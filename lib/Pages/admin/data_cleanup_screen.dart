import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:intl/intl.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:gmwf/services/local_storage_service.dart';
import 'package:gmwf/services/sync_service.dart';
import 'package:gmwf/tools/firestore_structure_sanitizer.dart';
import '../../constants/colors.dart';

class DataCleanupScreen extends StatefulWidget {
  const DataCleanupScreen({super.key});

  @override
  State<DataCleanupScreen> createState() => _DataCleanupScreenState();
}

class _LocalDocItem {
  final String id;
  final String path;
  final Map<String, dynamic> _data;

  _LocalDocItem({
    required this.id,
    required this.path,
    required Map<String, dynamic> data,
  }) : _data = data;

  Map<String, dynamic> data() => _data;
  _LocalDocRef get reference => _LocalDocRef(path);
}

class _LocalDocRef {
  final String path;
  _LocalDocRef(this.path);
  Future<void> delete() async {}
}

class _DataCleanupScreenState extends State<DataCleanupScreen> {
  final FirebaseFirestore _fs = FirebaseFirestore.instance;
  bool _isProcessing = false;
  List<String> _logs = [];
  double _progress = 0.0;
  String _currentBranch = "";

  // Cache operating dates during a cleanup run to avoid redundant Firestore gets
  final Map<String, List<String>> _serialsDatesCache = {};
  final Map<String, List<String>> _dispensaryDatesCache = {};

  // Interactive manual cleanup state
  int _activeTab = 0; // 0 = Child & Parent Conflicts, 1 = Manual Review, 2 = Prescriptions, 3 = Auto
  bool _isScanning = false;
  bool _hasScanned = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _scanChildParentConflicts();
    });
  }
  
  // Letter (A-Z, #) -> GroupKey (branchId_canonicalKey) -> List of duplicate documents
  Map<String, Map<String, List<_LocalDocItem>>> _duplicatesByLetter = {};
  String? _selectedLetter;
  // Selected master document ID for each duplicate group key
  final Map<String, String> _electedMasterIds = {};
  // Track which groups are currently being merged
  final Set<String> _mergingGroupKeys = {};
  // Track which groups have just been successfully merged
  final Set<String> _mergedGroupKeys = {};
  // Track which groups are animating out of the list
  final Set<String> _disappearingGroupKeys = {};

  // Prescription cleanup state
  bool _isScanningPrescriptions = false;
  bool _hasScannedPrescriptions = false;
  // Key -> details of each prescription document (status, docs, metadata)
  Map<String, Map<String, dynamic>> _prescriptionMigrationItems = {};
  // Track which prescription keys are currently being processed
  final Set<String> _processingPrescriptionKeys = {};

  Future<List<String>> _getSerialsDates(String branchId) async {
    if (_serialsDatesCache.containsKey(branchId)) {
      return _serialsDatesCache[branchId]!;
    }
    try {
      final snap = await _fs.collection('branches').doc(branchId).collection('serials').get();
      final dates = snap.docs.map((d) => d.id).toList();
      _serialsDatesCache[branchId] = dates;
      return dates;
    } catch (_) {
      return [];
    }
  }

  Future<List<String>> _getDispensaryDates(String branchId) async {
    if (_dispensaryDatesCache.containsKey(branchId)) {
      return _dispensaryDatesCache[branchId]!;
    }
    try {
      final snap = await _fs.collection('branches').doc(branchId).collection('dispensary').get();
      final dates = snap.docs.map((d) => d.id).toList();
      _dispensaryDatesCache[branchId] = dates;
      return dates;
    } catch (_) {
      return [];
    }
  }

  // Child-parent conflicts state
  bool _isScanningConflicts = false;
  bool _hasScannedConflicts = false;
  List<Map<String, dynamic>> _childParentConflicts = [];
  String _conflictFilter = 'all'; // 'all', 'raw_cnic', 'shared_cnic'
  final Set<String> _processingConflictKeys = {};

  Future<void> _scanChildParentConflicts() async {
    setState(() {
      _isScanningConflicts = true;
      _isProcessing = true;
      _log("🔍 Scanning local patient registry for child & parent CNIC conflicts...");
    });

    try {
      final conflicts = await LocalStorageService.findChildParentCnicConflicts(
        branchId: _currentBranch.isNotEmpty ? _currentBranch : null,
      );
      if (mounted) {
        setState(() {
          _childParentConflicts = conflicts;
          _hasScannedConflicts = true;
          _isScanningConflicts = false;
          _isProcessing = false;
        });
      }
      _log("✅ Scan complete: Found ${conflicts.length} child/parent conflict records.");
    } catch (e) {
      if (mounted) {
        setState(() {
          _isScanningConflicts = false;
          _isProcessing = false;
        });
      }
      _log("❌ Failed to scan child/parent conflicts: $e");
    }
  }

  Future<void> _deleteConflictRegistration(Map<String, dynamic> item) async {
    final hiveKey = (item['hiveKey'] ?? item['patientId']).toString();
    final name = (item['patientName'] ?? 'Patient').toString();
    setState(() => _processingConflictKeys.add(hiveKey));
    _log("🗑️ Removing corrupted registration for $name ($hiveKey) — preserving medical history...");

    try {
      await LocalStorageService.deletePatientRegistrationPreservingHistory(
        hiveKey,
        branchId: item['branchId']?.toString(),
        reason: 'Data Integrity: Child-parent CNIC conflict resolved',
      );

      if (mounted) {
        setState(() {
          _childParentConflicts.removeWhere((c) => c['hiveKey'] == hiveKey);
          _processingConflictKeys.remove(hiveKey);
        });
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text("✅ Removed registration for $name. Medical history preserved intact."),
          backgroundColor: const Color(0xFF0D9488),
        ));
      }
      _log("✨ Registration $hiveKey deleted locally and queued for background Firestore sync.");
    } catch (e) {
      if (mounted) setState(() => _processingConflictKeys.remove(hiveKey));
      _log("❌ Failed to delete registration $hiveKey: $e");
    }
  }

  Future<void> _migrateConflictToChildId(Map<String, dynamic> item) async {
    final hiveKey = (item['hiveKey'] ?? item['patientId']).toString();
    final name = (item['patientName'] ?? 'Patient').toString();
    setState(() => _processingConflictKeys.add(hiveKey));
    _log("🔄 Migrating $name ($hiveKey) to canonical child ID...");

    try {
      final newId = await LocalStorageService.autoMigrateChildToCanonicalId(
        hiveKey,
        branchId: item['branchId']?.toString(),
      );

      if (mounted) {
        setState(() {
          _childParentConflicts.removeWhere((c) => c['hiveKey'] == hiveKey);
          _processingConflictKeys.remove(hiveKey);
        });
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text("✅ Migrated $name to canonical ID: $newId"),
          backgroundColor: const Color(0xFF10B981),
        ));
      }
      _log("✨ Migrated $hiveKey to $newId and scheduled background sync.");
    } catch (e) {
      if (mounted) setState(() => _processingConflictKeys.remove(hiveKey));
      _log("❌ Failed to migrate $hiveKey: $e");
    }
  }

  Future<void> _batchDeleteAllConflicts() async {
    if (_childParentConflicts.isEmpty) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text("Delete Conflicted Registrations?"),
        content: Text(
          "This will remove ${_childParentConflicts.length} corrupted patient registration(s) from the patient list.\n\n"
          "✅ ALL clinical visit history, prescriptions, and dispensary logs will remain 100% intact.",
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text("Cancel")),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: ElevatedButton.styleFrom(backgroundColor: Colors.redAccent, foregroundColor: Colors.white),
            child: const Text("Delete Registrations"),
          ),
        ],
      ),
    );

    if (confirmed != true) return;

    setState(() => _isProcessing = true);
    int count = 0;
    final list = List<Map<String, dynamic>>.from(_childParentConflicts);

    for (final item in list) {
      final hiveKey = (item['hiveKey'] ?? item['patientId']).toString();
      try {
        await LocalStorageService.deletePatientRegistrationPreservingHistory(
          hiveKey,
          branchId: item['branchId']?.toString(),
          reason: 'Batch conflict resolution',
        );
        count++;
      } catch (_) {}
    }

    if (mounted) {
      setState(() {
        _childParentConflicts.clear();
        _isProcessing = false;
      });
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text("✅ Cleaned $count patient registrations. Medical history preserved."),
        backgroundColor: const Color(0xFF0D9488),
      ));
    }
    _log("✨ Batch clean complete: Deleted $count corrupted registrations, medical history intact.");
  }

  Future<void> _batchMigrateAllConflicts() async {
    if (_childParentConflicts.isEmpty) return;
    setState(() => _isProcessing = true);
    int count = 0;
    final list = List<Map<String, dynamic>>.from(_childParentConflicts);

    for (final item in list) {
      final hiveKey = (item['hiveKey'] ?? item['patientId']).toString();
      try {
        await LocalStorageService.autoMigrateChildToCanonicalId(
          hiveKey,
          branchId: item['branchId']?.toString(),
        );
        count++;
      } catch (_) {}
    }

    if (mounted) {
      setState(() {
        _childParentConflicts.clear();
        _isProcessing = false;
      });
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text("✅ Migrated $count records to canonical child IDs."),
        backgroundColor: const Color(0xFF10B981),
      ));
    }
    _log("✨ Batch migration complete: Converted $count child records to canonical format.");
  }

  Future<void> _formatAllPatientCnics() async {
    setState(() {
      _isProcessing = true;
      _log("🔄 Formatting all 13-digit raw CNICs into standard xxxxx-xxxxxxx-x format...");
    });
    try {
      final count = await LocalStorageService.formatAllRawCnics(
        branchId: _currentBranch.isNotEmpty ? _currentBranch : null,
      );
      if (mounted) {
        setState(() => _isProcessing = false);
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(count > 0
              ? "✅ Updated $count patient(s) with formatted CNIC (xxxxx-xxxxxxx-x). Queued for background sync."
              : "✅ All patient CNICs are already properly formatted (xxxxx-xxxxxxx-x)."),
          backgroundColor: const Color(0xFF0D9488),
        ));
      }
      _log("✨ Completed CNIC formatting: $count records updated to xxxxx-xxxxxxx-x and queued for sync.");
    } catch (e) {
      if (mounted) setState(() => _isProcessing = false);
      _log("❌ Failed to format patient CNICs: $e");
    }
  }

  // ─── Logging ────────────────────────────────────────────────────────────────

  void _log(String msg) {
    if (mounted) {
      setState(() => _logs.insert(0, msg));
    }
  }

  // ─── Schema Auto-Heal & Backfill with Interactive Preview ──────────────────

  Future<void> _scanAndPreviewPatientRepairs() async {
    setState(() {
      _isProcessing = true;
      _logs = ["🔍 Scanning local Hive & database for patient schema anomalies..."];
      _progress = 0.0;
    });

    final previewItems = <_PatientRepairPreviewItem>[];

    try {
      // 1. Scan Local Hive patientsBox
      if (Hive.isBoxOpen(LocalStorageService.patientsBox)) {
        final pBox = Hive.box(LocalStorageService.patientsBox);
        for (final k in pBox.keys) {
          final raw = pBox.get(k);
          if (raw is Map) {
            final pMap = Map<String, dynamic>.from(raw);
            final resolvedId = LocalStorageService.resolveIndividualPatientId(pMap);
            final currentId = (pMap['patientId'] ?? pMap['id'] ?? '').toString().trim();
            final guard = (pMap['guardianCnic'] ?? '').toString().trim();
            final name = (pMap['patientName'] ?? pMap['name'] ?? pMap['fullName'] ?? '').toString().trim();
            final proposedIsAdult = guard.isEmpty && !resolvedId.contains('_child_');
            final currentIsAdult = pMap['isAdult'];
            final rawCnic = (pMap['cnic'] ?? pMap['patientCnic'] ?? '').toString().trim();
            final isRaw13Cnic = RegExp(r'^\d{13}$').hasMatch(rawCnic);
            final isRaw13Guard = RegExp(r'^\d{13}$').hasMatch(guard);
            final formattedCnic = isRaw13Cnic
                ? '${rawCnic.substring(0, 5)}-${rawCnic.substring(5, 12)}-${rawCnic.substring(12, 13)}'
                : rawCnic;
            final formattedGuard = isRaw13Guard
                ? '${guard.substring(0, 5)}-${guard.substring(5, 12)}-${guard.substring(12, 13)}'
                : guard;

            bool needsRepair = false;
            if (resolvedId.isNotEmpty && (currentId.isEmpty || currentId != resolvedId)) needsRepair = true;
            if (currentIsAdult == null) needsRepair = true;
            if (pMap['patientName'] == null && name.isNotEmpty) needsRepair = true;
            if (isRaw13Cnic || isRaw13Guard) needsRepair = true;

            if (needsRepair) {
              previewItems.add(_PatientRepairPreviewItem(
                key: k.toString(),
                branchId: (pMap['branchId'] ?? '').toString(),
                patientName: name.isNotEmpty ? name : 'Unknown Patient',
                cnic: formattedCnic.isNotEmpty ? formattedCnic : rawCnic,
                guardianCnic: formattedGuard.isNotEmpty ? formattedGuard : guard,
                currentPatientId: currentId.isNotEmpty ? currentId : '(Missing ID)',
                proposedPatientId: resolvedId,
                currentIsAdult: currentIsAdult,
                proposedIsAdult: proposedIsAdult,
                recordType: isRaw13Cnic ? 'Local Patient (Raw CNIC)' : 'Local Patient Profile',
                source: 'hive_patients',
                rawData: {
                  ...pMap,
                  if (isRaw13Cnic) 'cnic': formattedCnic,
                  if (isRaw13Guard) 'guardianCnic': formattedGuard,
                },
              ));
            }
          }
        }
      }

      // 2. Scan Local Hive entriesBox
      if (Hive.isBoxOpen(LocalStorageService.entriesBox)) {
        final eBox = Hive.box(LocalStorageService.entriesBox);
        for (final k in eBox.keys) {
          final raw = eBox.get(k);
          if (raw is Map) {
            final eMap = Map<String, dynamic>.from(raw);
            final resolvedId = LocalStorageService.resolveIndividualPatientId(eMap);
            final currentId = (eMap['patientId'] ?? eMap['id'] ?? '').toString().trim();
            final name = (eMap['patientName'] ?? eMap['name'] ?? eMap['fullName'] ?? '').toString().trim();
            final rawQueue = eMap['queueType'] ?? eMap['category'] ?? eMap['status'];
            final resolvedQueue = SyncService().resolveQueueType(rawQueue?.toString());
            final currentQueue = eMap['queueType']?.toString().trim();

            bool needsRepair = false;
            if (resolvedId.isNotEmpty && (currentId.isEmpty || currentId != resolvedId)) needsRepair = true;
            if (currentQueue == null || currentQueue.isEmpty || currentQueue != resolvedQueue) needsRepair = true;

            if (needsRepair) {
              previewItems.add(_PatientRepairPreviewItem(
                key: k.toString(),
                branchId: (eMap['branchId'] ?? '').toString(),
                patientName: name.isNotEmpty ? name : 'Unknown Patient',
                cnic: (eMap['patientCnic'] ?? eMap['cnic'] ?? '').toString(),
                guardianCnic: (eMap['guardianCnic'] ?? '').toString(),
                currentPatientId: currentId.isNotEmpty ? currentId : '(Missing ID)',
                proposedPatientId: resolvedId.isNotEmpty ? resolvedId : currentId,
                currentIsAdult: eMap['isAdult'],
                proposedIsAdult: resolvedId.contains('_child_') ? false : true,
                recordType: 'Token Queue Entry (${eMap['serial'] ?? k}) [$resolvedQueue]',
                source: 'hive_entries',
                rawData: {...eMap, 'queueType': resolvedQueue},
              ));
            }
          }
        }
      }

      _log("✅ Scan complete: Found ${previewItems.length} records requiring repair.");
    } catch (e) {
      _log("❌ Error during diagnostic scan: $e");
    } finally {
      if (mounted) {
        setState(() {
          _isProcessing = false;
          _progress = 1.0;
        });

        if (previewItems.isEmpty) {
          showDialog(
            context: context,
            builder: (ctx) => AlertDialog(
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
              title: const Row(
                children: [
                  Icon(Icons.check_circle_rounded, color: Colors.green, size: 28),
                  SizedBox(width: 10),
                  Text("All Records Clean"),
                ],
              ),
              content: const Text(
                "All local patient profiles, token entries, and prescriptions have valid individual Patient IDs and schema flags.\n\nNo repair action is needed.",
                style: TextStyle(fontSize: 14, height: 1.4),
              ),
              actions: [
                ElevatedButton(
                  onPressed: () => Navigator.pop(ctx),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppColors.primary,
                    foregroundColor: Colors.white,
                  ),
                  child: const Text("OK"),
                ),
              ],
            ),
          );
        } else {
          _showPatientRepairPreviewDialog(previewItems);
        }
      }
    }
  }

  void _showPatientRepairPreviewDialog(List<_PatientRepairPreviewItem> items) {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) {
        return _PatientRepairPreviewModal(
          initialItems: items,
          onApplyFixes: (selectedItems) async {
            Navigator.pop(ctx);
            await _executeSelectedPatientRepairs(selectedItems);
          },
        );
      },
    );
  }

  Future<void> _executeSelectedPatientRepairs(List<_PatientRepairPreviewItem> selectedItems) async {
    setState(() {
      _isProcessing = true;
      _logs = ["🚀 Applying fixes to ${selectedItems.length} selected records..."];
      _progress = 0.0;
    });

    int fixedLocal = 0;
    try {
      final pBox = Hive.isBoxOpen(LocalStorageService.patientsBox) ? Hive.box(LocalStorageService.patientsBox) : null;
      final eBox = Hive.isBoxOpen(LocalStorageService.entriesBox) ? Hive.box(LocalStorageService.entriesBox) : null;
      final prBox = Hive.isBoxOpen(LocalStorageService.prescriptionsBox) ? Hive.box(LocalStorageService.prescriptionsBox) : null;

      for (int i = 0; i < selectedItems.length; i++) {
        final item = selectedItems[i];
        final updatedData = Map<String, dynamic>.from(item.rawData);
        updatedData['patientId'] = item.proposedPatientId;
        updatedData['id'] = item.proposedPatientId;
        updatedData['isAdult'] = item.proposedIsAdult;
        if (item.patientName.isNotEmpty && item.patientName != 'Unknown Patient') {
          updatedData['patientName'] = item.patientName;
          updatedData['name'] = item.patientName;
        }

        final rawCnic = (updatedData['cnic'] ?? updatedData['patientCnic'])?.toString().trim();
        if (rawCnic != null && RegExp(r'^\d{13}$').hasMatch(rawCnic)) {
          final formatted = '${rawCnic.substring(0, 5)}-${rawCnic.substring(5, 12)}-${rawCnic.substring(12, 13)}';
          updatedData['cnic'] = formatted;
          if (updatedData.containsKey('patientCnic')) {
            updatedData['patientCnic'] = formatted;
          }
        }
        final rawGuard = updatedData['guardianCnic']?.toString().trim();
        if (rawGuard != null && RegExp(r'^\d{13}$').hasMatch(rawGuard)) {
          updatedData['guardianCnic'] = '${rawGuard.substring(0, 5)}-${rawGuard.substring(5, 12)}-${rawGuard.substring(12, 13)}';
        }

        final sanitized = LocalStorageService.sanitize(updatedData);

        if (item.source == 'hive_patients' && pBox != null) {
          await pBox.put(item.key, sanitized);
          if (item.proposedPatientId.isNotEmpty && item.key != item.proposedPatientId) {
            await pBox.put(item.proposedPatientId, sanitized);
          }
          final bId = (item.branchId.isNotEmpty ? item.branchId : widget.key?.toString() ?? '').trim();
          if (bId.isNotEmpty) {
            await LocalStorageService.enqueueSync({
              'type': 'save_patient',
              'branchId': bId,
              'patientId': item.proposedPatientId,
              'data': sanitized,
            });
          }
          fixedLocal++;
        } else if (item.source == 'hive_entries' && eBox != null) {
          await eBox.put(item.key, sanitized);
          final bId = (item.branchId.isNotEmpty ? item.branchId : '').trim();
          final serial = (sanitized['serial'] ?? sanitized['id'] ?? '').toString().trim();
          if (bId.isNotEmpty && serial.isNotEmpty) {
            await LocalStorageService.enqueueSync({
              'type': 'save_entry',
              'branchId': bId,
              'serial': serial,
              'data': sanitized,
            });
          }
          fixedLocal++;
        } else if (item.source == 'hive_prescriptions' && prBox != null) {
          await prBox.put(item.key, sanitized);
          fixedLocal++;
        }

        setState(() {
          _progress = (i + 1) / selectedItems.length;
        });
      }

      _log("🎉 Successfully updated $fixedLocal local records! Enqueued changes for background sync.");
      Future.delayed(const Duration(milliseconds: 500), () {
        SyncService().triggerUpload();
      });
    } catch (e) {
      _log("❌ Error applying patient fixes: $e");
    } finally {
      if (mounted) {
        setState(() {
          _isProcessing = false;
          _progress = 1.0;
        });
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text("Successfully repaired $fixedLocal patient records and scheduled sync!"),
            backgroundColor: AppColors.primary,
          ),
        );
      }
    }
  }

  // ─── Serials ↔ Dispensary Reconciliation with Interactive Preview ─────────────

  Future<void> _scanAndPreviewSerialsDispensary() async {
    setState(() {
      _isProcessing = true;
      _logs = ["🔍 Scanning local Hive & database for all waiting serials & dispensary records..."];
      _progress = 0.0;
    });

    final previewItems = <_SerialsDispensaryPreviewItem>[];
    final seenSerials = <String>{};

    try {
      // 1. SCAN ALL LOCAL HIVE BOXES (entries, dispensary, prescriptions)
      _log("📦 Scanning local Hive cache (entries, dispensary, prescriptions)...");
      final eBox = Hive.isBoxOpen(LocalStorageService.entriesBox) ? Hive.box(LocalStorageService.entriesBox) : null;
      final dBox = Hive.isBoxOpen(LocalStorageService.dispensaryBox) ? Hive.box(LocalStorageService.dispensaryBox) : null;
      final prBox = Hive.isBoxOpen(LocalStorageService.prescriptionsBox) ? Hive.box(LocalStorageService.prescriptionsBox) : null;

      final localSerialMap = <String, Map<String, dynamic>>{};
      final localDispensaryMap = <String, Map<String, dynamic>>{};
      final localPrescriptionMap = <String, Map<String, dynamic>>{};

      if (eBox != null) {
        for (final raw in eBox.values) {
          if (raw is Map) {
            final data = Map<String, dynamic>.from(raw);
            final s = (data['serial'] ?? data['id'] ?? '').toString().trim().toUpperCase();
            final b = (data['branchId'] ?? '').toString().trim().toLowerCase();
            if (s.isNotEmpty) {
              final compKey = b.isNotEmpty ? '${b}_$s' : s;
              localSerialMap[compKey] = data;
              localSerialMap.putIfAbsent(s, () => data);
            }
          }
        }
      }

      if (dBox != null) {
        for (final raw in dBox.values) {
          if (raw is Map) {
            final data = Map<String, dynamic>.from(raw);
            final s = (data['serial'] ?? data['id'] ?? '').toString().trim().toUpperCase();
            final b = (data['branchId'] ?? '').toString().trim().toLowerCase();
            if (s.isNotEmpty) {
              final compKey = b.isNotEmpty ? '${b}_$s' : s;
              localDispensaryMap[compKey] = data;
              localDispensaryMap.putIfAbsent(s, () => data);
            }
          }
        }
      }

      if (prBox != null) {
        for (final raw in prBox.values) {
          if (raw is Map) {
            final data = Map<String, dynamic>.from(raw);
            final s = (data['serial'] ?? data['id'] ?? '').toString().trim().toUpperCase();
            final b = (data['branchId'] ?? '').toString().trim().toLowerCase();
            if (s.isNotEmpty) {
              final compKey = b.isNotEmpty ? '${b}_$s' : s;
              localPrescriptionMap[compKey] = data;
              localPrescriptionMap.putIfAbsent(s, () => data);
            }
          }
        }
      }

      // Collect all unique serial keys from local Hive across ALL branches
      final allLocalKeys = <String>{
        ...localSerialMap.keys.where((k) => k.contains('_')),
        ...localDispensaryMap.keys.where((k) => k.contains('_')),
        ...localPrescriptionMap.keys.where((k) => k.contains('_')),
      };
      for (final k in {...localSerialMap.keys, ...localDispensaryMap.keys, ...localPrescriptionMap.keys}) {
        if (!k.contains('_') && !allLocalKeys.any((ck) => ck.endsWith('_$k'))) {
          allLocalKeys.add(k);
        }
      }

      for (final sKey in allLocalKeys) {
        final serData = localSerialMap[sKey] ?? (sKey.contains('_') ? localSerialMap[sKey.split('_').last] : null);
        final dispData = localDispensaryMap[sKey] ?? (sKey.contains('_') ? localDispensaryMap[sKey.split('_').last] : null) ?? {};
        final prescData = localPrescriptionMap[sKey] ?? (sKey.contains('_') ? localPrescriptionMap[sKey.split('_').last] : null) ?? {};

        final cleanSerial = sKey.contains('_') ? sKey.split('_').last : sKey;
        final branch = (serData?['branchId'] ?? dispData['branchId'] ?? prescData['branchId'] ?? (sKey.contains('_') ? sKey.split('_').first : '')).toString();

        final sStatus = (serData?['dispenseStatus'] ?? serData?['status'] ?? 'waiting').toString().toLowerCase();
        final dStatus = (dispData['dispenseStatus'] ?? dispData['status'] ?? '').toString().toLowerCase();

        final pName = (serData?['patientName'] ?? dispData['patientName'] ?? dispData['name'] ?? prescData['patientName'] ?? 'Unknown Patient').toString();
        final date = (dispData['dateKey'] ?? serData?['dateKey'] ?? prescData['dateKey'] ?? '').toString();

        final rawQT = serData?['queueType'] ?? dispData['queueType'] ?? prescData['queueType'] ?? serData?['category'] ?? dispData['category'] ?? serData?['status'] ?? dispData['status'];
        final qType = SyncService().resolveQueueType(rawQT?.toString());
        final hasPrescription = dispData['prescription'] != null || dispData['medicines'] != null || prescData['medicines'] != null || prescData['prescription'] != null || serData?['prescription'] != null || serData?['medicines'] != null;

        // Include ALL serials that are in waiting status, or have prescription data, or have dispensary documents
        if (sStatus != 'dispensed' || hasPrescription || dispData.isNotEmpty) {
          seenSerials.add(sKey);
          previewItems.add(_SerialsDispensaryPreviewItem(
            serial: cleanSerial,
            branchId: branch,
            dateKey: date,
            patientName: pName,
            queueType: qType,
            currentStatus: sStatus,
            proposedStatus: 'dispensed',
            hasPrescriptionMerge: hasPrescription,
            hasMatchingSerial: serData != null,
            serialRef: null,
            dispensaryRef: null,
            dispensaryData: {
              ...dispData,
              'queueType': qType,
              if (prescData.isNotEmpty && dispData['prescription'] == null) 'prescription': prescData['prescription'] ?? prescData['medicines'],
              if (prescData.isNotEmpty && dispData['medicines'] == null) 'medicines': prescData['medicines'],
            },
            serialData: serData,
          ));
        }
      }

      _log("✨ Found ${previewItems.length} records in local Hive storage.");

      _log("✅ Local Hive scan complete: Found ${previewItems.length} records to reconcile (0 Cloud Reads used).");
    } catch (e) {
      _log("❌ Reconciliation scan failed: $e");
    } finally {
      if (mounted) {
        setState(() {
          _isProcessing = false;
          _progress = 1.0;
        });

        if (previewItems.isEmpty) {
          showDialog(
            context: context,
            builder: (ctx) => AlertDialog(
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
              title: const Row(
                children: [
                  Icon(Icons.check_circle_rounded, color: Colors.green, size: 28),
                  SizedBox(width: 10),
                  Text("Serials In Sync"),
                ],
              ),
              content: const Text(
                "All serials and dispensary records are completely in sync and marked as dispensed.\n\nNo reconciliation needed.",
                style: TextStyle(fontSize: 14, height: 1.4),
              ),
              actions: [
                ElevatedButton(
                  onPressed: () => Navigator.pop(ctx),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppColors.primary,
                    foregroundColor: Colors.white,
                  ),
                  child: const Text("OK"),
                ),
              ],
            ),
          );
        } else {
          _showSerialsDispensaryPreviewDialog(previewItems);
        }
      }
    }
  }

  void _showSerialsDispensaryPreviewDialog(List<_SerialsDispensaryPreviewItem> items) {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) {
        return _SerialsDispensaryPreviewModal(
          initialItems: items,
          onApplyFixes: (selectedItems) async {
            Navigator.pop(ctx);
            await _executeSelectedSerialsReconciliation(selectedItems);
          },
        );
      },
    );
  }

  Future<void> _executeSelectedSerialsReconciliation(List<_SerialsDispensaryPreviewItem> selectedItems) async {
    setState(() {
      _isProcessing = true;
      _logs = ["🚀 Reconciling & backfilling ${selectedItems.length} selected serial records..."];
      _progress = 0.0;
    });

    int mergedCount = 0;
    int deletedCount = 0;

    try {
      final eBox = Hive.isBoxOpen(LocalStorageService.entriesBox) ? Hive.box(LocalStorageService.entriesBox) : null;
      final dBox = Hive.isBoxOpen(LocalStorageService.dispensaryBox) ? Hive.box(LocalStorageService.dispensaryBox) : null;
      final prBox = Hive.isBoxOpen(LocalStorageService.prescriptionsBox) ? Hive.box(LocalStorageService.prescriptionsBox) : null;

      for (int i = 0; i < selectedItems.length; i++) {
        final item = selectedItems[i];
        final dispensaryData = Map<String, dynamic>.from(item.dispensaryData);

        // Also check if prescriptionsBox has additional clinical data for this serial
        if (prBox != null) {
          final pRaw = prBox.get(item.serial) ?? prBox.get(item.serial.toLowerCase()) ?? prBox.get(item.serial.toUpperCase());
          if (pRaw is Map) {
            final pMap = Map<String, dynamic>.from(pRaw);
            if (dispensaryData['prescription'] == null && pMap['prescription'] != null) dispensaryData['prescription'] = pMap['prescription'];
            if (dispensaryData['medicines'] == null && pMap['medicines'] != null) dispensaryData['medicines'] = pMap['medicines'];
            if (dispensaryData['doctorName'] == null && pMap['doctorName'] != null) dispensaryData['doctorName'] = pMap['doctorName'];
            if (dispensaryData['doctorId'] == null && pMap['doctorId'] != null) dispensaryData['doctorId'] = pMap['doctorId'];
            if (dispensaryData['daysOfMedicine'] == null && pMap['daysOfMedicine'] != null) dispensaryData['daysOfMedicine'] = pMap['daysOfMedicine'];
            if (dispensaryData['vitals'] == null && pMap['vitals'] != null) dispensaryData['vitals'] = pMap['vitals'];
          }
        }

        // 1. UPDATE / CREATE IN LOCAL HIVE ENTRIES BOX FIRST!
        String bId = (item.branchId.isNotEmpty && item.branchId != 'unknown')
            ? item.branchId
            : (dispensaryData['branchId']?.toString() ?? '');
        final qType = SyncService().resolveQueueType(
          dispensaryData['queueType']?.toString() ??
          item.queueType
        );

        if (eBox != null) {
          final sUpper = item.serial.toUpperCase();
          final sLower = item.serial.toLowerCase();
          final canonicalEntryKey = bId.isNotEmpty ? '${bId.toLowerCase()}-${item.serial}' : item.serial;
          final rawEntry = eBox.get(canonicalEntryKey) ?? eBox.get(sUpper) ?? eBox.get(sLower) ?? eBox.get(item.serial);
          final updatedEntry = rawEntry != null && rawEntry is Map ? Map<String, dynamic>.from(rawEntry) : <String, dynamic>{};

          if (bId.isEmpty && rawEntry is Map && rawEntry['branchId'] != null) {
            bId = rawEntry['branchId'].toString();
          }
          if (bId.isEmpty) {
            final localBranches = LocalStorageService.getLocalBranchesList();
            bId = localBranches.isNotEmpty ? (localBranches.first['id'] ?? 'default').toString() : 'default';
          }

          updatedEntry['serial'] = item.serial;
          updatedEntry['id'] = item.serial;
          updatedEntry['queueType'] = qType;
          updatedEntry['branchId'] = bId;
          if (item.dateKey.isNotEmpty) updatedEntry['dateKey'] = item.dateKey;
          if (item.patientName.isNotEmpty && item.patientName != 'Unknown Patient') updatedEntry['patientName'] = item.patientName;
          
          updatedEntry['dispenseStatus'] = 'dispensed';
          updatedEntry['status'] = 'completed';
          
          final prescObj = dispensaryData['prescription'] is Map
              ? Map<String, dynamic>.from(dispensaryData['prescription'] as Map)
              : null;

          if (prescObj != null) {
            updatedEntry['prescription'] = prescObj;
            if (prescObj['diagnosis'] != null) updatedEntry['diagnosis'] = prescObj['diagnosis'];
            if (prescObj['complaint'] != null) updatedEntry['complaint'] = prescObj['complaint'];
            if (prescObj['condition'] != null) updatedEntry['condition'] = prescObj['condition'];
            if (prescObj['doctorName'] != null) {
              updatedEntry['doctorName'] = prescObj['doctorName'];
              updatedEntry['prescribedBy'] ??= prescObj['doctorName'];
            }
            if (prescObj['doctorId'] != null) updatedEntry['doctorId'] = prescObj['doctorId'];
            if (prescObj['daysOfMedicine'] != null) updatedEntry['daysOfMedicine'] = prescObj['daysOfMedicine'];
            if (prescObj['extraCharge'] != null) updatedEntry['extraCharge'] = prescObj['extraCharge'];
            if (prescObj['vitals'] != null) updatedEntry['vitals'] = prescObj['vitals'];
            if (prescObj['labResults'] != null) updatedEntry['labResults'] = prescObj['labResults'];
            final pMeds = prescObj['prescriptions'] ?? prescObj['medicines'];
            if (pMeds != null) {
              updatedEntry['medicines'] = pMeds;
              updatedEntry['prescriptions'] ??= pMeds;
            }
          } else if (dispensaryData['prescription'] != null) {
            updatedEntry['prescription'] = dispensaryData['prescription'];
          }

          if (dispensaryData['medicines'] != null) {
            updatedEntry['medicines'] = dispensaryData['medicines'];
            updatedEntry['prescriptions'] ??= dispensaryData['medicines'];
          }
          if (dispensaryData['doctorName'] != null) {
            updatedEntry['doctorName'] = dispensaryData['doctorName'];
            updatedEntry['prescribedBy'] ??= dispensaryData['doctorName'];
          }
          if (dispensaryData['doctorId'] != null) updatedEntry['doctorId'] = dispensaryData['doctorId'];
          if (dispensaryData['daysOfMedicine'] != null) updatedEntry['daysOfMedicine'] = dispensaryData['daysOfMedicine'];
          if (dispensaryData['vitals'] != null) updatedEntry['vitals'] = dispensaryData['vitals'];
          if (dispensaryData['charges'] != null) updatedEntry['charges'] = dispensaryData['charges'];
          if (dispensaryData['receivedAmount'] != null) updatedEntry['receivedAmount'] = dispensaryData['receivedAmount'];
          if (dispensaryData['extraCharge'] != null) updatedEntry['extraCharge'] = dispensaryData['extraCharge'];
          if (dispensaryData['dispensedAt'] != null) updatedEntry['dispensedAt'] = dispensaryData['dispensedAt'];
          if (dispensaryData['dispensedBy'] != null) updatedEntry['dispensedBy'] = dispensaryData['dispensedBy'];
          if (dispensaryData['dispenserName'] != null) updatedEntry['dispenserName'] = dispensaryData['dispenserName'];
          if (dispensaryData['diagnosis'] != null) updatedEntry['diagnosis'] = dispensaryData['diagnosis'];
          if (dispensaryData['complaint'] != null) {
            updatedEntry['complaint'] = dispensaryData['complaint'];
            updatedEntry['condition'] ??= dispensaryData['complaint'];
          }

          final sanitized = LocalStorageService.sanitize(updatedEntry);
          await eBox.put(canonicalEntryKey, sanitized);
          await eBox.put(sUpper, sanitized);
          await eBox.put(sLower, sanitized);

          // 2. Enqueue Sync for serial entry
          await LocalStorageService.enqueueSync({
            'type': 'save_entry',
            'branchId': bId,
            'serial': item.serial,
            'dateKey': item.dateKey,
            'queueType': qType,
            'data': sanitized,
          });

          mergedCount++;
        }

        // 3. DELETE FROM LOCAL DISPENSARY BOX AND ENQUEUE SYNC DELETE
        if (dBox != null) {
          final sUpper = item.serial.toUpperCase();
          final keysToDelete = <dynamic>{};
          for (final dk in dBox.keys) {
            final kStr = dk.toString();
            final kUpper = kStr.toUpperCase();
            if (kUpper == sUpper || kUpper.endsWith('_$sUpper') || kUpper.contains('-$sUpper') || kUpper.contains('_$sUpper')) {
              keysToDelete.add(dk);
            } else {
              final val = dBox.get(dk);
              if (val is Map) {
                final vs = (val['serial'] ?? val['id'] ?? '').toString().toUpperCase();
                if (vs == sUpper) keysToDelete.add(dk);
              }
            }
          }
          for (final dk in keysToDelete) {
            await dBox.delete(dk);
            deletedCount++;
          }
          await LocalStorageService.enqueueSync({
            'type': 'delete_dispensary',
            'branchId': bId,
            'dateKey': item.dateKey,
            'serial': item.serial,
          });
        }

        // 4. DELETE FROM LOCAL PRESCRIPTIONS BOX AND ENQUEUE SYNC DELETE
        if (prBox != null) {
          final sUpper = item.serial.toUpperCase();
          final keysToDelete = <dynamic>{};
          for (final pk in prBox.keys) {
            final kStr = pk.toString();
            final kUpper = kStr.toUpperCase();
            if (kUpper == sUpper || kUpper.endsWith('_$sUpper') || kUpper.contains('-$sUpper')) {
              keysToDelete.add(pk);
            } else {
              final val = prBox.get(pk);
              if (val is Map) {
                final vs = (val['serial'] ?? val['id'] ?? '').toString().toUpperCase();
                if (vs == sUpper) keysToDelete.add(pk);
              }
            }
          }
          for (final pk in keysToDelete) {
            await prBox.delete(pk);
            deletedCount++;
          }
          await LocalStorageService.enqueueSync({
            'type': 'delete_prescription',
            'branchId': bId,
            'serial': item.serial,
          });
        }

        setState(() {
          _progress = (i + 1) / selectedItems.length;
        });
      }

      if (eBox != null) await eBox.flush();
      if (dBox != null) await dBox.flush();
      if (prBox != null) await prBox.flush();

      _log("✨ Reconciliation complete: Merged into $mergedCount serial visit entries and removed $deletedCount redundant dispensary/prescription records.");
      SyncService().triggerUpload(force: true).catchError((e) {
        debugPrint('[SyncService] Background sync error: $e');
      });
    } catch (e) {
      _log("❌ Reconciliation execution failed: $e");
    } finally {
      if (mounted) {
        setState(() {
          _isProcessing = false;
          _progress = 1.0;
        });
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text("Reconciliation complete: Merged ${selectedItems.length} records and enqueued for sync."),
            backgroundColor: Colors.green,
          ),
        );
      }
    }
  }

  Future<void> _fixAllLegacyDataSchema() async {
    setState(() {
      _isProcessing = true;
      _logs = ["🚀 Starting Fix & Heal All Legacy Data Schema..."];
      _progress = 0.0;
    });

    try {
      int totalHealed = 0;
      final collectionsToHeal = [
        'users',
        'donations',
        'inventory',
        'patients',
        'madrassa_students',
        'school_students',
      ];

      for (int i = 0; i < collectionsToHeal.length; i++) {
        final collName = collectionsToHeal[i];
        _log("🔍 Scanning collection '$collName' for missing schema fields...");
        setState(() => _progress = (i / collectionsToHeal.length));

        List<DocumentSnapshot> docs = [];
        try {
          if (collName == 'users' || collName == 'donations') {
            final snap = await _fs.collection(collName).get();
            docs = snap.docs;
          } else {
            final snap = await _fs.collectionGroup(collName).get();
            docs = snap.docs;
          }
        } catch (e) {
          _log("⚠️ Note on $collName: $e");
        }

        WriteBatch batch = _fs.batch();
        int batchCount = 0;

        for (final doc in docs) {
          final data = doc.data() as Map<String, dynamic>? ?? {};
          bool needsFix = false;
          final updates = <String, dynamic>{};

          if (data['updatedAt'] == null) {
            updates['updatedAt'] = FieldValue.serverTimestamp();
            needsFix = true;
          }
          if (data['isDeleted'] == null) {
            updates['isDeleted'] = false;
            needsFix = true;
          }

          if (needsFix) {
            batch.set(doc.reference, updates, SetOptions(merge: true));
            batchCount++;
            totalHealed++;

            if (batchCount >= 400) {
              await batch.commit();
              batch = _fs.batch();
              batchCount = 0;
              _log("  ↳ Committed batch heal for 400 records in $collName...");
            }
          }
        }

        if (batchCount > 0) {
          await batch.commit();
          _log("  ↳ Committed batch heal for $batchCount records in $collName.");
        }
      }

      setState(() {
        _isProcessing = false;
        _progress = 1.0;
      });
      _log("🎉 Fix & Heal Completed! Total legacy records healed: $totalHealed.");

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text("✅ Schema Heal Complete! $totalHealed legacy records fixed."),
            backgroundColor: Colors.green,
          ),
        );
      }
    } catch (e) {
      _log("❌ Fix All Data error: $e");
      setState(() => _isProcessing = false);
    }
  }

  Future<void> _runStructureSanitizer() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Row(
          children: [
            Icon(Icons.warning_amber_rounded, color: Colors.redAccent),
            SizedBox(width: 8),
            Text("Purge Bogus Branches & Bloat?"),
          ],
        ),
        content: const Text(
          "This action will:\n\n"
          "1. 🗑️ Delete bogus branch docs in Firestore ('all', 'global', and numeric CNICs) and reparent any data to real branches.\n"
          "2. 📦 Clean root-level collections ('employees', 'biometric_devices', etc.) so all branch data strictly resides in branches/{branchId}/.\n"
          "3. 👤 Purge placeholder 'Employee (Staff PIN)' ghost entries and free their credentials.\n\n"
          "Do you want to proceed?",
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text("Cancel")),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: ElevatedButton.styleFrom(backgroundColor: Colors.redAccent, foregroundColor: Colors.white),
            child: const Text("Start Structure Purge"),
          ),
        ],
      ),
    );

    if (confirmed != true) return;

    setState(() {
      _isProcessing = true;
      _logs = ["🚀 Initiating Full Firestore Structure Sanitization..."];
      _progress = 0.1;
    });

    try {
      await FirestoreStructureSanitizer.executeFullStructureSanitization(
        onProgress: (msg) {
          _log(msg);
        },
      );

      setState(() => _progress = 1.0);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text("✅ Structure Sanitization completed successfully!"),
            backgroundColor: Color(0xFF10B981),
          ),
        );
      }
    } catch (e) {
      _log("❌ Error during structure sanitization: $e");
    } finally {
      if (mounted) setState(() => _isProcessing = false);
    }
  }

  // ─── Entry point ────────────────────────────────────────────────────────────

  Future<void> _startCleanup() async {
    setState(() {
      _isProcessing = true;
      _logs = ["🚀 Starting global local scan across all patients in Hive..."];
      _progress = 0.0;
      _serialsDatesCache.clear();
      _dispensaryDatesCache.clear();
    });

    try {
      if (!Hive.isBoxOpen(LocalStorageService.patientsBox)) {
        await LocalStorageService.openBoxSafe(LocalStorageService.patientsBox);
      }
      final pBox = Hive.box(LocalStorageService.patientsBox);

      _log("📦 Reading all patient records from local Hive storage...");
      
      final List<_LocalDocItem> allDocs = [];
      for (final key in pBox.keys) {
        final val = pBox.get(key);
        if (val is Map) {
          final data = Map<String, dynamic>.from(val);
          final id = key.toString();
          final bId = (data['branchId'] ?? 'unknown').toString();
          allDocs.add(_LocalDocItem(
            id: id,
            path: 'branches/$bId/patients/$id',
            data: data,
          ));
        }
      }

      _log("🔎 Found ${allDocs.length} total local records in Hive.");

      // 2. Group by (branchId + canonicalKey)
      final Map<String, List<_LocalDocItem>> groups = {};
      for (final doc in allDocs) {
        final data = doc.data();
        final branchId = data['branchId']?.toString() ?? 'unknown';
        final key = _canonicalKey(data, doc.id);
        final compositeKey = "${branchId}_$key";
        groups.putIfAbsent(compositeKey, () => []).add(doc);
      }

      // 3. Identify what needs fixing
      // - Multiple docs for same key -> MERGE
      // - Single doc with wrong ID -> FIX (MOVE)
      // - Single doc with correct ID -> IGNORE
      final Map<String, List<_LocalDocItem>> toProcess = {};
      int ignoredCount = 0;

      groups.forEach((compKey, docs) {
        final data = docs.first.data();
        final canonicalId = _canonicalKey(data, docs.first.id);
        
        bool needsFix = false;
        if (docs.length > 1) {
          needsFix = true; // Duplicates
        } else {
          final doc = docs.first;
          if (doc.id != canonicalId) {
            needsFix = true;
          }
        }

        if (needsFix) {
          toProcess[compKey] = docs;
        } else {
          ignoredCount++;
        }
      });

      _log("✅ Scan complete. Ignoring $ignoredCount correct records.");
      _log("🛠️  Processing ${toProcess.length} group(s) that need fixing...");

      int done = 0;
      final total = toProcess.length;

      for (final entry in toProcess.entries) {
        final docs = entry.value;
        final data = docs.first.data();
        final branchId = data['branchId']?.toString() ?? 'unknown';
        
        setState(() {
          _currentBranch = branchId;
          _progress = total > 0 ? done / total : 1.0;
        });

        await _performMerge(branchId, docs);
        done++;
      }

      setState(() {
        _progress = 1.0;
        _isProcessing = false;
      });
      _log("✨ ALL RECORDS PROCESSED SUCCESSFULLY LOCALLY!");
      
      // Trigger background sync to Firestore
      SyncService().triggerUpload(force: true).catchError((e) {
        debugPrint('[SyncService] Background sync error: $e');
      });
    } catch (e, st) {
      _log("❌ Fatal error: $e");
      _log("   $st");
      setState(() => _isProcessing = false);
    }
  }

  // ─── Branch processing ──────────────────────────────────────────────────────

  Future<void> _processBranch(String branchId) async {
    if (!Hive.isBoxOpen(LocalStorageService.patientsBox)) {
      await LocalStorageService.openBoxSafe(LocalStorageService.patientsBox);
    }
    final pBox = Hive.box(LocalStorageService.patientsBox);

    final List<_LocalDocItem> branchDocs = [];
    for (final key in pBox.keys) {
      final val = pBox.get(key);
      if (val is Map) {
        final data = Map<String, dynamic>.from(val);
        final bId = (data['branchId'] ?? '').toString();
        if (bId.toLowerCase() == branchId.toLowerCase() || branchId.isEmpty || branchId == 'all') {
          branchDocs.add(_LocalDocItem(
            id: key.toString(),
            path: 'branches/$bId/patients/$key',
            data: data,
          ));
        }
      }
    }

    // Group by canonical key
    final Map<String, List<_LocalDocItem>> groups = {};
    for (final doc in branchDocs) {
      final key = _canonicalKey(doc.data(), doc.id);
      groups.putIfAbsent(key, () => []).add(doc);
    }

    // Only process groups that actually have duplicates
    final dupeGroups = groups.entries.where((e) => e.value.length > 1).toList();
    _log("   Found ${dupeGroups.length} duplicate group(s) locally in $branchId");

    for (final entry in dupeGroups) {
      await _performMerge(branchId, entry.value);
    }
  }

  // ─── Canonical key ──────────────────────────────────────────────────────────
  // Always strips CNIC to raw digits so "34201-0106660-0" == "3420101066600"
  // which is also the doc ID format that PatientRegisterPage writes.

  String _canonicalKey(Map<String, dynamic> data, String docId) {
    final cnic  = _stripCnic(data['cnic']?.toString() ?? '');
    final gCnic = _stripCnic(data['guardianCnic']?.toString() ?? '');
    final name  = _normName(data['name']?.toString() ?? '');

    if (cnic.isNotEmpty) return cnic;
    if (gCnic.isNotEmpty && name.isNotEmpty) return '${gCnic}_child_$name';
    // Last resort: normalise the doc ID itself
    final strippedId = _stripCnic(docId);
    return strippedId.isNotEmpty ? strippedId : docId;
  }

  /// Removes dashes, spaces, and leading/trailing whitespace from a CNIC string.
  String _stripCnic(String raw) =>
      raw.replaceAll(RegExp(r'[-\s]'), '').trim();

  String _normName(String raw) =>
      raw.trim().toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '');

  // ─── Score ──────────────────────────────────────────────────────────────────
  // Counts non-null, non-empty, non-"null" fields as a richness proxy.
  // Prefer the document whose ID is already the stripped (registration) form —
  // that is the authoritative record created by PatientRegisterPage.

  int _scoreDoc(_LocalDocItem doc) {
    final data = doc.data();

    // Bonus: if the doc ID is already a pure-digit CNIC or canonical child ID,
    // treat it as inherently more authoritative by adding a large base score.
    final idIsAuthoritative = RegExp(r'^\d{13}$').hasMatch(doc.id) ||
        RegExp(r'^\d{13}_child_.+$').hasMatch(doc.id);
    final base = idIsAuthoritative ? 1000 : 0;

    return base + data.values.where((v) {
      if (v == null) return false;
      final s = v.toString().trim();
      return s.isNotEmpty && s.toLowerCase() != 'null' && s != 'N/A';
    }).length;
  }

  // ─── Merge ──────────────────────────────────────────────────────────────────

  Future<void> _performMerge(
      String branchId, List<_LocalDocItem> docs, {_LocalDocItem? electedMaster}) async {
    if (docs.isEmpty) return;

    // 1. Elect master: registration doc (pure-digit ID or canonical child ID) in the correct branch wins.
    final master = electedMaster ?? docs.reduce((a, b) {
      final scoreA = _scoreDoc(a);
      final scoreB = _scoreDoc(b);
      return scoreA >= scoreB ? a : b;
    });
    
    final masterData = master.data();
    final canonicalId = _canonicalKey(masterData, master.id);
    final masterName = masterData['name'] ?? 'Unknown';

    bool renamingMaster = master.id != canonicalId;

    _log("💡 ${renamingMaster ? 'Fixing' : 'Merging'} record for: $masterName (canonical → $canonicalId)");

    // 2. Enrich data
    final Map<String, dynamic> merged = Map<String, dynamic>.from(masterData);
    for (final doc in docs) {
      if (doc.id == master.id) continue;
      final data = doc.data();
      data.forEach((key, incoming) {
        if (!merged.containsKey(key) || _isMissingValue(merged[key])) {
          if (!_isMissingValue(incoming)) {
            merged[key] = incoming;
          }
        }
        if (merged[key] is Timestamp && incoming is Timestamp) {
          if ((incoming).compareTo(merged[key] as Timestamp) > 0) {
            merged[key] = incoming;
          }
        }
      });
    }

    // 3. Normalise ID fields and format CNIC
    final cleanDigits = canonicalId.replaceAll(RegExp(r'[-\s]'), '');
    final formattedCnic = RegExp(r'^\d{13}$').hasMatch(cleanDigits)
        ? '${cleanDigits.substring(0, 5)}-${cleanDigits.substring(5, 12)}-${cleanDigits.substring(12, 13)}'
        : (merged['cnic']?.toString() ?? canonicalId);

    final cleanBranch = LocalStorageService.sanitizeBranchId(branchId, fallback: 'karachi');
    merged['cnic']      = formattedCnic;
    merged['patientId'] = canonicalId;
    merged['branchId']  = cleanBranch;

    // 4. Save to local patientsBox
    if (!Hive.isBoxOpen(LocalStorageService.patientsBox)) {
      await LocalStorageService.openBoxSafe(LocalStorageService.patientsBox);
    }
    final pBox = Hive.box(LocalStorageService.patientsBox);
    final sanitizedMaster = LocalStorageService.sanitize(merged);
    await pBox.put(canonicalId, sanitizedMaster);
    _log("   ✅ Saved canonical patient locally in branch $cleanBranch: $canonicalId");

    // Enqueue sync for master patient
    await LocalStorageService.enqueueSync({
      'type': 'save_patient',
      'branchId': cleanBranch,
      'patientId': canonicalId,
      'data': sanitizedMaster,
    });

    // Collect all old IDs to repoint
    final List<String> oldIds = docs
        .where((d) => d.id != canonicalId)
        .map((d) => d.id)
        .toList();

    if (oldIds.isNotEmpty) {
      _log("   🔄 Repointing local entries and prescriptions for ${oldIds.length} duplicate IDs...");
      
      // Repoint in local entriesBox
      if (Hive.isBoxOpen(LocalStorageService.entriesBox)) {
        final eBox = Hive.box(LocalStorageService.entriesBox);
        for (final ek in eBox.keys.toList()) {
          final ev = eBox.get(ek);
          if (ev is Map) {
            final eMap = Map<String, dynamic>.from(ev);
            final pId = (eMap['patientId'] ?? '').toString();
            final cnic = (eMap['cnic'] ?? eMap['patientCnic'] ?? '').toString();
            if (oldIds.contains(pId) || oldIds.contains(cnic)) {
              eMap['patientId'] = canonicalId;
              eMap['cnic'] = formattedCnic;
              final sanitizedEntry = LocalStorageService.sanitize(eMap);
              await eBox.put(ek, sanitizedEntry);
              await LocalStorageService.enqueueSync({
                'type': 'save_entry',
                'branchId': branchId,
                'serial': eMap['serial'] ?? ek,
                'data': sanitizedEntry,
              });
            }
          }
        }
        await eBox.flush();
      }

      // Repoint in local prescriptionsBox
      if (Hive.isBoxOpen(LocalStorageService.prescriptionsBox)) {
        final prBox = Hive.box(LocalStorageService.prescriptionsBox);
        for (final pk in prBox.keys.toList()) {
          final pv = prBox.get(pk);
          if (pv is Map) {
            final prMap = Map<String, dynamic>.from(pv);
            final pId = (prMap['patientId'] ?? '').toString();
            final cnic = (prMap['patientCnic'] ?? prMap['cnic'] ?? '').toString();
            if (oldIds.contains(pId) || oldIds.contains(cnic)) {
              prMap['patientId'] = canonicalId;
              prMap['patientCnic'] = formattedCnic;
              await prBox.put(pk, LocalStorageService.sanitize(prMap));
            }
          }
        }
        await prBox.flush();
      }

      // Repoint in local dispensaryBox
      if (Hive.isBoxOpen(LocalStorageService.dispensaryBox)) {
        final dBox = Hive.box(LocalStorageService.dispensaryBox);
        for (final dk in dBox.keys.toList()) {
          final dv = dBox.get(dk);
          if (dv is Map) {
            final dMap = Map<String, dynamic>.from(dv);
            final pId = (dMap['patientId'] ?? '').toString();
            final cnic = (dMap['cnic'] ?? dMap['patientCnic'] ?? '').toString();
            if (oldIds.contains(pId) || oldIds.contains(cnic)) {
              dMap['patientId'] = canonicalId;
              dMap['cnic'] = formattedCnic;
              await dBox.put(dk, LocalStorageService.sanitize(dMap));
            }
          }
        }
        await dBox.flush();
      }

      // Delete old duplicate docs from local patientsBox and enqueue sync
      for (final oldId in oldIds) {
        await pBox.delete(oldId);
        await LocalStorageService.enqueueSync({
          'type': 'delete_patient',
          'branchId': branchId,
          'patientId': oldId,
        });
        _log("      🗑️ Deleted duplicate patient locally: $oldId");
      }
      await pBox.flush();
    }
  }

  // ─── Missing-value helper ────────────────────────────────────────────────────
  // Returns true if a value should be considered absent (null, empty, "null", "N/A").

  bool _isMissingValue(dynamic v) {
    if (v == null) return true;
    final s = v.toString().trim();
    return s.isEmpty || s.toLowerCase() == 'null' || s == 'N/A';
  }

  // ─── Prescriptions migration ─────────────────────────────────────────────────
  // Path: branches/{b}/prescriptions/{patientId}/prescriptions/{visitId}

  Future<void> _migratePrescriptions(
      String branchId, String fromId, String toId) async {
    final fromCol = _fs
        .collection('branches').doc(branchId)
        .collection('prescriptions').doc(fromId)
        .collection('prescriptions');
    final toCol = _fs
        .collection('branches').doc(branchId)
        .collection('prescriptions').doc(toId)
        .collection('prescriptions');

    final snap = await fromCol.get();
    if (snap.docs.isEmpty) return;

    _log("      📋 Moving ${snap.docs.length} prescription(s)...");
    for (final p in snap.docs) {
      // Merge into destination (don't overwrite if a same-ID visit already exists)
      await toCol.doc(p.id).set(p.data(), SetOptions(merge: true));
      await p.reference.delete();
    }

    // Delete the now-empty phantom parent doc if it happens to exist
    final fromParent = _fs
        .collection('branches').doc(branchId)
        .collection('prescriptions').doc(fromId);
    final parentSnap = await fromParent.get();
    if (parentSnap.exists) await fromParent.delete();
  }

  Future<void> _fastUpdatePatientRefs({
    required String branchId,
    required List<String> fromIds,
    required String toId,
  }) async {
    final Set<String> oldValuesSet = {};
    for (final fromId in fromIds) {
      final strippedFrom = _stripCnic(fromId);
      if (fromId.isNotEmpty) oldValuesSet.add(fromId);
      if (strippedFrom.isNotEmpty) {
        oldValuesSet.add(strippedFrom);
        oldValuesSet.add(_formatCnic(strippedFrom));
      }
    }
    final oldValues = oldValuesSet.toList();
    if (oldValues.isEmpty) return;

    final targets = ['zakat', 'non-zakat', 'gmwf', 'credits', 'emergency'];
    final fields  = ['patientId', 'cnic', 'patientCnic'];

    // Chunk old values to satisfy Firestore's limit of 30 items for 'whereIn'
    final valueChunks = <List<String>>[];
    for (int i = 0; i < oldValues.length; i += 30) {
      valueChunks.add(oldValues.sublist(i, (i + 30).clamp(0, oldValues.length)));
    }

    // Check if collectionGroup index is available
    bool collectionGroupIndexAvailable = true;
    try {
      await _fs.collectionGroup('zakat').where('patientId', isEqualTo: 'dummy').limit(1).get();
    } catch (e) {
      if (e.toString().contains('failed-precondition')) {
        collectionGroupIndexAvailable = false;
      }
    }

    if (collectionGroupIndexAvailable) {
      _log("   ⚡ Using high-speed collectionGroup index...");
      for (final col in targets) {
        for (final field in fields) {
          for (final valChunk in valueChunks) {
            try {
              final snap = await _fs.collectionGroup(col)
                  .where(field, whereIn: valChunk)
                  .get();

              for (final doc in snap.docs) {
                final docData = doc.data();
                if (docData['branchId'] != null && docData['branchId'] != branchId) continue;
                await doc.reference.update({field: toId});
                _log("         🔧 Repointed ${doc.id} in $col");
              }
            } catch (e) {
              if (e.toString().contains('failed-precondition')) {
                _log("      ⚠️ Index check failed during execution. Reverting to fallback scan...");
                await _runUnifiedFallbackScan(branchId: branchId, oldValues: valChunk, toId: toId);
              } else {
                _log("      ❌ Error updating refs in $col: $e");
              }
            }
          }
        }
      }
    } else {
      for (final valChunk in valueChunks) {
        await _runUnifiedFallbackScan(branchId: branchId, oldValues: valChunk, toId: toId);
      }
    }

    // 2. Explicitly update dispensary collections since their leaf collection names are dynamic dateKeys
    try {
      _log("   📋 Checking dispensary visits history...");
      final dates = await _getDispensaryDates(branchId);
      final root = _fs.collection('branches').doc(branchId).collection('dispensary');
      
      final chunkSize = 5;
      for (int i = 0; i < dates.length; i += chunkSize) {
        final chunk = dates.sublist(i, (i + chunkSize).clamp(0, dates.length));
        
        setState(() {
          _currentBranch = "Dispensary: date ${i + 1} of ${dates.length}";
          _progress = i / dates.length;
        });

        await Future.wait(chunk.map((date) async {
          final subCol = root.doc(date).collection(date);
          final List<Future> repointFutures = [];
          for (final field in fields) {
            for (final valChunk in valueChunks) {
              repointFutures.add(() async {
                try {
                  final matches = await subCol.where(field, whereIn: valChunk).get();
                  for (final doc in matches.docs) {
                    await doc.reference.update({field: toId});
                    _log("         🔧 Repointed ${doc.id} in dispensary/$date");
                  }
                } catch (_) {
                  // Fallback to sequential if whereIn fails
                  for (final oldVal in valChunk) {
                    final matches = await subCol.where(field, isEqualTo: oldVal).get();
                    for (final doc in matches.docs) {
                      await doc.reference.update({field: toId});
                      _log("         🔧 Repointed ${doc.id} in dispensary/$date (fallback)");
                    }
                  }
                }
              }());
            }
          }
          await Future.wait(repointFutures);
        }));
      }
    } catch (e) {
      _log("      ❌ Error updating dispensary refs: $e");
    }
  }

  /// Unified fallback scan that scans the entire branch serials history exactly once
  /// and repoints references for all collections and fields in parallel.
  Future<void> _runUnifiedFallbackScan({
    required String branchId,
    required List<String> oldValues,
    required String toId,
  }) async {
    _log("      ⚠️ CollectionGroup indexes are missing. Running unified single-pass parallel fallback scan...");
    try {
      final dates = await _getSerialsDates(branchId);
      final root = _fs.collection('branches').doc(branchId).collection('serials');
      final targets = ['zakat', 'non-zakat', 'gmwf', 'credits', 'emergency'];
      final fields  = ['patientId', 'cnic', 'patientCnic'];

      final chunkSize = 5;
      for (int i = 0; i < dates.length; i += chunkSize) {
        final chunk = dates.sublist(i, (i + chunkSize).clamp(0, dates.length));
        
        setState(() {
          _currentBranch = "Serials: date ${i + 1} of ${dates.length}";
          _progress = i / dates.length;
        });

        await Future.wait(chunk.map((date) async {
          final dateDocRef = root.doc(date);
          final List<Future> repointFutures = [];
          
          for (final col in targets) {
            final subCol = dateDocRef.collection(col);
            for (final field in fields) {
              repointFutures.add(() async {
                try {
                  final matches = await subCol.where(field, whereIn: oldValues).get();
                  for (final doc in matches.docs) {
                    await doc.reference.update({field: toId});
                    _log("         🔧 Repointed ${doc.id} in serials/$date/$col");
                  }
                } catch (_) {
                  // Fallback to sequential if whereIn fails
                  for (final oldVal in oldValues) {
                    final matches = await subCol.where(field, isEqualTo: oldVal).get();
                    for (final doc in matches.docs) {
                      await doc.reference.update({field: toId});
                      _log("         🔧 Repointed ${doc.id} in serials/$date/$col (fallback)");
                    }
                  }
                }
              }());
            }
          }
          await Future.wait(repointFutures);
        }));
      }
      _log("      ✅ Unified fallback scan completed.");
    } catch (e) {
      _log("      ❌ Error in unified fallback scan: $e");
    }
  }

  Widget _buildMergeProgressPanel() {
    if (!_isProcessing && _mergingGroupKeys.isEmpty) return const SizedBox.shrink();

    final latestLog = _logs.isNotEmpty ? _logs.first : "Preparing merge...";
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        border: Border(top: BorderSide(color: AppColors.gray200)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.05),
            blurRadius: 10,
            offset: const Offset(0, -4),
          )
        ],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              const SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(strokeWidth: 2.5, color: AppColors.primary),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  _isProcessing ? "Performing Batch Merge..." : "Merging Selected Patient Group...",
                  style: const TextStyle(fontWeight: FontWeight.bold, color: AppColors.navy),
                ),
              ),
              Text(
                "${(_progress * 100).toStringAsFixed(0)}%",
                style: const TextStyle(fontWeight: FontWeight.bold, color: AppColors.primary),
              ),
            ],
          ),
          const SizedBox(height: 12),
          LinearProgressIndicator(
            value: _progress,
            backgroundColor: AppColors.gray200,
            color: AppColors.primary,
            minHeight: 6,
            borderRadius: BorderRadius.circular(3),
          ),
          const SizedBox(height: 8),
          Text(
            latestLog,
            style: TextStyle(
              fontFamily: 'monospace',
              fontSize: 11,
              color: latestLog.contains("❌") ? Colors.red : AppColors.gray600,
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ],
      ),
    );
  }

  /// Returns a dash-formatted CNIC string from a stripped one, e.g.
  /// "3420101066600" → "34201-0106660-0"
  /// Only used when searching for OLD formatted references left in serials/dispensary.
  String _formatCnic(String stripped) {
    final digits = stripped.replaceAll(RegExp(r'\D'), '');
    if (digits.length == 13) {
      return '${digits.substring(0, 5)}-${digits.substring(5, 12)}-${digits.substring(12)}';
    }
    return stripped;
  }

  // ─── Prescription Merge & Cleanup Logic ──────────────────────────────────────

  Future<void> _scanPrescriptions() async {
    setState(() {
      _isScanningPrescriptions = true;
      _hasScannedPrescriptions = true;
      _prescriptionMigrationItems.clear();
      _logs = ["🔎 Scanning local Hive storage for prescription records..."];
      _progress = 0.0;
    });

    try {
      if (!Hive.isBoxOpen(LocalStorageService.prescriptionsBox)) {
        await LocalStorageService.openBoxSafe(LocalStorageService.prescriptionsBox);
      }
      if (!Hive.isBoxOpen(LocalStorageService.entriesBox)) {
        await LocalStorageService.openBoxSafe(LocalStorageService.entriesBox);
      }

      final pBox = Hive.box(LocalStorageService.prescriptionsBox);
      final eBox = Hive.box(LocalStorageService.entriesBox);

      _log("🔎 Found ${pBox.length} local prescription documents in Hive.");
      
      final Map<String, Map<String, dynamic>> items = {};
      int done = 0;
      final total = pBox.length;

      // Index entries for fast O(1) lookup
      final Map<String, MapEntry<dynamic, Map<String, dynamic>>> entriesBySerial = {};
      for (final ek in eBox.keys) {
        final ev = eBox.get(ek);
        if (ev is Map) {
          final eMap = Map<String, dynamic>.from(ev);
          final s = (eMap['serial'] ?? eMap['id'] ?? '').toString().trim().toUpperCase();
          if (s.isNotEmpty) {
            entriesBySerial[s] = MapEntry(ek, eMap);
          }
          final cleanKey = ek.toString().trim().toUpperCase();
          entriesBySerial[cleanKey] = MapEntry(ek, eMap);
        }
      }

      for (final key in pBox.keys) {
        final val = pBox.get(key);
        if (val == null || val is! Map) {
          done++;
          continue;
        }
        final data = Map<String, dynamic>.from(val);
        final serial = (data['serial'] ?? data['id'] ?? key).toString().trim();
        final upperSerial = serial.toUpperCase();
        String branchId = data['branchId']?.toString() ?? '';
        String patientCnic = (data['patientCnic'] ?? data['cnic'] ?? data['patientId'] ?? '').toString().trim();
        patientCnic = patientCnic.replaceAll('-', '').replaceAll(' ', '').trim();

        final itemKey = "${branchId.isEmpty ? 'unknown' : branchId}_${patientCnic}_$serial";

        // Extract dateKey
        String dateKey = (data['dateKey'] ?? '').toString().trim();
        if (dateKey.isEmpty && serial.contains('-')) {
          dateKey = serial.split('-')[0];
        }
        if (dateKey.isEmpty) {
          final created = data['createdAt'];
          if (created is Timestamp) {
            dateKey = DateFormat('ddMMyy').format(created.toDate());
          } else if (created is String && created.isNotEmpty) {
            try {
              dateKey = DateFormat('ddMMyy').format(DateTime.parse(created));
            } catch (_) {}
          }
        }
        if (dateKey.isEmpty) {
          dateKey = LocalStorageService.getTodayDateKey();
        }

        final preferredType = (data['queueType'] ?? 'zakat').toString();

        // Locate local serial entry
        MapEntry<dynamic, Map<String, dynamic>>? entryMatch = entriesBySerial[upperSerial];
        if (entryMatch == null && branchId.isNotEmpty) {
          entryMatch = entriesBySerial['${branchId.toUpperCase()}-$upperSerial'] ??
                       entriesBySerial['${branchId.toLowerCase()}-$upperSerial'];
        }
        if (entryMatch == null) {
          // Cross-branch scan: inspect all keys in entriesBySerial for this serial across all branches
          for (final candidateKey in entriesBySerial.keys) {
            if (candidateKey.endsWith('-$upperSerial') || candidateKey.endsWith('_$upperSerial')) {
              entryMatch = entriesBySerial[candidateKey];
              if (branchId.isEmpty && entryMatch?.value['branchId'] != null) {
                branchId = entryMatch!.value['branchId'].toString();
              }
              break;
            }
          }
        }
        if (branchId.isEmpty && entryMatch != null && entryMatch.value['branchId'] != null) {
          branchId = entryMatch.value['branchId'].toString();
        }

        String resolvedQueue = preferredType;
        bool serialDocExists = entryMatch != null;
        String status = 'orphaned';

        if (serialDocExists) {
          final sData = entryMatch.value;
          resolvedQueue = (sData['queueType'] ?? preferredType).toString();
          final hasPresc = sData['prescription'] != null || 
              (sData['medicines'] is List && (sData['medicines'] as List).isNotEmpty);
          status = hasPresc ? 'already_merged' : 'needs_merge';
        }

        items[itemKey] = {
          'key': itemKey,
          'hiveKey': key,
          'branchId': branchId.isNotEmpty ? branchId : 'unknown',
          'patientCnic': patientCnic,
          'serial': serial,
          'dateKey': dateKey,
          'queueType': resolvedQueue.isEmpty ? 'zakat' : resolvedQueue,
          'patientName': data['patientName'] ?? data['name'] ?? 'Unknown Patient',
          'createdAt': data['createdAt'],
          'medicines': data['prescriptions'] ?? data['medicines'] ?? [],
          'prescriptionData': data,
          'matchedEntryKey': entryMatch?.key,
          'status': status,
          'serialDocExists': serialDocExists,
        };

        done++;
        if (total > 0 && done % 50 == 0) {
          setState(() {
            _progress = done / total;
          });
        }
      }

      setState(() {
        _prescriptionMigrationItems = items;
        _isScanningPrescriptions = false;
      });
      _log("✨ Local scan complete! Found ${items.length} prescriptions in Hive to check.");
    } catch (e, st) {
      _log("❌ Local scan failed: $e");
      _log("   $st");
      setState(() {
        _isScanningPrescriptions = false;
        _hasScannedPrescriptions = false;
      });
    }
  }

  Future<void> _mergeAndCleanPrescription(String key, {required bool forceRecreateSerial}) async {
    final item = _prescriptionMigrationItems[key];
    if (item == null) return;

    setState(() {
      _processingPrescriptionKeys.add(key);
    });

    String branchId = (item['branchId'] ?? '').toString().trim();
    if (branchId.isEmpty || branchId == 'unknown') {
      if (item['matchedEntryKey'] != null && item['matchedEntryKey'].toString().contains('-')) {
        branchId = item['matchedEntryKey'].toString().split('-').first;
      } else {
        final localBranches = LocalStorageService.getLocalBranchesList();
        branchId = localBranches.isNotEmpty ? (localBranches.first['id'] ?? 'default').toString() : 'default';
      }
    }
    final patientCnic = item['patientCnic']?.toString() ?? '';
    final serial = item['serial']?.toString() ?? '';
    final dateKey = item['dateKey']?.toString() ?? '';
    final queueType = item['queueType']?.toString() ?? 'zakat';
    final hiveKey = item['hiveKey'];
    final matchedEntryKey = item['matchedEntryKey'];
    final isOrphaned = item['status'] == 'orphaned';

    _log("⏳ Cleaning local prescription $serial...");

    try {
      final eBox = Hive.box(LocalStorageService.entriesBox);
      final prBox = Hive.box(LocalStorageService.prescriptionsBox);
      final dBox = Hive.isBoxOpen(LocalStorageService.dispensaryBox)
          ? Hive.box(LocalStorageService.dispensaryBox)
          : null;

      final pData = item['prescriptionData'] is Map ? Map<String, dynamic>.from(item['prescriptionData'] as Map) : <String, dynamic>{};
      final pMeds = pData['prescriptions'] ?? pData['medicines'];
      final docName = pData['doctorName'] ?? pData['prescribedBy'];
      final docId = pData['doctorId'];
      final diag = pData['diagnosis'];
      final comp = pData['complaint'] ?? pData['condition'];
      final days = pData['daysOfMedicine'];
      final vitals = pData['vitals'];
      final lab = pData['labResults'];
      final extra = pData['extraCharge'];

      // Also inspect dispensaryBox for any matching dispense records for this serial
      Map<String, dynamic>? dispData;
      final List<dynamic> dKeysToDelete = [];
      if (dBox != null) {
        final sUpper = serial.toUpperCase();
        for (final dk in dBox.keys) {
          final kStr = dk.toString().toUpperCase();
          if (kStr == sUpper || kStr.endsWith('_$sUpper') || kStr.contains('-$sUpper')) {
            dKeysToDelete.add(dk);
            if (dispData == null) {
              final val = dBox.get(dk);
              if (val is Map) dispData = Map<String, dynamic>.from(val);
            }
          } else {
            final val = dBox.get(dk);
            if (val is Map) {
              final vs = (val['serial'] ?? val['id'] ?? '').toString().toUpperCase();
              if (vs == sUpper) {
                dKeysToDelete.add(dk);
                dispData ??= Map<String, dynamic>.from(val);
              }
            }
          }
        }
      }

      final hasDispensed = dispData != null &&
          ((dispData['dispenseStatus'] ?? dispData['status'] ?? '').toString().toLowerCase() == 'dispensed' ||
           (dispData['dispenseStatus'] ?? dispData['status'] ?? '').toString().toLowerCase() == 'completed');

      if (isOrphaned && forceRecreateSerial) {
        // Re-create missing serial document in local Hive entriesBox
        final newEntry = {
          'serial': serial,
          'id': serial,
          'patientId': patientCnic,
          'cnic': patientCnic,
          'patientName': item['patientName'],
          'name': item['patientName'],
          'status': 'completed',
          'dispenseStatus': hasDispensed ? 'dispensed' : 'waiting',
          'queueType': queueType,
          'dateKey': dateKey,
          'branchId': branchId,
          'createdAt': item['createdAt'] ?? DateTime.now().toIso8601String(),
          'completedAt': item['createdAt'] ?? DateTime.now().toIso8601String(),
          'prescription': pData,
          if (pMeds != null) 'medicines': pMeds,
          if (pMeds != null) 'prescriptions': pMeds,
          if (docName != null) 'doctorName': docName,
          if (docName != null) 'prescribedBy': docName,
          if (docId != null) 'doctorId': docId,
          if (diag != null) 'diagnosis': diag,
          if (comp != null) 'complaint': comp,
          if (comp != null) 'condition': comp,
          if (days != null) 'daysOfMedicine': days,
          if (vitals != null) 'vitals': vitals,
          if (lab != null) 'labResults': lab,
          if (extra != null) 'extraCharge': extra,
          if (dispData != null) ...{
            if (dispData['dispensedAt'] != null) 'dispensedAt': dispData['dispensedAt'],
            if (dispData['dispensedBy'] != null) 'dispensedBy': dispData['dispensedBy'],
            if (dispData['dispenserName'] != null) 'dispenserName': dispData['dispenserName'],
            if (dispData['charges'] != null) 'charges': dispData['charges'],
            if (dispData['receivedAmount'] != null) 'receivedAmount': dispData['receivedAmount'],
          },
        };
        final newKey = '${branchId.toLowerCase()}-$serial';
        await eBox.put(newKey, LocalStorageService.sanitize(newEntry));
        await eBox.put(serial.toUpperCase(), LocalStorageService.sanitize(newEntry));
        await eBox.put(serial.toLowerCase(), LocalStorageService.sanitize(newEntry));

        // Enqueue sync for Firestore in the background
        await LocalStorageService.enqueueSync({
          'type': 'save_entry',
          'branchId': branchId,
          'dateKey': dateKey,
          'queueType': queueType,
          'serial': serial,
          'data': newEntry,
        });
        _log("   ✅ Re-created missing serial visit entry locally: $newKey");
      } else if (!isOrphaned && matchedEntryKey != null) {
        final existingRaw = eBox.get(matchedEntryKey);
        if (existingRaw is Map) {
          final updatedEntry = Map<String, dynamic>.from(existingRaw);
          updatedEntry['prescription'] = pData;
          updatedEntry['status'] = 'completed';
          updatedEntry['completedAt'] ??= pData['completedAt'] ??
              pData['createdAt'] ??
              DateTime.now().toIso8601String();
          if (hasDispensed) {
            updatedEntry['dispenseStatus'] = 'dispensed';
          }
          if (pMeds != null) {
            updatedEntry['medicines'] = pMeds;
            updatedEntry['prescriptions'] ??= pMeds;
          }
          if (docName != null) {
            updatedEntry['doctorName'] = docName;
            updatedEntry['prescribedBy'] ??= docName;
          }
          if (docId != null) updatedEntry['doctorId'] = docId;
          if (diag != null) updatedEntry['diagnosis'] = diag;
          if (comp != null) {
            updatedEntry['complaint'] = comp;
            updatedEntry['condition'] ??= comp;
          }
          if (days != null) updatedEntry['daysOfMedicine'] = days;
          if (vitals != null) updatedEntry['vitals'] = vitals;
          if (lab != null) updatedEntry['labResults'] = lab;
          if (extra != null) updatedEntry['extraCharge'] = extra;
          if (dispData != null) {
            if (dispData['dispensedAt'] != null) updatedEntry['dispensedAt'] = dispData['dispensedAt'];
            if (dispData['dispensedBy'] != null) updatedEntry['dispensedBy'] = dispData['dispensedBy'];
            if (dispData['dispenserName'] != null) updatedEntry['dispenserName'] = dispData['dispenserName'];
            if (dispData['charges'] != null) updatedEntry['charges'] = dispData['charges'];
            if (dispData['receivedAmount'] != null) updatedEntry['receivedAmount'] = dispData['receivedAmount'];
          }

          final sanitized = LocalStorageService.sanitize(updatedEntry);
          await eBox.put(matchedEntryKey, sanitized);
          await eBox.put(serial.toUpperCase(), sanitized);
          await eBox.put(serial.toLowerCase(), sanitized);

          // Enqueue sync for Firestore in the background
          await LocalStorageService.enqueueSync({
            'type': 'save_entry',
            'branchId': branchId,
            'dateKey': dateKey,
            'queueType': queueType,
            'serial': serial,
            'data': updatedEntry,
          });
          _log("   ✅ Merged prescription & dispensary data into local serial visit entry: $matchedEntryKey");
        }
      }

      // Delete all redundant prescription keys from local Hive prescriptionsBox
      final sUpper = serial.toUpperCase();
      final keysToDelete = <dynamic>{};
      if (hiveKey != null) keysToDelete.add(hiveKey);
      for (final pk in prBox.keys) {
        final kStr = pk.toString().toUpperCase();
        if (kStr == sUpper || kStr.endsWith('_$sUpper') || kStr.contains('-$sUpper')) {
          keysToDelete.add(pk);
        } else {
          final pv = prBox.get(pk);
          if (pv is Map) {
            final vs = (pv['serial'] ?? pv['id'] ?? '').toString().toUpperCase();
            if (vs == sUpper) keysToDelete.add(pk);
          }
        }
      }
      for (final pk in keysToDelete) {
        await prBox.delete(pk);
      }

      // Enqueue sync deletion for prescription from Firestore
      await LocalStorageService.enqueueSync({
        'type': 'delete_prescription',
        'branchId': branchId,
        'patientCnic': patientCnic,
        'serial': serial,
      });

      // Also delete all matching redundant dispensary keys from local Hive dispensaryBox
      if (dBox != null && dKeysToDelete.isNotEmpty) {
        for (final dk in dKeysToDelete) {
          await dBox.delete(dk);
        }
        await dBox.flush();
        await LocalStorageService.enqueueSync({
          'type': 'delete_dispensary',
          'branchId': branchId,
          'dateKey': dateKey,
          'serial': serial,
        });
        _log("   🗑️ Removed redundant dispensary record for: $serial");
      }

      await eBox.flush();
      await prBox.flush();
      _log("   🗑️ Removed redundant local prescription: $serial");

      setState(() {
        _prescriptionMigrationItems.remove(key);
        _processingPrescriptionKeys.remove(key);
      });

      // Trigger background sync without blocking UI
      SyncService().triggerUpload(force: true).catchError((e) {
        debugPrint('[SyncService] Background sync error: $e');
      });
    } catch (e, st) {
      _log("❌ Failed to process prescription $serial: $e");
      _log("   $st");
      setState(() {
        _processingPrescriptionKeys.remove(key);
      });
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text("Error: $e"),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  Future<void> _mergeAndCleanAllPrescriptions() async {
    final pending = _prescriptionMigrationItems.entries
        .where((e) => !_processingPrescriptionKeys.contains(e.key))
        .toList();
    
    if (pending.isEmpty) return;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text("Bulk Merge & Clean Prescriptions"),
        content: Text("Are you sure you want to merge and delete all ${pending.length} prescription documents locally? "
            "Orphaned prescriptions will be automatically re-created in local visits to preserve patient history, and all updates will be queued for sync."),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text("Cancel"),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: ElevatedButton.styleFrom(backgroundColor: AppColors.primary),
            child: const Text("Merge & Clean All"),
          ),
        ],
      ),
    );

    if (confirmed != true) return;

    setState(() {
      _isProcessing = true;
      _currentBranch = "Merging prescriptions locally...";
      _progress = 0.0;
    });

    int done = 0;
    final total = pending.length;

    for (final entry in pending) {
      final key = entry.key;
      setState(() {
        _progress = done / total;
      });

      await _mergeAndCleanPrescription(key, forceRecreateSerial: true);
      done++;
    }

    setState(() {
      _isProcessing = false;
      _progress = 1.0;
    });

    // Trigger sync in the end
    SyncService().triggerUpload(force: true).catchError((e) {
      debugPrint('[SyncService] Background sync error: $e');
    });

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text("Bulk local prescription cleanup completed! Background sync queued."),
          backgroundColor: Colors.green,
        ),
      );
    }
  }

  Future<void> _unifyAllBranchesSerialsDispensary() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Row(
          children: [
            Icon(Icons.hub_rounded, color: Color(0xFF0D9488)),
            SizedBox(width: 8),
            Text("Unify All Branches"),
          ],
        ),
        content: const Text(
          "This operation reconciles data across ALL branches in local Hive storage:\n\n"
          "• Prescriptions & dispensary records are merged directly into EACH BRANCH'S OWN serial visit entries (e.g. branches/khi_01/serials/..., branches/saddar/serials/...). Each branch's data stays in its own separate branch.\n"
          "• Re-creates canonical visit entries for any orphaned prescriptions or dispensary records in their respective branch.\n"
          "• Completely purges redundant standalone documents from legacy prescription & dispensary boxes.\n"
          "• Queues unified records for background Firestore sync to each branch's own serial collection.\n\n"
          "Do you want to run unification across all branches?",
          style: TextStyle(fontSize: 14, height: 1.4),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text("Cancel"),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFF0D9488),
              foregroundColor: Colors.white,
            ),
            child: const Text("Unify All Branches"),
          ),
        ],
      ),
    );

    if (confirmed != true) return;

    setState(() {
      _isProcessing = true;
      _currentBranch = "Unifying all branches...";
      _logs = ["🔄 Unifying serials, prescriptions & dispensary records across ALL branches..."];
      _progress = 0.0;
    });

    try {
      final count = await LocalStorageService.unifyAndMergeAllLocalSerials(null);
      SyncService().triggerUpload(force: true).catchError((_) {});

      if (mounted) {
        setState(() {
          _isProcessing = false;
          _progress = 1.0;
          _currentBranch = "";
        });
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text("✅ Unified $count records across all branches! Duplicates purged and sync queued."),
          backgroundColor: const Color(0xFF0D9488),
          duration: const Duration(seconds: 4),
        ));
      }
      _log("✨ All-branches unification complete: $count records unified into canonical serial entries.");

      // Refresh prescription scan if active
      if (_hasScannedPrescriptions) {
        await _scanPrescriptions();
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _isProcessing = false;
          _currentBranch = "";
        });
      }
      _log("❌ Failed to unify records across all branches: $e");
    }
  }

  // ─── Interactive Deduplication Logic ────────────────────────────────────────

  Future<void> _scanForDuplicates() async {
    setState(() {
      _isScanning = true;
      _logs = ["🔎 Scanning local Hive storage for duplicate patient records..."];
      _duplicatesByLetter.clear();
      _electedMasterIds.clear();
      _progress = 0.0;
      _serialsDatesCache.clear();
      _dispensaryDatesCache.clear();
    });

    try {
      _log("📦 Fetching all patient records from local Hive...");
      if (!Hive.isBoxOpen(LocalStorageService.patientsBox)) {
        await LocalStorageService.openBoxSafe(LocalStorageService.patientsBox);
      }
      final pBox = Hive.box(LocalStorageService.patientsBox);

      final List<_LocalDocItem> allDocs = [];
      for (final key in pBox.keys) {
        final val = pBox.get(key);
        if (val is Map) {
          final data = Map<String, dynamic>.from(val);
          final id = key.toString();
          final bId = (data['branchId'] ?? 'unknown').toString();
          allDocs.add(_LocalDocItem(
            id: id,
            path: 'branches/$bId/patients/$id',
            data: data,
          ));
        }
      }

      _log("🔎 Found ${allDocs.length} total records in local Hive storage.");

      // Group by (branchId + canonicalKey)
      final Map<String, List<_LocalDocItem>> groups = {};
      for (final doc in allDocs) {
        final data = doc.data();
        final branchId = data['branchId']?.toString() ?? 'unknown';
        final key = _canonicalKey(data, doc.id);
        final compositeKey = "${branchId}_$key";
        groups.putIfAbsent(compositeKey, () => []).add(doc);
      }

      // Identify duplicate groups (docs.length > 1)
      final Map<String, Map<String, List<_LocalDocItem>>> duplicates = {};
      int dupeCount = 0;

      groups.forEach((compKey, docs) {
        if (docs.length > 1) {
          final data = docs.first.data();
          final name = data['name']?.toString() ?? '';
          final letter = name.isNotEmpty ? name[0].toUpperCase() : '#';
          
          final keyLetter = RegExp(r'[A-Z]').hasMatch(letter) ? letter : '#';

          duplicates.putIfAbsent(keyLetter, () => {});
          duplicates[keyLetter]![compKey] = docs;

          // Elect default master (highest score)
          final master = docs.reduce((a, b) {
            final scoreA = _scoreDoc(a);
            final scoreB = _scoreDoc(b);
            return scoreA >= scoreB ? a : b;
          });
          _electedMasterIds[compKey] = master.id;

          dupeCount++;
        }
      });

      // Sort keys alphabetically
      final sortedLetters = duplicates.keys.toList()..sort();
      final Map<String, Map<String, List<_LocalDocItem>>> sortedDuplicates = {};
      for (final letter in sortedLetters) {
        sortedDuplicates[letter] = duplicates[letter]!;
      }

      setState(() {
        _duplicatesByLetter = sortedDuplicates;
        _hasScanned = true;
        _isScanning = false;
        if (sortedLetters.isNotEmpty) {
          _selectedLetter = sortedLetters.first;
        } else {
          _selectedLetter = null;
        }
      });

      _log("✨ Local scan complete! Found $dupeCount duplicate patient groups.");
    } catch (e, st) {
      _log("❌ Local scan failed: $e");
      _log("   $st");
      setState(() {
        _isScanning = false;
        _hasScanned = false;
      });
    }
  }

  Future<void> _animateAndRemoveGroup({
    required String groupKey,
    required String letter,
    bool updateLetterSelection = true,
  }) async {
    setState(() {
      _mergedGroupKeys.add(groupKey);
    });

    // Wait to let user see the success state
    await Future.delayed(const Duration(milliseconds: 1500));

    // Start shrinking transition
    setState(() {
      _disappearingGroupKeys.add(groupKey);
    });

    // Wait for shrink animation to finish
    await Future.delayed(const Duration(milliseconds: 350));

    // Finally remove from list and clean up keys
    setState(() {
      _mergedGroupKeys.remove(groupKey);
      _disappearingGroupKeys.remove(groupKey);
      
      if (letter.isNotEmpty && _duplicatesByLetter.containsKey(letter)) {
        _duplicatesByLetter[letter]!.remove(groupKey);
        
        if (updateLetterSelection && _duplicatesByLetter[letter]!.isEmpty) {
          _duplicatesByLetter.remove(letter);
          
          final sortedLetters = _duplicatesByLetter.keys.toList()..sort();
          if (sortedLetters.isNotEmpty) {
            _selectedLetter = sortedLetters.first;
          } else {
            _selectedLetter = null;
          }
        }
      }
    });
  }

  Future<void> _mergeSingleGroup(String groupKey, String branchId, List<_LocalDocItem> docs) async {
    final masterId = _electedMasterIds[groupKey];
    if (masterId == null) return;

    final masterDoc = docs.firstWhere((d) => d.id == masterId, orElse: () => docs.first);

    setState(() {
      _mergingGroupKeys.add(groupKey);
    });

    _log("⏳ Merging duplicate group $groupKey locally...");
    try {
      await _performMerge(branchId, docs, electedMaster: masterDoc);
      _log("✅ Successfully merged group $groupKey locally.");

      setState(() {
        _mergingGroupKeys.remove(groupKey);
      });

      // Background sync queued
      SyncService().triggerUpload(force: true).catchError((e) {
        debugPrint('[SyncService] Background sync error: $e');
      });
      
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text("Group merged locally! Sync queued."),
          backgroundColor: Colors.green,
          duration: Duration(seconds: 2),
        ),
      );

      await _animateAndRemoveGroup(
        groupKey: groupKey,
        letter: _selectedLetter ?? '',
        updateLetterSelection: true,
      );
    } catch (e, st) {
      _log("❌ Failed to merge group $groupKey: $e");
      _log("   $st");
      setState(() {
        _mergingGroupKeys.remove(groupKey);
        _mergedGroupKeys.remove(groupKey);
        _disappearingGroupKeys.remove(groupKey);
      });
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text("Merge failed: $e"),
          backgroundColor: Colors.red,
        ),
      );
    }
  }

  void _ignoreGroup(String groupKey) {
    setState(() {
      if (_selectedLetter != null && _duplicatesByLetter.containsKey(_selectedLetter)) {
        _duplicatesByLetter[_selectedLetter]!.remove(groupKey);
        
        if (_duplicatesByLetter[_selectedLetter]!.isEmpty) {
          _duplicatesByLetter.remove(_selectedLetter);
          
          final sortedLetters = _duplicatesByLetter.keys.toList()..sort();
          if (sortedLetters.isNotEmpty) {
            _selectedLetter = sortedLetters.first;
          } else {
            _selectedLetter = null;
          }
        }
      }
    });
  }

  Future<void> _mergeAllUnderSelectedLetter() async {
    final letter = _selectedLetter;
    if (letter == null) return;
    final groups = Map<String, List<_LocalDocItem>>.from(_duplicatesByLetter[letter] ?? {});
    if (groups.isEmpty) return;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text("Merge All under '$letter'"),
        content: Text("Are you sure you want to merge all ${groups.length} duplicate groups under the letter '$letter' locally using the currently selected masters?"),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text("Cancel"),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: ElevatedButton.styleFrom(backgroundColor: AppColors.primary),
            child: const Text("Merge All"),
          ),
        ],
      ),
    );

    if (confirmed != true) return;

    setState(() {
      _isProcessing = true;
      _currentBranch = "Merging letter $letter locally...";
      _progress = 0.0;
    });

    int done = 0;
    final total = groups.length;

    for (final entry in groups.entries) {
      final groupKey = entry.key;
      final docs = entry.value;
      final branchId = (docs.first.data()['branchId'] ?? 'unknown').toString();
      final masterId = _electedMasterIds[groupKey];
      final masterDoc = docs.firstWhere((d) => d.id == masterId, orElse: () => docs.first);

      setState(() {
        _progress = done / total;
      });

      try {
        setState(() {
          _mergingGroupKeys.add(groupKey);
        });

        await _performMerge(branchId, docs, electedMaster: masterDoc);
        
        setState(() {
          _mergingGroupKeys.remove(groupKey);
        });

        _animateAndRemoveGroup(
          groupKey: groupKey,
          letter: letter,
          updateLetterSelection: true,
        );
      } catch (e) {
        _log("❌ Failed bulk merge for group $groupKey: $e");
        setState(() {
          _mergingGroupKeys.remove(groupKey);
        });
      }
      done++;
    }

    setState(() {
      _isProcessing = false;
      _progress = 1.0;
    });

    // Trigger sync in the end
    SyncService().triggerUpload(force: true).catchError((e) {
      debugPrint('[SyncService] Background sync error: $e');
    });

    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text("Finished merging duplicates locally under letter '$letter'. Background sync queued."),
        backgroundColor: AppColors.primary,
      ),
    );
  }

  String _parseDate(dynamic raw, {String fmt = 'dd MMM yyyy'}) {
    if (raw == null) return 'N/A';
    try {
      if (raw is Timestamp) return DateFormat(fmt).format(raw.toDate());
      if (raw is String && raw.isNotEmpty) {
        return DateFormat(fmt).format(DateTime.parse(raw));
      }
    } catch (_) {}
    return 'N/A';
  }

  // ─── UI Helpers & KPI Getters ──────────────────────────────────────────────

  int get _localPatientsCount {
    if (Hive.isBoxOpen(LocalStorageService.patientsBox)) {
      return Hive.box(LocalStorageService.patientsBox).length;
    }
    return 0;
  }

  int get _syncQueuePendingCount {
    if (Hive.isBoxOpen(LocalStorageService.syncBox)) {
      return Hive.box(LocalStorageService.syncBox).length;
    }
    return 0;
  }

  int get _totalDuplicateGroups {
    return _duplicatesByLetter.values.fold(0, (total, m) => total + m.length);
  }

  List<Map<String, dynamic>> get _filteredConflicts {
    if (_conflictFilter == 'raw_cnic') {
      return _childParentConflicts.where((c) => c['isRawCnicChild'] == true).toList();
    }
    if (_conflictFilter == 'shared_cnic') {
      return _childParentConflicts.where((c) => c['hasCnicCollision'] == true).toList();
    }
    return _childParentConflicts;
  }

  Widget _buildKpiCard({
    required String label,
    required String value,
    required IconData icon,
    required Color color,
    VoidCallback? onTap,
  }) {
    return Expanded(
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: AppColors.gray200),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.02),
                blurRadius: 4,
                offset: const Offset(0, 2),
              ),
            ],
          ),
          child: Row(
            children: [
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: color.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(icon, color: color, size: 20),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      value,
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                        color: color,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      label,
                      style: const TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                        color: AppColors.gray600,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildTabButton({
    required int index,
    required String title,
    required IconData icon,
    int? count,
    Color? badgeColor,
  }) {
    final isSelected = _activeTab == index;
    return Expanded(
      child: GestureDetector(
        onTap: () => setState(() => _activeTab = index),
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 6),
          decoration: BoxDecoration(
            color: isSelected ? Colors.white : Colors.transparent,
            borderRadius: BorderRadius.circular(10),
            boxShadow: isSelected
                ? [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.05),
                      blurRadius: 4,
                      offset: const Offset(0, 2),
                    ),
                  ]
                : null,
          ),
          alignment: Alignment.center,
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                icon,
                size: 16,
                color: isSelected ? AppColors.primary : AppColors.gray600,
              ),
              const SizedBox(width: 6),
              Flexible(
                child: Text(
                  title,
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.bold,
                    color: isSelected ? AppColors.primary : AppColors.gray600,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              if (count != null && count > 0) ...[
                const SizedBox(width: 6),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  decoration: BoxDecoration(
                    color: badgeColor ?? (isSelected ? AppColors.primary : AppColors.gray400),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Text(
                    count > 999 ? '999+' : count.toString(),
                    style: const TextStyle(
                      fontSize: 10,
                      fontWeight: FontWeight.bold,
                      color: Colors.white,
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  // ─── UI ─────────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final conflictsCount = _childParentConflicts.length;
    final duplicatesCount = _totalDuplicateGroups;
    final prescriptionsCount = _prescriptionMigrationItems.length;

    return Scaffold(
      backgroundColor: AppColors.gray50,
      appBar: AppBar(
        title: const Text(
          "Data Integrity & Cleanup",
          style: TextStyle(fontWeight: FontWeight.bold),
        ),
        backgroundColor: Colors.white,
        elevation: 0,
        centerTitle: true,
      ),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Executive KPI HUD Row
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 16, 24, 4),
            child: Row(
              children: [
                _buildKpiCard(
                  label: "Local Patients",
                  value: _localPatientsCount.toString(),
                  icon: Icons.people_alt_rounded,
                  color: const Color(0xFF0D9488),
                  onTap: _scanAndPreviewPatientRepairs,
                ),
                const SizedBox(width: 12),
                _buildKpiCard(
                  label: "Child/Parent Conflicts",
                  value: conflictsCount.toString(),
                  icon: Icons.family_restroom_rounded,
                  color: const Color(0xFFE11D48),
                  onTap: () => setState(() => _activeTab = 0),
                ),
                const SizedBox(width: 12),
                _buildKpiCard(
                  label: "Duplicates (A-Z)",
                  value: duplicatesCount.toString(),
                  icon: Icons.copy_rounded,
                  color: AppColors.primary,
                  onTap: () => setState(() => _activeTab = 1),
                ),
                const SizedBox(width: 12),
                _buildKpiCard(
                  label: "Sync Queue Pending",
                  value: _syncQueuePendingCount.toString(),
                  icon: Icons.cloud_sync_rounded,
                  color: const Color(0xFF7C3AED),
                  onTap: null,
                ),
              ],
            ),
          ),

          // Custom Tab Selector (4 Modern Tabs)
          Container(
            color: Colors.transparent,
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 10),
            child: Container(
              decoration: BoxDecoration(
                color: AppColors.gray100,
                borderRadius: BorderRadius.circular(12),
              ),
              padding: const EdgeInsets.all(4),
              child: Row(
                children: [
                  _buildTabButton(
                    index: 0,
                    title: "Child & Parent Conflicts",
                    icon: Icons.child_care_rounded,
                    count: conflictsCount,
                    badgeColor: const Color(0xFFE11D48),
                  ),
                  _buildTabButton(
                    index: 1,
                    title: "Manual Review (A-Z)",
                    icon: Icons.people_outline_rounded,
                    count: duplicatesCount,
                    badgeColor: AppColors.primary,
                  ),
                  _buildTabButton(
                    index: 2,
                    title: "Prescription Cleanups",
                    icon: Icons.medication_outlined,
                    count: prescriptionsCount,
                    badgeColor: const Color(0xFF10B981),
                  ),
                  _buildTabButton(
                    index: 3,
                    title: "Automated Global Run",
                    icon: Icons.bolt_rounded,
                  ),
                ],
              ),
            ),
          ),

          // Quick Diagnostics Actions
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 4),
            child: Row(
              children: [
                Expanded(
                  child: ElevatedButton.icon(
                    onPressed: _isProcessing ? null : _scanAndPreviewPatientRepairs,
                    icon: const Icon(Icons.preview_rounded, size: 18),
                    label: const Text('Preview & Repair Patient IDs'),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFF0D9488),
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(vertical: 13),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                      elevation: 0,
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: ElevatedButton.icon(
                    onPressed: _isProcessing ? null : _formatAllPatientCnics,
                    icon: const Icon(Icons.badge_outlined, size: 18),
                    label: const Text('Format CNICs (xxxxx-xxxxxxx-x)'),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFF0284C7),
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(vertical: 13),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                      elevation: 0,
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: ElevatedButton.icon(
                    onPressed: _isProcessing ? null : _scanAndPreviewSerialsDispensary,
                    icon: const Icon(Icons.compare_arrows_rounded, size: 18),
                    label: const Text('Preview & Fix Serials/Dispensary'),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFF7C3AED),
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(vertical: 13),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                      elevation: 0,
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: ElevatedButton.icon(
                    onPressed: _isProcessing ? null : _unifyAllBranchesSerialsDispensary,
                    icon: const Icon(Icons.hub_rounded, size: 18),
                    label: const Text('Unify All Branches (Rx/Disp/Serials)'),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFF0D9488),
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(vertical: 13),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                      elevation: 0,
                    ),
                  ),
                ),
              ],
            ),
          ),
          
          Expanded(
            child: _activeTab == 0
                ? _buildChildParentConflictsTab()
                : _activeTab == 1
                    ? _buildManualReviewTab()
                    : _activeTab == 2
                        ? _buildPrescriptionCleanupsTab()
                        : _buildAutomatedTab(),
          ),
          _buildMergeProgressPanel(),
        ],
      ),
    );
  }

  Widget _buildChildParentConflictsTab() {
    if (_isScanningConflicts) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const CircularProgressIndicator(color: Color(0xFFE11D48)),
            const SizedBox(height: 20),
            const Text(
              "Scanning patient registry for child & parent conflicts...",
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: AppColors.gray800),
            ),
            const SizedBox(height: 8),
            Text(
              "Checking CNICs, guardian fields, and verifying linked clinical history...",
              style: TextStyle(fontSize: 13, color: AppColors.gray500),
            ),
          ],
        ),
      );
    }

    if (!_hasScannedConflicts) {
      return Padding(
        padding: const EdgeInsets.all(24.0),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.family_restroom_rounded, size: 72, color: const Color(0xFFE11D48).withValues(alpha: 0.8)),
            const SizedBox(height: 24),
            const Text(
              "Child & Parent CNIC Conflict Resolution",
              style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold, color: AppColors.navy),
            ),
            const SizedBox(height: 12),
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 550),
              child: Text(
                "Detect child patients registered directly under an adult's raw CNIC before the adult existed, "
                "or records sharing the same CNIC without child designations. "
                "Cleaning conflicted registrations removes token issuance collisions between parent and child on the same day.\n\n"
                "✅ All clinical visit histories, prescriptions, and dispensary logs remain 100% preserved.",
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 13.5, color: AppColors.gray600, height: 1.5),
              ),
            ),
            const SizedBox(height: 32),
            ElevatedButton.icon(
              onPressed: _scanChildParentConflicts,
              icon: const Icon(Icons.search_rounded),
              label: const Text("Scan for Child / Parent Conflicts"),
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFFE11D48),
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 18),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                elevation: 0,
              ),
            ),
          ],
        ),
      );
    }

    if (_childParentConflicts.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32.0),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Container(
                padding: const EdgeInsets.all(20),
                decoration: BoxDecoration(
                  color: const Color(0xFF10B981).withValues(alpha: 0.1),
                  shape: BoxShape.circle,
                ),
                child: const Icon(Icons.verified_user_rounded, size: 64, color: Color(0xFF10B981)),
              ),
              const SizedBox(height: 24),
              const Text(
                "No Child/Parent Conflicts Found!",
                style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold, color: AppColors.navy),
              ),
              const SizedBox(height: 8),
              const Text(
                "All child and adult profiles are cleanly partitioned with zero token collision risk.",
                style: TextStyle(fontSize: 14, color: AppColors.gray600),
              ),
              const SizedBox(height: 32),
              OutlinedButton.icon(
                onPressed: _scanChildParentConflicts,
                icon: const Icon(Icons.refresh_rounded),
                label: const Text("Scan Again"),
                style: OutlinedButton.styleFrom(
                  foregroundColor: const Color(0xFF10B981),
                  side: const BorderSide(color: Color(0xFF10B981), width: 2),
                  padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                ),
              ),
            ],
          ),
        ),
      );
    }

    final filtered = _filteredConflicts;
    final rawCnicCount = _childParentConflicts.where((c) => c['isRawCnicChild'] == true).length;
    final sharedCnicCount = _childParentConflicts.where((c) => c['hasCnicCollision'] == true).length;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Filter & Batch Actions Bar
        Container(
          decoration: BoxDecoration(
            color: Colors.white,
            border: Border(bottom: BorderSide(color: AppColors.gray200)),
          ),
          padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 24),
          child: Wrap(
            spacing: 12,
            runSpacing: 10,
            alignment: WrapAlignment.spaceBetween,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              // Filter Chips
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  ChoiceChip(
                    label: Text("All (${_childParentConflicts.length})"),
                    selected: _conflictFilter == 'all',
                    onSelected: (_) => setState(() => _conflictFilter = 'all'),
                    selectedColor: const Color(0xFFE11D48).withValues(alpha: 0.15),
                    labelStyle: TextStyle(
                      fontWeight: FontWeight.bold,
                      fontSize: 12,
                      color: _conflictFilter == 'all' ? const Color(0xFFE11D48) : AppColors.gray700,
                    ),
                  ),
                  const SizedBox(width: 8),
                  ChoiceChip(
                    label: Text("Raw CNIC ($rawCnicCount)"),
                    selected: _conflictFilter == 'raw_cnic',
                    onSelected: (_) => setState(() => _conflictFilter = 'raw_cnic'),
                    selectedColor: Colors.orange.withValues(alpha: 0.15),
                    labelStyle: TextStyle(
                      fontWeight: FontWeight.bold,
                      fontSize: 12,
                      color: _conflictFilter == 'raw_cnic' ? Colors.orange.shade800 : AppColors.gray700,
                    ),
                  ),
                  const SizedBox(width: 8),
                  ChoiceChip(
                    label: Text("Shared CNIC ($sharedCnicCount)"),
                    selected: _conflictFilter == 'shared_cnic',
                    onSelected: (_) => setState(() => _conflictFilter = 'shared_cnic'),
                    selectedColor: Colors.purple.withValues(alpha: 0.15),
                    labelStyle: TextStyle(
                      fontWeight: FontWeight.bold,
                      fontSize: 12,
                      color: _conflictFilter == 'shared_cnic' ? Colors.purple.shade800 : AppColors.gray700,
                    ),
                  ),
                ],
              ),

              // Batch Action Buttons
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  OutlinedButton.icon(
                    onPressed: _isProcessing ? null : _scanChildParentConflicts,
                    icon: const Icon(Icons.refresh_rounded, size: 16),
                    label: const Text("Re-scan"),
                    style: OutlinedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                    ),
                  ),
                  const SizedBox(width: 8),
                  ElevatedButton.icon(
                    onPressed: _isProcessing ? null : _batchMigrateAllConflicts,
                    icon: const Icon(Icons.drive_file_rename_outline_rounded, size: 16),
                    label: const Text("Migrate All to Canonical IDs"),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFF10B981),
                      foregroundColor: Colors.white,
                      elevation: 0,
                      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                    ),
                  ),
                  const SizedBox(width: 8),
                  ElevatedButton.icon(
                    onPressed: _isProcessing ? null : _batchDeleteAllConflicts,
                    icon: const Icon(Icons.delete_sweep_rounded, size: 16),
                    label: const Text("Delete Conflicted Registrations (Preserve History)"),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFFE11D48),
                      foregroundColor: Colors.white,
                      elevation: 0,
                      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),

        // Conflicts List
        Expanded(
          child: filtered.isEmpty
              ? Center(
                  child: Text(
                    "No conflict records match the selected filter.",
                    style: TextStyle(color: Colors.grey.shade600),
                  ),
                )
              : ListView.builder(
                  padding: const EdgeInsets.all(24),
                  itemCount: filtered.length,
                  itemBuilder: (context, index) {
                    final item = filtered[index];
                    final hiveKey = (item['hiveKey'] ?? item['patientId']).toString();
                    final name = (item['patientName'] ?? 'Unknown').toString();
                    final cnic = (item['cnic'] ?? '').toString();
                    final guardianCnic = (item['guardianCnic'] ?? '').toString();
                    final branchId = (item['branchId'] ?? '').toString();
                    final isChild = item['isChild'] == true;
                    final isRawCnicChild = item['isRawCnicChild'] == true;
                    final hasCnicCollision = item['hasCnicCollision'] == true;
                    final linkedVisits = (item['linkedVisitsCount'] ?? 0) as int;
                    final linkedPrescriptions = (item['linkedPrescriptionsCount'] ?? 0) as int;
                    final isProcessingThis = _processingConflictKeys.contains(hiveKey);

                    return Card(
                      margin: const EdgeInsets.only(bottom: 14),
                      elevation: 0,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(14),
                        side: BorderSide(color: AppColors.gray200, width: 1),
                      ),
                      child: Padding(
                        padding: const EdgeInsets.all(16.0),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                // Avatar Icon
                                Container(
                                  width: 44,
                                  height: 44,
                                  decoration: BoxDecoration(
                                    color: isChild
                                        ? const Color(0xFFFEF3C7)
                                        : const Color(0xFFDBEAFE),
                                    shape: BoxShape.circle,
                                  ),
                                  alignment: Alignment.center,
                                  child: Text(
                                    isChild ? "👶" : "👤",
                                    style: const TextStyle(fontSize: 22),
                                  ),
                                ),
                                const SizedBox(width: 14),

                                // Profile Details
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      Row(
                                        children: [
                                          Text(
                                            name,
                                            style: const TextStyle(
                                              fontSize: 16,
                                              fontWeight: FontWeight.bold,
                                              color: AppColors.navy,
                                            ),
                                          ),
                                          const SizedBox(width: 8),
                                          Container(
                                            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                                            decoration: BoxDecoration(
                                              color: isChild
                                                  ? const Color(0xFFFEF3C7)
                                                  : const Color(0xFFDBEAFE),
                                              borderRadius: BorderRadius.circular(6),
                                            ),
                                            child: Text(
                                              isChild ? "Child Patient" : "Adult Patient",
                                              style: TextStyle(
                                                fontSize: 11,
                                                fontWeight: FontWeight.bold,
                                                color: isChild
                                                    ? const Color(0xFF92400E)
                                                    : const Color(0xFF1E40AF),
                                              ),
                                            ),
                                          ),
                                          if (branchId.isNotEmpty) ...[
                                            const SizedBox(width: 6),
                                            Container(
                                              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                              decoration: BoxDecoration(
                                                color: AppColors.gray100,
                                                borderRadius: BorderRadius.circular(6),
                                              ),
                                              child: Text(
                                                "Branch: ${branchId.toUpperCase()}",
                                                style: const TextStyle(fontSize: 10.5, fontWeight: FontWeight.w600, color: AppColors.gray700),
                                              ),
                                            ),
                                          ],
                                        ],
                                      ),
                                      const SizedBox(height: 6),
                                      Row(
                                        children: [
                                          Text("CNIC / Key: ", style: TextStyle(fontSize: 12, color: Colors.grey.shade600)),
                                          Text(
                                            cnic.isNotEmpty ? cnic : hiveKey,
                                            style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold, fontFamily: 'monospace'),
                                          ),
                                          if (guardianCnic.isNotEmpty) ...[
                                            const SizedBox(width: 14),
                                            Text("Guardian CNIC: ", style: TextStyle(fontSize: 12, color: Colors.grey.shade600)),
                                            Text(
                                              guardianCnic,
                                              style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold, fontFamily: 'monospace'),
                                            ),
                                          ],
                                        ],
                                      ),
                                    ],
                                  ),
                                ),

                                // Conflict Badges
                                Column(
                                  crossAxisAlignment: CrossAxisAlignment.end,
                                  children: [
                                    if (isRawCnicChild)
                                      Container(
                                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                                        decoration: BoxDecoration(
                                          color: Colors.orange.shade50,
                                          borderRadius: BorderRadius.circular(6),
                                          border: Border.all(color: Colors.orange.shade200),
                                        ),
                                        child: Text(
                                          "⚠️ Raw Parent CNIC",
                                          style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: Colors.orange.shade900),
                                        ),
                                      ),
                                    if (hasCnicCollision) ...[
                                      const SizedBox(height: 4),
                                      Container(
                                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                                        decoration: BoxDecoration(
                                          color: Colors.purple.shade50,
                                          borderRadius: BorderRadius.circular(6),
                                          border: Border.all(color: Colors.purple.shade200),
                                        ),
                                        child: Text(
                                          "⚡ CNIC Shared with Other Profile",
                                          style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: Colors.purple.shade900),
                                        ),
                                      ),
                                    ],
                                  ],
                                ),
                              ],
                            ),

                            const SizedBox(height: 12),
                            Divider(height: 1, color: AppColors.gray200),
                            const SizedBox(height: 10),

                            // Medical History Preservation & Resolution Actions
                            Row(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: [
                                // History preservation badge
                                Container(
                                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                                  decoration: BoxDecoration(
                                    color: const Color(0xFF0D9488).withValues(alpha: 0.1),
                                    borderRadius: BorderRadius.circular(6),
                                    border: Border.all(color: const Color(0xFF0D9488).withValues(alpha: 0.3)),
                                  ),
                                  child: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      const Icon(Icons.shield_outlined, size: 14, color: Color(0xFF0D9488)),
                                      const SizedBox(width: 6),
                                      Text(
                                        "History Preserved: $linkedVisits Visits • $linkedPrescriptions Prescriptions",
                                        style: const TextStyle(fontSize: 11.5, fontWeight: FontWeight.bold, color: Color(0xFF0D9488)),
                                      ),
                                    ],
                                  ),
                                ),

                                // Actions
                                if (isProcessingThis)
                                  const SizedBox(
                                    width: 20,
                                    height: 20,
                                    child: CircularProgressIndicator(strokeWidth: 2, color: Color(0xFFE11D48)),
                                  )
                                else
                                  Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      OutlinedButton.icon(
                                        onPressed: () => _deleteConflictRegistration(item),
                                        icon: const Icon(Icons.delete_outline_rounded, size: 16),
                                        label: const Text("Delete Registration (Keep History)"),
                                        style: OutlinedButton.styleFrom(
                                          foregroundColor: const Color(0xFFE11D48),
                                          side: const BorderSide(color: Color(0xFFE11D48)),
                                          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                                        ),
                                      ),
                                      const SizedBox(width: 8),
                                      ElevatedButton.icon(
                                        onPressed: () => _migrateConflictToChildId(item),
                                        icon: const Icon(Icons.drive_file_rename_outline_rounded, size: 16),
                                        label: const Text("Migrate to Child ID"),
                                        style: ElevatedButton.styleFrom(
                                          backgroundColor: const Color(0xFF10B981),
                                          foregroundColor: Colors.white,
                                          elevation: 0,
                                          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                                        ),
                                      ),
                                    ],
                                  ),
                              ],
                            ),
                          ],
                        ),
                      ),
                    );
                  },
                ),
        ),
      ],
    );
  }

  Widget _buildManualReviewTab() {
    if (_isScanning) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const CircularProgressIndicator(color: AppColors.primary),
            const SizedBox(height: 20),
            const Text(
              "Scanning all patient documents...",
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: AppColors.gray800),
            ),
            const SizedBox(height: 8),
            Text(
              "This scans branches and local lists to build indexes.",
              style: TextStyle(fontSize: 13, color: AppColors.gray500),
            ),
          ],
        ),
      );
    }

    if (!_hasScanned) {
      return Padding(
        padding: const EdgeInsets.all(24.0),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.manage_search_rounded, size: 72, color: AppColors.primary.withValues(alpha: 0.8)),
            const SizedBox(height: 24),
            const Text(
              "Interactive Duplicate Resolution",
              style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold, color: AppColors.navy),
            ),
            const SizedBox(height: 12),
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 500),
              child: Text(
                "Scan the database to search for patients with duplicate accounts. "
                "You can inspect patient data side-by-side grouped by name (A to Z), "
                "elect which record is the correct version, and merge them cleanly.",
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 14, color: AppColors.gray600, height: 1.5),
              ),
            ),
            const SizedBox(height: 32),
            ElevatedButton.icon(
              onPressed: _scanForDuplicates,
              icon: const Icon(Icons.search),
              label: const Text("Scan Database for Duplicates"),
              style: ElevatedButton.styleFrom(
                backgroundColor: AppColors.primary,
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 18),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                elevation: 0,
              ),
            ),
          ],
        ),
      );
    }

    if (_duplicatesByLetter.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32.0),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Container(
                padding: const EdgeInsets.all(20),
                decoration: BoxDecoration(
                  color: AppColors.primaryLight,
                  shape: BoxShape.circle,
                ),
                child: const Icon(Icons.done_all_rounded, size: 64, color: AppColors.primary),
              ),
              const SizedBox(height: 24),
              const Text(
                "No Duplicates Found!",
                style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold, color: AppColors.navy),
              ),
              const SizedBox(height: 8),
              const Text(
                "Your patient database contains no duplicate profiles.",
                style: TextStyle(fontSize: 14, color: AppColors.gray600),
              ),
              const SizedBox(height: 32),
              OutlinedButton.icon(
                onPressed: _scanForDuplicates,
                icon: const Icon(Icons.refresh),
                label: const Text("Scan Again"),
                style: OutlinedButton.styleFrom(
                  foregroundColor: AppColors.primary,
                  side: const BorderSide(color: AppColors.primary, width: 2),
                  padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                ),
              ),
            ],
          ),
        ),
      );
    }

    final letters = _duplicatesByLetter.keys.toList()..sort();
    final currentLetterGroups = _duplicatesByLetter[_selectedLetter] ?? {};

    int totalGroups = 0;
    int totalDocs = 0;
    _duplicatesByLetter.forEach((letter, groups) {
      totalGroups += groups.length;
      for (final docList in groups.values) {
        totalDocs += docList.length;
      }
    });

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // A-Z Horizontal Chip Bar
        Container(
          decoration: BoxDecoration(
            color: Colors.white,
            border: Border(bottom: BorderSide(color: AppColors.gray200)),
          ),
          padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    "Select Patient First Letter:",
                    style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: AppColors.gray500),
                  ),
                  Text(
                    "Total Duplicates: $totalGroups groups ($totalDocs profiles)",
                    style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: AppColors.primary),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(
                  children: letters.map((letter) {
                    final isSelected = _selectedLetter == letter;
                    final count = _duplicatesByLetter[letter]?.length ?? 0;
                    return Padding(
                      padding: const EdgeInsets.only(right: 8.0),
                      child: GestureDetector(
                        onTap: () => setState(() => _selectedLetter = letter),
                        child: AnimatedContainer(
                          duration: const Duration(milliseconds: 200),
                          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                          decoration: BoxDecoration(
                            color: isSelected ? AppColors.primary : AppColors.gray100,
                            borderRadius: BorderRadius.circular(20),
                            border: Border.all(
                              color: isSelected ? AppColors.primaryDark : AppColors.gray200,
                            ),
                          ),
                          child: Row(
                            children: [
                              Text(
                                letter,
                                style: TextStyle(
                                  fontWeight: FontWeight.bold,
                                  color: isSelected ? Colors.white : AppColors.gray800,
                                ),
                              ),
                              const SizedBox(width: 6),
                              Container(
                                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                decoration: BoxDecoration(
                                  color: isSelected ? Colors.white.withValues(alpha: 0.2) : AppColors.gray300,
                                  borderRadius: BorderRadius.circular(10),
                                ),
                                child: Text(
                                  count.toString(),
                                  style: TextStyle(
                                    fontSize: 11,
                                    fontWeight: FontWeight.bold,
                                    color: isSelected ? Colors.white : AppColors.gray700,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    );
                  }).toList(),
                ),
              ),
            ],
          ),
        ),

        // Letter header options
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 16, 24, 8),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                "Duplicates under '$_selectedLetter' (${currentLetterGroups.length} group(s))",
                style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: AppColors.navy),
              ),
              ElevatedButton.icon(
                onPressed: _isProcessing ? null : _mergeAllUnderSelectedLetter,
                icon: const Icon(Icons.merge_type_rounded, size: 18),
                label: Text("Merge All under '$_selectedLetter'"),
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppColors.primaryLight,
                  foregroundColor: AppColors.primary,
                  elevation: 0,
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                ),
              ),
            ],
          ),
        ),

        // Scrollable list of duplicate groups
        Expanded(
          child: ListView.builder(
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 8),
            itemCount: currentLetterGroups.length,
            itemBuilder: (context, index) {
              final groupKey = currentLetterGroups.keys.elementAt(index);
              final docs = currentLetterGroups[groupKey]!;
              return _buildDuplicateGroupCard(groupKey, docs);
            },
          ),
        ),
      ],
    );
  }
  Widget _buildDuplicateGroupCard(String groupKey, List<_LocalDocItem> docs) {
    final firstDoc = docs.first;
    final firstData = firstDoc.data() as Map<String, dynamic>? ?? {};
    final patientName = firstData['name'] ?? 'Unknown';
    final branchId = firstData['branchId'] ?? 'unknown';
    final isMerging = _mergingGroupKeys.contains(groupKey);
    final isMerged = _mergedGroupKeys.contains(groupKey);
    final isDisappearing = _disappearingGroupKeys.contains(groupKey);

    return AnimatedSize(
      key: ValueKey("size_$groupKey"),
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeInOut,
      clipBehavior: Clip.hardEdge,
      child: isDisappearing
          ? const SizedBox(height: 0, width: double.infinity)
          : AnimatedSwitcher(
              duration: const Duration(milliseconds: 400),
              transitionBuilder: (Widget child, Animation<double> animation) {
                return FadeTransition(
                  opacity: animation,
                  child: SizeTransition(
                    sizeFactor: animation,
                    axisAlignment: -1.0,
                    child: child,
                  ),
                );
              },
              child: isMerged
                  ? Card(
                      key: ValueKey("merged_$groupKey"),
                      margin: const EdgeInsets.only(bottom: 24),
                      elevation: 0,
                      color: Colors.green.shade50,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(16),
                        side: BorderSide(color: Colors.green.shade200, width: 1.5),
                      ),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 24.0, vertical: 20.0),
                        child: Row(
                          children: [
                            Container(
                              padding: const EdgeInsets.all(8),
                              decoration: BoxDecoration(
                                color: Colors.green.shade100,
                                shape: BoxShape.circle,
                              ),
                              child: Icon(
                                Icons.check_circle_rounded,
                                color: Colors.green.shade700,
                                size: 28,
                              ),
                            ),
                            const SizedBox(width: 16),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    "$patientName Merged Successfully",
                                    style: TextStyle(
                                      fontSize: 16,
                                      fontWeight: FontWeight.bold,
                                      color: Colors.green.shade900,
                                    ),
                                  ),
                                  const SizedBox(height: 4),
                                  Text(
                                    "Database references and prescriptions updated live.",
                                    style: TextStyle(
                                      fontSize: 12,
                                      color: Colors.green.shade700,
                                      fontWeight: FontWeight.w500,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),
                    )
                  : Card(
                      key: ValueKey("normal_$groupKey"),
                      margin: const EdgeInsets.only(bottom: 24),
                      elevation: 0,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(16),
                        side: BorderSide(color: AppColors.gray200, width: 1),
                      ),
                      child: Padding(
                        padding: const EdgeInsets.all(20.0),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            // Group Header
                            Row(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: [
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        patientName,
                                        style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800, color: AppColors.navy),
                                      ),
                                      const SizedBox(height: 4),
                                      Row(
                                        children: [
                                          Icon(Icons.location_on_outlined, size: 14, color: AppColors.gray500),
                                          const SizedBox(width: 4),
                                          Text(
                                            "Branch: ${branchId.toUpperCase()}",
                                            style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: AppColors.gray500),
                                          ),
                                          const SizedBox(width: 16),
                                          Icon(Icons.copy_all_outlined, size: 14, color: AppColors.gray500),
                                          const SizedBox(width: 4),
                                          Text(
                                            "${docs.length} Duplicate Records",
                                            style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: AppColors.gray500),
                                          ),
                                        ],
                                      ),
                                    ],
                                  ),
                                ),
                                TextButton.icon(
                                  onPressed: isMerging ? null : () => _ignoreGroup(groupKey),
                                  icon: const Icon(Icons.visibility_off_outlined, size: 16),
                                  label: const Text("Ignore Group"),
                                  style: TextButton.styleFrom(
                                    foregroundColor: AppColors.gray500,
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 16),
                            Divider(color: AppColors.gray200, height: 1),
                            const SizedBox(height: 16),

                            // Responsive Layout Builder using Wrap for side-by-side or multi-row card layouts
                            LayoutBuilder(
                              builder: (context, constraints) {
                                final cardWidth = 280.0;
                                final singleCardFullWidth = constraints.maxWidth < cardWidth;
                                
                                return Wrap(
                                  spacing: 12,
                                  runSpacing: 12,
                                  children: docs.map((doc) {
                                    return SizedBox(
                                      width: singleCardFullWidth ? constraints.maxWidth : cardWidth,
                                      child: _buildDocDetailCard(groupKey, doc, docs),
                                    );
                                  }).toList(),
                                );
                              },
                            ),

                            const SizedBox(height: 20),
                            
                            // Resolve Actions row
                            Row(
                              mainAxisAlignment: MainAxisAlignment.end,
                              children: [
                                if (isMerging)
                                  Row(
                                    children: [
                                      const SizedBox(
                                        width: 20,
                                        height: 20,
                                        child: CircularProgressIndicator(strokeWidth: 2, color: AppColors.primary),
                                      ),
                                      const SizedBox(width: 12),
                                      Text(
                                        "Merging records...",
                                        style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold, color: AppColors.gray600),
                                      ),
                                    ],
                                  )
                                else
                                  ElevatedButton.icon(
                                    onPressed: () => _mergeSingleGroup(groupKey, branchId, docs),
                                    icon: const Icon(Icons.check_circle_outline),
                                    label: const Text("Merge Group Now"),
                                    style: ElevatedButton.styleFrom(
                                      backgroundColor: AppColors.primary,
                                      foregroundColor: Colors.white,
                                      elevation: 0,
                                      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
                                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                                    ),
                                  ),
                              ],
                            ),
                          ],
                        ),
                      ),
                    ),
            ),
    );
  }
  Widget _buildDocDetailCard(String groupKey, _LocalDocItem doc, List<_LocalDocItem> allDocs) {
    final data = doc.data() as Map<String, dynamic>? ?? {};
    final selectedMasterId = _electedMasterIds[groupKey];
    final isSelected = selectedMasterId == doc.id;
    
    // Determine the recommended master
    final bestMaster = allDocs.reduce((a, b) {
      final scoreA = _scoreDoc(a);
      final scoreB = _scoreDoc(b);
      return scoreA >= scoreB ? a : b;
    });
    final isRecommended = bestMaster.id == doc.id;

    // Check if ID is authoritative (exactly 13 digit CNIC or child composite id)
    final idIsAuthoritative = RegExp(r'^\d{13}$').hasMatch(doc.id) || RegExp(r'^\d{13}_child_.+$').hasMatch(doc.id);

    final status = data['status']?.toString() ?? 'N/A';
    final docId = doc.id;
    final name = data['name']?.toString() ?? 'N/A';
    final cnic = data['cnic']?.toString() ?? 'N/A';
    final gCnic = data['guardianCnic']?.toString() ?? 'N/A';
    final phone = data['phone']?.toString() ?? 'N/A';
    final age = data['age']?.toString() ?? 'N/A';
    final gender = data['gender']?.toString() ?? 'N/A';
    final dob = _parseDate(data['dob']);
    final created = _parseDate(data['createdAt']);
    final score = _scoreDoc(doc);

    return InkWell(
      onTap: () => setState(() => _electedMasterIds[groupKey] = doc.id),
      borderRadius: BorderRadius.circular(12),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        decoration: BoxDecoration(
          color: isSelected ? AppColors.primaryLight.withValues(alpha: 0.5) : Colors.white,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: isSelected ? AppColors.primary : AppColors.gray200,
            width: isSelected ? 2.5 : 1,
          ),
          boxShadow: isSelected
              ? [BoxShadow(color: AppColors.primary.withValues(alpha: 0.1), blurRadius: 8, offset: const Offset(0, 4))]
              : null,
        ),
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Top Selection State & Badges
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Row(
                  children: [
                    Icon(
                      isSelected ? Icons.radio_button_checked : Icons.radio_button_off,
                      color: isSelected ? AppColors.primary : AppColors.gray400,
                      size: 20,
                    ),
                    const SizedBox(width: 8),
                    Text(
                      isSelected ? "Keep as Master" : "Select Master",
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.bold,
                        color: isSelected ? AppColors.primary : AppColors.gray600,
                      ),
                    ),
                  ],
                ),
                if (isRecommended)
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                    decoration: BoxDecoration(
                      color: AppColors.amberLight,
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: AppColors.amber.withValues(alpha: 0.3)),
                    ),
                    child: const Text(
                      "RECOMMENDED",
                      style: TextStyle(fontSize: 9, fontWeight: FontWeight.w800, color: AppColors.amber),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 12),

            // Document ID Badge
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: idIsAuthoritative ? Colors.purple.shade50 : AppColors.gray100,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(
                  color: idIsAuthoritative ? Colors.purple.shade200 : AppColors.gray300,
                ),
              ),
              child: Row(
                children: [
                  Icon(
                    idIsAuthoritative ? Icons.check_circle : Icons.help_outline,
                    size: 14,
                    color: idIsAuthoritative ? Colors.purple.shade700 : AppColors.gray500,
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      docId,
                      style: TextStyle(
                        fontFamily: 'monospace',
                        fontSize: 11,
                        fontWeight: FontWeight.bold,
                        color: idIsAuthoritative ? Colors.purple.shade800 : AppColors.gray800,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),

            // Properties list
            _buildPropRow("Name", name, isBold: true),
            _buildPropRow("CNIC", cnic),
            if (gCnic != 'N/A' && gCnic.isNotEmpty) _buildPropRow("Guard. CNIC", gCnic),
            _buildPropRow("Phone", phone),
            _buildPropRow("Age / Gender", "$age / $gender"),
            _buildPropRow("Date of Birth", dob),
            _buildPropRow("Joined", created),
            
            const SizedBox(height: 8),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                // Status Chip
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                  decoration: BoxDecoration(
                    color: _getStatusColor(status).withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Text(
                    status,
                    style: TextStyle(
                      fontSize: 10,
                      fontWeight: FontWeight.w900,
                      color: _getStatusColor(status),
                    ),
                  ),
                ),
                
                // Richness Score
                Text(
                  "Data Score: $score",
                  style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: AppColors.gray500),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildPropRow(String label, String value, {bool isBold = false}) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6.0),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 80,
            child: Text(
              label,
              style: TextStyle(fontSize: 11, color: AppColors.gray500, fontWeight: FontWeight.w500),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: TextStyle(
                fontSize: 11,
                color: AppColors.gray800,
                fontWeight: isBold ? FontWeight.bold : FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Color _getStatusColor(String status) {
    switch (status.trim().toLowerCase()) {
      case 'zakat':
        return const Color(0xFF1565C0);
      case 'non-zakat':
        return const Color(0xFF6A1B9A);
      case 'gmwf':
        return const Color(0xFF2E7D32);
      default:
        return AppColors.gray500;
    }
  }

  Widget _buildAutomatedTab() {
    return Padding(
      padding: const EdgeInsets.all(24.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _buildInfoCard(),
          const SizedBox(height: 24),
          if (_isProcessing) ...[
            Text(
              "Processing: $_currentBranch",
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 8),
            LinearProgressIndicator(
              value: _progress,
              backgroundColor: AppColors.gray200,
              color: AppColors.primary,
              minHeight: 10,
              borderRadius: BorderRadius.circular(5),
            ),
            const SizedBox(height: 24),
          ],
          Expanded(
            child: Container(
              decoration: BoxDecoration(
                color: Colors.black.withValues(alpha: 0.05),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: AppColors.gray200),
              ),
              child: ListView.builder(
                padding: const EdgeInsets.all(16),
                itemCount: _logs.length,
                itemBuilder: (context, index) {
                  final log = _logs[index];
                  Color textColor = AppColors.gray800;
                  if (log.contains("❌")) textColor = Colors.red;
                  if (log.contains("✨")) textColor = Colors.green;
                  if (log.contains("🔧")) textColor = Colors.orange.shade700;
                  return Padding(
                    padding: const EdgeInsets.only(bottom: 4),
                    child: Text(
                      log,
                      style: TextStyle(
                        fontFamily: 'monospace',
                        fontSize: 13,
                        color: textColor,
                      ),
                    ),
                  );
                },
              ),
            ),
          ),
          const SizedBox(height: 24),
          Row(
            children: [
              Expanded(
                child: ElevatedButton.icon(
                  onPressed: _isProcessing ? null : _startCleanup,
                  icon: const Icon(Icons.cleaning_services),
                  label: Text(
                    _isProcessing ? "Cleaning..." : "Start Deep Deduplication",
                  ),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppColors.primary,
                    padding: const EdgeInsets.symmetric(vertical: 16),
                  ),
                ),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: ElevatedButton.icon(
                  onPressed: _isProcessing ? null : _fixAllLegacyDataSchema,
                  icon: const Icon(Icons.auto_fix_high),
                  label: Text(
                    _isProcessing ? "Processing..." : "Fix & Heal All Legacy Data",
                  ),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF10B981),
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(vertical: 16),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          ElevatedButton.icon(
            onPressed: _isProcessing ? null : _runStructureSanitizer,
            icon: const Icon(Icons.delete_sweep_rounded),
            label: Text(
              _isProcessing ? "Sanitizing Structure..." : "Purge Bogus Branches & Root Bloat",
              style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14),
            ),
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFFDC2626),
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(vertical: 16),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildInfoCard() {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.blue.shade50,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.blue.shade200),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.info_outline, color: Colors.blue.shade700),
          const SizedBox(width: 16),
          const Expanded(
            child: Text(
              "Performs a global scan across all branches and collections. "
              "Identifies duplicates to merge and single patients with non-canonical IDs (e.g. formatted CNICs) to fix. "
              "Correctly saved single patients are ignored. "
              "Prescriptions, serials, and dispensary records are re-pointed using high-speed global queries. "
              "CNIC and ID normalization is enforced across all linked documents.",
              style: TextStyle(fontSize: 13),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPrescriptionCleanupsTab() {
    if (_isScanningPrescriptions) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const CircularProgressIndicator(color: AppColors.primary),
            const SizedBox(height: 20),
            const Text(
              "Scanning local prescription documents in Hive...",
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: AppColors.gray800),
            ),
            const SizedBox(height: 8),
            Text(
              "Matching local serial entries and checking prescription data...",
              style: TextStyle(fontSize: 13, color: AppColors.gray500),
            ),
          ],
        ),
      );
    }

    if (!_hasScannedPrescriptions) {
      return Padding(
        padding: const EdgeInsets.all(24.0),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.assignment_turned_in_outlined, size: 72, color: AppColors.primary.withValues(alpha: 0.8)),
            const SizedBox(height: 24),
            const Text(
              "Prescription Data Cleanups",
              style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold, color: AppColors.navy),
            ),
            const SizedBox(height: 12),
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 500),
              child: Text(
                "Scan local Hive storage to identify prescription documents needing consolidation. "
                "The tool will locate their corresponding daily serial entries, "
                "merge the prescription data inside them, and delete the redundant "
                "local records before syncing all changes in the background.",
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 14, color: AppColors.gray600, height: 1.5),
              ),
            ),
            const SizedBox(height: 32),
            ElevatedButton.icon(
              onPressed: _scanPrescriptions,
              icon: const Icon(Icons.search),
              label: const Text("Scan Local Prescriptions"),
              style: ElevatedButton.styleFrom(
                backgroundColor: AppColors.primary,
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 18),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                elevation: 0,
              ),
            ),
          ],
        ),
      );
    }

    if (_prescriptionMigrationItems.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32.0),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Container(
                padding: const EdgeInsets.all(20),
                decoration: const BoxDecoration(
                  color: Color(0xFFE8F5E9),
                  shape: BoxShape.circle,
                ),
                child: const Icon(Icons.done_all_rounded, size: 64, color: Colors.green),
              ),
              const SizedBox(height: 24),
              const Text(
                "No Redundant Prescriptions Found!",
                style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold, color: AppColors.navy),
              ),
              const SizedBox(height: 8),
              const Text(
                "All prescription documents have been successfully consolidated into local visit entries.",
                style: TextStyle(fontSize: 14, color: AppColors.gray600),
              ),
              const SizedBox(height: 32),
              OutlinedButton.icon(
                onPressed: _scanPrescriptions,
                icon: const Icon(Icons.refresh),
                label: const Text("Scan Again"),
                style: OutlinedButton.styleFrom(
                  foregroundColor: AppColors.primary,
                  side: const BorderSide(color: AppColors.primary, width: 2),
                  padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                ),
              ),
            ],
          ),
        ),
      );
    }

    final items = _prescriptionMigrationItems.values.toList();
    final zakatCount = items.where((i) => i['queueType'] == 'zakat').length;
    final nonZakatCount = items.where((i) => i['queueType'] == 'non-zakat').length;
    final otherCount = items.length - zakatCount - nonZakatCount;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Prescription Summary Panel
        Container(
          decoration: BoxDecoration(
            color: Colors.white,
            border: Border(bottom: BorderSide(color: AppColors.gray200)),
          ),
          padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 24),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      "Pending Cleanups: ${items.length} prescriptions",
                      style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: AppColors.navy),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      "Zakat: $zakatCount | Non-Zakat: $nonZakatCount | Others: $otherCount",
                      style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: AppColors.gray500),
                    ),
                  ],
                ),
              ),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  OutlinedButton.icon(
                    onPressed: _isProcessing ? null : _unifyAllBranchesSerialsDispensary,
                    icon: const Icon(Icons.hub_rounded, size: 16),
                    label: const Text("Unify All Branches"),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: const Color(0xFF0D9488),
                      side: const BorderSide(color: Color(0xFF0D9488), width: 1.5),
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                    ),
                  ),
                  const SizedBox(width: 12),
                  ElevatedButton.icon(
                    onPressed: _isProcessing ? null : _mergeAndCleanAllPrescriptions,
                    icon: const Icon(Icons.cleaning_services),
                    label: const Text("Bulk Merge & Clean All"),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: AppColors.primary,
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                      elevation: 0,
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),

        // Prescription list
        Expanded(
          child: ListView.builder(
            padding: const EdgeInsets.all(24),
            itemCount: items.length,
            itemBuilder: (context, index) {
              final item = items[index];
              return _buildPrescriptionCard(item);
            },
          ),
        ),
      ],
    );
  }

  Widget _buildPrescriptionCard(Map<String, dynamic> item) {
    final key = item['key'] as String;
    final patientName = item['patientName'] as String;
    final serial = item['serial'] as String;
    final branchId = item['branchId'] as String;
    final dateKey = item['dateKey'] as String;
    final queueType = item['queueType'] as String;
    final status = item['status'] as String;
    final medicines = item['medicines'] as List<dynamic>;
    final isProcessing = _processingPrescriptionKeys.contains(key);

    Color statusColor;
    String statusLabel;
    IconData statusIcon;

    if (status == 'already_merged') {
      statusColor = Colors.green;
      statusLabel = "Already Merged (Clean)";
      statusIcon = Icons.check_circle_outline;
    } else if (status == 'needs_merge') {
      statusColor = Colors.orange;
      statusLabel = "Needs Merge";
      statusIcon = Icons.sync;
    } else {
      statusColor = Colors.red;
      statusLabel = "Orphaned (No Serial Visit)";
      statusIcon = Icons.warning_amber_rounded;
    }

    return Card(
      margin: const EdgeInsets.only(bottom: 16),
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: AppColors.gray200, width: 1),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Row 1: Header info & Status Badge
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        patientName,
                        style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: AppColors.navy),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        "Branch: ${branchId.toUpperCase()} | Serial: $serial | Date: $dateKey | Queue: $queueType",
                        style: TextStyle(fontSize: 12, color: AppColors.gray600),
                      ),
                    ],
                  ),
                ),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                  decoration: BoxDecoration(
                    color: statusColor.withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: statusColor.withValues(alpha: 0.3)),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(statusIcon, color: statusColor, size: 14),
                      const SizedBox(width: 4),
                      Text(
                        statusLabel,
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.bold,
                          color: statusColor,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Divider(color: AppColors.gray200, height: 1),
            const SizedBox(height: 12),

            // Row 2: Medicines List
            const Text(
              "Prescribed Medicines:",
              style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: AppColors.navy),
            ),
            const SizedBox(height: 8),
            if (medicines.isEmpty)
              const Text("No medicines in this prescription.", style: TextStyle(fontSize: 12, color: Colors.grey))
            else
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: medicines.map<Widget>((med) {
                  final name = med['name'] ?? 'Unknown Medicine';
                  final qty = med['quantity'] ?? 1;
                  return Chip(
                    label: Text("$name (x$qty)"),
                    backgroundColor: AppColors.gray100,
                    labelStyle: const TextStyle(fontSize: 11, color: AppColors.gray800),
                    visualDensity: VisualDensity.compact,
                  );
                }).toList(),
              ),

            const SizedBox(height: 16),
            
            // Row 3: Action Buttons
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                if (isProcessing)
                  const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2, color: AppColors.primary),
                  )
                else if (status == 'orphaned')
                  Row(
                    children: [
                      TextButton(
                        onPressed: () => _mergeAndCleanPrescription(key, forceRecreateSerial: false),
                        style: TextButton.styleFrom(foregroundColor: Colors.red),
                        child: const Text("Delete Prescription Only"),
                      ),
                      const SizedBox(width: 12),
                      ElevatedButton(
                        onPressed: () => _mergeAndCleanPrescription(key, forceRecreateSerial: true),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: Colors.green,
                          foregroundColor: Colors.white,
                          elevation: 0,
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                        ),
                        child: const Text("Re-create Serial & Clean"),
                      ),
                    ],
                  )
                else if (status == 'needs_merge')
                  ElevatedButton(
                    onPressed: () => _mergeAndCleanPrescription(key, forceRecreateSerial: false),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: AppColors.primary,
                      foregroundColor: Colors.white,
                      elevation: 0,
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                    ),
                    child: const Text("Merge & Clean"),
                  )
                else // already_merged
                  ElevatedButton(
                    onPressed: () => _mergeAndCleanPrescription(key, forceRecreateSerial: false),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.green,
                      foregroundColor: Colors.white,
                      elevation: 0,
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                    ),
                    child: const Text("Delete Prescription (Safe)"),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

// ─── Diagnostic Preview Model & Interactive Review Modal ──────────────────────

class _PatientRepairPreviewItem {
  final String key;
  final String branchId;
  final String patientName;
  final String cnic;
  final String guardianCnic;
  final String currentPatientId;
  final String proposedPatientId;
  final bool? currentIsAdult;
  final bool proposedIsAdult;
  final String recordType;
  final String source;
  final Map<String, dynamic> rawData;
  bool isSelected;

  _PatientRepairPreviewItem({
    required this.key,
    required this.branchId,
    required this.patientName,
    required this.cnic,
    required this.guardianCnic,
    required this.currentPatientId,
    required this.proposedPatientId,
    required this.currentIsAdult,
    required this.proposedIsAdult,
    required this.recordType,
    required this.source,
    required this.rawData,
    this.isSelected = true,
  });
}

class _PatientRepairPreviewModal extends StatefulWidget {
  final List<_PatientRepairPreviewItem> initialItems;
  final Future<void> Function(List<_PatientRepairPreviewItem> selectedItems) onApplyFixes;

  const _PatientRepairPreviewModal({
    required this.initialItems,
    required this.onApplyFixes,
  });

  @override
  State<_PatientRepairPreviewModal> createState() => _PatientRepairPreviewModalState();
}

class _PatientRepairPreviewModalState extends State<_PatientRepairPreviewModal> {
  late List<_PatientRepairPreviewItem> _items;
  String _searchQuery = '';
  bool _selectAll = true;

  @override
  void initState() {
    super.initState();
    _items = List.from(widget.initialItems);
  }

  List<_PatientRepairPreviewItem> get _filteredItems {
    if (_searchQuery.trim().isEmpty) return _items;
    final q = _searchQuery.toLowerCase().trim();
    return _items.where((i) {
      return i.patientName.toLowerCase().contains(q) ||
          i.cnic.toLowerCase().contains(q) ||
          i.guardianCnic.toLowerCase().contains(q) ||
          i.proposedPatientId.toLowerCase().contains(q);
    }).toList();
  }

  int get _selectedCount => _items.where((i) => i.isSelected).length;

  @override
  Widget build(BuildContext context) {
    final filtered = _filteredItems;
    final theme = Theme.of(context);

    return Dialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      insetPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 32),
      child: Container(
        width: 850,
        height: 650,
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Header Row
            Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: const Color(0xFF0D9488).withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: const Icon(Icons.fact_check_rounded, color: Color(0xFF0D9488), size: 28),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        "Patient ID & Schema Repair Preview",
                        style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: AppColors.navy),
                      ),
                      const SizedBox(height: 3),
                      Text(
                        "Review proposed individual IDs and schema updates before applying changes.",
                        style: TextStyle(fontSize: 12.5, color: Colors.grey.shade600),
                      ),
                    ],
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.close_rounded),
                  onPressed: () => Navigator.pop(context),
                ),
              ],
            ),
            const SizedBox(height: 16),
            const Divider(height: 1),
            const SizedBox(height: 14),

            // Search Bar & Filter Controls
            Row(
              children: [
                Expanded(
                  child: TextField(
                    decoration: InputDecoration(
                      hintText: "Search patient name, CNIC, or ID...",
                      prefixIcon: const Icon(Icons.search, size: 20),
                      isDense: true,
                      filled: true,
                      fillColor: AppColors.gray50,
                      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(10),
                        borderSide: BorderSide(color: AppColors.gray300),
                      ),
                    ),
                    onChanged: (val) => setState(() => _searchQuery = val),
                  ),
                ),
                const SizedBox(width: 14),
                FilterChip(
                  label: Text(_selectAll ? "Deselect All" : "Select All"),
                  selected: _selectAll,
                  onSelected: (val) {
                    setState(() {
                      _selectAll = val;
                      for (final it in _items) {
                        it.isSelected = val;
                      }
                    });
                  },
                ),
              ],
            ),
            const SizedBox(height: 14),

            // Diagnostic Summary Counter
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
              decoration: BoxDecoration(
                color: const Color(0xFFF0FDF4),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: const Color(0xFFBBF7D0)),
              ),
              child: Row(
                children: [
                  const Icon(Icons.info_outline, size: 16, color: Color(0xFF16A34A)),
                  const SizedBox(width: 8),
                  Text(
                    "Total Detected: ${_items.length} records  •  Selected for Fix: $_selectedCount records",
                    style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600, color: Color(0xFF15803D)),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),

            // List of Review Cards
            Expanded(
              child: filtered.isEmpty
                  ? Center(
                      child: Text(
                        _searchQuery.isEmpty ? "No records require repair." : "No matching records found for '$_searchQuery'",
                        style: TextStyle(color: Colors.grey.shade600),
                      ),
                    )
                  : ListView.builder(
                      itemCount: filtered.length,
                      itemBuilder: (ctx, idx) {
                        final item = filtered[idx];
                        return Card(
                          margin: const EdgeInsets.only(bottom: 10),
                          elevation: 0,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(10),
                            side: BorderSide(
                              color: item.isSelected ? const Color(0xFF0D9488) : AppColors.gray200,
                              width: item.isSelected ? 1.5 : 1.0,
                            ),
                          ),
                          child: Padding(
                            padding: const EdgeInsets.all(12),
                            child: Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Checkbox(
                                  value: item.isSelected,
                                  activeColor: const Color(0xFF0D9488),
                                  onChanged: (val) {
                                    setState(() {
                                      item.isSelected = val ?? false;
                                      _selectAll = _items.every((i) => i.isSelected);
                                    });
                                  },
                                ),
                                const SizedBox(width: 8),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      Row(
                                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                        children: [
                                          Text(
                                            item.patientName,
                                            style: const TextStyle(fontSize: 14.5, fontWeight: FontWeight.bold, color: AppColors.navy),
                                          ),
                                          Container(
                                            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                                            decoration: BoxDecoration(
                                              color: AppColors.gray100,
                                              borderRadius: BorderRadius.circular(6),
                                            ),
                                            child: Text(
                                              item.recordType,
                                              style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: AppColors.gray700),
                                            ),
                                          ),
                                        ],
                                      ),
                                      const SizedBox(height: 6),
                                      Row(
                                        children: [
                                          if (item.cnic.isNotEmpty)
                                            Text(
                                              "CNIC: ${item.cnic}  ",
                                              style: TextStyle(fontSize: 12, color: Colors.grey.shade700),
                                            ),
                                          if (item.guardianCnic.isNotEmpty)
                                            Text(
                                              "Guardian: ${item.guardianCnic}  ",
                                              style: TextStyle(fontSize: 12, color: Colors.grey.shade700),
                                            ),
                                        ],
                                      ),
                                      const SizedBox(height: 8),
                                      // Diff Chip Box
                                      Container(
                                        padding: const EdgeInsets.all(8),
                                        decoration: BoxDecoration(
                                          color: AppColors.gray50,
                                          borderRadius: BorderRadius.circular(6),
                                        ),
                                        child: Row(
                                          children: [
                                            Expanded(
                                              child: Row(
                                                children: [
                                                  const Text("Current ID: ", style: TextStyle(fontSize: 11.5, color: Colors.grey)),
                                                  Text(
                                                    item.currentPatientId,
                                                    style: const TextStyle(fontSize: 11.5, color: Colors.red, fontWeight: FontWeight.bold),
                                                  ),
                                                ],
                                              ),
                                            ),
                                            const Icon(Icons.arrow_forward_rounded, size: 14, color: Colors.grey),
                                            const SizedBox(width: 8),
                                            Expanded(
                                              child: Row(
                                                children: [
                                                  const Text("Proposed Clean ID: ", style: TextStyle(fontSize: 11.5, color: Colors.grey)),
                                                  Text(
                                                    item.proposedPatientId,
                                                    style: const TextStyle(fontSize: 11.5, color: Color(0xFF0D9488), fontWeight: FontWeight.bold),
                                                  ),
                                                ],
                                              ),
                                            ),
                                            Container(
                                              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                              decoration: BoxDecoration(
                                                color: item.proposedIsAdult ? const Color(0xFFDBEAFE) : const Color(0xFFFEF3C7),
                                                borderRadius: BorderRadius.circular(4),
                                              ),
                                              child: Text(
                                                item.proposedIsAdult ? "Adult" : "Child",
                                                style: TextStyle(
                                                  fontSize: 10.5,
                                                  fontWeight: FontWeight.bold,
                                                  color: item.proposedIsAdult ? const Color(0xFF1E40AF) : const Color(0xFF92400E),
                                                ),
                                              ),
                                            ),
                                          ],
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ],
                            ),
                          ),
                        );
                      },
                    ),
            ),
            const SizedBox(height: 16),

            // Footer Actions
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                OutlinedButton(
                  onPressed: () => Navigator.pop(context),
                  style: OutlinedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                  ),
                  child: const Text("Cancel"),
                ),
                const SizedBox(width: 12),
                ElevatedButton.icon(
                  onPressed: _selectedCount == 0
                      ? null
                      : () => widget.onApplyFixes(_items.where((i) => i.isSelected).toList()),
                  icon: const Icon(Icons.check_circle_outline, size: 18),
                  label: Text("Apply Fixes to Selected ($_selectedCount)"),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF0D9488),
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

// ─── Serials ↔ Dispensary Reconciliation Preview Model & Modal ───────────────

class _SerialsDispensaryPreviewItem {
  final String serial;
  final String branchId;
  final String dateKey;
  final String patientName;
  final String queueType;
  final String currentStatus;
  final String proposedStatus;
  final bool hasPrescriptionMerge;
  final bool hasMatchingSerial;
  final DocumentReference? serialRef;
  final DocumentReference? dispensaryRef;
  final Map<String, dynamic> dispensaryData;
  final Map<String, dynamic>? serialData;
  bool isSelected;

  _SerialsDispensaryPreviewItem({
    required this.serial,
    required this.branchId,
    required this.dateKey,
    required this.patientName,
    required this.queueType,
    required this.currentStatus,
    required this.proposedStatus,
    required this.hasPrescriptionMerge,
    required this.hasMatchingSerial,
    required this.serialRef,
    required this.dispensaryRef,
    required this.dispensaryData,
    required this.serialData,
    this.isSelected = true,
  });
}

class _SerialsDispensaryPreviewModal extends StatefulWidget {
  final List<_SerialsDispensaryPreviewItem> initialItems;
  final Future<void> Function(List<_SerialsDispensaryPreviewItem> selectedItems) onApplyFixes;

  const _SerialsDispensaryPreviewModal({
    required this.initialItems,
    required this.onApplyFixes,
  });

  @override
  State<_SerialsDispensaryPreviewModal> createState() => _SerialsDispensaryPreviewModalState();
}

class _SerialsDispensaryPreviewModalState extends State<_SerialsDispensaryPreviewModal> {
  late List<_SerialsDispensaryPreviewItem> _items;
  String _searchQuery = '';
  bool _selectAll = true;

  @override
  void initState() {
    super.initState();
    _items = List.from(widget.initialItems);
  }

  List<_SerialsDispensaryPreviewItem> get _filteredItems {
    if (_searchQuery.trim().isEmpty) return _items;
    final q = _searchQuery.toLowerCase().trim();
    return _items.where((i) {
      return i.patientName.toLowerCase().contains(q) ||
          i.serial.toLowerCase().contains(q) ||
          i.branchId.toLowerCase().contains(q) ||
          i.dateKey.toLowerCase().contains(q);
    }).toList();
  }

  int get _selectedCount => _items.where((i) => i.isSelected).length;

  @override
  Widget build(BuildContext context) {
    final filtered = _filteredItems;

    return Dialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      insetPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 32),
      child: Container(
        width: 850,
        height: 650,
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Header Row
            Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: const Color(0xFF7C3AED).withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: const Icon(Icons.compare_arrows_rounded, color: Color(0xFF7C3AED), size: 28),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        "Serials ↔ Dispensary Reconciliation Preview",
                        style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: AppColors.navy),
                      ),
                      const SizedBox(height: 3),
                      Text(
                        "Review clinical data merges and legacy dispensary document cleanup before applying.",
                        style: TextStyle(fontSize: 12.5, color: Colors.grey.shade600),
                      ),
                    ],
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.close_rounded),
                  onPressed: () => Navigator.pop(context),
                ),
              ],
            ),
            const SizedBox(height: 16),
            const Divider(height: 1),
            const SizedBox(height: 14),

            // Search Bar & Filter Controls
            Row(
              children: [
                Expanded(
                  child: TextField(
                    decoration: InputDecoration(
                      hintText: "Search serial, patient name, or branch...",
                      prefixIcon: const Icon(Icons.search, size: 20),
                      isDense: true,
                      filled: true,
                      fillColor: AppColors.gray50,
                      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(10),
                        borderSide: BorderSide(color: AppColors.gray300),
                      ),
                    ),
                    onChanged: (val) => setState(() => _searchQuery = val),
                  ),
                ),
                const SizedBox(width: 14),
                FilterChip(
                  label: Text(_selectAll ? "Deselect All" : "Select All"),
                  selected: _selectAll,
                  onSelected: (val) {
                    setState(() {
                      _selectAll = val;
                      for (final it in _items) {
                        it.isSelected = val;
                      }
                    });
                  },
                ),
              ],
            ),
            const SizedBox(height: 14),

            // Counter Panel
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
              decoration: BoxDecoration(
                color: const Color(0xFFF5F3FF),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: const Color(0xFFDDD6FE)),
              ),
              child: Row(
                children: [
                  const Icon(Icons.info_outline, size: 16, color: Color(0xFF7C3AED)),
                  const SizedBox(width: 8),
                  Text(
                    "Total Discrepancies: ${_items.length} records  •  Selected to Fix: $_selectedCount records",
                    style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600, color: Color(0xFF6D28D9)),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),

            // List of Review Cards
            Expanded(
              child: filtered.isEmpty
                  ? Center(
                      child: Text(
                        _searchQuery.isEmpty ? "No discrepancies found." : "No matching records found for '$_searchQuery'",
                        style: TextStyle(color: Colors.grey.shade600),
                      ),
                    )
                  : ListView.builder(
                      itemCount: filtered.length,
                      itemBuilder: (ctx, idx) {
                        final item = filtered[idx];
                        return Card(
                          margin: const EdgeInsets.only(bottom: 10),
                          elevation: 0,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(10),
                            side: BorderSide(
                              color: item.isSelected ? const Color(0xFF7C3AED) : AppColors.gray200,
                              width: item.isSelected ? 1.5 : 1.0,
                            ),
                          ),
                          child: Padding(
                            padding: const EdgeInsets.all(12),
                            child: Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Checkbox(
                                  value: item.isSelected,
                                  activeColor: const Color(0xFF7C3AED),
                                  onChanged: (val) {
                                    setState(() {
                                      item.isSelected = val ?? false;
                                      _selectAll = _items.every((i) => i.isSelected);
                                    });
                                  },
                                ),
                                const SizedBox(width: 8),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      Row(
                                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                        children: [
                                          Text(
                                            "Serial: ${item.serial}",
                                            style: const TextStyle(fontSize: 14.5, fontWeight: FontWeight.bold, color: AppColors.navy),
                                          ),
                                          Container(
                                            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                                            decoration: BoxDecoration(
                                              color: AppColors.gray100,
                                              borderRadius: BorderRadius.circular(6),
                                            ),
                                            child: Text(
                                              "Branch: ${item.branchId.toUpperCase()} • Date: ${item.dateKey}",
                                              style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: AppColors.gray700),
                                            ),
                                          ),
                                        ],
                                      ),
                                      const SizedBox(height: 4),
                                      Text(
                                        "Patient: ${item.patientName}",
                                        style: TextStyle(fontSize: 12.5, color: Colors.grey.shade700),
                                      ),
                                      const SizedBox(height: 8),
                                      // Diff / Action Box
                                      Container(
                                        padding: const EdgeInsets.all(8),
                                        decoration: BoxDecoration(
                                          color: AppColors.gray50,
                                          borderRadius: BorderRadius.circular(6),
                                        ),
                                        child: Row(
                                          children: [
                                            Expanded(
                                              child: Row(
                                                children: [
                                                  const Text("Current Status: ", style: TextStyle(fontSize: 11.5, color: Colors.grey)),
                                                  Text(
                                                    item.currentStatus,
                                                    style: TextStyle(
                                                      fontSize: 11.5,
                                                      color: item.currentStatus == 'dispensed' ? Colors.green : Colors.orange.shade800,
                                                      fontWeight: FontWeight.bold,
                                                    ),
                                                  ),
                                                ],
                                              ),
                                            ),
                                            const Icon(Icons.arrow_forward_rounded, size: 14, color: Colors.grey),
                                            const SizedBox(width: 8),
                                            Expanded(
                                              child: Row(
                                                children: [
                                                  const Text("Target Status: ", style: TextStyle(fontSize: 11.5, color: Colors.grey)),
                                                  Text(
                                                    item.proposedStatus,
                                                    style: const TextStyle(fontSize: 11.5, color: Color(0xFF7C3AED), fontWeight: FontWeight.bold),
                                                  ),
                                                ],
                                              ),
                                            ),
                                            if (item.hasPrescriptionMerge)
                                              Container(
                                                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                                decoration: BoxDecoration(
                                                  color: const Color(0xFFD1FAE5),
                                                  borderRadius: BorderRadius.circular(4),
                                                ),
                                                child: const Text(
                                                  "+ Prescription",
                                                  style: TextStyle(
                                                    fontSize: 10.5,
                                                    fontWeight: FontWeight.bold,
                                                    color: Color(0xFF065F46),
                                                  ),
                                                ),
                                              ),
                                          ],
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ],
                            ),
                          ),
                        );
                      },
                    ),
            ),
            const SizedBox(height: 16),

            // Footer Actions
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                OutlinedButton(
                  onPressed: () => Navigator.pop(context),
                  style: OutlinedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                  ),
                  child: const Text("Cancel"),
                ),
                const SizedBox(width: 12),
                ElevatedButton.icon(
                  onPressed: _selectedCount == 0
                      ? null
                      : () => widget.onApplyFixes(_items.where((i) => i.isSelected).toList()),
                  icon: const Icon(Icons.check_circle_outline, size: 18),
                  label: Text("Apply Reconciliation to Selected ($_selectedCount)"),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF7C3AED),
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}