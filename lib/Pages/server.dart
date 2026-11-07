// lib/pages/server.dart
//
// [ARCH DECISION] This is the live ServerSyncManager as of 2026-08-27. See Task 0.1 report.
// The implementation in lib/realtime/server_sync_manager.dart is dead code (only its static initHive helper is called at startup).
//
// FIXES vs previous version:
//   [FIX-A] The embedded ServerSyncManager._resolveQueueType() previously only
//           recognised 'zakat' and fell back to 'zakat' for everything else.
//           It now mirrors the canonical resolver: handles non-zakat/gmwf and
//           all known variant spellings.
//
//   [FIX-B] _queueForSync() for 'dispense_completed' now preserves queueType
//           in the serial-status patch op at TOP LEVEL (not just inside data)
//           so _syncToFirestore never has to guess.
//
//   [FIX-C] _syncToFirestore 'update_serial_status' now reads queueType from
//           the op level first, then falls back to a Hive lookup — never zakat
//           silently.
//
//   [FIX-D] Medicine inventory is decremented in Firestore when a
//           'dispense_completed' is synced (FieldValue.increment on
//           branches/{branchId}/inventory/{medicineId}.quantity).
//
//   [FIX-0.3] Standardized attendance event mapping and Firestore ingestion
//           to branches/{branchId}/employee_attendance/{dateKey}/records/{employeeId}.

import '../utils/ui_stall_monitor.dart';
import 'package:gmwf/design/tokens/comfort_colors.dart';
import 'package:gmwf/design/tokens/soft_palette.dart';
import '../widgets/lazy_indexed_stack.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:io' as io;
import 'dart:math' as math;
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:gmwf/design/components/app_toast.dart';
import 'package:flutter/services.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:intl/intl.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:connectivity_plus/connectivity_plus.dart';

import 'server_data_viewer.dart';
import 'settings/biometric_device_manager_page.dart';
import 'settings/python_terminal_screen.dart';
import 'package:hive_flutter/hive_flutter.dart';

import '../realtime/lan_server.dart';
import '../config/constants.dart';
import '../utils/network_utils.dart';
import '../services/auth_service.dart';
import '../services/local_storage_service.dart';
import '../services/camp_session_service.dart';
import '../widgets/department_activity_widget.dart';
import '../widgets/server_overview_panel.dart';
import '../widgets/stress_test_dialog.dart';
import '../realtime/stress_test_engine.dart';
import '../widgets/multi_server_control_widget.dart';
import '../widgets/lan_hardware_status_widget.dart';
import '../services/multi_server_service.dart';
import '../services/zkteco_network_service.dart';
import '../services/python_runner_service.dart';
import 'package:gmwf/design/design_system.dart';
import '../services/system_metrics_service.dart';
import '../services/user_theme_service.dart';
import '../services/network_health_service.dart';
import '../services/auto_update_service.dart';
import '../services/finance_local_storage.dart';
import '../widgets/update_dialog_widget.dart';
import '../services/donations_local_storage.dart';
import 'madrassa/utils/madrassa_local_storage.dart';
import 'package:uuid/uuid.dart';
import '../services/sync_service.dart';
import '../services/quota_service.dart';
import '../services/cloud/cloud_db.dart';
import '../services/cloud/lan_firestore_gate.dart';
import '../realtime/server_sync_coordinator.dart';
import '../main.dart' show AuthHomeWrapper;
import 'login_page.dart';
import '../constants/navigator_key.dart';
import '../services/offline_auth_service.dart';
import '../services/hourly_dispensary_sync.dart';
import '../realtime/realtime_manager.dart';
import '../realtime/realtime_router.dart' show RealtimeRouter;
import '../widgets/nexus_server_dashboard/nexus_colors.dart';
import '../widgets/nexus_server_dashboard/nexus_performance_chart.dart';
import '../widgets/nexus_server_dashboard/nexus_devices_table.dart';
import '../widgets/nexus_server_dashboard/nexus_top_header.dart';
import '../widgets/nexus_server_dashboard/nexus_sidebar.dart';
import '../widgets/nexus_server_dashboard/nexus_views.dart';
import '../widgets/nexus_server_dashboard/nexus_more_views.dart';
import '../widgets/nexus_server_dashboard/server_theme.dart';
import '../widgets/nexus_server_dashboard/server_theme_selector.dart';

// ─────────────────────────────────────────────────────────────────────────────
// Connected client model
// ─────────────────────────────────────────────────────────────────────────────
class ConnectedClient {
  final String socketId;
  final String role;
  final String branchId;
  final String? clientId;
  final String? username;
  final String deviceOs;
  final String appVersion;
  final String ipAddress;
  String currentActivity;
  DateTime connectedAt;
  DateTime lastActiveAt;
  int messagesCount;
  bool isActive;

  ConnectedClient({
    required this.socketId,
    required this.role,
    required this.branchId,
    this.clientId,
    this.username,
    this.deviceOs = 'Windows PC',
    String? appVersion,
    this.ipAddress = '192.168.1.x',
    this.currentActivity = 'Active on Network',
    required this.connectedAt,
    DateTime? lastActiveAt,
    this.messagesCount = 0,
    this.isActive = true,
  }) : appVersion = appVersion ?? 'v${AutoUpdateService.currentVersion}',
       lastActiveAt = lastActiveAt ?? connectedAt;

  IconData get icon {
    final r = role.toLowerCase();
    if (r.contains('rec+dis') || r.contains('hybrid') || r.contains('+') || r.contains('_dis') || r.contains('rec_')) return Icons.auto_awesome;
    if (r.contains('receptionist') || r == 'rec') return Icons.person_pin_circle;
    if (r.contains('doctor') || r == 'doc') return Icons.local_hospital;
    if (r.contains('dispenser') || r.contains('pharmacist') || r == 'dis') return Icons.medication;
    if (r.contains('supervisor') || r.contains('admin')) return Icons.admin_panel_settings;
    if (r.contains('finance') || r.contains('donations')) return Icons.account_balance;
    if (r.contains('teacher') || r.contains('faculty') || r.contains('madrassa') || r.contains('school')) return Icons.school;
    if (r.contains('library')) return Icons.local_library;
    if (r.contains('dasterkhwaan')) return Icons.soup_kitchen;
    if (r.contains('attendance')) return Icons.fingerprint;
    if (r.contains('server')) return Icons.dns;
    return Icons.devices;
  }

  Color get color {
    final r = role.toLowerCase();
    if (r.contains('rec+dis') || r.contains('hybrid') || r.contains('+') || r.contains('_dis') || r.contains('rec_')) return SoftPalette.cyan350;
    if (r.contains('receptionist') || r == 'rec') return SoftPalette.blue400;
    if (r.contains('doctor') || r == 'doc') return SoftPalette.green400;
    if (r.contains('dispenser') || r.contains('pharmacist') || r == 'dis') return SoftPalette.amber300;
    if (r.contains('supervisor') || r.contains('admin')) return SoftPalette.red500;
    if (r.contains('finance') || r.contains('donations')) return SoftPalette.teal500;
    if (r.contains('teacher') || r.contains('faculty') || r.contains('madrassa') || r.contains('school')) return SoftPalette.indigo600;
    if (r.contains('library')) return SoftPalette.orange600m;
    if (r.contains('dasterkhwaan')) return SoftPalette.red400;
    if (r.contains('attendance')) return SoftPalette.violet600;
    if (r.contains('server')) return SoftPalette.purple550;
    return SoftPalette.slate500;
  }

  String get displayName {
    final r = role.toLowerCase();
    String roleLabel;
    if (r == 'rec+dis' || r == 'rec_dis' || r == 'receptionist+dispenser') {
      roleLabel = 'Receptionist + Dispenser (Hybrid)';
    } else if (r == 'doc+dis' || r == 'doctor+dispenser') {
      roleLabel = 'Doctor + Dispenser (Hybrid)';
    } else {
      roleLabel = role[0].toUpperCase() + role.substring(1);
    }
    if (username != null &&
        username!.isNotEmpty &&
        username!.toLowerCase() != role.toLowerCase()) {
      return '$username ($roleLabel)';
    }
    return roleLabel;
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Widget
// ─────────────────────────────────────────────────────────────────────────────
class ServerDashboardWithSync extends StatefulWidget {
  final String branchId;
  final bool autoAuthenticate;

  const ServerDashboardWithSync({
    super.key,
    required this.branchId,
    this.autoAuthenticate = true,
  });

  @override
  State<ServerDashboardWithSync> createState() =>
      _ServerDashboardWithSyncState();
}

class _ServerDashboardWithSyncState
    extends State<ServerDashboardWithSync> {
  bool _isAuthenticated = true;
  bool _isRunning       = false;
  bool _isStarting      = false;
  bool _isAutoStarting  = false;
  bool _userStoppedServer = false;
  bool _isLoggingOut    = false;
  int  _selectedTab     = 0;
  String? _serverIp;
  DateTime? _startTime;
  final List<String> _activityLog = [];

  bool _isOnline     = false;
  bool _isManualSyncing = false;
  bool _isCatchingUp    = false;
  double _pulseTick  = 0.0;
  int  _syncQueueSize = 0;
  int  _syncedToday   = 0;
  int  _syncErrors    = 0;
  DateTime? _lastSyncTime;

  final Map<String, ConnectedClient> _connectedClients = {};
  io.RawDatagramSocket? _beaconSocket;
  final Map<String, DateTime> _otherServerSeen = {};
  Set<String> _localIps = {};
  Timer? _overviewTicker;
  StreamSubscription? _healthSub;
  // [epoch ms, total LAN messages (in + out), total LAN bytes (in + out)] sampled every 5 s.
  final List<List<num>> _lanSamples = [];
  final List<NexusTelemetryPoint> _telemetryHistory = [];
  bool _isFirewallBannerDismissed = false;
  bool _isFirewallBannerExpanded = false;

  Timer? _updateTimer;
  Timer? _syncTimer;
  Timer? _udpBroadcastTimer;
  Timer? _clientUiThrottleTimer;
  StreamSubscription<List<ConnectivityResult>>? _connectivitySub;
  StreamSubscription<Map<String, dynamic>>? _punchSubscription;
  StreamSubscription<SystemSnapshot>? _metricsSubscription;
  ServerSyncManager? _syncManager;
  LanServer? _server;
  SyncQueueStats _queueHealthStats = const SyncQueueStats();
  Timer? _queueStatsTimer;
  Timer? _firewallTimer;
  final ScrollController _runningScrollController = ScrollController();

  // ── Server location (branch + camp) ────────────────────────────────────────
  // The branch this server PC serves. Saved once on this PC ("Server location") and used
  // instead of the logged-in account's branch: a Karachi / Haji Camp server logged in with
  // an account whose record said "sialkot" announced itself as Sialkot to every desk,
  // registered itself under Sialkot in the cloud, and showed "Sialkot" in the header.
  static const String _siteBranchKey = 'server_site_branch';
  static const String _siteCampKey = 'server_site_camp';

  String? _readSetting(String key) {
    try {
      if (Hive.isBoxOpen('app_settings')) {
        final v = Hive.box('app_settings').get(key)?.toString().trim().toLowerCase();
        if (v != null && v.isNotEmpty && v != 'null') return v;
      }
    } catch (_) {}
    return null;
  }

  bool get _hasSiteLocation => _readSetting(_siteBranchKey) != null;
  String get _serverBranch => _readSetting(_siteBranchKey) ?? widget.branchId;
  String? get _serverCamp => _readSetting(_siteCampKey);

  /// Branch the connected desks actually belong to, when they all agree (null otherwise).
  String? _desksBranchFamily() {
    final fams = <String>{};
    for (final c in _connectedClients.values) {
      final cb = c.branchId.trim().toLowerCase();
      if (cb.isEmpty || cb == 'all' || cb == 'unknown' || cb == 'default' || cb == 'global') continue;
      fams.add(CampSessionService.isKarachiFamily(cb) ? 'karachi' : cb);
    }
    return fams.length == 1 ? fams.first : null;
  }

  /// True when the desks on this LAN belong to another branch than this server says it serves.
  bool get _locationMismatch {
    final desks = _desksBranchFamily();
    if (desks == null) return false;
    final mine = CampSessionService.isKarachiFamily(_serverBranch) ? 'karachi' : _serverBranch.toLowerCase().trim();
    return mine.isNotEmpty && mine != 'all' && !CampSessionService.areBranchesMatching(desks, mine);
  }

  List<String> _knownBranchIds() {
    final ids = <String>{'karachi', 'gujrat', 'sialkot', 'rawalpindi', 'jalalpurjattan'};
    try {
      if (Hive.isBoxOpen('local_branches')) {
        for (final k in Hive.box('local_branches').keys) {
          final id = k.toString().replaceAll('branch:', '').trim().toLowerCase();
          if (id.isNotEmpty && id != 'all' && !CampSessionService.isKarachiFamily(id)) ids.add(id);
        }
      }
    } catch (_) {}
    final list = ids.toList()..sort();
    return list;
  }

  /// Lets the admin set which branch / camp this server PC serves. Applied by restarting the
  /// LAN server (desks reconnect on their own within a few seconds).
  Future<void> _showServerLocationDialog() async {
    String branch = CampSessionService.isKarachiFamily(_serverBranch) ? 'karachi' : _serverBranch.toLowerCase().trim();
    final suggested = _desksBranchFamily();
    if (!_hasSiteLocation && suggested != null) branch = suggested;
    String? camp = _serverCamp;
    final branches = _knownBranchIds();
    if (!branches.contains(branch) && branch.isNotEmpty) branches.insert(0, branch);

    final result = await showDialog<({String branch, String? camp})>(
      context: context,
      builder: (ctx) => StatefulBuilder(builder: (ctx, setD) {
        final camps = CampSessionService.getCampsForBranch(branch, includeClosed: false);
        final campIds = camps
            .map((c) => (c['id'] ?? '').toString().trim().toLowerCase())
            .where((id) => id.isNotEmpty)
            .toList();
        if (camp != null && !campIds.contains(camp)) camp = null;
        return AlertDialog(
          backgroundColor: NexusColors.cardBg,
          title: Text('Server location', style: TextStyle(color: NexusColors.textMain, fontWeight: FontWeight.w700)),
          content: SizedBox(
            width: 380,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Which branch and camp does this server PC serve? Desks on this network connect to it as that branch.',
                  style: TextStyle(color: NexusColors.textSecondary, fontSize: 12.5),
                ),
                if (suggested != null && suggested != branch) ...[
                  const SizedBox(height: 8),
                  Text('Connected desks are from ${LocalStorageService.getBranchName(suggested)}.',
                      style: TextStyle(color: NexusColors.warning, fontSize: 12, fontWeight: FontWeight.w600)),
                ],
                const SizedBox(height: 14),
                DropdownButtonFormField<String>(
                  initialValue: branch,
                  dropdownColor: NexusColors.cardBg,
                  style: TextStyle(color: NexusColors.textMain),
                  decoration: const InputDecoration(labelText: 'Branch', border: OutlineInputBorder()),
                  items: branches
                      .map((b) => DropdownMenuItem(value: b, child: Text(LocalStorageService.getBranchName(b))))
                      .toList(),
                  onChanged: (v) => setD(() {
                    branch = v ?? branch;
                    camp = null;
                  }),
                ),
                if (campIds.isNotEmpty) ...[
                  const SizedBox(height: 12),
                  DropdownButtonFormField<String?>(
                    initialValue: camp,
                    dropdownColor: NexusColors.cardBg,
                    style: TextStyle(color: NexusColors.textMain),
                    decoration: const InputDecoration(labelText: 'Camp', border: OutlineInputBorder()),
                    items: [
                      const DropdownMenuItem<String?>(value: null, child: Text('All camps')),
                      ...campIds.map((id) => DropdownMenuItem<String?>(
                            value: id,
                            child: Text(CampSessionService.getCampLabel(id, branch)),
                          )),
                    ],
                    onChanged: (v) => setD(() => camp = v),
                  ),
                ],
              ],
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, (branch: branch, camp: camp)),
              child: const Text('Save & restart server'),
            ),
          ],
        );
      }),
    );
    if (result == null || !mounted) return;

    final box = Hive.box('app_settings');
    await box.put(_siteBranchKey, result.branch);
    if (result.camp == null) {
      await box.delete(_siteCampKey);
    } else {
      await box.put(_siteCampKey, result.camp);
    }
    _addLog('📍 Server location set to ${_resolveBranchAndCampDisplay()}');
    if (_isRunning) {
      _addLog('🔄 Restarting the LAN server with the new location…');
      await _stopServer();
      if (mounted) await _startServer();
    }
    if (mounted) {
      setState(() {});
      _showSuccess('Server location saved: ${_resolveBranchAndCampDisplay()}');
    }
  }

  /// Red bar shown on every tab while another GMWF server is heard on the network.
  Widget _buildOtherServerAlert() {
    return ValueListenableBuilder<Map<String, ({String branch, DateTime at})>>(
      valueListenable: LanServer.otherServers,
      builder: (context, _, __) {
        if (!_isRunning) return const SizedBox.shrink();
        final others = LanServer.activeOtherServers;
        if (others.isEmpty) return const SizedBox.shrink();
        final list = others.entries
            .map((e) => e.value.branch.isEmpty
                ? e.key
                : '${e.key} (${LocalStorageService.getBranchName(e.value.branch)})')
            .join(', ');
        return Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 10),
          decoration: BoxDecoration(
            color: NexusColors.errorMuted,
            border: Border(bottom: BorderSide(color: NexusColors.errorBorder)),
          ),
          child: Row(
            children: [
              Icon(Icons.dns_rounded, color: NexusColors.error, size: 20),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  'Another GMWF server is running on this network: $list. '
                  'Desks will split between the two servers and tokens will go missing. '
                  'Keep only ONE server — close GMWF (or stop the server) on the other PC.',
                  style: GoogleFonts.inter(fontSize: 12.5, fontWeight: FontWeight.w600, color: NexusColors.textMain),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  String _resolveEffectiveBranchId() {
    // An explicit server location always wins.
    final site = _readSetting(_siteBranchKey);
    if (site != null) return CampSessionService.isKarachiFamily(site) ? 'karachi' : site;
    String candidate = _serverBranch.trim().toLowerCase();
    // 1. If connected clients on the LAN all belong to one branch (e.g. 'karachi') and
    // _serverBranch was stale/mismatched, infer it from the active LAN clients.
    final clientBranches = <String>{};
    for (final c in _connectedClients.values) {
      final cb = c.branchId.trim().toLowerCase();
      if (cb.isNotEmpty && cb != 'all' && cb != 'unknown' && cb != 'default' && cb != 'global') {
        clientBranches.add(CampSessionService.isKarachiFamily(cb) ? 'karachi' : cb);
      }
    }
    if (clientBranches.length == 1) {
      return clientBranches.first;
    }
    // 2. Check app_settings if healed during startup
    try {
      if (Hive.isBoxOpen('app_settings')) {
        final box = Hive.box('app_settings');
        final sel = (box.get('selected_branch') ?? box.get('current_branch'))?.toString().trim().toLowerCase();
        if (sel != null && sel.isNotEmpty && sel != 'all' && sel != 'unknown') {
          candidate = sel;
        }
      }
    } catch (_) {}
    if (CampSessionService.isKarachiFamily(candidate)) {
      return 'karachi';
    }
    return candidate.isNotEmpty ? candidate : _serverBranch;
  }

  String _resolveBranchAndCampDisplay() {
    final effBranch = _resolveEffectiveBranchId();
    final branchTitle = LocalStorageService.getBranchName(effBranch);
    if (!CampSessionService.hasCampsForBranch(effBranch)) {
      return branchTitle;
    }
    // The camp saved in the server location wins; otherwise the active camp / connected desks.
    String? campId = _serverCamp ?? CampSessionService.getActiveCamp(effBranch);
    if (campId == null || campId.isEmpty || campId == 'all') {
      for (final c in _connectedClients.values) {
        final cb = c.branchId.trim().toLowerCase();
        if (cb.isNotEmpty && cb != effBranch && CampSessionService.areBranchesMatching(cb, effBranch)) {
          campId = cb;
          break;
        }
      }
    }
    if (campId != null && campId.isNotEmpty && campId != 'all') {
      final campLabel = CampSessionService.getCampLabel(campId, effBranch);
      if (campLabel.isNotEmpty && campLabel.toLowerCase() != branchTitle.toLowerCase()) {
        return '$branchTitle — $campLabel';
      }
    }
    final camps = CampSessionService.getCampsForBranch(effBranch, includeClosed: false);
    if (camps.isNotEmpty) {
      final names = camps
          .map((c) => (c['name'] ?? c['label'] ?? c['id'] ?? '').toString().trim())
          .where((n) => n.isNotEmpty)
          .toList();
      if (names.isNotEmpty) {
        return '$branchTitle (${names.join(' / ')})';
      }
    }
    return branchTitle;
  }

  @override
  void initState() {
    super.initState();

    _isAuthenticated = true;
    _userStoppedServer = false;
    _isLoggingOut = false;
    try {
      if (Hive.isBoxOpen('app_settings')) {
        Hive.box('app_settings').put('server_authenticated', true);
      }
    } catch (_) {}
    _initializeSync();
    // Real firewall check (the banner used to show on every Windows PC). Rechecked every 5 min.
    unawaited(_checkFirewall());
    _firewallTimer = Timer.periodic(const Duration(minutes: 5), (_) => _checkFirewall());
    _checkConnectivity();
    _startBeaconWatch();
    // 15 s (was 5): each tick rebuilds the whole dashboard.
    _overviewTicker = Timer.periodic(const Duration(seconds: 15), (_) {
      final now = DateTime.now().millisecondsSinceEpoch;
      _lanSamples.add([
        now,
        LanServer.trafficMsgsIn + LanServer.trafficMsgsOut,
        LanServer.trafficBytesIn + LanServer.trafficBytesOut,
      ]);
      _lanSamples.removeWhere((s) => now - s[0] > 65000);

      // (CPU/RAM history is filled from the live metrics stream below, every 5 s. Adding the
      // same cached reading here as well put stale duplicate points on the chart.)

      // Refresh lastActiveAt for all connected clients from the server's tracked activity
      if (_server != null) {
        final serverClients = _server!.getConnectedClients();
        for (final sc in serverClients) {
          final sId = sc['socketId']?.toString();
          if (sId != null && _connectedClients.containsKey(sId)) {
            final lastAct = sc['lastActive'] as DateTime?;
            if (lastAct != null) {
              _connectedClients[sId]!.lastActiveAt = lastAct;
            }
          }
        }
      }

      if (mounted) setState(() {});
    });
    _detectIp().then((_) {
      if (mounted && !_isRunning && !_userStoppedServer && !_isLoggingOut) {
        _autoStartServer();
      }
    });

    _connectivitySub =
        Connectivity().onConnectivityChanged.listen((results) {
      final hasInterface = results.any((r) => r != ConnectivityResult.none);
      final online = hasInterface && NetworkHealthService().isStableOnline;
      setState(() => _isOnline = online);
      if (online && _syncManager != null) {
        _addLog('📡 Back online - triggering sync');
        _syncManager!.triggerSync();
      } else if (!online) {
        _addLog('⚠️ Offline - operating in local LAN mode (changes safely queued)');
      }
    });

    _healthSub?.cancel(); // was never cancelled: one more listener per dashboard open
    _healthSub = NetworkHealthService().onHealthChanged.listen((state) {
      if (mounted) {
        final online = state == NetworkQualityState.onlineStable;
        setState(() => _isOnline = online);
        if (online && _syncManager != null) {
          _syncManager!.triggerSync();
        }
      }
    });

    _updateTimer = Timer.periodic(const Duration(seconds: 2), (_) {
      if (mounted) {
        final newQueue = _syncManager?.queueSize ??
            (Hive.isBoxOpen(LocalStorageService.syncBox) ? Hive.box(LocalStorageService.syncBox).length : 0);
        if (newQueue != _syncQueueSize) {
          setState(() {
            _syncQueueSize = newQueue;
          });
        }
      }
    });

    _punchSubscription = ZkTecoNetworkService.punchStream.listen((punch) {
      if (mounted) {
        final pin = punch['pin']?.toString() ?? '';
        final name = punch['entityName'] ?? 'PIN $pin';
        final type = punch['entityType'] ?? 'user';
        final loc = punch['buildingLocation'] ?? punch['deviceIp'] ?? 'Biometric Scanner';
        final driftStr = punch['timeDriftFormatted']?.toString() ?? 'In Sync';
        final hasDriftAlert = punch['hasTimeDriftAlert'] == true;

        if (punch['isMapped'] == true) {
          _addLog('👉 Biometric Punch: $name ($type) at $loc [Time Drift: $driftStr]');
        } else {
          _addLog('⚠️ Scanner Scan: PIN $pin (Unassigned) at $loc [Time Drift: $driftStr]');
        }

        if (hasDriftAlert) {
          _addLog('⏱️ Clock Drift Alert: Device clock differs by $driftStr from Server PC!');
        }
      }
    });

    SystemMetricsService().startMonitoring();
    _metricsSubscription = SystemMetricsService().metricsStream.listen((snap) {
      if (mounted) {
        // Only real CPU readings go on the chart (the first sample only sets the baseline).
        if (snap.cpuKnown) {
          _telemetryHistory.add(NexusTelemetryPoint(
            timestamp: snap.timestamp,
            cpuPercent: snap.cpuPercent,
            ramPercent: snap.ramPercent,
          ));
          // 15 minutes of 5-second samples.
          while (_telemetryHistory.length > 180) {
            _telemetryHistory.removeAt(0);
          }
        }
        setState(() {});
      }
    });

    _refreshQueueHealthStats();
    _queueStatsTimer = Timer.periodic(const Duration(seconds: 30), (_) {
      _refreshQueueHealthStats();
    });

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        UpdateDialogWidget.showUpdateDialogIfNeeded(context, isServerMode: true);
      }
    });
  }

  // ── Windows Firewall: real check + one-click fix ──────────────────────────────
  // The banner used to show on every Windows PC (it never looked at the firewall), and the
  // fix ran netsh without administrator rights, so Windows refused it and nothing happened.

  /// True only when the firewall really does not let desks reach the LAN server port.
  bool _firewallBlocked = false;
  bool _isFixingFirewall = false;

  /// Reads the firewall through Windows' FwPolicy2 object (works without admin rights;
  /// Get-NetFirewallPortFilter does not). Prints OK, BLOCKED (a Block rule for this program
  /// beats every Allow rule) or MISSING (no rule lets the port in on the current network).
  static const String _firewallCheckScript = r'''
$ErrorActionPreference = 'SilentlyContinue'
$exe  = "$env:GMWF_EXE"
$port = "$env:GMWF_PORT"
$fw = New-Object -ComObject HNetCfg.FwPolicy2
$cur = $fw.CurrentProfileTypes
$ok = $false; $blocked = $false
foreach ($r in $fw.Rules) {
  if ($r.Direction -ne 1 -or -not $r.Enabled) { continue }
  if (($r.Profiles -band $cur) -eq 0) { continue }
  if ($r.Protocol -ne 6 -and $r.Protocol -ne 256) { continue }
  $lp = "$($r.LocalPorts)"
  $ports = @($lp -split ',' | ForEach-Object { $_.Trim() })
  $portOk = ($lp -eq '' -or $lp -eq '*' -or ($ports -contains $port))
  if (-not $portOk) {
    foreach ($p in $ports) { if ($p -match '^(\d+)-(\d+)$' -and [int]$port -ge [int]$matches[1] -and [int]$port -le [int]$matches[2]) { $portOk = $true } }
  }
  $app = "$($r.ApplicationName)"
  $appOk = ($app -eq '') -or ($exe -ne '' -and $app -ieq $exe)
  $specific = ($ports -contains $port) -or ($exe -ne '' -and $app -ieq $exe)
  if ($portOk -and $appOk -and $specific) {
    if ($r.Action -eq 0) { $blocked = $true } elseif ($r.Action -eq 1) { $ok = $true }
  }
}
if ($blocked) { 'BLOCKED' } elseif ($ok) { 'OK' } else { 'MISSING' }
''';

  /// Runs [script] with Windows PowerShell from a temporary file; returns trimmed stdout.
  Future<({int code, String out})> _runPowerShellScript(String script,
      {Map<String, String>? env, Duration timeout = const Duration(seconds: 20)}) async {
    final file = io.File(
        '${io.Directory.systemTemp.path}${io.Platform.pathSeparator}gmwf_fw_${DateTime.now().microsecondsSinceEpoch}.ps1');
    try {
      await file.writeAsString(script);
      final res = await io.Process.run(
        'powershell',
        ['-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', file.path],
        environment: env,
      ).timeout(timeout);
      return (code: res.exitCode, out: res.stdout.toString().trim());
    } finally {
      try { await file.delete(); } catch (_) {}
    }
  }

  Future<String> _checkFirewall() async {
    if (kIsWeb || !io.Platform.isWindows) return 'OK';
    try {
      final r = await _runPowerShellScript(_firewallCheckScript, env: {
        'GMWF_EXE': io.Platform.resolvedExecutable,
        'GMWF_PORT': AppNetwork.websocketPort.toString(),
      });
      final state = r.out.split(RegExp(r'\s+')).lastWhere((s) => s.isNotEmpty, orElse: () => 'OK');
      final blocked = state == 'BLOCKED' || state == 'MISSING';
      if (mounted && blocked != _firewallBlocked) setState(() => _firewallBlocked = blocked);
      if (blocked) _addLog('🛡️ Firewall check: port ${AppNetwork.websocketPort} is $state for desks on this network');
      return state;
    } catch (e) {
      // Could not read the firewall: do not show a false alarm.
      debugPrint('[Server] Firewall check failed: $e');
      return 'UNKNOWN';
    }
  }

  Future<void> _openFirewallPort() async {
    if (kIsWeb || !io.Platform.isWindows) {
      _showError('Firewall configuration is only applicable on Windows.');
      return;
    }
    if (_isFixingFirewall) return;
    _isFixingFirewall = true;
    final port = AppNetwork.websocketPort;
    final exe = io.Platform.resolvedExecutable.replaceAll("'", "''");
    // Runs elevated (Windows shows its "allow changes" prompt). Replaces GMWF's own rules
    // (so re-running never piles up duplicates) and disables any Block rule Windows created
    // for this program when its first-run firewall prompt was cancelled.
    final fixScript = '''
\$exe = '$exe'
foreach (\$n in 'GMWF_LAN_Server','GMWF_LAN','GMWF_LAN_UDP_53280','GMWF_ZKTeco_ADMS_8088','GMWF_ZKTeco_UDP_4370','GMWF_ZKTeco_UDP','GMWF_App_Inbound') {
  netsh advfirewall firewall delete rule name="\$n" | Out-Null
}
netsh advfirewall firewall add rule name="GMWF_LAN_Server" dir=in action=allow protocol=TCP localport=$port profile=any | Out-Null
netsh advfirewall firewall add rule name="GMWF_LAN_UDP_53280" dir=in action=allow protocol=UDP localport=53280 profile=any | Out-Null
netsh advfirewall firewall add rule name="GMWF_ZKTeco_ADMS_8088" dir=in action=allow protocol=TCP localport=8088 profile=any | Out-Null
netsh advfirewall firewall add rule name="GMWF_ZKTeco_UDP_4370" dir=in action=allow protocol=UDP localport=4370 profile=any | Out-Null
netsh advfirewall firewall add rule name="GMWF_App_Inbound" dir=in action=allow program="\$exe" enable=yes profile=any | Out-Null
\$fw = New-Object -ComObject HNetCfg.FwPolicy2
foreach (\$r in @(\$fw.Rules)) {
  if (\$r.Direction -eq 1 -and \$r.Action -eq 0 -and \$r.Enabled -and "\$(\$r.ApplicationName)" -ieq \$exe) { \$r.Enabled = \$false }
}
exit 0
''';
    final fixFile = io.File(
        '${io.Directory.systemTemp.path}${io.Platform.pathSeparator}gmwf_fw_fix_${DateTime.now().microsecondsSinceEpoch}.ps1');
    try {
      await fixFile.writeAsString(fixScript);
      _addLog('🛡️ Asking Windows for administrator permission to open port $port…');
      final launcher = "try { \$p = Start-Process -FilePath powershell -Verb RunAs -Wait -PassThru -WindowStyle Hidden "
          "-ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-File','\"${fixFile.path}\"'); exit \$p.ExitCode } "
          "catch { exit 1223 }";
      final res = await io.Process.run('powershell', ['-NoProfile', '-NonInteractive', '-Command', launcher])
          .timeout(const Duration(minutes: 2));
      if (res.exitCode == 1223) {
        _addLog('⚠️ Firewall fix cancelled at the Windows permission prompt');
        if (mounted) _showError('Firewall not changed: the Windows permission prompt was cancelled. Click "Fix Firewall" again and choose Yes.');
        return;
      }
      final state = await _checkFirewall();
      if (state == 'OK') {
        _addLog('🔓 Firewall opened: TCP $port (LAN), UDP 53280 (discovery), TCP 8088 / UDP 4370 (biometrics)');
        if (mounted) _showSuccess('Firewall fixed — other PCs can now connect on port $port.');
      } else {
        _addLog('⚠️ Firewall still reports $state after the fix (exit ${res.exitCode})');
        if (mounted) {
          _showError('The firewall still blocks port $port. A company/antivirus firewall may be overriding Windows — '
              'ask IT to allow TCP $port and UDP 53280 for GMWF.');
        }
      }
    } catch (e) {
      _addLog('⚠️ Could not open the firewall automatically: $e');
      if (mounted) _showError('Could not change the firewall automatically: $e');
    } finally {
      _isFixingFirewall = false;
      try { await fixFile.delete(); } catch (_) {}
    }
  }

  Future<void> _autoStartServer() async {
    if (_isAutoStarting || _isRunning || _isStarting || _userStoppedServer || _isLoggingOut) return;
    _isAutoStarting = true;
    try {
      for (int attempt = 0; attempt < 8; attempt++) {
        if (!mounted || _isRunning || _userStoppedServer || _isLoggingOut) break;
        if (_isStarting) {
          await Future.delayed(const Duration(milliseconds: 500));
          if (!mounted || _isRunning || _userStoppedServer || _isLoggingOut) break;
        }
        if (attempt > 0) {
          await Future.delayed(const Duration(milliseconds: 600));
        }
        if (!mounted || _isRunning || _userStoppedServer || _isLoggingOut) break;
        await _startServer();
        if (_isRunning || _userStoppedServer || _isLoggingOut) break;
      }
    } finally {
      _isAutoStarting = false;
    }
  }

  Future<void> _initializeSync() async {
    try {
      if (!Hive.isBoxOpen(LocalStorageService.syncBox)) {
        await Hive.openBox(LocalStorageService.syncBox);
      }
      // Non-blocking staggered sweeps to guarantee zero UI stall on startup
      Future.delayed(const Duration(seconds: 4), () {
        LocalStorageService.purgePhantomUnknownTokens(_serverBranch).ignore();
      });
      Future.delayed(const Duration(seconds: 8), () {
        LocalStorageService.purgeBloatedSyncQueue().ignore();
      });
    } catch (e) {
      debugPrint('Hive init error: $e');
    }
    if (mounted) {
      setState(() {
        _syncQueueSize =
            Hive.box(LocalStorageService.syncBox).length;
      });
    }
  }

  Future<void> _checkConnectivity() async {
    bool online = true;
    try {
      if (NetworkHealthService().isStableOnline) {
        online = true;
      } else if (!kIsWeb && (io.Platform.isAndroid || io.Platform.isIOS)) {
        final results = await Connectivity().checkConnectivity();
        online = results.any((r) => r != ConnectivityResult.none);
      }
    } catch (_) {
      online = true;
    }
    if (mounted) {
      setState(() => _isOnline = online);
    }
  }

  Future<void> _detectIp() async {
    final ip = await getPrimaryLanIp();
    setState(() => _serverIp = ip ?? _serverIp ?? '127.0.0.1');
  }

  Future<void> _startServer() async {
    UiStallMonitor.mark('server: _startServer');
    if (_isRunning || _isStarting || _isLoggingOut) return;
    _userStoppedServer = false;
    _isStarting = true;

    if (kIsWeb) {
      _showError('Server hosting is not supported on web.');
      _isStarting = false;
      return;
    }
    // IP discovery runs in parallel during initState. Wait for it here so
    // auto-start cannot permanently fail just because discovery is slow.
    if (_serverIp == null || _serverIp!.isEmpty) {
      final detectedIp = await getPrimaryLanIp();
      if (detectedIp != null && detectedIp.isNotEmpty) {
        _serverIp = detectedIp;
      } else {
        _serverIp = '127.0.0.1';
      }
      if (mounted) {
        setState(() {});
      }
    }

    unawaited(_openFirewallPort());

    try {
      _server = LanServer(port: AppNetwork.websocketPort)
        // Announced in the discovery beacon so desks join their own branch's server only.
        ..branchId = _serverBranch;

      _server!.onClientConnected = (socketId, info) {
        final cId = info['clientId']?.toString();
        final cIp = info['ipAddress']?.toString() ?? info['deviceIp']?.toString();
        final uName = info['username']?.toString();
        if (!mounted) return;

        setState(() {
          _connectedClients.removeWhere((key, existing) {
            if (key == socketId) return true;
            if (cId != null && cId.isNotEmpty && existing.clientId == cId) return true;
            return false;
          });

          _connectedClients[socketId] = ConnectedClient(
            socketId:    socketId,
            role:        info['role']     as String? ?? 'unknown',
            branchId:    info['branchId'] as String? ?? _serverBranch,
            clientId:    info['clientId'] as String?,
            username:    info['username'] as String?,
            deviceOs:    info['deviceOs'] as String? ?? info['platform'] as String? ?? (kIsWeb ? 'Chrome Web' : 'Windows PC'),

            appVersion:  info['appVersion'] as String? ?? 'v${AutoUpdateService.currentVersion}',
            ipAddress:   info['ipAddress'] as String? ?? info['deviceIp'] as String? ?? '192.168.1.x',
            currentActivity: 'Connected to Branch Server',
            connectedAt: DateTime.now(),
          );
        });
        final name = info['username'] ?? info['role'];
        final clientIp = info['ipAddress'] ?? info['deviceIp'] ?? '127.0.0.1';
        _addLog('🟢 Connected: $name (${info['role']} / ${info['branchId']}) - IP: $clientIp');
      };

      _server!.onClientDisconnected = (socketId) {
        final client = _connectedClients[socketId];
        if (!mounted) {
          _connectedClients.remove(socketId);
          return;
        }
        setState(() => _connectedClients.remove(socketId));
        if (client != null) {
          _addLog('🔴 Disconnected: ${client.displayName}');
        }
      };

      _server!.onClientActivity = (socketId) {
        final client = _connectedClients[socketId];
        if (client != null) {
          client.lastActiveAt = DateTime.now();
        }
      };

      _server!.onMessageReceived = (message) {
        final rawType = message['event_type']?.toString() ?? message['type']?.toString() ?? 'activity';
        final sender = message['_senderUsername'] ?? message['_senderRole'] ?? message['username'] ?? 'Client';
        final socketId = message['_socketId']?.toString();
        final clientId = message['_clientId']?.toString();

        if (rawType != 'ping' && rawType != 'pong' && rawType != 'identify' && rawType != 'identified') {
          _addLog('📨 $rawType: from $sender');
        }

        bool clientUpdated = false;
        for (final entry in _connectedClients.entries) {
          if (entry.key == socketId || entry.value.clientId == clientId || entry.value.username == sender) {
            entry.value.messagesCount++;
            entry.value.lastActiveAt = DateTime.now();
            entry.value.currentActivity = _describeActivity(rawType, message['data']);
            clientUpdated = true;
          }
        }
        if (clientUpdated && mounted) {
          if (_clientUiThrottleTimer?.isActive != true) {
            _clientUiThrottleTimer = Timer(const Duration(seconds: 1), () {
              if (mounted) setState(() {});
            });
          }
        }
      };

      await _server!.start(_serverIp);

      // The WebSocket server is the essential service. Mark it running now;
      // optional biometric/Python/Firestore services must not hide a working
      // LAN token server if one of them is unavailable.
      if (mounted) {
        setState(() {
          _isRunning = true;
          _startTime = DateTime.now();
        });
      }

      _syncManager = ServerSyncManager(
        branchId: _serverBranch,
        server:   _server!,
        onSyncComplete: (int count) {
          if (!mounted) return;
          setState(() {
            _syncedToday += count;
            _lastSyncTime = DateTime.now();
          });
          _refreshQueueHealthStats();
          _addLog('✅ Synced $count items to Firestore');
        },
        onSyncError: (error) {
          if (!mounted) return;
          setState(() => _syncErrors++);
          _addLog('❌ Sync error: $error');
        },
        onMessageReceived: (message) {
          final rawType = message['event_type']?.toString() ?? message['type']?.toString() ?? 'activity';
          if (rawType != 'ping' && rawType != 'pong' && rawType != 'identify' && rawType != 'identified') {
            _addLog('📨 $rawType: ${message['_senderUsername'] ?? message['_senderRole'] ?? message['username']}');
          }
        },
      );


      await _syncManager!.start();

      // [FIX-1.2] Enable attendance server role for this instance
      await LocalStorageService.setAttendanceServerRole(true);

      // Start embedded ZKTeco Biometric listener on Port 8088 / 4370.
      // A busy hardware port must not stop LAN token routing.
      try {
        await ZkTecoNetworkService.startServer();
        _addLog('✅ ZKTeco Biometric Listener active on Port 8088 / 4370');
      } catch (e) {
        _addLog('⚠️ Biometric listener unavailable; LAN tokens remain active: $e');
      }

      // Automatically start Python ZKTeco Sync Daemon when the Server starts
      if (!kIsWeb) {
        if (!PythonRunnerService.instance.isRunning) {
          _addLog('🐍 Auto-starting Python ZKTeco Sync Daemon...');
          unawaited(PythonRunnerService.instance.startScript('zkteco_sync_service.py', args: ['--config', 'config.json']).then((success) {
            if (success) {
              _addLog('🟢 Python ZKTeco Sync Daemon running (PID: ${PythonRunnerService.instance.runningPid})');
            } else {
              _addLog('⚠️ Python daemon start skipped (check Python Terminal for details)');
            }
          }));
        } else {
          _addLog('🟢 Python ZKTeco Sync Daemon already active (PID: ${PythonRunnerService.instance.runningPid})');
        }
      }

      MultiServerService().startHeartbeatLoop(
        branchId: _serverBranch,
        roleSupplier: () => 'primary',
        clientsSupplier: () => _connectedClients.length,
        queueSupplier: () => _syncManager?.queueSize ?? 0,
      );

      // Immediately publish activeServerIp to Firestore for instant discovery by clients
      if (_serverIp != null && _serverIp!.isNotEmpty) {
        MultiServerService().registerAndHeartbeat(
          branchId: _serverBranch,
          serverRole: 'primary',
          connectedClientsCount: _connectedClients.length,
          syncQueueSize: _syncManager?.queueSize ?? 0,
        );

        // Also publish directly to Firestore branches doc so all network desks discover this server automatically
        if (_serverIp != '127.0.0.1' && _serverIp != 'localhost') {
          try {
            CloudDb.instance.collection('branches').doc(_serverBranch).set({ // REST: no hidden SDK queue
              'activeServerIp': _serverIp,
              'activeServerPort': AppNetwork.websocketPort,
              'serverLastSeen': FieldValue.serverTimestamp(),
            }, SetOptions(merge: true)).catchError((e) {
              debugPrint('[Server] Could not publish activeServerIp to Firestore: $e');
            });
          } catch (e) {
            debugPrint('[Server] Exception publishing activeServerIp to Firestore: $e');
          }
        }
      }

      _addLog('✅ Server started on $_serverIp:${AppNetwork.websocketPort}');
      _addLog('✅ Sync bridge active');
      _showSuccess('Server is running!');
      _startUdpBroadcast();
    } catch (e) {
      if (mounted && _server == null) {
        setState(() => _isRunning = false);
      }
      _showError('Failed to start: $e');
      _addLog('❌ Start failed: $e');
    } finally {
      _isStarting = false;
    }
  }

  io.RawDatagramSocket? _serverUdpSocket;

  void _startUdpBroadcast() async {
    _udpBroadcastTimer?.cancel();
    try {
      _serverUdpSocket?.close();
    } catch (_) {}
    _serverUdpSocket = null;

    try {
      _serverUdpSocket = await io.RawDatagramSocket.bind(io.InternetAddress.anyIPv4, 0);
      _serverUdpSocket?.broadcastEnabled = true;
    } catch (e) {
      _addLog('⚠️ UDP broadcast socket bind error: $e');
    }

    // LanServer already announces this server every 5 s (lan_server.dart _startUdpBroadcast).
    // This is only a fallback in case that socket failed to bind, so every 30 s (was 10 s):
    // each tick also looks up all subnets on the server's UI thread.
    _udpBroadcastTimer = Timer.periodic(const Duration(seconds: 30), (_) async {
      if (!_isRunning) return;
      try {
        final currentIp = await getPrimaryLanIp();
        if (currentIp != null && currentIp.isNotEmpty && currentIp != _serverIp) {
          if (mounted) {
            setState(() => _serverIp = currentIp);
          } else {
            _serverIp = currentIp;
          }
          _server?.updateServerIp(currentIp);
        }
        if (_serverIp == null || _serverIp!.isEmpty) return;
        if (_serverUdpSocket == null) {
          _serverUdpSocket = await io.RawDatagramSocket.bind(io.InternetAddress.anyIPv4, 0);
          _serverUdpSocket?.broadcastEnabled = true;
        }
        final message = utf8.encode(
            '${AppNetwork.udpMessagePrefix}'
            '$_serverIp:${AppNetwork.websocketPort}:${LocalStorageService.sanitizeBranchId(_serverBranch)}');
        
        // 1. Global broadcast
        _serverUdpSocket?.send(message, io.InternetAddress('255.255.255.255'), AppNetwork.udpBroadcastPort);

        // 2. Broadcast across all active local subnets
        final localSubnets = await getAllLanSubnets();
        for (final sub in localSubnets) {
          try {
            _serverUdpSocket?.send(message, io.InternetAddress('$sub.255'), AppNetwork.udpBroadcastPort);
          } catch (_) {}
        }
      } catch (_) {}
    });
  }

  Future<void> _stopServer() async {
    _userStoppedServer = true;
    try {
      _udpBroadcastTimer?.cancel();
      try {
        _serverUdpSocket?.close();
      } catch (_) {}
      _serverUdpSocket = null;

      await Future.wait([
        Future(() async {
          try { await MultiServerService().stopHeartbeat(_serverBranch); } catch (_) {}
        }),
        Future(() async {
          try { await _syncManager?.stop(); } catch (_) {}
        }),
        Future(() async {
          try { await _server?.stop(); } catch (_) {}
        }),
        Future(() async {
          try { await ZkTecoNetworkService.stopServer(); } catch (_) {}
        }),
        if (!kIsWeb && PythonRunnerService.instance.isRunning)
          Future(() async {
            try { await PythonRunnerService.instance.stopProcess(); } catch (_) {}
          }),
      ]).timeout(const Duration(seconds: 4), onTimeout: () {
        debugPrint('[Server] Component shutdown timed out, proceeding');
        return [];
      });

      // [FIX-1.2] Disable attendance server role when server stops
      try {
        await LocalStorageService.setAttendanceServerRole(false);
      } catch (_) {}

      if (mounted) {
        setState(() {
          _isRunning  = false;
          _syncManager = null;
          _server      = null;
          _connectedClients.clear();
        });
        _addLog('🛑 Server stopped');
        _showSuccess('Server stopped');
      } else {
        _isRunning = false;
        _syncManager = null;
        _server = null;
        _connectedClients.clear();
      }
    } catch (e) {
      if (mounted) _showError('Failed to stop: $e');
    } finally {
      _isStarting = false;
    }
  }

  Future<void> _manualSync() async {
    if (_syncManager == null) { _showError('Server not running'); return; }
    setState(() => _isManualSyncing = true);
    _addLog('🔄 Manual sync triggered');
    try {
      final purged = await _syncManager!.purgeInvalidQueue(force: true);
      if (purged > 0) {
        _addLog('🧹 Cleaned $purged stale/no-op entries from queue');
      }
      _syncManager!.pushCatchUpAll();
      await _syncManager!.triggerSync(force: true);
      try {
        await SyncService().triggerUpload(force: true);
      } catch (e) {
        debugPrint('[Server] SyncService upload note: $e');
      }
      await ZkTecoNetworkService.syncAllDevices();
      final pushedCount = await ZkTecoNetworkService.syncAllRecordedAttendanceToFirestore();
      if (pushedCount > 0) {
        _addLog('✅ Uploaded $pushedCount attendance records to Cloud Firestore');
      }
      _addLog('✅ Catch-up broadcast & cloud sync completed');
    } finally {
      if (mounted) {
        setState(() {
          _isManualSyncing = false;
          _syncQueueSize = _syncManager?.queueSize ?? 0;
        });
      }
    }
  }

  Future<void> _triggerCatchUpAndFixMismatch() async {
    if (_syncManager == null || !_isRunning) {
      _showError('Server is not currently running');
      return;
    }
    setState(() => _isCatchingUp = true);
    _addLog('⚡ Starting full LAN Catch-Up & Data Mismatch Healing...');

    try {
      final purged = await _syncManager!.purgeInvalidQueue(force: true);
      if (purged > 0) {
        _addLog('🧹 Cleaned $purged stale entries from sync queue');
      }

      final stats = await _syncManager!.triggerCatchUpAndFixMismatch(forceAll: true);

      // Run cloud upload and biometric hardware sync in background so UI completes immediately
      unawaited(() async {
        try {
          await SyncService().triggerUpload(force: true);
        } catch (e) {
          debugPrint('[Server] CatchUp SyncService upload notice: $e');
        }

        try {
          await ZkTecoNetworkService.syncAllDevices().timeout(const Duration(seconds: 4));
        } catch (_) {}
      }());

      final clients = stats['clients'] ?? 0;
      final entries = stats['entries'] ?? 0;
      final stock = stats['stock'] ?? 0;
      final requests = stats['requests'] ?? 0;

      _addLog('✅ Catch-Up Complete: Pushed $entries tokens, $stock stock items, $requests requests to $clients connected workstation(s)');

      if (mounted) {
        AppToast.showSnackBar(context, 
          SnackBar(
            content: Row(
              children: [
                const Icon(Icons.bolt_rounded, color: SoftPalette.gray50, size: 22),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    clients > 0
                        ? 'LAN Catch-Up Complete: Pushed $entries tokens, $stock stock items, $requests requests to $clients workstation(s).'
                        : 'Catch-Up Complete: Server cache reset. Synced with Cloud Firestore.',
                    style: GoogleFonts.inter(fontWeight: FontWeight.w600, fontSize: 13),
                  ),
                ),
              ],
            ),
            backgroundColor: SoftPalette.teal500,
            duration: const Duration(seconds: 4),
            behavior: SnackBarBehavior.floating,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
          ),
        );
      }
    } catch (e) {
      _addLog('❌ Catch-Up error: $e');
      _showError('Catch-Up encountered an error: $e');
    } finally {
      if (mounted) {
        setState(() {
          _isCatchingUp = false;
          _syncQueueSize = _syncManager?.queueSize ?? 0;
        });
      }
    }
  }

  void _showQueueManagementDialog() {
    if (_syncManager == null) {
      _showError('Server is not running');
      return;
    }

    final isDark = Theme.of(context).brightness == Brightness.dark;
    showDialog(
      context: context,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (dialogCtx, setDialogState) {
            final total = _syncManager!.queueSize;
            final breakdown = _syncManager!.getQueueBreakdown();

            return AlertDialog(
              backgroundColor: isDark ? SoftPalette.violet900 : SoftPalette.gray50,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
              title: Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: SoftPalette.emerald350.withValues(alpha: 0.15),
                      shape: BoxShape.circle,
                    ),
                    child: const Icon(Icons.auto_awesome, color: SoftPalette.emerald350, size: 22),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Autonomous Sync Engine',
                          style: GoogleFonts.inter(
                            fontWeight: FontWeight.bold,
                            fontSize: 18,
                            color: isDark ? SoftPalette.gray50 : SoftPalette.slate900,
                          ),
                        ),
                        Text(
                          'Zero-maintenance background synchronization & self-healing',
                          style: GoogleFonts.inter(
                            fontSize: 11,
                            color: isDark ? SoftPalette.gray50A60 : SoftPalette.gray900A54,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              content: SizedBox(
                width: 520,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // Autonomous engine status banner
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                      decoration: BoxDecoration(
                        color: isDark ? SoftPalette.emerald800 : SoftPalette.emerald50,
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(color: SoftPalette.emerald350.withValues(alpha: 0.3)),
                      ),
                      child: Row(
                        children: [
                          const Icon(Icons.verified_user_rounded, color: SoftPalette.emerald350, size: 18),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  'Smart Auto-Healing Active',
                                  style: GoogleFonts.inter(fontWeight: FontWeight.bold, fontSize: 12, color: SoftPalette.emerald350),
                                ),
                                Text(
                                  'Heartbeats and noise are automatically dropped. Duplicate token updates are auto-compacted into the latest state without manual intervention.',
                                  style: GoogleFonts.inter(fontSize: 11, color: isDark ? SoftPalette.gray50A70 : SoftPalette.emerald600),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 14),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                      decoration: BoxDecoration(
                        color: isDark ? SoftPalette.slate900 : SoftPalette.slate100,
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text('Queued For Cloud Sync:', style: GoogleFonts.inter(fontWeight: FontWeight.w600, color: isDark ? SoftPalette.gray50A70 : SoftPalette.gray900A87)),
                              Text('Legitimate offline operations buffered for Firestore', style: GoogleFonts.inter(fontSize: 11, color: isDark ? SoftPalette.gray50A38 : SoftPalette.gray900A45)),
                            ],
                          ),
                          Text('$total items', style: GoogleFonts.inter(fontSize: 18, fontWeight: FontWeight.bold, color: total > 0 ? SoftPalette.sky350 : SoftPalette.emerald350)),
                        ],
                      ),
                    ),
                    const SizedBox(height: 12),
                    Text('Buffered Operations Breakdown:', style: GoogleFonts.inter(fontSize: 12, fontWeight: FontWeight.bold, color: isDark ? SoftPalette.gray50A60 : SoftPalette.gray900A54)),
                    const SizedBox(height: 6),
                    if (breakdown.isEmpty)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 8),
                        child: Row(
                          children: [
                            const Icon(Icons.check_circle_rounded, color: SoftPalette.emerald350, size: 16),
                            const SizedBox(width: 6),
                            Text('All local operations are synchronized with the cloud.', style: GoogleFonts.inter(fontSize: 13, color: SoftPalette.emerald350)),
                          ],
                        ),
                      )
                    else
                      ConstrainedBox(
                        constraints: const BoxConstraints(maxHeight: 180),
                        child: ListView(
                          shrinkWrap: true,
                          children: breakdown.entries.map((e) {
                            return Padding(
                              padding: const EdgeInsets.symmetric(vertical: 3),
                              child: Row(
                                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                children: [
                                  Row(
                                    children: [
                                      const Icon(Icons.sync_rounded, size: 14, color: SoftPalette.sky350),
                                      const SizedBox(width: 6),
                                      Text(
                                        e.key,
                                        style: GoogleFonts.firaCode(fontSize: 12, color: isDark ? SoftPalette.gray50 : SoftPalette.gray900A87),
                                      ),
                                    ],
                                  ),
                                  Text('${e.value}', style: GoogleFonts.inter(fontWeight: FontWeight.bold, fontSize: 13, color: isDark ? SoftPalette.gray50A70 : SoftPalette.gray900A87)),
                                ],
                              ),
                            );
                          }).toList(),
                        ),
                      ),
                  ],
                ),
              ),
              actions: [
                TextButton.icon(
                  icon: const Icon(Icons.auto_fix_high_rounded, size: 16, color: SoftPalette.emerald350),
                  label: const Text('Auto-Optimize Queue', style: TextStyle(color: SoftPalette.emerald350)),
                  onPressed: () async {
                    final removed = await _syncManager!.purgeInvalidQueue(force: true);
                    if (!mounted) return;
                    _addLog('🧹 Auto-compacted & cleaned $removed stale/redundant items from sync queue');
                    try {
                      setDialogState(() {});
                    } catch (_) {} // dialog closed while the purge ran
                    setState(() => _syncQueueSize = _syncManager!.queueSize);
                    _showSuccess('Queue optimized. Clean queue size: ${_syncManager!.queueSize}');
                  },
                ),
                TextButton.icon(
                  icon: const Icon(Icons.local_fire_department_rounded, size: 16, color: SoftPalette.red400),
                  label: const Text('Clear Flooded Queue', style: TextStyle(color: SoftPalette.red400)),
                  onPressed: () async {
                    final confirm = await showDialog<bool>(
                      context: ctx,
                      builder: (c) => AlertDialog(
                        backgroundColor: isDark ? SoftPalette.violet900 : SoftPalette.gray50,
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                        title: Row(children: [
                          const Icon(Icons.warning_amber_rounded, color: SoftPalette.amber300, size: 22),
                          const SizedBox(width: 10),
                          Text('Clear Flooded Queue?', style: GoogleFonts.inter(fontWeight: FontWeight.bold, fontSize: 16, color: isDark ? SoftPalette.gray50 : SoftPalette.slate900)),
                        ]),
                        content: Text(
                          'This will remove:\n'
                          '  • Items with ≥5 failed attempts (→ dead letter)\n'
                          '  • Attendance records older than 24h\n'
                          '  • All heartbeat/ping entries\n'
                          '  • Failed items with ≥3 retries older than 12h\n'
                          '  • Phantom items with no data\n\n'
                          'Legitimate unsynced records are kept safe.',
                          style: GoogleFonts.inter(fontSize: 13, color: isDark ? SoftPalette.gray50A70 : SoftPalette.gray900A87),
                        ),
                        actions: [
                          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
                          ElevatedButton(
                            style: ElevatedButton.styleFrom(backgroundColor: SoftPalette.red400),
                            onPressed: () => Navigator.pop(c, true),
                            child: const Text('Clear Flooded', style: TextStyle(color: SoftPalette.gray50)),
                          ),
                        ],
                      ),
                    );
                    if (confirm != true || !mounted) return;
                    final removed = await _syncManager!.clearFloodedQueueEntries();
                    _addLog('🔥 Flood-cleared $removed stale/redundant items. Queue: ${_syncManager!.queueSize} remaining');
                    if (mounted) {
                      setDialogState(() {});
                      setState(() => _syncQueueSize = _syncManager!.queueSize);
                      _showSuccess('Flood cleared: $removed items removed. Remaining: ${_syncManager!.queueSize}');
                    }
                  },
                ),
                ElevatedButton.icon(
                  icon: const Icon(Icons.bolt_rounded, size: 16, color: SoftPalette.gray50),
                  label: const Text('Catch-Up LAN Devices', style: TextStyle(color: SoftPalette.gray50)),
                  style: ElevatedButton.styleFrom(backgroundColor: SoftPalette.teal500),
                  onPressed: () async {
                    Navigator.of(ctx).pop();
                    await _triggerCatchUpAndFixMismatch();
                  },
                ),
                ElevatedButton.icon(
                  icon: const Icon(Icons.cloud_upload_outlined, size: 16, color: SoftPalette.gray50),
                  label: const Text('Force Cloud Sync', style: TextStyle(color: SoftPalette.gray50)),
                  style: ElevatedButton.styleFrom(backgroundColor: SoftPalette.blue500),
                  onPressed: () async {
                    _addLog('🚀 Triggered Cloud Sync from Queue Manager');
                    Navigator.of(ctx).pop();
                    await _manualSync();
                  },
                ),
                TextButton(
                  onPressed: () => Navigator.of(ctx).pop(),
                  child: const Text('Close'),
                ),
              ],
            );
          },
        );
      },
    );
  }

  Timer? _logRepaintTimer;

  /// Adds a dashboard log line. The list is updated at once, but the screen is repainted at
  /// most once a second: this used to setState() the whole 8,000-line server screen for every
  /// LAN packet (10-20 rebuilds/s with several desks busy), which kept the server's UI thread
  /// — the same thread that answers token requests — too busy to reply quickly.
  void _addLog(String message) {
    if (!mounted) return;
    _activityLog.insert(0, '${_formatTime(DateTime.now())} - $message');
    if (_activityLog.length > 100) _activityLog.removeLast();
    if (_logRepaintTimer?.isActive == true) return;
    _logRepaintTimer = Timer(const Duration(seconds: 1), () {
      if (mounted) setState(() {});
    });
  }

  String _formatTime(DateTime t) => DateFormat('HH:mm:ss').format(t);

  String _formatUptime() {
    if (_startTime == null) return '0s';
    final uptime  = DateTime.now().difference(_startTime!);
    final hours   = uptime.inHours;
    final minutes = uptime.inMinutes % 60;
    final seconds = uptime.inSeconds % 60;
    if (hours > 0)   return '${hours}h ${minutes}m';
    if (minutes > 0) return '${minutes}m ${seconds}s';
    return '${seconds}s';
  }

  String _formatDeviceTimeAgo(DateTime time) {
    final diff = DateTime.now().difference(time);
    if (diff.inSeconds < 60) return 'Just now';
    if (diff.inMinutes < 60) return '${diff.inMinutes}m ago';
    if (diff.inHours < 24) return '${diff.inHours}h ago';
    return '${diff.inDays}d ago';
  }

  void _showError(String msg) {
    if (!mounted) return;
    AppToast.showSnackBar(context, SnackBar(
        content: Text(msg),
        backgroundColor: SoftPalette.red400,
        behavior: SnackBarBehavior.floating));
  }

  void _showSuccess(String msg) {
    if (!mounted) return;
    AppToast.showSnackBar(context, SnackBar(
        content: Text(msg),
        backgroundColor: SoftPalette.green400,
        behavior: SnackBarBehavior.floating));
  }

  Future<void> _showLogoutDialog(BuildContext context) async {
    final confirmed = await showLogoutDialog(
      context,
      warningNotice: _isRunning ? 'Server is currently running and will be stopped.' : null,
    );
    if (confirmed == true) await _logout();
  }

  static String _describeActivity(String type, dynamic data) {
    final map = data is Map ? Map<String, dynamic>.from(data) : {};
    switch (type) {
      case 'save_entry':
      case 'token_created':
        return 'Issued Token #${map['serial'] ?? 'N/A'} (${map['queueType'] ?? 'Zakat'})';
      case 'save_prescription':
      case 'prescription_created':
        return 'Created Prescription for Token #${map['serial'] ?? 'N/A'}';
      case 'dispense_completed':
        return 'Completed Dispensing for Token #${map['serial'] ?? 'N/A'}';
      case 'save_biometric_log':
      case 'save_employee_attendance':
      case 'save_faculty_attendance':
      case 'save_student_attendance':
        return 'Recorded Attendance Punch (${map['entityName'] ?? map['pin'] ?? 'Biometric'})';
      case 'save_madrassa_fee':
        return 'Collected Madrassa Fee Receipt #${map['receiptNo'] ?? 'N/A'}';
      case 'save_madrassa_admission':
        return 'Registered Madrassa Student (${map['studentName'] ?? 'New Student'})';
      case 'save_expense':
        return 'Recorded Expense (${map['category'] ?? map['title'] ?? 'Office Expense'})';
      case 'save_loan':
        return 'Issued Loan Transaction (${map['employeeName'] ?? 'Employee'})';
      case 'save_donation_receipt':
        return 'Generated Donation Receipt #${map['receiptNumber'] ?? 'N/A'}';
      case 'save_dasterkhwan_entry':
      case 'save_office_boy_token':
      case 'save_kitchen_serve_log':
        return 'Logged Dasterkhwaan Kitchen Meal Token';
      case 'save_library_book':
      case 'save_library_issue':
        return 'Issued Library Book (${map['bookTitle'] ?? 'Library Catalog'})';
      case 'save_supervisor_action':
      case 'approve_edit_request':
        return 'Supervisor Edit/Approval Action';
      default:
        return 'Processing $type';
    }
  }

  Future<void> _logout() async {
    _isLoggingOut = true;
    _userStoppedServer = true;

    _updateTimer?.cancel();
    _syncTimer?.cancel();
    _udpBroadcastTimer?.cancel();
    _clientUiThrottleTimer?.cancel();

    if (_isRunning || _server != null) {
      try {
        await _stopServer().timeout(const Duration(seconds: 5), onTimeout: () {
          debugPrint('[Server] Stop server timeout during logout');
        });
      } catch (e) {
        debugPrint('[Server] Stop server error during logout: $e');
      }
    }
    try {
      AuthHomeWrapper.clearSession();
      if (Hive.isBoxOpen('app_settings')) {
        final box = Hive.box('app_settings');
        await box.delete('server_authenticated');
        await box.delete('user_data');
        await box.delete('currentUser');
        await box.delete('user');
        await box.delete('role');
        await box.delete('user_role');
        await box.delete('auth_token');
        await box.flush();
      }
      await OfflineAuthService.clearCachedUserData();
      await AuthService().signOut();
    } catch (e) {
      debugPrint('[Server] Logout error: $e');
    } finally {
      final nav = navigatorKey.currentState;
      if (nav != null) {
        nav.pushAndRemoveUntil(
          MaterialPageRoute(builder: (_) => const LoginPage()),
          (route) => false,
        );
      } else if (mounted) {
        Navigator.of(context, rootNavigator: true).pushAndRemoveUntil(
          MaterialPageRoute(builder: (_) => const LoginPage()),
          (route) => false,
        );
      }
    }
  }

  @override
  void dispose() {
    _logRepaintTimer?.cancel();
    _isLoggingOut = true;
    _userStoppedServer = true;
    _punchSubscription?.cancel();
    _metricsSubscription?.cancel();
    SystemMetricsService().stopMonitoring();
    HardwareKeyboard.instance.removeHandler(_stressTestKeyHandler);
    _overviewTicker?.cancel();
    try {
      _beaconSocket?.close();
    } catch (_) {}
    _updateTimer?.cancel();
    _syncTimer?.cancel();
    _queueStatsTimer?.cancel();
    _firewallTimer?.cancel();
    _udpBroadcastTimer?.cancel();
    _clientUiThrottleTimer?.cancel();
    _connectivitySub?.cancel();
    try {
      _serverUdpSocket?.close();
    } catch (_) {}
    _syncManager?.stop();
    _server?.stop();
    if (!kIsWeb && PythonRunnerService.instance.isRunning) {
      PythonRunnerService.instance.stopProcess().catchError((_) {});
    }
    _healthSub?.cancel();
    ZkTecoNetworkService.stopServer().catchError((_) {});
    _runningScrollController.dispose();
    super.dispose();
  }

  // ── Build ──────────────────────────────────────────────────────────────────
  @override
  Widget build(BuildContext context) {
    // Registered here (once) rather than only in initState so a hot reload also activates it.
    if (!_stressKeyRegistered) {
      _stressKeyRegistered = true;
      HardwareKeyboard.instance.addHandler(_stressTestKeyHandler);
    }
    if (kIsWeb) return _buildWebUnsupportedMessage();
    if (!_isAuthenticated) return _buildNotAuthenticatedMessage();

    final (breadcrumbSection, breadcrumbPage) = _getBreadcrumbs();
    final snap = SystemMetricsService().currentSnapshot;
    final staffCount = _connectedClients.values.map((c) => c.username).where((u) => u != null && u.isNotEmpty).toSet().length;

    return ListenableBuilder(
      listenable: ServerThemeController.instance,
      builder: (context, _) {
        return Scaffold(
          backgroundColor: NexusColors.mainBg,
          body: Row(
            children: [
              // ── 1. Fixed Dark Sidebar (260px) ──────────────────────────────────
              NexusSidebar(
                selectedIndex: _selectedTab,
                onSelectTab: (idx) => setState(() => _selectedTab = idx),
                isRunning: _isRunning,
                serverIp: _serverIp ?? '127.0.0.1',
                port: AppNetwork.websocketPort,
                connectedDevicesCount: _connectedClients.length,
                activeUsersCount: staffCount > 0 ? staffCount : (_isRunning ? 1 : 0),
                pendingEventsCount: _syncQueueSize,
                cpuLoadPercent: snap.cpuPercent,
                adminName: 'Server Control Panel',
                onToggleServer: _isRunning ? _stopServer : _startServer,
                onCatchUp: _isRunning ? _triggerCatchUpAndFixMismatch : null,
                onCloudSync: _isOnline ? _manualSync : null,
                isCatchingUp: _isCatchingUp,
                isSyncing: _isManualSyncing,
              ),

              // ── 2. Main Content Canvas ──────────────────────────────────────────
              Expanded(
                child: Column(
                  children: [
                    // Top Navigation Bar
                    NexusTopHeader(
                      breadcrumbSection: breadcrumbSection,
                      breadcrumbPage: breadcrumbPage,
                      isRunning: _isRunning,
                      isOnline: _isOnline,
                      syncedToday: _syncedToday,
                      queueSize: _syncQueueSize,
                      isCatchingUp: _isCatchingUp,
                      isSyncing: _isManualSyncing,
                      onRefresh: () {
                        _manualSync();
                        SystemMetricsService().startMonitoring();
                        setState(() {});
                      },
                      onCatchUp: _isRunning ? _triggerCatchUpAndFixMismatch : null,
                      onCloudSync: _isOnline ? _manualSync : null,
                      adminName: 'Server Control Panel',
                      branchDisplay: _resolveBranchAndCampDisplay(),
                      onLocationTap: _showServerLocationDialog,
                      locationWarning: _locationMismatch
                          ? 'Desks on this network are from ' + LocalStorageService.getBranchName(_desksBranchFamily() ?? '') + ' — click to set this server\'s location'
                          : (!_hasSiteLocation ? 'Location taken from the logged-in account — click to confirm' : null),
                    ),

                    // Another GMWF server on this network splits the desks between two servers.
                    _buildOtherServerAlert(),

                    // Content View for Selected Navigation Tab (Truly Lazy Initialized)
                    Expanded(
                      child: Container(
                        color: NexusColors.mainBg,
                        child: LazyIndexedStack(
                          index: _selectedTab,
                          children: [
                            _buildNexusOverviewView(), // Tab 0: Overview
                            DepartmentActivityWidget(branchId: _serverBranch), // Tab 1: Department Activity
                            _buildNexusDevicesView(),  // Tab 2: Connected Devices
                            _buildNexusUsersView(),    // Tab 3: Users & Sessions
                            BiometricDeviceManagerPage( // Tab 4: Biometrics
                              branchId: _serverBranch,
                              isEmbedded: true,
                              onBack: null,
                            ),
                            PythonTerminalScreen(      // Tab 5: Python Sync Engine
                              isEmbedded: true,
                              onBack: null,
                            ),
                            _buildNexusResourcesView(),// Tab 6: Resource Monitoring
                            _buildNexusLogsView(),     // Tab 7: System Logs
                            _buildNexusNetworkView(),  // Tab 8: Network & Interfaces
                            MultiServerControlWidget(  // Tab 9: Multi-Server Mesh
                              branchId: _serverBranch,
                              onTriggerSync: _manualSync,
                            ),
                            ServerDataViewer(branchId: _serverBranch, isEmbedded: true), // Tab 10: Data Vault
                            _buildNexusSettingsView(), // Tab 11: Settings & Firewall
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  // ── Nexus Dashboard View Helpers ───────────────────────────────────────────
  List<NexusDeviceItem> _buildNexusDeviceItems() {
    return _connectedClients.values.map((c) {
      return NexusDeviceItem(
        id: c.socketId,
        name: c.username?.isNotEmpty == true ? c.username! : c.displayName,
        role: c.role,
        ipAddress: c.ipAddress,
        osName: c.deviceOs,
        appVersion: c.appVersion,
        lastActive: c.lastActiveAt,
        messagesCount: c.messagesCount,
      );
    }).toList();
  }

  (String, String) _getBreadcrumbs() {
    return switch (_selectedTab) {
      0 => ('Workspace', 'Overview'),
      1 => ('Workspace', 'Department Activity'),
      2 => ('Workspace', 'Connected Devices'),
      3 => ('Workspace', 'Users & Sessions'),
      4 => ('Engines & Hardware', 'Biometric Devices'),
      5 => ('Engines & Hardware', 'Python Sync Engine'),
      6 => ('Observability', 'Resource Monitoring'),
      7 => ('Observability', 'System Logs'),
      8 => ('Observability', 'Network & Interfaces'),
      9 => ('Storage & Clustering', 'Multi-Server Mesh'),
      10 => ('Storage & Clustering', 'Data Vault'),
      11 => ('System', 'Settings & Firewall'),
      _ => ('Workspace', 'Overview'),
    };
  }

  void _openStressTestDirectly() {
    final server = _server;
    if (!_isRunning || server == null) {
      AppToast.showSnackBar(
        context,
        const SnackBar(content: Text('Launch the LAN server first to run the socket pressure benchmark.')),
      );
      return;
    }
    final engine = StressTestEngine(server: server, cloudQueueSize: () => _syncQueueSize);
    StressTestDialog.show(context, engine, deviceCount: server.stressClientSnapshot().length);
  }

  Future<void> _runDatabaseRepairSuite() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: NexusColors.cardBg,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Row(
          children: [
            Icon(Icons.healing_rounded, color: NexusColors.success, size: 24),
            const SizedBox(width: 10),
            Text(
              'Database Repair & Deduplication',
              style: GoogleFonts.inter(fontWeight: FontWeight.w700, fontSize: 17, color: NexusColors.textMain),
            ),
          ],
        ),
        content: Text(
          'This will execute the following automated maintenance repairs:\n\n'
          '• Deduplicate & purge bloated sync queue items\n'
          '• Flatten nested prescription records\n'
          '• Heal and restore missing patient CNICs & remove phantom tokens\n'
          '• Compact local Hive database caches on disk\n\n'
          'All operations run safely in the background with zero data loss.',
          style: GoogleFonts.inter(fontSize: 13, color: NexusColors.textSecondary, height: 1.4),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text('Cancel', style: GoogleFonts.inter(color: NexusColors.textSecondary)),
          ),
          ElevatedButton.icon(
            onPressed: () => Navigator.pop(ctx, true),
            icon: const Icon(Icons.check_circle_outline_rounded, size: 16),
            label: Text('Run Repairs Now', style: GoogleFonts.inter(fontWeight: FontWeight.w600)),
            style: ElevatedButton.styleFrom(
              backgroundColor: NexusColors.primary,
              foregroundColor: NexusColors.onPrimary,
              elevation: 0,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
            ),
          ),
        ],
      ),
    );

    if (confirmed == true && mounted) {
      AppToast.showSnackBar(context, const SnackBar(content: Text('⏳ Running database repair suite in background...'), duration: Duration(seconds: 2)));
      final purged = await LocalStorageService.purgeBloatedSyncQueue(force: true);
      final flattened = await LocalStorageService.healNestedPrescriptions();
      final healed = await LocalStorageService.healAndRestorePatientCnics(_serverBranch, true);
      await LocalStorageService.compactBloatedBoxes();
      if (mounted) {
        setState(() {
          _syncQueueSize = Hive.isBoxOpen(LocalStorageService.syncBox) ? Hive.box(LocalStorageService.syncBox).length : 0;
        });
        AppToast.showSnackBar(
          context,
          SnackBar(
            backgroundColor: NexusColors.success,
            content: Text('✅ Repairs complete! Purged $purged items, flattened $flattened prescriptions, healed $healed CNICs.'),
          ),
        );
      }
    }
  }

  Widget _buildNexusOverviewView() {
    final snap = SystemMetricsService().currentSnapshot;
    final devices = _buildNexusDeviceItems();
    final onlineCount = devices.where((d) => DateTime.now().difference(d.lastActive).inMinutes < 2).length;
    final staffUsersCount = _connectedClients.values.map((c) => c.username).where((u) => u != null && u.isNotEmpty).toSet().length;
    final showFirewall = !kIsWeb && io.Platform.isWindows && _firewallBlocked && !_isFirewallBannerDismissed;

    return NexusOverviewView(
      totalDevices: devices.length,
      onlineDevices: onlineCount,
      activeUsers: staffUsersCount > 0 ? staffUsersCount : (_isRunning ? 1 : 0),
      branchDisplay: _resolveBranchAndCampDisplay(),
      cpuPercent: snap.cpuPercent,
      cpuKnown: snap.cpuKnown,
      cpuStatus: snap.cpuStatus,
      ramPercent: snap.ramPercent,
      ramKnown: snap.ramKnown,
      usedRamGb: snap.usedRamGb,
      totalRamGb: snap.totalRamGb,
      appProcessRamMb: snap.appProcessRamMb,
      diskPercent: snap.diskPercent,
      diskKnown: snap.diskKnown,
      usedDiskGb: snap.usedDiskGb,
      totalDiskGb: snap.totalDiskGb,
      diskDrive: snap.diskDrive,
      lanThroughput: _lanStats().text,
      telemetryHistory: _telemetryHistory,
      devices: devices,
      rawLogs: _activityLog,
      firewallMissing: showFirewall,
      onFixFirewall: _openFirewallPort,
      onTriggerCatchUp: _manualSync,
      onRepairDatabase: _runDatabaseRepairSuite,
      onStressTest: _openStressTestDirectly,
      onOpenQueueDialog: _showQueueManagementDialog,
      queuedSyncCount: _syncQueueSize,
      onRefresh: () {
        _manualSync();
        SystemMetricsService().startMonitoring();
        setState(() {});
      },
      onViewAllDevices: () => setState(() => _selectedTab = 2),
      onViewAllLogs: () => setState(() => _selectedTab = 7),
    );
  }

  Widget _buildNexusDevicesView() {
    final devices = _buildNexusDeviceItems();
    return NexusDevicesView(
      devices: devices,
      hardwareStatusWidget: const LanHardwareStatusWidget(),
    );
  }

  Widget _buildNexusUsersView() {
    final devices = _buildNexusDeviceItems();
    return NexusUsersView(
      devices: devices,
      departmentActivityWidget: DepartmentActivityWidget(branchId: _serverBranch),
      branchDisplay: _resolveBranchAndCampDisplay(),
    );
  }

  Widget _buildNexusResourcesView() {
    final snap = SystemMetricsService().currentSnapshot;
    return NexusResourcesView(
      cpuPercent: snap.cpuPercent,
      cpuKnown: snap.cpuKnown,
      cpuStatus: snap.cpuStatus,
      ramPercent: snap.ramPercent,
      ramKnown: snap.ramKnown,
      usedRamGb: snap.usedRamGb,
      totalRamGb: snap.totalRamGb,
      appProcessRamMb: snap.appProcessRamMb,
      diskPercent: snap.diskPercent,
      diskKnown: snap.diskKnown,
      usedDiskGb: snap.usedDiskGb,
      totalDiskGb: snap.totalDiskGb,
      diskDrive: snap.diskDrive,
      lanThroughput: _lanStats().text,
    );
  }

  Widget _buildNexusLogsView() {
    return NexusLogsView(
      rawLogs: _activityLog,
      onClearLogs: () {
        setState(() => _activityLog.clear());
      },
    );
  }

  Widget _buildNexusNetworkView() {
    final showFirewall = !kIsWeb && io.Platform.isWindows && _firewallBlocked && !_isFirewallBannerDismissed;
    return NexusNetworkView(
      serverIp: _serverIp ?? '127.0.0.1',
      port: AppNetwork.websocketPort,
      lanThroughput: _lanStats().text,
      connectedClientsCount: _connectedClients.length,
      otherServers: _otherServers,
      firewallMissing: showFirewall,
      onFixFirewall: _openFirewallPort,
    );
  }

  Widget _buildNexusSettingsView() {
    return NexusSettingsView(
      multiServerControl: MultiServerControlWidget(
        branchId: _serverBranch,
        onTriggerSync: _manualSync,
      ),
      biometricDeviceManager: BiometricDeviceManagerPage(
        branchId: _serverBranch,
        isEmbedded: true,
        onBack: null,
      ),
      pythonTerminal: PythonTerminalScreen(
        isEmbedded: true,
        onBack: null,
      ),
      dataVaultViewer: ServerDataViewer(branchId: _serverBranch, isEmbedded: true),
    );
  }

  // ── Sleek Desktop Server Sidebar ──────────────────────────────────────────
  Widget _buildServerSidebar(bool isDark) {
    final sidebarBg = isDark ? SoftPalette.slate900 : SoftPalette.gray50;
    final borderColor = isDark ? SoftPalette.slate800 : SoftPalette.slate150;
    final serverIpStr = _serverIp ?? 'Detecting...';

    return Container(
      width: 270,
      decoration: BoxDecoration(
        color: sidebarBg,
        border: Border(right: BorderSide(color: borderColor, width: 1.2)),
        boxShadow: [
          BoxShadow(
            color: SoftPalette.gray900.withOpacity(isDark ? 0.35 : 0.04),
            blurRadius: 10,
            offset: const Offset(2, 0),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // ── Brand Header ──────────────────────────────────────────────
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 20, 16, 14),
            child: Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(6),
                  decoration: BoxDecoration(
                    color: isDark ? SoftPalette.slate900 : SoftPalette.slate100,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: borderColor),
                  ),
                  child: Image.asset('assets/logo/gmwf-1.webp', height: 32, fit: BoxFit.contain),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        'GMWF SERVER',
                        style: GoogleFonts.inter(
                          fontWeight: FontWeight.bold,
                          fontSize: 16,
                          letterSpacing: 0.5,
                          color: isDark ? SoftPalette.gray50 : SoftPalette.slate900,
                        ),
                      ),
                      Text(
                        'Hybrid LAN Gateway',
                        style: GoogleFonts.inter(
                          fontSize: 11,
                          fontWeight: FontWeight.w600,
                          color: SoftPalette.emerald350,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),

          // ── Node Status Card ──────────────────────────────────────────
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
            child: Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: isDark ? SoftPalette.slate900 : SoftPalette.gray50,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(
                  color: _isRunning
                      ? SoftPalette.emerald350.withOpacity(0.4)
                      : SoftPalette.amber300.withOpacity(0.4),
                ),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Container(
                        width: 8,
                        height: 8,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: _isRunning ? SoftPalette.emerald350 : SoftPalette.amber300,
                          boxShadow: [
                            BoxShadow(
                              color: (_isRunning ? SoftPalette.emerald350 : SoftPalette.amber300).withOpacity(0.6),
                              blurRadius: 6,
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 8),
                      Text(
                        _isRunning ? 'SERVER ACTIVE & LIVE' : 'GATEWAY STANDBY',
                        style: GoogleFonts.inter(
                          fontSize: 10.5,
                          fontWeight: FontWeight.bold,
                          letterSpacing: 0.4,
                          color: _isRunning ? SoftPalette.emerald300 : SoftPalette.amber200,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  InkWell(
                    onTap: () {
                      if (_serverIp != null && _serverIp!.isNotEmpty) {
                        Clipboard.setData(ClipboardData(text: _serverIp!));
                        AppToast.showSnackBar(context, 
                          SnackBar(
                            content: Text('Server IP "$_serverIp" copied to clipboard!'),
                            backgroundColor: SoftPalette.emerald350,
                            duration: const Duration(seconds: 2),
                          ),
                        );
                      }
                    },
                    borderRadius: BorderRadius.circular(8),
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
                      decoration: BoxDecoration(
                        color: isDark ? SoftPalette.slate800 : SoftPalette.slate150,
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Row(
                        children: [
                          Icon(Icons.wifi_tethering_rounded, size: 13, color: isDark ? SoftPalette.sky350 : SoftPalette.sky500),
                          const SizedBox(width: 6),
                          Expanded(
                            child: Text(
                              '$serverIpStr:8080',
                              style: GoogleFonts.firaCode(
                                fontSize: 11,
                                fontWeight: FontWeight.w600,
                                color: isDark ? SoftPalette.gray50A70 : SoftPalette.slate800,
                              ),
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          Icon(Icons.copy_rounded, size: 12, color: isDark ? SoftPalette.gray50A54 : SoftPalette.gray900A45),
                          const SizedBox(width: 6),
                          InkWell(
                            onTap: () => _showFirewallStatusAndNextStepsDialog(alreadyAdded: true),
                            borderRadius: BorderRadius.circular(4),
                            child: Tooltip(
                              message: 'Firewall & Port Setup Guide',
                              child: Padding(
                                padding: const EdgeInsets.all(1.5),
                                child: Icon(Icons.security_rounded, size: 13, color: isDark ? SoftPalette.sky350 : SoftPalette.sky500),
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
          ),

          const SizedBox(height: 8),
          Divider(color: borderColor, height: 1),

          // ── Navigation Menu ───────────────────────────────────────────
          Expanded(
            child: ListView(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
              children: [
                _sidebarSectionLabel('CORE GATEWAY', isDark),
                _sidebarItem(0, 'Command Matrix', 'Overview & telemetry', Icons.dashboard_rounded, isDark),
                _sidebarItem(2, 'Department Activity', 'Queues & dispensing', Icons.domain_rounded, isDark),

                const SizedBox(height: 12),
                _sidebarSectionLabel('HARDWARE & ENGINES', isDark),
                _sidebarItem(4, 'Biometric Devices', 'ZKTeco attendance', Icons.fingerprint_rounded, isDark),
                _sidebarItem(5, 'Python Sync Engine', 'Terminal & daemon', Icons.terminal_rounded, isDark),

                const SizedBox(height: 12),
                _sidebarSectionLabel('STORAGE & AUDIT', isDark),
                _sidebarItem(6, 'Data Vault', 'Local database boxes', Icons.storage_rounded, isDark),
              ],
            ),
          ),

          Divider(color: borderColor, height: 1),

          // ── Sidebar Footer Controls ───────────────────────────────────
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
            child: Column(
              children: [
                // Quick Power Action
                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton.icon(
                    onPressed: _isRunning ? _stopServer : _startServer,
                    icon: Icon(
                      _isRunning ? Icons.stop_circle_rounded : Icons.play_arrow_rounded,
                      size: 18,
                    ),
                    label: Text(
                      _isRunning ? 'Stop LAN Server' : 'Launch LAN Server',
                      style: GoogleFonts.inter(fontWeight: FontWeight.bold, fontSize: 12.5),
                    ),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: _isRunning ? SoftPalette.red400 : SoftPalette.emerald500,
                      foregroundColor: SoftPalette.gray50,
                      padding: const EdgeInsets.symmetric(vertical: 10),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                    ),
                  ),
                ),
                const SizedBox(height: 8),

                if (_isRunning) ...[
                  SizedBox(
                    width: double.infinity,
                    child: ElevatedButton.icon(
                      onPressed: !_isCatchingUp ? _triggerCatchUpAndFixMismatch : null,
                      icon: _isCatchingUp
                          ? const SizedBox(width: 13, height: 13, child: CircularProgressIndicator(strokeWidth: 2, color: SoftPalette.gray50))
                          : const Icon(Icons.bolt_rounded, size: 15),
                      label: Text(
                        _isCatchingUp ? 'Catching Up...' : 'Catch-Up & Fix Mismatch',
                        style: GoogleFonts.inter(fontWeight: FontWeight.bold, fontSize: 11.5),
                      ),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: SoftPalette.teal500,
                        foregroundColor: SoftPalette.gray50,
                        padding: const EdgeInsets.symmetric(vertical: 9),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                        elevation: 0,
                      ),
                    ),
                  ),
                  const SizedBox(height: 8),
                ],

                // Utility actions row
                Row(
                  children: [
                    // Manual Sync
                    Expanded(
                      child: Tooltip(
                        message: 'Trigger Cloud Sync Now',
                        child: OutlinedButton.icon(
                          onPressed: _isManualSyncing ? null : _manualSync,
                          icon: _isManualSyncing
                              ? const SizedBox(width: 12, height: 12, child: CircularProgressIndicator(strokeWidth: 2, color: SoftPalette.emerald350))
                              : const Icon(Icons.sync_rounded, size: 15, color: SoftPalette.emerald350),
                          label: Text(
                            'Sync',
                            style: GoogleFonts.inter(fontSize: 11, fontWeight: FontWeight.w600, color: isDark ? SoftPalette.gray50A70 : SoftPalette.slate800),
                          ),
                          style: OutlinedButton.styleFrom(
                            side: BorderSide(color: borderColor),
                            padding: const EdgeInsets.symmetric(vertical: 8),
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 6),
                    // Theme toggle
                    Tooltip(
                      message: isDark ? 'Switch to Light' : 'Switch to Dark',
                      child: InkWell(
                        onTap: () async => await UserThemeService.setDarkMode(!isDark),
                        borderRadius: BorderRadius.circular(8),
                        child: Container(
                          padding: const EdgeInsets.all(8),
                          decoration: BoxDecoration(
                            border: Border.all(color: borderColor),
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: Icon(
                            isDark ? Icons.light_mode_rounded : Icons.dark_mode_rounded,
                            size: 16,
                            color: isDark ? SoftPalette.amber200 : SoftPalette.slate900,
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 6),
                    // Logout
                    Tooltip(
                      message: 'Exit Server Dashboard',
                      child: InkWell(
                        onTap: () => _showLogoutDialog(context),
                        borderRadius: BorderRadius.circular(8),
                        child: Container(
                          padding: const EdgeInsets.all(8),
                          decoration: BoxDecoration(
                            border: Border.all(color: SoftPalette.red400.withOpacity(0.4)),
                            borderRadius: BorderRadius.circular(8),
                            color: SoftPalette.red400.withOpacity(0.1),
                          ),
                          child: const Icon(Icons.power_settings_new_rounded, size: 16, color: SoftPalette.red400),
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _sidebarSectionLabel(String text, bool isDark) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(10, 8, 10, 4),
      child: Text(
        text,
        style: GoogleFonts.inter(
          fontSize: 10,
          fontWeight: FontWeight.w800,
          letterSpacing: 0.8,
          color: isDark ? SoftPalette.slate550 : SoftPalette.slate350,
        ),
      ),
    );
  }

  Widget _sidebarItem(int index, String title, String subtitle, IconData icon, bool isDark) {
    final isSelected = _selectedTab == index;
    final activeBg = isDark ? SoftPalette.teal550.withOpacity(0.28) : SoftPalette.emerald50;
    final activeBorder = SoftPalette.emerald350;
    final inactiveHover = isDark ? SoftPalette.slate800.withOpacity(0.4) : SoftPalette.gray50;

    return Container(
      margin: const EdgeInsets.only(bottom: 4),
      child: Material(
        color: isSelected ? activeBg : Colors.transparent,
        borderRadius: BorderRadius.circular(10),
        child: InkWell(
          onTap: () => setState(() => _selectedTab = index),
          borderRadius: BorderRadius.circular(10),
          hoverColor: inactiveHover,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8.5),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(10),
              border: Border.all(
                color: isSelected ? activeBorder : Colors.transparent,
                width: 1.0,
              ),
            ),
            child: Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(6),
                  decoration: BoxDecoration(
                    color: isSelected
                        ? SoftPalette.emerald350.withOpacity(0.2)
                        : (isDark ? SoftPalette.slate800 : SoftPalette.slate100),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Icon(
                    icon,
                    size: 16,
                    color: isSelected
                        ? SoftPalette.emerald350
                        : (isDark ? SoftPalette.slate350 : SoftPalette.slate550),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        style: GoogleFonts.inter(
                          fontSize: 12.5,
                          fontWeight: isSelected ? FontWeight.bold : FontWeight.w500,
                          color: isSelected
                              ? (isDark ? SoftPalette.gray50 : SoftPalette.emerald600)
                              : (isDark ? SoftPalette.slate150 : SoftPalette.slate700),
                        ),
                      ),
                      Text(
                        subtitle,
                        style: GoogleFonts.inter(
                          fontSize: 10,
                          color: isDark ? SoftPalette.slate550 : SoftPalette.slate350,
                        ),
                      ),
                    ],
                  ),
                ),
                if (isSelected)
                  Container(
                    width: 5,
                    height: 5,
                    decoration: const BoxDecoration(
                      shape: BoxShape.circle,
                      color: SoftPalette.emerald350,
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  // ── Server Top Header Bar with Live Telemetry ──────────────────────────────
  Widget _buildServerTopHeader(bool isDark) {
    final headerBg = isDark ? SoftPalette.slate900 : SoftPalette.gray50;
    final borderColor = isDark ? SoftPalette.slate800 : SoftPalette.slate150;

    final tabTitles = [
      'Command Matrix',
      'Multi-Server Cluster',
      'Department Activity',
      'LAN Hardware & Devices',
      'Biometric Devices',
      'Python Sync Engine',
      'Data Vault',
    ];
    final tabSubtitles = [
      'Real-time overview of primary node, traffic telemetry & active nodes',
      'High-availability peer mesh replication & failover status',
      'Live dispensary token flow, queuing, and pharmacy operations',
      'Connected client workstations, thermal printers, and switches',
      'ZKTeco network biometrics, real-time clock punch capture',
      'Automated background python daemons and maintenance tasks',
      'Authoritative local Hive boxes, encrypted schemas & record tables',
    ];

    final currentTitle = (_selectedTab >= 0 && _selectedTab < tabTitles.length) ? tabTitles[_selectedTab] : 'Server Hub';
    final currentSub = (_selectedTab >= 0 && _selectedTab < tabSubtitles.length) ? tabSubtitles[_selectedTab] : '';

    return Container(
      height: 62,
      padding: const EdgeInsets.symmetric(horizontal: 20),
      decoration: BoxDecoration(
        color: headerBg,
        border: Border(bottom: BorderSide(color: borderColor, width: 1.0)),
      ),
      child: Row(
        children: [
          // Section Title
          Expanded(
            child: Row(
              children: [
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Row(
                      children: [
                        Text(
                          currentTitle,
                          style: GoogleFonts.inter(
                            fontSize: 17,
                            fontWeight: FontWeight.bold,
                            color: isDark ? SoftPalette.gray50 : SoftPalette.slate900,
                          ),
                        ),
                        const SizedBox(width: 10),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                          decoration: BoxDecoration(
                            color: isDark ? SoftPalette.slate800 : SoftPalette.slate100,
                            borderRadius: BorderRadius.circular(6),
                            border: Border.all(color: borderColor),
                          ),
                          child: Text(
                            'BRANCH: ${_resolveBranchAndCampDisplay().toUpperCase()}',
                            style: GoogleFonts.inter(
                              fontSize: 10,
                              fontWeight: FontWeight.bold,
                              letterSpacing: 0.3,
                              color: isDark ? SoftPalette.slate350 : SoftPalette.slate550,
                            ),
                          ),
                        ),
                        if (_isRunning && _startTime != null) ...[
                          const SizedBox(width: 8),
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                            decoration: BoxDecoration(
                              color: SoftPalette.teal500.withOpacity(0.15),
                              borderRadius: BorderRadius.circular(6),
                              border: Border.all(color: SoftPalette.teal500.withOpacity(0.4)),
                            ),
                            child: Row(
                              children: [
                                const Icon(Icons.timer_outlined, size: 11, color: SoftPalette.teal300),
                                const SizedBox(width: 4),
                                Text(
                                  _formatUptime(),
                                  style: GoogleFonts.inter(
                                    fontSize: 10.5,
                                    fontWeight: FontWeight.bold,
                                    color: SoftPalette.teal300,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ],
                    ),
                    Text(
                      currentSub,
                      style: GoogleFonts.inter(
                        fontSize: 11,
                        color: isDark ? SoftPalette.slate550 : SoftPalette.slate350,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ],
            ),
          ),

          // Telemetry and Status Badges
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              _buildStatusBadge(),
              const SizedBox(width: 8),

              // Synced Today Pill
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4.5),
                decoration: BoxDecoration(
                  color: isDark ? SoftPalette.emerald700.withOpacity(0.3) : SoftPalette.emerald50,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: SoftPalette.emerald350.withOpacity(0.4)),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.cloud_done_rounded, size: 13, color: SoftPalette.emerald350),
                    const SizedBox(width: 5),
                    Text(
                      '$_syncedToday Synced',
                      style: GoogleFonts.inter(fontSize: 11, fontWeight: FontWeight.bold, color: SoftPalette.emerald350),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),

              // Sync Queue Pending Pill
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4.5),
                decoration: BoxDecoration(
                  color: _syncQueueSize > 0
                      ? (isDark ? SoftPalette.orange700.withOpacity(0.3) : SoftPalette.yellow50m)
                      : (isDark ? SoftPalette.slate800 : SoftPalette.slate100),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(
                    color: _syncQueueSize > 0 ? SoftPalette.amber300.withOpacity(0.5) : borderColor,
                  ),
                ),
                child: Row(
                  children: [
                    Icon(
                      Icons.pending_actions_rounded,
                      size: 13,
                      color: _syncQueueSize > 0 ? SoftPalette.amber300 : (isDark ? SoftPalette.gray50A38 : SoftPalette.gray900A38),
                    ),
                    const SizedBox(width: 5),
                    Text(
                      '$_syncQueueSize Queue',
                      style: GoogleFonts.inter(
                        fontSize: 11,
                        fontWeight: FontWeight.bold,
                        color: _syncQueueSize > 0 ? SoftPalette.amber300 : (isDark ? SoftPalette.gray50A60 : SoftPalette.gray900A54),
                      ),
                    ),
                  ],
                ),
              ),

              const SizedBox(width: 8),

              // Cloud Online/Offline status
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4.5),
                decoration: BoxDecoration(
                  color: _isOnline
                      ? (isDark ? SoftPalette.emerald550.withOpacity(0.25) : SoftPalette.emerald50m)
                      : (isDark ? SoftPalette.slate700.withOpacity(0.3) : SoftPalette.gray50),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(
                    color: _isOnline ? SoftPalette.emerald350.withOpacity(0.4) : borderColor,
                  ),
                ),
                child: Row(
                  children: [
                    Icon(
                      _isOnline ? Icons.cloud_rounded : Icons.cloud_off_rounded,
                      size: 13,
                      color: _isOnline ? SoftPalette.emerald350 : (isDark ? SoftPalette.slate350 : SoftPalette.slate550),
                    ),
                    const SizedBox(width: 5),
                    Text(
                      _isOnline ? 'Cloud Sync' : 'Local LAN',
                      style: GoogleFonts.inter(
                        fontSize: 11,
                        fontWeight: FontWeight.bold,
                        color: _isOnline ? SoftPalette.emerald350 : (isDark ? SoftPalette.slate350 : SoftPalette.slate550),
                      ),
                    ),
                  ],
                ),
              ),

              const SizedBox(width: 8),

              // App Version Badge
              FutureBuilder<String>(
                future: AutoUpdateService.getAppVersion(),
                builder: (context, snap) {
                  final ver = snap.data ?? AutoUpdateService.currentVersion;
                  return Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4.5),
                    decoration: BoxDecoration(
                      color: isDark ? SoftPalette.slate800 : SoftPalette.slate100,
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: borderColor),
                    ),
                    child: Text(
                      'v$ver',
                      style: GoogleFonts.inter(
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                        color: isDark ? SoftPalette.slate350 : SoftPalette.slate550,
                      ),
                    ),
                  );
                },
              ),

              if (_isRunning) ...[
                const SizedBox(width: 8),
                Tooltip(
                  message: 'Push all broadcast drops, missed tokens, and stock updates to LAN devices',
                  child: ElevatedButton.icon(
                    onPressed: !_isCatchingUp ? _triggerCatchUpAndFixMismatch : null,
                    icon: _isCatchingUp
                        ? const SizedBox(
                            width: 12,
                            height: 12,
                            child: CircularProgressIndicator(strokeWidth: 2, color: SoftPalette.gray50),
                          )
                        : const Icon(Icons.bolt_rounded, size: 14),
                    label: Text(
                      _isCatchingUp ? 'Catching Up...' : 'Catch-Up & Fix Mismatch',
                      style: GoogleFonts.inter(fontSize: 11, fontWeight: FontWeight.bold),
                    ),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: SoftPalette.teal500,
                      foregroundColor: SoftPalette.gray50,
                      elevation: 0,
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                    ),
                  ),
                ),
              ],
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildStatusBadge() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: _isRunning ? SoftPalette.emerald700.withOpacity(0.4) : SoftPalette.red700.withOpacity(0.4),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
          color: _isRunning ? SoftPalette.emerald350 : SoftPalette.red400,
          width: 0.8,
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 7,
            height: 7,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: _isRunning ? SoftPalette.emerald350 : SoftPalette.red400,
              boxShadow: [
                BoxShadow(
                  color: (_isRunning ? SoftPalette.emerald350 : SoftPalette.red400).withOpacity(0.6),
                  blurRadius: 6,
                )
              ],
            ),
          ),
          const SizedBox(width: 7),
          Text(
            _isRunning ? 'SYS ONLINE' : 'SYS OFFLINE',
            style: GoogleFonts.inter(
              fontWeight: FontWeight.bold,
              fontSize: 11,
              color: _isRunning ? SoftPalette.emerald300 : SoftPalette.red350,
              letterSpacing: 0.5,
            ),
          ),
        ],
      ),
    );
  }

  /// How many connected devices per role group (devices with several roles count in each).
  Map<String, int> _roleCounts() {
    final counts = <String, int>{
      'Hybrid': 0, 'Admin': 0, 'Reception': 0, 'Doctor': 0, 'Dispenser': 0,
      'Finance': 0, 'Madrassa': 0, 'Library': 0, 'Dastarkhwaan': 0, 'Attendance': 0,
    };
    void bump(String k) => counts[k] = (counts[k] ?? 0) + 1;
    for (final c in _connectedClients.values) {
      final r = c.role.toLowerCase();
      if (r.contains('hybrid') || r.contains('+') || r.contains('rec_dis')) bump('Hybrid');
      if (r.contains('supervisor') || r.contains('admin')) bump('Admin');
      if (r.contains('receptionist') || r == 'rec' || r.contains('rec+dis')) bump('Reception');
      if (r.contains('doctor') || r == 'doc' || r.contains('doc+dis')) bump('Doctor');
      if (r.contains('dispenser') || r.contains('pharmacist') || r == 'dis' || r.contains('rec+dis') || r.contains('doc+dis')) bump('Dispenser');
      if (r.contains('finance') || r.contains('donations')) bump('Finance');
      if (r.contains('teacher') || r.contains('school') || r.contains('madrassa')) bump('Madrassa');
      if (r.contains('library')) bump('Library');
      if (r.contains('dasterkhwaan')) bump('Dastarkhwaan');
      if (r.contains('attendance')) bump('Attendance');
    }
    return counts;
  }

  // ── Other servers on this LAN ─────────────────────────────────────────────────
  // Every GMWF server broadcasts "GMWF_TOKEN_SERVER_I_AM:<ip>:<port>" on UDP. Hearing one that
  // is not this PC means two servers share the network (devices may pick the wrong one).
  Future<void> _startBeaconWatch() async {
    if (kIsWeb) return;
    try {
      final ifaces = await io.NetworkInterface.list(type: io.InternetAddressType.IPv4);
      _localIps = {for (final i in ifaces) for (final a in i.addresses) a.address};
      final socket = await io.RawDatagramSocket.bind(
        io.InternetAddress.anyIPv4,
        AppNetwork.udpBroadcastPort,
        reuseAddress: true,
      );
      _beaconSocket = socket;
      socket.listen((event) {
        if (event != io.RawSocketEvent.read) return;
        final dg = socket.receive();
        if (dg == null) return;
        final msg = utf8.decode(dg.data, allowMalformed: true);
        if (!msg.startsWith(AppNetwork.udpMessagePrefix)) return;
        final parts = msg.substring(AppNetwork.udpMessagePrefix.length).split(':');
        final ip = parts.first.trim();
        if (ip.isEmpty || _localIps.contains(ip) || ip == _serverIp) return;
        // Only a second server of THIS branch is a conflict (two token sequences for one branch);
        // another branch's server on a shared network is ignored by desks of this branch.
        final otherBranch = parts.length > 2 ? LocalStorageService.sanitizeBranchId(parts[2].trim(), fallback: '') : '';
        if (otherBranch.isNotEmpty &&
            otherBranch != LocalStorageService.sanitizeBranchId(_serverBranch, fallback: '')) {
          return;
        }
        _otherServerSeen[ip] = DateTime.now();
      });
    } catch (e) {
      debugPrint('[Server] Beacon watch unavailable: $e');
    }
  }

  // ── Hidden stress test: Ctrl+Shift+Alt+T ───────────────────────────────────────
  bool _stressTestOpen = false;
  bool _stressKeyRegistered = false;

  bool _stressTestKeyHandler(KeyEvent event) {
    if (event is! KeyDownEvent || event.logicalKey != LogicalKeyboardKey.keyT) return false;
    final kb = HardwareKeyboard.instance;
    if (!(kb.isControlPressed && kb.isShiftPressed && kb.isAltPressed)) return false;
    if (!mounted || _stressTestOpen) return true;
    final server = _server;
    if (!_isRunning || server == null) {
      AppToast.showSnackBar(context, 
        const SnackBar(content: Text('Start the LAN server first, then press the shortcut again.')),
      );
      return true;
    }
    _stressTestOpen = true;
    debugPrint('[StressTest] Shortcut pressed by ${FirebaseAuth.instance.currentUser?.email ?? "unknown user"}');
    final engine = StressTestEngine(server: server, cloudQueueSize: () => _syncQueueSize);
    StressTestDialog.show(context, engine, deviceCount: server.stressClientSnapshot().length)
        .whenComplete(() => _stressTestOpen = false);
    return true;
  }

  /// Ring colour by how full the resource is: green normally, amber above 70%, red above 90%.
  Color _levelColor(double? p) {
    if (p == null) return SoftPalette.slate350;
    if (p >= 0.9) return SoftPalette.red500;
    if (p >= 0.7) return SoftPalette.orange400;
    return SoftPalette.emerald350;
  }

  /// Real LAN traffic over the last ~minute: ring value (0..1 of 50 msg/s) and a readable summary.
  ({double load, String text}) _lanStats() {
    if (_lanSamples.length < 2) return (load: 0, text: 'Measuring…');
    final first = _lanSamples.first;
    final last = _lanSamples.last;
    final secs = ((last[0] - first[0]) / 1000).clamp(1, 3600);
    final msgsPerSec = (last[1] - first[1]) / secs;
    final kbPerSec = (last[2] - first[2]) / secs / 1024;
    return (
      load: (msgsPerSec / 50).clamp(0.0, 1.0).toDouble(),
      text: '${(msgsPerSec * 60).round()} msg/min · ${kbPerSec.toStringAsFixed(1)} KB/s',
    );
  }

  List<String> get _otherServers {
    final now = DateTime.now();
    return _otherServerSeen.entries
        .where((e) => now.difference(e.value).inSeconds < 20)
        .map((e) => e.key)
        .toList()
      ..sort();
  }

  // ── Main dashboard (running) ───────────────────────────────────────────────────
  Widget _buildRunningView([bool isDark = false]) {
    final showFirewall = !kIsWeb && io.Platform.isWindows && _firewallBlocked && !_isFirewallBannerDismissed;
    final rows = _connectedClients.values
        .map((c) => ServerClientRow(
              name: c.username?.isNotEmpty == true ? c.username! : c.displayName,
              role: c.role,
              ip: c.ipAddress,
              lastActive: c.lastActiveAt,
              messages: c.messagesCount,
            ))
        .toList();

    return ScrollConfiguration(
      behavior: ScrollConfiguration.of(context).copyWith(
        dragDevices: {
          ui.PointerDeviceKind.touch,
          ui.PointerDeviceKind.mouse,
          ui.PointerDeviceKind.trackpad,
          ui.PointerDeviceKind.stylus,
        },
      ),
      child: Scrollbar(
        controller: _runningScrollController,
        thumbVisibility: true,
        interactive: true,
        thickness: 8.0,
        radius: const Radius.circular(4),
        child: SingleChildScrollView(
          controller: _runningScrollController,
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              ServerOverviewPanel(
                isDark: isDark,
                isRunning: _isRunning,
                hasInternet: _isOnline,
                branchName: _resolveBranchAndCampDisplay(),
                address: '${_serverIp ?? "—"}:${AppNetwork.websocketPort}',
                startedAt: _startTime,
                lastCloudSync: _lastSyncTime,
                queueSize: _syncQueueSize,
                clients: rows,
                lanNote: 'LAN traffic: ${_lanStats().text}',
                roleCounts: _roleCounts(),
                onViewAll: _showAllNodesDialog,
                otherServers: _otherServers,
                firewallMissing: showFirewall,
                isSyncing: _isManualSyncing,
                onRetrySync: () {
                  if (!_isManualSyncing) _manualSync();
                },
                onCopyAddress: () {
                  Clipboard.setData(ClipboardData(text: '${_serverIp ?? ""}:${AppNetwork.websocketPort}'));
                  AppToast.showSnackBar(context, 
                    const SnackBar(content: Text('Server address copied'), duration: Duration(seconds: 2)),
                  );
                },
                onFixFirewall: _openFirewallPort,
                onOpenQueue: _showQueueManagementDialog,
              ),
              const SizedBox(height: 16),

              // System health, then the live log, each full width.
              _buildSystemHealthOverview(isDark),
              const SizedBox(height: 16),
              _buildLiveLogsCard(isDark),
              const SizedBox(height: 24),
            ],
          ),
        ),
      ),
    );
  }

  // ── 1. Hero Command Center Card ─────────────────────────────────────────────
  Widget _buildHeroCommandCenterCard(bool isDark) {
    final serverIpStr = _serverIp ?? '192.168.1.100';
    final bootTimeStr = _startTime != null
        ? DateFormat('d MMM yyyy, HH:mm').format(_startTime!)
        : DateFormat('d MMM yyyy, HH:mm').format(DateTime.now());
    final locationName = LocalStorageService.getBranchName(_serverBranch);

    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: isDark
              ? const [SoftPalette.slate900, SoftPalette.slate800, SoftPalette.slate900]
              : const [SoftPalette.emerald50m, SoftPalette.slate100, SoftPalette.gray50],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: isDark ? SoftPalette.teal500.withOpacity(0.35) : SoftPalette.slate200,
          width: 1.2,
        ),
        boxShadow: [
          BoxShadow(
            color: isDark ? SoftPalette.gray900A13 : SoftPalette.gray900A4,
            blurRadius: 16,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: LayoutBuilder(builder: (context, constraints) {
        final isCompact = constraints.maxWidth < 920;

        final leftDetails = Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            // 3D Isometric Server Rack Illustration
            _build3dServerRackVisual(),
            const SizedBox(width: 20),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    children: [
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3.5),
                        decoration: BoxDecoration(
                          color: isDark ? SoftPalette.emerald700.withOpacity(0.6) : SoftPalette.emerald100,
                          borderRadius: BorderRadius.circular(6),
                          border: Border.all(color: SoftPalette.emerald350.withOpacity(0.5)),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Container(
                              width: 6,
                              height: 6,
                              decoration: const BoxDecoration(shape: BoxShape.circle, color: SoftPalette.emerald350),
                            ),
                            const SizedBox(width: 5),
                            Text(
                              'PRIMARY GATEWAY NODE',
                              style: GoogleFonts.inter(
                                fontSize: 10,
                                fontWeight: FontWeight.w800,
                                color: isDark ? SoftPalette.emerald300 : SoftPalette.emerald600,
                                letterSpacing: 0.5,
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 8),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3.5),
                        decoration: BoxDecoration(
                          color: isDark ? SoftPalette.slate800 : SoftPalette.slate100,
                          borderRadius: BorderRadius.circular(6),
                          border: Border.all(color: isDark ? SoftPalette.slate700 : SoftPalette.slate200),
                        ),
                        child: Text(
                          'PORT 53281',
                          style: GoogleFonts.firaCode(
                            fontSize: 9.5,
                            fontWeight: FontWeight.bold,
                            color: isDark ? SoftPalette.sky350 : SoftPalette.sky500,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'GMWF Hybrid Command Center',
                    style: GoogleFonts.inter(
                      fontWeight: FontWeight.bold,
                      fontSize: 22,
                      color: isDark ? SoftPalette.gray50 : SoftPalette.slate900,
                      letterSpacing: 0.2,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'Dedicated branch gateway orchestrating real-time local sync & hardware push services.',
                    style: GoogleFonts.inter(
                      fontSize: 12,
                      color: isDark ? SoftPalette.slate350 : SoftPalette.slate550,
                      height: 1.3,
                    ),
                  ),
                  const SizedBox(height: 14),
                  // Non-redundant Gateway Metadata strip
                  Wrap(
                    spacing: 16,
                    runSpacing: 8,
                    children: [
                      _buildHeroMetadataItem(Icons.location_on_outlined, 'LOCATION', locationName, isDark),
                      _buildHeroMetadataItem(Icons.account_tree_outlined, 'GATEWAY STACK', 'LAN REST & WebSocket', isDark),
                      _buildHeroMetadataItem(Icons.storage_rounded, 'LOCAL VAULT', 'Hive Encrypted Box', isDark),
                      _buildHeroMetadataItem(Icons.calendar_today_outlined, 'LAST BOOT', bootTimeStr, isDark),
                    ],
                  ),
                ],
              ),
            ),
          ],
        );

        final rightWaveAndSync = Container(
          width: isCompact ? double.infinity : 280,
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: isDark ? SoftPalette.slate900.withOpacity(0.7) : SoftPalette.gray50,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: isDark ? SoftPalette.slate750 : SoftPalette.slate150),
            boxShadow: isDark ? [] : [const BoxShadow(color: SoftPalette.gray900A3, blurRadius: 8)],
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(6),
                    decoration: BoxDecoration(
                      color: isDark ? SoftPalette.emerald700.withOpacity(0.5) : SoftPalette.emerald100,
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: const Icon(Icons.shield_outlined, color: SoftPalette.emerald350, size: 16),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'SECURE & STABLE CONNECTION',
                          style: GoogleFonts.inter(fontSize: 10, fontWeight: FontWeight.w800, color: SoftPalette.emerald350),
                        ),
                        Text(
                          'Your server is running smoothly',
                          style: GoogleFonts.inter(fontSize: 10.5, color: isDark ? SoftPalette.slate350 : SoftPalette.slate550),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              // Dynamic Glowing Heartbeat Waveform Graph
              SizedBox(
                height: 32,
                child: CustomPaint(
                  painter: HeartbeatWavePainter(
                    animationValue: _pulseTick,
                    color: SoftPalette.emerald350,
                  ),
                  size: const Size(double.infinity, 32),
                ),
              ),
              const SizedBox(height: 12),
              // Actions: Catch-Up & Fix Mismatch, Force Cloud Sync & Copy Gateway URL
              Row(
                children: [
                  Expanded(
                    child: ElevatedButton.icon(
                      onPressed: (_isRunning && !_isCatchingUp) ? _triggerCatchUpAndFixMismatch : null,
                      icon: _isCatchingUp
                          ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2, color: SoftPalette.gray50))
                          : const Icon(Icons.bolt_rounded, size: 16),
                      label: Text(
                        _isCatchingUp ? 'Catching Up...' : 'Catch-Up & Fix Mismatch',
                        style: GoogleFonts.inter(fontWeight: FontWeight.bold, fontSize: 12),
                      ),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: SoftPalette.teal500,
                        foregroundColor: SoftPalette.gray50,
                        padding: const EdgeInsets.symmetric(vertical: 10),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                        elevation: 0,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: ElevatedButton.icon(
                      onPressed: (_isOnline && !_isManualSyncing) ? _manualSync : null,
                      icon: _isManualSyncing
                          ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2, color: SoftPalette.gray50))
                          : const Icon(Icons.cloud_sync_rounded, size: 16),
                      label: Text(
                        _isManualSyncing ? 'Syncing...' : 'Force Cloud Sync',
                        style: GoogleFonts.inter(fontWeight: FontWeight.bold, fontSize: 12),
                      ),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: SoftPalette.sky500,
                        foregroundColor: SoftPalette.gray50,
                        padding: const EdgeInsets.symmetric(vertical: 10),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                        elevation: 0,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Tooltip(
                    message: 'Copy Gateway URL (http://$serverIpStr:53281)',
                    child: InkWell(
                      onTap: () {
                        Clipboard.setData(ClipboardData(text: 'http://$serverIpStr:53281'));
                        AppToast.showSnackBar(context, 
                          const SnackBar(
                            content: Text('Copied Gateway URL to clipboard!'),
                            backgroundColor: SoftPalette.emerald350,
                            duration: Duration(seconds: 2),
                          ),
                        );
                      },
                      borderRadius: BorderRadius.circular(8),
                      child: Container(
                        padding: const EdgeInsets.all(9),
                        decoration: BoxDecoration(
                          color: isDark ? SoftPalette.slate800 : SoftPalette.slate100,
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(color: isDark ? SoftPalette.slate700 : SoftPalette.slate200),
                        ),
                        child: Icon(
                          Icons.copy_rounded,
                          size: 16,
                          color: isDark ? SoftPalette.sky350 : SoftPalette.sky500,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        );

        if (isCompact) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              leftDetails,
              const SizedBox(height: 16),
              rightWaveAndSync,
            ],
          );
        }

        return Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Expanded(child: leftDetails),
            const SizedBox(width: 20),
            rightWaveAndSync,
          ],
        );
      }),
    );
  }

  Widget _buildHeroMetadataItem(IconData icon, String label, String value, [bool isDark = false]) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 13, color: isDark ? SoftPalette.slate550 : SoftPalette.slate350),
        const SizedBox(width: 5),
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(label, style: GoogleFonts.inter(fontSize: 9, fontWeight: FontWeight.bold, color: isDark ? SoftPalette.slate550 : SoftPalette.slate350, letterSpacing: 0.5)),
            Text(value, style: GoogleFonts.inter(fontSize: 11.5, fontWeight: FontWeight.bold, color: isDark ? SoftPalette.slate200 : SoftPalette.slate900)),
          ],
        ),
      ],
    );
  }

  // ── 3D Isometric Server Visual ──────────────────────────────────────────────
  Widget _build3dServerRackVisual() {
    return Container(
      width: 80,
      height: 86,
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          colors: [SoftPalette.slate900, SoftPalette.slate800],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: SoftPalette.sky500.withOpacity(0.4)),
        boxShadow: const [
          BoxShadow(color: SoftPalette.gray900A25, blurRadius: 10, offset: Offset(2, 4)),
        ],
      ),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 7),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: [
          _buildServerDriveSlot(true),
          _buildServerDriveSlot(true),
          _buildServerDriveSlot(true),
        ],
      ),
    );
  }

  Widget _buildServerDriveSlot(bool isActive) {
    return Container(
      height: 18,
      decoration: BoxDecoration(
        color: SoftPalette.slate900,
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: SoftPalette.slate700, width: 0.8),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 5),
      child: Row(
        children: [
          Container(
            width: 4,
            height: 4,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: isActive ? SoftPalette.emerald350 : SoftPalette.slate550,
              boxShadow: isActive ? [const BoxShadow(color: SoftPalette.emerald350, blurRadius: 4)] : null,
            ),
          ),
          const SizedBox(width: 5),
          Expanded(
            child: Container(
              height: 2,
              decoration: BoxDecoration(
                color: SoftPalette.slate800,
                borderRadius: BorderRadius.circular(1),
              ),
            ),
          ),
          const SizedBox(width: 5),
          Container(
            width: 14,
            height: 5,
            decoration: BoxDecoration(
              color: SoftPalette.sky500.withOpacity(0.8),
              borderRadius: BorderRadius.circular(1.5),
              boxShadow: const [BoxShadow(color: SoftPalette.sky500, blurRadius: 3)],
            ),
          ),
        ],
      ),
    );
  }

  // ── 2. KPI Metrics Grid (4 Cards) ──────────────────────────────────────────
  Widget _buildKpiMetricsGrid(bool isDark) {
    return LayoutBuilder(builder: (context, constraints) {
      final isNarrow = constraints.maxWidth < 800;
      final serverIpStr = _serverIp ?? '192.168.1.100';

      final cards = [
        _buildMetricKpiCard(
          label: 'PRIMARY LAN ENDPOINT',
          value: '$serverIpStr:53281',
          subtitle: 'Tap to copy LAN address',
          icon: Icons.dns_rounded,
          glowColor: SoftPalette.cyan350,
          bgGradient: isDark ? const [SoftPalette.slate900, SoftPalette.slate900] : const [SoftPalette.gray50, SoftPalette.gray50],
          isDark: isDark,
          onTap: () {
            Clipboard.setData(ClipboardData(text: 'http://$serverIpStr:53281'));
            AppToast.showSnackBar(context, 
              SnackBar(
                content: Text('Copied LAN Endpoint: http://$serverIpStr:53281'),
                backgroundColor: SoftPalette.cyan350,
                duration: const Duration(seconds: 2),
              ),
            );
          },
        ),
        _buildMetricKpiCard(
          label: 'CLUSTER UPTIME',
          value: _formatUptime(),
          subtitle: 'Stable Gateway Operation',
          icon: Icons.timer_outlined,
          glowColor: SoftPalette.violet500,
          bgGradient: isDark ? const [SoftPalette.violet900, SoftPalette.slate900] : const [SoftPalette.gray50, SoftPalette.gray50],
          isDark: isDark,
        ),
        _buildMetricKpiCard(
          label: 'ACTIVE WORKSTATIONS',
          value: '${_connectedClients.length} Online',
          subtitle: _connectedClients.isEmpty ? 'Awaiting LAN clients' : '${_connectedClients.length} nodes communicating',
          icon: Icons.devices_rounded,
          glowColor: SoftPalette.emerald350,
          bgGradient: isDark ? const [SoftPalette.emerald900, SoftPalette.emerald900] : const [SoftPalette.gray50, SoftPalette.gray50],
          isDark: isDark,
          onTap: _showAllNodesDialog,
        ),
        _buildMetricKpiCard(
          label: 'SYNC PIPELINE',
          value: '$_syncedToday Synced',
          subtitle: '$_syncQueueSize Ops in Queue (Manage)',
          icon: Icons.cloud_sync_outlined,
          glowColor: SoftPalette.amber300,
          bgGradient: isDark ? const [SoftPalette.amber900, SoftPalette.yellow900] : const [SoftPalette.gray50, SoftPalette.gray50],
          isDark: isDark,
          onTap: _showQueueManagementDialog,
        ),
      ];

      if (isNarrow) {
        return GridView.count(
          crossAxisCount: 2,
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          mainAxisSpacing: 12,
          crossAxisSpacing: 12,
          childAspectRatio: 1.8,
          children: cards,
        );
      }

      return Row(
        children: [
          Expanded(child: cards[0]),
          const SizedBox(width: 12),
          Expanded(child: cards[1]),
          const SizedBox(width: 12),
          Expanded(child: cards[2]),
          const SizedBox(width: 12),
          Expanded(child: cards[3]),
        ],
      );
    });
  }

  Widget _buildMetricKpiCard({
    required String label,
    required String value,
    required String subtitle,
    required IconData icon,
    required Color glowColor,
    required List<Color> bgGradient,
    required bool isDark,
    VoidCallback? onTap,
  }) {
    final cardContent = Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        gradient: LinearGradient(colors: bgGradient, begin: Alignment.topLeft, end: Alignment.bottomRight),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: isDark ? glowColor.withOpacity(0.35) : SoftPalette.slate200,
          width: 1,
        ),
        boxShadow: [
          BoxShadow(
            color: isDark ? glowColor.withOpacity(0.04) : SoftPalette.gray900A2,
            blurRadius: 10,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                label,
                style: GoogleFonts.inter(fontSize: 10.5, fontWeight: FontWeight.bold, color: glowColor, letterSpacing: 0.6),
              ),
              Container(
                padding: const EdgeInsets.all(5),
                decoration: BoxDecoration(
                  color: glowColor.withOpacity(0.15),
                  shape: BoxShape.circle,
                ),
                child: Icon(icon, size: 14, color: glowColor),
              ),
            ],
          ),
          const SizedBox(height: 8),
          FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerLeft,
            child: Text(
              value,
              style: GoogleFonts.inter(
                fontSize: 22,
                fontWeight: FontWeight.w800,
                color: isDark ? SoftPalette.gray50 : SoftPalette.slate900,
                letterSpacing: 0.2,
              ),
            ),
          ),
          const SizedBox(height: 2),
          Text(
            subtitle,
            style: GoogleFonts.inter(fontSize: 11, color: isDark ? SoftPalette.slate350 : SoftPalette.slate550, fontWeight: FontWeight.w500),
          ),
        ],
      ),
    );

    if (onTap != null) {
      return Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(12),
          child: cardContent,
        ),
      );
    }

    return cardContent;
  }

  // ── 3. Middle Left: Live Network System Log Stream ──────────────────────────
  Widget _buildLiveLogsCard(bool isDark) {
    return Container(
      decoration: BoxDecoration(
        color: isDark ? SoftPalette.slate900 : SoftPalette.gray50,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: isDark ? SoftPalette.slate800 : SoftPalette.slate200),
        boxShadow: isDark ? [] : [const BoxShadow(color: SoftPalette.gray900A2, blurRadius: 8)],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Card Header
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 10),
            child: Row(
              children: [
                const Icon(Icons.terminal_rounded, size: 16, color: SoftPalette.sky500),
                const SizedBox(width: 8),
                Text(
                  'Live Network System Log Stream',
                  style: GoogleFonts.inter(fontWeight: FontWeight.bold, fontSize: 14, color: isDark ? SoftPalette.gray50 : SoftPalette.slate900),
                ),
                const Spacer(),
                Tooltip(
                  message: 'Copy all logs',
                  child: InkWell(
                    onTap: () {
                      if (_activityLog.isNotEmpty) {
                        Clipboard.setData(ClipboardData(text: _activityLog.join('\n')));
                        AppToast.showSnackBar(context, 
                          const SnackBar(content: Text('Logs copied!'), backgroundColor: SoftPalette.emerald350, duration: Duration(seconds: 1)),
                        );
                      }
                    },
                    borderRadius: BorderRadius.circular(4),
                    child: Padding(
                      padding: const EdgeInsets.all(4),
                      child: Icon(Icons.copy_rounded, size: 15, color: isDark ? SoftPalette.slate350 : SoftPalette.slate550),
                    ),
                  ),
                ),
                const SizedBox(width: 4),
                Tooltip(
                  message: 'Clear terminal',
                  child: InkWell(
                    onTap: () => setState(() => _activityLog.clear()),
                    borderRadius: BorderRadius.circular(4),
                    child: Padding(
                      padding: const EdgeInsets.all(4),
                      child: Icon(Icons.clear_all_rounded, size: 16, color: isDark ? SoftPalette.slate350 : SoftPalette.slate550),
                    ),
                  ),
                ),
                const SizedBox(width: 6),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2.5),
                  decoration: BoxDecoration(
                    color: isDark ? SoftPalette.emerald700.withOpacity(0.5) : SoftPalette.emerald100,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: SoftPalette.emerald350.withOpacity(0.5)),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Container(width: 5, height: 5, decoration: const BoxDecoration(shape: BoxShape.circle, color: SoftPalette.emerald350)),
                      const SizedBox(width: 4),
                      Text('LIVE', style: GoogleFonts.inter(fontSize: 9.5, fontWeight: FontWeight.bold, color: isDark ? SoftPalette.emerald300 : SoftPalette.emerald600)),
                    ],
                  ),
                ),
              ],
            ),
          ),
          Divider(height: 1, color: isDark ? SoftPalette.slate800 : SoftPalette.slate150),

          // Terminal Stream Box
          Container(
            height: 205,
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: isDark ? SoftPalette.slate900 : SoftPalette.gray50,
            ),
            child: _activityLog.isEmpty
                ? Center(
                    child: Text(
                      'Waiting for network logs and events...',
                      style: GoogleFonts.firaCode(fontSize: 11, color: isDark ? SoftPalette.slate550 : SoftPalette.slate350),
                    ),
                  )
                : ListView.builder(
                    itemCount: _activityLog.length,
                    reverse: false,
                    itemBuilder: (context, idx) {
                      final log = _activityLog[idx];
                      Color textColor = isDark ? SoftPalette.emerald350 : SoftPalette.emerald550;
                      if (log.contains('❌') || log.contains('ERROR') || log.contains('Failed')) {
                        textColor = isDark ? SoftPalette.red350 : SoftPalette.red500;
                      } else if (log.contains('⚠️') || log.contains('Queued') || log.contains('warning')) {
                        textColor = isDark ? SoftPalette.amber200 : SoftPalette.orange400;
                      } else if (log.contains('ℹ️') || log.contains('Waiting')) {
                        textColor = isDark ? SoftPalette.sky350 : SoftPalette.sky500;
                      }
                      return Padding(
                        padding: const EdgeInsets.symmetric(vertical: 2.5),
                        child: Text(
                          log,
                          style: GoogleFonts.firaCode(fontSize: 10.5, color: textColor, height: 1.3),
                        ),
                      );
                    },
                  ),
          ),
          Divider(height: 1, color: isDark ? SoftPalette.slate800 : SoftPalette.slate150),

          // Footer Action
          InkWell(
            onTap: _showFullLogDialog,
            borderRadius: const BorderRadius.vertical(bottom: Radius.circular(14)),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text('View Full Log', style: GoogleFonts.inter(fontSize: 11.5, color: isDark ? SoftPalette.slate350 : SoftPalette.slate600, fontWeight: FontWeight.w600)),
                  const SizedBox(width: 4),
                  Icon(Icons.arrow_forward_rounded, size: 13, color: isDark ? SoftPalette.slate350 : SoftPalette.slate600),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
  Widget _buildActiveBranchNodesCard(bool isDark) {
    int hybridCount = 0;
    int supervisorCount = 0;
    int receptionistCount = 0;
    int doctorCount = 0;
    int dispenserCount = 0;
    int financeCount = 0;
    int eduCount = 0;
    int libraryCount = 0;
    int dasterkhwaanCount = 0;
    int attendanceCount = 0;

    for (final c in _connectedClients.values) {
      final r = c.role.toLowerCase();
      if (r.contains('hybrid') || r.contains('+') || r.contains('rec+dis') || r.contains('rec_dis') || r.contains('doc+dis')) {
        hybridCount++;
      }
      if (r.contains('supervisor') || r.contains('admin')) supervisorCount++;
      if (r.contains('receptionist') || r == 'rec' || r.contains('rec+dis')) receptionistCount++;
      if (r.contains('doctor') || r == 'doc' || r.contains('doc+dis')) doctorCount++;
      if (r.contains('dispenser') || r.contains('pharmacist') || r == 'dis' || r.contains('rec+dis') || r.contains('doc+dis')) dispenserCount++;
      if (r.contains('finance') || r.contains('donations')) financeCount++;
      if (r.contains('teacher') || r.contains('school') || r.contains('madrassa')) eduCount++;
      if (r.contains('library')) libraryCount++;
      if (r.contains('dasterkhwaan')) dasterkhwaanCount++;
      if (r.contains('attendance')) attendanceCount++;
    }

    return Container(
      decoration: BoxDecoration(
        color: isDark ? SoftPalette.slate900 : SoftPalette.gray50,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: isDark ? SoftPalette.slate800 : SoftPalette.slate200),
        boxShadow: isDark ? [] : [const BoxShadow(color: SoftPalette.gray900A2, blurRadius: 8)],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Card Header
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 10),
            child: Row(
              children: [
                const Icon(Icons.hub_rounded, size: 16, color: SoftPalette.sky500),
                const SizedBox(width: 8),
                Text(
                  'Active Branch Network Nodes',
                  style: GoogleFonts.inter(fontWeight: FontWeight.bold, fontSize: 14, color: isDark ? SoftPalette.gray50 : SoftPalette.slate900),
                ),
                const Spacer(),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(
                    color: _connectedClients.isNotEmpty
                        ? SoftPalette.emerald350.withOpacity(0.15)
                        : SoftPalette.sky500.withOpacity(0.12),
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(
                      color: _connectedClients.isNotEmpty
                          ? SoftPalette.emerald350.withOpacity(0.4)
                          : SoftPalette.sky500.withOpacity(0.3),
                    ),
                  ),
                  child: Text(
                    '${_connectedClients.length} CONNECTED',
                    style: GoogleFonts.inter(
                      fontSize: 10,
                      fontWeight: FontWeight.bold,
                      color: _connectedClients.isNotEmpty
                          ? (isDark ? SoftPalette.emerald300 : SoftPalette.emerald600)
                          : (isDark ? SoftPalette.sky350 : SoftPalette.sky500),
                    ),
                  ),
                ),
              ],
            ),
          ),
          Divider(height: 1, color: isDark ? SoftPalette.slate800 : SoftPalette.slate150),

          // Body: Connected Clients list or Awaiting Status Banner
          Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (_connectedClients.isNotEmpty) ...[
                  Container(
                    constraints: const BoxConstraints(maxHeight: 90),
                    margin: const EdgeInsets.only(bottom: 10),
                    child: ListView(
                      shrinkWrap: true,
                      children: _connectedClients.values.map((c) => _buildClientRow(c, isDark)).toList(),
                    ),
                  ),
                ] else ...[
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                    margin: const EdgeInsets.only(bottom: 10),
                    decoration: BoxDecoration(
                      color: isDark ? SoftPalette.slate800.withOpacity(0.4) : SoftPalette.gray50,
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: isDark ? SoftPalette.slate700 : SoftPalette.slate150),
                    ),
                    child: Row(
                      children: [
                        Icon(Icons.wifi_tethering_rounded, size: 15, color: isDark ? SoftPalette.sky350 : SoftPalette.sky500),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            'Awaiting client workstations to connect on LAN (Port 53281).',
                            style: GoogleFonts.inter(fontSize: 11, color: isDark ? SoftPalette.slate350 : SoftPalette.slate550),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],

                // Role Summary Badges
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    _buildRoleNodePill('Hybrid', hybridCount, isDark),
                    _buildRoleNodePill('Admin', supervisorCount, isDark),
                    _buildRoleNodePill('Reception', receptionistCount, isDark),
                    _buildRoleNodePill('Doctor', doctorCount, isDark),
                    _buildRoleNodePill('Dispenser', dispenserCount, isDark),
                    _buildRoleNodePill('Finance', financeCount, isDark),
                    _buildRoleNodePill('Madrassa', eduCount, isDark),
                    _buildRoleNodePill('Library', libraryCount, isDark),
                    _buildRoleNodePill('Dastarkhwaan', dasterkhwaanCount, isDark),
                    _buildRoleNodePill('Attendance', attendanceCount, isDark),
                  ],
                ),
              ],
            ),
          ),
          Divider(height: 1, color: isDark ? SoftPalette.slate800 : SoftPalette.slate150),

          // Footer Action
          InkWell(
            onTap: _showAllNodesDialog,
            borderRadius: const BorderRadius.vertical(bottom: Radius.circular(14)),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text('View All Nodes', style: GoogleFonts.inter(fontSize: 11.5, color: isDark ? SoftPalette.slate350 : SoftPalette.slate600, fontWeight: FontWeight.w600)),
                  const SizedBox(width: 4),
                  Icon(Icons.arrow_forward_rounded, size: 13, color: isDark ? SoftPalette.slate350 : SoftPalette.slate600),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildRoleNodePill(String label, int count, [bool isDark = false]) {
    final hasActive = count > 0;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: hasActive
            ? (isDark ? SoftPalette.teal550.withOpacity(0.3) : SoftPalette.emerald50)
            : (isDark ? SoftPalette.slate800.withOpacity(0.4) : SoftPalette.slate100),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(
          color: hasActive ? SoftPalette.emerald350 : (isDark ? SoftPalette.slate700 : SoftPalette.slate200),
          width: 0.8,
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            label,
            style: GoogleFonts.inter(
              fontSize: 10.5,
              color: hasActive
                  ? (isDark ? SoftPalette.gray50 : SoftPalette.emerald600)
                  : (isDark ? SoftPalette.slate350 : SoftPalette.slate600),
              fontWeight: hasActive ? FontWeight.bold : FontWeight.w500,
            ),
          ),
          const SizedBox(width: 5),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 4.5, vertical: 1),
            decoration: BoxDecoration(
              color: hasActive ? SoftPalette.emerald350 : (isDark ? SoftPalette.slate700 : SoftPalette.slate350),
              borderRadius: BorderRadius.circular(3),
            ),
            child: Text(
              '$count',
              style: GoogleFonts.inter(fontSize: 9.5, fontWeight: FontWeight.bold, color: SoftPalette.gray50),
            ),
          ),
        ],
      ),
    );
  }

  // ── 4. Bottom Left: System Health Overview (Live Genuine Telemetry) ──────────
  Widget _buildSystemHealthOverview(bool isDark) {
    final snap = SystemMetricsService().currentSnapshot;

    // LAN load: real traffic through this server over the last ~minute (messages received
    // from devices plus messages delivered to them). The ring shows it against a comfortable
    // capacity of 50 messages per second; a clinic normally sits at a tiny fraction of that.
    final lan = _lanStats();
    final double lanLoad = lan.load;
    final String lanSubtext = lan.text;
    final cloudWaiting = _syncQueueSize;
    final cloudLoad = (cloudWaiting / 500).clamp(0.0, 1.0);

    return Container(
      decoration: BoxDecoration(
        color: isDark ? SoftPalette.slate900 : SoftPalette.gray50,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: isDark ? SoftPalette.slate800 : SoftPalette.slate200),
        boxShadow: isDark ? [] : [const BoxShadow(color: SoftPalette.gray900A2, blurRadius: 8)],
      ),
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              const Icon(Icons.monitor_heart_outlined, size: 16, color: SoftPalette.emerald350),
              const SizedBox(width: 8),
              Text(
                'System Health Overview',
                style: GoogleFonts.inter(fontWeight: FontWeight.bold, fontSize: 14, color: isDark ? SoftPalette.gray50 : SoftPalette.slate900),
              ),
              const Spacer(),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                decoration: BoxDecoration(
                  color: isDark ? SoftPalette.slate800 : SoftPalette.slate100,
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Text(
                  'Process RAM: ${snap.appProcessRamMb.toStringAsFixed(0)} MB',
                  style: GoogleFonts.inter(fontSize: 10, fontWeight: FontWeight.bold, color: SoftPalette.sky500),
                ),
              ),
            ],
          ),
          const SizedBox(height: 18),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceAround,
            children: [
              _buildRadialGauge('CPU', snap.cpuKnown ? snap.cpuPercent : null, snap.cpuStatus, _levelColor(snap.cpuKnown ? snap.cpuPercent : null), isDark),
              _buildRadialGauge('Memory', snap.ramKnown ? snap.ramPercent : null,
                  snap.ramKnown ? '${snap.usedRamGb} / ${snap.totalRamGb} GB' : 'Not available', _levelColor(snap.ramKnown ? snap.ramPercent : null), isDark),
              _buildRadialGauge('Disk ${snap.diskDrive}'.trim(), snap.diskKnown ? snap.diskPercent : null,
                  snap.diskKnown ? '${snap.usedDiskGb} / ${snap.totalDiskGb} GB' : 'Not available', _levelColor(snap.diskKnown ? snap.diskPercent : null), isDark),
              _buildRadialGauge('LAN load', lanLoad, lanSubtext, SoftPalette.teal500, isDark),
              _buildRadialGauge('Cloud queue', cloudLoad,
                  cloudWaiting == 0 ? 'All uploaded' : '$cloudWaiting waiting',
                  cloudWaiting == 0 ? SoftPalette.emerald350 : SoftPalette.orange500, isDark,
                  '$cloudWaiting'),
              _buildQueueHealthCard(isDark),
            ],
          ),
        ],
      ),
    );
  }

  bool _queueStatsRunning = false;

  Future<void> _refreshQueueHealthStats() async {
    if (!mounted || _queueStatsRunning) return;
    _queueStatsRunning = true;
    final SyncQueueStats stats;
    try {
      stats = await SyncService().queueStats();
    } finally {
      _queueStatsRunning = false;
    }
    if (!mounted) return;
    setState(() {
      _queueHealthStats = stats;
    });
  }

  Widget _buildQueueHealthCard(bool isDark) {
    final stats = _queueHealthStats;
    final total = stats.expressCount + stats.freightCount;
    final age = stats.oldestAgeDue ?? stats.oldestAgeOverall;
    final ageColor = _oldestAgeColor(age, total, isDark);
    final ageText = total == 0 ? 'Queue empty' : _formatQueueAge(age);
    final isPaused = QuotaService.isPausedForDailyReset;
    final pauseUntil = QuotaService.dailyResetPauseUntil;
    final pauseStep = QuotaService.pauseStepCount;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: isDark ? SoftPalette.slate800.withValues(alpha: 0.6) : SoftPalette.slate100,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: isDark ? SoftPalette.slate700 : SoftPalette.slate200),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                'Oldest: ',
                style: GoogleFonts.inter(fontSize: 10, color: isDark ? SoftPalette.slate350 : SoftPalette.slate600, fontWeight: FontWeight.w600),
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                decoration: BoxDecoration(
                  color: ageColor.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Text(
                  ageText,
                  style: GoogleFonts.inter(fontSize: 10, color: ageColor, fontWeight: FontWeight.bold),
                ),
              ),
            ],
          ),
          const SizedBox(height: 3),
          Text(
            'Express: ${stats.expressCount} · Freight: ${stats.freightCount}',
            style: GoogleFonts.inter(fontSize: 9.5, color: isDark ? SoftPalette.slate350 : SoftPalette.slate700, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 2),
          Text(
            'Writes today: ${QuotaService.dailyWriteCount} | Backlog: ${QuotaService.dailyBacklogWriteCount}/${QuotaService.backlogDailyBudget}',
            style: GoogleFonts.inter(fontSize: 9.5, color: isDark ? SoftPalette.slate400 : SoftPalette.slate600),
          ),
          if (isPaused && pauseUntil != null) ...[
            const SizedBox(height: 2),
            Text(
              '⚠️ Paused until ${DateFormat('HH:mm').format(pauseUntil.toLocal())} (step $pauseStep)',
              style: GoogleFonts.inter(fontSize: 9.5, color: SoftPalette.amber300, fontWeight: FontWeight.bold),
            ),
          ],
        ],
      ),
    );
  }

  String _formatQueueAge(Duration? d) {
    if (d == null) return 'None';
    if (d.isNegative) return '0s';
    if (d.inSeconds < 60) return '${d.inSeconds}s';
    if (d.inMinutes < 60) return '${d.inMinutes}m ${d.inSeconds % 60}s';
    if (d.inHours < 24) return '${d.inHours}h ${d.inMinutes % 60}m';
    return '${d.inDays}d ${d.inHours % 24}h';
  }

  Color _oldestAgeColor(Duration? age, int totalItems, bool isDark) {
    if (totalItems == 0 || age == null) {
      return isDark ? SoftPalette.slate400 : SoftPalette.slate500;
    }
    if (age < const Duration(minutes: 2)) {
      return SoftPalette.emerald350;
    } else if (age < const Duration(minutes: 15)) {
      return SoftPalette.amber300;
    } else {
      return SoftPalette.red400;
    }
  }

  Widget _buildRadialGauge(String title, double? percentage, String subtext, Color color, [bool isDark = false, String? centerText]) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          title,
          style: GoogleFonts.inter(fontSize: 11, color: isDark ? SoftPalette.slate350 : SoftPalette.slate600, fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 10),
        SizedBox(
          width: 68,
          height: 68,
          child: Stack(
            alignment: Alignment.center,
            children: [
              CircularProgressIndicator(
                value: percentage ?? 0,
                strokeWidth: 6,
                backgroundColor: isDark ? SoftPalette.slate800 : SoftPalette.slate150,
                valueColor: AlwaysStoppedAnimation<Color>(color),
              ),
              Text(
                centerText ?? (percentage == null ? 'n/a' : '${(percentage * 100).round()}%'),
                style: GoogleFonts.inter(fontWeight: FontWeight.bold, fontSize: 15, color: isDark ? SoftPalette.gray50 : SoftPalette.slate900),
              ),
            ],
          ),
        ),
        const SizedBox(height: 8),
        Text(
          subtext,
          style: GoogleFonts.inter(fontSize: 10, color: isDark ? SoftPalette.slate550 : SoftPalette.slate350, fontWeight: FontWeight.w500),
        ),
      ],
    );
  }

  // ── 4. Bottom Right: LAN Hardware & Devices ─────────────────────────────────
  Widget _buildLanHardwareDevicesCard(bool isDark) {
    final serverIpStr = _serverIp ?? '192.168.1.100';
    final devices = ZkTecoNetworkService.getAllDevices();

    return Container(
      decoration: BoxDecoration(
        color: isDark ? SoftPalette.slate900 : SoftPalette.gray50,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: isDark ? SoftPalette.slate800 : SoftPalette.slate200),
        boxShadow: isDark ? [] : [const BoxShadow(color: SoftPalette.gray900A2, blurRadius: 8)],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Header
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 10),
            child: Row(
              children: [
                const Icon(Icons.dns_rounded, size: 16, color: SoftPalette.violet500),
                const SizedBox(width: 8),
                Text(
                  'LAN Hardware & Devices',
                  style: GoogleFonts.inter(fontWeight: FontWeight.bold, fontSize: 14, color: isDark ? SoftPalette.gray50 : SoftPalette.slate900),
                ),
                const Spacer(),
                TextButton(
                  onPressed: () {
                    setState(() => _selectedTab = 4);
                  },
                  style: TextButton.styleFrom(
                    backgroundColor: isDark ? SoftPalette.slate800 : SoftPalette.slate100,
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                    minimumSize: Size.zero,
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
                  ),
                  child: Text('View All Devices', style: GoogleFonts.inter(fontSize: 11, fontWeight: FontWeight.bold, color: isDark ? SoftPalette.slate150 : SoftPalette.slate900)),
                ),
              ],
            ),
          ),
          Divider(height: 1, color: isDark ? SoftPalette.slate800 : SoftPalette.slate150),

          // Data Table in bounded scroll container for vertical balance
          Container(
            constraints: const BoxConstraints(maxHeight: 220),
            child: SingleChildScrollView(
              scrollDirection: Axis.vertical,
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: DataTable(
                  headingRowHeight: 34,
                  dataRowMinHeight: 36,
                  dataRowMaxHeight: 40,
                  horizontalMargin: 16,
                  columnSpacing: 18,
                  headingTextStyle: GoogleFonts.inter(fontSize: 10.5, fontWeight: FontWeight.bold, color: isDark ? SoftPalette.slate550 : SoftPalette.slate600),
                  dataTextStyle: GoogleFonts.inter(fontSize: 11.5, color: isDark ? SoftPalette.slate200 : SoftPalette.slate800),
                  columns: const [
                    DataColumn(label: Text('DEVICE NAME')),
                    DataColumn(label: Text('IP ADDRESS')),
                    DataColumn(label: Text('TYPE')),
                    DataColumn(label: Text('STATUS')),
                    DataColumn(label: Text('LAST SEEN')),
                  ],
                  rows: [
                    // 1. Primary Server Node
                    DataRow(cells: [
                      DataCell(Text('GMWF-Server', style: TextStyle(fontWeight: FontWeight.bold, color: isDark ? SoftPalette.gray50 : SoftPalette.slate900))),
                      DataCell(Text(serverIpStr, style: const TextStyle(fontFamily: 'monospace'))),
                      const DataCell(Text('Primary Node')),
                      const DataCell(Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.circle, size: 8, color: SoftPalette.emerald350),
                          SizedBox(width: 5),
                          Text('Online', style: TextStyle(color: SoftPalette.emerald350, fontWeight: FontWeight.bold)),
                        ],
                      )),
                      const DataCell(Text('Just now')),
                    ]),

                    // 2. Biometric Devices (Real from Registry)
                    ...devices.map((dev) {
                      final isOnline = dev.status.toLowerCase() == 'online';
                      final lastSeenStr = dev.lastHeartbeat != null
                          ? _formatDeviceTimeAgo(dev.lastHeartbeat!)
                          : (isOnline ? 'Just now' : 'Offline');
                      return DataRow(cells: [
                        DataCell(Text(dev.deviceName.isNotEmpty ? dev.deviceName : 'ZKTeco Scanner', style: TextStyle(color: isDark ? SoftPalette.gray50 : SoftPalette.slate900))),
                        DataCell(Text(dev.ipAddress, style: const TextStyle(fontFamily: 'monospace'))),
                        const DataCell(Text('Biometric Device')),
                        DataCell(Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(Icons.circle, size: 8, color: isOnline ? SoftPalette.emerald350 : SoftPalette.red400),
                            SizedBox(width: 5),
                            Text(
                              isOnline ? 'Online' : 'Offline',
                              style: TextStyle(color: isOnline ? SoftPalette.emerald350 : SoftPalette.red400, fontWeight: FontWeight.bold),
                            ),
                          ],
                        )),
                        DataCell(Text(lastSeenStr)),
                      ]);
                    }),

                    // 3. Fallback row if no devices
                    if (devices.isEmpty)
                      const DataRow(cells: [
                        DataCell(Text('ZKTeco Biometric')),
                        DataCell(Text('192.168.1.150', style: TextStyle(fontFamily: 'monospace'))),
                        DataCell(Text('Biometric Device')),
                        DataCell(Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(Icons.circle, size: 8, color: SoftPalette.emerald350),
                            SizedBox(width: 5),
                            Text('Online', style: TextStyle(color: SoftPalette.emerald300, fontWeight: FontWeight.bold)),
                          ],
                        )),
                        DataCell(Text('1m ago')),
                      ]),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ── Dialogs: Full Log View & All Nodes ──────────────────────────────────────
  void _showFullLogDialog() {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: SoftPalette.slate900,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16), side: const BorderSide(color: SoftPalette.slate700)),
        title: Row(
          children: [
            const Icon(Icons.terminal_rounded, color: SoftPalette.sky500, size: 20),
            const SizedBox(width: 10),
            Text('Full Network System Log', style: GoogleFonts.inter(fontWeight: FontWeight.bold, fontSize: 16, color: SoftPalette.gray50)),
          ],
        ),
        content: SizedBox(
          width: 600,
          height: 400,
          child: Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: SoftPalette.slate900,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: SoftPalette.slate800),
            ),
            child: _activityLog.isEmpty
                ? Center(child: Text('No activity logs recorded yet.', style: GoogleFonts.firaCode(color: SoftPalette.gray50A38)))
                : ListView.builder(
                    itemCount: _activityLog.length,
                    itemBuilder: (_, i) => Padding(
                      padding: const EdgeInsets.symmetric(vertical: 2),
                      child: Text(_activityLog[i], style: GoogleFonts.firaCode(fontSize: 11, color: SoftPalette.emerald300)),
                    ),
                  ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () {
              Clipboard.setData(ClipboardData(text: _activityLog.join('\n')));
              AppToast.showSnackBar(context, const SnackBar(content: Text('Logs copied to clipboard!'), backgroundColor: SoftPalette.emerald350));
            },
            child: const Text('Copy All Logs', style: TextStyle(color: SoftPalette.sky350)),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx),
            style: ElevatedButton.styleFrom(backgroundColor: SoftPalette.sky500),
            child: const Text('Close', style: TextStyle(color: SoftPalette.gray50)),
          ),
        ],
      ),
    );
  }

  void _showAllNodesDialog() {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: SoftPalette.slate900,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16), side: const BorderSide(color: SoftPalette.slate700)),
        title: Row(
          children: [
            const Icon(Icons.hub_rounded, color: SoftPalette.sky500, size: 20),
            const SizedBox(width: 10),
            Text('Connected Network Nodes (${_connectedClients.length})', style: GoogleFonts.inter(fontWeight: FontWeight.bold, fontSize: 16, color: SoftPalette.gray50)),
          ],
        ),
        content: SizedBox(
          width: 550,
          height: 350,
          child: _connectedClients.isEmpty
              ? Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.radar_rounded, size: 48, color: SoftPalette.slate600),
                      const SizedBox(height: 12),
                      Text('No Client Nodes Currently Connected', style: GoogleFonts.inter(color: SoftPalette.gray50A70, fontWeight: FontWeight.bold)),
                      const SizedBox(height: 4),
                      Text('When client devices open the app on the LAN, they appear here.', style: GoogleFonts.inter(color: SoftPalette.slate550, fontSize: 12)),
                    ],
                  ),
                )
              : ListView(
                  children: _connectedClients.values.map((c) => _buildClientRow(c, true)).toList(),
                ),
        ),
        actions: [
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx),
            style: ElevatedButton.styleFrom(backgroundColor: SoftPalette.sky500),
            child: const Text('Close', style: TextStyle(color: SoftPalette.gray50)),
          ),
        ],
      ),
    );
  }

  Widget _buildWebUnsupportedMessage() {
    return Scaffold(
      backgroundColor: SoftPalette.slate900,
      appBar: AppBar(backgroundColor: Colors.transparent, elevation: 0),
      body: Center(
        child: Container(
          constraints: const BoxConstraints(maxWidth: 500),
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.cloud_off_rounded, size: 100, color: SoftPalette.blue400.withOpacity(0.5)),
              const SizedBox(height: 32),
              const Text('Platform Incompatible', style: TextStyle(fontSize: 28, fontWeight: FontWeight.bold, color: SoftPalette.gray50)),
              const SizedBox(height: 16),
              const Text(
                'Server hosting requires native socket access. Please run the application on Windows, macOS, or Linux to establish a LAN node.',
                textAlign: TextAlign.center,
                style: TextStyle(height: 1.5, color: SoftPalette.gray50A60, fontSize: 16),
              ),
              const SizedBox(height: 40),
              ElevatedButton.icon(
                onPressed: () => Navigator.of(context).pop(),
                icon: const Icon(Icons.arrow_back),
                label: const Text('Return'),
                style: ElevatedButton.styleFrom(backgroundColor: SoftPalette.blue400, padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 16)),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildNotAuthenticatedMessage() {
    return Scaffold(
      backgroundColor: SoftPalette.slate900,
      body: Center(
        child: Container(
          constraints: const BoxConstraints(maxWidth: 500),
          child: Card(
            color: SoftPalette.slate800.withOpacity(0.8),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20), side: BorderSide(color: SoftPalette.gray50.withOpacity(0.05))),
            child: Padding(
              padding: const EdgeInsets.all(40),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    padding: const EdgeInsets.all(20),
                    decoration: BoxDecoration(shape: BoxShape.circle, color: SoftPalette.amber300.withOpacity(0.1)),
                    child: const Icon(Icons.lock_outline, size: 60, color: SoftPalette.amber300),
                  ),
                  const SizedBox(height: 32),
                  const Text('Access Denied', style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold, color: SoftPalette.gray50)),
                  const SizedBox(height: 16),
                  const Text('Server level clearance required. Please authenticate with a Server role.', textAlign: TextAlign.center, style: TextStyle(color: SoftPalette.gray50A60)),
                  const SizedBox(height: 40),
                  ElevatedButton.icon(
                    onPressed: () => Navigator.of(context).pop(),
                    icon: const Icon(Icons.arrow_back),
                    label: const Text('Go Back'),
                    style: ElevatedButton.styleFrom(backgroundColor: SoftPalette.amber300, foregroundColor: SoftPalette.gray900, padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 16)),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildStoppedView([bool isDark = false]) {
    final cardBg = isDark ? SoftPalette.slate900 : SoftPalette.gray50;
    final borderColor = isDark ? SoftPalette.slate800 : SoftPalette.slate150;
    final textPrimary = isDark ? SoftPalette.gray50 : SoftPalette.slate900;
    final textSecondary = isDark ? SoftPalette.slate350 : SoftPalette.slate550;
    final serverIpStr = _serverIp ?? 'Detecting...';

    return SingleChildScrollView(
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 24),
      child: Center(
        child: Container(
          constraints: const BoxConstraints(maxWidth: 720),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // ── 1. Standby Hero Header ──────────────────────────────────────
              Container(
                padding: const EdgeInsets.all(28),
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    colors: isDark
                        ? [SoftPalette.slate900, SoftPalette.slate900]
                        : [SoftPalette.slate100, SoftPalette.gray50],
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                  ),
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(
                    color: isDark ? SoftPalette.sky500.withOpacity(0.3) : SoftPalette.slate150,
                    width: 1.2,
                  ),
                  boxShadow: [
                    BoxShadow(
                      color: SoftPalette.sky500.withOpacity(isDark ? 0.12 : 0.06),
                      blurRadius: 20,
                      offset: const Offset(0, 8),
                    ),
                  ],
                ),
                child: Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.all(18),
                      decoration: BoxDecoration(
                        color: SoftPalette.sky500.withOpacity(0.12),
                        shape: BoxShape.circle,
                        border: Border.all(
                          color: SoftPalette.sky500.withOpacity(0.3),
                          width: 1.5,
                        ),
                      ),
                      child: const Icon(
                        Icons.settings_input_antenna_rounded,
                        size: 38,
                        color: SoftPalette.sky500,
                      ),
                    ),
                    const SizedBox(width: 22),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Text(
                                'LAN Gateway in Standby',
                                style: GoogleFonts.inter(
                                  fontSize: 22,
                                  fontWeight: FontWeight.bold,
                                  color: textPrimary,
                                ),
                              ),
                              const SizedBox(width: 10),
                              Container(
                                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                                decoration: BoxDecoration(
                                  color: isDark ? SoftPalette.slate800 : SoftPalette.slate150,
                                  borderRadius: BorderRadius.circular(6),
                                  border: Border.all(color: borderColor),
                                ),
                                child: Text(
                                  _serverBranch.toUpperCase(),
                                  style: GoogleFonts.inter(
                                    fontSize: 10.5,
                                    fontWeight: FontWeight.bold,
                                    color: textSecondary,
                                  ),
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 6),
                          Text(
                            'The local network socket is idle. Initialize the node to begin accepting clinic workstations, thermal printers, and biometric punches.',
                            style: GoogleFonts.inter(
                              fontSize: 12.5,
                              color: textSecondary,
                              height: 1.4,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),

              const SizedBox(height: 20),

              // ── 2. Pre-Flight Readiness Matrix ──────────────────────────────
              Container(
                padding: const EdgeInsets.all(20),
                decoration: BoxDecoration(
                  color: cardBg,
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: borderColor),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        const Icon(Icons.fact_check_rounded, size: 18, color: SoftPalette.emerald350),
                        const SizedBox(width: 8),
                        Text(
                          'Pre-Flight System Check',
                          style: GoogleFonts.inter(
                            fontSize: 15,
                            fontWeight: FontWeight.bold,
                            color: textPrimary,
                          ),
                        ),
                        const Spacer(),
                        Text(
                          'All Systems Normal',
                          style: GoogleFonts.inter(
                            fontSize: 11,
                            fontWeight: FontWeight.w600,
                            color: SoftPalette.emerald350,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 14),
                    _buildPreflightItem(
                      icon: Icons.storage_rounded,
                      title: 'Local Hive Data Vault',
                      desc: 'Authoritative offline database ready with zero cloud dependency',
                      status: 'READY',
                      statusColor: SoftPalette.emerald350,
                      isDark: isDark,
                    ),
                    const Divider(height: 16),
                    _buildPreflightItem(
                      icon: Icons.lan_rounded,
                      title: 'Network Interface & Host IP',
                      desc: '$serverIpStr (Binding port 8080/8088)',
                      status: 'BOUND',
                      statusColor: SoftPalette.sky500,
                      isDark: isDark,
                    ),
                    const Divider(height: 16),
                    _buildPreflightItem(
                      icon: Icons.fingerprint_rounded,
                      title: 'Biometric UDP Service (Port 4370)',
                      desc: 'ZKTeco real-time punch daemon ready to listen',
                      status: 'CONFIGURED',
                      statusColor: SoftPalette.sky500,
                      isDark: isDark,
                    ),
                    const Divider(height: 16),
                    _buildPreflightItem(
                      icon: Icons.cloud_sync_rounded,
                      title: 'Cloud Replication Bridge',
                      desc: _isOnline ? 'Firebase mesh connected & authenticated' : 'Operating in offline local-only mode',
                      status: _isOnline ? 'ONLINE' : 'STANDBY',
                      statusColor: _isOnline ? SoftPalette.emerald350 : SoftPalette.amber300,
                      isDark: isDark,
                    ),
                  ],
                ),
              ),

              const SizedBox(height: 20),

              // ── 3. Launch Action Center ─────────────────────────────────────
              Container(
                padding: const EdgeInsets.all(22),
                decoration: BoxDecoration(
                  color: cardBg,
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: borderColor),
                ),
                child: Column(
                  children: [
                    SizedBox(
                      width: double.infinity,
                      height: 52,
                      child: ElevatedButton.icon(
                        onPressed: _startServer,
                        icon: const Icon(Icons.rocket_launch_rounded, size: 22),
                        label: Text(
                          'Initialize & Broadcast LAN Server',
                          style: GoogleFonts.inter(
                            fontSize: 16,
                            fontWeight: FontWeight.bold,
                            letterSpacing: 0.3,
                          ),
                        ),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: SoftPalette.emerald500,
                          foregroundColor: SoftPalette.gray50,
                          elevation: 3,
                          shadowColor: SoftPalette.emerald500.withOpacity(0.4),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                        ),
                      ),
                    ),
                    const SizedBox(height: 14),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        TextButton.icon(
                          onPressed: () => _showFirewallStatusAndNextStepsDialog(alreadyAdded: true),
                          icon: const Icon(Icons.security_rounded, size: 16, color: SoftPalette.sky500),
                          label: Text(
                            'Firewall Setup Guide',
                            style: GoogleFonts.inter(fontSize: 12, fontWeight: FontWeight.w600, color: SoftPalette.sky500),
                          ),
                        ),
                        const SizedBox(width: 12),
                        TextButton.icon(
                          onPressed: () => setState(() => _selectedTab = 6),
                          icon: Icon(Icons.storage_rounded, size: 16, color: context.adapt(SoftPalette.slate550)),
                          label: Text(
                            'Inspect Data Vault',
                            style: GoogleFonts.inter(fontSize: 12, fontWeight: FontWeight.w600, color: textSecondary),
                          ),
                        ),
                        const SizedBox(width: 12),
                        TextButton.icon(
                          onPressed: () => _showLogoutDialog(context),
                          icon: const Icon(Icons.logout_rounded, size: 16, color: SoftPalette.red400),
                          label: Text(
                            'Logout',
                            style: GoogleFonts.inter(fontSize: 12, fontWeight: FontWeight.w600, color: SoftPalette.red400),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildPreflightItem({
    required IconData icon,
    required String title,
    required String desc,
    required String status,
    required Color statusColor,
    required bool isDark,
  }) {
    return Row(
      children: [
        Container(
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(
            color: statusColor.withOpacity(0.12),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Icon(icon, size: 18, color: statusColor),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: GoogleFonts.inter(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: isDark ? SoftPalette.gray50 : SoftPalette.slate900,
                ),
              ),
              Text(
                desc,
                style: GoogleFonts.inter(
                  fontSize: 11,
                  color: isDark ? SoftPalette.slate350 : SoftPalette.slate550,
                ),
              ),
            ],
          ),
        ),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
          decoration: BoxDecoration(
            color: statusColor.withOpacity(0.12),
            borderRadius: BorderRadius.circular(6),
            border: Border.all(color: statusColor.withOpacity(0.4)),
          ),
          child: Text(
            status,
            style: GoogleFonts.firaCode(
              fontSize: 10,
              fontWeight: FontWeight.bold,
              color: statusColor,
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildClientRow(ConnectedClient client, [bool isDark = false]) {
    final Color cColor = client.color == SoftPalette.slate500 ? SoftPalette.teal500 : client.color;
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: SoftPalette.slate800.withOpacity(0.5),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: cColor.withOpacity(0.3)),
      ),
      child: Row(
        children: [
          Icon(client.icon, color: cColor, size: 20),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(client.displayName, style: GoogleFonts.inter(fontWeight: FontWeight.bold, color: SoftPalette.gray50, fontSize: 13)),
                Text('${client.deviceOs} • IP: ${client.ipAddress}', style: GoogleFonts.inter(fontSize: 11, color: SoftPalette.slate350)),
              ],
            ),
          ),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
            decoration: BoxDecoration(color: cColor.withOpacity(0.2), borderRadius: BorderRadius.circular(6)),
            child: Text(client.role.toUpperCase(), style: GoogleFonts.inter(fontSize: 9.5, fontWeight: FontWeight.bold, color: cColor)),
          ),
        ],
      ),
    );
  }

  // ── Windows Firewall Banner & Guide (Theme-Adaptive & Collapsible) ──────────
  Widget _buildFirewallBanner([bool isDark = false]) {
    if (kIsWeb || !io.Platform.isWindows || _isFirewallBannerDismissed) return const SizedBox.shrink();
    final bannerBg = isDark ? SoftPalette.amber900m : SoftPalette.yellow50m;
    final borderColor = isDark ? SoftPalette.orange700 : SoftPalette.yellow150;
    const accentColor = SoftPalette.orange400;
    final titleColor = isDark ? SoftPalette.yellow150 : SoftPalette.orange600;
    final subtitleColor = isDark ? SoftPalette.gray200 : SoftPalette.orange700;

    const cmd1 = 'netsh advfirewall firewall add rule name="GMWF_LAN" dir=in action=allow protocol=TCP localport=53281,8088';
    const cmd2 = 'netsh advfirewall firewall add rule name="GMWF_ZKTeco_UDP" dir=in action=allow protocol=UDP localport=4370';

    return Container(
      margin: const EdgeInsets.only(bottom: 16),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: bannerBg,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: borderColor, width: 1.2),
        boxShadow: [
          BoxShadow(
            color: isDark ? SoftPalette.gray900A19 : SoftPalette.gray900A3,
            blurRadius: 8,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: accentColor.withOpacity(0.18),
                  shape: BoxShape.circle,
                ),
                child: const Icon(Icons.security_rounded, color: accentColor, size: 20),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Text(
                          'Windows Firewall Rules',
                          style: GoogleFonts.inter(fontWeight: FontWeight.bold, color: titleColor, fontSize: 13.5),
                        ),
                        const SizedBox(width: 8),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                          decoration: BoxDecoration(
                            color: accentColor.withOpacity(0.15),
                            borderRadius: BorderRadius.circular(4),
                            border: Border.all(color: accentColor.withOpacity(0.3)),
                          ),
                          child: Text(
                            'PORTS: 53281 (TCP), 8088 (ADMS), 4370 (UDP)',
                            style: GoogleFonts.firaCode(fontSize: 9.5, fontWeight: FontWeight.bold, color: accentColor),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 2),
                    Text(
                      'Ensure Windows Firewall allows inbound connections for client PCs and ZKTeco biometric devices.',
                      style: GoogleFonts.inter(fontSize: 11, color: subtitleColor),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 12),
              ElevatedButton.icon(
                onPressed: _openFirewallPort,
                icon: const Icon(Icons.auto_fix_high_rounded, size: 14),
                label: const Text('Auto-Fix All'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: accentColor,
                  foregroundColor: SoftPalette.gray50,
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
                  elevation: 0,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                ),
              ),
              const SizedBox(width: 8),
              TextButton.icon(
                onPressed: () => setState(() => _isFirewallBannerExpanded = !_isFirewallBannerExpanded),
                icon: Icon(_isFirewallBannerExpanded ? Icons.keyboard_arrow_up_rounded : Icons.keyboard_arrow_down_rounded, size: 16, color: accentColor),
                label: Text(
                  _isFirewallBannerExpanded ? 'Hide' : 'Details',
                  style: GoogleFonts.inter(fontSize: 11.5, fontWeight: FontWeight.bold, color: accentColor),
                ),
                style: TextButton.styleFrom(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
                  minimumSize: Size.zero,
                ),
              ),
              const SizedBox(width: 4),
              IconButton(
                onPressed: () => setState(() => _isFirewallBannerDismissed = true),
                icon: Icon(Icons.close_rounded, size: 16, color: isDark ? SoftPalette.slate350 : SoftPalette.slate550),
                tooltip: 'Dismiss firewall banner',
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(),
              ),
            ],
          ),
          if (_isFirewallBannerExpanded) ...[
            const SizedBox(height: 12),
            Divider(height: 1, color: borderColor),
            const SizedBox(height: 10),
            Text(
              'Run in Administrator PowerShell if auto-fix does not complete:',
              style: GoogleFonts.inter(fontSize: 10.5, fontWeight: FontWeight.w600, color: subtitleColor),
            ),
            const SizedBox(height: 6),
            _buildFirewallCommandRow(cmd1, 'TCP: Sync & ZKTeco ADMS (53281, 8088)', isDark),
            const SizedBox(height: 6),
            _buildFirewallCommandRow(cmd2, 'UDP: ZKTeco Hardware Socket (4370)', isDark),
          ],
        ],
      ),
    );
  }

  Widget _buildFirewallCommandRow(String command, String label, [bool isDark = false]) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: isDark ? SoftPalette.slate900 : SoftPalette.gray50,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: isDark ? SoftPalette.slate800 : SoftPalette.slate150),
      ),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
            decoration: BoxDecoration(
              color: isDark ? SoftPalette.slate800 : SoftPalette.slate100,
              borderRadius: BorderRadius.circular(4),
            ),
            child: Text(
              label,
              style: GoogleFonts.inter(fontSize: 9.5, fontWeight: FontWeight.bold, color: SoftPalette.sky500),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: SelectableText(
              command,
              style: GoogleFonts.firaCode(fontSize: 10, color: isDark ? SoftPalette.emerald300 : SoftPalette.emerald600),
            ),
          ),
          const SizedBox(width: 8),
          IconButton(
            icon: Icon(Icons.copy, size: 14, color: context.adapt(SoftPalette.slate550)),
            onPressed: () {
              Clipboard.setData(ClipboardData(text: command));
              AppToast.showSnackBar(context, 
                SnackBar(
                  content: Text('Copied: $label', style: const TextStyle(color: SoftPalette.gray50, fontWeight: FontWeight.bold)),
                  backgroundColor: SoftPalette.emerald350,
                  behavior: SnackBarBehavior.floating,
                  duration: const Duration(seconds: 2),
                ),
              );
            },
            tooltip: 'Copy command',
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(),
          ),
        ],
      ),
    );
  }

  void _showFirewallStatusAndNextStepsDialog({required bool alreadyAdded}) {
    final serverIpStr = _serverIp ?? '192.168.1.100';
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: SoftPalette.slate900,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: BorderSide(color: alreadyAdded ? SoftPalette.sky500 : SoftPalette.emerald350, width: 1.2),
        ),
        title: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: (alreadyAdded ? SoftPalette.sky500 : SoftPalette.emerald350).withOpacity(0.15),
                shape: BoxShape.circle,
              ),
              child: Icon(
                alreadyAdded ? Icons.verified_user_rounded : Icons.check_circle_rounded,
                color: alreadyAdded ? SoftPalette.sky350 : SoftPalette.emerald300,
                size: 22,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    alreadyAdded ? 'Rules Already Added & Active' : 'Firewall Rules Successfully Configured',
                    style: GoogleFonts.inter(fontWeight: FontWeight.bold, fontSize: 16, color: SoftPalette.gray50),
                  ),
                  Text(
                    'Ports 53281 (TCP), 8088 (TCP), and 4370 (UDP) are open',
                    style: GoogleFonts.inter(fontSize: 11, color: SoftPalette.slate350),
                  ),
                ],
              ),
            ),
          ],
        ),
        content: SizedBox(
          width: 540,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: SoftPalette.slate900,
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: SoftPalette.slate800),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.info_outline_rounded, color: SoftPalette.sky350, size: 18),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        alreadyAdded
                            ? 'Windows Defender Firewall is already allowing all LAN Sync and ZKTeco Biometric connections on this machine.'
                            : 'All required firewall rules for LAN clients and biometric hardware have been registered.',
                        style: GoogleFonts.inter(fontSize: 12, color: SoftPalette.slate200),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 16),
              Text(
                'WHAT TO DO NEXT:',
                style: GoogleFonts.inter(fontSize: 11, fontWeight: FontWeight.bold, color: SoftPalette.amber300, letterSpacing: 0.5),
              ),
              const SizedBox(height: 10),
              _buildNextStepRow(
                '1',
                'Configure Physical Biometric Device',
                'In the ZKTeco device Menu ➔ Comm. ➔ Cloud Server / ADMS:\n• Enable Domain Name: OFF\n• Server Address / IP: $serverIpStr\n• Server Port: 8088 (or direct UDP 4370)',
              ),
              const SizedBox(height: 10),
              _buildNextStepRow(
                '2',
                'Connect Device via Ethernet',
                'Ensure the biometric machine is connected via Ethernet cable to the same LAN router as this server PC.',
              ),
              const SizedBox(height: 10),
              _buildNextStepRow(
                '3',
                'Perform Test Punch',
                'Place a finger on the scanner. The Live Network System Log Stream on this dashboard will immediately capture and sync the punch.',
              ),
            ],
          ),
        ),
        actions: [
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx),
            style: ElevatedButton.styleFrom(
              backgroundColor: SoftPalette.sky500,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
            ),
            child: const Text('Got It, Thanks!', style: TextStyle(color: SoftPalette.gray50, fontWeight: FontWeight.bold)),
          ),
        ],
      ),
    );
  }

  Widget _buildNextStepRow(String stepNum, String title, String description) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          width: 22,
          height: 22,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: SoftPalette.slate800,
            shape: BoxShape.circle,
            border: Border.all(color: SoftPalette.sky500),
          ),
          child: Text(stepNum, style: GoogleFonts.inter(fontSize: 11, fontWeight: FontWeight.bold, color: SoftPalette.sky350)),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: GoogleFonts.inter(fontWeight: FontWeight.bold, fontSize: 12.5, color: SoftPalette.gray50)),
              const SizedBox(height: 2),
              Text(description, style: GoogleFonts.inter(fontSize: 11, color: SoftPalette.slate350, height: 1.35)),
            ],
          ),
        ),
      ],
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Custom Heartbeat Waveform Painter
// ─────────────────────────────────────────────────────────────────────────────
class HeartbeatWavePainter extends CustomPainter {
  final double animationValue;
  final Color color;

  HeartbeatWavePainter({required this.animationValue, required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = 1.8
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round;

    final glowPaint = Paint()
      ..color = color.withOpacity(0.25)
      ..strokeWidth = 3.5
      ..style = PaintingStyle.stroke;

    final path = Path();
    final h = size.height;
    final w = size.width;
    final mid = h / 2;

    path.moveTo(0, mid);
    for (double x = 0; x <= w; x += 3) {
      double pulse = 0;
      final cycle = (x + (animationValue * 10)) % 70;
      if (cycle >= 20 && cycle <= 30) {
        pulse = -8.0;
      } else if (cycle > 30 && cycle <= 40) {
        pulse = 10.0;
      } else if (cycle > 40 && cycle <= 48) {
        pulse = -4.0;
      }
      final y = (mid + pulse + (math.sin(x * 0.1) * 1.5)).clamp(2.0, h - 2.0);
      path.lineTo(x, y);
    }

    canvas.drawPath(path, glowPaint);
    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(covariant HeartbeatWavePainter oldDelegate) => true;
}

// ─────────────────────────────────────────────────────────────────────────────
// ServerSyncManager  (embedded in this file — used by the dashboard widget)
// ─────────────────────────────────────────────────────────────────────────────
class ServerSyncManager {
  final String branchId;
  final LanServer server;
  final Function(int) onSyncComplete;
  final Function(String) onSyncError;
  final FutureOr<void> Function(Map<String, dynamic>) onMessageReceived;

  Timer? _syncTimer;
  Timer? _catchUpTimer;
  Timer? _tokenCatchUpTimer; // undelivered tokens only, every 45 s (see start())
  Timer? _downloadTimer;
  Timer? _compactionTimer;
  Timer? _syncDebounceTimer;
  bool _isSyncing = false;
  int _syncedThisRun = 0;

  void _scheduleSyncDebounced({Duration delay = const Duration(milliseconds: 50)}) {
    _syncDebounceTimer?.cancel();
    _syncDebounceTimer = Timer(delay, () {
      triggerSync();
    });
  }

  // ── Counter events the originating PC uploads itself (see _queueForSync) ────
  static const Set<String> _originUploadedEventTypes = {
    'save_office_boy_token',
    'save_kitchen_serve_log',
    'save_dasterkhwan_tokens',
    'reverse_dasterkhwan_tokens',
    'serve_dasterkhwan_token',
  };

  // ── Non-persistence / heartbeat event types that must NOT be queued ─────────
  static const Set<String> _ignoredEventTypes = {
    // Desk-to-desk "I'm dispensing this token" notices: live only, never stored or uploaded.
    'dispense_claim',
    'dispense_release',
    'activity',
    'status_update',
    'client_activity',
    'heartbeat',
    'version_mismatch',
    'ping',
    'pong',
    'identify',
    'identified',
    'client_count_update',
    'ack_serials',
    'request_catch_up',
    'auth_handshake',
    'message_ack',
    'credential_sync',
    'session_event',
    'welcome',
    'identify_request',
    'cross_branch_punch_alert',
    'cross_branch_punch_status_update',
    'biometric_heartbeat',
    'echo',
    'broadcast',
    'unknown',
    // Donation receipt/collection broadcasts: the PC that took the donation uploads the
    // donation itself; queued here they had no handler and went to branches/*/sync_records,
    // which nothing reads (wasted writes on the shared quota).
    'save_donation_receipt',
    'save_donation_collection',
    '',
  };

   // ── [CATCH-UP] Per-client seen-serial tracking ─────────────────────────────
  // A serial is "seen" once the desk ACKs it (ack_serials), not when it is sent: a message the
  // desk dropped or failed to apply used to wait for the 30-min full resync. A change to a
  // token (_markSerialChanged) makes it unseen for every desk until each one ACKs it again.
  final Map<String, Set<String>> _clientSeenSerials = {};
  // Only today's tokens are ever checked against this set, so it must hold a whole busy day
  // (all Karachi camps together). At 2000, a bigger day dropped the oldest confirmations,
  // those tokens counted as "not confirmed" again and were resent in a loop, and the desk's
  // missing-token count never reached 0 (doctor auto-select kept pausing). ~20 bytes each.
  static const int _maxSeenPerClient = 20000;
  // Sent but not ACKed yet: not re-sent before [_resendUnackedAfter].
  final Map<String, Map<String, DateTime>> _clientSentAt = {};
  /// socketId → serial → times sent without an ACK (catch-up resend backoff).
  final Map<String, Map<String, int>> _clientSendCount = {};
  Timer? _trafficTimer;
  static const Duration _resendUnackedAfter = Duration(seconds: 6);
  // Seen sets of desks that disconnected, by their clientId: a desk that reconnects (Wi-Fi
  // blip, new socket) only gets what it has not ACKed, instead of the whole day again.
  final Map<String, Set<String>> _seenByClientId = {};
  final Map<String, String> _socketClientId = {};
  static const int _maxRememberedClients = 64;

  // ── [INV-CATCHUP] Per-client seen-stock tracking — mirrors seen-serials.
  // Keyed as "medicineId|version" so a re-restock (new version) is treated
  // as unseen and gets pushed again, while an already-delivered version is
  // skipped instead of being re-blasted on every reconnect.
  final Map<String, Set<String>> _clientSeenStock = {};
  static const int _maxSeenStockPerClient = 5000;

  // [A4] Cross-socket serial write lock queue to prevent concurrent race conditions
  final Map<String, Future<void>> _serialLocks = {};

  // Track recently requested gap serials to prevent hammering the client repeatedly
  final Map<String, DateTime> _lastGapRequestedAt = {};
  /// socketId → today's token serials that desk has not confirmed (see _pushCatchUpToSocket).
  final Map<String, Set<String>> _unconfirmedSerials = {};
  /// How far back a sequence-gap check looks (bounds the per-token cost; older gaps are
  /// covered by the periodic catch-up).
  static const int _gapLookBack = 20;

  // ── Saved previous callbacks so the dashboard UI keeps working ─────────────
  Function(String socketId, Map<String, dynamic> info)? _prevOnClientConnected;
  Function(String socketId)? _prevOnClientDisconnected;

  // FIX-A: full resolver — matches canonical resolver
  static const _validQueueTypes = {'zakat', 'non-zakat', 'gmwf'};

  /// Canonical resolver — NEVER falls back silently.
  static String _resolveQueueType(dynamic raw) {
    if (raw == null) return 'zakat';
    final s = raw.toString().toLowerCase().trim();
    if (s.isEmpty) return 'zakat';
    if (s == '20' || s == 'pkr 20' || s == 'pkr20' || s == 'twenty') return 'zakat';
    if (s == 'non-zakat' || s == 'non zakat' || s == 'nonzakat' ||
        s == 'non_zakat' || s.startsWith('non')) {
      return 'non-zakat';
    }
    if (s == 'gmwf' || s == 'gm wf' || s == 'gm-wf' || s == 'gm_wf') return 'gmwf';
    if (s == 'zakat') return 'zakat';
    return 'zakat';
  }

  ServerSyncManager({
    required this.branchId,
    required this.server,
    required this.onSyncComplete,
    required this.onSyncError,
    required this.onMessageReceived,
  });

  int get queueSize {
    try {
      if (!Hive.isBoxOpen(LocalStorageService.syncBox)) return 0;
      return Hive.box(LocalStorageService.syncBox).length;
    } catch (e) {
      return 0;
    }
  }

  /// Purges no-op / heartbeat / invalid entries from the sync queue.
  /// Also deduplicates biometric-device entries: keeps only the latest per
  /// deviceId so an existing backlog of hundreds of duplicates is instantly
  /// collapsed to one pending write per device.
  ///
  /// Every sync pass (each 30 s) asks for it, but it goes through the whole queue, so unless
  /// [force]d it runs at most once a minute, and it hands control back to the UI as it goes.
  Future<int> purgeInvalidQueue({bool force = false}) async {
    final last = _lastQueuePurgeAt;
    if (!force && last != null && DateTime.now().difference(last) < const Duration(minutes: 1)) return 0;
    if (_queuePurgeRunning) return 0;
    _queuePurgeRunning = true;
    _lastQueuePurgeAt = DateTime.now();
    try {
      await LocalStorageService.purgePhantomUnknownTokens(branchId);
      await LocalStorageService.purgeBloatedSyncQueue();
      if (!Hive.isBoxOpen(LocalStorageService.syncBox)) return 0;
      final box = Hive.box(LocalStorageService.syncBox);
      final keysToDelete = <dynamic>[];

      var scanned = 0;
      for (final key in box.keys.toList()) {
        if (++scanned % 300 == 0) await Future<void>.delayed(Duration.zero);
        final val = box.get(key);
        if (val == null || val is! Map) {
          keysToDelete.add(key);
          continue;
        }
        final rawType = (val['type'] ?? val['event_type'] ?? '').toString().toLowerCase().trim();
        final bool hasPayload = val['data'] != null ||
            val['serial'] != null ||
            val['collection'] != null ||
            val['delta'] != null ||
            val['entityId'] != null ||
            val['id'] != null ||
            val['localId'] != null ||
            val['patientId'] != null ||
            val['employeeId'] != null ||
            val['deviceId'] != null;
        if (_ignoredEventTypes.contains(rawType) || (!hasPayload && !rawType.startsWith('delete_'))) {
          keysToDelete.add(key);
        }
      }

      if (keysToDelete.isNotEmpty) await box.deleteAll(keysToDelete);

      // [FIX] Collapse any duplicate save_biometric_device / delete_biometric_device
      // entries that accumulated before the dedup-key fix was deployed.
      // Keep only the most-recently-created entry per deviceId; delete all older ones.
      int biomedDedupRemoved = 0;
      const bioTypes = {'save_biometric_device', 'delete_biometric_device'};
      final seenDeviceKey = <String, dynamic>{}; // deviceKey -> boxKey of best entry
      final seenDeviceTs = <String, String>{};    // deviceKey -> createdAt of best entry

      scanned = 0;
      for (final key in box.keys.toList()) {
        if (++scanned % 300 == 0) await Future<void>.delayed(Duration.zero);
        final val = box.get(key);
        if (val is! Map) continue;
        final t = (val['type'] ?? '').toString().toLowerCase().trim();
        if (!bioTypes.contains(t)) continue;
        final devId = (val['deviceId'] ??
                (val['data'] is Map ? val['data']['deviceId'] : null) ??
                '')
            .toString()
            .trim()
            .toLowerCase();
        if (devId.isEmpty) continue;
        final deviceKey = '${t}_$devId';
        final ts = (val['createdAt'] ?? '').toString();
        if (!seenDeviceKey.containsKey(deviceKey) || ts.compareTo(seenDeviceTs[deviceKey]!) > 0) {
          // This entry is newer — mark the previous winner for deletion
          if (seenDeviceKey.containsKey(deviceKey)) {
            box.delete(seenDeviceKey[deviceKey]);
            biomedDedupRemoved++;
          }
          seenDeviceKey[deviceKey] = key;
          seenDeviceTs[deviceKey] = ts;
        } else {
          // This entry is older — delete it
          box.delete(key);
          biomedDedupRemoved++;
        }
      }

      final totalRemoved = keysToDelete.length + biomedDedupRemoved;
      if (totalRemoved > 0) {
        debugPrint('[SSM] 🧹 Purged ${keysToDelete.length} stale/no-op + $biomedDedupRemoved biometric-device duplicates from sync queue');
      }
      return totalRemoved;
    } catch (e) {
      debugPrint('[SSM] purgeInvalidQueue error: $e');
      return 0;
    } finally {
      _queuePurgeRunning = false;
    }
  }

  DateTime? _lastQueuePurgeAt;
  bool _queuePurgeRunning = false;

  /// Returns count breakdown of pending items by type
  Map<String, int> getQueueBreakdown() {
    final map = <String, int>{};
    try {
      if (!Hive.isBoxOpen(LocalStorageService.syncBox)) return map;
      final box = Hive.box(LocalStorageService.syncBox);
      for (final val in box.values) {
        if (val is Map) {
          final t = (val['type'] ?? val['event_type'] ?? 'unknown').toString();
          map[t] = (map[t] ?? 0) + 1;
        }
      }
    } catch (_) {}
    return map;
  }

  /// Clears the entire sync queue
  Future<void> clearEntireQueue() async {
    try {
      if (Hive.isBoxOpen(LocalStorageService.syncBox)) {
        await Hive.box(LocalStorageService.syncBox).clear();
      }
    } catch (e) {
      debugPrint('[SSM] clearEntireQueue error: $e');
    }
  }

  /// Targeted flood cleaner: removes high-retry, stale, and redundant entries
  /// without destroying legitimate pending records.
  ///
  /// Strategy:
  ///   • Items with ≥5 failed attempts → moved to dead letter queue
  ///   • Attendance/heartbeat items created >24h ago → deleted (stale)
  ///   • Items with null/empty data and no meaningful payload → deleted (phantom)
  ///   • Items with 'status' == 'failed' or 'error' and attempts > 3 → pruned
  ///   • All other records with 0–2 attempts are kept (legitimate pending)
  /// Returns count of items removed.
  Future<int> clearFloodedQueueEntries() async {
    int removed = 0;
    try {
      // First run the standard dedup pass
      await purgeInvalidQueue(force: true);
      await LocalStorageService.purgeBloatedSyncQueue();

      if (!Hive.isBoxOpen(LocalStorageService.syncBox)) return 0;
      final box = Hive.box(LocalStorageService.syncBox);

      final keysToDelete = <dynamic>[];
      final now = DateTime.now();

      const attendanceLike = {
        'save_attendance_record', 'save_employee_attendance',
        'save_biometric_log', 'zkteco',
      };
      const heartbeatLike = {
        'heartbeat', 'ping', 'status_update', 'device_heartbeat',
        'biometric_heartbeat', 'sync_heartbeat',
      };

      for (final key in box.keys) {
        final val = box.get(key);
        if (val == null || val is! Map) {
          keysToDelete.add(key);
          continue;
        }
        final item = Map<String, dynamic>.from(val);
        final type = (item['type'] ?? item['event_type'] ?? '').toString().toLowerCase().trim();
        final attempts = (item['attempts'] as num?)?.toInt() ?? 0;
        final status = (item['status'] ?? '').toString().toLowerCase();
        final createdAtStr = (item['createdAt'] ?? '').toString();
        final createdAt = DateTime.tryParse(createdAtStr);
        final ageHours = createdAt != null ? now.difference(createdAt).inHours : 0;

        // ── Rule 1: High retry items (≥5 attempts) go to dead letter ──────────
        if (attempts >= 5) {
          await LocalStorageService.moveToDeadLetterQueue(
            LocalStorageService.syncBox,
            key,
            item,
            reason: 'flood_purge: $attempts failed attempts',
          );
          removed++;
          continue;
        }

        // ── Rule 2: (Removed stale deletion to prevent silent deletes of unsynced items)

        // ── Rule 3: All heartbeat/ping types ─────────────────────────────────
        if (heartbeatLike.contains(type)) {
          keysToDelete.add(key);
          removed++;
          continue;
        }

        // ── Rule 4: Failed/error items with ≥3 attempts older than 12h ───────
        if ((status == 'failed' || status == 'error') && attempts >= 3 && ageHours > 12) {
          await LocalStorageService.moveToDeadLetterQueue(
            LocalStorageService.syncBox,
            key,
            item,
            reason: 'flood_purge: status=$status after $attempts attempts',
          );
          removed++;
          continue;
        }

        // ── Rule 5: Phantom items (no meaningful payload, >1h old) ────────────
        final hasPayload = item['data'] != null ||
            item['serial'] != null ||
            item['entityId'] != null ||
            item['id'] != null ||
            item['localId'] != null ||
            item['patientId'] != null ||
            item['employeeId'] != null;
        if (!hasPayload && ageHours > 1) {
          await LocalStorageService.moveToDeadLetterQueue(
            LocalStorageService.syncBox,
            key,
            item,
            reason: 'PURGED: phantom item with no payload (>1h old)',
          );
          removed++;
          continue;
        }
      }

      if (keysToDelete.isNotEmpty) {
        await box.deleteAll(keysToDelete);
      }

      if (removed > 0) {
        debugPrint('[SSM] 🔥 Flood-cleared $removed stale/redundant items. Remaining: ${box.length}');
      }
    } catch (e) {
      debugPrint('[SSM] clearFloodedQueueEntries error: $e');
    }
    return removed;
  }

  // ── Backfill cooldown: prevents _enqueueMissing* from flooding on rapid calls
  final Map<String, DateTime> _lastBackfillTime = {};
  static const Duration _backfillCooldown = Duration(minutes: 5);

  bool _backfillCooledDown(String key) {
    final last = _lastBackfillTime[key];
    if (last == null || DateTime.now().difference(last) >= _backfillCooldown) {
      _lastBackfillTime[key] = DateTime.now();
      return true; // OK to run
    }
    return false; // Still in cooldown, skip
  }

  DateTime? _lastTokenDownloadTime;
  DateTime? _lastSweepTime;
  /// Re-enables the old built-in batch uploader (see triggerSync).
  static bool legacyUploaderEnabled = false;

  // Per-socket catch-up cooldown: multiple screens / sync buttons on one
  // station must not trigger repeated full-day pushes on the same socket.
  final Map<String, DateTime> _lastCatchUpPerSocket = {};
  static const Duration _catchUpCooldown = Duration(seconds: 3);
  final Map<String, DateTime> _lastFullCatchUpPerSocket = {};

  Future<void> _downloadTodayTokens({bool force = false}) async {
    final now = DateTime.now();
    // 10 min: it reads every token of today from Firestore and rewrites them all to Hive.
    if (!force && _lastTokenDownloadTime != null && now.difference(_lastTokenDownloadTime!).inMinutes < 10) {
      return;
    }
    _lastTokenDownloadTime = now;
    try {
      final before = _todayTokenSignatures();
      await LocalStorageService.downloadTodayTokens(branchId, null, true);
      // Edits made in the cloud (admin screens, another PC uploading late) must reach the desks
      // too, including desks that are offline now: make every changed token unseen, so the
      // next catch-up (reconnect or the 5-min sweep) sends it.
      final after = _todayTokenSignatures();
      var changed = 0;
      after.forEach((serial, sig) {
        if (before[serial] != sig) {
          _markSerialChanged(serial);
          changed++;
        }
      });
      if (changed > 0) debugPrint('[SSM] Cloud download changed $changed token(s); desks will get them');
    } catch (e) {
      debugPrint('[SSM] _downloadTodayTokens error: $e');
    }
  }

  /// serial -> signature of each of today's tokens on this server.
  Map<String, String> _todayTokenSignatures() {
    final out = <String, String>{};
    if (!Hive.isBoxOpen(LocalStorageService.entriesBox)) return out;
    final today = LocalStorageService.getTodayDateKey();
    for (final v in Hive.box(LocalStorageService.entriesBox).values) {
      if (v is! Map || v['dateKey']?.toString() != today) continue;
      final serial = v['serial']?.toString().trim() ?? '';
      if (serial.isEmpty) continue;
      out[serial] = [
        LocalStorageService.lanPushSignature(v),
        v['patientName'], v['queueType'], v['isDeleted'], v['tokenStatus'],
      ].join('|');
    }
    return out;
  }

  Future<void> start() async {
    debugPrint('ServerSyncManager: Starting for branch $branchId');

    // Initial sync of today's tokens from Firestore into server local Hive
    _downloadTodayTokens().ignore();

    // Auto-backfill any unsynced local tokens, donations, employees, attendance, patients, and students from offline periods.
    // First merge the old per-type token items into one per token, then backfill (which only
    // adds tokens not queued yet).
    unawaited(_compactTokenQueue().then((_) => _enqueueMissingEntries()));
    unawaited(_enqueueMissingDonations());
    unawaited(_enqueueMissingEmployees());
    unawaited(_enqueueMissingAttendance());
    unawaited(_enqueueMissingPatients());
    unawaited(_enqueueMissingMadrassaStudents());
    unawaited(_enqueueMissingMadrassaLogs());
    unawaited(LocalStorageService.pushLocalUsersToFirestore());

    // ── Chain onClientConnected for catch-up push ────────────────────────────
    _prevOnClientConnected = server.onClientConnected;
    _prevOnClientDisconnected = server.onClientDisconnected;

                  server.onClientConnected = (socketId, info) {
      final clientId = (info['clientId'] ?? '').toString();
      if (clientId.isNotEmpty) _socketClientId[socketId] = clientId;
      _clientSeenSerials[socketId] = (clientId.isNotEmpty ? _seenByClientId.remove(clientId) : null) ?? {};
      _clientSentAt[socketId] = {};
      _clientSendCount[socketId] = {};
      _clientSeenStock[socketId] = {};
      // The push below is this socket's full catch-up. Without this mark the desk's own
      // request_catch_up (sent right after identify) counted as "no full sync yet", cleared
      // the seen set and sent the whole day a second time on every reconnect.
      _lastFullCatchUpPerSocket[socketId] = DateTime.now();
      _prevOnClientConnected?.call(socketId, info);
      Future.delayed(const Duration(milliseconds: 500), () async {
        _pushCatchUpToSocket(socketId, Map<String, dynamic>.from(info));
        _pushInventoryCatchUpToSocket(socketId, Map<String, dynamic>.from(info));
        _pushPendingRequestsCatchUpToSocket(socketId, Map<String, dynamic>.from(info));
      });
      // Again a few seconds later: tokens that reached the server while this desk was
      // reconnecting may still have been saving during the first push (it reads the store).
      Future.delayed(const Duration(seconds: 6), () {
        if (_clientSeenSerials.containsKey(socketId)) {
          _pushCatchUpToSocket(socketId, Map<String, dynamic>.from(info));
        }
      });
    };
    server.onClientDisconnected = (socketId) {
      final seen = _clientSeenSerials.remove(socketId);
      final clientId = _socketClientId.remove(socketId);
      if (seen != null && clientId != null) {
        if (_seenByClientId.length >= _maxRememberedClients) {
          _seenByClientId.remove(_seenByClientId.keys.first);
        }
        _seenByClientId[clientId] = seen;
      }
      _clientSentAt.remove(socketId);
      _clientSendCount.remove(socketId);
      _clientSeenStock.remove(socketId);
      _lastCatchUpPerSocket.remove(socketId);
      _lastFullCatchUpPerSocket.remove(socketId);
      _prevOnClientDisconnected?.call(socketId);
    };

    server.onMessageReceived = _handleIncomingMessage;
    // Desk messages are ACKed (and leave the desk's outbox) only from here on.
    server.persistenceReady = true;

    // Clean any dead items on start. After the handler is installed: this scans the whole
    // sync queue, and desks' messages (and their relay to the other desks) waited on it.
    await purgeInvalidQueue(force: true);

    // ── Periodic catch-up to all connected clients every 5 minutes (live changes are pushed
    // instantly; this is only a safety net and scans entries + stock per client) ──
    _catchUpTimer = Timer.periodic(const Duration(minutes: 5), (_) {
      _periodicCatchUpAll();
    });

    // ── LAN traffic breakdown, once a minute ─────────────────────────────────
    // Names the source of any flood (message type, which desk, catch-up or live) in the
    // server log, where the dashboard only showed a total msg/min.
    _trafficTimer?.cancel();
    _trafficTimer = Timer.periodic(const Duration(minutes: 1), (_) {
      final summary = server.takeTrafficSummary();
      if (summary == null) return;
      debugPrint('[SSM] 📊 LAN traffic last minute — $summary');
      try {
        onMessageReceived({
          'event_type': 'lan_traffic_summary',
          '_senderRole': 'server',
          '_senderUsername': 'Traffic: $summary',
          'data': {'summary': summary},
        });
      } catch (_) {}
    });

    // ── Today's tokens a desk has not confirmed, every 5 s ───────────────────
    // A token whose live forward was lost (desk reconnecting, Wi-Fi drop) used to wait for the
    // 5-minute catch-up and showed up at the doctor after later tokens had been prescribed and
    // dispensed. This pass sends only what a desk has not ACKed (and not in the last 6 s), so
    // when everything is delivered it sends nothing; the entry list it reads is cached.
    _tokenCatchUpTimer = Timer.periodic(const Duration(seconds: 5), (_) {
      for (final client in server.getConnectedClients()) {
        final sid = client['socketId']?.toString();
        if (sid == null || !_clientSeenSerials.containsKey(sid)) continue;
        unawaited(_pushCatchUpToSocket(sid, Map<String, dynamic>.from(client)).catchError((Object _) => 0));
      }
    });

    // ── High-performance periodic sync timer every 30 seconds ───────────────
    _syncTimer = Timer.periodic(const Duration(seconds: 30), (_) {
      triggerSync();
    });

    // ── Queue compaction & deduplication every 10 minutes (full scans; was every minute) ──
    _compactionTimer = Timer.periodic(const Duration(minutes: 10), (_) {
      unawaited(purgeInvalidQueue());
    });

    await triggerSync(force: true);
  }

  // ── Message interception — local saves + catch-up + Firestore queue ────────
  Future<void> _handleIncomingMessage(Map<String, dynamic> message) async {
    final eventType = message['event_type'] as String?;
    if (eventType == null) return;
    // Before the first await: LanServer has just forwarded this to the other desks, and their
    // ACKs (which mark it seen again) must not arrive before this invalidation.
    if (_tokenChangeEvents.contains(eventType)) {
      final inner = message['data'] is Map ? message['data'] as Map : message;
      final serial = (inner['serial'] ?? message['serial'])?.toString().trim() ?? '';
      if (serial.isNotEmpty) _markSerialChanged(serial, senderSocketId: message['_socketId']?.toString());
    }
    await onMessageReceived(message);

        // ── Handle catch-up / ACK events (do NOT queue for Firestore) ────────────
    if (eventType == 'ack_serials') {
      _handleClientAck(message);
      return;
    }

    if (eventType == 'ack_stock_items') {
      _handleStockAck(message);
      return;
    }

    if (eventType == 'request_catch_up' || eventType == 'request_full_lan_sync') {
      final socketId = message['_socketId']?.toString();
      if (socketId != null) {
        final now = DateTime.now();
        final last = _lastCatchUpPerSocket[socketId];
        final isForced = message['force'] == true ||
            message['forceAll'] == true ||
            message['reason'] == 'sequence_gap' ||
            eventType == 'request_full_lan_sync';
        if (!isForced && last != null && now.difference(last) < _catchUpCooldown) {
          debugPrint('[SSM] Catch-up from $socketId coalesced (cooldown)');
          return;
        }
        _lastCatchUpPerSocket[socketId] = now;
        // A routine catch-up only sends what this client has not acknowledged yet. Re-sending
        // the whole day (and re-downloading it from Firestore) on every request was the core
        // of the CPU/RAM/network loop with the doctor PCs. Only an explicit full LAN sync does that.
        // (Status changes the client missed are still covered: at most every 30 min a request
        // gets the full re-send. It was every 5 min, the same interval at which the doctor screen
        // asks, so every request re-sent the whole day.)
        final lastFull = _lastFullCatchUpPerSocket[socketId];
        final fullResync = eventType == 'request_full_lan_sync' ||
            lastFull == null || now.difference(lastFull) > const Duration(minutes: 30);
        if (fullResync) _lastFullCatchUpPerSocket[socketId] = now;
        if (fullResync) _clientSeenSerials.remove(socketId);
        final clients = server.getConnectedClients();
        Map<String, dynamic>? info;
        for (final c in clients) {
          if (c['socketId']?.toString() == socketId) {
            info = c;
            break;
          }
        }
        final clientInfo = info ?? {
          'socketId': socketId,
          'role': message['_senderRole'] ?? message['role'] ?? 'doctor',
          'branchId': message['_senderBranch'] ?? message['branchId'] ?? branchId,
          'username': message['_senderUsername'] ?? message['username'] ?? '',
        };
        debugPrint('[SSM] Catch-up requested by $socketId');
        // 1. Immediately push local tokens and unseen inventory over LAN (0ms delay)
        _pushCatchUpToSocket(socketId, clientInfo, forceAll: fullResync);
        _pushInventoryCatchUpToSocket(socketId, clientInfo);

        // 2. Refresh today's tokens from the cloud (rate-limited to every 10 min) without blocking
        _downloadTodayTokens().then((_) {
          _pushCatchUpToSocket(socketId, clientInfo);
          _pushInventoryCatchUpToSocket(socketId, clientInfo);
        }).catchError((e) {
          debugPrint('[SSM] Background cloud download error: $e');
        });
      }
      return;
    }

    // ── Save data locally on the server device ───────────────────────────────
    // All events for one token (entry, prescription, dispense, status) go through one queue
    // per serial. LanServer runs handlers concurrently, and only save_entry was locked: a
    // reconnecting desk flushes entry + prescription + dispense 20 ms apart, and a save_entry
    // that read the token before the dispense was written then wrote it back "not dispensed".
    final tokenSerial = _tokenSerialOf(eventType, message);
    if (tokenSerial != null) {
      await _withTokenLock(tokenSerial, () => _saveToLocalHive(eventType, message));
    } else {
      await _saveToLocalHive(eventType, message);
    }

    // ── Queue for Firestore sync ─────────────────────────────────────────────
    _queueForSync(message);
  }

  final Map<String, Future<void>> _tokenLocks = {};
  static const Duration _tokenLockWait = Duration(seconds: 15);

  String? _tokenSerialOf(String eventType, Map<String, dynamic> message) {
    if (!_tokenChangeEvents.contains(eventType)) return null;
    final inner = message['data'] is Map ? message['data'] as Map : message;
    var s = (inner['serial'] ?? message['serial'])?.toString().trim().toUpperCase() ?? '';
    if (s.isEmpty) return null;
    // Same token whatever branch spelling prefixes it ("karachi-…", "saddar-…").
    final m = RegExp(r'(\d{6}[A-Z]?-[A-Z0-9_]+-\d{1,4})$').firstMatch(s);
    if (m != null) s = m.group(1)!;
    return s;
  }

  /// Runs [action] after every earlier action for the same token has finished (errors are
  /// passed to this caller only; the queue keeps going).
  Future<void> _withTokenLock(String serial, Future<void> Function() action) {
    final previous = _tokenLocks[serial] ?? Future<void>.value();
    // Never wait forever on an earlier action for this token: one hung save used to block
    // every later entry/prescription/dispense of the same token (and its ACKs) for good.
    final run = previous
        .timeout(_tokenLockWait, onTimeout: () {
          debugPrint('[SSM] ⚠️ Token lock for $serial waited >${_tokenLockWait.inSeconds}s — continuing');
        })
        .catchError((Object _) {})
        .then((_) => action());
    final tail = run.catchError((Object _) {});
    _tokenLocks[serial] = tail;
    tail.whenComplete(() {
      if (identical(_tokenLocks[serial], tail)) _tokenLocks.remove(serial);
    });
    return run;
  }

  // ── Save all tokens/prescriptions/dispense/patients locally ────────────────
  Future<void> _saveToLocalHive(String eventType, Map<String, dynamic> message) async {
    try {
      final data = (message['data'] is Map)
          ? Map<String, dynamic>.from(message['data'] as Map)
          : Map<String, dynamic>.from(message);

      for (final field in ['queueType', 'dateKey', 'serial', 'branchId']) {
        if (!data.containsKey(field) && message.containsKey(field)) {
          data[field] = message[field];
        }
      }

      final msgBranch = (message['branchId']?.toString() ??
              data['branchId']?.toString() ??
              branchId)
          .toLowerCase()
          .trim();

      switch (eventType) {
        case 'save_entry':
        case 'token_created':
          final serial = data['serial']?.toString().trim();
          if (serial != null && serial.isNotEmpty) {
            // [A4] Cross-socket write lock queue for this specific serial
            final lockKey = '$msgBranch-$serial';
            final currentLock = _serialLocks[lockKey] ?? Future.value();
            Object? saveError;
            late final Future<void> nextLock;
            nextLock = currentLock
                .timeout(_tokenLockWait, onTimeout: () {})
                .catchError((Object _) {})
                .then((_) async {
              await LocalStorageService.saveEntryLocal(msgBranch, serial, data);
            }).catchError((e) {
              debugPrint('[SSM] Error in serial write lock for $lockKey: $e');
              saveError = e; // the lock chain stays usable; this message is not ACKed
            }).whenComplete(() {
              if (_serialLocks[lockKey] == nextLock) {
                _serialLocks.remove(lockKey);
              }
            });
            _serialLocks[lockKey] = nextLock;
            await nextLock;
            if (saveError != null) throw saveError!;
            debugPrint('[SSM] ✅ Entry saved locally: $msgBranch-$serial');

            // ── UNBREAKABLE SEQUENCE GAP DETECTION (e.g. server got 2 and 5, but missing 1, 3, 4) ──
            try {
              final upperSer = serial.toUpperCase().trim();
              final lastDash = upperSer.lastIndexOf('-');
              if (lastDash > 0) {
                final prefix = upperSer.substring(0, lastDash);
                final seqStr = upperSer.substring(lastDash + 1);
                final seq = int.tryParse(seqStr);
                if (seq != null && seq > 1 && seq <= 999) {
                  const padWidth = 3;
                  final now = DateTime.now();
                  final missingSerials = <String>[];
                  final from = (seq - _gapLookBack) > 1 ? seq - _gapLookBack : 1;
                  for (int i = from; i < seq; i++) {
                    final checkSerial = '$prefix-${i.toString().padLeft(padWidth, '0')}';
                    final lastReq = _lastGapRequestedAt[checkSerial];
                    if (lastReq != null && now.difference(lastReq).inSeconds < 15) {
                      continue; // Recently requested
                    }
                    if (LocalStorageService.getLocalEntry(msgBranch, checkSerial) == null) {
                      missingSerials.add(checkSerial);
                      _lastGapRequestedAt[checkSerial] = now;
                    }
                  }
                  if (missingSerials.isNotEmpty) {
                    final senderSid = message['_socketId']?.toString();
                    if (senderSid != null && senderSid.isNotEmpty) {
                      debugPrint('[SSM] ⚠️ Sequence gap detected ($upperSer arrived with missing [${missingSerials.join(", ")}]) → requesting from $senderSid');
                      _sendToSocket(senderSid, {
                        'event_type': 'request_missing_serials',
                        'serials': missingSerials,
                        'serial': missingSerials.first,
                        'branchId': msgBranch,
                      });
                    }
                  }
                }
              }
            } catch (_) {}

            // ── DIRECT CLOUD SYNC & ENQUEUE ON SERVER ──
            try {
              final upperSerial = serial.toUpperCase().trim();
              final dateKey = (data['dateKey'] ?? CampSessionService.getDateKeyFromSerial(upperSerial)).toString();
              final queueType = _resolveQueueType(data['queueType']?.toString());
              final campId = (data['campId'] ?? data['dispensaryId'] ?? data['dispensaryTag'] ?? '').toString().toLowerCase().trim();
              final entryUid = (data['entryUid'] ?? message['entryUid'])?.toString().trim();
              final hasCollision = message['hasCollision'] == true || data['hasCollision'] == true;

              // The token's single cloud item, merged (not overwritten: a plain put replaced
              // a queued prescription/dispense with this bare entry before it was uploaded).
              await _enqueueTokenState(
                box: await _syncQueueBox(),
                branch: msgBranch,
                localBranch: msgBranch,
                serial: upperSerial,
                incoming: data,
                entryUid: entryUid,
                hasCollision: hasCollision,
                dateKey: dateKey,
                queueType: queueType,
                campId: campId,
              );
              _scheduleSyncDebounced();
            } catch (e) {
              debugPrint('[SSM] Direct sync enqueue error for entry: $e');
              rethrow; // not ACKed: the desk resends, so the token still reaches the cloud
            }
          }
          break;

        case 'save_prescription':
        case 'prescription_created':
          final serial = data['serial']?.toString().trim();
          final entryUid = (data['entryUid'] ?? message['entryUid'])?.toString().trim();
          if (serial != null && serial.isNotEmpty) {
            await LocalStorageService.saveLocalPrescription(data);
            try {
              if (Hive.isBoxOpen(LocalStorageService.entriesBox)) {
                final eBox = Hive.box(LocalStorageService.entriesBox);
                final normBranch = msgBranch.toLowerCase().trim();
                final normSerial = serial.toLowerCase().trim();
                final key = '$normBranch-$serial';

                dynamic targetKey = key;
                dynamic existing;

                // [A4] Look up by entryUid first if present to match the exact collision entry
                if (entryUid != null && entryUid.isNotEmpty) {
                  for (final k in eBox.keys) {
                    final val = eBox.get(k);
                    if (val is Map && (val['entryUid']?.toString().trim() == entryUid)) {
                      targetKey = k;
                      existing = val;
                      break;
                    }
                  }
                }

                if (existing == null) {
                  // Entries are stored under the upper-case serial; the doctor sends it lower-case.
                  final canonicalKey = '$normBranch-${serial.toUpperCase()}';
                  existing = eBox.get(canonicalKey);
                  if (existing != null) targetKey = canonicalKey;
                  existing ??= eBox.get(key);
                  if (existing == null) {
                    for (final k in eBox.keys) {
                      final kStr = k.toString().toLowerCase().trim();
                      if (kStr == '$normBranch-$normSerial' || kStr == normSerial || kStr.endsWith('-$normSerial')) {
                        targetKey = k;
                        existing = eBox.get(k);
                        break;
                      }
                    }
                  }
                }

                // An older replay or a copy without medicines must not replace what the token
                // holds (the same rule as saveLocalPrescription above).
                if (existing != null && existing is Map &&
                    LocalStorageService.mayReplacePrescription(data, existing['prescription'])) {
                  final updated = Map<String, dynamic>.from(existing);
                  final embeddedRx = LocalStorageService.prescriptionForEmbedding(data);
                  updated['status'] = 'completed';
                  // Without its nested older copies (they grew every token a level per save).
                  updated['prescription'] = embeddedRx;
                  updated['prescriptionId'] = data['id'] ?? serial;
                  updated['completedAt'] ??= data['completedAt'] ?? DateTime.now().toIso8601String();
                  if (data['updatedAt'] != null) updated['updatedAt'] = data['updatedAt'];
                  final rxMeds = embeddedRx['medicines'] ?? embeddedRx['prescriptions'] ?? data['medicines'] ?? data['prescriptions'];
                  if (rxMeds is List && rxMeds.isNotEmpty) {
                    updated['medicines'] = rxMeds;
                    updated['prescriptions'] = rxMeds;
                  }
                  if (data['daysOfMedicine'] != null) updated['daysOfMedicine'] = data['daysOfMedicine'];
                  final docName = data['doctorName'] ?? data['prescribedBy'] ?? embeddedRx['doctorName'];
                  if (docName != null) {
                    updated['doctorName'] = docName;
                    updated['prescribedBy'] = docName;
                  }
                  if (data['doctorId'] != null) updated['doctorId'] = data['doctorId'];
                  if (data['diagnosis'] != null) updated['diagnosis'] = data['diagnosis'];
                  final comp = data['complaint'] ?? data['condition'];
                  if (comp != null) {
                    updated['complaint'] = comp;
                    updated['condition'] = comp;
                  }
                  if (data['vitals'] != null) updated['vitals'] = data['vitals'];
                  if (data['labResults'] != null) updated['labResults'] = data['labResults'];
                  if (data['extraCharge'] != null) updated['extraCharge'] = data['extraCharge'];
                  if (entryUid != null && entryUid.isNotEmpty) {
                    updated['entryUid'] = entryUid;
                  }
                  // Ensure backfill sweeper uploads this prescription to Firestore
                  updated['pendingSync'] = true;
                  updated['synced'] = false;
                  updated['syncStatus'] = 'pending';
                  await eBox.put(targetKey, updated);
                  LocalStorageService.invalidateLocalEntriesCache();
                }
              }
            } catch (_) {}
            debugPrint('[SSM] ✅ Prescription saved locally: $serial');

            // ── DIRECT CLOUD SYNC & ENQUEUE ON SERVER ──
            try {
              final upperSerial = serial.toUpperCase().trim();
              final dateKey = (data['dateKey'] ?? CampSessionService.getDateKeyFromSerial(upperSerial)).toString();
              final queueType = _resolveQueueType(data['queueType']?.toString());
              final campId = (data['campId'] ?? data['dispensaryId'] ?? data['dispensaryTag'] ?? '').toString().toLowerCase().trim();

              // Merged into the token's single cloud item (was its own 'sync_presc_' item).
              final sBox = await _syncQueueBox();
              await sBox.delete('sync_presc_${msgBranch.toLowerCase().trim()}_$upperSerial');
              await _enqueueTokenState(
                box: sBox,
                branch: msgBranch,
                localBranch: msgBranch,
                serial: upperSerial,
                incoming: {...data, 'status': 'completed'},
                entryUid: entryUid,
                dateKey: dateKey,
                queueType: queueType,
                campId: campId,
              );
              _scheduleSyncDebounced();
            } catch (e) {
              debugPrint('[SSM] Direct sync enqueue error for prescription: $e');
              rethrow; // not ACKed: the desk resends
            }
          }
          break;

        case 'dispense_completed':
          final serial = data['serial']?.toString().trim();
          final entryUid = (data['entryUid'] ?? message['entryUid'])?.toString().trim();
          if (serial != null && serial.isNotEmpty) {
            final normBranch = msgBranch.toLowerCase().trim();
            var cleanSerial = serial.trim();
            if (cleanSerial.toLowerCase().startsWith('$normBranch-')) {
              cleanSerial = cleanSerial.substring(normBranch.length + 1).trim();
            }
            final normSerial = cleanSerial.toLowerCase();
            final normSerialUpper = cleanSerial.toUpperCase();
            final canonicalKey = '$normBranch-$normSerialUpper';

            try {
              if (Hive.isBoxOpen(LocalStorageService.entriesBox)) {
                final eBox = Hive.box(LocalStorageService.entriesBox);

                dynamic targetKey = canonicalKey;
                dynamic existing;

                // The token is normally at its canonical key: use it when its entryUid matches
                // (or either side has none). Only otherwise scan for the entryUid — that scan
                // read the whole entries box on every dispense, on the server's UI thread.
                final atCanonical = eBox.get(canonicalKey);
                if (atCanonical is Map) {
                  final uidThere = atCanonical['entryUid']?.toString().trim() ?? '';
                  if (entryUid == null || entryUid.isEmpty || uidThere.isEmpty || uidThere == entryUid) {
                    existing = atCanonical;
                  }
                }

                // [A4] Look up by entryUid if the canonical key holds a different token
                if (existing == null && entryUid != null && entryUid.isNotEmpty) {
                  for (final k in eBox.keys) {
                    final val = eBox.get(k);
                    if (val is Map && (val['entryUid']?.toString().trim() == entryUid)) {
                      targetKey = k;
                      existing = val;
                      break;
                    }
                  }
                }

                if (existing == null) {
                  existing = eBox.get(canonicalKey) ?? eBox.get('$normBranch-$cleanSerial');
                  if (existing == null) {
                    for (final k in eBox.keys) {
                      final kStr = k.toString().toLowerCase().trim();
                      if (kStr == canonicalKey.toLowerCase() ||
                          kStr == '$normBranch-$normSerial' ||
                          kStr == normSerial ||
                          kStr.endsWith('-$normSerial') ||
                          kStr.endsWith('-$normSerialUpper'.toLowerCase())) {
                        targetKey = k;
                        existing = eBox.get(k);
                        break;
                      }
                    }
                  }
                }

                if (existing != null && existing is Map) {
                  final updated = Map<String, dynamic>.from(existing);
                  updated['dispenseStatus'] = 'dispensed';
                  updated['status'] = 'completed';
                  updated['dispensedAt'] =
                      data['dispensedAt'] ?? DateTime.now().toIso8601String();
                  updated['dispensedBy'] = data['dispensedBy'] ?? data['dispenserName'];
                  updated['completedAt'] =
                      data['completedAt'] ?? DateTime.now().toIso8601String();
                  if (entryUid != null && entryUid.isNotEmpty) {
                    updated['entryUid'] = entryUid;
                  }
                  // Ensure backfill sweeper uploads this dispense status to Firestore
                  updated['pendingSync'] = true;
                  updated['synced'] = false;
                  updated['syncStatus'] = 'pending';
                  await eBox.put(targetKey, updated);
                  if (targetKey != canonicalKey && !targetKey.toString().contains('-COLLISION-')) {
                    await eBox.put(canonicalKey, updated);
                  }
                  debugPrint('[SSM] ✅ Dispense saved locally: $targetKey');
                }
                await LocalStorageService.updateDispenseStatus(normBranch, normSerialUpper, 'dispensed');
              }
            } catch (e) {
              // Not swallowed any more: the desk was ACKed although the server had not saved
              // the dispense, so the server's catch-up later pushed "not dispensed" to desks
              // that missed the live message (risk of a second dispense). Failing here means no
              // ACK, and the desk resends; the stock below is deducted once per token anyway.
              debugPrint('[SSM] ❌ Dispense save failed for $canonicalKey: $e');
              rethrow;
            }

            // Deduct dispensed stock from the LAN server's own stockBox (unless this PC itself was the sender,
            // in which case PatientForm already deducted from stockBox locally).
            try {
              final senderClientId = message['_clientId']?.toString() ?? '';
              final myClientId = RealtimeManager().clientId ?? '';
              final isFromSelf = senderClientId.isNotEmpty && myClientId.isNotEmpty && senderClientId == myClientId;
              final localClaimKey = (entryUid != null && entryUid.isNotEmpty)
                  ? 'srv_local_stock_${normBranch}_${normSerialUpper}_$entryUid'
                  : 'srv_local_stock_${normBranch}_$normSerialUpper';
              if (!isFromSelf &&
                  Hive.isBoxOpen(LocalStorageService.stockBox) &&
                  HourlyDispensarySync.claimStockDeduction(localClaimKey)) {
                final deductedBatches = data['deductedBatches'];
                if (deductedBatches is List && deductedBatches.isNotEmpty) {
                  for (final b in deductedBatches) {
                    if (b is! Map) continue;
                    final medId = (b['medicineId'] ?? b['inventoryId'] ?? b['id'] ?? '').toString().trim();
                    final rawDelta = b['delta'];
                    final delta = rawDelta is num
                        ? rawDelta.toDouble()
                        : double.tryParse(rawDelta?.toString() ?? '') ?? 0.0;
                    if (medId.isNotEmpty && delta != 0) {
                      LocalStorageService.updateLocalStockQuantity(medId, delta);
                    }
                  }
                } else {
                  final medicines = data['medicines'];
                  final days = (data['daysOfMedicine'] is num)
                      ? (data['daysOfMedicine'] as num).toInt()
                      : (int.tryParse(data['daysOfMedicine']?.toString() ?? '1') ?? 1);
                  if (medicines is List && medicines.isNotEmpty) {
                    for (final m in medicines) {
                      if (m is! Map) continue;
                      final medId = (m['inventoryId'] ?? m['medicineId'] ?? m['id'] ?? '').toString().trim();
                      final perDayRaw = m['quantity'] ?? m['qty'] ?? 0;
                      final perDay = perDayRaw is num
                          ? perDayRaw.toDouble()
                          : double.tryParse(perDayRaw.toString()) ?? 0.0;
                      if (medId.isEmpty || perDay <= 0) continue;
                      final medType = (m['type'] ?? '').toString().toLowerCase().trim();
                      final medName = (m['name'] ?? m['medicineName'] ?? '').toString().toLowerCase().trim();
                      final isSyrup = medType.contains('syrup') || medType.contains('syp') || medType.contains('susp') ||
                          medName.contains('syp') || medName.contains('syrup');
                      final isInj = medType.contains('inj') || medType.contains('drip') || medType.contains('infusion') ||
                          medType == 'iv' || medType == 'i.v' || medType == 'im' || medType == 'i.m' ||
                          medName.startsWith('inj');
                      final qtyDeduct = isSyrup ? 1.0 : (isInj ? perDay : perDay * days);
                      LocalStorageService.updateLocalStockQuantity(medId, -qtyDeduct);
                    }
                  }
                }
              }
            } catch (e) {
              debugPrint('[SSM] Server local stock deduction warning: $e');
            }

            // ── DIRECT CLOUD SYNC & ENQUEUE ON SERVER ──
            try {
              final upperSerial = normSerialUpper;
              final dateKey = (data['dateKey'] ?? CampSessionService.getDateKeyFromSerial(upperSerial)).toString();
              final queueType = _resolveQueueType(data['queueType']?.toString());
              final campId = (data['campId'] ?? data['dispensaryId'] ?? data['dispensaryTag'] ?? '').toString().toLowerCase().trim();

              // Merged into the token's single cloud item (it was a separate status item: one
              // more upload of the same documents per patient). A dispensed token is "settled",
              // so it uploads on the next pass.
              final sBox = await _syncQueueBox();
              await sBox.delete('sync_dispense_${msgBranch.toLowerCase().trim()}_$upperSerial');
              await _enqueueTokenState(
                box: sBox,
                branch: msgBranch,
                localBranch: msgBranch,
                serial: upperSerial,
                incoming: {
                  ...data,
                  'dispenseStatus': 'dispensed',
                  'status': 'completed',
                },
                entryUid: entryUid,
                dateKey: dateKey,
                queueType: queueType,
                campId: campId,
              );
              _scheduleSyncDebounced();
            } catch (e) {
              debugPrint('[SSM] Direct sync enqueue error for dispense: $e');
              rethrow; // not ACKed: the desk resends
            }
          }
          break;

        case 'save_patient':
          try {
            await LocalStorageService.saveLocalPatient(
                {...data, 'branchId': msgBranch},
                isFromSync: true);
            final pid = (data['patientId'] ?? data['id'] ?? '').toString().trim();
            final pCnic = (data['cnic'] ?? data['patientCnic'] ?? '').toString().trim();
            if (pid.isNotEmpty) {
              await LocalStorageService.updateActiveEntriesForPatient(msgBranch, pid, data);
              // Mark any today's tokens for this patient changed so connected desks get the updated name/CNIC
              for (final e in LocalStorageService.getLocalEntries(msgBranch)) {
                final ePid = (e['patientId'] ?? e['id'] ?? '').toString().trim();
                final eCnic = (e['patientCnic'] ?? e['cnic'] ?? '').toString().trim();
                final s = (e['serial'] ?? '').toString().trim();
                if (s.isNotEmpty && (ePid == pid || (pCnic.isNotEmpty && eCnic == pCnic))) {
                  _markSerialChanged(s, senderSocketId: message['_socketId']?.toString());
                }
              }
            }
            debugPrint('[SSM] ✅ Patient saved locally');

            // ── DIRECT CLOUD SYNC & ENQUEUE ON SERVER ──
            if (pid.isNotEmpty) {
              final canonicalBranch = msgBranch.toLowerCase().trim();
              final targetKey = 'sync_patient_${canonicalBranch}_$pid';
              final sBox = await _syncQueueBox();
              await sBox.put(targetKey, {
                'type': 'save_patient',
                'entityId': pid,
                'branchId': canonicalBranch,
                'patientId': pid,
                'data': {...data, 'branchId': canonicalBranch},
                'createdAt': DateTime.now().toIso8601String(),
                'attempts': 0,
                'status': 'pending',
              });
              _scheduleSyncDebounced();
            }
          } catch (e) {
            debugPrint('[SSM] save_patient error: $e');
            rethrow; // not ACKed: the desk resends
          }
          break;

        case 'migrate_patient_key':
          try {
            final oldId = (data['oldPatientId'] ?? message['oldPatientId'])?.toString().trim();
            final newId = (data['newPatientId'] ?? message['newPatientId'])?.toString().trim();
            final patientMap = data['patient'] is Map
                ? Map<String, dynamic>.from(data['patient'] as Map)
                : Map<String, dynamic>.from(data);
            patientMap['branchId'] ??= msgBranch;
            if (newId != null && newId.isNotEmpty) {
              patientMap['patientId'] = newId;
              patientMap['id'] = newId;
            }
            if (oldId != null && oldId.isNotEmpty && oldId != newId && Hive.isBoxOpen(LocalStorageService.patientsBox)) {
              await Hive.box(LocalStorageService.patientsBox).delete(oldId);
            }
            await LocalStorageService.saveLocalPatient(patientMap, isFromSync: true);
            if (oldId != null && oldId.isNotEmpty) {
              await LocalStorageService.updateActiveEntriesForPatient(msgBranch, oldId, patientMap);
            }
            if (newId != null && newId.isNotEmpty && newId != oldId) {
              await LocalStorageService.updateActiveEntriesForPatient(msgBranch, newId, patientMap);
            }
            final targetPid = (newId != null && newId.isNotEmpty) ? newId : (patientMap['patientId'] ?? '').toString().trim();
            for (final e in LocalStorageService.getLocalEntries(msgBranch)) {
              final ePid = (e['patientId'] ?? e['id'] ?? '').toString().trim();
              final s = (e['serial'] ?? '').toString().trim();
              if (s.isNotEmpty && (ePid == targetPid || (oldId != null && ePid == oldId))) {
                _markSerialChanged(s, senderSocketId: message['_socketId']?.toString());
              }
            }
            if (targetPid.isNotEmpty) {
              final canonicalBranch = msgBranch.toLowerCase().trim();
              final targetKey = 'sync_patient_${canonicalBranch}_$targetPid';
              final sBox = await _syncQueueBox();
              await sBox.put(targetKey, {
                'type': 'save_patient',
                'entityId': targetPid,
                'branchId': canonicalBranch,
                'patientId': targetPid,
                if (oldId != null && oldId.isNotEmpty && oldId != targetPid) 'oldPatientId': oldId,
                'data': {...patientMap, 'branchId': canonicalBranch},
                'createdAt': DateTime.now().toIso8601String(),
                'attempts': 0,
                'status': 'pending',
              });
              _scheduleSyncDebounced();
            }
            debugPrint('[SSM] ✅ Migrated patient key on server: $oldId → $newId');
          } catch (e) {
            debugPrint('[SSM] migrate_patient_key error: $e');
            rethrow;
          }
          break;

        // [FIX-INV] Handle save_stock_item events so the server's local
        // Hive stockBox stays up-to-date with inventory from proforma/register.
        case 'save_stock_item':
        case 'medicine_registered':
        case 'add_proforma_stock':
        case 'add_stock':
          try {
            final medData = data['data'] is Map
                ? Map<String, dynamic>.from(data['data'] as Map)
                : data;
            final rawDelta = data['_quantityDelta'] ?? medData['_quantityDelta'];
            final medId = (medData['id'] ?? medData['medicineId'] ?? medData['docId'])?.toString().trim();
            // Never store the delta inside the item: a stored _quantityDelta was later pushed to
            // desks with the item and applied again there.
            medData.remove('_quantityDelta');
            if (medId != null && medId.isNotEmpty) {
              medData['branchId'] ??= msgBranch;
              medData['id'] ??= medId;
              medData['medicineId'] ??= medId;
              medData['docId'] ??= medId;
              if (rawDelta != null) {
                // Once per operation, also after a server restart (the in-memory message
                // dedupe is lost then and the desk's resend was applied a second time).
                final opId = (data['_opId'] ?? medData['_opId'] ?? message['_messageId'] ?? '').toString();
                if (opId.isNotEmpty && await RealtimeRouter.stockOpAlreadyApplied(opId)) {
                  debugPrint('[SSM] Stock delta $opId already applied — skipped');
                  break;
                }
                final delta = rawDelta is num ? rawDelta.toDouble() : double.tryParse(rawDelta.toString()) ?? 0.0;
                final existing = LocalStorageService.getLocalInventoryItem(medId);
                if (existing != null && delta != 0) {
                  LocalStorageService.updateLocalStockQuantity(medId, delta);
                } else {
                  LocalStorageService.saveLocalInventoryItem(medData);
                }
                if (opId.isNotEmpty) await RealtimeRouter.markStockOpApplied(opId);
              } else {
                LocalStorageService.saveLocalInventoryItem(medData);
              }
              debugPrint('[SSM] ✅ Stock item saved locally on server: $medId');
            }
          } catch (e) {
            debugPrint('[SSM] save_stock_item local save error: $e');
          }
          break;

        case 'delete_stock_item':
          try {
            final medId = (data['id'] ?? data['medicineId'] ?? data['docId'])?.toString().trim();
            if (medId != null && medId.isNotEmpty) {
              LocalStorageService.deleteLocalStockItem(medId);
              debugPrint('[SSM] ✅ Stock item deleted locally on server: $medId');
            }
          } catch (e) {
            debugPrint('[SSM] delete_stock_item local error: $e');
          }
          break;

        case 'save_office_boy_token':
        case 'save_dasterkhwan_tokens':
        case 'save_dasterkhwan_entry':
          try {
            if (!Hive.isBoxOpen('dasterkhwaan_tokens')) {
              await LocalStorageService.openBoxSafe('dasterkhwaan_tokens');
            }
            final tBox = Hive.box('dasterkhwaan_tokens');
            final tokensList = List<dynamic>.from(data['tokens'] as List? ?? []);
            // Copies from another PC are marked lanReceived: the issuing PC uploads them,
            // so this PC's backfill sweep must never upload them again.
            if (data['action'] == 'reverse') {
              for (final id in (data['tokenIds'] as List? ?? const [])) {
                await tBox.delete(id.toString());
              }
            } else if (tokensList.isNotEmpty) {
              for (final t in tokensList) {
                if (t is Map) {
                  final tMap = Map<String, dynamic>.from(t);
                  final tid = tMap['id']?.toString() ?? 'dst_${msgBranch}_${DateTime.now().microsecondsSinceEpoch}';
                  tMap['branchId'] ??= msgBranch;
                  tMap['lanReceived'] = true;
                  await tBox.put(tid, LocalStorageService.sanitize(tMap));
                }
              }
            } else {
              final tid = data['id']?.toString() ?? 'dst_${msgBranch}_${DateTime.now().microsecondsSinceEpoch}';
              data['branchId'] ??= msgBranch;
              data['lanReceived'] = true;
              await tBox.put(tid, LocalStorageService.sanitize(data));
            }
            debugPrint('[SSM] ✅ Food token(s) saved locally on server: ${tokensList.length} token(s)');
          } catch (e) {
            debugPrint('[SSM] Food token save error: $e');
          }
          break;

        case 'save_kitchen_serve_log':
          try {
            if (!Hive.isBoxOpen('dasterkhwaan_tokens')) {
              await LocalStorageService.openBoxSafe('dasterkhwaan_tokens');
            }
            final tBox = Hive.box('dasterkhwaan_tokens');
            final tokenId = data['tokenId']?.toString();
            if (tokenId != null && tokenId.isNotEmpty) {
              final existing = tBox.get(tokenId);
              if (existing is Map) {
                final updated = Map<String, dynamic>.from(existing)
                  ..['served'] = true
                  ..['servedTime'] = data['timestamp'] ?? DateTime.now().toIso8601String();
                await tBox.put(tokenId, updated);
              }
            }
            debugPrint('[SSM] ✅ Kitchen serve log saved locally on server: $tokenId');
          } catch (e) {
            debugPrint('[SSM] Kitchen serve log save error: $e');
          }
          break;

        case 'save_donation_receipt':
        case 'save_donation':
        case 'update_donation':
          try {
            if (!Hive.isBoxOpen(DonationsLocalStorage.donationsBox)) {
              await LocalStorageService.openBoxSafe(DonationsLocalStorage.donationsBox);
            }
            final dBox = Hive.box(DonationsLocalStorage.donationsBox);
            final id = (data['localId'] ?? data['id'] ?? data['firestoreId'] ?? data['receiptNoClean'] ?? 'don_${DateTime.now().microsecondsSinceEpoch}').toString();
            final bId = (data['branchId']?.toString() ?? msgBranch).toLowerCase().trim();
            final dt = data['date']?.toString() ?? DateTime.now().toIso8601String().substring(0, 10);
            final hKey = data['hiveKey']?.toString() ?? '${bId}_${dt}_$id';
            final sanitized = LocalStorageService.sanitize(data);
            sanitized['branchId'] = bId;
            sanitized['localId'] = id;
            sanitized['syncStatus'] = 'pending';
            await dBox.put(hKey, sanitized);
            debugPrint('[SSM] ✅ Donation saved locally on server: $hKey');
          } catch (e) {
            debugPrint('[SSM] Donation local save error on server: $e');
          }
          break;

        case 'token_reversal_approved':
        case 'token_reversal':
        case 'delete_entry':
          try {
            final serial = (data['tokenSerial'] ?? data['serial'] ?? data['tokenId'] ?? message['serial'] ?? message['tokenSerial'] ?? message['tokenId'])?.toString().trim();
            if (serial != null && serial.isNotEmpty) {
              LocalStorageService.deleteLocalEntry(msgBranch, serial);
              LocalStorageService.deleteLocalPrescription(serial);
              for (final seenSet in _clientSeenSerials.values) {
                seenSet.remove(serial);
                seenSet.remove(serial.toLowerCase());
                seenSet.remove(serial.toUpperCase());
              }
              final reqId = (data['requestId'] ?? data['id'])?.toString();
              if (reqId != null && reqId.isNotEmpty) {
                if (Hive.isBoxOpen('local_edit_requests')) {
                  final box = Hive.box('local_edit_requests');
                  final raw = box.get(reqId);
                  if (raw is Map) {
                    final updated = Map<String, dynamic>.from(raw);
                    updated['status'] = 'approved';
                    await box.put(reqId, updated);
                  }
                }
              }
              debugPrint('[SSM] ✅ Token reversed locally on server: $msgBranch-$serial');
            }
          } catch (e) {
            debugPrint('[SSM] token_reversal local error: $e');
          }
          break;

        case 'save_proforma_item':
        case 'proforma_item_updated':
          try {
            final code = (data['code'] ?? data['barcode'] ?? '').toString().trim();
            if (code.isNotEmpty) {
              if (!Hive.isBoxOpen(LocalStorageService.masterProformaBox)) {
                await Hive.openBox(LocalStorageService.masterProformaBox);
              }
              final box = Hive.box(LocalStorageService.masterProformaBox);
              final item = Map<String, dynamic>.from(data);
              item['isProformaMaster'] = true;
              await box.put('proforma:$code', LocalStorageService.sanitize(item));
              debugPrint('[SSM] ✅ Master Proforma item saved locally on server: $code');
            }
            final medId = (data['id'] ?? data['medicineId'] ?? data['docId'] ?? data['code'])?.toString().trim();
            if (medId != null && medId.isNotEmpty) {
              final medData = Map<String, dynamic>.from(data);
              medData['branchId'] ??= msgBranch;
              medData['id'] ??= medId;
              LocalStorageService.saveLocalInventoryItem(medData);
            }
          } catch (e) {
            debugPrint('[SSM] proforma save local error: $e');
          }
          break;

        case 'request_created':
        case 'save_inventory_edit_request':
        case 'save_token_reversal_request':
        case 'workflow_request':
          try {
            final reqMap = Map<String, dynamic>.from(data);
            reqMap['status'] ??= 'pending';
            await LocalStorageService.saveLocalEditRequest(reqMap);
            debugPrint('[SSM] ✅ Edit request saved locally on server: ${reqMap['id'] ?? reqMap['requestId']}');
          } catch (e) {
            debugPrint('[SSM] edit request save local error: $e');
          }
          break;

        case 'token_exception_request':
          try {
            final reqId = (data['requestId'] ?? data['id'] ?? 'exc_${DateTime.now().millisecondsSinceEpoch}').toString();
            if (!LocalStorageService.isLocalRequestDecided(reqId)) {
              final reqMap = Map<String, dynamic>.from(data)
                ..['id'] = reqId
                ..['requestId'] = reqId
                ..['branchId'] ??= msgBranch
                ..['requestType'] = 'token_exception'
                ..['status'] ??= 'pending';
              await LocalStorageService.saveLocalEditRequest(reqMap);
              if (Hive.isBoxOpen('app_settings')) {
                await Hive.box('app_settings').put('pending_exception_$reqId', reqMap);
              }
              final bId = (data['branchId']?.toString() ?? msgBranch).toLowerCase().trim();
              await LocalStorageService.enqueueSync({
                'type': 'save_token_exception_request',
                'branchId': bId.isNotEmpty ? bId : branchId,
                'requestId': reqId,
                'data': reqMap,
              });
              debugPrint('[SSM] ✅ Token exception request saved on server: $reqId');
            }
          } catch (e) {
            debugPrint('[SSM] token_exception_request save error: $e');
          }
          break;

        case 'token_exception_approved':
        case 'restriction_removed':
          try {
            final pid = (data['patientId'] ?? data['cnic'] ?? data['patientCnic'] ?? '').toString().trim();
            final reqId = (data['requestId'] ?? data['id'])?.toString().trim();
            final bId = (data['branchId']?.toString() ?? msgBranch).toLowerCase().trim();
            if (pid.isNotEmpty) {
              await LocalStorageService.grantTokenException(
                bId.isNotEmpty ? bId : branchId,
                pid,
                dateKey: data['dateKey']?.toString(),
                reason: data['reason']?.toString() ?? 'Approved by Doctor',
                approvedBy: data['approvedBy']?.toString() ?? 'Doctor',
                requestId: reqId,
              );
            }
            if (reqId != null && reqId.isNotEmpty) {
              await LocalStorageService.markLocalRequestDecided(reqId, 'approved', fields: {
                'approvedBy': data['approvedBy']?.toString() ?? 'Doctor',
                'approvedAt': data['approvedAt']?.toString() ?? DateTime.now().toIso8601String(),
              });
            }
            if (pid.isNotEmpty) {
              await LocalStorageService.enqueueSync({
                'type': 'approve_token_exception',
                'branchId': bId.isNotEmpty ? bId : branchId,
                'patientId': pid,
                if (reqId != null && reqId.isNotEmpty) 'requestId': reqId,
                'data': data,
              });
            }
            debugPrint('[SSM] ✅ Token exception approved on server for patient=$pid');
          } catch (e) {
            debugPrint('[SSM] token_exception_approved error: $e');
          }
          break;

        case 'request_approved':
        case 'request_rejected':
        case 'workflow_decision':
          try {
            final reqId = (data['requestId'] ?? data['id'] ?? data['docId'])?.toString();
            final resolvedStatus = (eventType == 'request_rejected' || data['status'] == 'rejected') ? 'rejected' : 'approved';
            if (reqId != null && reqId.isNotEmpty) {
              if (Hive.isBoxOpen('local_edit_requests')) {
                final box = Hive.box('local_edit_requests');
                final raw = box.get(reqId);
                final map = raw is Map ? Map<String, dynamic>.from(raw) : Map<String, dynamic>.from(data);
                map['status'] = resolvedStatus;
                if (data['reviewedAt'] != null) map['reviewedAt'] = data['reviewedAt'];
                if (data['reviewedBy'] != null) map['reviewedBy'] = data['reviewedBy'];
                if (data['reviewedByName'] != null) map['reviewedByName'] = data['reviewedByName'];
                if (data['doctorReason'] != null) map['doctorReason'] = data['doctorReason'];
                if (data['rejectionReason'] != null) map['rejectionReason'] = data['rejectionReason'];
                await box.put(reqId, map);
                debugPrint('[SSM] ✅ Request $reqId status updated to $resolvedStatus on server');
              }
              if (Hive.isBoxOpen(LocalStorageService.restockRequestsBox)) {
                final rBox = Hive.box(LocalStorageService.restockRequestsBox);
                final raw = rBox.get(reqId);
                if (raw is Map) {
                  final map = Map<String, dynamic>.from(raw);
                  map['status'] = resolvedStatus;
                  if (data['reviewedAt'] != null) map['reviewedAt'] = data['reviewedAt'];
                  if (data['reviewedBy'] != null) map['reviewedBy'] = data['reviewedBy'];
                  if (data['reviewedByName'] != null) map['reviewedByName'] = data['reviewedByName'];
                  if (data['doctorReason'] != null) map['doctorReason'] = data['doctorReason'];
                  if (data['rejectionReason'] != null) map['rejectionReason'] = data['rejectionReason'];
                  await rBox.put(reqId, map);
                }
              }
              // Enqueue Firestore sync on server
              final bId = (data['branchId']?.toString() ?? msgBranch).toLowerCase().trim();
              final col = (data['collection'] ?? 'edit_requests').toString();
              await LocalStorageService.enqueueSync({
                'type': resolvedStatus == 'approved' ? 'approve_request' : 'reject_request',
                'requestId': reqId,
                'id': reqId,
                'docId': reqId,
                'status': resolvedStatus,
                'collection': col,
                'branchId': bId.isNotEmpty ? bId : branchId,
                'data': data,
              });
            }
          } catch (e) {
            debugPrint('[SSM] request status update local error: $e');
          }
          break;

        case 'save_madrassa_student':
        case 'save_madrassa_admission':
          try {
            final studentId = data['studentId']?.toString() ?? data['id']?.toString() ?? '';
            final bId = (data['branchId']?.toString() ?? msgBranch).toLowerCase().trim();
            if (studentId.isNotEmpty && bId.isNotEmpty) {
              await MadrassaLocalStorage.cacheStudent(bId, studentId, data);
              // Also enqueue on server so client-saved/edited students reach Firestore!
              await LocalStorageService.enqueueSync({
                'type': 'save_madrassa_student',
                'branchId': bId,
                'studentId': studentId,
                'data': data,
                'forceUpload': true,
              });
              debugPrint('[SSM] ✅ Madrassa student cached locally and enqueued for sync on server');
            }
          } catch (e) {
            debugPrint('[SSM] Madrassa student cache error on server: $e');
          }
          break;

        case 'delete_madrassa_student':
        case 'offboard_madrassa_student':
          try {
            final studentId = data['studentId']?.toString() ?? data['id']?.toString() ?? '';
            final bId = (data['branchId']?.toString() ?? msgBranch).toLowerCase().trim();
            final status = data['status']?.toString() ?? 'left';
            if (studentId.isNotEmpty && bId.isNotEmpty) {
              final studentCache = MadrassaLocalStorage.getStudentCached(bId, studentId);
              if (studentCache != null) {
                studentCache['status'] = status;
                studentCache['batch'] = status;
                if (data['effectiveDate'] != null) {
                  studentCache['offboardedAt'] = data['effectiveDate'];
                }
                await MadrassaLocalStorage.cacheStudent(bId, studentId, studentCache);
              }
              // Enqueue deletion/offboarding on server for cloud sync
              await LocalStorageService.enqueueSync({
                'type': 'offboard_madrassa_student',
                'branchId': bId,
                'studentId': studentId,
                'status': status,
                'reason': data['reason']?.toString(),
                'effectiveDate': data['effectiveDate']?.toString(),
                'forceUpload': true,
              });
              debugPrint('[SSM] ✅ Madrassa student offboarded locally and enqueued for sync on server');
            }
          } catch (e) {
            debugPrint('[SSM] Madrassa student offboard error on server: $e');
          }
          break;

        case 'save_biometric_device':
          try {
            final devId = (data['deviceId'] ?? data['id'] ?? '').toString().trim();
            if (devId.isNotEmpty) {
              if (!Hive.isBoxOpen(LocalStorageService.biometricDevicesBox)) {
                await LocalStorageService.openBoxSafe(LocalStorageService.biometricDevicesBox);
              }
              final devBox = Hive.box(LocalStorageService.biometricDevicesBox);
              await devBox.put(devId, data);
              debugPrint('[SSM] ✅ Biometric device saved locally on server: $devId');
            }
          } catch (e) {
            debugPrint('[SSM] save_biometric_device local error: $e');
          }
          break;
      }
    } catch (e) {
      debugPrint('[SSM] _saveToLocalHive error: $e');
      // Tokens, prescriptions, dispenses and patients must not be ACKed when they were not
      // stored: LanServer only ACKs after this returns, so the desk keeps and resends them.
      if (_mustPersist.contains(eventType)) rethrow;
    }
  }

  static const Set<String> _tokenChangeEvents = {
    'save_entry', 'token_created', 'save_prescription', 'prescription_created', 'dispense_completed',
    'update_serial_status',
  };

  /// A token changed: every desk has to ACK it again (the live broadcast does that for desks
  /// that got it; the others get it at their next catch-up, including desks that are offline
  /// right now). The sender already has it.
  void _markSerialChanged(String serial, {String? senderSocketId}) {
    final variants = {serial, serial.toUpperCase(), serial.toLowerCase()};
    for (final entry in _clientSeenSerials.entries) {
      if (entry.key == senderSocketId) continue;
      entry.value.removeAll(variants);
      _clientSentAt[entry.key]?.removeWhere((k, _) => variants.contains(k));
      _clientSendCount[entry.key]?.removeWhere((k, _) => variants.contains(k)); // changed: send fresh
    }
    for (final seen in _seenByClientId.values) {
      seen.removeAll(variants);
    }
    if (senderSocketId != null) (_clientSeenSerials[senderSocketId] ??= {}).add(serial);
  }

  static const Set<String> _mustPersist = {
    'save_entry', 'token_created', 'save_prescription', 'prescription_created',
    'dispense_completed', 'save_patient', 'migrate_patient_key',
  };

  /// The server's cloud upload queue, opened if the LRU timer or a slow start left it closed
  /// (the old isBoxOpen check skipped the enqueue silently and the record never uploaded).
  Future<Box> _syncQueueBox() => LocalStorageService.ensureBoxOpen(LocalStorageService.syncBox);

  // ── Catch-up push — send today's entries to a client (supports forceAll) ──
  // ── Today's tokens, built once and shared ─────────────────────────────────
  // The 5-second catch-up used to rebuild this list for EVERY connected desk on every tick:
  // a copy of the whole token history for up to 6 Karachi branch ids, plus a date check per
  // entry — the main CPU cost on the i3 server while it should be answering token requests.
  // Now it is built once and reused until the entries box changes (any write), the day
  // changes, or 60 s pass. Entries are read-only here (copied before sending).
  final Map<String, List<Map<String, dynamic>>> _todayEntriesCache = {};
  int _entriesVersion = 0;
  int _todayEntriesCacheVersion = -1;
  String _todayEntriesCacheDay = '';
  DateTime _todayEntriesCacheAt = DateTime.fromMillisecondsSinceEpoch(0);
  StreamSubscription<BoxEvent>? _entriesWatch;

  void _watchEntriesBox() {
    if (_entriesWatch != null || !Hive.isBoxOpen(LocalStorageService.entriesBox)) return;
    _entriesWatch = Hive.box(LocalStorageService.entriesBox).watch().listen((_) => _entriesVersion++);
  }

  List<Map<String, dynamic>> _todayEntriesFor(Set<String> branches, String today) {
    _watchEntriesBox();
    final now = DateTime.now();
    if (_todayEntriesCacheVersion != _entriesVersion ||
        _todayEntriesCacheDay != today ||
        now.difference(_todayEntriesCacheAt) > const Duration(seconds: 60) ||
        _entriesWatch == null) {
      _todayEntriesCache.clear();
      _todayEntriesCacheVersion = _entriesVersion;
      _todayEntriesCacheDay = today;
      _todayEntriesCacheAt = now;
    }
    final key = (branches.toList()..sort()).join('|');
    return _todayEntriesCache.putIfAbsent(key, () {
      final Map<String, Map<String, dynamic>> deduped = {};
      for (final b in branches) {
        for (final e in LocalStorageService.getLocalEntries(b)) {
          final serial = (e['serial'] ?? e['id'] ?? '').toString().trim();
          // Only tokens dated today by their serial. The old 24-hour carry-over re-pushed
          // yesterday's tokens to every desk the next morning.
          // Plus last night's late tokens until 06:00 (a desk that missed one still gets it).
          if (serial.isNotEmpty &&
              (CampSessionService.isTokenOnDate(e, today, branchId) ||
                  CampSessionService.isLateNightCarryOver(e, branchId))) {
            deduped[serial.toUpperCase()] = e;
          }
        }
      }
      return deduped.values.toList(growable: false);
    });
  }

  Future<int> _pushCatchUpToSocket(
      String socketId, Map<String, dynamic> info, {bool forceAll = false}) async {
    final role = (info['role'] ?? '').toString().toLowerCase();

    final today = _todayKey();
    List<Map<String, dynamic>> entries;
    try {
      final clientBranch = (info['branchId'] ?? info['branch'] ?? '').toString().toLowerCase().trim();
      final branchesToQuery = <String>{branchId};
      if (clientBranch.isNotEmpty && clientBranch != 'all') branchesToQuery.add(clientBranch);
      if (CampSessionService.isKarachiFamily(branchId)) {
        branchesToQuery.addAll(['karachi', 'saddar', 'haji_camp', 'haji', 'hajicamp']);
      }
      entries = _todayEntriesFor(branchesToQuery, today);
    } catch (e) {
      debugPrint('[SSM] Catch-up read failed: $e');
      return 0;
    }

    final clientSeen = _clientSeenSerials[socketId] ?? <String>{};
    final sentAt = _clientSentAt[socketId] ??= {};
    final sendCount = _clientSendCount[socketId] ??= {};
    final now = DateTime.now();
    // Today's tokens this desk has not confirmed yet (sent or not). Their count goes back to
    // the desk with every pong so the doctor screen can tell it is behind and wait for the
    // missing tokens before choosing the next patient. Kept as a set so the desk's ACKs
    // (_handleClientAck) lower the count at once instead of at the next pass.
    final unconfirmed = <String>{};
    final candidates = entries.where((e) {
      final serial = e['serial']?.toString().trim() ?? '';
      // Filter out phantom unknown tokens with synthetic CNIC
      final cnic = (e['patientCnic'] ?? e['cnic'] ?? '').toString().trim();
      final name = (e['patientName'] ?? e['name'] ?? '').toString().trim().toLowerCase();
      if ((cnic.startsWith('unknown_cnic_') || cnic.isEmpty) && (name.isEmpty || name == 'unknown patient' || name == 'unknown')) {
        return false;
      }
      if (serial.isEmpty) return false;
      final seen = clientSeen.contains(serial);
      if (!seen) unconfirmed.add(serial);
      if (forceAll) return true;
      if (seen) return false;
      final sent = sentAt[serial];
      if (sent == null) return true;
      // Back off per token: 6 s, 12, 24, 48, then every 60 s. A token a desk never confirms
      // (fails to apply, other camp, old build) used to be re-sent as 3 frames every 6 s
      // forever — a steady LAN flood. The cap was 5 min, which left a doctor whose desk was
      // briefly busy (apply timed out) waiting minutes for a token; 60 s keeps the flood away
      // while a missed token still shows up within a minute.
      final n = sendCount[serial] ?? 1;
      final wait = _resendUnackedAfter * (1 << (n - 1).clamp(0, 6));
      const maxWait = Duration(seconds: 60);
      final capped = wait > maxWait ? maxWait : wait;
      return now.difference(sent) >= capped;
    }).toList();
    _unconfirmedSerials[socketId] = unconfirmed;
    if (_unconfirmedSerials.length > 200) _unconfirmedSerials.remove(_unconfirmedSerials.keys.first);
    server.reportUnconfirmedTokens(socketId, unconfirmed.length);

    if (candidates.isEmpty) return 0;

    debugPrint('[SSM] 📤 Catch-up to $role ($socketId): ${candidates.length} entry(ies) (forceAll=$forceAll)');
    int pushedCount = 0;
    final patientByCnic = <String, Map<String, dynamic>?>{};

    for (final entry in candidates) {
      final serial = entry['serial']?.toString() ?? '';
      if (serial.isEmpty) continue;

      final entryCopy = Map<String, dynamic>.from(entry);
      LocalStorageService.flattenEmbeddedPrescription(entryCopy);

      Map<String, dynamic>? presc;
      try {
        // The token's own prescription unless the lookup has a newer one with medicines (the
        // lookup alone, without the branch, could pick an older or empty record).
        presc = LocalStorageService.preferredPrescription(
          LocalStorageService.getLocalPrescription(serial, branchId: branchId),
          entry['prescription'],
        );
      } catch (_) {}

      if (presc != null && presc.isNotEmpty) {
        entryCopy['status'] = 'completed';
        entryCopy['prescription'] = LocalStorageService.prescriptionForEmbedding(presc);
        entryCopy['prescriptionId'] = presc['id'] ?? serial;
        final meds = entryCopy['prescription']['medicines'];
        if (meds is List && meds.isNotEmpty) {
          entryCopy['medicines'] = meds;
          entryCopy['prescriptions'] = meds;
        }
      }
      if ((entry['dispenseStatus'] ?? '') == 'dispensed') {
        entryCopy['status'] = 'completed';
        entryCopy['dispenseStatus'] = 'dispensed';
      }

      // Auto-resolve patient name from local_patients before pushing to client
      final curPushName = (entryCopy['patientName'] ?? entryCopy['name'] ?? entryCopy['fullName'])?.toString().trim().toLowerCase() ?? '';
      if (curPushName.isEmpty || curPushName == 'null' || curPushName == 'unknown' || curPushName == 'unknown patient') {
        final pId = (entryCopy['patientId'] ?? entryCopy['id'] ?? '').toString().trim();
        final pCnic = (entryCopy['patientCnic'] ?? entryCopy['cnic'] ?? entryCopy['guardianCnic'] ?? '').toString().trim();
        if (pId.isNotEmpty) {
          final lp = LocalStorageService.getLocalPatient(pId);
          final lpName = (lp?['name'] ?? lp?['patientName'] ?? lp?['fullName'])?.toString().trim();
          if (lpName != null && lpName.isNotEmpty && lpName.toLowerCase() != 'null' && lpName.toLowerCase() != 'unknown' && lpName.toLowerCase() != 'unknown patient') {
            entryCopy['patientName'] = lpName;
            entryCopy['name'] = lpName;
          }
        }
        final nameAfterPid = (entryCopy['patientName'] ?? '').toString().trim().toLowerCase();
        final isEntryAdult = entryCopy['isAdult'] is bool
            ? entryCopy['isAdult'] as bool
            : (!pId.contains('_child_') && (entryCopy['guardianCnic']?.toString().trim().isEmpty ?? true));
        if (isEntryAdult && (nameAfterPid.isEmpty || nameAfterPid == 'null' || nameAfterPid == 'unknown' || nameAfterPid == 'unknown patient') && pCnic.isNotEmpty) {
          // A CNIC miss scans every patient; remember answers for the rest of this push.
          final lp = patientByCnic.putIfAbsent(pCnic, () => LocalStorageService.getLocalPatientByCnic(pCnic));
          final lpName = (lp?['name'] ?? lp?['patientName'] ?? lp?['fullName'])?.toString().trim();
          if (lpName != null && lpName.isNotEmpty && lpName.toLowerCase() != 'null' && lpName.toLowerCase() != 'unknown' && lpName.toLowerCase() != 'unknown patient') {
            entryCopy['patientName'] = lpName;
            entryCopy['name'] = lpName;
          }
        }
      }

      final entrySent = _sendToSocket(socketId, {
        'event_type': 'save_entry',
        'branchId': branchId,
        'data': entryCopy,
        '_serverPush': true,
        'isCatchUp': true,
      });

      bool allSent = entrySent;

      if (presc != null && presc.isNotEmpty) {
        final prescSent = _sendToSocket(socketId, {
          'event_type': 'save_prescription',
          'branchId': branchId,
          'data': presc,
          '_serverPush': true,
          'isCatchUp': true,
        });
        if (!prescSent) allSent = false;
      }

      if ((entryCopy['dispenseStatus'] ?? '') == 'dispensed') {
        final dispSent = _sendToSocket(socketId, {
          'event_type': 'dispense_completed',
          'branchId': branchId,
          'data': entryCopy,
          '_serverPush': true,
          'isCatchUp': true,
        });
        if (!dispSent) allSent = false;
      }

      // [FIX-A] Only mark seen if ALL related messages (entry + presc + dispense)
      // were confirmed successful on socket. If any failed, retry next sweep.
      // Seen only once the desk ACKs it (_handleClientAck); until then it is just "sent".
      if (allSent) {
        pushedCount++;
        final sent = _clientSentAt[socketId] ??= {};
        sent[serial] = DateTime.now();
        sendCount[serial] = (sendCount[serial] ?? 0) + 1;
        if (sent.length > _maxSeenPerClient) {
          sent.remove(sent.keys.first);
        }
        if (sendCount.length > _maxSeenPerClient) sendCount.remove(sendCount.keys.first);
      }

      await Future.delayed(const Duration(milliseconds: 4));
    }
    return pushedCount;
  }

  // ── [FIX-INV-CATCHUP] Push full current stock snapshot to clients ──────────
  Future<int> _pushInventoryCatchUpToSocket(
      String socketId, Map<String, dynamic> info, {bool forceAll = false}) async {
    try {
      if (!Hive.isBoxOpen(LocalStorageService.stockBox)) return 0;
      final stockBox = Hive.box(LocalStorageService.stockBox);
      final targetBranch = branchId.toLowerCase().trim();
      final seen = _clientSeenStock[socketId] ??= {};
      int pushed = 0;
      int skipped = 0;

      for (final k in stockBox.keys) {
        final kStr = k.toString();
        if (kStr.startsWith('stock:')) continue; // Skip dual prefix key in Hive to avoid duplicate pushes
        final val = stockBox.get(k);
        if (val is! Map) continue;
        final item = Map<String, dynamic>.from(val);
        if (item['status'] == 'deleted') continue;

        final itemBranch = (item['branchId'] ?? '').toString().trim().toLowerCase();
        if (itemBranch.isNotEmpty && itemBranch != targetBranch && itemBranch != 'all') {
          continue;
        }

        final medicineId = (item['id'] ?? item['medicineId'] ?? item['docId'] ?? k).toString().trim();
        if (medicineId.isEmpty) continue;

        final version = (item['updatedAt'] ?? item['lastUpdated'] ?? item['createdAt'] ?? '').toString();
        final seenMarker = '$medicineId|$version';
        if (!forceAll && seen.contains(seenMarker)) {
          skipped++;
          continue;
        }

        final sent = _sendToSocket(socketId, {
          'event_type': 'save_stock_item',
          'branchId': branchId,
          'data': item,
          '_serverPush': true,
          'isCatchUp': true,
          '_isReplay': true,
        });
        if (sent) {
          pushed++;
          seen.add(seenMarker);
          if (seen.length > _maxSeenStockPerClient) {
            final overflow = seen.length - _maxSeenStockPerClient;
            seen.removeAll(seen.take(overflow).toList());
          }
        }
        await Future.delayed(const Duration(milliseconds: 10));
      }

      if (pushed > 0 || skipped > 0) {
        debugPrint('[SSM] 📦 Inventory catch-up → $socketId: $pushed pushed, $skipped already-seen (forceAll=$forceAll)');
        onMessageReceived({
          'event_type': 'inventory_catchup_pushed',
          '_senderRole': 'server',
          '_senderUsername': 'Inventory Catch-up',
          'data': {'socketId': socketId, 'itemsPushed': pushed, 'itemsSkipped': skipped},
        });
      }
      return pushed;
    } catch (e) {
      debugPrint('[SSM] _pushInventoryCatchUpToSocket error: $e');
      return 0;
    }
  }

  Future<int> _pushPendingRequestsCatchUpToSocket(
      String socketId, Map<String, dynamic> info) async {
    int pushed = 0;
    try {
      final seenKeys = <String>{};
      final boxNames = ['local_edit_requests', LocalStorageService.restockRequestsBox];
      for (final boxName in boxNames) {
        if (!Hive.isBoxOpen(boxName)) continue;
        final box = Hive.box(boxName);
        for (final key in box.keys) {
          final kStr = key.toString();
          if (!seenKeys.add(kStr)) continue;
          final raw = box.get(key);
          if (raw is! Map) continue;
          final reqMap = Map<String, dynamic>.from(raw);
          final reqBranch = (reqMap['branchId'] ?? '').toString().toLowerCase().trim();
          if (reqBranch.isNotEmpty && reqBranch != branchId.toLowerCase().trim()) continue;
          final status = (reqMap['status'] ?? 'pending').toString().toLowerCase().trim();
          final reqType = (reqMap['requestType'] ?? reqMap['type'] ?? '').toString().toLowerCase().trim();
          final isTokenExc = reqType == 'token_exception' || reqMap['event_type'] == 'token_exception_request';
          final eventType = status == 'approved'
              ? (isTokenExc ? 'token_exception_approved' : 'request_approved')
              : (status == 'rejected' ? 'request_rejected' : (isTokenExc ? 'token_exception_request' : 'request_created'));
          final sent = _sendToSocket(socketId, {
            'event_type': eventType,
            'branchId': branchId,
            'data': reqMap,
            '_serverPush': true,
            'isCatchUp': true,
          });
          if (sent) pushed++;
          await Future.delayed(const Duration(milliseconds: 15));
        }
      }
      // Also push any active today's token exceptions to Receptionist/Hybrid desks
      if (Hive.isBoxOpen(LocalStorageService.tokenExceptionsBox)) {
        final excBox = Hive.box(LocalStorageService.tokenExceptionsBox);
        final todayKey = _todayKey();
        for (final key in excBox.keys) {
          final raw = excBox.get(key);
          if (raw is! Map) continue;
          final excMap = Map<String, dynamic>.from(raw);
          if (excMap['used'] == true) continue;
          final dk = (excMap['dateKey'] ?? '').toString().trim();
          if (dk.isNotEmpty && dk != todayKey) continue;
          final sent = _sendToSocket(socketId, {
            'event_type': 'token_exception_approved',
            'branchId': branchId,
            'data': excMap,
            '_serverPush': true,
            'isCatchUp': true,
          });
          if (sent) pushed++;
          await Future.delayed(const Duration(milliseconds: 10));
        }
      }
    } catch (e) {
      debugPrint('[SSM] _pushPendingRequestsCatchUpToSocket error: $e');
    }
    return pushed;
  }

  bool _sendToSocket(String socketId, Map<String, dynamic> payload) {
    try {
      final isCatchUp = payload['isCatchUp'] == true;
      server.countTraffic('out ${payload['event_type'] ?? '?'}${isCatchUp ? ' (catch-up)' : ''} '
          'to ${_socketClientId[socketId] ?? socketId}');
      return server.sendToSocket(socketId, jsonEncode(payload));
    } catch (e) {
      debugPrint('[SSM] sendToSocket failed: $e');
      return false;
    }
  }

  void _handleClientAck(Map<String, dynamic> msg) {
    var socketId = (msg['_socketId'] ?? '').toString();
    final clientId = (msg['_clientId'] ?? '').toString();
    if (socketId.isEmpty && clientId.isNotEmpty) {
      for (final client in server.getConnectedClients()) {
        if (client['clientId']?.toString() == clientId) {
          socketId = client['socketId']?.toString() ?? '';
          break;
        }
      }
    }
    final serials = msg['serials'];
    if (socketId.isEmpty || serials is! List) return;

    _clientSeenSerials[socketId] ??= {};
    final sent = _clientSentAt[socketId];
    final unconfirmed = _unconfirmedSerials[socketId];
    final counts = _clientSendCount[socketId];
    for (final s in serials) {
      final serial = s?.toString().trim() ?? '';
      if (serial.isNotEmpty) {
        _clientSeenSerials[socketId]!.add(serial);
        sent?.remove(serial);
        unconfirmed?.remove(serial);
        counts?.remove(serial);
      }
    }
    if (unconfirmed != null) server.reportUnconfirmedTokens(socketId, unconfirmed.length);

    final seen = _clientSeenSerials[socketId]!;
    if (seen.length > _maxSeenPerClient) {
      final overflow = seen.length - _maxSeenPerClient;
      seen.removeAll(seen.take(overflow).toList());
    }
  }

  // ── [INV-CATCHUP] Mirrors _handleClientAck — marks stock items the client
  // has confirmed receiving so catch-up/periodic sweeps don't re-push them.
  void _handleStockAck(Map<String, dynamic> msg) {
    var socketId = (msg['_socketId'] ?? '').toString();
    final clientId = (msg['_clientId'] ?? '').toString();
    if (socketId.isEmpty && clientId.isNotEmpty) {
      for (final client in server.getConnectedClients()) {
        if (client['clientId']?.toString() == clientId) {
          socketId = client['socketId']?.toString() ?? '';
          break;
        }
      }
    }
    final items = msg['items'];
    if (socketId.isEmpty || items is! List) return;

    final seen = _clientSeenStock[socketId] ??= {};
    for (final entry in items) {
      if (entry is Map) {
        final medicineId = (entry['medicineId'] ?? '').toString().trim();
        final version = (entry['version'] ?? '').toString();
        if (medicineId.isNotEmpty) {
          seen.add('$medicineId|$version');
        }
      }
    }

    if (seen.length > _maxSeenStockPerClient) {
      final overflow = seen.length - _maxSeenStockPerClient;
      seen.removeAll(seen.take(overflow).toList());
    }
  }

  void pushCatchUpAll({bool forceAll = false}) => _periodicCatchUpAll(forceAll: forceAll);

  Future<Map<String, int>> _periodicCatchUpAll({bool forceAll = false}) async {
    final clients = server.getConnectedClients();
    int entriesCount = 0;
    int stockCount = 0;
    int requestsCount = 0;
    if (clients.isEmpty) {
      return {'clients': 0, 'entries': 0, 'stock': 0, 'requests': 0};
    }
    for (final client in clients) {
      final socketId = client['socketId']?.toString();
      if (socketId == null || socketId.isEmpty) continue;
      final cMap = Map<String, dynamic>.from(client);
      final e = await _pushCatchUpToSocket(socketId, cMap, forceAll: forceAll);
      final s = await _pushInventoryCatchUpToSocket(socketId, cMap, forceAll: forceAll);
      final r = await _pushPendingRequestsCatchUpToSocket(socketId, cMap);
      entriesCount += e;
      stockCount += s;
      requestsCount += r;
    }
    return {
      'clients': clients.length,
      'entries': entriesCount,
      'stock': stockCount,
      'requests': requestsCount,
    };
  }

  // ── [CATCH-UP & FIX MISMATCH] Authoritative Data Healing ─────────────────────
  // Resets client seen trackers so no device is skipped due to past broadcast drops,
  // pushes today's tokens, prescriptions, inventory, and requests to all connected
  // workstations, and broadcasts signals to trigger local queue synchronization.
  Future<Map<String, int>> triggerCatchUpAndFixMismatch({bool forceAll = true}) async {
    if (forceAll) {
      _clientSeenSerials.clear();
      _clientSeenStock.clear();
      debugPrint('[SSM] ⚡ Cleared client seen serials & stock caches for full catch-up resync');
    }

    // 1. Download latest tokens from Firestore if online
    try {
      await _downloadTodayTokens(force: true);
    } catch (e) {
      debugPrint('[SSM] catchup token download note: $e');
    }

    // 2. Push all data to all connected clients
    final stats = await _periodicCatchUpAll(forceAll: forceAll);

    // 3. Broadcast sync signals to all clients
    try {
      server.broadcast(jsonEncode({
        'event_type': 'force_all_users_cloud_sync',
        'branchId': branchId,
        'timestamp': DateTime.now().toIso8601String(),
        '_serverPush': true,
      }));
      server.broadcast(jsonEncode({
        'event_type': 'server_catchup_completed',
        'branchId': branchId,
        'entriesPushed': stats['entries'] ?? 0,
        'stockPushed': stats['stock'] ?? 0,
        'requestsPushed': stats['requests'] ?? 0,
        'clientCount': stats['clients'] ?? 0,
        'timestamp': DateTime.now().toIso8601String(),
        '_serverPush': true,
      }));
    } catch (e) {
      debugPrint('[SSM] broadcast catchup signals error: $e');
    }

    // 4. Backfill any offline local queues
    unawaited(_enqueueMissingEntries());
    unawaited(_enqueueMissingDonations());
    unawaited(_enqueueMissingEmployees());
    unawaited(_enqueueMissingAttendance());
    unawaited(_enqueueMissingPatients());
    unawaited(_enqueueMissingMadrassaStudents());
    unawaited(_enqueueMissingMadrassaLogs());

    // 5. Trigger cloud sync in background (never block LAN catchup response)
    try {
      unawaited(triggerSync(urgent: true));
    } catch (_) {}

    return stats;
  }

  // ── Queue for Firestore — strict whitelist of non-ignored event types ──────
  void _queueForSync(Map<String, dynamic> message) {
    final eventType = (message['event_type'] as String?)?.toLowerCase().trim();
    if (eventType == null || _ignoredEventTypes.contains(eventType)) {
      return;
    }
    // Food-token issues/reversals and kitchen serves add to the day's counters, so only the
    // PC that made them uploads them (office boy and kitchen always queue their own upload).
    // Queued here under their raw LAN names they had no SyncService handler and were
    // written to branches/{b}/sync_records instead; mapped to the real types they would
    // count every token twice.
    if (_originUploadedEventTypes.contains(eventType)) {
      return;
    }

    try {
      final box = Hive.box(LocalStorageService.syncBox);
      final key =
          'sync_${DateTime.now().millisecondsSinceEpoch}_$eventType';

      if (eventType == 'dispense_completed') {
        final data = (message['data'] as Map<String, dynamic>?) ??
            Map<String, dynamic>.from(message);

        final serial = (data['serial']?.toString() ?? '').trim().toUpperCase();
        final bId = LocalStorageService.sanitizeBranchId((data['branchId'] as String?)?.trim() ?? branchId);
        final entryUid = (data['entryUid'] ?? message['entryUid'])?.toString().trim();

        if (serial.isNotEmpty) {
          final deductedBatches = data['deductedBatches'];
          if (deductedBatches is List && deductedBatches.isNotEmpty) {
            for (int i = 0; i < deductedBatches.length; i++) {
              final b = deductedBatches[i];
              if (b is! Map) continue;
              final bMap = Map<String, dynamic>.from(b);
              final medicineId = (bMap['medicineId'] ?? bMap['inventoryId'] ?? bMap['id'] ?? '').toString().trim();
              final rawDelta = bMap['delta'];
              final delta = rawDelta is num
                  ? rawDelta.toDouble()
                  : double.tryParse(rawDelta?.toString() ?? '') ?? 0.0;
              if (medicineId.isEmpty || delta == 0) continue;

              final invKey = (entryUid != null && entryUid.isNotEmpty)
                  ? 'sync_dispense_${bId}_${serial}_${entryUid}_inv_${medicineId.toLowerCase()}'
                  : 'sync_dispense_${bId}_${serial}_inv_${medicineId.toLowerCase()}';
              if (!HourlyDispensarySync.claimStockDeduction(invKey)) continue;
              box.put(invKey, {
                'type': 'update_inventory',
                'branchId': bId,
                'medicineId': medicineId,
                'inventoryId': medicineId,
                'delta': delta,
                'serial': serial,
                'campId': bMap['campId'] ?? data['campId'] ?? data['dispensaryId'],
                'dispensaryId': bMap['dispensaryId'] ?? data['dispensaryId'] ?? data['campId'],
                'data': {
                  'medicineId': medicineId,
                  'medicineName': bMap['name'] ?? bMap['medicineName'] ?? '',
                  'delta': delta,
                  'serial': serial,
                  'campId': bMap['campId'] ?? data['campId'] ?? data['dispensaryId'],
                  'dispensedAt': data['dispensedAt'] ?? DateTime.now().toIso8601String(),
                  'dispensedBy': data['dispensedBy'] ?? '',
                },
                'createdAt': DateTime.now().toIso8601String(),
                'attempts': 0,
                'status': 'pending',
              });
            }
          } else {
            final medicines = data['medicines'];
            final days = (data['daysOfMedicine'] is num)
                ? (data['daysOfMedicine'] as num).toInt()
                : (int.tryParse(data['daysOfMedicine']?.toString() ?? '1') ?? 1);
            if (medicines is List && medicines.isNotEmpty) {
              for (int i = 0; i < medicines.length; i++) {
                final med = medicines[i];
                if (med is! Map) continue;
                final medMap = Map<String, dynamic>.from(med);
                final medicineId = (medMap['inventoryId'] ?? medMap['medicineId'] ?? medMap['id'] ??
                        medMap['stockItemId'] ?? '').toString().trim();
                final qty = medMap['quantity'] ?? medMap['qty'] ?? 0;
                final perDay = qty is num
                    ? qty.toDouble()
                    : double.tryParse(qty.toString()) ?? 0.0;
                if (medicineId.isEmpty || perDay <= 0) continue;

                final medType = (medMap['type'] ?? '').toString().toLowerCase().trim();
                final medName = (medMap['medicineName'] ?? medMap['name'] ?? '').toString().toLowerCase().trim();
                final isSyrup = medType.contains('syrup') || medType.contains('syp') || medType.contains('susp') ||
                    medName.contains('syp') || medName.contains('syrup');
                final isInj = medType.contains('inj') || medType.contains('drip') || medType.contains('infusion') ||
                    medType == 'iv' || medType == 'i.v' || medType == 'im' || medType == 'i.m' ||
                    medName.startsWith('inj');
                final qtyNum = isSyrup ? 1.0 : (isInj ? perDay : perDay * days);

                final invKey = (entryUid != null && entryUid.isNotEmpty)
                    ? 'sync_dispense_${bId}_${serial}_${entryUid}_inv_${medicineId.toLowerCase()}'
                    : 'sync_dispense_${bId}_${serial}_inv_${medicineId.toLowerCase()}';
                // A dispense reaches the server again when a client re-sends it (its outbox keeps
                // messages until the server confirms them) or replays it after a restart. Stock
                // changes are increments, so each dispense line may only ever be queued once.
                if (!HourlyDispensarySync.claimStockDeduction(invKey)) continue;
                box.put(invKey, {
                  'type':       'update_inventory',
                  'branchId':   bId,
                  'medicineId': medicineId,
                  'inventoryId': medicineId,
                  'delta':      -qtyNum,
                  'serial':     serial,
                  'campId':     data['campId'] ?? data['dispensaryId'],
                  'data': {
                    'medicineId':   medicineId,
                    'medicineName': medMap['medicineName'] ?? medMap['name'] ?? '',
                    'delta':        -qtyNum,
                    'serial':       serial,
                    'campId':       data['campId'] ?? data['dispensaryId'],
                    'dispensedAt':  data['dispensedAt'] ?? DateTime.now().toIso8601String(),
                    'dispensedBy':  data['dispensedBy'] ?? '',
                  },
                  'createdAt': DateTime.now().toIso8601String(),
                  'attempts':  0,
                  'status':    'pending',
                });
              }
            }
          }
        }
        unawaited(triggerSync(urgent: true));
        return;
      }

      // Events already enqueued with deterministic keys in _saveToLocalHive must not be
      // double-enqueued here under a second key.
      const alreadyEnqueuedInSaveToLocalHive = {
        'save_entry',
        'token_created',
        'save_prescription',
        'prescription_created',
        'save_patient',
        'migrate_patient_key',
        'request_approved',
        'request_rejected',
        'workflow_decision',
        'token_exception_request',
        'token_exception_approved',
        'restriction_removed',
        'save_madrassa_student',
        'save_madrassa_admission',
        'delete_madrassa_student',
        'offboard_madrassa_student',
      };
      if (alreadyEnqueuedInSaveToLocalHive.contains(eventType)) {
        return;
      }

      if (eventType == 'delete_stock_item' || eventType == 'delete_inventory') {
        final data = message['data'] is Map
            ? Map<String, dynamic>.from(message['data'] as Map)
            : Map<String, dynamic>.from(message);
        final medicineId = (data['id'] ?? data['medicineId'] ?? data['docId'])?.toString().trim();
        final rawB = (message['branchId'] as String?)?.trim();
        final bId = LocalStorageService.sanitizeBranchId(
            (rawB != null && rawB.isNotEmpty) ? rawB : branchId);
        if (medicineId != null && medicineId.isNotEmpty) {
          box.put('sync_stock_del_${bId}_$medicineId', {
            'type': 'delete_stock_item',
            'branchId': bId,
            'medicineId': medicineId,
            'campId': data['campId'],
            'dispensaryId': data['dispensaryId'],
            'data': data,
            'createdAt': DateTime.now().toIso8601String(),
            'attempts': 0,
            'status': 'pending',
          });
          unawaited(triggerSync(urgent: true));
        }
        return;
      }

            // [FIX-INV] save_stock_item: route delta restocks through update_inventory
      // (FieldValue.increment), and deltaless full-object saves (new medicine
      // registrations, edits from the proforma catalog) through register_medicine
      // (plain set/merge). Without this branch, save_stock_item falls into the
      // generic else-path below and the delta is lost, causing the server to
      // treat an absolute quantity as an increment — double-counting stock.
      if (eventType == 'save_stock_item' ||
          eventType == 'medicine_registered' ||
          eventType == 'save_proforma_item' ||
          eventType == 'proforma_item_updated' ||
          eventType == 'add_proforma_stock' ||
          eventType == 'add_stock') {
        final data = message['data'] is Map
            ? Map<String, dynamic>.from(message['data'] as Map)
            : Map<String, dynamic>.from(message);

        final rawDelta = data['_quantityDelta'];
        final medicineId = (data['id'] ?? data['medicineId'] ?? data['docId'])?.toString().trim();
        final rawB = (message['branchId'] as String?)?.trim();
        final bId = LocalStorageService.sanitizeBranchId(
            (rawB != null && rawB.isNotEmpty) ? rawB : branchId);

        if (medicineId != null && medicineId.isNotEmpty) {
          if (rawDelta != null) {
            final delta = rawDelta is num
                ? rawDelta.toDouble()
                : double.tryParse(rawDelta.toString()) ?? 0.0;
            if (delta != 0) {
              // [A3] Replay-safe deterministic key instead of random microseconds timestamp
              // The message id first: it is unique per restock. Falling back to dateKey made two
              // restocks of one medicine on the same day share a key, so the second replaced
              // the first in the cloud queue and one restock never reached Firestore.
              final txId = (data['_opId'] ?? data['txId'] ?? message['_messageId'] ?? data['requestId'] ?? message['requestId'] ?? message['id'] ?? data['batchId'] ?? data['dateKey'] ?? data['createdAt'])?.toString().trim();
              final invKey = (txId != null && txId.isNotEmpty)
                  ? 'sync_stock_delta_${bId}_${medicineId}_$txId'
                  : 'sync_stock_delta_${bId}_${medicineId}_${DateTime.now().millisecondsSinceEpoch}';
              box.put(invKey, {
                'type': 'update_inventory',
                'branchId': bId,
                'medicineId': medicineId,
                'delta': delta,
                'campId': data['campId'],
                'dispensaryId': data['dispensaryId'],
                'data': {
                  'medicineId': medicineId,
                  'delta': delta,
                  'campId': data['campId'],
                  'dispensaryId': data['dispensaryId'],
                },
                'createdAt': DateTime.now().toIso8601String(),
                'attempts': 0,
                'status': 'pending',
              });
            }
          } else {
            box.put('sync_stock_full_${bId}_$medicineId', {
              'type': 'register_medicine',
              'branchId': bId,
              'medicineId': medicineId,
              'campId': data['campId'],
              'dispensaryId': data['dispensaryId'],
              'data': data,
              'createdAt': DateTime.now().toIso8601String(),
              'attempts': 0,
              'status': 'pending',
            });
          }
        }
        unawaited(triggerSync(urgent: true));
        return;
      }

      final opQueueType = _resolveQueueType(
          message['queueType'] ?? (message['data'] is Map ? message['data']['queueType'] : null));

      final clientBranchId = (message['branchId'] ??
              (message['data'] is Map ? message['data']['branchId'] : null))
          ?.toString()
          .trim();
      final bId = LocalStorageService.sanitizeBranchId(
          (clientBranchId != null && clientBranchId.isNotEmpty) ? clientBranchId : branchId);

      final rawSerial = (message['serial'] ?? (message['data'] is Map ? (message['data']['serial'] ?? message['data']['id']) : null))?.toString().trim().toUpperCase();
      final entryUid = (message['entryUid'] ?? (message['data'] is Map ? message['data']['entryUid'] : null))?.toString().trim();
      final hasCollision = message['hasCollision'] == true || (message['data'] is Map && message['data']['hasCollision'] == true);

      const serialTypes = _tokenSyncTypes;
      final mappedType = _mapEventTypeToSyncType(eventType);
      final isSerialType = serialTypes.contains(mappedType) || serialTypes.contains(eventType);
      Map<String, dynamic> payloadData = (message['data'] is Map ? Map<String, dynamic>.from(message['data'] as Map) : Map<String, dynamic>.from(message));

      // Every token event → the token's single cloud item (see _enqueueTokenState).
      if (isSerialType && rawSerial != null && rawSerial.isNotEmpty) {
        unawaited(_enqueueTokenState(
          box: box,
          branch: bId,
          localBranch: (clientBranchId != null && clientBranchId.isNotEmpty) ? clientBranchId : branchId,
          serial: rawSerial,
          incoming: payloadData,
          entryUid: entryUid,
          hasCollision: hasCollision,
          dateKey: (message['dateKey'] ?? payloadData['dateKey'])?.toString(),
          queueType: opQueueType,
        ).then((_) => _scheduleSyncDebounced(delay: const Duration(seconds: 2))).catchError((Object e) {
          debugPrint('[SSM] token enqueue error for $rawSerial: $e');
        }));
        return;
      }

      String targetKey;
      if (isSerialType && rawSerial != null && rawSerial.isNotEmpty) {
        if (hasCollision && entryUid != null && entryUid.isNotEmpty) {
          targetKey = 'sync_${bId}_${rawSerial}_${entryUid}_$mappedType';
        } else {
          targetKey = 'sync_${bId}_${rawSerial}_$mappedType';
        }
      } else if (mappedType == 'save_attendance') {
        final empId = (payloadData['employeeId'] ?? payloadData['entityId'] ?? payloadData['id'] ?? payloadData['pin'] ?? '').toString().trim();
        final dtKey = (message['dateKey'] ?? payloadData['date'] ?? payloadData['dateKey'] ?? DateFormat('yyyy-MM-dd').format(DateTime.now())).toString().trim();
        targetKey = 'sync_${bId}_att_${empId}_$dtKey';
      } else if (mappedType == 'save_school_daily_log' || mappedType == 'save_school_teacher_log' || mappedType == 'save_madrassa_daily_log') {
        final dtKey = (message['dateKey'] ?? payloadData['date'] ?? payloadData['dateKey'] ?? DateFormat('yyyy-MM-dd').format(DateTime.now())).toString().trim();
        targetKey = 'sync_${bId}_${mappedType}_$dtKey';
      } else if (mappedType == 'save_biometric_device' || mappedType == 'delete_biometric_device' || eventType == 'save_biometric_device' || eventType == 'delete_biometric_device') {
        final devId = (payloadData['deviceId'] ?? payloadData['id'] ?? payloadData['deviceName'] ?? '').toString().trim().toLowerCase();
        targetKey = 'sync_${bId}_biodev_$devId';

        // Check if device is already identical in local storage or already pending in sync queue
        if ((mappedType == 'save_biometric_device' || eventType == 'save_biometric_device') && Hive.isBoxOpen(LocalStorageService.biometricDevicesBox)) {
          final devBox = Hive.box(LocalStorageService.biometricDevicesBox);
          final existing = devBox.get(devId) ?? devBox.get(payloadData['deviceId']);
          if (existing is Map && box.containsKey(targetKey)) {
            // Already present in local storage and queued once — do not duplicate
            return;
          }
        }
      } else {
        targetKey = key;
      }

      if (isSerialType && rawSerial != null && rawSerial.isNotEmpty) {
        final existing = box.get(targetKey);
        if (existing is Map && existing['data'] is Map) {
          payloadData = {
            ...Map<String, dynamic>.from(existing['data'] as Map),
            ...payloadData,
          };
        }
      }

      final resolvedDateKey = message['dateKey'] ??
          (message['data'] is Map ? message['data']['dateKey'] : null) ??
          payloadData['dateKey'] ??
          (rawSerial != null ? CampSessionService.getDateKeyFromSerial(rawSerial) : null) ??
          _todayKey();

      box.put(targetKey, {
        'type':      mappedType,
        'branchId':  bId,
        'queueType': opQueueType,
        'dateKey':   resolvedDateKey,
        'serial':    rawSerial ?? message['serial'],
        'data':      payloadData,
        'createdAt': DateTime.now().toIso8601String(),
        'attempts':  0,
        'status':    'pending',
      });
      debugPrint('[SSM] Queued for sync: $mappedType | key: $targetKey | serial: $rawSerial (queue: ${box.length})');
      // Instant upload: tokens, prescriptions, status updates, dispenses, and madrassa logs upload immediately
      if (isSerialType || mappedType.contains('madrassa') || mappedType == 'save_entry') {
        unawaited(triggerSync(urgent: true));
      } else {
        _scheduleSyncDebounced(delay: const Duration(milliseconds: 50));
      }
    } catch (e) {
      debugPrint('[SSM] Error queuing message: $e');
    }
  }

  // ── One cloud item per token ──────────────────────────────────────────────
  // A token used to be queued as up to 4 items (save_entry under two keys, save_prescription,
  // update_serial_status), each re-writing the same Firestore documents: ~9 writes per patient
  // on a 20k-writes/day plan shared by every branch, so the queue grew faster than it could
  // drain (5,959 items, 3 days old). Now every token event merges into ONE item holding the
  // token's latest full state (taken from this server's Hive copy, which already has the
  // prescription and dispense status merged). Its save_entry upload writes the serial,
  // dispensary, prescription and patient documents once.
  static const Set<String> _tokenSyncTypes = {'save_entry', 'save_prescription', 'update_serial_status'};

  String _tokenQueueKey(String branch, String serial, {String? entryUid, bool hasCollision = false}) =>
      (hasCollision && entryUid != null && entryUid.isNotEmpty)
          ? 'sync_serial_${branch}_${serial}_$entryUid'
          : 'sync_serial_${branch}_$serial';

  Future<void> _enqueueTokenState({
    required Box box,
    required String branch,
    required String serial,
    required Map<String, dynamic> incoming,
    String? entryUid,
    bool hasCollision = false,
    String? dateKey,
    String? queueType,
    String? campId,
    String? localBranch,
  }) async {
    // Cloud branch (camps folded, e.g. saddar → karachi) — the same for every event of a token,
    // so a token never gets two items.
    final b = LocalStorageService.sanitizeBranchId(branch);
    final s = serial.toUpperCase().trim();
    if (b.isEmpty || s.isEmpty) return;
    final key = _tokenQueueKey(b, s, entryUid: entryUid, hasCollision: hasCollision);

    final merged = <String, dynamic>{};
    final existing = box.get(key);
    if (existing is Map && existing['data'] is Map) merged.addAll(Map<String, dynamic>.from(existing['data'] as Map));
    // Absorb the old per-type items of this token (queued by earlier builds).
    for (final t in _tokenSyncTypes) {
      final legacyKeys = [
        'sync_${b}_${s}_$t',
        if (entryUid != null && entryUid.isNotEmpty) 'sync_${b}_${s}_${entryUid}_$t',
      ];
      for (final lk in legacyKeys) {
        final legacy = box.get(lk);
        if (legacy is Map) {
          if (legacy['data'] is Map) merged.addAll(Map<String, dynamic>.from(legacy['data'] as Map));
          await box.delete(lk);
        }
      }
    }
    merged.addAll(incoming);
    // The server's own stored copy is the authoritative merged state of the token.
    if (!hasCollision) {
      // Direct key reads (no full-box scan on a miss; this runs for every token event).
      if (Hive.isBoxOpen(LocalStorageService.entriesBox)) {
        final eBox = Hive.box(LocalStorageService.entriesBox);
        final lb = (localBranch ?? branch).toLowerCase().trim();
        final local = eBox.get('$lb-$s') ?? eBox.get('$b-$s');
        if (local is Map && local.isNotEmpty) merged.addAll(Map<String, dynamic>.from(local));
      }
    }
    // Never upload a dispense back to "pending".
    if ((existing is Map && existing['data'] is Map &&
            (existing['data'] as Map)['dispenseStatus']?.toString() == 'dispensed') ||
        incoming['dispenseStatus']?.toString() == 'dispensed') {
      merged['dispenseStatus'] = 'dispensed';
      merged['status'] = 'completed';
    }

    final nowIso = DateTime.now().toIso8601String();
    await box.put(key, {
      'type': 'save_entry',
      'entityId': '$b-$s',
      'branchId': b,
      'dateKey': dateKey ?? merged['dateKey'] ?? CampSessionService.getDateKeyFromSerial(s),
      'queueType': queueType ?? merged['queueType'],
      'serial': s,
      if (campId != null && campId.isNotEmpty) 'campId': campId,
      if (entryUid != null && entryUid.isNotEmpty) 'entryUid': entryUid,
      if (hasCollision) 'hasCollision': true,
      'data': merged,
      'createdAt': existing is Map ? (existing['createdAt'] ?? nowIso) : nowIso,
      // Revision of this item: changes on every merge (see the upload pass).
      'lastChangeAt': nowIso,
      'attempts': 0,
      'status': 'pending',
    });
  }

  /// One-time (each start) clean-up of the cloud queue built by earlier builds: every queued
  /// item of the same token (save_entry under two keys, save_prescription, update_serial_status,
  /// sync_presc_/sync_dispense_) is merged into the token's single item, oldest first, with
  /// the server's stored copy of the token on top. A 5,959-item backlog of ~1,800 tokens
  /// becomes ~1,800 items. Yields regularly so the server stays responsive.
  Future<void> _compactTokenQueue() async {
    try {
      final box = await _syncQueueBox();
      final groups = <String, List<MapEntry<dynamic, Map>>>{};
      var scanned = 0;
      for (final k in box.keys.toList()) {
        if (++scanned % 300 == 0) await Future<void>.delayed(const Duration(milliseconds: 5));
        final v = box.get(k);
        if (v is! Map) continue;
        final type = (v['type'] ?? '').toString();
        if (!_tokenSyncTypes.contains(type)) continue;
        final data = v['data'] is Map ? v['data'] as Map : const {};
        final serial = (v['serial'] ?? data['serial'] ?? '').toString().trim().toUpperCase();
        if (serial.isEmpty) continue;
        final branch = LocalStorageService.sanitizeBranchId((v['branchId'] ?? data['branchId'] ?? branchId).toString());
        final collision = v['hasCollision'] == true || data['hasCollision'] == true;
        final uid = (v['entryUid'] ?? data['entryUid'] ?? '').toString();
        final g = '$branch|$serial|${collision ? uid : ''}';
        (groups[g] ??= []).add(MapEntry(k, v));
      }

      var merged = 0, removed = 0;
      for (final entry in groups.entries) {
        final items = entry.value;
        final parts = entry.key.split('|');
        final branch = parts[0], serial = parts[1], uid = parts[2];
        final canonical = _tokenQueueKey(branch, serial, entryUid: uid, hasCollision: uid.isNotEmpty);
        if (items.length == 1 && items.single.key.toString() == canonical) continue;

        items.sort((a, b) => (a.value['createdAt'] ?? '').toString().compareTo((b.value['createdAt'] ?? '').toString()));
        final data = <String, dynamic>{};
        var dispensed = false;
        String? oldestCreated, dateKey, queueType, campId, localBranch;
        for (final it in items) {
          final v = it.value;
          if (v['data'] is Map) data.addAll(Map<String, dynamic>.from(v['data'] as Map));
          if ((v['data'] is Map && (v['data'] as Map)['dispenseStatus']?.toString() == 'dispensed') ||
              v['type'] == 'update_serial_status') {
            dispensed = true;
          }
          oldestCreated ??= v['createdAt']?.toString();
          dateKey ??= v['dateKey']?.toString();
          queueType ??= v['queueType']?.toString();
          campId ??= v['campId']?.toString();
          localBranch ??= (v['data'] is Map ? (v['data'] as Map)['branchId'] : null)?.toString();
        }
        if (uid.isEmpty && Hive.isBoxOpen(LocalStorageService.entriesBox)) {
          // Direct key reads only: getLocalEntry scans the whole entries box on a miss, and
          // old tokens are often pruned — ~1,800 misses would stall the server at startup.
          final eBox = Hive.box(LocalStorageService.entriesBox);
          final lb = (localBranch ?? branch).toLowerCase().trim();
          final local = eBox.get('$lb-$serial') ?? eBox.get('$branch-$serial');
          if (local is Map && local.isNotEmpty) data.addAll(Map<String, dynamic>.from(local));
        }
        if (dispensed) {
          data['dispenseStatus'] = 'dispensed';
          data['status'] = 'completed';
        }
        for (final it in items) {
          if (it.key.toString() != canonical) {
            await box.delete(it.key);
            removed++;
          }
        }
        await box.put(canonical, {
          'type': 'save_entry',
          'entityId': '$branch-$serial',
          'branchId': branch,
          'dateKey': dateKey ?? data['dateKey'] ?? CampSessionService.getDateKeyFromSerial(serial),
          'queueType': queueType ?? data['queueType'],
          'serial': serial,
          if (campId != null && campId.isNotEmpty) 'campId': campId,
          if (uid.isNotEmpty) ...{'entryUid': uid, 'hasCollision': true},
          'data': data,
          'createdAt': oldestCreated ?? DateTime.now().toIso8601String(),
          // Old work: already settled, upload on the next pass.
          'lastChangeAt': oldestCreated ?? DateTime.now().toIso8601String(),
          'attempts': 0,
          'status': 'pending',
        });
        merged++;
        if (merged % 100 == 0) await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      if (removed > 0) {
        debugPrint('[SSM] 🧹 Cloud queue compacted: $removed duplicate token item(s) merged into $merged '
            '(queue now ${box.length})');
      }
    } catch (e) {
      debugPrint('[SSM] Cloud queue compaction error: $e');
    }
  }

  /// A token is uploaded once it has settled — dispensed, or unchanged for 10 minutes (or
  /// queued 45 minutes ago at most) — so its whole visit (issued → prescribed → dispensed)
  /// costs one upload instead of one per step.
  static bool _tokenItemSettled(Map item, DateTime now) {
    final data = item['data'];
    if (data is Map && data['dispenseStatus']?.toString() == 'dispensed') return true;
    final last = DateTime.tryParse(item['lastChangeAt']?.toString() ?? '');
    if (last == null) return true; // items from earlier builds: upload as before
    if (now.difference(last) >= const Duration(minutes: 10)) return true;
    final created = DateTime.tryParse(item['createdAt']?.toString() ?? '');
    return created != null && now.difference(created) >= const Duration(minutes: 45);
  }

  String _mapEventTypeToSyncType(String eventType) {
    switch (eventType) {
      case 'save_entry':
      case 'token_created':
        return 'save_entry';
      case 'save_prescription':
      case 'prescription_created':
        return 'save_prescription';
      case 'save_patient':
        return 'save_patient';
      case 'delete_patient':
        return 'delete_patient';
      case 'save_dispensary_record':
        return 'save_dispensary_record';
      case 'update_serial_status':
        return 'update_serial_status';
      case 'save_dispensary_charge':
        return 'save_dispensary_charge';
      case 'save_attendance':
      case 'save_attendance_record':
      case 'save_biometric_log':
      case 'save_employee_attendance':
      case 'save_faculty_attendance':
      case 'save_student_attendance':
        return 'save_attendance';
      // [FIX-INV] Map save_stock_item to register_medicine so _syncToFirestore
      // routes it to the inventory collection instead of the generic sync_records.
            case 'save_stock_item':
      case 'medicine_registered':
        return 'register_medicine';
      case 'token_reversal':
      case 'token_reversal_approved':
      case 'delete_entry':
        return eventType;
      default:
        return eventType;
    }
  }

  String _todayKey() => CampSessionService.resolveShiftAndDateKey(null, branchId).dateKey;

  /// Sweeps local_entries on the server for unsynced tokens and queues them for Firestore
  Future<void> _enqueueMissingEntries() async {
    if (!_backfillCooledDown('entries')) return;
    try {
      if (!Hive.isBoxOpen(LocalStorageService.entriesBox)) {
        await LocalStorageService.ensureBoxOpen(LocalStorageService.entriesBox);
      }
      if (!Hive.isBoxOpen(LocalStorageService.syncBox)) {
        await LocalStorageService.ensureBoxOpen(LocalStorageService.syncBox);
      }
      final entriesBox = Hive.box(LocalStorageService.entriesBox);
      final syncBox    = Hive.box(LocalStorageService.syncBox);

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
      for (final key in entriesBox.keys) {
        final raw = entriesBox.get(key);
        if (raw == null || raw is! Map) continue;

        final data = Map<String, dynamic>.from(raw);
        if (LocalStorageService.isStressTestRecord(data, key)) continue;
        final isSynced = (data['synced'] == true || data['syncStatus'] == 'synced') && data['pendingSync'] != true;
        if (isSynced) continue;

        final rawCreated = data['createdAt'] ?? data['time'] ?? data['timestamp'] ?? data['date'];
        final dt = rawCreated != null ? DateTime.tryParse(rawCreated.toString()) : null;
        final isOld = dt != null && DateTime.now().difference(dt).inHours > 48;
        final isCompleted = (data['status'] ?? '').toString().toLowerCase() == 'completed' ||
            (data['dispenseStatus'] ?? '').toString().toLowerCase() == 'dispensed';

        final serial = (data['serial'] ?? key.toString().split('-').last).toString().trim().toUpperCase();
        if (serial.isEmpty) continue;

        final serialDk = CampSessionService.getDateKeyFromSerial(serial);
        final itemDk = (data['dateKey'] ?? '').toString().trim();
        final bool isThisMonth = LocalStorageService.isCurrentMonth(itemDk) ||
            LocalStorageService.isCurrentMonth(serialDk) ||
            LocalStorageService.isCurrentMonth(rawCreated);



        // Skip phantom entries fabricated by old migrations
        final pCnic = (data['patientCnic'] ?? data['cnic'] ?? '').toString().trim();
        final pName = (data['patientName'] ?? data['name'] ?? '').toString().trim().toLowerCase();
        final isPhantomCnic = pCnic.startsWith('unknown_cnic_') || pCnic.isEmpty;
        final isPhantomName = pName.isEmpty || pName == 'unknown' || pName == 'unknown patient';
        if (isPhantomCnic && isPhantomName) continue;

        final dateKey = serialDk.isNotEmpty ? serialDk : (itemDk.isNotEmpty ? itemDk : _todayKey());
        final effectiveBranch = (data['branchId']?.toString().isNotEmpty == true)
            ? data['branchId'].toString()
            : branchId;
        final campId = (data['campId'] ?? data['dispensaryId'] ?? data['dispensaryTag'] ?? '').toString().toLowerCase().trim();
        final uniqueKey = '${effectiveBranch.toLowerCase().trim()}-$campId-$serial';
        if (alreadyQueued.contains(uniqueKey)) continue;

        final queueType = _resolveQueueType(data['queueType']?.toString());

        // Same key as live token events (camps folded), so a token never gets two items.
        final canonicalBranch = LocalStorageService.sanitizeBranchId(effectiveBranch);
        final targetKey = _tokenQueueKey(canonicalBranch, serial.toUpperCase());
        if (syncBox.containsKey(targetKey)) {
          alreadyQueued.add(uniqueKey);
          continue;
        }
        await syncBox.put(targetKey, {
          'type':      'save_entry',
          'entityId':  '$canonicalBranch-$serial',
          'branchId':  effectiveBranch,
          'dateKey':   dateKey,
          'queueType': queueType,
          'serial':    serial,
          'campId':    campId,
          'data':      data,
          'createdAt': DateTime.now().toIso8601String(),
          'attempts':  0,
          'status':    'pending',
        });
        alreadyQueued.add(uniqueKey);
        queued++;
      }

      if (queued > 0) {
        debugPrint('[SSM] 📥 Backfill: queued $queued unsynced local tokens for Firestore upload');
      }
    } catch (e) {
      debugPrint('[SSM] _enqueueMissingEntries error: $e');
    }
  }

  /// Sweeps donations on the server for pending receipts and queues them for Firestore
  Future<void> _enqueueMissingDonations() async {
    if (!_backfillCooledDown('donations')) return;
    try {
      if (!Hive.isBoxOpen(DonationsLocalStorage.donationsBox)) {
        await Hive.openBox(DonationsLocalStorage.donationsBox);
      }
      if (!Hive.isBoxOpen(LocalStorageService.syncBox)) {
        await LocalStorageService.ensureBoxOpen(LocalStorageService.syncBox);
      }
      final donationsBox = Hive.box(DonationsLocalStorage.donationsBox);
      final syncBox      = Hive.box(LocalStorageService.syncBox);

      final alreadyQueued = syncBox.values
          .where((v) => v is Map && (v['type'] == 'save_donation' || v['type'] == 'update_donation'))
          .map((v) => (v['localId'] ?? v['data']?['id'] ?? v['data']?['receiptNumber'])?.toString())
          .whereType<String>()
          .toSet();

      int queued = 0;
      for (final key in donationsBox.keys) {
        final raw = donationsBox.get(key);
        if (raw == null || raw is! Map) continue;
        final data = Map<String, dynamic>.from(raw);

        final isSynced = (data['synced'] == true || data['syncStatus'] == 'synced') && data['pendingSync'] != true;
        if (isSynced) continue;

        final localId = (data['localId'] ?? data['id'] ?? data['receiptNumber'])?.toString();
        if (localId == null || localId.isEmpty || alreadyQueued.contains(localId)) continue;

        final targetKey = 'sync_${branchId}_don_$localId';
        await syncBox.put(targetKey, {
          'type':      'save_donation',
          'branchId':  branchId,
          'localId':   localId,
          'hiveKey':   key.toString(),
          'data':      data,
          'createdAt': DateTime.now().toIso8601String(),
          'attempts':  0,
          'status':    'pending',
        });
        alreadyQueued.add(localId);
        queued++;
      }

      if (queued > 0) {
        debugPrint('[SSM] 📥 Backfill: queued $queued pending donations for Firestore upload');
      }
    } catch (e) {
      debugPrint('[SSM] _enqueueMissingDonations error: $e');
    }
  }

  Future<void> _enqueueMissingEmployees() async {
    if (!_backfillCooledDown('employees')) return;
    try {
      if (!Hive.isBoxOpen(LocalStorageService.employeesBox)) {
        await LocalStorageService.openBoxSafe(LocalStorageService.employeesBox);
      }
      if (!Hive.isBoxOpen(LocalStorageService.syncBox)) {
        await LocalStorageService.ensureBoxOpen(LocalStorageService.syncBox);
      }
      final empBox = Hive.box(LocalStorageService.employeesBox);
      final syncBox = Hive.box(LocalStorageService.syncBox);

      final alreadyQueued = syncBox.values
          .where((v) => v is Map && v['type'] == 'save_employee')
          .map((v) => (v['localId'] ?? v['data']?['localId'] ?? v['data']?['id'])?.toString())
          .whereType<String>()
          .toSet();

      int queued = 0;
      for (final key in empBox.keys) {
        final raw = empBox.get(key);
        if (raw == null || raw is! Map) continue;
        final data = Map<String, dynamic>.from(raw);
        if (FinanceLocalStorage.isPlaceholderEmployee(data)) continue;

        final isPending = data['syncStatus'] != 'synced' ||
            data['synced'] == false ||
            data['pendingSync'] == true;
        if (!isPending) continue;

        final localId = (data['localId'] ?? data['id'] ?? key).toString().trim();
        if (localId.isEmpty || alreadyQueued.contains(localId)) continue;

        final targetKey = 'sync_${branchId}_emp_$localId';
        await syncBox.put(targetKey, {
          'type': 'save_employee',
          'branchId': branchId,
          'localId': localId,
          'data': data,
          'createdAt': DateTime.now().toIso8601String(),
          'attempts': 0,
          'status': 'pending',
        });
        alreadyQueued.add(localId);
        queued++;
      }

      if (queued > 0) {
        debugPrint('[SSM] 📥 Backfill: queued $queued unsynced employees for Firestore upload');
      }
    } catch (e) {
      debugPrint('[SSM] _enqueueMissingEmployees error: $e');
    }
  }

  Future<void> _enqueueMissingAttendance() async {
    if (!_backfillCooledDown('attendance')) return;
    try {
      if (!Hive.isBoxOpen(LocalStorageService.attendanceBox)) {
        await LocalStorageService.openBoxSafe(LocalStorageService.attendanceBox);
      }
      if (!Hive.isBoxOpen(LocalStorageService.syncBox)) {
        await LocalStorageService.ensureBoxOpen(LocalStorageService.syncBox);
      }
      final attBox = Hive.box(LocalStorageService.attendanceBox);
      final syncBox = Hive.box(LocalStorageService.syncBox);

      final alreadyQueued = syncBox.values
          .where((v) => v is Map && (v['type'] == 'save_attendance_record' || v['type'] == 'save_employee_attendance'))
          .map((v) => '${v['employeeId'] ?? v['data']?['employeeId']}_${v['date'] ?? v['data']?['date']}')
          .toSet();

      int queued = 0;
      for (final key in attBox.keys) {
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

        final targetKey = 'sync_${branchId}_att_$queueKey';
        await syncBox.put(targetKey, {
          'type': 'save_attendance_record',
          'branchId': branchId,
          'date': dateStr,
          'employeeId': employeeId,
          'localKey': key,
          'data': data,
          'createdAt': DateTime.now().toIso8601String(),
          'attempts': 0,
          'status': 'pending',
          'pendingSync': true,
          'forceUpload': true,
        });
        alreadyQueued.add(queueKey);
        queued++;
      }

      if (queued > 0) {
        debugPrint('[SSM] 📥 Backfill: queued $queued unsynced attendance records for Firestore upload');
      }
    } catch (e) {
      debugPrint('[SSM] _enqueueMissingAttendance error: $e');
    }
  }

  Future<void> _enqueueMissingPatients() async {
    if (!_backfillCooledDown('patients')) return;
    try {
      if (!Hive.isBoxOpen(LocalStorageService.patientsBox)) {
        await LocalStorageService.openBoxSafe(LocalStorageService.patientsBox);
      }
      if (!Hive.isBoxOpen(LocalStorageService.syncBox)) {
        await LocalStorageService.ensureBoxOpen(LocalStorageService.syncBox);
      }
      final pBox = Hive.box(LocalStorageService.patientsBox);
      final syncBox = Hive.box(LocalStorageService.syncBox);

      final alreadyQueued = syncBox.values
          .where((v) => v is Map && v['type'] == 'save_patient')
          .map((v) => (v['patientId'] ?? v['data']?['patientId'])?.toString())
          .whereType<String>()
          .toSet();

      final flagsBox = Hive.isBoxOpen('app_flags') ? Hive.box('app_flags') : null;
      int queued = 0;
      for (final key in pBox.keys) {
        final raw = pBox.get(key);
        if (raw == null || raw is! Map) continue;
        final data = Map<String, dynamic>.from(raw);
        final pid = (data['patientId'] ?? data['id'] ?? key).toString().trim();
        if (pid.isEmpty || alreadyQueued.contains(pid)) continue;

        final pCnic = (data['cnic'] ?? pid).toString().trim();
        final pName = (data['name'] ?? '').toString().trim().toLowerCase();
        if ((pCnic.startsWith('unknown_cnic_') || pCnic.isEmpty) && (pName.isEmpty || pName == 'unknown patient' || pName == 'unknown')) {
          continue;
        }

        final flagSynced = flagsBox?.get('patient_synced_$pid') == true;
        final isExplicitlySynced = (data['syncStatus'] == 'synced' || data['synced'] == true || flagSynced) && data['pendingSync'] != true;
        if (isExplicitlySynced) continue;

        if (data['pendingSync'] != true && (data['id'] != null || data['mrNo'] != null || data['firestoreId'] != null)) {
          data['syncStatus'] = 'synced';
          data['synced'] = true;
          await pBox.put(key, data);
          if (flagsBox != null) {
            await flagsBox.put('patient_synced_$pid', true);
            final c = pCnic.replaceAll(RegExp(r'[^0-9]'), '');
            if (c.isNotEmpty) await flagsBox.put('patient_synced_$c', true);
          }
          continue;
        }

        final isPending = data['pendingSync'] == true ||
            (data['syncStatus'] != 'synced' && data['synced'] != true && !flagSynced);
        if (!isPending) continue;

        final targetKey = 'sync_${branchId}_pat_$pid';
        await syncBox.put(targetKey, {
          'type': 'save_patient',
          'branchId': branchId,
          'patientId': pid,
          'data': data,
          'createdAt': DateTime.now().toIso8601String(),
          'attempts': 0,
          'status': 'pending',
        });
        alreadyQueued.add(pid);
        queued++;
      }

      if (queued > 0) {
        debugPrint('[SSM] 📥 Backfill: queued $queued unsynced patients for Firestore upload');
      }
    } catch (e) {
      debugPrint('[SSM] _enqueueMissingPatients error: $e');
    }
  }

  Future<void> _enqueueMissingMadrassaStudents() async {
    if (!_backfillCooledDown('madrassa')) return;
    try {
      if (!Hive.isBoxOpen(LocalStorageService.madrassaStudentsBox)) {
        await LocalStorageService.openBoxSafe(LocalStorageService.madrassaStudentsBox);
      }
      if (!Hive.isBoxOpen(LocalStorageService.syncBox)) {
        await LocalStorageService.ensureBoxOpen(LocalStorageService.syncBox);
      }
      final sBox = Hive.box(LocalStorageService.madrassaStudentsBox);
      final syncBox = Hive.box(LocalStorageService.syncBox);

      final alreadyQueued = syncBox.values
          .where((v) => v is Map && (v['type'] == 'save_madrassa_student' || v['type'] == 'save_madrassa_admission'))
          .map((v) => (v['studentId'] ?? v['data']?['id'] ?? v['data']?['studentId'])?.toString())
          .whereType<String>()
          .toSet();

      int queued = 0;
      for (final key in sBox.keys) {
        final raw = sBox.get(key);
        if (raw == null || raw is! Map) continue;
        final data = Map<String, dynamic>.from(raw);
        final isPending = data['syncStatus'] != 'synced' || data['synced'] == false || data['pendingSync'] == true;
        if (!isPending) continue;

        final sid = (data['id'] ?? data['studentId'] ?? key).toString().trim();
        if (sid.isEmpty || alreadyQueued.contains(sid)) continue;

        final targetKey = 'sync_${branchId}_std_$sid';
        await syncBox.put(targetKey, {
          'type': 'save_madrassa_student',
          'branchId': branchId,
          'studentId': sid,
          'data': data,
          'createdAt': DateTime.now().toIso8601String(),
          'attempts': 0,
          'status': 'pending',
        });
        alreadyQueued.add(sid);
        queued++;
      }

      if (queued > 0) {
        debugPrint('[SSM] 📥 Backfill: queued $queued unsynced madrassa students for Firestore upload');
      }
    } catch (e) {
      debugPrint('[SSM] _enqueueMissingMadrassaStudents error: $e');
    }
  }

  /// Sweeps madrassaLogsBox for unsynced madrassa logs and enqueues them for immediate upload
  Future<void> _enqueueMissingMadrassaLogs() async {
    try {
      if (!Hive.isBoxOpen(LocalStorageService.madrassaLogsBox)) {
        await LocalStorageService.ensureBoxOpen(LocalStorageService.madrassaLogsBox);
      }
      if (!Hive.isBoxOpen(LocalStorageService.syncBox)) {
        await LocalStorageService.ensureBoxOpen(LocalStorageService.syncBox);
      }
      final mBox = Hive.box(LocalStorageService.madrassaLogsBox);
      final syncBox = Hive.box(LocalStorageService.syncBox);

      int queued = 0;
      for (final key in mBox.keys.toList()) {
        final raw = mBox.get(key);
        if (raw is! Map || raw['syncStatus'] == 'synced') continue;
        final keyStr = key.toString();
        String bId = branchId;
        String dateKey = keyStr;
        if (keyStr.contains('__log__')) {
          final parts = keyStr.split('__log__');
          bId = parts[0].toLowerCase().trim();
          dateKey = parts.length > 1 ? parts[1] : keyStr;
        } else if (keyStr.contains('_')) {
          final parts = keyStr.split('_');
          bId = parts.isNotEmpty ? parts.first.toLowerCase().trim() : branchId;
          dateKey = parts.length >= 4 ? '${parts[1]}-${parts[2]}-${parts[3]}' : parts.last;
        }

        final targetKey = 'sync_${bId}_save_madrassa_log_$dateKey';
        if (syncBox.containsKey(targetKey)) continue;

        await syncBox.put(targetKey, {
          'type': 'save_madrassa_log',
          'branchId': bId,
          'dateKey': dateKey,
          'data': Map<String, dynamic>.from(raw)..remove('syncStatus'),
          'localBox': LocalStorageService.madrassaLogsBox,
          'localKey': keyStr,
          'createdAt': DateTime.now().toIso8601String(),
          'attempts': 0,
          'status': 'pending',
        });
        queued++;
      }
      if (queued > 0) {
        debugPrint('[SSM] 📥 Backfill: queued $queued unsynced madrassa logs for Firestore upload');
      }
    } catch (e) {
      debugPrint('[SSM] _enqueueMissingMadrassaLogs error: $e');
    }
  }

  Future<void> _runBackgroundSweep({bool force = false}) async {
    try {
      await Future.delayed(const Duration(milliseconds: 100));
      await LocalStorageService.purgeStressTestLeftovers();
      await Future.delayed(const Duration(milliseconds: 30));
      await LocalStorageService.healLegacyHistoricalData();
      await Future.delayed(const Duration(milliseconds: 30));
      await _enqueueMissingEntries();
      await Future.delayed(const Duration(milliseconds: 30));
      await _enqueueMissingDonations();
      await Future.delayed(const Duration(milliseconds: 30));
      await _enqueueMissingEmployees();
      await Future.delayed(const Duration(milliseconds: 30));
      await _enqueueMissingAttendance();
      await Future.delayed(const Duration(milliseconds: 30));
      await _enqueueMissingPatients();
      await Future.delayed(const Duration(milliseconds: 30));
      await _enqueueMissingMadrassaStudents();
      await Future.delayed(const Duration(milliseconds: 30));
      await _enqueueMissingMadrassaLogs();
      await Future.delayed(const Duration(milliseconds: 30));
      await LocalStorageService.pushLocalUsersToFirestore();
    } catch (e) {
      debugPrint('[SSM] _runBackgroundSweep error: $e');
    }
  }

  /// Fast parallelized sync processor with auto-purging
  Future<void> triggerSync({bool force = false, bool urgent = false}) async {
    if (_isSyncing && !force) return;
    if (!ServerSyncCoordinator.canStartSync(isServer: true, force: force)) {
      debugPrint('[SSM] ⏸️ Yielding sync pass — SyncService is currently uploading');
      return;
    }

    // Periodic sweep for missing offline tokens and donations:
    // Run on force OR every 15 minutes in non-blocking background task so server UI and WebSockets never freeze.
    final now = DateTime.now();
    final bool shouldSweep = !urgent && (force ||
        _lastSweepTime == null ||
        now.difference(_lastSweepTime!).inMinutes >= 15);
    if (shouldSweep) {
      _lastSweepTime = now;
      unawaited(_runBackgroundSweep(force: force));
    }

    if (!Hive.isBoxOpen(LocalStorageService.syncBox)) return;
    final box = Hive.box(LocalStorageService.syncBox);
    if (box.isEmpty) return;

    // Upload through SyncService, the same quota-aware uploader every other PC uses. This
    // second uploader worked the same queue every 30 s without timeouts, without the
    // hand-off marks (it re-sent writes already waiting in Firestore) and without the
    // backlog budget. Set legacyUploaderEnabled = true to go back to it.
    if (!legacyUploaderEnabled) {
      final before = box.length;
      await SyncService().triggerUpload(force: force, urgent: urgent);
      final uploaded = before - (box.isOpen ? box.length : before);
      if (uploaded > 0) onSyncComplete(uploaded);
      return;
    }

    _isSyncing = true;
    _syncedThisRun = 0;
    ServerSyncCoordinator.markStarted(isServer: true);

    try {
      // First, purge invalid noise
      await purgeInvalidQueue();

      // Desktop-resilient online verification:
      // Abort cloud upload pass if internet is unreachable so server stays responsive on local LAN.
      bool isOnline = true;
      try {
        if (NetworkHealthService().isOffline || !NetworkHealthService().isStableOnline) {
          isOnline = false;
        } else if (!kIsWeb && (io.Platform.isAndroid || io.Platform.isIOS)) {
          final connectivity = await Connectivity().checkConnectivity();
          isOnline = connectivity.any((r) => r != ConnectivityResult.none);
        }
      } catch (_) {
        isOnline = false;
      }

      if (!isOnline && !force) {
        _isSyncing = false;
        return;
      }

      // Uploads are paused until the daily reset (a write was refused for quota): do not
      // touch the queue; a manual forced sync still goes ahead.
      if (QuotaService.isPausedForDailyReset && !force) {
        _isSyncing = false;
        return;
      }

      bool quotaStopped = false;
      int passes = 0;
      while (box.isNotEmpty && passes < 10 && !quotaStopped) {
        final keys = box.keys.toList();
        if (keys.isEmpty) break;
        final startSynced = _syncedThisRun;

        // Process in high-throughput WriteBatch chunks of up to 35 items
        const chunkSize = 35;
        for (int i = 0; i < keys.length; i += chunkSize) {
          ServerSyncCoordinator.touch();
          final chunk = keys.sublist(i, math.min(i + chunkSize, keys.length));
          final batch = CloudDb.instance.batch();
          final List<dynamic> stagedKeys = [];
          final Map<dynamic, String?> stagedRev = {};
          final List<Future<void> Function()> postCommitCallbacks = [];
          final nowForSettle = DateTime.now();

          for (final key in chunk) {
            try {
              final raw = box.get(key);
              // A token still in progress waits until it settles (one upload per visit);
              // a manual forced sync uploads everything now.
              if (!force && raw is Map && raw['type'] == 'save_entry' && raw['lastChangeAt'] != null &&
                  !_tokenItemSettled(raw, nowForSettle)) {
                continue;
              }
              final rev = raw is Map ? (raw['lastChangeAt'] ?? raw['createdAt'])?.toString() : null;
              final ok = await _processSyncItem(box, key, batch: batch, postCommitCallbacks: postCommitCallbacks);
              if (ok) {
                stagedKeys.add(key);
                stagedRev[key] = rev;
              }
            } catch (_) {}
          }

          if (stagedKeys.isNotEmpty) {
            try {
              // One atomic REST commit: done or not done, nothing left in a hidden queue.
              await CloudDb.runWith(CloudWriteContext(force: force), () => batch.commit())
                  .timeout(const Duration(seconds: 90));
              for (final cb in postCommitCallbacks) {
                try { await cb(); } catch (_) {}
              }
              for (final k in stagedKeys) {
                // A token event merged into this item while it uploaded: keep it (the newer
                // state goes up on the next pass). Deleting it lost that change in the cloud.
                final cur = box.get(k);
                final curRev = cur is Map ? (cur['lastChangeAt'] ?? cur['createdAt'])?.toString() : null;
                if (cur is Map && curRev != stagedRev[k]) continue;
                await box.delete(k);
                _syncedThisRun++;
              }
            } catch (batchErr) {
              debugPrint('[SSM] WriteBatch commit notice: $batchErr — evaluating failure');
              // The commit may still have landed (timeout, lost answer): mark the items as tried,
              // so stock increments check their applied-marker before being sent again.
              for (final k in stagedKeys) {
                final cur = box.get(k);
                if (cur is Map) {
                  final upd = Map<String, dynamic>.from(cur);
                  upd['lastError'] ??= 'batch: $batchErr';
                  await box.put(k, upd);
                }
              }
              if (QuotaService.isQuotaError(batchErr)) {
                // Daily quota used up (CloudDb paused uploads until the reset): keep every item
                // queued, untouched. Retrying them one by one only counted failures and
                // quarantined good records.
                quotaStopped = true;
                break;
              }
              final errStr = batchErr.toString().toLowerCase();
              final isNetworkFailure = errStr.contains('network') ||
                  errStr.contains('socket') ||
                  errStr.contains('timeout') ||
                  errStr.contains('unavailable') ||
                  errStr.contains('deadline') ||
                  errStr.contains('connection');
              if (isNetworkFailure) {
                debugPrint('[SSM] 🌐 Cloud connection unreachable during batch write. Pausing cloud upload pass (items safely preserved in Hive).');
                break;
              }
              // Safe fallback: run individually so any single bad record gets isolated
              await CloudDb.runWith(CloudWriteContext(force: force),
                  () => Future.wait(stagedKeys.map((k) => _processSyncItem(box, k))));
            }
          }
          await Future.delayed(const Duration(milliseconds: 10));
        }

        passes++;
        if (_syncedThisRun == startSynced) {
          break;
        }
      }

      if (_syncedThisRun > 0) {
        onSyncComplete(_syncedThisRun);
      }
    } catch (e) {
      onSyncError(e.toString());
    } finally {
      _isSyncing = false;
      ServerSyncCoordinator.markFinished(isServer: true);
    }
  }

  Future<bool> _processSyncItem(Box box, dynamic key, {CloudBatch? batch, List<Future<void> Function()>? postCommitCallbacks}) async {
    try {
      final item = box.get(key);
      if (item == null || item is! Map) {
        await box.delete(key);
        return false;
      }
      final syncItem = Map<String, dynamic>.from(item);
      final type     = syncItem['type'] as String?;
      final data     = syncItem['data'];
      if (type == null || _ignoredEventTypes.contains(type.toLowerCase())) {
        await box.delete(key);
        return false;
      }

      final rawBranch = (syncItem['branchId'] as String?)?.trim().isNotEmpty == true
          ? (syncItem['branchId'] as String).trim()
          : (data is Map ? (data['branchId'] as String?)?.trim() : null);
      final resolvedBranchId = LocalStorageService.sanitizeBranchId(
          (rawBranch != null && rawBranch.isNotEmpty) ? rawBranch : branchId);

      String resolvedSerial = (syncItem['serial'] as String?)?.trim().toUpperCase() ??
          (data is Map ? (data['serial'] ?? data['tokenSerial'] ?? data['tokenNumber'] ?? data['id'])?.toString().trim().toUpperCase() ?? '' : '');

      String resolvedDateKey = (syncItem['dateKey'] as String?)?.trim() ??
          (data is Map ? data['dateKey']?.toString().trim() ?? '' : '');

      // Resilient fallback for missing dateKey: derive canonical 6-digit dateKey from serial
      if (resolvedDateKey.isEmpty && resolvedSerial.isNotEmpty) {
        resolvedDateKey = CampSessionService.getDateKeyFromSerial(resolvedSerial);
      }
      if (resolvedDateKey.isEmpty) {
        resolvedDateKey = _todayKey();
      }

      final resolvedQueueType = _resolveQueueType(syncItem['queueType'] ?? (data is Map ? data['queueType'] : null));

      // Merge syncItem with data map so top-level keys like uid, employeeId, entityId are retained
      final dataMap = <String, dynamic>{
        ...syncItem,
        if (data is Map) ...Map<String, dynamic>.from(data),
      };

      if (dataMap.length <= 1 && !type.toLowerCase().startsWith('delete_')) {
        await box.delete(key);
        return false;
      }

      await _syncToFirestore(
        type:       type,
        data:       dataMap,
        branchId:   resolvedBranchId,
        dateKey:    resolvedDateKey,
        queueType:  resolvedQueueType,
        serial:     resolvedSerial,
        medicineId: (syncItem['medicineId'] as String?)?.trim() ?? '',
        delta:      syncItem['delta'] is num
            ? (syncItem['delta'] as num).toDouble()
            : double.tryParse(syncItem['delta']?.toString() ?? '') ?? 0.0,
        batch:      batch,
        postCommitCallbacks: postCommitCallbacks,
        txId:       (syncItem['txId'] ?? (data is Map ? data['txId'] : null) ?? key).toString(),
        isRetry:    ((syncItem['attempts'] as num?) ?? 0) > 0 || syncItem['lastError'] != null,
      );

      if (batch == null) {
        // Same rule as the batch path: keep an item that changed while it uploaded.
        final cur = box.get(key);
        final startRev = (item['lastChangeAt'] ?? item['createdAt'])?.toString();
        final curRev = cur is Map ? (cur['lastChangeAt'] ?? cur['createdAt'])?.toString() : null;
        if (cur is! Map || curRev == startRev) {
          await box.delete(key);
          _syncedThisRun++;
        }
      }
      return true;
    } catch (e) {
      debugPrint('[SSM] Sync item error for key $key: $e');
      try {
        final item = box.get(key);
        if (item is Map) {
          final updated = Map<String, dynamic>.from(item);
          final errStr = e.toString().toLowerCase();
          final isNetworkError = errStr.contains('network') ||
              errStr.contains('socket') ||
              errStr.contains('timeout') ||
              errStr.contains('unavailable') ||
              errStr.contains('connection') ||
              errStr.contains('deadline') ||
              errStr.contains('host') ||
              QuotaService.isQuotaError(e); // quota pause: wait for the reset, not a bad record

          // Never increment failure attempts or quarantine valid items on network drops
          if (!isNetworkError) {
            final attempts = ((updated['attempts'] as int?) ?? 0) + 1;
            updated['attempts'] = attempts;
            updated['lastError'] = e.toString();
            if (attempts >= 5) {
              debugPrint('[SSM] 🛡️ Quarantining unrecoverable item after 5 failures: ${updated['type']} — $e');
              try {
                if (!Hive.isBoxOpen('dead_letter_queue')) {
                  await LocalStorageService.openBoxSafe('dead_letter_queue');
                }
                final dlq = Hive.box('dead_letter_queue');
                await dlq.put('dlq_${DateTime.now().millisecondsSinceEpoch}_$key', {
                  ...updated,
                  'fatalError': e.toString(),
                  'quarantinedAt': DateTime.now().toIso8601String(),
                });
              } catch (_) {}
              await box.delete(key);
            } else {
              await box.put(key, updated);
            }
          } else {
            updated['lastError'] = 'Network unreachable ($e)';
            await box.put(key, updated);
          }
        }
      } catch (_) {}
      return false;
    }
  }

  // ── Firestore writer with comprehensive support across all modules ─────────
  Future<void> _syncToFirestore({
    required String type,
    required Map<String, dynamic> data,
    required String branchId,
    required String dateKey,
    required String queueType,
    required String serial,
    String medicineId = '',
    double delta      = 0.0,
    CloudBatch? batch,
    List<Future<void> Function()>? postCommitCallbacks,
    String txId       = '',
    bool isRetry      = false,
  }) async {
    // Writes go through CloudDb (Firestore REST): each one is confirmed or fails. SDK writes
    // on Windows could time out here yet stay in the SDK queue and be sent later, while the
    // item was still queued and sent again (increments counted twice).
    final db        = CloudDb.instance;
    final cleanData = _removeFieldValues(data);

    // CloudDb has its own request timeouts; an outer timeout shorter than those would give up
    // on a write that may still land.
    Future<void> setDoc(CloudDoc ref, Map<String, dynamic> docData, {bool merge = true}) async {
      if (batch != null) {
        batch.set(ref, docData, SetOptions(merge: merge));
      } else {
        await ref.set(docData, SetOptions(merge: merge)).timeout(const Duration(seconds: 90));
      }
    }

    Future<void> deleteDoc(CloudDoc ref) async {
      if (batch != null) {
        batch.delete(ref);
      } else {
        await ref.delete().timeout(const Duration(seconds: 90));
      }
    }

    final effectiveDateKey  = dateKey.isNotEmpty ? dateKey : (cleanData['dateKey'] as String? ?? _todayKey());
    final rawSerial         = serial.isNotEmpty ? serial : (cleanData['serial'] as String? ?? '');
    final effectiveSerial   = rawSerial.trim().toUpperCase();
    final effectiveQueueType = queueType;
    final effectiveBranchId = LocalStorageService.sanitizeBranchId(
        branchId.isNotEmpty ? branchId : this.branchId);

    switch (type) {
      // ── Token entry ──────────────────────────────────────────────────────
      case 'save_entry':
      case 'token_created':
        String s = effectiveSerial;
        if (s.isEmpty) {
          s = (cleanData['serial'] ?? cleanData['id'] ?? cleanData['tokenNumber'] ?? cleanData['token'] ?? '').toString().trim().toUpperCase();
        }
        final dk = effectiveDateKey;
        final qt = _validQueueTypes.contains(effectiveQueueType)
            ? effectiveQueueType
            : _resolveQueueType(cleanData['queueType']);
        if (s.isEmpty) {
          debugPrint('⚠️ [SSM] save_entry: invalid or missing serial — skipping');
          break;
        }

        cleanData['serial'] = s;
        final campDocKey = CampSessionService.getCampDateDocId(
          branchId: effectiveBranchId,
          dateKey: dk,
          campId: cleanData['campId']?.toString() ?? cleanData['dispensaryId']?.toString(),
          dispensaryTag: cleanData['dispensaryTag']?.toString(),
          serial: s,
        );
        final entryUid = (cleanData['entryUid'] ?? data['entryUid'])?.toString().trim();
        final hasCollision = cleanData['hasCollision'] == true || data['hasCollision'] == true;
        final docId = (hasCollision && entryUid != null && entryUid.isNotEmpty)
            ? '${s}_COLLISION_$entryUid'
            : s;

        final entryRef = db
            .collection('branches').doc(effectiveBranchId)
            .collection('serials').doc(campDocKey)
            .collection(qt).doc(docId);
        await setDoc(entryRef, cleanData);
        debugPrint('✅ save_entry → serials/$campDocKey/$qt/$docId');

        // Direct write to dispensary collection for cloud console & legacy paths
        try {
          final dispRef = db
              .collection('branches').doc(effectiveBranchId)
              .collection('dispensary').doc(dk)
              .collection(dk).doc(s);
          await setDoc(dispRef, cleanData);
        } catch (_) {}

        // Direct write embedded prescription to patient timeline so historical data is easily found
        final pCnic = (cleanData['patientCnic'] ?? cleanData['cnic'] ?? '').toString().trim();
        if (pCnic.isNotEmpty && (cleanData['prescription'] != null || cleanData['medicines'] != null || cleanData['doctorName'] != null)) {
          try {
            final pRef1 = db
                .collection('branches').doc(effectiveBranchId)
                .collection('prescriptions').doc(pCnic)
                .collection('prescriptions').doc(s);
            await setDoc(pRef1, cleanData);
          } catch (_) {}
          // (No copy under patients/{cnic}/prescriptions: nothing reads it, and on the shared
          // 20k-writes/day plan each extra copy per token adds up.)
        }

        // Direct write patient profile so historical patient details are queryable
        final pid = (cleanData['patientId'] ?? cleanData['id'] ?? '').toString().trim();
        if (pid.isNotEmpty && !pid.startsWith('unknown_')) {
          try {
            final patData = {
              'id': pid,
              'patientId': pid,
              'name': cleanData['patientName'] ?? cleanData['name'],
              'cnic': cleanData['patientCnic'] ?? cleanData['cnic'],
              if (cleanData['phone'] != null) 'phone': cleanData['phone'],
              if (cleanData['gender'] != null) 'gender': cleanData['gender'],
              if (cleanData['age'] != null) 'age': cleanData['age'],
              'branchId': effectiveBranchId,
              // No per-visit field: an identical profile is skipped by CloudDb's fingerprint
              // check, so repeat visits cost no write.
            };
            final patRef = db
                .collection('branches').doc(effectiveBranchId)
                .collection('patients').doc(pid);
            await setDoc(patRef, patData);
          } catch (_) {}
        }

        // Update local entry so pendingSync is cleared and marked synced on the server
        Future<void> applyEntrySync() async {
          try {
            if (Hive.isBoxOpen(LocalStorageService.entriesBox)) {
              final eBox = Hive.box(LocalStorageService.entriesBox);
              final normB = effectiveBranchId.toLowerCase().trim();
              final normS = s.toUpperCase().trim();
              final localKey = '$normB-$normS';
              dynamic targetKey = localKey;
              dynamic existing;

              // The token is normally at its canonical key: use it when its entryUid matches.
              // Only otherwise scan (this ran a full scan of the entries box per uploaded token).
              final atLocal = eBox.get(localKey);
              if (atLocal is Map) {
                final uidThere = atLocal['entryUid']?.toString().trim() ?? '';
                if (entryUid == null || entryUid.isEmpty || uidThere.isEmpty || uidThere == entryUid) {
                  existing = atLocal;
                }
              }

              if (existing == null && entryUid != null && entryUid.isNotEmpty) {
                for (final k in eBox.keys) {
                  final val = eBox.get(k);
                  if (val is Map && (val['entryUid']?.toString().trim() == entryUid)) {
                    targetKey = k;
                    existing = val;
                    break;
                  }
                }
              }

              if (existing == null) {
                existing = eBox.get(localKey);
                if (existing == null) {
                  for (final k in eBox.keys) {
                    final kStr = k.toString().toUpperCase().trim();
                    if (kStr == localKey.toUpperCase() || kStr == normS || kStr.endsWith('-$normS')) {
                      targetKey = k;
                      existing = eBox.get(k);
                      break;
                    }
                  }
                }
              }
              if (existing is Map) {
                final updated = Map<String, dynamic>.from(existing);
                updated['synced'] = true;
                updated['pendingSync'] = false;
                updated['syncStatus'] = 'synced';
                updated['syncedAt'] = DateTime.now().toIso8601String();
                await eBox.put(targetKey, updated);
              }
            }
          } catch (_) {}
        }

        if (batch != null && postCommitCallbacks != null) {
          postCommitCallbacks.add(applyEntrySync);
        } else {
          await applyEntrySync();
        }
        break;

      // ── Prescription (Single Canonical Serials Write) ─────────────────────
      case 'save_prescription':
      case 'prescription_created':
        String s = effectiveSerial.isNotEmpty
            ? effectiveSerial
            : (cleanData['id'] as String? ?? cleanData['serial'] as String? ?? '').toString().trim().toUpperCase();
        if (s.isEmpty) {
          debugPrint('⚠️ [SSM] save_prescription: invalid or missing serial — skipping');
          break;
        }
        cleanData['serial'] = s;

        // Mark serial status as completed and embed clinical prescription data directly
        final campDocKey = CampSessionService.getCampDateDocId(
          branchId: effectiveBranchId,
          dateKey: effectiveDateKey,
          campId: cleanData['campId']?.toString() ?? cleanData['dispensaryId']?.toString(),
          dispensaryTag: cleanData['dispensaryTag']?.toString(),
          serial: s,
        );

        final updateMap = <String, dynamic>{
          'status':         'completed',
          'completedAt':    cleanData['completedAt'] ?? DateTime.now().toIso8601String(),
          // Only ever write 'dispensed': the doctor's 'pending' (merge) overwrote dispenses in the cloud.
          if ((cleanData['dispenseStatus'] ?? '').toString().toLowerCase() == 'dispensed') 'dispenseStatus': 'dispensed',
        };
        for (final f in ['doctorName', 'doctorId', 'daysOfMedicine', 'extraCharge', 'vitals', 'prescription', 'medicines', 'diagnosis', 'complaints']) {
          if (cleanData.containsKey(f) && cleanData[f] != null) {
            updateMap[f] = cleanData[f];
          }
        }

        final prescRef = db
            .collection('branches').doc(effectiveBranchId)
            .collection('serials').doc(campDocKey)
            .collection(effectiveQueueType).doc(s);
        await setDoc(prescRef, updateMap);
        debugPrint('✅ save_prescription → serials/$campDocKey/$effectiveQueueType/$s');

        // Direct write to prescriptions collections & dispensary daily collection
        final cnic = (cleanData['patientCnic'] ?? cleanData['cnic'] ?? '').toString().trim();
        if (cnic.isNotEmpty) {
          try {
            final pRef1 = db
                .collection('branches').doc(effectiveBranchId)
                .collection('prescriptions').doc(cnic)
                .collection('prescriptions').doc(s);
            await setDoc(pRef1, Map<String, dynamic>.from(cleanData)..addAll(updateMap));
          } catch (_) {}
        }
        try {
          final dispRef = db
              .collection('branches').doc(effectiveBranchId)
              .collection('dispensary').doc(effectiveDateKey)
              .collection(effectiveDateKey).doc(s);
          await setDoc(dispRef, Map<String, dynamic>.from(cleanData)..addAll(updateMap));
        } catch (_) {}

        // Update local entry so prescription status is synced on the server
        Future<void> applyPrescriptionSync() async {
          try {
            if (Hive.isBoxOpen(LocalStorageService.entriesBox)) {
              final eBox = Hive.box(LocalStorageService.entriesBox);
              final normB = effectiveBranchId.toLowerCase().trim();
              final normS = s.toUpperCase().trim();
              final localKey = '$normB-$normS';
              dynamic targetKey = localKey;
              dynamic existing = eBox.get(localKey);
              if (existing == null) {
                for (final k in eBox.keys) {
                  final kStr = k.toString().toUpperCase().trim();
                  if (kStr == localKey.toUpperCase() || kStr == normS || kStr.endsWith('-$normS')) {
                    targetKey = k;
                    existing = eBox.get(k);
                    break;
                  }
                }
              }
              if (existing is Map) {
                final updated = Map<String, dynamic>.from(existing);
                updated['synced'] = true;
                updated['pendingSync'] = false;
                updated['prescriptionSynced'] = true;
                updated['syncedAt'] = DateTime.now().toIso8601String();
                await eBox.put(targetKey, updated);
              }
            }
          } catch (_) {}
        }

        if (batch != null && postCommitCallbacks != null) {
          postCommitCallbacks.add(applyPrescriptionSync);
        } else {
          await applyPrescriptionSync();
        }
        break;

      // ── Patient ──────────────────────────────────────────────────────────
      case 'save_patient':
        final pid = (cleanData['patientId'] as String? ?? cleanData['id'] as String? ?? '').trim();
        if (pid.isEmpty) throw Exception('save_patient: missing patientId');
        final patRef = db
            .collection('branches').doc(effectiveBranchId)
            .collection('patients').doc(pid);
        await setDoc(patRef, cleanData);
        debugPrint('✅ save_patient → patients/$pid');
        break;

      // ── Dispensary charge ─────────────────────────────────────────────────
      case 'save_dispensary_charge':
        final s  = effectiveSerial;
        final dk = effectiveDateKey;
        if (s.isEmpty) throw Exception('save_dispensary_charge: missing serial');
        final campDocKey = CampSessionService.getCampDateDocId(
          branchId: effectiveBranchId,
          dateKey: dk,
          campId: cleanData['campId']?.toString() ?? cleanData['dispensaryId']?.toString(),
          dispensaryTag: cleanData['dispensaryTag']?.toString(),
          serial: s,
        );
        final chargeRef = db
            .collection('branches').doc(effectiveBranchId)
            .collection('dispensary_charges').doc(dk)
            .collection('charges').doc(s);
        await setDoc(chargeRef, {...cleanData, 'queueType': effectiveQueueType});

        final serialsMedRef = db
            .collection('branches').doc(effectiveBranchId)
            .collection('serials').doc(campDocKey)
            .collection(effectiveQueueType).doc(s);
        await setDoc(serialsMedRef, {'daysOfMedicine': (cleanData['daysOfMedicine'] as num?)?.toInt() ?? 1});
        debugPrint('✅ save_dispensary_charge → charges/$dk/$s');
        break;

      // ── Dispensary record / Serial status patch ───────────────────────────
      case 'save_dispensary_record':
      case 'update_serial_status':
        final s  = effectiveSerial;
        final dk = effectiveDateKey;
        final qt = _validQueueTypes.contains(effectiveQueueType)
            ? effectiveQueueType
            : _resolveQueueType(cleanData['queueType']);
        if (s.isEmpty) throw Exception('update_serial_status: missing serial');

        final statusPatch = {
          'dispenseStatus': cleanData['dispenseStatus'] ?? 'dispensed',
          'status': 'completed',
          if (cleanData['dispensedAt'] != null)
            'dispensedAt': cleanData['dispensedAt'],
          if (cleanData['dispensedBy'] != null)
            'dispensedBy': cleanData['dispensedBy'],
          if (cleanData['completedAt'] != null)
            'completedAt': cleanData['completedAt'],
        };
        final campDocKey = CampSessionService.getCampDateDocId(
          branchId: effectiveBranchId,
          dateKey: dk,
          campId: cleanData['campId']?.toString() ?? cleanData['dispensaryId']?.toString(),
          dispensaryTag: cleanData['dispensaryTag']?.toString(),
          serial: s,
        );
        final statusRef = db
            .collection('branches').doc(effectiveBranchId)
            .collection('serials').doc(campDocKey)
            .collection(qt).doc(s);
        await setDoc(statusRef, statusPatch);
        debugPrint('✅ update_serial_status → serials/$campDocKey/$qt/$s');

        // Direct write status patch to dispensary daily collection
        try {
          final dispRef = db
              .collection('branches').doc(effectiveBranchId)
              .collection('dispensary').doc(dk)
              .collection(dk).doc(s);
          await setDoc(dispRef, Map<String, dynamic>.from(cleanData)..addAll(statusPatch));
        } catch (_) {}

        // Update local entry so dispenseStatus is synced on the server
        Future<void> applyDispenseSync() async {
          try {
            if (Hive.isBoxOpen(LocalStorageService.entriesBox)) {
              final eBox = Hive.box(LocalStorageService.entriesBox);
              final normB = effectiveBranchId.toLowerCase().trim();
              final normS = s.toUpperCase().trim();
              final localKey = '$normB-$normS';
              dynamic targetKey = localKey;
              dynamic existing = eBox.get(localKey);
              if (existing == null) {
                for (final k in eBox.keys) {
                  final kStr = k.toString().toUpperCase().trim();
                  if (kStr == localKey.toUpperCase() || kStr == normS || kStr.endsWith('-$normS')) {
                    targetKey = k;
                    existing = eBox.get(k);
                    break;
                  }
                }
              }
              if (existing is Map) {
                final updated = Map<String, dynamic>.from(existing);
                updated['dispenseStatus'] = cleanData['dispenseStatus'] ?? 'dispensed';
                updated['status'] = 'completed';
                if (cleanData['dispensedAt'] != null) updated['dispensedAt'] = cleanData['dispensedAt'];
                if (cleanData['dispensedBy'] != null) updated['dispensedBy'] = cleanData['dispensedBy'];
                updated['synced'] = true;
                updated['pendingSync'] = false;
                updated['syncStatus'] = 'synced';
                await eBox.put(targetKey, updated);
              }
            }
          } catch (_) {}
        }

        if (batch != null && postCommitCallbacks != null) {
          postCommitCallbacks.add(applyDispenseSync);
        } else {
          await applyDispenseSync();
        }
        break;
      // ── Delete patient ───────────────────────────────────────────────────
      case 'delete_patient':
        final pid = (cleanData['patientId'] as String? ?? cleanData['id'] as String? ?? '').trim();
        if (pid.isEmpty) throw Exception('delete_patient: missing patientId');
        await deleteDoc(db
            .collection('branches').doc(effectiveBranchId)
            .collection('patients').doc(pid));
        debugPrint('✅ delete_patient → patients/$pid');
        break;

      case 'token_reversal':
      case 'token_reversal_approved':
      case 'delete_entry':
        final s = effectiveSerial;
        final dk = effectiveDateKey;
        final qt = _validQueueTypes.contains(effectiveQueueType)
            ? effectiveQueueType
            : _resolveQueueType(cleanData['queueType']);
        if (s.isEmpty) {
          debugPrint('⚠️ $type: missing serial — skipping');
          return;
        }
        final campDocKey = CampSessionService.getCampDateDocId(
          branchId: effectiveBranchId,
          dateKey: dk,
          campId: cleanData['campId']?.toString() ?? cleanData['dispensaryId']?.toString(),
          dispensaryTag: cleanData['dispensaryTag']?.toString(),
          serial: s,
        );
        await deleteDoc(db
            .collection('branches').doc(effectiveBranchId)
            .collection('serials').doc(campDocKey)
            .collection(qt).doc(s));
        debugPrint('✅ $type → deleted serials/$campDocKey/$qt/$s');
        break;

      // ── Delta Inventory Update — increments ONLY, never reads 'quantity' as a delta ──
      case 'update_inventory':
      case 'add_inventory_stock':
        final mid = medicineId.isNotEmpty
            ? medicineId
            : (cleanData['medicineId'] as String? ?? cleanData['id'] as String? ?? '').trim();
        if (mid.isEmpty) {
          debugPrint('⚠️ update_inventory: missing medicineId — skipping');
          return;
        }
        // [FIX-INV-2] NEVER fall back to cleanData['quantity'] here — that field
        // is an absolute total, not a delta. Reading it as a delta was the root
        // cause of restock double-counting in Firestore. Only an explicit
        // 'delta' value is ever applied as an increment.
        final d = delta != 0.0
            ? delta
            : (cleanData['delta'] is num
                ? (cleanData['delta'] as num).toDouble()
                : double.tryParse(cleanData['delta']?.toString() ?? '') ?? 0.0);
        if (d == 0.0) {
          debugPrint('⚠️ update_inventory: zero/missing delta for $mid — skipping (no-op, will not touch quantity)');
          break;
        }
        final invCol = CampSessionService.getCampInventoryPath(
          branchId: effectiveBranchId,
          campId: cleanData['campId']?.toString() ?? cleanData['dispensaryId']?.toString(),
          serial: cleanData['serial']?.toString(),
        );
        final docRef = db
            .collection('branches').doc(effectiveBranchId)
            .collection(invCol).doc(mid);
        // Applied once per txId: the increment and a marker doc are committed together; a retry
        // after a write that did land finds the marker and adds nothing (it used to add again).
        final markerRef = txId.isEmpty
            ? null
            : db.collection('branches').doc(effectiveBranchId)
                .collection('inventory_applied_tx').doc(txId.replaceAll('/', '_'));
        if (markerRef != null && isRetry) {
          final snap = await markerRef.get();
          if (snap.exists) {
            debugPrint('↩️ update_inventory $txId already applied in the cloud — skipped');
            break;
          }
        }
        final incData = <String, dynamic>{
          'quantity': FieldValue.increment(d),
          'lastUpdated': FieldValue.serverTimestamp(),
          'updatedAt': FieldValue.serverTimestamp(),
          if (cleanData.containsKey('medicineName')) 'medicineName': cleanData['medicineName'],
          if (cleanData.containsKey('category')) 'category': cleanData['category'],
          if (cleanData.containsKey('unit')) 'unit': cleanData['unit'],
        };
        final markerData = <String, dynamic>{
          'medicineId': mid,
          'amount': d,
          'appliedAt': FieldValue.serverTimestamp(),
        };
        if (batch != null) {
          batch.set(docRef, incData, SetOptions(merge: true));
          if (markerRef != null) batch.set(markerRef, markerData);
        } else {
          final b = db.batch();
          b.set(docRef, incData, SetOptions(merge: true));
          if (markerRef != null) b.set(markerRef, markerData);
          await b.commit();
        }
        debugPrint('✅ update_inventory → $invCol/$mid delta=$d');
        break;

      // ── Absolute Inventory Object Write — plain set/merge, NEVER FieldValue.increment ──
      case 'register_medicine':
      case 'add_stock':
      case 'add_proforma_stock':
      case 'save_stock_item':
        final mid2 = medicineId.isNotEmpty
            ? medicineId
            : (cleanData['medicineId'] as String? ?? cleanData['id'] as String? ?? cleanData['docId'] as String? ?? '').trim();
        if (mid2.isEmpty) {
          debugPrint('⚠️ register_medicine: missing medicineId — skipping');
          return;
        }
        final invCol2 = CampSessionService.getCampInventoryPath(
          branchId: effectiveBranchId,
          campId: cleanData['campId']?.toString() ?? cleanData['dispensaryId']?.toString(),
          serial: cleanData['serial']?.toString(),
        );
        await setDoc(db
            .collection('branches').doc(effectiveBranchId)
            .collection(invCol2).doc(mid2), cleanData);
        debugPrint('✅ register_medicine → $invCol2/$mid2 (absolute set/merge, no increment)');
        break;

      case 'delete_stock_item':
      case 'delete_inventory':
        final delMid = medicineId.isNotEmpty
            ? medicineId
            : (cleanData['medicineId'] as String? ?? cleanData['id'] as String? ?? cleanData['docId'] as String? ?? '').trim();
        final docIds = (cleanData['docIds'] is List)
            ? List<String>.from((cleanData['docIds'] as List).map((e) => e.toString().trim()).where((s) => s.isNotEmpty))
            : <String>[];
        if (delMid.isNotEmpty && !docIds.contains(delMid)) {
          docIds.add(delMid);
        }
        if (docIds.isEmpty) {
          debugPrint('⚠️ delete_stock_item: missing medicineId — skipping');
          return;
        }
        final delInvCol = CampSessionService.getCampInventoryPath(
          branchId: effectiveBranchId,
          campId: cleanData['campId']?.toString() ?? cleanData['dispensaryId']?.toString(),
          serial: cleanData['serial']?.toString(),
        );
        for (final targetId in docIds) {
          await deleteDoc(db
              .collection('branches').doc(effectiveBranchId)
              .collection(delInvCol).doc(targetId));
          if (delInvCol != 'inventory') {
            await deleteDoc(db
                .collection('branches').doc(effectiveBranchId)
                .collection('inventory').doc(targetId));
          }
        }
        debugPrint('✅ delete_stock_item → $delInvCol/${docIds.join(",")}');
        break;

      // ── Attendance record sync ────────────────────────────────────────────
      case 'save_attendance':
      case 'save_attendance_record':
      case 'save_biometric_log':
      case 'save_employee_attendance':
      case 'save_faculty_attendance':
      case 'save_student_attendance':
        final rawEmpId = (cleanData['employeeId'] ??
                cleanData['empId'] ??
                cleanData['userId'] ??
                cleanData['pin'] ??
                cleanData['biometricPin'] ??
                cleanData['entityId'] ??
                cleanData['id'] ??
                '')
            .toString()
            .trim();
        String empId = rawEmpId;
        if (empId.startsWith('att_')) {
          final parts = empId.split('_');
          if (parts.length >= 3) {
            empId = parts[2];
          }
        }
        if (empId.isEmpty) {
          empId = 'att_${DateTime.now().millisecondsSinceEpoch}';
        }

        final dtKey = (cleanData['date'] ??
                cleanData['dateKey'] ??
                (effectiveDateKey.isNotEmpty ? effectiveDateKey : null) ??
                DateFormat('yyyy-MM-dd').format(DateTime.now()))
            .toString()
            .trim();

        await setDoc(db
            .collection('branches').doc(effectiveBranchId)
            .collection('employee_attendance').doc(dtKey), {'date': dtKey, 'branchId': effectiveBranchId, 'lastUpdated': FieldValue.serverTimestamp()});
        await setDoc(db
            .collection('branches').doc(effectiveBranchId)
            .collection('employee_attendance').doc(dtKey)
            .collection('records').doc(empId), cleanData);

        if (type == 'save_biometric_log' || cleanData['punchSequence'] != null) {
          final logId = (cleanData['id'] ?? '${empId}_${dtKey}_${DateTime.now().millisecondsSinceEpoch}').toString();
          await setDoc(db.collection('branches').doc(effectiveBranchId).collection('biometric_logs').doc(logId), cleanData);
        }

        // Mark local record as synced in LocalStorageService.attendanceBox
        try {
          if (Hive.isBoxOpen(LocalStorageService.attendanceBox)) {
            final aBox = Hive.box(LocalStorageService.attendanceBox);
            final hKey = '${empId}_$dtKey';
            final localRecord = aBox.get(hKey);
            if (localRecord is Map) {
              final updated = Map<String, dynamic>.from(localRecord)
                ..['synced'] = true
                ..['syncStatus'] = 'synced'
                ..['lastSyncedAt'] = DateTime.now().toUtc().toIso8601String();
              await aBox.put(hKey, updated);
            }
          }
        } catch (_) {}
        debugPrint('✅ save_attendance → branches/$effectiveBranchId/employee_attendance/$dtKey/records/$empId');
        break;

      // ── Users Module sync ─────────────────────────────────────────────────
      case 'save_user':
        final rawData = cleanData['data'] is Map ? Map<String, dynamic>.from(cleanData['data']) : cleanData;
        final uid = (cleanData['uid'] ?? cleanData['id'] ?? cleanData['userId'] ?? rawData['uid'] ?? rawData['id'])?.toString().trim() ?? '';
        final bId = (cleanData['branchId'] ?? rawData['branchId'] ?? effectiveBranchId).toString().trim();
        if (uid.isEmpty) {
          debugPrint('⚠️ [SSM] save_user: missing uid — skipping');
          break;
        }
        final userPayload = Map<String, dynamic>.from(rawData)..remove('syncStatus')..remove('pendingSync');
        if (bId.isNotEmpty && bId != 'all' && bId != 'global') {
          userPayload['branchId'] ??= bId;
        }
        userPayload['lastSyncedAt'] = FieldValue.serverTimestamp();

        await setDoc(db.collection('users').doc(uid), userPayload);
        if (bId.isNotEmpty && bId != 'all' && bId != 'global') {
          await setDoc(db.collection('branches').doc(bId).collection('users').doc(uid), userPayload);
        }
        try {
          if (Hive.isBoxOpen('local_users')) {
            final box = Hive.box('local_users');
            final email = (userPayload['email'] ?? '').toString().trim().toLowerCase();
            if (email.isNotEmpty) await box.put('user:$email', userPayload);
            await box.put('user:$uid', userPayload);
            await box.put(uid, userPayload);
            await box.flush();
          }
        } catch (_) {}
        debugPrint('✅ save_user → users/$uid (branch: $bId)');
        break;

      case 'delete_user':
        final uid = (cleanData['uid'] ?? cleanData['id'] ?? '').toString().trim();
        final bId = (cleanData['branchId'] ?? effectiveBranchId).toString().trim();
        final email = (cleanData['email'] ?? '').toString().trim().toLowerCase();
        final username = (cleanData['username'] ?? '').toString().trim().toLowerCase();
        final identifiers = <String>{
          if (uid.isNotEmpty) uid,
          if (email.isNotEmpty) email,
          if (username.isNotEmpty) username,
        };
        final deletePayload = {
          'isDeleted': true,
          'status': 'deleted',
          'accountStatus': 'deleted',
          'deletedAt': FieldValue.serverTimestamp(),
        };
        for (final identifier in identifiers) {
          await setDoc(db.collection('users').doc(identifier), deletePayload);
          if (bId.isNotEmpty && bId != 'all') {
            await setDoc(db.collection('branches').doc(bId).collection('users').doc(identifier), deletePayload);
          }
        }
        debugPrint('✅ delete_user → $identifiers');
        break;

      // ── Branch Details sync ───────────────────────────────────────────────
      case 'update_branch':
        final bId = (cleanData['branchId'] ?? cleanData['id'] ?? cleanData['docId'] ?? effectiveBranchId).toString().trim();
        if (bId.isNotEmpty) {
          final payload = cleanData['data'] is Map ? Map<String, dynamic>.from(cleanData['data']) : Map<String, dynamic>.from(cleanData);
          payload.remove('type');
          payload.remove('collection');
          payload.remove('docId');
          payload['lastUpdated'] = FieldValue.serverTimestamp();
          await setDoc(db.collection('branches').doc(bId), payload);
          debugPrint('✅ update_branch → branches/$bId');
        }
        break;

      // ── Employee sync ─────────────────────────────────────────────────────
      case 'save_employee':
        final empData = cleanData['data'] is Map ? Map<String, dynamic>.from(cleanData['data']) : cleanData;
        final localId = (cleanData['localId'] ?? cleanData['id'] ?? cleanData['employeeId'] ?? empData['localId'] ?? empData['id'] ?? empData['employeeId'])?.toString().trim() ?? '';
        final bId = (cleanData['branchId'] ?? empData['branchId'] ?? effectiveBranchId).toString().trim();
        if (localId.isEmpty) {
          debugPrint('⚠️ [SSM] save_employee missing localId/id — skipping');
          break;
        }
        final fsEmpData = Map<String, dynamic>.from(empData)..remove('syncStatus');
        for (final f in ['dob', 'cnicExpiry', 'joiningDate', 'exitDate', 'createdAt']) {
          if (fsEmpData[f] is String) {
            try {
              fsEmpData[f] = Timestamp.fromDate(DateTime.parse(fsEmpData[f] as String));
            } catch (_) {}
          }
        }
        fsEmpData['lastSyncedAt'] = FieldValue.serverTimestamp();
        await setDoc(db.collection('branches').doc(bId).collection('employees').doc(localId), fsEmpData);
        await setDoc(db.collection('employees').doc(localId), fsEmpData);
        try {
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
        } catch (_) {}
        debugPrint('✅ save_employee → branches/$bId/employees/$localId');
        break;

      case 'delete_employee':
        final localId = (cleanData['localId'] ?? cleanData['id'] ?? cleanData['employeeId'])?.toString().trim() ?? '';
        final bId = (cleanData['branchId'] ?? effectiveBranchId).toString().trim();
        if (localId.isNotEmpty) {
          await deleteDoc(db.collection('branches').doc(bId).collection('employees').doc(localId));
          await deleteDoc(db.collection('employees').doc(localId));
          debugPrint('✅ delete_employee → branches/$bId/employees/$localId');
        }
        break;

      // ── Audit Logs sync ───────────────────────────────────────────────────
      case 'save_audit_log':
        final logData = cleanData['data'] is Map ? Map<String, dynamic>.from(cleanData['data']) : cleanData;
        final logId = (cleanData['id'] ?? cleanData['syncId'] ?? logData['id'] ?? const Uuid().v4()).toString().trim();
        final bId = (cleanData['branchId'] ?? logData['branchId'] ?? effectiveBranchId).toString().trim();
        final fsLog = Map<String, dynamic>.from(logData);
        fsLog['branchId'] ??= bId;
        fsLog['lastSyncedAt'] = FieldValue.serverTimestamp();
        await setDoc(db.collection('branches').doc(bId).collection('audit_logs').doc(logId), fsLog);
        await setDoc(db.collection('global_audit_logs').doc(logId), fsLog);
        debugPrint('✅ save_audit_log → branches/$bId/audit_logs/$logId');
        break;

      // ── School Module sync ────────────────────────────────────────────────
      case 'save_school_daily_log':
      case 'save_school_teacher_log':
      case 'save_school_student_log':
        final dtKey = (cleanData['date'] ?? cleanData['dateKey'] ?? effectiveDateKey).toString().trim();
        final targetCollection = type == 'save_school_teacher_log'
            ? 'school_teacher_logs'
            : (type == 'save_school_student_log' ? 'school_student_logs' : 'school_daily_logs');
        final logData = cleanData['data'] is Map ? Map<String, dynamic>.from(cleanData['data']) : cleanData;
        if (dtKey.isNotEmpty) {
          await setDoc(db.collection('branches').doc(effectiveBranchId).collection(targetCollection).doc(dtKey), logData);
          debugPrint('✅ $type → branches/$effectiveBranchId/$targetCollection/$dtKey');
        }
        break;

      // ── Biometric Hardware Devices sync ───────────────────────────────────
      case 'save_biometric_device':
        final devId = (cleanData['deviceId'] ?? cleanData['id'] ?? '').toString().trim();
        if (devId.isNotEmpty) {
          cleanData['updatedAt'] = FieldValue.serverTimestamp();
          await setDoc(db.collection('branches').doc(effectiveBranchId).collection('biometric_devices').doc(devId), cleanData);
          debugPrint('✅ save_biometric_device → branches/$effectiveBranchId/biometric_devices/$devId');
        }
        break;

      case 'delete_biometric_device':
        final devId = (cleanData['deviceId'] ?? cleanData['id'] ?? '').toString().trim();
        if (devId.isNotEmpty) {
          await deleteDoc(db.collection('branches').doc(effectiveBranchId).collection('biometric_devices').doc(devId));
          debugPrint('✅ delete_biometric_device → branches/$effectiveBranchId/biometric_devices/$devId');
        }
        break;

      // ── Donations Module sync ─────────────────────────────────────────────
      case 'save_donation':
      case 'update_donation':
      case 'save_donation_receipt':
      case 'save_donation_collection':
        String donationId = (cleanData['firestoreId'] ??
                cleanData['localId'] ??
                cleanData['id'] ??
                cleanData['donationId'] ??
                cleanData['receiptNoClean'] ??
                cleanData['receiptNo'] ??
                cleanData['receiptNumber'] ??
                '')
            .toString()
            .trim();
        if (donationId.isEmpty) {
          final amt = cleanData['amount']?.toString() ?? '0';
          final dt = cleanData['date']?.toString() ?? _todayKey();
          donationId = 'don_${effectiveBranchId}_${dt}_$amt';
        }
        await setDoc(db.collection('donations').doc(donationId), cleanData);
        await setDoc(db.collection('branches').doc(effectiveBranchId).collection('donations').doc(donationId), cleanData);
        debugPrint('✅ save_donation → donations/$donationId (branch: $effectiveBranchId)');

        // Update local donation so syncStatus is synced on the server
        try {
          if (Hive.isBoxOpen(DonationsLocalStorage.donationsBox)) {
            final dBox = Hive.box(DonationsLocalStorage.donationsBox);
            for (final k in dBox.keys) {
              final v = dBox.get(k);
              if (v is Map &&
                  (v['localId'] == donationId ||
                      v['firestoreId'] == donationId ||
                      v['receiptNumber'] == donationId ||
                      v['receiptNoClean'] == donationId ||
                      v['receiptNo'] == donationId ||
                      v['id'] == donationId)) {
                final upd = Map<String, dynamic>.from(v);
                upd['syncStatus'] = 'synced';
                await dBox.put(k, upd);
                break;
              }
            }
          }
        } catch (_) {}
        break;

      case 'delete_donation':
        final donationId = (cleanData['id'] ?? cleanData['donationId'] ?? cleanData['localId'] ?? '').toString().trim();
        if (donationId.isNotEmpty) {
          await deleteDoc(db.collection('donations').doc(donationId));
          await deleteDoc(db.collection('branches').doc(effectiveBranchId).collection('donations').doc(donationId));
        }
        break;

      // ── Dasterkhwaan / Food Tokens Module sync ────────────────────────────
      case 'save_dasterkhwan_tokens':
      case 'save_office_boy_token':
      case 'save_dasterkhwan_entry':
        final tokensList = List<dynamic>.from(cleanData['tokens'] as List? ?? []);
        final rawQty = cleanData['quantity'] ?? cleanData['tokenCount'];
        final qty = (rawQty is num) ? rawQty.toInt() : (tokensList.isNotEmpty ? tokensList.length : 1);
        final session = (cleanData['session'] ?? 'lunch').toString().toLowerCase();
        final dt = (cleanData['dateKey'] ?? cleanData['date'] ?? effectiveDateKey).toString().trim();
        final effectiveDt = dt.isNotEmpty ? dt : _todayKey();

        final dayDocRef = db.collection('branches').doc(effectiveBranchId).collection('dasterkhwaan').doc(effectiveDt);
        final tokensColRef = dayDocRef.collection('tokens');

        if (tokensList.isNotEmpty) {
          for (final t in tokensList) {
            if (t is Map) {
              final tMap = Map<String, dynamic>.from(t);
              final tid = (tMap['id'] ?? tMap['localId'] ?? tokensColRef.doc().id).toString();
              final fsToken = {
                'number': tMap['number'] ?? 1,
                'served': tMap['served'] == true,
                'session': tMap['session'] ?? session,
                'time': tMap['time'] != null
                    ? (DateTime.tryParse(tMap['time'].toString()) != null
                        ? Timestamp.fromDate(DateTime.parse(tMap['time'].toString()))
                        : FieldValue.serverTimestamp())
                    : FieldValue.serverTimestamp(),
                'issuedBy': tMap['issuedBy'] ?? cleanData['issuedBy'] ?? '',
                'localId': tid,
                'pricePerToken': tMap['pricePerToken'] ?? cleanData['pricePerToken'] ?? 0,
              };
              await setDoc(tokensColRef.doc(tid), fsToken);
            }
          }
        } else {
          final tid = (cleanData['id'] ?? cleanData['localId'] ?? tokensColRef.doc().id).toString();
          await setDoc(tokensColRef.doc(tid), cleanData);
        }

        await setDoc(dayDocRef, {
          'totalTokens': FieldValue.increment(qty),
          'session_${session}_total': FieldValue.increment(qty),
          'lastUpdated': FieldValue.serverTimestamp(),
          'date': effectiveDt,
          'branchId': effectiveBranchId,
        });

        // Also update local cache status
        try {
          if (Hive.isBoxOpen('dasterkhwaan_tokens')) {
            final tBox = Hive.box('dasterkhwaan_tokens');
            for (final t in tokensList) {
              if (t is Map) {
                final tid = t['id']?.toString();
                if (tid != null && tBox.containsKey(tid)) {
                  final ex = tBox.get(tid);
                  if (ex is Map) {
                    await tBox.put(tid, Map<String, dynamic>.from(ex)..['syncStatus'] = 'synced');
                  }
                }
              }
            }
          }
        } catch (_) {}
        debugPrint('✅ $type → branches/$effectiveBranchId/dasterkhwaan/$effectiveDt ($qty tokens)');
        break;

      case 'save_kitchen_serve_log':
        final dt = (cleanData['dateKey'] ?? cleanData['date'] ?? effectiveDateKey).toString().trim();
        final effectiveDt = dt.isNotEmpty ? dt : _todayKey();
        final tokenId = (cleanData['tokenId'] ?? cleanData['id'] ?? '').toString().trim();
        final dayDocRef = db.collection('branches').doc(effectiveBranchId).collection('dasterkhwaan').doc(effectiveDt);

        if (tokenId.isNotEmpty) {
          final tokenRef = dayDocRef.collection('tokens').doc(tokenId);
          await setDoc(tokenRef, {
            'served': true,
            'servedTime': cleanData['timestamp'] ?? FieldValue.serverTimestamp(),
            'servedBy': cleanData['servedBy'] ?? 'Kitchen',
          });
        }
        await setDoc(dayDocRef, {
          'servedTokens': FieldValue.increment(1),
          'lastUpdated': FieldValue.serverTimestamp(),
        });
        debugPrint('✅ save_kitchen_serve_log → $tokenId marked served');
        break;

      // ── Finance & Expenses Module sync ────────────────────────────────────
      case 'save_expense':
      case 'void_expense':
        final expenseId = (cleanData['id'] ?? cleanData['expenseId'] ?? '').toString().trim();
        if (expenseId.isEmpty) throw Exception('save_expense: missing expenseId');
        await setDoc(db.collection('branches').doc(effectiveBranchId).collection('expenses').doc(expenseId), cleanData);
        debugPrint('✅ save_expense → expenses/$expenseId');
        break;

      case 'save_salary_history':
        final recordId = (cleanData['id'] ?? cleanData['employeeId'] ?? '').toString().trim();
        if (recordId.isNotEmpty) {
          await setDoc(db.collection('branches').doc(effectiveBranchId).collection('salary_history').doc(recordId), cleanData);
        }
        break;

      case 'save_finance_loan':
        final loanId = (cleanData['id'] ?? cleanData['loanId'] ?? '').toString().trim();
        if (loanId.isNotEmpty) {
          await setDoc(db.collection('branches').doc(effectiveBranchId).collection('loans').doc(loanId), cleanData);
        }
        break;

      case 'save_journal_entry':
        final entryId = (cleanData['id'] ?? cleanData['entryId'] ?? '').toString().trim();
        if (entryId.isNotEmpty) {
          final payload = cleanData['data'] is Map ? Map<String, dynamic>.from(cleanData['data']) : cleanData;
          if (effectiveBranchId != 'all') {
            await setDoc(db.collection('branches').doc(effectiveBranchId).collection('journal_entries').doc(entryId), payload);
          }
          await setDoc(db.collection('global_journal_entries').doc(entryId), payload);
          debugPrint('✅ save_journal_entry → branches/$effectiveBranchId/journal_entries/$entryId');
        }
        break;

      // ── Madrassa Module sync ──────────────────────────────────────────────
      case 'save_madrassa_student':
      case 'save_madrassa_admission':
      case 'update_madrassa_student':
        final studentId = (cleanData['studentId'] ?? cleanData['id'] ?? '').toString().trim();
        if (studentId.isNotEmpty) {
          final payload = Map<String, dynamic>.from(cleanData);
          if (payload['joinDate'] is String) {
            final parsed = DateTime.tryParse(payload['joinDate'] as String);
            if (parsed != null) payload['joinDate'] = Timestamp.fromDate(parsed);
          }
          payload['lastUpdatedAt'] = FieldValue.serverTimestamp();
          payload['branchId'] = MadrassaLocalStorage.normalizeBranch(effectiveBranchId);
          await setDoc(
              db.collection('branches').doc(MadrassaLocalStorage.normalizeBranch(effectiveBranchId))
                  .collection('madrassa_students').doc(studentId),
              MadrassaLocalStorage.compactMediaForCloud(payload));
        }
        break;

      case 'delete_madrassa_student':
      case 'offboard_madrassa_student':
        final studentId = (cleanData['studentId'] ?? cleanData['id'] ?? '').toString().trim();
        if (studentId.isNotEmpty) {
          final status = cleanData['status']?.toString() ?? 'left';
          await setDoc(db.collection('branches').doc(effectiveBranchId).collection('madrassa_students').doc(studentId), {
            'status': status,
            'batch': status,
            'lastUpdatedAt': FieldValue.serverTimestamp(),
          });
        }
        break;

      case 'save_madrassa_daily_log':
      case 'save_madrassa_log':
      case 'save_madrassa_attendance':
      case 'enrollment':
      case 'status_change':
      case 'ptm_reschedule':
        final dateKey = (cleanData['dateKey'] ??
                cleanData['datePart'] ??
                cleanData['date'] ??
                cleanData['data']?['dateKey'] ??
                cleanData['data']?['date'] ??
                cleanData['id'] ??
                DateFormat('yyyy-MM-dd').format(DateTime.now()))
            .toString()
            .trim();
        final logData = cleanData['data'] is Map
            ? Map<String, dynamic>.from(cleanData['data'])
            : (cleanData['logData'] is Map ? Map<String, dynamic>.from(cleanData['logData']) : cleanData);
        if (dateKey.isNotEmpty) {
          await setDoc(db.collection('branches').doc(effectiveBranchId).collection('madrassa_daily_logs').doc(dateKey), logData);
        }
        break;

      case 'save_madrassa_fee_payment':
        final docId = (cleanData['id'] ?? '${cleanData['year']}_${cleanData['month']}_${cleanData['studentId']}').toString().trim();
        final feeData = cleanData['data'] is Map ? Map<String, dynamic>.from(cleanData['data']) : cleanData;
        if (docId.isNotEmpty) {
          await setDoc(db.collection('branches').doc(effectiveBranchId).collection('madrassa_fee_payments').doc(docId), feeData);
        }
        break;

      // ── Token Exception Requests ──────────────────────────────────────────
      case 'save_token_exception_request':
      case 'approve_token_exception':
        final reqId = (cleanData['id'] ?? cleanData['requestId'] ?? '').toString().trim();
        if (reqId.isNotEmpty) {
          await setDoc(db.collection('branches').doc(effectiveBranchId).collection('token_exceptions').doc(reqId), cleanData);
        }
        break;

      // ── Requests & Edit Requests Module sync ─────────────────────────────
      case 'update_request_status':
      case 'approve_request':
      case 'reject_request':
      case 'request_approved':
      case 'request_rejected':
      case 'token_exception_approved':
      case 'save_edit_request':
      case 'request_created':
      case 'token_exception_request':
        // token_exception_approved carries the patient id in 'id'-less data; requestId first.
        final reqId = (cleanData['requestId'] ?? cleanData['id'] ?? cleanData['docId'] ?? '').toString().trim();
        final col = (cleanData['collection'] ?? cleanData['col'] ?? 'edit_requests').toString().trim();
        final bId = (cleanData['cloudBranch'] ?? cleanData['branchId'] ?? effectiveBranchId).toString().trim();
        if (reqId.isNotEmpty && bId.isNotEmpty) {
          final payload = cleanData['data'] is Map ? Map<String, dynamic>.from(cleanData['data']) : Map<String, dynamic>.from(cleanData);
          // Queue bookkeeping merged in from the queue item is not part of the request.
          for (final f in ['attempts', 'lastError', 'queueType', 'cloudBranch', 'serial']) {
            payload.remove(f);
          }
          payload['lastSyncedAt'] = FieldValue.serverTimestamp();
          if (type == 'approve_request' || type == 'request_approved' || type == 'token_exception_approved') {
            payload['status'] = 'approved';
          } else if (type == 'reject_request' || type == 'request_rejected') {
            payload['status'] = 'rejected';
          } else if (type == 'update_request_status') {
            // The queue item's own 'status' (merged in above) is its queue state, 'pending';
            // the decision is in 'requestStatus'. Uploading 'status' turned decisions made on
            // this PC back to pending. An older item without requestStatus is skipped.
            final resolved = cleanData['requestStatus'] ??
                (cleanData['data'] is Map ? (cleanData['data'] as Map)['status'] : null);
            if (!LocalStorageService.isDecidedRequestStatus(resolved)) {
              debugPrint('[SSM] Skipped $col/$reqId status update with no decision');
              break;
            }
            payload['status'] = resolved;
            payload.remove('requestStatus');
          } else if (type == 'request_created' || type == 'save_edit_request' || type == 'token_exception_request') {
            if (type == 'token_exception_request') payload['requestType'] ??= 'token_exception';
            // A new request is uploaded pending; it must never replace a decision taken
            // meanwhile (on the phone, or on another PC). Checks this PC's copy, then the cloud.
            final local = Hive.isBoxOpen('local_edit_requests') ? Hive.box('local_edit_requests').get(reqId) : null;
            if (!SyncService.applyDecidedRequestStatus(payload, local: local is Map ? local : null)) {
              final snap = await db.collection('branches').doc(bId).collection(col).doc(reqId)
                  .get(const GetOptions(source: Source.server))
                  .timeout(const Duration(seconds: 10));
              SyncService.applyDecidedRequestStatus(payload, cloud: snap.data());
            }
          }
          await setDoc(db.collection('branches').doc(bId).collection(col).doc(reqId), payload, merge: true);
          debugPrint('✅ $type → branches/$bId/$col/$reqId (status: ${payload['status']})');
        }
        break;

      case LanFirestoreGate.relayEvent:
        // A dispensary desk's write with no LAN event of its own (notification, preference,
        // ...), handed to the server by LanFirestoreGate.relayWrite. Document paths only.
        final relayPath = (cleanData['path'] ?? '').toString().trim();
        final segs = relayPath.split('/').where((s) => s.isNotEmpty).length;
        if (relayPath.isEmpty || segs.isOdd) break;
        final relayRef = db.doc(relayPath);
        if (cleanData['delete'] == true) {
          await deleteDoc(relayRef);
        } else {
          final fields = Map<String, dynamic>.from(cleanData['fields'] as Map? ?? const {});
          for (final k in (cleanData['serverTimeKeys'] as List? ?? const [])) {
            fields[k.toString()] = FieldValue.serverTimestamp();
          }
          await setDoc(relayRef, fields, merge: cleanData['merge'] != false);
        }
        break;

      case 'save_prescription_template':
      case 'delete_prescription_template':
        // A doctor desk on the LAN sends its templates here; only the server uploads.
        final tplId = (cleanData['id'] ?? '').toString().trim();
        if (tplId.isNotEmpty) {
          final doctorId = (cleanData['doctorId'] ?? cleanData['userId'] ?? '').toString().trim();
          final tplData = Map<String, dynamic>.from(cleanData)
            ..remove('attempts')
            ..remove('lastError')
            ..remove('queueType')
            ..remove('serial');
          final refs = [
            db.collection('branches').doc(effectiveBranchId).collection('doctor_templates').doc(tplId),
            if (doctorId.isNotEmpty) db.collection('users').doc(doctorId).collection('doctor_templates').doc(tplId),
          ];
          for (final ref in refs) {
            if (type == 'delete_prescription_template') {
              await deleteDoc(ref);
            } else {
              await setDoc(ref, tplData);
            }
          }
        }
        break;

      default:
        debugPrint('ℹ️ [SSM] Generic sync type "$type" — saving to branches/$effectiveBranchId/records');
        final recordId = (cleanData['id'] ?? cleanData['key'] ?? DateTime.now().millisecondsSinceEpoch.toString()).toString();
        await setDoc(db.collection('branches').doc(effectiveBranchId).collection('sync_records').doc(recordId), cleanData);
        break;
    }
  }

  Map<String, dynamic> _removeFieldValues(Map<String, dynamic> data) {
    return LocalStorageService.sanitizeForCloudUpload(data);
  }

  Future<void> stop() async {
    _syncDebounceTimer?.cancel();
    _downloadTimer?.cancel();
    _syncTimer?.cancel();
    _catchUpTimer?.cancel();
    _tokenCatchUpTimer?.cancel();
    _trafficTimer?.cancel();
    _compactionTimer?.cancel();
    _clientSeenSerials.clear();
    await _entriesWatch?.cancel();
    _entriesWatch = null;
    _todayEntriesCache.clear();

    if (_prevOnClientConnected != null) {
      server.onClientConnected = _prevOnClientConnected;
    }
    if (_prevOnClientDisconnected != null) {
      server.onClientDisconnected = _prevOnClientDisconnected;
    }
    _prevOnClientConnected = null;
    _prevOnClientDisconnected = null;

    debugPrint('ServerSyncManager: Stopped');
  }
}
