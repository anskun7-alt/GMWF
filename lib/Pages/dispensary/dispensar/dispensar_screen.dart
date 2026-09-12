// lib/pages/dispensary/dispensar/dispensar_screen.dart

import 'dart:async';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:another_flushbar/flushbar.dart';

import 'package:gmwf/services/local_storage_service.dart';
import 'package:gmwf/services/sync_service.dart';
import 'package:gmwf/services/auth_service.dart';
import 'package:gmwf/realtime/connection_manager.dart';
import 'package:gmwf/realtime/realtime_manager.dart';
import 'package:gmwf/realtime/realtime_events.dart';
import 'package:gmwf/services/camp_session_service.dart';
import 'package:gmwf/widgets/clock_skew_warning_banner.dart';
import 'package:gmwf/widgets/connection_status_widget.dart';
import 'package:gmwf/widgets/gmwf_app_bar.dart';
import 'package:gmwf/widgets/camp_selection_dialog.dart';
import 'package:gmwf/widgets/update_dialog_widget.dart';
import 'package:gmwf/utils/notification_deduper.dart';
import '../user_settings_dialog.dart';
import 'inventory.dart';
import 'patient_form.dart';
import 'patient_list.dart';

class DispensarScreen extends StatefulWidget {
  final String branchId;
  final String? dispenserId;
  final String? dispenserName;
  final bool isEmbedded;
  const DispensarScreen({
    super.key,
    required this.branchId,
    this.dispenserId,
    this.dispenserName,
    this.isEmbedded = false,
  });

  @override
  State<DispensarScreen> createState() => _DispensarScreenState();
}

class _DispensarScreenState extends State<DispensarScreen> with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;

  StreamSubscription<List<ConnectivityResult>>? _connSub;
  StreamSubscription<Map<String, dynamic>>? _realtimeSub;
  StreamSubscription<ConnectionStatus>? _connectionSub;
  final List<StreamSubscription> _inventoryLiveSubs = [];

  bool _online = true;
  bool _isSyncing = false;
  bool _isLoggingOut = false;
  bool _showingForm = false;

  ConnectionStatus _connectionStatus = const ConnectionStatus(
    state: LanConnectionState.disconnected,
    message: 'Not connected',
  );

  String? _dispenserName;
  String? _branchName;
  bool _loadingBranch = true;

  Map<String, dynamic>? _selectedQueueEntry;

  // [BUG-13] Remove function returned by addReconnectListener
  VoidCallback? _removeReconnectListener;

  // [BUG-12] Debounce + guard for reconnect-triggered sync
  Timer? _syncDebounce;
  bool _reconnectSyncing = false;

  static const Color _teal = Color(0xFF00695C);

  @override
  void initState() {
    super.initState();
    LocalStorageService.ensureDoctorBoxesOpen();
    if (!widget.isEmbedded) {
      SyncService().start(widget.branchId);
    }
    _listenConnectivity();
    _startLiveInventoryListener();

    // [FIX-USERNAME] Load name first, then start ConnectionManager with it.
    // We do NOT call ConnectionManager().start() in postFrameCallback anymore
    // because at that point _dispenserName is still null (async fetch pending).
    // Instead _fetchDispenserName() starts the connection once the name is resolved.
    _fetchDispenserName();
    _loadBranchName();

    _connectionSub = ConnectionManager().statusStream.listen((status) {
      if (mounted) setState(() => _connectionStatus = status);
      // [BUG-12] Debounce: only trigger sync after 300 ms of stable connection
      if (status.isConnected && !widget.isEmbedded) {
        _syncDebounce?.cancel();
        _syncDebounce = Timer(const Duration(milliseconds: 300), _syncOnReconnect);
      }
    });

    // [BUG-13] Register via listener list — safe alongside DoctorScreen
    if (!widget.isEmbedded) {
      _removeReconnectListener = ConnectionManager().addReconnectListener(_syncOnReconnect);
    }

    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!widget.isEmbedded) {
        _startBackgroundSync();
        if (mounted) UpdateDialogWidget.showUpdateDialogIfNeeded(context);
      }
    });

    _realtimeSub = RealtimeManager().messageStream.listen(_handleRealtimeMessage);
  }

  void _startLiveInventoryListener() {
    for (final s in _inventoryLiveSubs) {
      s.cancel();
    }
    _inventoryLiveSubs.clear();
    // Pure Local/LAN Architecture: inventory updates are received reactively via LAN events and Hive
  }

  // [FIX-USERNAME] Resolve dispenser name then start/update connection with it.
  Future<void> _fetchDispenserName() async {
    String? resolvedName;

    // 1. Try local cache first (fast, no network needed).
    final user = FirebaseAuth.instance.currentUser;
    if (user != null) {
      final local = LocalStorageService.getLocalUserByUid(user.uid);
      resolvedName = (local?['username'] as String?)?.trim();
      if (resolvedName?.isEmpty == true) resolvedName = null;
    }

    // 2. Fall back to email prefix while Firestore loads.
    resolvedName ??= user?.email?.split('@').first;

    if (mounted) setState(() => _dispenserName = resolvedName);

    // 3. Start connection with whatever name we have so far.
    //    This ensures the identify message goes out quickly.
    if (!widget.isEmbedded) {
      ConnectionManager().start(
        role:     'dispenser',
        branchId: widget.branchId,
        username: resolvedName,
      );
      if (resolvedName != null) {
        RealtimeManager().updateUsername(resolvedName);
      }
    }

    // 4. Fetch from Firestore for the authoritative display name.
    if (user != null) {
      try {
        final doc = await FirebaseFirestore.instance
            .collection('users')
            .doc(user.uid)
            .get();
        final firestoreName =
            (doc.data()?['username'] as String?)?.trim() ??
            (doc.data()?['name']     as String?)?.trim();
        if (firestoreName != null && firestoreName.isNotEmpty) {
          if (mounted) setState(() => _dispenserName = firestoreName);
          // [FIX-USERNAME] Push updated name into RealtimeManager so future
          // messages carry the correct attribution.
          if (!widget.isEmbedded) {
            RealtimeManager().updateUsername(firestoreName);
          }
        }
      } catch (e) {
        debugPrint('[Dispenser] Could not fetch dispenser name from Firestore: $e');
      }
    }
  }

  // FIX-SYNC-2: Upload first, then let triggerUpload() decide whether it is
  // safe to download. Do NOT call downloadTodayTokens() directly here —
  // that would pull stale Firestore data before pending items are uploaded.
  Future<void> _syncOnReconnect() async {
    if (!mounted || _reconnectSyncing) return;
    _reconnectSyncing = true;
    try {
      // triggerUpload() handles upload → conditional download in the right order
      await SyncService().triggerUpload();
      if (mounted) setState(() {});
      debugPrint('[Dispenser] ✅ Synced on reconnect');
    } catch (e) {
      debugPrint('[Dispenser] Reconnect sync failed: $e');
    } finally {
      _reconnectSyncing = false;
    }
  }

  Future<void> _startBackgroundSync() async {
    try {
      await LocalStorageService.downloadInventory(widget.branchId);
      await SyncService().initialFullDownload(widget.branchId);
    } catch (e) {
      debugPrint('Background sync error: $e');
    }
  }

  void _handleRealtimeMessage(Map<String, dynamic> event) {
    final type = event['event_type'] as String?;
    final rawData = event['data'];
    final data = (rawData is Map) ? Map<String, dynamic>.from(rawData) : Map<String, dynamic>.from(event);
    if (type == null || data.isEmpty) return;

    final senderId = event['_clientId']?.toString() ?? '';
    final myId = RealtimeManager().clientId;
    if (senderId.isNotEmpty && myId != null && senderId == myId) return;

    final serial = data['serial']?.toString().trim();
    final branch = (data['branchId'] ?? event['branchId'] ?? event['_senderBranch'] ?? '')
        .toString().toLowerCase().trim();

    if (branch.isNotEmpty && branch != widget.branchId.toLowerCase().trim()) return;

    // ── Handle INVENTORY events (no patient serial) ───────────────────────────
    if (type == RealtimeEvents.saveStockItem || type == 'save_stock_item' || type == 'medicine_registered') {
      // RealtimeRouter._handleSaveStockItem already ran (before this stream listener fires)
      // and correctly persisted the stock update to Hive (with delta handling).
      // We only refresh the UI state here to avoid applying the delta twice.
      if (mounted) setState(() {});
      return;
    } else if (type == RealtimeEvents.deleteStockItem || type == 'delete_stock_item') {
      final mId = (data['id'] ?? data['medicineId'])?.toString();
      if (mId != null) LocalStorageService.deleteLocalStockItem(mId);
      if (mounted) setState(() {});
      return;
    }

    if (serial == null) return;

    final isReplay = event['_serverPush'] == true ||
        event['_resent'] == true ||
        event['isCatchUp'] == true ||
        event['_isReplay'] == true ||
        data['_serverPush'] == true ||
        data['_resent'] == true ||
        data['isCatchUp'] == true ||
        data['_isReplay'] == true;

    final today = CampSessionService.resolveShiftAndDateKey().dateKey;
    final itemDateKey = (data['dateKey'] ?? event['dateKey'])?.toString().trim();
    final parts = serial.contains('-') ? serial.split('-') : <String>[];
    final serialDk = (parts.isNotEmpty && parts[0].toUpperCase() == 'X')
        ? (parts.length > 1 ? parts[1] : '')
        : (parts.isNotEmpty ? parts[0] : '');
    final isToday = (itemDateKey == null || itemDateKey.isEmpty || itemDateKey == today) &&
        (serialDk.length != 6 || serialDk == today);

    final hasMultiCamps = CampSessionService.hasCampsForBranch(widget.branchId);
    final activeCamp = CampSessionService.getActiveCamp(widget.branchId);
    final matchesActiveCamp = (!hasMultiCamps || activeCamp == null || activeCamp.isEmpty || activeCamp == 'all')
        ? true
        : CampSessionService.matchesCamp(
            selectedCamp: activeCamp,
            dispensaryId: data['dispensaryId']?.toString(),
            campId: data['campId']?.toString(),
            dispensaryTag: data['dispensaryTag']?.toString(),
            serial: serial,
          );

    if (type == RealtimeEvents.savePrescription || type == 'prescription_created') {
      LocalStorageService.saveLocalPrescription(data);

      final normBranch = widget.branchId.toLowerCase().trim();
      final normSerial = serial.toLowerCase().trim();
      final box = Hive.box(LocalStorageService.entriesBox);
      dynamic actualKey;
      dynamic entry;
      for (final k in ['$normBranch-$serial', '$normBranch-${serial.toUpperCase()}', '$normBranch-$normSerial', serial, serial.toUpperCase()]) {
        if (box.containsKey(k)) {
          actualKey = k;
          entry = box.get(k);
          break;
        }
      }

      if (entry != null && actualKey != null) {
        final updated = Map<String, dynamic>.from(entry as Map);
        updated['status'] = 'completed';
        updated['completedAt'] = data['completedAt'] ?? DateTime.now().toIso8601String();
        updated['prescription'] = data;
        box.put(actualKey, updated);
        if (serial.toUpperCase() == (_selectedQueueEntry?['serial'] ?? _selectedQueueEntry?['id'] ?? '').toString().toUpperCase()) {
          _selectedQueueEntry = updated;
        }
      }
      if (mounted) setState(() {});

      final entryMap = (entry is Map) ? entry as Map : null;
      final isAlreadyDispensed = (entryMap?['dispenseStatus'] ?? data['dispenseStatus']) == 'dispensed';

      final rawTime = data['completedAt'] ?? data['createdAt'] ?? data['timestamp'];
      final dt = rawTime != null ? DateTime.tryParse(rawTime.toString()) : null;
      final isRecent = dt == null || DateTime.now().difference(dt).inMinutes <= 3;

      if (!isReplay && isToday && !isAlreadyDispensed && isRecent && matchesActiveCamp) {
        if (NotificationDeduper.shouldShow('dispenser_presc_${widget.branchId}_$serial', window: const Duration(minutes: 5))) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) {
              Flushbar(
                message: '💊 Prescription ready for #$serial',
                backgroundColor: Colors.blue.shade700,
                duration: const Duration(seconds: 5),
              ).show(context);
            }
          });
        }
      }

    } else if (type == RealtimeEvents.saveEntry || type == 'token_created') {
      // [BUG-14] Use saveEntryLocal for proper sanitisation
      LocalStorageService.saveEntryLocal(widget.branchId, serial, data);
      if (mounted) setState(() {});

      final status = (data['status'] ?? 'waiting').toString().toLowerCase();
      final isWaiting = status == 'waiting';
      final isAlreadyDispensed = data['dispenseStatus'] == 'dispensed';

      final rawTime = data['createdAt'] ?? data['timestamp'];
      final dt = rawTime != null ? DateTime.tryParse(rawTime.toString()) : null;
      final isRecent = dt == null || DateTime.now().difference(dt).inMinutes <= 3;

      if (!isReplay && isToday && isWaiting && !isAlreadyDispensed && isRecent && matchesActiveCamp) {
        if (NotificationDeduper.shouldShow('dispenser_token_${widget.branchId}_$serial', window: const Duration(minutes: 5))) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) {
              Flushbar(
                message: '🎟️ New token: #$serial',
                backgroundColor: Colors.green.shade700,
                duration: const Duration(seconds: 4),
              ).show(context);
            }
          });
        }
      }

    } else if (type == 'dispense_completed') {
      final box = Hive.box(LocalStorageService.entriesBox);
      final key = '${widget.branchId}-$serial';
      final entry = box.get(key);
      if (entry != null) {
        final updated = Map<String, dynamic>.from(entry);
        updated['dispenseStatus'] = 'dispensed';
        box.put(key, updated);
      }
      if (serial == _selectedQueueEntry?['serial'] && mounted) {
        setState(() {
          _selectedQueueEntry = null;
          _showingForm = false;
        });
      }
    }
  }

  static final Map<String, String> _cachedBranchNames = {};

  Future<void> _loadBranchName() async {
    if (widget.branchId.isEmpty) {
      if (mounted) setState(() { _branchName = 'Free Dispensary'; _loadingBranch = false; });
      return;
    }
    if (_cachedBranchNames.containsKey(widget.branchId)) {
      if (mounted) setState(() {
        _branchName = _cachedBranchNames[widget.branchId];
        _loadingBranch = false;
      });
      return;
    }
    try {
      final doc = await FirebaseFirestore.instance.collection('branches').doc(widget.branchId).get(const GetOptions(source: Source.cache));
      final name = doc.data()?['name'] ?? 'Free Dispensary';
      _cachedBranchNames[widget.branchId] = name;
      if (mounted) setState(() { _branchName = name; _loadingBranch = false; });
    } catch (_) {
      if (mounted) setState(() { _branchName = 'Free Dispensary'; _loadingBranch = false; });
    }
  }

  void _listenConnectivity() {
    _connSub = Connectivity().onConnectivityChanged.listen((results) async {
      final isOnline = results.any((r) => r != ConnectivityResult.none);
      if (_online != isOnline && mounted) {
        setState(() => _online = isOnline);
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) {
            Flushbar(
              message: isOnline ? 'Internet restored — syncing...' : 'Offline (LAN still works)',
              backgroundColor: isOnline ? Colors.green.shade700 : Colors.orange.shade700,
              duration: const Duration(seconds: 4),
            ).show(context);
          }
        });
        if (isOnline) {
          RealtimeManager().forceFlushAndCatchUp().ignore();
          SyncService().triggerUpload().ignore();
        }
      }
    });
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
      if (mounted) setState(() {});
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          Flushbar(
            message: _online ? 'Full sync completed (LAN & Cloud)' : 'LAN Sync completed (Outbox flushed)',
            backgroundColor: Colors.green.shade700,
            duration: const Duration(seconds: 4),
          ).show(context);
        }
      });
    } catch (e) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          Flushbar(message: 'Sync failed: $e', backgroundColor: Colors.red.shade700, duration: const Duration(seconds: 5)).show(context);
        }
      });
    } finally {
      if (mounted) setState(() => _isSyncing = false);
    }
  }

  Future<void> _logout() async {
    if (_isLoggingOut) return;
    if (mounted) setState(() => _isLoggingOut = true);
    try { _connectionSub?.cancel(); _connSub?.cancel(); _realtimeSub?.cancel(); } catch (_) {}
    ConnectionManager().stop().catchError((_) {});
    await AuthService().signOut();
    if (mounted) Navigator.pushNamedAndRemoveUntil(context, '/login', (r) => false);
  }

  PreferredSizeWidget _buildAppBar(bool isMobile) {
    return GmwfAppBar(
      title: 'Dispensary – ${_dispenserName ?? widget.dispenserName ?? 'Loading...'}',
      subtitle: CampSessionService.getBranchAndCampDisplayName(
        branchName: _branchName ?? 'Free Dispensary',
        branchId: widget.branchId,
        campId: CampSessionService.getActiveCamp(),
      ),
      onTitleLongPress: () => DispensaryUserSettingsDialog.show(
        context,
        branchId: widget.branchId,
        onUserUpdated: () {
          if (mounted) setState(() { _fetchDispenserName(); });
        },
      ),
      titleTooltip: 'Long press for Settings',
      connectionStatus: _connectionStatus,
      onRetryConnection: () => ConnectionManager().reconnectNow(),
      isOnline: _online,
      isSyncing: _isSyncing,
      onSync: _forceSync,
      onLogout: _logout,
      extraActions: [
        Tooltip(
          message: 'Medicine Inventory',
          child: Material(
            color: Colors.transparent,
            child: InkWell(
              borderRadius: BorderRadius.circular(12),
              onTap: () => Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => InventoryPage(
                    branchId: widget.branchId,
                    isDispenser: true,
                  ),
                ),
              ),
              child: Container(
                width: 38,
                height: 38,
                decoration: BoxDecoration(
                  color: _isDark ? const Color(0xFF1E293B) : Colors.white,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(
                    color: _isDark ? const Color(0xFF334155) : const Color(0xFFE2E8F0),
                    width: 1,
                  ),
                ),
                child: Center(
                  child: Icon(
                    Icons.inventory_2_outlined,
                    size: 18,
                    color: _isDark ? const Color(0xFF38BDF8) : const Color(0xFF0F5B46),
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
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
  Widget build(BuildContext context) {
    super.build(context);
    final screenWidth = MediaQuery.of(context).size.width;
    final isMobile = screenWidth < 700;

    return ValueListenableBuilder<Box>(
      valueListenable: Hive.box('app_settings').listenable(keys: ['is_dark_mode']),
      builder: (context, box, _) {
        final isDark = box.get('is_dark_mode', defaultValue: false) == true;

        final bodyContent = Container(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: isDark
                  ? const [Color(0xFF0F172A), Color(0xFF1E293B)]
                  : const [Color(0xFFE8F5E9), Color(0xFFF1F8E9)],
            ),
          ),
          child: Column(
            children: [
              ClockSkewWarningBanner(branchId: widget.branchId),
              Expanded(
                child: isMobile ? _buildMobileLayout() : _buildDesktopLayout(),
              ),
            ],
          ),
        );

        if (widget.isEmbedded) return bodyContent;

        return Scaffold(
          backgroundColor: isDark ? const Color(0xFF0F172A) : const Color(0xFFF1F8F5),
          appBar: _buildAppBar(isMobile),
          body: bodyContent,
        );
      },
    );
  }

  Widget _buildMobileLayout() {
    if (_showingForm && _selectedQueueEntry != null) {
      return Column(children: [
        Container(
          color: _isDark ? const Color(0xFF1E293B) : Colors.white,
          child: Row(children: [
            TextButton.icon(
              onPressed: () => setState(() { _showingForm = false; }),
              icon: Icon(Icons.arrow_back, color: _isDark ? const Color(0xFF38BDF8) : _teal),
              label: Text('Queue', style: TextStyle(color: _isDark ? const Color(0xFF38BDF8) : _teal)),
            ),
            const Spacer(),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Text(
                '#${_selectedQueueEntry!['serial'] ?? ''}',
                style: TextStyle(fontWeight: FontWeight.bold, color: _isDark ? Colors.white : _teal),
              ),
            ),
          ]),
        ),
        Divider(height: 1, color: _isDark ? const Color(0xFF334155) : null),
        Expanded(
          child: PatientForm(
            branchId: widget.branchId,
            queueEntry: _selectedQueueEntry!,
            onDispensed: () => setState(() { _selectedQueueEntry = null; _showingForm = false; }),
            dispenserName: _dispenserName,
          ),
        ),
      ]);
    }

    return Padding(
      padding: const EdgeInsets.all(12),
      child: PatientList(
        branchId: widget.branchId,
        dispenserId: widget.dispenserId,
        dispenserName: _dispenserName ?? widget.dispenserName,
        selectedPatient: _selectedQueueEntry,
        onPatientSelected: (e) {
          if (e.isEmpty) return;
          setState(() {
            _selectedQueueEntry = e;
            _showingForm = true;
          });
        },
      ),
    );
  }

  Widget _buildDesktopLayout() {
    return LayoutBuilder(builder: (context, constraints) {
      final isTablet = constraints.maxWidth >= 1100;
      final queueWidth = isTablet ? 470.0 : constraints.maxWidth * 0.40;
      return Padding(
        padding: const EdgeInsets.all(20),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Left Queue Column
            SizedBox(
              width: queueWidth,
              child: PatientList(
                branchId: widget.branchId,
                dispenserId: widget.dispenserId,
                dispenserName: _dispenserName ?? widget.dispenserName,
                selectedPatient: _selectedQueueEntry,
                onPatientSelected: (e) {
                  if (mounted) {
                    setState(() => _selectedQueueEntry = e);
                  }
                },
              ),
            ),
            const SizedBox(width: 20),

            // Right Form Column
            Expanded(
              child: Card(
                elevation: 10,
                color: _isDark ? const Color(0xFF1E293B) : Colors.white,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(28),
                ),
                clipBehavior: Clip.antiAlias,
                child: _selectedQueueEntry == null
                    ? Center(
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Icon(
                              Icons.medication_liquid_rounded,
                              size: 80,
                              color: _isDark
                                  ? const Color(0xFF475569)
                                  : Colors.grey.shade300,
                            ),
                            const SizedBox(height: 16),
                            Text(
                              'Select a patient to dispense medicines',
                              style: TextStyle(
                                fontSize: 18,
                                fontWeight: FontWeight.w600,
                                color: _isDark
                                    ? const Color(0xFF94A3B8)
                                    : Colors.grey.shade600,
                              ),
                              textAlign: TextAlign.center,
                            ),
                          ],
                        ),
                      )
                    : PatientForm(
                        key: ValueKey(_selectedQueueEntry!['serial'] ?? _selectedQueueEntry!['id']),
                        branchId: widget.branchId,
                        queueEntry: _selectedQueueEntry!,
                        onDispensed: () {
                          if (mounted) {
                            setState(() => _selectedQueueEntry = null);
                          }
                        },
                        dispenserName: _dispenserName,
                      ),
              ),
            ),
          ],
        ),
      );
    });
  }

  @override
  void dispose() {
    _syncDebounce?.cancel();
    for (final s in _inventoryLiveSubs) {
      s.cancel();
    }
    // [BUG-13] Unregister from ConnectionManager's listener list
    _removeReconnectListener?.call();
    if (!widget.isEmbedded) {
      ConnectionManager().stop();
    }
    _connectionSub?.cancel();
    _connSub?.cancel();
    _realtimeSub?.cancel();
    super.dispose();
  }
}
