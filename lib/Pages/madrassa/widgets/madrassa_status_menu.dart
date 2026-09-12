import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:intl/intl.dart';
import '../madrassa_strings.dart';
import 'madrassa_common_widgets.dart';
import '../../../theme/app_theme.dart';
import '../dialogs/enrollment_dialog.dart';
import '../utils/madrassa_local_storage.dart';
import '../../../widgets/media_upload_tile.dart';
import '../../../realtime/realtime_manager.dart';
import '../../../realtime/realtime_events.dart';
import '../../../services/local_storage_service.dart';
import '../../../services/sync_service.dart';
import 'dart:async';

class StatusActionMenu extends StatelessWidget {
  final dynamic student;
  final String branchId;
  final bool isAdmin;
  final RoleThemeData t;
  final String username;
  final String role;

  const StatusActionMenu({
    super.key,
    required this.student,
    required this.branchId,
    required this.isAdmin,
    required this.t,
    required this.username,
    required this.role,
  });

  Map<String, dynamic> _getStudentData() {
    if (student is DocumentSnapshot) {
      return _asStringMap((student as DocumentSnapshot).data()) ?? <String, dynamic>{};
    } else {
      return _asStringMap(student) ?? <String, dynamic>{};
    }
  }

  Future<void> _updateStatus(BuildContext context, String newStatus) async {
    final sData = _getStudentData();
    final studentId = student is DocumentSnapshot ? (student as DocumentSnapshot).id : (student as Map)['id'].toString();
    final currentStatus = sData['status'] ?? 'active';
    if (newStatus == currentStatus) return;

    String statusLabelEn = '';
    if (newStatus == 'active') {
      statusLabelEn = context.l.statusActive;
    } else if (newStatus == 'archived') {
      statusLabelEn = context.l.statusArchived;
    } else if (newStatus == 'hifz_completed') {
      statusLabelEn = context.l.statusHifzCompleted;
    } else if (newStatus == 'left') {
      statusLabelEn = context.l.statusLeft;
    } else if (newStatus == 'dropped') {
      statusLabelEn = context.isUrdu ? 'خارج' : 'Dropped Out';
    }

    // Statuses that carry their own event date, and the Firestore field it's stored in
    const dateFieldForStatus = {
      'archived': 'archivedDate',
      'hifz_completed': 'hifzCompletionDate',
      'left': 'leftDate',
      'dropped': 'droppedDate',
    };
    final isUnarchive = newStatus == 'active';
    final requiresDate = dateFieldForStatus.containsKey(newStatus);
    final dateFieldName = dateFieldForStatus[newStatus];

    String dialogTitle;
    if (isUnarchive) {
      dialogTitle = context.l.unarchiveStudent;
    } else if (newStatus == 'hifz_completed') {
      dialogTitle = context.isUrdu ? 'حفظ کی تکمیل' : 'Mark Hifz Completed';
    } else if (newStatus == 'left') {
      dialogTitle = context.isUrdu ? 'طالب علم چھوڑ گیا' : 'Mark as Left';
    } else if (newStatus == 'dropped') {
      dialogTitle = context.isUrdu ? 'طالب علم خارج' : 'Mark as Dropped Out';
    } else {
      dialogTitle = context.l.archiveStudent;
    }

    Color confirmColor;
    if (isUnarchive) {
      confirmColor = Colors.green;
    } else if (newStatus == 'hifz_completed') {
      confirmColor = const Color(0xFF4C4DDC);
    } else if (newStatus == 'left') {
      confirmColor = Colors.redAccent;
    } else if (newStatus == 'dropped') {
      confirmColor = Colors.red;
    } else {
      confirmColor = Colors.orange;
    }

    final reasonCtrl = TextEditingController();
    // Required statuses default to today; unarchive starts empty (optional, opt-in)
    DateTime? selectedDate = requiresDate ? DateTime.now() : null;
    String? hifzCertBase64 = sData['hifzCertificateUrl'] ?? sData['hifzCertificateBase64'];

    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDs) {
          return AlertDialog(
            backgroundColor: t.bgCard,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
            title: Text(
              dialogTitle,
              style: context.urduStyle(style: TextStyle(fontWeight: FontWeight.bold, color: t.textPrimary)),
            ),
            content: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    context.l.confirmAction.replaceAll('{action}', statusLabelEn).replaceAll('{name}', sData['name'] ?? ''),
                    style: context.urduStyle(style: TextStyle(color: t.textSecondary)),
                  ),
                  if (requiresDate || isUnarchive) ...[
                    const SizedBox(height: 16),
                    Text(
                      isUnarchive
                          ? (ctx.isUrdu ? 'دوبارہ فعال ہونے کی تاریخ (اختیاری)' : 'Reactivation Date (optional)')
                          : (ctx.isUrdu ? 'واقعہ کی تاریخ' : 'Event Date'),
                      style: context.urduStyle(
                        style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: Color(0xFF008080)),
                      ),
                    ),
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        Expanded(
                          child: InkWell(
                            borderRadius: BorderRadius.circular(12),
                            onTap: () async {
                              final picked = await showDatePicker(
                                context: ctx,
                                initialDate: selectedDate ?? DateTime.now(),
                                firstDate: DateTime(2000),
                                lastDate: DateTime.now(),
                              );
                              if (picked != null) {
                                setDs(() => selectedDate = picked);
                              }
                            },
                            child: Container(
                              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                              decoration: BoxDecoration(
                                border: Border.all(color: t.bgRule),
                                borderRadius: BorderRadius.circular(12),
                              ),
                              child: Row(
                                children: [
                                  const Icon(Icons.calendar_today_outlined, size: 16, color: Color(0xFF008080)),
                                  const SizedBox(width: 10),
                                  Text(
                                    selectedDate != null
                                        ? DateFormat('d MMM yyyy').format(selectedDate!)
                                        : (ctx.isUrdu ? 'کوئی تاریخ منتخب نہیں' : 'No date selected'),
                                    style: TextStyle(fontWeight: FontWeight.w600, color: t.textPrimary),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                        // Only unarchive can clear back to "no date" — required statuses always keep one
                        if (isUnarchive && selectedDate != null) ...[
                          const SizedBox(width: 8),
                          IconButton(
                            icon: const Icon(Icons.clear, size: 18, color: Colors.grey),
                            tooltip: 'Clear',
                            onPressed: () => setDs(() => selectedDate = null),
                          ),
                        ],
                      ],
                    ),
                  ],
                  if (newStatus == 'hifz_completed') ...[
                    const SizedBox(height: 16),
                    MediaUploadTile(
                      label: 'Certificate of Hifz Completion',
                      icon: Icons.workspace_premium_outlined,
                      initialValue: hifzCertBase64,
                      isDocument: true,
                      onChanged: (val) => setDs(() => hifzCertBase64 = val),
                    ),
                  ],
                  const SizedBox(height: 20),
                  buildTf(
                    reasonCtrl,
                    'Custom Reason / Additional Notes',
                    Icons.comment,
                    context,
                    hint: 'e.g. Moved to another city',
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(
                  onPressed: () => Navigator.pop(ctx, false),
                  child: Text(context.l.cancel, style: context.urduStyle())),
              ElevatedButton(
                onPressed: () => Navigator.pop(ctx, true),
                style: ElevatedButton.styleFrom(
                  backgroundColor: confirmColor,
                  foregroundColor: Colors.white,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                ),
                child: Text(context.l.confirm, style: context.urduStyle()),
              ),
            ],
          );
        },
      ),
    );

    if (confirm == true) {
      final now = Timestamp.now();
      final customReason = reasonCtrl.text.trim();
      String baseReason = statusLabelEn;
      if (requiresDate && selectedDate != null) {
        baseReason = '$statusLabelEn on ${DateFormat('d MMM yyyy').format(selectedDate!)}';
      }
      final finalReason = customReason.isEmpty ? baseReason : '$baseReason: $customReason';

      final updates = <String, dynamic>{
        'status': newStatus,
        'batch': newStatus,
        if (newStatus == 'hifz_completed' && hifzCertBase64 != null) ...{
          'hifzCertificateUrl': hifzCertBase64,
          'hifzCertificateBase64': hifzCertBase64,
        },
        'auditLog': FieldValue.arrayUnion([
          {
            'status': newStatus,
            'type': 'status_change',
            'date': now,
            'reason': finalReason,
          }
        ]),
      };

      if (requiresDate && dateFieldName != null && selectedDate != null) {
        updates[dateFieldName] = Timestamp.fromDate(selectedDate!);
      }
      if (isUnarchive && selectedDate != null) {
        updates['reactivatedDate'] = Timestamp.fromDate(selectedDate!);
      }

      if (newStatus == 'left' || newStatus == 'dropped' || newStatus == 'archived') {
        // Full offboard: Hive first, unenroll PIN, revoke app access, broadcast & queue
        await MadrassaLocalStorage.deleteOrOffboardStudentLocalAndSync(
          branchId: branchId,
          studentId: studentId,
          status: newStatus,
          reason: finalReason,
          effectiveDate: selectedDate,
        );
      } else {
        // Active or Hifz completed: instant local Hive cache update & flush
        final studentCache = MadrassaLocalStorage.getStudentCached(branchId, studentId) ?? Map<String, dynamic>.from(sData);
        studentCache['status'] = newStatus;
        studentCache['batch'] = newStatus;
        if (newStatus == 'hifz_completed' && hifzCertBase64 != null) {
          studentCache['hifzCertificateUrl'] = hifzCertBase64;
          studentCache['hifzCertificateBase64'] = hifzCertBase64;
        }
        if (requiresDate && dateFieldName != null && selectedDate != null) {
          studentCache[dateFieldName] = selectedDate!.toIso8601String();
        }
        studentCache['lastUpdatedAt'] = DateTime.now().toIso8601String();

        final auditList = List<Map<String, dynamic>>.from(
          (studentCache['auditLog'] as List? ?? []).whereType<Map>().map((e) => Map<String, dynamic>.from(e)),
        );
        auditList.add({
          'status': newStatus,
          'type': 'status_change',
          'date': (selectedDate ?? DateTime.now()).toIso8601String(),
          'reason': finalReason,
        });
        studentCache['auditLog'] = auditList;

        await MadrassaLocalStorage.cacheStudent(branchId, studentId, studentCache);

        // Broadcast LAN
        try {
          final payload = RealtimeEvents.payload(
            type: RealtimeEvents.saveMadrassaStudent,
            data: {
              ...studentCache,
              'studentId': studentId,
            },
            branchId: branchId,
          );
          RealtimeManager().sendMessage(payload);
        } catch (e) {
          debugPrint('[MadrassaStatusMenu] LAN broadcast error: $e');
        }

        // Always enqueue sync
        try {
          await LocalStorageService.enqueueSync({
            'type': 'save_madrassa_student',
            'branchId': branchId,
            'studentId': studentId,
            'data': studentCache,
          });
          unawaited(SyncService().triggerUpload());
        } catch (e) {
          debugPrint('[MadrassaStatusMenu] enqueueSync error: $e');
        }
      }

      // Calculate active tenure duration
      final joinDate = _parseDateTime(sData['joinDate']);
      final durationStr = _formatDuration(joinDate, selectedDate ?? DateTime.now());
      String statusDetail = '';
      if (newStatus == 'hifz_completed') {
        statusDetail = 'Hifz Completed in $durationStr';
      } else if (newStatus == 'archived') {
        statusDetail = 'Moved to Archive after $durationStr of active study';
      } else if (newStatus == 'left') {
        statusDetail = 'Marked as Left after $durationStr';
      } else if (newStatus == 'dropped') {
        statusDetail = 'Expelled / Dropped Out after $durationStr';
      } else if (newStatus == 'active') {
        statusDetail = 'Reactivated into Active classes';
      }

      final auditMsg = '${sData['name'] ?? 'Student'} status changed from ${currentStatus.toUpperCase()} to ${newStatus.toUpperCase()} ($statusDetail). Note: $finalReason';

      // Centralized Audit Log
      await MadrassaAuditService.logAction(
        branchId: branchId,
        editor: username,
        role: role,
        type: 'status_change',
        message: auditMsg,
        studentId: studentId,
        studentName: sData['name'],
      );
    }
  }

  String _formatDuration(DateTime start, DateTime end) {
    int years = end.year - start.year;
    int months = end.month - start.month;
    int days = end.day - start.day;

    if (days < 0) {
      months -= 1;
      final prevMonth = DateTime(end.year, end.month, 0);
      days += prevMonth.day;
    }
    if (months < 0) {
      years -= 1;
      months += 12;
    }

    final parts = <String>[];
    if (years > 0) parts.add('$years ${years == 1 ? "year" : "years"}');
    if (months > 0) parts.add('$months ${months == 1 ? "month" : "months"}');
    if (days > 0 || parts.isEmpty) parts.add('$days ${days == 1 ? "day" : "days"}');
    return parts.join(', ');
  }

  void _showHistoryDialog(BuildContext context) {
    final sData = _getStudentData();
    final name = sData['name'] ?? '';
    final joinDate = _parseDateTime(sData['joinDate']);

    final rawAudit = sData['auditLog'];
    final auditListRaw = rawAudit is List ? rawAudit : [];
    final auditList = List<Map<String, dynamic>>.from(
      auditListRaw.whereType<Map>().map((e) => Map<String, dynamic>.from(e)),
    );

    // Sort audit list chronologically (oldest first for a sequential timeline)
    auditList.sort((a, b) {
      final aDate = _parseDateTime(a['date']);
      final bDate = _parseDateTime(b['date']);
      return aDate.compareTo(bDate);
    });

    final durationStr = _formatDuration(joinDate, DateTime.now());

    showDialog(
      context: context,
      builder: (ctx) {
        return AlertDialog(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
          title: Text(
            context.l.auditLog,
            style: context.urduStyle(style: const TextStyle(fontWeight: FontWeight.bold)),
          ),
          content: SizedBox(
            width: double.maxFinite,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Student: $name',
                  style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
                ),
                const SizedBox(height: 4),
                Text(
                  'Total Duration: $durationStr',
                  style: TextStyle(color: Colors.grey[600], fontSize: 13),
                ),
                const SizedBox(height: 16),
                const Divider(),
                const SizedBox(height: 8),
                if (auditList.isEmpty)
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: 20),
                    child: Center(
                      child: Text('No history records found.'),
                    ),
                  )
                else
                  Flexible(
                    child: ListView.builder(
                      shrinkWrap: true,
                      itemCount: auditList.length,
                      itemBuilder: (context, idx) {
                        final log = auditList[idx];
                        final logStatus = log['status'] ?? 'unknown';
                        final logType = log['type'] ?? 'info';
                        final logDate = _parseDateTime(log['date']);
                        final logReason = log['reason'] ?? '';

                        Color dotColor = Colors.grey;
                        IconData icon = Icons.circle;
                        if (logStatus == 'active' || logType == 'enrollment' || logType == 'rejoin_approval') {
                          dotColor = const Color(0xFF008080); // Teal
                          icon = Icons.check_circle_outline;
                        } else if (logStatus == 'left' || logType == 'rejoin_rejection') {
                          dotColor = Colors.redAccent;
                          icon = Icons.error_outline;
                        } else if (logStatus == 'archived') {
                          dotColor = Colors.orange;
                          icon = Icons.archive_outlined;
                        } else if (logStatus == 'hifz_completed') {
                          dotColor = const Color(0xFF4C4DDC); // Purple
                          icon = Icons.stars_outlined;
                        } else if (logStatus == 'dropped') {
                          dotColor = Colors.red;
                          icon = Icons.remove_circle_outline;
                        }

                        return IntrinsicHeight(
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              Column(
                                children: [
                                  Icon(icon, color: dotColor, size: 22),
                                  if (idx < auditList.length - 1)
                                    Expanded(
                                      child: Container(
                                        width: 2,
                                        color: Colors.grey[300],
                                        margin: const EdgeInsets.symmetric(vertical: 4),
                                      ),
                                    ),
                                ],
                              ),
                              const SizedBox(width: 12),
                              Expanded(
                                child: Padding(
                                  padding: const EdgeInsets.only(bottom: 16.0),
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        '${logStatus.toUpperCase()} (${logType.replaceAll('_', ' ')})',
                                        style: TextStyle(
                                          fontWeight: FontWeight.bold,
                                          fontSize: 13,
                                          color: dotColor,
                                        ),
                                      ),
                                      const SizedBox(height: 2),
                                      Text(
                                        logReason,
                                        style: const TextStyle(fontSize: 12, color: Colors.black87),
                                      ),
                                      const SizedBox(height: 4),
                                      Text(
                                        DateFormat('dd MMMM yyyy, hh:mm a').format(logDate),
                                        style: TextStyle(
                                          color: Colors.grey[500],
                                          fontSize: 10,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            ],
                          ),
                        );
                      },
                    ),
                  ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Close'),
            ),
          ],
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final sData = _getStudentData();
    final status = sData['status'] ?? 'active';

    return PopupMenuButton<String>(
      icon: Icon(Icons.more_vert, color: t.textTertiary),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      onSelected: (val) {
        if (val == 'edit') {
          showAddStudentDialog(
            context,
            branchId,
            student: student,
            username: username,
            role: role,
          );
        } else if (val == 'history') {
          _showHistoryDialog(context);
        } else {
          _updateStatus(context, val);
        }
      },
      itemBuilder: (ctx) => [
        PopupMenuItem(
          value: 'edit',
          child: Row(
            children: [
              Container(
                padding: const EdgeInsets.all(6),
                decoration: BoxDecoration(
                  color: const Color(0xFF4C4DDC).withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: const Icon(Icons.edit_rounded, size: 16, color: Color(0xFF4C4DDC)),
              ),
              const SizedBox(width: 10),
              Text(
                'Edit Student Profile',
                style: context.urduStyle(style: const TextStyle(fontWeight: FontWeight.bold, color: Color(0xFF4C4DDC), fontSize: 13)),
              ),
            ],
          ),
        ),
        const PopupMenuDivider(),
        if (status != 'active')
          PopupMenuItem(
            value: 'active',
            child: Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(6),
                  decoration: BoxDecoration(
                    color: Colors.green.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: const Icon(Icons.check_circle_rounded, size: 16, color: Colors.green),
                ),
                const SizedBox(width: 10),
                Text(context.l.statusActive, style: context.urduStyle(style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13))),
              ],
            ),
          ),
        if (status == 'active') ...[
          PopupMenuItem(
            value: 'hifz_completed',
            child: Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(6),
                  decoration: BoxDecoration(
                    color: const Color(0xFF4C4DDC).withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: const Icon(Icons.workspace_premium_rounded, size: 16, color: Color(0xFF4C4DDC)),
                ),
                const SizedBox(width: 10),
                Text(context.l.statusHifzCompleted, style: context.urduStyle(style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13))),
              ],
            ),
          ),
          PopupMenuItem(
            value: 'left',
            child: Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(6),
                  decoration: BoxDecoration(
                    color: Colors.redAccent.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: const Icon(Icons.exit_to_app_rounded, size: 16, color: Colors.redAccent),
                ),
                const SizedBox(width: 10),
                Text(context.l.statusLeft, style: context.urduStyle(style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13))),
              ],
            ),
          ),
          PopupMenuItem(
            value: 'dropped',
            child: Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(6),
                  decoration: BoxDecoration(
                    color: Colors.red.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: const Icon(Icons.person_off_rounded, size: 16, color: Colors.red),
                ),
                const SizedBox(width: 10),
                Text(context.isUrdu ? 'خارج' : 'Dropped Out', style: context.urduStyle(style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13))),
              ],
            ),
          ),
          PopupMenuItem(
            value: 'archived',
            child: Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(6),
                  decoration: BoxDecoration(
                    color: Colors.orange.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: const Icon(Icons.archive_rounded, size: 16, color: Colors.orange),
                ),
                const SizedBox(width: 10),
                Text(context.l.statusArchived, style: context.urduStyle(style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13))),
              ],
            ),
          ),
        ],
        const PopupMenuDivider(),
        PopupMenuItem(
          value: 'history',
          child: Row(
            children: [
              Container(
                padding: const EdgeInsets.all(6),
                decoration: BoxDecoration(
                  color: Colors.grey.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: const Icon(Icons.history_rounded, size: 16, color: Colors.grey),
              ),
              const SizedBox(width: 10),
              Text('Audit & Status History', style: context.urduStyle(style: const TextStyle(fontWeight: FontWeight.w500, fontSize: 13))),
            ],
          ),
        ),
      ],
    );
  }
}

Map<String, dynamic>? _asStringMap(dynamic raw) {
  if (raw == null) return null;
  if (raw is Map<String, dynamic>) return raw;
  if (raw is Map) return Map<String, dynamic>.from(raw);
  return null;
}

DateTime _parseDateTime(dynamic val) {
  if (val == null) return DateTime.now();
  if (val is Timestamp) return val.toDate();
  if (val is String) {
    return DateTime.tryParse(val) ?? DateTime.now();
  }
  if (val is DateTime) return val;
  return DateTime.now();
}