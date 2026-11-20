// lib/pages/school/grades/grade_report_pdf.dart
//
// Printable student academic report card PDF (School ERP plan §3.6, Phase 5).
// Includes term subject marks, overall percentage/GPA/rank, and compulsory
// bimonthly event participation (flagging any absences — report-only).

import 'dart:typed_data';

import 'package:flutter/services.dart' show rootBundle;
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';

import 'grade_rules.dart';

abstract final class SchoolReportCardPdf {
  static pw.Font? _urdu;

  static Future<pw.ThemeData> _theme() async {
    if (_urdu == null) {
      try {
        _urdu = pw.Font.ttf(await rootBundle.load('assets/fonts/Amiri-Regular.ttf'));
      } catch (_) {}
    }
    return pw.ThemeData.withFont(
      base: pw.Font.helvetica(),
      bold: pw.Font.helveticaBold(),
      fontFallback: [?_urdu],
    );
  }

  static Future<Uint8List> buildSingle({
    required StudentTermReport report,
    required String branchName,
  }) =>
      buildBatch(reports: [report], branchName: branchName);

  static Future<Uint8List> buildBatch({
    required List<StudentTermReport> reports,
    required String branchName,
  }) async {
    final doc = pw.Document(theme: await _theme());
    pw.ImageProvider? logo;
    try {
      final data = await rootBundle.load('assets/logo/twt.webp');
      logo = pw.MemoryImage(data.buffer.asUint8List());
    } catch (_) {
      try {
        final data = await rootBundle.load('assets/logo/gmwf-1.webp');
        logo = pw.MemoryImage(data.buffer.asUint8List());
      } catch (_) {}
    }

    for (final r in reports) {
      doc.addPage(pw.Page(
        pageFormat: PdfPageFormat.a4,
        margin: const pw.EdgeInsets.all(28),
        build: (_) => _page(r, branchName, logo),
      ));
    }
    return doc.save();
  }

  static pw.Widget _page(StudentTermReport r, String branchName, pw.ImageProvider? logo) {
    final s = r.student;
    final ev = r.events;
    final headerColor = PdfColor.fromInt(0xFF1E3A5F);

    return pw.Container(
      padding: const pw.EdgeInsets.all(18),
      decoration: pw.BoxDecoration(
        border: pw.Border.all(color: headerColor, width: 1.5),
        borderRadius: const pw.BorderRadius.all(pw.Radius.circular(6)),
      ),
      child: pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.stretch, children: [
        // School header
        pw.Row(crossAxisAlignment: pw.CrossAxisAlignment.center, children: [
          if (logo != null) pw.SizedBox(width: 50, height: 50, child: pw.Image(logo)) else pw.SizedBox(width: 50),
          pw.Expanded(
            child: pw.Column(children: [
              pw.Text(
                'Taleem o Tarbiyat School System',
                textAlign: pw.TextAlign.center,
                style: pw.TextStyle(fontSize: 16, fontWeight: pw.FontWeight.bold, color: headerColor),
              ),
              pw.Text(
                'Gulzar Madina Welfare Foundation · $branchName',
                textAlign: pw.TextAlign.center,
                style: const pw.TextStyle(fontSize: 9, color: PdfColors.grey700),
              ),
            ]),
          ),
          pw.SizedBox(width: 50),
        ]),
        pw.SizedBox(height: 8),
        pw.Container(
          color: headerColor,
          padding: const pw.EdgeInsets.symmetric(vertical: 5, horizontal: 10),
          child: pw.Text(
            'ACADEMIC REPORT CARD · ${r.term.toUpperCase()}${s.academicYear.isEmpty ? '' : ' (${s.academicYear})'}',
            textAlign: pw.TextAlign.center,
            style: pw.TextStyle(color: PdfColors.white, fontSize: 10.5, fontWeight: pw.FontWeight.bold),
          ),
        ),
        pw.SizedBox(height: 10),

        // Student info box
        pw.Container(
          padding: const pw.EdgeInsets.all(8),
          decoration: pw.BoxDecoration(
            color: PdfColors.grey100,
            border: pw.Border.all(color: PdfColors.grey400, width: 0.6),
          ),
          child: pw.Column(children: [
            _infoRow('Student Name', s.name, 'Admission No.', s.admissionNo),
            pw.SizedBox(height: 3),
            _infoRow('Father / Guardian', s.guardianName, 'Class & Roll', '${s.grade}-${s.section} · Roll ${s.rollNo}'),
            pw.SizedBox(height: 3),
            _infoRow(
              'Academic Stream',
              s.academicGroup,
              'Class Position',
              r.rank == null ? '—' : '${r.rank} of ${r.classSize}',
            ),
          ]),
        ),
        pw.SizedBox(height: 12),

        // Marks table
        if (r.grades.isEmpty)
          pw.Container(
            padding: const pw.EdgeInsets.all(16),
            decoration: pw.BoxDecoration(border: pw.Border.all(color: PdfColors.grey300)),
            child: pw.Text('No marks have been recorded for ${r.term} yet.',
                textAlign: pw.TextAlign.center, style: const pw.TextStyle(fontSize: 9.5, color: PdfColors.grey700)),
          )
        else
          pw.Table(
            border: pw.TableBorder.all(color: PdfColors.grey400, width: 0.5),
            columnWidths: const {
              0: pw.FlexColumnWidth(3.0),
              1: pw.FlexColumnWidth(1.6),
              2: pw.FlexColumnWidth(1.3),
              3: pw.FlexColumnWidth(1.3),
              4: pw.FlexColumnWidth(1.3),
              5: pw.FlexColumnWidth(1.0),
              6: pw.FlexColumnWidth(2.2),
            },
            children: [
              pw.TableRow(
                decoration: const pw.BoxDecoration(color: PdfColors.grey200),
                children: [
                  for (final h in ['Subject', 'Exam', 'Obtained', 'Total', '%', 'Grade', 'Remarks'])
                    pw.Padding(
                      padding: const pw.EdgeInsets.all(5),
                      child: pw.Text(h, style: pw.TextStyle(fontSize: 8.5, fontWeight: pw.FontWeight.bold)),
                    ),
                ],
              ),
              for (final g in r.grades)
                pw.TableRow(children: [
                  _cell(g.subject),
                  _cell(g.examType),
                  _cell(GradeRules.formatMark(g.marksObtained), align: pw.TextAlign.right),
                  _cell(GradeRules.formatMark(g.totalMarks), align: pw.TextAlign.right),
                  _cell('${g.percentage.toStringAsFixed(1)}%', align: pw.TextAlign.right),
                  _cell(g.letterGrade, bold: true, align: pw.TextAlign.center),
                  _cell(g.remarks.isEmpty ? '—' : g.remarks),
                ]),
              pw.TableRow(
                decoration: const pw.BoxDecoration(color: PdfColors.grey100),
                children: [
                  _cell('OVERALL TOTAL', bold: true),
                  _cell('${r.grades.length} subjects', bold: true),
                  _cell(GradeRules.formatMark(r.totalObtained), bold: true, align: pw.TextAlign.right),
                  _cell(GradeRules.formatMark(r.totalPossible), bold: true, align: pw.TextAlign.right),
                  _cell('${r.percentage.toStringAsFixed(1)}%', bold: true, align: pw.TextAlign.right),
                  _cell(r.letterGrade, bold: true, align: pw.TextAlign.center),
                  _cell('GPA ${r.gpa.toStringAsFixed(2)} · ${r.passed ? 'PASS' : 'NEEDS IMPROVEMENT'}', bold: true),
                ],
              ),
            ],
          ),

        pw.SizedBox(height: 12),

        // Bimonthly compulsory events block (report-only, flags absences)
        pw.Container(
          padding: const pw.EdgeInsets.all(8),
          decoration: pw.BoxDecoration(
            color: ev.hasAbsences ? PdfColor.fromInt(0xFFFFF4F4) : PdfColors.grey50,
            border: pw.Border.all(color: ev.hasAbsences ? PdfColors.red400 : PdfColors.grey400, width: 0.7),
            borderRadius: const pw.BorderRadius.all(pw.Radius.circular(4)),
          ),
          child: pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.start, children: [
            pw.Text(
              'Compulsory Bimonthly Events (Bazm-e-Adab, Speech Gala, Training & Field Trips)',
              style: pw.TextStyle(fontSize: 9, fontWeight: pw.FontWeight.bold, color: headerColor),
            ),
            pw.SizedBox(height: 3),
            if (ev.totalHeld == 0)
              pw.Text('No compulsory events held yet in this session.', style: const pw.TextStyle(fontSize: 8.5, color: PdfColors.grey700))
            else ...[
              pw.Text(
                'Participated: ${ev.attended} of ${ev.totalHeld} events'
                '${ev.excused > 0 ? ' · Excused: ${ev.excused}' : ''}'
                ' · Unexcused Absences: ${ev.absent}',
                style: pw.TextStyle(
                  fontSize: 8.5,
                  fontWeight: ev.hasAbsences ? pw.FontWeight.bold : pw.FontWeight.normal,
                  color: ev.hasAbsences ? PdfColors.red800 : PdfColors.grey800,
                ),
              ),
              if (ev.missedEvents.isNotEmpty) ...[
                pw.SizedBox(height: 2),
                pw.Text(
                  'Flagged absences (participation is compulsory): ${ev.missedEvents.map((e) => '${e.title} (${e.date})').join(', ')}',
                  style: const pw.TextStyle(fontSize: 8, color: PdfColors.red900),
                ),
              ],
            ],
          ]),
        ),

        pw.Spacer(),

        // Signatures
        pw.Row(mainAxisAlignment: pw.MainAxisAlignment.spaceBetween, children: [
          _sig('Class Teacher'),
          _sig('Principal Signature & Stamp'),
          _sig('Parent / Guardian Signature'),
        ]),
      ]),
    );
  }

  static pw.Widget _infoRow(String k1, String v1, String k2, String v2) => pw.Row(children: [
        pw.SizedBox(width: 85, child: pw.Text(k1, style: const pw.TextStyle(fontSize: 8.5, color: PdfColors.grey700))),
        pw.Expanded(child: pw.Text(v1, style: pw.TextStyle(fontSize: 9, fontWeight: pw.FontWeight.bold))),
        pw.SizedBox(width: 12),
        pw.SizedBox(width: 85, child: pw.Text(k2, style: const pw.TextStyle(fontSize: 8.5, color: PdfColors.grey700))),
        pw.Expanded(child: pw.Text(v2, style: pw.TextStyle(fontSize: 9, fontWeight: pw.FontWeight.bold))),
      ]);

  static pw.Widget _cell(String text, {bool bold = false, pw.TextAlign align = pw.TextAlign.left}) => pw.Padding(
        padding: const pw.EdgeInsets.all(5),
        child: pw.Text(
          text,
          textAlign: align,
          style: pw.TextStyle(fontSize: 8.5, fontWeight: bold ? pw.FontWeight.bold : pw.FontWeight.normal),
        ),
      );

  static pw.Widget _sig(String label) => pw.Column(children: [
        pw.Container(width: 135, height: 0.8, color: PdfColors.grey800),
        pw.SizedBox(height: 4),
        pw.Text(label, style: pw.TextStyle(fontSize: 8.5, fontWeight: pw.FontWeight.bold)),
      ]);

  static Future<void> printSingle({required StudentTermReport report, required String branchName}) async {
    final bytes = await buildSingle(report: report, branchName: branchName);
    final safe = report.student.name.replaceAll(RegExp(r'[^A-Za-z0-9]+'), '_');
    await Printing.layoutPdf(name: 'ReportCard-${report.student.admissionNo}-$safe', onLayout: (_) async => bytes);
  }

  static Future<void> printBatch({required List<StudentTermReport> reports, required String branchName, required String title}) async {
    final bytes = await buildBatch(reports: reports, branchName: branchName);
    await Printing.layoutPdf(name: title, onLayout: (_) async => bytes);
  }
}
