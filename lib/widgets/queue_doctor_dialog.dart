import 'dart:async';
import 'package:flutter/material.dart';
import 'package:hive_flutter/hive_flutter.dart';
import '../services/local_storage_service.dart';
import '../services/queue_self_healing_service.dart';
import '../services/sync_service.dart';
import '../services/hidden_force_uploader.dart';

class QueueDoctorDialog extends StatefulWidget {
  const QueueDoctorDialog({super.key});

  static Future<void> show(BuildContext context) {
    return showDialog(
      context: context,
      barrierDismissible: true,
      builder: (_) => const QueueDoctorDialog(),
    );
  }

  @override
  State<QueueDoctorDialog> createState() => _QueueDoctorDialogState();
}

class _QueueDoctorDialogState extends State<QueueDoctorDialog> {
  bool _isHealing = false;
  QueueHealingReport? _lastReport;

  Map<String, int> _getTypeCounts() {
    final counts = <String, int>{};
    if (Hive.isBoxOpen(LocalStorageService.syncBox)) {
      final box = Hive.box(LocalStorageService.syncBox);
      for (final key in box.keys) {
        final val = box.get(key);
        if (val is Map) {
          final type = (val['type'] ?? 'unknown').toString();
          counts[type] = (counts[type] ?? 0) + 1;
        }
      }
    }
    return counts;
  }

  Future<void> _runHealing() async {
    setState(() => _isHealing = true);
    try {
      final report = await QueueSelfHealingService().healEntireQueue();
      // Launch high-speed background upload via Python Firebase Admin uploader
      unawaited(HiddenForceUploader.instance.runSilentForceUpload());
      // Also kick off Dart upload pass
      unawaited(SyncService().triggerUpload(force: true));
      if (mounted) {
        setState(() {
          _lastReport = report;
          _isHealing = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() => _isHealing = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Healing error: $e'), backgroundColor: Colors.red),
        );
      }
    }
  }

  Future<void> _purgeCategory(String type) async {
    if (!Hive.isBoxOpen(LocalStorageService.syncBox)) return;
    final box = Hive.box(LocalStorageService.syncBox);
    final keysToDelete = <dynamic>[];
    for (final key in box.keys) {
      final val = box.get(key);
      if (val is Map && (val['type'] ?? '').toString() == type) {
        keysToDelete.add(key);
      }
    }
    if (keysToDelete.isEmpty) return;

    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Purge ${type.replaceAll('_', ' ').toUpperCase()}?'),
        content: Text(
          'Are you sure you want to remove all ${keysToDelete.length} queued ${type.replaceAll('_', ' ')} records from this station? This cannot be undone.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Purge'),
          ),
        ],
      ),
    );

    if (confirm != true) return;

    await box.deleteAll(keysToDelete);
    await box.flush();
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Successfully removed ${keysToDelete.length} ${type.replaceAll('_', ' ')} records.'),
          backgroundColor: const Color(0xFF00695C),
        ),
      );
      setState(() {});
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Dialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      backgroundColor: isDark ? const Color(0xFF1E293B) : Colors.white,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 580, maxHeight: 680),
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Header
              Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: const Color(0xFF00695C).withValues(alpha: 0.15),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: const Icon(Icons.healing_rounded, color: Color(0xFF00897B), size: 26),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Queue Doctor & Self-Healing',
                          style: TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.bold,
                            color: isDark ? Colors.white : const Color(0xFF0F172A),
                          ),
                        ),
                        Text(
                          'Diagnose, auto-repair corrupted records, and flush backlogs to Cloud Firestore',
                          style: TextStyle(
                            fontSize: 12,
                            color: isDark ? Colors.white60 : Colors.black54,
                          ),
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.close),
                    onPressed: () => Navigator.of(context).pop(),
                  ),
                ],
              ),
              const Divider(height: 28),

              // Live Queue Counts
              ValueListenableBuilder(
                valueListenable: Hive.box(LocalStorageService.syncBox).listenable(),
                builder: (context, Box box, _) {
                  final totalPending = box.length;
                  final typeCounts = _getTypeCounts();
                  final deadLetters = Hive.isBoxOpen(LocalStorageService.deadLetterQueueBox)
                      ? Hive.box(LocalStorageService.deadLetterQueueBox).length
                      : 0;

                  return Expanded(
                    child: ListView(
                      children: [
                        // Summary Cards
                        Row(
                          children: [
                            Expanded(
                              child: _statCard(
                                title: 'Pending Upload',
                                count: totalPending,
                                color: totalPending > 0 ? Colors.orange : Colors.green,
                                icon: Icons.cloud_upload_outlined,
                                isDark: isDark,
                              ),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: _statCard(
                                title: 'Dead Letter / Stalled',
                                count: deadLetters,
                                color: deadLetters > 0 ? Colors.redAccent : Colors.blueGrey,
                                icon: Icons.warning_amber_rounded,
                                isDark: isDark,
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 18),

                        // Healing report if just run
                        if (_lastReport != null) ...[
                          Container(
                            padding: const EdgeInsets.all(12),
                            decoration: BoxDecoration(
                              color: const Color(0xFF10B981).withValues(alpha: 0.12),
                              borderRadius: BorderRadius.circular(12),
                              border: Border.all(color: const Color(0xFF10B981).withValues(alpha: 0.4)),
                            ),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                const Row(
                                  children: [
                                    Icon(Icons.check_circle, color: Color(0xFF10B981), size: 18),
                                    SizedBox(width: 8),
                                    Text(
                                      'Self-Healing Sweep Completed',
                                      style: TextStyle(color: Color(0xFF10B981), fontWeight: FontWeight.bold, fontSize: 13),
                                    ),
                                  ],
                                ),
                                const SizedBox(height: 6),
                                Text(
                                  '• ${_lastReport!.healedCount} malformed actions repaired (camps/branches resolved)\n'
                                  '• ${_lastReport!.deadLettersRevived} dead-letter items revived back into active queue\n'
                                  '• ${_lastReport!.duplicatesPurged} obsolete duplicates cleaned',
                                  style: TextStyle(fontSize: 12, color: isDark ? Colors.white70 : Colors.black87),
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(height: 16),
                        ],

                        // Breakdown by entity type
                        Text(
                          'Queued Backlog Breakdown',
                          style: TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w700,
                            color: isDark ? Colors.white70 : Colors.black87,
                          ),
                        ),
                        const SizedBox(height: 8),
                        if (typeCounts.isEmpty)
                          Padding(
                            padding: const EdgeInsets.symmetric(vertical: 24),
                            child: Center(
                              child: Column(
                                children: [
                                  const Icon(Icons.cloud_done, color: Colors.green, size: 36),
                                  const SizedBox(height: 8),
                                  Text(
                                    'All queues are completely clear!',
                                    style: TextStyle(color: isDark ? Colors.white60 : Colors.black54, fontSize: 13),
                                  ),
                                ],
                              ),
                            ),
                          )
                        else
                          ...typeCounts.entries.map((entry) {
                            return Container(
                              margin: const EdgeInsets.only(bottom: 6),
                              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                              decoration: BoxDecoration(
                                color: isDark ? const Color(0xFF0F172A) : const Color(0xFFF8FAFC),
                                borderRadius: BorderRadius.circular(8),
                                border: Border.all(color: isDark ? Colors.white10 : Colors.black12),
                              ),
                              child: Row(
                                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                children: [
                                  Text(
                                    entry.key.replaceAll('_', ' ').toUpperCase(),
                                    style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: isDark ? Colors.white70 : Colors.black87),
                                  ),
                                  Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Container(
                                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                                        decoration: BoxDecoration(
                                          color: const Color(0xFF00695C).withValues(alpha: 0.15),
                                          borderRadius: BorderRadius.circular(10),
                                        ),
                                        child: Text(
                                          '${entry.value}',
                                          style: const TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: Color(0xFF00897B)),
                                        ),
                                      ),
                                      const SizedBox(width: 6),
                                      IconButton(
                                        icon: const Icon(Icons.delete_outline_rounded, size: 18, color: Colors.redAccent),
                                        tooltip: 'Purge all ${entry.value} ${entry.key.replaceAll('_', ' ')} records from queue',
                                        constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
                                        padding: EdgeInsets.zero,
                                        onPressed: () => _purgeCategory(entry.key),
                                      ),
                                    ],
                                  ),
                                ],
                              ),
                            );
                          }),
                      ],
                    ),
                  );
                },
              ),

              const SizedBox(height: 16),
              // Action Buttons
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      style: OutlinedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                      ),
                      onPressed: _isHealing ? null : () => SyncService().broadcastUniversalForceUpload(),
                      icon: const Icon(Icons.broadcast_on_personal_rounded, size: 18),
                      label: const Text('Universal Force Broadcast'),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: ElevatedButton.icon(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFF00695C),
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                      ),
                      onPressed: _isHealing ? null : _runHealing,
                      icon: _isHealing
                          ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2))
                          : const Icon(Icons.auto_fix_high_rounded, size: 18),
                      label: Text(_isHealing ? 'Healing & Syncing...' : 'Auto-Heal & Flush Now'),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _statCard({
    required String title,
    required int count,
    required Color color,
    required IconData icon,
    required bool isDark,
  }) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: color.withValues(alpha: 0.25)),
      ),
      child: Row(
        children: [
          Icon(icon, color: color, size: 26),
          const SizedBox(width: 12),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '$count',
                style: TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.bold,
                  color: color,
                ),
              ),
              Text(
                title,
                style: TextStyle(
                  fontSize: 11,
                  color: isDark ? Colors.white60 : Colors.black54,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
