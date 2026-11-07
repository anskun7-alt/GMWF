// lib/pages/dispensary/dispensar/patient_list.dart

import 'dart:async';
import 'package:gmwf/design/tokens/soft_palette.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:cloud_firestore/cloud_firestore.dart';

import 'package:gmwf/services/local_storage_service.dart';
import 'package:gmwf/services/camp_session_service.dart';
import 'package:gmwf/realtime/realtime_manager.dart';
import 'package:gmwf/realtime/realtime_events.dart';
import 'package:gmwf/realtime/connection_manager.dart';
import 'package:gmwf/design/design_system.dart';
import 'dispense_queue.dart';

class PatientList extends StatefulWidget {
  final String branchId;
  final String? dispenserId;
  final String? dispenserName;
  final Map<String, dynamic>? selectedPatient;
  final Function(Map<String, dynamic>) onPatientSelected;

  const PatientList({
    super.key,
    required this.branchId,
    this.dispenserId,
    this.dispenserName,
    this.selectedPatient,
    required this.onPatientSelected,
  });

  @override
  State<PatientList> createState() => _PatientListState();
}

class _PatientListState extends State<PatientList> {
  static const Color _teal   = SoftPalette.teal600;
  static const Color _emerald = SoftPalette.emerald550;
  static const Color _indigo  = SoftPalette.indigo600;
  static const Color _amber   = SoftPalette.orange400;

  bool get _isDark {
    try {
      if (Hive.isBoxOpen('app_settings')) {
        final dark = Hive.box('app_settings').get('is_dark_mode');
        if (dark != null) return dark == true;
      }
    } catch (_) {}
    return Theme.of(context).brightness == Brightness.dark;
  }

  bool get _isKarachi => widget.branchId.toLowerCase().contains('karachi') || widget.branchId.toLowerCase().contains('khi');

  final ScrollController _scroll = ScrollController();
  final TextEditingController _searchCtrl = TextEditingController();
  String _searchQuery = '';

  String get _todayKey => CampSessionService.resolveShiftAndDateKey(null, widget.branchId).dateKey;
  String _selectedSessionFilter = 'all';
  String _selectedCampFilter = 'all';
  bool get _hasMultiCamps => CampSessionService.hasCampsForBranch(widget.branchId);
  bool _sortNewestFirst = false;
  bool _isSyncingQueue = false;
  String _dispenseFilter = 'all'; // 'all', 'pending', 'dispensed'

  StreamSubscription<Map<String, dynamic>>? _realtimeSub;
  StreamSubscription<BoxEvent>? _entriesBoxSub;
  Timer? _debounceRebuildTimer;

  @override
  void initState() {
    super.initState();

    if (_hasMultiCamps) {
      final active = CampSessionService.getActiveCamp(widget.branchId);
      if (active != null && active.isNotEmpty && active != 'all') {
        _selectedCampFilter = active;
      }
    }
    CampSessionService.activeCampNotifier.addListener(_onActiveCampChanged);
    ConnectionManager().addReconnectListener(_onLanReconnected);
    // Another desk opened a patient (skip them) or won the same token (move on).
    DispenseQueue.listenForClaims();
    DispenseQueue.claimsChanged.addListener(_debouncedRebuild);

    if (Hive.isBoxOpen(LocalStorageService.entriesBox)) {
      _refreshQueueCache();
      _entriesBoxSub = Hive.box(LocalStorageService.entriesBox).watch().listen((_) {
        _debouncedRebuild();
      });
    }

    _realtimeSub = RealtimeManager().messageStream.listen((event) async {
      final type = event['event_type'] as String?;
      final rawData = event['data'];
      final data = (rawData is Map) ? Map<String, dynamic>.from(rawData) : null;
      if (type == null || !mounted) return;

      final eventBranch = (data?['branchId'] ?? event['branchId'])?.toString().trim().toLowerCase();
      final myBranch    = widget.branchId.toLowerCase().trim();
      if (eventBranch != null &&
          eventBranch.isNotEmpty &&
          eventBranch != 'all' &&
          eventBranch != 'default' &&
          myBranch.isNotEmpty &&
          myBranch != 'all' &&
          myBranch != 'default' &&
          !CampSessionService.areBranchesMatching(eventBranch, myBranch)) {
        return;
      }

      if (type == RealtimeEvents.savePrescription ||
          type == 'prescription_created' ||
          type == 'save_prescription') {
        if (data != null) {
          LocalStorageService.saveLocalPrescription(data);
          // Link prescription → entry in entriesBox
          final serial = (data['serial'] ?? data['id'])?.toString().trim();
          if (serial != null && serial.isNotEmpty) {
            try {
              final eBox = Hive.box(LocalStorageService.entriesBox);
              final normBranch = myBranch;
              final upperSerial = serial.toUpperCase();
              final lowerSerial = serial.toLowerCase();
              dynamic existingKey;
              dynamic existing;

              for (final k in [
                '$normBranch-$serial',
                '$normBranch-$upperSerial',
                '$normBranch-$lowerSerial',
                if (eventBranch != null && eventBranch.isNotEmpty) '$eventBranch-$serial',
                if (eventBranch != null && eventBranch.isNotEmpty) '$eventBranch-$upperSerial',
                serial,
                upperSerial,
                lowerSerial
              ]) {
                if (eBox.containsKey(k)) {
                  existingKey = k;
                  existing = eBox.get(k);
                  break;
                }
              }

              if (existing is Map && LocalStorageService.isOlderPrescription(data, existing['prescription'])) {
                _debouncedRebuild();
                return;
              }
              final updated = (existing is Map)
                  ? Map<String, dynamic>.from(existing)
                  : <String, dynamic>{
                      'branchId': normBranch,
                      'serial': upperSerial,
                      'tokenNumber': upperSerial,
                      'dateKey': data['dateKey'] ?? DateTime.now().toIso8601String().substring(0, 10),
                      'createdAt': data['createdAt'] ?? DateTime.now().toIso8601String(),
                    };

              updated['status'] = 'completed';
              // Not an older or medicine-less copy over the stored prescription.
              if (existing is! Map || LocalStorageService.mayReplacePrescription(data, existing['prescription'])) {
                final embeddedRx = LocalStorageService.prescriptionForEmbedding(data);
                updated['prescription'] = embeddedRx;
                final rxMeds = embeddedRx['medicines'] ?? embeddedRx['prescriptions'] ?? data['medicines'] ?? data['prescriptions'];
                if (rxMeds is List && rxMeds.isNotEmpty) {
                  updated['medicines'] = rxMeds;
                  updated['prescriptions'] = rxMeds;
                }
              }
              updated['prescriptionId'] = data['id'] ?? serial;
              updated['completedAt'] ??= data['completedAt'] ?? DateTime.now().toIso8601String();
              if (data['doctorName'] != null) updated['doctorName'] = data['doctorName'];
              if (data['doctorId'] != null) updated['doctorId'] = data['doctorId'];
              if (data['daysOfMedicine'] != null) updated['daysOfMedicine'] = data['daysOfMedicine'];

              final pName = (data['patientName'] ?? data['name'])?.toString().trim();
              if (pName != null && pName.isNotEmpty && pName.toLowerCase() != 'unknown' && pName.toLowerCase() != 'unknown patient') {
                updated['patientName'] = pName;
                updated['name'] = pName;
              }
              final incomingP = data['patientCnic']?.toString().trim();
              if (incomingP != null && incomingP.isNotEmpty && !incomingP.startsWith('unknown_') && incomingP != '00000-0000000-0' && incomingP != '-') {
                updated['patientCnic'] = incomingP;
                updated['cnic'] ??= incomingP;
              }
              final incomingC = data['cnic']?.toString().trim();
              if (incomingC != null && incomingC.isNotEmpty && !incomingC.startsWith('unknown_') && incomingC != '00000-0000000-0' && incomingC != '-') {
                updated['cnic'] = incomingC;
                updated['patientCnic'] ??= incomingC;
              }
              if (data['guardianCnic'] != null) updated['guardianCnic'] = data['guardianCnic'];
              if (data['patientAge'] != null) updated['patientAge'] = data['patientAge'];
              if (data['patientGender'] != null) updated['patientGender'] = data['patientGender'];
              if (data['dispensaryTag'] != null) updated['dispensaryTag'] = data['dispensaryTag'];
              if (data['dispensaryId'] != null) updated['dispensaryId'] = data['dispensaryId'];
              if (data['campId'] != null) updated['campId'] = data['campId'];
              if (data['campName'] != null) updated['campName'] = data['campName'];
              if (data['session'] != null) updated['session'] = data['session'];
              // Never downgrade a dispensed token. Prescriptions are re-sent over LAN (doctor
              // reconnects, server catch-ups) carrying the doctor's 'pending', which flipped
              // dispensed patients back to "not dispensed" again and again.
              final wasDispensed = (updated['dispenseStatus'] ?? '').toString().toLowerCase() == 'dispensed';
              if (data['dispenseStatus'] != null && !wasDispensed) updated['dispenseStatus'] = data['dispenseStatus'];
              // The first key found may be an old duplicate; any dispensed copy wins.
              DispenseQueue.keepDispensedState(updated, [
                '$normBranch-$serial', '$normBranch-$upperSerial', '$normBranch-$lowerSerial',
                serial, upperSerial, lowerSerial,
              ].map(eBox.get));

              // One write, and none when nothing changed (each put wakes every
              // entries-box listener; three puts per event tripled the rebuilds).
              final writeKey = existingKey ?? '$normBranch-$upperSerial';
              if (existing is! Map || !_sameEntry(existing, updated)) {
                await eBox.put(writeKey, updated);
              }
              // Keep any other existing key variant of this serial in sync (never
              // create new duplicates) so a stale copy can't win the de-duplication.
              for (final k in ['$normBranch-$upperSerial', '$normBranch-$serial']) {
                if (k == writeKey) continue;
                final other = eBox.get(k);
                if (other is Map && !_sameEntry(other, updated)) {
                  await eBox.put(k, updated);
                }
              }
            } catch (_) {}
          }
        }
        _debouncedRebuild();
      } else if (type == RealtimeEvents.saveEntry ||
          type == 'token_created' ||
          type == 'save_entry') {
        if (data != null) {
          final serial = (data['serial'] ?? data['id'])?.toString();
          if (serial != null && serial.isNotEmpty) {
            LocalStorageService.saveEntryLocal(widget.branchId, serial, data);
          }
        }
        _debouncedRebuild();
      } else if (type == 'dispense_completed') {
        if (data != null) {
          final serial = (data['serial'] ?? data['id'])?.toString();
          if (serial != null && serial.isNotEmpty) {
            LocalStorageService.updateDispenseStatus(widget.branchId, serial, 'dispensed', receivedViaLan: true);
          }
        }
        _debouncedRebuild();
      }
    });

    WidgetsBinding.instance.addPostFrameCallback((_) {
      _tryAutoSelectSmallestPending();
      RealtimeManager().requestCatchUp(branchId: widget.branchId);
    });
  }

  @override
  void didUpdateWidget(PatientList oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.selectedPatient != widget.selectedPatient ||
        widget.selectedPatient == null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _tryAutoSelectSmallestPending();
      });
    }
  }

  List<Map<String, dynamic>> _cachedAllPatients = [];
  bool _isQueueInitialized = false;

  void _refreshQueueCache() {
    try {
      _cachedAllPatients = _getSortedQueue(filterOverride: 'all');
      _isQueueInitialized = true;
    } catch (e) {
      debugPrint('[PatientList] Error refreshing queue cache: $e');
    }
  }

  void _onActiveCampChanged() {
    if (!mounted || !_hasMultiCamps) return;
    final active = CampSessionService.getActiveCamp(widget.branchId);
    if (active != null && active.isNotEmpty && active != 'all' && active != _selectedCampFilter) {
      _selectedCampFilter = active;
      _refreshQueueCache();
      setState(() {});
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _tryAutoSelectSmallestPending();
      });
    }
  }

  // ─── Debounce rebuild to batch events ──────────────────────────────
  void _debouncedRebuild() {
    _debounceRebuildTimer?.cancel();
    _debounceRebuildTimer = Timer(const Duration(milliseconds: 150), () {
      if (mounted) {
        _refreshQueueCache();
        setState(() {});
        WidgetsBinding.instance.addPostFrameCallback((_) {
          _tryAutoSelectSmallestPending();
        });
      }
    });
  }

  @override
  void dispose() {
    _debounceRebuildTimer?.cancel();
    _scroll.dispose();
    _searchCtrl.dispose();
    _realtimeSub?.cancel();
    _entriesBoxSub?.cancel();
    CampSessionService.activeCampNotifier.removeListener(_onActiveCampChanged);
    ConnectionManager().removeReconnectListener(_onLanReconnected);
    DispenseQueue.claimsChanged.removeListener(_debouncedRebuild);
    super.dispose();
  }

  /// Shallow equality of two entry maps (nested maps compared by their string form).
  static bool _sameEntry(Map a, Map b) {
    if (a.length != b.length) return false;
    for (final k in a.keys) {
      if (!b.containsKey(k)) return false;
      final va = a[k], vb = b[k];
      if (va == vb) continue;
      if ((va is Map || va is List) && va.toString() == vb.toString()) continue;
      return false;
    }
    return true;
  }

  void _onLanReconnected() {
    if (!mounted) return;
    debugPrint('[PatientList] 🔄 LAN reconnected — requesting catch-up from server');
    try {
      RealtimeManager().requestCatchUp(branchId: widget.branchId);
    } catch (_) {}
    _debouncedRebuild();
  }

  // ─── Manual Cloud Recovery Pull (On-Demand with 30s Debounce) ─────────
  DateTime? _lastCloudPullTime;
  Future<void> manualCloudPull({bool showToast = true}) async {
    if (_lastCloudPullTime != null &&
        DateTime.now().difference(_lastCloudPullTime!) < const Duration(seconds: 30)) {
      if (showToast && mounted) {
        AppToast.showSnackBar(context, 
          const SnackBar(
            content: Text('Please wait 30 seconds between cloud syncs.'),
            duration: Duration(seconds: 2),
          ),
        );
      }
      return;
    }
    _lastCloudPullTime = DateTime.now();

    if (widget.branchId.isEmpty) return;

    if (showToast && mounted) {
      AppToast.showSnackBar(context, 
        const SnackBar(
          content: Text('Syncing today\'s patient list from cloud...'),
          duration: Duration(seconds: 2),
        ),
      );
    }

    final docIds = CampSessionService.getAllCampDateDocIds(
      branchId: widget.branchId,
      dateKey: _todayKey,
    );

    try {
      bool hasChanges = false;
      for (final docId in docIds) {
        final serialsRef = FirebaseFirestore.instance
            .collection('branches')
            .doc(widget.branchId)
            .collection('serials')
            .doc(docId);

        for (final type in ['zakat', 'non-zakat', 'gmwf']) {
          try {
            final snap = await serialsRef.collection(type).get(const GetOptions(source: Source.serverAndCache));
            for (final doc in snap.docs) {
              final data = doc.data();
              final serial = (data['serial'] ?? doc.id).toString();
              final entryData = Map<String, dynamic>.from(data);
              entryData['queueType'] ??= type;
              entryData['dateKey']   ??= _todayKey;
              entryData['serial']    ??= serial;

              // One after the other: run concurrently, the token save read the entry before the
              // prescription save wrote it and then put its older copy back. Both keep the
              // newer prescription with medicines (preferredPrescription).
              await LocalStorageService.saveEntryLocal(widget.branchId, serial, entryData);
              if (entryData['prescription'] is Map && (entryData['prescription'] as Map).isNotEmpty) {
                await LocalStorageService.saveLocalPrescription(
                    Map<String, dynamic>.from(entryData['prescription'] as Map));
              }
              hasChanges = true;
            }
          } catch (e) {
            debugPrint('[PatientList] Manual pull error ($type / $docId): $e');
          }
        }
      }
      if (hasChanges && mounted) {
        _debouncedRebuild();
        if (showToast) {
          AppToast.showSnackBar(context, 
            const SnackBar(
              content: Text('Cloud sync complete.'),
              backgroundColor: SoftPalette.teal600,
              duration: Duration(seconds: 2),
            ),
          );
        }
      }
    } catch (e) {
      debugPrint('[PatientList] manualCloudPull error: $e');
    }
  }

  Map<String, dynamic> _getUserData() {
    try {
      if (Hive.isBoxOpen('app_settings')) {
        final box = Hive.box('app_settings');
        final data = box.get('user_data') ?? box.get('currentUser');
        if (data is Map) {
          return Map<String, dynamic>.from(data);
        }
      }
    } catch (_) {}
    return {};
  }

  List<String> get _allowedSessions => CampSessionService.getAllowedSessions(widget.branchId, userData: _getUserData());

  int _getDaysOfMedicine(Map<String, dynamic> e) {
    final dynamic rawDays = e['daysOfMedicine'] ?? e['days'];
    if (rawDays is int && rawDays > 0) return rawDays;
    if (rawDays is String) {
      final parsed = int.tryParse(rawDays);
      if (parsed != null && parsed > 0) return parsed;
    }
    final presc = e['prescription'];
    if (presc is Map) {
      final pDays = presc['daysOfMedicine'] ?? presc['days'];
      if (pDays is int && pDays > 0) return pDays;
      if (pDays is String) {
        final parsed = int.tryParse(pDays);
        if (parsed != null && parsed > 0) return parsed;
      }
    }
    return 1;
  }

  List<Map<String, dynamic>>? _queueMemo;
  List<Map<String, dynamic>>? _queueMemoSrc;
  String _queueMemoKey = '';
  DateTime _queueMemoAt = DateTime.fromMillisecondsSinceEpoch(0);

  List<Map<String, dynamic>> _getSortedQueue({String? filterOverride}) {
    final src = LocalStorageService.getLocalEntries(widget.branchId);
    final key = '${filterOverride ?? ''}|$_selectedSessionFilter|$_selectedCampFilter|$_searchQuery|$_sortNewestFirst|$_todayKey|${widget.branchId}';
    final now = DateTime.now();
    if (_queueMemo != null &&
        identical(src, _queueMemoSrc) &&
        key == _queueMemoKey &&
        now.difference(_queueMemoAt).inMilliseconds < 1500) {
      return _queueMemo!;
    }
    final result = _computeSortedQueue(filterOverride: filterOverride);
    _queueMemo = result;
    _queueMemoSrc = src;
    _queueMemoKey = key;
    _queueMemoAt = now;
    return result;
  }

  // Queue rules live in DispenseQueue (shared with the Hybrid Pharmacy tab).
  List<Map<String, dynamic>> _computeSortedQueue({String? filterOverride}) => DispenseQueue.compute(
        branchId: widget.branchId,
        sessionFilter: _selectedSessionFilter,
        campFilter: _selectedCampFilter,
        searchQuery: _searchQuery,
        newestFirst: _sortNewestFirst,
        filter: filterOverride ?? _dispenseFilter,
      );

  void _tryAutoSelectSmallestPending() {
    if (!mounted) return;
    if (!_isQueueInitialized) {
      _refreshQueueCache();
    }
    final activePending = DispenseQueue.pendingInTokenOrder(_cachedAllPatients);

    if (activePending.isEmpty) {
      if (widget.selectedPatient != null &&
          (widget.selectedPatient?['serial']?.toString() ?? '').isNotEmpty) {
        widget.onPatientSelected({});
      }
      return;
    }

    final currentSerial = widget.selectedPatient?['serial']?.toString() ?? '';
    final currentIsStillActive = activePending
        .any((p) => DispenseQueue.sameSerial(p['serial'], currentSerial));

    if (currentSerial.isEmpty || !currentIsStillActive) {
      final smallest = activePending.first;
      widget.onPatientSelected(smallest);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (Hive.isBoxOpen(LocalStorageService.entriesBox)) {
      if (!_isQueueInitialized) {
        _refreshQueueCache();
      }
      return _buildListContent(context);
    }
    return FutureBuilder<Box>(
      future: LocalStorageService.ensureBoxOpen(LocalStorageService.entriesBox),
      builder: (context, snapshot) {
        if (snapshot.hasData && snapshot.data != null && snapshot.data!.isOpen) {
          if (!_isQueueInitialized) {
            _refreshQueueCache();
            _entriesBoxSub ??= snapshot.data!.watch().listen((_) {
              _debouncedRebuild();
            });
          }
          return _buildListContent(context);
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

  Widget _buildListContent(BuildContext context) {
    final isMobile = GBreakpoint.isMobile(context);

    if (!_isQueueInitialized) {
      _refreshQueueCache();
    }
    final allPatients = _cachedAllPatients;

        final pendingList = allPatients
            .where((p) =>
                (p['dispenseStatus'] ?? '').toString().toLowerCase() != 'dispensed')
            .toList();
        final dispensedList = allPatients
            .where((p) =>
                (p['dispenseStatus'] ?? '').toString().toLowerCase() == 'dispensed')
            .toList();

        final waitingCount   = pendingList.length;
        final dispensedCount = dispensedList.length;
        final totalCount     = allPatients.length;

        final patients = _dispenseFilter == 'pending'
            ? pendingList
            : (_dispenseFilter == 'dispensed' ? dispensedList : allPatients);

        return Column(
          children: [
            // ── Summary Cards (Matching Receptionist Solid Aesthetics) ───────
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Row(
                children: [
                  Expanded(
                    child: _compactSummaryCard(
                      label: 'Waiting',
                      value: '$waitingCount',
                      icon: Icons.hourglass_top_rounded,
                      bgGradientStart: _amber,
                      bgGradientEnd: SoftPalette.orange500,
                      glowColor: _amber,
                      isSelected: _dispenseFilter == 'pending',
                      onTap: () => setState(() => _dispenseFilter = _dispenseFilter == 'pending' ? 'all' : 'pending'),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: _compactSummaryCard(
                      label: 'Dispensed',
                      value: '$dispensedCount',
                      icon: Icons.check_circle_outline_rounded,
                      bgGradientStart: _emerald,
                      bgGradientEnd: SoftPalette.emerald600,
                      glowColor: _emerald,
                      isSelected: _dispenseFilter == 'dispensed',
                      onTap: () => setState(() => _dispenseFilter = _dispenseFilter == 'dispensed' ? 'all' : 'dispensed'),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: _compactSummaryCard(
                      label: 'Total Queue',
                      value: '$totalCount',
                      icon: Icons.people_alt_rounded,
                      bgGradientStart: _teal,
                      bgGradientEnd: SoftPalette.teal600,
                      glowColor: _teal,
                      isSelected: _dispenseFilter == 'all',
                      onTap: () => setState(() => _dispenseFilter = 'all'),
                    ),
                  ),
                ],
              ),
            ),

            // ── Main Card (Matching Receptionist Today's Tokens Card) ────────
            Expanded(
              child: Card(
                elevation: 8,
                color: _isDark ? SoftPalette.slate800 : SoftPalette.gray50,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(24),
                ),
                clipBehavior: Clip.antiAlias,
                child: Stack(
                  children: [
                    // ── Golden Watermark (1.webp) on Bottom Right ──────────
                    Positioned(
                      right: -135,
                      bottom: -50,
                      width: 320,
                      height: 320,
                      child: IgnorePointer(
                        child: Transform.rotate(
                          angle: -0.16,
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

                    // ── Card Content ───────────────────────────────────────
                    Padding(
                      padding: const EdgeInsets.all(20),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          // Header Row
                          Row(
                            children: [
                              Icon(
                                Icons.list_alt_rounded,
                                color: _isDark ? SoftPalette.sky350 : _teal,
                                size: 24,
                              ),
                              const SizedBox(width: 10),
                              Text(
                                "Dispense Queue",
                                style: TextStyle(
                                  fontSize: 18,
                                  fontWeight: FontWeight.bold,
                                  color: _isDark ? SoftPalette.gray50 : _teal,
                                ),
                              ),
                              const Spacer(),
                              IconButton(
                                icon: Icon(
                                  _sortNewestFirst
                                      ? Icons.arrow_downward_rounded
                                      : Icons.arrow_upward_rounded,
                                  color: _isDark ? SoftPalette.sky350 : _teal,
                                  size: 20,
                                ),
                                onPressed: () => setState(() {
                                  _sortNewestFirst = !_sortNewestFirst;
                                  _refreshQueueCache();
                                }),
                                tooltip: _sortNewestFirst ? 'Sort: Oldest First' : 'Sort: Newest First',
                              ),
                              IconButton(
                                icon: _isSyncingQueue
                                    ? SizedBox(
                                        width: 18,
                                        height: 18,
                                        child: CircularProgressIndicator(
                                          color: _isDark ? SoftPalette.sky350 : _teal,
                                          strokeWidth: 2,
                                        ),
                                      )
                                    : Icon(
                                        Icons.refresh_rounded,
                                        color: _isDark ? SoftPalette.sky350 : _teal,
                                        size: 22,
                                      ),
                                onPressed: _isSyncingQueue
                                    ? null
                                    : () async {
                                        setState(() => _isSyncingQueue = true);
                                        try {
                                          // 1. Force immediate LAN catch-up sweep from LAN Server
                                          await RealtimeManager().forceFlushAndCatchUp();
                                          // 2. Fetch today's tokens from Cloud Firestore fallback
                                          await LocalStorageService.downloadTodayTokens(widget.branchId);
                                        } catch (e) {
                                          debugPrint('[PatientList] Manual refresh error: $e');
                                        } finally {
                                          if (mounted) {
                                            setState(() => _isSyncingQueue = false);
                                            WidgetsBinding.instance.addPostFrameCallback(
                                                (_) => _tryAutoSelectSmallestPending());
                                          }
                                        }
                                      },
                                tooltip: 'Refresh & Fetch Missing Tokens from Server',
                              ),
                            ],
                          ),

                          // Session / Shift Filter Bar inside Card
                          Padding(
                            padding: const EdgeInsets.only(top: 8, bottom: 8),
                            child: SizedBox(
                              width: double.infinity,
                              child: SingleChildScrollView(
                                scrollDirection: Axis.horizontal,
                                child: Row(
                                  children: [
                                    _buildSessionChip('auto', '⚡ Current (${CampSessionService.getCurrentSession(null, widget.branchId).toUpperCase()})', _isDark),
                                    const SizedBox(width: 6),
                                    _buildSessionChip('all', '📋 All Today', _isDark),
                                    if (_allowedSessions.contains('morning') || _allowedSessions.contains('all')) ...[
                                      const SizedBox(width: 6),
                                      _buildSessionChip('morning', '☀️ Morning', _isDark),
                                    ],
                                    if (_allowedSessions.contains('evening') || _allowedSessions.contains('all')) ...[
                                      const SizedBox(width: 6),
                                      _buildSessionChip('evening', '🌅 Evening', _isDark),
                                    ],
                                    if (_allowedSessions.contains('night') || _allowedSessions.contains('all')) ...[
                                      const SizedBox(width: 6),
                                      _buildSessionChip('night', '🌙 Night', _isDark),
                                    ],
                                  ],
                                ),
                              ),
                            ),
                          ),

                          // Header Row (Patient Count)
                          Row(
                            children: [
                              Text(
                                '$totalCount patients',
                                style: TextStyle(
                                  color: _isDark ? SoftPalette.slate350 : SoftPalette.gray550,
                                  fontSize: 13,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ],
                          ),
                          const Divider(height: 18),

                          // Patient List
                          Expanded(
                            child: patients.isEmpty
                                ? Center(
                                    child: Column(
                                      mainAxisAlignment: MainAxisAlignment.center,
                                      children: [
                                        Icon(
                                          Icons.assignment_turned_in_outlined,
                                          size: 56,
                                          color: _isDark ? SoftPalette.slate600 : SoftPalette.gray300,
                                        ),
                                        const SizedBox(height: 12),
                                        Text(
                                          "No completed prescriptions in queue",
                                          style: TextStyle(
                                            fontSize: 14,
                                            color: _isDark ? SoftPalette.slate350 : SoftPalette.gray500,
                                          ),
                                          textAlign: TextAlign.center,
                                        ),
                                      ],
                                    ),
                                  )
                                : ListView.separated(
                                    controller: _scroll,
                                    itemCount: patients.length,
                                    separatorBuilder: (_, _) => Divider(
                                      height: 1,
                                      color: _isDark ? SoftPalette.slate700 : SoftPalette.gray100,
                                    ),
                                    itemBuilder: (context, index) {
                                      final patient = patients[index];
                                      return _buildPatientItem(patient, isMobile);
                                    },
                                  ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        );
  }

  Widget _buildPatientItem(Map<String, dynamic> e, bool isMobile) {
    final serial = e['serial'] as String? ?? 'N/A';
    final rawName = (e['patientName'] ?? e['name'] ?? e['fullName'])?.toString().trim();
    final name = (rawName != null && rawName.isNotEmpty && rawName.toLowerCase() != 'null')
        ? rawName
        : 'Unknown Patient';
    final cnic = (e['patientCnic'] ?? e['cnic'] ?? e['guardianCnic'])?.toString().trim() ?? '';
    final queueTypeRaw = (e['queueType'] as String?)?.toLowerCase().trim() ?? 'unknown';
    final days = _getDaysOfMedicine(e);

    final isDispensed = (e['dispenseStatus'] ?? '').toString().toLowerCase() == 'dispensed' ||
        (e['status'] ?? '').toString().toLowerCase() == 'dispensed';
    final isOnHold = (e['dispenseStatus'] ?? '').toString().toLowerCase() == 'on_hold' ||
        (e['dispenseStatus'] ?? '').toString().toLowerCase() == 'hold';
    final isPending = !isDispensed && !isOnHold;

    final isSelected = DispenseQueue.sameSerial(serial, widget.selectedPatient?['serial']);

    // Category badge color & text
    Color badgeColor;
    String displayType;
    if (_isKarachi) {
      if (queueTypeRaw == 'gmwf') {
        badgeColor = SoftPalette.orange400;
        displayType = 'GMWF';
      } else {
        badgeColor = SoftPalette.emerald550;
        displayType = 'PKR 20';
      }
    } else {
      switch (queueTypeRaw) {
        case 'zakat':
          badgeColor = SoftPalette.emerald550;
          displayType = 'Zakat';
          break;
        case 'non-zakat':
          badgeColor = SoftPalette.indigo600;
          displayType = 'Non-Zakat';
          break;
        case 'gmwf':
          badgeColor = SoftPalette.orange400;
          displayType = 'GMWF';
          break;
        default:
          badgeColor = SoftPalette.emerald550;
          displayType = 'Zakat';
      }
    }

    // Status pill
    String statusLabel;
    Color statusBg;
    Color statusText;
    IconData statusIcon;

    if (isDispensed) {
      statusLabel = 'Dispensed';
      statusBg = _isDark ? SoftPalette.green700 : SoftPalette.green100m;
      statusText = _isDark ? SoftPalette.emerald200 : SoftPalette.green550;
      statusIcon = Icons.check_circle_outline_rounded;
    } else if (isOnHold) {
      statusLabel = 'On Hold';
      statusBg = _isDark ? SoftPalette.orange800 : SoftPalette.yellow50;
      statusText = _isDark ? SoftPalette.yellow200 : SoftPalette.orange350;
      statusIcon = Icons.pause_circle_outline_rounded;
    } else {
      statusLabel = 'Waiting to Dispense';
      statusBg = _isDark ? SoftPalette.blue750 : SoftPalette.slate100;
      statusText = _isDark ? SoftPalette.blue300 : SoftPalette.blue550;
      statusIcon = Icons.medication_outlined;
    }

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

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: () {
          widget.onPatientSelected(e);
        },
        borderRadius: BorderRadius.circular(10),
        child: Container(
          margin: const EdgeInsets.symmetric(vertical: 3),
          padding: EdgeInsets.symmetric(
            horizontal: isMobile ? 8 : 12,
            vertical: 8,
          ),
          decoration: BoxDecoration(
            color: isSelected
                ? (_isDark ? SoftPalette.teal700.withValues(alpha: 0.5) : SoftPalette.teal50)
                : (_isDark ? SoftPalette.slate800 : SoftPalette.gray50),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(
              color: isSelected
                  ? (_isDark ? SoftPalette.teal300 : _teal)
                  : (_isDark ? SoftPalette.slate700 : SoftPalette.gray100),
              width: isSelected ? 1.8 : 1.0,
            ),
          ),
          child: Row(
            children: [
              // ── Token Number Pill ──────────────────────────────
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: isDispensed ? SoftPalette.gray350 : badgeColor,
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
                              color: isDispensed
                                  ? SoftPalette.gray350
                                  : (_isDark ? SoftPalette.gray50 : SoftPalette.gray900A87),
                            ),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        if (days > 1) ...[
                          const SizedBox(width: 4),
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1.5),
                            decoration: BoxDecoration(
                              color: SoftPalette.red400,
                              borderRadius: BorderRadius.circular(6),
                            ),
                            child: Text(
                              '${days}d',
                              style: const TextStyle(
                                color: SoftPalette.gray50,
                                fontSize: 10,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ),
                        ],
                      ],
                    ),
                    const SizedBox(height: 2),
                    Row(
                      children: [
                        if (cnic.isNotEmpty) ...[
                          GestureDetector(
                            onTap: () {
                              Clipboard.setData(ClipboardData(text: cnic));
                              AppToast.showSnackBar(context, 
                                SnackBar(
                                  content: Text('Copied CNIC: $cnic'),
                                  duration: const Duration(seconds: 1),
                                ),
                              );
                            },
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Text(
                                  cnic,
                                  style: TextStyle(
                                    fontSize: 11,
                                    color: _isDark ? SoftPalette.sky350 : _teal,
                                    decoration: TextDecoration.underline,
                                  ),
                                ),
                                const SizedBox(width: 3),
                                Icon(Icons.copy_rounded,
                                    size: 11,
                                    color: _isDark ? SoftPalette.sky350 : _teal),
                              ],
                            ),
                          ),
                          const SizedBox(width: 6),
                        ],
                        if (_hasMultiCamps && campTag.isNotEmpty) ...[
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                            decoration: BoxDecoration(
                              color: campTag.contains('HAJI')
                                  ? SoftPalette.indigo500
                                  : SoftPalette.teal500,
                              borderRadius: BorderRadius.circular(4),
                            ),
                            child: Text(
                              '📍 $campTag',
                              style: const TextStyle(
                                color: SoftPalette.gray50,
                                fontSize: 9,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ),
                        ],
                      ],
                    ),
                  ],
                ),
              ),

              const SizedBox(width: 8),

              // ── Category & Status Pills ────────────────────────
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                    decoration: BoxDecoration(
                      color: isDarkCategoryBadgeBg(badgeColor),
                      borderRadius: BorderRadius.circular(6),
                      border: Border.all(color: badgeColor.withValues(alpha: 0.5)),
                    ),
                    child: Text(
                      displayType,
                      style: TextStyle(
                        fontSize: 10,
                        fontWeight: FontWeight.bold,
                        color: badgeColor,
                      ),
                    ),
                  ),
                  const SizedBox(height: 3),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                    decoration: BoxDecoration(
                      color: statusBg,
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(statusIcon, size: 11, color: statusText),
                        const SizedBox(width: 3),
                        Text(
                          statusLabel,
                          style: TextStyle(
                            fontSize: 10,
                            fontWeight: FontWeight.bold,
                            color: statusText,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Color isDarkCategoryBadgeBg(Color baseColor) {
    return _isDark ? baseColor.withValues(alpha: 0.20) : baseColor.withValues(alpha: 0.10);
  }

  Widget _compactSummaryCard({
    required String label,
    required String value,
    required IconData icon,
    required Color bgGradientStart,
    required Color bgGradientEnd,
    required Color glowColor,
    VoidCallback? onTap,
    bool isSelected = false,
  }) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(16),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [bgGradientStart, bgGradientEnd],
            ),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(
              color: isSelected ? SoftPalette.gray50 : SoftPalette.gray50.withValues(alpha: 0.25),
              width: isSelected ? 2.2 : 1.0,
            ),
            boxShadow: [
              BoxShadow(
                color: glowColor.withValues(alpha: isSelected ? 0.48 : 0.28),
                blurRadius: isSelected ? 14 : 10,
                offset: const Offset(0, 4),
              ),
            ],
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(icon, size: 14, color: SoftPalette.gray50.withValues(alpha: 0.90)),
                  const SizedBox(width: 5),
                  Expanded(
                    child: Text(
                      label,
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: isSelected ? FontWeight.bold : FontWeight.w600,
                        color: SoftPalette.gray50.withValues(alpha: 0.95),
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              Text(
                value,
                style: const TextStyle(
                  fontSize: 19,
                  fontWeight: FontWeight.bold,
                  color: SoftPalette.gray50,
                ),
              ),
            ],
          ),
        ),
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
              child: Text(
                i['label']!,
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  color: isDark ? SoftPalette.gray50 : SoftPalette.gray900A87,
                ),
              ),
            );
          }).toList(),
          onChanged: onChanged,
        ),
      ),
    );
  }

  Widget _buildSessionChip(String value, String label, bool isDark) {
    final isSelected = _selectedSessionFilter == value;
    return InkWell(
      onTap: () => setState(() {
        _selectedSessionFilter = value;
        _refreshQueueCache();
      }),
      borderRadius: BorderRadius.circular(10),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: isSelected ? _teal : (isDark ? SoftPalette.slate800 : SoftPalette.gray50),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: isSelected ? _teal : (isDark ? SoftPalette.slate700 : SoftPalette.slate200),
            width: 1,
          ),
          boxShadow: isSelected
              ? [BoxShadow(color: _teal.withValues(alpha: 0.3), blurRadius: 4, offset: const Offset(0, 1))]
              : null,
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 11,
            fontWeight: isSelected ? FontWeight.bold : FontWeight.w600,
            color: isSelected ? SoftPalette.gray50 : (isDark ? SoftPalette.slate200 : SoftPalette.slate700),
          ),
        ),
      ),
    );
  }
}
