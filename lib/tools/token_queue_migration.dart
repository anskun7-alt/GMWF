// lib/tools/token_queue_migration.dart

import 'package:flutter/foundation.dart';
import 'package:hive_flutter/hive_flutter.dart';
import '../services/local_storage_service.dart';
import '../services/camp_session_service.dart';

class TokenQueueMigration {
  /// Dry-run read-only audit: Scans patient records to detect CNIC collisions
  /// (e.g. adults and children incorrectly sharing the same CNIC without distinct child IDs).
  static Map<String, dynamic> auditAmbiguousChildRecords(String branchId) {
    if (!Hive.isBoxOpen(LocalStorageService.patientsBox)) {
      return {'error': 'local_patients box is not open'};
    }
    final pBox = Hive.box(LocalStorageService.patientsBox);
    final normBranch = branchId.toLowerCase().trim();

    final Map<String, List<Map<String, dynamic>>> cnicGroups = {};

    for (final raw in pBox.values) {
      if (raw is! Map) continue;
      final p = Map<String, dynamic>.from(raw);
      final bId = (p['branchId'] ?? '').toString().toLowerCase().trim();
      if (normBranch.isNotEmpty && normBranch != 'all' && bId.isNotEmpty && bId != normBranch) {
        continue;
      }

      final cnic = (p['cnic'] ?? p['guardianCnic'] ?? p['patientCnic'] ?? '')
          .toString()
          .replaceAll(RegExp(r'[^0-9]'), '');
      if (cnic.isEmpty) continue;

      cnicGroups.putIfAbsent(cnic, () => []).add(p);
    }

    final ambiguousCollisions = <Map<String, dynamic>>[];

    for (final entry in cnicGroups.entries) {
      final cnic = entry.key;
      final records = entry.value;

      if (records.length > 1) {
        final names = records
            .map((r) => (r['name'] ?? r['patientName'] ?? '').toString().trim().toLowerCase())
            .toSet();
        if (names.length > 1) {
          ambiguousCollisions.add({
            'cnic': cnic,
            'count': records.length,
            'records': records.map((r) => {
              'patientId': r['patientId'] ?? r['id'],
              'name': r['name'] ?? r['patientName'],
              'age': r['age'],
              'dob': r['dob']?.toString(),
              'isAdult': r['isAdult'],
              'guardianCnic': r['guardianCnic'],
            }).toList(),
          });
        }
      } else {
        final r = records.first;
        final age = (r['age'] is num)
            ? (r['age'] as num).toInt()
            : (int.tryParse(r['age']?.toString() ?? '') ?? 0);
        final isAdult = r['isAdult'];
        final guard = (r['guardianCnic'] ?? '').toString().trim();
        if (age > 0 && age < 18 && guard.isEmpty && isAdult != false) {
          ambiguousCollisions.add({
            'cnic': cnic,
            'type': 'unmarked_minor',
            'record': r,
          });
        }
      }
    }

    debugPrint('[TokenQueueMigration Audit] Branch: $branchId, Found ${ambiguousCollisions.length} ambiguous collision(s).');
    return {
      'branchId': branchId,
      'collisionCount': ambiguousCollisions.length,
      'collisions': ambiguousCollisions,
    };
  }

  /// Runs the full 3-step per-branch migration sequence safely:
  /// 1. Reverses corrupted dateKeys using the immutable serial prefix via restoreRealignedTokens
  /// 2. Corrects in-flight shift sessions and pushes updates to Firestore via repairMisassignedShiftSessions
  /// 3. Resolves individual child IDs and fixes missing isAdult flags via repairMissingPatientData
  static Future<Map<String, dynamic>> runMigrationForBranch(String branchId) async {
    final normBranch = branchId.toLowerCase().trim();
    debugPrint('[TokenQueueMigration] 🚀 Starting migration pass for branch: $normBranch');

    final results = <String, dynamic>{
      'branchId': normBranch,
      'timestamp': DateTime.now().toIso8601String(),
    };

    try {
      // Step 1: Restore accidentally realigned tokens back to original serial dateKeys
      final restoredCount = await CampSessionService.restoreRealignedTokens(branchId: normBranch);
      results['restoredRealignedTokens'] = restoredCount;
      debugPrint('[TokenQueueMigration] Step 1 Complete: Restored $restoredCount realigned token(s).');

      // Step 2: Repair in-flight waiting sessions with branch-aware config and Firestore sync
      await LocalStorageService.repairMisassignedShiftSessions(normBranch);
      results['shiftSessionsRepaired'] = true;
      debugPrint('[TokenQueueMigration] Step 2 Complete: In-flight shift sessions verified.');

      // Step 3: Repair patient IDs and missing child flags across boxes
      final patientRepairs = await LocalStorageService.repairMissingPatientData(branchId: normBranch);
      results['patientDataRepairs'] = patientRepairs;
      debugPrint('[TokenQueueMigration] Step 3 Complete: Patient records repaired: $patientRepairs');

      results['success'] = true;
    } catch (e, st) {
      debugPrint('[TokenQueueMigration] ❌ Error during migration: $e\n$st');
      results['success'] = false;
      results['error'] = e.toString();
    }

    return results;
  }
}
