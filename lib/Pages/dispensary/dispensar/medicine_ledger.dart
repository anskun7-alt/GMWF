// lib/pages/dispensary/dispensar/medicine_ledger.dart

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:gmwf/design/design_system.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:intl/intl.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:gmwf/services/local_storage_service.dart';
import 'package:gmwf/services/camp_session_service.dart';
import 'package:gmwf/services/master_proforma_service.dart';
import 'package:gmwf/services/stock/stock_pool.dart';
import 'package:gmwf/services/stock/stock_reader.dart';
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
      // Stock book: the batches of the selected camp's pool, or of every pool of the branch.
      final pools = _selectedCampFilter != 'all'
          ? [
              if (StockPool.of(widget.branchId, _selectedCampFilter,
                      fallbackCamp: CampSessionService.getActiveCamp(widget.branchId)) case final p?)
                p
            ]
          : StockPool.allFor(widget.branchId);
      final items = <Map<String, dynamic>>[
        for (final pool in pools) ...StockReader.batches(pool),
      ];
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
          copy['id'] = (copy['medicineId'] ?? copy['id']).toString();
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
    final nowDt = DateTime.now();
    final isCurrentMonth = _selectedMonth.year == nowDt.year && _selectedMonth.month == nowDt.month;
    if (!forceRecalculate) {
      final cached = Hive.box(LocalStorageService.reportsCacheBox).get(key);
      if (cached is Map) {
        final genAt = DateTime.tryParse(cached['generatedAt']?.toString() ?? '');
        final isFresh = !isCurrentMonth || (genAt != null && nowDt.difference(genAt).inMinutes < 2);
        if (isFresh) {
          setState(() {
            _reportData = Map<String, dynamic>.from(cached);
            _isLoading = false;
          });
          return;
        }
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
            // Legacy 'proforma' action names mapped at display time so old logs remain readable.
            final isProforma = action == 'add_proforma_stock' || action == 'add_from_proforma' || action == 'proforma_add' || action == 'proforma_import';
            final isReg = action == 'medicine_registered_directly' || action == 'medicine_registered';
            final actionLabel = isProforma ? 'Add Medicine' : (isReg ? 'Initial Registration' : 'Restock');
            final performer = d['performedByName'] ?? d['performedBy'] ?? 'Unknown';
            final performerRole = d['performedByRole'] != null ? ' (${d['performedByRole']})' : '';

            logs.add({
              'type': 'added',
              'qty': qty,
              'date': ts.toIso8601String(),
              'user': '$performer$performerRole',
              'msg': '$actionLabel ($medName)',
              'medicineName': medName,
              'details': (d['details'] ?? '').toString().replaceAll('Universal Proforma Catalog', 'Add Medicine'),
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

          final q = d['quantityAdded'];
          final qty = (q is num ? q.toDouble() : double.tryParse(q?.toString() ?? '') ?? 0.0);
          final rawTs = d['createdAt'] ?? d['timestamp'];
          final ts = rawTs is DateTime ? rawTs : (DateTime.tryParse(rawTs?.toString() ?? '') ?? DateTime.now());
          final action = d['action'] ?? '';
          final medName = d['medicineName'] ?? d['name'] ?? 'Unknown Medicine';

          if (ts.year == selectedYear && ts.month == selectedMonthVal) {
            // Legacy 'proforma' action names mapped at display time so old logs remain readable.
            final isProforma = action == 'add_proforma_stock' || action == 'add_from_proforma' || action == 'proforma_add' || action == 'proforma_import';
            final isReg = action == 'medicine_registered_directly' || action == 'medicine_registered';
            final isEdit = action == 'edit_stock' || action == 'medicine_edited';
            final actionLabel = isProforma ? 'Add Medicine' : (isReg ? 'Initial Registration' : 'Restock');
            final performer = d['performedByName'] ?? d['performedBy'] ?? 'Unknown';
            final performerRole = d['performedByRole'] != null ? ' (${d['performedByRole']})' : '';
            final campTag = (d['dispensaryTag'] ?? d['dispensaryId'] ?? d['campId'] ?? '').toString();

            final alreadyPresent = logs.any((l) =>
                l['medicineName'] == medName &&
                (l['qty'] as num?)?.toDouble() == qty.abs() &&
                (DateTime.parse(l['date']).difference(ts).inMinutes.abs() < 5));

            if (!alreadyPresent) {
              if (isEdit) {
                if (q != null) {
                  totalAdjusted += qty;
                  logs.add({
                    'type': qty >= 0 ? 'added' : 'removed',
                    'qty': qty.abs(),
                    'date': ts.toIso8601String(),
                    'user': '$performer$performerRole',
                    'msg': '${action == 'medicine_edited' ? 'Medicine Edited' : 'Manual Adjustment'} ($medName)',
                    'medicineName': medName,
                    'campTag': campTag,
                  });
                }
              } else {
                final addQty = q != null
                    ? qty
                    : ((d['quantity'] is num)
                        ? (d['quantity'] as num).toDouble()
                        : (double.tryParse(d['quantity']?.toString() ?? '') ?? 0.0));
                totalAdded += addQty;
                logs.add({
                  'type': 'added',
                  'qty': addQty,
                  'date': ts.toIso8601String(),
                  'user': '$performer$performerRole',
                  'msg': '$actionLabel ($medName)',
                  'medicineName': medName,
                  'details': (d['details'] ?? '').toString().replaceAll('Universal Proforma Catalog', 'Add Medicine'),
                  'isProforma': isProforma,
                  'campTag': campTag,
                });
              }
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

      final normBranchPrefix = '${widget.branchId.toLowerCase().trim()}_';
      final fetchFutures = daysToFetch.map((curr) async {
        final dateKey = DateFormat('ddMMyy').format(curr);
        double dayTotalRemoved = 0;
        List<Map<String, dynamic>> dayLogs = [];

        // 1. Try local dispensary records first
        final localRecords = <Map<String, dynamic>>[];
        if (Hive.isBoxOpen(LocalStorageService.dispensaryBox)) {
          final box = Hive.box(LocalStorageService.dispensaryBox);
          final targetPrefix = '$normBranchPrefix$dateKey';
          for (final k in box.keys) {
            if (k.toString().toLowerCase().startsWith(targetPrefix)) {
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
              final rxTypeLower = (rx['type'] ?? '').toString().toLowerCase();
              final rxNameLower = rxName.toString().toLowerCase();
              // Same rule as the dispense (StockMath). Syrups dispensed before 2026-11-21 took
              // 1 bottle whatever the days, so those keep showing 1.
              final isSyrup = rxTypeLower.contains('syrup') || rxNameLower.contains('syp') || rxNameLower.contains('syrup');
              final at = DateTime.tryParse((d['dispensedAt'] ?? d['createdAt'] ?? '').toString());
              final oldSyrupRule = isSyrup && at != null && at.isBefore(DateTime(2026, 11, 21));
              final qty = oldSyrupRule
                  ? 1.0
                  : (perDay <= 0 ? 0.0 : StockMath.lineUnits(rx, days.round()));
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
        totalRemoved += ((res['totalRemoved'] as num?)?.toDouble() ?? 0.0);
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
    final c = context.comfort;
    final isWrapped = GlobalModuleWrapper.isWrapped(context);
    final content = Container(
      color: c.background,
      child: _buildBody(),
    );

    if (widget.isEmbedded || isWrapped) return content;

    return Scaffold(
      backgroundColor: c.background,
      appBar: AppBar(
        backgroundColor: c.surface,
        foregroundColor: c.textPrimary,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        title: Text(
          _selectedMed != null
              ? '${_selectedMed!['name']} Ledger'
              : 'Dispensary Medicine Ledger',
          style: TextStyle(
            fontWeight: FontWeight.w700,
            fontSize: 17,
            color: c.textPrimary,
          ),
        ),
        actions: [
          IconButton(
            icon: Icon(Icons.refresh_rounded, color: c.brand),
            onPressed: () => _loadReport(forceRecalculate: true),
            tooltip: 'Recalculate Report',
          ),
        ],
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(1),
          child: Divider(height: 1, color: c.border),
        ),
      ),
      body: content,
    );
  }

  Widget _buildBody() {
    final c = context.comfort;
    return Column(
      children: [
        _buildFilterHeader(),
        Expanded(
          child: _isLoading
              ? Center(child: CircularProgressIndicator(color: c.brand))
              : _reportData == null
                  ? _buildEmptyState('No records found for this period')
                  : _buildLedgerView(),
        ),
      ],
    );
  }

  Widget _buildFilterHeader() {
    final c = context.comfort;
    final isCompact = GBreakpoint.isCompact(context);
    final monthLabel = DateFormat('MMMM yyyy').format(_selectedMonth);
    final branchCamps = CampSessionService.getCampsForBranch(widget.branchId);
    final isAtCurrentMonth =
        _selectedMonth.year == DateTime.now().year && _selectedMonth.month == DateTime.now().month;

    final medicineSelector = InkWell(
      onTap: _showMedicinePicker,
      borderRadius: BorderRadius.circular(10),
      child: Container(
        height: 38,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        decoration: BoxDecoration(
          color: c.surfaceSunken,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: c.borderStrong),
        ),
        child: Row(
          children: [
            Icon(Icons.medication_rounded, size: 17, color: c.brand),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                MasterProformaService.cleanBrandToFormula(
                  _selectedMed?['name']?.toString() ?? 'All Stock Items (Consolidated)',
                ),
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                  color: c.textPrimary,
                ),
                overflow: TextOverflow.ellipsis,
              ),
            ),
            Icon(Icons.keyboard_arrow_down_rounded, size: 18, color: c.textSecondary),
          ],
        ),
      ),
    );

    final Widget? campSelector = (_hasMultiCamps && branchCamps.isNotEmpty)
        ? _buildFilterDropdown(
            value: _selectedCampFilter,
            items: [
              {'id': 'all', 'label': '🏥 All Camps'},
              ...branchCamps.map((camp) => {
                    'id': (camp['id'] ?? '').toString().toLowerCase().trim(),
                    'label':
                        '📍 ${(camp['name'] ?? CampSessionService.getCampLabel((camp['id'] ?? '').toString(), widget.branchId)).toString()}',
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
          )
        : null;

    final monthNavigator = Container(
      height: 38,
      decoration: BoxDecoration(
        color: c.surfaceSunken,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: c.border),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            icon: Icon(Icons.chevron_left_rounded, size: 18, color: c.brand),
            padding: const EdgeInsets.symmetric(horizontal: 8),
            constraints: const BoxConstraints(minWidth: 34, minHeight: 38),
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
            borderRadius: BorderRadius.circular(6),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.calendar_month_rounded, size: 14, color: c.brand),
                  const SizedBox(width: 6),
                  Text(
                    monthLabel,
                    style: TextStyle(
                      fontSize: 12.5,
                      fontWeight: FontWeight.w700,
                      color: c.textPrimary,
                    ),
                  ),
                ],
              ),
            ),
          ),
          IconButton(
            icon: Icon(
              Icons.chevron_right_rounded,
              size: 18,
              color: isAtCurrentMonth ? c.textMuted : c.brand,
            ),
            padding: const EdgeInsets.symmetric(horizontal: 8),
            constraints: const BoxConstraints(minWidth: 34, minHeight: 38),
            onPressed: isAtCurrentMonth
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
    );

    final refreshBtn = Tooltip(
      message: 'Recalculate Report',
      child: InkWell(
        onTap: () => _loadReport(forceRecalculate: true),
        borderRadius: BorderRadius.circular(10),
        child: Container(
          width: 38,
          height: 38,
          decoration: BoxDecoration(
            color: c.surfaceSunken,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: c.border),
          ),
          child: Icon(Icons.refresh_rounded, size: 18, color: c.brand),
        ),
      ),
    );

    return Container(
      margin: const EdgeInsets.fromLTRB(12, 8, 12, 4),
      padding: EdgeInsets.symmetric(
        horizontal: isCompact ? 10 : 12,
        vertical: isCompact ? 8 : 10,
      ),
      decoration: BoxDecoration(
        color: c.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: c.border),
      ),
      child: isCompact
          ? Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    Expanded(child: medicineSelector),
                    if (campSelector != null) ...[
                      const SizedBox(width: 8),
                      campSelector,
                    ],
                  ],
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(child: Center(child: monthNavigator)),
                    const SizedBox(width: 8),
                    refreshBtn,
                  ],
                ),
              ],
            )
          : Row(
              children: [
                Expanded(child: medicineSelector),
                if (campSelector != null) ...[
                  const SizedBox(width: 8),
                  campSelector,
                ],
                const SizedBox(width: 8),
                monthNavigator,
                const SizedBox(width: 8),
                refreshBtn,
              ],
            ),
    );
  }

  Widget _buildLedgerView() {
    final c = context.comfort;
    final report = _reportData!;
    final logs = (report['logs'] as List?) ?? [];

    return ListView(
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 20),
      children: [
        _buildMetricCards(report),
        const SizedBox(height: 10),
        _buildLiveStockBanner(report),
        const SizedBox(height: 12),
        _buildConsolidatedBreakdown(report),
        const SizedBox(height: 14),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
          child: Row(
            children: [
              Icon(Icons.history_rounded, size: 18, color: c.brand),
              const SizedBox(width: 8),
              Text(
                'Audit & Dispensation History (${logs.length})',
                style: TextStyle(
                  color: c.textPrimary,
                  fontWeight: FontWeight.w700,
                  fontSize: 14.5,
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
                style: TextStyle(color: c.textSecondary),
              ),
            ),
          )
        else
          ...logs.map((log) => _buildTransactionTile(log)),
      ],
    );
  }

  Widget _buildMetricCards(Map<String, dynamic> report) {
    final c = context.comfort;
    final ta = report['totalAdded'];
    final added = (ta is num ? ta.toDouble() : double.tryParse(ta?.toString() ?? '') ?? 0.0);
    final tr = report['totalRemoved'];
    final removed = (tr is num ? tr.toDouble() : double.tryParse(tr?.toString() ?? '') ?? 0.0);
    final tAdj = report['totalAdjusted'];
    final adjusted = (tAdj is num ? tAdj.toDouble() : double.tryParse(tAdj?.toString() ?? '') ?? 0.0);
    final net = added - removed;

    return LayoutBuilder(
      builder: (context, constraints) {
        final isNarrow = constraints.maxWidth < 640;
        final c1 = _solidSummaryCard(
          label: 'Total Added',
          value: '+${added.toStringAsFixed(0)}',
          icon: Icons.add_circle_outline_rounded,
          accentColor: c.success,
          bgTint: c.successBg,
        );
        final c2 = _solidSummaryCard(
          label: 'Dispensed',
          value: '-${removed.toStringAsFixed(0)}',
          icon: Icons.medication_outlined,
          accentColor: c.info,
          bgTint: c.infoBg,
        );
        final c3 = _solidSummaryCard(
          label: 'Adjustments',
          value: adjusted.toStringAsFixed(0),
          icon: Icons.tune_rounded,
          accentColor: c.warning,
          bgTint: c.warningBg,
        );
        final c4 = _solidSummaryCard(
          label: 'Net Flow',
          value: net >= 0 ? '+${net.toStringAsFixed(0)}' : net.toStringAsFixed(0),
          icon: Icons.account_balance_wallet_outlined,
          accentColor: c.brand,
          bgTint: c.brandSoft,
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
    final c = context.comfort;
    final remaining = report['remaining'];
    final remVal = (remaining is num ? remaining.toDouble() : double.tryParse(remaining?.toString() ?? '') ?? 0.0);

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: c.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: c.border),
      ),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(9),
            decoration: BoxDecoration(
              color: c.brandSoft,
              borderRadius: BorderRadius.circular(10),
            ),
            child: Icon(Icons.inventory_2_rounded, size: 20, color: c.brand),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  _selectedMed != null ? '${_selectedMed!['name']} Live Stock' : 'Active Stock on Hand',
                  style: TextStyle(
                    fontSize: 13.5,
                    fontWeight: FontWeight.w700,
                    color: c.textPrimary,
                  ),
                ),
                Text(
                  'Branch: ${widget.branchId.toUpperCase()}${_selectedCampFilter != 'all' ? ' • Camp: ${(CampSessionService.getCampLabel(_selectedCampFilter).toUpperCase().contains('KAPAY') ? 'SADDAR' : CampSessionService.getCampLabel(_selectedCampFilter).toUpperCase())}' : ' • All Camps'}',
                  style: TextStyle(fontSize: 11.5, color: c.textSecondary),
                ),
              ],
            ),
          ),
          Text(
            remVal.toStringAsFixed(0),
            style: TextStyle(
              fontSize: 22,
              fontWeight: FontWeight.w800,
              color: c.brand,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildConsolidatedBreakdown(Map<String, dynamic> report) {
    if (_selectedMed != null) return const SizedBox.shrink();

    final c = context.comfort;
    final logs = (report['logs'] as List?) ?? [];
    final Map<String, Map<String, dynamic>> groups = {};

    for (final raw in logs) {
      // Synced/legacy log rows can be malformed (non-Map, qty as text); never let one break the view.
      if (raw is! Map) continue;
      final l = raw;
      final rawName = l['medicineName']?.toString() ?? 'Unknown Medicine';
      String name;
      try {
        name = MasterProformaService.cleanBrandToFormula(rawName);
      } catch (_) {
        name = rawName;
      }
      final type = l['type']?.toString() ?? 'removed';
      final qtyRaw = l['qty'];
      final qty = qtyRaw is num ? qtyRaw.toDouble() : (double.tryParse(qtyRaw?.toString() ?? '') ?? 0.0);
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

    return Container(
      decoration: BoxDecoration(
        color: c.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: c.border),
      ),
      // Own storage bucket: the tile's open/closed state otherwise collides with the parent
      // ListView's saved scroll offset in PageStorage ("double is not a subtype of bool?").
      child: PageStorage(
        bucket: PageStorageBucket(),
        child: Theme(
          data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
          child: ExpansionTile(
            key: const ValueKey('ledger_breakdown_tile'),
            initiallyExpanded: false,
            leading: Icon(Icons.analytics_rounded, color: c.brand),
            title: Text(
              'Medicine Breakdown Summary',
              style: TextStyle(fontWeight: FontWeight.w700, color: c.textPrimary, fontSize: 14),
            ),
            subtitle: Text(
              '${groups.length} medicines moved this period',
              style: TextStyle(fontSize: 11.5, color: c.textSecondary),
            ),
            children: [
              Divider(height: 1, color: c.border),
              ListView.separated(
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                padding: const EdgeInsets.all(12),
                itemCount: groups.length,
                separatorBuilder: (_, __) => Divider(height: 10, color: c.border),
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
                              style: TextStyle(
                                fontWeight: FontWeight.w700,
                                color: c.textPrimary,
                                fontSize: 13,
                              ),
                            ),
                            const SizedBox(height: 4),
                            Row(
                              children: [
                                if (added > 0)
                                  Container(
                                    margin: const EdgeInsets.only(right: 6),
                                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                    decoration: BoxDecoration(
                                      color: c.successBg,
                                      borderRadius: BorderRadius.circular(5),
                                      border: Border.all(color: c.success.withValues(alpha: 0.3)),
                                    ),
                                    child: Text(
                                      '+${added.toStringAsFixed(0)}',
                                      style: TextStyle(
                                        color: c.success,
                                        fontSize: 10.5,
                                        fontWeight: FontWeight.w700,
                                      ),
                                    ),
                                  ),
                                if (removed > 0)
                                  Container(
                                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                    decoration: BoxDecoration(
                                      color: c.infoBg,
                                      borderRadius: BorderRadius.circular(5),
                                      border: Border.all(color: c.info.withValues(alpha: 0.3)),
                                    ),
                                    child: Text(
                                      '-${removed.toStringAsFixed(0)} (${patientSet.length} pts)',
                                      style: TextStyle(
                                        color: c.info,
                                        fontSize: 10.5,
                                        fontWeight: FontWeight.w700,
                                      ),
                                    ),
                                  ),
                              ],
                            ),
                          ],
                        ),
                      ),
                      Text(
                        net >= 0 ? '+${net.toStringAsFixed(0)}' : net.toStringAsFixed(0),
                        style: TextStyle(
                          color: net >= 0 ? c.success : c.danger,
                          fontWeight: FontWeight.w800,
                          fontSize: 14.5,
                        ),
                      ),
                    ],
                  );
                },
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildTransactionTile(Map<dynamic, dynamic> log) {
    final c = context.comfort;
    final bool isAdded = log['type'] == 'added';
    final isProforma = log['isProforma'] == true;
    final date = DateTime.tryParse(log['date']?.toString() ?? '') ?? DateTime.now();
    final rawCampTag = (log['campTag'] ?? '').toString().trim().toUpperCase();
    final campTag = (rawCampTag.contains('KAPAY') || rawCampTag == 'KAPAYYA' || rawCampTag == 'KAPAYA')
        ? 'SADDAR'
        : (rawCampTag.isNotEmpty ? CampSessionService.getCampLabel(rawCampTag, widget.branchId).toUpperCase() : '');
    final rawMedName = (log['medicineName'] ?? '').toString();
    final medName = MasterProformaService.cleanBrandToFormula(rawMedName);
    final rawMsg = (log['msg'] ?? (isAdded ? 'Restock' : 'Dispensed')).toString();
    final msg = MasterProformaService.cleanBrandToFormula(rawMsg);

    final Color iconBg = isAdded ? c.successBg : c.infoBg;
    final Color iconFg = isAdded ? c.success : c.info;

    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: c.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: c.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              // Action Icon Avatar
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: iconBg,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Icon(
                  isAdded
                      ? (isProforma ? Icons.inventory_2_rounded : Icons.add_circle_outline_rounded)
                      : Icons.medication_outlined,
                  color: iconFg,
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
                    fontWeight: FontWeight.w700,
                    color: c.textPrimary,
                    fontSize: 13.5,
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
                  color: iconFg,
                  fontWeight: FontWeight.w800,
                  fontSize: 15.5,
                ),
              ),
            ],
          ),
          if ((!isAdded && log['serial'] != null && log['serial'].toString().isNotEmpty) ||
              (!isAdded && log['patientCnic'] != null && log['patientCnic'].toString().isNotEmpty) ||
              (!isAdded && log['days'] != null) ||
              (campTag.isNotEmpty && campTag != 'ALL')) ...[
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 4,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                if (!isAdded && log['serial'] != null && log['serial'].toString().isNotEmpty)
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                    decoration: BoxDecoration(
                      color: c.brandSoft,
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Text(
                      '#${log['serial']}',
                      style: TextStyle(fontSize: 10.5, fontWeight: FontWeight.w700, color: c.brandStrong),
                    ),
                  ),
                if (!isAdded && log['patientCnic'] != null && log['patientCnic'].toString().isNotEmpty)
                  Text(
                    'CNIC: ${log['patientCnic']}',
                    style: TextStyle(fontSize: 11, color: c.textSecondary),
                  ),
                if (!isAdded && log['days'] != null)
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                    decoration: BoxDecoration(
                      color: c.warningBg,
                      borderRadius: BorderRadius.circular(5),
                      border: Border.all(color: c.warning.withValues(alpha: 0.3)),
                    ),
                    child: Text(
                      '${log['days']}d supply',
                      style: TextStyle(fontSize: 10, color: c.warning, fontWeight: FontWeight.w700),
                    ),
                  ),
                if (campTag.isNotEmpty && campTag != 'ALL')
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                    decoration: BoxDecoration(
                      color: c.infoBg,
                      borderRadius: BorderRadius.circular(5),
                      border: Border.all(color: c.info.withValues(alpha: 0.3)),
                    ),
                    child: Text(
                      '📍 $campTag',
                      style: TextStyle(color: c.info, fontSize: 10, fontWeight: FontWeight.w700),
                    ),
                  ),
              ],
            ),
          ],
          const SizedBox(height: 8),
          // Footer: Performed by & Date/Time
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Expanded(
                child: Text(
                  'By: ${log['user'] ?? 'System'}',
                  style: TextStyle(color: c.textMuted, fontSize: 11),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              Text(
                DateFormat('dd MMM, hh:mm a').format(date),
                style: TextStyle(color: c.textSecondary, fontSize: 11, fontWeight: FontWeight.w500),
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
    required Color accentColor,
    required Color bgTint,
  }) {
    final c = context.comfort;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
      decoration: BoxDecoration(
        color: bgTint,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: accentColor.withValues(alpha: 0.3)),
      ),
      child: Row(
        children: [
          Container(
            width: 36,
            height: 36,
            decoration: BoxDecoration(
              color: accentColor.withValues(alpha: _isDark ? 0.22 : 0.14),
              shape: BoxShape.circle,
            ),
            child: Icon(icon, color: accentColor, size: 18),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  value,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: c.textPrimary,
                    fontSize: 18,
                    fontWeight: FontWeight.w800,
                    height: 1.1,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: accentColor,
                    fontSize: 11.5,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
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
  }) {
    final c = context.comfort;
    return Container(
      height: 38,
      padding: const EdgeInsets.symmetric(horizontal: 10),
      decoration: BoxDecoration(
        color: c.surfaceSunken,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: c.border),
      ),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<String>(
          value: items.any((i) => i['id'] == value) ? value : items.first['id'],
          isDense: true,
          icon: Icon(Icons.keyboard_arrow_down_rounded, size: 18, color: c.textSecondary),
          dropdownColor: c.surface,
          style: TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w600,
            color: c.textPrimary,
          ),
          items: items.map((i) {
            return DropdownMenuItem<String>(
              value: i['id'],
              child: Text(
                i['label']!,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: c.textPrimary,
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
    final c = context.comfort;
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => Container(
        height: MediaQuery.of(context).size.height * 0.7,
        decoration: BoxDecoration(
          color: c.surface,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
          border: Border(top: BorderSide(color: c.border)),
        ),
        child: Column(
          children: [
            Container(
              margin: const EdgeInsets.all(12),
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: c.borderStrong,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            Text(
              'Select Medicine for Ledger',
              style: TextStyle(
                fontWeight: FontWeight.w700,
                fontSize: 16,
                color: c.textPrimary,
              ),
            ),
            const SizedBox(height: 12),
            Divider(height: 1, color: c.border),
            Expanded(
              child: ListView.builder(
                itemCount: _allMedicines.length + 1,
                itemBuilder: (ctx, i) {
                  if (i == 0) {
                    return ListTile(
                      leading: CircleAvatar(
                        backgroundColor: c.brandSoft,
                        child: Icon(Icons.apps_rounded, size: 16, color: c.brand),
                      ),
                      title: Text(
                        'All Medicines (Consolidated)',
                        style: TextStyle(fontWeight: FontWeight.w700, color: c.textPrimary),
                      ),
                      subtitle: Text(
                        'Show ledger for all stock items combined',
                        style: TextStyle(color: c.textSecondary, fontSize: 12),
                      ),
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
                      backgroundColor: c.brandSoft,
                      child: Icon(Icons.medication_rounded, size: 16, color: c.brand),
                    ),
                    title: Text(
                      cleanName.isNotEmpty ? cleanName : (med['name'] ?? ''),
                      style: TextStyle(fontWeight: FontWeight.w700, color: c.textPrimary),
                    ),
                    subtitle: Text(
                      '${med['type']} • ${med['dose'] ?? 'No Dose'} • Qty: ${med['quantity']}',
                      style: TextStyle(color: c.textSecondary, fontSize: 12),
                    ),
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
    final c = context.comfort;
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const GEmptyIllustration(
            GEmptyIllustrationKind.activity,
            size: 152,
            fallbackIcon: Icons.query_stats_rounded,
          ),
          const SizedBox(height: 14),
          Text(msg, style: TextStyle(color: c.textSecondary, fontSize: 15, fontWeight: FontWeight.w600)),
        ],
      ),
    );
  }
}
