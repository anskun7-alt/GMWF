import 'dart:io';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:http/http.dart' as http;
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:excel/excel.dart' hide Border, BorderStyle;
import 'package:excel/excel.dart' as exc;
import 'package:intl/intl.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';
import 'package:arabic_reshaper/arabic_reshaper.dart';
import '../models/madrassa_config.dart';
import '../models/madrassa_fee_logic.dart';
import 'madrassa_local_storage.dart';
import '../../../constants/navigator_key.dart';

class MadrassaReportHelper {
  static pw.Font? _amiriFont;

  /// Safely converts whatever Map-ish value comes back from Firestore /
  /// JSON / local-storage into a proper `Map<String, dynamic>`. Firestore
  /// (and some local/json sources) can hand back a raw `Map<dynamic,
  /// dynamic>` for nested maps, and a direct `as Map<String, dynamic>`
  /// cast on that throws:
  ///   "type '_Map<dynamic, dynamic>' is not a subtype of type
  ///    'Map<String, dynamic>?' in type cast"
  /// `Map<String, dynamic>.from(...)` re-keys everything as Strings (via
  /// toString() on each key) instead of doing an unsafe runtime cast, so
  /// this never throws for a Map of any shape.
  static Map<String, dynamic>? _asStringMap(dynamic raw) {
    if (raw == null) return null;
    if (raw is Map<String, dynamic>) return raw;
    if (raw is Map) return Map<String, dynamic>.from(raw);
    return null;
  }

  static Map<String, dynamic> getAcademicProgress({
    required String studentId,
    required List<dynamic> logs,
  }) {
    final sortedLogs = [...logs]..sort((a, b) {
      final aId = a is DocumentSnapshot ? a.id : (a as Map)['id']?.toString() ?? '';
      final bId = b is DocumentSnapshot ? b.id : (b as Map)['id']?.toString() ?? '';
      return aId.compareTo(bId);
    });
    int firstLines = -1;
    int lastLines = -1;
    int latestSabkiPara = 0;
    String latestSabkiRatio = '';
    int latestManzilPara = 0;
    String latestManzilRatio = '';

    for (var logDoc in sortedLogs) {
      Map<String, dynamic>? logData;
      if (logDoc is DocumentSnapshot) {
        logData = _asStringMap(logDoc.data());
      } else if (logDoc is Map) {
        logData = Map<String, dynamic>.from(logDoc);
      }
      if (logData == null || !logData.containsKey(studentId)) continue;
      final studentLog = _asStringMap(logData[studentId]);
      if (studentLog == null) continue;

      final currentLines = (studentLog['currentLines'] as num?)?.toInt() ?? int.tryParse(studentLog['currentLines']?.toString() ?? '');
      if (currentLines != null && currentLines > 0) {
        if (firstLines == -1) firstLines = currentLines;
        lastLines = currentLines;
      }

      final sabkiPara = (studentLog['sabkiPara'] as num?)?.toInt() ?? int.tryParse(studentLog['sabkiPara']?.toString() ?? '');
      final sabkiRatio = studentLog['sabkiRatio']?.toString();
      if (sabkiPara != null && sabkiPara > 0) {
        latestSabkiPara = sabkiPara;
        latestSabkiRatio = sabkiRatio ?? '';
      } else if (sabkiRatio == 'nahi_sunaya') {
        latestSabkiPara = 0;
        latestSabkiRatio = 'nahi_sunaya';
      }

      final manzilPara = (studentLog['manzilPara'] as num?)?.toInt() ?? int.tryParse(studentLog['manzilPara']?.toString() ?? '');
      final manzilRatio = studentLog['manzilRatio']?.toString();
      if (manzilPara != null && manzilPara > 0) {
        latestManzilPara = manzilPara;
        latestManzilRatio = manzilRatio ?? '';
      } else if (manzilRatio == 'nahi_sunaya') {
        latestManzilPara = 0;
        latestManzilRatio = 'nahi_sunaya';
      }
    }

    int linesMemorized = 0;
    if (firstLines != -1 && lastLines != -1) {
      linesMemorized = (lastLines - firstLines).clamp(0, 99999);
    }

    return {
      'linesMemorized': linesMemorized,
      'lastLines': lastLines == -1 ? 0 : lastLines,
      'sabkiPara': latestSabkiPara,
      'sabkiRatio': latestSabkiRatio,
      'manzilPara': latestManzilPara,
      'manzilRatio': latestManzilRatio,
    };
  }

  /// Walks a student's logs for the period and pulls out the actual *dates*
  /// (not just counts) of absence, leave, days the uniform wasn't proper,
  /// and days a message wasn't replied to — used by the Excel export's
  /// "Attendance & Compliance Details" rows.
  ///
  /// IMPORTANT — field-name assumption: each log document's id is assumed to
  /// be (or start with) a parseable date, e.g. "2026-06-15", which is how
  /// `getAcademicProgress` above already sorts logs. Per-student status is
  /// read from `studentLog['status']` (expected values: 'present', 'absent',
  /// 'leave') with a fallback to legacy boolean fields `absent`/`leave` if
  /// `status` isn't present.
  ///
  /// Uniform / message-reply field names are NOT fully confirmed against
  /// your live schema, so this checks a handful of common variants for each
  /// (in priority order) instead of a single hardcoded key.
  static Map<String, List<String>> getAttendanceDetails({
    required String studentId,
    required List<dynamic> logs,
  }) {
    final sortedLogs = [...logs]..sort((a, b) {
      final aId = a is DocumentSnapshot ? a.id : (a as Map)['id']?.toString() ?? '';
      final bId = b is DocumentSnapshot ? b.id : (b as Map)['id']?.toString() ?? '';
      return aId.compareTo(bId);
    });

    final absentDates = <String>[];
    final leaveDates = <String>[];
    final uniformNotProperDates = <String>[];
    final messageNotRepliedDates = <String>[];

    // Candidate field names, checked in order, for uniform compliance and
    // message-reply status. The first key present on the log entry wins.
    const uniformKeys = ['uniform', 'uniformProper', 'uniformOk', 'isUniformProper'];
    const messageKeys = ['message', 'messageReplied', 'msgReplied', 'reply', 'replied'];

    /// Reads a boolean-ish value out of a log map, trying several possible
    /// keys and several possible value encodings (bool, "yes"/"no",
    /// "true"/"false", 1/0). Returns null if no candidate key is present at
    /// all (so "not recorded" can be distinguished from "recorded as false").
    bool? readBoolField(Map<String, dynamic> studentLog, List<String> keys) {
      for (final key in keys) {
        if (!studentLog.containsKey(key)) continue;
        final raw = studentLog[key];
        if (raw is bool) return raw;
        if (raw is num) return raw != 0;
        if (raw is String) {
          final v = raw.trim().toLowerCase();
          if (v == 'true' || v == 'yes' || v == '1') return true;
          if (v == 'false' || v == 'no' || v == '0') return false;
        }
      }
      return null;
    }

    String formatLogDate(String rawId) {
      // Log ids are typically date-stamped (e.g. "2026-06-15"); fall back to
      // the raw id if it doesn't parse so nothing silently disappears.
      final parsed = DateTime.tryParse(rawId);
      if (parsed != null) return DateFormat('dd MMM').format(parsed);
      return rawId;
    }

    for (var logDoc in sortedLogs) {
      String logId;
      Map<String, dynamic>? logData;
      if (logDoc is DocumentSnapshot) {
        logId = logDoc.id;
        logData = _asStringMap(logDoc.data());
      } else if (logDoc is Map) {
        logId = (logDoc['id'] ?? '').toString();
        logData = Map<String, dynamic>.from(logDoc);
      } else {
        continue;
      }
      if (logData == null || !logData.containsKey(studentId)) continue;
      final studentLog = _asStringMap(logData[studentId]);
      if (studentLog == null) continue;

      final dateLabel = formatLogDate(logId);

      // ── Attendance status ──────────────────────────────────────────
      final status = studentLog['status']?.toString().toLowerCase();
      final isAbsent = status == 'absent' || studentLog['absent'] == true;
      final isLeave = status == 'leave' || studentLog['leave'] == true;
      if (isAbsent) absentDates.add(dateLabel);
      if (isLeave) leaveDates.add(dateLabel);

      // ── Uniform ─────────────────────────────────────────────────────
      // Flagged as "not proper" only when explicitly recorded as false, so
      // missing/unrecorded data isn't flagged as non-compliant by default.
      final uniformOk = readBoolField(studentLog, uniformKeys);
      if (uniformOk == false) {
        uniformNotProperDates.add(dateLabel);
      }

      // ── Message reply ──────────────────────────────────────────────
      final messageReplied = readBoolField(studentLog, messageKeys);
      if (messageReplied == false) {
        messageNotRepliedDates.add(dateLabel);
      }
    }

    return {
      'absent': absentDates,
      'leave': leaveDates,
      'uniformNotProper': uniformNotProperDates,
      'messageNotReplied': messageNotRepliedDates,
    };
  }

  static Future<void> exportMonthlyPdf({
    required MadrassaConfig config,
    required List<dynamic> students,
    required List<dynamic> logs,
    List<DateTime> holidays = const [],
  }) async {
    if (_amiriFont == null) {
      final amiriData = await rootBundle.load('assets/fonts/Amiri-Regular.ttf');
      _amiriFont = pw.Font.ttf(amiriData);
    }

    final pdf = pw.Document(
      theme: pw.ThemeData.withFont(
        base: pw.Font.helvetica(),
        bold: pw.Font.helveticaBold(),
      ),
    );

    final monthName = DateFormat('MMMM yyyy').format(DateTime(config.year, config.month));
    final workingDays = MadrassaFeeLogic.getWorkingDaysCount(config.year, config.month, holidays);

    final logoData = await rootBundle.load('assets/logo/gmwf-1.webp');
    final logoImage = pw.MemoryImage(logoData.buffer.asUint8List());

    String formatRatioCompact(String ratio) {
      if (ratio == '1/4') return '1/4';
      if (ratio == '1/2') return '1/2';
      if (ratio == '3/4') return '3/4';
      if (ratio == '1') return '1';
      if (ratio == 'nahi_sunaya') return 'NS';
      return ratio;
    }

    // ── Pre-compute every row's data once so we can both render the table
    // AND build an accurate grand-totals row at the bottom. ───────────────
    final rows = <Map<String, dynamic>>[];
    double totalAtt = 0, totalUni = 0, totalMsg = 0, totalSavings = 0, totalDue = 0;
    int totalPresent = 0, totalLeave = 0, totalAbsent = 0;

    for (final s in students) {
      final sData = s is DocumentSnapshot ? (_asStringMap(s.data()) ?? <String, dynamic>{}) : Map<String, dynamic>.from(s as Map);
      final sId = s is DocumentSnapshot ? s.id : s['id'].toString();
      final fee = MadrassaFeeLogic.calculateStudentFee(
        studentId: sId,
        studentData: sData,
        logs: logs,
        config: config,
        totalWorkingDays: workingDays,
        holidays: holidays,
      );
      final acad = getAcademicProgress(studentId: sId, logs: logs);
      final branchId = (sData['branchId']?.toString() ?? config.id).toLowerCase().trim();
      final pRec = MadrassaLocalStorage.getFeePaymentCached(branchId, config.year, config.month, sId);
      final due = (fee['amountDue'] as num).toDouble();
      final pStatus = pRec?['status']?.toString() ?? (due <= 0 ? 'paid' : 'unpaid');
      final pPaid = (pRec?['amountPaid'] as num?)?.toDouble() ?? (pStatus == 'paid' ? due : 0.0);

      totalAtt += (fee['attSavings'] as num).toDouble();
      totalUni += (fee['uniSavings'] as num).toDouble();
      totalMsg += (fee['msgSavings'] as num).toDouble();
      totalSavings += (fee['totalSavings'] as num).toDouble();
      totalDue += due;
      totalPresent += (fee['present'] as num).toInt();
      totalLeave += (fee['leave'] as num).toInt();
      totalAbsent += (fee['absent'] as num).toInt();

      rows.add({
        'name': sData['name'] ?? '',
        'rollNumber': sData['rollNumber'] ?? '',
        'fee': fee,
        'acad': acad,
        'isPaid': pStatus == 'paid',
        'status': pStatus,
        'amountPaid': pPaid,
      });
    }

    pdf.addPage(
      pw.MultiPage(
        pageFormat: PdfPageFormat.a4.landscape,
        margin: const pw.EdgeInsets.all(24),
        header: (pw.Context context) => pw.Column(
          crossAxisAlignment: pw.CrossAxisAlignment.start,
          children: [
            pw.Container(
              padding: const pw.EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              decoration: const pw.BoxDecoration(
                color: PdfColor.fromInt(0xFF00695C),
                borderRadius: pw.BorderRadius.all(pw.Radius.circular(8)),
              ),
              child: pw.Row(
                mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
                children: [
                  pw.Column(
                    crossAxisAlignment: pw.CrossAxisAlignment.start,
                    children: [
                      pw.Text(
                        'Gulzar Madina Madrassa',
                        style: pw.TextStyle(
                          fontSize: 20,
                          fontWeight: pw.FontWeight.bold,
                          color: PdfColors.white,
                        ),
                      ),
                      pw.SizedBox(height: 4),
                      pw.Text(
                        'Madrassa Monthly Report - $monthName',
                        style: const pw.TextStyle(
                          fontSize: 12,
                          color: PdfColors.teal50,
                        ),
                      ),
                    ],
                  ),
                  pw.Row(
                    children: [
                      if (config.year == DateTime.now().year && config.month == DateTime.now().month)
                        pw.Container(
                          padding: const pw.EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                          decoration: const pw.BoxDecoration(
                            color: PdfColor.fromInt(0xFF004D40),
                            borderRadius: pw.BorderRadius.all(pw.Radius.circular(4)),
                          ),
                          child: pw.Text(
                            'Status: Active (${DateFormat('yyyy-MM-dd').format(DateTime.now())})',
                            style: pw.TextStyle(
                              fontSize: 9,
                              color: PdfColors.teal100,
                              fontStyle: pw.FontStyle.italic,
                            ),
                          ),
                        ),
                      pw.SizedBox(width: 16),
                      pw.ClipOval(
                        child: pw.Container(
                          color: PdfColors.white,
                          width: 42,
                          height: 42,
                          child: pw.Image(logoImage, fit: pw.BoxFit.contain),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            pw.SizedBox(height: 16),
          ],
        ),
        build: (pw.Context context) {
          // Column layout (index reference for cellAlignments/columnWidths/decoration):
          // 0 #  1 Student  2 Roll  3 Days  4 P  5 L  6 A  7 Uniform  8 Sabak  9 Sabki  10 Manzil
          // [If fees enabled: 11 Att.Rs  12 Uni.Rs  13 Msg  14 Msg.Rs  15 PTM  16 Total Rs  17 Due  18 Status]
          // [If fees disabled: 11 Msg  12 PTM]
          final bool isFeeEnabled = config.enableFees;
          final headers = [
            '#', 'Student', 'Roll', 'Days', 'P', 'L', 'A', 'Uniform',
            'Sabak', 'Sabki', 'Manzil',
            if (isFeeEnabled) 'Att. Rs',
            if (isFeeEnabled) 'Uni. Rs',
            'Msg',
            if (isFeeEnabled) 'Msg. Rs',
            'PTM',
            if (isFeeEnabled) 'Total Rs',
            if (isFeeEnabled) 'Due',
            if (isFeeEnabled) 'Status',
          ];
          final int dueColIndex = isFeeEnabled ? (headers.length - 2) : -1;

          return [
            pw.TableHelper.fromTextArray(
              headers: headers,
              data: List.generate(rows.length, (i) {
                final row = rows[i];
                final fee = row['fee'] as Map<String, dynamic>;
                final acad = row['acad'] as Map<String, dynamic>;

                final linesMemorized = acad['linesMemorized'] as int;
                final cumulativeLines = acad['lastLines'] as int;
                final sabkiPara = acad['sabkiPara'] as int;
                final sabkiRatio = acad['sabkiRatio'] as String;
                final manzilPara = acad['manzilPara'] as int;
                final manzilRatio = acad['manzilRatio'] as String;

                final String sabakText;
                if (linesMemorized > 0) {
                  sabakText = '+$linesMemorized ($cumulativeLines)';
                } else if (cumulativeLines > 0) {
                  sabakText = '($cumulativeLines)';
                } else {
                  sabakText = '-';
                }

                final sabkiText = sabkiPara > 0
                    ? '$sabkiPara (${formatRatioCompact(sabkiRatio)})'
                    : (sabkiRatio == 'nahi_sunaya' ? 'NS' : '-');
                final manzilText = manzilPara > 0
                    ? '$manzilPara (${formatRatioCompact(manzilRatio)})'
                    : (manzilRatio == 'nahi_sunaya' ? 'NS' : '-');

                return [
                  '${i + 1}',
                  _processUrduCell(row['name'] ?? '', style: pw.TextStyle(fontSize: 10, fontWeight: pw.FontWeight.bold), alignment: pw.Alignment.centerLeft),
                  '${row['rollNumber'] ?? ''}',
                  '${fee['activeWorkingDays']}',
                  '${fee['present']}',
                  '${fee['leave']}',
                  '${fee['absent']}',
                  '${fee['uniform']}/${fee['activeWorkingDays']}',
                  sabakText,
                  sabkiText,
                  manzilText,
                  if (isFeeEnabled) ((fee['attSavings'] as num).toStringAsFixed(0)),
                  if (isFeeEnabled) ((fee['uniSavings'] as num).toStringAsFixed(0)),
                  '${fee['message']}/${fee['activeWorkingDays']}',
                  if (isFeeEnabled) ((fee['msgSavings'] as num).toStringAsFixed(0)),
                  fee['ptm'] ? 'Joined' : 'Missed',
                  if (isFeeEnabled) ((fee['totalSavings'] as num).toStringAsFixed(0)),
                  if (isFeeEnabled) ((fee['amountDue'] as num).toStringAsFixed(0)),
                  if (isFeeEnabled) (row['isPaid'] == true ? 'Paid' : ((fee['amountDue'] as num) <= 0 ? 'Waived' : 'Unpaid')),
                ];
              }),
              headerStyle: pw.TextStyle(fontWeight: pw.FontWeight.bold, fontSize: 8.5, color: PdfColors.white, letterSpacing: 0.3),
              cellStyle: const pw.TextStyle(fontSize: 8.5),
              headerDecoration: const pw.BoxDecoration(color: PdfColor.fromInt(0xFF00695C)),
              headerPadding: const pw.EdgeInsets.symmetric(horizontal: 6, vertical: 9),
              cellAlignment: pw.Alignment.center,
              cellAlignments: {
                for (int col = 0; col < headers.length; col++)
                  col: (col == 1 ? pw.Alignment.centerLeft : pw.Alignment.center),
              },
              cellPadding: const pw.EdgeInsets.symmetric(horizontal: 8, vertical: 10),
              columnWidths: isFeeEnabled
                  ? {
                      0: const pw.FixedColumnWidth(24),
                      1: const pw.FlexColumnWidth(3),
                      2: const pw.FixedColumnWidth(28),
                      3: const pw.FixedColumnWidth(36),
                      4: const pw.FixedColumnWidth(30),
                      5: const pw.FixedColumnWidth(30),
                      6: const pw.FixedColumnWidth(30),
                      7: const pw.FixedColumnWidth(44),
                      8: const pw.FixedColumnWidth(38),
                      9: const pw.FixedColumnWidth(38),
                      10: const pw.FixedColumnWidth(38),
                      11: const pw.FixedColumnWidth(36),
                      12: const pw.FixedColumnWidth(36),
                      13: const pw.FixedColumnWidth(38),
                      14: const pw.FixedColumnWidth(40),
                      15: const pw.FixedColumnWidth(48),
                      16: const pw.FixedColumnWidth(46),
                      17: const pw.FixedColumnWidth(42),
                      18: const pw.FixedColumnWidth(44),
                    }
                  : {
                      0: const pw.FixedColumnWidth(30),
                      1: const pw.FlexColumnWidth(3),
                      2: const pw.FixedColumnWidth(36),
                      3: const pw.FixedColumnWidth(48),
                      4: const pw.FixedColumnWidth(40),
                      5: const pw.FixedColumnWidth(40),
                      6: const pw.FixedColumnWidth(40),
                      7: const pw.FixedColumnWidth(56),
                      8: const pw.FixedColumnWidth(50),
                      9: const pw.FixedColumnWidth(50),
                      10: const pw.FixedColumnWidth(50),
                      11: const pw.FixedColumnWidth(48),
                      12: const pw.FixedColumnWidth(58),
                    },
              // Full grid lines (horizontal AND vertical) so the dense,
              // wide table is easy to track across both rows and columns,
              // plus a slightly bolder border framing the whole table.
              // Previously only horizontalInside was set, which is why the
              // table looked like un-separated stripes with no column
              // lines — that's the "lines must be added" fix.
              border: pw.TableBorder(
                horizontalInside: const pw.BorderSide(color: PdfColor.fromInt(0xFFCBD5E1), width: 0.5),
                verticalInside: const pw.BorderSide(color: PdfColor.fromInt(0xFFCBD5E1), width: 0.5),
                top: const pw.BorderSide(color: PdfColor.fromInt(0xFF00695C), width: 1),
                bottom: const pw.BorderSide(color: PdfColor.fromInt(0xFF00695C), width: 1),
                left: const pw.BorderSide(color: PdfColor.fromInt(0xFF00695C), width: 1),
                right: const pw.BorderSide(color: PdfColor.fromInt(0xFF00695C), width: 1),
              ),
              // ── Zebra striping + highlight the Due column so the most
              // actionable number on the page (who still owes money) jumps
              // out, instead of looking identical to a fully-paid row.
              rowDecoration: const pw.BoxDecoration(color: PdfColors.white),
              oddRowDecoration: const pw.BoxDecoration(color: PdfColor.fromInt(0xFFF0FAF8)),
              cellDecoration: (int colIndex, dynamic cellData, int rowIndex) {
                // NOTE: pdf 3.11.3's TableHelper.fromTextArray declares
                // `cellDecoration` as returning a non-nullable BoxDecoration,
                // so `return null;` fails to compile on this version.
                // Returning an "empty" BoxDecoration is the equivalent of
                // "no decoration" and renders transparently.
                if (colIndex != dueColIndex) {
                  return const pw.BoxDecoration();
                }
                final due = double.tryParse(cellData.toString()) ?? 0;
                if (due <= 0) {
                  return const pw.BoxDecoration(color: PdfColor.fromInt(0xFFDFF5E1)); // paid — soft green
                }
                if (due > 1000) {
                  return const pw.BoxDecoration(color: PdfColor.fromInt(0xFFFBE0E0)); // high due — soft red
                }
                return const pw.BoxDecoration(color: PdfColor.fromInt(0xFFFFF3D6)); // some due — soft amber
              },
            ),
            pw.SizedBox(height: 14),
            // ── Grand-totals summary row, mirroring the Excel export ──────
            pw.Container(
              padding: const pw.EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              decoration: pw.BoxDecoration(
                color: const PdfColor.fromInt(0xFFE0F2F1),
                borderRadius: pw.BorderRadius.circular(8),
                border: pw.Border.all(color: const PdfColor.fromInt(0xFF00695C), width: 0.75),
              ),
              child: pw.Row(
                mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
                children: [
                  _totalChip('Students', '${rows.length}'),
                  _totalChip('Present', '$totalPresent'),
                  _totalChip('Leave', '$totalLeave'),
                  _totalChip('Absent', '$totalAbsent'),
                  if (isFeeEnabled) ...[
                    _totalChip('Att. Savings', totalAtt.toStringAsFixed(0)),
                    _totalChip('Uni. Savings', totalUni.toStringAsFixed(0)),
                    _totalChip('Msg Savings', totalMsg.toStringAsFixed(0)),
                    _totalChip('Total Savings', totalSavings.toStringAsFixed(0)),
                    _totalChip('GRAND TOTAL DUE', totalDue.toStringAsFixed(0), emphasize: true),
                  ],
                ],
              ),
            ),
          ];
        },
        footer: (pw.Context context) => pw.Align(
          alignment: pw.Alignment.centerRight,
          child: pw.Text('Page ${context.pageNumber} of ${context.pagesCount}', style: const pw.TextStyle(fontSize: 8, color: PdfColors.grey)),
        ),
      ),
    );

    final bytes = await pdf.save();
    await _saveAndNotify('Madrassa_Monthly_Report_${monthName.replaceAll(' ', '_')}.pdf', bytes);
  }

  static pw.Widget _totalChip(String label, String value, {bool emphasize = false}) {
    return pw.Column(
      crossAxisAlignment: pw.CrossAxisAlignment.center,
      children: [
        pw.Text(label.toUpperCase(),
            style: pw.TextStyle(fontSize: 7, fontWeight: pw.FontWeight.bold, color: const PdfColor.fromInt(0xFF0F766E))),
        pw.SizedBox(height: 2),
        pw.Text(
          value,
          style: pw.TextStyle(
            fontSize: emphasize ? 13 : 10,
            fontWeight: pw.FontWeight.bold,
            color: emphasize ? const PdfColor.fromInt(0xFFD32F2F) : const PdfColor.fromInt(0xFF004D40),
          ),
        ),
      ],
    );
  }

  static Future<void> exportMonthlyExcel({
    required MadrassaConfig config,
    required List<dynamic> students,
    required List<dynamic> logs,
    List<DateTime> holidays = const [],
  }) async {
    final excel = Excel.createExcel();
    final String sheetName = 'Monthly Report';
    excel.rename('Sheet1', sheetName);
    final Sheet sheet = excel[sheetName];
    excel.setDefaultSheet(sheetName);
    
    final monthName = DateFormat('MMMM yyyy').format(DateTime(config.year, config.month));
    final workingDays = MadrassaFeeLogic.getWorkingDaysCount(config.year, config.month, holidays);

    // Styling
    final headerStyle = CellStyle(
      bold: true,
      backgroundColorHex: ExcelColor.fromHexString('#008080'), // Teal
      fontColorHex: ExcelColor.fromHexString('#FFFFFF'),
      horizontalAlign: HorizontalAlign.Center,
      verticalAlign: VerticalAlign.Center,
      topBorder: exc.Border(borderStyle: exc.BorderStyle.Thin),
      bottomBorder: exc.Border(borderStyle: exc.BorderStyle.Thin),
      leftBorder: exc.Border(borderStyle: exc.BorderStyle.Thin),
      rightBorder: exc.Border(borderStyle: exc.BorderStyle.Thin),
    );

    final titleStyle = CellStyle(
      bold: true,
      fontSize: 14,
      fontColorHex: ExcelColor.fromHexString('#004D40'), // Deep Teal
    );

    // Set Column Widths
    sheet.setColumnWidth(0, 5); // #
    sheet.setColumnWidth(1, 25); // Student Name
    sheet.setColumnWidth(2, 15); // Roll
    for (int c = 3; c <= 19; c++) {
      sheet.setColumnWidth(c, 12);
    }

    // Headers & Branding
    try {
      final ByteData data = await rootBundle.load('assets/logo/gmwf-1.webp');
      final Uint8List imageBytes = data.buffer.asUint8List();
      (excel as dynamic).insertImage(sheetName, imageBytes, 0, 0);
    } catch (e) {
      debugPrint("Excel Logo Error: $e");
    }

    // Main Title with Merged Cells
    var titleCell = sheet.cell(CellIndex.indexByColumnRow(columnIndex: 0, rowIndex: 0));
    titleCell.value = TextCellValue('Gulzar Madina Welfare Foundation');
    titleCell.cellStyle = CellStyle(
      bold: true,
      fontSize: 16,
      horizontalAlign: HorizontalAlign.Left,
      fontColorHex: ExcelColor.fromHexString('#008080'), // Teal
      backgroundColorHex: ExcelColor.fromHexString('#E0F2F1'), // Light Teal
    );
    sheet.merge(CellIndex.indexByColumnRow(columnIndex: 0, rowIndex: 0), CellIndex.indexByColumnRow(columnIndex: 5, rowIndex: 1));
    
    sheet.cell(CellIndex.indexByColumnRow(columnIndex: 0, rowIndex: 2)).value = TextCellValue('Monthly Academic Report — $monthName');
    sheet.cell(CellIndex.indexByColumnRow(columnIndex: 0, rowIndex: 2)).cellStyle = CellStyle(italic: true, horizontalAlign: HorizontalAlign.Left);
    sheet.merge(CellIndex.indexByColumnRow(columnIndex: 0, rowIndex: 2), CellIndex.indexByColumnRow(columnIndex: 5, rowIndex: 2));

    if (config.year == DateTime.now().year && config.month == DateTime.now().month) {
      var statusCell = sheet.cell(CellIndex.indexByColumnRow(columnIndex: 0, rowIndex: 3));
      statusCell.value = TextCellValue('Report Status: Data compiled till today (${DateFormat('yyyy-MM-dd').format(DateTime.now())})');
      statusCell.cellStyle = CellStyle(italic: true, horizontalAlign: HorizontalAlign.Left, fontColorHex: ExcelColor.fromHexString('#C62828'));
      sheet.merge(CellIndex.indexByColumnRow(columnIndex: 0, rowIndex: 3), CellIndex.indexByColumnRow(columnIndex: 5, rowIndex: 3));
    }

    const int headerRow = 4;
    final bool isFeeEnabled = config.enableFees;
    final headers = [
      '#', 'Student Name', 'Roll Number', 'Total Days', 'Present', 'Leave', 'Absent',
      'Uniform Days',
      'Sabak (Lines)', 'Cumulative Lines', 'Latest Sabki Para', 'Latest Sabki Ratio',
      'Latest Manzil Para', 'Latest Manzil Ratio',
      if (isFeeEnabled) 'Att. Savings',
      if (isFeeEnabled) 'Uni. Savings',
      'Msg Replied',
      'PTM Joined',
      if (isFeeEnabled) 'Total Savings',
      if (isFeeEnabled) 'Amount Due',
    ];
    
    for (int i = 0; i < headers.length; i++) {
      var cell = sheet.cell(CellIndex.indexByColumnRow(columnIndex: i, rowIndex: headerRow));
      cell.value = TextCellValue(headers[i]);
      cell.cellStyle = headerStyle;
    }

    double totalAmountDue = 0;
    int totalStudents = students.length;

    String formatRatio(String ratio) {
      if (ratio == '1/4') return 'Pao (1/4)';
      if (ratio == '1/2') return 'Nisf (1/2)';
      if (ratio == '3/4') return 'Salasa (3/4)';
      if (ratio == '1') return 'Para (1)';
      if (ratio == 'nahi_sunaya') return 'Nahi Sunaya';
      return ratio;
    }

    for (var i = 0; i < students.length; i++) {
      final s = students[i];
      final sData = s is DocumentSnapshot ? (_asStringMap(s.data()) ?? <String, dynamic>{}) : Map<String, dynamic>.from(s as Map);
      final sId = s is DocumentSnapshot ? s.id : s['id'].toString();
      final fee = MadrassaFeeLogic.calculateStudentFee(
        studentId: sId,
        studentData: sData,
        logs: logs,
        config: config,
        totalWorkingDays: workingDays,
        holidays: holidays,
      );
      final amountDue = (fee['amountDue'] as num).toDouble();
      totalAmountDue += amountDue;

      final acad = getAcademicProgress(studentId: sId, logs: logs);
      final linesMemorized = acad['linesMemorized'] as int;
      final cumulativeLines = acad['lastLines'] as int;
      final sabkiPara = acad['sabkiPara'] as int;
      final sabkiRatio = acad['sabkiRatio'] as String;
      final manzilPara = acad['manzilPara'] as int;
      final manzilRatio = acad['manzilRatio'] as String;

      sheet.appendRow([
        IntCellValue(i + 1),
        TextCellValue('${sData['name'] ?? ''}'),
        TextCellValue('${sData['rollNumber'] ?? ''}'),
        IntCellValue(fee['activeWorkingDays']),
        IntCellValue(fee['present']),
        IntCellValue(fee['leave']),
        IntCellValue(fee['absent']),
        TextCellValue('${fee['uniform']}/${fee['activeWorkingDays']}'),
        IntCellValue(linesMemorized),
        IntCellValue(cumulativeLines),
        IntCellValue(sabkiPara),
        TextCellValue(formatRatio(sabkiRatio)),
        IntCellValue(manzilPara),
        TextCellValue(formatRatio(manzilRatio)),
        if (isFeeEnabled) DoubleCellValue((fee['attSavings'] as num).toDouble().roundToDouble()),
        if (isFeeEnabled) DoubleCellValue((fee['uniSavings'] as num).toDouble().roundToDouble()),
        TextCellValue(fee['message'] > 0 ? 'Yes' : 'No'),
        TextCellValue(fee['ptm'] ? 'Joined' : 'Missed'),
        if (isFeeEnabled) DoubleCellValue((fee['totalSavings'] as num).toDouble().roundToDouble()),
        if (isFeeEnabled) DoubleCellValue(amountDue.roundToDouble()),
      ]);
    }

    // Add totals row
    if (isFeeEnabled) {
      sheet.appendRow([]);
      final totalRow = sheet.maxRows;
      sheet.cell(CellIndex.indexByColumnRow(columnIndex: headers.length - 2, rowIndex: totalRow)).value = TextCellValue('GRAND TOTAL:');
      sheet.cell(CellIndex.indexByColumnRow(columnIndex: headers.length - 2, rowIndex: totalRow)).cellStyle = CellStyle(bold: true);
      sheet.cell(CellIndex.indexByColumnRow(columnIndex: headers.length - 1, rowIndex: totalRow)).value = DoubleCellValue(totalAmountDue.roundToDouble());
      sheet.cell(CellIndex.indexByColumnRow(columnIndex: headers.length - 1, rowIndex: totalRow)).cellStyle = CellStyle(bold: true, fontColorHex: ExcelColor.fromHexString('#D32F2F'));
    }

    final fileBytes = excel.save();
    if (fileBytes != null) {
      await _saveAndNotify('Madrassa_Monthly_Report_${monthName.replaceAll(' ', '_')}.xlsx', Uint8List.fromList(fileBytes));
    }
  }

  /// Safely pulls a DateTime out of a Firestore field that might be a
  /// [Timestamp], an ISO date [String], a [DateTime], or missing/malformed.
  /// Previously this was a hard `as Timestamp?` cast, which threw and
  /// silently aborted the whole individual export for any student whose
  /// joinDate wasn't stored as a Timestamp.
  static DateTime? _parseJoinDate(dynamic raw) {
    if (raw == null) return null;
    try {
      if (raw is Timestamp) return raw.toDate();
      if (raw is DateTime) return raw;
      if (raw is String && raw.isNotEmpty) return DateTime.tryParse(raw);
    } catch (_) {}
    return null;
  }

  static Future<void> exportIndividualPdf({
    required MadrassaConfig config,
    required String studentId,
    required Map<String, dynamic> studentData,
    required List<dynamic> logs,
    List<DateTime> holidays = const [],
  }) async {
    try {
      if (_amiriFont == null) {
        final amiriData = await rootBundle.load('assets/fonts/Amiri-Regular.ttf');
        _amiriFont = pw.Font.ttf(amiriData);
      }

    final pdf = pw.Document(
      theme: pw.ThemeData.withFont(
        base: pw.Font.helvetica(),
        bold: pw.Font.helveticaBold(),
      ),
    );

    final monthName = DateFormat('MMMM yyyy').format(DateTime(config.year, config.month));
   final workingDays = MadrassaFeeLogic.getWorkingDaysCount(config.year, config.month, holidays);
    final fee = MadrassaFeeLogic.calculateStudentFee(
      studentId: studentId,
      studentData: studentData,
      logs: logs,
      config: config,
      totalWorkingDays: workingDays,
      holidays: holidays,
    );
    
    // Academic calculations
    final total = 8640;
    final currentTotalLines = (studentData['currentLines'] as num?)?.toInt() ?? int.tryParse(studentData['currentLines']?.toString() ?? '') ?? 0;
    final prevHifzLines = int.tryParse(studentData['prevHifzLines']?.toString() ?? '0') ?? 0;
    
    final joinDate = MadrassaFeeLogic.parseStudentJoinDate(studentData) ?? _parseJoinDate(studentData['joinDate']);
    final joinDateStr = joinDate != null ? DateFormat('dd MMMM yyyy').format(joinDate) : 'Not Provided';
    
    final joinZero = joinDate != null ? DateTime(joinDate.year, joinDate.month, joinDate.day) : null;
    final now = DateTime.now();
    final nowZero = DateTime(now.year, now.month, now.day);
    final daysEnrolled = joinZero != null ? nowZero.difference(joinZero).inDays.clamp(1, 99999) : 1;

    final branchId = (studentData['branchId']?.toString() ?? config.id).toLowerCase().trim();
    final paymentRecord = MadrassaLocalStorage.getFeePaymentCached(branchId, config.year, config.month, studentId);
    final due = (fee['amountDue'] as num).toDouble();
    final paymentStatus = paymentRecord?['status']?.toString() ?? (due <= 0 ? 'paid' : 'unpaid');
    final amountPaid = (paymentRecord?['amountPaid'] as num?)?.toDouble() ?? (paymentStatus == 'paid' ? due : 0.0);
    final isPaid = paymentStatus == 'paid';

    double totalHistoricalPendingDues = 0.0;
    int unpaidMonthsCount = 0;
    if (joinDate != null && config.enableFees) {
      final startMonth = DateTime(joinDate.year, joinDate.month, 1);
      final endMonth = DateTime(DateTime.now().year, DateTime.now().month, 1);
      DateTime iter = DateTime(endMonth.year, endMonth.month, 1);
      while (!iter.isBefore(startMonth)) {
        final y = iter.year;
        final m = iter.month;
        final pRec = MadrassaLocalStorage.getFeePaymentCached(branchId, y, m, studentId);
        final mConf = config.copyWith(year: y, month: m);
        final mWorkingDays = MadrassaFeeLogic.getWorkingDaysCount(y, m, holidays);
        final mLogs = MadrassaLocalStorage.getLogsForMonthCached(branchId, y, m);
        final mFee = MadrassaFeeLogic.calculateStudentFee(
          studentId: studentId,
          studentData: studentData,
          logs: mLogs,
          config: mConf,
          totalWorkingDays: mWorkingDays,
          holidays: holidays,
        );
        final mDue = ((mFee['amountDue'] as num?) ?? 0.0).toDouble();
        final mStatus = pRec?['status']?.toString() ?? (mDue <= 0 ? 'paid' : 'unpaid');
        final activeDays = (mFee['activeWorkingDays'] as num?)?.toInt() ?? 0;
        if (activeDays > 0 && mStatus != 'paid' && mDue > 0) {
          totalHistoricalPendingDues += mDue;
          unpaidMonthsCount++;
        }
        if (iter.month == 1) {
          iter = DateTime(iter.year - 1, 12, 1);
        } else {
          iter = DateTime(iter.year, iter.month - 1, 1);
        }
      }
    }
    
    final acad = getAcademicProgress(studentId: studentId, logs: logs);
    final linesMemorized = acad['linesMemorized'] as int;
    final latestSabkiPara = acad['sabkiPara'] as int;
    final latestSabkiRatio = acad['sabkiRatio'] as String;
    final latestManzilPara = acad['manzilPara'] as int;
    final latestManzilRatio = acad['manzilRatio'] as String;

    final linesMemorizedHere = (currentTotalLines - prevHifzLines).clamp(0, total);
    final double overallPace = (linesMemorizedHere / daysEnrolled).clamp(0.0, total.toDouble());
    final remainingLines = (total - currentTotalLines).clamp(0, total);
    final double daysRemaining = overallPace > 0.0001 ? (remainingLines / overallPace) : 0.0;
    final paceWeekly = overallPace * 7;
    
    String estCompletionStr = '—';
    if (overallPace > 0) {
      final int totalDays = daysRemaining.round();
      final int years = totalDays ~/ 365;
      final int months = (totalDays % 365) ~/ 30;
      final int remainingDays = (totalDays % 365) % 30;
      final parts = <String>[];
      if (years > 0) parts.add('$years ${years == 1 ? "yr" : "yrs"}');
      if (months > 0) parts.add('$months ${months == 1 ? "mo" : "mos"}');
      if (years == 0 && months == 0) parts.add('$remainingDays ${remainingDays == 1 ? "day" : "days"}');
      estCompletionStr = parts.join(', ');
    }

    final photoUrl = studentData['photoUrl'];

    // Wrapped in an async closure (rather than calling Uri.parse / http.get
    // directly inside the Future.wait list) so a malformed photoUrl throws
    // *inside* the future and gets caught here, instead of throwing
    // synchronously and killing the whole export before it starts.
    //
    // FIX — photo not showing: the timeout was 1200ms, which is too short
    // for a real Firebase Storage download URL (auth/redirect roundtrip +
    // actual image bytes) on anything but a very fast connection. The
    // request would get cancelled before it completed and the photo would
    // silently never appear. Bumped to 8s, and now logs *why* a fetch
    // failed (bad status code vs. timeout vs. parse error) instead of
    // swallowing every failure silently.
    Future<http.Response?> fetchPhoto() async {
      if (photoUrl == null || photoUrl.toString().trim().isEmpty) return null;
      try {
        final uri = Uri.tryParse(photoUrl.toString().trim());
        if (uri == null) {
          debugPrint('Student photo: could not parse photoUrl "$photoUrl"');
          return null;
        }
        final response = await http.get(uri).timeout(const Duration(seconds: 8));
        if (response.statusCode != 200) {
          debugPrint('Student photo fetch failed: HTTP ${response.statusCode} for $uri');
          return null;
        }
        return response;
      } catch (e) {
        debugPrint('Student photo fetch failed: $e');
        return null;
      }
    }

    // Fetch assets concurrently to maximize speed and bypass slow network hangs
    final List<dynamic> results = await Future.wait([
      rootBundle.load('assets/logo/gmwf-1.webp'),
      fetchPhoto(),
    ]);

    final logoData = results[0] as ByteData;
    final logoImage = pw.MemoryImage(logoData.buffer.asUint8List());

    pw.Widget? studentPhotoWidget;
    final photoResponse = results[1] as http.Response?;
    if (photoResponse != null && photoResponse.statusCode == 200) {
      try {
        final image = pw.MemoryImage(photoResponse.bodyBytes);
        studentPhotoWidget = pw.Container(
          width: 90,
          height: 90,
          decoration: pw.BoxDecoration(
            shape: pw.BoxShape.circle,
            border: pw.Border.all(color: PdfColor.fromInt(0xFF008080), width: 2),
          ),
          padding: const pw.EdgeInsets.all(2),
          child: pw.ClipOval(
            child: pw.Image(image, fit: pw.BoxFit.cover),
          ),
        );
      } catch (e) {
        debugPrint('Failed to parse student photo: $e');
      }
    }

    String formatRatio(String ratio) {
      if (ratio == '1/4') return 'Pao (1/4)';
      if (ratio == '1/2') return 'Nisf (1/2)';
      if (ratio == '3/4') return 'Salasa (3/4)';
      if (ratio == '1') return 'Para (1)';
      if (ratio == 'nahi_sunaya') return 'Did not recite';
      return ratio.isEmpty ? '-' : ratio;
    }

    // FIX — Urdu name showing as garbled/boxed unicode: the profile-strip
    // student name was rendered with a plain pw.Text() using the document's
    // default Helvetica font and default (LTR) text direction. Helvetica
    // has no Urdu/Arabic glyphs at all, and without reshaping + RTL
    // direction the joined letterforms break apart even when a font does
    // support them. Every other Urdu string in this file goes through this
    // same reshape + Amiri-font + RTL pattern (see _row/_processUrduCell);
    // the name in the header strip was the one spot that didn't.
    final studentNameRaw = '${studentData['name'] ?? ''}';
    final nameHasUrdu = RegExp(r'[\u0600-\u06FF\u0750-\u077F\uFB50-\uFDFF\uFE70-\uFEFF]').hasMatch(studentNameRaw);
    final studentNameDisplay = nameHasUrdu ? ArabicReshaper().reshape(studentNameRaw) : studentNameRaw;

    pdf.addPage(
      pw.MultiPage(
        pageFormat: PdfPageFormat.a4,
        margin: const pw.EdgeInsets.all(28),
        header: (pw.Context context) {
          if (context.pageNumber > 1) return pw.SizedBox();
          return pw.Column(
            crossAxisAlignment: pw.CrossAxisAlignment.start,
            children: [
              pw.Container(
                padding: const pw.EdgeInsets.symmetric(horizontal: 18, vertical: 14),
                decoration: const pw.BoxDecoration(
                  color: PdfColor.fromInt(0xFF00695C),
                  borderRadius: pw.BorderRadius.all(pw.Radius.circular(10)),
                ),
                child: pw.Row(
                  mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
                  crossAxisAlignment: pw.CrossAxisAlignment.center,
                  children: [
                    pw.Column(
                      crossAxisAlignment: pw.CrossAxisAlignment.start,
                      children: [
                        pw.Text('Gulzar Madina Madrassa', style: pw.TextStyle(fontSize: 18, fontWeight: pw.FontWeight.bold, color: PdfColors.white)),
                        pw.SizedBox(height: 3),
                        pw.Text('Student Report Card  •  $monthName', style: const pw.TextStyle(fontSize: 10, color: PdfColors.teal50)),
                        if (config.year == DateTime.now().year && config.month == DateTime.now().month)
                          pw.Padding(
                            padding: const pw.EdgeInsets.only(top: 4),
                            child: pw.Text(
                              'Compiled till ${DateFormat('dd MMM yyyy').format(DateTime.now())}',
                              style: pw.TextStyle(fontSize: 8, color: PdfColors.teal100, fontStyle: pw.FontStyle.italic),
                            ),
                          ),
                      ],
                    ),
                    pw.ClipOval(
                      child: pw.Container(
                        color: PdfColors.white,
                        width: 40,
                        height: 40,
                        child: pw.Image(logoImage, fit: pw.BoxFit.contain),
                      ),
                    ),
                  ],
                ),
              ),
              pw.SizedBox(height: 16),
            ],
          );
        },
        footer: (pw.Context context) => pw.Align(
          alignment: pw.Alignment.centerRight,
          child: pw.Text('Page ${context.pageNumber} of ${context.pagesCount}', style: const pw.TextStyle(fontSize: 8, color: PdfColors.grey)),
        ),
        build: (pw.Context context) {
          final due = (fee['amountDue'] as num).toDouble();
          return [
            // ── Profile strip ──────────────────────────────────────────
            pw.Container(
              padding: const pw.EdgeInsets.all(14),
              decoration: pw.BoxDecoration(
                color: const PdfColor.fromInt(0xFFF0FDFC),
                borderRadius: pw.BorderRadius.circular(10),
                border: pw.Border.all(color: const PdfColor.fromInt(0xFFCCFBF1)),
              ),
              child: pw.Row(
                crossAxisAlignment: pw.CrossAxisAlignment.center,
                children: [
                  if (studentPhotoWidget != null) ...[
                    studentPhotoWidget,
                    pw.SizedBox(width: 14),
                  ],
                  pw.Expanded(
                    child: pw.Column(
                      crossAxisAlignment: pw.CrossAxisAlignment.start,
                      children: [
                        pw.Text(
                          studentNameDisplay,
                          style: pw.TextStyle(
                            font: nameHasUrdu ? _amiriFont : null,
                            fontSize: 17,
                            fontWeight: pw.FontWeight.bold,
                            color: const PdfColor.fromInt(0xFF0F172A),
                          ),
                          textDirection: nameHasUrdu ? pw.TextDirection.rtl : null,
                        ),
                        pw.SizedBox(height: 5),
                        pw.Wrap(
                          spacing: 16,
                          runSpacing: 4,
                          children: [
                            pw.Text('Roll # ${studentData['rollNumber'] ?? '-'}', style: const pw.TextStyle(fontSize: 9.5, color: PdfColor.fromInt(0xFF475569))),
                            pw.Text('Joined: $joinDateStr', style: const pw.TextStyle(fontSize: 9.5, color: PdfColor.fromInt(0xFF475569))),
                          ],
                        ),
                      ],
                    ),
                  ),
                  pw.SizedBox(width: 10),
                  pw.Container(
                    padding: const pw.EdgeInsets.symmetric(horizontal: 14, vertical: 9),
                    decoration: pw.BoxDecoration(
                      color: isPaid || due <= 0 ? const PdfColor.fromInt(0xFFDFF5E1) : const PdfColor.fromInt(0xFFFBE0E0),
                      borderRadius: pw.BorderRadius.circular(8),
                    ),
                    child: pw.Column(
                      crossAxisAlignment: pw.CrossAxisAlignment.end,
                      children: [
                        pw.Text(
                          isPaid ? 'STATUS: PAID' : (due <= 0 ? 'STATUS: WAIVED' : 'STATUS: UNPAID'),
                          style: pw.TextStyle(
                            fontSize: 7,
                            fontWeight: pw.FontWeight.bold,
                            color: isPaid || due <= 0 ? const PdfColor.fromInt(0xFF0F766E) : const PdfColor.fromInt(0xFF991B1B),
                          ),
                        ),
                        pw.SizedBox(height: 2),
                        pw.Text(
                          isPaid
                              ? 'Rs. ${amountPaid.toStringAsFixed(0)} (Paid)'
                              : (due <= 0 ? 'Rs. 0 (Waived)' : 'Rs. ${due.toStringAsFixed(0)} Due'),
                          style: pw.TextStyle(
                            fontSize: 14,
                            fontWeight: pw.FontWeight.bold,
                            color: isPaid || due <= 0 ? const PdfColor.fromInt(0xFF166534) : const PdfColor.fromInt(0xFFB91C1C),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            pw.SizedBox(height: 10),

            // ── Monthly snapshot stat tiles ────────────────────────────
            _sectionHeader('MONTHLY SNAPSHOT'),
            pw.SizedBox(height: 6),
            pw.Row(
              children: [
                pw.Expanded(child: _statTile('Active', '${fee['activeWorkingDays']}', const PdfColor.fromInt(0xFF64748B))),
                pw.SizedBox(width: 8),
                pw.Expanded(child: _statTile('Present', '${fee['present']}', const PdfColor.fromInt(0xFF16A34A))),
                pw.SizedBox(width: 8),
                pw.Expanded(child: _statTile('Absent', '${fee['absent']}', const PdfColor.fromInt(0xFFDC2626))),
                pw.SizedBox(width: 8),
                pw.Expanded(child: _statTile('Leave', '${fee['leave']}', const PdfColor.fromInt(0xFFD97706))),
                pw.SizedBox(width: 8),
                pw.Expanded(child: _statTile('Uniform', '${fee['uniform']}/${fee['activeWorkingDays']}', const PdfColor.fromInt(0xFF0EA5E9))),
              ],
            ),
            pw.SizedBox(height: 12),

            // ── Academic progress ───────────────────────────────────────
            _sectionHeader('ACADEMIC PROGRESS'),
            pw.SizedBox(height: 6),
            pw.Container(
              padding: const pw.EdgeInsets.symmetric(horizontal: 12),
              decoration: pw.BoxDecoration(
                color: PdfColors.white,
                borderRadius: pw.BorderRadius.circular(8),
                border: pw.Border.all(color: const PdfColor.fromInt(0xFFE2E8F0)),
              ),
              child: pw.Column(
                children: [
                  _row('Lines Memorized This Month', '$linesMemorized lines'),
                  _row('Total Cumulative Lines', '$currentTotalLines of 8,640 (${(currentTotalLines / 8640 * 100).toStringAsFixed(1)}%)'),
                  _row('Latest Sabki Progress', latestSabkiPara > 0 ? 'Para $latestSabkiPara (${formatRatio(latestSabkiRatio)})' : (latestSabkiRatio == 'nahi_sunaya' ? 'Did not recite' : 'No recitation')),
                  _row('Latest Manzil Progress', latestManzilPara > 0 ? 'Para $latestManzilPara (${formatRatio(latestManzilRatio)})' : (latestManzilRatio == 'nahi_sunaya' ? 'Did not recite' : 'No recitation')),
                  _row('Remaining Lines', '$remainingLines lines'),
                  _row('Weekly Pace', '${paceWeekly.toStringAsFixed(1)} lines/week'),
                  _row('Est. Completion Time', estCompletionStr, isLast: true),
                ],
              ),
            ),
            if (config.enableFees) ...[
              pw.SizedBox(height: 12),
              // ── Financial summary ───────────────────────────────────────
              _sectionHeader('FINANCIAL SUMMARY'),
              pw.SizedBox(height: 6),
              pw.Container(
                padding: const pw.EdgeInsets.symmetric(horizontal: 12),
                decoration: pw.BoxDecoration(
                  color: PdfColors.white,
                  borderRadius: pw.BorderRadius.circular(8),
                  border: pw.Border.all(color: const PdfColor.fromInt(0xFFE2E8F0)),
                ),
                child: pw.Column(
                  children: [
                    _row('Base Fee', 'Rs. ${config.baseFee.toStringAsFixed(0)}'),
                    if (config.baseFee - fee['proRatedBaseFee'] > 0.5)
                      _row(
                        'Holiday Adjustment (${fee['activeWorkingDays']}/${workingDays} days)',
                        '- Rs. ${(config.baseFee - fee['proRatedBaseFee']).toStringAsFixed(0)}',
                      ),
                    _row('Attendance Savings (${fee['present'] + fee['leave']}/${fee['activeWorkingDays']} present/leave)', '- Rs. ${fee['attSavings'].toStringAsFixed(0)}'),
                    _row('Uniform Savings (${fee['uniform']}/${fee['activeWorkingDays']} clean)', '- Rs. ${fee['uniSavings'].toStringAsFixed(0)}'),
                    _row('Message Savings (${fee['message']}/${fee['activeWorkingDays']} replied)', '- Rs. ${fee['msgSavings'].toStringAsFixed(0)}'),
                    _row('PTM Savings (${fee['ptm'] ? 'Attended' : 'Missed'})', '- Rs. ${fee['ptmSavings'].toStringAsFixed(0)}'),
                    _row(
                      'Payment Status',
                      isPaid
                          ? 'PAID (Rs. ${amountPaid.toStringAsFixed(0)})'
                          : (due <= 0 ? 'WAIVED (Rs. 0)' : 'UNPAID (Pending Rs. ${due.toStringAsFixed(0)})'),
                      isLast: true,
                    ),
                  ],
                ),
              ),
              pw.SizedBox(height: 8),
              pw.Container(
                width: double.infinity,
                padding: const pw.EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                decoration: pw.BoxDecoration(
                  color: const PdfColor.fromInt(0xFFE0F2F1),
                  borderRadius: pw.BorderRadius.circular(8),
                  border: pw.Border.all(color: const PdfColor.fromInt(0xFF00695C), width: 0.75),
                ),
                child: pw.Row(
                  mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
                  children: [
                    pw.Text('MONTH NET AMOUNT DUE', style: pw.TextStyle(fontSize: 10, fontWeight: pw.FontWeight.bold, color: const PdfColor.fromInt(0xFF0F766E))),
                    pw.Text('Rs. ${due.toStringAsFixed(0)}', style: pw.TextStyle(fontSize: 15, fontWeight: pw.FontWeight.bold, color: const PdfColor.fromInt(0xFF004D40))),
                  ],
                ),
              ),
              if (totalHistoricalPendingDues > 0) ...[
                pw.SizedBox(height: 8),
                pw.Container(
                  width: double.infinity,
                  padding: const pw.EdgeInsets.symmetric(horizontal: 14, vertical: 9),
                  decoration: pw.BoxDecoration(
                    color: const PdfColor.fromInt(0xFFFEF2F2),
                    borderRadius: pw.BorderRadius.circular(8),
                    border: pw.Border.all(color: const PdfColor.fromInt(0xFFEF4444), width: 0.75),
                  ),
                  child: pw.Row(
                    mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
                    children: [
                      pw.Text('TOTAL OUTSTANDING PENDING DUES (ALL MONTHS)', style: pw.TextStyle(fontSize: 8.5, fontWeight: pw.FontWeight.bold, color: const PdfColor.fromInt(0xFF991B1B))),
                      pw.Text('Rs. ${totalHistoricalPendingDues.toStringAsFixed(0)} ($unpaidMonthsCount Unpaid Month(s))', style: pw.TextStyle(fontSize: 10, fontWeight: pw.FontWeight.bold, color: const PdfColor.fromInt(0xFFDC2626))),
                    ],
                  ),
                ),
              ],
            ],
            // Attendance & Compliance Details section removed from the PDF
            // per request — it's still available in the Excel export via
            // getAttendanceDetails(), just not rendered here anymore.
          ];
        },
      ),
    );

    final bytes = await pdf.save();
    await _saveAndNotify('Report_${studentData['name']}_$monthName.pdf', bytes);
    } catch (e, st) {
      debugPrint('Individual PDF export failed: $e\n$st');
      final context = navigatorKey.currentContext;
      if (context != null) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to generate report: $e')),
        );
      }
      rethrow;
    }
  }

  static Future<void> exportIndividualExcel({
    required MadrassaConfig config,
    required String studentId,
    required Map<String, dynamic> studentData,
    required List<dynamic> logs,
    List<DateTime> holidays = const [],
  }) async {
    try {
    final excel = Excel.createExcel();
    final String sheetName = 'Report Card';
    excel.rename('Sheet1', sheetName);
    final Sheet sheet = excel[sheetName];
    excel.setDefaultSheet(sheetName);
    
    final monthName = DateFormat('MMMM yyyy').format(DateTime(config.year, config.month));
    final workingDays = MadrassaFeeLogic.getWorkingDaysCount(config.year, config.month, holidays);
    final fee = MadrassaFeeLogic.calculateStudentFee(
      studentId: studentId,
      studentData: studentData,
      logs: logs,
      config: config,
      totalWorkingDays: workingDays,
      holidays: holidays,
    );

    // Academic calculations
    final total = 8640;
    final currentTotalLines = (studentData['currentLines'] as num?)?.toInt() ?? int.tryParse(studentData['currentLines']?.toString() ?? '') ?? 0;
    final prevHifzLines = int.tryParse(studentData['prevHifzLines']?.toString() ?? '0') ?? 0;
    
    final joinDate = _parseJoinDate(studentData['joinDate']);
    final joinDateStr = joinDate != null ? DateFormat('dd MMMM yyyy').format(joinDate) : 'Not Provided';
    
    final joinZero = joinDate != null ? DateTime(joinDate.year, joinDate.month, joinDate.day) : null;
    final now = DateTime.now();
    final nowZero = DateTime(now.year, now.month, now.day);
    final daysEnrolled = joinZero != null ? nowZero.difference(joinZero).inDays.clamp(1, 99999) : 1;
    
    final acad = getAcademicProgress(studentId: studentId, logs: logs);
    final attendanceDetails = getAttendanceDetails(studentId: studentId, logs: logs);
    final linesMemorized = acad['linesMemorized'] as int;
    final latestSabkiPara = acad['sabkiPara'] as int;
    final latestSabkiRatio = acad['sabkiRatio'] as String;
    final latestManzilPara = acad['manzilPara'] as int;
    final latestManzilRatio = acad['manzilRatio'] as String;

    String joinDates(List<String> dates) => dates.isEmpty ? 'None' : dates.join(', ');

    final linesMemorizedHere = (currentTotalLines - prevHifzLines).clamp(0, total);
    final double overallPace = (linesMemorizedHere / daysEnrolled).clamp(0.0, total.toDouble());
    final remainingLines = (total - currentTotalLines).clamp(0, total);
    final double daysRemaining = overallPace > 0.0001 ? (remainingLines / overallPace) : 0.0;
    final paceWeekly = overallPace * 7;
    
    String estCompletionStr = '—';
    if (overallPace > 0) {
      final int totalDays = daysRemaining.round();
      final int years = totalDays ~/ 365;
      final int months = (totalDays % 365) ~/ 30;
      final int remainingDays = (totalDays % 365) % 30;
      final parts = <String>[];
      if (years > 0) parts.add('$years ${years == 1 ? "year" : "years"}');
      if (months > 0) parts.add('$months ${months == 1 ? "month" : "months"}');
      if (years == 0 && months == 0) parts.add('$remainingDays ${remainingDays == 1 ? "day" : "days"}');
      estCompletionStr = parts.join(', ');
    }

    // Styling
    final headerStyle = CellStyle(
      bold: true,
      backgroundColorHex: ExcelColor.fromHexString('#008080'), // Teal
      fontColorHex: ExcelColor.fromHexString('#FFFFFF'),
    );
    final labelStyle = CellStyle(bold: true, backgroundColorHex: ExcelColor.fromHexString('#E0F2F1')); // Light Teal
    final totalStyle = CellStyle(bold: true, fontColorHex: ExcelColor.fromHexString('#D32F2F'), fontSize: 12);

    sheet.setColumnWidth(0, 25);
    sheet.setColumnWidth(1, 35);

    // Header Branding
    try {
      final ByteData data = await rootBundle.load('assets/logo/gmwf-1.webp');
      final Uint8List imageBytes = data.buffer.asUint8List();
      (excel as dynamic).insertImage(sheetName, imageBytes, 0, 0);
    } catch (e) {
      debugPrint("Excel Logo Error: $e");
    }

    // Title Section
    var titleCell = sheet.cell(CellIndex.indexByColumnRow(columnIndex: 0, rowIndex: 0));
    titleCell.value = TextCellValue('Gulzar Madina Welfare Foundation');
    titleCell.cellStyle = CellStyle(bold: true, fontSize: 16, fontColorHex: ExcelColor.fromHexString('#008080')); // Teal
    sheet.merge(CellIndex.indexByColumnRow(columnIndex: 0, rowIndex: 0), CellIndex.indexByColumnRow(columnIndex: 5, rowIndex: 1));

    sheet.cell(CellIndex.indexByColumnRow(columnIndex: 0, rowIndex: 2)).value = TextCellValue('Student Report Card - $monthName');
    sheet.cell(CellIndex.indexByColumnRow(columnIndex: 0, rowIndex: 2)).cellStyle = CellStyle(italic: true, fontColorHex: ExcelColor.fromHexString('#004D40'));
    sheet.merge(CellIndex.indexByColumnRow(columnIndex: 0, rowIndex: 2), CellIndex.indexByColumnRow(columnIndex: 5, rowIndex: 2));

    if (config.year == DateTime.now().year && config.month == DateTime.now().month) {
      var statusCell = sheet.cell(CellIndex.indexByColumnRow(columnIndex: 0, rowIndex: 3));
      statusCell.value = TextCellValue('Report Status: Data compiled till today (${DateFormat('yyyy-MM-dd').format(DateTime.now())})');
      statusCell.cellStyle = CellStyle(italic: true, fontColorHex: ExcelColor.fromHexString('#C62828'));
      sheet.merge(CellIndex.indexByColumnRow(columnIndex: 0, rowIndex: 3), CellIndex.indexByColumnRow(columnIndex: 5, rowIndex: 3));
    }
    
    // Info Section
    int r = 5;
    void addInfo(String label, String value) {
      sheet.cell(CellIndex.indexByColumnRow(columnIndex: 0, rowIndex: r)).value = TextCellValue(label);
      sheet.cell(CellIndex.indexByColumnRow(columnIndex: 0, rowIndex: r)).cellStyle = labelStyle;
      sheet.cell(CellIndex.indexByColumnRow(columnIndex: 1, rowIndex: r)).value = TextCellValue(value);
      r++;
    }

    addInfo('Student Name', '${studentData['name'] ?? ''}');
    addInfo('Roll Number', '${studentData['rollNumber'] ?? ''}');
    addInfo('Class', studentData['class'] ?? 'Hifz');
    addInfo('Joining Date', joinDateStr);
    
    r++; // Spacer
    
    // Stats Header
    var statsHeader = sheet.cell(CellIndex.indexByColumnRow(columnIndex: 0, rowIndex: r));
    statsHeader.value = TextCellValue('ACADEMIC PROGRESS');
    statsHeader.cellStyle = headerStyle;
    sheet.merge(CellIndex.indexByColumnRow(columnIndex: 0, rowIndex: r), CellIndex.indexByColumnRow(columnIndex: 1, rowIndex: r));
    r++;

    void addStat(String label, dynamic val) {
      sheet.cell(CellIndex.indexByColumnRow(columnIndex: 0, rowIndex: r)).value = TextCellValue(label);
      sheet.cell(CellIndex.indexByColumnRow(columnIndex: 1, rowIndex: r)).value = val is int ? IntCellValue(val) : TextCellValue(val.toString());
      r++;
    }

    String formatRatio(String ratio) {
      if (ratio == '1/4') return 'Pao (1/4)';
      if (ratio == '1/2') return 'Nisf (1/2)';
      if (ratio == '3/4') return 'Salasa (3/4)';
      if (ratio == '1') return 'Para (1)';
      if (ratio == 'nahi_sunaya') return 'Did not recite';
      return ratio.isEmpty ? '-' : ratio;
    }

    addStat('Present Days', fee['present']);
    addStat('Absent Days', fee['absent']);
    addStat('Leave Days', fee['leave']);
    addStat('Uniform Clean Days', '${fee['uniform']}/${fee['activeWorkingDays']}');
    addStat('Lines Memorized This Month', linesMemorized);
    addStat('Total Cumulative Lines', '$currentTotalLines / 8,640 (${(currentTotalLines / 8640 * 100).toStringAsFixed(1)}%)');
    addStat('Latest Sabki Progress', latestSabkiPara > 0 ? 'Para $latestSabkiPara (${formatRatio(latestSabkiRatio)})' : (latestSabkiRatio == 'nahi_sunaya' ? 'Did not recite' : 'No recitation'));
    addStat('Latest Manzil Progress', latestManzilPara > 0 ? 'Para $latestManzilPara (${formatRatio(latestManzilRatio)})' : (latestManzilRatio == 'nahi_sunaya' ? 'Did not recite' : 'No recitation'));
    addStat('Remaining Lines', remainingLines);
    addStat('Weekly Pace', '${paceWeekly.toStringAsFixed(1)} lines/week');
    addStat('Est. Completion Time', estCompletionStr);
    
    if (config.enableFees) {
      r++; // Spacer

      // Financial Header
      var finHeader = sheet.cell(CellIndex.indexByColumnRow(columnIndex: 0, rowIndex: r));
      finHeader.value = TextCellValue('FINANCIAL SUMMARY');
      finHeader.cellStyle = headerStyle;
      sheet.merge(CellIndex.indexByColumnRow(columnIndex: 0, rowIndex: r), CellIndex.indexByColumnRow(columnIndex: 1, rowIndex: r));
      r++;

      void addFin(String label, double val, {bool isTotal = false}) {
        sheet.cell(CellIndex.indexByColumnRow(columnIndex: 0, rowIndex: r)).value = TextCellValue(label);
        if (isTotal) sheet.cell(CellIndex.indexByColumnRow(columnIndex: 0, rowIndex: r)).cellStyle = labelStyle;
        
        var valCell = sheet.cell(CellIndex.indexByColumnRow(columnIndex: 1, rowIndex: r));
        valCell.value = DoubleCellValue(val.roundToDouble());
        if (isTotal) valCell.cellStyle = totalStyle;
        r++;
      }

      addFin('Base Fee', config.baseFee.toDouble());
      addFin('Attendance Savings', (fee['attSavings'] as num).toDouble());
      addFin('Uniform Savings', (fee['uniSavings'] as num).toDouble());
      addFin('Message Savings', (fee['msgSavings'] as num).toDouble());
      addFin('PTM Savings', (fee['ptmSavings'] as num).toDouble());
      r++;
      addFin('TOTAL AMOUNT DUE', (fee['amountDue'] as num).toDouble(), isTotal: true);
    }

    r++; // Spacer

    // Attendance & Compliance Details Header (kept in Excel — only removed
    // from the PDF per request)
    var detailsHeader = sheet.cell(CellIndex.indexByColumnRow(columnIndex: 0, rowIndex: r));
    detailsHeader.value = TextCellValue('ATTENDANCE & COMPLIANCE DETAILS');
    detailsHeader.cellStyle = headerStyle;
    sheet.merge(CellIndex.indexByColumnRow(columnIndex: 0, rowIndex: r), CellIndex.indexByColumnRow(columnIndex: 1, rowIndex: r));
    r++;

    void addDetailRow(String label, List<String> dates) {
      sheet.cell(CellIndex.indexByColumnRow(columnIndex: 0, rowIndex: r)).value = TextCellValue(label);
      sheet.cell(CellIndex.indexByColumnRow(columnIndex: 0, rowIndex: r)).cellStyle = labelStyle;
      sheet.cell(CellIndex.indexByColumnRow(columnIndex: 1, rowIndex: r)).value = TextCellValue(joinDates(dates));
      r++;
    }

    addDetailRow('Absent Dates', attendanceDetails['absent']!);
    addDetailRow('Leave Dates', attendanceDetails['leave']!);
    addDetailRow('Uniform Not Proper', attendanceDetails['uniformNotProper']!);
    addDetailRow('Message Not Replied', attendanceDetails['messageNotReplied']!);

    final fileBytes = excel.save();
    if (fileBytes != null) {
      await _saveAndNotify('Report_${studentData['name']}_$monthName.xlsx', Uint8List.fromList(fileBytes));
    }
    } catch (e, st) {
      debugPrint('Individual Excel export failed: $e\n$st');
      final context = navigatorKey.currentContext;
      if (context != null) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to generate report: $e')),
        );
      }
      rethrow;
    }
  }

  static Future<void> exportDailyPdf({
    required MadrassaConfig config,
    required DateTime selectedDate,
    required List<dynamic> students,
    required Map<String, dynamic> logData,
  }) async {
    if (_amiriFont == null) {
      final amiriData = await rootBundle.load('assets/fonts/Amiri-Regular.ttf');
      _amiriFont = pw.Font.ttf(amiriData);
    }

    final pdf = pw.Document(
      theme: pw.ThemeData.withFont(
        base: pw.Font.helvetica(),
        bold: pw.Font.helveticaBold(),
      ),
    );

    final dateStr = DateFormat('dd-MM-yyyy').format(selectedDate);
    final dateLabelStr = DateFormat('dd MMMM yyyy').format(selectedDate);
    final logoData = await rootBundle.load('assets/logo/gmwf-1.webp');
    final logoImage = pw.MemoryImage(logoData.buffer.asUint8List());

    // Calculate attendance stats
    int presentCount = 0;
    int leaveCount = 0;
    int absentCount = 0;

    for (final s in students) {
      final sId = s is DocumentSnapshot ? s.id : (s as Map)['id']?.toString() ?? '';
      final log = _asStringMap(logData[sId]) ?? {};
      final att = log['attendance']?.toString() ?? 'absent';
      if (att == 'present') {
        presentCount++;
      } else if (att == 'leave') {
        leaveCount++;
      } else {
        absentCount++;
      }
    }

    String formatRatioCompact(String ratio) {
      if (ratio == '1/4') return '1/4';
      if (ratio == '1/2') return '1/2';
      if (ratio == '3/4') return '3/4';
      if (ratio == '1') return '1';
      if (ratio == 'nahi_sunaya') return 'NS';
      return ratio;
    }

    pdf.addPage(
      pw.MultiPage(
        pageFormat: PdfPageFormat.a4,
        margin: const pw.EdgeInsets.all(32),
        header: (pw.Context context) => pw.Column(
          crossAxisAlignment: pw.CrossAxisAlignment.start,
          children: [
            pw.Container(
              padding: const pw.EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              decoration: const pw.BoxDecoration(
                color: PdfColor.fromInt(0xFF00695C),
                borderRadius: pw.BorderRadius.all(pw.Radius.circular(8)),
              ),
              child: pw.Row(
                mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
                children: [
                  pw.Column(
                    crossAxisAlignment: pw.CrossAxisAlignment.start,
                    children: [
                      pw.Text(
                        'Gulzar Madina Madrassa',
                        style: pw.TextStyle(
                          fontSize: 18,
                          fontWeight: pw.FontWeight.bold,
                          color: PdfColors.white,
                        ),
                      ),
                      pw.SizedBox(height: 4),
                      pw.Text(
                        'Daily Progress Report - $dateLabelStr',
                        style: const pw.TextStyle(
                          fontSize: 11,
                          color: PdfColors.teal50,
                        ),
                      ),
                    ],
                  ),
                  pw.ClipOval(
                    child: pw.Container(
                      color: PdfColors.white,
                      width: 36,
                      height: 36,
                      child: pw.Image(logoImage, fit: pw.BoxFit.contain),
                    ),
                  ),
                ],
              ),
            ),
            pw.SizedBox(height: 16),
          ],
        ),
        build: (pw.Context context) {
          return [
            // Stats summary row
            pw.Container(
              padding: const pw.EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: pw.BoxDecoration(
                color: const PdfColor.fromInt(0xFFF1F5F9),
                borderRadius: pw.BorderRadius.circular(6),
                border: pw.Border.all(color: const PdfColor.fromInt(0xFFCBD5E1), width: 0.5),
              ),
              child: pw.Row(
                mainAxisAlignment: pw.MainAxisAlignment.spaceAround,
                children: [
                  _totalChip('Total Students', '${students.length}'),
                  _totalChip('Present', '$presentCount'),
                  _totalChip('Leave', '$leaveCount'),
                  _totalChip('Absent', '$absentCount'),
                ],
              ),
            ),
            pw.SizedBox(height: 16),
            
            // Student list table
            pw.TableHelper.fromTextArray(
              headers: const [
                '#', 'Student', 'Roll', 'Attendance', 'Reply', 'Uniform', 'Sabak', 'Sabki', 'Manzil'
              ],
              data: List.generate(students.length, (i) {
                final s = students[i];
                final sData = s is DocumentSnapshot ? (_asStringMap(s.data()) ?? <String, dynamic>{}) : Map<String, dynamic>.from(s as Map);
                final sId = s is DocumentSnapshot ? s.id : (s as Map)['id']?.toString() ?? '';
                final log = _asStringMap(logData[sId]) ?? {};
                
                final att = log['attendance']?.toString() ?? 'absent';
                final uni = log['uniform'] == true;
                final parentReplied = log['parentReplied'] == true;

                String attText = 'Absent';
                if (att == 'present') {
                  attText = 'Present';
                } else if (att == 'leave') {
                  attText = 'Leave';
                }

                String replyText = parentReplied ? 'Yes' : 'No';

                String uniformText = '-';
                String sabakText = '-';
                String sabkiText = '-';
                String manzilText = '-';

                if (att == 'present') {
                  uniformText = uni ? 'Clean' : 'Not Clean';
                  
                  final int lines = (log.containsKey('sabakLines') && log['sabakLines'] != null)
                      ? ((log['sabakLines'] as num?)?.toInt() ?? 0)
                      : (log['currentLines'] is int ? log['currentLines'] as int : (int.tryParse(log['currentLines']?.toString() ?? '') ?? 0));
                  sabakText = lines > 0 ? '$lines lines' : '-';

                  final int sabkiPara = log['sabkiPara'] is int ? log['sabkiPara'] as int : (int.tryParse(log['sabkiPara']?.toString() ?? '') ?? 0);
                  final String sabkiRatio = log['sabkiRatio']?.toString() ?? '';
                  sabkiText = sabkiPara > 0
                      ? 'Para $sabkiPara (${formatRatioCompact(sabkiRatio)})'
                      : (sabkiRatio == 'nahi_sunaya' ? 'NS' : '-');

                  final int manzilPara = log['manzilPara'] is int ? log['manzilPara'] as int : (int.tryParse(log['manzilPara']?.toString() ?? '') ?? 0);
                  final String manzilRatio = log['manzilRatio']?.toString() ?? '';
                  manzilText = manzilPara > 0
                      ? 'Para $manzilPara (${formatRatioCompact(manzilRatio)})'
                      : (manzilRatio == 'nahi_sunaya' ? 'NS' : '-');
                }

                return [
                  '${i + 1}',
                  _processUrduCell(sData['name'] ?? '', style: pw.TextStyle(fontSize: 9, fontWeight: pw.FontWeight.bold), alignment: pw.Alignment.centerLeft),
                  '${sData['rollNumber'] ?? ''}',
                  attText,
                  replyText,
                  uniformText,
                  sabakText,
                  sabkiText,
                  manzilText,
                ];
              }),
              headerStyle: pw.TextStyle(fontWeight: pw.FontWeight.bold, fontSize: 9, color: PdfColors.white),
              cellStyle: const pw.TextStyle(fontSize: 8.5),
              headerDecoration: const pw.BoxDecoration(color: PdfColor.fromInt(0xFF00695C)),
              headerPadding: const pw.EdgeInsets.symmetric(horizontal: 4, vertical: 6),
              cellAlignment: pw.Alignment.center,
              cellAlignments: {
                0: pw.Alignment.center,
                1: pw.Alignment.centerLeft,
                2: pw.Alignment.center,
                3: pw.Alignment.center,
                4: pw.Alignment.center,
                5: pw.Alignment.center,
                6: pw.Alignment.center,
                7: pw.Alignment.center,
                8: pw.Alignment.center,
              },
              cellPadding: const pw.EdgeInsets.symmetric(horizontal: 6, vertical: 8),
              columnWidths: {
                0: const pw.FixedColumnWidth(22),
                1: const pw.FlexColumnWidth(3),
                2: const pw.FixedColumnWidth(30),
                3: const pw.FixedColumnWidth(55),
                4: const pw.FixedColumnWidth(40),
                5: const pw.FixedColumnWidth(50),
                6: const pw.FixedColumnWidth(50),
                7: const pw.FixedColumnWidth(60),
                8: const pw.FixedColumnWidth(60),
              },
              border: pw.TableBorder(
                horizontalInside: const pw.BorderSide(color: PdfColor.fromInt(0xFFE2E8F0), width: 0.5),
                verticalInside: const pw.BorderSide(color: PdfColor.fromInt(0xFFE2E8F0), width: 0.5),
                top: const pw.BorderSide(color: PdfColor.fromInt(0xFF00695C), width: 0.75),
                bottom: const pw.BorderSide(color: PdfColor.fromInt(0xFF00695C), width: 0.75),
                left: const pw.BorderSide(color: PdfColor.fromInt(0xFF00695C), width: 0.75),
                right: const pw.BorderSide(color: PdfColor.fromInt(0xFF00695C), width: 0.75),
              ),
              rowDecoration: const pw.BoxDecoration(color: PdfColors.white),
              oddRowDecoration: const pw.BoxDecoration(color: PdfColor.fromInt(0xFFF8FAFC)),
            ),
          ];
        },
        footer: (pw.Context context) => pw.Align(
          alignment: pw.Alignment.centerRight,
          child: pw.Text('Page ${context.pageNumber} of ${context.pagesCount}', style: const pw.TextStyle(fontSize: 8, color: PdfColors.grey)),
        ),
      ),
    );

    final bytes = await pdf.save();
    await _saveAndNotify('Madrassa_Daily_Report_${dateStr}.pdf', bytes);
  }

  static Future<void> _saveAndNotify(String fileName, Uint8List bytes) async {
    try {
      String? finalFilePath;
      final bool isMobile = !kIsWeb && (Platform.isAndroid || Platform.isIOS);

      if (isMobile) {
        if (Platform.isAndroid) {
          final List<String> pathsToTry = [
            '/storage/emulated/0/Download',
            '/storage/emulated/0/Documents',
            '/sdcard/Download',
            '/sdcard/Documents',
          ];
          
          for (final pth in pathsToTry) {
            try {
              final testDir = Directory(pth);
              if (await testDir.exists()) {
                final testPath = p.join(testDir.path, fileName);
                final testFile = File(testPath);
                await testFile.writeAsBytes(bytes);
                finalFilePath = testPath;
                break; // Succeeded!
              }
            } catch (_) {
              // Write failed or directory does not exist, try next
            }
          }
          
          if (finalFilePath == null) {
            // Fallback 1: external app directory
            try {
              final extDir = await getExternalStorageDirectory();
              if (extDir != null) {
                final testPath = p.join(extDir.path, fileName);
                await File(testPath).writeAsBytes(bytes);
                finalFilePath = testPath;
              }
            } catch (_) {}
          }
          
          if (finalFilePath == null) {
            // Fallback 2: temporary directory
            final tempDir = await getTemporaryDirectory();
            final testPath = p.join(tempDir.path, fileName);
            await File(testPath).writeAsBytes(bytes);
            finalFilePath = testPath;
          }
        } else {
          // iOS
          final docDir = await getApplicationDocumentsDirectory();
          final testPath = p.join(docDir.path, fileName);
          await File(testPath).writeAsBytes(bytes);
          finalFilePath = testPath;
        }
      } else {
        // Desktop / Web
        Directory? dir;
        if (!kIsWeb && Platform.isWindows) {
          dir = Directory(p.join(Platform.environment['USERPROFILE']!, 'Downloads'));
        } else {
          dir = await getDownloadsDirectory();
        }
        if (dir != null) {
          finalFilePath = p.join(dir.path, fileName);
          await File(finalFilePath).writeAsBytes(bytes);
        }
      }

      if (finalFilePath != null) {
        // Show dialog with options to Open/Share or Close
        final context = navigatorKey.currentContext;
        if (context != null) {
          showDialog(
            context: context,
            builder: (ctx) => AlertDialog(
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
              title: Text(isMobile ? 'Report Generated ✓' : 'Report Saved ✓'),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(isMobile
                      ? 'The report has been saved to your device. You can open, view, or share it directly.'
                      : 'The report has been saved to your Downloads folder:'),
                  const SizedBox(height: 12),
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(color: Colors.grey.shade100, borderRadius: BorderRadius.circular(8)),
                    child: SelectableText(finalFilePath!,
                        style: const TextStyle(fontSize: 12, fontFamily: 'monospace')),
                  ),
                ],
              ),
              actions: [
                if (!isMobile)
                  TextButton(
                    onPressed: () {
                      Clipboard.setData(ClipboardData(text: finalFilePath!));
                      ScaffoldMessenger.of(ctx).showSnackBar(const SnackBar(content: Text('Path copied to clipboard!')));
                    },
                    child: const Text('COPY PATH'),
                  ),
                TextButton(
                  onPressed: () async {
                    if (isMobile) {
                      await Share.shareXFiles([XFile(finalFilePath!, mimeType: 'application/pdf')], text: fileName);
                    } else {
                      final fileUri = Uri.file(finalFilePath!);
                      await launchUrl(fileUri, mode: LaunchMode.externalApplication);
                    }
                  },
                  child: Text(isMobile ? 'OPEN / SHARE' : 'OPEN FILE'),
                ),
                TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('CLOSE')),
              ],
            ),
          );
        }
      } else {
        // Fallback to printing share
        await Printing.sharePdf(bytes: bytes, filename: fileName);
      }
    } catch (e) {
      // Fallback to printing share
      await Printing.sharePdf(bytes: bytes, filename: fileName);
    }
  }

  static dynamic _processUrduCell(String text, {required pw.TextStyle style, pw.Alignment alignment = pw.Alignment.center}) {
    final hasUrdu = RegExp(r'[\u0600-\u06FF\u0750-\u077F\uFB50-\uFDFF\uFE70-\uFEFF]').hasMatch(text);
    if (hasUrdu) {
      final reshaped = ArabicReshaper().reshape(text);
      return pw.Container(
        alignment: alignment,
        child: pw.Text(
          reshaped,
          style: _amiriFont != null ? style.copyWith(font: _amiriFont) : style,
          textDirection: pw.TextDirection.rtl,
        ),
      );
    }
    return text;
  }

  /// Section title used to separate the major blocks of the individual
  /// report (Monthly Snapshot, Academic Progress, etc). A small teal
  /// accent bar + uppercase label, with a hairline rule trailing off to
  /// the right so it reads as a proper section break rather than just
  /// another bold line of text.
  static pw.Widget _sectionHeader(String title) {
    return pw.Row(
      crossAxisAlignment: pw.CrossAxisAlignment.center,
      children: [
        pw.Container(
          width: 4,
          height: 14,
          decoration: pw.BoxDecoration(
            color: const PdfColor.fromInt(0xFF00695C),
            borderRadius: pw.BorderRadius.circular(2),
          ),
        ),
        pw.SizedBox(width: 8),
        pw.Text(
          title,
          style: pw.TextStyle(
            fontSize: 11,
            fontWeight: pw.FontWeight.bold,
            color: const PdfColor.fromInt(0xFF0F172A),
            letterSpacing: 0.6,
          ),
        ),
        pw.SizedBox(width: 10),
        pw.Expanded(
          child: pw.Container(height: 0.75, color: const PdfColor.fromInt(0xFFE2E8F0)),
        ),
      ],
    );
  }

  /// Compact KPI card used in the "Monthly Snapshot" row (Active / Present
  /// / Absent / Leave / Uniform). Colored top accent bar identifies the
  /// stat at a glance, big number for scanability, small caps label below.
  static pw.Widget _statTile(String label, String value, PdfColor accent) {
    return pw.Container(
      decoration: pw.BoxDecoration(
        color: PdfColors.white,
        borderRadius: pw.BorderRadius.circular(8),
        border: pw.Border.all(color: const PdfColor.fromInt(0xFFE2E8F0)),
      ),
      child: pw.Column(
        crossAxisAlignment: pw.CrossAxisAlignment.stretch,
        children: [
          pw.Container(
            height: 3,
            decoration: pw.BoxDecoration(
              color: accent,
              borderRadius: const pw.BorderRadius.only(
                topLeft: pw.Radius.circular(8),
                topRight: pw.Radius.circular(8),
              ),
            ),
          ),
          pw.Padding(
            padding: const pw.EdgeInsets.symmetric(vertical: 7, horizontal: 6),
            child: pw.Column(
              crossAxisAlignment: pw.CrossAxisAlignment.center,
              children: [
                pw.Text(
                  value,
                  style: pw.TextStyle(fontSize: 16, fontWeight: pw.FontWeight.bold, color: const PdfColor.fromInt(0xFF0F172A)),
                ),
                pw.SizedBox(height: 3),
                pw.Text(
                  label.toUpperCase(),
                  style: pw.TextStyle(fontSize: 7, fontWeight: pw.FontWeight.bold, color: accent, letterSpacing: 0.4),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// Label/value row used inside the Academic Progress and Financial
  /// Summary cards. A thin divider trails each row except the last one
  /// (set [isLast] to true on the final row in a block) so the card looks
  /// like a clean, structured list instead of a stack of plain text lines.
  static pw.Widget _row(String label, String value, {bool isBold = false, bool isLast = false}) {
    final hasUrduVal = RegExp(r'[\u0600-\u06FF\u0750-\u077F\uFB50-\uFDFF\uFE70-\uFEFF]').hasMatch(value);
    final displayValue = hasUrduVal ? ArabicReshaper().reshape(value) : value;

    final hasUrduLabel = RegExp(r'[\u0600-\u06FF\u0750-\u077F\uFB50-\uFDFF\uFE70-\uFEFF]').hasMatch(label);
    final displayLabel = hasUrduLabel ? ArabicReshaper().reshape(label) : label;

    return pw.Container(
      padding: const pw.EdgeInsets.symmetric(vertical: 5),
      decoration: pw.BoxDecoration(
        border: isLast
            ? null
            : const pw.Border(bottom: pw.BorderSide(color: PdfColor.fromInt(0xFFF1F5F9), width: 0.5)),
      ),
      child: pw.Row(
        mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
        children: [
          pw.Expanded(
            child: pw.Text(
              displayLabel,
              style: pw.TextStyle(
                font: hasUrduLabel ? _amiriFont : null,
                fontSize: 9.5,
                fontWeight: isBold ? pw.FontWeight.bold : pw.FontWeight.normal,
                color: const PdfColor.fromInt(0xFF475569),
              ),
              textDirection: hasUrduLabel ? pw.TextDirection.rtl : null,
            ),
          ),
          pw.SizedBox(width: 10),
          pw.Text(
            displayValue,
            style: pw.TextStyle(
              font: hasUrduVal ? _amiriFont : null,
              fontSize: 9.5,
              fontWeight: isBold ? pw.FontWeight.bold : pw.FontWeight.bold,
              color: const PdfColor.fromInt(0xFF0F172A),
            ),
            textDirection: hasUrduVal ? pw.TextDirection.rtl : null,
          ),
        ],
      ),
    );
  }
}