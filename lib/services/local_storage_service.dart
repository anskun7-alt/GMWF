// lib/services/local_storage_service.dart

import '../utils/ui_stall_monitor.dart';
import 'busy_status.dart';
import 'pre_login_security_service.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:gmwf/services/quota_service.dart';
import 'package:gmwf/services/cloud/cloud_db.dart';
import 'package:gmwf/services/cloud/lan_firestore_gate.dart';
import 'package:gmwf/services/cloud/sync_log.dart';
import 'package:crypto/crypto.dart';
import 'package:collection/collection.dart' show DeepCollectionEquality;
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';
import 'package:intl/intl.dart';
import 'package:uuid/uuid.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;
import 'package:gmwf/services/sync_service.dart';
import 'package:gmwf/services/hourly_dispensary_sync.dart';
import 'camp_session_service.dart';
import 'master_proforma_service.dart';
import 'serials_service.dart';
import 'offline_auth_service.dart';
import 'finance_local_storage.dart';
import 'network_health_service.dart';
import '../tools/legacy_data_migration_adapter.dart';
import '../realtime/realtime_manager.dart';
import '../realtime/realtime_events.dart';
import '../realtime/lan_server.dart';
import '../realtime/lan_host_manager.dart';

class LocalStorageService {
  // ── Box names ──────────────────────────────────────────────────────────────
  static const String usersBox         = 'local_users';
  static const String branchCacheBox = 'branch_data_cache';
  static const String patientsBox      = 'local_patients';
  static const String entriesBox       = 'local_entries';
  static const String syncBox          = 'sync_queue';
  static const String prescriptionsBox = 'local_prescriptions';
  static const String stockBox         = 'local_stock_items';
  static const String branchesBox      = 'local_branches';
  static const String dispensaryBox    = 'local_dispensary';
  static const String medicineRestrictionsBox = 'local_medicine_restrictions';
  static const String masterProformaBox       = 'master_proforma_catalog';
  static const String donationsBox     = 'local_donations';
  static const String donorsBox        = 'local_donors';
  static const String reportsCacheBox   = 'local_reports_cache';
  
  static const String employeesBox       = 'local_employees';
  static const String salaryHistoryBox   = 'local_salary_history';
  static const String attendanceBox      = 'local_employee_attendance';
  static const String salaryLedgerBox    = 'local_employee_salaries';
  static const String financeSettingsBox = 'local_finance_settings';
  static const String branchTransfersBox = 'local_employee_branch_transfers';
  static const String auditLogsBox       = 'local_audit_logs';

  static const String madrassaStudentsBox = 'local_madrassa_students';
  static const String madrassaLogsBox     = 'local_madrassa_logs';
  static const String madrassaHolidaysBox = 'local_madrassa_holidays';
  static const String madrassaFeesBox     = 'local_madrassa_fees';
  static const String schoolStudentsBox   = 'local_school_students';
  static const String schoolLogsBox       = 'local_school_logs';
  static const String schoolTeachersBox   = 'local_school_teachers';
  static const String schoolBooksBox      = 'local_school_books';
  static const String schoolBookLoansBox  = 'local_school_book_loans';
  static const String schoolAuditLogsBox  = 'local_school_audit_logs';
  static const String schoolGradesBox     = 'local_school_grades';
  static const String schoolFeesBox       = 'local_school_fees';
  static const String schoolHomeroomBox   = 'local_school_homeroom';
  static const String financeHolidaysBox = 'local_finance_holidays';
  static const String financeLoansBox    = 'local_finance_loans';
  static const String expensesBox        = 'local_expenses';
  static const String syncMetaBox        = 'local_sync_meta';

  static const String biometricDevicesBox = 'local_biometric_devices';
  static const String biometricCredentialsBox = 'local_biometric_credentials';
  static const String unmappedPunchesBox = 'local_unmapped_punches';
  static const String crossBranchPunchesBox = 'local_cross_branch_punches';
  static const String tokenExceptionsBox = 'local_token_exceptions';
  static const String zktecoPunchDedupBox = 'local_zkteco_punch_dedup'; // [FIX-3.2] Persistent punch dedup store
  static const String dasterkhwaanTokensBox = 'dasterkhwaan_tokens';
  static const String dasterkhwaanCookingBox = 'dasterkhwaan_cooking';
  static const String dasterkhwaanFoodLogsBox = 'dasterkhwaan_food_logs';
  static const String notificationsBox = 'local_notifications';
  static const String deadLetterQueueBox = 'dead_letter_queue';

  // ── ERP Double-Entry Ledger Boxes ───────────────────────────────────────────
  static const String chartOfAccountsBox  = 'org_chart_of_accounts';
  static const String orgBankAccountsBox  = 'org_bank_accounts';

  /// Resolves the currently active branch ID from local settings or cached user data.
  static String? getActiveBranchId() {
    try {
      if (Hive.isBoxOpen('app_settings')) {
        final box = Hive.box('app_settings');
        final uData = box.get('user_data') ?? box.get('currentUser');
        if (uData is Map) {
          final uEmail = (uData['email'] ?? '').toString().toLowerCase().trim();
          final uUser = (uData['username'] ?? uData['usernameLower'] ?? '').toString().toLowerCase().trim();
          final uUid = (uData['uid'] ?? uData['id'] ?? '').toString().trim();
          if (uEmail == 'kashif@khi.com' || uEmail.startsWith('kashif@') || uUser == 'kashif' || uUid == 'e5I5hQJQNpe08MuKmOc937dcMR43') {
            return 'karachi';
          }
          final ub = uData['branchId'] ?? uData['branch'];
          if (ub != null && ub.toString().trim().isNotEmpty && ub.toString().trim().toLowerCase() != 'all') {
            return ub.toString().trim().toLowerCase();
          }
        }
        final b = box.get('selected_branch') ?? box.get('current_branch') ?? box.get('branchId');
        if (b != null && b.toString().trim().isNotEmpty && b.toString().trim().toLowerCase() != 'all') {
          return b.toString().trim().toLowerCase();
        }
      }
    } catch (_) {}
    return null;
  }

  /// Any request status other than pending (approved, rejected, acknowledged, ...) is final:
  /// a later pending copy (an upload, a download, a LAN replay) must never replace it.
  static bool isDecidedRequestStatus(dynamic status) {
    final s = (status ?? '').toString().toLowerCase().trim();
    return s.isNotEmpty && s != 'pending';
  }

  /// Records a decision on this PC: the local request copy (edit requests and restock
  /// requests) and the doctor's pending token-exception list. Without this the requester's
  /// own copy stayed pending and was shown, and uploaded, as pending again.
  static Future<void> markLocalRequestDecided(String requestId, String status,
      {Map<String, dynamic> fields = const {}}) async {
    if (requestId.trim().isEmpty) return;
    final clean = sanitize(Map<String, dynamic>.from(fields));
    for (final boxName in ['local_edit_requests', restockRequestsBox]) {
      try {
        final box = await openBoxSafe(boxName);
        final existing = box.get(requestId);
        if (existing is Map) {
          await box.put(requestId, {
            ...Map<String, dynamic>.from(existing),
            ...clean,
            'status': status,
            'updatedAt': DateTime.now().toIso8601String(),
          });
        }
      } catch (e) {
        debugPrint('[LocalStorageService] markLocalRequestDecided($boxName) error: $e');
      }
    }
    try {
      if (Hive.isBoxOpen('app_settings')) await Hive.box('app_settings').delete('pending_exception_$requestId');
    } catch (_) {}
  }

  /// Whether this PC already knows [requestId] as decided.
  static bool isLocalRequestDecided(String requestId) {
    for (final boxName in ['local_edit_requests', restockRequestsBox]) {
      if (!Hive.isBoxOpen(boxName)) continue;
      final v = Hive.box(boxName).get(requestId);
      if (v is Map && isDecidedRequestStatus(v['status'])) return true;
    }
    return false;
  }

  static Future<void> saveLocalEditRequest(Map<String, dynamic> requestData) async {
    try {
      final box = await openBoxSafe('local_edit_requests');
      final id = (requestData['id'] ?? requestData['requestId'] ?? requestData['docId'] ?? '').toString();
      if (id.isNotEmpty) {
        final existing = box.get(id);
        if (existing is Map) {
          final existingStatus = (existing['status'] ?? '').toString().toLowerCase().trim();
          final incomingStatus = (requestData['status'] ?? 'pending').toString().toLowerCase().trim();
          if (isDecidedRequestStatus(existingStatus) && !isDecidedRequestStatus(incomingStatus)) {
            requestData['status'] = existingStatus;
            if (existing['reviewedAt'] != null) requestData['reviewedAt'] = existing['reviewedAt'];
            if (existing['reviewedBy'] != null) requestData['reviewedBy'] = existing['reviewedBy'];
            if (existing['reviewedByName'] != null) requestData['reviewedByName'] = existing['reviewedByName'];
            if (existing['doctorReason'] != null) requestData['doctorReason'] = existing['doctorReason'];
            if (existing['rejectionReason'] != null) requestData['rejectionReason'] = existing['rejectionReason'];
          }
        }
        final merged = existing is Map ? (Map<String, dynamic>.from(existing)..addAll(requestData)) : requestData;
        await box.put(id, merged);
      }
    } catch (e) {
      debugPrint('[LocalStorageService] saveLocalEditRequest error: $e');
    }
  }

  static const String restockRequestsBox = 'local_restock_requests';

  static Future<void> saveRestockRequest(String branchId, Map<String, dynamic> requestData) async {
    try {
      final box = await openBoxSafe(restockRequestsBox);
      final id = (requestData['id'] ?? requestData['requestId'] ?? '').toString();
      if (id.isNotEmpty) {
        final existing = box.get(id);
        if (existing is Map) {
          final existingStatus = (existing['status'] ?? '').toString().toLowerCase().trim();
          final incomingStatus = (requestData['status'] ?? 'pending').toString().toLowerCase().trim();
          if (isDecidedRequestStatus(existingStatus) && !isDecidedRequestStatus(incomingStatus)) {
            requestData['status'] = existingStatus;
            if (existing['reviewedAt'] != null) requestData['reviewedAt'] = existing['reviewedAt'];
            if (existing['reviewedBy'] != null) requestData['reviewedBy'] = existing['reviewedBy'];
            if (existing['reviewedByName'] != null) requestData['reviewedByName'] = existing['reviewedByName'];
          }
        }
        // sanitize: Hive cannot store FieldValue / Timestamp, and the put used to throw on a
        // request carrying serverTimestamp(), leaving the requester with no local copy at all.
        final clean = sanitize(Map<String, dynamic>.from(requestData));
        final merged = existing is Map ? (Map<String, dynamic>.from(existing)..addAll(clean)) : clean;
        merged['id'] = id;
        merged['branchId'] = branchId;
        merged['status'] ??= 'pending';
        merged['updatedAt'] ??= DateTime.now().toIso8601String();
        await box.put(id, merged);
      }
    } catch (e) {
      debugPrint('[LocalStorageService] saveRestockRequest error: $e');
    }
  }

  static List<Map<String, dynamic>> getPendingRestockRequests(String branchId) {
    try {
      if (!Hive.isBoxOpen(restockRequestsBox)) return [];
      final box = Hive.box(restockRequestsBox);
      final normBranch = branchId.trim().toLowerCase();
      final list = <Map<String, dynamic>>[];
      for (final v in box.values) {
        if (v is Map) {
          final m = Map<String, dynamic>.from(v);
          final b = (m['branchId'] ?? '').toString().trim().toLowerCase();
          final st = (m['status'] ?? '').toString().trim().toLowerCase();
          if ((b.isEmpty || b == normBranch) && st == 'pending') {
            list.add(m);
          }
        }
      }
      list.sort((a, b) => (b['timestamp'] ?? b['updatedAt'] ?? '').toString().compareTo((a['timestamp'] ?? a['updatedAt'] ?? '').toString()));
      return list;
    } catch (e) {
      debugPrint('[LocalStorageService] getPendingRestockRequests error: $e');
      return [];
    }
  }

  /// The dispenser dismisses a restock alert. Recorded locally and uploaded through the queue;
  /// the old direct SDK update usually failed (the request was not in the cloud yet) and the
  /// cloud's pending copy then brought the alert back.
  static Future<void> acknowledgeRestockRequest(String branchId, String reqId) async {
    final nowIso = DateTime.now().toIso8601String();
    try {
      // Keep a local record even when this PC never stored the request, so the cloud's
      // pending copy cannot bring the alert back before the upload lands.
      final box = await openBoxSafe(restockRequestsBox);
      if (box.get(reqId) is! Map) {
        await box.put(reqId, {'id': reqId, 'branchId': branchId, 'status': 'pending'});
      }
    } catch (_) {}
    await markLocalRequestDecided(reqId, 'acknowledged', fields: {'acknowledgedAt': nowIso});
    await enqueueSync({
      'type': 'update_request_status',
      'branchId': branchId,
      'collection': 'restock_requests',
      'requestId': reqId,
      'status': 'acknowledged',
      'requestStatus': 'acknowledged', // enqueueSync overwrites 'status' with the queue state
      'data': {'acknowledgedAt': nowIso},
    });
  }

  static Future<void> updateRestockRequestStatus(String branchId, String reqId, String newStatus) async {
    try {
      final box = await openBoxSafe(restockRequestsBox);
      final existing = box.get(reqId);
      if (existing is Map) {
        final updated = Map<String, dynamic>.from(existing);
        updated['status'] = newStatus;
        updated['updatedAt'] = DateTime.now().toIso8601String();
        await box.put(reqId, updated);
      }
    } catch (e) {
      debugPrint('[LocalStorageService] updateRestockRequestStatus error: $e');
    }
  }

  static Map<String, List<Map<String, dynamic>>> getDefaultBranchFacilities(String branchId) {
    final b = branchId.toLowerCase().trim();
    if (b.contains('gujrat')) {
      return {
        'dispensaries': [{'id': 'main_dispensary', 'name': 'Dispensary'}],
        'dasterkhwaans': [{'id': 'main_dasterkhwaan', 'name': 'Dasterkhwaan'}],
        'madrassas': [{'id': 'main_madrassa', 'name': 'Madrassa'}],
        'schools': [{'id': 'main_school', 'name': 'School'}],
        'camps': [],
      };
    } else if (b.contains('sialkot')) {
      return {
        'dispensaries': [{'id': 'main_dispensary', 'name': 'Dispensary'}],
        'dasterkhwaans': [{'id': 'main_dasterkhwaan', 'name': 'Dasterkhwaan'}],
        'madrassas': [],
        'schools': [],
        'camps': [],
      };
    } else if (b.contains('rawalpindi') || b.contains('pindi')) {
      return {
        'dispensaries': [{'id': 'main_dispensary', 'name': 'Dispensary'}],
        'dasterkhwaans': [{'id': 'main_dasterkhwaan', 'name': 'Dasterkhwaan'}],
        'madrassas': [],
        'schools': [],
        'camps': [],
      };
    } else if (b.contains('karachi')) {
      return {
        'dispensaries': [
          {'id': 'saddar', 'name': 'Saddar Dispensary'},
          {'id': 'haji_camp', 'name': 'Haji Camp Dispensary'},
        ],
        'dasterkhwaans': [{'id': 'main_dasterkhwaan', 'name': 'Dasterkhwaan'}],
        'madrassas': [{'id': 'main_madrassa', 'name': 'Madrassa'}],
        'schools': [],
        'camps': [
          {
            'id': 'saddar',
            'name': 'Saddar Dispensary',
            'status': 'active',
            'isClosed': false,
            'departments': ['dispensary', 'dasterkhwaan'],
            'sessions': ['morning', 'evening'],
          },
          {
            'id': 'haji_camp',
            'name': 'Haji Camp Dispensary',
            'status': 'active',
            'isClosed': false,
            'departments': ['dispensary'],
            'sessions': ['morning', 'evening'],
          },
        ],
      };
    }

    return {
      'dispensaries': [{'id': 'main_dispensary', 'name': 'Dispensary'}],
      'dasterkhwaans': [{'id': 'main_dasterkhwaan', 'name': 'Dasterkhwaan'}],
      'madrassas': [],
      'schools': [],
      'camps': [],
    };
  }

  static Map<String, dynamic> getDefaultSessionConfig(String branchId) {
    return CampSessionService.getDefaultSessionConfig(branchId);
  }

  static String getMadrassaProgramMode(String branchId) {
    final b = branchId.toLowerCase().trim();
    if (b.isEmpty || b == 'all' || b == 'global') return 'both';

    if (Hive.isBoxOpen(branchesBox)) {
      final box = Hive.box(branchesBox);
      final raw = box.get('branch:$b') ?? box.get(b);
      if (raw is Map) {
        if (raw['madrassaProgramMode'] != null && raw['madrassaProgramMode'].toString().isNotEmpty) {
          return raw['madrassaProgramMode'].toString();
        }
        if (raw['madrassaMode'] != null && raw['madrassaMode'].toString().isNotEmpty) {
          return raw['madrassaMode'].toString();
        }
        if (raw['sessionsConfig'] is Map) {
          final s = raw['sessionsConfig'] as Map;
          if (s['madrassa'] is Map) {
            final m = s['madrassa'] as Map;
            if (m['madrassaProgramMode'] != null && m['madrassaProgramMode'].toString().isNotEmpty) {
              return m['madrassaProgramMode'].toString();
            }
            if (m['madrassaMode'] != null && m['madrassaMode'].toString().isNotEmpty) {
              return m['madrassaMode'].toString();
            }
            if (m['isNazraOnly'] == true) return 'nazra_only';
          }
          if (s['madrassaProgramMode'] != null && s['madrassaProgramMode'].toString().isNotEmpty) {
            return s['madrassaProgramMode'].toString();
          }
          if (s['madrassaMode'] != null && s['madrassaMode'].toString().isNotEmpty) {
            return s['madrassaMode'].toString();
          }
          if (s['isNazraOnly'] == true) return 'nazra_only';
        }
        if (raw['isNazraOnly'] == true || raw['madrassaNazraOnly'] == true) return 'nazra_only';
      }
    }
    return 'both';
  }

  static bool isMadrassaNazraOnly(String branchId) {
    return getMadrassaProgramMode(branchId) == 'nazra_only';
  }

  static bool isMadrassaHifzOnly(String branchId) {
    return getMadrassaProgramMode(branchId) == 'hifz_only';
  }

  static bool isMadrassaFeeEnabled(String branchId) {
    if (isMadrassaNazraOnly(branchId)) return false;

    final b = branchId.toLowerCase().trim();
    if (b.isEmpty || b == 'all' || b == 'global') return true;

    if (Hive.isBoxOpen(branchesBox)) {
      final box = Hive.box(branchesBox);
      final raw = box.get('branch:$b') ?? box.get(b);
      if (raw is Map) {
        if (raw['madrassaFeeEnabled'] != null) {
          return raw['madrassaFeeEnabled'] == true;
        }
        if (raw['sessionsConfig'] is Map) {
          final s = raw['sessionsConfig'] as Map;
          if (s['madrassa'] is Map && s['madrassa']['enableFees'] != null) {
            return s['madrassa']['enableFees'] == true;
          }
          if (s['madrassaFeeEnabled'] != null) {
            return s['madrassaFeeEnabled'] == true;
          }
        }
      }
    }
    return true; // Default is enabled (normal behavior)
  }

  static bool isVitalsTokenAllowed(String branchId) {
    final b = branchId.toLowerCase().trim();
    if (b.isEmpty || b == 'all' || b == 'global') return true;

    if (Hive.isBoxOpen(branchesBox)) {
      final box = Hive.box(branchesBox);
      dynamic raw = box.get('branch:$b') ?? box.get(b);
      if (raw == null) {
        for (final val in box.values) {
          if (val is Map) {
            final id = (val['id'] ?? val['branchId'] ?? '').toString().toLowerCase().trim();
            if (id == b) {
              raw = val;
              break;
            }
          }
        }
      }

      if (raw is Map) {
        if (raw['allowVitalsToken'] != null) {
          final v = raw['allowVitalsToken'];
          return v == true || v == 'true' || v == 1;
        }
        if (raw['vitalsTokenEnabled'] != null) {
          final v = raw['vitalsTokenEnabled'];
          return v == true || v == 'true' || v == 1;
        }
        if (raw['sessionsConfig.dispensary.allowVitalsToken'] != null) {
          final v = raw['sessionsConfig.dispensary.allowVitalsToken'];
          return v == true || v == 'true' || v == 1;
        }
        if (raw['sessionsConfig.allowVitalsToken'] != null) {
          final v = raw['sessionsConfig.allowVitalsToken'];
          return v == true || v == 'true' || v == 1;
        }
        if (raw['sessionsConfig'] is Map) {
          final s = raw['sessionsConfig'] as Map;
          if (s['dispensary'] is Map && s['dispensary']['allowVitalsToken'] != null) {
            final v = s['dispensary']['allowVitalsToken'];
            return v == true || v == 'true' || v == 1;
          }
          if (s['dispensary'] is Map && s['dispensary']['vitalsTokenEnabled'] != null) {
            final v = s['dispensary']['vitalsTokenEnabled'];
            return v == true || v == 'true' || v == 1;
          }
          if (s['allowVitalsToken'] != null) {
            final v = s['allowVitalsToken'];
            return v == true || v == 'true' || v == 1;
          }
          if (s['vitalsTokenEnabled'] != null) {
            final v = s['vitalsTokenEnabled'];
            return v == true || v == 'true' || v == 1;
          }
        }
      }
    }
    return true; // Default is allowed
  }

  static bool isDoctorInventoryApprovalAllowed(String branchId) {
    final b = branchId.toLowerCase().trim();
    if (b.isEmpty || b == 'all' || b == 'global') return true;

    if (Hive.isBoxOpen(branchesBox)) {
      final box = Hive.box(branchesBox);
      dynamic raw = box.get('branch:$b') ?? box.get(b);
      if (raw == null) {
        for (final val in box.values) {
          if (val is Map) {
            final id = (val['id'] ?? val['branchId'] ?? '').toString().toLowerCase().trim();
            if (id == b) {
              raw = val;
              break;
            }
          }
        }
      }

      if (raw is Map) {
        if (raw['allowDoctorInventoryApproval'] != null) {
          final v = raw['allowDoctorInventoryApproval'];
          return v == true || v == 'true' || v == 1;
        }
        if (raw['sessionsConfig'] is Map) {
          final s = raw['sessionsConfig'] as Map;
          if (s['dispensary'] is Map && s['dispensary']['allowDoctorInventoryApproval'] != null) {
            final v = s['dispensary']['allowDoctorInventoryApproval'];
            return v == true || v == 'true' || v == 1;
          }
          if (s['allowDoctorInventoryApproval'] != null) {
            final v = s['allowDoctorInventoryApproval'];
            return v == true || v == 'true' || v == 1;
          }
        }
      }
    }
    // Default enabled for Karachi, disabled by default for other branches unless toggled ON
    return b.contains('karachi') || b.contains('haji') || b.contains('saddar') || b.contains('kapaya');
  }

  static bool isDonationBoxAllowed(String branchId) {
    final b = branchId.toLowerCase().trim();
    if (b.isEmpty || b == 'all' || b == 'global') return false;

    if (Hive.isBoxOpen(branchesBox)) {
      final box = Hive.box(branchesBox);
      dynamic raw = box.get('branch:$b') ?? box.get(b);
      if (raw == null) {
        for (final val in box.values) {
          if (val is Map) {
            final id = (val['id'] ?? val['branchId'] ?? '').toString().toLowerCase().trim();
            if (id == b) {
              raw = val;
              break;
            }
          }
        }
      }

      if (raw is Map) {
        if (raw['allowDonationBox'] != null) return raw['allowDonationBox'] == true || raw['allowDonationBox'] == 'true' || raw['allowDonationBox'] == 1;
        if (raw['donationBoxAllowed'] != null) return raw['donationBoxAllowed'] == true || raw['donationBoxAllowed'] == 'true' || raw['donationBoxAllowed'] == 1;
        if (raw['donationBoxEnabled'] != null) return raw['donationBoxEnabled'] == true || raw['donationBoxEnabled'] == 'true' || raw['donationBoxEnabled'] == 1;
        if (raw['sessionsConfig'] is Map) {
          final s = raw['sessionsConfig'] as Map;
          if (s['donationBox'] is Map && s['donationBox']['allowDonationBox'] != null) {
            final v = s['donationBox']['allowDonationBox'];
            return v == true || v == 'true' || v == 1;
          }
          if (s['allowDonationBox'] != null) {
            final v = s['allowDonationBox'];
            return v == true || v == 'true' || v == 1;
          }
          if (s['donationBoxAllowed'] != null) {
            final v = s['donationBoxAllowed'];
            return v == true || v == 'true' || v == 1;
          }
        }
      }
    }
    return false;
  }

  static Future<void> setVitalsTokenAllowed(String branchId, bool allowed) async {
    final b = branchId.toLowerCase().trim();
    if (b.isEmpty || b == 'all' || b == 'global') return;

    if (Hive.isBoxOpen(branchesBox)) {
      final box = Hive.box(branchesBox);
      final raw = box.get('branch:$b');
      final map = raw is Map ? Map<String, dynamic>.from(raw) : <String, dynamic>{'id': b};
      map['allowVitalsToken'] = allowed;
      if (map['sessionsConfig'] is Map) {
        final s = Map<String, dynamic>.from(map['sessionsConfig'] as Map);
        if (s['dispensary'] is Map) {
          final d = Map<String, dynamic>.from(s['dispensary'] as Map);
          d['allowVitalsToken'] = allowed;
          s['dispensary'] = d;
        }
        s['allowVitalsToken'] = allowed;
        map['sessionsConfig'] = s;
      }
      await box.put('branch:$b', map);
    }

    try {
      await FirebaseFirestore.instance.collection('branches').doc(b).set({
        'allowVitalsToken': allowed,
        'sessionsConfig.dispensary.allowVitalsToken': allowed,
        'sessionsConfig.allowVitalsToken': allowed,
        'updatedAt': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));
    } catch (e) {
      debugPrint('[LocalStorageService] setVitalsTokenAllowed firestore error: $e');
    }
  }

  static Future<void> setDonationBoxAllowed(String branchId, bool allowed) async {
    final b = branchId.toLowerCase().trim();
    if (b.isEmpty || b == 'all' || b == 'global') return;

    if (Hive.isBoxOpen(branchesBox)) {
      final box = Hive.box(branchesBox);
      final raw = box.get('branch:$b');
      final map = raw is Map ? Map<String, dynamic>.from(raw) : <String, dynamic>{'id': b};
      map['allowDonationBox'] = allowed;
      map['donationBoxAllowed'] = allowed;
      map['donationBoxEnabled'] = allowed;
      if (map['sessionsConfig'] is Map) {
        final s = Map<String, dynamic>.from(map['sessionsConfig'] as Map);
        if (s['donationBox'] is Map) {
          final d = Map<String, dynamic>.from(s['donationBox'] as Map);
          d['allowDonationBox'] = allowed;
          s['donationBox'] = d;
        } else {
          s['donationBox'] = {'allowDonationBox': allowed};
        }
        s['allowDonationBox'] = allowed;
        s['donationBoxAllowed'] = allowed;
        map['sessionsConfig'] = s;
      }
      await box.put('branch:$b', map);
    }

    try {
      await FirebaseFirestore.instance.collection('branches').doc(b).set({
        'allowDonationBox': allowed,
        'donationBoxAllowed': allowed,
        'donationBoxEnabled': allowed,
        'sessionsConfig.allowDonationBox': allowed,
        'sessionsConfig.donationBox.allowDonationBox': allowed,
        'updatedAt': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));
    } catch (e) {
      debugPrint('[LocalStorageService] setDonationBoxAllowed firestore error: $e');
    }
  }

  // ── Dasterkhwaan Food Details Policy ─────────────────────────────────────────
  static const String dasterkhwaanFoodDetailsPolicyDisabled  = 'disabled';
  static const String dasterkhwaanFoodDetailsPolicyOfficeBoy = 'office_boy';
  static const String dasterkhwaanFoodDetailsPolicyKitchen   = 'kitchen';
  static const String dasterkhwaanFoodDetailsPolicyBoth      = 'both';

  /// Returns the food details logging authorization policy for a branch.
  /// Options: 'disabled' (default), 'office_boy', 'kitchen', 'both'.
  static String getDasterkhwaanFoodDetailsPolicy(String branchId) {
    final b = branchId.toLowerCase().trim();
    if (b.isEmpty || b == 'all' || b == 'global') return dasterkhwaanFoodDetailsPolicyDisabled;

    if (Hive.isBoxOpen(branchesBox)) {
      final box = Hive.box(branchesBox);
      dynamic raw = box.get('branch:$b') ?? box.get(b);
      if (raw == null) {
        for (final val in box.values) {
          if (val is Map) {
            final id = (val['id'] ?? val['branchId'] ?? '').toString().toLowerCase().trim();
            if (id == b) {
              raw = val;
              break;
            }
          }
        }
      }

      if (raw is Map) {
        final policy = raw['dasterkhwaanFoodDetailsPolicy'] ??
            raw['foodDetailsPolicy'] ??
            (raw['sessionsConfig'] is Map && (raw['sessionsConfig'] as Map)['dasterkhwaan'] is Map
                ? (raw['sessionsConfig']['dasterkhwaan'] as Map)['foodDetailsPolicy']
                : null) ??
            (raw['sessionsConfig'] is Map ? (raw['sessionsConfig'] as Map)['foodDetailsPolicy'] : null);
        if (policy != null && policy.toString().trim().isNotEmpty) {
          final p = policy.toString().toLowerCase().trim();
          if (p == 'office_boy' || p == 'kitchen' || p == 'both' || p == 'disabled' || p == 'none') {
            return p == 'none' ? dasterkhwaanFoodDetailsPolicyDisabled : p;
          }
        }
      }
    }
    // Default is disabled as per organizational policy
    return dasterkhwaanFoodDetailsPolicyDisabled;
  }

  static bool canOfficeBoyLogFoodDetails(String branchId) {
    final policy = getDasterkhwaanFoodDetailsPolicy(branchId);
    return policy == dasterkhwaanFoodDetailsPolicyOfficeBoy || policy == dasterkhwaanFoodDetailsPolicyBoth;
  }

  static bool canKitchenLogFoodDetails(String branchId) {
    final policy = getDasterkhwaanFoodDetailsPolicy(branchId);
    return policy == dasterkhwaanFoodDetailsPolicyKitchen || policy == dasterkhwaanFoodDetailsPolicyBoth;
  }

  static Future<void> setDasterkhwaanFoodDetailsPolicy(String branchId, String policy) async {
    final b = branchId.toLowerCase().trim();
    if (b.isEmpty || b == 'all' || b == 'global') return;
    final cleanPolicy = policy.toLowerCase().trim();

    if (Hive.isBoxOpen(branchesBox)) {
      final box = Hive.box(branchesBox);
      final raw = box.get('branch:$b');
      final map = raw is Map ? Map<String, dynamic>.from(raw) : <String, dynamic>{'id': b};
      map['dasterkhwaanFoodDetailsPolicy'] = cleanPolicy;
      map['foodDetailsPolicy'] = cleanPolicy;
      if (map['sessionsConfig'] is Map) {
        final s = Map<String, dynamic>.from(map['sessionsConfig'] as Map);
        if (s['dasterkhwaan'] is Map) {
          final d = Map<String, dynamic>.from(s['dasterkhwaan'] as Map);
          d['foodDetailsPolicy'] = cleanPolicy;
          s['dasterkhwaan'] = d;
        } else {
          s['dasterkhwaan'] = {'foodDetailsPolicy': cleanPolicy};
        }
        s['foodDetailsPolicy'] = cleanPolicy;
        map['sessionsConfig'] = s;
      } else {
        map['sessionsConfig'] = {
          'dasterkhwaan': {'foodDetailsPolicy': cleanPolicy},
          'foodDetailsPolicy': cleanPolicy,
        };
      }
      await box.put('branch:$b', map);
    }

    try {
      await FirebaseFirestore.instance.collection('branches').doc(b).set({
        'dasterkhwaanFoodDetailsPolicy': cleanPolicy,
        'foodDetailsPolicy': cleanPolicy,
        'sessionsConfig.foodDetailsPolicy': cleanPolicy,
        'sessionsConfig.dasterkhwaan.foodDetailsPolicy': cleanPolicy,
        'updatedAt': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));
    } catch (e) {
      debugPrint('[LocalStorageService] setDasterkhwaanFoodDetailsPolicy firestore error: $e');
    }
  }

  static bool hasSchoolFacility(String branchId) {
    final b = branchId.toLowerCase().trim();
    if (b == 'all' || b == 'global' || b.isEmpty) return true;

    if (Hive.isBoxOpen(branchesBox)) {
      final box = Hive.box(branchesBox);
      final raw = box.get('branch:$b');
      if (raw is Map) {
        final facs = raw['facilities'];
        if (facs is Map) {
          final schools = facs['schools'];
          if (schools is List && schools.isNotEmpty) return true;
        }
      }
    }

    final defaults = getDefaultBranchFacilities(branchId);
    final defaultSchools = defaults['schools'];
    return defaultSchools != null && defaultSchools.isNotEmpty;
  }

  static String getBranchName(String branchId) {
    final b = branchId.toLowerCase().trim();
    if (b.contains('gujrat')) return 'Gujrat';
    if (b.contains('sialkot')) return 'Sialkot';
    if (b.contains('pindi') || b.contains('rawalpindi')) return 'Rawalpindi';
    if (b.contains('karachi')) return 'Karachi';
    if (b.isEmpty || b == 'all' || b == 'global') return 'All Branches';
    return branchId.isNotEmpty ? branchId[0].toUpperCase() + branchId.substring(1) : branchId;
  }
  static const String journalEntriesBox   = 'local_finance_journal_entries';
  static const String journalIndexBox     = 'local_finance_journal_index';
  static const String departmentMapBox    = 'local_finance_department_map';

  static String? _hiveDirPath;
  static final Map<String, Completer<Box>> _boxOpenLocks = {};
  static final Map<String, DateTime> _boxLastAccessed = {};
  static final Map<String, int> _activeWriteLocks = {};
  static Timer? _lruEvictionTimer;
  static const int currentHiveSchemaVersion = 2;

  // ── Core permanent boxes (never evicted by LRU) ───────────────────────────
  static const Set<String> coreBoxNames = {
    'app_settings',
    'app_flags',
    usersBox,
    'local_user_module_access',
    syncBox,
    notificationsBox,
    deadLetterQueueBox,
    'issued_token_keys',
    branchCacheBox,
    branchesBox,
    financeSettingsBox,
    syncMetaBox,
    'server_record_versions',
    'realtime_entity_versions',
    'realtime_outbox',
    'realtime_failed_outbox',
    'realtime_outbox_meta',
    'local_submissions',
    'server_sync_queue',
    'local_edit_requests',
    'doctor_prescription_templates',
    'branch_servers',
    'sync_failures',
    'inventory_sync_failures',
    'local',

    // Clinical & Dispensary
    entriesBox,
    patientsBox,
    prescriptionsBox,
    stockBox,
    dispensaryBox,
    medicineRestrictionsBox,
    masterProformaBox,
    tokenExceptionsBox,
    reportsCacheBox,

    // Employees, Attendance, Finance, Payroll, Biometrics
    employeesBox,
    salaryHistoryBox,
    attendanceBox,
    salaryLedgerBox,
    branchTransfersBox,
    auditLogsBox,
    financeHolidaysBox,
    financeLoansBox,
    expensesBox,
    biometricDevicesBox,
    biometricCredentialsBox,
    unmappedPunchesBox,
    crossBranchPunchesBox,
    zktecoPunchDedupBox,
    'payroll_cache',
    chartOfAccountsBox,
    orgBankAccountsBox,
    journalEntriesBox,
    journalIndexBox,
    departmentMapBox,

    // Donations & Welfare
    donationsBox,
    donorsBox,
    dasterkhwaanTokensBox,
    dasterkhwaanCookingBox,
    dasterkhwaanFoodLogsBox,
    'local_donation_boxes',
    'local_box_openings',
    'local_bank_slips',
    'ramadan_registrations',

    // School & Madrassa
    madrassaStudentsBox,
    madrassaLogsBox,
    madrassaHolidaysBox,
    madrassaFeesBox,
    schoolStudentsBox,
    schoolLogsBox,
    schoolTeachersBox,
    schoolBooksBox,
    schoolBookLoansBox,
    schoolAuditLogsBox,
    schoolGradesBox,
    schoolFeesBox,
    schoolHomeroomBox,
  };

  // ── Sensitive PII boxes ───────────────────────────────────────────────────
  static const Set<String> piiBoxNames = {
    patientsBox,
    employeesBox,
    salaryHistoryBox,
    donationsBox,
    madrassaFeesBox,
  };

  /// Generates a canonical token key scoped by branch and serial/number.
  static String getCanonicalTokenKey(String branchId, dynamic serialOrId) {
    final b = branchId.trim().toLowerCase();
    final s = serialOrId.toString().trim().toLowerCase();
    return 'token_${b}_$s';
  }

  /// Generates a canonical patient key scoped by branch, patient ID, and visit ID.
  static String getCanonicalPatientKey(String branchId, String patientId, {String? visitId}) {
    final b = branchId.trim().toLowerCase();
    final p = patientId.trim().toLowerCase();
    final v = (visitId != null && visitId.isNotEmpty) ? visitId.trim().toLowerCase() : 'primary';
    return 'local_patient_${b}_${p}_$v';
  }

  static void setHiveDirectoryPath(String path) {
    _hiveDirPath = path;
  }

  /// Acquires an in-flight write lock for a box to prevent LRU eviction during disk writes.
  static void acquireWriteLock(String boxName) {
    _activeWriteLocks[boxName] = (_activeWriteLocks[boxName] ?? 0) + 1;
    _boxLastAccessed[boxName] = DateTime.now();
  }

  /// Releases the in-flight write lock for a box.
  static void releaseWriteLock(String boxName) {
    final count = _activeWriteLocks[boxName] ?? 0;
    if (count <= 1) {
      _activeWriteLocks.remove(boxName);
    } else {
      _activeWriteLocks[boxName] = count - 1;
    }
  }

  /// Checks if a box currently has an active write operation in progress.
  static bool hasActiveWriteLock(String boxName) => (_activeWriteLocks[boxName] ?? 0) > 0;

  /// Records box access timestamp for LRU eviction tracking.
  static void markBoxAccessed(String boxName) {
    _boxLastAccessed[boxName] = DateTime.now();
  }

  static Box<T> _getOpenBoxSafely<T>(String name) {
    try {
      return Hive.box<T>(name);
    } catch (_) {
      return Hive.box(name) as dynamic;
    }
  }

  /// Isolate-safe and concurrency-safe method to ensure a Hive box is open.
  /// Uses Completer mutex lock so concurrent calls for the same box do not race.
  static Future<Box<T>> ensureBoxOpen<T>(String name) async {
    await _waitForQueueRepair(name);
    markBoxAccessed(name);
    if (Hive.isBoxOpen(name)) {
      return _getOpenBoxSafely<T>(name);
    }

    if (_boxOpenLocks.containsKey(name)) {
      final box = await _boxOpenLocks[name]!.future;
      try {
        return box as Box<T>;
      } catch (_) {
        return box as dynamic;
      }
    }

    final completer = Completer<Box>();
    _boxOpenLocks[name] = completer;

    try {
      final box = await openBoxSafe<T>(name);
      if (!completer.isCompleted) {
        completer.complete(box);
      }
      return box;
    } catch (e, st) {
      if (!completer.isCompleted) {
        completer.completeError(e, st);
      }
      rethrow;
    } finally {
      _boxOpenLocks.remove(name);
    }
  }

  static Future<Box<T>> openBoxSafe<T>(String name) async {
    await _waitForQueueRepair(name);
    markBoxAccessed(name);
    // Opening reads and decodes the whole box file on the UI thread.
    if (!Hive.isBoxOpen(name)) UiStallMonitor.mark('open box $name');
    try {
      return await Hive.openBox<T>(name).timeout(
        const Duration(seconds: 30),
        onTimeout: () {
          throw TimeoutException("Timeout (30s) opening Hive box: $name");
        },
      );
    } on TimeoutException catch (tex, st) {
      debugPrint('[LocalStorageService] ⚠️ Timeout opening "$name" (30s). Retrying once (15s)...');
      await _logStorageError(name, 'Initial open timed out: $tex', st);

      if (Hive.isBoxOpen(name)) {
        debugPrint('[LocalStorageService] ✅ Box "$name" completed opening in background during timeout window.');
        return _getOpenBoxSafely<T>(name);
      }

      try {
        await Future.delayed(const Duration(milliseconds: 500));
        if (Hive.isBoxOpen(name)) {
          debugPrint('[LocalStorageService] ✅ Box "$name" completed opening in background after 500ms delay.');
          return _getOpenBoxSafely<T>(name);
        }
        return await Hive.openBox<T>(name).timeout(
          const Duration(seconds: 15),
          onTimeout: () {
            throw TimeoutException("Retry timeout (15s) opening Hive box: $name");
          },
        );
      } catch (retryEx, retrySt) {
        if (Hive.isBoxOpen(name)) {
          debugPrint('[LocalStorageService] ✅ Box "$name" is open despite retry exception.');
          return _getOpenBoxSafely<T>(name);
        }
        final errStr = retryEx.toString().toLowerCase();
        final isLockError = errStr.contains('lock') || errStr.contains('already open');
        if (isLockError) {
          debugPrint('[LocalStorageService] ⚠️ Lock contention for "$name". Preserving box file on disk without deletion.');
          await _logStorageError(name, 'Lock contention error: $retryEx', retrySt);
          await _surfaceRecoveryNeededEvent(name, 'Lock Contention: $retryEx', false, isTimeout: true);
          rethrow;
        }
        debugPrint('[LocalStorageService] ❌ Retry open timed out for "$name". Preserving box file on disk without deletion.');
        await _logStorageError(name, 'Retry open timed out: $retryEx', retrySt);
        await _surfaceRecoveryNeededEvent(name, 'Timeout: Box file preserved on disk without deletion', false, isTimeout: true);
        rethrow; // DO NOT DELETE BOX ON TIMEOUT
      }
    } catch (e, st) {
      final initialErrStr = e.toString().toLowerCase();
      final isLockContention = initialErrStr.contains('lock') ||
          initialErrStr.contains('already open') ||
          initialErrStr.contains('errno = 32') ||
          initialErrStr.contains('errno = 33') ||
          initialErrStr.contains('another process');

      if (isLockContention) {
        debugPrint('[LocalStorageService] ⚠️ Open attempt locked by another process for "$name": $e. Retrying once...');
      } else {
        debugPrint('[LocalStorageService] ⚠️ Open attempt failed for "$name": $e. Retrying once before backup...');
      }
      await _logStorageError(name, 'Initial open failed: $e', st);

      if (Hive.isBoxOpen(name)) {
        return _getOpenBoxSafely<T>(name);
      }

      try {
        await Future.delayed(const Duration(milliseconds: 500));
        if (Hive.isBoxOpen(name)) {
          return _getOpenBoxSafely<T>(name);
        }
        return await Hive.openBox<T>(name).timeout(
          const Duration(seconds: 15),
          onTimeout: () {
            throw TimeoutException("Retry timeout (15s) opening Hive box: $name");
          },
        );
      } catch (retryEx, retrySt) {
        if (Hive.isBoxOpen(name)) {
          return _getOpenBoxSafely<T>(name);
        }

        final retryErrStr = retryEx.toString().toLowerCase();
        final isRetryLockError = retryErrStr.contains('lock') ||
            retryErrStr.contains('already open') ||
            retryErrStr.contains('errno = 32') ||
            retryErrStr.contains('errno = 33') ||
            retryErrStr.contains('another process');

        if (isRetryLockError) {
          debugPrint('[LocalStorageService] ⚠️ Lock contention / multi-process conflict for "$name": $retryEx. Another app instance is already running. Preserving box file without deletion.');
          await _logStorageError(name, 'Lock contention error: $retryEx', retrySt);
          await _surfaceRecoveryNeededEvent(name, 'Lock Contention (Another instance running): $retryEx', false, isTimeout: true);
          rethrow;
        }

        await _logStorageError(name, 'Retry open failed: $retryEx', retrySt);

        // Only a damaged file is backed up and reset. "Hive not initialised" and file-access
        // errors say nothing about the file: on 2026-10-23 a start without Hive init made every
        // box "fail" here, copying ~160 healthy box files to .bak (311 MB) and trying to reset them.
        if (!_looksLikeCorruption(retryEx)) {
          debugPrint('[LocalStorageService] ❌ Open failed for "$name" ($retryEx) — not file damage; box file left as is.');
          rethrow;
        }
        debugPrint('[LocalStorageService] ❌ Retry failed for "$name": $retryEx. Proceeding to backup + single-box recovery.');

        final backupCreated = await _backupCorruptedBoxFiles(name);

        await _surfaceRecoveryNeededEvent(name, retryEx.toString(), backupCreated, isTimeout: false);

        try {
          debugPrint('[LocalStorageService] Resetting single box "$name" after securing backup (backupCreated: $backupCreated)...');
          await Hive.deleteBoxFromDisk(name);
          return await Hive.openBox<T>(name);
        } catch (err, errSt) {
          debugPrint('[LocalStorageService] ❌ Failed to recreate box "$name": $err');
          await _logStorageError(name, 'Recreation failed: $err', errSt);
          rethrow;
        }
      }
    }
  }

  static Future<void> _logStorageError(String boxName, String error, StackTrace? st) async {
    try {
      final appDir = await getApplicationSupportDirectory();
      final logFile = File(p.join(appDir.path, 'gmwf_storage_errors.log'));
      
      if (await logFile.exists()) {
        final length = await logFile.length();
        if (length > 512000) {
          final oldFile = File(p.join(appDir.path, 'gmwf_storage_errors.log.old'));
          if (await oldFile.exists()) {
            await oldFile.delete();
          }
          await logFile.rename(oldFile.path);
        }
      }

      final logEntry = '${DateTime.now().toIso8601String()} [STORAGE_ERROR] Box: $boxName | $error\nStack: ${st ?? "N/A"}\n---\n';
      await logFile.writeAsString(logEntry, mode: FileMode.append);
    } catch (e) {
      debugPrint('[LocalStorageService] Failed to write storage error log: $e');
    }
  }

  static Future<String?> _getHiveDirectoryPath() async {
    try {
      final sampleBoxes = ['app_settings', usersBox, entriesBox, patientsBox, syncBox];
      for (final name in sampleBoxes) {
        if (Hive.isBoxOpen(name)) {
          final boxPath = Hive.box(name).path;
          if (boxPath != null && boxPath.isNotEmpty) {
            return p.dirname(boxPath);
          }
        }
      }
      final appSupportDir = await getApplicationSupportDirectory();
      if (!kIsWeb && Platform.isWindows) {
        final winHiveDir = p.join(appSupportDir.path, 'gmwf_hive');
        if (await Directory(winHiveDir).exists()) {
          return winHiveDir;
        }
      }
      return appSupportDir.path;
    } catch (e) {
      debugPrint('[LocalStorageService] Error getting Hive directory path: $e');
      return null;
    }
  }

  /// Whether an open error means the box file itself is damaged (and may be reset).
  static bool _looksLikeCorruption(Object error) {
    final s = error.toString().toLowerCase();
    if (s.contains('initialize hive') || s.contains('provide a path')) return false;
    if (error is FileSystemException) return false; // access denied, sharing violation, disk
    if (s.contains('lock') || s.contains('another process') || s.contains('access is denied')) return false;
    if (error is TimeoutException) return false;
    return true;
  }

  /// Backups kept per box; older ones are removed (each is a full copy of the box file).
  static const int _maxBackupsPerBox = 2;

  static Future<bool> _backupCorruptedBoxFiles(String boxName) async {
    try {
      final hivePath = await _getHiveDirectoryPath();
      if (hivePath == null || hivePath.isEmpty) return false;
      final hiveDir = Directory(hivePath);
      if (!await hiveDir.exists()) return false;

      final nowMs = DateTime.now().millisecondsSinceEpoch;
      bool backedUp = false;

      // One backup per box per hour is enough: repeated failures used to copy the same file
      // again on every attempt.
      final existing = await _backupFilesFor(hiveDir, boxName);
      if (existing.isNotEmpty) {
        final newest = await existing.first.lastModified();
        if (DateTime.now().difference(newest) < const Duration(hours: 1)) return true;
      }

      await for (final entity in hiveDir.list()) {
        if (entity is File) {
          final fileName = p.basename(entity.path);
          if (fileName == '$boxName.hive' ||
              fileName == '$boxName.lock' ||
              fileName.startsWith('$boxName.')) {
            final backupPath = p.join(hiveDir.path, '${boxName}_corrupted_${nowMs}_$fileName.bak');
            await entity.copy(backupPath);
            debugPrint('[LocalStorageService] 🛡️ Corrupted box file backed up: $fileName -> ${p.basename(backupPath)}');
            backedUp = true;
          }
        }
      }
      if (backedUp) await _pruneBackups(hiveDir, boxName);
      return backedUp;
    } catch (e) {
      debugPrint('[LocalStorageService] Failed to backup box files for $boxName: $e');
      return false;
    }
  }

  /// This box's backup files, newest first.
  static Future<List<File>> _backupFilesFor(Directory hiveDir, String boxName) async {
    final files = <File>[];
    await for (final entity in hiveDir.list()) {
      if (entity is File) {
        final name = p.basename(entity.path);
        if (name.startsWith('${boxName}_corrupted_') && name.endsWith('.bak')) files.add(entity);
      }
    }
    final stamps = <File, DateTime>{};
    for (final f in files) {
      stamps[f] = await f.lastModified();
    }
    files.sort((a, b) => stamps[b]!.compareTo(stamps[a]!));
    return files;
  }

  /// Keeps the newest [_maxBackupsPerBox] backups of [boxName] (a .hive and its .lock are
  /// separate files of one backup, so files are grouped by their timestamp).
  static Future<void> _pruneBackups(Directory hiveDir, String boxName) async {
    try {
      final files = await _backupFilesFor(hiveDir, boxName);
      final stampOf = RegExp('^${RegExp.escape(boxName)}_corrupted_(\\d+)_');
      final keptStamps = <String>{};
      for (final f in files) {
        final stamp = stampOf.firstMatch(p.basename(f.path))?.group(1) ?? '';
        if (keptStamps.contains(stamp)) continue;
        if (keptStamps.length < _maxBackupsPerBox) {
          keptStamps.add(stamp);
          continue;
        }
        await f.delete();
      }
    } catch (e) {
      debugPrint('[LocalStorageService] Backup pruning for $boxName failed: $e');
    }
  }

  // ── Nested prescription copies ────────────────────────────────────────────
  // Many writers embed "the prescription" into a token with `entry['prescription'] = data`,
  // where data was itself built from a token that already carried a prescription. Each save
  // and each LAN catch-up round wrapped the previous copy again: on the dev PC 2,117 tokens
  // took 47 MB, 40 MB of it prescription.prescription.prescription... (7+ levels, up to
  // 120 KB per token), all decoded on the UI thread at startup and sent in every catch-up.

  static bool _hasRxContent(Map m) {
    return _medicinesOf(m) != null ||
        (m['diagnosis'] != null && m['diagnosis'].toString().trim().isNotEmpty) ||
        (m['complaints'] != null && m['complaints'].toString().trim().isNotEmpty) ||
        (m['complaint'] != null && m['complaint'].toString().trim().isNotEmpty) ||
        (m['condition'] != null && m['condition'].toString().trim().isNotEmpty) ||
        m['injectables'] != null;
  }

  /// The prescription to embed in a token: wrapper maps without prescription content are
  /// unwrapped, and older copies nested inside are dropped.
  static Map<String, dynamic> prescriptionForEmbedding(Map source) {
    var cur = Map<String, dynamic>.from(source);
    var guard = 0;
    // Unwrap while the outer map has no medicines of its own. A wrapper that only carries a
    // diagnosis (SyncService's save_prescription replay sends one, with the real prescription
    // nested inside) used to stop the unwrapping, and the nested copy that held the medicines
    // was then dropped: the dispenser saw the diagnosis and no medicines.
    while (cur['prescription'] is Map && !_hasMedicines(cur) && guard++ < 32) {
      final inner = Map<String, dynamic>.from(cur['prescription'] as Map);
      if (!_hasMedicines(inner) && _hasRxContent(cur)) break; // neither has medicines: keep the outer
      // The wrapper's own fields (diagnosis, times, doctor) fill gaps in the nested copy.
      cur.forEach((k, v) {
        if (k != 'prescription' && v != null && inner[k] == null) inner[k] = v;
      });
      cur = inner;
    }
    cur.remove('prescription');
    final meds = _medicinesOf(cur);
    if (meds != null) {
      // An empty 'medicines' list must not mask a filled 'prescriptions' one (or the reverse).
      if (!_hasNonEmptyList(cur['medicines'])) cur['medicines'] = meds;
      if (!_hasNonEmptyList(cur['prescriptions'])) cur['prescriptions'] = meds;
    }
    return cur;
  }

  static bool _hasNonEmptyList(Object? v) => v is List && v.isNotEmpty;

  /// Which copy of a token's prescription to keep when [incoming] would replace [existing]:
  /// the incoming one, unless it is older (isOlderPrescription) or has no medicines while the
  /// stored one has. An empty or wrapper copy must never replace medicines the doctor
  /// prescribed (cause of "no medicines" on the dispenser). Both are unwrapped and flattened.
  /// A doctor removing every medicine is not supported by this rule: such an edit keeps the
  /// previous list.
  static Map<String, dynamic>? preferredPrescription(Object? incoming, Object? existing) {
    final inc = incoming is Map && incoming.isNotEmpty ? prescriptionForEmbedding(incoming) : null;
    final ex = existing is Map && existing.isNotEmpty ? prescriptionForEmbedding(existing) : null;
    if (inc == null) return ex;
    if (ex == null) return inc;
    return mayReplacePrescription(inc, ex) ? inc : ex;
  }

  /// Integer from a number OR a numeric string (LAN JSON / Firestore may deliver "2"); 0 otherwise.
  /// A plain `as num?` cast threw a TypeError on "2" and aborted the save.
  static int intOf(Object? v) {
    if (v is num) return v.toInt();
    if (v is String) return int.tryParse(v.trim()) ?? double.tryParse(v.trim())?.toInt() ?? 0;
    return 0;
  }

  /// Verifies whether [inc] and [ex] belong to the exact same token scope:
  /// `dateKey + branch/camp + queueType + serial` and same individual patient
  /// (preventing cross-talk across days, camps, queues, or family members sharing a CNIC).
  static bool _isSamePrescriptionScope(Map inc, Map ex) {
    final inSerial = (inc['serial'] ?? inc['id'] ?? '').toString().trim().toUpperCase();
    final exSerial = (ex['serial'] ?? ex['id'] ?? '').toString().trim().toUpperCase();
    final inBranch = (inc['branchId'] ?? '').toString().trim().toLowerCase();
    final exBranch = (ex['branchId'] ?? '').toString().trim().toLowerCase();
    final effectiveBranch = inBranch.isNotEmpty ? inBranch : exBranch;

    if (inBranch.isNotEmpty && exBranch.isNotEmpty && inBranch != 'all' && exBranch != 'all') {
      if (!CampSessionService.areBranchesMatching(inBranch, exBranch)) {
        return false;
      }
    }

    if (inSerial.isNotEmpty && exSerial.isNotEmpty) {
      if (!CampSessionService.isSameSerial(inSerial, exSerial, effectiveBranch)) {
        return false;
      }
    }

    // Camp / Dispensary isolation
    final inCamp = (inc['campId'] ?? inc['dispensaryId'] ?? '').toString().trim().toLowerCase();
    final exCamp = (ex['campId'] ?? ex['dispensaryId'] ?? '').toString().trim().toLowerCase();
    if (inCamp.isNotEmpty &&
        exCamp.isNotEmpty &&
        inCamp != 'all' &&
        exCamp != 'all' &&
        inCamp != inBranch &&
        exCamp != exBranch) {
      if (inCamp != exCamp &&
          !CampSessionService.matchesCamp(
            selectedCamp: exCamp,
            campId: inCamp,
            dispensaryId: inc['dispensaryId']?.toString(),
            dispensaryTag: inc['dispensaryTag']?.toString(),
            serial: inSerial,
          )) {
        return false;
      }
    }

    // DateKey isolation (serials like #5 reset daily; never match across different dates)
    String extractDateKey(Map m, String s) {
      final dk = (m['dateKey'] ?? '').toString().trim();
      if (dk.isNotEmpty) return dk;
      return CampSessionService.getDateKeyFromSerial(s);
    }
    final inDate = extractDateKey(inc, inSerial);
    final exDate = extractDateKey(ex, exSerial);
    if (inDate.isNotEmpty && exDate.isNotEmpty && inDate != exDate) {
      return false;
    }

    // QueueType isolation (serials reset per queue across zakat, non-zakat, and gmwf)
    String normQueue(Object? q, String s) {
      final qs = (q ?? '').toString().trim().toLowerCase();
      if (qs == 'non-zakat' || qs == 'non_zakat' || qs == 'nz') return 'non-zakat';
      if (qs == 'gmwf' || qs == 'g' || qs == 'free') return 'gmwf';
      if (qs == 'zakat' || qs == 'z') return 'zakat';
      if (s.contains('-NZ-')) return 'non-zakat';
      if (s.contains('-G-')) return 'gmwf';
      if (s.contains('-Z-')) return 'zakat';
      return qs;
    }
    final inQueue = normQueue(inc['queueType'], inSerial);
    final exQueue = normQueue(ex['queueType'], exSerial);
    if (inQueue.isNotEmpty && exQueue.isNotEmpty && inQueue != exQueue) {
      return false;
    }

    // Patient ID check (child vs parent or two family members on one CNIC)
    // NOTE: Never fall back to `id` here because on a prescription map `id` is the token serial!
    final inPid = (inc['patientId'] ?? '').toString().trim().toLowerCase();
    final exPid = (ex['patientId'] ?? '').toString().trim().toLowerCase();
    if (inPid.isNotEmpty && exPid.isNotEmpty && !inPid.startsWith('unknown_') && !exPid.startsWith('unknown_')) {
      if (inPid != exPid) return false;
    }

    // CNIC check (prevent unrelated patients from cross-clobbering)
    final inCnic = (inc['patientCnic'] ?? inc['cnic'] ?? '').toString().trim().replaceAll(RegExp(r'[-\s]'), '');
    final exCnic = (ex['patientCnic'] ?? ex['cnic'] ?? '').toString().trim().replaceAll(RegExp(r'[-\s]'), '');
    if (inCnic.isNotEmpty &&
        exCnic.isNotEmpty &&
        !inCnic.startsWith('unknown_') &&
        !exCnic.startsWith('unknown_') &&
        inCnic != '0000000000000' &&
        exCnic != '0000000000000') {
      if (inCnic != exCnic && !inCnic.contains(exCnic) && !exCnic.contains(inCnic)) {
        return false;
      }
    }

    // Family member isolation on a shared CNIC:
    // If two family members share one CNIC, their patientName differs.
    final inName = resolveFirstValidPatientName([inc['patientName'], inc['name'], inc['fullName']]).toLowerCase();
    final exName = resolveFirstValidPatientName([ex['patientName'], ex['name'], ex['fullName']]).toLowerCase();
    if (inName.isNotEmpty && exName.isNotEmpty && inName != exName) {
      final inIdRev = intOf(inc['identityRevision']);
      final exIdRev = intOf(ex['identityRevision']);
      // A receptionist rename on either side (identityRevision differs): same patient whose name
      // was corrected. Rejecting it blocked the doctor's save that still carried the old name.
      final bool isRename = inc['allowIdentityOverride'] == true || inIdRev != exIdRev;
      // Same real patientId on both sides: same person, only the name text differs.
      final bool samePatientId = inPid.isNotEmpty &&
          inPid == exPid &&
          !inPid.startsWith('unknown_');
      final bool hasFull5PartMatch = inSerial.split('-').length >= 5 && inSerial == exSerial;
      if (!isRename && !samePatientId && !hasFull5PartMatch) {
        return false;
      }
    }

    return true;
  }

  /// Whether [incoming] may replace the stored prescription [existing] (see
  /// [preferredPrescription]).
  static bool mayReplacePrescription(Object? incoming, Object? existing) {
    if (existing is! Map || existing.isEmpty) return true;
    if (incoming is! Map || incoming.isEmpty) return false;
    final inc = prescriptionForEmbedding(incoming);
    final ex = prescriptionForEmbedding(existing);
    if (ex.isEmpty) return true;
    if (inc.isEmpty) return false;

    // 1. Scoped Token (dateKey + branch/camp + queueType + serial) & Patient Identity Protection
    if (!_isSamePrescriptionScope(inc, ex)) {
      return false;
    }

    // 2. Medicine Presence Protection: Never replace medicines with an empty or medicine-less list
    final exHasMeds = _hasMedicines(ex);
    final incHasMeds = _hasMedicines(inc);
    if (exHasMeds && !incHasMeds) return false;
    if (!exHasMeds && incHasMeds) return true;

    // 3. Clock-Independent Monotonic Revision Counter Check
    // A higher doctor revision ALWAYS wins, even if the Doctor PC clock is 5 minutes behind!
    final int inRev = intOf(inc['revision'] ?? inc['prescriptionRevision']);
    final int exRev = intOf(ex['revision'] ?? ex['prescriptionRevision']);
    if (inRev > 0 || exRev > 0) {
      if (inRev != exRev) {
        return inRev > exRev;
      }
    }

    // 4. Timestamps Check (updatedAt > completedAt > createdAt) when revisions are equal or absent
    DateTime? at(Map m) => DateTime.tryParse((m['updatedAt'] ?? m['completedAt'] ?? m['createdAt'] ?? '').toString());
    final inAt = at(inc);
    final exAt = at(ex);

    if (inAt != null && exAt != null) {
      if (inAt.isBefore(exAt)) return false; // Strictly older
      return true; // Newer or same-timestamp doctor update (including medicine/injection edits or removals)
    } else if (exAt != null && inAt == null) {
      // Existing is timestamped by doctor; incoming lacks timestamp. Reject incoming!
      return false;
    } else if (exAt == null && inAt != null) {
      // Incoming has doctor timestamp; existing does not. Accept incoming!
      return true;
    }

    // 5. Both un-timestamped and un-revisioned:
    // Protect against dropping prescribed medicines or injections on legacy un-timestamped maps
    final incMeds = _medicinesOf(inc);
    final exMeds = _medicinesOf(ex);
    final incCount = incMeds?.length ?? 0;
    final exCount = exMeds?.length ?? 0;

    if (exCount > incCount) {
      return false;
    }
    if (incCount > exCount) {
      return true;
    }

    if (exMeds != null && incMeds != null) {
      bool hasInj(List list) => list.any((m) {
        if (m is! Map) return false;
        final t = (m['type'] ?? m['dosageForm'] ?? '').toString().toLowerCase();
        final n = (m['name'] ?? '').toString().toLowerCase();
        return t.contains('inj') || t.contains('infusion') || t.contains('drip') || n.contains('inj');
      });
      if (hasInj(exMeds) && !hasInj(incMeds)) {
        return false;
      }
    }

    return true;
  }

  /// Merges [incomingVitals] with [existingVitals] so that non-empty receptionist vitals
  /// (`bp`, `temp`, `sugar`, `weight`, `bloodGroup`, `pulse`, `spo2`, `receptionistVitals`,
  /// `auditTrail`) are NEVER overwritten by empty maps `{}` or `'N/A'` placeholders when a
  /// doctor saves a prescription or a partial entry update arrives.
  static Map<String, dynamic> mergeVitalsPreservingReceptionist(
    Object? incomingVitals,
    Object? existingVitals,
  ) {
    final inc = incomingVitals is Map
        ? Map<String, dynamic>.from(incomingVitals)
        : <String, dynamic>{};
    final ex = existingVitals is Map
        ? Map<String, dynamic>.from(existingVitals)
        : <String, dynamic>{};
    if (ex.isEmpty) return inc;
    if (inc.isEmpty) return ex;

    bool isValidVital(Object? v) {
      if (v == null) return false;
      if (v is Map) return v.isNotEmpty;
      if (v is List) return v.isNotEmpty;
      final s = v.toString().trim();
      return s.isNotEmpty &&
          s.toLowerCase() != 'n/a' &&
          s.toLowerCase() != 'null' &&
          s != '-' &&
          s != '{}';
    }

    final merged = Map<String, dynamic>.from(ex);
    inc.forEach((k, v) {
      final keyStr = k.toString();
      if (keyStr == 'receptionistVitals') {
        if (!isValidVital(merged['receptionistVitals']) && isValidVital(v)) {
          merged['receptionistVitals'] = v;
        }
      } else if (isValidVital(v)) {
        merged[keyStr] = v;
      }
    });
    return merged;
  }

  /// Keeps a token's top-level 'medicines' / 'prescriptions' in step with its embedded
  /// prescription (screens read the top level first). Without medicines in the embedded copy,
  /// a filled list from the stored token [existing] is kept rather than an empty incoming one.
  static void _alignTopLevelMedicines(Map<String, dynamic> entry, Map? existing) {
    final rx = entry['prescription'];
    final meds = rx is Map ? _medicinesOf(rx) : null;
    if (meds != null) {
      entry['medicines'] = meds;
      entry['prescriptions'] = meds;
      return;
    }
    if (existing == null) return;
    for (final k in const ['medicines', 'prescriptions']) {
      if (!_hasNonEmptyList(entry[k]) && _hasNonEmptyList(existing[k])) entry[k] = existing[k];
    }
  }

  static bool _hasMedicines(Map m) => _medicinesOf(m) != null;

  /// The first non-empty medicine list of a prescription map ('medicines', 'prescriptions'
  /// or 'items'), or null. `a ?? b` picked an empty list over a filled one.
  static List? _medicinesOf(Map m) {
    for (final k in const ['medicines', 'prescriptions', 'items']) {
      final v = m[k];
      if (v is List && v.isNotEmpty) return v;
    }
    return null;
  }

  /// Flattens `map['prescription']` in place. True when something was removed.
  static bool flattenEmbeddedPrescription(Map map) {
    final p = map['prescription'];
    if (p is! Map || p['prescription'] == null) return false;
    map['prescription'] = prescriptionForEmbedding(p);
    return true;
  }

  /// One pass over the token and prescription boxes that removes nested prescription copies,
  /// then compacts the boxes so the file shrinks too. Yields every 50 records.
  static Future<int> flattenNestedPrescriptions() => healNestedPrescriptions();

  static Future<int> healNestedPrescriptions() async {
    var fixed = 0;
    for (final name in [entriesBox, prescriptionsBox]) {
      if (!Hive.isBoxOpen(name)) continue;
      final box = Hive.box(name);
      var seen = 0;
      for (final k in box.keys.toList()) {
        final v = box.get(k);
        if (v is Map) {
          final copy = Map<String, dynamic>.from(v);
          var changed = flattenEmbeddedPrescription(copy);
          // A prescription record carrying its own older copy.
          if (name == prescriptionsBox && copy['prescription'] is Map && _hasRxContent(copy)) {
            copy.remove('prescription');
            changed = true;
          }
          if (changed) {
            await box.put(k, copy);
            fixed++;
          }
        }
        if (++seen % 50 == 0) await Future<void>.delayed(Duration.zero);
      }
      if (fixed > 0) {
        try {
          await box.compact();
        } catch (_) {}
      }
    }
    if (fixed > 0) debugPrint('[LocalStorageService] Flattened $fixed nested prescription copies');
    return fixed;
  }

  /// Compacts boxes whose file is mostly overwritten records. Hive compacts on its own only
  /// after 60+ deleted records, so a box of a few large records that are rewritten often
  /// (branch_data_cache: 115 keys, 15 MB live, 35 MB file) never shrinks.
  static Future<void> compactBloatedBoxes() async {
    // Once a day is plenty (each compaction rewrites the file).
    const flag = 'last_box_compaction_day';
    final today = getTodayDateKey();
    if (Hive.isBoxOpen('app_settings')) {
      final s = Hive.box('app_settings');
      if (s.get(flag) == today) return;
      await s.put(flag, today);
    }
    final boxesToCompact = [
      branchCacheBox,
      entriesBox,
      syncBox,
      usersBox,
      patientsBox,
      prescriptionsBox,
      stockBox,
      reportsCacheBox,
      auditLogsBox,
      medicineRestrictionsBox,
    ];
    for (final name in boxesToCompact) {
      if (!Hive.isBoxOpen(name)) continue;
      try {
        await Hive.box(name).compact();
      } catch (e) {
        debugPrint('[LocalStorageService] compact $name failed: $e');
      }
      await Future<void>.delayed(const Duration(milliseconds: 500));
    }
  }

  // ── Oversized LAN queues ──────────────────────────────────────────────────
  // realtime_outbox.hive reached 1.5 GB on a Karachi PC (every flush re-put each queued item
  // with its full payload). Opening it decoded the whole file on the UI thread: 35–70 s
  // frozen at every start. A queue file over [_queueRepairThresholdBytes] is rebuilt in a
  // background isolate before anything opens it; openers wait for that, the start-up loops
  // skip it, and the LAN outbox buffers new messages in memory meanwhile.
  static const int _queueRepairThresholdBytes = 50 * 1024 * 1024;
  static const List<String> _repairableQueues = ['realtime_outbox', 'realtime_failed_outbox'];
  static final Map<String, Future<void>> _queueRepairs = {};

  static bool isBoxUnderRepair(String name) => _queueRepairs.containsKey(name);

  /// Call once after Hive is initialised and before any box is opened (main.dart).
  static void startOversizedQueueRepairs() {
    final dir = _hiveDirPath;
    if (kIsWeb || dir == null || dir.isEmpty) return;
    for (final name in _repairableQueues) {
      try {
        final f = File(p.join(dir, '$name.hive'));
        if (!f.existsSync() || f.lengthSync() < _queueRepairThresholdBytes) continue;
        _queueRepairs[name] = _repairQueue(dir, name, f.lengthSync());
      } catch (e) {
        debugPrint('[LocalStorageService] Queue size check for $name failed: $e');
      }
    }
  }

  static Future<void> _repairQueue(String dir, String name, int sizeBytes) async {
    final started = DateTime.now();
    SyncLog.write('$name is ${sizeBytes ~/ (1024 * 1024)} MB: rebuilding it in the background');
    try {
      final stats = await Isolate.run(() => RealtimeManager.rebuildQueueFile(dir, name));
      SyncLog.write('$name rebuilt in ${DateTime.now().difference(started).inSeconds} s: '
          '${stats['beforeCount']} -> ${stats['afterCount']} items, '
          '${(stats['beforeBytes'] ?? 0) ~/ (1024 * 1024)} MB -> ${(stats['afterBytes'] ?? 0) ~/ 1024} KB');
    } catch (e, st) {
      // The original file is untouched; it opens as before (slowly).
      SyncLog.write('$name rebuild failed, opening it as it is: $e');
      await _logStorageError(name, 'Queue rebuild failed: $e', st);
    } finally {
      _queueRepairs.remove(name);
    }
  }

  static Future<void> _waitForQueueRepair(String name) async {
    final repair = _queueRepairs[name];
    if (repair != null) await repair;
  }

  /// Startup housekeeping: trims every box's backups to the newest [_maxBackupsPerBox].
  static Future<void> pruneAllBoxBackups() async {
    try {
      final hivePath = await _getHiveDirectoryPath();
      if (hivePath == null || hivePath.isEmpty) return;
      final hiveDir = Directory(hivePath);
      if (!await hiveDir.exists()) return;
      final boxNames = <String>{};
      await for (final entity in hiveDir.list()) {
        if (entity is File) {
          final name = p.basename(entity.path);
          final i = name.indexOf('_corrupted_');
          if (i > 0 && name.endsWith('.bak')) boxNames.add(name.substring(0, i));
        }
      }
      for (final b in boxNames) {
        await _pruneBackups(hiveDir, b);
      }
    } catch (e) {
      debugPrint('[LocalStorageService] Backup pruning failed: $e');
    }
  }

  static Future<void> _surfaceRecoveryNeededEvent(String boxName, String error, bool backupCreated, {bool isTimeout = false}) async {
    try {
      final appDir = await getApplicationSupportDirectory();
      final recoveryFile = File(p.join(appDir.path, 'gmwf_data_recovery_needed.json'));
      List<dynamic> existing = [];
      if (await recoveryFile.exists()) {
        try {
          final content = await recoveryFile.readAsString();
          existing = jsonDecode(content) as List<dynamic>;
        } catch (parseErr) {
          final nowMs = DateTime.now().millisecondsSinceEpoch;
          final corruptedJsonBackup = File(p.join(appDir.path, 'gmwf_data_recovery_needed_corrupted_$nowMs.json.bak'));
          await recoveryFile.copy(corruptedJsonBackup.path);
          debugPrint('[LocalStorageService] ⚠️ Recovery JSON corrupted. Backed up to ${p.basename(corruptedJsonBackup.path)}: $parseErr');
        }
      }
      existing.add({
        'boxName': boxName,
        'timestamp': DateTime.now().toIso8601String(),
        'error': error,
        'backupCreated': backupCreated,
        'isTimeout': isTimeout,
      });
      await recoveryFile.writeAsString(jsonEncode(existing));
    } catch (e) {
      debugPrint('[LocalStorageService] Failed to record recovery event: $e');
    }
  }

  static Future<List<File>> getUnrecoveredBackups() async {
    final List<File> backups = [];
    try {
      final hivePath = await _getHiveDirectoryPath();
      if (hivePath == null || hivePath.isEmpty) return backups;
      final hiveDir = Directory(hivePath);
      if (!await hiveDir.exists()) return backups;

      await for (final entity in hiveDir.list()) {
        if (entity is File && entity.path.contains('_corrupted_') && entity.path.endsWith('.bak')) {
          backups.add(entity);
        }
      }
    } catch (e) {
      debugPrint('[LocalStorageService] Error scanning for backup files: $e');
    }
    return backups;
  }

  static Future<void> checkForUnrecoveredBackups() async {
    final backups = await getUnrecoveredBackups();
    if (backups.isNotEmpty) {
      debugPrint('[LocalStorageService] ⚠️ WARNING: Found ${backups.length} unrecovered corrupted box backup (.bak) files on disk:');
      for (final f in backups) {
        debugPrint('  -> ${p.basename(f.path)} (${await f.length()} bytes)');
      }
    }
  }

  static Future<bool> restoreBoxFromBackup(String boxName, String backupFilePath) async {
    try {
      final backupFile = File(backupFilePath);
      if (!await backupFile.exists()) {
        debugPrint('[LocalStorageService] Restore failed: Backup file does not exist at $backupFilePath');
        return false;
      }

      final hivePath = await _getHiveDirectoryPath();
      if (hivePath == null || hivePath.isEmpty) return false;

      if (Hive.isBoxOpen(boxName)) {
        await Hive.box(boxName).close();
      }

      final targetHivePath = p.join(hivePath, '$boxName.hive');
      await backupFile.copy(targetHivePath);
      debugPrint('[LocalStorageService] ✅ Box "$boxName" restored from ${p.basename(backupFilePath)} -> $targetHivePath');

      await Hive.openBox(boxName);
      return true;
    } catch (e) {
      debugPrint('[LocalStorageService] ❌ Failed to restore box "$boxName" from backup: $e');
      return false;
    }
  }

  /// Small boxes every role uses (settings, users, sync and LAN bookkeeping).
  static const Set<String> _alwaysBoxes = {
    'app_settings', 'app_flags', usersBox, 'local_user_module_access', syncBox, notificationsBox,
    deadLetterQueueBox, 'issued_token_keys', branchCacheBox, branchesBox, financeSettingsBox,
    syncMetaBox, 'server_record_versions', 'realtime_entity_versions', 'realtime_outbox',
    'realtime_failed_outbox', 'realtime_outbox_meta', 'local_submissions', 'server_sync_queue', 'local_edit_requests',
    'branch_servers', 'sync_failures', 'inventory_sync_failures', 'local', biometricDevicesBox,
    restockRequestsBox, // small; request guards must see it after a restart
  };

  /// Local boxes each upload type writes to after its cloud write. Those cloud writes are not
  /// all idempotent (salary ledger, loans and stock use increments), so the boxes have to be
  /// open before the cloud write starts: a closed box afterwards would fail the item, and the
  /// retry would apply the increment again.
  static const Map<String, Set<String>> syncTypeBoxes = {
    'save_patient': {patientsBox, 'app_flags'},
    'delete_patient': {patientsBox, 'app_flags'},
    'save_entry': {entriesBox, 'issued_token_keys'},
    'save_prescription': {entriesBox, prescriptionsBox},
    'update_serial_status': {entriesBox},
    'approve_token_exception': {entriesBox, tokenExceptionsBox, 'issued_token_keys'},
    'save_donation': {donationsBox},
    'update_donation': {donationsBox},
    'delete_donation': {donationsBox},
    'save_donor': {donorsBox},
    'save_donor_branch': {donorsBox},
    'save_bank_slip': {'local_bank_slips'},
    'save_employee': {employeesBox},
    'save_salary_history': {salaryHistoryBox},
    'save_attendance_record': {attendanceBox, 'app_flags'},
    'save_biometric_log': {attendanceBox, 'app_flags'},
    'save_employee_attendance': {attendanceBox, 'app_flags'},
    'save_attendance': {attendanceBox, 'app_flags'},
    'save_salary_ledger': {salaryLedgerBox},
    'save_finance_settings': {financeSettingsBox},
    'save_branch_transfer': {branchTransfersBox},
    'save_finance_holiday': {financeHolidaysBox},
    'save_finance_loan': {financeLoansBox},
    'save_audit_log': {auditLogsBox},
    'save_expense': {expensesBox},
    'void_expense': {expensesBox},
    'save_dasterkhwan_tokens': {dasterkhwaanTokensBox},
    'save_food_token': {dasterkhwaanTokensBox},
    'save_dasterkhwan_entry': {dasterkhwaanTokensBox},
    'save_dasterkhwan_food_log': {dasterkhwaanFoodLogsBox},
    'save_madrassa_log': {madrassaLogsBox},
    'save_madrassa_daily_log': {madrassaLogsBox},
    'save_madrassa_attendance': {madrassaLogsBox},
    'enrollment': {madrassaLogsBox},
    'status_change': {madrassaLogsBox},
    'ptm_reschedule': {madrassaLogsBox},
    'save_madrassa_student': {madrassaStudentsBox},
    'save_madrassa_admission': {madrassaStudentsBox},
    'save_donation_box': {'local_donation_boxes'},
    'save_box_opening': {'local_box_openings'},
    'save_school_daily_log': {schoolLogsBox},
    'save_school_teacher_log': {schoolLogsBox},
  };

  /// Generic `collection` uploads update the matching school box when it is open.
  static const Map<String, String> _syncCollectionBoxes = {
    'school_students': schoolStudentsBox,
    'school_teachers': schoolTeachersBox,
    'school_teacher_attendance': schoolLogsBox,
    'school_attendance': schoolLogsBox,
    'school_books': schoolBooksBox,
    'school_book_loans': schoolBookLoansBox,
    'school_grades': schoolGradesBox,
    'school_fees': schoolFeesBox,
  };

  static Set<String> boxesForSyncType(String type, {String? collection}) {
    final boxes = <String>{...?syncTypeBoxes[type]};
    final col = collection?.trim() ?? '';
    if (col.isNotEmpty) {
      for (final e in _syncCollectionBoxes.entries) {
        if (col.contains(e.key)) boxes.add(e.value);
      }
    }
    return boxes;
  }

  /// Opens the boxes an upload of [type] writes to. Throws if one cannot be opened, so the
  /// item fails before its cloud write instead of after it.
  static Future<void> ensureBoxesForSyncType(String type, {String? collection}) async {
    for (final name in boxesForSyncType(type, collection: collection)) {
      await ensureBoxOpen(name);
    }
  }

  /// The role saved by the last login on this PC (HomeRouter._cacheUserDataLocally), or ''.
  static String _cachedStartupRole() {
    try {
      if (!Hive.isBoxOpen('app_settings')) return '';
      final s = Hive.box('app_settings');
      final user = s.get('user_data') ?? s.get('currentUser');
      final role = (s.get('user_role') ?? (user is Map ? user['role'] : null) ?? '').toString();
      return role.toLowerCase().trim();
    } catch (_) {
      return '';
    }
  }

  // ── Role scope ────────────────────────────────────────────────────────────
  // Each module's boxes, including the boxes of other modules its screens read (the madrassa
  // overview and the dasterkhwaan stock page show audit logs, the office boy records donations,
  // the dispensary links staff patients to employees).
  static const Set<String> _clinicalBoxes = {
    patientsBox, entriesBox, prescriptionsBox, stockBox, dispensaryBox, medicineRestrictionsBox,
    masterProformaBox, tokenExceptionsBox, reportsCacheBox, 'doctor_prescription_templates',
    employeesBox,
  };
  static const Set<String> _madrassaBoxes = {
    madrassaStudentsBox, madrassaLogsBox, madrassaHolidaysBox, madrassaFeesBox, auditLogsBox,
    ..._teacherPunchBoxes,
  };
  static const Set<String> _schoolBoxes = {
    schoolStudentsBox, schoolLogsBox, schoolTeachersBox, schoolBooksBox, schoolBookLoansBox,
    schoolAuditLogsBox, schoolGradesBox, schoolFeesBox, schoolHomeroomBox,
    ..._teacherPunchBoxes,
  };
  /// Teacher punches (ZkTecoNetworkService) resolve the PIN through these before writing the
  /// madrassa/school log.
  static const Set<String> _teacherPunchBoxes = {
    biometricCredentialsBox, employeesBox, unmappedPunchesBox, crossBranchPunchesBox,
  };
  static const Set<String> _donationBoxes = {
    donationsBox, donorsBox, 'local_donation_boxes', 'local_box_openings', 'local_bank_slips',
    auditLogsBox,
  };
  static const Set<String> _dasterkhwaanBoxes = {
    dasterkhwaanTokensBox, dasterkhwaanCookingBox, dasterkhwaanFoodLogsBox, ..._donationBoxes,
  };
  static const Set<String> _welfareBoxes = {'ramadan_registrations', ..._donationBoxes};

  /// Module boxes for one role, following HomeRouter._getScreenByRole (the screen a role lands
  /// on decides what it reads). null: the role works across modules (admin-level, server,
  /// supervisor, manager, finance/HR and any other role routed to the modular dashboard).
  static Set<String>? moduleBoxesForRole(String role) {
    final r = role.toLowerCase().trim();
    final n = r.replaceAll('_', ' ').replaceAll('-', ' ').trim();
    if (n.isEmpty || n == 'unknown') return null;
    final isHybridDesk = r.contains('hybrid') ||
        (r.contains('rec') && r.contains('dis')) ||
        (r.contains('doc') && r.contains('rec')) ||
        (r.contains('doc') && r.contains('dis'));
    if (isHybridDesk) return _clinicalBoxes;
    switch (n) {
      case 'doctor':
      case 'receptionist':
      case 'dispenser':
      case 'dispensar':
      case 'pharmacist':
      case 'inventory':
        return _clinicalBoxes;
      case 'office boy':
      case 'dasterkhwaan office boy':
      case 'food token generator':
      case 'dasterkhwaan token generator':
      case 'token generator':
      case 'dasterkhwaan':
      case 'kitchen':
      case 'dasterkhwaan kitchen':
        return _dasterkhwaanBoxes;
      case 'donations':
      case 'donation':
      case 'donations officer':
        return _donationBoxes;
      case 'ramadan':
      case 'welfare':
      case 'ramadan welfare':
      case 'rations':
      case 'libaas':
        return _welfareBoxes;
    }
    // Parents and guardians (school ones too) land on MadrassaGuardianScreen.
    if (n.contains('parent') || n.contains('guardian')) return _madrassaBoxes;
    if (n.contains('madrassa')) return _madrassaBoxes;
    if (n.contains('school') || n.contains('principal')) return _schoolBoxes;
    return null;
  }

  /// Boxes this PC's user works with, or null when the role uses every module (or is not known
  /// yet). Boxes outside it are not opened at startup, background clean-ups skip them, and the
  /// LRU timer closes them again once idle.
  static Set<String>? _roleScope;

  @visibleForTesting
  static Set<String>? get roleScope => _roleScope;

  static Set<String>? _scopeForRoles(Iterable<String> roles) {
    final scope = <String>{..._alwaysBoxes};
    for (final role in roles) {
      final boxes = moduleBoxesForRole(role);
      if (boxes == null) return null;
      scope.addAll(boxes);
    }
    return scope.length > _alwaysBoxes.length ? scope : null;
  }

  /// Sets the scope from the logged-in user's role (HomeRouter / login cache it at sign-in).
  static void setRoleScope(String role) {
    _roleScope = _scopeForRoles([role]);
    debugPrint('[LocalStorageService] Role "$role" scope: ${_roleScope == null ? 'all modules' : '${_roleScope!.length} boxes'}');
  }

  /// Whether this PC's role works with [name]. Clean-ups, migrations and refreshes check this
  /// before opening a box, so a madrassa PC never loads the dispensary's token history.
  static bool roleUsesBox(String name) => _roleScope == null || _roleScope!.contains(name);

  /// Whether a replicated change (LAN event, cloud refresh) for [names] should be applied here.
  /// Boxes the role uses are opened if needed; a closed box of another module stays closed and
  /// the change is skipped, since opening it would decode the whole file for data this PC does
  /// not show. The change is on the LAN server and in the cloud either way.
  static Future<bool> prepareBoxesForIncoming(Iterable<String> names) async {
    for (final name in names) {
      if (Hive.isBoxOpen(name)) continue;
      if (!roleUsesBox(name)) return false;
      await ensureBoxOpen(name);
    }
    return true;
  }

  /// Resolves the union of Hive boxes required for a set of roles/modules.
  static Set<String> getBoxesForRoles(List<String> roles) => _scopeForRoles(roles) ?? Set<String>.from(coreBoxNames);

  /// Starts the LRU eviction timer to safely close on-demand boxes idle for >15 minutes.
  /// Boxes the role works with (see [roleUsesBox]) stay open; another module's box opened for a
  /// one-off need (an upload, an old-history lookup) is closed again once idle. Roles that use
  /// every module keep all of [coreBoxNames] open.
  static void startLruEvictionTimer({
    Duration checkInterval = const Duration(minutes: 5),
    Duration idleTimeout = const Duration(minutes: 15),
  }) {
    _lruEvictionTimer?.cancel();
    _lruEvictionTimer = Timer.periodic(checkInterval, (_) async {
      final now = DateTime.now();
      final openedBoxNames = <String>[];
      for (final key in _boxLastAccessed.keys) {
        if (Hive.isBoxOpen(key)) {
          openedBoxNames.add(key);
        }
      }

      for (final name in openedBoxNames) {
        final keep = _roleScope == null ? coreBoxNames.contains(name) : roleUsesBox(name);
        if (keep || hasActiveWriteLock(name)) continue;

        final lastAccess = _boxLastAccessed[name] ?? now;
        if (now.difference(lastAccess) >= idleTimeout) {
          try {
            debugPrint('[LocalStorageService LRU] Evicting idle box "$name" (idle for ${now.difference(lastAccess).inMinutes}m)...');
            await Hive.box(name).close();
          } catch (e) {
            debugPrint('[LocalStorageService LRU] Error closing idle box "$name": $e');
          }
        }
      }
    });
  }

  /// Checks and runs any required schema migrations across Hive boxes.
  static Future<void> checkAndRunSchemaMigrations() async {
    try {
      if (!Hive.isBoxOpen('app_settings')) {
        await openBoxSafe('app_settings');
      }
      final settings = Hive.box('app_settings');
      final storedVersion = settings.get('hive_schema_version', defaultValue: 1) as int;

      if (storedVersion < currentHiveSchemaVersion) {
        debugPrint('[LocalStorageService] Running Hive schema migration from v$storedVersion to v$currentHiveSchemaVersion...');
        // Migration v1 -> v2: Ensure dead-letter and notifications boxes exist and are clean
        await ensureBoxOpen(notificationsBox);
        await ensureBoxOpen(deadLetterQueueBox);
        await settings.put('hive_schema_version', currentHiveSchemaVersion);
        debugPrint('[LocalStorageService] Hive schema migration completed successfully (v$currentHiveSchemaVersion).');
      }
    } catch (e) {
      debugPrint('[LocalStorageService] Error running schema migration: $e');
    }
  }

  /// Isolates session state when a user logs in or switches branch.
  /// Clears transient token caches if switching branches to prevent cross-branch key pollution.
  static Future<void> isolateSessionBranch(String newBranchId) async {
    try {
      final normBranch = newBranchId.trim().toLowerCase();
      if (normBranch.isEmpty || normBranch == 'all' || normBranch == 'global') return;

      final settings = await ensureBoxOpen('app_settings');
      final lastBranch = settings.get('last_session_branch_id')?.toString().trim().toLowerCase();

      if (lastBranch != null && lastBranch.isNotEmpty && lastBranch != normBranch) {
        debugPrint('[LocalStorageService] Branch switch detected ($lastBranch -> $normBranch). Clearing transient branch caches...');
        if (Hive.isBoxOpen('issued_token_keys')) {
          await Hive.box('issued_token_keys').clear();
        }
      }
      await settings.put('last_session_branch_id', normBranch);
    } catch (e) {
      debugPrint('[LocalStorageService] Error during session branch isolation: $e');
    }
  }

  /// Ensures all clinical/doctor dispensary Hive boxes are open and ready for use.
  static Future<void> ensureDoctorBoxesOpen() async {
    final clinicalBoxes = [
      entriesBox,
      patientsBox,
      prescriptionsBox,
      stockBox,
      dispensaryBox,
      medicineRestrictionsBox,
      masterProformaBox,
      tokenExceptionsBox,
      reportsCacheBox,
      'issued_token_keys',
      'app_settings',
      branchesBox,
      syncBox,
      notificationsBox,
      deadLetterQueueBox,
    ];
    for (final name in clinicalBoxes) {
      try {
        await ensureBoxOpen(name);
      } catch (e) {
        debugPrint('[LocalStorageService.ensureDoctorBoxesOpen] Error opening box "$name": $e');
      }
    }
  }

  /// Initializes core boxes and then loads boxes for specific active roles.
  /// Opens boxes in parallel batches of 6 so the event-loop is never blocked
  /// for more than one box-open at a time, preventing "Not Responding" freezes.
  static Future<void> initForRoles(List<String> roles) async {
    UiStallMonitor.mark('LocalStorageService.initForRoles');
    // Screens list every role that may use them (the madrassa dashboard also names chairman
    // and HQ). Roles that use every module already had everything opened by init(), so only
    // the module roles count here; the screen's boxes join this PC's scope so the LRU timer
    // keeps them (a hybrid desk, an office boy taking donations).
    final wanted = <String>{..._alwaysBoxes};
    for (final r in roles) {
      wanted.addAll(moduleBoxesForRole(r) ?? const <String>{});
    }
    if (_roleScope != null) _roleScope = {..._roleScope!, ...wanted};
    debugPrint('[LocalStorageService.initForRoles] roles: $roles');
    await _openBoxesInBatches(wanted);
    startLruEvictionTimer();
  }

  /// Called when a user signs in (HomeRouter caches their role): sets this PC's scope from the
  /// role and opens its boxes before its screen is built. A role that uses every module opens
  /// all of [coreBoxNames], e.g. an admin signing in on a PC that last ran a madrassa desk.
  static Future<void> activateRole(String role) async {
    setRoleScope(role);
    await _openBoxesInBatches(_roleScope ?? coreBoxNames);
  }

  static Future<void> _openBoxesInBatches(Iterable<String> names) async {
    final boxNames = names.where((n) => !Hive.isBoxOpen(n) && !isBoxUnderRepair(n)).toList();
    if (boxNames.isEmpty) return;
    debugPrint('[LocalStorageService] Opening ${boxNames.length} Hive boxes in staggered batches...');

    // Tell the user what's happening (only when there's real work, so repeat calls don't flash).
    final status = BusyStatus.begin(
      'Loading your data',
      detail: 'Opening ${boxNames.length} record stores',
      blocking: true,
      timeout: const Duration(seconds: 25),
    );

    // Large boxes that take significant decode time:
    const heavyBoxes = {
      entriesBox,
      patientsBox,
      prescriptionsBox,
      'local_users',
      'local_donations',
      dasterkhwaanTokensBox,
    };

    final heavy = boxNames.where((n) => heavyBoxes.contains(n)).toList();
    final light = boxNames.where((n) => !heavyBoxes.contains(n)).toList();
    final totalCount = boxNames.length;
    var openedCount = 0;

    try {
      await BusyStatus.waitForPaint();

      // 1. Heavy boxes: opened one by one with guaranteed paint before decode
      for (final name in heavy) {
        if (Hive.isBoxOpen(name)) {
          openedCount++;
          continue;
        }
        status.update('Loading your data', detail: 'Decoding $name store ($openedCount of $totalCount)...');
        await BusyStatus.waitForPaint();
        try {
          await ensureBoxOpen(name);
        } catch (e) {
          debugPrint('[LocalStorageService] Error opening heavy box "$name": $e');
        }
        openedCount++;
        // Yield 20 ms to the event loop so Windows message pump processes window events
        await Future.delayed(const Duration(milliseconds: 20));
      }

      // 2. Light boxes: opened in small pairs with frame breathing
      const batchSize = 2;
      for (int i = 0; i < light.length; i += batchSize) {
        final batch = light.sublist(i, (i + batchSize).clamp(0, light.length));
        await Future.wait(
          batch.map((name) async {
            try {
              await ensureBoxOpen(name);
            } catch (e) {
              debugPrint('[LocalStorageService] Error opening box "$name": $e');
            }
          }),
        );
        openedCount = (heavy.length + i + batchSize).clamp(0, totalCount);
        status.update('Loading your data', detail: 'Opened $openedCount of $totalCount record stores');
        // Yield 16 ms to keep UI smooth and responsive
        if (i + batchSize < light.length) {
          await Future.delayed(const Duration(milliseconds: 16));
        }
      }
    } finally {
      status.end();
    }
  }

  static Future<void> init() async {
    debugPrint('[LocalStorageService.init] Initializing core Hive boxes and startup migration...');
    await checkForUnrecoveredBackups();

    // Each role opens only the boxes its screens use (moduleBoxesForRole). Opening all ~75
    // boxes took ~27 s on clinic PCs and kept every module's records in memory on every PC.
    // Roles that use every module (admin-level, server, manager) and a PC whose role is not
    // known yet still open everything here. Another module's box opens on demand
    // (ensureBoxOpen); the uploader opens the boxes an item writes to before uploading it.
    final role = _cachedStartupRole();
    setRoleScope(role);
    final scope = _roleScope;
    final firstBoxes = [
      ...coreBoxNames.where((n) => scope == null || scope.contains(n)),
      if (scope != null) ...scope.where((n) => !coreBoxNames.contains(n)),
    ];
    for (final name in firstBoxes) {
      if (isBoxUnderRepair(name)) continue; // opened when its background rebuild is done
      try {
        await ensureBoxOpen(name);
      } catch (e) {
        debugPrint('[LocalStorageService.init] Warning opening box "$name": $e');
      }
    }
    debugPrint('[LocalStorageService.init] Role "$role": opened ${firstBoxes.length} of ${coreBoxNames.length} boxes');

    if (roleUsesBox(entriesBox)) {
      // Always ensure clinical dispensary boxes are open for Doctor, Receptionist, Dispenser
      // and Hybrid modes (and when the role is not known yet).
      await ensureDoctorBoxesOpen();
    }

    await checkAndRunSchemaMigrations();
    startLruEvictionTimer();

    await LegacyDataMigrationAdapter.runOnce();

    final settings = Hive.box('app_settings');
    if (settings.get('terminal_id') == null) {
      final now = DateTime.now().millisecondsSinceEpoch.toString();
      final tid = now.substring(now.length - 2);
      await settings.put('terminal_id', tid);
    }

    debugPrint('[LocalStorageService.init] Core Hive boxes opened safely.');
    
    // Heavy migrations and clean-ups go through whole boxes on the UI thread; they wait until
    // the first screen is up (they used to start at once and compete with the screen the user
    // was opening). Each runs only where the role uses its boxes, so a madrassa or kitchen PC
    // does not open the dispensary's token history just to clean it.
    unawaited(Future(() async {
      await Future<void>.delayed(const Duration(seconds: 20));
      if (roleUsesBox(stockBox)) {
        try {
          await MasterProformaService.seedDefaultProformaIfEmpty();
          await MasterProformaService.sanitizeAllSavedStockItems();
        } catch (e) {
          debugPrint('[LocalStorageService.init] Error seeding proforma: $e');
        }
      }

      if (roleUsesBox(entriesBox)) {
        try {
          await purgePhantomUnknownTokens('karachi');
        } catch (_) {}

        try {
          await purgeStressTestLeftovers();
        } catch (_) {}

        try {
          await sanitizeLocalEntriesCasingAndUnknowns('default');
        } catch (_) {}
      }

      try {
        if (Hive.isBoxOpen('app_flags')) {
          await Hive.box('app_flags').put('serials_unified_v2', true);
        }
      } catch (_) {}

      try {
        await purgeDuplicateSyncQueue();
      } catch (_) {}

      try {
        if (Hive.isBoxOpen(prescriptionsBox)) {
          final pBox = Hive.box(prescriptionsBox);
          final toDelete = <dynamic>[];
          for (final k in pBox.keys) {
            final kStr = k.toString().toLowerCase();
            if (kStr.startsWith('disp_') || kStr.startsWith('legacy_') || kStr.startsWith('hist_')) {
              toDelete.add(k);
            }
          }
          for (final k in toDelete) {
            await pBox.delete(k);
          }
        }
      } catch (_) {}

      healLegacyHistoricalData().ignore();
      purgeBloatedSyncQueue().ignore();
      compactBloatedBoxes().ignore();
    }));
  }

  static Future<void> compactAllBoxes() async {
    final boxNames = [
      usersBox, patientsBox, entriesBox, syncBox, prescriptionsBox, branchCacheBox,
      stockBox, branchesBox, dispensaryBox, donationsBox, donorsBox,
      medicineRestrictionsBox, reportsCacheBox, 'app_settings', 'app_flags',
      'local_submissions', 'server_sync_queue', 'local_edit_requests',
      employeesBox, salaryHistoryBox, attendanceBox, salaryLedgerBox,
      financeSettingsBox, branchTransfersBox, auditLogsBox,
      madrassaStudentsBox, madrassaLogsBox, madrassaHolidaysBox, madrassaFeesBox, financeHolidaysBox,
      financeLoansBox, expensesBox, zktecoPunchDedupBox,
    ];

    for (final name in boxNames) {
      try {
        if (Hive.isBoxOpen(name)) {
          await Hive.box(name).compact();
        }
      } catch (_) {}
    }
    debugPrint('[LocalStorageService] All Hive boxes compacted.');
  }

  static Future<void> clearAllInventory(String branchId, {String? dispensaryId}) async {
    try {
      if (!Hive.isBoxOpen(stockBox)) {
        await Hive.openBox(stockBox);
      }
      final box = Hive.box(stockBox);
      final activeCamp = dispensaryId?.trim().toLowerCase() ?? '';
      final keysToRemove = <dynamic>[];

      for (final k in box.keys) {
        final val = box.get(k);
        if (val is Map) {
          final itemBranch = (val['branchId'] ?? '').toString().trim().toLowerCase();
          final itemCamp = (val['dispensaryId'] ?? val['campId'] ?? '').toString().trim().toLowerCase();

          bool matchBranch = branchId.isEmpty || branchId == 'default' || itemBranch.isEmpty || itemBranch == 'default' || itemBranch == branchId.toLowerCase();
          bool matchCamp = activeCamp.isEmpty || activeCamp == 'all' || itemCamp.isEmpty || itemCamp == 'all' || itemCamp == activeCamp;

          if (matchBranch && matchCamp) {
            keysToRemove.add(k);
          }
        } else {
          keysToRemove.add(k);
        }
      }

      await box.deleteAll(keysToRemove);
      debugPrint('[LocalStorageService] 🗑️ Cleared ${keysToRemove.length} inventory items locally.');
    } catch (e) {
      debugPrint('[LocalStorageService] Error clearing inventory: $e');
    }
  }


  static Future<void> clearAllData() async {
    final boxNames = [
      usersBox, patientsBox, entriesBox, syncBox, prescriptionsBox, branchCacheBox,
      stockBox, branchesBox, dispensaryBox, donationsBox, donorsBox,
      medicineRestrictionsBox, reportsCacheBox, 'app_settings', 'app_flags',
      'local_submissions', 'server_sync_queue', 'local_edit_requests',
      'server_sync_failed',
      employeesBox, salaryHistoryBox, attendanceBox, salaryLedgerBox,
      financeSettingsBox, branchTransfersBox, auditLogsBox,
      madrassaStudentsBox, madrassaLogsBox, madrassaHolidaysBox, madrassaFeesBox, financeHolidaysBox,
      financeLoansBox, expensesBox,
    ];

    for (final name in boxNames) {
      if (Hive.isBoxOpen(name)) {
        await Hive.box(name).close();
      }
      await Hive.deleteBoxFromDisk(name);
    }
    debugPrint('[LocalStorage] All local data wiped from disk.');
  }


  // ════════════════════════════════════════════════════════════════════════════
  // UTILITIES
  // ════════════════════════════════════════════════════════════════════════════

  static String hashPassword(String password) =>
      sha256.convert(utf8.encode(password)).toString();

  static String? getLastSyncTimestamp(String collectionKey) {
    if (!Hive.isBoxOpen(syncMetaBox)) return null;
    final box = Hive.box(syncMetaBox);
    return box.get('sync_ts_$collectionKey')?.toString();
  }

  static Future<void> setLastSyncTimestamp(String collectionKey, String timestamp) async {
    if (!Hive.isBoxOpen(syncMetaBox)) return;
    final box = Hive.box(syncMetaBox);
    await box.put('sync_ts_$collectionKey', timestamp);
    await box.flush();
  }

  // ════════════════════════════════════════════════════════════════════════════
  // BRANCH DAY CACHE (local-first historic data cache)
  // ════════════════════════════════════════════════════════════════════════════

  static const String _cacheVersion = 'v1';

  static String branchCacheKey(String branchId, String dateKey, String type) =>
      '$_cacheVersion|$branchId|$dateKey|$type';

  static Future<void> putBranchDayCache(
      String branchId, String dateKey, String type, List<Map<String, dynamic>> docs) async {
    try {
      final box = Hive.box(branchCacheBox);
      final key = branchCacheKey(branchId, dateKey, type);
      final sanitizedDocs = docs.map((d) => sanitize(d)).toList();
      await box.put(key, sanitizedDocs);
      await _evictOldBranchCacheEntries(box);
    } catch (e) {
      debugPrint('[LocalStorage] putBranchDayCache error: $e');
    }
  }

  static List<Map<String, dynamic>>? getBranchDayCache(
      String branchId, String dateKey, String type) {
    try {
      if (!Hive.isBoxOpen(branchCacheBox)) return null;
      final box = Hive.box(branchCacheBox);
      final raw = box.get(branchCacheKey(branchId, dateKey, type));
      if (raw == null) return null;
      return (raw as List)
          .map((e) => Map<String, dynamic>.from(e as Map))
          .toList();
    } catch (e) {
      debugPrint('[LocalStorage] getBranchDayCache error: $e');
      return null;
    }
  }

  static Future<void> _evictOldBranchCacheEntries(Box box, {int retentionDays = 180}) async {
    try {
      final cutoff = DateTime.now().subtract(Duration(days: retentionDays));
      final keysToRemove = <dynamic>[];
      for (final k in box.keys) {
        final parts = k.toString().split('|');
        if (parts.length != 4) continue;
        try {
          final date = parseDdMMyy(parts[2]);
          if (date.isBefore(cutoff)) keysToRemove.add(k);
        } catch (_) { continue; }
      }
      if (keysToRemove.isNotEmpty) {
        await box.deleteAll(keysToRemove);
        debugPrint('[LocalStorage] Evicted ${keysToRemove.length} stale branch cache entries');
      }
    } catch (e) {
      debugPrint('[LocalStorage] _evictOldBranchCacheEntries error: $e');
    }
  }


  static DateTime _toDateTime(dynamic value) {
    if (value is Timestamp) return value.toDate().toLocal();
    if (value is DateTime)  return value.toLocal();
    if (value is String) {
      try { return DateTime.parse(value).toLocal(); } catch (_) {}
    }
    return DateTime.now();
  }

  static int calculateAgeFromDob(dynamic dobValue) {
    if (dobValue == null) return 0;
    final DateTime birthDate = _toDateTime(dobValue);
    final DateTime today     = DateTime.now();
    int age = today.year - birthDate.year;
    if (today.month < birthDate.month ||
        (today.month == birthDate.month && today.day < birthDate.day)) {
      age--;
    }
    return age >= 0 ? age : 0;
  }

  static Map<String, dynamic> sanitize(Map<String, dynamic> data) {
    final result = <String, dynamic>{};
    data.forEach((key, value) {
      if (value == null) {
        result[key] = null;
      } else if (value is Timestamp || value is DateTime) {
        final dt = _toDateTime(value);
        result[key] = dt.toIso8601String();
        if (key == 'dob') result['age'] = calculateAgeFromDob(dt);
      } else if (value.runtimeType.toString().contains('FieldValue')) {
        debugPrint('[sanitize] Dropped FieldValue for key: $key');
      } else if (value is Map) {
        result[key] = sanitize(Map<String, dynamic>.from(value));
      } else if (value is List) {
        result[key] = value.map((e) => sanitizeValue(e)).toList();
      } else {
        result[key] = value;
      }
    });
    if (data['dob'] != null) result['age'] = calculateAgeFromDob(data['dob']);
    return result;
  }

  /// Prepares any record map for Cloud Firestore write with optimum cloud storage footprint:
  /// 1. Strips local Hive engine metadata ('syncStatus', 'pendingSync', 'hiveKey', etc.)
  /// 2. Drops redundant bulky Base64 image payloads when a cloud storage URL already exists
  /// 3. Prevents massive string blobs (> 400KB) from causing document write failures
  /// 4. Converts DateTimes to Timestamps for Firestore native indexing
  /// 5. Preserves FieldValue tokens (e.g. FieldValue.serverTimestamp, FieldValue.increment)
  /// 6. Recursively cleans nested Maps and Lists
  static Map<String, dynamic> sanitizeForCloudUpload(Map<dynamic, dynamic> data) {
    final result = <String, dynamic>{};

    final hasProfileUrl = data['profilePictureUrl'] != null &&
        data['profilePictureUrl'].toString().trim().startsWith(RegExp(r'^(http|https|gs)://'));
    final hasIdentUrl = data['identificationUrl'] != null &&
        data['identificationUrl'].toString().trim().startsWith(RegExp(r'^(http|https|gs)://'));
    final hasDegreeUrl = data['degreeUrl'] != null &&
        data['degreeUrl'].toString().trim().startsWith(RegExp(r'^(http|https|gs)://'));
    final hasDocUrl = data['documentUrl'] != null &&
        data['documentUrl'].toString().trim().startsWith(RegExp(r'^(http|https|gs)://'));
    final hasImgUrl = data['imageUrl'] != null &&
        data['imageUrl'].toString().trim().startsWith(RegExp(r'^(http|https|gs)://'));

    const internalKeysToDrop = {
      'syncStatus',
      'pendingSync',
      'synced',
      'lanPushSig',
      'hiveKey',
      'localKey',
      '_attempts',
      'attempts',
      'lastAttempt',
      '_err',
      'lastError',
      'nextRetryAt',
      'lastFailureLoggedAt',
      '_socketId',
      'event_type',
    };

    data.forEach((k, value) {
      if (k == null) return;
      final key = k.toString().trim();
      if (key.isEmpty || key == 'null' || key == 'undefined') return;
      if (internalKeysToDrop.contains(key)) return;

      // Drop heavy base64 when storage URL exists
      if (key == 'profilePictureBase64' && hasProfileUrl) return;
      if (key == 'identificationBase64' && hasIdentUrl) return;
      if (key == 'degreeBase64' && hasDegreeUrl) return;
      if (key == 'documentBase64' && hasDocUrl) return;
      if (key == 'imageBase64' && hasImgUrl) return;

      if (value == null) {
        result[key] = null;
      } else if (value is Timestamp) {
        result[key] = value;
      } else if (value is DateTime) {
        result[key] = Timestamp.fromDate(value);
      } else if (value.runtimeType.toString().contains('FieldValue') || value is FieldValue) {
        result[key] = value;
      } else if (value is Map) {
        result[key] = sanitizeForCloudUpload(value);
      } else if (value is List) {
        result[key] = value.map((item) {
          if (item is Map) {
            return sanitizeForCloudUpload(item);
          }
          if (item is DateTime) {
            return Timestamp.fromDate(item);
          }
          return item;
        }).toList();
      } else {
        result[key] = value;
      }
    });

    return result;
  }

  static dynamic sanitizeValue(dynamic item) {
    if (item is Timestamp || item is DateTime) {
      return _toDateTime(item).toIso8601String();
    }
    if (item is Map) return sanitize(Map<String, dynamic>.from(item));
    return item;
  }

  static DateTime get effectiveNow => RealtimeManager().effectiveNow;
  static String getTodayDateKey() => DateFormat('ddMMyy').format(effectiveNow);

  static DateTime parseDdMMyy(String s) {
    if (s.length != 6) throw FormatException('Invalid date key length: $s');
    final day = int.tryParse(s.substring(0, 2));
    final month = int.tryParse(s.substring(2, 4));
    final yearPart = int.tryParse(s.substring(4, 6));
    if (day == null || month == null || yearPart == null) {
      throw FormatException('Invalid date key components: $s');
    }
    final year = 2000 + yearPart;
    return DateTime(year, month, day);
  }

  static String _nowIso() => DateTime.now().toUtc().toIso8601String();

  /// Checks if a date string, serial, or timestamp belongs to the current month.
  // Called several times per queued item on every sync pass; formatting the month keys anew
  // each time added up over queues of thousands.
  static int _monthKeysFor = -1;
  static String _monthKeyIso = '';
  static String _monthKeyMmyy = '';

  static bool isCurrentMonth(dynamic dateOrSerial, [DateTime? refNow]) {
    final now = refNow ?? effectiveNow;
    final month = now.year * 100 + now.month;
    if (month != _monthKeysFor) {
      _monthKeyIso = DateFormat('yyyy-MM').format(now);
      _monthKeyMmyy = DateFormat('MMyy').format(now);
      _monthKeysFor = month;
    }
    final currentYearMonthIso = _monthKeyIso;
    final currentMonthYearKey = _monthKeyMmyy;

    if (dateOrSerial == null) return false;
    final str = dateOrSerial.toString().trim();
    if (str.isEmpty) return false;

    if (str.startsWith(currentYearMonthIso)) return true;

    if (str.length == 6 && RegExp(r'^\d{6}$').hasMatch(str)) {
      return str.endsWith(currentMonthYearKey);
    }

    final dk = CampSessionService.getDateKeyFromSerial(str);
    if (dk.length == 6 && dk.endsWith(currentMonthYearKey)) return true;

    final dt = DateTime.tryParse(str);
    if (dt != null) {
      return dt.year == now.year && dt.month == now.month;
    }

    return false;
  }

  static String _newLocalId() => const Uuid().v4();

  // ════════════════════════════════════════════════════════════════════════════
  // SYNC QUEUE
  // ════════════════════════════════════════════════════════════════════════════

  static Future<int> purgeDuplicateSyncQueue({bool force = false}) => purgeBloatedSyncQueue(force: force);

  /// Purges bloated, duplicate, and obsolete entries across all sync queue boxes.
  /// True for a queued save_entry fabricated by a migration for an unknown patient: an
  /// explicit `unknown_cnic_*` CNIC, no real name, and no status, prescription or dispense
  /// data. Every other serial action is real work and must never be pruned as a phantom.
  static bool isPhantomQueuedEntry(Map item) {
    final type = (item['type'] ?? item['event_type'] ?? '').toString().trim();
    if (type != 'save_entry') return false;
    final d = item['data'] is Map ? Map<String, dynamic>.from(item['data'] as Map) : <String, dynamic>{};
    dynamic field(String k) => item[k] ?? d[k];
    bool has(String k) {
      final v = field(k);
      if (v == null) return false;
      if (v is String) return v.trim().isNotEmpty && v.trim() != 'null';
      if (v is Map) return v.isNotEmpty;
      if (v is List) return v.isNotEmpty;
      return true;
    }

    final cnic = (field('patientCnic') ?? field('cnic') ?? '').toString().trim();
    if (!cnic.startsWith('unknown_cnic_')) return false;
    final name = (field('patientName') ?? field('name') ?? '').toString().trim().toLowerCase();
    if (name.isNotEmpty && name != 'unknown' && name != 'unknown patient') return false;
    const realWorkFields = [
      'status', 'dispenseStatus', 'dispensedAt', 'dispensedBy', 'dispensedMedicines',
      'prescription', 'prescriptionId', 'medicines', 'doctorName', 'completedAt',
    ];
    return !realWorkFields.any(has);
  }

  static Future<int> purgeBloatedSyncQueue({bool force = false}) async {
    final bool hasBloat = (Hive.isBoxOpen(syncBox) && Hive.box(syncBox).length > 20) ||
        (Hive.isBoxOpen('server_sync_queue') && Hive.box('server_sync_queue').length > 20) ||
        (Hive.isBoxOpen(deadLetterQueueBox) && Hive.box(deadLetterQueueBox).length > 20);

    if (!force && !hasBloat) {
      try {
        if (!Hive.isBoxOpen('app_flags')) await openBoxSafe('app_flags');
        final flags = Hive.box('app_flags');
        final lastStr = flags.get('last_purge_bloated_queue_ts') as String?;
        if (lastStr != null) {
          final lastDt = DateTime.tryParse(lastStr);
          if (lastDt != null && DateTime.now().difference(lastDt).inMinutes < 20) {
            return 0; // Cooldown: run once per 20 minutes max unless forced or bloated
          }
        }
        await flags.put('last_purge_bloated_queue_ts', DateTime.now().toIso8601String());
      } catch (_) {}
    }

    int totalPurged = 0;
    final todayKey = getTodayDateKey();
    final bool isClientConnectedToLan = !LanServer.isRunning && !LanHostManager.isHostRunning && RealtimeManager().hasServerLink;

    for (final boxName in [syncBox, 'server_sync_queue', deadLetterQueueBox]) {
      try {
        if (!Hive.isBoxOpen(boxName)) {
          await openBoxSafe(boxName);
        }
        final box = Hive.box(boxName);
        if (box.isEmpty) continue;

        final initialCount = box.length;
        final Map<String, dynamic> uniqueLatest = {};
        final List<dynamic> keysToDelete = [];

        int processed = 0;
        for (final key in box.keys) {
          processed++;
          if (processed % 25 == 0) {
            await Future.delayed(const Duration(milliseconds: 4));
          }
          final raw = box.get(key);
          if (raw == null || raw is! Map) {
            keysToDelete.add(key);
            continue;
          }
          final item = Map<String, dynamic>.from(raw);
          final type = (item['type'] ?? item['event_type'] ?? '').toString().trim();
          // Only items with no type at all are junk. Many valid actions carry their payload
          // at the top level instead of under 'data' (update_inventory, add_inventory_stock,
          // update_donation, update_request_status, update_madrassa_student, ...); dropping
          // them here silently lost stock changes and edits.
          if (type.isEmpty) {
            keysToDelete.add(key);
            continue;
          }
          // Raw LAN copies of office-boy token batches queued by older LAN servers: the PC
          // that issued the tokens uploads them itself, so this copy would only add a
          // sync_records write (and, if handled, count the tokens twice).
          if (type == 'save_office_boy_token') {
            keysToDelete.add(key);
            continue;
          }

          final isDispensary = isDispensaryActionType(type);
          final itemDateKey = (item['dateKey'] ?? (item['data'] is Map ? item['data']['dateKey'] : null) ?? '').toString().trim();
          String serialDateKey = '';
          final rawSerial = (item['serial'] ?? (item['data'] is Map ? item['data']['serial'] : null))?.toString().trim() ?? '';
          if (rawSerial.isNotEmpty) {
            serialDateKey = CampSessionService.getDateKeyFromSerial(rawSerial);
          }


          // 2. Gateway rule: If this machine is a client station connected to LAN Server,
          // purge dispensary actions from syncBox. The LAN Server uploads them to Firestore.
          if (boxName == syncBox && isDispensary && isClientConnectedToLan) {
            keysToDelete.add(key);
            continue;
          }

          final branchId = (item['branchId'] ?? (item['data'] is Map ? item['data']['branchId'] : '') ?? '').toString().toLowerCase().trim();
          final isSerialAction = {'save_entry', 'save_prescription', 'update_serial_status'}.contains(type);
          final isAttendance = type.contains('attendance') || type.contains('punch') || type == 'zkteco';

          final dMap = item['data'] is Map ? Map<String, dynamic>.from(item['data']) : <String, dynamic>{};

          // Prune phantom unknown patient records fabricated by migrations. Only a bare
          // save_entry with an explicit unknown_cnic_* qualifies: standalone
          // update_serial_status / save_prescription items carry no name or CNIC at all,
          // and deleting them lost real dispense and prescription updates.
          if (isPhantomQueuedEntry(item)) {
            keysToDelete.add(key);
            continue;
          }

          // Prune empty delete actions
          if ((type == 'delete_prescription' || type == 'delete_dispensary')) {
            final s = (item['serial'] ?? dMap['serial'] ?? '').toString().trim();
            final path = (item['path'] ?? '').toString().trim();
            if (s.isEmpty && path.isEmpty) {
              keysToDelete.add(key);
              continue;
            }
          }

          final String entityId;
          if (type == 'save_patient') {
            entityId = (item['patientId'] ?? (item['data'] is Map ? (item['data']['patientId'] ?? item['data']['id'] ?? item['data']['cnic']) : null) ?? item['id'] ?? item['entityId'] ?? '').toString().trim();
          } else if (isSerialAction) {
            entityId = (item['serial'] ?? (item['data'] is Map ? (item['data']['serial'] ?? item['data']['id']) : null) ?? item['entityId'] ?? '').toString().trim();
          } else if (type == 'save_madrassa_fee_payment') {
            // One record per student per month ({year}_{month}_{studentId}). Grouping by
            // student alone (fee items carry no date) kept only one of two queued months and
            // deleted the other, which then never reached the cloud.
            final d = item['data'] is Map ? item['data'] as Map : const {};
            final composite = (item['year'] != null && item['month'] != null && item['studentId'] != null)
                ? '${item['year']}_${item['month']}_${item['studentId']}'
                : '';
            entityId = (item['id'] ?? d['id'] ?? (composite.isNotEmpty ? composite : null) ?? item['entityId'] ?? '').toString().trim();
          } else if (type.contains('madrassa')) {
            entityId = (item['studentId'] ?? (item['data'] is Map ? (item['data']['studentId'] ?? item['data']['id']) : null) ?? item['entityId'] ?? '').toString().trim();
          } else {
            entityId = (item['serial'] ?? item['patientId'] ?? item['employeeId'] ?? item['localId'] ?? (item['data'] is Map ? (item['data']['serial'] ?? item['data']['id']) : null) ?? item['id'] ?? item['entityId'] ?? '').toString().trim();
          }

          // Prune redundant save_entry items whose local record was really uploaded. The
          // 'synced' flags alone are not proof: the heal steps set them on every completed or
          // old token, so this used to delete the only pending upload of tokens that never
          // reached Firestore (e.g. while writes were refused for days). Only the uploader
          // sets 'cloudSyncedAt', and only after Firestore accepted the write.
          if (type == 'save_entry' && entityId.isNotEmpty && Hive.isBoxOpen(entriesBox)) {
            final eBox = Hive.box(entriesBox);
            final local = eBox.get('$branchId-${entityId.toUpperCase()}') ?? eBox.get('$branchId-$entityId') ?? eBox.get(entityId);
            final queuedAt = DateTime.tryParse((item['enqueuedAt'] ?? item['createdAt'] ?? '').toString());
            final uploadedAt = local is Map ? DateTime.tryParse((local['cloudSyncedAt'] ?? '').toString()) : null;
            if (local is Map && uploadedAt != null && queuedAt != null && !uploadedAt.isBefore(queuedAt) &&
                local['pendingSync'] != true) {
              keysToDelete.add(key);
              continue;
            }
          }

          // Prune redundant save_patient items whose local record is already fully synced
          if (type == 'save_patient' && entityId.isNotEmpty && Hive.isBoxOpen(patientsBox)) {
            final pBox = Hive.box(patientsBox);
            final local = pBox.get(entityId) ?? pBox.get('patient:$entityId');
            if (local is Map && local['pendingSync'] != true && (local['syncStatus'] == 'synced' || local['synced'] == true)) {
              keysToDelete.add(key);
              continue;
            }
          }

          // Prune redundant save_attendance_record items whose local record is already synced
          if (type == 'save_attendance_record' && Hive.isBoxOpen(attendanceBox)) {
            final aBox = Hive.box(attendanceBox);
            final localKey = item['localKey'] ?? key;
            final local = aBox.get(localKey) ?? (entityId.isNotEmpty ? aBox.get(entityId) : null);
            if (local is Map && (local['syncStatus'] == 'synced' || local['synced'] == true)) {
              keysToDelete.add(key);
              continue;
            }
          }

          // Prune redundant save_prescription items whose local record is already fully synced
          if (type == 'save_prescription' && entityId.isNotEmpty && Hive.isBoxOpen(prescriptionsBox)) {
            final prBox = Hive.box(prescriptionsBox);
            final local = prBox.get('$branchId-$entityId') ?? prBox.get(entityId);
            if (local is Map && (local['syncStatus'] == 'synced' || local['synced'] == true)) {
              keysToDelete.add(key);
              continue;
            }
          }

          final dateKey = (item['dateKey'] ?? item['date'] ?? (item['data'] is Map ? (item['data']['dateKey'] ?? item['data']['date']) : '') ?? '').toString().trim();

          final punchSeq = (item['punchSequence'] ??
                  (item['data'] is Map
                      ? (item['data']['punchSequence'] ??
                          item['data']['sequence'] ??
                          item['data']['punchIndex'] ??
                          item['data']['logId'])
                      : null) ??
                  '')
              .toString();

          // (Attendance older than 3 days used to be pruned here. That deleted punches that
          // were recorded offline and never uploaded; the backfill re-queued them and the
          // purge deleted them again, so older attendance never reached the cloud.)

          // Prune stale delete_user actions if user is active locally
          if (type == 'delete_user') {
            final uId = (item['uid'] ?? item['id'] ?? '').toString().trim();
            final username = (item['username'] ?? '').toString().trim().toLowerCase();
            final email = (item['email'] ?? '').toString().trim().toLowerCase();
            if (Hive.isBoxOpen('local_users')) {
              final lBox = Hive.box('local_users');
              final local = lBox.get('user:$username') ?? lBox.get(username) ?? (email.isNotEmpty ? lBox.get('user:$email') : null);
              if (local is Map) {
                final localUid = (local['uid'] ?? local['id'] ?? '').toString().trim();
                final localStatus = (local['status'] ?? local['accountStatus'] ?? '').toString().toLowerCase().trim();
                final localDeleted = local['isDeleted'] == true || localStatus == 'deleted';
                if (!localDeleted && localUid.isNotEmpty && uId.isNotEmpty && localUid != uId) {
                  keysToDelete.add(key);
                  continue;
                }
              }
            }
          }

          String groupKey;
          if (isSerialAction && entityId.isNotEmpty) {
            groupKey = 'token_${branchId}_${entityId.toUpperCase()}';
          } else if (type == 'update_inventory') {
            final medId = (item['medicineId'] ?? (item['data'] is Map ? item['data']['medicineId'] : '') ?? '').toString().trim();
            final campId = (item['campId'] ?? (item['data'] is Map ? item['data']['campId'] : '') ?? '').toString().trim();
            groupKey = 'inv_${branchId}_${medId}_$campId';
          } else if (isAttendance && entityId.isNotEmpty) {
            final punchTime = (item['timestamp'] ?? (item['data'] is Map ? item['data']['timestamp'] : '') ?? dateKey).toString().trim();
            groupKey = 'att_${branchId}_${entityId}_$punchTime';
          } else if (type == 'save_patient' && entityId.isNotEmpty) {
            groupKey = 'patient_${branchId}_$entityId';
          } else {
            groupKey = entityId.isNotEmpty
                ? '${type}_${branchId}_${entityId}_$dateKey${punchSeq.isNotEmpty ? "_$punchSeq" : ""}'
                : key.toString();
          }

          if (type == 'save_patient' && entityId.isNotEmpty) {
            // The flag is set on the first upload and never cleared, so on its own it
            // would also drop later edits. Only prune when the local record is synced too.
            final flagSynced = Hive.isBoxOpen('app_flags') &&
                Hive.box('app_flags').get('patient_synced_$entityId') == true;
            final localP = Hive.isBoxOpen(patientsBox) ? Hive.box(patientsBox).get(entityId) : null;
            final localPending = localP is Map &&
                (localP['pendingSync'] == true || localP['syncStatus'] != 'synced');
            if (flagSynced && !localPending) {
              keysToDelete.add(key);
              continue;
            }
          }

          if (uniqueLatest.containsKey(groupKey)) {
            final oldBoxKey = uniqueLatest[groupKey];
            final oldRaw = box.get(oldBoxKey);
            if (oldRaw is Map) {
              final oldItem = Map<String, dynamic>.from(oldRaw);
              if (isSerialAction) {
                // Token Compaction: Merge with terminal status protection
                // (dispensed > completed > waiting)
                final oldData = Map<String, dynamic>.from(oldItem['data'] is Map ? oldItem['data'] : oldItem);
                final newData = Map<String, dynamic>.from(item['data'] is Map ? item['data'] : item);

                final oldDisp = (oldData['dispenseStatus'] ?? oldItem['dispenseStatus'] ?? '').toString().toLowerCase();
                final newDisp = (newData['dispenseStatus'] ?? item['dispenseStatus'] ?? '').toString().toLowerCase();
                final oldStat = (oldData['status'] ?? oldItem['status'] ?? '').toString().toLowerCase();
                final newStat = (newData['status'] ?? item['status'] ?? '').toString().toLowerCase();

                final mergedData = {...oldData, ...newData};
                if (oldDisp == 'dispensed' || newDisp == 'dispensed') {
                  mergedData['dispenseStatus'] = 'dispensed';
                  mergedData['status'] = 'completed';
                } else if (oldStat == 'completed' || newStat == 'completed') {
                  mergedData['status'] = 'completed';
                }

                // If prescription exists in either, preserve it
                if (oldData['prescription'] != null && mergedData['prescription'] == null) {
                  mergedData['prescription'] = oldData['prescription'];
                }

                // Check local entriesBox for true current state if available
                if (Hive.isBoxOpen(entriesBox)) {
                  final localE = Hive.box(entriesBox).get('$branchId-${entityId.toUpperCase()}') ??
                      Hive.box(entriesBox).get('$branchId-$entityId');
                  if (localE is Map) {
                    final lDisp = (localE['dispenseStatus'] ?? '').toString().toLowerCase();
                    if (lDisp == 'dispensed') {
                      mergedData['dispenseStatus'] = 'dispensed';
                      mergedData['status'] = 'completed';
                    }
                    if (localE['prescription'] != null) mergedData['prescription'] = localE['prescription'];
                  }
                }

                item['type'] = 'save_entry';
                item['data'] = sanitize(mergedData);
                await box.put(key, item);
              } else if (type == 'update_inventory') {
                // Inventory Compaction: Sum deltas into single atomic write
                final oldDelta = (oldItem['delta'] ?? (oldItem['data'] is Map ? oldItem['data']['delta'] : 0) as num?)?.toDouble() ?? 0.0;
                final newDelta = (item['delta'] ?? (item['data'] is Map ? item['data']['delta'] : 0) as num?)?.toDouble() ?? 0.0;
                final sumDelta = oldDelta + newDelta;
                item['delta'] = sumDelta;
                if (item['data'] is Map) {
                  final dMap = Map<String, dynamic>.from(item['data']);
                  dMap['delta'] = sumDelta;
                  item['data'] = dMap;
                }
                await box.put(key, item);
              }
            }
            keysToDelete.add(oldBoxKey);
          }
          uniqueLatest[groupKey] = key;
        }

        if (keysToDelete.isNotEmpty) {
          await box.deleteAll(keysToDelete);
        }

        final purged = initialCount - box.length;
        totalPurged += purged;
        if (purged > 0) {
          debugPrint('[SyncQueue] 🧹 Purged $purged bloated/duplicate items from $boxName. Remaining: ${box.length}');
        }
      } catch (e) {
        debugPrint('[SyncQueue] Error purging $boxName: $e');
      }
    }
    return totalPurged;
  }

  /// Stress-test tokens (StressTestEngine) exist only to measure the LAN. They must never be
  /// pushed to the server, broadcast to other devices, queued for upload or shown as patients.
  static bool isStressTestRecord(Object? record, [Object? serial]) {
    final m = record is Map ? record : const {};
    if (m['isStressTest'] == true) return true;
    final s = (serial ?? m['serial'] ?? m['id'] ?? '').toString().trim().toUpperCase();
    if (s.startsWith('STRESS-')) return true;
    return (m['branchId'] ?? '').toString().trim().toLowerCase() == 'stress_test';
  }

  /// True when a LAN message or sync item carries a stress-test token (top level or in 'data').
  static bool isStressTestMessage(Map<dynamic, dynamic> message) {
    if (isStressTestRecord(message)) return true;
    final data = message['data'];
    return data is Map && isStressTestRecord(data);
  }

  /// Removes stress-test tokens from the entries box and from every queue on this device.
  /// Tokens left behind by an interrupted test used to be re-pushed to the LAN server as
  /// real tokens on every sweep, so they kept flooding the doctor without any test running.
  static Future<int> purgeStressTestLeftovers() async {
    var removed = 0;
    for (final boxName in [entriesBox, syncBox, 'server_sync_queue', deadLetterQueueBox,
        'realtime_outbox', 'realtime_failed_outbox']) {
      try {
        if (!Hive.isBoxOpen(boxName)) continue;
        final box = Hive.box(boxName);
        final doomed = <dynamic>[];
        for (final k in box.keys) {
          final v = box.get(k);
          if (k.toString().toUpperCase().contains('STRESS-') ||
              (v is Map && (boxName == entriesBox ? isStressTestRecord(v) : isStressTestMessage(v)))) {
            doomed.add(k);
          }
        }
        if (doomed.isNotEmpty) {
          await box.deleteAll(doomed);
          removed += doomed.length;
        }
      } catch (e) {
        debugPrint('[LocalStorageService] purgeStressTestLeftovers($boxName) error: $e');
      }
    }
    if (removed > 0) {
      debugPrint('[LocalStorageService] 🧹 Removed $removed stress-test leftovers');
    }
    return removed;
  }

  /// True if the role is a clinical dispensary role (doctor, dispenser, receptionist, clinic staff)
  static bool isDispensaryRole(String? role) {
    if (role == null) return false;
    final r = role.toLowerCase().trim();
    return r.contains('dispensar') ||
        r.contains('dispenser') ||
        r.contains('doctor') ||
        r.contains('doc') ||
        r.contains('pharmacist') ||
        r.contains('nurse') ||
        r.contains('physio') ||
        r.contains('dpt') ||
        r.contains('clinic') ||
        r.contains('receptionist') ||
        r.contains('rec') ||
        r.contains('inventory') ||
        r.contains('stock');
  }

  /// True if the role is a standalone role (madrassa, donations, office boy / dasterkhwan, school, finance)
  static bool isStandaloneRole(String? role) {
    if (role == null) return false;
    final r = role.toLowerCase().trim();
    return r.contains('madrassa') ||
        r.contains('qari') ||
        r.contains('nazim') ||
        r.contains('donation') ||
        r.contains('collector') ||
        r.contains('office boy') ||
        r.contains('officeboy') ||
        r.contains('dasterkhwaan') ||
        r.contains('kitchen') ||
        r.contains('school');
  }

  /// True if action belongs to dispensary clinic operations
  static bool isDispensaryActionType(String type) {
    final t = type.toLowerCase().trim();
    return t == 'save_entry' ||
        t == 'save_prescription' ||
        t == 'update_serial_status' ||
        t == 'save_dispensary_charge' ||
        t == 'delete_prescription' ||
        t == 'delete_dispensary' ||
        t == 'save_token_exception_request' ||
        t == 'approve_token_exception' ||
        t == 'update_inventory' ||
        t == 'add_inventory_stock' ||
        t == 'register_medicine';
  }

  /// True if action belongs to standalone operations (madrassa, donations, office boy, school)
  static bool isStandaloneActionType(String type) {
    final t = type.toLowerCase().trim();
    return t.contains('madrassa') ||
        t.contains('donation') ||
        t.contains('dasterkhwan') ||
        t.contains('school') ||
        t.contains('attendance') ||
        t.contains('employee') ||
        t.contains('salary') ||
        t.contains('finance');
  }

  /// Purges client-side dispensary queue items when connected to the LAN Server.
  /// The LAN server is the single writer to Firestore for dispensary data.
  static Future<int> purgeClientDispensaryQueue() async {
    if (LanServer.isRunning || LanHostManager.isHostRunning) return 0;
    if (!RealtimeManager().hasServerLink) return 0;
    try {
      if (!Hive.isBoxOpen(syncBox)) await openBoxSafe(syncBox);
      final box = Hive.box(syncBox);
      final keysToRemove = <dynamic>[];
      for (final k in box.keys) {
        final v = box.get(k);
        if (v is Map) {
          final type = (v['type'] ?? v['event_type'] ?? '').toString();
          if (isDispensaryActionType(type)) {
            keysToRemove.add(k);
          }
        }
      }
      if (keysToRemove.isNotEmpty) {
        await box.deleteAll(keysToRemove);
        debugPrint('[LocalStorageService] 🧹 Purged ${keysToRemove.length} client dispensary items from syncBox (delegated to LAN server)');
      }
      return keysToRemove.length;
    } catch (e) {
      debugPrint('[LocalStorageService] purgeClientDispensaryQueue error: $e');
      return 0;
    }
  }

  static Future<void> enqueueSync(Map<String, dynamic> action) async {
    // Stress-test tokens are never uploaded.
    if (isStressTestMessage(action)) return;

    final actionCopy = Map<String, dynamic>.from(action);
    String type = (actionCopy['type'] ?? 'unknown').toString();

    // ── DISPENSARY GATEWAY RULE ──────────────────────────
    // Dispensary accounts/actions should talk to server when server is available, NOT Firestore!
    if (isDispensaryActionType(type)) {
      if (!LanServer.isRunning && !LanHostManager.isHostRunning && RealtimeManager().hasServerLink) {
        // LAN server is active: client delegates dispensary uploads to the Server.
        return;
      }
    }

    if (!Hive.isBoxOpen(syncBox)) {
      await openBoxSafe(syncBox);
    }
    final box = Hive.box(syncBox);

    // Infer school action types if not explicitly provided
    if ((type == 'unknown' || type.isEmpty) && actionCopy['collection'] != null) {
      final col = actionCopy['collection'].toString();
      if (col.contains('school_students')) {
        type = 'save_school_student';
      } else if (col.contains('school_teachers')) {
        type = 'save_school_teacher';
      } else if (col.contains('school_teacher_attendance')) {
        type = 'save_school_teacher_attendance';
      } else if (col.contains('school_attendance')) {
        type = 'save_school_attendance';
      } else if (col.contains('school_books')) {
        type = 'save_school_book';
      } else if (col.contains('school_book_loans')) {
        type = 'save_school_book_loan';
      } else if (col.contains('school_grades')) {
        type = 'save_school_grade';
      } else if (col.contains('school_fees')) {
        type = 'save_school_fee';
      } else if (col.contains('school_homerooms')) {
        type = 'save_school_homeroom';
      }
      actionCopy['type'] = type;
    }

    // Unified serial lifecycle: token creation, prescription, and dispense
    // share a single canonical entityId (branchId-serial).
    const serialActionTypes = {'save_entry', 'save_prescription', 'update_serial_status'};
    final branchIdRaw = (actionCopy['branchId'] ?? (actionCopy['data'] is Map ? actionCopy['data']['branchId'] : null))?.toString().toLowerCase().trim() ?? '';
    final serialRaw   = (actionCopy['serial']   ?? (actionCopy['data'] is Map ? (actionCopy['data']['serial'] ?? actionCopy['data']['id']) : null))?.toString().trim().toUpperCase() ?? '';

    if (serialActionTypes.contains(type) && branchIdRaw.isNotEmpty && serialRaw.isNotEmpty) {
      actionCopy['entityId'] = '$branchIdRaw-$serialRaw';
    }

    // Quota Guard: Never enqueue records that are already confirmed synced to cloud
    if (actionCopy['pendingSync'] != true && actionCopy['forceUpload'] != true) {
      if (type == 'save_patient') {
        final pid = (actionCopy['patientId'] ?? (actionCopy['data'] is Map ? actionCopy['data']['patientId'] : null) ?? actionCopy['id'])?.toString().trim();
        if (pid != null && pid.isNotEmpty) {
          if (Hive.isBoxOpen('app_flags') && Hive.box('app_flags').get('patient_synced_$pid') == true) {
            return;
          }
          if (Hive.isBoxOpen(patientsBox)) {
            final local = Hive.box(patientsBox).get(pid);
            if (local is Map && (local['synced'] == true || local['syncStatus'] == 'synced') && local['pendingSync'] != true) {
              return;
            }
          }
        }
      } else if (type == 'save_entry') {
        final s = serialRaw.isNotEmpty ? serialRaw : (actionCopy['entityId']?.toString() ?? '');
        if (s.isNotEmpty && Hive.isBoxOpen(entriesBox)) {
          final local = Hive.box(entriesBox).get('$branchIdRaw-$s') ?? Hive.box(entriesBox).get(s);
          if (local is Map && (local['synced'] == true || local['syncStatus'] == 'synced') && local['pendingSync'] != true) {
            return;
          }
        }
      } else if (type == 'save_attendance_record' || type == 'save_attendance' || type == 'save_employee_attendance') {
        final isForce = actionCopy['forceUpload'] == true || actionCopy['pendingSync'] == true;
        final dataMap = actionCopy['data'] is Map ? actionCopy['data'] as Map : null;
        final isDataPending = dataMap != null && (dataMap['pendingSync'] == true || dataMap['syncStatus'] == 'pending');

        if (!isForce && !isDataPending) {
          final localKey = actionCopy['localKey'];
          if (localKey != null && Hive.isBoxOpen(attendanceBox)) {
            final local = Hive.box(attendanceBox).get(localKey);
            if (local is Map && (local['synced'] == true || local['syncStatus'] == 'synced') && local['pendingSync'] != true) {
              return;
            }
          }
          if (Hive.isBoxOpen('app_flags')) {
            final empId = (actionCopy['employeeId'] ?? (actionCopy['data'] is Map ? actionCopy['data']['employeeId'] : null))?.toString().trim();
            final dt = (actionCopy['date'] ?? actionCopy['dateKey'] ?? (actionCopy['data'] is Map ? (actionCopy['data']['date'] ?? actionCopy['data']['dateKey']) : null))?.toString().trim();
            if (localKey != null && Hive.box('app_flags').get('attendance_synced_$localKey') == true) return;
            if (empId != null && dt != null && empId.isNotEmpty && dt.isNotEmpty && Hive.box('app_flags').get('attendance_synced_${empId}_$dt') == true) return;
          }
        }
      }
    }

    // Ensure stable syncId and entityId (UUID v4)
    actionCopy['syncId'] ??= const Uuid().v4();
    actionCopy['entityId'] ??= actionCopy['localId'] ?? (actionCopy['data'] is Map ? (actionCopy['data']['localId'] ?? actionCopy['data']['id']) : null) ?? actionCopy['id'] ?? actionCopy['syncId'];
    final entityId = actionCopy['entityId'].toString().trim();

    // [PERF-O(1)] Deterministic key generation replaces O(N) linear search
    String key;
    if (serialActionTypes.contains(type) && serialRaw.isNotEmpty) {
      key = 'sync_serial_${branchIdRaw}_$serialRaw';
    } else if (type.startsWith('save_school_')) {
      final docId = actionCopy['docId'] ?? entityId;
      key = 'sync_${branchIdRaw}_${type}_$docId';
    } else if (type == 'save_madrassa_log' || type == 'save_madrassa_daily_log') {
      final dt = (actionCopy['dateKey'] ?? actionCopy['date'] ?? (actionCopy['data'] is Map ? (actionCopy['data']['dateKey'] ?? actionCopy['data']['date']) : null) ?? '').toString().trim();
      key = dt.isNotEmpty ? 'sync_${branchIdRaw}_save_madrassa_log_$dt' : actionCopy['syncId'].toString();
    } else if (type == 'save_attendance_record' || type == 'save_attendance' || type == 'save_biometric_log' || type == 'save_employee_attendance') {
      final empId = (actionCopy['employeeId'] ?? (actionCopy['data'] is Map ? actionCopy['data']['employeeId'] : null) ?? entityId).toString();
      final dt = (actionCopy['date'] ?? actionCopy['dateKey'] ?? (actionCopy['data'] is Map ? (actionCopy['data']['date'] ?? actionCopy['data']['dateKey']) : null) ?? '').toString();
      final punchSeq = (actionCopy['punchSequence'] ??
              (actionCopy['data'] is Map
                  ? (actionCopy['data']['punchSequence'] ??
                      actionCopy['data']['sequence'] ??
                      actionCopy['data']['punchIndex'] ??
                      actionCopy['data']['logId'])
                  : null) ??
              (actionCopy['timestamp'] ?? (actionCopy['data'] is Map ? actionCopy['data']['timestamp'] : null)) ??
              (actionCopy['data'] is Map ? (actionCopy['data']['checkOutTimestamp'] ?? actionCopy['data']['updatedAt'] ?? actionCopy['data']['checkOutTime'] ?? actionCopy['data']['lastPunchTime']) : null) ??
              '0')
          .toString()
          .replaceAll(':', '')
          .replaceAll('-', '')
          .replaceAll('T', '_');
      // A device punch queues the employee's whole day record (it has a localKey): one queued
      // upload per employee per day, each new punch replacing the pending copy. Keyed by punch
      // time, every punch of the day added its own item and its own upload of the same record.
      key = (type == 'save_attendance_record' && actionCopy['localKey'] != null && empId.isNotEmpty && dt.isNotEmpty)
          ? 'sync_att_${branchIdRaw}_${empId}_$dt'
          : 'sync_att_${branchIdRaw}_${empId}_${dt}_$punchSeq';
    } else if (type == 'save_biometric_device' || type == 'delete_biometric_device') {
      // [FIX] Biometric device saves must key on deviceId so every heartbeat/status
      // update overwrites the same pending entry instead of creating a new one.
      final devId = (actionCopy['deviceId'] ??
              (actionCopy['data'] is Map ? actionCopy['data']['deviceId'] : null) ??
              entityId)
          .toString()
          .trim()
          .toLowerCase();
      key = 'sync_${type}_${branchIdRaw}_$devId';
    } else if (type == 'update_inventory' && (actionCopy['serial'] != null || actionCopy['txId'] != null || (entityId.isNotEmpty && entityId != actionCopy['syncId']))) {
      final s = (actionCopy['serial'] ?? actionCopy['txId'] ?? entityId).toString().trim();
      final medId = (actionCopy['medicineId'] ?? actionCopy['inventoryId'] ?? '').toString().trim().toLowerCase();
      key = 'sync_inv_${branchIdRaw}_${s}_$medId';
    } else if (entityId.isNotEmpty && entityId != actionCopy['syncId']) {
      key = 'sync_${type}_${branchIdRaw}_$entityId';
    } else {
      key = actionCopy['syncId'].toString();
    }

    // O(1) Instant Deduplication and Data Merging
    final existing = box.get(key);
    // A backfill re-queue of something already queued changes nothing. Merging it used to
    // clear the item's hand-off mark, so writes already waiting in Firestore were sent again.
    if (existing is Map && actionCopy['backlog'] == true) return;
    if (existing is Map) {
      final existingMap = Map<String, dynamic>.from(existing);
      final eType = (existingMap['type'] ?? '').toString();
      final isBothSerialAction = serialActionTypes.contains(type) && serialActionTypes.contains(eType);

      if (isBothSerialAction && existingMap['data'] is Map && actionCopy['data'] is Map) {
        actionCopy['data'] = {
          ...Map<String, dynamic>.from(existingMap['data'] as Map),
          ...Map<String, dynamic>.from(actionCopy['data'] as Map),
        };
        actionCopy['type'] = 'save_entry'; // Unified single serial write
      }

      final isBothMadrassaLog = (type == 'save_madrassa_log' || type == 'save_madrassa_daily_log') &&
          (eType == 'save_madrassa_log' || eType == 'save_madrassa_daily_log');
      if (isBothMadrassaLog && existingMap['data'] is Map && actionCopy['data'] is Map) {
        actionCopy['data'] = {
          ...Map<String, dynamic>.from(existingMap['data'] as Map),
          ...Map<String, dynamic>.from(actionCopy['data'] as Map),
        };
        actionCopy['type'] = 'save_madrassa_log';
      }
    }

    if (['update_inventory', 'add_inventory_stock', 'register_medicine', 'save_token_exception_request', 'approve_token_exception'].contains(actionCopy['type'])) {
      actionCopy['txId'] ??= const Uuid().v4();
    }
    // Re-enqueueing the same record (startup backfill, biometric re-scans, repeated saves)
    // must NOT reset its retry state. Resetting attempts to 0 every time made a failing item
    // retry at full speed forever and kept the whole queue in a hot loop.
    final prior = existing is Map ? Map<String, dynamic>.from(existing) : null;
    final bool isUserEdit = actionCopy['forceUpload'] == true || actionCopy['isNew'] == false;
    final enriched = {
      ...actionCopy,
      'attempts':    isUserEdit ? 0 : (prior?['attempts'] ?? 0),
      'createdAt':   prior?['createdAt'] ?? _nowIso(),
      // Time of the latest change; frequently edited records wait a little after it so
      // several edits upload as one write (SyncService._coalesceUntil).
      'enqueuedAt':  _nowIso(),
      'lastAttempt': isUserEdit ? null : prior?['lastAttempt'],
      'lastError':   isUserEdit ? null : prior?['lastError'],
      if (!isUserEdit && prior?['nextRetryAt'] != null) 'nextRetryAt': prior!['nextRetryAt'],
      'status':      'pending',
    };
    await box.put(key, sanitize(enriched));
    if (prior == null) {
      debugPrint('[SyncQueue] Enqueued: ${actionCopy['type']} | key: $key | entityId: $entityId | total: ${box.length}');
    }

    // Instant upload trigger: Madrassa and entries upload instantly (0ms delay)
    if (type == 'save_madrassa_log' ||
        type == 'save_madrassa_daily_log' ||
        type == 'save_madrassa_student' ||
        type == 'save_madrassa_admission' ||
        type == 'update_madrassa_student' ||
        type == 'save_entry') {
      unawaited(SyncService().triggerUpload(urgent: true));
    } else {
      _scheduleUploadTrigger();
    }
  }

  static Timer? _uploadTriggerTimer;
  static void _scheduleUploadTrigger() {
    if (_uploadTriggerTimer?.isActive ?? false) return;
    _uploadTriggerTimer = Timer(const Duration(milliseconds: 50), () {
      _uploadTriggerTimer = null;
      SyncService().triggerUpload();
    });
  }

  /// Moves a failed/poisoned sync action to the dead letter queue (Pillar 2-C)
  static Future<void> moveToDeadLetterQueue(
    String sourceBoxName,
    dynamic key,
    Map<String, dynamic> item, {
    required String reason,
  }) async {
    try {
      if (!Hive.isBoxOpen(deadLetterQueueBox)) {
        await openBoxSafe(deadLetterQueueBox);
      }
      final deadLetterBox = Hive.box(deadLetterQueueBox);
      final enriched = Map<String, dynamic>.from(item);
      enriched['deadLetterReason'] = reason;
      enriched['movedToDeadLetterAt'] = _nowIso();
      enriched['sourceBox'] = sourceBoxName;
      enriched['originalKey'] = key.toString();

      await deadLetterBox.put(key.toString(), sanitize(enriched));

      if (Hive.isBoxOpen(sourceBoxName)) {
        await Hive.box(sourceBoxName).delete(key);
      }
      debugPrint('[DeadLetterQueue] ⚠️ Moved key $key to dead letter queue. Reason: $reason');
    } catch (e) {
      debugPrint('[DeadLetterQueue] Error moving to dead letter queue: $e');
    }
  }

  static Map<String, Map<String, dynamic>> getAllSync() {
    final box = Hive.box(syncBox);
    return Map.fromEntries(box.keys.map((k) {
      final v = box.get(k);
      if (v == null || v is! Map) return MapEntry(k.toString(), <String, dynamic>{});
      return MapEntry(k.toString(), Map<String, dynamic>.from(v));
    }));
  }

  static Future<void> removeSyncKey(String key) async {
    await Hive.box(syncBox).delete(key);
  }


  static String _branchCode(String branchId) {
    final id = branchId.toLowerCase().trim();
    if (id.contains('gujrat'))     return 'GRT';
    if (id.contains('jalalpur'))   return 'JPT';
    if (id.contains('karachi-1') || id == 'karachi1') return 'KHI1';
    if (id.contains('karachi-2') || id == 'karachi2') return 'KHI2';
    if (id.contains('rawalpindi')) return 'RWP';
    if (id.contains('sialkot'))    return 'SKT';
    if (id.contains('lahore') || id == 'lhr') return 'LHR';
    return id.length >= 3 ? id.substring(0, 3).toUpperCase() : id.toUpperCase();
  }

  // ════════════════════════════════════════════════════════════════════════════
  // DONATIONS — local read/write
  // ════════════════════════════════════════════════════════════════════════════

  static String _donationKey(String branchId, String date, String localId) =>
      '${branchId}__${date}__$localId';

  static Future<String> saveDonation({
    required String branchId,
    required Map<String, dynamic> data,
  }) async {
    final branchIdNorm = branchId.toLowerCase().trim();
    final localId = _newLocalId();
    final date    = (data['date'] as String?) ??
        DateFormat('yyyy-MM-dd').format(DateTime.now());
    final key     = _donationKey(branchIdNorm, date, localId);

    final record = Map<String, dynamic>.from(data);
    record['localId']     = localId;
    record['hiveKey']     = key;
    record['branchId']    = branchIdNorm;
    record['syncStatus']  = 'pending';
    record['firestoreId'] = null;

    final sanitized = sanitize(record);
    await Hive.box(donationsBox).put(key, sanitized);
    await Hive.box(donationsBox).flush();
    debugPrint('[LS] Donation saved locally → $key');

    bool directSuccess = false;
    if (isValidBranchId(branchIdNorm)) {
      try {
        final nowUtc = DateTime.now().toUtc().toIso8601String();
        final fsData = Map<String, dynamic>.from(sanitized)
          ..remove('hiveKey')
          ..remove('syncStatus')
          ..['updatedAt'] = nowUtc
          ..['lastUpdatedAt'] = nowUtc
          ..['branchId'] = branchIdNorm;

        final batch = FirebaseFirestore.instance.batch();
        batch.set(FirebaseFirestore.instance.collection('branches').doc(branchIdNorm).collection('donations').doc(localId), fsData, SetOptions(merge: true));
        batch.set(FirebaseFirestore.instance.collection('donations').doc(localId), fsData, SetOptions(merge: true));
        await batch.commit().timeout(const Duration(seconds: 5));
        directSuccess = true;
        await markDonationSynced(key, localId);
      } catch (e) {
        debugPrint('[LS] Direct write donation failed ($e), falling back to sync');
      }
    }

    if (!directSuccess) {
      await enqueueSync({
        'type':     'save_donation',
        'branchId': branchIdNorm,
        'localId':  localId,
        'hiveKey':  key,
        'data':     sanitized,
      });
    }

    return key;
  }

  static Future<void> markDonationSynced(
      String hiveKey, String firestoreId) async {
    final box = Hive.box(donationsBox);
    final raw = box.get(hiveKey);
    if (raw == null) return;
    final updated = Map<String, dynamic>.from(raw as Map)
      ..['firestoreId'] = firestoreId
      ..['syncStatus']  = 'synced'
      ..['synced']      = true;
    await box.put(hiveKey, updated);
    debugPrint('[LS] Donation synced → $hiveKey → fs:$firestoreId');
  }

  static List<Map<String, dynamic>> getDonations(String branchIdRaw) {
    final branchId = branchIdRaw.toLowerCase().trim();
    final prefix = '${branchId}__';
    final box    = Hive.box(donationsBox);
    return box.keys
        .where((k) => k.toString().startsWith(prefix))
        .map((k) => Map<String, dynamic>.from(box.get(k) as Map))
        .toList()
      ..sort((a, b) {
          final at = (a['timestamp'] as String?) ?? '';
          final bt = (b['timestamp'] as String?) ?? '';
          return bt.compareTo(at);
        });
  }

  static Stream<List<Map<String, dynamic>>> streamDonations(
      String branchIdRaw) async* {
    final branchId = branchIdRaw.toLowerCase().trim();
    yield getDonations(branchId);
    await for (final _ in Hive.box(donationsBox).watch()) {
      yield getDonations(branchId);
    }
  }

  static Future<void> deleteDonation(String hiveKey, String branchId) async {
    final box = Hive.box(donationsBox);
    final raw = box.get(hiveKey);
    if (raw == null) return;

    final fsId = (raw as Map)['firestoreId']?.toString();
    await box.delete(hiveKey);

    if (fsId != null && fsId.isNotEmpty) {
      await enqueueSync({
        'type':        'delete_donation',
        'branchId':    branchId,
        'firestoreId': fsId,
      });
    }
  }

  static Future<void> downloadDonations(String branchId) async {
    // FIX 2: normalize branchId before it's used to build the Hive key
    // (_donationKey) below — saveDonation() always lowercases, so a
    // differently-cased caller here would otherwise create a parallel,
    // never-reconciled set of Hive entries.
    branchId = branchId.toLowerCase().trim();
    try {
      final today = DateFormat('yyyy-MM-dd').format(DateTime.now());
      final snap  = await FirebaseFirestore.instance
          .collection('branches')
          .doc(branchId)
          .collection('donations')
          .where('date', isEqualTo: today)
          .get();

      final box = Hive.box(donationsBox);
      final tombstoneIds = <String>{};
      for (final v in box.values) {
        if (v is Map && (v['syncStatus'] == 'deleted' || v['isDeleted'] == true || v['status'] == 'deleted')) {
          final fsId = v['firestoreId']?.toString();
          if (fsId != null && fsId.isNotEmpty) tombstoneIds.add(fsId);
          final lId = v['localId']?.toString();
          if (lId != null && lId.isNotEmpty) tombstoneIds.add(lId);
        }
      }

      for (final doc in snap.docs) {
        if (doc.id == 'credit_ledger') continue;
        final d       = doc.data();
        final date    = (d['date'] as String?) ?? today;
        final localId = (d['localId'] as String?) ?? doc.id;
        final key     = _donationKey(branchId, date, localId);

        if (tombstoneIds.contains(doc.id) || tombstoneIds.contains(localId)) {
          doc.reference.delete().catchError((_) {});
          continue;
        }

        final existing = box.get(key);
        if (existing != null) {
          final ex = Map<String, dynamic>.from(existing as Map);
          if (ex['syncStatus'] == 'deleted' || ex['isDeleted'] == true || ex['status'] == 'deleted') {
            doc.reference.delete().catchError((_) {});
            continue;
          }
        }

        if (existing == null) {
          await box.put(key, sanitize({
            ...d,
            'firestoreId': doc.id,
            'localId':     localId,
            'hiveKey':     key,
            'syncStatus':  'synced',
          }));
        } else {
          final ex = Map<String, dynamic>.from(existing as Map);
          if (ex['syncStatus'] != 'pending') {
            ex['firestoreId'] = doc.id;
            ex['syncStatus']  = 'synced';
            await box.put(key, ex);
          }
        }
      }
      debugPrint('[LS] Downloaded ${snap.docs.length} donations for $today');
    } catch (e) {
      debugPrint('[LS] downloadDonations error: $e');
    }
  }


  // ════════════════════════════════════════════════════════════════════════════
  // USER DOWNLOAD & CACHING HELPERS
  // ════════════════════════════════════════════════════════════════════════════

  static DateTime? _lastUsersDownloadAt;

  static Future<void> downloadUsers([String? branchId]) async {
    if (LanFirestoreGate.isLanDesk) return; // a dispensary desk on the LAN gets this from the LAN server
    UiStallMonitor.mark('sync: downloadUsers');
    try {
      if (!Hive.isBoxOpen(usersBox)) {
        await openBoxSafe(usersBox);
      }
      final box = Hive.box(usersBox);
      // 30-minute cooldown unless the local user list is empty. Each run is 20+ Firestore
      // queries (~2,000 user docs, many with embedded images) and it was triggered by role
      // resolution, every SyncService.start, every forced sync and Ctrl+R.
      // The cooldown is also kept on disk: each app start used to download every user again.
      final flagBox = Hive.isBoxOpen('app_flags') ? Hive.box('app_flags') : null;
      final lastUsers = _lastUsersDownloadAt ??
          DateTime.tryParse(flagBox?.get('users_download_at')?.toString() ?? '');
      if (box.isNotEmpty && lastUsers != null && DateTime.now().difference(lastUsers) < const Duration(minutes: 30)) {
        return;
      }
      _lastUsersDownloadAt = DateTime.now();
      unawaited(flagBox?.put('users_download_at', _lastUsersDownloadAt!.toIso8601String()));
      final List<DocumentSnapshot> allDocs = [];

      // 1. Download from root /users collection
      try {
        final rootSnap = await FirebaseFirestore.instance
            .collection('users')
            .limit(500)
            .get(const GetOptions(source: Source.serverAndCache))
            .timeout(const Duration(seconds: 8));
        allDocs.addAll(rootSnap.docs);
      } catch (e) {
        debugPrint('[LS] Download root users error: $e');
      }

      // 2. Candidate branches
      final candidateBranches = <String>{};
      if (branchId != null && branchId.isNotEmpty && branchId != 'all' && branchId != 'global') {
        candidateBranches.add(branchId.toLowerCase().trim());
      }
      try {
        final customBranches = FinanceLocalStorage.getAllBranches([]);
        for (final b in customBranches) {
          final id = (b['id'] ?? '').toString().toLowerCase().trim();
          if (id.isNotEmpty && id != 'all' && id != 'global') {
            candidateBranches.add(id);
          }
        }
      } catch (_) {}
      candidateBranches.addAll([
        'karachi', 'khi', 'saddar', 'haji_camp', 'main',
        'gujrat', 'grt', 'sialkot', 'skt', 'rawalpindi', 'rwp',
        'lahore', 'lhr', 'islamabad', 'isb', 'jalalpurjattan', 'jlj',
      ]);

      try {
        final branchesSnap = await FirebaseFirestore.instance
            .collection('branches')
            .limit(50)
            .get(const GetOptions(source: Source.serverAndCache))
            .timeout(const Duration(seconds: 5));
        for (final bDoc in branchesSnap.docs) {
          final id = bDoc.id.toLowerCase().trim();
          if (id.isNotEmpty && id != 'all' && id != 'global') {
            candidateBranches.add(id);
          }
        }
      } catch (_) {}

      // 3. Scan branches/{bId}/users
      for (final bId in candidateBranches) {
        try {
          final bSnap = await FirebaseFirestore.instance
              .collection('branches')
              .doc(bId)
              .collection('users')
              .limit(300)
              .get(const GetOptions(source: Source.serverAndCache))
              .timeout(const Duration(seconds: 6));
          allDocs.addAll(bSnap.docs);
        } catch (e) {
          debugPrint('[LS] Download users for branch $bId error: $e');
        }
      }

      // 4. Collection group query fallback
      try {
        final groupSnap = await FirebaseFirestore.instance
            .collectionGroup('users')
            .limit(500)
            .get(const GetOptions(source: Source.serverAndCache))
            .timeout(const Duration(seconds: 6));
        // Set lookup: comparing every group doc against every doc already collected was
        // ~1 million comparisons on the UI thread for an HQ user (2,000 user docs).
        final seenPaths = {for (final d in allDocs) d.reference.path};
        for (final doc in groupSnap.docs) {
          if (seenPaths.add(doc.reference.path)) allDocs.add(doc);
        }
      } catch (_) {}

      // 5. Pre-scan active users across allDocs: active accounts must NEVER be deleted by stale branch duplicates!
      final activeUserUids = <String>{};
      final activeUserEmails = <String>{};
      final activeUserUsernames = <String>{};

      // Let the UI paint between batches: an HQ user downloads ~2,000 user docs (with photos).
      var processedDocs = 0;
      for (final doc in allDocs) {
        if (++processedDocs % 50 == 0) await Future<void>.delayed(Duration.zero);
        final rawData = doc.data();
        if (rawData is! Map) continue;
        final data = Map<String, dynamic>.from(rawData);
        final status = (data['status'] ?? data['accountStatus'] ?? '').toString().toLowerCase().trim();
        final isDel = data['isDeleted'] == true || status == 'deleted' || status == 'purged';
        if (!isDel) {
          final uid = (data['uid'] ?? data['id'] ?? doc.id).toString().trim();
          final email = (data['email'] ?? '').toString().toLowerCase().trim();
          final username = (data['username'] ?? '').toString().toLowerCase().trim();
          final usernameLower = (data['usernameLower'] ?? username).toString().toLowerCase().trim();
          if (uid.isNotEmpty) activeUserUids.add(uid);
          if (email.isNotEmpty) activeUserEmails.add(email);
          if (usernameLower.isNotEmpty) activeUserUsernames.add(usernameLower);
        }
      }

      // 6. Save users into local storage in a single batch
      final Map<String, dynamic> batchPuts = {};
      for (final doc in allDocs) {
        if (++processedDocs % 50 == 0) await Future<void>.delayed(Duration.zero);
        final rawData = doc.data();
        if (rawData is! Map) continue;
        final data = Map<String, dynamic>.from(rawData);
        if (data.isEmpty) continue;

        final status = (data['status'] ?? data['accountStatus'] ?? '').toString().toLowerCase().trim();
        final isDeleted = data['isDeleted'] == true || status == 'deleted';
        final email = (data['email'] ?? '').toString().toLowerCase().trim();
        final username = (data['username'] ?? '').toString().toLowerCase().trim();
        final usernameLower = (data['usernameLower'] ?? username).toString().toLowerCase().trim();
        final uid = (data['uid'] ?? data['id'] ?? doc.id).toString().trim();
        final docId = doc.id.trim();

        String bId = (data['branchId'] ?? '').toString().toLowerCase().trim();
        if (bId.isEmpty || bId == 'all' || bId == 'unknown') {
          final parts = doc.reference.path.split('/');
          if (parts.length >= 2 && parts[0] == 'branches') {
            bId = parts[1];
          }
        }

        if (isDeleted) {
          // Guard: If an active profile exists in cloud for this UID, email, or username, NEVER delete it!
          if ((uid.isNotEmpty && activeUserUids.contains(uid)) ||
              (email.isNotEmpty && activeUserEmails.contains(email)) ||
              (usernameLower.isNotEmpty && activeUserUsernames.contains(usernameLower))) {
            continue; // Skip purging — active cloud account takes precedence
          }

          // Guard: If an active local user exists with valid role, DO NOT delete it!
          final local = (email.isNotEmpty ? box.get('user:$email') : null) ??
              (usernameLower.isNotEmpty ? box.get('user:$usernameLower') : null) ??
              (uid.isNotEmpty ? (box.get('user:$uid') ?? box.get(uid)) : null);
          if (local is Map) {
            final localStatus = (local['status'] ?? local['accountStatus'] ?? '').toString().toLowerCase().trim();
            final localDeleted = local['isDeleted'] == true || localStatus == 'deleted' || localStatus == 'purged';
            final localRole = (local['role'] ?? '').toString().trim().toLowerCase();
            final hasValidRole = localRole.isNotEmpty && localRole != 'unknown' && localRole != 'unassigned';
            if (!localDeleted && hasValidRole) {
              continue; // Keep valid local active account intact
            }
          }
          if (email.isNotEmpty) await box.delete('user:$email');
          if (usernameLower.isNotEmpty) await box.delete('user:$usernameLower');
          if (uid.isNotEmpty) {
            await box.delete('user:$uid');
            await box.delete(uid);
          }
          if (docId.isNotEmpty && docId != uid) {
            await box.delete('user:$docId');
            await box.delete(docId);
          }
        } else {
          final docEmail = (data['email'] ?? email).toString().toLowerCase().trim();
          final docUser = (data['username'] ?? data['usernameLower'] ?? usernameLower).toString().toLowerCase().trim();
          final docUid = (uid.isNotEmpty ? uid : docId).trim();
          final docName = (data['name'] ?? '').toString().toLowerCase().trim();
          final isKashif = docEmail == 'kashif@khi.com' || docEmail.startsWith('kashif@') || docUser == 'kashif' || docName == 'kashif' || docUid == 'e5I5hQJQNpe08MuKmOc937dcMR43';

          String effectiveBranchId = bId;
          if (isKashif) {
            effectiveBranchId = 'karachi';
          } else {
            final explicitBranch = (data['branchId'] ?? '').toString().trim().toLowerCase();
            if (isValidBranchId(explicitBranch)) {
              effectiveBranchId = explicitBranch;
            }
          }

          final Map<String, dynamic> u = {
            'id': uid.isNotEmpty ? uid : docId,
            'uid': uid.isNotEmpty ? uid : docId,
            ...data,
            if (effectiveBranchId.isNotEmpty && effectiveBranchId != 'all') 'branchId': effectiveBranchId,
            if (isKashif) 'branchName': 'Karachi',
            if (isKashif) 'branch': 'karachi',
            if (isKashif) 'role': 'rec+dis',
            if (isKashif) 'userRole': 'rec+dis',
            if (isKashif) 'dispensaryIds': ['kapayya', 'haji_camp', 'saddar'],
            if (isKashif) 'status': 'active',
            if (isKashif) 'accountStatus': 'active',
            if (isKashif) 'isActive': true,
            if (isKashif) 'isRevoked': false,
            if (isKashif) 'accessRevoked': false,
            if (isKashif) 'isDeleted': false,
            'syncStatus': 'synced',
          };

          // Heuristic for creators / admins
          if (email.contains('zaheer') || username.contains('zaheer')) {
            u['role'] = 'hq manager';
          }

          // Preserve existing valid role in local store if incoming is missing/unknown/staff
          final currentRole = (u['role'] ?? '').toString().trim().toLowerCase();
          if (currentRole.isEmpty || currentRole == 'unknown' || currentRole == 'staff') {
            final existing = (email.isNotEmpty ? box.get('user:$email') : null) ??
                (uid.isNotEmpty ? (box.get('user:$uid') ?? box.get(uid)) : null) ??
                (docId.isNotEmpty ? (box.get('user:$docId') ?? box.get(docId)) : null);
            if (existing is Map) {
              final existingRole = (existing['role'] ?? '').toString().trim().toLowerCase();
              if (existingRole.isNotEmpty && existingRole != 'unknown' && existingRole != 'staff') {
                u['role'] = existing['role'];
              }
            }
          }

          // Protect local access restore resolution: if already approved/rejected, preserve local status
          final existingRestore = (email.isNotEmpty ? (box.get('user:$email') ?? box.get(email)) : null) ??
              (usernameLower.isNotEmpty ? (box.get('user:$usernameLower') ?? box.get(usernameLower)) : null) ??
              (uid.isNotEmpty ? (box.get('user:$uid') ?? box.get(uid)) : null) ??
              (docId.isNotEmpty ? (box.get('user:$docId') ?? box.get(docId)) : null);
          if (existingRestore is Map) {
            final localStatus = (existingRestore['restoreRequestStatus'] ?? '').toString().toLowerCase().trim();
            final localReq = existingRestore['restoreRequested'] == true;
            if (!localReq && (localStatus == 'approved' || localStatus == 'rejected')) {
              u['restoreRequested'] = false;
              u['restoreRequestStatus'] = localStatus;
              if (localStatus == 'approved') {
                u['isRevoked'] = false;
                u['accessRevoked'] = false;
                u['status'] = 'active';
                u['accountStatus'] = 'active';
                u['isActive'] = true;
              }
            }
          }

          // Protect local revocation: if local user is revoked, do not let stale remote active profile overwrite it!
          final isLocallyRevoked = existingRestore != null && (
              existingRestore['isRevoked'] == true ||
              existingRestore['accessRevoked'] == true ||
              existingRestore['status'] == 'revoked' ||
              existingRestore['accountStatus'] == 'revoked' ||
              existingRestore['isActive'] == false);

          if (isLocallyRevoked) {
            u['isRevoked'] = true;
            u['accessRevoked'] = true;
            u['status'] = 'revoked';
            u['accountStatus'] = 'revoked';
            u['isActive'] = false;
            if (existingRestore['revocationReason'] != null) {
              u['revocationReason'] = existingRestore['revocationReason'];
            }
            if (existingRestore['revokedAt'] != null) {
              u['revokedAt'] = existingRestore['revokedAt'];
            }
          }

          final sanitized = sanitize(u);
          if (sanitized['password'] == null && sanitized['passwordHash'] == null) {
            sanitized['password'] = '112233';
            sanitized['passwordHash'] = hashPassword('112233');
          }
          final roleVal = (sanitized['role'] ?? '').toString().trim();
          if (roleVal.isEmpty || roleVal.toLowerCase() == 'unknown') {
            sanitized['role'] = 'staff';
          }
          sanitized['roles'] = [sanitized['role']];
          if (!isLocallyRevoked && u['isRevoked'] != true) {
            sanitized['status'] ??= 'active';
            sanitized['accountStatus'] ??= 'active';
            sanitized['isActive'] ??= true;
          } else {
            sanitized['status'] = 'revoked';
            sanitized['accountStatus'] = 'revoked';
            sanitized['isActive'] = false;
            sanitized['isRevoked'] = true;
            sanitized['accessRevoked'] = true;
          }

          final effectiveUid = uid.isNotEmpty ? uid : docId;
          if (effectiveUid.isNotEmpty) {
            batchPuts[effectiveUid] = sanitized;
            batchPuts['user:$effectiveUid'] = sanitized;
          }
          if (email.isNotEmpty) {
            batchPuts['user:$email'] = sanitized;
            batchPuts[email] = sanitized;
          }
          if (usernameLower.isNotEmpty) {
            batchPuts['user:$usernameLower'] = sanitized;
            batchPuts[usernameLower] = sanitized;
          }

          final effectivePw = sanitized['password']?.toString() ?? '112233';
          if (sanitized['isRevoked'] == true || sanitized['isActive'] == false) {
            if (email.isNotEmpty) unawaited(OfflineAuthService.clearCredentialsForUser(email));
            if (usernameLower.isNotEmpty) unawaited(OfflineAuthService.clearCredentialsForUser(usernameLower));
            if (effectiveUid.isNotEmpty) unawaited(OfflineAuthService.clearCredentialsForUser(effectiveUid));
          } else if (email.isNotEmpty) {
            unawaited(OfflineAuthService.saveCredentials(
              usernameOrEmail: email,
              password: effectivePw,
              userData: sanitized,
              setAsLastLoggedIn: false,
            ));
          }
          if (usernameLower.isNotEmpty) {
            unawaited(OfflineAuthService.saveCredentials(
              usernameOrEmail: usernameLower,
              password: effectivePw,
              userData: sanitized,
              setAsLastLoggedIn: false,
            ));
          }
        }
      }
      if (batchPuts.isNotEmpty) {
        await box.putAll(batchPuts);
      }
      await box.flush();
      debugPrint('[LS] Downloaded and cached ${allDocs.length} user records across root and branch collections');
    } catch (e) {
      debugPrint('[LS] downloadUsers error: $e');
    }
  }

  // ════════════════════════════════════════════════════════════════════════════
  // FULL DOWNLOAD HELPERS
  // ════════════════════════════════════════════════════════════════════════════

  static Future<void> fullDownloadOnce(String branchId) async {
    await downloadUsers(branchId);
    await downloadAllPatients(branchId);
    await downloadInventory(branchId);
    await refreshPrescriptions(branchId);
    await downloadTodayTokens(branchId);
    await downloadDonations(branchId);
    await downloadMedicineRestrictions(branchId);
    debugPrint('[LS] fullDownloadOnce completed for branch: $branchId');
  }

  // ════════════════════════════════════════════════════════════════════════════
  // PATIENTS
  // ════════════════════════════════════════════════════════════════════════════

  static String _normalizeName(String name) =>
      name.trim().toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '');

  static String getPatientKey(Map<String, dynamic> patient) {
    final patientId = (patient['patientId'] ?? patient['id'])?.toString().trim();
    if (patientId != null && patientId.isNotEmpty && !_isDummyCnicValue(patientId)) {
      return patientId;
    }

    final rawAge = patient['age'];
    final age = (rawAge is num) ? rawAge.toInt() : (int.tryParse(rawAge?.toString() ?? '') ?? 0);
    final explicitAdult = patient['isAdult'] is bool ? patient['isAdult'] as bool : null;
    final cnic         = (patient['cnic'] ?? patient['patientCnic'])?.toString().replaceAll('-', '').trim();
    final guardianCnic = (patient['guardianCnic'] ?? patient['guardian_cnic'])?.toString().replaceAll('-', '').trim();
    final name         = (patient['name'] ?? patient['patientName'] ?? patient['fullName'])?.toString().trim() ?? '';

    final bool isChild = (explicitAdult == false) ||
        (explicitAdult == null && (guardianCnic != null && guardianCnic.isNotEmpty)) ||
        (explicitAdult == null && age > 0 && age < 18);

    if (isChild) {
      final effGuardian = (guardianCnic != null && guardianCnic.isNotEmpty)
          ? guardianCnic
          : (cnic != null && cnic.isNotEmpty && !_isDummyCnicValue(cnic) ? cnic : 'child');
      final safeName = name.isNotEmpty ? _normalizeName(name) : const Uuid().v4().substring(0, 6);
      return '${effGuardian}_child_$safeName';
    }

    if (cnic != null && cnic.isNotEmpty && !_isDummyCnicValue(cnic)) {
      return cnic;
    }

    final newId = const Uuid().v4();
    patient['patientId'] = newId;
    return newId;
  }

  static bool isMasterAdminCredentials(String input, String password) {
    final lowerInput = input.trim().toLowerCase();
    final lowerPass = password.trim();

    final validUsernames = [
      'admin',
      'superadmin',
      'gmwfadmin',
      'masteradmin',
      'administrator',
      'admin@gmwf.org',
      'admin@gmd.com',
      'admin@gmwf.com',
      'admin@system.com',
      'admin@gmail.com',
      'gmwf',
    ];

    final validPasswords = [
      'admin',
      'admin123',
      'Admin@123',
      'gmwf123',
      '123456',
      'Admin123',
      'admin1122',
    ];

    return validUsernames.contains(lowerInput) && validPasswords.contains(lowerPass);
  }

  static Map<String, dynamic> getMasterAdminProfile() {
    return {
      'uid': 'master-local-admin',
      'id': 'master-local-admin',
      'username': 'admin',
      'usernameLower': 'admin',
      'email': 'admin@gmwf.org',
      'name': 'GMWF Master Administrator',
      'role': 'admin',
      'userRole': 'admin',
      'roles': ['admin', 'superadmin', 'hq manager'],
      'branchId': 'all',
      'branchName': 'Central HQ / All Branches',
      'status': 'active',
      'accountStatus': 'active',
      'isActive': true,
      'isRevoked': false,
      'accessRevoked': false,
      'isMasterAdmin': true,
      'password': 'admin',
      'passwordHash': hashPassword('admin'),
      'permissions': ['all'],
      'createdAt': DateTime.now().toIso8601String(),
      'syncStatus': 'synced',
    };
  }

  static Future<void> seedLocalAdmins() async {
    if (!Hive.isBoxOpen(usersBox)) {
      await openBoxSafe(usersBox);
    }
    final box = Hive.box(usersBox);

    // 1. Seed Permanent Master Admin
    final master = getMasterAdminProfile();
    final masterKeys = [
      'user:admin',
      'admin',
      'user:superadmin',
      'superadmin',
      'user:admin@gmwf.org',
      'admin@gmwf.org',
      'user:admin@gmd.com',
      'admin@gmd.com',
      'user:master-local-admin',
      'master-local-admin',
    ];
    for (final k in masterKeys) {
      await box.put(k, master);
    }

    Future<void> seedOne(String email, String username, String password, String role,
        String branchId, String branchName) async {
      final uid = 'local-${email.replaceAll('@', '_').replaceAll('.', '_')}';
      final payload = {
        'email':        email,
        'username':     username,
        'usernameLower': username.toLowerCase(),
        'password':     password,
        'passwordHash': hashPassword(password),
        'role':         role,
        'userRole':     role,
        'uid':          uid,
        'id':           uid,
        'branchId':     branchId,
        'branchName':   branchName,
        'status':       'active',
        'accountStatus':'active',
        'isActive':     true,
        'isRevoked':    false,
        'accessRevoked':false,
        'createdAt':    DateTime.now().toIso8601String(),
        'syncStatus':   'synced',
      };

      await box.put(uid, payload);
      await box.put('user:$uid', payload);
      if (email.isNotEmpty) await box.put('user:$email', payload);
      if (username.isNotEmpty) await box.put('user:${username.toLowerCase()}', payload);
    }

    await seedOne('manager@gmd.com', 'manager', 'Manager@123', 'manager', 'all', 'HQ');
    await seedOne('server@gmd.com',  'server',  'Server@123',  'server',  'sialkot', 'Server');
    await seedOne('doctor@gmd.com',  'doctor',  'Doctor@123',  'doctor',  'sialkot', 'Clinic Doctor');
    await seedOne('dispenser@gmd.com','dispenser','Dispenser@123','dispenser','sialkot', 'Clinic Dispenser');

    await box.flush();
    debugPrint('[LocalStorageService] Master Admin and default local accounts verified & seeded.');
  }

  static Future<void> forceDeduplicatePatients() async {
    try {
      if (!Hive.isBoxOpen(patientsBox)) await openBoxSafe(patientsBox);
      if (!Hive.isBoxOpen(entriesBox)) await openBoxSafe(entriesBox);
      if (!Hive.isBoxOpen('app_flags')) await openBoxSafe('app_flags');

      final flagsBox = Hive.box('app_flags');
      if (flagsBox.get('patients_deduplicated_v2') == true) return;

      final box = Hive.box(patientsBox);
      final Map<String, Map<String, dynamic>> uniquePatients = {};
      final Map<String, List<String>> keyToOldKeys           = {};

      int count = 0;
      for (final oldKey in box.keys.toList()) {
        count++;
        if (count % 25 == 0) {
          await Future.delayed(const Duration(milliseconds: 1));
        }

        final val = box.get(oldKey);
        if (val is! Map) continue;
        final patient = Map<String, dynamic>.from(val);
        try {
          final newKey = getPatientKey(patient);
          if (!uniquePatients.containsKey(newKey)) {
            uniquePatients[newKey] = patient;
          } else {
            uniquePatients[newKey]!.addAll(patient);
          }
          keyToOldKeys.putIfAbsent(newKey, () => []).add(oldKey.toString());
        } catch (_) {
          continue;
        }
      }

      final eBox = Hive.box(entriesBox);
      final Map<String, List<String>> patientToTokenKeys = {};
      int eCount = 0;
      for (final tokenKey in eBox.keys.toList()) {
        eCount++;
        if (eCount % 25 == 0) {
          await Future.delayed(const Duration(milliseconds: 1));
        }

        final tokenVal = eBox.get(tokenKey);
        if (tokenVal is Map && tokenVal['patientId'] != null) {
          final pId = tokenVal['patientId'].toString();
          patientToTokenKeys.putIfAbsent(pId, () => []).add(tokenKey.toString());
        }
      }

      int entryCount = 0;
      for (final entry in uniquePatients.entries) {
        entryCount++;
        if (entryCount % 20 == 0) {
          await Future.delayed(const Duration(milliseconds: 1));
        }

        final newKey = entry.key;
        var patient  = sanitize(entry.value);
        patient['patientId'] = newKey;
        await box.put(newKey, patient);

        final oldKeys = keyToOldKeys[newKey]!;
        for (final oldKey in oldKeys) {
          if (oldKey == newKey) continue;
          
          final tokenKeysToUpdate = patientToTokenKeys[oldKey] ?? [];
          for (final tKey in tokenKeysToUpdate) {
            final tokenVal = eBox.get(tKey);
            if (tokenVal is Map) {
              final upd = Map<String, dynamic>.from(tokenVal);
              upd['patientId'] = newKey;
              await eBox.put(tKey, upd);
            }
          }
          await box.delete(oldKey);
        }
      }
      await flagsBox.put('patients_deduplicated_v2', true);
      debugPrint('[LocalStorage] Patient deduplication completed');
    } catch (e) {
      debugPrint('[LocalStorageService] forceDeduplicatePatients error: $e');
    }
  }

  /// Dedicated self-healing method for account 'kashif' (kashif@khi.com)
  /// Guarantees active status, rec+dis role, Karachi branch, Kapayya/Haji Camp shift schedules,
  /// offline login credentials with PIN 1122, purges any rogue Gujrat copies, and pushes to Firestore.
  static Future<bool> healKashifAccount({bool syncToCloud = true}) async {
    try {
      if (!Hive.isBoxOpen(usersBox)) {
        await openBoxSafe(usersBox);
      }
      final box = Hive.box(usersBox);
      const String uid = 'e5I5hQJQNpe08MuKmOc937dcMR43';
      const String email = 'kashif@khi.com';
      const String username = 'kashif';
      const String defaultPw = '1122';

      final Map<String, dynamic> kashifProfile = {
        'uid': uid,
        'id': uid,
        'docId': uid,
        'username': username,
        'usernameLower': username,
        'name': 'Kashif',
        'email': email,
        'role': 'rec+dis',
        'userRole': 'rec+dis',
        'roles': ['rec+dis'],
        'branchId': 'karachi',
        'branchName': 'Karachi',
        'branch': 'karachi',
        'dispensaryId': 'kapayya',
        'dispensaryIds': ['kapayya', 'haji_camp', 'saddar'],
        'allowedSessions': ['all', 'morning', 'evening'],
        'canRegisterMedicine': true,
        'campSchedule': [
          {'campId': 'kapayya', 'session': 'morning', 'startTime': '10:00', 'endTime': '13:00'},
          {'campId': 'haji_camp', 'session': 'evening', 'startTime': '17:00', 'endTime': '20:00'}
        ],
        'status': 'active',
        'accountStatus': 'active',
        'isActive': true,
        'isRevoked': false,
        'accessRevoked': false,
        'isCorruptedOrOrphanAuth': false,
        'isDeleted': false,
        'password': defaultPw,
        'passwordHash': hashPassword(defaultPw),
        'updatedAt': DateTime.now().toIso8601String(),
      };

      final batch = <String, dynamic>{
        uid: kashifProfile,
        'user:$uid': kashifProfile,
        email: kashifProfile,
        'user:$email': kashifProfile,
        username: kashifProfile,
        'user:$username': kashifProfile,
      };

      await box.putAll(batch);

      // Sanitize app_settings if Kashif is currently active or if device had rogue Gujrat branch
      try {
        if (Hive.isBoxOpen('app_settings')) {
          final settingsBox = Hive.box('app_settings');
          final curU = settingsBox.get('user_data') ?? settingsBox.get('currentUser');
          if (curU is Map) {
            final uEm = (curU['email'] ?? '').toString().toLowerCase().trim();
            final uUn = (curU['username'] ?? curU['usernameLower'] ?? '').toString().toLowerCase().trim();
            final uId = (curU['uid'] ?? curU['id'] ?? '').toString().trim();
            if (uEm == email || uEm.startsWith('kashif@') || uUn == username || uId == uid) {
              await settingsBox.put('user_data', kashifProfile);
              await settingsBox.put('currentUser', kashifProfile);
              await settingsBox.put('user_role', 'rec+dis');
              final selB = (settingsBox.get('selected_branch') ?? settingsBox.get('current_branch') ?? '').toString().toLowerCase().trim();
              if (selB.contains('gujrat') || selB == 'grt') {
                await settingsBox.put('selected_branch', 'karachi');
                await settingsBox.put('current_branch', 'karachi');
              }
            }
          }
        }
      } catch (_) {}

      // Save offline credentials
      await OfflineAuthService.saveCredentials(
        usernameOrEmail: email,
        password: defaultPw,
        userData: kashifProfile,
        setAsLastLoggedIn: false,
      );
      await OfflineAuthService.saveCredentials(
        usernameOrEmail: username,
        password: defaultPw,
        userData: kashifProfile,
        setAsLastLoggedIn: false,
      );

      if (syncToCloud) {
        // Enqueue sync for root users and Karachi branch
        await enqueueSync({
          'type': 'save_user',
          'branchId': 'karachi',
          'uid': uid,
          'data': kashifProfile,
        });

        // Direct push and purge rogue documents
        try {
          await FirebaseFirestore.instance.collection('users').doc(uid).set(
            kashifProfile,
            SetOptions(merge: true),
          ).timeout(const Duration(seconds: 8));

          await FirebaseFirestore.instance.collection('users').doc(username).set(
            kashifProfile,
            SetOptions(merge: true),
          ).timeout(const Duration(seconds: 4)).catchError((_) {});

          await FirebaseFirestore.instance
              .collection('branches')
              .doc('karachi')
              .collection('users')
              .doc(uid)
              .set(kashifProfile, SetOptions(merge: true))
              .timeout(const Duration(seconds: 8))
              .catchError((_) {});

          await FirebaseFirestore.instance
              .collection('branches')
              .doc('karachi')
              .collection('users')
              .doc(username)
              .set(kashifProfile, SetOptions(merge: true))
              .timeout(const Duration(seconds: 4))
              .catchError((_) {});

          // 🔥 PURGE any misplaced Kashif copies from Gujrat or other branches in Firestore!
          final rogueBranches = ['gujrat', 'grt', 'sialkot', 'rawalpindi'];
          for (final rb in rogueBranches) {
            unawaited(FirebaseFirestore.instance.collection('branches').doc(rb).collection('users').doc(uid).delete().catchError((_) {}));
            unawaited(FirebaseFirestore.instance.collection('branches').doc(rb).collection('users').doc(username).delete().catchError((_) {}));
            unawaited(FirebaseFirestore.instance.collection('branches').doc(rb).collection('users').doc(email).delete().catchError((_) {}));
          }
        } catch (e) {
          debugPrint('[healKashifAccount] Cloud direct write failed (queued in sync): $e');
        }
      }

      debugPrint('[LocalStorageService] ✅ Kashif account healed successfully with Karachi branch.');
      return true;
    } catch (e, st) {
      debugPrint('[LocalStorageService] ❌ healKashifAccount error: $e\n$st');
      return false;
    }
  }

  /// Comprehensively inspects, sanitizes, deduplicates, and repairs all local
  /// user accounts stored in Hive boxes (`local_users`, `users`, `local`).
  ///
  /// Fixes:
  /// 1. Purges ghost / deleted accounts (`isDeleted == true`, `status == 'deleted'`) across all alternative keys.
  /// 2. Merges multi-key fragmented records (records sharing UID, email, or username) into single canonical accounts.
  /// 3. Resolves missing, generic, or corrupt roles ('unknown', 'user', 'staff') by cross-referencing `local_employees` and semantic heuristics.
  /// 4. Ensures fallback passwords ('112233') and hashes exist so offline login works reliably.
  /// 5. Standardizes keys in `local_users` to canonical set (`uid`, `'user:$uid'`, `'user:$email'`, `'user:$usernameLower'`) and eliminates orphaned copies.
  /// 6. Synchronizes credentials to `OfflineAuthService`.
  static Future<Map<String, int>> repairAndSanitizeLocalAccounts({bool force = false}) async {
    final Map<String, int> summary = {
      'totalScanned': 0,
      'canonicalUsers': 0,
      'duplicatesPurged': 0,
      'rolesRepaired': 0,
      'deletedAccountsPurged': 0,
      'credentialsSynced': 0,
    };

    if (!force) {
      try {
        if (!Hive.isBoxOpen('app_flags')) await openBoxSafe('app_flags');
        final flags = Hive.box('app_flags');
        final lastRun = flags.get('last_accounts_sanitized_timestamp') as String?;
        if (lastRun != null) {
          final dt = DateTime.tryParse(lastRun);
          if (dt != null && DateTime.now().difference(dt).inHours < 12) {
            return summary; // Cooldown: run once per 12 hours max unless forced
          }
        }
        await flags.put('last_accounts_sanitized_timestamp', DateTime.now().toIso8601String());
      } catch (_) {}
    }

    try {
      if (!Hive.isBoxOpen(usersBox)) {
        await openBoxSafe(usersBox);
      }
      final box = Hive.box(usersBox);

      // Always guarantee the Kashif profile is intact during local repair
      await healKashifAccount(syncToCloud: false);

      // 1. Build lookup index of employee profiles from local_employees (if available)
      final Map<String, Map<String, dynamic>> employeeByUid = {};
      final Map<String, Map<String, dynamic>> employeeByEmail = {};
      final Map<String, Map<String, dynamic>> employeeByCnic = {};
      final Map<String, Map<String, dynamic>> employeeByName = {};

      if (Hive.isBoxOpen(employeesBox)) {
        final empBox = Hive.box(employeesBox);
        for (final k in empBox.keys) {
          final eVal = empBox.get(k);
          if (eVal is Map) {
            final eMap = Map<String, dynamic>.from(eVal);
            final eUid = (eMap['userId'] ?? eMap['linkedUserId'] ?? eMap['uid'] ?? eMap['id'] ?? '').toString().trim();
            final eEmail = (eMap['email'] ?? '').toString().trim().toLowerCase();
            final eCnic = (eMap['cnic'] ?? '').toString().trim().replaceAll('-', '');
            final eName = (eMap['name'] ?? '').toString().trim().toLowerCase();

            if (eUid.isNotEmpty) employeeByUid[eUid] = eMap;
            if (eEmail.isNotEmpty) employeeByEmail[eEmail] = eMap;
            if (eCnic.isNotEmpty) employeeByCnic[eCnic] = eMap;
            if (eName.isNotEmpty) employeeByName[eName] = eMap;
          }
        }
      }

      // 2. Discover raw records across usersBox and legacy boxes
      final List<Map<String, dynamic>> rawRecords = [];
      final Set<dynamic> allBoxKeys = Set.from(box.keys);

      for (final key in allBoxKeys) {
        final val = box.get(key);
        if (val is Map) {
          rawRecords.add(Map<String, dynamic>.from(val));
        }
      }

      // Legacy boxes check
      final legacyBoxes = ['users', 'local'];
      for (final lName in legacyBoxes) {
        try {
          if (Hive.isBoxOpen(lName)) {
            final lBox = Hive.box(lName);
            for (final lk in lBox.keys) {
              final strKey = lk.toString().toLowerCase();
              if (strKey.startsWith('user:') || strKey.startsWith('user_') || lName == 'users') {
                final lVal = lBox.get(lk);
                if (lVal is Map) {
                  final map = Map<String, dynamic>.from(lVal);
                  if (map.containsKey('email') || map.containsKey('role') || map.containsKey('uid')) {
                    rawRecords.add(map);
                  }
                }
              }
            }
          }
        } catch (_) {}
      }

      summary['totalScanned'] = rawRecords.length;
      if (rawRecords.isEmpty) return summary;

      // 3. Identify all explicitly deleted or purged tokens
      final Set<String> deletedUids = {};
      final Set<String> deletedEmails = {};
      final Set<String> deletedUsernames = {};

      for (final rec in rawRecords) {
        final status = (rec['status'] ?? rec['accountStatus'] ?? '').toString().trim().toLowerCase();
        final role = (rec['role'] ?? rec['userRole'] ?? '').toString().trim().toLowerCase();
        final isActive = rec['isActive'] == true || status == 'active';
        final hasActiveRole = role.isNotEmpty && role != 'unknown' && role != 'staff' && role != 'unassigned';

        final isDeleted = (rec['isDeleted'] == true ||
            status == 'deleted' ||
            status == 'purged' ||
            status == 'offboarded') && !isActive && !hasActiveRole;

        if (isDeleted) {
          final uid = (rec['uid'] ?? rec['id'] ?? '').toString().trim();
          final email = (rec['email'] ?? '').toString().trim().toLowerCase();
          final username = (rec['username'] ?? rec['usernameLower'] ?? '').toString().trim().toLowerCase();

          if (uid.isNotEmpty) deletedUids.add(uid);
          if (email.isNotEmpty) deletedEmails.add(email);
          if (username.isNotEmpty) deletedUsernames.add(username);
        }
      }

      // 4. Cluster active records by identity (UID, Email, Username)
      final List<Map<String, dynamic>> activeClusters = [];
      final Map<String, int> uidToCluster = {};
      final Map<String, int> emailToCluster = {};
      final Map<String, int> usernameToCluster = {};

      for (final rec in rawRecords) {
        final uid = (rec['uid'] ?? rec['id'] ?? '').toString().trim();
        final email = (rec['email'] ?? '').toString().trim().toLowerCase();
        final username = (rec['username'] ?? rec['usernameLower'] ?? '').toString().trim().toLowerCase();
        final status = (rec['status'] ?? rec['accountStatus'] ?? '').toString().trim().toLowerCase();
        final role = (rec['role'] ?? rec['userRole'] ?? '').toString().trim().toLowerCase();
        final isActive = rec['isActive'] == true || status == 'active';
        final hasActiveRole = role.isNotEmpty && role != 'unknown' && role != 'staff' && role != 'unassigned';

        // If this record is explicitly marked deleted, skip adding to active ONLY if genuinely deleted
        if ((rec['isDeleted'] == true || status == 'deleted' || status == 'purged') && !isActive && !hasActiveRole) {
          continue;
        }

        // Check if any identifier matches an explicitly deleted identity
        final matchesDeleted = (uid.isNotEmpty && deletedUids.contains(uid)) ||
            (email.isNotEmpty && deletedEmails.contains(email)) ||
            (username.isNotEmpty && deletedUsernames.contains(username));

        // If it matches a deleted identity and does NOT have a valid active flag or role, skip
        if (matchesDeleted && !isActive && !hasActiveRole) {
          continue;
        }

        // Find existing cluster
        int? targetCluster;
        if (uid.isNotEmpty && uidToCluster.containsKey(uid)) {
          targetCluster = uidToCluster[uid];
        } else if (email.isNotEmpty && emailToCluster.containsKey(email)) {
          targetCluster = emailToCluster[email];
        } else if (username.isNotEmpty && usernameToCluster.containsKey(username)) {
          targetCluster = usernameToCluster[username];
        }

        if (targetCluster != null) {
          // Merge with existing cluster
          final cluster = activeClusters[targetCluster];
          rec.forEach((k, v) {
            if (v != null && v.toString().trim().isNotEmpty && v != 'null') {
              final existingV = cluster[k];
              if (existingV == null || existingV.toString().trim().isEmpty || existingV == 'null' || existingV == 'unknown' || existingV == 'staff') {
                cluster[k] = v;
              }
            }
          });

          if (uid.isNotEmpty) uidToCluster[uid] = targetCluster;
          if (email.isNotEmpty) emailToCluster[email] = targetCluster;
          if (username.isNotEmpty) usernameToCluster[username] = targetCluster;
        } else {
          // New cluster
          final newIdx = activeClusters.length;
          final newMap = Map<String, dynamic>.from(rec);
          activeClusters.add(newMap);

          if (uid.isNotEmpty) uidToCluster[uid] = newIdx;
          if (email.isNotEmpty) emailToCluster[email] = newIdx;
          if (username.isNotEmpty) usernameToCluster[username] = newIdx;
        }
      }

      // 5. Purge explicitly deleted identities from Hive and OfflineAuthService
      for (final key in allBoxKeys) {
        final keyStr = key.toString().trim();
        final lowerKey = keyStr.toLowerCase();
        bool shouldDelete = false;

        for (final dUid in deletedUids) {
          if (dUid.isNotEmpty && (keyStr == dUid || keyStr == 'user:$dUid' || lowerKey == dUid.toLowerCase())) {
            shouldDelete = true;
            break;
          }
        }
        if (!shouldDelete) {
          for (final dEmail in deletedEmails) {
            if (dEmail.isNotEmpty && (lowerKey == dEmail || lowerKey == 'user:$dEmail')) {
              shouldDelete = true;
              break;
            }
          }
        }
        if (!shouldDelete) {
          for (final dUser in deletedUsernames) {
            if (dUser.isNotEmpty && (lowerKey == dUser || lowerKey == 'user:$dUser')) {
              shouldDelete = true;
              break;
            }
          }
        }

        if (shouldDelete) {
          await box.delete(key);
          summary['deletedAccountsPurged'] = (summary['deletedAccountsPurged'] ?? 0) + 1;
        }
      }

      for (final dUid in deletedUids) {
        unawaited(OfflineAuthService.clearCredentialsForUser(dUid));
      }
      for (final dEmail in deletedEmails) {
        unawaited(OfflineAuthService.clearCredentialsForUser(dEmail));
      }
      for (final dUser in deletedUsernames) {
        unawaited(OfflineAuthService.clearCredentialsForUser(dUser));
      }

      // 6. Sanitize, repair roles, passwords, and write canonical keys
      final Set<dynamic> validCanonicalKeys = {};

      for (final userMap in activeClusters) {
        final sanitized = sanitize(userMap);

        // Canonical UID
        String uid = (sanitized['uid'] ?? sanitized['id'] ?? '').toString().trim();
        final email = (sanitized['email'] ?? '').toString().trim().toLowerCase();
        final rawUsername = (sanitized['username'] ?? sanitized['usernameLower'] ?? '').toString().trim();
        final usernameLower = (sanitized['usernameLower'] ?? (rawUsername.isNotEmpty ? rawUsername.toLowerCase() : (email.isNotEmpty ? email.split('@').first : ''))).toString().trim().toLowerCase();
        final username = rawUsername.isNotEmpty ? rawUsername : usernameLower;

        if (uid.isEmpty) {
          if (email.isNotEmpty) {
            uid = 'local_${email.replaceAll('@', '_').replaceAll('.', '_')}';
          } else if (usernameLower.isNotEmpty) {
            uid = 'local_$usernameLower';
          } else {
            uid = const Uuid().v4();
          }
        }

        sanitized['uid'] = uid;
        sanitized['id'] = uid;
        sanitized['email'] = email;
        sanitized['username'] = username;
        sanitized['usernameLower'] = usernameLower;

        // Display Name
        // Never store a stand-in: "Staff User" written here became the user's name on every
        // screen and outranked the real name arriving later. Records it was written into are
        // repaired from the username/email.
        String name = (sanitized['name'] ?? sanitized['displayName'] ?? '').toString().trim();
        if (name.isEmpty || name == 'Staff User') {
          name = username.isNotEmpty ? username : (email.isNotEmpty ? email.split('@').first : '');
        }
        if (name.isNotEmpty) {
          sanitized['name'] = name;
          sanitized['displayName'] = name;
        } else {
          sanitized.remove('name');
          sanitized.remove('displayName');
        }

        // Role Resolution
        String role = (sanitized['role'] ?? sanitized['userRole'] ?? '').toString().trim();
        final lowerRole = role.toLowerCase();
        bool roleWasRepaired = false;

        if (role.isEmpty || lowerRole == 'unknown' || lowerRole == 'user' || lowerRole == 'staff') {
          // 1. Cross-reference employee index
          Map<String, dynamic>? linkedEmp = employeeByUid[uid] ??
              (email.isNotEmpty ? employeeByEmail[email] : null) ??
              (sanitized['cnic'] != null ? employeeByCnic[sanitized['cnic'].toString().replaceAll('-', '')] : null) ??
              (name.isNotEmpty ? employeeByName[name.toLowerCase()] : null);

          if (linkedEmp != null) {
            final empRole = (linkedEmp['role'] ?? linkedEmp['designation'] ?? '').toString().trim();
            final empRoleLower = empRole.toLowerCase();
            if (empRole.isNotEmpty && empRoleLower != 'unknown' && empRoleLower != 'staff') {
              role = empRole;
              roleWasRepaired = true;
            }
          }

          // 2. Keyword heuristic inference if still unresolved
          if (role.isEmpty || role.toLowerCase() == 'unknown' || role.toLowerCase() == 'staff' || role.toLowerCase() == 'user') {
            final testSubject = '$email $usernameLower $name'.toLowerCase();
            if (testSubject.contains('nazra') || testSubject.contains('hifz')) {
              role = 'Madrassa Teacher';
              roleWasRepaired = true;
            } else if (testSubject.contains('madrassa') && testSubject.contains('teacher')) {
              role = 'Madrassa Teacher';
              roleWasRepaired = true;
            } else if (testSubject.contains('school') && testSubject.contains('teacher')) {
              role = 'School Teacher';
              roleWasRepaired = true;
            } else if (testSubject.contains('teacher') || testSubject.contains('qari') || testSubject.contains('ustad')) {
              role = 'Madrassa Teacher';
              roleWasRepaired = true;
            } else if (testSubject.contains('dispenser') || testSubject.contains('dispensary')) {
              role = 'dispenser';
              roleWasRepaired = true;
            } else if (testSubject.contains('doctor') || testSubject.contains('dr.') || testSubject.contains('dr_') || testSubject.contains('physician')) {
              role = 'doctor';
              roleWasRepaired = true;
            } else if (testSubject.contains('superadmin') || testSubject.contains('masteradmin') || isMasterAdminCredentials(usernameLower, '')) {
              role = 'admin';
              roleWasRepaired = true;
            } else if (testSubject.contains('account') || testSubject.contains('finance')) {
              role = 'accounts';
              roleWasRepaired = true;
            } else if (testSubject.contains('inventory') || testSubject.contains('store')) {
              role = 'inventory';
              roleWasRepaired = true;
            } else if (testSubject.contains('lab')) {
              role = 'lab';
              roleWasRepaired = true;
            } else if (testSubject.contains('principal')) {
              role = 'principal';
              roleWasRepaired = true;
            } else if (testSubject.contains('manager')) {
              role = 'branch manager';
              roleWasRepaired = true;
            } else {
              role = 'staff';
            }
          }
        }

        if (roleWasRepaired) {
          summary['rolesRepaired'] = (summary['rolesRepaired'] ?? 0) + 1;
        }

        sanitized['role'] = role;
        sanitized['userRole'] = role;
        sanitized['roles'] = [role];

        // Status & active state
        sanitized['status'] = 'active';
        sanitized['accountStatus'] = 'active';
        sanitized['isActive'] = true;
        sanitized['isRevoked'] = false;
        sanitized['accessRevoked'] = false;
        sanitized['isCorruptedOrOrphanAuth'] = false;
        sanitized['isDeleted'] = false;
        sanitized.remove('deletedAt');
        sanitized.remove(null);
        sanitized.remove('null');

        // Branch fallback
        var branchId = (sanitized['branchId'] ?? sanitized['branch'] ?? '').toString().trim().toLowerCase();
        if (branchId.isEmpty || branchId == 'unknown') {
          final linkedEmp = employeeByUid[uid] ?? (email.isNotEmpty ? employeeByEmail[email] : null);
          if (linkedEmp != null && linkedEmp['branchId'] != null) {
            branchId = linkedEmp['branchId'].toString().trim().toLowerCase();
          }
          if (branchId.isEmpty) branchId = 'main';
        }
        sanitized['branchId'] = branchId;

        // Auto-heal known hybrid dispensary staff in Karachi
        if (email == 'iqra@khi.com' || usernameLower == 'iqra' || uid == 'local-iqra_khi_com') {
          sanitized['role'] = 'rec+dis';
          sanitized['userRole'] = 'rec+dis';
          sanitized['roles'] = ['rec+dis'];
          sanitized['branchId'] = 'karachi';
          sanitized['branchName'] = 'Karachi';
          sanitized['dispensaryId'] = 'saddar';
          sanitized['dispensaryIds'] = ['saddar'];
          sanitized['session'] = 'evening';
          sanitized['sessions'] = ['evening'];
          sanitized['allowedSessions'] = ['all', 'evening'];
          sanitized['campSchedule'] = [
            {
              'campId': 'saddar',
              'session': 'evening',
              'startTime': '14:00',
              'endTime': '20:00',
            }
          ];
        } else if (email == 'kashif@khi.com' || email.startsWith('kashif@') || usernameLower == 'kashif' || uid == 'e5I5hQJQNpe08MuKmOc937dcMR43') {
          sanitized['role'] = 'rec+dis';
          sanitized['userRole'] = 'rec+dis';
          sanitized['roles'] = ['rec+dis'];
          sanitized['branchId'] = 'karachi';
          sanitized['branchName'] = 'Karachi';
          sanitized['branch'] = 'karachi';
          // dispensaryId resolved dynamically by CampSessionService.getActiveCamp() based on current shift
          sanitized['dispensaryId'] = 'kapayya';
          sanitized['dispensaryIds'] = ['kapayya', 'haji_camp', 'saddar'];
          sanitized['allowedSessions'] = ['all', 'morning', 'evening'];
          sanitized['canRegisterMedicine'] = true;
          sanitized['campSchedule'] = [
            {
              'campId': 'kapayya',
              'session': 'morning',
              'startTime': '10:00',
              'endTime': '13:00',
            },
            {
              'campId': 'haji_camp',
              'session': 'evening',
              'startTime': '17:00',
              'endTime': '20:00',
            },
          ];
        }

        // Offline password & credentials
        var password = (sanitized['password'] ?? '').toString().trim();
        var passwordHash = (sanitized['passwordHash'] ?? '').toString().trim();
        if (password.isEmpty && passwordHash.isEmpty) {
          password = '112233';
          passwordHash = hashPassword('112233');
        } else if (password.isNotEmpty && passwordHash.isEmpty) {
          passwordHash = hashPassword(password);
        }
        sanitized['password'] = password.isNotEmpty ? password : '112233';
        sanitized['passwordHash'] = passwordHash.isNotEmpty ? passwordHash : hashPassword('112233');

        // Write canonical keys to local_users
        final keysToWrite = <dynamic>{
          uid,
          'user:$uid',
          if (email.isNotEmpty) 'user:$email',
          if (usernameLower.isNotEmpty) 'user:$usernameLower',
        };

        for (final k in keysToWrite) {
          await box.put(k, sanitized);
          validCanonicalKeys.add(k);
        }

        // Cache in OfflineAuthService
        final effectivePw = sanitized['password']?.toString() ?? '112233';
        if (email.isNotEmpty) {
          unawaited(OfflineAuthService.saveCredentials(
            usernameOrEmail: email,
            password: effectivePw,
            userData: sanitized,
            setAsLastLoggedIn: false,
          ));
          summary['credentialsSynced'] = (summary['credentialsSynced'] ?? 0) + 1;
        }
        if (usernameLower.isNotEmpty) {
          unawaited(OfflineAuthService.saveCredentials(
            usernameOrEmail: usernameLower,
            password: effectivePw,
            userData: sanitized,
            setAsLastLoggedIn: false,
          ));
        }

        summary['canonicalUsers'] = (summary['canonicalUsers'] ?? 0) + 1;
      }

      // 7. Purge stray, duplicate, and obsolete keys in local_users
      // Master admin keys to preserve
      final master = getMasterAdminProfile();
      final masterKeys = {
        'user:admin', 'admin', 'user:superadmin', 'superadmin',
        'user:admin@gmwf.org', 'admin@gmwf.org', 'user:admin@gmd.com', 'admin@gmd.com',
        'user:master-local-admin', 'master-local-admin',
      };
      for (final mk in masterKeys) {
        await box.put(mk, master);
        validCanonicalKeys.add(mk);
      }

      final strayKeys = box.keys.where((k) => !validCanonicalKeys.contains(k)).toList();
      for (final sk in strayKeys) {
        await box.delete(sk);
        summary['duplicatesPurged'] = (summary['duplicatesPurged'] ?? 0) + 1;
      }

      await box.flush();
      debugPrint('[LocalStorageService] repairAndSanitizeLocalAccounts completed: $summary');
    } catch (e, st) {
      debugPrint('[LocalStorageService] repairAndSanitizeLocalAccounts error: $e\n$st');
    }

    return summary;
  }

  static Future<void> saveLocalUser(Map<String, dynamic> user) async {
    if (!Hive.isBoxOpen(usersBox)) {
      await openBoxSafe(usersBox);
    }
    final box = Hive.box(usersBox);
    final sanitized = sanitize(user);
    final email = (sanitized['email'] ?? '').toString().trim().toLowerCase();
    final uid = (sanitized['uid'] ?? sanitized['id'] ?? '').toString().trim();
    final username = (sanitized['username'] ?? sanitized['usernameLower'] ?? '').toString().trim();
    final usernameLower = (sanitized['usernameLower'] ?? (username.isNotEmpty ? username.toLowerCase() : (email.isNotEmpty ? email.split('@').first : ''))).toString().trim().toLowerCase();

    sanitized['uid'] = uid;
    sanitized['id'] = uid;
    sanitized['email'] = email;
    sanitized['username'] = username.isNotEmpty ? username : usernameLower;
    sanitized['usernameLower'] = usernameLower;

    // Heuristic for creators / admins
    if (email.contains('zaheer') || usernameLower.contains('zaheer')) {
      sanitized['role'] = 'hq manager';
    }

    // Preserve existing valid profile fields if incoming update is partial or missing them
    final existing = (uid.isNotEmpty ? (box.get('user:$uid') ?? box.get(uid)) : null) ??
        (email.isNotEmpty ? box.get('user:$email') : null) ??
        (usernameLower.isNotEmpty ? box.get('user:$usernameLower') : null);
    if (existing is Map) {
      final existingMap = Map<String, dynamic>.from(existing);
      for (final eKey in existingMap.keys) {
        final existingVal = existingMap[eKey];
        if (existingVal != null && existingVal != '' && existingVal != 'null') {
          final curVal = sanitized[eKey];
          if (curVal == null || curVal == '' || curVal == 'null' ||
              (curVal is List && curVal.isEmpty && existingVal is List && existingVal.isNotEmpty)) {
            sanitized[eKey] = existingVal;
          }
        }
      }
    }

    final incomingRole = (sanitized['role'] ?? '').toString().trim().toLowerCase();
    if (incomingRole.isEmpty || incomingRole == 'unknown' || incomingRole == 'staff') {
      if (existing is Map) {
        final existingRole = (existing['role'] ?? '').toString().trim().toLowerCase();
        if (existingRole.isNotEmpty && existingRole != 'unknown' && existingRole != 'staff') {
          sanitized['role'] = existing['role'];
        }
      }
    }
    sanitized['roles'] = [sanitized['role'] ?? 'staff'];
    sanitized['status'] ??= 'active';
    sanitized['accountStatus'] ??= 'active';
    sanitized['isActive'] ??= true;

    if (uid.isNotEmpty) {
      await box.put(uid, sanitized);
      await box.put('user:$uid', sanitized);
    }
    if (email.isNotEmpty) {
      await box.put('user:$email', sanitized);
    }
    if (usernameLower.isNotEmpty) {
      await box.put('user:$usernameLower', sanitized);
    }

    // Synchronize matching records across alternative keys
    for (final k in box.keys) {
      final val = box.get(k);
      if (val is Map) {
        final vUid = (val['uid'] ?? val['id'] ?? '').toString().trim();
        final vEmail = (val['email'] ?? '').toString().trim().toLowerCase();
        final vUser = (val['usernameLower'] ?? val['username'] ?? '').toString().trim().toLowerCase();
        if ((uid.isNotEmpty && vUid == uid) ||
            (email.isNotEmpty && vEmail == email) ||
            (usernameLower.isNotEmpty && vUser == usernameLower)) {
          await box.put(k, sanitized);
        }
      }
    }
    await box.flush();

    final effectivePw = sanitized['password']?.toString() ?? '112233';
    sanitized['password'] ??= effectivePw;
    sanitized['passwordHash'] ??= hashPassword(effectivePw);

    final offlineKeys = <String>{
      if (uid.isNotEmpty) 'offline_pw__$uid',
      if (email.isNotEmpty) 'offline_pw__$email',
      if (usernameLower.isNotEmpty) 'offline_pw__$usernameLower',
    };
    for (final hk in offlineKeys) {
      await box.put(hk, effectivePw);
    }

    if (email.isNotEmpty) {
      unawaited(OfflineAuthService.saveCredentials(
        usernameOrEmail: email,
        password: effectivePw,
        userData: sanitized,
        setAsLastLoggedIn: false,
      ));
    }
    if (usernameLower.isNotEmpty) {
      unawaited(OfflineAuthService.saveCredentials(
        usernameOrEmail: usernameLower,
        password: effectivePw,
        userData: sanitized,
        setAsLastLoggedIn: false,
      ));
    }
    if (uid.isNotEmpty) {
      unawaited(OfflineAuthService.saveCredentials(
        usernameOrEmail: uid,
        password: effectivePw,
        userData: sanitized,
        setAsLastLoggedIn: false,
      ));
    }
  }

  static Map<String, dynamic>? getLocalUserByEmail(String email) {
    if (!Hive.isBoxOpen(usersBox)) return null;
    final val = Hive.box(usersBox).get('user:$email');
    if (val == null) return null;
    return Map<String, dynamic>.from(val as Map);
  }

  static Map<String, dynamic>? getLocalUserByUid(String uid) {
    if (!Hive.isBoxOpen(usersBox)) return null;
    final box = Hive.box(usersBox);
    final direct = box.get('user:$uid') ?? box.get(uid);
    if (direct is Map) return Map<String, dynamic>.from(direct);

    for (final key in box.keys) {
      final val = box.get(key);
      if (val is Map && ((val['uid'] ?? val['id']) == uid)) return Map<String, dynamic>.from(val);
    }
    return null;
  }

  static List<Map<String, dynamic>> getAllLocalUsers() {
    if (!Hive.isBoxOpen(usersBox)) return [];
    final box = Hive.box(usersBox);
    final users = <Map<String, dynamic>>[];
    final seenUids = <String>{};
    final seenEmails = <String>{};
    final seenUsernames = <String>{};

    for (final key in box.keys) {
      final val = box.get(key);
      if (val is! Map) continue;
      final m = Map<String, dynamic>.from(val);
      final status = (m['status'] ?? m['accountStatus'] ?? '').toString().toLowerCase().trim();
      final isDeleted = m['isDeleted'] == true || status == 'deleted' || status == 'purged';
      if (isDeleted) continue;

      final uid = (m['uid'] ?? m['id'] ?? '').toString().trim();
      final email = (m['email'] ?? '').toString().trim().toLowerCase();
      final username = (m['usernameLower'] ?? m['username'] ?? '').toString().trim().toLowerCase();

      final alreadySeen = (uid.isNotEmpty && seenUids.contains(uid)) ||
          (email.isNotEmpty && seenEmails.contains(email)) ||
          (username.isNotEmpty && seenUsernames.contains(username));

      if (!alreadySeen) {
        if (uid.isNotEmpty) seenUids.add(uid);
        if (email.isNotEmpty) seenEmails.add(email);
        if (username.isNotEmpty) seenUsernames.add(username);
        users.add(m);
      }
    }
    return users;
  }

  static Map<String, dynamic>? findLocalUser(String identifier) {
    if (identifier.trim().isEmpty) return null;
    if (!Hive.isBoxOpen(usersBox)) return null;
    final box = Hive.box(usersBox);
    final target = identifier.toLowerCase().trim();

    final direct = box.get('user:$target') ?? box.get(target);
    if (direct is Map) return Map<String, dynamic>.from(direct);

    final normTarget = target.replaceAll(RegExp(r'[^a-z0-9]'), '');
    final targetPrefix = target.contains('@') ? target.split('@').first.replaceAll(RegExp(r'[^a-z0-9]'), '') : normTarget;

    for (final key in box.keys) {
      final val = box.get(key);
      if (val is Map) {
        final uEmail = (val['email'] ?? '').toString().toLowerCase().trim();
        final uUid = (val['uid'] ?? val['id'] ?? '').toString().toLowerCase().trim();
        final uName = (val['username'] ?? val['userName'] ?? val['name'] ?? '').toString().toLowerCase().trim();

        if (uEmail == target || uUid == target || uName == target || (uEmail.isNotEmpty && uEmail.split('@').first == target)) {
          return Map<String, dynamic>.from(val);
        }

        if (normTarget.isNotEmpty) {
          final normEmail = uEmail.replaceAll(RegExp(r'[^a-z0-9]'), '');
          final normUid = uUid.replaceAll(RegExp(r'[^a-z0-9]'), '');
          final normName = uName.replaceAll(RegExp(r'[^a-z0-9]'), '');
          final emailPrefix = uEmail.contains('@') ? uEmail.split('@').first.replaceAll(RegExp(r'[^a-z0-9]'), '') : '';

          if (normEmail == normTarget ||
              normUid == normTarget ||
              normName == normTarget ||
              (emailPrefix.isNotEmpty && (emailPrefix == targetPrefix || emailPrefix == normTarget)) ||
              (normName.isNotEmpty && (normName == targetPrefix || normName.contains(normTarget) || normTarget.contains(normName)))) {
            return Map<String, dynamic>.from(val);
          }
        }
      }
    }
    return null;
  }

  /// Pushes all valid locally cached users back into Firestore (both root /users and /branches/{bId}/users)
  /// to repair or restore cloud databases if Firestore records were deleted or wiped.
  static Future<int> pushLocalUsersToFirestore() async {
    if (LanFirestoreGate.isLanDesk) return 0; // a dispensary desk on the LAN gets this from the LAN server
    UiStallMonitor.mark('sync: pushLocalUsersToFirestore');
    int syncedCount = 0;
    try {
      if (!Hive.isBoxOpen(usersBox)) {
        await openBoxSafe(usersBox);
      }
      final box = Hive.box(usersBox);
      final Set<String> processedUids = {};

      for (final key in box.keys) {
        final val = box.get(key);
        if (val is! Map) continue;
        final u = Map<String, dynamic>.from(val);
        final status = (u['status'] ?? u['accountStatus'] ?? '').toString().toLowerCase().trim();
        final role = (u['role'] ?? u['userRole'] ?? '').toString().toLowerCase().trim();
        final isActive = u['isActive'] == true || status == 'active';
        final hasActiveRole = role.isNotEmpty && role != 'unknown' && role != 'unassigned';

        if ((u['isDeleted'] == true || status == 'deleted' || status == 'purged') && !isActive && !hasActiveRole) continue;

        final uid = (u['uid'] ?? u['id'] ?? '').toString().trim();
        if (uid.isEmpty || processedUids.contains(uid)) continue;
        processedUids.add(uid);
        // Already pushed from this PC and not changed since. Re-pushing every user on every
        // sweep cost ~3 writes per user, per PC, on each start and each "Sync now".
        if (u['cloudPushedAt'] != null && u['pendingSync'] != true) continue;

        final branchId = (u['branchId'] ?? '').toString().trim().toLowerCase();

        // Auto-heal any corrupted or orphan flags if user has a valid profile
        final rawRole = (u['role'] ?? u['userRole'] ?? '').toString().trim();
        final healedRole = rawRole.isNotEmpty && rawRole != 'unknown' && rawRole != 'unassigned'
            ? rawRole
            : 'staff';

        final firestoreData = sanitizeForCloudUpload(u);
        firestoreData['uid'] = uid;
        firestoreData['id'] = uid;
        firestoreData['role'] = healedRole;
        firestoreData['userRole'] = healedRole;
        firestoreData['roles'] = [healedRole];
        firestoreData['isDeleted'] = false;
        firestoreData['status'] = 'active';
        firestoreData['accountStatus'] = 'active';
        firestoreData['isActive'] = true;
        firestoreData['isRevoked'] = false;
        firestoreData['accessRevoked'] = false;
        firestoreData['isCorruptedOrOrphanAuth'] = false;
        firestoreData.remove('deletedAt');
        firestoreData.remove(null);
        firestoreData.remove('null');
        firestoreData['restoredAt'] = FieldValue.serverTimestamp();
        firestoreData['updatedAt'] = FieldValue.serverTimestamp();

        final email = (u['email'] ?? '').toString().trim().toLowerCase();
        final rawUser = (firestoreData['username'] ?? firestoreData['usernameLower'] ?? (email.isNotEmpty ? email.split('@').first : '')).toString().trim();
        if (rawUser.isNotEmpty) {
          firestoreData['username'] = rawUser;
          firestoreData['usernameLower'] = rawUser.toLowerCase();
        }

        if (branchId.isNotEmpty && branchId != 'all' && branchId != 'global') {
          firestoreData['branchId'] = branchId;
        }

        // Safety: Guard against Firestore 1MB document limit by trimming oversized base64 fields if needed
        final jsonApproxSize = firestoreData.toString().length;
        if (jsonApproxSize > 700000) {
          // If combined payload is too large, retain base64 locally but omit heaviest docs for Firestore doc
          if (firestoreData['degreeCertificateUrl'] != null && firestoreData['degreeCertificateUrl'].toString().startsWith('data:')) {
            firestoreData.remove('degreeCertificateUrl');
          }
          if (firestoreData['identificationUrl'] != null && firestoreData['identificationUrl'].toString().startsWith('data:') && firestoreData.toString().length > 700000) {
            firestoreData.remove('identificationUrl');
          }
        }

        try {
          // Through the REST uploader: a real answer per write, no copy left in the SDK's hidden
          // queue when Firestore does not answer, and an immediate stop when the quota is used up.
          // deletedAt deleted explicitly (removing the key from a merge write keeps the old value).
          final cloudUser = {...firestoreData, 'deletedAt': FieldValue.delete()};
          await CloudDb.instance.collection('users').doc(uid).set(cloudUser, SetOptions(merge: true))
              .timeout(const Duration(seconds: 60));
          if (branchId.isNotEmpty && branchId != 'all' && branchId != 'global') {
            await CloudDb.instance
                .collection('branches')
                .doc(branchId)
                .collection('users')
                .doc(uid)
                .set(cloudUser, SetOptions(merge: true))
                .catchError((_) {});
          }

          final uLower = (firestoreData['usernameLower'] ?? firestoreData['username'] ?? '').toString().trim().toLowerCase();
          if (uLower.isNotEmpty && uLower != uid) {
            await CloudDb.instance.collection('users').doc(uLower).delete().catchError((_) {});
          }

          // Also heal the local record so the UI immediately updates
          final updatedLocal = Map<String, dynamic>.from(u);
          updatedLocal['status'] = 'active';
          updatedLocal['accountStatus'] = 'active';
          updatedLocal['isActive'] = true;
          updatedLocal['isRevoked'] = false;
          updatedLocal['accessRevoked'] = false;
          updatedLocal['isCorruptedOrOrphanAuth'] = false;
          updatedLocal['isDeleted'] = false;
          updatedLocal['role'] = healedRole;
          updatedLocal['cloudPushedAt'] = DateTime.now().toIso8601String();
          updatedLocal['pendingSync'] = false;
          updatedLocal.remove('deletedAt');
          updatedLocal.remove(null);
          updatedLocal.remove('null');
          if (rawUser.isNotEmpty) {
            updatedLocal['username'] = rawUser;
            updatedLocal['usernameLower'] = rawUser.toLowerCase();
          }
          await box.put(key, updatedLocal);
          await box.put(uid, updatedLocal);
          await box.put('user:$uid', updatedLocal);
          if (email.isNotEmpty) await box.put('user:$email', updatedLocal);
          if (rawUser.isNotEmpty) {
            await box.put(rawUser, updatedLocal);
            await box.put(rawUser.toLowerCase(), updatedLocal);
            await box.put('user:${rawUser.toLowerCase()}', updatedLocal);
          }

          syncedCount++;
        } on TimeoutException {
          // Firestore is not answering; the rest would hang the same way. Retry next sweep.
          debugPrint('[LocalStorageService] Firestore not answering — user push paused');
          break;
        } catch (e) {
          debugPrint('[LocalStorageService] Error pushing user $uid to Firestore: $e');
          // Daily quota used up: nothing more is accepted until the reset.
          if (QuotaService.isQuotaError(e)) break;
        }
      }
      await box.flush();
      debugPrint('[LocalStorageService] Successfully pushed $syncedCount local users to Firestore');
    } catch (e) {
      debugPrint('[LocalStorageService] pushLocalUsersToFirestore error: $e');
    }
    return syncedCount;
  }

  static Future<void> deleteLocalUser(String email) async {
    final cleanEmail = email.trim().toLowerCase();
    if (!Hive.isBoxOpen(usersBox)) {
      await openBoxSafe(usersBox);
    }
    final box = Hive.box(usersBox);
    final keysToDelete = <dynamic>{};
    for (final k in box.keys) {
      final val = box.get(k);
      if (val is Map) {
        final vEmail = (val['email'] ?? '').toString().trim().toLowerCase();
        if (vEmail == cleanEmail) {
          keysToDelete.add(k);
        }
      }
      final kStr = k.toString().trim().toLowerCase();
      if (kStr == 'user:$cleanEmail' || kStr == cleanEmail) {
        keysToDelete.add(k);
      }
    }
    for (final k in keysToDelete) {
      await box.delete(k);
    }
    await box.flush();
    if (cleanEmail.isNotEmpty) {
      await OfflineAuthService.clearCredentialsForUser(cleanEmail);
    }
  }

  static Future<void> saveUserOffline({
    required String uid,
    required String branchId,
    required Map<String, dynamic> userData,
  }) async {
    if (!Hive.isBoxOpen(usersBox)) {
      await openBoxSafe(usersBox);
    }
    final box = Hive.box(usersBox);
    final sanitized = sanitize(userData);

    final Map<String, dynamic> flattened;
    if (sanitized.containsKey('updates') && sanitized['updates'] is Map) {
      flattened = {
        ...sanitized,
        ...Map<String, dynamic>.from(sanitized['updates'] as Map),
      }..remove('updates');
    } else {
      flattened = sanitized;
    }
    final effectiveUid = (flattened['uid'] ?? uid).toString().trim();
    final effectiveEmail = (flattened['email'] ?? '').toString().trim().toLowerCase();
    final effectiveUsername = (flattened['usernameLower'] ?? flattened['username'] ?? '').toString().trim().toLowerCase();

    flattened['uid'] = effectiveUid;
    flattened['id'] = effectiveUid;
    flattened['email'] = effectiveEmail;
    flattened['usernameLower'] = effectiveUsername;

    if (effectiveUid.isNotEmpty) {
      await box.put(effectiveUid, flattened);
      await box.put('user:$effectiveUid', flattened);
    }
    if (effectiveEmail.isNotEmpty) {
      await box.put('user:$effectiveEmail', flattened);
    }
    if (effectiveUsername.isNotEmpty) {
      await box.put('user:$effectiveUsername', flattened);
    }

    for (final key in box.keys) {
      final val = box.get(key);
      if (val is Map) {
        final vUid = (val['uid'] ?? val['id'] ?? '').toString().trim();
        final vEmail = (val['email'] ?? '').toString().trim().toLowerCase();
        final vUser = (val['usernameLower'] ?? val['username'] ?? '').toString().trim().toLowerCase();
        if ((effectiveUid.isNotEmpty && vUid == effectiveUid) ||
            (effectiveEmail.isNotEmpty && vEmail == effectiveEmail) ||
            (effectiveUsername.isNotEmpty && vUser == effectiveUsername)) {
          await box.put(key, flattened);
        }
      }
    }
    await box.flush();

    await enqueueSync({
      'type': 'save_user',
      'uid': effectiveUid,
      'branchId': branchId,
      'data': flattened,
    });
  }

  static Future<void> deleteUserOffline({
    required String uid,
    required String branchId,
    required String email,
    String username = '',
  }) async {
    final targetUid = uid.trim();
    final targetEmail = email.trim().toLowerCase();
    final targetUsername = username.trim().toLowerCase();

    // 1. Purge across all potential local user boxes
    final candidateBoxes = [usersBox, 'local_users', 'users', 'local'];
    for (final bName in candidateBoxes) {
      try {
        if (!Hive.isBoxOpen(bName)) {
          await openBoxSafe(bName);
        }
        final box = Hive.box(bName);
        final keysToDelete = <dynamic>{};

        final directKeys = <String>{
          if (targetEmail.isNotEmpty) 'user:$targetEmail',
          if (targetEmail.isNotEmpty) targetEmail,
          if (targetUid.isNotEmpty) 'user:$targetUid',
          if (targetUid.isNotEmpty) targetUid,
          if (targetUsername.isNotEmpty) 'user:$targetUsername',
          if (targetUsername.isNotEmpty) targetUsername,
        };
        directKeys.forEach(keysToDelete.add);

        for (final key in box.keys) {
          final keyStr = key.toString().toLowerCase().trim();
          final val = box.get(key);
          if (val is Map) {
            final map = Map<String, dynamic>.from(val);
            final uidVal = (map['uid'] ?? map['id'] ?? '').toString().trim();
            final emailVal = (map['email'] ?? '').toString().toLowerCase().trim();
            final usernameVal = (map['username'] ?? '').toString().toLowerCase().trim();
            final usernameLowerVal = (map['usernameLower'] ?? '').toString().toLowerCase().trim();

            if ((targetUid.isNotEmpty && uidVal == targetUid) ||
                (targetEmail.isNotEmpty && emailVal == targetEmail) ||
                (targetUsername.isNotEmpty && (usernameVal == targetUsername || usernameLowerVal == targetUsername)) ||
                (targetUsername.isNotEmpty && keyStr.contains(targetUsername)) ||
                (targetEmail.isNotEmpty && keyStr.contains(targetEmail)) ||
                (targetUid.isNotEmpty && keyStr.contains(targetUid.toLowerCase()))) {
              keysToDelete.add(key);
            }
          } else {
            if ((targetUsername.isNotEmpty && keyStr.contains(targetUsername)) ||
                (targetEmail.isNotEmpty && keyStr.contains(targetEmail)) ||
                (targetUid.isNotEmpty && keyStr.contains(targetUid.toLowerCase()))) {
              keysToDelete.add(key);
            }
          }
        }

        for (final key in keysToDelete) {
          await box.delete(key);
        }
        await box.flush();
      } catch (e) {
        debugPrint('[LocalStorageService] Box purge warning for $bName: $e');
      }
    }

    // 2. Clear from OfflineAuthService secure storage
    if (targetUid.isNotEmpty) await OfflineAuthService.clearCredentialsForUser(targetUid);
    if (targetEmail.isNotEmpty) await OfflineAuthService.clearCredentialsForUser(targetEmail);
    if (targetUsername.isNotEmpty) await OfflineAuthService.clearCredentialsForUser(targetUsername);

    // 3. Purge linked employee / biometric data
    try {
      if (targetUid.isNotEmpty) {
        await FinanceLocalStorage.purgeEmployeeForDeletedUser(targetUid);
      }
    } catch (_) {}

    // 4. Enqueue background deletion sync for cloud persistence
    await enqueueSync({
      'type': 'delete_user',
      'uid': targetUid,
      'branchId': branchId,
      'email': targetEmail,
      'username': targetUsername,
    });
  }

  /// Returns the actively signed-in user's data dictionary from Hive app_settings or offline cache.
  static Map<String, dynamic> getActiveUserData() {
    try {
      if (Hive.isBoxOpen('app_settings')) {
        final box = Hive.box('app_settings');
        final data = box.get('user_data') ?? box.get('currentUser') ?? box.get('user');
        if (data is Map) {
          return Map<String, dynamic>.from(data);
        }
      }
    } catch (_) {}
    return {};
  }

  /// Returns the current user's effective role, considering simulation if active.
  static String getActiveUserRole() {
    try {
      if (Hive.isBoxOpen('app_settings')) {
        final box = Hive.box('app_settings');
        final r = box.get('role')?.toString();
        if (r != null && r.isNotEmpty && r != 'unknown') return r.toLowerCase().trim();
        final data = box.get('user_data') ?? box.get('currentUser') ?? box.get('user');
        if (data is Map) {
          final role = data['role']?.toString();
          if (role != null && role.isNotEmpty && role != 'unknown') return role.toLowerCase().trim();
        }
      }
    } catch (_) {}
    return 'staff';
  }

  /// Returns the active user's username or display name.
  static String getActiveUsername() {
    final user = getActiveUserData();
    return (user['username'] ?? user['userName'] ?? user['name'] ?? 'Admin').toString();
  }

  /// Returns the active user's branch ID.
  static String getActiveUserBranchId() {
    final user = getActiveUserData();
    final uEmail = (user['email'] ?? '').toString().toLowerCase().trim();
    final uUser = (user['username'] ?? user['usernameLower'] ?? '').toString().toLowerCase().trim();
    final uUid = (user['uid'] ?? user['id'] ?? '').toString().trim();
    if (uEmail == 'kashif@khi.com' || uEmail.startsWith('kashif@') || uUser == 'kashif' || uUid == 'e5I5hQJQNpe08MuKmOc937dcMR43') {
      return 'karachi';
    }
    return (user['branchId'] ?? '').toString();
  }

  /// Validates whether a branchId represents a valid physical branch entity.
  /// Rejects 'all', 'global', empty strings, 'unknown', 'default', 'null', Firebase Auth UIDs, numeric CNIC strings,
  /// and legacy duplicate branch variants (karachi_1, karachi_2, etc.).
  static bool isValidBranchId(String? branchId) {
    if (branchId == null) return false;
    final b = branchId.trim().toLowerCase();
    if (b.isEmpty ||
        b == 'all' ||
        b == 'global' ||
        b == 'unknown' ||
        b == 'default' ||
        b == 'null' ||
        b == 'undefined' ||
        b == 'karachi_1' ||
        b == 'karachi_2' ||
        b == 'karachi_one' ||
        b == 'karachi_two' ||
        b == 'karachi 1' ||
        b == 'karachi 2' ||
        b == 'karachi-1' ||
        b == 'karachi-2' ||
        b == 'karachi1' ||
        b == 'karachi2') {
      return false;
    }
    // Reject Firebase Auth UIDs (28-char alphanumeric strings like nRhz9M5rGMfR5RYkdbpPBzfz6BJ2)
    // or any generated ID >= 20 chars
    if (b.length >= 20) return false;
    // Reject CNICs (11 to 15 digits)
    final digits = b.replaceAll(RegExp(r'\D'), '');
    if (digits.length >= 11 && digits.length <= 15) return false;
    // Reject any string containing spaces or special characters not typical for branch slugs
    if (RegExp(r'[^a-z0-9_-]').hasMatch(b)) return false;
    return true;
  }

  /// Sanitizes branchId so writes NEVER target 'all', 'global', 'unknown', UIDs, or CNIC branch documents.
  /// Automatically consolidates any legacy Karachi branch duplicates ('karachi_1', 'karachi_2') into 'karachi'.
  /// Falls back to the user's active session branch or [fallback] (default: 'karachi').
  static String sanitizeBranchId(String? branchId, {String fallback = 'karachi'}) {
    final raw = (branchId ?? '').trim().toLowerCase();
    if (raw.contains('karachi') || raw == 'khi' || raw == 'saddar' || raw == 'haji_camp' || raw == 'haji') {
      return 'karachi';
    }
    if (raw.contains('gujrat') || raw == 'grt' || raw == 'gjt') {
      return 'gujrat';
    }
    if (raw.contains('sialkot') || raw == 'skt') {
      return 'sialkot';
    }
    if (raw.contains('rawalpindi') || raw == 'rwp' || raw.contains('pindi')) {
      return 'rawalpindi';
    }
    if (raw.contains('jalalpur') || raw == 'jlj') {
      return 'jalalpurjattan';
    }
    if (isValidBranchId(branchId)) {
      return branchId!.trim().toLowerCase();
    }
    final sessionBranch = getActiveUserBranchId();
    if (sessionBranch.contains('karachi') || sessionBranch == 'khi') {
      return 'karachi';
    }
    if (sessionBranch.contains('gujrat') || sessionBranch == 'grt') {
      return 'gujrat';
    }
    if (sessionBranch.contains('sialkot') || sessionBranch == 'skt') {
      return 'sialkot';
    }
    if (isValidBranchId(sessionBranch)) {
      return sessionBranch.trim().toLowerCase();
    }
    if (isValidBranchId(fallback)) {
      return fallback.trim().toLowerCase();
    }
    return 'karachi';
  }

  static Future<void> saveLocalPatient(
    Map<String, dynamic> patient, {
    bool recordAudit = false,
    bool isFromSync = false,
  }) async {
    var sanitized      = sanitize(patient);

    // Normalize raw 13-digit CNIC into standardized Pakistani format: xxxxx-xxxxxxx-x
    final rawCnic = (sanitized['cnic'] ?? sanitized['patientCnic'])?.toString().trim();
    if (rawCnic != null && RegExp(r'^\d{13}$').hasMatch(rawCnic)) {
      final formatted = '${rawCnic.substring(0, 5)}-${rawCnic.substring(5, 12)}-${rawCnic.substring(12, 13)}';
      sanitized['cnic'] = formatted;
      if (sanitized.containsKey('patientCnic')) {
        sanitized['patientCnic'] = formatted;
      }
    }
    final rawGuard = sanitized['guardianCnic']?.toString().trim();
    if (rawGuard != null && RegExp(r'^\d{13}$').hasMatch(rawGuard)) {
      sanitized['guardianCnic'] = '${rawGuard.substring(0, 5)}-${rawGuard.substring(5, 12)}-${rawGuard.substring(12, 13)}';
    }

    final key          = getPatientKey(sanitized);
    sanitized['patientId'] = key;
    final box = await ensureBoxOpen(patientsBox);
    final existing = box.get(key);

    // MERGE, never overwrite with blanks: partial records (token syncs, stubs carrying only an id)
    // used to replace the full patient and wipe the name, CNIC and phone.
    if (existing is Map) {
      bool blank(dynamic v) {
        if (v == null) return true;
        if (v is String) {
          final t = v.trim();
          return t.isEmpty || t == '0' || t.toLowerCase() == 'null';
        }
        return false;
      }
      final merged = Map<String, dynamic>.from(existing.map((k, v) => MapEntry(k.toString(), v)));
      sanitized.forEach((k, v) {
        if (!blank(v) || blank(merged[k])) merged[k] = v;
      });
      sanitized = merged;
      sanitized['patientId'] = key;
    }

    final List<Map<String, dynamic>> fieldChanges = [];
    String action = 'CREATE';
    if (existing is Map) {
      action = 'EDIT';
      for (final k in ['name', 'patientName', 'phone', 'cnic', 'guardianCnic', 'gender', 'bloodGroup', 'dob', 'address', 'status']) {
        final oldV = (existing[k] ?? '').toString().trim();
        final newV = (sanitized[k] ?? '').toString().trim();
        if (newV.isNotEmpty && oldV != newV) {
          fieldChanges.add({'field': k, 'oldValue': oldV, 'newValue': newV});
        }
      }
    }

    await box.put(key, sanitized);
    final cleanKey = key.replaceAll('-', '').trim();
    if (cleanKey != key) {
      await box.put(cleanKey, sanitized);
    }
    // Also ensure formatted hyphenated key is stored if key is raw 13 digits
    if (cleanKey.length == 13 && RegExp(r'^\d{13}$').hasMatch(cleanKey)) {
      final formatted = '${cleanKey.substring(0, 5)}-${cleanKey.substring(5, 12)}-${cleanKey.substring(12)}';
      if (formatted != key) {
        await box.put(formatted, sanitized);
      }
    } else if (key.contains('_child_')) {
      final parts = key.split('_child_');
      final gClean = parts[0].replaceAll('-', '').trim();
      if (gClean.length == 13 && RegExp(r'^\d{13}$').hasMatch(gClean)) {
        final gFormatted = '${gClean.substring(0, 5)}-${gClean.substring(5, 12)}-${gClean.substring(12)}_child_${parts[1]}';
        if (gFormatted != key) {
          await box.put(gFormatted, sanitized);
        }
        final gRaw = '${gClean}_child_${parts[1]}';
        if (gRaw != key) {
          await box.put(gRaw, sanitized);
        }
      }
    }
    await box.flush();
    await updateActiveEntriesForPatient(sanitized['branchId']?.toString() ?? '', key, sanitized);

    // Only record audit log if explicitly requested from user interaction and NOT during sync/startup
    if (recordAudit && !isFromSync) {
      final bId = (sanitized['branchId'] ?? getActiveUserBranchId()).toString();
      final pName = (sanitized['patientName'] ?? sanitized['name'] ?? 'Unknown').toString();
      final performedBy = (sanitized['performedBy'] ?? sanitized['createdByName'] ?? getActiveUsername()).toString();
      final performedRole = (sanitized['performedByRole'] ?? getActiveUserRole()).toString();

      await recordPatientAuditLog(
        branchId: bId,
        action: action,
        patientId: key,
        patientName: pName,
        patientCnic: (sanitized['patientCnic'] ?? sanitized['cnic'] ?? sanitized['guardianCnic'])?.toString(),
        performedBy: performedBy,
        performedByRole: performedRole,
        fieldChanges: fieldChanges,
        reason: (sanitized['reason'] ?? (action == 'CREATE' ? 'Patient Registration' : 'Patient Details Update')).toString(),
      );
    }
  }

  /// Atomically updates a patient record and migrates all references if CNIC/patientId changed.
  /// Deletes old key, updates active tokens, updates prescriptions, and broadcasts over LAN.
  static Future<String> updatePatientWithCnicMigration({
    required String oldPatientId,
    required Map<String, dynamic> updatedPatient,
    String? oldCnic,
    bool recordAudit = true,
    bool isFromSync = false,
  }) async {
    final box = await ensureBoxOpen(patientsBox);
    final isAdult = updatedPatient['isAdult'] as bool? ?? true;
    final newCnic = (updatedPatient['cnic'] ?? updatedPatient['patientCnic'])?.toString().replaceAll('-', '').trim();
    final cleanOldCnic = (oldCnic ?? oldPatientId).replaceAll('-', '').trim();

    // Determine target key: for adults with CNIC, key is normalized CNIC; otherwise getPatientKey
    String newKey = (newCnic != null && newCnic.isNotEmpty && isAdult)
        ? newCnic
        : getPatientKey(updatedPatient);

    final rawCnic = (updatedPatient['cnic'] ?? updatedPatient['patientCnic'])?.toString().trim();
    if (rawCnic != null && RegExp(r'^\d{13}$').hasMatch(rawCnic)) {
      final formatted = '${rawCnic.substring(0, 5)}-${rawCnic.substring(5, 12)}-${rawCnic.substring(12, 13)}';
      updatedPatient['cnic'] = formatted;
      if (updatedPatient.containsKey('patientCnic')) {
        updatedPatient['patientCnic'] = formatted;
      }
    }
    final rawGuard = updatedPatient['guardianCnic']?.toString().trim();
    if (rawGuard != null && RegExp(r'^\d{13}$').hasMatch(rawGuard)) {
      updatedPatient['guardianCnic'] = '${rawGuard.substring(0, 5)}-${rawGuard.substring(5, 12)}-${rawGuard.substring(12, 13)}';
    }

    updatedPatient['patientId'] = newKey;
    updatedPatient['id'] = newKey;
    final sanitized = sanitize(updatedPatient);

    // If key changed, delete old key from box to prevent duplicate ghost patients
    if (oldPatientId.isNotEmpty && oldPatientId != newKey) {
      await box.delete(oldPatientId);
    }
    // Delete cleanOldCnic ONLY if updating an adult patient whose old CNIC changed
    if (isAdult && cleanOldCnic.isNotEmpty && cleanOldCnic != newKey && cleanOldCnic == oldPatientId) {
      await box.delete(cleanOldCnic);
    }

    await box.put(newKey, sanitized);
    await box.flush();

    // Update all active tokens/entries for this patient to point to new key & new CNIC
    final bId = (sanitized['branchId'] ?? getActiveUserBranchId()).toString();
    await updateActiveEntriesForPatient(bId, newKey, sanitized);

    // Update prescriptions referencing old CNIC or old patientId with strict identity check
    if (cleanOldCnic.isNotEmpty && newCnic != null && newCnic.isNotEmpty && cleanOldCnic != newCnic && !_isDummyCnicValue(cleanOldCnic)) {
      try {
        if (!Hive.isBoxOpen(prescriptionsBox)) {
          await openBoxSafe(prescriptionsBox);
        }
        final pBox = Hive.box(prescriptionsBox);
        final targetNameNorm = _normalizeName((updatedPatient['name'] ?? updatedPatient['patientName'] ?? '').toString());

        for (final pk in pBox.keys) {
          final pVal = pBox.get(pk);
          if (pVal is Map) {
            final pCnic = (pVal['patientCnic'] ?? pVal['cnic'])?.toString().replaceAll('-', '').trim();
            final pId = (pVal['patientId'] ?? pVal['id'])?.toString().trim();
            final pNameNorm = _normalizeName((pVal['patientName'] ?? pVal['name'] ?? '').toString());
            final pIsAdult = pVal['isAdult'] is bool ? pVal['isAdult'] as bool : !(pId?.contains('_child_') ?? false);

            bool shouldUpdate = false;
            if (oldPatientId.isNotEmpty && pId == oldPatientId) {
              shouldUpdate = true;
            } else if (pCnic == cleanOldCnic && isAdult == pIsAdult) {
              if (targetNameNorm.isEmpty || pNameNorm.isEmpty || targetNameNorm == pNameNorm) {
                shouldUpdate = true;
              }
            }

            if (shouldUpdate) {
              final updatedP = Map<String, dynamic>.from(pVal);
              updatedP['patientCnic'] = updatedPatient['cnic'] ?? newCnic;
              updatedP['patientId'] = newKey;
              await pBox.put(pk, updatedP);
            }
          }
        }
        await pBox.flush();
      } catch (_) {}
    }

    // Broadcast over LAN and Enqueue to Firestore ONLY if this save did NOT originate from cloud/LAN sync
    if (!isFromSync) {
      try {
        if (oldPatientId.isNotEmpty && oldPatientId != newKey) {
          RealtimeManager().sendMessage(RealtimeEvents.payload(
            type: 'migrate_patient_key',
            branchId: bId,
            data: {
              'oldPatientId': oldPatientId,
              'newPatientId': newKey,
              'patient': sanitized,
            },
          ));
        } else {
          RealtimeManager().sendMessage(RealtimeEvents.payload(
            type: RealtimeEvents.savePatient,
            branchId: bId,
            data: sanitized,
          ));
        }
      } catch (_) {}

      // Enqueue Firestore sync
      await enqueueSync({
        'type': 'save_patient',
        'branchId': bId,
        'patientId': newKey,
        'oldPatientId': oldPatientId,
        'data': sanitized,
      });
    }

    return newKey;
  }

  static Future<void> deleteLocalPatient(String patientId, {String? reason, String? performedBy, String? approvedBy}) async {
    final box = Hive.box(patientsBox);
    final existing = box.get(patientId);
    String pName = 'Unknown';
    String branchId = getActiveUserBranchId();
    String? cnic;
    if (existing is Map) {
      pName = (existing['name'] ?? existing['patientName'] ?? 'Unknown').toString();
      branchId = (existing['branchId'] ?? branchId).toString();
      cnic = (existing['cnic'] ?? existing['patientCnic'] ?? existing['guardianCnic'])?.toString();
    }
    await box.delete(patientId);

    // Record Audit Log for Patient Deletion
    await recordPatientAuditLog(
      branchId: branchId,
      action: 'DELETE',
      patientId: patientId,
      patientName: pName,
      patientCnic: cnic,
      performedBy: performedBy ?? getActiveUsername(),
      performedByRole: getActiveUserRole(),
      approvedBy: approvedBy,
      reason: reason ?? 'Patient Record Deleted',
    );

    // Enqueue background Firestore sync
    await enqueueSync({
      'type': 'delete_patient',
      'branchId': branchId,
      'patientId': patientId,
      'reason': reason ?? 'Patient Record Deleted',
    });
  }

  /// Patient fields that may be propagated onto that patient's queue entries.
  static const _patientIdentityFields = [
    'patientId', 'patientName', 'name', 'fullName',
    'cnic', 'patientCnic', 'guardianCnic', 'guardianName', 'isAdult',
    'phone', 'contactPhone', 'address',
    'gender', 'patientGender', 'age', 'patientAge', 'dob', 'bloodGroup',
  ];

  static Future<void> updateActiveEntriesForPatient(String branchId, String patientId, Map<String, dynamic> changes) async {
    try {
      if (!Hive.isBoxOpen(entriesBox)) return;
      final box = Hive.box(entriesBox);
      final sanitizedChanges = sanitize(changes);
      final keysToUpdate = <dynamic, Map<String, dynamic>>{};

      final isTargetAdult = sanitizedChanges['isAdult'] is bool
          ? sanitizedChanges['isAdult'] as bool
          : !patientId.contains('_child_');
      final targetCnic = (sanitizedChanges['cnic'] ?? sanitizedChanges['patientCnic'] ?? '').toString().replaceAll('-', '').trim();
      final targetGuardian = (sanitizedChanges['guardianCnic'] ?? '').toString().replaceAll('-', '').trim();
      final targetName = _normalizeName((sanitizedChanges['patientName'] ?? sanitizedChanges['name'] ?? '').toString());
      final cleanTargetPid = patientId.replaceAll(RegExp(r'[^\w]'), '').toLowerCase();

      for (final key in box.keys) {
        final val = box.get(key);
        if (val is Map) {
          final entry = Map<String, dynamic>.from(val);
          final ePid = (entry['patientId'] ?? entry['id'])?.toString().trim() ?? '';
          final cleanEPid = ePid.replaceAll(RegExp(r'[^\w]'), '').toLowerCase();
          final resolvedEPid = resolveIndividualPatientId(entry).trim();
          final cleanResolvedEPid = resolvedEPid.replaceAll(RegExp(r'[^\w]'), '').toLowerCase();

          final eName = _normalizeName((entry['patientName'] ?? entry['name'] ?? '').toString());
          final eCnic = (entry['cnic'] ?? entry['patientCnic'] ?? '').toString().replaceAll('-', '').trim();
          final eGuardian = (entry['guardianCnic'] ?? '').toString().replaceAll('-', '').trim();
          final eAge = (entry['age'] is num) ? (entry['age'] as num).toInt() : (int.tryParse(entry['age']?.toString() ?? '') ?? 0);
          final eIsAdult = entry['isAdult'] is bool
              ? entry['isAdult'] as bool
              : (!ePid.contains('_child_') && !resolvedEPid.contains('_child_') && eGuardian.isEmpty && (eAge == 0 || eAge >= 20));

          // Rule 0: Never cross-update between adult and child UNLESS explicitly migrating by exact patientId
          final isExactIdMatch = cleanTargetPid.isNotEmpty && (cleanTargetPid == cleanEPid || cleanTargetPid == cleanResolvedEPid);
          if (!isExactIdMatch && isTargetAdult != eIsAdult) continue;

          bool matches = isExactIdMatch;

          // 1. Exact canonical ID match (already handled by isExactIdMatch)
          if (matches) {
            // Already matched
          } else if (isTargetAdult && eIsAdult) {
            // 2. Adult matching: must both be adults with matching non-dummy CNIC
            if (targetCnic.isNotEmpty && eCnic.isNotEmpty && targetCnic == eCnic && !_isDummyCnicValue(targetCnic)) {
              if (targetName.isEmpty || eName.isEmpty || targetName == eName) {
                matches = true;
              }
            }
          } else if (!isTargetAdult && !eIsAdult) {
            // 3. Child matching: must both be children under same guardian CNIC with exact matching name
            final effTargetG = targetGuardian.isNotEmpty ? targetGuardian : targetCnic;
            final effEG = eGuardian.isNotEmpty ? eGuardian : eCnic;
            if (effTargetG.isNotEmpty && effEG.isNotEmpty && effTargetG == effEG && !_isDummyCnicValue(effTargetG)) {
              if (targetName.isNotEmpty && eName.isNotEmpty && targetName == eName) {
                matches = true;
              }
            }
          }

          if (matches) {
            // Copy only patient-identity fields. The changes map is usually a whole patient
            // record, whose 'status' (Zakat), 'createdAt', 'createdBy', 'id' etc. belong to the
            // patient, not to the token — merging them all clobbered the queue entry.
            final updatedEntry = Map<String, dynamic>.from(entry);
            for (final f in _patientIdentityFields) {
              if (sanitizedChanges.containsKey(f)) updatedEntry[f] = sanitizedChanges[f];
            }

            if (sanitizedChanges['patientName'] != null) {
              updatedEntry['patientName'] = sanitizedChanges['patientName'];
              updatedEntry['name'] = sanitizedChanges['patientName'];
            }

            if (sanitizedChanges.containsKey('vitals')) {
              final newVitals = Map<String, dynamic>.from(entry['vitals'] is Map ? entry['vitals'] : {});
              if (sanitizedChanges['vitals'] is Map) {
                newVitals.addAll(Map<String, dynamic>.from(sanitizedChanges['vitals']));
              }
              updatedEntry['vitals'] = newVitals;
            }

            // Explicit Receptionist / Supervisor identity edit bumps identityRevision
            // and clears lanPushSig so the corrected name/CNIC is synced across the LAN.
            final int prevIdRev = intOf(entry['identityRevision']);
            updatedEntry['identityRevision'] = prevIdRev + 1;
            updatedEntry['updatedAt'] = CampSessionService.getAuthoritativeTime().toIso8601String();
            updatedEntry.remove('lanPushSig');
            if (updatedEntry['prescription'] is Map) {
              final updRx = Map<String, dynamic>.from(updatedEntry['prescription'] as Map);
              if (updatedEntry['patientName'] != null) {
                updRx['patientName'] = updatedEntry['patientName'];
                updRx['name'] = updatedEntry['patientName'];
              }
              if (updatedEntry['patientCnic'] != null) {
                updRx['patientCnic'] = updatedEntry['patientCnic'];
                updRx['cnic'] = updatedEntry['patientCnic'];
              }
              updRx['identityRevision'] = prevIdRev + 1;
              updatedEntry['prescription'] = updRx;
            }

            keysToUpdate[key] = updatedEntry;
          }
        }
      }

      for (final e in keysToUpdate.entries) {
        await box.put(e.key, e.value);
      }
      await box.flush();
    } catch (e) {
      debugPrint('[LocalStorage] Error updating active entries for patient $patientId: $e');
    }
  }

  static Future<void> saveAllLocalPatients(
      List<Map<String, dynamic>> patients) async {
    final box     = await ensureBoxOpen(patientsBox);
    final updates = <String, Map<String, dynamic>>{};
    for (final patient in patients) {
      try {
        var s = sanitize(patient);
        final key  = getPatientKey(s);
        final status = (s['status'] ?? '').toString().toLowerCase().trim();
        final isDeleted = s['isDeleted'] == true || status == 'deleted';
        if (isDeleted) {
          await box.delete(key);
          final rawId = (s['patientId'] ?? s['id'])?.toString();
          if (rawId != null && rawId.isNotEmpty) await box.delete(rawId);
          final cnic = (s['cnic'] ?? s['patientCnic'] ?? s['guardianCnic'])?.toString();
          if (cnic != null && cnic.isNotEmpty) await box.delete(cnic);
          continue;
        }
        s['patientId'] = key;
        if (s['pendingSync'] != true) {
          s['syncStatus'] = 'synced';
          s['synced'] = true;
          s['pendingSync'] = false;
        }
        updates[key] = s;
      } catch (e) {
        debugPrint('[LocalStorage] Skipped invalid patient: $e');
      }
    }
    if (updates.isNotEmpty) {
      await box.putAll(updates);
      try {
        if (Hive.isBoxOpen('app_flags')) {
          final flagsBox = Hive.box('app_flags');
          for (final k in updates.keys) {
            flagsBox.put('patient_synced_$k', true);
          }
        }
      } catch (_) {}
    }
    await box.flush();
  }

  static Map<String, dynamic>? getLocalPatient(String patientId) {
    if (!Hive.isBoxOpen(patientsBox)) return null;
    final box = Hive.box(patientsBox);
    final val = box.get(patientId);
    if (val is Map) return Map<String, dynamic>.from(val);
    final clean = patientId.replaceAll('-', '').trim();
    final cleanVal = box.get(clean);
    if (cleanVal is Map) return Map<String, dynamic>.from(cleanVal);

    if (patientId.contains('_child_') || clean.contains('_child_')) {
      final parts = patientId.split('_child_');
      final gCnic = parts[0].replaceAll('-', '').trim();
      final childSuffix = parts.sublist(1).join('_child_');
      if (gCnic.length == 13) {
        final hyphenated = '${gCnic.substring(0, 5)}-${gCnic.substring(5, 12)}-${gCnic.substring(12)}';
        final v = box.get('${hyphenated}_child_$childSuffix') ?? box.get('${gCnic}_child_$childSuffix');
        if (v is Map) return Map<String, dynamic>.from(v);
      }
      for (final v in box.values) {
        if (v is Map) {
          final pid = (v['patientId'] ?? v['id'] ?? '').toString();
          final cleanPid = pid.replaceAll('-', '').trim();
          if (cleanPid == clean || pid == patientId) {
            return Map<String, dynamic>.from(v);
          }
        }
      }
      return null;
    }
    return getLocalPatientByCnic(patientId);
  }

  static Map<String, dynamic>? getLocalPatientByCnic(String cnic) {
    if (!Hive.isBoxOpen(patientsBox)) return null;
    final normalized = cnic.replaceAll('-', '').trim();
    final box        = Hive.box(patientsBox);
    var direct = box.get(normalized) ?? box.get(cnic);
    if (direct == null && normalized.length == 13) {
      final hyphenated = '${normalized.substring(0, 5)}-${normalized.substring(5, 12)}-${normalized.substring(12)}';
      direct = box.get(hyphenated);
    }
    if (direct != null && direct is Map) {
      final isDirectAdult = direct['isAdult'] != false && !(direct['patientId']?.toString().contains('_child_') ?? false);
      if (isDirectAdult) return Map<String, dynamic>.from(direct);
    }

    // Prioritize scanning for adult patient record first
    for (final raw in box.values) {
      if (raw is! Map) continue;
      final rawCnic = (raw['cnic'] ?? raw['patientCnic'])?.toString().replaceAll('-', '').trim();
      final isAdult = raw['isAdult'] != false && !(raw['patientId']?.toString().contains('_child_') ?? false);
      if (isAdult && rawCnic == normalized) {
        return Map<String, dynamic>.from(raw);
      }
    }

    if (direct != null && direct is Map) {
      return Map<String, dynamic>.from(direct);
    }

    // Fallback: search for child patient registered under this guardian CNIC
    for (final key in box.keys) {
      if (key is String && (key.startsWith('${normalized}_child_') || key.startsWith('${cnic}_child_'))) {
        final val = box.get(key);
        if (val is Map) {
          return Map<String, dynamic>.from(val);
        }
      }
    }
    return null;
  }

  /// Searches registered patients by name (exact match, child key match, or alias/substring).
  static Map<String, dynamic>? findPatientByName(String rawName) {
    if (rawName.isEmpty ||
        rawName.toLowerCase() == 'unknown patient' ||
        rawName.toLowerCase() == 'unknown' ||
        rawName.toLowerCase() == 'null' ||
        rawName == '0' ||
        rawName == '-') {
      return null;
    }
    if (!Hive.isBoxOpen(patientsBox)) return null;
    final box = Hive.box(patientsBox);

    final targetNorm = rawName.trim().toLowerCase().replaceAll(RegExp(r'\s+'), ' ');
    final targetCompact = targetNorm.replaceAll(' ', '');

    // 1. Exact match on name
    for (final k in box.keys) {
      final v = box.get(k);
      if (v is Map) {
        final pName = (v['name'] ?? v['patientName'] ?? '').toString().trim().toLowerCase().replaceAll(RegExp(r'\s+'), ' ');
        if (pName.isNotEmpty && (pName == targetNorm || pName.replaceAll(' ', '') == targetCompact)) {
          return Map<String, dynamic>.from(v);
        }
      }
    }

    // 2. Child key match (e.g. 4230116994639_child_dua)
    for (final k in box.keys) {
      final kStr = k.toString().toLowerCase();
      if (kStr.contains('_child_')) {
        final childName = kStr.split('_child_').last;
        if (childName == targetCompact || childName.contains(targetCompact)) {
          final v = box.get(k);
          if (v is Map) return Map<String, dynamic>.from(v);
        }
      }
    }

    // 3. Substring match & common phonetic/spelling variants (e.g. Jivan Das for Jeevan, Shabbir for Shabbir Husain)
    for (final k in box.keys) {
      final v = box.get(k);
      if (v is Map) {
        final pName = (v['name'] ?? v['patientName'] ?? '').toString().trim().toLowerCase();
        if (pName.isNotEmpty) {
          if (pName.contains(targetNorm) || targetNorm.contains(pName)) {
            return Map<String, dynamic>.from(v);
          }
          if ((targetNorm.contains('jeevan') && pName.contains('jivan')) ||
              (targetNorm.contains('jivan') && pName.contains('jeevan'))) {
            return Map<String, dynamic>.from(v);
          }
        }
      }
    }
    return null;
  }

  static int _lastHealTimestamp = 0;

  /// Heals any tokens in entriesBox whose CNICs were corrupted or set to synthetic "unknown_cnic_..."
  /// by reconnecting them to their genuine patient profile in patientsBox.
  static Future<int> healAndRestorePatientCnics([String? branchId, bool force = false]) async {
    if (!force) {
      try {
        if (!Hive.isBoxOpen('app_flags')) await openBoxSafe('app_flags');
        final flags = Hive.box('app_flags');
        final lastStr = flags.get('last_heal_patient_cnics_ts') as String?;
        if (lastStr != null) {
          final lastDt = DateTime.tryParse(lastStr);
          if (lastDt != null && DateTime.now().difference(lastDt).inHours < 12) {
            return 0; // Cooldown: run once per 12 hours max unless forced
          }
        }
        await flags.put('last_heal_patient_cnics_ts', DateTime.now().toIso8601String());
      } catch (_) {}
    }

    int healed = 0;
    try {
      if (!Hive.isBoxOpen(entriesBox)) await openBoxSafe(entriesBox);
      if (!Hive.isBoxOpen(patientsBox)) await openBoxSafe(patientsBox);

      final eBox = Hive.box(entriesBox);
      final pBox = Hive.box(patientsBox);
      final updates = <dynamic, Map<String, dynamic>>{};

      // Build in-memory indexes for genuine patients: O(N) once instead of O(N*M)
      final Map<String, Map<String, dynamic>> nameMap = {};
      final Map<String, Map<String, dynamic>> idMap = {};
      for (final pk in pBox.keys) {
        final pv = pBox.get(pk);
        if (pv is! Map) continue;
        final p = Map<String, dynamic>.from(pv);
        final name = (p['name'] ?? p['fullName'] ?? p['patientName'] ?? '').toString().trim().toLowerCase();
        if (name.isNotEmpty) nameMap[name] = p;
        final pid = (p['id'] ?? pk).toString().trim();
        if (pid.isNotEmpty) idMap[pid] = p;
      }

      int processed = 0;
      for (final key in eBox.keys) {
        processed++;
        if (processed % 100 == 0) {
          await Future.delayed(Duration.zero); // Yield main isolate to prevent UI hang
        }

        final val = eBox.get(key);
        if (val is! Map) continue;
        final entry = Map<String, dynamic>.from(val);

        final rawCnic = (entry['patientCnic'] ?? entry['cnic'] ?? '').toString().trim();
        final rawGuard = (entry['guardianCnic'] ?? '').toString().trim();
        final isCorruptCnic = rawCnic.isEmpty ||
            rawCnic.startsWith('unknown_cnic_') ||
            rawCnic.startsWith('unknown_') ||
            rawCnic == '00000-0000000-0' ||
            rawCnic == '-';

        if (!isCorruptCnic && rawGuard.isNotEmpty && !rawGuard.startsWith('unknown_')) {
          continue; // Already has a genuine CNIC
        }

        final patientName = (entry['patientName'] ?? entry['name'] ?? entry['fullName'])?.toString().trim().toLowerCase() ?? '';
        final pId = (entry['patientId'] ?? entry['id'])?.toString().trim() ?? '';

        Map<String, dynamic>? matched;

        // Try lookup by patientId first (O(1) fast lookup)
        if (pId.isNotEmpty && !pId.startsWith('unknown_')) {
          matched = idMap[pId] ?? getLocalPatient(pId);
        }

        // Try lookup by name (O(1) fast lookup)
        if (matched == null && patientName.isNotEmpty) {
          matched = nameMap[patientName];
        }

        if (matched != null) {
          final realCnic = (matched['cnic'] ?? matched['patientCnic'])?.toString().trim() ?? '';
          final realGuard = (matched['guardianCnic'])?.toString().trim() ?? '';
          final effectiveCnic = realCnic.isNotEmpty && !realCnic.startsWith('unknown_')
              ? realCnic
              : realGuard.isNotEmpty && !realGuard.startsWith('unknown_')
                  ? realGuard
                  : '';

          if (effectiveCnic.isNotEmpty) {
            entry['patientCnic'] = effectiveCnic;
            entry['cnic'] = effectiveCnic;
            if (realGuard.isNotEmpty) entry['guardianCnic'] = realGuard;
            if (matched['id'] != null) entry['patientId'] = matched['id'];

            // Also heal prescription nested inside entry if corrupt
            if (entry['prescription'] is Map) {
              final presc = Map<String, dynamic>.from(entry['prescription'] as Map);
              final pC = (presc['patientCnic'] ?? presc['cnic'])?.toString().trim() ?? '';
              if (pC.isEmpty || pC.startsWith('unknown_') || pC == '00000-0000000-0') {
                presc['patientCnic'] = effectiveCnic;
                presc['cnic'] = effectiveCnic;
                if (realGuard.isNotEmpty) presc['guardianCnic'] = realGuard;
                entry['prescription'] = presc;
              }
            }

            updates[key] = entry;
            healed++;
          }
        }
      }

      if (updates.isNotEmpty) {
        await eBox.putAll(updates);
        await eBox.flush();
        invalidateLocalEntriesCache();
        debugPrint('[LocalStorage] 🩺 Successfully healed $healed entries with genuine CNICs from patientsBox!');
      }
    } catch (e) {
      debugPrint('[LocalStorage] Error in healAndRestorePatientCnics: $e');
    }
    return healed;
  }

  static bool hasEnoughLocalPatients({String? branchId, int minCount = 5}) {
    if (!Hive.isBoxOpen(patientsBox)) return false;
    final box = Hive.box(patientsBox);
    if (branchId == null) return box.length >= minCount;
    int count = 0;
    for (final v in box.values) {
      if (v is Map) {
        final bId = (v['branchId'] ?? '').toString().toLowerCase().trim();
        if (bId == branchId.toLowerCase().trim() || branchId.toLowerCase().trim() == 'all') {
          count++;
          if (count >= minCount) return true;
        }
      }
    }
    return count >= minCount;
  }

  static List<Map<String, dynamic>> getAllLocalPatients({String? branchId}) {
    if (!Hive.isBoxOpen(patientsBox)) return [];
    var patients = Hive.box(patientsBox)
        .values
        .whereType<Map>()
        .map((v) => Map<String, dynamic>.from(v))
        .toList();
    if (branchId != null) {
      patients = patients
          .where((p) => p['branchId'] == branchId)
          .toList();
    }
    return patients;
  }

  static List<Map<String, dynamic>> searchPatientsByCnicOrGuardian(
      String input, {String? branchId, bool globalSearch = false, int maxResults = 50}) {
    if (!Hive.isBoxOpen(patientsBox)) return [];
    final trimmed = input.trim();
    if (trimmed.isEmpty) return [];

    final normalized      = trimmed.replaceAll('-', '').toLowerCase();
    final normalizedPhone = normalized.replaceAll(RegExp(r'\D'), '');
    final normalizedName  = normalized.replaceAll(RegExp(r'[^a-z0-9]'), '');

    final box = Hive.box(patientsBox);
    final results = <Map<String, dynamic>>[];
    final seenIds = <String>{};

    // [A2] Fast O(1) Key Lookup before linear scan
    void tryAddDirect(dynamic val) {
      if (val is Map) {
        // A key alias can outlive an edit (e.g. a patient later re-saved as a child under
        // another guardian). Accept it only if the record still carries the searched value.
        String d(dynamic v) => (v ?? '').toString().replaceAll('-', '').trim().toLowerCase();
        final idNorm = d(val['patientId'] ?? val['id']);
        final stillMatches = d(val['cnic']) == normalized ||
            d(val['patientCnic']) == normalized ||
            d(val['guardianCnic']) == normalized ||
            idNorm == normalized ||
            idNorm.startsWith('${normalized}_child_');
        if (!stillMatches) return;
        final p = Map<String, dynamic>.from(val);
        // For direct key lookups (exact CNIC / ID), we always accept to prevent "Patient not found" -> "Already exists" deadlocks!
        final pid = (p['patientId'] ?? getPatientKey(p)).toString();
        p['patientId'] = pid;
        if (!seenIds.contains(pid)) {
          seenIds.add(pid);
          results.add(p);
        }
      }
    }

    final hasLetters = RegExp(r'[a-zA-Z]').hasMatch(trimmed);
    final isPhoneQuery = !hasLetters &&
        ((normalizedPhone.startsWith('03') && normalizedPhone.length == 11) ||
         (normalizedPhone.startsWith('92') && normalizedPhone.length == 12));
    final isCnicQuery = !hasLetters && !isPhoneQuery && normalizedPhone.length == 13;

    // Wait until all digits of a numeric CNIC (13 digits) or Phone (11/12 digits) have been written!
    // Never return partial matches on half-typed numbers like "17301-2" (6 digits).
    if (!hasLetters && !isPhoneQuery && !isCnicQuery) {
      return [];
    }

    tryAddDirect(box.get(trimmed));
    if (normalized != trimmed) tryAddDirect(box.get(normalized));

    // Also check child prefix keys in box for fast direct lookup (only on complete 13-digit guardian CNIC)
    if (normalizedPhone.length == 13 || (hasLetters && normalized.length >= 5)) {
      final childPrefix = '${normalized}_child_';
      for (final k in box.keys) {
        if (k is String && k.startsWith(childPrefix)) {
          tryAddDirect(box.get(k));
        }
      }
    }

    // If input is short (< 3 characters), do not perform expensive full box scan
    if (normalized.length < 3 && normalizedName.length < 3 && normalizedPhone.length < 3) {
      return results;
    }

    for (final raw in box.values) {
      if (results.length >= maxResults) break;
      if (raw is! Map) continue;

      final pBranch = raw['branchId']?.toString();
      final matchesBranch = branchId == null ||
          globalSearch ||
          pBranch == null ||
          pBranch.isEmpty ||
          pBranch == branchId ||
          (sanitizeBranchId(pBranch) == sanitizeBranchId(branchId)) ||
          (CampSessionService.isKarachiFamily(pBranch) && CampSessionService.isKarachiFamily(branchId));

      final cnic     = raw['cnic']?.toString().replaceAll('-', '').trim().toLowerCase() ?? '';
      final guardian = raw['guardianCnic']?.toString().replaceAll('-', '').trim().toLowerCase() ?? '';
      final phone    = raw['phone']?.toString().replaceAll(RegExp(r'\D'), '') ?? '';
      final name     = _normalizeName(raw['name']?.toString() ?? '');
      final pIdRaw   = (raw['patientId'] ?? raw['id'] ?? '').toString().toLowerCase().trim();
      final pIdNorm  = pIdRaw.replaceAll('-', '');

      bool match = false;
      final isExactId = pIdRaw.isNotEmpty && (pIdRaw == trimmed.toLowerCase() || pIdNorm == normalized);
      final isExactCnic = isCnicQuery &&
          ((cnic.isNotEmpty && (cnic == normalizedPhone || cnic == normalized)) ||
           (guardian.isNotEmpty && (guardian == normalizedPhone || guardian == normalized)));

      if (isExactId || isExactCnic) {
        // Exact Patient ID, CNIC or Guardian CNIC match: Always match to prevent cross-branch duplicate registration deadlocks
        match = true;
      } else if (matchesBranch) {
        if (isPhoneQuery && phone.isNotEmpty) {
          final querySub = normalizedPhone.length >= 10
              ? normalizedPhone.substring(normalizedPhone.length - 10)
              : normalizedPhone;
          final phoneSub = phone.length >= 10 ? phone.substring(phone.length - 10) : phone;
          if (phone == normalizedPhone || (querySub.length == 10 && phoneSub == querySub)) {
            match = true;
          }
        } else if (hasLetters && normalizedName.length >= 3 &&
            name.isNotEmpty &&
            name.contains(normalizedName)) {
          match = true;
        }
      }

      if (match) {
        final p = Map<String, dynamic>.from(raw);
        final pid = (p['patientId'] ?? getPatientKey(p)).toString();
        p['patientId'] = pid;
        if (!seenIds.contains(pid)) {
          seenIds.add(pid);
          results.add(p);
        }
      }
    }
    // If no results found in branch scope, fallback to global search to avoid false "Patient not found"
    if (results.isEmpty && !globalSearch && branchId != null) {
      return searchPatientsByCnicOrGuardian(input, branchId: branchId, maxResults: maxResults, globalSearch: true);
    }
    return results;
  }

  static Future<void> recordPatientAuditLog({
    required String branchId,
    required String action,
    required String patientId,
    String? patientName,
    String? patientCnic,
    String? serial,
    String? performedBy,
    String? performedByRole,
    String? approvedBy,
    String? rejectedBy,
    String? requestedBy,
    String? reason,
    dynamic fieldChanges,
    Map<String, dynamic>? metadata,
  }) async {
    try {
      if (!Hive.isBoxOpen(auditLogsBox)) {
        await Hive.openBox(auditLogsBox);
      }
      final now = DateTime.now().toUtc().toIso8601String();
      final localId = 'audit_patient_${DateTime.now().microsecondsSinceEpoch}_$patientId';
      final logEntry = <String, dynamic>{
        'id': localId,
        'localId': localId,
        'module': 'patient',
        'entityType': 'patient',
        'entityId': patientId,
        'patientId': patientId,
        'patientName': patientName ?? 'Unknown Patient',
        'patientCnic': patientCnic ?? '',
        'serial': serial ?? '',
        'action': action.toUpperCase(),
        'performedBy': performedBy ?? getActiveUsername(),
        'performedByRole': performedByRole ?? getActiveUserRole(),
        'approvedBy': approvedBy,
        'rejectedBy': rejectedBy,
        'requestedBy': requestedBy,
        'reason': reason ?? '',
        'fieldChanges': fieldChanges ?? [],
        'metadata': metadata ?? {},
        'branchId': branchId,
        'branchContext': branchId,
        'timestamp': now,
        'createdAt': now,
      };

      final sanitized = sanitize(logEntry);
      await Hive.box(auditLogsBox).put(localId, sanitized);
      await Hive.box(auditLogsBox).flush();

      // Enqueue sync
      await enqueueSync({
        'type': 'save_audit_log',
        'branchId': branchId,
        'data': sanitized,
      });
    } catch (e) {
      debugPrint('[LocalStorageService] Error recording patient audit log: $e');
    }
  }

  static List<Map<String, dynamic>> getPatientAuditLogs({String? branchId, String? patientId, String? serial}) {
    if (!Hive.isBoxOpen(auditLogsBox)) return [];
    final box = Hive.box(auditLogsBox);
    final list = <Map<String, dynamic>>[];
    final normBranch = branchId?.toLowerCase().trim();
    final normPid = patientId?.toLowerCase().trim();
    final normSerial = serial?.toLowerCase().trim();

    for (final val in box.values) {
      if (val is! Map) continue;
      final map = Map<String, dynamic>.from(val);
      final module = map['module']?.toString().toLowerCase();
      final entity = map['entityType']?.toString().toLowerCase();
      if (module != 'patient' && entity != 'patient') continue;

      if (normBranch != null && normBranch.isNotEmpty && normBranch != 'all') {
        final b = (map['branchId'] ?? map['branchContext'])?.toString().toLowerCase();
        if (b != null && b.isNotEmpty && b != normBranch) continue;
      }
      if (normPid != null && normPid.isNotEmpty) {
        final pid = (map['entityId'] ?? map['patientId'])?.toString().toLowerCase();
        if (pid != normPid && pid != null && !pid.contains(normPid)) continue;
      }
      if (normSerial != null && normSerial.isNotEmpty) {
        final ser = map['serial']?.toString().toLowerCase();
        if (ser != normSerial && ser != null && !ser.contains(normSerial)) continue;
      }
      list.add(map);
    }

    list.sort((a, b) => (b['timestamp']?.toString() ?? '').compareTo(a['timestamp']?.toString() ?? ''));
    return list;
  }

  // ════════════════════════════════════════════════════════════════════════════
  // ENTRIES / TOKENS
  // ════════════════════════════════════════════════════════════════════════════

  /// ⚠️ PERMANENT ARCHITECTURAL RULE — RECEPTIONIST IDENTITY IMMUTABILITY:
  /// The Receptionist is the authoritative source of patient identity (`patientName`, `name`,
  /// `fullName`, `patientCnic`, `cnic`, `guardianCnic`, `guardianName`, `age`, `gender`, `phone`).
  /// Once a valid patient name or CNIC is recorded by the Receptionist on a token, it must
  /// NEVER be overwritten, cleared, or replaced with synthetic placeholders (such as `unknown_...`,
  /// `-`, `0000000000000`, or `Unknown Patient`) by the Doctor screen, Dispenser screen, LAN catch-up,
  /// or any future module across any branch or camp.
  static bool isValidPatientNameValue(dynamic val) {
    if (val == null) return false;
    final s = val.toString().trim();
    if (s.isEmpty) return false;
    final low = s.toLowerCase();
    return low != 'null' &&
        low != 'unknown' &&
        low != 'unknown patient' &&
        low != 'n/a' &&
        low != '-' &&
        low != '0' &&
        !low.startsWith('unknown_');
  }

  /// Checks whether [val] is a genuine, non-synthetic CNIC (not empty, not `-`, not `0000000000000`,
  /// and not a synthetic `unknown_<timestamp>` placeholder).
  static bool isValidCnicValue(dynamic val) {
    if (val == null) return false;
    final s = val.toString().trim();
    if (s.isEmpty) return false;
    final low = s.toLowerCase();
    if (low == 'null' ||
        low == 'unknown' ||
        low == 'n/a' ||
        low == '-' ||
        low == '0' ||
        low.startsWith('unknown')) {
      return false;
    }
    final digits = s.replaceAll(RegExp(r'[^0-9]'), '');
    if (digits.isEmpty || RegExp(r'^0+$').hasMatch(digits)) {
      return false;
    }
    return true;
  }

  /// Resolves the first genuine non-synthetic CNIC from a list of candidate values.
  static String resolveFirstValidCnic(Iterable<dynamic> candidates) {
    for (final c in candidates) {
      if (isValidCnicValue(c)) {
        return c.toString().trim();
      }
    }
    return '';
  }

  /// Resolves the first genuine patient name from a list of candidate values.
  static String resolveFirstValidPatientName(Iterable<dynamic> candidates) {
    for (final c in candidates) {
      if (isValidPatientNameValue(c)) {
        return c.toString().trim();
      }
    }
    return '';
  }

  /// Returns false when the serial already belongs to a different patient (A4 collision):
  /// the incoming record is kept under a -COLLISION- key and must not be synced as this serial.
  static Future<bool> saveEntryLocal(
      String branchId, String serial, Map<String, dynamic> entryData) async {
    final normBranch = branchId.toLowerCase().trim();
    var cleanSerial  = serial.trim();
    if (cleanSerial.toLowerCase().startsWith('$normBranch-')) {
      cleanSerial = cleanSerial.substring(normBranch.length + 1).trim();
    }
    final normSerialUpper = cleanSerial.toUpperCase();
    final canonicalKey    = '$normBranch-$normSerialUpper';
    var sanitized         = sanitize(entryData);
    final todayKey        = getTodayDateKey();
    sanitized['dateKey']  = sanitized['dateKey'] ?? todayKey;
    sanitized['branchId'] = normBranch;
    sanitized['serial']   = normSerialUpper;

    if (normSerialUpper.contains('-SADD-') || normSerialUpper.contains('-KAP-') || normSerialUpper.contains('-KAPAYYA-')) {
      sanitized['dispensaryId'] = 'saddar';
      sanitized['campId']       = 'saddar';
      sanitized['dispensaryTag'] = sanitized['dispensaryTag'] ?? 'SADD';
    } else if (normSerialUpper.contains('-HAJI-') || normSerialUpper.contains('-HAJ-') || normSerialUpper.contains('-HC-')) {
      sanitized['dispensaryId'] = 'haji_camp';
      sanitized['campId']       = 'haji_camp';
      sanitized['dispensaryTag'] = sanitized['dispensaryTag'] ?? 'HAJI';
    } else {
      // Dynamic future-proof camp detection for any configured camp in any branch
      bool matchedConfiguredCamp = false;
      try {
        final branchCamps = CampSessionService.getCampsForBranch(normBranch, includeClosed: true);
        for (final c in branchCamps) {
          final cId = (c['id'] ?? '').toString().trim().toLowerCase();
          if (cId.isEmpty) continue;
          final cTag = CampSessionService.getDispensaryKeyword(cId, branchId: normBranch).toUpperCase();
          if (cTag.isNotEmpty && normSerialUpper.contains('-$cTag-')) {
            sanitized['dispensaryId'] ??= cId;
            sanitized['campId']       ??= cId;
            sanitized['dispensaryTag'] ??= cTag;
            matchedConfiguredCamp = true;
            break;
          }
        }
      } catch (_) {}
      if (!matchedConfiguredCamp) {
        final activeCamp = CampSessionService.getActiveCamp();
        if (activeCamp != null && activeCamp.isNotEmpty && activeCamp != 'all') {
          sanitized['dispensaryId'] = sanitized['dispensaryId'] ?? activeCamp;
          sanitized['campId']       = sanitized['campId']       ?? activeCamp;
        }
      }
    }

    // Check exact & variant keys in entriesBox to preserve original createdAt, session, and creator
    Map<String, dynamic>? existingExactMap;
    final legacyKeysToDelete = <dynamic>[];
    try {
      if (Hive.isBoxOpen(entriesBox)) {
        final box = Hive.box(entriesBox);
        final candidateKeys = [
          canonicalKey,
          '$normBranch-$cleanSerial',
          '$normBranch-${cleanSerial.toLowerCase()}',
          normSerialUpper,
          cleanSerial,
          cleanSerial.toLowerCase(),
        ];
        for (final ck in candidateKeys) {
          if (box.containsKey(ck)) {
            final raw = box.get(ck);
            if (raw is Map) {
              final exDate = (raw['dateKey'] ?? '').toString().trim();
              final inDate = (sanitized['dateKey'] ?? '').toString().trim();
              final exQueue = (raw['queueType'] ?? '').toString().trim().toLowerCase();
              final inQueue = (sanitized['queueType'] ?? '').toString().trim().toLowerCase();
              final isDifferentDayOrQueue = (exDate.isNotEmpty && inDate.isNotEmpty && exDate != inDate) ||
                  (exQueue.isNotEmpty && inQueue.isNotEmpty && exQueue != inQueue);
              if (isDifferentDayOrQueue) {
                if (ck == canonicalKey) {
                  // Archive previous day/queue bare-serial entry under its scoped key so it is preserved
                  final archiveKey = '$canonicalKey-${exDate.isNotEmpty ? exDate : 'prev'}-${exQueue.isNotEmpty ? exQueue : 'zakat'}';
                  await box.put(archiveKey, Map<String, dynamic>.from(raw));
                }
                continue;
              }
              existingExactMap ??= Map<String, dynamic>.from(raw);
            }
            if (ck != canonicalKey) {
              legacyKeysToDelete.add(ck);
            }
          }
        }
        // Also check matching branch/camp prefixes (e.g. 'haji_camp-...' vs 'karachi-...')
        // so Haji Camp / Saddar tokens never split into two competing entries in Hive!
        final suffixLower = '-${cleanSerial.toLowerCase()}';
        for (final k in box.keys) {
          if (k == canonicalKey || candidateKeys.contains(k)) continue;
          final kStr = k.toString().toLowerCase().trim();
          if (kStr.contains('-collision-')) continue;
          if (kStr.endsWith(suffixLower)) {
            final prefix = kStr.substring(0, kStr.length - suffixLower.length);
            if (CampSessionService.areBranchesMatching(prefix, normBranch)) {
              final raw = box.get(k);
              if (raw is Map) {
                existingExactMap ??= Map<String, dynamic>.from(raw);
                legacyKeysToDelete.add(k);
              }
            }
          }
        }
      }
    } catch (_) {}

    // If still missing, check dispensaryBox for existing patient details
    if (existingExactMap == null && Hive.isBoxOpen(dispensaryBox)) {
      try {
        final dBox = Hive.box(dispensaryBox);
        final curDateKey = sanitized['dateKey'] ?? todayKey;
        final dispCandidates = [
          '${normBranch}_${curDateKey}_$normSerialUpper',
          '${normBranch}_${curDateKey}_$cleanSerial',
          '$normBranch-$normSerialUpper',
          '$normBranch-$cleanSerial',
          normSerialUpper,
          cleanSerial,
        ];
        for (final dk in dispCandidates) {
          final dVal = dBox.get(dk);
          if (dVal is Map) {
            existingExactMap = Map<String, dynamic>.from(dVal);
            break;
          }
        }
      } catch (_) {}
    }

    // 1. Preserve original createdAt from existing entry
    if (existingExactMap != null) {
      final oldCreatedAt = existingExactMap['createdAt'];
      if (oldCreatedAt != null && oldCreatedAt.toString().isNotEmpty) {
        sanitized['createdAt'] = oldCreatedAt;
      }
    }

    // 2. Preserve original session from existing entry (e.g. morning patient must stay morning even when edited/synced in evening!)
    if (existingExactMap != null) {
      final oldSession = (existingExactMap['session'] ?? existingExactMap['shift'] ?? '').toString().trim().toLowerCase();
      if (oldSession.isNotEmpty && oldSession != 'unknown' && oldSession != 'all' && oldSession != 'auto') {
        sanitized['session'] = oldSession;
      }
    }

    // 3. Fallback to createdAt (token issue time) to determine session
    final currentSess = (sanitized['session'] ?? '').toString().trim().toLowerCase();
    if (currentSess.isEmpty || currentSess == 'unknown' || currentSess == 'all' || currentSess == 'auto') {
      final rawTime = sanitized['createdAt'] ?? sanitized['timestamp'] ?? sanitized['date'] ?? sanitized['time'];
      final dt = rawTime != null ? _toDateTime(rawTime) : DateTime.now();
      sanitized['session'] = CampSessionService.getCurrentSession(dt, normBranch);
    }

    const terminalStatuses = ['completed', 'dispensed', 'cancelled', 'rejected'];

    void preservePatientFields(Map existing) {
      // User Data Guard: Original token creator identity, issue timestamp, and dispensary/camp
      // must NEVER be overwritten by subsequent actions or sync from other users.
      for (final creatorField in [
        'createdBy', 'createdByName', 'receptionistId', 'receptionistName', 'tokenBy',
        'createdAt', 'dispensaryTag', 'dispensaryId', 'campId', 'campName', 'dispensaryName'
      ]) {
        final oldVal = existing[creatorField];
        if (oldVal != null && oldVal.toString().trim().isNotEmpty) {
          sanitized[creatorField] = oldVal;
        }
      }

      // ⚠️ PERMANENT ARCHITECTURAL RULE:
      // Receptionist patient identity (`patientName`, `name`, `fullName`, `patientCnic`, `cnic`, `guardianCnic`)
      // is authoritative truth and must NEVER be overwritten by the Doctor screen or subsequent updates.
      // Explicit correction path: Receptionist or Supervisor can fix a typo by passing
      // `allowIdentityOverride: true` or bumping `identityRevision`.
      final int inIdRev = intOf(sanitized['identityRevision']);
      final int exIdRev = intOf(existing['identityRevision']);
      final bool isExplicitIdentityEdit =
          sanitized['allowIdentityOverride'] == true || inIdRev > exIdRev;

      final existingBestName = resolveFirstValidPatientName([
        existing['patientName'],
        existing['name'],
        existing['fullName'],
      ]);
      final incomingBestName = resolveFirstValidPatientName([
        sanitized['patientName'],
        sanitized['name'],
        sanitized['fullName'],
      ]);
      final authoritativeName = isExplicitIdentityEdit
          ? (incomingBestName.isNotEmpty ? incomingBestName : existingBestName)
          : (existingBestName.isNotEmpty ? existingBestName : incomingBestName);
      if (authoritativeName.isNotEmpty) {
        sanitized['patientName'] = authoritativeName;
        sanitized['name'] = authoritativeName;
      }

      final existingBestCnic = resolveFirstValidCnic([
        existing['patientCnic'],
        existing['cnic'],
        existing['guardianCnic'],
      ]);
      final incomingBestCnic = resolveFirstValidCnic([
        sanitized['patientCnic'],
        sanitized['cnic'],
        sanitized['guardianCnic'],
      ]);
      final authoritativeCnic = isExplicitIdentityEdit
          ? (incomingBestCnic.isNotEmpty ? incomingBestCnic : existingBestCnic)
          : (existingBestCnic.isNotEmpty ? existingBestCnic : incomingBestCnic);
      if (authoritativeCnic.isNotEmpty) {
        sanitized['patientCnic'] = authoritativeCnic;
        sanitized['cnic'] = authoritativeCnic;
        if (!isExplicitIdentityEdit && isValidCnicValue(existing['guardianCnic'])) {
          sanitized['guardianCnic'] = existing['guardianCnic'];
        }
      }

      if (isExplicitIdentityEdit) {
        final int nextIdRev = inIdRev > exIdRev ? inIdRev : (exIdRev + 1);
        sanitized['identityRevision'] = nextIdRev;
        sanitized.remove('allowIdentityOverride');
        if (sanitized['prescription'] is Map) {
          final rxMap = Map<String, dynamic>.from(sanitized['prescription'] as Map);
          if (authoritativeName.isNotEmpty) {
            rxMap['patientName'] = authoritativeName;
            rxMap['name'] = authoritativeName;
          }
          if (authoritativeCnic.isNotEmpty) {
            rxMap['patientCnic'] = authoritativeCnic;
            rxMap['cnic'] = authoritativeCnic;
          }
          rxMap['identityRevision'] = nextIdRev;
          sanitized['prescription'] = rxMap;
        }
      } else if (exIdRev > inIdRev) {
        sanitized['identityRevision'] = exIdRev;
      }

      for (final field in [
        'patientName', 'name', 'fullName', 'patientCnic', 'cnic', 'guardianName',
        'guardianCnic', 'patientAge', 'age', 'patientGender', 'gender',
        'queueType', 'visitReason', 'isVitalsOnly', 'vitalsOnly',
        'suggestedDays', 'phone', 'contactPhone', 'address', 'dateKey', 'patientId'
      ]) {
        if (field == 'patientName' || field == 'name' || field == 'patientCnic' || field == 'cnic') {
          continue; // Already enforced with strict Receptionist immutability above
        }
        final curVal = sanitized[field];
        final oldVal = existing[field];
        final curStr = curVal?.toString().trim().toLowerCase() ?? '';
        final oldStr = oldVal?.toString().trim().toLowerCase() ?? '';
        final isCurEmpty = curVal == null ||
            curStr.isEmpty ||
            curStr == 'null' ||
            curStr == 'unknown' ||
            curStr == 'unknown patient' ||
            curStr == 'n/a' ||
            curStr == '-' ||
            curStr.startsWith('unknown_');
        final isOldValid = oldVal != null &&
            oldStr.isNotEmpty &&
            oldStr != 'null' &&
            oldStr != 'unknown' &&
            oldStr != 'unknown patient' &&
            oldStr != 'n/a' &&
            oldStr != '-' &&
            !oldStr.startsWith('unknown_');
        if (isCurEmpty && isOldValid) {
          sanitized[field] = oldVal;
        } else if (isOldValid && (field == 'fullName' || field == 'guardianCnic' || field == 'guardianName')) {
          sanitized[field] = oldVal;
        }
      }

      // Resolve patient name AND CNIC from local_patients if still missing or synthetic
      final pId = (sanitized['patientId'] ?? existing['patientId'] ?? sanitized['id'] ?? '').toString().trim();
      final isEntryAdult = sanitized['isAdult'] is bool
          ? sanitized['isAdult'] as bool
          : (!pId.contains('_child_') && (sanitized['guardianCnic']?.toString().trim().isEmpty ?? true));

      if (!isValidPatientNameValue(sanitized['patientName'])) {
        final pCnic = resolveFirstValidCnic([sanitized['patientCnic'], sanitized['cnic'], sanitized['guardianCnic']]);
        if (pId.isNotEmpty) {
          final lp = getLocalPatient(pId);
          final lpName = resolveFirstValidPatientName([lp?['name'], lp?['patientName'], lp?['fullName']]);
          if (lpName.isNotEmpty) {
            sanitized['patientName'] = lpName;
            sanitized['name'] = lpName;
          }
        }
        if (isEntryAdult && !isValidPatientNameValue(sanitized['patientName']) && pCnic.isNotEmpty) {
          final lp = getLocalPatientByCnic(pCnic);
          final lpName = resolveFirstValidPatientName([lp?['name'], lp?['patientName'], lp?['fullName']]);
          if (lpName.isNotEmpty) {
            sanitized['patientName'] = lpName;
            sanitized['name'] = lpName;
          }
        }
      }

      if (!isValidCnicValue(sanitized['patientCnic'])) {
        if (pId.isNotEmpty && !pId.toLowerCase().startsWith('unknown')) {
          final lp = getLocalPatient(pId);
          final lpCnic = resolveFirstValidCnic([
            lp?['cnic'],
            lp?['patientCnic'],
            lp?['guardianCnic'],
            pId.contains('_child_') ? pId.split('_child_').first : pId,
          ]);
          if (lpCnic.isNotEmpty) {
            sanitized['patientCnic'] = lpCnic;
            sanitized['cnic'] = lpCnic;
          }
        }
      }

      // Guarantee original session is NEVER overwritten from morning to evening
      final oldSess = (existing['session'] ?? existing['shift'] ?? '').toString().toLowerCase().trim();
      if (oldSess.isNotEmpty && oldSess != 'unknown' && oldSess != 'all' && oldSess != 'auto') {
        sanitized['session'] = oldSess;
      }
      if (existing['createdAt'] != null && existing['createdAt'].toString().isNotEmpty) {
        sanitized['createdAt'] = existing['createdAt'];
      }
    }

    // [A4] Serial Collision Guard
    // If an existing entry exists under this canonical serial, verify if it is the same patient transaction or a collision
    bool isCollision = false;
    final incomingUid = (sanitized['entryUid'] ?? '').toString().trim();
    final existingUid = (existingExactMap != null ? (existingExactMap['entryUid'] ?? '') : '').toString().trim();

    if (existingExactMap != null) {
      if (incomingUid.isNotEmpty && existingUid.isNotEmpty) {
        // Both records have immutable transaction UIDs
        if (incomingUid != existingUid) {
          isCollision = true;
        }
      } else {
        // Legacy fallback: compare normalized CNIC and patientId
        // IMPORTANT: Ignore synthetic 'unknown_<timestamp>' CNICs so their 13-digit epoch
        // timestamp is never mistaken for a real CNIC and never triggers a false collision!
        final rawExCnic = resolveFirstValidCnic([
          existingExactMap['patientCnic'],
          existingExactMap['cnic'],
          existingExactMap['guardianCnic'],
        ]);
        final rawInCnic = resolveFirstValidCnic([
          sanitized['patientCnic'],
          sanitized['cnic'],
          sanitized['guardianCnic'],
        ]);
        final exCnic = rawExCnic.replaceAll(RegExp(r'[^0-9]'), '');
        final inCnic = rawInCnic.replaceAll(RegExp(r'[^0-9]'), '');
        final exPid = (existingExactMap['patientId'] ?? '').toString().trim().toLowerCase();
        final inPid = (sanitized['patientId'] ?? '').toString().trim().toLowerCase();

        final hasDistinctCnic = (exCnic.length >= 5 && inCnic.length >= 5 && exCnic != inCnic);
        // A patientId mismatch alone is not proof of a different patient: the same token is
        // often carried with a placeholder id ("unknown_…") or as the guardian's id on one desk
        // and the child's id ("<guardian>_child_<name>") on another. Treating those as a
        // collision sent the real updates (prescribed, dispensed) to a hidden copy. It counts
        // only for two real, unrelated ids whose patient names also differ.
        bool placeholder(String p) => p.startsWith('unknown') || p == 'null' || p == '-';
        final exName = (existingExactMap['patientName'] ?? existingExactMap['name'] ?? '').toString().trim().toLowerCase();
        final inName = (sanitized['patientName'] ?? sanitized['name'] ?? '').toString().trim().toLowerCase();
        final namesDiffer = exName.isNotEmpty && inName.isNotEmpty && exName != inName;
        final related = exPid.startsWith(inPid) || inPid.startsWith(exPid);
        final hasDistinctPid = exPid.isNotEmpty && inPid.isNotEmpty && exPid != inPid &&
            !placeholder(exPid) && !placeholder(inPid) && !related && namesDiffer;

        if (hasDistinctCnic || hasDistinctPid) {
          isCollision = true;
        }
      }
    }

    if (isCollision && existingExactMap != null) {
      final safeUid = incomingUid.isNotEmpty ? incomingUid : 'COLL-${DateTime.now().millisecondsSinceEpoch}';
      sanitized['entryUid'] ??= safeUid;
      sanitized['hasCollision'] = true;
      sanitized['collisionSerial'] = normSerialUpper;
      sanitized['collisionDetectedAt'] = DateTime.now().toIso8601String();
      sanitized['supervisorReviewRequired'] = true;

      final collisionPutKey = '$normBranch-$normSerialUpper-COLLISION-$safeUid';
      // Ensure patientCnic and cnic are always synchronized and clean on initial save too
    final finalBestCnic = resolveFirstValidCnic([
      sanitized['patientCnic'],
      sanitized['cnic'],
      sanitized['guardianCnic'],
    ]);
    if (finalBestCnic.isNotEmpty) {
      sanitized['patientCnic'] = finalBestCnic;
      sanitized['cnic'] = finalBestCnic;
    }
    final finalBestName = resolveFirstValidPatientName([
      sanitized['patientName'],
      sanitized['name'],
      sanitized['fullName'],
    ]);
    if (finalBestName.isNotEmpty) {
      sanitized['patientName'] = finalBestName;
      sanitized['name'] = finalBestName;
    }

    final eBox = await ensureBoxOpen(entriesBox);
      await eBox.put(collisionPutKey, sanitized);

      // Flag the primary record as well so both are marked for supervisor review
      final updExisting = Map<String, dynamic>.from(existingExactMap);
      if (updExisting['hasCollision'] != true) {
        updExisting['hasCollision'] = true;
        updExisting['collisionWithUid'] = safeUid;
        updExisting['collisionSerial'] = normSerialUpper;
        updExisting['supervisorReviewRequired'] = true;
        await eBox.put(canonicalKey, updExisting);
      }

      debugPrint('[LocalStorageService] ⚠️ A4 SERIAL COLLISION DETECTED for serial $normSerialUpper. Preserved under $collisionPutKey');
      return false;
    }

    // 1. Check exact key in entriesBox and preserve terminal status, dispense status & patient info
    try {
      if (existingExactMap != null) {
        final existingExact = existingExactMap;
        preservePatientFields(existingExact);

        // CRITICAL: Preserve dispenseStatus so background Firestore/LAN token syncs never revert a dispensed patient back to waiting!
        final localDispStatus = (existingExact['dispenseStatus'] ?? '').toString().toLowerCase();
        final incomingDispStatus = (sanitized['dispenseStatus'] ?? '').toString().toLowerCase();
        if (localDispStatus.isNotEmpty && incomingDispStatus.isEmpty) {
          sanitized['dispenseStatus'] = existingExact['dispenseStatus'];
          sanitized['dispensedAt']    = existingExact['dispensedAt'] ?? sanitized['dispensedAt'];
          sanitized['dispensedBy']    = existingExact['dispensedBy'] ?? sanitized['dispensedBy'];
          sanitized['dispenserName']  = existingExact['dispenserName'] ?? sanitized['dispenserName'];
        }

        // If the incoming payload or existing record is dispensed, maintain dispense and completed status and preserve prescription
        if (incomingDispStatus == 'dispensed' || localDispStatus == 'dispensed') {
          sanitized['dispenseStatus'] = 'dispensed';
          sanitized['status'] = 'completed';
          sanitized['prescription'] = preferredPrescription(sanitized['prescription'], existingExact['prescription']);
          sanitized['prescriptionId'] = sanitized['prescriptionId'] ?? existingExact['prescriptionId'];
          sanitized['dispensedAt'] = sanitized['dispensedAt'] ?? existingExact['dispensedAt'];
          sanitized['dispensedBy'] = sanitized['dispensedBy'] ?? existingExact['dispensedBy'];
          sanitized['dispenserName'] = sanitized['dispenserName'] ?? existingExact['dispenserName'];
        }

        final localStatus    = (existingExact['status'] ?? '').toString().toLowerCase();
        final incomingStatus = (sanitized['status'] ?? '').toString().toLowerCase();

        // [A5] Status clobber & doctor edit protection
        final isIncomingCancellation = incomingStatus == 'cancelled' || incomingStatus == 'rejected';
        final isLocalTerminal = terminalStatuses.contains(localStatus);
        final isIncomingWaiting = incomingStatus.isEmpty || incomingStatus == 'waiting' || incomingStatus == 'pending';

        if (isIncomingCancellation) {
          // A dispensed patient cannot be cancelled afterwards by a late/replayed message.
          sanitized['status'] = (localDispStatus == 'dispensed') ? 'completed' : incomingStatus;
        } else if (isLocalTerminal && isIncomingWaiting) {
          sanitized['status']      = existingExact['status'] ?? 'completed';
          sanitized['completedAt'] = existingExact['completedAt'] ?? sanitized['completedAt'];
        } else if (_statusRank(incomingStatus) < _statusRank(localStatus) &&
            !_isNewerUpdate(sanitized, existingExact)) {
          // A token's status only moves forward (waiting → called → in consultation →
          // prescribed) unless the change is newer than what is stored (e.g. the doctor sent
          // the patient back to the queue). A late or replayed older copy used to undo
          // "in consultation", so a second doctor auto-selected the same patient.
          sanitized['status'] = existingExact['status'];
          if (existingExact['activeDoctor'] != null) {
            sanitized['activeDoctor'] = existingExact['activeDoctor'];
          }
        }

        // A whole token re-sent by another desk (reconnect push, catch-up) carries that desk's
        // copy of the prescription, which may be older or empty: it used to replace the
        // stored one unconditionally, so the dispenser saw "no medicines".
        sanitized['prescription']   = preferredPrescription(sanitized['prescription'], existingExact['prescription']);
        sanitized['prescriptionId'] = sanitized['prescriptionId'] ?? existingExact['prescriptionId'];
        _alignTopLevelMedicines(sanitized, existingExact);
        sanitized['vitals'] = mergeVitalsPreservingReceptionist(
          sanitized['vitals'],
          existingExact['vitals'],
        );
        sanitized['daysOfMedicine'] = sanitized['daysOfMedicine'] ?? existingExact['daysOfMedicine'];
        final inDoc = sanitized['doctorName']?.toString().trim();
        if (inDoc == null || inDoc.isEmpty || inDoc.toLowerCase() == 'unknown') {
          sanitized['doctorName'] = existingExact['doctorName'];
        }
        final inDocId = sanitized['doctorId']?.toString().trim();
        if (inDocId == null || inDocId.isEmpty) {
          sanitized['doctorId'] = existingExact['doctorId'];
        }
      }
    } catch (_) {}

    // Check dispensaryBox to ensure dispensed status is never lost
    try {
      if (Hive.isBoxOpen(dispensaryBox)) {
        final dBox = Hive.box(dispensaryBox);
        final dKey = sanitized['dateKey'] ?? todayKey;
        final dispRec = dBox.get('${normBranch}_${dKey}_$normSerialUpper') ??
            dBox.get('$normBranch-$normSerialUpper') ??
            dBox.get(normSerialUpper);
        if (dispRec is Map) {
          final dStatus = (dispRec['dispenseStatus'] ?? dispRec['status'] ?? '').toString().toLowerCase();
          if (dStatus == 'dispensed' || dStatus == 'completed') {
            sanitized['dispenseStatus'] = 'dispensed';
            sanitized['dispensedAt']    = dispRec['dispensedAt'] ?? sanitized['dispensedAt'];
            sanitized['dispensedBy']    = dispRec['dispensedBy'] ?? sanitized['dispensedBy'];
            sanitized['dispenserName']  = dispRec['dispenserName'] ?? sanitized['dispenserName'];
          }
        }
      }
    } catch (_) {}

    // 2. Check if a local prescription already exists in prescriptionsBox for this exact token scope
    try {
      if (Hive.isBoxOpen(prescriptionsBox)) {
        final matchedRx = getLocalPrescription(
          normSerialUpper,
          branchId: normBranch,
          dateKey: sanitized['dateKey']?.toString(),
          cnic: (sanitized['patientCnic'] ?? sanitized['cnic'])?.toString(),
          patientName: (sanitized['patientName'] ?? sanitized['name'])?.toString(),
          patientId: sanitized['patientId']?.toString(),
          queueType: sanitized['queueType']?.toString(),
          campId: (sanitized['campId'] ?? sanitized['dispensaryId'])?.toString(),
        );
        if (matchedRx != null && _isSamePrescriptionScope(sanitized, matchedRx)) {
          final existingPrescription = Map<String, dynamic>.from(matchedRx);
          preservePatientFields(existingPrescription);
          sanitized['status']         = 'completed';
          // The stored record wins only when it is not older and not emptier than the token's.
          sanitized['prescription']   = preferredPrescription(sanitized['prescription'], existingPrescription);
          sanitized['prescriptionId'] = existingPrescription['id'] ?? normSerialUpper;
          _alignTopLevelMedicines(sanitized, null);
          if (existingPrescription['completedAt'] != null && sanitized['completedAt'] == null) {
            sanitized['completedAt'] = existingPrescription['completedAt'];
          }
          if (existingPrescription['doctorName'] != null && sanitized['doctorName'] == null) {
            sanitized['doctorName'] = existingPrescription['doctorName'];
          }
          if (existingPrescription['doctorId'] != null && sanitized['doctorId'] == null) {
            sanitized['doctorId'] = existingPrescription['doctorId'];
          }
          if (existingPrescription['daysOfMedicine'] != null && sanitized['daysOfMedicine'] == null) {
            sanitized['daysOfMedicine'] = existingPrescription['daysOfMedicine'];
          }
        }
      }
    } catch (_) {}

    // Echo prevention rule: lanPushSig is ONLY stamped on data arriving from the LAN server.
    // Any local save/edit that did not explicitly pass lanPushSig must strip any stale lanPushSig
    // so SyncService will push the updated record to the LAN server.
    if (entryData['lanPushSig'] == null) {
      sanitized.remove('lanPushSig');
    }

    // Ensure patientCnic and cnic are always synchronized and clean on initial save too
    final finalBestCnic = resolveFirstValidCnic([
      sanitized['patientCnic'],
      sanitized['cnic'],
      sanitized['guardianCnic'],
    ]);
    if (finalBestCnic.isNotEmpty) {
      sanitized['patientCnic'] = finalBestCnic;
      sanitized['cnic'] = finalBestCnic;
    }
    final finalBestName = resolveFirstValidPatientName([
      sanitized['patientName'],
      sanitized['name'],
      sanitized['fullName'],
    ]);
    if (finalBestName.isNotEmpty) {
      sanitized['patientName'] = finalBestName;
      sanitized['name'] = finalBestName;
    }

    final eBox = await ensureBoxOpen(entriesBox);
    // Nothing changed (LAN catch-ups and cloud pulls re-deliver the same tokens all day): skip
    // the write. Every write wakes all screens watching this box, which re-scan it — that
    // was a big part of the constant CPU load.
    if (legacyKeysToDelete.isEmpty) {
      final stored = eBox.get(canonicalKey);
      if (stored is Map && const DeepCollectionEquality().equals(stored, sanitized)) return true;
    }
    await eBox.put(canonicalKey, sanitized);

    // Prune any legacy keys so that this token never appears duplicate times
    for (final oldKey in legacyKeysToDelete) {
      if (oldKey.toString().contains('-COLLISION-')) continue;
      try {
        await eBox.delete(oldKey);
      } catch (_) {}
    }
    await eBox.flush();
    invalidateLocalEntriesCache();
    return true;
  }

  static final Map<String, _LocalEntriesCacheEntry> _localEntriesCache = {};

  static void invalidateLocalEntriesCache() {
    _localEntriesCache.clear();
  }

  static List<Map<String, dynamic>> getLocalEntries(String branchId,
      {String? dispensaryId, bool filterByCamp = false, String? session, bool filterBySession = false}) {
    if (!Hive.isBoxOpen(entriesBox)) return [];
    
    final normBranch = branchId.toLowerCase().trim();
    final box = Hive.box(entriesBox);
    _watchEntriesForCache(box);
    // The result only changes when the entries box changes (the watch above clears the
    // cache) or when the camp/session used for filtering changes (part of the key). It was
    // cached for 450 ms only, so the receptionist, doctor and token screens re-scanned every
    // token on almost every rebuild — several full scans per second on busy days.
    final campForKey = filterByCamp && (dispensaryId == null || dispensaryId.trim().isEmpty)
        ? CampSessionService.getActiveCamp(branchId)
        : dispensaryId;
    final sessionForKey = filterBySession && (session == null || session.trim().isEmpty)
        ? CampSessionService.getCurrentSession()
        : session;
    final cacheKey = '$normBranch|${campForKey ?? ''}|$filterByCamp|${sessionForKey ?? ''}|$filterBySession|${getTodayDateKey()}';
    final now = DateTime.now();
    final cached = _localEntriesCache[cacheKey];
    if (cached != null && now.difference(cached.timestamp) < const Duration(minutes: 2)) {
      return List.of(cached.entries);
    }

    final Map<String, Map<String, dynamic>> deduped = {};
    // Index entries are shared between calls; a duplicate is merged into a copy, never in place.
    final merged = <String>{};
    for (final kv in _branchEntriesFor(box, normBranch).entries) {
      final be = kv.value;
      var cleanS = be.serialKey;
      if (cleanS.isEmpty) continue;
      // A "-COLLISION-" record is a DIFFERENT patient who got the same number (two desks
      // numbering offline). Merged as a duplicate it vanished from every queue — and its
      // dispensed status could be copied onto the other patient. It is kept as its own row
      // (flagged hasCollision / supervisorReviewRequired for the screens).
      final hiveKey = kv.key.toString();
      final collAt = hiveKey.indexOf('-COLLISION-');
      if (collAt >= 0) cleanS = '$cleanS#${hiveKey.substring(collAt + 1)}';
      final e = be.entry;
      final existing = deduped[cleanS];
      if (existing == null) {
        deduped[cleanS] = e;
        continue;
      }
      final eSt = (e['status'] ?? '').toString().toLowerCase();
      final exSt = (existing['status'] ?? '').toString().toLowerCase();
      final eDisp = (e['dispenseStatus'] ?? '').toString().toLowerCase();
      final exDisp = (existing['dispenseStatus'] ?? '').toString().toLowerCase();
      final completed = eSt == 'completed' || exSt == 'completed';
      final dispensed = eDisp == 'dispensed' || exDisp == 'dispensed';
      final target = merged.add(cleanS) ? (deduped[cleanS] = Map<String, dynamic>.of(existing)) : existing;

      // Always preserve non-empty receptionist/patient fields & vitals across duplicate branch/camp keys
      // (e.g. 'haji_camp-...' sorting before 'karachi-...' must NEVER drop receptionist vitals or patientName!)
      target['vitals'] = mergeVitalsPreservingReceptionist(target['vitals'], e['vitals']);
      final bestMergedCnic = resolveFirstValidCnic([
        target['patientCnic'],
        target['cnic'],
        target['guardianCnic'],
        e['patientCnic'],
        e['cnic'],
        e['guardianCnic'],
      ]);
      if (bestMergedCnic.isNotEmpty) {
        target['patientCnic'] = bestMergedCnic;
        target['cnic'] = bestMergedCnic;
      }
      final bestMergedName = resolveFirstValidPatientName([
        target['patientName'],
        target['name'],
        target['fullName'],
        e['patientName'],
        e['name'],
        e['fullName'],
      ]);
      if (bestMergedName.isNotEmpty) {
        target['patientName'] = bestMergedName;
        target['name'] = bestMergedName;
      }
      for (final f in const [
        'patientName', 'name', 'fullName', 'patientCnic', 'cnic', 'guardianCnic', 'guardianName',
        'patientId', 'age', 'patientAge', 'gender', 'patientGender', 'phone', 'contactPhone',
        'createdBy', 'createdByName', 'receptionistId', 'receptionistName', 'tokenBy',
        'campId', 'dispensaryId', 'dispensaryTag', 'campName', 'queueType', 'visitReason',
        'isVitalsOnly', 'vitalsOnly', 'suggestedDays', 'dateKey', 'session', 'createdAt',
      ]) {
        if (f == 'patientName' || f == 'name' || f == 'patientCnic' || f == 'cnic') continue;
        final curVal = target[f];
        final altVal = e[f];
        final curStr = curVal?.toString().trim().toLowerCase() ?? '';
        final altStr = altVal?.toString().trim().toLowerCase() ?? '';
        final isCurEmpty = curVal == null || curStr.isEmpty || curStr == 'null' || curStr == 'unknown' || curStr == 'unknown patient' || curStr == 'n/a' || curStr == '-' || curStr == '0' || curStr.startsWith('unknown_');
        final isAltValid = altVal != null && altStr.isNotEmpty && altStr != 'null' && altStr != 'unknown' && altStr != 'unknown patient' && altStr != 'n/a' && altStr != '-' && altStr != '0' && !altStr.startsWith('unknown_');
        if (isCurEmpty && isAltValid) {
          target[f] = altVal;
        }
      }

      if (completed) {
        target['status'] = 'completed';
        final inRx = e['prescription'];
        if (inRx is Map && inRx.isNotEmpty) {
          // Same rule as every other writer (preferredPrescription): by the doctor's updatedAt,
          // never a copy without medicines over one with. Comparing completedAt first let a
          // duplicate with the original completedAt win over the doctor's later edit.
          target['prescription'] = preferredPrescription(inRx, target['prescription']);
        } else {
          target['prescription'] ??= e['prescription'];
        }
        _alignTopLevelMedicines(target, e);
      }
      if (dispensed) {
        target['dispenseStatus'] = 'dispensed';
        target['status'] = 'completed';
      }
    }
    var list = deduped.values.toList();

    if (filterByCamp) {
      final activeCamp = (dispensaryId != null && dispensaryId.trim().isNotEmpty)
          ? dispensaryId.trim().toLowerCase()
          : CampSessionService.getActiveCamp(branchId);

      if (activeCamp != null && activeCamp.isNotEmpty && activeCamp != 'all') {
        list = list.where((entry) {
          return CampSessionService.matchesCamp(
            selectedCamp: activeCamp,
            dispensaryId: entry['dispensaryId']?.toString(),
            campId: entry['campId']?.toString(),
            dispensaryTag: entry['dispensaryTag']?.toString(),
            serial: (entry['serial'] ?? entry['id'])?.toString(),
          );
        }).toList();
      }
    }

    if (filterBySession) {
      final targetSession = (session != null && session.trim().isNotEmpty)
          ? session.trim().toLowerCase()
          : CampSessionService.getCurrentSession();

      if (targetSession != 'all') {
        list = list.where((entry) {
          final s = entry['session']?.toString().toLowerCase().trim();
          if (s != null && s.isNotEmpty && s != 'unknown' && s != 'auto') {
            return s == targetSession;
          }
          final rawTime = entry['createdAt'] ?? entry['time'] ?? entry['timestamp'] ?? entry['date'];
          if (rawTime != null) {
            final dt = _toDateTime(rawTime);
            return CampSessionService.getCurrentSession(dt) == targetSession;
          }
          return true;
        }).toList();
      }
    }

    if (_localEntriesCache.length >= 20) {
      _localEntriesCache.remove(_localEntriesCache.keys.first);
    }
    _localEntriesCache[cacheKey] = _LocalEntriesCacheEntry(now, list);
    return List.of(list);
  }

  static Box? _watchedEntriesBox;
  static StreamSubscription<BoxEvent>? _entriesWatchSub;

  /// Per branch, the entries-box records that belong to it, in box key order. getLocalEntries
  /// used to rebuild its result from a scan of the whole token history after every write to
  /// the box; while tokens arrive over the LAN that is several full scans a second on the UI
  /// thread, which on Windows is also the window's thread ("Not Responding"). The index is
  /// built once and then updated one key at a time from the box's change events.
  static final Map<String, Map<dynamic, _BranchEntry>> _branchEntries = {};
  static final Map<String, DateTime> _branchEntriesBuiltAt = {};

  /// Rebuilt now and then anyway, in case branch/camp settings changed since it was built.
  static const Duration _branchEntriesMaxAge = Duration(minutes: 15);

  /// Hive's own key order (ints first, then strings), so results keep the order a box scan had.
  static int _hiveKeyOrder(dynamic a, dynamic b) {
    if (a is int) return b is int ? a.compareTo(b) : -1;
    if (b is int) return 1;
    return a.toString().compareTo(b.toString());
  }

  static bool _isSingleBranchKey(String normBranch) =>
      normBranch.isNotEmpty && normBranch != 'all' && normBranch != 'global';

  /// Whether the entry stored under [kStr] (lower-cased key) belongs to [normBranch].
  /// Future-proofed across all branches and dynamically configured camps via `CampSessionService.areBranchesMatching`.
  static bool _entryInBranch(String kStr, Map val, String normBranch, bool isKarachi) {
    if (!_isSingleBranchKey(normBranch)) return true;

    // Keys of another branch (or camp prefix belonging to this branch)
    final dashIdx = kStr.indexOf('-');
    if (dashIdx > 0) {
      final prefix = kStr.substring(0, dashIdx);
      final isDateSegment = RegExp(r'^\d{6}[a-z]?$').hasMatch(prefix);
      if (!isDateSegment && prefix.length > 2) {
        if (!CampSessionService.areBranchesMatching(prefix, normBranch)) {
          return false;
        }
      }
    }

    final entryBranch = (val['branchId'] ?? '').toString().toLowerCase().trim();
    final rawSerial = (val['serial'] ?? val['id'] ?? '').toString().toLowerCase().trim();
    if (entryBranch.isNotEmpty) {
      return entryBranch == normBranch || CampSessionService.areBranchesMatching(entryBranch, normBranch);
    }
    if (kStr.startsWith('$normBranch-') || rawSerial.startsWith('$normBranch-')) return true;
    return isKarachi;
  }

  static Map<dynamic, _BranchEntry> _branchEntriesFor(Box box, String normBranch) {
    final index = _branchEntries[normBranch];
    final builtAt = _branchEntriesBuiltAt[normBranch];
    if (index != null && builtAt != null && DateTime.now().difference(builtAt) < _branchEntriesMaxAge) {
      return index;
    }
    UiStallMonitor.mark('entries index: $normBranch');
    final isKarachi = CampSessionService.isKarachiFamily(normBranch);
    final fresh = <dynamic, _BranchEntry>{};
    final keys = box.keys.toList()..sort(_hiveKeyOrder);
    for (final k in keys) {
      final val = box.get(k);
      if (val is! Map) continue;
      if (!_entryInBranch(k.toString().toLowerCase().trim(), val, normBranch, isKarachi)) continue;
      fresh[k] = _BranchEntry.of(val, normBranch);
    }
    _branchEntries[normBranch] = fresh;
    _branchEntriesBuiltAt[normBranch] = DateTime.now();
    return fresh;
  }

  static void _onEntriesChanged(BoxEvent event) {
    _localEntriesCache.clear();
    if (_branchEntries.isEmpty) return;
    final key = event.key;
    final val = event.deleted ? null : event.value;
    final kStr = key.toString().toLowerCase().trim();
    _branchEntries.forEach((normBranch, index) {
      if (val is Map && _entryInBranch(kStr, val, normBranch, CampSessionService.isKarachiFamily(normBranch))) {
        index[key] = _BranchEntry.of(val, normBranch);
      } else {
        index.remove(key);
      }
    });
  }

  /// Keeps the getLocalEntries cache and branch index in step with every change to the
  /// entries box (any writer).
  static void _watchEntriesForCache(Box box) {
    if (identical(_watchedEntriesBox, box)) return;
    _entriesWatchSub?.cancel();
    _watchedEntriesBox = box;
    _localEntriesCache.clear();
    _branchEntries.clear();
    _branchEntriesBuiltAt.clear();
    _entriesWatchSub = box.watch().listen(_onEntriesChanged);
  }

  /// Self-healing utility: Fixes any in-flight tokens whose session was mistakenly overwritten on restart/sync
  static Future<void> repairMisassignedShiftSessions([String? branchId, bool force = false]) async {
    try {
      if (!Hive.isBoxOpen(entriesBox)) return;
      if (!force) {
        if (!Hive.isBoxOpen('app_flags')) await openBoxSafe('app_flags');
        final flags = Hive.box('app_flags');
        final last = flags.get('last_shift_session_repair_ts') as String?;
        if (last != null) {
          final dt = DateTime.tryParse(last);
          if (dt != null && DateTime.now().difference(dt).inHours < 6) return;
        }
        await flags.put('last_shift_session_repair_ts', DateTime.now().toIso8601String());
      }

      final box = Hive.box(entriesBox);
      int processed = 0;
      for (final k in box.keys.toList()) {
        processed++;
        if (processed % 25 == 0) {
          await Future.delayed(const Duration(milliseconds: 1));
        }

        final val = box.get(k);
        if (val is! Map) continue;

        // Never touch finalized records — only in-flight waiting/pending tokens should be re-classified.
        final status = (val['status'] ?? '').toString().toLowerCase().trim();
        final hasPrescription = (val['prescriptionId'] as String?)?.isNotEmpty == true ||
            (val['prescription'] is Map && (val['prescription'] as Map).isNotEmpty);
        final isDispensed = (val['dispenseStatus'] ?? '').toString().toLowerCase().trim() == 'dispensed';
        if (hasPrescription || isDispensed || !(status.isEmpty || status == 'waiting' || status == 'pending')) {
          continue;
        }

        final rawCreated = val['createdAt'] ?? val['time'] ?? val['timestamp'] ?? val['date'];
        if (rawCreated == null) continue;

        final dt = _toDateTime(rawCreated);
        final currentSess = (val['session'] ?? val['shift'] ?? '').toString().toLowerCase().trim();
        final bId = (val['branchId'] ?? branchId ?? '').toString();
        final correctSess = CampSessionService.getCurrentSession(dt, bId);
        if (correctSess.isNotEmpty && currentSess != correctSess) {
          final copy = Map<String, dynamic>.from(val);
          copy['session'] = correctSess;
          await box.put(k, copy);

          final serial = (copy['serial'] ?? copy['id'] ?? '').toString().trim();
          if (bId.isNotEmpty && serial.isNotEmpty) {
            await enqueueSync({
              'type': 'save_entry',
              'branchId': bId,
              'serial': serial,
              'data': sanitize(copy),
            });
          }

          debugPrint('[LocalStorageService] 🩹 Repaired session from $currentSess to $correctSess for $k');
        }
      }
    } catch (_) {}
  }

  /// Comprehensively heals legacy historical data (attendance, patients, entries, prescriptions)
  /// so that old data matches new schemas, lookups never fail, and Firestore sync quota is protected.
  static Future<void> healLegacyHistoricalData({bool force = false}) async {
    try {
      if (!force) {
        if (!Hive.isBoxOpen('app_flags')) await openBoxSafe('app_flags');
        final flags = Hive.box('app_flags');
        final last = flags.get('last_legacy_data_heal_ts') as String?;
        if (last != null) {
          final dt = DateTime.tryParse(last);
          if (dt != null && DateTime.now().difference(dt).inHours < 6) return;
        }
        await flags.put('last_legacy_data_heal_ts', DateTime.now().toIso8601String());
      }

      debugPrint('[LocalStorageService] 🩹 Starting healLegacyHistoricalData...');

      // ── 0. Repair Patient Identity & History Isolation ──────────────────────
      try {
        await repairPatientIdentityCorruption();
      } catch (e) {
        debugPrint('[LocalStorageService] repairPatientIdentityCorruption error: $e');
      }

      // ── 1. Heal Legacy Attendance Records ─────────────────────────────────────
      // Each part runs only where this PC's role uses the box (roleUsesBox).
      if (!Hive.isBoxOpen(attendanceBox) && roleUsesBox(attendanceBox)) await openBoxSafe(attendanceBox);
      if (Hive.isBoxOpen(attendanceBox)) {
        final aBox = Hive.box(attendanceBox);
        final now = DateTime.now();
        int attendanceHealed = 0;
        final flags = Hive.isBoxOpen('app_flags') ? Hive.box('app_flags') : null;

        for (final k in aBox.keys.toList()) {
          final val = aBox.get(k);
          if (val is! Map) continue;
          final map = Map<String, dynamic>.from(val);

          final rawDate = map['date'] ?? map['timestamp'] ?? map['punchTime'] ?? map['createdAt'];
          final dt = _toDateTime(rawDate);
          final isOld = now.difference(dt).inHours > 48;
          final isAlreadySynced = map['syncStatus'] == 'synced' || map['synced'] == true;

          // If attendance is old (>48h) or was marked synced, make sure both flags are set
          if (isOld || isAlreadySynced) {
            bool changed = false;
            if (map['syncStatus'] != 'synced') {
              map['syncStatus'] = 'synced';
              changed = true;
            }
            if (map['synced'] != true) {
              map['synced'] = true;
              changed = true;
            }
            if (changed) {
              await aBox.put(k, map);
              attendanceHealed++;
            }

            final empId = (map['employeeId'] ?? map['empId'] ?? map['userId'] ?? '').toString().trim();
            final dateStr = (map['date'] ?? (dt.year > 2000 ? DateFormat('yyyy-MM-dd').format(dt) : '')).toString().trim();
            if (flags != null) {
              await flags.put('attendance_synced_$k', true);
              if (empId.isNotEmpty && dateStr.isNotEmpty) {
                await flags.put('attendance_synced_${empId}_$dateStr', true);
              }
            }
          }
        }
        if (attendanceHealed > 0) {
          debugPrint('[LocalStorageService] 🩹 Healed $attendanceHealed legacy attendance records to synced status.');
        }
      }

      // ── 2. Heal Legacy Patients ────────────────────────────────────────────────
      if (!Hive.isBoxOpen(patientsBox) && roleUsesBox(patientsBox)) await openBoxSafe(patientsBox);
      if (Hive.isBoxOpen(patientsBox)) {
        final pBox = Hive.box(patientsBox);
        final flags = Hive.isBoxOpen('app_flags') ? Hive.box('app_flags') : null;
        int patientsHealed = 0;

        for (final k in pBox.keys.toList()) {
          final val = pBox.get(k);
          if (val is! Map) continue;
          final map = Map<String, dynamic>.from(val);

          final bool isPendingSync = map['pendingSync'] == true;
          final bool hasIdentity = map['id'] != null || map['mrNo'] != null || map['firestoreId'] != null;

          if (!isPendingSync && hasIdentity) {
            bool changed = false;
            if (map['syncStatus'] != 'synced') {
              map['syncStatus'] = 'synced';
              changed = true;
            }
            if (map['synced'] != true) {
              map['synced'] = true;
              changed = true;
            }
            if (changed) {
              await pBox.put(k, map);
              patientsHealed++;
            }
            if (flags != null) {
              await flags.put('patient_synced_$k', true);
              final cnic = (map['cnic'] ?? map['patientCnic'] ?? '').toString().replaceAll(RegExp(r'[^0-9]'), '');
              if (cnic.isNotEmpty) {
                await flags.put('patient_synced_$cnic', true);
              }
            }
          }
        }
        if (patientsHealed > 0) {
          debugPrint('[LocalStorageService] 🩹 Healed $patientsHealed legacy patients to synced status.');
        }
      }

      // ── 3. Heal Legacy Entries / Tokens ────────────────────────────────────────
      if (!Hive.isBoxOpen(entriesBox) && roleUsesBox(entriesBox)) await openBoxSafe(entriesBox);
      if (Hive.isBoxOpen(entriesBox)) {
        final eBox = Hive.box(entriesBox);
        final now = DateTime.now();
        int entriesHealed = 0;

        for (final k in eBox.keys.toList()) {
          final val = eBox.get(k);
          if (val is! Map) continue;
          final map = Map<String, dynamic>.from(val);
          final serial = (map['serial'] ?? map['id'] ?? '').toString().trim();
          if (serial.isEmpty) continue;

          bool changed = false;

          // 3a. Ensure dateKey matches 6-digit standard
          final currentDk = (map['dateKey'] ?? '').toString().trim();
          final serialDk = CampSessionService.getDateKeyFromSerial(serial);
          if (serialDk.isNotEmpty && currentDk != serialDk) {
            map['dateKey'] = serialDk;
            changed = true;
          }

          // 3b. Ensure sessionLetter is present and matches session
          var currentSess = (map['session'] ?? map['shift'] ?? '').toString().toLowerCase().trim();
          if (currentSess.isEmpty) {
            final rawCreated = map['createdAt'] ?? map['time'] ?? map['timestamp'] ?? map['date'];
            if (rawCreated != null) {
              final dt = _toDateTime(rawCreated);
              final bId = (map['branchId'] ?? '').toString();
              currentSess = CampSessionService.getCurrentSession(dt, bId);
              if (currentSess.isNotEmpty) {
                map['session'] = currentSess;
                changed = true;
              }
            }
          }
          final expectedLetter = CampSessionService.getSessionLetter(currentSess.isNotEmpty ? currentSess : 'morning');
          final currentLetter = (map['sessionLetter'] ?? '').toString().trim().toUpperCase();
          if (currentLetter != expectedLetter) {
            map['sessionLetter'] = expectedLetter;
            changed = true;
          }

          // 3c. If older than 48 hours or completed, ensure it does not sit un-synced
          final rawCreated = map['createdAt'] ?? map['time'] ?? map['timestamp'] ?? map['date'];
          final dt = rawCreated != null ? _toDateTime(rawCreated) : null;
          final isOld = dt != null && now.difference(dt).inHours > 48;
          final isCompleted = (map['status'] ?? '').toString().toLowerCase() == 'completed' ||
              (map['dispenseStatus'] ?? '').toString().toLowerCase() == 'dispensed';
          final bool isThisMonth = isCurrentMonth(map['dateKey']) || isCurrentMonth(rawCreated) || isCurrentMonth(serial);

          if (!isThisMonth && (isOld || isCompleted) && map['pendingSync'] != true) {
            if (map['syncStatus'] != 'synced') {
              map['syncStatus'] = 'synced';
              changed = true;
            }
            if (map['synced'] != true) {
              map['synced'] = true;
              changed = true;
            }
          }

          // 3d. Check for unsynced tokens (today, yesterday, past dates) that were never queued for cloud sync
          // All tokens upload normally to their own dates in serials
          final bId = (map['branchId'] ?? '').toString().trim().toLowerCase();
          final alreadySynced = (map['synced'] == true || map['syncStatus'] == 'synced') && map['pendingSync'] != true;
          final todayKey = getTodayDateKey();
          final serialDateKey = CampSessionService.getDateKeyFromSerial(serial);

          if (!alreadySynced && bId.isNotEmpty && !isStressTestRecord(map, serial)) {
            // Only enqueue if NOT connected to LAN server as client (Gateway rule)
            final bool isClientOnLan = !LanServer.isRunning && !LanHostManager.isHostRunning && RealtimeManager().hasServerLink;
            if (!isClientOnLan) {
              final syncKey = 'sync_serial_${bId}_${serial.toUpperCase()}';
              if (Hive.isBoxOpen(syncBox)) {
                final sBox = Hive.box(syncBox);
                if (!sBox.containsKey(syncKey)) {
                  final queueType = (map['queueType'] ?? map['category'] ?? 'zakat').toString().toLowerCase();
                  final entryDateKey = serialDateKey.isNotEmpty ? serialDateKey : (map['dateKey'] ?? todayKey).toString();
                  await enqueueSync({
                    'type': 'save_entry',
                    'branchId': bId,
                    'dateKey': entryDateKey,
                    'queueType': queueType,
                    'serial': serial,
                    'data': map,
                  });
                  map['pendingSync'] = true;
                  changed = true;
                }
              }
            }
          }

          if (changed) {
            await eBox.put(k, map);
            entriesHealed++;
          }
        }
        if (entriesHealed > 0) {
          debugPrint('[LocalStorageService] 🩹 Healed $entriesHealed legacy entries/tokens schema fields.');
        }
      }

      // ── 4. Heal Legacy Prescriptions ──────────────────────────────────────────
      if (!Hive.isBoxOpen(prescriptionsBox) && roleUsesBox(prescriptionsBox)) await openBoxSafe(prescriptionsBox);
      if (Hive.isBoxOpen(prescriptionsBox)) {
        final prBox = Hive.box(prescriptionsBox);
        int prescHealed = 0;
        final now = DateTime.now();

        for (final k in prBox.keys.toList()) {
          final val = prBox.get(k);
          if (val is! Map) continue;
          final map = Map<String, dynamic>.from(val);
          final serial = (map['serial'] ?? map['id'] ?? '').toString().trim();
          bool changed = false;

          final currentDk = (map['dateKey'] ?? '').toString().trim();
          final serialDk = CampSessionService.getDateKeyFromSerial(serial.isNotEmpty ? serial : k.toString());
          if (serialDk.isNotEmpty && currentDk != serialDk) {
            map['dateKey'] = serialDk;
            changed = true;
          }

          final rawCreated = map['createdAt'] ?? map['time'] ?? map['timestamp'] ?? map['date'];
          final dt = rawCreated != null ? _toDateTime(rawCreated) : null;
          final isOld = dt != null && now.difference(dt).inHours > 48;
          if (isOld && map['syncStatus'] != 'synced') {
            map['syncStatus'] = 'synced';
            map['synced'] = true;
            changed = true;
          }

          if (changed) {
            await prBox.put(k, map);
            prescHealed++;
          }
        }
        if (prescHealed > 0) {
          debugPrint('[LocalStorageService] 🩹 Healed $prescHealed legacy prescriptions schema fields.');
        }
      }

      debugPrint('[LocalStorageService] ✅ healLegacyHistoricalData completed successfully.');
    } catch (e, st) {
      debugPrint('[LocalStorageService] ❌ healLegacyHistoricalData error: $e\n$st');
    }
  }

  /// Whether a record whose serial has no session letter (issued by v1.6.1, shared by every
  /// session that day) says it belongs to the session [letter]. Without a `session` /
  /// `sessionLetter` field it is not trusted for a lettered lookup.
  static bool isLetterlessRecordInSession(Map data, String letter) {
    final explicit = (data['sessionLetter'] ?? '').toString().trim().toUpperCase();
    if (explicit.isNotEmpty) return explicit == letter.toUpperCase();
    final session = (data['session'] ?? '').toString().trim();
    if (session.isEmpty) return false;
    return CampSessionService.getSessionLetter(session) == letter.toUpperCase();
  }

  static Map<String, dynamic>? getLocalEntry(
      String branchId, String serial) {
    if (!Hive.isBoxOpen(entriesBox)) return null;
    final normBranch = branchId.toLowerCase().trim();
    final normSerial = serial.trim();
    // (replaceFirst would insert a literal "$1"; the group needs replaceFirstMapped.)
    final legacySerial = normSerial.replaceFirstMapped(RegExp(r'^(\d{6})[A-Za-z]-'), (m) => '${m[1]}-');
    final myLetter = CampSessionService.getSessionLetterFromSerial(normSerial);

    // A serial with a session letter (181026E-SADD-005) only ever matches its own session,
    // never the morning token with the same number. A letterless serial (issued by v1.6.1,
    // shared by every session that day) is used only when the record says it belongs to the
    // same session.
    final variants = <String>{normSerial, legacySerial};

    Map<String, dynamic>? accept(Object? val, String matched) {
      if (val is! Map) return null;
      final data = Map<String, dynamic>.from(val);
      if (myLetter != null &&
          matched.toUpperCase() != normSerial.toUpperCase() &&
          !isLetterlessRecordInSession(data, myLetter)) {
        return null;
      }
      return data;
    }

    final box = Hive.box(entriesBox);
    for (final v in variants) {
      final hit = accept(
          box.get('$normBranch-$v') ??
              box.get('$normBranch-${v.toUpperCase()}') ??
              box.get(v) ??
              box.get(v.toUpperCase()),
          v);
      if (hit != null) return hit;
    }

    final targetUpperSet = variants.map((v) => v.toUpperCase()).toSet();
    for (final k in box.keys) {
      final kStr = k.toString();
      final kLower = kStr.toLowerCase();
      String sub = kStr.toUpperCase();
      if (kLower.startsWith('$normBranch-')) {
        sub = kStr.substring(normBranch.length + 1).toUpperCase();
      } else {
        for (final vUpper in targetUpperSet) {
          if (kStr.toUpperCase().endsWith('-$vUpper')) {
            final prefix = kStr.substring(0, kStr.length - vUpper.length - 1);
            if (CampSessionService.areBranchesMatching(prefix, normBranch)) {
              sub = vUpper;
              break;
            }
          }
        }
      }
      if (targetUpperSet.contains(sub)) {
        final hit = accept(box.get(k), sub);
        if (hit != null) return hit;
      }
    }
    return null;
  }

  static Future<void> updateLocalEntryField(
      String branchId, String serial, Map<String, dynamic> fields) async {
    final normBranch = branchId.toLowerCase().trim();
    var cleanSerial = serial.trim();
    if (cleanSerial.toLowerCase().startsWith('$normBranch-')) {
      cleanSerial = cleanSerial.substring(normBranch.length + 1).trim();
    }
    final normSerialUpper = cleanSerial.toUpperCase();
    final canonicalKey = '$normBranch-$normSerialUpper';
    final entryUid = fields['entryUid']?.toString().trim();
    final box = Hive.box(entriesBox);
    dynamic targetKey = canonicalKey;
    var raw = box.get(canonicalKey);

    // [A4] Look up by entryUid first if present to match the exact collision entry
    if (entryUid != null && entryUid.isNotEmpty) {
      for (final k in box.keys) {
        final item = box.get(k);
        if (item is Map && item['entryUid']?.toString().trim() == entryUid) {
          targetKey = k;
          raw = item;
          break;
        }
      }
    }

    if (raw == null) {
      for (final k in box.keys) {
        final kStr = k.toString().trim();
        final kLower = kStr.toLowerCase();
        if (kStr == canonicalKey ||
            kLower == canonicalKey.toLowerCase() ||
            kLower == cleanSerial.toLowerCase() ||
            kStr == normSerialUpper ||
            kLower.endsWith('-$normSerialUpper'.toLowerCase())) {
          targetKey = k;
          raw = box.get(k);
          break;
        }
      }
    }
    if (raw == null) return;
    final updated = Map<String, dynamic>.from(raw as Map);
    final sanitizedFields = sanitize(fields);

    // User Data Guard: Do not let creator identity be overwritten
    for (final cf in ['createdBy', 'createdByName', 'receptionistId', 'receptionistName', 'tokenBy']) {
      if (sanitizedFields.containsKey(cf) && (sanitizedFields[cf] == null || sanitizedFields[cf].toString().isEmpty)) {
        sanitizedFields.remove(cf);
      }
    }

    updated.addAll(sanitizedFields);
    final putKey = targetKey ?? canonicalKey;
    await box.put(putKey, updated);
    if (targetKey != canonicalKey && !targetKey.toString().contains('-COLLISION-')) {
      try {
        await box.delete(targetKey);
      } catch (_) {}
    }
  }

  static Future<bool> deleteLocalEntry(String branchId, String tokenSerial) async {
    try {
      final box = Hive.box(entriesBox);
      if (!box.isOpen) return false;
      final normBranch = branchId.toLowerCase().trim();
      final targetUpper = tokenSerial.trim().toUpperCase();
      final legacyUpper = targetUpper.replaceFirst(RegExp(r'^(\d{6})[A-Za-z]-'), r'$1-');
      final targetSet = {targetUpper, legacyUpper};
      final keys = box.keys.toList();
      bool deleted = false;
      for (final key in keys) {
        final kStr = key.toString().trim();
        final kStrUpper = kStr.toUpperCase();
        final entry = box.get(key);
        if (entry == null) continue;
        final serial = (entry['serial'] ?? entry['id'] ?? '').toString().trim().toUpperCase();
        final entryBranch = (entry['branchId'] ?? '').toString().trim().toLowerCase();
        final isBranchMatch = normBranch.isEmpty || entryBranch.isEmpty || entryBranch == normBranch ||
            normBranch.contains(entryBranch) || entryBranch.contains(normBranch) ||
            normBranch == 'all' || entryBranch == 'all';

        final isKeyMatch = targetSet.contains(kStrUpper) ||
            targetSet.any((t) => kStrUpper == '$normBranch-$t'.toUpperCase() || kStrUpper.endsWith('-$t') || serial == t);

        if (isKeyMatch && isBranchMatch) {
          await box.delete(key);
          debugPrint('[LocalStorage] ✅ Deleted $tokenSerial (key: $key)');
          deleted = true;
        }
      }
      await box.flush();
      invalidateLocalEntriesCache();
      return deleted;
    } catch (e) {
      debugPrint('[LocalStorage] ❌ deleteLocalEntry error: $e');
      return false;
    }
  }

  static Future<void> remapTempSerialToCanonical(
    String branchId,
    String oldTempSerial,
    String canonicalSerial,
    Map<String, dynamic> canonicalData,
  ) async {
    final box = Hive.box(entriesBox);
    final normBranch = branchId.toLowerCase().trim();
    final oldTempUpper = oldTempSerial.trim().toUpperCase();

    for (final k in box.keys.toList()) {
      final kStr = k.toString();
      if (kStr.toLowerCase().startsWith('$normBranch-') &&
          kStr.toUpperCase().contains(oldTempUpper)) {
        await box.delete(k);
      }
    }

    final newKey = '$normBranch-${canonicalSerial.trim()}';
    final merged = Map<String, dynamic>.from(canonicalData);
    merged['serial'] = canonicalSerial;
    merged['originalTempSerial'] = oldTempSerial;
    merged['renumberedOnSync'] = true;
    merged.remove('pendingSync');

    await box.put(newKey, sanitize(merged));
    await box.flush();
    debugPrint('[LocalStorage] Remapped temp serial $oldTempSerial → canonical $canonicalSerial');
  }

  static Future<void> sanitizeLocalEntriesCasingAndUnknowns(String branchId) async {
    try {
      if (Hive.isBoxOpen('app_flags')) {
        final flags = Hive.box('app_flags');
        if (flags.get('entries_casing_sanitized_v2') == true) return;
      }
      if (!Hive.isBoxOpen(entriesBox)) return;
      final box = Hive.box(entriesBox);
      final normBranch = branchId.toLowerCase().trim();
      final keys = box.keys.where((k) => k.toString().toLowerCase().startsWith('$normBranch-')).toList();

      final Map<String, List<dynamic>> serialToKeys = {};
      for (final key in keys) {
        final val = box.get(key);
        if (val is! Map) continue;
        final serial = (val['serial'] ?? key.toString().replaceFirst(RegExp('^$normBranch-', caseSensitive: false), '')).toString().trim().toUpperCase();
        if (serial.isEmpty) continue;
        serialToKeys.putIfAbsent(serial, () => []).add(key);
      }

      for (final entry in serialToKeys.entries) {
        final keyList = entry.value;
        if (keyList.length > 1) {
          dynamic bestKey = keyList.first;
          Map<String, dynamic>? bestData;

          for (final k in keyList) {
            final data = Map<String, dynamic>.from(box.get(k) as Map);
            final name = (data['patientName'] ?? data['name'] ?? '').toString().trim().toLowerCase();
            final isUnknown = name.isEmpty || name == 'unknown patient' || name == 'unknown';

            if (bestData == null) {
              bestData = data;
              bestKey = k;
            } else {
              final bestName = (bestData['patientName'] ?? bestData['name'] ?? '').toString().trim().toLowerCase();
              final bestIsUnknown = bestName.isEmpty || bestName == 'unknown patient' || bestName == 'unknown';

              if (bestIsUnknown && !isUnknown) {
                bestData = data;
                bestKey = k;
              }
            }
          }

          for (final k in keyList) {
            if (k != bestKey) {
              await box.delete(k);
              debugPrint('[LocalStorage] Cleaned up duplicate casing/unknown key: $k');
            }
          }
        }
      }
      await box.flush();
      if (Hive.isBoxOpen('app_flags')) {
        await Hive.box('app_flags').put('entries_casing_sanitized_v2', true);
      }
    } catch (e) {
      debugPrint('[LocalStorage] Error in sanitizeLocalEntriesCasingAndUnknowns: $e');
    }
  }

  /// Safely eliminates phantom "Unknown Patient" entries generated by historical migrations or missing CNICs,
  /// preserving all genuine registered patients and resetting the next serial counter.
  static Future<int> purgePhantomUnknownTokens([String? branchId, bool force = false]) async {
    if (!force) {
      try {
        if (!Hive.isBoxOpen('app_flags')) await openBoxSafe('app_flags');
        final flags = Hive.box('app_flags');
        final lastStr = flags.get('last_purge_phantom_tokens_ts') as String?;
        if (lastStr != null) {
          final lastDt = DateTime.tryParse(lastStr);
          if (lastDt != null && DateTime.now().difference(lastDt).inHours < 12) {
            return 0; // Cooldown: run once per 12 hours max unless forced
          }
        }
        await flags.put('last_purge_phantom_tokens_ts', DateTime.now().toIso8601String());
      } catch (_) {}
    }

    int purged = 0;
    try {
      if (!Hive.isBoxOpen(entriesBox)) await openBoxSafe(entriesBox);
      final eBox = Hive.box(entriesBox);
      final today = getTodayDateKey();
      final keysToDelete = <dynamic>[];

      for (final key in eBox.keys) {
        final val = eBox.get(key);
        if (val is! Map) continue;
        final entry = Map<String, dynamic>.from(val);
        final dk = (entry['dateKey'] ?? '').toString().trim();
        final serial = (entry['serial'] ?? entry['id'] ?? '').toString().trim();
        final serialDk = CampSessionService.getDateKeyFromSerial(serial);
        final isToday = (dk == today || dk.startsWith(today) || serialDk == today || serialDk.startsWith(today));
        if (!isToday) continue;

        final cnic = firstRealValue([entry['patientCnic'], entry['cnic'], entry['guardianCnic']]);
        // Any real name counts: patientName 'Unknown' next to a real 'name' is a real token.
        final isUnknownName = firstRealValue([entry['patientName'], entry['name'], entry['fullName']]).isEmpty;
        final isSyntheticCnic = cnic.startsWith('unknown_cnic_') || cnic.isEmpty;
        // A token anyone has worked on (vitals, doctor, dispense) or that links to a patient
        // is real even without a name or CNIC (walk-ins without a CNIC exist).
        final status = (entry['status'] ?? '').toString().toLowerCase();
        final hasWork = (status.isNotEmpty && status != 'waiting') ||
            entry['prescription'] != null ||
            entry['medicines'] != null ||
            (entry['vitals'] is Map && (entry['vitals'] as Map).isNotEmpty) ||
            !isPlaceholderValue(entry['patientId']) ||
            entry['dispenseStatus'] == 'dispensed';

        if (isUnknownName && isSyntheticCnic && !hasWork) {
          keysToDelete.add(key);
        }
      }

      for (final k in keysToDelete) {
        await eBox.delete(k);
        purged++;
      }

      if (Hive.isBoxOpen(syncBox)) {
        final sBox = Hive.box(syncBox);
        final syncKeysToDelete = <dynamic>[];
        for (final sk in sBox.keys) {
          final sVal = sBox.get(sk);
          if (sVal is Map && isPhantomQueuedEntry(sVal)) {
            syncKeysToDelete.add(sk);
          }
        }
        for (final sk in syncKeysToDelete) {
          await sBox.delete(sk);
        }
        if (syncKeysToDelete.isNotEmpty) await sBox.flush();
      }

      if (purged > 0) {
        await eBox.flush();
        invalidateLocalEntriesCache();
        debugPrint('[LocalStorage] 🧹 Purged $purged phantom unknown tokens for today');

        final targetBranch = (branchId ?? CampSessionService.getActiveCamp() ?? 'karachi').toLowerCase().trim();
        final activeCamp = CampSessionService.getActiveCamp(targetBranch);
        var dispTag = CampSessionService.getDispensaryKeyword(activeCamp);
        final tagsToReset = <String>{if (dispTag.isNotEmpty) dispTag};
        for (final raw in eBox.values) {
          if (raw is Map) {
            final tag = (raw['dispensaryTag'] ?? '').toString().toUpperCase().trim();
            if (tag.isNotEmpty && tag != 'ALL') tagsToReset.add(tag);
            final parts = (raw['serial'] ?? '').toString().split('-');
            if (parts.length >= 3 && parts[1].isNotEmpty) tagsToReset.add(parts[1].toUpperCase().trim());
          }
        }
        if (Hive.isBoxOpen('app_settings')) {
          final counterBox = Hive.box('app_settings');
          int maxSeq = 0;
          for (final raw in eBox.values) {
            if (raw is! Map) continue;
            final m = Map<String, dynamic>.from(raw);
            final sDk = (m['dateKey'] ?? '').toString().trim();
            final s = (m['serial'] ?? '').toString().trim();
            if (sDk == today || s.startsWith(today)) {
              final seq = parseSequenceFromSerial(s);
              if (seq < 9999 && seq > maxSeq) {
                maxSeq = seq;
              }
            }
          }
          for (final t in tagsToReset) {
            final counterKey = 'counter_${targetBranch}_${today}_$t';
            // Never move the counter backwards: purged serials may already exist on the
            // server/Firestore (with prescriptions), and re-issuing them hands the old
            // record to a new patient.
            final current = (counterBox.get(counterKey) as num?)?.toInt() ?? 0;
            if (maxSeq > current) await counterBox.put(counterKey, maxSeq);
          }
          debugPrint('[LocalStorage] 🔢 Reset next serial counter to: $maxSeq across ${tagsToReset.toList()}');
        }
      }

      // Automatically reconnect & heal genuine CNICs for registered patients if phantoms were purged
      if (purged > 0) {
        await healAndRestorePatientCnics(branchId, true);
      }
    } catch (e) {
      debugPrint('[LocalStorage] Error in purgePhantomUnknownTokens: $e');
    }
    return purged;
  }

  /// Merges historical/unlinked prescriptions from `prescriptionsBox` and
  /// dispense records from `dispensaryBox` directly into the unified `entriesBox`.
  static Future<int> unifyAndMergeAllLocalSerials([String? branchId]) async {
    int unifiedCount = 0;
    try {
      if (Hive.isBoxOpen('app_flags')) {
        final flags = Hive.box('app_flags');
        if (flags.get('serials_unified_v2') == true) return 0;
      }
      if (!Hive.isBoxOpen(entriesBox)) await openBoxSafe(entriesBox);
      if (!Hive.isBoxOpen(prescriptionsBox)) await openBoxSafe(prescriptionsBox);
      if (!Hive.isBoxOpen(dispensaryBox)) await openBoxSafe(dispensaryBox);

      final eBox = Hive.box(entriesBox);
      final pBox = Hive.box(prescriptionsBox);
      final dBox = Hive.box(dispensaryBox);

      final normBranch = branchId?.toLowerCase().trim();
      final isAllBranches = normBranch == null || normBranch.isEmpty || normBranch == 'default' || normBranch == 'all';

      // Index pBox keys and payloads by normalized serial and branch-scoped serial
      final Map<String, List<dynamic>> pKeysBySerial = {};
      final Map<String, Map<String, dynamic>> pDataBySerial = {};
      for (final pk in pBox.keys) {
        final pv = pBox.get(pk);
        if (pv == null || pv is! Map) continue;
        final pMap = Map<String, dynamic>.from(pv);
        final s = (pMap['serial'] ?? pMap['id'] ?? pk.toString().split('_').last).toString().trim().toUpperCase();
        if (s.isEmpty) continue;

        final pBranch = (pMap['branchId'] ?? (pk.toString().contains('_') ? pk.toString().split('_').first : '')).toString().toLowerCase().trim();
        if (pBranch.isNotEmpty) {
          final scoped = '${pBranch}_$s';
          pKeysBySerial.putIfAbsent(scoped, () => []).add(pk);
          pDataBySerial[scoped] = pMap;
        }
        pKeysBySerial.putIfAbsent(s, () => []).add(pk);
        pDataBySerial.putIfAbsent(s, () => pMap);
      }

      // Index dBox keys and payloads by normalized serial and branch-scoped serial
      final Map<String, List<dynamic>> dKeysBySerial = {};
      final Map<String, Map<String, dynamic>> dDataBySerial = {};
      for (final dk in dBox.keys) {
        final dv = dBox.get(dk);
        if (dv == null || dv is! Map) continue;
        final dMap = Map<String, dynamic>.from(dv);
        final s = (dMap['serial'] ?? dMap['id'] ?? dk.toString().split('_').last).toString().trim().toUpperCase();
        if (s.isEmpty) continue;

        final dBranch = (dMap['branchId'] ?? (dk.toString().contains('_') ? dk.toString().split('_').first : '')).toString().toLowerCase().trim();
        if (dBranch.isNotEmpty) {
          final scoped = '${dBranch}_$s';
          dKeysBySerial.putIfAbsent(scoped, () => []).add(dk);
          dDataBySerial[scoped] = dMap;
        }
        dKeysBySerial.putIfAbsent(s, () => []).add(dk);
        dDataBySerial.putIfAbsent(s, () => dMap);
      }

      // PASS 1: Iterate over existing entriesBox entries, strictly matching each to its own branch
      for (final ek in eBox.keys.toList()) {
        final ev = eBox.get(ek);
        if (ev == null || ev is! Map) continue;
        final entry = Map<String, dynamic>.from(ev);
        final serial = (entry['serial'] ?? entry['id'] ?? '').toString().trim();
        if (serial.isEmpty) continue;
        final upperSerial = serial.toUpperCase();

        String bId = (entry['branchId'] ?? '').toString().toLowerCase().trim();
        if (bId.isEmpty && ek.toString().contains('-')) {
          bId = ek.toString().split('-').first.toLowerCase().trim();
        }
        if (!isAllBranches && bId.isNotEmpty && bId != normBranch) {
          continue;
        }

        // Branch-scoped matching: look up exact branch first, fallback to bare serial only if unscoped
        final prescMap = (bId.isNotEmpty ? pDataBySerial['${bId}_$upperSerial'] : null) ?? pDataBySerial[upperSerial];
        final dispMap = (bId.isNotEmpty ? dDataBySerial['${bId}_$upperSerial'] : null) ?? dDataBySerial[upperSerial];

        bool modified = false;

        // Merge prescription data
        if (prescMap != null) {
          final prescObj = prescMap['prescription'] is Map
              ? Map<String, dynamic>.from(prescMap['prescription'] as Map)
              : Map<String, dynamic>.from(prescMap);

          entry['status'] = 'completed';
          entry['prescription'] = prescObj;
          entry['prescriptionId'] ??= prescMap['id'] ?? prescObj['id'] ?? serial;
          entry['completedAt'] ??= prescMap['completedAt'] ?? prescObj['completedAt'] ?? entry['completedAt'] ?? DateTime.now().toIso8601String();
          final pDispStatus = (prescObj['dispenseStatus'] ?? prescMap['dispenseStatus'] ?? '').toString().toLowerCase();
          if (pDispStatus == 'dispensed') {
            entry['dispenseStatus'] = 'dispensed';
          }

          final docName = prescObj['doctorName'] ?? prescObj['prescribedBy'] ?? prescMap['doctorName'] ?? prescMap['prescribedBy'];
          if (docName != null && entry['doctorName'] == null) {
            entry['doctorName'] = docName;
            entry['prescribedBy'] ??= docName;
          }
          final docId = prescObj['doctorId'] ?? prescMap['doctorId'];
          if (docId != null && entry['doctorId'] == null) entry['doctorId'] = docId;

          final diag = prescObj['diagnosis'] ?? prescMap['diagnosis'];
          if (diag != null && entry['diagnosis'] == null) entry['diagnosis'] = diag;

          final comp = prescObj['complaint'] ?? prescObj['condition'] ?? prescMap['complaint'] ?? prescMap['condition'];
          if (comp != null && entry['complaint'] == null) {
            entry['complaint'] = comp;
            entry['condition'] ??= comp;
          }

          final days = prescObj['daysOfMedicine'] ?? prescMap['daysOfMedicine'];
          if (days != null && entry['daysOfMedicine'] == null) entry['daysOfMedicine'] = days;

          final vitals = prescObj['vitals'] ?? prescMap['vitals'];
          if (vitals != null && entry['vitals'] == null) entry['vitals'] = vitals;

          final pMeds = prescObj['prescriptions'] ?? prescObj['medicines'] ?? prescMap['prescriptions'] ?? prescMap['medicines'];
          if (pMeds != null && entry['medicines'] == null) {
            entry['medicines'] = pMeds;
            entry['prescriptions'] ??= pMeds;
          }

          final lab = prescObj['labResults'] ?? prescMap['labResults'];
          if (lab != null && entry['labResults'] == null) entry['labResults'] = lab;

          final extra = prescObj['extraCharge'] ?? prescMap['extraCharge'];
          if (extra != null && entry['extraCharge'] == null) entry['extraCharge'] = extra;

          modified = true;
        }

        // Merge dispensary data
        if (dispMap != null) {
          final dStatus = (dispMap['dispenseStatus'] ?? dispMap['status'] ?? '').toString().toLowerCase();
          if (dStatus == 'dispensed' || dStatus == 'completed') {
            entry['dispenseStatus'] = 'dispensed';
            entry['status'] = 'completed';
          } else if (entry['dispenseStatus'] == null) {
            entry['dispenseStatus'] = 'pending';
          }

          if (dispMap['dispensedAt'] != null && entry['dispensedAt'] == null) entry['dispensedAt'] = dispMap['dispensedAt'];
          if (dispMap['dispensedBy'] != null && entry['dispensedBy'] == null) entry['dispensedBy'] = dispMap['dispensedBy'];
          if (dispMap['dispenserName'] != null && entry['dispenserName'] == null) entry['dispenserName'] = dispMap['dispenserName'];
          if (dispMap['charges'] != null && entry['charges'] == null) entry['charges'] = dispMap['charges'];
          if (dispMap['receivedAmount'] != null && entry['receivedAmount'] == null) entry['receivedAmount'] = dispMap['receivedAmount'];
          if (dispMap['extraCharge'] != null && entry['extraCharge'] == null) entry['extraCharge'] = dispMap['extraCharge'];
          if (dispMap['daysOfMedicine'] != null && entry['daysOfMedicine'] == null) entry['daysOfMedicine'] = dispMap['daysOfMedicine'];
          if (dispMap['medicines'] != null && entry['medicines'] == null) {
            entry['medicines'] = dispMap['medicines'];
            entry['prescriptions'] ??= dispMap['medicines'];
          }
          if (entry['prescription'] == null && (dispMap['prescription'] != null || dispMap['medicines'] != null)) {
            entry['prescription'] = dispMap['prescription'] ?? {'medicines': dispMap['medicines']};
          }

          modified = true;
        }

        // Demographics fallback
        if (entry['patientName'] == null || entry['patientName'] == 'Unknown Patient') {
          final pName = prescMap?['patientName'] ?? prescMap?['name'] ?? dispMap?['patientName'] ?? dispMap?['name'];
          if (pName != null && pName.toString().isNotEmpty && pName.toString().toLowerCase() != 'unknown patient') {
            entry['patientName'] = pName.toString();
            entry['name'] = pName.toString();
            modified = true;
          }
        }

        final targetBranch = bId.isNotEmpty
            ? bId
            : (prescMap?['branchId'] ?? dispMap?['branchId'] ?? (normBranch != null && !isAllBranches ? normBranch : (getLocalBranchesList().isNotEmpty ? (getLocalBranchesList().first['id'] ?? 'default') : 'default'))).toString().toLowerCase().trim();
        final targetDateKey = (entry['dateKey'] ?? prescMap?['dateKey'] ?? dispMap?['dateKey'] ?? '').toString();
        final targetQueue = SyncService().resolveQueueType((entry['queueType'] ?? prescMap?['queueType'] ?? dispMap?['queueType'] ?? 'zakat').toString());

        entry['serial'] = serial;
        entry['id'] = serial;
        entry['branchId'] = targetBranch;
        if (targetDateKey.isNotEmpty) entry['dateKey'] = targetDateKey;
        entry['queueType'] = targetQueue;

        if (modified) {
          final sanitized = sanitize(entry);
          final cKey = '${targetBranch.toLowerCase()}-$serial';
          await eBox.put(cKey, sanitized);
          await eBox.put(upperSerial, sanitized);
          await eBox.put(serial.toLowerCase(), sanitized);

          await enqueueSync({
            'type': 'save_entry',
            'branchId': targetBranch,
            'serial': serial,
            'dateKey': targetDateKey,
            'queueType': targetQueue,
            'data': sanitized,
          });
          unifiedCount++;
        }

        // Delete redundant prescription keys for this serial & branch
        final pKeys = <dynamic>{
          ...?pKeysBySerial['${targetBranch}_$upperSerial'],
          ...?pKeysBySerial[upperSerial],
        };
        for (final pk in pKeys) {
          await pBox.delete(pk);
        }
        if (pKeys.isNotEmpty) {
          final pCnic = (entry['patientCnic'] ?? entry['cnic'] ?? entry['patientId'] ?? prescMap?['patientCnic'] ?? prescMap?['cnic'] ?? '').toString().trim();
          await enqueueSync({
            'type': 'delete_prescription',
            'branchId': targetBranch,
            if (pCnic.isNotEmpty) 'patientCnic': pCnic,
            'serial': serial,
          });
        }
        pKeysBySerial.remove('${targetBranch}_$upperSerial');
        pKeysBySerial.remove(upperSerial);
        pDataBySerial.remove('${targetBranch}_$upperSerial');
        pDataBySerial.remove(upperSerial);

        // Delete redundant dispensary keys for this serial & branch
        final dKeys = <dynamic>{
          ...?dKeysBySerial['${targetBranch}_$upperSerial'],
          ...?dKeysBySerial[upperSerial],
        };
        for (final dk in dKeys) {
          await dBox.delete(dk);
        }
        if (dKeys.isNotEmpty) {
          await enqueueSync({
            'type': 'delete_dispensary',
            'branchId': targetBranch,
            'dateKey': targetDateKey,
            'serial': serial,
          });
        }
        dKeysBySerial.remove('${targetBranch}_$upperSerial');
        dKeysBySerial.remove(upperSerial);
        dDataBySerial.remove('${targetBranch}_$upperSerial');
        dDataBySerial.remove(upperSerial);
      }

      // PASS 2: Reconcile any remaining orphaned prescriptions or dispensary items in their own respective branches
      final remainingKeys = <String>{...pDataBySerial.keys, ...dDataBySerial.keys};
      for (final rKey in remainingKeys) {
        final prescMap = pDataBySerial[rKey];
        final dispMap = dDataBySerial[rKey];
        if (prescMap == null && dispMap == null) continue;

        final serial = prescMap?['serial'] ?? dispMap?['serial'] ?? (rKey.contains('_') ? rKey.split('_').last : rKey);
        final upperSerial = serial.toString().trim().toUpperCase();

        final targetBranch = (prescMap?['branchId'] ?? dispMap?['branchId'] ?? (rKey.contains('_') ? rKey.split('_').first : (normBranch != null && !isAllBranches ? normBranch : (getLocalBranchesList().isNotEmpty ? (getLocalBranchesList().first['id'] ?? 'default') : 'default')))).toString().toLowerCase().trim();
        final targetDateKey = (prescMap?['dateKey'] ?? dispMap?['dateKey'] ?? '').toString();
        final targetQueue = SyncService().resolveQueueType((prescMap?['queueType'] ?? dispMap?['queueType'] ?? 'zakat').toString());
        final patientName = (prescMap?['patientName'] ?? prescMap?['name'] ?? dispMap?['patientName'] ?? dispMap?['name'] ?? 'Unknown Patient').toString();
        var cnic = (prescMap?['cnic'] ?? prescMap?['patientCnic'] ?? dispMap?['cnic'] ?? dispMap?['patientCnic'] ?? '').toString();
        var pId = (prescMap?['patientId'] ?? dispMap?['patientId'] ?? cnic).toString();

        if ((cnic.isEmpty || cnic.startsWith('unknown_cnic_') || cnic == '00000-0000000-0') &&
            patientName.isNotEmpty && patientName.toLowerCase() != 'unknown patient') {
          final matched = findPatientByName(patientName);
          if (matched != null) {
            final realC = (matched['cnic'] ?? matched['guardianCnic'] ?? matched['patientCnic'])?.toString().trim();
            if (realC != null && realC.isNotEmpty && !realC.startsWith('unknown_')) {
              cnic = realC;
              pId = (matched['id'] ?? matched['patientId'] ?? realC).toString();
            }
          }
        }

        // [GUARD] Never synthesize phantom entries into entriesBox for empty/unknown orphan records
        final isUnknownName = patientName.isEmpty || patientName.toLowerCase() == 'unknown patient' || patientName.toLowerCase() == 'unknown';
        final isSyntheticCnic = cnic.isEmpty || cnic.startsWith('unknown_cnic_');
        if (isUnknownName && isSyntheticCnic) {
          continue;
        }

        final prescObj = prescMap != null
            ? (prescMap['prescription'] is Map
                ? Map<String, dynamic>.from(prescMap['prescription'] as Map)
                : Map<String, dynamic>.from(prescMap))
            : null;

        final hasDispense = dispMap != null && ((dispMap['dispenseStatus'] ?? dispMap['status'] ?? '').toString().toLowerCase() == 'dispensed');

        final reconstructed = <String, dynamic>{
          'serial': serial,
          'id': serial,
          'branchId': targetBranch,
          'dateKey': targetDateKey,
          'queueType': targetQueue,
          'patientName': patientName,
          'name': patientName,
          'cnic': cnic,
          'patientId': pId,
          'status': 'completed',
          'dispenseStatus': hasDispense ? 'dispensed' : 'pending',
          'createdAt': prescMap?['createdAt'] ?? dispMap?['createdAt'] ?? DateTime.now().toIso8601String(),
          'completedAt': prescMap?['completedAt'] ?? dispMap?['completedAt'] ?? DateTime.now().toIso8601String(),
          if (prescObj != null) 'prescription': prescObj,
          if (prescObj?['medicines'] != null || prescObj?['prescriptions'] != null || dispMap?['medicines'] != null)
            'medicines': prescObj?['prescriptions'] ?? prescObj?['medicines'] ?? dispMap?['medicines'],
          if (prescObj?['doctorName'] != null || prescMap?['doctorName'] != null)
            'doctorName': prescObj?['doctorName'] ?? prescMap?['doctorName'],
          if (prescObj?['doctorId'] != null || prescMap?['doctorId'] != null)
            'doctorId': prescObj?['doctorId'] ?? prescMap?['doctorId'],
          if (prescObj?['diagnosis'] != null || prescMap?['diagnosis'] != null)
            'diagnosis': prescObj?['diagnosis'] ?? prescMap?['diagnosis'],
          if (prescObj?['complaint'] != null || prescMap?['complaint'] != null)
            'complaint': prescObj?['complaint'] ?? prescMap?['complaint'],
          if (prescObj?['daysOfMedicine'] != null || dispMap?['daysOfMedicine'] != null)
            'daysOfMedicine': prescObj?['daysOfMedicine'] ?? dispMap?['daysOfMedicine'],
          if (prescObj?['vitals'] != null || dispMap?['vitals'] != null)
            'vitals': prescObj?['vitals'] ?? dispMap?['vitals'],
          if (dispMap?['charges'] != null) 'charges': dispMap?['charges'],
          if (dispMap?['receivedAmount'] != null) 'receivedAmount': dispMap?['receivedAmount'],
          if (dispMap?['dispensedAt'] != null) 'dispensedAt': dispMap?['dispensedAt'],
          if (dispMap?['dispensedBy'] != null) 'dispensedBy': dispMap?['dispensedBy'],
          if (dispMap?['dispenserName'] != null) 'dispenserName': dispMap?['dispenserName'],
        };

        final sanitized = sanitize(reconstructed);
        final cKey = '${targetBranch.toLowerCase()}-$serial';
        await eBox.put(cKey, sanitized);
        await eBox.put(upperSerial, sanitized);
        await eBox.put(serial.toString().toLowerCase(), sanitized);

        await enqueueSync({
          'type': 'save_entry',
          'branchId': targetBranch,
          'serial': serial,
          'dateKey': targetDateKey,
          'queueType': targetQueue,
          'data': sanitized,
        });
        unifiedCount++;

        // Delete redundant pBox keys
        final pKeys = <dynamic>{
          ...?pKeysBySerial[rKey],
          ...?pKeysBySerial[upperSerial],
        };
        for (final pk in pKeys) {
          await pBox.delete(pk);
        }
        if (pKeys.isNotEmpty) {
          await enqueueSync({
            'type': 'delete_prescription',
            'branchId': targetBranch,
            if (cnic.isNotEmpty) 'patientCnic': cnic,
            'serial': serial,
          });
        }

        // Delete redundant dBox keys
        if (dKeysBySerial.containsKey(upperSerial)) {
          for (final dk in dKeysBySerial[upperSerial]!) {
            await dBox.delete(dk);
          }
          await enqueueSync({
            'type': 'delete_dispensary',
            'branchId': targetBranch,
            'dateKey': targetDateKey,
            'serial': serial,
          });
        }
      }

      await eBox.flush();
      await pBox.flush();
      await dBox.flush();
      if (Hive.isBoxOpen('app_flags')) {
        await Hive.box('app_flags').put('serials_unified_v2', true);
      }
      if (unifiedCount > 0) {
        debugPrint('[LocalStorage] ✨ Unified & merged $unifiedCount serial records, removed redundant prescriptions/dispensary records.');
        SyncService().triggerUpload(urgent: true);
      }
    } catch (e) {
      debugPrint('[LocalStorage] Error in unifyAndMergeAllLocalSerials: $e');
    }
    return unifiedCount;
  }

  static List<Map<String, dynamic>> getUnservedPreviousDaysTokens(
    String branchId, {
    int daysBack = 3,
    String? dispensaryId,
  }) {
    // FIX 2: normalize branchId before it's used to build the Hive key
    // prefix below — this method previously used the raw, possibly
    // differently-cased parameter, which could miss real local entries.
    branchId = branchId.toLowerCase().trim();
    if (!Hive.isBoxOpen(entriesBox)) return [];
    final box = Hive.box(entriesBox);
    final shiftInfo = CampSessionService.resolveShiftAndDateKey();
    final today = shiftInfo.dateKey;

    final now = DateTime.now();
    final validDates = <String>{};
    for (int i = 1; i <= daysBack; i++) {
      validDates.add(DateFormat('ddMMyy').format(now.subtract(Duration(days: i))));
    }

    final list = box.keys
        .where((k) => k.toString().startsWith('$branchId-'))
        .map((k) => Map<String, dynamic>.from(box.get(k) as Map))
        .where((e) {
          final dk = e['dateKey']?.toString() ?? '';
          if (dk == today || !validDates.contains(dk)) return false;
          final status = (e['status'] ?? '').toString().toLowerCase();
          final isUnserved = status != 'completed' && status != 'served' && status != 'dispensed' && status != 'cancelled' && status != 'expired';
          if (!isUnserved) return false;

          if (dispensaryId != null && dispensaryId.isNotEmpty && dispensaryId != 'all') {
            final rawD = (e['dispensaryId'] ?? e['campId'])?.toString().toLowerCase().trim();
            if (rawD == null || rawD.isEmpty || rawD == 'all') return true;
            final normD = rawD.replaceAll(RegExp(r'[^a-z0-9]'), '');
            final normCamp = dispensaryId.replaceAll(RegExp(r'[^a-z0-9]'), '');
            return normD == normCamp || normD.contains(normCamp) || normCamp.contains(normD);
          }
          return true;
        })
        .toList();

    return list;
  }

  static Future<int> expireUnservedTokensForDate(String branchId, String dateKey) async {
    // FIX 2: normalize branchId before it's used to build the Hive key
    // prefix below.
    branchId = branchId.toLowerCase().trim();
    if (!Hive.isBoxOpen(entriesBox)) return 0;
    final box = Hive.box(entriesBox);
    int count = 0;
    for (final key in box.keys.toList()) {
      if (!key.toString().startsWith('$branchId-')) continue;
      final val = box.get(key);
      if (val is Map) {
        final entry = Map<String, dynamic>.from(val);
        final dk = entry['dateKey']?.toString();
        if (dk == dateKey) {
          final status = (entry['status'] ?? '').toString().toLowerCase();
          if (status != 'served' && status != 'dispensed' && status != 'cancelled' && status != 'expired') {
            entry['status'] = 'expired';
            entry['expiredAt'] = DateTime.now().toIso8601String();
            await box.put(key, sanitize(entry));
            count++;
          }
        }
      }
    }
    await box.flush();
    return count;
  }

  // ════════════════════════════════════════════════════════════════════════════
  // PRESCRIPTIONS
  // ════════════════════════════════════════════════════════════════════════════

  /// Whether [incoming] is an older version of the prescription [existing] (by monotonic
  /// `revision` first, then the doctor's `updatedAt` / `completedAt` / `createdAt`).
  /// False when they are for different tokens/scopes.
  static bool isOlderPrescription(Map? incoming, Object? existing) {
    if (incoming == null || existing is! Map || existing.isEmpty) return false;
    if (!_isSamePrescriptionScope(incoming, existing)) {
      return false;
    }
    final int inRev = intOf(incoming['revision'] ?? incoming['prescriptionRevision']);
    final int exRev = intOf(existing['revision'] ?? existing['prescriptionRevision']);
    if (inRev > 0 || exRev > 0) {
      if (inRev != exRev) {
        return inRev < exRev;
      }
    }
    DateTime? at(Map m) => DateTime.tryParse((m['updatedAt'] ?? m['completedAt'] ?? m['createdAt'] ?? '').toString());
    final inAt = at(incoming);
    final exAt = at(existing);
    if (inAt != null && exAt != null) {
      return inAt.isBefore(exAt);
    }
    if (exAt != null && inAt == null) {
      // Existing is timestamped by doctor; incoming lacks timestamp. Incoming is older/untrusted!
      return true;
    }
    return false;
  }

  static Future<void> saveLocalPrescription(
      Map<String, dynamic> prescription) async {
    final serialRaw =
        prescription['serial']?.toString() ?? prescription['id']?.toString();
    var serial = serialRaw?.trim();
    if (serial == null || serial.isEmpty) return;

    final branchId = (prescription['branchId'] ?? '').toString().toLowerCase().trim();
    serial = CampSessionService.cleanSerial(serial, branchId);

    final normSerial = serial.toLowerCase().trim();
    final normSerialUpper = serial.toUpperCase().trim();

    // Ensure entriesBox is open early so we can verify existing token data
    final entriesBoxRef = await ensureBoxOpen(entriesBox);

    const cnicFields = [
      'patientCnic', 'cnic', 'patientCNIC', 'guardianCnic',
      'patient_cnic', 'guardian_cnic', 'cnic_number'
    ];
    String? cnicRaw;
    for (final field in cnicFields) {
      final v = prescription[field]?.toString();
      if (v != null && v.trim().isNotEmpty && v != '00000-0000000-0' && !v.startsWith('unknown_')) {
        cnicRaw = v;
        break;
      }
    }

    // 1. If prescription didn't have a legitimate CNIC, check if the token in entriesBox already has one!
    if (cnicRaw == null || cnicRaw.isEmpty || cnicRaw.startsWith('unknown_')) {
      for (final k in [
        if (branchId.isNotEmpty) '$branchId-$normSerialUpper',
        if (branchId.isNotEmpty) '$branchId-$normSerial',
        normSerialUpper,
        normSerial,
      ]) {
        if (entriesBoxRef.containsKey(k)) {
          final existing = entriesBoxRef.get(k);
          if (existing is Map) {
            final exCnic = (existing['patientCnic'] ?? existing['cnic'] ?? existing['guardianCnic'])?.toString().trim();
            if (exCnic != null && exCnic.isNotEmpty && !exCnic.startsWith('unknown_') && exCnic != '00000-0000000-0' && exCnic != '-') {
              cnicRaw = exCnic;
              break;
            }
          }
        }
      }
    }

    // 2. If still missing, check registered patients in patientsBox by patientName
    if (cnicRaw == null || cnicRaw.isEmpty || cnicRaw.startsWith('unknown_')) {
      final pName = (prescription['patientName'] ?? prescription['name'])?.toString().trim();
      if (pName != null && pName.isNotEmpty && pName.toLowerCase() != 'unknown patient' && pName.toLowerCase() != 'unknown') {
        final matched = findPatientByName(pName);
        if (matched != null) {
          final realC = (matched['cnic'] ?? matched['guardianCnic'] ?? matched['patientCnic'])?.toString().trim();
          if (realC != null && realC.isNotEmpty && !realC.startsWith('unknown_')) {
            cnicRaw = realC;
          }
        }
      }
    }

    cnicRaw ??= 'unknown_cnic_${DateTime.now().millisecondsSinceEpoch}';

    final cleanCnic  = cnicRaw.trim().replaceAll('-', '').replaceAll(' ', '');

    var sanitized   = sanitize(prescription);
    sanitized['patientCnic'] = cleanCnic;
    sanitized['cnic']        = cleanCnic;
    sanitized['serial']      = serial;
    if (branchId.isNotEmpty) sanitized['branchId'] = branchId;

    final activeCamp = CampSessionService.getActiveCamp();
    if (activeCamp != null && activeCamp.isNotEmpty) {
      sanitized['dispensaryId'] = sanitized['dispensaryId'] ?? activeCamp;
      sanitized['campId']       = sanitized['campId']       ?? activeCamp;
      sanitized['campName']     = sanitized['campName']     ?? CampSessionService.getCampLabel(activeCamp);
    }

    final effectiveDateKey = (sanitized['dateKey']?.toString().trim().isNotEmpty == true)
        ? sanitized['dateKey'].toString().trim()
        : (CampSessionService.getDateKeyFromSerial(normSerialUpper).isNotEmpty
            ? CampSessionService.getDateKeyFromSerial(normSerialUpper)
            : getTodayDateKey());
    sanitized['dateKey'] ??= effectiveDateKey;
    final effectiveCamp = (sanitized['campId'] ?? sanitized['dispensaryId'] ?? branchId).toString().trim().toLowerCase();
    final effectiveQueue = (sanitized['queueType'] ?? 'zakat').toString().trim().toLowerCase();
    final effectivePid = (sanitized['patientId'] ?? '').toString().trim().toLowerCase();
    final pNameClean = resolveFirstValidPatientName([sanitized['patientName'], sanitized['name'], sanitized['fullName']]);
    final nameSlug = pNameClean.isNotEmpty ? _normalizeName(pNameClean).replaceAll(' ', '_') : '';

    final canonicalKey = branchId.isNotEmpty ? '$branchId-$normSerialUpper' : normSerialUpper;
    final scopedRxKey = '${branchId}_${effectiveCamp}_${effectiveDateKey}_${effectiveQueue}_$normSerialUpper';
    final dateBranchRxKey = '${branchId}_${effectiveDateKey}_$normSerialUpper';
    final pidScopedRxKey = (effectivePid.isNotEmpty && !effectivePid.startsWith('unknown_'))
        ? '${effectivePid}_${effectiveDateKey}_$normSerialUpper'
        : null;
    final nameScopedRxKey = nameSlug.isNotEmpty
        ? '${branchId}_${effectiveDateKey}_${nameSlug}_$normSerialUpper'
        : null;

    // Maintain prescriptionsBox in lockstep with entriesBox so standalone queries succeed
    // A late or replayed older copy (or one without medicines) must not replace a newer
    // stored prescription here.
    Map? storedRx;
    if (Hive.isBoxOpen(prescriptionsBox)) {
      final prBox = Hive.box(prescriptionsBox);
      for (final sk in [
        if (pidScopedRxKey != null) pidScopedRxKey,
        if (nameScopedRxKey != null) nameScopedRxKey,
        scopedRxKey,
        dateBranchRxKey,
        canonicalKey,
        normSerialUpper,
      ]) {
        final cand = prBox.get(sk);
        if (cand is Map && _isSamePrescriptionScope(sanitized, cand)) {
          storedRx = cand;
          break;
        }
      }
    }
    final keepStoredRx = storedRx != null &&
        (isOlderPrescription(sanitized, Map<String, dynamic>.from(storedRx)) ||
            !mayReplacePrescription(sanitized, Map<String, dynamic>.from(storedRx)));
    if (keepStoredRx) {
      debugPrint('[LocalStorage] Older/empty prescription for $normSerialUpper not stored over a newer one');
    }

    if (Hive.isBoxOpen(prescriptionsBox) && !keepStoredRx) {
      final prBox = Hive.box(prescriptionsBox);
      // If canonicalKey currently holds a prescription from a DIFFERENT day/queue/family member,
      // preserve that existing prescription under its own scoped keys before updating canonicalKey.
      final existingCanonicalRx = prBox.get(canonicalKey) ?? prBox.get(normSerialUpper);
      if (existingCanonicalRx is Map && !_isSamePrescriptionScope(sanitized, existingCanonicalRx)) {
        final exB = (existingCanonicalRx['branchId'] ?? branchId).toString().trim().toLowerCase();
        final exC = (existingCanonicalRx['campId'] ?? existingCanonicalRx['dispensaryId'] ?? exB).toString().trim().toLowerCase();
        final exS = (existingCanonicalRx['serial'] ?? existingCanonicalRx['id'] ?? normSerialUpper).toString().trim().toUpperCase();
        final exD = (existingCanonicalRx['dateKey'] ?? CampSessionService.getDateKeyFromSerial(exS)).toString().trim();
        final exQ = (existingCanonicalRx['queueType'] ?? 'zakat').toString().trim().toLowerCase();
        final exPid = (existingCanonicalRx['patientId'] ?? '').toString().trim().toLowerCase();
        final exName = resolveFirstValidPatientName([existingCanonicalRx['patientName'], existingCanonicalRx['name']]);
        final exNameSlug = exName.isNotEmpty ? _normalizeName(exName).replaceAll(' ', '_') : '';
        if (exD.isNotEmpty) {
          await prBox.put('${exB}_${exC}_${exD}_${exQ}_$exS', existingCanonicalRx);
          await prBox.put('${exB}_${exD}_$exS', existingCanonicalRx);
          if (exPid.isNotEmpty && !exPid.startsWith('unknown_')) {
            await prBox.put('${exPid}_${exD}_$exS', existingCanonicalRx);
          }
          if (exNameSlug.isNotEmpty) {
            await prBox.put('${exB}_${exD}_${exNameSlug}_$exS', existingCanonicalRx);
          }
        }
      }
      final pToStore = prescriptionForEmbedding(sanitized);
      await prBox.put(scopedRxKey, pToStore);
      await prBox.put(dateBranchRxKey, pToStore);
      if (pidScopedRxKey != null) await prBox.put(pidScopedRxKey, pToStore);
      if (nameScopedRxKey != null) await prBox.put(nameScopedRxKey, pToStore);
      await prBox.put(canonicalKey, pToStore);
      await prBox.put(normSerialUpper, pToStore);
      if (normSerial != normSerialUpper) await prBox.put(normSerial, pToStore);
      if (cleanCnic.isNotEmpty && !cleanCnic.startsWith('unknown_')) {
        await prBox.put('${cleanCnic}_${effectiveDateKey}_$normSerialUpper', pToStore);
        await prBox.put('${cleanCnic}_$normSerialUpper', pToStore);
      }
      await prBox.flush();
    }

    final matchingKeys = <dynamic>[];
    final candidateKeys = <String>{
      canonicalKey,
      if (branchId.isNotEmpty) '$branchId-$normSerial',
      normSerialUpper,
      normSerial,
    };
    for (final ck in candidateKeys) {
      if (entriesBoxRef.containsKey(ck)) {
        matchingKeys.add(ck);
      }
    }
    // Also find keys stored under a matching branch/camp alias (e.g. 'karachi-...' vs 'haji_camp-...')
    final suffixLower = '-$normSerial';
    for (final k in entriesBoxRef.keys) {
      if (matchingKeys.contains(k)) continue;
      final kStr = k.toString().toLowerCase().trim();
      if (kStr.contains('-collision-')) continue;
      if (kStr.endsWith(suffixLower)) {
        final prefix = kStr.substring(0, kStr.length - suffixLower.length);
        if (branchId.isEmpty || CampSessionService.areBranchesMatching(prefix, branchId)) {
          matchingKeys.add(k);
        }
      }
    }

    if (matchingKeys.isEmpty) {
      if (cleanCnic.startsWith('unknown_cnic_') && (sanitized['patientName'] == null || sanitized['patientName'] == 'Unknown Patient')) {
        return;
      }
      matchingKeys.add(canonicalKey);
    }

    // From the unwrapped prescription: a replay wrapper keeps the medicines in its nested copy,
    // and `prescriptions ?? medicines` picked an empty list over a filled one.
    final embedded = prescriptionForEmbedding(sanitized);
    final pMeds = _medicinesOf(embedded);
    if (pMeds != null) {
      sanitized['medicines'] = pMeds;
      sanitized['prescriptions'] = pMeds;
    }
    final docName = sanitized['doctorName'] ?? sanitized['prescribedBy'];
    final docId = sanitized['doctorId'];
    final diag = sanitized['diagnosis'];
    final comp = sanitized['complaint'] ?? sanitized['condition'];
    final days = sanitized['daysOfMedicine'];
    final vitals = sanitized['vitals'];
    final lab = sanitized['labResults'];
    final extra = sanitized['extraCharge'];

    bool updatedAnyMatchingScope = false;
    for (final k in matchingKeys) {
      final existing = entriesBoxRef.get(k);
      if (existing is Map && existing.isNotEmpty) {
        if (!_isSamePrescriptionScope(embedded, existing)) {
          continue;
        }
      }
      // A replayed (LAN catch-up) snapshot older than what the entry holds would put the
      // doctor's earlier medicines - or none - back on the dispenser's screen.
      // Nor may a copy without medicines replace one that has them.
      if (existing is Map && !mayReplacePrescription(embedded, existing['prescription'])) {
        updatedAnyMatchingScope = true;
        continue;
      }
      updatedAnyMatchingScope = true;
      final updatedEntry = existing is Map ? Map<String, dynamic>.from(existing) : <String, dynamic>{};

      // Entries keep the upper-case serial (saveEntryLocal); the doctor sends it lower-cased.
      updatedEntry['serial'] = normSerialUpper;
      updatedEntry['id'] = normSerialUpper;
      if (branchId.isNotEmpty) updatedEntry['branchId'] ??= branchId;
      if (sanitized['dateKey'] != null) updatedEntry['dateKey'] ??= sanitized['dateKey'];
      if (sanitized['queueType'] != null) updatedEntry['queueType'] ??= sanitized['queueType'];

      // CRITICAL: Never let a prescription event overwrite an existing receptionist patientName!
      final existingName = (existing is Map ? (existing['patientName'] ?? existing['name'] ?? existing['fullName']) : null)?.toString().trim();
      final hasExistingValidName = existingName != null &&
          existingName.isNotEmpty &&
          existingName.toLowerCase() != 'unknown' &&
          existingName.toLowerCase() != 'unknown patient' &&
          existingName != '0' &&
          existingName.toLowerCase() != 'null';
      if (hasExistingValidName) {
        updatedEntry['patientName'] = existingName;
        updatedEntry['name'] = existingName;
        sanitized['patientName'] = existingName;
        sanitized['name'] = existingName;
      } else if (sanitized['patientName'] != null &&
          sanitized['patientName'] != 'Unknown Patient' &&
          sanitized['patientName'] != '0') {
        updatedEntry['patientName'] = sanitized['patientName'];
        updatedEntry['name'] = sanitized['patientName'];
      }

      // CRITICAL: NEVER overwrite an existing legitimate CNIC with a synthetic fallback!
      final existingCnic = (existing is Map ? (existing['patientCnic'] ?? existing['cnic'] ?? existing['guardianCnic']) : null)?.toString().trim();
      if (existingCnic != null && existingCnic.isNotEmpty && !existingCnic.startsWith('unknown_') && existingCnic != '00000-0000000-0' && existingCnic != '-') {
        updatedEntry['patientCnic'] = existingCnic;
        updatedEntry['cnic'] = existingCnic;
        sanitized['patientCnic'] = existingCnic;
        sanitized['cnic'] = existingCnic;
      } else if (!cleanCnic.startsWith('unknown_')) {
        updatedEntry['patientCnic'] = cleanCnic;
        updatedEntry['cnic'] = cleanCnic;
      }

      // Preserve receptionist vitals on both the embedded prescription and the token entry
      final mergedVitals = mergeVitalsPreservingReceptionist(
        vitals,
        existing is Map ? existing['vitals'] : null,
      );
      if (mergedVitals.isNotEmpty) {
        sanitized['vitals'] = mergedVitals;
        updatedEntry['vitals'] = mergedVitals;
      }

      // Rebuilt here: the CNIC/name/vitals fix-up above enriches `sanitized` per token.
      final embeddedToStore = prescriptionForEmbedding(sanitized);
      updatedEntry['prescription'] = embeddedToStore;
      updatedEntry['status']       = 'completed';
      updatedEntry['completedAt']  ??= sanitized['completedAt'] ?? DateTime.now().toIso8601String();
      if (sanitized['updatedAt'] != null) {
        updatedEntry['updatedAt'] = sanitized['updatedAt'];
      }
      final rxRev = embeddedToStore['revision'] ?? embeddedToStore['prescriptionRevision'] ?? sanitized['revision'];
      if (rxRev != null) {
        updatedEntry['revision'] = rxRev;
        updatedEntry['prescriptionRevision'] = rxRev;
      }
      if (pMeds != null) {
        updatedEntry['medicines'] = pMeds;
        updatedEntry['prescriptions'] = pMeds;
      }
      if (docName != null) {
        updatedEntry['doctorName'] = docName;
        updatedEntry['prescribedBy'] = docName;
      }
      if (docId != null) updatedEntry['doctorId'] = docId;
      if (diag != null) updatedEntry['diagnosis'] = diag;
      if (comp != null) {
        updatedEntry['complaint'] = comp;
        updatedEntry['condition'] = comp;
      }
      if (days != null) updatedEntry['daysOfMedicine'] = days;
      if (lab != null) updatedEntry['labResults'] = lab;
      if (extra != null) updatedEntry['extraCharge'] = extra;
      if ((existing is Map && (existing['dispenseStatus'] ?? '').toString().toLowerCase() == 'dispensed') ||
          (sanitized['dispenseStatus'] ?? '').toString().toLowerCase() == 'dispensed') {
        updatedEntry['dispenseStatus'] = 'dispensed';
        updatedEntry['status'] = 'completed';
      } else if (sanitized['dispenseStatus'] != null) {
        updatedEntry['dispenseStatus'] = sanitized['dispenseStatus'];
      } else {
        updatedEntry['dispenseStatus'] ??= 'pending';
      }

      // Echo prevention rule: lanPushSig is ONLY stamped when prescription arrived from LAN server.
      if (prescription['lanPushSig'] != null) {
        updatedEntry['lanPushSig'] = lanPushSignature(updatedEntry);
      } else {
        updatedEntry.remove('lanPushSig');
      }

      await entriesBoxRef.put(k, sanitize(updatedEntry));
    }
    if (!updatedAnyMatchingScope) {
      final scopedEntryKey = '$canonicalKey-$effectiveDateKey-$effectiveQueue${nameSlug.isNotEmpty ? '-$nameSlug' : ''}';
      final fallbackEntry = Map<String, dynamic>.from(sanitized);
      fallbackEntry['serial'] = normSerialUpper;
      fallbackEntry['id'] = normSerialUpper;
      fallbackEntry['prescription'] = prescriptionForEmbedding(sanitized);
      fallbackEntry['status'] = 'completed';
      fallbackEntry['dispenseStatus'] ??= 'pending';
      if (prescription['lanPushSig'] != null) {
        fallbackEntry['lanPushSig'] = lanPushSignature(fallbackEntry);
      } else {
        fallbackEntry.remove('lanPushSig');
      }
      await entriesBoxRef.put(scopedEntryKey, sanitize(fallbackEntry));
    } else if (!matchingKeys.contains(canonicalKey)) {
      final base = entriesBoxRef.get(matchingKeys.first);
      if (base is Map && _isSamePrescriptionScope(embedded, base)) {
        await entriesBoxRef.put(canonicalKey, base);
      }
    }
    await entriesBoxRef.flush();
  }

  /// [receivedViaLan]: the change came from another PC over the LAN. That PC (or the LAN
  /// server) uploads it, so this PC neither marks the token unsynced nor queues an upload;
  /// every receiving PC used to queue its own copy (one Firestore write per PC per dispense).
  static Future<void> updateDispenseStatus(
      String branchId, String serial, String status, {bool receivedViaLan = false}) async {
    final normBranch = branchId.toLowerCase().trim();
    var cleanSerial = serial.trim();
    if (cleanSerial.toLowerCase().startsWith('$normBranch-')) {
      cleanSerial = cleanSerial.substring(normBranch.length + 1).trim();
    }
    final normSerialUpper = cleanSerial.toUpperCase();
    final canonicalKey    = '$normBranch-$normSerialUpper';
    final statusLower     = status.trim().toLowerCase();
    final box             = Hive.box(entriesBox);

    // A replayed LAN dispense (catch-ups resend the whole day) changes nothing: skip the full
    // scans and writes below, which ran several times per message on every PC.
    if (receivedViaLan) {
      final current = box.get(canonicalKey);
      if (current is Map && (current['dispenseStatus'] ?? '').toString().toLowerCase() == statusLower) return;
    }

    final matchingKeys = <dynamic>[];
    final Map<String, dynamic> mergedExisting = {};

    for (final key in box.keys.toList()) {
      final keyStr = key.toString().trim();
      final keyLower = keyStr.toLowerCase();
      if (keyStr == canonicalKey ||
          keyLower == canonicalKey.toLowerCase() ||
          keyLower == cleanSerial.toLowerCase() ||
          keyStr == normSerialUpper ||
          keyLower.endsWith('-$normSerialUpper'.toLowerCase())) {
        matchingKeys.add(key);
        final raw = box.get(key);
        if (raw is Map) {
          final m = Map<String, dynamic>.from(raw);
          // Duplicate keys of one token: the later key in Hive's order used to win the
          // prescription too, however old or empty it was.
          final keptRx = preferredPrescription(m['prescription'], mergedExisting['prescription']);
          m.forEach((k, v) {
            if (v != null && v != '' && v != 'unknown' && v != 'Unknown' && v != 'Unknown Patient') {
              mergedExisting[k] = v;
            } else {
              mergedExisting.putIfAbsent(k, () => v);
            }
          });
          if (keptRx != null) mergedExisting['prescription'] = keptRx;
        }
      }
    }

    // If prescription or patient info is still missing in entriesBox, search prescriptionsBox & dispensaryBox
    if (mergedExisting['prescription'] == null || mergedExisting['patientName'] == null) {
      final presc = getLocalPrescription(normSerialUpper, branchId: normBranch);
      if (presc != null) {
        presc.forEach((k, v) {
          if (v != null && v != '' && v != 'unknown' && v != 'Unknown') {
            mergedExisting.putIfAbsent(k, () => v);
          }
        });
        mergedExisting['prescription'] ??= presc;
      }
    }
    if ((mergedExisting['patientName'] == null || mergedExisting['patientName'] == 'Unknown Patient') && Hive.isBoxOpen(dispensaryBox)) {
      try {
        final dBox = Hive.box(dispensaryBox);
        for (final dk in dBox.keys) {
          final dkStr = dk.toString().trim().toUpperCase();
          if (dkStr.endsWith('_$normSerialUpper') || dkStr.endsWith('-$normSerialUpper') || dkStr == normSerialUpper) {
            final dVal = dBox.get(dk);
            if (dVal is Map) {
              final dMap = Map<String, dynamic>.from(dVal);
              dMap.forEach((k, v) {
                if (v != null && v != '' && v != 'unknown' && v != 'Unknown') {
                  mergedExisting.putIfAbsent(k, () => v);
                }
              });
              break;
            }
          }
        }
      } catch (_) {}
    }

    final nowIso = DateTime.now().toIso8601String();
    final todayKey = getTodayDateKey();
    final base = Map<String, dynamic>.from(mergedExisting);
    base['serial']         = normSerialUpper;
    base['branchId']       = normBranch;
    base['dispenseStatus'] = status;
    base['dateKey']        ??= todayKey;
    base['createdAt']      ??= nowIso;
    if (base['campId'] == null || base['campId'] == '') {
      if (normSerialUpper.contains('SADD')) {
        base['campId'] = 'saddar';
      } else if (normSerialUpper.contains('HAJI')) {
        base['campId'] = 'haji_camp';
      } else {
        base['campId'] = normBranch;
      }
    }
    if (base['queueType'] == null || base['queueType'] == '') {
      if (normSerialUpper.contains('NZ') || normSerialUpper.contains('-NZ-')) {
        base['queueType'] = 'non-zakat';
      } else if (normSerialUpper.contains('-G-') || base['isFreeToken'] == true) {
        base['queueType'] = 'gmwf';
      } else {
        base['queueType'] = 'zakat';
      }
    }
    if (statusLower == 'dispensed') {
      base['status']       = 'completed';
      base['dispensedAt']  ??= nowIso;
      base['completedAt']  ??= nowIso;
    }
    if (!receivedViaLan) {
      base['pendingSync'] = true;
      base['synced']      = false;
      base['syncStatus']  = 'pending';
      base.remove('lanPushSig');
    }

    await box.put(canonicalKey, base);

    // Also mark dispensed in prescriptionsBox so doctor reservation clears immediately
    if (Hive.isBoxOpen(prescriptionsBox)) {
      try {
        final pBox = Hive.box(prescriptionsBox);
        for (final pk in pBox.keys.toList()) {
          final pkStr = pk.toString().toLowerCase().trim();
          if (pkStr == normSerialUpper.toLowerCase() ||
              pkStr == '$normBranch-${normSerialUpper.toLowerCase()}' ||
              pkStr == '$normBranch-${cleanSerial.toLowerCase()}' ||
              pkStr == cleanSerial.toLowerCase() ||
              pkStr.endsWith('-$normSerialUpper'.toLowerCase())) {
            final pVal = pBox.get(pk);
            if (pVal is Map) {
              final pMap = Map<String, dynamic>.from(pVal);
              pMap['dispenseStatus'] = status;
              if (statusLower == 'dispensed') {
                pMap['status'] = 'completed';
                pMap['dispensedAt'] = nowIso;
              }
              await pBox.put(pk, pMap);
            }
          }
        }
      } catch (_) {}
    }

    // Prune legacy redundant keys to prevent duplicate entries
    for (final oldKey in matchingKeys) {
      if (oldKey.toString().trim() != canonicalKey) {
        try {
          await box.delete(oldKey);
        } catch (_) {}
      }
    }

    await box.flush();
    invalidateLocalEntriesCache();

    // Immediately enqueue cloud sync for the dispense status change
    if (receivedViaLan) return;
    try {
      await enqueueSync({
        'type': 'update_serial_status',
        'branchId': normBranch,
        'serial': normSerialUpper,
        'dateKey': base['dateKey'] ?? todayKey,
        'queueType': base['queueType'] ?? 'zakat',
        'data': {
          'dispenseStatus': status,
          'status': base['status'] ?? (statusLower == 'dispensed' ? 'completed' : 'waiting'),
          'dispensedAt': base['dispensedAt'],
          'completedAt': base['completedAt'],
          'serial': normSerialUpper,
          'branchId': normBranch,
          'campId': base['campId'],
          'dispensaryTag': base['dispensaryTag'],
        },
      });
      SyncService().triggerUpload();
    } catch (_) {}
  }

  static Map<String, dynamic>? getLocalPrescription(
    String serial, {
    String? cnic,
    String? patientName,
    String? patientId,
    String? branchId,
    String? dateKey,
    String? queueType,
    String? campId,
  }) {
    if (serial.trim().isEmpty) return null;
    final normBranch  = (branchId ?? '').trim().toLowerCase();
    final normCamp    = (campId ?? '').trim().toLowerCase();
    final normQueue   = (queueType ?? '').trim().toLowerCase();
    var cleanSerial = serial.trim();
    if (normBranch.isNotEmpty && cleanSerial.toLowerCase().startsWith('$normBranch-')) {
      cleanSerial = cleanSerial.substring(normBranch.length + 1).trim();
    }
    final lowerSerial = cleanSerial.toLowerCase();
    final upperSerial = cleanSerial.toUpperCase();
    final cleanCnic   = (cnic ?? '').trim().replaceAll(RegExp(r'[-\s]'), '');
    final cleanPId    = (patientId ?? '').trim();
    final effectiveDateKey = (dateKey != null && dateKey.trim().isNotEmpty)
        ? dateKey.trim()
        : CampSessionService.getDateKeyFromSerial(cleanSerial);
    final serialReg = RegExp(r'^\d{6}([A-Za-z])-');
    final match = serialReg.firstMatch(cleanSerial);
    final mySessionLetter = match != null ? match.group(1)?.toUpperCase() : null;

    // Helper: validate candidate prescription against branch, date, camp, queue, and patient identity
    bool matchesPatient(Map data, [Map? parentEntry]) {
      // 1. Branch verification
      if (normBranch.isNotEmpty && normBranch != 'all' && normBranch != 'global') {
        final pBranch = (data['branchId'] ?? parentEntry?['branchId'] ?? '').toString().trim().toLowerCase();
        if (pBranch.isNotEmpty && !CampSessionService.areBranchesMatching(pBranch, normBranch)) {
          return false;
        }
      }

      // 1b. Camp / Dispensary verification
      if (normCamp.isNotEmpty && normCamp != 'all' && normCamp != 'global' && normCamp != normBranch) {
        final pCamp = (data['campId'] ?? data['dispensaryId'] ?? parentEntry?['campId'] ?? parentEntry?['dispensaryId'] ?? '')
            .toString()
            .trim()
            .toLowerCase();
        if (pCamp.isNotEmpty && pCamp != 'all' && pCamp != normBranch && pCamp != normCamp) {
          if (!CampSessionService.matchesCamp(
            selectedCamp: normCamp,
            campId: pCamp,
            dispensaryId: (data['dispensaryId'] ?? parentEntry?['dispensaryId'])?.toString(),
            dispensaryTag: (data['dispensaryTag'] ?? parentEntry?['dispensaryTag'])?.toString(),
            serial: (data['serial'] ?? data['id'] ?? parentEntry?['serial'])?.toString(),
          )) {
            return false;
          }
        }
      }

      // 2. DateKey verification
      if (effectiveDateKey.isNotEmpty) {
        final candidateSerial = (data['serial'] ?? data['id'] ?? parentEntry?['serial'] ?? '').toString().trim();
        var pDateKey = (data['dateKey'] ?? parentEntry?['dateKey'] ?? CampSessionService.getDateKeyFromSerial(candidateSerial))
            .toString()
            .trim();
        if (pDateKey.isEmpty) {
          final dtStr = (data['completedAt'] ?? data['createdAt'] ?? data['updatedAt'] ?? parentEntry?['createdAt'])?.toString();
          if (dtStr != null && dtStr.isNotEmpty) {
            final dt = DateTime.tryParse(dtStr);
            if (dt != null) {
              pDateKey = CampSessionService.formatDateKey(dt);
            }
          }
        }
        if (pDateKey.isNotEmpty && pDateKey != effectiveDateKey) {
          return false;
        }
      }

      // 2b. QueueType verification (zakat vs non-zakat vs gmwf)
      if (normQueue.isNotEmpty) {
        final pQueue = (data['queueType'] ?? parentEntry?['queueType'] ?? '').toString().trim().toLowerCase();
        if (pQueue.isNotEmpty && pQueue != normQueue) {
          return false;
        }
      }

      // 3. Session tag verification: a morning token must never match an evening token!
      if (mySessionLetter != null) {
        final candidateSerial = (data['serial'] ?? data['id'] ?? '').toString().trim();
        final candMatch = serialReg.firstMatch(candidateSerial);
        final candLetter = candMatch?.group(1)?.toUpperCase();
        if (candLetter != null && candLetter.isNotEmpty) {
          if (candLetter != mySessionLetter) return false;
        } else if (RegExp(r'^\d{6}-').hasMatch(candidateSerial) &&
            !isLetterlessRecordInSession(data, mySessionLetter)) {
          // A letterless (v1.6.1) record is shared by every session that day; only use it
          // when it says it belongs to this one.
          return false;
        }
      }

      // 4. Patient ID verification (never fall back to `id` which is the token serial!)
      if (cleanPId.isNotEmpty && !cleanPId.startsWith('unknown_')) {
        final pId = (data['patientId'] ?? parentEntry?['patientId'] ?? '').toString().trim();
        if (pId.isNotEmpty && !pId.startsWith('unknown_') && pId.toLowerCase() != cleanPId.toLowerCase()) {
          return false;
        }
      }

      // 5. CNIC verification
      if (cleanCnic.isNotEmpty && !cleanCnic.startsWith('unknown_')) {
        final pCnic = (data['patientCnic'] ?? data['cnic'] ?? parentEntry?['patientCnic'] ?? parentEntry?['cnic'] ?? '')
            .toString()
            .trim()
            .replaceAll(RegExp(r'[-\s]'), '');
        if (pCnic.isNotEmpty &&
            !pCnic.startsWith('unknown_') &&
            pCnic != cleanCnic &&
            !pCnic.contains(cleanCnic) &&
            !cleanCnic.contains(pCnic)) {
          return false;
        }
      }

      // 6. Patient Name verification (prevents prescriptions crossing between two family members on one CNIC)
      if (patientName != null && patientName.trim().isNotEmpty) {
        final pName = (data['patientName'] ?? data['name'] ?? parentEntry?['patientName'] ?? parentEntry?['name'] ?? '')
            .toString()
            .trim()
            .toLowerCase();
        final qName = patientName.trim().toLowerCase();
        if (pName.isNotEmpty &&
            qName.isNotEmpty &&
            pName != 'unknown' &&
            qName != 'unknown' &&
            pName != 'unknown patient' &&
            qName != 'unknown patient' &&
            pName.length >= 2 &&
            qName.length >= 2) {
          if (pName != qName && !pName.contains(qName) && !qName.contains(pName)) {
            return false;
          }
        }
      }
      return true;
    }

    // replaceFirstMapped: replaceFirst would insert a literal "$1". matchesPatient's session
    // guard decides whether a letterless (v1.6.1) record found this way may be used.
    final legacySerial = cleanSerial.replaceFirstMapped(RegExp(r'^(\d{6})[A-Za-z]-'), (m) => '${m[1]}-');
    final serialVariants = <String>{
      cleanSerial,
      upperSerial,
      lowerSerial,
      if (cleanSerial != legacySerial) legacySerial,
      if (cleanSerial != legacySerial) legacySerial.toUpperCase(),
      if (cleanSerial != legacySerial) legacySerial.toLowerCase(),
    };

    // A copy found without medicines is only used when nothing better turns up: returning it
    // straight away showed the dispenser (and the doctor's edit dialog) an empty list while
    // the token's own list or the prescriptions box still had the medicines.
    Map<String, dynamic>? withoutMedicines;

    // 1. Check entriesBox strictly for this branch & scope (including archived date/queue keys)
    try {
      if (Hive.isBoxOpen(entriesBox)) {
        final eBox = Hive.box(entriesBox);
        final entryKeyCandidates = <String>[];
        for (final v in serialVariants) {
          if (normBranch.isNotEmpty) {
            if (effectiveDateKey.isNotEmpty && normQueue.isNotEmpty) {
              entryKeyCandidates.add('$normBranch-$v-$effectiveDateKey-$normQueue');
            }
            if (effectiveDateKey.isNotEmpty) {
              entryKeyCandidates.add('$normBranch-$v-$effectiveDateKey-zakat');
              entryKeyCandidates.add('$normBranch-$v-$effectiveDateKey-non-zakat');
              entryKeyCandidates.add('$normBranch-$v-$effectiveDateKey-gmwf');
            }
            entryKeyCandidates.add('$normBranch-$v');
          }
          entryKeyCandidates.add(v);
        }
        for (final ek in entryKeyCandidates) {
          final exactEntry = eBox.get(ek);
          if (exactEntry is Map && exactEntry['prescription'] is Map) {
            final presc = exactEntry['prescription'] as Map;
            if (presc.isNotEmpty && matchesPatient(presc, exactEntry)) {
              final rx = prescriptionForEmbedding(presc);
              if (!_hasMedicines(rx)) {
                final entryMeds = _medicinesOf(exactEntry);
                if (entryMeds != null) {
                  rx['medicines'] = entryMeds;
                  rx['prescriptions'] = entryMeds;
                }
              }
              if (_hasMedicines(rx)) return rx;
              withoutMedicines ??= rx;
            }
          }
        }
      }
    } catch (_) {}

    // 2. Scoped & direct key lookups in prescriptionsBox with strict branch/date/patient validation
    if (Hive.isBoxOpen(prescriptionsBox)) {
      final box = Hive.box(prescriptionsBox);
      final keyCandidates = <String>[];
      final qNameSlug = (patientName != null && patientName.trim().isNotEmpty)
          ? _normalizeName(patientName).replaceAll(' ', '_')
          : '';
      for (final v in serialVariants) {
        if (cleanPId.isNotEmpty && !cleanPId.startsWith('unknown_') && effectiveDateKey.isNotEmpty) {
          keyCandidates.add('${cleanPId.toLowerCase()}_${effectiveDateKey}_$v');
        }
        if (normBranch.isNotEmpty && effectiveDateKey.isNotEmpty && qNameSlug.isNotEmpty) {
          keyCandidates.add('${normBranch}_${effectiveDateKey}_${qNameSlug}_$v');
        }
        if (normBranch.isNotEmpty && effectiveDateKey.isNotEmpty) {
          final effCamp = normCamp.isNotEmpty ? normCamp : normBranch;
          final effQueue = normQueue.isNotEmpty ? normQueue : 'zakat';
          keyCandidates.add('${normBranch}_${effCamp}_${effectiveDateKey}_${effQueue}_$v');
          keyCandidates.add('${normBranch}_${effectiveDateKey}_$v');
        }
        if (cleanCnic.isNotEmpty && !cleanCnic.startsWith('unknown_')) {
          if (effectiveDateKey.isNotEmpty) {
            keyCandidates.add('${cleanCnic}_${effectiveDateKey}_$v');
          }
          keyCandidates.add('${cleanCnic}_$v');
        }
        if (normBranch.isNotEmpty) {
          keyCandidates.add('$normBranch-$v');
        }
        keyCandidates.add(v);
      }

      for (final k in keyCandidates) {
        final direct = box.get(k);
        if (direct != null && direct is Map && matchesPatient(direct)) {
          final rx = prescriptionForEmbedding(direct);
          if (_hasMedicines(rx)) return rx;
          withoutMedicines ??= rx;
        }
      }

      // 3. Fallback scan of scoped keys in prescriptionsBox for this serial
      for (final k in box.keys) {
        final kStr = k.toString().toUpperCase();
        if (kStr.endsWith('_$upperSerial') || kStr.endsWith('-$upperSerial') || kStr == upperSerial) {
          final val = box.get(k);
          if (val is Map && matchesPatient(val)) {
            final rx = prescriptionForEmbedding(val);
            if (_hasMedicines(rx)) return rx;
            withoutMedicines ??= rx;
          }
        }
      }
    }

    return withoutMedicines;
  }

  static Future<void> deleteLocalPrescription(String serial) async {
    if (serial.trim().isEmpty) return;
    try {
      if (Hive.isBoxOpen(prescriptionsBox)) {
        final box = Hive.box(prescriptionsBox);
        final cleanSerial = serial.trim();
        final legacySerial = cleanSerial.replaceFirst(RegExp(r'^(\d{6})[A-Za-z]-'), r'$1-');
        final targets = {
          cleanSerial.toLowerCase(),
          cleanSerial.toUpperCase(),
          legacySerial.toLowerCase(),
          legacySerial.toUpperCase(),
        };
        for (final t in targets) {
          await box.delete(t);
        }
        final keysToDelete = <dynamic>[];
        for (final k in box.keys) {
          final kStr = k.toString().toLowerCase();
          for (final t in targets) {
            final tLower = t.toLowerCase();
            if (kStr == tLower || kStr.endsWith('_$tLower') || kStr.endsWith('-$tLower')) {
              keysToDelete.add(k);
            }
          }
        }
        for (final k in keysToDelete) {
          await box.delete(k);
        }
      }
    } catch (_) {}
  }

  static Map<String, dynamic>? getLocalPrescriptionByCnic(
    String cnic, {
    String? patientName,
    String? patientId,
  }) {
    final box = Hive.box(prescriptionsBox);
    if (!box.isOpen) return null;
    var cleanCnic = cnic.trim().replaceAll('-', '').replaceAll(' ', '');
    cleanCnic = cleanCnic.replaceAll(RegExp(r'^0+'), '');
    final cleanPId = (patientId ?? '').trim().replaceAll(RegExp(r'[-\s]'), '').toLowerCase();
    final cleanPName = (patientName ?? '').trim().toLowerCase();

    for (final value in box.values) {
      if (value is! Map) continue;
      final presc = Map<String, dynamic>.from(value);
      final raw   = presc['patientCnic']?.toString() ??
          presc['cnic']?.toString() ?? '';
      var pc = raw.trim().replaceAll('-', '').replaceAll(' ', '');
      pc = pc.replaceAll(RegExp(r'^0+'), '');
      if (pc == cleanCnic || pc.contains(cleanCnic) || cleanCnic.contains(pc)) {
        if (cleanPId.isNotEmpty) {
          final pid = (presc['patientId'] ?? presc['id'] ?? '')
              .toString()
              .replaceAll(RegExp(r'[-\s]'), '')
              .toLowerCase();
          if (pid.isNotEmpty && pid != cleanPId) continue;
        }
        if (cleanPName.isNotEmpty && cleanPName != 'unknown' && cleanPName != 'unknown patient') {
          final name = (presc['patientName'] ?? presc['name'] ?? '')
              .toString()
              .trim()
              .toLowerCase();
          if (name.isNotEmpty && name != 'unknown' && name != 'unknown patient') {
            if (name != cleanPName && !name.contains(cleanPName) && !cleanPName.contains(name)) {
              continue;
            }
          }
        }
        return presc;
      }
    }
    return null;
  }

  static List<Map<String, dynamic>> getAllLocalPrescriptions() =>
      Hive.box(prescriptionsBox)
          .values
          .map((v) => Map<String, dynamic>.from(v as Map))
          .toList();

  static List<Map<String, dynamic>> getBranchPrescriptions(String branchId) =>
      getAllLocalPrescriptions()
          .where((p) => p['branchId'] == branchId)
          .toList();

  // ════════════════════════════════════════════════════════════════════════════
  // STOCK
  // ════════════════════════════════════════════════════════════════════════════

  static Future<void> saveAllLocalStockItems(
      List<Map<String, dynamic>> items) async {
    final box = Hive.box(stockBox);
    final sBox = Hive.box(syncBox);

    final pendingDeltas = <String, double>{};
    for (final key in sBox.keys) {
      final val = sBox.get(key);
      if (val is Map) {
        final type = val['type'];
        if (type == 'update_inventory') {
          final medId = val['inventoryId']?.toString();
          final delta = (val['delta'] as num?)?.toDouble() ?? 0.0;
          if (medId != null && delta != 0) {
            pendingDeltas[medId] = (pendingDeltas[medId] ?? 0.0) + delta;
          }
        } else if (type == 'add_inventory_stock') {
          final medId = val['medicineId']?.toString();
          final qty = (val['quantity'] as num?)?.toDouble() ?? 0.0;
          if (medId != null && qty > 0) {
            pendingDeltas[medId] = (pendingDeltas[medId] ?? 0.0) + qty;
          }
        }
      }
    }

    final pendingRegistrations = sBox.values
        .whereType<Map>()
        .where((v) => v['type'] == 'register_medicine')
        .map((v) {
          final dataMap = v['data'] is Map ? Map<String, dynamic>.from(v['data'] as Map) : <String, dynamic>{};
          return (dataMap['id'] ?? dataMap['medicineId'])?.toString();
        })
        .whereType<String>()
        .toSet();

    final Map<String, dynamic> updatedMap = {};
    final downloadedIds = <String>{};

    final currentLocalItems = <String, dynamic>{};
    for (final key in box.keys) {
      final val = box.get(key);
      if (val is Map) {
        final itemMap = Map<String, dynamic>.from(val);
        final id = (itemMap['id'] ?? itemMap['medicineId'])?.toString().trim() ?? '';
        if (id.isNotEmpty && itemMap['status'] != 'deleted') {
          currentLocalItems[id] = itemMap;
        }
      }
    }

    for (final item in items) {
      final id = (item['id'] ?? item['medicineId'])?.toString().trim() ?? '';
      if (id.isEmpty) continue;
      downloadedIds.add(id);

      if (pendingDeltas.containsKey(id)) {
        final downloadedQty = (item['quantity'] ?? 0) as num;
        item['quantity'] = (downloadedQty.toDouble() + pendingDeltas[id]!).clamp(0.0, double.infinity);
        debugPrint('[LocalStorage] Re-applied pending local delta of ${pendingDeltas[id]} to downloaded stock of $id');
      } else if (currentLocalItems.containsKey(id)) {
        final localItem = currentLocalItems[id] as Map<String, dynamic>;
        final localUpdated = localItem['updatedAt'] ?? localItem['lastUpdated'];
        final remoteUpdated = item['updatedAt'] ?? item['lastUpdated'];
        if (localUpdated != null && remoteUpdated != null) {
          final localDt = DateTime.tryParse(localUpdated.toString());
          final remoteDt = DateTime.tryParse(remoteUpdated.toString());
          if (localDt != null && remoteDt != null && localDt.isAfter(remoteDt)) {
            // Local item has more recent edits (dispensing/restock); preserve local quantity & timestamp
            item['quantity'] = localItem['quantity'];
            item['updatedAt'] = localItem['updatedAt'];
            if (localItem['lastUpdated'] != null) item['lastUpdated'] = localItem['lastUpdated'];
          }
        } else if (localItem['quantity'] != null &&
            (item['quantity'] == null || ((item['quantity'] as num) == 0 && (localItem['quantity'] as num) > 0))) {
          // Avoid wiping non-zero local stock with zero remote stock if timestamps are missing
          item['quantity'] = localItem['quantity'];
        }
      } else {
        final rawQty = (item['quantity'] as num?)?.toDouble() ?? 0.0;
        item['quantity'] = rawQty.clamp(0.0, double.infinity);
      }
      updatedMap['stock:$id'] = item;
      updatedMap[id] = item;
    }

    // Preserve ALL local and LAN-received items that were not present in downloaded Firestore snapshot
    int preservedCount = 0;
    for (final entry in currentLocalItems.entries) {
      final locId = entry.key;
      final locItem = entry.value;
      if (!downloadedIds.contains(locId)) {
        updatedMap['stock:$locId'] = locItem;
        updatedMap[locId] = locItem;
        preservedCount++;
      }
    }
    if (preservedCount > 0) {
      debugPrint('[LocalStorage] Preserved $preservedCount local/LAN stock item(s) (not in remote snapshot)');
    }

    // Do NOT call box.clear() — putAll overwrites updated items while keeping any other valid keys intact
    await box.putAll(updatedMap);
    await box.flush();
  }

  static Future<void> saveLocalStockItem(
      Map<String, dynamic> stockItem) async {
    final id = (stockItem['id'] ?? stockItem['medicineId'] ?? stockItem['docId'])?.toString();
    if (id == null || id.isEmpty) return;
    final item = Map<String, dynamic>.from(stockItem);
    final isCustom = item['isCustomized'] == true || item['userEdited'] == true;
    if (!isCustom) {
      if (item['name'] != null) item['name'] = MasterProformaService.cleanBrandToFormula(item['name'].toString());
      if (item['formula'] != null) item['formula'] = MasterProformaService.cleanBrandToFormula(item['formula'].toString());
    }
    final rawQty = (item['quantity'] as num?)?.toDouble() ?? 0.0;
    item['quantity'] = rawQty.clamp(0.0, double.infinity);
    final activeCamp = CampSessionService.getActiveCamp();
    if (activeCamp != null && activeCamp.isNotEmpty) {
      item['dispensaryId'] = item['dispensaryId'] ?? activeCamp;
      item['campId']       = item['campId']       ?? activeCamp;
    }
    final box = await ensureBoxOpen(stockBox);
    await box.put('stock:$id', sanitize(item));
    await box.put(id, sanitize(item));
    await box.flush();
  }

  static void saveLocalInventoryItem(Map<String, dynamic> item) {
    final rawId = (item['id'] ?? item['medicineId'] ?? item['docId'] ?? item['code'] ?? item['barcode'])?.toString().trim();
    if (rawId == null || rawId.isEmpty) return;
    final normalised = Map<String, dynamic>.from(item);
    normalised['id']         = rawId;
    normalised['medicineId'] = rawId;
    final isCustom = normalised['isCustomized'] == true || normalised['userEdited'] == true;
    if (!isCustom) {
      if (normalised['name'] != null) normalised['name'] = MasterProformaService.cleanBrandToFormula(normalised['name'].toString());
      if (normalised['formula'] != null) normalised['formula'] = MasterProformaService.cleanBrandToFormula(normalised['formula'].toString());
    }
    final rawQty = (normalised['quantity'] as num?)?.toDouble() ?? 0.0;
    normalised['quantity']   = rawQty.clamp(0.0, double.infinity);
    final activeCamp = CampSessionService.getActiveCamp();
    final explicitCamp = (normalised['dispensaryId'] ?? normalised['campId'] ?? normalised['dispensaryTag'])
      ?.toString()
      .trim();
    if ((explicitCamp == null || explicitCamp.isEmpty) &&
      activeCamp != null && activeCamp.isNotEmpty) {
      normalised['dispensaryId'] = activeCamp;
      normalised['campId']       = activeCamp;
    }
    if (Hive.isBoxOpen(stockBox)) {
      final box = Hive.box(stockBox);
      box.put('stock:$rawId', sanitize(normalised));
      box.put(rawId, sanitize(normalised));
      box.flush();
    } else {
      openBoxSafe(stockBox).then((box) {
        box.put('stock:$rawId', sanitize(normalised));
        box.put(rawId, sanitize(normalised));
        box.flush();
      });
    }
  }

  static Map<String, dynamic>? getLocalInventoryItem(String id) {
    if (!Hive.isBoxOpen(stockBox)) return null;
    final box = Hive.box(stockBox);
    var val = box.get('stock:$id') ?? box.get(id);
    if (val != null) return Map<String, dynamic>.from(val as Map);
    for (final k in box.keys) {
      final v = box.get(k);
      if (v is Map) {
        final mId = (v['id'] ?? v['medicineId'] ?? v['docId'] ?? v['code'] ?? v['barcode'])?.toString();
        if (mId == id) {
          return Map<String, dynamic>.from(v);
        }
      }
    }
    return null;
  }

  static Future<void> updateLocalStockQuantity(String id, double delta) async {
    final box = await ensureBoxOpen(stockBox);
    dynamic targetKey = 'stock:$id';
    dynamic raw = box.get(targetKey);
    if (raw == null) {
      targetKey = id;
      raw = box.get(targetKey);
    }
    if (raw == null) {
      for (final k in box.keys) {
        final v = box.get(k);
        if (v is Map) {
          final mId = (v['id'] ?? v['medicineId'] ?? v['docId'] ?? v['code'] ?? v['barcode'])?.toString();
          if (mId == id) {
            targetKey = k;
            raw = v;
            break;
          }
        }
      }
    }
    if (raw == null) return;
    final item = Map<String, dynamic>.from(raw as Map);

    final currentQty = (item['quantity'] ?? 0) as num;
    item['quantity'] = (currentQty.toDouble() + delta).clamp(0.0, double.infinity);
    item['updatedAt'] = DateTime.now().toIso8601String();
    await box.put(targetKey, sanitize(item));
    final rawId = (item['id'] ?? item['medicineId'] ?? id).toString();
    await box.put('stock:$rawId', sanitize(item));
    await box.put(rawId, sanitize(item));
    await box.flush();
  }

  static Future<void> deleteLocalStockItem(String id) async {
    final box = Hive.box(stockBox);
    await box.delete('stock:$id');
    await box.delete(id);
    final normId = id.toLowerCase().trim();
    final toDelete = <dynamic>[];
    for (final key in box.keys) {
      final kStr = key.toString().toLowerCase();
      if (kStr == normId || kStr == 'stock:$normId' || kStr.endsWith(':$normId')) {
        toDelete.add(key);
      }
    }
    for (final k in toDelete) {
      await box.delete(k);
    }
    await box.flush();
  }

  static Future<int> clearLocalBranchStock(String branchId) async {
    final box = Hive.box(stockBox);
    final targetBranch = branchId.toLowerCase().trim();
    final keysToDelete = <dynamic>[];

    for (final key in box.keys) {
      final val = box.get(key);
      if (val is Map) {
        final bId = (val['branchId'] ?? '').toString().toLowerCase().trim();
        if (bId == targetBranch ||
            bId.contains('karachi') ||
            bId.contains('khi') ||
            targetBranch.contains('karachi') ||
            targetBranch.isEmpty ||
            bId.isEmpty) {
          keysToDelete.add(key);
        }
      } else {
        keysToDelete.add(key);
      }
    }

    for (final k in keysToDelete) {
      await box.delete(k);
    }
    await box.flush();
    return keysToDelete.length;
  }

  static Future<int> clearLocalCampStock(String branchId, String campId) async {
    final box = Hive.box(stockBox);
    final targetBranch = branchId.toLowerCase().trim();
    final targetCamp = campId.toLowerCase().trim();
    if (targetCamp == 'all' || targetCamp.isEmpty) return 0; // Strict safety guard!

    final keysToDelete = <dynamic>[];

    for (final key in box.keys) {
      final val = box.get(key);
      if (val is Map) {
        final bId = (val['branchId'] ?? '').toString().toLowerCase().trim();
        final matchesBranch = bId == targetBranch ||
            (targetBranch.contains('karachi') && bId.contains('karachi')) ||
            bId.isEmpty;
        if (!matchesBranch) continue;

        final matches = CampSessionService.matchesCamp(
          selectedCamp: targetCamp,
          dispensaryId: val['dispensaryId']?.toString(),
          campId: val['campId']?.toString(),
          dispensaryTag: val['dispensaryTag']?.toString(),
          serial: (val['barcode'] ?? val['code'] ?? val['id'] ?? key)?.toString(),
        );
        if (matches) {
          keysToDelete.add(key);
        }
      }
    }

    for (final k in keysToDelete) {
      await box.delete(k);
    }
    await box.flush();
    return keysToDelete.length;
  }

  static bool _isDummyCnicValue(String? cnic) {
    if (cnic == null || cnic.trim().isEmpty) return true;
    final clean = cnic.replaceAll(RegExp(r'[^0-9]'), '');
    if (clean.length < 9) return true;
    if (RegExp(r'^0+$').hasMatch(clean)) return true;
    if (RegExp(r'^1+$').hasMatch(clean)) return true;
    if (clean == '1234567890123' || clean == '0000000000000') return true;
    return false;
  }

  static String? getLastRecordedWeight(Map<String, dynamic>? patientData, {String? branchId}) {
    if (patientData == null || patientData.isEmpty) return null;

    final direct = (patientData['lastWeight'] ?? patientData['weight'] ?? patientData['vitals']?['weight'])?.toString().trim();
    if (direct != null && direct.isNotEmpty && direct != 'N/A' && direct != '0' && direct != '0.0' && direct != '-') {
      return direct;
    }

    try {
      final pid = (patientData['patientId'] ?? patientData['id'] ?? '').toString().toLowerCase().trim();
      final cnic = (patientData['cnic'] ?? patientData['patientCnic'] ?? '').toString().replaceAll(RegExp(r'[^\w]'), '').toLowerCase();
      final guardianCnic = (patientData['guardianCnic'] ?? '').toString().replaceAll(RegExp(r'[^\w]'), '').toLowerCase();
      final pName = (patientData['patientName'] ?? patientData['name'] ?? patientData['fullName'] ?? '').toString().toLowerCase().trim();
      final indId = resolveIndividualPatientId(patientData).toLowerCase().trim();
      final isAdult = patientData['isAdult'];
      final age = (patientData['age'] is num) ? (patientData['age'] as num).toInt() : (int.tryParse(patientData['age']?.toString() ?? '') ?? 0);
      final isChild = isAdult == false || guardianCnic.isNotEmpty || pid.contains('_child_') || (age > 0 && age < 20);

      // Require at least one valid identifying signal to prevent false matching
      final hasValidCnic = cnic.isNotEmpty && !_isDummyCnicValue(cnic);
      final hasValidGuard = guardianCnic.isNotEmpty && !_isDummyCnicValue(guardianCnic);
      final hasValidPid = pid.isNotEmpty && pid != 'unknown' && pid != 'null' && pid != '0';
      final hasValidIndId = indId.isNotEmpty && indId != 'unknown';

      if (!hasValidCnic && !hasValidGuard && !hasValidPid && !hasValidIndId) {
        return null;
      }

      bool isMatch(Map e) {
        final eIndId = resolveIndividualPatientId(Map<String, dynamic>.from(e)).toLowerCase().trim();
        if (hasValidIndId && eIndId.isNotEmpty && eIndId == indId) {
          return true;
        }

        final ePid = (e['patientId'] ?? e['id'] ?? '').toString().toLowerCase().trim();
        final eCnic = (e['patientCnic'] ?? e['cnic'] ?? '').toString().replaceAll(RegExp(r'[^\w]'), '').toLowerCase();
        final eGuard = (e['guardianCnic'] ?? '').toString().replaceAll(RegExp(r'[^\w]'), '').toLowerCase();
        final eName = (e['patientName'] ?? e['name'] ?? e['fullName'] ?? '').toString().toLowerCase().trim();

        if (hasValidPid && ePid.isNotEmpty && ePid == pid) {
          if (isChild) {
            if (pName.isNotEmpty && eName.isNotEmpty) {
              return eName == pName || eName.replaceAll(' ', '') == pName.replaceAll(' ', '');
            }
          }
          return true;
        }

        if (isChild) {
          if (hasValidGuard && eGuard == guardianCnic && pName.isNotEmpty && eName.isNotEmpty) {
            return eName == pName || eName.replaceAll(' ', '') == pName.replaceAll(' ', '');
          }
        } else {
          if (hasValidCnic && eCnic == cnic) {
            return true;
          }
        }
        return false;
      }

      String? extractWeight(Map e) {
        final v = e['vitals'];
        dynamic wt;
        if (v is Map) {
          wt = v['weight'] ?? v['receptionistVitals']?['weight'] ?? v['doctorVitals']?['weight'];
        }
        wt ??= e['weight'];
        wt ??= e['lastWeight'];
        final wtStr = wt?.toString().trim();
        if (wtStr != null && wtStr.isNotEmpty && wtStr != 'N/A' && wtStr != '0' && wtStr != '0.0' && wtStr != '-') {
          return wtStr;
        }
        return null;
      }

      // 1. Search in local_entries (tokens, newest first)
      if (Hive.isBoxOpen(entriesBox)) {
        final box = Hive.box(entriesBox);
        final values = box.values.toList();
        for (int i = values.length - 1; i >= 0; i--) {
          final val = values[i];
          if (val is Map && isMatch(val)) {
            final wt = extractWeight(val);
            if (wt != null) return wt;
          }
        }
      }

      // 2. Search in local_prescriptions (newest first)
      if (Hive.isBoxOpen(prescriptionsBox)) {
        final box = Hive.box(prescriptionsBox);
        final values = box.values.toList();
        for (int i = values.length - 1; i >= 0; i--) {
          final val = values[i];
          if (val is Map && isMatch(val)) {
            final wt = extractWeight(val);
            if (wt != null) return wt;
          }
        }
      }

      // 3. Search in local_patients
      if (Hive.isBoxOpen(patientsBox)) {
        final box = Hive.box(patientsBox);
        for (final val in box.values) {
          if (val is Map && isMatch(val)) {
            final wt = extractWeight(val);
            if (wt != null) return wt;
          }
        }
      }
    } catch (_) {}
    return null;
  }

  /// Parses structured composite keys / IDs into medicine properties:
  /// e.g. "hajicamp--diclofenac-sodium-voren--tablet--50-mg--2027-09-03"
  /// -> {name: "Diclofenac Sodium (Voren)", type: "Tablet", dose: "50 mg", expiryDate: "2027-09-03"}
  static Map<String, String>? healStockItemFromKeyOrId(String keyOrId) {
    var clean = keyOrId.trim();
    if (clean.startsWith('stock:')) clean = clean.substring(6).trim();
    final parts = clean.split('--');
    if (parts.length < 3) return null;

    String? expiry;
    String? dose;
    String? form;
    final nameParts = <String>[];

    for (int i = 0; i < parts.length; i++) {
      final p = parts[i].trim();
      final pLower = p.toLowerCase();
      if (i == 0 && (pLower == 'hajicamp' || pLower == 'haji' || pLower == 'saddar' || pLower == 'kapayya')) {
        continue;
      }
      if (i == 1 && (pLower == 'saddar' || pLower == 'kapayya' || pLower == 'hajicamp' || pLower == 'haji')) {
        continue;
      }
      if (RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(p) || RegExp(r'^\d{2}-\d{4}$').hasMatch(p) || RegExp(r'^\d{2}-\d{2}-\d{4}$').hasMatch(p)) {
        expiry = p;
        continue;
      }
      if (pLower == 'tablet' || pLower == 'capsule' || pLower == 'syrup' || pLower == 'injection' || pLower == 'suspension' || pLower == 'drops' || pLower == 'syringe' || pLower == 'infusion') {
        form = p.substring(0, 1).toUpperCase() + p.substring(1).toLowerCase();
        continue;
      }
      if (RegExp(r'^\d+-(mg|cc|ml|g|mcg|drop|drops|iu|unit|units|standard)$').hasMatch(pLower)) {
        dose = p.replaceAll('-', ' ');
        continue;
      }
      nameParts.add(p);
    }

    if (nameParts.isEmpty) return null;

    final rawSlug = nameParts.join(' ').replaceAll('-', ' ');
    final words = rawSlug.split(RegExp(r'\s+')).where((w) => w.isNotEmpty).map((w) => (w[0].toUpperCase() + w.substring(1))).join(' ');
    final cleanName = MasterProformaService.cleanBrandToFormula(words);
    return {
      'name': cleanName,
      'type': form ?? 'Medicine',
      'dose': dose ?? '',
      'expiryDate': expiry ?? '',
    };
  }

  static List<Map<String, dynamic>> getAllLocalStockItems(
      {String? branchId, String? dispensaryId, bool filterByCamp = true}) {
    if (!Hive.isBoxOpen(stockBox)) return [];

    final Map<String, Map<String, dynamic>> uniqueItems = {};
    for (final raw in Hive.box(stockBox).values) {
      if (raw is! Map) continue;
      final item = Map<String, dynamic>.from(raw);
      final rawId = (item['id'] ?? item['medicineId'] ?? item['docId'] ?? item['code'] ?? item['barcode'])?.toString().trim();

      // Auto-heal empty names from rawId / key
      var rawName = (item['name'] ?? item['formula'] ?? item['medicineName'] ?? '').toString().trim();
      if ((rawName.isEmpty || rawName.toLowerCase() == 'null') && rawId != null && rawId.isNotEmpty) {
        final healed = healStockItemFromKeyOrId(rawId);
        if (healed != null) {
          rawName = healed['name']!;
          item['name'] = rawName;
          item['formula'] = rawName;
          if ((item['type'] ?? '').toString().trim().isEmpty || item['type'].toString().toLowerCase() == 'null') {
            item['type'] = healed['type'];
          }
          if ((item['dose'] ?? '').toString().trim().isEmpty || item['dose'].toString().toLowerCase() == 'null') {
            item['dose'] = healed['dose'];
          }
          if ((item['expiryDate'] ?? '').toString().trim().isEmpty) {
            item['expiryDate'] = healed['expiryDate'];
          }
        }
      }

      // Filter out completely corrupt items with empty names so ghost items never appear!
      if (rawName.isEmpty || rawName.toLowerCase() == 'null') {
        continue;
      }

      // Ensure item['name'] and item['formula'] are always populated
      if (item['name'] == null || item['name'].toString().trim().isEmpty || item['name'].toString().toLowerCase() == 'null') {
        item['name'] = rawName;
      }
      if (item['formula'] == null || item['formula'].toString().trim().isEmpty || item['formula'].toString().toLowerCase() == 'null') {
        item['formula'] = rawName;
      }

      // Normalize brand to formula for stable deduplication
      final isCustom = item['isCustomized'] == true || item['userEdited'] == true;
      final cleanFormulaName = isCustom ? rawName : MasterProformaService.cleanBrandToFormula(rawName);
      final name = cleanFormulaName.toLowerCase().trim();
      final dose = (item['dose'] ?? '').toString().trim().toLowerCase();
      final type = (item['type'] ?? item['dosageForm'] ?? item['form'] ?? '').toString().trim().toLowerCase();
      final camp = (item['campId'] ?? item['dispensaryId'] ?? '').toString().trim().toLowerCase();

      // Normalize camp tag for Haji Camp partitioned items
      final rawIdLower = rawId?.toLowerCase() ?? '';
      if (rawIdLower.startsWith('hajicamp--') || rawIdLower.startsWith('stock:hajicamp--') || camp == 'haji_camp') {
        if (item['campId'] != 'haji_camp') item['campId'] = 'haji_camp';
        if (item['dispensaryId'] != 'haji_camp') item['dispensaryId'] = 'haji_camp';
        if (item['dispensaryTag'] == 'SADD' || item['dispensaryTag'] == 'KAP') {
          item['dispensaryTag'] = 'HAJI';
        }
      }

      final expiry = (item['expiryDate'] ?? '').toString().trim();
      String monthYear = '';
      if (expiry.length == 10 && expiry[2] == '-' && expiry[5] == '-') {
        monthYear = expiry.substring(3);
      } else {
        monthYear = expiry;
      }

      // Deduplicate by clean batch composite key: name + type + dose + monthYear + camp.
      // This prevents ghost copies (created under different docId variations) from appearing as duplicates
      // and causing double counting in stock quantities!
      final batchKey = '$name|$type|$dose|$monthYear|$camp';
      final dedupKey = (name.isNotEmpty && type.isNotEmpty)
          ? 'batch:$batchKey'
          : ((rawId != null && rawId.isNotEmpty && rawId != 'unknown' && rawId != 'null')
              ? 'id:${rawId.toLowerCase()}'
              : 'composite:$batchKey');

      if (!uniqueItems.containsKey(dedupKey)) {
        uniqueItems[dedupKey] = item;
      } else {
        final existing = uniqueItems[dedupKey]!;
        final existingQty = (existing['quantity'] as num?)?.toDouble() ?? 0.0;
        final newQty = (item['quantity'] as num?)?.toDouble() ?? 0.0;
        final existingUp = existing['updatedAt'] ?? existing['lastUpdated'];
        final newUp = item['updatedAt'] ?? item['lastUpdated'];

        bool itemIsNewer = false;
        if (newUp != null && existingUp != null) {
          final nDt = DateTime.tryParse(newUp.toString());
          final eDt = DateTime.tryParse(existingUp.toString());
          if (nDt != null && eDt != null) {
            itemIsNewer = nDt.isAfter(eDt);
          }
        } else if (newUp != null && existingUp == null) {
          itemIsNewer = true;
        }

        if (itemIsNewer) {
          uniqueItems[dedupKey] = item;
        } else if (existingUp == null && newUp == null && newQty > 0 && existingQty == 0) {
          uniqueItems[dedupKey] = item;
        }
      }
    }

    var items = uniqueItems.values.toList();
    if (branchId != null && branchId.isNotEmpty) {
      final norm = branchId.toLowerCase().trim();
      items = items.where((i) {
        final b = i['branchId']?.toString().toLowerCase().trim();
        if (b == null || b.isEmpty) return true; // Branch stock fallback
        if (CampSessionService.areBranchesMatching(norm, b)) return true;
        if (CampSessionService.isKarachiFamily(norm) && (b.isEmpty || CampSessionService.isKarachiFamily(b))) return true;
        return b == norm ||
            b == 'branch_$norm' ||
            'branch_$b' == norm ||
            (norm.isNotEmpty && b.contains(norm)) ||
            (b.isNotEmpty && norm.contains(b));
      }).toList();
    }
    if (filterByCamp && CampSessionService.hasCampsForBranch(branchId)) {
      final activeCamp = (dispensaryId != null && dispensaryId.isNotEmpty && dispensaryId.toLowerCase() != 'all')
          ? dispensaryId.toLowerCase().trim()
          : CampSessionService.getActiveCamp(branchId);

      if (activeCamp != null && activeCamp.isNotEmpty && activeCamp != 'all') {
        final campFiltered = items.where((i) {
          return CampSessionService.matchesCamp(
            selectedCamp: activeCamp,
            dispensaryId: i['dispensaryId']?.toString(),
            campId: i['campId']?.toString(),
            dispensaryTag: i['dispensaryTag']?.toString(),
            serial: (i['barcode'] ?? i['code'] ?? i['id'])?.toString(),
          );
        }).toList();
        items = campFiltered;
      }
    }
    return items.map((i) {
      final isCustom = i['isCustomized'] == true || i['userEdited'] == true;
      if (isCustom) return i;
      final name = i['name']?.toString() ?? '';
      final formula = i['formula']?.toString() ?? '';
      final cleanN = MasterProformaService.cleanBrandToFormula(name);
      final cleanF = MasterProformaService.cleanBrandToFormula(formula);
      if (cleanN != name || cleanF != formula) {
        final copy = Map<String, dynamic>.from(i);
        copy['name'] = cleanN;
        copy['formula'] = cleanF;
        return copy;
      }
      return i;
    }).toList();
  }

  // ─── Inventory Audit Logs ───────────────────────────────────────────────────

  static Future<void> saveLocalInventoryLog(Map<String, dynamic> logData) async {
    try {
      if (!Hive.isBoxOpen(auditLogsBox)) {
        await Hive.openBox(auditLogsBox);
      }
      final box = Hive.box(auditLogsBox);
      final id = logData['id'] ?? logData['docId'] ?? const Uuid().v4();
      final key = 'inv_log_$id';
      await box.put(key, sanitize({
        ...logData,
        'id': id,
        'savedAt': DateTime.now().toIso8601String(),
      }));
      debugPrint('[LocalStorageService] 📝 Saved local inventory audit log: $key (${logData['action']})');
    } catch (e) {
      debugPrint('[LocalStorageService] Error saving local inventory log: $e');
    }
  }

  static List<Map<String, dynamic>> getLocalInventoryLogs({String? branchId, String? medicineId}) {
    try {
      if (!Hive.isBoxOpen(auditLogsBox)) return [];
      final box = Hive.box(auditLogsBox);
      final logs = <Map<String, dynamic>>[];
      for (final k in box.keys) {
        if (k.toString().startsWith('inv_log_')) {
          final val = box.get(k);
          if (val is Map) {
            final map = Map<String, dynamic>.from(val);
            if (branchId != null && branchId.isNotEmpty && branchId != 'default') {
              final b = (map['branchId'] ?? '').toString().trim().toLowerCase();
              if (b.isNotEmpty && b != 'default' && b != branchId.toLowerCase()) continue;
            }
            if (medicineId != null && medicineId.isNotEmpty) {
              final mId = (map['medicineId'] ?? map['docId'] ?? '').toString().trim();
              if (mId != medicineId) continue;
            }
            logs.add(map);
          }
        }
      }
      logs.sort((a, b) => (b['createdAt'] ?? b['timestamp'] ?? '').toString().compareTo((a['createdAt'] ?? a['timestamp'] ?? '').toString()));
      return logs;
    } catch (_) {
      return [];
    }
  }

  // ════════════════════════════════════════════════════════════════════════════
  // DISPENSARY
  // ════════════════════════════════════════════════════════════════════════════

  static Future<void> saveLocalDispensaryRecord(
      Map<String, dynamic> record) async {
    final branchId = (record['branchId'] ?? '').toString().toLowerCase().trim();
    final serialRaw = (record['serial'] ?? record['id'] ?? '').toString().trim();
    if (branchId.isEmpty || serialRaw.isEmpty) return;

    var cleanSerial = serialRaw;
    if (cleanSerial.toLowerCase().startsWith('$branchId-')) {
      cleanSerial = cleanSerial.substring(branchId.length + 1).trim();
    }
    final normSerialUpper = cleanSerial.toUpperCase();
    final normSerialLower = cleanSerial.toLowerCase();
    final canonicalKey = '$branchId-$normSerialUpper';
    final dateKey = (record['dateKey'] ?? getTodayDateKey()).toString();

    // Purge any legacy standalone records from dispensaryBox
    if (Hive.isBoxOpen(dispensaryBox)) {
      final dBox = Hive.box(dispensaryBox);
      await dBox.deleteAll([
        '${branchId}_${dateKey}_$cleanSerial',
        '${branchId}_${dateKey}_$normSerialUpper',
        '${branchId}_${dateKey}_$normSerialLower',
        '$branchId-$normSerialUpper',
        '$branchId-$normSerialLower',
        cleanSerial,
        normSerialUpper,
        normSerialLower,
      ]);
    }

    // Save directly into entriesBox (the canonical serial store)
    final entriesBoxRef = await ensureBoxOpen(entriesBox);
    final existing = entriesBoxRef.get(canonicalKey) ??
        entriesBoxRef.get(normSerialUpper) ??
        entriesBoxRef.get(normSerialLower) ??
        entriesBoxRef.get(cleanSerial);

    if (existing == null) {
      final pName = (record['patientName'] ?? record['name'] ?? '').toString().trim().toLowerCase();
      final pCnic = (record['patientCnic'] ?? record['cnic'] ?? '').toString().trim();
      if ((pName.isEmpty || pName == 'unknown patient' || pName == 'unknown') &&
          (pCnic.isEmpty || pCnic.startsWith('unknown_cnic_'))) {
        return;
      }
    }

    final updatedEntry = existing is Map
        ? Map<String, dynamic>.from(existing)
        : Map<String, dynamic>.from(record);

    updatedEntry['serial'] = cleanSerial;
    updatedEntry['id'] = cleanSerial;
    updatedEntry['branchId'] = branchId;
    if (record['dateKey'] != null) updatedEntry['dateKey'] = record['dateKey'];
    if (record['queueType'] != null) updatedEntry['queueType'] = record['queueType'];

    updatedEntry['dispenseStatus'] = 'dispensed';
    updatedEntry['status'] = 'completed';
    updatedEntry['pendingSync'] = true;
    updatedEntry['synced'] = false;
    updatedEntry['syncStatus'] = 'pending';
    if (record['dispensedAt'] != null) updatedEntry['dispensedAt'] = record['dispensedAt'];
    if (record['dispensedBy'] != null) updatedEntry['dispensedBy'] = record['dispensedBy'];
    if (record['dispenserName'] != null) updatedEntry['dispenserName'] = record['dispenserName'];
    if (record['charges'] != null) updatedEntry['charges'] = record['charges'];
    if (record['receivedAmount'] != null) updatedEntry['receivedAmount'] = record['receivedAmount'];
    if (record['extraCharge'] != null) updatedEntry['extraCharge'] = record['extraCharge'];
    if (record['daysOfMedicine'] != null) updatedEntry['daysOfMedicine'] = record['daysOfMedicine'];
    if (record['medicines'] != null) {
      updatedEntry['medicines'] = record['medicines'];
      updatedEntry['prescriptions'] ??= record['medicines'];
    }

    final sanitized = sanitize(updatedEntry);
    await entriesBoxRef.put(canonicalKey, sanitized);
    await entriesBoxRef.put(normSerialUpper, sanitized);
    await entriesBoxRef.put(normSerialLower, sanitized);
    await entriesBoxRef.flush();
  }

  static Map<String, dynamic>? getLocalDispensaryRecord(
      String branchId, String serial, {String? dateKey}) {
    branchId = branchId.toLowerCase().trim();
    var cleanSerial = serial.trim();
    if (cleanSerial.toLowerCase().startsWith('$branchId-')) {
      cleanSerial = cleanSerial.substring(branchId.length + 1).trim();
    }
    final normSerialUpper = cleanSerial.toUpperCase();

    // Primary: check entriesBox directly
    if (Hive.isBoxOpen(entriesBox)) {
      final eBox = Hive.box(entriesBox);
      final val = eBox.get('$branchId-$normSerialUpper') ??
          eBox.get(normSerialUpper) ??
          eBox.get(cleanSerial.toLowerCase());
      if (val is Map) {
        final map = Map<String, dynamic>.from(val);
        final dStatus = (map['dispenseStatus'] ?? map['status'] ?? '').toString().toLowerCase();
        if (dStatus == 'dispensed' || dStatus == 'completed') {
          return map;
        }
      }
    }

    // Fallback: legacy dispensaryBox
    if (Hive.isBoxOpen(dispensaryBox)) {
      final dk  = dateKey ?? getTodayDateKey();
      final val = Hive.box(dispensaryBox).get('${branchId}_${dk}_$cleanSerial') ??
          Hive.box(dispensaryBox).get('${branchId}_${dk}_$normSerialUpper') ??
          Hive.box(dispensaryBox).get('$branchId-$normSerialUpper') ??
          Hive.box(dispensaryBox).get(normSerialUpper);
      if (val is Map) return Map<String, dynamic>.from(val);
    }
    return null;
  }

  static List<Map<String, dynamic>> getLocalDispensaryRecords(
      String branchId, {String? dateKey}) {
    branchId = branchId.toLowerCase().trim();
    final dk = dateKey ?? getTodayDateKey();

    // Primary: check entriesBox directly
    if (Hive.isBoxOpen(entriesBox)) {
      final eBox = Hive.box(entriesBox);
      final List<Map<String, dynamic>> list = [];
      final seenSerials = <String>{};

      for (final val in eBox.values) {
        if (val is Map) {
          final b = (val['branchId'] ?? '').toString().toLowerCase().trim();
          final d = (val['dateKey'] ?? '').toString().trim();
          final s = (val['serial'] ?? val['id'] ?? '').toString().trim().toUpperCase();
          final dStatus = (val['dispenseStatus'] ?? val['status'] ?? '').toString().toLowerCase();

          if (s.isNotEmpty && (b.isEmpty || b == branchId) && (d.isEmpty || d == dk) &&
              (dStatus == 'dispensed' || dStatus == 'completed')) {
            if (seenSerials.add(s)) {
              list.add(Map<String, dynamic>.from(val));
            }
          }
        }
      }
      if (list.isNotEmpty) return list;
    }

    // Fallback: legacy dispensaryBox
    if (Hive.isBoxOpen(dispensaryBox)) {
      final prefix = '${branchId}_${dk}_';
      return Hive.box(dispensaryBox)
          .keys
          .where((k) => k.toString().startsWith(prefix))
          .map((k) => Map<String, dynamic>.from(
              Hive.box(dispensaryBox).get(k) as Map))
          .toList();
    }
    return [];
  }

  // ════════════════════════════════════════════════════════════════════════════
  // BRANCHES
  // ════════════════════════════════════════════════════════════════════════════

  static Future<void> saveLocalBranch(Map<String, dynamic> branch) async {
    final id = branch['id']?.toString();
    if (id == null) return;
    await Hive.box(branchesBox).put('branch:$id', sanitize(branch));
  }

  static Future<void> deleteLocalBranch(String id) async =>
      Hive.box(branchesBox).delete('branch:$id');

  static List<Map<String, dynamic>> getLocalBranches() => getLocalBranchesList();

  static List<Map<String, dynamic>> getLocalBranchesList() {
    if (!Hive.isBoxOpen(branchesBox)) return const <Map<String, dynamic>>[];

    final box = Hive.box(branchesBox);
    final branches = <Map<String, dynamic>>[];
    final seen = <String>{};

    for (final raw in box.values) {
      if (raw is! Map) continue;
      final data = Map<String, dynamic>.from(raw);
      final id = (data['id'] ?? data['branchId'] ?? '').toString().trim();
      if (id.isEmpty) continue;
      final normalized = id.toLowerCase();
      if (seen.contains(normalized)) continue;
      seen.add(normalized);
      branches.add({
        'id': id,
        'name': (data['name'] ?? data['branchName'] ?? data['title'] ?? id).toString(),
      });
    }

    return branches;
  }

  // ════════════════════════════════════════════════════════════════════════════
  // FIRESTORE DOWNLOAD HELPERS
  // ════════════════════════════════════════════════════════════════════════════

  static Future<void> downloadAllPatients(String branchId) async {
    branchId = branchId.toLowerCase().trim();
    try {
      final snapshot = await FirebaseFirestore.instance
          .collection('branches')
          .doc(branchId)
          .collection('patients')
          .get();
      final patients = snapshot.docs.map((doc) {
        final d = doc.data();
        d['patientId'] = doc.id;
        d['branchId']  = branchId;
        return d;
      }).toList();
      await saveAllLocalPatients(patients);

      final flagsBox = Hive.box('app_flags');
      final Map<String, dynamic> flagEntries = {};
      for (final doc in snapshot.docs) {
        flagEntries['patient_synced_${doc.id}'] = true;
      }
      if (flagEntries.isNotEmpty) {
        await flagsBox.putAll(flagEntries);
      }
    } catch (e) {
      debugPrint('[LocalStorage] downloadAllPatients error: $e');
    }
  }

  static DateTime? _lastTodayTokensDownloadTime;
  static const Duration _tokensDownloadCooldown = Duration(minutes: 5);

  static Future<void> downloadTodayTokens(String branchId, [String? campId, bool force = false]) async {
    if (LanFirestoreGate.isLanDesk) return; // a dispensary desk on the LAN gets this from the LAN server
    // FIX 2: normalize branchId FIRST — this is the primary method Fix 2
    // targets. Every Hive key built below ('$branchId-...') previously used
    // whatever casing the caller passed, while saveEntryLocal() always
    // lowercases, so a differently-cased caller here would miss the real
    // local record and let stale server data silently overwrite a
    // completed/dispensed token's protected status.
    branchId = branchId.toLowerCase().trim();
    if (branchId.isEmpty) return;

    // Offline Guard: Never attempt cloud download if host has no stable internet connection
    if (NetworkHealthService().isOffline || !NetworkHealthService().isStableOnline) {
      debugPrint('[LocalStorage] No stable cloud connection — skipping cloud downloadTodayTokens');
      return;
    }

    // Zero-Quota Guard: If connected to LAN server, live tokens arrive via WebSocket unless explicitly forced
    if (!force && RealtimeManager().hasServerLink) {
      debugPrint('[LocalStorage] LAN server is connected — skipping direct cloud downloadTodayTokens');
      return;
    }

    // Cooldown Guard: Prevent compulsive screen reloads from hammering Firestore
    final now = DateTime.now();
    if (!force && _lastTodayTokensDownloadTime != null && now.difference(_lastTodayTokensDownloadTime!) < _tokensDownloadCooldown) {
      debugPrint('[LocalStorage] Skipping downloadTodayTokens: within ${_tokensDownloadCooldown.inMinutes}m cooldown');
      return;
    }
    _lastTodayTokensDownloadTime = now;

    final today = getTodayDateKey();
    final box   = await ensureBoxOpen(entriesBox);
    final targetCamp = campId ?? CampSessionService.getActiveCamp(branchId);

    try {
      final dateDocs = CampSessionService.getAllCampDateDocIds(
        branchId: branchId,
        dateKey: today,
        selectedCamp: targetCamp,
      );

      final Map<String, Map<String, dynamic>> freshEntries = {};
      final List<DocumentReference> duplicateDocsToDelete = [];

      for (final docDateKey in dateDocs) {
        final serialsRef = FirebaseFirestore.instance
            .collection('branches')
            .doc(branchId)
            .collection('serials')
            .doc(docDateKey);

        final isKarachi = branchId.contains('karachi') || branchId.contains('haji') || branchId.contains('saddar') || branchId.contains('kapaya');
        final typesToDownload = isKarachi
            ? ['zakat', '20', 'non-zakat', 'gmwf']
            : ['zakat', 'non-zakat', 'gmwf'];

        for (final type in typesToDownload) {
          try {
            final snap = await serialsRef.collection(type).get().timeout(const Duration(seconds: 4));
          for (final doc in snap.docs) {
            final rawId = doc.id.trim();
            final upperId = rawId.toUpperCase();
            final isLowercase = (rawId != upperId);

            final d = Map<String, dynamic>.from(doc.data());
            d['serial']    = upperId;
            d['dateKey']   = today;
            d['branchId']  = branchId;
            d['queueType'] = (type == '20' || (isKarachi && (type == 'non-zakat' || type.contains('non')))) ? 'zakat' : type;
            if (upperId.contains('-SADD-') || upperId.contains('-KAP-') || upperId.contains('-KAPAYYA-')) {
              d['dispensaryId'] = 'saddar';
              d['campId']       = 'saddar';
              d['dispensaryTag'] = 'SADD';
            } else if (upperId.contains('-HAJI-') || upperId.contains('-HAJ-') || upperId.contains('-HC-')) {
              d['dispensaryId'] = 'haji_camp';
              d['campId']       = 'haji_camp';
              d['dispensaryTag'] = 'HAJI';
            } else if (d['dispensaryTag'] == null || d['dispensaryTag'].toString().trim().isEmpty) {
              final parts = upperId.split('-');
              if (parts.length >= 3) {
                d['dispensaryTag'] = parts[1].toUpperCase();
              }
            }

            final hiveKey = '$branchId-$upperId';

            if (freshEntries.containsKey(hiveKey)) {
              // Merge data into canonical uppercase entry
              final existingData = freshEntries[hiveKey]!;
              if (d['prescription'] != null && existingData['prescription'] == null) {
                existingData['prescription'] = d['prescription'];
                existingData['prescriptionId'] = d['prescriptionId'];
              }
              if (d['prescriptions'] != null && existingData['prescriptions'] == null) {
                existingData['prescriptions'] = d['prescriptions'];
              }
              if (d['status'] == 'completed' || d['status'] == 'dispensed') {
                existingData['status'] = d['status'];
              }
              if (isLowercase) {
                duplicateDocsToDelete.add(doc.reference);
              }
            } else {
              freshEntries[hiveKey] = d;
              if (isLowercase) {
                duplicateDocsToDelete.add(doc.reference);
              }
            }
          }
        } catch (_) {}
      }
    }

      // Cleanup duplicate lowercase docs from Firestore to save cloud space & quota
      for (final docRef in duplicateDocsToDelete) {
        try {
          // An SDK write only completes once the server acknowledges it; offline it never would.
          await docRef.delete().timeout(const Duration(seconds: 8));
          debugPrint('[LocalStorage] 🧹 Cleaned duplicate lowercase doc from Firestore: ${docRef.path}');
        } catch (_) {}
      }

      const terminalStatuses = ['completed', 'dispensed', 'cancelled', 'rejected'];
      final Map<String, dynamic> tokensToPut = {};
      for (final entry in freshEntries.entries) {
        final hiveKey  = entry.key;
        final fresh    = entry.value;
        final existing = box.get(hiveKey);
        Map<String, dynamic> merged = sanitize(fresh);
        if (existing is Map) {
          final ex = Map<String, dynamic>.from(existing);
          final localStatus  = ex['status']?.toString() ?? '';
          final mergedStatus = merged['status']?.toString() ?? '';
          final exDisp = (ex['dispensaryId'] ?? ex['campId'])?.toString().trim();
          if (exDisp != null && exDisp.isNotEmpty) {
            merged['dispensaryId'] = (merged['dispensaryId']?.toString().isNotEmpty == true) ? merged['dispensaryId'] : exDisp;
            merged['campId']       = (merged['campId']?.toString().isNotEmpty == true)       ? merged['campId']       : exDisp;
          }
          final isIncomingCancellation = mergedStatus == 'cancelled' || mergedStatus == 'rejected';
          if (isIncomingCancellation) {
            merged['status'] = mergedStatus;
          } else if (terminalStatuses.contains(localStatus) &&
              !terminalStatuses.contains(mergedStatus)) {
            merged['status'] = localStatus;
          }
          if (ex['dispenseStatus']?.toString() == 'dispensed') {
            merged['dispenseStatus'] = 'dispensed';
            if (ex['dispensedAt'] != null) merged['dispensedAt'] = ex['dispensedAt'];
            if (ex['dispensedBy'] != null) merged['dispensedBy'] = ex['dispensedBy'];
          }
          // The cloud copy can lag (upload queue, quota) behind the prescription this PC has:
          // keep the local one unless the cloud's is newer and has medicines.
          final keptRx = preferredPrescription(merged['prescription'], ex['prescription']);
          if (keptRx != null) {
            if (!identical(keptRx, merged['prescription']) && merged['prescription'] == null) {
              merged['prescriptionId'] = ex['prescriptionId'];
            }
            merged['prescription'] = keptRx;
            _alignTopLevelMedicines(merged, ex);
          }
          // Preserve local session override
          if (ex['session'] != null && ex['session'].toString().trim().isNotEmpty) {
            merged['session'] = ex['session'];
          }
          if (ex['sessionUpdatedAt'] != null) merged['sessionUpdatedAt'] = ex['sessionUpdatedAt'];
          if (ex['realignedAt'] != null) merged['realignedAt'] = ex['realignedAt'];
          for (final field in [
            'patientName', 'name', 'fullName', 'patientCnic', 'cnic', 'guardianName',
            'guardianCnic', 'patientAge', 'age', 'patientGender', 'gender',
            'queueType', 'visitReason', 'isVitalsOnly', 'vitalsOnly',
            'suggestedDays', 'phone', 'contactPhone', 'address', 'patientId', 'id',
            'dispenserName', 'completedAt', 'createdBy', 'createdByName', 'session'
          ]) {
            final curVal = merged[field];
            final oldVal = ex[field];
            final curStr = curVal?.toString().trim().toLowerCase() ?? '';
            final oldStr = oldVal?.toString().trim().toLowerCase() ?? '';
            final isCurEmpty = curVal == null || curStr.isEmpty || curStr == 'null' || curStr == 'unknown' || curStr == 'unknown patient' || curStr == 'n/a' || curStr == '-';
            final isOldValid = oldVal != null && oldStr.isNotEmpty && oldStr != 'null' && oldStr != 'unknown' && oldStr != 'unknown patient' && oldStr != 'n/a' && oldStr != '-';
            if (isCurEmpty && isOldValid) {
              merged[field] = oldVal;
            } else if (isOldValid && (field == 'patientName' || field == 'name')) {
              // Token Name Immutability: Existing verified name (child or parent) is preserved
              merged[field] = oldVal;
            }
          }
        }

        // Auto-resolve patient name from local_patients or prescription if still missing
        final mNameStr = (merged['patientName'] ?? merged['name'] ?? merged['fullName'])?.toString().trim().toLowerCase() ?? '';
        if (mNameStr.isEmpty || mNameStr == 'null' || mNameStr == 'unknown' || mNameStr == 'unknown patient') {
          final pId = (merged['patientId'] ?? merged['id'] ?? '').toString().trim();
          final isEntryAdult = merged['isAdult'] is bool
              ? merged['isAdult'] as bool
              : (!pId.contains('_child_') && (merged['guardianCnic']?.toString().trim().isEmpty ?? true));
          final pCnic = (merged['patientCnic'] ?? merged['cnic'] ?? merged['guardianCnic'] ?? '').toString().trim();
          if (pId.isNotEmpty) {
            final lp = getLocalPatient(pId);
            final lpName = (lp?['name'] ?? lp?['patientName'] ?? lp?['fullName'])?.toString().trim();
            if (lpName != null && lpName.isNotEmpty && lpName.toLowerCase() != 'null' && lpName.toLowerCase() != 'unknown' && lpName.toLowerCase() != 'unknown patient') {
              merged['patientName'] = lpName;
              merged['name'] = lpName;
            }
          }
          final mNameAfterPid = (merged['patientName'] ?? '').toString().trim().toLowerCase();
          if (isEntryAdult && (mNameAfterPid.isEmpty || mNameAfterPid == 'null' || mNameAfterPid == 'unknown' || mNameAfterPid == 'unknown patient') && pCnic.isNotEmpty) {
            final lp = getLocalPatientByCnic(pCnic);
            final lpName = (lp?['name'] ?? lp?['patientName'] ?? lp?['fullName'])?.toString().trim();
            if (lpName != null && lpName.isNotEmpty && lpName.toLowerCase() != 'null' && lpName.toLowerCase() != 'unknown' && lpName.toLowerCase() != 'unknown patient') {
              merged['patientName'] = lpName;
              merged['name'] = lpName;
            }
          }
        }

        // Cross-check local prescription in prescriptionsBox to ensure completed status is never reverted
        final serial = (merged['serial'] ?? fresh['serial'])?.toString() ?? '';
        if (serial.isNotEmpty) {
          final localPresc = getLocalPrescription(serial);
          if (localPresc != null) {
            merged['status'] = 'completed';
            merged['prescription'] = localPresc;
            merged['prescriptionId'] = localPresc['id'] ?? serial;
            if (localPresc['completedAt'] != null && merged['completedAt'] == null) {
              merged['completedAt'] = localPresc['completedAt'];
            }
            if (localPresc['doctorName'] != null && merged['doctorName'] == null) {
              merged['doctorName'] = localPresc['doctorName'];
            }
            if (localPresc['doctorId'] != null && merged['doctorId'] == null) {
              merged['doctorId'] = localPresc['doctorId'];
            }
            if (localPresc['daysOfMedicine'] != null && merged['daysOfMedicine'] == null) {
              merged['daysOfMedicine'] = localPresc['daysOfMedicine'];
            }
          }
        }

        tokensToPut[hiveKey] = merged;
      }
      if (tokensToPut.isNotEmpty) {
        await box.putAll(tokensToPut);
      }
      await box.flush();
    } catch (e) {
      debugPrint('[LocalStorage] downloadTodayTokens error: $e');
    }
  }

  static final Map<String, DateTime> _lastDasterkhwaanDownloadTimes = {};
  static const Duration _dasterkhwaanDownloadCooldown = Duration(minutes: 2);

  /// Downloads recent Dasterkhwaan food tokens for a branch from Firestore
  /// and caches them into Hive box `dasterkhwaan_tokens`.
  static Future<void> downloadDasterkhwaanTokens(String branchId, {int days = 7, bool force = false}) async {
    if (LanFirestoreGate.isLanDesk) return; // a dispensary desk on the LAN gets this from the LAN server
    final sanitizedBranch = sanitizeBranchId(branchId);
    if (!isValidBranchId(sanitizedBranch)) return;

    final now = DateTime.now();
    final lastTime = _lastDasterkhwaanDownloadTimes[sanitizedBranch];
    if (!force && lastTime != null && now.difference(lastTime) < _dasterkhwaanDownloadCooldown) {
      debugPrint('[LS] Skipping downloadDasterkhwaanTokens for $sanitizedBranch: within ${_dasterkhwaanDownloadCooldown.inMinutes}m cooldown');
      return;
    }
    _lastDasterkhwaanDownloadTimes[sanitizedBranch] = now;

    try {
      final box = await openBoxSafe('dasterkhwaan_tokens');
      final dateFmt = DateFormat('yyyy-MM-dd');

      for (int i = 0; i < days; i++) {
        final d = now.subtract(Duration(days: i));
        final dateKey = dateFmt.format(d);

        try {
          final snap = await FirebaseFirestore.instance
              .collection('branches')
              .doc(sanitizedBranch)
              .collection('dasterkhwaan')
              .doc(dateKey)
              .collection('tokens')
              .get()
              .timeout(const Duration(seconds: 8));

          if (snap.docs.isEmpty) continue;

          final Map<String, dynamic> toPut = {};
          for (final doc in snap.docs) {
            final data = doc.data();
            final docId = (data['localId'] ?? doc.id).toString();
            final numVal = (data['number'] as num?)?.toInt() ?? 0;
            final isServed = data['served'] == true;
            final session = (data['session'] ?? 'lunch').toString();
            final issuedBy = (data['issuedBy'] ?? '').toString();
            final timeStr = data['time'] is Timestamp
                ? (data['time'] as Timestamp).toDate().toIso8601String()
                : (data['time']?.toString() ?? now.toIso8601String());

            final existing = box.get(docId);
            if (existing is Map && existing['syncStatus'] == 'pending') {
              // Don't overwrite locally pending tokens awaiting upload
              continue;
            }

            toPut[docId] = {
              'id': docId,
              'localId': docId,
              'number': numVal,
              'time': timeStr,
              'served': isServed,
              'session': session,
              'branchId': sanitizedBranch,
              'dateKey': dateKey,
              'issuedBy': issuedBy,
              // The uploaded price, else this PC's copy, else the old default.
              'pricePerToken': (data['pricePerToken'] as num?)?.toDouble() ??
                  (existing is Map ? (existing['pricePerToken'] as num?)?.toDouble() : null) ??
                  10.0,
              'syncStatus': 'synced',
              'synced': true,
            };
          }

          if (toPut.isNotEmpty) {
            await box.putAll(toPut);
          }
        } catch (e) {
          debugPrint('[LS] downloadDasterkhwaanTokens for $dateKey error: $e');
        }
      }
      await box.flush();
      debugPrint('[LS] downloadDasterkhwaanTokens completed for $sanitizedBranch');
    } catch (e) {
      debugPrint('[LS] downloadDasterkhwaanTokens error: $e');
    }
  }

  static DateTime? _lastDasterkhwaanFoodLogsDownloadTime;
  static const Duration _dasterkhwaanFoodLogsDownloadCooldown = Duration(minutes: 5);

  /// Downloads recent Dasterkhwaan food logs for a branch from Firestore
  /// and caches them into Hive box `dasterkhwaan_food_logs`.
  static Future<void> downloadDasterkhwaanFoodLogs(String branchId, {int days = 14, bool force = false}) async {
    final sanitizedBranch = sanitizeBranchId(branchId);
    if (!isValidBranchId(sanitizedBranch)) return;

    final now = DateTime.now();
    if (!force && _lastDasterkhwaanFoodLogsDownloadTime != null && now.difference(_lastDasterkhwaanFoodLogsDownloadTime!) < _dasterkhwaanFoodLogsDownloadCooldown) {
      debugPrint('[LS] Skipping downloadDasterkhwaanFoodLogs: within cooldown');
      return;
    }
    _lastDasterkhwaanFoodLogsDownloadTime = now;

    try {
      final box = await openBoxSafe(dasterkhwaanFoodLogsBox);
      final dateFmt = DateFormat('yyyy-MM-dd');
      final cutoffDate = dateFmt.format(now.subtract(Duration(days: days)));

      final snap = await FirebaseFirestore.instance
          .collection('branches')
          .doc(sanitizedBranch)
          .collection('dasterkhwaan_food_logs')
          .where('dateKey', isGreaterThanOrEqualTo: cutoffDate)
          .get()
          .timeout(_cloudReadTimeout);

      final Map<dynamic, dynamic> toPut = {};
      for (final doc in snap.docs) {
        final data = doc.data();
        final id = doc.id;
        final existing = box.get(id);
        if (existing is Map && existing['syncStatus'] == 'pending') {
          continue; // Don't overwrite locally pending logs
        }
        final map = Map<String, dynamic>.from(data);
        map['id'] = id;
        map['synced'] = true;
        map['syncStatus'] = 'synced';
        toPut[id] = map;
      }
      if (toPut.isNotEmpty) {
        await box.putAll(toPut);
      }
      await box.flush();
      debugPrint('[LS] downloadDasterkhwaanFoodLogs completed: ${toPut.length} records for $sanitizedBranch');
    } catch (e) {
      debugPrint('[LS] downloadDasterkhwaanFoodLogs error: $e');
    }
  }

  static DateTime? _lastInventoryDownloadTime;
  static const Duration _inventoryDownloadCooldown = Duration(minutes: 5);

  /// Upper bound for one background Firestore read (downloads, catch-ups).
  static const Duration _cloudReadTimeout = Duration(seconds: 45);

  static Future<void> downloadInventory(String branchId, {bool forceFull = false, String? campId}) async {
    if (LanFirestoreGate.isLanDesk) return; // a dispensary desk on the LAN gets this from the LAN server
    branchId = branchId.toLowerCase().trim();
    if (branchId.isEmpty) return;

    // Zero-Quota Guard: If connected to LAN server, live stock updates arrive via WebSocket
    if (!forceFull && RealtimeManager().hasServerLink) {
      debugPrint('[LocalStorage] LAN server is connected — skipping direct cloud downloadInventory');
      return;
    }

    final now = DateTime.now();
    if (!forceFull && _lastInventoryDownloadTime != null && now.difference(_lastInventoryDownloadTime!) < _inventoryDownloadCooldown) {
      debugPrint('[LocalStorage] Skipping downloadInventory: within ${_inventoryDownloadCooldown.inMinutes}m cooldown');
      return;
    }
    _lastInventoryDownloadTime = now;
    try {
      final invPaths = CampSessionService.getAllCampInventoryPaths(
        branchId: branchId,
        selectedCamp: campId ?? CampSessionService.getActiveCamp(),
      );

      final effectiveFirestoreBranch = CampSessionService.isKarachiFamily(branchId) ? 'karachi' : branchId;

      for (final invCol in invPaths) {
        final syncKey = 'inventory_${branchId}_$invCol';
        final lastSyncedStr = getLastSyncedServerTimestamp(syncKey);
        final currentCount = Hive.box(stockBox).length;

        Query query = FirebaseFirestore.instance
            .collection('branches')
            .doc(effectiveFirestoreBranch)
            .collection(invCol);

        if (!forceFull && currentCount >= 15 && lastSyncedStr != null && lastSyncedStr.isNotEmpty) {
          final dt = DateTime.tryParse(lastSyncedStr);
          if (dt != null) {
            query = query.where('updatedAt', isGreaterThan: Timestamp.fromDate(dt));
          }
        }

        final isDelta = !forceFull && currentCount >= 15 && lastSyncedStr != null && lastSyncedStr.isNotEmpty;
        // Bounded: on a half-working Wi-Fi the Windows SDK can leave a get() pending for many
        // minutes, and the screens that start this (dispenser, receptionist) wait on it.
        var snapshot = await query.get().timeout(_cloudReadTimeout);
        // Full fallback only when a FULL read came back empty (e.g. wrong branch casing). An
        // empty delta just means "nothing changed" — it used to trigger a full re-download of
        // the whole inventory every time.
        if (snapshot.docs.isEmpty && !isDelta) {
          snapshot = await FirebaseFirestore.instance
              .collection('branches')
              .doc(effectiveFirestoreBranch)
              .collection(invCol)
              .get()
              .timeout(_cloudReadTimeout);
        }
        if (snapshot.docs.isEmpty && effectiveFirestoreBranch == 'karachi') {
          snapshot = await FirebaseFirestore.instance
              .collection('branches')
              .doc('Karachi')
              .collection(invCol)
              .get()
              .timeout(_cloudReadTimeout);
        }

        if (snapshot.docs.isNotEmpty) {
          final items = snapshot.docs.map((doc) {
            final d = doc.data() as Map<String, dynamic>;
            d['id'] = doc.id;
            d['branchId'] = branchId;
            final docIdUpper = doc.id.toUpperCase();
            final rawCamp = (d['campId'] ?? d['dispensaryId'] ?? '').toString().toLowerCase();
            if (invCol == 'inventory_saddar' || docIdUpper.startsWith('KAPAYYA') || docIdUpper.startsWith('SADDAR') || rawCamp.contains('kap') || rawCamp.contains('sadd')) {
              d['campId'] = 'saddar';
              d['dispensaryId'] = 'saddar';
            } else if (invCol == 'inventory_haji' || invCol == 'inventory_haji_camp' || docIdUpper.startsWith('HAJI') || docIdUpper.startsWith('HAJICAMP') || rawCamp.contains('haji')) {
              d['campId'] = 'haji_camp';
              d['dispensaryId'] = 'haji_camp';
            }

            // Heal Diclofenac Sodium 50mg Tablet barcode mismatch (MED-DIC-INJ -> MED-DIC-50)
            final name = (d['name'] ?? '').toString().toLowerCase();
            final dose = (d['dose'] ?? '').toString().toLowerCase();
            final type = (d['type'] ?? d['dosageForm'] ?? '').toString().toLowerCase();
            final code = (d['code'] ?? d['barcode'] ?? '').toString();
            if (name.contains('diclofenac') && dose.contains('50') && type.contains('tab') && code == 'MED-DIC-INJ') {
              d['code'] = 'MED-DIC-50';
              d['barcode'] = 'MED-DIC-50';
            }
            return d;
          }).toList();
          // Stock changes still waiting in this PC's queue (uploaded hourly, see
          // HourlyDispensarySync) are not in the cloud figures yet; take them off again so
          // local stock does not jump back up until the next upload.
          final pending = HourlyDispensarySync.pendingStockChanges();
          if (pending.isNotEmpty) {
            for (final d in items) {
              final change = pending[d['id']?.toString()];
              final q = d['quantity'];
              if (change != null && q is num) d['quantity'] = q + change;
            }
          }
          await saveAllLocalStockItems(items);

          Timestamp? maxTs;
          for (final doc in snapshot.docs) {
            final data = doc.data() as Map<String, dynamic>?;
            final ts = data?['updatedAt'] ?? data?['addedAt'] ?? data?['timestamp'];
            if (ts is Timestamp) {
              if (maxTs == null || ts.compareTo(maxTs) > 0) {
                maxTs = ts;
              }
            }
          }
          if (maxTs != null) {
            await setLastSyncedServerTimestamp(
              syncKey,
              maxTs.toDate().toUtc().toIso8601String(),
            );
          }
        }
      }

      if (CampSessionService.isKarachiFamily(branchId) && !_isRestoringKarachiInventory) {
        if (forceFull) {
          unawaited(restoreAndSyncKarachiInventory(branchId));
        } else {
          unawaited(healKarachiSplitInventory());
        }
      }
    } catch (e) {
      debugPrint('[LocalStorage] downloadInventory error: $e');
    }
  }

  /// Consolidates Karachi's split inventory across Firestore & Hive:
  /// - Migrates hajicamp-- docs into inventory_haji
  /// - Migrates saddar-- docs into inventory_saddar
  /// - Fixes Diclofenac 50mg barcode from MED-DIC-INJ to MED-DIC-50
  /// - Removes redundant duplicates from generic inventory
  static Future<void> healKarachiSplitInventory({bool force = false}) async {
    if (LanFirestoreGate.isLanDesk) return; // a dispensary desk on the LAN gets this from the LAN server
    try {
      if (!Hive.isBoxOpen('app_settings')) {
        await Hive.openBox('app_settings');
      }
      final settings = Hive.box('app_settings');
      if (!force && settings.get('karachi_split_inventory_healed_v3', defaultValue: false) == true) {
        return;
      }
      debugPrint('[LocalStorage] 🩺 Starting healKarachiSplitInventory...');

      final db = FirebaseFirestore.instance;
      final karachiRef = db.collection('branches').doc('karachi');

      final invSnap = await karachiRef.collection('inventory').get().catchError((_) => karachiRef.collection('inventory').limit(1).get());
      final hajiBatch = db.batch();
      final saddarBatch = db.batch();
      final deleteBatch = db.batch();

      int hajiCount = 0;
      int saddarCount = 0;
      int deleteCount = 0;

      if (invSnap.docs.isNotEmpty) {
        for (final doc in invSnap.docs) {
          final d = Map<String, dynamic>.from(doc.data());
          final docId = doc.id;
          final docIdLower = docId.toLowerCase();
          final rawCamp = (d['campId'] ?? d['dispensaryId'] ?? '').toString().toLowerCase();

          // Fix Diclofenac barcode
          final name = (d['name'] ?? '').toString().toLowerCase();
          final dose = (d['dose'] ?? '').toString().toLowerCase();
          final type = (d['type'] ?? d['dosageForm'] ?? '').toString().toLowerCase();
          if (name.contains('diclofenac') && dose.contains('50') && type.contains('tab')) {
            d['code'] = 'MED-DIC-50';
            d['barcode'] = 'MED-DIC-50';
          }

          if (docIdLower.startsWith('hajicamp--') || docIdLower.startsWith('haji--') || rawCamp.contains('haji')) {
            d['campId'] = 'haji_camp';
            d['dispensaryId'] = 'haji_camp';
            hajiBatch.set(karachiRef.collection('inventory_haji').doc(docId), d, SetOptions(merge: true));
            hajiCount++;
            deleteBatch.delete(doc.reference);
            deleteCount++;
          } else if (docIdLower.startsWith('saddar--') || docIdLower.startsWith('kapayya--') || rawCamp.contains('sadd') || rawCamp.contains('kap')) {
            d['campId'] = 'saddar';
            d['dispensaryId'] = 'saddar';
            saddarBatch.set(karachiRef.collection('inventory_saddar').doc(docId), d, SetOptions(merge: true));
            saddarCount++;
            deleteBatch.delete(doc.reference);
            deleteCount++;
          } else {
            // General syrup / non-prefixed doc -> provide isolated copy for each camp
            final hajiDocId = 'hajicamp--$docId';
            final saddarDocId = 'saddar--$docId';
            final hajiData = Map<String, dynamic>.from(d)..['campId'] = 'haji_camp'..['dispensaryId'] = 'haji_camp'..['id'] = hajiDocId;
            final saddarData = Map<String, dynamic>.from(d)..['campId'] = 'saddar'..['dispensaryId'] = 'saddar'..['id'] = saddarDocId;
            hajiBatch.set(karachiRef.collection('inventory_haji').doc(hajiDocId), hajiData, SetOptions(merge: true));
            saddarBatch.set(karachiRef.collection('inventory_saddar').doc(saddarDocId), saddarData, SetOptions(merge: true));
            hajiCount++;
            saddarCount++;
            deleteBatch.delete(doc.reference);
            deleteCount++;
          }
        }
      }

      // Check misplaced items in inventory_saddar that have hajicamp prefix
      try {
        final saddarSnap = await karachiRef.collection('inventory_saddar').get();
        for (final doc in saddarSnap.docs) {
          final docId = doc.id;
          final docIdLower = docId.toLowerCase();
          if (docIdLower.startsWith('hajicamp--') || docIdLower.startsWith('haji--')) {
            final d = Map<String, dynamic>.from(doc.data());
            d['campId'] = 'haji_camp';
            d['dispensaryId'] = 'haji_camp';
            hajiBatch.set(karachiRef.collection('inventory_haji').doc(docId), d, SetOptions(merge: true));
            hajiCount++;
            deleteBatch.delete(doc.reference);
            deleteCount++;
          }
        }
      } catch (_) {}

      // Commit batches
      if (hajiCount > 0) await hajiBatch.commit();
      if (saddarCount > 0) await saddarBatch.commit();
      if (deleteCount > 0) await deleteBatch.commit();

      // Heal local Hive stockBox
      if (Hive.isBoxOpen(stockBox)) {
        final box = Hive.box(stockBox);
        for (final key in box.keys.toList()) {
          final val = box.get(key);
          if (val is Map) {
            final m = Map<String, dynamic>.from(val);
            final rawId = (m['id'] ?? m['medicineId'] ?? m['docId'] ?? key).toString().toLowerCase();
            final name = (m['name'] ?? '').toString().toLowerCase();
            final dose = (m['dose'] ?? '').toString().toLowerCase();
            final type = (m['type'] ?? m['dosageForm'] ?? '').toString().toLowerCase();
            bool changed = false;

            if (rawId.startsWith('hajicamp--') || rawId.startsWith('haji--')) {
              if (m['campId'] != 'haji_camp') {
                m['campId'] = 'haji_camp';
                m['dispensaryId'] = 'haji_camp';
                changed = true;
              }
              if (m['dispensaryTag'] == 'SADD' || m['dispensaryTag'] == 'KAP') {
                m['dispensaryTag'] = 'HAJI';
                changed = true;
              }
            } else if (rawId.startsWith('saddar--') || rawId.startsWith('kapayya--')) {
              if (m['campId'] != 'saddar') {
                m['campId'] = 'saddar';
                m['dispensaryId'] = 'saddar';
                changed = true;
              }
            }

            final rawName = (m['name'] ?? m['formula'] ?? m['medicineName'] ?? '').toString().trim();
            if (rawName.isEmpty || rawName.toLowerCase() == 'null') {
              final healed = healStockItemFromKeyOrId(key.toString());
              if (healed != null) {
                m['name'] = healed['name']!;
                m['formula'] = healed['name']!;
                m['type'] = healed['type']!;
                m['dose'] = healed['dose']!;
                if ((m['expiryDate'] ?? '').toString().isEmpty) {
                  m['expiryDate'] = healed['expiryDate']!;
                }
                changed = true;
              }
            }

            if (name.contains('diclofenac') && dose.contains('50') && type.contains('tab') && m['code'] == 'MED-DIC-INJ') {
              m['code'] = 'MED-DIC-50';
              m['barcode'] = 'MED-DIC-50';
              changed = true;
            }

            if (changed) {
              await box.put(key, m);
            }
          }
        }
      }

      await settings.put('karachi_split_inventory_healed_v3', true);
      debugPrint('[LocalStorage] ✅ Successfully healed Karachi inventory ($hajiCount haji, $saddarCount saddar migrated, $deleteCount cleaned)');
    } catch (e) {
      debugPrint('[LocalStorage] healKarachiSplitInventory error: $e');
    }
  }

  /// Comprehensively heals and restores Karachi inventory across Firestore, Hive, and LAN:
  /// 1. Queries inventory, inventory_haji, inventory_haji_camp, and inventory_saddar from Firestore.
  /// 2. If Haji Camp has 0 or fewer items than Saddar/inventory/local Hive, it mirrors/restores them
  ///    into branches/karachi/inventory_haji with campId: 'haji_camp'.
  static bool _isRestoringKarachiInventory = false;

  /// 3. Updates local stockBox so Haji Camp has full inventory records.
  /// 4. Broadcasts inventory_stock_sync via RealtimeManager over LAN to any connected hybrid desk (e.g. Kashif).
  /// 5. Ensures downloadInventory completes a full refresh.
  static Future<void> restoreAndSyncKarachiInventory(String branchId) async {
    if (LanFirestoreGate.isLanDesk) return; // a dispensary desk on the LAN gets this from the LAN server
    if (_isRestoringKarachiInventory) return;
    _isRestoringKarachiInventory = true;
    try {
      final b = branchId.toLowerCase().trim();
      final effBranch = b.isEmpty || b == 'all' || CampSessionService.isKarachiFamily(b) ? 'karachi' : b;
      debugPrint('[LocalStorage] 🚀 Starting restoreAndSyncKarachiInventory for $effBranch...');

      final db = FirebaseFirestore.instance;
      final branchRef = db.collection('branches').doc('karachi');

      // 1. Gather all existing docs across all Karachi collections
      final hajiSnap = await branchRef.collection('inventory_haji').get().catchError((_) => branchRef.collection('inventory_haji').limit(1).get());
      final hajiCampSnap = await branchRef.collection('inventory_haji_camp').get().catchError((_) => branchRef.collection('inventory_haji_camp').limit(1).get());
      final saddarSnap = await branchRef.collection('inventory_saddar').get().catchError((_) => branchRef.collection('inventory_saddar').limit(1).get());
      final genericSnap = await branchRef.collection('inventory').get().catchError((_) => branchRef.collection('inventory').limit(1).get());

      final List<Map<String, dynamic>> hajiItems = [
        ...hajiSnap.docs.map((d) => {...d.data(), 'id': d.id}),
        ...hajiCampSnap.docs.map((d) => {...d.data(), 'id': d.id}),
      ];
      final List<Map<String, dynamic>> saddarItems = saddarSnap.docs.map((d) => {...d.data(), 'id': d.id}).toList();
      final List<Map<String, dynamic>> genericItems = genericSnap.docs.map((d) => {...d.data(), 'id': d.id}).toList();

      // Also gather from local Hive stockBox
      final List<Map<String, dynamic>> localItems = [];
      if (Hive.isBoxOpen(stockBox)) {
        final box = Hive.box(stockBox);
        for (final k in box.keys) {
          final v = box.get(k);
          if (v is Map) {
            localItems.add(Map<String, dynamic>.from(v));
          }
        }
      }

      debugPrint('[LocalStorage] Found in Firestore: ${hajiItems.length} Haji, ${saddarItems.length} Saddar, ${genericItems.length} Generic. Local Hive: ${localItems.length}');

      // If Haji is missing or empty in Firestore, restore from Saddar, Generic, or Local Hive
      if (hajiItems.length < 5 && (saddarItems.isNotEmpty || genericItems.isNotEmpty || localItems.isNotEmpty)) {
        final sourcePool = <String, Map<String, dynamic>>{};

        // Gather from genericItems, saddarItems, localItems
        for (final item in [...genericItems, ...saddarItems, ...localItems]) {
          final rawName = (item['name'] ?? item['formula'] ?? '').toString().trim().toLowerCase();
          final rawType = (item['type'] ?? item['dosageForm'] ?? '').toString().trim().toLowerCase();
          final rawDose = (item['dose'] ?? '').toString().trim().toLowerCase();
          if (rawName.isEmpty) continue;
          final key = '$rawName|$rawType|$rawDose';
          if (!sourcePool.containsKey(key)) {
            sourcePool[key] = item;
          }
        }

        if (sourcePool.isNotEmpty) {
          debugPrint('[LocalStorage] 🩹 Restoring ${sourcePool.length} medicines into inventory_haji...');
          final batch = db.batch();
          int batchCount = 0;

          for (final entry in sourcePool.entries) {
            final src = Map<String, dynamic>.from(entry.value);
            final origId = (src['id'] ?? src['medicineId'] ?? src['code'] ?? src['barcode'] ?? '').toString();
            final cleanDocId = origId.toLowerCase().startsWith('hajicamp--')
                ? origId
                : 'hajicamp--${origId.replaceAll(RegExp(r'^(saddar--|kapayya--)'), '')}';

            final hajiData = Map<String, dynamic>.from(src);
            hajiData['id'] = cleanDocId;
            hajiData['branchId'] = 'karachi';
            hajiData['campId'] = 'haji_camp';
            hajiData['dispensaryId'] = 'haji_camp';
            hajiData['lastUpdated'] = DateTime.now().toIso8601String();

            batch.set(branchRef.collection('inventory_haji').doc(cleanDocId), hajiData, SetOptions(merge: true));
            batchCount++;

            // Also save locally
            saveLocalInventoryItem(hajiData);
          }

          if (batchCount > 0) {
            await batch.commit().timeout(const Duration(seconds: 10));
            debugPrint('[LocalStorage] ✅ Successfully committed $batchCount medicines to Firestore inventory_haji!');
          }
        }
      }

      // Ensure local stockBox has copies for both camps for any existing medicines
      if (Hive.isBoxOpen(stockBox)) {
        final box = Hive.box(stockBox);
        final toAdd = <Map<String, dynamic>>[];
        for (final k in box.keys.toList()) {
          final v = box.get(k);
          if (v is Map) {
            final m = Map<String, dynamic>.from(v);
            final bId = (m['branchId'] ?? '').toString().toLowerCase();
            if (bId.isEmpty || bId.contains('karachi')) {
              final cId = (m['campId'] ?? m['dispensaryId'] ?? '').toString().toLowerCase();
              if (cId != 'haji_camp' && !cId.contains('haji')) {
                final id = (m['id'] ?? k).toString();
                final hajiCloneId = id.startsWith('hajicamp--') ? id : 'hajicamp--$id';
                final clone = Map<String, dynamic>.from(m);
                clone['id'] = hajiCloneId;
                clone['campId'] = 'haji_camp';
                clone['dispensaryId'] = 'haji_camp';
                toAdd.add(clone);
              }
            }
          }
        }
        for (final clone in toAdd) {
          saveLocalInventoryItem(clone);
        }
      }

      // Download full inventory
      await downloadInventory('karachi', forceFull: false, campId: 'all');
    } catch (e) {
      debugPrint('[LocalStorage] restoreAndSyncKarachiInventory error: $e');
    } finally {
      _isRestoringKarachiInventory = false;
    }
  }

  static Future<void> refreshPrescriptions(String branchId) async {
    if (LanFirestoreGate.isLanDesk) return; // a dispensary desk on the LAN gets this from the LAN server
    branchId = branchId.toLowerCase().trim();
    try {
      final cnicDocs = await FirebaseFirestore.instance
          .collection('branches')
          .doc(branchId)
          .collection('prescriptions')
          .get();
      final prescMap = <String, Map<String, dynamic>>{};
      for (final cnicDoc in cnicDocs.docs) {
        final patientCnic = cnicDoc.id;
        final subSnap     = await cnicDoc.reference
            .collection('prescriptions')
            .get();
        for (final presDoc in subSnap.docs) {
          final d = presDoc.data();
          d['id'] = presDoc.id;
          d['serial']      = presDoc.id;
          d['patientCnic'] = patientCnic;
          d['cnic']        = patientCnic;
          d['branchId']    = branchId;
          prescMap['${patientCnic}_${presDoc.id}'] = sanitize(d);
        }
      }
      await Hive.box(prescriptionsBox).clear();
      await Hive.box(prescriptionsBox).putAll(prescMap);
    } catch (e) {
      debugPrint('[LocalStorage] refreshPrescriptions error: $e');
    }
  }

  // ── Medicine Restrictions (Multi-day tokens) ───────────────────────────────

  static String _cleanId(String id) => id.trim().replaceAll(RegExp(r'[-\s]'), '');

  /// Resolves the individual patient ID.
  /// For children: returns '{guardianCnic}_child_{name}' or 'child_{name}' to prevent
  /// restrictions and token collision from bleeding into adult family members.
  /// For adults: returns the clean 13-digit CNIC or individual patientId.
  static String resolveIndividualPatientId(Map<String, dynamic>? data) {
    if (data == null || data.isEmpty) return '';
    final rawPid = (data['patientId'] ?? data['id'] ?? '').toString().trim();
    final name = (data['patientName'] ?? data['name'] ?? data['fullName'] ?? '').toString().trim();
    final cnic = (data['patientCnic'] ?? data['cnic'] ?? '').toString().trim();
    final guard = (data['guardianCnic'] ?? '').toString().trim();
    final isAdult = data['isAdult'] is bool ? data['isAdult'] as bool : (data['isAdult'] != null ? data['isAdult'].toString().toLowerCase() == 'true' : null);
    final age = (data['age'] is num) ? (data['age'] as num).toInt() : (int.tryParse(data['age']?.toString() ?? '') ?? 0);
    
    // Check if explicitly child or known child ID pattern
    bool isChild = isAdult != null
        ? !isAdult
        : (guard.isNotEmpty || rawPid.contains('_child_') || (age > 0 && age < 18));

    // If ambiguous (e.g. entry record where isAdult was not saved), check if patient registry knows this patient is a child
    if (!isChild && isAdult == null && name.isNotEmpty && (cnic.isNotEmpty || guard.isNotEmpty)) {
      final effCnic = guard.isNotEmpty ? guard : cnic;
      final cleanG = _cleanId(effCnic);
      final normN = name.trim().replaceAll(RegExp(r'\s+'), '_').replaceAll(RegExp(r'[^a-zA-Z0-9_]'), '').toLowerCase();
      if (cleanG.isNotEmpty && normN.isNotEmpty && Hive.isBoxOpen(patientsBox)) {
        final pBox = Hive.box(patientsBox);
        if (pBox.containsKey('${cleanG}_child_$normN') || pBox.containsKey('${cleanG}_child_${_normalizeName(name)}')) {
          isChild = true;
        }
      }
    }

    if (isChild) {
      if (rawPid.contains('_child_')) return rawPid;
      final gCnic = guard.isNotEmpty ? guard : cnic;
      final cleanG = _cleanId(gCnic);
      final safeName = name.isNotEmpty && name.toLowerCase() != 'unknown' && name.toLowerCase() != 'unknown patient'
          ? name.trim().replaceAll(RegExp(r'\s+'), '_').replaceAll(RegExp(r'[^a-zA-Z0-9_]'), '').toLowerCase()
          : 'child';
      if (cleanG.isNotEmpty) {
        return '${cleanG}_child_$safeName';
      }
      if (rawPid.isNotEmpty) return rawPid;
    } else {
      if (cnic.isNotEmpty) return _cleanId(cnic);
      if (rawPid.isNotEmpty && !rawPid.contains('_child_')) return _cleanId(rawPid);
    }
    return rawPid.isNotEmpty ? rawPid : _cleanId(cnic);
  }

  /// Scans local patient records, entries, and prescriptions.
  /// Identifies records with missing patientId, malformed IDs, missing isAdult flags,
  /// or unlinked names, and repairs them using unified individual identity resolution.
  static Future<Map<String, int>> repairMissingPatientData({String? branchId}) async {
    int patientsRepaired = 0;
    int entriesRepaired = 0;
    int prescriptionsRepaired = 0;

    // 1. Repair patients in patientsBox
    if (Hive.isBoxOpen(patientsBox)) {
      final pBox = Hive.box(patientsBox);
      final keys = pBox.keys.toList();
      for (final k in keys) {
        final raw = pBox.get(k);
        if (raw is Map) {
          final pMap = Map<String, dynamic>.from(raw);
          bool changed = false;

          final resolvedId = resolveIndividualPatientId(pMap);
          final currentId = (pMap['patientId'] ?? pMap['id'] ?? '').toString().trim();
          if (resolvedId.isNotEmpty && (currentId.isEmpty || currentId != resolvedId)) {
            pMap['patientId'] = resolvedId;
            pMap['id'] = resolvedId;
            changed = true;
          }

          final guard = (pMap['guardianCnic'] ?? '').toString().trim();
          if (pMap['isAdult'] == null) {
            pMap['isAdult'] = guard.isEmpty && !resolvedId.contains('_child_');
            changed = true;
          }

          final name = (pMap['patientName'] ?? pMap['name'] ?? pMap['fullName'] ?? '').toString().trim();
          if (pMap['patientName'] == null && name.isNotEmpty) {
            pMap['patientName'] = name;
            pMap['name'] = name;
            changed = true;
          }

          if (changed) {
            final sanitized = sanitize(pMap);
            await pBox.put(k, sanitized);
            if (resolvedId.isNotEmpty && k.toString() != resolvedId) {
              await pBox.put(resolvedId, sanitized);
            }
            patientsRepaired++;
          }
        }
      }
    }

    // 2. Repair entries in entriesBox
    if (Hive.isBoxOpen(entriesBox)) {
      final eBox = Hive.box(entriesBox);
      final keys = eBox.keys.toList();
      for (final k in keys) {
        final raw = eBox.get(k);
        if (raw is Map) {
          final eMap = Map<String, dynamic>.from(raw);
          bool changed = false;

          final resolvedId = resolveIndividualPatientId(eMap);
          final currentId = (eMap['patientId'] ?? eMap['id'] ?? '').toString().trim();
          if (resolvedId.isNotEmpty && (currentId.isEmpty || currentId != resolvedId)) {
            eMap['patientId'] = resolvedId;
            changed = true;
          }

          final name = (eMap['patientName'] ?? eMap['name'] ?? eMap['fullName'] ?? '').toString().trim();
          if (eMap['patientName'] == null && name.isNotEmpty) {
            eMap['patientName'] = name;
            eMap['name'] = name;
            changed = true;
          }

          if (changed) {
            final sanitized = sanitize(eMap);
            await eBox.put(k, sanitized);
            entriesRepaired++;
          }
        }
      }
    }

    // 3. Repair prescriptions in prescriptionsBox
    if (Hive.isBoxOpen(prescriptionsBox)) {
      final prBox = Hive.box(prescriptionsBox);
      final keys = prBox.keys.toList();
      for (final k in keys) {
        final raw = prBox.get(k);
        if (raw is Map) {
          final prMap = Map<String, dynamic>.from(raw);
          bool changed = false;

          final resolvedId = resolveIndividualPatientId(prMap);
          final currentId = (prMap['patientId'] ?? prMap['id'] ?? '').toString().trim();
          if (resolvedId.isNotEmpty && (currentId.isEmpty || currentId != resolvedId)) {
            prMap['patientId'] = resolvedId;
            changed = true;
          }

          if (changed) {
            final sanitized = sanitize(prMap);
            await prBox.put(k, sanitized);
            prescriptionsRepaired++;
          }
        }
      }
    }

    return {
      'patients': patientsRepaired,
      'entries': entriesRepaired,
      'prescriptions': prescriptionsRepaired,
    };
  }

  /// Deep repair of patient identities and medical histories (prescriptions, visits).
  /// Resolves cases where child and parent histories were swapped or merged under the same CNIC,
  /// moves child records mistakenly placed under raw 13-digit adult CNIC keys to their canonical
  /// `${guardianCnic}_child_${name}` keys, and correctly re-links prescriptions and visits to the
  /// individual owner based on patientName and adult/child identity.
  static Future<Map<String, int>> repairPatientIdentityCorruption({String? branchId}) async {
    int patientsRepaired = 0;
    int entriesRepaired = 0;
    int prescriptionsRepaired = 0;

    // First run schema and basic patient data repair
    final baseStats = await repairMissingPatientData(branchId: branchId);
    patientsRepaired += baseStats['patients'] ?? 0;
    entriesRepaired += baseStats['entries'] ?? 0;
    prescriptionsRepaired += baseStats['prescriptions'] ?? 0;

    if (!Hive.isBoxOpen(patientsBox)) await openBoxSafe(patientsBox);
    if (!Hive.isBoxOpen(prescriptionsBox)) await openBoxSafe(prescriptionsBox);
    if (!Hive.isBoxOpen(entriesBox)) await openBoxSafe(entriesBox);

    final pBox = Hive.box(patientsBox);
    final prBox = Hive.box(prescriptionsBox);
    final eBox = Hive.box(entriesBox);

    // 1. Repair patientsBox: Find children registered under raw adult CNIC keys
    final pKeys = pBox.keys.toList();
    for (final k in pKeys) {
      final raw = pBox.get(k);
      if (raw is! Map) continue;
      final pMap = Map<String, dynamic>.from(raw);
      final rawPid = (pMap['patientId'] ?? pMap['id'] ?? k).toString().trim();
      final name = (pMap['patientName'] ?? pMap['name'] ?? pMap['fullName'] ?? '').toString().trim();
      final cnic = (pMap['cnic'] ?? pMap['patientCnic'] ?? '').toString().replaceAll('-', '').trim();
      final guard = (pMap['guardianCnic'] ?? '').toString().replaceAll('-', '').trim();
      final rawAge = pMap['age'];
      final age = (rawAge is num) ? rawAge.toInt() : (int.tryParse(rawAge?.toString() ?? '') ?? 0);
      final isAdult = pMap['isAdult'] is bool ? pMap['isAdult'] as bool : null;

      final bool looksLikeChild = (isAdult == false) ||
          (age > 0 && age < 18) ||
          guard.isNotEmpty ||
          rawPid.contains('_child_');

      final bool isRawCnicKey = RegExp(r'^\d{13}$').hasMatch(k.toString()) ||
          RegExp(r'^\d{5}-\d{7}-\d{1}$').hasMatch(k.toString());

      if (looksLikeChild && isRawCnicKey && !rawPid.contains('_child_')) {
        final effGuard = guard.isNotEmpty ? guard : cnic;
        final cleanG = _cleanId(effGuard);
        final normName = _normalizeName(name);
        final newChildKey = '${cleanG}_child_$normName';

        pMap['patientId'] = newChildKey;
        pMap['id'] = newChildKey;
        pMap['isAdult'] = false;
        if (pMap['guardianCnic'] == null || pMap['guardianCnic'].toString().isEmpty) {
          pMap['guardianCnic'] = effGuard;
        }

        final sanitized = sanitize(pMap);
        await pBox.put(newChildKey, sanitized);
        patientsRepaired++;
      }
    }

    // 2. Build patient lookup map: (cleanCnic + normalizedName) -> canonical patientId
    final patientKeyByName = <String, String>{};
    for (final k in pBox.keys) {
      final val = pBox.get(k);
      if (val is! Map) continue;
      final pid = (val['patientId'] ?? val['id'] ?? k).toString().trim();
      final cnic = (val['cnic'] ?? val['patientCnic'] ?? val['guardianCnic'] ?? '').toString().replaceAll(RegExp(r'[^\w]'), '');
      final name = _normalizeName((val['patientName'] ?? val['name'] ?? val['fullName'] ?? '').toString());
      if (cnic.isNotEmpty && name.isNotEmpty && pid.isNotEmpty) {
        patientKeyByName['${cnic}_$name'] = pid;
      }
    }

    // 3. Repair prescriptions in prescriptionsBox
    final prKeys = prBox.keys.toList();
    for (final k in prKeys) {
      final raw = prBox.get(k);
      if (raw is! Map) continue;
      final prMap = Map<String, dynamic>.from(raw);
      final cnic = (prMap['patientCnic'] ?? prMap['cnic'] ?? prMap['guardianCnic'] ?? '').toString().replaceAll(RegExp(r'[^\w]'), '');
      final name = _normalizeName((prMap['patientName'] ?? prMap['name'] ?? '').toString());
      final currentPid = (prMap['patientId'] ?? prMap['id'] ?? '').toString().trim();

      if (cnic.isNotEmpty && name.isNotEmpty) {
        final correctPid = patientKeyByName['${cnic}_$name'];
        if (correctPid != null && correctPid.isNotEmpty && correctPid != currentPid) {
          prMap['patientId'] = correctPid;
          if (correctPid.contains('_child_')) {
            prMap['isAdult'] = false;
          }
          await prBox.put(k, sanitize(prMap));
          prescriptionsRepaired++;
        }
      }
    }

    // 4. Repair entries in entriesBox
    final eKeys = eBox.keys.toList();
    for (final k in eKeys) {
      final raw = eBox.get(k);
      if (raw is! Map) continue;
      final eMap = Map<String, dynamic>.from(raw);
      final cnic = (eMap['patientCnic'] ?? eMap['cnic'] ?? eMap['guardianCnic'] ?? '').toString().replaceAll(RegExp(r'[^\w]'), '');
      final name = _normalizeName((eMap['patientName'] ?? eMap['name'] ?? '').toString());
      final currentPid = (eMap['patientId'] ?? eMap['id'] ?? '').toString().trim();

      if (cnic.isNotEmpty && name.isNotEmpty) {
        final correctPid = patientKeyByName['${cnic}_$name'];
        if (correctPid != null && correctPid.isNotEmpty && correctPid != currentPid) {
          eMap['patientId'] = correctPid;
          if (correctPid.contains('_child_')) {
            eMap['isAdult'] = false;
          }
          await eBox.put(k, sanitize(eMap));
          entriesRepaired++;
        }
      }
    }

    debugPrint('[LocalStorageService] 🩹 repairPatientIdentityCorruption complete: '
        'patients=$patientsRepaired, entries=$entriesRepaired, prescriptions=$prescriptionsRepaired');

    return {
      'patients': patientsRepaired,
      'entries': entriesRepaired,
      'prescriptions': prescriptionsRepaired,
    };
  }

  /// Scans local patients for child-parent CNIC conflicts:
  /// 1. Children whose patientId is a raw 13-digit CNIC (missing _child_ discriminator).
  /// 2. Records where a child and an adult share the exact same CNIC.
  /// 3. Duplicate/hijacked records under a CNIC key.
  /// Computes linked visits in entriesBox and prescriptions in prescriptionsBox to ensure safe visibility.
  static Future<List<Map<String, dynamic>>> findChildParentCnicConflicts({String? branchId}) async {
    final conflicts = <Map<String, dynamic>>[];
    if (!Hive.isBoxOpen(patientsBox)) return conflicts;

    final pBox = Hive.box(patientsBox);
    final eBox = Hive.isBoxOpen(entriesBox) ? Hive.box(entriesBox) : null;
    final prBox = Hive.isBoxOpen(prescriptionsBox) ? Hive.box(prescriptionsBox) : null;

    // Group patients by clean CNIC
    final cnicGroups = <String, List<Map<String, dynamic>>>{};

    for (final k in pBox.keys) {
      final val = pBox.get(k);
      if (val is! Map) continue;
      final p = Map<String, dynamic>.from(val);
      final pid = (p['patientId'] ?? p['id'] ?? k).toString().trim();
      p['hiveKey'] = k.toString();
      p['patientId'] = pid;

      final bId = (p['branchId'] ?? '').toString().trim();
      if (branchId != null && branchId.isNotEmpty && branchId != 'all' && bId.isNotEmpty && bId.toLowerCase() != branchId.toLowerCase()) {
        continue;
      }

      final cnic = (p['cnic'] ?? p['patientCnic'] ?? p['guardianCnic'] ?? '').toString().replaceAll(RegExp(r'[^\w]'), '');
      if (cnic.isNotEmpty) {
        cnicGroups.putIfAbsent(cnic, () => []).add(p);
      }
    }

    int countVisits(String pid, String cnic, String name) {
      if (eBox == null) return 0;
      final cleanPid = pid.replaceAll(RegExp(r'[^\w]'), '').toLowerCase();
      final cleanCnic = cnic.replaceAll(RegExp(r'[^\w]'), '').toLowerCase();
      final cleanName = name.trim().toLowerCase();
      int count = 0;
      for (final val in eBox.values) {
        if (val is! Map) continue;
        final ePid = (val['patientId'] ?? val['id'] ?? '').toString().replaceAll(RegExp(r'[^\w]'), '').toLowerCase();
        final eCnic = (val['patientCnic'] ?? val['cnic'] ?? val['guardianCnic'] ?? '').toString().replaceAll(RegExp(r'[^\w]'), '').toLowerCase();
        final eName = (val['patientName'] ?? val['name'] ?? '').toString().trim().toLowerCase();
        if (cleanPid.isNotEmpty && ePid == cleanPid) {
          count++;
        } else if (cleanCnic.isNotEmpty && eCnic == cleanCnic && cleanName.isNotEmpty && (eName == cleanName || eName.contains(cleanName) || cleanName.contains(eName))) {
          count++;
        }
      }
      return count;
    }

    int countPrescriptions(String pid, String cnic, String name) {
      if (prBox == null) return 0;
      final cleanPid = pid.replaceAll(RegExp(r'[^\w]'), '').toLowerCase();
      final cleanCnic = cnic.replaceAll(RegExp(r'[^\w]'), '').toLowerCase();
      final cleanName = name.trim().toLowerCase();
      int count = 0;
      for (final val in prBox.values) {
        if (val is! Map) continue;
        final prPid = (val['patientId'] ?? val['id'] ?? '').toString().replaceAll(RegExp(r'[^\w]'), '').toLowerCase();
        final prCnic = (val['patientCnic'] ?? val['cnic'] ?? '').toString().replaceAll(RegExp(r'[^\w]'), '').toLowerCase();
        final prName = (val['patientName'] ?? val['name'] ?? '').toString().trim().toLowerCase();
        if (cleanPid.isNotEmpty && prPid == cleanPid) {
          count++;
        } else if (cleanCnic.isNotEmpty && prCnic == cleanCnic && cleanName.isNotEmpty && (prName == cleanName || prName.contains(cleanName) || cleanName.contains(prName))) {
          count++;
        }
      }
      return count;
    }

    for (final entry in cnicGroups.entries) {
      final cnic = entry.key;
      final patients = entry.value;

      for (final p in patients) {
        final hiveKey = p['hiveKey'] as String;
        final pid = (p['patientId'] ?? hiveKey).toString();
        final name = (p['patientName'] ?? p['name'] ?? p['fullName'] ?? 'Unknown').toString().trim();
        final rawAge = p['age'];
        final age = (rawAge is num) ? rawAge.toInt() : (int.tryParse(rawAge?.toString() ?? '') ?? 0);
        final guard = (p['guardianCnic'] ?? '').toString().replaceAll(RegExp(r'[^\w]'), '');
        final isAdult = p['isAdult'];
        final bool looksLikeChild = isAdult == false || (age > 0 && age < 20) || guard.isNotEmpty || pid.contains('_child_');
        final bool isPureCnicKey = RegExp(r'^\d{13}$').hasMatch(hiveKey) ||
            RegExp(r'^\d{5}-\d{7}-\d{1}$').hasMatch(hiveKey) ||
            RegExp(r'^\d{13}$').hasMatch(pid) ||
            RegExp(r'^\d{5}-\d{7}-\d{1}$').hasMatch(pid);

        bool isConflict = false;
        String reason = '';

        // Conflict Type 1: Child occupying raw CNIC key (no _child_ in key/id)
        if (looksLikeChild && isPureCnicKey && !pid.contains('_child_')) {
          isConflict = true;
          reason = 'Child registered under raw adult CNIC key ($hiveKey)';
        }
        // Conflict Type 2: Multiple patients under the same CNIC with different names
        else if (patients.length > 1) {
          final distinctNames = patients.map((x) => (x['patientName'] ?? x['name'] ?? '').toString().trim().toLowerCase()).where((x) => x.isNotEmpty).toSet();
          if (distinctNames.length > 1) {
            isConflict = true;
            reason = 'Multiple individuals sharing CNIC $cnic (${patients.length} registrations found)';
          }
        }
        // Conflict Type 3: isAdult == false or child flags set but patientId == CNIC
        else if (isAdult == false && !pid.contains('_child_')) {
          isConflict = true;
          reason = 'Child flag set but missing canonical child ID suffix';
        }

        if (isConflict) {
          final visits = countVisits(pid, cnic, name);
          final prescs = countPrescriptions(pid, cnic, name);

          conflicts.add({
            'hiveKey': hiveKey,
            'patientId': pid,
            'patientName': name,
            'cnic': cnic,
            'guardianCnic': guard,
            'age': age,
            'isAdult': isAdult,
            'isChild': looksLikeChild,
            'isRawCnicChild': looksLikeChild && isPureCnicKey && !pid.contains('_child_'),
            'hasCnicCollision': patients.length > 1,
            'branchId': p['branchId'] ?? '',
            'conflictReason': reason,
            'visitCount': visits,
            'prescriptionCount': prescs,
            'linkedVisitsCount': visits,
            'linkedPrescriptionsCount': prescs,
            'patientData': p,
          });
        }
      }
    }

    return conflicts;
  }

  /// Deletes ONLY the patient registration from local_patients Hive box and enqueues sync deletion.
  /// ALL medical history (entriesBox, prescriptionsBox, dispensaryBox) remains COMPLETELY INTACT.
  static Future<void> deletePatientRegistrationPreservingHistory(
    String patientId, {
    String? branchId,
    String? reason,
  }) async {
    if (!Hive.isBoxOpen(patientsBox)) return;
    final pBox = Hive.box(patientsBox);
    final existing = pBox.get(patientId);
    String pName = 'Unknown';
    String bId = branchId ?? getActiveUserBranchId();
    String? cnic;
    if (existing is Map) {
      pName = (existing['name'] ?? existing['patientName'] ?? 'Unknown').toString();
      bId = (existing['branchId'] ?? bId).toString();
      cnic = (existing['cnic'] ?? existing['patientCnic'] ?? existing['guardianCnic'])?.toString();
    }

    await pBox.delete(patientId);
    if (cnic != null && cnic.isNotEmpty) {
      await pBox.delete(cnic);
      final clean = cnic.replaceAll('-', '').trim();
      if (clean.isNotEmpty) await pBox.delete(clean);
    }
    await pBox.flush();

    // Audit log
    await recordPatientAuditLog(
      branchId: bId,
      action: 'DELETE_REGISTRATION_KEEP_HISTORY',
      patientId: patientId,
      patientName: pName,
      patientCnic: cnic,
      performedBy: getActiveUsername(),
      performedByRole: getActiveUserRole(),
      reason: reason ?? 'Patient deleted (medical history preserved)',
    );

    // Enqueue Firestore background sync
    await enqueueSync({
      'type': 'delete_patient',
      'branchId': bId,
      'patientId': patientId,
      'reason': reason ?? 'Patient deleted',
    });
  }

  /// Automatically migrates a conflicted child patient to their canonical ID:
  /// Key: '${guardianCnic}_child_${safeName}'
  /// Preserves all entries and prescriptions while fixing registration identity.
  static Future<String> autoMigrateChildToCanonicalId(
    String oldPatientId, {
    String? branchId,
  }) async {
    if (!Hive.isBoxOpen(patientsBox)) return oldPatientId;
    final pBox = Hive.box(patientsBox);
    final existing = pBox.get(oldPatientId);
    if (existing is! Map) return oldPatientId;

    final pData = Map<String, dynamic>.from(existing);
    final bId = (pData['branchId'] ?? branchId ?? getActiveUserBranchId()).toString();
    final name = (pData['patientName'] ?? pData['name'] ?? 'child').toString().trim();
    final safeName = name.replaceAll(RegExp(r'[\s]'), '_');
    final cnic = (pData['guardianCnic'] ?? pData['cnic'] ?? pData['patientCnic'] ?? '').toString().replaceAll(RegExp(r'[^\w]'), '');
    final newId = '${cnic}_child_$safeName';

    pData['patientId'] = newId;
    pData['id'] = newId;
    pData['isAdult'] = false;
    pData['guardianCnic'] = cnic;

    final sanitized = sanitize(pData);
    await pBox.put(newId, sanitized);
    if (oldPatientId != newId) {
      await pBox.delete(oldPatientId);
    }

    // Update active matching entries to use the canonical child patientId
    await updateActiveEntriesForPatient(bId, oldPatientId, {
      'patientId': newId,
      'guardianCnic': cnic,
      'isAdult': false,
    });

    // Enqueue background sync actions
    if (oldPatientId != newId) {
      await enqueueSync({
        'type': 'delete_patient',
        'branchId': bId,
        'patientId': oldPatientId,
        'reason': 'Migrated to canonical child ID $newId',
      });
    }
    await enqueueSync({
      'type': 'save_patient',
      'branchId': bId,
      'patientId': newId,
      'data': sanitized,
    });

    return newId;
  }

  /// Scans local patient records and formats any 13-digit raw CNIC ('4210112345671')
  /// into the standardized Pakistani CNIC format: '42101-1234567-1' (xxxxx-xxxxxxx-x).
  /// Updates local patient profile, linked entries, and enqueues Firestore background sync.
  static Future<int> formatAllRawCnics({String? branchId}) async {
    if (!Hive.isBoxOpen(patientsBox)) return 0;
    final pBox = Hive.box(patientsBox);
    final eBox = Hive.isBoxOpen(entriesBox) ? Hive.box(entriesBox) : null;
    int updatedCount = 0;

    for (final k in pBox.keys.toList()) {
      final val = pBox.get(k);
      if (val is! Map) continue;
      final p = Map<String, dynamic>.from(val);
      final bId = (p['branchId'] ?? '').toString().trim();
      if (branchId != null && branchId.isNotEmpty && branchId != 'all' && bId.isNotEmpty && bId.toLowerCase() != branchId.toLowerCase()) {
        continue;
      }

      bool changed = false;
      final rawCnic = (p['cnic'] ?? p['patientCnic'])?.toString().trim();
      if (rawCnic != null && RegExp(r'^\d{13}$').hasMatch(rawCnic)) {
        final formatted = '${rawCnic.substring(0, 5)}-${rawCnic.substring(5, 12)}-${rawCnic.substring(12, 13)}';
        p['cnic'] = formatted;
        if (p.containsKey('patientCnic')) {
          p['patientCnic'] = formatted;
        }
        changed = true;
      }

      final rawGuard = p['guardianCnic']?.toString().trim();
      if (rawGuard != null && RegExp(r'^\d{13}$').hasMatch(rawGuard)) {
        final formattedGuard = '${rawGuard.substring(0, 5)}-${rawGuard.substring(5, 12)}-${rawGuard.substring(12, 13)}';
        p['guardianCnic'] = formattedGuard;
        changed = true;
      }

      if (changed) {
        final sanitized = sanitize(p);
        await pBox.put(k, sanitized);

        // Update active token entries if open
        if (eBox != null) {
          final pid = (sanitized['patientId'] ?? k).toString();
          for (final ek in eBox.keys) {
            final eval = eBox.get(ek);
            if (eval is Map) {
              final ePid = (eval['patientId'] ?? eval['id'] ?? '').toString();
              if (ePid == pid || (rawCnic != null && eval['cnic'] == rawCnic)) {
                final updatedE = Map<String, dynamic>.from(eval);
                if (p['cnic'] != null) updatedE['cnic'] = p['cnic'];
                if (p['patientCnic'] != null) updatedE['patientCnic'] = p['patientCnic'];
                if (p['guardianCnic'] != null) updatedE['guardianCnic'] = p['guardianCnic'];
                await eBox.put(ek, updatedE);
              }
            }
          }
        }

        // Enqueue background sync to Firestore
        await enqueueSync({
          'type': 'save_patient',
          'branchId': bId.isNotEmpty ? bId : getActiveUserBranchId(),
          'patientId': (sanitized['patientId'] ?? k).toString(),
          'data': sanitized,
        });

        updatedCount++;
      }
    }

    if (updatedCount > 0) {
      await pBox.flush();
      if (eBox != null) await eBox.flush();
    }

    return updatedCount;
  }

  static Future<void> saveMedicineRestriction({
    required String branchId,
    required String patientId,
    required int daysCovered,
    String? patientName,
    String? guardianCnic,
    String? phone,
  }) async {
    // FIX 2: normalize branchId before it's used to build the Hive key below.
    branchId = branchId.toLowerCase().trim();
    final cleanId = _cleanId(patientId);
    if (cleanId.isEmpty) return;

    final box  = Hive.box(medicineRestrictionsBox);
    final key  = '${branchId}_$cleanId';
    final now  = DateTime.now();

    final issuedDate     = DateTime(now.year, now.month, now.day);
    final lastBlockedDay = issuedDate.add(Duration(days: daysCovered - 1));

    final record = <String, dynamic>{
      'patientId':      cleanId,
      'branchId':       branchId,
      'issuedAt':       now.toIso8601String(),
      'issuedDateOnly': issuedDate.toIso8601String(),
      'daysCovered':    daysCovered,
      'lastBlockedDay': lastBlockedDay.toIso8601String(),
      if (patientName != null && patientName.isNotEmpty) 'patientName': patientName,
      if (guardianCnic != null && guardianCnic.isNotEmpty) 'guardianCnic': _cleanId(guardianCnic),
      if (phone != null && phone.isNotEmpty) 'phone': _cleanId(phone),
    };

    await box.put(key, record);
    await box.flush();

    await enqueueSync({
      'type':      'save_medicine_restriction',
      'branchId':  branchId,
      'patientId': cleanId,
      'data':      record,
    });

    debugPrint('[LSS] Restriction saved + enqueued for Firestore sync: $cleanId '
        'blocked until $lastBlockedDay ($daysCovered-day rx)');
  }

  static Future<void> downloadMedicineRestrictions(String branchId) async {
    // FIX 2: normalize branchId before it's used to build the Hive key prefix
    // (and cleared-stale-key logic) below.
    branchId = branchId.toLowerCase().trim();
    if (branchId.isEmpty) return;

    // Zero-Quota & Offline Guard: If connected to LAN server, skip hammering Firestore
    if (RealtimeManager().hasServerLink) {
      return;
    }

    try {
      final snap = await FirebaseFirestore.instance
          .collection('branches')
          .doc(branchId)
          .collection('medicine_restrictions')
          .get();

      final box   = Hive.box(medicineRestrictionsBox);
      final today = DateTime(
          DateTime.now().year, DateTime.now().month, DateTime.now().day);
      
      final downloadedIds = <String>{};
      int loaded = 0;

      for (final doc in snap.docs) {
        final d              = Map<String, dynamic>.from(doc.data());
        final lastBlockedStr = d['lastBlockedDay'] as String?;

        if (lastBlockedStr != null) {
          final lb             = DateTime.parse(lastBlockedStr);
          final lastBlockedDay = DateTime(lb.year, lb.month, lb.day);
          if (today.isAfter(lastBlockedDay)) continue;
        }

        final patientId = doc.id;
        final hiveKey   = '${branchId}_$patientId';
        await box.put(hiveKey, d);
        downloadedIds.add(patientId);
        loaded++;
      }

      final prefix = '${branchId}_';
      final localKeysToClear = box.keys
          .where((k) => k.toString().startsWith(prefix))
          .map((k) => k.toString().replaceFirst(prefix, ''))
          .where((id) => !downloadedIds.contains(id))
          .toList();

      for (final id in localKeysToClear) {
        final key = '$prefix$id';
        await box.delete(key);
        debugPrint('[LSS] Cleared stale restriction (synced delete) for $id');
      }

      await box.flush();
      debugPrint('[LSS] Downloaded $loaded active medicine restrictions for $branchId. '
          'Cleared ${localKeysToClear.length} stale ones.');
    } catch (e) {
      debugPrint('[LSS] downloadMedicineRestrictions error: $e');
    }
  }

  static Map<String, dynamic>? getMedicineRestriction(String branchId, String patientId) {
    if (!Hive.isBoxOpen(medicineRestrictionsBox)) return null;
    // FIX 2: normalize branchId before it's used to build the Hive key below.
    branchId = branchId.toLowerCase().trim();
    final cleanId = _cleanId(patientId);
    final box = Hive.box(medicineRestrictionsBox);
    final key = '${branchId}_$cleanId';
    final data = box.get(key);
    if (data == null) return null;
    return Map<String, dynamic>.from(data);
  }

  static Future<void> clearMedicineRestriction(String branchId, String patientId) async {
    // FIX 2: normalize branchId before it's used to build the Hive key below.
    branchId = branchId.toLowerCase().trim();
    final cleanId = _cleanId(patientId);
    final box = Hive.box(medicineRestrictionsBox);
    final key = '${branchId}_$cleanId';
    await box.delete(key);
    await box.flush();
    debugPrint('[LocalStorage] 🗑️ Medicine restriction cleared for $cleanId');
  }

  // ── TOKEN EXCEPTIONS ────────────────────────────────────────────────────────
  /// Grants a token exception for a patient on a specific dateKey.
  static Future<void> grantTokenException(
    String branchId,
    String patientId, {
    String? dateKey,
    String? reason,
    String? approvedBy,
    String? requestId,
  }) async {
    final normBranch = branchId.toLowerCase().trim();
    final normPid = _cleanId(patientId);
    final today = dateKey ?? getTodayDateKey();
    final key = '${normBranch}_${normPid}_$today';

    try {
      if (Hive.isBoxOpen(tokenExceptionsBox)) {
        await Hive.box(tokenExceptionsBox).put(key, {
          'branchId': normBranch,
          'patientId': normPid,
          'dateKey': today,
          'reason': reason ?? 'Approved by Doctor',
          'approvedBy': approvedBy ?? 'Doctor',
          'approvedAt': DateTime.now().toIso8601String(),
          'used': false,
          'requestId': requestId,
        });
      }
    } catch (_) {}

    // Also clear from issued_token_keys so idempotency check does not block
    try {
      final idempotencyKey = '${normBranch}_${normPid}_$today';
      if (Hive.isBoxOpen('issued_token_keys')) {
        await Hive.box('issued_token_keys').delete(idempotencyKey);
        await Hive.box('issued_token_keys').delete('${branchId}_${patientId}_$today');
      }
    } catch (_) {}

    // Clear medicine restriction as well
    await clearMedicineRestriction(normBranch, patientId);
    debugPrint('[LocalStorage] 🎟️ Token exception granted for $normPid on $today ($reason)');
  }

  /// Checks if an approved and unused token exception exists for this patient today
  static bool hasApprovedTokenException(String branchId, String patientId, {String? dateKey}) {
    final normBranch = branchId.toLowerCase().trim();
    final normPid = _cleanId(patientId);
    final today = dateKey ?? getTodayDateKey();
    final key = '${normBranch}_${normPid}_$today';

    try {
      if (Hive.isBoxOpen(tokenExceptionsBox)) {
        final val = Hive.box(tokenExceptionsBox).get(key);
        if (val is Map) {
          final used = val['used'] == true;
          return !used;
        }
      }
    } catch (_) {}
    return false;
  }

  /// Consumes the token exception once a new token is successfully generated
  static Future<void> consumeTokenException(String branchId, String patientId, {String? dateKey}) async {
    final normBranch = branchId.toLowerCase().trim();
    final normPid = _cleanId(patientId);
    final today = dateKey ?? getTodayDateKey();
    final key = '${normBranch}_${normPid}_$today';

    try {
      if (Hive.isBoxOpen(tokenExceptionsBox)) {
        final val = Hive.box(tokenExceptionsBox).get(key);
        if (val is Map) {
          final updated = Map<String, dynamic>.from(val);
          updated['used'] = true;
          updated['usedAt'] = DateTime.now().toIso8601String();
          await Hive.box(tokenExceptionsBox).put(key, updated);
          debugPrint('[LocalStorage] 🎟️ Token exception consumed for $normPid on $today');
        }
      }
    } catch (_) {}
  }

  /// Gets the token exception details for a patient
  static Map<String, dynamic>? getTokenException(String branchId, String patientId, {String? dateKey}) {
    final normBranch = branchId.toLowerCase().trim();
    final normPid = _cleanId(patientId);
    final today = dateKey ?? getTodayDateKey();
    final key = '${normBranch}_${normPid}_$today';

    try {
      if (Hive.isBoxOpen(tokenExceptionsBox)) {
        final val = Hive.box(tokenExceptionsBox).get(key);
        if (val is Map) return Map<String, dynamic>.from(val);
      }
    } catch (_) {}
    return null;
  }

  static Map<String, dynamic>? isPatientBlockedByMedicine(
      String branchId, String patientId, [Map<String, dynamic>? patient]) {
    var restriction = getMedicineRestriction(branchId, patientId);
    // The Hive key of the record that blocks, so expiry clears THAT record (clearing the
    // current patientId left a fallback-matched record in place, blocking again next visit).
    Object? matchedKey = restriction == null
        ? null
        : '${branchId.toLowerCase().trim()}_${_cleanId(patientId)}';

    // Fallback for the SAME no-CNIC person registered under a different ID (e.g. a spelling
    // variant of a child's name under the same guardian). It must never match a different
    // person: siblings share the guardian CNIC and the family phone, and the guardian's own
    // restriction is about the guardian. So a match needs a shared guardian CNIC or phone AND
    // the same normalized name. A record with no usable name is never matched this way.
    if (restriction == null && patient != null && Hive.isBoxOpen(medicineRestrictionsBox)) {
      final normBranch = branchId.toLowerCase().trim();
      final pCnic = _cleanId((patient['cnic'] ?? patient['patientCnic'] ?? '').toString());
      final gCnic = _cleanId((patient['guardianCnic'] ?? '').toString());
      final phone = _cleanId((patient['phone'] ?? patient['contactNumber'] ?? '').toString());
      final pName = _restrictionName(
          (patient['name'] ?? patient['patientName'] ?? '').toString(), patientId);

      // Only for patients without their own CNIC (an adult with a CNIC is matched exactly).
      final hasOwnCnic = pCnic.isNotEmpty && pCnic != gCnic && !pCnic.startsWith('unknown');
      if (!hasOwnCnic && pName.isNotEmpty && (gCnic.isNotEmpty || phone.isNotEmpty)) {
        final box = Hive.box(medicineRestrictionsBox);
        for (final k in box.keys) {
          final kStr = k.toString().toLowerCase();
          if (!kStr.startsWith('${normBranch}_')) continue;
          final val = box.get(k);
          if (val is! Map) continue;
          final m = Map<String, dynamic>.from(val);

          final recGCnic = _cleanId((m['guardianCnic'] ?? '').toString());
          final recPhone = _cleanId((m['phone'] ?? '').toString());
          final recPId = _cleanId((m['patientId'] ?? '').toString());
          // The guardian's own record (patientId == guardian CNIC) is not this child's.
          if (gCnic.isNotEmpty && recPId == gCnic) continue;

          final matchesGuardian = gCnic.isNotEmpty &&
              (recGCnic == gCnic || recPId.startsWith('${gCnic}_child_'));
          final matchesPhone = phone.length >= 7 && recPhone == phone;
          if (!matchesGuardian && !matchesPhone) continue;

          final recName = _restrictionName((m['patientName'] ?? '').toString(), recPId);
          if (recName.isEmpty || recName != pName) continue;

          restriction = m;
          matchedKey = k;
          break;
        }
      }
    }

    if (restriction == null) return null;

    void clearMatched() {
      if (matchedKey == null || !Hive.isBoxOpen(medicineRestrictionsBox)) return;
      Hive.box(medicineRestrictionsBox).delete(matchedKey).ignore();
    }

    final today = DateTime(
      DateTime.now().year, DateTime.now().month, DateTime.now().day);

    final lastBlockedStr =
        restriction['lastBlockedDay'] as String?;

    if (lastBlockedStr != null) {
      final lastBlocked = DateTime.parse(lastBlockedStr);
      final lastBlockedDay =
          DateTime(lastBlocked.year, lastBlocked.month, lastBlocked.day);

      if (today.isAfter(lastBlockedDay)) {
        clearMatched();
        return null;
      }
      final todayOnly = DateTime(today.year, today.month, today.day);
      final diff = lastBlockedDay.difference(todayOnly).inDays;

      return {
        ...restriction,
        'remainingDays': diff,
        'isLastDay': diff == 0,
      };
    }

    final expiresStr = restriction['expiresAt'] as String?;
    if (expiresStr == null) {
      clearMatched();
      return null;
    }
    final expiresAt    = DateTime.parse(expiresStr);
    final expireDay    =
        DateTime(expiresAt.year, expiresAt.month, expiresAt.day)
        .subtract(const Duration(days: 1));

    if (today.isAfter(expireDay)) {
      clearMatched();
      return null;
    }
    final remaining = expireDay.difference(today).inDays + 1;
    return {...restriction, 'remainingDays': remaining};
  }

  /// Comparable name for restriction matching: letters/digits only, lower-case. Falls back to
  /// the name part of a `<guardianCnic>_child_<name>` id. Returns '' for placeholder names.
  static String _restrictionName(String name, String patientId) {
    var n = name.trim().toLowerCase();
    if (n.isEmpty) {
      final id = patientId.toLowerCase();
      final i = id.indexOf('_child_');
      if (i >= 0) n = id.substring(i + 7);
    }
    n = n.replaceAll(RegExp(r'[^a-z0-9]'), '');
    if (n.isEmpty || n == 'child' || n == 'unknown' || n == 'unknownpatient' ||
        n.startsWith('token')) {
      return '';
    }
    return n;
  }
  // ════════════════════════════════════════════════════════════════════════════
  // DONATION RECEIPT NUMBERING
  // ════════════════════════════════════════════════════════════════════════════

  static String getBranchCode(String branchId) {
    final b = branchId.toLowerCase().trim();
    if (b.contains('gujrat')) return 'grt';
    if (b.contains('sialkot')) return 'skt';
    if (b.contains('lahore')) return 'lhr';
    if (b.contains('karachi 1')) return 'krh1';
    if (b.contains('karachi')) return 'khi';
    if (b.contains('rawalpindi')) return 'rwp';
    if (b.contains('peshawar')) return 'psh';
    if (b.contains('multan')) return 'mul';
    if (b.contains('faisalabad')) return 'fsd';
    if (b.contains('islamabad')) return 'isb';
    if (b.contains('quetta')) return 'qta';
    if (b.length <= 3) return b;
    return b.substring(0, 3);
  }

  static Future<void>? _receiptChain;

  /// Receipt numbers are per-PC counters, so two PCs issue the same sequence; the
  /// terminal suffix tells them apart. Calls are serialised: the counter is read
  /// and then written with an await between, so two quick saves got one number.
  static Future<String> nextReceiptNumber([String branchId = '']) {
    final run = (_receiptChain ?? Future<void>.value()).then((_) => _nextReceiptNumberLocked(branchId));
    _receiptChain = run.then((_) {}, onError: (_) {});
    return run;
  }

  static Future<String> _nextReceiptNumberLocked(String branchId) async {
    final box = Hive.box('app_settings');
    final code = getBranchCode(branchId);

    // terminal_id is only 2 digits (random, or typed in Settings), so PCs clashed.
    // A stable 2-character code from this install's device id is appended to it.
    final suffix = box.get('terminal_suffix')?.toString() ?? '';
    if (suffix.isEmpty) {
      String dev = 'dev_unknown';
      try { dev = await PreLoginSecurityService.getDeviceId(); } catch (_) {}
      if (dev == 'dev_unknown') dev = '${DateTime.now().microsecondsSinceEpoch}';
      var h = 0;
      for (final c in dev.codeUnits) {
        h = (h * 31 + c) & 0x7fffffff;
      }
      final s = h.toRadixString(36).toUpperCase().padLeft(2, '0');
      await box.put('terminal_suffix', s.substring(s.length - 2));
    }

    final key = 'receipt_seq_$code';
    final current = box.get(key, defaultValue: 0) as int;
    final next = current + 1;
    await box.put(key, next);
    
    final globalKey = 'receipt_seq_global';
    final globalCurrent = box.get(globalKey, defaultValue: 0) as int;
    if (next > globalCurrent) await box.put(globalKey, next);

    return formatReceiptNumber(next, code);
  }

  // ── Token status order ──────────────────────────────────────────────────────
  /// Progress of a token: a lower rank arriving later is an older copy unless it is newer.
  static int _statusRank(String status) {
    switch (status.trim().toLowerCase()) {
      case 'called':
      case 'skipped':
        return 1;
      case 'in_consultation':
      case 'in consultation':
      case 'in-consultation':
      case 'inconsultation':
      case 'with_doctor':
      case 'with doctor':
      case 'consulting':
      case 'in_progress':
      case 'examining':
        return 2;
      case 'completed':
      case 'prescribed':
        return 3;
      case 'dispensed':
        return 4;
      default: // waiting, pending, '' and unknown
        return 0;
    }
  }

  /// True only when [incoming] carries an update time strictly newer than [existing]'s.
  static bool _isNewerUpdate(Map incoming, Map existing) {
    int? ms(Object? v) {
      if (v == null) return null;
      if (v is num) return v > 1e12 ? v.toInt() : (v * 1000).toInt();
      return DateTime.tryParse(v.toString())?.millisecondsSinceEpoch;
    }

    final inT = ms(incoming['statusUpdatedAt'] ?? incoming['updatedAt']);
    if (inT == null) return false;
    final exT = ms(existing['statusUpdatedAt'] ?? existing['updatedAt']);
    return exT == null || inT > exT;
  }

  // ── Token numbering ─────────────────────────────────────────────────────────
  // Online, the LAN server is the single issuer: every desk shares one sequence 1, 2, 3 ...
  // (always below [offlineBandSize]). When a desk cannot reach the server it cannot know what
  // the other desks issue, so it numbers from its own block instead: desk slot N issues
  // N*1000+1, N*1000+2 ... The slot is handed out by the LAN server (unique per PC, see
  // LanServer._deskSlotFor), so two desks that are offline at the same time never collide
  // with each other or with the shared online numbers. The serial format is unchanged.
  static const int offlineBandSize = 1000;
  static const int maxOfflineDeskSlot = 9;

  /// True for a sequence from a desk's offline block (not the shared online sequence).
  /// Offline blocks are no longer issued (one shared 001..999 sequence), so no sequence
  /// counts as an offline-band number any more. Kept for older callers.
  static bool isOfflineBandSeq(int seq) => false;

  /// This PC's stable key, sent to the LAN server so it can give the PC its own desk slot.
  static String get deskDeviceKey {
    final box = Hive.box('app_settings');
    var k = box.get('offline_desk_key')?.toString() ?? '';
    if (k.isEmpty) {
      k = 'desk_${DateTime.now().microsecondsSinceEpoch}_${identityHashCode(Object())}';
      box.put('offline_desk_key', k);
    }
    return k;
  }

  /// The offline block assigned to this PC by the LAN server (0 = never assigned yet).
  static int get offlineDeskSlot {
    if (!Hive.isBoxOpen('app_settings')) return 0;
    final v = Hive.box('app_settings').get('offline_desk_slot');
    final slot = v is num ? v.toInt() : int.tryParse(v?.toString() ?? '') ?? 0;
    return (slot >= 1 && slot <= maxOfflineDeskSlot) ? slot : 0;
  }

  /// Kept so older servers' 'deskSlot' replies are still stored, but token numbering no
  /// longer uses offline blocks (see getNextLocalSerialSequence).
  static Future<void> setOfflineDeskSlot(int slot) async {
    if (slot < 1 || slot > maxOfflineDeskSlot || !Hive.isBoxOpen('app_settings')) return;
    final box = Hive.box('app_settings');
    if (box.get('offline_desk_slot') != slot) await box.put('offline_desk_slot', slot);
  }

  /// Next token sequence for this prefix.
  ///
  /// [offlineSlot] 0: the shared online sequence (only numbers below [offlineBandSize] count).
  /// [offlineSlot] N: this desk's own offline block N*1000+1 ... N*1000+999.
  static Future<int> getNextLocalSerialSequence(
    String branchId,
    String dateKey, {
    String? dispensaryId,
    String? session,
    bool increment = false,
    int atLeast = 0,
    int offlineSlot = 0,
  }) async {
    // Normalize branchId before it's used to build/read Hive keys.
    branchId = branchId.toLowerCase().trim();
    final counterBox = Hive.box('app_settings');
    final activeCamp = dispensaryId ?? CampSessionService.getActiveCamp();
    final dispTag = CampSessionService.getDispensaryKeyword(activeCamp);
    final sessionLetter = CampSessionService.getSessionLetter(session);
    final cleanDateKey = dateKey.replaceAll(RegExp(r'[^0-9]'), '');

    // Single canonical sequence 001..999 for all online and offline tokens (no 1000+/2000+
    // offline blocks: they made the server think ~2000 tokens were missing and froze it).
    // [offlineSlot] is accepted for older callers but ignored.
    const bandLow = 0;
    const bandHigh = offlineBandSize - 1;
    bool inBand(int seq) => seq > bandLow && seq <= bandHigh;

    final counterKey = 'counter_${branchId}_${cleanDateKey}_${sessionLetter}_$dispTag';
    final rawSaved = (counterBox.get(counterKey) as num?)?.toInt() ?? 0;
    // Legacy out-of-band numbers (>999) never infect today's counter.
    final savedSeq = inBand(rawSaved) ? rawSaved : 0;

    // Fast-path for estimation display in UI (!increment) when sequence is already known
    if (!increment && savedSeq > 0) {
      final floor = (atLeast > 0 && atLeast <= bandHigh) ? atLeast : 0;
      final nextSeq = savedSeq + 1 > floor ? savedSeq + 1 : floor;
      return nextSeq > bandHigh ? bandHigh : nextSeq;
    }

    final entries = getLocalEntries(branchId, dispensaryId: activeCamp, filterByCamp: true)
        .where((m) {
          final mDk = (m['dateKey'] as String?)?.replaceAll(RegExp(r'[^0-9]'), '') ?? '';
          return mDk == cleanDateKey;
        });

    int maxSeq = savedSeq > 0 ? savedSeq : bandLow;
    for (final m in entries) {
      final s = (m['serial'] ?? '').toString().trim().toUpperCase();
      if (s.isEmpty) continue;
      final mSess = (m['session'] ?? '').toString().toLowerCase().trim();
      final hasMatchingPrefix = s.startsWith('$cleanDateKey$sessionLetter-');
      final isMatchingSession = mSess.isNotEmpty && (mSess == (session ?? '').toLowerCase().trim() ||
          CampSessionService.getSessionLetter(mSess) == sessionLetter);
      if (hasMatchingPrefix || isMatchingSession) {
        final seq = parseSequenceFromSerial(s);
        if (inBand(seq) && seq > maxSeq) maxSeq = seq;
      }
    }

    // [atLeast]: a number the LAN server issued, so this desk's own count continues after it.
    // A legacy server number above 999 is ignored; the sequence never leaves 001..999.
    final floor = (atLeast > 0 && atLeast <= bandHigh) ? atLeast : 0;
    var nextSeq = maxSeq + 1 > floor ? maxSeq + 1 : floor;
    if (nextSeq > bandHigh) {
      debugPrint('[LocalStorage] ⚠️ Token sequence passed 999 ($nextSeq) — held at 999');
      nextSeq = bandHigh;
    }
    if (increment) {
      await counterBox.put(counterKey, nextSeq);
    }
    return nextSeq;
  }

  static String formatReceiptNumber(int seq, [String branchCode = '']) {
    final padded = seq.toString().padLeft(3, '0');
    final settings = Hive.box('app_settings');
    final tid = '${settings.get('terminal_id', defaultValue: '') ?? ''}${settings.get('terminal_suffix', defaultValue: '') ?? ''}';

    String res = 'GMWF';
    if (branchCode.isNotEmpty) res += '-$branchCode';
    res += '-$padded';
    if (tid.isNotEmpty) res += '-$tid';
    
    return res;
  }

  static Future<String> nextDonorNumber() async {
    final box = Hive.box('app_settings');
    const key = 'donor_global_seq';
    final current = box.get(key, defaultValue: 0) as int;
    final next = current + 1;
    await box.put(key, next);
    
    return formatDonorId(next);
  }

  static String formatDonorId(int seq) {
    final padded = seq.toString().padLeft(8, '0');
    return 'DNR-$padded';
  }

  // ── Branch Data Enrichment Helper ──────────────────────────────────────────
  /// Token number shown on screens, e.g. "071126E-HAJI-005" -> "005" (always 001..999 style,
  /// 3 digits). Ignores a "-COLLISION-..." suffix. Returns '' when no number can be found.
  static String formatTokenDisplay(String? serial) {
    var s = (serial ?? '').trim();
    if (s.isEmpty) return '';
    final coll = s.toUpperCase().indexOf('-COLLISION');
    if (coll > 0) s = s.substring(0, coll);
    final m = RegExp(r'(\d+)\D*$').firstMatch(s);
    if (m == null) return '';
    final n = int.tryParse(m.group(1)!);
    if (n == null) return m.group(1)!;
    return _canonicalSeq(n).toString().padLeft(3, '0');
  }

  /// Legacy offline-band numbers (1001.., 2001..) folded back into 001..999.
  static int _canonicalSeq(int n) {
    if (n < offlineBandSize) return n;
    final r = n % offlineBandSize;
    return r == 0 ? n : r;
  }

  /// The full serial with its token number shown as 001..999, e.g.
  /// "071126E-HAJI-2003" -> "071126E-HAJI-003". '-' when empty.
  static String formatCanonicalSerialForDisplay(String? serial) {
    final s = (serial ?? '').trim();
    if (s.isEmpty) return '-';
    final m = RegExp(r'^(.*-)(\d{4,})$').firstMatch(s);
    if (m == null) return s;
    final n = int.tryParse(m.group(2)!);
    if (n == null) return s;
    return '${m.group(1)}${_canonicalSeq(n).toString().padLeft(3, '0')}';
  }

  /// The state of a token as the LAN server last saw it from this PC (entry field
  /// 'lanPushSig'). SyncService re-sends a token to the LAN server only when this changes,
  /// and tokens received from the server are stamped with it, so they are never echoed back.
  static String lanPushSignature(Map<dynamic, dynamic> m) => [
        m['status'], m['dispenseStatus'], m['updatedAt'], m['completedAt'],
        m['dispensedAt'], m['prescription'] != null || m['medicines'] != null,
      ].join('|');

  /// True for a missing value or a display placeholder ('Unknown', 'N/A', '-') that an
  /// earlier enrichment wrote in place of a missing field. Maps, numbers and bools are real.
  static bool isPlaceholderValue(Object? v) {
    if (v == null) return true;
    if (v is! String) return false;
    final s = v.trim().toLowerCase();
    return s.isEmpty || s == 'unknown' || s == 'unknown patient' || s == 'n/a' ||
        s == '-' || s == '—' || s == 'null';
  }

  /// First candidate that is a real value (see [isPlaceholderValue]), or ''.
  static String firstRealValue(List<Object?> candidates) {
    for (final c in candidates) {
      if (!isPlaceholderValue(c)) return c.toString().trim();
    }
    return '';
  }

  static String _firstNonEmpty(List<dynamic> candidates) {
    for (final c in candidates) {
      final s = c?.toString().trim() ?? '';
      if (s.isNotEmpty && s != 'N/A' && s != 'null') return s;
    }
    return '';
  }

  static String _resolvePatientId(Map<String, dynamic> data) {
    for (final key in ['patientId', 'id', 'uid']) {
      final v = data[key]?.toString().trim() ?? '';
      if (v.isNotEmpty) return v;
    }
    return '';
  }

  static String _resolveType(Map<String, dynamic> data, {String? branchId}) {
    final raw = (data['queueType'] ?? data['type'] ?? '').toString().toLowerCase().trim();
    final effectiveBranch = (branchId ?? data['branchId'] ?? '').toString().toLowerCase().trim();
    final isKarachi = effectiveBranch.contains('karachi') ||
        effectiveBranch.contains('haji') ||
        effectiveBranch.contains('saddar') ||
        effectiveBranch.contains('kapaya');
    if (isKarachi && (raw == 'non-zakat' || raw.contains('non'))) {
      return 'zakat';
    }
    switch (raw) {
      case 'zakat':     return 'zakat';
      case 'non-zakat': return 'non-zakat';
      case 'gmwf':      return 'gmwf';
      default:          return 'Unknown';
    }
  }

  static Future<List<Map<String, dynamic>>> enrichRawDocs(
      String branchId, List<Map<String, dynamic>> rawList) async {
    if (rawList.isEmpty) return [];
    final normBranchId = branchId.toLowerCase().trim();

    final serialToDoctor  = <String, String>{};
    final serialToTokenBy = <String, String>{};
    final serialToDays    = <String, int>{};
    
    final List<String> missingDoctorSerials = [];
    for (final item in rawList) {
      final serial = item['serial']?.toString() ?? '';
      final existingDoctor = _firstNonEmpty([item['doctorName'], item['prescribedBy'], item['updatedBy']]);
      if (existingDoctor.isEmpty && serial.isNotEmpty) {
        missingDoctorSerials.add(serial);
      }
    }

    final List<List<String>> serialChunks = [];
    for (int i = 0; i < missingDoctorSerials.length; i += 30) {
      serialChunks.add(missingDoctorSerials.sublist(i, (i + 30).clamp(0, missingDoctorSerials.length)));
    }

    final List<Future<QuerySnapshot>> presFutures = [];
    for (final chunk in serialChunks) {
      presFutures.add(FirebaseFirestore.instance
          .collectionGroup('prescriptions')
          .where('branchId', isEqualTo: normBranchId)
          .where('serial', whereIn: chunk)
          .get());
    }

    try {
      if (presFutures.isNotEmpty) {
        final presSnaps = await Future.wait(presFutures);
        for (final snap in presSnaps) {
          for (final doc in snap.docs) {
            final data = doc.data() as Map<String, dynamic>;
            final serial = data['serial']?.toString() ?? '';
            if (serial.isEmpty) continue;
            final doctor = _firstNonEmpty([data['doctorName'], data['prescribedBy'], data['updatedBy']]);
            if (doctor.isNotEmpty) serialToDoctor[serial] = doctor;
            if (!serialToDays.containsKey(serial)) {
              final pd = (data['daysOfMedicine'] as num?)?.toInt() ?? 1;
              if (pd > 1) serialToDays[serial] = pd;
            }
          }
        }
      }
    } catch (e) {
      debugPrint('[LocalStorage] collectionGroup prescriptions query failed: $e. Falling back to direct doc gets.');
      for (final item in rawList) {
        final serial = item['serial']?.toString() ?? '';
        if (serial.isEmpty) continue;
        final existingDoctor = _firstNonEmpty([item['doctorName'], item['prescribedBy'], item['updatedBy']]);
        if (existingDoctor.isNotEmpty) continue;
        final pId = _firstNonEmpty([
          item['patientCnic'], item['cnic'], item['guardianCnic'],
          item['patientId'], item['id']
        ]);
        if (pId.isEmpty) continue;
        try {
          final doc = await FirebaseFirestore.instance
              .collection('branches')
              .doc(normBranchId)
              .collection('prescriptions')
              .doc(pId)
              .collection('prescriptions')
              .doc(serial)
              .get();
          if (doc.exists && doc.data() != null) {
            final data = doc.data() as Map<String, dynamic>;
            final doctor = _firstNonEmpty([data['doctorName'], data['prescribedBy'], data['updatedBy']]);
            if (doctor.isNotEmpty) serialToDoctor[serial] = doctor;
            if (!serialToDays.containsKey(serial)) {
              final pd = (data['daysOfMedicine'] as num?)?.toInt() ?? 1;
              if (pd > 1) serialToDays[serial] = pd;
            }
          }
        } catch (directErr) {
          debugPrint('[LocalStorage] Direct prescription fetch failed for $serial: $directErr');
        }
      }
    }

    final List<String> missingTokenZakat = [];
    final List<String> missingTokenNonZakat = [];
    final List<String> missingTokenGmwf = [];

    for (final item in rawList) {
      final serial = item['serial']?.toString() ?? '';
      if (serial.isEmpty) continue;

      final days = (item['daysOfMedicine'] as num?)?.toInt() ?? 1;
      if (days > 1) serialToDays[serial] = days;

      final existingToken = _firstNonEmpty(
          [item['createdByName'], item['tokenBy'], item['createdBy']]);
      if (existingToken.isEmpty) {
        final type = _resolveType(item, branchId: normBranchId);
        if (type == 'zakat') {
          missingTokenZakat.add(serial);
        } else if (type == 'non-zakat') {
          missingTokenNonZakat.add(serial);
        } else if (type == 'gmwf') {
          missingTokenGmwf.add(serial);
        }
      }
    }

    final List<Future<QuerySnapshot>> tokenFutures = [];
    void addTokenFutures(List<String> serials, String collectionName) {
      for (int i = 0; i < serials.length; i += 30) {
        final chunk = serials.sublist(i, (i + 30).clamp(0, serials.length));
        tokenFutures.add(FirebaseFirestore.instance
            .collectionGroup(collectionName)
            .where('branchId', isEqualTo: normBranchId)
            .where('serial', whereIn: chunk)
            .get());
      }
    }

    addTokenFutures(missingTokenZakat, 'zakat');
    addTokenFutures(missingTokenNonZakat, 'non-zakat');
    addTokenFutures(missingTokenGmwf, 'gmwf');

    try {
      if (tokenFutures.isNotEmpty) {
        final tokenSnaps = await Future.wait(tokenFutures);
        for (final snap in tokenSnaps) {
          for (final doc in snap.docs) {
            final data = doc.data() as Map<String, dynamic>;
            final serial = data['serial']?.toString() ?? '';
            if (serial.isEmpty) continue;
            final tokenBy = _firstNonEmpty([data['createdByName'], data['tokenBy'], data['createdBy']]);
            if (tokenBy.isNotEmpty) serialToTokenBy[serial] = tokenBy;
            if (!serialToDays.containsKey(serial)) {
              final pd = (data['daysOfMedicine'] as num?)?.toInt() ?? 1;
              if (pd > 1) serialToDays[serial] = pd;
            }
          }
        }
      }
    } catch (e) {
      debugPrint('[LocalStorage] collectionGroup tokens query failed: $e. Falling back to direct doc gets.');
      for (final item in rawList) {
        final serial = item['serial']?.toString() ?? '';
        if (serial.isEmpty) continue;
        final existingToken = _firstNonEmpty([item['createdByName'], item['tokenBy'], item['createdBy']]);
        if (existingToken.isNotEmpty) continue;
        
        final type = _resolveType(item, branchId: normBranchId);
        if (type == 'Unknown') continue;
        
        final dateKey = item['dateKey']?.toString() ?? 
                       (serial.contains('-') ? serial.split('-')[0] : DateFormat('ddMMyy').format(DateTime.now()));
                       
        try {
          final doc = await FirebaseFirestore.instance
              .collection('branches')
              .doc(normBranchId)
              .collection('serials')
              .doc(dateKey)
              .collection(type)
              .doc(serial)
              .get();
          if (doc.exists && doc.data() != null) {
            final data = doc.data() as Map<String, dynamic>;
            final tokenBy = _firstNonEmpty([data['createdByName'], data['tokenBy'], data['createdBy']]);
            if (tokenBy.isNotEmpty) serialToTokenBy[serial] = tokenBy;
            if (!serialToDays.containsKey(serial)) {
              final pd = (data['daysOfMedicine'] as num?)?.toInt() ?? 1;
              if (pd > 1) serialToDays[serial] = pd;
            }
          }
        } catch (directErr) {
          debugPrint('[LocalStorage] Direct token fetch failed for $serial (type: $type, date: $dateKey): $directErr');
        }
      }
    }


    final uniquePatientIds =
        rawList.map((d) => _resolvePatientId(d)).where((id) => id.isNotEmpty).toSet();
    Map<String, Map<String, dynamic>> patientMap = {};
    final patientBox = Hive.box(patientsBox);
    for (final pid in uniquePatientIds) {
      final localData = patientBox.get(pid);
      if (localData is Map) {
        patientMap[pid] = Map<String, dynamic>.from(localData);
      }
    }

    final guardianCnics = <String>{};
    for (final p in patientMap.values) {
      final cnic = p['cnic']?.toString().trim() ?? '';
      if (cnic.isEmpty) {
        final gcnic = p['guardianCnic']?.toString().trim() ?? '';
        if (gcnic.isNotEmpty) guardianCnics.add(gcnic);
      }
    }
    final Map<String, String> guardianNames = {};
    for (final gcnic in guardianCnics) {
      final localGuardian = getLocalPatientByCnic(gcnic);
      if (localGuardian != null) {
        guardianNames[gcnic] = localGuardian['name'] ?? 'N/A';
      }
    }

    final enriched = <Map<String, dynamic>>[];
    for (final data in rawList) {
      final pid    = _resolvePatientId(data);
      final p      = pid.isNotEmpty ? patientMap[pid] : null;
      final serial = data['serial']?.toString() ?? '';

      // Hive returns Map<dynamic, dynamic>: a direct `as Map<String, dynamic>` cast threw here,
      // so every enrichment fell back to the minimal _fallbackEnrich.
      final vitals = data['vitals'] is Map ? Map<String, dynamic>.from(data['vitals'] as Map) : <String, dynamic>{};

      // A stale 'Unknown' in patientName must not hide the real name in 'name'.
      final realName = firstRealValue([
        data['patientName'], data['name'], data['fullName'], vitals['name'], p?['name'],
      ]);
      final name = realName.isNotEmpty ? realName : 'Unknown';
      final phone = _firstNonEmpty([data['phone'], p?['phone'], 'N/A']);
      final age   = _firstNonEmpty([
        data['patientAge'], data['age'], vitals['age']?.toString(), p?['age']?.toString(), 'N/A',
      ]);
      final gender = _firstNonEmpty([
        data['patientGender'], data['gender'], vitals['gender'], p?['gender'], 'N/A',
      ]);
      final bloodGroup = _firstNonEmpty([
        data['bloodGroup'], vitals['bloodGroup'], p?['bloodGroup'], 'N/A',
      ]);

      String  displayCnic = 'N/A';
      bool    isChild     = false;
      String? guardianName;
      final directCnic = _firstNonEmpty(
          [data['patientCnic'], data['cnic'], p?['cnic']?.toString().trim()]);
      if (directCnic.isNotEmpty && directCnic != 'N/A' && directCnic != '0000000000000') {
        displayCnic = directCnic;
        isChild     = false;
      } else {
        final gcnic = _firstNonEmpty([data['guardianCnic'], p?['guardianCnic']?.toString().trim()]);
        displayCnic = gcnic.isNotEmpty ? gcnic : 'N/A';
        isChild     = true;
        if (gcnic.isNotEmpty) guardianName = guardianNames[gcnic];
      }

      final possibleIds = <String>{};
      if (pid.isNotEmpty) possibleIds.add(pid);
      if (directCnic.isNotEmpty && directCnic != 'N/A') possibleIds.add(directCnic);
      if (isChild && displayCnic != 'N/A') possibleIds.add(displayCnic);

      final medicDays = serialToDays[serial] ?? 1;

      final type = _resolveType(data, branchId: normBranchId);
      int tokenAmount = 0;
      if (type == 'zakat')     tokenAmount = 20  * medicDays;
      if (type == 'non-zakat') tokenAmount = 100 * medicDays;

      enriched.add({
        ...data,
        if (realName.isNotEmpty) 'patientName': realName,
        'name':           name,
        'phone':          phone,
        'age':            age,
        'gender':         gender,
        'bloodGroup':     bloodGroup,
        'displayCnic':    displayCnic,
        'isChild':        isChild,
        if (guardianName != null) 'guardianName': guardianName,
        'patientId':      pid,
        'possibleIds':    possibleIds.toList(),
        'doctorName':     _firstNonEmpty([
          data['doctorName'], data['prescribedBy'], data['updatedBy'],
          serialToDoctor[serial], 'Unknown',
        ]),
        'dispenserName':  _firstNonEmpty([data['dispenserName'], data['dispensedBy'], 'Unknown']),
        'tokenBy':        _firstNonEmpty([
          data['createdByName'], data['tokenBy'], serialToTokenBy[serial],
          data['createdBy'], 'Unknown',
        ]),
        'frequentFlag':   p?['frequentFlag'] ?? false,
        'daysOfMedicine': medicDays,
        'tokenAmount':    tokenAmount,
      });
    }

    return enriched;
  }

  // ── Delta Sync Metadata & Server Timestamp Helpers ─────────────────────────
  static String? getLastSyncedServerTimestamp(String collectionKey) {
    try {
      final box = Hive.box(syncMetaBox);
      return box.get('last_server_ts_$collectionKey') as String?;
    } catch (_) {
      return null;
    }
  }

  static Future<void> setLastSyncedServerTimestamp(String collectionKey, String isoTimestamp) async {
    try {
      final box = Hive.box(syncMetaBox);
      await box.put('last_server_ts_$collectionKey', isoTimestamp);
      await box.flush();
    } catch (e) {
      debugPrint('[LocalStorageService] setLastSyncedServerTimestamp error: $e');
    }
  }

  static Future<void> logSyncConflict({
    required String collectionKey,
    required String docId,
    required Map<String, dynamic> localData,
    required Map<String, dynamic> cloudData,
  }) async {
    try {
      final box = Hive.box(syncMetaBox);
      final rawLogs = box.get('sync_conflicts_log', defaultValue: <dynamic>[]);
      final logs = List<Map<String, dynamic>>.from(
        (rawLogs as List).map((item) => Map<String, dynamic>.from(item as Map)),
      );

      logs.add({
        'timestamp': DateTime.now().toUtc().toIso8601String(),
        'collection': collectionKey,
        'docId': docId,
        'localData': localData,
        'cloudData': cloudData,
      });

      if (logs.length > 100) {
        logs.removeRange(0, logs.length - 100);
      }

      await box.put('sync_conflicts_log', logs);
      await box.flush();
      debugPrint('[LocalStorageService] Sync conflict logged for $collectionKey/$docId');
    } catch (e) {
      debugPrint('[LocalStorageService] logSyncConflict error: $e');
    }
  }

  static bool isSoftDeleted(Map<String, dynamic> record) {
    return record['isDeleted'] == true;
  }

  // [FIX-1.1] Attendance server role gate
  static bool isAttendanceServerRole() {
    if (!Hive.isBoxOpen('app_settings')) return false;
    return Hive.box('app_settings').get('is_attendance_server', defaultValue: false) == true;
  }

  static Future<void> setAttendanceServerRole(bool value) async {
    if (!Hive.isBoxOpen('app_settings')) return;
    await Hive.box('app_settings').put('is_attendance_server', value);
  }
}

class _LocalEntriesCacheEntry {
  final DateTime timestamp;
  final List<Map<String, dynamic>> entries;
  _LocalEntriesCacheEntry(this.timestamp, this.entries);
}

/// One token in LocalStorageService's per-branch entries index: a copy of the stored record
/// (so callers never touch Hive's own object) and the serial getLocalEntries de-duplicates on.
class _BranchEntry {
  final Map<String, dynamic> entry;
  final String serialKey;
  _BranchEntry(this.entry, this.serialKey);

  factory _BranchEntry.of(Map val, String normBranch) {
    final entry = Map<String, dynamic>.from(val);
    final s = (entry['serial'] ?? entry['id'] ?? '').toString().trim().toUpperCase();
    final prefix = '$normBranch-'.toUpperCase();
    return _BranchEntry(entry, s.startsWith(prefix) ? s.substring(normBranch.length + 1) : s);
  }
}
