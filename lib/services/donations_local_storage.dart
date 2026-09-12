// lib/services/donations_local_storage.dart
//
// FIXES vs previous revision:
//   1. init() now also opens 'sync_queue' and 'app_settings' boxes.
//      enqueueSync() (called on every save) uses Hive.box('sync_queue') and
//      nextReceiptNumber() uses Hive.box('app_settings') for the offline
//      fallback counter. If either box isn't open when saveDonation() is
//      called, Hive throws HiveError which is an Error (not Exception) and
//      escapes the try/catch in _submit(), killing the whole app.
//
//   2. saveDonor() now calls flush() after put() so the write is durably
//      committed before the UI rebuilds (was missing, causing lost donors).
//
//   3. saveDonation() always sets syncStatus = 'pending' so
//      _enqueueMissingDonations() in SyncService can find and backfill
//      any donation that missed its initial enqueue.
//
//   4. All other logic is identical to the previous revision.

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:intl/intl.dart';
import 'package:collection/collection.dart';
import 'package:uuid/uuid.dart';

import 'local_storage_service.dart';
import 'sync_service.dart';
import '../models/donation_models.dart';
import '../pages/donations/donations_shared.dart';
import '../realtime/realtime_manager.dart';
import '../realtime/realtime_events.dart';

class DonationsLocalStorage {
  // ── Box names (public — SubmissionService references donationsBox) ─────────
  static const String donationsBox = 'local_donations';
  static const String donorsBox    = 'local_donors';
  static const String bankSlipsBox = 'local_bank_slips';

  // ══════════════════════════════════════════════════════════════════════════
  // INIT — call once in main() before runApp()
  // ══════════════════════════════════════════════════════════════════════════

  static Future<void> init() async {
    await LocalStorageService.openBoxSafe(donationsBox);
    await LocalStorageService.openBoxSafe(donorsBox);
    await LocalStorageService.openBoxSafe(bankSlipsBox);
    // Required by LocalStorageService.enqueueSync()
    await LocalStorageService.openBoxSafe(LocalStorageService.syncBox);
    // Required by LocalStorageService.nextReceiptNumber() offline path
    await LocalStorageService.openBoxSafe('app_settings');
    await LocalStorageService.openBoxSafe('app_flags');


    debugPrint('[DonationsLocalStorage] Boxes opened safely. Init sequence FINISHED.');
    
    // Resume receipt sequence from max existing if possible
    await _syncReceiptSequence();

    // Migrate duplicate clean receipt firestoreIds to unique ones to prevent collision overwrites in Firestore
    await migrateDuplicateReceiptFirestoreIds();

    // Clean up any incorrect 'all' branch garbage — runs only once per install
    // to avoid a Firestore read on every cold boot.
    final flags = Hive.box('app_flags');
    if (flags.get('all_branch_garbage_cleaned', defaultValue: false) != true) {
      await _cleanAllBranchGarbage();
      await flags.put('all_branch_garbage_cleaned', true);
    }
  }

  static Future<void> _cleanAllBranchGarbage() async {
    try {
      final box = Hive.box(donationsBox);
      final syncBox = Hive.box(LocalStorageService.syncBox);

      // 1. Delete local 'all' records
      final localKeysToDelete = <dynamic>[];
      for (var key in box.keys) {
        final keyStr = key.toString();
        if (keyStr.startsWith('all_') || keyStr.startsWith('all__')) {
          localKeysToDelete.add(key);
        }
      }
      if (localKeysToDelete.isNotEmpty) {
        for (var k in localKeysToDelete) {
          await box.delete(k);
        }
        await box.flush();
        debugPrint('[DonationsLS] Cleaned ${localKeysToDelete.length} local garbage "all" records.');
      }

      // 2. Delete queued 'all' records from syncBox
      final syncKeysToDelete = <dynamic>[];
      for (var key in syncBox.keys) {
        final val = syncBox.get(key);
        if (val is Map) {
          final bId = val['branchId']?.toString();
          if (bId == 'all') {
            syncKeysToDelete.add(key);
          }
        }
      }
      if (syncKeysToDelete.isNotEmpty) {
        for (var k in syncKeysToDelete) {
          await syncBox.delete(k);
        }
        debugPrint('[DonationsLS] Cleaned ${syncKeysToDelete.length} queued garbage "all" sync tasks.');
      }

      // 3. Clear remote 'all' branch subcollection in Firestore
      FirebaseFirestore.instance
          .collection('branches')
          .doc('all')
          .collection('donations')
          .get()
          .then((snap) async {
            if (snap.docs.isNotEmpty) {
              debugPrint('[DonationsLS] Found ${snap.docs.length} garbage documents in branches/all/donations. Deleting...');
              for (final doc in snap.docs) {
                await doc.reference.delete();
              }
              debugPrint('[DonationsLS] Garbage remote "all" documents deleted.');
            }
          }).catchError((e) {
            debugPrint('[DonationsLS] Error clearing remote "all" branch: $e');
          });

    } catch (e) {
      debugPrint('[DonationsLS] Error cleaning "all" garbage: $e');
    }
  }

  static Future<void> migrateDuplicateReceiptFirestoreIds() async {
    final box = Hive.box(donationsBox);
    int migratedCount = 0;
    
    for (var key in box.keys.toList()) {
      final raw = box.get(key);
      if (raw == null || raw is! Map) continue;
      
      final data = Map<String, dynamic>.from(raw);
      final cleanRcpt = data['receiptNoClean']?.toString() ?? '';
      final localId = data['localId']?.toString() ?? '';
      final currentFsId = data['firestoreId']?.toString() ?? '';
      final branchId = data['branchId']?.toString() ?? 'gujrat';
      
      if (cleanRcpt.isNotEmpty && localId.isNotEmpty && currentFsId == cleanRcpt) {
        final newFsId = '${cleanRcpt}_$localId';
        final updated = {
          ...data,
          'firestoreId': newFsId,
          'syncStatus': 'pending',
          'lastUpdatedAt': DateTime.now().toUtc().toIso8601String(),
        };
        await box.put(key, updated);
        
        // Enqueue deletion of the old document
        await LocalStorageService.enqueueSync({
          'type': 'delete_donation',
          'branchId': branchId,
          'firestoreId': cleanRcpt,
        });

        // Enqueue sync for this updated unique document
        await LocalStorageService.enqueueSync({
          'type':     'save_donation',
          'branchId': branchId,
          'localId':  localId,
          'hiveKey':  key.toString(),
          'data':     _sanitize(updated),
        });
        
        migratedCount++;
      }
    }
    
    if (migratedCount > 0) {
      await box.flush();
      debugPrint('[DonationsLS] Migrated $migratedCount records to unique firestoreIds and enqueued for sync & cleanup.');
    }
  }

  static Future<void> _syncReceiptSequence() async {
    final settings = Hive.box('app_settings');
    final box = Hive.box(donationsBox);
    
    for (var val in box.values) {
      if (val is Map) {
        final rcpt = val['receiptNo']?.toString() ?? '';
        if (rcpt.startsWith('GMWF-')) {
          final parts = rcpt.split('-');
          // Format: GMWF-001 (length 2) or GMWF-grt-001 (length 3) 
          // or GMWF-grt-001-X1 (length 4)
          if (parts.length >= 3) {
            final code = parts[1];
            final seq = int.tryParse(parts[2]) ?? 0;
            final key = 'receipt_seq_$code';
            final cur = settings.get(key, defaultValue: 0) as int;
            if (seq > cur) await settings.put(key, seq);
          } else if (parts.length == 2) {
            final seq = int.tryParse(parts[1]) ?? 0;
            final cur = settings.get('receipt_seq_global', defaultValue: 0) as int;
            if (seq > cur) await settings.put('receipt_seq_global', seq);
          }
        }
      }
    }
    debugPrint('[DonationsLS] Receipt sequences synced from existing records.');
  }

  // ── Public box accessors ───────────────────────────────────────────────────
  static Box getBox()       => Hive.box(donationsBox);
  static Box getDonorsBox() => Hive.box(donorsBox);

  // ══════════════════════════════════════════════════════════════════════════
  // SANITIZE
  //
  // Hive only supports: String, int, double, bool, List, Map, null.
  // DateTime, Timestamp, FieldValue, GeoPoint all crash Hive on put().
  // ══════════════════════════════════════════════════════════════════════════

  static Map<String, dynamic> _sanitize(Map<String, dynamic> input) {
    final out = <String, dynamic>{};
    input.forEach((k, v) => out[k] = _val(v));
    return out;
  }

  static dynamic _val(dynamic v) {
    if (v == null)       return null;
    if (v is String)     return v;
    if (v is int)        return v;
    if (v is double)     return v;
    if (v is bool)       return v;
    if (v is DateTime)   return v.toIso8601String();
    if (v is Timestamp)  return v.toDate().toIso8601String();
    if (v is Map)        return _sanitize(Map<String, dynamic>.from(v));
    if (v is List)       return v.map(_val).toList();
    // FieldValue, GeoPoint, DocumentReference etc. — not storable in Hive.
    debugPrint('[DonationsLS] _sanitize WARNING: dropping ${v.runtimeType} for value $v');
    return null;
  }

  // ── Key helpers ────────────────────────────────────────────────────────────
  static String _donationKey(String branchId, String date, String localId) =>
      '${branchId}__${date}__$localId';

  static String _donorKey(String donorId) => 'donor_$donorId';

  static String _newLocalId() => const Uuid().v4();

  static String _today() => DateFormat('yyyy-MM-dd').format(DateTime.now());

  // ══════════════════════════════════════════════════════════════════════════
  // DONATIONS — write
  // ══════════════════════════════════════════════════════════════════════════

  static Future<DonationRecord> saveDonation({
    required String branchId,
    required Map<String, dynamic> data,
  }) async {
    final branchIdNorm = branchId.toLowerCase().trim();
    final localId  = (data['localId'] as String?)?.isNotEmpty == true
        ? data['localId'] as String
        : _newLocalId();
    final date     = (data['date'] as String?) ?? _today();
    final key      = _donationKey(branchIdNorm, date, localId);

    final recordMap = Map<String, dynamic>.from(data);
    recordMap['localId']     = localId;
    recordMap['hiveKey']     = key;
    recordMap['branchId']    = branchIdNorm;
    recordMap['syncStatus']  = 'pending'; // always mark pending so backfill picks it up
    // Coerce status to a plain string — DonationStatus holds static const Strings.
    final rawStatus = data['status'];
    recordMap['status'] = rawStatus?.toString() ?? kStatusPending;
    recordMap['firestoreId'] = null;
    recordMap['lastUpdatedAt'] = DateTime.now().toIso8601String();

    final existingReceipt = (recordMap['receiptNo'] as String? ?? '').trim();
    if (existingReceipt.isEmpty) {
      recordMap['receiptNo'] = await LocalStorageService.nextReceiptNumber(branchIdNorm);
    }

    // Always store clean version
    recordMap['receiptNoClean'] =
        cleanReceiptNumber(recordMap['receiptNo'] as String? ?? '');

    // ── DONOR AUTO-REGISTRATION & ENRICHMENT ─────────────────────────────────
    final phone       = (data['phone'] as String? ?? '').trim();
    final donorId     = (data['donorId'] as String? ?? '').trim();
    final donorName   = (data['donorName'] as String? ?? 'Walk-in Donor').trim();
    final isAnonymous = data['isAnonymous'] as bool? ?? false;
    final bankAcc     = (data['bankAccountNumber'] as String? ?? '').trim();

    final isBox = data['isBoxDonation'] == true ||
        donorId.contains('_box_') ||
        (data['boxId'] != null && (data['boxId'] as String).isNotEmpty) ||
        (data['boxNumber'] != null && (data['boxNumber'] as String).isNotEmpty);

    final donorNameNorm = donorName.toLowerCase().trim();
    final isAnonymousEffective = isAnonymous ||
        donorNameNorm == 'valued donor' ||
        donorNameNorm == 'anonymous' ||
        donorNameNorm == 'walk-in donor';

    recordMap['isAnonymous'] = isAnonymousEffective;

    if (!isBox && !isAnonymousEffective && (phone.isNotEmpty || donorId.isNotEmpty || donorName.isNotEmpty)) {
      DonorRecord? active;

      // Search GLOBALLY across all branches by donorId first, then phone
      if (donorId.isNotEmpty) {
        active = getDonorById(donorId);
      }

      if (active == null && phone.isNotEmpty) {
        // Global phone search — ignores branch
        final matches = getDonorsByPhone(phone);
        if (matches.length == 1) {
          active = matches.first;
        } else if (matches.length > 1) {
          // Prefer same branch, fall back to first match
          active = matches.firstWhere(
            (d) => d.branchId == branchIdNorm,
            orElse: () => matches.first,
          );
        }
      }

      if (active == null && phone.isEmpty && donorName.isNotEmpty) {
        // Search by name among donors who have NO phone number
        final allDonors = getAllDonors();
        active = allDonors.firstWhereOrNull((d) => 
          d.name.toLowerCase().trim() == donorName.toLowerCase().trim() &&
          d.phones.isEmpty
        );
      }

      if (active == null) {
        final dnrId = donorId.isNotEmpty
            ? donorId
            : await LocalStorageService.nextDonorNumber();
        active = DonorRecord(
          id:             dnrId,
          name:           donorName,
          phones:         phone.isNotEmpty ? [phone] : [],
          accountNumbers: bankAcc.isNotEmpty ? [bankAcc] : [],
          branchId:       branchIdNorm,  // home branch — never changes
          createdAt:      DateTime.now().toIso8601String(),
          address:        (data['address'] as String? ?? ''),
        );
        await saveDonor(active);
        recordMap['donorId']   = active.id;
        recordMap['donorHomeBranch'] = active.branchId;
      } else {
        recordMap['donorId']         = active.id;
        recordMap['donorHomeBranch'] = active.branchId;  // preserve home branch

        bool changed = false;
        var updated = active;

        if (phone.isNotEmpty && !active.phones.contains(phone)) {
          updated = updated.copyWith(phones: [...active.phones, phone]);
          changed = true;
        }
        if (bankAcc.isNotEmpty && !active.accountNumbers.contains(bankAcc)) {
          updated = updated.copyWith(accountNumbers: [...active.accountNumbers, bankAcc]);
          changed = true;
        }
        if (active.name != donorName && donorName != 'Walk-in Donor') {
          updated = updated.copyWith(name: donorName);
          changed = true;
        }
        if (changed) await saveDonor(updated);
      }

      // Record which branch this specific donation was collected at
      recordMap['collectedAtBranch'] = branchIdNorm;
    }

    final cleanRcpt = recordMap['receiptNoClean'] as String;
    // Append localId to guarantee uniqueness and prevent collisions/overwriting in Firestore.
    recordMap['firestoreId'] = cleanRcpt.isNotEmpty ? '${cleanRcpt}_$localId' : localId;
    
    final sanitized = _sanitize(recordMap);

    debugPrint('[DonationsLS] Put record into Hive... key: $key');
    final box = Hive.box(donationsBox);
    await box.put(key, sanitized);
    await box.flush();
    debugPrint('[DonationsLS] Saved → $key');

    debugPrint('[DonationsLS] Enqueuing sync...');
    await LocalStorageService.enqueueSync({
      'type':     'save_donation',
      'branchId': branchIdNorm,
      'localId':  localId,
      'hiveKey':  key,
      'data':     sanitized,
    });

    // Broadcast over LAN so server and peer stations receive the donation receipt immediately
    try {
      if (RealtimeManager().isConnected) {
        RealtimeManager().sendMessage(
          RealtimeEvents.payload(
            type: RealtimeEvents.saveDonationReceipt,
            data: sanitized,
          ),
        );
      }
    } catch (e) {
      debugPrint('[DonationsLS] Realtime LAN broadcast error: $e');
    }

    // Immediately trigger cloud upload
    try {
      SyncService().triggerUpload(force: true);
    } catch (_) {}

    debugPrint('[DonationsLS] Sync enqueued. Queue size: ${Hive.box(LocalStorageService.syncBox).length}');

    // ── ENQUEUE AUDIT LOG ───────────────────────────────────────────────────
    await enqueueAuditLog(
      branchId: branchIdNorm,
      collection: 'donations',
      documentId: localId,
      action: 'create',
      userId: recordMap['collectorId'] ?? 'unknown',
      username: recordMap['recordedBy'] ?? 'Unknown',
      newData: sanitized,
    );

    return DonationRecord.fromMap(sanitized, key);
  }

  static bool isReceiptNoDuplicate(String receiptNo) {
    if (receiptNo.trim().isEmpty) return false;
    final clean = cleanReceiptNumber(receiptNo.trim());
    final box = Hive.box(donationsBox);
    for (var val in box.values) {
      if (val is Map) {
        if (val['syncStatus'] == 'deleted') continue;
        final rcpt = cleanReceiptNumber(val['receiptNo']?.toString() ?? '');
        if (rcpt == clean) return true;
        final bookRcpt = cleanReceiptNumber(val['bookReceiptNo']?.toString() ?? '');
        if (bookRcpt == clean) return true;
      }
    }
    return false;
  }

  static Future<void> updateDonationField(
    String hiveKey,
    Map<String, dynamic> fields, {
    required String branchId,
  }) async {
    final box = Hive.box(donationsBox);
    final raw = box.get(hiveKey);
    if (fields.containsKey('receiptNo')) {
      fields['receiptNoClean'] =
          cleanReceiptNumber(fields['receiptNo'] as String? ?? '');
    }
    if (raw == null) {
      debugPrint('[DonationsLS] updateDonationField: not found → $hiveKey');
      return;
    }
    final now = DateTime.now().toUtc().toIso8601String();

    final String lastSegment = hiveKey.split('__').last;
    final String resolvedLocalId = (raw as Map)['localId']?.toString() ?? lastSegment;

    // Check if the date has changed to update the Hive key accordingly
    final String oldDate = (raw as Map)['date']?.toString() ?? '';
    final String newDate = fields['date']?.toString() ?? oldDate;
    String finalKey = hiveKey;

    final updated = Map<String, dynamic>.from(raw as Map)
      ..addAll(_sanitize(fields))
      ..['lastUpdatedAt'] = now
      ..['isEdited'] = true
      ..['localId'] = resolvedLocalId;

    if (newDate != oldDate && newDate.isNotEmpty) {
      finalKey = _donationKey(branchId.toLowerCase().trim(), newDate, resolvedLocalId);
      updated['hiveKey'] = finalKey;

      // Save under new key and delete old key
      await box.put(finalKey, updated);
      await box.delete(hiveKey);
    } else {
      await box.put(hiveKey, updated);
    }
    await box.flush();
    debugPrint('[DonationsLS] Updated → oldKey: $hiveKey, finalKey: $finalKey');

    // ── ENQUEUE AUDIT LOG ───────────────────────────────────────────────────
    final user = updated['recordedBy'] ?? 'Unknown';
    final userId = updated['collectorId'] ?? 'unknown';

    await enqueueAuditLog(
      branchId: branchId,
      collection: 'donations',
      documentId: (updated['firestoreId'] as String?) ?? resolvedLocalId,
      action: 'update',
      userId: userId,
      username: user,
      oldData: Map<String, dynamic>.from(raw as Map),
      newData: updated,
      reason: fields['editReason'],
    );

    final fsId = (raw as Map)['firestoreId']?.toString();
    if (fsId != null && fsId.isNotEmpty) {
      await LocalStorageService.enqueueSync({
        'type':        'update_donation',
        'branchId':    branchId,
        'firestoreId': fsId,
        'hiveKey':     finalKey,
        'fields':      _sanitize(updated), // Send full updated map for conflict resolution
      });
    } else {
      await LocalStorageService.enqueueSync({
        'type':     'save_donation',
        'branchId': branchId,
        'localId':  resolvedLocalId,
        'hiveKey':  finalKey,
        'data':     updated,
      });
    }
  }

  static Future<void> enqueueAuditLog({
    required String branchId,
    required String collection,
    required String documentId,
    required String action,
    required String userId,
    required String username,
    Map<String, dynamic>? oldData,
    Map<String, dynamic>? newData,
    String? reason,
  }) async {
    final log = AuditLogEntry(
      id: const Uuid().v4(),
      collection: collection,
      documentId: documentId,
      action: action,
      userId: userId,
      username: username,
      timestamp: DateTime.now().toIso8601String(),
      branchId: branchId,
      branchName: branchId, // Will use branchId for name if no map exists
      oldData: oldData,
      newData: newData,
      reason: reason,
    );

    await LocalStorageService.enqueueSync({
      'type': 'save_audit_log',
      'branchId': branchId,
      'data': log.toMap(),
    });
  }

  static Future<void> markDonationSynced(
      String hiveKey, String firestoreId) async {
    final box = Hive.box(donationsBox);
    final raw = box.get(hiveKey);
    if (raw == null) return;
    final updated = Map<String, dynamic>.from(raw as Map)
      ..['firestoreId'] = firestoreId
      ..['syncStatus']  = 'synced';
    await box.put(hiveKey, updated);
    await box.flush();
    debugPrint('[DonationsLS] Synced → $hiveKey → $firestoreId');
  }

  static Future<void> mergeRemoteDonation(
    String hiveKey,
    String firestoreId,
    Map<String, dynamic> remoteData,
  ) async {
    final box = Hive.box(donationsBox);
    final existing = box.get(hiveKey);
    final Map<String, dynamic> merged = existing != null
        ? Map<String, dynamic>.from(existing as Map)
        : <String, dynamic>{};

    merged.addAll(_sanitize({
      ...remoteData,
      'firestoreId': firestoreId,
      'hiveKey': hiveKey,
      'syncStatus': 'synced',
    }));

    await box.put(hiveKey, merged);
    await box.flush();
    debugPrint('[DonationsLS] Merging remote donation -> $hiveKey');
  }

  static Future<void> mergeRemoteDonor(
    String donorId,
    Map<String, dynamic> remoteData,
  ) async {
    final box = Hive.box(donorsBox);
    final key = _donorKey(donorId);
    final existing = box.get(key);
    final Map<String, dynamic> merged = existing != null
        ? Map<String, dynamic>.from(existing as Map)
        : <String, dynamic>{};

    merged.addAll(_sanitize({
      ...remoteData,
      'id': donorId,
      'syncStatus': 'synced',
    }));

    await box.put(key, merged);
    await box.flush();
    debugPrint('[DonationsLS] Merging remote donor -> $donorId');
  }



  // ── Reads ──────────────────────────────────────────────────────────────────

  static List<DonationRecord> getDonationsForDate(
      String branchId, String date) {
    if (!Hive.isBoxOpen(donationsBox)) return [];
    final box = Hive.box(donationsBox);
    return box.keys
        .where((k) {
          final s = k.toString();
          return (s.startsWith('${branchId}_${date}_') ||
                  s.startsWith('${branchId}__${date}__')) &&
                 !s.contains('_credit_');
        })
        .map((k) {
          try {
            final raw = box.get(k);
            if (raw == null) return null;
            final m = Map<String, dynamic>.from(raw as Map);
            // DO NOT filter tombstones here; they are needed for LWW merge in the dashboard
            return DonationRecord.fromMap(m, k.toString());
          } catch (e) {
            debugPrint('[DonationsLS] Skipping corrupted record $k: $e');
            return null;
          }
        })
        .whereType<DonationRecord>()
        .toList()
      ..sort((a, b) => b.date.compareTo(a.date));
  }

  /// All donations for branch, newest first. Credit keys excluded.
  static List<DonationRecord> getAllDonations(String branchIdRaw) {
    if (!Hive.isBoxOpen(donationsBox)) return [];
    final branchId = branchIdRaw.toLowerCase().trim();
    final box = Hive.box(donationsBox);
    final isGlobal = branchId == 'all' || branchId.isEmpty;

    return box.keys
        .where((k) {
          final s = k.toString();
          if (s.contains('_credit_')) return false;
          if (isGlobal) return true;
          return s.startsWith('${branchId}_') || s.startsWith('${branchId}__');
        })
        .map((k) {
          try {
            final raw = box.get(k);
            if (raw == null) return null;
            final m = Map<String, dynamic>.from(raw as Map);
            // DO NOT filter tombstones here; they are needed for LWW merge in the dashboard
            return DonationRecord.fromMap(m, k.toString());
          } catch (e) {
            debugPrint('[DonationsLS] Skipping corrupted record $k: $e');
            return null;
          }
        })
        .whereType<DonationRecord>()
        .toList();
  }

  /// Fetch a page of donations for pagination.
  static Future<List<DonationRecord>> fetchPage({
    required String branchId,
    required int offset,
    required int limit,
  }) async {
    final all = getAllDonations(branchId);
    // Ensure sorted newest first (date descending)
    all.sort((a, b) => b.date.compareTo(a.date));
    if (offset >= all.length) return [];
    final end = (offset + limit) > all.length ? all.length : offset + limit;
    return all.sublist(offset, end);
  }
  /// Alias used by SubmissionService.getUnsubmittedPool().
  static List<DonationRecord> getDonationsList(String branchId) =>
      getAllDonations(branchId);

  /// Calculates total amount donated by a donor in the current calendar year.
  static double getDonorYTDTotal(String donorId) {
    if (donorId.isEmpty) return 0.0;
    final box = Hive.box(donationsBox);
    final currentYear = DateTime.now().year.toString();
    double total = 0.0;

    // Use values directly for better iteration performance in Hive
    for (var raw in box.values) {
      if (raw is! Map) continue;
      if (raw['syncStatus'] == 'deleted') continue; // Skip tombstones
      
      final dId = raw['donorId']?.toString();
      if (dId != donorId) continue;

      final date = raw['date']?.toString() ?? '';
      if (date.startsWith(currentYear)) {
        final amt = (raw['amount'] as num?)?.toDouble() ?? 0.0;
        final probable = (raw['probableAmount'] as num?)?.toDouble() ?? 0.0;
        total += (amt > 0 ? amt : probable);
      }
    }
    return total;
  }

  /// Calculates lifetime stats for a donor: total amount, total count, last date.
  static Future<Map<String, dynamic>> getDonorLifetimeStats(String donorId) async {
    if (donorId.isEmpty) return {'total': 0.0, 'count': 0, 'lastDate': ''};
    
    final donor = getDonorById(donorId);
    final box = Hive.box(donationsBox);
    double total = donor?.openingBalance ?? 0.0;
    int count = 0;
    String lastDate = donor?.joinedSince ?? '';

    for (var raw in box.values) {
      if (raw is! Map) continue;
      if (raw['syncStatus'] == 'deleted') continue; // Skip tombstones
      
      final dId = raw['donorId']?.toString();
      if (dId != donorId) continue;

      final amt  = (raw['amount'] as num?)?.toDouble() ?? 0.0;
      final prob = (raw['probableAmount'] as num?)?.toDouble() ?? 0.0;
      final date = (raw['date'] as String? ?? '');
      
      total += (amt > 0 ? amt : prob);
      count++;
      if (date.compareTo(lastDate) > 0) lastDate = date;
    }
    return {'total': total, 'count': count, 'lastDate': lastDate};
  }

  // ── Streams ────────────────────────────────────────────────────────────────

  static Stream<List<DonationRecord>> streamDonationsForDate(
      String branchId, String date) async* {
    if (!Hive.isBoxOpen(donationsBox)) {
      await LocalStorageService.openBoxSafe(donationsBox);
    }
    yield getDonationsForDate(branchId, date);
    await for (final _ in Hive.box(donationsBox).watch()) {
      yield getDonationsForDate(branchId, date);
    }
  }

  static Stream<List<DonationRecord>> streamAllDonations(
      String branchId) async* {
    if (!Hive.isBoxOpen(donationsBox)) {
      await LocalStorageService.openBoxSafe(donationsBox);
    }
    yield getAllDonations(branchId);
    await for (final _ in Hive.box(donationsBox).watch()) {
      yield getAllDonations(branchId);
    }
  }

  // ══════════════════════════════════════════════════════════════════════════
  // DONORS — local read/write
  // ══════════════════════════════════════════════════════════════════════════

  static List<DonorRecord> getDonorsByPhone(String phone) {
    if (phone.isEmpty || !Hive.isBoxOpen(donorsBox)) return [];
    final box    = Hive.box(donorsBox);
    final pClean = phone.replaceAll(RegExp(r'\D'), '');

    return box.values
        .map((v) {
          final m = Map<String, dynamic>.from(v as Map);
          if (m['syncStatus'] == 'deleted') return null;
          return DonorRecord.fromMap(m);
        })
        .whereType<DonorRecord>()
        .where((d) => d.phones.any(
            (p) => p.replaceAll(RegExp(r'\D'), '') == pClean))
        .toList();
  }

  static DonorRecord? getDonorById(String id) {
    if (id.isEmpty || !Hive.isBoxOpen(donorsBox)) return null;
    final box = Hive.box(donorsBox);
    final raw = box.get(_donorKey(id));
    if (raw == null) return null;
    final m = Map<String, dynamic>.from(raw as Map);
    if (m['syncStatus'] == 'deleted') return null;
    return DonorRecord.fromMap(m);
  }

  static Future<void> saveDonor(DonorRecord donor) async {
    final key = _donorKey(donor.id);
    final now = DateTime.now().toUtc().toIso8601String();
    
    // Roti donor fix
    final phones = donor.phones.isEmpty && (donor.name.toLowerCase().contains('roti')) 
        ? ['00000000000'] 
        : donor.phones;

    final sanitized = _sanitize({
      ...donor.toMap(), 
      'phones': phones,
      'lastUpdatedAt': now,
      'syncStatus': 'pending',
      'isEdited': true,
    });
    final box = Hive.box(donorsBox);
    
    // Merge if exists to preserve fields not in current view
    final existing = box.get(key);
    Map<String, dynamic> finalData = sanitized;
    if (existing != null) {
      finalData = {...Map<String, dynamic>.from(existing as Map), ...sanitized};
    }

    await box.put(key, finalData);
    await box.flush();

    // Save to donor's HOME branch — never the collecting branch
    if (donor.branchId.isNotEmpty) {
      await LocalStorageService.enqueueSync({
        'type': 'save_donor_branch',
        'branchId': donor.branchId,   // always home branch
        'donorId': donor.id,
        'data': finalData,
      });
    }
    // Also save to global /donors collection for cross-branch lookup
    await LocalStorageService.enqueueSync({
      'type': 'save_donor',
      'donorId': donor.id,
      'data': finalData,
    });

    debugPrint(
        '[DonationsLS] Donor saved & enqueued → ${donor.id} (${donor.name})');
  }

  static Future<void> deleteDonor(String donorId, String branchId) async {
    final box = Hive.box(donorsBox);
    final key = _donorKey(donorId);
    final raw = box.get(key);
    if (raw == null) return;

    final now = DateTime.now().toUtc().toIso8601String();
    final data = Map<String, dynamic>.from(raw as Map);
    
    // ── TOMBSTONE LOCALLY ───────────────────────────────────────────────────
    final updated = {...data, 'syncStatus': 'deleted', 'lastUpdatedAt': now, 'isEdited': true};
    await box.put(key, updated);
    await box.flush();

    // ── ENQUEUE SYNC ────────────────────────────────────────────────────────
    await LocalStorageService.enqueueSync({
      'type': 'delete_donor',
      'donorId': donorId,
    });
    
    if (branchId.isNotEmpty) {
      await LocalStorageService.enqueueSync({
        'type': 'delete_donor_branch',
        'branchId': branchId,
        'donorId': donorId,
      });
    }

    debugPrint('[DonationsLS] Donor marked Deleted (Tombstoned) → $donorId');
  }

  static DonorRecord? findDonorByPhone(String phone) {
    if (phone.isEmpty) return null;
    final normalized = phone.replaceAll(RegExp(r'\D'), '');
    if (normalized.length < 10) return null;

    final box = Hive.box(donorsBox);
    for (var v in box.values) {
      final m = Map<String, dynamic>.from(v as Map);
      if (m['syncStatus'] == 'deleted') continue;
      final d = DonorRecord.fromMap(m);
      for (var p in d.phones) {
        if (p.replaceAll(RegExp(r'\D'), '') == normalized) {
          return d;
        }
      }
    }
    return null;
  }

  static List<DonorRecord> findDonorsByName(String name) {
    if (name.length < 3) return [];
    final search = name.toLowerCase().trim();
    final box = Hive.box(donorsBox);
    return box.values
        .map((v) {
          final m = Map<String, dynamic>.from(v as Map);
          if (m['syncStatus'] == 'deleted') return null;
          return DonorRecord.fromMap(m);
        })
        .whereType<DonorRecord>()
        .where((d) => d.name.toLowerCase().contains(search))
        .toList();
  }

  static List<DonorRecord> getAllDonors([String? branchId]) {
    if (!Hive.isBoxOpen(donorsBox)) return [];
    final box = Hive.box(donorsBox);
    var list = box.values
        .map((v) {
          final m = Map<String, dynamic>.from(v as Map);
          if (m['syncStatus'] == 'deleted') return null;
          final name = (m['name'] as String? ?? '').toLowerCase();
          final id = (m['id'] as String? ?? '').toLowerCase();
          // Filter out donation boxes from donors
          if (id.contains('_box_') || name.startsWith('box ') || name.startsWith('box-')) {
            return null;
          }
          return DonorRecord.fromMap(m);
        })
        .whereType<DonorRecord>();
        
    if (branchId != null && branchId.toLowerCase() != 'all' && branchId.isNotEmpty) {
      list = list.where((d) => d.branchId.toLowerCase().trim() == branchId.toLowerCase().trim());
    }
    
    return list.toList()
      ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
  }

  static Stream<List<DonorRecord>> streamAllDonors([String? branchId]) async* {
    if (!Hive.isBoxOpen(donorsBox)) {
      await LocalStorageService.openBoxSafe(donorsBox);
    }
    yield getAllDonors(branchId);
    await for (final _ in Hive.box(donorsBox).watch()) {
      yield getAllDonors(branchId);
    }
  }

  // ══════════════════════════════════════════════════════════════════════════
  // FIRESTORE → HIVE  (called by SyncService after upload)
  // ══════════════════════════════════════════════════════════════════════════

  static Future<void> downloadAllDonations(String branchId,
      {int days = 90, bool force = false}) async {
    try {
      final normBranch = branchId.toLowerCase().trim();
      final syncKey = 'donations_$normBranch';
      final lastSyncedTs = force ? null : LocalStorageService.getLastSyncedServerTimestamp(syncKey);

      final cutoff = DateTime.now().subtract(Duration(days: days));
      final cutoffStr = DateFormat('yyyy-MM-dd').format(cutoff);

      final List<QueryDocumentSnapshot<Map<String, dynamic>>> docs = [];
      String? maxServerTs = lastSyncedTs;

      final branchesToQuery = <String>[];
      if (normBranch == 'all' || normBranch.isEmpty) {
        final branchesSnap = await FirebaseFirestore.instance.collection('branches').get();
        branchesToQuery.addAll(branchesSnap.docs.map((d) => d.id));
      } else {
        branchesToQuery.add(normBranch);
      }

      for (final bId in branchesToQuery) {
        DocumentSnapshot? lastDoc;
        bool hasMore = true;

        while (hasMore) {
          Query<Map<String, dynamic>> query = FirebaseFirestore.instance
              .collection('branches')
              .doc(bId)
              .collection('donations');

          if (lastSyncedTs != null) {
            query = query.where('updatedAt', isGreaterThan: lastSyncedTs).orderBy('updatedAt', descending: false).limit(500);
          } else {
            query = query.where('date', isGreaterThanOrEqualTo: cutoffStr).orderBy('date', descending: false).limit(500);
          }

          if (lastDoc != null) {
            query = query.startAfterDocument(lastDoc);
          }

          final snap = await query.get();
          docs.addAll(snap.docs);

          if (snap.docs.length < 500) {
            hasMore = false;
          } else {
            lastDoc = snap.docs.last;
          }
        }
      }

      final box = Hive.box(donationsBox);
      int saved = 0;
      final Map<String, dynamic> updates = {};

      for (final doc in docs) {
        if (doc.id == 'credit_ledger') continue;
        final d = doc.data();

        final String? rawBranch = d['branchId'] as String?;
        final docBranch = (rawBranch != null && rawBranch.isNotEmpty)
            ? rawBranch.toLowerCase().trim()
            : (doc.reference.parent.parent?.id ?? normBranch).toLowerCase().trim();
        final date = (d['date'] as String?) ?? _today();
        final localId = (d['localId'] as String?) ?? doc.id;
        final key = _donationKey(docBranch, date, localId);

        final docUpdatedAt = d['updatedAt']?.toString();
        if (docUpdatedAt != null) {
          if (maxServerTs == null || docUpdatedAt.compareTo(maxServerTs) > 0) {
            maxServerTs = docUpdatedAt;
          }
        }

        final existing = box.get(key);
        if (existing == null) {
          updates[key] = _sanitize({
            ...d,
            'firestoreId': doc.id,
            'localId': localId,
            'hiveKey': key,
            'syncStatus': 'synced',
          });
          saved++;
        } else {
          final ex = Map<String, dynamic>.from(existing as Map);
          final localTs = ex['updatedAt']?.toString() ?? ex['lastUpdatedAt']?.toString() ?? '';
          final cloudTs = docUpdatedAt ?? '';
          final cloudIsNewer = cloudTs.compareTo(localTs) >= 0;

          if (ex['syncStatus'] != 'pending' || cloudIsNewer) {
            if (ex['syncStatus'] == 'pending' && !cloudIsNewer) {
              // Log conflict
              LocalStorageService.logSyncConflict(
                collectionKey: 'donations',
                docId: doc.id,
                localData: ex,
                cloudData: d,
              );
            }
            ex['firestoreId'] = doc.id;
            ex['syncStatus']  = 'synced';
            if (cloudIsNewer) {
              ex.addAll(_sanitize({...d, 'firestoreId': doc.id, 'syncStatus': 'synced'}));
            }
            updates[key] = ex;
            saved++;
          }
        }
      }

      if (updates.isNotEmpty) {
        await box.putAll(updates);
      }

      if (maxServerTs != null) {
        await LocalStorageService.setLastSyncedServerTimestamp(syncKey, maxServerTs);
      }

      await _syncReceiptSequence();
      await box.flush();
      debugPrint(
          '[DonationsLS] downloadAllDonations (Delta): merged $saved records '
          '(${docs.length} fetched from Firestore)');
    } catch (e) {
      debugPrint('[DonationsLS] downloadAllDonations error: $e');
    }
  }

  static Future<void> downloadTodayDonations(String branchId) =>
      downloadAllDonations(branchId, days: 1);

  static Future<void> downloadDonors(String branchId, {bool force = false}) async {
    try {
      // ── 30-minute cooldown guard ──────────────────────────────────────────
      if (!force) {
        final settings = Hive.box('app_settings');
        final ttlKey = 'donors_last_download_$branchId';
        final lastStr = settings.get(ttlKey) as String?;
        final last = lastStr != null ? DateTime.tryParse(lastStr) : null;
        final now = DateTime.now();
        if (last != null && now.difference(last) < const Duration(minutes: 30)) {
          debugPrint('[DonationsLS] downloadDonors cooldown active for $branchId — skipping');
          return;
        }
        await settings.put(ttlKey, now.toIso8601String());
      }

      final box = Hive.box(donorsBox);
      
      QuerySnapshot<Map<String, dynamic>> branchSnap;
      if (branchId == 'all' || branchId.isEmpty) {
        branchSnap = await FirebaseFirestore.instance.collectionGroup('donors').get();
      } else {
        branchSnap = await FirebaseFirestore.instance
            .collection('branches')
            .doc(branchId)
            .collection('donors')
            .get();
      }

      final bool isGlobalRequest = branchId == 'all' || branchId.isEmpty;
      final rootSnap = isGlobalRequest
          ? await FirebaseFirestore.instance.collection('donors').get()
          : null;

      final Map<String, dynamic> donorUpdates = {};

      void put(QueryDocumentSnapshot<Map<String, dynamic>> doc) {
        final d = doc.data();
        final key = _donorKey(doc.id);
        final existing = box.get(key) ?? donorUpdates[key];
        
        if (existing == null) {
          donorUpdates[key] = _sanitize({...d, 'id': doc.id, 'syncStatus': 'synced'});
        } else {
          final ex = Map<String, dynamic>.from(existing as Map);
          // Only overwrite if Firestore has a NEWER or equal lastUpdatedAt
          final localTs  = DateTime.tryParse(ex['lastUpdatedAt']?.toString() ?? '') ?? DateTime.fromMillisecondsSinceEpoch(0);
          final cloudTs  = DateTime.tryParse(d['lastUpdatedAt']?.toString() ?? '') ?? DateTime.fromMillisecondsSinceEpoch(0);
          
          final cloudIsNewer = !cloudTs.isBefore(localTs);
          
          if (ex['syncStatus'] != 'pending' || cloudIsNewer) {
            final merged = {...ex, ..._sanitize(d), 'id': doc.id, 'syncStatus': 'synced'};
            donorUpdates[key] = merged;
          }
        }
      }

      for (final doc in branchSnap.docs) {
        put(doc);
      }
      if (rootSnap != null) {
        for (final doc in rootSnap.docs) {
          put(doc);
        }
      }

      if (donorUpdates.isNotEmpty) {
        await box.putAll(donorUpdates);
      }

      await box.flush();
      debugPrint(
          '[DonationsLS] downloadDonors: '
          '${branchSnap.docs.length} branch + ${rootSnap?.docs.length ?? 0} root');
    } catch (e) {
      debugPrint('[DonationsLS] downloadDonors error: $e');
    }
  }

  static Future<void> clearAll() async {
    await Hive.box(donationsBox).clear();
    await Hive.box(donorsBox).clear();
    await Hive.box(bankSlipsBox).clear();
    debugPrint('[DonationsLS] Cleared all data.');
  }

  static Future<void> saveBankSlip(BankSlip slip) async {
    final box  = Hive.box(bankSlipsBox);
    final data = slip.toMap();
    data['syncStatus'] = 'pending';
    await box.put(slip.id, data);
    await box.flush();

    await LocalStorageService.enqueueSync({
      'type':     'save_bank_slip',
      'branchId': slip.branchId,
      'slipId':   slip.id,
      'data':     data,
    });
  }

  static Future<List<BankSlip>> getBankSlips({required String branchId}) async {
    if (!Hive.isBoxOpen(bankSlipsBox)) {
      await LocalStorageService.openBoxSafe(bankSlipsBox);
    }
    final box = Hive.box(bankSlipsBox);
    return box.values
        .map((e) => BankSlip.fromMap(Map<String, dynamic>.from(e as Map)))
        .where((s) => s.branchId == branchId)
        .toList()
      ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
  }

  static Future<void> markBankSlipSynced(String id, String firestoreId) async {
    final box      = Hive.box(bankSlipsBox);
    final existing = box.get(id);
    if (existing != null) {
      final data = Map<String, dynamic>.from(existing as Map);
      data['syncStatus']  = 'synced';
      data['firestoreId'] = firestoreId;
      await box.put(id, data);
      await box.flush();
    }
  }

  static Future<void> updateDonationStatus({
    required String branchId,
    required String localId,
    required String date,
    required String newStatus,
    String? firestoreId,
  }) async {
    final key      = _donationKey(branchId, date, localId);
    final box      = Hive.box(donationsBox);
    final existing = box.get(key);

    if (existing != null) {
      final now  = DateTime.now().toUtc().toIso8601String();
      final data = Map<String, dynamic>.from(existing as Map);
      data['status']        = newStatus;
      data['lastUpdatedAt'] = now; // ← timestamp so last-writer-wins resolves correctly
      await box.put(key, data);
      await box.flush();

      await enqueueAuditLog(
        branchId: branchId,
        collection: 'donations',
        documentId: firestoreId ?? data['firestoreId'] ?? localId,
        action: 'status_update',
        userId: 'system',
        username: 'System',
        oldData: Map<String, dynamic>.from(existing as Map),
        newData: data,
        reason: 'Status changed to $newStatus',
      );

      final fsId = firestoreId ?? data['firestoreId']?.toString();
      await LocalStorageService.enqueueSync({
        'type':        'update_donation',
        'branchId':    branchId,
        'firestoreId': fsId,
        // Include lastUpdatedAt so Firestore respects timestamp ordering
        'fields':      {'status': newStatus, 'lastUpdatedAt': now},
      });
    }
  }

  static Future<void> deleteDonation(String hiveKey, String branchId, {
    required String reason,
    required String userId,
    required String username,
  }) async {
    debugPrint('[DonationsLS] deleteDonation called for key: $hiveKey | branch: $branchId');
    final box = Hive.box(donationsBox);
    final raw = box.get(hiveKey);
    if (raw == null) {
      debugPrint('[DonationsLS] ❌ ERROR: Record not found for key: $hiveKey');
      return;
    }

    final data = Map<String, dynamic>.from(raw as Map);
    final now  = DateTime.now().toUtc().toIso8601String();

    // 1. Tombstone locally (Instant UI removal via getAllDonations filter)
    final updated = {
      ...data,
      'syncStatus': 'deleted',
      'lastUpdatedAt': now,
      'isEdited': true,
    };
    await box.put(hiveKey, updated);
    await box.flush();

    // 2. Audit Log for security/financial tracking
    final fsId = data['firestoreId']?.toString() ?? data['localId']?.toString();
    final resolvedDocId = fsId ?? hiveKey.split('__').last;

    await enqueueAuditLog(
      branchId: branchId,
      collection: 'donations',
      documentId: resolvedDocId,
      action: 'delete_donation',
      userId: userId,
      username: username,
      oldData: data,
      newData: {'status': 'deleted', 'deletedAt': now, 'reason': reason},
      reason: reason,
    );

    // 3. Queue for Firestore removal (Enqueue all possible ID candidates to ensure complete deletion)
    final candidates = <String>{};
    if (fsId != null && fsId.isNotEmpty) candidates.add(fsId);
    if (data['localId']?.toString().isNotEmpty == true) candidates.add(data['localId'].toString());
    final lastSegment = hiveKey.split('__').last;
    candidates.add(lastSegment);
    candidates.add(hiveKey); // In case it was uploaded as full key string

    for (final id in candidates) {
      await LocalStorageService.enqueueSync({
        'type': 'delete_donation',
        'branchId': branchId,
        'firestoreId': id,
      });
    }
    
    debugPrint('[DonationsLS] Transaction tombstoned and deletion enqueued: $hiveKey');
  }
}