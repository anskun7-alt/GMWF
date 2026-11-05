import 'package:flutter/material.dart';
import 'package:gmwf/design/tokens/soft_palette.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:arabic_reshaper/arabic_reshaper.dart';

import 'package:intl/intl.dart';

class PatientFormHelper {
  static bool _isSyrup(String t, String n) =>
      t.contains('syrup') || t.contains('syp') || n.contains('syrup') || n.contains('syp');

  /// "IV" / "I.V." as a word, not inside Multivitamin, Ivermectin, Rivotril, Ativan …
  static final RegExp ivWord = RegExp(r'(^|[^a-z])i\.?v\.?([^a-z]|$)');

  /// A prescribed item that needs a syringe/needle (injection, drip, infusion, IV).
  static bool isInjectablePrescription(String type, String name) {
    final t = type.toLowerCase();
    final n = name.toLowerCase();
    if (_isSyrup(t, n) || t.contains('tablet') || t.contains('capsule')) return false;
    return t.contains('injection') || t.contains('inj') || t.contains('infusion') ||
        t.contains('drip') || ivWord.hasMatch(t) ||
        n.startsWith('inj') || n.contains(' inj') || n.contains('inj.') || ivWord.hasMatch(n);
  }

  /// A stock item that is a syringe. 'syr.' is this app's own TYPE abbreviation for syringe
  /// (see _getMedAbbrev in patient_form), but in a NAME "Syr." usually means syrup
  /// ("Syr. Brufen 120ml"), so a name alone never makes a syrup a syringe.
  static bool isSyringeStockItem(String type, String name, String category) {
    final t = type.toLowerCase().trim();
    final n = name.toLowerCase();
    final c = category.toLowerCase();
    if (_isSyrup(t, n) || t.contains('susp') || n.contains('suspension')) return false;
    if (t.contains('syringe') || t == 'syr' || t == 'syr.') return true;
    if (n.contains('syringe') || n.contains('disp. syr') || n.contains('disposable syr')) return true;
    return (c.contains('consumable') || c.contains('disposable')) && (n.contains('syr') || t.contains('syr'));
  }

  static final Map<String, Uint8List> _assetCache = {};
  static pw.Font? _cachedUrduFont;
  static pw.Font? _cachedEnglishFont;

  static String _processUrduText(String text) {
    if (text.trim().isEmpty) return '';
    final hasArabicUrdu = RegExp(r'[\u0600-\u06FF\u0750-\u077F\uFB50-\uFDFF\uFE70-\uFEFF]').hasMatch(text);
    if (hasArabicUrdu) {
      try {
        return ArabicReshaper().reshape(text);
      } catch (_) {
        return text;
      }
    }
    return text;
  }

  // ====================== COLORS ======================
  static const Color primaryGreen = SoftPalette.green400;
  static const Color primaryRed = SoftPalette.red400;
  static const Color textBlack = SoftPalette.gray900A87;

  // ====================== TEXT STYLES (Flutter UI) ======================
  static TextStyle robotoRegular({double size = 16, Color color = textBlack}) =>
      TextStyle(fontFamily: 'Roboto', fontSize: size, color: color);
  static TextStyle robotoBold({double size = 16, Color color = textBlack}) =>
      TextStyle(
          fontFamily: 'Roboto',
          fontSize: size,
          color: color,
          fontWeight: FontWeight.bold);
  static TextStyle nooriRegular({double size = 16, Color color = textBlack}) =>
      TextStyle(fontFamily: 'Noori', fontSize: size, color: color);

  // ====================== TIMING & MEDICINE HELPERS ======================
  static List<int> parseTiming(String timing) {
    if (timing.isEmpty) return [0, 0, 0];
    final t = timing.trim().toLowerCase();
    if (t == 'od' || t == 'qd') return [1, 0, 0];
    if (t == 'bd' || t == 'bid') return [1, 0, 1];
    if (t == 'tds' || t == 'tid') return [1, 1, 1];
    if (t == 'qid') return [1, 1, 1, 1];
    if (t == 'hs' || t == 'bedtime') return [0, 0, 1];
    if (t == 'sos' || t == 'prn') return [0, 0, 0];
    final clean = timing.replaceAll('/', '+').replaceAll('-', '+').replaceAll(' ', '');
    final parts =
        clean.split('+').map((s) => int.tryParse(s.trim()) ?? 0).toList();
    while (parts.length < 3) {
      parts.add(0);
    }
    return parts.length > 3 && parts[3] > 0 ? parts.sublist(0, 4) : parts.sublist(0, 3);
  }

  static int totalPerDay(String timing) =>
      parseTiming(timing).reduce((a, b) => a + b);

  static bool isInjectable(Map m) {
    final type = (m['type'] ?? '').toString().toLowerCase().trim();
    final name = (m['name'] ?? '').toString().toLowerCase();
    return type.contains('injection') ||
        type.contains('inj') ||
        type.contains('infusion') ||
        type.contains('inf') ||
        type.contains('drip') ||
        type.contains('syringe') ||
        name.contains('injection') ||
        name.contains('inj') ||
        name.contains('infusion');
  }

  static bool isInventoryMed(Map m) {
    final invId = m['inventoryId'] ?? m['medicineId'];
    if (invId == null) return false;
    final s = invId.toString().trim().toLowerCase();
    return s.isNotEmpty && s != 'null' && s != 'undefined' && s != '0';
  }

  static String getUnitUrdu(Map med) {
    final type = (med['type'] ?? '').toString().toLowerCase().trim();
    final name = (med['name'] ?? '').toString().toLowerCase();
    final dosage = (med['dosage'] ?? '').toString().toLowerCase();
    if (type.contains('syrup') ||
        type.contains('syp') ||
        name.contains('syrup') ||
        name.contains('syp') ||
        dosage.contains('spoon')) {
      return 'چمچ';
    }
    if (type.contains('injection') || type.contains('inj') || name.contains('injection') || name.contains('inj')) {
      return 'ٹیقہ';
    }
    if (type.contains('infusion') || type.contains('inf') || type.contains('drip') || name.contains('infusion')) {
      return 'ڈرپ';
    }
    if (type.contains('capsule') || type.contains('cap')) return 'کیپسول';
    return 'گولی';
  }

  static String buildUrduDosageLine(Map med) {
    final timing = med['timing']?.toString() ?? '';
    final quantity = med['quantity'] ?? 1;
    if (isInjectable(med)) return 'مقدار $quantity';

    final unitUrdu = getUnitUrdu(med);
    final parts = parseTiming(timing);

    // Only syrups / spoon-based medicines use fractional spoon amounts
    String spoonPrefix = '';
    final dosage = (med['dosage'] ?? med['dose'] ?? '').toString().toLowerCase();
    if (unitUrdu == 'چمچ') {
      if (dosage.contains('1/2') || dosage.contains('half') || dosage.contains('0.5')) {
        spoonPrefix = 'آدھا ';
      } else if (dosage.contains('1/3')) {
        spoonPrefix = 'ایک تہائی ';
      } else if (dosage.contains('1/4')) {
        spoonPrefix = 'چوتھائی ';
      }
    }

    List<String> periods = [];
    if (parts[0] > 0) {
      periods.add('${parts[0]} $spoonPrefix$unitUrdu صبح');
    }
    if (parts[1] > 0) {
      periods.add('${parts[1]} $spoonPrefix$unitUrdu دوپہر');
    }
    if (parts[2] > 0) {
      periods.add('${parts[2]} $spoonPrefix$unitUrdu شام');
    }
    if (periods.isNotEmpty) return periods.join(' - ');

    final q = quantity is num ? quantity.toInt() : (int.tryParse(quantity.toString()) ?? 1);
    return 'مقدار: $q $unitUrdu';
  }

  static String getMealUrdu(String meal) {
    switch (meal) {
      case 'Empty Stomach':
        return 'خالی پیٹ';
      case 'Before Meal':
        return 'کھانے سے پہلے';
      case 'During Meal':
        return 'کھانے کے دوران';
      case 'After Meal':
        return 'کھانے کے بعد';
      case 'Before Sleep':
        return 'سونے سے پہلے';
      default:
        return '';
    }
  }

  static String _getMedAbbrevStatic(String? type) {
    final t = (type ?? '').toLowerCase();
    if (t.contains('syrup')) return 'syp.';
    if (t.contains('injection')) return 'inj.';
    if (t.contains('tablet')) return 'tab.';
    if (t.contains('capsule')) return 'cap.';
    if (t.contains('drip')) return 'drip.';
    if (t.contains('syringe')) return 'syr.';
    return '';
  }

  /// Returns only the timing string, e.g. "1+1+1" or "Qty: 2" for injectables.
  static String buildEnglishDosageLine(Map med) {
    final timing = med['timing']?.toString() ?? '';
    final quantity = med['quantity'] ?? 1;

    if (isInjectable(med)) {
      return 'Qty: $quantity';
    }

    return timing.isNotEmpty ? timing : 'Qty: $quantity';
  }

  /// English meal label (After Meal / Before Meal / Empty Stomach / Bedtime / With Meal).
  static String getMealEnglish(String rawMeal) {
    final meal = rawMeal.trim();
    final lower = meal.toLowerCase();
    if (lower.contains('after') || lower.contains('بعد')) return 'After Meal';
    if (lower.contains('before sleep') || lower.contains('سونے') || lower.contains('سوتے') || lower.contains('bedtime')) {
      return 'Bedtime';
    }
    if (lower.contains('before') || lower.contains('پہلے')) return 'Before Meal';
    if (lower.contains('empty') || lower.contains('خالی') || lower.contains('نہار')) return 'Empty Stomach';
    if (lower.contains('during') || lower.contains('دوران') || lower.contains('with meal')) return 'With Meal';
    return meal;
  }

  /// Compact numeric timing used when the user prefers the "1+1+1" format
  /// (e.g. "1+0+1", "Single Dose", "2/day").
  static String buildCompactEnglishTiming(Map med) {
    if (isInjectable(med)) return 'Single Dose';
    final timing = med['timing']?.toString() ?? '';
    final parts = parseTiming(timing);
    final hasParts = parts.any((p) => p > 0);
    if (hasParts) return parts.join('+');
    if (timing.isNotEmpty) return timing;
    final q = med['quantity'] ?? med['qty'] ?? 1;
    final perDay = q is num ? q.toInt() : (int.tryParse(q.toString()) ?? 1);
    return '$perDay/day';
  }

  // ====================== ASSET LOADER ======================
  static Future<Uint8List> loadAssetBytes(String path) async {
    if (_assetCache.containsKey(path)) return _assetCache[path]!;
    try {
      final data = await rootBundle.load(path);
      final bytes = data.buffer.asUint8List();
      _assetCache[path] = bytes;
      return bytes;
    } catch (e) {
      debugPrint('Asset not found: $path');
      return Uint8List(0);
    }
  }

  // ====================== FONT HELPERS ======================
  static Future<pw.Font> getNooriFont() async {
    if (_cachedUrduFont != null) return _cachedUrduFont!;
    try {
      final data = await rootBundle.load('assets/fonts/Amiri-Regular.ttf');
      _cachedUrduFont = pw.Font.ttf(data);
      return _cachedUrduFont!;
    } catch (_) {
      try {
        final data = await rootBundle.load('assets/fonts/NooriNastaliq.ttf');
        _cachedUrduFont = pw.Font.ttf(data);
        return _cachedUrduFont!;
      } catch (_) {
        _cachedUrduFont = pw.Font.helvetica();
        return _cachedUrduFont!;
      }
    }
  }

  static Future<pw.Font> getEnglishFont() async {
    _cachedEnglishFont ??= pw.Font.helvetica();
    return _cachedEnglishFont!;
  }

  // =========================================================================
  // PRINT SLIP — clean, English-only, small page (A5 or thermal 80mm)
  // Contents:
  //   • gmwf-1.png logo  +  "Free Dispensary" title (English only)
  //   • Lab tests (if any)
  //   • Custom medicines (name + dosage + quantity)
  //   • Custom injectables (name + quantity)
  //
  // NO patient name/token, NO Urdu, NO Unicode bullets, NO inventory medicines.
  // =========================================================================
  static Future<Uint8List> generatePrintSlip({
    required Map<String, dynamic> data,
    required String branchName,
  }) async {
    final english = await getEnglishFont();
    final logoBytes = await loadAssetBytes('assets/logo/gmwf-1.webp');

    final isPhysio = data['isPhysiotherapist'] == true;
    final labTests = (data['labResults'] ?? []) as List;
    final prescriptions = (data['prescriptions'] ?? []) as List;

    // Only custom items on the slip
    final customMeds = prescriptions
        .where((m) => !isInventoryMed(m) && !isInjectable(m))
        .toList();
    final customInjectables = prescriptions
        .where((m) => !isInventoryMed(m) && isInjectable(m))
        .toList();

    final teal = PdfColor.fromHex('#00695C');
    final black = PdfColors.black;
    final grey = PdfColors.grey700;

    final pdf = pw.Document();

    pw.Widget label(String text, {double size = 9, PdfColor? color}) =>
        pw.Text(text,
            style: pw.TextStyle(
                font: english,
                fontSize: size,
                color: color ?? black,
                fontWeight: pw.FontWeight.bold));

    pw.Widget value(String text, {double size = 9}) =>
        pw.Text(text,
            style: pw.TextStyle(font: english, fontSize: size, color: black));

    // Build medicine rows — name left, dosage right — no bullets
    pw.Widget medRow(Map med) {
      final abbrev = _getMedAbbrevStatic(med['type']);
      final name = '$abbrev ${med['name'] ?? ''}'.trim();
      final dosage = buildEnglishDosageLine(med);
      return pw.Padding(
        padding: const pw.EdgeInsets.symmetric(vertical: 2),
        child: pw.Row(
          crossAxisAlignment: pw.CrossAxisAlignment.start,
          children: [
            pw.Expanded(
              flex: 5,
              child: pw.Text(name,
                  style: pw.TextStyle(
                      font: english,
                      fontSize: 9,
                      fontWeight: pw.FontWeight.bold)),
            ),
            pw.SizedBox(width: 6),
            pw.Expanded(
              flex: 5,
              child: pw.Text(dosage,
                  style: pw.TextStyle(
                      font: english, fontSize: 8, color: PdfColors.grey800)),
            ),
          ],
        ),
      );
    }

    pdf.addPage(
      pw.Page(
        // 80mm thermal width; generous height boundary to prevent overflow freezes
        pageFormat: const PdfPageFormat(80 * PdfPageFormat.mm, 500 * PdfPageFormat.mm,
            marginAll: 5 * PdfPageFormat.mm),
        build: (pw.Context ctx) {
          return pw.Column(
            crossAxisAlignment: pw.CrossAxisAlignment.start,
            mainAxisSize: pw.MainAxisSize.min,
            children: [
              // ── Header ──────────────────────────────────────────────────
              pw.Row(
                crossAxisAlignment: pw.CrossAxisAlignment.center,
                children: [
                  if (logoBytes.isNotEmpty)
                    pw.Image(pw.MemoryImage(logoBytes), width: 36, height: 36)
                  else
                    pw.SizedBox(width: 36, height: 36),
                  pw.SizedBox(width: 6),
                  pw.Expanded(
                    child: pw.Column(
                      crossAxisAlignment: pw.CrossAxisAlignment.start,
                      children: [
                        pw.Text('Gulzar Madina Welfare Foundation',
                            style: pw.TextStyle(
                                font: english,
                                fontSize: 9,
                                fontWeight: pw.FontWeight.bold,
                                color: teal)),
                        pw.Text('Free Dispensary',
                            style: pw.TextStyle(
                                font: english,
                                fontSize: 8,
                                color: teal)),
                        if (branchName.isNotEmpty && branchName != 'Free Dispensary')
                          pw.Text(branchName,
                              style: pw.TextStyle(
                                  font: english, fontSize: 7, color: grey)),
                      ],
                    ),
                  ),
                ],
              ),
              pw.Divider(thickness: 0.5, color: grey),

              // ── Lab Tests ────────────────────────────────────────────────
              if (labTests.isNotEmpty) ...[
                label(isPhysio ? 'Physiotherapies' : 'Lab Tests', size: 9, color: teal),
                pw.SizedBox(height: 3),
                ...labTests.map((lab) => pw.Padding(
                      padding: const pw.EdgeInsets.symmetric(vertical: 1),
                      child: pw.Text(lab['name']?.toString() ?? '',
                          style: pw.TextStyle(font: english, fontSize: 9)),
                    )),
              ],

              // ── Custom Medicines ─────────────────────────────────────────
              if (customMeds.isNotEmpty) ...[
                pw.Divider(thickness: 0.4, color: grey),
                label('Medicines', size: 9, color: teal),
                pw.SizedBox(height: 3),
                ...customMeds.map((m) => medRow(m)),
              ],

              // ── Custom Injectables ───────────────────────────────────────
              if (customInjectables.isNotEmpty) ...[
                pw.Divider(thickness: 0.4, color: grey),
                label('Injectables', size: 9, color: teal),
                pw.SizedBox(height: 3),
                ...customInjectables.map((m) => medRow(m)),
              ],

              // ── Footer ───────────────────────────────────────────────────
              pw.Divider(thickness: 0.5, color: grey),
              pw.Center(
                child: pw.Text('gulzarmadina.com',
                    style: pw.TextStyle(
                        font: english, fontSize: 7, color: grey)),
              ),
            ],
          );
        },
      ),
    );

    return pdf.save();
  }

  // ====================== PDF HEADER (WhatsApp / full doc) =================
  static pw.Widget buildPdfHeader(
    pw.Font english,
    pw.Font urdu,
    Uint8List logoBytes,
    Uint8List moonBytes,
    String doctorName, {
    required bool isPrint,
    bool includeDoctor = true,
  }) {
    final textColor = PdfColors.green;
    final drColor = isPrint ? PdfColors.green : PdfColors.red;
    final logoSize = isPrint ? 70.0 : 85.0;
    final titleSize1 = isPrint ? 18.0 : 28.0;
    final titleSize2 = isPrint ? 16.0 : 26.0;
    final titleSize3 = isPrint ? 14.0 : 24.0;
    final doctorSize = isPrint ? 12.0 : 22.0;
    return pw.Column(children: [
      pw.Row(
        mainAxisAlignment: pw.MainAxisAlignment.start,
        children: [
          if (logoBytes.isNotEmpty)
            pw.Image(pw.MemoryImage(logoBytes),
                width: logoSize, height: logoSize)
          else
            pw.SizedBox(width: logoSize, height: logoSize),
          pw.SizedBox(width: 8),
          pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.start, children: [
            pw.Text('Gulzar Madina Welfare Foundation',
                style: pw.TextStyle(
                    font: english,
                    fontSize: titleSize2,
                    fontWeight: pw.FontWeight.bold,
                    color: textColor)),
            pw.Text('Free Dispensary',
                style: pw.TextStyle(
                    font: english,
                    fontSize: titleSize3,
                    fontWeight: pw.FontWeight.bold,
                    color: textColor)),
          ]),
        ],
      ),
      pw.SizedBox(height: isPrint ? 4 : 16),
      if (includeDoctor)
        pw.Align(
          alignment: pw.Alignment.centerLeft,
          child: pw.Padding(
            padding: const pw.EdgeInsets.only(left: 20),
            child: pw.Text(
              doctorName.isNotEmpty ? 'Dr. $doctorName' : 'Dr. ____________',
              style: pw.TextStyle(
                  color: drColor,
                  fontSize: doctorSize,
                  fontWeight: pw.FontWeight.bold,
                  font: english),
            ),
          ),
        ),
    ]);
  }

  static pw.Widget buildPdfLabColumn(pw.Font english, List labTests,
      {required bool isPrint, bool isPhysio = false}) {
    final titleColor = PdfColors.green;
    final titleSize = isPrint ? 12.0 : 18.0;
    final itemSize = isPrint ? 10.0 : 16.0;
    final paddingVertical = isPrint ? 2.0 : 6.0;
    final titleText = isPhysio ? 'Physiotherapies' : 'Lab Tests';
    return pw.Column(
      crossAxisAlignment: pw.CrossAxisAlignment.start,
      children: [
        pw.Text(titleText,
            style: pw.TextStyle(
                font: english,
                fontSize: titleSize,
                fontWeight: pw.FontWeight.bold,
                color: titleColor)),
        pw.SizedBox(height: isPrint ? 2 : 8),
        ...labTests.map((item) => pw.Padding(
              padding: pw.EdgeInsets.symmetric(vertical: paddingVertical),
              child: pw.Text(item['name'] ?? '',
                  style: pw.TextStyle(
                      fontSize: itemSize,
                      color: PdfColors.black,
                      font: english,
                      fontWeight: pw.FontWeight.bold)),
            )),
      ],
    );
  }

  static pw.Widget buildPdfRightColumn(
    pw.Font english,
    pw.Font urdu,
    Uint8List rxBytes,
    String patientName,
    String diagnosis,
    List inventoryMeds,
    List inventoryInjectables,
    List customMeds,
    List customInjectables, {
    required bool isPrint,
    required String gender,
    required String age,
  }) {
    final textColor = PdfColors.green;
    final patientSize = isPrint ? 10.0 : 16.0;
    final diagTitleSize = isPrint ? 12.0 : 18.0;
    final diagSize = isPrint ? 10.0 : 16.0;
    final patientStyle = pw.TextStyle(font: english, fontSize: patientSize);
    final labelStyle =
        pw.TextStyle(color: textColor, fontWeight: pw.FontWeight.bold);

    return pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.start, children: [
      pw.RichText(
        text: pw.TextSpan(style: patientStyle, children: [
          pw.TextSpan(text: 'Patient: ', style: labelStyle),
          pw.TextSpan(text: patientName),
          const pw.TextSpan(text: ' '),
          pw.TextSpan(text: 'Gender: ', style: labelStyle),
          pw.TextSpan(text: gender),
          const pw.TextSpan(text: ' '),
          pw.TextSpan(text: 'Age: ', style: labelStyle),
          pw.TextSpan(text: age),
        ]),
      ),
      if (diagnosis.isNotEmpty && !isPrint) ...[
        pw.SizedBox(height: 20),
        if (rxBytes.isNotEmpty)
          pw.Image(pw.MemoryImage(rxBytes),
              width: isPrint ? 30 : 40, height: isPrint ? 30 : 40),
        pw.SizedBox(height: 6),
        pw.Text('Diagnosis',
            style: pw.TextStyle(
                font: english,
                fontSize: diagTitleSize,
                fontWeight: pw.FontWeight.bold,
                color: textColor)),
        pw.Text(diagnosis,
            style: pw.TextStyle(fontSize: diagSize, font: english)),
      ],
      ...buildPdfMedicineSections(english, urdu,
          isPrint: isPrint,
          inventoryMeds: inventoryMeds,
          inventoryInjectables: inventoryInjectables,
          customMeds: customMeds,
          customInjectables: customInjectables),
    ]);
  }

  static pw.Widget buildPdfFooter(pw.Font english, String branchName) =>
      pw.Center(
        child: pw.Column(children: [
          pw.Text('Gulzar Madina $branchName',
              style: pw.TextStyle(
                  fontSize: 12,
                  fontWeight: pw.FontWeight.bold,
                  color: PdfColors.black,
                  font: english)),
          pw.Text('Website: gulzarmadina.com',
              style: pw.TextStyle(
                  fontSize: 10, color: PdfColors.grey, font: english)),
        ]),
      );

  static pw.Widget pdfVerticalDivider() => pw.Container(
      width: 1,
      height: 400,
      color: PdfColors.grey400,
      margin: const pw.EdgeInsets.symmetric(horizontal: 20));

  static List<pw.Widget> buildPdfMedicineSections(
    pw.Font english,
    pw.Font urdu, {
    required bool isPrint,
    required List inventoryMeds,
    required List inventoryInjectables,
    required List customMeds,
    required List customInjectables,
  }) {
    final sections = <pw.Widget>[];
    final titleSize = isPrint ? 12.0 : 18.0;
    final spacing = isPrint ? 10.0 : 20.0;

    void add(String title, List items, {bool inj = false}) {
      if (items.isEmpty) return;
      sections.add(pw.SizedBox(height: spacing));
      sections.add(pw.Text(title,
          style: pw.TextStyle(
              font: english,
              fontSize: titleSize,
              fontWeight: pw.FontWeight.bold,
              color: PdfColors.green)));
      sections.addAll(buildPdfMedicineItems(english, urdu, items,
          isPrint: isPrint, isInjectable: inj));
    }

    add('Inventory Medicines', inventoryMeds);
    add('Inventory Injectables', inventoryInjectables, inj: true);
    add('Custom Medicines', customMeds);
    add('Custom Injectables', customInjectables, inj: true);
    return sections;
  }

  static List<pw.Widget> buildPdfMedicineItems(
    pw.Font english,
    pw.Font urdu,
    List items, {
    required bool isPrint,
    required bool isInjectable,
  }) {
    final timingColor = isPrint ? PdfColors.black : PdfColors.green;
    final totalColor = isPrint ? PdfColors.black : PdfColors.red;
    final paddingVertical = isPrint ? 2.0 : 6.0;
    final nameSize = isPrint ? 10.0 : 16.0;
    final timingSize = isPrint ? 10.0 : 16.0;
    final totalSize = isPrint ? 9.0 : 15.0;
    final urduSize = isPrint ? 8.0 : 14.0;

    return items.map((m) {
      final rawName = m['name']?.toString() ?? '';
      final prefixType = _getMedAbbrevStatic(m['type']);
      final doseStr = (m['dose'] ?? m['dosage'] ?? '').toString().trim();
      final doseSuffix = doseStr.isNotEmpty ? ' ($doseStr)' : '';
      final name = '$prefixType$rawName$doseSuffix'.trim();
      final timing = m['timing']?.toString() ?? '';
      final quantity = m['quantity'] ?? 1;
      final total = totalPerDay(timing);
      final timingDisp = timing.replaceAll('+', '+');
      final urduTiming = _processUrduText(buildUrduDosageLine(m));
      final urduDose = (total <= 0 && !isInjectable)
          ? _processUrduText('مقدار: $quantity ${getUnitUrdu(m)}')
          : '';
      final mealUrdu = _processUrduText(getMealUrdu(m['meal']?.toString() ?? ''));
      final showTiming = !isInjectable && total > 0;
      final showQty = isInjectable;

      if (isPrint) {
        final dosage = buildEnglishDosageLine(m);
        return pw.Padding(
          padding: pw.EdgeInsets.symmetric(vertical: paddingVertical),
          child: pw.Row(
            crossAxisAlignment: pw.CrossAxisAlignment.start,
            children: [
              pw.Expanded(
                flex: 5,
                child: pw.Text(name,
                    style: pw.TextStyle(
                        font: english,
                        fontSize: nameSize,
                        fontWeight: pw.FontWeight.bold)),
              ),
              pw.SizedBox(width: 6),
              pw.Expanded(
                flex: 5,
                child: pw.Text(dosage,
                    style: pw.TextStyle(
                        font: english, fontSize: nameSize - 1, color: PdfColors.grey800)),
              ),
            ],
          ),
        );
      } else {
        final mealText = (m['meal'] ?? '').toString().trim();
        return pw.Padding(
          padding: pw.EdgeInsets.symmetric(vertical: paddingVertical),
          child: pw.Column(
            crossAxisAlignment: pw.CrossAxisAlignment.start,
            children: [
              pw.Row(children: [
                pw.Expanded(
                  flex: 5,
                  child: pw.Text(name,
                      style: pw.TextStyle(
                          font: english,
                          fontSize: nameSize,
                          fontWeight: pw.FontWeight.bold)),
                ),
                if (showTiming)
                  pw.Expanded(
                    flex: 5,
                    child: pw.RichText(
                      text: pw.TextSpan(children: [
                        pw.TextSpan(
                            text: timingDisp,
                            style: pw.TextStyle(
                                font: english,
                                fontSize: timingSize,
                                fontWeight: pw.FontWeight.bold,
                                color: timingColor)),
                        const pw.TextSpan(text: ' '),
                        pw.TextSpan(
                            text: '($total/day)',
                            style: pw.TextStyle(
                                font: english,
                                fontSize: totalSize,
                                fontWeight: pw.FontWeight.bold,
                                color: totalColor)),
                      ]),
                    ),
                  ),
                if (showQty)
                  pw.Expanded(
                    flex: 5,
                    child: pw.Text('Qty: $quantity',
                        style: pw.TextStyle(
                            font: english,
                            fontSize: timingSize,
                            fontWeight: pw.FontWeight.bold,
                            color: timingColor)),
                  ),
              ]),
              if (mealText.isNotEmpty)
                pw.Padding(
                  padding: const pw.EdgeInsets.only(top: 2),
                  child: pw.Text(
                    mealText,
                    style: pw.TextStyle(
                      font: english,
                      fontSize: nameSize - 2,
                      color: PdfColors.grey700,
                    ),
                  ),
                ),
            ],
          ),
        );
      }
    }).toList();
  }

  // ====================== Modern WhatsApp Prescription PDF =========================
  static Future<Uint8List> generateWhatsAppPdf(
    Map<String, dynamic> data,
    String branchName,
    String gender,
    String age,
  ) async {
    final pdf = pw.Document();
    final english = await getEnglishFont();
    final urdu = await getNooriFont();
    final logoBytes = await loadAssetBytes('assets/logo/gmwf-1.webp');

    final doctorName = data['doctorName']?.toString() ?? '';
    String patientName = 'Patient';
    final candidateNames = [data['patientName'], data['name'], data['patient_name']];
    for (var c in candidateNames) {
      if (c != null) {
        final str = c.toString().trim();
        if (str.isNotEmpty && str != '0') {
          patientName = str;
          break;
        }
      }
    }
    final diagnosis = data['diagnosis']?.toString() ?? '';
    final serial = data['tokenNumber'] ?? data['serial'] ?? data['token'] ?? data['id'] ?? 'N/A';
    final labTests = (data['labResults'] ?? []) as List;
    final prescriptions = (data['prescriptions'] ?? []) as List;

    final isPhysio = data['isPhysiotherapist'] == true;
    final tealDark = PdfColor.fromHex('#00695C');
    final tealLight = PdfColor.fromHex('#E0F2F1');
    final textDark = PdfColor.fromHex('#0F172A');
    final textMuted = PdfColor.fromHex('#64748B');
    final borderGrey = PdfColor.fromHex('#E2E8F0');
    final bgLight = PdfColor.fromHex('#F8FAFC');

    final dateStr = DateFormat('dd MMM yyyy, hh:mm a').format(DateTime.now());

    pdf.addPage(
      pw.Page(
        pageFormat: PdfPageFormat.a4,
        margin: const pw.EdgeInsets.all(24),
        build: (pw.Context ctx) {
          return pw.Column(
            crossAxisAlignment: pw.CrossAxisAlignment.start,
            children: [
              // ── 1. Modern Header ───────────────────────────────────────
              pw.Container(
                padding: const pw.EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                decoration: pw.BoxDecoration(
                  color: tealDark,
                  borderRadius: const pw.BorderRadius.all(pw.Radius.circular(10)),
                ),
                child: pw.Row(
                  children: [
                    if (logoBytes.isNotEmpty)
                      pw.Container(
                        width: 44,
                        height: 44,
                        decoration: const pw.BoxDecoration(
                          color: PdfColors.white,
                          shape: pw.BoxShape.circle,
                        ),
                        padding: const pw.EdgeInsets.all(3),
                        child: pw.Image(pw.MemoryImage(logoBytes)),
                      ),
                    if (logoBytes.isNotEmpty) pw.SizedBox(width: 12),
                    pw.Expanded(
                      child: pw.Column(
                        crossAxisAlignment: pw.CrossAxisAlignment.start,
                        children: [
                          pw.Text(
                            'GULZAR MADINA WELFARE FOUNDATION',
                            style: pw.TextStyle(
                              font: english,
                              fontSize: 13,
                              fontWeight: pw.FontWeight.bold,
                              color: PdfColors.white,
                              letterSpacing: 0.5,
                            ),
                          ),
                          pw.SizedBox(height: 2),
                          pw.Text(
                            'Free Medical Dispensary & Clinical Welfare Services',
                            style: pw.TextStyle(
                              font: english,
                              fontSize: 9.5,
                              color: PdfColor.fromHex('#B2DFDB'),
                            ),
                          ),
                        ],
                      ),
                    ),
                    pw.Container(
                      padding: const pw.EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                      decoration: pw.BoxDecoration(
                        color: PdfColors.white,
                        borderRadius: const pw.BorderRadius.all(pw.Radius.circular(6)),
                      ),
                      child: pw.Column(
                        crossAxisAlignment: pw.CrossAxisAlignment.end,
                        children: [
                          pw.Text(
                            'PRESCRIPTION',
                            style: pw.TextStyle(
                              font: english,
                              fontSize: 8.5,
                              fontWeight: pw.FontWeight.bold,
                              color: tealDark,
                            ),
                          ),
                          pw.Text(
                            'Slip #$serial',
                            style: pw.TextStyle(
                              font: english,
                              fontSize: 8.5,
                              fontWeight: pw.FontWeight.bold,
                              color: textDark,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),

              pw.SizedBox(height: 10),

              // ── 2. Patient & Clinical Metadata Card ───────────────────────
              pw.Container(
                padding: const pw.EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                decoration: pw.BoxDecoration(
                  color: bgLight,
                  borderRadius: const pw.BorderRadius.all(pw.Radius.circular(8)),
                  border: pw.Border.all(color: borderGrey, width: 1),
                ),
                child: pw.Row(
                  crossAxisAlignment: pw.CrossAxisAlignment.start,
                  children: [
                    pw.Expanded(
                      flex: 3,
                      child: pw.Column(
                        crossAxisAlignment: pw.CrossAxisAlignment.start,
                        children: [
                          _buildPdfMetaRow(english, 'Patient Name', patientName, isBoldValue: true),
                          pw.SizedBox(height: 4),
                          _buildPdfMetaRow(english, 'Age / Gender', '$age Yrs / ${gender.toUpperCase()}'),
                        ],
                      ),
                    ),
                    pw.Expanded(
                      flex: 3,
                      child: pw.Column(
                        crossAxisAlignment: pw.CrossAxisAlignment.start,
                        children: [
                          _buildPdfMetaRow(english, 'Dispensary', branchName),
                          pw.SizedBox(height: 4),
                          _buildPdfMetaRow(english, 'Visit Date', dateStr),
                        ],
                      ),
                    ),
                    pw.Expanded(
                      flex: 3,
                      child: pw.Column(
                        crossAxisAlignment: pw.CrossAxisAlignment.start,
                        children: [
                          _buildPdfMetaRow(english, 'Consultant Doctor', doctorName.isNotEmpty ? 'Dr. $doctorName' : 'Attending Physician', isBoldValue: true),
                          pw.SizedBox(height: 4),
                          _buildPdfMetaRow(english, 'Status', 'Verified Patient'),
                        ],
                      ),
                    ),
                  ],
                ),
              ),

              if (diagnosis.isNotEmpty || labTests.isNotEmpty) ...[
                pw.SizedBox(height: 10),
                pw.Row(
                  crossAxisAlignment: pw.CrossAxisAlignment.start,
                  children: [
                    if (diagnosis.isNotEmpty)
                      pw.Expanded(
                        flex: 6,
                        child: pw.Container(
                          padding: const pw.EdgeInsets.all(10),
                          decoration: pw.BoxDecoration(
                            color: PdfColor.fromHex('#F0FDF4'),
                            borderRadius: const pw.BorderRadius.all(pw.Radius.circular(8)),
                            border: pw.Border.all(color: PdfColor.fromHex('#BBF7D0'), width: 0.8),
                          ),
                          child: pw.Row(
                            crossAxisAlignment: pw.CrossAxisAlignment.start,
                            children: [
                              pw.Container(
                                padding: const pw.EdgeInsets.symmetric(horizontal: 5, vertical: 2),
                                decoration: pw.BoxDecoration(
                                  color: tealDark,
                                  borderRadius: const pw.BorderRadius.all(pw.Radius.circular(4)),
                                ),
                                child: pw.Text(
                                  'Rx',
                                  style: pw.TextStyle(
                                    font: english,
                                    fontSize: 10,
                                    fontWeight: pw.FontWeight.bold,
                                    color: PdfColors.white,
                                  ),
                                ),
                              ),
                              pw.SizedBox(width: 8),
                              pw.Expanded(
                                child: pw.Column(
                                  crossAxisAlignment: pw.CrossAxisAlignment.start,
                                  children: [
                                    pw.Text(
                                      'Clinical Diagnosis / Notes',
                                      style: pw.TextStyle(
                                        font: english,
                                        fontSize: 8.5,
                                        fontWeight: pw.FontWeight.bold,
                                        color: tealDark,
                                      ),
                                    ),
                                    pw.SizedBox(height: 2),
                                    pw.Text(
                                      diagnosis,
                                      style: pw.TextStyle(
                                        font: english,
                                        fontSize: 9.5,
                                        color: textDark,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    if (diagnosis.isNotEmpty && labTests.isNotEmpty) pw.SizedBox(width: 10),
                    if (labTests.isNotEmpty)
                      pw.Expanded(
                        flex: 4,
                        child: pw.Container(
                          padding: const pw.EdgeInsets.all(10),
                          decoration: pw.BoxDecoration(
                            color: PdfColor.fromHex('#EFF6FF'),
                            borderRadius: const pw.BorderRadius.all(pw.Radius.circular(8)),
                            border: pw.Border.all(color: PdfColor.fromHex('#BFDBFE'), width: 0.8),
                          ),
                          child: pw.Column(
                            crossAxisAlignment: pw.CrossAxisAlignment.start,
                            children: [
                              pw.Text(
                                isPhysio ? 'Prescribed Physiotherapy' : 'Prescribed Lab Tests',
                                style: pw.TextStyle(
                                  font: english,
                                  fontSize: 8.5,
                                  fontWeight: pw.FontWeight.bold,
                                  color: PdfColor.fromHex('#1D4ED8'),
                                ),
                              ),
                              pw.SizedBox(height: 3),
                              ...labTests.map((t) => pw.Text(
                                    '• ${t['name'] ?? ''}',
                                    style: pw.TextStyle(
                                      font: english,
                                      fontSize: 8.5,
                                      color: textDark,
                                    ),
                                  )),
                            ],
                          ),
                        ),
                      ),
                  ],
                ),
              ],

              pw.SizedBox(height: 10),

              // ── 3. Prescribed Medicines Section ───────────────────────────
              pw.Container(
                decoration: pw.BoxDecoration(
                  border: pw.Border.all(color: borderGrey, width: 1),
                  borderRadius: const pw.BorderRadius.all(pw.Radius.circular(8)),
                ),
                child: pw.Column(
                  children: [
                    // Table Header
                    pw.Container(
                      padding: const pw.EdgeInsets.symmetric(horizontal: 10, vertical: 7),
                      decoration: pw.BoxDecoration(
                        color: PdfColor.fromHex('#F1F5F9'),
                        borderRadius: const pw.BorderRadius.vertical(top: pw.Radius.circular(7)),
                      ),
                      child: pw.Row(
                        children: [
                          pw.SizedBox(
                            width: 24,
                            child: pw.Text('#', style: pw.TextStyle(font: english, fontSize: 8.5, fontWeight: pw.FontWeight.bold, color: textMuted)),
                          ),
                          pw.Expanded(
                            flex: 5,
                            child: pw.Text('MEDICINE / FORMULATION', style: pw.TextStyle(font: english, fontSize: 8.5, fontWeight: pw.FontWeight.bold, color: textMuted)),
                          ),
                          pw.Expanded(
                            flex: 3,
                            child: pw.Text('FREQUENCY / TIMING', style: pw.TextStyle(font: english, fontSize: 8.5, fontWeight: pw.FontWeight.bold, color: textMuted)),
                          ),
                          pw.Expanded(
                            flex: 2,
                            child: pw.Text('QTY', style: pw.TextStyle(font: english, fontSize: 8.5, fontWeight: pw.FontWeight.bold, color: textMuted)),
                          ),
                          pw.Expanded(
                            flex: 5,
                            child: pw.Text('INSTRUCTIONS & USAGE (ہدایات)', style: pw.TextStyle(font: english, fontSize: 8.5, fontWeight: pw.FontWeight.bold, color: textMuted)),
                          ),
                        ],
                      ),
                    ),

                    // Table Rows
                    if (prescriptions.isEmpty)
                      pw.Padding(
                        padding: const pw.EdgeInsets.all(16),
                        child: pw.Center(
                          child: pw.Text(
                            'No prescription items recorded.',
                            style: pw.TextStyle(font: english, fontSize: 9.5, color: textMuted),
                          ),
                        ),
                      )
                    else
                      ...List.generate(prescriptions.length, (i) {
                        final m = prescriptions[i];
                        final isEven = i % 2 == 0;
                        final rawName = m['name']?.toString() ?? '';
                        final prefix = _getMedAbbrevStatic(m['type']);
                        final dose = (m['dose'] ?? m['dosage'] ?? '').toString().trim();
                        final nameWithDose = '$prefix$rawName${dose.isNotEmpty ? ' ($dose)' : ''}'.trim();
                        final timing = m['timing']?.toString() ?? '';
                        final qty = m['quantity'] ?? 1;
                        final meal = (m['meal'] ?? '').toString().trim();
                        final mealUrdu = getMealUrdu(meal);
                        final urduDosage = buildUrduDosageLine(m);
                        final isInj = isInjectable(m);

                        return pw.Container(
                          padding: const pw.EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                          decoration: pw.BoxDecoration(
                            color: isEven ? PdfColors.white : bgLight,
                            border: i == prescriptions.length - 1
                                ? null
                                : pw.Border(bottom: pw.BorderSide(color: borderGrey, width: 0.5)),
                          ),
                          child: pw.Row(
                            crossAxisAlignment: pw.CrossAxisAlignment.center,
                            children: [
                              pw.SizedBox(
                                width: 24,
                                child: pw.Text('${i + 1}', style: pw.TextStyle(font: english, fontSize: 8.5, fontWeight: pw.FontWeight.bold, color: tealDark)),
                              ),
                              pw.Expanded(
                                flex: 5,
                                child: pw.Text(
                                  nameWithDose,
                                  style: pw.TextStyle(font: english, fontSize: 9.5, fontWeight: pw.FontWeight.bold, color: textDark),
                                ),
                              ),
                              pw.Expanded(
                                flex: 3,
                                child: pw.Container(
                                  padding: const pw.EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                  decoration: pw.BoxDecoration(
                                    color: tealLight,
                                    borderRadius: const pw.BorderRadius.all(pw.Radius.circular(4)),
                                  ),
                                  child: pw.Text(
                                    isInj ? 'Single Dose' : (timing.isNotEmpty ? timing : '-'),
                                    style: pw.TextStyle(font: english, fontSize: 8.5, fontWeight: pw.FontWeight.bold, color: tealDark),
                                  ),
                                ),
                              ),
                              pw.Expanded(
                                flex: 2,
                                child: pw.Text(
                                  '$qty',
                                  style: pw.TextStyle(font: english, fontSize: 9, fontWeight: pw.FontWeight.bold, color: textDark),
                                ),
                              ),
                              pw.Expanded(
                                flex: 5,
                                child: pw.Column(
                                  crossAxisAlignment: pw.CrossAxisAlignment.start,
                                  children: [
                                    if (meal.isNotEmpty)
                                      pw.Text(
                                        meal,
                                        style: pw.TextStyle(font: english, fontSize: 8.5, color: textMuted),
                                      ),
                                    if (urduDosage.isNotEmpty || mealUrdu.isNotEmpty)
                                      pw.Text(
                                        _processUrduText('$urduDosage ${mealUrdu.isNotEmpty ? '($mealUrdu)' : ''}'.trim()),
                                        style: pw.TextStyle(font: urdu, fontSize: 8.5, color: tealDark),
                                      ),
                                  ],
                                ),
                              ),
                            ],
                          ),
                        );
                      }),
                  ],
                ),
              ),

              pw.Spacer(),

              // ── 4. Islamic Healing Supplication & Security Watermark ────────
              pw.Container(
                padding: const pw.EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                decoration: pw.BoxDecoration(
                  color: PdfColor.fromHex('#F0FDFA'),
                  borderRadius: const pw.BorderRadius.all(pw.Radius.circular(6)),
                  border: pw.Border.all(color: PdfColor.fromHex('#CCFBF1'), width: 0.8),
                ),
                child: pw.Row(
                  mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
                  children: [
                    pw.Text(
                      _processUrduText('اَللّٰهُمَّ رَبَّ النَّاسِ أَذْهِبِ الْبَاسَ اشْفِ أَنْتَ الشَّافِي'),
                      style: pw.TextStyle(font: urdu, fontSize: 10, fontWeight: pw.FontWeight.bold, color: tealDark),
                    ),
                    pw.Text(
                      'Free Humanitarian Healthcare • Non-Commercial Record',
                      style: pw.TextStyle(font: english, fontSize: 8, color: textMuted),
                    ),
                  ],
                ),
              ),

              pw.SizedBox(height: 8),

              // ── 5. Official Footer ──────────────────────────────────────────
              pw.Row(
                mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
                children: [
                  pw.Text(
                    'Gulzar Madina Free Dispensary ($branchName)',
                    style: pw.TextStyle(font: english, fontSize: 8, fontWeight: pw.FontWeight.bold, color: textDark),
                  ),
                  pw.Text(
                    'Official Portal: www.gulzarmadina.com  •  Helpline: +92 300 0000000',
                    style: pw.TextStyle(font: english, fontSize: 8, color: textMuted),
                  ),
                ],
              ),
            ],
          );
        },
      ),
    );

    return pdf.save();
  }

  static pw.Widget _buildPdfMetaRow(pw.Font font, String label, String value, {bool isBoldValue = false}) {
    return pw.Row(
      crossAxisAlignment: pw.CrossAxisAlignment.start,
      children: [
        pw.Text(
          '$label: ',
          style: pw.TextStyle(font: font, fontSize: 8.5, color: PdfColor.fromHex('#64748B')),
        ),
        pw.Expanded(
          child: pw.Text(
            value,
            style: pw.TextStyle(
              font: font,
              fontSize: 8.5,
              fontWeight: isBoldValue ? pw.FontWeight.bold : pw.FontWeight.normal,
              color: PdfColor.fromHex('#0F172A'),
            ),
          ),
        ),
      ],
    );
  }
}
