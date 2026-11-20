import 'package:gmwf/utils/debounced_box_listenable.dart';
import 'package:gmwf/design/tokens/soft_palette.dart';
import 'package:gmwf/design/tokens/comfort_colors.dart';
import 'dart:async';
import 'dart:convert';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:flutter/material.dart';
import 'package:gmwf/design/components/app_toast.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:gmwf/design/components/flushbar_compat.dart';
import 'package:hive_flutter/hive_flutter.dart';

import 'package:gmwf/services/local_storage_service.dart';
import 'package:gmwf/services/sync_service.dart';
import 'package:gmwf/services/auth_service.dart';
import 'package:gmwf/realtime/connection_manager.dart';
import 'package:gmwf/realtime/realtime_manager.dart';
import 'package:gmwf/realtime/realtime_events.dart';
import 'package:gmwf/widgets/connection_status_widget.dart';
import 'package:gmwf/widgets/gmwf_app_bar.dart';
import 'package:gmwf/services/camp_session_service.dart';
import 'package:gmwf/widgets/clock_skew_warning_banner.dart';
import 'package:gmwf/utils/formatters.dart';
import 'package:gmwf/utils/notification_deduper.dart';
import '../user_settings_dialog.dart';
import 'patient_queue.dart';
import 'patient_info.dart';
import 'doctor_right_panel.dart';
import 'patient_history.dart';
import 'package:gmwf/pages/dispensary/dispensar/inventory.dart';
import 'package:gmwf/pages/request.dart';
import 'package:gmwf/widgets/update_dialog_widget.dart';
import 'package:gmwf/services/prescription_template_service.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:gmwf/design/design_system.dart';
import 'package:gmwf/utils/branch_labels.dart';
import '../widgets/desk_theme.dart';

class DoctorScreen extends StatefulWidget {
  final String branchId;
  final String doctorId;
  final String doctorName;
  final bool isEmbedded;

  const DoctorScreen({
    super.key,
    required this.branchId,
    required this.doctorId,
    required this.doctorName,
    this.isEmbedded = false,
  });

  @override
  State<DoctorScreen> createState() => _DoctorScreenState();
}

class _DoctorScreenState extends State<DoctorScreen>
    with SingleTickerProviderStateMixin, AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;
  Map<String, dynamic>? _selectedPatientData;

  final TextEditingController _complaintController = TextEditingController();
  final TextEditingController _diagnosisController = TextEditingController();

  List<Map<String, dynamic>> _prescriptions = [];
  List<Map<String, dynamic>> _labResults = [];

  bool _isSaving = false;
  String? _username;
  String? _doctorDegree;
  String? _branchName;
  bool _online = true;
  bool _isSyncing = false;
  bool _loadingBranch = true;

  ConnectionStatus _connectionStatus = ConnectionManager().status;

  StreamSubscription<List<ConnectivityResult>>? _connSub;
  StreamSubscription<Map<String, dynamic>>? _realtimeSub;
  StreamSubscription<ConnectionStatus>? _connectionSub;

  // [BUG-13] Remove function returned by addReconnectListener
  VoidCallback? _removeReconnectListener;

  // [BUG-12] Debounce + guard for reconnect-triggered sync
  Timer? _syncDebounce;
  bool _reconnectSyncing = false;

  // [FIX-FREEZE] Debounce rapid catch-up setState() storms.
  // When the LAN server sends a catch-up batch (e.g. 100 tokens), every token
  // fires _handleNewToken → setState(). 100 redraws in <100ms stall the UI
  // thread, causing the "white screen trance". Instead, coalesce all updates
  // within a 120ms window into a single setState().
  Timer? _refreshDebounce;
  void _scheduleRefresh() {
    _refreshDebounce?.cancel();
    _refreshDebounce = Timer(const Duration(milliseconds: 120), () {
      if (mounted) setState(() {});
    });
  }

  Color get _teal => context.comfort.brand;

  int _rightPanelKey = 0;

  late TabController _tabController;

  bool get _isKarachi => BranchLabels.isKarachiBranch(widget.branchId);

  bool get _canApproveRequests => LocalStorageService.isDoctorInventoryApprovalAllowed(widget.branchId);

  // ── Queue-type resolver ────────────────────────────────────────────────────
  String resolveQueueType(String? raw) {
    final s = (raw ?? '').toLowerCase().trim();
    if (s == 'non-zakat' || s == 'non zakat' || s == 'nonzakat' ||
        s == 'non_zakat' || s.startsWith('non')) {
      if (_isKarachi) return 'zakat';
      return 'non-zakat';
    }
    if (s == 'gmwf' || s == 'gm wf' || s == 'gm-wf' || s == 'gm_wf') return 'gmwf';
    return 'zakat';
  }

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 3, vsync: this);

    LocalStorageService.ensureDoctorBoxesOpen();

    if (!widget.isEmbedded) {
      SyncService().start(widget.branchId, moduleScope: 'dispensary');
    }
    _loadBranchName();
    _listenConnectivity();

    CampSessionService.activeCampNotifier.addListener(_onActiveCampChanged);

    // [FIX-USERNAME] Load name first, then start ConnectionManager with it.
    // _fetchDoctorName() starts the connection once the name is resolved so
    // the identify message carries the real name, not just 'doctor'.
    _fetchDoctorName();
    _connectionStatus = ConnectionManager().status;
    _connectionSub = ConnectionManager().statusStream.listen((s) {
      if (mounted) setState(() => _connectionStatus = s);
      // [BUG-12] Debounce: only trigger sync after 300 ms of stable connection
      if (s.isConnected && !widget.isEmbedded) {
        _syncDebounce?.cancel();
        _syncDebounce = Timer(const Duration(milliseconds: 300), _syncOnReconnect);
      }
    });

    // [BUG-13] Register via listener list — safe alongside DispensarScreen
    if (!widget.isEmbedded) {
      _removeReconnectListener = ConnectionManager().addReconnectListener(_syncOnReconnect);
    }

    _realtimeSub = RealtimeManager().messageStream.listen(_handleRealtimeUpdate);

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && !widget.isEmbedded) {
        UpdateDialogWidget.showUpdateDialogIfNeeded(context);
        RealtimeManager().forceFlushAndCatchUp();
      }
    });
  }

  // [FIX-USERNAME] Resolve doctor name then start/update connection with it.
  Future<void> _fetchDoctorName() async {
    String? resolvedName;

    // 1. Try local user cache
    final localUser = LocalStorageService.getLocalUserByUid(widget.doctorId);
    if (localUser != null) {
      resolvedName = resolveUserDisplayName(localUser);
      final localDegree = (localUser['degree'] as String?)?.trim();
      if (localDegree != null && localDegree.isNotEmpty) {
        _doctorDegree = localDegree;
      }
    }

    // 2. Check active app_settings cache
    if (resolvedName == null || resolvedName == 'User' || resolvedName == 'Doctor') {
      try {
        if (Hive.isBoxOpen('app_settings')) {
          final box = Hive.box('app_settings');
          final uData = box.get('user_data') ?? box.get('currentUser');
          if (uData is Map) {
            final n = resolveUserDisplayName(Map<String, dynamic>.from(uData));
            if (n.isNotEmpty && n != 'User' && n != 'Doctor') {
              resolvedName = n;
            }
          }
        }
      } catch (_) {}
    }

    // 3. Fall back to widget parameter
    if (resolvedName == null || resolvedName == 'User' || resolvedName == 'Doctor') {
      if (widget.doctorName.trim().isNotEmpty && widget.doctorName.trim().toLowerCase() != 'doctor') {
        resolvedName = widget.doctorName.trim();
      }
    }

    if (mounted && resolvedName != null && resolvedName.isNotEmpty) {
      setState(() => _username = resolvedName);
    }

    // 4. Start connection immediately with resolved name
    if (!widget.isEmbedded) {
      ConnectionManager().start(
        role:     'doctor',
        branchId: widget.branchId,
        username: resolvedName,
      );
      if (resolvedName != null) {
        RealtimeManager().updateUsername(resolvedName);
      }
    }

    // 5. Fetch authoritative name from Firestore with timeout.
    try {
      final snap = await FirebaseFirestore.instance
          .collection('users')
          .doc(widget.doctorId)
          .get()
          .timeout(const Duration(seconds: 3));
      if (!snap.exists) return;
      final firestoreName = resolveUserDisplayName(snap.data());
      if (firestoreName.isNotEmpty && firestoreName != 'User' && firestoreName != 'Doctor') {
        if (mounted) setState(() => _username = firestoreName);
        if (!widget.isEmbedded) {
          RealtimeManager().updateUsername(firestoreName);
        }
      }
      final firestoreDegree = (snap.data()?['degree'] as String?)?.trim() ?? '';
      if (firestoreDegree.isNotEmpty) {
        if (mounted) setState(() => _doctorDegree = firestoreDegree);
      }
    } catch (e) {
      debugPrint('[DoctorScreen] Could not fetch doctor name: $e');
    }
  }

  Future<void> _syncOnReconnect() async {
    if (!mounted || _reconnectSyncing) return;
    _reconnectSyncing = true;
    try {
      await RealtimeManager().forceFlushAndCatchUp();
      // If connected to LAN server, server is the single writer to Firestore.
      // Dispensary client station should not trigger direct cloud upload or pull.
      if (!RealtimeManager().isConnected) {
        unawaited(SyncService().triggerUpload().catchError((_) {}));
        unawaited(
          LocalStorageService.downloadTodayTokens(widget.branchId, null, true)
              .timeout(const Duration(seconds: 3))
              .then((_) {
                if (mounted) setState(() {});
              })
              .catchError((e) {
                debugPrint('[DoctorScreen] Reconnect cloud token pull notice: $e');
              })
        );
      }
      if (mounted) setState(() {});
      debugPrint('[DoctorScreen] ✅ Synced on reconnect');
    } catch (e) {
      debugPrint('[DoctorScreen] Reconnect sync failed: $e');
    } finally {
      _reconnectSyncing = false;
    }
  }

  void _handleRealtimeUpdate(Map<String, dynamic> event) {
    final type = event['event_type'] as String?;
    final rawData = event['data'];
    final data = (rawData is Map) ? Map<String, dynamic>.from(rawData) : Map<String, dynamic>.from(event);
    if (type == null) return;

    final senderId = event['_clientId']?.toString() ?? '';
    final myId = RealtimeManager().clientId;
    if (senderId.isNotEmpty && myId != null && senderId == myId) return;

    if (type == 'token_created' || (type == RealtimeEvents.saveEntry && (data['status'] == 'waiting' || data['status'] == null) && data['prescriptions'] == null)) {
      _handleNewToken(data, event);
    } else if (type == RealtimeEvents.savePrescription || type == 'prescription_created' || (type == RealtimeEvents.saveEntry && (data['status'] == 'completed' || data['prescriptions'] != null))) {
      _handlePrescriptionUpdate(data, event);
    } else if (type == 'dispense_completed') {
      _handleDispenseCompleted(data);
    } else if (type == RealtimeEvents.saveStockItem || type == 'save_stock_item' || type == 'medicine_registered') {
      // [FIX] RealtimeRouter._handleSaveStockItem already ran (before this
      // stream listener fires) and correctly persisted the stock change to
      // Hive — handling both _quantityDelta increments and full-item saves.
      // The old code here did a raw saveLocalInventoryItem(data) which is a
      // full overwrite that IGNORES _quantityDelta, clobbering the router's
      // correct delta-applied value with the SENDER's absolute total.
      // [PERF] No setState here either: the right panel watches the stock box itself
      // (debounced reload), and a whole-screen rebuild per stock tick (one per dispensed
      // medicine) rebuilt the queue, history and panel for nothing.
    } else if (type == RealtimeEvents.deleteStockItem || type == 'delete_stock_item') {
      // RealtimeRouter._handleDeleteStockItem already removed it; the panel's box watch refreshes.
    } else if (type == RealtimeEvents.saveProformaItem || type == 'save_proforma_item' ||
               type == RealtimeEvents.proformaItemUpdated || type == 'proforma_item_updated') {
      // [FIX] Proforma catalog changes (new medicines added/edited in the
      // master catalog) were completely unhandled — the doctor's medicine
      // search list never refreshed. Force right panel rebuild so the
      // updated proforma entries appear in the prescription search.
      _scheduleRefresh();
    } else if (type == RealtimeEvents.requestApproved || type == 'request_approved') {
      // [FIX] Request approvals (e.g. stock addition approved by supervisor)
      // were silently ignored on the doctor screen. Refresh inventory panel
      // and notify the doctor so approved stock is immediately visible.
      if (mounted) {
        _scheduleRefresh();
        AppToast.showSnackBar(context, 
          SnackBar(
            content: Text('✅ Request approved: ${data['title'] ?? data['requestType'] ?? 'Stock Request'}'),
            backgroundColor: SoftPalette.green500,
            duration: const Duration(seconds: 4),
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    } else if (type == RealtimeEvents.requestRejected || type == 'request_rejected') {
      if (mounted) {
        _scheduleRefresh();
        AppToast.showSnackBar(context, 
          SnackBar(
            content: Text('❌ Request rejected: ${data['title'] ?? data['requestType'] ?? 'Stock Request'}'),
            backgroundColor: SoftPalette.red500,
            duration: const Duration(seconds: 4),
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    } else if (type == RealtimeEvents.tokenReversalApproved || type == 'token_reversal_approved') {
      final serial = (data['tokenSerial'] ?? data['serial'] ?? data['tokenId'])?.toString();
      if (serial != null && serial.isNotEmpty && serial == _selectedPatientData?['serial']) {
        if (mounted) {
          setState(() {
            _selectedPatientData = null;
            _complaintController.clear();
            _diagnosisController.clear();
            _prescriptions.clear();
            _labResults.clear();
            _bumpPanelKey();
          });
        }
      }
    }
  }

  void _mergeReceptionistFieldsIntoSelectedPatient(Map<String, dynamic> source) {
    if (_selectedPatientData == null) return;
    bool isMeaningful(dynamic v) {
      if (v == null) return false;
      final s = v.toString().trim();
      if (s.isEmpty) return false;
      final low = s.toLowerCase();
      return low != 'n/a' && low != 'null' && low != 'unknown' && low != 'unknown patient' && !low.startsWith('unknown_');
    }

    const receptionistKeys = [
      'patientName', 'name', 'fullName',
      'patientCnic', 'cnic', 'guardianCnic', 'guardianName', 'patientId',
      'age', 'patientAge', 'gender', 'patientGender',
      'phone', 'contactNumber', 'mobile', 'address',
      'bp', 'temp', 'sugar', 'weight',
      'campId', 'campName', 'dispensaryId', 'dispensaryTag', 'session',
      'createdBy', 'createdByName', 'receptionistId', 'receptionistName', 'tokenBy',
    ];
    for (final key in receptionistKeys) {
      if (isMeaningful(source[key])) {
        _selectedPatientData![key] = source[key];
      }
    }
    if (isMeaningful(_selectedPatientData!['patientName'])) {
      _selectedPatientData!['name'] = _selectedPatientData!['patientName'];
    } else if (isMeaningful(_selectedPatientData!['name'])) {
      _selectedPatientData!['patientName'] = _selectedPatientData!['name'];
    }
    _selectedPatientData!['vitals'] = LocalStorageService.mergeVitalsPreservingReceptionist(
      source['vitals'],
      _selectedPatientData!['vitals'],
    );
  }

  void _handleNewToken(Map<String, dynamic> data, [Map<String, dynamic>? fullEvent]) {
    // DO NOT call saveEntryLocal() here — RealtimeRouter._handleSaveEntry()
    // already persisted this token to Hive before this stream listener fires.
    // Calling it again is a duplicate write that triggers an extra Hive flush
    // per token (200 bytes of disk I/O per token in a catch-up batch).

    final incomingSerial = (data['serial'] ?? data['id'])?.toString();
    final selectedSerial = (_selectedPatientData?['serial'] ?? _selectedPatientData?['id'])?.toString();
    if (_selectedPatientData != null &&
        incomingSerial != null &&
        selectedSerial != null &&
        CampSessionService.isSameSerial(incomingSerial, selectedSerial, widget.branchId)) {
      _mergeReceptionistFieldsIntoSelectedPatient(data);
      final latestHive = LocalStorageService.getLocalEntry(widget.branchId, incomingSerial);
      if (latestHive != null) {
        _mergeReceptionistFieldsIntoSelectedPatient(latestHive);
      }
      if (mounted) setState(() {});
    }

    final isReplay = fullEvent?['_serverPush'] == true ||
        fullEvent?['_resent'] == true ||
        fullEvent?['isCatchUp'] == true ||
        fullEvent?['_isReplay'] == true ||
        data['_serverPush'] == true ||
        data['_resent'] == true ||
        data['isCatchUp'] == true ||
        data['_isReplay'] == true;
    if (isReplay) {
      // [FIX-FREEZE] Debounce — don't setState() for every token in a batch.
      _scheduleRefresh();
      return;
    }

    final today = CampSessionService.resolveShiftAndDateKey().dateKey;
    final serial = data['serial']?.toString();
    final itemDateKey = (data['dateKey'] ?? fullEvent?['dateKey'])?.toString().trim();
    final parts = (serial != null && serial.contains('-')) ? serial.split('-') : <String>[];
    final serialDk = (parts.isNotEmpty && parts[0].toUpperCase() == 'X')
        ? (parts.length > 1 ? parts[1] : '')
        : (parts.isNotEmpty ? parts[0] : '');
    final isToday = (itemDateKey == null || itemDateKey.isEmpty || itemDateKey == today) &&
        (serialDk.length != 6 || serialDk == today);
    if (!isToday) {
      _scheduleRefresh();
      return;
    }

    // Ignore if not a waiting new token
    final status = (data['status'] ?? '').toString().toLowerCase();
    if (status == 'completed' || status == 'prescribed' || status == 'dispensed' || data['dispenseStatus'] == 'dispensed' || data['prescriptions'] != null) {
      _scheduleRefresh();
      return;
    }

    final rawTime = data['createdAt'] ?? data['timestamp'];
    final dt = rawTime != null ? DateTime.tryParse(rawTime.toString()) : null;
    if (dt != null && DateTime.now().difference(dt).inMinutes > 3) {
      _scheduleRefresh();
      return;
    }

    final activeCamp = CampSessionService.getActiveCamp(widget.branchId);
    if (activeCamp != null && activeCamp.isNotEmpty && activeCamp != 'all') {
      final matches = CampSessionService.matchesCamp(
        selectedCamp: activeCamp,
        dispensaryId: data['dispensaryId']?.toString(),
        campId: data['campId']?.toString(),
        dispensaryTag: data['dispensaryTag']?.toString(),
        serial: serial,
      );
      if (!matches) return;
    }

    if (mounted) {
      setState(() {});
      final tokenKey = 'doc_token_${widget.branchId}_$serial';
      if (NotificationDeduper.shouldShow(tokenKey, window: const Duration(minutes: 5))) {
        AppToast.showSnackBar(context, 
          SnackBar(
            content: Text('🎟️ New token: ${data['patientName'] ?? '#${data['serial']}'}'),
            backgroundColor: SoftPalette.green500,
            duration: const Duration(seconds: 4),
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    }
  }

  void _handlePrescriptionUpdate(Map<String, dynamic> data, [Map<String, dynamic>? event]) {
    final serial = data['serial']?.toString();
    if (serial == null || serial != _selectedPatientData?['serial']) return;
    if (!mounted) return;

    // Replays / catch-up pushes carry old snapshots; applying one would erase medicines
    // the doctor added after that snapshot was taken.
    // The flags are on the event (RealtimeManager), not in 'data'. An outbox resend from
    // another desk is an old snapshot here too.
    if (data['_serverPush'] == true || data['_resent'] == true ||
        data['isCatchUp'] == true || data['_isReplay'] == true ||
        event?['_serverPush'] == true || event?['isCatchUp'] == true ||
        event?['_isReplay'] == true || event?['_resent'] == true || event?['_outboxResend'] == true) {
      return;
    }

    final incomingPrescriptions = (data['prescriptions'] as List<dynamic>?)
        ?.map((e) => Map<String, dynamic>.from(e as Map))
        .toList();
    final incomingLabResults = (data['labResults'] as List<dynamic>?)
        ?.map((e) => Map<String, dynamic>.from(e as Map))
        .toList();
    final incomingComplaint = data['complaint']?.toString();
    final incomingDiagnosis = data['diagnosis']?.toString();

    // Ignore echoes/replays that carry nothing new — recreating the panel for
    // them destroys any open medicine dialog and silently aborts the doctor's tap.
    final doctorListLocked = _prescriptions.isNotEmpty;
    final unchanged =
        (incomingPrescriptions == null || doctorListLocked || _sameJson(incomingPrescriptions, _prescriptions)) &&
        (incomingLabResults == null || _sameJson(incomingLabResults, _labResults)) &&
        (incomingComplaint == null || incomingComplaint == _complaintController.text) &&
        (incomingDiagnosis == null || incomingDiagnosis == _diagnosisController.text);
    if (unchanged) return;

    setState(() {
      if (incomingComplaint != null) _complaintController.text = incomingComplaint;
      if (incomingDiagnosis != null) _diagnosisController.text = incomingDiagnosis;
      if (incomingPrescriptions != null && _prescriptions.isEmpty) {
        // The doctor's open list is authoritative: remote events may only fill an EMPTY
        // list (e.g. opening a patient already prescribed elsewhere), never edit or
        // remove what the doctor has added.
        _prescriptions.addAll(incomingPrescriptions);
      }
      if (incomingLabResults != null) {
        _labResults
          ..clear()
          ..addAll(incomingLabResults);
      }
      _bumpPanelKey();
    });
  }

  /// Recreates the right panel (fresh State) — unless a dialog is open on top of this
  /// screen. A dialog such as medicine selection belongs to the current panel State;
  /// disposing that State leaves the dialog on screen but dead (every tap hits
  /// `if (!mounted) return`). In that case the data was already updated in place.
  /// Call inside setState.
  void _bumpPanelKey() {
    final dialogOpen = ModalRoute.of(context)?.isCurrent == false;
    if (kDebugMode) {
      debugPrint('[DoctorScreen] panel key bump ${dialogOpen ? "SKIPPED (dialog open)" : "applied"} from: '
          '${StackTrace.current.toString().split("\n").skip(1).take(3).map((l) => l.trim()).join(" <- ")}');
    }
    if (!dialogOpen) _rightPanelKey++;
  }

  static bool _sameJson(Object a, Object b) {
    try {
      return jsonEncode(a) == jsonEncode(b);
    } catch (_) {
      return false;
    }
  }

  void _handleDispenseCompleted(Map<String, dynamic> data) {
    final serial = data['serial']?.toString();
    if (serial != null && serial == _selectedPatientData?['serial']) {
      if (mounted) {
        setState(() => _selectedPatientData?['dispenseStatus'] = 'dispensed');
        AppToast.showSnackBar(context, 
          SnackBar(
            content: Text('💊 Patient #$serial has been dispensed'),
            backgroundColor: SoftPalette.purple600,
            duration: const Duration(seconds: 3),
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    }
  }

  Future<void> _loadBranchName() async {
    if (widget.branchId.isEmpty) {
      if (mounted) setState(() { _branchName = 'Free Dispensary'; _loadingBranch = false; });
      return;
    }
    try {
      final doc = await FirebaseFirestore.instance
          .collection('branches').doc(widget.branchId).get();
      if (mounted) {
        setState(() {
        _branchName = doc.data()?['name'] ?? 'Free Dispensary';
        _loadingBranch = false;
      });
      }
    } catch (_) {
      if (mounted) setState(() { _branchName = 'Free Dispensary'; _loadingBranch = false; });
    }
  }

  void _listenConnectivity() {
    _connSub = Connectivity().onConnectivityChanged.listen((results) {
      final online = results.any((r) => r != ConnectivityResult.none);
      if (_online != online && mounted) {
        setState(() => _online = online);
        AppToast.showSnackBar(context, 
          SnackBar(
            content: Text(online ? 'Internet restored' : 'Offline (LAN still works)'),
            backgroundColor: online ? SoftPalette.green500 : SoftPalette.orange350,
            duration: const Duration(seconds: 3),
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    }, onError: (e) {
      debugPrint('[DoctorScreen] Connectivity error ignored: $e');
    });
  }

  Future<void> _forceSync() async {
    if (_isSyncing || !mounted) return;
    setState(() => _isSyncing = true);
    try {
      // 1. Force-flush LAN WebSocket outbox & request catch-up from LAN server
      await RealtimeManager().forceFlushAndCatchUp();

      // 2. If online and NOT connected to LAN server, sync with cloud (server handles cloud sync when connected)
      if (_online && !RealtimeManager().isConnected) {
        await SyncService().syncTodayOnly(widget.branchId);
        await SyncService().triggerUpload();
      }
      if (mounted) {
        setState(() {});
        AppToast.showSnackBar(context, 
          SnackBar(
            content: Text(_online ? 'Sync completed (LAN & Cloud)' : 'LAN Sync completed (Outbox flushed)'),
            backgroundColor: SoftPalette.green500,
            duration: const Duration(seconds: 3),
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        AppToast.showSnackBar(context, 
          SnackBar(
            content: Text('Sync failed: $e'),
            backgroundColor: SoftPalette.red500,
            duration: const Duration(seconds: 3),
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _isSyncing = false);
    }
  }

  Future<void> _logout() async {
    final confirm = await showLogoutDialog(context);
    if (confirm != true || !mounted) return;
    try { _connectionSub?.cancel(); _connSub?.cancel(); _realtimeSub?.cancel(); } catch (_) {}
    ConnectionManager().stop().catchError((_) {});
    await AuthService().signOut();
    if (mounted) Navigator.pushNamedAndRemoveUntil(context, '/login', (r) => false);
  }

  Future<void> _selectPatient(Map<String, dynamic> rawEntry) async {
    if (_isSaving || !mounted) return;
    final incomingSerial = (rawEntry['serial'] ?? rawEntry['id'])?.toString().trim();
    final currentSerial = (_selectedPatientData?['serial'] ?? _selectedPatientData?['id'])?.toString().trim();
    if (currentSerial != null && currentSerial.isNotEmpty && incomingSerial != null && currentSerial == incomingSerial) {
      return; // Already selected, skip redundant save, broadcast, and rebuild loop
    }
    setState(() => _isSaving = true);
    try {
      _selectedPatientData = Map.from(rawEntry);
      final rawSerial = (rawEntry['serial'] ?? rawEntry['id'])?.toString();
      if (rawSerial != null && rawSerial.isNotEmpty) {
        final latestEntry = LocalStorageService.getLocalEntry(widget.branchId, rawSerial);
        if (latestEntry != null) {
          _mergeReceptionistFieldsIntoSelectedPatient(latestEntry);
        }
      }
      final currentName = (_selectedPatientData!['patientName'] ?? _selectedPatientData!['name'])?.toString().trim();
      if (currentName == null || currentName.isEmpty || currentName.toLowerCase() == 'unknown' || currentName.toLowerCase() == 'unknown patient') {
        final pId = (_selectedPatientData!['patientId'] ?? '').toString().trim();
        final pCnic = (_selectedPatientData!['patientCnic'] ?? _selectedPatientData!['cnic'] ?? _selectedPatientData!['guardianCnic'] ?? '').toString().trim();
        if (pId.isNotEmpty) {
          final lp = LocalStorageService.getLocalPatient(pId);
          final lpName = (lp?['name'] ?? lp?['patientName'] ?? lp?['fullName'])?.toString().trim();
          if (lpName != null && lpName.isNotEmpty && lpName.toLowerCase() != 'unknown' && lpName.toLowerCase() != 'unknown patient') {
            _selectedPatientData!['patientName'] = lpName;
          }
        }
        if ((_selectedPatientData!['patientName'] == null || _selectedPatientData!['patientName'] == 'Unknown Patient') && pCnic.isNotEmpty) {
          final lp = LocalStorageService.getLocalPatientByCnic(pCnic);
          final lpName = (lp?['name'] ?? lp?['patientName'] ?? lp?['fullName'])?.toString().trim();
          if (lpName != null && lpName.isNotEmpty && lpName.toLowerCase() != 'unknown' && lpName.toLowerCase() != 'unknown patient') {
            _selectedPatientData!['patientName'] = lpName;
          }
        }
      }
      final docName = _username ?? widget.doctorName;
      final docId = widget.doctorId;
      final serial = (rawEntry['serial'] ?? rawEntry['id'])?.toString();

      final rawPresc = rawEntry['prescription'];
      var prescription = (rawPresc is Map)
          ? PatientHistoryPanel.unwrapPrescriptionData(Map<String, dynamic>.from(rawPresc))
          : null;

      // If embedded prescription has no medicines, check local prescriptions box
      final initialMeds = prescription != null
          ? (prescription['prescriptions'] ?? prescription['medicines'] ?? prescription['items'])
          : null;
      if ((initialMeds is! List || initialMeds.isEmpty) && serial != null && serial.isNotEmpty) {
        final localP = LocalStorageService.getLocalPrescription(
          serial,
          cnic: _selectedPatientData?['patientCnic']?.toString() ?? _selectedPatientData?['cnic']?.toString(),
          patientName: _selectedPatientData?['patientName']?.toString() ?? _selectedPatientData?['name']?.toString(),
          branchId: widget.branchId,
        );
        if (localP != null && localP.isNotEmpty) {
          prescription = PatientHistoryPanel.unwrapPrescriptionData(localP);
        }
      }
      // Not this token's prescription (stored earlier under the same token number): start empty.
      if (prescription != null &&
          (rawEntry['dispenseStatus'] ?? '').toString().toLowerCase() != 'dispensed' &&
          !LocalStorageService.prescriptionFitsToken(prescription, rawEntry)) {
        prescription = null;
      }

      // Track consultation status locally and broadcast so other doctors see it
      if (serial != null && serial.isNotEmpty) {
        final existing = LocalStorageService.getLocalEntry(widget.branchId, serial);
        if (existing != null) {
          final updated = Map<String, dynamic>.from(existing);
          final status = (updated['status'] ?? '').toString().toLowerCase();
          if (status == 'waiting' || status.isEmpty) {
            updated['activeDoctor'] = docName;
            updated['activeDoctorId'] = docId;
            LocalStorageService.saveEntryLocal(widget.branchId, serial, updated);
            try {
              RealtimeManager().sendMessage(RealtimeEvents.payload(
                type: RealtimeEvents.saveEntry,
                branchId: widget.branchId,
                data: updated,
              ));
            } catch (_) {}
          }
        }
      }

      final medsList = prescription != null
          ? (prescription['prescriptions'] ?? prescription['medicines'] ?? prescription['items'])
          : null;
      _prescriptions
        ..clear()
        ..addAll(medsList is List
            ? medsList.whereType<Map>().map((e) => Map<String, dynamic>.from(e)).toList()
            : []);

      final labsList = prescription != null
          ? (prescription['labResults'] ?? prescription['labTests'] ?? prescription['tests'])
          : null;
      _labResults
        ..clear()
        ..addAll(labsList is List
            ? labsList.whereType<Map>().map((e) => Map<String, dynamic>.from(e)).toList()
            : []);

      _complaintController.text = prescription?['complaint']?.toString() ?? '';
      _diagnosisController.text = prescription?['diagnosis']?.toString() ?? '';

      _bumpPanelKey();

      final screenWidth = MediaQuery.of(context).size.width;
      if (screenWidth < 900) _tabController.animateTo(1);
    } finally {
      if (mounted) setState(() => _isSaving = false);
    }
  }

  Future<void> _skipPatient() async {
    if (_selectedPatientData == null || _isSaving || !mounted) return;

    final patient = Map<String, dynamic>.from(_selectedPatientData!);
    final serial = (patient['serial'] ?? patient['id'])?.toString();
    if (serial == null || serial.isEmpty) return;

    setState(() => _isSaving = true);
    try {
      final nowIso = DateTime.now().toIso8601String();
      patient['status'] = 'skipped';
      patient['skippedAt'] = nowIso;
      patient['skippedBy'] = _username ?? widget.doctorName;
      patient['updatedAt'] = nowIso;

      // Clear idempotency key so receptionist can issue a new token if patient returns
      final patientId = (patient['patientId'] ?? '').toString();
      final dateKey = CampSessionService.getDateKeyFromSerial(serial);
      if (patientId.isNotEmpty) {
        final idempotencyKey = '${widget.branchId}_${patientId}_$dateKey';
        try {
          if (Hive.isBoxOpen('issued_token_keys')) {
            await Hive.box('issued_token_keys').delete(idempotencyKey);
          }
        } catch (_) {}
      }

      // 1. Save locally in Hive (< 5ms)
      await LocalStorageService.saveEntryLocal(widget.branchId, serial, patient);

      // 2. Broadcast via LAN
      try {
        RealtimeManager().sendMessage(RealtimeEvents.payload(
          type: RealtimeEvents.saveEntry,
          branchId: widget.branchId,
          data: patient,
        ));
      } catch (e) {
        debugPrint('[DoctorScreen] Skip LAN broadcast failed: $e');
      }

      // 3. Enqueue to sync queue & background Firestore sync (ONLY when offline / not connected to LAN server)
      if (!RealtimeManager().isConnected) {
        try {
          await LocalStorageService.enqueueSync({
            'type': 'save_entry',
            'branchId': widget.branchId,
            'serial': serial,
            'dateKey': dateKey,
            'data': patient,
          });
          unawaited(SyncService().triggerUpload());
        } catch (_) {}

        // Background non-blocking Firestore sync (never freeze UI)
        final queueType = resolveQueueType(patient['queueType']?.toString() ?? patient['status']?.toString());
        final campDocKey = CampSessionService.getCampDateDocId(
          branchId: widget.branchId,
          dateKey: dateKey,
          campId: patient['campId']?.toString() ?? patient['dispensaryId']?.toString(),
          dispensaryTag: patient['dispensaryTag']?.toString(),
          serial: serial,
        );
        unawaited(FirebaseFirestore.instance
            .collection('branches').doc(widget.branchId)
            .collection('serials').doc(campDocKey)
            .collection(queueType)
            .doc(serial)
            .set({
          'status': 'skipped',
          'skippedAt': nowIso,
          'skippedBy': _username ?? widget.doctorName,
          'updatedAt': FieldValue.serverTimestamp(),
        }, SetOptions(merge: true)).timeout(const Duration(seconds: 3)).catchError((e) {
          debugPrint('[DoctorScreen] Skip Firestore deferred: $e');
        }));
      }

      if (mounted) {
        AppToast.showSnackBar(context, 
          SnackBar(
            content: Text('⏩ Patient #$serial skipped'),
            backgroundColor: SoftPalette.orange400,
            duration: const Duration(seconds: 2),
            behavior: SnackBarBehavior.floating,
          ),
        );
      }

      // Clear current inputs immediately
      _complaintController.clear();
      _diagnosisController.clear();
      _prescriptions.clear();
      _labResults.clear();
      _selectedPatientData = null;
      _isSaving = false; // Reset so next patient can be selected without being blocked!

      // Auto-select the next waiting patient from today's tokens only. Yesterday's waiting
      // tokens used to be included and, sorting first by serial, were always opened next.
      final userDisp = CampSessionService.getActiveCamp(widget.branchId);
      final todayKey = CampSessionService.resolveShiftAndDateKey(null, widget.branchId).dateKey;
      final waiting = LocalStorageService.getLocalEntries(
        widget.branchId,
        dispensaryId: userDisp,
        filterByCamp: true,
      ).where((e) {
        final st = (e['status'] ?? '').toString().toLowerCase().trim();
        if (st != 'waiting') return false;
        return CampSessionService.isTokenOnDate(e, todayKey, widget.branchId) ||
            CampSessionService.isLateNightCarryOver(e, widget.branchId);
      }).toList();

      if (waiting.isNotEmpty) {
        waiting.sort((a, b) {
          final sA = (a['serial'] ?? '').toString();
          final sB = (b['serial'] ?? '').toString();
          return sA.compareTo(sB);
        });
        await _selectPatient(waiting.first);
      } else {
        if (mounted) setState(() {});
      }
    } finally {
      if (mounted && _isSaving) setState(() => _isSaving = false);
    }
  }

  void _applyRepeatData(Map<String, dynamic> d) {
    if (!mounted) return;
    final unwrapped = PatientHistoryPanel.unwrapPrescriptionData(d);

    // Collect prescriptions from all possible keys
    final rawMeds = unwrapped['prescriptions'] ??
        unwrapped['medicines'] ??
        unwrapped['items'] ??
        unwrapped['oralMedicines'] ??
        unwrapped['prescriptionList'] ??
        unwrapped['dispensedMedicines'];

    final parsedMeds = <Map<String, dynamic>>[];
    if (rawMeds is List) {
      for (final item in rawMeds) {
        if (item is Map) {
          final m = Map<String, dynamic>.from(item);
          final name = (m['name'] ?? m['displayName'] ?? m['medicineName'] ?? m['medName'] ?? m['title'] ?? '').toString().trim();
          if (name.isNotEmpty) {
            m['name'] = name;
            m['displayName'] = name;
            m['_repeat'] = true; // the right panel matches it to today's stock
            parsedMeds.add(m);
          }
        } else if (item is String && item.trim().isNotEmpty) {
          parsedMeds.add({
            'name': item.trim(),
            'displayName': item.trim(),
            'type': 'Tablet',
            'dosage': '1',
            // Old record kept only the name; its timing is unknown. Once a day, as for an
            // empty timing box (never a silent twice a day) — the doctor edits it if needed.
            'timing': '1+0+0',
            'quantity': 1,
            '_repeat': true,
          });
        }
      }
    }

    // Collect labs
    final rawLabs = unwrapped['labResults'] ??
        unwrapped['labTests'] ??
        unwrapped['tests'] ??
        unwrapped['lab_tests'] ??
        unwrapped['physiotherapies'];

    final parsedLabs = <Map<String, dynamic>>[];
    if (rawLabs is List) {
      for (final item in rawLabs) {
        if (item is Map) {
          parsedLabs.add(Map<String, dynamic>.from(item));
        } else if (item is String && item.trim().isNotEmpty) {
          parsedLabs.add({'name': item.trim()});
        }
      }
    }

    final complaint = (unwrapped['complaint'] ?? unwrapped['condition'] ?? unwrapped['patientCondition'] ?? '').toString().trim();
    final diagnosis = (unwrapped['diagnosis'] ?? unwrapped['patientDiagnosis'] ?? unwrapped['finalDiagnosis'] ?? '').toString().trim();

    setState(() {
      if (complaint.isNotEmpty) _complaintController.text = complaint;
      if (diagnosis.isNotEmpty) _diagnosisController.text = diagnosis;
      _prescriptions
        ..clear()
        ..addAll(parsedMeds);
      _labResults
        ..clear()
        ..addAll(parsedLabs);
      _bumpPanelKey();
    });

    AppToast.showSnackBar(context, 
      SnackBar(
        content: Text('🔁 Repeated — ${_prescriptions.length} medicine(s), ${_labResults.length} lab test(s)'),
        backgroundColor: SoftPalette.teal550,
        duration: const Duration(seconds: 3),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  void _openFullHistory() {
    if (_selectedPatientData == null) return;
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => PatientHistoryPage(
          branchId: widget.branchId,
          patientData: _selectedPatientData!,
          onRepeatLast: (raw) {
            _applyRepeatData(raw);
            final screenWidth = MediaQuery.of(context).size.width;
            if (screenWidth < 900) _tabController.animateTo(1);
          },
        ),
      ),
    );
  }

  Future<void> _openTemplatesManagerDialog(bool isDark) async {
    showDialog(
      context: context,
      builder: (dialogCtx) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            return FutureBuilder<List<Map<String, dynamic>>>(
              future: PrescriptionTemplateService.loadTemplates(
                widget.branchId,
                doctorId: widget.doctorId,
              ),
              builder: (context, snapshot) {
                final templates = snapshot.data ?? [];
                final isLoading = snapshot.connectionState == ConnectionState.waiting;

                return AlertDialog(
                  backgroundColor: isDark ? SoftPalette.slate800 : SoftPalette.gray50,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
                  titlePadding: EdgeInsets.zero,
                  contentPadding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
                  title: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
                    decoration: BoxDecoration(
                      color: isDark ? SoftPalette.slate900 : SoftPalette.teal700,
                      borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
                    ),
                    child: Row(
                      children: [
                        Container(
                          padding: const EdgeInsets.all(8),
                          decoration: BoxDecoration(
                            color: SoftPalette.gray50.withValues(alpha: 0.15),
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: const Icon(Icons.collections_bookmark_rounded, color: SoftPalette.gray50, size: 20),
                        ),
                        const SizedBox(width: 12),
                        const Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                'Disease Templates & Presets',
                                style: TextStyle(color: SoftPalette.gray50, fontSize: 16, fontWeight: FontWeight.bold),
                              ),
                              SizedBox(height: 2),
                              Text(
                                'Manage re-usable clinical templates for rapid prescribing',
                                style: TextStyle(color: SoftPalette.gray50A70, fontSize: 11),
                              ),
                            ],
                          ),
                        ),
                        IconButton(
                          icon: const Icon(Icons.close_rounded, color: SoftPalette.gray50A70),
                          onPressed: () => Navigator.pop(dialogCtx),
                        ),
                      ],
                    ),
                  ),
                  content: SizedBox(
                    width: 580,
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (isLoading)
                          Padding(
                            padding: EdgeInsets.symmetric(vertical: 40),
                            child: Center(child: CircularProgressIndicator(color: context.adapt(_teal))),
                          )
                        else if (templates.isEmpty)
                          Padding(
                            padding: const EdgeInsets.symmetric(vertical: 30),
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(Icons.bookmark_border_rounded, size: 48, color: isDark ? SoftPalette.slate600 : SoftPalette.gray300),
                                const SizedBox(height: 12),
                                Text(
                                  'No Presets Created Yet',
                                  style: TextStyle(
                                    fontWeight: FontWeight.bold,
                                    fontSize: 15,
                                    color: isDark ? SoftPalette.gray50 : SoftPalette.gray700,
                                  ),
                                ),
                                const SizedBox(height: 6),
                                Text(
                                  'Save disease prescriptions directly from the consultation workspace to quickly apply them across visits.',
                                  textAlign: TextAlign.center,
                                  style: TextStyle(
                                    fontSize: 12,
                                    color: isDark ? SoftPalette.slate350 : SoftPalette.gray500,
                                  ),
                                ),
                              ],
                            ),
                          )
                        else
                          ConstrainedBox(
                            constraints: const BoxConstraints(maxHeight: 420),
                            child: ListView.separated(
                              shrinkWrap: true,
                              itemCount: templates.length,
                              separatorBuilder: (_, __) => const SizedBox(height: 10),
                              itemBuilder: (ctx, i) {
                                final tpl = templates[i];
                                final name = tpl['name']?.toString() ?? 'Template';
                                final iconData = PrescriptionTemplateService.getIcon(tpl['icon']?.toString());
                                final condition = tpl['condition']?.toString() ?? tpl['complaint']?.toString() ?? '';
                                final diagnosis = tpl['diagnosis']?.toString() ?? '';
                                final meds = (tpl['medicines'] as List?) ?? [];
                                final labs = (tpl['labResults'] as List?) ?? (tpl['tests'] as List?) ?? [];

                                return Container(
                                  padding: const EdgeInsets.all(12),
                                  decoration: BoxDecoration(
                                    color: isDark ? SoftPalette.slate900 : SoftPalette.gray50,
                                    borderRadius: BorderRadius.circular(14),
                                    border: Border.all(
                                      color: isDark ? SoftPalette.slate700 : SoftPalette.slate150,
                                      width: 1,
                                    ),
                                  ),
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      Row(
                                        children: [
                                          Container(
                                            padding: const EdgeInsets.all(8),
                                            decoration: BoxDecoration(
                                              color: isDark ? SoftPalette.teal700 : SoftPalette.teal100m,
                                              borderRadius: BorderRadius.circular(10),
                                            ),
                                            child: FaIcon(iconData, size: 14, color: isDark ? SoftPalette.teal300 : _teal),
                                          ),
                                          const SizedBox(width: 10),
                                          Expanded(
                                            child: Column(
                                              crossAxisAlignment: CrossAxisAlignment.start,
                                              children: [
                                                Text(
                                                  name,
                                                  style: TextStyle(
                                                    fontWeight: FontWeight.bold,
                                                    fontSize: 14,
                                                    color: isDark ? SoftPalette.gray50 : SoftPalette.slate900,
                                                  ),
                                                ),
                                                if (diagnosis.isNotEmpty)
                                                  Text(
                                                    'Dx: $diagnosis',
                                                    style: TextStyle(
                                                      fontSize: 11.5,
                                                      color: isDark ? SoftPalette.slate350 : SoftPalette.gray550,
                                                    ),
                                                    maxLines: 1,
                                                    overflow: TextOverflow.ellipsis,
                                                  ),
                                              ],
                                            ),
                                          ),
                                          if (_selectedPatientData != null)
                                            ElevatedButton.icon(
                                              onPressed: () {
                                                Navigator.pop(dialogCtx);
                                                _applyRepeatData({
                                                  'complaint': condition,
                                                  'diagnosis': diagnosis,
                                                  'prescriptions': meds,
                                                  'labResults': labs,
                                                });
                                              },
                                              icon: const Icon(Icons.bolt_rounded, size: 14),
                                              label: const Text('Apply', style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.bold)),
                                              style: ElevatedButton.styleFrom(
                                                backgroundColor: isDark ? SoftPalette.teal500 : _teal,
                                                foregroundColor: SoftPalette.gray50,
                                                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                                                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                                                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                                              ),
                                            ),
                                          const SizedBox(width: 6),
                                          IconButton(
                                            icon: Icon(Icons.delete_outline_rounded, size: 18, color: context.adapt(SoftPalette.red400)),
                                            tooltip: 'Delete Template',
                                            padding: EdgeInsets.zero,
                                            constraints: const BoxConstraints(),
                                            onPressed: () async {
                                              final confirmed = await showDialog<bool>(
                                                context: context,
                                                builder: (confirmCtx) => AlertDialog(
                                                  title: const Text('Delete Template?'),
                                                  content: Text('Are you sure you want to delete "$name"?'),
                                                  actions: [
                                                    TextButton(
                                                      onPressed: () => Navigator.pop(confirmCtx, false),
                                                      child: const Text('Cancel'),
                                                    ),
                                                    ElevatedButton(
                                                      onPressed: () => Navigator.pop(confirmCtx, true),
                                                      style: ElevatedButton.styleFrom(backgroundColor: SoftPalette.red400),
                                                      child: const Text('Delete', style: TextStyle(color: SoftPalette.gray50)),
                                                    ),
                                                  ],
                                                ),
                                              );
                                              if (confirmed == true) {
                                                await PrescriptionTemplateService.deleteTemplate(
                                                  widget.branchId,
                                                  tpl['id']?.toString() ?? '',
                                                  doctorId: widget.doctorId,
                                                );
                                                setDialogState(() {});
                                              }
                                            },
                                          ),
                                        ],
                                      ),
                                      if (meds.isNotEmpty) ...[
                                        const SizedBox(height: 8),
                                        Wrap(
                                          spacing: 4,
                                          runSpacing: 4,
                                          children: meds.map<Widget>((m) {
                                            final mName = m['name']?.toString() ?? '';
                                            final mTiming = m['timing']?.toString() ?? m['dose']?.toString() ?? '';
                                            return Container(
                                              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                              decoration: BoxDecoration(
                                                color: isDark ? SoftPalette.slate800 : SoftPalette.slate150,
                                                borderRadius: BorderRadius.circular(6),
                                              ),
                                              child: Text(
                                                mTiming.isNotEmpty ? '$mName ($mTiming)' : mName,
                                                style: TextStyle(
                                                  fontSize: 10,
                                                  color: isDark ? SoftPalette.slate200 : SoftPalette.slate700,
                                                ),
                                              ),
                                            );
                                          }).toList(),
                                        ),
                                      ],
                                    ],
                                  ),
                                );
                              },
                            ),
                          ),
                      ],
                    ),
                  ),
                );
              },
            );
          },
        );
      },
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

  /// Pending requests (patient edits, token exceptions, stock requests, etc.)
  /// waiting for this doctor's approval (shown as a badge).
  int _pendingApprovals() {
    final normBranch = widget.branchId.toLowerCase().trim();
    final seenIds = <String>{};
    var n = 0;

    bool branchMatches(String b) {
      if (normBranch.isEmpty || b.isEmpty || b == normBranch) return true;
      if (normBranch.contains('gujrat') && (b == 'grt' || b == 'gjt' || b.contains('gujrat'))) return true;
      if (normBranch == 'grt' && (b.contains('gujrat') || b == 'gjt')) return true;
      if (normBranch.contains('sialkot') && (b == 'skt' || b.contains('sialkot'))) return true;
      if (normBranch == 'skt' && b.contains('sialkot')) return true;
      if (normBranch.contains('rawalpindi') && (b == 'rwp' || b.contains('rawalpindi'))) return true;
      if (normBranch == 'rwp' && b.contains('rawalpindi')) return true;
      return false;
    }

    void scanBox(String boxName, {bool defaultIsStock = false}) {
      if (!Hive.isBoxOpen(boxName)) return;
      final box = Hive.box(boxName);
      for (final entry in box.toMap().entries) {
        final v = entry.value;
        if (v is! Map) continue;
        final id = (v['requestId'] ?? v['id'] ?? entry.key).toString();
        if (!seenIds.add(id)) continue;
        final b = (v['branchId'] ?? '').toString().toLowerCase().trim();
        final st = (v['status'] ?? (defaultIsStock ? 'pending' : '')).toString().toLowerCase().trim();
        final type = (v['requestType'] ?? v['type'] ?? (defaultIsStock ? 'add_stock' : '')).toString().toLowerCase().trim();
        final isStockOnly = type == 'add_stock' || type == 'edit_medicine' || type == 'delete_medicine';
        if (st == 'pending' &&
            branchMatches(b) &&
            (_canApproveRequests || !isStockOnly)) {
          n++;
        }
      }
    }

    scanBox('local_edit_requests');
    scanBox(LocalStorageService.restockRequestsBox, defaultIsStock: true);
    return n;
  }

  Box get _requestsBox => Hive.isBoxOpen('local_edit_requests')
      ? Hive.box('local_edit_requests')
      : (Hive.isBoxOpen('app_settings') ? Hive.box('app_settings') : Hive.box(LocalStorageService.entriesBox));

  Listenable get _requestsListenable {
    final listenables = <Listenable>[
      DebouncedBoxListenable.shared(_requestsBox),
      if (Hive.isBoxOpen(LocalStorageService.restockRequestsBox))
        DebouncedBoxListenable.shared(Hive.box(LocalStorageService.restockRequestsBox)),
    ];
    return listenables.length == 1 ? listenables.first : Listenable.merge(listenables);
  }

  void _openUserSettings() => DispensaryUserSettingsDialog.show(
        context,
        branchId: widget.branchId,
        onUserUpdated: () {
          if (mounted) setState(() => _fetchDoctorName());
        },
      );

  void _openInventory() => Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => InventoryPage(
            branchId: widget.branchId,
            isDoctor: true,
            isSupervisor: _canApproveRequests,
            isDispenser: false,
          ),
        ),
      );

  void _openRequests() => Navigator.push(
        context,
        MaterialPageRoute(builder: (_) => RequestPage(branchId: widget.branchId, isSupervisor: true)),
      ).then((_) {
        if (mounted) setState(() {});
      });

  Widget _buildHeaderIconButton({
    required bool isDark,
    required bool isMobile,
    required String tooltip,
    required IconData icon,
    required VoidCallback onTap,
    int badge = 0,
  }) {
    final size = isMobile ? 36.0 : 40.0;
    final button = Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Container(
          height: size,
          width: size,
          decoration: BoxDecoration(
            color: isDark ? SoftPalette.slate700 : SoftPalette.slate100,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: isDark ? SoftPalette.slate600 : SoftPalette.slate200,
              width: 1,
            ),
          ),
          child: Icon(
            icon,
            size: 20,
            color: isDark ? SoftPalette.slate350 : SoftPalette.emerald600,
          ),
        ),
      ),
    );

    return Tooltip(
      message: tooltip,
      child: Badge(
        isLabelVisible: badge > 0,
        offset: const Offset(2, -2),
        backgroundColor: SoftPalette.orange350,
        label: Text(
          badge > 99 ? '99+' : '$badge',
          style: const TextStyle(
            fontSize: 9,
            fontWeight: FontWeight.bold,
            color: SoftPalette.gray50,
          ),
        ),
        child: button,
      ),
    );
  }

  /// Header action buttons placed between the connection pill and the ⋮ menu:
  /// Requests (notifications icon + pending count badge) and Stock (inventory).
  List<Widget> _buildDoctorHeaderButtons({
    required bool isDark,
    required bool isMobile,
    required int pending,
  }) =>
      [
        _buildHeaderIconButton(
          isDark: isDark,
          isMobile: isMobile,
          tooltip: pending > 0 ? 'Requests & approvals ($pending pending)' : 'Requests & approvals',
          icon: pending > 0 ? Icons.notifications_active_outlined : Icons.notifications_outlined,
          badge: pending,
          onTap: _openRequests,
        ),
        SizedBox(width: isMobile ? 6 : 8),
        _buildHeaderIconButton(
          isDark: isDark,
          isMobile: isMobile,
          tooltip: 'Medicine inventory (Stock)',
          icon: Icons.inventory_2_outlined,
          onTap: _openInventory,
        ),
      ];

  /// The Doctor's own items, for the "Desk" group of the shared ⋮ menu.
  List<GmwfMenuAction> _deskActions(bool isDark) => [
        GmwfMenuAction(
          id: 'templates',
          label: 'Disease templates & presets',
          icon: Icons.collections_bookmark_outlined,
          onTap: () => _openTemplatesManagerDialog(isDark),
        ),
      ];

  /// Small ⋮ menu for the slim row when the Doctor screen is embedded in the
  /// executive app (the app's own header already has sync, theme and logout).
  Widget _buildDoctorActionMenu(bool isDark) {
    final actions = [
      ..._deskActions(isDark),
      GmwfMenuAction(id: 'settings', label: 'User settings', icon: Icons.manage_accounts_outlined, onTap: _openUserSettings),
    ];
    final menuBtn = Container(
      width: 36,
      height: 36,
      decoration: BoxDecoration(
        color: isDark ? SoftPalette.slate700 : SoftPalette.slate100,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: isDark ? SoftPalette.slate600 : SoftPalette.slate200),
      ),
      child: Icon(Icons.more_vert_rounded, size: 20, color: isDark ? SoftPalette.slate350 : SoftPalette.emerald600),
    );
    return PopupMenuButton<String>(
      tooltip: 'Menu',
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      color: isDark ? SoftPalette.slate800 : SoftPalette.gray50,
      offset: const Offset(0, 42),
      onSelected: (id) {
        for (final a in actions) {
          if (a.id == id) a.onTap();
        }
      },
      itemBuilder: (_) => [
        for (final a in actions)
          PopupMenuItem<String>(
            value: a.id,
            child: Row(children: [
              Icon(a.icon, size: 18, color: isDark ? SoftPalette.sky350 : SoftPalette.emerald600),
              const SizedBox(width: 10),
              Expanded(
                child: Text(a.label,
                    style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: isDark ? SoftPalette.gray50 : SoftPalette.slate800)),
              ),
              if (a.badge > 0)
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                  decoration: BoxDecoration(color: SoftPalette.orange350, borderRadius: BorderRadius.circular(8)),
                  child: Text('${a.badge}', style: const TextStyle(fontSize: 10.5, fontWeight: FontWeight.w700, color: SoftPalette.gray50)),
                ),
            ]),
          ),
      ],
      child: menuBtn,
    );
  }

  /// The shared desk header (same as Hybrid, Dispensar and Receptionist): one
  /// connection pill, Requests (notifications) + Stock buttons, and the grouped
  /// ⋮ menu. Rebuilt when requests change, for the notifications badge.
  PreferredSizeWidget _buildAppBar(bool isMobile, bool isDark) {
    final docRaw = (_username?.isNotEmpty == true ? _username! : widget.doctorName).trim();
    final docDisplay = docRaw.isEmpty
        ? ''
        : (docRaw.toLowerCase().startsWith('dr') ? docRaw : 'Dr. $docRaw');
    final branchDisplay = CampSessionService.getBranchAndCampDisplayName(
      branchName: _branchName ?? LocalStorageService.getBranchName(widget.branchId),
      branchId: widget.branchId,
      campId: CampSessionService.getActiveCamp(widget.branchId),
    );
    final subtitleText = docDisplay.isNotEmpty ? '$branchDisplay · $docDisplay' : branchDisplay;

    GmwfAppBar bar(int pending) => GmwfAppBar(
          title: 'Doctor',
          subtitle: subtitleText,
          onTitleLongPress: _openUserSettings,
          titleTooltip: 'Long press for Settings',
          connectionStatus: _connectionStatus,
          onRetryConnection: () => ConnectionManager().reconnectNow(),
          isOnline: _online,
          isSyncing: _isSyncing,
          onSync: _forceSync,
          onUserSettings: _openUserSettings,
          onLogout: _logout,
          isFloating: false,
          trailingActions: _buildDoctorHeaderButtons(
            isDark: isDark,
            isMobile: isMobile,
            pending: pending,
          ),
          deskActions: _deskActions(isDark),
          bottom: isMobile
              ? PreferredSize(
                  preferredSize: const Size.fromHeight(44),
                  child: TabBar(
                    controller: _tabController,
                    indicatorColor: SoftPalette.emerald400,
                    labelColor: SoftPalette.emerald400,
                    unselectedLabelColor: SoftPalette.gray350,
                    labelStyle: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold),
                    tabs: const [
                      Tab(icon: Icon(Icons.people, size: 18), text: 'Queue'),
                      Tab(icon: Icon(Icons.medical_services, size: 18), text: 'Prescription'),
                      Tab(icon: Icon(Icons.history, size: 18), text: 'History'),
                    ],
                  ),
                )
              : null,
        );

    return PreferredSize(
      preferredSize: bar(0).preferredSize,
      child: ListenableBuilder(
        listenable: _requestsListenable,
        builder: (context, _) => bar(_pendingApprovals()),
      ),
    );
  }
  Widget _buildPrescriptionPanel() {
    if (_selectedPatientData == null) {
      final isDark = _isDark;
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(16),
              child: Image.asset(
                'assets/images/doctor_select_patient.jpg',
                width: 140,
                height: 140,
                fit: BoxFit.cover,
              ),
            ),
            const SizedBox(height: 14),
            Text('Select a patient from the queue',
                style: TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w700,
                  color: isDark ? SoftPalette.gray50 : SoftPalette.slate900,
                ),
                textAlign: TextAlign.center),
            const SizedBox(height: 4),
            Text('Vitals, prescription, and visit history will appear here',
                style: TextStyle(
                  fontSize: 12.5,
                  color: isDark ? SoftPalette.slate400 : SoftPalette.slate550,
                ),
                textAlign: TextAlign.center),
          ]),
        ),
      );
    }

    final resolvedQueueType = resolveQueueType(
      (_selectedPatientData!['queueType']?.toString().isNotEmpty == true
              ? _selectedPatientData!['queueType']
              : _selectedPatientData!['status'])
          ?.toString(),
    );

    return DoctorRightPanel(
      key: ValueKey(_rightPanelKey),
      branchId: widget.branchId,
      selectedPatientData: _selectedPatientData,
      serialId: _selectedPatientData!['serial']?.toString() ?? '',
      doctorId: widget.doctorId,
      doctorName: _username?.isNotEmpty == true ? _username! : widget.doctorName,
      isPhysiotherapist: _doctorDegree?.toLowerCase().contains('physio') == true ||
                         _doctorDegree?.toLowerCase().contains('dpt') == true,
      queueType: resolvedQueueType,
      complaintController: _complaintController,
      diagnosisController: _diagnosisController,
      prescriptions: _prescriptions,
      labResults: _labResults,
      isSaving: _isSaving,
      onAddLabResult: () { if (mounted) setState(() => _labResults.add({'name': 'New Lab Test'})); },
      onRemoveLabResult: (i) { if (mounted) setState(() => _labResults.removeAt(i)); },
      onRemoveMedicine: (i) { if (mounted) setState(() => _prescriptions.removeAt(i)); },
      onAddMedicine: (med) { if (mounted) setState(() {}); },
      onEditMedicine: (med) {
        final idx = _prescriptions.indexWhere((m) => m['name'] == med['name']);
        if (idx != -1) setState(() => _prescriptions[idx] = med);
      },
      onSavePrescription: () async {},
      onEntryCompleted: () => setState(() {
        _selectedPatientData = null;
        _complaintController.clear();
        _diagnosisController.clear();
        _prescriptions.clear();
        _labResults.clear();
        _rightPanelKey++;
      }),
      onRepeatData: _applyRepeatData,
      onSkipPatient: _skipPatient,
    );
  }

  Widget _buildHistoryPanel() {
    final isDark = _isDark;
    if (_selectedPatientData == null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(14),
                child: Image.asset(
                  'assets/images/doctor_empty_history.jpg',
                  width: 112,
                  height: 112,
                  fit: BoxFit.cover,
                ),
              ),
              const SizedBox(height: 12),
              Text('Select a patient to view history',
                  style: TextStyle(
                    fontSize: 13.5,
                    fontWeight: FontWeight.w600,
                    color: isDark ? SoftPalette.slate350 : SoftPalette.slate600,
                  ),
                  textAlign: TextAlign.center),
            ],
          ),
        ),
      );
    }
    final brandColor = Theme.of(context).colorScheme.primary;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(14, 12, 12, 10),
          child: Row(children: [
            Icon(Icons.history_rounded, color: brandColor, size: 18),
            const SizedBox(width: 8),
            Expanded(
              child: Text('Visit history',
                  style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w700,
                      color: isDark ? SoftPalette.gray50 : SoftPalette.slate900)),
            ),
            InkWell(
              onTap: _openFullHistory,
              borderRadius: BorderRadius.circular(6),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      'All visits',
                      style: TextStyle(
                        fontSize: 11.5,
                        fontWeight: FontWeight.w600,
                        color: isDark ? SoftPalette.slate350 : brandColor,
                      ),
                    ),
                    const SizedBox(width: 3),
                    Icon(Icons.chevron_right_rounded,
                        size: 14, color: isDark ? SoftPalette.slate350 : brandColor),
                  ],
                ),
              ),
            ),
          ]),
        ),
        Divider(
          height: 1,
          color: isDark ? SoftPalette.slate700.withValues(alpha: 0.7) : SoftPalette.slate150,
        ),
        Expanded(
          child: PatientHistory(
            branchId: widget.branchId,
            patientData: _selectedPatientData,
            compactMode: true,
            onRepeatLast: _applyRepeatData,
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final isDark = _isDark;
    final screenWidth = MediaQuery.of(context).size.width;
    final isMobile = screenWidth < 900;

    final scaffoldBg = Theme.of(context).scaffoldBackgroundColor;

    final body = DeskBackdrop(
      child: Column(
        children: [
          ClockSkewWarningBanner(branchId: widget.branchId),
          Expanded(
            child: isMobile ? _buildMobileBody(isDark) : _buildDesktopBody(isDark),
          ),
        ],
      ),
    );

    // Embedded (executive shell): the shell header replaces the title bar, but
    // the phone tabs and the action menu (templates, inventory, approvals) exist
    // nowhere else, so they stay in one slim row.
    if (widget.isEmbedded) {
      return Column(children: [
        _buildEmbeddedBar(isMobile, isDark),
        Expanded(child: body),
      ]);
    }

    return Scaffold(
      backgroundColor: scaffoldBg,
      appBar: _buildAppBar(isMobile, isDark),
      body: body,
    );
  }

  Widget _buildEmbeddedBar(bool isMobile, bool isDark) {
    return ListenableBuilder(
      listenable: _requestsListenable,
      builder: (context, _) {
        final pending = _pendingApprovals();
        return Material(
          color: isDark ? SoftPalette.slate800 : SoftPalette.gray50,
          child: Container(
            height: 48,
            decoration: BoxDecoration(
              border: Border(bottom: BorderSide(color: isDark ? SoftPalette.slate700 : SoftPalette.slate150)),
            ),
            child: Row(children: [
              if (isMobile)
                Expanded(
                  child: TabBar(
                    controller: _tabController,
                    indicatorColor: isDark ? SoftPalette.emerald400 : SoftPalette.emerald600,
                    labelColor: isDark ? SoftPalette.emerald400 : SoftPalette.emerald600,
                    unselectedLabelColor: isDark ? SoftPalette.slate350 : SoftPalette.slate550,
                    labelStyle: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold),
                    tabs: const [
                      Tab(height: 46, iconMargin: EdgeInsets.zero, icon: Icon(Icons.people, size: 16), text: 'Queue'),
                      Tab(height: 46, iconMargin: EdgeInsets.zero, icon: Icon(Icons.medical_services, size: 16), text: 'Prescription'),
                      Tab(height: 46, iconMargin: EdgeInsets.zero, icon: Icon(Icons.history, size: 16), text: 'History'),
                    ],
                  ),
                )
              else
                const Spacer(),
              ..._buildDoctorHeaderButtons(
                isDark: isDark,
                isMobile: true,
                pending: pending,
              ),
              const SizedBox(width: 6),
              _buildDoctorActionMenu(isDark),
              const SizedBox(width: 8),
            ]),
          ),
        );
      },
    );
  }

  Widget _buildMobileBody(bool isDark) {
    return TabBarView(
      controller: _tabController,
      children: [
        Padding(
          padding: const EdgeInsets.all(8),
          child: DeskCard(
            accentTop: true,
            child: PatientQueue(
              branchId: widget.branchId,
              doctorId: widget.doctorId,
              doctorName: _username?.isNotEmpty == true ? _username! : widget.doctorName,
              selectedPatient: _selectedPatientData,
              onPatientSelected: _selectPatient,
              isSaving: _isSaving,
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.all(8),
          child: Column(children: [
            if (_selectedPatientData != null)
              DeskCard(
                margin: const EdgeInsets.only(bottom: 8),
                radius: 12,
                child: PatientInfo(
                  patientData: _selectedPatientData,
                  doctorId: widget.doctorId,
                  doctorName: _username?.isNotEmpty == true ? _username! : widget.doctorName,
                  branchId: widget.branchId,
                  onSkipPatient: _skipPatient,
                  onVitalsUpdated: (updatedVitals) {
                    if (mounted && _selectedPatientData != null) {
                      setState(() {
                        _selectedPatientData!['vitals'] = updatedVitals;
                      });
                    }
                  },
                ),
              ),
            Expanded(
              child: DeskCard(
                accentTop: true,
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: _buildPrescriptionPanel(),
                ),
              ),
            ),
          ]),
        ),
        Padding(
          padding: const EdgeInsets.all(8),
          child: DeskCard(
            accentTop: true,
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: _buildHistoryPanel(),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildDesktopBody(bool isDark) {
    return Padding(
      padding: const EdgeInsets.all(14),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // ── Column 1 (Left): Today's Queue ─────────────────────────────
          Expanded(
            flex: 25,
            child: DeskCard(
              accentTop: true,
              child: PatientQueue(
                branchId: widget.branchId,
                doctorId: widget.doctorId,
                doctorName: _username?.isNotEmpty == true ? _username! : widget.doctorName,
                selectedPatient: _selectedPatientData,
                onPatientSelected: _selectPatient,
                isSaving: _isSaving,
              ),
            ),
          ),
          const SizedBox(width: 14),

          // ── Column 2 (Center): Patient Info + Prescription ─────────────
          Expanded(
            flex: 50,
            child: Column(
              children: [
                if (_selectedPatientData != null)
                  DeskCard(
                    margin: const EdgeInsets.only(bottom: 14),
                    child: PatientInfo(
                      patientData: _selectedPatientData,
                      doctorId: widget.doctorId,
                      doctorName: _username?.isNotEmpty == true ? _username! : widget.doctorName,
                      branchId: widget.branchId,
                      onSkipPatient: _skipPatient,
                      onVitalsUpdated: (updatedVitals) {
                        if (mounted && _selectedPatientData != null) {
                          setState(() {
                            _selectedPatientData!['vitals'] = updatedVitals;
                          });
                        }
                      },
                    ),
                  ),
                Expanded(
                  child: DeskCard(
                    accentTop: true,
                    child: _buildPrescriptionPanel(),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 14),

          // ── Column 3 (Right, Full Height): Visit History ───────────────
          Expanded(
            flex: 25,
            child: DeskCard(
              accentTop: true,
              child: _buildHistoryPanel(),
            ),
          ),
        ],
      ),
    );
  }

  void _onActiveCampChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _tabController.dispose();
    _syncDebounce?.cancel();
    _refreshDebounce?.cancel();
    // [BUG-13] Unregister from ConnectionManager's listener list
    _removeReconnectListener?.call();
    CampSessionService.activeCampNotifier.removeListener(_onActiveCampChanged);
    // The LAN link is shared by every desk screen and only logout stops it. Stopping it here
    // (e.g. when this screen was replaced or popped) left the PC disconnected, with Retry
    // doing nothing, until the next login.
    _connectionSub?.cancel();
    _connSub?.cancel();
    _realtimeSub?.cancel();
    _complaintController.dispose();
    _diagnosisController.dispose();
    super.dispose();
  }
}
