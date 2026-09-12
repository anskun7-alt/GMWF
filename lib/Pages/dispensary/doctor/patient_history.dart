// lib/pages/dispensary/doctor/patient_history.dart

import 'dart:async';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:intl/intl.dart';

import 'package:gmwf/services/local_storage_service.dart';
import 'package:gmwf/services/camp_session_service.dart';
import 'package:gmwf/services/staff_patient_link_service.dart';
import 'package:gmwf/widgets/app_skeleton.dart';

// Alias kept for backwards compatibility with existing call sites
typedef PatientHistory = PatientHistoryPanel;

// ═══════════════════════════════════════════════════════════════════════════════
// HYBRID ID UTILITIES
// ═══════════════════════════════════════════════════════════════════════════════

class _IdHelper {
  static Set<String> variants(String id) {
    final clean = id.trim();
    if (clean.isEmpty) return {};
    final noHyphens  = clean.replaceAll('-', '');
    final digitsOnly = clean.replaceAll(RegExp(r'\D'), '');
    return {clean, noHyphens, if (digitsOnly.isNotEmpty) digitsOnly};
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

    // If patientId is empty or was set to a daily serial string (e.g. 030926-HAJI-007),
    // resolve the individual patient ID from local storage
    if (pid.isEmpty || (pid.contains('-') && RegExp(r'^\d{6}-').hasMatch(pid))) {
      final resolved = LocalStorageService.resolveIndividualPatientId(d);
      if (resolved.isNotEmpty && !RegExp(r'^\d{6}-').hasMatch(resolved)) {
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
    if (patientId.isNotEmpty && !RegExp(r'^\d{6}-').hasMatch(patientId)) return patientId;
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
    final docGuardian = (doc['guardianCnic'] ?? '').toString().trim();
    final docAge = (doc['age'] is num) ? (doc['age'] as num).toInt() : (int.tryParse(doc['age']?.toString() ?? '') ?? 0);
    final docIsAdult = doc['isAdult'] is bool
        ? doc['isAdult'] as bool
        : (!docPid.contains('_child_') && !docResolvedPid.contains('_child_') && docGuardian.isEmpty && (docAge == 0 || docAge >= 20));

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

    if (name.isNotEmpty && docName.isNotEmpty) {
      return docName == myName || docName.contains(myName) || myName.contains(docName);
    }
    return true;
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

  @override
  State<PatientHistoryPanel> createState() => _PatientHistoryPanelState();
}

class _PatientHistoryPanelState extends State<PatientHistoryPanel> {
  static const Color _teal = Color(0xFF00695C);

  List<_HistoryEntry> _entries   = [];
  bool                _isLoading = false;

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

    // ── Step 1: Instant Local Hive Scan (entries, dispensary, prescriptions) ──
    void scanLocalBox(String boxName, String sourceLabel) {
      try {
        if (!Hive.isBoxOpen(boxName)) return;
        final box = Hive.box(boxName);
        for (final key in box.keys) {
          final raw = box.get(key);
          if (raw is! Map) continue;
          final data = Map<String, dynamic>.from(raw);

          // Must have clinical, prescription, or vitals content
          final hasData = data['medicines'] != null ||
              data['prescriptions'] != null ||
              data['prescription'] != null ||
              data['oralMedicines'] != null ||
              data['injectables'] != null ||
              data['diagnosis'] != null ||
              data['vitals'] != null ||
              data['receptionistVitals'] != null ||
              data['bp'] != null;
          if (!hasData) continue;

          bool belongs = false;
          for (final field in ['patientId', 'id', 'cnic', 'patientCnic', 'guardianCnic']) {
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

          if (data['prescription'] is Map) {
            final nested = Map<String, dynamic>.from(data['prescription'] as Map);
            for (final k in nested.keys) {
              data.putIfAbsent(k, () => nested[k]);
            }
          }

          final rawSer = (data['serial'] ?? data['id'] ?? key.toString()).toString().trim();
          final serialMatch = RegExp(r'(\d{6}-[A-Za-z0-9]+-\d{3,})').firstMatch(rawSer);
          final canonicalSerial = serialMatch != null ? serialMatch.group(1)!.toUpperCase() : rawSer.toUpperCase();
          data['serial'] = canonicalSerial;

          final entry = _HistoryEntry.fromMap(data, source: sourceLabel);
          if (entry != null && seen.add(canonicalSerial)) found.add(entry);
        }
      } catch (e) {
        debugPrint('[PatientHistory] $boxName scan error: $e');
      }
    }

    scanLocalBox(LocalStorageService.prescriptionsBox, 'Prescriptions');
    scanLocalBox(LocalStorageService.entriesBox, 'Token History');
    scanLocalBox(LocalStorageService.dispensaryBox, 'Dispensary');

    // Show cached entries immediately without waiting for network!
    if (found.isNotEmpty && mounted && _loadToken == token) {
      found.sort((a, b) => b.date.compareTo(a.date));
      setState(() {
        _entries = List.from(found);
        _isLoading = false;
      });
    }

    // ── Step 2: Parallel Remote Fetches ──────────────────────────────────────
    try {
      // 1. Patient Doc Enrichment in background
      Map<String, dynamic>? firestorePatient;
      for (final variant in _IdHelper.variants(
          identity.patientId.isNotEmpty ? identity.patientId : identity.cnic)) {
        if (variant.isEmpty) continue;
        try {
          final doc = await FirebaseFirestore.instance
              .collection('branches')
              .doc(widget.branchId.toLowerCase())
              .collection('patients')
              .doc(variant)
              .get()
              .timeout(const Duration(seconds: 4));
          if (doc.exists) { firestorePatient = doc.data(); break; }
        } catch (_) {}
      }

      final enriched = _PatientIdentity.fromMap({
        ...?widget.patientData,
        ...?firestorePatient,
      }, widget.patientCnic);
      final allSearchIds = enriched.searchIds;

      if (_loadToken != token) return;

      // 2. Parallel Prescriptions queries
      final prescFutures = allSearchIds.where((id) => id.isNotEmpty).map((id) async {
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

            final entry = _HistoryEntry.fromMap(data, source: 'Prescriptions');
            if (entry != null && seen.add(entry.serial)) {
              found.add(entry);
              try {
                if (Hive.isBoxOpen(LocalStorageService.reportsCacheBox)) {
                  Hive.box(LocalStorageService.reportsCacheBox)
                      .put('legacy_${id}_${entry.serial}', data);
                }
              } catch (_) {}
            }
          }
        } catch (_) {}
      });

      // 3. Local dispensary cache check (instant, 0 Firestore reads)
      try {
        if (Hive.isBoxOpen(LocalStorageService.dispensaryBox)) {
          final dBox = Hive.box(LocalStorageService.dispensaryBox);
          for (final key in dBox.keys) {
            final raw = dBox.get(key);
            if (raw is Map) {
              final d = Map<String, dynamic>.from(raw);
              final pCnic = (d['patientCnic'] ?? d['cnic'] ?? '').toString().trim();
              final pId = (d['patientId'] ?? '').toString().trim();
              if (allSearchIds.contains(pCnic) || allSearchIds.contains(pId)) {
                if (d['prescription'] is Map) {
                  final nested = Map<String, dynamic>.from(d['prescription'] as Map);
                  for (final k in nested.keys) {
                    d.putIfAbsent(k, () => nested[k]);
                  }
                }
                d['serial'] ??= d['id'] ?? key.toString();
                if (enriched.docBelongsToThisChild(d)) {
                  final entry = _HistoryEntry.fromMap(d, source: 'Dispensary');
                  if (entry != null && !seen.contains(entry.key)) {
                    seen.add(entry.key);
                    found.add(entry);
                  }
                }
              }
            }
          }
        }
      } catch (_) {}

      // 4. Local serial / queue entries fallback (same source as token status)
      try {
        if (Hive.isBoxOpen(LocalStorageService.entriesBox)) {
          final eBox = Hive.box(LocalStorageService.entriesBox);
          for (final key in eBox.keys) {
            final raw = eBox.get(key);
            if (raw is! Map) continue;
            final d = Map<String, dynamic>.from(raw);
            final pCnic = (d['patientCnic'] ?? d['cnic'] ?? '').toString().trim();
            final pId = (d['patientId'] ?? '').toString().trim();
            if ((allSearchIds.contains(pCnic) || allSearchIds.contains(pId)) && enriched.docBelongsToThisChild(d)) {
              d['serial'] ??= d['id'] ?? key.toString();
              final entry = _HistoryEntry.fromMap(d, source: 'Serials');
              if (entry != null && !seen.contains(entry.key)) {
                seen.add(entry.key);
                found.add(entry);
              }
            }
          }
        }
      } catch (_) {}

      // 5. Remote serials lookup (only when needed, final safety net)
      try {
        final serialRoot = FirebaseFirestore.instance
            .collection('branches')
            .doc(widget.branchId.toLowerCase())
            .collection('serials');
        final serialDates = await serialRoot.get().timeout(const Duration(seconds: 4));
        for (final dayDoc in serialDates.docs) {
          for (final queue in ['zakat', 'non-zakat', 'gmwf']) {
            final queueSnap = await dayDoc.reference.collection(queue).get().timeout(const Duration(seconds: 3));
            for (final doc in queueSnap.docs) {
              final data = Map<String, dynamic>.from(doc.data());
              data['serial'] ??= doc.id;
              final pCnic = (data['patientCnic'] ?? data['cnic'] ?? '').toString().trim();
              final pId = (data['patientId'] ?? '').toString().trim();
              if ((allSearchIds.contains(pCnic) || allSearchIds.contains(pId)) && enriched.docBelongsToThisChild(data)) {
                final entry = _HistoryEntry.fromMap(data, source: 'Serials');
                if (entry != null && !seen.contains(entry.key)) {
                  seen.add(entry.key);
                  found.add(entry);
                }
              }
            }
          }
        }
      } catch (_) {}

      await Future.wait(prescFutures);
    } catch (e) {
      debugPrint('[PatientHistory] Parallel fetch error: $e');
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
      return const Center(
        child: Text('Select a patient to view history',
            style: TextStyle(color: Colors.grey, fontSize: 16)),
      );
    }

    final patientName = widget.patientData?['name']?.toString() ??
        widget.patientCnic ?? 'Patient';

    if (widget.compactMode) {
      return _buildCompactLatestVisit(patientName);
    }

    final isDark = _getIsDark(context);
    final tealColor = isDark ? const Color(0xFF2DD4BF) : _teal;

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
                      style: TextStyle(fontSize: 11, color: isDark ? const Color(0xFF94A3B8) : Colors.grey[600])),
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
        Divider(height: 1, color: isDark ? const Color(0xFF334155) : Colors.grey.shade200),
        Expanded(
          child: _isLoading
              ? const PatientHistorySkeleton(count: 3)
              : _entries.isEmpty
                  ? Center(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(Icons.assignment_outlined,
                              size: 56, color: isDark ? const Color(0xFF475569) : Colors.grey[300]),
                          const SizedBox(height: 12),
                          Text(
                            'No prescription history found\nfor $patientName',
                            textAlign: TextAlign.center,
                            style: TextStyle(
                                color: isDark ? const Color(0xFF94A3B8) : Colors.grey[500], fontSize: 14),
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
                        onRepeatLast: null,
                      ),
                    ),
        ),
      ],
    );
  }

  Widget _buildCompactLatestVisit(String patientName) {
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(10, 8, 10, 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            const Icon(Icons.history_edu_rounded, color: _teal, size: 17),
            const SizedBox(width: 6),
            const Expanded(
              child: Text('Last Visit',
                  style: TextStyle(
                      fontSize: 13, fontWeight: FontWeight.w800, color: _teal)),
            ),
            if (!_isLoading && _entries.isNotEmpty)
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: _teal.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: _teal.withValues(alpha: 0.3)),
                ),
                child: Text(
                  '${_entries.length} visit${_entries.length == 1 ? '' : 's'}',
                  style: const TextStyle(
                      fontSize: 10, fontWeight: FontWeight.bold, color: _teal),
                ),
              ),
            const SizedBox(width: 6),
            GestureDetector(
              onTap: _isLoading ? null : _reload,
              child: const Icon(Icons.refresh_rounded, color: _teal, size: 17),
            ),
          ]),
          const SizedBox(height: 8),
          if (_isLoading)
            const Center(
              child: Padding(
                padding: EdgeInsets.symmetric(vertical: 24),
                child: CircularProgressIndicator(color: _teal, strokeWidth: 2),
              ),
            )
          else if (_entries.isEmpty)
            Container(
              padding: const EdgeInsets.symmetric(vertical: 20),
              alignment: Alignment.center,
              child: Column(children: [
                Icon(Icons.assignment_outlined, size: 36, color: Colors.grey[300]),
                const SizedBox(height: 8),
                Text('No visit history yet',
                    style: TextStyle(fontSize: 12, color: Colors.grey[400])),
              ]),
            )
          else
            _CompactLatestCard(
              entry: _entries.firstWhere(
                (e) => e.medicines.isNotEmpty || e.diagnosis.isNotEmpty || e.complaint.isNotEmpty,
                orElse: () => _entries.first,
              ),
              onRepeat: widget.onRepeatLast,
            ),
        ],
      ),
    );
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
  static const Color _teal = Color(0xFF00695C);

  List<_HistoryEntry> _entries   = [];
  bool                _isLoading = true;
  int                 _loadToken = 0;

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

    // Enrich from Firestore
    Map<String, dynamic>? fsPatient;
    for (final variant in _IdHelper.variants(
        identity.patientId.isNotEmpty ? identity.patientId : identity.cnic)) {
      if (variant.isEmpty) continue;
      try {
        final doc = await FirebaseFirestore.instance
            .collection('branches')
            .doc(widget.branchId.toLowerCase())
            .collection('patients')
            .doc(variant)
            .get()
            .timeout(const Duration(seconds: 8));
        if (doc.exists) { fsPatient = doc.data(); break; }
      } catch (_) {}
    }

    final enriched    = _PatientIdentity.fromMap({...widget.patientData, ...?fsPatient}, null);
    final searchIds   = enriched.searchIds;
    final List<_HistoryEntry> found = [];
    final Set<String> seen = {};

    // Instant Local Hive Scan (entries, dispensary, prescriptions)
    void scanLocalBox(String boxName, String sourceLabel) {
      try {
        if (!Hive.isBoxOpen(boxName)) return;
        final box = Hive.box(boxName);
        for (final key in box.keys) {
          final raw = box.get(key);
          if (raw is! Map) continue;
          final data = Map<String, dynamic>.from(raw);
          final hasData = data['medicines'] != null ||
              data['prescriptions'] != null ||
              data['prescription'] != null ||
              data['oralMedicines'] != null ||
              data['injectables'] != null ||
              data['diagnosis'] != null ||
              data['vitals'] != null ||
              data['receptionistVitals'] != null ||
              data['bp'] != null;
          if (!hasData) continue;

          bool belongs = false;
          for (final field in ['patientId', 'id', 'cnic', 'patientCnic', 'guardianCnic']) {
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

          if (data['prescription'] is Map) {
            final nested = Map<String, dynamic>.from(data['prescription'] as Map);
            for (final k in nested.keys) {
              data.putIfAbsent(k, () => nested[k]);
            }
          }

          data['serial'] ??= data['id'] ?? key.toString();
          final entry = _HistoryEntry.fromMap(data, source: sourceLabel);
          if (entry != null && seen.add(entry.serial)) found.add(entry);
        }
      } catch (e) {
        debugPrint('[PatientHistoryPage] $boxName scan error: $e');
      }
    }

    scanLocalBox(LocalStorageService.prescriptionsBox, 'Prescriptions');
    scanLocalBox(LocalStorageService.entriesBox, 'Token History');
    scanLocalBox(LocalStorageService.dispensaryBox, 'Dispensary');

    if (found.isNotEmpty && mounted && _loadToken == token) {
      found.sort((a, b) => b.date.compareTo(a.date));
      setState(() { _entries = List.from(found); _isLoading = false; });
    }

    if (_loadToken != token) return;

    // Legacy prescriptions path
    for (final id in searchIds) {
      if (id.isEmpty) continue;
      try {
        final query = await FirebaseFirestore.instance
            .collection('branches')
            .doc(widget.branchId.toLowerCase())
            .collection('prescriptions')
            .doc(id)
            .collection('prescriptions')
            .orderBy('createdAt', descending: true)
            .get()
            .timeout(const Duration(seconds: 4));
        for (final doc in query.docs) {
          if (_loadToken != token) return;
          final data = Map<String, dynamic>.from(doc.data());
          data['serial'] ??= doc.id;
          if (!enriched.docBelongsToThisChild(data)) continue;
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
    }

    if (_loadToken != token) return;

    found.sort((a, b) => b.date.compareTo(a.date));
    if (mounted && _loadToken == token) setState(() { _entries = found; _isLoading = false; });
  }

  @override
  Widget build(BuildContext context) {
    final name = widget.patientData['name']?.toString() ?? 'Patient';
    final id   = _PatientIdentity.fromMap(widget.patientData, null).key;

    return Scaffold(
      backgroundColor: const Color(0xFFF1F8E9),
      appBar: AppBar(
        backgroundColor: _teal,
        foregroundColor: Colors.white,
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text(name, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                Builder(builder: (_) {
                  final staffInfo = StaffPatientLinkService.getStaffInfoForPatient(
                    cnic: widget.patientData['cnic'] ?? widget.patientData['patientCnic'] ?? widget.patientData['guardianCnic'],
                    name: name,
                  );
                  if (staffInfo != null) {
                    return Padding(
                      padding: const EdgeInsets.only(left: 8),
                      child: StaffPatientLinkService.buildStaffBadge(staffInfo, isDark: true),
                    );
                  }
                  return const SizedBox.shrink();
                }),
              ],
            ),
            Text(id, style: const TextStyle(fontSize: 12, color: Colors.white70)),
          ],
        ),
        actions: [
          IconButton(
            icon: _isLoading
                ? const SizedBox(width: 20, height: 20,
                    child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2))
                : const Icon(Icons.refresh),
            onPressed: _isLoading ? null : _load,
          ),
        ],
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator(color: _teal))
          : _entries.isEmpty
              ? Center(child: Column(mainAxisSize: MainAxisSize.min, children: [
                  Icon(Icons.assignment_outlined, size: 64, color: Colors.grey[300]),
                  const SizedBox(height: 14),
                  Text('No visit history found for $name',
                      style: TextStyle(color: Colors.grey[500], fontSize: 15),
                      textAlign: TextAlign.center),
                ]))
              : ListView.builder(
                  padding: const EdgeInsets.all(14),
                  itemCount: _entries.length,
                  itemBuilder: (_, i) => _HistoryCard(
                    entry: _entries[i],
                    isLatest: i == 0,
                    onRepeatLast: (i == 0 && widget.onRepeatLast != null)
                        ? (raw) { widget.onRepeatLast!(raw); Navigator.pop(context); }
                        : null,
                  ),
                ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════════════
// COMPACT LATEST CARD  (unchanged UI, just wired to fixed data)
// ═══════════════════════════════════════════════════════════════════════════════

class _CompactLatestCard extends StatelessWidget {
  final _HistoryEntry entry;
  final void Function(Map<String, dynamic>)? onRepeat;
  static const Color _teal = Color(0xFF00695C);

  const _CompactLatestCard({required this.entry, this.onRepeat});

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
    final e       = entry;
    final dateStr = DateFormat('d MMM yyyy  •  hh:mm a').format(e.date);
    final oralMeds     = e.medicines.where((m) => !m.isInjectable).toList();
    final injectables  = e.medicines.where((m) => m.isInjectable).toList();

    return Container(
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF0F172A) : Colors.white,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: isDark ? const Color(0xFF334155) : _teal.withValues(alpha: 0.25), width: 1.2),
        boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: isDark ? 0.2 : 0.07), blurRadius: 10, offset: const Offset(0, 3))],
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Container(
          padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
          decoration: const BoxDecoration(
            color: _teal,
            borderRadius: BorderRadius.vertical(top: Radius.circular(13)),
          ),
          child: Wrap(
            crossAxisAlignment: WrapCrossAlignment.center,
            spacing: 8,
            runSpacing: 4,
            children: [
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.calendar_month_rounded, color: Colors.white70, size: 13),
                  const SizedBox(width: 5),
                  Text(dateStr, style: const TextStyle(color: Colors.white, fontSize: 11.5, fontWeight: FontWeight.w600)),
                ],
              ),
              if (e.doctorName.isNotEmpty)
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.person_outline_rounded, color: Colors.white60, size: 13),
                    const SizedBox(width: 4),
                    Text(e.doctorName, style: const TextStyle(color: Colors.white70, fontSize: 11)),
                  ],
                ),
              if (e.campName.isNotEmpty)
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  decoration: BoxDecoration(color: Colors.white.withValues(alpha: 0.2), borderRadius: BorderRadius.circular(4)),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.location_on_outlined, color: Colors.white, size: 11),
                      const SizedBox(width: 3),
                      Text(e.campName, style: const TextStyle(color: Colors.white, fontSize: 10, fontWeight: FontWeight.bold)),
                    ],
                  ),
                ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(color: Colors.white24, borderRadius: BorderRadius.circular(4)),
                child: Text('${e.days} Days', style: const TextStyle(color: Colors.white, fontSize: 10, fontWeight: FontWeight.bold)),
              ),
              if (e.isVitalsOnly) ...[
                const SizedBox(width: 4),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  decoration: BoxDecoration(color: Colors.amber.shade800, borderRadius: BorderRadius.circular(4)),
                  child: const Text('🩺 Vitals Only', style: TextStyle(color: Colors.white, fontSize: 10, fontWeight: FontWeight.bold)),
                ),
              ],
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            if (e.complaint.isNotEmpty) ...[
              _label('Condition', isDark), const SizedBox(height: 3),
              Text(e.complaint,
                  style: TextStyle(fontSize: 12.5, color: isDark ? const Color(0xFFE2E8F0) : Colors.black87),
                  maxLines: 2, overflow: TextOverflow.ellipsis),
              const SizedBox(height: 8),
            ],
            if (e.diagnosis.isNotEmpty) ...[
              _label('Diagnosis', isDark), const SizedBox(height: 3),
              Text(e.diagnosis,
                  style: TextStyle(fontSize: 12.5, color: isDark ? const Color(0xFFE2E8F0) : Colors.black87),
                  maxLines: 2, overflow: TextOverflow.ellipsis),
              const SizedBox(height: 8),
            ],
            if (e.vitals.isNotEmpty) ...[
              _label('Vitals', isDark), const SizedBox(height: 4),
              _buildCompactVitalsDisplay(e.vitals, isDark),
              const SizedBox(height: 8),
            ],
            if (oralMeds.isNotEmpty) ...[
              _label('Medicines', isDark), const SizedBox(height: 4),
              ...oralMeds.map((m) => _medTile(m, isInj: false, isDark: isDark)),
              const SizedBox(height: 4),
            ],
            if (injectables.isNotEmpty) ...[
              _label('Injectables', isDark), const SizedBox(height: 4),
              ...injectables.map((m) => _medTile(m, isInj: true, isDark: isDark)),
              const SizedBox(height: 4),
            ],
            if (e.labTests.isNotEmpty) ...[
              _label(e.raw['isPhysiotherapist'] == true ? 'Physiotherapies' : 'Lab Tests', isDark), const SizedBox(height: 4),
              Wrap(spacing: 5, runSpacing: 5,
                  children: e.labTests.map((t) => _labChip(t, isDark)).toList()),
              const SizedBox(height: 4),
            ],
            if (onRepeat != null) ...[
              const SizedBox(height: 6), Divider(height: 1, color: isDark ? const Color(0xFF334155) : Colors.grey.shade200), const SizedBox(height: 8),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton.icon(
                  onPressed: () => onRepeat!(e.raw),
                  icon: const Icon(Icons.repeat_rounded, size: 15),
                  label: const Text('Repeat This Prescription',
                      style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700)),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: _teal, foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(vertical: 10), elevation: 0,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                  ),
                ),
              ),
            ],
          ]),
        ),
      ]),
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
                  style: TextStyle(fontSize: 8.5, fontWeight: FontWeight.w800, color: isDark ? Colors.blue.shade300 : Colors.blue.shade800, letterSpacing: 0.5)),
            ],
          ),
          const SizedBox(height: 3),
          Wrap(spacing: 5, runSpacing: 4, children: [
            if (recVitals['bp'] != null && recVitals['bp'] != 'N/A') _vitalChip('BP', recVitals['bp'].toString(), Colors.blue.shade700),
            if (recVitals['temp'] != null && recVitals['temp'] != 'N/A') _vitalChip('Temp', '${recVitals['temp']}°C', Colors.orange.shade700),
            if (recVitals['sugar'] != null && recVitals['sugar'].toString().isNotEmpty) _vitalChip('Sugar', recVitals['sugar'].toString(), Colors.purple),
            if (recVitals['weight'] != null && recVitals['weight'] != 'N/A') _vitalChip('Wt', '${recVitals['weight']} kg', Colors.teal),
          ]),
          const SizedBox(height: 6),
          Row(
            children: [
              Text('DOC VITALS EDITED (${docVitals['updatedBy'] ?? 'Doctor'}):',
                  style: TextStyle(fontSize: 8.5, fontWeight: FontWeight.w800, color: isDark ? Colors.amber.shade300 : Colors.amber.shade900, letterSpacing: 0.5)),
            ],
          ),
          const SizedBox(height: 3),
          Wrap(spacing: 5, runSpacing: 4, children: [
            if (docVitals['bp'] != null && docVitals['bp'] != 'N/A') _vitalChip('BP', docVitals['bp'].toString(), const Color(0xFFE91E63)),
            if (docVitals['temp'] != null && docVitals['temp'] != 'N/A') _vitalChip('Temp', '${docVitals['temp']}°C', Colors.orange.shade700),
            if (docVitals['sugar'] != null && docVitals['sugar'].toString().isNotEmpty) _vitalChip('Sugar', docVitals['sugar'].toString(), Colors.purple),
            if (docVitals['weight'] != null && docVitals['weight'] != 'N/A') _vitalChip('Wt', '${docVitals['weight']} kg', Colors.teal),
          ]),
        ],
      );
    }

    return Wrap(spacing: 5, runSpacing: 5, children: [
      if (vitals['bp'] != null && vitals['bp'] != 'N/A') _vitalChip('BP', vitals['bp'].toString(), const Color(0xFFE91E63)),
      if (vitals['temp'] != null && vitals['temp'] != 'N/A') _vitalChip('Temp', '${vitals['temp']}${vitals['tempUnit'] ?? ''}', Colors.orange.shade700),
      if (vitals['sugar'] != null && vitals['sugar'].toString().isNotEmpty) _vitalChip('Sugar', vitals['sugar'].toString(), Colors.purple),
      if (vitals['weight'] != null && vitals['weight'] != 'N/A') _vitalChip('Wt', '${vitals['weight']} kg', Colors.teal),
    ]);
  }

  Widget _label(String text, bool isDark) => Text(text.toUpperCase(),
      style: TextStyle(fontSize: 9.5, fontWeight: FontWeight.w800, color: isDark ? const Color(0xFF2DD4BF) : _teal, letterSpacing: 0.8));

  Widget _vitalChip(String label, String value, Color color) => Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(20),
        border: Border.all(color: color.withValues(alpha: 0.35)),
      ),
      child: RichText(text: TextSpan(children: [
        TextSpan(text: '$label  ', style: TextStyle(fontSize: 10, fontWeight: FontWeight.w600, color: color.withValues(alpha: 0.85))),
        TextSpan(text: value,     style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold,  color: color)),
      ])));

  Widget _labChip(String text, bool isDark) => Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF451A03) : Colors.orange.shade50, borderRadius: BorderRadius.circular(20),
        border: Border.all(color: isDark ? const Color(0xFF9A3412) : Colors.orange.shade300),
      ),
      child: Text(text, style: TextStyle(fontSize: 11, color: isDark ? const Color(0xFFFDBA74) : Colors.orange.shade800, fontWeight: FontWeight.w600)));

  Widget _medTile(_MedEntry med, {required bool isInj, required bool isDark}) {
    final parts     = <String>[];
    if (med.dosage.isNotEmpty)    parts.add(med.dosage);
    if (med.frequency.isNotEmpty) parts.add(med.frequency);
    if (med.timing.isNotEmpty)    parts.add(med.timing);
    if (!isInj && med.meal.isNotEmpty) parts.add(med.meal);

    final badgeColor = isInj ? const Color(0xFF1565C0) : _teal;
    final badge = isInj ? 'Inj' :
        (med.abbrev.length > 3 ? med.abbrev.substring(0, 3) :
         med.abbrev.isNotEmpty ? med.abbrev : 'Med');

    return Container(
      margin: const EdgeInsets.only(bottom: 5),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
      decoration: BoxDecoration(
        color: isInj
            ? (isDark ? const Color(0xFF1E3A8A).withValues(alpha: 0.25) : const Color(0xFFE3F2FD))
            : (isDark ? const Color(0xFF1E293B) : _teal.withValues(alpha: 0.04)),
        borderRadius: BorderRadius.circular(9),
        border: Border.all(
            color: isDark
                ? const Color(0xFF334155)
                : (isInj ? const Color(0xFF90CAF9) : _teal.withValues(alpha: 0.15))),
      ),
      child: Row(children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
          decoration: BoxDecoration(color: badgeColor, borderRadius: BorderRadius.circular(5)),
          child: Text(badge, style: const TextStyle(color: Colors.white, fontSize: 9, fontWeight: FontWeight.bold)),
        ),
        const SizedBox(width: 8),
        Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(med.name,
              style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600, color: isDark ? Colors.white : Colors.black87),
              maxLines: 1, overflow: TextOverflow.ellipsis),
          if (parts.isNotEmpty)
            Text(parts.join(' · '),
                style: TextStyle(fontSize: 10.5, color: isDark ? const Color(0xFF94A3B8) : Colors.grey[600]),
                maxLines: 1, overflow: TextOverflow.ellipsis),
        ])),
      ]),
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════════════
// FULL HISTORY CARD (Ultra-Compact, High Information Density)
// ═══════════════════════════════════════════════════════════════════════════════

class _HistoryCard extends StatelessWidget {
  final _HistoryEntry entry;
  final bool isLatest;
  final void Function(Map<String, dynamic>)? onRepeatLast;

  const _HistoryCard({required this.entry, this.isLatest = false, this.onRepeatLast});

  static const Color _teal = Color(0xFF00695C);

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
    final dateStr = DateFormat('d MMM yyyy • hh:mm a').format(e.date);
    final oralMeds = e.medicines.where((m) => !m.isInjectable).toList();
    final injectables = e.medicines.where((m) => m.isInjectable).toList();

    final cardBg = isDark ? const Color(0xFF0F172A) : Colors.white;
    final cardBorder = isDark ? const Color(0xFF334155) : _teal.withValues(alpha: 0.25);
    final textPrimary = isDark ? const Color(0xFFF8FAFC) : const Color(0xFF1E293B);

    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      decoration: BoxDecoration(
        color: cardBg,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: cardBorder, width: 1.1),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: isDark ? 0.25 : 0.05),
            blurRadius: 6,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // ── Compact Header ──
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            decoration: BoxDecoration(
              color: isDark ? const Color(0xFF1E293B) : const Color(0xFF065F46),
              borderRadius: const BorderRadius.vertical(top: Radius.circular(11)),
            ),
            child: Row(
              children: [
                const Icon(Icons.calendar_today_rounded, color: Colors.white, size: 12),
                const SizedBox(width: 5),
                Text(
                  dateStr,
                  style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.bold),
                ),
                const SizedBox(width: 6),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1.5),
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Text(
                    '${e.days}d',
                    style: const TextStyle(color: Colors.white, fontSize: 10, fontWeight: FontWeight.bold),
                  ),
                ),
                if (e.doctorName.isNotEmpty) ...[
                  const SizedBox(width: 6),
                  Flexible(
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1.5),
                      decoration: BoxDecoration(
                        color: Colors.white.withValues(alpha: 0.15),
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: Text(
                        'Dr. ${e.doctorName}',
                        style: const TextStyle(color: Colors.white, fontSize: 10.5, fontWeight: FontWeight.w600),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ),
                ],
                const Spacer(),
                Text(
                  '#${e.serial}',
                  style: TextStyle(
                    color: isDark ? const Color(0xFF94A3B8) : Colors.white70,
                    fontSize: 10.5,
                    fontWeight: FontWeight.w500,
                  ),
                ),
                if (isLatest) ...[
                  const SizedBox(width: 6),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1.5),
                    decoration: BoxDecoration(
                      color: const Color(0xFF10B981),
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: const Text(
                      'LATEST',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 9,
                        fontWeight: FontWeight.w900,
                        letterSpacing: 0.5,
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),

          // ── Compact Body ──
          Padding(
            padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Condition & Diagnosis Inline (Distinct harmonious colors)
                if (e.complaint.isNotEmpty || e.diagnosis.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 6),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        if (e.complaint.isNotEmpty)
                          Expanded(
                            child: _compactInlineBlock(
                              label: 'Condition',
                              value: e.complaint,
                              icon: Icons.medical_services_outlined,
                              accentColor: isDark ? const Color(0xFF38BDF8) : const Color(0xFF0284C7),
                              bgColor: isDark ? const Color(0xFF082F49).withValues(alpha: 0.35) : const Color(0xFFF0F9FF),
                              borderColor: isDark ? const Color(0xFF0369A1).withValues(alpha: 0.5) : const Color(0xFFBAE6FD),
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
                              accentColor: isDark ? const Color(0xFF34D399) : const Color(0xFF059669),
                              bgColor: isDark ? const Color(0xFF064E3B).withValues(alpha: 0.3) : const Color(0xFFECFDF5),
                              borderColor: isDark ? const Color(0xFF047857).withValues(alpha: 0.5) : const Color(0xFFA7F3D0),
                              textPrimary: textPrimary,
                            ),
                          ),
                      ],
                    ),
                  ),

                // Vitals
                if (e.vitals.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 6),
                    child: _buildCompactVitalsRow(e.vitals, isDark),
                  ),

                // Medicines Wrap
                if (oralMeds.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 6),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
                          margin: const EdgeInsets.only(right: 6, top: 1),
                          decoration: BoxDecoration(
                            color: isDark ? const Color(0xFF0D9488).withValues(alpha: 0.25) : _teal.withValues(alpha: 0.12),
                            borderRadius: BorderRadius.circular(5),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(Icons.medication_rounded, size: 11, color: isDark ? const Color(0xFF2DD4BF) : _teal),
                              const SizedBox(width: 3),
                              Text(
                                'Medicines',
                                style: TextStyle(fontSize: 10, fontWeight: FontWeight.bold, color: isDark ? const Color(0xFF2DD4BF) : _teal),
                              ),
                            ],
                          ),
                        ),
                        Expanded(
                          child: Wrap(
                            spacing: 6,
                            runSpacing: 4,
                            children: oralMeds.map((m) => _compactMedChip(m, isDark)).toList(),
                          ),
                        ),
                      ],
                    ),
                  ),

                // Injectables Wrap
                if (injectables.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 6),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
                          margin: const EdgeInsets.only(right: 6, top: 1),
                          decoration: BoxDecoration(
                            color: isDark ? const Color(0xFF1E3A8A).withValues(alpha: 0.4) : Colors.blue.shade100,
                            borderRadius: BorderRadius.circular(5),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              const Icon(Icons.vaccines_rounded, size: 11, color: Color(0xFF2563EB)),
                              const SizedBox(width: 3),
                              Text(
                                'Injectables',
                                style: TextStyle(fontSize: 10, fontWeight: FontWeight.bold, color: isDark ? const Color(0xFF93C5FD) : Colors.blue.shade900),
                              ),
                            ],
                          ),
                        ),
                        Expanded(
                          child: Wrap(
                            spacing: 6,
                            runSpacing: 4,
                            children: injectables.map((m) => _compactInjChip(m, isDark)).toList(),
                          ),
                        ),
                      ],
                    ),
                  ),

                // Lab tests / Physiotherapies
                if (e.labTests.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 4),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
                          margin: const EdgeInsets.only(right: 6, top: 1),
                          decoration: BoxDecoration(
                            color: isDark ? const Color(0xFF451A03) : Colors.orange.shade100,
                            borderRadius: BorderRadius.circular(5),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(
                                e.raw['isPhysiotherapist'] == true ? Icons.accessibility_rounded : Icons.science_rounded,
                                size: 11,
                                color: isDark ? const Color(0xFFFB923C) : Colors.orange.shade900,
                              ),
                              const SizedBox(width: 3),
                              Text(
                                e.raw['isPhysiotherapist'] == true ? 'Physiotherapy' : 'Lab Tests',
                                style: TextStyle(fontSize: 10, fontWeight: FontWeight.bold, color: isDark ? const Color(0xFFFB923C) : Colors.orange.shade900),
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
                                color: isDark ? const Color(0xFF451A03).withValues(alpha: 0.7) : Colors.orange.shade50,
                                borderRadius: BorderRadius.circular(6),
                                border: Border.all(color: isDark ? const Color(0xFF9A3412) : Colors.orange.shade300),
                              ),
                              child: Text(
                                t,
                                style: TextStyle(
                                  fontSize: 11,
                                  fontWeight: FontWeight.bold,
                                  color: isDark ? const Color(0xFFFDBA74) : Colors.orange.shade900,
                                ),
                              ),
                            )).toList(),
                          ),
                        ),
                      ],
                    ),
                  ),

                if (onRepeatLast != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: SizedBox(
                      width: double.infinity,
                      child: ElevatedButton.icon(
                        onPressed: () => onRepeatLast!(entry.raw),
                        icon: const Icon(Icons.repeat, size: 14),
                        label: const Text('Repeat This Prescription', style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold)),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: isDark ? const Color(0xFF0D9488) : _teal,
                          foregroundColor: Colors.white,
                          padding: const EdgeInsets.symmetric(vertical: 6),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                          elevation: 0,
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
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
      chips.add(_microVitalChip('BP', bp.toString(), const Color(0xFFF43F5E), isDark));
    }

    final temp = merged['temp'] ?? merged['temperature'] ?? merged['Temp'];
    if (temp != null && temp.toString().trim().isNotEmpty && temp != 'N/A') {
      chips.add(_microVitalChip('Temp', '${temp.toString().replaceAll('°C', '')}°C', const Color(0xFFFB923C), isDark));
    }

    final sugar = merged['sugar'] ?? merged['bloodSugar'] ?? merged['Sugar'] ?? merged['glucose'] ?? merged['rbs'];
    if (sugar != null && sugar.toString().trim().isNotEmpty && sugar != 'N/A') {
      chips.add(_microVitalChip('Sugar', sugar.toString(), const Color(0xFFC084FC), isDark));
    }

    final weight = merged['weight'] ?? merged['wt'] ?? merged['Weight'];
    if (weight != null && weight.toString().trim().isNotEmpty && weight != 'N/A') {
      chips.add(_microVitalChip('Weight', '${weight.toString().replaceAll('kg', '')}kg', const Color(0xFF2DD4BF), isDark));
    }

    final pulse = merged['pulse'] ?? merged['heartRate'] ?? merged['spo2'] ?? merged['hr'];
    if (pulse != null && pulse.toString().trim().isNotEmpty && pulse != 'N/A') {
      chips.add(_microVitalChip('Pulse', pulse.toString(), const Color(0xFF38BDF8), isDark));
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

    final bg = isDark ? const Color(0xFF1E293B) : const Color(0xFFF1F5F9);
    final border = isDark ? const Color(0xFF334155) : Colors.grey.shade300;
    final textNameColor = isDark ? const Color(0xFFF8FAFC) : const Color(0xFF0F172A);
    final textPartsColor = isDark ? const Color(0xFF94A3B8) : Colors.grey.shade700;

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
              color: isDark ? const Color(0xFF0D9488) : _teal,
              borderRadius: BorderRadius.circular(4),
            ),
            child: Text(
              med.abbrev.isNotEmpty ? med.abbrev : 'Med',
              style: const TextStyle(color: Colors.white, fontSize: 9, fontWeight: FontWeight.bold),
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
    final bg = isDark ? const Color(0xFF1E3A8A).withValues(alpha: 0.3) : Colors.blue.shade50;
    final border = isDark ? const Color(0xFF3B82F6).withValues(alpha: 0.35) : Colors.blue.shade200;
    final textNameColor = isDark ? const Color(0xFFF8FAFC) : Colors.blue.shade900;

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
          const Icon(Icons.vaccines, size: 12, color: Color(0xFF2563EB)),
          const SizedBox(width: 5),
          Text(
            med.name,
            style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: textNameColor),
          ),
          const SizedBox(width: 4),
          Text(
            'Qty: ${med.quantity}',
            style: TextStyle(fontSize: 10.5, color: isDark ? const Color(0xFF93C5FD) : Colors.blue.shade700, fontWeight: FontWeight.w600),
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

    final meds = <_MedEntry>[];
    void addMedList(dynamic list) {
      if (list is! List) return;
      for (final m in list) {
        if (m is! Map) continue;
        final name = (m['name'] ?? m['displayName'] ?? m['medicineName'] ?? '').toString().trim();
        if (name.isEmpty) continue;
        if (meds.any((existing) => existing.name.toLowerCase() == name.toLowerCase())) continue;
        meds.add(_MedEntry(
          name:      name,
          type:      m['type']?.toString() ?? '',
          timing:    m['timing']?.toString() ?? '',
          meal:      m['meal']?.toString() ?? '',
          dosage:    m['dosage']?.toString() ?? m['dose']?.toString() ?? '',
          quantity:  (m['quantity'] is num ? (m['quantity'] as num).toInt() : int.tryParse(m['quantity']?.toString() ?? '') ?? 1),
          frequency: m['frequency']?.toString() ?? '',
        ));
      }
    }

    addMedList(data['prescriptions']);
    addMedList(data['medicines']);
    addMedList(data['oralMedicines']);
    addMedList(data['injectables']);
    addMedList(data['items']);
    addMedList(data['prescriptionList']);
    addMedList(data['prescriptionsList']);
    if (data['prescription'] is Map) {
      final p = data['prescription'] as Map;
      addMedList(p['prescriptions']);
      addMedList(p['medicines']);
      addMedList(p['oralMedicines']);
      addMedList(p['injectables']);
      addMedList(p['items']);
    }

    String extractedDiagnosis = (data['diagnosis'] ??
        data['patientDiagnosis'] ??
        data['finalDiagnosis'] ??
        data['provisionalDiagnosis'] ??
        (data['prescription'] is Map ? data['prescription']['diagnosis'] : null) ??
        '')
        .toString()
        .trim();

    String extractedComplaint = (data['complaint'] ??
        data['condition'] ??
        data['patientCondition'] ??
        data['reason'] ??
        data['symptoms'] ??
        data['chiefComplaint'] ??
        (data['prescription'] is Map ? (data['prescription']['complaint'] ?? data['prescription']['condition']) : null) ??
        '')
        .toString()
        .trim();

    String extractedDoctor = (data['doctorName'] ??
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
        if (Hive.isBoxOpen(LocalStorageService.dispensaryBox)) {
          final dBox = Hive.box(LocalStorageService.dispensaryBox);
          final dRaw = dBox.get(serial) ?? dBox.get(serial.toLowerCase()) ?? dBox.get(serial.toUpperCase());
          if (dRaw is Map) {
            addMedList(dRaw['medicines']);
            addMedList(dRaw['prescriptions']);
            addMedList(dRaw['oralMedicines']);
            addMedList(dRaw['injectables']);
            if (dRaw['prescription'] is Map) {
              addMedList(dRaw['prescription']['medicines']);
              addMedList(dRaw['prescription']['prescriptions']);
              if (extractedDiagnosis.isEmpty) extractedDiagnosis = (dRaw['prescription']['diagnosis'] ?? '').toString();
              if (extractedComplaint.isEmpty) extractedComplaint = (dRaw['prescription']['complaint'] ?? dRaw['prescription']['condition'] ?? '').toString();
            }
            if (extractedDiagnosis.isEmpty) extractedDiagnosis = (dRaw['diagnosis'] ?? '').toString();
            if (extractedDoctor.isEmpty) extractedDoctor = (dRaw['doctorName'] ?? dRaw['prescribedBy'] ?? '').toString();
          }
        }
        if (meds.isEmpty && Hive.isBoxOpen(LocalStorageService.prescriptionsBox)) {
          final prBox = Hive.box(LocalStorageService.prescriptionsBox);
          final prRaw = prBox.get(serial) ?? prBox.get(serial.toLowerCase()) ?? prBox.get(serial.toUpperCase());
          if (prRaw is Map) {
            addMedList(prRaw['medicines']);
            addMedList(prRaw['prescriptions']);
            if (prRaw['prescription'] is Map) {
              addMedList(prRaw['prescription']['medicines']);
              addMedList(prRaw['prescription']['prescriptions']);
            }
            if (extractedDiagnosis.isEmpty) extractedDiagnosis = (prRaw['diagnosis'] ?? '').toString();
            if (extractedDoctor.isEmpty) extractedDoctor = (prRaw['doctorName'] ?? prRaw['prescribedBy'] ?? '').toString();
          }
        }
      } catch (_) {}
    }

    final labs = <String>[];
    void addLabList(dynamic list) {
      if (list is! List) return;
      for (final l in list) {
        final name = (l is Map ? (l['name'] ?? l['testName'] ?? l['title']) : l)?.toString().trim() ?? '';
        if (name.isNotEmpty && !labs.contains(name)) labs.add(name);
      }
    }

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
      raw:       data,
      source:    source,
      days:      (data['daysOfMedicine'] is num ? (data['daysOfMedicine'] as num).toInt() : int.tryParse(data['daysOfMedicine']?.toString() ?? '') ?? 1),
      campId:    cId,
      campName:  cName,
      isVitalsOnly: isVitalsOnly,
    );
  }

  Color get sourceColor {
    if (source.contains('Hive'))         return Colors.blue;
    if (source.contains('Dispensary'))   return Colors.teal;
    if (source.contains('Prescriptions')) return Colors.green;
    return Colors.grey;
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

  const _MedEntry({
    required this.name, required this.type, required this.timing,
    required this.meal, required this.dosage, required this.quantity,
    required this.frequency,
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
}
