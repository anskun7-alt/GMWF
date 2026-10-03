import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:hive/hive.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../constants/navigator_key.dart';
import '../widgets/app_feedback.dart';
import '../widgets/queue_doctor_dialog.dart';
import 'local_storage_service.dart';
import 'python_runner_service.dart';
import 'sync_service.dart';

class HiddenForceUploader {
  HiddenForceUploader._();
  static final HiddenForceUploader instance = HiddenForceUploader._();

  bool _isUploading = false;
  bool get isUploading => _isUploading;

  void _notify(void Function(BuildContext ctx) callback) {
    final ctx = navigatorKey.currentContext;
    if (ctx != null && ctx.mounted) {
      callback(ctx);
    }
  }

  /// Triggered via Ctrl+Shift+U or Auto-Heal & Flush.
  /// Exports all pending records, runs the fast Python Firestore Admin SDK uploader,
  /// displays real-time start and completion notifications, and updates local cache.
  Future<void> runSilentForceUpload() async {
    if (_isUploading) {
      _notify((ctx) {
        AppFeedback.showWarning(
          ctx,
          'Force Upload in Progress',
          subtitle: 'Cloud sync is actively committing batches. Please wait...',
          duration: const Duration(seconds: 3),
        );
      });
      return;
    }
    _isUploading = true;

    try {
      if (!Hive.isBoxOpen(LocalStorageService.syncBox)) {
        await Hive.openBox(LocalStorageService.syncBox);
      }
      final queueBox = Hive.box(LocalStorageService.syncBox);
      final totalPending = queueBox.length;

      // If the queue is already empty
      if (totalPending == 0) {
        _notify((ctx) {
          AppFeedback.showSuccess(
            ctx,
            'Sync Queue Clean',
            subtitle: '0 pending items in local queue. All data is synchronized.',
            duration: const Duration(seconds: 3),
          );
        });
        unawaited(SyncService().triggerUpload(force: true));
        return;
      }

      // 1. Initial Notification: Let user know Ctrl+Shift+U was received and started!
      _notify((ctx) {
        AppFeedback.showInfo(
          ctx,
          'Force Upload Started (Ctrl+Shift+U)',
          subtitle: 'Exporting $totalPending records to high-speed cloud engine...',
          duration: const Duration(seconds: 4),
        );
      });

      // 2. Export pending items into temporary JSON
      final items = <Map<String, dynamic>>[];
      for (final key in queueBox.keys) {
        final val = queueBox.get(key);
        if (val is Map) {
          final itemMap = Map<String, dynamic>.from(val);
          itemMap['_queueKey'] = key.toString();
          if (itemMap['data'] is Map) {
            itemMap['data'] = Map<String, dynamic>.from(itemMap['data'] as Map);
          }
          items.add(itemMap);
        }
      }

      final appDir = await getApplicationSupportDirectory();
      final exportFile = File(p.join(appDir.path, '.hidden_queue_export.json'));
      final syncedKeysFile = File(p.join(appDir.path, '.hidden_synced_keys.json'));

      if (await syncedKeysFile.exists()) {
        try {
          await syncedKeysFile.delete();
        } catch (_) {}
      }

      await exportFile.writeAsString(jsonEncode(items), flush: true);

      // 3. Discover Python interpreter & scripts
      final pythonExe = await PythonRunnerService.instance.resolvePythonExecutable();
      final scriptsDir = await PythonRunnerService.instance.resolveScriptsDirectory();

      final scriptCandidates = [
        p.join(scriptsDir, 'hidden_cloud_sync.py'),
        p.join(Directory.current.path, 'scripts', 'hidden_cloud_sync.py'),
        r'E:\GMWF\gmwf\scripts\hidden_cloud_sync.py',
      ];

      String? targetScript;
      for (final cand in scriptCandidates) {
        if (await File(cand).exists()) {
          targetScript = cand;
          break;
        }
      }

      final credsCandidates = [
        p.join(scriptsDir, 'serviceAccountKey.json'),
        p.join(Directory.current.path, 'scripts', 'serviceAccountKey.json'),
        r'E:\GMWF\gmwf\scripts\serviceAccountKey.json',
      ];

      String? targetCreds;
      for (final cand in credsCandidates) {
        if (await File(cand).exists()) {
          targetCreds = cand;
          break;
        }
      }

      if (pythonExe == null || targetScript == null || targetCreds == null) {
        _notify((ctx) {
          AppFeedback.showError(
            ctx,
            'Python Engine Missing',
            subtitle: 'Could not find python.exe or serviceAccountKey.json. Running standard sync.',
          );
        });
        unawaited(SyncService().triggerUpload(force: true));
        return;
      }

      // 4. Run Python process
      final result = await Process.run(
        pythonExe,
        [
          targetScript,
          '--export',
          exportFile.path,
          '--creds',
          targetCreds,
          '--out',
          syncedKeysFile.path,
        ],
      );

      debugPrint('[HiddenForceUploader] Python exit code: ${result.exitCode}');

      // 5. Parse result and purge synced items from sync_queue Hive box
      int committedCount = 0;
      Map<String, dynamic> breakdown = {};
      double durationSec = 0.0;

      if (await syncedKeysFile.exists()) {
        try {
          final content = await syncedKeysFile.readAsString();
          final parsed = jsonDecode(content);
          List<dynamic> keysToDelete = [];

          if (parsed is List) {
            keysToDelete = parsed;
            committedCount = parsed.length;
          } else if (parsed is Map) {
            keysToDelete = (parsed['syncedKeys'] as List<dynamic>?) ?? [];
            committedCount = (parsed['totalCommitted'] as int?) ?? keysToDelete.length;
            breakdown = (parsed['breakdown'] as Map<String, dynamic>?) ?? {};
            durationSec = (parsed['durationSeconds'] as num?)?.toDouble() ?? 0.0;
          }

          for (final k in keysToDelete) {
            await queueBox.delete(k);
            if (int.tryParse(k.toString()) != null) {
              await queueBox.delete(int.parse(k.toString()));
            }
          }
          await queueBox.flush();
        } catch (e) {
          debugPrint('[HiddenForceUploader] Key purge error: $e');
        }
      }

      // Cleanup temp files
      try {
        if (await exportFile.exists()) await exportFile.delete();
        if (await syncedKeysFile.exists()) await syncedKeysFile.delete();
      } catch (_) {}

      // 6. Display Completion Summary Toast
      final remaining = queueBox.length;

      if (committedCount > 0) {
        final pCount = breakdown['patients'] ?? 0;
        final dCount = (breakdown['patient_deletes'] ?? 0) + (breakdown['dispensary_deletes'] ?? 0) + (breakdown['prescription_deletes'] ?? 0);
        final mCount = breakdown['madrassa'] ?? 0;
        final aCount = breakdown['attendance'] ?? 0;

        final summaryParts = <String>[];
        if (pCount > 0) summaryParts.add('Patients: $pCount');
        if (dCount > 0) summaryParts.add('Deletions: $dCount');
        if (mCount > 0) summaryParts.add('Madrassa: $mCount');
        if (aCount > 0) summaryParts.add('Attendance: $aCount');
        if (summaryParts.isEmpty) summaryParts.add('Records: $committedCount');
        if (durationSec > 0) summaryParts.add('${durationSec}s');

        _notify((ctx) {
          AppFeedback.showSuccess(
            ctx,
            'Force Upload Complete ($committedCount items uploaded)',
            subtitle: '${summaryParts.join(' • ')} • Remaining: $remaining',
            duration: const Duration(seconds: 6),
            actionLabel: 'Details',
            onAction: () => QueueDoctorDialog.show(ctx),
          );
        });
      } else if (result.exitCode != 0) {
        final errText = result.stderr.toString().isNotEmpty
            ? result.stderr.toString().trim().split('\n').last
            : 'Upload encountered an issue. Inspect details in Queue Doctor.';
        _notify((ctx) {
          AppFeedback.showError(
            ctx,
            'Force Upload Exited (${result.exitCode})',
            subtitle: errText,
            duration: const Duration(seconds: 6),
            actionLabel: 'Doctor',
            onAction: () => QueueDoctorDialog.show(ctx),
          );
        });
      } else {
        _notify((ctx) {
          AppFeedback.showInfo(
            ctx,
            'Force Upload Finished',
            subtitle: 'Queue remaining: $remaining items.',
            duration: const Duration(seconds: 4),
            actionLabel: 'Doctor',
            onAction: () => QueueDoctorDialog.show(ctx),
          );
        });
      }

      // 7. Trigger Dart sync pass to refresh local markers
      unawaited(SyncService().triggerUpload(force: true));
    } catch (e) {
      debugPrint('[HiddenForceUploader] Exception: $e');
      _notify((ctx) {
        AppFeedback.showError(
          ctx,
          'Force Upload Error',
          subtitle: e.toString(),
          duration: const Duration(seconds: 5),
          actionLabel: 'Doctor',
          onAction: () => QueueDoctorDialog.show(ctx),
        );
      });
      unawaited(SyncService().triggerUpload(force: true));
    } finally {
      _isUploading = false;
    }
  }
}
