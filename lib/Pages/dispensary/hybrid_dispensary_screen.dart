// lib/pages/dispensary/hybrid_dispensary_screen.dart

import 'dart:async';
import '../../widgets/lazy_indexed_stack.dart';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:gmwf/design/components/flushbar_compat.dart';

import 'package:gmwf/services/local_storage_service.dart';
import 'package:gmwf/services/sync_service.dart';
import 'package:gmwf/services/auth_service.dart';
import 'package:gmwf/realtime/connection_manager.dart';
import 'package:gmwf/realtime/realtime_manager.dart';
import 'package:gmwf/realtime/realtime_events.dart';
import 'package:gmwf/widgets/gmwf_app_bar.dart';
import 'package:gmwf/services/camp_session_service.dart';
import 'package:gmwf/widgets/camp_selector_chip.dart';
import 'user_settings_dialog.dart';
import 'widgets/connection_status_same.dart';
import 'widgets/desk_theme.dart';

import 'package:gmwf/models/patient.dart';
import 'package:gmwf/services/firestore_service.dart';
import 'package:gmwf/design/design_system.dart';

import 'receptionist/receptionist_screen.dart';
import 'dispensar/dispensar_screen.dart';
import 'dispensar/inventory.dart';
import 'hybrid_all_in_one_screen.dart';
import '../../services/dispensary_preferences_service.dart';
import 'doctor/doctor_screen.dart';
import 'package:gmwf/constants/navigator_key.dart';
import 'package:gmwf/utils/formatters.dart';

class HybridDispensaryScreen extends StatefulWidget {
  final String branchId;
  final String userId;
  final String userName;
  final String role; // 'rec+dis', 'doc+rec', 'doc+dis', 'doc+rec+dis'

  const HybridDispensaryScreen({
    super.key,
    required this.branchId,
    required this.userId,
    required this.userName,
    required this.role,
  });

  @override
  State<HybridDispensaryScreen> createState() => _HybridDispensaryScreenState();
}

class _HybridDispensaryScreenState extends State<HybridDispensaryScreen>
    with TickerProviderStateMixin {
  late TabController _tabController;
  bool _controllerInitialized = false;
  int _activeTabIndex = 0;
  bool _isLoggingOut = false;
  ValueListenable<Box>? _hybridBoxListenable;
  VoidCallback? _hybridBoxListener;
  final List<Map<String, dynamic>> _tabs = [];

  StreamSubscription<List<ConnectivityResult>>? _connSub;
  StreamSubscription<ConnectionStatus>? _connectionSub;

  bool _online = true;
  bool _isSyncing = false;
  String? _branchName;
  String? _resolvedName;

  ConnectionStatus _connectionStatus = ConnectionManager().status;

  Color get _teal => context.comfort.brand;

  StreamSubscription? _restockRealtimeSub;
  StreamSubscription? _restockFirestoreSub;
  List<Map<String, dynamic>> _pendingRestockAlerts = [];

  // Dispenser tab badge: today's prescribed patients not yet dispensed.
  int _readyToDispenseCount = 0;

  // Theme-toggle refresh of the kept-alive tab screens (see _rebuildTabsForTheme).
  final GlobalKey _tabBodyKey = GlobalKey();
  bool? _lastIsDark;
  String? _lastThemeChoice;
  StreamSubscription? _readyCountSub;
  Timer? _readyCountDebounce;

  /// The tab that dispenses: "Dispenser", or "Pharmacy" in the all-in-one layout.
  static bool _isDispenseTab(String title) {
    final t = title.toLowerCase();
    return t.contains('dispens') || t.contains('pharmacy');
  }

  void _startReadyToDispenseCounter() {
    final hasDispenserTab = _tabs.any((t) => _isDispenseTab(t['title'] as String));
    if (!hasDispenserTab) return;
    CampSessionService.activeCampNotifier.addListener(_scheduleReadyCount);
    // The entries box is opened asynchronously on desk entry — wait for it instead of giving up.
    LocalStorageService.ensureBoxOpen(LocalStorageService.entriesBox).then((box) {
      if (!mounted) return;
      _recomputeReadyToDispense();
      _readyCountSub?.cancel();
      // Debounced: a catch-up writes many entries in a burst; count once after it settles.
      _readyCountSub = box.watch().listen((_) => _scheduleReadyCount());
    }).catchError((e) {
      debugPrint('[HybridScreen] Ready-to-dispense counter could not start: $e');
    });
  }

  void _scheduleReadyCount() {
    _readyCountDebounce?.cancel();
    _readyCountDebounce = Timer(const Duration(milliseconds: 800), _recomputeReadyToDispense);
  }

  void _recomputeReadyToDispense() {
    if (_isLoggingOut || !mounted || !Hive.isBoxOpen(LocalStorageService.entriesBox)) return;
    final today = CampSessionService.resolveShiftAndDateKey(null, widget.branchId).dateKey;
    final camp = CampSessionService.getActiveCamp(widget.branchId);
    final byCamp = camp != null && camp.isNotEmpty && camp != 'all';
    final seen = <String>{};
    var count = 0;
    for (final e in LocalStorageService.getLocalEntries(widget.branchId, dispensaryId: camp, filterByCamp: byCamp)) {
      final serial = (e['serial'] ?? e['id'] ?? '').toString().trim().toUpperCase();
      if (serial.isEmpty || !seen.add(serial)) continue;
      final dk = (e['dateKey'] ?? '').toString().trim();
      if (dk != today && CampSessionService.getDateKeyFromSerial(serial) != today) continue;
      // Same rule as the Receptionist list's "Waiting for Dispense" label.
      final s = (e['status'] ?? 'waiting').toString().toLowerCase().trim();
      if (s == 'cancelled' || s == 'rejected' || s == 'reversed' || s == 'deleted' || s == 'skipped') continue;
      final isDispensed = s == 'dispensed' || e['dispensedAt'] != null ||
          (e['dispenseStatus'] ?? '').toString().toLowerCase().trim() == 'dispensed';
      if (isDispensed) continue;
      final hasPrescription = (e['prescriptionId']?.toString().isNotEmpty ?? false) || e['prescription'] is Map;
      if (hasPrescription || s == 'completed' || s == 'prescribed' ||
          s == 'waiting_to_dispense' || s == 'waiting_for_dispense') {
        count++;
      }
    }
    if (count != _readyToDispenseCount && mounted && !_isLoggingOut) {
      setState(() => _readyToDispenseCount = count);
    }
  }

  bool get _shouldShowRestockAlert {
    final r = widget.role.toLowerCase().trim();
    final hasDispenser = r.contains('dis') || r.contains('dispenser') || r.contains('dispensar');
    final hasDoctor = r.contains('doc') || r.contains('doctor');
    return hasDispenser && !hasDoctor;
  }

  static String? _lastActiveTabTitle;
  static int? _lastActiveTabIndex;

  void _saveCurrentActiveTab(int idx) {
    if (idx >= 0 && idx < _tabs.length) {
      _lastActiveTabIndex = idx;
      final title = _tabs[idx]['title'] as String?;
      if (title != null && title.isNotEmpty) {
        _lastActiveTabTitle = title;
        try {
          if (Hive.isBoxOpen('app_settings')) {
            Hive.box('app_settings').put('last_hybrid_tab_title', title);
          }
        } catch (_) {}
      }
    }
  }

  int _resolveInitialTabIndex() {
    if (_tabs.isEmpty) return 0;
    // 1. Try in-memory static last active title (prevents numeric index mismatch
    //    when toggling between separate tabs and single-screen Pharmacy mode).
    if (_lastActiveTabTitle != null) {
      final idx = _tabs.indexWhere((t) => t['title'] == _lastActiveTabTitle);
      if (idx >= 0) return idx;
    }
    // 2. Try Hive app_settings
    String? savedTitle;
    try {
      if (Hive.isBoxOpen('app_settings')) {
        savedTitle = Hive.box('app_settings').get('last_hybrid_tab_title')?.toString();
        if (savedTitle != null && savedTitle.isNotEmpty) {
          final idx = _tabs.indexWhere((t) => t['title'] == savedTitle);
          if (idx >= 0) return idx;
        }
      }
    } catch (_) {}
    // 3. Fallback: Receptionist is the default in separate-tabs mode;
    //    Pharmacy is the default in single-screen mode.
    final recIdx = _tabs.indexWhere((t) => (t['title'] as String) == 'Receptionist');
    if (recIdx >= 0) return recIdx;
    final pharmacyIdx = _tabs.indexWhere((t) => (t['title'] as String) == 'Pharmacy');
    if (pharmacyIdx >= 0) return pharmacyIdx;
    final disIdx = _tabs.indexWhere((t) => _isDispenseTab(t['title'] as String));
    if (disIdx >= 0) return disIdx;
    // 4. Only use numeric index if no title preference existed
    if (_lastActiveTabTitle == null && (savedTitle == null || savedTitle.isEmpty)) {
      if (_lastActiveTabIndex != null && _lastActiveTabIndex! >= 0 && _lastActiveTabIndex! < _tabs.length) {
        return _lastActiveTabIndex!;
      }
    }
    return 0;
  }

  void _onTabControllerChanged() {
    if (_tabController.index < _tabs.length) {
      _saveCurrentActiveTab(_tabController.index);
    }
    if (_activeTabIndex != _tabController.index && !_tabController.indexIsChanging) {
      if (mounted && !_isLoggingOut) {
        setState(() {
          _activeTabIndex = _tabController.index;
        });
      }
    }
  }

  @override
  void initState() {
    super.initState();
    debugPrint("[Lifecycle] HybridDispensaryScreen initState");

    _parseRole();
    _syncTabController();

    if (_shouldShowRestockAlert) {
      _listenRestockRequests();
    }
    _startReadyToDispenseCounter();

    // Start services once
    SyncService().start(widget.branchId, moduleScope: 'dispensary'); // like the other desks: no full-PC sweep
    _listenConnectivity();
    _loadBranchName();

    _fetchUserNameAndConnect();

    _connectionStatus = ConnectionManager().status;
    _connectionSub = ConnectionManager().statusStream.listen((status) {
      // Only rebuild when the status really changed (the stream re-emits the same state).
      if (mounted && !status.sameAs(_connectionStatus)) setState(() => _connectionStatus = status);
    });

    // Ensure all role boxes (patients, entries, stock, prescriptions) are opened on desk entry
    LocalStorageService.initForRoles([widget.role, 'receptionist', 'dispenser']);

    // Ensure active camp is resolved — getActiveCamp() now handles time-based detection automatically
    if (CampSessionService.hasCampsForBranch(widget.branchId)) {
      CampSessionService.getActiveCamp(widget.branchId);
      CampSessionService.startAutoCampTimer();
    }

    CampSessionService.activeCampNotifier.addListener(_onCampChanged);

    // Run receptionist bootstrap if "rec" is included in role
    if (widget.role.toLowerCase().contains('rec')) {
      _bootstrapReceptionistData(widget.branchId);
    }

    if (Hive.isBoxOpen('app_settings')) {
      final hybridKey = DispensaryPreferencesService.getHybridAllInOneKey(widget.userId);
      _hybridBoxListenable = Hive.box('app_settings').listenable(keys: [hybridKey]);
      _hybridBoxListener = () {
        if (mounted && !_isLoggingOut) {
          setState(() {
            _parseRole();
          });
        }
      };
      _hybridBoxListenable?.addListener(_hybridBoxListener!);
    }
  }

  void _onCampChanged() {
    if (mounted && !_isLoggingOut) setState(() {});
  }

  void _parseRole([String? effectiveName]) {
    final name = effectiveName ?? _resolvedName ?? widget.userName;
    _tabs.clear();
    final r = widget.role.toLowerCase().trim();
    final hasReception = r.contains('rec') || r.contains('receptionist');
    final hasDispense = r.contains('dis') || r.contains('dispenser') || r.contains('dispensar');
    // Reception + dispense desks can switch between the all-in-one Pharmacy layout
    // and the separate Receptionist / Dispenser tabs via the 3-dot menu.
    // Default is always false (the normal separate tabs), per-account isolated.
    final bool allInOneEnabled = DispensaryPreferencesService.isHybridAllInOne(widget.userId);
    final useAllInOne = hasReception && hasDispense && allInOneEnabled;
    if (r.contains('doc') || r.contains('doctor')) {
      _tabs.add({
        'title': 'Doctor',
        'icon': Icons.medical_services_outlined,
        'widget': DoctorScreen(
          branchId: widget.branchId,
          doctorId: widget.userId,
          doctorName: name,
          isEmbedded: true,
        ),
      });
    }
    if (useAllInOne) {
      _tabs.add({
        'title': 'Pharmacy',
        'icon': Icons.local_pharmacy_outlined,
        'widget': HybridAllInOneScreen(
          branchId: widget.branchId,
          userId: widget.userId,
          userName: name,
        ),
      });
    }
    if (!useAllInOne && hasReception) {
      // Doctor desks write the prescriptions; dispenser desks get the Dispenser tab badge.
      // Either way a popup per prescription on the Receptionist tab is noise.
      final suppressPrescriptionNotifications = r.contains('doc') || r.contains('doctor') ||
          r.contains('dis') || r.contains('dispenser') || r.contains('dispensar');
      _tabs.add({
        'title': 'Receptionist',
        'icon': Icons.support_agent_rounded,
        'widget': ReceptionistScreen(
          branchId: widget.branchId,
          receptionistId: widget.userId,
          receptionistName: name,
          isEmbedded: true,
          suppressPrescriptionNotifications: suppressPrescriptionNotifications,
        ),
      });
    }
    if (!useAllInOne && hasDispense) {
      _tabs.add({
        'title': 'Dispenser',
        'icon': Icons.medication_outlined,
        'widget': DispensarScreen(
          branchId: widget.branchId,
          dispenserId: widget.userId,
          dispenserName: name,
          isEmbedded: true,
          showEmbeddedToolbar: false,
        ),
      });
    }
    if (_tabs.isEmpty) {
      _tabs.add({
        'title': 'Desk',
        'icon': Icons.support_agent_rounded,
        'widget': ReceptionistScreen(
          branchId: widget.branchId,
          receptionistId: widget.userId,
          receptionistName: name,
          isEmbedded: true,
        ),
      });
    }

    _syncTabController();
  }

  void _syncTabController() {
    if (_isLoggingOut || _tabs.isEmpty) return;
    final targetLength = _tabs.length;
    final bool needsNew = !_controllerInitialized || _tabController.length != targetLength;
    if (needsNew) {
      final old = _controllerInitialized ? _tabController : null;
      if (old != null) {
        old.removeListener(_onTabControllerChanged);
      }
      final targetIndex = _resolveInitialTabIndex().clamp(0, targetLength - 1);

      _tabController = TabController(
        length: targetLength,
        initialIndex: targetIndex,
        vsync: this,
      );
      _controllerInitialized = true;
      _activeTabIndex = _tabController.index;
      if (old != null) {
        _saveCurrentActiveTab(_tabController.index);
      }
      _tabController.addListener(_onTabControllerChanged);

      if (old != null) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          try {
            old.dispose();
          } catch (_) {}
        });
      }
    }
  }

  void _listenConnectivity() {
    _connSub = Connectivity().onConnectivityChanged.listen((results) {
      final isOnline = results.any((r) => r != ConnectivityResult.none);
      if (_online != isOnline && mounted) {
        setState(() => _online = isOnline);
        if (isOnline) {
          _forceSync();
        }
      }
    });
  }

  Future<void> _fetchUserNameAndConnect() async {
    String? name;

    // 1. Try local cache
    try {
      final local = LocalStorageService.getLocalUserByUid(widget.userId);
      if (local != null) {
        final n = resolveUserDisplayName(local);
        if (n.isNotEmpty && n != 'User' && n != 'Doctor') name = n;
      }
    } catch (_) {}

    // 2. Check app_settings cache
    if (name == null || name == 'User' || name == 'Doctor') {
      try {
        if (Hive.isBoxOpen('app_settings')) {
          final box = Hive.box('app_settings');
          final uData = box.get('user_data') ?? box.get('currentUser');
          if (uData is Map) {
            final n = resolveUserDisplayName(Map<String, dynamic>.from(uData));
            if (n.isNotEmpty && n != 'User' && n != 'Doctor') name = n;
          }
        }
      } catch (_) {}
    }

    // 3. Fall back to widget param
    if (name == null || name == 'User' || name == 'Doctor') {
      if (widget.userName.trim().isNotEmpty && widget.userName.trim().toLowerCase() != 'user') {
        name = widget.userName.trim();
      }
    }

    if (mounted && name != null && name.isNotEmpty) {
      setState(() {
        _resolvedName = name;
        _parseRole(name);
      });
    }

    // Start connection
    ConnectionManager().start(
      role: widget.role,
      branchId: widget.branchId,
      username: name,
    );
    if (name != null) {
      RealtimeManager().updateUsername(name);
    }

    // 4. Fetch from Firestore for authoritative user profile and cache it
    try {
      final userData = await AuthService().getUserByUid(widget.userId);
      if (userData != null && Hive.isBoxOpen('app_settings')) {
        await Hive.box('app_settings').put('user_data', userData);
        await Hive.box('app_settings').put('currentUser', userData);
      }
      final firestoreName = resolveUserDisplayName(userData);
      if (mounted && firestoreName.isNotEmpty && firestoreName != 'User' && firestoreName != 'Doctor') {
        setState(() {
          _resolvedName = firestoreName;
          _parseRole(firestoreName);
        });
        RealtimeManager().updateUsername(firestoreName);
      }
    } catch (e) {
      debugPrint('[HybridScreen] Could not fetch name from Firestore: $e');
    }
  }

  Future<void> _loadBranchName() async {
    if (widget.branchId.isEmpty) {
      if (mounted) setState(() => _branchName = 'Free Dispensary');
      return;
    }
    final localName = LocalStorageService.getBranchName(widget.branchId);
    if (localName.isNotEmpty && localName != 'Free Dispensary') {
      if (mounted) setState(() => _branchName = localName);
    }
    try {
      final doc = await FirebaseFirestore.instance
          .collection('branches')
          .doc(widget.branchId)
          .get();
      if (mounted && doc.exists) {
        final n = doc.data()?['name']?.toString();
        if (n != null && n.isNotEmpty) {
          setState(() => _branchName = n);
        }
      }
    } catch (_) {}
  }

  Future<void> _forceSync() async {
    if (_isSyncing || !mounted) return;
    setState(() => _isSyncing = true);
    try {
      // 1. Force-flush LAN WebSocket outbox & request catch-up from LAN server
      await RealtimeManager().forceFlushAndCatchUp();

      // 2. If online, sync with cloud
      if (_online) {
        await SyncService().syncTodayOnly(widget.branchId);
        await SyncService().triggerUpload();
      }
      if (mounted) {
        Flushbar(
          message: _online ? 'Full sync completed (LAN & Cloud)' : 'LAN Sync completed (Outbox flushed)',
          backgroundColor: SoftPalette.green500,
          duration: const Duration(seconds: 2),
        ).show(context);
      }
    } catch (e) {
      if (mounted) {
        Flushbar(
          message: 'Sync failed: $e',
          backgroundColor: SoftPalette.red500,
          duration: const Duration(seconds: 3),
        ).show(context);
      }
    } finally {
      if (mounted) setState(() => _isSyncing = false);
    }
  }

  Future<void> _bootstrapReceptionistData(String branchId) async {
    final isOnline = _online;
    if (!isOnline) return;

    final firestoreService = FirestoreService();
    try {
      await LocalStorageService.ensureBoxOpen(LocalStorageService.patientsBox);
      await LocalStorageService.ensureBoxOpen(LocalStorageService.entriesBox);
      // Only do a bulk patient download if local storage is fresh/empty (< 5 patients)
      final localCount = LocalStorageService.getAllLocalPatients(branchId: branchId).length;
      if (localCount < 5) {
        final List<Patient> patients =
            await firestoreService.getAllPatientsForBranch(branchId);
        final patientsList = patients.map((p) => p.toMap()).toList();
        await LocalStorageService.saveAllLocalPatients(patientsList);
      }

      await LocalStorageService.downloadTodayTokens(branchId);
    } catch (e) {
      debugPrint("Warning: Error bootstrapping receptionist data: $e");
    }
  }

  Future<void> _logout() async {
    if (_isLoggingOut) return;
    final confirm = await showLogoutDialog(context);

    if (confirm == true && mounted) {
      setState(() => _isLoggingOut = true);
      try { _connectionSub?.cancel(); _connSub?.cancel(); } catch (_) {}
      try { _restockRealtimeSub?.cancel(); _restockFirestoreSub?.cancel(); } catch (_) {}
      try { _readyCountSub?.cancel(); _readyCountDebounce?.cancel(); } catch (_) {}
      try { ConnectionManager().stop().catchError((_) {}); } catch (_) {}
      try {
        await AuthService().signOut().timeout(const Duration(seconds: 4));
      } catch (_) {}

      if (mounted) {
        Navigator.of(context, rootNavigator: true).pushNamedAndRemoveUntil('/login', (r) => false);
      } else if (navigatorKey.currentState != null) {
        navigatorKey.currentState!.pushNamedAndRemoveUntil('/login', (r) => false);
      }
    }
  }

  @override
  void dispose() {
    _isLoggingOut = true;
    CampSessionService.activeCampNotifier.removeListener(_onCampChanged);
    CampSessionService.stopAutoCampTimer();
    if (_hybridBoxListenable != null && _hybridBoxListener != null) {
      _hybridBoxListenable!.removeListener(_hybridBoxListener!);
    }
    _restockRealtimeSub?.cancel();
    _restockFirestoreSub?.cancel();
    _readyCountSub?.cancel();
    _readyCountDebounce?.cancel();
    CampSessionService.activeCampNotifier.removeListener(_scheduleReadyCount);
    _connSub?.cancel();
    _connectionSub?.cancel();
    if (_controllerInitialized) {
      _tabController.removeListener(_onTabControllerChanged);
      _tabController.dispose();
    }
    // The LAN link is shared by every desk screen and only logout stops it (see _logout).
    debugPrint("[Lifecycle] HybridDispensaryScreen dispose");
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isMobile = GBreakpoint.isMobile(context);

    if (!Hive.isBoxOpen('app_settings')) {
      return FutureBuilder<Box>(
        future: LocalStorageService.ensureBoxOpen('app_settings'),
        builder: (context, snapshot) {
          if (!snapshot.hasData || snapshot.data == null || !snapshot.data!.isOpen) {
            return Scaffold(
              body: Center(child: CircularProgressIndicator(color: _teal)),
            );
          }
          final isDark = snapshot.data!.get('is_dark_mode', defaultValue: false) == true;
          return _buildThemedScaffold(context, isDark, isMobile);
        },
      );
    }

    return ValueListenableBuilder<Box>(
      valueListenable: Hive.box('app_settings').listenable(
        keys: ['is_dark_mode', 'theme_choice', 'visual_theme'],
      ),
      builder: (context, box, _) {
        final isDark = box.isOpen ? (box.get('is_dark_mode', defaultValue: false) == true) : false;
        return _buildThemedScaffold(context, isDark, isMobile);
      },
    );
  }

  /// The embedded tab screens are kept-alive widget instances, so a theme toggle does not
  /// rebuild them; parts that read `is_dark_mode` from Hive kept the old theme while
  /// Theme-driven parts switched (light text on light / dark on dark). Rebuild them once.
  void _rebuildTabsForTheme() {
    if (!mounted) return;
    final root = _tabBodyKey.currentContext;
    if (root is! Element) return;
    void mark(Element el) {
      el.markNeedsBuild();
      el.visitChildren(mark);
    }
    root.visitChildren(mark);
  }

  Widget _buildThemedScaffold(BuildContext context, bool isDark, bool isMobile) {
    if (!_isLoggingOut) {
      _syncTabController();
    }
    final currentThemeChoice = Hive.isBoxOpen('app_settings')
        ? Hive.box('app_settings').get('theme_choice')?.toString()
        : null;
    if ((_lastIsDark != null && _lastIsDark != isDark) ||
        (_lastThemeChoice != null && _lastThemeChoice != currentThemeChoice)) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _rebuildTabsForTheme());
    }
    _lastIsDark = isDark;
    _lastThemeChoice = currentThemeChoice;

    final isAllInOne = DispensaryPreferencesService.isHybridAllInOne(widget.userId);
    final rLower = widget.role.toLowerCase();
    final isRecDis = rLower.contains('rec') && rLower.contains('dis');
    final hasInventoryAccess = rLower.contains('dis') || rLower.contains('doc') || rLower.contains('inventory');

    void openInventory() {
      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => InventoryPage(
            branchId: widget.branchId,
            isDispenser: rLower.contains('dis'),
          ),
        ),
      );
    }

    return Scaffold(
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      appBar: GmwfAppBar(
        isFloating: false,
        title: 'Hybrid Desk – ${_resolvedName ?? widget.userName}',
        subtitle: CampSessionService.getBranchAndCampDisplayName(
          branchName: _branchName ?? LocalStorageService.getBranchName(widget.branchId),
          branchId: widget.branchId,
          campId: CampSessionService.getActiveCamp(widget.branchId),
        ),
        userId: widget.userId,
        showHybridLayoutToggle: isRecDis,
        showTimingFormatToggle: true,
        showPaneOrderToggle: isRecDis && isAllInOne,
        onToggleHybridLayout: () {
          if (mounted) setState(() => _parseRole());
        },
        onToggleTimingFormat: () {
          if (mounted) setState(() {});
        },
        onTogglePaneOrder: () {
          if (mounted) setState(() {});
        },
        centerWidget: (!isMobile && _tabs.length > 1) ? _buildHeaderPillTabs(isDark) : null,
        extraActions: [
          CampSelectorChip(
            branchId: widget.branchId,
            textColor: context.comfort.brand,
            bgColor: context.comfort.brandSoft,
            borderColor: context.comfort.brand.withValues(alpha: 0.30),
          ),
        ],
        onTitleLongPress: () => DispensaryUserSettingsDialog.show(
          context,
          branchId: widget.branchId,
          onUserUpdated: () {
            if (mounted) setState(() { _fetchUserNameAndConnect(); });
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
        deskActions: [
          if (_shouldShowRestockAlert && _pendingRestockAlerts.isNotEmpty)
            GmwfMenuAction(
              id: 'restock_requests',
              label: 'Restock Alerts (${_pendingRestockAlerts.length})',
              icon: Icons.warning_amber_rounded,
              badge: _pendingRestockAlerts.length,
              onTap: openInventory,
            ),
        ],
        onInventory: hasInventoryAccess ? openInventory : null,
        inventoryBadge: (_shouldShowRestockAlert) ? _pendingRestockAlerts.length : 0,
        onUserSettings: () => DispensaryUserSettingsDialog.show(
          context,
          branchId: widget.branchId,
          onUserUpdated: () {
            if (mounted) setState(() { _fetchUserNameAndConnect(); });
          },
        ),
        bottom: null,
      ),
      body: DeskBackdrop(
        child: Column(
          children: [
            Expanded(
              child: KeyedSubtree(
                key: ValueKey('tab_body_${_tabs.length}_${_tabController.length}_$isAllInOne'),
                child: LazyIndexedStack(
                  key: _tabBodyKey,
                  index: _tabs.isEmpty ? 0 : _activeTabIndex.clamp(0, _tabs.length - 1),
                  children: _tabs.map((t) => t['widget'] as Widget).toList(),
                ),
              ),
            ),
          ],
        ),
      ),
      bottomNavigationBar: (isMobile && _tabs.length > 1) ? _buildMobileBottomBar(isDark) : null,
    );
  }

  Widget _buildHeaderPillTabs(bool isDark) {
    final c = context.comfort;
    final activeIndex = _tabs.isEmpty ? 0 : _activeTabIndex.clamp(0, _tabs.length - 1);
    return Container(
      key: ValueKey('hybrid_header_pills_${_tabs.length}_${_tabController.length}'),
      height: 40,
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        color: c.surfaceSunken,
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: c.border),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: _tabs.asMap().entries.map((entry) {
          final idx = entry.key;
          final t = entry.value;
          final isSelected = activeIndex == idx;
          final title = t['title'] as String;
          final showBadge = _readyToDispenseCount > 0 && _isDispenseTab(title);

          return Padding(
            padding: EdgeInsets.only(left: idx == 0 ? 0 : 4),
            child: InkWell(
              borderRadius: BorderRadius.circular(20),
              onTap: () {
                _saveCurrentActiveTab(idx);
                if (_tabController.index != idx) {
                  _tabController.animateTo(idx);
                }
                if (_activeTabIndex != idx) {
                  setState(() => _activeTabIndex = idx);
                }
              },
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 160),
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
                decoration: BoxDecoration(
                  color: isSelected ? c.brand : Colors.transparent,
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      t['icon'] as IconData,
                      size: 16,
                      color: isSelected ? c.onBrand : c.textSecondary,
                    ),
                    const SizedBox(width: 7),
                    Text(
                      title,
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w700,
                        color: isSelected ? c.onBrand : c.textSecondary,
                      ),
                    ),
                    if (showBadge) ...[
                      const SizedBox(width: 6),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1.5),
                        decoration: BoxDecoration(
                          color: isSelected ? c.onBrand : c.brand,
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: Text(
                          '$_readyToDispenseCount',
                          style: TextStyle(
                            color: isSelected ? c.brand : c.onBrand,
                            fontSize: 10.5,
                            fontWeight: FontWeight.w800,
                          ),
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
    );
  }

  Widget _buildMobileBottomBar(bool isDark) {
    final c = context.comfort;
    final activeColor = c.brand;
    final inactiveColor = c.textMuted;
    final activeBg = c.brandSoft;

    return Container(
      decoration: BoxDecoration(
        color: c.surface,
        border: Border(
          top: BorderSide(
            color: c.border,
            width: 1.2,
          ),
        ),
        boxShadow: [
          BoxShadow(
            color: SoftPalette.gray900.withValues(alpha: isDark ? 0.35 : 0.08),
            blurRadius: 10,
            offset: const Offset(0, -2),
          ),
        ],
      ),
      child: SafeArea(
        top: false,
        child: SizedBox(
          height: 58,
          child: Row(
            children: _tabs.asMap().entries.map((entry) {
              final idx = entry.key;
              final t = entry.value;
              final activeIndex = _tabs.isEmpty ? 0 : _activeTabIndex.clamp(0, _tabs.length - 1);
              final isSelected = activeIndex == idx;

              return Expanded(
                child: InkWell(
                  onTap: () {
                    _saveCurrentActiveTab(idx);
                    if (_tabController.index != idx) {
                      _tabController.animateTo(idx);
                    }
                    if (_activeTabIndex != idx) {
                      setState(() => _activeTabIndex = idx);
                    }
                  },
                  splashColor: activeColor.withValues(alpha: 0.12),
                  highlightColor: Colors.transparent,
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      AnimatedContainer(
                        duration: const Duration(milliseconds: 200),
                        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
                        decoration: BoxDecoration(
                          color: isSelected ? activeBg : Colors.transparent,
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Icon(
                          t['icon'] as IconData,
                          size: 20,
                          color: isSelected ? activeColor : inactiveColor,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        t['title'] as String,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight: isSelected ? FontWeight.bold : FontWeight.w500,
                          color: isSelected ? activeColor : inactiveColor,
                        ),
                      ),
                    ],
                  ),
                ),
              );
            }).toList(),
          ),
        ),
      ),
    );
  }

  void _listenRestockRequests() {
    if (widget.branchId.isEmpty) return;

    // 1. Initial load from local Hive storage (instant, persists across restarts and works offline)
    _pendingRestockAlerts = LocalStorageService.getPendingRestockRequests(widget.branchId);

    // 2. Realtime WebSocket message stream
    _restockRealtimeSub?.cancel();
    _restockRealtimeSub = RealtimeManager().messageStream.listen((event) {
      final type = (event['event_type'] ?? event['type'])?.toString();
      if (type == RealtimeEvents.restockRequest || type == 'restock_request') {
        final rawData = event['data'];
        final data = (rawData is Map) ? Map<String, dynamic>.from(rawData) : Map<String, dynamic>.from(event);
        final medName = (data['medicineName'] ?? data['name'] ?? 'Medicine').toString();
        final currentQty = data['currentQty'] ?? data['quantity'] ?? 'low';
        final doctor = (data['requestedBy'] ?? 'Doctor').toString();
        final notes = (data['notes'] ?? '').toString();
        final reqId = data['id']?.toString() ?? 'restock_${DateTime.now().millisecondsSinceEpoch}';

        final reqData = {
          'id': reqId,
          'medicineName': medName,
          'currentQty': currentQty,
          'requestedBy': doctor,
          'notes': notes,
          'status': 'pending',
          'branchId': widget.branchId,
          'timestamp': DateTime.now().toIso8601String(),
        };

        LocalStorageService.saveRestockRequest(widget.branchId, reqData);

        final exists = _pendingRestockAlerts.any((r) => r['id'] == reqId || (r['medicineName'] == medName && r['status'] == 'pending'));
        if (!exists) {
          _pendingRestockAlerts.insert(0, reqData);
        }

        // No popup: the Stock & Inventory tab badge and the banner inside it show the request.
        if (mounted) setState(() {});
      }
    });

    // 3. Firestore snapshot listener for pending cloud catch-up
    try {
      _restockFirestoreSub?.cancel();
      _restockFirestoreSub = FirebaseFirestore.instance
          .collection('branches')
          .doc(widget.branchId)
          .collection('restock_requests')
          .where('status', isEqualTo: 'pending')
          .limit(50)
          .snapshots()
          .listen((snap) {
        if (!mounted) return;
        final alerts = <Map<String, dynamic>>[];
        for (final doc in snap.docs) {
          // Dismissed here but the cloud has not caught up yet: keep it dismissed.
          if (LocalStorageService.isLocalRequestDecided(doc.id)) continue;
          final d = Map<String, dynamic>.from(doc.data());
          d['id'] = doc.id;
          alerts.add(d);
          LocalStorageService.saveRestockRequest(widget.branchId, d);
        }
        setState(() {
          _pendingRestockAlerts = alerts;
        });
      }, onError: (e) {
        debugPrint('[HybridScreen] Restock requests stream error: $e');
      });
    } catch (_) {}
  }
}
