import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:image_picker/image_picker.dart';
import 'dart:convert';
import 'dart:typed_data';
import 'dart:async';
import 'package:file_picker/file_picker.dart';
import 'package:excel/excel.dart' hide Border, BorderStyle, TextSpan;

import 'package:intl/intl.dart';
import 'package:hive_flutter/hive_flutter.dart';
import '../../../services/local_storage_service.dart';
import '../../../services/sync_service.dart';
import '../../../realtime/realtime_manager.dart';
import '../../../realtime/realtime_events.dart';
import '../../../services/user_theme_service.dart';
import '../../../services/image_upload_service.dart';
import '../utils/madrassa_local_storage.dart';
import '../widgets/student_progress_dialog.dart';
import '../utils/photo_upload_helper.dart';

import '../widgets/madrassa_status_menu.dart';
import '../../../theme/role_theme_provider.dart';
import '../dialogs/enrollment_dialog.dart';
import '../madrassa_strings.dart';
import 'student_detail_page.dart';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../providers/madrassa_providers.dart';

class StudentManagementView extends ConsumerStatefulWidget {
  final String branchId;
  final bool isAdmin;
  final String username;
  final String role;
  const StudentManagementView({
    super.key,
    required this.branchId,
    required this.isAdmin,
    required this.username,
    this.role = 'Madrassa Teacher',
  });

  @override
  ConsumerState<StudentManagementView> createState() => _StudentManagementViewState();
}

class _StudentManagementViewState extends ConsumerState<StudentManagementView> {
  bool get _canAddStudent {
    if (widget.isAdmin) return true;
    final r = widget.role.toLowerCase();
    return r.contains('admin') || r.contains('teacher') || r.contains('nazim') || r.contains('staff') || r.contains('madrassa');
  }

  String _searchQuery = '';
  String _statusFilter = 'all';
  String _sortBy = 'rollNumber';
  final Map<String, PhotoUploadStatus> _uploadStates = {};
  final Set<String> _expandedStudentIds = {};
  bool _showFilters = false;


  Future<void> _importStudentsFile() async {
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['json', 'csv', 'xlsx', 'xls'],
        withData: true,
      );

      if (result == null || result.files.isEmpty) return;

      final file = result.files.first;
      final bytes = file.bytes;
      if (bytes == null) return;

      final extension = file.extension?.toLowerCase();

      List<Map<String, dynamic>> studentsToImport = [];

      if (extension == 'json') {
        final fileContent = utf8.decode(bytes);
        final decoded = jsonDecode(fileContent);
        if (decoded is List) {
          for (var item in decoded) {
            if (item is Map<String, dynamic>) {
              studentsToImport.add(item);
            }
          }
        } else if (decoded is Map<String, dynamic>) {
          studentsToImport.add(decoded);
        }
      } else if (extension == 'csv') {
        final fileContent = utf8.decode(bytes);
        studentsToImport = _parseCsvToMap(fileContent);
      } else if (extension == 'xlsx' || extension == 'xls') {
        studentsToImport = _parseExcelToStudents(bytes);
      }

      if (studentsToImport.isEmpty) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('No valid student records found in file. Format should be JSON list or CSV.'),
              backgroundColor: Colors.red,
            ),
          );
        }
        return;
      }

      if (!mounted) return;
      final confirm = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text(
            context.isUrdu ? 'طلباء درآمد کریں' : 'Import Students',
            style: context.urduStyle(style: const TextStyle(fontWeight: FontWeight.bold)),
          ),
          content: Text(
            'Found ${studentsToImport.length} student records in the file. Would you like to import them to local cache and sync with Firestore?',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text(context.l.cancel, style: context.urduStyle()),
            ),
            ElevatedButton(
              style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF008080)),
              onPressed: () => Navigator.pop(ctx, true),
              child: Text(context.isUrdu ? 'درآمد کریں' : 'Import', style: context.urduStyle(style: const TextStyle(color: Colors.white))),
            ),
          ],
        ),
      );

      if (confirm != true) return;

      int successCount = 0;
      int skippedCount = 0;
      final now = DateTime.now();

      final cachedStudents = MadrassaLocalStorage.getAllStudentsCached(widget.branchId);
      final existingRollNumbers = cachedStudents
          .map((d) => d['rollNumber']?.toString().trim())
          .whereType<String>()
          .toSet();
      final existingIds = cachedStudents
          .map((d) => d['id']?.toString().trim())
          .whereType<String>()
          .toSet();

      for (var s in studentsToImport) {
        final name = s['name']?.toString().trim() ?? '';
        final rollNumber = s['rollNumber']?.toString().trim() ?? '';
        if (name.isEmpty || rollNumber.isEmpty) {
          skippedCount++;
          continue;
        }

        final docId = s['id']?.toString().trim();
        if (docId != null && docId.isNotEmpty && existingIds.contains(docId)) {
          skippedCount++;
          continue;
        }
        if (existingRollNumbers.contains(rollNumber)) {
          skippedCount++;
          continue;
        }

        final guardianName = s['guardianName']?.toString().trim() ?? '';
        final guardianCnic = s['guardianCnic']?.toString().trim() ?? '';
        final contactPhone = s['contactPhone']?.toString().trim() ?? s['phone']?.toString().trim() ?? '';
        final studentCnic = s['studentCnic']?.toString().trim() ?? '';
        final className = s['class']?.toString().trim() ?? 'Hifz';
        final lines = int.tryParse(s['currentLines']?.toString() ?? '') ?? 0;
        final rawHasPrev = s['hasPrevMadrassa'] ?? s['has_prev_madrassa'];
        final hasPrevMadrassa = rawHasPrev != null ? (rawHasPrev.toString().toLowerCase() == 'true' || rawHasPrev.toString() == '1') : false;
        final prevMadrassaName = s['prevMadrassaName']?.toString().trim() ?? s['prev_madrassa_name']?.toString().trim() ?? s['previousMadrassa']?.toString().trim() ?? '';
        final prevHifzLines = int.tryParse(s['prevHifzLines']?.toString() ?? s['prev_hifz_lines']?.toString() ?? s['priorHifzLines']?.toString() ?? '') ?? 0;

        final rawJoinDate = s['joindate'] ?? s['join_date'] ?? s['created_date'] ?? s['createddate'] ?? s['joinDate'] ?? s['createdDate'];
        DateTime parsedJoinDate = now;
        if (rawJoinDate != null) {
          try {
            parsedJoinDate = DateTime.parse(rawJoinDate.toString());
          } catch (_) {
            try {
              parsedJoinDate = DateFormat('yyyy-MM-dd').parse(rawJoinDate.toString());
            } catch (_) {}
          }
        }

        final finalData = {
          'name': name,
          'rollNumber': rollNumber,
          'studentCnic': studentCnic,
          'class': className,
          'guardianName': guardianName,
          'guardianCnic': guardianCnic,
          'contactPhone': contactPhone,
          'joinDate': parsedJoinDate.toIso8601String(),
          'hasPrevMadrassa': hasPrevMadrassa || prevMadrassaName.isNotEmpty,
          'prevMadrassaName': prevMadrassaName,
          'prevHifzLines': prevHifzLines,
          'branchId': widget.branchId,
          'status': 'active',
          'batch': 'active',
          'auditLog': [
            {
              'status': 'active',
              'type': 'enrollment',
              'date': parsedJoinDate.toIso8601String(),
              'reason': 'Bulk Import'
            }
          ],
          'currentLines': lines,
          'enrolledMonth': DateFormat('yyyy-MM').format(parsedJoinDate),
          'createdAt': now.toIso8601String(),
          'lastUpdatedAt': now.toIso8601String(),
          'photoUrl': '',
        };

        final savedId = await MadrassaLocalStorage.saveStudentLocalAndSync(
          branchId: widget.branchId,
          studentId: (docId != null && docId.isNotEmpty) ? docId : '',
          data: finalData,
          isNew: true,
        );

        existingIds.add(savedId);
        existingRollNumbers.add(rollNumber);
        successCount++;
      }

      if (mounted) {
        String msg = 'Successfully imported $successCount students.';
        if (skippedCount > 0) {
          msg += ' Skipped $skippedCount existing students.';
        }
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(msg),
            backgroundColor: successCount > 0 ? Colors.green : Colors.orange,
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Import failed: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  List<Map<String, dynamic>> _parseExcelToStudents(Uint8List bytes) {
    final List<Map<String, dynamic>> result = [];
    try {
      final excel = Excel.decodeBytes(bytes);
      if (excel.tables.isEmpty) return result;
      final sheet = excel.tables.values.first;

      List<String> headers = [];
      int headerRowIdx = -1;

      // Find headers
      for (int i = 0; i < sheet.rows.length; i++) {
        final row = sheet.rows[i];
        if (row.any((cell) => cell != null && cell.value != null)) {
          headers = row.map((cell) => cell?.value?.toString().replaceAll('"', '').trim().toLowerCase() ?? '').toList();
          headerRowIdx = i;
          break;
        }
      }

      if (headerRowIdx == -1 || headers.isEmpty) return result;

      for (int i = headerRowIdx + 1; i < sheet.rows.length; i++) {
        final row = sheet.rows[i];
        if (!row.any((cell) => cell != null && cell.value != null && cell.value.toString().trim().isNotEmpty)) {
          continue;
        }

        final Map<String, dynamic> studentRow = {};
        for (int j = 0; j < headers.length; j++) {
          if (j < row.length) {
            final cellVal = row[j]?.value;
            if (cellVal == null) continue;
            final valStr = cellVal.toString().trim();
            final header = headers[j];

            if (header == 'rollnumber' || header == 'roll' || header == 'roll_number') {
              studentRow['rollNumber'] = valStr;
            } else if (header == 'name' || header == 'fullname' || header == 'student_name') {
              studentRow['name'] = valStr;
            } else if (header == 'guardianname' || header == 'guardian_name') {
              studentRow['guardianName'] = valStr;
            } else if (header == 'guardiancnic' || header == 'guardian_cnic') {
              studentRow['guardianCnic'] = valStr;
            } else if (header == 'contactphone' || header == 'phone' || header == 'contact_phone') {
              studentRow['contactPhone'] = valStr;
            } else if (header == 'studentcnic' || header == 'student_cnic') {
              studentRow['studentCnic'] = valStr;
            } else if (header == 'class' || header == 'classname') {
              studentRow['class'] = valStr;
            } else if (header == 'currentlines' || header == 'lines' || header == 'progress') {
              studentRow['currentLines'] = valStr;
            } else if (header.isNotEmpty) {
              studentRow[header] = valStr;
            }
          }
        }
        result.add(studentRow);
      }
    } catch (e) {
      debugPrint("Excel Student Import Error: $e");
    }
    return result;
  }

  List<Map<String, dynamic>> _parseCsvToMap(String csvText) {
    final List<Map<String, dynamic>> result = [];
    final lines = csvText.split('\n');
    if (lines.isEmpty) return result;

    final headerLine = lines.first.trim();
    final headers = headerLine.split(',').map((h) => h.replaceAll('"', '').trim().toLowerCase()).toList();

    for (int i = 1; i < lines.length; i++) {
      final line = lines[i].trim();
      if (line.isEmpty) continue;

      final values = _splitCsvLine(line);
      final Map<String, dynamic> row = {};

      for (int j = 0; j < headers.length; j++) {
        if (j < values.length) {
          final header = headers[j];
          final val = values[j];
          if (header == 'rollnumber' || header == 'roll' || header == 'roll_number') {
            row['rollNumber'] = val;
          } else if (header == 'name' || header == 'fullname' || header == 'student_name') {
            row['name'] = val;
          } else if (header == 'guardianname' || header == 'guardian_name') {
            row['guardianName'] = val;
          } else if (header == 'guardiancnic' || header == 'guardian_cnic') {
            row['guardianCnic'] = val;
          } else if (header == 'contactphone' || header == 'phone' || header == 'contact_phone') {
            row['contactPhone'] = val;
          } else if (header == 'studentcnic' || header == 'student_cnic') {
            row['studentCnic'] = val;
          } else if (header == 'class' || header == 'classname') {
            row['class'] = val;
          } else if (header == 'currentlines' || header == 'lines' || header == 'progress') {
            row['currentLines'] = val;
          } else {
            row[header] = val;
          }
        }
      }
      result.add(row);
    }
    return result;
  }

  List<String> _splitCsvLine(String line) {
    final result = <String>[];
    StringBuffer sb = StringBuffer();
    bool inQuotes = false;
    for (int i = 0; i < line.length; i++) {
      final char = line[i];
      if (char == '"') {
        inQuotes = !inQuotes;
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

  double _calculateRecentPace(String studentId, String branchId, double overallAvg) {
    try {
      if (!Hive.isBoxOpen(LocalStorageService.madrassaLogsBox)) return overallAvg;
      final box = Hive.box(LocalStorageService.madrassaLogsBox);
      final prefix = '${branchId.toLowerCase().trim()}__log__';
      
      final logsList = <MapEntry<DateTime, int>>[];
      for (final key in box.keys) {
        if (key.toString().startsWith(prefix)) {
          final datePart = key.toString().substring(prefix.length);
          final date = DateTime.tryParse(datePart);
          if (date == null) continue;
          
          final logVal = box.get(key);
          if (logVal is Map && logVal.containsKey(studentId)) {
            final studentLog = Map<String, dynamic>.from(logVal[studentId] as Map);
            final currentLines = (studentLog['currentLines'] as num?)?.toInt() ?? int.tryParse(studentLog['currentLines']?.toString() ?? '');
            if (currentLines != null && currentLines > 0) {
              logsList.add(MapEntry(date, currentLines));
            }
          }
        }
      }
      
      if (logsList.length < 2) {
        return overallAvg;
      }
      
      // Sort chronologically
      logsList.sort((a, b) => a.key.compareTo(b.key));
      
      final latest = logsList.last;
      
      // Find reference log from 7 to 30 days ago
      MapEntry<DateTime, int>? bestRef;
      for (int i = logsList.length - 2; i >= 0; i--) {
        final ref = logsList[i];
        final daysDiff = latest.key.difference(ref.key).inDays;
        if (daysDiff >= 7 && daysDiff <= 30) {
          bestRef = ref;
          if (daysDiff >= 14) break;
        }
      }
      
      // Fallback: take oldest different log if no 7-30 days log exists
      if (bestRef == null) {
        for (final ref in logsList) {
          if (ref.key != latest.key) {
            bestRef = ref;
            break;
          }
        }
      }
      
      if (bestRef != null) {
        final daysDiff = latest.key.difference(bestRef.key).inDays;
        final linesDiff = latest.value - bestRef.value;
        if (daysDiff > 0 && linesDiff >= 0) {
          final pace = linesDiff / daysDiff;
          return pace >= 0.8 ? pace : overallAvg;
        }
      }
    } catch (e) {
      debugPrint('Error calculating recent pace: $e');
    }
    return overallAvg;
  }

  void _openStudentDetailPage(Map<String, dynamic> studentData) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => StudentDetailPage(
          studentData: studentData,
          branchId: widget.branchId,
          isAdmin: widget.isAdmin,
          username: widget.username,
          role: widget.role,
        ),
      ),
    );
  }

  void _showStudentProgressDialog(BuildContext context, Map<String, dynamic> studentData) {
    final studentId = studentData['id']?.toString() ?? '';
    final branchId = widget.branchId;

    final totalLines = 8640;
    final currentLines = (studentData['currentLines'] as num?)?.toInt() ?? 0;
    final prevLines = int.tryParse(studentData['prevHifzLines']?.toString() ?? '0') ?? 0;
    // joinDate may be stored as Timestamp or ISO string
    final dynamic joinField = studentData['joinDate'];
    Timestamp? joinTimestamp;
    if (joinField is Timestamp) {
      joinTimestamp = joinField;
    } else if (joinField is String) {
      try {
        final parsed = DateTime.parse(joinField);
        joinTimestamp = Timestamp.fromDate(parsed);
      } catch (_) {}
    }
    final joinDate = joinTimestamp?.toDate();
    final daysSinceJoin = (joinDate != null) ? DateTime.now().difference(joinDate).inDays : 0;
    // totalMemorized = lines at this madrassa + prior hifz
    final totalMemorized = currentLines + prevLines;
    // Use totalMemorized for rate so prior hifz is reflected in the student's real pace
    final avgPerDay = daysSinceJoin > 0 ? totalMemorized / daysSinceJoin : 0.0;
    
    // Calculate recent pace (moving average) using the cached logs
    final recentDailyRate = _calculateRecentPace(studentId, branchId, avgPerDay);

    final remainingLines = (totalLines - totalMemorized).clamp(0, totalLines);
    
    // Estimate completion using the recent pace instead of overall average
    final estimatedDays = recentDailyRate > 0.3 ? (remainingLines / recentDailyRate).ceil() : null;
    final pct = ((totalMemorized / totalLines) * 100).clamp(0.0, 100.0).toStringAsFixed(1);

    showDialog(
      context: context,
      builder: (_) => StudentProgressDialog(
        studentName: studentData['name'] ?? 'Student',
        photoUrl: studentData['photoUrl'],
        className: studentData['class']?.toString() ?? 'Hifz',
        rollNumber: studentData['rollNumber']?.toString() ?? '?',
        joinDate: joinDate,
        totalLines: totalLines,
        currentLines: currentLines,
        prevHifzLines: prevLines,
        percentage: pct,
        estimatedDays: estimatedDays,
        recentDailyRate: recentDailyRate,
      ),
    );
  }

  Widget _buildStatusChip(BuildContext context, Map<String, dynamic> d, {bool isDark = false}) {
    final status = d['status'] ?? 'active';
    String statusLabel;
    Color color;

    switch (status) {
      case 'active':
        statusLabel = context.l.statusActive;
        color = const Color(0xFF008080); // Teal
        break;
      case 'archived':
        statusLabel = context.l.statusArchived;
        color = const Color(0xFFF59E0B); // Amber
        break;
      case 'hifz_completed':
        statusLabel = context.l.statusHifzCompleted;
        color = const Color(0xFF4C4DDC); // Purple
        break;
      case 'left':
        statusLabel = context.l.statusLeft;
        color = const Color(0xFFEF4444); // Red/Rose
        break;
      case 'dropped':
      case 'dropped_out':
        statusLabel = context.isUrdu ? 'خارج' : 'Dropped Out';
        color = const Color(0xFFDC2626); // Dark Red
        break;
      case 'inactive':
        statusLabel = context.isUrdu ? 'غیر فعال' : 'Inactive';
        color = const Color(0xFF6B7280); // Slate Gray
        break;
      default:
        statusLabel = status.toString().toUpperCase();
        color = const Color(0xFF6B7280);
    }

    // Extract the latest reason for this status from auditLog
    String reason = '';
    final rawAuditLog = d['auditLog'];
    final auditListRaw = rawAuditLog is List ? rawAuditLog : [];
    if (auditListRaw.isNotEmpty) {
      final auditList = List<Map<String, dynamic>>.from(
        auditListRaw.whereType<Map>().map((e) => Map<String, dynamic>.from(e)),
      );
      // Sort in descending order to get the latest first
      auditList.sort((a, b) {
        final dynamic aRaw = a['date'];
        final dynamic bRaw = b['date'];
        
        DateTime aDate;
        if (aRaw is Timestamp) {
          aDate = aRaw.toDate();
        } else if (aRaw is String) {
          aDate = DateTime.tryParse(aRaw) ?? DateTime.fromMillisecondsSinceEpoch(0);
        } else {
          aDate = DateTime.fromMillisecondsSinceEpoch(0);
        }

        DateTime bDate;
        if (bRaw is Timestamp) {
          bDate = bRaw.toDate();
        } else if (bRaw is String) {
          bDate = DateTime.tryParse(bRaw) ?? DateTime.fromMillisecondsSinceEpoch(0);
        } else {
          bDate = DateTime.fromMillisecondsSinceEpoch(0);
        }

        return bDate.compareTo(aDate);
      });
      final matchingEntry = auditList.firstWhere(
        (entry) => entry['status'] == status,
        orElse: () => <String, dynamic>{},
      );
      if (matchingEntry.isNotEmpty) {
        reason = matchingEntry['reason'] ?? '';
      }
    }

    final chip = Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: isDark ? 0.22 : 0.10),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color.withValues(alpha: isDark ? 0.45 : 0.30), width: 1),
      ),
      child: Text(
        statusLabel,
        style: context.urduStyle(
          style: TextStyle(
            color: color,
            fontSize: 11,
            fontWeight: FontWeight.bold,
          ),
        ),
      ),
    );

    if (reason.isNotEmpty && reason != statusLabel && reason != '$statusLabel:') {
      return Tooltip(
        message: reason,
        child: chip,
      );
    }
    return chip;
  }

  Widget _buildMobileStudentCard(dynamic s, Map<String, dynamic> d, bool isDark) {
    final studentId = s is DocumentSnapshot ? s.id : s['id'].toString();
    final isExpanded = _expandedStudentIds.contains(studentId);
    final cardBg = isDark ? const Color(0xFF1E293B) : Colors.white;
    final borderColor = isDark ? const Color(0xFF334155) : const Color(0xFFE0E2E7);
    final textPrimary = isDark ? Colors.white : const Color(0xFF1A1C1E);
    final textMuted = isDark ? const Color(0xFF94A3B8) : Colors.grey[600]!;

    final rollVal = (d['rollNumber'] ?? d['rollNo'] ?? '?').toString();
    final classValRaw = (d['class'] ?? 'Hifz').toString();
    final classDisplay = context.isUrdu && (classValRaw.toLowerCase() == 'hifz' || classValRaw.isEmpty)
        ? 'حفظ'
        : classValRaw;

    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: cardBg,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: borderColor),
      ),
      child: Theme(
        data: Theme.of(context).copyWith(
          dividerColor: Colors.transparent,
          colorScheme: Theme.of(context).colorScheme.copyWith(
            surface: cardBg,
          ),
        ),
        child: ExpansionTile(
          key: PageStorageKey<String>('std_tile_$studentId'),
          initiallyExpanded: isExpanded,
          onExpansionChanged: (expanded) {
            setState(() {
              if (expanded) {
                _expandedStudentIds.add(studentId);
              } else {
                _expandedStudentIds.remove(studentId);
              }
            });
          },
          tilePadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
          leading: GestureDetector(
            onTap: () => _pickAndUploadPhoto(studentId),
            child: Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                border: Border.all(
                  color: isDark ? const Color(0xFF475569) : const Color(0xFFCBD5E1),
                  width: 1.2,
                ),
              ),
              child: ClipOval(
                child: _uploadStates[studentId] == PhotoUploadStatus.uploading
                    ? const Padding(
                        padding: EdgeInsets.all(6.0),
                        child: CircularProgressIndicator(strokeWidth: 2, color: Color(0xFF008080)),
                      )
                    : _buildStudentAvatar(d['photoUrl']?.toString(), d['name']?.toString(), size: 40),
              ),
            ),
          ),
          title: Text(
            (d['name'] ?? '').toString().trim(),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontWeight: FontWeight.bold,
              fontSize: 15.5,
              color: textPrimary,
              fontFamily: context.isUrdu ? 'Noori' : null,
            ),
          ),
          subtitle: Padding(
            padding: const EdgeInsets.only(top: 3.0),
            child: Text(
              '${context.isUrdu ? 'رول نمبر' : 'Roll'}: $rollVal  •  ${context.isUrdu ? 'کلاس' : 'Class'}: $classDisplay',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: context.urduStyle(
                style: TextStyle(
                  color: textMuted,
                  fontSize: 11.5,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
          ),
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              _buildStatusChip(context, d, isDark: isDark),
              const SizedBox(width: 4),
              Container(
                width: 26,
                height: 26,
                decoration: BoxDecoration(
                  color: isDark ? const Color(0xFF334155).withValues(alpha: 0.5) : const Color(0xFFF1F5F9),
                  shape: BoxShape.circle,
                ),
                child: Icon(
                  isExpanded ? Icons.keyboard_arrow_up_rounded : Icons.keyboard_arrow_down_rounded,
                  color: textMuted,
                  size: 18,
                ),
              ),
            ],
          ),
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Divider(height: 1, color: borderColor),
                  const SizedBox(height: 12),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(context.l.guardianFullName, style: context.urduStyle(style: TextStyle(fontSize: 10, color: textMuted))),
                          const SizedBox(height: 2),
                          Text(d['guardianName'] ?? '—', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13, color: textPrimary)),
                        ],
                      ),
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.end,
                        children: [
                          Text(context.l.contactPhone, style: context.urduStyle(style: TextStyle(fontSize: 10, color: textMuted))),
                          const SizedBox(height: 2),
                          Text(d['contactPhone'] ?? d['phone'] ?? '—', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13, color: textPrimary)),
                        ],
                      ),
                    ],
                  ),
                  () {
                    final rawAudit = d['auditLog'];
                    if (rawAudit is List && rawAudit.isNotEmpty) {
                      final latest = rawAudit.last;
                      if (latest is Map && latest['reason'] != null && latest['reason'].toString().trim().isNotEmpty) {
                        final reasonStr = latest['reason'].toString().trim();
                        final isStatusMatch = latest['status'] == d['status'];
                        if (isStatusMatch && reasonStr != d['status'] && reasonStr != '${d['status']}:') {
                          return Container(
                            margin: const EdgeInsets.only(top: 10),
                            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                            decoration: BoxDecoration(
                              color: isDark ? const Color(0xFF334155).withValues(alpha: 0.35) : const Color(0xFFF1F5F9),
                              borderRadius: BorderRadius.circular(8),
                              border: Border.all(color: borderColor.withValues(alpha: 0.6)),
                            ),
                            child: Row(
                              children: [
                                Icon(Icons.info_outline_rounded, size: 14, color: textMuted),
                                const SizedBox(width: 6),
                                Expanded(
                                  child: Text(
                                    reasonStr,
                                    style: TextStyle(fontSize: 11, color: textMuted),
                                  ),
                                ),
                              ],
                            ),
                          );
                        }
                      }
                    }
                    return const SizedBox.shrink();
                  }(),
                  const SizedBox(height: 12),
                  _buildProgressBar(context, d['currentLines'] ?? 0, isDark),
                  const SizedBox(height: 12),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      StatusActionMenu(
                        student: s,
                        branchId: widget.branchId,
                        isAdmin: widget.isAdmin,
                        t: RoleThemeScope.dataOf(context),
                        username: widget.username,
                        role: widget.role,
                      ),
                      Row(
                        children: [
                          IconButton(
                            icon: const Icon(Icons.badge_outlined, color: Color(0xFF008080)),
                            tooltip: 'View Student Profile',
                            onPressed: () => _openStudentDetailPage(d),
                          ),
                          IconButton(
                            icon: const Icon(Icons.info_outline, color: Color(0xFF008080)),
                            tooltip: context.l.moreInfo,
                            onPressed: () => _showStudentProgressDialog(context, d),
                          ),
                        ],
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildProgressBar(BuildContext context, int currentLines, bool isDark) {
    const int totalLines = 8640;
    final double pct = (currentLines / totalLines).clamp(0.0, 1.0);
    final pctText = (pct * 100).toStringAsFixed(1);
    final textMuted = isDark ? const Color(0xFF94A3B8) : Colors.grey[600]!;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(
              '${context.l.memorizationProgress} ($currentLines ${context.l.lines})',
              style: context.urduStyle(style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: textMuted)),
            ),
            Text('$pctText%', style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: isDark ? const Color(0xFF2DD4BF) : const Color(0xFF008080))),
          ],
        ),
        const SizedBox(height: 6),
        ClipRRect(
          borderRadius: BorderRadius.circular(4),
          child: LinearProgressIndicator(
            value: pct,
            backgroundColor: isDark ? const Color(0xFF334155) : const Color(0xFFF0F2F5),
            valueColor: AlwaysStoppedAnimation<Color>(isDark ? const Color(0xFF2DD4BF) : const Color(0xFF008080)),
            minHeight: 8,
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final isMobile = MediaQuery.of(context).size.width < 600;

    return ValueListenableBuilder(
      valueListenable: UserThemeService.listenable(widget.username),
      builder: (context, _, __) {
        final isDark = Theme.of(context).brightness == Brightness.dark || UserThemeService.isDarkMode(widget.username);
        final scaffoldBg = isDark ? const Color(0xFF0F172A) : const Color(0xFFF8F9FD);
        final cardBg = isDark ? const Color(0xFF1E293B) : Colors.white;
        final textPrimary = isDark ? Colors.white : const Color(0xFF1A1C1E);
        final textMuted = isDark ? const Color(0xFF94A3B8) : Colors.grey[600]!;
        final borderColor = isDark ? const Color(0xFF334155) : const Color(0xFFE0E2E7);

        final studentsAsync = ref.watch(madrassaStudentsProvider(widget.branchId));

        return Scaffold(
          backgroundColor: scaffoldBg,
          floatingActionButton: null,
          body: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _buildHeader(context, isDark),
              _buildPendingRejoinRequests(studentsAsync.valueOrNull ?? []),
              Expanded(
                child: studentsAsync.when(
                  loading: () => const Center(child: CircularProgressIndicator()),
                  error: (e, st) => Center(child: Text('Error loading students: $e')),
                  data: (studentsList) {
                    final filteredStudents = studentsList.where((d) {
                  final name = (d['name'] ?? '').toString().toLowerCase();
                  final roll = (d['rollNumber'] ?? '').toString().toLowerCase();
                  final query = _searchQuery.toLowerCase();
                  
                  final matchesSearch = name.contains(query) || roll.contains(query);
                  if (!matchesSearch) return false;

                  if (_statusFilter != 'all') {
                    final status = d['status'] ?? 'active';
                    return status == _statusFilter;
                  }
                  return true;
                }).toList()..sort((a, b) {
                  if (_sortBy == 'rollNumber') {
                    final aVal = int.tryParse(a['rollNumber']?.toString() ?? '') ?? 999999;
                    final bVal = int.tryParse(b['rollNumber']?.toString() ?? '') ?? 999999;
                    return aVal.compareTo(bVal);
                  } else if (_sortBy == 'progress') {
                    final aLines = (a['currentLines'] as num?)?.toInt() ?? 0;
                    final aPrev = int.tryParse(a['prevHifzLines']?.toString() ?? '0') ?? 0;
                    final aTotal = aLines + aPrev;

                    final bLines = (b['currentLines'] as num?)?.toInt() ?? 0;
                    final bPrev = int.tryParse(b['prevHifzLines']?.toString() ?? '0') ?? 0;
                    final bTotal = bLines + bPrev;

                    return bTotal.compareTo(aTotal);
                  } else if (_sortBy == 'joinDate') {
                    final dynamic aJoinRaw = a['joinDate'];
                    final dynamic bJoinRaw = b['joinDate'];
                    
                    DateTime aJoin;
                    if (aJoinRaw is Timestamp) {
                      aJoin = aJoinRaw.toDate();
                    } else if (aJoinRaw is String) {
                      aJoin = DateTime.tryParse(aJoinRaw) ?? DateTime.fromMillisecondsSinceEpoch(0);
                    } else {
                      aJoin = DateTime.fromMillisecondsSinceEpoch(0);
                    }

                    DateTime bJoin;
                    if (bJoinRaw is Timestamp) {
                      bJoin = bJoinRaw.toDate();
                    } else if (bJoinRaw is String) {
                      bJoin = DateTime.tryParse(bJoinRaw) ?? DateTime.fromMillisecondsSinceEpoch(0);
                    } else {
                      bJoin = DateTime.fromMillisecondsSinceEpoch(0);
                    }

                    return bJoin.compareTo(aJoin);
                  }
                  return 0;
                });

                if (filteredStudents.isEmpty) {
                  return Center(
                    child: Text(
                      context.l.noData,
                      style: context.urduStyle(style: const TextStyle(color: Colors.grey)),
                    ),
                  );
                }

                // Group students by batch
                final Map<String, List<Map<String, dynamic>>> studentsByBatch = {};
                for (final student in filteredStudents) {
                  final batch = student['batch'] ?? student['status'] ?? 'active';
                  studentsByBatch.putIfAbsent(batch, () => []).add(student);
                }

                // Define batch order
                const batchOrder = ['active', 'left', 'dropped', 'dropped_out', 'hifz_completed', 'hifz_complete', 'archived', 'inactive'];

                if (isMobile) {
                  return RefreshIndicator(
                    onRefresh: () async {
                      await MadrassaLocalStorage.downloadStudents(widget.branchId, force: true);
                      if (mounted) setState(() {});
                    },
                    child: ListView(
                      physics: const AlwaysScrollableScrollPhysics(),
                      padding: const EdgeInsets.only(bottom: 24),
                      children: [
                        for (final batch in batchOrder)
                          if (studentsByBatch.containsKey(batch))
                            ...[
                              _buildBatchHeader(context, batch),
                              ...studentsByBatch[batch]!.map((s) => _buildMobileStudentCard(s, s, isDark)),
                            ]
                      ],
                    ),
                  );
                }

                return RefreshIndicator(
                  onRefresh: () async {
                    await MadrassaLocalStorage.downloadStudents(widget.branchId, force: true);
                    if (mounted) setState(() {});
                  },
                  child: SingleChildScrollView(
                    physics: const AlwaysScrollableScrollPhysics(),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 24),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        for (final batch in batchOrder)
                          if (studentsByBatch.containsKey(batch))
                            ...[
                              _buildBatchHeader(context, batch),
                              const SizedBox(height: 12),
                              Container(
                                width: double.infinity,
                                decoration: BoxDecoration(
                                  color: cardBg,
                                  borderRadius: BorderRadius.circular(16),
                                  border: Border.all(color: borderColor),
                                ),
                                child: SingleChildScrollView(
                                  scrollDirection: Axis.horizontal,
                                  child: DataTable(
                                  columnSpacing: 12,
                                  horizontalMargin: 12,
                                  headingRowColor: WidgetStateProperty.all(isDark ? const Color(0xFF0F172A) : const Color(0xFFF1F4F9)),
                                  dataRowMinHeight: 60,
                                  dataRowMaxHeight: 60,
                                  columns: [
                                    DataColumn(label: Text('#', style: TextStyle(fontWeight: FontWeight.bold, color: textPrimary))),
                                    DataColumn(label: Text(context.l.students, style: context.urduStyle(style: TextStyle(fontWeight: FontWeight.bold, color: textPrimary)))),
                                    DataColumn(label: Text(context.l.rollNumber, style: context.urduStyle(style: TextStyle(fontWeight: FontWeight.bold, color: textPrimary)))),
                                    DataColumn(label: Text('Class', style: TextStyle(fontWeight: FontWeight.bold, color: textPrimary))),
                                    DataColumn(label: Text(context.l.guardianFullName, style: context.urduStyle(style: TextStyle(fontWeight: FontWeight.bold, color: textPrimary)))),
                                    DataColumn(label: Text(context.l.contactPhone, style: context.urduStyle(style: TextStyle(fontWeight: FontWeight.bold, color: textPrimary)))),
                                    DataColumn(label: Text(context.l.overallProgress, style: context.urduStyle(style: TextStyle(fontWeight: FontWeight.bold, color: textPrimary)))),
                                    DataColumn(label: Text('Status', style: TextStyle(fontWeight: FontWeight.bold, color: textPrimary))),
                                    DataColumn(label: Text(context.l.todayActions, style: context.urduStyle(style: TextStyle(fontWeight: FontWeight.bold, color: textPrimary)))),
                                  ],
                                  rows: List.generate(studentsByBatch[batch]!.length, (i) {
                                    final s = studentsByBatch[batch]![i];
                                    final d = s;
                                    final studentId = s['id'].toString();
                                    final lines = d['currentLines'] ?? 0;
                                    final prevL = int.tryParse(d['prevHifzLines']?.toString() ?? '0') ?? 0;
                                    final totalL = lines + prevL;
                                    final pct = (totalL / 8640 * 100).clamp(0.0, 100.0).toStringAsFixed(1);

                                    return DataRow(cells: [
                                      DataCell(Text('${i + 1}', style: TextStyle(color: textPrimary))),
                                      DataCell(Row(
                                        children: [
                                          GestureDetector(
                                            onTap: () => _pickAndUploadPhoto(studentId),
                                            child: SizedBox(
                                              width: 28,
                                              height: 28,
                                              child: _uploadStates[studentId] == PhotoUploadStatus.uploading
                                                  ? const Padding(
                                                      padding: EdgeInsets.all(4.0),
                                                      child: CircularProgressIndicator(strokeWidth: 1.5, color: Color(0xFF008080)),
                                                    )
                                                  : _buildStudentAvatar(d['photoUrl']?.toString(), d['name']?.toString(), size: 28),
                                            ),
                                          ),
                                          const SizedBox(width: 8),
                                          InkWell(
                                            onTap: () => _openStudentDetailPage(d),
                                            child: Text(
                                              d['name'] ?? '',
                                              style: TextStyle(
                                                fontWeight: FontWeight.bold,
                                                color: isDark ? const Color(0xFF2DD4BF) : const Color(0xFF008080),
                                              ),
                                            ),
                                          ),
                                        ],
                                      )),
                                      DataCell(Text(d['rollNumber']?.toString() ?? '?', style: TextStyle(color: textPrimary))),
                                      DataCell(Text(d['class']?.toString() ?? 'Hifz', style: TextStyle(color: textPrimary))),
                                      DataCell(Text(d['guardianName']?.toString() ?? '—', style: TextStyle(color: textPrimary))),
                                      DataCell(Text(d['contactPhone']?.toString() ?? d['phone']?.toString() ?? '—', style: TextStyle(color: textPrimary))),
                                      DataCell(Row(
                                        children: [
                                          Text('$totalL lines ($pct%)', style: TextStyle(fontWeight: FontWeight.bold, color: isDark ? const Color(0xFF2DD4BF) : const Color(0xFF008080))),
                                          IconButton(
                                            icon: Icon(Icons.info_outline, size: 14, color: isDark ? const Color(0xFF2DD4BF) : const Color(0xFF008080)),
                                            tooltip: context.l.moreInfo,
                                            onPressed: () => _showStudentProgressDialog(context, d),
                                          ),
                                        ],
                                      )),
                                      DataCell(_buildStatusChip(context, d, isDark: isDark)),
                                      DataCell(StatusActionMenu(
                                        student: s,
                                        branchId: widget.branchId,
                                        isAdmin: widget.isAdmin,
                                        t: RoleThemeScope.dataOf(context),
                                        username: widget.username,
                                        role: widget.role,
                                      )),
                                    ]);
                                  }),
                                ),
                              ),
                              ),
                                const SizedBox(height: 24),
                              ],
                        ],
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  },
);
  }

  Widget _buildBatchHeader(BuildContext context, String batch) {
    String displayName;
    Color batchColor;
    IconData batchIcon;
    
    switch (batch) {
      case 'active':
        displayName = 'Active Students';
        batchColor = Colors.green;
        batchIcon = Icons.check_circle;
        break;
      case 'left':
        displayName = 'Students Left';
        batchColor = Colors.orange;
        batchIcon = Icons.exit_to_app;
        break;
      case 'dropped':
        displayName = 'Dropped Students';
        batchColor = Colors.red;
        batchIcon = Icons.cancel;
        break;
      case 'hifz_complete':
        displayName = 'Hifz Complete';
        batchColor = Colors.blue;
        batchIcon = Icons.auto_stories;
        break;
      default:
        displayName = batch;
        batchColor = Colors.grey;
        batchIcon = Icons.people;
    }

    return Padding(
      padding: const EdgeInsets.only(top: 20, bottom: 12),
      child: Row(
        children: [
          Icon(batchIcon, color: batchColor, size: 24),
          const SizedBox(width: 12),
          Text(
            displayName,
            style: context.urduStyle(
              style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.bold,
                color: batchColor,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildHeader(BuildContext context, bool isDark) {
    final cardBg = isDark ? const Color(0xFF1E293B) : Colors.white;
    final borderColor = isDark ? const Color(0xFF334155) : const Color(0xFFE0E2E7);
    final textPrimary = isDark ? Colors.white : const Color(0xFF1A1C1E);
    final textMuted = isDark ? const Color(0xFF94A3B8) : const Color(0xFF64748B);

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            spacing: 12,
            runSpacing: 12,
            alignment: WrapAlignment.spaceBetween,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Text(
                context.l.studentRoster,
                style: context.urduStyle(
                  style: TextStyle(
                    fontSize: 22,
                    fontWeight: FontWeight.bold,
                    color: textPrimary,
                  ),
                ),
              ),
              if (_canAddStudent)
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    if (widget.isAdmin)
                      ElevatedButton.icon(
                        style: ElevatedButton.styleFrom(
                          backgroundColor: const Color(0xFF008080),
                          foregroundColor: Colors.white,
                        ),
                        onPressed: _importStudentsFile,
                        icon: const Icon(Icons.upload_file),
                        label: Text(
                          context.isUrdu ? 'درآمد کریں' : 'Import File',
                          style: context.urduStyle(style: const TextStyle(color: Colors.white)),
                        ),
                      ),
                    ElevatedButton.icon(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFF008080),
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                      ),
                      onPressed: () => showAddStudentDialog(
                        context,
                        widget.branchId,
                        username: widget.username,
                        role: widget.role,
                      ),
                      icon: const Icon(Icons.person_add_rounded, color: Colors.white),
                      label: Text(
                        context.isUrdu ? 'نیا طالب علم داخل کریں / Add Student' : '+ Add Student',
                        style: context.urduStyle(style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
                      ),
                    ),
                  ],
                ),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: TextField(
                  style: TextStyle(color: textPrimary),
                  decoration: InputDecoration(
                    hintText: '${context.l.search}...',
                    hintStyle: TextStyle(color: textMuted),
                    prefixIcon: Icon(Icons.search, color: textMuted),
                    filled: true,
                    fillColor: cardBg,
                    contentPadding: const EdgeInsets.symmetric(vertical: 0, horizontal: 16),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: BorderSide(color: borderColor),
                    ),
                    enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: BorderSide(color: borderColor),
                    ),
                    focusedBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: const BorderSide(color: Color(0xFF008080), width: 2),
                    ),
                  ),
                  onChanged: (val) {
                    setState(() {
                      _searchQuery = val;
                    });
                  },
                ),
              ),
              const SizedBox(width: 8),
              Container(
                decoration: BoxDecoration(
                  color: cardBg,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: borderColor),
                ),
                child: IconButton(
                  icon: Icon(
                    Icons.tune,
                    color: _showFilters ? const Color(0xFF008080) : textMuted,
                  ),
                  onPressed: () {
                    setState(() {
                      _showFilters = !_showFilters;
                    });
                  },
                ),
              ),
            ],
          ),
          if (_showFilters) ...[
            const SizedBox(height: 12),
            Builder(
              builder: (context) {
                final isSmallScreen = MediaQuery.of(context).size.width < 600;

                final statusFilterDropdown = DropdownButtonFormField<String>(
                  value: _statusFilter,
                  decoration: InputDecoration(
                    labelText: context.isUrdu ? 'حیثیت کے لحاظ سے فلٹر کریں' : 'Filter by Status',
                    labelStyle: context.urduStyle(style: TextStyle(fontSize: 12, color: isDark ? const Color(0xFF2DD4BF) : const Color(0xFF008080))),
                    filled: true,
                    fillColor: cardBg,
                    contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: BorderSide(color: borderColor),
                    ),
                    enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: BorderSide(color: borderColor),
                    ),
                  ),
                  dropdownColor: cardBg,
                  style: context.urduStyle(style: TextStyle(color: textPrimary, fontSize: 13)),
                  items: [
                    DropdownMenuItem(value: 'all', child: Text(context.isUrdu ? 'تمام' : 'All Statuses')),
                    DropdownMenuItem(value: 'active', child: Text(context.l.statusActive)),
                    DropdownMenuItem(value: 'inactive', child: Text(context.isUrdu ? 'غیر فعال' : 'Inactive')),
                    DropdownMenuItem(value: 'archived', child: Text(context.l.statusArchived)),
                    DropdownMenuItem(value: 'hifz_completed', child: Text(context.l.statusHifzCompleted)),
                    DropdownMenuItem(value: 'left', child: Text(context.l.statusLeft)),
                  ],
                  onChanged: (val) {
                    if (val != null) {
                      setState(() {
                        _statusFilter = val;
                      });
                    }
                  },
                );

                final sortByDropdown = DropdownButtonFormField<String>(
                  value: _sortBy,
                  decoration: InputDecoration(
                    labelText: context.isUrdu ? 'ترتیب دیں' : 'Sort By',
                    labelStyle: context.urduStyle(style: TextStyle(fontSize: 12, color: isDark ? const Color(0xFF2DD4BF) : const Color(0xFF008080))),
                    filled: true,
                    fillColor: cardBg,
                    contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: BorderSide(color: borderColor),
                    ),
                    enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: BorderSide(color: borderColor),
                    ),
                  ),
                  dropdownColor: cardBg,
                  style: context.urduStyle(style: TextStyle(color: textPrimary, fontSize: 13)),
                  items: [
                    DropdownMenuItem(value: 'rollNumber', child: Text(context.isUrdu ? 'رول نمبر' : 'Roll Number')),
                    DropdownMenuItem(value: 'progress', child: Text(context.isUrdu ? 'پیش رفت' : 'Progress')),
                    DropdownMenuItem(value: 'joinDate', child: Text(context.isUrdu ? 'شمولیت کی تاریخ' : 'Join Date')),
                  ],
                  onChanged: (val) {
                    if (val != null) {
                      setState(() {
                        _sortBy = val;
                      });
                    }
                  },
                );

                return isSmallScreen
                    ? Column(
                        children: [
                          statusFilterDropdown,
                          const SizedBox(height: 12),
                          sortByDropdown,
                        ],
                      )
                    : Row(
                        children: [
                          Expanded(child: statusFilterDropdown),
                          const SizedBox(width: 12),
                          Expanded(child: sortByDropdown),
                        ],
                      );
              },
            ),
          ],
        ],
      ),
    );
  }

  Future<void> _pickAndUploadPhoto(String studentId) async {
    final ImageSource? source = await showModalBottomSheet<ImageSource>(
      context: context,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.all(16.0),
              child: Text(
                context.isUrdu ? 'طالب علم کی تصویر منتخب کریں' : 'Update Student Photo',
                style: context.urduStyle(style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
              ),
            ),
            ListTile(
              leading: const Icon(Icons.camera_alt_outlined, color: Color(0xFF008080)),
              title: Text(
                context.isUrdu ? 'کیمرہ سے تصویر لیں' : 'Take Photo with Camera',
                style: context.urduStyle(),
              ),
              onTap: () => Navigator.pop(ctx, ImageSource.camera),
            ),
            ListTile(
              leading: const Icon(Icons.photo_library_outlined, color: Color(0xFF008080)),
              title: Text(
                context.isUrdu ? 'گیلری سے منتخب کریں' : 'Choose from Gallery',
                style: context.urduStyle(),
              ),
              onTap: () => Navigator.pop(ctx, ImageSource.gallery),
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );

    if (source == null) return;

    try {
      if (!mounted) return;
      setState(() => _uploadStates[studentId] = PhotoUploadStatus.uploading);

      final b64 = await ImageUploadService.pickAndProcessImage(source: source);
      if (b64 == null || b64.isEmpty) {
        if (mounted) setState(() => _uploadStates[studentId] = PhotoUploadStatus.idle);
        return;
      }

      final studentCache = MadrassaLocalStorage.getStudentCached(widget.branchId, studentId) ?? {'id': studentId, 'branchId': widget.branchId};
      studentCache['photoUrl'] = b64;
      studentCache['photoBase64'] = b64;
      studentCache['studentPhotoBase64'] = b64;
      studentCache['lastUpdatedAt'] = DateTime.now().toIso8601String();
      await MadrassaLocalStorage.cacheStudent(widget.branchId, studentId, studentCache);

      // Broadcast to LAN WebSocket
      try {
        final payload = RealtimeEvents.payload(
          type: RealtimeEvents.saveMadrassaStudent,
          data: {
            ...studentCache,
            'studentId': studentId,
          },
          branchId: widget.branchId,
        );
        RealtimeManager().sendMessage(payload);
      } catch (e) {
        debugPrint('[StudentManagementView] LAN broadcast error: $e');
      }

      // Always enqueue sync
      await LocalStorageService.enqueueSync({
        'type': 'save_madrassa_student',
        'branchId': widget.branchId,
        'studentId': studentId,
        'data': studentCache,
      });
      unawaited(SyncService().triggerUpload());

      if (mounted) {
        setState(() {
          _uploadStates[studentId] = PhotoUploadStatus.success;
        });
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              context.isUrdu ? 'تصویر کامیابی کے ساتھ اپ ڈیٹ ہو گئی' : 'Student photo updated successfully!',
              style: context.urduStyle(),
            ),
            backgroundColor: const Color(0xFF008080),
          ),
        );
      }
    } catch (e) {
      if (!mounted) return;
      setState(() => _uploadStates[studentId] = PhotoUploadStatus.error);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Failed to update photo: $e'), backgroundColor: Colors.red),
      );
    }
  }

  Widget _buildStudentAvatar(String? photoUrl, String? name, {double size = 36}) {
    if (photoUrl != null && photoUrl.trim().isNotEmpty) {
      final str = photoUrl.trim();
      if (str.startsWith('http://') || str.startsWith('https://')) {
        return ClipOval(
          child: Image.network(
            str,
            width: size,
            height: size,
            fit: BoxFit.cover,
            errorBuilder: (_, __, ___) => _buildAvatarFallback(name, fontSize: size * 0.4),
          ),
        );
      }
      final bytes = ImageUploadService.decodeBase64ToBytes(str);
      if (bytes != null) {
        return ClipOval(
          child: Image.memory(
            bytes,
            width: size,
            height: size,
            fit: BoxFit.cover,
            errorBuilder: (_, __, ___) => _buildAvatarFallback(name, fontSize: size * 0.4),
          ),
        );
      }
    }
    return _buildAvatarFallback(name, fontSize: size * 0.4);
  }

  Widget _buildAvatarFallback(String? name, {double? fontSize}) {
    final firstLetter = name != null && name.isNotEmpty ? name[0].toUpperCase() : '?';
    return Container(
      decoration: const BoxDecoration(
        color: Color(0xFFE0F2F1),
        shape: BoxShape.circle,
      ),
      alignment: Alignment.center,
      child: Text(
        firstLetter,
        style: TextStyle(
          color: const Color(0xFF008080),
          fontWeight: FontWeight.bold,
          fontSize: fontSize,
        ),
      ),
    );
  }

  Widget _buildPendingRejoinRequests(List<Map<String, dynamic>> allStudents) {
    final docs = allStudents.where((d) => d['rejoinRequestStatus'] == 'pending').toList();
    if (docs.isEmpty) return const SizedBox.shrink();

    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: const Color(0xFFFEF3C7), // Light amber
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0xFFFDE68A)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.hail_rounded, color: Color(0xFFD97706), size: 24),
              const SizedBox(width: 12),
              Text(
                'Pending Rejoining Requests (${docs.length})',
                style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16, color: Color(0xFF92400E)),
              ),
            ],
          ),
          const SizedBox(height: 12),
          ListView.separated(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            itemCount: docs.length,
            separatorBuilder: (_, _) => const Divider(color: Color(0xFFFDE68A)),
            itemBuilder: (context, i) {
              final d = docs[i];
              final dynamic dateRaw = d['rejoinRequestDate'];
              DateTime? date;
              if (dateRaw is Timestamp) {
                date = dateRaw.toDate();
              } else if (dateRaw is String) {
                date = DateTime.tryParse(dateRaw);
              }
              final dateStr = date != null ? DateFormat('yyyy-MM-dd HH:mm').format(date) : '';

              return Padding(
                padding: const EdgeInsets.symmetric(vertical: 8.0),
                child: Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            '${d['name'] ?? ''} (Roll: ${d['rollNumber'] ?? '?'})',
                            style: const TextStyle(fontWeight: FontWeight.bold, color: Color(0xFF78350F)),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            'Reason: "${d['rejoinRequestReason'] ?? 'No reason specified'}"',
                            style: const TextStyle(fontSize: 12, color: Color(0xFF92400E)),
                          ),
                          if (dateStr.isNotEmpty) ...[
                            const SizedBox(height: 2),
                            Text(
                              'Requested on: $dateStr',
                              style: const TextStyle(fontSize: 10, color: Color(0xFFB45309)),
                            ),
                          ],
                        ],
                      ),
                    ),
                    ElevatedButton.icon(
                      onPressed: () => _approveRejoin(d),
                      icon: const Icon(Icons.check, size: 14),
                      label: const Text('Approve', style: TextStyle(fontSize: 11)),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.green,
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                        minimumSize: Size.zero,
                      ),
                    ),
                    const SizedBox(width: 8),
                    TextButton.icon(
                      onPressed: () => _rejectRejoin(d),
                      icon: const Icon(Icons.close, size: 14, color: Colors.red),
                      label: const Text('Reject', style: TextStyle(fontSize: 11, color: Colors.red)),
                      style: TextButton.styleFrom(
                        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                        minimumSize: Size.zero,
                      ),
                    ),
                  ],
                ),
              );
            },
          ),
        ],
      ),
    );
  }

  Future<void> _approveRejoin(Map<String, dynamic> sData) async {
    final now = DateTime.now();
    final studentId = sData['id']?.toString() ?? '';
    if (studentId.isEmpty) return;

    final auditReason = 'Rejoin request approved. Notes: ${sData['rejoinRequestReason'] ?? ''}';
    final studentCache = MadrassaLocalStorage.getStudentCached(widget.branchId, studentId) ?? Map<String, dynamic>.from(sData);
    studentCache['status'] = 'active';
    studentCache['batch'] = 'active';
    studentCache['rejoinRequestStatus'] = null;
    studentCache['rejoinRequestReason'] = null;
    studentCache['rejoinRequestDate'] = null;
    studentCache['lastUpdatedAt'] = now.toIso8601String();

    final auditList = List<Map<String, dynamic>>.from(
      (studentCache['auditLog'] as List? ?? []).whereType<Map>().map((e) => Map<String, dynamic>.from(e)),
    );
    auditList.add({
      'status': 'active',
      'type': 'rejoin_approval',
      'date': now.toIso8601String(),
      'reason': auditReason,
    });
    studentCache['auditLog'] = auditList;

    await MadrassaLocalStorage.cacheStudent(widget.branchId, studentId, studentCache);

    // Broadcast LAN
    try {
      final payload = RealtimeEvents.payload(
        type: RealtimeEvents.saveMadrassaStudent,
        data: {
          ...studentCache,
          'studentId': studentId,
        },
        branchId: widget.branchId,
      );
      RealtimeManager().sendMessage(payload);
    } catch (e) {
      debugPrint('[StudentManagementView] LAN broadcast error: $e');
    }

    // Always enqueue sync
    await LocalStorageService.enqueueSync({
      'type': 'save_madrassa_student',
      'branchId': widget.branchId,
      'studentId': studentId,
      'data': studentCache,
    });
    unawaited(SyncService().triggerUpload());

    // Central Audit Log in background
    unawaited(MadrassaAuditService.logAction(
      branchId: widget.branchId,
      editor: widget.username,
      role: widget.role,
      type: 'status_change',
      message: 'Approved rejoining request for student ${sData['name'] ?? ''} (Roll: ${sData['rollNumber'] ?? ''})',
      studentId: studentId,
      studentName: sData['name'],
    ));

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Rejoin approved for ${sData['name'] ?? ''}')),
      );
    }
  }

  Future<void> _rejectRejoin(Map<String, dynamic> sData) async {
    final reasonCtrl = TextEditingController();
    String? reasonError;

    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (context, setDs) {
          return AlertDialog(
            title: const Text('Reject Rejoin Request', style: TextStyle(fontWeight: FontWeight.bold)),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Are you sure you want to reject the rejoin request for ${sData['name'] ?? ''}?'),
                const SizedBox(height: 16),
                RichText(
                  text: const TextSpan(
                    children: [
                      TextSpan(
                        text: 'Rejection Reason',
                        style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: Color(0xFF1E293B)),
                      ),
                      TextSpan(
                        text: ' *',
                        style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: Color(0xFFD32F2F)),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 6),
                TextField(
                  controller: reasonCtrl,
                  decoration: InputDecoration(
                    hintText: 'e.g. Class capacity reached.',
                    errorText: reasonError,
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                    enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: BorderSide(color: reasonError != null ? const Color(0xFFD32F2F) : const Color(0xFFD0D3D9)),
                    ),
                    focusedBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: const BorderSide(color: Colors.red, width: 2),
                    ),
                  ),
                  onChanged: (v) {
                    if (reasonError != null) setDs(() => reasonError = null);
                  },
                ),
              ],
            ),
            actions: [
              TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
              ElevatedButton(
                onPressed: () {
                  if (reasonCtrl.text.trim().isEmpty) {
                    setDs(() {
                      reasonError = 'Rejection reason is required';
                    });
                    return;
                  }
                  Navigator.pop(ctx, true);
                },
                style: ElevatedButton.styleFrom(backgroundColor: Colors.red, foregroundColor: Colors.white),
                child: const Text('Reject'),
              ),
            ],
          );
        },
      ),
    );

    if (confirm == true) {
      final now = DateTime.now();
      final studentId = sData['id']?.toString() ?? '';
      if (studentId.isEmpty) return;

      final customReason = reasonCtrl.text.trim();
      final finalReason = customReason.isEmpty ? 'Rejoin request rejected by teacher.' : 'Rejoin request rejected by teacher. Reason: $customReason';

      final studentCache = MadrassaLocalStorage.getStudentCached(widget.branchId, studentId) ?? Map<String, dynamic>.from(sData);
      studentCache['rejoinRequestStatus'] = 'rejected';
      studentCache['lastUpdatedAt'] = now.toIso8601String();

      final auditList = List<Map<String, dynamic>>.from(
        (studentCache['auditLog'] as List? ?? []).whereType<Map>().map((e) => Map<String, dynamic>.from(e)),
      );
      auditList.add({
        'status': sData['status'] ?? 'left',
        'type': 'rejoin_rejection',
        'date': now.toIso8601String(),
        'reason': finalReason,
      });
      studentCache['auditLog'] = auditList;

      await MadrassaLocalStorage.cacheStudent(widget.branchId, studentId, studentCache);

      try {
        final payload = RealtimeEvents.payload(
          type: RealtimeEvents.saveMadrassaStudent,
          data: {
            ...studentCache,
            'studentId': studentId,
          },
          branchId: widget.branchId,
        );
        RealtimeManager().sendMessage(payload);
      } catch (e) {
        debugPrint('[StudentManagementView] LAN broadcast error: $e');
      }

      await LocalStorageService.enqueueSync({
        'type': 'save_madrassa_student',
        'branchId': widget.branchId,
        'studentId': studentId,
        'data': studentCache,
      });
      unawaited(SyncService().triggerUpload());

      unawaited(MadrassaAuditService.logAction(
        branchId: widget.branchId,
        editor: widget.username,
        role: widget.role,
        type: 'status_change',
        message: 'Rejected rejoining request for student ${sData['name'] ?? ''} (Roll: ${sData['rollNumber'] ?? ''}). Reason: $customReason',
        studentId: studentId,
        studentName: sData['name'],
      ));

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Rejoin rejected for ${sData['name'] ?? ''}')),
        );
      }
    }
  }
}
