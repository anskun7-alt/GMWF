// lib/pages/download_screen.dart — Enhanced with Date Range & Visualizations
// Note: excel package aliased as 'xl' to avoid Border conflict with Flutter

import 'dart:convert';
import 'package:gmwf/design/tokens/soft_palette.dart';
import 'dart:io';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:excel/excel.dart' as xl;
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:gmwf/pages/home/home_module_host.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:hive_flutter/hive_flutter.dart';
import '../services/local_storage_service.dart';
import '../services/finance_local_storage.dart';
import '../services/donations_local_storage.dart';
import 'school/utils/school_local_storage.dart';
import '../theme/role_theme_provider.dart';
import '../theme/app_theme.dart';
import '../design/design_system.dart';
import '../widgets/file_action_helper.dart';

// ─── Date Filter Mode ────────────────────────────────────────────────────────
enum DateFilterMode { allTime, singleDay, dateRange }

class DownloadScreen extends StatefulWidget {
  /// When non-null, the screen is locked to this branch only.
  /// Pass this for branch managers and supervisors.
  final String? lockedBranchId;

  const DownloadScreen({super.key, this.lockedBranchId});

  @override
  State<DownloadScreen> createState() => _DownloadScreenState();
}

class _DownloadScreenState extends State<DownloadScreen>
    with TickerProviderStateMixin {
  String? _selectedBranch;
  bool _isDownloadingJson = false;
  bool _isDownloadingExcel = false;
  String _statusMessage = 'Ready';

  // Date filter state
  DateFilterMode _dateMode = DateFilterMode.allTime;
  DateTime? _singleDate;
  DateTime? _rangeStart;
  DateTime? _rangeEnd;

  // Live counts across all modules
  int _totalPatients = 0, _totalTokens = 0, _totalPrescriptions = 0, _totalDispensary = 0;
  int _totalDonations = 0, _totalFood = 0, _totalFoodStock = 0, _totalFoodLogs = 0, _totalCredits = 0;
  int _totalMadrassaS = 0, _totalMadrassaL = 0;
  int _totalSchoolStudents = 0, _totalSchoolTeachers = 0, _totalSchoolLogs = 0;
  int _totalSchoolBooks = 0, _totalSchoolBookLoans = 0, _totalSchoolGrades = 0, _totalSchoolAudit = 0;
  int _totalOfficeBoyTasks = 0, _totalOfficeBoyLogs = 0;
  int _totalFinanceLoans = 0, _totalExpenses = 0;
  int _totalEmployees = 0, _totalSalaryHistory = 0;

  // Animation controllers
  late AnimationController _cardController;
  late AnimationController _statsController;
  late Animation<double> _cardFade;
  late Animation<double> _statsFade;

  final List<Map<String, String>> _availableBranches = [];
  final Set<String> _selectedCategories = {
    'dispensary',
    'dasterkhwaan',
    'madrassa',
    'school',
    'donations',
    'officeboy',
    'finance',
    'hr',
  };
  bool _isLoadingBranches = true;

  final List<Map<String, dynamic>> _categoryDef = [
    {'id': 'dispensary', 'label': 'Dispensary', 'icon': Icons.medication_outlined, 'color': SoftPalette.teal500},
    {'id': 'dasterkhwaan', 'label': 'Dasterkhwaan & Food Stock', 'icon': Icons.restaurant_rounded, 'color': SoftPalette.orange400},
    {'id': 'madrassa', 'label': 'Madrassa Module', 'icon': Icons.menu_book_rounded, 'color': SoftPalette.indigo550},
    {'id': 'school', 'label': 'School System (TWT)', 'icon': Icons.school_rounded, 'color': SoftPalette.indigo500},
    {'id': 'donations', 'label': 'Donations & Credit', 'icon': Icons.volunteer_activism_outlined, 'color': SoftPalette.pink550},
    {'id': 'officeboy', 'label': 'Food Tokens (Dasterkhwaan)', 'icon': Icons.confirmation_number_rounded, 'color': SoftPalette.amber300},
    {'id': 'finance', 'label': 'Finance, Loans & Expenses', 'icon': Icons.account_balance_wallet_rounded, 'color': SoftPalette.emerald350},
    {'id': 'hr', 'label': 'HR & Staff Payroll', 'icon': Icons.badge_rounded, 'color': SoftPalette.sky500},
  ];

  @override
  void initState() {
    super.initState();
    _cardController = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 480));
    _statsController = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 380));
    _cardFade = CurvedAnimation(
        parent: _cardController, curve: Curves.easeOutCubic);
    _statsFade = CurvedAnimation(
        parent: _statsController, curve: Curves.easeOutCubic);
    _cardController.forward();

    // Pre-select locked branch immediately.
    if (widget.lockedBranchId != null && widget.lockedBranchId!.isNotEmpty) {
      _selectedBranch = widget.lockedBranchId;
    }

    _loadBranches();
  }

  Future<void> _loadBranches() async {
    // ── Branch-locked mode: only fetch the one assigned branch ────────────
    if (widget.lockedBranchId != null && widget.lockedBranchId!.isNotEmpty) {
      final bid = widget.lockedBranchId!;
      try {
        final doc = await FirebaseFirestore.instance
            .collection('branches')
            .doc(bid)
            .get();
        final name = (doc.data()?['name'] as String?) ?? bid;
        if (mounted) {
          setState(() {
            _availableBranches
              ..clear()
              ..add({'id': bid, 'name': name});
            _selectedBranch = bid;
            _isLoadingBranches = false;
          });
        }
      } catch (_) {
        if (mounted) {
          setState(() {
            _availableBranches
              ..clear()
              ..add({'id': bid, 'name': bid});
            _selectedBranch = bid;
            _isLoadingBranches = false;
          });
        }
      }
      return;
    }
    // ── Global roles: check local Hive branches first (instant, 0 reads) ──
    final localBranches = LocalStorageService.getLocalBranchesList();
    if (localBranches.isNotEmpty) {
      if (mounted) {
        setState(() {
          _availableBranches.clear();
          _availableBranches.add({'id': 'all', 'name': 'All Branches'});
          _availableBranches.addAll(localBranches.map((b) => {'id': b['id'].toString(), 'name': b['name'].toString()}));
          _isLoadingBranches = false;
        });
      }
      return;
    }

    // Fallback: fetch from Firestore if local cache is completely empty
    try {
      final snap = await FirebaseFirestore.instance.collection('branches').get();
      final list = <Map<String, String>>[];
      final localBranchesBox = Hive.box(LocalStorageService.branchesBox);
      for (final d in snap.docs) {
        final data = d.data();
        final name = (data['name'] ?? d.id).toString();
        list.add({'id': d.id, 'name': name});
        await localBranchesBox.put('branch:${d.id}', {'id': d.id, 'name': name});
      }
      
      if (mounted) {
        setState(() {
          _availableBranches.clear();
          _availableBranches.add({'id': 'all', 'name': 'All Branches'});
          _availableBranches.addAll(list);
          _isLoadingBranches = false;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _isLoadingBranches = false);
    }
  }

  @override
  void dispose() {
    _cardController.dispose();
    _statsController.dispose();
    super.dispose();
  }

  // ─── Sanitisers ─────────────────────────────────────────────────────────────
  dynamic _sanitizeValue(dynamic value) {
    if (value is Timestamp) return value.toDate().toIso8601String();
    if (value is Map) {
      return value.map(
          (k, v) => MapEntry(k.toString(), _sanitizeValue(v)));
    }
    if (value is List) return value.map(_sanitizeValue).toList();
    return value ?? '';
  }

  Map<String, dynamic> _sanitizeForJson(Map<String, dynamic> data) =>
      data.map((key, value) =>
          MapEntry(key.toString(), _sanitizeValue(value)));

  // ─── Date helpers ────────────────────────────────────────────────────────────
  String get _dateLabel {
    switch (_dateMode) {
      case DateFilterMode.allTime:
        return 'All Time';
      case DateFilterMode.singleDay:
        return _singleDate != null
            ? DateFormat('dd MMM yyyy').format(_singleDate!)
            : 'Pick a date';
      case DateFilterMode.dateRange:
        if (_rangeStart != null && _rangeEnd != null) {
          return '${DateFormat('dd MMM').format(_rangeStart!)} → ${DateFormat('dd MMM yyyy').format(_rangeEnd!)}';
        }
        return 'Pick range';
    }
  }

  bool _isDateInRange(String? dateStr) {
    if (dateStr == null || _dateMode == DateFilterMode.allTime) return true;
    try {
      // dateStr may be "yyyy-MM-dd" (from serials doc id) or ISO8601
      final date = dateStr.length == 10
          ? DateFormat('yyyy-MM-dd').parse(dateStr)
          : DateTime.parse(dateStr);
      if (_dateMode == DateFilterMode.singleDay && _singleDate != null) {
        return date.year == _singleDate!.year &&
            date.month == _singleDate!.month &&
            date.day == _singleDate!.day;
      }
      if (_dateMode == DateFilterMode.dateRange &&
          _rangeStart != null &&
          _rangeEnd != null) {
        final start =
            DateTime(_rangeStart!.year, _rangeStart!.month, _rangeStart!.day);
        final end = DateTime(
            _rangeEnd!.year, _rangeEnd!.month, _rangeEnd!.day, 23, 59, 59);
        return date.isAfter(start.subtract(const Duration(seconds: 1))) &&
            date.isBefore(end.add(const Duration(seconds: 1)));
      }
    } catch (_) {}
    return true;
  }

  // ─── Date pickers ────────────────────────────────────────────────────────────
  Future<void> _pickSingleDate(RoleThemeData t) async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _singleDate ?? DateTime.now(),
      firstDate: DateTime(2020),
      lastDate: DateTime.now(),
      builder: (ctx, child) => _datePickerTheme(ctx, child, t),
    );
    if (picked != null) setState(() => _singleDate = picked);
  }

  Future<void> _pickDateRange(RoleThemeData t) async {
    final picked = await showDateRangePicker(
      context: context,
      initialDateRange: (_rangeStart != null && _rangeEnd != null)
          ? DateTimeRange(start: _rangeStart!, end: _rangeEnd!)
          : null,
      firstDate: DateTime(2020),
      lastDate: DateTime.now(),
      builder: (ctx, child) => _datePickerTheme(ctx, child, t),
    );
    if (picked != null) {
      setState(() {
        _rangeStart = picked.start;
        _rangeEnd = picked.end;
      });
    }
  }

  Widget _datePickerTheme(
      BuildContext ctx, Widget? child, RoleThemeData t) {
    return Theme(
      data: Theme.of(ctx).copyWith(
        colorScheme: ColorScheme.dark(
          primary: t.accent,
          onPrimary: SoftPalette.gray50,
          surface: t.bgCard,
          onSurface: t.textPrimary,
        ), dialogTheme: DialogThemeData(backgroundColor: t.bgCard),
      ),
      child: child!,
    );
  }

  // ─── Excel sheet builder ─────────────────────────────────────────────────────
  void _addSheet(xl.Excel excel, String sheetName,
      List<Map<String, dynamic>> data) {
    if (data.isEmpty) {
      excel[sheetName];
      return;
    }
    final sheet = excel[sheetName];
    final headers = data.first.keys.toList();
    sheet.appendRow(
        headers.map((h) => xl.TextCellValue(h.toString())).toList());
    for (final row in data) {
      sheet.appendRow(
          headers.map((h) => xl.TextCellValue(row[h].toString())).toList());
    }
  }

  List<Map<String, dynamic>> _getHiveData(String boxName, String branchId) {
    if (!Hive.isBoxOpen(boxName)) return [];
    final box = Hive.box(boxName);
    final prefix = '${branchId.toLowerCase()}__';
    final results = <Map<String, dynamic>>[];
    for (final key in box.keys) {
      if (branchId == 'all' || key.toString().toLowerCase().startsWith(prefix)) {
        final val = box.get(key);
        if (val is Map) {
          final mapData = Map<String, dynamic>.from(val);
          mapData['key'] = key.toString();
          results.add(_sanitizeForJson(mapData));
        }
      }
    }
    return results;
  }

  // ignore: unused_element
  void _addUniqueRecords(List<Map<String, dynamic>> targetList, List<Map<String, dynamic>> sourceList, String idKey) {
    final existingIds = targetList.map((e) => (e[idKey] ?? e['id'] ?? e['key'] ?? '').toString()).toSet();
    for (final item in sourceList) {
      final id = (item[idKey] ?? item['id'] ?? item['key'] ?? '').toString();
      if (id.isNotEmpty && !existingIds.contains(id)) {
        targetList.add(item);
        existingIds.add(id);
      }
    }
  }

  // ─── Core data fetcher (with date filtering) ──────────────────────────────
  Future<Map<String, dynamic>> _fetchAllData() async {
    final selectedId = _selectedBranch!;
    final bool downloadAll = selectedId == 'all';
    final db = FirebaseFirestore.instance;

    List<String> branchIdsToProcess = [];
    if (downloadAll) {
      branchIdsToProcess = _availableBranches
          .where((b) => b['id'] != 'all')
          .map((b) => b['id']!)
          .toList();
      if (branchIdsToProcess.isEmpty) throw 'No branches found';
    } else {
      branchIdsToProcess = [selectedId];
    }

    final List<Map<String, dynamic>> allPatients = [];
    final List<Map<String, dynamic>> allTokens = [];
    final List<Map<String, dynamic>> allPrescriptions = [];
    final List<Map<String, dynamic>> allDispensary = [];

    final List<Map<String, dynamic>> allDonations = [];
    final List<Map<String, dynamic>> allCredits = [];

    final List<Map<String, dynamic>> allFood = [];
    final List<Map<String, dynamic>> allFoodStock = [];
    final List<Map<String, dynamic>> allFoodLogs = [];

    final List<Map<String, dynamic>> allMadrassaStudents = [];
    final List<Map<String, dynamic>> allMadrassaLogs = [];

    final List<Map<String, dynamic>> allSchoolStudents = [];
    final List<Map<String, dynamic>> allSchoolTeachers = [];
    final List<Map<String, dynamic>> allSchoolLogs = [];
    final List<Map<String, dynamic>> allSchoolBooks = [];
    final List<Map<String, dynamic>> allSchoolBookLoans = [];
    final List<Map<String, dynamic>> allSchoolGrades = [];
    final List<Map<String, dynamic>> allSchoolAudit = [];

    final List<Map<String, dynamic>> allOfficeBoyTasks = [];
    final List<Map<String, dynamic>> allOfficeBoyLogs = [];

    final List<Map<String, dynamic>> allFinanceLoans = [];
    final List<Map<String, dynamic>> allExpenses = [];

    final List<Map<String, dynamic>> allEmployees = [];
    final List<Map<String, dynamic>> allSalaryHistory = [];

    int patients = 0, tokens = 0, prescriptions = 0, dispensary = 0;
    int donations = 0, credits = 0;
    int food = 0, foodStock = 0, foodLogs = 0;
    int madrassaS = 0, madrassaL = 0;
    int schoolS = 0, schoolT = 0, schoolLogs = 0, schoolBooks = 0, schoolLoans = 0, schoolGrades = 0, schoolAudit = 0;
    int obTasks = 0, obLogs = 0;
    int financeLoans = 0, expenses = 0;
    int employees = 0, salaryHistory = 0;

    // Pre-calculate date keys
    List<String> dsLegacyKeys = []; // ddMMyy
    List<String> dsDashKeys   = []; // yyyy-MM-dd

    if (_dateMode != DateFilterMode.allTime) {
      DateTime start = _dateMode == DateFilterMode.singleDay ? _singleDate! : _rangeStart!;
      DateTime end   = _dateMode == DateFilterMode.singleDay ? _singleDate! : _rangeEnd!;
      start = DateTime(start.year, start.month, start.day);
      end   = DateTime(end.year, end.month, end.day);
      int days = end.difference(start).inDays + 1;
      if (days > 400) days = 400;

      for (int i = 0; i < days; i++) {
        final d = start.add(Duration(days: i));
        dsLegacyKeys.add(DateFormat('ddMMyy').format(d));
        dsDashKeys.add(DateFormat('yyyy-MM-dd').format(d));
      }
    }

    final hasDispensary    = _selectedCategories.contains('dispensary');
    final hasDasterkhwaan  = _selectedCategories.contains('dasterkhwaan');
    final hasMadrassa      = _selectedCategories.contains('madrassa');
    final hasSchool        = _selectedCategories.contains('school');
    final hasDonations     = _selectedCategories.contains('donations');
    final hasOfficeBoy     = _selectedCategories.contains('officeboy');
    final hasFinance       = _selectedCategories.contains('finance');
    final hasHR            = _selectedCategories.contains('hr');

    for (final bid in branchIdsToProcess) {
      final bName = _availableBranches.firstWhere((b) => b['id'] == bid, orElse: () => {'name': bid})['name'] ?? bid;
      setState(() => _statusMessage = 'Fetching $bName records…');

      // ── 1. DISPENSARY ──
      if (hasDispensary) {
        // A. Patients: Local Hive first (instant, 0 reads)
        final localPatients = LocalStorageService.getAllLocalPatients(branchId: bid);
        for (final p in localPatients) {
          final sanitized = _sanitizeForJson(p);
          if (_isDateInRange(sanitized['registrationDate'] ?? sanitized['createdAt'])) {
            allPatients.add(sanitized);
            patients++;
          }
        }
        // Remote fallback only if local box is completely empty for this branch
        if (allPatients.isEmpty) {
          try {
            final snap = await db.collection('branches').doc(bid).collection('patients').limit(1000).get();
            for (final doc in snap.docs) {
              final data = doc.data(); data['patientId'] = doc.id; data['branchId'] = bid;
              final sanitized = _sanitizeForJson(data);
              if (_isDateInRange(sanitized['registrationDate'] ?? sanitized['createdAt'])) {
                allPatients.add(sanitized); patients++;
              }
            }
          } catch (_) {}
        }

        // B. Tokens: Local Hive entries first (instant, 0 reads)
        final localEntries = LocalStorageService.getLocalEntries(bid);
        for (final t in localEntries) {
          final d = Map<String, dynamic>.from(t);
          d['branchId'] = bid;
          final dateStr = (d['dateKey'] ?? d['date'] ?? d['createdAt'] ?? '').toString();
          if (_isDateInRange(dateStr)) {
            allTokens.add(_sanitizeForJson(d));
            tokens++;
          }
        }
        // Remote fallback only if local box had 0 tokens
        if (allTokens.isEmpty) {
          try {
            if (_dateMode == DateFilterMode.allTime) {
              final snap = await db.collection('branches').doc(bid).collection('serials').limit(45).get();
              for (final dateDoc in snap.docs) {
                for (final type in ['zakat', 'non-zakat', 'gmwf']) {
                  final qSnap = await dateDoc.reference.collection(type).limit(300).get();
                  for (final doc in qSnap.docs) {
                    final d = doc.data();
                    d['serial'] = doc.id; d['date'] = dateDoc.id; d['queueType'] = type; d['branchId'] = bid;
                    allTokens.add(_sanitizeForJson(d)); tokens++;
                  }
                }
              }
            } else {
              await Future.wait(dsLegacyKeys.map((key) async {
                final dateDoc = db.collection('branches').doc(bid).collection('serials').doc(key);
                await Future.wait(['zakat', 'non-zakat', 'gmwf'].map((type) async {
                  try {
                    final qSnap = await dateDoc.collection(type).limit(300).get();
                    for (final doc in qSnap.docs) {
                      final d = doc.data();
                      d['serial'] = doc.id; d['date'] = key; d['queueType'] = type; d['branchId'] = bid;
                      allTokens.add(_sanitizeForJson(d)); tokens++;
                    }
                  } catch (_) {}
                }));
              }));
            }
          } catch (_) {}
        }

        // C. Prescriptions: Local Hive first
        final localPrescriptions = _getHiveData(LocalStorageService.prescriptionsBox, bid);
        for (final p in localPrescriptions) {
          final sanitized = _sanitizeForJson(p);
          if (_isDateInRange(sanitized['date'] ?? sanitized['createdAt'])) {
            allPrescriptions.add(sanitized);
            prescriptions++;
          }
        }
        if (allPrescriptions.isEmpty) {
          try {
            final patientSnap = await db.collection('branches').doc(bid).collection('prescriptions').limit(150).get();
            for (final pDoc in patientSnap.docs) {
              final prescSnap = await pDoc.reference.collection('prescriptions').limit(100).get();
              for (final doc in prescSnap.docs) {
                final data = doc.data();
                data['prescriptionId'] = doc.id; data['patientCnic'] = pDoc.id; data['branchId'] = bid;
                final sanitized = _sanitizeForJson(data);
                if (_isDateInRange(sanitized['date'] ?? sanitized['createdAt'])) {
                  allPrescriptions.add(sanitized); prescriptions++;
                }
              }
            }
          } catch (_) {}
        }

        // D. Inventory: Local Hive stockBox first
        if (Hive.isBoxOpen(LocalStorageService.stockBox)) {
          final sBox = Hive.box(LocalStorageService.stockBox);
          for (final key in sBox.keys) {
            final val = sBox.get(key);
            if (val is Map) {
              final d = Map<String, dynamic>.from(val);
              final itemBranch = (d['branchId'] ?? '').toString().toLowerCase().trim();
              if (itemBranch.isEmpty || itemBranch == bid.toLowerCase().trim() || bid == 'all') {
                d['itemId'] = key.toString();
                d['branchId'] = bid;
                allDispensary.add(_sanitizeForJson(d));
                dispensary++;
              }
            }
          }
        }
        if (allDispensary.isEmpty) {
          try {
            final snap = await db.collection('branches').doc(bid).collection('inventory').limit(1000).get();
            for (final doc in snap.docs) {
              final data = doc.data(); data['itemId'] = doc.id; data['branchId'] = bid;
              allDispensary.add(_sanitizeForJson(data)); dispensary++;
            }
          } catch (_) {}
        }
      }

      // ── 2. DASTERKHWAAN & FOOD STOCK ──
      if (hasDasterkhwaan) {
        // Food tokens: Local Hive first
        final localFood = _getHiveData(LocalStorageService.dasterkhwaanTokensBox, bid);
        for (final d in localFood) {
          if (_isDateInRange(d['date'] ?? d['createdAt'] ?? d['timestamp'])) {
            allFood.add(d);
            food++;
          }
        }
        if (allFood.isEmpty) {
          try {
            if (_dateMode == DateFilterMode.allTime) {
              final snap = await db.collection('branches').doc(bid).collection('dasterkhwaan').limit(45).get();
              for (final dateDoc in snap.docs) {
                final qSnap = await dateDoc.reference.collection('tokens').limit(300).get();
                for (final doc in qSnap.docs) {
                  final d = doc.data();
                  d['id'] = doc.id; d['date'] = dateDoc.id; d['branchId'] = bid;
                  allFood.add(_sanitizeForJson(d)); food++;
                }
              }
            } else {
              await Future.wait(dsDashKeys.map((key) async {
                try {
                  final qSnap = await db.collection('branches').doc(bid).collection('dasterkhwaan').doc(key).collection('tokens').limit(300).get();
                  for (final doc in qSnap.docs) {
                    final d = doc.data(); d['id'] = doc.id; d['date'] = key; d['branchId'] = bid;
                    allFood.add(_sanitizeForJson(d)); food++;
                  }
                } catch (_) {}
              }));
            }
          } catch (_) {}
        }

        // Food Stock Inventory: Local Hive first
        final localFoodStock = _getHiveData('dasterkhwaan_stock', bid);
        allFoodStock.addAll(localFoodStock);
        foodStock = allFoodStock.length;
        if (allFoodStock.isEmpty) {
          try {
            final snap = await db.collection('branches').doc(bid).collection('dasterkhwaan_stock').limit(500).get();
            for (final doc in snap.docs) {
              final d = doc.data(); d['id'] = doc.id; d['branchId'] = bid;
              allFoodStock.add(_sanitizeForJson(d)); foodStock++;
            }
          } catch (_) {}
        }

        // Food Stock Deduction Logs: Local Hive first
        final localFoodLogs = _getHiveData('dasterkhwaan_stock_logs', bid);
        for (final d in localFoodLogs) {
          if (_isDateInRange(d['timestamp'] ?? d['date'])) {
            allFoodLogs.add(d);
            foodLogs++;
          }
        }
        if (allFoodLogs.isEmpty) {
          try {
            final snap = await db.collection('branches').doc(bid).collection('dasterkhwaan_stock_logs').limit(500).get();
            for (final doc in snap.docs) {
              final d = doc.data(); d['id'] = doc.id; d['branchId'] = bid;
              if (_isDateInRange(d['timestamp'] ?? d['date'])) {
                allFoodLogs.add(_sanitizeForJson(d)); foodLogs++;
              }
            }
          } catch (_) {}
        }
      }

      // ── 3. MADRASSA MODULE ──
      if (hasMadrassa) {
        // Students: Local Hive first
        final localMadrassaS = _getHiveData(LocalStorageService.madrassaStudentsBox, bid);
        allMadrassaStudents.addAll(localMadrassaS);
        madrassaS = allMadrassaStudents.length;
        if (allMadrassaStudents.isEmpty) {
          try {
            final snap = await db.collection('branches').doc(bid).collection('madrassa_students').limit(500).get();
            for (final doc in snap.docs) {
              final data = doc.data(); data['studentId'] = doc.id; data['branchId'] = bid;
              allMadrassaStudents.add(_sanitizeForJson(data)); madrassaS++;
            }
          } catch (_) {}
        }

        // Daily Logs: Local Hive first
        final localMadrassaLogs = _getHiveData(LocalStorageService.madrassaLogsBox, bid);
        for (final d in localMadrassaLogs) {
          if (_isDateInRange(d['date'] ?? d['dateKey'])) {
            allMadrassaLogs.add(d);
            madrassaL++;
          }
        }
        if (allMadrassaLogs.isEmpty) {
          try {
            if (_dateMode == DateFilterMode.allTime) {
              final snap = await db.collection('branches').doc(bid).collection('madrassa_daily_logs').limit(60).get();
              for (final doc in snap.docs) {
                final d = doc.data(); d['date'] = doc.id; d['branchId'] = bid;
                allMadrassaLogs.add(_sanitizeForJson(d)); madrassaL++;
              }
            } else {
              await Future.wait(dsDashKeys.map((key) async {
                try {
                  final doc = await db.collection('branches').doc(bid).collection('madrassa_daily_logs').doc(key).get();
                  if (doc.exists) {
                    final d = doc.data() as Map<String, dynamic>; d['date'] = doc.id; d['branchId'] = bid;
                    allMadrassaLogs.add(_sanitizeForJson(d)); madrassaL++;
                  }
                } catch (_) {}
              }));
            }
          } catch (_) {}
        }
      }

      // ── 4. SCHOOL SYSTEM (TWT) ──
      if (hasSchool) {
        // Students: Local first
        final localSchoolS = SchoolLocalStorage.getAllStudentsCached(bid);
        allSchoolStudents.addAll(localSchoolS.map((e) => _sanitizeForJson(Map<String, dynamic>.from(e))));
        schoolS = allSchoolStudents.length;
        if (allSchoolStudents.isEmpty) {
          try {
            final snap = await db.collection('branches').doc(bid).collection('school_students').limit(500).get();
            for (final doc in snap.docs) {
              final d = doc.data(); d['id'] = doc.id; d['branchId'] = bid;
              allSchoolStudents.add(_sanitizeForJson(d)); schoolS++;
            }
          } catch (_) {}
        }

        // Teachers: Local first
        final localSchoolT = SchoolLocalStorage.getAllTeachersCached(bid);
        allSchoolTeachers.addAll(localSchoolT.map((e) => _sanitizeForJson(Map<String, dynamic>.from(e))));
        schoolT = allSchoolTeachers.length;
        if (allSchoolTeachers.isEmpty) {
          try {
            final snap = await db.collection('branches').doc(bid).collection('school_teachers').limit(200).get();
            for (final doc in snap.docs) {
              final d = doc.data(); d['id'] = doc.id; d['branchId'] = bid;
              allSchoolTeachers.add(_sanitizeForJson(d)); schoolT++;
            }
          } catch (_) {}
        }

        // Attendance Logs: Local first
        final localSchoolLogs = _getHiveData(LocalStorageService.schoolLogsBox, bid);
        for (final d in localSchoolLogs) {
          if (_isDateInRange(d['dateKey'] ?? d['date'] ?? d['id'])) {
            allSchoolLogs.add(d);
            schoolLogs++;
          }
        }
        if (allSchoolLogs.isEmpty) {
          try {
            final snap = await db.collection('branches').doc(bid).collection('school_logs').limit(200).get();
            for (final doc in snap.docs) {
              final d = doc.data(); d['dateKey'] = doc.id; d['branchId'] = bid;
              if (_isDateInRange(doc.id)) {
                allSchoolLogs.add(_sanitizeForJson(d)); schoolLogs++;
              }
            }
          } catch (_) {}
        }

        // Books: Local first
        allSchoolBooks.addAll(SchoolLocalStorage.getAllBooksCached(bid).map((e) => _sanitizeForJson(Map<String, dynamic>.from(e))));
        schoolBooks = allSchoolBooks.length;
        if (allSchoolBooks.isEmpty) {
          try {
            final snap = await db.collection('branches').doc(bid).collection('school_books').limit(500).get();
            for (final doc in snap.docs) {
              final d = doc.data(); d['id'] = doc.id; d['branchId'] = bid;
              allSchoolBooks.add(_sanitizeForJson(d)); schoolBooks++;
            }
          } catch (_) {}
        }

        // Book Loans: Local first
        allSchoolBookLoans.addAll(SchoolLocalStorage.getAllBookLoansCached(bid).map((e) => _sanitizeForJson(Map<String, dynamic>.from(e))));
        schoolLoans = allSchoolBookLoans.length;
        if (allSchoolBookLoans.isEmpty) {
          try {
            final snap = await db.collection('branches').doc(bid).collection('school_book_loans').limit(500).get();
            for (final doc in snap.docs) {
              final d = doc.data(); d['id'] = doc.id; d['branchId'] = bid;
              allSchoolBookLoans.add(_sanitizeForJson(d)); schoolLoans++;
            }
          } catch (_) {}
        }

        // Grades: Local first
        allSchoolGrades.addAll(SchoolLocalStorage.getAllGradesCached(bid).map((e) => _sanitizeForJson(Map<String, dynamic>.from(e))));
        schoolGrades = allSchoolGrades.length;
        if (allSchoolGrades.isEmpty) {
          try {
            final snap = await db.collection('branches').doc(bid).collection('school_grades').limit(500).get();
            for (final doc in snap.docs) {
              final d = doc.data(); d['id'] = doc.id; d['branchId'] = bid;
              allSchoolGrades.add(_sanitizeForJson(d)); schoolGrades++;
            }
          } catch (_) {}
        }

        // Audit Logs: Local first
        final localSchoolAudit = SchoolLocalStorage.getAuditLogsCached(bid);
        for (final a in localSchoolAudit) {
          final d = _sanitizeForJson(Map<String, dynamic>.from(a));
          if (_isDateInRange(d['timestamp'])) {
            allSchoolAudit.add(d);
            schoolAudit++;
          }
        }
        if (allSchoolAudit.isEmpty) {
          try {
            final snap = await db.collection('branches').doc(bid).collection('school_audit_logs').limit(300).get();
            for (final doc in snap.docs) {
              final d = doc.data(); d['id'] = doc.id; d['branchId'] = bid;
              if (_isDateInRange(d['timestamp'])) {
                allSchoolAudit.add(_sanitizeForJson(d)); schoolAudit++;
              }
            }
          } catch (_) {}
        }
      }

      // ── 5. DONATIONS & CREDIT LEDGER ──
      if (hasDonations) {
        // Donations: Local Hive first
        final localDons = DonationsLocalStorage.getAllDonations(bid);
        for (final d in localDons) {
          final m = _sanitizeForJson(d.toMap());
          m['branchId'] = bid;
          final dateStr = (m['date'] ?? m['createdAt'] ?? '').toString();
          if (_isDateInRange(dateStr)) {
            allDonations.add(m);
            donations++;
          }
        }
        if (allDonations.isEmpty) {
          try {
            Query q = db.collection('branches').doc(bid).collection('donations');
            if (_dateMode != DateFilterMode.allTime) {
              q = q.where('date', isGreaterThanOrEqualTo: dsDashKeys.first).where('date', isLessThanOrEqualTo: dsDashKeys.last);
            }
            final snap = await q.limit(500).get();
            for (final doc in snap.docs) {
              if (doc.id == 'credit_ledger') continue;
              final d = doc.data() as Map<String, dynamic>; d['id'] = doc.id; d['branchId'] = bid;
              allDonations.add(_sanitizeForJson(d)); donations++;
            }
          } catch (_) {}
        }

        // Credit Ledger: Local first
        final localCredits = _getHiveData('creditLedger', bid);
        for (final c in localCredits) {
          if (_isDateInRange(c['date'] ?? c['createdAt'])) {
            allCredits.add(c);
            credits++;
          }
        }
        if (allCredits.isEmpty) {
          try {
            Query q = db.collection('branches').doc(bid).collection('creditLedger');
            if (_dateMode != DateFilterMode.allTime) {
              q = q.where('date', isGreaterThanOrEqualTo: dsDashKeys.first).where('date', isLessThanOrEqualTo: dsDashKeys.last);
            }
            final snap = await q.limit(300).get();
            for (final doc in snap.docs) {
              final d = doc.data() as Map<String, dynamic>; d['id'] = doc.id; d['branchId'] = bid;
              allCredits.add(_sanitizeForJson(d)); credits++;
            }
          } catch (_) {}
        }
      }

      // ── 6. OFFICE BOY MODULE ──
      if (hasOfficeBoy) {
        final localObTasks = _getHiveData('office_boy_tasks', bid);
        allOfficeBoyTasks.addAll(localObTasks);
        obTasks = allOfficeBoyTasks.length;
        if (allOfficeBoyTasks.isEmpty) {
          try {
            final snap = await db.collection('branches').doc(bid).collection('office_boy_tasks').limit(300).get();
            for (final doc in snap.docs) {
              final d = doc.data(); d['id'] = doc.id; d['branchId'] = bid;
              allOfficeBoyTasks.add(_sanitizeForJson(d)); obTasks++;
            }
          } catch (_) {}
        }

        final localObLogs = _getHiveData('office_boy_logs', bid);
        allOfficeBoyLogs.addAll(localObLogs);
        obLogs = allOfficeBoyLogs.length;
        if (allOfficeBoyLogs.isEmpty) {
          try {
            final snap = await db.collection('branches').doc(bid).collection('office_boy_logs').limit(300).get();
            for (final doc in snap.docs) {
              final d = doc.data(); d['id'] = doc.id; d['branchId'] = bid;
              allOfficeBoyLogs.add(_sanitizeForJson(d)); obLogs++;
            }
          } catch (_) {}
        }
      }

      // ── 7. FINANCE & EXPENSES ──
      if (hasFinance) {
        final localLoans = _getHiveData(LocalStorageService.financeLoansBox, bid);
        allFinanceLoans.addAll(localLoans);
        financeLoans = allFinanceLoans.length;
        if (allFinanceLoans.isEmpty) {
          try {
            final snap = await db.collection('branches').doc(bid).collection('finance_loans').limit(500).get();
            for (final doc in snap.docs) {
              final d = doc.data(); d['id'] = doc.id; d['branchId'] = bid;
              allFinanceLoans.add(_sanitizeForJson(d)); financeLoans++;
            }
          } catch (_) {}
        }

        final localExp = _getHiveData(LocalStorageService.expensesBox, bid);
        for (final e in localExp) {
          if (_isDateInRange(e['date'] ?? e['timestamp'])) {
            allExpenses.add(e);
            expenses++;
          }
        }
        if (allExpenses.isEmpty) {
          try {
            final snap = await db.collection('branches').doc(bid).collection('expenses').limit(500).get();
            for (final doc in snap.docs) {
              final d = doc.data(); d['id'] = doc.id; d['branchId'] = bid;
              if (_isDateInRange(d['date'] ?? d['timestamp'])) {
                allExpenses.add(_sanitizeForJson(d)); expenses++;
              }
            }
          } catch (_) {}
        }
      }

      // ── 8. HR & PAYROLL ──
      if (hasHR) {
        final seenEmpMap = <String, Map<String, dynamic>>{};

        // A. Load local Hive records first (instant and offline-ready)
        final localHr = FinanceLocalStorage.getEmployees(bid);
        for (final emp in localHr) {
          if (FinanceLocalStorage.isExecutiveEmployee(emp)) continue;
          final key = (emp['cnic'] ?? emp['localId'] ?? emp['id'] ?? '').toString().trim();
          if (key.isNotEmpty) {
            seenEmpMap[key] = {
              ...emp,
              'id': emp['localId'] ?? emp['id'],
              'branchId': bid,
              'department': FinanceLocalStorage.normalizeDepartment(emp['department']?.toString()),
              'camp': FinanceLocalStorage.getEmployeeCamp(emp),
            };
          }
        }

        // B. Query Firestore if online
        try {
          final snap = await db.collection('branches').doc(bid).collection('employees').limit(300).get().timeout(const Duration(seconds: 4));
          for (final doc in snap.docs) {
            final d = doc.data();
            d['id'] = doc.id;
            d['branchId'] = bid;
            if (FinanceLocalStorage.isExecutiveEmployee(d)) continue;
            final key = (d['cnic'] ?? d['id'] ?? '').toString().trim();
            if (key.isNotEmpty && !seenEmpMap.containsKey(key)) {
              seenEmpMap[key] = {
                ...d,
                'department': FinanceLocalStorage.normalizeDepartment(d['department']?.toString()),
                'camp': FinanceLocalStorage.getEmployeeCamp(d),
              };
            }
          }
        } catch (_) {}

        for (final emp in seenEmpMap.values) {
          allEmployees.add(_sanitizeForJson(emp));
        }
        employees = allEmployees.length;

        final localSalary = _getHiveData(LocalStorageService.salaryHistoryBox, bid);
        for (final s in localSalary) {
          if (_isDateInRange(s['month'] ?? s['date'])) {
            allSalaryHistory.add(s);
            salaryHistory++;
          }
        }
        if (allSalaryHistory.isEmpty) {
          try {
            final snap = await db.collection('branches').doc(bid).collection('salary_history').limit(500).get();
            for (final doc in snap.docs) {
              final d = doc.data(); d['id'] = doc.id; d['branchId'] = bid;
              if (_isDateInRange(d['month'] ?? d['date'])) {
                allSalaryHistory.add(_sanitizeForJson(d)); salaryHistory++;
              }
            }
          } catch (_) {}
        }
        salaryHistory = allSalaryHistory.length;
      }

      setState(() {
        _totalPatients = patients; _totalTokens = tokens; _totalPrescriptions = prescriptions; _totalDispensary = dispensary;
        _totalDonations = donations; _totalCredits = credits;
        _totalFood = food; _totalFoodStock = foodStock; _totalFoodLogs = foodLogs;
        _totalMadrassaS = madrassaS; _totalMadrassaL = madrassaL;
        _totalSchoolStudents = schoolS; _totalSchoolTeachers = schoolT; _totalSchoolLogs = schoolLogs;
        _totalSchoolBooks = schoolBooks; _totalSchoolBookLoans = schoolLoans; _totalSchoolGrades = schoolGrades; _totalSchoolAudit = schoolAudit;
        _totalOfficeBoyTasks = obTasks; _totalOfficeBoyLogs = obLogs;
        _totalFinanceLoans = financeLoans; _totalExpenses = expenses;
        _totalEmployees = employees; _totalSalaryHistory = salaryHistory;
      });
    }

    // Sort lists
    if (hasDispensary) {
      _sortByDate(allPatients, ['registrationDate', 'createdAt']);
      _sortByDate(allTokens, ['date', 'createdAt']);
      _sortByDate(allPrescriptions, ['date', 'createdAt']);
    }
    if (hasDonations) {
      _sortByDate(allDonations, ['date', 'timestamp']);
      _sortByDate(allCredits, ['date', 'timestamp']);
    }
    if (hasDasterkhwaan) {
      _sortByDate(allFood, ['date', 'timestamp']);
      _sortByDate(allFoodLogs, ['timestamp', 'date']);
    }
    if (hasMadrassa) {
      _sortByDate(allMadrassaLogs, ['date', 'updatedAt']);
    }
    if (hasSchool) {
      _sortByDate(allSchoolLogs, ['dateKey', 'timestamp']);
      _sortByDate(allSchoolGrades, ['date', 'timestamp']);
      _sortByDate(allSchoolAudit, ['timestamp', 'date']);
    }
    if (hasOfficeBoy) {
      _sortByDate(allOfficeBoyTasks, ['createdAt', 'date']);
      _sortByDate(allOfficeBoyLogs, ['timestamp', 'date']);
    }
    if (hasFinance) {
      _sortByDate(allExpenses, ['date', 'timestamp']);
    }
    if (hasHR) {
      _sortByDate(allSalaryHistory, ['month', 'date']);
    }

    return {
      if (hasDispensary) 'patients': allPatients,
      if (hasDispensary) 'tokens': allTokens,
      if (hasDispensary) 'prescriptions': allPrescriptions,
      if (hasDispensary) 'dispensary': allDispensary,

      if (hasDasterkhwaan) 'food': allFood,
      if (hasDasterkhwaan) 'food_stock': allFoodStock,
      if (hasDasterkhwaan) 'food_logs': allFoodLogs,

      if (hasMadrassa) 'madrassa_students': allMadrassaStudents,
      if (hasMadrassa) 'madrassa_logs': allMadrassaLogs,

      if (hasSchool) 'school_students': allSchoolStudents,
      if (hasSchool) 'school_teachers': allSchoolTeachers,
      if (hasSchool) 'school_logs': allSchoolLogs,
      if (hasSchool) 'school_books': allSchoolBooks,
      if (hasSchool) 'school_book_loans': allSchoolBookLoans,
      if (hasSchool) 'school_grades': allSchoolGrades,
      if (hasSchool) 'school_audit_logs': allSchoolAudit,

      if (hasDonations) 'donations': allDonations,
      if (hasDonations) 'credits': allCredits,

      if (hasOfficeBoy) 'office_boy_tasks': allOfficeBoyTasks,
      if (hasOfficeBoy) 'office_boy_logs': allOfficeBoyLogs,

      if (hasFinance) 'finance_loans': allFinanceLoans,
      if (hasFinance) 'expenses': allExpenses,

      if (hasHR) 'employees': allEmployees,
      if (hasHR) 'salary_history': allSalaryHistory,
    };
  }

  void _sortByDate(
      List<Map<String, dynamic>> list, List<String> dateKeys) {
    list.sort((a, b) {
      String? aStr, bStr;
      for (final k in dateKeys) {
        if (a[k] != null) { aStr = a[k].toString(); break; }
      }
      for (final k in dateKeys) {
        if (b[k] != null) { bStr = b[k].toString(); break; }
      }
      if (aStr == null && bStr == null) return 0;
      if (aStr == null) return 1;
      if (bStr == null) return -1;
      try {
        return DateTime.parse(bStr).compareTo(DateTime.parse(aStr));
      } catch (_) {
        return bStr.compareTo(aStr);
      }
    });
  }

  // ─── Download handlers ───────────────────────────────────────────────────────
  Future<void> _downloadJson(RoleThemeData t) async {
    setState(() {
      _isDownloadingJson = true;
      _statusMessage = 'Fetching records…';
    });
    try {
      final data = await _fetchAllData();
      setState(() => _statusMessage = 'Encoding JSON…');

      final totalRecords = _totalPatients +
          _totalTokens +
          _totalPrescriptions +
          _totalDispensary +
          _totalDonations +
          _totalFood +
          _totalFoodStock +
          _totalFoodLogs +
          _totalCredits +
          _totalMadrassaS +
          _totalMadrassaL +
          _totalSchoolStudents +
          _totalSchoolTeachers +
          _totalSchoolLogs +
          _totalSchoolBooks +
          _totalSchoolBookLoans +
          _totalSchoolGrades +
          _totalSchoolAudit +
          _totalOfficeBoyTasks +
          _totalOfficeBoyLogs +
          _totalFinanceLoans +
          _totalExpenses +
          _totalEmployees +
          _totalSalaryHistory;

      final backupData = {
        'backupDate': DateTime.now().toIso8601String(),
        'branchSelection': _availableBranches.firstWhere((b) => b['id'] == _selectedBranch, orElse: () => {'name': _selectedBranch ?? 'Unknown'})['name'],
        'dateFilter': _buildDateFilterMeta(),
        'counts': {
          'patients': _totalPatients,
          'tokens': _totalTokens,
          'prescriptions': _totalPrescriptions,
          'dispensary': _totalDispensary,
          'donations': _totalDonations,
          'food_tokens': _totalFood,
          'food_stock': _totalFoodStock,
          'food_logs': _totalFoodLogs,
          'credits': _totalCredits,
          'madrassa_students': _totalMadrassaS,
          'madrassa_logs': _totalMadrassaL,
          'school_students': _totalSchoolStudents,
          'school_teachers': _totalSchoolTeachers,
          'school_logs': _totalSchoolLogs,
          'school_books': _totalSchoolBooks,
          'school_book_loans': _totalSchoolBookLoans,
          'school_grades': _totalSchoolGrades,
          'school_audit_logs': _totalSchoolAudit,
          'office_boy_tasks': _totalOfficeBoyTasks,
          'office_boy_logs': _totalOfficeBoyLogs,
          'finance_loans': _totalFinanceLoans,
          'expenses': _totalExpenses,
          'employees': _totalEmployees,
          'salary_history': _totalSalaryHistory,
        },
        'data': data,
      };
      final jsonString =
          const JsonEncoder.withIndent('  ').convert(backupData);
      final jsonBytes = utf8.encode(jsonString);
      final dateStr = DateFormat('yyyy-MM-dd_HH-mm-ss').format(DateTime.now());
      final rangeStr = _buildFilenameDateSuffix();
      final branchStr = _selectedBranch == 'all'
          ? 'all_branches'
          : _availableBranches.firstWhere((b) => b['id'] == _selectedBranch, orElse: () => {'name': _selectedBranch ?? 'Unknown'})['name']!.toLowerCase();
      final fileName = 'backup_${branchStr}_${rangeStr}_$dateStr.json';

      String? savePath;
      try {
        savePath = await FilePicker.platform.saveFile(
          dialogTitle: 'Save JSON Backup',
          fileName: fileName,
          bytes: jsonBytes,
          type: FileType.custom,
          allowedExtensions: ['json'],
        );
      } catch (_) {}

      if (savePath != null && savePath.isNotEmpty) {
        try {
          final file = File(savePath);
          await file.writeAsBytes(jsonBytes, flush: true);
        } catch (_) {}
      } else if (kIsWeb) {
        // Web: saveFile with bytes starts the download and returns null; there
        // is no temp directory, so getTempFilePath would throw "JSON failed".
        if (mounted) {
          _showSnack('✓ JSON Backup downloaded — $totalRecords total records', color: t.accent);
        }
        return;
      } else {
        savePath = await FileActionHelper.getTempFilePath(fileName, jsonBytes);
      }

      if (mounted) {
        Clipboard.setData(ClipboardData(text: savePath));
        _showSnack(
            '✓ JSON Backup saved — $totalRecords total records across ${_selectedCategories.length} modules\n$savePath',
            color: t.accent);
        FileActionHelper.showFileOptions(
          context,
          filePath: savePath,
          bytes: jsonBytes,
          fileName: fileName,
          title: 'JSON Backup Ready',
        );
      }
    } catch (e) {
      _showSnack('JSON failed: $e', color: t.danger);
    } finally {
      setState(() {
        _isDownloadingJson = false;
        if (!_isDownloadingExcel) _statusMessage = 'Ready';
      });
    }
  }

  Future<void> _downloadExcel(RoleThemeData t) async {
    setState(() {
      _isDownloadingExcel = true;
      _statusMessage = 'Fetching records…';
    });
    try {
      final data = await _fetchAllData();
      setState(() => _statusMessage = 'Building Excel workbook…');
      final excel = xl.Excel.createExcel();
      excel.rename('Sheet1', 'Instructions');
      excel['Instructions'].appendRow([xl.TextCellValue('GMWF Data Export Summary')]);
      excel['Instructions'].appendRow([xl.TextCellValue('Date Range: $_dateLabel')]);
      excel['Instructions'].appendRow([xl.TextCellValue('Generated At: ${DateTime.now()}')]);

      if (data.containsKey('patients')) _addSheet(excel, 'Patients', data['patients']);
      if (data.containsKey('tokens')) _addSheet(excel, 'Tokens', data['tokens']);
      if (data.containsKey('prescriptions')) _addSheet(excel, 'Prescriptions', data['prescriptions']);
      if (data.containsKey('dispensary')) _addSheet(excel, 'Dispensary_Inventory', data['dispensary']);
      if (data.containsKey('food')) _addSheet(excel, 'Food_Tokens', data['food']);
      if (data.containsKey('food_stock')) _addSheet(excel, 'Food_Stock_Inventory', data['food_stock']);
      if (data.containsKey('food_logs')) _addSheet(excel, 'Food_Stock_Audit_Logs', data['food_logs']);
      if (data.containsKey('madrassa_students')) _addSheet(excel, 'Madrassa_Students', data['madrassa_students']);
      if (data.containsKey('madrassa_logs')) _addSheet(excel, 'Madrassa_Logs', data['madrassa_logs']);
      if (data.containsKey('school_students')) _addSheet(excel, 'School_Students', data['school_students']);
      if (data.containsKey('school_teachers')) _addSheet(excel, 'School_Teachers', data['school_teachers']);
      if (data.containsKey('school_logs')) _addSheet(excel, 'School_Attendance_Logs', data['school_logs']);
      if (data.containsKey('school_books')) _addSheet(excel, 'School_Library_Books', data['school_books']);
      if (data.containsKey('school_book_loans')) _addSheet(excel, 'School_Book_Loans', data['school_book_loans']);
      if (data.containsKey('school_grades')) _addSheet(excel, 'School_Exams_&_Grades', data['school_grades']);
      if (data.containsKey('school_audit_logs')) _addSheet(excel, 'School_Audit_Logs', data['school_audit_logs']);
      if (data.containsKey('donations')) _addSheet(excel, 'Donations', data['donations']);
      if (data.containsKey('credits')) _addSheet(excel, 'Credits_Ledger', data['credits']);
      if (data.containsKey('office_boy_tasks')) _addSheet(excel, 'Office_Boy_Tasks', data['office_boy_tasks']);
      if (data.containsKey('office_boy_logs')) _addSheet(excel, 'Office_Boy_Logs', data['office_boy_logs']);
      if (data.containsKey('finance_loans')) _addSheet(excel, 'Finance_Loans', data['finance_loans']);
      if (data.containsKey('expenses')) _addSheet(excel, 'Operational_Expenses', data['expenses']);
      if (data.containsKey('employees')) _addSheet(excel, 'Employees_Directory', data['employees']);
      if (data.containsKey('salary_history')) _addSheet(excel, 'Salary_History', data['salary_history']);

      final totalRecords = _totalPatients +
          _totalTokens +
          _totalPrescriptions +
          _totalDispensary +
          _totalDonations +
          _totalFood +
          _totalFoodStock +
          _totalFoodLogs +
          _totalCredits +
          _totalMadrassaS +
          _totalMadrassaL +
          _totalSchoolStudents +
          _totalSchoolTeachers +
          _totalSchoolLogs +
          _totalSchoolBooks +
          _totalSchoolBookLoans +
          _totalSchoolGrades +
          _totalSchoolAudit +
          _totalOfficeBoyTasks +
          _totalOfficeBoyLogs +
          _totalFinanceLoans +
          _totalExpenses +
          _totalEmployees +
          _totalSalaryHistory;

      final excelBytesList = excel.encode();
      final Uint8List excelBytes = excelBytesList != null
          ? Uint8List.fromList(excelBytesList)
          : Uint8List(0);
      final dateStr = DateFormat('yyyy-MM-dd_HH-mm-ss').format(DateTime.now());
      final rangeStr = _buildFilenameDateSuffix();
      final branchStr = _selectedBranch == 'all'
          ? 'all_branches'
          : _availableBranches.firstWhere((b) => b['id'] == _selectedBranch, orElse: () => {'name': _selectedBranch ?? 'Unknown'})['name']!.toLowerCase();
      final fileName = 'backup_${branchStr}_${rangeStr}_$dateStr.xlsx';

      String? savePath;
      try {
        savePath = await FilePicker.platform.saveFile(
          dialogTitle: 'Save Excel Backup',
          fileName: fileName,
          bytes: excelBytes,
          type: FileType.custom,
          allowedExtensions: ['xlsx'],
        );
      } catch (_) {}

      if (savePath != null && savePath.isNotEmpty) {
        try {
          final file = File(savePath);
          await file.writeAsBytes(excelBytes, flush: true);
        } catch (_) {}
      } else {
        savePath = await FileActionHelper.getTempFilePath(fileName, excelBytes);
      }

      if (mounted) {
        Clipboard.setData(ClipboardData(text: savePath));
        _showSnack(
            '✓ Excel Backup saved — ${data.length} sheets, $totalRecords total rows\n$savePath',
            color: SoftPalette.green550);
        FileActionHelper.showFileOptions(
          context,
          filePath: savePath,
          bytes: excelBytes,
          fileName: fileName,
          title: 'Excel Backup Ready',
        );
      }
    } catch (e) {
      _showSnack('Excel failed: $e', color: SoftPalette.red400);
    } finally {
      setState(() {
        _isDownloadingExcel = false;
        if (!_isDownloadingJson) _statusMessage = 'Ready';
      });
    }
  }

  Map<String, dynamic> _buildDateFilterMeta() {
    switch (_dateMode) {
      case DateFilterMode.allTime:
        return {'mode': 'allTime'};
      case DateFilterMode.singleDay:
        return {
          'mode': 'singleDay',
          'date': _singleDate?.toIso8601String()
        };
      case DateFilterMode.dateRange:
        return {
          'mode': 'dateRange',
          'from': _rangeStart?.toIso8601String(),
          'to': _rangeEnd?.toIso8601String(),
        };
    }
  }

  String _buildFilenameDateSuffix() {
    switch (_dateMode) {
      case DateFilterMode.allTime:
        return 'alltime';
      case DateFilterMode.singleDay:
        return _singleDate != null
            ? DateFormat('yyyy-MM-dd').format(_singleDate!)
            : 'alltime';
      case DateFilterMode.dateRange:
        if (_rangeStart != null && _rangeEnd != null) {
          return '${DateFormat('yyyy-MM-dd').format(_rangeStart!)}_to_${DateFormat('yyyy-MM-dd').format(_rangeEnd!)}';
        }
        return 'alltime';
    }
  }

  void _showSnack(String msg, {required Color color}) {
    if (!mounted) return;
    AppToast.showSnackBar(context, SnackBar(
      content: Text(msg, style: const TextStyle(fontSize: 13)),
      backgroundColor: color,
      duration: const Duration(seconds: 8),
      behavior: SnackBarBehavior.floating,
      shape:
          RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      action: SnackBarAction(
        label: 'Close',
        textColor: SoftPalette.gray50,
        onPressed: () =>
            AppToast.hideCurrent(),
      ),
    ));
  }

  // ─── Build ───────────────────────────────────────────────────────────────────
  @override
  Widget build(BuildContext context) {
    final t = RoleThemeScope.dataOf(context);
    final bool isBusy = _isDownloadingJson || _isDownloadingExcel;
    final bool canDownload =
        _selectedBranch != null && _isDateFilterValid();

    return Scaffold(
      backgroundColor: t.bg,
      // Inside the executive shell its header already names the page.
      appBar: HomeModuleHost.isModuleRoot(context) ? null : _buildAppBar(t),
      body: FadeTransition(
        opacity: _cardFade,
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(
                horizontal: 20, vertical: 28),
            child: Container(
              constraints: const BoxConstraints(maxWidth: 840),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _buildHeaderCard(t),
                  const SizedBox(height: 16),
                  _buildBranchCard(t, isBusy),
                  const SizedBox(height: 16),
                  _buildCategoryCard(t, isBusy),
                  const SizedBox(height: 16),
                  _buildDateFilterCard(t, isBusy),
                  const SizedBox(height: 16),
                  if (isBusy) _buildProgressCard(t),
                  if (!isBusy && canDownload) ...[
                    _buildStatsCard(t),
                    const SizedBox(height: 16),
                    _buildDownloadCard(t),
                  ],
                  if (!isBusy && !canDownload) _buildEmptyState(t),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  bool _isDateFilterValid() {
    switch (_dateMode) {
      case DateFilterMode.allTime:
        return true;
      case DateFilterMode.singleDay:
        return _singleDate != null;
      case DateFilterMode.dateRange:
        return _rangeStart != null && _rangeEnd != null;
    }
  }

  // ─── AppBar ──────────────────────────────────────────────────────────────────
  PreferredSizeWidget _buildAppBar(RoleThemeData t) => AppBar(
        title: Text('Download Backup',
            style: TextStyle(
                color: t.textPrimary, fontWeight: FontWeight.w700)),
        backgroundColor: t.bgCard,
        elevation: 0,
        surfaceTintColor: Colors.transparent,
        iconTheme: IconThemeData(color: t.textSecondary),
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(1),
          child: Container(height: 1, color: t.bgRule),
        ),
      );

  Widget _buildHeaderCard(RoleThemeData t) {
    final isMobile = GBreakpoint.isMobile(context);
    return Container(
      padding: EdgeInsets.symmetric(horizontal: isMobile ? 20 : 24, vertical: 20),
      decoration: _cardDecor(t),
      child: Column(
        children: [
          Row(children: [
            Container(
              padding: EdgeInsets.all(isMobile ? 10 : 14),
              decoration: BoxDecoration(color: t.accentMuted, borderRadius: BorderRadius.circular(16)),
              child: Icon(Icons.cloud_download_rounded, color: t.accent, size: isMobile ? 20 : 30),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Clinic Data Backup',
                      style: TextStyle(fontSize: isMobile ? 16 : 20, fontWeight: FontWeight.w800, color: t.textPrimary, letterSpacing: -0.3)),
                  const SizedBox(height: 2),
                  Text('Export records by branch & range',
                      style: TextStyle(fontSize: isMobile ? 11 : 12, color: t.textSecondary)),
                ],
              ),
            ),
            if (!isMobile) ...[
              _buildFormatBadge('JSON', t.accent, t),
              const SizedBox(width: 8),
              _buildFormatBadge('XLSX', t.accentLight, t),
            ],
          ]),
          if (isMobile) ...[
            const SizedBox(height: 16),
            Row(mainAxisAlignment: MainAxisAlignment.end, children: [
              _buildFormatBadge('JSON', t.accent, t),
              const SizedBox(width: 8),
              _buildFormatBadge('XLSX', t.accentLight, t),
            ]),
          ],
        ],
      ),
    );
  }

  Widget _buildFormatBadge(String label, Color color, RoleThemeData t) =>
      Container(
        padding:
            const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: color.withValues(alpha: 0.35)),
        ),
        child: Text(label,
            style: TextStyle(
                color: color,
                fontSize: 11,
                fontWeight: FontWeight.w700,
                letterSpacing: 0.5)),
      );

  // ─── Branch card ─────────────────────────────────────────────────────────────
  Widget _buildBranchCard(RoleThemeData t, bool isBusy) {
    // ── Branch-locked mode: show read-only pill, no dropdown ─────────────
    final isLocked = widget.lockedBranchId != null && widget.lockedBranchId!.isNotEmpty;
    if (isLocked) {
      final branchName = _availableBranches.isNotEmpty
          ? (_availableBranches.first['name'] ?? widget.lockedBranchId!)
          : widget.lockedBranchId!;
      return Container(
        padding: const EdgeInsets.all(20),
        decoration: _cardDecor(t),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _sectionLabel(Icons.account_tree_outlined, 'Branch', t),
            const SizedBox(height: 14),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              decoration: BoxDecoration(
                color: t.accent.withValues(alpha: 0.07),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: t.accent.withValues(alpha: 0.25)),
              ),
              child: Row(children: [
                Icon(Icons.lock_outline_rounded, color: t.accent, size: 16),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    branchName,
                    style: TextStyle(
                        color: t.textPrimary,
                        fontSize: 14,
                        fontWeight: FontWeight.w700),
                  ),
                ),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(
                    color: t.accent.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Text('Your Branch',
                      style: TextStyle(
                          color: t.accent,
                          fontSize: 10,
                          fontWeight: FontWeight.w700)),
                ),
              ]),
            ),
          ],
        ),
      );
    }
    // ── Global roles: full branch selector ───────────────────────────────
    return Container(
        padding: const EdgeInsets.all(20),
        decoration: _cardDecor(t),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _sectionLabel(Icons.account_tree_outlined, 'Branch', t),
            const SizedBox(height: 14),
            if (_isLoadingBranches)
              const LinearProgressIndicator()
            else
              DropdownButtonFormField<String>(
                initialValue: _selectedBranch,
                dropdownColor: t.bgCard,
                decoration: _inputDecor(
                    'Select Branch', Icons.business_outlined, t),
                items: _availableBranches
                    .map((e) => DropdownMenuItem(
                        value: e['id'],
                        child: Row(children: [
                          Icon(
                              e['id'] == 'all'
                                  ? Icons.hub_outlined
                                  : Icons.location_on_outlined,
                              size: 16,
                              color: t.textTertiary),
                          const SizedBox(width: 8),
                          Text(e['name'] ?? '',
                              style: TextStyle(
                                  fontSize: 14, color: t.textPrimary)),
                        ])))
                    .toList(),
                onChanged: isBusy
                    ? null
                    : (v) => setState(() => _selectedBranch = v),
              ),
          ],
        ),
      );
  }

  // ─── Category card ──────────────────────────────────────────────────────────
  Widget _buildCategoryCard(RoleThemeData t, bool isBusy) => Container(
        padding: const EdgeInsets.all(20),
        decoration: _cardDecor(t),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                _sectionLabel(Icons.category_outlined, 'Data Categories', t),
                Row(
                  children: [
                    TextButton(
                      onPressed: isBusy
                          ? null
                          : () {
                              setState(() {
                                _selectedCategories.addAll(_categoryDef.map((c) => c['id'].toString()));
                              });
                            },
                      child: const Text('Select All', style: TextStyle(fontSize: 12)),
                    ),
                    Text('•', style: TextStyle(color: t.textTertiary, fontSize: 12)),
                    TextButton(
                      onPressed: isBusy
                          ? null
                          : () {
                              setState(() {
                                _selectedCategories.clear();
                                _selectedCategories.add(_categoryDef.first['id'].toString());
                              });
                            },
                      child: const Text('Clear', style: TextStyle(fontSize: 12)),
                    ),
                  ],
                ),
              ],
            ),
            const SizedBox(height: 10),
            Wrap(
              spacing: 10,
              runSpacing: 10,
              children: _categoryDef.map((cat) {
                final selected = _selectedCategories.contains(cat['id']);
                final color = cat['color'] as Color;
                return FilterChip(
                  label: Text(cat['label']),
                  selected: selected,
                  selectedColor: color.withValues(alpha: 0.2),
                  checkmarkColor: color,
                  labelStyle: TextStyle(
                    color: selected ? color : t.textSecondary,
                    fontWeight: selected ? FontWeight.bold : FontWeight.normal,
                    fontSize: 13,
                  ),
                  avatar: Icon(cat['icon'], size: 16, color: selected ? color : t.textTertiary),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(10),
                    side: BorderSide(color: selected ? color : t.bgRule),
                  ),
                  onSelected: isBusy ? null : (v) {
                    setState(() {
                      if (v) {
                        _selectedCategories.add(cat['id']);
                      } else if (_selectedCategories.length > 1) {
                        _selectedCategories.remove(cat['id']);
                      }
                    });
                  },
                );
              }).toList(),
            ),
          ],
        ),
      );

  // ─── Date filter card ────────────────────────────────────────────────────────
  Widget _buildDateFilterCard(RoleThemeData t, bool isBusy) => Container(
        padding: const EdgeInsets.all(20),
        decoration: _cardDecor(t),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _sectionLabel(Icons.date_range_outlined, 'Date Filter', t),
            const SizedBox(height: 14),

            // Mode toggle tabs
            Container(
              padding: const EdgeInsets.all(4),
              decoration: BoxDecoration(
                color: t.bg,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: t.bgRule),
              ),
              child: Row(children: [
                _modeTab('All Time', DateFilterMode.allTime,
                    Icons.all_inclusive_rounded, t, isBusy),
                _modeTab('Single Day', DateFilterMode.singleDay,
                    Icons.today_rounded, t, isBusy),
                _modeTab('Date Range', DateFilterMode.dateRange,
                    Icons.date_range_rounded, t, isBusy),
              ]),
            ),

            const SizedBox(height: 16),

            // Date picker trigger
            if (_dateMode != DateFilterMode.allTime)
              AnimatedSwitcher(
                duration: const Duration(milliseconds: 260),
                child: _buildDatePickerTrigger(t, isBusy),
              ),

            if (_dateMode == DateFilterMode.allTime)
              Container(
                padding: const EdgeInsets.symmetric(
                    horizontal: 14, vertical: 12),
                decoration: BoxDecoration(
                  color: t.accentMuted.withValues(alpha: 0.5),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(
                      color: t.accent.withValues(alpha: 0.2)),
                ),
                child: Row(children: [
                  Icon(Icons.info_outline,
                      size: 16, color: t.accent),
                  const SizedBox(width: 10),
                  Text('All records across every date will be exported',
                      style: TextStyle(
                          fontSize: 13, color: t.textSecondary)),
                ]),
              ),
          ],
        ),
      );

  Widget _modeTab(String label, DateFilterMode mode, IconData icon,
      RoleThemeData t, bool isBusy) {
    final active = _dateMode == mode;
    return Expanded(
      child: GestureDetector(
        onTap: isBusy ? null : () => setState(() => _dateMode = mode),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          padding: const EdgeInsets.symmetric(vertical: 10),
          decoration: BoxDecoration(
            color: active ? t.accent : Colors.transparent,
            borderRadius: BorderRadius.circular(9),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icon,
                  size: 14,
                  color: active ? SoftPalette.gray50 : t.textTertiary),
              const SizedBox(width: 5),
              Text(label,
                  style: TextStyle(
                      fontSize: 12,
                      fontWeight: active
                          ? FontWeight.w700
                          : FontWeight.w500,
                      color: active ? SoftPalette.gray50 : t.textTertiary)),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildDatePickerTrigger(RoleThemeData t, bool isBusy) {
    if (_dateMode == DateFilterMode.singleDay) {
      return GestureDetector(
        key: const ValueKey('single'),
        onTap: isBusy ? null : () => _pickSingleDate(t),
        child: _dateChip(
          _singleDate != null
              ? DateFormat('EEEE, dd MMMM yyyy').format(_singleDate!)
              : 'Tap to pick a date',
          Icons.today_rounded,
          _singleDate != null,
          t,
        ),
      );
    }
    // Date range
    return Column(
      key: const ValueKey('range'),
      children: [
        Row(children: [
          Expanded(
            child: GestureDetector(
              onTap: isBusy ? null : () => _pickDateRange(t),
              child: _dateChip(
                _rangeStart != null
                    ? 'From: ${DateFormat('dd MMM yyyy').format(_rangeStart!)}'
                    : 'From date',
                Icons.calendar_today_rounded,
                _rangeStart != null,
                t,
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10),
            child: Icon(Icons.arrow_forward_rounded,
                size: 18, color: t.textTertiary),
          ),
          Expanded(
            child: GestureDetector(
              onTap: isBusy ? null : () => _pickDateRange(t),
              child: _dateChip(
                _rangeEnd != null
                    ? 'To: ${DateFormat('dd MMM yyyy').format(_rangeEnd!)}'
                    : 'To date',
                Icons.event_rounded,
                _rangeEnd != null,
                t,
              ),
            ),
          ),
        ]),
        if (_rangeStart != null && _rangeEnd != null) ...[
          const SizedBox(height: 10),
          Container(
            padding: const EdgeInsets.symmetric(
                horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
              color: t.accentMuted.withValues(alpha: 0.5),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(Icons.timelapse_rounded,
                    size: 14, color: t.accent),
                const SizedBox(width: 6),
                Text(
                  '${_rangeEnd!.difference(_rangeStart!).inDays + 1} days selected',
                  style: TextStyle(
                      fontSize: 12,
                      color: t.accent,
                      fontWeight: FontWeight.w600),
                ),
              ],
            ),
          ),
        ]
      ],
    );
  }

  Widget _dateChip(
      String label, IconData icon, bool hasValue, RoleThemeData t) =>
      Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
        decoration: BoxDecoration(
          color: hasValue ? t.accentMuted : t.bg,
          borderRadius: BorderRadius.circular(11),
          border: Border.all(
              color: hasValue
                  ? t.accent.withValues(alpha: 0.4)
                  : t.bgRule),
        ),
        child: Row(children: [
          Icon(icon,
              size: 16,
              color: hasValue ? t.accent : t.textTertiary),
          const SizedBox(width: 10),
          Expanded(
            child: Text(label,
                style: TextStyle(
                    fontSize: 13,
                    color: hasValue ? t.textPrimary : t.textTertiary,
                    fontWeight: hasValue
                        ? FontWeight.w600
                        : FontWeight.w400)),
          ),
          Icon(Icons.edit_calendar_rounded,
              size: 15,
              color: hasValue ? t.accent : t.textTertiary),
        ]),
      );

  // ─── Progress card ───────────────────────────────────────────────────────────
  Widget _buildProgressCard(RoleThemeData t) => Container(
        margin: const EdgeInsets.only(bottom: 16),
        padding: const EdgeInsets.all(20),
        decoration: _cardDecor(t),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(
                      color: t.accent, strokeWidth: 2.5)),
              const SizedBox(width: 14),
              Text(_statusMessage,
                  style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      color: t.textPrimary)),
            ]),
            const SizedBox(height: 14),
            ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: LinearProgressIndicator(
                color: t.accent,
                backgroundColor: t.accentMuted,
                minHeight: 6,
              ),
            ),
            const SizedBox(height: 14),
            _buildLiveCountRow(t),
          ],
        ),
      );

  Widget _buildLiveCountRow(RoleThemeData t) {
    final hasDispensary = _selectedCategories.contains('dispensary');
    final hasDasterkhwaan = _selectedCategories.contains('dasterkhwaan');
    final hasDonations = _selectedCategories.contains('donations');
    final hasMadrassa = _selectedCategories.contains('madrassa');
    final hasSchool = _selectedCategories.contains('school');
    final hasOfficeBoy = _selectedCategories.contains('officeboy');
    final hasFinance = _selectedCategories.contains('finance');
    final hasHR = _selectedCategories.contains('hr');

    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        children: [
          if (hasDispensary) ...[
            _miniStat('Patients', _totalPatients, Icons.people_outline, t),
            const SizedBox(width: 16),
            _miniStat('Tokens', _totalTokens, Icons.confirmation_number_outlined, t),
            const SizedBox(width: 16),
            _miniStat('Rx', _totalPrescriptions, Icons.medication_outlined, t),
            const SizedBox(width: 16),
            _miniStat('Rx Stock', _totalDispensary, Icons.inventory_2_outlined, t),
            const SizedBox(width: 16),
          ],
          if (hasDonations) ...[
            _miniStat('Donations', _totalDonations, Icons.volunteer_activism_outlined, t),
            const SizedBox(width: 16),
            _miniStat('Credits', _totalCredits, Icons.payments_outlined, t),
            const SizedBox(width: 16),
          ],
          if (hasDasterkhwaan) ...[
            _miniStat('Food Tokens', _totalFood, Icons.restaurant_outlined, t),
            const SizedBox(width: 16),
            _miniStat('Food Stock', _totalFoodStock, Icons.kitchen_outlined, t),
            const SizedBox(width: 16),
            _miniStat('Food Audit', _totalFoodLogs, Icons.history_rounded, t),
            const SizedBox(width: 16),
          ],
          if (hasMadrassa) ...[
            _miniStat('Madrassa Std', _totalMadrassaS, Icons.school_outlined, t),
            const SizedBox(width: 16),
            _miniStat('Madrassa Logs', _totalMadrassaL, Icons.history_edu_rounded, t),
            const SizedBox(width: 16),
          ],
          if (hasSchool) ...[
            _miniStat('Students', _totalSchoolStudents, Icons.groups_outlined, t),
            const SizedBox(width: 16),
            _miniStat('Teachers', _totalSchoolTeachers, Icons.record_voice_over_outlined, t),
            const SizedBox(width: 16),
            _miniStat('Attendance', _totalSchoolLogs, Icons.how_to_reg_outlined, t),
            const SizedBox(width: 16),
            _miniStat('Books', _totalSchoolBooks, Icons.local_library_outlined, t),
            const SizedBox(width: 16),
            _miniStat('Book Loans', _totalSchoolBookLoans, Icons.auto_stories_outlined, t),
            const SizedBox(width: 16),
            _miniStat('Grades', _totalSchoolGrades, Icons.grade_outlined, t),
            const SizedBox(width: 16),
            _miniStat('School Audit', _totalSchoolAudit, Icons.security_outlined, t),
            const SizedBox(width: 16),
          ],
          if (hasOfficeBoy) ...[
            _miniStat('OB Tasks', _totalOfficeBoyTasks, Icons.cleaning_services_outlined, t),
            const SizedBox(width: 16),
            _miniStat('OB Logs', _totalOfficeBoyLogs, Icons.task_alt_outlined, t),
            const SizedBox(width: 16),
          ],
          if (hasFinance) ...[
            _miniStat('Loans', _totalFinanceLoans, Icons.account_balance_wallet_outlined, t),
            const SizedBox(width: 16),
            _miniStat('Expenses', _totalExpenses, Icons.receipt_long_outlined, t),
            const SizedBox(width: 16),
          ],
          if (hasHR) ...[
            _miniStat('Employees', _totalEmployees, Icons.badge_outlined, t),
            const SizedBox(width: 16),
            _miniStat('Payroll', _totalSalaryHistory, Icons.monetization_on_outlined, t),
            const SizedBox(width: 16),
          ],
        ],
      ),
    );
  }

  Widget _miniStat(
      String label, int value, IconData icon, RoleThemeData t) =>
      Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: t.bg,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: t.bgRule),
        ),
        child: Column(children: [
          Icon(icon, size: 15, color: t.textTertiary),
          const SizedBox(height: 3),
          Text('$value',
              style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w800,
                  color: t.textPrimary)),
          Text(label,
              style:
                  TextStyle(fontSize: 10, color: t.textTertiary)),
        ]),
      );

  // ─── Stats card ──────────────────────────────────────────────────────────────
  Widget _buildStatsCard(RoleThemeData t) {
    final total = _totalPatients +
        _totalTokens +
        _totalPrescriptions +
        _totalDispensary +
        _totalDonations +
        _totalFood +
        _totalFoodStock +
        _totalFoodLogs +
        _totalCredits +
        _totalMadrassaS +
        _totalMadrassaL +
        _totalSchoolStudents +
        _totalSchoolTeachers +
        _totalSchoolLogs +
        _totalSchoolBooks +
        _totalSchoolBookLoans +
        _totalSchoolGrades +
        _totalSchoolAudit +
        _totalOfficeBoyTasks +
        _totalOfficeBoyLogs +
        _totalFinanceLoans +
        _totalExpenses +
        _totalEmployees +
        _totalSalaryHistory;
    if (total == 0) return const SizedBox.shrink();

    return FadeTransition(
      opacity: _statsFade,
      child: Container(
        padding: const EdgeInsets.all(20),
        decoration: _cardDecor(t),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _sectionLabel(Icons.bar_chart_rounded, 'Records Preview', t),
            const SizedBox(height: 16),
            GridView.count(
              crossAxisCount: 2,
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              mainAxisSpacing: 10,
              crossAxisSpacing: 10,
              childAspectRatio: 2.2,
              children: [
                if (_totalPatients > 0) _statTile('Patients', _totalPatients, Icons.people_rounded, SoftPalette.green400, total, t),
                if (_totalTokens > 0) _statTile('Tokens', _totalTokens, Icons.confirmation_number_rounded, SoftPalette.blue400, total, t),
                if (_totalPrescriptions > 0) _statTile('Prescriptions', _totalPrescriptions, Icons.medication_rounded, SoftPalette.amber300, total, t),
                if (_totalDispensary > 0) _statTile('Medicine Stock', _totalDispensary, Icons.inventory_2_rounded, SoftPalette.purple550, total, t),
                if (_totalDonations > 0) _statTile('Donations', _totalDonations, Icons.volunteer_activism_rounded, SoftPalette.red500, total, t),
                if (_totalFood > 0) _statTile('Food Tokens', _totalFood, Icons.restaurant_rounded, SoftPalette.orange600m, total, t),
                if (_totalFoodStock > 0) _statTile('Food Stock Items', _totalFoodStock, Icons.kitchen_rounded, SoftPalette.orange400, total, t),
                if (_totalFoodLogs > 0) _statTile('Food Audit Logs', _totalFoodLogs, Icons.history_rounded, SoftPalette.orange500, total, t),
                if (_totalCredits > 0) _statTile('Credits', _totalCredits, Icons.payments_rounded, SoftPalette.teal500, total, t),
                if (_totalMadrassaS > 0) _statTile('Madrassa Students', _totalMadrassaS, Icons.school_rounded, SoftPalette.indigo550, total, t),
                if (_totalMadrassaL > 0) _statTile('Madrassa Logs', _totalMadrassaL, Icons.menu_book_rounded, SoftPalette.indigo600, total, t),
                if (_totalSchoolStudents > 0) _statTile('School Students', _totalSchoolStudents, Icons.groups_rounded, SoftPalette.indigo500, total, t),
                if (_totalSchoolTeachers > 0) _statTile('School Faculty', _totalSchoolTeachers, Icons.record_voice_over_rounded, SoftPalette.emerald350, total, t),
                if (_totalSchoolLogs > 0) _statTile('School Attendance', _totalSchoolLogs, Icons.how_to_reg_rounded, SoftPalette.sky500, total, t),
                if (_totalSchoolBooks > 0) _statTile('Library Books', _totalSchoolBooks, Icons.local_library_rounded, SoftPalette.violet500, total, t),
                if (_totalSchoolBookLoans > 0) _statTile('Book Loans', _totalSchoolBookLoans, Icons.auto_stories_rounded, SoftPalette.violet400, total, t),
                if (_totalSchoolGrades > 0) _statTile('Exam Grades', _totalSchoolGrades, Icons.grade_rounded, SoftPalette.pink400, total, t),
                if (_totalSchoolAudit > 0) _statTile('School Audit Logs', _totalSchoolAudit, Icons.security_rounded, SoftPalette.slate550, total, t),
                if (_totalOfficeBoyTasks > 0) _statTile('Office Boy Tasks', _totalOfficeBoyTasks, Icons.cleaning_services_rounded, SoftPalette.amber300, total, t),
                if (_totalOfficeBoyLogs > 0) _statTile('Office Boy Logs', _totalOfficeBoyLogs, Icons.task_alt_rounded, SoftPalette.orange400, total, t),
                if (_totalFinanceLoans > 0) _statTile('Finance Loans', _totalFinanceLoans, Icons.account_balance_wallet_rounded, SoftPalette.emerald500, total, t),
                if (_totalExpenses > 0) _statTile('Expenses', _totalExpenses, Icons.receipt_long_rounded, SoftPalette.green400, total, t),
                if (_totalEmployees > 0) _statTile('Staff Employees', _totalEmployees, Icons.badge_rounded, SoftPalette.sky500, total, t),
                if (_totalSalaryHistory > 0) _statTile('Salary Payroll', _totalSalaryHistory, Icons.monetization_on_rounded, SoftPalette.sky550, total, t),
              ],
            ),
            const SizedBox(height: 16),
            // Proportional bar
            if (total > 0) _buildProportionBar(total, t),
            const SizedBox(height: 12),
            Center(
              child: Text(
                '$total total records · sorted newest first',
                style: TextStyle(
                    fontSize: 12, color: t.textTertiary),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _statTile(String label, int value, IconData icon,
      Color color, int total, RoleThemeData t) {
    final pct = total > 0 ? (value / total * 100).round() : 0;
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.07),
        borderRadius: BorderRadius.circular(12),
        border:
            Border.all(color: color.withValues(alpha: 0.18)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            Icon(icon, size: 18, color: color),
            const Spacer(),
            Text('$pct%',
                style: TextStyle(
                    fontSize: 11,
                    color: color,
                    fontWeight: FontWeight.w700)),
          ]),
          const SizedBox(height: 8),
          Text('$value',
              style: TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.w800,
                  color: t.textPrimary)),
          Text(label,
              style: TextStyle(
                  fontSize: 11, color: t.textSecondary)),
        ],
      ),
    );
  }

  Widget _buildProportionBar(int total, RoleThemeData t) {
    final segments = [
      (_totalPatients / total, SoftPalette.green400),
      (_totalTokens / total, SoftPalette.blue400),
      (_totalPrescriptions / total, SoftPalette.amber300),
      (_totalDispensary / total, SoftPalette.purple550),
      (_totalDonations / total, SoftPalette.red500),
      (_totalFood / total, SoftPalette.orange600m),
      (_totalFoodStock / total, SoftPalette.orange400),
      (_totalFoodLogs / total, SoftPalette.orange500),
      (_totalCredits / total, SoftPalette.teal500),
      (_totalMadrassaS / total, SoftPalette.indigo550),
      (_totalMadrassaL / total, SoftPalette.indigo600),
      (_totalSchoolStudents / total, SoftPalette.indigo500),
      (_totalSchoolTeachers / total, SoftPalette.emerald350),
      (_totalSchoolLogs / total, SoftPalette.sky500),
      (_totalSchoolBooks / total, SoftPalette.violet500),
      (_totalSchoolBookLoans / total, SoftPalette.violet400),
      (_totalSchoolGrades / total, SoftPalette.pink400),
      (_totalSchoolAudit / total, SoftPalette.slate550),
      (_totalOfficeBoyTasks / total, SoftPalette.amber300),
      (_totalOfficeBoyLogs / total, SoftPalette.orange400),
      (_totalFinanceLoans / total, SoftPalette.emerald500),
      (_totalExpenses / total, SoftPalette.green400),
      (_totalEmployees / total, SoftPalette.sky500),
      (_totalSalaryHistory / total, SoftPalette.sky550),
    ];
    return ClipRRect(
      borderRadius: BorderRadius.circular(6),
      child: SizedBox(
        height: 10,
        child: Row(
          children: segments
              .where((s) => s.$1 > 0)
              .map((s) => Flexible(
                    flex: (s.$1 * 1000).round(),
                    child: Container(color: s.$2),
                  ))
              .toList(),
        ),
      ),
    );
  }

  // ─── Download card ───────────────────────────────────────────────────────────
  Widget _buildDownloadCard(RoleThemeData t) => Container(
        padding: const EdgeInsets.all(20),
        decoration: _cardDecor(t),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _sectionLabel(
                Icons.download_rounded, 'Export', t),
            const SizedBox(height: 6),
            // Summary chip
            Container(
              margin: const EdgeInsets.only(bottom: 16),
              padding: const EdgeInsets.symmetric(
                  horizontal: 12, vertical: 9),
              decoration: BoxDecoration(
                color: t.bg,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: t.bgRule),
              ),
              child: Row(children: [
                Icon(Icons.filter_list_rounded,
                    size: 15, color: t.textTertiary),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    '${_availableBranches.firstWhere((b) => b['id'] == _selectedBranch, orElse: () => {'name': _selectedBranch ?? 'Unknown'})['name']}  ·  $_dateLabel',
                    style: TextStyle(
                        fontSize: 12,
                        color: t.textSecondary,
                        fontWeight: FontWeight.w500),
                  ),
                ),
              ]),
            ),
            Row(children: [
              Expanded(
                  child: _downloadButton(
                'Download JSON',
                Icons.data_object_rounded,
                t.accent,
                _isDownloadingExcel ? null : () => _downloadJson(t),
                'Structured · nested · machine-readable',
                t,
              )),
              const SizedBox(width: 14),
              Expanded(
                  child: _downloadButton(
                'Download Excel',
                Icons.table_chart_rounded,
                t.accentLight,
                _isDownloadingJson ? null : () => _downloadExcel(t),
                '${_selectedCategories.length + 3} sheets · sorted · human-readable',
                t,
              )),
            ]),
          ],
        ),
      );

  Widget _downloadButton(String label, IconData icon, Color color,
      VoidCallback? onTap, String subtitle, RoleThemeData t) =>
      GestureDetector(
        onTap: onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          padding: const EdgeInsets.all(18),
          decoration: BoxDecoration(
            color:
                onTap != null ? color : color.withValues(alpha: 0.3),
            borderRadius: BorderRadius.circular(14),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(icon, color: SoftPalette.gray50, size: 24),
              const SizedBox(height: 10),
              Text(label,
                  style: const TextStyle(
                      color: SoftPalette.gray50,
                      fontSize: 14,
                      fontWeight: FontWeight.w800)),
              const SizedBox(height: 3),
              Text(subtitle,
                  style: TextStyle(
                      color: SoftPalette.gray50.withValues(alpha: 0.7),
                      fontSize: 11)),
            ],
          ),
        ),
      );

  // ─── Empty state ─────────────────────────────────────────────────────────────
  Widget _buildEmptyState(RoleThemeData t) => Container(
        padding: const EdgeInsets.symmetric(
            vertical: 40, horizontal: 24),
        decoration: _cardDecor(t),
        child: Column(children: [
          const GEmptyIllustration(
            GEmptyIllustrationKind.general,
            size: 136,
            fallbackIcon: Icons.tune_rounded,
          ),
          const SizedBox(height: 14),
          Text(
            _selectedBranch == null
                ? 'Select a branch to continue'
                : 'Complete the date filter to continue',
            style: TextStyle(
                fontSize: 15, color: t.textSecondary),
            textAlign: TextAlign.center,
          ),
        ]),
      );

  // ─── Shared helpers ──────────────────────────────────────────────────────────
  BoxDecoration _cardDecor(RoleThemeData t) => BoxDecoration(
        color: t.bgCard,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: t.bgRule),
        boxShadow: [
          BoxShadow(
              color: SoftPalette.gray900.withValues(alpha: 0.05),
              blurRadius: 16,
              offset: const Offset(0, 4)),
        ],
      );

  Widget _sectionLabel(IconData icon, String label, RoleThemeData t) =>
      Row(children: [
        Icon(icon, size: 16, color: t.accent),
        const SizedBox(width: 7),
        Text(label,
            style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w700,
                color: t.textSecondary,
                letterSpacing: 0.3)),
      ]);

  InputDecoration _inputDecor(
          String label, IconData icon, RoleThemeData t) =>
      InputDecoration(
        labelText: label,
        labelStyle: TextStyle(color: t.textTertiary, fontSize: 13),
        floatingLabelStyle: TextStyle(
            color: t.accent,
            fontSize: 12,
            fontWeight: FontWeight.w600),
        prefixIcon:
            Icon(icon, color: t.textTertiary, size: 18),
        filled: true,
        fillColor: t.bg,
        contentPadding: const EdgeInsets.symmetric(
            horizontal: 16, vertical: 14),
        border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: BorderSide(color: t.bgRule)),
        enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: BorderSide(color: t.bgRule)),
        focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: BorderSide(color: t.accent, width: 2)),
      );
}
