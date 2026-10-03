import 'package:flutter/foundation.dart';
import 'package:hive_flutter/hive_flutter.dart';

class QuotaService {
  static final QuotaService _instance = QuotaService._internal();
  factory QuotaService() => _instance;
  QuotaService._internal();

  static final ValueNotifier<bool> isQuotaExhaustedNotifier = ValueNotifier<bool>(false);
  static final ValueNotifier<String?> quotaExhaustedReasonNotifier = ValueNotifier<String?>(null);
  static final ValueNotifier<DateTime?> quotaExhaustedTimestampNotifier = ValueNotifier<DateTime?>(null);

  static bool get isQuotaExhausted => isQuotaExhaustedNotifier.value;

  // ── Daily Write Counter ──────────────────────────────────────────────────
  // Raised ceiling to accommodate multi-branch operations and massive backlog flushes.
  static const int _dailyWriteCeiling = 200000;
  static const String _writeCountKey = 'quota_daily_writes';
  static const String _writeDateKey = 'quota_daily_date';
  static const String _quotaPausedUntilKey = 'quota_paused_until';

  /// Returns true if a write operation is allowed. Records the write.
  /// Call this BEFORE every Firestore write in SyncService.
  /// If [isPriority] is true (e.g. Tokens, Donations, Madrassa, Employees), writes proceed even during soft pauses.
  static bool canWrite({int count = 1, bool isPriority = false}) {
    try {
      if (isPriority) {
        // Priority business writes are never blocked by soft exhaustion or pauses
        return true;
      }

      if (isQuotaExhausted) return false;

      // Check if paused due to a quota error backoff
      final pausedUntilStr = _getFlag(_quotaPausedUntilKey);
      if (pausedUntilStr != null) {
        final pausedUntil = DateTime.tryParse(pausedUntilStr);
        if (pausedUntil != null && DateTime.now().isBefore(pausedUntil)) {
          return false;
        }
        // Backoff expired, clear pause
        _setFlag(_quotaPausedUntilKey, null);
      }

      final today = DateTime.now().toIso8601String().substring(0, 10);
      final storedDate = _getFlag(_writeDateKey);

      // Daily reset: if the stored date is not today, reset the counter
      if (storedDate != today) {
        _setFlag(_writeDateKey, today);
        _setFlag(_writeCountKey, '0');
        // Also auto-recover quota exhaustion on a new day
        if (isQuotaExhausted) {
          recordSuccess();
        }
      }

      final current = int.tryParse(_getFlag(_writeCountKey) ?? '0') ?? 0;
      if (current + count > _dailyWriteCeiling) {
        recordQuotaExceeded(reason: 'Daily write ceiling reached ($current/$_dailyWriteCeiling)');
        return false;
      }

      // Record the writes
      _setFlag(_writeCountKey, '${current + count}');
      return true;
    } catch (e) {
      debugPrint('[QuotaService] canWrite error: $e');
      return true; // Fail-open: allow writes if quota tracking itself fails
    }
  }

  /// Get current daily write count for monitoring
  static int get dailyWriteCount {
    try {
      final today = DateTime.now().toIso8601String().substring(0, 10);
      final storedDate = _getFlag(_writeDateKey);
      if (storedDate != today) return 0;
      return int.tryParse(_getFlag(_writeCountKey) ?? '0') ?? 0;
    } catch (_) {
      return 0;
    }
  }

  /// Pause uploads for a specified duration (used on quota errors)
  static void pauseForDuration(Duration duration) {
    final until = DateTime.now().add(duration);
    _setFlag(_quotaPausedUntilKey, until.toIso8601String());
    debugPrint('[QuotaService] ⏸️ Uploads paused until ${until.toIso8601String()}');
  }

  /// Check if an exception/error is a Firebase quota exhaustion error
  static bool isQuotaError(dynamic error) {
    if (error == null) return false;
    final errStr = error.toString().toLowerCase();
    return errStr.contains('resource-exhausted') ||
        errStr.contains('quota-exceeded') ||
        errStr.contains('resource_exhausted') ||
        errStr.contains('quota exceeded') ||
        errStr.contains('over quota') ||
        errStr.contains('quota limit') ||
        errStr.contains('usage limit');
  }

  /// Record that quota has been exceeded
  static void recordQuotaExceeded({String? reason, dynamic error}) {
    final effectiveReason = reason ?? (error != null ? error.toString() : 'Firebase Cloud Daily Quota Exceeded (50,000 Reads Limit Reached)');
    isQuotaExhaustedNotifier.value = true;
    quotaExhaustedReasonNotifier.value = effectiveReason;
    quotaExhaustedTimestampNotifier.value = DateTime.now();
    debugPrint('🚨 [QuotaService] Cloud Quota Exhaustion Detected: $effectiveReason');
  }

  /// Record a successful cloud operation to recover state after midnight reset
  static void recordSuccess() {
    if (isQuotaExhaustedNotifier.value) {
      final lastExhausted = quotaExhaustedTimestampNotifier.value;
      if (lastExhausted == null || DateTime.now().difference(lastExhausted).inMinutes > 15) {
        isQuotaExhaustedNotifier.value = false;
        quotaExhaustedReasonNotifier.value = null;
        debugPrint('✅ [QuotaService] Firestore connection restored / quota reset.');
      }
    }
  }

  /// Reset manual override (for admin testing/recovery)
  static void resetState() {
    isQuotaExhaustedNotifier.value = false;
    quotaExhaustedReasonNotifier.value = null;
    quotaExhaustedTimestampNotifier.value = null;
    _setFlag(_quotaPausedUntilKey, null);
  }

  // ── Hive helpers ─────────────────────────────────────────────────────────
  static String? _getFlag(String key) {
    try {
      if (!Hive.isBoxOpen('app_flags')) return null;
      return Hive.box('app_flags').get(key)?.toString();
    } catch (_) {
      return null;
    }
  }

  static void _setFlag(String key, String? value) {
    try {
      if (!Hive.isBoxOpen('app_flags')) return;
      if (value == null) {
        Hive.box('app_flags').delete(key);
      } else {
        Hive.box('app_flags').put(key, value);
      }
    } catch (_) {}
  }
}
