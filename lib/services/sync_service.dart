import '../utils/ui_stall_monitor.dart';
import 'busy_status.dart';
import 'firebase_session_guard.dart';
import 'package:firebase_core/firebase_core.dart';
import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'package:intl/intl.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:logger/logger.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:gmwf/services/local_storage_service.dart';
import 'package:gmwf/services/donations_local_storage.dart';
import 'package:gmwf/pages/madrassa/utils/madrassa_local_storage.dart';
import 'package:gmwf/pages/school/utils/school_sync_service.dart';
import 'package:gmwf/pages/school/utils/school_local_storage.dart';
import 'package:gmwf/services/finance_local_storage.dart';
import 'package:gmwf/services/finance_loans_storage.dart';
import 'package:gmwf/services/finance_expenses_storage.dart';
import 'package:gmwf/services/permission_service.dart';
import 'package:gmwf/services/quota_service.dart';
import 'package:gmwf/services/cloud/cloud_db.dart';
import 'package:gmwf/services/cloud/sync_log.dart';
import 'package:gmwf/services/cloud/lan_firestore_gate.dart';
import 'package:collection/collection.dart';
import 'package:uuid/uuid.dart';
import 'package:gmwf/services/serials_service.dart';
import 'package:gmwf/services/camp_session_service.dart';
import 'package:gmwf/services/queue_self_healing_service.dart';
import 'package:gmwf/services/offline_auth_service.dart';
import 'package:gmwf/services/auth_service.dart';
import 'package:gmwf/services/pre_login_security_service.dart';

import 'package:gmwf/services/network_health_service.dart';
import 'package:gmwf/services/auto_update_service.dart';
import 'package:gmwf/services/donation_box_storage.dart';
import 'package:gmwf/realtime/connection_manager.dart';
import 'package:gmwf/realtime/realtime_manager.dart';
import 'package:gmwf/realtime/realtime_events.dart';
import 'package:gmwf/realtime/server_sync_coordinator.dart';
import 'package:gmwf/realtime/lan_server.dart';
import 'package:gmwf/realtime/lan_host_manager.dart';
import 'package:gmwf/services/hourly_dispensary_sync.dart';
import 'package:gmwf/tools/firestore_structure_sanitizer.dart';

class SyncQueueStats {
  final int expressCount;
  final int freightCount;
  final int deferredCount;
  final Duration? oldestAgeOverall;
  final Duration? oldestAgeDue;

  const SyncQueueStats({
    this.expressCount = 0,
    this.freightCount = 0,
    this.deferredCount = 0,
    this.oldestAgeOverall,
    this.oldestAgeDue,
  });
}

class SyncService {
  static final SyncService _instance = SyncService._internal();
  factory SyncService() => _instance;
  SyncService._internal();

  FirebaseFirestore get _db => FirebaseFirestore.instance;
  final Uuid _uuid = const Uuid();
  bool _isUploading = false;
  bool get isUploading => _isUploading;
  DateTime? _uploadStartedAt;
  /// A pass is treated as hung only after this long without progress. Must exceed the
  /// per-item limit (120 s): at 90 s a legitimately slow item let a second pass start, and
  /// both uploaded the same items (stock increments counted twice).
  static const int _hungPassSeconds = 150;
  /// Generation of the running pass; an abandoned (hung) pass must not clear the flag of the
  /// pass that replaced it when it finally ends.
  int _uploadGen = 0;
  String? _currentBranchId;
  List<String> _authorizedBranches = [];
  String? _currentUserRole;

  /// Ensures any branch string is strictly sanitized so 'all', 'global', or CNIC IDs are NEVER used as branch documents.
  String _cleanBranch(dynamic b, {String? fallback}) {
    return LocalStorageService.sanitizeBranchId(
      b?.toString(),
      fallback: fallback ?? _currentBranchId ?? 'karachi',
    );
  }

  static const List<String> _decisionFields = [
    'reviewedAt', 'reviewedBy', 'reviewedByName', 'decision', 'doctorReason',
    'approvedAt', 'approvedBy', 'rejectedAt', 'rejectedBy', 'acknowledgedAt', 'acknowledgedBy',
  ];

  static bool isDecidedRequestStatus(dynamic status) => LocalStorageService.isDecidedRequestStatus(status);

  /// Queue types handled by the request handlers, never by the generic collection writer.
  static const Set<String> _requestEventTypes = {
    'update_request_status', 'approve_request', 'reject_request', 'request_approved',
    'request_rejected', 'token_exception_approved', 'request_created', 'save_edit_request',
    'save_token_exception_request', 'token_exception_request', 'save_inventory_edit_request',
    'save_token_reversal_request', 'save_restock_request',
  };

  /// Makes a request upload keep a decision taken elsewhere. A request is created pending on
  /// one PC and decided on another; the creating PC's upload can land after the decision
  /// (queue paused, quota, backlog) and used to turn it back to pending. With a decided
  /// [local] copy its decision is sent; with a decided [cloud] doc the decision fields are
  /// left out so the merge keeps the cloud's. Returns true when [data] was changed.
  @visibleForTesting
  static bool applyDecidedRequestStatus(Map<String, dynamic> data, {Map? local, Map? cloud}) {
    if (isDecidedRequestStatus(data['status'])) return false;
    if (local != null && isDecidedRequestStatus(local['status'])) {
      data['status'] = local['status'];
      for (final f in _decisionFields) {
        if (local[f] != null) data[f] = local[f];
      }
      return true;
    }
    if (cloud != null && isDecidedRequestStatus(cloud['status'])) {
      data.remove('status');
      for (final f in _decisionFields) {
        data.remove(f);
      }
      return true;
    }
    return false;
  }

  /// Runs [applyDecidedRequestStatus] for an upload to [docRef], reading the local copy from
  /// [localBox] and, when that is not decided, the cloud doc (one read). A failed read throws,
  /// so the item waits for the next pass instead of risking an overwrite.
  Future<void> _keepDecidedRequestStatus(
      CloudDoc docRef, Map<String, dynamic> data, {required String localBox, required String id}) async {
    if (isDecidedRequestStatus(data['status'])) return;
    Map? local;
    try {
      final box = Hive.isBoxOpen(localBox) ? Hive.box(localBox) : await LocalStorageService.openBoxSafe(localBox);
      final v = box.get(id);
      if (v is Map) local = v;
    } catch (_) {}
    if (applyDecidedRequestStatus(data, local: local)) return;
    final snap = await docRef.get(const GetOptions(source: Source.server)).timeout(const Duration(seconds: 10));
    applyDecidedRequestStatus(data, cloud: snap.data());
  }

  StreamSubscription<List<ConnectivityResult>>? _connectivitySub;
  StreamSubscription<DocumentSnapshot>? _cloudSyncTriggerSub;
  String? _lastProcessedCloudTrigger;
  Timer? _dailyTokenTimer;
  Timer? _periodicSyncTimer;
  Timer? _queueDrainTimer;
  Timer? _retryTimer;

  Future<void> triggerManualSync() async => broadcastUniversalForceUpload();

  /// Universally broadcasts a force-upload command across BOTH LAN WebSockets AND Cloud Firestore.
  /// Every connected device and remote branch immediately executes an upload flush on its local queue.
  Future<void> broadcastUniversalForceUpload({String? branchId}) async {
    if (LanFirestoreGate.isLanDesk) return; // a dispensary desk on the LAN leaves Firestore to the LAN server
    QuotaService.clearDailyResetPause();
    final effectiveBranch = branchId ?? _currentBranchId ?? 'karachi';
    final user = LocalStorageService.getActiveUsername();
    
    // 1. Force sweep & upload on this machine immediately
    try {
      await sweepAllPendingLocalData(force: true);
    } catch (e) {
      debugPrint('[SyncService] sweepAllPendingLocalData warning in broadcast: $e');
      await triggerUpload(force: true);
    }

    // 2. Broadcast over LAN WebSocket so all local PCs upload
    try {
      RealtimeManager().sendMessage(RealtimeEvents.payload(
        type: RealtimeEvents.forceSyncUpload,
        branchId: effectiveBranch,
        data: {
          'triggeredAt': DateTime.now().toUtc().toIso8601String(),
          'triggeredBy': user,
        },
      ));
      debugPrint('[SyncService] 📡 LAN forceSyncUpload broadcast sent');
    } catch (e) {
      debugPrint('[SyncService] LAN forceSyncUpload broadcast warning: $e');
    }

    // 3. Broadcast to Cloud Firestore so remote stations across the internet upload
    try {
      final nowIso = DateTime.now().toUtc().toIso8601String();
      await _db.collection('app_control').doc('sync_trigger').set({
        'triggeredAt': FieldValue.serverTimestamp(),
        'timestamp': nowIso,
        'triggeredBy': user,
        'branchId': effectiveBranch,
      }, SetOptions(merge: true)).timeout(const Duration(seconds: 5));
      debugPrint('[SyncService] ☁️ Cloud sync trigger broadcasted to Firestore');
    } catch (e) {
      debugPrint('[SyncService] Firestore cloud sync trigger warning: $e');
    }
  }

  void _setupCloudSyncTriggerListener() {
    _cloudSyncTriggerSub?.cancel();
    _cloudSyncTriggerSub = _db.collection('app_control').doc('sync_trigger').snapshots().listen((snap) {
      if (LanFirestoreGate.isLanDesk) return; // the LAN server reacts to remote triggers for this desk
      if (!snap.exists) return;
      final data = snap.data();
      if (data == null) return;
      final ts = data['timestamp']?.toString();
      final triggeredBy = data['triggeredBy']?.toString() ?? '';
      if (ts == null || ts.isEmpty) return;
      
      // Do not re-trigger on our own broadcast
      if (triggeredBy.isNotEmpty && triggeredBy == LocalStorageService.getActiveUsername()) return;
      if (_lastProcessedCloudTrigger == ts) return;
      
      final triggerTime = DateTime.tryParse(ts);
      if (triggerTime != null && DateTime.now().toUtc().difference(triggerTime).inMinutes < 5) {
        _lastProcessedCloudTrigger = ts;
        debugPrint('[SyncService] ⚡ Received remote Cloud Sync Trigger from Firestore (by $triggeredBy) -> sweeping and uploading');
        // Not forced: a remote button press must not lift this PC's quota pause or backoffs
        // (that made every PC in every branch hammer an exhausted quota at once).
        sweepAllPendingLocalData();
      }
    }, onError: (e) {
      debugPrint('[SyncService] Cloud sync trigger listener error: $e');
    });
  }

  String? _startedForBranch;
  bool _dispBackfillDone = false, _fullBackfillDone = false;

  void start(String branchId, {List<String>? authorizedBranches, String? moduleScope}) {
    // About 25 screens call start() when they open. Each call used to restart every timer,
    // the cloud listener and the network check, and re-run the full backfill (every box
    // scanned, all users re-downloaded from Firestore). Once running for a branch, just
    // refresh the authorised branches and nudge an upload.
    final cleanBranch = _cleanBranch(branchId);
    if (_startedForBranch == cleanBranch && _periodicSyncTimer?.isActive == true) {
      if (authorizedBranches != null) {
        _authorizedBranches = authorizedBranches
            .map((b) => _cleanBranch(b))
            .where((b) => LocalStorageService.isValidBranchId(b))
            .toSet()
            .toList();
      }
      // Runs only if this module's backfill hasn't run yet this session (e.g. the app
      // opened on a dispensary screen and now a school/donations screen starts).
      _scheduleBackgroundBackfill(cleanBranch, moduleScope: moduleScope);
      triggerUpload();
      return;
    }
    _startedForBranch = cleanBranch;
    _currentBranchId = cleanBranch;
    _authorizedBranches = (authorizedBranches ?? [])
        .map((b) => _cleanBranch(b))
        .where((b) => LocalStorageService.isValidBranchId(b))
        .toSet()
        .toList();

    NetworkHealthService().start();
    _setupCloudSyncTriggerListener();
    
    _connectivitySub?.cancel();
    _connectivitySub = Connectivity().onConnectivityChanged.listen((results) {
      if (results.any((r) => r != ConnectivityResult.none)) {
        triggerUpload();
      }
    });

    _setupDailyTokenRefresh(branchId);
    
    _periodicSyncTimer?.cancel();
    // 10-minute periodic sync — flushes offline queues rapidly.
    // Quota consumption is minimal (zero snapshots, lightweight writes).
    _periodicSyncTimer = Timer.periodic(const Duration(minutes: 10), (_) {
      triggerUpload();
    });

    _queueDrainTimer?.cancel();
    // Supervisor timer (every 15s): ensures sync_queue drains swiftly.
    // Respects backoff windows and priority writes.
    _queueDrainTimer = Timer.periodic(const Duration(seconds: 15), (_) {
      if (Hive.isBoxOpen(LocalStorageService.syncBox) &&
          Hive.box(LocalStorageService.syncBox).isNotEmpty) {
        triggerUpload(); // non-forced: respects backoff and _isUploading guard
      }
    });

    // Cooperative background backfill:
    // Defers and paces backfill tasks sequentially to prevent main isolate
    // event-pump starvation and Windows (Not Responding) freezes.
    _scheduleBackgroundBackfill(branchId, moduleScope: moduleScope);

    // Stock changes are uploaded once an hour, added up per medicine.
    HourlyDispensarySync.start();
    LanFirestoreGate.start(); // dispensary desks on the LAN leave Firestore to the server

    ConnectionManager().removeReconnectListener(_onLanReconnected);
    ConnectionManager().addReconnectListener(_onLanReconnected);

    triggerUpload();
    Logger().d("SyncService started for branch: $branchId");
    unawaited(_probeFirebaseHealth());
  }

  DateTime? _lastVersionCheckAt;
  DateTime? _lastSyncPurgeAt;
  /// Set when the cloud cannot be reached; non-forced passes wait until then.
  DateTime? _stalledUntil;

  // Queue items a LAN desk may not upload itself (see Gate 1b in _uploadPending), by queue key.
  // In memory only: rewriting each item to record this appended its whole payload to the file.
  final Map<dynamic, DateTime> _lanDeferredUntil = {};
  static const Duration _lanDeferral = Duration(minutes: 15);

  bool _isLanDeferred(dynamic key) {
    final until = _lanDeferredUntil[key];
    if (until == null) return false;
    if (DateTime.now().isBefore(until)) return true;
    _lanDeferredUntil.remove(key);
    return false;
  }

  /// Item types whose cloud writes go to dispensary paths (patients, inventory, medicines,
  /// templates, restrictions) that CloudDb refuses on a LAN desk.
  static bool _lanServerOwnsType(String type) {
    final t = type.toLowerCase();
    return t == 'save_patient' ||
        t == 'delete_patient' ||
        t.contains('inventory') ||
        t.contains('stock') ||
        t.contains('medicine') ||
        t.contains('proforma') ||
        t.contains('doctor_template') ||
        t.contains('restriction');
  }

  /// Checks if an item is a Madrassa daily log, student profile, fee, attendance, or status update that should upload first.
  bool _isMadrassaDailyLog(Map item) {
    final t = (item['type'] ?? '').toString();
    return t.contains('madrassa') ||
        t == 'save_madrassa_log' ||
        t == 'save_madrassa_daily_log' ||
        t == 'save_madrassa_student' ||
        t == 'save_madrassa_admission' ||
        t == 'delete_madrassa_student' ||
        t == 'offboard_madrassa_student' ||
        t == 'update_madrassa_student' ||
        t == 'save_madrassa_attendance' ||
        t == 'save_madrassa_teacher_attendance' ||
        t == 'save_madrassa_fee_payment' ||
        t == 'save_madrassa_fee' ||
        t == 'save_madrassa_holiday' ||
        t == 'delete_madrassa_holiday';
  }

  /// Checks if an item belongs to the current calendar month.
  bool _isCurrentMonthItem(Map item) {
    final rawCreated = item['createdAt'] ?? item['enqueuedAt'];
    final serial = item['serial'] ?? (item['data'] is Map ? item['data']['serial'] : null);
    final dateKey = item['dateKey'] ?? item['date'] ?? (item['data'] is Map ? (item['data']['dateKey'] ?? item['data']['date']) : null);
    return LocalStorageService.isCurrentMonth(dateKey) ||
        LocalStorageService.isCurrentMonth(serial) ||
        LocalStorageService.isCurrentMonth(rawCreated);
  }

  /// Snapshot of current sync queue status for telemetry and health cards. The server screen
  /// asks every 30 s and the queue can hold thousands of items on days the cloud refuses
  /// writes, so the count hands control back to the UI every few hundred items.
  Future<SyncQueueStats> queueStats() async {
    if (!Hive.isBoxOpen(LocalStorageService.syncBox)) {
      return const SyncQueueStats();
    }
    final box = Hive.box(LocalStorageService.syncBox);
    if (box.isEmpty) {
      return const SyncQueueStats();
    }

    final now = DateTime.now();
    int express = 0;
    int freight = 0;
    int deferred = 0;
    DateTime? oldestOverall;
    DateTime? oldestDue;

    var counted = 0;
    for (final val in box.values.toList()) {
      if (++counted % 300 == 0) await Future<void>.delayed(Duration.zero);
      if (val is! Map) continue;
      final isBacklog = _isBacklogItem(val);
      if (isBacklog) {
        freight++;
      } else {
        express++;
      }

      bool isItemDeferred = false;
      final retryStr = val['nextRetryAt']?.toString();
      if (retryStr != null && retryStr.isNotEmpty) {
        final retry = DateTime.tryParse(retryStr);
        if (retry != null && retry.isAfter(now)) {
          isItemDeferred = true;
          deferred++;
        }
      }

      final timeStr = (val['enqueuedAt'] ?? val['createdAt'])?.toString();
      if (timeStr != null && timeStr.isNotEmpty) {
        final t = DateTime.tryParse(timeStr);
        if (t != null) {
          if (oldestOverall == null || t.isBefore(oldestOverall)) {
            oldestOverall = t;
          }
          if (!isItemDeferred) {
            if (oldestDue == null || t.isBefore(oldestDue)) {
              oldestDue = t;
            }
          }
        }
      }
    }

    return SyncQueueStats(
      expressCount: express,
      freightCount: freight,
      deferredCount: deferred,
      oldestAgeOverall: oldestOverall != null ? now.difference(oldestOverall) : null,
      oldestAgeDue: oldestDue != null ? now.difference(oldestDue) : null,
    );
  }

  /// Dual-Lane Classification:
  /// Express Lane (false) = today's live clinic work, madrassa daily logs, current month data, instant updates.
  /// Freight Lane (true) = records older than current month or historical freight.
  bool _isBacklogItem(Map item) {
    // Madrassa daily logs and current month's records are ALWAYS live express items!
    if (_isMadrassaDailyLog(item) || _isCurrentMonthItem(item)) {
      return false;
    }

    if (item['backlog'] == true) return true;

    // Check creation timestamp: older than 24 hours is backlog (unless current month)
    final createdStr = (item['createdAt'] ?? item['enqueuedAt'])?.toString();
    if (createdStr != null && createdStr.isNotEmpty) {
      final created = DateTime.tryParse(createdStr);
      if (created != null && DateTime.now().difference(created).inHours.abs() >= 24) {
        return true;
      }
    }

    // Check serial dateKey: if serial starts with dateKey not matching today, it's backlog
    final serial = (item['serial'] ?? (item['data'] is Map ? item['data']['serial'] : null))?.toString().trim();
    if (serial != null && serial.isNotEmpty) {
      final dateKey = CampSessionService.getDateKeyFromSerial(serial);
      if (dateKey.length == 6) {
        if (dateKey != _todayKeys().dmyy) return true;
      }
    }

    // Check explicit dateKey or date field in item or data
    final dateKey = (item['dateKey'] ?? item['date'] ?? (item['data'] is Map ? (item['data']['dateKey'] ?? item['data']['date']) : null))?.toString().trim();
    if (dateKey != null && dateKey.isNotEmpty) {
      if (dateKey.length == 6 && _sixDigits.hasMatch(dateKey)) {
        if (dateKey != _todayKeys().dmyy) return true;
      } else if (dateKey.length >= 10 && _isoDatePrefix.hasMatch(dateKey)) {
        if (!dateKey.startsWith(_todayKeys().iso)) return true;
      }
    }

    return false;
  }

  // _isBacklogItem runs for every queued item on each pass and on every queue count; building
  // the date formatters and patterns once per item made those whole-queue loops slow.
  static final RegExp _sixDigits = RegExp(r'^\d{6}$');
  static final RegExp _isoDatePrefix = RegExp(r'^\d{4}-\d{2}-\d{2}');
  ({String dmyy, String iso})? _todayKeyCache;
  DateTime? _todayKeyCacheAt;

  ({String dmyy, String iso}) _todayKeys() {
    final now = DateTime.now();
    final at = _todayKeyCacheAt;
    final cached = _todayKeyCache;
    if (cached != null && at != null && at.year == now.year && at.month == now.month && at.day == now.day) {
      return cached;
    }
    _todayKeyCacheAt = now;
    return _todayKeyCache = (dmyy: DateFormat('ddMMyy').format(now), iso: DateFormat('yyyy-MM-dd').format(now));
  }

  /// Causal Entity Precedence (Ensures parent docs precede child docs):
  /// 0: save_madrassa_log, save_madrassa_daily_log, update_madrassa_student (Top Priority)
  /// 1: save_patient (Root entity), save_madrassa_student, save_school_student, save_user
  /// 2: save_entry (Token entry)
  /// 3: save_prescription (Prescription referencing entry)
  /// 4: update_serial_status (Dispensing / lifecycle updates)
  /// 5: update_inventory, add_inventory_stock
  /// 6: save_donation
  /// 7: save_attendance_record, save_attendance, save_employee_attendance
  /// 8: school / other madrassa
  /// 10: default / background
  int _actionPrecedence(Map action) {
    final type = (action['type'] ?? '').toString();
    switch (type) {
      case 'save_madrassa_log':
      case 'save_madrassa_daily_log':
      case 'save_madrassa_student':
      case 'save_madrassa_admission':
      case 'delete_madrassa_student':
      case 'offboard_madrassa_student':
      case 'update_madrassa_student':
        return 0; // Madrassa logs and students always upload first!
      case 'save_patient':
      case 'save_school_student':
      case 'save_user':
        return 1;
      case 'save_entry':
        return 2;
      case 'save_prescription':
        return 3;
      case 'update_serial_status':
        return 4;
      case 'update_inventory':
      case 'add_inventory_stock':
        return 5;
      case 'save_donation':
      case 'save_donation_box':
      case 'save_dasterkhwan_tokens':
      case 'save_food_token':
      case 'save_dasterkhwan_entry':
      case 'serve_dasterkhwan_token':
      case 'reverse_dasterkhwan_tokens':
      case 'save_dasterkhwan_food_log':
        return 6;
      case 'save_attendance_record':
      case 'save_attendance':
      case 'save_employee_attendance':
      case 'save_madrassa_teacher_attendance':
      case 'save_school_teacher_attendance':
        return 7;
      case 'save_madrassa_attendance':
      case 'save_madrassa_fee_payment':
      case 'save_school_attendance':
      case 'save_school_fee':
        return 8;
      default:
        return 10;
    }
  }

  /// Compares two sync actions for deterministic, causal, FIFO upload order.
  int _compareSyncActions(Map a, Map b) {
    // 0. Madrassa daily logs ALWAYS upload first before anything else!
    final isMadrassaLogA = _isMadrassaDailyLog(a);
    final isMadrassaLogB = _isMadrassaDailyLog(b);
    if (isMadrassaLogA && !isMadrassaLogB) return -1;
    if (!isMadrassaLogA && isMadrassaLogB) return 1;

    // 1. Current month data uploads ahead of past month backlog
    final isCurrA = _isCurrentMonthItem(a);
    final isCurrB = _isCurrentMonthItem(b);
    if (isCurrA && !isCurrB) return -1;
    if (!isCurrA && isCurrB) return 1;

    // 2. Causal precedence: parent before child
    final precA = _actionPrecedence(a);
    final precB = _actionPrecedence(b);
    if (precA != precB) return precA.compareTo(precB);

    // 3. FIFO: Earlier actions before later actions
    final timeA = (a['createdAt'] ?? a['enqueuedAt'] ?? '') as String;
    final timeB = (b['createdAt'] ?? b['enqueuedAt'] ?? '') as String;
    if (timeA.isNotEmpty && timeB.isNotEmpty) {
      final cmp = timeA.compareTo(timeB);
      if (cmp != 0) return cmp;
    }
    return 0;
  }

  /// Errors worth retrying later without counting toward the dead-letter limit.
  bool _isTransientError(Object e) {
    if (e is TimeoutException || e is SocketException || e is HandshakeException || e is HttpException) return true;
    if (QuotaService.isQuotaError(e)) return true;
    final s = e.toString().toLowerCase();
    return s.contains('unavailable') || s.contains('deadline') || s.contains('network') ||
        s.contains('failed to connect') || s.contains('connection') || s.contains('aborted') ||
        s.contains('[cloud_firestore/internal]') || s.contains('unauthenticated') ||
        s.contains('permission-denied') || s.contains('permission denied') || s.contains('status: 403');
  }

  /// Records that are typically edited several times in a row.
  /// Madrassa daily logs and live current month records upload immediately with zero delay.
  static const Set<String> _coalescedTypes = {
    'save_madrassa_attendance',
    'save_madrassa_teacher_attendance',
    'save_school_attendance',
    'save_school_teacher_attendance',
    'save_school_teacher',
    'save_school_grade',
    'save_school_fee',
    'save_employee',
    'save_attendance_record',
    'save_employee_attendance',
    'save_biometric_device',
    'save_dasterkhwan_food_log',
  };
  static const Duration _coalesceDelay = Duration(seconds: 90);

  /// When a coalesced record may upload, or null if it may upload now.
  DateTime? _coalesceUntil(Map item) {
    if (_isMadrassaDailyLog(item) || _isCurrentMonthItem(item)) return null;
    if (!_coalescedTypes.contains(item['type']?.toString() ?? '')) return null;
    final changedAt = DateTime.tryParse((item['enqueuedAt'] ?? '').toString());
    if (changedAt == null) return null;
    final now = DateTime.now();
    // Never hold a record more than 5 minutes, even if it keeps changing.
    final createdAt = DateTime.tryParse((item['createdAt'] ?? '').toString());
    if (createdAt != null && now.difference(createdAt) > const Duration(minutes: 5)) return null;
    final until = changedAt.add(_coalesceDelay);
    return now.isBefore(until) ? until : null;
  }

  int _failuresLoggedThisMinute = 0;
  DateTime _failureLogWindowStart = DateTime.now();
  final Map<String, int> _failureCountsByType = {};

  void _noteUploadFailure(String type, String key, int attempt, Object error, StackTrace st) {
    _failureCountsByType[type] = (_failureCountsByType[type] ?? 0) + 1;
    final now = DateTime.now();
    if (now.difference(_failureLogWindowStart).inSeconds >= 60) {
      if (_failureCountsByType.isNotEmpty) {
        debugPrint('[SyncService] ❌ Upload failures in the last minute: $_failureCountsByType');
      }
      _failureCountsByType.clear();
      _failuresLoggedThisMinute = 0;
      _failureLogWindowStart = now;
    }
    // Show only the first few individual failures per minute; the summary above covers the rest.
    if (_failuresLoggedThisMinute < 3) {
      _failuresLoggedThisMinute++;
      final shortErr = error is TimeoutException ? 'timed out (no answer from Firestore)' : error.toString();
      debugPrint('[SyncService] ❌ $type attempt $attempt failed: $shortErr');
      if (error is! TimeoutException) debugPrint(st.toString().split('\n').take(4).join('\n'));
    }
  }

  bool _probedFirebaseHealth = false;

  /// Once per session: records in gmwf_sync.log who is signed in, how much is queued and
  /// whether Firestore answers reads. Read-only — it used to write a probe document on
  /// every start, which was one more write that could get stuck in the SDK's queue.
  Future<void> _probeFirebaseHealth() async {
    if (LanFirestoreGate.isLanDesk) return; // a dispensary desk on the LAN leaves Firestore to the LAN server
    if (_probedFirebaseHealth || kIsWeb) return;
    _probedFirebaseHealth = true;
    final sw = Stopwatch()..start();
    try {
      final user = FirebaseAuth.instance.currentUser;
      final queued = Hive.isBoxOpen(LocalStorageService.syncBox) ? Hive.box(LocalStorageService.syncBox).length : -1;
      SyncLog.write('Startup check: app ${AutoUpdateService.currentVersion}, '
          '${user == null ? 'not signed in to Firebase (uploads go unauthenticated)' : 'signed in (${user.uid})'}, '
          '$queued item(s) queued, ${QuotaService.dailyWriteCount} writes from this PC today'
          '${QuotaService.isPausedForDailyReset ? ', quota pause until ${QuotaService.dailyResetPauseUntil?.toLocal()}' : ''}');
      try {
        await FirebaseFirestore.instance
            .collection('branches')
            .limit(1)
            .get(const GetOptions(source: Source.server))
            .timeout(const Duration(seconds: 8));
        SyncLog.write('Startup check: Firestore reads OK (${sw.elapsedMilliseconds} ms)');
      } catch (e) {
        SyncLog.write('Startup check: Firestore read FAILED after ${sw.elapsedMilliseconds} ms: $e');
      }
    } catch (e) {
      SyncLog.write('Startup check error: $e');
    }
  }

  void _onLanReconnected() {
    final bId = _currentBranchId;
    if (bId != null && bId.isNotEmpty) {
      Logger().d('[SyncService] 🔄 LAN reconnected — pushing any unsynced local tokens to LAN Server');
      _pushUnsyncedEntriesToLanServer(bId).ignore();
    }
  }

  void updateAuthorizedBranches(List<String> branchIds) {
    _authorizedBranches = branchIds;
    Logger().d("SyncService: Updated authorized branches: $branchIds");
    triggerUpload();
  }

  bool _isBackfillRunning = false;

  void _scheduleBackgroundBackfill(String branchId, {String? moduleScope}) {
    // Once per app session: the sweep and the 15 s upload timer keep the queue complete
    // afterwards, and "Sync now" still runs the full sweep on demand.
    final isDispScope = moduleScope == 'dispensary';
    if (_isBackfillRunning || _fullBackfillDone || (isDispScope && _dispBackfillDone)) return;
    if (isDispScope) {
      _dispBackfillDone = true;
    } else {
      _fullBackfillDone = true;
    }
    // Defer backfill by 20 seconds so the UI paints, animations complete, and user is seated
    Timer(const Duration(seconds: 20), () async {
      if (_isBackfillRunning) return;
      _isBackfillRunning = true;
      try {
        Logger().d('[SyncService] 🚀 Starting cooperative background backfill pipeline...');

        // ── HEAL falsely-synced attendance records ─────────────────────────
        // Old bug in zkteco_network_service.dart set synced=!enqueueForSync,
        // which could be true before Firestore ever confirmed the upload.
        // We detect these as synced==true AND lastSyncedAt==null, and reset
        // them to pending so _enqueueMissingAttendance below can re-upload them.
        try {
          if (Hive.isBoxOpen(LocalStorageService.attendanceBox)) {
            final aBox = Hive.box(LocalStorageService.attendanceBox);
            int healedCount = 0;
            for (final key in aBox.keys) {
              final raw = aBox.get(key);
              if (raw is Map &&
                  raw['lastSyncedAt'] == null &&
                  (raw['synced'] == true || raw['syncStatus'] == 'synced')) {
                await aBox.put(key, Map<String, dynamic>.from(raw)
                  ..['synced'] = false
                  ..['syncStatus'] = 'pending'
                  ..['pendingSync'] = true);
                healedCount++;
              }
            }
            if (healedCount > 0) {
              Logger().d('[SyncService] 🩹 Healed $healedCount falsely-synced attendance records → re-queuing for upload');
            }
          }
        } catch (e) {
          Logger().d('[SyncService] Attendance heal notice: $e');
        }
        // ── END HEAL ────────────────────────────────────────────────────────

        if (moduleScope == 'dispensary') {
          final isClientOnLan = !LanServer.isRunning && !LanHostManager.isHostRunning && RealtimeManager().hasServerLink;
          if (isClientOnLan) {
            // Dispensary client on LAN delegates cloud sync to Server node
            await _pushUnsyncedEntriesToLanServer(branchId);
          } else {
            await _enqueueMissingEntries(branchId);
            await Future.delayed(const Duration(milliseconds: 50));
            await _enqueueMissingPatients(branchId);
            await Future.delayed(const Duration(milliseconds: 50));
          }
        } else {
          // The full sweep queues every module (tokens, patients, donations, food, staff,
          // attendance, madrassa, school, users). Each of those used to run here first and
          // then a second time inside the sweep — every local record scanned twice per start.
          await sweepAllPendingLocalData(force: false);
          await Future.delayed(const Duration(milliseconds: 50));
          await LocalStorageService.downloadUsers(branchId);

          // Run full structure sanitization (clean bogus/duplicate branches & consolidate bloat)
          try {
            if (Hive.isBoxOpen('app_flags')) {
              final flags = Hive.box('app_flags');
              if (flags.get('bogus_branches_cleaned_v5', defaultValue: false) != true) {
                try {
                  await FirestoreStructureSanitizer.executeFullStructureSanitization();
                  await flags.put('bogus_branches_cleaned_v5', true);
                } catch (e) {
                  Logger().d('[SyncService] Structure sanitization notice: $e');
                }
              }
            }
          } catch (_) {}
        }
        Logger().d('[SyncService] ✅ Cooperative background backfill pipeline finished.');
      } catch (e) {
        Logger().d('[SyncService] Backfill pipeline warning: $e');
      } finally {
        _isBackfillRunning = false;
      }
    });
  }

  Future<void> _enqueueMissingEntries(String branchId, {bool force = false}) async {
    UiStallMonitor.mark('sync: _enqueueMissingEntries');
    try {
      // Single-Writer Gateway Architecture:
      // If connected to LAN server, the Server is the authoritative single source of truth for the branch.
      // We do not enqueue directly to Firestore from client stations.
      if (!LanServer.isRunning && !LanHostManager.isHostRunning && RealtimeManager().hasServerLink) {
        Logger().d('[SyncService] LAN server connected — pushing unsynced tokens to LAN Server (delegated to Server)');
        await _pushUnsyncedEntriesToLanServer(branchId);
        return;
      }

      if (!Hive.isBoxOpen(LocalStorageService.entriesBox)) {
        await LocalStorageService.ensureBoxOpen(LocalStorageService.entriesBox);
      }
      if (!Hive.isBoxOpen(LocalStorageService.syncBox)) {
        await LocalStorageService.ensureBoxOpen(LocalStorageService.syncBox);
      }
      final entriesBox = Hive.box(LocalStorageService.entriesBox);
      final syncBox    = Hive.box(LocalStorageService.syncBox);
      final todayDateKey = LocalStorageService.getTodayDateKey();

      final alreadyQueued = syncBox.values
          .where((v) => v is Map && (v['type'] == 'save_entry' || v['type'] == 'save_prescription'))
          .map((v) {
            final b = (v['branchId'] ?? v['data']?['branchId'] ?? '').toString().toLowerCase().trim();
            final s = (v['serial'] ?? v['data']?['serial'])?.toString().trim().toUpperCase();
            final c = (v['campId'] ?? v['data']?['campId'] ?? v['data']?['dispensaryTag'] ?? '').toString().toLowerCase().trim();
            return '$b-$c-$s';
          })
          .whereType<String>()
          .toSet();

      int queued = 0;
      int processed = 0;
      for (final key in entriesBox.keys) {
        processed++;
        if (processed % 10 == 0) {
          await Future.delayed(const Duration(milliseconds: 2));
        }

        final raw = entriesBox.get(key);
        if (raw == null || raw is! Map) continue;

        final data = Map<String, dynamic>.from(raw);
        if (LocalStorageService.isStressTestRecord(data, key)) continue;

        final serial = (data['serial'] ?? key.toString().split('-').last).toString().trim().toUpperCase();
        if (serial.isEmpty) continue;

        final itemDateKey = (data['dateKey'] ?? '').toString();
        final serialDateKey = CampSessionService.getDateKeyFromSerial(serial);
        final bool isToday = (itemDateKey == todayDateKey) || (serialDateKey == todayDateKey);
        final rawCreated = data['createdAt'] ?? data['time'] ?? data['timestamp'] ?? data['date'];
        final bool isThisMonth = LocalStorageService.isCurrentMonth(itemDateKey) ||
            LocalStorageService.isCurrentMonth(serialDateKey) ||
            LocalStorageService.isCurrentMonth(rawCreated);

        final isSynced = (data['synced'] == true || data['syncStatus'] == 'synced') && data['pendingSync'] != true;
        if (isSynced) continue;

        // Skip phantom entries fabricated by old migrations
        final pCnic = (data['patientCnic'] ?? data['cnic'] ?? '').toString().trim();
        final pName = (data['patientName'] ?? data['name'] ?? '').toString().trim().toLowerCase();
        final isPhantomCnic = pCnic.startsWith('unknown_cnic_') || pCnic.isEmpty;
        final isPhantomName = pName.isEmpty || pName == 'unknown' || pName == 'unknown patient';
        if (isPhantomCnic && isPhantomName) continue;

        final effectiveBranch = (data['branchId']?.toString().isNotEmpty == true)
            ? data['branchId'].toString().toLowerCase().trim()
            : branchId.toLowerCase().trim();
        final campId = (data['campId'] ?? data['dispensaryId'] ?? data['dispensaryTag'] ?? '').toString().toLowerCase().trim();
        final uniqueKey = '$effectiveBranch-$campId-$serial';
        if (alreadyQueued.contains(uniqueKey) && data['pendingSync'] != true) continue;

        final queueType = resolveQueueType(data['queueType']?.toString(), branchId: effectiveBranch);
        final entryDateKey = serialDateKey.isNotEmpty ? serialDateKey : (itemDateKey.isNotEmpty ? itemDateKey : todayDateKey);

        await LocalStorageService.enqueueSync({
          'type':      'save_entry',
          'branchId':  effectiveBranch,
          'dateKey':   entryDateKey,
          'queueType': queueType,
          'serial':    serial,
          'campId':    campId,
          'data':      data,
        });
        alreadyQueued.add(uniqueKey);
        queued++;
      }

      if (queued > 0) {
        Logger().d('[SyncService] 📥 Backfill: queued $queued unsynced local tokens for upload');
      }
    } catch (e) {
      Logger().d('[SyncService] _enqueueMissingEntries error: $e');
    }
  }

  /// Pushes any local tokens, prescriptions, and dispenses created while offline directly to the LAN server upon reconnection
  Future<void> _pushUnsyncedEntriesToLanServer(String branchId) async {
    try {
      if (!Hive.isBoxOpen(LocalStorageService.entriesBox)) {
        await LocalStorageService.ensureBoxOpen(LocalStorageService.entriesBox);
      }
      final entriesBox = Hive.box(LocalStorageService.entriesBox);
      int pushed = 0;
      int processed = 0;
      for (final key in entriesBox.keys) {
        processed++;
        if (processed % 25 == 0) {
          await Future.delayed(const Duration(milliseconds: 1));
        }
        final raw = entriesBox.get(key);
        if (raw == null || raw is! Map) continue;

        final data = Map<String, dynamic>.from(raw);
        final rawCreated = data['createdAt'] ?? data['time'] ?? data['timestamp'] ?? data['date'];
        final dt = rawCreated != null ? DateTime.tryParse(rawCreated.toString()) : null;
        final isOld = dt != null && DateTime.now().difference(dt).inHours > 48;
        if (isOld && data['pendingSync'] != true) {
          if (data['syncStatus'] != 'synced' || data['synced'] != true) {
            data['syncStatus'] = 'synced';
            data['synced'] = true;
            await entriesBox.put(key, data);
          }
          continue;
        }

        final bool entryUnsynced = (data['synced'] != true && data['syncStatus'] != 'synced') || data['pendingSync'] == true;
        final bool prescUnsynced = data['prescriptionSynced'] == false ||
            ((data['prescription'] != null || data['medicines'] != null) && data['prescriptionSynced'] != true);
        final bool dispenseUnsynced = data['dispenseStatus'] == 'dispensed' && data['dispenseSynced'] != true;

        if (!entryUnsynced && !prescUnsynced && !dispenseUnsynced) continue;
        if (LocalStorageService.isStressTestRecord(data, key)) continue;

        // "Unsynced" means "not yet in Firestore", not "the LAN server lacks it". While the
        // cloud refuses writes (daily quota) nothing ever becomes synced, so every device used
        // to re-send every token it holds - including the ones the server itself sent it - on
        // each sweep and reconnect, and the server broadcast them all to the doctor again.
        // A token is now pushed once per state change, and never when it came from the server.
        final pushSig = LocalStorageService.lanPushSignature(data);
        if (data['lanPushSig'] == pushSig) continue;

        final serial = (data['serial'] ?? key.toString().split('-').last).toString().trim().toUpperCase();
        if (serial.isEmpty) continue;

        final dateKey = (data['dateKey'] ?? LocalStorageService.getTodayDateKey()).toString();
        final effectiveBranch = (data['branchId']?.toString().isNotEmpty == true)
            ? data['branchId'].toString()
            : branchId;
        final queueType = resolveQueueType(data['queueType']?.toString(), branchId: effectiveBranch);

        // 1. Push entry if token itself is unsynced
        if (entryUnsynced) {
          RealtimeManager().sendMessage({
            ...RealtimeEvents.payload(
              type: RealtimeEvents.saveEntry,
              branchId: effectiveBranch,
              data: data,
            ),
            'queueType': queueType,
            'dateKey':   dateKey,
            'serial':    serial,
          });
          pushed++;
        }

        // 2. Push prescription if clinical work was done
        if (prescUnsynced && (data['prescription'] != null || data['medicines'] != null)) {
          RealtimeManager().sendMessage(RealtimeEvents.payload(
            type: RealtimeEvents.savePrescription,
            branchId: effectiveBranch,
            data: {
              'serial': serial,
              'dateKey': dateKey,
              'queueType': queueType,
              'branchId': effectiveBranch,
              if (data['entryUid'] != null) 'entryUid': data['entryUid'],
              'status': 'completed',
              // The prescription's own times, never "now": a replay stamped now looked newer
              // than the doctor's real later edit, which the receivers then refused.
              if ((data['completedAt'] ?? (data['prescription'] is Map ? data['prescription']['completedAt'] : null)) != null)
                'completedAt': data['completedAt'] ?? data['prescription']['completedAt'],
              if (data['prescription'] is Map && data['prescription']['updatedAt'] != null)
                'updatedAt': data['prescription']['updatedAt'],
              'doctorName': data['doctorName'],
              'doctorId': data['doctorId'],
              'daysOfMedicine': data['daysOfMedicine'] ?? 1,
              'extraCharge': data['extraCharge'],
              'vitals': data['vitals'],
              'prescription': data['prescription'],
              'medicines': data['medicines'],
              'diagnosis': data['diagnosis'],
              'complaints': data['complaints'],
              // Only the real status: a default 'pending' here could overwrite a dispense
              // the dispenser already recorded.
              if (data['dispenseStatus'] != null) 'dispenseStatus': data['dispenseStatus'],
              'campId': data['campId'] ?? data['dispensaryId'],
              'dispensaryTag': data['dispensaryTag'],
            },
          ));
          pushed++;
        }

        // 3. Push dispense if medication was dispensed
        if (dispenseUnsynced) {
          RealtimeManager().sendMessage(RealtimeEvents.payload(
            type: RealtimeEvents.dispenseCompleted,
            data: {
              'branchId': effectiveBranch,
              'serial': serial,
              'dateKey': dateKey,
              'queueType': queueType,
              if (data['entryUid'] != null) 'entryUid': data['entryUid'],
              'dispenseStatus': 'dispensed',
              'status': 'completed',
              if (data['dispensedAt'] != null) 'dispensedAt': data['dispensedAt'],
              if (data['dispensedBy'] != null) 'dispensedBy': data['dispensedBy'],
              if (data['dispenserName'] != null) 'dispenserName': data['dispenserName'],
              if (data['medicines'] != null) 'medicines': data['medicines'],
              'campId': data['campId'] ?? data['dispensaryId'],
              'dispensaryTag': data['dispensaryTag'],
            },
          ));
          pushed++;
        }

        // RealtimeManager keeps undelivered messages in its outbox, so one send is enough.
        await entriesBox.put(key, {...data, 'lanPushSig': pushSig});
      }
      if (pushed > 0) {
        Logger().d('[SyncService] 📤 Pushed $pushed unsynced local events (tokens/prescriptions/dispenses) to LAN Server');
      }
    } catch (e) {
      Logger().d('[SyncService] _pushUnsyncedEntriesToLanServer error: $e');
    }
  }

  /// Whether a backfill should upload this donation: not synced, not deleted, and taken on
  /// this PC. The old test skipped anything with a firestoreId, but saveDonation sets one
  /// before the first upload, so the backfill never picked up a single failed donation.
  /// Records from before `originDevice` existed keep that old rule (a LAN copy from another
  /// PC also had a firestoreId), so this change does not make every PC re-upload them.
  static bool needsDonationBackfill(Map data, String deviceId) {
    final synced = (data['syncStatus'] == 'synced' || data['synced'] == true) && data['pendingSync'] != true;
    if (synced) return false;
    if (data['syncStatus'] == 'deleted' || data['isDeleted'] == true) return false;
    if (data['lanReceived'] == true) return false;
    final origin = (data['originDevice'] ?? '').toString().trim();
    if (origin.isNotEmpty) return origin == deviceId;
    return data['firestoreId'] == null || data['pendingSync'] == true;
  }

  Future<void> _enqueueMissingDonations(String branchId) async {
    UiStallMonitor.mark('sync: _enqueueMissingDonations');
    try {
      if (!Hive.isBoxOpen(DonationsLocalStorage.donationsBox)) {
        await LocalStorageService.openBoxSafe(DonationsLocalStorage.donationsBox);
      }
      if (!Hive.isBoxOpen(LocalStorageService.syncBox)) {
        await LocalStorageService.openBoxSafe(LocalStorageService.syncBox);
      }
      final donationsBox = Hive.box(DonationsLocalStorage.donationsBox);
      final syncBox      = Hive.box(LocalStorageService.syncBox);
      
      final alreadyQueued = <String>{};
      for (final v in syncBox.values) {
        if (v is Map && v['type'] == 'save_donation') {
          final id = v['localId']?.toString();
          if (id != null) alreadyQueued.add(id);
        }
      }

      final deviceId = await PreLoginSecurityService.getDeviceId();
      int queued = 0;
      int processed = 0;
      for (final key in donationsBox.keys) {
        processed++;
        if (processed % 10 == 0) {
          await Future.delayed(const Duration(milliseconds: 2));
        }

        final keyStr = key.toString();
        final raw = donationsBox.get(key);
        if (raw == null || raw is! Map) continue;

        final data = Map<String, dynamic>.from(raw);
        if (!needsDonationBackfill(data, deviceId)) continue;

        final localId = data['localId']?.toString();
        if (localId == null || localId.isEmpty) continue;
        if (alreadyQueued.contains(localId)) continue;

        final targetBranch = _cleanBranch(data['branchId'] ?? branchId);

        await LocalStorageService.enqueueSync({
          'backlog': true, // backfill: uses the backlog share of the daily quota
          'type': 'save_donation',
          'branchId': targetBranch,
          'localId': localId,
          'hiveKey': keyStr,
          'data': data,
        });
        queued++;
      }
      
      if (queued > 0) {
        Logger().d('[SyncService] 📥 Backfill: queued $queued pending donations for upload');
      }
    } catch (e) {
      Logger().d('[SyncService] _enqueueMissingDonations error: $e');
    }
  }

  /// True when this PC issued the food token and so is the one that must upload it.
  /// Each upload adds to the day's totalTokens, so a token that reached this PC over the
  /// LAN (another PC issued it and uploads it itself) must never be uploaded here again.
  /// Tokens from before `originDevice` existed count as local unless a LAN receiver
  /// marked them `lanReceived`.
  static bool isFoodTokenOwnedHere(Map token, String deviceId) {
    if (token['lanReceived'] == true) return false;
    final origin = (token['originDevice'] ?? '').toString().trim();
    if (origin.isEmpty) return true;
    return origin == deviceId;
  }

  /// Picks the food tokens a backfill should upload: not yet synced, issued on this PC, and
  /// not already inside a queued save_dasterkhwan_tokens item (whose batch id never
  /// matches a backfill batch id, so the batch-id check alone queued them twice).
  static List<Map<String, dynamic>> selectFoodTokensToUpload(
    Iterable<dynamic> tokens, {
    required String deviceId,
    required Iterable<dynamic> queuedActions,
  }) {
    final queuedTokenIds = <String>{};
    for (final v in queuedActions) {
      if (v is! Map || v['type'] != 'save_dasterkhwan_tokens') continue;
      final data = v['data'];
      final list = data is Map ? data['tokens'] : null;
      if (list is! List) continue;
      for (final t in list) {
        if (t is Map) {
          final id = (t['id'] ?? t['localId'])?.toString();
          if (id != null && id.isNotEmpty) queuedTokenIds.add(id);
        }
      }
    }

    final result = <Map<String, dynamic>>[];
    for (final raw in tokens) {
      if (raw is! Map) continue;
      final t = Map<String, dynamic>.from(raw);
      final unsynced = t['synced'] != true || t['syncStatus'] != 'synced' || t['pendingSync'] == true;
      if (!unsynced) continue;
      if (!isFoodTokenOwnedHere(t, deviceId)) continue;
      final id = (t['id'] ?? t['localId'])?.toString();
      if (id != null && queuedTokenIds.contains(id)) continue;
      result.add(t);
    }
    return result;
  }

  /// Queues this PC's food tokens that never reached the cloud. Only [onlyBranch]'s tokens
  /// when given; otherwise every branch's, each under its own branch.
  Future<void> enqueueMissingFoodTokens(String branchId, {String? onlyBranch, bool backlog = true}) =>
      _enqueueMissingFoodTokens(branchId, onlyBranch: onlyBranch, backlog: backlog);

  Future<void> _enqueueMissingFoodTokens(String branchId, {String? onlyBranch, bool backlog = true}) async {
    UiStallMonitor.mark('sync: _enqueueMissingFoodTokens');
    try {
      if (!Hive.isBoxOpen('dasterkhwaan_tokens')) {
        await LocalStorageService.openBoxSafe('dasterkhwaan_tokens');
      }
      if (!Hive.isBoxOpen(LocalStorageService.syncBox)) {
        await LocalStorageService.openBoxSafe(LocalStorageService.syncBox);
      }
      final tBox = Hive.box('dasterkhwaan_tokens');
      final syncBox = Hive.box(LocalStorageService.syncBox);

      final deviceId = await PreLoginSecurityService.getDeviceId();
      final onlyB = onlyBranch == null ? null : _cleanBranch(onlyBranch);
      final unsynced = selectFoodTokensToUpload(
        tBox.values,
        deviceId: deviceId,
        queuedActions: syncBox.values,
      ).where((t) => onlyB == null || _cleanBranch(t['branchId'] ?? branchId) == onlyB).toList();

      if (unsynced.isNotEmpty) {
        // Group by branch AND date: one item writes one branch's day doc.
        final groups = <String, List<Map<String, dynamic>>>{};
        for (final t in unsynced) {
          final b = _cleanBranch(t['branchId'] ?? branchId);
          final dk = (t['dateKey']?.toString() ?? DateTime.now().toIso8601String().substring(0, 10)).trim();
          groups.putIfAbsent('$b|$dk', () => []).add(t);
        }
        for (final entry in groups.entries) {
          final sep = entry.key.indexOf('|');
          final targetBranch = entry.key.substring(0, sep);
          final dateKey = entry.key.substring(sep + 1);
          final tokens = entry.value
            ..sort((a, b) => ((a['number'] as num?) ?? 0).compareTo((b['number'] as num?) ?? 0));
          final firstNum = tokens.first['number'] ?? '';
          final lastNum = tokens.last['number'] ?? '';
          final batchId = 'dst_sweep_${targetBranch}_${dateKey}_${firstNum}_$lastNum';

          await LocalStorageService.enqueueSync({
            if (backlog) 'backlog': true, // backfill: uses the backlog share of the daily quota
            'type': 'save_dasterkhwan_tokens',
            'entityId': batchId,
            'batchId': batchId,
            'branchId': targetBranch,
            'dateKey': dateKey,
            'data': {
              'branchId': targetBranch,
              'dateKey': dateKey,
              'quantity': tokens.length,
              'tokens': tokens,
              'issuedBy': tokens.first['issuedBy'] ?? 'Office Boy',
              'batchId': batchId,
            },
          });
        }
        Logger().d('[SyncService] 📥 Backfill: queued unsynced food tokens for upload');
      }
    } catch (e) {
      Logger().d('[SyncService] _enqueueMissingFoodTokens error: $e');
    }
  }

  Future<void> _enqueueMissingFoodLogs(String branchId) async {
    UiStallMonitor.mark('sync: _enqueueMissingFoodLogs');
    try {
      if (!Hive.isBoxOpen(LocalStorageService.dasterkhwaanFoodLogsBox)) {
        await LocalStorageService.openBoxSafe(LocalStorageService.dasterkhwaanFoodLogsBox);
      }
      if (!Hive.isBoxOpen(LocalStorageService.syncBox)) {
        await LocalStorageService.openBoxSafe(LocalStorageService.syncBox);
      }
      final box = Hive.box(LocalStorageService.dasterkhwaanFoodLogsBox);
      final syncBox = Hive.box(LocalStorageService.syncBox);

      final alreadyQueued = <String>{};
      for (final v in syncBox.values) {
        if (v is Map && v['type'] == 'save_dasterkhwan_food_log') {
          final id = v['entityId']?.toString();
          if (id != null) alreadyQueued.add(id);
        }
      }

      for (final raw in box.values) {
        if (raw is Map) {
          final log = Map<String, dynamic>.from(raw);
          final id = (log['id'] ?? log['logId'])?.toString();
          if (id == null || id.isEmpty) continue;
          if (log['synced'] != true && log['syncStatus'] != 'synced') {
            if (alreadyQueued.contains(id)) continue;
            final targetBranch = _cleanBranch(log['branchId']?.toString() ?? branchId);
            final dateKey = log['dateKey']?.toString() ?? DateTime.now().toIso8601String().substring(0, 10);
            await LocalStorageService.enqueueSync({
              'backlog': true, // backfill: uses the backlog share of the daily quota
              'type': 'save_dasterkhwan_food_log',
              'entityId': id,
              'branchId': targetBranch,
              'dateKey': dateKey,
              'data': log,
            });
            alreadyQueued.add(id);
          }
        }
      }
    } catch (e) {
      Logger().d('[SyncService] _enqueueMissingFoodLogs error: $e');
    }
  }

  Future<void> _enqueueMissingEmployees(String branchId) async {
    UiStallMonitor.mark('sync: _enqueueMissingEmployees');
    try {
      if (!Hive.isBoxOpen(LocalStorageService.employeesBox)) {
        await LocalStorageService.openBoxSafe(LocalStorageService.employeesBox);
      }
      if (!Hive.isBoxOpen(LocalStorageService.syncBox)) {
        await LocalStorageService.openBoxSafe(LocalStorageService.syncBox);
      }
      final empBox = Hive.box(LocalStorageService.employeesBox);
      final syncBox = Hive.box(LocalStorageService.syncBox);

      final alreadyQueued = <String>{};
      for (final v in syncBox.values) {
        if (v is Map && v['type'] == 'save_employee') {
          final id = (v['localId'] ?? v['data']?['localId'] ?? v['data']?['id'])?.toString();
          if (id != null) alreadyQueued.add(id);
        }
      }

      int queued = 0;
      int processed = 0;
      for (final key in empBox.keys) {
        processed++;
        if (processed % 10 == 0) {
          await Future.delayed(const Duration(milliseconds: 2));
        }
        final raw = empBox.get(key);
        if (raw == null || raw is! Map) continue;
        final data = Map<String, dynamic>.from(raw);
        if (FinanceLocalStorage.isPlaceholderEmployee(data)) continue;

        final isSynced = (data['synced'] == true || data['syncStatus'] == 'synced') && data['pendingSync'] != true;
        if (isSynced) continue;

        final localId = (data['localId'] ?? data['id'] ?? key).toString().trim();
        if (localId.isEmpty || alreadyQueued.contains(localId)) continue;

        final targetBranch = _cleanBranch(data['branchId'] ?? branchId);

        await LocalStorageService.enqueueSync({
          'backlog': true, // backfill: uses the backlog share of the daily quota
          'type': 'save_employee',
          'branchId': targetBranch,
          'localId': localId,
          'data': data,
        });
        alreadyQueued.add(localId);
        queued++;
      }

      if (queued > 0) {
        Logger().d('[SyncService] 📥 Backfill: queued $queued unsynced employees for upload');
      }
    } catch (e) {
      Logger().d('[SyncService] _enqueueMissingEmployees error: $e');
    }
  }

  Future<void> _enqueueMissingAttendance(String branchId, {bool force = false}) async {
    UiStallMonitor.mark('sync: _enqueueMissingAttendance');
    try {
      if (!Hive.isBoxOpen(LocalStorageService.attendanceBox)) {
        await LocalStorageService.openBoxSafe(LocalStorageService.attendanceBox);
      }
      if (!Hive.isBoxOpen(LocalStorageService.syncBox)) {
        await LocalStorageService.openBoxSafe(LocalStorageService.syncBox);
      }
      final attBox = Hive.box(LocalStorageService.attendanceBox);
      final syncBox = Hive.box(LocalStorageService.syncBox);

      final alreadyQueued = <String>{};
      for (final v in syncBox.values) {
        if (v is Map && (v['type'] == 'save_attendance_record' || v['type'] == 'save_employee_attendance')) {
          final empId = (v['employeeId'] ?? v['data']?['employeeId'])?.toString();
          final d = (v['date'] ?? v['data']?['date'])?.toString();
          if (empId != null && d != null) alreadyQueued.add('${empId}_$d');
        }
      }

      final flagsBox = Hive.isBoxOpen('app_flags') ? Hive.box('app_flags') : null;
      int queued = 0;
      int processed = 0;
      for (final key in attBox.keys) {
        processed++;
        if (processed % 10 == 0) {
          await Future.delayed(const Duration(milliseconds: 2));
        }
        final raw = attBox.get(key);
        if (raw == null || raw is! Map) continue;
        final data = Map<String, dynamic>.from(raw);

        final isSynced = (data['synced'] == true && data['syncStatus'] == 'synced') && data['pendingSync'] != true && data['lastSyncedAt'] != null;
        if (isSynced) continue;

        final flagsBox = Hive.isBoxOpen('app_flags') ? Hive.box('app_flags') : null;
        final flagSynced = flagsBox?.get('attendance_synced_$key') == true;
        if (flagSynced && data['pendingSync'] != true && data['lastSyncedAt'] != null) continue;

        final employeeId = (data['employeeId'] ?? data['empId'] ?? data['userId'] ?? (key.toString().contains('_') ? key.toString().split('_')[0] : '')).toString().trim();
        final dateStr = (data['date'] ?? data['dateKey'] ?? (key.toString().contains('_') ? key.toString().split('_')[1] : DateFormat('yyyy-MM-dd').format(DateTime.now()))).toString().trim();
        if (employeeId.isEmpty || dateStr.isEmpty) continue;

        final flagEmpSynced = flagsBox?.get('attendance_synced_${employeeId}_$dateStr') == true;
        if (flagEmpSynced && data['pendingSync'] != true && data['lastSyncedAt'] != null) continue;

        final queueKey = '${employeeId}_$dateStr';
        if (alreadyQueued.contains(queueKey)) continue;

        final targetBranch = _cleanBranch(data['branchId'] ?? branchId);

        await LocalStorageService.enqueueSync({
          'backlog': true, // backfill: uses the backlog share of the daily quota
          'type': 'save_attendance_record',
          'branchId': targetBranch,
          'date': dateStr,
          'employeeId': employeeId,
          'localKey': key,
          'data': data,
          'pendingSync': true,
          'forceUpload': true,
        });
        alreadyQueued.add(queueKey);
        queued++;
      }

      if (queued > 0) {
        Logger().d('[SyncService] 📥 Backfill: queued $queued unsynced attendance records for upload');
      }
    } catch (e) {
      Logger().d('[SyncService] _enqueueMissingAttendance error: $e');
    }
  }

  Future<void> _enqueueMissingPatients(String branchId, {bool force = false}) async {
    UiStallMonitor.mark('sync: _enqueueMissingPatients');
    try {
      // If connected to LAN server, server manages patients
      if (!LanServer.isRunning && !LanHostManager.isHostRunning && RealtimeManager().hasServerLink) {
        return;
      }

      if (!Hive.isBoxOpen(LocalStorageService.patientsBox)) {
        await LocalStorageService.openBoxSafe(LocalStorageService.patientsBox);
      }
      if (!Hive.isBoxOpen(LocalStorageService.syncBox)) {
        await LocalStorageService.openBoxSafe(LocalStorageService.syncBox);
      }
      final pBox = Hive.box(LocalStorageService.patientsBox);
      final syncBox = Hive.box(LocalStorageService.syncBox);
      final todayIso = DateFormat('yyyy-MM-dd').format(DateTime.now());

      final alreadyQueued = <String>{};
      for (final v in syncBox.values) {
        if (v is Map && v['type'] == 'save_patient') {
          final pid = (v['patientId'] ?? v['data']?['patientId'])?.toString();
          if (pid != null) alreadyQueued.add(pid);
        }
      }

      final flagsBox = Hive.isBoxOpen('app_flags') ? Hive.box('app_flags') : null;
      int queued = 0;
      int processedP = 0;
      for (final key in pBox.keys) {
        processedP++;
        if (processedP % 10 == 0) {
          await Future.delayed(const Duration(milliseconds: 2));
        }

        final raw = pBox.get(key);
        if (raw == null || raw is! Map) continue;
        final data = Map<String, dynamic>.from(raw);
        final pid = (data['patientId'] ?? data['id'] ?? key).toString().trim();
        if (pid.isEmpty || alreadyQueued.contains(pid)) continue;

        // Daily Data Rule: Only enqueue patients created today or with explicit pendingSync
        final rawCreated = (data['createdAt'] ?? data['created_at'] ?? '').toString();
        if (!rawCreated.startsWith(todayIso) && data['pendingSync'] != true) continue;

        final pCnic = (data['cnic'] ?? pid).toString().trim();
        final pName = (data['name'] ?? '').toString().trim().toLowerCase();
        if ((pCnic.startsWith('unknown_cnic_') || pCnic.isEmpty) && (pName.isEmpty || pName == 'unknown patient' || pName == 'unknown')) {
          continue;
        }

        final flagSynced = flagsBox?.get('patient_synced_$pid') == true;
        final isExplicitlySynced = (data['syncStatus'] == 'synced' || data['synced'] == true || flagSynced) && data['pendingSync'] != true;
        if (isExplicitlySynced) continue;

        final isPending = data['pendingSync'] == true ||
            (data['syncStatus'] != 'synced' && !flagSynced);
        if (!isPending) continue;

        final targetBranch = _cleanBranch(data['branchId'] ?? branchId);

        await LocalStorageService.enqueueSync({
          'backlog': true, // backfill: uses the backlog share of the daily quota
          'type': 'save_patient',
          'branchId': targetBranch,
          'patientId': pid,
          'data': data,
        });
        alreadyQueued.add(pid);
        queued++;
      }

      if (queued > 0) {
        Logger().d('[SyncService] 📥 Backfill: queued $queued unsynced patients for upload');
      }
    } catch (e) {
      Logger().d('[SyncService] _enqueueMissingPatients error: $e');
    }
  }

  Future<void> _enqueueMissingMadrassaStudents(String branchId) async {
    UiStallMonitor.mark('sync: _enqueueMissingMadrassaStudents');
    try {
      if (!Hive.isBoxOpen(LocalStorageService.madrassaStudentsBox)) {
        await LocalStorageService.openBoxSafe(LocalStorageService.madrassaStudentsBox);
      }
      if (!Hive.isBoxOpen(LocalStorageService.syncBox)) {
        await LocalStorageService.openBoxSafe(LocalStorageService.syncBox);
      }
      final sBox = Hive.box(LocalStorageService.madrassaStudentsBox);
      final syncBox = Hive.box(LocalStorageService.syncBox);

      final alreadyQueued = <String>{};
      for (final v in syncBox.values) {
        if (v is Map && (v['type'] == 'save_madrassa_student' || v['type'] == 'save_madrassa_admission')) {
          final sid = (v['studentId'] ?? v['data']?['id'] ?? v['data']?['studentId'])?.toString();
          if (sid != null) alreadyQueued.add(sid);
        }
      }

      int queued = 0;
      int processedS = 0;
      for (final key in sBox.keys) {
        processedS++;
        if (processedS % 25 == 0) {
          await Future.delayed(const Duration(milliseconds: 1));
        }

        final raw = sBox.get(key);
        if (raw == null || raw is! Map) continue;
        final data = Map<String, dynamic>.from(raw);
        final isSynced = (data['synced'] == true || data['syncStatus'] == 'synced') && data['pendingSync'] != true;
        if (isSynced) continue;

        final sid = (data['id'] ?? data['studentId'] ?? key).toString().trim();
        if (sid.isEmpty || alreadyQueued.contains(sid)) continue;
        if (sid.contains('config__current') || sid.contains('__config__')) continue;
        final name = (data['name'] ?? data['studentName'])?.toString().trim();
        if (name == null || name.isEmpty) continue;

        final targetBranch = _cleanBranch(data['branchId'] ?? branchId);

        await LocalStorageService.enqueueSync({
          'type': 'save_madrassa_student',
          'branchId': targetBranch,
          'studentId': sid,
          'entityId': sid,
          'data': data,
          'localBox': LocalStorageService.madrassaStudentsBox,
          'localKey': key,
        });
        alreadyQueued.add(sid);
        queued++;
      }

      if (queued > 0) {
        Logger().d('[SyncService] 📥 Backfill: queued $queued unsynced madrassa students for upload');
      }
    } catch (e) {
      Logger().d('[SyncService] _enqueueMissingMadrassaStudents error: $e');
    }
  }

  Future<void> _enqueueMissingMadrassaLogs(String branchId) async {
    UiStallMonitor.mark('sync: _enqueueMissingMadrassaLogs');
    try {
      if (!Hive.isBoxOpen(LocalStorageService.madrassaLogsBox)) {
        await LocalStorageService.openBoxSafe(LocalStorageService.madrassaLogsBox);
      }
      if (!Hive.isBoxOpen(LocalStorageService.syncBox)) {
        await LocalStorageService.openBoxSafe(LocalStorageService.syncBox);
      }
      final mBox = Hive.box(LocalStorageService.madrassaLogsBox);
      final syncBox = Hive.box(LocalStorageService.syncBox);

      final alreadyQueued = <String>{};
      for (final v in syncBox.values) {
        if (v is Map && (v['type'] == 'save_madrassa_log' || v['type'] == 'save_madrassa_daily_log')) {
          final lKey = (v['localKey'] ?? v['entityId'] ?? '${v['branchId']}__log__${v['dateKey']}')?.toString();
          if (lKey != null) alreadyQueued.add(lKey);
        }
      }

      int queued = 0;
      int processedL = 0;
      for (final key in mBox.keys.toList()) {
        processedL++;
        if (processedL % 25 == 0) {
          await Future.delayed(const Duration(milliseconds: 1));
        }

        final raw = mBox.get(key);
        if (raw == null || raw is! Map) continue;
        final isSynced = (raw['synced'] == true && raw['syncStatus'] == 'synced') && raw['pendingSync'] != true;

        // If any student log inside was edited AFTER lastSyncedAt, it needs sync
        final lastSyncedStr = raw['lastSyncedAt']?.toString();
        DateTime? lastSynced = lastSyncedStr != null ? DateTime.tryParse(lastSyncedStr) : null;
        bool hasRecentEdits = false;
        if (lastSynced != null) {
          for (final entry in raw.values) {
            if (entry is Map && entry['lastEditedAt'] != null) {
              final editTime = DateTime.tryParse(entry['lastEditedAt'].toString());
              if (editTime != null && editTime.isAfter(lastSynced)) {
                hasRecentEdits = true;
                break;
              }
            }
          }
        }
        if (isSynced && !hasRecentEdits) continue;

        final keyStr = key.toString();
        if (alreadyQueued.contains(keyStr)) continue;

        // The logs box also holds teacher attendance ('…__madrassa_tchlog__date') and
        // ZKTeco records ('studentId_date'); those were uploaded as junk daily-log docs
        // ('-madrassa-tchlog', 'std-…'). Only day logs: 'b__log__date' or legacy 'b_yyyy_MM_dd'.
        String bId = branchId;
        String dateKey;
        if (keyStr.contains('__log__')) {
          final parts = keyStr.split('__log__');
          bId = _cleanBranch(parts[0]);
          dateKey = parts.length > 1 ? parts[1] : keyStr;
        } else {
          final parts = keyStr.split('_');
          final isLegacyDayKey = !keyStr.contains('__') && parts.length == 4 &&
              RegExp(r'^\d{4}$').hasMatch(parts[1]) &&
              RegExp(r'^\d{2}$').hasMatch(parts[2]) &&
              RegExp(r'^\d{2}$').hasMatch(parts[3]);
          if (!isLegacyDayKey) continue;
          bId = _cleanBranch(parts.first);
          dateKey = '${parts[1]}-${parts[2]}-${parts[3]}';
        }

        await LocalStorageService.enqueueSync({
          'type': 'save_madrassa_daily_log',
          'entityId': 'mlog_${bId}_$dateKey',
          'branchId': bId,
          'dateKey': dateKey,
          'data': Map<String, dynamic>.from(raw)
            ..remove('syncStatus')
            ..remove('pendingSync')
            ..remove('synced')
            ..remove('lastSyncedAt'),
          'localBox': LocalStorageService.madrassaLogsBox,
          'localKey': keyStr,
        });
        alreadyQueued.add(keyStr);
        queued++;
      }

      if (queued > 0) {
        Logger().d('[SyncService] 📥 Backfill: queued $queued unsynced madrassa logs for upload');
      }
    } catch (e) {
      Logger().d('[SyncService] _enqueueMissingMadrassaLogs error: $e');
    }
  }

  Future<void> _enqueueMissingSchoolData(String branchId) async {
    UiStallMonitor.mark('sync: _enqueueMissingSchoolData');
    try {
      final syncBox = Hive.isBoxOpen(LocalStorageService.syncBox)
          ? Hive.box(LocalStorageService.syncBox)
          : await LocalStorageService.openBoxSafe(LocalStorageService.syncBox);

      final alreadyQueued = <String>{};
      for (final v in syncBox.values) {
        if (v is Map) {
          final docId = v['docId']?.toString() ?? v['entityId']?.toString() ?? v['id']?.toString();
          final coll = v['collection']?.toString() ?? '';
          if (docId != null && coll.isNotEmpty) {
            alreadyQueued.add('$coll/$docId');
          }
        }
      }

      int queued = 0;

      // 1. School Students
      if (!Hive.isBoxOpen(LocalStorageService.schoolStudentsBox)) {
        await LocalStorageService.openBoxSafe(LocalStorageService.schoolStudentsBox);
      }
      final sBox = Hive.box(LocalStorageService.schoolStudentsBox);
      for (final key in sBox.keys) {
        final raw = sBox.get(key);
        if (raw is! Map) continue;
        final data = Map<String, dynamic>.from(raw);
        final rb = _cleanBranch(data['branchId'] ?? branchId); // the record's own branch
        final isSynced = (data['syncStatus'] == 'synced' || data['synced'] == true) && data['pendingSync'] != true;
        if (isSynced) continue;

        final sid = (data['id'] ?? data['studentId'] ?? key.toString().split('__std__').last).toString().trim();
        final coll = 'branches/$rb/school_students';
        if (sid.isEmpty || alreadyQueued.contains('$coll/$sid')) continue;

        await LocalStorageService.enqueueSync({
          'backlog': true, // backfill: uses the backlog share of the daily quota
          'action': 'set',
          'type': 'save_school_student',
          'branchId': rb,
          'collection': coll,
          'docId': sid,
          'data': data,
        });
        alreadyQueued.add('$coll/$sid');
        queued++;
      }

      // 2. School Teachers
      if (!Hive.isBoxOpen(LocalStorageService.schoolTeachersBox)) {
        await LocalStorageService.openBoxSafe(LocalStorageService.schoolTeachersBox);
      }
      final tBox = Hive.box(LocalStorageService.schoolTeachersBox);
      for (final key in tBox.keys) {
        final raw = tBox.get(key);
        if (raw is! Map) continue;
        final data = Map<String, dynamic>.from(raw);
        final rb = _cleanBranch(data['branchId'] ?? branchId); // the record's own branch
        final isSynced = (data['syncStatus'] == 'synced' || data['synced'] == true) && data['pendingSync'] != true;
        if (isSynced) continue;

        final tid = (data['id'] ?? data['teacherId'] ?? key.toString().split('__tch__').last).toString().trim();
        final coll = 'branches/$rb/school_teachers';
        if (tid.isEmpty || alreadyQueued.contains('$coll/$tid')) continue;

        await LocalStorageService.enqueueSync({
          'backlog': true, // backfill: uses the backlog share of the daily quota
          'action': 'set',
          'type': 'save_school_teacher',
          'branchId': rb,
          'collection': coll,
          'docId': tid,
          'data': data,
        });
        alreadyQueued.add('$coll/$tid');
        queued++;
      }

      // 3. Attendance Logs (Student & Teacher)
      if (!Hive.isBoxOpen(LocalStorageService.schoolLogsBox)) {
        await LocalStorageService.openBoxSafe(LocalStorageService.schoolLogsBox);
      }
      final lBox = Hive.box(LocalStorageService.schoolLogsBox);
      for (final key in lBox.keys) {
        final raw = lBox.get(key);
        if (raw is! Map) continue;
        final data = Map<String, dynamic>.from(raw);
        final rb = _cleanBranch(data['branchId'] ?? branchId); // the record's own branch
        final isSynced = (data['syncStatus'] == 'synced' || data['synced'] == true) && data['pendingSync'] != true;
        if (isSynced) continue;

        final keyStr = key.toString();
        final isTeacher = keyStr.contains('__tchlog__');
        final dateKey = (data['date'] ?? (isTeacher ? keyStr.split('__tchlog__').last : keyStr.split('__log__').last)).toString().trim();
        final coll = isTeacher
            ? 'branches/$rb/school_teacher_attendance'
            : 'branches/$rb/school_attendance';
        if (dateKey.isEmpty || alreadyQueued.contains('$coll/$dateKey')) continue;

        await LocalStorageService.enqueueSync({
          'backlog': true, // backfill: uses the backlog share of the daily quota
          'action': 'set',
          'type': isTeacher ? 'save_school_teacher_attendance' : 'save_school_attendance',
          'branchId': rb,
          'collection': coll,
          'docId': dateKey,
          'data': data,
        });
        alreadyQueued.add('$coll/$dateKey');
        queued++;
      }

      // 4. Grades
      if (!Hive.isBoxOpen(LocalStorageService.schoolGradesBox)) {
        await LocalStorageService.openBoxSafe(LocalStorageService.schoolGradesBox);
      }
      final gBox = Hive.box(LocalStorageService.schoolGradesBox);
      for (final key in gBox.keys) {
        final raw = gBox.get(key);
        if (raw is! Map) continue;
        final data = Map<String, dynamic>.from(raw);
        final rb = _cleanBranch(data['branchId'] ?? branchId); // the record's own branch
        final isSynced = (data['syncStatus'] == 'synced' || data['synced'] == true) && data['pendingSync'] != true;
        if (isSynced) continue;

        final gid = (data['id'] ?? key.toString().split('__').last).toString().trim();
        final coll = 'branches/$rb/school_grades';
        if (gid.isEmpty || alreadyQueued.contains('$coll/$gid')) continue;

        await LocalStorageService.enqueueSync({
          'backlog': true, // backfill: uses the backlog share of the daily quota
          'action': 'set',
          'type': 'save_school_grade',
          'branchId': rb,
          'collection': coll,
          'docId': gid,
          'data': data,
        });
        alreadyQueued.add('$coll/$gid');
        queued++;
      }

      // 5. Fees
      if (!Hive.isBoxOpen(LocalStorageService.schoolFeesBox)) {
        await LocalStorageService.openBoxSafe(LocalStorageService.schoolFeesBox);
      }
      final fBox = Hive.box(LocalStorageService.schoolFeesBox);
      for (final key in fBox.keys) {
        final raw = fBox.get(key);
        if (raw is! Map) continue;
        final data = Map<String, dynamic>.from(raw);
        final rb = _cleanBranch(data['branchId'] ?? branchId); // the record's own branch
        final isSynced = (data['syncStatus'] == 'synced' || data['synced'] == true) && data['pendingSync'] != true;
        if (isSynced) continue;

        final fid = (data['id'] ?? key.toString().split('__').last).toString().trim();
        final coll = 'branches/$rb/school_fees';
        if (fid.isEmpty || alreadyQueued.contains('$coll/$fid')) continue;

        await LocalStorageService.enqueueSync({
          'backlog': true, // backfill: uses the backlog share of the daily quota
          'action': 'set',
          'type': 'save_school_fee',
          'branchId': rb,
          'collection': coll,
          'docId': fid,
          'data': data,
        });
        alreadyQueued.add('$coll/$fid');
        queued++;
      }

      if (queued > 0) {
        Logger().d('[SyncService] 📥 Backfill: queued $queued unsynced school records for upload');
      }
    } catch (e) {
      Logger().d('[SyncService] _enqueueMissingSchoolData error: $e');
    }
  }

  void _setupDailyTokenRefresh(String branchId) {
    final now          = DateTime.now();
    final nextMidnight = DateTime(now.year, now.month, now.day + 1, 0, 5);
    var duration       = nextMidnight.difference(now);
    if (duration.isNegative) duration += const Duration(days: 1);

    _dailyTokenTimer?.cancel();
    _dailyTokenTimer = Timer(duration, () async {
      await LocalStorageService.downloadTodayTokens(branchId);
      _setupDailyTokenRefresh(branchId);
    });
  }

  /// Unit tests that enqueue sync actions set this so no real Firestore upload is
  /// attempted (there is no Firebase app in a test isolate).
  @visibleForTesting
  static bool suppressUploadsForTests = false;

  Future<void> triggerUpload({bool force = false, bool urgent = false}) async {
    if (suppressUploadsForTests) return;
    // Runs once per app session, whichever screen started the sync (the server screen
    // does not go through SyncService.start). Read-only except for one tiny probe doc.
    unawaited(_probeFirebaseHealth());
    if (_currentBranchId == null || !LocalStorageService.isValidBranchId(_currentBranchId)) {
      final activeBranch = LocalStorageService.getActiveUserBranchId();
      if (LocalStorageService.isValidBranchId(activeBranch)) {
        _currentBranchId = _cleanBranch(activeBranch);
      } else if (Hive.isBoxOpen('app_settings')) {
        final box = Hive.box('app_settings');
        final cb = box.get('current_branch_id')?.toString();
        if (LocalStorageService.isValidBranchId(cb)) {
          _currentBranchId = _cleanBranch(cb);
        }
      }
      _currentBranchId ??= 'karachi';
    }

    final bool hasPendingItems = Hive.isBoxOpen(LocalStorageService.syncBox) &&
        Hive.box(LocalStorageService.syncBox).isNotEmpty;

    // Quota guard: only skip if daily quota is exhausted AND there are no pending items waiting to upload
    if (force) {
      QuotaService.resetState();
    } else if (QuotaService.isQuotaExhausted && !hasPendingItems) {
      Logger().d('[SyncService] ⛔ Quota exhausted and no pending items — upload skipped');
      return;
    }

    bool isOnline = true;
    try {
      if (!kIsWeb && (Platform.isAndroid || Platform.isIOS)) {
        final connectivity = await Connectivity().checkConnectivity();
        isOnline = connectivity.any((r) => r != ConnectivityResult.none);
      } else if (!kIsWeb && (Platform.isWindows || Platform.isLinux || Platform.isMacOS)) {
        isOnline = force || (!NetworkHealthService().isOffline && NetworkHealthService().isStableOnline);
      } else if (NetworkHealthService().isOffline) {
        isOnline = false;
      }
    } catch (_) {
      isOnline = false;
    }

    // Firestore stopped answering recently: give it a few minutes instead of re-trying every 15 s.
    final stalled = _stalledUntil;
    if (!force && stalled != null && DateTime.now().isBefore(stalled)) return;

    // _uploadStartedAt is refreshed per item, so this only fires when a pass made no progress
    // for 90 s. (It used to fire 25 s after a pass *started*, and forced syncs reset it outright,
    // so two passes ran at once and uploaded the same items twice.)
    if (_isUploading && _uploadStartedAt != null && DateTime.now().difference(_uploadStartedAt!).inSeconds > _hungPassSeconds) {
      debugPrint('[SyncService] ⚠️ Resetting hung _isUploading watchdog after ${_hungPassSeconds}s without progress');
      _isUploading = false;
    }

    if (isOnline || force) {
      // Dual Sync Rule:
      // If local LAN server is running on this machine, ServerSyncManager handles the scheduled cloud sync passes.
      // If this is a client station connected to the LAN server:
      //  - Dispensary client stations must NOT upload dispensary data directly to Firestore (LAN server handles it).
      //  - Client dispensary queue items are purged to prevent bloat.
      //  - Standalone items (Madrassa, Donations, School, Dasterkhwaan) still upload to Firestore.
      final bool isLocalServer = LanServer.isRunning || LanHostManager.isHostRunning;
      final bool isServerConnected = RealtimeManager().hasServerLink;
      final bool isClientOnLan = !isLocalServer && isServerConnected;

      if (isClientOnLan) {
        // Dispensary client stations must not upload dispensary entries to Firestore
        await LocalStorageService.purgeClientDispensaryQueue();

        if (_currentUserRole == null) {
          try {
            final userData = await OfflineAuthService.getCachedUserData();
            if (userData != null) {
              _currentUserRole = userData['role'] as String?;
            }
          } catch (_) {}
        }

        final currentRole = _currentUserRole;
        final isDispensary = LocalStorageService.isDispensaryRole(currentRole);

        // If this station is exclusively dispensary, defer entirely to LAN server
        if (isDispensary) {
          debugPrint('[SyncService] 🏥 Dispensary client station connected to LAN Server. Upload deferred to server.');
          return;
        }

        // If other role, check if any pending standalone items remain
        final hasLocalPending = Hive.isBoxOpen(LocalStorageService.syncBox) &&
            Hive.box(LocalStorageService.syncBox).isNotEmpty;
        if (!hasLocalPending) {
          Logger().d("SyncService: LAN server is connected and active. No standalone items queued. Sync deferred.");
          return;
        }
      }

      // Mutual exclusion coordinator: Prevent clashing with ServerSyncManager on the same server node
      if (!ServerSyncCoordinator.canStartSync(isServer: false, force: force)) {
        debugPrint('[SyncService] ⏸️ ServerSyncManager is currently syncing. Deferring SyncService pass to prevent clash.');
        return;
      }

      if (_currentUserRole == null) {
        try {
          final userData = await OfflineAuthService.getCachedUserData();
          if (userData != null) {
            _currentUserRole = userData['role'] as String?;
          }
        } catch (_) {}
      }

      // Firestore rules need a signed-in session; without one every upload is rejected.
      // Skipped quietly when Firebase never initialised (tests, a failed start).
      if (!kIsWeb && Firebase.apps.isNotEmpty) {
        try {
          if (FirebaseAuth.instance.currentUser == null) {
            await FirebaseSessionGuard.ensureSession(reason: 'upload');
          }
        } catch (e) {
          debugPrint('[SyncService] session check skipped: $e');
        }
      }

      await _uploadPending(force: force, urgent: urgent);

      if (!Hive.isBoxOpen(LocalStorageService.syncBox)) return;
      final remainingQueue = Hive.box(LocalStorageService.syncBox).length;
      if (remainingQueue == 0) {
        try {
          final branchesToSync = <String>{};
          final activeB = (_currentBranchId ?? '').toLowerCase().trim();
          if (activeB.isNotEmpty && activeB != 'all' && activeB != 'global') {
            branchesToSync.add(activeB);
          } else if (_authorizedBranches.isNotEmpty) {
            branchesToSync.addAll(_authorizedBranches);
          }

          if (!Hive.isBoxOpen('app_settings')) return;
          final settings = Hive.box('app_settings');
          for (final bId in branchesToSync) {
            final now = DateTime.now();
            // Cooldown raised to 2 hours to match historical periodic timer
            // and prevent redundant full/delta scans on rapid connectivity events.
            if (force) {
              await settings.put('last_refresh_$bId', now.toIso8601String());
              await _refreshDataForBranch(bId);
              await Future.delayed(const Duration(milliseconds: 50));
            } else {
              Logger().d("[SyncService] Automatic post-upload refresh skipped (zero-read architecture)");
            }
          }
        } catch (e) {
          Logger().d("Refresh after upload failed: $e");
        }
      }
    }
  }

  Future<void> _refreshDataForBranch(String branchId) async {
    try {
      // Each download runs only where this PC's role uses its box (LocalStorageService
      // .roleUsesBox): elsewhere the box is closed, and opening it would load a module this PC
      // never shows.
      const uses = LocalStorageService.roleUsesBox;
      await LocalStorageService.downloadUsers(branchId);
      if (uses(LocalStorageService.entriesBox)) await LocalStorageService.downloadTodayTokens(branchId);
      if (uses(LocalStorageService.stockBox)) await LocalStorageService.downloadInventory(branchId);
      if (uses(LocalStorageService.prescriptionsBox)) await LocalStorageService.refreshPrescriptions(branchId);
      if (uses(LocalStorageService.medicineRestrictionsBox)) await LocalStorageService.downloadMedicineRestrictions(branchId);
      // [FIX-4.1] Periodic attendance download (participates in FinanceLocalStorage internal TTL guard)
      if (uses(LocalStorageService.attendanceBox)) await FinanceLocalStorage.downloadAttendance(branchId);

      final role = _currentUserRole?.toLowerCase().trim();

      // Only download donations if the user has donations permission or is office boy / executive
      final isExec = role == null || role.contains('admin') || role.contains('hq manager') || role.contains('hqmanager') || role.contains('ceo') || role.contains('supervisor');
      final isDonationRole = role != null && (role.contains('donation') || role.contains('collector') || role.contains('office boy') || role.contains('officeboy'));
      final hasDonationsPerm = isExec || isDonationRole ||
          (_currentUserRole != null && (PermissionService().hasPermission(_currentUserRole!, AppPermission.viewDonations) ||
          PermissionService().hasPermission(_currentUserRole!, AppPermission.manageDonations)));
      if (hasDonationsPerm && uses(LocalStorageService.donationsBox)) {
        await DonationsLocalStorage.downloadAllDonations(branchId);
        await DonationsLocalStorage.downloadDonors(branchId);
        await DonationBoxStorage.downloadBoxes(branchId);
      }

      // Download Dasterkhwaan tokens for branch
      if (uses(LocalStorageService.dasterkhwaanTokensBox)) await LocalStorageService.downloadDasterkhwaanTokens(branchId);

      // Download Madrassa data if the user has madrassa permissions or is a madrassa user / executive
      final isMadrassaRole = isExec || role.contains('madrassa') || role.contains('qari') || role.contains('nazim') || role.contains('teacher');
      final hasMadrassaPerm = isMadrassaRole ||
          (_currentUserRole != null && (PermissionService().hasPermission(_currentUserRole!, AppPermission.manageMadrassa) ||
          PermissionService().hasPermission(_currentUserRole!, AppPermission.manageMadrassaAdmin)));
      if (hasMadrassaPerm && uses(LocalStorageService.madrassaStudentsBox)) {
        await MadrassaLocalStorage.downloadAllMadrassaData(branchId);
      }

      // Download School data if the user has school permissions or is a school user / executive
      final isSchoolRole = isExec || role.contains('school') || role.contains('teacher') || role.contains('principal');
      if (isSchoolRole && uses(LocalStorageService.schoolStudentsBox)) {
        await SchoolSyncService().fetchRemoteSchoolData(branchId);
      }

      // Finance bulk downloads (heavy collectionGroup scans) are intentionally
      // excluded from the periodic sync cycle. Call triggerFinanceRefresh()
      // explicitly when the Finance page is opened.
    } catch (e) {
      Logger().d("[SyncService] Error refreshing branch $branchId: $e");
    }
  }

  /// Call this when the Finance module is opened by the user.
  /// Respects the same TTL guards as FinanceLocalStorage so it won't hammer
  /// Firestore if the page is opened multiple times within the cooldown window.
  Future<void> triggerFinanceRefresh({bool force = false}) async {
    final branchId = _currentBranchId;
    if (branchId == null) return;

    final role = _currentUserRole;
    final hasFinancePerm = role == null ||
        PermissionService().hasPermission(role, AppPermission.manageFinance);
    if (!hasFinancePerm) return;

    Logger().d('[SyncService] triggerFinanceRefresh for $branchId (force=$force)');
    try {
      await FinanceLocalStorage.downloadEmployees(branchId);
      await FinanceLocalStorage.downloadSalaryHistory(branchId, force: force);
      await FinanceLocalStorage.downloadAttendance(branchId, force: force);
      await FinanceLocalStorage.downloadSalaryLedger(branchId);
      await FinanceLocalStorage.downloadFinanceSettings(branchId);
      await FinanceLocalStorage.downloadTransfers(branchId, force: force);
      await FinanceLocalStorage.downloadAuditLogs(branchId, force: force);
      await FinanceLocalStorage.downloadFinanceHolidays(branchId);
      await FinanceLocalStorage.downloadLoans(branchId);
      await FinanceExpensesStorage.downloadExpenses(branchId, force: force);
    } catch (e) {
      Logger().d('[SyncService] triggerFinanceRefresh error: $e');
    }
  }

  /// Moves dead-lettered uploads back into the queue. Forced syncs revive everything; the
  /// automatic revival (every 2 h) brings them back as backlog, so items that failed during
  /// an outage or a quota-exhausted day are retried instead of sitting there forever.
  DateTime? _lastDlqRevivalAt;
  Future<void> _reviveDeadLetterQueue({bool asBacklog = false, bool force = false}) async {
    try {
      final now = DateTime.now();
      // Throttle revival to at most once per 2 hours unless forced
      if (!force && _lastDlqRevivalAt != null && now.difference(_lastDlqRevivalAt!) < const Duration(hours: 2)) {
        return;
      }
      _lastDlqRevivalAt = now;

      final dlBoxName = LocalStorageService.deadLetterQueueBox;
      if (!Hive.isBoxOpen(dlBoxName)) await LocalStorageService.openBoxSafe(dlBoxName);
      if (Hive.isBoxOpen(dlBoxName)) {
        final dlBox = Hive.box(dlBoxName);
        if (dlBox.isNotEmpty && Hive.isBoxOpen(LocalStorageService.syncBox)) {
          final sBox = Hive.box(LocalStorageService.syncBox);
          final keys = List.from(dlBox.keys);
          final todayKey = DateFormat('yyyy-MM-dd').format(now);
          final bool isLocalServer = LanServer.isRunning || LanHostManager.isHostRunning;
          final bool isServerConnected = RealtimeManager().hasServerLink;
          final bool isClientOnLan = !isLocalServer && isServerConnected;

          int revivedCount = 0;
          for (final k in keys) {
            final val = dlBox.get(k);
            if (val is! Map) {
              await dlBox.delete(k);
              continue;
            }

            final type = (val['type'] ?? '').toString();
            final isDispensary = LocalStorageService.isDispensaryActionType(type);
            final dateKey = (val['dateKey'] ?? val['datePart'] ?? (val['data'] is Map ? val['data']['dateKey'] : null))?.toString();

            // Client dispensary actions on LAN belong to the LAN server; purge permanently from client DLQ
            if (isDispensary && isClientOnLan) {
              await dlBox.delete(k);
              continue;
            }


            final reason = (val['reason'] ?? val['lastError'] ?? '').toString();
            final isParked = val['parked'] == true;
            // Items whose reason starts "PURGED:" or that are parked are skipped by automatic revival
            if (!force && (isParked || reason.startsWith('PURGED:'))) {
              continue;
            }

            final revived = (val['autoRevivals'] as int?) ?? 0;
            // Never revive poison pill items more than 3 times: park instead of deleting
            if (revived >= 3 && !force) {
              if (val['parked'] != true) {
                final parkedItem = Map<String, dynamic>.from(val);
                parkedItem['parked'] = true;
                await dlBox.put(k, parkedItem);
              }
              continue;
            }

            if (!sBox.containsKey(k)) {
              final action = Map<String, dynamic>.from(val);
              action['autoRevivals'] = revived + 1;
              action['attempts'] = 0;
              action.remove('nextRetryAt');
              action.remove('lastError');
              if (asBacklog) action['backlog'] = true;
              await sBox.put(k, action);
              revivedCount++;
            }
            await dlBox.delete(k);
          }
          if (revivedCount > 0) {
            debugPrint('[SyncService] 🔄 Revived $revivedCount items from DeadLetterQueue to syncBox');
          }
        }
      }
    } catch (e) {
      debugPrint('[SyncService] Dead letter revival notice: $e');
    }
  }

  Future<void> _uploadPending({bool force = false, bool urgent = false}) async {
    // Each item opens the boxes it writes to first (ensureBoxesForSyncType below): this PC
    // keeps only its role's boxes open.
    if (!Hive.isBoxOpen(LocalStorageService.syncBox)) return;
    if (!ServerSyncCoordinator.canStartSync(isServer: false, force: force)) {
      debugPrint('[SyncService] ⏸️ ServerSyncManager is actively syncing. Yielding _uploadPending pass.');
      return;
    }
    if (_isUploading) {
      if (_uploadStartedAt != null && DateTime.now().difference(_uploadStartedAt!).inSeconds > _hungPassSeconds) {
        debugPrint('[SyncService] ⚠️ Resetting hung _isUploading watchdog after ${_hungPassSeconds}s in _uploadPending');
        _isUploading = false;
      } else {
        // Never run two passes at once (they upload the same items twice). A forced sync
        // asked for mid-pass runs right after the current pass.
        if (force) {
          _forceRequested = true;
        } else if (urgent) {
          _urgentRequested = true;
        }
        return;
      }
    }
    _isUploading = true;
    final myUploadGen = ++_uploadGen;
    UiStallMonitor.mark('sync: upload pass');
    _uploadStartedAt = DateTime.now();
    ServerSyncCoordinator.markStarted(isServer: false);
    BusyTask? uploadStatus;

    try {
      try {
        await _reviveDeadLetterQueue(force: force);
      } catch (e) {
        debugPrint('[SyncService] _reviveDeadLetterQueue warning: $e');
      }
      if (force) {
        try {
          await QueueSelfHealingService().healEntireQueue(fallbackBranchId: _currentBranchId);
          // A forced pass sends held stock changes too; add them up first so they go out as
          // one write per medicine.
          await HourlyDispensarySync.foldNow();
        } catch (e) {
          debugPrint('[SyncService] healEntireQueue warning: $e');
        }
      }
      final queueBox = Hive.box(LocalStorageService.syncBox);
      if (queueBox.isEmpty) return;

      // Only clear quota pause if explicitly forced by user action
      if (force) {
        QuotaService.clearDailyResetPause();
      }

      // If cloud writes are paused due to daily quota exhaustion, stop here stably
      if (QuotaService.isPausedForDailyReset && !force) return;

      // The bulk "force" uploader is manual only (Ctrl+Shift+U / Settings). Started from here
      // whenever 15+ items were queued (v1.6.2), it reset the quota pause and ran a forced
      // whole-database sweep; while Firestore refused writes the queue never shrank, so every
      // PC re-ran that sweep every few seconds and its UI froze.

      if (queueBox.length >= 8) {
        uploadStatus = BusyStatus.begin('Syncing offline data (${queueBox.length} items queued)', background: true);
      }
      final passStarted = DateTime.now();
      final writesBefore = QuotaService.dailyWriteCount;
      final skippedBefore = CloudDb.skippedUnchanged;

      // Track attendance headers updated during this pass to avoid writing parent doc 50x per batch
      final updatedAttendanceHeaders = <String>{};

      // Minimum-Version Fleet Lock Check (with strict 3-second timeout). At most every
      // 6 h: it ran on every 15-second pass, costing a Firestore read each time.
      final lastVersionCheck = _lastVersionCheckAt;
      if (lastVersionCheck == null || DateTime.now().difference(lastVersionCheck) > const Duration(hours: 6)) {
        _lastVersionCheckAt = DateTime.now();
        try {
          final versionDoc = await _db
              .collection('app_config')
              .doc('version')
              .get()
              .timeout(const Duration(seconds: 3));
          if (versionDoc.exists) {
            final minVersion = versionDoc.data()?['min_supported_version']?.toString();
            if (minVersion != null && AutoUpdateService.compareVersions(AutoUpdateService.currentVersion, minVersion) < 0) {
              debugPrint('[SyncService] ⚠️ App version (${AutoUpdateService.currentVersion}) is below minimum supported version ($minVersion). Sync continuing in compatibility mode.');
            }
          }
        } catch (e) {
          debugPrint('[SyncService] Version check notice: $e');
        }
      }

      // Fast purge bloated duplicates before processing
      if (force || queueBox.length > 20) {
        _lastSyncPurgeAt = DateTime.now();
        await LocalStorageService.purgeBloatedSyncQueue();
      }

      // Gateway rule & daily data configuration
      final bool isLocalServer = LanServer.isRunning || LanHostManager.isHostRunning;
      final bool isServerConnected = RealtimeManager().hasServerLink;
      final bool isClientOnLan = !isLocalServer && isServerConnected;
      final String todayKey = DateFormat('yyyy-MM-dd').format(DateTime.now());

      // Process in batches until queue is drained or max 80 batches (8,000 items)
      int batchesRun = 0;
      var consecutiveNetworkFailures = 0;
      var uploadedThisPass = 0;
      var backlogDeferred = 0;
      var quotaStop = false;
      // Keys already tried, or found waiting out a backoff, in this pass. Each batch used to take
      // the first 120 keys in key order again; items that kept failing stayed at the front, so
      // everything behind them (e.g. a teacher's new students) never got a turn, forced or not.
      final seenThisPass = <dynamic>{};
      while (queueBox.isNotEmpty && batchesRun < 80 && !quotaStop) {
        batchesRun++;
        ServerSyncCoordinator.touch();
        if (uploadStatus != null && queueBox.isNotEmpty) {
          uploadStatus.update('Syncing offline data (${queueBox.length} remaining)');
        }

        // Take only up to 120 candidate keys to avoid loading & sorting thousands of keys in memory
        // Stock changes waiting for the hourly run (HourlyDispensarySync) are skipped here;
        // counted in the 120 they would fill the window and stop everything behind them.
        final candidateKeys = <dynamic>[];
        for (final k in queueBox.keys) {
          if (candidateKeys.length >= 120) break;
          if (seenThisPass.contains(k)) continue;
          if (!force && HourlyDispensarySync.isHeld(queueBox.get(k))) continue;
          candidateKeys.add(k);
        }
        if (candidateKeys.isEmpty) break;

        // Cache candidate action data in memory to avoid repeated Hive disk reads during sorting/partitioning
        final candidateData = <dynamic, Map<String, dynamic>>{};
        final rawLiveKeys = <dynamic>[], rawBacklogKeys = <dynamic>[];

        for (final k in candidateKeys) {
          final v = queueBox.get(k);
          if (v is! Map) {
            await queueBox.delete(k);
            continue;
          }
          final map = Map<String, dynamic>.from(v);
          final type = (map['type'] ?? '').toString();
          final isDispensary = LocalStorageService.isDispensaryActionType(type);
          final dateKey = (map['dateKey'] ?? map['datePart'] ?? (map['data'] is Map ? map['data']['dateKey'] : null))?.toString();

          // Gate 1: Client dispensary actions on LAN belong to LAN Server, drop from client sync queue
          if (isDispensary && isClientOnLan) {
            await queueBox.delete(k);
            continue;
          }

          // Gate 1b: other items whose cloud write a LAN desk may not make (patients, inventory,
          // medicines, templates: CloudDb refuses them while the LAN server link is up). They
          // are kept, since they may not have reached the server, but set aside instead of
          // being prepared and refused again on every pass (Haji Camp: 567 such items, each
          // pass froze the desk for 8–28 s before giving up).
          if (isClientOnLan && (_lanServerOwnsType(type) || _isLanDeferred(k))) {
            _lanDeferredUntil[k] ??= DateTime.now().add(_lanDeferral);
            seenThisPass.add(k);
            continue;
          }


          candidateData[k] = map;
          if (_isBacklogItem(map)) {
            rawBacklogKeys.add(k);
          } else {
            rawLiveKeys.add(k);
          }
        }

        if (candidateData.isEmpty) {
          continue;
        }

        // Select ready keys (not in backoff window, unless forced)
        DateTime? earliestBackoff;
        bool isKeyReady(dynamic k) {
          final raw = candidateData[k];
          if (raw == null) return false;
          final nextRetryAtStr = raw['nextRetryAt'] as String?;
          final coalesceUntil = (force || urgent || queueBox.length > 5) ? null : _coalesceUntil(raw);
          if (coalesceUntil != null) {
            if (earliestBackoff == null || coalesceUntil.isBefore(earliestBackoff!)) {
              earliestBackoff = coalesceUntil;
            }
            return false;
          } else if (force || nextRetryAtStr == null) {
            return true;
          } else {
            final nextRetry = DateTime.tryParse(nextRetryAtStr);
            // Only bypass future nextRetryAt if clock skew pushed it > 48 hours ahead.
            if (nextRetry == null ||
                !DateTime.now().isBefore(nextRetry) ||
                nextRetry.difference(DateTime.now()) > const Duration(hours: 48)) {
              return true;
            } else {
              if (earliestBackoff == null || nextRetry.isBefore(earliestBackoff!)) {
                earliestBackoff = nextRetry;
              }
              return false;
            }
          }
        }

        final readyLiveKeys = <dynamic>[];
        for (final k in rawLiveKeys) {
          if (isKeyReady(k)) readyLiveKeys.add(k);
        }

        final readyBacklogKeys = <dynamic>[];
        final canRunBacklog = force || (QuotaService.backlogBudgetAvailable && !QuotaService.isPausedForDailyReset);
        if (canRunBacklog) {
          for (final k in rawBacklogKeys) {
            if (isKeyReady(k)) readyBacklogKeys.add(k);
          }
        }

        // Dependency Promotion: If a live action references a patient, token, or student that is pending in backlog,
        // promote that backlog action to the Express Lane so parents are never uploaded after children!
        final livePatientIds = <String>{};
        final liveSerials = <String>{};
        final liveStudentIds = <String>{};
        for (final k in readyLiveKeys) {
          final raw = candidateData[k];
          if (raw != null) {
            final pid = (raw['patientId'] ?? (raw['data'] is Map ? raw['data']['patientId'] : null) ?? raw['id'])?.toString().trim();
            if (pid != null && pid.isNotEmpty) livePatientIds.add(pid);
            final s = (raw['serial'] ?? (raw['data'] is Map ? raw['data']['serial'] : null))?.toString().trim();
            if (s != null && s.isNotEmpty) liveSerials.add(s);
            final sid = (raw['studentId'] ?? (raw['data'] is Map ? (raw['data']['studentId'] ?? raw['data']['id']) : null) ?? raw['id'])?.toString().trim();
            if (sid != null && sid.isNotEmpty) liveStudentIds.add(sid);
          }
        }

        final promotedFromBacklog = <dynamic>{};
        if (livePatientIds.isNotEmpty || liveSerials.isNotEmpty || liveStudentIds.isNotEmpty) {
          final promoted = <dynamic>[];
          for (final bk in rawBacklogKeys) {
            final raw = candidateData[bk];
            if (raw != null) {
              final type = (raw['type'] ?? '').toString();
              if (type == 'save_patient') {
                final pid = (raw['patientId'] ?? (raw['data'] is Map ? raw['data']['patientId'] : null) ?? raw['id'])?.toString().trim();
                if (pid != null && livePatientIds.contains(pid)) promoted.add(bk);
              } else if (type == 'save_entry') {
                final s = (raw['serial'] ?? (raw['data'] is Map ? raw['data']['serial'] : null))?.toString().trim();
                if (s != null && liveSerials.contains(s)) promoted.add(bk);
              } else if (type == 'save_madrassa_student' || type == 'save_school_student') {
                final sid = (raw['studentId'] ?? (raw['data'] is Map ? (raw['data']['studentId'] ?? raw['data']['id']) : null) ?? raw['id'])?.toString().trim();
                if (sid != null && liveStudentIds.contains(sid)) promoted.add(bk);
              }
            }
          }
          for (final pk in promoted) {
            readyBacklogKeys.remove(pk);
            if (!readyLiveKeys.contains(pk)) readyLiveKeys.add(pk);
            promotedFromBacklog.add(pk);
          }
        }

        // Sort both lanes in memory with Causal Precedence and FIFO timestamps (no Hive disk reads)
        readyLiveKeys.sort((a, b) {
          final rawA = candidateData[a];
          final rawB = candidateData[b];
          if (rawA != null && rawB != null) {
            return _compareSyncActions(rawA, rawB);
          }
          return 0;
        });

        readyBacklogKeys.sort((a, b) {
          final rawA = candidateData[a];
          final rawB = candidateData[b];
          if (rawA != null && rawB != null) {
            return _compareSyncActions(rawA, rawB);
          }
          return 0;
        });

        // Dual-Lane (80/20) Batch Scheduler:
        // Max 100 items per batch. Up to 80 slots for today's live Express Lane,
        // and up to 20 slots for Freight Lane (backlog) to prevent backlog starvation.
        // If either lane has fewer items, remaining quota dynamically transfers to the other.
        const int maxBatchSize = 100;
        final int expressCount = min(80, readyLiveKeys.length);
        final int remainingCapacity = maxBatchSize - expressCount;
        final int freightCount = min(remainingCapacity, readyBacklogKeys.length);

        final batchKeys = <dynamic>[];
        // 1. Express items first (live data appears immediately in Firestore for HQ & Chairman)
        batchKeys.addAll(readyLiveKeys.take(expressCount));
        // 2. Freight items (backlog continually drains in background)
        batchKeys.addAll(readyBacklogKeys.take(freightCount));

        // 3. If there is still capacity and more live items are waiting, take them
        if (batchKeys.length < maxBatchSize && readyLiveKeys.length > expressCount) {
          final extraLive = readyLiveKeys.skip(expressCount).take(maxBatchSize - batchKeys.length);
          batchKeys.addAll(extraLive);
        }

        // Not-ready candidates are skipped for the rest of this pass; batch keys are marked as tried.
        final batchSet = batchKeys.toSet();
        for (final k in candidateData.keys) {
          if (batchSet.contains(k) || !(readyLiveKeys.contains(k) || readyBacklogKeys.contains(k))) {
            seenThisPass.add(k);
          }
        }

        if (batchKeys.isEmpty) {
          // A full window of items waiting out a backoff: look further down the queue.
          if (candidateKeys.length >= 120) continue;
          // If all remaining keys are in backoff, schedule an immediate retry for when the earliest backoff expires!
          if (earliestBackoff != null) {
            final waitSeconds = earliestBackoff!.difference(DateTime.now()).inSeconds.clamp(1, 15);
            _retryTimer?.cancel();
            _retryTimer = Timer(Duration(seconds: waitSeconds), () {
              triggerUpload();
            });
          }
          break;
        }

        final batchedProcessedKeys = <dynamic>{};
        for (final key in batchKeys) {
          if (batchedProcessedKeys.contains(key)) continue;
          final raw = candidateData[key] ?? queueBox.get(key);
          if (raw == null || raw is! Map) {
            await queueBox.delete(key);
            continue;
          }

        final action   = Map<String, dynamic>.from(raw);
        // Revision of the queued item when this upload started. enqueueSync merges a newer edit
        // into the same key (and stamps a new enqueuedAt) while the upload is in flight; the
        // item must then stay queued (success) and must not be overwritten with this older
        // copy (failure) — both lost the newer edit, e.g. a dispense merged into a token upload.
        final startRevision = raw['enqueuedAt']?.toString();
        bool changedSinceStart() {
          final cur = queueBox.get(key);
          return cur is Map && cur['enqueuedAt']?.toString() != startRevision;
        }
        // Self-heal action payload on the fly (repairs missing camp, invalid branch, corrupt date)
        QueueSelfHealingService.healAction(action, fallbackBranch: _currentBranchId);
        final type     = action['type'] as String? ?? 'unknown';
        final attempts = (action['attempts'] as int?) ?? 0;

        // Exponential backoff check - skip if backoff is active (unless clock-skewed > 48h)
        final nextRetryAtStr = action['nextRetryAt'] as String?;
        if (!force && nextRetryAtStr != null && !promotedFromBacklog.contains(key)) {
          final nextRetry = DateTime.tryParse(nextRetryAtStr);
          if (nextRetry != null &&
              DateTime.now().isBefore(nextRetry) &&
              nextRetry.difference(DateTime.now()) <= const Duration(hours: 48)) {
            continue; // Skip key until backoff window expires
          }
        }

        // Bounded retry: Route to dead letter queue after 15 attempts (Pillar 2-C)
        if (!force && attempts >= 15) {
          action['lastFailureLoggedAt'] = DateTime.now().toIso8601String();
          await _flagPersistentSyncFailure(key, action, type);
          await LocalStorageService.moveToDeadLetterQueue(
            LocalStorageService.syncBox,
            key,
            action,
            reason: action['lastError']?.toString() ?? 'Exceeded max retry attempts (15)',
          );
          continue;
        }

        // Defer backlog item if the per-PC daily backlog budget is exhausted (unless promoted as parent of a live item)
        if (!force && _isBacklogItem(action) && !promotedFromBacklog.contains(key)) {
          if (!QuotaService.backlogBudgetAvailable) {
            final targetReset = QuotaService.nextDailyReset().toLocal();
            final existingRetry = nextRetryAtStr != null ? DateTime.tryParse(nextRetryAtStr) : null;
            if (existingRetry == null || existingRetry.isBefore(targetReset.subtract(const Duration(minutes: 1)))) {
              action['nextRetryAt'] = targetReset.toIso8601String();
              await queueBox.put(key, action);
            }
            backlogDeferred++;
            continue;
          }
          if (QuotaService.isPausedForDailyReset) {
            final targetPause = DateTime.now().add(const Duration(seconds: 30));
            final existingRetry = nextRetryAtStr != null ? DateTime.tryParse(nextRetryAtStr) : null;
            if (existingRetry == null || !DateTime.now().isBefore(existingRetry)) {
              action['nextRetryAt'] = targetPause.toIso8601String();
              await queueBox.put(key, action);
            }
            backlogDeferred++;
            continue;
          }
        }

        try {
          final branchId = _cleanBranch(action['branchId']);
          debugPrint('[SyncService] 📤 Uploading [$type] key: $key (attempt ${attempts + 1})...');

          _uploadStartedAt = DateTime.now(); // progress heartbeat for the hung-pass watchdog

          // One item's work. Every write in it goes through CloudDb (Firestore's REST API) and
          // completes only once Firestore has accepted it, so getting to the end without an
          // error means the item really is in the cloud. Nothing waits in a hidden SDK queue.
          // ignore: no_leading_underscores_for_local_identifiers
          final _db = CloudDb.instance;
          Future<void> work() async {
          // Request status items name their collection too ('edit_requests', ...) but have no
          // docId: the generic collection writer below skipped them without writing anything
          // and the item was removed as uploaded, so a decision queued on the phone never
          // reached Firestore. They go to their own handler further down.
          if (action['collection'] != null && !_requestEventTypes.contains(type) && type != 'save_school_student' && type != 'save_madrassa_student') {
            final colPath = action['collection'].toString().trim();
            final docId = action['docId']?.toString().trim();
            final act = (action['action'] ?? 'set').toString().toLowerCase().trim();
            final data = Map<String, dynamic>.from(action['data'] ?? {});

            if (colPath.isNotEmpty && docId != null && docId.isNotEmpty) {
              final isUserCol = colPath == 'users' || colPath.endsWith('/users') || colPath.contains('users');
              final CloudDoc docRef;
              if (colPath.contains('/')) {
                docRef = _db.doc('$colPath/$docId');
              } else {
                docRef = _db.collection('branches').doc(branchId).collection(colPath).doc(docId);
              }

              if (act == 'delete') {
                await docRef.delete();
                if (isUserCol) {
                  await _db.collection('users').doc(docId).delete().catchError((_) {});
                  if (branchId.isNotEmpty && branchId != 'all' && branchId != 'global') {
                    await _db.collection('branches').doc(branchId).collection('users').doc(docId).delete().catchError((_) {});
                  }
                }
              } else {
                var fsData = LocalStorageService.sanitizeForCloudUpload(data);
                if (colPath.contains('madrassa_students')) {
                  fsData = MadrassaLocalStorage.compactMediaForCloud(fsData);
                } else if (colPath.contains('school_students')) {
                  fsData = SchoolLocalStorage.compactMediaForCloud(fsData);
                }
                await docRef.set(fsData, SetOptions(merge: true));
                if (isUserCol) {
                  // Dual write: ensure both root /users and branch /branches/{b}/users are updated
                  await _db.collection('users').doc(docId).set(fsData, SetOptions(merge: true)).catchError((_) {});
                  if (branchId.isNotEmpty && branchId != 'all' && branchId != 'global') {
                    await _db.collection('branches').doc(branchId).collection('users').doc(docId).set(fsData, SetOptions(merge: true)).catchError((_) {});
                  }
                }
              }

              // Update local cache status for school records
              try {
                final bId = branchId.toLowerCase().trim();
                final nowIso = DateTime.now().toIso8601String();
                if (colPath.contains('school_students') && Hive.isBoxOpen(LocalStorageService.schoolStudentsBox)) {
                  final sBox = Hive.box(LocalStorageService.schoolStudentsBox);
                  for (final k in ['${bId}__std__$docId', '${bId}__$docId', docId]) {
                    final r = sBox.get(k);
                    if (r is Map) {
                      await sBox.put(k, Map<String, dynamic>.from(r)
                        ..['syncStatus'] = 'synced'
                        ..['lastSyncedAt'] = nowIso
                        ..['pendingSync'] = false
                        ..['synced'] = true);
                    }
                  }
                } else if (colPath.contains('school_teachers') && Hive.isBoxOpen(LocalStorageService.schoolTeachersBox)) {
                  final tBox = Hive.box(LocalStorageService.schoolTeachersBox);
                  for (final k in ['${bId}__tch__$docId', '${bId}__$docId', docId]) {
                    final r = tBox.get(k);
                    if (r is Map) {
                      await tBox.put(k, Map<String, dynamic>.from(r)
                        ..['syncStatus'] = 'synced'
                        ..['lastSyncedAt'] = nowIso
                        ..['pendingSync'] = false
                        ..['synced'] = true);
                    }
                  }
                } else if (colPath.contains('school_teacher_attendance') && Hive.isBoxOpen(LocalStorageService.schoolLogsBox)) {
                  final lBox = Hive.box(LocalStorageService.schoolLogsBox);
                  for (final k in ['${bId}__tchlog__$docId', '${bId}__$docId', docId]) {
                    final r = lBox.get(k);
                    if (r is Map) {
                      await lBox.put(k, Map<String, dynamic>.from(r)
                        ..['syncStatus'] = 'synced'
                        ..['lastSyncedAt'] = nowIso
                        ..['pendingSync'] = false
                        ..['synced'] = true);
                    }
                  }
                } else if (colPath.contains('school_attendance') && Hive.isBoxOpen(LocalStorageService.schoolLogsBox)) {
                  final lBox = Hive.box(LocalStorageService.schoolLogsBox);
                  for (final k in ['${bId}__log__$docId', '${bId}__$docId', docId]) {
                    final r = lBox.get(k);
                    if (r is Map) {
                      await lBox.put(k, Map<String, dynamic>.from(r)
                        ..['syncStatus'] = 'synced'
                        ..['lastSyncedAt'] = nowIso
                        ..['pendingSync'] = false
                        ..['synced'] = true);
                    }
                  }
                } else if (colPath.contains('school_books') && Hive.isBoxOpen(LocalStorageService.schoolBooksBox)) {
                  final bBox = Hive.box(LocalStorageService.schoolBooksBox);
                  for (final k in ['${bId}__$docId', docId]) {
                    final r = bBox.get(k);
                    if (r is Map) {
                      await bBox.put(k, Map<String, dynamic>.from(r)
                        ..['syncStatus'] = 'synced'
                        ..['lastSyncedAt'] = nowIso
                        ..['pendingSync'] = false
                        ..['synced'] = true);
                    }
                  }
                } else if (colPath.contains('school_book_loans') && Hive.isBoxOpen(LocalStorageService.schoolBookLoansBox)) {
                  final lBox = Hive.box(LocalStorageService.schoolBookLoansBox);
                  for (final k in ['${bId}__$docId', docId]) {
                    final r = lBox.get(k);
                    if (r is Map) {
                      await lBox.put(k, Map<String, dynamic>.from(r)
                        ..['syncStatus'] = 'synced'
                        ..['lastSyncedAt'] = nowIso
                        ..['pendingSync'] = false
                        ..['synced'] = true);
                    }
                  }
                } else if (colPath.contains('school_grades') && Hive.isBoxOpen(LocalStorageService.schoolGradesBox)) {
                  final gBox = Hive.box(LocalStorageService.schoolGradesBox);
                  for (final k in ['${bId}__$docId', docId]) {
                    final r = gBox.get(k);
                    if (r is Map) {
                      await gBox.put(k, Map<String, dynamic>.from(r)
                        ..['syncStatus'] = 'synced'
                        ..['lastSyncedAt'] = nowIso
                        ..['pendingSync'] = false
                        ..['synced'] = true);
                    }
                  }
                } else if (colPath.contains('school_fees') && Hive.isBoxOpen(LocalStorageService.schoolFeesBox)) {
                  final fBox = Hive.box(LocalStorageService.schoolFeesBox);
                  for (final k in ['${bId}__$docId', docId]) {
                    final r = fBox.get(k);
                    if (r is Map) {
                      await fBox.put(k, Map<String, dynamic>.from(r)
                        ..['syncStatus'] = 'synced'
                        ..['lastSyncedAt'] = nowIso
                        ..['pendingSync'] = false
                        ..['synced'] = true);
                    }
                  }
                }
              } catch (_) {}
            }
          }
          else if (type == 'save_patient') {
            final data      = Map<String, dynamic>.from(action['data'] ?? {});
            final patientId = (action['patientId'] ?? data['patientId'])?.toString();
            final bId       = _cleanBranch(action['branchId'] ?? data['branchId'] ?? branchId);
            if (patientId == null || patientId.isEmpty) throw Exception('Missing patientId');

            if (data['dob'] is String) {
              try {
                data['dob'] = Timestamp.fromDate(DateTime.parse(data['dob'] as String));
              } catch (_) {}
            }
            final fsData = LocalStorageService.sanitizeForCloudUpload(data);
            await _db.collection('branches').doc(bId).collection('patients').doc(patientId).set(fsData, SetOptions(merge: true));
            if (Hive.isBoxOpen('app_flags')) {
              await Hive.box('app_flags').put('patient_synced_$patientId', true);
            }
            if (Hive.isBoxOpen(LocalStorageService.patientsBox)) {
              final pBox = Hive.box(LocalStorageService.patientsBox);
              final r = pBox.get(patientId);
              if (r is Map) {
                await pBox.put(patientId, Map<String, dynamic>.from(r)..['syncStatus'] = 'synced');
              }
            }
          }
          else if (type == 'delete_patient') {
            final patientId = action['patientId']?.toString();
            final bId       = _cleanBranch(action['branchId'] ?? branchId);
            if (patientId != null && patientId.isNotEmpty) {
              final tombstone = {
                'isDeleted': true,
                'status': 'deleted',
                'deletedAt': FieldValue.serverTimestamp(),
                'patientId': patientId,
                'branchId': bId,
              };
              await _db.collection('branches').doc(bId).collection('patients').doc(patientId).set(tombstone, SetOptions(merge: true));
              await Hive.box('app_flags').delete('patient_synced_$patientId');
              if (Hive.isBoxOpen(LocalStorageService.patientsBox)) {
                final pBox = Hive.box(LocalStorageService.patientsBox);
                await pBox.delete(patientId);
                await pBox.flush();
              }
            }
          }
          else if (type == 'delete_prescription') {
            final bId = (action['branchId'] ?? branchId).toString();
            final pCnic = action['patientCnic']?.toString() ?? '';
            final serial = action['serial']?.toString() ?? '';
            final path = action['path']?.toString() ?? '';
            if (path.isNotEmpty) {
              await _db.doc(path).delete();
            }
            if (pCnic.isNotEmpty && serial.isNotEmpty) {
              await _db.collection('branches').doc(bId).collection('patients').doc(pCnic).collection('prescriptions').doc(serial).delete();
              try {
                await _db.collection('branches').doc(bId).collection('prescriptions').doc(pCnic).collection('prescriptions').doc(serial).delete();
              } catch (_) {}
              try {
                await _db.collection('prescriptions').doc(pCnic).collection('prescriptions').doc(serial).delete();
              } catch (_) {}
            }
          }
          else if (type == 'delete_dispensary') {
            final bId     = (action['branchId'] ?? branchId).toString();
            final dateKey = action['dateKey']?.toString() ?? '';
            final serial  = action['serial']?.toString() ?? '';
            final path    = action['path']?.toString() ?? '';
            if (path.isNotEmpty) {
              await _db.doc(path).delete();
            }
            if (bId.isNotEmpty && dateKey.isNotEmpty && serial.isNotEmpty) {
              await _db.collection('branches').doc(bId).collection('dispensary').doc(dateKey).collection(dateKey).doc(serial).delete();
              try {
                await _db.collection('branches').doc(bId).collection('dispensary').doc(dateKey).collection('dispensed').doc(serial).delete();
              } catch (_) {}
              try {
                await _db.collection('branches').doc(bId).collection('dispensary').doc(serial).delete();
              } catch (_) {}
            }
          }
          else if (type == 'save_entry') {
            final data    = Map<String, dynamic>.from(action['data'] ?? {});
            final dateKey = (action['dateKey'] ?? action['datePart'] ?? data['dateKey'])?.toString();
            final serial  = (action['serial'] ?? data['serial'])?.toString();
            if (dateKey == null || serial == null) throw Exception('Missing dateKey/serial');
            final queueType = resolveQueueType((action['queueType'] ?? data['queueType'])?.toString(), branchId: branchId);

            if (data['isTempSerial'] == true || action['isTempSerial'] == true) {
              final dispTag = (data['dispensaryTag'] ?? CampSessionService.getDispensaryKeyword(data['dispensaryId'])).toString();
              final result = await issueAtomicSerialTransaction(
                branchId: branchId,
                dispensaryTag: dispTag,
                queueType: queueType,
                tokenData: data,
              );
              final canonicalSerial = result['serial'] as String;
              await LocalStorageService.remapTempSerialToCanonical(
                branchId,
                serial,
                canonicalSerial,
                result['entryData'] as Map<String, dynamic>,
              );
            } else {
              final upperSerial = serial.trim().toUpperCase();
              data['serial'] = upperSerial;

              // Terminal Status Protection: Never overwrite completed/dispensed with waiting
              try {
                if (Hive.isBoxOpen(LocalStorageService.entriesBox)) {
                  final eBox = Hive.box(LocalStorageService.entriesBox);
                  final localE = eBox.get('$branchId-$upperSerial') ?? eBox.get('$branchId-$serial');
                  if (localE is Map) {
                    final lDisp = (localE['dispenseStatus'] ?? '').toString().toLowerCase();
                    final lStat = (localE['status'] ?? '').toString().toLowerCase();
                    if (lDisp == 'dispensed' || lStat == 'completed') {
                      data['status'] = 'completed';
                      if (lDisp == 'dispensed') {
                        data['dispenseStatus'] = 'dispensed';
                        if (localE['dispensedAt'] != null) data['dispensedAt'] = localE['dispensedAt'];
                      }
                      if (localE['prescription'] != null) data['prescription'] = localE['prescription'];
                      if (localE['doctorName'] != null) data['doctorName'] = localE['doctorName'];
                      if (localE['completedAt'] != null) data['completedAt'] = localE['completedAt'];
                    }
                  }
                }
              } catch (_) {}

              final campDocKey = CampSessionService.getCampDateDocId(
                branchId: branchId,
                dateKey: dateKey,
                campId: data['campId']?.toString() ?? data['dispensaryId']?.toString(),
                dispensaryTag: data['dispensaryTag']?.toString(),
                serial: upperSerial,
              );
              final fsData = LocalStorageService.sanitizeForCloudUpload(data);
              // This PC's copy may be older than the cloud's (another PC dispensed it). With
              // merge, its 'pending' would undo that dispense, so only 'dispensed' is written.
              if ((fsData['dispenseStatus'] ?? '').toString().toLowerCase() != 'dispensed') {
                fsData.remove('dispenseStatus');
              }
              // Re-uploaded older records must not move a completed token back to waiting.
              final st = (fsData['status'] ?? '').toString().toLowerCase();
              if (_isBacklogItem(action) && (st == 'waiting' || st == 'pending' || st.isEmpty)) {
                fsData.remove('status');
              }
              await _db.collection('branches').doc(branchId).collection('serials').doc(campDocKey).collection(queueType).doc(upperSerial).set(fsData, SetOptions(merge: true));
              // The dispense and prescription copies are part of this item: a failure here used
              // to be swallowed and the item deleted as uploaded, so the cloud kept the token but
              // lost its prescription/dispense for good. Failing the item retries it; all writes
              // are merges on fixed document ids, so a retry is safe.
              await _db.collection('branches').doc(branchId).collection('dispensary').doc(dateKey).collection(dateKey).doc(upperSerial).set(fsData, SetOptions(merge: true));

              // Direct write embedded prescription to patient timeline so historical data is easily found
              final pCnic = (fsData['patientCnic'] ?? fsData['cnic'] ?? '').toString().trim();
              if (pCnic.isNotEmpty && (fsData['prescription'] != null || fsData['medicines'] != null || fsData['doctorName'] != null)) {
                await _db.collection('branches').doc(branchId).collection('prescriptions').doc(pCnic).collection('prescriptions').doc(upperSerial).set(fsData, SetOptions(merge: true));
                // (No unread copy under patients/{cnic}/prescriptions.)
              }

              // Direct write patient profile
              final pid = (fsData['patientId'] ?? fsData['id'] ?? '').toString().trim();
              if (pid.isNotEmpty && !pid.startsWith('unknown_')) {
                try {
                  final patData = {
                    'id': pid,
                    'patientId': pid,
                    'name': fsData['patientName'] ?? fsData['name'],
                    'cnic': fsData['patientCnic'] ?? fsData['cnic'],
                    if (fsData['phone'] != null) 'phone': fsData['phone'],
                    if (fsData['gender'] != null) 'gender': fsData['gender'],
                    if (fsData['age'] != null) 'age': fsData['age'],
                    'branchId': branchId,
                    // No per-visit field, so CloudDb skips repeat writes of the same profile.
                  };
                  await _db.collection('branches').doc(branchId).collection('patients').doc(pid).set(patData, SetOptions(merge: true));
                } catch (_) {}
              }

              if (serial != upperSerial) {
                try {
                  await _db.collection('branches').doc(branchId).collection('serials').doc(campDocKey).collection(queueType).doc(serial.toLowerCase()).delete();
                } catch (_) {}
              }

              // Update local entry so pendingSync is cleared
              try {
                if (Hive.isBoxOpen(LocalStorageService.entriesBox)) {
                  final eBox = Hive.box(LocalStorageService.entriesBox);
                  final normBranch = branchId.toLowerCase().trim();
                  final canonicalKey = '$normBranch-$upperSerial';
                  final existing = eBox.get(canonicalKey) ?? eBox.get('$branchId-$serial') ?? eBox.get(upperSerial);
                  if (existing is Map) {
                    final upd = Map<String, dynamic>.from(existing);
                    upd['pendingSync'] = false;
                    upd['synced'] = true;
                    upd['syncStatus'] = 'synced';
                    upd['cloudSyncedAt'] = DateTime.now().toIso8601String(); // proof of a real upload (see purgeBloatedSyncQueue)
                    await eBox.put(canonicalKey, upd);
                  }
                }
              } catch (_) {}
            }
          }
          else if (type == 'save_prescription') {
            final rawSerial = action['serial'] as String?;
            final data   = Map<String, dynamic>.from(action['data'] ?? {});
            if (rawSerial == null) throw Exception('Missing serial');
            final serial = rawSerial.trim().toUpperCase();
            data['serial'] = serial;
            
            final queueType = resolveQueueType(action['queueType']?.toString() ?? Hive.box(LocalStorageService.entriesBox).get('$branchId-$serial')?['queueType']?.toString(), branchId: branchId);
            final dateKey   = action['dateKey']?.toString() ?? Hive.box(LocalStorageService.entriesBox).get('$branchId-$serial')?['dateKey']?.toString() ?? LocalStorageService.getTodayDateKey();
            final campDocKey = CampSessionService.getCampDateDocId(
              branchId: branchId,
              dateKey: dateKey,
              campId: data['campId']?.toString() ?? data['dispensaryId']?.toString(),
              dispensaryTag: data['dispensaryTag']?.toString(),
              serial: serial,
            );

            final updateMap = <String, dynamic>{
              'status':         'completed',
              'completedAt':    data['completedAt'] ?? DateTime.now().toUtc().toIso8601String(),
              // Only ever write 'dispensed' here: the doctor's prescription carries 'pending', and
              // a delayed doctor upload (merge) used to undo a dispense already in the cloud.
              if ((data['dispenseStatus'] ?? '').toString().toLowerCase() == 'dispensed') 'dispenseStatus': 'dispensed',
            };

            // Terminal Status Protection: Preserve dispensed status if already dispensed locally
            try {
              if (Hive.isBoxOpen(LocalStorageService.entriesBox)) {
                final localE = Hive.box(LocalStorageService.entriesBox).get('$branchId-$serial');
                if (localE is Map && (localE['dispenseStatus'] ?? '').toString().toLowerCase() == 'dispensed') {
                  updateMap['dispenseStatus'] = 'dispensed';
                  if (localE['dispensedAt'] != null) updateMap['dispensedAt'] = localE['dispensedAt'];
                }
              }
            } catch (_) {}

            for (final f in ['doctorName', 'doctorId', 'daysOfMedicine', 'extraCharge', 'vitals', 'prescription', 'medicines', 'diagnosis', 'complaints']) {
              if (data.containsKey(f) && data[f] != null) {
                updateMap[f] = data[f];
              }
            }

            await _db.collection('branches').doc(branchId).collection('serials').doc(campDocKey).collection(queueType).doc(serial).set(updateMap, SetOptions(merge: true));

            // Direct write to prescriptions and dispensary paths
            final cnic = (data['patientCnic'] ?? data['cnic'] ?? '').toString();
            if (cnic.isNotEmpty) {
              try {
                await _db.collection('branches').doc(branchId).collection('prescriptions').doc(cnic).collection('prescriptions').doc(serial).set(Map<String, dynamic>.from(data)..addAll(updateMap), SetOptions(merge: true));
              } catch (_) {}
            }
            try {
              await _db.collection('branches').doc(branchId).collection('dispensary').doc(dateKey).collection(dateKey).doc(serial).set(updateMap, SetOptions(merge: true));
            } catch (_) {}

            if (rawSerial != serial) {
              try {
                await _db.collection('branches').doc(branchId).collection('serials').doc(campDocKey).collection(queueType).doc(rawSerial.toLowerCase()).delete();
              } catch (_) {}
            }

            // Update local entry so pendingSync is cleared
            try {
              if (Hive.isBoxOpen(LocalStorageService.entriesBox)) {
                final eBox = Hive.box(LocalStorageService.entriesBox);
                final normBranch = branchId.toLowerCase().trim();
                final canonicalKey = '$normBranch-$serial';
                final existing = eBox.get(canonicalKey) ?? eBox.get('$branchId-$rawSerial') ?? eBox.get(serial);
                if (existing is Map) {
                  final upd = Map<String, dynamic>.from(existing);
                  upd['pendingSync'] = false;
                  upd['synced'] = true;
                  upd['syncStatus'] = 'synced';
                  upd['cloudSyncedAt'] = DateTime.now().toIso8601String();
                  await eBox.put(canonicalKey, upd);
                }
              }
            } catch (_) {}
          }
          else if (type == 'update_serial_status') {
            final serial = action['serial'] as String?;
            final data   = Map<String, dynamic>.from(action['data'] ?? {});
            if (serial == null) throw Exception('Missing serial');
            final entryKey = '$branchId-$serial';
            final localEntry = Hive.box(LocalStorageService.entriesBox).get(entryKey);

            // Terminal Status Protection
            try {
              if (localEntry is Map) {
                final lDisp = (localEntry['dispenseStatus'] ?? '').toString().toLowerCase();
                final dDisp = (data['dispenseStatus'] ?? '').toString().toLowerCase();
                if (lDisp == 'dispensed' && dDisp != 'dispensed') {
                  data['dispenseStatus'] = 'dispensed';
                  data['status'] = 'completed';
                }
              }
            } catch (_) {}

            final queueType = resolveQueueType(action['queueType']?.toString() ?? localEntry?['queueType']?.toString(), branchId: branchId);
            final dateKey   = action['dateKey']?.toString() ?? localEntry?['dateKey']?.toString() ?? LocalStorageService.getTodayDateKey();
            final campDocKey = CampSessionService.getCampDateDocId(
              branchId: branchId,
              dateKey: dateKey,
              campId: data['campId']?.toString() ?? data['dispensaryId']?.toString() ?? localEntry?['campId']?.toString() ?? localEntry?['dispensaryId']?.toString(),
              dispensaryTag: data['dispensaryTag']?.toString() ?? localEntry?['dispensaryTag']?.toString(),
              serial: serial,
            );
            await _db.collection('branches').doc(branchId).collection('serials').doc(campDocKey).collection(queueType).doc(serial).set(data, SetOptions(merge: true));
            try {
              await _db.collection('branches').doc(branchId).collection('dispensary').doc(dateKey).collection(dateKey).doc(serial).set(data, SetOptions(merge: true));
            } catch (_) {}
          }
          else if (type == 'save_dispensary_record') {
            final serial = action['serial'] as String?;
            final data   = Map<String, dynamic>.from(action['data'] ?? {});
            if (serial != null && serial.isNotEmpty) {
              final upperSerial = serial.trim().toUpperCase();
              final dateKey = (action['dateKey'] ?? data['dateKey'] ?? LocalStorageService.getTodayDateKey()).toString();
              final campDocKey = CampSessionService.getCampDateDocId(
                branchId: branchId,
                dateKey: dateKey,
                campId: data['campId']?.toString() ?? data['dispensaryId']?.toString(),
                dispensaryTag: data['dispensaryTag']?.toString(),
                serial: upperSerial,
              );
              final queueType = resolveQueueType(action['queueType']?.toString() ?? data['queueType']?.toString(), branchId: branchId);
              final statusPatch = {
                'dispenseStatus': data['dispenseStatus'] ?? 'dispensed',
                'status': 'completed',
                if (data['dispensedAt'] != null) 'dispensedAt': data['dispensedAt'],
                if (data['dispensedBy'] != null) 'dispensedBy': data['dispensedBy'],
                if (data['completedAt'] != null) 'completedAt': data['completedAt'],
              };
              // These are this item's only writes: swallowing their errors deleted a dispense
              // record that never reached the cloud. Merges on fixed ids — safe to retry.
              await _db.collection('branches').doc(branchId).collection('serials').doc(campDocKey).collection(queueType).doc(upperSerial).set(statusPatch, SetOptions(merge: true));
              await _db.collection('branches').doc(branchId).collection('dispensary').doc(dateKey).collection(dateKey).doc(upperSerial).set(Map<String, dynamic>.from(data)..addAll(statusPatch), SetOptions(merge: true));
            }
          }
          else if (type == 'save_dispensary_charge') {
            final data    = Map<String, dynamic>.from(action['data'] ?? {});
            final serial  = (action['serial'] ?? data['serial'])?.toString();
            final dateKey = (action['dateKey'] ?? data['dateKey'])?.toString() ?? LocalStorageService.getTodayDateKey();
            if (serial == null || serial.isEmpty) throw Exception('Missing serial');
            final queueType = resolveQueueType((action['queueType'] ?? data['queueType'])?.toString(), branchId: branchId);
            final campDocKey = CampSessionService.getCampDateDocId(
              branchId: branchId,
              dateKey: dateKey,
              campId: data['campId']?.toString() ?? data['dispensaryId']?.toString(),
              dispensaryTag: data['dispensaryTag']?.toString(),
              serial: serial,
            );
            await _db.collection('branches').doc(branchId).collection('dispensary_charges').doc(dateKey).collection('charges').doc(serial).set({...data, 'queueType': queueType}, SetOptions(merge: true));
            await _db.collection('branches').doc(branchId).collection('serials').doc(campDocKey).collection(queueType).doc(serial).set({'daysOfMedicine': (data['daysOfMedicine'] as num?)?.toInt() ?? 1}, SetOptions(merge: true));
          }
          else if (type == 'update_inventory') {
            final nestedData = action['data'] is Map
                ? Map<String, dynamic>.from(action['data'] as Map)
                : <String, dynamic>{};
            final medicineId = (action['medicineId'] ?? action['inventoryId'] ?? nestedData['medicineId'] ?? nestedData['inventoryId'] ?? nestedData['id'] ?? nestedData['docId'])?.toString().trim();
            final deltaValue = action['delta'] ?? nestedData['delta'];
            final delta = deltaValue is num
                ? deltaValue.toDouble()
                : double.tryParse(deltaValue?.toString() ?? '') ?? 0.0;
            if (medicineId != null && medicineId.isNotEmpty && delta != 0) {
              final serialHint = medicineId.startsWith('hajicamp--')
                  ? 'HAJI'
                  : (medicineId.startsWith('saddar--') ? 'SADDAR' : (action['serial'] ?? nestedData['serial'])?.toString());
              final invCol = CampSessionService.getCampInventoryPath(
                branchId: branchId,
                campId: (action['campId'] ?? nestedData['campId'] ?? nestedData['dispensaryId'])?.toString(),
                dispensaryTag: (action['dispensaryTag'] ?? nestedData['dispensaryTag'])?.toString(),
                serial: serialHint,
              );
              final docRef = _db.collection('branches').doc(branchId).collection(invCol).doc(medicineId);
              // Applied once per txId ('updatedAt' is what the inventory delta download filters on).
              await _incrementStockOnce(
                branchId: branchId,
                docRef: docRef,
                txId: (action['txId'] ?? key).toString(),
                amount: delta,
                isRetry: attempts > 0 || action['lastAttempt'] != null || action['lastError'] != null,
              );
            }
          }
          else if (type == 'add_inventory_stock') {
            final nestedData = action['data'] is Map
                ? Map<String, dynamic>.from(action['data'] as Map)
                : <String, dynamic>{};
            final medicineId = (action['medicineId'] ?? action['inventoryId'] ?? nestedData['medicineId'] ?? nestedData['inventoryId'] ?? nestedData['id'] ?? nestedData['docId'])?.toString().trim();
            final qty = (action['quantity'] as num?)?.toInt() ?? 0;
            final txId = action['txId'] as String? ?? key;
            if (medicineId != null && medicineId.isNotEmpty && qty > 0) {
              final serialHint = medicineId.startsWith('hajicamp--')
                  ? 'HAJI'
                  : (medicineId.startsWith('saddar--') ? 'SADDAR' : (action['serial'] ?? nestedData['serial'])?.toString());
              final invCol = CampSessionService.getCampInventoryPath(
                branchId: branchId,
                campId: (action['campId'] ?? nestedData['campId'] ?? nestedData['dispensaryId'])?.toString(),
                dispensaryTag: (action['dispensaryTag'] ?? nestedData['dispensaryTag'])?.toString(),
                serial: serialHint,
              );
              final docRef = _db.collection('branches').doc(branchId).collection(invCol).doc(medicineId);
              // Applied once per txId ('updatedAt' is what the other PCs' inventory pull filters on).
              await _incrementStockOnce(
                branchId: branchId,
                docRef: docRef,
                txId: txId,
                amount: qty,
                isRetry: attempts > 0 || action['lastAttempt'] != null || action['lastError'] != null,
              );

              // Add to audit log using txId as document ID to prevent duplicate log items on retry
              await _db
                  .collection('branches')
                  .doc(branchId)
                  .collection('inventory_log')
                  .doc(txId)
                  .set({
                'action': 'add_stock',
                'medicineId': medicineId,
                'medicineName': action['medicineName'] ?? '',
                'quantityAdded': qty,
                'performedBy': action['performedBy'] ?? '',
                'performedByName': action['performedByName'] ?? '',
                'timestamp': FieldValue.serverTimestamp(),
              }, SetOptions(merge: true));
            }
          }
          else if (type == 'register_medicine' || type == 'add_stock' || type == 'add_proforma_stock') {
            final data = Map<String, dynamic>.from(action['data'] ?? {});
            final docId = data['id']?.toString() ?? data['docId']?.toString() ?? action['medicineId']?.toString() ?? action['docId']?.toString() ?? action['syncId']?.toString() ?? const Uuid().v4();
            final fsData = Map<String, dynamic>.from(data)..remove('id')..remove('syncStatus');
            // downloadInventory's delta query compares updatedAt with a Timestamp; the client's
            // ISO string never matched, so edited/registered medicines didn't reach other PCs.
            fsData['updatedAt'] = FieldValue.serverTimestamp();
            // Folded branch like every other inventory executor ('haji_camp' → 'karachi'); a raw
            // camp id is kept as the camp so its stock still goes to that camp's collection.
            final rawBranch = (action['branchId']?.toString() ?? branchId).trim();
            final targetBranch = _cleanBranch(rawBranch);
            final rawIsCamp = rawBranch.isNotEmpty && rawBranch.toLowerCase() != targetBranch;
            final invCol = CampSessionService.getCampInventoryPath(
              branchId: targetBranch,
              campId: data['dispensaryId']?.toString() ?? data['campId']?.toString() ?? (rawIsCamp ? rawBranch : null),
            );
            await _db.collection('branches').doc(targetBranch).collection(invCol).doc(docId).set(fsData, SetOptions(merge: true));

            final logData = action['logData'] != null ? Map<String, dynamic>.from(action['logData']) : null;
            if (logData != null) {
              await _db.collection('branches').doc(targetBranch).collection('inventory_log').add({
                ...logData,
                'timestamp': FieldValue.serverTimestamp(),
              });
            } else if (type == 'register_medicine') {
              await _db.collection('branches').doc(targetBranch).collection('inventory_log').add({
                'action': 'medicine_registered_directly',
                'medicineName': data['name'],
                'docId': docId,
                'quantityAdded': (data['quantity'] as num?)?.toInt() ?? 0,
                'timestamp': FieldValue.serverTimestamp(),
              });
            }
          }
          else if (type == 'delete_inventory_item') {
            final nestedData = action['data'] is Map ? Map<String, dynamic>.from(action['data'] as Map) : <String, dynamic>{};
            final medicineId = (action['medicineId'] ?? action['inventoryId'] ?? action['id'] ?? nestedData['medicineId'] ?? nestedData['inventoryId'] ?? nestedData['id'] ?? nestedData['docId'])?.toString().trim();
            final targetBranch = _cleanBranch(action['branchId'] ?? nestedData['branchId'] ?? branchId);
            if (medicineId != null && medicineId.isNotEmpty) {
              final serialHint = medicineId.startsWith('hajicamp--')
                  ? 'HAJI'
                  : (medicineId.startsWith('saddar--') ? 'SADDAR' : (action['serial'] ?? nestedData['serial'])?.toString());
              final invCol = CampSessionService.getCampInventoryPath(
                branchId: targetBranch,
                campId: (action['campId'] ?? nestedData['campId'] ?? nestedData['dispensaryId'])?.toString(),
                dispensaryTag: (action['dispensaryTag'] ?? nestedData['dispensaryTag'])?.toString(),
                serial: serialHint,
              );
              await _db.collection('branches').doc(targetBranch).collection(invCol).doc(medicineId).delete().catchError((_) {});
              await _db.collection('branches').doc(targetBranch).collection('inventory').doc(medicineId).delete().catchError((_) {});
            }
          }
          else if (type == 'save_inventory_log') {
            final logData = Map<String, dynamic>.from(action['data'] ?? action['logData'] ?? {});
            final targetBranch = action['branchId']?.toString() ?? branchId;
            await _db.collection('branches').doc(targetBranch).collection('inventory_log').add({
              ...logData,
              'timestamp': FieldValue.serverTimestamp(),
            });
          }
          else if (type == 'save_token_exception_request' || type == 'token_exception_request') {
            // token_exception_request: forwarded by the LAN server for a client receptionist.
            final data = Map<String, dynamic>.from(action['data'] ?? {});
            final requestId = action['requestId']?.toString() ?? action['docId']?.toString() ?? data['id']?.toString() ?? data['requestId']?.toString() ?? action['syncId']?.toString() ?? const Uuid().v4();
            data['status'] ??= 'pending';
            data['requestType'] ??= 'token_exception';
            final bId = action['branchId']?.toString() ?? branchId;
            final docRef = _db.collection('branches').doc(bId).collection('edit_requests').doc(requestId);
            await _keepDecidedRequestStatus(docRef, data, localBox: 'local_edit_requests', id: requestId);

            for (final f in ['requestedAt', 'reviewedAt']) {
              if (data[f] is String) {
                try {
                  data[f] = Timestamp.fromDate(DateTime.parse(data[f] as String));
                } catch (_) {}
              }
            }

            await docRef.set(LocalStorageService.sanitizeForCloudUpload(data), SetOptions(merge: true));
          }
          else if (type == 'approve_token_exception') {
            final data = Map<String, dynamic>.from(action['data'] ?? {});
            final requestId = action['requestId']?.toString() ?? action['docId']?.toString();
            final bId = action['branchId']?.toString() ?? branchId;
            final patientId = action['patientId']?.toString() ?? data['patientId']?.toString();

            if (patientId != null && patientId.isNotEmpty) {
              await LocalStorageService.grantTokenException(
                bId,
                patientId,
                reason: data['doctorReason']?.toString() ?? 'Approved by Doctor',
                approvedBy: data['approvedBy']?.toString() ?? 'Doctor',
                requestId: requestId,
              );
            }

            if (requestId != null) {
              data['status'] = 'approved';
              data['reviewedAt'] ??= DateTime.now().toIso8601String();
              for (final f in ['requestedAt', 'reviewedAt', 'approvedAt']) {
                if (data[f] is String) {
                  try {
                    data[f] = Timestamp.fromDate(DateTime.parse(data[f] as String));
                  } catch (_) {}
                }
              }
              await _db
                  .collection('branches')
                  .doc(bId)
                  .collection('edit_requests')
                  .doc(requestId)
                  .set(data, SetOptions(merge: true));
            }
          }
          else if (type == 'update_request_status' || type == 'approve_request' || type == 'reject_request' || type == 'request_approved' || type == 'request_rejected' || type == 'token_exception_approved') {
            final data = action['data'] is Map
                ? Map<String, dynamic>.from(action['data'] as Map)
                : Map<String, dynamic>.from(action);
            final requestId = action['docId']?.toString() ?? action['requestId']?.toString() ?? data['requestId']?.toString() ?? data['id']?.toString() ?? action['id']?.toString();
            // cloudBranch: the exact branch doc the request was read from. Some requests live
            // under a raw id (grt, jalalpur_jattan); the cleaned id would write the decision to
            // a different, new doc and leave the real request pending.
            final cloudBranch = action['cloudBranch']?.toString().trim() ?? '';
            final bId = cloudBranch.isNotEmpty
                ? cloudBranch
                : _cleanBranch(action['branchId']?.toString() ?? data['branchId']?.toString() ?? branchId);
            data.remove('cloudBranch');
            if (action['data'] is! Map) {
              // The queue item itself is the payload: its own bookkeeping (createdAt is when
              // it was queued) must not overwrite the request's fields.
              for (final f in ['createdAt', 'enqueuedAt', 'syncId', 'txId', 'backlog', 'priority', 'lastAttemptAt']) {
                data.remove(f);
              }
            }
            final col = action['collection']?.toString() ?? data['collection']?.toString() ?? 'edit_requests';
            if (requestId != null && requestId.isNotEmpty) {
              if (type == 'approve_request' || type == 'request_approved' || type == 'token_exception_approved') {
                data['status'] = 'approved';
              } else if (type == 'reject_request' || type == 'request_rejected') {
                data['status'] = 'rejected';
              } else {
                // update_request_status. The decision is in 'requestStatus': enqueueSync
                // overwrites a queue item's 'status' with its own state ('pending'), and reading
                // that uploaded every approval made on the phone as pending again, right after
                // its direct write had set it approved.
                final resolved = action['requestStatus'] ?? data['requestStatus'] ??
                    (action['data'] is Map ? data['status'] : null);
                if (!isDecidedRequestStatus(resolved)) {
                  // An older item whose decision was overwritten: sending it would only revert
                  // the request. The approver's direct write (and the re-send in the Requests
                  // page) carries the decision instead.
                  SyncLog.write('Skipped $col/$requestId status update with no decision (queued before 2026-10-18)');
                  await queueBox.delete(key);
                  return;
                }
                data['status'] = resolved;
              }
              data.remove('requestStatus');
              for (final f in ['requestedAt', 'reviewedAt', 'approvedAt', 'rejectedAt', 'acknowledgedAt']) {
                if (data[f] is String) {
                  try {
                    data[f] = Timestamp.fromDate(DateTime.parse(data[f] as String));
                  } catch (_) {}
                }
              }
              data.remove('type');
              data.remove('data');
              await _db
                  .collection('branches')
                  .doc(bId)
                  .collection(col)
                  .doc(requestId)
                  .set(LocalStorageService.sanitizeForCloudUpload(data), SetOptions(merge: true));
            }
          }
          else if (type == 'save_donation') {
            final data    = Map<String, dynamic>.from(action['data'] ?? {});
            final hiveKey = action['hiveKey'] as String?;
            final stableId = (data['firestoreId'] as String?)?.isNotEmpty == true ? data['firestoreId'] as String : (action['localId']?.toString() ?? action['syncId']?.toString() ?? const Uuid().v4());
            final targetBranch = _cleanBranch(action['branchId'] ?? data['branchId'] ?? branchId);
            final docRef = _db.collection('branches').doc(targetBranch).collection('donations').doc(stableId);

            final hasRemoteId = (data['firestoreId'] as String?)?.isNotEmpty == true;
            if (hasRemoteId) {
              try {
                final remoteDoc = await docRef.get().timeout(const Duration(seconds: 4));
                if (remoteDoc.exists) {
                  final remoteUpdate = (remoteDoc.data()?['lastUpdatedAt'] ?? remoteDoc.data()?['updatedAt']) as String?;
                  final localUpdate  = (data['lastUpdatedAt'] ?? data['updatedAt']) as String?;
                  if (remoteUpdate != null && localUpdate != null && DateTime.parse(remoteUpdate).isAfter(DateTime.parse(localUpdate))) {
                    if (hiveKey != null) await DonationsLocalStorage.mergeRemoteDonation(hiveKey, stableId, remoteDoc.data() ?? {});
                    await queueBox.delete(key);
                    return;
                  }
                }
              } catch (_) {}
            }
            // Always UTC ISO strings. downloadAllDonations compares updatedAt as a string
            // watermark; a local-time value (no 'Z', from saveDonation) sorts ~5 h after UTC ones
            // in Pakistan, pushing the watermark past donations that then never downloaded.
            String utcIso(Object? v) =>
                (DateTime.tryParse('${v ?? ''}') ?? DateTime.now()).toUtc().toIso8601String();
            data['updatedAt'] = utcIso(data['updatedAt'] ?? data['lastUpdatedAt']);
            data['lastUpdatedAt'] = utcIso(data['lastUpdatedAt'] ?? data['updatedAt']);
            data['branchId'] = targetBranch;
            final fsData = Map<String, dynamic>.from(data)..remove('hiveKey')..remove('syncStatus')..remove('firestoreId');

            // Dual write: subcollection AND top-level collection (ensures remote visibility anywhere in Firestore)
            await docRef.set(fsData, SetOptions(merge: true));
            await _db.collection('donations').doc(stableId).set(fsData, SetOptions(merge: true)).catchError((_) {});

            if (hiveKey != null) await DonationsLocalStorage.markDonationSynced(hiveKey, docRef.id);
          }
          else if (type == 'save_audit_log') {
            final data      = Map<String, dynamic>.from(action['data'] ?? {});
            final logId     = data['id']?.toString() ?? action['syncId']?.toString() ?? const Uuid().v4();
            final logBranch = action['branchId'] as String? ?? branchId;
            data['branchId'] ??= logBranch;
            final batch = _db.batch();
            batch.set(_db.collection('branches').doc(logBranch).collection('audit_logs').doc(logId), data, SetOptions(merge: true));
            batch.set(_db.collection('global_audit_logs').doc(logId), data, SetOptions(merge: true));
            await batch.commit();
          }
          else if (type == 'save_journal_entry') {
            final data    = Map<String, dynamic>.from(action['data'] ?? {});
            final entryId = action['entryId'] as String?;
            final bId     = action['branchId'] as String? ?? branchId;
            if (entryId != null && data.isNotEmpty) {
              final batch = _db.batch();
              if (bId != 'all') {
                batch.set(_db.collection('branches').doc(bId).collection('journal_entries').doc(entryId), data, SetOptions(merge: true));
              }
              batch.set(_db.collection('global_journal_entries').doc(entryId), data, SetOptions(merge: true));
              await batch.commit();
            }
          }
          else if (type == 'save_org_bank_account') {
            final data      = Map<String, dynamic>.from(action['data'] ?? {});
            final accountId = action['accountId'] as String?;
            if (accountId != null && data.isNotEmpty) {
              await _db.collection('global_org_bank_accounts').doc(accountId).set(data, SetOptions(merge: true));
            }
          }

          else if (type == 'save_donor') {
            final data    = Map<String, dynamic>.from(action['data'] ?? {});
            final donorId = action['donorId'] as String?;
            if (donorId == null || data.isEmpty) throw Exception('Missing donorId');
            final docRef = _db.collection('donors').doc(donorId);
            final remoteDoc = await docRef.get();
            if (remoteDoc.exists) {
              final remoteUpdate = remoteDoc.data()?['lastUpdatedAt'] as String?;
              final localUpdate  = data['lastUpdatedAt'] as String?;
              if (remoteUpdate != null && localUpdate != null && DateTime.parse(remoteUpdate).isAfter(DateTime.parse(localUpdate))) {
                await DonationsLocalStorage.mergeRemoteDonor(donorId, remoteDoc.data() ?? {});
                await queueBox.delete(key);
                return;
              }
            }
            final fsData = Map<String, dynamic>.from(data)..remove('syncStatus')..remove('isEdited');
            await docRef.set(fsData, SetOptions(merge: true));
          }
          else if (type == 'save_donor_branch') {
            final data    = Map<String, dynamic>.from(action['data'] ?? {});
            final donorId = action['donorId'] as String?;
            final bId     = _cleanBranch((action['branchId'] as String?) ?? branchId); // 'grt' → 'gujrat'
            if (donorId == null || data.isEmpty) throw Exception('Missing donorId');
            final docRef = _db.collection('branches').doc(bId).collection('donors').doc(donorId);
            final remoteDoc = await docRef.get();
            if (remoteDoc.exists) {
              final remoteUpdate = remoteDoc.data()?['lastUpdatedAt'] as String?;
              final localUpdate  = data['lastUpdatedAt'] as String?;
              if (remoteUpdate != null && localUpdate != null && DateTime.parse(remoteUpdate).isAfter(DateTime.parse(localUpdate))) {
                await DonationsLocalStorage.mergeRemoteDonor(donorId, remoteDoc.data() ?? {});
                await queueBox.delete(key);
                return;
              }
            }
            final fsData = Map<String, dynamic>.from(data)..remove('syncStatus')..remove('isEdited');
            await docRef.set(fsData, SetOptions(merge: true));
          }
          else if (type == 'update_donation') {
            final firestoreId = action['firestoreId'] as String?;
            final fields      = Map<String, dynamic>.from(action['fields'] ?? {});
            if (firestoreId == null) throw Exception('Missing firestoreId');
            final bId = _cleanBranch(action['branchId'] ?? branchId);
            final docRef = _db.collection('branches').doc(bId).collection('donations').doc(firestoreId);
            try {
              final remoteDoc = await docRef.get().timeout(const Duration(seconds: 4));
              if (remoteDoc.exists) {
                final remoteUpdate = (remoteDoc.data()?['lastUpdatedAt'] ?? remoteDoc.data()?['updatedAt']) as String?;
                final localUpdate  = (fields['lastUpdatedAt'] ?? fields['updatedAt']) as String?;
                if (remoteUpdate != null && localUpdate != null && DateTime.parse(remoteUpdate).isAfter(DateTime.parse(localUpdate))) {
                  final hiveKey = (action['hiveKey'] as String?) ?? DonationsLocalStorage.getBox().keys.firstWhere(
                    (k) => k.toString().endsWith(firestoreId),
                    orElse: () => '',
                  ).toString();
                  if (hiveKey.isNotEmpty) {
                    await DonationsLocalStorage.mergeRemoteDonation(hiveKey, firestoreId, remoteDoc.data() ?? {});
                  }
                  await queueBox.delete(key);
                  return;
                }
              }
            } catch (_) {}
            final nowUtc = DateTime.now().toUtc().toIso8601String();
            fields['updatedAt'] ??= fields['lastUpdatedAt'] ?? nowUtc;
            fields['lastUpdatedAt'] ??= nowUtc;
            fields['branchId'] = bId;
            final fsFields = Map<String, dynamic>.from(fields)..remove('hiveKey')..remove('syncStatus')..remove('firestoreId');
            
            // Safe upsert into both subcollection and top-level donations
            await docRef.set(fsFields, SetOptions(merge: true));
            await _db.collection('donations').doc(firestoreId).set(fsFields, SetOptions(merge: true));
          }
          else if (type == 'delete_donation') {
            final firestoreId = action['firestoreId'] as String?;
            final bId = _cleanBranch(action['branchId'] ?? branchId);
            if (firestoreId != null && firestoreId.isNotEmpty) {
              await _db.collection('donations').doc(firestoreId).delete().catchError((_) {});
              if (bId.isNotEmpty && bId != 'all') {
                try {
                  await _db.collection('branches').doc(bId).collection('donations').doc(firestoreId).delete();
                } catch (_) {}
              } else {
                try {
                  final bSnap = await _db.collection('branches').get();
                  for (final bDoc in bSnap.docs) {
                    await _db.collection('branches').doc(bDoc.id).collection('donations').doc(firestoreId).delete().catchError((_) {});
                  }
                } catch (_) {}
              }
            }
          }
          else if (type == 'delete_donor') {
            final donorId = action['donorId'] as String?;
            if (donorId != null) await _db.collection('donors').doc(donorId).delete();
          }
          else if (type == 'delete_donor_branch') {
            final donorId = action['donorId'] as String?;
            final rawBId  = action['branchId'] as String?;
            final bId     = rawBId == null ? null : _cleanBranch(rawBId);
            if (donorId != null && bId != null) await _db.collection('branches').doc(bId).collection('donors').doc(donorId).delete();
          }
          else if (type == 'save_bank_slip') {
            final data   = Map<String, dynamic>.from(action['data'] ?? {});
            final slipId = action['slipId'] as String?;
            final fsData = Map<String, dynamic>.from(data)..remove('syncStatus');
            final docRef = _db.collection('branches').doc(branchId).collection('bank_slips').doc(slipId);
            await docRef.set(fsData, SetOptions(merge: true));
            if (slipId != null) await DonationsLocalStorage.markBankSlipSynced(slipId, docRef.id);
          }
          else if (type == 'save_employee') {
            final data = Map<String, dynamic>.from(action['data'] ?? {});
            if (FinanceLocalStorage.isPlaceholderEmployee(data)) {
              // Silently delete placeholder employee from queue to avoid infinite backlog
              await queueBox.delete(key);
              return;
            }
            final localId = action['localId']?.toString() ?? data['localId']?.toString();
            final bId = _cleanBranch(action['branchId'] ?? data['branchId'] ?? branchId);
            if (localId == null || localId.isEmpty) throw Exception('Missing localId');

            for (final f in ['dob', 'cnicExpiry', 'joiningDate', 'exitDate']) {
              if (data[f] is String) {
                try {
                  data[f] = Timestamp.fromDate(DateTime.parse(data[f] as String));
                } catch (_) {}
              }
            }
            if (data['createdAt'] is String) {
              try {
                data['createdAt'] = Timestamp.fromDate(DateTime.parse(data['createdAt'] as String));
              } catch (_) {}
            }

            final fsData = LocalStorageService.sanitizeForCloudUpload(data);
            await _db.collection('branches').doc(bId).collection('employees').doc(localId).set(fsData, SetOptions(merge: true));
            await _db.collection('employees').doc(localId).set(fsData, SetOptions(merge: true)).catchError((_) {});
            
            if (Hive.isBoxOpen(LocalStorageService.employeesBox)) {
              final box = Hive.box(LocalStorageService.employeesBox);
              final localRecord = box.get(localId);
              if (localRecord is Map) {
                final updated = Map<String, dynamic>.from(localRecord)
                  ..['syncStatus'] = 'synced'
                  ..['remoteId'] = localId
                  ..['lastSyncedAt'] = DateTime.now().toUtc().toIso8601String();
                await box.put(localId, updated);
              }
            }
          }
          else if (type == 'delete_employee') {
            final localId = action['localId']?.toString();
            final bId = _cleanBranch(action['branchId'] ?? branchId);
            if (localId == null || localId.isEmpty) throw Exception('Missing localId');

            await _db.collection('branches').doc(bId).collection('employees').doc(localId).delete().catchError((_) {});
            await _db.collection('employees').doc(localId).delete().catchError((_) {});
          }
          else if (type == 'save_user') {
            final rawData = Map<String, dynamic>.from(action['data'] ?? {});
            final Map<String, dynamic> data;
            if (rawData.containsKey('updates') && rawData['updates'] is Map) {
              data = {
                ...rawData,
                ...Map<String, dynamic>.from(rawData['updates'] as Map),
              }..remove('updates');
            } else {
              data = rawData;
            }
            final uid = action['uid']?.toString() ?? data['uid']?.toString() ?? data['id']?.toString();
            String rawBId = (action['branchId'] ?? data['branchId'] ?? branchId ?? '').toString().trim();
            if (rawBId.isEmpty || rawBId == 'all' || rawBId == 'global' || rawBId == 'none') {
              final email = (data['email'] ?? '').toString().toLowerCase();
              if (email.contains('@khi.com') || email.contains('@saddar.com') || email.contains('@server.com')) {
                rawBId = 'karachi';
              } else if (email.contains('@grt.com')) {
                rawBId = 'gujrat';
              } else if (email.contains('@skt.com')) {
                rawBId = 'sialkot';
              } else if (email.contains('@jlj.com')) {
                rawBId = 'jalalpurjattan';
              } else if (email.contains('@rwp.com')) {
                rawBId = 'rawalpindi';
              } else {
                rawBId = _cleanBranch(null);
              }
            }
            final bId = _cleanBranch(rawBId);
            if (uid == null || uid.isEmpty) throw Exception('Missing uid');

            final fsData = LocalStorageService.sanitizeForCloudUpload(data);
            if (bId.isNotEmpty && bId != 'all' && bId != 'global') {
              if (fsData['branchId'] == null || fsData['branchId'] == 'all' || fsData['branchId'] == 'global' || fsData['branchId'].toString().isEmpty) {
                fsData['branchId'] = bId;
              }
            }
            // Explicitly revive and activate the account so any previous tombstone is completely overwritten
            fsData['isDeleted'] = false;
            fsData['status'] = 'active';
            fsData['accountStatus'] = 'active';
            fsData['isActive'] = true;
            fsData['isRevoked'] = false;
            fsData['accessRevoked'] = false;
            fsData['isCorruptedOrOrphanAuth'] = false;
            fsData.remove('deletedAt');
            fsData.remove(null);
            fsData.remove('null');
            fsData['updatedAt'] = FieldValue.serverTimestamp();

            final email = (fsData['email'] ?? '').toString().trim().toLowerCase();
            final rawUser = (fsData['username'] ?? fsData['usernameLower'] ?? (email.isNotEmpty ? email.split('@').first : '')).toString().trim();
            if (rawUser.isNotEmpty) {
              fsData['username'] = rawUser;
              fsData['usernameLower'] = rawUser.toLowerCase();
            }

            // Write user to root collection /users and branch subcollection with timeout.
            // remove('deletedAt') above only leaves the key out of a merge write, so the cloud kept
            // it and HomeRouter showed "Access Revoked" for restored accounts; delete it for real.
            final cloudUser = {...fsData, 'deletedAt': FieldValue.delete()};
            await _db.collection('users').doc(uid).set(cloudUser, SetOptions(merge: true));
            if (bId.isNotEmpty && bId != 'all' && bId != 'global') {
              await _db.collection('branches').doc(bId).collection('users').doc(uid).set(cloudUser, SetOptions(merge: true)).catchError((_) {});
            }

            final uLower = (fsData['usernameLower'] ?? fsData['username'] ?? '').toString().trim().toLowerCase();
            if (uLower.isNotEmpty && uLower != uid) {
              await _db.collection('users').doc(uLower).delete().catchError((_) {});
            }

            try {
              if (Hive.isBoxOpen('local_users')) {
                final box = Hive.box('local_users');
                final email = (fsData['email'] ?? '').toString().trim().toLowerCase();
                final existing = box.get('user:$uid') ?? box.get(uid) ?? (email.isNotEmpty ? box.get('user:$email') : null);
                final mergedData = existing is Map ? (Map<String, dynamic>.from(existing)..addAll(fsData)) : fsData;
                if (email.isNotEmpty) await box.put('user:$email', mergedData);
                await box.put('user:$uid', mergedData);
                await box.put(uid, mergedData);
                await box.flush();
              }
            } catch (_) {}
          }
          else if (type == 'delete_user') {
            final uid = (action['uid'] ?? action['id'] ?? '').toString().trim();
            final bId = action['branchId']?.toString() ?? branchId;
            final email = action['email']?.toString().trim().toLowerCase() ?? '';
            final username = action['username']?.toString().trim().toLowerCase() ?? '';
            final identifiers = {uid, username, email}.where((s) => s.isNotEmpty).toSet();

            // Check if there is an active user locally or in cloud with a different UID
            if (Hive.isBoxOpen('local_users')) {
              final box = Hive.box('local_users');
              final local = box.get('user:$username') ?? box.get(username) ?? (email.isNotEmpty ? box.get('user:$email') : null);
              if (local is Map) {
                final localUid = (local['uid'] ?? local['id'] ?? '').toString().trim();
                final localStatus = (local['status'] ?? local['accountStatus'] ?? '').toString().toLowerCase().trim();
                final localDeleted = local['isDeleted'] == true || localStatus == 'deleted';
                if (!localDeleted && localUid.isNotEmpty && uid.isNotEmpty && localUid != uid) {
                  // User was re-created with a new UID! Discard this stale delete action.
                  debugPrint('[SyncService] Discarding stale delete_user for $username: user was re-created with new UID $localUid');
                  await queueBox.delete(key);
                  return;
                }
              }
            }

            final deletePayload = {
              'isDeleted': true,
              'status': 'deleted',
              'accountStatus': 'deleted',
              'deletedAt': FieldValue.serverTimestamp(),
            };

            // 1. Direct document tombstones and permanent Firebase Auth deletion
            try {
              await AuthService.deleteAuthUser(
                uid: uid,
                email: email,
                username: username,
                branchId: bId,
              );
            } catch (_) {}

            if (uid.isNotEmpty) {
              await _db.collection('users').doc(uid).set(deletePayload, SetOptions(merge: true)).catchError((_) {});
              if (bId != 'all' && bId.isNotEmpty) {
                await _db.collection('branches').doc(bId).collection('users').doc(uid).set(deletePayload, SetOptions(merge: true)).catchError((_) {});
              }
            }

            // Remove any shadow documents at users/username or users/email
            if (username.isNotEmpty) {
              await _db.collection('users').doc(username).delete().catchError((_) {});
            }
            if (email.isNotEmpty) {
              await _db.collection('users').doc(email).delete().catchError((_) {});
            }

            // 2. Query root collection 'users' - ONLY tombstone docs matching target UID
            if (uid.isNotEmpty) {
              try {
                final snap = await _db.sdk.collection('users').where('uid', isEqualTo: uid).get();
                for (final doc in snap.docs) {
                  await _db.ref(doc.reference).set(deletePayload, SetOptions(merge: true)).catchError((_) {});
                }
              } catch (_) {}
            } else {
              if (username.isNotEmpty) {
                try {
                  final snap = await _db.sdk.collection('users').where('usernameLower', isEqualTo: username).get();
                  for (final doc in snap.docs) {
                    await _db.ref(doc.reference).set(deletePayload, SetOptions(merge: true)).catchError((_) {});
                  }
                } catch (_) {}
              }
              if (email.isNotEmpty) {
                try {
                  final snap = await _db.sdk.collection('users').where('email', isEqualTo: email).get();
                  for (final doc in snap.docs) {
                    await _db.ref(doc.reference).set(deletePayload, SetOptions(merge: true)).catchError((_) {});
                  }
                } catch (_) {}
              }
            }

            // 3. Query all branch sub-collections (collectionGroup)
            try {
              if (uid.isNotEmpty) {
                final gSnap = await _db.collectionGroup('users').where('uid', isEqualTo: uid).get();
                for (final doc in gSnap.docs) {
                  await _db.ref(doc.reference).set(deletePayload, SetOptions(merge: true)).catchError((_) {});
                }
              }
            } catch (_) {}
            // Fallback to iterating branches collection
            try {
              final branchDocs = await _db.collection('branches').get();
              for (final bDoc in branchDocs.docs) {
                for (final identifier in identifiers) {
                  await _db.ref(bDoc.reference).collection('users').doc(identifier).set(deletePayload, SetOptions(merge: true)).catchError((_) {});
                }
              }
            } catch (_) {}

            // 4. Ensure purged from local Hive box
            try {
              if (Hive.isBoxOpen('local_users')) {
                final box = Hive.box('local_users');
                for (final id in identifiers) {
                  await box.delete(id);
                  await box.delete('user:$id');
                }
                await box.flush();
              }
            } catch (_) {}
          }
          else if (type == 'access_restore_request') {
            final uid = (action['userId'] ?? action['uid'])?.toString() ?? '';
            final branch = (action['branchId'])?.toString() ?? 'all';
            final note = (action['reason'])?.toString() ?? '';
            final reqPayload = {
              'restoreRequested': true,
              'restoreRequestStatus': 'pending',
              'restoreRequestedAt': FieldValue.serverTimestamp(),
              'restoreRequestReason': note,
              'updatedAt': FieldValue.serverTimestamp(),
            };
            if (uid.isNotEmpty) {
              await _db.collection('users').doc(uid).set(reqPayload, SetOptions(merge: true)).catchError((_) {});
              if (branch.isNotEmpty && branch != 'all' && branch != 'global') {
                await _db.collection('branches').doc(branch).collection('users').doc(uid).set(reqPayload, SetOptions(merge: true)).catchError((_) {});
              }
            }
          }
          else if (type == 'save_salary_history') {
            final data = Map<String, dynamic>.from(action['data'] ?? {});
            final employeeId = action['employeeId']?.toString();
            final historyId = action['historyId']?.toString();
            final bId = action['branchId']?.toString() ?? branchId;
            if (employeeId == null || historyId == null) throw Exception('Missing keys');

            if (data['effectiveDate'] is String) {
              try {
                data['effectiveDate'] = Timestamp.fromDate(DateTime.parse(data['effectiveDate'] as String));
              } catch (_) {}
            }
            if (data['createdAt'] is String) {
              try {
                data['createdAt'] = Timestamp.fromDate(DateTime.parse(data['createdAt'] as String));
              } catch (_) {}
            }

            final fsData = Map<String, dynamic>.from(data)..remove('syncStatus');
            await _db.collection('branches').doc(bId).collection('employees').doc(employeeId).collection('salary_history').doc(historyId).set(fsData, SetOptions(merge: true));

            final box = Hive.box(LocalStorageService.salaryHistoryBox);
            final key = '${employeeId}_$historyId';
            final localRecord = box.get(key);
            if (localRecord is Map) {
              final updated = Map<String, dynamic>.from(localRecord)
                ..['syncStatus'] = 'synced'
                ..['remoteId'] = historyId
                ..['lastSyncedAt'] = DateTime.now().toUtc().toIso8601String();
              await box.put(key, updated);
            }
          }
          else if (type == 'save_attendance_record' ||
              type == 'save_biometric_log' ||
              type == 'save_employee_attendance' ||
              type == 'save_attendance') {
            final data = Map<String, dynamic>.from(action['data'] ?? {});
            final dateStr = (action['date'] ??
                    action['dateKey'] ??
                    data['date'] ??
                    data['dateKey'] ??
                    DateFormat('yyyy-MM-dd').format(DateTime.now()))
                .toString();
            final employeeId = (action['employeeId'] ??
                    data['employeeId'] ??
                    data['empId'] ??
                    data['userId'])
                ?.toString();
            final bId = (action['branchId'] ?? data['branchId'] ?? branchId).toString();
            final logId = (action['localId'] ?? data['id'] ?? data['logId'] ?? key).toString();
            if (employeeId == null || employeeId.isEmpty) throw Exception('Missing employeeId');

            if (data['markedAt'] is String) {
              try {
                data['markedAt'] = Timestamp.fromDate(DateTime.parse(data['markedAt'] as String));
              } catch (_) {}
            }
            if (data['timestamp'] is String) {
              try {
                data['timestamp'] = Timestamp.fromDate(DateTime.parse(data['timestamp'] as String));
              } catch (_) {}
            }

            final fsData = LocalStorageService.sanitizeForCloudUpload(data);
            fsData['lastSyncedAt'] = FieldValue.serverTimestamp();

            // Quota optimization: only touch parent date document once per upload pass
            final headerKey = '$bId###$dateStr';
            if (!updatedAttendanceHeaders.contains(headerKey)) {
              updatedAttendanceHeaders.add(headerKey);
              await _db.collection('branches').doc(bId).collection('employee_attendance').doc(dateStr).set({
                'date': dateStr,
                'branchId': bId,
                'lastUpdated': FieldValue.serverTimestamp(),
              }, SetOptions(merge: true));
            }
            await _db
                .collection('branches')
                .doc(bId)
                .collection('employee_attendance')
                .doc(dateStr)
                .collection('records')
                .doc(employeeId)
                .set(fsData, SetOptions(merge: true));

            // Mirror to primary Karachi branch doc if this is a Karachi sub-camp
            if (bId != 'karachi' && CampSessionService.isKarachiFamily(bId)) {
              await _db
                  .collection('branches')
                  .doc('karachi')
                  .collection('employee_attendance')
                  .doc(dateStr)
                  .collection('records')
                  .doc(employeeId)
                  .set(fsData, SetOptions(merge: true))
                  .catchError((_) {});
            }

            if (type == 'save_biometric_log' || action['punchSequence'] != null) {
              await _db.collection('branches').doc(bId).collection('biometric_logs').doc(logId).set(fsData, SetOptions(merge: true)).catchError((_) {});
            }

            if (Hive.isBoxOpen(LocalStorageService.attendanceBox)) {
              final aBox = Hive.box(LocalStorageService.attendanceBox);
              final hKey = '${employeeId}_$dateStr';
              final keysToCheck = <dynamic>{
                hKey,
                if (action['localKey'] != null) action['localKey'],
                if (action['localId'] != null) action['localId'],
              };
              for (final k in keysToCheck) {
                if (aBox.containsKey(k)) {
                  final rec = aBox.get(k);
                  if (rec is Map) {
                    final updated = Map<String, dynamic>.from(rec)
                      ..['syncStatus'] = 'synced'
                      ..['synced'] = true
                      ..['pendingSync'] = false
                      ..['remoteId'] = employeeId
                      ..['lastSyncedAt'] = DateTime.now().toUtc().toIso8601String();
                    await aBox.put(k, updated);
                  }
                }
              }
              if (Hive.isBoxOpen('app_flags')) {
                final flags = Hive.box('app_flags');
                for (final k in keysToCheck) {
                  await flags.put('attendance_synced_$k', true);
                }
                await flags.put('attendance_synced_${employeeId}_$dateStr', true);
              }
            }
          }
          else if (type == 'send_notification') {
            final data = Map<String, dynamic>.from(action['data'] ?? {});
            final notifId = (action['localId'] ?? data['id'] ?? const Uuid().v4()).toString();
            final bId = (action['branchId'] ?? data['branchId'] ?? branchId).toString();

            final fsData = Map<String, dynamic>.from(data);
            fsData['timestamp'] = FieldValue.serverTimestamp();

            await _db.collection('branches').doc(bId).collection('notifications').doc(notifId).set(fsData, SetOptions(merge: true));
          }
          else if (type == 'save_salary_ledger') {
            final data = Map<String, dynamic>.from(action['data'] ?? {});
            final recordId = action['recordId']?.toString();
            final bId = action['branchId']?.toString() ?? branchId;
            if (recordId == null) throw Exception('Missing recordId');

            for (final f in ['date', 'createdAt', 'voidedAt']) {
              if (data[f] is String) {
                try {
                  data[f] = Timestamp.fromDate(DateTime.parse(data[f] as String));
                } catch (_) {}
              }
            }

            final fsData = Map<String, dynamic>.from(data)..remove('syncStatus');
            final employeeDocRef = _db.collection('branches').doc(bId).collection('employees').doc(data['employeeId'] as String);
            final ledgerDocRef = _db.collection('branches').doc(bId).collection('employee_salaries').doc(recordId);

            // GMWF v2 Conflict Check
            final remoteDoc = await ledgerDocRef.get();
            if (remoteDoc.exists) {
              final remoteData = remoteDoc.data();
              if (remoteData != null) {
                final remoteVoid = remoteData['isVoided'] == true;
                final localVoid = data['isVoided'] == true;
                if (remoteVoid != localVoid || (remoteVoid && localVoid && remoteData['voidReason'] != data['voidReason'])) {
                  await _handleSyncConflict(bId, recordId, 'salary_ledger', data, remoteData);
                  await queueBox.delete(key);
                  return;
                }
              }
            }

            await _db.runTransaction((transaction) async {
              transaction.set(ledgerDocRef, fsData, SetOptions(merge: true));
              
              final ledgerType = data['type']?.toString();
              final amount = (data['amount'] as num?)?.toDouble() ?? 0.0;
              final amountMinor = (data['amountMinor'] as num?)?.toInt() ?? (amount * 100).round();
              final isVoided = data['isVoided'] == true;
              
              double delta = 0.0;
              int deltaMinor = 0;
              if (ledgerType == 'advance_payment') {
                delta = isVoided ? -amount : amount;
                deltaMinor = isVoided ? -amountMinor : amountMinor;
              } else if (ledgerType == 'payout') {
                final recovery = (data['advanceDeductions'] as num?)?.toDouble() ?? 0.0;
                final recoveryMinor = (data['advanceDeductionsMinor'] as num?)?.toInt() ?? (recovery * 100).round();
                delta = isVoided ? recovery : -recovery;
                deltaMinor = isVoided ? recoveryMinor : -recoveryMinor;
              }

              if (delta != 0) {
                transaction.update(employeeDocRef, {
                  'currentAdvanceBalance': FieldValue.increment(delta),
                  'currentAdvanceBalanceMinor': FieldValue.increment(deltaMinor),
                });
              }
            });

            final box = Hive.box(LocalStorageService.salaryLedgerBox);
            final localRecord = box.get(recordId);
            if (localRecord is Map) {
              final updated = Map<String, dynamic>.from(localRecord)
                ..['syncStatus'] = 'synced'
                ..['remoteId'] = recordId
                ..['lastSyncedAt'] = DateTime.now().toUtc().toIso8601String();
              await box.put(recordId, updated);
            }
          }
          else if (type == 'save_finance_settings') {
            final data = Map<String, dynamic>.from(action['data'] ?? {});
            final bId = action['branchId']?.toString() ?? branchId;

            final fsData = Map<String, dynamic>.from(data)..remove('syncStatus');
            await _db.collection('branches').doc(bId).collection('settings').doc('workSchedule').set(fsData, SetOptions(merge: true));

            final box = Hive.box(LocalStorageService.financeSettingsBox);
            final localRecord = box.get(bId);
            if (localRecord is Map) {
              final updated = Map<String, dynamic>.from(localRecord)
                ..['syncStatus'] = 'synced'
                ..['lastSyncedAt'] = DateTime.now().toUtc().toIso8601String();
              await box.put(bId, updated);
            }
          }
          else if (type == 'save_branch_transfer') {
            final data = Map<String, dynamic>.from(action['data'] ?? {});
            final transferId = action['transferId']?.toString();
            final employeeId = action['employeeId']?.toString();
            final fromBranch = action['fromBranchId']?.toString();
            final toBranch = action['toBranchId']?.toString();

            if (transferId == null || employeeId == null || fromBranch == null || toBranch == null) {
              throw Exception('Missing transfer arguments');
            }

            if (data['effectiveDate'] is String) {
              try {
                data['effectiveDate'] = Timestamp.fromDate(DateTime.parse(data['effectiveDate'] as String));
              } catch (_) {}
            }
            if (data['createdAt'] is String) {
              try {
                data['createdAt'] = Timestamp.fromDate(DateTime.parse(data['createdAt'] as String));
              } catch (_) {}
            }

            final fsData = Map<String, dynamic>.from(data)..remove('syncStatus');

            final fromEmpRef = _db.collection('branches').doc(fromBranch).collection('employees').doc(employeeId);
            final toEmpRef = _db.collection('branches').doc(toBranch).collection('employees').doc(employeeId);
            final transferRef = _db.collection('branches').doc(toBranch).collection('employees').doc(employeeId).collection('branch_transfers').doc(transferId);

            await _db.runTransaction((transaction) async {
              final snapshot = await transaction.get(fromEmpRef);
              if (snapshot.exists) {
                final empData = Map<String, dynamic>.from(snapshot.data() ?? {});
                empData['branchId'] = toBranch;
                
                transaction.set(toEmpRef, empData, SetOptions(merge: true));
                transaction.delete(fromEmpRef);
                transaction.set(transferRef, fsData, SetOptions(merge: true));
              }
            });

            final box = Hive.box(LocalStorageService.branchTransfersBox);
            final localRecord = box.get(transferId);
            if (localRecord is Map) {
              final updated = Map<String, dynamic>.from(localRecord)
                ..['syncStatus'] = 'synced'
                ..['remoteId'] = transferId
                ..['lastSyncedAt'] = DateTime.now().toUtc().toIso8601String();
              await box.put(transferId, updated);
            }
          }
          else if (type == 'delete_biometric_device') {
            final deviceId = (action['deviceId'] ?? action['id'] ?? action['localId'])?.toString().trim();
            final bId = LocalStorageService.sanitizeBranchId(action['branchId'], fallback: 'karachi');
            if (deviceId != null && deviceId.isNotEmpty) {
              final candidateBranches = <String>{bId, 'karachi', 'saddar', 'haji_camp', 'main'};
              for (final cand in candidateBranches) {
                try {
                  await _db.collection('branches').doc(cand).collection('biometric_devices').doc(deviceId).delete();
                } catch (_) {}
              }
              try {
                await _db.collection('biometric_devices').doc(deviceId).delete();
              } catch (_) {}
              try {
                final groupSnap = await _db.collectionGroup('biometric_devices').get();
                for (final doc in groupSnap.docs) {
                  final d = doc.data();
                  if (doc.id == deviceId || d['deviceId'] == deviceId) {
                    await _db.ref(doc.reference).delete();
                  }
                }
              } catch (_) {}
            }
          }
          else if (type == 'save_biometric_device') {
            final deviceId = (action['deviceId'] ?? action['id'])?.toString().trim();
            final data = Map<String, dynamic>.from(action['data'] ?? {});
            final bId = LocalStorageService.sanitizeBranchId(action['branchId'] ?? data['branchId'], fallback: 'karachi');
            if (deviceId != null && deviceId.isNotEmpty) {
              data['updatedAt'] = FieldValue.serverTimestamp();
              await _db.collection('branches').doc(bId).collection('biometric_devices').doc(deviceId).set(data, SetOptions(merge: true));
            }
          }
          else if (type == 'save_finance_holiday') {
            final data = Map<String, dynamic>.from(action['data'] ?? {});
            final holidayId = action['holidayId']?.toString();
            final bId = action['branchId']?.toString() ?? branchId;
            if (holidayId == null) throw Exception('Missing holidayId');

            if (data['date'] is String) {
              try {
                data['date'] = Timestamp.fromDate(DateTime.parse(data['date'] as String));
              } catch (_) {}
            }
            if (data['updatedAt'] is String) {
              try {
                data['updatedAt'] = Timestamp.fromDate(DateTime.parse(data['updatedAt'] as String));
              } catch (_) {}
            }

            final fsData = Map<String, dynamic>.from(data)..remove('syncStatus');
            await _db.collection('branches').doc(bId).collection('finance_holidays').doc(holidayId).set(fsData, SetOptions(merge: true));

            final box = Hive.box(LocalStorageService.financeHolidaysBox);
            final key = '${bId.toLowerCase().trim()}__hol__$holidayId';
            final localRecord = box.get(key);
            if (localRecord is Map) {
              final updated = Map<String, dynamic>.from(localRecord)
                ..['syncStatus'] = 'synced'
                ..['remoteId'] = holidayId
                ..['lastSyncedAt'] = DateTime.now().toUtc().toIso8601String();
              await box.put(key, updated);
            }
          }
          else if (type == 'delete_finance_holiday') {
            final holidayId = action['holidayId']?.toString();
            final bId = action['branchId']?.toString() ?? branchId;
            if (holidayId == null) throw Exception('Missing holidayId');

            await _db.collection('branches').doc(bId).collection('finance_holidays').doc(holidayId).delete();
          }
          else if (type == 'save_finance_loan') {
            final data = Map<String, dynamic>.from(action['data'] ?? {});
            final loanId = action['loanId']?.toString();
            final bId = action['branchId']?.toString() ?? branchId;
            if (loanId == null) throw Exception('Missing loanId');

            for (final f in ['dateIssued', 'closedAt', 'createdAt', 'updatedAt']) {
              if (data[f] is String) {
                try {
                  data[f] = Timestamp.fromDate(DateTime.parse(data[f] as String));
                } catch (_) {}
              }
            }

            if (data['payments'] is List) {
              final paymentsList = List<dynamic>.from(data['payments'] as List);
              final convertedPayments = <Map<String, dynamic>>[];
              for (final p in paymentsList) {
                if (p is Map) {
                  final pMap = Map<String, dynamic>.from(p);
                  for (final f in ['date', 'createdAt', 'voidedAt']) {
                    if (pMap[f] is String) {
                      try {
                        pMap[f] = Timestamp.fromDate(DateTime.parse(pMap[f] as String));
                      } catch (_) {}
                    }
                  }
                  convertedPayments.add(pMap);
                }
              }
              data['payments'] = convertedPayments;
            }

            // GMWF v2 Conflict Check
            final loanDocRef = _db.collection('branches').doc(bId).collection('finance_loans').doc(loanId);
            final remoteDoc = await loanDocRef.get();
            if (remoteDoc.exists) {
              final remoteData = remoteDoc.data();
              if (remoteData != null) {
                final remotePayments = List<dynamic>.from(remoteData['payments'] as List? ?? []);
                final localPayments = List<dynamic>.from(data['payments'] as List? ?? []);
                
                bool hasConflict = false;
                for (final lp in localPayments) {
                  if (lp is Map) {
                    final rp = remotePayments.firstWhereOrNull((p) => p['id'] == lp['id']);
                    if (rp is Map && rp['isVoided'] == true && lp['isVoided'] == true && rp['voidReason'] != lp['voidReason']) {
                      hasConflict = true;
                      break;
                    }
                  }
                }
                
                if (hasConflict) {
                  await _handleSyncConflict(bId, loanId, 'loan', data, remoteData);
                  await queueBox.delete(key);
                  return;
                }
              }
            }

            final fsData = Map<String, dynamic>.from(data)..remove('syncStatus');
            await loanDocRef.set(fsData, SetOptions(merge: true));

            final box = Hive.box(LocalStorageService.financeLoansBox);
            final localRecord = box.get(loanId);
            if (localRecord is Map) {
              final updated = Map<String, dynamic>.from(localRecord)
                ..['syncStatus'] = 'synced'
                ..['remoteId'] = loanId
                ..['lastSyncedAt'] = DateTime.now().toUtc().toIso8601String();
              await box.put(loanId, updated);
            }
          }
          else if (type == 'save_audit_log') {
            final data = Map<String, dynamic>.from(action['data'] ?? {});
            final logId = data['id']?.toString() ?? action['localId']?.toString();
            final bId = action['branchId']?.toString() ?? data['branchContext']?.toString() ?? branchId;
            if (logId == null) throw Exception('Missing logId');

            for (final f in ['timestamp', 'updatedAt']) {
              if (data[f] is String) {
                try {
                  data[f] = Timestamp.fromDate(DateTime.parse(data[f] as String));
                } catch (_) {}
              }
            }

            final fsData = Map<String, dynamic>.from(data)..remove('syncStatus');
            
            // Mirror to branch collection and global_audit_logs collection
            await _db.collection('branches').doc(bId).collection('audit_logs').doc(logId).set(fsData, SetOptions(merge: true));
            await _db.collection('global_audit_logs').doc(logId).set(fsData, SetOptions(merge: true));

            final box = Hive.box(LocalStorageService.auditLogsBox);
            final localRecord = box.get(logId);
            if (localRecord is Map) {
              final updated = Map<String, dynamic>.from(localRecord)
                ..['syncStatus'] = 'synced'
                ..['remoteId'] = logId
                ..['lastSyncedAt'] = DateTime.now().toUtc().toIso8601String();
              await box.put(logId, updated);
            }
          }
          else if (type == 'save_dasterkhwan_tokens' || type == 'save_food_token' || type == 'save_dasterkhwan_entry') {
            final data = Map<String, dynamic>.from(action['data'] ?? {});
            final rawBId = action['branchId']?.toString() ?? data['branchId']?.toString() ?? branchId;
            final bId = _cleanBranch(rawBId);
            final dateKey = (action['dateKey'] ?? data['dateKey'] ?? DateTime.now().toIso8601String().substring(0, 10)).toString();
            final tokensList = List<dynamic>.from(data['tokens'] as List? ?? []);
            final qty = (data['quantity'] as num?)?.toInt() ?? tokensList.length;
            final session = data['session']?.toString() ?? 'lunch';
            final batchId = (action['batchId'] ?? action['entityId'] ?? data['batchId'])?.toString();

            final dayDocRef = _db
                .collection('branches')
                .doc(bId)
                .collection('dasterkhwaan')
                .doc(dateKey);

            // Check if this batch was already applied by direct write to avoid double counting!
            bool alreadyApplied = false;
            if (batchId != null && batchId.isNotEmpty) {
              try {
                final daySnap = await dayDocRef.get().timeout(const Duration(seconds: 4));
                if (daySnap.exists) {
                  final applied = (daySnap.data()?['appliedBatches'] as List?)?.map((e) => e.toString()).toSet() ?? {};
                  if (applied.contains(batchId)) {
                    alreadyApplied = true;
                  }
                }
              } catch (_) {}
            }

            final tokensColRef = dayDocRef.collection('tokens');

            final batch = _db.batch();
            for (final t in tokensList) {
              if (t is Map) {
                final tMap = Map<String, dynamic>.from(t);
                final tokenId = tMap['id']?.toString() ?? tokensColRef.doc().id;
                final fsToken = {
                  'number': tMap['number'] ?? 1,
                  // Only ever set served: the kitchen PC may have served the token (and
                  // uploaded that) before this issue upload landed; served:false undid it.
                  if (tMap['served'] == true) 'served': true,
                  'session': tMap['session'] ?? session,
                  'time': tMap['time'] != null
                      ? Timestamp.fromDate(DateTime.tryParse(tMap['time'].toString()) ?? DateTime.now())
                      : FieldValue.serverTimestamp(),
                  'issuedBy': tMap['issuedBy'] ?? '',
                  'localId': tokenId,
                  'branchId': bId,
                  'dateKey': dateKey,
                  // Kept (direct writes include it); dropping it made downloads assume 10.
                  if ((tMap['pricePerToken'] ?? data['pricePerToken']) != null)
                    'pricePerToken': tMap['pricePerToken'] ?? data['pricePerToken'],
                };
                batch.set(tokensColRef.doc(tokenId), fsToken, SetOptions(merge: true));
              }
            }

            // Session totals from each token's own session: a backfill batch has no batch-level
            // session, so every token used to land in one session's total.
            final perSession = <String, int>{};
            for (final t in tokensList) {
              if (t is Map) {
                final s = (t['session'] ?? session).toString();
                perSession[s] = (perSession[s] ?? 0) + 1;
              }
            }
            final sessionCounts = perSession.values.fold<int>(0, (a, b) => a + b) == qty
                ? perSession
                : {session.toString(): qty};

            final dayUpdate = <String, dynamic>{
              if (!alreadyApplied) 'totalTokens': FieldValue.increment(qty),
              if (!alreadyApplied)
                for (final e in sessionCounts.entries) 'session_${e.key}_total': FieldValue.increment(e.value),
              if (batchId != null) 'appliedBatches': FieldValue.arrayUnion([batchId]),
              'lastUpdated': FieldValue.serverTimestamp(),
              'dateKey': dateKey,
              'branchId': bId,
            };

            if (!alreadyApplied) {
              await dayDocRef.set(dayUpdate, SetOptions(merge: true));
            }

            try {
              await batch.commit();
            } catch (tokErr) {
              debugPrint('[SyncService] Individual subcollection tokens commit deferred: $tokErr');
            }

            try {
              if (Hive.isBoxOpen('dasterkhwaan_tokens')) {
                final tBox = Hive.box('dasterkhwaan_tokens');
                for (final t in tokensList) {
                  if (t is Map && t['id'] != null) {
                    final loc = tBox.get(t['id']);
                    if (loc is Map) {
                      await tBox.put(t['id'], Map<String, dynamic>.from(loc)
                        ..['syncStatus'] = 'synced'
                        ..['synced'] = true);
                    }
                  }
                }
              }
            } catch (_) {}
          }
          else if (type == 'reverse_dasterkhwan_tokens') {
            final data = Map<String, dynamic>.from(action['data'] ?? {});
            final rawBId = action['branchId']?.toString() ?? data['branchId']?.toString() ?? branchId;
            final bId = _cleanBranch(rawBId);
            final dateKey = (action['dateKey'] ?? data['dateKey'] ?? DateTime.now().toIso8601String().substring(0, 10)).toString();
            final tokenIds = List<String>.from((data['tokenIds'] as List? ?? []).map((e) => e.toString()));
            final qty = (data['quantity'] as num?)?.toInt() ?? tokenIds.length;
            final sessionCounts = Map<String, dynamic>.from(data['sessionCounts'] ?? {});
            final revBatchId = (action['batchId'] ?? action['entityId'] ?? data['batchId'])?.toString();

            final dayDocRef = _db
                .collection('branches')
                .doc(bId)
                .collection('dasterkhwaan')
                .doc(dateKey);

            bool alreadyReversed = false;
            if (revBatchId != null && revBatchId.isNotEmpty) {
              try {
                final daySnap = await dayDocRef.get().timeout(const Duration(seconds: 4));
                if (daySnap.exists) {
                  final reversed = (daySnap.data()?['reversedBatchIds'] as List?)?.map((e) => e.toString()).toSet() ?? {};
                  if (reversed.contains(revBatchId)) {
                    alreadyReversed = true;
                  }
                }
              } catch (_) {}
            }

            final tokensColRef = dayDocRef.collection('tokens');
            final batch = _db.batch();

            for (final id in tokenIds) {
              batch.delete(tokensColRef.doc(id));
            }

            final dayUpdate = <String, dynamic>{
              if (!alreadyReversed) 'totalTokens': FieldValue.increment(-qty),
              if (revBatchId != null) 'reversedBatchIds': FieldValue.arrayUnion([revBatchId]),
              'lastUpdated': FieldValue.serverTimestamp(),
            };
            if (!alreadyReversed) {
              sessionCounts.forEach((s, cnt) {
                final cVal = (cnt as num?)?.toInt() ?? 0;
                if (cVal > 0) {
                  dayUpdate['session_${s}_total'] = FieldValue.increment(-cVal);
                }
              });
            }

            if (!alreadyReversed) {
              await dayDocRef.set(dayUpdate, SetOptions(merge: true));
            }

            try {
              await batch.commit();
            } catch (delErr) {
              debugPrint('[SyncService] Individual token deletes commit deferred: $delErr');
            }
          }
          else if (type == 'serve_dasterkhwan_token') {
            final data = Map<String, dynamic>.from(action['data'] ?? {});
            final bId = _cleanBranch(action['branchId']?.toString() ?? data['branchId']?.toString() ?? branchId);
            final dateKey = (action['dateKey'] ?? data['dateKey'] ?? DateTime.now().toIso8601String().substring(0, 10)).toString();
            final tokenId = data['tokenId']?.toString();
            final session = data['session']?.toString() ?? 'lunch';

            if (tokenId != null && tokenId.isNotEmpty) {
              final dayDocRef = _db
                  .collection('branches')
                  .doc(bId)
                  .collection('dasterkhwaan')
                  .doc(dateKey);

              bool alreadyServed = false;
              try {
                final daySnap = await dayDocRef.get().timeout(const Duration(seconds: 4));
                if (daySnap.exists) {
                  final servedIds = (daySnap.data()?['servedTokenIds'] as List?)?.map((e) => e.toString()).toSet() ?? {};
                  if (servedIds.contains(tokenId)) {
                    alreadyServed = true;
                  }
                }
              } catch (_) {}

              final tokensColRef = dayDocRef.collection('tokens');

              final batch = _db.batch();
              batch.set(tokensColRef.doc(tokenId), {
                'served': true,
                'servedTime': FieldValue.serverTimestamp(),
              }, SetOptions(merge: true));

              batch.set(dayDocRef, {
                if (!alreadyServed) 'servedTokens': FieldValue.increment(1),
                if (!alreadyServed) 'session_${session}_served': FieldValue.increment(1),
                'servedTokenIds': FieldValue.arrayUnion([tokenId]),
                'lastUpdated': FieldValue.serverTimestamp(),
              }, SetOptions(merge: true));

              await batch.commit();
            }
          }
          else if (type == 'save_dasterkhwan_food_log') {
            final data = Map<String, dynamic>.from(action['data'] ?? {});
            final rawBId = action['branchId']?.toString() ?? data['branchId']?.toString() ?? branchId;
            final bId = _cleanBranch(rawBId);
            final logId = (action['entityId'] ?? data['id'] ?? data['logId'])?.toString();
            if (logId != null && logId.isNotEmpty) {
              final payload = Map<String, dynamic>.from(data);
              payload['updatedAt'] = FieldValue.serverTimestamp();
              if (payload['createdAt'] != null && payload['createdAt'] is String) {
                final parsedDate = DateTime.tryParse(payload['createdAt'].toString());
                if (parsedDate != null) {
                  payload['timestamp'] = Timestamp.fromDate(parsedDate);
                }
              }
              await _db
                  .collection('branches')
                  .doc(bId)
                  .collection('dasterkhwaan_food_logs')
                  .doc(logId)
                  .set(payload, SetOptions(merge: true));

              try {
                if (Hive.isBoxOpen(LocalStorageService.dasterkhwaanFoodLogsBox)) {
                  final logBox = Hive.box(LocalStorageService.dasterkhwaanFoodLogsBox);
                  final local = logBox.get(logId);
                  if (local is Map) {
                    await logBox.put(
                      logId,
                      Map<String, dynamic>.from(local)
                        ..['syncStatus'] = 'synced'
                        ..['synced'] = true,
                    );
                  }
                }
              } catch (_) {}
            }
          }
          else if (type == 'save_madrassa_log' ||
              type == 'save_madrassa_daily_log' ||
              type == 'save_madrassa_attendance' ||
              type == 'enrollment' ||
              type == 'status_change' ||
              type == 'ptm_reschedule') {
            final dateKey = (action['dateKey'] ??
                    action['datePart'] ??
                    action['date'] ??
                    action['data']?['dateKey'] ??
                    action['data']?['date'] ??
                    DateFormat('yyyy-MM-dd').format(DateTime.now()))
                .toString();
            final bId = LocalStorageService.sanitizeBranchId(
              action['branchId'] ?? (action['data'] is Map ? action['data']['branchId'] : null),
              fallback: (branchId.isNotEmpty && branchId != 'all' && branchId != 'global') ? branchId : 'gujrat',
            );
            final rawPayload = action['data'] is Map
                ? action['data']
                : (action['logData'] is Map ? action['logData'] : action);
            final data = Map<String, dynamic>.from(rawPayload);
            data.remove('type');
            data.remove('branchId');
            data.remove('dateKey');
            data.remove('datePart');
            data.remove('date');
            data.remove('syncStatus');
            // These live inside the local day map; uploaded, they came back on every
            // PC's download as "pending" and the day was re-uploaded forever.
            data.remove('pendingSync');
            data.remove('synced');
            data.remove('lastSyncedAt');
            data.remove('localBox');
            data.remove('localKey');
            data.remove('syncId');
            data.remove('entityId');
            data.remove('attempts');
            data.remove('nextRetryAt');
            await _db.collection('branches').doc(bId).collection('madrassa_daily_logs').doc(dateKey).set(data, SetOptions(merge: true));
            if (Hive.isBoxOpen(LocalStorageService.madrassaLogsBox)) {
              final mBox = Hive.box(LocalStorageService.madrassaLogsBox);
              final lKey = action['localKey'] ?? '${bId}__log__$dateKey';
              final local = mBox.get(lKey);
              if (local is Map) {
                await mBox.put(lKey, Map<String, dynamic>.from(local)
                  ..['syncStatus'] = 'synced'
                  ..['synced'] = true
                  ..['pendingSync'] = false);
              }
            }
          }
          else if (type == 'save_madrassa_teacher_attendance') {
            final dateKey = (action['dateKey'] ?? action['datePart'] ?? action['data']?['dateKey'])?.toString();
            final bId = LocalStorageService.sanitizeBranchId(
              action['branchId'] ?? (action['data'] is Map ? action['data']['branchId'] : null),
              fallback: (branchId.isNotEmpty && branchId != 'all' && branchId != 'global') ? branchId : 'gujrat',
            );
            final data = Map<String, dynamic>.from(action['data'] ?? {});
            if (dateKey == null) throw Exception('Missing dateKey');
            for (final f in const ['syncStatus', 'pendingSync', 'synced', 'lastSyncedAt']) {
              data.remove(f);
            }
            data['lastUpdatedAt'] = FieldValue.serverTimestamp();
            final ref = _db.collection('branches').doc(bId).collection('madrassa_teacher_attendance').doc(dateKey);
            final entries = data['entries'] is Map ? Map<String, dynamic>.from(data['entries'] as Map) : <String, dynamic>{};
            final autoIds = entries.entries
                .where((e) => e.value is Map && (e.value as Map)['autoPresent'] == true)
                .map((e) => e.key)
                .toList();
            if (autoIds.isEmpty) {
              await ref.set(data, SetOptions(merge: true));
            } else {
              // An untouched teacher is saved as 'present' (autoPresent). It must not
              // replace a real status another PC already uploaded for that teacher.
              await _db.runTransaction((tx) async {
                final snap = await tx.get(ref);
                final cloudEntries = snap.data()?['entries'];
                final toWrite = Map<String, dynamic>.from(entries);
                if (cloudEntries is Map) {
                  for (final id in autoIds) {
                    final c = cloudEntries[id];
                    if (c is Map && c['autoPresent'] != true) toWrite.remove(id);
                  }
                }
                tx.set(ref, {...data, 'entries': toWrite}, SetOptions(merge: true));
              }).timeout(const Duration(seconds: 25));
            }
            // Mark the local copy synced, or the backfill re-uploaded it every sweep.
            if (Hive.isBoxOpen(LocalStorageService.madrassaLogsBox)) {
              final mBox = Hive.box(LocalStorageService.madrassaLogsBox);
              final rawB = (action['branchId'] ?? action['data']?['branchId'] ?? bId).toString().toLowerCase().trim();
              final lKey = '${rawB}__madrassa_tchlog__$dateKey';
              final local = mBox.get(lKey);
              if (local is Map && local['lastUpdated'] == action['data']?['lastUpdated']) {
                await mBox.put(lKey, Map<String, dynamic>.from(local)..['syncStatus'] = 'synced');
              }
            }
          }
          else if (type == 'save_donation_box') {
            final data = Map<String, dynamic>.from(action['data'] ?? {});
            final bId = LocalStorageService.sanitizeBranchId(action['branchId'] ?? data['branchId'], fallback: branchId);
            final boxId = (action['boxId'] ?? action['entityId'] ?? data['id'])?.toString();
            if (boxId == null || boxId.isEmpty) throw Exception('Missing boxId');

            // A box that came from the cloud keeps its cloud doc id (firestoreId); writing to
            // its local key created a second doc for the same box.
            final fsId = (data['firestoreId'] ?? '').toString().trim();
            final docId = fsId.isNotEmpty ? fsId : DonationBoxStorage.boxCloudDocId(boxId);
            final fsData = Map<String, dynamic>.from(data)
              ..remove('syncStatus')
              ..['id'] = docId;
            await _db.collection('branches').doc(bId).collection('donation_boxes').doc(docId).set(fsData, SetOptions(merge: true));

            if (Hive.isBoxOpen(DonationBoxStorage.boxesBoxName)) {
              final bBox = Hive.box(DonationBoxStorage.boxesBoxName);
              final local = bBox.get(boxId);
              if (local is Map) {
                await bBox.put(boxId, Map<String, dynamic>.from(local)
                  ..['syncStatus'] = 'synced'
                  ..['firestoreId'] = docId);
              }
            }
          }
          else if (type == 'save_box_opening') {
            final data = Map<String, dynamic>.from(action['data'] ?? {});
            final bId = LocalStorageService.sanitizeBranchId(action['branchId'] ?? data['branchId'], fallback: branchId);
            final openingId = (action['openingId'] ?? action['entityId'] ?? data['id'])?.toString();
            if (openingId == null || openingId.isEmpty) throw Exception('Missing openingId');

            // Openings live under their box: donation_boxes/{box}/openings/{opening}, which is
            // where every reader looks. They used to go to a separate donation_box_openings
            // collection that nothing read.
            final boxLocalId = (action['boxId'] ?? data['boxId'] ?? '').toString().trim();
            if (boxLocalId.isEmpty) throw Exception('Missing boxId for opening $openingId');
            final boxDocId = DonationBoxStorage.boxCloudDocId(boxLocalId);
            final fsId = (data['firestoreId'] ?? '').toString().trim();
            final openingDocId = fsId.isNotEmpty ? fsId : openingId;
            final fsData = Map<String, dynamic>.from(data)
              ..remove('syncStatus')
              ..['id'] = openingDocId;
            await _db.collection('branches').doc(bId).collection('donation_boxes').doc(boxDocId)
                .collection('openings').doc(openingDocId).set(fsData, SetOptions(merge: true));

            if (Hive.isBoxOpen(DonationBoxStorage.openingsBoxName)) {
              final oBox = Hive.box(DonationBoxStorage.openingsBoxName);
              final local = oBox.get(openingId);
              if (local is Map) {
                await oBox.put(openingId, Map<String, dynamic>.from(local)
                  ..['syncStatus'] = 'synced'
                  ..['firestoreId'] = openingDocId);
              }
            }
          }
          else if (type == 'save_madrassa_student' || type == 'save_madrassa_admission') {
            final data = Map<String, dynamic>.from(action['data'] ?? {});
            String? studentId = action['studentId']?.toString().trim();
            if (studentId == null || studentId.isEmpty) {
              studentId = (data['studentId'] ?? data['id'] ?? data['localId'] ?? action['localId'] ?? action['entityId'])
                  ?.toString()
                  .trim();
            }
            if (studentId == null || studentId.isEmpty) {
              // A record with no id can never upload; retrying it forever only wastes work.
              await LocalStorageService.moveToDeadLetterQueue(
                LocalStorageService.syncBox,
                key,
                Map<String, dynamic>.from(action),
                reason: 'save_madrassa_student has no studentId',
              );
              return;
            }
            final studentName = (data['name'] ?? data['studentName'])?.toString().trim();
            if (studentId.contains('config__current') || studentId.contains('__config__') || studentName == null || studentName.isEmpty) {
              // Corrupted phantom stub without a name or a config doc: prune immediately
              if (Hive.isBoxOpen(LocalStorageService.syncBox)) {
                await Hive.box(LocalStorageService.syncBox).delete(key);
              }
              return;
            }
            var bId = (action['branchId']?.toString() ?? branchId).toLowerCase().trim();
            var normBId = MadrassaLocalStorage.normalizeBranch(bId);
            if (normBId == 'all' || normBId == 'global' || normBId.isEmpty) {
              final studentBranch = (data['branchId'] ?? data['branch'] ?? '').toString().toLowerCase().trim();
              final normStdBranch = MadrassaLocalStorage.normalizeBranch(studentBranch);
              if (normStdBranch != 'all' && normStdBranch != 'global' && normStdBranch.isNotEmpty) {
                bId = normStdBranch;
              } else {
                bId = 'gujrat';
              }
            } else {
              bId = normBId;
            }
            data['branchId'] = bId;
            if (studentId.contains('__std__')) {
              studentId = studentId.split('__std__').last.trim();
            }
            if (studentId.isEmpty) throw Exception('Missing studentId');
            if (data['joinDate'] is String) {
              final parsed = DateTime.tryParse(data['joinDate'] as String);
              if (parsed != null) data['joinDate'] = Timestamp.fromDate(parsed);
            }
            data['lastUpdatedAt'] = FieldValue.serverTimestamp();
            // One copy of each image (see MadrassaLocalStorage.compactMediaForCloud).
            final fsData = MadrassaLocalStorage.compactMediaForCloud(LocalStorageService.sanitizeForCloudUpload(data));
            await _db.collection('branches').doc(bId).collection('madrassa_students').doc(studentId).set(fsData, SetOptions(merge: true));
            if (Hive.isBoxOpen(LocalStorageService.madrassaStudentsBox)) {
              final sBox = Hive.box(LocalStorageService.madrassaStudentsBox);
              // O(1) lookup via the queued localKey; full key scan only as a fallback.
              dynamic hitKey;
              final lk = action['localKey'];
              if (lk != null && sBox.get(lk) is Map) {
                hitKey = lk;
              } else {
                for (final k in sBox.keys) {
                  final r = sBox.get(k);
                  if (r is Map && (r['id'] == studentId || r['studentId'] == studentId || k.toString().endsWith('__$studentId') || k.toString() == studentId)) {
                    hitKey = k;
                    break;
                  }
                }
              }
              if (hitKey != null) {
                final r = Map<String, dynamic>.from(sBox.get(hitKey) as Map);
                // A newer local edit made while this upload was in flight stays pending.
                final sentIso = (action['data'] is Map ? action['data']['lastUpdatedAt'] : null)?.toString();
                if (sentIso == null || r['lastUpdatedAt']?.toString() == sentIso) {
                  await sBox.put(hitKey, r..['syncStatus'] = 'synced'..['synced'] = true..['pendingSync'] = false);
                }
              }
            }
          }
          else if (type == 'save_school_student' || type == 'save_school_admission') {
            final data = Map<String, dynamic>.from(action['data'] ?? {});
            String? studentId = action['studentId']?.toString().trim();
            if (studentId == null || studentId.isEmpty) {
              studentId = (data['studentId'] ?? data['id'] ?? data['localId'] ?? action['localId'] ?? action['entityId'] ?? action['docId'])
                  ?.toString()
                  .trim();
            }
            if (studentId == null || studentId.isEmpty) {
              await LocalStorageService.moveToDeadLetterQueue(
                LocalStorageService.syncBox,
                key,
                Map<String, dynamic>.from(action),
                reason: 'save_school_student has no studentId',
              );
              return;
            }
            var bId = (action['branchId']?.toString() ?? branchId).toLowerCase().trim();
            if (bId.isEmpty || bId == 'all' || bId == 'global') {
              final studentBranch = (data['branchId'] ?? data['branch'] ?? '').toString().toLowerCase().trim();
              bId = studentBranch.isNotEmpty && studentBranch != 'all' && studentBranch != 'global'
                  ? studentBranch
                  : 'gujrat';
            }
            bId = MadrassaLocalStorage.normalizeBranch(bId);
            data['branchId'] = bId;
            data['lastModified'] = DateTime.now().toIso8601String();
            final fsData = SchoolLocalStorage.compactMediaForCloud(LocalStorageService.sanitizeForCloudUpload(data));
            await _db.collection('branches').doc(bId).collection('school_students').doc(studentId).set(fsData, SetOptions(merge: true));

            if (Hive.isBoxOpen(LocalStorageService.schoolStudentsBox)) {
              final sBox = Hive.box(LocalStorageService.schoolStudentsBox);
              dynamic hitKey;
              final lk = action['localKey'];
              if (lk != null && sBox.containsKey(lk)) {
                hitKey = lk;
              } else {
                for (final k in ['${bId}__std__$studentId', '${bId}__$studentId', studentId]) {
                  if (sBox.containsKey(k)) {
                    hitKey = k;
                    break;
                  }
                }
              }
              if (hitKey != null) {
                final r = Map<String, dynamic>.from(sBox.get(hitKey) as Map);
                await sBox.put(hitKey, r
                  ..['syncStatus'] = 'synced'
                  ..['synced'] = true
                  ..['pendingSync'] = false
                  ..['lastSyncedAt'] = DateTime.now().toIso8601String());
              }
            }
          }
          else if (type == 'permanent_delete_madrassa_student') {
            final studentId = action['studentId'] as String?;
            final rawBId = action['branchId']?.toString() ?? branchId;
            final bId = MadrassaLocalStorage.normalizeBranch(rawBId);
            if (studentId != null && studentId.isNotEmpty) {
              if (bId == 'all' || bId == 'global' || bId.isEmpty) {
                for (final b in ['gujrat', 'karachi', 'saddar', 'haji', 'sialkot', 'jalalpurjattan']) {
                  await _db.collection('branches').doc(b).collection('madrassa_students').doc(studentId).delete().catchError((_) {});
                }
              } else {
                await _db.collection('branches').doc(bId).collection('madrassa_students').doc(studentId).delete().catchError((_) {});
              }
            }
          }
          else if (type == 'delete_madrassa_student' || type == 'offboard_madrassa_student') {
            final studentId = action['studentId'] as String?;
            final bId = MadrassaLocalStorage.normalizeBranch(action['branchId']?.toString() ?? branchId);
            final status = action['status']?.toString() ?? 'left';
            if (studentId == null || studentId.isEmpty) throw Exception('Missing studentId');
            await _db.collection('branches').doc(bId).collection('madrassa_students').doc(studentId).set({
              'status': status,
              'batch': status,
              'lastUpdatedAt': FieldValue.serverTimestamp(),
            }, SetOptions(merge: true));
          }
          else if (type == 'update_madrassa_student') {
            final studentId = action['studentId'] as String?;
            final currentLines = (action['currentLines'] as num?)?.toInt();
            if (studentId == null || currentLines == null) throw Exception('Missing studentId/currentLines');
            final ubId = MadrassaLocalStorage.normalizeBranch(_cleanBranch(action['branchId'] ?? branchId));

            // High performance: batch all pending update_madrassa_student actions from batchKeys into one commit
            final batch = _db.batch();
            final batchedKeys = <dynamic>[key];
            final processedStudentIds = <String>{studentId};

            batch.set(_db.collection('branches').doc(ubId).collection('madrassa_students').doc(studentId), {
              'currentLines': currentLines,
              'lastUpdatedAt': FieldValue.serverTimestamp(),
            }, SetOptions(merge: true));

            for (final otherKey in batchKeys) {
              if (otherKey == key || batchedProcessedKeys.contains(otherKey)) continue;
              final otherRaw = candidateData[otherKey] ?? queueBox.get(otherKey);
              if (otherRaw is Map && otherRaw['type'] == 'update_madrassa_student') {
                final oSId = otherRaw['studentId']?.toString();
                final oLines = (otherRaw['currentLines'] as num?)?.toInt();
                final oBId = MadrassaLocalStorage.normalizeBranch(_cleanBranch(otherRaw['branchId'] ?? branchId));
                if (oSId != null && oLines != null) {
                  if (!processedStudentIds.contains(oSId)) {
                    batch.set(_db.collection('branches').doc(oBId).collection('madrassa_students').doc(oSId), {
                      'currentLines': oLines,
                      'lastUpdatedAt': FieldValue.serverTimestamp(),
                    }, SetOptions(merge: true));
                    processedStudentIds.add(oSId);
                  }
                  batchedKeys.add(otherKey);
                }
              }
            }

            await batch.commit();

            for (final bk in batchedKeys) {
              batchedProcessedKeys.add(bk);
              if (bk != key) {
                await queueBox.delete(bk);
              }
            }
          }
          else if (type == 'save_madrassa_fee_payment' || type == 'save_madrassa_fee') {
            final bId = MadrassaLocalStorage.normalizeBranch(action['branchId']?.toString() ?? branchId);
            final docId = action['id']?.toString() ?? '${action['year']}_${action['month']}_${action['studentId']}';
            final data = Map<String, dynamic>.from(action['data'] ?? {});
            data['lastUpdatedAt'] = FieldValue.serverTimestamp();
            await _db.collection('branches').doc(bId).collection('madrassa_fee_payments').doc(docId).set(data, SetOptions(merge: true));
          }
          else if (type == 'save_expense' || type == 'void_expense') {
            final expenseId = action['expenseId'] as String?;
            final bId = action['branchId']?.toString() ?? branchId;
            final data = Map<String, dynamic>.from(action['data'] ?? {});
            if (expenseId == null) throw Exception('Missing expenseId');

            for (final f in ['date', 'createdAt', 'updatedAt', 'voidedAt']) {
              if (data[f] is String) {
                try {
                  data[f] = Timestamp.fromDate(DateTime.parse(data[f] as String));
                } catch (_) {}
              }
            }

            // GMWF v2 Conflict Check
            final expDocRef = _db.collection('branches').doc(bId).collection('expenses').doc(expenseId);
            final remoteDoc = await expDocRef.get();
            if (remoteDoc.exists) {
              final remoteData = remoteDoc.data();
              if (remoteData != null) {
                if (remoteData['isVoided'] == true && data['isVoided'] == true && remoteData['voidReason'] != data['voidReason']) {
                  await _handleSyncConflict(bId, expenseId, 'expense', data, remoteData);
                  await queueBox.delete(key);
                  return;
                }
              }
            }

            final fsData = Map<String, dynamic>.from(data)..remove('syncStatus');
            await expDocRef.set(fsData, SetOptions(merge: true));

            final box = Hive.box(LocalStorageService.expensesBox);
            final localRecord = box.get(expenseId);
            if (localRecord is Map) {
              final updated = Map<String, dynamic>.from(localRecord)
                ..['syncStatus'] = 'synced'
                ..['lastSyncedAt'] = DateTime.now().toUtc().toIso8601String();
              await box.put(expenseId, updated);
            }
          }
          // ── Types that were queued but had no upload handler (in 1.6.1 they were dropped
          // from the queue without ever reaching Firestore). Each goes where its module
          // reads it from.
          else if (type == 'save_madrassa_holiday' || type == 'delete_madrassa_holiday') {
            final bId = _cleanBranch(action['branchId']);
            final id = (action['id'] ?? action['data']?['id'] ?? action['data']?['dateKey'])?.toString().trim() ?? '';
            if (id.isEmpty) throw Exception('$type without id');
            final ref = _db.collection('branches').doc(bId).collection('madrassa_holidays').doc(id);
            if (type == 'delete_madrassa_holiday') {
              await ref.delete();
            } else {
              await ref.set(LocalStorageService.sanitizeForCloudUpload(Map<String, dynamic>.from(action['data'] ?? {})),
                  SetOptions(merge: true));
            }
          }
          else if (type == 'save_school_daily_log' || type == 'save_school_teacher_log') {
            // Biometric punches for school students/teachers: the same daily documents the
            // School module's attendance screens write and read.
            final bId = _cleanBranch(action['branchId']);
            final date = (action['date'] ?? action['dateKey'] ?? action['data']?['date'])?.toString().trim() ?? '';
            if (date.isEmpty) throw Exception('$type without date');
            final isTeacher = type == 'save_school_teacher_log';
            final logData = Map<String, dynamic>.from(action['data'] ?? {})
              ..remove('syncStatus')
              ..remove('synced')
              ..remove('pendingSync')
              ..remove('lastSyncedAt');
            await _db
                .collection('branches')
                .doc(bId)
                .collection(isTeacher ? 'school_teacher_attendance' : 'school_attendance')
                .doc(date)
                .set(LocalStorageService.sanitizeForCloudUpload(logData), SetOptions(merge: true));
            if (Hive.isBoxOpen(LocalStorageService.schoolLogsBox)) {
              final lBox = Hive.box(LocalStorageService.schoolLogsBox);
              final lKey = isTeacher ? '${bId}__tchlog__$date' : '${bId}__log__$date';
              final local = lBox.get(lKey);
              if (local is Map) {
                await lBox.put(lKey, Map<String, dynamic>.from(local)
                  ..['syncStatus'] = 'synced'
                  ..['synced'] = true
                  ..['pendingSync'] = false
                  ..['lastSyncedAt'] = DateTime.now().toIso8601String());
              }
            }
          }
          else if (type == 'save_restock_request') {
            final bId = _cleanBranch(action['branchId']);
            final data = Map<String, dynamic>.from(action['data'] ?? {});
            final id = (action['id'] ?? data['id'])?.toString().trim() ?? '';
            if (id.isEmpty) throw Exception('save_restock_request without id');
            final docRef = _db.collection('branches').doc(bId).collection('restock_requests').doc(id);
            await _keepDecidedRequestStatus(docRef, data, localBox: LocalStorageService.restockRequestsBox, id: id);
            await docRef.set(LocalStorageService.sanitizeForCloudUpload(data), SetOptions(merge: true));
          }
          else if (type == 'save_inventory_edit_request' || type == 'save_token_reversal_request' ||
              type == 'request_created' || type == 'save_edit_request') {
            // request_created: the LAN server forwards a client's new request under the event
            // name (clients on the LAN do not upload). It used to fall through to sync_records,
            // so the request never reached edit_requests and the phone never saw it.
            final bId = _cleanBranch(action['branchId'] ?? (action['data'] is Map ? action['data']['branchId'] : null));
            final data = Map<String, dynamic>.from(action['data'] ?? {});
            final requestId = (action['requestId'] ?? data['id'] ?? data['requestId'])?.toString().trim() ?? '';
            if (requestId.isEmpty) throw Exception('$type without requestId');
            final col = (data['collection'] ?? action['collection'] ?? 'edit_requests').toString();
            final docRef = _db.collection('branches').doc(bId).collection(col).doc(requestId);
            await _keepDecidedRequestStatus(docRef, data, localBox: 'local_edit_requests', id: requestId);
            for (final f in ['requestedAt', 'reviewedAt', 'approvedAt']) {
              if (data[f] is String) {
                try {
                  data[f] = Timestamp.fromDate(DateTime.parse(data[f] as String));
                } catch (_) {}
              }
            }
            await docRef.set(LocalStorageService.sanitizeForCloudUpload(data), SetOptions(merge: true));
          }
          else if (type == LanFirestoreGate.relayEvent) {
            // A desk's write handed to the LAN server (LanFirestoreGate.relayWrite).
            final data = Map<String, dynamic>.from(action['data'] ?? {});
            final path = (data['path'] ?? '').toString().trim();
            final segs = path.split('/').where((s) => s.isNotEmpty).length;
            if (path.isNotEmpty && segs.isEven) {
              final ref = _db.doc(path);
              if (data['delete'] == true) {
                await ref.delete();
              } else {
                final fields = Map<String, dynamic>.from(data['fields'] as Map? ?? const {});
                for (final k in (data['serverTimeKeys'] as List? ?? const [])) {
                  fields[k.toString()] = FieldValue.serverTimestamp();
                }
                await ref.set(fields, SetOptions(merge: data['merge'] != false));
              }
            }
          }
          else if (type == 'save_prescription_template' || type == 'delete_prescription_template') {
            // Forwarded by the LAN server for a doctor desk (desks on the LAN do not write).
            final data = Map<String, dynamic>.from(action['data'] ?? {});
            final id = (data['id'] ?? action['id'])?.toString().trim() ?? '';
            if (id.isEmpty) throw Exception('$type without id');
            final doctorId = (data['doctorId'] ?? data['userId'] ?? '').toString().trim();
            final refs = [
              _db.collection('branches').doc(branchId).collection('doctor_templates').doc(id),
              if (doctorId.isNotEmpty) _db.collection('users').doc(doctorId).collection('doctor_templates').doc(id),
            ];
            for (final ref in refs) {
              if (type == 'delete_prescription_template') {
                await ref.delete();
              } else {
                await ref.set(LocalStorageService.sanitizeForCloudUpload(data), SetOptions(merge: true));
              }
            }
          }
          else if (type == 'token_reversal') {
            // Removes the reversed token from the cloud (the same document the request
            // screen deletes directly; this makes sure it happens even if that failed).
            final bId = _cleanBranch(action['branchId']);
            final data = Map<String, dynamic>.from(action['data'] ?? {});
            final serial = (action['serial'] ?? data['tokenSerial'])?.toString().trim() ?? '';
            final dateKey = (action['dateKey'] ?? data['dateKey'])?.toString().trim() ?? '';
            final queueCol = data['queueType']?.toString().trim() ?? '';
            if (serial.isNotEmpty && dateKey.isNotEmpty && queueCol.isNotEmpty) {
              await _db.collection('branches').doc(bId).collection('serials').doc(dateKey)
                  .collection(queueCol).doc(serial).delete();
            }
          }
          else if (type == 'save_medicine_restriction') {
            final bId = _cleanBranch(action['branchId']);
            final patientId = action['patientId']?.toString().trim() ?? '';
            if (patientId.isEmpty) throw Exception('save_medicine_restriction without patientId');
            await _db.collection('branches').doc(bId).collection('medicine_restrictions').doc(patientId)
                .set(LocalStorageService.sanitizeForCloudUpload(Map<String, dynamic>.from(action['data'] ?? {})),
                    SetOptions(merge: true));
          }
          else if (type == 'ramadan_registration' || type == 'ramadan_lucky_draw_winner') {
            final data = Map<String, dynamic>.from(action['data'] ?? {});
            final rawB = (action['branchId'] ?? data['branchId'] ?? '').toString().toLowerCase().trim();
            final bId = rawB.isEmpty ? 'global' : rawB;
            final id = (action['hiveKey'] ?? data['id'])?.toString().trim() ?? '';
            if (id.isEmpty) throw Exception('$type without id');
            await _db.collection('branches').doc(bId).collection('ramadan_registrations').doc(id)
                .set(LocalStorageService.sanitizeForCloudUpload(data), SetOptions(merge: true));
          }
          else if (type == 'save_submission' || type == 'update_submission_status') {
            // Donation cash hand-over chain (collector → supervisor → office).
            final bId = _cleanBranch(action['branchId']);
            final id = (action['hiveKey'] ?? action['data']?['id'])?.toString().trim() ?? '';
            if (id.isEmpty) throw Exception('$type without id');
            final Map<String, dynamic> fields;
            if (type == 'save_submission') {
              fields = Map<String, dynamic>.from(action['data'] ?? {});
            } else {
              fields = {
                for (final f in ['status', 'acknowledgedBy', 'acknowledgedAt', 'returnReason'])
                  if (action[f] != null) f: action[f],
              };
            }
            await _db.collection('branches').doc(bId).collection('donation_submissions').doc(id)
                .set(LocalStorageService.sanitizeForCloudUpload(fields), SetOptions(merge: true));
          }
          else if (type.startsWith('request_') && type.endsWith('_approval')) {
            // Loan / repayment / write-off / month-lock requests awaiting CEO approval.
            final bId = _cleanBranch(action['branchId']);
            final data = Map<String, dynamic>.from(action['data'] ?? {});
            final id = (data['id'] ?? action['id'])?.toString().trim() ?? '';
            if (id.isEmpty) throw Exception('$type without id');
            data['requestType'] = type;
            data['status'] ??= 'pending';
            await _db.collection('branches').doc(bId).collection('approval_requests').doc(id)
                .set(LocalStorageService.sanitizeForCloudUpload(data), SetOptions(merge: true));
          }
          else if (type == 'edit_proforma_medicine') {
            // The master proforma catalogue is local (shared over LAN, no cloud copy):
            // nothing to upload.
          }
          else {
            // Generic fallback for any event types not handled explicitly above
            debugPrint('[SyncService] ℹ️ Generic sync type "$type" — saving to branches/$branchId/sync_records');
            final recData = Map<String, dynamic>.from(action['data'] is Map ? action['data'] : action);
            final recId = (action['docId'] ?? action['entityId'] ?? action['id'] ?? recData['id'] ?? recData['key'] ?? key).toString();
            final fsData = LocalStorageService.sanitizeForCloudUpload(recData);
            await _db.collection('branches').doc(branchId).collection('sync_records').doc(recId).set(fsData, SetOptions(merge: true));
          }

          if (changedSinceStart()) {
            // A newer edit was merged in while this one uploaded: keep it for the next pass.
            debugPrint('[SyncService] ↪️ $key changed during upload — newer version stays queued');
          } else {
            await _markLocalRecordSynced(action);
            await queueBox.delete(key);
          }
          debugPrint('[SyncService] ✅ Uploaded [$type] key: $key successfully! (${queueBox.length} remaining in queue)');
          if (['update_inventory', 'add_inventory_stock', 'register_medicine', 'save_token_exception_request', 'approve_token_exception'].contains(type)) {
            await _resolveInventorySyncFailure(key, branchId);
          }
          }
          // The time limit only guards against a read that never answers; REST writes have
          // their own limits. A timed-out item is simply retried (its writes are idempotent).
          // Boxes this item writes to after its cloud write: on a PC whose role doesn't use them
          // they may be closed, and failing after a cloud increment would repeat the increment.
          await LocalStorageService.ensureBoxesForSyncType(type, collection: action['collection']?.toString());
          await CloudDb.runWith(CloudWriteContext(force: force, backlog: _isBacklogItem(action)), work)
              .timeout(const Duration(seconds: 120));
          consecutiveNetworkFailures = 0;
          uploadedThisPass++;
        } catch (e, stackTrace) {
          debugPrint('[SyncService] ❌ Failed to upload [$type] key: $key: $e');
          // Refused because this desk is on the LAN (CloudDb): not a network failure. Set it
          // aside without rewriting it, and let the rest of the queue run.
          if (e.toString().contains(CloudDb.lanDeskRefusal)) {
            _lanDeferredUntil[key] = DateTime.now().add(_lanDeferral);
            continue;
          }
          // A newer edit merged in during the upload replaces this one: never write the older
          // copy back over it (it is uploaded on the next pass with fresh retry state).
          final keepNewer = changedSinceStart();
          if (QuotaService.isQuotaError(e) && QuotaService.isPausedForDailyReset) {
            action['lastAttempt'] = DateTime.now().toIso8601String();
            action['lastError'] = e.toString();
            action['nextRetryAt'] = DateTime.now().add(const Duration(seconds: 30)).toIso8601String();
            if (!keepNewer) await queueBox.put(key, action);
            quotaStop = true;
            break;
          }
          // Transient problems (no network, a read that timed out) are retried later
          // without counting toward the dead-letter limit — older data used to be
          // dead-lettered after a few minutes offline and never retried.
          if (_isTransientError(e)) {
            action['lastAttempt'] = DateTime.now().toIso8601String();
            action['lastError'] = e.toString();
            action['nextRetryAt'] = DateTime.now().add(const Duration(seconds: 15)).toIso8601String();
            if (!keepNewer) await queueBox.put(key, action);
            _noteUploadFailure(type, key.toString(), attempts, e, stackTrace);
            if (++consecutiveNetworkFailures >= 5) {
              _stalledUntil = DateTime.now().add(const Duration(seconds: 30));
              SyncLog.write('⏸️ Cloud not reachable ($e) — uploads retry in 30 seconds');
              quotaStop = true;
              break;
            }
            continue;
          }
          final errStr = e.toString().toLowerCase();
          final isNetworkError = errStr.contains('network') ||
              errStr.contains('socket') ||
              errStr.contains('timeout') ||
              errStr.contains('unavailable') ||
              errStr.contains('connection') ||
              errStr.contains('deadline') ||
              errStr.contains('host');

          final nextAttempts = isNetworkError ? attempts : attempts + 1;
          action['attempts'] = nextAttempts;
          action['lastAttempt'] = DateTime.now().toIso8601String();
          action['lastError'] = e.toString();

          final backoffSeconds = min(30, pow(2, min(nextAttempts + 1, 5)).toInt());
          action['nextRetryAt'] = DateTime.now().add(Duration(seconds: backoffSeconds)).toIso8601String();

          if (keepNewer) {
            // newer version queued — leave it alone
          } else if (!isNetworkError && nextAttempts >= 15) {
            await LocalStorageService.moveToDeadLetterQueue(
              LocalStorageService.syncBox,
              key,
              action,
              reason: e.toString(),
            );
          } else {
            await queueBox.put(key, action);
          }

          // One short line per failure. The old boxed Logger output plus a full stack trace for
          // every failed item flooded the console (hundreds of lines per pass), which is slow on
          // Windows and buried every other message.
          _noteUploadFailure(type, key.toString(), nextAttempts, e, stackTrace);
          if (['update_inventory', 'add_inventory_stock', 'register_medicine', 'save_token_exception_request', 'approve_token_exception'].contains(type)) {
            await _logInventorySyncFailure(key, action, type, e.toString());
          }
        }
        // Yield to event loop on every item so Windows message pump stays alive and UI never freezes
        await Future.delayed(const Duration(milliseconds: 10));
      }
      // Between batches, yield 50ms so Windows message pump processes clicks and draws UI
      await Future.delayed(const Duration(milliseconds: 50));
      }
      if (backlogDeferred > 0) {
        SyncLog.write('📦 Backlog share of today\'s quota used — $backlogDeferred older item(s) wait for the '
            'next reset (${QuotaService.dailyBacklogWriteCount}/${QuotaService.backlogDailyBudget} backlog writes today)');
      }
      final writesThisPass = QuotaService.dailyWriteCount - writesBefore;
      final skippedThisPass = CloudDb.skippedUnchanged - skippedBefore;
      if (uploadedThisPass > 0 || writesThisPass > 0 || quotaStop) {
        SyncLog.write('Upload pass${force ? ' (forced)' : ''}: $uploadedThisPass item(s) uploaded, '
            '$writesThisPass write(s), $skippedThisPass unchanged skipped, ${queueBox.length} still queued, '
            '${DateTime.now().difference(passStarted).inSeconds}s. Today: ${QuotaService.dailyWriteCount} writes from this PC'
            '${QuotaService.isPausedForDailyReset ? ' — quota used up, waiting for the reset' : ''}');
      }
      // If items that are ready to send remain, keep draining with a short timer. Items
      // waiting out a backoff or a coalescing delay don't count — re-running the pass
      // every 10 s for them prevents UI stall loops.
      final now = DateTime.now();
      bool hasReadyItems = false;
      if (!quotaStop && !QuotaService.isPausedForDailyReset && queueBox.isOpen) {
        for (final k in queueBox.keys) {
          final v = queueBox.get(k);
          if (v is! Map) {
            hasReadyItems = true;
            break;
          }
          if (_coalesceUntil(v) != null) continue;
          final next = DateTime.tryParse((v['nextRetryAt'] ?? '').toString());
          if (next == null || !now.isBefore(next)) {
            hasReadyItems = true;
            break;
          }
        }
      }
      if (Hive.isBoxOpen(LocalStorageService.syncBox) && hasReadyItems) {
        _retryTimer?.cancel();
        _retryTimer = Timer(const Duration(seconds: 10), () {
          if (Hive.isBoxOpen(LocalStorageService.syncBox)) {
            triggerUpload();
          }
        });
      }
    } catch (fatal) {
      Logger().d("FATAL sync: $fatal");
    } finally {
      uploadStatus?.end();
      // Only the current pass releases the flag (a hung pass the watchdog replaced does not).
      if (myUploadGen == _uploadGen) _isUploading = false;
      ServerSyncCoordinator.markFinished(isServer: false);
      if (_forceRequested) {
        _forceRequested = false;
        Timer(const Duration(milliseconds: 500), () => triggerUpload(force: true));
      } else if (_urgentRequested) {
        _urgentRequested = false;
        Timer(const Duration(milliseconds: 50), () => triggerUpload(urgent: true));
      }
    }
  }

  bool _forceRequested = false;
  bool _urgentRequested = false;

  /// Adds [amount] to a cloud stock quantity exactly once per [txId]. The increment and a
  /// marker document `inventory_applied_tx/{txId}` are committed in ONE batch (atomic), so a
  /// retry after a write that did reach Firestore (timeout, lost response, a later write in
  /// the same item failing) finds the marker and does nothing — before, it added the stock
  /// again (one restock of 100 showed +200; one dispense deducted twice). The marker is only
  /// read on retries, so a normal first upload costs no extra read.
  Future<void> _incrementStockOnce({
    required String branchId,
    required CloudDoc docRef,
    required String txId,
    required num amount,
    required bool isRetry,
  }) async {
    // Same writer as the rest of the upload pass (REST commit = atomic, quota-accounted).
    final cloud = CloudDb.instance;
    final markerRef = cloud
        .collection('branches')
        .doc(branchId)
        .collection('inventory_applied_tx')
        .doc(txId.replaceAll('/', '_'));
    if (isRetry) {
      final snap = await markerRef.get();
      if (snap.exists) {
        debugPrint('[SyncService] Stock tx $txId already applied in the cloud — not counted again');
        return;
      }
    }
    final batch = cloud.batch();
    batch.set(docRef, {
      'quantity': FieldValue.increment(amount),
      'lastUpdated': FieldValue.serverTimestamp(),
      'updatedAt': FieldValue.serverTimestamp(),
    }, SetOptions(merge: true));
    batch.set(markerRef, {
      'medicineId': docRef.id,
      'amount': amount,
      'appliedAt': FieldValue.serverTimestamp(),
    });
    await batch.commit();
  }

  /// Marks the local record a queued action came from as synced, when the action names it
  /// ('localBox'/'localKey'); otherwise the backfill sweep would queue it again forever.
  Future<void> _markLocalRecordSynced(Map<String, dynamic> action) async {
    final boxName = action['localBox']?.toString();
    final localKey = action['localKey'];
    if (boxName == null || localKey == null || !Hive.isBoxOpen(boxName)) return;
    final box = Hive.box(boxName);
    final r = box.get(localKey);
    if (r is Map) {
      await box.put(localKey, Map<String, dynamic>.from(r)
        ..['syncStatus'] = 'synced'
        ..['synced'] = true
        ..['pendingSync'] = false
        ..['lastSyncedAt'] = DateTime.now().toIso8601String());
    }
  }

  void cancelTimers() {
    _retryTimer?.cancel();
    _retryTimer = null;
  }



  Future<void> syncUnsyncedPatients(String branchId) async {
    await triggerUpload();
  }

  Future<void> syncTodayOnly(String branchId) async {
    if (LanFirestoreGate.isLanDesk) return; // a dispensary desk on the LAN leaves Firestore to the LAN server
    final normBranchId = branchId.toLowerCase().trim();
    await LocalStorageService.downloadTodayTokens(normBranchId);
    await LocalStorageService.downloadDasterkhwaanTokens(normBranchId, days: 2);
    await DonationsLocalStorage.downloadAllDonations(normBranchId);
    if (CampSessionService.isKarachiFamily(normBranchId)) {
      await LocalStorageService.restoreAndSyncKarachiInventory('karachi');
    } else {
      await LocalStorageService.downloadInventory(normBranchId, forceFull: true);
    }
  }

  Future<void> initialFullDownload(String branchId) async {
    if (LanFirestoreGate.isLanDesk) return; // a dispensary desk on the LAN leaves Firestore to the LAN server
    final normBranchId = branchId.toLowerCase().trim();
    final settings = Hive.box('app_settings');
    final key      = 'initial_download_done_$normBranchId';
    if (settings.get(key, defaultValue: false)) {
      await syncTodayOnly(normBranchId);
      return;
    }
    try {
      if (!Hive.isBoxOpen(LocalStorageService.patientsBox) ||
          Hive.box(LocalStorageService.patientsBox).isEmpty) {
        // Bounded: a pending whole-collection read on flaky Wi-Fi kept every later step (and
        // the 'done' flag) waiting for many minutes. A timeout retries on the next start.
        final patientsSnap = await _db
            .collection('branches')
            .doc(normBranchId)
            .collection('patients')
            .get()
            .timeout(const Duration(seconds: 90));
        final List<Map<String, dynamic>> patientsList = [];
        for (final doc in patientsSnap.docs) {
          final d = doc.data();
          d['patientId'] = doc.id;
          d['branchId'] = normBranchId;
          patientsList.add(d);
        }
        await LocalStorageService.saveAllLocalPatients(patientsList);
      }

      await LocalStorageService.downloadTodayTokens(normBranchId);
      await Future.delayed(const Duration(milliseconds: 50));
      await LocalStorageService.downloadDasterkhwaanTokens(normBranchId, days: 7);
      await Future.delayed(const Duration(milliseconds: 50));
      await LocalStorageService.downloadInventory(normBranchId);
      await Future.delayed(const Duration(milliseconds: 50));
      await DonationsLocalStorage.downloadAllDonations(normBranchId);
      await Future.delayed(const Duration(milliseconds: 50));
      await DonationsLocalStorage.downloadDonors(normBranchId);
      await Future.delayed(const Duration(milliseconds: 50));
      // Nine sequential collection downloads; a stalled one throws here (flag stays unset).
      await FinanceLocalStorage.downloadAllFinanceData(normBranchId).timeout(const Duration(minutes: 3));
      await Future.delayed(const Duration(milliseconds: 50));
      await FinanceLoansStorage.migrateLegacyAdvancesToLoans(performedBy: 'System');
      await settings.put(key, true);
    } catch (e) {
      Logger().d('Initial download failed: $e');
    }
  }

  Future<void> forceFullRefresh(String branchId) async {
    final normBranchId = branchId.toLowerCase().trim();
    final settings = Hive.box('app_settings');
    final lastForceKey = 'last_force_full_refresh_$normBranchId';
    final lastForceStr = settings.get(lastForceKey) as String?;
    if (lastForceStr != null) {
      final lastForce = DateTime.tryParse(lastForceStr);
      if (lastForce != null && DateTime.now().difference(lastForce).inHours < 6) {
        Logger().d('SyncService: forceFullRefresh skipped — cooldown active (6h)');
        await syncTodayOnly(normBranchId);
        await triggerUpload();
        return;
      }
    }
    await settings.put(lastForceKey, DateTime.now().toIso8601String());
    await settings.delete('initial_download_done_$normBranchId');
    await initialFullDownload(normBranchId);
    await triggerUpload();
  }

  void dispose() {
    _connectivitySub?.cancel();
    _cloudSyncTriggerSub?.cancel();
    _dailyTokenTimer?.cancel();
    _periodicSyncTimer?.cancel();
    _queueDrainTimer?.cancel();
    _retryTimer?.cancel();
  }

  String resolveQueueType(String? raw, {String? branchId}) {
    if (raw == null) return 'zakat';
    final r = raw.toLowerCase().trim();
    if (r == '20' || r == 'pkr 20' || r == 'pkr20' || r == 'twenty') {
      return 'zakat';
    }
    if (r.contains('non') || r.contains('general')) {
      if (branchId != null) {
        final b = branchId.toLowerCase().trim();
        if (b.contains('karachi') || b.contains('haji') || b.contains('saddar') || b.contains('kapaya')) {
          return 'zakat';
        }
      }
      return 'non-zakat';
    }
    if (r.contains('gmwf')) return 'gmwf';
    return 'zakat';
  }

  Future<void> _flagPersistentSyncFailure(String key, Map<String, dynamic> action, String type) async {
    try {
      final failuresBox = await Hive.openBox('sync_failures');
      final failureRecord = {
        'queueKey': key,
        'type': type,
        'action': action,
        'flaggedAt': DateTime.now().toIso8601String(),
        'attempts': action['attempts'],
      };
      await failuresBox.put(key, failureRecord);
      debugPrint('[SyncService] Flagged persistent sync failure: key=$key type=$type');
    } catch (e) {
      debugPrint('[SyncService] Error flagging sync failure: $e');
    }
  }

  Future<void> _logInventorySyncFailure(String queueKey, Map<String, dynamic> action, String type, String errorMsg) async {
    try {
      final bId = action['branchId'] as String? ?? _currentBranchId!;
      final medId = action['medicineId'] ?? action['inventoryId'] ?? (action['data'] as Map?)?['medicineId'] ?? '';
      final medName = action['medicineName'] ?? (action['data'] as Map?)?['name'] ?? 'Unknown Medicine';
      
      final docId = 'fail_$queueKey';
      
      final failuresBox = await Hive.openBox('inventory_sync_failures');
      final record = {
        'queueKey': queueKey,
        'type': type,
        'medicineId': medId,
        'medicineName': medName,
        'error': errorMsg,
        'timestamp': DateTime.now().toIso8601String(),
        'actionData': action,
        'attempts': action['attempts'] ?? 0,
        'status': 'pending',
      };
      await failuresBox.put(docId, record);
      
      await _db
          .collection('branches')
          .doc(bId)
          .collection('inventory_sync_failures')
          .doc(docId)
          .set({
        ...record,
        'timestamp': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));
      
      debugPrint('[SyncService] Logged inventory sync failure for $medName: $errorMsg');
    } catch (err) {
      debugPrint('[SyncService] Error logging sync failure: $err');
    }
  }

  Future<void> _resolveInventorySyncFailure(String queueKey, String branchId) async {
    try {
      final docId = 'fail_$queueKey';
      final failuresBox = await Hive.openBox('inventory_sync_failures');
      await failuresBox.delete(docId);
      
      await _db
          .collection('branches')
          .doc(branchId)
          .collection('inventory_sync_failures')
          .doc(docId)
          .update({
        'status': 'resolved',
        'resolvedAt': FieldValue.serverTimestamp(),
      }).catchError((_) {});
    } catch (err) {
      debugPrint('[SyncService] Error resolving sync failure: $err');
    }
  }

  Future<void> _handleSyncConflict(
    String branchId,
    String entityId,
    String entityType,
    Map<String, dynamic> localData,
    Map<String, dynamic> remoteData,
  ) async {
    try {
      final settings = Hive.box(LocalStorageService.financeSettingsBox);
      final conflicts = List<Map<String, dynamic>>.from(
        (settings.get('sync_conflicts') as List? ?? []).map((e) => Map<String, dynamic>.from(e as Map)),
      );
      
      // Avoid duplicate conflicts
      final exists = conflicts.any((c) => c['entityId'] == entityId && c['entityType'] == entityType);
      if (!exists) {
        conflicts.add({
          'id': _uuid.v4(),
          'entityId': entityId,
          'entityType': entityType,
          'branchId': branchId,
          'local': localData,
          'remote': remoteData,
          'timestamp': DateTime.now().toUtc().toIso8601String(),
        });
        await settings.put('sync_conflicts', conflicts);
        await settings.flush();
      }

      await _db.collection('branches').doc(branchId).collection('sync_conflicts').doc(entityId).set({
        'entityId': entityId,
        'entityType': entityType,
        'local': localData,
        'remote': remoteData,
        'status': 'unresolved',
        'timestamp': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));

      debugPrint('[SyncService] Conflict logged for $entityType: $entityId');
    } catch (e) {
      debugPrint('[SyncService] Error handling sync conflict: $e');
    }
  }

  /// Sweeps all local storage boxes across modules (Madrassa logs, Dasterkhwaan tokens,
  /// Donation boxes, Box openings, Donations, Clinic Tokens across all branches)
  /// and ensures any pending/unsynced records are pushed to Firestore directly.
  Future<void> sweepAllPendingLocalData({bool force = false}) async {
    if (LanFirestoreGate.isLanDesk) return; // a dispensary desk on the LAN leaves Firestore to the LAN server
    // Connectivity check — works on all platforms including Windows desktop
    bool canSync = false;
    try {
      final connectivity = await Connectivity().checkConnectivity();
      canSync = connectivity.any((r) => r != ConnectivityResult.none);
    } catch (_) {
      // Fall back to NetworkHealthService if Connectivity package fails
      canSync = NetworkHealthService().isStableOnline;
    }
    if (!kIsWeb && (Platform.isAndroid || Platform.isIOS)) {
      // Already handled above via Connectivity
    }
    if (!canSync) {
      debugPrint('[SyncService] Sweep skipped — no connectivity');
      return;
    }

    // Quota guard
    final bool hasPendingItems = Hive.isBoxOpen(LocalStorageService.syncBox) &&
        Hive.box(LocalStorageService.syncBox).isNotEmpty;

    // Quota guard: only skip if daily quota is exhausted AND there are no pending items waiting
    if (force) {
      QuotaService.resetState();
    } else if (QuotaService.isQuotaExhausted && !hasPendingItems) {
      debugPrint('[SyncService] ⛔ Quota exhausted and no pending items — sweep skipped');
      return;
    }

    // Sweep cooldown: 5 minutes between automatic sweeps unless forced.
    try {
      final settings = Hive.box('app_settings');
      final lastSweepStr = settings.get('last_sweep_timestamp') as String?;
      if (!force && lastSweepStr != null) {
        final lastSweep = DateTime.tryParse(lastSweepStr);
        if (lastSweep != null && DateTime.now().difference(lastSweep).inMinutes < 5) {
          debugPrint('[SyncService] Sweep cooldown active (last: $lastSweepStr)');
          return;
        }
      }
      await settings.put('last_sweep_timestamp', DateTime.now().toIso8601String());
    } catch (_) {}

    try {
      debugPrint('[SyncService] 🧹 Starting comprehensive sweep of all pending local data...');
      await LocalStorageService.healLegacyHistoricalData();

      // Everything below only QUEUES records; the upload pass sends them.


      try {
        for (final (boxName, type) in [
          (DonationBoxStorage.boxesBoxName, 'save_donation_box'),
          (DonationBoxStorage.openingsBoxName, 'save_box_opening'),
        ]) {
          if (!Hive.isBoxOpen(boxName)) continue;
          final b = Hive.box(boxName);
          for (final key in b.keys.toList()) {
            final raw = b.get(key);
            if (raw is! Map || raw['syncStatus'] == 'synced') continue;
            final id = (raw['id'] ?? key).toString();
            await LocalStorageService.enqueueSync({
              'backlog': true,
              'type': type,
              'entityId': id,
              'branchId': LocalStorageService.sanitizeBranchId(raw['branchId'], fallback: 'karachi'),
              'data': Map<String, dynamic>.from(raw)..['id'] = id,
              'localBox': boxName,
              'localKey': key,
            });
          }
        }
      } catch (e) {
        debugPrint('[SyncService] Sweep donation boxes notice: $e');
      }

      await Future.delayed(const Duration(milliseconds: 50));

      // Backlog harvesting. Each backfill scans ALL local records and uses the record's own
      // branchId (the argument is only the fallback), so one call covers every branch.
      final b = _currentBranchId ?? 'karachi';
      // A module is swept when its box is open, this PC's role uses it, or a forced sweep was requested.
      bool sweeps(String box) => force || Hive.isBoxOpen(box) || LocalStorageService.roleUsesBox(box);
      // Quiet background status so the user can see why things may feel slower right now.
      final status = BusyStatus.begin('Checking records to sync', background: true);
      try {
        if (sweeps(LocalStorageService.entriesBox)) {
          status.update('Checking tokens to sync');
          await _enqueueMissingEntries(b, force: force);
          await Future.delayed(const Duration(milliseconds: 75));
        }

        if (sweeps(DonationsLocalStorage.donationsBox)) {
          status.update('Checking donations to sync');
          await _enqueueMissingDonations(b);
          await Future.delayed(const Duration(milliseconds: 75));
        }

        status.update('Checking food records to sync');
        if (sweeps(LocalStorageService.dasterkhwaanTokensBox)) {
          await _enqueueMissingFoodTokens(b);
          await Future.delayed(const Duration(milliseconds: 50));
        }
        if (sweeps(LocalStorageService.dasterkhwaanFoodLogsBox)) {
          await _enqueueMissingFoodLogs(b);
          await Future.delayed(const Duration(milliseconds: 75));
        }

        status.update('Checking staff records to sync');
        if (sweeps(LocalStorageService.employeesBox)) {
          await _enqueueMissingEmployees(b);
          await Future.delayed(const Duration(milliseconds: 50));
        }
        if (sweeps(LocalStorageService.attendanceBox)) {
          await _enqueueMissingAttendance(b, force: force);
          await Future.delayed(const Duration(milliseconds: 75));
        }

        if (sweeps(LocalStorageService.patientsBox)) {
          status.update('Checking patient records to sync');
          await _enqueueMissingPatients(b, force: force);
          await Future.delayed(const Duration(milliseconds: 75));
        }

        status.update('Checking madrassa & school records');
        if (sweeps(LocalStorageService.madrassaStudentsBox)) {
          await _enqueueMissingMadrassaStudents(b);
          await Future.delayed(const Duration(milliseconds: 50));
        }
        if (sweeps(LocalStorageService.madrassaLogsBox)) {
          await _enqueueMissingMadrassaLogs(b);
          await Future.delayed(const Duration(milliseconds: 50));
        }
        if (sweeps(LocalStorageService.schoolStudentsBox)) {
          await _enqueueMissingSchoolData(b);
          await Future.delayed(const Duration(milliseconds: 75));
        }

        // Synchronize all local users (including recently created ones) to Firestore
        status.update('Syncing user accounts');
        await LocalStorageService.pushLocalUsersToFirestore();
        await Future.delayed(const Duration(milliseconds: 100));

        // Upload pass now that the queue is populated. Only a user-forced sweep forces it: the
        // startup sweep used to force it too, which cleared any daily-quota pause on every start.
        status.update('Uploading changes');
        await triggerUpload(force: force);
      } finally {
        status.end();
      }
      debugPrint('[SyncService] ✅ Comprehensive sweep completed.');
    } catch (e) {
      debugPrint('[SyncService] sweepAllPendingLocalData error: $e');
    }
  }
}