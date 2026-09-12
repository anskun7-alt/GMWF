// lib/pages/dispensary/dispensar/medicine_ledger.dart

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:intl/intl.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:gmwf/services/local_storage_service.dart';
import 'package:gmwf/services/camp_session_service.dart';
import 'package:gmwf/services/master_proforma_service.dart';
import 'package:gmwf/widgets/global_module_wrapper.dart';
import '../../../realtime/realtime_manager.dart';
import 'dart:async';

class MedicineLedgerPage extends StatefulWidget {
  final String branchId;
  final Map<String, dynamic>? initialMedicine;
  final bool isEmbedded;

  const MedicineLedgerPage({
    super.key,
    required this.branchId,
    this.initialMedicine,
    this.isEmbedded = false,
  });

  @override
  State<MedicineLedgerPage> createState() => _MedicineLedgerPageState();
}

class _MedicineLedgerPageState extends State<MedicineLedgerPage> {
  // ── Palette ───────────────────────────────────────────────────────────────
  static const _teal       = Color(0xFF00695C);
  static const _tealDark   = Color(0xFF004D40);
  static const _emerald    = Color(0xFF00875A);
  static const _indigo     = Color(0xFF4338CA);
  static const _amber      = Color(0xFFD97706);
  static const _red        = Color(0xFFD32F2F);
  static const _bg         = Color(0xFFF0F4F4);
  static const _white      = Colors.white;
  static const _textDark   = Color(0xFF1B2631);
  static const _textMid    = Color(0xFF4A5568);
  static const _textLight  = Color(0xFF718096);

  bool get _isDark {
    try {
      if (Hive.isBoxOpen('app_settings')) {
        final dark = Hive.box('app_settings').get('is_dark_mode');
        if (dark != null) return dark == true;
      }
    } catch (_) {}
    return Theme.of(context).brightness == Brightness.dark;
  }

  bool get _hasMultiCamps => CampSessionService.getCampsForBranch(widget.branchId).isNotEmpty;

  // ── State ──────────────────────────────────────────────────────────────────
  Map<String, dynamic>? _selectedMed;
  bool _isLoading = false;
  Map<String, dynamic>? _reportData;
  List<Map<String, dynamic>> _allMedicines = [];
  bool _isSearchingMeds = false;
  DateTime _selectedMonth = DateTime.now();
  String _selectedCampFilter = 'all';

  @override
  void initState() {
    super.initState();
    _selectedMed = widget.initialMedicine;
    if (_hasMultiCamps) {
      final active = CampSessionService.getActiveCamp(widget.branchId);
      if (active != null && active.isNotEmpty && active != 'all') {
        _selectedCampFilter = active;
      }
    }
    _initData();
  }

  Future<void> _initData() async {
    await _loadMedicines();
    _loadReport();
  }

  // ── Data Fetching ──────────────────────────────────────────────────────────
  Future<void> _loadMedicines() async {
    setState(() => _isSearchingMeds = true);
    try {
      final items = LocalStorageService.getAllLocalStockItems(
        branchId: widget.branchId,
        dispensaryId: _selectedCampFilter != 'all' ? _selectedCampFilter : null,
        filterByCamp: _selectedCampFilter != 'all',
      );
      setState(() {
        _allMedicines = items.map((m) {
          final copy = Map<String, dynamic>.from(m);
          final isCustom = copy['isCustomized'] == true || copy['userEdited'] == true;
          if (!isCustom) {
            final clean = MasterProformaService.cleanBrandToFormula(copy['name'] ?? copy['formula'] ?? '');
            if (clean.isNotEmpty) {
              copy['name'] = clean;
              copy['formula'] = clean;
            }
          }
          final rawCamp = (copy['campId'] ?? copy['dispensaryId'] ?? '').toString().toLowerCase();
          if (rawCamp.contains('kapay')) {
            copy['campId'] = 'saddar';
            copy['dispensaryId'] = 'saddar';
          }
          return copy;
        }).toList()
          ..sort((a, b) => (a['name'] ?? '').toString().toLowerCase().compareTo((b['name'] ?? '').toString().toLowerCase()));
        _isSearchingMeds = false;
      });
    } catch (e) {
      debugPrint('Error loading medicines: $e');
      setState(() => _isSearchingMeds = false);
    }
  }

  String _cacheKey() {
    final monthStr = DateFormat('yyyy-MM').format(_selectedMonth);
    final campStr = _selectedCampFilter.toLowerCase();
    if (_selectedMed == null) {
      return '${widget.branchId}_${campStr}_all_meds_$monthStr';
    }
    final medId = _selectedMed!['id'] ?? _selectedMed!['docId'] ?? _selectedMed!['medicineId'] ?? _selectedMed!['name'];
    return '${widget.branchId}_${campStr}_${medId}_$monthStr';
  }

  Future<void> _loadReport({bool forceRecalculate = false}) async {
    setState(() => _isLoading = true);

    final key = _cacheKey();
    if (!forceRecalculate) {
      final cached = Hive.box(LocalStorageService.reportsCacheBox).get(key);
      if (cached != null) {
        setState(() {
          _reportData = Map<String, dynamic>.from(cached as Map);
          _isLoading = false;
        });
        return;
      }
    }

    try {
      final medId = _selectedMed != null ? (_selectedMed!['id'] ?? _selectedMed!['docId'] ?? '') : '';
      final selectedType = _selectedMed != null ? (_selectedMed!['type'] ?? '').toString().toLowerCase() : '';
      final isSelectedMedSyringe = _selectedMed != null ? selectedType.contains('syringe') : false;
      final selectedYear = _selectedMonth.year;
      final selectedMonthVal = _selectedMonth.month;
      final targetCamp = _selectedCampFilter.toLowerCase().trim();

      // 1. Query Logs (Additions, Registrations, Edits) from inventory_log
      final List<Future<QuerySnapshot>> logQueries = [];
      final startOfMonth = DateTime(selectedYear, selectedMonthVal, 1);
      final endOfMonth = DateTime(selectedYear, selectedMonthVal + 1, 0, 23, 59, 59, 999);

      if (!RealtimeManager().isConnected) {
        if (_selectedMed != null) {
          if (medId.isNotEmpty) {
            logQueries.add(FirebaseFirestore.instance
                .collection('branches')
                .doc(widget.branchId)
                .collection('inventory_log')
                .where('medicineId', isEqualTo: medId)
                .where('timestamp', isGreaterThanOrEqualTo: Timestamp.fromDate(startOfMonth))
                .where('timestamp', isLessThanOrEqualTo: Timestamp.fromDate(endOfMonth))
                .get());
            logQueries.add(FirebaseFirestore.instance
                .collection('branches')
                .doc(widget.branchId)
                .collection('inventory_log')
                .where('docId', isEqualTo: medId)
                .where('timestamp', isGreaterThanOrEqualTo: Timestamp.fromDate(startOfMonth))
                .where('timestamp', isLessThanOrEqualTo: Timestamp.fromDate(endOfMonth))
                .get());
            logQueries.add(FirebaseFirestore.instance
                .collection('branches')
                .doc(widget.branchId)
                .collection('inventory_log')
                .where('newId', isEqualTo: medId)
                .where('timestamp', isGreaterThanOrEqualTo: Timestamp.fromDate(startOfMonth))
                .where('timestamp', isLessThanOrEqualTo: Timestamp.fromDate(endOfMonth))
                .get());
            logQueries.add(FirebaseFirestore.instance
                .collection('branches')
                .doc(widget.branchId)
                .collection('inventory_log')
                .where('oldId', isEqualTo: medId)
                .where('timestamp', isGreaterThanOrEqualTo: Timestamp.fromDate(startOfMonth))
                .where('timestamp', isLessThanOrEqualTo: Timestamp.fromDate(endOfMonth))
                .get());
          } else {
            logQueries.add(FirebaseFirestore.instance
                .collection('branches')
                .doc(widget.branchId)
                .collection('inventory_log')
                .where('medicineName', isEqualTo: _selectedMed!['name'])
                .where('timestamp', isGreaterThanOrEqualTo: Timestamp.fromDate(startOfMonth))
                .where('timestamp', isLessThanOrEqualTo: Timestamp.fromDate(endOfMonth))
                .get());
          }
        } else {
          logQueries.add(FirebaseFirestore.instance
              .collection('branches')
              .doc(widget.branchId)
              .collection('inventory_log')
              .where('timestamp', isGreaterThanOrEqualTo: Timestamp.fromDate(startOfMonth))
              .where('timestamp', isLessThanOrEqualTo: Timestamp.fromDate(endOfMonth))
              .get());
        }
      }

      final snapshots = await Future.wait(logQueries);
      final Map<String, DocumentSnapshot> uniqueDocs = {};
      for (final snap in snapshots) {
        for (final doc in snap.docs) {
          uniqueDocs[doc.id] = doc;
        }
      }

      double totalAdded = 0;
      double totalAdjusted = 0;
      List<Map<String, dynamic>> logs = [];

      for (final doc in uniqueDocs.values) {
        final d = doc.data() as Map<String, dynamic>;

        // Camp matching filter
        if (targetCamp != 'all' && targetCamp.isNotEmpty) {
          final itemCamp = (d['dispensaryId'] ?? d['campId'])?.toString().toLowerCase().trim();
          if (itemCamp != null && itemCamp.isNotEmpty && itemCamp != 'all' && itemCamp != targetCamp) {
            continue;
          }
        }

        final q = d['quantityAdded'];
        final qty = (q is num ? q.toDouble() : double.tryParse(q?.toString() ?? '') ?? 0.0);
        final ts = (d['timestamp'] as Timestamp?)?.toDate() ?? DateTime.now();
        final action = d['action'] ?? '';
        final medName = d['medicineName'] ?? d['name'] ?? 'Unknown Medicine';

        if (ts.year == selectedYear && ts.month == selectedMonthVal) {
          final campTag = (d['dispensaryTag'] ?? d['dispensaryId'] ?? d['campId'] ?? '').toString();
          if (action == 'edit_stock' || action == 'medicine_edited') {
            totalAdjusted += qty;
            logs.add({
              'type': qty >= 0 ? 'added' : 'removed',
              'qty': qty.abs(),
              'date': ts.toIso8601String(),
              'user': d['performedByName'] ?? d['performedBy'] ?? 'Admin',
              'msg': '${action == 'medicine_edited' ? 'Medicine Edited' : 'Manual Adjustment'} ($medName)',
              'medicineName': medName,
              'campTag': campTag,
            });
          } else {
            totalAdded += qty;
            final isProforma = action == 'add_proforma_stock' || action == 'add_from_proforma' || action == 'proforma_add' || action == 'proforma_import';
            final isReg = action == 'medicine_registered_directly' || action == 'medicine_registered';
            final actionLabel = isProforma ? 'Universal Proforma Import' : (isReg ? 'Initial Registration' : 'Restock');
            final performer = d['performedByName'] ?? d['performedBy'] ?? 'Unknown';
            final performerRole = d['performedByRole'] != null ? ' (${d['performedByRole']})' : '';

            logs.add({
              'type': 'added',
              'qty': qty,
              'date': ts.toIso8601String(),
              'user': '$performer$performerRole',
              'msg': '$actionLabel ($medName)',
              'medicineName': medName,
              'details': d['details'] ?? '',
              'isProforma': isProforma,
              'campTag': campTag,
            });
          }
        }
      }

      // Merge offline local inventory logs from Hive
      try {
        final localAuditLogs = LocalStorageService.getLocalInventoryLogs(
          branchId: widget.branchId,
          medicineId: _selectedMed != null ? medId : null,
        );
        for (final d in localAuditLogs) {
          // Camp filter check
          if (targetCamp != 'all' && targetCamp.isNotEmpty) {
            final itemCamp = (d['dispensaryId'] ?? d['campId'])?.toString().toLowerCase().trim();
            if (itemCamp != null && itemCamp.isNotEmpty && itemCamp != 'all' && itemCamp != targetCamp) {
              continue;
            }
          }

          final q = d['quantityAdded'] ?? d['quantity'];
          final qty = (q is num ? q.toDouble() : double.tryParse(q?.toString() ?? '') ?? 0.0);
          final rawTs = d['createdAt'] ?? d['timestamp'];
          final ts = rawTs is DateTime ? rawTs : (DateTime.tryParse(rawTs?.toString() ?? '') ?? DateTime.now());
          final action = d['action'] ?? '';
          final medName = d['medicineName'] ?? d['name'] ?? 'Unknown Medicine';

          if (ts.year == selectedYear && ts.month == selectedMonthVal) {
            final isProforma = action == 'add_proforma_stock' || action == 'add_from_proforma' || action == 'proforma_add' || action == 'proforma_import';
            final isReg = action == 'medicine_registered_directly' || action == 'medicine_registered';
            final actionLabel = isProforma ? 'Universal Proforma Import' : (isReg ? 'Initial Registration' : 'Restock');
            final performer = d['performedByName'] ?? d['performedBy'] ?? 'Unknown';
            final performerRole = d['performedByRole'] != null ? ' (${d['performedByRole']})' : '';
            final campTag = (d['dispensaryTag'] ?? d['dispensaryId'] ?? d['campId'] ?? '').toString();

            final alreadyPresent = logs.any((l) =>
                l['medicineName'] == medName &&
                (l['qty'] as num?)?.toDouble() == qty &&
                (DateTime.parse(l['date']).difference(ts).inMinutes.abs() < 5));

            if (!alreadyPresent) {
              totalAdded += qty;
              logs.add({
                'type': 'added',
                'qty': qty,
                'date': ts.toIso8601String(),
                'user': '$performer$performerRole',
                'msg': '$actionLabel ($medName)',
                'medicineName': medName,
                'details': d['details'] ?? '',
                'isProforma': isProforma,
                'campTag': campTag,
              });
            }
          }
        }
      } catch (_) {}

      // 2. Query Removals (Dispensing) over the selected month
      final List<DateTime> daysToFetch = [];
      DateTime start = DateTime(selectedYear, selectedMonthVal, 1);
      DateTime end = DateTime(selectedYear, selectedMonthVal + 1, 1).subtract(const Duration(seconds: 1));
      final today = DateTime.now();
      if (end.isAfter(today)) end = today;

      for (DateTime curr = start; curr.isBefore(end.add(const Duration(seconds: 1))); curr = curr.add(const Duration(days: 1))) {
        daysToFetch.add(curr);
      }

      double totalRemoved = 0;

      final fetchFutures = daysToFetch.map((curr) async {
        final dateKey = DateFormat('ddMMyy').format(curr);
        double dayTotalRemoved = 0;
        List<Map<String, dynamic>> dayLogs = [];

        // 1. Try local dispensary records first
        final localRecords = <Map<String, dynamic>>[];
        if (Hive.isBoxOpen(LocalStorageService.dispensaryBox)) {
          final box = Hive.box(LocalStorageService.dispensaryBox);
          for (final k in box.keys) {
            if (k.toString().startsWith('${widget.branchId}_$dateKey')) {
              final v = box.get(k);
              if (v is Map) localRecords.add(Map<String, dynamic>.from(v));
            }
          }
        }

        // 2. Query Firestore records (serials + legacy dispensary fallback) only if no local records and offline from LAN
        final firestoreRecords = <Map<String, dynamic>>[];
        if (localRecords.isEmpty && !RealtimeManager().isConnected) {
          try {
            final branchDoc = FirebaseFirestore.instance
                .collection('branches')
                .doc(widget.branchId);

            // Check serials collection for the date
            final serialsDateSnap = await branchDoc
                .collection('serials')
                .doc(dateKey)
                .get();
            
            if (serialsDateSnap.exists) {
              for (final qType in ['general', 'emergency', 'fasttrack', 'regular', 'zakat', 'non-zakat', 'gmwf']) {
                try {
                  final qSnap = await branchDoc
                      .collection('serials')
                      .doc(dateKey)
                      .collection(qType)
                      .where('dispenseStatus', isEqualTo: 'dispensed')
                      .get();
                  for (final doc in qSnap.docs) {
                    final data = doc.data();
                    data['serial'] ??= doc.id;
                    // Normalize prescriptions array from serial document structure
                    if (data['prescription'] is Map && data['prescriptions'] == null) {
                      final rxMap = data['prescription'] as Map;
                      data['prescriptions'] = rxMap['medicines'] ?? rxMap['prescriptions'] ?? [];
                    }
                    firestoreRecords.add(data);
                  }
                } catch (_) {}
              }
            }

            // Legacy dispensary collection fallback if serials had no records
            if (firestoreRecords.isEmpty) {
              final dailySnap = await branchDoc
                  .collection('dispensary')
                  .doc(dateKey)
                  .collection(dateKey)
                  .get();
              for (final doc in dailySnap.docs) {
                firestoreRecords.add(doc.data());
              }
            }
          } catch (_) {}
        }

        final combinedDaily = <String, Map<String, dynamic>>{};
        for (final r in localRecords) {
          final s = r['serial']?.toString() ?? '';
          if (s.isNotEmpty) combinedDaily[s] = r;
        }
        for (final r in firestoreRecords) {
          final s = r['serial']?.toString() ?? '';
          if (s.isNotEmpty) combinedDaily[s] = r;
        }

        for (final d in combinedDaily.values) {
          final serial = d['serial']?.toString() ?? '';

          // Camp filter check
          if (targetCamp != 'all' && targetCamp.isNotEmpty) {
            final matches = CampSessionService.matchesCamp(
              selectedCamp: targetCamp,
              dispensaryId: d['dispensaryId']?.toString(),
              campId: d['campId']?.toString(),
              dispensaryTag: d['dispensaryTag']?.toString(),
              serial: serial,
            );
            if (!matches) continue;
          }

          final prescriptions = (d['prescriptions'] as List?) ?? [];
          for (final rx in prescriptions) {
            if (rx is! Map) continue;
            bool isMatch = false;
            final rxName = rx['name'] ?? '';

            if (_selectedMed != null) {
              final String rxId = (rx['inventoryId'] ?? rx['medicineId'] ?? rx['id'] ?? '').toString();
              if (medId.isNotEmpty && rxId.isNotEmpty && rxId == medId) {
                isMatch = true;
              } else {
                final nameMatch = rx['name'] == _selectedMed!['name'];
                final typeMatch = rx['type'] == _selectedMed!['type'];
                final doseMatch = rx['dose'] == _selectedMed!['dose'];
                isMatch = nameMatch && typeMatch && doseMatch;
              }
            } else {
              isMatch = true;
            }

            if (isMatch) {
              final dQty = d['daysOfMedicine'];
              final days = (dQty is num ? dQty.toDouble() : double.tryParse(dQty?.toString() ?? '') ?? 1.0);
              final perDayRaw = rx['quantity'] ?? rx['qty'] ?? 0;
              final perDay = perDayRaw is num ? perDayRaw.toDouble() : double.tryParse(perDayRaw.toString()) ?? 0.0;
              final isInj = (rx['type']?.toString().toLowerCase().contains('injection') ?? false) ||
                            (rx['type']?.toString().toLowerCase().contains('drip') ?? false);
              final qty = isInj ? perDay : (perDay * days);
              dayTotalRemoved += qty;

              final patientName = d['patientName'] ?? d['name'] ?? 'Unknown Patient';
              final patientCnic = d['patientCnic'] ?? d['cnic'] ?? '';
              final age = d['patientAge'] ?? d['age'] ?? '';
              final gender = d['patientGender'] ?? d['gender'] ?? '';

              final dispensedAtStr = d['dispensedAt']?.toString() ?? d['createdAt']?.toString();
              DateTime logDate = curr;
              if (dispensedAtStr != null) {
                final parsed = DateTime.tryParse(dispensedAtStr);
                if (parsed != null) logDate = parsed.toLocal();
              }

              dayLogs.add({
                'type': 'removed',
                'qty': qty,
                'date': logDate.toIso8601String(),
                'user': d['dispenserName'] ?? d['dispensedBy'] ?? 'Dispenser',
                'msg': 'Dispensed to Patient',
                'medicineName': rxName,
                'patientName': patientName,
                'patientCnic': patientCnic,
                'age': age,
                'gender': gender,
                'serial': serial,
                'days': days.toInt(),
                'campTag': d['dispensaryTag'] ?? d['dispensaryId'] ?? d['campId'] ?? '',
              });
            }
          }
        }
        return {'totalRemoved': dayTotalRemoved, 'logs': dayLogs};
      });

      final results = await Future.wait(fetchFutures);
      for (final res in results) {
        totalRemoved += (res['totalRemoved'] as double);
        logs.addAll((res['logs'] as List<Map<String, dynamic>>));
      }

      logs.sort((a, b) => DateTime.parse(b['date']).compareTo(DateTime.parse(a['date'])));

      // Current live stock calculation
      double currentStock = 0;
      if (_selectedMed != null) {
        final rawQ = _selectedMed!['quantity'];
        currentStock = (rawQ is num ? rawQ.toDouble() : double.tryParse(rawQ?.toString() ?? '') ?? 0.0);
      } else {
        for (final m in _allMedicines) {
          final rawQ = m['quantity'];
          currentStock += (rawQ is num ? rawQ.toDouble() : double.tryParse(rawQ?.toString() ?? '') ?? 0.0);
        }
      }

      final report = {
        'totalAdded': totalAdded,
        'totalRemoved': totalRemoved,
        'totalAdjusted': totalAdjusted,
        'remaining': currentStock,
        'logs': logs,
        'generatedAt': DateTime.now().toIso8601String(),
      };

      await Hive.box(LocalStorageService.reportsCacheBox).put(key, report);

      if (mounted) {
        setState(() {
          _reportData = report;
          _isLoading = false;
        });
      }
    } catch (e) {
      debugPrint('Error generating report: $e');
      if (mounted) setState(() => _isLoading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDark = _isDark;
    final isWrapped = GlobalModuleWrapper.isWrapped(context);
    final content = _buildBody();

    if (widget.isEmbedded || isWrapped) return content;

    return Scaffold(
      backgroundColor: isDark ? const Color(0xFF0F172A) : _bg,
      appBar: AppBar(
        backgroundColor: isDark ? const Color(0xFF1E293B) : _teal,
        foregroundColor: Colors.white,
        elevation: 0,
        title: Text(
          _selectedMed != null ? '${_selectedMed!['name']} Ledger' : 'Dispensary Medicine Ledger',
          style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 18),
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh_rounded),
            onPressed: () => _loadReport(forceRecalculate: true),
            tooltip: 'Recalculate Report',
          ),
        ],
      ),
      body: content,
    );
  }

  Widget _buildBody() {
    final isDark = _isDark;
    return Column(
      children: [
        _buildFilterHeader(),
        Expanded(
          child: _isLoading
              ? const Center(child: CircularProgressIndicator(color: _teal))
              : _reportData == null
                  ? _buildEmptyState('No records found for this period')
                  : _buildLedgerView(),
        ),
      ],
    );
  }

  Widget _buildFilterHeader() {
    final isDark = _isDark;
    final monthLabel = DateFormat('MMMM yyyy').format(_selectedMonth);
    final branchCamps = CampSessionService.getCampsForBranch(widget.branchId);

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF1E293B) : Colors.white,
        border: Border(
          bottom: BorderSide(
            color: isDark ? const Color(0xFF334155) : const Color(0xFFE2E8F0),
          ),
        ),
      ),
      child: Column(
        children: [
          Row(
            children: [
              // Medicine Selector Button
              Expanded(
                child: InkWell(
                  onTap: _showMedicinePicker,
                  borderRadius: BorderRadius.circular(10),
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                    decoration: BoxDecoration(
                      color: isDark ? const Color(0xFF0F172A) : const Color(0xFFF1F8F6),
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(
                        color: isDark ? const Color(0xFF334155) : const Color(0xFFB2DFDB),
                      ),
                    ),
                    child: Row(
                      children: [
                        Icon(Icons.medication_rounded, size: 16, color: isDark ? const Color(0xFF38BDF8) : _teal),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            MasterProformaService.cleanBrandToFormula(_selectedMed?['name']?.toString() ?? 'All Stock Items (Consolidated)'),
                            style: TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.bold,
                              color: isDark ? Colors.white : _textDark,
                            ),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        Icon(Icons.arrow_drop_down, size: 18, color: isDark ? const Color(0xFF38BDF8) : _teal),
                      ],
                    ),
                  ),
                ),
              ),

              if (_hasMultiCamps && branchCamps.isNotEmpty) ...[
                const SizedBox(width: 8),
                _buildFilterDropdown(
                  value: _selectedCampFilter,
                  isDark: isDark,
                  items: [
                    {'id': 'all', 'label': '🏥 All Camps'},
                    ...branchCamps.map((c) => {
                      'id': (c['id'] ?? '').toString().toLowerCase().trim(),
                      'label': '📍 ${(c['name'] ?? CampSessionService.getCampLabel((c['id'] ?? '').toString(), widget.branchId)).toString()}',
                    }),
                  ],
                  onChanged: (v) {
                    setState(() {
                      _selectedCampFilter = v ?? 'all';
                      _reportData = null;
                    });
                    _loadMedicines();
                    _loadReport();
                  },
                ),
              ],
            ],
          ),
          const SizedBox(height: 10),

          // Month Navigation Row
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              IconButton(
                icon: Icon(Icons.chevron_left_rounded, color: isDark ? const Color(0xFF38BDF8) : _teal),
                onPressed: () {
                  setState(() {
                    _selectedMonth = DateTime(_selectedMonth.year, _selectedMonth.month - 1);
                    _reportData = null;
                  });
                  _loadReport();
                },
                tooltip: 'Previous Month',
              ),
              InkWell(
                onTap: () async {
                  final DateTime? picked = await showDatePicker(
                    context: context,
                    initialDate: _selectedMonth,
                    firstDate: DateTime(2020),
                    lastDate: DateTime.now(),
                    initialDatePickerMode: DatePickerMode.year,
                  );
                  if (picked != null) {
                    setState(() {
                      _selectedMonth = DateTime(picked.year, picked.month);
                      _reportData = null;
                    });
                    _loadReport();
                  }
                },
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
                  decoration: BoxDecoration(
                    color: isDark ? const Color(0xFF0F766E).withValues(alpha: 0.2) : _teal.withValues(alpha: 0.08),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(
                      color: isDark ? const Color(0xFF0F766E).withValues(alpha: 0.4) : _teal.withValues(alpha: 0.2),
                    ),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.calendar_month_rounded, size: 14, color: isDark ? const Color(0xFF38BDF8) : _teal),
                      const SizedBox(width: 6),
                      Text(
                        monthLabel,
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.bold,
                          color: isDark ? const Color(0xFF38BDF8) : _tealDark,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              IconButton(
                icon: Icon(Icons.chevron_right_rounded, color: isDark ? const Color(0xFF38BDF8) : _teal),
                onPressed: _selectedMonth.year == DateTime.now().year && _selectedMonth.month == DateTime.now().month
                    ? null
                    : () {
                        setState(() {
                          _selectedMonth = DateTime(_selectedMonth.year, _selectedMonth.month + 1);
                          _reportData = null;
                        });
                        _loadReport();
                      },
                tooltip: 'Next Month',
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildLedgerView() {
    final report = _reportData!;
    final logs = (report['logs'] as List?) ?? [];

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        _buildMetricCards(report),
        const SizedBox(height: 12),
        _buildLiveStockBanner(report),
        const SizedBox(height: 16),
        _buildConsolidatedBreakdown(report),
        const SizedBox(height: 16),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 6),
          child: Row(
            children: [
              Icon(Icons.history_rounded, size: 18, color: _isDark ? const Color(0xFF38BDF8) : _teal),
              const SizedBox(width: 8),
              Text(
                'Audit & Dispensation History (${logs.length})',
                style: TextStyle(
                  color: _isDark ? Colors.white : _tealDark,
                  fontWeight: FontWeight.bold,
                  fontSize: 15,
                ),
              ),
            ],
          ),
        ),
        if (logs.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 40),
            child: Center(
              child: Text(
                'No transactions recorded for this period',
                style: TextStyle(color: _isDark ? const Color(0xFF94A3B8) : _textLight),
              ),
            ),
          )
        else
          ...logs.map((log) => _buildTransactionTile(log)),
      ],
    );
  }

  Widget _buildMetricCards(Map<String, dynamic> report) {
    final ta = report['totalAdded'];
    final added = (ta is num ? ta.toDouble() : double.tryParse(ta?.toString() ?? '') ?? 0.0);
    final tr = report['totalRemoved'];
    final removed = (tr is num ? tr.toDouble() : double.tryParse(tr?.toString() ?? '') ?? 0.0);
    final tAdj = report['totalAdjusted'];
    final adjusted = (tAdj is num ? tAdj.toDouble() : double.tryParse(tAdj?.toString() ?? '') ?? 0.0);
    final net = added - removed;

    return LayoutBuilder(
      builder: (context, constraints) {
        final isNarrow = constraints.maxWidth < 620;
        final c1 = _solidSummaryCard(
          label: 'Total Added',
          value: '+${added.toStringAsFixed(0)}',
          icon: Icons.add_circle_outline_rounded,
          bgGradientStart: _emerald,
          bgGradientEnd: const Color(0xFF00704A),
          glowColor: _emerald,
        );
        final c2 = _solidSummaryCard(
          label: 'Dispensed',
          value: '-${removed.toStringAsFixed(0)}',
          icon: Icons.medication_outlined,
          bgGradientStart: _indigo,
          bgGradientEnd: const Color(0xFF3730A3),
          glowColor: _indigo,
        );
        final c3 = _solidSummaryCard(
          label: 'Adjustments',
          value: '${adjusted.toStringAsFixed(0)}',
          icon: Icons.tune_rounded,
          bgGradientStart: _amber,
          bgGradientEnd: const Color(0xFFB45309),
          glowColor: _amber,
        );
        final c4 = _solidSummaryCard(
          label: 'Net Flow',
          value: net >= 0 ? '+${net.toStringAsFixed(0)}' : net.toStringAsFixed(0),
          icon: Icons.account_balance_wallet_outlined,
          bgGradientStart: _teal,
          bgGradientEnd: const Color(0xFF0D5A50),
          glowColor: _teal,
        );

        if (isNarrow) {
          return Column(
            children: [
              Row(
                children: [
                  Expanded(child: c1),
                  const SizedBox(width: 8),
                  Expanded(child: c2),
                ],
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(child: c3),
                  const SizedBox(width: 8),
                  Expanded(child: c4),
                ],
              ),
            ],
          );
        }

        return Row(
          children: [
            Expanded(child: c1),
            const SizedBox(width: 8),
            Expanded(child: c2),
            const SizedBox(width: 8),
            Expanded(child: c3),
            const SizedBox(width: 8),
            Expanded(child: c4),
          ],
        );
      },
    );
  }

  Widget _buildLiveStockBanner(Map<String, dynamic> report) {
    final isDark = _isDark;
    final remaining = report['remaining'];
    final remVal = (remaining is num ? remaining.toDouble() : double.tryParse(remaining?.toString() ?? '') ?? 0.0);

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF1E293B) : Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: isDark ? const Color(0xFF334155) : const Color(0xFFE2E8F0),
        ),
      ),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: _teal.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Icon(Icons.inventory_2_rounded, size: 20, color: isDark ? const Color(0xFF38BDF8) : _teal),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  _selectedMed != null ? '${_selectedMed!['name']} Live Stock' : 'Active Stock on Hand',
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.bold,
                    color: isDark ? Colors.white : _textDark,
                  ),
                ),
                Text(
                  'Branch: ${widget.branchId.toUpperCase()}${_selectedCampFilter != 'all' ? ' • Camp: ${(CampSessionService.getCampLabel(_selectedCampFilter).toUpperCase().contains('KAPAY') ? 'SADDAR' : CampSessionService.getCampLabel(_selectedCampFilter).toUpperCase())}' : ' • All Camps'}',
                  style: TextStyle(fontSize: 11, color: isDark ? const Color(0xFF94A3B8) : _textLight),
                ),
              ],
            ),
          ),
          Text(
            remVal.toStringAsFixed(0),
            style: TextStyle(
              fontSize: 22,
              fontWeight: FontWeight.w900,
              color: isDark ? const Color(0xFF38BDF8) : _teal,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildConsolidatedBreakdown(Map<String, dynamic> report) {
    if (_selectedMed != null) return const SizedBox.shrink();

    final logs = (report['logs'] as List?) ?? [];
    final Map<String, Map<String, dynamic>> groups = {};

    for (final l in logs) {
      final rawName = l['medicineName']?.toString() ?? 'Unknown Medicine';
      final name = MasterProformaService.cleanBrandToFormula(rawName);
      final type = l['type']?.toString() ?? 'removed';
      final qty = (l['qty'] as num?)?.toDouble() ?? 0.0;
      final patientId = l['patientCnic'] ?? l['patientName'] ?? '';

      groups.putIfAbsent(name, () => {
        'added': 0.0,
        'removed': 0.0,
        'patients': <String>{},
      });

      if (type == 'added') {
        groups[name]!['added'] = (groups[name]!['added'] as double) + qty;
      } else {
        groups[name]!['removed'] = (groups[name]!['removed'] as double) + qty;
        if (patientId.toString().isNotEmpty) {
          (groups[name]!['patients'] as Set<String>).add(patientId.toString());
        }
      }
    }

    if (groups.isEmpty) return const SizedBox.shrink();

    final isDark = _isDark;
    return Card(
      elevation: 0,
      color: isDark ? const Color(0xFF1E293B) : Colors.white,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(color: isDark ? const Color(0xFF334155) : const Color(0xFFE2E8F0)),
      ),
      child: Theme(
        data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
        child: ExpansionTile(
          initiallyExpanded: false,
          leading: Icon(Icons.analytics_rounded, color: isDark ? const Color(0xFF38BDF8) : _teal),
          title: Text(
            'Medicine Breakdown Summary',
            style: TextStyle(fontWeight: FontWeight.bold, color: isDark ? Colors.white : _tealDark, fontSize: 14),
          ),
          subtitle: Text('${groups.length} medicines moved this period', style: const TextStyle(fontSize: 11)),
          children: [
            const Divider(height: 1),
            ListView.separated(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              padding: const EdgeInsets.all(12),
              itemCount: groups.length,
              separatorBuilder: (_, __) => const Divider(height: 10),
              itemBuilder: (context, index) {
                final name = groups.keys.elementAt(index);
                final counts = groups[name]!;
                final added = counts['added'] as double;
                final removed = counts['removed'] as double;
                final patientSet = counts['patients'] as Set<String>;
                final net = added - removed;

                return Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            name,
                            style: TextStyle(fontWeight: FontWeight.bold, color: isDark ? Colors.white : _textDark, fontSize: 13),
                          ),
                          const SizedBox(height: 3),
                          Row(
                            children: [
                              if (added > 0)
                                Container(
                                  margin: const EdgeInsets.only(right: 6),
                                  padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1.5),
                                  decoration: BoxDecoration(
                                    color: _emerald.withValues(alpha: 0.12),
                                    borderRadius: BorderRadius.circular(4),
                                  ),
                                  child: Text('+${added.toStringAsFixed(0)}', style: const TextStyle(color: _emerald, fontSize: 10, fontWeight: FontWeight.bold)),
                                ),
                              if (removed > 0)
                                Container(
                                  padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1.5),
                                  decoration: BoxDecoration(
                                    color: _indigo.withValues(alpha: 0.12),
                                    borderRadius: BorderRadius.circular(4),
                                  ),
                                  child: Text('-${removed.toStringAsFixed(0)} (${patientSet.length} pts)', style: const TextStyle(color: _indigo, fontSize: 10, fontWeight: FontWeight.bold)),
                                ),
                            ],
                          ),
                        ],
                      ),
                    ),
                    Text(
                      net >= 0 ? '+${net.toStringAsFixed(0)}' : net.toStringAsFixed(0),
                      style: TextStyle(
                        color: net >= 0 ? _emerald : _red,
                        fontWeight: FontWeight.w900,
                        fontSize: 14,
                      ),
                    ),
                  ],
                );
              },
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildTransactionTile(Map<dynamic, dynamic> log) {
    final bool isAdded = log['type'] == 'added';
    final isProforma = log['isProforma'] == true;
    final isDark = _isDark;
    final date = DateTime.tryParse(log['date']?.toString() ?? '') ?? DateTime.now();
    final rawCampTag = (log['campTag'] ?? '').toString().trim().toUpperCase();
    final campTag = (rawCampTag.contains('KAPAY') || rawCampTag == 'KAPAYYA' || rawCampTag == 'KAPAYA')
        ? 'SADDAR'
        : (rawCampTag.isNotEmpty ? CampSessionService.getCampLabel(rawCampTag, widget.branchId).toUpperCase() : '');
    final rawMedName = (log['medicineName'] ?? '').toString();
    final medName = MasterProformaService.cleanBrandToFormula(rawMedName);
    final rawMsg = (log['msg'] ?? (isAdded ? 'Restock' : 'Dispensed')).toString();
    final msg = MasterProformaService.cleanBrandToFormula(rawMsg);

    return Container(
      margin: const EdgeInsets.symmetric(vertical: 5),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF1E293B) : Colors.white,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: isDark ? const Color(0xFF334155) : Colors.grey.shade200,
          width: 1,
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: isDark ? 0.2 : 0.03),
            blurRadius: 6,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              // Action Icon Avatar
              Container(
                padding: const EdgeInsets.all(7),
                decoration: BoxDecoration(
                  color: isAdded
                      ? (isProforma ? _emerald.withValues(alpha: 0.15) : _teal.withValues(alpha: 0.15))
                      : _indigo.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Icon(
                  isAdded
                      ? (isProforma ? Icons.inventory_2_rounded : Icons.add_circle_outline_rounded)
                      : Icons.medication_outlined,
                  color: isAdded
                      ? (isProforma ? _emerald : (isDark ? const Color(0xFF2DD4BF) : _teal))
                      : _indigo,
                  size: 16,
                ),
              ),
              const SizedBox(width: 10),
              // Medicine Title / Action
              Expanded(
                child: Text(
                  isAdded
                      ? msg
                      : '$medName • ${log['patientName'] ?? 'Unknown Patient'}',
                  style: TextStyle(
                    fontWeight: FontWeight.bold,
                    color: isDark ? Colors.white : _textDark,
                    fontSize: 13,
                  ),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              const SizedBox(width: 8),
              // Quantity Delta
              Text(
                '${isAdded ? "+" : "-"}${log['qty']}',
                style: TextStyle(
                  color: isAdded ? (isDark ? const Color(0xFF4ADE80) : _emerald) : (isDark ? const Color(0xFF818CF8) : _indigo),
                  fontWeight: FontWeight.w900,
                  fontSize: 15,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          // Sub-details row with Wrap to NEVER overflow
          Wrap(
            spacing: 8,
            runSpacing: 4,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              if (!isAdded && log['serial'] != null && log['serial'].toString().isNotEmpty)
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  decoration: BoxDecoration(
                    color: _indigo.withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Text(
                    '#${log['serial']}',
                    style: const TextStyle(fontSize: 10.5, fontWeight: FontWeight.bold, color: _indigo),
                  ),
                ),
              if (!isAdded && log['patientCnic'] != null && log['patientCnic'].toString().isNotEmpty)
                Text(
                  'CNIC: ${log['patientCnic']}',
                  style: TextStyle(fontSize: 11, color: isDark ? const Color(0xFF94A3B8) : _textLight),
                ),
              if (!isAdded && log['days'] != null)
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1.5),
                  decoration: BoxDecoration(
                    color: Colors.deepOrange.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Text(
                    '${log['days']}d supply',
                    style: const TextStyle(fontSize: 10, color: Colors.deepOrange, fontWeight: FontWeight.bold),
                  ),
                ),
              if (campTag.isNotEmpty && campTag != 'ALL')
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1.5),
                  decoration: BoxDecoration(
                    color: campTag.contains('HAJI') ? const Color(0xFF6366F1) : const Color(0xFF0D9488),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Text(
                    '📍 $campTag',
                    style: const TextStyle(color: Colors.white, fontSize: 9.5, fontWeight: FontWeight.bold),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 6),
          // Footer: Performed by & Date/Time
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Expanded(
                child: Text(
                  'By: ${log['user'] ?? 'System'}',
                  style: TextStyle(
                    color: isDark ? const Color(0xFF64748B) : _textLight,
                    fontSize: 10.5,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              Text(
                DateFormat('dd MMM, hh:mm a').format(date),
                style: TextStyle(color: isDark ? const Color(0xFF94A3B8) : _textLight, fontSize: 10.5, fontWeight: FontWeight.w500),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _solidSummaryCard({
    required String label,
    required String value,
    required IconData icon,
    required Color bgGradientStart,
    required Color bgGradientEnd,
    required Color glowColor,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [bgGradientStart, bgGradientEnd],
        ),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: Colors.white.withValues(alpha: 0.25),
          width: 1.0,
        ),
        boxShadow: [
          BoxShadow(
            color: glowColor.withValues(alpha: 0.28),
            blurRadius: 8,
            offset: const Offset(0, 3),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, size: 14, color: Colors.white.withValues(alpha: 0.90)),
              const SizedBox(width: 4),
              Expanded(
                child: Text(
                  label,
                  style: TextStyle(
                    fontSize: 10.5,
                    fontWeight: FontWeight.w600,
                    color: Colors.white.withValues(alpha: 0.95),
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            value,
            style: const TextStyle(
              fontSize: 17,
              fontWeight: FontWeight.bold,
              color: Colors.white,
            ),
          ),
        ],
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
      height: 34,
      padding: const EdgeInsets.symmetric(horizontal: 8),
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF0F172A) : const Color(0xFFF1F8F6),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: isDark ? const Color(0xFF334155) : const Color(0xFFB2DFDB),
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

  void _showMedicinePicker() {
    final isDark = _isDark;
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => Container(
        height: MediaQuery.of(context).size.height * 0.7,
        decoration: BoxDecoration(
          color: isDark ? const Color(0xFF1E293B) : _white,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
        ),
        child: Column(
          children: [
            Container(
              margin: const EdgeInsets.all(12),
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: isDark ? const Color(0xFF475569) : Colors.grey[300],
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            Text('Select Medicine for Ledger',
                style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16, color: isDark ? Colors.white : _tealDark)),
            const SizedBox(height: 12),
            Expanded(
              child: ListView.builder(
                itemCount: _allMedicines.length + 1,
                itemBuilder: (ctx, i) {
                  if (i == 0) {
                    return ListTile(
                      leading: CircleAvatar(
                        backgroundColor: _teal.withValues(alpha: 0.1),
                        child: const Icon(Icons.apps_rounded, size: 16, color: _teal),
                      ),
                      title: const Text('All Medicines (Consolidated)', style: TextStyle(fontWeight: FontWeight.bold)),
                      subtitle: const Text('Show ledger for all stock items combined'),
                      onTap: () {
                        Navigator.pop(ctx);
                        setState(() {
                          _selectedMed = null;
                          _reportData = null;
                        });
                        _loadReport();
                      },
                    );
                  }
                  final med = _allMedicines[i - 1];
                  final cleanName = MasterProformaService.cleanBrandToFormula(med['name'] ?? med['formula'] ?? '');
                  return ListTile(
                    leading: CircleAvatar(
                      backgroundColor: _teal.withValues(alpha: 0.1),
                      child: const Icon(Icons.medication_rounded, size: 16, color: _teal),
                    ),
                    title: Text(cleanName.isNotEmpty ? cleanName : (med['name'] ?? ''), style: const TextStyle(fontWeight: FontWeight.bold)),
                    subtitle: Text('${med['type']} • ${med['dose'] ?? 'No Dose'} • Qty: ${med['quantity']}'),
                    onTap: () {
                      Navigator.pop(ctx);
                      setState(() {
                        _selectedMed = med;
                        _reportData = null;
                      });
                      _loadReport();
                    },
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildEmptyState(String msg) {
    final isDark = _isDark;
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.query_stats_rounded, size: 64, color: isDark ? const Color(0xFF334155) : Colors.grey.shade300),
          const SizedBox(height: 12),
          Text(msg, style: TextStyle(color: isDark ? const Color(0xFF94A3B8) : _textLight, fontSize: 14)),
        ],
      ),
    );
  }
}
