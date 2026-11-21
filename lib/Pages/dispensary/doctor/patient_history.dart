// lib/pages/dispensary/doctor/patient_history.dart

import 'dart:async';
import 'dart:convert';
import 'package:gmwf/design/tokens/soft_palette.dart';
import 'package:gmwf_ui/gmwf_ui.dart' show GEmptyIllustration, GEmptyIllustrationKind;
import 'package:gmwf/design/tokens/comfort_colors.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:intl/intl.dart';

import 'package:gmwf/services/local_storage_service.dart';
import 'package:gmwf/services/camp_session_service.dart';
import 'package:gmwf/services/staff_patient_link_service.dart';
import 'package:gmwf/widgets/app_skeleton.dart';
import '../widgets/medicine_icon_badge.dart';

// Alias kept for backwards compatibility with existing call sites
typedef PatientHistory = PatientHistoryPanel;

// ═══════════════════════════════════════════════════════════════════════════════
// HYBRID ID UTILITIES
// ═══════════════════════════════════════════════════════════════════════════════

class _IdHelper {
  static Set<String> variants(String id) {
    final clean = id.trim();
    if (clean.isEmpty) return {};
    final noHyphens  = clean.replaceAll('-', '').replaceAll(' ', '');
    final digitsOnly = clean.replaceAll(RegExp(r'\D'), '');
    final set = <String>{clean, noHyphens, if (digitsOnly.isNotEmpty) digitsOnly};
    // If standard 13-digit Pakistani CNIC, also generate the hyphenated form XXXXX-XXXXXXX-X
    if (digitsOnly.length == 13) {
      set.add('${digitsOnly.substring(0, 5)}-${digitsOnly.substring(5, 12)}-${digitsOnly.substring(12)}');
    }
    return set;
  }

  static List<String> expand(Iterable<String> ids) {
    final result = <String>{};
    for (final id in ids) {
      result.addAll(variants(id));
    }
    return result.where((s) => s.isNotEmpty).toList();
  }

  static bool matches(String candidate, Iterable<String> searchIds) {
    final c = candidate.trim();
    if (c.isEmpty) return false;
    final expandedSearch = expand(searchIds);
    for (final v in variants(c)) {
      if (expandedSearch.contains(v)) return true;
    }
    return false;
  }
}

// ═══════════════════════════════════════════════════════════════════════════════
// PATIENT IDENTITY
// A stable value object that captures everything we know about a patient.
// Two _PatientIdentity objects are equal iff they represent the same patient.
// ═══════════════════════════════════════════════════════════════════════════════

class _PatientIdentity {
  final String patientId;
  final String cnic;
  final String guardianCnic;
  final String name;       // needed to distinguish children of the same guardian
  final bool   isAdult;

  const _PatientIdentity({
    required this.patientId,
    required this.cnic,
    required this.guardianCnic,
    required this.name,
    required this.isAdult,
  });

  factory _PatientIdentity.fromMap(Map<String, dynamic>? data, String? rawCnic) {
    if (data == null && (rawCnic == null || rawCnic.isEmpty)) {
      return const _PatientIdentity(
          patientId: '', cnic: '', guardianCnic: '', name: '', isAdult: true);
    }
    final d = data ?? {};
    String pid      = (d['patientId'] ?? '').toString().trim();
    String cnic     = (d['cnic'] ?? d['patientCnic'] ?? rawCnic ?? '').toString().trim();
    String guardian = (d['guardianCnic'] ?? '').toString().trim();
    String name     = (d['name'] ?? d['patientName'] ?? d['fullName'] ?? '').toString().trim();
    bool isAdult    = d['isAdult'] as bool? ?? cnic.isNotEmpty;

    // If patientId is empty or was set to a daily serial string (e.g. 030926-HAJI-007 or 141026E-SADD-001),
    // resolve the individual patient ID from local storage
    if (pid.isEmpty || (pid.contains('-') && RegExp(r'^\d{6}[A-Za-z]?-').hasMatch(pid))) {
      final resolved = LocalStorageService.resolveIndividualPatientId(d);
      if (resolved.isNotEmpty && !RegExp(r'^\d{6}[A-Za-z]?-').hasMatch(resolved)) {
        pid = resolved;
      } else if (pid.isEmpty) {
        pid = (d['id'] ?? '').toString().trim();
      }
    }

    // Normalise — strip hyphens for comparison
    cnic     = cnic.replaceAll('-', '');
    guardian = guardian.replaceAll('-', '');

    return _PatientIdentity(
      patientId:    pid,
      cnic:         cnic,
      guardianCnic: guardian,
      name:         name.toLowerCase(),
      isAdult:      isAdult,
    );
  }

  /// A stable string key that uniquely identifies this patient.
  /// For adults   → their own CNIC (or patientId as fallback).
  /// For children → guardianCnic + normalised name (siblings have different names).
  String get key {
    if (cnic.isNotEmpty && isAdult) return cnic;
    if (!isAdult && guardianCnic.isNotEmpty && name.isNotEmpty) {
      return '${guardianCnic}_child_${name.replaceAll(RegExp(r'[^a-z0-9]'), '')}';
    }
    if (patientId.isNotEmpty && !RegExp(r'^\d{6}[A-Za-z]?-').hasMatch(patientId)) return patientId;
    if (cnic.isNotEmpty) return cnic;
    if (name.isNotEmpty) return 'name_${name.replaceAll(RegExp(r'[^a-z0-9]'), '')}';
    return patientId;
  }

  bool get isEmpty => key.isEmpty;

  @override
  bool operator ==(Object other) =>
      other is _PatientIdentity && other.key == key;

  @override
  int get hashCode => key.hashCode;

  @override
  String toString() => key;

  /// Returns identifiers to use when querying Firestore / Hive.
  /// For adults   → own CNIC variants.
  /// For children → guardian CNIC variants only (Firestore docs use guardianCnic).
  /// Name-based filtering happens in Dart after fetching.
  List<String> get searchIds {
    final ids = <String>{};
    if (cnic.isNotEmpty)        ids.addAll(_IdHelper.variants(cnic));
    if (patientId.isNotEmpty)   ids.addAll(_IdHelper.variants(patientId));
    if (guardianCnic.isNotEmpty) ids.addAll(_IdHelper.variants(guardianCnic));
    return ids.where((s) => s.isNotEmpty).toList();
  }

  /// Whether a doc/entry/prescription belongs to this individual patient.
  /// Strictly prevents mixing adult history with child history under the same CNIC.
  bool docBelongsToThisPatient(Map<String, dynamic> doc) {
    final docPid = (doc['patientId'] ?? doc['id'] ?? '').toString().trim();
    final docResolvedPid = LocalStorageService.resolveIndividualPatientId(doc).trim();
    final docGuardian = (doc['guardianCnic'] ?? '').toString().replaceAll('-', '').trim();
    final docAge = (doc['age'] is num) ? (doc['age'] as num).toInt() : (int.tryParse(doc['age']?.toString() ?? '') ?? 0);
    final docCnic = (doc['cnic'] ?? doc['patientCnic'] ?? '').toString().replaceAll(RegExp(r'[-\s]'), '').trim();

    final docIsAdult = doc['isAdult'] is bool
        ? doc['isAdult'] as bool
        : (!docPid.contains('_child_') && !docResolvedPid.contains('_child_') && docGuardian.isEmpty && (docAge == 0 || docAge >= 18));

    // Rule 0: Never mix adult and child history
    if (isAdult != docIsAdult) return false;

    // Direct canonical ID match
    final cleanMyPid = patientId.replaceAll(RegExp(r'[^\w]'), '').toLowerCase();
    final cleanDocPid = docPid.replaceAll(RegExp(r'[^\w]'), '').toLowerCase();
    final cleanDocResolved = docResolvedPid.replaceAll(RegExp(r'[^\w]'), '').toLowerCase();
    if (cleanMyPid.isNotEmpty && (cleanMyPid == cleanDocPid || cleanMyPid == cleanDocResolved)) {
      return true;
    }

    final docName = (doc['patientName'] ?? doc['name'] ?? '')
        .toString()
        .trim()
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9]'), '');
    final myName = name.replaceAll(RegExp(r'[^a-z0-9]'), '');

    // For adults: if CNIC matches, ensure names match if both present
    if (isAdult) {
      if (cnic.isNotEmpty && docCnic.isNotEmpty && cnic == docCnic) {
        if (name.isNotEmpty && docName.isNotEmpty) {
          if (docName == myName || docName.contains(myName) || myName.contains(docName)) {
            return true;
          }
          final myWords = name.split(RegExp(r'[\s_]+')).where((w) => w.length > 2).toSet();
          final docWords = (doc['patientName'] ?? doc['name'] ?? '').toString().toLowerCase().split(RegExp(r'[\s_]+')).where((w) => w.length > 2).toSet();
          if (myWords.isNotEmpty && docWords.isNotEmpty && myWords.intersection(docWords).isNotEmpty) {
            return true;
          }
          return false;
        }
        return true;
      }
    }

    // For children: under same guardian CNIC, MUST match child name
    if (!isAdult) {
      final myGuard = guardianCnic.isNotEmpty ? guardianCnic : cnic;
      final docGuard = docGuardian.isNotEmpty ? docGuardian : docCnic;
      if (myGuard.isNotEmpty && docGuard.isNotEmpty && myGuard == docGuard) {
        if (name.isNotEmpty && docName.isNotEmpty) {
          if (docName == myName || docName.contains(myName) || myName.contains(docName)) {
            return true;
          }
          final myWords = name.split(RegExp(r'[\s_]+')).where((w) => w.length > 2).toSet();
          final docWords = (doc['patientName'] ?? doc['name'] ?? '').toString().toLowerCase().split(RegExp(r'[\s_]+')).where((w) => w.length > 2).toSet();
          if (myWords.isNotEmpty && docWords.isNotEmpty && myWords.intersection(docWords).isNotEmpty) {
            return true;
          }
        }
      }
      return false;
    }

    return false;
  }

  /// Backward-compatible alias
  bool docBelongsToThisChild(Map<String, dynamic> doc) => docBelongsToThisPatient(doc);
}

// ═══════════════════════════════════════════════════════════════════════════════
// PANEL WIDGET
// ═══════════════════════════════════════════════════════════════════════════════

class PatientHistoryPanel extends StatefulWidget {
  final String branchId;
  final Map<String, dynamic>? patientData;
  final String? patientCnic;
  final void Function(Map<String, dynamic>)? onRepeatLast;
  final bool compactMode;

  const PatientHistoryPanel({
    super.key,
    required this.branchId,
    this.patientData,
    this.patientCnic,
    this.onRepeatLast,
    this.compactMode = false,
  });

  /// Recursively unwraps double or multiple nested prescription maps
  /// e.g. entry['prescription']['prescription']['prescriptions'] -> entry['prescriptions']
  static Map<String, dynamic> unwrapPrescriptionData(Map<String, dynamic> raw) {
    Map<String, dynamic> current = Map<String, dynamic>.from(raw);
    for (int i = 0; i < 5; i++) {
      bool changed = false;
      if (current['data'] is Map) {
        final d = Map<String, dynamic>.from(current['data'] as Map);
        d.forEach((k, v) => current.putIfAbsent(k, () => v));
      }
      if (current['prescription'] is Map) {
        final p = Map<String, dynamic>.from(current['prescription'] as Map);
        p.forEach((k, v) => current.putIfAbsent(k, () => v));
        if (p.containsKey('prescription') ||
            p.containsKey('prescriptions') ||
            p.containsKey('medicines') ||
            p.containsKey('oralMedicines') ||
            p.containsKey('items')) {
          current.addAll(p);
          changed = true;
        }
      }
      if (current['medicalData'] is Map) {
        final md = Map<String, dynamic>.from(current['medicalData'] as Map);
        md.forEach((k, v) => current.putIfAbsent(k, () => v));
        changed = true;
      }
      if (!changed) break;
    }
    return current;
  }

  @override
  State<PatientHistoryPanel> createState() => _PatientHistoryPanelState();
}

class _PatientHistoryPanelState extends State<PatientHistoryPanel> {
  Color get _teal => context.comfort.brand;

  List<_HistoryEntry> _entries   = [];
  bool                _isLoading = false;
  bool                _showAllEarlier = false;

  // FIX-4: cancellation token — incremented every time a new load starts.
  // The async load captures the token at start; if the token changes by the
  // time it wants to call setState, it knows it has been superseded and bails.
  int _loadToken = 0;

  // The identity of the patient whose data is currently displayed (or loading).
  _PatientIdentity _currentIdentity = const _PatientIdentity(
      patientId: '', cnic: '', guardianCnic: '', name: '', isAdult: true);

  bool _getIsDark(BuildContext context) {
    try {
      if (Hive.isBoxOpen('app_settings')) {
        final dark = Hive.box('app_settings').get('is_dark_mode');
        if (dark != null) return dark == true;
      }
    } catch (_) {}
    return Theme.of(context).brightness == Brightness.dark;
  }

  @override
  void initState() {
    super.initState();
    _kickOffLoad();
  }

  @override
  void didUpdateWidget(covariant PatientHistoryPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    // FIX-2: compare full identity objects, not just a single ID string
    final newIdentity = _PatientIdentity.fromMap(widget.patientData, widget.patientCnic);
    if (newIdentity != _currentIdentity) {
      _kickOffLoad();
    }
  }

  /// FIX-1: Synchronously clears stale data BEFORE starting the async load.
  void _kickOffLoad() {
    final identity = _PatientIdentity.fromMap(widget.patientData, widget.patientCnic);

    // Immediately wipe the old patient's data so it is never shown for the
    // new patient, even for a single frame.
    setState(() {
      _currentIdentity = identity;
      _entries         = [];
      _isLoading       = !identity.isEmpty;
    });

    if (!identity.isEmpty) {
      _loadHistory(identity);
    }
  }

  Future<void> _loadHistory(_PatientIdentity identity) async {
    final token = ++_loadToken;
    debugPrint('[PatientHistory] Loading history for: ${identity.key}');

    final List<_HistoryEntry> found = [];
    final Set<String> seen = {};
    final searchIds = identity.searchIds;

    final todayKey = DateFormat('ddMMyy').format(DateTime.now());
    final todayIso = DateFormat('yyyy-MM-dd').format(DateTime.now());
    final currentSerial = (widget.patientData?['serial'] ?? widget.patientData?['id'])?.toString().trim().toUpperCase();

    bool isTodayVisit(Map<String, dynamic> data, String canonicalSerial) {
      if (currentSerial != null && currentSerial.isNotEmpty && canonicalSerial == currentSerial) {
        return true;
      }
      bool isToday = false;
      final dk = (data['dateKey'] ?? '').toString().trim();
      if (dk == todayKey || canonicalSerial.startsWith(todayKey)) {
        isToday = true;
      } else {
        final parsedDk = CampSessionService.getDateKeyFromSerial(canonicalSerial);
        if (parsedDk == todayKey) isToday = true;
      }
      if (!isToday) {
        final rawTime = data['createdAt'] ?? data['completedAt'] ?? data['timestamp'] ?? data['date'];
        if (rawTime != null) {
          final str = rawTime.toString();
          if (str.startsWith(todayIso)) {
            isToday = true;
          } else {
            final dt = DateTime.tryParse(str);
            if (dt != null) {
              final now = DateTime.now();
              if (dt.year == now.year && dt.month == now.month && dt.day == now.day) {
                isToday = true;
              }
            }
          }
        }
      }

      if (isToday) {
        // Exclude in-progress/waiting tokens from today without medicines
        final unwrapped = PatientHistoryPanel.unwrapPrescriptionData(data);
        final hasMeds = (unwrapped['prescriptions'] is List && (unwrapped['prescriptions'] as List).isNotEmpty) ||
            (unwrapped['medicines'] is List && (unwrapped['medicines'] as List).isNotEmpty);
        final status = (data['status'] ?? '').toString().toLowerCase();
        final isCompleted = status == 'completed' || status == 'dispensed' || data['completedAt'] != null || data['dispensedAt'] != null;
        if (!hasMeds || !isCompleted) {
          return true;
        }
      }
      return false;
    }

    // ── Step 1: Instant Comprehensive Local Hive Scan ─────────────────────────
    void scanLocalBox(String boxName, String sourceLabel) {
      try {
        if (!Hive.isBoxOpen(boxName)) return;
        final box = Hive.box(boxName);
        for (final key in box.keys) {
          final raw = box.get(key);
          if (raw is! Map) continue;

          // Fast shallow filtering: skip non-matching records with ZERO allocations
          bool maybeBelongs = false;
          for (final field in const [
            'patientCnic', 'cnic', 'guardianCnic', 'patientId', 'id',
            'tokenCnic', 'patient_cnic', 'guardian_cnic', 'patient_id'
          ]) {
            final v = raw[field]?.toString().trim() ?? '';
            if (v.isNotEmpty && _IdHelper.matches(v, searchIds)) {
              maybeBelongs = true;
              break;
            }
          }
          if (!maybeBelongs && raw['prescription'] is Map) {
            final p = raw['prescription'] as Map;
            for (final field in const [
              'patientCnic', 'cnic', 'guardianCnic', 'patientId', 'id',
              'tokenCnic', 'patient_cnic', 'guardian_cnic', 'patient_id'
            ]) {
              final v = p[field]?.toString().trim() ?? '';
              if (v.isNotEmpty && _IdHelper.matches(v, searchIds)) {
                maybeBelongs = true;
                break;
              }
            }
          }
          if (!maybeBelongs && raw['data'] is Map) {
            final d = raw['data'] as Map;
            for (final field in const [
              'patientCnic', 'cnic', 'guardianCnic', 'patientId', 'id',
              'tokenCnic', 'patient_cnic', 'guardian_cnic', 'patient_id'
            ]) {
              final v = d[field]?.toString().trim() ?? '';
              if (v.isNotEmpty && _IdHelper.matches(v, searchIds)) {
                maybeBelongs = true;
                break;
              }
            }
          }
          if (!maybeBelongs && identity.name.isNotEmpty && identity.name.length >= 3) {
            final docName = (raw['patientName'] ?? raw['name'] ?? '')
                .toString()
                .trim()
                .toLowerCase()
                .replaceAll(RegExp(r'[^a-z0-9]'), '');
            final myName = identity.name.replaceAll(RegExp(r'[^a-z0-9]'), '');
            if (docName.isNotEmpty && (docName == myName || docName.contains(myName) || myName.contains(docName))) {
              maybeBelongs = true;
            }
          }
          if (!maybeBelongs) {
            final kStr = key.toString().toLowerCase();
            for (final sid in searchIds) {
              if (sid.length >= 4 && kStr.contains(sid.toLowerCase())) {
                maybeBelongs = true;
                break;
              }
            }
          }
          if (!maybeBelongs) continue;

          final data = PatientHistoryPanel.unwrapPrescriptionData(Map<String, dynamic>.from(raw));

          // Must have clinical, prescription, or vitals content
          final hasData = data['medicines'] != null ||
              data['prescriptions'] != null ||
              data['prescription'] != null ||
              data['oralMedicines'] != null ||
              data['injectables'] != null ||
              data['diagnosis'] != null ||
              data['vitals'] != null ||
              data['receptionistVitals'] != null ||
              data['bp'] != null ||
              data['tests'] != null ||
              data['labResults'] != null;
          if (!hasData) continue;

          bool belongs = false;
          for (final field in const [
            'patientCnic', 'cnic', 'guardianCnic', 'patientId', 'id',
            'tokenCnic', 'patient_cnic', 'guardian_cnic', 'patient_id'
          ]) {
            final v = data[field]?.toString().trim() ?? '';
            if (v.isNotEmpty && _IdHelper.matches(v, searchIds)) {
              belongs = true;
              break;
            }
          }

          // Robust fallback: Match by patient name when CNIC is missing or unlinked
          if (!belongs && identity.name.isNotEmpty && identity.name.length >= 3) {
            final docName = (data['patientName'] ?? data['name'] ?? '')
                .toString()
                .trim()
                .toLowerCase()
                .replaceAll(RegExp(r'[^a-z0-9]'), '');
            final myName = identity.name.replaceAll(RegExp(r'[^a-z0-9]'), '');
            if (docName.isNotEmpty && (docName == myName || docName.contains(myName) || myName.contains(docName))) {
              belongs = true;
            }
          }
          if (!belongs || !identity.docBelongsToThisPatient(data)) continue;

          final rawSer = (data['serial'] ?? data['id'] ?? key.toString()).toString().trim();
          final serialMatch = RegExp(r'(\d{6}[A-Za-z]?-[A-Za-z0-9-]+-\d{2,})').firstMatch(rawSer);
          final canonicalSerial = serialMatch != null ? serialMatch.group(1)!.toUpperCase() : rawSer.toUpperCase();
          data['serial'] = canonicalSerial;

          // Today's tokens are part of current consultation, NOT history!
          if (isTodayVisit(data, canonicalSerial)) continue;

          final entry = _HistoryEntry.fromMap(data, source: sourceLabel);
          if (entry != null) {
            final existingIdx = found.indexWhere((e) => e.serial == canonicalSerial);
            if (existingIdx >= 0) {
              // Clinical Priority: Merge data so nothing is lost!
              final existing = found[existingIdx];
              final mergedMeds = List<_MedEntry>.from(existing.medicines);
              for (final m in entry.medicines) {
                if (!mergedMeds.any((x) => x.name.toLowerCase() == m.name.toLowerCase())) {
                  mergedMeds.add(m);
                }
              }
              final mergedDiagnosis = existing.diagnosis.isNotEmpty ? existing.diagnosis : entry.diagnosis;
              final mergedComplaint = existing.complaint.isNotEmpty ? existing.complaint : entry.complaint;
              final mergedDoctor = existing.doctorName.isNotEmpty ? existing.doctorName : entry.doctorName;
              final mergedVitals = {...existing.vitals, ...entry.vitals};
              final mergedLabs = {...existing.labTests, ...entry.labTests}.toList();

              found[existingIdx] = _HistoryEntry(
                serial: canonicalSerial,
                date: existing.date.year > 2000 ? existing.date : entry.date,
                diagnosis: mergedDiagnosis,
                complaint: mergedComplaint,
                doctorName: mergedDoctor,
                medicines: mergedMeds,
                labTests: mergedLabs,
                vitals: mergedVitals,
                raw: {...existing.raw, ...entry.raw},
                source: existing.medicines.isNotEmpty ? existing.source : entry.source,
                days: existing.days > 1 ? existing.days : entry.days,
                campId: existing.campId.isNotEmpty ? existing.campId : entry.campId,
                campName: existing.campName.isNotEmpty ? existing.campName : entry.campName,
                isVitalsOnly: existing.isVitalsOnly && entry.isVitalsOnly,
              );
            } else if (seen.add(canonicalSerial)) {
              found.add(entry);
            }
          }
        }
      } catch (e) {
        debugPrint('[PatientHistory] $boxName scan error: $e');
      }
    }

    // Scan all local Hive caches
    scanLocalBox(LocalStorageService.prescriptionsBox, 'Prescriptions');
    scanLocalBox(LocalStorageService.entriesBox, 'Token History');
    scanLocalBox(LocalStorageService.dispensaryBox, 'Dispensary');
    scanLocalBox(LocalStorageService.reportsCacheBox, 'Reports Cache');

    // Local-First: If local data exists with prescriptions, show immediately
    final hasPrescriptionLocal = found.any((e) => e.medicines.isNotEmpty);
    if (found.isNotEmpty && mounted && _loadToken == token) {
      found.sort((a, b) => b.date.compareTo(a.date));
      setState(() {
        _entries = List.from(found);
        _isLoading = !hasPrescriptionLocal;
      });
      if (hasPrescriptionLocal) return;
    }

    // ── Step 2: One-Time Targeted Remote Fallback (Only if local data empty) ──
    try {
      final allSearchIds = identity.searchIds;
      final prescFutures = allSearchIds.where((id) => id.isNotEmpty).map((id) async {
        try {
          // Query current prescriptions path
          final query = await FirebaseFirestore.instance
              .collection('branches')
              .doc(widget.branchId.toLowerCase())
              .collection('prescriptions')
              .doc(id)
              .collection('prescriptions')
              .orderBy('createdAt', descending: true)
              .limit(15)
              .get()
              .timeout(const Duration(seconds: 6));

          for (final doc in query.docs) {
            if (_loadToken != token) return;
            final data = Map<String, dynamic>.from(doc.data());
            data['serial'] ??= doc.id;
            if (!identity.docBelongsToThisChild(data)) continue;

            final rawSer = (data['serial'] ?? data['id'] ?? doc.id).toString().trim();
            final serialMatch = RegExp(r'(\d{6}[A-Za-z]?-[A-Za-z0-9-]+-\d{2,})').firstMatch(rawSer);
            final canonicalSerial = serialMatch != null ? serialMatch.group(1)!.toUpperCase() : rawSer.toUpperCase();
            data['serial'] = canonicalSerial;

            // Today's tokens are part of current consultation, NOT history!
            if (isTodayVisit(data, canonicalSerial)) continue;

            final entry = _HistoryEntry.fromMap(data, source: 'Prescriptions');
            if (entry != null && seen.add(entry.serial)) {
              found.add(entry);
              // Save to local cache so subsequent loads are 100% local
              try {
                if (Hive.isBoxOpen(LocalStorageService.prescriptionsBox)) {
                  await LocalStorageService.saveLocalPrescription(data);
                }
              } catch (_) {}
            }
          }
        } catch (_) {}
      });

      await Future.wait(prescFutures);
    } catch (e) {
      debugPrint('[PatientHistory] Remote fallback error: $e');
    }

    if (_loadToken != token) return;

    found.sort((a, b) => b.date.compareTo(a.date));
    if (mounted && _loadToken == token) {
      setState(() {
        _entries = found;
        _isLoading = false;
      });
    }
  }

  void _reload() => _kickOffLoad();

  @override
  Widget build(BuildContext context) {
    if (_currentIdentity.isEmpty) {
      return Center(
        child: Text('Select a patient to view history',
            style: TextStyle(color: context.adapt(SoftPalette.gray350), fontSize: 16)),
      );
    }

    final patientName = widget.patientData?['name']?.toString() ??
        widget.patientCnic ?? 'Patient';

    if (widget.compactMode) {
      return _buildCompactLatestVisit(patientName);
    }

    final isDark = _getIsDark(context);
    final tealColor = context.comfort.brand;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
          child: Row(children: [
            Icon(Icons.history, color: tealColor, size: 20),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('History — $patientName',
                      style: TextStyle(
                          fontSize: 16, fontWeight: FontWeight.bold, color: tealColor)),
                  Text(_currentIdentity.key,
                      style: TextStyle(fontSize: 11, color: isDark ? SoftPalette.slate350 : SoftPalette.gray500)),
                ],
              ),
            ),
            IconButton(
              icon: Icon(Icons.refresh, color: tealColor, size: 20),
              tooltip: 'Reload history',
              onPressed: _isLoading ? null : _reload,
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(),
            ),
          ]),
        ),
        Divider(height: 1, color: isDark ? SoftPalette.slate700 : SoftPalette.gray100),
        Expanded(
          child: _isLoading
              ? const PatientHistorySkeleton(count: 3)
              : _entries.isEmpty
                  ? Center(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(Icons.assignment_outlined,
                              size: 56, color: isDark ? SoftPalette.slate600 : SoftPalette.gray150),
                          const SizedBox(height: 12),
                          Text(
                            'No prescription history found\nfor $patientName',
                            textAlign: TextAlign.center,
                            style: TextStyle(
                                color: isDark ? SoftPalette.slate350 : SoftPalette.gray350, fontSize: 14),
                          ),
                        ],
                      ),
                    )
                  : ListView.builder(
                      padding: const EdgeInsets.all(12),
                      itemCount: _entries.length,
                      itemBuilder: (_, i) => _HistoryCard(
                        entry: _entries[i],
                        isLatest: i == 0,
                        onRepeatLast: widget.onRepeatLast,
                      ),
                    ),
        ),
      ],
    );
  }

  Widget _buildCompactLatestVisit(String patientName) {
    final isDark = _getIsDark(context);
    if (_isLoading) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 24),
          child: CircularProgressIndicator(
            color: context.comfort.brand,
            strokeWidth: 2,
          ),
        ),
      );
    }
    if (_entries.isEmpty) {
      return Container(
        padding: const EdgeInsets.symmetric(vertical: 32, horizontal: 16),
        alignment: Alignment.center,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const GEmptyIllustration(
              GEmptyIllustrationKind.activity,
              size: 112,
              fallbackIcon: Icons.history_rounded,
            ),
            const SizedBox(height: 10),
            Text('No visit history yet',
                style: TextStyle(
                  fontSize: 12.5,
                  fontWeight: FontWeight.w600,
                  color: isDark ? SoftPalette.slate350 : SoftPalette.slate600,
                )),
          ],
        ),
      );
    }

    final latestPrescription = _entries.firstWhere(
      (e) => e.medicines.isNotEmpty,
      orElse: () => _entries.first,
    );
    final latestVitals = _entries.firstWhere(
      (e) => e.vitals.isNotEmpty,
      orElse: () => _entries.first,
    );

    final brand = Theme.of(context).colorScheme.primary;
    final muted = isDark ? SoftPalette.slate400 : SoftPalette.slate550;
    final borderColor = isDark ? SoftPalette.slate700 : SoftPalette.slate200;

    // Compute quick summary stats + family link count for the footer card
    final totalVisits = _entries.length;
    final firstVisitStr = DateFormat('d MMM yyyy').format(_entries.last.date);
    final totalMeds = _entries.fold<int>(0, (sum, e) => sum + e.medicines.length);
    final totalLabs = _entries.fold<int>(0, (sum, e) => sum + e.labTests.length);
    final pData = widget.patientData ?? const <String, dynamic>{};
    final gCnic = (pData['guardianCnic'] ?? '').toString().replaceAll(RegExp(r'\D'), '');
    final pCnic = (pData['cnic'] ?? pData['patientCnic'] ?? '').toString().replaceAll(RegExp(r'\D'), '');
    final allLocal = LocalStorageService.getAllLocalPatients();
    final int familyCount = gCnic.isNotEmpty
        ? allLocal.where((p) => (p['guardianCnic'] ?? '').toString().replaceAll(RegExp(r'\D'), '') == gCnic).length
        : (pCnic.length == 13
            ? allLocal.where((p) => (p['guardianCnic'] ?? '').toString().replaceAll(RegExp(r'\D'), '') == pCnic).length
            : 0);

    return LayoutBuilder(builder: (ctx, constraints) {
      return SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(14, 10, 14, 14),
        child: ConstrainedBox(
          constraints: BoxConstraints(
            minHeight: (constraints.maxHeight - 24).clamp(0.0, double.infinity),
          ),
          child: IntrinsicHeight(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _CompactLatestCard(
                  entry: latestPrescription,
                  latestVitalsEntry: (latestPrescription != latestVitals && latestVitals.vitals.isNotEmpty)
                      ? latestVitals
                      : null,
                  onRepeat: widget.onRepeatLast,
                ),
          if (_entries.isNotEmpty) ...[
            const SizedBox(height: 16),
            Builder(builder: (_) {
              final brand = Theme.of(context).colorScheme.primary;
              final canCollapse = _entries.length > 2;
              final hiddenCount = _entries.length - 2;

              Widget buildTimelineNode(_HistoryEntry e, {required bool isFirst, required bool isLast}) {
                final dateStr = DateFormat('d MMM yyyy').format(e.date);
                final titleText = e.diagnosis.isNotEmpty
                    ? e.diagnosis
                    : (e.complaint.isNotEmpty ? e.complaint : 'Consultation');
                final medCount = e.medicines.length;
                return IntrinsicHeight(
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      SizedBox(
                        width: 16,
                        child: Column(
                          children: [
                            const SizedBox(height: 4),
                            Container(
                              width: 7,
                              height: 7,
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                color: isFirst
                                    ? brand
                                    : (isDark ? SoftPalette.slate600 : SoftPalette.slate300),
                              ),
                            ),
                            if (!isLast)
                              Expanded(
                                child: Container(
                                  width: 1.5,
                                  color: isDark
                                      ? SoftPalette.slate700
                                      : SoftPalette.slate200,
                                ),
                              ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Padding(
                          padding: EdgeInsets.only(bottom: isLast ? 0 : 12),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                dateStr,
                                style: TextStyle(
                                  fontSize: 11,
                                  color: isDark ? SoftPalette.slate400 : SoftPalette.slate550,
                                ),
                              ),
                              const SizedBox(height: 2),
                              Text(
                                titleText,
                                style: TextStyle(
                                  fontSize: 12.5,
                                  fontWeight: FontWeight.w700,
                                  color: isDark ? SoftPalette.gray50 : SoftPalette.slate900,
                                ),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                              const SizedBox(height: 1),
                              Text(
                                '$medCount medicine${medCount == 1 ? '' : 's'}',
                                style: TextStyle(
                                  fontSize: 11,
                                  color: isDark ? SoftPalette.slate400 : SoftPalette.slate550,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                );
              }

              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Text(
                        'EARLIER',
                        style: TextStyle(
                          fontSize: 10.5,
                          fontWeight: FontWeight.w700,
                          letterSpacing: 0.7,
                          color: isDark ? SoftPalette.slate400 : SoftPalette.slate550,
                        ),
                      ),
                      const Spacer(),
                      if (canCollapse)
                        InkWell(
                          borderRadius: BorderRadius.circular(5),
                          onTap: () => setState(() => _showAllEarlier = !_showAllEarlier),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                            child: Text(
                              _showAllEarlier ? 'Collapse' : 'Show all (${_entries.length})',
                              style: TextStyle(
                                fontSize: 11,
                                fontWeight: FontWeight.w600,
                                color: brand,
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  if (!canCollapse || _showAllEarlier)
                    ...List.generate(_entries.length, (i) {
                      return buildTimelineNode(
                        _entries[i],
                        isFirst: i == 0,
                        isLast: i == _entries.length - 1,
                      );
                    })
                  else ...[
                    buildTimelineNode(_entries.first, isFirst: true, isLast: false),
                    IntrinsicHeight(
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          SizedBox(
                            width: 16,
                            child: Center(
                              child: Container(
                                width: 1.5,
                                color: isDark ? SoftPalette.slate700 : SoftPalette.slate200,
                              ),
                            ),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Padding(
                              padding: const EdgeInsets.only(bottom: 10),
                              child: InkWell(
                                borderRadius: BorderRadius.circular(7),
                                onTap: () => setState(() => _showAllEarlier = true),
                                child: Container(
                                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                                  decoration: BoxDecoration(
                                    color: brand.withValues(alpha: isDark ? 0.16 : 0.07),
                                    borderRadius: BorderRadius.circular(7),
                                    border: Border.all(color: brand.withValues(alpha: 0.3)),
                                  ),
                                  child: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Icon(Icons.unfold_more_rounded, size: 14, color: brand),
                                      const SizedBox(width: 5),
                                      Text(
                                        '$hiddenCount more visit${hiddenCount == 1 ? '' : 's'}',
                                        style: TextStyle(
                                          fontSize: 11,
                                          fontWeight: FontWeight.w600,
                                          color: isDark ? SoftPalette.gray50 : brand,
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
                    ),
                    buildTimelineNode(_entries.last, isFirst: false, isLast: true),
                  ],
                ],
              );
            }),
          ],
          const Spacer(),
          const SizedBox(height: 14),
          Container(
            padding: const EdgeInsets.all(11),
            decoration: BoxDecoration(
              color: brand.withValues(alpha: isDark ? 0.12 : 0.05),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: borderColor),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(Icons.insights_rounded, size: 14, color: brand),
                    const SizedBox(width: 6),
                    Text(
                      'PATIENT SUMMARY',
                      style: TextStyle(
                        fontSize: 10,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 0.7,
                        color: muted,
                      ),
                    ),
                    const Spacer(),
                    Text(
                      'Since $firstVisitStr',
                      style: TextStyle(fontSize: 10.5, color: muted),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('Visits', style: TextStyle(fontSize: 10.5, color: muted)),
                          const SizedBox(height: 1),
                          Text('$totalVisits',
                              style: TextStyle(
                                fontSize: 14,
                                fontWeight: FontWeight.w800,
                                color: isDark ? SoftPalette.gray50 : SoftPalette.slate900,
                              )),
                        ],
                      ),
                    ),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('Medicines', style: TextStyle(fontSize: 10.5, color: muted)),
                          const SizedBox(height: 1),
                          Text('$totalMeds',
                              style: TextStyle(
                                fontSize: 14,
                                fontWeight: FontWeight.w800,
                                color: isDark ? SoftPalette.gray50 : SoftPalette.slate900,
                              )),
                        ],
                      ),
                    ),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(familyCount > 0 ? 'Family' : 'Labs',
                              style: TextStyle(fontSize: 10.5, color: muted)),
                          const SizedBox(height: 1),
                          Text('${familyCount > 0 ? familyCount : totalLabs}',
                              style: TextStyle(
                                fontSize: 14,
                                fontWeight: FontWeight.w800,
                                color: isDark ? SoftPalette.gray50 : SoftPalette.slate900,
                              )),
                        ],
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
    });
  }
}

// ═══════════════════════════════════════════════════════════════════════════════
// DEDICATED FULL-PAGE HISTORY
// ═══════════════════════════════════════════════════════════════════════════════

class PatientHistoryPage extends StatefulWidget {
  final String branchId;
  final Map<String, dynamic> patientData;
  final void Function(Map<String, dynamic>)? onRepeatLast;

  const PatientHistoryPage({
    super.key,
    required this.branchId,
    required this.patientData,
    this.onRepeatLast,
  });

  @override
  State<PatientHistoryPage> createState() => _PatientHistoryPageState();
}

class _PatientHistoryPageState extends State<PatientHistoryPage> {
  Color get _teal => context.comfort.brand;

  List<_HistoryEntry> _entries   = [];
  bool                _isLoading = true;
  int                 _loadToken = 0;
  bool                _showAllMiddle = false;

  Map<String, dynamic> _profileData = {};
  Map<String, dynamic>? _guardianData;
  List<Map<String, dynamic>> _familyChildren = [];
  List<String> _historicalNames = [];

  void _resolveFamilyAndNames(Map<String, dynamic>? fsPatient, List<_HistoryEntry> entries) {
    final merged = <String, dynamic>{
      ...widget.patientData,
      if (fsPatient != null) ...fsPatient,
    };
    _profileData = merged;

    final currentName = (merged['patientName'] ?? merged['name'] ?? merged['fullName'] ?? '').toString().trim();
    final nameSet = <String>{};
    void addName(dynamic v) {
      final s = (v ?? '').toString().trim();
      if (s.isNotEmpty && s.toLowerCase() != 'unknown' && s.toLowerCase() != 'unknown patient' && s != 'null') {
        nameSet.add(s);
      }
    }
    addName(currentName);
    for (final key in const ['previousNames', 'nameHistory', 'aliases', 'oldNames']) {
      final list = merged[key];
      if (list is List) {
        for (final item in list) {
          if (item is Map) {
            addName(item['name'] ?? item['oldName'] ?? item['value']);
          } else {
            addName(item);
          }
        }
      }
    }
    if (merged['oldName'] != null) addName(merged['oldName']);
    for (final e in entries) {
      addName(e.raw['patientName'] ?? e.raw['name'] ?? e.raw['fullName']);
    }
    _historicalNames = nameSet.toList();

    // Resolve Guardian & Children from local storage
    final allLocal = LocalStorageService.getAllLocalPatients();
    final cnic = (merged['cnic'] ?? merged['patientCnic'] ?? '').toString().replaceAll(RegExp(r'\D'), '');
    final gCnic = (merged['guardianCnic'] ?? '').toString().replaceAll(RegExp(r'\D'), '');
    final isAdult = merged['isAdult'] == true || (gCnic.isEmpty && cnic.length == 13);

    if (isAdult && cnic.isNotEmpty) {
      _guardianData = null;
      _familyChildren = allLocal.where((p) {
        if (p['isAdult'] == true) return false;
        final pg = (p['guardianCnic'] ?? '').toString().replaceAll(RegExp(r'\D'), '');
        return pg == cnic;
      }).toList();
    } else if (gCnic.isNotEmpty) {
      _guardianData = LocalStorageService.getLocalPatientByCnic(
        (merged['guardianCnic'] ?? '').toString(),
      );
      _familyChildren = allLocal.where((p) {
        if (p['isAdult'] == true) return false;
        final pg = (p['guardianCnic'] ?? '').toString().replaceAll(RegExp(r'\D'), '');
        final pId = (p['id'] ?? p['patientId'] ?? '').toString();
        final myId = (merged['id'] ?? merged['patientId'] ?? '').toString();
        return pg == gCnic && (myId.isEmpty || pId != myId);
      }).toList();
    } else {
      _guardianData = null;
      _familyChildren = [];
    }
  }

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final token    = ++_loadToken;
    final identity = _PatientIdentity.fromMap(widget.patientData, null);

    if (mounted) setState(() { _entries = []; _isLoading = true; });

    if (identity.isEmpty) {
      if (mounted) setState(() => _isLoading = false);
      return;
    }

    // Check local patientsBox first to enrich identity without Firestore network delay
    Map<String, dynamic>? fsPatient;
    try {
      if (Hive.isBoxOpen(LocalStorageService.patientsBox)) {
        final pBox = Hive.box(LocalStorageService.patientsBox);
        for (final variant in _IdHelper.variants(
            identity.patientId.isNotEmpty ? identity.patientId : identity.cnic)) {
          if (variant.isEmpty) continue;
          final localP = pBox.get(variant) ?? pBox.get(variant.toLowerCase());
          if (localP is Map) {
            fsPatient = Map<String, dynamic>.from(localP);
            break;
          }
        }
      }
    } catch (_) {}

    final enriched    = _PatientIdentity.fromMap({...widget.patientData, ...?fsPatient}, null);
    final searchIds   = enriched.searchIds;
    final List<_HistoryEntry> found = [];
    final Set<String> seen = {};

    final todayKey = DateFormat('ddMMyy').format(DateTime.now());
    final todayIso = DateFormat('yyyy-MM-dd').format(DateTime.now());
    final currentSerial = (widget.patientData['serial'] ?? widget.patientData['id'])?.toString().trim().toUpperCase();

    bool isTodayVisit(Map<String, dynamic> data, String canonicalSerial) {
      if (currentSerial != null && currentSerial.isNotEmpty && canonicalSerial == currentSerial) {
        return true;
      }
      bool isToday = false;
      final dk = (data['dateKey'] ?? '').toString().trim();
      if (dk == todayKey || canonicalSerial.startsWith(todayKey)) {
        isToday = true;
      } else {
        final parsedDk = CampSessionService.getDateKeyFromSerial(canonicalSerial);
        if (parsedDk == todayKey) isToday = true;
      }
      if (!isToday) {
        final rawTime = data['createdAt'] ?? data['completedAt'] ?? data['timestamp'] ?? data['date'];
        if (rawTime != null) {
          final str = rawTime.toString();
          if (str.startsWith(todayIso)) {
            isToday = true;
          } else {
            final dt = DateTime.tryParse(str);
            if (dt != null) {
              final now = DateTime.now();
              if (dt.year == now.year && dt.month == now.month && dt.day == now.day) {
                isToday = true;
              }
            }
          }
        }
      }

      if (isToday) {
        // Exclude in-progress/waiting tokens from today without medicines
        final unwrapped = PatientHistoryPanel.unwrapPrescriptionData(data);
        final hasMeds = (unwrapped['prescriptions'] is List && (unwrapped['prescriptions'] as List).isNotEmpty) ||
            (unwrapped['medicines'] is List && (unwrapped['medicines'] as List).isNotEmpty);
        final status = (data['status'] ?? '').toString().toLowerCase();
        final isCompleted = status == 'completed' || status == 'dispensed' || data['completedAt'] != null || data['dispensedAt'] != null;
        if (!hasMeds || !isCompleted) {
          return true;
        }
      }
      return false;
    }

    // ── Instant Local Hive Scan (prescriptions, entries, dispensary, reportsCache) ──
    void scanLocalBox(String boxName, String sourceLabel) {
      try {
        if (!Hive.isBoxOpen(boxName)) return;
        final box = Hive.box(boxName);
        for (final key in box.keys) {
          final raw = box.get(key);
          if (raw is! Map) continue;

          // Fast shallow filtering: skip non-matching records with ZERO allocations
          bool maybeBelongs = false;
          for (final field in const [
            'patientCnic', 'cnic', 'guardianCnic', 'patientId', 'id',
            'tokenCnic', 'patient_cnic', 'guardian_cnic', 'patient_id'
          ]) {
            final v = raw[field]?.toString().trim() ?? '';
            if (v.isNotEmpty && _IdHelper.matches(v, searchIds)) {
              maybeBelongs = true;
              break;
            }
          }
          if (!maybeBelongs && raw['prescription'] is Map) {
            final p = raw['prescription'] as Map;
            for (final field in const [
              'patientCnic', 'cnic', 'guardianCnic', 'patientId', 'id',
              'tokenCnic', 'patient_cnic', 'guardian_cnic', 'patient_id'
            ]) {
              final v = p[field]?.toString().trim() ?? '';
              if (v.isNotEmpty && _IdHelper.matches(v, searchIds)) {
                maybeBelongs = true;
                break;
              }
            }
          }
          if (!maybeBelongs && raw['data'] is Map) {
            final d = raw['data'] as Map;
            for (final field in const [
              'patientCnic', 'cnic', 'guardianCnic', 'patientId', 'id',
              'tokenCnic', 'patient_cnic', 'guardian_cnic', 'patient_id'
            ]) {
              final v = d[field]?.toString().trim() ?? '';
              if (v.isNotEmpty && _IdHelper.matches(v, searchIds)) {
                maybeBelongs = true;
                break;
              }
            }
          }
          if (!maybeBelongs && enriched.name.isNotEmpty && enriched.name.length >= 3) {
            final docName = (raw['patientName'] ?? raw['name'] ?? '')
                .toString()
                .trim()
                .toLowerCase()
                .replaceAll(RegExp(r'[^a-z0-9]'), '');
            final myName = enriched.name.replaceAll(RegExp(r'[^a-z0-9]'), '');
            if (docName.isNotEmpty && (docName == myName || docName.contains(myName) || myName.contains(docName))) {
              maybeBelongs = true;
            }
          }
          if (!maybeBelongs) {
            final kStr = key.toString().toLowerCase();
            for (final sid in searchIds) {
              if (sid.length >= 4 && kStr.contains(sid.toLowerCase())) {
                maybeBelongs = true;
                break;
              }
            }
          }
          if (!maybeBelongs) continue;

          final data = PatientHistoryPanel.unwrapPrescriptionData(Map<String, dynamic>.from(raw));

          final hasData = data['medicines'] != null ||
              data['prescriptions'] != null ||
              data['prescription'] != null ||
              data['oralMedicines'] != null ||
              data['injectables'] != null ||
              data['diagnosis'] != null ||
              data['vitals'] != null ||
              data['receptionistVitals'] != null ||
              data['bp'] != null ||
              data['tests'] != null ||
              data['labResults'] != null;
          if (!hasData) continue;

          bool belongs = false;
          for (final field in const [
            'patientCnic', 'cnic', 'guardianCnic', 'patientId', 'id',
            'tokenCnic', 'patient_cnic', 'guardian_cnic', 'patient_id'
          ]) {
            final v = data[field]?.toString().trim() ?? '';
            if (v.isNotEmpty && _IdHelper.matches(v, searchIds)) { belongs = true; break; }
          }

          // Robust fallback: Match by patient name when CNIC is missing or unlinked
          if (!belongs && enriched.name.isNotEmpty && enriched.name.length >= 3) {
            final docName = (data['patientName'] ?? data['name'] ?? '')
                .toString()
                .trim()
                .toLowerCase()
                .replaceAll(RegExp(r'[^a-z0-9]'), '');
            final myName = enriched.name.replaceAll(RegExp(r'[^a-z0-9]'), '');
            if (docName.isNotEmpty && (docName == myName || docName.contains(myName) || myName.contains(docName))) {
              belongs = true;
            }
          }
          if (!belongs || !enriched.docBelongsToThisChild(data)) continue;

          final rawSer = (data['serial'] ?? data['id'] ?? key.toString()).toString().trim();
          final serialMatch = RegExp(r'(\d{6}[A-Za-z]?-[A-Za-z0-9-]+-\d{2,})').firstMatch(rawSer);
          final canonicalSerial = serialMatch != null ? serialMatch.group(1)!.toUpperCase() : rawSer.toUpperCase();
          data['serial'] = canonicalSerial;

          // Today's tokens are part of current consultation, NOT history!
          if (isTodayVisit(data, canonicalSerial)) continue;

          final entry = _HistoryEntry.fromMap(data, source: sourceLabel);
          if (entry != null) {
            final existingIdx = found.indexWhere((e) => e.serial == canonicalSerial);
            if (existingIdx >= 0) {
              // Clinical Priority: Merge data so nothing is lost!
              final existing = found[existingIdx];
              final mergedMeds = List<_MedEntry>.from(existing.medicines);
              for (final m in entry.medicines) {
                if (!mergedMeds.any((x) => x.name.toLowerCase() == m.name.toLowerCase())) {
                  mergedMeds.add(m);
                }
              }
              final mergedDiagnosis = existing.diagnosis.isNotEmpty ? existing.diagnosis : entry.diagnosis;
              final mergedComplaint = existing.complaint.isNotEmpty ? existing.complaint : entry.complaint;
              final mergedDoctor = existing.doctorName.isNotEmpty ? existing.doctorName : entry.doctorName;
              final mergedVitals = {...existing.vitals, ...entry.vitals};
              final mergedLabs = {...existing.labTests, ...entry.labTests}.toList();

              found[existingIdx] = _HistoryEntry(
                serial: canonicalSerial,
                date: existing.date.year > 2000 ? existing.date : entry.date,
                diagnosis: mergedDiagnosis,
                complaint: mergedComplaint,
                doctorName: mergedDoctor,
                medicines: mergedMeds,
                labTests: mergedLabs,
                vitals: mergedVitals,
                raw: {...existing.raw, ...entry.raw},
                source: existing.medicines.isNotEmpty ? existing.source : entry.source,
                days: existing.days > 1 ? existing.days : entry.days,
                campId: existing.campId.isNotEmpty ? existing.campId : entry.campId,
                campName: existing.campName.isNotEmpty ? existing.campName : entry.campName,
                isVitalsOnly: existing.isVitalsOnly && entry.isVitalsOnly,
              );
            } else if (seen.add(canonicalSerial)) {
              found.add(entry);
            }
          }
        }
      } catch (e) {
        debugPrint('[PatientHistoryPage] $boxName scan error: $e');
      }
    }

    scanLocalBox(LocalStorageService.prescriptionsBox, 'Prescriptions');
    scanLocalBox(LocalStorageService.entriesBox, 'Token History');
    scanLocalBox(LocalStorageService.dispensaryBox, 'Dispensary');
    scanLocalBox(LocalStorageService.reportsCacheBox, 'Reports Cache');

    // 100% Local-First: If local records exist with medicines, render immediately and return!
    final hasPrescriptionLocal = found.any((e) => e.medicines.isNotEmpty);
    if (found.isNotEmpty && mounted && _loadToken == token) {
      found.sort((a, b) => b.date.compareTo(a.date));
      _resolveFamilyAndNames(fsPatient, found);
      setState(() { _entries = List.from(found); _isLoading = !hasPrescriptionLocal; });
      if (hasPrescriptionLocal) return;
    }

    if (_loadToken != token) return;

    // Remote fallback: Only executed if zero local records were found
    try {
      final prescFutures = searchIds.where((id) => id.isNotEmpty).map((id) async {
        try {
          final query = await FirebaseFirestore.instance
              .collection('branches')
              .doc(widget.branchId.toLowerCase())
              .collection('prescriptions')
              .doc(id)
              .collection('prescriptions')
              .orderBy('createdAt', descending: true)
              .limit(15)
              .get()
              .timeout(const Duration(seconds: 4));
          for (final doc in query.docs) {
            if (_loadToken != token) return;
            final data = Map<String, dynamic>.from(doc.data());
            data['serial'] ??= doc.id;
            if (!enriched.docBelongsToThisChild(data)) continue;

            final rawSer = (data['serial'] ?? data['id'] ?? doc.id).toString().trim();
            final serialMatch = RegExp(r'(\d{6}[A-Za-z]?-[A-Za-z0-9-]+-\d{2,})').firstMatch(rawSer);
            final canonicalSerial = serialMatch != null ? serialMatch.group(1)!.toUpperCase() : rawSer.toUpperCase();
            data['serial'] = canonicalSerial;

            // Today's tokens are part of current consultation, NOT history!
            if (isTodayVisit(data, canonicalSerial)) continue;

            final entry = _HistoryEntry.fromMap(data, source: 'Prescriptions');
            if (entry != null && seen.add(entry.serial)) {
              found.add(entry);
              try {
                if (Hive.isBoxOpen(LocalStorageService.reportsCacheBox)) {
                  Hive.box(LocalStorageService.reportsCacheBox).put('legacy_${id}_${entry.serial}', data);
                }
              } catch (_) {}
            }
          }
        } catch (e) { debugPrint('[PatientHistoryPage] $id error: $e'); }
      });
      await Future.wait(prescFutures);
    } catch (e) {
      debugPrint('[PatientHistoryPage] Remote fallback error: $e');
    }

    if (_loadToken != token) return;

    found.sort((a, b) => b.date.compareTo(a.date));
    if (mounted && _loadToken == token) {
      _resolveFamilyAndNames(fsPatient, found);
      setState(() { _entries = found; _isLoading = false; });
    }
  }

  Widget _buildSidebarCard({
    required bool isDark,
    required Color brand,
    required Color borderColor,
    required IconData icon,
    required String title,
    required List<Widget> children,
    Widget? trailing,
  }) {
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      decoration: BoxDecoration(
        color: Theme.of(context).cardColor,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: borderColor),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 12, 12, 10),
            child: Row(
              children: [
                Container(
                  width: 26,
                  height: 26,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: brand.withValues(alpha: isDark ? 0.22 : 0.1),
                    borderRadius: BorderRadius.circular(7),
                  ),
                  child: Icon(icon, size: 15, color: brand),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    title,
                    style: TextStyle(
                      fontSize: 13.5,
                      fontWeight: FontWeight.w800,
                      color: isDark ? SoftPalette.gray50 : SoftPalette.slate900,
                    ),
                  ),
                ),
                if (trailing != null) trailing,
              ],
            ),
          ),
          Divider(height: 1, color: borderColor),
          Padding(
            padding: const EdgeInsets.all(14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: children,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPatientSidebar(bool isDark, Color brand, Color muted, Color borderColor) {
    final p = _profileData.isNotEmpty ? _profileData : widget.patientData;
    final pName = (p['patientName'] ?? p['name'] ?? p['fullName'] ?? 'Patient').toString().trim();
    final age = (p['age'] ?? p['vitals']?['age'] ?? '').toString().trim();
    final gender = (p['gender'] ?? p['vitals']?['gender'] ?? '').toString().trim();
    final blood = (p['bloodGroup'] ?? p['vitals']?['bloodGroup'] ?? '').toString().trim();
    final cnic = (p['cnic'] ?? p['patientCnic'] ?? '').toString().trim();
    final gCnic = (p['guardianCnic'] ?? '').toString().trim();
    final phone = (p['phone'] ?? p['contact'] ?? p['mobile'] ?? '').toString().trim();
    final address = (p['address'] ?? p['city'] ?? p['village'] ?? '').toString().trim();
    final mr = (p['mrNumber'] ?? p['patientId'] ?? p['id'] ?? '').toString().trim();
    final rawQt = (p['queueType'] ?? 'zakat').toString().toUpperCase();
    final qtLabel = rawQt.contains('NON') ? 'NON-ZAKAT' : (rawQt.contains('GMWF') ? 'GMWF' : 'ZAKAT');
    final staffInfo = StaffPatientLinkService.getStaffInfoFromPatientMap(p);

    Widget infoRow(IconData icon, String label, String value) {
      return Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, size: 14, color: muted),
            const SizedBox(width: 8),
            SizedBox(
              width: 84,
              child: Text(label, style: TextStyle(fontSize: 11.5, color: muted)),
            ),
            Expanded(
              child: Text(
                value,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: isDark ? SoftPalette.gray50 : SoftPalette.slate900,
                ),
              ),
            ),
          ],
        ),
      );
    }

    Widget treeNode({
      required String title,
      required String subtitle,
      required IconData icon,
      required bool isCurrent,
      bool isRoot = false,
      bool isLast = false,
    }) {
      return IntrinsicHeight(
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (!isRoot)
              SizedBox(
                width: 22,
                child: Column(
                  children: [
                    Container(
                      width: 1.5,
                      height: 14,
                      color: isDark ? SoftPalette.slate600 : SoftPalette.slate300,
                    ),
                    Row(
                      children: [
                        const SizedBox(width: 10),
                        Container(
                          width: 11,
                          height: 1.5,
                          color: isDark ? SoftPalette.slate600 : SoftPalette.slate300,
                        ),
                      ],
                    ),
                    if (!isLast)
                      Expanded(
                        child: Container(
                          width: 1.5,
                          color: isDark ? SoftPalette.slate600 : SoftPalette.slate300,
                        ),
                      ),
                  ],
                ),
              ),
            Expanded(
              child: Container(
                margin: EdgeInsets.only(bottom: isLast ? 0 : 8),
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                decoration: BoxDecoration(
                  color: isCurrent
                      ? brand.withValues(alpha: isDark ? 0.18 : 0.08)
                      : (isDark ? SoftPalette.slate900.withValues(alpha: 0.6) : SoftPalette.slate50),
                  borderRadius: BorderRadius.circular(9),
                  border: Border.all(
                    color: isCurrent ? brand.withValues(alpha: 0.55) : borderColor,
                  ),
                ),
                child: Row(
                  children: [
                    Icon(icon, size: 15, color: isCurrent ? brand : muted),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            title,
                            style: TextStyle(
                              fontSize: 12.5,
                              fontWeight: isCurrent ? FontWeight.w700 : FontWeight.w600,
                              color: isDark ? SoftPalette.gray50 : SoftPalette.slate900,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          if (subtitle.isNotEmpty)
                            Text(
                              subtitle,
                              style: TextStyle(fontSize: 11, color: muted),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                        ],
                      ),
                    ),
                    if (isCurrent)
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                        decoration: BoxDecoration(
                          color: brand,
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: const Text(
                          'CURRENT',
                          style: TextStyle(fontSize: 8.5, fontWeight: FontWeight.w800, color: SoftPalette.gray50),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ],
        ),
      );
    }

    final hasRenames = _historicalNames.length > 1;
    final hasGuardian = _guardianData != null || gCnic.isNotEmpty;
    final hasChildren = _familyChildren.isNotEmpty;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // 1. Patient Profile Card
        _buildSidebarCard(
          isDark: isDark,
          brand: brand,
          borderColor: borderColor,
          icon: Icons.person_outline_rounded,
          title: 'Patient Profile',
          trailing: Container(
            padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
            decoration: BoxDecoration(
              color: brand.withValues(alpha: isDark ? 0.25 : 0.12),
              borderRadius: BorderRadius.circular(5),
            ),
            child: Text(
              qtLabel,
              style: TextStyle(fontSize: 9.5, fontWeight: FontWeight.w800, color: isDark ? SoftPalette.gray50 : brand),
            ),
          ),
          children: [
            Row(
              children: [
                CircleAvatar(
                  radius: 20,
                  backgroundColor: brand.withValues(alpha: isDark ? 0.25 : 0.12),
                  child: Text(
                    pName.isNotEmpty ? pName[0].toUpperCase() : 'P',
                    style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800, color: isDark ? SoftPalette.gray50 : brand),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        pName,
                        style: TextStyle(
                          fontSize: 14.5,
                          fontWeight: FontWeight.w800,
                          color: isDark ? SoftPalette.gray50 : SoftPalette.slate900,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        [
                          if (age.isNotEmpty) '$age yrs',
                          if (gender.isNotEmpty) gender,
                          if (blood.isNotEmpty) 'Blood $blood',
                        ].join(' · '),
                        style: TextStyle(fontSize: 11.5, color: muted),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            if (staffInfo != null) ...[
              const SizedBox(height: 10),
              StaffPatientLinkService.buildStaffBadge(staffInfo, isDark: isDark),
            ],
            const SizedBox(height: 12),
            if (mr.isNotEmpty) infoRow(Icons.badge_outlined, 'Patient ID', mr),
            if (cnic.isNotEmpty) infoRow(Icons.credit_card_outlined, 'CNIC', cnic),
            if (gCnic.isNotEmpty && gCnic != cnic) infoRow(Icons.shield_outlined, 'Guardian CNIC', gCnic),
            if (phone.isNotEmpty) infoRow(Icons.phone_outlined, 'Phone', phone),
            if (address.isNotEmpty) infoRow(Icons.location_on_outlined, 'Address', address),
            infoRow(Icons.history_rounded, 'Total Visits', '${_entries.length}'),
          ],
        ),

        // 2. Name History / Renames Card
        if (hasRenames)
          _buildSidebarCard(
            isDark: isDark,
            brand: brand,
            borderColor: borderColor,
            icon: Icons.drive_file_rename_outline_rounded,
            title: 'Name History / Renames',
            children: _historicalNames.asMap().entries.map((entry) {
              final isCurrent = entry.value.toLowerCase() == pName.toLowerCase();
              return Padding(
                padding: EdgeInsets.only(bottom: entry.key == _historicalNames.length - 1 ? 0 : 6),
                child: Row(
                  children: [
                    Icon(
                      isCurrent ? Icons.check_circle_rounded : Icons.history_rounded,
                      size: 14,
                      color: isCurrent ? brand : muted,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        entry.value,
                        style: TextStyle(
                          fontSize: 12.5,
                          fontWeight: isCurrent ? FontWeight.w700 : FontWeight.w500,
                          color: isDark ? SoftPalette.gray50 : SoftPalette.slate900,
                        ),
                      ),
                    ),
                    if (isCurrent)
                      Text('Current', style: TextStyle(fontSize: 10.5, fontWeight: FontWeight.w600, color: brand))
                    else
                      Text('Previous', style: TextStyle(fontSize: 10.5, color: muted)),
                  ],
                ),
              );
            }).toList(),
          ),

        // 3. Family Tree Card
        _buildSidebarCard(
          isDark: isDark,
          brand: brand,
          borderColor: borderColor,
          icon: Icons.account_tree_outlined,
          title: 'Family Tree',
          children: [
            if (!hasGuardian && !hasChildren)
              Text(
                'No linked guardian or dependents found in local records.',
                style: TextStyle(fontSize: 12, color: muted),
              )
            else if (hasGuardian) ...[
              treeNode(
                title: (_guardianData?['name'] ?? 'Guardian').toString(),
                subtitle: [
                  if (_guardianData?['age'] != null) '${_guardianData!['age']} yrs',
                  if (_guardianData?['gender'] != null) _guardianData!['gender'].toString(),
                  if (gCnic.isNotEmpty) 'CNIC $gCnic',
                ].join(' · '),
                icon: Icons.shield_outlined,
                isCurrent: false,
                isRoot: true,
              ),
              treeNode(
                title: pName,
                subtitle: [if (age.isNotEmpty) '$age yrs', if (gender.isNotEmpty) gender].join(' · '),
                icon: Icons.person_rounded,
                isCurrent: true,
                isLast: _familyChildren.isEmpty,
              ),
              ...List.generate(_familyChildren.length, (i) {
                final c = _familyChildren[i];
                return treeNode(
                  title: (c['name'] ?? 'Dependent').toString(),
                  subtitle: [
                    if (c['age'] != null) '${c['age']} yrs',
                    if (c['gender'] != null) c['gender'].toString(),
                  ].join(' · '),
                  icon: Icons.child_care_rounded,
                  isCurrent: false,
                  isLast: i == _familyChildren.length - 1,
                );
              }),
            ] else ...[
              treeNode(
                title: pName,
                subtitle: [
                  if (age.isNotEmpty) '$age yrs',
                  if (gender.isNotEmpty) gender,
                  'Head / Guardian',
                ].join(' · '),
                icon: Icons.person_rounded,
                isCurrent: true,
                isRoot: true,
              ),
              ...List.generate(_familyChildren.length, (i) {
                final c = _familyChildren[i];
                return treeNode(
                  title: (c['name'] ?? 'Dependent').toString(),
                  subtitle: [
                    if (c['age'] != null) '${c['age']} yrs',
                    if (c['gender'] != null) c['gender'].toString(),
                  ].join(' · '),
                  icon: Icons.child_care_rounded,
                  isCurrent: false,
                  isLast: i == _familyChildren.length - 1,
                );
              }),
            ],
          ],
        ),

        // 4. Branches & Doctors Visited Card
        if (_entries.isNotEmpty)
          Builder(builder: (_) {
            final branchCounts = <String, int>{};
            final doctorCounts = <String, int>{};
            for (final e in _entries) {
              final rawB = (e.raw['branchName'] ?? e.raw['branchId'] ?? widget.branchId).toString().trim();
              final bLabel = rawB.isNotEmpty
                  ? (LocalStorageService.getBranchName(rawB) ?? rawB)
                  : LocalStorageService.getBranchName(widget.branchId) ?? widget.branchId;
              final campPart = e.campName.isNotEmpty && e.campName.toLowerCase() != bLabel.toLowerCase()
                  ? '$bLabel · ${e.campName}'
                  : bLabel;
              branchCounts[campPart] = (branchCounts[campPart] ?? 0) + 1;

              final doc = e.doctorName.trim();
              if (doc.isNotEmpty) {
                final cleanDoc = doc.toLowerCase().startsWith('dr') ? doc : 'Dr. $doc';
                doctorCounts[cleanDoc] = (doctorCounts[cleanDoc] ?? 0) + 1;
              }
            }

            return _buildSidebarCard(
              isDark: isDark,
              brand: brand,
              borderColor: borderColor,
              icon: Icons.local_hospital_outlined,
              title: 'Branches & Doctors',
              children: [
                Text(
                  'BRANCHES / CAMPS',
                  style: TextStyle(fontSize: 10, fontWeight: FontWeight.w700, letterSpacing: 0.6, color: muted),
                ),
                const SizedBox(height: 6),
                ...branchCounts.entries.map((kv) => Padding(
                      padding: const EdgeInsets.only(bottom: 5),
                      child: Row(
                        children: [
                          Icon(Icons.location_on_outlined, size: 13, color: brand),
                          const SizedBox(width: 6),
                          Expanded(
                            child: Text(
                              kv.key,
                              style: TextStyle(
                                fontSize: 12,
                                fontWeight: FontWeight.w600,
                                color: isDark ? SoftPalette.gray50 : SoftPalette.slate900,
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          Text(
                            '${kv.value} visit${kv.value == 1 ? '' : 's'}',
                            style: TextStyle(fontSize: 11, color: muted),
                          ),
                        ],
                      ),
                    )),
                if (doctorCounts.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  Text(
                    'DOCTORS CONSULTED',
                    style: TextStyle(fontSize: 10, fontWeight: FontWeight.w700, letterSpacing: 0.6, color: muted),
                  ),
                  const SizedBox(height: 6),
                  ...doctorCounts.entries.map((kv) => Padding(
                        padding: const EdgeInsets.only(bottom: 5),
                        child: Row(
                          children: [
                            Icon(Icons.medical_services_outlined, size: 13, color: brand),
                            const SizedBox(width: 6),
                            Expanded(
                              child: Text(
                                kv.key,
                                style: TextStyle(
                                  fontSize: 12,
                                  fontWeight: FontWeight.w600,
                                  color: isDark ? SoftPalette.gray50 : SoftPalette.slate900,
                                ),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                            Text(
                              '${kv.value} visit${kv.value == 1 ? '' : 's'}',
                              style: TextStyle(fontSize: 11, color: muted),
                            ),
                          ],
                        ),
                      )),
                ],
              ],
            );
          }),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final name = widget.patientData['name']?.toString() ?? 'Patient';
    final id   = _PatientIdentity.fromMap(widget.patientData, null).key;

    final isDark = Theme.of(context).brightness == Brightness.dark ||
        (Hive.isBoxOpen('app_settings') && Hive.box('app_settings').get('is_dark_mode', defaultValue: false) == true);
    final brand = Theme.of(context).colorScheme.primary;
    final muted = isDark ? SoftPalette.slate400 : SoftPalette.slate550;
    final borderColor = isDark ? SoftPalette.slate700 : SoftPalette.slate200;

    return Scaffold(
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      appBar: AppBar(
        backgroundColor: Theme.of(context).cardColor,
        foregroundColor: isDark ? SoftPalette.gray50 : SoftPalette.slate900,
        elevation: 0,
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(1),
          child: Divider(height: 1, color: borderColor),
        ),
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text(name, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w800)),
                Builder(builder: (_) {
                  final staffInfo = StaffPatientLinkService.getStaffInfoFromPatientMap(widget.patientData);
                  if (staffInfo != null) {
                    return Padding(
                      padding: const EdgeInsets.only(left: 8),
                      child: StaffPatientLinkService.buildStaffBadge(staffInfo, isDark: isDark),
                    );
                  }
                  return const SizedBox.shrink();
                }),
              ],
            ),
            Text(id, style: TextStyle(fontSize: 11.5, color: muted)),
          ],
        ),
        actions: [
          if (!_isLoading && _entries.isNotEmpty)
            Center(
              child: Container(
                margin: const EdgeInsets.only(right: 6),
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                decoration: BoxDecoration(
                  color: brand.withValues(alpha: isDark ? 0.22 : 0.1),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: brand.withValues(alpha: 0.35)),
                ),
                child: Text(
                  '${_entries.length} visit${_entries.length == 1 ? '' : 's'}',
                  style: TextStyle(
                    fontSize: 11.5,
                    fontWeight: FontWeight.w700,
                    color: isDark ? SoftPalette.gray50 : brand,
                  ),
                ),
              ),
            ),
          IconButton(
            icon: _isLoading
                ? SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(color: brand, strokeWidth: 2))
                : Icon(Icons.refresh_rounded, color: brand),
            onPressed: _isLoading ? null : _load,
          ),
        ],
      ),
      body: _isLoading
          ? Center(child: CircularProgressIndicator(color: brand))
          : _entries.isEmpty
              ? Center(child: Column(mainAxisSize: MainAxisSize.min, children: [
                  const GEmptyIllustration(
                    GEmptyIllustrationKind.activity,
                    size: 140,
                    fallbackIcon: Icons.history_rounded,
                  ),
                  const SizedBox(height: 14),
                  Text('No visit history found for $name',
                      style: TextStyle(color: muted, fontSize: 14, fontWeight: FontWeight.w600),
                      textAlign: TextAlign.center),
                ]))
              : Builder(builder: (_) {
                  final canCollapseMiddle = _entries.length > 2;
                  final hiddenCount = _entries.length - 2;
                  final onRep = widget.onRepeatLast != null
                      ? (Map<String, dynamic> raw) {
                          widget.onRepeatLast!(raw);
                          Navigator.pop(context);
                        }
                      : null;

                  final items = <Widget>[];
                  if (!canCollapseMiddle || _showAllMiddle) {
                    for (int i = 0; i < _entries.length; i++) {
                      items.add(_HistoryCard(
                        entry: _entries[i],
                        isLatest: i == 0,
                        isOldest: i == _entries.length - 1 && _entries.length > 1,
                        initiallyExpanded: i == 0 || i == _entries.length - 1,
                        onRepeatLast: onRep,
                      ));
                    }
                    if (canCollapseMiddle) {
                      items.insert(
                        1,
                        Padding(
                          padding: const EdgeInsets.only(bottom: 10),
                          child: InkWell(
                            borderRadius: BorderRadius.circular(10),
                            onTap: () => setState(() => _showAllMiddle = false),
                            child: Container(
                              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
                              decoration: BoxDecoration(
                                color: brand.withValues(alpha: isDark ? 0.16 : 0.07),
                                borderRadius: BorderRadius.circular(10),
                                border: Border.all(color: brand.withValues(alpha: 0.3)),
                              ),
                              child: Row(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  Icon(Icons.unfold_less_rounded, size: 16, color: brand),
                                  const SizedBox(width: 6),
                                  Text(
                                    'Collapse $hiddenCount middle visit${hiddenCount == 1 ? '' : 's'} (show latest & oldest)',
                                    style: TextStyle(
                                      fontSize: 12,
                                      fontWeight: FontWeight.w600,
                                      color: isDark ? SoftPalette.gray50 : brand,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                      );
                    }
                  } else {
                    items.add(_HistoryCard(
                      entry: _entries.first,
                      isLatest: true,
                      initiallyExpanded: true,
                      onRepeatLast: onRep,
                    ));
                    items.add(
                      Padding(
                        padding: const EdgeInsets.only(bottom: 10),
                        child: InkWell(
                          borderRadius: BorderRadius.circular(10),
                          onTap: () => setState(() => _showAllMiddle = true),
                          child: Container(
                            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                            decoration: BoxDecoration(
                              color: brand.withValues(alpha: isDark ? 0.16 : 0.07),
                              borderRadius: BorderRadius.circular(10),
                              border: Border.all(color: brand.withValues(alpha: 0.3)),
                            ),
                            child: Row(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                Icon(Icons.unfold_more_rounded, size: 16, color: brand),
                                const SizedBox(width: 6),
                                Text(
                                  'Show $hiddenCount earlier visit${hiddenCount == 1 ? '' : 's'}',
                                  style: TextStyle(
                                    fontSize: 12,
                                    fontWeight: FontWeight.w700,
                                    color: isDark ? SoftPalette.gray50 : brand,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    );
                    items.add(_HistoryCard(
                      entry: _entries.last,
                      isOldest: true,
                      initiallyExpanded: true,
                      onRepeatLast: onRep,
                    ));
                  }

                  return LayoutBuilder(builder: (ctx, constraints) {
                    if (constraints.maxWidth >= 900) {
                      return Padding(
                        padding: const EdgeInsets.all(14),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Expanded(
                              flex: 32,
                              child: SingleChildScrollView(
                                child: _buildPatientSidebar(isDark, brand, muted, borderColor),
                              ),
                            ),
                            const SizedBox(width: 14),
                            Expanded(
                              flex: 68,
                              child: ListView(
                                children: items,
                              ),
                            ),
                          ],
                        ),
                      );
                    }
                    return ListView(
                      padding: const EdgeInsets.all(14),
                      children: [
                        _buildPatientSidebar(isDark, brand, muted, borderColor),
                        ...items,
                      ],
                    );
                  });
                }),
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════════════
// COMPACT LATEST CARD  (unchanged UI, just wired to fixed data)
// ═══════════════════════════════════════════════════════════════════════════════

class _CompactLatestCard extends StatelessWidget {
  final _HistoryEntry entry;
  final _HistoryEntry? latestVitalsEntry;
  final void Function(Map<String, dynamic>)? onRepeat;

  const _CompactLatestCard({
    required this.entry,
    this.latestVitalsEntry,
    this.onRepeat,
  });

  bool _getIsDark(BuildContext context) {
    try {
      if (Hive.isBoxOpen('app_settings')) {
        final dark = Hive.box('app_settings').get('is_dark_mode');
        if (dark != null) return dark == true;
      }
    } catch (_) {}
    return Theme.of(context).brightness == Brightness.dark;
  }

  @override
  Widget build(BuildContext context) {
    final isDark = _getIsDark(context);
    final e = entry;
    final dateStr = DateFormat('d MMM yyyy').format(e.date);
    final docStr = e.doctorName.isNotEmpty
        ? (e.doctorName.toLowerCase().startsWith('dr') ? e.doctorName : 'Dr. ${e.doctorName}')
        : '';
    final vitalsMap = latestVitalsEntry?.vitals ?? e.vitals;
    final allMeds = e.medicines;

    Widget kvRow(String label, String value, {bool boldValue = false}) {
      return Padding(
        padding: const EdgeInsets.only(bottom: 5),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: 68,
              child: Text(
                label,
                style: TextStyle(
                  fontSize: 11.5,
                  color: isDark ? SoftPalette.slate400 : SoftPalette.slate550,
                ),
              ),
            ),
            Expanded(
              child: Text(
                value,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: boldValue ? FontWeight.w700 : FontWeight.w500,
                  color: isDark ? SoftPalette.gray50 : SoftPalette.slate900,
                ),
              ),
            ),
          ],
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // ── Header: LAST VISIT  |  2 Nov 2026 · Dr. Asif ──
        Row(
          children: [
            Text(
              'LAST VISIT',
              style: TextStyle(
                fontSize: 10.5,
                fontWeight: FontWeight.w700,
                letterSpacing: 0.7,
                color: isDark ? SoftPalette.slate400 : SoftPalette.slate550,
              ),
            ),
            const Spacer(),
            Text(
              docStr.isNotEmpty ? '$dateStr · $docStr' : dateStr,
              style: TextStyle(
                fontSize: 11,
                color: isDark ? SoftPalette.slate350 : SoftPalette.slate550,
              ),
            ),
          ],
        ),
        const SizedBox(height: 10),

        // ── Condition, Diagnosis, Vitals ──
        if (e.complaint.isNotEmpty) kvRow('Condition', e.complaint),
        if (e.diagnosis.isNotEmpty) kvRow('Diagnosis', e.diagnosis, boldValue: true),
        if (vitalsMap.isNotEmpty) ...[
          Padding(
            padding: const EdgeInsets.only(top: 2, bottom: 8),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(
                  width: 68,
                  child: Padding(
                    padding: const EdgeInsets.only(top: 3),
                    child: Text(
                      'Vitals',
                      style: TextStyle(
                        fontSize: 11.5,
                        color: isDark ? SoftPalette.slate400 : SoftPalette.slate550,
                      ),
                    ),
                  ),
                ),
                Expanded(
                  child: _buildCompactVitalsDisplay(vitalsMap, isDark),
                ),
              ],
            ),
          ),
        ],

        // ── Medicines List ──
        if (allMeds.isNotEmpty) ...[
          const SizedBox(height: 2),
          ...allMeds.map((m) => _medTile(m, isInj: m.isInjectable, isDark: isDark)),
        ] else ...[
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            decoration: BoxDecoration(
              color: isDark ? SoftPalette.slate900 : SoftPalette.slate100,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: isDark ? SoftPalette.slate700 : SoftPalette.slate200),
            ),
            child: Text(
              'No medicines prescribed in this visit',
              style: TextStyle(fontSize: 11.5, color: isDark ? SoftPalette.slate400 : SoftPalette.gray500),
            ),
          ),
        ],

        if (e.labTests.isNotEmpty) ...[
          const SizedBox(height: 6),
          Wrap(
            spacing: 5,
            runSpacing: 5,
            children: e.labTests.map((t) => _labChip(t, isDark)).toList(),
          ),
        ],

        if (onRepeat != null && allMeds.isNotEmpty) ...[
          const SizedBox(height: 10),
          SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              onPressed: () => onRepeat!(e.raw),
              icon: Icon(Icons.replay_rounded,
                  size: 14, color: context.comfort.brand),
              label: Text(
                'Repeat this prescription',
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: context.comfort.brand,
                ),
              ),
              style: OutlinedButton.styleFrom(
                backgroundColor: isDark ? SoftPalette.slate900.withValues(alpha: 0.65) : SoftPalette.gray50,
                side: BorderSide(
                  color: context.comfort.brand.withValues(alpha: isDark ? 0.55 : 0.45),
                ),
                padding: const EdgeInsets.symmetric(vertical: 11),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(9)),
              ),
            ),
          ),
        ],
      ],
    );
  }

  Widget _buildCompactVitalsDisplay(Map<String, dynamic> vitals, bool isDark) {
    final recVitals = (vitals['receptionistVitals'] is Map)
        ? Map<String, dynamic>.from(vitals['receptionistVitals'])
        : <String, dynamic>{};
    final docVitals = (vitals['doctorVitals'] is Map)
        ? Map<String, dynamic>.from(vitals['doctorVitals'])
        : <String, dynamic>{};

    final hasDocEdit = docVitals.isNotEmpty;

    if (hasDocEdit) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text('REC VITALS (${recVitals['addedBy'] ?? 'Receptionist'}):',
                  style: TextStyle(fontSize: 8.5, fontWeight: FontWeight.w800, color: isDark ? SoftPalette.sky350 : SoftPalette.blue550, letterSpacing: 0.5)),
            ],
          ),
          const SizedBox(height: 3),
          Wrap(spacing: 5, runSpacing: 4, children: [
            if (recVitals['bp'] != null && recVitals['bp'] != 'N/A') _vitalChip('BP', recVitals['bp'].toString(), SoftPalette.adaptive(SoftPalette.blue500, isDark)),
            if (recVitals['temp'] != null && recVitals['temp'] != 'N/A') _vitalChip('Temp', '${recVitals['temp']}°C', SoftPalette.adaptive(SoftPalette.orange350, isDark)),
            if (recVitals['sugar'] != null && recVitals['sugar'].toString().isNotEmpty) _vitalChip('Sugar', recVitals['sugar'].toString(), SoftPalette.adaptive(SoftPalette.purple550, isDark)),
            if (recVitals['weight'] != null && recVitals['weight'] != 'N/A') _vitalChip('Wt', '${recVitals['weight']} kg', SoftPalette.adaptive(SoftPalette.teal500, isDark)),
          ]),
          const SizedBox(height: 6),
          Row(
            children: [
              Text('DOC VITALS EDITED (${docVitals['updatedBy'] ?? 'Doctor'}):',
                  style: TextStyle(fontSize: 8.5, fontWeight: FontWeight.w800, color: isDark ? SoftPalette.yellow200 : SoftPalette.orange350, letterSpacing: 0.5)),
            ],
          ),
          const SizedBox(height: 3),
          Wrap(spacing: 5, runSpacing: 4, children: [
            if (docVitals['bp'] != null && docVitals['bp'] != 'N/A') _vitalChip('BP', docVitals['bp'].toString(), SoftPalette.adaptive(SoftPalette.red500, isDark)),
            if (docVitals['temp'] != null && docVitals['temp'] != 'N/A') _vitalChip('Temp', '${docVitals['temp']}°C', SoftPalette.adaptive(SoftPalette.orange350, isDark)),
            if (docVitals['sugar'] != null && docVitals['sugar'].toString().isNotEmpty) _vitalChip('Sugar', docVitals['sugar'].toString(), SoftPalette.adaptive(SoftPalette.purple550, isDark)),
            if (docVitals['weight'] != null && docVitals['weight'] != 'N/A') _vitalChip('Wt', '${docVitals['weight']} kg', SoftPalette.adaptive(SoftPalette.teal500, isDark)),
          ]),
        ],
      );
    }

    return Wrap(spacing: 5, runSpacing: 5, children: [
      if (vitals['bp'] != null && vitals['bp'] != 'N/A' && vitals['bp'].toString().trim().isNotEmpty)
        _vitalChip('BP', vitals['bp'].toString(), SoftPalette.adaptive(SoftPalette.red500, isDark)),
      if (vitals['temp'] != null && vitals['temp'] != 'N/A' && vitals['temp'].toString().trim().isNotEmpty)
        _vitalChip('Temp', '${vitals['temp']}${vitals['tempUnit'] ?? ''}', SoftPalette.adaptive(SoftPalette.orange350, isDark)),
      if (vitals['sugar'] != null && vitals['sugar'] != 'N/A' && vitals['sugar'].toString().trim().isNotEmpty)
        _vitalChip('Sugar', vitals['sugar'].toString(), SoftPalette.adaptive(SoftPalette.sky500, isDark)),
      if (vitals['weight'] != null && vitals['weight'] != 'N/A' && vitals['weight'].toString().trim().isNotEmpty)
        _vitalChip('Wt', '${vitals['weight']} kg', SoftPalette.adaptive(SoftPalette.emerald500, isDark)),
    ]);
  }

  Widget _label(BuildContext context, String text) => Text(text.toUpperCase(),
      style: TextStyle(fontSize: 9.5, fontWeight: FontWeight.w800, color: context.comfort.brand, letterSpacing: 0.8));

  Widget _vitalChip(String label, String value, Color color) => Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: color.withValues(alpha: 0.3)),
      ),
      child: Text(
        label == 'BP' ? 'BP $value' : value,
        style: TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w600,
          color: color,
        ),
      ));

  Widget _labChip(String text, bool isDark) => Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
      decoration: BoxDecoration(
        color: isDark ? SoftPalette.orange800 : SoftPalette.amber100m, borderRadius: BorderRadius.circular(20),
        border: Border.all(color: isDark ? SoftPalette.red600 : SoftPalette.amber300),
      ),
      child: Text(text, style: TextStyle(fontSize: 11, color: isDark ? SoftPalette.amber200 : SoftPalette.orange400, fontWeight: FontWeight.w600)));

  Widget _medTile(_MedEntry med, {required bool isInj, required bool isDark}) {
    final nameWithDose = [
      med.name,
      if (med.dosage.isNotEmpty) med.dosage,
    ].join(' ');
    final timingStr = med.timing.isNotEmpty
        ? med.timing
        : (med.frequency.isNotEmpty ? med.frequency : '');

    return Container(
      margin: const EdgeInsets.only(bottom: 5),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: isDark ? SoftPalette.slate900.withValues(alpha: 0.65) : SoftPalette.slate50,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: isDark ? SoftPalette.slate700.withValues(alpha: 0.8) : SoftPalette.slate200,
        ),
      ),
      child: Row(children: [
        MedicineIconBadge(
          name: med.name,
          type: isInj ? 'injection' : '',
          size: 20,
          iconSize: 12,
          borderRadius: 5,
        ),
        const SizedBox(width: 8),
        Expanded(
          child: RichText(
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            text: TextSpan(
              children: [
                TextSpan(
                  text: nameWithDose,
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: isDark ? SoftPalette.gray50 : SoftPalette.slate900,
                  ),
                ),
                if (timingStr.isNotEmpty)
                  TextSpan(
                    text: ' · $timingStr',
                    style: TextStyle(
                      fontSize: 11.5,
                      fontWeight: FontWeight.w500,
                      color: isDark ? SoftPalette.slate400 : SoftPalette.slate550,
                    ),
                  ),
              ],
            ),
          ),
        ),
        const SizedBox(width: 8),
        Text(
          '${med.quantity}',
          style: TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w700,
            color: isDark ? SoftPalette.gray50 : SoftPalette.slate900,
          ),
        ),
      ]),
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════════════
// FULL HISTORY CARD (Ultra-Compact, High Information Density)
// ═══════════════════════════════════════════════════════════════════════════════

class _HistoryCard extends StatefulWidget {
  final _HistoryEntry entry;
  final bool isLatest;
  final bool isOldest;
  final bool initiallyExpanded;
  final void Function(Map<String, dynamic>)? onRepeatLast;

  const _HistoryCard({
    required this.entry,
    this.isLatest = false,
    this.isOldest = false,
    this.initiallyExpanded = true,
    this.onRepeatLast,
  });

  @override
  State<_HistoryCard> createState() => _HistoryCardState();
}

class _HistoryCardState extends State<_HistoryCard> {
  Color get _teal => context.comfort.brand;
  late bool _expanded;

  @override
  void initState() {
    super.initState();
    _expanded = widget.initiallyExpanded;
  }

  bool _getIsDark(BuildContext context) {
    try {
      if (Hive.isBoxOpen('app_settings')) {
        final dark = Hive.box('app_settings').get('is_dark_mode');
        if (dark != null) return dark == true;
      }
    } catch (_) {}
    return Theme.of(context).brightness == Brightness.dark;
  }

  @override
  Widget build(BuildContext context) {
    final isDark = _getIsDark(context);
    final brand = Theme.of(context).colorScheme.primary;
    final muted = isDark ? SoftPalette.slate400 : SoftPalette.slate550;
    final e = widget.entry;
    final dateStr = DateFormat('d MMM yyyy · hh:mm a').format(e.date);
    final oralMeds = e.medicines.where((m) => !m.isInjectable).toList();
    final injectables = e.medicines.where((m) => m.isInjectable).toList();

    final cardBg = Theme.of(context).cardColor;
    final cardBorder = widget.isLatest
        ? brand.withValues(alpha: 0.45)
        : (isDark ? SoftPalette.slate700 : SoftPalette.slate200);
    final textPrimary = isDark ? SoftPalette.gray50 : SoftPalette.slate900;

    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      decoration: BoxDecoration(
        color: cardBg,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: cardBorder, width: widget.isLatest ? 1.4 : 1.0),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // ── Clickable Collapsible Header ──
          InkWell(
            borderRadius: _expanded
                ? const BorderRadius.vertical(top: Radius.circular(11))
                : BorderRadius.circular(11),
            onTap: () => setState(() => _expanded = !_expanded),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
              decoration: BoxDecoration(
                color: widget.isLatest
                    ? brand.withValues(alpha: isDark ? 0.16 : 0.08)
                    : (isDark ? SoftPalette.slate900.withValues(alpha: 0.55) : SoftPalette.slate50),
                borderRadius: _expanded
                    ? const BorderRadius.vertical(top: Radius.circular(11))
                    : BorderRadius.circular(11),
              ),
              child: Row(
                children: [
                  Icon(Icons.calendar_today_rounded, color: brand, size: 13),
                  const SizedBox(width: 6),
                  Text(
                    dateStr,
                    style: TextStyle(color: textPrimary, fontSize: 12.5, fontWeight: FontWeight.w700),
                  ),
                  const SizedBox(width: 6),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1.5),
                    decoration: BoxDecoration(
                      color: brand.withValues(alpha: isDark ? 0.25 : 0.12),
                      borderRadius: BorderRadius.circular(5),
                    ),
                    child: Text(
                      '${e.days}d',
                      style: TextStyle(color: isDark ? SoftPalette.gray50 : brand, fontSize: 10, fontWeight: FontWeight.w700),
                    ),
                  ),
                  if (e.doctorName.isNotEmpty) ...[
                    const SizedBox(width: 6),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 1.5),
                      decoration: BoxDecoration(
                        color: isDark ? SoftPalette.slate800 : Colors.white,
                        borderRadius: BorderRadius.circular(5),
                        border: Border.all(color: isDark ? SoftPalette.slate700 : SoftPalette.slate200),
                      ),
                      child: Text(
                        e.doctorName.toLowerCase().startsWith('dr') ? e.doctorName : 'Dr. ${e.doctorName}',
                        style: TextStyle(color: isDark ? SoftPalette.slate200 : SoftPalette.slate700, fontSize: 10.5, fontWeight: FontWeight.w600),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                  if (!_expanded && (e.diagnosis.isNotEmpty || e.medicines.isNotEmpty)) ...[
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        [
                          if (e.diagnosis.isNotEmpty) e.diagnosis,
                          '${e.medicines.length} med${e.medicines.length == 1 ? '' : 's'}',
                        ].join(' · '),
                        style: TextStyle(fontSize: 11.5, color: muted),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ] else
                    const Spacer(),
                  Text(
                    '#${e.serial}',
                    style: TextStyle(color: muted, fontSize: 10.5, fontWeight: FontWeight.w500),
                  ),
                  if (widget.isLatest) ...[
                    const SizedBox(width: 6),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                      decoration: BoxDecoration(
                        color: brand,
                        borderRadius: BorderRadius.circular(5),
                      ),
                      child: const Text(
                        'LATEST',
                        style: TextStyle(color: SoftPalette.gray50, fontSize: 9, fontWeight: FontWeight.w800, letterSpacing: 0.4),
                      ),
                    ),
                  ] else if (widget.isOldest) ...[
                    const SizedBox(width: 6),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                      decoration: BoxDecoration(
                        color: isDark ? SoftPalette.slate700 : SoftPalette.slate200,
                        borderRadius: BorderRadius.circular(5),
                      ),
                      child: Text(
                        'OLDEST',
                        style: TextStyle(color: isDark ? SoftPalette.slate200 : SoftPalette.slate700, fontSize: 9, fontWeight: FontWeight.w800, letterSpacing: 0.4),
                      ),
                    ),
                  ],
                  const SizedBox(width: 6),
                  Icon(
                    _expanded ? Icons.keyboard_arrow_up_rounded : Icons.keyboard_arrow_down_rounded,
                    size: 18,
                    color: muted,
                  ),
                ],
              ),
            ),
          ),

          // ── Body (when expanded) ──
          if (_expanded) ...[
            Divider(height: 1, color: isDark ? SoftPalette.slate700.withValues(alpha: 0.7) : SoftPalette.slate200),
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Branch, Camp, Doctor, Session & Dispense Metadata Strip
                  Builder(builder: (_) {
                    final rawB = (e.raw['branchName'] ?? e.raw['branchId'] ?? '').toString().trim();
                    final bLabel = rawB.isNotEmpty ? (LocalStorageService.getBranchName(rawB) ?? rawB) : '';
                    final campLabel = e.campName.isNotEmpty && e.campName.toLowerCase() != bLabel.toLowerCase() ? e.campName : '';
                    final session = (e.raw['session'] ?? e.raw['shift'] ?? '').toString().trim();
                    final dispensedBy = (e.raw['dispensedBy'] ?? e.raw['performedBy'] ?? '').toString().trim();
                    final dispStatus = (e.raw['dispenseStatus'] ?? e.raw['status'] ?? '').toString().toLowerCase();
                    final isDisp = dispStatus == 'dispensed' || dispensedBy.isNotEmpty;

                    Widget metaChip(IconData icon, String text, Color color) {
                      return Container(
                        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
                        decoration: BoxDecoration(
                          color: color.withValues(alpha: isDark ? 0.16 : 0.08),
                          borderRadius: BorderRadius.circular(6),
                          border: Border.all(color: color.withValues(alpha: 0.3)),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(icon, size: 11, color: color),
                            const SizedBox(width: 4),
                            Text(text, style: TextStyle(fontSize: 10.5, fontWeight: FontWeight.w600, color: isDark ? SoftPalette.gray50 : color)),
                          ],
                        ),
                      );
                    }

                    final chips = <Widget>[
                      if (bLabel.isNotEmpty) metaChip(Icons.local_hospital_outlined, bLabel, brand),
                      if (campLabel.isNotEmpty) metaChip(Icons.location_on_outlined, campLabel, SoftPalette.sky500),
                      if (e.doctorName.isNotEmpty)
                        metaChip(
                          Icons.medical_services_outlined,
                          e.doctorName.toLowerCase().startsWith('dr') ? e.doctorName : 'Dr. ${e.doctorName}',
                          brand,
                        ),
                      if (session.isNotEmpty)
                        metaChip(Icons.schedule_rounded, session[0].toUpperCase() + session.substring(1).toLowerCase(), muted),
                      if (isDisp)
                        metaChip(
                          Icons.check_circle_outline_rounded,
                          dispensedBy.isNotEmpty ? 'Dispensed by $dispensedBy' : 'Dispensed',
                          SoftPalette.emerald500,
                        ),
                    ];
                    if (chips.isEmpty) return const SizedBox.shrink();
                    return Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: Wrap(spacing: 6, runSpacing: 5, children: chips),
                    );
                  }),

                  if (e.complaint.isNotEmpty || e.diagnosis.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          if (e.complaint.isNotEmpty)
                            Expanded(
                              child: _compactInlineBlock(
                                label: 'Condition',
                                value: e.complaint,
                                icon: Icons.medical_services_outlined,
                                accentColor: isDark ? SoftPalette.sky350 : SoftPalette.sky500,
                                bgColor: SoftPalette.sky500.withValues(alpha: isDark ? 0.14 : 0.06),
                                borderColor: SoftPalette.sky500.withValues(alpha: isDark ? 0.35 : 0.25),
                                textPrimary: textPrimary,
                              ),
                            ),
                          if (e.complaint.isNotEmpty && e.diagnosis.isNotEmpty)
                            const SizedBox(width: 8),
                          if (e.diagnosis.isNotEmpty)
                            Expanded(
                              child: _compactInlineBlock(
                                label: 'Diagnosis',
                                value: e.diagnosis,
                                icon: Icons.assignment_outlined,
                                accentColor: brand,
                                bgColor: brand.withValues(alpha: isDark ? 0.14 : 0.06),
                                borderColor: brand.withValues(alpha: isDark ? 0.35 : 0.25),
                                textPrimary: textPrimary,
                              ),
                            ),
                        ],
                      ),
                    ),

                  // Vitals
                  if (e.vitals.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: _buildCompactVitalsRow(e.vitals, isDark),
                    ),

                  // Medicines & Injectables Structured Rows
                  if (oralMeds.isNotEmpty || injectables.isNotEmpty) ...[
                    Padding(
                      padding: const EdgeInsets.only(bottom: 6),
                      child: Text(
                        'MEDICINES PRESCRIBED (${e.medicines.length})',
                        style: TextStyle(fontSize: 10, fontWeight: FontWeight.w700, letterSpacing: 0.6, color: muted),
                      ),
                    ),
                    ...[...oralMeds, ...injectables].map((m) {
                      final isInj = m.isInjectable;
                      final accent = isInj ? SoftPalette.amber500 : brand;
                      final nameStr = [m.name, if (m.dosage.isNotEmpty) m.dosage].join(' ');
                      final metaParts = <String>[
                        if (m.type.isNotEmpty) m.type,
                        if (m.timing.isNotEmpty) m.timing,
                        if (m.frequency.isNotEmpty && m.frequency != m.timing) m.frequency,
                        if (m.meal.isNotEmpty) m.meal,
                      ];
                      return Container(
                        margin: const EdgeInsets.only(bottom: 5),
                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
                        decoration: BoxDecoration(
                          color: isDark ? SoftPalette.slate900.withValues(alpha: 0.6) : SoftPalette.slate50,
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(color: isDark ? SoftPalette.slate700 : SoftPalette.slate200),
                        ),
                        child: Row(
                          children: [
                            Container(
                              width: 22,
                              height: 22,
                              alignment: Alignment.center,
                              decoration: BoxDecoration(
                                color: accent.withValues(alpha: isDark ? 0.22 : 0.12),
                                borderRadius: BorderRadius.circular(6),
                              ),
                              child: Icon(
                                isInj ? Icons.vaccines_rounded : Icons.medication_rounded,
                                size: 12,
                                color: accent,
                              ),
                            ),
                            const SizedBox(width: 9),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    nameStr,
                                    style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700, color: textPrimary),
                                  ),
                                  if (metaParts.isNotEmpty)
                                    Text(
                                      metaParts.join(' · '),
                                      style: TextStyle(fontSize: 11, color: muted),
                                    ),
                                ],
                              ),
                            ),
                            const SizedBox(width: 8),
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                              decoration: BoxDecoration(
                                color: accent.withValues(alpha: isDark ? 0.2 : 0.1),
                                borderRadius: BorderRadius.circular(5),
                              ),
                              child: Text(
                                '×${m.quantity}',
                                style: TextStyle(
                                  fontSize: 11.5,
                                  fontWeight: FontWeight.w800,
                                  color: isDark ? SoftPalette.gray50 : accent,
                                ),
                              ),
                            ),
                          ],
                        ),
                      );
                    }),
                    const SizedBox(height: 4),
                  ],

                  // Lab tests / Physiotherapies
                  if (e.labTests.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 6),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
                            margin: const EdgeInsets.only(right: 6, top: 1),
                            decoration: BoxDecoration(
                              color: SoftPalette.amber500.withValues(alpha: isDark ? 0.2 : 0.1),
                              borderRadius: BorderRadius.circular(5),
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(
                                  e.raw['isPhysiotherapist'] == true ? Icons.accessibility_rounded : Icons.science_rounded,
                                  size: 11,
                                  color: SoftPalette.amber400,
                                ),
                                const SizedBox(width: 3),
                                Text(
                                  e.raw['isPhysiotherapist'] == true ? 'Physiotherapy' : 'Lab Tests',
                                  style: TextStyle(fontSize: 10, fontWeight: FontWeight.bold, color: isDark ? SoftPalette.amber300 : SoftPalette.amber500),
                                ),
                              ],
                            ),
                          ),
                          Expanded(
                            child: Wrap(
                              spacing: 5,
                              runSpacing: 4,
                              children: e.labTests.map((t) => Container(
                                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                                decoration: BoxDecoration(
                                  color: SoftPalette.amber500.withValues(alpha: isDark ? 0.18 : 0.08),
                                  borderRadius: BorderRadius.circular(6),
                                  border: Border.all(color: SoftPalette.amber500.withValues(alpha: 0.35)),
                                ),
                                child: Text(
                                  t,
                                  style: TextStyle(
                                    fontSize: 11,
                                    fontWeight: FontWeight.w600,
                                    color: isDark ? SoftPalette.amber200 : SoftPalette.amber500,
                                  ),
                                ),
                              )).toList(),
                            ),
                          ),
                        ],
                      ),
                    ),

                  if (widget.onRepeatLast != null && e.medicines.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 6),
                      child: SizedBox(
                        width: double.infinity,
                        child: OutlinedButton.icon(
                          onPressed: () => widget.onRepeatLast!(e.raw),
                          icon: Icon(Icons.replay_rounded, size: 14, color: isDark ? SoftPalette.gray50 : brand),
                          label: Text(
                            'Repeat this prescription',
                            style: TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                              color: isDark ? SoftPalette.gray50 : brand,
                            ),
                          ),
                          style: OutlinedButton.styleFrom(
                            backgroundColor: brand.withValues(alpha: isDark ? 0.16 : 0.07),
                            side: BorderSide(color: brand.withValues(alpha: 0.45)),
                            padding: const EdgeInsets.symmetric(vertical: 10),
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(9)),
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _compactInlineBlock({
    required String label,
    required String value,
    required IconData icon,
    required Color accentColor,
    required Color bgColor,
    required Color borderColor,
    required Color textPrimary,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
      decoration: BoxDecoration(
        color: bgColor,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: borderColor),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 13, color: accentColor),
          const SizedBox(width: 5),
          Expanded(
            child: RichText(
              text: TextSpan(
                children: [
                  TextSpan(
                    text: '$label: ',
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.bold,
                      color: accentColor,
                    ),
                  ),
                  TextSpan(
                    text: value,
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: textPrimary,
                    ),
                  ),
                ],
              ),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildCompactVitalsRow(Map<String, dynamic> vitals, bool isDark) {
    final chips = <Widget>[];

    final merged = <String, dynamic>{};
    if (vitals['receptionistVitals'] is Map) {
      merged.addAll(Map<String, dynamic>.from(vitals['receptionistVitals'] as Map));
    }
    if (vitals['doctorVitals'] is Map) {
      merged.addAll(Map<String, dynamic>.from(vitals['doctorVitals'] as Map));
    }
    for (final k in vitals.keys) {
      if (k != 'receptionistVitals' && k != 'doctorVitals' && vitals[k] != null) {
        merged.putIfAbsent(k, () => vitals[k]);
      }
    }

    final bp = merged['bp'] ?? merged['bloodPressure'] ?? merged['BP'];
    if (bp != null && bp.toString().trim().isNotEmpty && bp != 'N/A') {
      chips.add(_microVitalChip('BP', bp.toString(), SoftPalette.red400, isDark));
    }

    final temp = merged['temp'] ?? merged['temperature'] ?? merged['Temp'];
    if (temp != null && temp.toString().trim().isNotEmpty && temp != 'N/A') {
      chips.add(_microVitalChip('Temp', '${temp.toString().replaceAll('°C', '')}°C', SoftPalette.orange350, isDark));
    }

    final sugar = merged['sugar'] ?? merged['bloodSugar'] ?? merged['Sugar'] ?? merged['glucose'] ?? merged['rbs'];
    if (sugar != null && sugar.toString().trim().isNotEmpty && sugar != 'N/A') {
      chips.add(_microVitalChip('Sugar', sugar.toString(), SoftPalette.purple350, isDark));
    }

    final weight = merged['weight'] ?? merged['wt'] ?? merged['Weight'];
    if (weight != null && weight.toString().trim().isNotEmpty && weight != 'N/A') {
      chips.add(_microVitalChip('Weight', '${weight.toString().replaceAll('kg', '')}kg', SoftPalette.teal300, isDark));
    }

    final pulse = merged['pulse'] ?? merged['heartRate'] ?? merged['spo2'] ?? merged['hr'];
    if (pulse != null && pulse.toString().trim().isNotEmpty && pulse != 'N/A') {
      chips.add(_microVitalChip('Pulse', pulse.toString(), SoftPalette.sky350, isDark));
    }

    if (chips.isEmpty) return const SizedBox();

    return Wrap(spacing: 5, runSpacing: 4, children: chips);
  }

  Widget _microVitalChip(String label, String value, Color color, bool isDark) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2.5),
      decoration: BoxDecoration(
        color: color.withValues(alpha: isDark ? 0.16 : 0.08),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: color.withValues(alpha: isDark ? 0.4 : 0.25)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            '$label: ',
            style: TextStyle(fontSize: 10, fontWeight: FontWeight.bold, color: color),
          ),
          Text(
            value,
            style: TextStyle(fontSize: 11, fontWeight: FontWeight.w800, color: color),
          ),
        ],
      ),
    );
  }

  Widget _compactMedChip(_MedEntry med, bool isDark) {
    final parts = <String>[];
    if (med.dosage.isNotEmpty) parts.add(med.dosage);
    if (med.frequency.isNotEmpty) parts.add(med.frequency);
    if (med.meal.isNotEmpty) parts.add(med.meal);

    final bg = isDark ? SoftPalette.slate800 : SoftPalette.slate100;
    final border = isDark ? SoftPalette.slate700 : SoftPalette.gray150;
    final textNameColor = isDark ? SoftPalette.gray50 : SoftPalette.slate900;
    final textPartsColor = isDark ? SoftPalette.slate350 : SoftPalette.gray550;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(7),
        border: Border.all(color: border),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
            decoration: BoxDecoration(
              color: context.comfort.brand,
              borderRadius: BorderRadius.circular(4),
            ),
            child: Text(
              med.abbrev.isNotEmpty ? med.abbrev : 'Med',
              style: const TextStyle(color: SoftPalette.gray50, fontSize: 9, fontWeight: FontWeight.bold),
            ),
          ),
          const SizedBox(width: 6),
          Text(
            med.name,
            style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: textNameColor),
          ),
          if (parts.isNotEmpty) ...[
            const SizedBox(width: 4),
            Text(
              '(${parts.join(' · ')})',
              style: TextStyle(fontSize: 10.5, color: textPartsColor, fontWeight: FontWeight.w500),
            ),
          ],
        ],
      ),
    );
  }

  Widget _compactInjChip(_MedEntry med, bool isDark) {
    final bg = isDark ? SoftPalette.blue700.withValues(alpha: 0.3) : SoftPalette.slate100;
    final border = isDark ? SoftPalette.blue500.withValues(alpha: 0.35) : SoftPalette.sky300;
    final textNameColor = isDark ? SoftPalette.gray50 : SoftPalette.blue600;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(7),
        border: Border.all(color: border),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.vaccines, size: 12, color: SoftPalette.adaptive(SoftPalette.blue550, isDark)),
          const SizedBox(width: 5),
          Text(
            med.name,
            style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: textNameColor),
          ),
          const SizedBox(width: 4),
          Text(
            'Qty: ${med.quantity}',
            style: TextStyle(fontSize: 10.5, color: isDark ? SoftPalette.blue300 : SoftPalette.blue500, fontWeight: FontWeight.w600),
          ),
        ],
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════════════
// DATA MODELS  (unchanged)
// ═══════════════════════════════════════════════════════════════════════════════

class _HistoryEntry {
  final String serial, diagnosis, complaint, doctorName, source, campId, campName;
  final DateTime date;
  final List<_MedEntry> medicines;
  final List<String> labTests;
  final Map<String, dynamic> vitals, raw;
  final int days;
  final bool isVitalsOnly;

  const _HistoryEntry({
    required this.serial, required this.date, required this.diagnosis,
    required this.complaint, required this.doctorName, required this.medicines,
    required this.labTests, required this.vitals, required this.raw,
    required this.source, required this.days,
    required this.campId, required this.campName,
    required this.isVitalsOnly,
  });

  String get key => serial;

  static _HistoryEntry? fromMap(Map<String, dynamic> data, {required String source}) {
    final serial = (data['serial'] ?? data['id'] ?? '').toString().trim();
    if (serial.isEmpty) return null;

    final cId = (data['dispensaryId'] ?? data['campId'] ?? data['branchCamp'] ?? '').toString().trim();
    final rawCampName = (data['campName'] ?? '').toString().trim();
    final cName = rawCampName.isNotEmpty
        ? rawCampName
        : (cId.isNotEmpty
            ? CampSessionService.getCampLabel(cId)
            : (data['branchName'] ?? data['branchId'] ?? '').toString().trim());

    DateTime date = DateTime(2000);
    final rawTs = data['createdAt'] ?? data['completedAt'] ?? data['dispensedAt'];
    if (rawTs is Timestamp)       { date = rawTs.toDate(); }
    else if (rawTs is String && rawTs.isNotEmpty) {
      try { date = DateTime.parse(rawTs); } catch (_) {}
    }
    if (date.year == 2000) {
      final dk = data['dateKey']?.toString() ?? data['date']?.toString() ?? '';
      if (dk.length == 6) {
        try {
          date = DateTime(2000 + int.parse(dk.substring(4, 6)),
                          int.parse(dk.substring(2, 4)),
                          int.parse(dk.substring(0, 2)));
        } catch (_) {}
      }
    }
    if (date.year == 2000) {
      try {
        final ds = serial.split('-')[0];
        if (ds.length == 6) {
          date = DateTime(2000 + int.parse(ds.substring(4, 6)),
                          int.parse(ds.substring(2, 4)),
                          int.parse(ds.substring(0, 2)));
        }
      } catch (_) {}
    }

    final unwrapped = PatientHistoryPanel.unwrapPrescriptionData(data);

    final meds = <_MedEntry>[];

    void addSingleMedMap(Map<String, dynamic> m) {
      final name = (m['name'] ??
              m['displayName'] ??
              m['medicineName'] ??
              m['medName'] ??
              m['title'] ??
              m['medicine'] ??
              m['item'] ??
              m['drug'] ??
              m['formula'] ??
              m['productName'] ??
              '')
          .toString()
          .trim();
      if (name.isEmpty) return;
      // Saved records carry 'dosage': '' next to the real strength in 'dose', so the first
      // non-empty one wins (taking 'dosage' first lost 250 mg vs 500 mg).
      final dosage = [m['dose'], m['strength'], m['dosage']]
          .map((v) => (v ?? '').toString().trim())
          .firstWhere((v) => v.isNotEmpty && v.toLowerCase() != 'null', orElse: () => '');
      final type = (m['type'] ?? m['form'] ?? '').toString().trim();
      // The same medicine in another form or strength is a separate line.
      if (meds.any((existing) =>
          existing.name.toLowerCase() == name.toLowerCase() &&
          existing.type.toLowerCase() == type.toLowerCase() &&
          existing.dosage.toLowerCase() == dosage.toLowerCase())) {
        return;
      }
      String? idOf(Object? v) {
        final s = v?.toString().trim();
        return (s == null || s.isEmpty || s == 'null') ? null : s;
      }
      meds.add(_MedEntry(
        name: name,
        type: type,
        inventoryId: idOf(m['inventoryId'] ?? m['medicineId']),
        formula: idOf(m['formula']),
        timing: (m['timing'] ?? m['time'] ?? m['schedule'] ?? '').toString().trim(),
        meal: (m['meal'] ?? m['instruction'] ?? '').toString().trim(),
        dosage: dosage,
        quantity: (m['quantity'] is num
            ? (m['quantity'] as num).toInt()
            : (m['qty'] is num
                ? (m['qty'] as num).toInt()
                : int.tryParse(m['quantity']?.toString() ?? m['qty']?.toString() ?? '') ?? 1)),
        frequency: (m['frequency'] ?? m['freq'] ?? '').toString().trim(),
      ));
    }

    void addMedList(dynamic list) {
      if (list == null) return;
      if (list is String) {
        final trimmed = list.trim();
        if (trimmed.startsWith('[') && trimmed.endsWith(']')) {
          try {
            final decoded = jsonDecode(trimmed);
            if (decoded is List) list = decoded;
          } catch (_) {}
        }
      }
      if (list is! List) return;
      for (final m in list) {
        if (m == null) continue;
        if (m is String) {
          final trimmed = m.trim();
          if (trimmed.isEmpty) continue;
          if (trimmed.startsWith('{') && trimmed.endsWith('}')) {
            try {
              final decoded = jsonDecode(trimmed);
              if (decoded is Map) {
                addSingleMedMap(Map<String, dynamic>.from(decoded));
                continue;
              }
            } catch (_) {}
          }
          if (meds.any((existing) => existing.name.toLowerCase() == trimmed.toLowerCase())) continue;
          meds.add(_MedEntry(
            name: trimmed,
            type: 'Tablet',
            timing: '',
            meal: '',
            dosage: '',
            quantity: 1,
            frequency: '',
          ));
          continue;
        }
        if (m is Map) {
          addSingleMedMap(Map<String, dynamic>.from(m));
        }
      }
    }

    if (data['data'] is Map) {
      final inner = Map<String, dynamic>.from(data['data'] as Map);
      inner.forEach((k, v) => data.putIfAbsent(k, () => v));
    }

    addMedList(unwrapped['prescriptions']);
    addMedList(unwrapped['medicines']);
    addMedList(unwrapped['oralMedicines']);
    addMedList(unwrapped['injectables']);
    addMedList(unwrapped['items']);
    addMedList(unwrapped['dispensedMedicines']);
    addMedList(unwrapped['prescriptionList']);
    addMedList(unwrapped['prescriptionsList']);
    addMedList(unwrapped['rx']);
    addMedList(unwrapped['medicineList']);
    addMedList(unwrapped['treatment']);

    addMedList(data['prescriptions']);
    addMedList(data['medicines']);
    addMedList(data['oralMedicines']);
    addMedList(data['injectables']);
    addMedList(data['items']);
    addMedList(data['prescriptionList']);
    addMedList(data['prescriptionsList']);
    if (data['prescription'] is Map) {
      final p = PatientHistoryPanel.unwrapPrescriptionData(Map<String, dynamic>.from(data['prescription'] as Map));
      addMedList(p['prescriptions']);
      addMedList(p['medicines']);
      addMedList(p['oralMedicines']);
      addMedList(p['injectables']);
      addMedList(p['items']);
      addMedList(p['dispensedMedicines']);
    }

    String extractedDiagnosis = (unwrapped['diagnosis'] ??
        unwrapped['patientDiagnosis'] ??
        unwrapped['finalDiagnosis'] ??
        unwrapped['provisionalDiagnosis'] ??
        data['diagnosis'] ??
        data['patientDiagnosis'] ??
        data['finalDiagnosis'] ??
        data['provisionalDiagnosis'] ??
        (data['prescription'] is Map ? data['prescription']['diagnosis'] : null) ??
        '')
        .toString()
        .trim();

    String extractedComplaint = (unwrapped['complaint'] ??
        unwrapped['condition'] ??
        unwrapped['patientCondition'] ??
        unwrapped['reason'] ??
        unwrapped['symptoms'] ??
        unwrapped['chiefComplaint'] ??
        data['complaint'] ??
        data['condition'] ??
        data['patientCondition'] ??
        data['reason'] ??
        data['symptoms'] ??
        data['chiefComplaint'] ??
        (data['prescription'] is Map ? (data['prescription']['complaint'] ?? data['prescription']['condition']) : null) ??
        '')
        .toString()
        .trim();

    String extractedDoctor = (unwrapped['doctorName'] ??
        unwrapped['prescribedBy'] ??
        unwrapped['doctor'] ??
        unwrapped['doctor_name'] ??
        data['doctorName'] ??
        data['prescribedBy'] ??
        data['doctor'] ??
        data['doctor_name'] ??
        (data['prescription'] is Map ? data['prescription']['doctorName'] : null) ??
        '')
        .toString()
        .trim();

    // Cross-box fallback lookup if medicines or diagnosis missing on this record
    if (meds.isEmpty || extractedDiagnosis.isEmpty) {
      try {
        final lp = LocalStorageService.getLocalPrescription(serial);
        if (lp != null) {
          final ulp = PatientHistoryPanel.unwrapPrescriptionData(Map<String, dynamic>.from(lp));
          addMedList(ulp['medicines']);
          addMedList(ulp['prescriptions']);
          addMedList(ulp['oralMedicines']);
          addMedList(ulp['injectables']);
          addMedList(ulp['items']);
          addMedList(ulp['dispensedMedicines']);
          if (extractedDiagnosis.isEmpty) extractedDiagnosis = (ulp['diagnosis'] ?? ulp['finalDiagnosis'] ?? '').toString().trim();
          if (extractedComplaint.isEmpty) extractedComplaint = (ulp['complaint'] ?? ulp['condition'] ?? '').toString().trim();
          if (extractedDoctor.isEmpty) extractedDoctor = (ulp['doctorName'] ?? ulp['prescribedBy'] ?? '').toString().trim();
        }

        dynamic lookupSerialInBox(Box box, String s) {
          final sLow = s.toLowerCase();
          final sUp = s.toUpperCase();
          dynamic raw = box.get(s) ??
              box.get(sLow) ??
              box.get(sUp) ??
              box.get('karachi-$sLow') ??
              box.get('karachi-$sUp') ??
              box.get('legacy_$sLow');
          if (raw != null) return raw;
          if (box.length <= 500) {
            for (final k in box.keys) {
              if (k.toString().toLowerCase().contains(sLow)) {
                return box.get(k);
              }
            }
          }
          return null;
        }

        if (Hive.isBoxOpen(LocalStorageService.dispensaryBox)) {
          final dBox = Hive.box(LocalStorageService.dispensaryBox);
          final dRaw = lookupSerialInBox(dBox, serial);
          if (dRaw is Map) {
            final udRaw = PatientHistoryPanel.unwrapPrescriptionData(Map<String, dynamic>.from(dRaw));
            addMedList(udRaw['medicines']);
            addMedList(udRaw['prescriptions']);
            addMedList(udRaw['oralMedicines']);
            addMedList(udRaw['injectables']);
            addMedList(udRaw['items']);
            addMedList(udRaw['dispensedMedicines']);
            if (extractedDiagnosis.isEmpty) extractedDiagnosis = (udRaw['diagnosis'] ?? udRaw['finalDiagnosis'] ?? udRaw['patientDiagnosis'] ?? '').toString().trim();
            if (extractedComplaint.isEmpty) extractedComplaint = (udRaw['complaint'] ?? udRaw['condition'] ?? udRaw['patientCondition'] ?? '').toString().trim();
            if (extractedDoctor.isEmpty) extractedDoctor = (udRaw['doctorName'] ?? udRaw['prescribedBy'] ?? '').toString().trim();
          }
        }
        if ((meds.isEmpty || extractedDiagnosis.isEmpty) && Hive.isBoxOpen(LocalStorageService.prescriptionsBox)) {
          final prBox = Hive.box(LocalStorageService.prescriptionsBox);
          final prRaw = lookupSerialInBox(prBox, serial);
          if (prRaw is Map) {
            final uprRaw = PatientHistoryPanel.unwrapPrescriptionData(Map<String, dynamic>.from(prRaw));
            addMedList(uprRaw['medicines']);
            addMedList(uprRaw['prescriptions']);
            addMedList(uprRaw['oralMedicines']);
            addMedList(uprRaw['injectables']);
            addMedList(uprRaw['items']);
            addMedList(uprRaw['dispensedMedicines']);
            if (extractedDiagnosis.isEmpty) extractedDiagnosis = (uprRaw['diagnosis'] ?? uprRaw['finalDiagnosis'] ?? uprRaw['patientDiagnosis'] ?? '').toString().trim();
            if (extractedComplaint.isEmpty) extractedComplaint = (uprRaw['complaint'] ?? uprRaw['condition'] ?? uprRaw['patientCondition'] ?? '').toString().trim();
            if (extractedDoctor.isEmpty) extractedDoctor = (uprRaw['doctorName'] ?? uprRaw['prescribedBy'] ?? '').toString().trim();
          }
        }
        if ((meds.isEmpty || extractedDiagnosis.isEmpty) && Hive.isBoxOpen(LocalStorageService.entriesBox)) {
          final eBox = Hive.box(LocalStorageService.entriesBox);
          final eRaw = lookupSerialInBox(eBox, serial);
          if (eRaw is Map) {
            final ueRaw = PatientHistoryPanel.unwrapPrescriptionData(Map<String, dynamic>.from(eRaw));
            addMedList(ueRaw['medicines']);
            addMedList(ueRaw['prescriptions']);
            addMedList(ueRaw['oralMedicines']);
            addMedList(ueRaw['injectables']);
            addMedList(ueRaw['items']);
            addMedList(ueRaw['dispensedMedicines']);
            if (extractedDiagnosis.isEmpty) extractedDiagnosis = (ueRaw['diagnosis'] ?? ueRaw['finalDiagnosis'] ?? ueRaw['patientDiagnosis'] ?? '').toString().trim();
            if (extractedComplaint.isEmpty) extractedComplaint = (ueRaw['complaint'] ?? ueRaw['condition'] ?? ueRaw['patientCondition'] ?? '').toString().trim();
            if (extractedDoctor.isEmpty) extractedDoctor = (ueRaw['doctorName'] ?? ueRaw['prescribedBy'] ?? '').toString().trim();
          }
        }
        if ((meds.isEmpty || extractedDiagnosis.isEmpty) && Hive.isBoxOpen(LocalStorageService.reportsCacheBox)) {
          final rcBox = Hive.box(LocalStorageService.reportsCacheBox);
          final rcRaw = lookupSerialInBox(rcBox, serial);
          if (rcRaw is Map) {
            final urcRaw = PatientHistoryPanel.unwrapPrescriptionData(Map<String, dynamic>.from(rcRaw));
            addMedList(urcRaw['medicines']);
            addMedList(urcRaw['prescriptions']);
            addMedList(urcRaw['oralMedicines']);
            addMedList(urcRaw['injectables']);
            addMedList(urcRaw['items']);
            addMedList(urcRaw['dispensedMedicines']);
            if (extractedDiagnosis.isEmpty) extractedDiagnosis = (urcRaw['diagnosis'] ?? urcRaw['finalDiagnosis'] ?? '').toString().trim();
            if (extractedComplaint.isEmpty) extractedComplaint = (urcRaw['complaint'] ?? urcRaw['condition'] ?? '').toString().trim();
            if (extractedDoctor.isEmpty) extractedDoctor = (urcRaw['doctorName'] ?? urcRaw['prescribedBy'] ?? '').toString().trim();
          }
        }
      } catch (_) {}
    }

    final labs = <String>[];
    void addLabList(dynamic list) {
      if (list == null) return;
      if (list is String) {
        final trimmed = list.trim();
        if (trimmed.startsWith('[') && trimmed.endsWith(']')) {
          try {
            final decoded = jsonDecode(trimmed);
            if (decoded is List) list = decoded;
          } catch (_) {}
        }
      }
      if (list is! List) return;
      for (final l in list) {
        if (l == null) continue;
        final name = (l is Map ? (l['name'] ?? l['testName'] ?? l['title'] ?? l['test'] ?? l['labTest']) : l)?.toString().trim() ?? '';
        if (name.isNotEmpty && !labs.contains(name)) labs.add(name);
      }
    }

    addLabList(unwrapped['labResults']);
    addLabList(unwrapped['labTests']);
    addLabList(unwrapped['tests']);
    addLabList(unwrapped['lab_tests']);
    addLabList(unwrapped['physiotherapies']);
    addLabList(data['labResults']);
    addLabList(data['labTests']);
    addLabList(data['tests']);
    addLabList(data['lab_tests']);
    addLabList(data['physiotherapies']);
    if (data['prescription'] is Map) {
      final p = data['prescription'] as Map;
      addLabList(p['labResults']);
      addLabList(p['labTests']);
      addLabList(p['tests']);
      addLabList(p['lab_tests']);
      addLabList(p['physiotherapies']);
    }

    final rawVitals = data['vitals'] ?? data['receptionistVitals'];
    Map<String, dynamic> extractedVitals = rawVitals is Map
        ? Map<String, dynamic>.from(rawVitals)
        : (data['bp'] != null || data['temp'] != null || data['weight'] != null || data['sugar'] != null)
            ? {
                if (data['bp'] != null) 'bp': data['bp'],
                if (data['temp'] != null) 'temp': data['temp'],
                if (data['weight'] != null) 'weight': data['weight'],
                if (data['sugar'] != null) 'sugar': data['sugar'],
              }
            : {};

    if (data['doctorVitals'] is Map && (data['doctorVitals'] as Map).isNotEmpty) {
      extractedVitals['doctorVitals'] = data['doctorVitals'];
    }

    if (extractedVitals.isEmpty) {
      try {
        if (Hive.isBoxOpen(LocalStorageService.entriesBox)) {
          final entriesBox = Hive.box(LocalStorageService.entriesBox);
          for (final k in entriesBox.keys) {
            if (k.toString().toLowerCase().contains(serial.toLowerCase())) {
              final entryMap = entriesBox.get(k);
              if (entryMap is Map) {
                final ev = entryMap['vitals'] ?? entryMap['receptionistVitals'];
                if (ev is Map && ev.isNotEmpty) {
                  extractedVitals = Map<String, dynamic>.from(ev);
                  break;
                } else if (entryMap['bp'] != null || entryMap['temp'] != null || entryMap['sugar'] != null || entryMap['weight'] != null) {
                  extractedVitals = {
                    if (entryMap['bp'] != null) 'bp': entryMap['bp'],
                    if (entryMap['temp'] != null) 'temp': entryMap['temp'],
                    if (entryMap['weight'] != null) 'weight': entryMap['weight'],
                    if (entryMap['sugar'] != null) 'sugar': entryMap['sugar'],
                  };
                  break;
                }
              }
            }
          }
        }
      } catch (_) {}
    }

    final isVitalsOnly = data['isVitalsOnly'] == true ||
        data['vitalsOnly'] == true ||
        (data['visitReason']?.toString().toLowerCase().contains('vitals') == true);

    return _HistoryEntry(
      serial:    serial,
      date:      date,
      diagnosis: extractedDiagnosis,
      complaint: extractedComplaint,
      doctorName:extractedDoctor,
      medicines: meds,
      labTests:  labs,
      vitals:    extractedVitals,
      raw:       {
        ...data,
        ...unwrapped,
        'medicines': meds.map((m) => m.toMap()).toList(),
        'prescriptions': meds.map((m) => m.toMap()).toList(),
        if (extractedDiagnosis.isNotEmpty) 'diagnosis': extractedDiagnosis,
        if (extractedComplaint.isNotEmpty) 'complaint': extractedComplaint,
        if (extractedDoctor.isNotEmpty) 'doctorName': extractedDoctor,
        if (labs.isNotEmpty) 'labTests': labs,
        if (extractedVitals.isNotEmpty) 'vitals': extractedVitals,
      },
      source:    source,
      days:      (unwrapped['daysOfMedicine'] is num ? (unwrapped['daysOfMedicine'] as num).toInt() : int.tryParse(unwrapped['daysOfMedicine']?.toString() ?? data['daysOfMedicine']?.toString() ?? '') ?? 1),
      campId:    cId,
      campName:  cName,
      isVitalsOnly: isVitalsOnly,
    );
  }

  Color get sourceColor {
    if (source.contains('Hive'))         return SoftPalette.blue400;
    if (source.contains('Dispensary'))   return SoftPalette.teal500;
    if (source.contains('Prescriptions')) return SoftPalette.green400;
    return SoftPalette.gray350;
  }

  IconData get sourceIcon {
    if (source.contains('Hive'))          return Icons.storage;
    if (source.contains('Dispensary'))    return Icons.local_pharmacy;
    if (source.contains('Prescriptions')) return Icons.description;
    return Icons.cloud;
  }
}

class _MedEntry {
  final String name, type, timing, meal, dosage, frequency;
  final int quantity;
  /// Stock item it was given from, and its generic name; Repeat needs both to find the
  /// medicine in today's stock instead of adding it as a custom one.
  final String? inventoryId, formula;

  const _MedEntry({
    required this.name, required this.type, required this.timing,
    required this.meal, required this.dosage, required this.quantity,
    required this.frequency, this.inventoryId, this.formula,
  });

  bool get isInjectable {
    final t = type.toLowerCase();
    return t.contains('injection') || t.contains('drip') ||
        t.contains('syringe') || t.contains('nebulization');
  }

  String get abbrev {
    final t = type.toLowerCase();
    if (t.contains('syrup'))     return 'Syrup';
    if (t.contains('injection')) return 'Inj.';
    if (t.contains('tablet'))    return 'Tab.';
    if (t.contains('capsule'))   return 'Cap.';
    if (t.contains('drip'))      return 'Drip';
    return '';
  }

  Map<String, dynamic> toMap() => {
    'name': name,
    'displayName': name,
    'medicineName': name,
    'type': type,
    'timing': timing,
    'meal': meal,
    'dosage': dosage,
    'dose': dosage,
    'quantity': quantity,
    'qty': quantity,
    'frequency': frequency,
    if (inventoryId != null) 'inventoryId': inventoryId,
    if (inventoryId != null) 'medicineId': inventoryId,
    if (formula != null) 'formula': formula,
  };
}
