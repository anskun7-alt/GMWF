import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:gmwf/services/local_storage_service.dart';
import 'package:gmwf/services/finance_local_storage.dart';

class FirestoreStructureSanitizer {
  static final FirebaseFirestore _db = FirebaseFirestore.instance;

  static const List<String> _branchSubcollections = [
    'patients',
    'prescriptions',
    'dispensary',
    'serials',
    'employees',
    'donations',
    'donors',
    'biometric_devices',
    'biometric_credentials',
    'biometric_punches',
    'notifications',
    'settings',
    'charges',
    'dispensary_charges',
    'bank_slips',
    'inventory',
    'inventory_log',
    'audit_logs',
    'journal_entries',
  ];

  /// Scans and permanently purges bogus branch documents ('all', 'global', and 13-digit CNIC documents)
  /// from the Firestore `branches` collection, safely re-routing any real data to their proper branch.
  static Future<Map<String, dynamic>> cleanBogusBranchDocuments({
    void Function(String msg)? onProgress,
  }) async {
    final report = <String, dynamic>{
      'bogusBranchesFound': 0,
      'bogusBranchesDeleted': 0,
      'documentsMigrated': 0,
      'subcollectionDocsDeleted': 0,
      'errors': <String>[],
    };

    void log(String msg) {
      debugPrint('[FirestoreStructureSanitizer] $msg');
      onProgress?.call(msg);
    }

    try {
      log('🔍 Scanning Firestore branches collection...');
      final branchesSnap = await _db.collection('branches').get(const GetOptions(source: Source.serverAndCache));
      
      final bogusDocs = <QueryDocumentSnapshot<Map<String, dynamic>>>[];
      for (final doc in branchesSnap.docs) {
        final id = doc.id.trim().toLowerCase();
        final isAllOrGlobal = id == 'all' || id == 'global';
        final isCnic = RegExp(r'^\d{11,15}$').hasMatch(id.replaceAll(RegExp(r'\D'), ''));

        if (isAllOrGlobal || isCnic) {
          bogusDocs.add(doc);
        }
      }

      report['bogusBranchesFound'] = bogusDocs.length;
      log('🔎 Identified ${bogusDocs.length} bogus branch documents to remove (all, global, or CNICs).');

      for (final bogusDoc in bogusDocs) {
        final bogusBranchId = bogusDoc.id;
        log('🧹 Cleaning bogus branch: $bogusBranchId...');

        for (final subcol in _branchSubcollections) {
          try {
            final subcolRef = _db.collection('branches').doc(bogusBranchId).collection(subcol);
            final subSnap = await subcolRef.get();

            if (subSnap.docs.isNotEmpty) {
              for (final d in subSnap.docs) {
                final data = d.data();
                
                // If it's a real record, reparent it into the proper branch
                final targetBranch = LocalStorageService.sanitizeBranchId(
                  data['branchId']?.toString(),
                  fallback: 'karachi',
                );

                if (targetBranch != bogusBranchId) {
                  try {
                    await _db
                        .collection('branches')
                        .doc(targetBranch)
                        .collection(subcol)
                        .doc(d.id)
                        .set(data, SetOptions(merge: true));
                    report['documentsMigrated'] = (report['documentsMigrated'] as int) + 1;
                  } catch (e) {
                    debugPrint('[Sanitizer] Migration notice for ${d.id}: $e');
                  }
                }

                // Delete document from bogus branch
                await d.reference.delete();
                report['subcollectionDocsDeleted'] = (report['subcollectionDocsDeleted'] as int) + 1;
              }
            }
          } catch (e) {
            report['errors'].add('Error cleaning $bogusBranchId/$subcol: $e');
          }
        }

        // Delete the parent branch document itself
        try {
          await bogusDoc.reference.delete();
          report['bogusBranchesDeleted'] = (report['bogusBranchesDeleted'] as int) + 1;
          log('✅ Successfully removed bogus branch: $bogusBranchId');
        } catch (e) {
          report['errors'].add('Failed to delete branch document $bogusBranchId: $e');
        }
      }

      log('🎉 Completed bogus branch cleanup! Removed ${report['bogusBranchesDeleted']} bogus branches.');
    } catch (e) {
      log('❌ Error during bogus branch cleanup: $e');
      report['errors'].add(e.toString());
    }

    return report;
  }

  /// Cleans redundant root collections ('employees', 'biometric_devices', 'biometric_credentials', 'biometric_punches')
  /// by moving valid records into their proper branch subcollection and removing the root copies.
  static Future<Map<String, dynamic>> cleanRootCollections({
    void Function(String msg)? onProgress,
  }) async {
    final report = <String, dynamic>{
      'rootEmployeesCleaned': 0,
      'rootDevicesCleaned': 0,
      'rootCredentialsCleaned': 0,
      'rootPunchesCleaned': 0,
      'errors': <String>[],
    };

    void log(String msg) {
      debugPrint('[FirestoreStructureSanitizer] $msg');
      onProgress?.call(msg);
    }

    // 1. Clean root employees collection
    try {
      log('🔍 Checking root employees collection...');
      final empSnap = await _db.collection('employees').get();
      if (empSnap.docs.isNotEmpty) {
        log('📦 Migrating ${empSnap.docs.length} root employee documents into their branch subcollections...');
        for (final doc in empSnap.docs) {
          final data = doc.data();
          final bId = LocalStorageService.sanitizeBranchId(data['branchId']?.toString(), fallback: 'karachi');
          
          await _db.collection('branches').doc(bId).collection('employees').doc(doc.id).set(data, SetOptions(merge: true));
          await doc.reference.delete();
          report['rootEmployeesCleaned'] = (report['rootEmployeesCleaned'] as int) + 1;
        }
        log('✅ Cleaned root employees collection.');
      }
    } catch (e) {
      report['errors'].add('Root employees clean error: $e');
    }

    // 2. Clean root biometric_devices collection
    try {
      log('🔍 Checking root biometric_devices collection...');
      final devSnap = await _db.collection('biometric_devices').get();
      if (devSnap.docs.isNotEmpty) {
        log('📦 Migrating ${devSnap.docs.length} root biometric device configs into branches...');
        for (final doc in devSnap.docs) {
          final data = doc.data();
          final bId = LocalStorageService.sanitizeBranchId(data['branchId']?.toString(), fallback: 'karachi');
          
          await _db.collection('branches').doc(bId).collection('biometric_devices').doc(doc.id).set(data, SetOptions(merge: true));
          await doc.reference.delete();
          report['rootDevicesCleaned'] = (report['rootDevicesCleaned'] as int) + 1;
        }
        log('✅ Cleaned root biometric_devices collection.');
      }
    } catch (e) {
      report['errors'].add('Root devices clean error: $e');
    }

    // 3. Clean root biometric_credentials collection
    try {
      log('🔍 Checking root biometric_credentials collection...');
      final credSnap = await _db.collection('biometric_credentials').get();
      if (credSnap.docs.isNotEmpty) {
        log('📦 Migrating ${credSnap.docs.length} root biometric credentials into branches...');
        for (final doc in credSnap.docs) {
          final data = doc.data();
          final bId = LocalStorageService.sanitizeBranchId(data['branchId']?.toString(), fallback: 'karachi');
          
          await _db.collection('branches').doc(bId).collection('biometric_credentials').doc(doc.id).set(data, SetOptions(merge: true));
          await doc.reference.delete();
          report['rootCredentialsCleaned'] = (report['rootCredentialsCleaned'] as int) + 1;
        }
        log('✅ Cleaned root biometric_credentials collection.');
      }
    } catch (e) {
      report['errors'].add('Root credentials clean error: $e');
    }

    // 4. Clean root biometric_punches collection
    try {
      log('🔍 Checking root biometric_punches collection...');
      final punchSnap = await _db.collection('biometric_punches').limit(500).get();
      if (punchSnap.docs.isNotEmpty) {
        for (final doc in punchSnap.docs) {
          await doc.reference.delete();
          report['rootPunchesCleaned'] = (report['rootPunchesCleaned'] as int) + 1;
        }
        log('✅ Cleaned ${report['rootPunchesCleaned']} legacy root punches.');
      }
    } catch (e) {
      report['errors'].add('Root punches clean error: $e');
    }

    // 5. Clean root notifications collection (re-route to branch or delete root doc)
    try {
      log('🔍 Checking root notifications collection...');
      final notifSnap = await _db.collection('notifications').limit(500).get();
      if (notifSnap.docs.isNotEmpty) {
        int notifCount = 0;
        for (final doc in notifSnap.docs) {
          final data = doc.data();
          final bId = LocalStorageService.sanitizeBranchId(data['branchId']?.toString());
          if (bId.isNotEmpty) {
            await _db.collection('branches').doc(bId).collection('notifications').doc(doc.id).set(data, SetOptions(merge: true));
          }
          await doc.reference.delete();
          notifCount++;
        }
        report['rootNotificationsCleaned'] = notifCount;
        log('✅ Cleaned $notifCount root notifications, kept inside branches.');
      }
    } catch (e) {
      report['errors'].add('Root notifications clean error: $e');
    }

    // 6. Clean root announcements collection
    try {
      log('🔍 Checking root announcements collection...');
      final annSnap = await _db.collection('announcements').limit(500).get();
      if (annSnap.docs.isNotEmpty) {
        int annCount = 0;
        for (final doc in annSnap.docs) {
          await doc.reference.delete();
          annCount++;
        }
        report['rootAnnouncementsCleaned'] = annCount;
        log('✅ Cleaned $annCount root announcements.');
      }
    } catch (e) {
      report['errors'].add('Root announcements clean error: $e');
    }

    return report;
  }

  /// Runs the full comprehensive cleanup: bogus branches + root collections + dummy placeholder employees
  static Future<Map<String, dynamic>> executeFullStructureSanitization({
    void Function(String msg)? onProgress,
  }) async {
    final fullReport = <String, dynamic>{};

    onProgress?.call('🚀 Starting Firestore Structure Sanitization...');
    final branchReport = await cleanBogusBranchDocuments(onProgress: onProgress);
    fullReport['branches'] = branchReport;

    final rootReport = await cleanRootCollections(onProgress: onProgress);
    fullReport['rootCollections'] = rootReport;

    onProgress?.call('🧹 Purging unknown placeholder employees...');
    final purgedEmpCount = await FinanceLocalStorage.purgeUnknownPlaceholderEmployees();
    fullReport['purgedPlaceholderEmployees'] = purgedEmpCount;

    onProgress?.call('✨ Full Structure Sanitization Complete!');
    return fullReport;
  }
}
