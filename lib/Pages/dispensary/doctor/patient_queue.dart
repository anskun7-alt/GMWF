// lib/pages/dispensary/doctor/patient_queue.dart

import 'package:gmwf/services/cloud/cloud_db.dart';
import 'package:gmwf/services/cloud/lan_firestore_gate.dart';
import 'package:gmwf/utils/debounced_box_listenable.dart';
import 'package:gmwf_ui/gmwf_ui.dart' show GEmptyIllustration, GEmptyIllustrationKind;
import 'package:gmwf/pages/dispensary/widgets/tab_visibility.dart';
import 'package:gmwf/utils/token_order.dart';
import 'package:gmwf/utils/branch_labels.dart';
import 'package:gmwf/design/tokens/soft_palette.dart';
import 'package:gmwf/design/tokens/comfort_colors.dart';
import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/material.dart';
import 'package:gmwf/utils/formatters.dart';
import 'package:gmwf/design/components/app_toast.dart';
import 'package:flutter/services.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:intl/intl.dart';

import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:gmwf/services/local_storage_service.dart';
import 'package:gmwf/services/camp_session_service.dart';
import 'package:gmwf/services/stock/stock_pool.dart';
import 'package:gmwf/services/stock/stock_reader.dart';
import 'package:gmwf/services/serials_service.dart';
import 'package:gmwf/realtime/realtime_manager.dart';
import 'package:gmwf/realtime/realtime_events.dart';
import 'package:gmwf/realtime/connection_manager.dart';
import 'package:gmwf/services/staff_patient_link_service.dart';
import 'package:gmwf/pages/dispensary/doctor/patient_info.dart';
import 'package:gmwf/Pages/dispensary/dispensar/patient_form_helper.dart';

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
  Color get _teal => context.comfort.brand;
  static const Color _amber  = SoftPalette.amber300;
  static const Color _purple = SoftPalette.purple600;

  String _filter = 'all';
  String _selectedSessionFilter = 'all';
  String _selectedCampFilter = 'all';
  
  // ─── HANG FIX: Debounce + Cache ────────────────────────────────────
  Timer? _debounceRebuildTimer;  // Batch multiple events into single rebuild
  Timer? _queueCatchUpTimer;     // Periodic auto-catchup to prevent token delays
  List<Map<String, dynamic>>? _cachedQueue;  // Cache sorted queue
  DateTime? _queueCacheTime;  // Track cache freshness
  static const _queueCacheTTL = Duration(milliseconds: 500);  // Cache for 500ms
  bool _isSyncingQueue = false;
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
  String _selectedSession = 'all'; // 'all', 'auto' (Current Active Shift), 'morning', 'evening', 'night'
  String _doctorScopeFilter = 'all'; // 'my' vs 'all' for Total list
  final TextEditingController _queueSearchController = TextEditingController();
  String _queueSearchQuery = '';

  bool _isDoctorMatch(String? docA, String? docB) {
    if (docA == null || docB == null) return false;
    final prefix = RegExp(r'^(dr\.?|doctor)\s*', caseSensitive: false);
    final cleanA = docA.trim().toLowerCase().replaceFirst(prefix, '').trim();
    final cleanB = docB.trim().toLowerCase().replaceFirst(prefix, '').trim();
    if (cleanA.isEmpty || cleanB.isEmpty) {
      return docA.trim().toLowerCase() == docB.trim().toLowerCase();
    }
    return cleanA == cleanB || cleanA.contains(cleanB) || cleanB.contains(cleanA);
  }

  bool _isPrescribedByMe(Map<String, dynamic> p, [Map<String, dynamic>? optionalPresc]) {
    final myDocId = (widget.doctorId ?? '').trim().toLowerCase();
    final myDocName = (widget.doctorName ?? '').trim();

    // If no doctor context was passed, default to allow
    if (myDocId.isEmpty && myDocName.isEmpty) return true;

    final presc = optionalPresc ?? ((p['prescription'] is Map)
        ? Map<String, dynamic>.from(p['prescription'] as Map)
        : (LocalStorageService.getLocalPrescription(
            (p['serial'] ?? p['id'] ?? '').toString(),
            branchId: widget.branchId,
          ) ?? {}));

    final pDocId = (presc['doctorId'] ?? presc['prescribedById'] ?? p['doctorId'] ?? p['prescribedById'] ?? '').toString().trim().toLowerCase();
    // [FIX] Never check performedBy here! performedBy gets overwritten by the dispenser on dispense.
    // Checking performedBy causes dispensed tokens to match the dispenser rather than the doctor, hiding them from Doctor queue.
    final pDocName = (presc['doctorName'] ?? presc['prescribedBy'] ?? presc['prescribedByName'] ?? presc['examinedBy'] ?? p['doctorName'] ?? p['prescribedBy'] ?? p['prescribedByName'] ?? p['examinedBy'] ?? '').toString().trim();

    if (myDocId.isNotEmpty && pDocId.isNotEmpty) {
      if (pDocId == myDocId || pDocId.contains(myDocId) || myDocId.contains(pDocId)) return true;
    }
    if (myDocName.isNotEmpty && pDocName.isNotEmpty) {
      if (_isDoctorMatch(pDocName, myDocName)) return true;
    }
    // If neither doctorId nor doctorName was recorded on this patient/prescription, allow visibility so it does not vanish
    if (pDocId.isEmpty && pDocName.isEmpty) {
      return true;
    }
    return false;
  }

  // A token shows only on the date in its serial. There is no "recent" carry-over: a token
  // replayed from a desk's outbox the next day (e.g. after a server crash) used to land in the
  // waiting list next to today's tokens, sorted by number, and got prescribed on by mistake.
  // Exception: a session running past midnight — a token issued in the last hours of
  // yesterday stays until 06:00 (it vanished at 00:00 while the patient was still waiting).
  bool _isEffectivelyToday(Map<String, dynamic> e, String currentTodayKey, String todayIso) =>
      CampSessionService.isTokenOnDate(e, currentTodayKey, widget.branchId) ||
      CampSessionService.isLateNightCarryOver(e, widget.branchId);

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
                : 'all'))
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

        // Active patients from today (waiting, in consultation, or skipped):
        // ALWAYS keep in queue if viewing current real shift or all today
        final status = (entry['status'] ?? '').toString().toLowerCase();
        final isWaitingOrActive = status == 'waiting' || status == 'in_consultation' || status == 'in consultation' || status == 'skipped';
        if (isWaitingOrActive && (targetShift == currentRealShift || targetShift == 'all')) {
          return true;
        }

        if (resolved.isNotEmpty && resolved != 'unknown' && resolved != 'all' && resolved != 'auto') {
          return resolved == targetShift;
        }

        if (isWaitingOrActive) {
          return targetShift == currentRealShift;
        }

        // For completed tokens with unknown session, do not leak into targetShift
        return false;
      }).toList();
    }

    final waiting   = <Map<String, dynamic>>[];
    final skipped   = <Map<String, dynamic>>[];
    final editable  = <Map<String, dynamic>>[];
    final dispensed = <Map<String, dynamic>>[];

    for (final e in all) {
      final presc = e['prescription'];
      final hasRealPresc = presc is Map && (
        (presc['prescriptions'] is List && (presc['prescriptions'] as List).isNotEmpty) ||
        (presc['medicines'] is List && (presc['medicines'] as List).isNotEmpty) ||
        (presc['isVitalsOnly'] == true && presc['completedAt'] != null)
      );
      final isDispensed = _isPatientDispensed(e);
      var status = (e['status'] ?? '').toString().toLowerCase();

      // Self-Healing Guard: If patient is already dispensed, mark as completed in memory
      if (isDispensed) {
        if (status != 'completed') {
          e['status'] = 'completed';
          status = 'completed';
        }
        e['dispenseStatus'] = 'dispensed';
      }

      final isCompletedOrPrescribed = status == 'completed' || status == 'prescribed' || isDispensed || hasRealPresc;
      final isSkipped = status == 'skipped';

      if (isDispensed) {
        dispensed.add(e);
      } else if (isCompletedOrPrescribed) {
        editable.add(e);
      } else if (isSkipped) {
        skipped.add(e);
      } else {
        waiting.add(e);
      }
    }

    // Fair order: waiting at top, skipped, editable completed in the middle by token
    // index, and dispensed separated at the bottom by token index.
    return [
      ...TokenOrder.sortFairly(waiting),
      ...TokenOrder.sortFairly(skipped),
      ...TokenOrder.sortFairly(editable),
      ...TokenOrder.sortFairly(dispensed),
    ];
  }

  List<Map<String, dynamic>> _getPreviousDaysCarryoverQueue() {
    return [];
  }

  Future<void> _closeOutDay(String dateKey) async {
    final count = await LocalStorageService.expireUnservedTokensForDate(widget.branchId, dateKey);
    if (mounted) {
      AppToast.showSnackBar(context, SnackBar(
        content: Text('✅ Closed out day $dateKey. Expired $count unserved token(s).'),
        backgroundColor: SoftPalette.teal500,
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

  bool get _isKarachi => BranchLabels.isKarachiBranch(widget.branchId);

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
    ConnectionManager().addReconnectListener(_onLanReconnected);

    _realtimeSub = RealtimeManager().messageStream.listen((event) {
      final type = event['event_type'] as String?;
      final rawData = event['data'];
      final data = (rawData is Map) ? Map<String, dynamic>.from(rawData) : Map<String, dynamic>.from(event);
      if (!mounted || type == null) return;

      final msgBranch = (data['branchId'] ?? event['branchId'])?.toString().toLowerCase().trim();
      final myBranch  = widget.branchId.toLowerCase().trim();
      if (msgBranch != null && msgBranch.isNotEmpty && !CampSessionService.areBranchesMatching(msgBranch, myBranch)) return;

      if (type == RealtimeEvents.saveEntry ||
          type == 'token_created' ||
          type == 'save_entry') {
        final serial = (data['serial'] ?? data['id'])?.toString();
        if (serial != null && serial.isNotEmpty) {
          LocalStorageService.saveEntryLocal(widget.branchId, serial, data);
        }
        _debouncedRebuild();
      } else if (type == 'dispense_completed') {
        final serial = (data['serial'] ?? data['id'] ?? event['serial'] ?? event['id'])?.toString();
        if (serial != null && serial.isNotEmpty) {
          LocalStorageService.updateDispenseStatus(widget.branchId, serial, 'dispensed', receivedViaLan: true);
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
                final cleanSerial = CampSessionService.cleanSerial(serial, widget.branchId);
                final normSerial = cleanSerial.toUpperCase();
                final canonicalKey = '$normBranch-$normSerial';
                final candidateKeys = <String>{
                  canonicalKey,
                  '$normBranch-$cleanSerial',
                  normSerial,
                  cleanSerial,
                  if (serial != cleanSerial) serial,
                  if (serial != cleanSerial) '$normBranch-${serial.toUpperCase()}',
                };
                Map<String, dynamic>? existing;
                String matchedKey = canonicalKey;
                for (final ck in candidateKeys) {
                  final val = eBox.get(ck);
                  if (val is Map) {
                    existing = Map<String, dynamic>.from(val);
                    matchedKey = ck;
                    break;
                  }
                }
                if (existing != null) {
                  final updated = Map<String, dynamic>.from(existing);
                  updated['status'] = 'completed';
                  // Not an older or medicine-less copy over the stored prescription.
                  if (LocalStorageService.mayReplacePrescription(data, existing['prescription'])) {
                    updated['prescription'] = LocalStorageService.prescriptionForEmbedding(data);
                  }
                  updated['prescriptionId'] = data['id'] ?? cleanSerial;
                  updated['completedAt'] ??= data['completedAt'] ?? DateTime.now().toIso8601String();
                  if (data['doctorName'] != null) updated['doctorName'] = data['doctorName'];
                  if (data['doctorId'] != null) updated['doctorId'] = data['doctorId'];
                  if (data['daysOfMedicine'] != null) updated['daysOfMedicine'] = data['daysOfMedicine'];
                  eBox.put(canonicalKey, updated);
                  if (matchedKey != canonicalKey && eBox.containsKey(matchedKey)) {
                    eBox.delete(matchedKey);
                  }
                }
              }
            } catch (_) {}
          }
        }
        _debouncedRebuild();
      } else if (type == RealtimeEvents.savePatient ||
          type == 'save_patient' ||
          type == 'migrate_patient_key' ||
          type == 'patient_edit_approved') {
        _debouncedRebuild();
      } else if (type == RealtimeEvents.saveStockItem || type == 'save_stock_item' || type == 'medicine_registered' ||
          type == RealtimeEvents.deleteStockItem || type == 'delete_stock_item') {
        // RealtimeRouter already applied this to the stock box (single writer); re-saving the
        // raw payload here overwrote its result and rebuilt the queue on every stock tick.
        _debouncedRebuild();
      } else if (type == RealtimeEvents.tokenExceptionRequest || type == 'token_exception_request') {
        final requestId = (data['requestId'] ?? data['id'])?.toString() ??
            'local_${DateTime.now().millisecondsSinceEpoch}';
        final patientId = (data['patientId'] ?? '').toString().trim();
        if (patientId.isNotEmpty && LocalStorageService.hasApprovedTokenException(widget.branchId, patientId)) {
          return; // Already approved exception! Never re-display as pending.
        }
        final status = (data['status'] ?? '').toString().toLowerCase().trim();
        if (status == 'approved' || status == 'rejected') {
          return;
        }
        final localReq = <String, dynamic>{
          'id':          requestId,
          'requestType': 'token_exception',
          'status':      'pending',
          'patientId':   patientId,
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
      // Instantly request catch-up on mount so if the PC just booted after power cut,
      // all tokens are fetched from the LAN server in <100ms instead of waiting 2 minutes!
      RealtimeManager().requestCatchUp(branchId: widget.branchId);
    });

    // Safety net only: new tokens arrive as LAN pushes, and a catch-up already runs on
    // mount and on every reconnect. This used to run every 15 s — each time the server
    // re-sent the whole day and re-downloaded it from Firestore, and without LAN every
    // doctor PC read all of today's tokens from Firestore 4×/minute. That loop kept CPU,
    // RAM and network near 100% on the i3 PCs.
    var tick = 0;
    _queueCatchUpTimer = Timer.periodic(const Duration(minutes: 1), (_) {
      if (!mounted) return;
      tick++;
      if (!RealtimeManager().isConnected) {
        // Fallback when operating without LAN: only poll cloud if local queue is completely empty
        // and at a 15-minute interval, rather than hammering Firestore every 3 minutes.
        if (tick % 15 == 0 && (_cachedQueue == null || _cachedQueue!.isEmpty)) {
          manualCloudPull(showToast: false);
        }
      } else if (tick % 5 == 0) {
        RealtimeManager().requestCatchUp(branchId: widget.branchId); // every 5 min with LAN
      }
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
    _autoSelectRetry?.cancel();
    _debounceRebuildTimer?.cancel();
    _queueCatchUpTimer?.cancel();
    _queueSearchController.dispose();
    _realtimeSub.cancel();
    _connSub?.cancel();
    CampSessionService.activeCampNotifier.removeListener(_onActiveCampChanged);
    ConnectionManager().removeReconnectListener(_onLanReconnected);
    super.dispose();
  }

  void _onLanReconnected() {
    if (!mounted) return;
    debugPrint('[PatientQueue] 🔄 LAN reconnected — requesting catch-up from server');
    try {
      RealtimeManager().requestCatchUp(branchId: widget.branchId);
    } catch (_) {}
    _debouncedRebuild();
  }
  
  // ─── Debounce rebuild to batch events ─────────────────────
  void _debouncedRebuild() {
    if (_debounceRebuildTimer?.isActive ?? false) return;
    _debounceRebuildTimer = Timer(const Duration(milliseconds: 150), () {
      if (mounted) {
        _cachedQueue = null; // Clear cache so debounced pass computes fresh queue
        setState(() {});
        WidgetsBinding.instance.addPostFrameCallback((_) {
          _tryAutoSelectSmallestWaiting();
        });
      }
    });
  }

  // ─── On-Demand Cloud Recovery with Cooldown (Zero Continuous Reads) ───
  DateTime? _lastCloudPullTime;
  bool _isCloudPulling = false;

  Future<void> manualCloudPull({bool showToast = true, bool force = false}) async {
    if (RealtimeManager().isConnected) {
      await RealtimeManager().forceFlushAndCatchUp();
      if (showToast && mounted) {
        AppToast.showSnackBar(context, const SnackBar(
          content: Text('Requested sync from LAN server'),
          duration: Duration(seconds: 2),
        ));
      }
      return;
    }
    final now = DateTime.now();
    final cooldown = const Duration(seconds: 10);
    if (!force && _lastCloudPullTime != null && now.difference(_lastCloudPullTime!) < cooldown) {
      if (showToast && mounted) {
        AppToast.showSnackBar(context, SnackBar(
          content: Text('Please wait ${cooldown.inSeconds} seconds before pulling from cloud again.'),
          duration: const Duration(seconds: 2),
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
          AppToast.showSnackBar(context, const SnackBar(
            content: Text('✅ Cloud pull complete.'),
            backgroundColor: SoftPalette.green400,
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
              backgroundColor: SoftPalette.green400,
              foregroundColor: SoftPalette.gray50,
            ),
            child: const Text('Approve'),
          ),
        ],
      ),
    );

    if (approved != true) return;
    final doctorReason = reasonCtrl.text.trim();
    if (doctorReason.isEmpty) {
      AppToast.showSnackBar(context, const SnackBar(
        content: Text('Please enter a reason for the exception'),
      ));
      return;
    }

    try {
      final approvedBy = RealtimeManager().role ?? 'Doctor';
      final nowIso = DateTime.now().toIso8601String();
      await LocalStorageService.markLocalRequestDecided(requestId, 'approved', fields: {
        'doctorReason': doctorReason,
        'approvedBy': approvedBy,
        'reviewedAt': nowIso,
      });
      // The decision goes through the upload queue (retried until Firestore confirms it). On a
      // desk linked to the LAN the server uploads it once from the LAN message below; queuing
      // it here as well uploaded it twice.
      final uploadsHere = !LanFirestoreGate.isLanDesk;
      if (uploadsHere) await LocalStorageService.enqueueSync({
        'type':       'update_request_status',
        'branchId':   widget.branchId,
        'collection': 'edit_requests',
        'requestId':  requestId,
        'status':     'approved',
        'requestStatus': 'approved', // enqueueSync overwrites 'status' with the queue state
        'data': {
          'doctorReason': doctorReason,
          'approvedBy':   approvedBy,
          'approvedAt':   nowIso,
          'reviewedAt':   nowIso,
        },
      });

      if (uploadsHere) await LocalStorageService.enqueueSync({
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
        // The shift's date, as the token desk looks it up (night shift past midnight).
        dateKey: CampSessionService.resolveShiftAndDateKey(null, widget.branchId).dateKey,
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
            'approvedAt': nowIso,
            // The day it is for: a re-sent approval never becomes another day's exception.
            'dateKey':    CampSessionService.resolveShiftAndDateKey(null, widget.branchId).dateKey,
          },
        ),
      });

      if (mounted) {
        setState(() {
          _localExceptionRequests = _loadLocalExceptionRequests();
        });
        AppToast.showSnackBar(context, const SnackBar(
          content: Text('✅ Exception approved. Restriction cleared.'),
          backgroundColor: SoftPalette.green400,
        ));
      }
    } catch (e) {
      if (mounted) {
        AppToast.showSnackBar(context, SnackBar(content: Text('Failed: $e')));
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
              backgroundColor: SoftPalette.red400,
              foregroundColor: SoftPalette.gray50,
            ),
            child: const Text('Reject'),
          ),
        ],
      ),
    );

    if (rejected != true) return;

    try {
      // Same path as an approval: local copy, upload queue, LAN. The old direct SDK update
      // was the only record of a rejection; it hung when the quota was used up, failed when
      // the request had not been uploaded yet, and no other PC ever heard of it.
      final reason = reasonCtrl.text.trim();
      final rejectedBy = RealtimeManager().role ?? 'Doctor';
      final nowIso = DateTime.now().toIso8601String();
      final decision = {
        'doctorReason':    reason,
        'rejectionReason': reason,
        'rejectedBy':      rejectedBy,
        'rejectedAt':      nowIso,
        'reviewedAt':      nowIso,
      };
      await LocalStorageService.markLocalRequestDecided(requestId, 'rejected', fields: decision);
      // On a LAN desk the server uploads it from request_rejected below.
      if (!LanFirestoreGate.isLanDesk) await LocalStorageService.enqueueSync({
        'type':       'reject_request',
        'branchId':   widget.branchId,
        'collection': 'edit_requests',
        'requestId':  requestId,
        'data':       decision,
      });
      RealtimeManager().sendMessage({
        ...RealtimeEvents.payload(
          type: RealtimeEvents.requestRejected,
          branchId: widget.branchId,
          data: {'requestId': requestId, ...decision},
        ),
      });

      Hive.box('app_settings').delete('pending_exception_$requestId');
      _exceptionRequests.removeWhere((doc) => doc.id == requestId);
      _localExceptionRequests.removeWhere((r) => r['id'] == requestId);

      if (mounted) {
        setState(() {
          _localExceptionRequests = _loadLocalExceptionRequests();
        });
        AppToast.showSnackBar(context, const SnackBar(
          content: Text('❌ Exception request rejected.'),
          backgroundColor: SoftPalette.red400,
        ));
      }
    } catch (e) {
      if (mounted) {
        AppToast.showSnackBar(context, SnackBar(content: Text('Failed: $e')));
      }
    }
  }

  // ─── Auto-select smallest waiting ─────────────────────────────────────────
  Timer? _autoSelectRetry;
  DateTime? _behindSince;

  void _tryAutoSelectSmallestWaiting() {
    if (!mounted) return;

    // If a patient is currently selected, do NOT switch or re-select behind the doctor's back!
    if (widget.selectedPatient != null) {
      _behindSince = null;
      return;
    }

    // Never pick "next" while this desk is missing tokens the server already has: that is
    // how #2 got called before #1 (whose token had not reached this screen yet). Ask for the
    // missing tokens and try again shortly; after 4 s go ahead anyway so the doctor is never
    // blocked by a token this desk cannot apply. Offline, the local queue is all there is.
    final rm = RealtimeManager();
    if (rm.hasServerLink && rm.isBehindServer) {
      _behindSince ??= DateTime.now();
      if (DateTime.now().difference(_behindSince!) < const Duration(seconds: 4)) {
        rm.requestCatchUp(branchId: widget.branchId, reason: 'before_next_patient');
        _autoSelectRetry?.cancel();
        _autoSelectRetry = Timer(const Duration(milliseconds: 800), () {
          _cachedQueue = null; // re-read: the missing tokens may have arrived
          _tryAutoSelectSmallestWaiting();
        });
        return;
      }
    }
    _behindSince = null;

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
    if (smallestSerial.isEmpty) return;

    final currentSerial = (widget.selectedPatient?['serial'] ?? widget.selectedPatient?['id'])?.toString().trim();
    if (currentSerial != null && currentSerial.isNotEmpty && currentSerial == smallestSerial) {
      return; // Already selected, do not re-select
    }

    debugPrint('[PatientQueue] Auto-selecting smallest waiting: $smallestSerial');
    widget.onPatientSelected({...smallest, 'serial': smallestSerial, 'id': smallestSerial});
  }



  // ─── Injection / drip check ───────────────────────────────────────────────
  bool _isInjectionOrDrip(Map<String, dynamic> med) {
    final type = (med['type'] ?? '').toString().toLowerCase();
    if (type.contains('nebulization')) return true;
    return PatientFormHelper.isInjectable(med);
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

  static bool _isInventoryMed(Map<String, dynamic> m) {
    final id = (m['inventoryId'] ?? m['medicineId'])?.toString().trim();
    return id != null && id.isNotEmpty && id != 'null' && id != 'unknown';
  }

  int _getAvailableStock(
    Map<String, dynamic>? inventoryMed, {
    required String branchId,
    required List<Map<String, dynamic>> currentMeds,
    String? excludeSerial,
    String? patientCamp,
    int daysOfMedicine = 1,
    List<StockGroup>? within,
  }) {
    if (inventoryMed == null) return 999999;
    try {
      // One pool, all batches of the medicine added together, other patients' reservations
      // taken off (this token's own saved prescription excluded): the same figure the
      // doctor panel and the dispensar use.
      final pool = _stockPoolFor(branchId, patientCamp, inventoryMed);
      if (pool == null) return 0;
      final g = StockReader.groupForLine(pool, inventoryMed, excludeSerial: excludeSerial, within: within);
      if (g == null) return 0;
      final ids = g.batchIds.toSet();
      // Units already on this prescription being edited, in shelf units.
      double session = 0;
      for (final med in currentMeds) {
        if (med['isExternal'] == true || med['outOfStock'] == true) continue;
        if (ids.contains((med['inventoryId'] ?? '').toString().trim())) {
          session += StockMath.lineUnits(med, daysOfMedicine);
        }
      }
      final available = g.available - session;
      return available <= 0 ? 0 : available.floor();
    } catch (e) {
      debugPrint('[PatientQueue] _getAvailableStock error: $e');
      return 0;
    }
  }

  /// Stock pool of a prescription: the item's own pool (stock book records carry it), else
  /// the branch + the patient's camp, else this PC's active camp.
  StockPool? _stockPoolFor(String branchId, String? patientCamp, [Map<String, dynamic>? item]) {
    final own = StockPool.fromKey(item?['pool']?.toString());
    if (own != null) return own;
    return StockPool.of(branchId, patientCamp, fallbackCamp: CampSessionService.getActiveCamp(branchId));
  }

  /// This pool's stock as the medicine browser lists it: one row per medicine (all batches
  /// added together), quantity = on shelf, linked to its earliest usable batch.
  List<Map<String, dynamic>> _stockRowsFor(List<StockGroup> groups) {
    final out = <Map<String, dynamic>>[];
    for (final g in groups) {
      if (g.batches.isEmpty) continue;
      final first = g.primary;
      final row = Map<String, dynamic>.from(first);
      final q = g.onShelf;
      row['quantity'] = q.toInt() == q ? q.toInt() : q;
      row['_batches'] = g.batches;
      row['_batchIds'] = g.batchIds;
      row['id'] = (first['medicineId'] ?? first['id']).toString();
      out.add(row);
    }
    return out;
  }

  // ─── Add medicine sub-dialog ───────────────────────────────────────────────
  Future<Map<String, dynamic>?> _showAddMedicineSubDialog({
    required String branchId,
    required List<Map<String, dynamic>> currentMeds,
    required int daysOfMedicine,
    String? excludeSerial,
    String? patientCamp,
    Map<String, dynamic>? inventoryMed,
    Map<String, dynamic>? existingMed,
  }) async {
    final isEditing   = existingMed != null;
    final isInventory = inventoryMed != null || (isEditing && existingMed['inventoryId'] != null);
    final nameCtrl    = TextEditingController(text: isEditing ? (existingMed['name'] ?? '') : (isInventory ? (inventoryMed!['name'] ?? '') : ''));
    final qtyCtrl     = TextEditingController(text: isEditing ? (existingMed['quantity']?.toString() ?? '1') : '1');
    const validMealTimings = ['Empty Stomach', 'Before Meal', 'During Meal', 'After Meal', 'Before Sleep'];
    final rawMeal = isEditing ? (existingMed['meal'] ?? 'After Meal').toString() : 'After Meal';
    String mealTiming = 'After Meal';
    final lowerMeal = rawMeal.toLowerCase();
    if (lowerMeal.contains('empty')) {
      mealTiming = 'Empty Stomach';
    } else if (lowerMeal.contains('before') && (lowerMeal.contains('sleep') || lowerMeal.contains('bed'))) {
      mealTiming = 'Before Sleep';
    } else if (lowerMeal.contains('before')) {
      mealTiming = 'Before Meal';
    } else if (lowerMeal.contains('during') || lowerMeal.contains('with')) {
      mealTiming = 'During Meal';
    } else if (validMealTimings.contains(rawMeal)) {
      mealTiming = rawMeal;
    }

    const validDosages = ['1 spoon', '1/2 spoon', '1/3 spoon', '1/4 spoon'];
    final rawDosage = isEditing ? (existingMed['dosage'] ?? '1 spoon').toString() : '1 spoon';
    String dosage = validDosages.contains(rawDosage) ? rawDosage : '1 spoon';
    bool isSyrup      = false;
    bool isInjection  = false;
    String? stockError;

    void updateFields() {
      if (isInventory && inventoryMed != null) {
        final type  = (inventoryMed['type'] ?? '').toString().toLowerCase();
        final name  = (inventoryMed['name'] ?? '').toString().toLowerCase();
        isInjection = _isInjectionOrDrip(inventoryMed);
        isSyrup     = !isInjection && (type.contains('syrup') || type.contains('syp') || name.contains('syp') || name.contains('syrup'));
      } else if (isEditing) {
        final type  = (existingMed['type'] ?? '').toString().toLowerCase();
        final name  = (existingMed['name'] ?? '').toString().toLowerCase();
        isInjection = _isInjectionOrDrip(existingMed);
        isSyrup     = !isInjection && (type.contains('syrup') || type.contains('syp') || name.contains('syp') || name.contains('syrup'));
      } else {
        final text  = nameCtrl.text.toLowerCase().trim();
        isInjection = PatientFormHelper.isInjectablePrescription('', text);
        isSyrup     = !isInjection && (text.contains('syp.') || text.contains('syrup'));
      }
    }

    updateFields();
    final timingCtrl  = TextEditingController(text: isEditing ? (existingMed['timing'] ?? '1+0+1') : (isInjection ? '' : '1+0+1'));

    // Available for THIS line: the line being edited gives its own units back first.
    // An existing line already marked external / out of stock keeps its old behaviour.
    final bool existingIsExternal = isEditing &&
        (existingMed['isExternal'] == true || existingMed['outOfStock'] == true);
    int availableStock = 999999;
    if (isInventory) {
      final stockItem = inventoryMed ?? existingMed;
      final othersLines = isEditing
          ? currentMeds.where((m) => !identical(m, existingMed)).toList()
          : currentMeds;
      availableStock = _getAvailableStock(
        stockItem,
        branchId: branchId,
        currentMeds: othersLines,
        excludeSerial: excludeSerial,
        patientCamp: patientCamp,
        daysOfMedicine: daysOfMedicine,
      );
    }

    final result = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (context, setStateDialog) {
          void onNameChanged() {
            setStateDialog(() {
              updateFields();
              stockError = null;
            });
          }

          return AlertDialog(
            title: Text(isEditing
                ? (isInventory ? 'Edit Inventory Medicine' : 'Edit Custom Medicine')
                : (isInventory ? 'Add Inventory Medicine' : 'Add Custom Medicine')),
            content: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (stockError != null) ...[
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                      margin: const EdgeInsets.only(bottom: 12),
                      decoration: BoxDecoration(
                        color: context.adapt(SoftPalette.pink100m),
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(color: context.adapt(SoftPalette.red400)),
                      ),
                      child: Row(
                        children: [
                          Icon(Icons.error_outline_rounded, color: context.adapt(SoftPalette.red550), size: 18),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              stockError!,
                              style: TextStyle(
                                color: context.adapt(SoftPalette.red550),
                                fontSize: 12.5,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                  if (isInventory) ...[
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                      margin: const EdgeInsets.only(bottom: 12),
                      decoration: BoxDecoration(
                        color: availableStock <= 0
                            ? context.adapt(SoftPalette.pink100m)
                            : (availableStock <= 10 ? context.adapt(SoftPalette.amber50m) : context.adapt(SoftPalette.green100m)),
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(
                          color: availableStock <= 0
                              ? context.adapt(SoftPalette.red300)
                              : (availableStock <= 10 ? context.adapt(SoftPalette.amber150) : context.adapt(SoftPalette.green300)),
                        ),
                      ),
                      child: Row(
                        children: [
                          Icon(
                            availableStock <= 0
                                ? Icons.warning_amber_rounded
                                : (availableStock <= 10 ? Icons.info_outline : Icons.inventory_2_outlined),
                            size: 16,
                            color: availableStock <= 0
                                ? context.adapt(SoftPalette.red550)
                                : (availableStock <= 10 ? context.adapt(SoftPalette.orange400) : context.adapt(SoftPalette.teal600)),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              availableStock <= 0
                                  ? '⚠️ Out of Stock! (0 units available)'
                                  : (availableStock <= 10
                                      ? '⚠️ Low Stock: Only $availableStock units available'
                                      : 'Available Stock: $availableStock units'),
                              style: TextStyle(
                                fontSize: 12,
                                fontWeight: FontWeight.bold,
                                color: availableStock <= 0
                                    ? context.adapt(SoftPalette.red550)
                                    : (availableStock <= 10 ? context.adapt(SoftPalette.orange400) : context.adapt(SoftPalette.teal600)),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                  TextField(
                    controller: nameCtrl,
                    readOnly: isInventory,
                    decoration: InputDecoration(
                      labelText: 'Medicine name',
                      border: const OutlineInputBorder(),
                      filled: isInventory,
                      fillColor: isInventory ? context.adapt(SoftPalette.gray100) : null,
                    ),
                    onChanged: (val) {
                      if (!isInventory) onNameChanged();
                    },
                  ),
                  const SizedBox(height: 12),
                  if (!isInjection) ...[
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        const Text('Timing (Morning+Evening+Night):', style: TextStyle(fontWeight: FontWeight.w600)),
                        Text('e.g. 1+0+1', style: TextStyle(fontSize: 11, color: context.adapt(SoftPalette.gray500), fontStyle: FontStyle.italic)),
                      ],
                    ),
                    const SizedBox(height: 6),
                    TextField(
                      controller: timingCtrl,
                      keyboardType: TextInputType.number,
                      inputFormatters: [const DoseTimingInputFormatter()],
                      decoration: const InputDecoration(
                        hintText: 'e.g. 1+0+1 or 1+1+1',
                        border: OutlineInputBorder(),
                      ),
                      onChanged: (value) {
                        // '+' is inserted by DoseTimingInputFormatter as the doctor types.
                        setStateDialog(() => stockError = null);
                      },
                    ),
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 6,
                      runSpacing: 6,
                      children: ['1+0+1', '1+1+1', '1+0+0', '0+0+1', '0+1+0', '1+1+0'].map((chip) {
                        final isSelected = timingCtrl.text == chip;
                        return InkWell(
                          onTap: () {
                            setStateDialog(() {
                              timingCtrl.text = chip;
                              timingCtrl.selection = TextSelection.collapsed(offset: chip.length);
                              stockError = null;
                            });
                          },
                          borderRadius: BorderRadius.circular(16),
                          child: Container(
                            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                            decoration: BoxDecoration(
                              color: isSelected ? _teal : context.adapt(SoftPalette.gray100),
                              borderRadius: BorderRadius.circular(16),
                              border: Border.all(
                                color: isSelected ? _teal : context.adapt(SoftPalette.gray150),
                              ),
                            ),
                            child: Text(
                              chip,
                              style: TextStyle(
                                fontSize: 11.5,
                                fontWeight: FontWeight.w600,
                                color: isSelected ? SoftPalette.gray50 : context.adapt(SoftPalette.gray700),
                              ),
                            ),
                          ),
                        );
                      }).toList(),
                    ),
                    const SizedBox(height: 12),
                    DropdownButtonFormField<String>(
                      value: validMealTimings.contains(mealTiming) ? mealTiming : 'After Meal',
                      decoration: const InputDecoration(
                        labelText: 'Timing Instruction',
                        border: OutlineInputBorder(),
                      ),
                      items: validMealTimings
                          .map((d) => DropdownMenuItem(value: d, child: Text(d)))
                          .toList(),
                      onChanged: (v) {
                        setStateDialog(() {
                          mealTiming = v ?? mealTiming;
                          stockError = null;
                        });
                      },
                    ),
                    if (isSyrup) ...[
                      const SizedBox(height: 12),
                      DropdownButtonFormField<String>(
                        value: validDosages.contains(dosage) ? dosage : '1 spoon',
                        decoration: const InputDecoration(
                          labelText: 'Dosage',
                          border: OutlineInputBorder(),
                        ),
                        items: validDosages
                            .map((d) => DropdownMenuItem(value: d, child: Text(d)))
                            .toList(),
                        onChanged: (v) {
                          setStateDialog(() {
                            dosage = v ?? dosage;
                            stockError = null;
                          });
                        },
                      ),
                    ],
                  ] else ...[
                    TextField(
                      controller: qtyCtrl,
                      keyboardType: TextInputType.number,
                      decoration: const InputDecoration(
                        labelText: 'Quantity',
                        border: OutlineInputBorder(),
                      ),
                      onChanged: (_) {
                        setStateDialog(() => stockError = null);
                      },
                    ),
                  ],
                ],
              ),
            ),
            actions: [
              if (isEditing) ...[
                TextButton.icon(
                  style: TextButton.styleFrom(foregroundColor: context.adapt(SoftPalette.red400)),
                  icon: const Icon(Icons.delete_outline, size: 16),
                  label: const Text('Remove'),
                  onPressed: () => Navigator.pop(ctx, {'_deleted': true}),
                ),
                const SizedBox(width: 24),
              ],
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: Text('Cancel', style: TextStyle(color: context.adapt(_teal))),
              ),
              ElevatedButton(
                style: ElevatedButton.styleFrom(
                  backgroundColor: _teal,
                  foregroundColor: SoftPalette.gray50,
                ),
                onPressed: () {
                  final name = nameCtrl.text.trim();
                  if (name.isEmpty) {
                    setStateDialog(() => stockError = 'Please enter medicine name');
                    return;
                  }
                  final resolvedDose = (inventoryMed != null
                          ? (inventoryMed['dose'] ?? inventoryMed['dosage'] ?? '')
                          : (existingMed != null ? (existingMed['dose'] ?? existingMed['dosage'] ?? '') : ''))
                      .toString()
                      .trim();
                  final effectiveId = inventoryMed?['id'] ?? existingMed?['inventoryId'] ?? existingMed?['medicineId'];

                  Map<String, dynamic> newMed;
                  if (isInjection) {
                    final qty = int.tryParse(qtyCtrl.text) ?? 1;
                    if (qty <= 0) {
                      setStateDialog(() => stockError = 'Quantity must be at least 1');
                      return;
                    }
                    final medType = inventoryMed != null
                        ? (inventoryMed['type'] ?? 'Injection')
                        : ((existingMed?['type']) ?? 'Injection');
                    if (isInventory) {
                      final bool isStockZero = availableStock <= 0;
                      final bool exceedsStock = qty > availableStock;
                      if (!existingIsExternal && (isStockZero || exceedsStock)) {
                        setStateDialog(() => stockError = isStockZero
                            ? '⛔ Out of stock: this medicine has none available, so it cannot be prescribed.'
                            : '⛔ Only $availableStock available in stock — cannot prescribe $qty.');
                        return;
                      }
                      newMed = {
                        'name': name,
                        'formula': (inventoryMed?['formula'] ?? existingMed?['formula'] ?? '').toString().trim(),
                        'quantity': qty,
                        'type': medType,
                        'dose': resolvedDose,
                        'dosage': resolvedDose,
                        'inventoryId': effectiveId,
                        'medicineId': effectiveId,
                        if (isStockZero || exceedsStock) 'isExternal': true,
                        if (isStockZero) 'outOfStock': true,
                        if (exceedsStock) 'stockShortage': qty - (availableStock > 0 ? availableStock : 0),
                      };
                    } else {
                      newMed = {
                        'name': name,
                        'formula': (inventoryMed?['formula'] ?? existingMed?['formula'] ?? '').toString().trim(),
                        'quantity': qty,
                        'type': medType,
                        'dose': resolvedDose,
                        'dosage': resolvedDose,
                        'inventoryId': effectiveId,
                        'medicineId': effectiveId,
                      };
                    }
                  } else {
                    final resolvedTiming = PatientFormHelper.resolveCanonicalTiming(
                      timingCtrl.text,
                      mealTiming: mealTiming,
                    );
                    final timingStr = resolvedTiming.timing;
                    final qty = isSyrup ? 1 : resolvedTiming.dailyQty;
                    final totalRequired = isSyrup ? 1 : qty * daysOfMedicine;
                    final medType = isSyrup
                        ? 'Syrup'
                        : (inventoryMed != null
                            ? (inventoryMed['type'] ?? 'Tablet')
                            : ((existingMed?['type']) ?? 'Tablet'));
                    if (isInventory) {
                      final bool isStockZero = availableStock <= 0;
                      final bool exceedsStock = totalRequired > availableStock;
                      if (!existingIsExternal && (isStockZero || exceedsStock)) {
                        setStateDialog(() => stockError = isStockZero
                            ? '⛔ Out of stock: this medicine has none available, so it cannot be prescribed.'
                            : '⛔ Only $availableStock available in stock — this dose and number of days needs $totalRequired.');
                        return;
                      }
                      newMed = {
                        'name': name,
                        'formula': (inventoryMed?['formula'] ?? existingMed?['formula'] ?? '').toString().trim(),
                        'quantity': qty,
                        'timing': timingStr,
                        'meal': mealTiming,
                        'dosage': isSyrup ? dosage : resolvedDose,
                        'dose': resolvedDose,
                        'type': medType,
                        'inventoryId': effectiveId,
                        'medicineId': effectiveId,
                        if (isStockZero || exceedsStock) 'isExternal': true,
                        if (isStockZero) 'outOfStock': true,
                        if (exceedsStock) 'stockShortage': totalRequired - (availableStock > 0 ? availableStock : 0),
                      };
                    } else {
                      newMed = {
                        'name': name,
                        'formula': (inventoryMed?['formula'] ?? existingMed?['formula'] ?? '').toString().trim(),
                        'quantity': qty,
                        'timing': timingStr,
                        'meal': mealTiming,
                        'dosage': isSyrup ? dosage : resolvedDose,
                        'dose': resolvedDose,
                        'type': medType,
                        'inventoryId': effectiveId,
                        'medicineId': effectiveId,
                      };
                    }
                  }
                  Navigator.pop(ctx, newMed);
                },
                child: Text(isEditing ? 'Update' : 'Add'),
              ),
            ],
          );
        },
      ),
    );

    WidgetsBinding.instance.addPostFrameCallback((_) {
      nameCtrl.dispose();
      timingCtrl.dispose();
      qtyCtrl.dispose();
    });
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
    final brand = Theme.of(context).colorScheme.primary;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text(
              'Days of medicine',
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: isDark ? SoftPalette.slate350 : SoftPalette.slate700,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Container(
                padding: const EdgeInsets.all(3),
                decoration: BoxDecoration(
                  color: isDark ? SoftPalette.slate900 : SoftPalette.slate100,
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(
                    color: isDark ? SoftPalette.slate700 : SoftPalette.slate200,
                  ),
                ),
                child: Row(
                  children: [1, 2, 3].map((day) {
                    final isSelected = selectedDays == day;
                    final isDisabled = hasInjection && day > 1;
                    final extra = (pricePerDay > 0 && day > 1) ? (day - 1) * pricePerDay : 0;

                    return Expanded(
                      child: InkWell(
                        onTap: isDisabled
                            ? () {
                                AppToast.showSnackBar(context, const SnackBar(
                                  content: Text('💉 Injection prescribed — only 1 day of medicine is allowed'),
                                  backgroundColor: SoftPalette.amber300,
                                  duration: Duration(seconds: 2),
                                ));
                              }
                            : () => onChanged(day),
                        borderRadius: BorderRadius.circular(7),
                        child: AnimatedContainer(
                          duration: const Duration(milliseconds: 160),
                          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 7),
                          decoration: BoxDecoration(
                            color: isSelected
                                ? (isDark ? brand.withValues(alpha: 0.35) : brand)
                                : Colors.transparent,
                            borderRadius: BorderRadius.circular(7),
                            border: isSelected
                                ? Border.all(color: isDark ? brand : Colors.transparent)
                                : null,
                          ),
                          child: Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(
                                '$day ${day == 1 ? 'day' : 'days'}',
                                style: TextStyle(
                                  fontSize: 12,
                                  fontWeight: isSelected ? FontWeight.w700 : FontWeight.w500,
                                  color: isDisabled
                                      ? (isDark ? SoftPalette.slate600 : SoftPalette.gray350)
                                      : (isSelected
                                          ? SoftPalette.gray50
                                          : (isDark ? SoftPalette.slate350 : SoftPalette.slate700)),
                                ),
                              ),
                              if (extra > 0 && !isDisabled) ...[
                                const SizedBox(width: 4),
                                Text(
                                  '+$extra',
                                  style: TextStyle(
                                    fontSize: 10.5,
                                    fontWeight: FontWeight.w600,
                                    color: isSelected
                                        ? SoftPalette.gray50A70
                                        : (isDark ? SoftPalette.slate400 : SoftPalette.slate550),
                                  ),
                                ),
                              ],
                            ],
                          ),
                        ),
                      ),
                    );
                  }).toList(),
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 4),
        if (hasInjection)
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: context.adapt(SoftPalette.amber100m),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: context.adapt(SoftPalette.amber300)),
            ),
            child: Row(children: [
              Icon(Icons.vaccines_rounded, size: 13, color: context.adapt(SoftPalette.orange350)),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  'Injection prescribed — only 1 day of medicine is allowed. '
                  'Multi-day selection is disabled.',
                  style: TextStyle(
                      fontSize: 11,
                      color: context.adapt(SoftPalette.orange400),
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
                : 'No charge for ${BranchLabels.text(queueType, widget.branchId)} patients.',
            style: TextStyle(
                fontSize: 11,
                color: context.adapt(SoftPalette.gray500),
                fontStyle: FontStyle.italic),
          ),
      ],
    );
  }

  // ─── Modal medicine browser for edit dialog ──────────────────────────────
  Future<void> _showMedicineSelectionModal({
    required BuildContext parentContext,
    required String branchId,
    required String? patientCamp,
    required int daysOfMedicine,
    required List<Map<String, dynamic>> currentMeds,
    required String excludeSerial,
    required Function(Map<String, dynamic>) onMedicineAdded,
  }) async {
    final queryCtrl = TextEditingController();
    String selectedCategory = 'all';

    // This patient's stock pool only (no branch-wide / all-branches fallback).
    // Groups are read once per opening (other patients' reservations do not change while
    // this dialog is open; this prescription's own lines are counted per row).
    final modalPool = _stockPoolFor(branchId, patientCamp);
    final modalGroups = modalPool == null
        ? const <StockGroup>[]
        : StockReader.groups(modalPool, excludeSerial: excludeSerial);
    final fallbackStock = _stockRowsFor(modalGroups);

    const quickSearchKeywords = [
      'Paracetamol', 'Amoxicillin', 'Cipro', 'Omeprazole',
      'Metformin', 'Diclofenac', 'Panadol', 'Flagyl'
    ];

    const categoryTabs = [
      {'id': 'all', 'label': 'All', 'icon': Icons.apps},
      {'id': 'tablet', 'label': 'Tablets', 'icon': FontAwesomeIcons.tablets},
      {'id': 'syrup', 'label': 'Syrups', 'icon': Icons.medication_liquid},
      {'id': 'injection', 'label': 'Injections', 'icon': FontAwesomeIcons.syringe},
      {'id': 'capsule', 'label': 'Capsules', 'icon': FontAwesomeIcons.capsules},
      {'id': 'drop', 'label': 'Drops', 'icon': Icons.water_drop_outlined},
    ];

    await showDialog(
      context: parentContext,
      builder: (dialogCtx) => StatefulBuilder(
        builder: (ctx, setModalState) {
          final isDark = Theme.of(ctx).brightness == Brightness.dark;
          final query = queryCtrl.text.trim().toLowerCase();

          final filteredMeds = fallbackStock.where((m) {
            final name = (m['name'] ?? '').toString().toLowerCase();
            final formula = (m['formula'] ?? '').toString().toLowerCase();
            final code = (m['code'] ?? m['itemCode'] ?? '').toString().toLowerCase();
            final barcode = (m['barcode'] ?? m['rollNo'] ?? '').toString().toLowerCase();
            final packBarcode = (m['packBarcode'] ?? '').toString().toLowerCase();
            final type = (m['type'] ?? m['dosageForm'] ?? '').toString().toLowerCase();

            if (selectedCategory != 'all') {
              if (selectedCategory == 'injection') {
                if (!_isInjectionOrDrip(m)) return false;
              } else if (!type.contains(selectedCategory) && !name.contains(selectedCategory)) {
                return false;
              }
            }

            if (query.isNotEmpty) {
              final qNum = int.tryParse(query);
              final bNum = int.tryParse(barcode);
              final numMatch = qNum != null && bNum != null && qNum == bNum;
              if (!name.contains(query) &&
                  !formula.contains(query) &&
                  !code.contains(query) &&
                  !barcode.contains(query) &&
                  !packBarcode.contains(query) &&
                  !type.contains(query) &&
                  !numMatch) {
                return false;
              }
            }
            return true;
          }).toList();
          // Out-of-stock medicines are not normal choices: shown disabled, below the rest.
          {
            final inStock = <Map<String, dynamic>>[];
            final outOfStock = <Map<String, dynamic>>[];
            for (final m in filteredMeds) {
              final avail = _getAvailableStock(
                m,
                branchId: branchId,
                currentMeds: currentMeds,
                excludeSerial: excludeSerial,
                patientCamp: patientCamp,
                daysOfMedicine: daysOfMedicine,
                within: modalGroups,
              );
              (avail > 0 ? inStock : outOfStock).add(m);
            }
            filteredMeds
              ..clear()
              ..addAll(inStock)
              ..addAll(outOfStock);
          }

          return Dialog(
            backgroundColor: isDark ? SoftPalette.slate800 : SoftPalette.gray50,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
            insetPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 750, maxHeight: 680),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // Dialog Header
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
                    decoration: BoxDecoration(
                      color: _teal,
                      borderRadius: const BorderRadius.only(topLeft: Radius.circular(20), topRight: Radius.circular(20)),
                    ),
                    child: Row(
                      children: [
                        const FaIcon(FontAwesomeIcons.pills, color: SoftPalette.gray50, size: 18),
                        const SizedBox(width: 10),
                        const Text(
                          'Formulary Inventory Search',
                          style: TextStyle(color: SoftPalette.gray50, fontSize: 16, fontWeight: FontWeight.bold),
                        ),
                        const Spacer(),
                        IconButton(
                          icon: const Icon(Icons.close, color: SoftPalette.gray50),
                          onPressed: () => Navigator.pop(dialogCtx),
                          tooltip: 'Close',
                        ),
                      ],
                    ),
                  ),

                  // Search Box + Quick Keywords + Categories
                  Container(
                    padding: const EdgeInsets.fromLTRB(16, 12, 16, 10),
                    decoration: BoxDecoration(
                      color: isDark ? SoftPalette.slate900 : SoftPalette.gray50,
                      border: Border(bottom: BorderSide(color: isDark ? SoftPalette.slate700 : SoftPalette.gray100)),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        TextField(
                          controller: queryCtrl,
                          autofocus: true,
                          onChanged: (_) => setModalState(() {}),
                          decoration: InputDecoration(
                            hintText: 'Search formulary by name, formula, roll no, or type...',
                            prefixIcon: Icon(Icons.search, color: context.adapt(_teal)),
                            suffixIcon: queryCtrl.text.isNotEmpty
                                ? IconButton(
                                    icon: const Icon(Icons.clear),
                                    onPressed: () {
                                      queryCtrl.clear();
                                      setModalState(() {});
                                    },
                                  )
                                : null,
                            filled: true,
                            fillColor: isDark ? SoftPalette.slate800 : SoftPalette.gray50,
                            contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                            border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none),
                            focusedBorder: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(12),
                              borderSide: BorderSide(color: context.adapt(_teal), width: 2),
                            ),
                          ),
                        ),
                        const SizedBox(height: 8),
                        // Quick keyword chips
                        SingleChildScrollView(
                          scrollDirection: Axis.horizontal,
                          child: Row(
                            children: [
                              Text(
                                'Quick: ',
                                style: TextStyle(
                                  fontSize: 11,
                                  fontWeight: FontWeight.bold,
                                  color: isDark ? SoftPalette.slate350 : SoftPalette.gray500,
                                ),
                              ),
                              ...quickSearchKeywords.map((kw) {
                                final active = queryCtrl.text.toLowerCase() == kw.toLowerCase();
                                return Padding(
                                  padding: const EdgeInsets.only(right: 6),
                                  child: InkWell(
                                    onTap: () {
                                      setModalState(() {
                                        if (active) {
                                          queryCtrl.clear();
                                        } else {
                                          queryCtrl.text = kw;
                                        }
                                      });
                                    },
                                    borderRadius: BorderRadius.circular(8),
                                    child: Container(
                                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                                      decoration: BoxDecoration(
                                        color: active ? context.adapt(_teal).withValues(alpha: 0.25) : (isDark ? SoftPalette.slate800 : SoftPalette.gray50),
                                        borderRadius: BorderRadius.circular(8),
                                        border: Border.all(
                                          color: active ? context.adapt(_teal) : (isDark ? SoftPalette.slate700 : SoftPalette.gray150),
                                          width: active ? 1.2 : 0.8,
                                        ),
                                      ),
                                      child: Text(
                                        kw,
                                        style: TextStyle(
                                          fontSize: 11,
                                          fontWeight: active ? FontWeight.bold : FontWeight.w500,
                                          color: active ? context.adapt(_teal) : (isDark ? SoftPalette.slate200 : SoftPalette.gray700),
                                        ),
                                      ),
                                    ),
                                  ),
                                );
                              }),
                            ],
                          ),
                        ),
                        const SizedBox(height: 8),
                        // Category Tabs
                        SingleChildScrollView(
                          scrollDirection: Axis.horizontal,
                          child: Row(
                            children: categoryTabs.map((cat) {
                              final id = cat['id'] as String;
                              final label = cat['label'] as String;
                              final icon = cat['icon'] as IconData;
                              final isSelected = selectedCategory == id;
                              return Padding(
                                padding: const EdgeInsets.only(right: 6),
                                child: FilterChip(
                                  showCheckmark: false,
                                  avatar: Icon(
                                    icon,
                                    size: 13,
                                    color: isSelected ? SoftPalette.gray50 : (isDark ? SoftPalette.teal300 : _teal),
                                  ),
                                  label: Text(label),
                                  selected: isSelected,
                                  selectedColor: _teal,
                                  backgroundColor: isDark ? SoftPalette.slate800 : SoftPalette.gray50,
                                  labelStyle: TextStyle(
                                    color: isSelected ? SoftPalette.gray50 : (isDark ? SoftPalette.slate200 : SoftPalette.gray700),
                                    fontWeight: isSelected ? FontWeight.bold : FontWeight.w500,
                                    fontSize: 11.5,
                                  ),
                                  padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(10),
                                    side: BorderSide(
                                      color: isSelected ? _teal : (isDark ? SoftPalette.slate700 : SoftPalette.gray150),
                                      width: isSelected ? 1.2 : 0.8,
                                    ),
                                  ),
                                  onSelected: (_) => setModalState(() => selectedCategory = id),
                                ),
                              );
                            }).toList(),
                          ),
                        ),
                      ],
                    ),
                  ),

                  // ── Active Selected Medicines Tray ───────────────
                  if (currentMeds.isNotEmpty) ...[
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                      decoration: BoxDecoration(
                        color: isDark ? SoftPalette.slate900 : SoftPalette.slate100,
                        border: Border(bottom: BorderSide(color: isDark ? SoftPalette.slate700 : SoftPalette.gray150)),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Row(
                            children: [
                              Icon(Icons.check_circle, size: 14, color: context.adapt(_teal)),
                              const SizedBox(width: 6),
                              Text(
                                'Selected Medicines (${currentMeds.length})',
                                style: TextStyle(
                                  fontSize: 12,
                                  fontWeight: FontWeight.bold,
                                  color: isDark ? SoftPalette.teal300 : _teal,
                                ),
                              ),
                              const Spacer(),
                              Text(
                                'Tap to edit • ✕ to remove',
                                style: TextStyle(fontSize: 10.5, color: isDark ? SoftPalette.slate350 : SoftPalette.gray350),
                              ),
                            ],
                          ),
                          const SizedBox(height: 6),
                          SingleChildScrollView(
                            scrollDirection: Axis.horizontal,
                            child: Row(
                              children: currentMeds.map((m) {
                                final name = (m['name'] ?? '').toString().trim();
                                final abbrev = _getMedAbbrev(m);
                                final isInj = _isInjectionOrDrip(m);
                                final isCust = !_isInventoryMed(m);
                                final timing = (m['timing'] ?? '').toString().trim();
                                final qty = m['quantity'] ?? 1;
                                final chipBg = isInj
                                    ? SoftPalette.orange400
                                    : (isCust ? SoftPalette.slate600 : _teal);

                                return Padding(
                                  padding: const EdgeInsets.only(right: 6),
                                  child: InputChip(
                                    avatar: Icon(isCust ? Icons.auto_awesome : Icons.edit, size: 11, color: SoftPalette.gray50A70),
                                    label: Text(
                                      '${abbrev.isNotEmpty && !name.toLowerCase().startsWith(abbrev.toLowerCase()) ? "$abbrev " : ""}$name ×$qty${timing.isNotEmpty ? " ($timing)" : ""}',
                                      style: const TextStyle(fontSize: 11.5, fontWeight: FontWeight.bold, color: SoftPalette.gray50),
                                    ),
                                    backgroundColor: chipBg,
                                    deleteIconColor: SoftPalette.gray50A70,
                                    materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                                    onPressed: () async {
                                      final res = await _showAddMedicineSubDialog(
                                        branchId: branchId,
                                        currentMeds: currentMeds,
                                        daysOfMedicine: daysOfMedicine,
                                        excludeSerial: excludeSerial,
                                        patientCamp: patientCamp,
                                        existingMed: m,
                                      );
                                      if (res != null) {
                                        if (res['_deleted'] == true) {
                                          currentMeds.remove(m);
                                        } else {
                                          final idx = currentMeds.indexOf(m);
                                          if (idx != -1) currentMeds[idx] = res;
                                        }
                                        if (dialogCtx.mounted) setModalState(() {});
                                      }
                                    },
                                    onDeleted: () {
                                      currentMeds.remove(m);
                                      if (dialogCtx.mounted) setModalState(() {});
                                    },
                                  ),
                                );
                              }).toList(),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],

                  // Results list
                  Flexible(
                    child: filteredMeds.isEmpty
                        ? Center(
                            child: Padding(
                              padding: const EdgeInsets.all(32),
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Icon(Icons.search_off_rounded, size: 48, color: context.adapt(SoftPalette.gray300)),
                                  const SizedBox(height: 12),
                                  Text(
                                    queryCtrl.text.isNotEmpty
                                        ? 'No medicines matching "${queryCtrl.text}"'
                                        : 'No medicines in this category',
                                    style: TextStyle(fontSize: 14, color: context.adapt(SoftPalette.gray500)),
                                  ),
                                ],
                              ),
                            ),
                          )
                        : ListView.separated(
                            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                            itemCount: filteredMeds.length,
                            separatorBuilder: (_, __) => Divider(
                              height: 1,
                              color: isDark ? SoftPalette.slate700 : SoftPalette.gray100,
                            ),
                            itemBuilder: (ctx, i) {
                              final m = filteredMeds[i];
                              final abbrev = _getMedAbbrev(m);
                              final namePart = (m['name'] ?? '').toString().trim();
                              final medType = (m['type'] ?? m['dosageForm'] ?? m['form'] ?? '').toString().trim();
                              final dose = (m['dose'] ?? '').toString().trim();
                              final formula = (m['formula'] ?? '').toString().trim();
                              final availableStock = _getAvailableStock(
                                m,
                                branchId: branchId,
                                currentMeds: currentMeds,
                                excludeSerial: excludeSerial,
                                patientCamp: patientCamp,
                                daysOfMedicine: daysOfMedicine,
                                within: modalGroups,
                              );
                              final isOutOfStock = availableStock <= 0;
                              final isLowStock = availableStock > 0 && availableStock <= 10;
                              final existingIdx = currentMeds.indexWhere((cm) {
                                if (m['id'] != null && cm['inventoryId'] != null) {
                                  return cm['inventoryId'].toString() == m['id'].toString();
                                }
                                final cmName = (cm['name'] ?? '').toString().trim().toLowerCase();
                                final cmType = (cm['type'] ?? '').toString().toLowerCase().trim();
                                final cmDose = (cm['dose'] ?? cm['dosage'] ?? '').toString().toLowerCase().trim();
                                final nName = namePart.toLowerCase();
                                final nType = medType.toLowerCase();
                                final nDose = dose.toLowerCase();
                                return cmName == nName &&
                                    (cmType.isEmpty || nType.isEmpty || cmType == nType) &&
                                    (cmDose.isEmpty || nDose.isEmpty || cmDose == nDose);
                              });
                              final isAlreadyPrescribed = existingIdx != -1;

                              final label = abbrev.isNotEmpty &&
                                      !namePart.toLowerCase().startsWith(abbrev.toLowerCase())
                                  ? '$abbrev $namePart'
                                  : namePart;

                              return ListTile(
                                dense: true,
                                tileColor: isAlreadyPrescribed ? context.adapt(_teal).withValues(alpha: 0.08) : null,
                                contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                                title: Row(
                                  children: [
                                    Flexible(
                                      child: Text(
                                        label,
                                        style: TextStyle(
                                          fontWeight: FontWeight.bold,
                                          fontSize: 14,
                                          color: isOutOfStock
                                              ? context.adapt(SoftPalette.red500)
                                              : (isDark ? SoftPalette.gray50 : SoftPalette.gray800),
                                        ),
                                      ),
                                    ),
                                    if (medType.isNotEmpty) ...[
                                      const SizedBox(width: 6),
                                      Container(
                                        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1.5),
                                        decoration: BoxDecoration(
                                          color: context.adapt(_teal).withValues(alpha: 0.1),
                                          borderRadius: BorderRadius.circular(6),
                                          border: Border.all(color: context.adapt(_teal).withValues(alpha: 0.3), width: 0.5),
                                        ),
                                        child: Text(
                                          medType,
                                          style: TextStyle(fontSize: 10, fontWeight: FontWeight.bold, color: context.adapt(_teal)),
                                        ),
                                      ),
                                    ],
                                    if (dose.isNotEmpty) ...[
                                      const SizedBox(width: 4),
                                      Container(
                                        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1.5),
                                        decoration: BoxDecoration(
                                          color: isDark ? SoftPalette.slate700 : SoftPalette.gray100,
                                          borderRadius: BorderRadius.circular(6),
                                        ),
                                        child: Text(
                                          dose,
                                          style: TextStyle(
                                            fontSize: 10,
                                            color: isDark ? SoftPalette.slate200 : SoftPalette.gray550,
                                          ),
                                        ),
                                      ),
                                    ],
                                  ],
                                ),
                                subtitle: formula.isNotEmpty
                                    ? Row(
                                        children: [
                                          Icon(Icons.biotech_rounded, size: 13, color: context.adapt(_teal)),
                                          const SizedBox(width: 4),
                                          Flexible(
                                            child: Text(
                                              formula,
                                              style: TextStyle(
                                                fontSize: 11,
                                                fontStyle: FontStyle.italic,
                                                color: isDark ? SoftPalette.slate350 : SoftPalette.gray500,
                                              ),
                                              overflow: TextOverflow.ellipsis,
                                            ),
                                          ),
                                        ],
                                      )
                                    : null,
                                trailing: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Container(
                                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                                      decoration: BoxDecoration(
                                        color: isOutOfStock
                                            ? context.adapt(SoftPalette.pink100m)
                                            : (isLowStock ? context.adapt(SoftPalette.amber100m) : context.adapt(SoftPalette.green100m)),
                                        borderRadius: BorderRadius.circular(8),
                                        border: Border.all(
                                          color: isOutOfStock
                                              ? context.adapt(SoftPalette.red400)
                                              : (isLowStock ? context.adapt(SoftPalette.amber300) : context.adapt(SoftPalette.green300)),
                                          width: 0.8,
                                        ),
                                      ),
                                      child: Text(
                                        'Stock: $availableStock',
                                        style: TextStyle(
                                          fontSize: 11,
                                          fontWeight: FontWeight.bold,
                                          color: isOutOfStock
                                              ? context.adapt(SoftPalette.red550)
                                              : (isLowStock ? context.adapt(SoftPalette.orange400) : context.adapt(SoftPalette.green550)),
                                        ),
                                      ),
                                    ),
                                    const SizedBox(width: 8),
                                    Builder(
                                      builder: (context) {
                                         int findExistingIndex() {
                                           final mId = (m['id'] ?? m['medicineId'])?.toString().trim();
                                           final nName = (m['name'] ?? '').toString().trim().toLowerCase();
                                           final nType = (m['type'] ?? m['dosageForm'] ?? m['form'] ?? '').toString().trim().toLowerCase();
                                           final nDose = (m['dose'] ?? '').toString().trim().toLowerCase();

                                           return currentMeds.indexWhere((cm) {
                                             final cmId = (cm['inventoryId'] ?? cm['medicineId'])?.toString().trim();
                                             if (mId != null && mId.isNotEmpty && mId != 'unknown' &&
                                                 cmId != null && cmId.isNotEmpty && cmId != 'unknown') {
                                               return cmId == mId;
                                             }
                                             final cmName = (cm['name'] ?? '').toString().trim().toLowerCase();
                                             if (cmName.isEmpty || nName.isEmpty || cmName != nName) return false;
                                             final cmType = (cm['type'] ?? '').toString().toLowerCase().trim();
                                             final cmDose = (cm['dose'] ?? cm['dosage'] ?? '').toString().toLowerCase().trim();
                                             if (cmType.isNotEmpty && nType.isNotEmpty && cmType != nType) return false;
                                             if (cmDose.isNotEmpty && nDose.isNotEmpty && cmDose != nDose) return false;
                                             return true;
                                           });
                                         }

                                         final existingIdx = findExistingIndex();
                                         final isAlreadyPrescribed = existingIdx != -1;
                                         final existingMed = isAlreadyPrescribed ? currentMeds[existingIdx] : null;

                                         return ElevatedButton(
                                           style: ElevatedButton.styleFrom(
                                             backgroundColor: isAlreadyPrescribed
                                                 ? SoftPalette.green400
                                                 : (isOutOfStock
                                                     ? SoftPalette.gray300
                                                     : (isLowStock ? SoftPalette.orange400 : _teal)),
                                             foregroundColor: SoftPalette.gray50,
                                             disabledBackgroundColor: SoftPalette.gray300,
                                             disabledForegroundColor: SoftPalette.gray50,
                                             padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                                             minimumSize: Size.zero,
                                             tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                                             shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
                                           ),
                                           // No stock: not selectable (a medicine already on
                                           // this prescription can still be edited/removed).
                                           onPressed: (isOutOfStock && !isAlreadyPrescribed) ? null : () async {
                                                   final res = await _showAddMedicineSubDialog(
                                                     branchId: branchId,
                                                     currentMeds: currentMeds,
                                                     daysOfMedicine: daysOfMedicine,
                                                     excludeSerial: excludeSerial,
                                                     patientCamp: patientCamp,
                                                     inventoryMed: m,
                                                     existingMed: existingMed,
                                                   );
                                                   if (res != null) {
                                                     if (res['_deleted'] == true) {
                                                       if (existingMed != null) currentMeds.remove(existingMed);
                                                     } else if (existingIdx != -1) {
                                                       currentMeds[existingIdx] = res;
                                                     } else {
                                                       onMedicineAdded(res);
                                                     }
                                                     if (dialogCtx.mounted) {
                                                       setModalState(() {});
                                                     }
                                                   }
                                                 },
                                           child: Text(
                                             isAlreadyPrescribed ? 'Added (Edit)' : (isOutOfStock ? 'Out of Stock' : 'Select'),
                                             style: TextStyle(
                                               fontSize: 11.5,
                                               fontWeight: FontWeight.bold,
                                               color: SoftPalette.gray50,
                                             ),
                                           ),
                                         );
                                       },
                                     ),
                                   ],
                                 ),
                                 onTap: (isOutOfStock && !isAlreadyPrescribed) ? null : () async {
                                         int findExistingIndex() {
                                           final mId = (m['id'] ?? m['medicineId'])?.toString().trim();
                                           final nName = (m['name'] ?? '').toString().trim().toLowerCase();
                                           final nType = (m['type'] ?? m['dosageForm'] ?? m['form'] ?? '').toString().trim().toLowerCase();
                                           final nDose = (m['dose'] ?? '').toString().trim().toLowerCase();

                                           return currentMeds.indexWhere((cm) {
                                             final cmId = (cm['inventoryId'] ?? cm['medicineId'])?.toString().trim();
                                             if (mId != null && mId.isNotEmpty && mId != 'unknown' &&
                                                 cmId != null && cmId.isNotEmpty && cmId != 'unknown') {
                                               return cmId == mId;
                                             }
                                             final cmName = (cm['name'] ?? '').toString().trim().toLowerCase();
                                             if (cmName.isEmpty || nName.isEmpty || cmName != nName) return false;
                                             final cmType = (cm['type'] ?? '').toString().toLowerCase().trim();
                                             final cmDose = (cm['dose'] ?? cm['dosage'] ?? '').toString().toLowerCase().trim();
                                             if (cmType.isNotEmpty && nType.isNotEmpty && cmType != nType) return false;
                                             if (cmDose.isNotEmpty && nDose.isNotEmpty && cmDose != nDose) return false;
                                             return true;
                                           });
                                         }

                                         final existingIdx = findExistingIndex();
                                         final existingMed = existingIdx != -1 ? currentMeds[existingIdx] : null;

                                         final res = await _showAddMedicineSubDialog(
                                           branchId: branchId,
                                           currentMeds: currentMeds,
                                           daysOfMedicine: daysOfMedicine,
                                           excludeSerial: excludeSerial,
                                           patientCamp: patientCamp,
                                           inventoryMed: m,
                                           existingMed: existingMed,
                                         );
                                         if (res != null) {
                                           if (res['_deleted'] == true) {
                                             if (existingMed != null) currentMeds.remove(existingMed);
                                           } else if (existingIdx != -1) {
                                             currentMeds[existingIdx] = res;
                                           } else {
                                             onMedicineAdded(res);
                                           }
                                           if (dialogCtx.mounted) {
                                             setModalState(() {});
                                           }
                                         }
                                       },
                              );
                            },
                          ),
                  ),

                  // Modal Footer
                  Divider(height: 1, color: isDark ? SoftPalette.slate700 : SoftPalette.gray100),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                    child: Row(
                      children: [
                        OutlinedButton(
                          onPressed: () async {
                            final newMed = await _showAddMedicineSubDialog(
                              branchId: branchId,
                              currentMeds: currentMeds,
                              daysOfMedicine: daysOfMedicine,
                              excludeSerial: excludeSerial,
                              patientCamp: patientCamp,
                              inventoryMed: null,
                            );
                            if (newMed != null) {
                              onMedicineAdded(newMed);
                              if (dialogCtx.mounted) {
                                setModalState(() {});
                              }
                            }
                          },
                          style: OutlinedButton.styleFrom(
                            backgroundColor: isDark
                                ? SoftPalette.teal400.withValues(alpha: 0.10)
                                : _teal.withValues(alpha: 0.06),
                            foregroundColor: isDark ? SoftPalette.teal300 : _teal,
                            side: BorderSide(
                              color: (isDark ? SoftPalette.teal400 : _teal).withValues(alpha: 0.35),
                              width: 1.2,
                            ),
                            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(12),
                            ),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Container(
                                padding: const EdgeInsets.all(2),
                                decoration: BoxDecoration(
                                  color: (isDark ? SoftPalette.teal300 : _teal).withValues(alpha: 0.16),
                                  shape: BoxShape.circle,
                                ),
                                child: Icon(
                                  Icons.add_rounded,
                                  size: 15,
                                  color: isDark ? SoftPalette.teal300 : _teal,
                                ),
                              ),
                              const SizedBox(width: 8),
                              Text(
                                'Add Custom Medicine',
                                style: TextStyle(
                                  fontSize: 13,
                                  fontWeight: FontWeight.w600,
                                  letterSpacing: 0.1,
                                  color: isDark ? SoftPalette.teal300 : _teal,
                                ),
                              ),
                            ],
                          ),
                        ),
                        const Spacer(),
                        ElevatedButton(
                          onPressed: () => Navigator.pop(dialogCtx),
                          style: ElevatedButton.styleFrom(
                            elevation: currentMeds.isNotEmpty ? 2 : 0,
                            shadowColor: _teal.withValues(alpha: 0.35),
                            backgroundColor: currentMeds.isNotEmpty
                                ? _teal
                                : (isDark ? SoftPalette.slate700 : SoftPalette.gray200),
                            foregroundColor: currentMeds.isNotEmpty
                                ? SoftPalette.gray50
                                : (isDark ? SoftPalette.gray300 : SoftPalette.gray700),
                            padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(12),
                            ),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(
                                currentMeds.isNotEmpty
                                    ? Icons.check_circle_rounded
                                    : Icons.close_rounded,
                                size: 17,
                                color: currentMeds.isNotEmpty
                                    ? SoftPalette.gray50
                                    : (isDark ? SoftPalette.gray300 : SoftPalette.gray700),
                              ),
                              const SizedBox(width: 8),
                              Text(
                                currentMeds.isNotEmpty ? 'Done' : 'Close',
                                style: TextStyle(
                                  fontSize: 13,
                                  fontWeight: FontWeight.bold,
                                  letterSpacing: 0.2,
                                  color: currentMeds.isNotEmpty
                                      ? SoftPalette.gray50
                                      : (isDark ? SoftPalette.gray300 : SoftPalette.gray700),
                                ),
                              ),
                              if (currentMeds.isNotEmpty) ...[
                                const SizedBox(width: 8),
                                Container(
                                  padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                                  decoration: BoxDecoration(
                                    color: SoftPalette.gray50.withValues(alpha: 0.24),
                                    borderRadius: BorderRadius.circular(10),
                                    border: Border.all(
                                      color: SoftPalette.gray50.withValues(alpha: 0.35),
                                      width: 0.8,
                                    ),
                                  ),
                                  child: Text(
                                    '${currentMeds.length}',
                                    style: const TextStyle(
                                      color: SoftPalette.gray50,
                                      fontSize: 11.5,
                                      fontWeight: FontWeight.w800,
                                    ),
                                  ),
                                ),
                              ],
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
    );
  }

  // ─── Prescription edit dialog ──────────────────────────────────────────────
  Future<void> _showPrescriptionDialog(Map<String, dynamic> patient) async {
    final serial   = (patient['serial'] ?? patient['id'] ?? '').toString().trim();
    final branchId = widget.branchId;

    final patientCnic = (patient['patientCnic'] ?? patient['cnic'] ?? '').toString().trim();
    final patientName = (patient['patientName'] ?? patient['name'] ?? '').toString().trim();

    if (serial.isEmpty) {
      AppToast.showSnackBar(context, const SnackBar(content: Text('Invalid serial number')));
      return;
    }

    Map<String, dynamic> prescData = {};
    Map<String, dynamic> entryData = {};
    Map<String, dynamic> fallbackPresc = {};

    bool hasMedicines(Map m) {
      final meds = m['prescriptions'] ?? m['medicines'] ?? m['items'];
      return meds is List && meds.isNotEmpty;
    }

    // 1. Check if patient map already has prescription with actual medicines
    if (patient['prescription'] is Map && (patient['prescription'] as Map).isNotEmpty) {
      final pMap = Map<String, dynamic>.from(patient['prescription'] as Map);
      if (hasMedicines(pMap)) {
        prescData = pMap;
      } else {
        fallbackPresc = pMap;
      }
    }

    // 2. Check entriesBox directly
    if (prescData.isEmpty) {
      final entryBox = await LocalStorageService.ensureBoxOpen(LocalStorageService.entriesBox);
      final normBranch = branchId.toLowerCase().trim();
      final normSerial = serial.toLowerCase().trim();
      dynamic entryRaw = entryBox.get('$branchId-$serial') ??
          entryBox.get('$normBranch-$normSerial') ??
          entryBox.get('${branchId.toUpperCase()}-${serial.toUpperCase()}') ??
          entryBox.get(serial) ??
          entryBox.get(serial.toUpperCase());

      if (entryRaw == null) {
        for (final k in entryBox.keys) {
          final ks = k.toString().toLowerCase().trim();
          if (ks == '$normBranch-$normSerial' || ks == normSerial) {
            entryRaw = entryBox.get(k);
            break;
          }
        }
      }

      if (entryRaw != null) {
        entryData = Map<String, dynamic>.from(entryRaw);
        final rawEmb = entryData['prescription'];
        final embeddedPresc = (rawEmb is Map) ? Map<String, dynamic>.from(rawEmb) : null;
        if (embeddedPresc != null && embeddedPresc.isNotEmpty) {
          if (hasMedicines(embeddedPresc)) {
            prescData = Map<String, dynamic>.from(embeddedPresc);
            debugPrint('[PrescEdit] Loaded from embedded entry prescription: $serial');
          } else if (fallbackPresc.isEmpty) {
            fallbackPresc = Map<String, dynamic>.from(embeddedPresc);
          }
        }
      }
    }

    // 3. Check getLocalPrescription with patient credentials & direct prescriptionsBox lookup
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
      } else if (Hive.isBoxOpen(LocalStorageService.prescriptionsBox)) {
        final pBox = Hive.box(LocalStorageService.prescriptionsBox);
        final rawDirect = pBox.get(serial) ??
            pBox.get(serial.toLowerCase()) ??
            pBox.get(serial.toUpperCase()) ??
            pBox.get('${branchId.toLowerCase()}-$serial') ??
            pBox.get('${branchId.toLowerCase()}-${serial.toLowerCase()}');
        if (rawDirect is Map && rawDirect.isNotEmpty) {
          prescData = Map<String, dynamic>.from(rawDirect);
          debugPrint('[PrescEdit] Loaded directly from prescriptionsBox: $serial');
        }
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

    if (prescData.isEmpty && fallbackPresc.isNotEmpty) {
      prescData = fallbackPresc;
    }

    if (prescData.isEmpty) {
      prescData = {
        'serial': serial,
        'patientCnic': patientCnic,
        'patientName': patientName,
        'prescriptions': <Map<String, dynamic>>[],
        'labResults': <Map<String, dynamic>>[],
        'condition': entryData['condition'] ?? '',
        'complaint': entryData['complaint'] ?? entryData['condition'] ?? '',
        'diagnosis': entryData['diagnosis'] ?? '',
        'daysOfMedicine': entryData['daysOfMedicine'] ?? 1,
      };
    }

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
      final dRaw = prescData['daysOfMedicine'] ??
          entryData['daysOfMedicine'] ??
          (entryData['prescription'] is Map
              ? entryData['prescription']['daysOfMedicine']
              : null);
      final d = (dRaw is num ? dRaw.toInt() : int.tryParse(dRaw?.toString() ?? ''));
      if (d != null && d >= 1 && d <= 3) return d;
      final sRaw = entryData['suggestedDays'] ?? patient['suggestedDays'];
      final suggested = (sRaw is num ? sRaw.toInt() : int.tryParse(sRaw?.toString() ?? ''));
      if (suggested != null && suggested >= 1 && suggested <= 3) return suggested;
      return 1;
    })();

    final complaintCtrl = TextEditingController(
        text: prescData['condition'] ?? prescData['complaint'] ?? entryData['condition'] ?? entryData['complaint'] ?? '');
    final diagnosisCtrl = TextEditingController(
        text: prescData['diagnosis'] ?? entryData['diagnosis'] ?? '');

    final rawMeds = prescData['prescriptions'] ??
        prescData['medicines'] ??
        prescData['items'] ??
        entryData['prescriptions'] ??
        entryData['medicines'] ??
        entryData['items'] ??
        patient['prescriptions'] ??
        patient['medicines'] ??
        patient['items'];
    List<Map<String, dynamic>> currentMeds = List<Map<String, dynamic>>.from(
        (rawMeds as List<dynamic>?)
            ?.map((e) => Map<String, dynamic>.from(e as Map))
            .toList() ?? []);
    final rawLabs = prescData['labResults'] ??
        prescData['labTests'] ??
        prescData['tests'] ??
        entryData['labResults'] ??
        patient['labResults'];
    List<Map<String, dynamic>> currentLabs = List<Map<String, dynamic>>.from(
        (rawLabs as List<dynamic>?)
            ?.map((e) => Map<String, dynamic>.from(e as Map))
            .toList() ?? []);

    String? patientCamp = (patient['dispensaryId'] ?? patient['campId'] ?? patient['dispensaryTag'])?.toString().trim();
    if (patientCamp == null || patientCamp.isEmpty || patientCamp == 'all') {
      final s = serial.toUpperCase();
      if (s.contains('-SADD-') || s.contains('-SADDAR-') || s.contains('-SAD-') || s.contains('-KAP-')) patientCamp = 'saddar';
      else if (s.contains('-HAJI-') || s.contains('-HC-')) patientCamp = 'haji_camp';
    }

    const quickTests = [
      'CBC', 'LFT', 'RFT', 'HbA1C', 'BMP', 'Urine R/E', 'Lipid Profile',
      'ECG', 'X-ray', 'Ultrasound Abdomen',
    ];

    await showDialog(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) {
          final isDark = Theme.of(context).brightness == Brightness.dark;
          final brand = Theme.of(context).colorScheme.primary;
          final muted = isDark ? SoftPalette.slate400 : SoftPalette.slate550;
          final borderColor = isDark ? SoftPalette.slate700 : SoftPalette.slate200;

          return AlertDialog(
            backgroundColor: Theme.of(context).cardColor,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(14),
              side: BorderSide(color: borderColor),
            ),
            titlePadding: const EdgeInsets.fromLTRB(20, 16, 16, 12),
            title: Row(children: [
              Container(
                width: 30,
                height: 30,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: brand.withValues(alpha: isDark ? 0.24 : 0.1),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Icon(Icons.assignment_outlined, color: brand, size: 17),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  'Edit Prescription – $resolvedName ($serial)',
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w800,
                    color: isDark ? SoftPalette.gray50 : SoftPalette.slate900,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              IconButton(
                icon: Icon(Icons.close_rounded, color: muted, size: 20),
                onPressed: () => Navigator.pop(dialogContext),
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(),
              ),
            ]),
            content: SizedBox(
              width: 760,
              child: SingleChildScrollView(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // ── Side-by-side Condition & Diagnosis ──────────────────
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text('Patient condition',
                                  style: TextStyle(
                                      fontSize: 11.5,
                                      fontWeight: FontWeight.w500,
                                      color: isDark ? SoftPalette.slate350 : SoftPalette.slate600)),
                              const SizedBox(height: 5),
                              TextField(
                                controller: complaintCtrl,
                                minLines: 2,
                                maxLines: 4,
                                keyboardType: TextInputType.multiline,
                                style: TextStyle(
                                  fontSize: 13,
                                  color: isDark ? SoftPalette.gray50 : SoftPalette.slate900,
                                ),
                                decoration: InputDecoration(
                                  hintText: "Describe patient's condition...",
                                  hintStyle: TextStyle(fontSize: 12.5, color: muted),
                                  filled: true,
                                  fillColor: isDark ? SoftPalette.slate900.withValues(alpha: 0.7) : SoftPalette.slate50,
                                  border: OutlineInputBorder(
                                    borderRadius: BorderRadius.circular(9),
                                    borderSide: BorderSide(color: borderColor),
                                  ),
                                  enabledBorder: OutlineInputBorder(
                                    borderRadius: BorderRadius.circular(9),
                                    borderSide: BorderSide(color: borderColor),
                                  ),
                                  focusedBorder: OutlineInputBorder(
                                    borderRadius: BorderRadius.circular(9),
                                    borderSide: BorderSide(color: brand, width: 1.5),
                                  ),
                                  contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                                  isDense: true,
                                ),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text('Diagnosis',
                                  style: TextStyle(
                                      fontSize: 11.5,
                                      fontWeight: FontWeight.w500,
                                      color: isDark ? SoftPalette.slate350 : SoftPalette.slate600)),
                              const SizedBox(height: 5),
                              TextField(
                                controller: diagnosisCtrl,
                                minLines: 2,
                                maxLines: 4,
                                keyboardType: TextInputType.multiline,
                                style: TextStyle(
                                  fontSize: 13,
                                  color: isDark ? SoftPalette.gray50 : SoftPalette.slate900,
                                ),
                                decoration: InputDecoration(
                                  hintText: 'Enter diagnosis...',
                                  hintStyle: TextStyle(fontSize: 12.5, color: muted),
                                  filled: true,
                                  fillColor: isDark ? SoftPalette.slate900.withValues(alpha: 0.7) : SoftPalette.slate50,
                                  border: OutlineInputBorder(
                                    borderRadius: BorderRadius.circular(9),
                                    borderSide: BorderSide(color: borderColor),
                                  ),
                                  enabledBorder: OutlineInputBorder(
                                    borderRadius: BorderRadius.circular(9),
                                    borderSide: BorderSide(color: borderColor),
                                  ),
                                  focusedBorder: OutlineInputBorder(
                                    borderRadius: BorderRadius.circular(9),
                                    borderSide: BorderSide(color: brand, width: 1.5),
                                  ),
                                  contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                                  isDense: true,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 14),

                    // ── Days selector ───────────────────────────────────────
                    _buildDaysSelectorDialog(
                      selectedDays:  editDays,
                      queueType:     queueType,
                      hasInjection:  currentMeds.any(_isInjectionOrDrip),
                      suggestedDays: (patient['suggestedDays'] as int?) ?? (entryData['suggestedDays'] as int?),
                      onChanged:     (d) => setDialogState(() => editDays = d),
                    ),
                    const SizedBox(height: 16),

                    // ── Medicines Header ────────────────────────────────────
                    Row(
                      children: [
                        Text(
                          'MEDICINES',
                          style: TextStyle(
                            fontSize: 10.5,
                            fontWeight: FontWeight.w700,
                            letterSpacing: 0.7,
                            color: muted,
                          ),
                        ),
                        const Spacer(),
                        Text(
                          'Stock is checked when the pharmacy dispenses',
                          style: TextStyle(fontSize: 10.5, color: muted),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),

                    // ── Search + Browse + Custom Row ────────────────────────
                    Row(
                      children: [
                        Expanded(
                          child: InkWell(
                            onTap: () => _showMedicineSelectionModal(
                              parentContext: dialogContext,
                              branchId: branchId,
                              patientCamp: patientCamp,
                              daysOfMedicine: editDays,
                              currentMeds: currentMeds,
                              excludeSerial: serial,
                              onMedicineAdded: (med) {
                                setDialogState(() {
                                  currentMeds.add(med);
                                  final isInj = _isInjectionOrDrip(med);
                                  if (isInj && editDays > 1) editDays = 1;
                                });
                              },
                            ),
                            borderRadius: BorderRadius.circular(9),
                            child: Container(
                              height: 38,
                              padding: const EdgeInsets.symmetric(horizontal: 11),
                              decoration: BoxDecoration(
                                color: isDark ? SoftPalette.slate900.withValues(alpha: 0.7) : SoftPalette.slate50,
                                borderRadius: BorderRadius.circular(9),
                                border: Border.all(color: borderColor),
                              ),
                              child: Row(
                                children: [
                                  Icon(Icons.search_rounded, size: 16, color: muted),
                                  const SizedBox(width: 8),
                                  Expanded(
                                    child: Text(
                                      'Search medicine',
                                      style: TextStyle(fontSize: 12.5, color: muted),
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        InkWell(
                          onTap: () => _showMedicineSelectionModal(
                            parentContext: dialogContext,
                            branchId: branchId,
                            patientCamp: patientCamp,
                            daysOfMedicine: editDays,
                            currentMeds: currentMeds,
                            excludeSerial: serial,
                            onMedicineAdded: (med) {
                              setDialogState(() {
                                currentMeds.add(med);
                                final isInj = _isInjectionOrDrip(med);
                                if (isInj && editDays > 1) editDays = 1;
                              });
                            },
                          ),
                          borderRadius: BorderRadius.circular(9),
                          child: Container(
                            height: 38,
                            padding: const EdgeInsets.symmetric(horizontal: 12),
                            decoration: BoxDecoration(
                              color: isDark ? SoftPalette.slate900.withValues(alpha: 0.7) : SoftPalette.slate50,
                              borderRadius: BorderRadius.circular(9),
                              border: Border.all(color: borderColor),
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(Icons.grid_view_rounded, size: 14, color: isDark ? SoftPalette.gray50 : SoftPalette.slate800),
                                const SizedBox(width: 6),
                                Text('Browse', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: isDark ? SoftPalette.gray50 : SoftPalette.slate800)),
                              ],
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        InkWell(
                          onTap: () async {
                            final newMed = await _showAddMedicineSubDialog(
                              branchId: branchId,
                              currentMeds: currentMeds,
                              daysOfMedicine: editDays,
                              excludeSerial: serial,
                              patientCamp: patientCamp,
                              inventoryMed: null,
                            );
                            if (newMed != null) {
                              setDialogState(() {
                                currentMeds.add(newMed);
                                final isInj = _isInjectionOrDrip(newMed);
                                if (isInj && editDays > 1) editDays = 1;
                              });
                            }
                          },
                          borderRadius: BorderRadius.circular(9),
                          child: Container(
                            height: 38,
                            padding: const EdgeInsets.symmetric(horizontal: 12),
                            decoration: BoxDecoration(
                              color: isDark ? SoftPalette.slate900.withValues(alpha: 0.7) : SoftPalette.slate50,
                              borderRadius: BorderRadius.circular(9),
                              border: Border.all(color: borderColor),
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(Icons.add_rounded, size: 15, color: isDark ? SoftPalette.gray50 : SoftPalette.slate800),
                                const SizedBox(width: 4),
                                Text('Custom', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: isDark ? SoftPalette.gray50 : SoftPalette.slate800)),
                              ],
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 10),

                    // ── Added Medicines List ────────────────────────────────
                    if (currentMeds.isEmpty)
                      Container(
                        width: double.infinity,
                        padding: const EdgeInsets.symmetric(vertical: 18, horizontal: 12),
                        decoration: BoxDecoration(
                          color: isDark ? SoftPalette.slate900.withValues(alpha: 0.45) : SoftPalette.slate50,
                          border: Border.all(color: borderColor),
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: Text(
                          'No medicines added yet. Use Search, Browse, or + Custom above.',
                          style: TextStyle(fontSize: 12, color: muted),
                          textAlign: TextAlign.center,
                        ),
                      )
                    else
                      Column(
                        children: currentMeds.map((med) {
                          final namePart = (med['name'] ?? '').toString().trim();
                          final dosePart = (med['dose'] ?? '').toString().trim();
                          final qty = med['quantity'] ?? 1;
                          final isInj = _isInjectionOrDrip(med);
                          final timing = (med['timing'] ?? '').toString().trim();
                          final meal = (med['meal'] ?? med['instructions'] ?? '').toString().trim();

                          return Column(
                            children: [
                              InkWell(
                                borderRadius: BorderRadius.circular(8),
                                onTap: () async {
                                  final res = await _showAddMedicineSubDialog(
                                    branchId: branchId,
                                    currentMeds: currentMeds,
                                    daysOfMedicine: editDays,
                                    excludeSerial: serial,
                                    patientCamp: patientCamp,
                                    existingMed: med,
                                  );
                                  if (res != null) {
                                    setDialogState(() {
                                      if (res['_deleted'] == true) {
                                        currentMeds.remove(med);
                                      } else {
                                        final idx = currentMeds.indexOf(med);
                                        if (idx != -1) currentMeds[idx] = res;
                                      }
                                    });
                                  }
                                },
                                child: Padding(
                                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 8),
                                  child: Row(
                                    children: [
                                      Container(
                                        width: 24,
                                        height: 24,
                                        alignment: Alignment.center,
                                        decoration: BoxDecoration(
                                          color: isInj
                                              ? SoftPalette.amber500.withValues(alpha: 0.2)
                                              : brand.withValues(alpha: isDark ? 0.25 : 0.12),
                                          borderRadius: BorderRadius.circular(6),
                                        ),
                                        child: Icon(
                                          isInj ? Icons.vaccines_rounded : Icons.medication_rounded,
                                          size: 13,
                                          color: isInj ? SoftPalette.amber400 : brand,
                                        ),
                                      ),
                                      const SizedBox(width: 10),
                                      Expanded(
                                        child: Column(
                                          crossAxisAlignment: CrossAxisAlignment.start,
                                          children: [
                                            Text(
                                              dosePart.isNotEmpty ? '$namePart $dosePart' : namePart,
                                              style: TextStyle(
                                                fontSize: 12.5,
                                                fontWeight: FontWeight.w700,
                                                color: isDark ? SoftPalette.gray50 : SoftPalette.slate900,
                                              ),
                                              maxLines: 1,
                                              overflow: TextOverflow.ellipsis,
                                            ),
                                            if (timing.isNotEmpty || meal.isNotEmpty)
                                              Text(
                                                [if (timing.isNotEmpty) timing, if (meal.isNotEmpty) meal].join(' · '),
                                                style: TextStyle(fontSize: 11, color: muted),
                                              ),
                                          ],
                                        ),
                                      ),
                                      const SizedBox(width: 8),
                                      Text(
                                        '×$qty',
                                        style: TextStyle(
                                          fontSize: 12.5,
                                          fontWeight: FontWeight.w700,
                                          color: isDark ? SoftPalette.gray50 : SoftPalette.slate900,
                                        ),
                                      ),
                                      const SizedBox(width: 8),
                                      InkWell(
                                        onTap: () => setDialogState(() => currentMeds.remove(med)),
                                        child: Icon(Icons.close_rounded, size: 15, color: muted),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                              Divider(height: 1, color: borderColor.withValues(alpha: 0.6)),
                            ],
                          );
                        }).toList(),
                      ),
                    const SizedBox(height: 16),

                    // ── Lab Tests Header ────────────────────────────────────
                    Row(
                      children: [
                        Text(
                          'LAB TESTS',
                          style: TextStyle(
                            fontSize: 10.5,
                            fontWeight: FontWeight.w700,
                            letterSpacing: 0.7,
                            color: muted,
                          ),
                        ),
                        const Spacer(),
                        InkWell(
                          borderRadius: BorderRadius.circular(8),
                          onTap: () async {
                            final testNameCtrl = TextEditingController();
                            final customName = await showDialog<String>(
                              context: dialogContext,
                              builder: (tCtx) => AlertDialog(
                                title: const Text('Add Custom Lab Test'),
                                content: TextField(
                                  controller: testNameCtrl,
                                  autofocus: true,
                                  decoration: InputDecoration(
                                    labelText: 'Test Name',
                                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
                                  ),
                                ),
                                actions: [
                                  TextButton(onPressed: () => Navigator.pop(tCtx), child: const Text('Cancel')),
                                  ElevatedButton(
                                    style: ElevatedButton.styleFrom(backgroundColor: brand, foregroundColor: SoftPalette.gray50),
                                    onPressed: () => Navigator.pop(tCtx, testNameCtrl.text.trim()),
                                    child: const Text('Add'),
                                  ),
                                ],
                              ),
                            );
                            if (customName != null && customName.isNotEmpty) {
                              setDialogState(() {
                                if (!currentLabs.any((l) => (l['name'] ?? '').toString().trim().toLowerCase() == customName.toLowerCase())) {
                                  currentLabs.add({'name': customName});
                                }
                              });
                            }
                          },
                          child: Container(
                            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                            decoration: BoxDecoration(
                              color: isDark ? SoftPalette.slate900.withValues(alpha: 0.7) : SoftPalette.slate50,
                              borderRadius: BorderRadius.circular(8),
                              border: Border.all(color: borderColor),
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(Icons.add_rounded, size: 14, color: isDark ? SoftPalette.gray50 : SoftPalette.slate800),
                                const SizedBox(width: 4),
                                Text('Custom', style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.w600, color: isDark ? SoftPalette.gray50 : SoftPalette.slate800)),
                              ],
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),

                    // ── Preset Quick Lab Test Pills ─────────────────────────
                    Wrap(
                      spacing: 7,
                      runSpacing: 7,
                      children: quickTests.map((t) {
                        final selected = currentLabs.any((l) => (l['name'] ?? '').toString().trim().toLowerCase() == t.toLowerCase());
                        return InkWell(
                          borderRadius: BorderRadius.circular(8),
                          onTap: () {
                            setDialogState(() {
                              if (selected) {
                                currentLabs.removeWhere((l) => (l['name'] ?? '').toString().trim().toLowerCase() == t.toLowerCase());
                              } else {
                                currentLabs.add({'name': t});
                              }
                            });
                          },
                          child: AnimatedContainer(
                            duration: const Duration(milliseconds: 150),
                            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                            decoration: BoxDecoration(
                              color: selected
                                  ? (isDark ? brand.withValues(alpha: 0.35) : brand)
                                  : (isDark ? SoftPalette.slate900.withValues(alpha: 0.65) : SoftPalette.slate50),
                              borderRadius: BorderRadius.circular(8),
                              border: Border.all(color: selected ? brand : borderColor),
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                if (selected) ...[
                                  const Icon(Icons.check_rounded, size: 13, color: SoftPalette.gray50),
                                  const SizedBox(width: 4),
                                ],
                                Text(
                                  t,
                                  style: TextStyle(
                                    fontSize: 11.5,
                                    fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
                                    color: selected
                                        ? SoftPalette.gray50
                                        : (isDark ? SoftPalette.slate200 : SoftPalette.slate800),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        );
                      }).toList(),
                    ),

                    // ── Custom Lab Tests Pills ──────────────────────────────
                    if (currentLabs.any((l) => !quickTests.any((q) => q.toLowerCase() == (l['name'] ?? '').toString().trim().toLowerCase()))) ...[
                      const SizedBox(height: 10),
                      Wrap(
                        spacing: 7,
                        runSpacing: 7,
                        children: currentLabs
                            .where((l) => !quickTests.any((q) => q.toLowerCase() == (l['name'] ?? '').toString().trim().toLowerCase()))
                            .map((l) => Container(
                                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                                  decoration: BoxDecoration(
                                    color: isDark ? SoftPalette.amber800.withValues(alpha: 0.4) : SoftPalette.amber100,
                                    borderRadius: BorderRadius.circular(8),
                                    border: Border.all(
                                      color: isDark ? SoftPalette.amber400.withValues(alpha: 0.45) : SoftPalette.amber300,
                                    ),
                                  ),
                                  child: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Text(
                                        (l['name'] ?? '').toString(),
                                        style: TextStyle(
                                          fontSize: 11.5,
                                          fontWeight: FontWeight.w600,
                                          color: isDark ? SoftPalette.amber200 : SoftPalette.amber500,
                                        ),
                                      ),
                                      const SizedBox(width: 6),
                                      InkWell(
                                        onTap: () => setDialogState(() => currentLabs.remove(l)),
                                        child: Icon(
                                          Icons.close_rounded,
                                          size: 13,
                                          color: isDark ? SoftPalette.amber300 : SoftPalette.amber500,
                                        ),
                                      ),
                                    ],
                                  ),
                                ))
                            .toList(),
                      ),
                    ],

                    const SizedBox(height: 14),

                    // ── Source indicator ────────────────────────────────────
                    if (prescData.isNotEmpty && entryData.isEmpty)
                      Text('Source: local prescriptions',
                          style: TextStyle(fontSize: 11, color: context.adapt(SoftPalette.gray350)))
                    else if (entryData.isNotEmpty)
                      Text('Source: local entry cache',
                          style: TextStyle(fontSize: 11, color: context.adapt(SoftPalette.gray350)))
                    else
                      Text('Source: Firestore (cloud)',
                          style: TextStyle(fontSize: 11, color: context.adapt(SoftPalette.orange350))),
                  ],
                ),
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dialogContext),
                child: const Text('Cancel'),
              ),
              ElevatedButton.icon(
                style: ElevatedButton.styleFrom(
                  backgroundColor: _teal,
                  foregroundColor: SoftPalette.gray50,
                  disabledBackgroundColor: _teal.withValues(alpha: 0.6),
                  disabledForegroundColor: SoftPalette.gray50A70,
                ),
                icon: const Icon(Icons.save, color: SoftPalette.gray50),
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
      // StockReader only reads boxes that are already open.
      await LocalStorageService.ensureBoxOpen(LocalStorageService.prescriptionsBox);
      await LocalStorageService.ensureBoxOpen(LocalStorageService.entriesBox);
      final pool = _stockPoolFor(branchId, patientCamp);
      // Available = this pool's shelf minus other patients' reservations (this token's own
      // saved prescription excluded, since it is being replaced).
      final groups = pool == null
          ? const <StockGroup>[]
          : StockReader.groups(pool, excludeSerial: serial);

      // Lines of the same medicine are added together, in shelf units.
      final neededByGroup = <String, double>{};
      final groupByKey = <String, StockGroup>{};
      final nameByKey = <String, String>{};
      for (final med in medicines) {
        final inventoryId = (med['inventoryId'] ?? '').toString().trim();
        if (inventoryId.isEmpty || inventoryId == 'null') continue;
        // Custom / external lines are not taken from stock.
        if (med['isExternal'] == true || med['outOfStock'] == true) continue;
        final g = pool == null ? null : StockReader.groupForLine(pool, med, within: groups);
        if (g == null) {
          if (mounted) {
            AppToast.showSnackBar(context, SnackBar(
              content: Text('⚠️ "${med['name']}" is not in this dispensary\'s stock. Remove it or add it as a custom medicine.'),
              backgroundColor: SoftPalette.red400,
              duration: const Duration(seconds: 4),
            ));
          }
          return;
        }
        neededByGroup[g.key] = (neededByGroup[g.key] ?? 0) + StockMath.lineUnits(med, daysOfMedicine);
        groupByKey[g.key] = g;
        nameByKey[g.key] = (med['name'] ?? '').toString();
      }

      for (final e in neededByGroup.entries) {
        final g = groupByKey[e.key]!;
        if (e.value > g.available + 1e-9) {
          final required = e.value.ceil();
          final availableClamped = g.available.floor();
          if (mounted) {
            AppToast.showSnackBar(context, SnackBar(
              content: Text(
                '⚠️ "${nameByKey[e.key]}" stock insufficient! '
                'Need $required but only $availableClamped available after reservations.',
              ),
              backgroundColor: SoftPalette.red400,
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
      'id':              serial,
      'serial':          serial,
      'branchId':        branchId,
      if (patientCnic.trim().isNotEmpty) 'patientCnic': patientCnic.trim(),
      if (patientCnic.trim().isNotEmpty) 'cnic': patientCnic.trim(),
      'queueType':       queueType,
      'condition':       complaint,
      'complaint':       complaint,
      'diagnosis':       diagnosis,
      'prescriptions':   medicines,
      'medicines':       medicines,
      'labResults':      labTests,
      'daysOfMedicine':  daysOfMedicine,
      'extraCharge':     extraCharge,
      'updatedAt':       now,
      'updatedBy':       RealtimeManager().role ?? 'Doctor',
    };

    // 1. Hive prescriptions box
    await LocalStorageService.saveLocalPrescription(updatedPresc);
    debugPrint('[PrescEdit] ✅ Saved to local prescriptions box: $serial');

    // 2. Hive entries box — update all matching case variants and canonical key
    final entryBox = await LocalStorageService.ensureBoxOpen(LocalStorageService.entriesBox);
    final normBranch = branchId.toLowerCase().trim();
    final normSerial = serial.toLowerCase().trim();
    final canonicalKey = '$normBranch-${serial.trim().toUpperCase()}';
    final keysToUpdate = <dynamic>{};

    for (final k in entryBox.keys) {
      final ks = k.toString().toLowerCase().trim();
      if (ks == '$normBranch-$normSerial' || ks == normSerial) {
        keysToUpdate.add(k);
      }
    }
    if (keysToUpdate.isEmpty) {
      keysToUpdate.add(canonicalKey);
    }

    for (final k in keysToUpdate) {
      final existing = entryBox.get(k) ?? entryBox.get(canonicalKey);
      if (existing is! Map) continue;
      final updated = Map<String, dynamic>.from(existing);
      updated['prescription']   = updatedPresc;
      updated['prescriptionId'] = serial;
      updated['prescriptions']  = medicines;
      updated['medicines']      = medicines;
      updated['status']         = 'completed';
      updated['completedAt']    = updatedPresc['completedAt'] ?? now;
      updated['daysOfMedicine'] = daysOfMedicine;
      updated['extraCharge']    = extraCharge;
      await entryBox.put(k, updated);
      debugPrint('[PrescEdit] ✅ Updated entry in Hive: $k');
    }

    // 3. LAN broadcast
    RealtimeManager().sendMessage(RealtimeEvents.payload(
      type:     RealtimeEvents.savePrescription,
      branchId: branchId,
      data:     updatedPresc,
    ));
    debugPrint('[PrescEdit] ✅ Broadcasted save_prescription (days=$daysOfMedicine)');

    // 4. Firestore fire-and-forget or enqueue to sync if not a LAN client desk
    if (!LanFirestoreGate.isLanDesk) {
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
      } else {
        await LocalStorageService.enqueueSync({
          'type': 'save_prescription',
          'branchId': branchId,
          'serial': serial,
          'data': updatedPresc,
        });
        debugPrint('[PrescEdit] 📡 Enqueued offline prescription update to sync: $serial');
      }
    }

    if (mounted) {
      final daysTxt   = daysOfMedicine > 1 ? ' ($daysOfMedicine days)' : '';
      final chargeTxt = extraCharge > 0 ? ' | Extra: PKR $extraCharge' : '';
      AppToast.showSnackBar(context, SnackBar(
        content: Row(children: [
          const Icon(Icons.check_circle, color: SoftPalette.gray50),
          const SizedBox(width: 8),
          Text('Prescription updated$daysTxt$chargeTxt'),
        ]),
        backgroundColor: SoftPalette.green400,
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
      final db        = CloudDb.instance;
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
      debugPrint('[PrescEdit] ❌ Firestore update failed, enqueueing for sync: $e');
      await LocalStorageService.enqueueSync({
        'type': 'save_prescription',
        'branchId': branchId,
        'serial': serial,
        'data': updatedPresc,
      });
    }
  }

  // ─── Build ─────────────────────────────────────────────────────────────────
  @override
  Widget build(BuildContext context) {
    if (Hive.isBoxOpen(LocalStorageService.entriesBox)) {
      final box = Hive.box(LocalStorageService.entriesBox);
      if (box.isOpen) {
        // Visible-only rebuilds: on the Hybrid desk this queue stays alive in a hidden tab and
        // rebuilt on every token save. Hidden, it keeps its last build and rebuilds once when
        // shown (the next-patient auto-select then runs as the doctor tab opens, not while the
        // desk is on another tab). On screen it behaves exactly as before.
        return VisibleListenableBuilder(
          listenable: DebouncedBoxListenable.shared(box),
          builder: (context) => _buildQueueContent(context),
        );
      }
    }
    return FutureBuilder<Box>(
      future: LocalStorageService.ensureBoxOpen(LocalStorageService.entriesBox),
      builder: (context, snapshot) {
        if (snapshot.hasData && snapshot.data != null && snapshot.data!.isOpen) {
          return VisibleListenableBuilder(
            listenable: DebouncedBoxListenable.shared(snapshot.data!),
            builder: (context) => _buildQueueContent(context),
          );
        }
        return Center(
          child: Padding(
            padding: EdgeInsets.all(24),
            child: CircularProgressIndicator(color: context.adapt(SoftPalette.teal600)),
          ),
        );
      },
    );
  }

  bool _isPatientDispensed(Map<String, dynamic> p) {
    final status = (p['status'] ?? '').toString().toLowerCase();
    final dispenseStatus = (p['dispenseStatus'] ?? '').toString().toLowerCase();
    if (dispenseStatus == 'dispensed' || status == 'dispensed' || p['dispensedAt'] != null) {
      return true;
    }
    final serial = (p['serial'] ?? p['id'] ?? '').toString().trim();
    if (serial.isNotEmpty && Hive.isBoxOpen(LocalStorageService.dispensaryBox)) {
      final dBox = Hive.box(LocalStorageService.dispensaryBox);
      final dKey = (p['dateKey'] ?? _todayKey).toString();
      final rec = dBox.get('${widget.branchId}_${dKey}_$serial') ??
          dBox.get('${widget.branchId}-$serial') ??
          dBox.get(serial);
      if (rec is Map && ((rec['dispenseStatus'] ?? rec['status']) == 'dispensed' || rec['status'] == 'completed')) {
        return true;
      }
    }
    return false;
  }

  Widget _buildDispensedSectionHeader(BuildContext context, int count) {
    final c = context.comfort;
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 10, 4, 6),
      child: Row(
        children: [
          Expanded(child: Container(height: 1, color: c.border)),
          Container(
            margin: const EdgeInsets.symmetric(horizontal: 8),
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
            decoration: BoxDecoration(
              color: c.successBg,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: c.success.withValues(alpha: 0.3)),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.check_circle_outline_rounded, size: 11, color: c.success),
                const SizedBox(width: 4),
                Text(
                  'DISPENSED ($count)',
                  style: TextStyle(
                    fontSize: 9.5,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 0.6,
                    color: c.success,
                  ),
                ),
              ],
            ),
          ),
          Expanded(child: Container(height: 1, color: c.border)),
        ],
      ),
    );
  }

  Widget _buildQueueContent(BuildContext context) {
    try {
      final now = DateTime.now();
      final isCacheValid = _cachedQueue != null &&
          _queueCacheTime != null &&
          now.difference(_queueCacheTime!) < _queueCacheTTL;
      final allPatients = isCacheValid ? _cachedQueue! : _getSortedQueue();
      if (!isCacheValid) {
        _cachedQueue = allPatients;
        _queueCacheTime = now;
      }

        bool isPatientDone(Map<String, dynamic> p) {
          final s = (p['status'] ?? '').toString().toLowerCase();
          final presc = p['prescription'];
          final hasPresc = presc is Map && (
            (presc['prescriptions'] is List && (presc['prescriptions'] as List).isNotEmpty) ||
            (presc['medicines'] is List && (presc['medicines'] as List).isNotEmpty) ||
            (presc['isVitalsOnly'] == true && presc['completedAt'] != null)
          );
          return s == 'completed' || s == 'prescribed' || _isPatientDispensed(p) || hasPresc;
        }

        final waiting = allPatients.where((p) {
          final s = (p['status'] ?? '').toString().toLowerCase();
          return !isPatientDone(p) && s != 'skipped';
        }).toList();

        if (widget.selectedPatient == null && waiting.isNotEmpty) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted && widget.selectedPatient == null) {
              _tryAutoSelectSmallestWaiting();
            }
          });
        }

        final skipped = allPatients.where((p) {
          final s = (p['status'] ?? '').toString().toLowerCase();
          return s == 'skipped';
        }).toList();

        final allCompleted = allPatients.where(isPatientDone).toList();
        // Strictly filter to patients prescribed by this doctor
        final myCompleted = allCompleted.where(_isPrescribedByMe).toList();
        final editableCompleted = TokenOrder.sortFairly(
          myCompleted.where((p) => !_isPatientDispensed(p)).toList(),
        );
        final dispensedCompleted = TokenOrder.sortFairly(
          myCompleted.where(_isPatientDispensed).toList(),
        );
        final effectiveCompleted = [...editableCompleted, ...dispensedCompleted];

        final waitingCount   = waiting.length;
        final skippedCount   = skipped.length;
        final completedCount = effectiveCompleted.length;
        final total          = waiting.length + skipped.length + effectiveCompleted.length;

        final smallestWaitingSerial = waiting.isNotEmpty
            ? (waiting.first['serial'] ?? waiting.first['id'])?.toString().trim().toUpperCase()
            : null;

        List<Map<String, dynamic>> list;
        switch (_filter) {
          case 'waiting':   list = waiting;    break;
          case 'skipped':   list = skipped;    break;
          case 'completed': list = effectiveCompleted;  break;
          default:          list = [...waiting, ...skipped, ...editableCompleted, ...dispensedCompleted];
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

        // Apply local search filter if user typed a token or name
        if (_queueSearchQuery.trim().isNotEmpty) {
          final q = _queueSearchQuery.trim().toLowerCase();
          list = list.where((p) {
            final ser = (p['serial'] ?? p['id'] ?? '').toString().toLowerCase();
            final dispTok = PatientInfo.formatDisplayToken(ser).toLowerCase();
            final pName = (p['patientName'] ?? p['name'] ?? p['fullName'] ?? '').toString().toLowerCase();
            return ser.contains(q) || dispTok.contains(q) || pName.contains(q);
          }).toList();
        }

        return Column(children: [
          // ── Header ──────────────────────────────────────────────────────
          Container(
            padding: const EdgeInsets.fromLTRB(14, 12, 12, 10),
            decoration: BoxDecoration(
              border: Border(
                bottom: BorderSide(
                  color: isDark ? SoftPalette.slate700.withValues(alpha: 0.7) : SoftPalette.slate150,
                ),
              ),
            ),
            child: Row(children: [
              Icon(Icons.people_outline_rounded,
                  color: isDark ? SoftPalette.indigo400 : _teal, size: 18),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  "Today's queue",
                  style: TextStyle(
                    color: isDark ? SoftPalette.gray50 : SoftPalette.slate900,
                    fontSize: 14,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              InkWell(
                borderRadius: BorderRadius.circular(8),
                onTap: () => setState(() => _filter = 'all'),
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
                  decoration: BoxDecoration(
                    color: _filter == 'all'
                        ? context.comfort.brandSoft
                        : Colors.transparent,
                    borderRadius: BorderRadius.circular(8),
                    border: _filter == 'all'
                        ? Border.all(color: context.comfort.brand.withValues(alpha: 0.25))
                        : null,
                  ),
                  child: Text(
                    '$total total',
                    style: TextStyle(
                      color: _filter == 'all'
                          ? context.comfort.brand
                          : context.comfort.textMuted,
                      fontSize: 11.5,
                      fontWeight: _filter == 'all' ? FontWeight.w700 : FontWeight.w500,
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 4),
              InkWell(
                borderRadius: BorderRadius.circular(6),
                onTap: _isSyncingQueue
                    ? null
                    : () async {
                        setState(() => _isSyncingQueue = true);
                        try {
                          await RealtimeManager().forceFlushAndCatchUp();
                          await LocalStorageService.downloadTodayTokens(widget.branchId, null, true);
                        } catch (e) {
                          debugPrint('[PatientQueue] Manual refresh error: $e');
                        } finally {
                          if (mounted) {
                            setState(() => _isSyncingQueue = false);
                            WidgetsBinding.instance.addPostFrameCallback(
                                (_) => _tryAutoSelectSmallestWaiting());
                          }
                        }
                      },
                child: Padding(
                  padding: const EdgeInsets.all(4),
                  child: _isSyncingQueue
                      ? SizedBox(
                          width: 14,
                          height: 14,
                          child: CircularProgressIndicator(
                            color: isDark ? SoftPalette.slate350 : _teal,
                            strokeWidth: 1.8,
                          ),
                        )
                      : Icon(Icons.refresh_rounded,
                          color: isDark ? SoftPalette.slate400 : SoftPalette.slate550,
                          size: 16),
                ),
              ),
            ]),
          ),

          // ── Session / Shift & Camp Filter Bar ───────────────────────────────
          Container(
            width: double.infinity,
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  _buildSessionChip('all', 'All day'),
                  if (_allowedSessions.contains('morning') || _allowedSessions.contains('all')) ...[
                    const SizedBox(width: 4),
                    _buildSessionChip('morning', 'Morning'),
                  ],
                  if (_allowedSessions.contains('evening') || _allowedSessions.contains('all')) ...[
                    const SizedBox(width: 4),
                    _buildSessionChip('evening', 'Evening'),
                  ],
                  if (_allowedSessions.contains('night') || _allowedSessions.contains('all')) ...[
                    const SizedBox(width: 4),
                    _buildSessionChip('night', 'Night'),
                  ],
                  if (_hasMultiCamps) ...[
                    const SizedBox(width: 8),
                    Container(height: 14, width: 1, color: isDark ? SoftPalette.slate700 : SoftPalette.slate200),
                    const SizedBox(width: 8),
                    _buildCampChip('all', 'All Camps'),
                    ...CampSessionService.getCampsForBranch(widget.branchId).map((c) {
                      final cId = (c['id'] ?? '').toString();
                      final cName = (c['name'] ?? CampSessionService.getCampLabel(cId, widget.branchId)).toString();
                      return Padding(
                        padding: const EdgeInsets.only(left: 4),
                        child: _buildCampChip(cId, cName),
                      );
                    }),
                  ],
                ],
              ),
            ),
          ),

          // ── 3 Status Filter Cards (Waiting / Skipped / Done) ────────────────
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 6, 12, 8),
            child: Row(
              children: [
                Expanded(
                  child: GestureDetector(
                    onTap: () => setState(() => _filter = _filter == 'waiting' ? 'all' : 'waiting'),
                    child: _buildFilterTab(
                        'Waiting', waitingCount, isDark ? SoftPalette.gray50 : SoftPalette.slate900, _filter == 'waiting'),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: GestureDetector(
                    onTap: () => setState(() => _filter = _filter == 'skipped' ? 'all' : 'skipped'),
                    child: _buildFilterTab(
                        'Skipped', skippedCount, isDark ? SoftPalette.amber300 : SoftPalette.orange500, _filter == 'skipped'),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: GestureDetector(
                    onTap: () => setState(() => _filter = _filter == 'completed' ? 'all' : 'completed'),
                    child: _buildFilterTab(
                        'Done', completedCount, isDark ? SoftPalette.emerald350 : SoftPalette.emerald600, _filter == 'completed'),
                  ),
                ),
              ],
            ),
          ),

          // ── Token / Name Search Box ─────────────────────────────────────────
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
            child: SizedBox(
              height: 36,
              child: TextField(
                controller: _queueSearchController,
                onChanged: (v) => setState(() => _queueSearchQuery = v),
                style: TextStyle(
                  fontSize: 12.5,
                  color: isDark ? SoftPalette.gray50 : SoftPalette.slate900,
                ),
                decoration: InputDecoration(
                  hintText: 'Token or name',
                  hintStyle: TextStyle(
                    fontSize: 12.5,
                    color: isDark ? SoftPalette.slate400 : SoftPalette.slate400,
                  ),
                  prefixIcon: Icon(
                    Icons.search_rounded,
                    size: 16,
                    color: isDark ? SoftPalette.slate400 : SoftPalette.slate550,
                  ),
                  suffixIcon: _queueSearchQuery.isNotEmpty
                      ? IconButton(
                          icon: const Icon(Icons.close_rounded, size: 15),
                          padding: EdgeInsets.zero,
                          onPressed: () {
                            _queueSearchController.clear();
                            setState(() => _queueSearchQuery = '');
                          },
                        )
                      : null,
                  filled: true,
                  fillColor: isDark ? SoftPalette.slate900 : SoftPalette.slate50,
                  contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 0),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(8),
                    borderSide: BorderSide(
                      color: isDark ? SoftPalette.slate700 : SoftPalette.slate200,
                    ),
                  ),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(8),
                    borderSide: BorderSide(
                      color: isDark ? SoftPalette.slate700 : SoftPalette.slate200,
                    ),
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(8),
                    borderSide: BorderSide(
                      color: isDark ? SoftPalette.indigo400 : _teal,
                    ),
                  ),
                ),
              ),
            ),
          ),

          // ── Exception requests ───────────────────────────────────────────
          if (finalExceptions.isNotEmpty) ...[
            Container(
              width: double.infinity,
              margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              decoration: BoxDecoration(
                color: context.adapt(SoftPalette.amber100m),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: context.adapt(SoftPalette.amber300)),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(children: [
                    Icon(Icons.emergency_share_outlined, color: context.adapt(SoftPalette.orange400), size: 18),
                    const SizedBox(width: 8),
                    Text(
                      'EXCEPTION REQUESTS (${finalExceptions.length})',
                      style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.bold,
                          color: context.adapt(SoftPalette.orange400),
                          letterSpacing: 1.1),
                    ),
                  ]),
                  const SizedBox(height: 10),
                  ...finalExceptions.map((d) {
                    return Card(
                      elevation: 0,
                      color: context.adapt(SoftPalette.amber150),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                      child: ListTile(
                        dense: true,
                        leading: CircleAvatar(
                          radius: 14,
                          backgroundColor: SoftPalette.orange400,
                          child: const Icon(Icons.person, color: SoftPalette.gray50, size: 16),
                        ),
                        title: Text(d['patientName'] ?? 'Unknown',
                            style: TextStyle(fontWeight: FontWeight.bold, color: context.adapt(SoftPalette.orange400))),
                        subtitle: Text('Restricted: ${d['restriction']?['remainingDays'] ?? '?'} days left'),
                        trailing: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            IconButton(
                              icon: Icon(Icons.check_circle, color: context.adapt(SoftPalette.green400), size: 24),
                              onPressed: () => _approveException(d),
                            ),
                            IconButton(
                              icon: Icon(Icons.cancel, color: context.adapt(SoftPalette.red400), size: 24),
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
                ? Center(
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          const GEmptyIllustration(
                            GEmptyIllustrationKind.people,
                            size: 124,
                            fallbackIcon: Icons.people_outline_rounded,
                          ),
                          const SizedBox(height: 12),
                          Text(
                            "No patients in queue",
                            style: TextStyle(
                              fontSize: 13.5,
                              fontWeight: FontWeight.w600,
                              color: isDark ? SoftPalette.slate350 : SoftPalette.slate600,
                            ),
                          ),
                        ],
                      ),
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
                final isDispensed = _isPatientDispensed(patient);
                final presc = patient['prescription'];
                final hasRealPresc = presc is Map && (
                  (presc['prescriptions'] is List && (presc['prescriptions'] as List).isNotEmpty) ||
                  (presc['medicines'] is List && (presc['medicines'] as List).isNotEmpty) ||
                  (presc['isVitalsOnly'] == true && presc['completedAt'] != null)
                );
                final isDone = status == 'completed' || status == 'prescribed' || isDispensed || hasRealPresc;
                final isFirstDispensed = isDispensed &&
                    (index == 0 || !_isPatientDispensed(list[index - 1]));
                final isSkipped = status == 'skipped';
                final isWaiting = !isDone && !isSkipped;
                final isVitalsOnly = patient['isVitalsOnly'] == true || patient['vitalsOnly'] == true;

                // Edit button must only appear for status == 'completed' (not yet dispensed),
                // and MUST hide immediately once status becomes 'dispensed'.
                final isCompleted = isDone && !isDispensed;

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
                    : (isSkipped ? SoftPalette.orange400 : SoftPalette.green500);

                final Widget dot = Container(
                    width: 10,
                    height: 10,
                    decoration:
                        BoxDecoration(color: dotColor, shape: BoxShape.circle));

                final isDark = _isDark;
                final dispToken = PatientInfo.formatDisplayToken(serial);

                // Compute age, gender, queueType label for concise subtitle
                final pVitals = (patient['vitals'] is Map) ? patient['vitals'] as Map : const {};
                final pAge = (pVitals['age'] ?? patient['age'] ?? '').toString().trim();
                final pGenderRaw = (pVitals['gender'] ?? patient['gender'] ?? '').toString().trim();
                final pGenderShort = pGenderRaw.isEmpty
                    ? ''
                    : (pGenderRaw.toLowerCase().startsWith('m')
                        ? 'M'
                        : (pGenderRaw.toLowerCase().startsWith('f') ? 'F' : pGenderRaw));
                final rawQt = (patient['queueType'] ?? '').toString().toLowerCase();
                final staffInfo = StaffPatientLinkService.getStaffInfoFromPatientMap(patient);
                final qtLabel = rawQt.contains('non')
                    ? 'Non-Zakat'
                    : (rawQt.contains('gmwf') ? 'GMWF' : 'Zakat');

                final subParts = <String>[
                  if (pAge.isNotEmpty) '$pAge y',
                  if (pGenderShort.isNotEmpty) pGenderShort,
                  if (staffInfo != null) 'Staff',
                  qtLabel,
                ];

                // Compute wait minutes from createdAt / timestamp if available
                int? waitMinutes;
                final rawCreated = patient['createdAt'] ?? patient['registeredAt'] ?? patient['timestamp'];
                DateTime? createdDt;
                if (rawCreated is DateTime) {
                  createdDt = rawCreated;
                } else if (rawCreated is String && rawCreated.isNotEmpty) {
                  createdDt = DateTime.tryParse(rawCreated);
                } else if (rawCreated is int) {
                  createdDt = DateTime.fromMillisecondsSinceEpoch(rawCreated);
                }
                if (createdDt != null) {
                  final diff = DateTime.now().difference(createdDt).inMinutes;
                  if (diff >= 0 && diff < 720) waitMinutes = diff;
                }
                final Color waitColor = waitMinutes == null
                    ? (isDark ? SoftPalette.slate400 : SoftPalette.slate550)
                    : (waitMinutes >= 50
                        ? (isDark ? SoftPalette.red300 : SoftPalette.red600)
                        : (waitMinutes >= 25
                            ? (isDark ? SoftPalette.amber300 : SoftPalette.amber500)
                            : (isDark ? SoftPalette.slate400 : SoftPalette.slate550)));

                final brand = Theme.of(context).colorScheme.primary;
                // Token badge color
                final Color badgeBg = isSelected
                    ? brand.withValues(alpha: isDark ? 0.35 : 0.14)
                    : (isDispensed
                        ? (isDark ? SoftPalette.emerald700.withValues(alpha: 0.45) : SoftPalette.emerald100)
                        : (rawQt.contains('non')
                            ? (isDark ? SoftPalette.slate700.withValues(alpha: 0.65) : SoftPalette.slate150)
                            : (isDark ? SoftPalette.emerald700.withValues(alpha: 0.35) : SoftPalette.emerald50)));
                final Color badgeFg = isSelected
                    ? (isDark ? SoftPalette.gray50 : brand)
                    : ((isDispensed || !rawQt.contains('non'))
                        ? (isDark ? SoftPalette.emerald300 : SoftPalette.emerald600)
                        : (isDark ? SoftPalette.slate200 : SoftPalette.slate700));

                final card = AnimatedContainer(
                  duration: const Duration(milliseconds: 180),
                  margin: const EdgeInsets.only(bottom: 6),
                  decoration: BoxDecoration(
                    color: isSelected
                        ? brand.withValues(alpha: isDark ? 0.16 : 0.07)
                        : (isDispensed
                            ? (isDark
                                ? SoftPalette.emerald900.withValues(alpha: 0.22)
                                : SoftPalette.emerald50.withValues(alpha: 0.55))
                            : (isDark ? SoftPalette.slate900.withValues(alpha: 0.6) : SoftPalette.gray50)),
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(
                      color: isSelected
                          ? brand
                          : (isDispensed
                              ? (isDark
                                  ? SoftPalette.emerald500.withValues(alpha: 0.45)
                                  : SoftPalette.emerald600.withValues(alpha: 0.35))
                              : (isDark ? SoftPalette.slate700.withValues(alpha: 0.7) : SoftPalette.slate200)),
                      width: isSelected ? 1.6 : (isDispensed ? 1.2 : 1.0),
                    ),
                  ),
                  child: InkWell(
                    borderRadius: BorderRadius.circular(10),
                    onTap: () {
                      final thisSerial = serial.trim().toUpperCase();
                      if (smallestWaitingSerial == null || thisSerial != smallestWaitingSerial) {
                        return;
                      }
                      widget.onPatientSelected({...patient, 'serial': serial, 'id': serial});
                    },
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
                      child: Row(children: [
                        // Rounded square token badge (flexible width for XL text scaling)
                        Tooltip(
                          message: 'Full Serial: $serial',
                          child: Container(
                            constraints: const BoxConstraints(minWidth: 44, minHeight: 38),
                            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                            alignment: Alignment.center,
                            decoration: BoxDecoration(
                              color: badgeBg,
                              borderRadius: BorderRadius.circular(9),
                              border: Border.all(
                                color: badgeFg.withValues(alpha: 0.25),
                              ),
                            ),
                            child: Text(
                              dispToken,
                              maxLines: 1,
                              softWrap: false,
                              style: TextStyle(
                                color: badgeFg,
                                fontSize: 13.5,
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                name,
                                style: TextStyle(
                                  fontWeight: FontWeight.w700,
                                  fontSize: 13.5,
                                  color: isDark
                                      ? SoftPalette.gray50
                                      : ((!isWaiting && !isSkipped && !isDispensed)
                                          ? SoftPalette.gray550
                                          : SoftPalette.slate900),
                                ),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                              const SizedBox(height: 2),
                              Text(
                                subParts.join(' · '),
                                style: TextStyle(
                                  fontSize: 11,
                                  fontWeight: FontWeight.w500,
                                  color: isDark ? SoftPalette.slate400 : SoftPalette.slate550,
                                ),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                              if (isVitalsOnly || isSkipped || prescDays > 1) ...[
                                const SizedBox(height: 4),
                                Wrap(
                                  spacing: 4,
                                  runSpacing: 2,
                                  children: [
                                    if (isVitalsOnly)
                                      Container(
                                        padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                                        decoration: BoxDecoration(
                                          color: SoftPalette.purple600,
                                          borderRadius: BorderRadius.circular(4),
                                        ),
                                        child: const Text('VITALS',
                                            style: TextStyle(color: SoftPalette.gray50, fontSize: 8.5, fontWeight: FontWeight.bold)),
                                      ),
                                    if (isSkipped)
                                      Container(
                                        padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                                        decoration: BoxDecoration(
                                          color: SoftPalette.amber500,
                                          borderRadius: BorderRadius.circular(4),
                                        ),
                                        child: const Text('SKIPPED',
                                            style: TextStyle(color: SoftPalette.gray50, fontSize: 8.5, fontWeight: FontWeight.bold)),
                                      ),
                                    if (prescDays > 1)
                                      Container(
                                        padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                                        decoration: BoxDecoration(
                                          color: SoftPalette.indigo500,
                                          borderRadius: BorderRadius.circular(4),
                                        ),
                                        child: Text('×$prescDays d',
                                            style: const TextStyle(color: SoftPalette.gray50, fontSize: 8.5, fontWeight: FontWeight.bold)),
                                      ),
                                  ],
                                ),
                              ],
                            ],
                          ),
                        ),
                        const SizedBox(width: 6),
                        if (isCompleted)
                          IconButton(
                            icon: Icon(Icons.edit_outlined,
                                color: isDark ? SoftPalette.amber300 : _teal, size: 17),
                            tooltip: 'Edit Prescription',
                            padding: EdgeInsets.zero,
                            constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
                            onPressed: () => _showPrescriptionDialog(patient),
                          )
                        else if (isDispensed)
                          Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              if (waitMinutes != null) ...[
                                Icon(Icons.schedule_rounded, size: 12, color: waitColor),
                                const SizedBox(width: 3),
                                Text(
                                  '${waitMinutes}m',
                                  style: TextStyle(
                                    fontSize: 11,
                                    fontWeight: FontWeight.w600,
                                    color: waitColor,
                                  ),
                                ),
                                const SizedBox(width: 8),
                              ],
                              Container(
                                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3.5),
                                decoration: BoxDecoration(
                                  color: SoftPalette.emerald600,
                                  borderRadius: BorderRadius.circular(6),
                                ),
                                child: const Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Icon(
                                      Icons.check_circle_outline_rounded,
                                      size: 11,
                                      color: SoftPalette.gray50,
                                    ),
                                    SizedBox(width: 4),
                                    Text(
                                      'DISPENSED',
                                      style: TextStyle(
                                        color: SoftPalette.gray50,
                                        fontSize: 9.5,
                                        fontWeight: FontWeight.w800,
                                        letterSpacing: 0.3,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          )
                        else if (waitMinutes != null)
                          Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(Icons.schedule_rounded, size: 12, color: waitColor),
                              const SizedBox(width: 3),
                              Text(
                                '${waitMinutes}m',
                                style: TextStyle(
                                  fontSize: 11,
                                  fontWeight: FontWeight.w600,
                                  color: waitColor,
                                ),
                              ),
                            ],
                          )
                        else
                          dot,
                      ]),
                    ),
                  ),
                );
                if (!isFirstDispensed) return card;
                final dispensedSectionCount = list.where(_isPatientDispensed).length;
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _buildDispensedSectionHeader(context, dispensedSectionCount),
                    card,
                  ],
                );
              },
            ),
          ),
        ]);
    } catch (e, st) {
      debugPrint('[PatientQueue] Render error in _buildQueueContent: $e\n$st');
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.people_outline, size: 36, color: context.adapt(_teal)),
              const SizedBox(height: 12),
              const Text('Queue updating...', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14)),
              const SizedBox(height: 8),
              ElevatedButton.icon(
                icon: const Icon(Icons.refresh, size: 16),
                label: const Text('Reload Queue'),
                style: ElevatedButton.styleFrom(backgroundColor: _teal, foregroundColor: SoftPalette.gray50),
                onPressed: () {
                  if (mounted) setState(() {});
                },
              ),
            ],
          ),
        ),
      );
    }
  }

  Widget _buildFilterTab(
      String label, int count, Color color, bool isActive) {
    final isDark = _isDark;
    final brand = Theme.of(context).colorScheme.primary;
    final accent = color == (isDark ? SoftPalette.gray50 : SoftPalette.slate900) ? brand : color;
    return AnimatedContainer(
      duration: const Duration(milliseconds: 180),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: isActive
            ? accent.withValues(alpha: isDark ? 0.22 : 0.12)
            : accent.withValues(alpha: isDark ? 0.08 : 0.05),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
          color: isActive
              ? accent
              : accent.withValues(alpha: isDark ? 0.28 : 0.22),
          width: isActive ? 1.5 : 1.0,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '$count',
            style: TextStyle(
              color: color,
              fontSize: 16,
              fontWeight: FontWeight.w800,
              height: 1.1,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            label,
            style: TextStyle(
              color: isDark ? SoftPalette.slate350 : SoftPalette.slate600,
              fontWeight: FontWeight.w500,
              fontSize: 10.5,
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ],
      ),
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
                    _cachedQueue = null;
                  })
              : null,
          borderRadius: BorderRadius.circular(8),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
            decoration: BoxDecoration(
              color: isSelected
                  ? (isDark ? SoftPalette.slate700 : _teal)
                  : Colors.transparent,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Text(
              label,
              style: TextStyle(
                fontSize: 11.5,
                fontWeight: isSelected ? FontWeight.w700 : FontWeight.w500,
                color: isSelected
                    ? SoftPalette.gray50
                    : (isDark ? SoftPalette.slate350 : SoftPalette.slate600),
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
          onTap: isAllowed
              ? () => setState(() {
                    _selectedCampFilter = value;
                    _cachedQueue = null;
                  })
              : null,
          borderRadius: BorderRadius.circular(12),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            decoration: BoxDecoration(
              color: isSelected ? _teal : (isDark ? SoftPalette.slate800 : (isAllowed ? SoftPalette.gray50 : SoftPalette.gray100)),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: isSelected ? _teal : (isDark ? SoftPalette.slate700 : (isAllowed ? SoftPalette.teal300 : SoftPalette.gray300))),
            ),
            child: Text(
              label,
              style: TextStyle(
                fontSize: 10.5,
                fontWeight: isSelected ? FontWeight.bold : FontWeight.w500,
                color: isSelected ? SoftPalette.gray50 : (isDark ? SoftPalette.slate200 : (isAllowed ? SoftPalette.teal700 : SoftPalette.gray500)),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
