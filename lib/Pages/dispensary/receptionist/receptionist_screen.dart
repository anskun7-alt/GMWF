// lib/pages/dispensary/receptionist/receptionist_screen.dart

import 'dart:async';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:intl/intl.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:another_flushbar/flushbar.dart';
import 'package:flutter/foundation.dart';
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

class ReceptionistScreen extends StatefulWidget {
  final String branchId;
  final String receptionistId;
  final String receptionistName;
  final bool isEmbedded;
  final bool suppressPrescriptionNotifications;

  const ReceptionistScreen({
    super.key,
    required this.branchId,
    required this.receptionistId,
    required this.receptionistName,
    this.isEmbedded = false,
    this.suppressPrescriptionNotifications = false,
  });

  @override
  State<ReceptionistScreen> createState() => _ReceptionistScreenState();
}

class _ReceptionistScreenState extends State<ReceptionistScreen>
    with SingleTickerProviderStateMixin, AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;
  String? _username;
  String? _branchName;
  String _pendingCnic = '';
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

  ConnectionStatus _connectionStatus = const ConnectionStatus(
    state: LanConnectionState.disconnected,
    message: 'Not connected',
  );

  static const Color _teal = Color(0xFF00695C);
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

    if (_hasMultiCamps) {
      final active = CampSessionService.getActiveCamp(widget.branchId);
      if (active != null && active.isNotEmpty && active != 'all') {
        _selectedCampFilter = active;
      }
    }

    lss.LocalStorageService.ensureBoxOpen(lss.LocalStorageService.patientsBox);
    lss.LocalStorageService.ensureBoxOpen(lss.LocalStorageService.entriesBox);

    if (!widget.isEmbedded) {
      SyncService().start(widget.branchId);
    }
    _loadBranchName();
    _listenConnectivity();
    if (!widget.isEmbedded) {
      _startBackgroundSync();
    }

    // [FIX-USERNAME] Load name first, then start ConnectionManager with it.
    // _fetchReceptionistName() starts the connection once the name is resolved.
    CampSessionService.activeCampNotifier.addListener(_onActiveCampChanged);
    _fetchReceptionistName();

    _connectionSub = ConnectionManager().statusStream.listen((status) {
      if (mounted) setState(() => _connectionStatus = status);
    });

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && !widget.isEmbedded) {
        UpdateDialogWidget.showUpdateDialogIfNeeded(context);
      }
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
            await lss.LocalStorageService.downloadAllPatients(widget.branchId);
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
                if (data != null) {
                  updated['prescription'] = data;
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
        if (mounted) setState(() {});
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
              color: const Color(0xFF10B981).withValues(alpha: 0.25),
              shape: BoxShape.circle,
            ),
            child: const Icon(
              Icons.notifications_active_rounded,
              color: Color(0xFF10B981),
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
                color: Colors.white,
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
                fontSize: 13, color: Color(0xFFCBD5E1), height: 1.3),
            children: [
              TextSpan(
                text: doctorName.isNotEmpty ? '$doctorName ' : 'Doctor ',
                style: const TextStyle(
                    fontWeight: FontWeight.bold, color: Colors.white),
              ),
              const TextSpan(text: 'finished consultation for '),
              TextSpan(
                text: '$tokenDisplay $patientName',
                style: const TextStyle(
                  fontWeight: FontWeight.w900,
                  color: Color(0xFF34D399),
                ),
              ),
              const TextSpan(
                  text: '. Please call and send in the next patient.'),
            ],
          ),
        ),
      ),
      backgroundColor: const Color(0xFF0F172A),
      borderRadius: BorderRadius.circular(16),
      margin: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
      flushbarPosition: FlushbarPosition.TOP,
      duration: const Duration(seconds: 6),
      animationDuration: const Duration(milliseconds: 350),
      boxShadows: [
        BoxShadow(
          color: const Color(0xFF10B981).withValues(alpha: 0.35),
          blurRadius: 18,
          spreadRadius: 1,
          offset: const Offset(0, 4),
        ),
        BoxShadow(
          color: Colors.black.withValues(alpha: 0.5),
          blurRadius: 12,
          offset: const Offset(0, 4),
        ),
      ],
      borderColor: const Color(0xFF10B981).withValues(alpha: 0.6),
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
          backgroundColor: Colors.green.shade700,
          duration: const Duration(seconds: 3),
        ).show(context);
      }
    } catch (e) {
      if (mounted) {
        Flushbar(
          message: 'Sync failed: $e',
          backgroundColor: Colors.red.shade700,
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

      // Re-download today's tokens (most reliable for reversal issues)
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
    if (mounted) setState(() => _isLoggingOut = true);
    try { _connectionSub?.cancel(); _connSub?.cancel(); _realtimeSub?.cancel(); } catch (_) {}
    ConnectionManager().stop().catchError((_) {});
    await AuthService().signOut();
    if (mounted) Navigator.pushNamedAndRemoveUntil(context, '/login', (r) => false);
  }

  void _handlePatientNotFound(String cnic) {
    setState(() {
      _pendingCnic = cnic;
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
      _pendingCnic = clean;
      _activeSection = 'token';
    });
    if (_mobileTabController.length > _tabToken) {
      _mobileTabController.animateTo(_tabToken);
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _tokenKey.currentState?.focusAndFillCnic(clean);
    });
  }

  Future<void> _requestTokenReverse(Map<String, dynamic> entry) async {
    final serial = entry['serial'] as String? ?? 'N/A';
    final patientName = entry['patientName'] as String? ?? 'Unknown';
    final reasonCtrl = TextEditingController();

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Request Token Reversal',
            style: TextStyle(color: Colors.orange)),
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
                backgroundColor: Colors.orange[800]),
            onPressed: () => Navigator.of(ctx).pop(true),
          ),
        ],
      ),
    );

    if (confirmed != true) return;

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

      try {
        await FirebaseFirestore.instance
            .collection('branches')
            .doc(widget.branchId)
            .collection('edit_requests')
            .doc(requestId)
            .set({
          ...reqPayload,
          'requestedAt': FieldValue.serverTimestamp(),
        });
      } catch (e) {
        debugPrint('[ReceptionistScreen] Firestore offline, saved locally: $e');
      }

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
          backgroundColor: Colors.orange[800]!,
          duration: const Duration(seconds: 4),
        ).show(context);
      }
    } catch (e) {
      if (mounted) {
        Flushbar(
          message: 'Failed to send request: $e',
          backgroundColor: Colors.red,
          duration: const Duration(seconds: 5),
        ).show(context);
      }
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
      title: 'Receptionist – ${_username ?? widget.receptionistName}',
      subtitle: CampSessionService.getBranchAndCampDisplayName(
        branchName: _branchName ?? 'Free Dispensary',
        branchId: widget.branchId,
        campId: CampSessionService.getActiveCamp(),
      ),
      onTitleLongPress: () => DispensaryUserSettingsDialog.show(
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
    final dk = (e['dateKey'] as String?)?.trim() ?? '';
    final rawTime = e['createdAt'] ?? e['timestamp'] ?? e['time'] ?? e['date'];

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

  List<Map<String, dynamic>> _getFilteredTodayTokens() {
    if (!Hive.isBoxOpen(lss.LocalStorageService.entriesBox)) return [];
    try {
      final today = CampSessionService.resolveShiftAndDateKey(DateTime.now(), widget.branchId).dateKey;
      final todayIso = DateFormat('yyyy-MM-dd').format(DateTime.now());
      final rawEntries = lss.LocalStorageService.getLocalEntries(widget.branchId);

    final filtered = rawEntries.where((e) {
      // 1. Date filter (today by dateKey, serial, or rollover tolerance)
      if (!_isEffectivelyToday(e, today, todayIso)) return false;

      final serial = (e['serial'] ?? e['id'])?.toString();
      if (!CampSessionService.isSerialMatchingBranch(serial, widget.branchId)) return false;

      // 2. Deleted status filter
      final st = (e['status'] as String?)?.toLowerCase().trim();
      final syncSt = (e['syncStatus'] as String?)?.toLowerCase().trim();
      if (st == 'deleted' || syncSt == 'deleted') return false;

      // 3. Must have valid patient name or cnic
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

      // 4. Camp Filter (Uses selected camp filter if set)
      if (_hasMultiCamps && _selectedCampFilter.isNotEmpty && _selectedCampFilter != 'all') {
        final matches = CampSessionService.matchesCamp(
          selectedCamp: _selectedCampFilter,
          dispensaryId: e['dispensaryId']?.toString(),
          campId: e['campId']?.toString(),
          dispensaryTag: e['dispensaryTag']?.toString(),
          serial: serial,
        );
        if (!matches) return false;
      }

      // 5. Shift Filter (Supports 'all', 'morning', 'evening', 'night')
      if (_selectedSessionFilter != 'all') {
        final eSession = (e['session'] as String?)?.trim().toLowerCase() ?? '';
        if (eSession.isNotEmpty) {
          if (eSession != _selectedSessionFilter) return false;
        } else {
          final rawTime = e['createdAt'] ?? e['timestamp'] ?? e['time'];
          if (rawTime != null) {
            final dt = DateTime.tryParse(rawTime.toString());
            if (dt != null && CampSessionService.getCurrentSession(dt, widget.branchId) != _selectedSessionFilter) {
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

    return uniqueBySerial.values.toList();
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

    int all = 0, morning = 0, evening = 0, night = 0;

    final Map<String, Map<String, dynamic>> uniqueBySerial = {};
    for (final e in rawEntries) {
      if (!_isEffectivelyToday(e, today, todayIso)) continue;

      final serial = (e['serial'] ?? e['id'])?.toString();
      if (!CampSessionService.isSerialMatchingBranch(serial, widget.branchId)) continue;
      final st = (e['status'] as String?)?.toLowerCase().trim();
      final syncSt = (e['syncStatus'] as String?)?.toLowerCase().trim();
      if (st == 'deleted' || syncSt == 'deleted') continue;
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
          if (serial == null || serial.isEmpty) continue;
        }
      }

      if (_hasMultiCamps && _selectedCampFilter.isNotEmpty && _selectedCampFilter != 'all') {
        final matches = CampSessionService.matchesCamp(
          selectedCamp: _selectedCampFilter,
          dispensaryId: e['dispensaryId']?.toString(),
          campId: e['campId']?.toString(),
          dispensaryTag: e['dispensaryTag']?.toString(),
          serial: serial,
        );
        if (!matches) continue;
      }

      String s = (e['serial'] ?? e['id'] ?? '').toString().trim().toUpperCase();
      final branchPrefix = '${widget.branchId.trim().toUpperCase()}-';
      if (s.startsWith(branchPrefix)) {
        s = s.substring(branchPrefix.length);
      }
      if (s.isNotEmpty) {
        uniqueBySerial[s] = e;
      }
    }

    all = uniqueBySerial.length;
    for (final e in uniqueBySerial.values) {
      final eSession = (e['session'] as String?)?.trim().toLowerCase() ?? '';
      String resolved = eSession;
      if (resolved.isEmpty) {
        final rawTime = e['timestamp'] ?? e['createdAt'] ?? e['date'];
        if (rawTime != null) {
          final dt = DateTime.tryParse(rawTime.toString());
          if (dt != null) resolved = CampSessionService.getCurrentSession(dt);
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
              onTap: () => setState(() => _selectedSessionFilter = id),
              borderRadius: BorderRadius.circular(20),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 200),
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                decoration: BoxDecoration(
                  color: isSelected
                      ? const Color(0xFF00875A)
                      : (_isDark ? const Color(0xFF334155) : Colors.grey.shade100),
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(
                    color: isSelected
                        ? const Color(0xFF00875A)
                        : (_isDark ? const Color(0xFF475569) : Colors.grey.shade300),
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
                            ? Colors.white
                            : (_isDark ? Colors.white70 : Colors.black87),
                      ),
                    ),
                    const SizedBox(width: 5),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                      decoration: BoxDecoration(
                        color: isSelected
                            ? Colors.white.withValues(alpha: 0.25)
                            : (_isDark ? const Color(0xFF1E293B) : Colors.grey.shade300),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Text(
                        '$count',
                        style: TextStyle(
                          fontSize: 10,
                          fontWeight: FontWeight.bold,
                          color: isSelected
                              ? Colors.white
                              : (_isDark ? const Color(0xFF38BDF8) : const Color(0xFF00796B)),
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
        color: isDark ? const Color(0xFF334155) : Colors.grey.shade100,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: isDark ? const Color(0xFF475569) : Colors.grey.shade300,
        ),
      ),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<String>(
          value: items.any((i) => i['id'] == value) ? value : items.first['id'],
          isDense: true,
          icon: Icon(Icons.arrow_drop_down,
              size: 16, color: isDark ? const Color(0xFF38BDF8) : _teal),
          dropdownColor: isDark ? const Color(0xFF1E293B) : Colors.white,
          style: TextStyle(
            fontSize: 11,
            fontWeight: FontWeight.w600,
            color: isDark ? Colors.white : Colors.black87,
          ),
          items: items.map((i) {
            return DropdownMenuItem<String>(
              value: i['id'],
              child: Text(i['label']!,
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                    color: isDark ? Colors.white : Colors.black87,
                  )),
            );
          }).toList(),
          onChanged: onChanged,
        ),
      ),
    );
  }

  Widget _buildSummaryCards(bool isMobile) {
    try {
      final todayEntries = _getFilteredTodayTokens();

      int zakat = 0, nonZakat = 0, gmwf = 0;
      int zakatAmount = 0, nonZakatAmount = 0;

      for (final e in todayEntries) {
        var qt = (e['queueType'] as String?)?.toLowerCase().trim() ?? 'unknown';
        if (_isKarachi && (qt == 'non-zakat' || qt.contains('non'))) {
          qt = 'zakat';
        }
        final days = _getDaysOfMedicine(e);
        switch (qt) {
          case 'zakat':
            zakat++;
            zakatAmount += 20 * days;
            break;
          case 'non-zakat':
            nonZakat++;
            nonZakatAmount += 100 * days;
            break;
          case 'gmwf':
            gmwf++;
            break;
          default:
            zakat++;
            zakatAmount += 20 * days;
        }
      }

      final total = zakat + nonZakat + gmwf;
      final totalAmount = zakatAmount + nonZakatAmount;

      final cards = [
        _compactSummaryCard(
          _isKarachi ? 'PKR 20' : 'Zakat',
          zakat,
          'PKR $zakatAmount',
          const Color(0xFF00875A), // Solid Emerald Green
          Icons.volunteer_activism_rounded,
          isMobile: isMobile,
        ),
        _compactSummaryCard(
          _isKarachi ? 'PKR 100' : 'Non-Zakat',
          nonZakat,
          _isKarachi && nonZakat == 0 ? 'Disabled 🔒' : 'PKR $nonZakatAmount',
          const Color(0xFF00875A),
          Icons.person_outline_rounded,
          isMobile: isMobile,
          isOutlined: true,
          outlineColor: const Color(0xFF00875A), // Green Outline on White Card
        ),
        _compactSummaryCard(
          'GMWF',
          gmwf,
          'PKR 0',
          const Color(0xFFD97706), // Solid Amber
          null,
          isImage: true,
          isMobile: isMobile,
        ),
        _compactSummaryCard(
          'Total',
          total,
          'PKR $totalAmount',
          const Color(0xFFD97706),
          Icons.people_outline_rounded,
          isMobile: isMobile,
          isOutlined: true,
          outlineColor: const Color(0xFFD97706), // Amber Outline on White Card
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

  int _getDaysOfMedicine(Map<String, dynamic> entry) {
    final topLevel = entry['daysOfMedicine'];
    if (topLevel is int) return topLevel.clamp(1, 99);
    final presc = entry['prescription'];
    if (presc is Map) {
      final nested = presc['daysOfMedicine'];
      if (nested is int) return nested.clamp(1, 99);
    }
    return 1;
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
    final effectiveOutline = outlineColor ?? solidColor;
    final bgColor = isOutlined
        ? (_isDark ? const Color(0xFF1E293B) : Colors.white)
        : solidColor;
    final primaryTextColor = isOutlined
        ? (_isDark ? Colors.white : effectiveOutline)
        : Colors.white;
    final secondaryTextColor = isOutlined
        ? (_isDark
            ? const Color(0xFF94A3B8)
            : effectiveOutline.withValues(alpha: 0.85))
        : Colors.white.withValues(alpha: 0.85);

    return Container(
      height: isMobile ? 66 : 76,
      decoration: BoxDecoration(
        color: bgColor,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: isOutlined
              ? effectiveOutline
              : Colors.white.withValues(alpha: 0.22),
          width: isOutlined ? 1.6 : 1.2,
        ),
        boxShadow: [
          BoxShadow(
            color: isOutlined
                ? effectiveOutline.withValues(alpha: _isDark ? 0.25 : 0.15)
                : solidColor.withValues(alpha: _isDark ? 0.45 : 0.35),
            blurRadius: isOutlined ? 10 : 14,
            spreadRadius: 1,
            offset: const Offset(0, 4),
          ),
          BoxShadow(
            color: Colors.black.withValues(alpha: _isDark ? 0.30 : 0.06),
            blurRadius: 6,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      padding: EdgeInsets.symmetric(
        horizontal: isMobile ? 5 : 10,
        vertical: isMobile ? 4 : 8,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Flexible(
                child: Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: primaryTextColor,
                    fontSize: isMobile ? 9.5 : 12,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 0.1,
                  ),
                ),
              ),
              const SizedBox(width: 2),
              if (isImage)
                Image.asset(
                  'assets/logo/gmwf-1.webp',
                  height: isMobile ? 12 : 17,
                  fit: BoxFit.contain,
                )
              else if (icon != null)
                Icon(icon, size: isMobile ? 12 : 16, color: primaryTextColor),
            ],
          ),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              FittedBox(
                fit: BoxFit.scaleDown,
                child: Text(
                  '$count',
                  style: TextStyle(
                    color: primaryTextColor,
                    fontSize: isMobile ? 16 : 22,
                    fontWeight: FontWeight.w900,
                    height: 1.0,
                  ),
                ),
              ),
              if (!isMobile)
                Text(
                  amount,
                  style: TextStyle(
                    color: secondaryTextColor,
                    fontSize: 10,
                    fontWeight: FontWeight.w600,
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildTokenLog(bool isMobile) {
    final rawList = _getFilteredTodayTokens();

    rawList.sort((a, b) {
      final sa = (a['serial'] as String? ?? '000000-000').split('-').last;
      final sb = (b['serial'] as String? ?? '000000-000').split('-').last;
      final na = int.tryParse(sa) ?? 0;
      final nb = int.tryParse(sb) ?? 0;
      return _sortNewestFirst ? nb.compareTo(na) : na.compareTo(nb);
    });

    if (rawList.isEmpty) {
      return Center(
        child: Text(
          'No tokens issued today',
          style: TextStyle(
              fontSize: 14,
              color: _isDark ? const Color(0xFF94A3B8) : Colors.grey),
        ),
      );
    }

    return ListView.separated(
      itemCount: rawList.length,
      separatorBuilder: (_, _) => Divider(
          height: 1,
          color: _isDark ? const Color(0xFF334155) : Colors.grey.shade200),
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
        var cnic = (e['patientCnic'] ?? e['cnic'] ?? '').toString().trim();
        var guardianCnic = (e['guardianCnic'] ?? '').toString().trim();
        final pId = (e['patientId'] ?? e['id'] ?? '').toString().trim();

        if (name.isEmpty) {
          final presc = e['prescription'] is Map
              ? e['prescription'] as Map
              : lss.LocalStorageService.getLocalPrescription(
                  serial,
                  branchId: widget.branchId,
                  cnic: cnic.isNotEmpty ? cnic : guardianCnic,
                  patientId: pId,
                  patientName: rawName,
                );
          final pName = (presc?['patientName'] ?? presc?['name'] ?? presc?['fullName'])?.toString().trim();
          if (pName != null &&
              pName.isNotEmpty &&
              pName.toLowerCase() != 'null' &&
              pName.toLowerCase() != 'unknown' &&
              pName.toLowerCase() != 'unknown patient') {
            name = pName;
            e['patientName'] = name;
          }
        }

        if (name.isEmpty || cnic.isEmpty) {
          if (pId.isNotEmpty) {
            final lp = lss.LocalStorageService.getLocalPatient(pId);
            if (lp != null) {
              final lpName = (lp['name'] ?? lp['patientName'] ?? lp['fullName'])?.toString().trim();
              if (name.isEmpty &&
                  lpName != null &&
                  lpName.isNotEmpty &&
                  lpName.toLowerCase() != 'null' &&
                  lpName.toLowerCase() != 'unknown' &&
                  lpName.toLowerCase() != 'unknown patient') {
                name = lpName;
                e['patientName'] = name;
              }
              final lpCnic = (lp['cnic'] ?? lp['guardianCnic'])?.toString().trim() ?? '';
              if (cnic.isEmpty && lpCnic.isNotEmpty) {
                cnic = lpCnic;
                e['cnic'] = cnic;
              }
            }
          }
          final isChildEntry = e['isAdult'] == false || pId.contains('_child_') || guardianCnic.isNotEmpty;
          if (name.isEmpty && cnic.isNotEmpty && !isChildEntry) {
            final lp = lss.LocalStorageService.getLocalPatientByCnic(cnic);
            if (lp != null) {
              final lpName = (lp['name'] ?? lp['patientName'] ?? lp['fullName'])?.toString().trim();
              if (lpName != null &&
                  lpName.isNotEmpty &&
                  lpName.toLowerCase() != 'null' &&
                  lpName.toLowerCase() != 'unknown' &&
                  lpName.toLowerCase() != 'unknown patient') {
                name = lpName;
                e['patientName'] = name;
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
            badgeColor = Colors.green.shade600;
            displayType = 'PKR 20';
          } else if (effectiveQueueType == 'gmwf') {
            badgeColor = Colors.orange.shade600;
            displayType = 'GMWF';
          } else {
            badgeColor = Colors.green.shade600;
            displayType = 'PKR 20';
          }
        } else {
          switch (queueTypeRaw) {
            case 'zakat':
              badgeColor = Colors.green.shade600;
              displayType = 'Zakat';
              break;
            case 'non-zakat':
              badgeColor = Colors.blue.shade600;
              displayType = 'Non-Zakat';
              break;
            case 'gmwf':
              badgeColor = Colors.orange.shade600;
              displayType = 'GMWF';
              break;
            default:
              badgeColor = Colors.grey.shade600;
              displayType = 'Zakat';
          }
        }

        // Status determination
        final s = (e['status'] as String?)?.toLowerCase().trim() ?? 'waiting';
        final hasPrescription = (e['prescriptionId'] as String?)?.isNotEmpty == true || e['prescription'] is Map;
        final isDispensed = s == 'dispensed' || e['dispensedAt'] != null || (e['dispenseStatus'] as String?)?.toLowerCase().trim() == 'dispensed';
        final isWaitingToDispense = !isDispensed && (hasPrescription || s == 'completed' || s == 'prescribed' || s == 'waiting_to_dispense' || s == 'waiting_for_dispense');

        // Only tokens strictly waiting for doctor (not yet prescribed or dispensed) can be reversed/undone!
        final isWaitingOnly = !isDispensed && !isWaitingToDispense && s != 'with_doctor' && s != 'with doctor' && s != 'in_consultation' && s != 'cancelled' && s != 'reversed' && s != 'deleted';
        final canReverse = isWaitingOnly;

        String statusLabel;
        Color statusBg;
        Color statusText;
        IconData statusIcon;

        if (isDispensed) {
          statusLabel = 'Dispensed';
          statusBg = _isDark ? const Color(0xFF14532D) : Colors.green.shade50;
          statusText = _isDark ? const Color(0xFF86EFAC) : Colors.green.shade800;
          statusIcon = Icons.check_circle_outline_rounded;
        } else if (isWaitingToDispense) {
          statusLabel = 'Waiting for Dispense';
          statusBg = _isDark ? const Color(0xFF1E3A5F) : Colors.blue.shade50;
          statusText = _isDark ? const Color(0xFF93C5FD) : Colors.blue.shade800;
          statusIcon = Icons.medication_outlined;
        } else if (s == 'with_doctor' || s == 'with doctor' || s == 'in_consultation') {
          statusLabel = 'With Doctor';
          statusBg = _isDark ? const Color(0xFF3B1D5F) : Colors.purple.shade50;
          statusText = _isDark ? const Color(0xFFD8B4FE) : Colors.purple.shade800;
          statusIcon = Icons.medical_services_outlined;
        } else if (s == 'cancelled' || s == 'reversed') {
          statusLabel = 'Cancelled';
          statusBg = _isDark ? const Color(0xFF450A0A) : Colors.red.shade50;
          statusText = _isDark ? const Color(0xFFFCA5A5) : Colors.red.shade800;
          statusIcon = Icons.cancel_outlined;
        } else {
          statusLabel = 'Waiting';
          statusBg = _isDark ? const Color(0xFF451A03) : Colors.amber.shade50;
          statusText = _isDark ? const Color(0xFFFCD34D) : Colors.amber.shade900;
          statusIcon = Icons.hourglass_empty_rounded;
        }

        final displayCnic = cnic.isNotEmpty
            ? cnic
            : guardianCnic.isNotEmpty
                ? guardianCnic
                : '-';

        final seqNumber = serial.split('-').last.padLeft(3, '0');

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

        return Container(
          margin: const EdgeInsets.symmetric(vertical: 2.5),
          padding: EdgeInsets.symmetric(
              horizontal: isMobile ? 8 : 12, vertical: 6),
          decoration: BoxDecoration(
            color: _isDark
                ? const Color(0xFF1E293B)
                : Colors.white,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(
                color: _isDark
                    ? const Color(0xFF334155)
                    : Colors.grey.shade200),
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
                    color: Colors.white,
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
                                  ? Colors.white
                                  : Colors.black87,
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
                              color: Colors.deepOrange,
                              borderRadius:
                                  BorderRadius.circular(6),
                            ),
                            child: Text(
                              '×$days d',
                              style: const TextStyle(
                                  color: Colors.white,
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
                                    ScaffoldMessenger.of(context).clearSnackBars();
                                    ScaffoldMessenger.of(context).showSnackBar(
                                      SnackBar(
                                        content: Row(
                                          mainAxisSize: MainAxisSize.min,
                                          children: [
                                            const Icon(Icons.check_circle,
                                                color: Colors.white, size: 16),
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
                                          ? const Color(0xFF38BDF8)
                                          : const Color(0xFF00796B),
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
                                          ? const Color(0xFF38BDF8)
                                          : const Color(0xFF00796B),
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
                                color: Colors.grey.shade400)),
                        Text(
                          DateFormat('hh:mm a').format(timestamp),
                          style: TextStyle(
                            fontSize: 11,
                            color: _isDark
                                ? const Color(0xFF94A3B8)
                                : Colors.grey.shade600,
                          ),
                        ),
                        if ((e['session'] as String?)?.isNotEmpty == true) ...[
                          Text('•',
                              style: TextStyle(
                                  fontSize: 9,
                                  color: Colors.grey.shade400)),
                          Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 3, vertical: 1),
                            child: Text(
                              e['session'].toString(),
                              style: TextStyle(
                                fontSize: 10,
                                fontWeight: FontWeight.w600,
                                color: e['session'].toString().toLowerCase().contains('morn')
                                    ? Colors.amber.shade700
                                    : Colors.indigo.shade400,
                              ),
                            ),
                          ),
                        ],
                        if (_selectedCampFilter == 'all' && _hasMultiCamps && campTag.isNotEmpty) ...[
                          Text('•',
                              style: TextStyle(
                                  fontSize: 9,
                                  color: Colors.grey.shade400)),
                          Text(
                            campTag,
                            style: TextStyle(
                              fontSize: 10,
                              fontWeight: FontWeight.w600,
                              color: Colors.teal.shade600,
                            ),
                          ),
                        ],
                        if (hasExtraDays) ...[
                          Text('•',
                              style: TextStyle(
                                  fontSize: 9,
                                  color: Colors.grey.shade400)),
                          Text(
                            'PKR $tokenAmount',
                            style: TextStyle(
                              fontSize: 10,
                              fontWeight: FontWeight.bold,
                              color: Colors.orange.shade800,
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
                      color: Colors.redAccent, size: 16),
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
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final screenWidth = MediaQuery.of(context).size.width;
    final isMobile = screenWidth < 800;

    if (!Hive.isBoxOpen('app_settings')) {
      return FutureBuilder<Box>(
        future: lss.LocalStorageService.ensureBoxOpen('app_settings'),
        builder: (context, snapshot) {
          if (!snapshot.hasData || snapshot.data == null || !snapshot.data!.isOpen) {
            return const Scaffold(
              body: Center(child: CircularProgressIndicator(color: Color(0xFF00875A))),
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
        color: isDark ? const Color(0xFF0F172A) : const Color(0xFFF1F8F5),
      ),
      child: Column(
        children: [
          ClockSkewWarningBanner(branchId: widget.branchId),
          Expanded(
            child: isMobile ? _buildMobileBody() : _buildDesktopBody(),
          ),
        ],
      ),
    );

    if (widget.isEmbedded) return body;

    return Scaffold(
      backgroundColor: isDark ? const Color(0xFF0F172A) : const Color(0xFFF1F8F5),
      appBar: _buildAppBar(isMobile),
      body: body,
    );
  }

  Widget _buildWithEntriesListenable(Widget Function(BuildContext, Box?, Widget?) builder) {
    if (Hive.isBoxOpen(lss.LocalStorageService.entriesBox)) {
      final box = Hive.box(lss.LocalStorageService.entriesBox);
      if (box.isOpen) {
        return ValueListenableBuilder<Box>(
          valueListenable: box.listenable(),
          builder: (ctx, b, w) {
            try {
              if (b == null || !b.isOpen) {
                return const Center(
                  child: Padding(
                    padding: EdgeInsets.all(24),
                    child: CircularProgressIndicator(color: Color(0xFF00875A)),
                  ),
                );
              }
              return builder(ctx, b, w);
            } catch (e) {
              return const Center(
                child: Padding(
                  padding: EdgeInsets.all(24),
                  child: CircularProgressIndicator(color: Color(0xFF00875A)),
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
            valueListenable: snapshot.data!.listenable(),
            builder: (ctx, b, w) {
              try {
                if (b == null || !b.isOpen) {
                  return const Center(
                    child: Padding(
                      padding: EdgeInsets.all(24),
                      child: CircularProgressIndicator(color: Color(0xFF00875A)),
                    ),
                  );
                }
                return builder(ctx, b, w);
              } catch (e) {
                return const Center(
                  child: Padding(
                    padding: EdgeInsets.all(24),
                    child: CircularProgressIndicator(color: Color(0xFF00875A)),
                  ),
                );
              }
            },
          );
        }
        return const Center(
          child: Padding(
            padding: EdgeInsets.all(24),
            child: CircularProgressIndicator(color: Color(0xFF00875A)),
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
                ]),
                const SizedBox(height: 4),
                Row(
                  children: [
                    Text(
                      '${_getFilteredTodayTokens().length} total',
                      style: TextStyle(
                        fontSize: 12,
                        color: _isDark ? const Color(0xFF94A3B8) : Colors.grey.shade700,
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
                        color: _isDark ? const Color(0xFF1E293B) : Colors.white,
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(28)),
                        clipBehavior: Clip.antiAlias,
                        child: Stack(
                          children: [
                            // ── Authentic Islamic Pattern Background (Vibrant Golden) ──
                            Positioned.fill(
                              child: IgnorePointer(
                                child: Opacity(
                                  opacity: _isDark ? 0.18 : 0.28,
                                  child: Image.asset(
                                    'assets/images/islamic_pattern.webp',
                                    fit: BoxFit.cover,
                                    color: _isDark ? const Color(0xFFF6C358) : const Color(0xFFD4AF37),
                                    colorBlendMode: BlendMode.srcIn,
                                  ),
                                ),
                              ),
                            ),

                            // ── Form Content ──
                            Padding(
                              padding: const EdgeInsets.all(28),
                              child: AnimatedSwitcher(
                                duration: const Duration(milliseconds: 400),
                                child: _activeSection == 'register'
                                    ? PatientRegisterPage(
                                        key: _registerKey,
                                        branchId: widget.branchId,
                                        receptionistId: widget.receptionistId,
                                        initialCnic: _pendingCnic,
                                        onPatientRegistered:
                                            _onPatientRegistered,
                                      )
                                    : TokenScreen(
                                        key: _tokenKey,
                                        branchId: widget.branchId,
                                        receptionistId: widget.receptionistId,
                                        receptionistName:
                                            widget.receptionistName,
                                        initialCnic: _pendingCnic,
                                        onPatientNotFound:
                                            _handlePatientNotFound,
                                      ),
                              ),
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
                    (context, _, _) => Column(
                      children: [
                        _buildSummaryCards(false),
                        const SizedBox(height: 16),
                        Expanded(
                          child: Builder(
                            builder: (context) {
                              final todayCount = _getFilteredTodayTokens().length;
                              return Card(
                                elevation: 8,
                                color: _isDark ? const Color(0xFF1E293B) : Colors.white,
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
                                            child: Image.asset(
                                              'assets/images/1.webp',
                                              fit: BoxFit.contain,
                                              color: _isDark ? const Color(0xFFF6C358) : const Color(0xFFD4AF37),
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
                                                color: _isDark ? const Color(0xFF38BDF8) : _teal, size: 26),
                                            const SizedBox(width: 10),
                                            Text("Today's Tokens",
                                                style: TextStyle(
                                                    fontSize: 19,
                                                    fontWeight:
                                                        FontWeight.bold,
                                                    color: _isDark ? Colors.white : _teal)),
                                            const Spacer(),
                                            IconButton(
                                              icon: Icon(
                                                  _sortNewestFirst
                                                      ? Icons
                                                          .arrow_downward_rounded
                                                      : Icons
                                                          .arrow_upward_rounded,
                                                  color: _isDark ? const Color(0xFF38BDF8) : _teal,
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
                                                  color: _isDark ? const Color(0xFF38BDF8) : _teal, size: 22),
                                              onPressed: _refreshTokenLog,
                                              tooltip: 'Refresh token list',
                                            ),
                                          ]),
                                          const SizedBox(height: 10),
                                          _buildShiftSelector(false),
                                          const SizedBox(height: 6),
                                          Row(
                                            children: [
                                              Text('$todayCount total',
                                                  style: TextStyle(
                                                      color: _isDark ? const Color(0xFF94A3B8) : Colors.grey.shade700,
                                                      fontSize: 13,
                                                      fontWeight: FontWeight.w600)),
                                            ],
                                          ),
                                          const Divider(height: 20),
                                          Expanded(child: _buildTokenLog(false)),
                                        ],
                                      ),
                                    ),
                                  ],
                                ),
                              );
                            },
                          ),
                        ),
                      ],
                    ),
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
            color: _isDark ? const Color(0xFF1E293B) : Colors.white,
            borderRadius: BorderRadius.circular(24),
            border: Border.all(
              color: _isDark ? const Color(0xFF334155) : const Color(0xFFE2E8F0),
              width: 1.2,
            ),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: _isDark ? 0.20 : 0.04),
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
                onTap: () => _mobileTabController.animateTo(0),
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
                      colors: [Color(0xFF00A86B), Color(0xFF00875A)],
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                    )
                  : null,
              borderRadius: BorderRadius.circular(20),
              boxShadow: isSelected
                  ? [
                      BoxShadow(
                        color: const Color(0xFF00A86B).withValues(alpha: _isDark ? 0.4 : 0.25),
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
                      ? Colors.white
                      : (_isDark ? const Color(0xFF94A3B8) : const Color(0xFF64748B)),
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
                          ? Colors.white
                          : (_isDark ? const Color(0xFF94A3B8) : const Color(0xFF64748B)),
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
        color: _isDark ? const Color(0xFF1E293B) : Colors.white,
        borderRadius: BorderRadius.circular(32),
        border: Border.all(
          color: _isDark ? const Color(0xFF334155) : const Color(0xFFE2E8F0),
          width: 1.5,
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: _isDark ? 0.20 : 0.04),
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
                            colors: [Color(0xFF00A86B), Color(0xFF00875A)],
                            begin: Alignment.topLeft,
                            end: Alignment.bottomRight,
                          )
                        : null,
                    borderRadius: BorderRadius.circular(28),
                    boxShadow: !isToken
                        ? [
                            BoxShadow(
                              color: const Color(0xFF00A86B).withValues(alpha: _isDark ? 0.45 : 0.35),
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
                            ? Colors.white
                            : (_isDark ? const Color(0xFF94A3B8) : const Color(0xFF64748B)),
                      ),
                      const SizedBox(width: 8),
                      Text(
                        'Register Patient',
                        style: TextStyle(
                          fontWeight: !isToken ? FontWeight.bold : FontWeight.w600,
                          fontSize: 14.5,
                          color: !isToken
                              ? Colors.white
                              : (_isDark ? const Color(0xFF94A3B8) : const Color(0xFF64748B)),
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
                onTap: () => setState(() => _activeSection = 'token'),
                borderRadius: BorderRadius.circular(28),
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 250),
                  curve: Curves.easeInOut,
                  alignment: Alignment.center,
                  padding: const EdgeInsets.symmetric(vertical: 10),
                  decoration: BoxDecoration(
                    gradient: isToken
                        ? const LinearGradient(
                            colors: [Color(0xFF00A86B), Color(0xFF00875A)],
                            begin: Alignment.topLeft,
                            end: Alignment.bottomRight,
                          )
                        : null,
                    borderRadius: BorderRadius.circular(28),
                    boxShadow: isToken
                        ? [
                            BoxShadow(
                              color: const Color(0xFF00A86B).withValues(alpha: _isDark ? 0.45 : 0.35),
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
                            ? Colors.white
                            : (_isDark ? const Color(0xFF94A3B8) : const Color(0xFF64748B)),
                      ),
                      const SizedBox(width: 8),
                      Text(
                        'Issue Token',
                        style: TextStyle(
                          fontWeight: isToken ? FontWeight.bold : FontWeight.w600,
                          fontSize: 14.5,
                          color: isToken
                              ? Colors.white
                              : (_isDark ? const Color(0xFF94A3B8) : const Color(0xFF64748B)),
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
    CampSessionService.activeCampNotifier.removeListener(_onActiveCampChanged);
    _refreshNotifier.dispose();
    _mobileTabController.dispose();
    if (!widget.isEmbedded) {
      ConnectionManager().stop();
    }
    _connectionSub?.cancel();
    _connSub?.cancel();
    _realtimeSub?.cancel();
    super.dispose();
  }
}