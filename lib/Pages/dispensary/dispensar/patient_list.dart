// lib/pages/dispensary/dispensar/patient_list.dart

import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:intl/intl.dart';

import 'package:gmwf/services/local_storage_service.dart';
import 'package:gmwf/services/camp_session_service.dart';
import 'package:gmwf/services/serials_service.dart';
import 'package:gmwf/realtime/realtime_manager.dart';
import 'package:gmwf/realtime/realtime_events.dart';

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
  static const Color _teal   = Color(0xFF00695C);
  static const Color _emerald = Color(0xFF00875A);
  static const Color _indigo  = Color(0xFF4338CA);
  static const Color _amber   = Color(0xFFD97706);

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
  String _dispenseFilter = 'all'; // 'all', 'pending', 'dispensed'

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
    final dk = (e['dateKey'] ?? '').toString().trim();
    final rawTime = e['timestamp'] ?? e['createdAt'] ?? e['date'] ?? e['dispensedAt'] ?? e['completedAt'] ?? e['time'];

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
    } else if (dk.isEmpty && serialDk.isEmpty) {
      isTodayExact = true;
    }

    if (isTodayExact) return true;

    // 2. Shift/Rollover Tolerance: If non-terminal, accept previous day / within 24h
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

  StreamSubscription<Map<String, dynamic>>? _realtimeSub;
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

    _realtimeSub = RealtimeManager().messageStream.listen((event) async {
      final type = event['event_type'] as String?;
      final rawData = event['data'];
      final data = (rawData is Map) ? Map<String, dynamic>.from(rawData) : null;
      if (type == null || !mounted) return;

      final eventBranch = (data?['branchId'] ?? event['branchId'])?.toString().trim().toLowerCase();
      final myBranch    = widget.branchId.toLowerCase().trim();
      if (eventBranch != null && eventBranch.isNotEmpty && eventBranch != myBranch) return;

      if (type == RealtimeEvents.savePrescription ||
          type == 'prescription_created' ||
          type == 'save_prescription') {
        if (data != null) {
          LocalStorageService.saveLocalPrescription(data);
          // [FIX] Link prescription → entry in entriesBox (mirrors server SSM).
          // Without this, the dispenser queue shows 'waiting' even after doctor prescribes.
          final serial = (data['serial'] ?? data['id'])?.toString().trim();
          if (serial != null && serial.isNotEmpty) {
            try {
              final eBox = Hive.box(LocalStorageService.entriesBox);
              final normBranch = myBranch;
              final key = '$normBranch-$serial';
              final existing = eBox.get(key) ?? eBox.get('$normBranch-${serial.toUpperCase()}');
              final updated = (existing is Map)
                  ? Map<String, dynamic>.from(existing)
                  : <String, dynamic>{
                      'branchId': normBranch,
                      'serial': serial,
                      'tokenNumber': serial,
                      'dateKey': data['dateKey'] ?? DateTime.now().toIso8601String().substring(0, 10),
                      'createdAt': data['createdAt'] ?? DateTime.now().toIso8601String(),
                    };

              updated['status'] = 'completed';
              updated['prescription'] = data;
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
              if (data['patientCnic'] != null && data['patientCnic'].toString().isNotEmpty) {
                updated['patientCnic'] = data['patientCnic'];
                updated['cnic'] ??= data['patientCnic'];
              }
              if (data['cnic'] != null && data['cnic'].toString().isNotEmpty) {
                updated['cnic'] = data['cnic'];
                updated['patientCnic'] ??= data['cnic'];
              }
              if (data['guardianCnic'] != null) updated['guardianCnic'] = data['guardianCnic'];
              if (data['patientAge'] != null) updated['patientAge'] = data['patientAge'];
              if (data['patientGender'] != null) updated['patientGender'] = data['patientGender'];
              if (data['dispensaryTag'] != null) updated['dispensaryTag'] = data['dispensaryTag'];
              if (data['dispensaryId'] != null) updated['dispensaryId'] = data['dispensaryId'];
              if (data['campId'] != null) updated['campId'] = data['campId'];
              if (data['campName'] != null) updated['campName'] = data['campName'];
              if (data['session'] != null) updated['session'] = data['session'];

              final writeKey = (existing != null && existing == eBox.get('$normBranch-${serial.toUpperCase()}'))
                  ? '$normBranch-${serial.toUpperCase()}'
                  : key;
              await eBox.put(writeKey, updated);
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
            LocalStorageService.updateDispenseStatus(widget.branchId, serial, 'dispensed');
          }
        }
        _debouncedRebuild();
      }
    });

    WidgetsBinding.instance.addPostFrameCallback((_) {
      _tryAutoSelectSmallestPending();
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

  void _onActiveCampChanged() {
    if (!mounted || !_hasMultiCamps) return;
    final active = CampSessionService.getActiveCamp(widget.branchId);
    if (active != null && active.isNotEmpty && active != 'all' && active != _selectedCampFilter) {
      setState(() {
        _selectedCampFilter = active;
      });
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _tryAutoSelectSmallestPending();
      });
    }
  }

  // ─── Debounce rebuild to batch events ──────────────────────────────
  void _debouncedRebuild() {
    _debounceRebuildTimer?.cancel();
    _debounceRebuildTimer = Timer(const Duration(milliseconds: 300), () {
      if (mounted) {
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
    CampSessionService.activeCampNotifier.removeListener(_onActiveCampChanged);
    super.dispose();
  }

  // ─── Manual Cloud Recovery Pull (On-Demand with 30s Debounce) ─────────
  DateTime? _lastCloudPullTime;
  Future<void> manualCloudPull({bool showToast = true}) async {
    if (_lastCloudPullTime != null &&
        DateTime.now().difference(_lastCloudPullTime!) < const Duration(seconds: 30)) {
      if (showToast && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
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
      ScaffoldMessenger.of(context).showSnackBar(
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

              if (entryData['prescription'] is Map && (entryData['prescription'] as Map).isNotEmpty) {
                LocalStorageService.saveLocalPrescription(
                    Map<String, dynamic>.from(entryData['prescription'] as Map));
              }

              LocalStorageService.saveEntryLocal(widget.branchId, serial, entryData);
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
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Cloud sync complete.'),
              backgroundColor: Color(0xFF00695C),
              duration: Duration(seconds: 2),
            ),
          );
        }
      }
    } catch (e) {
      debugPrint('[PatientList] manualCloudPull error: $e');
    }
  }

  int _extractSerialNumber(Map<String, dynamic> p) {
    final s = (p['serial'] ?? p['id'] ?? '').toString();
    return parseSequenceFromSerial(s);
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

  List<Map<String, dynamic>> _getSortedQueue({String? filterOverride}) {
    final activeShift = CampSessionService.getCurrentSession(null, widget.branchId);
    final userData = _getUserData();
    final scheduledCamps = CampSessionService.getMatchingScheduledCamps(userData);
    final effectiveCamp = _hasMultiCamps
        ? ((_selectedCampFilter != null && _selectedCampFilter!.isNotEmpty && _selectedCampFilter != 'all')
            ? _selectedCampFilter
            : (scheduledCamps.isNotEmpty
                ? scheduledCamps.first
                : CampSessionService.getActiveCamp(widget.branchId)))
        : null;

    final allList = List<Map<String, dynamic>>.from(LocalStorageService.getLocalEntries(widget.branchId));
    final todayIso = DateFormat('yyyy-MM-dd').format(DateTime.now());

    var all = allList.where((e) {
      final serial = (e['serial'] ?? e['id'] ?? '').toString().trim();

      if (!CampSessionService.isSerialMatchingBranch(serial, widget.branchId)) {
        return false;
      }

      if (!_isEffectivelyToday(e, _todayKey, todayIso)) return false;

      final presc = (e['prescription'] is Map && (e['prescription'] as Map).isNotEmpty)
          ? Map<String, dynamic>.from(e['prescription'] as Map)
          : (serial.isNotEmpty && Hive.isBoxOpen(LocalStorageService.prescriptionsBox)
              ? (() {
                  final pBox = Hive.box(LocalStorageService.prescriptionsBox);
                  final raw = pBox.get(serial) ?? pBox.get(serial.toLowerCase()) ?? pBox.get(serial.toUpperCase());
                  return raw is Map ? Map<String, dynamic>.from(raw) : null;
                })()
              : null);
      final status = (e['status'] ?? '').toString().toLowerCase();
      final isDisp = (e['dispenseStatus'] ?? '').toString().toLowerCase() == 'dispensed' || status == 'dispensed';
      final hasPresc = presc != null && (
        (presc['prescriptions'] is List && (presc['prescriptions'] as List).isNotEmpty) ||
        (presc['medicines'] is List && (presc['medicines'] as List).isNotEmpty) ||
        (presc['isVitalsOnly'] == true && presc['completedAt'] != null)
      );

      var name = (e['patientName'] ?? e['name'] ?? '').toString().trim().toLowerCase();
      var cnic = (e['patientCnic'] ?? e['cnic'] ?? e['guardianCnic'] ?? '').toString().trim();

      // Fall back to prescription details if entry name/cnic is missing
      if ((name.isEmpty || name == 'unknown patient' || name == 'unknown') && presc != null) {
        final prName = (presc['patientName'] ?? presc['name'])?.toString().trim();
        if (prName != null && prName.isNotEmpty && prName.toLowerCase() != 'unknown' && prName.toLowerCase() != 'unknown patient') {
          name = prName.toLowerCase();
          e['patientName'] = prName;
        }
        final prCnic = (presc['patientCnic'] ?? presc['cnic'] ?? presc['guardianCnic'])?.toString().trim();
        if (prCnic != null && prCnic.isNotEmpty) {
          cnic = prCnic;
          e['cnic'] = prCnic;
        }
      }

      if ((name.isEmpty || name == 'unknown patient' || name == 'unknown') && cnic.isEmpty) {
        if (serial.isNotEmpty && Hive.isBoxOpen(LocalStorageService.entriesBox)) {
          final box = Hive.box(LocalStorageService.entriesBox);
          final raw = box.get('${widget.branchId}-$serial') ?? box.get(serial) ?? box.get(serial.toUpperCase());
          if (raw is Map) {
            final rName = (raw['patientName'] ?? raw['name'] ?? '').toString().trim();
            final rCnic = (raw['patientCnic'] ?? raw['cnic'] ?? raw['guardianCnic'] ?? '').toString().trim();
            if (rName.isNotEmpty && rName.toLowerCase() != 'unknown' && rName.toLowerCase() != 'unknown patient') {
              name = rName.toLowerCase();
              e['patientName'] = rName;
            }
            if (rCnic.isNotEmpty) {
              cnic = rCnic;
              e['cnic'] = rCnic;
            }
          }
        }
        if ((name.isEmpty || name == 'unknown patient' || name == 'unknown') && cnic.isEmpty) {
          // If token has prescription or completed status, NEVER hide it from dispenser!
          if (hasPresc || status == 'completed' || status == 'dispensed' || isDisp) {
            name = 'token #$serial';
            e['patientName'] = 'Token #$serial';
          } else {
            return false;
          }
        }
      }

      // Camp matching in multi-camp branches
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

      return (status == 'completed' || status == 'dispensed' || status == 'prescribed' || isDisp || hasPresc);
    }).toList();

    // Deduplicate by normalized serial (stripping branch prefix so 'branch-001' and '001' never appear as two patients)
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
        final eDisp = (e['dispenseStatus'] ?? e['status'] ?? '').toString().toLowerCase();
        final tDisp = (target['dispenseStatus'] ?? target['status'] ?? '').toString().toLowerCase();
        if (eDisp == 'dispensed' || tDisp == 'dispensed') {
          target['dispenseStatus'] = 'dispensed';
          target['status'] = 'completed';
        }
      }
    }
    all = uniqueBySerial.values.toList();

    final currentRealShift = CampSessionService.getCurrentSession(null, widget.branchId);
    final targetShift = _selectedSessionFilter == 'auto' ? currentRealShift : _selectedSessionFilter;

    // Strictly isolate to the active session
    if (targetShift != 'all') {
      all = all.where((entry) {
        String resolved = (entry['session'] ?? entry['shift'] ?? entry['campSession'] ?? entry['slot'] ?? '').toString().toLowerCase().trim();

        // Only infer session from createdAt if explicit session is missing/unknown
        if (resolved.isEmpty || resolved == 'unknown' || resolved == 'all' || resolved == 'auto') {
          final rawTime = entry['createdAt'] ?? entry['time'] ?? entry['timestamp'] ?? entry['date'];
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

        if (_selectedSessionFilter == 'auto') {
          return true;
        }

        if (resolved.isNotEmpty) {
          return resolved == targetShift;
        }
        return true;
      }).toList();
    }

    // Search query filter
    if (_searchQuery.isNotEmpty) {
      final q = _searchQuery.toLowerCase();
      all = all.where((e) {
        final s = (e['serial'] ?? e['id'] ?? '').toString().toLowerCase();
        final n = (e['patientName'] ?? e['name'] ?? '').toString().toLowerCase();
        final c = (e['patientCnic'] ?? e['cnic'] ?? e['guardianCnic'] ?? '').toString().toLowerCase();
        final phone = (e['phone'] ?? '').toString().toLowerCase();
        return s.contains(q) || n.contains(q) || c.contains(q) || phone.contains(q);
      }).toList();
    }

    final pending   = <Map<String, dynamic>>[];
    final onHold    = <Map<String, dynamic>>[];
    final dispensed = <Map<String, dynamic>>[];

    for (final e in all) {
      String ds = (e['dispenseStatus'] ?? '').toString().toLowerCase();
      final st = (e['status'] ?? '').toString().toLowerCase();

      if (ds != 'dispensed' && st != 'dispensed') {
        final s = (e['serial'] ?? e['id'] ?? '').toString().trim();
        final dKey = (e['dateKey'] ?? _todayKey).toString().trim();
        if (s.isNotEmpty && Hive.isBoxOpen(LocalStorageService.dispensaryBox)) {
          final dBox = Hive.box(LocalStorageService.dispensaryBox);
          final dispRec = dBox.get('${widget.branchId}_${dKey}_$s') ??
              dBox.get('${widget.branchId}-$s') ??
              dBox.get(s);
          if (dispRec is Map) {
            final recStatus = (dispRec['dispenseStatus'] ?? dispRec['status'] ?? '').toString().toLowerCase();
            if (recStatus == 'dispensed' || recStatus == 'completed') {
              ds = 'dispensed';
              e['dispenseStatus'] = 'dispensed';
            }
          }
        }
      }

      if (ds == 'dispensed' || st == 'dispensed') {
        dispensed.add(e);
      } else if (ds == 'on_hold' || ds == 'hold') {
        onHold.add(e);
      } else {
        pending.add(e);
      }
    }

    int compareTokens(Map<String, dynamic> a, Map<String, dynamic> b) {
      final numA = _extractSerialNumber(a);
      final numB = _extractSerialNumber(b);
      if (numA != numB) {
        return _sortNewestFirst ? numB.compareTo(numA) : numA.compareTo(numB);
      }
      final dtA = a['createdAt']?.toString() ?? '';
      final dtB = b['createdAt']?.toString() ?? '';
      return _sortNewestFirst ? dtB.compareTo(dtA) : dtA.compareTo(dtB);
    }

    pending.sort(compareTokens);
    onHold.sort(compareTokens);
    dispensed.sort(compareTokens);

    final effFilter = filterOverride ?? _dispenseFilter;
    if (effFilter == 'pending') {
      return [...pending, ...onHold];
    } else if (effFilter == 'dispensed') {
      return dispensed;
    }
    return [...pending, ...onHold, ...dispensed];
  }

  void _tryAutoSelectSmallestPending() {
    if (!mounted) return;
    final queue = _getSortedQueue(filterOverride: 'pending');
    final activePending = queue
        .where((p) {
          final ds = (p['dispenseStatus'] ?? '').toString().toLowerCase();
          return ds != 'dispensed' && ds != 'on_hold' && ds != 'hold';
        })
        .toList();

    if (activePending.isEmpty) {
      if (widget.selectedPatient != null &&
          (widget.selectedPatient?['serial']?.toString() ?? '').isNotEmpty) {
        widget.onPatientSelected({});
      }
      return;
    }

    final currentSerial = widget.selectedPatient?['serial']?.toString() ?? '';
    final currentIsStillActive = activePending
        .any((p) => (p['serial']?.toString() ?? '') == currentSerial);

    if (currentSerial.isEmpty || !currentIsStillActive) {
      final smallest = activePending.first;
      widget.onPatientSelected(smallest);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (Hive.isBoxOpen(LocalStorageService.entriesBox)) {
      final box = Hive.box(LocalStorageService.entriesBox);
      if (box.isOpen) {
        return ValueListenableBuilder<Box>(
          valueListenable: box.listenable(),
          builder: (context, box, _) => _buildListContent(context),
        );
      }
    }
    return FutureBuilder<Box>(
      future: LocalStorageService.ensureBoxOpen(LocalStorageService.entriesBox),
      builder: (context, snapshot) {
        if (snapshot.hasData && snapshot.data != null && snapshot.data!.isOpen) {
          return ValueListenableBuilder<Box>(
            valueListenable: snapshot.data!.listenable(),
            builder: (context, box, _) => _buildListContent(context),
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

  Widget _buildListContent(BuildContext context) {
    final screenWidth = MediaQuery.of(context).size.width;
    final isMobile    = screenWidth < 700;

    final allPatients = _getSortedQueue(filterOverride: 'all');

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
                      bgGradientEnd: const Color(0xFFB45309),
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
                      bgGradientEnd: const Color(0xFF00704A),
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
                      bgGradientEnd: const Color(0xFF0D5A50),
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
                color: _isDark ? const Color(0xFF1E293B) : Colors.white,
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
                                color: _isDark ? const Color(0xFF38BDF8) : _teal,
                                size: 24,
                              ),
                              const SizedBox(width: 10),
                              Text(
                                "Dispense Queue",
                                style: TextStyle(
                                  fontSize: 18,
                                  fontWeight: FontWeight.bold,
                                  color: _isDark ? Colors.white : _teal,
                                ),
                              ),
                              const Spacer(),
                              IconButton(
                                icon: Icon(
                                  _sortNewestFirst
                                      ? Icons.arrow_downward_rounded
                                      : Icons.arrow_upward_rounded,
                                  color: _isDark ? const Color(0xFF38BDF8) : _teal,
                                  size: 20,
                                ),
                                onPressed: () => setState(() => _sortNewestFirst = !_sortNewestFirst),
                                tooltip: _sortNewestFirst ? 'Sort: Oldest First' : 'Sort: Newest First',
                              ),
                              IconButton(
                                icon: Icon(
                                  Icons.refresh_rounded,
                                  color: _isDark ? const Color(0xFF38BDF8) : _teal,
                                  size: 22,
                                ),
                                onPressed: () {
                                  setState(() {});
                                  WidgetsBinding.instance.addPostFrameCallback((_) => _tryAutoSelectSmallestPending());
                                },
                                tooltip: 'Refresh queue',
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

                          // Filters Row
                          Row(
                            children: [
                              Text(
                                '$totalCount patients',
                                style: TextStyle(
                                  color: _isDark ? const Color(0xFF94A3B8) : Colors.grey.shade700,
                                  fontSize: 12.5,
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
                                          color: _isDark ? const Color(0xFF475569) : Colors.grey.shade400,
                                        ),
                                        const SizedBox(height: 12),
                                        Text(
                                          "No completed prescriptions in queue",
                                          style: TextStyle(
                                            fontSize: 14,
                                            color: _isDark ? const Color(0xFF94A3B8) : Colors.grey.shade600,
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
                                      color: _isDark ? const Color(0xFF334155) : Colors.grey.shade200,
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

    final isSelected = serial == widget.selectedPatient?['serial']?.toString();

    // Category badge color & text
    Color badgeColor;
    String displayType;
    if (_isKarachi) {
      if (queueTypeRaw == 'gmwf') {
        badgeColor = const Color(0xFFD97706);
        displayType = 'GMWF';
      } else {
        badgeColor = const Color(0xFF00875A);
        displayType = 'PKR 20';
      }
    } else {
      switch (queueTypeRaw) {
        case 'zakat':
          badgeColor = const Color(0xFF00875A);
          displayType = 'Zakat';
          break;
        case 'non-zakat':
          badgeColor = const Color(0xFF4338CA);
          displayType = 'Non-Zakat';
          break;
        case 'gmwf':
          badgeColor = const Color(0xFFD97706);
          displayType = 'GMWF';
          break;
        default:
          badgeColor = const Color(0xFF00875A);
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
      statusBg = _isDark ? const Color(0xFF14532D) : Colors.green.shade50;
      statusText = _isDark ? const Color(0xFF86EFAC) : Colors.green.shade800;
      statusIcon = Icons.check_circle_outline_rounded;
    } else if (isOnHold) {
      statusLabel = 'On Hold';
      statusBg = _isDark ? const Color(0xFF451A03) : Colors.amber.shade50;
      statusText = _isDark ? const Color(0xFFFCD34D) : Colors.amber.shade900;
      statusIcon = Icons.pause_circle_outline_rounded;
    } else {
      statusLabel = 'Waiting to Dispense';
      statusBg = _isDark ? const Color(0xFF1E3A5F) : Colors.blue.shade50;
      statusText = _isDark ? const Color(0xFF93C5FD) : Colors.blue.shade800;
      statusIcon = Icons.medication_outlined;
    }

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
                ? (_isDark ? const Color(0xFF134E4A).withValues(alpha: 0.5) : const Color(0xFFE6FFFA))
                : (_isDark ? const Color(0xFF1E293B) : Colors.white),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(
              color: isSelected
                  ? (_isDark ? const Color(0xFF2DD4BF) : _teal)
                  : (_isDark ? const Color(0xFF334155) : Colors.grey.shade200),
              width: isSelected ? 1.8 : 1.0,
            ),
          ),
          child: Row(
            children: [
              // ── Token Number Pill ──────────────────────────────
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: isDispensed ? Colors.grey.shade500 : badgeColor,
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
                              color: isDispensed
                                  ? Colors.grey.shade500
                                  : (_isDark ? Colors.white : Colors.black87),
                            ),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        if (days > 1) ...[
                          const SizedBox(width: 4),
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1.5),
                            decoration: BoxDecoration(
                              color: Colors.deepOrange,
                              borderRadius: BorderRadius.circular(6),
                            ),
                            child: Text(
                              '${days}d',
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
                    const SizedBox(height: 2),
                    Row(
                      children: [
                        if (cnic.isNotEmpty) ...[
                          GestureDetector(
                            onTap: () {
                              Clipboard.setData(ClipboardData(text: cnic));
                              ScaffoldMessenger.maybeOf(context)?.showSnackBar(
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
                                    color: _isDark ? const Color(0xFF38BDF8) : _teal,
                                    decoration: TextDecoration.underline,
                                  ),
                                ),
                                const SizedBox(width: 3),
                                Icon(Icons.copy_rounded,
                                    size: 11,
                                    color: _isDark ? const Color(0xFF38BDF8) : _teal),
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
                                  ? const Color(0xFF6366F1)
                                  : const Color(0xFF0D9488),
                              borderRadius: BorderRadius.circular(4),
                            ),
                            child: Text(
                              '📍 $campTag',
                              style: const TextStyle(
                                color: Colors.white,
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
              color: isSelected ? Colors.white : Colors.white.withValues(alpha: 0.25),
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
                  Icon(icon, size: 14, color: Colors.white.withValues(alpha: 0.90)),
                  const SizedBox(width: 5),
                  Expanded(
                    child: Text(
                      label,
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: isSelected ? FontWeight.bold : FontWeight.w600,
                        color: Colors.white.withValues(alpha: 0.95),
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
                  color: Colors.white,
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
              child: Text(
                i['label']!,
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  color: isDark ? Colors.white : Colors.black87,
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
      onTap: () => setState(() => _selectedSessionFilter = value),
      borderRadius: BorderRadius.circular(10),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: isSelected ? _teal : (isDark ? const Color(0xFF1E293B) : Colors.white),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: isSelected ? _teal : (isDark ? const Color(0xFF334155) : const Color(0xFFCBD5E1)),
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
            color: isSelected ? Colors.white : (isDark ? const Color(0xFFCBD5E1) : const Color(0xFF334155)),
          ),
        ),
      ),
    );
  }
}
