import 'dart:convert';
import 'dart:io' show File;

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:path/path.dart' as p;
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:intl/intl.dart';

import 'dart:async';
import 'madrassa_local_storage.dart';

enum MadrassaCsvType { students, dailyLogs, auditLog, unknown }

class MadrassaImportResult {
  final MadrassaCsvType type;
  final int imported;
  final int skipped;
  final String message;

  const MadrassaImportResult({
    required this.type,
    required this.imported,
    required this.skipped,
    required this.message,
  });
}

class MadrassaCsvService {
  static String _esc(dynamic v) {
    final s = (v ?? '').toString().replaceAll('"', '""');
    return '"$s"';
  }

  static List<String> splitCsvLine(String line) {
    final result = <String>[];
    final sb = StringBuffer();
    var inQuotes = false;
    for (var i = 0; i < line.length; i++) {
      final char = line[i];
      if (char == '"') {
        if (inQuotes && i + 1 < line.length && line[i + 1] == '"') {
          sb.write('"');
          i++;
        } else {
          inQuotes = !inQuotes;
        }
      } else if (char == ',' && !inQuotes) {
        result.add(sb.toString().trim());
        sb.clear();
      } else {
        sb.write(char);
      }
    }
    result.add(sb.toString().trim());
    return result;
  }

  static List<Map<String, String>> parseCsvRows(String csvText) {
    final normalized = csvText.replaceAll('\r\n', '\n').replaceAll('\r', '\n');
    final lines = normalized.split('\n');
    if (lines.isEmpty) return [];

    final headers = splitCsvLine(lines.first.trim())
        .map((h) => h.replaceAll('"', '').trim().toLowerCase().replaceAll(RegExp(r'[\s_\-\.]'), ''))
        .toList();

    final rows = <Map<String, String>>[];
    for (var i = 1; i < lines.length; i++) {
      final line = lines[i].trim();
      if (line.isEmpty) continue;
      final values = splitCsvLine(line);
      final row = <String, String>{};
      for (var j = 0; j < headers.length; j++) {
        if (j < values.length) {
          row[headers[j]] = values[j].replaceAll('"', '').trim();
        }
      }
      rows.add(row);
    }
    return rows;
  }

  static MadrassaCsvType detectCsvType(String csvText) {
    final normalized = csvText.replaceAll('\r\n', '\n').replaceAll('\r', '\n');
    final headerLine = normalized.split('\n').first.trim().toLowerCase();
    final normLine = headerLine.replaceAll(RegExp(r'[\s_\-\.]'), '');

    if (normLine.contains('eventtype') && normLine.contains('studentid')) {
      return MadrassaCsvType.auditLog;
    }
    if (normLine.contains('date') &&
        (normLine.contains('studentid') || normLine.contains('studentname') || normLine.contains('name')) &&
        (normLine.contains('present') || normLine.contains('attendance') || normLine.contains('leave'))) {
      return MadrassaCsvType.dailyLogs;
    }
    if (normLine.contains('rollnumber') || normLine.contains('roll')) {
      return MadrassaCsvType.students;
    }
    return MadrassaCsvType.unknown;
  }

  static bool _parseBool(String? value) {
    if (value == null || value.isEmpty) return false;
    final v = value.toLowerCase();
    return v == 'true' || v == '1' || v == 'yes' || v == 'y';
  }

  static DateTime? _parseDate(String? value) {
    if (value == null || value.isEmpty) return null;
    try {
      return DateTime.parse(value);
    } catch (_) {
      try {
        return DateFormat('yyyy-MM-dd').parse(value);
      } catch (_) {
        return null;
      }
    }
  }

  static String _formatTimestamp(dynamic value) {
    if (value == null) return '';
    if (value is Timestamp) return value.toDate().toIso8601String();
    if (value is DateTime) return value.toIso8601String();
    if (value is String) return value;
    return value.toString();
  }

  static CollectionReference<Map<String, dynamic>> _studentsRef(String branchId) {
    return FirebaseFirestore.instance
        .collection('branches')
        .doc(branchId)
        .collection('madrassa_students');
  }

  static CollectionReference<Map<String, dynamic>> _logsRef(String branchId) {
    return FirebaseFirestore.instance
        .collection('branches')
        .doc(branchId)
        .collection('madrassa_daily_logs');
  }

  // ─── Export ────────────────────────────────────────────────────────────────

  static Future<Map<String, String>> buildExportFiles(String branchId) async {
    // 1. Search local storage (Hive) first
    var localStudents = MadrassaLocalStorage.getAllStudentsCached(branchId);
    var localLogs = MadrassaLocalStorage.getAllLogsCached(branchId);

    // 2. If local cache has 0 students, fallback download from Firestore
    if (localStudents.isEmpty) {
      await MadrassaLocalStorage.downloadStudents(branchId, force: true);
      localStudents = MadrassaLocalStorage.getAllStudentsCached(branchId);
    }
    if (localLogs.isEmpty) {
      final now = DateTime.now();
      await MadrassaLocalStorage.downloadLogsForMonth(branchId, now.year, now.month);
      localLogs = MadrassaLocalStorage.getAllLogsCached(branchId);
    }

    final studentsById = <String, Map<String, dynamic>>{};
    for (final s in localStudents) {
      final id = s['id']?.toString() ?? '';
      if (id.isNotEmpty) {
        studentsById[id] = s;
      }
    }

    return {
      'Student_export.csv': _buildStudentsCsv(localStudents),
      'DailyLog_export.csv': _buildDailyLogsCsv(localLogs, studentsById),
      'StudentAuditLog_export.csv': _buildAuditLogCsv(localStudents),
    };
  }

  static String _buildStudentsCsv(List<Map<String, dynamic>> students) {
    final sb = StringBuffer();
    sb.writeln(
      'class_section,guardian_name,name,active,photo_url,roll_number,guardian_phone,status,id,student_cnic,guardian_cnic,current_lines,join_date,has_prev_madrassa,prev_madrassa_name,prev_hifz_lines,batch',
    );
    for (final d in students) {
      var status = (d['status'] ?? '').toString().trim();
      if (status.isEmpty) {
        status = d['active'] == true ? 'active' : 'inactive';
      }
      final active = status == 'active' ? 'TRUE' : 'FALSE';
      final batch = d['batch'] ?? 'active';
      sb.writeln([
        _esc(d['class'] ?? ''),
        _esc(d['guardianName'] ?? ''),
        _esc(d['name'] ?? ''),
        _esc(active),
        _esc(d['photoUrl'] ?? ''),
        _esc(d['rollNumber'] ?? ''),
        _esc(d['contactPhone'] ?? ''),
        _esc(status),
        _esc(d['id'] ?? ''),
        _esc(d['studentCnic'] ?? ''),
        _esc(d['guardianCnic'] ?? ''),
        _esc(d['currentLines'] ?? 0),
        _esc(_formatTimestamp(d['joinDate'])),
        _esc(d['hasPrevMadrassa'] ?? false),
        _esc(d['prevMadrassaName'] ?? ''),
        _esc(d['prevHifzLines'] ?? 0),
        _esc(batch),
      ].join(','));
    }
    return sb.toString();
  }

  static String _buildDailyLogsCsv(
    List<Map<String, dynamic>> logDocs,
    Map<String, Map<String, dynamic>> studentsById,
  ) {
    final sb = StringBuffer();
    sb.writeln(
      'date,student_name,uniform,is_ptm_day,leave,ptm,student_id,present,message,id,current_lines,sabki_para,sabki_ratio,manzil_para,manzil_ratio',
    );

    final sortedDocs = [...logDocs]..sort((a, b) => (a['id'] ?? a['dateKey'] ?? '').toString().compareTo((b['id'] ?? b['dateKey'] ?? '').toString()));
    for (final doc in sortedDocs) {
      final date = (doc['id'] ?? doc['dateKey'] ?? '').toString();
      if (date.isEmpty) continue;
      doc.forEach((studentId, rawLog) {
        if (studentId.startsWith('_') || studentId == 'id' || studentId == 'dateKey' || rawLog is! Map) return;
        final log = Map<String, dynamic>.from(rawLog);
        final student = studentsById[studentId];
        final attendance = (log['attendance'] ?? 'absent').toString();
        final isPresent = attendance == 'present';
        final isLeave = attendance == 'leave';
        sb.writeln([
          _esc(date),
          _esc(student?['name'] ?? log['studentName'] ?? ''),
          _esc((isLeave || log['uniform'] == true || log['uniform'] == 'leave').toString()),
          _esc('false'),
          _esc(isLeave.toString()),
          _esc((log['ptm'] ?? false).toString()),
          _esc(studentId),
          _esc(isPresent.toString()),
          _esc((log['parentReplied'] ?? log['message'] ?? false).toString()),
          _esc('${date}_$studentId'),
          _esc((log['currentLines'] ?? 0).toString()),
          _esc((log['sabkiPara'] ?? 0).toString()),
          _esc((log['sabkiRatio'] ?? '').toString()),
          _esc((log['manzilPara'] ?? 0).toString()),
          _esc((log['manzilRatio'] ?? '').toString()),
        ].join(','));
      });
    }
    return sb.toString();
  }

  static String _buildAuditLogCsv(List<Map<String, dynamic>> students) {
    final sb = StringBuffer();
    sb.writeln(
      'student_name,note,event_type,to_status,event_date,student_id,from_status,id',
    );

    var rowId = 0;
    for (final d in students) {
      final studentId = d['id']?.toString() ?? '';
      final name = d['name']?.toString() ?? '';
      final rawAudit = d['auditLog'];
      final auditList = (rawAudit is List ? rawAudit : []).whereType<Map>().map((e) => Map<String, dynamic>.from(e)).toList();
      for (final entry in auditList) {
        final status = entry['status']?.toString() ?? '';
        final type = entry['type']?.toString() ?? 'status_change';
        final eventType = _mapTypeToEventType(type, status);
        sb.writeln([
          _esc(name),
          _esc(entry['reason'] ?? entry['note'] ?? ''),
          _esc(eventType),
          _esc(status),
          _esc(_formatTimestamp(entry['date'])),
          _esc(studentId),
          _esc(entry['fromStatus'] ?? ''),
          _esc('audit_${studentId}_$rowId'),
        ].join(','));
        rowId++;
      }
    }
    return sb.toString();
  }

  static String _mapTypeToEventType(String type, String status) {
    if (type == 'enrollment') return 'enrollment';
    if (status == 'on_leave') return 'on_leave';
    if (status == 'active' && type == 'status_change') return 'rejoined';
    if (status == 'hifz_completed' || status == 'hifz_done') return 'hifz_done';
    return type;
  }

  static Future<int> saveCsvFile(String fileName, String content) async {
    final bytes = utf8.encode(content);
    final result = await FilePicker.platform.saveFile(
      dialogTitle: 'Save $fileName',
      fileName: fileName,
      bytes: bytes,
      type: FileType.custom,
      allowedExtensions: ['csv'],
    );
    return result == null ? 0 : 1;
  }

  static Future<int> exportAll(String branchId) async {
    final files = await buildExportFiles(branchId);
    if (kIsWeb) {
      var saved = 0;
      for (final entry in files.entries) {
        saved += await saveCsvFile(entry.key, entry.value);
      }
      return saved;
    }

    final dirPath = await FilePicker.platform.getDirectoryPath(
      dialogTitle: 'Select folder for CSV export',
    );
    if (dirPath == null) return 0;

    for (final entry in files.entries) {
      final file = File(p.join(dirPath, entry.key));
      await file.writeAsString(entry.value, encoding: utf8);
    }
    return files.length;
  }

  static Future<int> exportSingle(String branchId, MadrassaCsvType type) async {
    final files = await buildExportFiles(branchId);
    final fileName = switch (type) {
      MadrassaCsvType.students => 'Student_export.csv',
      MadrassaCsvType.dailyLogs => 'DailyLog_export.csv',
      MadrassaCsvType.auditLog => 'StudentAuditLog_export.csv',
      MadrassaCsvType.unknown => '',
    };
    if (fileName.isEmpty) return 0;
    return saveCsvFile(fileName, files[fileName]!);
  }

  // ─── Import ────────────────────────────────────────────────────────────────

  static Future<MadrassaImportResult> importCsv({
    required String branchId,
    required String csvText,
    MadrassaCsvType? forcedType,
    required String editor,
  }) async {
    final type = forcedType ?? detectCsvType(csvText);
    if (type == MadrassaCsvType.unknown) {
      return const MadrassaImportResult(
        type: MadrassaCsvType.unknown,
        imported: 0,
        skipped: 0,
        message: 'Could not detect CSV type from headers.',
      );
    }

    final rows = parseCsvRows(csvText);
    if (rows.isEmpty) {
      return MadrassaImportResult(
        type: type,
        imported: 0,
        skipped: 0,
        message: 'No data rows found in CSV.',
      );
    }

    return switch (type) {
      MadrassaCsvType.students => await _importStudents(branchId, rows, editor),
      MadrassaCsvType.dailyLogs => await _importDailyLogs(branchId, rows),
      MadrassaCsvType.auditLog => await _importAuditLogs(branchId, rows),
      _ => const MadrassaImportResult(
          type: MadrassaCsvType.unknown,
          imported: 0,
          skipped: 0,
          message: 'Unsupported CSV type.',
        ),
    };
  }

  static String _normalizePhoneNumber(String raw) {
    var cleaned = raw.replaceAll(RegExp(r'[^0-9]'), '');
    if (cleaned.isEmpty) return '';

    // If it starts with 92 and has 12 digits, convert to 03... (replace 92 with 0)
    if (cleaned.startsWith('92') && cleaned.length == 12) {
      cleaned = '0${cleaned.substring(2)}';
    }

    // If it starts with 3 and is 10 digits, prepend 0
    if (cleaned.startsWith('3') && cleaned.length == 10) {
      cleaned = '0$cleaned';
    }

    return cleaned;
  }

  static Future<MadrassaImportResult> _importStudents(
    String branchId,
    List<Map<String, String>> rows,
    String editor,
  ) async {
    var imported = 0;
    var skipped = 0;
    final now = DateTime.now();

    final existingStudents = await _studentsRef(branchId).get();

    // Map of ID -> Document
    final studentsById = <String, DocumentSnapshot<Map<String, dynamic>>>{
      for (var doc in existingStudents.docs) doc.id: doc
    };

    // Map of RollNumber -> Document
    final studentsByRoll = <String, DocumentSnapshot<Map<String, dynamic>>>{};
    for (final doc in existingStudents.docs) {
      final roll = doc.data()['rollNumber']?.toString().trim();
      if (roll != null && roll.isNotEmpty) {
        studentsByRoll[roll] = doc;
      }
    }

    for (final row in rows) {
      final name = _firstNonEmpty(row, ['name', 'studentname']);
      final rollNumber = _firstNonEmpty(row, ['rollnumber', 'roll']);
      if (name.isEmpty || rollNumber.isEmpty) {
        skipped++;
        continue;
      }

      final docId = row['id']?.trim();
      final normalizedPhone = _normalizePhoneNumber(
        _firstNonEmpty(row, ['guardianphone', 'contactphone', 'phone']),
      );

      final status = _firstNonEmpty(row, ['status']).isEmpty
          ? (_parseBool(row['active']) ? 'active' : 'inactive')
          : _firstNonEmpty(row, ['status']);
      final batch = _firstNonEmpty(row, ['batch'], fallback: 'active');
      final joinDate = _parseDate(_firstNonEmpty(row, ['joindate', 'createddate'])) ?? now;
      final studentCnic = _firstNonEmpty(row, ['studentcnic']);
      final classSection = _firstNonEmpty(row, ['classsection', 'class', 'classname'], fallback: 'Hifz');
      final guardianName = _firstNonEmpty(row, ['guardianname']);
      final guardianCnic = _firstNonEmpty(row, ['guardiancnic']);
      final photoUrl = _firstNonEmpty(row, ['photourl']);
      final currentLines = int.tryParse(_firstNonEmpty(row, ['currentlines', 'lines'])) ?? 0;
      final hasPrevMadrassa = _parseBool(_firstNonEmpty(row, ['hasprevmadrassa', 'has_prev_madrassa']));
      final prevMadrassaName = _firstNonEmpty(row, ['prevmadrassaname', 'prev_madrassa_name', 'previousmadrassa']);
      final prevHifzLines = int.tryParse(_firstNonEmpty(row, ['prevhifzlines', 'prev_hifz_lines', 'priorhifzlines'])) ?? 0;

      // Find existing student
      DocumentSnapshot<Map<String, dynamic>>? existingDoc;
      if (docId != null && docId.isNotEmpty && studentsById.containsKey(docId)) {
        existingDoc = studentsById[docId];
      } else if (studentsByRoll.containsKey(rollNumber)) {
        existingDoc = studentsByRoll[rollNumber];
      }

      if (existingDoc != null) {
        // Check for updates
        final extData = existingDoc.data() ?? {};
        final extName = extData['name']?.toString() ?? '';
        final extRoll = extData['rollNumber']?.toString() ?? '';
        final extCnic = extData['studentCnic']?.toString() ?? '';
        final extClass = extData['class']?.toString() ?? '';
        final extGuardian = extData['guardianName']?.toString() ?? '';
        final extGuardianCnic = extData['guardianCnic']?.toString() ?? '';
        final extPhone = extData['contactPhone']?.toString() ?? '';
        final extPhoto = extData['photoUrl']?.toString() ?? '';
        final extStatus = extData['status']?.toString() ?? '';
        final extLines = extData['currentLines'] is int ? extData['currentLines'] as int : (int.tryParse(extData['currentLines']?.toString() ?? '') ?? 0);
        final extHasPrev = extData['hasPrevMadrassa'] ?? false;
        final extPrevName = extData['prevMadrassaName'] ?? '';
        final extPrevLines = extData['prevHifzLines'] is int ? extData['prevHifzLines'] as int : (int.tryParse(extData['prevHifzLines']?.toString() ?? '') ?? 0);

        DateTime? extJoinDate;
        if (extData['joinDate'] is Timestamp) {
          extJoinDate = (extData['joinDate'] as Timestamp).toDate();
        } else if (extData['joinDate'] is String) {
          extJoinDate = DateTime.tryParse(extData['joinDate']);
        }

        final bool hasChanged = extName != name ||
            extRoll != rollNumber ||
            extCnic != studentCnic ||
            extClass != classSection ||
            extGuardian != guardianName ||
            extGuardianCnic != guardianCnic ||
            extPhone != normalizedPhone ||
            (photoUrl.isNotEmpty && extPhoto != photoUrl) ||
            extStatus != status ||
            extLines != currentLines ||
            extHasPrev != hasPrevMadrassa ||
            extPrevName != prevMadrassaName ||
            extPrevLines != prevHifzLines ||
            (extJoinDate == null || extJoinDate.year != joinDate.year || extJoinDate.month != joinDate.month || extJoinDate.day != joinDate.day);

        if (hasChanged) {
          final updateData = <String, dynamic>{
            'name': name,
            'rollNumber': rollNumber,
            'studentCnic': studentCnic,
            'class': classSection,
            'guardianName': guardianName,
            'guardianCnic': guardianCnic,
            'contactPhone': normalizedPhone,
            if (photoUrl.isNotEmpty) 'photoUrl': photoUrl,
            'status': status,
            'batch': batch,
            'currentLines': currentLines,
            'joinDate': Timestamp.fromDate(joinDate),
            'hasPrevMadrassa': hasPrevMadrassa || prevMadrassaName.isNotEmpty,
            'prevMadrassaName': prevMadrassaName,
            'prevHifzLines': prevHifzLines,
            'enrolledMonth': DateFormat('yyyy-MM').format(joinDate),
            'lastUpdatedAt': FieldValue.serverTimestamp(),
          };

          // Append audit log for modifications
          final reason = 'CSV Import Update by $editor';
          updateData['auditLog'] = FieldValue.arrayUnion([
            {
              'status': status,
              'type': 'status_change',
              'date': Timestamp.fromDate(now),
              'reason': reason,
            }
          ]);

          await _studentsRef(branchId).doc(existingDoc.id).update(updateData);

          // Refresh our maps
          final updatedSnap = await _studentsRef(branchId).doc(existingDoc.id).get();
          studentsById[existingDoc.id] = updatedSnap;
          if (rollNumber != extRoll) {
            studentsByRoll.remove(extRoll);
          }
          studentsByRoll[rollNumber] = updatedSnap;

          imported++;
        } else {
          skipped++;
        }
      } else {
        // Insert new student
        final data = <String, dynamic>{
          'name': name,
          'rollNumber': rollNumber,
          'studentCnic': studentCnic,
          'class': classSection,
          'guardianName': guardianName,
          'guardianCnic': guardianCnic,
          'contactPhone': normalizedPhone,
          'photoUrl': photoUrl,
          'status': status,
          'batch': batch,
          'branchId': branchId,
          'currentLines': currentLines,
          'joinDate': Timestamp.fromDate(joinDate),
          'hasPrevMadrassa': hasPrevMadrassa || prevMadrassaName.isNotEmpty,
          'prevMadrassaName': prevMadrassaName,
          'prevHifzLines': prevHifzLines,
          'enrolledMonth': DateFormat('yyyy-MM').format(joinDate),
          'createdAt': FieldValue.serverTimestamp(),
          'lastUpdatedAt': FieldValue.serverTimestamp(),
          'auditLog': [
            {
              'status': status,
              'type': 'enrollment',
              'date': Timestamp.fromDate(joinDate),
              'reason': 'CSV Import by $editor',
            }
          ],
        };

        final ref = _studentsRef(branchId);
        if (docId != null && docId.isNotEmpty) {
          await ref.doc(docId).set(data);
          final newDoc = await ref.doc(docId).get();
          studentsById[docId] = newDoc;
          studentsByRoll[rollNumber] = newDoc;
        } else {
          final docRef = await ref.add(data);
          final newDoc = await docRef.get();
          studentsById[newDoc.id] = newDoc;
          studentsByRoll[rollNumber] = newDoc;
        }
        imported++;
      }
    }

    return MadrassaImportResult(
      type: MadrassaCsvType.students,
      imported: imported,
      skipped: skipped,
      message: 'Imported/Updated $imported student(s)${skipped > 0 ? ', skipped $skipped' : ''}.',
    );
  }

  // ── UPDATED: merges into existing entries AND now writes a CSV of every
  // unmatched row (date, csv student_id, roll, name) so you can see exactly
  // which rows failed to find a student and why ───────────────────────────────
  static Future<MadrassaImportResult> _importDailyLogs(
    String branchId,
    List<Map<String, String>> rows,
  ) async {
    final studentsSnap = await _studentsRef(branchId).get();
    final byId = <String, QueryDocumentSnapshot<Map<String, dynamic>>>{};
    final byRoll = <String, String>{};
    final byNormalizedName = <String, String>{};
    for (final doc in studentsSnap.docs) {
      byId[doc.id] = doc;
      final roll = doc.data()['rollNumber']?.toString().trim();
      if (roll != null && roll.isNotEmpty) byRoll[roll] = doc.id;
      final name = doc.data()['name']?.toString().trim() ?? '';
      if (name.isNotEmpty) {
        byNormalizedName[_normName(name)] = doc.id;
      }
    }

    final grouped = <String, Map<String, dynamic>>{};
    final unmatchedRows = <Map<String, String>>[];
    var imported = 0;
    var skippedBadDate = 0;
    var skippedNoMatch = 0;

    for (final row in rows) {
      final dateRaw = _firstNonEmpty(row, ['date']);
      final parsedDate = _parseDate(dateRaw);
      if (parsedDate == null) {
        skippedBadDate++;
        continue;
      }
      final dateKey = DateFormat('yyyy-MM-dd').format(parsedDate);

      final rawId = _firstNonEmpty(row, ['studentid', 'id']);
      final rawRoll = _firstNonEmpty(row, ['rollnumber', 'roll']);
      final rawName = _firstNonEmpty(row, ['studentname', 'name']);

      var studentId = rawId;
      if (studentId.isEmpty || !byId.containsKey(studentId)) {
        if (rawRoll.isNotEmpty && byRoll.containsKey(rawRoll)) {
          studentId = byRoll[rawRoll]!;
        }
      }
      if (studentId.isEmpty || !byId.containsKey(studentId)) {
        if (rawName.isNotEmpty) {
          final match = byNormalizedName[_normName(rawName)];
          if (match != null) studentId = match;
        }
      }
      if (studentId.isEmpty || !byId.containsKey(studentId)) {
        skippedNoMatch++;
        unmatchedRows.add({
          'date': dateKey,
          'csv_student_id': rawId,
          'csv_roll_number': rawRoll,
          'csv_student_name': rawName,
        });
        continue;
      }

      final attendanceRaw = _firstNonEmpty(row, ['attendance']).toLowerCase();
      String attendance;
      if (attendanceRaw.isNotEmpty) {
        attendance = attendanceRaw;
      } else if (_parseBool(row['leave'])) {
        attendance = 'leave';
      } else if (_parseBool(row['present'])) {
        attendance = 'present';
      } else {
        attendance = 'absent';
      }

      final logEntry = <String, dynamic>{
        'attendance': attendance,
        'uniform': _parseBool(row['uniform']),
        'parentReplied': _parseBool(row['message']) || _parseBool(row['parentreplied']),
        'ptm': _parseBool(row['ptm']),
      };

      final lines = int.tryParse(_firstNonEmpty(row, ['current_lines', 'currentlines', 'sabaklines', 'lines']));
      if (lines != null) logEntry['currentLines'] = lines;

      final sabkiPara = int.tryParse(_firstNonEmpty(row, ['sabki_para', 'sabkipara']));
      if (sabkiPara != null) logEntry['sabkiPara'] = sabkiPara;

      final sabkiRatio = _firstNonEmpty(row, ['sabki_ratio', 'sabkiratio']);
      if (sabkiRatio.isNotEmpty) logEntry['sabkiRatio'] = sabkiRatio;

      final manzilPara = int.tryParse(_firstNonEmpty(row, ['manzil_para', 'manzilpara']));
      if (manzilPara != null) logEntry['manzilPara'] = manzilPara;

      final manzilRatio = _firstNonEmpty(row, ['manzil_ratio', 'manzilratio']);
      if (manzilRatio.isNotEmpty) logEntry['manzilRatio'] = manzilRatio;

      grouped.putIfAbsent(dateKey, () => {});
      grouped[dateKey]![studentId] = logEntry;
      imported++;
    }

    // Only skip a matched row if EVERY field it carries already matches what's
    // stored. If a field is missing or different, keep the row so it merges in.
    var skippedIdentical = 0;
    for (final dateKey in grouped.keys.toList()) {
      final docRef = _logsRef(branchId).doc(dateKey);
      final docSnap = await docRef.get();
      if (docSnap.exists) {
        final existingData = docSnap.data() ?? {};
        final importData = grouped[dateKey]!;
        final beforeCount = importData.length;

        importData.removeWhere((studentId, newLogRaw) {
          final existingRaw = existingData[studentId];
          if (existingRaw is! Map) return false; // no existing entry -> keep (new)

          final existingLog = Map<String, dynamic>.from(existingRaw);
          final newLog = Map<String, dynamic>.from(newLogRaw as Map);

          for (final fieldEntry in newLog.entries) {
            final existingVal = existingLog[fieldEntry.key];
            if (existingVal?.toString() != fieldEntry.value?.toString()) {
              return false; // missing or different -> keep, will merge
            }
          }
          return true; // every field already matches -> nothing to update
        });

        final removedCount = beforeCount - importData.length;
        imported -= removedCount;
        skippedIdentical += removedCount;

        if (importData.isEmpty) {
          grouped.remove(dateKey);
        }
      }
    }

    WriteBatch? batch = FirebaseFirestore.instance.batch();
    var ops = 0;
    for (final entry in grouped.entries) {
      final docRef = _logsRef(branchId).doc(entry.key);
      batch!.set(docRef, entry.value, SetOptions(merge: true));
      ops++;
      if (ops >= 450) {
        await batch.commit();
        batch = FirebaseFirestore.instance.batch();
        ops = 0;
      }
    }
    if (ops > 0) await batch!.commit();

    // Write out a CSV of every unmatched row so you can see exactly which
    // dates/names/ids failed to find a student, instead of just a 5-name sample.
    var unmatchedFileNote = '';
    if (unmatchedRows.isNotEmpty) {
      unmatchedFileNote = ' ${unmatchedRows.length} row(s) were unmatched (no student record matches these IDs/names).';
    }

    final totalSkipped = skippedBadDate + skippedNoMatch + skippedIdentical;

    return MadrassaImportResult(
      type: MadrassaCsvType.dailyLogs,
      imported: imported,
      skipped: totalSkipped,
      message: 'Imported $imported daily log row(s) across ${grouped.length} day(s). '
          'Skipped — bad date: $skippedBadDate, no matching student: $skippedNoMatch, '
          'already identical: $skippedIdentical.$unmatchedFileNote',
    );
  }

  static Future<MadrassaImportResult> _importAuditLogs(
    String branchId,
    List<Map<String, String>> rows,
  ) async {
    final studentsSnap = await _studentsRef(branchId).get();
    final byId = <String, DocumentReference<Map<String, dynamic>>>{};
    final byRoll = <String, DocumentReference<Map<String, dynamic>>>{};
    for (final doc in studentsSnap.docs) {
      byId[doc.id] = doc.reference;
      final roll = doc.data()['rollNumber']?.toString().trim();
      if (roll != null && roll.isNotEmpty) byRoll[roll] = doc.reference;
    }

    var imported = 0;
    var skipped = 0;

    for (final row in rows) {
      var studentId = _firstNonEmpty(row, ['studentid', 'id']);
      DocumentReference<Map<String, dynamic>>? ref;
      if (studentId.isNotEmpty) {
        ref = byId[studentId];
      } else {
        final roll = _firstNonEmpty(row, ['rollnumber', 'roll']);
        ref = byRoll[roll];
      }
      if (ref == null) {
        skipped++;
        continue;
      }

      final eventDate = _parseDate(_firstNonEmpty(row, ['eventdate', 'date']));
      if (eventDate == null) {
        skipped++;
        continue;
      }

      final toStatus = _firstNonEmpty(row, ['tostatus', 'status']);
      final eventType = _firstNonEmpty(row, ['eventtype', 'type']);
      final note = _firstNonEmpty(row, ['note', 'reason']);
      final fromStatus = _firstNonEmpty(row, ['fromstatus']);

      final entry = <String, dynamic>{
        'status': toStatus.isEmpty ? 'active' : toStatus,
        'type': _mapEventTypeToType(eventType),
        'date': Timestamp.fromDate(eventDate),
        'reason': note.isEmpty ? 'CSV Import' : note,
        if (fromStatus.isNotEmpty) 'fromStatus': fromStatus,
      };

      await ref.update({
        'auditLog': FieldValue.arrayUnion([entry]),
        if (toStatus.isNotEmpty) 'status': toStatus,
        'lastUpdatedAt': FieldValue.serverTimestamp(),
      });
      imported++;
    }

    return MadrassaImportResult(
      type: MadrassaCsvType.auditLog,
      imported: imported,
      skipped: skipped,
      message: 'Imported $imported audit log entry(ies)${skipped > 0 ? ', skipped $skipped' : ''}.',
    );
  }

  static String _mapEventTypeToType(String eventType) {
    switch (eventType.toLowerCase()) {
      case 'enrollment':
        return 'enrollment';
      case 'on_leave':
      case 'rejoined':
      case 'hifz_done':
      case 'restored':
        return 'status_change';
      default:
        return eventType.isEmpty ? 'status_change' : eventType;
    }
  }

  static String _normName(String s) =>
      s.trim().toLowerCase().replaceAll(RegExp(r'[^a-z0-9\u0600-\u06FF]'), '');

  static String _firstNonEmpty(
    Map<String, String> row,
    List<String> keys, {
    String fallback = '',
  }) {
    for (final key in keys) {
      final val = row[key]?.trim();
      if (val != null && val.isNotEmpty) return val;
    }
    return fallback;
  }
}