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
import 'package:gmwf/widgets/connection_status_widget.dart';
import 'package:gmwf/widgets/gmwf_app_bar.dart';
import 'package:gmwf/services/camp_session_service.dart';
import 'user_settings_dialog.dart';

import 'package:gmwf/models/patient.dart';
import 'package:gmwf/models/token.dart';
import 'package:gmwf/services/firestore_service.dart';

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

  @override
  void initState() {
    super.initState();

    _parseRole();
    _tabController = TabController(length: _tabs.length, vsync: this);

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

    // Run receptionist bootstrap if "rec" is included in role
    if (widget.role.toLowerCase().contains('rec')) {
      _bootstrapReceptionistData(widget.branchId);
    }
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
      if (mounted) {
        setState(() {
          _branchName = 'Free Dispensary';
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
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _branchName = 'Free Dispensary';
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
    _connSub?.cancel();
    _connectionSub?.cancel();
    _tabController.dispose();
    ConnectionManager().stop();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final screenWidth = MediaQuery.of(context).size.width;
    final isMobile = screenWidth < 700;

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
            title: 'Hybrid Desk – ${_resolvedName ?? widget.userName}',
            subtitle: CampSessionService.getBranchAndCampDisplayName(
              branchName: _branchName ?? 'Free Dispensary',
              branchId: widget.branchId,
              campId: CampSessionService.getActiveCamp(),
            ),
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
          body: AnimatedBuilder(
            animation: _tabController,
            builder: (context, _) {
              final safeIndex = _tabs.isEmpty ? 0 : _tabController.index.clamp(0, _tabs.length - 1);
              return IndexedStack(
                index: safeIndex,
                children: _tabs.map((t) => t['widget'] as Widget).toList(),
              );
            },
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
}
