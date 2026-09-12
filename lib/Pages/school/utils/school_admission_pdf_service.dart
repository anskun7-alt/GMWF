// lib/pages/school/utils/school_admission_pdf_service.dart

import 'dart:typed_data';
import 'package:flutter/services.dart' show rootBundle;
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';
import '../models/school_student.dart';
import '../../../services/image_upload_service.dart';

class SchoolAdmissionPdfService {
  static pw.Font? _urduFont;

  static Future<Uint8List> generateAdmissionFormPdf(SchoolStudent student) async {
    if (_urduFont == null) {
      try {
        final fontData = await rootBundle.load('assets/fonts/Amiri-Regular.ttf');
        _urduFont = pw.Font.ttf(fontData);
      } catch (_) {}
    }

    final doc = pw.Document(
      theme: pw.ThemeData.withFont(
        base: _urduFont ?? pw.Font.helvetica(),
        bold: _urduFont ?? pw.Font.helveticaBold(),
      ),
    );

    // Load School Logo
    pw.ImageProvider? logoImage;
    try {
      final logoData = await rootBundle.load('assets/logo/twt.webp');
      logoImage = pw.MemoryImage(logoData.buffer.asUint8List());
    } catch (_) {
      try {
        final logoData = await rootBundle.load('assets/logo/gmwf-1.webp');
        logoImage = pw.MemoryImage(logoData.buffer.asUint8List());
      } catch (_) {}
    }

    // Decode Student Photo if present
    pw.ImageProvider? studentPhoto;
    final photoBytes = ImageUploadService.decodeBase64ToBytes(student.photoUrl);
    if (photoBytes != null && photoBytes.isNotEmpty) {
      studentPhoto = pw.MemoryImage(photoBytes);
    }

    doc.addPage(
      pw.Page(
        pageFormat: PdfPageFormat.a4,
        margin: const pw.EdgeInsets.all(28),
        build: (pw.Context context) {
          return pw.Container(
            padding: const pw.EdgeInsets.all(18),
            decoration: pw.BoxDecoration(
              border: pw.Border.all(color: PdfColors.teal900, width: 2),
              borderRadius: const pw.BorderRadius.all(pw.Radius.circular(8)),
            ),
            child: pw.Column(
              crossAxisAlignment: pw.CrossAxisAlignment.stretch,
              children: [
                // ── Header Banner ────────────────────────────────────────────
                pw.Row(
                  crossAxisAlignment: pw.CrossAxisAlignment.center,
                  mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
                  children: [
                    if (logoImage != null)
                      pw.Container(
                        width: 58,
                        height: 58,
                        child: pw.Image(logoImage),
                      )
                    else
                      pw.SizedBox(width: 58),

                    pw.Expanded(
                      child: pw.Column(
                        children: [
                          pw.Text(
                            'TALEEM-WA-TARBIYAT SCHOOL SYSTEM',
                            style: pw.TextStyle(
                              fontSize: 15,
                              fontWeight: pw.FontWeight.bold,
                              color: PdfColors.teal900,
                            ),
                          ),
                          pw.SizedBox(height: 2),
                          pw.Text(
                            'تعلیم و تربیت سکول سسٹم',
                            textDirection: pw.TextDirection.rtl,
                            style: pw.TextStyle(
                              fontSize: 16,
                              fontWeight: pw.FontWeight.bold,
                              color: PdfColors.teal900,
                            ),
                          ),
                          pw.SizedBox(height: 2),
                          pw.Text(
                            'GULZAR-E-MADINA WELFARE FOUNDATION GUJRAT',
                            style: const pw.TextStyle(fontSize: 8.5, color: PdfColors.grey700),
                          ),
                          pw.Text(
                            'گلزار مدینہ ویلفیئر فاؤنڈیشن گلزار مدینہ روڈ گجرات • Ph: 0334-4687928',
                            textDirection: pw.TextDirection.rtl,
                            style: const pw.TextStyle(fontSize: 8.5, color: PdfColors.grey800),
                          ),
                        ],
                      ),
                    ),

                    // Student Photo Box
                    pw.Container(
                      width: 60,
                      height: 70,
                      decoration: pw.BoxDecoration(
                        border: pw.Border.all(color: PdfColors.grey600, width: 1),
                        borderRadius: const pw.BorderRadius.all(pw.Radius.circular(4)),
                        color: PdfColors.grey100,
                      ),
                      child: studentPhoto != null
                          ? pw.ClipRRect(
                              horizontalRadius: 4,
                              verticalRadius: 4,
                              child: pw.Image(studentPhoto, fit: pw.BoxFit.cover),
                            )
                          : pw.Center(
                              child: pw.Text(
                                'Affix\nPhoto',
                                textAlign: pw.TextAlign.center,
                                style: const pw.TextStyle(fontSize: 8, color: PdfColors.grey600),
                              ),
                            ),
                    ),
                  ],
                ),

                pw.SizedBox(height: 8),

                // Form Title Ribbon
                pw.Container(
                  padding: const pw.EdgeInsets.symmetric(vertical: 5, horizontal: 10),
                  decoration: const pw.BoxDecoration(
                    color: PdfColors.teal800,
                    borderRadius: pw.BorderRadius.all(pw.Radius.circular(4)),
                  ),
                  child: pw.Row(
                    mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
                    children: [
                      pw.Text(
                        'STUDENT ADMISSION & ENROLLMENT FORM',
                        style: pw.TextStyle(
                          color: PdfColors.white,
                          fontSize: 10.5,
                          fontWeight: pw.FontWeight.bold,
                        ),
                      ),
                      pw.Text(
                        'داخلہ فارم',
                        textDirection: pw.TextDirection.rtl,
                        style: pw.TextStyle(
                          color: PdfColors.white,
                          fontSize: 11,
                          fontWeight: pw.FontWeight.bold,
                        ),
                      ),
                    ],
                  ),
                ),

                pw.SizedBox(height: 8),

                // Meta Bar: Date, Roll No, Branch
                pw.Container(
                  padding: const pw.EdgeInsets.symmetric(vertical: 4, horizontal: 8),
                  decoration: pw.BoxDecoration(
                    border: pw.Border.all(color: PdfColors.grey400, width: 0.8),
                    color: PdfColors.grey50,
                  ),
                  child: pw.Row(
                    mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
                    children: [
                      pw.Text(
                        'Admission Date: ${student.admissionDate.isNotEmpty ? student.admissionDate : "—"}',
                        style: pw.TextStyle(fontSize: 9.5, fontWeight: pw.FontWeight.bold),
                      ),
                      pw.Text(
                        'Roll / Admission No: ${student.rollNo}',
                        style: pw.TextStyle(fontSize: 10.5, fontWeight: pw.FontWeight.bold, color: PdfColors.teal900),
                      ),
                      pw.Text(
                        'Branch: ${student.branchId.toUpperCase()}',
                        style: pw.TextStyle(fontSize: 9.5, fontWeight: pw.FontWeight.bold),
                      ),
                    ],
                  ),
                ),

                pw.SizedBox(height: 10),

                // ── Student & Guardian Information Table ─────────────────────
                pw.Table(
                  border: pw.TableBorder.all(color: PdfColors.grey400, width: 0.8),
                  children: [
                    _buildTableRow('Student Name (نام طالب علم):', student.name, 'Date of Birth (تاریخ پیدائش):', student.dob.isNotEmpty ? student.dob : '—'),
                    _buildTableRow('Father / Guardian (والد کا نام):', student.guardianName, 'Gender (جنس):', student.gender),
                    _buildTableRow('B-Form Number (ب فارم نمبر):', student.bformNo.isNotEmpty ? student.bformNo : '—', 'Father CNIC (والد کا شناختی کارڈ):', student.guardianCnic.isNotEmpty ? student.guardianCnic : '—'),
                    _buildTableRow('Class & Section (کلاس اور سیکشن):', '${student.grade} - Sec ${student.section}', 'Academic Group (تعلیمی گروپ):', student.academicGroup),
                    _buildTableRow('Father Profession (پیشہ):', student.fatherProfession.isNotEmpty ? student.fatherProfession : '—', 'Contact Phone (فون نمبر):', student.guardianPhone),
                    _buildTableRow('Biometric PIN (بائیو میٹرک پن):', student.biometricPin.isNotEmpty ? student.biometricPin : '—', 'Previous School (سابقہ ادارہ):', student.previousSchool.isNotEmpty ? student.previousSchool : '—'),
                  ],
                ),

                pw.SizedBox(height: 6),

                // Address Row
                pw.Container(
                  padding: const pw.EdgeInsets.all(6),
                  decoration: pw.BoxDecoration(
                    border: pw.Border.all(color: PdfColors.grey400, width: 0.8),
                    color: PdfColors.white,
                  ),
                  child: pw.Row(
                    children: [
                      pw.Text(
                        'Residential Address (گھر کا پتہ): ',
                        style: pw.TextStyle(fontSize: 9, fontWeight: pw.FontWeight.bold, color: PdfColors.grey800),
                      ),
                      pw.Expanded(
                        child: pw.Text(
                          student.address.isNotEmpty ? student.address : '—',
                          style: const pw.TextStyle(fontSize: 9),
                        ),
                      ),
                    ],
                  ),
                ),

                pw.SizedBox(height: 12),

                // ── Rules & Declaration Section ──────────────────────────────
                pw.Container(
                  padding: const pw.EdgeInsets.all(8),
                  decoration: pw.BoxDecoration(
                    color: PdfColors.grey50,
                    border: pw.Border.all(color: PdfColors.grey300, width: 0.5),
                    borderRadius: const pw.BorderRadius.all(pw.Radius.circular(4)),
                  ),
                  child: pw.Column(
                    crossAxisAlignment: pw.CrossAxisAlignment.start,
                    children: [
                      pw.Text(
                        'Parent / Guardian Undertaking (اقرار نامہ برائے والدین):',
                        style: pw.TextStyle(fontSize: 9, fontWeight: pw.FontWeight.bold, color: PdfColors.teal900),
                      ),
                      pw.SizedBox(height: 3),
                      pw.Text(
                        '1. I hereby confirm that the information provided in this admission form is complete, accurate, and true to the best of my knowledge.',
                        style: const pw.TextStyle(fontSize: 7.5, color: PdfColors.grey700),
                      ),
                      pw.Text(
                        '2. I agree to abide by all the rules, discipline, punctuality, and attendance regulations of Taleem-wa-Tarbiyat School System.',
                        style: const pw.TextStyle(fontSize: 7.5, color: PdfColors.grey700),
                      ),
                      pw.Text(
                        'میں اس بات کا اقرار کرتا / کرتی ہوں کہ داخلہ فارم میں دی گئی تمام معلومات درست ہیں اور میں ادارہ کے تمام قواعد و ضوابط کا پابند رہوں گا/گی۔',
                        textDirection: pw.TextDirection.rtl,
                        style: const pw.TextStyle(fontSize: 7.5, color: PdfColors.grey800),
                      ),
                    ],
                  ),
                ),

                pw.Spacer(),

                // ── Signatures Row ───────────────────────────────────────────
                pw.Row(
                  mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
                  crossAxisAlignment: pw.CrossAxisAlignment.end,
                  children: [
                    pw.Column(
                      children: [
                        pw.Container(width: 140, height: 1, color: PdfColors.grey800),
                        pw.SizedBox(height: 4),
                        pw.Text(
                          'Parent / Guardian Signature\n(دستخط والدین / سرپرست)',
                          textAlign: pw.TextAlign.center,
                          style: pw.TextStyle(fontSize: 8.5, fontWeight: pw.FontWeight.bold),
                        ),
                      ],
                    ),
                    pw.Column(
                      children: [
                        pw.Container(width: 120, height: 1, color: PdfColors.grey800),
                        pw.SizedBox(height: 4),
                        pw.Text(
                          'Admin / Admission Incharge\n(دستخط داخلہ انچارج)',
                          textAlign: pw.TextAlign.center,
                          style: pw.TextStyle(fontSize: 8.5, fontWeight: pw.FontWeight.bold),
                        ),
                      ],
                    ),
                    pw.Column(
                      children: [
                        pw.Container(width: 140, height: 1, color: PdfColors.grey800),
                        pw.SizedBox(height: 4),
                        pw.Text(
                          'Principal Signature & Stamp\n(دستخط پرنسپل و مہر)',
                          textAlign: pw.TextAlign.center,
                          style: pw.TextStyle(fontSize: 8.5, fontWeight: pw.FontWeight.bold),
                        ),
                      ],
                    ),
                  ],
                ),
                pw.SizedBox(height: 6),
              ],
            ),
          );
        },
      ),
    );

    return doc.save();
  }

  static pw.TableRow _buildTableRow(String label1, String value1, String label2, String value2) {
    return pw.TableRow(
      children: [
        pw.Container(
          padding: const pw.EdgeInsets.symmetric(horizontal: 6, vertical: 5),
          color: PdfColors.grey100,
          child: pw.Text(label1, style: pw.TextStyle(fontSize: 8.5, fontWeight: pw.FontWeight.bold, color: PdfColors.grey800)),
        ),
        pw.Container(
          padding: const pw.EdgeInsets.symmetric(horizontal: 6, vertical: 5),
          child: pw.Text(value1, style: pw.TextStyle(fontSize: 9, fontWeight: pw.FontWeight.bold, color: PdfColors.teal900)),
        ),
        pw.Container(
          padding: const pw.EdgeInsets.symmetric(horizontal: 6, vertical: 5),
          color: PdfColors.grey100,
          child: pw.Text(label2, style: pw.TextStyle(fontSize: 8.5, fontWeight: pw.FontWeight.bold, color: PdfColors.grey800)),
        ),
        pw.Container(
          padding: const pw.EdgeInsets.symmetric(horizontal: 6, vertical: 5),
          child: pw.Text(value2, style: pw.TextStyle(fontSize: 9, fontWeight: pw.FontWeight.bold, color: PdfColors.teal900)),
        ),
      ],
    );
  }

  static Future<void> printAdmissionSlip(SchoolStudent student) async {
    final pdfBytes = await generateAdmissionFormPdf(student);
    await Printing.layoutPdf(
      name: 'Admission-Form-${student.rollNo}-${student.name.replaceAll(' ', '_')}',
      onLayout: (format) async => pdfBytes,
    );
  }
}
