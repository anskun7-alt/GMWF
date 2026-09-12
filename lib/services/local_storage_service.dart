// lib/services/local_storage_service.dart

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:crypto/crypto.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';
import 'package:intl/intl.dart';
import 'package:uuid/uuid.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;
import 'package:gmwf/services/sync_service.dart';
import 'camp_session_service.dart';
import 'master_proforma_service.dart';
import 'serials_service.dart';
import '../tools/legacy_data_migration_adapter.dart';
import '../realtime/realtime_manager.dart';
import '../realtime/realtime_events.dart';

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
        final b = box.get('selected_branch') ?? box.get('current_branch') ?? box.get('branchId');
        if (b != null && b.toString().trim().isNotEmpty && b.toString().trim().toLowerCase() != 'all') {
          return b.toString().trim().toLowerCase();
        }
        final uData = box.get('user_data') ?? box.get('currentUser');
        if (uData is Map) {
          final ub = uData['branchId'] ?? uData['branch'];
          if (ub != null && ub.toString().trim().isNotEmpty && ub.toString().trim().toLowerCase() != 'all') {
            return ub.toString().trim().toLowerCase();
          }
        }
      }
    } catch (_) {}
    return null;
  }

  static Future<void> saveLocalEditRequest(Map<String, dynamic> requestData) async {
    try {
      final box = await openBoxSafe('local_edit_requests');
      final id = (requestData['id'] ?? requestData['requestId'] ?? requestData['docId'] ?? '').toString();
      if (id.isNotEmpty) {
        final existing = box.get(id);
        final merged = existing is Map ? (Map<String, dynamic>.from(existing)..addAll(requestData)) : requestData;
        await box.put(id, merged);
      }
    } catch (e) {
      debugPrint('[LocalStorageService] saveLocalEditRequest error: $e');
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

  static bool isMadrassaFeeEnabled(String branchId) {
    final b = branchId.toLowerCase().trim();
    if (b.isEmpty || b == 'all' || b == 'global') return true;

    if (Hive.isBoxOpen(branchesBox)) {
      final box = Hive.box(branchesBox);
      final raw = box.get('branch:$b');
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

  /// Isolate-safe and concurrency-safe method to ensure a Hive box is open.
  /// Uses Completer mutex lock so concurrent calls for the same box do not race.
  static Future<Box<T>> ensureBoxOpen<T>(String name) async {
    markBoxAccessed(name);
    if (Hive.isBoxOpen(name)) {
      return Hive.box<T>(name);
    }

    if (_boxOpenLocks.containsKey(name)) {
      final box = await _boxOpenLocks[name]!.future;
      return box as Box<T>;
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
    markBoxAccessed(name);
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
        return Hive.box<T>(name);
      }

      try {
        await Future.delayed(const Duration(milliseconds: 500));
        if (Hive.isBoxOpen(name)) {
          debugPrint('[LocalStorageService] ✅ Box "$name" completed opening in background after 500ms delay.');
          return Hive.box<T>(name);
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
          return Hive.box<T>(name);
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
      debugPrint('[LocalStorageService] ⚠️ Open attempt failed for "$name": $e. Retrying once before backup...');
      await _logStorageError(name, 'Initial open failed: $e', st);

      if (Hive.isBoxOpen(name)) {
        return Hive.box<T>(name);
      }

      try {
        await Future.delayed(const Duration(milliseconds: 500));
        if (Hive.isBoxOpen(name)) {
          return Hive.box<T>(name);
        }
        return await Hive.openBox<T>(name).timeout(
          const Duration(seconds: 15),
          onTimeout: () {
            throw TimeoutException("Retry timeout (15s) opening Hive box: $name");
          },
        );
      } catch (retryEx, retrySt) {
        if (Hive.isBoxOpen(name)) {
          return Hive.box<T>(name);
        }
        debugPrint('[LocalStorageService] ❌ Retry failed for "$name": $retryEx. Proceeding to backup + single-box recovery.');
        await _logStorageError(name, 'Retry open failed: $retryEx', retrySt);

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

  static Future<bool> _backupCorruptedBoxFiles(String boxName) async {
    try {
      final hivePath = await _getHiveDirectoryPath();
      if (hivePath == null || hivePath.isEmpty) return false;
      final hiveDir = Directory(hivePath);
      if (!await hiveDir.exists()) return false;

      final nowMs = DateTime.now().millisecondsSinceEpoch;
      bool backedUp = false;

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
      return backedUp;
    } catch (e) {
      debugPrint('[LocalStorageService] Failed to backup box files for $boxName: $e');
      return false;
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

  /// Resolves the union of Hive boxes required for a set of roles/modules.
  static Set<String> getBoxesForRoles(List<String> roles) {
    final Set<String> targetBoxes = Set<String>.from(coreBoxNames);
    final normalizedRoles = roles.map((r) => r.toLowerCase().trim()).toSet();

    final isAdmin = normalizedRoles.any((r) =>
        r == 'admin' ||
        r == 'superadmin' ||
        r == 'chairman' ||
        r == 'hq' ||
        r == 'global_admin');

    if (isAdmin) {
      // Admins load all module boxes
      targetBoxes.addAll([
        patientsBox, entriesBox, prescriptionsBox, stockBox, medicineRestrictionsBox,
        masterProformaBox, tokenExceptionsBox, reportsCacheBox, donationsBox, donorsBox,
        employeesBox, salaryHistoryBox, attendanceBox, salaryLedgerBox, financeSettingsBox,
        branchTransfersBox, auditLogsBox, madrassaStudentsBox, madrassaLogsBox, madrassaHolidaysBox,
        madrassaFeesBox, schoolStudentsBox, schoolLogsBox, schoolTeachersBox, schoolBooksBox,
        schoolBookLoansBox, schoolAuditLogsBox, schoolGradesBox, schoolFeesBox, schoolHomeroomBox,
        financeHolidaysBox, financeLoansBox, expensesBox, biometricDevicesBox, biometricCredentialsBox,
        unmappedPunchesBox, crossBranchPunchesBox, zktecoPunchDedupBox, chartOfAccountsBox,
        orgBankAccountsBox, journalEntriesBox, journalIndexBox, departmentMapBox, dasterkhwaanTokensBox,
      ]);
      return targetBoxes;
    }

    // Dispensary clinical roles (doctor, dispenser, pharmacist, nurse, receptionist, inventory)
    if (normalizedRoles.any((r) =>
        r.contains('dispensar') ||
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
        r.contains('stock'))) {
      targetBoxes.addAll([
        patientsBox,
        entriesBox,
        prescriptionsBox,
        stockBox,
        dispensaryBox,
        medicineRestrictionsBox,
        masterProformaBox,
        tokenExceptionsBox,
        reportsCacheBox,
      ]);
    }

    // Madrassa roles
    if (normalizedRoles.any((r) => r.contains('madrassa') || r.contains('qari') || r.contains('guardian') || r.contains('nazim'))) {
      targetBoxes.addAll([
        madrassaStudentsBox,
        madrassaLogsBox,
        madrassaHolidaysBox,
        madrassaFeesBox,
        unmappedPunchesBox,
        crossBranchPunchesBox,
      ]);
    }

    // School roles
    if (normalizedRoles.any((r) => r.contains('school') || r.contains('teacher') || r.contains('principal'))) {
      targetBoxes.addAll([
        schoolStudentsBox,
        schoolLogsBox,
        schoolTeachersBox,
        schoolBooksBox,
        schoolBookLoansBox,
        schoolAuditLogsBox,
        schoolGradesBox,
        schoolFeesBox,
        schoolHomeroomBox,
      ]);
    }

    // Finance / HR roles
    if (normalizedRoles.any((r) => r.contains('finance') || r.contains('accountant') || r.contains('hr') || r.contains('manager'))) {
      targetBoxes.addAll([
        employeesBox,
        salaryHistoryBox,
        attendanceBox,
        salaryLedgerBox,
        financeSettingsBox,
        branchTransfersBox,
        auditLogsBox,
        financeHolidaysBox,
        financeLoansBox,
        expensesBox,
        chartOfAccountsBox,
        orgBankAccountsBox,
        journalEntriesBox,
        journalIndexBox,
        departmentMapBox,
      ]);
    }

    // Biometrics / Security roles
    if (normalizedRoles.any((r) => r.contains('security') || r.contains('biometric') || r.contains('gatekeeper'))) {
      targetBoxes.addAll([
        biometricDevicesBox,
        biometricCredentialsBox,
        unmappedPunchesBox,
        crossBranchPunchesBox,
        zktecoPunchDedupBox,
      ]);
    }

    // Welfare / Dasterkhwaan / Donations / Office Boy
    if (normalizedRoles.any((r) => r.contains('welfare') || r.contains('donation') || r.contains('dasterkhwaan') || r.contains('office') || r.contains('kitchen'))) {
      targetBoxes.addAll([
        donationsBox,
        donorsBox,
        dasterkhwaanTokensBox,
        dasterkhwaanCookingBox,
        dasterkhwaanFoodLogsBox,
        'local_donation_boxes',
        'local_box_openings',
        'local_bank_slips',
      ]);
    }

    return targetBoxes;
  }

  /// Starts the LRU eviction timer to safely close on-demand boxes idle for >15 minutes.
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
        if (coreBoxNames.contains(name)) continue;
        // Never evict clinical/doctor dispensary boxes or core transaction boxes
        if (name == entriesBox ||
            name == patientsBox ||
            name == prescriptionsBox ||
            name == stockBox ||
            name == dispensaryBox ||
            name == medicineRestrictionsBox ||
            name == masterProformaBox ||
            name == tokenExceptionsBox ||
            name == reportsCacheBox ||
            name == madrassaStudentsBox ||
            name == madrassaLogsBox ||
            name == madrassaHolidaysBox ||
            name == madrassaFeesBox ||
            name == donationsBox ||
            name == donorsBox ||
            name == dasterkhwaanTokensBox ||
            name == 'local_donation_boxes' ||
            name == 'local_box_openings') {
          continue;
        }
        if (hasActiveWriteLock(name)) continue;

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
      await ensureBoxOpen(name);
    }
  }

  /// Initializes core boxes and then loads boxes for specific active roles.
  static Future<void> initForRoles(List<String> roles) async {
    await checkForUnrecoveredBackups();
    final boxNames = getBoxesForRoles(roles);
    debugPrint('[LocalStorageService.initForRoles] Initializing ${boxNames.length} role-specific Hive boxes (roles: $roles)...');

    for (final name in boxNames) {
      await ensureBoxOpen(name);
    }

    await checkAndRunSchemaMigrations();
    startLruEvictionTimer();
  }

  static Future<void> init() async {
    debugPrint('[LocalStorageService.init] Initializing core Hive boxes and startup migration...');
    await checkForUnrecoveredBackups();

    // Open permanent core boxes
    for (final name in coreBoxNames) {
      await ensureBoxOpen(name);
    }

    // Always ensure clinical dispensary boxes are open at startup
    // to guarantee Doctor, Receptionist, Dispenser, and Hybrid modes never crash or hit closed boxes.
    await ensureDoctorBoxesOpen();

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
    
    try {
      await MasterProformaService.seedDefaultProformaIfEmpty();
      await MasterProformaService.sanitizeAllSavedStockItems();
    } catch (e) {
      debugPrint('[LocalStorageService.init] Error seeding proforma: $e');
    }

    try {
      await sanitizeLocalEntriesCasingAndUnknowns('default');
    } catch (_) {}

    try {
      await unifyAndMergeAllLocalSerials('default');
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

    compactAllBoxes();
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

  static dynamic sanitizeValue(dynamic item) {
    if (item is Timestamp || item is DateTime) {
      return _toDateTime(item).toIso8601String();
    }
    if (item is Map) return sanitize(Map<String, dynamic>.from(item));
    return item;
  }

  static String getTodayDateKey() => DateFormat('ddMMyy').format(DateTime.now());

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

  static String _newLocalId() => const Uuid().v4();

  // ════════════════════════════════════════════════════════════════════════════
  // SYNC QUEUE
  // ════════════════════════════════════════════════════════════════════════════

  static Future<int> purgeDuplicateSyncQueue() => purgeBloatedSyncQueue();

  /// Purges bloated, duplicate, and obsolete entries across all sync queue boxes.
  static Future<int> purgeBloatedSyncQueue() async {
    int totalPurged = 0;
    for (final boxName in [syncBox, 'server_sync_queue']) {
      try {
        if (!Hive.isBoxOpen(boxName)) {
          await openBoxSafe(boxName);
        }
        final box = Hive.box(boxName);
        if (box.isEmpty) continue;

        final initialCount = box.length;
        final Map<String, dynamic> uniqueLatest = {};
        final List<dynamic> keysToDelete = [];

        for (final key in box.keys) {
          final raw = box.get(key);
          if (raw == null || raw is! Map) {
            keysToDelete.add(key);
            continue;
          }
          final item = Map<String, dynamic>.from(raw);
          final type = (item['type'] ?? item['event_type'] ?? '').toString().trim();
          if (type.isEmpty || (item['data'] == null && !type.startsWith('delete_'))) {
            keysToDelete.add(key);
            continue;
          }

          final branchId = (item['branchId'] ?? (item['data'] is Map ? item['data']['branchId'] : '') ?? '').toString().toLowerCase().trim();
          final entityId = (item['entityId'] ?? item['serial'] ?? item['patientId'] ?? item['employeeId'] ?? item['localId'] ?? item['id'] ?? (item['data'] is Map ? (item['data']['serial'] ?? item['data']['id']) : '') ?? '').toString().trim();
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

          final isSerialAction = {'save_entry', 'save_prescription', 'update_serial_status'}.contains(type);
          String groupKey;
          if (isSerialAction && entityId.isNotEmpty) {
            groupKey = 'token_${branchId}_${entityId.toUpperCase()}';
          } else if (type == 'update_inventory') {
            final medId = (item['medicineId'] ?? (item['data'] is Map ? item['data']['medicineId'] : '') ?? '').toString().trim();
            final campId = (item['campId'] ?? (item['data'] is Map ? item['data']['campId'] : '') ?? '').toString().trim();
            groupKey = 'inv_${branchId}_${medId}_$campId';
          } else {
            groupKey = entityId.isNotEmpty
                ? '${type}_${branchId}_${entityId}_$dateKey${punchSeq.isNotEmpty ? "_$punchSeq" : ""}'
                : key.toString();
          }

          if (type == 'save_patient' && entityId.isNotEmpty) {
            final isSynced = Hive.isBoxOpen('app_flags') &&
                Hive.box('app_flags').get('patient_synced_$entityId') == true;
            if (isSynced) {
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

        for (final key in keysToDelete) {
          await box.delete(key);
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

  static Future<void> enqueueSync(Map<String, dynamic> action) async {
    if (!Hive.isBoxOpen(syncBox)) {
      await openBoxSafe(syncBox);
    }
    final box = Hive.box(syncBox);
    final actionCopy = Map<String, dynamic>.from(action);
    final type = (actionCopy['type'] ?? 'unknown').toString();

    // Unified serial lifecycle: token creation, prescription, and dispense
    // share a single canonical entityId (branchId-serial).
    const serialActionTypes = {'save_entry', 'save_prescription', 'update_serial_status'};
    final branchIdRaw = (actionCopy['branchId'] ?? (actionCopy['data'] is Map ? actionCopy['data']['branchId'] : null))?.toString().toLowerCase().trim() ?? '';
    final serialRaw   = (actionCopy['serial']   ?? (actionCopy['data'] is Map ? (actionCopy['data']['serial'] ?? actionCopy['data']['id']) : null))?.toString().trim().toUpperCase() ?? '';

    if (serialActionTypes.contains(type) && branchIdRaw.isNotEmpty && serialRaw.isNotEmpty) {
      actionCopy['entityId'] = '$branchIdRaw-$serialRaw';
    }

    // Ensure stable syncId and entityId (UUID v4)
    actionCopy['syncId'] ??= const Uuid().v4();
    actionCopy['entityId'] ??= actionCopy['localId'] ?? (actionCopy['data'] is Map ? (actionCopy['data']['localId'] ?? actionCopy['data']['id']) : null) ?? actionCopy['id'] ?? actionCopy['syncId'];
    final entityId = actionCopy['entityId'].toString().trim();

    // [PERF-O(1)] Deterministic key generation replaces O(N) linear search
    String key;
    if (serialActionTypes.contains(type) && serialRaw.isNotEmpty) {
      key = 'sync_serial_${branchIdRaw}_$serialRaw';
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
              '0')
          .toString()
          .replaceAll(':', '')
          .replaceAll('-', '')
          .replaceAll('T', '_');
      key = 'sync_att_${branchIdRaw}_${empId}_${dt}_$punchSeq';
    } else if (entityId.isNotEmpty && entityId != actionCopy['syncId']) {
      key = 'sync_${type}_${branchIdRaw}_$entityId';
    } else {
      key = actionCopy['syncId'].toString();
    }

    // O(1) Instant Deduplication and Data Merging
    final existing = box.get(key);
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
    }

    if (['update_inventory', 'add_inventory_stock', 'register_medicine', 'save_token_exception_request', 'approve_token_exception'].contains(actionCopy['type'])) {
      actionCopy['txId'] ??= const Uuid().v4();
    }
    final enriched = {
      ...actionCopy,
      'attempts':    0,
      'createdAt':   _nowIso(),
      'lastAttempt': null,
      'lastError':   null,
      'status':      'pending',
    };
    await box.put(key, sanitize(enriched));
    debugPrint('[SyncQueue] Enqueued: ${actionCopy['type']} | key: $key | entityId: $entityId | total: ${box.length}');
    
    // Trigger sync upload immediately in background (Hive -> Firestore)
    SyncService().triggerUpload();
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

    await enqueueSync({
      'type':     'save_donation',
      'branchId': branchIdNorm,
      'localId':  localId,
      'hiveKey':  key,
      'data':     sanitized,
    });

    return key;
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
      for (final doc in snap.docs) {
        if (doc.id == 'credit_ledger') continue;
        final d       = doc.data();
        final date    = (d['date'] as String?) ?? today;
        final localId = (d['localId'] as String?) ?? doc.id;
        final key     = _donationKey(branchId, date, localId);

        final existing = box.get(key);
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
  // FULL DOWNLOAD HELPERS
  // ════════════════════════════════════════════════════════════════════════════

  static Future<void> fullDownloadOnce(String branchId) async {
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
    if (patientId != null && patientId.isNotEmpty) {
      return patientId;
    }

    final isAdult      = patient['isAdult'] as bool? ?? true;
    final cnic         = (patient['cnic'] ?? patient['patientCnic'])?.toString().replaceAll('-', '').trim();
    final guardianCnic = (patient['guardianCnic'] ?? patient['guardian_cnic'])?.toString().replaceAll('-', '').trim();
    final name         = (patient['name'] ?? patient['patientName'] ?? patient['fullName'])?.toString().trim() ?? '';

    if (isAdult && cnic != null && cnic.isNotEmpty) return cnic;
    if (!isAdult && guardianCnic != null && guardianCnic.isNotEmpty) {
      final safeName = name.isNotEmpty ? _normalizeName(name) : const Uuid().v4().substring(0, 6);
      return '${guardianCnic}_child_$safeName';
    }
    if (cnic != null && cnic.isNotEmpty) return cnic;

    final newId = const Uuid().v4();
    patient['patientId'] = newId;
    return newId;
  }

  static Future<void> seedLocalAdmins() async {
    if (!Hive.isBoxOpen(usersBox)) return;
    final box = Hive.box(usersBox);

    Future<void> seedOne(String email, String password, String role,
        String branchId) async {
      final key = 'user:$email';
      if (!box.containsKey(key)) {
        await box.put(key, {
          'email':        email,
          'username':     role == 'server'
              ? 'server'
              : (role == 'chairman' ? 'chairman' : (role == 'manager' ? 'manager' : 'admin')),
          'passwordHash': hashPassword(password),
          'role':         role,
          'uid':          'local-${email.replaceAll('@', '_').replaceAll('.', '_')}',
          'branchId':     branchId,
          'branchName':   role == 'server'
              ? 'Server'
              : (role == 'chairman' ? 'Chairman' : 'HQ'),
          'createdAt':    DateTime.now().toIso8601String(),
        });
        debugPrint('Seeded user: $email');
      } else {
        // Correct manager username if previously defaulted to 'admin'
        final existing = box.get(key);
        if (existing is Map && role == 'manager' && existing['username'] == 'admin') {
          final updated = Map<String, dynamic>.from(existing)..['username'] = 'manager';
          await box.put(key, updated);
        }
      }

    }

    await seedOne('admin@gmd.com',   'Admin@123',   'admin',   'all');
    await seedOne('manager@gmd.com', 'Manager@123', 'manager', 'all');
    await seedOne('server@gmd.com',  'Server@123',  'server',  'sialkot');
  }

  static Future<void> forceDeduplicatePatients() async {
    final box      = Hive.box(patientsBox);
    final flagsBox = Hive.box('app_flags');
    if (flagsBox.get('patients_deduplicated_v2') == true) return;

    final Map<String, Map<String, dynamic>> uniquePatients = {};
    final Map<String, List<String>> keyToOldKeys           = {};

    for (final oldKey in box.keys.toList()) {
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
    for (final tokenKey in eBox.keys.toList()) {
      final tokenVal = eBox.get(tokenKey);
      if (tokenVal is Map && tokenVal['patientId'] != null) {
        final pId = tokenVal['patientId'].toString();
        patientToTokenKeys.putIfAbsent(pId, () => []).add(tokenKey.toString());
      }
    }

    for (final entry in uniquePatients.entries) {
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
  }

  static Future<void> saveLocalUser(Map<String, dynamic> user) async {
    if (user['email'] == null) return;
    final sanitized = sanitize(user);
    await Hive.box(usersBox).put('user:${sanitized['email']}', sanitized);
  }

  static Map<String, dynamic>? getLocalUserByEmail(String email) {
    final val = Hive.box(usersBox).get('user:$email');
    if (val == null) return null;
    return Map<String, dynamic>.from(val as Map);
  }

  static Map<String, dynamic>? getLocalUserByUid(String uid) {
    final box = Hive.box(usersBox);
    for (final key in box.keys) {
      final val = box.get(key);
      if (val is Map && val['uid'] == uid) return Map<String, dynamic>.from(val);
    }
    return null;
  }

  static Map<String, dynamic>? findLocalUser(String identifier) {
    if (identifier.trim().isEmpty) return null;
    final box = Hive.box(usersBox);
    final target = identifier.toLowerCase().trim();

    final direct = box.get('user:$target') ?? box.get(target);
    if (direct is Map) return Map<String, dynamic>.from(direct);

    for (final key in box.keys) {
      final val = box.get(key);
      if (val is Map) {
        final uEmail = (val['email'] ?? '').toString().toLowerCase().trim();
        final uUid = (val['uid'] ?? '').toString().toLowerCase().trim();
        final uName = (val['username'] ?? val['userName'] ?? val['name'] ?? '').toString().toLowerCase().trim();

        if (uEmail == target || uUid == target || uName == target || (uEmail.isNotEmpty && uEmail.split('@').first == target)) {
          return Map<String, dynamic>.from(val);
        }
      }
    }
    return null;
  }

  static Future<void> deleteLocalUser(String email) async {
    await Hive.box(usersBox).delete('user:$email');
  }

  static Future<void> saveUserOffline({
    required String uid,
    required String branchId,
    required Map<String, dynamic> userData,
  }) async {
    final sanitized = sanitize(userData);
    await Hive.box(usersBox).put('user:${sanitized['email']}', sanitized);
    await Hive.box(usersBox).flush();

    await enqueueSync({
      'type': 'save_user',
      'uid': uid,
      'branchId': branchId,
      'data': sanitized,
    });
  }

  static Future<void> deleteUserOffline({
    required String uid,
    required String branchId,
    required String email,
    String username = '',
  }) async {
    final box = Hive.box(usersBox);
    final targetUid = uid.trim();
    final targetEmail = email.trim().toLowerCase();
    final targetUsername = username.trim().toLowerCase();
    final keysToDelete = <dynamic>{};

    final directKeys = <String>{
      if (targetEmail.isNotEmpty) 'user:$targetEmail',
      if (targetUid.isNotEmpty) 'user:$targetUid',
    };
    directKeys.forEach(keysToDelete.add);

    for (final key in box.keys) {
      final val = box.get(key);
      if (val is Map) {
        final map = Map<String, dynamic>.from(val);
        final uidVal = (map['uid'] ?? map['id'] ?? '').toString();
        final emailVal = (map['email'] ?? '').toString().toLowerCase();
        final usernameVal = (map['username'] ?? '').toString().toLowerCase();
        final usernameLowerVal = (map['usernameLower'] ?? '').toString().toLowerCase();

        if ((targetUid.isNotEmpty && uidVal == targetUid) ||
            (targetEmail.isNotEmpty && emailVal == targetEmail) ||
            (usernameVal.isNotEmpty && usernameVal == targetEmail) ||
            (usernameLowerVal.isNotEmpty && usernameLowerVal == targetEmail) ||
            (usernameVal.isNotEmpty && usernameVal == targetUid) ||
            (usernameLowerVal.isNotEmpty && usernameLowerVal == targetUid)) {
          keysToDelete.add(key);
        }
      }
    }

    for (final key in keysToDelete) {
      await box.delete(key);
    }

    await box.flush();

    await enqueueSync({
      'type': 'delete_user',
      'uid': uid,
      'branchId': branchId,
      'email': email.toLowerCase(),
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
    return (user['branchId'] ?? '').toString();
  }

  /// Validates whether a branchId represents a valid physical branch entity.
  /// Rejects 'all', 'global', empty strings, 'unknown', and any 13-digit numeric CNIC strings.
  static bool isValidBranchId(String? branchId) {
    if (branchId == null) return false;
    final b = branchId.trim().toLowerCase();
    if (b.isEmpty || b == 'all' || b == 'global' || b == 'unknown') return false;
    final digits = b.replaceAll(RegExp(r'\D'), '');
    if (digits.length >= 11 && digits.length <= 15) return false;
    return true;
  }

  /// Sanitizes branchId so writes NEVER target 'all', 'global', or a numeric CNIC branch document.
  /// Falls back to the user's active session branch or [fallback] (default: 'karachi').
  static String sanitizeBranchId(String? branchId, {String fallback = 'karachi'}) {
    if (isValidBranchId(branchId)) {
      return branchId!.trim().toLowerCase();
    }
    final sessionBranch = getActiveUserBranchId();
    if (isValidBranchId(sessionBranch)) {
      return sessionBranch.trim().toLowerCase();
    }
    return fallback.trim().toLowerCase();
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

    // Update prescriptions referencing old CNIC or old patientId
    if (cleanOldCnic.isNotEmpty && newCnic != null && newCnic.isNotEmpty && cleanOldCnic != newCnic) {
      try {
        if (!Hive.isBoxOpen(prescriptionsBox)) {
          await openBoxSafe(prescriptionsBox);
        }
        final pBox = Hive.box(prescriptionsBox);
        for (final pk in pBox.keys) {
          final pVal = pBox.get(pk);
          if (pVal is Map) {
            final pCnic = (pVal['patientCnic'] ?? pVal['cnic'])?.toString().replaceAll('-', '').trim();
            final pId = (pVal['patientId'] ?? pVal['id'])?.toString().trim();
            if (pCnic == cleanOldCnic || pId == oldPatientId) {
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
        RealtimeManager().sendMessage(RealtimeEvents.payload(
          type: RealtimeEvents.savePatient,
          branchId: bId,
          data: sanitized,
        ));
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

          // Rule 0: Never cross-update between adult and child
          if (isTargetAdult != eIsAdult) continue;

          bool matches = false;

          // 1. Exact canonical ID match
          if (cleanTargetPid.isNotEmpty && (cleanTargetPid == cleanEPid || cleanTargetPid == cleanResolvedEPid)) {
            matches = true;
          } else if (isTargetAdult && eIsAdult) {
            // 2. Adult matching: must both be adults with matching CNIC
            if (targetCnic.isNotEmpty && eCnic.isNotEmpty && targetCnic == eCnic) {
              if (targetName.isEmpty || eName.isEmpty || targetName == eName) {
                matches = true;
              }
            }
          } else if (!isTargetAdult && !eIsAdult) {
            // 3. Child matching: must both be children under same guardian CNIC with exact matching name
            final effTargetG = targetGuardian.isNotEmpty ? targetGuardian : targetCnic;
            final effEG = eGuardian.isNotEmpty ? eGuardian : eCnic;
            if (effTargetG.isNotEmpty && effEG.isNotEmpty && effTargetG == effEG) {
              if (targetName.isNotEmpty && eName.isNotEmpty && targetName == eName) {
                matches = true;
              }
            }
          }

          if (matches) {
            final updatedEntry = Map<String, dynamic>.from(entry)..addAll(sanitizedChanges);

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
        s['patientId'] = key;
        updates[key] = s;
      } catch (e) {
        debugPrint('[LocalStorage] Skipped invalid patient: $e');
      }
    }
    await box.putAll(updates);
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
    if (patientId.contains('_child_') || clean.contains('_child_')) return null;
    return getLocalPatientByCnic(patientId);
  }

  static Map<String, dynamic>? getLocalPatientByCnic(String cnic) {
    if (!Hive.isBoxOpen(patientsBox)) return null;
    final normalized = cnic.replaceAll('-', '').trim();
    final box        = Hive.box(patientsBox);
    final direct     = box.get(normalized);
    if (direct != null) {
      return Map<String, dynamic>.from(direct as Map);
    }
    for (final key in box.keys) {
      if (key is String && key.startsWith('${normalized}_child_')) {
        final val = box.get(key);
        if (val is Map) {
          return Map<String, dynamic>.from(val);
        }
      }
    }
    return null;
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
      String input, {String? branchId, bool globalSearch = false}) {
    if (!Hive.isBoxOpen(patientsBox)) return [];
    final normalized      = input.replaceAll('-', '').trim().toLowerCase();
    final normalizedPhone = normalized.replaceAll(RegExp(r'\D'), '');
    final normalizedName  = normalized.replaceAll(RegExp(r'[^a-z0-9]'), '');

    final box = Hive.box(patientsBox);
    final results = <Map<String, dynamic>>[];

    for (final raw in box.values) {
      if (raw is! Map) continue;
      
      if (!globalSearch && branchId != null) {
        final branch = raw['branchId']?.toString();
        if (branch != branchId) continue;
      }

      final cnic     = raw['cnic']?.toString().replaceAll('-', '').trim().toLowerCase() ?? '';
      final guardian = raw['guardianCnic']?.toString().replaceAll('-', '').trim().toLowerCase() ?? '';
      final phone    = raw['phone']?.toString().replaceAll(RegExp(r'\D'), '') ?? '';
      final name     = _normalizeName(raw['name']?.toString() ?? '');

      bool match = false;
      if (cnic.isNotEmpty && cnic.contains(normalized)) {
        match = true;
      } else if (guardian.isNotEmpty && guardian.contains(normalized)) {
        match = true;
      } else if (normalizedPhone.length >= 4 &&
          phone.isNotEmpty &&
          phone.contains(normalizedPhone)) {
        match = true;
      } else if (normalizedName.length >= 3 &&
          name.isNotEmpty &&
          name.contains(normalizedName)) {
        match = true;
      }

      if (match) {
        final p = Map<String, dynamic>.from(raw);
        if (p['patientId'] == null) {
          p['patientId'] = getPatientKey(p);
        }
        results.add(p);
      }
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

  static Future<void> saveEntryLocal(
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
      final activeCamp = CampSessionService.getActiveCamp();
      if (activeCamp != null && activeCamp.isNotEmpty && activeCamp != 'all') {
        sanitized['dispensaryId'] = sanitized['dispensaryId'] ?? activeCamp;
        sanitized['campId']       = sanitized['campId']       ?? activeCamp;
      }
    }

    // Check exact & variant keys in entriesBox to preserve original createdAt, session, and creator
    Map<String, dynamic>? existingExactMap;
    final legacyKeysToDelete = <dynamic>[];
    try {
      if (Hive.isBoxOpen(entriesBox)) {
        final box = Hive.box(entriesBox);
        for (final k in box.keys) {
          final kStr = k.toString().trim();
          final kLower = kStr.toLowerCase();
          if (kStr == canonicalKey ||
              kLower == canonicalKey.toLowerCase() ||
              kLower == '$normBranch-${cleanSerial.toLowerCase()}' ||
              kLower == cleanSerial.toLowerCase() ||
              kStr == normSerialUpper ||
              kLower.endsWith('-$normSerialUpper'.toLowerCase())) {
            final raw = box.get(k);
            if (raw is Map && existingExactMap == null) {
              existingExactMap = Map<String, dynamic>.from(raw);
            }
            if (kStr != canonicalKey) {
              legacyKeysToDelete.add(k);
            }
          }
        }
      }
    } catch (_) {}

    // If still missing, check dispensaryBox for existing patient details
    if (existingExactMap == null && Hive.isBoxOpen(dispensaryBox)) {
      try {
        final dBox = Hive.box(dispensaryBox);
        for (final dk in dBox.keys) {
          final dkStr = dk.toString().trim().toUpperCase();
          if (dkStr.endsWith('_$normSerialUpper') || dkStr.endsWith('-$normSerialUpper') || dkStr == normSerialUpper) {
            final dVal = dBox.get(dk);
            if (dVal is Map) {
              existingExactMap = Map<String, dynamic>.from(dVal);
              break;
            }
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

    const terminalStatuses = ['completed', 'dispensed'];

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

      for (final field in [
        'patientName', 'name', 'fullName', 'patientCnic', 'cnic', 'guardianName',
        'guardianCnic', 'patientAge', 'age', 'patientGender', 'gender',
        'queueType', 'visitReason', 'isVitalsOnly', 'vitalsOnly',
        'suggestedDays', 'phone', 'contactPhone', 'address', 'dateKey'
      ]) {
        final curVal = sanitized[field];
        final oldVal = existing[field];
        final curStr = curVal?.toString().trim().toLowerCase() ?? '';
        final oldStr = oldVal?.toString().trim().toLowerCase() ?? '';
        final isCurEmpty = curVal == null || curStr.isEmpty || curStr == 'null' || curStr == 'unknown' || curStr == 'unknown patient' || curStr == 'n/a' || curStr == '-';
        final isOldValid = oldVal != null && oldStr.isNotEmpty && oldStr != 'null' && oldStr != 'unknown' && oldStr != 'unknown patient' && oldStr != 'n/a' && oldStr != '-';
        if (isCurEmpty && isOldValid) {
          sanitized[field] = oldVal;
        }
      }

      // Resolve patient name from local_patients if still missing or unknown
      final curNameStr = (sanitized['patientName'] ?? sanitized['name'] ?? sanitized['fullName'])?.toString().trim().toLowerCase() ?? '';
      if (curNameStr.isEmpty || curNameStr == 'null' || curNameStr == 'unknown' || curNameStr == 'unknown patient') {
        final pId = (sanitized['patientId'] ?? sanitized['id'] ?? '').toString().trim();
        final isEntryAdult = sanitized['isAdult'] is bool
            ? sanitized['isAdult'] as bool
            : (!pId.contains('_child_') && (sanitized['guardianCnic']?.toString().trim().isEmpty ?? true));
        final pCnic = (sanitized['patientCnic'] ?? sanitized['cnic'] ?? sanitized['guardianCnic'] ?? '').toString().trim();
        if (pId.isNotEmpty) {
          final lp = getLocalPatient(pId);
          final lpName = (lp?['name'] ?? lp?['patientName'] ?? lp?['fullName'])?.toString().trim();
          if (lpName != null && lpName.isNotEmpty && lpName.toLowerCase() != 'null' && lpName.toLowerCase() != 'unknown' && lpName.toLowerCase() != 'unknown patient') {
            sanitized['patientName'] = lpName;
            sanitized['name'] = lpName;
          }
        }
        final curNameAfterPid = (sanitized['patientName'] ?? '').toString().trim().toLowerCase();
        if (isEntryAdult && (curNameAfterPid.isEmpty || curNameAfterPid == 'null' || curNameAfterPid == 'unknown' || curNameAfterPid == 'unknown patient') && pCnic.isNotEmpty) {
          final lp = getLocalPatientByCnic(pCnic);
          final lpName = (lp?['name'] ?? lp?['patientName'] ?? lp?['fullName'])?.toString().trim();
          if (lpName != null && lpName.isNotEmpty && lpName.toLowerCase() != 'null' && lpName.toLowerCase() != 'unknown' && lpName.toLowerCase() != 'unknown patient') {
            sanitized['patientName'] = lpName;
            sanitized['name'] = lpName;
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
          sanitized['prescription'] = sanitized['prescription'] ?? existingExact['prescription'];
          sanitized['prescriptionId'] = sanitized['prescriptionId'] ?? existingExact['prescriptionId'];
          sanitized['dispensedAt'] = sanitized['dispensedAt'] ?? existingExact['dispensedAt'];
          sanitized['dispensedBy'] = sanitized['dispensedBy'] ?? existingExact['dispensedBy'];
          sanitized['dispenserName'] = sanitized['dispenserName'] ?? existingExact['dispenserName'];
        }

        final localStatus    = (existingExact['status'] ?? '').toString().toLowerCase();
        final incomingStatus = (sanitized['status'] ?? '').toString().toLowerCase();
        if (terminalStatuses.contains(localStatus) && !terminalStatuses.contains(incomingStatus)) {
          sanitized['status']         = existingExact['status'] ?? 'completed';
          sanitized['completedAt']    = existingExact['completedAt'] ?? sanitized['completedAt'];
          sanitized['prescription']   = existingExact['prescription'] ?? sanitized['prescription'];
          sanitized['prescriptionId'] = existingExact['prescriptionId'] ?? sanitized['prescriptionId'];
          sanitized['vitals']         = existingExact['vitals'] ?? sanitized['vitals'];
          sanitized['daysOfMedicine'] = existingExact['daysOfMedicine'] ?? sanitized['daysOfMedicine'];
          sanitized['doctorName']     = existingExact['doctorName'] ?? sanitized['doctorName'];
          sanitized['doctorId']       = existingExact['doctorId'] ?? sanitized['doctorId'];
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

    // 2. Check if a local prescription already exists in prescriptionsBox for this exact token
    try {
      if (Hive.isBoxOpen(prescriptionsBox)) {
        final pBox = Hive.box(prescriptionsBox);
        final rawPresc = pBox.get(normSerialUpper) ?? pBox.get(cleanSerial);
        if (rawPresc is Map) {
          final existingPrescription = Map<String, dynamic>.from(rawPresc);
          preservePatientFields(existingPrescription);
          sanitized['status']         = 'completed';
          sanitized['prescription']   = existingPrescription;
          sanitized['prescriptionId'] = existingPrescription['id'] ?? normSerialUpper;
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

    final eBox = await ensureBoxOpen(entriesBox);
    await eBox.put(canonicalKey, sanitized);

    // Prune any legacy keys so that this token never appears duplicate times
    for (final oldKey in legacyKeysToDelete) {
      try {
        await eBox.delete(oldKey);
      } catch (_) {}
    }
  }

  static List<Map<String, dynamic>> getLocalEntries(String branchId,
      {String? dispensaryId, bool filterByCamp = false, String? session, bool filterBySession = false}) {
    if (!Hive.isBoxOpen(entriesBox)) return [];
    final box = Hive.box(entriesBox);
    final normBranch = branchId.toLowerCase().trim();
    var list = box.keys
        .where((k) => k.toString().toLowerCase().startsWith('$normBranch-'))
        .map((k) => Map<String, dynamic>.from(box.get(k) as Map))
        .toList();

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

    return list;
  }

  /// Self-healing utility: Fixes any in-flight tokens whose session was mistakenly overwritten on restart/sync
  static Future<void> repairMisassignedShiftSessions([String? branchId]) async {
    try {
      if (!Hive.isBoxOpen(entriesBox)) return;
      final box = Hive.box(entriesBox);
      for (final k in box.keys.toList()) {
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

  static Map<String, dynamic>? getLocalEntry(
      String branchId, String serial) {
    if (!Hive.isBoxOpen(entriesBox)) return null;
    final normBranch = branchId.toLowerCase().trim();
    final normSerial = serial.trim();
    final val = Hive.box(entriesBox).get('$normBranch-$normSerial');
    if (val != null) return Map<String, dynamic>.from(val as Map);

    final box = Hive.box(entriesBox);
    final targetUpper = normSerial.toUpperCase();
    for (final k in box.keys) {
      final kStr = k.toString();
      if (kStr.toLowerCase().startsWith('$normBranch-') &&
          kStr.substring(normBranch.length + 1).toUpperCase() == targetUpper) {
        final item = box.get(k);
        if (item is Map) return Map<String, dynamic>.from(item);
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
    final box = Hive.box(entriesBox);
    dynamic targetKey = canonicalKey;
    var raw = box.get(canonicalKey);
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
    await box.put(canonicalKey, updated);
    if (targetKey != canonicalKey) {
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

        final isKeyMatch = kStrUpper == targetUpper ||
            kStrUpper == '$normBranch-$targetUpper'.toUpperCase() ||
            kStrUpper.endsWith('-$targetUpper') ||
            serial == targetUpper;

        if (isKeyMatch && isBranchMatch) {
          await box.delete(key);
          debugPrint('[LocalStorage] ✅ Deleted $tokenSerial (key: $key)');
          deleted = true;
        }
      }
      await box.flush();
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
    } catch (e) {
      debugPrint('[LocalStorage] Error in sanitizeLocalEntriesCasingAndUnknowns: $e');
    }
  }

  /// Merges historical/unlinked prescriptions from `prescriptionsBox` and
  /// dispense records from `dispensaryBox` directly into the unified `entriesBox`.
  static Future<int> unifyAndMergeAllLocalSerials([String? branchId]) async {
    int unifiedCount = 0;
    try {
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
          await enqueueSync({
            'type': 'delete_prescription',
            'branchId': targetBranch,
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
        final cnic = (prescMap?['cnic'] ?? prescMap?['patientCnic'] ?? dispMap?['cnic'] ?? dispMap?['patientCnic'] ?? '').toString();
        final pId = (prescMap?['patientId'] ?? dispMap?['patientId'] ?? cnic).toString();

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
      if (unifiedCount > 0) {
        debugPrint('[LocalStorage] ✨ Unified & merged $unifiedCount serial records, removed redundant prescriptions/dispensary records.');
        SyncService().triggerUpload(force: true);
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

  static Future<void> saveLocalPrescription(
      Map<String, dynamic> prescription) async {
    final serialRaw =
        prescription['serial']?.toString() ?? prescription['id']?.toString();
    final serial = serialRaw?.trim();
    if (serial == null || serial.isEmpty) return;

    const cnicFields = [
      'patientCnic', 'cnic', 'patientCNIC', 'guardianCnic',
      'patient_cnic', 'guardian_cnic', 'cnic_number'
    ];
    String? cnicRaw;
    for (final field in cnicFields) {
      final v = prescription[field]?.toString();
      if (v != null && v.trim().isNotEmpty && v != '00000-0000000-0') {
        cnicRaw = v;
        break;
      }
    }
    cnicRaw ??= 'unknown_cnic_${DateTime.now().millisecondsSinceEpoch}';

    final cleanCnic  = cnicRaw.trim().replaceAll('-', '').replaceAll(' ', '');
    final normSerial = serial.toLowerCase().trim();
    final normSerialUpper = serial.toUpperCase().trim();

    final key       = '${cleanCnic}_$serial';
    var sanitized   = sanitize(prescription);
    sanitized['patientCnic'] = cleanCnic;
    sanitized['cnic']        = cleanCnic;
    sanitized['serial']      = serial;

    final activeCamp = CampSessionService.getActiveCamp();
    if (activeCamp != null && activeCamp.isNotEmpty) {
      sanitized['dispensaryId'] = sanitized['dispensaryId'] ?? activeCamp;
      sanitized['campId']       = sanitized['campId']       ?? activeCamp;
      sanitized['campName']     = sanitized['campName']     ?? CampSessionService.getCampLabel(activeCamp);
    }

    // Purge any legacy standalone records from prescriptionsBox to avoid duplicate docs
    if (Hive.isBoxOpen(prescriptionsBox)) {
      final prBox = Hive.box(prescriptionsBox);
      await prBox.deleteAll([key, serial, '${cleanCnic}_$normSerial', normSerial, normSerialUpper]);
    }

    // Save directly into entriesBox (the canonical serial store)
    final entriesBoxRef = await ensureBoxOpen(entriesBox);
    final branchId = (sanitized['branchId'] ?? '').toString().toLowerCase().trim();
    final canonicalKey = branchId.isNotEmpty ? '$branchId-$normSerialUpper' : normSerialUpper;

    final matchingKeys = <dynamic>[];
    for (final k in entriesBoxRef.keys) {
      final kStr = k.toString().toLowerCase();
      if (kStr == normSerial || kStr == normSerialUpper.toLowerCase() ||
          kStr.endsWith('-$normSerial') || kStr.endsWith('-$normSerialUpper') ||
          (branchId.isNotEmpty && kStr == '$branchId-$normSerial')) {
        matchingKeys.add(k);
      }
    }
    if (matchingKeys.isEmpty) {
      matchingKeys.add(canonicalKey);
    }

    final pMeds = sanitized['prescriptions'] ?? sanitized['medicines'];
    final docName = sanitized['doctorName'] ?? sanitized['prescribedBy'];
    final docId = sanitized['doctorId'];
    final diag = sanitized['diagnosis'];
    final comp = sanitized['complaint'] ?? sanitized['condition'];
    final days = sanitized['daysOfMedicine'];
    final vitals = sanitized['vitals'];
    final lab = sanitized['labResults'];
    final extra = sanitized['extraCharge'];

    for (final k in matchingKeys) {
      final existing = entriesBoxRef.get(k);
      final updatedEntry = existing is Map ? Map<String, dynamic>.from(existing) : <String, dynamic>{};

      updatedEntry['serial'] = serial;
      updatedEntry['id'] = serial;
      if (branchId.isNotEmpty) updatedEntry['branchId'] = branchId;
      if (sanitized['dateKey'] != null) updatedEntry['dateKey'] = sanitized['dateKey'];
      if (sanitized['queueType'] != null) updatedEntry['queueType'] = sanitized['queueType'];
      if (sanitized['patientName'] != null && sanitized['patientName'] != 'Unknown Patient') {
        updatedEntry['patientName'] = sanitized['patientName'];
      }

      updatedEntry['prescription'] = sanitized;
      updatedEntry['status']       = 'completed';
      updatedEntry['completedAt']  ??= sanitized['completedAt'] ?? DateTime.now().toIso8601String();
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
      if (vitals != null) updatedEntry['vitals'] = vitals;
      if (lab != null) updatedEntry['labResults'] = lab;
      if (extra != null) updatedEntry['extraCharge'] = extra;
      updatedEntry['dispenseStatus'] ??= 'pending';

      await entriesBoxRef.put(k, sanitize(updatedEntry));
    }
    if (!matchingKeys.contains(canonicalKey)) {
      final base = entriesBoxRef.get(matchingKeys.first);
      if (base != null) await entriesBoxRef.put(canonicalKey, base);
    }
    await entriesBoxRef.flush();
  }

  static Future<void> updateDispenseStatus(
      String branchId, String serial, String status) async {
    final normBranch = branchId.toLowerCase().trim();
    var cleanSerial = serial.trim();
    if (cleanSerial.toLowerCase().startsWith('$normBranch-')) {
      cleanSerial = cleanSerial.substring(normBranch.length + 1).trim();
    }
    final normSerialUpper = cleanSerial.toUpperCase();
    final canonicalKey    = '$normBranch-$normSerialUpper';
    final statusLower     = status.trim().toLowerCase();
    final box             = Hive.box(entriesBox);

    final matchingKeys = <dynamic>[];
    Map<String, dynamic>? bestExisting;

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
        if (raw is Map && bestExisting == null) {
          bestExisting = Map<String, dynamic>.from(raw);
        }
      }
    }

    // If still missing in entriesBox, search dispensaryBox and prescriptionsBox for full patient data
    if (bestExisting == null && Hive.isBoxOpen(dispensaryBox)) {
      try {
        final dBox = Hive.box(dispensaryBox);
        for (final dk in dBox.keys) {
          final dkStr = dk.toString().trim().toUpperCase();
          if (dkStr.endsWith('_$normSerialUpper') || dkStr.endsWith('-$normSerialUpper') || dkStr == normSerialUpper) {
            final dVal = dBox.get(dk);
            if (dVal is Map) {
              bestExisting = Map<String, dynamic>.from(dVal);
              break;
            }
          }
        }
      } catch (_) {}
    }

    final nowIso = DateTime.now().toIso8601String();
    final todayKey = getTodayDateKey();
    final base = bestExisting != null ? Map<String, dynamic>.from(bestExisting) : <String, dynamic>{};
    base['serial']         = normSerialUpper;
    base['branchId']       = normBranch;
    base['dispenseStatus'] = status;
    base['dateKey']        ??= todayKey;
    base['createdAt']      ??= nowIso;
    if (statusLower == 'dispensed') {
      base['status']       = 'completed';
      base['dispensedAt']  ??= nowIso;
      base['completedAt']  ??= nowIso;
    }

    await box.put(canonicalKey, base);

    // Prune legacy redundant keys to prevent duplicate entries
    for (final oldKey in matchingKeys) {
      if (oldKey.toString().trim() != canonicalKey) {
        try {
          await box.delete(oldKey);
        } catch (_) {}
      }
    }

    await box.flush();
  }

  static Map<String, dynamic>? getLocalPrescription(
    String serial, {
    String? cnic,
    String? patientName,
    String? patientId,
    String? branchId,
    String? dateKey,
  }) {
    if (serial.trim().isEmpty) return null;
    final cleanSerial = serial.trim();
    final lowerSerial = cleanSerial.toLowerCase();
    final normBranch  = (branchId ?? '').trim().toLowerCase();
    final cleanCnic   = (cnic ?? '').trim().replaceAll(RegExp(r'[-\s]'), '');
    final cleanPId    = (patientId ?? '').trim();

    // Helper: validate candidate prescription against branch and patient identity
    bool matchesPatient(Map data) {
      // 1. Branch verification
      if (normBranch.isNotEmpty && normBranch != 'all' && normBranch != 'global') {
        final pBranch = (data['branchId'] ?? '').toString().trim().toLowerCase();
        if (pBranch.isNotEmpty && pBranch != normBranch && !pBranch.contains(normBranch) && !normBranch.contains(pBranch)) {
          return false;
        }
      }

      // 2. DateKey verification
      if (dateKey != null && dateKey.trim().isNotEmpty) {
        final pDateKey = (data['dateKey'] ?? '').toString().trim();
        if (pDateKey.isNotEmpty && pDateKey != dateKey.trim()) {
          return false;
        }
      }

      // 3. Patient ID verification
      if (cleanPId.isNotEmpty) {
        final pId = (data['patientId'] ?? data['id'] ?? '').toString().trim();
        if (pId.isNotEmpty && pId != cleanPId) {
          return false;
        }
      }

      // 4. CNIC verification
      if (cleanCnic.isNotEmpty) {
        final pCnic = (data['patientCnic'] ?? data['cnic'] ?? '')
            .toString()
            .trim()
            .replaceAll(RegExp(r'[-\s]'), '');
        if (pCnic.isNotEmpty &&
            pCnic != cleanCnic &&
            !pCnic.contains(cleanCnic) &&
            !cleanCnic.contains(pCnic)) {
          return false;
        }
      }

      // 5. Patient Name verification (ignore vague names like '0', '02', 'unknown')
      if (patientName != null && patientName.trim().isNotEmpty) {
        final pName = (data['patientName'] ?? data['name'] ?? '')
            .toString()
            .trim()
            .toLowerCase();
        final qName = patientName.trim().toLowerCase();
        if (pName.isNotEmpty &&
            qName.isNotEmpty &&
            pName != 'unknown' &&
            qName != 'unknown' &&
            pName.length > 2 &&
            qName.length > 2) {
          if (pName != qName && !pName.contains(qName) && !qName.contains(pName)) {
            return false;
          }
        }
      }
      return true;
    }

    // 1. Check entriesBox strictly for this branch
    try {
      if (Hive.isBoxOpen(entriesBox)) {
        final eBox = Hive.box(entriesBox);
        if (normBranch.isNotEmpty) {
          final exactEntry = eBox.get('$normBranch-$cleanSerial') ??
              eBox.get('$normBranch-$lowerSerial') ??
              eBox.get('$normBranch-${cleanSerial.toUpperCase()}');
          if (exactEntry is Map && exactEntry['prescription'] is Map) {
            final presc = exactEntry['prescription'] as Map;
            if (presc.isNotEmpty && matchesPatient(presc)) {
              return Map<String, dynamic>.from(presc);
            }
          }
        }
      }
    } catch (_) {}

    // 2. Direct key lookups in prescriptionsBox with strict branch/patient validation
    final box = Hive.box(prescriptionsBox);
    final keyCandidates = [
      if (normBranch.isNotEmpty) '$normBranch-$cleanSerial',
      if (normBranch.isNotEmpty) '$normBranch-${cleanSerial.toUpperCase()}',
      cleanSerial,
      cleanSerial.toUpperCase(),
      lowerSerial,
    ];

    for (final k in keyCandidates) {
      final direct = box.get(k);
      if (direct != null && direct is Map && matchesPatient(direct)) {
        return Map<String, dynamic>.from(direct);
      }
    }

    return null;
  }

  static Future<void> deleteLocalPrescription(String serial) async {
    if (serial.trim().isEmpty) return;
    try {
      if (Hive.isBoxOpen(prescriptionsBox)) {
        final box = Hive.box(prescriptionsBox);
        final lowerSerial = serial.trim().toLowerCase();
        final upperSerial = serial.trim().toUpperCase();
        await box.delete(serial);
        await box.delete(lowerSerial);
        await box.delete(upperSerial);
        final keysToDelete = <dynamic>[];
        for (final k in box.keys) {
          final kStr = k.toString().toLowerCase();
          if (kStr == lowerSerial || kStr.endsWith('_$lowerSerial') || kStr.endsWith('-$lowerSerial')) {
            keysToDelete.add(k);
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
    for (final entry in currentLocalItems.entries) {
      final locId = entry.key;
      final locItem = entry.value;
      if (!downloadedIds.contains(locId)) {
        updatedMap['stock:$locId'] = locItem;
        updatedMap[locId] = locItem;
        debugPrint('[LocalStorage] Preserved local/LAN stock item $locId (not in remote snapshot)');
      }
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

  static bool _isDummyCnicValue(String cnic) {
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

  static List<Map<String, dynamic>> getAllLocalStockItems(
      {String? branchId, String? dispensaryId, bool filterByCamp = true}) {
    if (!Hive.isBoxOpen(stockBox)) return [];

    final Map<String, Map<String, dynamic>> uniqueItems = {};
    for (final raw in Hive.box(stockBox).values) {
      if (raw is! Map) continue;
      final item = Map<String, dynamic>.from(raw);
      final rawId = (item['id'] ?? item['medicineId'] ?? item['docId'] ?? item['code'] ?? item['barcode'])?.toString().trim();
      final name = (item['name'] ?? item['formula'] ?? '').toString().trim().toLowerCase();
      final dose = (item['dose'] ?? '').toString().trim().toLowerCase();
      final type = (item['type'] ?? item['dosageForm'] ?? item['form'] ?? '').toString().trim().toLowerCase();
      final camp = (item['campId'] ?? item['dispensaryId'] ?? '').toString().trim().toLowerCase();

      final dedupKey = (rawId != null && rawId.isNotEmpty && rawId != 'unknown' && rawId != 'null')
          ? 'id:${rawId.toLowerCase()}'
          : 'composite:$name|$type|$dose|$camp';

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
        } else if (existingUp == null && newUp == null && newQty > existingQty) {
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
      final data = Map<String, dynamic>.from(raw as Map);
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
      for (final doc in snapshot.docs) {
        await flagsBox.put('patient_synced_${doc.id}', true);
      }
    } catch (e) {
      debugPrint('[LocalStorage] downloadAllPatients error: $e');
    }
  }

  static Future<void> downloadTodayTokens(String branchId, [String? campId]) async {
    // FIX 2: normalize branchId FIRST — this is the primary method Fix 2
    // targets. Every Hive key built below ('$branchId-...') previously used
    // whatever casing the caller passed, while saveEntryLocal() always
    // lowercases, so a differently-cased caller here would miss the real
    // local record and let stale server data silently overwrite a
    // completed/dispensed token's protected status.
    branchId = branchId.toLowerCase().trim();
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

        for (final type in ['zakat', 'non-zakat', 'gmwf']) {
          try {
            final snap = await serialsRef.collection(type).get();
          for (final doc in snap.docs) {
            final rawId = doc.id.trim();
            final upperId = rawId.toUpperCase();
            final isLowercase = (rawId != upperId);

            final d = Map<String, dynamic>.from(doc.data());
            d['serial']    = upperId;
            d['dateKey']   = today;
            d['branchId']  = branchId;
            final isKarachi = branchId.contains('karachi') || branchId.contains('haji') || branchId.contains('saddar') || branchId.contains('kapaya');
            d['queueType'] = (isKarachi && (type == 'non-zakat' || type.contains('non'))) ? 'zakat' : type;
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
          await docRef.delete();
          debugPrint('[LocalStorage] 🧹 Cleaned duplicate lowercase doc from Firestore: ${docRef.path}');
        } catch (_) {}
      }

      const terminalStatuses = ['completed', 'dispensed'];
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
          if (terminalStatuses.contains(localStatus) &&
              !terminalStatuses.contains(mergedStatus)) {
            merged['status'] = localStatus;
          }
          if (ex['dispenseStatus']?.toString() == 'dispensed') {
            merged['dispenseStatus'] = 'dispensed';
            if (ex['dispensedAt'] != null) merged['dispensedAt'] = ex['dispensedAt'];
            if (ex['dispensedBy'] != null) merged['dispensedBy'] = ex['dispensedBy'];
          }
          if (ex['prescription'] != null && merged['prescription'] == null) {
            merged['prescription']   = ex['prescription'];
            merged['prescriptionId'] = ex['prescriptionId'];
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

  static Future<void> downloadInventory(String branchId, {bool forceFull = false, String? campId}) async {
    branchId = branchId.toLowerCase().trim();
    try {
      final invPaths = CampSessionService.getAllCampInventoryPaths(
        branchId: branchId,
        selectedCamp: campId ?? CampSessionService.getActiveCamp(),
      );

      for (final invCol in invPaths) {
        final syncKey = 'inventory_${branchId}_$invCol';
        final lastSyncedStr = getLastSyncedServerTimestamp(syncKey);
        final currentCount = Hive.box(stockBox).length;

        Query query = FirebaseFirestore.instance
            .collection('branches')
            .doc(branchId)
            .collection(invCol);

        if (!forceFull && currentCount >= 15 && lastSyncedStr != null && lastSyncedStr.isNotEmpty) {
          final dt = DateTime.tryParse(lastSyncedStr);
          if (dt != null) {
            query = query.where('updatedAt', isGreaterThan: Timestamp.fromDate(dt));
          }
        }

        var snapshot = await query.get();
        // Fallback: If incremental query returned nothing BUT local cache is empty/low or forced, fetch all
        final isIncremental = !forceFull && currentCount >= 15 && lastSyncedStr != null && lastSyncedStr.isNotEmpty;
        if (snapshot.docs.isEmpty && (!isIncremental || currentCount < 5)) {
          snapshot = await FirebaseFirestore.instance
              .collection('branches')
              .doc(branchId)
              .collection(invCol)
              .get();
        }
        if (snapshot.docs.isEmpty && (!isIncremental || currentCount < 5)) {
          final altBranch = branchId == 'karachi' ? 'Karachi' : 'karachi';
          snapshot = await FirebaseFirestore.instance
              .collection('branches')
              .doc(altBranch)
              .collection(invCol)
              .get();
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
            } else if (invCol == 'inventory_haji' || docIdUpper.startsWith('HAJI') || docIdUpper.startsWith('HAJICAMP') || rawCamp.contains('haji')) {
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

      if (branchId == 'karachi') {
        unawaited(healKarachiSplitInventory());
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
    try {
      if (!Hive.isBoxOpen('app_settings')) {
        await Hive.openBox('app_settings');
      }
      final settings = Hive.box('app_settings');
      if (!force && settings.get('karachi_split_inventory_healed_v2', defaultValue: false) == true) {
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
            } else if (rawId.startsWith('saddar--') || rawId.startsWith('kapayya--')) {
              if (m['campId'] != 'saddar') {
                m['campId'] = 'saddar';
                m['dispensaryId'] = 'saddar';
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

      await settings.put('karachi_split_inventory_healed_v2', true);
      debugPrint('[LocalStorage] ✅ Successfully healed Karachi inventory ($hajiCount haji, $saddarCount saddar migrated, $deleteCount cleaned)');
    } catch (e) {
      debugPrint('[LocalStorage] healKarachiSplitInventory error: $e');
    }
  }

  static Future<void> refreshPrescriptions(String branchId) async {
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
    bool isChild = isAdult == false || guard.isNotEmpty || rawPid.contains('_child_') || (age > 0 && age < 20);

    // If ambiguous (e.g. entry record where isAdult was not saved), check if patient registry knows this patient is a child
    if (!isChild && isAdult == null && name.isNotEmpty && (cnic.isNotEmpty || guard.isNotEmpty)) {
      final effCnic = guard.isNotEmpty ? guard : cnic;
      final cleanG = _cleanId(effCnic);
      final normN = _normalizeName(name);
      if (cleanG.isNotEmpty && normN.isNotEmpty && Hive.isBoxOpen(patientsBox)) {
        final pBox = Hive.box(patientsBox);
        if (pBox.containsKey('${cleanG}_child_$normN')) {
          isChild = true;
        }
      }
    }

    if (isChild) {
      if (rawPid.contains('_child_')) return rawPid;
      final gCnic = guard.isNotEmpty ? guard : cnic;
      final cleanG = _cleanId(gCnic);
      final safeName = name.isNotEmpty && name.toLowerCase() != 'unknown' && name.toLowerCase() != 'unknown patient'
          ? _normalizeName(name)
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

    // Audit log
    await recordPatientAuditLog(
      branchId: bId,
      action: 'DELETE_REGISTRATION_KEEP_HISTORY',
      patientId: patientId,
      patientName: pName,
      patientCnic: cnic,
      performedBy: getActiveUsername(),
      performedByRole: getActiveUserRole(),
      reason: reason ?? 'Child-parent CNIC conflict resolution (medical history preserved)',
    );

    // Enqueue Firestore background sync
    await enqueueSync({
      'type': 'delete_patient',
      'branchId': bId,
      'patientId': patientId,
      'reason': reason ?? 'Child-parent CNIC conflict resolution',
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
      String branchId, String patientId) {
    final restriction = getMedicineRestriction(branchId, patientId);
    if (restriction == null) return null;

    final today = DateTime(
      DateTime.now().year, DateTime.now().month, DateTime.now().day);

    final lastBlockedStr =
        restriction['lastBlockedDay'] as String?;

    if (lastBlockedStr != null) {
      final lastBlocked = DateTime.parse(lastBlockedStr);
      final lastBlockedDay =
          DateTime(lastBlocked.year, lastBlocked.month, lastBlocked.day);

      if (today.isAfter(lastBlockedDay)) {
        clearMedicineRestriction(branchId, patientId);
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
      clearMedicineRestriction(branchId, patientId);
      return null;
    }
    final expiresAt    = DateTime.parse(expiresStr);
    final expireDay    =
        DateTime(expiresAt.year, expiresAt.month, expiresAt.day)
        .subtract(const Duration(days: 1));

    if (today.isAfter(expireDay)) {
      clearMedicineRestriction(branchId, patientId);
      return null;
    }
    final remaining = expireDay.difference(today).inDays + 1;
    return {...restriction, 'remainingDays': remaining};
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

  static Future<String> nextReceiptNumber([String branchId = '']) async {
    final box = Hive.box('app_settings');
    final code = getBranchCode(branchId);
    
    final key = 'receipt_seq_$code';
    final current = box.get(key, defaultValue: 0) as int;
    final next = current + 1;
    await box.put(key, next);
    
    final globalKey = 'receipt_seq_global';
    final globalCurrent = box.get(globalKey, defaultValue: 0) as int;
    if (next > globalCurrent) await box.put(globalKey, next);

    return formatReceiptNumber(next, code);
  }

  static Future<int> getNextLocalSerialSequence(
    String branchId,
    String dateKey, {
    String? dispensaryId,
    bool increment = false,
  }) async {
    // FIX 2: normalize branchId before it's used (via getLocalEntries and
    // the counter key below) to build/read Hive keys.
    branchId = branchId.toLowerCase().trim();
    final counterBox = Hive.box('app_settings');
    final activeCamp = dispensaryId ?? CampSessionService.getActiveCamp();
    final dispTag = CampSessionService.getDispensaryKeyword(activeCamp);
    final counterKey = 'counter_${branchId}_${dateKey}_$dispTag';
    final savedSeq = (counterBox.get(counterKey) as num?)?.toInt() ?? 0;

    final entries = getLocalEntries(branchId, dispensaryId: activeCamp, filterByCamp: true)
        .where((m) => (m['dateKey'] as String?) == dateKey);

    int maxSeq = savedSeq;
    for (final m in entries) {
      final s = (m['serial'] ?? '').toString().trim();
      if (s.isEmpty) continue;
      final seq = parseSequenceFromSerial(s);
      if (seq < 9999 && seq > maxSeq) {
        maxSeq = seq;
      }
    }

    final nextSeq = maxSeq + 1;
    if (increment) {
      await counterBox.put(counterKey, nextSeq);
    }
    return nextSeq;
  }

  static String formatReceiptNumber(int seq, [String branchCode = '']) {
    final padded = seq.toString().padLeft(3, '0');
    final tid = Hive.box('app_settings').get('terminal_id', defaultValue: '');
    
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

      final vitals = data['vitals'] as Map<String, dynamic>? ?? {};

      final name = _firstNonEmpty([
        data['patientName'], data['name'], vitals['name'], p?['name'], 'Unknown',
      ]);
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