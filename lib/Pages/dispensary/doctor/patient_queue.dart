// lib/pages/dispensary/doctor/patient_queue.dart

import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:intl/intl.dart';

import 'package:gmwf/services/local_storage_service.dart';
import 'package:gmwf/services/camp_session_service.dart';
import 'package:gmwf/services/serials_service.dart';
import 'package:gmwf/realtime/realtime_manager.dart';
import 'package:gmwf/realtime/realtime_events.dart';
import 'package:gmwf/services/staff_patient_link_service.dart';

class PatientQueue extends StatefulWidget {
  final String branchId;
  final String? doctorId;
  final String? doctorName;
  final Map<String, dynamic>? selectedPatient;
  final Function(Map<String, dynamic>) onPatientSelected;
  final bool isSaving;

  const PatientQueue({
    super.key,
    required this.branchId,
    this.doctorId,
    this.doctorName,
    this.selectedPatient,
    required this.onPatientSelected,
    this.isSaving = false,
  });

  @override
  State<PatientQueue> createState() => _PatientQueueState();
}

class _PatientQueueState extends State<PatientQueue> {
  static const Color _teal   = Color(0xFF00695C);
  static const Color _amber  = Color(0xFFFFA000);
  static const Color _purple = Color(0xFF6A1B9A);

  String _filter = 'all';
  String _selectedSessionFilter = 'auto';
  String _selectedCampFilter = 'all';
  
  // ─── HANG FIX: Debounce + Cache ────────────────────────────────────
  Timer? _debounceRebuildTimer;  // Batch multiple events into single rebuild
  List<Map<String, dynamic>>? _cachedQueue;  // Cache sorted queue
  DateTime? _queueCacheTime;  // Track cache freshness
  static const _queueCacheTTL = Duration(milliseconds: 500);  // Cache for 500ms
  bool get _hasMultiCamps => CampSessionService.hasCampsForBranch(widget.branchId);
  String get _todayKey => CampSessionService.resolveShiftAndDateKey().dateKey;

  late StreamSubscription<Map<String, dynamic>> _realtimeSub;
  StreamSubscription<List<ConnectivityResult>>? _connSub;
  List<DocumentSnapshot> _exceptionRequests = [];
  List<Map<String, dynamic>> _localExceptionRequests = [];
  Map<String, dynamic> _getUserData() {
    try {
      if (Hive.isBoxOpen('app_settings')) {
        final userData = Hive.box('app_settings').get('user_data') ?? Hive.box('app_settings').get('currentUser');
        if (userData is Map) return Map<String, dynamic>.from(userData);
      }
    } catch (_) {}
    return {};
  }

  List<String> get _allowedSessions => CampSessionService.getAllowedSessions(widget.branchId, userData: _getUserData());

  List<String> get _allowedCamps {
    final userData = _getUserData();
    final role = (userData['role'] ?? userData['userRole'] ?? '').toString().toLowerCase();
    if (role.contains('admin') || role.contains('supervisor') || role.contains('manager') || role.contains('chairman')) {
      return ['all'];
    }
    final scheduled = CampSessionService.getMatchingScheduledCamps(userData);
    if (scheduled.isNotEmpty) return scheduled;
    final assigned = CampSessionService.getAssignedCamps(userData);
    if (assigned.isNotEmpty) return assigned;
    return ['all'];
  }

  bool _isCampAllowed(String campId) {
    final allowed = _allowedCamps;
    if (allowed.contains('all')) return true;
    if (campId == 'all') return allowed.contains('all');
    final normCamp = campId.toLowerCase().trim();
    return allowed.any((c) => c.toLowerCase().trim() == normCamp ||
        (normCamp == 'haji_camp' && c.toLowerCase().contains('haji')) ||
        (normCamp == 'saddar' && (c.toLowerCase().contains('saddar') || c.toLowerCase().contains('kap'))));
  }

  bool _isSessionAllowed(String sessionValue) {
    final allowed = _allowedSessions;
    if (allowed.contains('all')) return true;
    if (sessionValue == 'auto') {
      final current = CampSessionService.getCurrentSession(null, widget.branchId);
      return allowed.contains(current);
    }
    return allowed.contains(sessionValue);
  }

  String _completedFilter = 'my'; // 'my' vs 'all'
  String _selectedSession = 'auto'; // 'auto' (Current Active Shift), 'morning', 'evening', 'night', 'all'
  String _doctorScopeFilter = 'all'; // 'my' vs 'all' for Total list

  bool _isDoctorMatch(String? docA, String? docB) {
    if (docA == null || docB == null) return false;
    String cleanA = docA.trim().toLowerCase().replaceAll('dr.', '').replaceAll('dr', '').replaceAll('doctor', '').replaceAll('.', '').trim();
    String cleanB = docB.trim().toLowerCase().replaceAll('dr.', '').replaceAll('dr', '').replaceAll('doctor', '').replaceAll('.', '').trim();
    if (cleanA.isEmpty || cleanB.isEmpty) return false;
    return cleanA == cleanB || cleanA.contains(cleanB) || cleanB.contains(cleanA);
  }

  bool _isPrescribedByMe(Map<String, dynamic> p, [Map<String, dynamic>? optionalPresc]) {
    final myDocId = (widget.doctorId ?? '').trim().toLowerCase();
    final myDocName = (widget.doctorName ?? '').trim();

    // If no doctor context was passed, default to allow
    if (myDocId.isEmpty && myDocName.isEmpty) return true;

    final presc = optionalPresc ?? ((p['prescription'] is Map)
        ? Map<String, dynamic>.from(p['prescription'] as Map)
        : (LocalStorageService.getLocalPrescription((p['serial'] ?? p['id'] ?? '').toString()) ?? {}));

    final pDocId = (presc['doctorId'] ?? presc['prescribedById'] ?? p['doctorId'] ?? p['prescribedById'] ?? '').toString().trim().toLowerCase();
    final pDocName = (presc['doctorName'] ?? presc['prescribedBy'] ?? presc['prescribedByName'] ?? presc['examinedBy'] ?? presc['performedBy'] ?? p['doctorName'] ?? p['prescribedBy'] ?? p['prescribedByName'] ?? p['examinedBy'] ?? p['performedBy'] ?? '').toString().trim();

    if (myDocId.isNotEmpty && pDocId.isNotEmpty) {
      if (pDocId == myDocId || pDocId.contains(myDocId) || myDocId.contains(pDocId)) return true;
    }
    if (myDocName.isNotEmpty && pDocName.isNotEmpty) {
      if (_isDoctorMatch(pDocName, myDocName)) return true;
    }
    return false;
  }

  bool _isEffectivelyToday(Map<String, dynamic> e, String currentTodayKey, String todayIso) {
    final status = (e['status'] ?? '').toString().toLowerCase().trim();
    final dispenseStatus = (e['dispenseStatus'] ?? '').toString().toLowerCase().trim();
    final isTerminal = status == 'completed' ||
        status == 'dispensed' ||
        status == 'cancelled' ||
        status == 'expired' ||
        status == 'reversed' ||
        status == 'deleted' ||
        dispenseStatus == 'dispensed';

    final serial = (e['serial'] ?? e['id'] ?? '').toString().trim();
    final serialDk = CampSessionService.getDateKeyFromSerial(serial);
    final dk = (e['dateKey'] ?? '').toString().trim();
    final rawTime = e['createdAt'] ?? e['timestamp'] ?? e['date'] ?? e['time'];

    // 1. Exact match with today's dateKey or ISO date string
    bool isTodayExact = false;
    if (dk == currentTodayKey || (serialDk.isNotEmpty && serialDk == currentTodayKey)) {
      isTodayExact = true;
    } else if (rawTime != null) {
      final rawStr = rawTime.toString();
      if (rawStr.startsWith(todayIso)) {
        isTodayExact = true;
      } else {
        final dt = DateTime.tryParse(rawStr);
        if (dt != null) {
          final dtKey = CampSessionService.resolveShiftAndDateKey(dt, widget.branchId).dateKey;
          if (dtKey == currentTodayKey) isTodayExact = true;
        }
      }
    }

    if (isTodayExact) return true;

    // 2. Shift/Rollover Tolerance [FIX-B]: If the token's status is non-terminal
    // (still actively waiting / in-progress), also accept the previous calendar day's dateKey
    // or timestamp within 24h so active patients don't suddenly vanish across boundaries.
    if (!isTerminal) {
      final prevDateKey = DateFormat('ddMMyy').format(DateTime.now().subtract(const Duration(days: 1)));
      final prevTodayIso = DateFormat('yyyy-MM-dd').format(DateTime.now().subtract(const Duration(days: 1)));

      if (dk == prevDateKey || (serialDk.isNotEmpty && serialDk == prevDateKey)) {
        return true;
      }
      if (rawTime != null) {
        final rawStr = rawTime.toString();
        if (rawStr.startsWith(prevTodayIso)) {
          return true;
        }
        final dt = DateTime.tryParse(rawStr);
        if (dt != null && DateTime.now().difference(dt).inHours < 24) {
          return true;
        }
      }
    }

    return false;
  }

  // ─── Strict two-group sort ─────────────────────────────────────────────────
  List<Map<String, dynamic>> _getSortedQueue() {
    final currentRealShift = CampSessionService.getCurrentSession(null, widget.branchId);
    final targetShift = _selectedSession == 'auto' ? currentRealShift : _selectedSession;
    final allowedCamps = _allowedCamps;

    final effectiveCamp = _hasMultiCamps
        ? ((_selectedCampFilter.isNotEmpty && _selectedCampFilter != 'all')
            ? _selectedCampFilter
            : (allowedCamps.isNotEmpty && !allowedCamps.contains('all')
                ? allowedCamps.first
                : CampSessionService.getActiveCamp(widget.branchId)))
        : null;

    final todayStr = DateFormat('yyyy-MM-dd').format(DateTime.now());
    final currentTodayKey = _todayKey;

    var all = LocalStorageService.getLocalEntries(widget.branchId)
        .where((e) {
          final serial = (e['serial'] ?? e['id'] ?? '').toString().trim();
          if (serial.isEmpty) return false;

          // [FIX-B] Check if effectively today (shift-aware with rollover tolerance for waiting tokens)
          if (!_isEffectivelyToday(e, currentTodayKey, todayStr)) {
            return false;
          }

          // Strict camp matching in multi-camp branch
          if (_hasMultiCamps && effectiveCamp != null && effectiveCamp.isNotEmpty && effectiveCamp != 'all') {
            final matches = CampSessionService.matchesCamp(
              selectedCamp: effectiveCamp,
              dispensaryId: e['dispensaryId']?.toString(),
              campId: e['campId']?.toString(),
              dispensaryTag: e['dispensaryTag']?.toString(),
              serial: serial,
            );
            if (!matches) return false;
          }

          return true;
        })
        .toList();

    // Deduplicate by normalized uppercase serial (stripping branch prefix)
    final Map<String, Map<String, dynamic>> uniqueBySerial = {};
    for (final e in all) {
      String s = (e['serial'] ?? e['id'] ?? '').toString().trim().toUpperCase();
      final branchPrefix = '${widget.branchId.trim().toUpperCase()}-';
      if (s.startsWith(branchPrefix)) {
        s = s.substring(branchPrefix.length);
      }
      if (s.isEmpty) continue;
      if (!uniqueBySerial.containsKey(s)) {
        uniqueBySerial[s] = Map<String, dynamic>.from(e);
      } else {
        final target = uniqueBySerial[s]!;
        e.forEach((k, v) {
          if (v != null && v != '' && v != 'unknown') {
            final old = target[k];
            if (old == null || old == '' || old == 'unknown') {
              target[k] = v;
            }
          }
        });
        final eSt = (e['status'] ?? '').toString().toLowerCase();
        final tSt = (target['status'] ?? '').toString().toLowerCase();
        if (eSt == 'completed' || tSt == 'completed') {
          target['status'] = 'completed';
        }
        final eDisp = (e['dispenseStatus'] ?? '').toString().toLowerCase();
        final tDisp = (target['dispenseStatus'] ?? '').toString().toLowerCase();
        if (eDisp == 'dispensed' || tDisp == 'dispensed') {
          target['dispenseStatus'] = 'dispensed';
          target['status'] = 'completed';
        }
      }
    }
    all = uniqueBySerial.values.toList();

    // Filter by target shift if not 'all'
    if (targetShift != 'all') {
      all = all.where((entry) {
        String resolved = (entry['session'] ?? entry['shift'] ?? entry['campSession'] ?? entry['slot'] ?? '').toString().toLowerCase().trim();

        // Infer session from createdAt or prescription completedAt if explicit session is missing
        if (resolved.isEmpty || resolved == 'unknown' || resolved == 'all' || resolved == 'auto') {
          final presc = entry['prescription'];
          final rawTime = entry['createdAt'] ??
              entry['time'] ??
              entry['timestamp'] ??
              entry['date'] ??
              (presc is Map ? (presc['completedAt'] ?? presc['createdAt'] ?? presc['timestamp']) : null);

          if (rawTime != null) {
            DateTime? dt;
            if (rawTime is Timestamp) {
              dt = rawTime.toDate().toLocal();
            } else if (rawTime is DateTime) {
              dt = rawTime.toLocal();
            } else {
              dt = DateTime.tryParse(rawTime.toString())?.toLocal();
            }
            if (dt != null) {
              final hasNight = _allowedSessions.contains('night');
              if (dt.hour >= 6 && dt.hour < 14) {
                resolved = 'morning';
              } else if (dt.hour >= 14 && (dt.hour < 22 || !hasNight)) {
                resolved = 'evening';
              } else if (hasNight && (dt.hour >= 22 || dt.hour < 6)) {
                resolved = 'night';
              } else {
                resolved = CampSessionService.getCurrentSession(dt, widget.branchId);
              }
            }
          }
        }

        if (resolved.isNotEmpty && resolved != 'unknown' && resolved != 'all' && resolved != 'auto') {
          return resolved == targetShift;
        }

        // For non-terminal active tokens (waiting / in consultation), allow into current active real shift
        final status = (entry['status'] ?? '').toString().toLowerCase();
        final isWaitingOrConsult = status == 'waiting' || status == 'in_consultation' || status == 'in consultation';
        if (isWaitingOrConsult) {
          return targetShift == currentRealShift;
        }

        // For completed tokens with unknown session, do not leak into targetShift
        return false;
      }).toList();
    }

    final waiting = <Map<String, dynamic>>[];
    final skipped = <Map<String, dynamic>>[];
    final others  = <Map<String, dynamic>>[];

    for (final e in all) {
      final serial = (e['serial'] ?? e['id'] ?? '').toString().trim();
      final presc = e['prescription'];
      final hasRealPresc = presc is Map && (
        (presc['prescriptions'] is List && (presc['prescriptions'] as List).isNotEmpty) ||
        (presc['medicines'] is List && (presc['medicines'] as List).isNotEmpty) ||
        (presc['isVitalsOnly'] == true && presc['completedAt'] != null)
      );
      final isDispensed = (e['dispenseStatus'] ?? '').toString().toLowerCase() == 'dispensed';
      var status = (e['status'] ?? '').toString().toLowerCase();

      // Self-Healing Guard: If patient is already dispensed, mark as completed
      if (isDispensed) {
        if (status != 'completed') {
          e['status'] = 'completed';
          status = 'completed';
          final normBranch = widget.branchId.toLowerCase().trim();
          final normSerial = serial.toUpperCase();
          try {
            if (Hive.isBoxOpen(LocalStorageService.entriesBox)) {
              Hive.box(LocalStorageService.entriesBox).put('$normBranch-$normSerial', LocalStorageService.sanitize(e));
            }
          } catch (_) {}
        }
      }

      final isCompletedOrPrescribed = status == 'completed' || status == 'prescribed' || isDispensed || hasRealPresc;
      final isSkipped = status == 'skipped';

      if (isCompletedOrPrescribed) {
        others.add(e);
      } else if (isSkipped) {
        skipped.add(e);
      } else {
        waiting.add(e);
      }
    }

    int compareTokens(Map<String, dynamic> a, Map<String, dynamic> b) {
      final numA = _extractSerialNumber(a);
      final numB = _extractSerialNumber(b);
      if (numA != numB) return numA.compareTo(numB);
      final dtA = a['createdAt']?.toString() ?? '';
      final dtB = b['createdAt']?.toString() ?? '';
      return dtA.compareTo(dtB);
    }

    waiting.sort(compareTokens);
    skipped.sort(compareTokens);
    others.sort(compareTokens);

    return [...waiting, ...skipped, ...others];
  }

  List<Map<String, dynamic>> _getPreviousDaysCarryoverQueue() {
    return [];
  }

  Future<void> _closeOutDay(String dateKey) async {
    final count = await LocalStorageService.expireUnservedTokensForDate(widget.branchId, dateKey);
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('✅ Closed out day $dateKey. Expired $count unserved token(s).'),
        backgroundColor: Colors.teal,
      ));
      setState(() {});
    }
  }

  List<Map<String, dynamic>> _loadLocalExceptionRequests() {
    final box = Hive.box('app_settings');
    return box.keys
        .where((k) => k.toString().startsWith('pending_exception_'))
        .map((k) => Map<String, dynamic>.from(box.get(k) as Map))
        .where((r) =>
            r['branchId']?.toString() == widget.branchId &&
            r['status']?.toString() == 'pending')
        .toList();
  }

  bool _isOnline = true;

  bool get _isKarachi {
    final b = widget.branchId.toLowerCase().trim();
    return b.contains('karachi') || b.contains('haji') || b.contains('saddar') || b.contains('kapaya');
  }

  // ── Pricing: base PKR per day per queue type ───────────────────────────────
  Map<String, int> get _baseDayPrice => {
    'zakat':     20,
    'non-zakat': _isKarachi ? 20 : 100,
    'gmwf':      0,
  };

  // ─── Queue-type normaliser ─────────────────────────────────────────────────
  String _normaliseQueueType(String? raw) {
    final s = (raw ?? '').toLowerCase().trim();
    if (s == 'non-zakat' || s == 'non zakat' || s == 'nonzakat' ||
        s == 'non_zakat' || s.startsWith('non')) {
      if (_isKarachi) return 'zakat';
      return 'non-zakat';
    }
    if (s == 'gmwf' || s == 'gm wf' || s == 'gm-wf' || s == 'gm_wf') {
      return 'gmwf';
    }
    return 'zakat';
  }

  @override
  void initState() {
    super.initState();

    LocalStorageService.ensureDoctorBoxesOpen();

    if (_hasMultiCamps) {
      final active = CampSessionService.getActiveCamp(widget.branchId);
      if (active != null && active.isNotEmpty && active != 'all') {
        _selectedCampFilter = active;
      }
    }
    CampSessionService.activeCampNotifier.addListener(_onActiveCampChanged);

    _realtimeSub = RealtimeManager().messageStream.listen((event) {
      final type = event['event_type'] as String?;
      final rawData = event['data'];
      final data = (rawData is Map) ? Map<String, dynamic>.from(rawData) : Map<String, dynamic>.from(event);
      if (!mounted || type == null) return;

      final msgBranch = (data['branchId'] ?? event['branchId'])?.toString().toLowerCase().trim();
      final myBranch  = widget.branchId.toLowerCase().trim();
      if (msgBranch != null && msgBranch.isNotEmpty && msgBranch != myBranch) return;

      if (type == RealtimeEvents.saveEntry ||
          type == 'token_created' ||
          type == 'save_entry') {
        final serial = (data['serial'] ?? data['id'])?.toString();
        if (serial != null && serial.isNotEmpty) {
          LocalStorageService.saveEntryLocal(widget.branchId, serial, data);
        }
        _debouncedRebuild();
      } else if (type == 'dispense_completed') {
        final serial = (data['serial'] ?? data['id'])?.toString();
        if (serial != null && serial.isNotEmpty) {
          LocalStorageService.updateDispenseStatus(widget.branchId, serial, 'dispensed');
        }
        _debouncedRebuild();
      } else if (type == RealtimeEvents.savePrescription || type == 'prescription_created' || type == 'save_prescription') {
        if (data.isNotEmpty) {
          LocalStorageService.saveLocalPrescription(data);
          // [FIX] Link prescription → entry in entriesBox (mirrors server SSM).
          // Without this, the entry stays 'waiting' because only prescriptionsBox
          // was updated — the queue reads from entriesBox.
          final serial = (data['serial'] ?? data['id'])?.toString().trim();
          if (serial != null && serial.isNotEmpty) {
            try {
              if (Hive.isBoxOpen(LocalStorageService.entriesBox)) {
                final eBox = Hive.box(LocalStorageService.entriesBox);
                final normBranch = widget.branchId.toLowerCase().trim();
                final key = '$normBranch-$serial';
                final existing = eBox.get(key) ?? eBox.get('$normBranch-${serial.toUpperCase()}');
                if (existing != null && existing is Map) {
                  final updated = Map<String, dynamic>.from(existing);
                  updated['status'] = 'completed';
                  updated['prescription'] = data;
                  updated['prescriptionId'] = data['id'] ?? serial;
                  updated['completedAt'] ??= data['completedAt'] ?? DateTime.now().toIso8601String();
                  if (data['doctorName'] != null) updated['doctorName'] = data['doctorName'];
                  if (data['doctorId'] != null) updated['doctorId'] = data['doctorId'];
                  if (data['daysOfMedicine'] != null) updated['daysOfMedicine'] = data['daysOfMedicine'];
                  eBox.put(existing == eBox.get(key) ? key : '$normBranch-${serial.toUpperCase()}', updated);
                }
              }
            } catch (_) {}
          }
        }
        _debouncedRebuild();
      } else if (type == RealtimeEvents.saveStockItem || type == 'save_stock_item' || type == 'medicine_registered') {
        LocalStorageService.saveLocalInventoryItem(data);
        if (mounted) setState(() {});
      } else if (type == RealtimeEvents.deleteStockItem || type == 'delete_stock_item') {
        final mId = (data['id'] ?? data['medicineId'])?.toString();
        if (mId != null) LocalStorageService.deleteLocalStockItem(mId);
        _debouncedRebuild();
      } else if (type == RealtimeEvents.tokenExceptionRequest || type == 'token_exception_request') {
        final requestId = (data['requestId'] ?? data['id'])?.toString() ??
            'local_${DateTime.now().millisecondsSinceEpoch}';
        final localReq = <String, dynamic>{
          'id':          requestId,
          'requestType': 'token_exception',
          'status':      'pending',
          'patientId':   data['patientId'] ?? '',
          'patientName': data['patientName'] ?? 'Unknown',
          'restriction': data['restriction'],
          'branchId':    widget.branchId,
        };
        Hive.box('app_settings').put(
            'pending_exception_$requestId',
            LocalStorageService.sanitize(localReq));
        if (mounted) {
          setState(() {
            _localExceptionRequests = _loadLocalExceptionRequests();
          });
        }
            } else if (type == RealtimeEvents.tokenExceptionApproved ||
                 type == 'token_exception_approved' ||
                 type == 'token_exception_rejected') {
        final reqId = (data['requestId'] ?? data['id'])?.toString();
        if (reqId != null && reqId.isNotEmpty) {
          _exceptionRequests.removeWhere((doc) => doc.id == reqId);
          _localExceptionRequests.removeWhere((r) => r['id'] == reqId);
          Hive.box('app_settings').delete('pending_exception_$reqId');
          if (mounted) setState(() {});
        }
      } else if (type == RealtimeEvents.tokenReversalApproved || type == 'token_reversal_approved') {
        final serial = (data['tokenSerial'] ?? data['serial'] ?? data['tokenId'])?.toString();
        if (serial != null && serial.isNotEmpty) {
          LocalStorageService.deleteLocalEntry(widget.branchId, serial);
          LocalStorageService.deleteLocalPrescription(serial);
          _debouncedRebuild();
        }
      }
    });

    _connSub = Connectivity().onConnectivityChanged.listen((results) {
      final online = results.any((r) => r != ConnectivityResult.none);
      if (_isOnline != online && mounted) {
        setState(() => _isOnline = online);
      }
    });

    WidgetsBinding.instance.addPostFrameCallback((_) {
      _tryAutoSelectSmallestWaiting();
    });
  }

  @override
  void didUpdateWidget(PatientQueue oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.selectedPatient != widget.selectedPatient ||
        widget.selectedPatient == null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _tryAutoSelectSmallestWaiting();
      });
    }
  }

  void _onActiveCampChanged() {
    if (!mounted || !_hasMultiCamps) return;
    final active = CampSessionService.getActiveCamp(widget.branchId);
    if (active != null && active.isNotEmpty && active != 'all' && active != _selectedCampFilter) {
      setState(() {
        _selectedCampFilter = active;
      });
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _tryAutoSelectSmallestWaiting();
      });
    }
  }

  @override
  void dispose() {
    _debounceRebuildTimer?.cancel();
    _realtimeSub.cancel();
    _connSub?.cancel();
    CampSessionService.activeCampNotifier.removeListener(_onActiveCampChanged);
    super.dispose();
  }
  
  // ─── Debounce rebuild to batch events ─────────────────────
  void _debouncedRebuild() {
    if (_debounceRebuildTimer?.isActive ?? false) return;
    _debounceRebuildTimer = Timer(const Duration(milliseconds: 150), () {
      if (mounted) setState(() {});
    });
  }

  // ─── On-Demand Cloud Recovery with 30s Cooldown (Zero Continuous Reads) ───
  DateTime? _lastCloudPullTime;
  bool _isCloudPulling = false;

  Future<void> manualCloudPull({bool showToast = true}) async {
    final now = DateTime.now();
    if (_lastCloudPullTime != null && now.difference(_lastCloudPullTime!) < const Duration(seconds: 30)) {
      if (showToast && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Please wait 30 seconds before pulling from cloud again.'),
          duration: Duration(seconds: 2),
        ));
      }
      return;
    }
    _lastCloudPullTime = now;
    if (_isCloudPulling) return;
    _isCloudPulling = true;

    try {
      final docKeys = CampSessionService.getAllCampDateDocIds(
        branchId: widget.branchId,
        dateKey: _todayKey,
      );

      for (final campDocKey in docKeys) {
        final serialsRef = FirebaseFirestore.instance
            .collection('branches').doc(widget.branchId)
            .collection('serials').doc(campDocKey);

        for (final type in ['zakat', 'non-zakat', 'gmwf']) {
          try {
            final snap = await serialsRef.collection(type).get(const GetOptions(source: Source.serverAndCache));
            for (final doc in snap.docs) {
              final data = doc.data();
              final serial = doc.id;
              final entryData = Map<String, dynamic>.from(data);
              entryData['serial']    ??= serial;
              entryData['queueType'] ??= type;
              entryData['dateKey']   ??= _todayKey;
              if (entryData['prescription'] is Map && (entryData['prescription'] as Map).isNotEmpty) {
                LocalStorageService.saveLocalPrescription(Map<String, dynamic>.from(entryData['prescription'] as Map));
              }
              await LocalStorageService.saveEntryLocal(widget.branchId, serial, entryData);
            }
          } catch (_) {}
        }
      }
      if (mounted) {
        _debouncedRebuild();
        if (showToast) {
          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text('✅ Cloud pull complete.'),
            backgroundColor: Colors.green,
            duration: Duration(seconds: 2),
          ));
        }
      }
    } finally {
      _isCloudPulling = false;
    }
  }

  Future<void> _approveException(Map<String, dynamic> data) async {
    final patientId = data['patientId'] as String;
    final requestId = data['id'] as String;

    final reasonCtrl = TextEditingController();
    final approved = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Approve Exception'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('Why are you allowing this patient (${data['patientName']}) to get a token again today?'),
            const SizedBox(height: 12),
            TextField(
              controller: reasonCtrl,
              decoration: const InputDecoration(
                hintText: 'Enter reason (e.g. emergency, correction)',
                border: OutlineInputBorder(),
              ),
              maxLines: 2,
            ),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.green,
              foregroundColor: Colors.white,
            ),
            child: const Text('Approve'),
          ),
        ],
      ),
    );

    if (approved != true) return;
    final doctorReason = reasonCtrl.text.trim();
    if (doctorReason.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('Please enter a reason for the exception'),
      ));
      return;
    }

    try {
      try {
        await FirebaseFirestore.instance
            .collection('branches')
            .doc(widget.branchId)
            .collection('edit_requests')
            .doc(requestId)
            .update({
          'status': 'approved',
          'doctorReason': doctorReason,
          'approvedBy': RealtimeManager().role ?? 'Doctor',
          'approvedAt': FieldValue.serverTimestamp(),
        });
      } catch (e) {
        debugPrint('[PatientQueue] Firestore offline update failed: $e');
      }

      await LocalStorageService.enqueueSync({
        'type':      'approve_token_exception',
        'branchId':  widget.branchId,
        'requestId': requestId,
        'patientId': patientId,
        'data': {
          'doctorReason': doctorReason,
          'approvedBy':   RealtimeManager().role ?? 'Doctor',
          'approvedAt':   DateTime.now().toIso8601String(),
        },
      });

      await LocalStorageService.grantTokenException(
        widget.branchId,
        patientId,
        reason: doctorReason,
        approvedBy: RealtimeManager().role ?? 'Doctor',
        requestId: requestId,
      );
      Hive.box('app_settings').delete('pending_exception_$requestId');
      _exceptionRequests.removeWhere((doc) => doc.id == requestId);
      _localExceptionRequests.removeWhere((r) => r['id'] == requestId);

      RealtimeManager().sendMessage({
        ...RealtimeEvents.payload(
          type: RealtimeEvents.tokenExceptionApproved,
          branchId: widget.branchId,
          data: {
            'requestId':  requestId,
            'patientId':  patientId,
            'reason':     doctorReason,
            'approvedBy': RealtimeManager().role ?? 'Doctor',
          },
        ),
      });

      if (mounted) {
        setState(() {
          _localExceptionRequests = _loadLocalExceptionRequests();
        });
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('✅ Exception approved. Restriction cleared.'),
          backgroundColor: Colors.green,
        ));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Failed: $e')));
      }
    }
  }

  Future<void> _rejectException(Map<String, dynamic> data) async {
    final requestId  = data['id'] as String;
    final reasonCtrl = TextEditingController();

    final rejected = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Reject Exception'),
        content: TextField(
          controller: reasonCtrl,
          decoration: const InputDecoration(hintText: 'Reason for rejection'),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.red,
              foregroundColor: Colors.white,
            ),
            child: const Text('Reject'),
          ),
        ],
      ),
    );

    if (rejected != true) return;

    try {
      await FirebaseFirestore.instance
          .collection('branches')
          .doc(widget.branchId)
          .collection('edit_requests')
          .doc(requestId)
          .update({
        'status': 'rejected',
        'doctorReason': reasonCtrl.text.trim(),
        'rejectedBy': RealtimeManager().role ?? 'Doctor',
        'rejectedAt': FieldValue.serverTimestamp(),
      });

      Hive.box('app_settings').delete('pending_exception_$requestId');
      _exceptionRequests.removeWhere((doc) => doc.id == requestId);
      _localExceptionRequests.removeWhere((r) => r['id'] == requestId);

      if (mounted) {
        setState(() {
          _localExceptionRequests = _loadLocalExceptionRequests();
        });
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('❌ Exception request rejected.'),
          backgroundColor: Colors.red,
        ));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Failed: $e')));
      }
    }
  }

  // ─── Serial number extraction ──────────────────────────────────────────────
  int _extractSerialNumber(Map<String, dynamic> p) {
    final s = (p['serial'] ?? p['id'] ?? '').toString();
    return parseSequenceFromSerial(s);
  }

  // ─── Auto-select smallest waiting ─────────────────────────────────────────
  void _tryAutoSelectSmallestWaiting() {
    if (!mounted) return;
    if (widget.selectedPatient != null) return;
    
    // ← HANG FIX: Use cached queue if fresh, avoid recalculation
    final now = DateTime.now();
    final isCacheValid = _cachedQueue != null && 
                        _queueCacheTime != null && 
                        now.difference(_queueCacheTime!) < _queueCacheTTL;
    
    final queue = isCacheValid ? _cachedQueue! : _getSortedQueue();
    
    // Cache the result for 500ms
    if (!isCacheValid) {
      _cachedQueue = queue;
      _queueCacheTime = now;
    }
    
    final waiting = queue.where((p) {
      final s = (p['status'] ?? '').toString().toLowerCase();
      final presc = p['prescription'];
      final hasRealPresc = presc is Map && (
        (presc['prescriptions'] is List && (presc['prescriptions'] as List).isNotEmpty) ||
        (presc['medicines'] is List && (presc['medicines'] as List).isNotEmpty) ||
        (presc['isVitalsOnly'] == true && presc['completedAt'] != null)
      );
      final isDisp = (p['dispenseStatus'] ?? '').toString().toLowerCase() == 'dispensed' || s == 'dispensed';
      final isDone = s == 'completed' || s == 'prescribed' || isDisp || hasRealPresc;
      if (isDone || s == 'skipped') return false;

      final activeDoc = p['activeDoctor']?.toString().trim();
      if (activeDoc != null && activeDoc.isNotEmpty && !_isDoctorMatch(activeDoc, widget.doctorName)) {
        return false; // Skip if currently being examined by another doctor
      }
      return true;
    }).toList();
    if (waiting.isEmpty) return;

    final smallest       = waiting.first;
    final smallestSerial = smallest['serial']?.toString() ?? smallest['id']?.toString() ?? '';
    debugPrint('[PatientQueue] Auto-selecting smallest waiting: $smallestSerial');
    widget.onPatientSelected({...smallest, 'serial': smallestSerial, 'id': smallestSerial});
  }



  // ─── Injection / drip check ───────────────────────────────────────────────
  bool _isInjectionOrDrip(Map<String, dynamic> med) {
    final type = (med['type'] ?? '').toString().toLowerCase();
    final name = (med['name'] ?? '').toString().toLowerCase();
    return type.contains('injection') || type.contains('inj') ||
        type.contains('drip') ||
        name.contains('inj.') || name.contains('drip');
  }

  // ─── Medicine abbreviation helper ─────────────────────────────────────────
  String _getMedAbbrev(Map<String, dynamic> med) {
    final rawName = (med['name'] ?? '').toString().trim().toLowerCase();
    final rawType = (med['type'] ?? '').toString().trim().toLowerCase();
    final prefixes = {
      'syrup': 'syp.', 'syp': 'syp.',
      'capsule': 'cap.', 'cap': 'cap.',
      'tablet': 'tab.', 'tab': 'tab.',
      'injection': 'inj.', 'inj': 'inj.',
      'drip': 'drip.', 'syringe': 'syr.', 'syr': 'syr.',
    };
    String? abbrev;
    for (var entry in prefixes.entries) {
      if (rawType.contains(entry.key) || rawName.contains(entry.key)) {
        abbrev = entry.value;
        break;
      }
    }
    if (abbrev == null) return '';
    if (rawName.startsWith(abbrev.toLowerCase())) return '';
    return abbrev;
  }

  int _getAvailableStock(
    Map<String, dynamic>? inventoryMed, {
    required String branchId,
    required List<Map<String, dynamic>> currentMeds,
    String? excludeSerial,
  }) {
    if (inventoryMed == null) return 999999;

    final invQty = inventoryMed['quantity'];
    final totalStock = (invQty is num ? invQty.toInt() : int.tryParse(invQty?.toString() ?? '') ?? 0);
    final inventoryId = inventoryMed['id']?.toString() ?? '';

    // Quantity reserved by OTHER pending patients (from Hive scan)
    if (!Hive.isBoxOpen(LocalStorageService.prescriptionsBox) || !Hive.isBoxOpen(LocalStorageService.entriesBox)) {
      return totalStock;
    }
    final prescBox   = Hive.box(LocalStorageService.prescriptionsBox);
    final entriesBox = Hive.box(LocalStorageService.entriesBox);
    final mySerial   = excludeSerial?.trim().toLowerCase();

    int reservedByOthers = 0;
    for (final key in prescBox.keys) {
      final raw = prescBox.get(key);
      if (raw is! Map) continue;
      final presc = Map<String, dynamic>.from(raw);

      final prescSerial = (presc['serial'] ?? presc['id'] ?? '')
          .toString().trim().toLowerCase();
      if (prescSerial == mySerial) continue;

      final entryKey = '$branchId-$prescSerial';
      final entry    = entriesBox.get(entryKey);
      if (entry is Map) {
        final dispenseStatus =
            (entry['dispenseStatus'] ?? '').toString().toLowerCase();
        if (dispenseStatus == 'dispensed') continue;
      }

      final dispenseStatusOnPresc =
          (presc['dispenseStatus'] ?? '').toString().toLowerCase();
      if (dispenseStatusOnPresc == 'dispensed') continue;

      final meds = presc['prescriptions'];
      if (meds is! List) continue;

      for (final med in meds) {
        if (med is! Map) continue;
        if (med['inventoryId']?.toString() == inventoryId) {
          final medQty = med['quantity'];
          final qty = (medQty is num ? medQty.toInt() : int.tryParse(medQty?.toString() ?? '') ?? 0);
          final days = (presc['daysOfMedicine'] as int?) ?? 1;
          final type = (med['type'] ?? '').toString().toLowerCase();
          final isInj = type.contains('injection') || type.contains('inj') ||
              type.contains('drip') || type.contains('syringe') ||
              type.contains('nebulization');
          reservedByOthers += isInj ? qty : qty * days;
        }
      }
    }

    // Quantity already added in THIS dialog/edit session for this patient
    int sessionQty = 0;
    for (final med in currentMeds) {
      if (med['inventoryId']?.toString() == inventoryId) {
        final medQty = med['quantity'];
        sessionQty += (medQty is num ? medQty.toInt() : int.tryParse(medQty?.toString() ?? '') ?? 0);
      }
    }

    final available = totalStock - reservedByOthers - sessionQty;
    return available < 0 ? 0 : available;
  }

  // ─── Add medicine sub-dialog ───────────────────────────────────────────────
  Future<Map<String, dynamic>?> _showAddMedicineSubDialog({
    required String branchId,
    required List<Map<String, dynamic>> currentMeds,
    required int daysOfMedicine,
    String? excludeSerial,
    Map<String, dynamic>? inventoryMed,
  }) async {
    final isInventory = inventoryMed != null;
    final nameCtrl    = TextEditingController(text: isInventory ? inventoryMed['name'] : '');
    final timingCtrl  = TextEditingController();
    final qtyCtrl     = TextEditingController(text: '1');
    String mealTiming = 'After Meal';
    String dosage     = '1 spoon';
    bool isSyrup      = false;
    bool isInjection  = false;

    void updateFields() {
      if (isInventory) {
        final type  = (inventoryMed['type'] ?? '').toString().toLowerCase();
        final name  = (inventoryMed['name'] ?? '').toString().toLowerCase();
        isInjection = type.contains('injection') || type.contains('inj') ||
                      type.contains('infusion') || type.contains('inf') ||
                      type.contains('drip') ||
                      name.contains('inj') || name.contains('infusion') || name.contains('drip');
        isSyrup     = type.contains('syrup')     || type.contains('syp') || name.contains('syp') || name.contains('syrup');
      } else {
        final text  = nameCtrl.text.toLowerCase();
        isInjection = text.contains('inj.') || text.contains('inj') ||
                      text.contains('inf.') || text.contains('infusion') ||
                      text.contains('drip');
        isSyrup     = text.contains('syp.') || text.contains('syrup');
      }
    }

    updateFields();
    if (!isInventory) nameCtrl.addListener(updateFields);

    final result = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(isInventory ? 'Add Inventory Medicine' : 'Add Custom Medicine'),
        content: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            TextField(
              controller: nameCtrl, readOnly: isInventory,
              decoration: InputDecoration(
                labelText: 'Medicine name', border: const OutlineInputBorder(),
                filled: isInventory, fillColor: isInventory ? Colors.grey[200] : null),
            ),
            const SizedBox(height: 12),
            if (!isInjection) ...[
              const Text('Timing (M+E+N):'),
              const SizedBox(height: 6),
              TextField(
                controller: timingCtrl, keyboardType: TextInputType.number,
                inputFormatters: [
                  FilteringTextInputFormatter.digitsOnly,
                  LengthLimitingTextInputFormatter(3),
                ],
                decoration: const InputDecoration(
                    hintText: 'e.g. 1+0+2', border: OutlineInputBorder()),
                onChanged: (value) {
                  final digits    = value.replaceAll('+', '');
                  if (digits.length > 3) return;
                  final formatted = digits.split('').join('+');
                  if (timingCtrl.text != formatted) {
                    timingCtrl.text = formatted;
                    timingCtrl.selection =
                        TextSelection.collapsed(offset: formatted.length);
                  }
                },
              ),
              const SizedBox(height: 12),
              DropdownButtonFormField<String>(
                initialValue: mealTiming,
                decoration: const InputDecoration(
                    labelText: 'Timing Instruction', border: OutlineInputBorder()),
                items: ['Empty Stomach', 'Before Meal', 'During Meal', 'After Meal', 'Before Sleep']
                    .map((d) => DropdownMenuItem(value: d, child: Text(d))).toList(),
                onChanged: (v) => mealTiming = v!,
              ),
              if (isSyrup) ...[
                const SizedBox(height: 12),
                DropdownButtonFormField<String>(
                  initialValue: dosage,
                  decoration: const InputDecoration(
                      labelText: 'Dosage', border: OutlineInputBorder()),
                  items: ['1 spoon', '1/2 spoon', '1/3 spoon', '1/4 spoon']
                      .map((d) => DropdownMenuItem(value: d, child: Text(d))).toList(),
                  onChanged: (v) => dosage = v!,
                ),
              ],
            ] else
              TextField(
                controller: qtyCtrl, keyboardType: TextInputType.number,
                decoration: const InputDecoration(
                    labelText: 'Quantity', border: OutlineInputBorder()),
              ),
          ]),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel', style: TextStyle(color: _teal)),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: _teal,
              foregroundColor: Colors.white,
            ),
            onPressed: () {
              final name = nameCtrl.text.trim();
              if (name.isEmpty) return;
              Map<String, dynamic> newMed;
              if (isInjection) {
                final qty = int.tryParse(qtyCtrl.text) ?? 1;
                if (qty <= 0) return;
                if (isInventory) {
                  final availableStock = _getAvailableStock(
                    inventoryMed,
                    branchId: branchId,
                    currentMeds: currentMeds,
                    excludeSerial: excludeSerial,
                  );
                  if (qty > availableStock) {
                    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                        content: Text('⚠️ Stock Limit Exceeded! Available: $availableStock'),
                        backgroundColor: Colors.red));
                    return;
                  }
                }
                newMed = {
                  'name': name, 'quantity': qty, 'type': 'Injection',
                  'inventoryId': inventoryMed?['id'],
                };
              } else {
                final digits = timingCtrl.text.replaceAll('+', '');
                final m      = int.tryParse(digits.isNotEmpty ? digits[0] : '0') ?? 0;
                final e      = digits.length > 1 ? int.tryParse(digits[1]) ?? 0 : 0;
                final n      = digits.length > 2 ? int.tryParse(digits[2]) ?? 0 : 0;
                final sum    = m + e + n;
                final qty    = (mealTiming == 'Before Sleep' && sum == 0) ? 1 : sum;
                if (qty == 0) return;
                if (isInventory) {
                  final availableStock = _getAvailableStock(
                    inventoryMed,
                    branchId: branchId,
                    currentMeds: currentMeds,
                    excludeSerial: excludeSerial,
                  );
                  final totalRequired = qty * daysOfMedicine;
                  if (totalRequired > availableStock) {
                    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                        content: Text('⚠️ Stock Limit Exceeded! Need $totalRequired but only $availableStock available.'),
                        backgroundColor: Colors.red));
                    return;
                  }
                }
                newMed = {
                  'name': name, 'quantity': qty, 'timing': '$m+$e+$n',
                  'meal': mealTiming, 'dosage': isSyrup ? dosage : '',
                  'type': isSyrup ? 'Syrup' : 'Tablet',
                  'inventoryId': inventoryMed?['id'],
                };
              }
              Navigator.pop(ctx, newMed);
            },
            child: const Text('Add'),
          ),
        ],
      ),
    );

    nameCtrl.dispose(); timingCtrl.dispose(); qtyCtrl.dispose();
    return result;
  }

  // ─── Days selector widget ──────────────────────────────────────────────────
  Widget _buildDaysSelectorDialog({
    required int selectedDays,
    required String queueType,
    required void Function(int) onChanged,
    bool hasInjection = false,
    int? suggestedDays,
  }) {
    final pricePerDay = _baseDayPrice[queueType] ?? 0;
    final isDark = _isDark;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(children: [
          const Icon(Icons.calendar_month_rounded, color: _teal, size: 18),
          const SizedBox(width: 8),
          const Text('Days of Medicine',
              style: TextStyle(
                  fontWeight: FontWeight.bold, fontSize: 15, color: _teal)),
          if (!hasInjection && pricePerDay > 0 && selectedDays > 1) ...[
            const Spacer(),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(
                color: isDark ? const Color(0xFF451A03) : Colors.orange.shade50,
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: isDark ? const Color(0xFFF97316) : Colors.orange.shade300),
              ),
              child: Text(
                'Extra: PKR ${(selectedDays - 1) * pricePerDay}',
                style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.bold,
                    color: isDark ? const Color(0xFFFDBA74) : Colors.orange.shade800),
              ),
            ),
          ],
        ]),
        const SizedBox(height: 8),
        Row(
          children: [1, 2, 3].map((day) {
            final isSelected = selectedDays == day;
            final isDisabled = hasInjection && day > 1;
            final effectiveColor = isDisabled
                ? (isDark ? const Color(0xFF0F172A) : Colors.grey.shade200)
                : isSelected
                    ? _teal
                    : (isDark ? const Color(0xFF1E293B) : Colors.white);
            return Expanded(
              child: Padding(
                padding: EdgeInsets.only(right: day < 3 ? 8 : 0),
                child: Tooltip(
                  message: isDisabled ? 'Injection prescribed — only 1 day allowed' : '',
                  child: GestureDetector(
                    onTap: isDisabled
                        ? () {
                            ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                              content: Text(
                                  '💉 Injection prescribed — only 1 day of medicine is allowed'),
                              backgroundColor: Colors.orange,
                              duration: Duration(seconds: 2),
                            ));
                          }
                        : () => onChanged(day),
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 160),
                      padding: const EdgeInsets.symmetric(vertical: 6),
                      decoration: BoxDecoration(
                        color: effectiveColor,
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(
                            color: isDisabled
                                ? (isDark ? const Color(0xFF334155) : Colors.grey.shade300)
                                : isSelected
                                    ? _teal
                                    : (isDark ? const Color(0xFF334155) : Colors.grey.shade300),
                            width: isSelected && !isDisabled ? 2 : 1),
                        boxShadow: isSelected && !isDisabled
                            ? [BoxShadow(
                                color: _teal.withValues(alpha: 0.22),
                                blurRadius: 6,
                                offset: const Offset(0, 2))]
                            : [],
                      ),
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Text(
                            '$day',
                            style: TextStyle(
                                fontSize: 16,
                                fontWeight: FontWeight.bold,
                                color: isDisabled
                                    ? Colors.grey.shade400
                                    : isSelected
                                        ? Colors.white
                                        : (isDark ? Colors.white : Colors.grey.shade700)),
                          ),
                          Text(
                            day == 1 ? 'day' : 'days',
                            style: TextStyle(
                                fontSize: 10,
                                color: isDisabled
                                    ? Colors.grey.shade400
                                    : isSelected
                                        ? Colors.white70
                                        : (isDark ? const Color(0xFF94A3B8) : Colors.grey.shade500)),
                          ),
                          if (!isDisabled && pricePerDay > 0 && day > 1)
                            Text(
                              '+PKR ${(day - 1) * pricePerDay}',
                              style: TextStyle(
                                  fontSize: 10,
                                  color: isSelected
                                      ? Colors.white70
                                      : Colors.orange.shade600,
                                  fontWeight: FontWeight.w600),
                            ),
                          if (isDisabled)
                            Icon(Icons.vaccines_rounded,
                                size: 11, color: Colors.grey.shade400),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            );
          }).toList(),
        ),
        const SizedBox(height: 4),
        if (hasInjection)
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: Colors.orange.shade50,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: Colors.orange.shade300),
            ),
            child: Row(children: [
              Icon(Icons.vaccines_rounded, size: 13, color: Colors.orange.shade700),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  'Injection prescribed — only 1 day of medicine is allowed. '
                  'Multi-day selection is disabled.',
                  style: TextStyle(
                      fontSize: 11,
                      color: Colors.orange.shade800,
                      fontWeight: FontWeight.w600),
                ),
              ),
            ]),
          )
        else
          Text(
            pricePerDay > 0
                ? 'Day-1 fee (PKR $pricePerDay) collected at token desk.'
                    '${selectedDays > 1 ? ' Extra PKR ${(selectedDays - 1) * pricePerDay} will be charged.' : ''}'
                : 'No charge for $queueType patients.',
            style: TextStyle(
                fontSize: 11,
                color: Colors.grey.shade600,
                fontStyle: FontStyle.italic),
          ),
      ],
    );
  }

  // ─── Prescription edit dialog ──────────────────────────────────────────────
  Future<void> _showPrescriptionDialog(Map<String, dynamic> patient) async {
    final serial   = (patient['serial'] ?? patient['id'] ?? '').toString().trim();
    final branchId = widget.branchId;

    final patientCnic = (patient['patientCnic'] ?? patient['cnic'] ?? '').toString().trim();
    final patientName = (patient['patientName'] ?? patient['name'] ?? '').toString().trim();

    if (serial.isEmpty) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('Invalid serial number')));
      return;
    }

    Map<String, dynamic> prescData = {};
    Map<String, dynamic> entryData = {};

    // 1. Check if patient map already has prescription
    if (patient['prescription'] is Map && (patient['prescription'] as Map).isNotEmpty) {
      prescData = Map<String, dynamic>.from(patient['prescription'] as Map);
    }

    // 2. Check entriesBox directly
    if (prescData.isEmpty) {
      final entryKey = '$branchId-$serial';
      final entryBox = await LocalStorageService.ensureBoxOpen(LocalStorageService.entriesBox);
      final entryRaw = entryBox.get(entryKey);
      if (entryRaw != null) {
        entryData = Map<String, dynamic>.from(entryRaw);
        final rawEmb = entryData['prescription'];
        final embeddedPresc = (rawEmb is Map) ? Map<String, dynamic>.from(rawEmb) : null;
        if (embeddedPresc != null && embeddedPresc.isNotEmpty) {
          prescData = Map<String, dynamic>.from(embeddedPresc);
          debugPrint('[PrescEdit] Loaded from embedded entry prescription: $serial');
        }
      }
    }

    // 3. Check getLocalPrescription with patient credentials
    if (prescData.isEmpty) {
      final localPresc = LocalStorageService.getLocalPrescription(
        serial,
        cnic: patientCnic,
        patientName: patientName,
        branchId: branchId,
      );
      if (localPresc != null && localPresc.isNotEmpty) {
        prescData = Map<String, dynamic>.from(localPresc);
        debugPrint('[PrescEdit] Loaded from validated local prescription: $serial');
      }
    }

    // 4. Firestore fallback
    if (prescData.isEmpty && _isOnline) {
      debugPrint('[PrescEdit] Falling back to Firestore for: $serial');
      try {
        final ddmmyy = CampSessionService.getDateKeyFromSerial(serial);
        for (final type in ['zakat', 'non-zakat', 'gmwf']) {
          final snap = await FirebaseFirestore.instance
              .collection('branches').doc(branchId)
              .collection('serials').doc(ddmmyy)
              .collection(type).doc(serial).get();
          if (snap.exists) {
            final d = snap.data() ?? <String, dynamic>{};
            entryData = Map<String, dynamic>.from(d);
            entryData['queueType'] = type;
            final rawEmb2 = d['prescription'];
            final embeddedPresc = (rawEmb2 is Map) ? Map<String, dynamic>.from(rawEmb2) : null;
            if (embeddedPresc != null) {
              prescData = Map<String, dynamic>.from(embeddedPresc);
            }
            break;
          }
        }
      } catch (e) {
        debugPrint('[PrescEdit] Firestore fetch failed: $e');
      }
    }

    if (prescData.isEmpty) {
      prescData = {
        'serial': serial,
        'patientCnic': patientCnic,
        'patientName': patientName,
        'prescriptions': <Map<String, dynamic>>[],
        'labResults': <Map<String, dynamic>>[],
        'condition': entryData['condition'] ?? '',
        'diagnosis': entryData['diagnosis'] ?? '',
        'daysOfMedicine': entryData['daysOfMedicine'] ?? 1,
      };
    }

    final String resolvedCnic = (
      prescData['patientCnic']?.toString() ??
      prescData['cnic']?.toString() ??
      entryData['patientCnic']?.toString() ??
      entryData['cnic']?.toString() ??
      patientCnic
    ).replaceAll(RegExp(r'[-\s]'), '').toLowerCase();

    final String resolvedName = (
      prescData['patientName']?.toString() ??
      entryData['patientName']?.toString() ??
      (patientName.isNotEmpty ? patientName : 'Unknown Patient')
    );

    final String queueType = _normaliseQueueType(
      entryData['queueType']?.toString() ??
      prescData['queueType']?.toString() ??
      patient['queueType']?.toString(),
    );

    debugPrint('[PrescEdit] resolved queueType=$queueType for serial=$serial');

    int editDays = (() {
      final d = prescData['daysOfMedicine'] ??
          entryData['daysOfMedicine'] ??
          (entryData['prescription'] is Map
              ? entryData['prescription']['daysOfMedicine']
              : null);
      if (d is int && d >= 1 && d <= 3) return d;
      final suggested = (entryData['suggestedDays'] as int?) ?? (patient['suggestedDays'] as int?);
      if (suggested is int && suggested >= 1 && suggested <= 3) return suggested;
      return 1;
    })();

    final complaintCtrl = TextEditingController(
        text: prescData['condition'] ?? prescData['complaint'] ?? '');
    final diagnosisCtrl = TextEditingController(
        text: prescData['diagnosis'] ?? '');

    List<Map<String, dynamic>> currentMeds = List<Map<String, dynamic>>.from(
        (prescData['prescriptions'] as List<dynamic>?)
            ?.map((e) => Map<String, dynamic>.from(e as Map))
            .toList() ?? []);
    List<Map<String, dynamic>> currentLabs = List<Map<String, dynamic>>.from(
        (prescData['labResults'] as List<dynamic>?)
            ?.map((e) => Map<String, dynamic>.from(e as Map))
            .toList() ?? []);

    final searchCtrl = TextEditingController();
    List<Map<String, dynamic>> searchResults = [];

    String? patientCamp = (patient['dispensaryId'] ?? patient['campId'] ?? patient['dispensaryTag'])?.toString().trim();
    if (patientCamp == null || patientCamp.isEmpty || patientCamp == 'all') {
      final s = serial.toUpperCase();
      if (s.contains('-SADD-') || s.contains('-SADDAR-') || s.contains('-SAD-') || s.contains('-KAP-')) patientCamp = 'saddar';
      else if (s.contains('-HAJI-') || s.contains('-HC-')) patientCamp = 'haji_camp';
    }

    void searchInventory(String q) {
      final query    = q.trim().toLowerCase();
      var allStock   = LocalStorageService.getAllLocalStockItems(branchId: branchId, dispensaryId: patientCamp);
      if (allStock.isEmpty && patientCamp != null && patientCamp.isNotEmpty) {
        allStock = LocalStorageService.getAllLocalStockItems(branchId: branchId, filterByCamp: false);
      }
      searchResults  = query.isEmpty ? []
          : allStock
              .where((m) =>
                  (m['name'] ?? '').toString().toLowerCase().contains(query) ||
                  (m['formula'] ?? '').toString().toLowerCase().contains(query) ||
                  (m['code'] ?? m['barcode'] ?? '').toString().toLowerCase().contains(query))
              .toList();
    }

    await showDialog(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) {
          searchCtrl.addListener(() {
            searchInventory(searchCtrl.text);
            setDialogState(() {});
          });

          return AlertDialog(
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
            title: Row(children: [
              const Icon(Icons.edit_note, color: _teal),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  'Edit Prescription – $resolvedName ($serial)',
                  style: const TextStyle(fontSize: 16),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ]),
            content: SizedBox(
              width: 700,
              height: 640,
              child: SingleChildScrollView(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // ── Complaint ───────────────────────────────────────────
                    TextField(
                      controller: complaintCtrl,
                      decoration: InputDecoration(
                        labelText: 'Patient Complaint',
                        border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(16)),
                        filled: true,
                        fillColor: _isDark ? const Color(0xFF1E293B) : Colors.green[50],
                      ),
                      maxLines: 2,
                    ),
                    const SizedBox(height: 16),

                    // ── Diagnosis ───────────────────────────────────────────
                    TextField(
                      controller: diagnosisCtrl,
                      decoration: InputDecoration(
                        labelText: 'Diagnosis',
                        border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(16)),
                        filled: true,
                        fillColor: _isDark ? const Color(0xFF1E293B) : Colors.green[50],
                      ),
                      maxLines: 3,
                    ),
                    const SizedBox(height: 20),

                    // ── Days selector ───────────────────────────────────────
                    _buildDaysSelectorDialog(
                      selectedDays:  editDays,
                      queueType:     queueType,
                      hasInjection:  currentMeds.any(_isInjectionOrDrip),
                      suggestedDays: (patient['suggestedDays'] as int?) ?? (entryData['suggestedDays'] as int?),
                      onChanged:     (d) => setDialogState(() => editDays = d),
                    ),
                    const SizedBox(height: 20),

                    // ── Medicines ───────────────────────────────────────────
                    const Text('Medicines',
                        style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
                    const SizedBox(height: 8),
                    TextField(
                      controller: searchCtrl,
                      autofocus: true,
                      decoration: InputDecoration(
                        hintText: 'Search inventory & add medicine...',
                        prefixIcon: const Icon(Icons.search),
                        border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(30)),
                        filled: true,
                      ),
                      onChanged: (q) {
                        searchInventory(q);
                        setDialogState(() {});
                      },
                    ),
                    const SizedBox(height: 8),
                    if (searchResults.isNotEmpty)
                      Container(
                        constraints: const BoxConstraints(maxHeight: 200),
                        decoration: BoxDecoration(
                            border: Border.all(color: Colors.grey[300]!),
                            borderRadius: BorderRadius.circular(12)),
                        child: ListView.separated(
                          shrinkWrap: true,
                          itemCount: searchResults.length,
                          separatorBuilder: (_, __) => Divider(
                            height: 1,
                            thickness: 0.8,
                            color: Colors.grey.shade200,
                            indent: 12,
                            endIndent: 12,
                          ),
                          itemBuilder: (ctx, i) {
                            final med      = searchResults[i];
                            final abbrev   = _getMedAbbrev(med);
                            final namePart = (med['name'] ?? '').trim();
                            final medType  = (med['type'] ?? med['dosageForm'] ?? med['form'] ?? '').toString().trim();
                            final dose     = (med['dose'] ?? '').toString().trim();
                            final label    = abbrev.isNotEmpty &&
                                    !namePart.toLowerCase().startsWith(
                                        abbrev.toLowerCase())
                                ? '$abbrev $namePart'
                                : namePart;
                            return ListTile(
                              contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
                              title: Row(
                                children: [
                                  Flexible(child: Text(label, style: const TextStyle(fontWeight: FontWeight.w600))),
                                  if (medType.isNotEmpty) ...[
                                    const SizedBox(width: 6),
                                    Container(
                                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1.5),
                                      decoration: BoxDecoration(
                                        color: Colors.teal.shade50,
                                        border: Border.all(color: Colors.teal.shade300, width: 0.5),
                                        borderRadius: BorderRadius.circular(10),
                                      ),
                                      child: Text(
                                        medType,
                                        style: TextStyle(fontSize: 10, fontWeight: FontWeight.bold, color: Colors.teal.shade800),
                                      ),
                                    ),
                                  ],
                                  if (dose.isNotEmpty) ...[
                                    const SizedBox(width: 4),
                                    Container(
                                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1.5),
                                      decoration: BoxDecoration(
                                        color: Colors.grey.shade100,
                                        border: Border.all(color: Colors.grey.shade400, width: 0.5),
                                        borderRadius: BorderRadius.circular(10),
                                      ),
                                      child: Text(
                                        dose,
                                        style: TextStyle(fontSize: 10, color: Colors.grey.shade700),
                                      ),
                                    ),
                                  ],
                                ],
                              ),
                              trailing: Text(
                                'Stock: ${med['quantity'] ?? 0}',
                                style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 12),
                              ),
                              onTap: () async {
                                final newMed =
                                    await _showAddMedicineSubDialog(
                                  branchId: branchId,
                                  currentMeds: currentMeds,
                                  daysOfMedicine: editDays,
                                  excludeSerial: serial,
                                  inventoryMed: med,
                                );
                                if (newMed != null) {
                                  setDialogState(() {
                                    currentMeds.add(newMed);
                                    final isInj = _isInjectionOrDrip(newMed);
                                    if (isInj && editDays > 1) editDays = 1;
                                    searchCtrl.clear();
                                    searchResults = [];
                                  });
                                }
                              },
                            );
                          },
                        ),
                      )
                    else if (searchCtrl.text.isNotEmpty)
                      const Padding(
                        padding: EdgeInsets.all(16),
                        child: Text('No matching medicines in local inventory',
                            style: TextStyle(color: Colors.grey)),
                      ),
                    const SizedBox(height: 12),
                    if (currentMeds.isEmpty)
                      Container(
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                            border: Border.all(color: Colors.grey[300]!),
                            borderRadius: BorderRadius.circular(8)),
                        child: const Text('No medicines added yet',
                            style: TextStyle(color: Colors.grey)))
                    else
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: currentMeds.map((med) {
                          final abbrev   = _getMedAbbrev(med);
                          final namePart = (med['name'] ?? '').trim();
                          final qty      = med['quantity'] ?? 1;
                          final label    = abbrev.isNotEmpty &&
                                  !namePart
                                      .toLowerCase()
                                      .startsWith(abbrev.toLowerCase())
                              ? '$abbrev $namePart ×$qty'
                              : '$namePart ×$qty';
                          return Chip(
                            label: Text(label),
                            backgroundColor: _teal,
                            labelStyle: const TextStyle(color: Colors.white),
                            onDeleted: () =>
                                setDialogState(() => currentMeds.remove(med)),
                          );
                        }).toList(),
                      ),
                    const SizedBox(height: 16),

                    // ── Lab tests ───────────────────────────────────────────
                    const Text('Lab Tests',
                        style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
                    const SizedBox(height: 8),
                    TextFormField(
                      initialValue: currentLabs.map((l) => l['name']).join(', '),
                      decoration: InputDecoration(
                        hintText: 'Lab tests (comma separated)',
                        border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(16)),
                        filled: true,
                      ),
                      onChanged: (value) {
                        currentLabs = value
                            .split(',')
                            .map((e) => e.trim())
                            .where((e) => e.isNotEmpty)
                            .map((e) => {'name': e})
                            .toList();
                        setDialogState(() {});
                      },
                    ),
                    const SizedBox(height: 8),

                    // ── Source indicator ────────────────────────────────────
                    if (prescData.isNotEmpty && entryData.isEmpty)
                      Text('Source: local prescriptions',
                          style: TextStyle(fontSize: 11, color: Colors.grey[500]))
                    else if (entryData.isNotEmpty)
                      Text('Source: local entry cache',
                          style: TextStyle(fontSize: 11, color: Colors.grey[500]))
                    else
                      Text('Source: Firestore (cloud)',
                          style: TextStyle(fontSize: 11, color: Colors.orange[700])),
                  ],
                ),
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dialogContext),
                child: const Text('Cancel'),
              ),
              // FIX: confirmation dialog "Update" button — teal background so white text is readable
              ElevatedButton.icon(
                style: ElevatedButton.styleFrom(
                  backgroundColor: _teal,
                  foregroundColor: Colors.white,
                  disabledBackgroundColor: _teal.withValues(alpha: 0.6),
                  disabledForegroundColor: Colors.white70,
                ),
                icon: const Icon(Icons.save, color: Colors.white),
                label: const Text('Update'),
                onPressed: () async {
                  Navigator.pop(dialogContext);
                  await _savePrescriptionUpdate(
                    serial:        serial,
                    branchId:      branchId,
                    patientCnic:   patientCnic,
                    queueType:     queueType,
                    originalPresc: prescData,
                    complaint:     complaintCtrl.text.trim(),
                    diagnosis:     diagnosisCtrl.text.trim(),
                    medicines:     currentMeds,
                    labTests:      currentLabs,
                    daysOfMedicine: editDays,
                  );
                },
              ),
            ],
          );
        },
      ),
    );

    complaintCtrl.dispose();
    diagnosisCtrl.dispose();
    searchCtrl.dispose();
  }

  // ─── Save prescription update ──────────────────────────────────────────────
  Future<void> _savePrescriptionUpdate({
    required String serial,
    required String branchId,
    required String patientCnic,
    required String queueType,
    required Map<String, dynamic> originalPresc,
    required String complaint,
    required String diagnosis,
    required List<Map<String, dynamic>> medicines,
    required List<Map<String, dynamic>> labTests,
    required int daysOfMedicine,
  }) async {
    // --- Stock Check Validation at Save Time ---
    try {
      String? patientCamp = (originalPresc['dispensaryId'] ?? originalPresc['campId'] ?? originalPresc['dispensaryTag'])?.toString().trim();
      if (patientCamp == null || patientCamp.isEmpty || patientCamp == 'all') {
        final s = serial.toUpperCase();
        if (s.contains('-SADD-') || s.contains('-SADDAR-') || s.contains('-SAD-') || s.contains('-KAP-')) patientCamp = 'saddar';
        else if (s.contains('-HAJI-') || s.contains('-HC-')) patientCamp = 'haji_camp';
      }
      var allStock = LocalStorageService.getAllLocalStockItems(branchId: branchId, dispensaryId: patientCamp);
      if (allStock.isEmpty && patientCamp != null && patientCamp.isNotEmpty) {
        allStock = LocalStorageService.getAllLocalStockItems(branchId: branchId, filterByCamp: false);
      }
      final prescBox   = await LocalStorageService.ensureBoxOpen(LocalStorageService.prescriptionsBox);
      final entriesBox = await LocalStorageService.ensureBoxOpen(LocalStorageService.entriesBox);
      final mySerial   = serial.trim().toLowerCase();

      // 1. Build reserved quantities from other pending patients
      final Map<String, int> reserved = {};
      for (final key in prescBox.keys) {
        final raw = prescBox.get(key);
        if (raw is! Map) continue;
        final presc = Map<String, dynamic>.from(raw);

        final prescSerial = (presc['serial'] ?? presc['id'] ?? '')
            .toString().trim().toLowerCase();
        if (prescSerial == mySerial) continue;

        final entryKey = '$branchId-$prescSerial';
        final entry    = entriesBox.get(entryKey);
        if (entry is Map) {
          final dispenseStatus =
              (entry['dispenseStatus'] ?? '').toString().toLowerCase();
          if (dispenseStatus == 'dispensed') continue;
        }

        final dispenseStatusOnPresc =
            (presc['dispenseStatus'] ?? '').toString().toLowerCase();
        if (dispenseStatusOnPresc == 'dispensed') continue;

        final meds = presc['prescriptions'];
        if (meds is! List) continue;

        for (final med in meds) {
          if (med is! Map) continue;
          final inventoryId = (med['inventoryId'] ?? '').toString().trim();
          if (inventoryId.isEmpty) continue;

          final medQty = med['quantity'];
          final qty = (medQty is num ? medQty.toInt() : int.tryParse(medQty?.toString() ?? '') ?? 0);
          final days = (presc['daysOfMedicine'] as int?) ?? 1;
          final type = (med['type'] ?? '').toString().toLowerCase();
          final isInj = type.contains('injection') || type.contains('inj') ||
              type.contains('drip') || type.contains('syringe') ||
              type.contains('nebulization');
          final effectiveQty = isInj ? qty : qty * days;

          reserved[inventoryId] = (reserved[inventoryId] ?? 0) + effectiveQty;
        }
      }

      // 2. Validate each medicine in the updated prescription
      for (final med in medicines) {
        final inventoryId = (med['inventoryId'] ?? '').toString().trim();
        if (inventoryId.isEmpty) continue;

        final inventoryMed = allStock.firstWhere(
          (m) => m['id']?.toString() == inventoryId,
          orElse: () => {},
        );
        if (inventoryMed.isEmpty) continue;

        final invQty = inventoryMed['quantity'];
        final totalStock = (invQty is num ? invQty.toInt() : int.tryParse(invQty?.toString() ?? '') ?? 0);
        final reservedByOthers = reserved[inventoryId] ?? 0;
        final available = totalStock - reservedByOthers;
        final availableClamped = available < 0 ? 0 : available;

        final medQty = med['quantity'];
        final perDayQty = (medQty is num ? medQty.toInt() : int.tryParse(medQty?.toString() ?? '') ?? 0);
        final isInj = _isInjectionOrDrip(med);
        final required = isInj ? perDayQty : perDayQty * daysOfMedicine;

        if (required > availableClamped) {
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(SnackBar(
              content: Text(
                '⚠️ "${med['name']}" stock insufficient! '
                'Need $required but only $availableClamped available after reservations.',
              ),
              backgroundColor: Colors.red,
              duration: const Duration(seconds: 4),
            ));
          }
          return;
        }
      }
    } catch (e) {
      debugPrint('[PrescEdit] Stock validation error: $e');
    }

    final now         = DateTime.now().toIso8601String();
    final pricePerDay = _baseDayPrice[queueType] ?? 0;
    final extraCharge = (daysOfMedicine - 1) * pricePerDay;

    final updatedPresc = <String, dynamic>{
      ...originalPresc,
      'serial':          serial,
      'branchId':        branchId,
      'queueType':       queueType,
      'condition':       complaint,
      'complaint':       complaint,
      'diagnosis':       diagnosis,
      'prescriptions':   medicines,
      'labResults':      labTests,
      'daysOfMedicine':  daysOfMedicine,
      'updatedAt':       now,
      'updatedBy':       RealtimeManager().role ?? 'Doctor',
    };

    // 1. Hive prescriptions box
    await LocalStorageService.saveLocalPrescription(updatedPresc);
    debugPrint('[PrescEdit] ✅ Saved to local prescriptions box: $serial');

    // 2. Hive entries box — also update top-level daysOfMedicine
    final entryKey = '$branchId-$serial';
    final entryBox  = await LocalStorageService.ensureBoxOpen(LocalStorageService.entriesBox);
    final existing  = entryBox.get(entryKey);
    if (existing != null) {
      final updated = Map<String, dynamic>.from(existing);
      updated['prescription']   = updatedPresc;
      updated['prescriptionId'] = serial;
      updated['status']         = 'completed';
      updated['completedAt']    = updatedPresc['completedAt'] ?? now;
      updated['daysOfMedicine'] = daysOfMedicine;
      await entryBox.put(entryKey, updated);
      debugPrint('[PrescEdit] ✅ Updated entry in Hive: $entryKey');
    }

    // 3. LAN broadcast
    RealtimeManager().sendMessage(RealtimeEvents.payload(
      type:     RealtimeEvents.savePrescription,
      branchId: branchId,
      data:     updatedPresc,
    ));
    debugPrint('[PrescEdit] ✅ Broadcasted save_prescription (days=$daysOfMedicine)');

    // 4. Firestore fire-and-forget
    if (_isOnline) {
      _updateFirestore(
        serial:         serial,
        branchId:       branchId,
        patientCnic:    patientCnic,
        queueType:      queueType,
        updatedPresc:   updatedPresc,
        daysOfMedicine: daysOfMedicine,
        now:            now,
      );
    }

    if (mounted) {
      final daysTxt   = daysOfMedicine > 1 ? ' ($daysOfMedicine days)' : '';
      final chargeTxt = extraCharge > 0 ? ' | Extra: PKR $extraCharge' : '';
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Row(children: [
          const Icon(Icons.check_circle, color: Colors.white),
          const SizedBox(width: 8),
          Text('Prescription updated$daysTxt$chargeTxt'),
        ]),
        backgroundColor: Colors.green,
        duration: const Duration(seconds: 3),
      ));
      setState(() {});
    }
  }

  // ─── Firestore write ───────────────────────────────────────────────────────
  Future<void> _updateFirestore({
    required String serial,
    required String branchId,
    required String patientCnic,
    required String queueType,
    required Map<String, dynamic> updatedPresc,
    required int daysOfMedicine,
    required String now,
  }) async {
    try {
      final ddmmyy    = CampSessionService.getDateKeyFromSerial(serial);
      final db        = FirebaseFirestore.instance;
      final cleanCnic = patientCnic.isNotEmpty ? patientCnic : 'unknown_$serial';

      // Path A: Clean up any legacy standalone prescription document
      try {
        await db
            .collection('branches').doc(branchId)
            .collection('prescriptions').doc(cleanCnic)
            .collection('prescriptions').doc(serial)
            .delete();
      } catch (_) {}

      // Path B: serials/{campDateDoc}/{queueType}/{serial}
      final campDocKey = CampSessionService.getCampDateDocId(
        branchId: branchId,
        dateKey: ddmmyy,
        serial: serial,
      );
      await db
          .collection('branches').doc(branchId)
          .collection('serials').doc(campDocKey)
          .collection(queueType)
          .doc(serial)
          .set({
        'prescription':   updatedPresc,
        'status':         'completed',
        'daysOfMedicine': daysOfMedicine,
        'updatedAt':      FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));
      debugPrint('[PrescEdit] ✅ Firestore serials/$campDocKey/$queueType/$serial updated '
          '(days=$daysOfMedicine)');
    } catch (e) {
      debugPrint('[PrescEdit] ❌ Firestore update failed (will retry on next sync): $e');
    }
  }

  // ─── Build ─────────────────────────────────────────────────────────────────
  @override
  Widget build(BuildContext context) {
    if (Hive.isBoxOpen(LocalStorageService.entriesBox)) {
      final box = Hive.box(LocalStorageService.entriesBox);
      if (box.isOpen) {
        return ValueListenableBuilder<Box>(
          valueListenable: box.listenable(),
          builder: (context, box, _) => _buildQueueContent(context),
        );
      }
    }
    return FutureBuilder<Box>(
      future: LocalStorageService.ensureBoxOpen(LocalStorageService.entriesBox),
      builder: (context, snapshot) {
        if (snapshot.hasData && snapshot.data != null && snapshot.data!.isOpen) {
          return ValueListenableBuilder<Box>(
            valueListenable: snapshot.data!.listenable(),
            builder: (context, box, _) => _buildQueueContent(context),
          );
        }
        return const Center(
          child: Padding(
            padding: EdgeInsets.all(24),
            child: CircularProgressIndicator(color: Color(0xFF00695C)),
          ),
        );
      },
    );
  }

  Widget _buildQueueContent(BuildContext context) {
        final allPatients = _getSortedQueue();

        WidgetsBinding.instance.addPostFrameCallback((_) {
          _tryAutoSelectSmallestWaiting();
        });

        bool isPatientDone(Map<String, dynamic> p) {
          final s = (p['status'] ?? '').toString().toLowerCase();
          final presc = p['prescription'];
          final hasPresc = presc is Map && (
            (presc['prescriptions'] is List && (presc['prescriptions'] as List).isNotEmpty) ||
            (presc['medicines'] is List && (presc['medicines'] as List).isNotEmpty) ||
            (presc['isVitalsOnly'] == true && presc['completedAt'] != null)
          );
          final isDisp = (p['dispenseStatus'] ?? '').toString().toLowerCase() == 'dispensed' || s == 'dispensed';
          return s == 'completed' || s == 'prescribed' || isDisp || hasPresc;
        }

        final waiting = allPatients.where((p) {
          final s = (p['status'] ?? '').toString().toLowerCase();
          return !isPatientDone(p) && s != 'skipped';
        }).toList();

        final skipped = allPatients.where((p) {
          final s = (p['status'] ?? '').toString().toLowerCase();
          return s == 'skipped';
        }).toList();

        final allCompleted = allPatients.where(isPatientDone).toList();
        // Strictly filter to patients prescribed by this doctor
        final myCompleted = allCompleted.where(_isPrescribedByMe).toList();
        final effectiveCompleted = myCompleted;

        final waitingCount   = waiting.length;
        final skippedCount   = skipped.length;
        final completedCount = effectiveCompleted.length;
        final total          = waiting.length + skipped.length + effectiveCompleted.length;

        List<Map<String, dynamic>> list;
        switch (_filter) {
          case 'waiting':   list = waiting;    break;
          case 'skipped':   list = skipped;    break;
          case 'completed': list = effectiveCompleted;  break;
          default:          list = [...waiting, ...skipped, ...effectiveCompleted];
        }

        final mergedExceptions = [
          ..._exceptionRequests.map((doc) {
                final raw = doc.data();
                final d = (raw is Map) ? Map<String, dynamic>.from(raw) : <String, dynamic>{};
                return {...d, 'id': doc.id};
              }),
          ..._localExceptionRequests,
        ];

        // deduplicate by ID and enforce pending status
        final uniqueExceptions = <String, Map<String, dynamic>>{};
        for (var e in mergedExceptions) {
          final id = e['id']?.toString() ?? '';
          if (id.isEmpty) continue;
          final status = (e['status'] ?? 'pending').toString().toLowerCase();
          if (status == 'pending') {
            uniqueExceptions[id] = e;
          }
        }
        final finalExceptions = uniqueExceptions.values.toList();

        final isDark = _isDark;

        return Column(children: [
          // ── Header ──────────────────────────────────────────────────────
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
            color: _teal,
            child: Row(children: [
              const Icon(Icons.people_alt, color: Colors.white, size: 26),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text("Today's Queue",
                        style: TextStyle(
                            color: Colors.white,
                            fontSize: 19,
                            fontWeight: FontWeight.bold)),
                    if (widget.doctorName != null && widget.doctorName!.isNotEmpty)
                      Text(
                        'Logged in as ${widget.doctorName!.startsWith("Dr") ? widget.doctorName : "Dr. ${widget.doctorName}"}',
                        style: const TextStyle(
                          color: Color(0xFFCCFBF1),
                          fontSize: 11,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                  ],
                ),
              ),
              IconButton(
                icon: const Icon(Icons.refresh, color: Colors.white, size: 24),
                tooltip: 'Refresh Queue',
                onPressed: () {
                  setState(() {});
                  WidgetsBinding.instance.addPostFrameCallback(
                      (_) => _tryAutoSelectSmallestWaiting());
                }),
            ]),
          ),

          // ── Session / Shift & Camp Filter Bar ───────────────────────────────
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            decoration: BoxDecoration(
              color: isDark ? const Color(0xFF0F172A) : const Color(0xFFF8FAFC),
              border: Border(bottom: BorderSide(color: isDark ? const Color(0xFF1E293B) : const Color(0xFFE2E8F0))),
            ),
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  _buildSessionChip('auto', '⚡ Current (${CampSessionService.getCurrentSession(null, widget.branchId).toUpperCase()})'),
                  if (_allowedSessions.contains('morning') || _allowedSessions.contains('all')) ...[
                    const SizedBox(width: 5),
                    _buildSessionChip('morning', '☀️ Morning'),
                  ],
                  if (_allowedSessions.contains('evening') || _allowedSessions.contains('all')) ...[
                    const SizedBox(width: 5),
                    _buildSessionChip('evening', '🌅 Evening'),
                  ],
                  if (_allowedSessions.contains('night') || _allowedSessions.contains('all')) ...[
                    const SizedBox(width: 5),
                    _buildSessionChip('night', '🌙 Night'),
                  ],
                  if (_hasMultiCamps && (_allowedCamps.contains('all') || _allowedCamps.length > 1)) ...[
                    const SizedBox(width: 10),
                    Container(height: 16, width: 1, color: isDark ? const Color(0xFF334155) : const Color(0xFFCBD5E1)),
                    const SizedBox(width: 10),
                    if (_allowedCamps.contains('all')) _buildCampChip('all', '🏥 All Camps'),
                    if (_allowedCamps.contains('all') || _allowedCamps.contains('saddar')) ...[
                      const SizedBox(width: 5),
                      _buildCampChip('saddar', 'Saddar'),
                    ],
                    if (_allowedCamps.contains('all') || _allowedCamps.contains('haji_camp') || _allowedCamps.contains('haji')) ...[
                      const SizedBox(width: 5),
                      _buildCampChip('haji_camp', 'Haji Camp'),
                    ],
                  ],
                ],
              ),
            ),
          ),

          // ── Filter tabs ──────────────────────────────────────────────────
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                GestureDetector(
                  onTap: () => setState(() => _filter = 'waiting'),
                  child: _buildFilterTab(
                      'Waiting', waitingCount, _amber, _filter == 'waiting')),
                GestureDetector(
                  onTap: () => setState(() => _filter = 'skipped'),
                  child: _buildFilterTab(
                      'Skipped', skippedCount, Colors.deepOrange, _filter == 'skipped')),
                GestureDetector(
                  onTap: () => setState(() => _filter = 'completed'),
                  child: _buildFilterTab('Done', completedCount,
                      Colors.green[700]!, _filter == 'completed')),
                GestureDetector(
                  onTap: () => setState(() => _filter = 'all'),
                  child: _buildFilterTab(
                      'Total', total, _purple, _filter == 'all')),
              ],
            ),
          ),

          // ── Exception requests ───────────────────────────────────────────
          if (finalExceptions.isNotEmpty) ...[
            Container(
              width: double.infinity,
              margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              decoration: BoxDecoration(
                color: Colors.orange.shade50,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: Colors.orange.shade300),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(children: [
                    Icon(Icons.emergency_share_outlined, color: Colors.orange.shade900, size: 18),
                    const SizedBox(width: 8),
                    Text(
                      'EXCEPTION REQUESTS (${finalExceptions.length})',
                      style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.bold,
                          color: Colors.orange.shade900,
                          letterSpacing: 1.1),
                    ),
                  ]),
                  const SizedBox(height: 10),
                  ...finalExceptions.map((d) {
                    return Card(
                      elevation: 0,
                      color: Colors.orange.shade100,
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                      child: ListTile(
                        dense: true,
                        leading: CircleAvatar(
                          radius: 14,
                          backgroundColor: Colors.orange.shade800,
                          child: const Icon(Icons.person, color: Colors.white, size: 16),
                        ),
                        title: Text(d['patientName'] ?? 'Unknown',
                            style: TextStyle(fontWeight: FontWeight.bold, color: Colors.orange.shade900)),
                        subtitle: Text('Restricted: ${d['restriction']?['remainingDays'] ?? '?'} days left'),
                        trailing: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            IconButton(
                              icon: const Icon(Icons.check_circle, color: Colors.green, size: 24),
                              onPressed: () => _approveException(d),
                            ),
                            IconButton(
                              icon: const Icon(Icons.cancel, color: Colors.red, size: 24),
                              onPressed: () => _rejectException(d),
                            ),
                          ],
                        ),
                      ),
                    );
                  }),
                ],
              ),
            ),
          ],



          // ── Patient list ─────────────────────────────────────────────────
          Expanded(
            child: list.isEmpty
                ? const Center(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(Icons.people_outline, size: 64, color: Colors.grey),
                        SizedBox(height: 12),
                        Text(
                          "No patients in queue",
                          style: TextStyle(fontSize: 16, color: Colors.grey),
                        ),
                      ],
                    ),
                  )
                : ListView.builder(
                    padding: const EdgeInsets.fromLTRB(12, 4, 12, 12),
                    itemCount: list.length,
                    itemBuilder: (context, index) {
                final patient = list[index];
                final serial  = patient['serial']?.toString() ??
                    patient['id']?.toString() ?? 'N/A';
                final rawName = (patient['patientName'] ?? patient['name'] ?? patient['fullName'])?.toString().trim();
                String name = (rawName != null && rawName.isNotEmpty && rawName.toLowerCase() != 'null' && rawName.toLowerCase() != 'unknown' && rawName.toLowerCase() != 'unknown patient')
                    ? rawName
                    : '';
                if (name.isEmpty) {
                  final presc = patient['prescription'] is Map
                      ? patient['prescription'] as Map
                      : LocalStorageService.getLocalPrescription(
                          serial,
                          branchId: widget.branchId,
                          cnic: patient['patientCnic'] ?? patient['cnic'],
                          patientId: patient['patientId'] ?? patient['id'],
                          patientName: rawName,
                        );
                  final pName = (presc?['patientName'] ?? presc?['name'] ?? presc?['fullName'])?.toString().trim();
                  if (pName != null && pName.isNotEmpty && pName.toLowerCase() != 'unknown' && pName.toLowerCase() != 'unknown patient') {
                    name = pName;
                  }
                }
                if (name.isEmpty) {
                  final pId = (patient['patientId'] ?? patient['id'] ?? '').toString().trim();
                  final pCnic = (patient['patientCnic'] ?? patient['cnic'] ?? patient['guardianCnic'] ?? '').toString().trim();
                  if (pId.isNotEmpty) {
                    final lp = LocalStorageService.getLocalPatient(pId);
                    final lpName = (lp?['name'] ?? lp?['patientName'] ?? lp?['fullName'])?.toString().trim();
                    if (lpName != null && lpName.isNotEmpty && lpName.toLowerCase() != 'unknown' && lpName.toLowerCase() != 'unknown patient') {
                      name = lpName;
                    }
                  }
                  if (name.isEmpty && pCnic.isNotEmpty) {
                    final lp = LocalStorageService.getLocalPatientByCnic(pCnic);
                    final lpName = (lp?['name'] ?? lp?['patientName'] ?? lp?['fullName'])?.toString().trim();
                    if (lpName != null && lpName.isNotEmpty && lpName.toLowerCase() != 'unknown' && lpName.toLowerCase() != 'unknown patient') {
                      name = lpName;
                    }
                  }
                }
                if (name.isEmpty) {
                  name = 'Unknown Patient';
                }

                final isSelected =
                    widget.selectedPatient?['serial']?.toString() == serial ||
                    widget.selectedPatient?['id']?.toString() == serial;

                final status    = (patient['status'] ?? '').toString().toLowerCase();
                String dispenseStatus = (patient['dispenseStatus'] ?? '').toString().toLowerCase();
                if (dispenseStatus != 'dispensed' && status != 'dispensed') {
                  if (Hive.isBoxOpen(LocalStorageService.dispensaryBox)) {
                    final dBox = Hive.box(LocalStorageService.dispensaryBox);
                    final dKey = (patient['dateKey'] ?? _todayKey).toString();
                    final rec = dBox.get('${widget.branchId}_${dKey}_$serial') ??
                                dBox.get('${widget.branchId}-$serial') ??
                                dBox.get(serial);
                    if (rec is Map && ((rec['dispenseStatus'] ?? rec['status']) == 'dispensed' || rec['status'] == 'completed')) {
                      dispenseStatus = 'dispensed';
                    }
                  }
                }
                final presc = patient['prescription'];
                final hasRealPresc = presc is Map && (
                  (presc['prescriptions'] is List && (presc['prescriptions'] as List).isNotEmpty) ||
                  (presc['medicines'] is List && (presc['medicines'] as List).isNotEmpty) ||
                  (presc['isVitalsOnly'] == true && presc['completedAt'] != null)
                );
                final isDispensed = dispenseStatus == 'dispensed' || status == 'dispensed';
                final isDone = status == 'completed' || status == 'prescribed' || isDispensed || hasRealPresc;
                final isSkipped = status == 'skipped';
                final isWaiting = !isDone && !isSkipped;
                final isVitalsOnly = patient['isVitalsOnly'] == true || patient['vitalsOnly'] == true;

                // Edit button must only appear for status == 'completed' (not yet dispensed),
                // and MUST hide immediately once status becomes 'dispensed'.
                final isCompleted = isDone && !isDispensed;

                final smallestWaitingSerial = waiting.isNotEmpty
                    ? (waiting.first['serial']?.toString() ??
                        waiting.first['id']?.toString() ?? '')
                    : '';
                final isSmallestWaiting =
                    isWaiting && serial == smallestWaitingSerial;
                final isSelectable = (isSmallestWaiting || isSkipped) && !widget.isSaving;
                final hasPrescription = hasRealPresc;

                // Days badge for prescriptions with > 1 day
                final prescDays = (() {
                  final d = patient['daysOfMedicine'];
                  if (d is int && d > 1) return d;
                  final presc = patient['prescription'];
                  if (presc is Map) {
                    final pd = presc['daysOfMedicine'];
                    if (pd is int && pd > 1) return pd;
                  }
                  return 1;
                })();

                final Color dotColor = isWaiting
                    ? _amber
                    : (isSkipped ? Colors.orange.shade800 : Colors.green[700]!);

                final Widget dot = Container(
                    width: 10,
                    height: 10,
                    decoration:
                        BoxDecoration(color: dotColor, shape: BoxShape.circle));

                final isDark = _isDark;
                return AnimatedContainer(
                  duration: const Duration(milliseconds: 250),
                  margin: const EdgeInsets.symmetric(vertical: 4),
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: isSelected
                        ? (isDark ? const Color(0xFF1E3A3A) : const Color(0xFFE8F5E9))
                        : (isDark ? const Color(0xFF1E293B) : Colors.white),
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(
                        color: isSelected
                            ? (isDark ? const Color(0xFF2DD4BF) : _teal)
                            : (isDark ? const Color(0xFF334155) : dotColor.withValues(alpha: 0.4)),
                        width: isSelected ? 2.0 : 1.2),
                    boxShadow: [
                      BoxShadow(
                          color: Colors.black12.withValues(alpha: 0.08),
                          blurRadius: 3,
                          offset: const Offset(0, 1))
                    ],
                  ),
                  child: InkWell(
                    onTap: isSelectable
                        ? () => widget.onPatientSelected(
                            {...patient, 'serial': serial, 'id': serial})
                        : null,
                    child: Row(children: [
                      Icon(
                          isWaiting
                              ? Icons.person
                              : (isSkipped ? Icons.pause_circle_filled : Icons.check_circle),
                          color: dotColor,
                          size: 26),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                Expanded(
                                  child: Text(name,
                                      style: TextStyle(
                                          fontWeight: FontWeight.w600,
                                          fontSize: 15,
                                          color: isDark
                                              ? Colors.white
                                              : ((!isWaiting && !isSkipped)
                                                  ? Colors.grey.shade700
                                                  : const Color(0xFF1B2631)))),
                                ),
                              ],
                            ),
                            const SizedBox(height: 3),
                            // Row 1: Staff, Camp, and Serial Number
                            Row(
                              children: [
                                Builder(builder: (_) {
                                  final staffInfo = StaffPatientLinkService.getStaffInfoForPatient(
                                    cnic: patient['cnic'] ?? patient['patientCnic'] ?? patient['guardianCnic'],
                                    name: name,
                                  );
                                  if (staffInfo != null) {
                                    return Padding(
                                      padding: const EdgeInsets.only(right: 4),
                                      child: StaffPatientLinkService.buildStaffBadge(staffInfo, isDark: isDark),
                                    );
                                  }
                                  return const SizedBox.shrink();
                                }),
                                Builder(builder: (_) {
                                  if (!_hasMultiCamps) return const SizedBox.shrink();
                                  final ser = serial.toUpperCase();
                                  final dispId = (patient['dispensaryId'] ?? patient['campId'])?.toString();
                                  final isHaji = ser.contains('-HAJI-') || ser.contains('-HC-') || (dispId ?? '').contains('haji');
                                  return Container(
                                    margin: const EdgeInsets.only(right: 6),
                                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                    decoration: BoxDecoration(
                                      color: isHaji ? const Color(0xFF6366F1) : const Color(0xFF0D9488),
                                      borderRadius: BorderRadius.circular(6),
                                    ),
                                    child: Row(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        const Icon(Icons.location_on_rounded, size: 10, color: Colors.white),
                                        const SizedBox(width: 2),
                                        Text(
                                          isHaji ? 'Haji Camp' : 'Saddar',
                                          style: const TextStyle(color: Colors.white, fontSize: 9.5, fontWeight: FontWeight.bold),
                                        ),
                                      ],
                                    ),
                                  );
                                }),
                                Text('Serial: $serial',
                                    style: TextStyle(
                                        color: isSelected
                                            ? _teal
                                            : (!isWaiting && !isSkipped
                                                ? (isDark ? const Color(0xFF64748B) : Colors.grey)
                                                : (isDark ? const Color(0xFF94A3B8) : Colors.black54)),
                                        fontSize: 12)),
                              ],
                            ),
                            // Row 2: Status & Doctor Pills (Always below serial number)
                            Padding(
                              padding: const EdgeInsets.only(top: 4),
                              child: Wrap(
                                crossAxisAlignment: WrapCrossAlignment.center,
                                spacing: 6,
                                runSpacing: 3,
                                children: [
                                  if (isVitalsOnly)
                                    Container(
                                      padding: const EdgeInsets.symmetric(
                                          horizontal: 6, vertical: 1.5),
                                      decoration: BoxDecoration(
                                        color: Colors.purple.shade700,
                                        borderRadius: BorderRadius.circular(6),
                                      ),
                                      child: const Text('🩺 VITALS ONLY',
                                          style: TextStyle(
                                              color: Colors.white,
                                              fontSize: 9,
                                              fontWeight: FontWeight.bold)),
                                    ),
                                  if (isSkipped)
                                    Container(
                                      padding: const EdgeInsets.symmetric(
                                          horizontal: 6, vertical: 1.5),
                                      decoration: BoxDecoration(
                                        color: Colors.orange.shade800,
                                        borderRadius: BorderRadius.circular(6),
                                      ),
                                      child: const Text('SKIPPED',
                                          style: TextStyle(
                                              color: Colors.white,
                                              fontSize: 9,
                                              fontWeight: FontWeight.bold)),
                                    ),
                                  // ×2 / ×3 days badge
                                  if (prescDays > 1)
                                    Container(
                                      padding: const EdgeInsets.symmetric(
                                          horizontal: 5, vertical: 1.5),
                                      decoration: BoxDecoration(
                                        color: Colors.deepOrange,
                                        borderRadius: BorderRadius.circular(6),
                                      ),
                                      child: Text('×$prescDays',
                                          style: const TextStyle(
                                              color: Colors.white,
                                              fontSize: 9,
                                              fontWeight: FontWeight.bold)),
                                    ),
                                  // Doctor attribution badge
                                  Builder(builder: (_) {
                                    final pMap = (presc is Map) ? Map<String, dynamic>.from(presc) : null;
                                    final prescDoc = (pMap?['doctorName'] ?? pMap?['prescribedBy'] ?? patient['doctorName'] ?? patient['prescribedBy'] ?? patient['examinedBy'])?.toString().trim();
                                    final isMine = _isPrescribedByMe(patient, pMap);
                                    
                                    if (isDone && prescDoc != null && prescDoc.isNotEmpty && prescDoc.toLowerCase() != 'unknown') {
                                      final cleanDoc = prescDoc.startsWith('Dr') ? prescDoc : 'Dr. $prescDoc';
                                      return Container(
                                        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1.5),
                                        decoration: BoxDecoration(
                                          color: isMine ? (isDark ? const Color(0xFF064E3B) : const Color(0xFFD1FAE5)) : (isDark ? const Color(0xFF334155) : const Color(0xFFF1F5F9)),
                                          borderRadius: BorderRadius.circular(6),
                                          border: Border.all(color: isMine ? (isDark ? const Color(0xFF059669) : const Color(0xFF34D399)) : (isDark ? const Color(0xFF475569) : const Color(0xFFCBD5E1))),
                                        ),
                                        child: Row(
                                          mainAxisSize: MainAxisSize.min,
                                          children: [
                                            Icon(Icons.medical_services_rounded, size: 10, color: isMine ? (isDark ? const Color(0xFF34D399) : const Color(0xFF065F46)) : (isDark ? const Color(0xFF94A3B8) : const Color(0xFF475569))),
                                            const SizedBox(width: 3),
                                            Text(
                                              isMine ? 'Prescribed by You' : cleanDoc,
                                              style: TextStyle(
                                                color: isMine ? (isDark ? const Color(0xFF34D399) : const Color(0xFF065F46)) : (isDark ? const Color(0xFF94A3B8) : const Color(0xFF475569)),
                                                fontSize: 9.5,
                                                fontWeight: FontWeight.bold,
                                              ),
                                            ),
                                          ],
                                        ),
                                      );
                                    }
                                    final actDoc = patient['activeDoctor']?.toString().trim();
                                    if (isWaiting && actDoc != null && actDoc.isNotEmpty) {
                                      final isWithMe = _isDoctorMatch(actDoc, widget.doctorName);
                                      return Container(
                                        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1.5),
                                        decoration: BoxDecoration(
                                          color: isWithMe ? (isDark ? const Color(0xFF1E3A5F) : const Color(0xFFDBEAFE)) : (isDark ? const Color(0xFF451A03) : const Color(0xFFFEF3C7)),
                                          borderRadius: BorderRadius.circular(6),
                                          border: Border.all(color: isWithMe ? const Color(0xFF3B82F6) : const Color(0xFFF59E0B)),
                                        ),
                                        child: Row(
                                          mainAxisSize: MainAxisSize.min,
                                          children: [
                                            Icon(Icons.person_pin_circle_rounded, size: 10, color: isWithMe ? const Color(0xFF2563EB) : const Color(0xFFD97706)),
                                            const SizedBox(width: 3),
                                            Text(
                                              isWithMe ? 'In Consultation with You' : 'With Dr. $actDoc',
                                              style: TextStyle(
                                                color: isWithMe ? (isDark ? const Color(0xFF93C5FD) : const Color(0xFF1E40AF)) : (isDark ? const Color(0xFFFDE68A) : const Color(0xFF92400E)),
                                                fontSize: 9.5,
                                                fontWeight: FontWeight.bold,
                                              ),
                                            ),
                                          ],
                                        ),
                                      );
                                    }
                                    return const SizedBox.shrink();
                                  }),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),
                      if (isDispensed)
                        Container(
                          margin: const EdgeInsets.only(right: 6),
                          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                          decoration: BoxDecoration(
                            color: isDark ? const Color(0xFF14532D) : Colors.green.shade50,
                            borderRadius: BorderRadius.circular(6),
                            border: Border.all(color: isDark ? const Color(0xFF16A34A) : Colors.green.shade400),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(Icons.check_circle_rounded, size: 10, color: isDark ? const Color(0xFF86EFAC) : Colors.green.shade800),
                              const SizedBox(width: 3),
                              Text(
                                'Dispensed',
                                style: TextStyle(
                                  color: isDark ? const Color(0xFF86EFAC) : Colors.green.shade800,
                                  fontSize: 9.5,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                            ],
                          ),
                        ),
                      if (isCompleted)
                        IconButton(
                          icon: const Icon(Icons.edit,
                              color: Colors.orange, size: 20),
                          tooltip: 'Edit Prescription',
                          onPressed: () => _showPrescriptionDialog(patient),
                        ),
                      dot,
                    ]),
                  ),
                );
              },
            ),
          ),
        ]);
  }

  Widget _buildFilterTab(
      String label, int count, Color color, bool isActive) {
    final isDark = _isDark;
    final isAmberLike = color == _amber || color == Colors.orange || color == Colors.deepOrange || color == Colors.amber;
    final Color solidBg = color;
    
    return AnimatedContainer(
      duration: const Duration(milliseconds: 200),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      decoration: BoxDecoration(
        color: isActive ? solidBg : (isDark ? const Color(0xFF1E293B) : color.withValues(alpha: 0.12)),
        borderRadius: BorderRadius.circular(30),
        border: Border.all(
          color: isActive ? solidBg : (isDark ? const Color(0xFF334155) : color.withValues(alpha: 0.4)),
          width: isActive ? 2.0 : 1.0,
        ),
        boxShadow: isActive
            ? [BoxShadow(
                color: color.withValues(alpha: 0.35),
                blurRadius: 8,
                offset: const Offset(0, 3))]
            : null,
      ),
      child: Column(children: [
        Text(label,
            style: TextStyle(
                color: isActive
                    ? (isAmberLike && !isDark ? const Color(0xFF1B2631) : Colors.white)
                    : (isDark ? const Color(0xFFCBD5E1) : (isAmberLike ? const Color(0xFF9A3412) : color)),
                fontWeight: FontWeight.bold,
                fontSize: 12)),
        const SizedBox(height: 2),
        Text('$count',
            style: TextStyle(
                color: isActive
                    ? (isAmberLike && !isDark ? const Color(0xFF1B2631) : Colors.white)
                    : (isDark ? Colors.white : (isAmberLike ? const Color(0xFF9A3412) : color)),
                fontSize: 18,
                fontWeight: FontWeight.bold)),
      ]),
    );
  }

  bool get _isDark {
    try {
      if (Hive.isBoxOpen('app_settings')) {
        final dark = Hive.box('app_settings').get('is_dark_mode');
        if (dark != null) return dark == true;
      }
    } catch (_) {}
    return Theme.of(context).brightness == Brightness.dark;
  }

  Widget _buildSessionChip(String value, String label) {
    final isAllowed  = _isSessionAllowed(value);
    final isSelected = (_selectedSession == value || _selectedSessionFilter == value) && (value == 'all' || isAllowed);
    final isDark = _isDark;
    return Opacity(
      opacity: (value == 'all' || isAllowed) ? 1.0 : 0.4,
      child: Tooltip(
        message: (value == 'all' || isAllowed) ? label : 'Restricted to assigned work shifts',
        child: InkWell(
          onTap: (value == 'all' || isAllowed)
              ? () => setState(() {
                    _selectedSession = value;
                    _selectedSessionFilter = value;
                  })
              : null,
          borderRadius: BorderRadius.circular(12),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            decoration: BoxDecoration(
              color: isSelected ? _teal : (isDark ? const Color(0xFF1E293B) : (isAllowed ? Colors.white : Colors.grey.shade200)),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: isSelected ? _teal : (isDark ? const Color(0xFF334155) : (isAllowed ? Colors.teal.shade200 : Colors.grey.shade400))),
            ),
            child: Text(
              label,
              style: TextStyle(
                fontSize: 10.5,
                fontWeight: isSelected ? FontWeight.bold : FontWeight.w500,
                color: isSelected ? Colors.white : (isDark ? const Color(0xFFCBD5E1) : (isAllowed ? Colors.teal.shade900 : Colors.grey.shade600)),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildCampChip(String value, String label) {
    final isAllowed  = _isCampAllowed(value);
    final normVal    = value.toLowerCase();
    final normSel    = _selectedCampFilter.toLowerCase();
    final isSelected = isAllowed && (normSel == normVal ||
        (normVal == 'haji_camp' && normSel == 'haji') ||
        (normVal == 'haji' && normSel == 'haji_camp') ||
        (normVal == 'saddar' && (normSel == 'kapayya' || normSel == 'kapaya' || normSel == 'kap')));
    final isDark = _isDark;
    return Opacity(
      opacity: isAllowed ? 1.0 : 0.35,
      child: Tooltip(
        message: isAllowed ? label : 'Not scheduled for this camp during active shift',
        child: InkWell(
          onTap: isAllowed ? () => setState(() => _selectedCampFilter = value) : null,
          borderRadius: BorderRadius.circular(12),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            decoration: BoxDecoration(
              color: isSelected ? _teal : (isDark ? const Color(0xFF1E293B) : (isAllowed ? Colors.white : Colors.grey.shade200)),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: isSelected ? _teal : (isDark ? const Color(0xFF334155) : (isAllowed ? Colors.teal.shade200 : Colors.grey.shade400))),
            ),
            child: Text(
              label,
              style: TextStyle(
                fontSize: 10.5,
                fontWeight: isSelected ? FontWeight.bold : FontWeight.w500,
                color: isSelected ? Colors.white : (isDark ? const Color(0xFFCBD5E1) : (isAllowed ? Colors.teal.shade900 : Colors.grey.shade600)),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
