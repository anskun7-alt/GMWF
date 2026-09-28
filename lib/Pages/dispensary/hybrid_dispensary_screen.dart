// lib/pages/dispensary/hybrid_dispensary_screen.dart

import 'dart:async';
import 'package:flutter/material.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:another_flushbar/flushbar.dart';

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

import 'package:gmwf/models/patient.dart';
import 'package:gmwf/services/firestore_service.dart';
import 'package:gmwf/design/design_system.dart';

import 'receptionist/receptionist_screen.dart';
import 'dispensar/dispensar_screen.dart';
import 'dispensar/inventory.dart';
import 'doctor/doctor_screen.dart';
import 'package:gmwf/pages/login_page.dart';
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
    with SingleTickerProviderStateMixin {
  late TabController _tabController;
  final List<Map<String, dynamic>> _tabs = [];

  StreamSubscription<List<ConnectivityResult>>? _connSub;
  StreamSubscription<ConnectionStatus>? _connectionSub;

  bool _online = true;
  bool _isSyncing = false;
  String? _branchName;
  String? _resolvedName;

  ConnectionStatus _connectionStatus = const ConnectionStatus(
    state: LanConnectionState.disconnected,
    message: 'Not connected',
  );

  static const Color _teal = Color(0xFF00695C);

  StreamSubscription? _restockRealtimeSub;
  StreamSubscription? _restockFirestoreSub;
  List<Map<String, dynamic>> _pendingRestockAlerts = [];

  bool get _shouldShowRestockAlert {
    final r = widget.role.toLowerCase().trim();
    final hasDispenser = r.contains('dis') || r.contains('dispenser') || r.contains('dispensar');
    final hasDoctor = r.contains('doc') || r.contains('doctor');
    return hasDispenser && !hasDoctor;
  }

  @override
  void initState() {
    super.initState();

    _parseRole();
    _tabController = TabController(length: _tabs.length, vsync: this);

    if (_shouldShowRestockAlert) {
      _listenRestockRequests();
    }

    // Start services once
    SyncService().start(widget.branchId);
    _listenConnectivity();
    _loadBranchName();

    _fetchUserNameAndConnect();

    _connectionSub = ConnectionManager().statusStream.listen((status) {
      if (mounted) setState(() => _connectionStatus = status);
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
  }

  void _onCampChanged() {
    if (mounted) setState(() {});
  }

  void _parseRole([String? effectiveName]) {
    final name = effectiveName ?? _resolvedName ?? widget.userName;
    _tabs.clear();
    final r = widget.role.toLowerCase().trim();
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
    if (r.contains('rec') || r.contains('receptionist')) {
      final suppressPrescriptionNotifications = r.contains('doc') || r.contains('doctor');
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
    if (r.contains('dis') || r.contains('dispenser') || r.contains('dispensar')) {
      _tabs.add({
        'title': 'Dispenser',
        'icon': Icons.medication_outlined,
        'widget': DispensarScreen(
          branchId: widget.branchId,
          dispenserId: widget.userId,
          dispenserName: name,
          isEmbedded: true,
        ),
      });
    }
    if (r.contains('dis') || r.contains('dispenser') || r.contains('dispensar') || r.contains('doc') || r.contains('inventory')) {
      _tabs.add({
        'title': 'Stock & Inventory',
        'icon': Icons.inventory_2_outlined,
        'widget': InventoryPage(
          branchId: widget.branchId,
          isDispenser: true,
          isEmbedded: true,
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

    try {
      final oldIndex = _tabController.index;
      if (_tabController.length != _tabs.length) {
        _tabController.dispose();
        _tabController = TabController(
          length: _tabs.length,
          initialIndex: oldIndex.clamp(0, _tabs.length - 1),
          vsync: this,
        );
      }
    } catch (_) {}
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
          backgroundColor: Colors.green.shade700,
          duration: const Duration(seconds: 2),
        ).show(context);
      }
    } catch (e) {
      if (mounted) {
        Flushbar(
          message: 'Sync failed: $e',
          backgroundColor: Colors.red.shade700,
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
    final confirm = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Log Out'),
        content: const Text('Are you sure you want to log out of GMWF?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: _teal),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Log Out', style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );

    if (confirm == true) {
      try {
        await AuthService().signOut();
      } catch (_) {}
      if (mounted) {
        Navigator.pushAndRemoveUntil(
          context,
          MaterialPageRoute(builder: (_) => const LoginPage()),
          (r) => false,
        );
      }
    }
  }

  @override
  void dispose() {
    CampSessionService.activeCampNotifier.removeListener(_onCampChanged);
    CampSessionService.stopAutoCampTimer();
    _restockRealtimeSub?.cancel();
    _restockFirestoreSub?.cancel();
    _connSub?.cancel();
    _connectionSub?.cancel();
    _tabController.dispose();
    ConnectionManager().stop();
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
            return const Scaffold(
              body: Center(child: CircularProgressIndicator(color: _teal)),
            );
          }
          final isDark = snapshot.data!.get('is_dark_mode', defaultValue: false) == true;
          return _buildThemedScaffold(context, isDark, isMobile);
        },
      );
    }

    return ValueListenableBuilder<Box>(
      valueListenable: Hive.box('app_settings').listenable(keys: ['is_dark_mode']),
      builder: (context, box, _) {
        final isDark = box.isOpen ? (box.get('is_dark_mode', defaultValue: false) == true) : false;
        return _buildThemedScaffold(context, isDark, isMobile);
      },
    );
  }

  Widget _buildThemedScaffold(BuildContext context, bool isDark, bool isMobile) {

        return Scaffold(
          backgroundColor: isDark ? const Color(0xFF0F172A) : const Color(0xFFF1F8F5),
          appBar: GmwfAppBar(
            isFloating: false,
            title: 'Hybrid Desk – ${_resolvedName ?? widget.userName}',
            subtitle: CampSessionService.getBranchAndCampDisplayName(
              branchName: _branchName ?? LocalStorageService.getBranchName(widget.branchId),
              branchId: widget.branchId,
              campId: CampSessionService.getActiveCamp(widget.branchId),
            ),
            extraActions: [
              CampSelectorChip(
                branchId: widget.branchId,
                textColor: isDark ? const Color(0xFF38BDF8) : const Color(0xFF0F5B46),
                bgColor: isDark ? const Color(0xFF334155) : const Color(0xFFE8F5E9),
                borderColor: isDark ? const Color(0xFF475569) : const Color(0xFFA7F3D0),
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
            onInventory: () {
              final stockIdx = _tabs.indexWhere((t) =>
                  (t['title'] as String).toLowerCase().contains('stock') ||
                  (t['title'] as String).toLowerCase().contains('inventory'));
              if (stockIdx >= 0) {
                _tabController.animateTo(stockIdx);
              } else {
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => InventoryPage(
                      branchId: widget.branchId,
                      isDispenser: widget.role.toLowerCase().contains('dis'),
                    ),
                  ),
                );
              }
            },
            onUserSettings: () => DispensaryUserSettingsDialog.show(
              context,
              branchId: widget.branchId,
              onUserUpdated: () {
                if (mounted) setState(() { _fetchUserNameAndConnect(); });
              },
            ),
            bottom: isMobile
                ? null
                : PreferredSize(
                    preferredSize: const Size.fromHeight(48),
                    child: AnimatedBuilder(
                      animation: _tabController,
                      builder: (context, _) {
                        final activeIndex = _tabController.index;
                        return Container(
                          height: 48,
                          decoration: BoxDecoration(
                            color: isDark ? const Color(0xFF1E293B) : Colors.white,
                            borderRadius: BorderRadius.circular(14),
                            border: Border.all(
                              color: isDark ? const Color(0xFF334155) : const Color(0xFFE2E8F0),
                              width: 1.2,
                            ),
                            boxShadow: [
                              BoxShadow(
                                color: Colors.black.withValues(alpha: isDark ? 0.2 : 0.03),
                                blurRadius: 8,
                                offset: const Offset(0, 2),
                              ),
                            ],
                          ),
                          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
                          child: TabBar(
                            controller: _tabController,
                            isScrollable: false,
                            indicator: BoxDecoration(
                              color: isDark ? const Color(0xFF0F766E).withValues(alpha: 0.35) : const Color(0xFFE8F5E9),
                              borderRadius: BorderRadius.circular(10),
                              border: Border.all(
                                color: const Color(0xFF10B981),
                                width: 1.2,
                              ),
                            ),
                            indicatorSize: TabBarIndicatorSize.tab,
                            splashFactory: NoSplash.splashFactory,
                            overlayColor: WidgetStateProperty.all(Colors.transparent),
                            dividerColor: Colors.transparent,
                            labelPadding: const EdgeInsets.symmetric(horizontal: 2),
                            tabs: _tabs.asMap().entries.map((entry) {
                              final idx = entry.key;
                              final t = entry.value;
                              final isSelected = activeIndex == idx;
                              return Tab(
                                height: 38,
                                child: Container(
                                  alignment: Alignment.center,
                                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                                  child: Row(
                                    mainAxisAlignment: MainAxisAlignment.center,
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Icon(
                                        t['icon'] as IconData,
                                        size: 18,
                                        color: isSelected
                                            ? (isDark ? const Color(0xFF34D399) : const Color(0xFF00875A))
                                            : (isDark ? const Color(0xFF94A3B8) : const Color(0xFF64748B)),
                                      ),
                                      const SizedBox(width: 8),
                                        Text(
                                          t['title'] as String,
                                          style: TextStyle(
                                            fontWeight: isSelected ? FontWeight.bold : FontWeight.w600,
                                            fontSize: 14,
                                            color: isSelected
                                                ? (isDark ? const Color(0xFF34D399) : const Color(0xFF00875A))
                                                : (isDark ? const Color(0xFF94A3B8) : const Color(0xFF64748B)),
                                          ),
                                        ),
                                        if (_shouldShowRestockAlert &&
                                            _pendingRestockAlerts.isNotEmpty &&
                                            ((t['title'] as String).toLowerCase().contains('dispens') ||
                                                (t['title'] as String).toLowerCase().contains('stock'))) ...[
                                          const SizedBox(width: 6),
                                          Container(
                                            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                            decoration: BoxDecoration(
                                              color: Colors.red.shade700,
                                              borderRadius: BorderRadius.circular(10),
                                            ),
                                            child: Text(
                                              '${_pendingRestockAlerts.length}',
                                              style: const TextStyle(
                                                color: Colors.white,
                                                fontSize: 10,
                                                fontWeight: FontWeight.bold,
                                              ),
                                            ),
                                          ),
                                        ],
                                      ],
                                  ),
                                ),
                              );
                            }).toList(),
                          ),
                        );
                      },
                    ),
                  ),
          ),
          body: Column(
            children: [
              _buildRestockBanner(isDark),
              Expanded(
                child: AnimatedBuilder(
                  animation: _tabController,
                  builder: (context, _) {
                    final safeIndex = _tabs.isEmpty ? 0 : _tabController.index.clamp(0, _tabs.length - 1);
                    return IndexedStack(
                      index: safeIndex,
                      children: _tabs.map((t) => t['widget'] as Widget).toList(),
                    );
                  },
                ),
              ),
            ],
          ),
          bottomNavigationBar: isMobile ? _buildMobileBottomBar(isDark) : null,
        );
  }

  Widget _buildMobileBottomBar(bool isDark) {
    final activeColor = isDark ? const Color(0xFF34D399) : const Color(0xFF00875A);
    final inactiveColor = isDark ? const Color(0xFF94A3B8) : const Color(0xFF64748B);
    final activeBg = isDark ? const Color(0xFF0F766E).withValues(alpha: 0.3) : const Color(0xFFE8F5E9);

    return Container(
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF1E293B) : Colors.white,
        border: Border(
          top: BorderSide(
            color: isDark ? const Color(0xFF334155) : const Color(0xFFE2E8F0),
            width: 1.2,
          ),
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: isDark ? 0.35 : 0.08),
            blurRadius: 10,
            offset: const Offset(0, -2),
          ),
        ],
      ),
      child: SafeArea(
        top: false,
        child: AnimatedBuilder(
          animation: _tabController,
          builder: (context, _) {
            final activeIndex = _tabs.isEmpty ? 0 : _tabController.index.clamp(0, _tabs.length - 1);
            return SizedBox(
              height: 58,
              child: Row(
                children: _tabs.asMap().entries.map((entry) {
                  final idx = entry.key;
                  final t = entry.value;
                  final isSelected = activeIndex == idx;

                  return Expanded(
                    child: InkWell(
                      onTap: () {
                        if (_tabController.index != idx) {
                          _tabController.animateTo(idx);
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
            );
          },
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

        if (mounted) {
          setState(() {});
          ScaffoldMessenger.of(context).hideCurrentSnackBar();
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Row(
                children: [
                  const Icon(Icons.warning_amber_rounded, color: Colors.amberAccent, size: 28),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'RESTOCK ALERT: $medName',
                          style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13, color: Colors.white),
                        ),
                        Text(
                          '$doctor reported low stock (Current: $currentQty). Please restock.${notes.isNotEmpty ? ' ($notes)' : ''}',
                          style: const TextStyle(fontSize: 11.5, color: Colors.white70),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              backgroundColor: const Color(0xFFB91C1C),
              behavior: SnackBarBehavior.floating,
              duration: const Duration(seconds: 8),
              action: SnackBarAction(
                label: 'OPEN INVENTORY',
                textColor: Colors.amberAccent,
                onPressed: () {
                  final stockIdx = _tabs.indexWhere((t) =>
                      (t['title'] as String).toLowerCase().contains('stock') ||
                      (t['title'] as String).toLowerCase().contains('inventory'));
                  if (stockIdx >= 0) _tabController.animateTo(stockIdx);
                },
              ),
            ),
          );
        }
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
          .snapshots()
          .listen((snap) {
        if (!mounted) return;
        final alerts = <Map<String, dynamic>>[];
        for (final doc in snap.docs) {
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

  Future<void> _dismissRestockAlert(String reqId) async {
    setState(() {
      _pendingRestockAlerts.removeWhere((r) => r['id'] == reqId);
    });
    await LocalStorageService.updateRestockRequestStatus(widget.branchId, reqId, 'acknowledged');
    try {
      await FirebaseFirestore.instance
          .collection('branches')
          .doc(widget.branchId)
          .collection('restock_requests')
          .doc(reqId)
          .update({'status': 'acknowledged', 'acknowledgedAt': FieldValue.serverTimestamp()});
    } catch (_) {}
  }

  Widget _buildRestockBanner(bool isDark) {
    if (!_shouldShowRestockAlert || _pendingRestockAlerts.isEmpty) return const SizedBox.shrink();

    final first = _pendingRestockAlerts.first;
    final count = _pendingRestockAlerts.length;
    final medName = first['medicineName'] ?? first['name'] ?? 'Medicine';
    final doctor = first['requestedBy'] ?? 'Doctor';
    final currentQty = first['currentQty'] ?? first['quantity'] ?? '0';

    return Container(
      width: double.infinity,
      margin: const EdgeInsets.fromLTRB(14, 8, 14, 4),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF451A03) : const Color(0xFFFFFBEB),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFFF59E0B), width: 1.2),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.05),
            blurRadius: 4,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Row(
        children: [
          const Icon(Icons.warning_amber_rounded, color: Color(0xFFD97706), size: 24),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  count > 1
                      ? '⚠️ Restock Requests ($count pending): $medName and ${count - 1} more'
                      : '⚠️ Restock Alert: $medName (Current: $currentQty)',
                  style: TextStyle(
                    fontWeight: FontWeight.bold,
                    fontSize: 13,
                    color: isDark ? const Color(0xFFFDE68A) : const Color(0xFF92400E),
                  ),
                ),
                Text(
                  '$doctor requested restock from dispensary. Please restock soon.',
                  style: TextStyle(
                    fontSize: 11.5,
                    color: isDark ? const Color(0xFFD1D5DB) : const Color(0xFF78350F),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          TextButton(
            onPressed: () {
              final stockIdx = _tabs.indexWhere((t) =>
                  (t['title'] as String).toLowerCase().contains('stock') ||
                  (t['title'] as String).toLowerCase().contains('inventory'));
              if (stockIdx >= 0) {
                _tabController.animateTo(stockIdx);
              } else {
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => InventoryPage(
                      branchId: widget.branchId,
                      isDispenser: true,
                    ),
                  ),
                );
              }
            },
            style: TextButton.styleFrom(
              backgroundColor: const Color(0xFFD97706),
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
            ),
            child: const Text('Open Inventory', style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
          ),
          const SizedBox(width: 4),
          IconButton(
            icon: const Icon(Icons.close, size: 18),
            color: isDark ? Colors.white70 : Colors.black54,
            tooltip: 'Dismiss alert',
            onPressed: () {
              final id = first['id']?.toString();
              if (id != null) _dismissRestockAlert(id);
            },
          ),
        ],
      ),
    );
  }
}
