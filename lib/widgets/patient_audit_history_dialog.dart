// lib/widgets/patient_audit_history_dialog.dart

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../services/local_storage_service.dart';

class PatientAuditHistoryDialog extends StatelessWidget {
  final String patientId;
  final String? serial;
  final String? patientName;
  final String? branchId;

  const PatientAuditHistoryDialog({
    super.key,
    required this.patientId,
    this.serial,
    this.patientName,
    this.branchId,
  });

  static Future<void> show(
    BuildContext context, {
    required String patientId,
    String? serial,
    String? patientName,
    String? branchId,
  }) {
    return showDialog(
      context: context,
      builder: (_) => PatientAuditHistoryDialog(
        patientId: patientId,
        serial: serial,
        patientName: patientName,
        branchId: branchId,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final logs = LocalStorageService.getPatientAuditLogs(
      branchId: branchId,
      patientId: patientId,
      serial: serial,
    );

    final bgCard = isDark ? const Color(0xFF1E293B) : Colors.white;
    final bgHeader = isDark ? const Color(0xFF0F172A) : const Color(0xFFF8FAFC);
    final borderCol = isDark ? const Color(0xFF334155) : const Color(0xFFE2E8F0);
    final textPrimary = isDark ? Colors.white : const Color(0xFF0F172A);
    final textSecondary = isDark ? const Color(0xFF94A3B8) : const Color(0xFF64748B);

    final displayName = patientName ??
        (logs.isNotEmpty ? logs.first['patientName']?.toString() : null) ??
        'Patient Details';
    final displaySerial = serial ??
        (logs.isNotEmpty ? logs.first['serial']?.toString() : null) ??
        '';

    return Dialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      backgroundColor: bgCard,
      insetPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 24),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 680, maxHeight: 720),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Header
            Container(
              padding: const EdgeInsets.fromLTRB(24, 20, 20, 16),
              decoration: BoxDecoration(
                color: bgHeader,
                borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
              ),
              child: Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: const Color(0xFF0D9488).withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: const Icon(Icons.history_rounded, color: Color(0xFF0D9488), size: 22),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Flexible(
                              child: Text(
                                displayName,
                                style: TextStyle(
                                  color: textPrimary,
                                  fontSize: 16,
                                  fontWeight: FontWeight.bold,
                                ),
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                            if (displaySerial.isNotEmpty) ...[
                              const SizedBox(width: 8),
                              Container(
                                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                decoration: BoxDecoration(
                                  color: const Color(0xFF6366F1).withValues(alpha: 0.15),
                                  borderRadius: BorderRadius.circular(6),
                                ),
                                child: Text(
                                  displaySerial,
                                  style: const TextStyle(
                                    color: Color(0xFF6366F1),
                                    fontSize: 11,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                              ),
                            ],
                          ],
                        ),
                        const SizedBox(height: 2),
                        Text(
                          'Audit trail, edit approvals & deletion history',
                          style: TextStyle(color: textSecondary, fontSize: 12),
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    icon: Icon(Icons.close_rounded, color: textSecondary, size: 20),
                    onPressed: () => Navigator.of(context).pop(),
                  ),
                ],
              ),
            ),
            Divider(height: 1, thickness: 1, color: borderCol),

            // Content Body
            Expanded(
              child: logs.isEmpty
                  ? Center(
                      child: Padding(
                        padding: const EdgeInsets.all(32),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(Icons.shield_outlined, size: 48, color: textSecondary.withValues(alpha: 0.4)),
                            const SizedBox(height: 12),
                            Text(
                              'No audit changes recorded yet.',
                              style: TextStyle(color: textSecondary, fontSize: 14, fontWeight: FontWeight.w600),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              'All modifications, supervisor approvals, and deletions will appear here.',
                              textAlign: TextAlign.center,
                              style: TextStyle(color: textSecondary.withValues(alpha: 0.8), fontSize: 12),
                            ),
                          ],
                        ),
                      ),
                    )
                  : ListView.builder(
                      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
                      itemCount: logs.length,
                      itemBuilder: (ctx, idx) {
                        final log = logs[idx];
                        return _buildAuditItem(log, isDark, textPrimary, textSecondary, borderCol);
                      },
                    ),
            ),

            // Footer
            Divider(height: 1, thickness: 1, color: borderCol),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
              decoration: BoxDecoration(
                color: bgHeader,
                borderRadius: const BorderRadius.vertical(bottom: Radius.circular(20)),
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    '${logs.length} audit event${logs.length == 1 ? '' : 's'} logged',
                    style: TextStyle(color: textSecondary, fontSize: 11, fontWeight: FontWeight.w600),
                  ),
                  TextButton(
                    onPressed: () => Navigator.of(context).pop(),
                    style: TextButton.styleFrom(
                      foregroundColor: const Color(0xFF0D9488),
                      textStyle: const TextStyle(fontWeight: FontWeight.bold),
                    ),
                    child: const Text('Close'),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildAuditItem(
    Map<String, dynamic> log,
    bool isDark,
    Color textPrimary,
    Color textSecondary,
    Color borderCol,
  ) {
    final act = (log['action'] ?? '').toString().toUpperCase();
    final performedBy = log['performedBy'] ?? 'Staff';
    final performedRole = (log['performedByRole'] ?? '').toString();
    final approvedBy = log['approvedBy']?.toString();
    final rejectedBy = log['rejectedBy']?.toString();
    final requestedBy = log['requestedBy']?.toString();
    final reason = (log['reason'] ?? '').toString();
    final tsStr = log['timestamp'] ?? log['createdAt'] ?? '';

    DateTime? dt;
    if (tsStr.isNotEmpty) {
      dt = DateTime.tryParse(tsStr)?.toLocal();
    }
    final timeFormatted = dt != null ? DateFormat('dd MMM yyyy, hh:mm a').format(dt) : 'Recent';

    Color actColor = const Color(0xFF3B82F6);
    IconData actIcon = Icons.edit_rounded;
    String actLabel = 'EDITED';

    if (act == 'CREATE') {
      actColor = const Color(0xFF10B981);
      actIcon = Icons.person_add_alt_1_rounded;
      actLabel = 'REGISTERED';
    } else if (act == 'DELETE' || act == 'DELETE_TOKEN') {
      actColor = const Color(0xFFEF4444);
      actIcon = Icons.delete_forever_rounded;
      actLabel = 'DELETED';
    } else if (act == 'REQUEST_EDIT') {
      actColor = const Color(0xFFF59E0B);
      actIcon = Icons.pending_actions_rounded;
      actLabel = 'EDIT REQUESTED';
    } else if (act == 'APPROVE_EDIT') {
      actColor = const Color(0xFF10B981);
      actIcon = Icons.check_circle_outline_rounded;
      actLabel = 'EDIT APPROVED';
    } else if (act == 'REJECT_EDIT') {
      actColor = const Color(0xFFEF4444);
      actIcon = Icons.cancel_outlined;
      actLabel = 'EDIT REJECTED';
    } else if (act == 'TOKEN_EXCEPTION_APPROVED') {
      actColor = const Color(0xFF8B5CF6);
      actIcon = Icons.verified_user_rounded;
      actLabel = 'RESTRICTION OVERRIDDEN';
    }

    // Parse changes
    final fieldChanges = <Map<String, dynamic>>[];
    if (log['fieldChanges'] is List) {
      for (final item in (log['fieldChanges'] as List)) {
        if (item is Map) fieldChanges.add(Map<String, dynamic>.from(item));
      }
    } else if (log['fieldChanges'] is Map) {
      final map = log['fieldChanges'] as Map;
      map.forEach((k, v) {
        if (v is Map) {
          fieldChanges.add({
            'field': k,
            'oldValue': v['old'],
            'newValue': v['new'],
          });
        }
      });
    }

    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF0F172A) : Colors.white,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: borderCol),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Header row: action badge, date
          Row(
            children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: actColor.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(actIcon, size: 13, color: actColor),
                    const SizedBox(width: 4),
                    Text(
                      actLabel,
                      style: TextStyle(
                        color: actColor,
                        fontSize: 10.5,
                        fontWeight: FontWeight.bold,
                        letterSpacing: 0.3,
                      ),
                    ),
                  ],
                ),
              ),
              const Spacer(),
              Text(
                timeFormatted,
                style: TextStyle(color: textSecondary, fontSize: 11),
              ),
            ],
          ),
          const SizedBox(height: 10),

          // User & Approval Context
          Wrap(
            spacing: 12,
            runSpacing: 4,
            children: [
              Text(
                'By: $performedBy${performedRole.isNotEmpty ? " ($performedRole)" : ""}',
                style: TextStyle(color: textPrimary, fontSize: 12, fontWeight: FontWeight.w600),
              ),
              if (approvedBy != null && approvedBy.isNotEmpty)
                Text(
                  '✅ Approved by: $approvedBy',
                  style: const TextStyle(color: Color(0xFF10B981), fontSize: 12, fontWeight: FontWeight.bold),
                ),
              if (rejectedBy != null && rejectedBy.isNotEmpty)
                Text(
                  '❌ Rejected by: $rejectedBy',
                  style: const TextStyle(color: Color(0xFFEF4444), fontSize: 12, fontWeight: FontWeight.bold),
                ),
              if (requestedBy != null && requestedBy.isNotEmpty)
                Text(
                  'Requested by: $requestedBy',
                  style: TextStyle(color: textSecondary, fontSize: 12),
                ),
            ],
          ),

          if (reason.isNotEmpty) ...[
            const SizedBox(height: 6),
            Text(
              'Reason: $reason',
              style: TextStyle(color: textSecondary, fontSize: 12, fontStyle: FontStyle.italic),
            ),
          ],

          // Field differences diff view
          if (fieldChanges.isNotEmpty) ...[
            const SizedBox(height: 10),
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: isDark ? const Color(0xFF1E293B) : const Color(0xFFF1F5F9),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: fieldChanges.map((ch) {
                  final field = ch['field'] ?? 'Field';
                  final oldVal = (ch['oldValue'] ?? '-').toString();
                  final newVal = (ch['newValue'] ?? '-').toString();
                  return Padding(
                    padding: const EdgeInsets.symmetric(vertical: 2),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '• $field: ',
                          style: TextStyle(color: textPrimary, fontSize: 11, fontWeight: FontWeight.bold),
                        ),
                        Expanded(
                          child: RichText(
                            text: TextSpan(
                              style: const TextStyle(fontSize: 11, fontFamily: 'monospace'),
                              children: [
                                TextSpan(
                                  text: oldVal,
                                  style: const TextStyle(color: Color(0xFFEF4444), decoration: TextDecoration.lineThrough),
                                ),
                                const TextSpan(text: '  ➔  ', style: TextStyle(color: Colors.grey)),
                                TextSpan(
                                  text: newVal,
                                  style: const TextStyle(color: Color(0xFF10B981), fontWeight: FontWeight.bold),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ],
                    ),
                  );
                }).toList(),
              ),
            ),
          ],
        ],
      ),
    );
  }
}
