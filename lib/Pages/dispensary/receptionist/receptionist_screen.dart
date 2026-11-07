// lib/pages/dispensary/receptionist/receptionist_screen.dart

import 'package:gmwf/utils/perf_trace.dart';
import 'package:gmwf/design/tokens/soft_palette.dart';
import 'package:gmwf/utils/debounced_box_listenable.dart';
import 'package:gmwf/utils/token_order.dart';
import 'dart:async';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:intl/intl.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:gmwf/design/components/flushbar_compat.dart';
import 'package:gmwf/services/auth_service.dart';
import 'package:gmwf/services/local_storage_service.dart';
import 'package:gmwf/services/local_storage_service.dart' as lss;
import 'package:gmwf/services/sync_service.dart';
import 'package:gmwf/realtime/connection_manager.dart';
import 'package:gmwf/realtime/realtime_manager.dart';
import 'package:gmwf/realtime/realtime_events.dart';
import 'package:gmwf/services/camp_session_service.dart';
import 'package:gmwf/widgets/clock_skew_warning_banner.dart';
import 'package:gmwf/widgets/gmwf_app_bar.dart';
import 'package:gmwf/widgets/update_dialog_widget.dart';
import '../user_settings_dialog.dart';
import '../../../utils/notification_deduper.dart';
import 'package:gmwf/services/cloud_messaging_service.dart';
import 'patient_register.dart';
import 'token_screen.dart';
import '../widgets/desk_summary_card.dart';
import '../widgets/pharmacy_pane.dart';
import '../widgets/connection_status_same.dart';
import 'token_tally.dart';
import 'package:gmwf/design/design_system.dart';
import '../../../services/dispensary_preferences_service.dart';

class ReceptionistScreen extends StatefulWidget {
  final String branchId;
  final String receptionistId;
  final String receptionistName;
  final bool isEmbedded;
  final bool suppressPrescriptionNotifications;

  /// Hybrid "Pharmacy" layout (all-in-one desk). When set, this screen lays out
  /// Reception | Today's Tokens | the host's dispense pane, with the
  /// "Today's collection" strip on top. All reception logic stays here.
  final ReceptionistPharmacySlots? pharmacy;

  const ReceptionistScreen({
    super.key,
    required this.branchId,
    required this.receptionistId,
    required this.receptionistName,
    this.isEmbedded = false,
    this.suppressPrescriptionNotifications = false,
    this.pharmacy,
  });
  @override
  State<ReceptionistScreen> createState() => _ReceptionistScreenState();
}

/// What the Hybrid desk plugs into the Receptionist's Pharmacy layout.
class ReceptionistPharmacySlots {
  /// Right-hand pane (the dispense form).
  final Widget dispensePane;

  /// Serial loaded in the dispense form (highlighted in Today's Tokens).
  final String? dispensingSerial;

  /// A "Waiting for Dispense" row was tapped: load it in the dispense form.
  final ValueChanged<Map<String, dynamic>> onDispenseRequested;

  /// The shift filter of Today's Tokens changed ('all', 'morning', …).
  final ValueChanged<String> onSessionFilterChanged;

  const ReceptionistPharmacySlots({
    required this.dispensePane,
    required this.dispensingSerial,
    required this.onDispenseRequested,
    required this.onSessionFilterChanged,
  });
}

class _ReceptionistScreenState extends State<ReceptionistScreen>
    with SingleTickerProviderStateMixin, AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;
  String? _username;
  String? _branchName;
  String _pendingCnic = '';
  String? _pendingPatientId;
  String _activeSection = 'token';

  final GlobalKey<PatientRegisterPageState> _registerKey =
      GlobalKey<PatientRegisterPageState>();
  final GlobalKey<TokenScreenState> _tokenKey =
      GlobalKey<TokenScreenState>();

  StreamSubscription<List<ConnectivityResult>>? _connSub;
  StreamSubscription<Map<String, dynamic>>? _realtimeSub;
  StreamSubscription<ConnectionStatus>? _connectionSub;

  bool _online = true;
  bool _isSyncing = false;
  bool _loadingBranch = true;
  bool _sortNewestFirst = true;
  String _selectedSessionFilter = 'all';
  String _selectedCampFilter = 'all';

  bool get _hasMultiCamps => CampSessionService.hasCampsForBranch(widget.branchId);

  // Manual refresh notifier for token log
  final ValueNotifier<int> _refreshNotifier = ValueNotifier<int>(0);

  ConnectionStatus _connectionStatus = ConnectionManager().status;
  final Set<String> _pendingReversalSerials = <String>{};
  bool _isSubmittingReversal = false;

  static const Color _teal = SoftPalette.teal600;
  static const int _tabToken = 0;
  // ignore: unused_field
  static const int _tabLog = 1;
  static const int _tabRegister = 2;

  late TabController _mobileTabController;

  bool get _isKarachi {
    final b = widget.branchId.toLowerCase().trim();
    return b.contains('karachi') || b.contains('haji') || b.contains('saddar') || b.contains('kapaya');
  }

  bool get _isDark {
    try {
      if (Hive.isBoxOpen('app_settings')) {
        return Hive.box('app_settings').get('is_dark_mode', defaultValue: false) == true;
      }
    } catch (_) {}
    return false;
  }

  @override
  void initState() {
    super.initState();
    _mobileTabController = TabController(length: 3, vsync: this);

    _selectedSessionFilter = 'all';

    if (_hasMultiCamps) {
      final active = CampSessionService.getActiveCamp(widget.branchId);
      if (active != null && active.isNotEmpty && active != 'all') {
        _selectedCampFilter = active;
      }
    }

    lss.LocalStorageService.ensureBoxOpen(lss.LocalStorageService.patientsBox);
    lss.LocalStorageService.ensureBoxOpen(lss.LocalStorageService.entriesBox);

    if (!widget.isEmbedded) {
      SyncService().start(widget.branchId, moduleScope: 'dispensary'); // like the other desks: no full-PC sweep
    }
    _loadBranchName();
    _listenConnectivity();
    if (!widget.isEmbedded) {
      _startBackgroundSync();
    }

    // [FIX-USERNAME] Load name first, then start ConnectionManager with it.
    // _fetchReceptionistName() starts the connection once the name is resolved.
    CampSessionService.activeCampNotifier.addListener(_onActiveCampChanged);
    ConnectionManager().addReconnectListener(_onLanReconnected);
    _fetchReceptionistName();

    _connectionStatus = ConnectionManager().status;
    _connectionSub = ConnectionManager().statusStream.listen((status) {
      // The status is only shown in the standalone app bar; skip repeats and embedded rebuilds.
      final changed = !status.sameAs(_connectionStatus);
      _connectionStatus = status;
      if (mounted && changed && !widget.isEmbedded) setState(() {});
    });

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && !widget.isEmbedded) {
        UpdateDialogWidget.showUpdateDialogIfNeeded(context);
      }
      RealtimeManager().requestCatchUp(branchId: widget.branchId);
    });

    _realtimeSub = RealtimeManager().messageStream.listen((event) async {
      final type = event['event_type'] as String?;
      final rawData = event['data'];
      final data = (rawData is Map) ? Map<String, dynamic>.from(rawData) : null;

      debugPrint('[Receptionist] 📨 Got event: $type');

      // TOKEN REVERSAL APPROVED
      if (type == 'token_reversal_approved') {
        final eventBranch = data?['branchId']?.toString().toLowerCase().trim();
        final myBranch = widget.branchId.toLowerCase().trim();
        if (eventBranch != null && eventBranch.isNotEmpty && myBranch.isNotEmpty &&
            eventBranch != myBranch && !eventBranch.contains(myBranch) && !myBranch.contains(eventBranch)) {
          return;
        }

        final tokenSerial = (data?['tokenSerial'] ?? data?['serial'] ?? data?['tokenId'])?.toString();
        if (tokenSerial != null && tokenSerial.isNotEmpty) {
          _pendingReversalSerials.remove(tokenSerial.trim().toUpperCase());
          await lss.LocalStorageService.deleteLocalEntry(widget.branchId, tokenSerial);
          debugPrint('[Receptionist] ✅ Token reversal processed for $tokenSerial');
        }

        // Force UI refresh
        if (mounted) {
          _refreshNotifier.value++;
          setState(() {});
        }
        return;
      }

      if (type == 'token_reversal_rejected') {
        final tokenSerial = (data?['tokenSerial'] ?? data?['serial'] ?? data?['tokenId'])?.toString();
        if (tokenSerial != null) {
          _pendingReversalSerials.remove(tokenSerial.trim().toUpperCase());
        }
      }

      // PATIENT EDIT APPROVED
      if (type == 'patient_edit_approved') {
        final eventBranch = data?['branchId'] as String?;
        if (eventBranch != widget.branchId) return;

        final patientId = data?['patientId'] as String?;
        final rawChanges = data?['changes'];
        final changes = (rawChanges is Map) ? Map<String, dynamic>.from(rawChanges) : null;

        if (patientId != null && changes != null && changes.isNotEmpty) {
          final allPatients = lss.LocalStorageService.getAllLocalPatients(
              branchId: widget.branchId);
          final existing = allPatients
              .where((p) => p['patientId'] == patientId)
              .firstOrNull;

          if (existing != null) {
            final updated = Map<String, dynamic>.from(existing)
              ..addAll(lss.LocalStorageService.sanitize(changes));
            await lss.LocalStorageService.saveLocalPatient(updated, isFromSync: true);
          } else {
            final newPatient = lss.LocalStorageService.sanitize(changes);
            newPatient['patientId'] = patientId;
            newPatient['branchId'] = widget.branchId;
            await lss.LocalStorageService.saveLocalPatient(newPatient, isFromSync: true);
          }
          await lss.LocalStorageService.updateActiveEntriesForPatient(widget.branchId, patientId, changes);

          if (mounted) setState(() {});
        }
        return;
      }

      // PRESCRIPTION SAVED BY DOCTOR -> TRIGGER RECEPTIONIST TOAST & UPDATE LOCAL ENTRY
      if (type == RealtimeEvents.savePrescription ||
          type == 'prescription_created' ||
          type == 'save_prescription' ||
          (type == RealtimeEvents.saveEntry &&
              (data?['status'] == 'completed' || data?['prescriptions'] != null))) {
        final eventBranch =
            data?['branchId'] as String? ?? event['branchId'] as String?;
        if (eventBranch == null || eventBranch == widget.branchId) {
          if (!widget.suppressPrescriptionNotifications) {
            _showPrescriptionNotification(data, event);
          }
          final serial = (data?['serial'] ?? data?['id'])?.toString().trim();
          if (serial != null && serial.isNotEmpty && Hive.isBoxOpen(LocalStorageService.entriesBox)) {
            try {
              final eBox = Hive.box(LocalStorageService.entriesBox);
              final normB = widget.branchId.trim().toLowerCase();
              final key = '$normB-$serial';
              final existing = eBox.get(key) ?? eBox.get('$normB-${serial.toUpperCase()}');
              if (existing is Map) {
                final updated = Map<String, dynamic>.from(existing);
                updated['status'] = 'completed';
                // Not an older or medicine-less copy over the stored prescription (a replay of
                // it was then pushed to every desk as this desk's token on reconnect).
                if (data != null && LocalStorageService.mayReplacePrescription(data, existing['prescription'])) {
                  updated['prescription'] = LocalStorageService.prescriptionForEmbedding(data);
                  updated['prescriptionId'] = data['id'] ?? serial;
                  updated['completedAt'] ??= data['completedAt'] ?? DateTime.now().toIso8601String();
                  if (data['doctorName'] != null) updated['doctorName'] = data['doctorName'];
                }
                final writeKey = (existing == eBox.get('$normB-${serial.toUpperCase()}'))
                    ? '$normB-${serial.toUpperCase()}'
                    : key;
                eBox.put(writeKey, updated);
              }
            } catch (_) {}
          }
        }
      }

      // Other events that should trigger UI refresh
      if (type == RealtimeEvents.saveEntry ||
          type == RealtimeEvents.savePrescription ||
          type == 'dispense_completed' ||
          type == 'token_created' ||
          type == 'prescription_created') {
        _debouncedRebuild();
      }
    });
  }

  void _showPrescriptionNotification(Map<String, dynamic>? data, [Map<String, dynamic>? fullEvent]) {
    if (!mounted || data == null) return;

    final isReplay = fullEvent?['_serverPush'] == true ||
        fullEvent?['_resent'] == true ||
        fullEvent?['isCatchUp'] == true ||
        fullEvent?['_isReplay'] == true ||
        data['_serverPush'] == true ||
        data['_resent'] == true ||
        data['isCatchUp'] == true ||
        data['_isReplay'] == true;
    if (isReplay) return;
    // Never alert this desk about its own action (Hybrid Desk: a Doctor tab on the same desk).
    if (RealtimeManager().isOwnEvent(fullEvent)) return;

    final serial =
        (data['serial'] ?? data['tokenNumber'] ?? '').toString().trim();
    if (serial.isEmpty) return;

    final today = CampSessionService.resolveShiftAndDateKey().dateKey;
    final itemDateKey = (data['dateKey'] ?? fullEvent?['dateKey'])?.toString().trim();
    final parts = serial.contains('-') ? serial.split('-') : <String>[];
    final serialDk = (parts.isNotEmpty && parts[0].toUpperCase() == 'X')
        ? (parts.length > 1 ? parts[1] : '')
        : (parts.isNotEmpty ? parts[0] : '');
    final isToday = (itemDateKey == null || itemDateKey.isEmpty || itemDateKey == today) &&
        (serialDk.length != 6 || serialDk == today);
    if (!isToday) return;

    if (data['dispenseStatus'] == 'dispensed') return;

    final rawTime = data['completedAt'] ?? data['createdAt'] ?? data['timestamp'];
    final dt = rawTime != null ? DateTime.tryParse(rawTime.toString()) : null;
    if (dt != null && DateTime.now().difference(dt).inMinutes > 3) return;

    // Isolate notifications by camp in multi-camp branches so other camps' prescriptions are not alerted
    if (CampSessionService.hasCampsForBranch(widget.branchId)) {
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
    }

    final branchKey = '${widget.branchId}_$serial';

    if (!NotificationDeduper.shouldShow('receptionist_prescription_$branchKey', window: const Duration(minutes: 10))) {
      return;
    }

    final patientName =
        (data['patientName'] ?? data['name'] ?? 'Patient').toString().trim();
    final rawDoc = (data['doctorName'] ?? data['prescribedBy'] ?? data['updatedBy'] ?? data['performedBy'] ?? '').toString().trim();
    final doctorName = rawDoc.isNotEmpty && rawDoc.toLowerCase() != 'unknown' ? rawDoc : 'Doctor';
    final serialSuffix = serial.contains('-') ? serial.split('-').last : serial;
    final tokenDisplay = serialSuffix.isNotEmpty ? '#$serialSuffix' : serial;

    try {
      HapticFeedback.mediumImpact();
    } catch (_) {}

    Flushbar(
      titleText: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(5),
            decoration: BoxDecoration(
              color: SoftPalette.emerald350.withValues(alpha: 0.25),
              shape: BoxShape.circle,
            ),
            child: const Icon(
              Icons.notifications_active_rounded,
              color: SoftPalette.emerald350,
              size: 18,
            ),
          ),
          const SizedBox(width: 10),
          const Expanded(
            child: Text(
              'Doctor Ready – Send Next Patient',
              style: TextStyle(
                fontWeight: FontWeight.w800,
                fontSize: 14.5,
                color: SoftPalette.gray50,
                letterSpacing: -0.2,
              ),
            ),
          ),
        ],
      ),
      messageText: Padding(
        padding: const EdgeInsets.only(top: 2),
        child: RichText(
          text: TextSpan(
            style: const TextStyle(
                fontSize: 13, color: SoftPalette.slate200, height: 1.3),
            children: [
              TextSpan(
                text: doctorName.isNotEmpty ? '$doctorName ' : 'Doctor ',
                style: const TextStyle(
                    fontWeight: FontWeight.bold, color: SoftPalette.gray50),
              ),
              const TextSpan(text: 'finished consultation for '),
              TextSpan(
                text: '$tokenDisplay $patientName',
                style: const TextStyle(
                  fontWeight: FontWeight.w900,
                  color: SoftPalette.emerald300,
                ),
              ),
              const TextSpan(
                  text: '. Please call and send in the next patient.'),
            ],
          ),
        ),
      ),
      backgroundColor: SoftPalette.slate900,
      borderRadius: BorderRadius.circular(16),
      margin: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
      flushbarPosition: FlushbarPosition.TOP,
      duration: const Duration(seconds: 6),
      animationDuration: const Duration(milliseconds: 350),
      boxShadows: [
        BoxShadow(
          color: SoftPalette.emerald350.withValues(alpha: 0.35),
          blurRadius: 18,
          spreadRadius: 1,
          offset: const Offset(0, 4),
        ),
        BoxShadow(
          color: SoftPalette.gray900.withValues(alpha: 0.5),
          blurRadius: 12,
          offset: const Offset(0, 4),
        ),
      ],
      borderColor: SoftPalette.emerald350.withValues(alpha: 0.6),
      borderWidth: 1.4,
    ).show(context);
  }

  // [FIX-USERNAME] Resolve receptionist name then start/update connection with it.
  Future<void> _fetchReceptionistName() async {
    String? resolvedName;

    // 1. Try local cache first (fast, no network needed).
    try {
      final user = lss.LocalStorageService.getLocalUserByUid(widget.receptionistId);
      resolvedName = (user?['username'] as String?)?.trim();
      if (resolvedName?.isEmpty == true) resolvedName = null;
    } catch (_) {}

    // 2. Fall back to the name passed as a widget param.
    resolvedName ??= widget.receptionistName.trim().isNotEmpty
        ? widget.receptionistName.trim()
        : null;

    if (mounted) setState(() => _username = resolvedName);

    // 3. Start connection immediately with whatever name is available.
    if (!widget.isEmbedded) {
      ConnectionManager().start(
        role:     'receptionist',
        branchId: widget.branchId,
        username: resolvedName,
      );
      if (resolvedName != null) {
        RealtimeManager().updateUsername(resolvedName);
      }
    }

    // 4. Optionally fetch authoritative name from Firestore if local was stale.
    //    Receptionist name is usually reliable from widget props / local cache,
    //    but if it differs from Firestore we update in the background.
    try {
      final userData = await AuthService().getUserByUid(widget.receptionistId);
      if (userData != null && Hive.isBoxOpen('app_settings')) {
        await Hive.box('app_settings').put('user_data', userData);
        await Hive.box('app_settings').put('currentUser', userData);
      }
      final firestoreName =
          (userData?['username'] as String?)?.trim() ??
          (userData?['name']     as String?)?.trim();
      if (mounted) {
        setState(() {
          if (firestoreName != null && firestoreName.isNotEmpty) {
            _username = firestoreName;
          }
        });
        if (firestoreName != null && firestoreName.isNotEmpty && !widget.isEmbedded) {
          RealtimeManager().updateUsername(firestoreName);
        }
      }
    } catch (e) {
      debugPrint('[Receptionist] Could not fetch name from Firestore: $e');
    }
  }

  Future<void> _startBackgroundSync() async {
    try {
      await lss.LocalStorageService.downloadTodayTokens(widget.branchId);
      final settings = Hive.box('app_settings');
      final key = 'initial_download_done_${widget.branchId}';
      if (!settings.get(key, defaultValue: false)) {
        SyncService().initialFullDownload(widget.branchId).then((_) {
          settings.put(key, true);
        });
      }
    } catch (e) {
      debugPrint('[ReceptionistScreen] Background sync failed: $e');
    }
  }

  void _listenConnectivity() {
    _connSub = Connectivity().onConnectivityChanged.listen((results) {
      final isOnline = results.any((r) => r != ConnectivityResult.none);
      if (_online != isOnline && mounted) {
        setState(() => _online = isOnline);
        if (isOnline) {
          RealtimeManager().forceFlushAndCatchUp().ignore();
          SyncService().triggerUpload().ignore();
        }
      }
    });
  }

  void _onActiveCampChanged() {
    if (!mounted) return;
    if (_hasMultiCamps) {
      final active = CampSessionService.getActiveCamp(widget.branchId);
      if (active != null && active.isNotEmpty && active != 'all') {
        _selectedCampFilter = active;
      }
    }
    setState(() {});
  }

  Future<void> _loadBranchName() async {
    if (widget.branchId.isEmpty) {
      if (mounted) {
        setState(() {
          _branchName = 'Free Dispensary';
          _loadingBranch = false;
        });
      }
      return;
    }
    try {
      final doc = await FirebaseFirestore.instance
          .collection('branches')
          .doc(widget.branchId)
          .get();
      if (mounted) {
        setState(() {
          _branchName = doc.data()?['name'] ?? 'Free Dispensary';
          _loadingBranch = false;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _branchName = 'Free Dispensary';
          _loadingBranch = false;
        });
      }
    }
  }

  Future<void> _forceSync() async {
    if (_isSyncing || !mounted) return;
    setState(() => _isSyncing = true);
    try {
      // 1. Force-flush LAN WebSocket outbox & request catch-up from LAN server
      await RealtimeManager().forceFlushAndCatchUp();

      // 2. If online, sync pending and today records with cloud
      if (_online) {
        await SyncService().syncTodayOnly(widget.branchId);
        await SyncService().triggerUpload();
      }
      if (mounted) {
        Flushbar(
          message: _online ? 'Full sync completed (LAN & Cloud)' : 'LAN Sync completed (Outbox flushed)',
          backgroundColor: SoftPalette.green500,
          duration: const Duration(seconds: 3),
        ).show(context);
      }
    } catch (e) {
      if (mounted) {
        Flushbar(
          message: 'Sync failed: $e',
          backgroundColor: SoftPalette.red500,
          duration: const Duration(seconds: 4),
        ).show(context);
      }
    } finally {
      if (mounted) setState(() => _isSyncing = false);
    }
  }

  // NEW: Dedicated refresh for token log
  Future<void> _refreshTokenLog() async {
    if (!mounted) return;

    setState(() => _isSyncing = true);

    try {
      // Immediate UI feedback
      _refreshNotifier.value++;

      // 0. Purge any phantom unknown tokens before reloading
      await lss.LocalStorageService.purgePhantomUnknownTokens(widget.branchId);

      // 1. Force flush stuck outbox and request catch-up over LAN
      await RealtimeManager().forceFlushAndCatchUp();

      // 2. Re-download today's tokens (most reliable for reversal issues)
      await lss.LocalStorageService.downloadTodayTokens(widget.branchId);

      debugPrint('[Receptionist] Token log manually refreshed');
    } catch (e) {
      debugPrint('[Receptionist] Manual refresh failed: $e');
    } finally {
      if (mounted) {
        setState(() => _isSyncing = false);
        _refreshNotifier.value++; // Final tick to ensure rebuild
      }
    }
  }

  bool _isLoggingOut = false;

  Future<void> _logout() async {
    if (_isLoggingOut) return;
    final confirm = await showLogoutDialog(context);
    if (confirm != true || !mounted) return;
    if (mounted) setState(() => _isLoggingOut = true);
    try { _connectionSub?.cancel(); _connSub?.cancel(); _realtimeSub?.cancel(); } catch (_) {}
    ConnectionManager().stop().catchError((_) {});
    await AuthService().signOut();
    if (mounted) Navigator.pushNamedAndRemoveUntil(context, '/login', (r) => false);
  }

  void _handlePatientNotFound(String cnic) {
    setState(() {
      _pendingCnic = cnic;
      _pendingPatientId = null;
      _activeSection = 'register';
    });
    _mobileTabController.animateTo(_tabRegister);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _registerKey.currentState?.prefillCnic(cnic);
    });
  }

  void _onPatientRegistered(String patientIdOrCnic) {
    final clean = patientIdOrCnic.contains('_child_')
        ? patientIdOrCnic.split('_child_').first
        : patientIdOrCnic;
    setState(() {
      _pendingPatientId = patientIdOrCnic;
      _pendingCnic = clean;
      _activeSection = 'token';
    });
    if (_mobileTabController.length > _tabToken) {
      _mobileTabController.animateTo(_tabToken);
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _tokenKey.currentState?.selectPatientDirectly(patientIdOrCnic, cnicFallback: clean);
      // One-time hand-off: clear it once delivered. Left set, every rebuild of the token
      // panel re-filled the search box with this CNIC and re-opened this patient — even
      // after the receptionist searched a different (unregistered) CNIC.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        setState(() {
          _pendingPatientId = null;
          _pendingCnic = '';
        });
      });
    });
  }

  Future<void> _requestTokenReverse(Map<String, dynamic> entry) async {
    final serial = (entry['serial'] as String? ?? 'N/A').trim().toUpperCase();
    final patientName = entry['patientName'] as String? ?? 'Unknown';

    // Anti-Spam Guard 1: In-flight or already submitted during this active session
    if (_isSubmittingReversal || _pendingReversalSerials.contains(serial)) {
      if (mounted) {
        Flushbar(
          message: 'A reversal request for Token #$serial is already pending supervisor review.',
          backgroundColor: SoftPalette.orange350,
          duration: const Duration(seconds: 3),
        ).show(context);
      }
      return;
    }

    // Anti-Spam Guard 2: Persistent check against local_edit_requests
    try {
      if (Hive.isBoxOpen('local_edit_requests')) {
        final box = Hive.box('local_edit_requests');
        final alreadyPending = box.values.any((v) =>
            v is Map &&
            (v['tokenSerial'] ?? v['serial'])?.toString().trim().toUpperCase() == serial &&
            v['status'] == 'pending');
        if (alreadyPending) {
          _pendingReversalSerials.add(serial);
          if (mounted) {
            Flushbar(
              message: 'Token #$serial already has an active reversal request awaiting approval.',
              backgroundColor: SoftPalette.orange350,
              duration: const Duration(seconds: 3),
            ).show(context);
          }
          return;
        }
      }
    } catch (_) {}

    final reasonCtrl = TextEditingController();

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Request Token Reversal',
            style: TextStyle(color: SoftPalette.amber300)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Token: #$serial',
                style: const TextStyle(fontWeight: FontWeight.bold)),
            Text('Patient: $patientName'),
            const SizedBox(height: 16),
            TextField(
              controller: reasonCtrl,
              decoration: const InputDecoration(
                  labelText: 'Reason (optional)',
                  border: OutlineInputBorder()),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          ElevatedButton.icon(
            icon: const Icon(Icons.undo),
            label: const Text('Send Request'),
            style: ElevatedButton.styleFrom(
                backgroundColor: SoftPalette.orange400),
            onPressed: () => Navigator.of(ctx).pop(true),
          ),
        ],
      ),
    );

    if (confirmed != true) return;

    if (_isSubmittingReversal) return;
    _isSubmittingReversal = true;
    _pendingReversalSerials.add(serial);

    final requesterName = (_username?.isNotEmpty == true)
        ? _username!
        : widget.receptionistName;

    try {
      final requestId = 'req_reversal_${widget.receptionistId}_${DateTime.now().millisecondsSinceEpoch}';
      final reqPayload = <String, dynamic>{
        'id': requestId,
        'requestId': requestId,
        'type': 'token_reversal',
        'requestType': 'token_reversal',
        'status': 'pending',
        'branchId': widget.branchId,
        'receptionistId': widget.receptionistId,
        'receptionistName': requesterName,
        'requesterName': requesterName,
        'requestedBy': widget.receptionistId,
        'tokenSerial': serial,
        'patientId': entry['patientId'] ?? '',
        'patientName': patientName,
        'queueType': entry['queueType'] ?? 'unknown',
        'originalCreatedAt': entry['createdAt'],
        'reason': reasonCtrl.text.trim().isNotEmpty
            ? reasonCtrl.text.trim()
            : null,
        'requestedAt': DateTime.now().toIso8601String(),
        'reviewedAt': null,
        'reviewedBy': null,
        'decision': null,
      };

      await LocalStorageService.saveLocalEditRequest(reqPayload);

      await LocalStorageService.enqueueSync({
        'type': 'save_token_reversal_request',
        'branchId': widget.branchId,
        'requestId': requestId,
        'data': reqPayload,
      });

      RealtimeManager().sendMessage({
        ...RealtimeEvents.payload(
          type: 'request_created',
          branchId: widget.branchId,
          data: reqPayload,
        ),
      });

      // The queue item above is the only cloud write. A direct SDK set() here as well (no
      // merge, status pending) sat in the SDK's offline queue when the quota ran out and was
      // sent after the supervisor's decision, turning the request back to pending.

      // Notify supervisor via Cloud Messaging (works even if supervisor's app is closed)
      try {
        CloudMessagingService().notifySupervisorPendingRequests(
          branchId: widget.branchId,
          requestType: 'Token Reversal',
          requesterName: requesterName,
          details: 'Token reversal requested for #$serial ($patientName)',
        );
      } catch (e) {
        debugPrint('[ReceptionistScreen] Supervisor notification error: $e');
      }

      if (mounted) {
        Flushbar(
          message: 'Reversal request sent for #$serial',
          backgroundColor: SoftPalette.orange400,
          duration: const Duration(seconds: 4),
        ).show(context);
      }
    } catch (e) {
      _pendingReversalSerials.remove(serial);
      if (mounted) {
        Flushbar(
          message: 'Failed to send request: $e',
          backgroundColor: SoftPalette.red400,
          duration: const Duration(seconds: 5),
        ).show(context);
      }
    } finally {
      _isSubmittingReversal = false;
    }
  }

  bool _isWaitingOnly(Map<String, dynamic> entry) {
    final status = (entry['status'] as String?)?.toLowerCase().trim() ?? '';
    if (status.isNotEmpty && status != 'waiting') return false;
    final hasPrescription =
        (entry['prescriptionId'] as String?)?.isNotEmpty == true;
    if (hasPrescription) return false;
    return true;
  }

  PreferredSizeWidget _buildAppBar(bool isMobile) {
    return GmwfAppBar(
      isFloating: false,
      title: 'Receptionist – ${_username ?? widget.receptionistName}',
      subtitle: CampSessionService.getBranchAndCampDisplayName(
        branchName: _branchName ?? LocalStorageService.getBranchName(widget.branchId),
        branchId: widget.branchId,
        campId: CampSessionService.getActiveCamp(widget.branchId),
      ),
      onTitleLongPress: () => DispensaryUserSettingsDialog.show(
        context,
        branchId: widget.branchId,
        onUserUpdated: () {
          if (mounted) setState(() { _fetchReceptionistName(); });
        },
      ),
      onUserSettings: () => DispensaryUserSettingsDialog.show(
        context,
        branchId: widget.branchId,
        onUserUpdated: () {
          if (mounted) setState(() { _fetchReceptionistName(); });
        },
      ),
      titleTooltip: 'Long press for Settings',
      connectionStatus: _connectionStatus,
      onRetryConnection: () => ConnectionManager().reconnectNow(),
      isOnline: _online,
      isSyncing: _isSyncing,
      onSync: _forceSync,
      onLogout: _logout,
      isLoggingOut: _isLoggingOut,
      bottom: null,
    );
  }

  Map<String, dynamic> _getUserData() {
    try {
      if (Hive.isBoxOpen('app_settings')) {
        final userData = Hive.box('app_settings').get('user_data') ?? Hive.box('app_settings').get('currentUser');
        if (userData is Map) return Map<String, dynamic>.from(userData);
      }
    } catch (_) {}
    return {};
  }

  bool _isCreatedByMe(Map<String, dynamic> e) {
    final myId = widget.receptionistId.trim().toLowerCase();
    final myName = widget.receptionistName.trim().toLowerCase();
    final myDisplay = (_username ?? '').trim().toLowerCase();

    // Admins and supervisors can view tokens across the branch
    if (myId == 'admin' || myName == 'admin' || myDisplay == 'admin' || 
        myName.contains('supervisor') || myDisplay.contains('supervisor')) {
      return true;
    }

    final cBy = (e['createdBy'] ?? e['receptionistId'] ?? e['userId'] ?? '').toString().trim().toLowerCase();
    // [FIX] Never check performedBy here! performedBy gets updated on dispense/vitals/audit actions
    // to the dispenser or supervisor, which silently hides the token from the receptionist who created it.
    final cName = (e['createdByName'] ?? e['receptionistName'] ?? e['tokenBy'] ?? e['addedByName'] ?? e['addedBy'] ?? '').toString().trim().toLowerCase();

    if (myId.isNotEmpty && cBy.isNotEmpty) {
      if (cBy == myId || cBy.contains(myId) || myId.contains(cBy)) return true;
    }
    if (myName.isNotEmpty && cName.isNotEmpty) {
      if (cName == myName || cName.contains(myName) || myName.contains(cName)) return true;
    }
    if (myDisplay.isNotEmpty && cName.isNotEmpty) {
      if (cName == myDisplay || cName.contains(myDisplay) || myDisplay.contains(cName)) return true;
    }

    // Fallback for demo / temp staff sessions or tokens where creator was omitted
    if (cName == 'temp' || cBy == 'temp' || cBy.isEmpty || cName.isEmpty || cName == 'unknown') {
      return true;
    }

    // On offline or single receptionist branch, never hide tokens from the desk when logged in generically:
    if (myName.isEmpty || myName == 'receptionist' || myName == 'user' || myName == 'doctor') {
      return true;
    }

    if (cBy.isNotEmpty || cName.isNotEmpty) {
      return false;
    }

    return true;
  }

  // A token shows only on the date in its serial (no "recent" carry-over) — except a session
  // running past midnight, same rule as the doctor/dispenser queues (issued in the last 8 h).
  bool _isEffectivelyToday(Map<String, dynamic> e, String currentTodayKey, String todayIso) =>
      CampSessionService.isTokenOnDate(e, currentTodayKey, widget.branchId) ||
      CampSessionService.isLateNightCarryOver(e, widget.branchId);

  Timer? _debounceRebuildTimer;
  void _debouncedRebuild() {
    if (_debounceRebuildTimer?.isActive ?? false) return;
    _debounceRebuildTimer = Timer(const Duration(milliseconds: 120), () {
      if (mounted) {
        _cachedFilteredTokens = null;
        setState(() {});
      }
    });
  }

  List<Map<String, dynamic>>? _cachedFilteredTokens;
  DateTime? _cachedTokensTime;
  String? _cachedTokensFilter;

  List<Map<String, dynamic>> _getFilteredTodayTokens() {
    if (!Hive.isBoxOpen(lss.LocalStorageService.entriesBox)) return [];
    final now = DateTime.now();
    final filterKey = '$_selectedSessionFilter|$_selectedCampFilter|${Hive.box(lss.LocalStorageService.entriesBox).length}';
    if (_cachedFilteredTokens != null &&
        _cachedTokensTime != null &&
        now.difference(_cachedTokensTime!).inMilliseconds < 1200 &&
        _cachedTokensFilter == filterKey) {
      return _cachedFilteredTokens!;
    }
    try {
      final today = CampSessionService.resolveShiftAndDateKey(DateTime.now(), widget.branchId).dateKey;
      final todayIso = DateFormat('yyyy-MM-dd').format(DateTime.now());
      final currentStaffSession = CampSessionService.getCurrentSession(null, widget.branchId);
      final activeSession = (_selectedSessionFilter.isNotEmpty && _selectedSessionFilter != 'all')
          ? _selectedSessionFilter
          : currentStaffSession;

      final rawEntries = lss.LocalStorageService.getLocalEntries(widget.branchId);
      final normBranch = widget.branchId.toLowerCase().trim();
      // Once per rebuild, not per token: getActiveCamp reads (and may rewrite) the settings
      // box and logs, and this list is rebuilt after every LAN message.
      final targetCamp = !_hasMultiCamps
          ? null
          : ((_selectedCampFilter.isNotEmpty && _selectedCampFilter != 'all')
              ? _selectedCampFilter
              : CampSessionService.getActiveCamp(widget.branchId));

    final filtered = rawEntries.where((e) {
      // 1. Date filter (strictly today only - no yesterday tokens regardless of status)
      if (!_isEffectivelyToday(e, today, todayIso)) return false;

      final serial = (e['serial'] ?? e['id'])?.toString();
      if (!CampSessionService.isSerialMatchingBranch(serial, widget.branchId)) return false;

      // 2. Strict Branch filter (supports multi-camp aliases across any branch)
      final eBranch = (e['branchId'] ?? '').toString().toLowerCase().trim();
      if (eBranch.isNotEmpty && eBranch != normBranch && !CampSessionService.areBranchesMatching(eBranch, normBranch)) {
        return false;
      }

      // 3. Strict User filter (cannot see another user's tokens)
      if (!_isCreatedByMe(e)) return false;

      // 4. Deleted status filter
      final st = (e['status'] as String?)?.toLowerCase().trim();
      final syncSt = (e['syncStatus'] as String?)?.toLowerCase().trim();
      if (st == 'deleted' || syncSt == 'deleted') return false;

      // 5. Must have valid patient name or cnic
      var name = (e['patientName'] ?? e['name'] ?? '').toString().trim().toLowerCase();
      var cnic = (e['patientCnic'] ?? e['cnic'] ?? e['guardianCnic'] ?? '').toString().trim();
      if ((name.isEmpty || name == 'unknown patient' || name == 'unknown' || name == 'null') && cnic.isEmpty) {
        final presc = e['prescription'];
        if (presc is Map) {
          final pName = (presc['patientName'] ?? presc['name'])?.toString().trim();
          if (pName != null && pName.isNotEmpty && pName.toLowerCase() != 'unknown' && pName.toLowerCase() != 'unknown patient' && pName.toLowerCase() != 'null') {
            name = pName.toLowerCase();
          }
        }
        if ((name.isEmpty || name == 'unknown patient' || name == 'unknown' || name == 'null') && cnic.isEmpty) {
          if (serial != null && serial.isNotEmpty) {
            name = 'token #$serial';
          } else {
            return false;
          }
        }
      }

      // 6. Strict Camp Filter (cannot see another camp's tokens)
      if (_hasMultiCamps) {
        if (targetCamp != null && targetCamp.isNotEmpty && targetCamp != 'all') {
          final matches = CampSessionService.matchesCamp(
            selectedCamp: targetCamp,
            dispensaryId: e['dispensaryId']?.toString(),
            campId: e['campId']?.toString(),
            dispensaryTag: e['dispensaryTag']?.toString(),
            serial: serial,
          );
          if (!matches) return false;
        }
      }

      // 7. Strict Session Filter (evening staff cannot see morning, morning cannot see evening)
      if (_selectedSessionFilter != 'all') {
        final eSession = (e['session'] as String?)?.trim().toLowerCase() ?? '';
        if (eSession.isNotEmpty && eSession != 'unknown' && eSession != 'auto') {
          if (eSession != activeSession) return false;
        } else {
          final ser = (serial ?? '').toUpperCase();
          if (ser.contains('-M-') && activeSession != 'morning') return false;
          if (ser.contains('-E-') && activeSession != 'evening') return false;
          if (ser.contains('-N-') && activeSession != 'night') return false;
          final rawTime = e['createdAt'] ?? e['timestamp'] ?? e['time'];
          if (rawTime != null) {
            final dt = DateTime.tryParse(rawTime.toString());
            if (dt != null && CampSessionService.getCurrentSession(dt, widget.branchId) != activeSession) {
              return false;
            }
          }
        }
      }

      return true;
    }).toList();

    final Map<String, Map<String, dynamic>> uniqueBySerial = {};
    for (final e in filtered) {
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
      }
    }

    final result = uniqueBySerial.values.toList();
    _cachedFilteredTokens = result;
    _cachedTokensTime = now;
    _cachedTokensFilter = filterKey;
    return result;
    } catch (e) {
      debugPrint('[ReceptionistScreen] _getFilteredTodayTokens error: $e');
      return [];
    }
  }

  Map<String, int> _getSessionCounts() {
    if (!Hive.isBoxOpen(lss.LocalStorageService.entriesBox)) {
      return {'all': 0, 'morning': 0, 'evening': 0, 'night': 0};
    }
    try {
      final today = CampSessionService.resolveShiftAndDateKey(DateTime.now(), widget.branchId).dateKey;
      final todayIso = DateFormat('yyyy-MM-dd').format(DateTime.now());
      final rawEntries = lss.LocalStorageService.getLocalEntries(widget.branchId);
      final normBranch = widget.branchId.toLowerCase().trim();

      int all = 0, morning = 0, evening = 0, night = 0;
      final targetCamp = !_hasMultiCamps
          ? null
          : ((_selectedCampFilter.isNotEmpty && _selectedCampFilter != 'all')
              ? _selectedCampFilter
              : CampSessionService.getActiveCamp(widget.branchId));

      final Map<String, Map<String, dynamic>> uniqueBySerial = {};
      for (final e in rawEntries) {
        if (!_isEffectivelyToday(e, today, todayIso)) continue;

        final serial = (e['serial'] ?? e['id'])?.toString();
        if (!CampSessionService.isSerialMatchingBranch(serial, widget.branchId)) continue;

        final eBranch = (e['branchId'] ?? '').toString().toLowerCase().trim();
        if (eBranch.isNotEmpty && eBranch != normBranch) continue;

        if (!_isCreatedByMe(e)) continue;

        final st = (e['status'] as String?)?.toLowerCase().trim();
        final syncSt = (e['syncStatus'] as String?)?.toLowerCase().trim();
        if (st == 'deleted' || syncSt == 'deleted') continue;

        if (_hasMultiCamps) {
          if (targetCamp != null && targetCamp.isNotEmpty && targetCamp != 'all') {
            final matches = CampSessionService.matchesCamp(
              selectedCamp: targetCamp,
              dispensaryId: e['dispensaryId']?.toString(),
              campId: e['campId']?.toString(),
              dispensaryTag: e['dispensaryTag']?.toString(),
              serial: serial,
            );
            if (!matches) continue;
          }
        }

        String s = (serial ?? '').trim().toUpperCase();
        final branchPrefix = '${widget.branchId.trim().toUpperCase()}-';
        if (s.startsWith(branchPrefix)) {
          s = s.substring(branchPrefix.length);
        }
        if (s.isNotEmpty) {
          uniqueBySerial[s] = e;
        }
      }

      for (final e in uniqueBySerial.values) {
        final eSession = (e['session'] as String?)?.trim().toLowerCase() ?? '';
        String resolved = eSession;
        if (resolved.isEmpty || resolved == 'auto' || resolved == 'unknown') {
          final ser = (e['serial'] ?? '').toString().toUpperCase();
          if (ser.contains('-M-')) {
            resolved = 'morning';
          } else if (ser.contains('-E-')) {
            resolved = 'evening';
          } else if (ser.contains('-N-')) {
            resolved = 'night';
          } else {
            final rawTime = e['timestamp'] ?? e['createdAt'] ?? e['date'];
            if (rawTime != null) {
              final dt = DateTime.tryParse(rawTime.toString());
              if (dt != null) resolved = CampSessionService.getCurrentSession(dt, widget.branchId);
            }
          }
        }
        if (resolved.contains('morn')) {
          morning++;
        } else if (resolved.contains('eve')) {
          evening++;
        } else if (resolved.contains('night')) {
          night++;
        }
      }

      all = morning + evening + night;
      return {'all': all, 'morning': morning, 'evening': evening, 'night': night};
    } catch (e) {
      debugPrint('[ReceptionistScreen] _getSessionCounts error: $e');
      return {'all': 0, 'morning': 0, 'evening': 0, 'night': 0};
    }
  }

  Widget _buildShiftSelector(bool isMobile) {
    final counts = _getSessionCounts();
    final shifts = [
      {'id': 'all', 'label': 'All Today', 'count': counts['all'] ?? 0},
      {'id': 'morning', 'label': 'Morning', 'count': counts['morning'] ?? 0},
      {'id': 'evening', 'label': 'Evening', 'count': counts['evening'] ?? 0},
      {'id': 'night', 'label': 'Night', 'count': counts['night'] ?? 0},
    ];

    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        children: shifts.map((s) {
          final isSelected = _selectedSessionFilter == s['id'];
          final id = s['id'] as String;
          final label = s['label'] as String;
          final count = s['count'] as int;

          return Padding(
            padding: const EdgeInsets.only(right: 6),
            child: InkWell(
              onTap: () {
                setState(() => _selectedSessionFilter = id);
                // Pharmacy tab: the dispense form follows the same shift filter.
                widget.pharmacy?.onSessionFilterChanged(id);
              },
              borderRadius: BorderRadius.circular(20),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 200),
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                decoration: BoxDecoration(
                  color: isSelected
                      ? SoftPalette.emerald550
                      : (_isDark ? SoftPalette.slate700 : SoftPalette.gray100),
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(
                    color: isSelected
                        ? SoftPalette.emerald550
                        : (_isDark ? SoftPalette.slate600 : SoftPalette.gray150),
                    width: 1.2,
                  ),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      label,
                      style: TextStyle(
                        fontSize: 11.5,
                        fontWeight: isSelected ? FontWeight.bold : FontWeight.w600,
                        color: isSelected
                            ? SoftPalette.gray50
                            : (_isDark ? SoftPalette.gray50A70 : SoftPalette.gray900A87),
                      ),
                    ),
                    const SizedBox(width: 5),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                      decoration: BoxDecoration(
                        color: isSelected
                            ? SoftPalette.gray50.withValues(alpha: 0.25)
                            : (_isDark ? SoftPalette.slate800 : SoftPalette.gray150),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Text(
                        '$count',
                        style: TextStyle(
                          fontSize: 10,
                          fontWeight: FontWeight.bold,
                          color: isSelected
                              ? SoftPalette.gray50
                              : (_isDark ? SoftPalette.sky350 : SoftPalette.teal550),
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
    );
  }



  Widget _buildFilterDropdown({
    required String value,
    required List<Map<String, String>> items,
    required ValueChanged<String?> onChanged,
    required bool isDark,
  }) {
    return Container(
      height: 30,
      padding: const EdgeInsets.symmetric(horizontal: 8),
      decoration: BoxDecoration(
        color: isDark ? SoftPalette.slate700 : SoftPalette.gray100,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: isDark ? SoftPalette.slate600 : SoftPalette.gray150,
        ),
      ),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<String>(
          value: items.any((i) => i['id'] == value) ? value : items.first['id'],
          isDense: true,
          icon: Icon(Icons.arrow_drop_down,
              size: 16, color: isDark ? SoftPalette.sky350 : _teal),
          dropdownColor: isDark ? SoftPalette.slate800 : SoftPalette.gray50,
          style: TextStyle(
            fontSize: 11,
            fontWeight: FontWeight.w600,
            color: isDark ? SoftPalette.gray50 : SoftPalette.gray900A87,
          ),
          items: items.map((i) {
            return DropdownMenuItem<String>(
              value: i['id'],
              child: Text(i['label']!,
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                    color: isDark ? SoftPalette.gray50 : SoftPalette.gray900A87,
                  )),
            );
          }).toList(),
          onChanged: onChanged,
        ),
      ),
    );
  }

  Widget _buildSummaryCards([bool isMobile = false, List<Map<String, dynamic>>? precomputedEntries]) {
    try {
      final todayEntries = precomputedEntries ?? _getFilteredTodayTokens();

      final tally = TokenTally.of(todayEntries, isKarachi: _isKarachi);
      final zakat = tally.zakat, nonZakat = tally.nonZakat, gmwf = tally.gmwf;
      final zakatAmount = tally.zakatAmount, nonZakatAmount = tally.nonZakatAmount;
      final total = tally.total;
      final totalAmount = tally.totalAmount;

      final cards = [
        _compactSummaryCard(
          _isKarachi ? 'PKR 20' : 'Zakat',
          zakat,
          'PKR $zakatAmount',
          SoftPalette.emerald550, // Solid Emerald Green
          Icons.volunteer_activism_rounded,
          isMobile: isMobile,
        ),
        _compactSummaryCard(
          _isKarachi ? 'PKR 100' : 'Non-Zakat',
          nonZakat,
          _isKarachi && nonZakat == 0 ? 'Disabled 🔒' : 'PKR $nonZakatAmount',
          SoftPalette.emerald550,
          Icons.person_outline_rounded,
          isMobile: isMobile,
          isOutlined: true,
          outlineColor: SoftPalette.emerald550, // Green Outline on White Card
        ),
        _compactSummaryCard(
          'GMWF',
          gmwf,
          'PKR 0',
          SoftPalette.orange400, // Solid Amber
          null,
          isImage: true,
          isMobile: isMobile,
        ),
        _compactSummaryCard(
          'Total',
          total,
          'PKR $totalAmount',
          SoftPalette.orange400,
          Icons.people_outline_rounded,
          isMobile: isMobile,
          isOutlined: true,
          outlineColor: SoftPalette.orange400, // Amber Outline on White Card
        ),
      ];

      return Row(
        children: cards
            .map((c) => Expanded(
                  child: Padding(
                    padding: EdgeInsets.symmetric(horizontal: isMobile ? 1.5 : 4),
                    child: c,
                  ),
                ))
            .toList(),
      );
    } catch (e) {
      debugPrint('[ReceptionistScreen] _buildSummaryCards error: $e');
      return const SizedBox.shrink();
    }
  }

  int _getDaysOfMedicine(Map<String, dynamic> entry) => TokenTally.daysOfMedicine(entry);

  /// Shares today's collection (same numbers as the summary) to WhatsApp.
  void _shareCollectionToWhatsApp([List<Map<String, dynamic>>? entries]) {
    final tally = TokenTally.of(entries ?? _getFilteredTodayTokens(), isKarachi: _isKarachi);
    final place = CampSessionService.getBranchAndCampDisplayName(
      branchName: _branchName ?? LocalStorageService.getBranchName(widget.branchId),
      branchId: widget.branchId,
      campId: CampSessionService.getActiveCamp(widget.branchId),
    );
    shareTextToWhatsApp(buildCollectionSummary(
      tally: tally,
      place: place,
      date: DateFormat('d MMM yyyy').format(DateTime.now()),
      shift: _selectedSessionFilter,
      username: (_username?.isNotEmpty == true) ? _username! : widget.receptionistName,
    ));
  }

  Widget _compactSummaryCard(
    String title,
    int count,
    String amount,
    Color solidColor,
    IconData? icon, {
    bool isImage = false,
    bool isMobile = false,
    bool isOutlined = false,
    Color? outlineColor,
  }) {
    // Shared with the Dispense Queue / Hybrid Pharmacy view (same look everywhere).
    return DeskSummaryCard(
      title: title,
      count: count,
      amount: amount,
      solidColor: solidColor,
      icon: icon,
      isImage: isImage,
      isMobile: isMobile,
      isOutlined: isOutlined,
      outlineColor: outlineColor,
      isDark: _isDark,
    );
  }

  Widget _buildTokenLog([bool isMobile = false, List<Map<String, dynamic>>? precomputedEntries]) {
    // Same fair order as the doctor/dispenser queues (offline-issued tokens by issue time).
    final rawList = TokenOrder.sortFairly(
        precomputedEntries ?? _getFilteredTodayTokens(),
        newestFirst: _sortNewestFirst);

    if (rawList.isEmpty) {
      return Center(
        child: Text(
          'No tokens issued today',
          style: TextStyle(
              fontSize: 14,
              color: _isDark ? SoftPalette.slate350 : SoftPalette.gray350),
        ),
      );
    }

    return ListView.separated(
      itemCount: rawList.length,
      separatorBuilder: (_, _) => Divider(
          height: 1,
          color: _isDark ? SoftPalette.slate700 : SoftPalette.gray100),
      itemBuilder: (context, i) {
        final e = rawList[i];
        final serial = e['serial'] as String? ?? 'N/A';
        final rawName = (e['patientName'] ?? e['name'] ?? e['fullName'])?.toString().trim();
        var name = (rawName != null &&
                rawName.isNotEmpty &&
                rawName.toLowerCase() != 'null' &&
                rawName.toLowerCase() != 'unknown' &&
                rawName.toLowerCase() != 'unknown patient')
            ? rawName
            : '';
        var cnic = lss.LocalStorageService.resolveFirstValidCnic([
          e['patientCnic'],
          e['cnic'],
          e['guardianCnic'],
        ]);
        var guardianCnic = lss.LocalStorageService.resolveFirstValidCnic([
          e['guardianCnic'],
        ]);
        final pId = (e['patientId'] ?? e['id'] ?? '').toString().trim();

        if (name.isEmpty || cnic.isEmpty) {
          final presc = e['prescription'] is Map
              ? e['prescription'] as Map
              : lss.LocalStorageService.getLocalPrescription(
                  serial,
                  branchId: widget.branchId,
                  cnic: cnic.isNotEmpty ? cnic : guardianCnic,
                  patientId: pId,
                  patientName: rawName,
                );
          if (name.isEmpty) {
            final pName = lss.LocalStorageService.resolveFirstValidPatientName([
              presc?['patientName'],
              presc?['name'],
              presc?['fullName'],
            ]);
            if (pName.isNotEmpty) {
              name = pName;
              e['patientName'] = name;
            }
          }
          if (cnic.isEmpty) {
            final pCnic = lss.LocalStorageService.resolveFirstValidCnic([
              presc?['patientCnic'],
              presc?['cnic'],
              presc?['guardianCnic'],
            ]);
            if (pCnic.isNotEmpty) {
              cnic = pCnic;
              e['cnic'] = cnic;
              e['patientCnic'] = cnic;
            }
          }
        }

        bool isSyntheticCnic = !lss.LocalStorageService.isValidCnicValue(cnic);

        if (name.isEmpty || isSyntheticCnic) {
          if (pId.isNotEmpty && !pId.toLowerCase().startsWith('unknown')) {
            final lp = lss.LocalStorageService.getLocalPatient(pId);
            if (lp != null) {
              final lpName = lss.LocalStorageService.resolveFirstValidPatientName([
                lp['name'],
                lp['patientName'],
                lp['fullName'],
              ]);
              if (name.isEmpty && lpName.isNotEmpty) {
                name = lpName;
                e['patientName'] = name;
              }
              final lpCnic = lss.LocalStorageService.resolveFirstValidCnic([
                lp['cnic'],
                lp['patientCnic'],
                lp['guardianCnic'],
              ]);
              if (isSyntheticCnic && lpCnic.isNotEmpty) {
                cnic = lpCnic;
                e['cnic'] = cnic;
                e['patientCnic'] = cnic;
                isSyntheticCnic = false;
              }
            }
            // Fallback: extract CNIC directly from patientId if patientId is a CNIC or `<cnic>_child_<name>`
            if (isSyntheticCnic) {
              final pidCandidate = pId.contains('_child_') ? pId.split('_child_').first : pId;
              if (lss.LocalStorageService.isValidCnicValue(pidCandidate)) {
                cnic = pidCandidate;
                e['cnic'] = cnic;
                e['patientCnic'] = cnic;
                isSyntheticCnic = false;
              }
            }
          }
          final isChildEntry = e['isAdult'] == false || pId.contains('_child_') || guardianCnic.isNotEmpty;
          if (name.isEmpty && cnic.isNotEmpty && !isSyntheticCnic && !isChildEntry) {
            final lp = lss.LocalStorageService.getLocalPatientByCnic(cnic);
            if (lp != null) {
              final lpName = lss.LocalStorageService.resolveFirstValidPatientName([
                lp['name'],
                lp['patientName'],
                lp['fullName'],
              ]);
              if (lpName.isNotEmpty) {
                name = lpName;
                e['patientName'] = name;
              }
            }
          }
          // CRITICAL: Look up by patient name if CNIC was corrupted or lost!
          if (isSyntheticCnic && name.isNotEmpty && name != 'Unknown Patient') {
            final lp = lss.LocalStorageService.findPatientByName(name);
            if (lp != null) {
              final realC = lss.LocalStorageService.resolveFirstValidCnic([
                lp['cnic'],
                lp['patientCnic'],
                lp['guardianCnic'],
              ]);
              if (realC.isNotEmpty) {
                cnic = realC;
                e['cnic'] = cnic;
                e['patientCnic'] = cnic;
                if (lss.LocalStorageService.isValidCnicValue(lp['guardianCnic'])) {
                  guardianCnic = lp['guardianCnic'].toString().trim();
                  e['guardianCnic'] = guardianCnic;
                }
              }
            }
          }
        }

        if (name.isEmpty) {
          name = 'Unknown Patient';
        }
        final queueTypeRaw =
            (e['queueType'] as String?)?.toLowerCase().trim() ?? 'unknown';
        final effectiveQueueType = (_isKarachi && (queueTypeRaw == 'non-zakat' || queueTypeRaw.contains('non')))
            ? 'zakat'
            : queueTypeRaw;
        final timestamp = DateTime.tryParse(e['createdAt'] as String? ?? '') ??
            DateTime.now();
        final days = _getDaysOfMedicine(e);
        int tokenAmount = 0;
        if (effectiveQueueType == 'zakat') tokenAmount = 20 * days;
        if (effectiveQueueType == 'non-zakat') tokenAmount = 100 * days;
        final hasExtraDays = days > 1 && tokenAmount > 0;

        // Category label & color
        Color badgeColor;
        String displayType;
        if (_isKarachi) {
          if (effectiveQueueType == 'zakat') {
            badgeColor = SoftPalette.green400;
            displayType = 'PKR 20';
          } else if (effectiveQueueType == 'gmwf') {
            badgeColor = SoftPalette.orange350;
            displayType = 'GMWF';
          } else {
            badgeColor = SoftPalette.green400;
            displayType = 'PKR 20';
          }
        } else {
          switch (queueTypeRaw) {
            case 'zakat':
              badgeColor = SoftPalette.green400;
              displayType = 'Zakat';
              break;
            case 'non-zakat':
              badgeColor = SoftPalette.blue500;
              displayType = 'Non-Zakat';
              break;
            case 'gmwf':
              badgeColor = SoftPalette.orange350;
              displayType = 'GMWF';
              break;
            default:
              badgeColor = SoftPalette.gray500;
              displayType = 'Zakat';
          }
        }

        // Status determination
        final s = (e['status'] as String?)?.toLowerCase().trim() ?? 'waiting';
        final hasPrescription = (e['prescriptionId'] as String?)?.isNotEmpty == true || e['prescription'] is Map;
        final isDispensed = s == 'dispensed' || e['dispensedAt'] != null || (e['dispenseStatus'] as String?)?.toLowerCase().trim() == 'dispensed';
        final isWaitingToDispense = !isDispensed && (hasPrescription || s == 'completed' || s == 'prescribed' || s == 'waiting_to_dispense' || s == 'waiting_for_dispense');

        // Only tokens strictly waiting for doctor (not yet prescribed or dispensed) can be reversed/undone!
        final isWaitingOnly = !isDispensed && !isWaitingToDispense && s != 'with_doctor' && s != 'with doctor' && s != 'in_consultation' && s != 'cancelled' && s != 'reversed' && s != 'deleted' && s != 'skipped';
        final canReverse = isWaitingOnly;

        String statusLabel;
        Color statusBg;
        Color statusText;
        IconData statusIcon;

        if (isDispensed) {
          statusLabel = 'Dispensed';
          statusBg = _isDark ? SoftPalette.green700 : SoftPalette.green100m;
          statusText = _isDark ? SoftPalette.emerald200 : SoftPalette.green550;
          statusIcon = Icons.check_circle_outline_rounded;
        } else if (isWaitingToDispense) {
          statusLabel = 'Waiting for Dispense';
          statusBg = _isDark ? SoftPalette.blue750 : SoftPalette.slate100;
          statusText = _isDark ? SoftPalette.blue300 : SoftPalette.blue550;
          statusIcon = Icons.medication_outlined;
        } else if (s == 'with_doctor' || s == 'with doctor' || s == 'in_consultation') {
          statusLabel = 'With Doctor';
          statusBg = _isDark ? SoftPalette.violet750 : SoftPalette.purple150m;
          statusText = _isDark ? SoftPalette.purple300 : SoftPalette.purple600;
          statusIcon = Icons.medical_services_outlined;
        } else if (s == 'cancelled' || s == 'reversed') {
          statusLabel = 'Cancelled';
          statusBg = _isDark ? SoftPalette.red800 : SoftPalette.pink100m;
          statusText = _isDark ? SoftPalette.red300 : SoftPalette.red550;
          statusIcon = Icons.cancel_outlined;
        } else if (s == 'skipped') {
          statusLabel = 'Skipped';
          statusBg = _isDark ? SoftPalette.slate700 : SoftPalette.gray100;
          statusText = _isDark ? SoftPalette.slate350 : SoftPalette.gray550;
          statusIcon = Icons.skip_next_rounded;
        } else {
          statusLabel = 'Waiting';
          statusBg = _isDark ? SoftPalette.orange800 : SoftPalette.yellow50;
          statusText = _isDark ? SoftPalette.yellow200 : SoftPalette.orange350;
          statusIcon = Icons.hourglass_empty_rounded;
        }

        final validCnic = cnic.isNotEmpty && !cnic.startsWith('unknown_') && cnic != '00000-0000000-0' && cnic != '-' ? cnic : '';
        final validGuard = guardianCnic.isNotEmpty && !guardianCnic.startsWith('unknown_') && guardianCnic != '00000-0000000-0' && guardianCnic != '-' ? guardianCnic : '';
        final displayCnic = validCnic.isNotEmpty
            ? validCnic
            : validGuard.isNotEmpty
                ? validGuard
                : '-';

        final seqNumber = LocalStorageService.formatTokenDisplay(serial);

        String campTag = (e['dispensaryTag'] ?? e['dispensaryId'] ?? '').toString().trim().toUpperCase();
        if (campTag.isEmpty || campTag == 'ALL') {
          final parts = serial.split('-');
          if (parts.length >= 3) {
            campTag = parts[1].toUpperCase();
          }
        }
        if (campTag == 'KAP' || campTag == 'KAPAYYA' || campTag == 'SADDAR' || campTag == 'SAD') {
          campTag = 'SADD';
        } else if (campTag == 'HC' || campTag == 'HAJI_CAMP' || campTag == 'HAJICAMP') {
          campTag = 'HAJI';
        }

        // Pharmacy tab: the row loaded in the dispense form is outlined for visual tracking.
        // STRICT ENFORCEMENT: Only the smallest waiting token is automatically selected.
        // Manual clicking or selecting rows to jump the queue is strictly disabled.
        final pharmacy = widget.pharmacy;
        final dispensingSerial = pharmacy?.dispensingSerial?.trim().toUpperCase() ?? '';
        final isDispensingRow = dispensingSerial.isNotEmpty && serial.trim().toUpperCase() == dispensingSerial;
        const VoidCallback? onRowTap = null;

        final row = Container(
          margin: const EdgeInsets.symmetric(vertical: 2.5),
          padding: EdgeInsets.symmetric(
              horizontal: isMobile ? 8 : 12, vertical: 6),
          decoration: BoxDecoration(
            color: _isDark
                ? SoftPalette.slate800
                : SoftPalette.gray50,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(
                color: isDispensingRow
                    ? (_isDark ? SoftPalette.teal350 : SoftPalette.teal600)
                    : (_isDark
                        ? SoftPalette.slate700
                        : SoftPalette.gray100),
                width: isDispensingRow ? 1.6 : 1),
          ),
          child: Row(
            children: [
              // ── Token Number Pill ──────────────────────────────
              Container(
                padding: const EdgeInsets.symmetric(
                    horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: badgeColor,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  '#$seqNumber',
                  style: const TextStyle(
                    color: SoftPalette.gray50,
                    fontWeight: FontWeight.bold,
                    fontSize: 13,
                  ),
                ),
              ),
              const SizedBox(width: 10),

              // ── Patient Info ──────────────────────────────────
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            name,
                            style: TextStyle(
                              fontWeight: FontWeight.bold,
                              fontSize: isMobile ? 13 : 14,
                              color: _isDark
                                  ? SoftPalette.gray50
                                  : SoftPalette.gray900A87,
                            ),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        if (days > 1) ...[
                          const SizedBox(width: 4),
                          Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 4, vertical: 1),
                            decoration: BoxDecoration(
                              color: SoftPalette.red400,
                              borderRadius:
                                  BorderRadius.circular(6),
                            ),
                            child: Text(
                              '×$days d',
                              style: const TextStyle(
                                  color: SoftPalette.gray50,
                                  fontSize: 9,
                                  fontWeight: FontWeight.bold),
                            ),
                          ),
                        ],
                      ],
                    ),
                    const SizedBox(height: 2),
                    Wrap(
                      spacing: 4,
                      runSpacing: 2,
                      crossAxisAlignment:
                          WrapCrossAlignment.center,
                      children: [
                        Tooltip(
                          message: 'Click to copy CNIC',
                          child: InkWell(
                            onTap: (displayCnic.isEmpty || displayCnic == '-')
                                ? null
                                : () {
                                    Clipboard.setData(ClipboardData(text: displayCnic));
                                    AppToast.clear();
                                    AppToast.showSnackBar(context, 
                                      SnackBar(
                                        content: Row(
                                          mainAxisSize: MainAxisSize.min,
                                          children: [
                                            const Icon(Icons.check_circle,
                                                color: SoftPalette.gray50, size: 16),
                                            const SizedBox(width: 8),
                                            Text('Copied: $displayCnic',
                                                style: const TextStyle(fontSize: 12)),
                                          ],
                                        ),
                                        duration: const Duration(seconds: 2),
                                        behavior: SnackBarBehavior.floating,
                                        backgroundColor: _teal,
                                        width: 250,
                                      ),
                                    );
                                  },
                            borderRadius: BorderRadius.circular(4),
                            child: Padding(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 3, vertical: 1),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Text(
                                    displayCnic,
                                    style: TextStyle(
                                      fontSize: 11,
                                      fontWeight: FontWeight.w600,
                                      color: _isDark
                                          ? SoftPalette.sky350
                                          : SoftPalette.teal550,
                                      decoration: (displayCnic.isNotEmpty && displayCnic != '-')
                                          ? TextDecoration.underline
                                          : TextDecoration.none,
                                      decorationStyle: TextDecorationStyle.dotted,
                                    ),
                                  ),
                                  if (displayCnic.isNotEmpty && displayCnic != '-') ...[
                                    const SizedBox(width: 3),
                                    Icon(
                                      Icons.copy,
                                      size: 10,
                                      color: _isDark
                                          ? SoftPalette.sky350
                                          : SoftPalette.teal550,
                                    ),
                                  ],
                                ],
                              ),
                            ),
                          ),
                        ),
                        Text('•',
                            style: TextStyle(
                                fontSize: 9,
                                color: context.adapt(SoftPalette.gray300))),
                        Text(
                          DateFormat('hh:mm a').format(timestamp),
                          style: TextStyle(
                            fontSize: 11,
                            color: _isDark
                                ? SoftPalette.slate350
                                : SoftPalette.gray500,
                          ),
                        ),
                        if ((e['session'] as String?)?.isNotEmpty == true) ...[
                          Text('•',
                              style: TextStyle(
                                  fontSize: 9,
                                  color: context.adapt(SoftPalette.gray300))),
                          Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 3, vertical: 1),
                            child: Text(
                              e['session'].toString(),
                              style: TextStyle(
                                fontSize: 10,
                                fontWeight: FontWeight.w600,
                                color: e['session'].toString().toLowerCase().contains('morn')
                                    ? SoftPalette.amber300
                                    : SoftPalette.indigo500,
                              ),
                            ),
                          ),
                        ],
                        if (_selectedCampFilter == 'all' && _hasMultiCamps && campTag.isNotEmpty) ...[
                          Text('•',
                              style: TextStyle(
                                  fontSize: 9,
                                  color: context.adapt(SoftPalette.gray300))),
                          Text(
                            campTag,
                            style: TextStyle(
                              fontSize: 10,
                              fontWeight: FontWeight.w600,
                              color: SoftPalette.teal500,
                            ),
                          ),
                        ],
                        if (hasExtraDays) ...[
                          Text('•',
                              style: TextStyle(
                                  fontSize: 9,
                                  color: context.adapt(SoftPalette.gray300))),
                          Text(
                            'PKR $tokenAmount',
                            style: TextStyle(
                              fontSize: 10,
                              fontWeight: FontWeight.bold,
                              color: SoftPalette.orange400,
                            ),
                          ),
                        ],
                      ],
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 6),

              // ── Fee Badge ─────────────────────────────────────
              Container(
                padding: const EdgeInsets.symmetric(
                    horizontal: 6, vertical: 2.5),
                decoration: BoxDecoration(
                  color: badgeColor.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(6),
                  border: Border.all(
                      color: badgeColor.withValues(alpha: 0.3)),
                ),
                child: Text(
                  displayType,
                  style: TextStyle(
                    color: badgeColor,
                    fontSize: 10,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
              const SizedBox(width: 4),

              // ── Status Chip ───────────────────────────────────
              Container(
                padding: const EdgeInsets.symmetric(
                    horizontal: 6, vertical: 2.5),
                decoration: BoxDecoration(
                  color: statusBg,
                  borderRadius: BorderRadius.circular(6),
                  border: Border.all(
                      color: statusText.withValues(alpha: 0.3)),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(statusIcon, size: 11, color: statusText),
                    const SizedBox(width: 3),
                    Text(
                      statusLabel,
                      style: TextStyle(
                        color: statusText,
                        fontSize: 10,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ),

              // ── Undo / Reversal ───────────────────────────────
              if (canReverse) ...[
                const SizedBox(width: 2),
                IconButton(
                  icon: const Icon(Icons.undo,
                      color: SoftPalette.red400, size: 16),
                  tooltip: 'Cancel / Reverse Token',
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(
                      minWidth: 26, minHeight: 26),
                  onPressed: () => _requestTokenReverse(e),
                ),
              ],
            ],
          ),
        );
        if (onRowTap == null) return row;
        return Tooltip(
          message: isDispensingRow ? 'In the dispense form' : 'Dispense this patient',
          waitDuration: const Duration(milliseconds: 600),
          child: InkWell(
            onTap: onRowTap,
            borderRadius: BorderRadius.circular(10),
            child: row,
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final isMobile = GBreakpoint.isCompact(context);

    if (!Hive.isBoxOpen('app_settings')) {
      return FutureBuilder<Box>(
        future: lss.LocalStorageService.ensureBoxOpen('app_settings'),
        builder: (context, snapshot) {
          if (!snapshot.hasData || snapshot.data == null || !snapshot.data!.isOpen) {
            return const Scaffold(
              body: Center(child: CircularProgressIndicator(color: SoftPalette.emerald550)),
            );
          }
          final isDark = snapshot.data!.get('is_dark_mode', defaultValue: false) == true;
          return _buildScaffoldWithTheme(context, isDark, isMobile);
        },
      );
    }

    return ValueListenableBuilder<Box>(
      valueListenable: Hive.box('app_settings').listenable(keys: ['is_dark_mode']),
      builder: (context, box, _) {
        final isDark = box.isOpen ? (box.get('is_dark_mode', defaultValue: false) == true) : false;
        return _buildScaffoldWithTheme(context, isDark, isMobile);
      },
    );
  }

  Widget _buildScaffoldWithTheme(BuildContext context, bool isDark, bool isMobile) {
    final body = Container(
      decoration: BoxDecoration(
        color: isDark ? SoftPalette.slate900 : SoftPalette.emerald100t,
      ),
      child: Column(
        children: [
          ClockSkewWarningBanner(branchId: widget.branchId),
          Expanded(
            child: widget.pharmacy != null
                ? _buildPharmacyBody(isMobile)
                : (isMobile ? _buildMobileBody() : _buildDesktopBody()),
          ),
        ],
      ),
    );

    if (widget.isEmbedded) return body;

    return Scaffold(
      backgroundColor: isDark ? SoftPalette.slate900 : SoftPalette.emerald100t,
      appBar: _buildAppBar(isMobile),
      body: body,
    );
  }

  Widget _buildWithEntriesListenable(Widget Function(BuildContext, Box?, Widget?) builder) {
    if (Hive.isBoxOpen(lss.LocalStorageService.entriesBox)) {
      final box = Hive.box(lss.LocalStorageService.entriesBox);
      if (box.isOpen) {
        return ValueListenableBuilder<Box>(
          valueListenable: DebouncedBoxListenable.shared(box),
          builder: (ctx, b, w) {
            try {
              if (!b.isOpen) {
                return const Center(
                  child: Padding(
                    padding: EdgeInsets.all(24),
                    child: CircularProgressIndicator(color: SoftPalette.emerald550),
                  ),
                );
              }
              return PerfTrace.measure('receptionist list/summary build (${b.length} entries)', () => builder(ctx, b, w), thresholdMs: 30);
            } catch (e) {
              return const Center(
                child: Padding(
                  padding: EdgeInsets.all(24),
                  child: CircularProgressIndicator(color: SoftPalette.emerald550),
                ),
              );
            }
          },
        );
      }
    }
    return FutureBuilder<Box>(
      future: lss.LocalStorageService.ensureBoxOpen(lss.LocalStorageService.entriesBox),
      builder: (context, snapshot) {
        if (snapshot.hasData && snapshot.data != null && snapshot.data!.isOpen) {
          return ValueListenableBuilder<Box>(
            valueListenable: DebouncedBoxListenable.shared(snapshot.data!),
            builder: (ctx, b, w) {
              try {
                if (!b.isOpen) {
                  return const Center(
                    child: Padding(
                      padding: EdgeInsets.all(24),
                      child: CircularProgressIndicator(color: SoftPalette.emerald550),
                    ),
                  );
                }
                return builder(ctx, b, w);
              } catch (e) {
                return const Center(
                  child: Padding(
                    padding: EdgeInsets.all(24),
                    child: CircularProgressIndicator(color: SoftPalette.emerald550),
                  ),
                );
              }
            },
          );
        }
        return const Center(
          child: Padding(
            padding: EdgeInsets.all(24),
            child: CircularProgressIndicator(color: SoftPalette.emerald550),
          ),
        );
      },
    );
  }

  Widget _buildMobileBody() {
    return Column(children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(4, 6, 4, 4),
        child: _buildWithEntriesListenable(
          (context, _, _) => _buildSummaryCards(true),
        ),
      ),
      _buildMobileToggle(),
      Expanded(
        child: TabBarView(
          controller: _mobileTabController,
          children: [
            // Tab 0: Token
            Padding(
              padding: const EdgeInsets.all(8),
              child: Card(
                elevation: 4,
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(16)),
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: TokenScreen(
                    key: _tokenKey,
                    branchId: widget.branchId,
                    receptionistId: widget.receptionistId,
                    receptionistName: widget.receptionistName,
                    initialCnic: _pendingCnic,
                    targetPatientId: _pendingPatientId,
                    onPatientNotFound: _handlePatientNotFound,
                  ),
                ),
              ),
            ),
            // Tab 1: Log
            Padding(
              padding: const EdgeInsets.all(8),
              child: Column(children: [
                Row(children: [
                  Text("Today's Tokens",
                      style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.bold,
                          color: _teal)),
                  const Spacer(),
                  IconButton(
                    icon: Icon(
                        _sortNewestFirst
                            ? Icons.arrow_downward_rounded
                            : Icons.arrow_upward_rounded,
                        color: _teal,
                        size: 20),
                    onPressed: () =>
                        setState(() => _sortNewestFirst = !_sortNewestFirst),
                  ),
                  // Refresh Button
                  IconButton(
                    icon: const Icon(Icons.refresh, color: _teal, size: 20),
                    onPressed: _refreshTokenLog,
                    tooltip: 'Refresh token list',
                  ),
                  WhatsAppShareButton(onPressed: _shareCollectionToWhatsApp),
                ]),
                const SizedBox(height: 4),
                Row(
                  children: [
                    Text(
                      '${_getFilteredTodayTokens().length} total',
                      style: TextStyle(
                        fontSize: 12,
                        color: _isDark ? SoftPalette.slate350 : SoftPalette.gray550,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                Expanded(
                  child: ValueListenableBuilder<int>(
                    valueListenable: _refreshNotifier,
                    builder: (context, _, _) => _buildWithEntriesListenable(
                      (context, _, _) => _buildTokenLog(true),
                    ),
                  ),
                ),
              ]),
            ),
            // Tab 2: Register
            Padding(
              padding: const EdgeInsets.all(8),
              child: Card(
                elevation: 4,
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(16)),
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: PatientRegisterPage(
                    key: _registerKey,
                    branchId: widget.branchId,
                    receptionistId: widget.receptionistId,
                    initialCnic: _pendingCnic,
                    onPatientRegistered: _onPatientRegistered,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    ]);
  }

  /// Register Patient or Issue Token (with vitals) — shared by the desktop body
  /// and the Hybrid Pharmacy layout.
  Widget _buildReceptionForm() {
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 120),
      child: _activeSection == 'register'
          ? PatientRegisterPage(
              key: _registerKey,
              branchId: widget.branchId,
              receptionistId: widget.receptionistId,
              initialCnic: _pendingCnic,
              onPatientRegistered: _onPatientRegistered,
            )
          : TokenScreen(
              key: _tokenKey,
              branchId: widget.branchId,
              receptionistId: widget.receptionistId,
              receptionistName: widget.receptionistName,
              initialCnic: _pendingCnic,
              targetPatientId: _pendingPatientId,
              onPatientNotFound: _handlePatientNotFound,
            ),
    );
  }

  // ── Hybrid "Pharmacy" layout ──────────────────────────────────────────────
  //   [ Today's collection strip (Zakat / Non-Zakat / GMWF / Issued by me) ⓦ ]
  //   [ Reception (Register | Token & Vitals) ][ Today's Tokens ][ Dispense ]
  // Reception and Today's Tokens are this screen's own widgets and handlers
  // (reverse token, shift filter, refresh…); the dispense pane comes from the host.

  Widget _buildPharmacyBody(bool isNarrow) {
    final slots = widget.pharmacy!;
    const gap = kPharmacyPad;

    final strip = ValueListenableBuilder<int>(
      valueListenable: _refreshNotifier,
      builder: (context, _, _) => _buildWithEntriesListenable((context, _, _) {
        final todayEntries = _getFilteredTodayTokens();
        return TodayCollectionStrip(
          tally: TokenTally.of(todayEntries, isKarachi: _isKarachi),
          isKarachi: _isKarachi,
          onShare: () => _shareCollectionToWhatsApp(todayEntries),
        );
      }),
    );

    return ValueListenableBuilder<Box>(
      valueListenable: DispensaryPreferencesService.pharmacyPaneOrderListenable(widget.receptionistId),
      builder: (context, _, _) {
        final paneOrder = DispensaryPreferencesService.getPharmacyPanes(widget.receptionistId);

        Widget buildChildPane(String id) {
          switch (id) {
            case 'dispense':
              return slots.dispensePane;
            case 'reception':
              return _pharmacyReceptionPane();
            case 'tokens':
            default:
              return _pharmacyTokensPane();
          }
        }

        return LayoutBuilder(builder: (context, box) {
          if (isNarrow || box.maxWidth < 900) {
            return DefaultTabController(
              key: ValueKey('narrow_tabs_${paneOrder.join('_')}'),
              length: 3,
              child: Column(
                children: [
                  Padding(padding: const EdgeInsets.fromLTRB(gap, gap, gap, 0), child: strip),
                  _pharmacyNarrowTabBar(paneOrder),
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.all(gap),
                      child: TabBarView(
                        children: paneOrder.map(buildChildPane).toList(),
                      ),
                    ),
                  ),
                ],
              ),
            );
          }

          // Desktop view: build columns according to preferred order
          final isLargeScreen = box.maxWidth >= 1300;
          Widget panes;
          if (isLargeScreen) {
            final columns = <Widget>[];
            for (int i = 0; i < paneOrder.length; i++) {
              if (i > 0) columns.add(const SizedBox(width: gap));
              final id = paneOrder[i];
              if (id == 'tokens') {
                columns.add(SizedBox(
                  width: box.maxWidth >= 1700 ? 460 : 380,
                  child: _pharmacyTokensPane(),
                ));
              } else if (id == 'reception') {
                columns.add(Expanded(flex: 5, child: _pharmacyReceptionPane()));
              } else {
                columns.add(Expanded(flex: 6, child: slots.dispensePane));
              }
            }
            panes = Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: columns,
            );
          } else {
            // Below 1300px: first pane on left, other two stacked on right
            final firstId = paneOrder[0];
            final secondId = paneOrder[1];
            final thirdId = paneOrder[2];

            Widget firstWidget = firstId == 'tokens'
                ? SizedBox(width: 360, child: _pharmacyTokensPane())
                : Expanded(flex: 5, child: buildChildPane(firstId));

            panes = Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                firstWidget,
                const SizedBox(width: gap),
                Expanded(
                  flex: firstId == 'tokens' ? 1 : 6,
                  child: Column(
                    children: [
                      Expanded(child: buildChildPane(secondId)),
                      const SizedBox(height: gap),
                      Expanded(child: buildChildPane(thirdId)),
                    ],
                  ),
                ),
              ],
            );
          }

          return Padding(
            padding: const EdgeInsets.all(gap),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                strip,
                const SizedBox(height: gap),
                Expanded(child: panes),
              ],
            ),
          );
        });
      },
    );
  }

  Widget _pharmacyNarrowTabBar(List<String> paneOrder) {
    final c = context.comfort;
    final tabs = paneOrder.map((id) {
      switch (id) {
        case 'dispense':
          return const Tab(text: 'Dispense');
        case 'reception':
          return const Tab(text: 'Reception');
        case 'tokens':
        default:
          return const Tab(text: "Today's Tokens");
      }
    }).toList();

    return TabBar(
      labelColor: c.brand,
      unselectedLabelColor: c.textSecondary,
      indicatorColor: c.brand,
      dividerColor: c.border,
      labelStyle: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700),
      unselectedLabelStyle: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600),
      tabs: tabs,
    );
  }

  Widget _pharmacyReceptionPane() {
    return PharmacyPane(
      icon: Icons.support_agent_rounded,
      title: 'Reception',
      actions: [
        PaneSegment(
          icon: Icons.person_add_alt_1_rounded,
          label: 'Register',
          selected: _activeSection == 'register',
          onTap: () => setState(() => _activeSection = 'register'),
        ),
        const SizedBox(width: 6),
        PaneSegment(
          icon: Icons.confirmation_number_outlined,
          label: 'Token & Vitals',
          selected: _activeSection != 'register',
          // Same as the desktop toggle: switching to Token clears a pending hand-off.
          onTap: () => setState(() {
            _activeSection = 'token';
            _pendingCnic = '';
            _pendingPatientId = null;
          }),
        ),
        const SizedBox(width: 4),
      ],
      child: Padding(
        padding: const EdgeInsets.all(kPharmacyPad),
        child: _buildReceptionForm(),
      ),
    );
  }

  Widget _pharmacyTokensPane() {
    final c = context.comfort;
    return PharmacyPane(
      icon: Icons.format_list_bulleted_rounded,
      title: "Today's Tokens",
      actions: [
        PaneAction(
          icon: _sortNewestFirst ? Icons.arrow_downward_rounded : Icons.arrow_upward_rounded,
          tooltip: _sortNewestFirst ? 'Sort: Oldest First' : 'Sort: Newest First',
          onPressed: () => setState(() => _sortNewestFirst = !_sortNewestFirst),
        ),
        PaneAction(
          icon: Icons.refresh_rounded,
          tooltip: 'Refresh token list',
          busy: _isSyncing,
          onPressed: _refreshTokenLog,
        ),
      ],
      child: ValueListenableBuilder<int>(
        valueListenable: _refreshNotifier,
        builder: (context, _, _) => _buildWithEntriesListenable((context, _, _) {
          final todayEntries = _getFilteredTodayTokens();
          return Padding(
            padding: const EdgeInsets.fromLTRB(kPharmacyPad, 8, kPharmacyPad, 6),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _buildShiftSelector(false),
                const SizedBox(height: 6),
                Text(
                  '${todayEntries.length} total · Auto-serving smallest token',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: c.textSecondary),
                ),
                Divider(height: 12, color: c.border),
                Expanded(child: _buildTokenLog(false, todayEntries)),
              ],
            ),
          );
        }),
      ),
    );
  }

  Widget _buildDesktopBody() {
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 1650),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // ── Left Column (flex: 3): Action Toggle + Main Form Card ───────
              Expanded(
                flex: 3,
                child: Column(
                  children: [
                    _buildDesktopToggle(),
                    const SizedBox(height: 16),
                    Expanded(
                      child: Card(
                        elevation: 10,
                        color: _isDark ? SoftPalette.slate800 : SoftPalette.gray50,
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(28)),
                        clipBehavior: Clip.antiAlias,
                        child: Stack(
                          children: [
                            // ── Authentic Islamic Pattern Background (Vibrant Golden) ──
                            // Performance: this used to be Opacity (a full-card offscreen layer) around a
                            // tinted full-size image, repainted on every cursor blink and keystroke in the
                            // form above it. Now the opacity is folded into the tint, the image is decoded
                            // at a sensible size, and a RepaintBoundary lets Flutter keep it as a cached
                            // layer that typing never touches.
                            Positioned.fill(
                              child: RepaintBoundary(
                                child: IgnorePointer(
                                  child: GDecorativeImage.asset(
                                    'assets/images/islamic_pattern.webp',
                                    fit: BoxFit.cover,
                                    cacheWidth: 1400,
                                    filterQuality: FilterQuality.low,
                                    color: (_isDark ? SoftPalette.amber200 : SoftPalette.yellow300)
                                        .withValues(alpha: _isDark ? 0.18 : 0.28),
                                    colorBlendMode: BlendMode.srcIn,
                                  ),
                                ),
                              ),
                            ),

                            // ── Form Content ──
                            Padding(
                              padding: const EdgeInsets.all(28),
                              child: _buildReceptionForm(),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 20),

              // ── Right Column (flex: 2): Summary Cards + Today's Tokens Card ──
              Expanded(
                flex: 2,
                child: ValueListenableBuilder<int>(
                  valueListenable: _refreshNotifier,
                  builder: (context, _, _) => _buildWithEntriesListenable(
                    (context, _, _) {
                      final todayEntries = _getFilteredTodayTokens();
                      final todayCount = todayEntries.length;
                      return Column(
                        children: [
                          _buildSummaryCards(false, todayEntries),
                          const SizedBox(height: 16),
                          Expanded(
                            child: Card(
                                elevation: 8,
                                color: _isDark ? SoftPalette.slate800 : SoftPalette.gray50,
                                shape: RoundedRectangleBorder(
                                    borderRadius:
                                        BorderRadius.circular(24)),
                                clipBehavior: Clip.antiAlias,
                                child: Stack(
                                  children: [
                                    // ── Vibrant Golden Islamic Watermark (Center Touching Right Edge + Rotated) ──
                                    Positioned(
                                      right: -135,
                                      bottom: -50,
                                      width: 320,
                                      height: 320,
                                      child: IgnorePointer(
                                        child: Transform.rotate(
                                          angle: -0.16, // ~9.2 degrees graceful tilt
                                          child: Opacity(
                                            opacity: _isDark ? 0.22 : 0.32,
                                            child: GDecorativeImage.asset(
                                              'assets/images/1.webp',
                                              fit: BoxFit.contain,
                                              color: _isDark ? SoftPalette.amber200 : SoftPalette.yellow300,
                                              colorBlendMode: BlendMode.srcIn,
                                            ),
                                          ),
                                        ),
                                      ),
                                    ),

                                    // ── Today's Tokens Content ──
                                    Padding(
                                      padding: const EdgeInsets.all(20),
                                      child: Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        children: [
                                          Row(children: [
                                            Icon(Icons.list_alt_rounded,
                                                color: _isDark ? SoftPalette.sky350 : _teal, size: 26),
                                            const SizedBox(width: 10),
                                            Text("Today's Tokens",
                                                style: TextStyle(
                                                    fontSize: 19,
                                                    fontWeight:
                                                        FontWeight.bold,
                                                    color: _isDark ? SoftPalette.gray50 : _teal)),
                                            const Spacer(),
                                            IconButton(
                                              icon: Icon(
                                                  _sortNewestFirst
                                                      ? Icons
                                                          .arrow_downward_rounded
                                                      : Icons
                                                          .arrow_upward_rounded,
                                                  color: _isDark ? SoftPalette.sky350 : _teal,
                                                  size: 20),
                                              onPressed: () => setState(() =>
                                                  _sortNewestFirst =
                                                      !_sortNewestFirst),
                                              tooltip: _sortNewestFirst
                                                  ? 'Sort: Oldest First'
                                                  : 'Sort: Newest First',
                                            ),
                                            IconButton(
                                              icon: Icon(Icons.refresh_rounded,
                                                  color: _isDark ? SoftPalette.sky350 : _teal, size: 22),
                                              onPressed: _refreshTokenLog,
                                              tooltip: 'Refresh token list',
                                            ),
                                            WhatsAppShareButton(
                                              onPressed: () => _shareCollectionToWhatsApp(todayEntries),
                                            ),
                                          ]),
                                          const SizedBox(height: 10),
                                          _buildShiftSelector(false),
                                          const SizedBox(height: 6),
                                          Row(
                                            children: [
                                              Text('$todayCount total',
                                                  style: TextStyle(
                                                      color: _isDark ? SoftPalette.slate350 : SoftPalette.gray550,
                                                      fontSize: 13,
                                                      fontWeight: FontWeight.w600)),
                                            ],
                                          ),
                                          const Divider(height: 20),
                                          Expanded(child: _buildTokenLog(false, todayEntries)),
                                        ],
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                        ],
                      );
                    },
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildMobileToggle() {
    return AnimatedBuilder(
      animation: _mobileTabController,
      builder: (context, _) {
        final activeIndex = _mobileTabController.index;
        return Container(
          width: double.infinity,
          height: 44,
          margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          padding: const EdgeInsets.all(3),
          decoration: BoxDecoration(
            color: _isDark ? SoftPalette.slate800 : SoftPalette.gray50,
            borderRadius: BorderRadius.circular(24),
            border: Border.all(
              color: _isDark ? SoftPalette.slate700 : SoftPalette.slate150,
              width: 1.2,
            ),
            boxShadow: [
              BoxShadow(
                color: SoftPalette.gray900.withValues(alpha: _isDark ? 0.20 : 0.04),
                blurRadius: 6,
                offset: const Offset(0, 2),
              )
            ],
          ),
          child: Row(
            children: [
              _buildMobileToggleButton(
                label: 'Issue Token',
                icon: Icons.confirmation_number_outlined,
                isSelected: activeIndex == 0,
                onTap: () {
                  setState(() {
                    _pendingCnic = '';
                    _pendingPatientId = null;
                  });
                  _mobileTabController.animateTo(0);
                },
              ),
              _buildMobileToggleButton(
                label: 'Register Patient',
                icon: Icons.person_add_alt_1_rounded,
                isSelected: activeIndex == 2,
                onTap: () => _mobileTabController.animateTo(2),
              ),
              _buildMobileToggleButton(
                label: "Today's Log",
                icon: Icons.format_list_bulleted_rounded,
                isSelected: activeIndex == 1,
                onTap: () => _mobileTabController.animateTo(1),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildMobileToggleButton({
    required String label,
    required IconData icon,
    required bool isSelected,
    required VoidCallback onTap,
  }) {
    return Expanded(
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(20),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 200),
            alignment: Alignment.center,
            decoration: BoxDecoration(
              gradient: isSelected
                  ? const LinearGradient(
                      colors: [SoftPalette.emerald400, SoftPalette.emerald550],
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                    )
                  : null,
              borderRadius: BorderRadius.circular(20),
              boxShadow: isSelected
                  ? [
                      BoxShadow(
                        color: SoftPalette.emerald400.withValues(alpha: _isDark ? 0.4 : 0.25),
                        blurRadius: 8,
                        offset: const Offset(0, 2),
                      )
                    ]
                  : null,
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  icon,
                  size: 14,
                  color: isSelected
                      ? SoftPalette.gray50
                      : (_isDark ? SoftPalette.slate350 : SoftPalette.slate550),
                ),
                const SizedBox(width: 4),
                Flexible(
                  child: Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: isSelected ? FontWeight.bold : FontWeight.w600,
                      color: isSelected
                          ? SoftPalette.gray50
                          : (_isDark ? SoftPalette.slate350 : SoftPalette.slate550),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildDesktopToggle() {
    final isToken = _activeSection == 'token';
    return Container(
      width: double.infinity,
      height: 54,
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: _isDark ? SoftPalette.slate800 : SoftPalette.gray50,
        borderRadius: BorderRadius.circular(32),
        border: Border.all(
          color: _isDark ? SoftPalette.slate700 : SoftPalette.slate150,
          width: 1.5,
        ),
        boxShadow: [
          BoxShadow(
            color: SoftPalette.gray900.withValues(alpha: _isDark ? 0.20 : 0.04),
            blurRadius: 8,
            offset: const Offset(0, 2),
          )
        ],
      ),
      child: Row(
        children: [
          // ── Register Patient ──────────────────────────────────────────
          Expanded(
            child: Material(
              color: Colors.transparent,
              child: InkWell(
                onTap: () => setState(() => _activeSection = 'register'),
                borderRadius: BorderRadius.circular(28),
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 250),
                  curve: Curves.easeInOut,
                  alignment: Alignment.center,
                  padding: const EdgeInsets.symmetric(vertical: 10),
                  decoration: BoxDecoration(
                    gradient: !isToken
                        ? const LinearGradient(
                            colors: [SoftPalette.emerald400, SoftPalette.emerald550],
                            begin: Alignment.topLeft,
                            end: Alignment.bottomRight,
                          )
                        : null,
                    borderRadius: BorderRadius.circular(28),
                    boxShadow: !isToken
                        ? [
                            BoxShadow(
                              color: SoftPalette.emerald400.withValues(alpha: _isDark ? 0.45 : 0.35),
                              blurRadius: 14,
                              spreadRadius: 1,
                              offset: const Offset(0, 3),
                            )
                          ]
                        : null,
                  ),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(
                        Icons.person_add_alt_1_rounded,
                        size: 19,
                        color: !isToken
                            ? SoftPalette.gray50
                            : (_isDark ? SoftPalette.slate350 : SoftPalette.slate550),
                      ),
                      const SizedBox(width: 8),
                      Text(
                        'Register Patient',
                        style: TextStyle(
                          fontWeight: !isToken ? FontWeight.bold : FontWeight.w600,
                          fontSize: 14.5,
                          color: !isToken
                              ? SoftPalette.gray50
                              : (_isDark ? SoftPalette.slate350 : SoftPalette.slate550),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(width: 4),
          // ── Issue Token ───────────────────────────────────────────────
          Expanded(
            child: Material(
              color: Colors.transparent,
              child: InkWell(
                onTap: () => setState(() {
                  _activeSection = 'token';
                  _pendingCnic = '';
                  _pendingPatientId = null;
                }),
                borderRadius: BorderRadius.circular(28),
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 250),
                  curve: Curves.easeInOut,
                  alignment: Alignment.center,
                  padding: const EdgeInsets.symmetric(vertical: 10),
                  decoration: BoxDecoration(
                    gradient: isToken
                        ? const LinearGradient(
                            colors: [SoftPalette.emerald400, SoftPalette.emerald550],
                            begin: Alignment.topLeft,
                            end: Alignment.bottomRight,
                          )
                        : null,
                    borderRadius: BorderRadius.circular(28),
                    boxShadow: isToken
                        ? [
                            BoxShadow(
                              color: SoftPalette.emerald400.withValues(alpha: _isDark ? 0.45 : 0.35),
                              blurRadius: 14,
                              spreadRadius: 1,
                              offset: const Offset(0, 3),
                            )
                          ]
                        : null,
                  ),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(
                        Icons.inventory_2_rounded,
                        size: 19,
                        color: isToken
                            ? SoftPalette.gray50
                            : (_isDark ? SoftPalette.slate350 : SoftPalette.slate550),
                      ),
                      const SizedBox(width: 8),
                      Text(
                        'Issue Token',
                        style: TextStyle(
                          fontWeight: isToken ? FontWeight.bold : FontWeight.w600,
                          fontSize: 14.5,
                          color: isToken
                              ? SoftPalette.gray50
                              : (_isDark ? SoftPalette.slate350 : SoftPalette.slate550),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  @override
  void dispose() {
    _debounceRebuildTimer?.cancel();
    CampSessionService.activeCampNotifier.removeListener(_onActiveCampChanged);
    ConnectionManager().removeReconnectListener(_onLanReconnected);
    _refreshNotifier.dispose();
    _mobileTabController.dispose();
    // The LAN link is shared by every desk screen and only logout stops it. Stopping it here
    // (e.g. when this screen was replaced or popped) left the PC disconnected, with Retry
    // doing nothing, until the next login.
    _connectionSub?.cancel();
    _connSub?.cancel();
    _realtimeSub?.cancel();
    super.dispose();
  }

  void _onLanReconnected() {
    if (!mounted) return;
    debugPrint('[Receptionist] 🔄 LAN reconnected — requesting catch-up from server');
    try {
      RealtimeManager().requestCatchUp(branchId: widget.branchId);
    } catch (_) {}
    _refreshNotifier.value++;
    setState(() {});
  }
}