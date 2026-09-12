// lib/services/donation_box_storage.dart
//
// Hive-based local storage + Firestore sync for donation boxes and openings.

import 'dart:io';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:excel/excel.dart' hide Border;
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:intl/intl.dart';
import 'package:uuid/uuid.dart';

import 'local_storage_service.dart';
import '../models/donation_box_models.dart';

class DonationBoxStorage {
  static const String boxesBoxName   = 'local_donation_boxes';
  static const String openingsBoxName = 'local_box_openings';

  // ══════════════════════════════════════════════════════════════════════════
  // INIT
  // ══════════════════════════════════════════════════════════════════════════

  static Future<void> init() async {
    await LocalStorageService.openBoxSafe(boxesBoxName);
    await LocalStorageService.openBoxSafe(openingsBoxName);
    debugPrint('[DonationBoxStorage] Boxes opened safely.');
  }

  // ══════════════════════════════════════════════════════════════════════════
  // BOX CRUD (HIVE)
  // ══════════════════════════════════════════════════════════════════════════

  static Future<DonationBox> saveBox(DonationBox box) async {
    final hiveBox = Hive.box(boxesBoxName);
    await hiveBox.put(box.id, box.toMap());
    await hiveBox.flush();
    _enqueueBoxSync(box);
    debugPrint('[DonationBoxStorage] Saved box ${box.boxNumber} locally');
    return box;
  }

  static Future<void> updateBox(DonationBox box) async {
    await saveBox(box);
  }

  static DonationBox? getBox(String id) {
    if (id.isEmpty || !Hive.isBoxOpen(boxesBoxName)) return null;
    final hiveBox = Hive.box(boxesBoxName);
    final raw = hiveBox.get(id);
    if (raw is Map) {
      return DonationBox.fromMap(raw, id);
    }
    return null;
  }

  /// Get all boxes across the entire system regardless of branch or status
  static List<DonationBox> getAllBoxes() => getBoxes('all');

  /// Checks if a box number has ever been assigned anywhere in the system.
  /// An assigned box number can NEVER be reused again under any circumstances.
  static bool isBoxNumberTaken(String boxNumber, {String? excludeBoxId}) {
    final clean = boxNumber.trim().toUpperCase();
    if (clean.isEmpty) return false;
    final allBoxes = getAllBoxes();
    return allBoxes.any((b) =>
        b.boxNumber.trim().toUpperCase() == clean &&
        (excludeBoxId == null || b.id != excludeBoxId));
  }

  /// Get the next sequentially unique box number for a branch.
  /// An assigned box number to a box will NEVER be used again.
  static String suggestNextBoxNumber([String? branchId, String? baseBoxNumber]) {
    final allBoxes = getAllBoxes();
    int maxNum = 0;
    for (var box in allBoxes) {
      final match = RegExp(r'BOX-(\d+)', caseSensitive: false).firstMatch(box.boxNumber);
      if (match != null) {
        final num = int.tryParse(match.group(1)!) ?? 0;
        if (num > maxNum) maxNum = num;
      }
    }
    String candidate = 'BOX-${(maxNum + 1).toString().padLeft(3, '0')}';
    while (isBoxNumberTaken(candidate)) {
      maxNum++;
      candidate = 'BOX-${(maxNum + 1).toString().padLeft(3, '0')}';
    }
    return candidate;
  }

  static List<DonationBox> getBoxes(String branchId) {
    if (!Hive.isBoxOpen(boxesBoxName)) return [];
    final hiveBox = Hive.box(boxesBoxName);
    final List<DonationBox> results = [];
    for (var key in hiveBox.keys) {
      final raw = hiveBox.get(key);
      if (raw is Map) {
        final box = DonationBox.fromMap(raw, key.toString());
        if (branchId == 'all' || box.branchId == branchId) {
          results.add(box);
        }
      }
    }
    results.sort((a, b) => a.boxNumber.compareTo(b.boxNumber));
    return results;
  }

  static Future<void> deleteBox(String id) async {
    final hiveBox = Hive.box(boxesBoxName);
    await hiveBox.delete(id);
    await hiveBox.flush();
  }

  static DonationBox createBox({
    required String boxNumber,
    required String holderName,
    required String branchId,
    required String branchName,
    String holderPhone = '',
    String holderAddress = '',
    String area = '',
    String notes = '',
    String? replacementForBoxId,
  }) {
    final cleanBoxNum = boxNumber.trim().toUpperCase();
    if (isBoxNumberTaken(cleanBoxNum)) {
      throw ArgumentError('Box number "$cleanBoxNum" has already been assigned in the past. Box numbers can never be reused.');
    }

    final id = '${branchId}_box_${const Uuid().v4()}';
    return DonationBox(
      id: id,
      boxNumber: cleanBoxNum,
      holderName: holderName,
      holderPhone: holderPhone,
      holderAddress: holderAddress,
      area: area,
      branchId: branchId,
      branchName: branchName,
      registeredDate: DateFormat('yyyy-MM-dd').format(DateTime.now()),
      isActive: true,
      notes: notes,
      syncStatus: 'pending',
      status: 'active',
      replacementForBoxId: replacementForBoxId,
    );
  }

  /// Reports an accident or compromise incident (snatched, stolen, broken) while preserving all historical data
  static Future<DonationBox> reportIncident({
    required String boxId,
    required String incidentType, // 'snatched', 'stolen', 'broken'
    required String incidentDate,
    String incidentReportedBy = '',
    String incidentNotes = '',
    String policeReportNo = '',
    double? estimatedCashLost,
  }) async {
    final box = getBox(boxId);
    if (box == null) throw Exception('Box not found: $boxId');

    final updated = box.copyWith(
      status: incidentType,
      isActive: false, // Compromised box cannot continue taking cash physically
      incidentType: incidentType,
      incidentDate: incidentDate,
      incidentReportedBy: incidentReportedBy,
      incidentNotes: incidentNotes,
      policeReportNo: policeReportNo,
      estimatedCashLost: estimatedCashLost,
      syncStatus: 'pending',
    );

    await saveBox(updated);
    debugPrint('[DonationBoxStorage] Incident ($incidentType) reported for box ${box.boxNumber}');
    return updated;
  }

  /// Assigns a brand new replacement box with a never-before-used box number, linking historical chain
  static Future<DonationBox> assignReplacementBox({
    required String compromisedBoxId,
    required String newBoxNumber,
    String? customHolderName,
    String? customPhone,
    String? customAddress,
    String? customArea,
    String notes = '',
  }) async {
    final oldBox = getBox(compromisedBoxId);
    if (oldBox == null) throw Exception('Original box not found: $compromisedBoxId');

    final cleanNewNo = newBoxNumber.trim().toUpperCase();
    if (isBoxNumberTaken(cleanNewNo)) {
      throw ArgumentError('Box number "$cleanNewNo" has already been assigned in the past. An assigned box number can never be reused.');
    }

    // 1. Create new replacement box
    final newBox = createBox(
      boxNumber: cleanNewNo,
      holderName: customHolderName ?? oldBox.holderName,
      holderPhone: customPhone ?? oldBox.holderPhone,
      holderAddress: customAddress ?? oldBox.holderAddress,
      area: customArea ?? oldBox.area,
      branchId: oldBox.branchId,
      branchName: oldBox.branchName,
      notes: notes.isNotEmpty
          ? notes
          : 'Replacement for ${oldBox.boxNumber} (${oldBox.status.toUpperCase()})',
      replacementForBoxId: oldBox.id,
    );
    await saveBox(newBox);

    // 2. Link old box to the new replacement box
    final updatedOldBox = oldBox.copyWith(
      replacedByBoxId: newBox.id,
      syncStatus: 'pending',
    );
    await saveBox(updatedOldBox);

    debugPrint('[DonationBoxStorage] Replaced box ${oldBox.boxNumber} with brand-new box ${newBox.boxNumber}');
    return newBox;
  }


  // ══════════════════════════════════════════════════════════════════════════
  // BOX OPENINGS CRUD
  // ══════════════════════════════════════════════════════════════════════════

  static Future<BoxOpening> saveOpening(BoxOpening opening) async {
    final hiveBox = Hive.box(openingsBoxName);
    await hiveBox.put(opening.id, opening.toMap());
    await hiveBox.flush();

    // Update last opened date on the box
    final box = getBox(opening.boxId);
    if (box != null) {
      await updateBox(box.copyWith(
        lastOpenedDate: opening.openDate,
        lastOpenedAmount: opening.amount,
        syncStatus: 'pending',
      ));
    }

    _enqueueOpeningSync(opening);
    debugPrint('[DonationBoxStorage] Saved opening for ${opening.boxNumber} on ${opening.openDate}');
    return opening;
  }

  static BoxOpening createOpening({
    required String boxId,
    required String boxNumber,
    required String openDate,
    required double amount,
    required String collectedBy,
    required String branchId,
    required String branchName,
    String notes = '',
    String? physicalReceiptNo,
  }) {
    final parsed = DateTime.tryParse(openDate);
    final today = DateTime.now();
    final todayMidnight = DateTime(today.year, today.month, today.day, 23, 59, 59);
    if (parsed != null && parsed.isAfter(todayMidnight)) {
      throw ArgumentError('Cannot record donation box openings for future dates.');
    }

    final id = '${branchId}_opening_${const Uuid().v4()}';
    return BoxOpening(
      id: id,
      boxId: boxId,
      boxNumber: boxNumber,
      openDate: openDate,
      amount: amount,
      collectedBy: collectedBy,
      branchId: branchId,
      branchName: branchName,
      notes: notes,
      syncStatus: 'pending',
      timestamp: DateTime.now().toIso8601String(),
      physicalReceiptNo: physicalReceiptNo,
    );
  }

  /// Generates person-level audit analytics comparing lifetime money output vs accidents/incidents
  static List<PersonBoxAuditSummary> getPersonAuditSummaries(String branchId) {
    final allBoxes = getBoxes(branchId);
    final allOpenings = getOpenings(branchId);

    // Group openings by boxId
    final Map<String, List<BoxOpening>> openingsByBox = {};
    for (final op in allOpenings) {
      openingsByBox.putIfAbsent(op.boxId, () => []).add(op);
    }

    // Group boxes by person identity (normalized phone if available, else normalized name)
    final Map<String, List<DonationBox>> boxesByPerson = {};
    for (final box in allBoxes) {
      final phoneClean = box.holderPhone.trim().replaceAll(RegExp(r'[^0-9]'), '');
      final key = phoneClean.isNotEmpty ? phoneClean : box.holderName.trim().toLowerCase();
      final personKey = key.isNotEmpty ? key : box.holderName.trim().toLowerCase();
      boxesByPerson.putIfAbsent(personKey, () => []).add(box);
    }

    final List<PersonBoxAuditSummary> summaries = [];

    for (final entry in boxesByPerson.entries) {
      final pBoxes = entry.value;
      if (pBoxes.isEmpty) continue;

      final primary = pBoxes.first;
      int activeCount = 0;
      int compromisedCount = 0;
      int snatchedCount = 0;
      int stolenCount = 0;
      int brokenCount = 0;
      int replacedCount = 0;
      double totalMoney = 0.0;
      double totalLoss = 0.0;
      int openingsCount = 0;
      String? latestOpenDate;

      for (final b in pBoxes) {
        if (b.status == 'active' && b.isActive) {
          activeCount++;
        } else if (b.status == 'snatched') {
          compromisedCount++;
          snatchedCount++;
        } else if (b.status == 'stolen') {
          compromisedCount++;
          stolenCount++;
        } else if (b.status == 'broken') {
          compromisedCount++;
          brokenCount++;
        } else if (b.status == 'replaced') {
          replacedCount++;
        }

        if (b.estimatedCashLost != null) {
          totalLoss += b.estimatedCashLost!;
        }

        // Sum openings for this box
        final boxOps = openingsByBox[b.id] ?? [];
        for (final op in boxOps) {
          totalMoney += op.amount;
          openingsCount++;
          if (latestOpenDate == null || op.openDate.compareTo(latestOpenDate) > 0) {
            latestOpenDate = op.openDate;
          }
        }
      }

      summaries.add(PersonBoxAuditSummary(
        personName: primary.holderName,
        phone: primary.holderPhone,
        area: primary.area,
        branchId: primary.branchId,
        branchName: primary.branchName,
        totalBoxesAssigned: pBoxes.length,
        activeBoxesCount: activeCount,
        compromisedBoxesCount: compromisedCount,
        snatchedCount: snatchedCount,
        stolenCount: stolenCount,
        brokenCount: brokenCount,
        replacedCount: replacedCount,
        totalMoneyOutput: totalMoney,
        totalEstimatedCashLost: totalLoss,
        totalOpeningsCount: openingsCount,
        lastOpenedDate: latestOpenDate,
        boxes: pBoxes,
      ));
    }

    // Default sort: highest accidents/incidents first, then highest money output
    summaries.sort((a, b) {
      final incComp = b.totalIncidents.compareTo(a.totalIncidents);
      if (incComp != 0) return incComp;
      return b.totalMoneyOutput.compareTo(a.totalMoneyOutput);
    });

    return summaries;
  }

  static List<BoxOpening> getOpenings(String branchId) {
    if (!Hive.isBoxOpen(openingsBoxName)) return [];
    final hiveBox = Hive.box(openingsBoxName);
    final List<BoxOpening> results = [];
    for (var key in hiveBox.keys) {
      final raw = hiveBox.get(key);
      if (raw is Map) {
        final opening = BoxOpening.fromMap(raw, key.toString());
        if (branchId == 'all' || opening.branchId == branchId) {
          results.add(opening);
        }
      }
    }
    results.sort((a, b) => b.openDate.compareTo(a.openDate));
    return results;
  }

  static List<BoxOpening> getOpeningsForBox(String boxId) {
    if (boxId.isEmpty || !Hive.isBoxOpen(openingsBoxName)) return [];
    final hiveBox = Hive.box(openingsBoxName);
    final List<BoxOpening> results = [];
    for (var key in hiveBox.keys) {
      final raw = hiveBox.get(key);
      if (raw is Map) {
        final opening = BoxOpening.fromMap(raw, key.toString());
        if (opening.boxId == boxId) {
          results.add(opening);
        }
      }
    }
    results.sort((a, b) => b.openDate.compareTo(a.openDate));
    return results;
  }

  // ══════════════════════════════════════════════════════════════════════════
  // YEARLY REPORT
  // ══════════════════════════════════════════════════════════════════════════

  static List<BoxMonthlyReport> getYearlyReport(String boxId, int year) {
    final openings = getOpeningsForBox(boxId);
    final monthNames = [
      'January', 'February', 'March', 'April', 'May', 'June',
      'July', 'August', 'September', 'October', 'November', 'December',
    ];

    return List.generate(12, (i) {
      final month = i + 1;
      // Find openings in this month
      final monthOpenings = openings.where((o) {
        final date = DateTime.tryParse(o.openDate);
        return date != null && date.year == year && date.month == month;
      }).toList();

      if (monthOpenings.isEmpty) {
        return BoxMonthlyReport(
          month: month,
          monthName: monthNames[i],
          wasOpened: false,
        );
      }

      // Sum all openings in the month (could be opened multiple times)
      double totalAmount = 0;
      String? lastDate;
      String? lastCollector;
      final List<String> notesList = [];
      for (var o in monthOpenings) {
        totalAmount += o.amount;
        lastDate = o.openDate;
        lastCollector = o.collectedBy;
        if (o.notes.isNotEmpty) notesList.add(o.notes);
      }

      return BoxMonthlyReport(
        month: month,
        monthName: monthNames[i],
        wasOpened: true,
        openDate: lastDate,
        amount: totalAmount,
        collectedBy: lastCollector,
        notes: notesList.join('; '),
      );
    });
  }

  /// Export yearly report to Excel and let user choose save location.
  static Future<void> exportBoxYearlyReport(
    DonationBox box,
    int year,
  ) async {
    final report = getYearlyReport(box.id, year);
    final excel = Excel.createExcel();
    final sheet = excel['Box ${box.boxNumber} - $year'];
    excel.delete('Sheet1');

    // Header info
    sheet.appendRow([
      TextCellValue('Donation Box Yearly Report'),
    ]);
    sheet.appendRow([
      TextCellValue('Box Number: ${box.boxNumber}'),
    ]);
    sheet.appendRow([
      TextCellValue('Holder: ${box.holderName}'),
    ]);
    sheet.appendRow([
      TextCellValue('Area: ${box.area}'),
    ]);
    sheet.appendRow([
      TextCellValue('Address: ${box.holderAddress}'),
    ]);
    sheet.appendRow([
      TextCellValue('Year: $year'),
    ]);
    sheet.appendRow([]); // blank row

    // Column headers
    sheet.appendRow([
      TextCellValue('Month'),
      TextCellValue('Status'),
      TextCellValue('Date Opened'),
      TextCellValue('Amount (PKR)'),
      TextCellValue('Collected By'),
      TextCellValue('Notes'),
    ]);

    double yearTotal = 0;
    int openedCount = 0;
    for (var r in report) {
      if (r.wasOpened) {
        openedCount++;
        yearTotal += r.amount;
      }
      sheet.appendRow([
        TextCellValue(r.monthName),
        TextCellValue(r.wasOpened ? 'OPENED' : 'NOT OPENED'),
        TextCellValue(r.openDate ?? ''),
        r.wasOpened ? DoubleCellValue(r.amount) : TextCellValue(''),
        TextCellValue(r.collectedBy ?? ''),
        TextCellValue(r.notes ?? ''),
      ]);
    }

    // Summary row
    sheet.appendRow([]);
    sheet.appendRow([
      TextCellValue('TOTAL'),
      TextCellValue('$openedCount / 12 months opened'),
      TextCellValue(''),
      DoubleCellValue(yearTotal),
      TextCellValue(''),
      TextCellValue(''),
    ]);

    final bytes = excel.encode();
    if (bytes == null) return;

    final String? outputFile = await FilePicker.platform.saveFile(
      dialogTitle: 'Save Box Yearly Report',
      fileName: 'DonationBox_${box.boxNumber}_$year.xlsx',
      type: FileType.custom,
      allowedExtensions: ['xlsx'],
    );

    if (outputFile != null) {
      final file = File(outputFile);
      await file.writeAsBytes(bytes);
      debugPrint('[DonationBoxStorage] Exported yearly report to $outputFile');
    }
  }

  /// Export 12-Month Jan-Dec Matrix Report for ALL Boxes in branch to Excel
  static Future<void> exportAllBoxesYearlyReport({
    required String branchId,
    required String branchName,
    required int year,
  }) async {
    final boxes = getBoxes(branchId);
    final excel = Excel.createExcel();
    final sheetName = 'Boxes Annual $year';
    final sheet = excel[sheetName];
    excel.delete('Sheet1');

    // Header Info
    sheet.appendRow([TextCellValue('GMWF Donation Boxes — Annual 12-Month Performance Report')]);
    sheet.appendRow([TextCellValue('Branch: $branchName ($branchId)')]);
    sheet.appendRow([TextCellValue('Year: $year (January – December)')]);
    sheet.appendRow([TextCellValue('Total Registered Boxes: ${boxes.length}')]);
    sheet.appendRow([TextCellValue('Generated At: ${DateFormat('yyyy-MM-dd HH:mm').format(DateTime.now())}')]);
    sheet.appendRow([]); // Blank row

    // Table Header
    final headers = [
      'Box #',
      'Holder Name',
      'Phone',
      'Area',
      'Address',
      'Jan',
      'Feb',
      'Mar',
      'Apr',
      'May',
      'Jun',
      'Jul',
      'Aug',
      'Sep',
      'Oct',
      'Nov',
      'Dec',
      'Total Amount (PKR)',
      'Opened Months (out of 12)',
    ];
    sheet.appendRow(headers.map((h) => TextCellValue(h)).toList());

    final List<double> monthlyTotals = List.filled(12, 0.0);
    double grandTotal = 0.0;

    for (final box in boxes) {
      final report = getYearlyReport(box.id, year);
      double boxTotal = 0.0;
      int openedMonths = 0;
      final List<CellValue> row = [
        TextCellValue(box.boxNumber),
        TextCellValue(box.holderName),
        TextCellValue(box.holderPhone),
        TextCellValue(box.area),
        TextCellValue(box.holderAddress),
      ];

      for (int m = 0; m < 12; m++) {
        final monthReport = report.firstWhere((r) => r.month == m + 1);
        if (monthReport.wasOpened) {
          row.add(DoubleCellValue(monthReport.amount));
          boxTotal += monthReport.amount;
          monthlyTotals[m] += monthReport.amount;
          openedMonths++;
        } else {
          row.add(TextCellValue('-'));
        }
      }

      grandTotal += boxTotal;
      row.add(DoubleCellValue(boxTotal));
      row.add(TextCellValue('$openedMonths / 12'));
      sheet.appendRow(row);
    }

    // Grand Total Row
    sheet.appendRow([]);
    final totalRow = <CellValue>[
      TextCellValue('GRAND TOTAL'),
      TextCellValue(''),
      TextCellValue(''),
      TextCellValue(''),
    ];
    for (int m = 0; m < 12; m++) {
      totalRow.add(DoubleCellValue(monthlyTotals[m]));
    }
    totalRow.add(DoubleCellValue(grandTotal));
    totalRow.add(TextCellValue(''));
    sheet.appendRow(totalRow);

    final bytes = excel.encode();
    if (bytes == null) return;

    final String? outputFile = await FilePicker.platform.saveFile(
      dialogTitle: 'Save Annual Donation Boxes Report ($year)',
      fileName: 'Donation_Boxes_Report_${year}_${branchId.replaceAll(' ', '_')}.xlsx',
      type: FileType.custom,
      allowedExtensions: ['xlsx'],
    );

    if (outputFile != null) {
      final file = File(outputFile);
      await file.writeAsBytes(bytes);
      debugPrint('[DonationBoxStorage] Exported all boxes yearly report to $outputFile');
    }
  }

  // ══════════════════════════════════════════════════════════════════════════
  // FIRESTORE SYNC
  // ══════════════════════════════════════════════════════════════════════════

  static Future<void> downloadBoxes(String branchId) async {
    try {
      final db = FirebaseFirestore.instance;
      List<String> targetBranches = [];
      if (branchId == 'all' || branchId.isEmpty) {
        final bSnap = await db.collection('branches').get();
        targetBranches = bSnap.docs.map((d) => d.id).toList();
      } else {
        targetBranches = [branchId];
      }

      final hiveBox = Hive.box(boxesBoxName);
      final openingsBox = Hive.box(openingsBoxName);
      int totalBoxes = 0;

      for (final bId in targetBranches) {
        final snap = await db
            .collection('branches')
            .doc(bId)
            .collection('donation_boxes')
            .get();
        totalBoxes += snap.docs.length;
        for (var doc in snap.docs) {
          final data = doc.data();
          data['firestoreId'] = doc.id;
          data['syncStatus'] = 'synced';
          final key = '${bId}_box_${doc.id}';
          await hiveBox.put(key, data);
        }

        // Download openings for each box
        for (var doc in snap.docs) {
          final openSnap = await db
              .collection('branches')
              .doc(bId)
              .collection('donation_boxes')
              .doc(doc.id)
              .collection('openings')
              .get();
          for (var openDoc in openSnap.docs) {
            final data = openDoc.data();
            data['firestoreId'] = openDoc.id;
            data['syncStatus'] = 'synced';
            final key = '${bId}_opening_${openDoc.id}';
            await openingsBox.put(key, data);
          }
        }
      }
      await hiveBox.flush();
      await openingsBox.flush();
      debugPrint('[DonationBoxStorage] Downloaded $totalBoxes boxes for $branchId');
    } catch (e) {
      debugPrint('[DonationBoxStorage] Download failed: $e');
    }
  }

  static void _enqueueBoxSync(DonationBox box) {
    try {
      final syncBox = Hive.box(LocalStorageService.syncBox);
      syncBox.put('dbox_${box.id}', {
        'event_type': 'save_donation_box',
        'data': box.toMap(),
        'boxId': box.id,
        'branchId': box.branchId,
        'timestamp': DateTime.now().toIso8601String(),
      });
    } catch (e) {
      debugPrint('[DonationBoxStorage] Enqueue box sync failed: $e');
    }
  }

  static void _enqueueOpeningSync(BoxOpening opening) {
    try {
      final syncBox = Hive.box(LocalStorageService.syncBox);
      syncBox.put('dbox_open_${opening.id}', {
        'event_type': 'save_box_opening',
        'data': opening.toMap(),
        'openingId': opening.id,
        'boxId': opening.boxId,
        'branchId': opening.branchId,
        'timestamp': DateTime.now().toIso8601String(),
      });
    } catch (e) {
      debugPrint('[DonationBoxStorage] Enqueue opening sync failed: $e');
    }
  }

  /// Sync a box to Firestore (called by ServerSyncManager or SyncService)
  static Future<bool> syncBoxToFirestore(Map<String, dynamic> data) async {
    try {
      final branchId = data['branchId'] as String?;
      if (branchId == null || branchId.isEmpty) return false;

      final db = FirebaseFirestore.instance;
      final boxData = data['data'] as Map<String, dynamic>? ?? data;
      final boxNumber = boxData['boxNumber'] as String? ?? '';

      final docRef = db
          .collection('branches')
          .doc(branchId)
          .collection('donation_boxes')
          .doc(boxNumber.isNotEmpty ? boxNumber : null);

      await docRef.set({
        ...boxData,
        'syncedAt': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));

      return true;
    } catch (e) {
      debugPrint('[DonationBoxStorage] syncBoxToFirestore failed: $e');
      return false;
    }
  }

  /// Sync an opening to Firestore
  static Future<bool> syncOpeningToFirestore(Map<String, dynamic> data) async {
    try {
      final branchId = data['branchId'] as String?;
      final boxId = data['boxId'] as String?;
      if (branchId == null || branchId.isEmpty) return false;

      final db = FirebaseFirestore.instance;
      final openData = data['data'] as Map<String, dynamic>? ?? data;
      final boxNumber = openData['boxNumber'] as String? ?? '';

      // Find or use the box number as the parent doc ID
      final parentDocId = boxNumber.isNotEmpty ? boxNumber : (boxId ?? 'unknown');

      final docRef = db
          .collection('branches')
          .doc(branchId)
          .collection('donation_boxes')
          .doc(parentDocId)
          .collection('openings')
          .doc();

      await docRef.set({
        ...openData,
        'syncedAt': FieldValue.serverTimestamp(),
      });

      return true;
    } catch (e) {
      debugPrint('[DonationBoxStorage] syncOpeningToFirestore failed: $e');
      return false;
    }
  }
}
