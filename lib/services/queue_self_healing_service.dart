import 'package:flutter/foundation.dart';
import 'package:hive/hive.dart';
import 'camp_session_service.dart';
import 'local_storage_service.dart';

class QueueHealingReport {
  final int totalInspected;
  final int healedCount;
  final int deadLettersRevived;
  final int duplicatesPurged;
  final int readyToUpload;
  final List<String> healedDetails;

  const QueueHealingReport({
    required this.totalInspected,
    required this.healedCount,
    required this.deadLettersRevived,
    required this.duplicatesPurged,
    required this.readyToUpload,
    required this.healedDetails,
  });

  @override
  String toString() =>
      'QueueHealingReport(inspected: $totalInspected, healed: $healedCount, revived: $deadLettersRevived, purged: $duplicatesPurged, ready: $readyToUpload)';
}

class QueueSelfHealingService {
  static final QueueSelfHealingService _instance = QueueSelfHealingService._internal();
  factory QueueSelfHealingService() => _instance;
  QueueSelfHealingService._internal();

  /// Scans and repairs all items across sync_queue, server_sync_queue, and dead_letter_queue.
  Future<QueueHealingReport> healEntireQueue({String? fallbackBranchId}) async {
    int totalInspected = 0;
    int healedCount = 0;
    int deadLettersRevived = 0;
    final List<String> details = [];

    final effectiveFallbackBranch = fallbackBranchId ?? LocalStorageService.getActiveBranchId() ?? 'karachi';

    // 1. First, revive & heal dead letter queue
    deadLettersRevived = await _healAndReviveDeadLetters(effectiveFallbackBranch, details);

    // 2. Next, purge obsolete duplicate entries across queues
    final duplicatesPurged = await LocalStorageService.purgeBloatedSyncQueue();

    // 3. Heal all items in sync_queue
    for (final boxName in [LocalStorageService.syncBox, 'server_sync_queue']) {
      try {
        if (!Hive.isBoxOpen(boxName)) {
          await LocalStorageService.openBoxSafe(boxName);
        }
        final box = Hive.box(boxName);
        final allKeys = box.keys.toList();
        totalInspected += allKeys.length;

        for (final key in allKeys) {
          final raw = box.get(key);
          if (raw == null || raw is! Map) {
            await box.delete(key);
            continue;
          }

          final action = Map<String, dynamic>.from(raw);
          final bool wasRepaired = healAction(action, fallbackBranch: effectiveFallbackBranch);

          // Clear backoff window so records are immediately eligible for upload
          action.remove('nextRetryAt');
          if ((action['attempts'] as int? ?? 0) >= 3) {
            action['attempts'] = 0;
          }

          if (wasRepaired) {
            healedCount++;
            action['attempts'] = 0;
            action.remove('lastError');
            action['healedAt'] = DateTime.now().toUtc().toIso8601String();
          }
          await box.put(key, action);

          if (totalInspected % 50 == 0) {
            await Future.delayed(Duration.zero);
          }
        }
      } catch (e) {
        debugPrint('[QueueSelfHealing] Error healing box $boxName: $e');
      }
    }

    final totalRemaining = Hive.isBoxOpen(LocalStorageService.syncBox)
        ? Hive.box(LocalStorageService.syncBox).length
        : 0;

    final report = QueueHealingReport(
      totalInspected: totalInspected,
      healedCount: healedCount,
      deadLettersRevived: deadLettersRevived,
      duplicatesPurged: duplicatesPurged,
      readyToUpload: totalRemaining,
      healedDetails: details,
    );

    debugPrint('[QueueSelfHealing] 🩺 Self-Healing Completed: $report');
    return report;
  }

  /// On-the-fly self-healing for an individual queued item before uploading.
  /// Returns true if modifications were made to repair the action payload.
  static bool healAction(Map<String, dynamic> action, {String? fallbackBranch}) {
    bool modified = false;

    final rawType = (action['type'] ?? action['event_type'] ?? '').toString().trim();
    if (rawType.isEmpty) {
      action['type'] = 'unknown';
      modified = true;
    }

    // ── 1. BRANCH HEALING ───────────────────────────────────────────────────────
    String rawBranch = (action['branchId'] ?? '').toString().trim().toLowerCase();
    final data = action['data'] is Map ? Map<String, dynamic>.from(action['data']) : <String, dynamic>{};

    // If branch is invalid, all, global, or empty, search payload for branch hints
    if (!LocalStorageService.isValidBranchId(rawBranch)) {
      final dataBranch = (data['branchId'] ?? data['branch'] ?? '').toString().trim().toLowerCase();
      if (LocalStorageService.isValidBranchId(dataBranch)) {
        rawBranch = dataBranch;
      } else {
        // Try inferring from serial prefix (e.g. GRT-001 -> gujrat, SKT-001 -> sialkot)
        final serial = (action['serial'] ?? data['serial'] ?? '').toString().toUpperCase();
        if (serial.startsWith('GRT-') || serial.startsWith('GJT-')) {
          rawBranch = 'gujrat';
        } else if (serial.startsWith('SKT-')) {
          rawBranch = 'sialkot';
        } else if (serial.startsWith('JPJ-') || serial.startsWith('JALAL-')) {
          rawBranch = 'jalalpurjattan';
        } else if (serial.startsWith('RWP-')) {
          rawBranch = 'rawalpindi';
        } else {
          rawBranch = fallbackBranch ?? 'karachi';
        }
      }
      action['branchId'] = rawBranch;
      data['branchId'] = rawBranch;
      modified = true;
    }

    // ── 2. CAMP HEALING ────────────────────────────────────────────────────────
    // If the branch requires camps (like Karachi multi-camp or configured dynamic camps),
    // ensure campId is valid and not null
    final isDispensaryAction = rawType == 'save_entry' ||
        rawType == 'save_prescription' ||
        rawType == 'update_serial_status' ||
        rawType == 'update_inventory' ||
        rawType == 'save_dispensary_charge';

    if (isDispensaryAction) {
      String? campId = (action['campId'] ?? data['campId'] ?? data['dispensaryId'])?.toString().trim();
      final serial = (action['serial'] ?? data['serial'] ?? '').toString().toUpperCase();
      final tag = (data['dispensaryTag'] ?? '').toString().toUpperCase();

      if (campId == null || campId.isEmpty || campId == 'null' || campId == 'undefined') {
        if (CampSessionService.hasCampsForBranch(rawBranch)) {
          final camps = CampSessionService.getCampsForBranch(rawBranch, includeClosed: true);
          if (camps.isNotEmpty) {
            // Check if serial or tag matches any camp
            bool matched = false;
            for (final c in camps) {
              final cId = (c['id'] ?? '').toString();
              final cTag = (c['dispensaryTag'] ?? c['tag'] ?? '').toString().toUpperCase();
              if (cTag.isNotEmpty && (tag == cTag || serial.contains('-$cTag-') || serial.contains('-$cTag'))) {
                campId = cId;
                matched = true;
                break;
              }
            }
            if (!matched) {
              campId = (camps.first['id'] ?? 'main').toString();
            }
          } else {
            campId = 'main';
          }
        } else {
          campId = 'main';
        }
        action['campId'] = campId;
        data['campId'] = campId;
        modified = true;
      }
    }

    // ── 3. DATE KEY HEALING ───────────────────────────────────────────────────
    final rawDate = (action['dateKey'] ?? action['date'] ?? data['dateKey'] ?? data['date'])?.toString().trim();
    if (rawDate == null || rawDate.isEmpty || rawDate.length < 10) {
      final nowStr = DateTime.now().toIso8601String().substring(0, 10);
      action['dateKey'] = nowStr;
      data['dateKey'] = nowStr;
      modified = true;
    }

    // ── 4. STALE BACKOFF REPAIR ────────────────────────────────────────────────
    // If an item has been sitting with nextRetryAt far in the future or corrupted, clear it
    final nextRetryAtStr = action['nextRetryAt'] as String?;
    if (nextRetryAtStr != null) {
      final nextRetry = DateTime.tryParse(nextRetryAtStr);
      if (nextRetry != null && nextRetry.difference(DateTime.now()).inMinutes > 15) {
        action.remove('nextRetryAt');
        modified = true;
      }
    }

    // ── 5. TIMEOUT & RETRY RECOVERY ──────────────────────────────────────────
    // If an action was blocked due to a network timeout (e.g. TimeoutException after 8s),
    // reset attempts and clear lastError so it immediately gets retried with the 25s window.
    final lastErr = (action['lastError'] ?? '').toString();
    if (lastErr.contains('TimeoutException') || lastErr.contains('0:00:08')) {
      action['attempts'] = 0;
      action.remove('lastError');
      action.remove('nextRetryAt');
      modified = true;
    }

    if (modified) {
      action['data'] = data;
    }
    return modified;
  }

  /// Scans dead_letter_queue, fixes any issues, and re-injects items into sync_queue
  Future<int> _healAndReviveDeadLetters(String fallbackBranch, List<String> details) async {
    final dlBoxName = LocalStorageService.deadLetterQueueBox;
    int revivedCount = 0;
    try {
      if (!Hive.isBoxOpen(dlBoxName)) {
        await LocalStorageService.openBoxSafe(dlBoxName);
      }
      final dlBox = Hive.box(dlBoxName);
      if (dlBox.isEmpty) return 0;

      if (!Hive.isBoxOpen(LocalStorageService.syncBox)) {
        await LocalStorageService.openBoxSafe(LocalStorageService.syncBox);
      }
      final syncBox = Hive.box(LocalStorageService.syncBox);

      final dlKeys = dlBox.keys.toList();
      for (final key in dlKeys) {
        final raw = dlBox.get(key);
        if (raw == null || raw is! Map) {
          await dlBox.delete(key);
          continue;
        }

        final action = Map<String, dynamic>.from(raw);
        // Clean out dead-letter failure tags and reset attempt counter
        action.remove('deadLetteredAt');
        action.remove('deadLetterReason');
        action.remove('nextRetryAt');
        action.remove('lastError');
        action['attempts'] = 0;
        action['revivedAt'] = DateTime.now().toUtc().toIso8601String();

        // Run self-healing rules
        healAction(action, fallbackBranch: fallbackBranch);

        // Put back into active syncBox
        await syncBox.put(key, action);
        await dlBox.delete(key);
        revivedCount++;

        if (details.length < 25) {
          details.add('Revived dead-letter item $key (${action['type']})');
        }
      }

      if (revivedCount > 0) {
        debugPrint('[QueueSelfHealing] 🕊️ Revived $revivedCount items from dead-letter queue back to sync_queue');
      }
    } catch (e) {
      debugPrint('[QueueSelfHealing] Error reviving dead letters: $e');
    }
    return revivedCount;
  }
}
