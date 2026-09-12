// lib/pages/dispensary/dispensar/universal_proforma_sheet.dart

import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:intl/intl.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:gmwf/services/local_storage_service.dart';
import 'package:gmwf/services/master_proforma_service.dart';
import 'package:gmwf/utils/string_similarity_helper.dart';
import 'package:gmwf/realtime/realtime_manager.dart';
import 'package:gmwf/realtime/realtime_events.dart';
import 'package:gmwf/services/camp_session_service.dart';
import 'package:gmwf/pages/request.dart';
import 'package:gmwf/widgets/app_back_button.dart';

class UniversalProformaSheetPage extends StatefulWidget {
  final String branchId;
  final bool isDispenser;
  final bool isAdmin;
  final bool isEmbedded;

  const UniversalProformaSheetPage({
    super.key,
    required this.branchId,
    this.isDispenser = true,
    this.isAdmin = false,
    this.isEmbedded = false,
  });

  @override
  State<UniversalProformaSheetPage> createState() => _UniversalProformaSheetPageState();
}

class _UniversalProformaSheetPageState extends State<UniversalProformaSheetPage> {
  // ── Palette ───────────────────────────────────────────────────────────────
  static const _teal = Color(0xFF00695C);
  static const _tealDark = Color(0xFF004D40);
  static const _bg = Color(0xFFF4F7F6);
  static const _white = Colors.white;
  static const _headerBg = Color(0xFFE0F2F1);
  static const _gridBorder = Color(0xFFB2DFDB);
  static const _textDark = Color(0xFF1B2631);
  static const _textMid = Color(0xFF4A5568);
  static const _textLight = Color(0xFF718096);
  static const _green600 = Color(0xFF2E7D32);
  static const _red = Color(0xFFD32F2F);

  final TextEditingController _searchCtrl = TextEditingController();
  String _selectedTypeFilter = 'All';
  List<Map<String, dynamic>> _proformaMasterList = [];
  List<Map<String, dynamic>> _filteredList = [];

  // Item state maps (keyed by item code/id)
  final Map<String, bool> _selectedItems = {};
  final Set<String> _inStockCodes = {};
  final Map<String, int> _inStockQuantities = {};
  final Map<String, TextEditingController> _qtyControllers = {};
  final Map<String, TextEditingController> _priceControllers = {};
  final Map<String, DateTime> _expiryDates = {};

  bool _isSavingBatch = false;
  bool _selectAllChecked = false;

  final List<String> _typeCategories = [
    'All', 'Tablet', 'Capsule', 'Syrup', 'Injection', 'Infusion', 'Drip Set', 'Syringe', 'Cannula', 'Nebulization', 'Dressing Item', 'Consumables', 'Others'
  ];

  Map<String, dynamic> _getUserData() {
    try {
      if (Hive.isBoxOpen('app_settings')) {
        final uData = Hive.box('app_settings').get('user_data') ?? Hive.box('app_settings').get('currentUser');
        if (uData is Map) return Map<String, dynamic>.from(uData);
      }
    } catch (_) {}
    return {};
  }

  bool get _canManageProforma {
    if (widget.isDispenser && !widget.isAdmin) return false;
    final uData = _getUserData();
    final role = (uData['role'] ?? uData['userRole'] ?? uData['roleType'] ?? '').toString().toLowerCase().trim();
    if (role.contains('dispenser') || role.contains('dispensary') || role.contains('doctor') || role.contains('pharmacist') || role.contains('receptionist')) {
      if (!role.contains('admin') && !role.contains('chairman') && !role.contains('hq') && !role.contains('manager') && !role.contains('super')) {
        return false;
      }
    }
    return widget.isAdmin || role.contains('admin') || role.contains('chairman') || role.contains('hq') || role.contains('manager') || role.contains('super');
  }

    Timer? _stockDebounce;
  StreamSubscription<Map<String, dynamic>>? _realtimeSub;

  // [FIX-REACTIVE-STOCK] Recompute in-stock badges/colors whenever stockBox
  // changes — local edits, LAN broadcasts, or catch-up pushes — instead of
  // only once in initState() or after a manual batch save. Without this,
  // the "In Stock: N" badge and row highlighting go stale the moment any
  // other screen or device updates stock while this sheet is open.
  void _debouncedReloadProforma() {
    _stockDebounce?.cancel();
    _stockDebounce = Timer(const Duration(milliseconds: 150), () {
      if (mounted) _loadProformaData();
    });
  }

  @override
  void initState() {
    super.initState();
    _loadProformaData();
    _searchCtrl.addListener(_filterData);

        if (Hive.isBoxOpen(LocalStorageService.stockBox)) {
      Hive.box(LocalStorageService.stockBox)
          .listenable()
          .addListener(_debouncedReloadProforma);
    } else {
      LocalStorageService.ensureBoxOpen(LocalStorageService.stockBox).then((box) {
        if (mounted && box.isOpen) {
          box.listenable().addListener(_debouncedReloadProforma);
          _loadProformaData();
        }
      });
    }

    _realtimeSub = RealtimeManager().messageStream.listen((event) {
      final type = event['event_type'] as String?;
      if (type == RealtimeEvents.saveProformaItem ||
          type == 'save_proforma_item' ||
          type == RealtimeEvents.proformaItemUpdated ||
          type == 'proforma_item_updated') {
        if (mounted) _loadProformaData();
      }
    });
  }

    @override
  void dispose() {
    _realtimeSub?.cancel();
    _stockDebounce?.cancel();
    try {
      if (Hive.isBoxOpen(LocalStorageService.stockBox)) {
        Hive.box(LocalStorageService.stockBox)
            .listenable()
            .removeListener(_debouncedReloadProforma);
      }
    } catch (_) {}
    _searchCtrl.removeListener(_filterData);
    _searchCtrl.dispose();
    for (final ctrl in _qtyControllers.values) {
      ctrl.dispose();
    }
    for (final ctrl in _priceControllers.values) {
      ctrl.dispose();
    }
    super.dispose();
  }

  void _showDeleteMedicineDialog(Map<String, dynamic> item) {
    final isDark = _isDark;
    final code = (item['code'] as String? ?? '').trim();
    final name = (item['name'] as String? ?? item['formula'] as String? ?? code).trim();
    final reasonCtrl = TextEditingController();

    showDialog(
      context: context,
      builder: (dialogCtx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          backgroundColor: isDark ? const Color(0xFF1E293B) : Colors.white,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          title: Row(
            children: [
              const Icon(Icons.delete_forever_rounded, color: _red, size: 24),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  'Delete from Master Proforma',
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                    color: isDark ? Colors.white : _textDark,
                  ),
                ),
              ),
            ],
          ),
          content: SizedBox(
            width: 440,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Are you sure you want to permanently remove "$name" ($code) from the Universal Master Proforma Catalog?',
                  style: TextStyle(
                    fontSize: 13.5,
                    color: isDark ? Colors.white70 : _textDark,
                  ),
                ),
                const SizedBox(height: 14),
                Text(
                  'Mandatory Reason for Deletion *',
                  style: TextStyle(
                    fontSize: 12.5,
                    fontWeight: FontWeight.w600,
                    color: isDark ? const Color(0xFFFF6B6B) : _red,
                  ),
                ),
                const SizedBox(height: 4),
                TextField(
                  controller: reasonCtrl,
                  maxLines: 2,
                  style: TextStyle(color: isDark ? Colors.white : _textDark, fontSize: 13),
                  decoration: InputDecoration(
                    hintText: 'e.g. Discontinued formulation per Chairman / HQ decision',
                    hintStyle: TextStyle(color: isDark ? const Color(0xFF64748B) : Colors.grey.shade400, fontSize: 12.5),
                    filled: true,
                    fillColor: isDark ? const Color(0xFF0F172A) : const Color(0xFFF8FAFC),
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogCtx),
              child: const Text('Cancel'),
            ),
            ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: _red,
                foregroundColor: Colors.white,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
              ),
              onPressed: () async {
                final reason = reasonCtrl.text.trim();
                if (reason.isEmpty) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      content: Text('A mandatory reason is required to delete a master proforma item!'),
                      backgroundColor: _red,
                    ),
                  );
                  return;
                }

                Navigator.pop(dialogCtx);

                final user = FirebaseAuth.instance.currentUser;
                String performedByName = 'HQ Manager';
                String performedByRole = 'HQ Manager';
                String performedByUid = user?.uid ?? '';

                try {
                  if (Hive.isBoxOpen('app_settings')) {
                    final uData = Hive.box('app_settings').get('user_data') ?? Hive.box('app_settings').get('currentUser');
                    if (uData is Map) {
                      performedByName = (uData['username'] ?? uData['name'] ?? uData['displayName'] ?? performedByName).toString();
                      performedByRole = (uData['role'] ?? uData['userRole'] ?? performedByRole).toString();
                      if (performedByUid.isEmpty) performedByUid = (uData['uid'] ?? uData['id'] ?? '').toString();
                    }
                  }
                } catch (_) {}

                final auditLog = {
                  'id': 'audit_${DateTime.now().millisecondsSinceEpoch}',
                  'action': 'delete_proforma_medicine',
                  'medicineCode': code,
                  'medicineName': name,
                  'reason': reason,
                  'performedBy': performedByUid,
                  'performedByName': performedByName,
                  'performedByRole': performedByRole,
                  'timestamp': DateTime.now().toIso8601String(),
                  'branchId': widget.branchId,
                };

                final ok = await MasterProformaService.deleteProformaItem(code: code, auditLog: auditLog);
                if (ok && mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: Text('Removed "$name" from Master Proforma Catalog!'),
                      backgroundColor: const Color(0xFF00897B),
                    ),
                  );
                  _loadProformaData();
                }
              },
              child: const Text('Delete Permanently'),
            ),
          ],
        ),
      ),
    );
  }

  void _showAddMedicineDialog() {
    final isDark = _isDark;
    final nameCtrl = TextEditingController();
    final doseCtrl = TextEditingController(text: '500 mg');
    final barcodeCtrl = TextEditingController();
    final reasonCtrl = TextEditingController();
    String selectedType = 'Tablet';

    showDialog(
      context: context,
      builder: (dialogCtx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          backgroundColor: isDark ? const Color(0xFF1E293B) : Colors.white,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          title: Row(
            children: [
              const Icon(Icons.add_circle, color: Color(0xFF00897B), size: 24),
              const SizedBox(width: 10),
              Text(
                'Register Medicine to Master Proforma',
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.bold,
                  color: isDark ? Colors.white : _textDark,
                ),
              ),
            ],
          ),
          content: SizedBox(
            width: 480,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Note: Only Chairman and HQ Managers can add permanent catalog items. An audit log with mandatory reason will be permanently recorded.',
                    style: TextStyle(
                      fontSize: 12,
                      color: isDark ? const Color(0xFF94A3B8) : Colors.grey.shade600,
                    ),
                  ),
                  const SizedBox(height: 14),

                  // Formula Name
                  Text('Medicine Formula / Generic Name *', style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600, color: isDark ? const Color(0xFF38BDF8) : _teal)),
                  const SizedBox(height: 4),
                  TextField(
                    controller: nameCtrl,
                    style: TextStyle(color: isDark ? Colors.white : _textDark, fontSize: 13.5),
                    decoration: InputDecoration(
                      hintText: 'e.g. Paracetamol + Tramadol (Zaldiar)',
                      hintStyle: TextStyle(color: isDark ? const Color(0xFF64748B) : Colors.grey.shade400, fontSize: 13),
                      filled: true,
                      fillColor: isDark ? const Color(0xFF0F172A) : const Color(0xFFF8FAFC),
                      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
                    ),
                  ),
                  const SizedBox(height: 12),

                  // Type & Dose Row
                  Row(
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text('Category / Type *', style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600, color: isDark ? const Color(0xFF38BDF8) : _teal)),
                            const SizedBox(height: 4),
                            DropdownButtonFormField<String>(
                              value: selectedType,
                              dropdownColor: isDark ? const Color(0xFF1E293B) : Colors.white,
                              style: TextStyle(color: isDark ? Colors.white : _textDark, fontSize: 13),
                              decoration: InputDecoration(
                                filled: true,
                                fillColor: isDark ? const Color(0xFF0F172A) : const Color(0xFFF8FAFC),
                                contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                                border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
                              ),
                              items: _typeCategories.where((t) => t != 'All').map((t) => DropdownMenuItem(value: t, child: Text(t))).toList(),
                              onChanged: (val) {
                                if (val != null) {
                                  setDialogState(() {
                                    selectedType = val;
                                    if (val.toLowerCase() == 'syrup') {
                                      doseCtrl.text = '15 ml';
                                    } else if (val.toLowerCase() == 'injection') {
                                      doseCtrl.text = '2 cc';
                                    } else if (val.toLowerCase() == 'infusion' || val.toLowerCase() == 'drip') {
                                      doseCtrl.text = '100 ml';
                                    }
                                  });
                                }
                              },
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text('Dose *', style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600, color: isDark ? const Color(0xFF38BDF8) : _teal)),
                            const SizedBox(height: 4),
                            TextField(
                              controller: doseCtrl,
                              style: TextStyle(color: isDark ? Colors.white : _textDark, fontSize: 13.5),
                              decoration: InputDecoration(
                                hintText: 'e.g. 500 mg, 15 ml',
                                hintStyle: TextStyle(color: isDark ? const Color(0xFF64748B) : Colors.grey.shade400, fontSize: 13),
                                filled: true,
                                fillColor: isDark ? const Color(0xFF0F172A) : const Color(0xFFF8FAFC),
                                contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                                border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),

                  // Barcode (Optional)
                  Text('Item Code / Barcode (Optional)', style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600, color: isDark ? const Color(0xFF38BDF8) : _teal)),
                  const SizedBox(height: 4),
                  TextField(
                    controller: barcodeCtrl,
                    style: TextStyle(color: isDark ? Colors.white : _textDark, fontSize: 13),
                    decoration: InputDecoration(
                      hintText: 'Leave empty to auto-generate (e.g. MED-GEN-1234)',
                      hintStyle: TextStyle(color: isDark ? const Color(0xFF64748B) : Colors.grey.shade400, fontSize: 12),
                      filled: true,
                      fillColor: isDark ? const Color(0xFF0F172A) : const Color(0xFFF8FAFC),
                      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
                    ),
                  ),
                  const SizedBox(height: 14),

                  // Reason for Addition (MANDATORY)
                  Text('Reason for Addition (Mandatory Audit Requirement) *', style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.bold, color: isDark ? const Color(0xFFF59E0B) : const Color(0xFFB45309))),
                  const SizedBox(height: 4),
                  TextField(
                    controller: reasonCtrl,
                    maxLines: 2,
                    style: TextStyle(color: isDark ? Colors.white : _textDark, fontSize: 13),
                    decoration: InputDecoration(
                      hintText: 'e.g. Added permanent formula per HQ / Chairman decision',
                      hintStyle: TextStyle(color: isDark ? const Color(0xFF64748B) : Colors.grey.shade400, fontSize: 12),
                      filled: true,
                      fillColor: isDark ? const Color(0xFF0F172A) : const Color(0xFFFFFBEB),
                      contentPadding: const EdgeInsets.all(10),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(8),
                        borderSide: const BorderSide(color: Color(0xFFF59E0B)),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogCtx),
              child: Text('Cancel', style: TextStyle(color: isDark ? const Color(0xFF94A3B8) : Colors.grey.shade600)),
            ),
            ElevatedButton.icon(
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF00897B),
                foregroundColor: Colors.white,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
              ),
              onPressed: () async {
                final name = nameCtrl.text.trim();
                final dose = doseCtrl.text.trim();
                final reason = reasonCtrl.text.trim();
                if (name.isEmpty) {
                  ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Please enter medicine formula/name'), backgroundColor: Colors.red));
                  return;
                }
                if (reason.isEmpty) {
                  ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Reason for adding to Master Proforma is required for audit recording.'), backgroundColor: Colors.red));
                  return;
                }

                final uData = _getUserData();
                final performedBy = (uData['username'] ?? uData['name'] ?? uData['displayName'] ?? 'HQ Manager').toString();
                final role = (uData['role'] ?? uData['userRole'] ?? 'HQ Manager').toString();
                final uid = (uData['uid'] ?? uData['id'] ?? FirebaseAuth.instance.currentUser?.uid ?? '').toString();

                String code = barcodeCtrl.text.trim();
                if (code.isEmpty) {
                  final initials = name.split(RegExp(r'\s+')).take(3).map((w) => w.isNotEmpty ? w[0].toUpperCase() : '').join();
                  code = 'MED-$initials-${DateTime.now().millisecondsSinceEpoch % 10000}';
                }

                final cleanFormula = MasterProformaService.cleanBrandToFormula(name);

                final auditLog = {
                  'id': 'audit_${DateTime.now().millisecondsSinceEpoch}',
                  'action': 'add_proforma_medicine',
                  'medicineCode': code,
                  'medicineName': cleanFormula,
                  'medicineType': selectedType,
                  'medicineDose': dose,
                  'reason': reason,
                  'performedBy': uid,
                  'performedByName': performedBy,
                  'performedByRole': role,
                  'timestamp': DateTime.now().toIso8601String(),
                  'branchId': widget.branchId,
                };

                final newItem = {
                  'code': code,
                  'name': cleanFormula,
                  'formula': cleanFormula,
                  'type': selectedType,
                  'dose': dose,
                  'defaultPrice': 0.0,
                  'expiryDate': '2099-12-31',
                  'isProformaMaster': true,
                  'createdAt': DateTime.now().toIso8601String(),
                };

                final ok = await MasterProformaService.saveProformaItem(newItem, auditLog: auditLog);
                if (ok) {
                  Navigator.pop(dialogCtx);
                  _loadProformaData();
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: Text('Added "$cleanFormula" to Universal Master Proforma with Permanent Audit Log!'),
                      backgroundColor: const Color(0xFF00897B),
                    ),
                  );
                }
              },
              icon: const Icon(Icons.check, size: 16),
              label: const Text('Save to Proforma'),
            ),
          ],
        ),
      ),
    );
  }

  void _showEditMedicineNameDialog(Map<String, dynamic> item) {
    final isDark = _isDark;
    final code = (item['code'] ?? item['barcode'] ?? '').toString();
    final currentName = (item['formula'] ?? item['name'] ?? '').toString();
    final currentType = (item['type'] ?? 'Tablet').toString();
    final currentDose = (item['dose'] ?? '').toString();

    final nameCtrl = TextEditingController(text: currentName);
    final doseCtrl = TextEditingController(text: currentDose);
    final reasonCtrl = TextEditingController();

    final allTypes = [
      'Tablet', 'Capsule', 'Syrup', 'Injection', 'Infusion',
      'Drip Set', 'Syringe', 'Cannula', 'Nebulization', 'Dressing Item', 'Consumables', 'Others',
    ];

    String selectedType = allTypes.contains(currentType) ? currentType : 'Tablet';

    showDialog(
      context: context,
      builder: (dialogCtx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          backgroundColor: isDark ? const Color(0xFF1E293B) : Colors.white,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          title: Row(
            children: [
              const Icon(Icons.edit_note, color: Color(0xFF00897B), size: 24),
              const SizedBox(width: 10),
              Text(
                'Edit Master Proforma Medicine',
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.bold,
                  color: isDark ? Colors.white : _textDark,
                ),
              ),
            ],
          ),
          content: SizedBox(
            width: 480,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Code chip
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                    decoration: BoxDecoration(
                      color: isDark ? const Color(0xFF334155) : Colors.grey.shade200,
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Text(code, style: TextStyle(fontFamily: 'monospace', fontSize: 12, fontWeight: FontWeight.bold, color: isDark ? const Color(0xFF7DD3FC) : _textDark)),
                  ),
                  const SizedBox(height: 14),

                  // Current values summary
                  Container(
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: isDark ? const Color(0xFF0F172A) : Colors.grey.shade50,
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: isDark ? const Color(0xFF334155) : Colors.grey.shade300),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('Current Values', style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: isDark ? const Color(0xFF94A3B8) : Colors.grey.shade600)),
                        const SizedBox(height: 4),
                        Row(children: [
                          Chip(label: Text(currentType, style: const TextStyle(fontSize: 10, color: Colors.white, fontWeight: FontWeight.bold)), backgroundColor: _getTypeBadgeColor(currentType), visualDensity: VisualDensity.compact, padding: EdgeInsets.zero),
                          const SizedBox(width: 8),
                          Text(currentDose.isNotEmpty ? currentDose : '-', style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: isDark ? Colors.white70 : _textMid)),
                          const SizedBox(width: 8),
                          Expanded(child: Text(currentName, style: TextStyle(fontSize: 12, color: isDark ? Colors.white70 : _textDark), overflow: TextOverflow.ellipsis)),
                        ]),
                      ],
                    ),
                  ),
                  const SizedBox(height: 14),

                  // New Name
                  Text('Formula Name *', style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600, color: isDark ? const Color(0xFF38BDF8) : _teal)),
                  const SizedBox(height: 4),
                  TextField(
                    controller: nameCtrl,
                    style: TextStyle(color: isDark ? Colors.white : _textDark, fontSize: 13.5),
                    decoration: InputDecoration(
                      filled: true,
                      fillColor: isDark ? const Color(0xFF0F172A) : const Color(0xFFF8FAFC),
                      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
                    ),
                  ),
                  const SizedBox(height: 14),

                  // Type Dropdown
                  Text('Type *', style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600, color: isDark ? const Color(0xFF38BDF8) : _teal)),
                  const SizedBox(height: 4),
                  DropdownButtonFormField<String>(
                    value: selectedType,
                    dropdownColor: isDark ? const Color(0xFF1E293B) : Colors.white,
                    style: TextStyle(color: isDark ? Colors.white : _textDark, fontSize: 13),
                    decoration: InputDecoration(
                      filled: true,
                      fillColor: isDark ? const Color(0xFF0F172A) : const Color(0xFFF8FAFC),
                      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
                    ),
                    items: allTypes.map((t) => DropdownMenuItem(value: t, child: Text(t))).toList(),
                    onChanged: (v) {
                      if (v != null) setDialogState(() => selectedType = v);
                    },
                  ),
                  const SizedBox(height: 14),

                  // Dose
                  Text('Dose', style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600, color: isDark ? const Color(0xFF38BDF8) : _teal)),
                  const SizedBox(height: 4),
                  TextField(
                    controller: doseCtrl,
                    style: TextStyle(color: isDark ? Colors.white : _textDark, fontSize: 13.5),
                    decoration: InputDecoration(
                      hintText: 'e.g. 500mg, 5ml, Standard',
                      hintStyle: TextStyle(color: isDark ? const Color(0xFF64748B) : Colors.grey.shade400, fontSize: 12),
                      filled: true,
                      fillColor: isDark ? const Color(0xFF0F172A) : const Color(0xFFF8FAFC),
                      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
                    ),
                  ),
                  const SizedBox(height: 14),

                  // Reason for Edit (MANDATORY)
                  Text('Reason for Modification (Mandatory Audit) *', style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.bold, color: isDark ? const Color(0xFFF59E0B) : const Color(0xFFB45309))),
                  const SizedBox(height: 4),
                  TextField(
                    controller: reasonCtrl,
                    maxLines: 2,
                    style: TextStyle(color: isDark ? Colors.white : _textDark, fontSize: 13),
                    decoration: InputDecoration(
                      hintText: 'e.g. Corrected dose from 250mg to 500mg per HQ directive',
                      hintStyle: TextStyle(color: isDark ? const Color(0xFF64748B) : Colors.grey.shade400, fontSize: 12),
                      filled: true,
                      fillColor: isDark ? const Color(0xFF0F172A) : const Color(0xFFFFFBEB),
                      contentPadding: const EdgeInsets.all(10),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(8),
                        borderSide: const BorderSide(color: Color(0xFFF59E0B)),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogCtx),
              child: Text('Cancel', style: TextStyle(color: isDark ? const Color(0xFF94A3B8) : Colors.grey.shade600)),
            ),
            ElevatedButton.icon(
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF00897B),
                foregroundColor: Colors.white,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
              ),
              onPressed: () async {
                final newName = nameCtrl.text.trim();
                final newDose = doseCtrl.text.trim();
                final newType = selectedType;
                final reason = reasonCtrl.text.trim();
                if (newName.isEmpty) {
                  ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Formula name cannot be empty'), backgroundColor: Colors.red));
                  return;
                }
                if (reason.isEmpty) {
                  ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Reason for modification is required for audit recording.'), backgroundColor: Colors.red));
                  return;
                }

                final uData = _getUserData();
                final performedBy = (uData['username'] ?? uData['name'] ?? uData['displayName'] ?? 'Unknown').toString();
                final role = (uData['role'] ?? uData['userRole'] ?? 'HQ Manager').toString();
                final uid = (uData['uid'] ?? uData['id'] ?? FirebaseAuth.instance.currentUser?.uid ?? '').toString();

                final auditLog = {
                  'id': 'audit_${DateTime.now().millisecondsSinceEpoch}',
                  'action': 'edit_proforma_medicine',
                  'medicineCode': code,
                  'oldName': currentName,
                  'newName': newName,
                  'oldType': currentType,
                  'newType': newType,
                  'oldDose': currentDose,
                  'newDose': newDose,
                  'reason': reason,
                  'performedBy': uid,
                  'performedByName': performedBy,
                  'performedByRole': role,
                  'timestamp': DateTime.now().toIso8601String(),
                  'branchId': widget.branchId,
                };

                final ok = await MasterProformaService.editProformaItem(
                  code: code,
                  newName: newName,
                  newType: newType,
                  newDose: newDose,
                  auditLog: auditLog,
                );

                if (ok) {
                  Navigator.pop(dialogCtx);
                  _loadProformaData();
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: Text('Updated "$currentName" → "$newName" ($newType / $newDose) with Audit Log!'),
                      backgroundColor: const Color(0xFF00897B),
                    ),
                  );
                }
              },
              icon: const Icon(Icons.check, size: 16),
              label: const Text('Update Medicine'),
            ),
          ],
        ),
      ),
    );
  }

  void _showAuditTrailDialog(Map<String, dynamic> item) {
    final isDark = _isDark;
    final code = (item['code'] ?? item['barcode'] ?? '').toString();
    final name = (item['formula'] ?? item['name'] ?? '').toString();
    final audits = MasterProformaService.getAuditTrailForItem(code);

    showDialog(
      context: context,
      builder: (dialogCtx) => AlertDialog(
        backgroundColor: isDark ? const Color(0xFF1E293B) : Colors.white,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Row(
          children: [
            const Icon(Icons.history_rounded, color: Color(0xFF00897B), size: 24),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Audit Trail & History',
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                      color: isDark ? Colors.white : _textDark,
                    ),
                  ),
                  Text(
                    '$name ($code)',
                    style: TextStyle(
                      fontSize: 12,
                      color: isDark ? const Color(0xFF94A3B8) : Colors.grey.shade600,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
        content: SizedBox(
          width: 500,
          child: audits.isEmpty
              ? Padding(
                  padding: const EdgeInsets.symmetric(vertical: 24),
                  child: Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.verified_outlined, size: 36, color: isDark ? const Color(0xFF64748B) : Colors.grey.shade400),
                        const SizedBox(height: 10),
                        Text(
                          'Standard Master Seed Item (No edits recorded)',
                          style: TextStyle(fontSize: 13, color: isDark ? const Color(0xFF94A3B8) : Colors.grey.shade600),
                        ),
                      ],
                    ),
                  ),
                )
              : ListView.separated(
                  shrinkWrap: true,
                  itemCount: audits.length,
                  separatorBuilder: (_, index) => const Divider(height: 16),
                  itemBuilder: (ctx, idx) {
                    final log = audits[audits.length - 1 - idx]; // newest first
                    final action = (log['action'] ?? '').toString();
                    final user = (log['performedByName'] ?? log['performedBy'] ?? 'Authorized User').toString();
                    final role = (log['performedByRole'] ?? 'Staff').toString();
                    final time = (log['timestamp'] ?? log['savedAt'] ?? '').toString();
                    final reason = (log['reason'] ?? 'No reason provided').toString();
                    final oldN = log['oldName']?.toString();
                    final newN = log['newName']?.toString();

                    return Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
                              decoration: BoxDecoration(
                                color: action.contains('edit')
                                    ? (isDark ? const Color(0xFF0284C7).withValues(alpha: 0.2) : Colors.blue.shade50)
                                    : (isDark ? const Color(0xFF059669).withValues(alpha: 0.2) : Colors.green.shade50),
                                borderRadius: BorderRadius.circular(4),
                              ),
                              child: Text(
                                action.contains('edit') ? '✏️ Name Modified' : '➕ Added to Catalog',
                                style: TextStyle(
                                  fontSize: 11.5,
                                  fontWeight: FontWeight.bold,
                                  color: action.contains('edit')
                                      ? (isDark ? const Color(0xFF38BDF8) : Colors.blue.shade800)
                                      : (isDark ? const Color(0xFF34D399) : Colors.green.shade800),
                                ),
                              ),
                            ),
                            const Spacer(),
                            if (time.isNotEmpty)
                              Text(
                                time.length > 16 ? time.substring(0, 16).replaceAll('T', ' ') : time,
                                style: TextStyle(fontSize: 11, color: isDark ? const Color(0xFF94A3B8) : Colors.grey.shade500),
                              ),
                          ],
                        ),
                        const SizedBox(height: 6),
                        Text(
                          'By: $user ($role)',
                          style: TextStyle(
                            fontSize: 12.5,
                            fontWeight: FontWeight.w600,
                            color: isDark ? Colors.white : _textDark,
                          ),
                        ),
                        if (oldN != null && newN != null) ...[
                          const SizedBox(height: 3),
                          Text(
                            'Changed from "$oldN" to "$newN"',
                            style: TextStyle(fontSize: 12, color: isDark ? const Color(0xFFCBD5E1) : Colors.grey.shade700),
                          ),
                        ],
                        const SizedBox(height: 6),
                        Container(
                          padding: const EdgeInsets.all(8),
                          decoration: BoxDecoration(
                            color: isDark ? const Color(0xFF0F172A) : const Color(0xFFFFFBEB),
                            borderRadius: BorderRadius.circular(6),
                            border: Border.all(color: isDark ? const Color(0xFF334155) : const Color(0xFFFDE68A)),
                          ),
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Text('📌 ', style: TextStyle(fontSize: 11)),
                              Expanded(
                                child: Text(
                                  'Reason: $reason',
                                  style: TextStyle(
                                    fontSize: 12,
                                    fontStyle: FontStyle.italic,
                                    color: isDark ? const Color(0xFFFBBF24) : const Color(0xFF92400E),
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    );
                  },
                ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogCtx),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  void _loadProformaData() {
    final list = MasterProformaService.getAllProformaItems();
    final defaultExp = DateTime.now().add(const Duration(days: 365));
    final String activeBranch = widget.branchId.isEmpty ? 'default' : widget.branchId;
    final String activeCamp = (CampSessionService.getActiveCamp() ?? '').toLowerCase().trim();

    final List<Map<String, dynamic>> existingStock = [];
    try {
      if (Hive.isBoxOpen(LocalStorageService.stockBox)) {
        final box = Hive.box(LocalStorageService.stockBox);
        for (final k in box.keys) {
          final val = box.get(k);
          if (val is Map) {
            final m = Map<String, dynamic>.from(val);
            if (m['status'] == 'deleted') continue;

            final itemBranch = (m['branchId'] ?? '').toString().trim().toLowerCase();
            if (activeBranch.isNotEmpty && activeBranch != 'default' && itemBranch.isNotEmpty && itemBranch != activeBranch.toLowerCase()) {
              continue;
            }

            final itemCamp = (m['dispensaryId'] ?? m['campId'] ?? '').toString().trim().toLowerCase();
            if (activeCamp.isNotEmpty && itemCamp.isNotEmpty && itemCamp != 'all' && itemCamp != activeCamp) {
              continue;
            }

            existingStock.add(m);
          }
        }
      }
    } catch (_) {}

    setState(() {
      _proformaMasterList = list;
      _inStockCodes.clear();
      _inStockQuantities.clear();

      for (final item in list) {
        final code = item['code'] as String? ?? 'MED-GEN';
        final name = (item['name'] as String? ?? '').trim().toLowerCase();
        final formula = (item['formula'] as String? ?? name).trim().toLowerCase();
        final type = (item['type'] as String? ?? '').trim().toLowerCase();
        final dose = (item['dose'] as String? ?? '').trim().toLowerCase();
        final cleanCode = code.trim().toLowerCase();

        int inStockQty = 0;
        for (final stockItem in existingStock) {
          final sName = (stockItem['name'] as String? ?? '').trim().toLowerCase();
          final sFormula = (stockItem['formula'] as String? ?? sName).trim().toLowerCase();
          final sType = (stockItem['type'] as String? ?? '').trim().toLowerCase();
          final sDose = (stockItem['dose'] as String? ?? '').trim().toLowerCase();
          final sBarcode = (stockItem['code'] as String? ?? stockItem['barcode'] as String? ?? '').trim().toLowerCase();

          bool isMatch = false;
          if (cleanCode.isNotEmpty && sBarcode.isNotEmpty && cleanCode == sBarcode) {
            isMatch = true;
          } else if ((sFormula == formula || sName == name || sFormula == name || sName == formula) &&
              sType == type &&
              (dose.isEmpty || sDose == dose || sDose == 'standard')) {
            isMatch = true;
          }

          if (isMatch) {
            final q = (stockItem['quantity'] as num?)?.toInt() ?? 0;
            if (q > 0) inStockQty += q;
          }
        }

        if (inStockQty > 0) {
          _inStockCodes.add(code);
          _inStockQuantities[code] = inStockQty;
        }

        _selectedItems[code] = false;

        if (!_qtyControllers.containsKey(code)) {
          _qtyControllers[code] = TextEditingController(text: '0');
        }

        final defaultPrice = (item['defaultPrice'] as num?)?.toDouble() ?? 0.0;
        if (!_priceControllers.containsKey(code)) {
          _priceControllers[code] = TextEditingController(
            text: defaultPrice > 0 ? defaultPrice.toStringAsFixed(0) : '0',
          );
        }

        if (!_expiryDates.containsKey(code)) {
          _expiryDates[code] = defaultExp;
        }
      }
      _filterData();
    });
  }

  void _filterData() {
    final query = _searchCtrl.text.trim().toLowerCase();
    setState(() {
      var directMatches = _proformaMasterList.where((item) {
        final name = (item['name'] as String? ?? '').toLowerCase();
        final formula = (item['formula'] as String? ?? '').toLowerCase();
        final code = (item['code'] as String? ?? '').toLowerCase();
        final type = item['type'] as String? ?? 'Tablet';

        final matchesQuery = query.isEmpty ||
            name.contains(query) ||
            formula.contains(query) ||
            code.contains(query);

        final matchesType = _selectedTypeFilter == 'All' ||
            type == _selectedTypeFilter ||
            (_selectedTypeFilter == 'Infusion' && (type == 'Infusion' || type == 'Drip'));

        return matchesQuery && matchesType;
      }).toList();

      if (directMatches.isEmpty && query.length >= 3) {
        directMatches = _proformaMasterList.where((item) {
          final name = (item['name'] as String? ?? '').toLowerCase();
          final formula = (item['formula'] as String? ?? '').toLowerCase();
          final type = item['type'] as String? ?? 'Tablet';
          final matchesType = _selectedTypeFilter == 'All' || type == _selectedTypeFilter;
          if (!matchesType) return false;

          final simName = StringSimilarityHelper.calculateSimilarity(query, name);
          final simForm = StringSimilarityHelper.calculateSimilarity(query, formula);
          return simName >= 0.55 || simForm >= 0.55;
        }).toList();
      }

      _filteredList = directMatches;

      // Check if all filtered are selected
      if (_filteredList.isEmpty) {
        _selectAllChecked = false;
      } else {
        _selectAllChecked = _filteredList.every((item) {
          final code = item['code'] as String? ?? '';
          return _selectedItems[code] == true;
        });
      }
    });
  }

  void _toggleSelectAll(bool? val) {
    final flag = val ?? false;
    setState(() {
      _selectAllChecked = flag;
      for (final item in _filteredList) {
        final code = item['code'] as String? ?? '';
        _selectedItems[code] = flag;
        if (flag) {
          final currentQty = int.tryParse(_qtyControllers[code]?.text ?? '0') ?? 0;
          if (currentQty == 0) {
            _qtyControllers[code]?.text = '20';
          }
        }
      }
    });
  }

  void _selectItemsWithQty() {
    setState(() {
      int count = 0;
      for (final item in _proformaMasterList) {
        final code = item['code'] as String? ?? '';
        final qtyText = _qtyControllers[code]?.text.trim() ?? '0';
        final qty = int.tryParse(qtyText) ?? 0;
        if (qty > 0) {
          _selectedItems[code] = true;
          count++;
        }
      }

      _filterData();

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Selected $count items with Quantity > 0'),
          backgroundColor: _teal,
          duration: const Duration(seconds: 2),
        ),
      );
    });
  }

  int get _selectedCount => _selectedItems.values.where((v) => v).length;

  Future<void> _pickExpiryDate(String code) async {
    final current = _expiryDates[code] ?? DateTime.now().add(const Duration(days: 365));
    final picked = await showDatePicker(
      context: context,
      initialDate: current,
      firstDate: DateTime.now(),
      lastDate: DateTime.now().add(const Duration(days: 3650)),
      builder: (context, child) {
        return Theme(
          data: Theme.of(context).copyWith(
            colorScheme: const ColorScheme.light(
              primary: _teal,
              onPrimary: Colors.white,
              onSurface: _textDark,
            ),
          ),
          child: child!,
        );
      },
    );

    if (picked != null) {
      setState(() {
        _expiryDates[code] = picked;
      });
    }
  }

  Future<void> _saveBatchToInventory() async {
    final itemsToSave = <Map<String, dynamic>>[];

    for (final item in _proformaMasterList) {
      final code = item['code'] as String? ?? '';
      if (_selectedItems[code] == true) {
        final qtyText = _qtyControllers[code]?.text.trim() ?? '0';
        final qty = int.tryParse(qtyText) ?? 0;
        final priceText = _priceControllers[code]?.text.trim() ?? '0';
        final price = double.tryParse(priceText) ?? 0.0;
        final expDate = _expiryDates[code] ?? DateTime.now().add(const Duration(days: 365));

        if (qty < 0) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Please enter a valid non-negative quantity for "${item['name']}"'),
              backgroundColor: _red,
            ),
          );
          return;
        }

        itemsToSave.add({
          'proforma': item,
          'qty': qty,
          'price': price,
          'expiryDate': DateFormat('yyyy-MM-dd').format(expDate),
        });
      }
    }

    if (itemsToSave.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('No items selected! Check at least one medicine to add to inventory.'),
          backgroundColor: _red,
        ),
      );
      return;
    }

    setState(() => _isSavingBatch = true);

    try {
      String activeBranch = widget.branchId.trim();
      if (activeBranch.isEmpty || activeBranch.toLowerCase() == 'default' || activeBranch.toLowerCase() == 'all') {
        activeBranch = LocalStorageService.getActiveBranchId() ?? 'karachi';
      }
      final stockBox = Hive.box(LocalStorageService.stockBox);
      final user = FirebaseAuth.instance.currentUser;
      String addedBy = 'Dispenser';
      String performedByRole = 'Dispenser';
      String performedByEmail = user?.email ?? '';
      String performedByUid = user?.uid ?? '';

      try {
        if (Hive.isBoxOpen('app_settings')) {
          final uData = Hive.box('app_settings').get('user_data') ?? Hive.box('app_settings').get('currentUser');
          if (uData is Map) {
            addedBy = (uData['username'] ?? uData['name'] ?? uData['displayName'] ?? addedBy).toString();
            performedByRole = (uData['role'] ?? uData['userRole'] ?? performedByRole).toString();
            if (performedByUid.isEmpty) performedByUid = (uData['uid'] ?? uData['id'] ?? '').toString();
            if (performedByEmail.isEmpty) performedByEmail = (uData['email'] ?? '').toString();
          }
        }
      } catch (_) {}

      if (addedBy == 'Dispenser' && user != null) {
        final local = LocalStorageService.getLocalUserByUid(user.uid);
        if (local != null) {
          addedBy = (local['username'] ?? local['name'] ?? local['displayName'] ?? addedBy).toString();
          performedByRole = (local['role'] ?? performedByRole).toString();
        }
      }
      if (addedBy == 'Dispenser' && user?.displayName != null && user!.displayName!.isNotEmpty) {
        addedBy = user.displayName!;
      } else if (addedBy == 'Dispenser' && user?.email != null && user!.email!.isNotEmpty) {
        addedBy = user.email!.split('@').first;
      }

      int totalAdded = 0;
      int totalNewCount = 0;

      final String activeCamp = CampSessionService.getActiveCamp(activeBranch) ?? '';

      for (final entry in itemsToSave) {
        final rawProf = entry['proforma'];
        final prof = (rawProf is Map) ? Map<String, dynamic>.from(rawProf) : <String, dynamic>{};
        final String name = prof['name'] as String? ?? 'Unknown';
        final String formula = prof['formula'] as String? ?? '';
        final String type = prof['type'] as String? ?? 'Tablet';
        final String dose = prof['dose'] as String? ?? '';
        final String code = prof['code'] as String? ?? '';
        final int qty = entry['qty'] as int;
        final double price = entry['price'] as double;
        final String exp = entry['expiryDate'] as String;

        // Search stockBox for an existing item matching Name/Formula + Type + Dose (or exact barcode)
        final cleanCode = code.trim().toLowerCase();
        final cleanN = (formula.isNotEmpty ? formula : name).trim().toLowerCase().replaceAll(RegExp(r'\s+'), ' ');
        final cleanT = type.trim().toLowerCase().replaceAll(RegExp(r'\s+'), '');
        final cleanD = dose.trim().toLowerCase().replaceAll(RegExp(r'\s+'), '');

        Map<String, dynamic>? existingStockData;

        for (final k in stockBox.keys) {
          final val = stockBox.get(k);
          if (val is Map) {
            final map = Map<String, dynamic>.from(val);

            // Camp filter check
            final itemCamp = (map['dispensaryId'] ?? map['campId'])?.toString().trim().toLowerCase() ?? '';
            if (activeCamp.isNotEmpty && itemCamp.isNotEmpty && itemCamp != 'all' && itemCamp != activeCamp.toLowerCase()) {
              continue;
            }

            final itemCode = (map['code'] ?? map['barcode'] ?? '').toString().trim().toLowerCase();
            final itemN = (map['name'] ?? map['formula'] ?? '').toString().trim().toLowerCase().replaceAll(RegExp(r'\s+'), ' ');
            final itemT = (map['type'] ?? '').toString().trim().toLowerCase().replaceAll(RegExp(r'\s+'), '');
            final itemD = (map['dose'] ?? '').toString().trim().toLowerCase().replaceAll(RegExp(r'\s+'), '');

            bool isMatch = false;
            // Match Name/Formula + Type + Dose FIRST to avoid creating duplicate medicine records when barcodes differ
            if (itemN == cleanN && itemT == cleanT && (cleanD.isEmpty || itemD == cleanD || itemD == 'standard')) {
              isMatch = true;
            } else if (cleanCode.isNotEmpty && itemCode.isNotEmpty && itemCode == cleanCode) {
              isMatch = true;
            }

            if (isMatch) {
              existingStockData = map;
              break;
            }
          }
        }

        // If medicine ALREADY EXISTS in branch stock, increment its quantity!
        if (existingStockData != null) {
          final oldQty = (existingStockData['quantity'] as num?)?.toInt() ?? 0;
          final newTotalQty = oldQty + qty;
          final existingDocId = (existingStockData['id'] ?? existingStockData['docId'] ?? existingStockData['medicineId'] ?? code).toString();

          final updatedStock = Map<String, dynamic>.from(existingStockData);
          updatedStock['quantity'] = newTotalQty;
          if (price > 0) updatedStock['price'] = price;
          if (exp.isNotEmpty) updatedStock['expiryDate'] = exp;
          updatedStock['lastUpdated'] = DateTime.now().toIso8601String();
          updatedStock['updatedAt'] = DateTime.now().toIso8601String();

          LocalStorageService.saveLocalInventoryItem(updatedStock);
          totalAdded += qty;
          totalNewCount++;

          final logData = {
            'action': 'add_stock',
            'medicineName': name,
            'medicineFormula': formula,
            'medicineType': type,
            'medicineDose': dose,
            'medicineCode': code,
            'medicineId': existingDocId,
            'docId': existingDocId,
            'quantityAdded': qty,
            'previousQuantity': oldQty,
            'newQuantity': newTotalQty,
            'price': price,
            'expiryDate': exp,
            'branchId': activeBranch,
            'dispensaryId': activeCamp.isNotEmpty ? activeCamp : 'all',
            'campId': activeCamp.isNotEmpty ? activeCamp : 'all',
            'isProforma': true,
            'source': 'Universal Proforma Catalog (Restock)',
            'performedBy': performedByUid,
            'performedByName': addedBy,
            'performedByRole': performedByRole,
            'performedByEmail': performedByEmail,
            'details': 'Restocked +$qty units of $name ($type $dose, New Total: $newTotalQty) from Universal Proforma Catalog by $addedBy ($performedByRole)',
            'timestamp': FieldValue.serverTimestamp(),
            'createdAt': DateTime.now().toIso8601String(),
          };

          await LocalStorageService.saveLocalInventoryLog(logData);

                   RealtimeManager().sendMessage({
            'event_type': RealtimeEvents.saveStockItem,
            'branchId': activeBranch,
            'data': {
              ...updatedStock,
              '_quantityDelta': qty,   // the amount being added this restock, NOT newTotalQty
            },
            'logData': logData,
          });

          // LAN Server First routing: the server syncs to Firestore.
          // If offline or LAN disconnected, enqueue locally for background sync without blocking UI.
          if (!RealtimeManager().isConnected) {
            await LocalStorageService.enqueueSync({
              'type': 'add_inventory_stock',
              'branchId': activeBranch,
              'medicineId': existingDocId,
              'quantity': qty,
              'campId': activeCamp,
              'dispensaryId': activeCamp,
              'data': updatedStock,
              'logData': logData,
            });
          }
          continue;
        }

        final docId = RequestUtils.generateDocId(name, type, dose, exp, campId: activeCamp);
        final stockData = {
          'docId': docId,
          'id': docId,
          'medicineId': docId,
          'code': code,
          'barcode': code,
          'name': name,
          'formula': formula,
          'type': type,
          'dose': dose,
          'quantity': qty,
          'price': price,
          'expiryDate': exp,
          'branchId': activeBranch,
          'dispensaryId': activeCamp.isNotEmpty ? activeCamp : 'all',
          'campId': activeCamp.isNotEmpty ? activeCamp : 'all',
          'isProforma': true,
          'source': 'Universal Proforma Catalog',
          'addedBy': addedBy,
          'performedByName': addedBy,
          'performedByRole': performedByRole,
          'performedByUid': performedByUid,
          'createdAt': DateTime.now().toIso8601String(),
          'lastUpdated': DateTime.now().toIso8601String(),
        };

        LocalStorageService.saveLocalInventoryItem(stockData);
        totalAdded += qty;
        totalNewCount++;

        // Detailed Audit Log entry for tracking who added what from proforma
        final logData = {
          'action': 'add_from_proforma',
          'medicineName': name,
          'medicineFormula': formula,
          'medicineType': type,
          'medicineDose': dose,
          'medicineCode': code,
          'medicineId': docId,
          'docId': docId,
          'quantityAdded': qty,
          'quantity': qty,
          'previousQuantity': 0,
          'newQuantity': qty,
          'price': price,
          'totalAmount': price * qty,
          'expiryDate': exp,
          'branchId': activeBranch,
          'dispensaryId': activeCamp.isNotEmpty ? activeCamp : 'all',
          'campId': activeCamp.isNotEmpty ? activeCamp : 'all',
          'isProforma': true,
          'source': 'Universal Proforma Catalog',
          'proformaCode': code,
          'performedBy': performedByUid,
          'performedByName': addedBy,
          'performedByRole': performedByRole,
          'performedByEmail': performedByEmail,
          'details': 'Added $qty units of $name ($type $dose, Expiry: $exp, Price: PKR $price) from Universal Proforma Catalog by $addedBy ($performedByRole)',
          'timestamp': FieldValue.serverTimestamp(),
          'createdAt': DateTime.now().toIso8601String(),
        };

        // Save locally to audit logs Hive box
        await LocalStorageService.saveLocalInventoryLog(logData);

        // LAN Broadcast
        RealtimeManager().sendMessage({
          'event_type': RealtimeEvents.saveStockItem,
          'branchId': activeBranch,
          'data': stockData,
          'logData': logData,
        });

        // Offline resilience: if LAN disconnected, enqueue locally without blocking UI
        if (!RealtimeManager().isConnected) {
          await LocalStorageService.enqueueSync({
            'type': 'add_proforma_stock',
            'branchId': activeBranch,
            'data': stockData,
            'logData': logData,
          });
        }
      }

      if (!mounted) return;

      setState(() {
        _isSavingBatch = false;
        // Reset selections & quantities
        for (final item in _proformaMasterList) {
          final code = item['code'] as String? ?? '';
          _selectedItems[code] = false;
          _qtyControllers[code]?.text = '0';
        }
        _selectAllChecked = false;
      });

      _loadProformaData();

      showDialog(
        context: context,
        builder: (context) => AlertDialog(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          title: Row(
            children: const [
              Icon(FontAwesomeIcons.circleCheck, color: _green600, size: 28),
              SizedBox(width: 12),
              Text('Inventory Added!'),
            ],
          ),
          content: Text(
            'Successfully added/updated $totalNewCount proforma medicines ($totalAdded total pcs) in Branch Inventory!',
            style: const TextStyle(fontSize: 14, color: _textDark),
          ),
          actions: [
            ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: _teal,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
              ),
              onPressed: () {
                Navigator.of(context).pop();
                Navigator.of(context).pop(true); // Return success to caller
              },
              child: const Text('Back to Inventory', style: TextStyle(color: Colors.white)),
            ),
          ],
        ),
      );
    } catch (e) {
      if (!mounted) return;
      setState(() => _isSavingBatch = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Failed to save batch: $e'), backgroundColor: _red),
      );
    }
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
    final isDark = _isDark;
    return Scaffold(
      backgroundColor: isDark ? const Color(0xFF0F172A) : _bg,
      appBar: AppBar(
        backgroundColor: isDark ? const Color(0xFF0F172A) : _tealDark,
        elevation: 2,
        automaticallyImplyLeading: false,
        leading: (!widget.isEmbedded && Navigator.canPop(context))
            ? AppBackButton(color: Colors.white)
            : null,
        iconTheme: const IconThemeData(color: Colors.white),
        title: Row(
          children: [
            const Icon(FontAwesomeIcons.fileExcel, color: Colors.white, size: 22),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text(
                    'Universal Proforma Sheet',
                    style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 18),
                  ),
                  const Text(
                    'Master Generic Formula Catalog (Universal)',
                    style: TextStyle(color: Color(0xFF80CBC4), fontSize: 11.5, fontWeight: FontWeight.w600),
                  ),
                ],
              ),
            ),
          ],
        ),
        actions: [
          if (_canManageProforma)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 4),
              child: ElevatedButton.icon(
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF00897B),
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 0),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                  elevation: 2,
                ),
                onPressed: _showAddMedicineDialog,
                icon: const Icon(Icons.add_circle_outline, size: 16, color: Colors.white),
                label: const Text('Add Medicine', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12.5)),
              ),
            ),
          IconButton(
            tooltip: 'Auto-Select Items with Qty > 0',
            icon: const Icon(FontAwesomeIcons.listCheck, color: Colors.white, size: 18),
            onPressed: _selectItemsWithQty,
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: Column(
        children: [
          // ── Top Search & Filter Bar ───────────────────────────────────────
          _buildFilterHeader(),

          Expanded(
            child: _filteredList.isEmpty
                ? _buildEmptyState()
                : LayoutBuilder(
                    builder: (ctx, constraints) =>
                        _buildExcelGridSheet(constraints.maxHeight),
                  ),
          ),

          // ── Bottom Action Sticky Toolbar ──────────────────────────────────
          _buildBottomToolbar(),
        ],
      ),
    );
  }

  Widget _buildFilterHeader() {
    final isDark = _isDark;
    return Container(
      color: isDark ? const Color(0xFF1E293B) : _white,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Column(
        children: [
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _searchCtrl,
                  style: TextStyle(color: isDark ? Colors.white : _textDark),
                  decoration: InputDecoration(
                    hintText: 'Search Proforma by Name, Formula, Barcode...',
                    hintStyle: TextStyle(color: isDark ? const Color(0xFF94A3B8) : _textLight),
                    prefixIcon: Icon(Icons.search, color: isDark ? const Color(0xFF38BDF8) : _teal),
                    suffixIcon: _searchCtrl.text.isNotEmpty
                        ? IconButton(
                            icon: Icon(Icons.clear, size: 18, color: isDark ? const Color(0xFF94A3B8) : Colors.grey),
                            onPressed: () => _searchCtrl.clear(),
                          )
                        : null,
                    filled: true,
                    fillColor: isDark ? const Color(0xFF0F172A) : _bg,
                    contentPadding: const EdgeInsets.symmetric(vertical: 10, horizontal: 16),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(10),
                      borderSide: BorderSide(color: isDark ? const Color(0xFF334155) : _gridBorder),
                    ),
                    focusedBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(10),
                      borderSide: BorderSide(color: isDark ? const Color(0xFF38BDF8) : _teal, width: 2),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              OutlinedButton.icon(
                style: OutlinedButton.styleFrom(
                  foregroundColor: isDark ? const Color(0xFF38BDF8) : _teal,
                  side: BorderSide(color: isDark ? const Color(0xFF38BDF8) : _teal),
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                ),
                onPressed: _selectItemsWithQty,
                icon: const Icon(FontAwesomeIcons.checkDouble, size: 14),
                label: const Text('Auto Select Qty > 0'),
              ),
            ],
          ),
          const SizedBox(height: 10),

          // ── Medicine Count Badges ──
          Row(
            children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                decoration: BoxDecoration(
                  color: isDark ? const Color(0xFF0F766E).withValues(alpha: 0.2) : _teal.withValues(alpha: 0.08),
                  borderRadius: BorderRadius.circular(6),
                  border: Border.all(color: isDark ? const Color(0xFF0F766E) : _teal.withValues(alpha: 0.2)),
                ),
                child: Text(
                  'Total Master Catalog: ${_proformaMasterList.length} Medicines',
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.bold,
                    color: isDark ? const Color(0xFF38BDF8) : _tealDark,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                decoration: BoxDecoration(
                  color: isDark ? const Color(0xFF1E3A3A) : Colors.blue.shade50,
                  borderRadius: BorderRadius.circular(6),
                  border: Border.all(color: isDark ? const Color(0xFF0284C7) : Colors.blue.shade200),
                ),
                child: Text(
                  'Showing: ${_filteredList.length} Matching',
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.bold,
                    color: isDark ? const Color(0xFF7DD3FC) : Colors.blue.shade900,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                decoration: BoxDecoration(
                  color: _selectedCount > 0
                      ? (isDark ? const Color(0xFF065F46) : Colors.green.shade50)
                      : (isDark ? const Color(0xFF334155) : Colors.grey.shade100),
                  borderRadius: BorderRadius.circular(6),
                  border: Border.all(
                    color: _selectedCount > 0
                        ? (isDark ? const Color(0xFF10B981) : Colors.green.shade300)
                        : (isDark ? const Color(0xFF475569) : Colors.grey.shade300),
                  ),
                ),
                child: Text(
                  'Selected: $_selectedCount',
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.bold,
                    color: _selectedCount > 0
                        ? (isDark ? const Color(0xFF34D399) : Colors.green.shade800)
                        : (isDark ? const Color(0xFF94A3B8) : Colors.grey.shade600),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),

          // Category filter pills
          SizedBox(
            height: 34,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              itemCount: _typeCategories.length,
              separatorBuilder: (_, index) => const SizedBox(width: 6),
              itemBuilder: (context, idx) {
                final cat = _typeCategories[idx];
                final isSelected = _selectedTypeFilter == cat;
                return ChoiceChip(
                  label: Text(
                    cat,
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
                      color: isSelected ? Colors.white : (isDark ? const Color(0xFFCBD5E1) : _textMid),
                    ),
                  ),
                  selected: isSelected,
                  selectedColor: isDark ? const Color(0xFF0F766E) : _teal,
                  backgroundColor: isDark ? const Color(0xFF334155) : _bg,
                  onSelected: (val) {
                    if (val) {
                      setState(() {
                        _selectedTypeFilter = cat;
                        _filterData();
                      });
                    }
                  },
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildExcelGridSheet([double? availableHeight]) {
    final isDark = _isDark;
    final double tableWidth = _canManageProforma ? 1360 : 1240;

    final headerBg = isDark ? const Color(0xFF0F766E) : _headerBg;
    final headerTextColor = isDark ? Colors.white : _tealDark;
    final rowBgNormal = isDark ? const Color(0xFF1E293B) : Colors.white;
    final rowBgAlt = isDark ? const Color(0xFF0F172A) : const Color(0xFFFAFAFA);
    final rowBgSelected = isDark ? const Color(0xFF1E3A3A) : _teal.withValues(alpha: 0.08);
    final borderColor = isDark ? const Color(0xFF334155) : _gridBorder.withValues(alpha: 0.6);
    final textColor = isDark ? Colors.white : _textDark;

    return Container(
      margin: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: rowBgNormal,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: isDark ? const Color(0xFF334155) : _gridBorder),
        boxShadow: const [
          BoxShadow(color: Color(0x10000000), blurRadius: 6, offset: Offset(0, 3)),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: SizedBox(
            width: tableWidth,
            height: availableHeight != null ? (availableHeight - 24).clamp(100.0, double.infinity) : null,
            child: Column(
              children: [
                // ── Header Row ──
                Container(
                  height: 48,
                  color: headerBg,
                  child: Row(
                    children: [
                      SizedBox(
                        width: 110,
                        child: Row(
                          children: [
                            Checkbox(
                              value: _selectAllChecked,
                              activeColor: _teal,
                              onChanged: _toggleSelectAll,
                            ),
                            Text('Select', style: TextStyle(fontWeight: FontWeight.bold, color: headerTextColor, fontSize: 13.5)),
                          ],
                        ),
                      ),
                      _vDivider(borderColor),
                      SizedBox(width: 145, child: Padding(padding: const EdgeInsets.symmetric(horizontal: 10), child: Text('Code / Barcode', style: TextStyle(fontWeight: FontWeight.bold, color: headerTextColor, fontSize: 13.5)))),
                      _vDivider(borderColor),
                      Expanded(flex: 4, child: Padding(padding: const EdgeInsets.symmetric(horizontal: 10), child: Text('Medicine Formula (Generic)', style: TextStyle(fontWeight: FontWeight.bold, color: headerTextColor, fontSize: 13.5)))),
                      if (_canManageProforma) ...[
                        _vDivider(borderColor),
                        SizedBox(width: 120, child: Center(child: Text('Actions', style: TextStyle(fontWeight: FontWeight.bold, color: headerTextColor, fontSize: 13.5)))),
                      ],
                      _vDivider(borderColor),
                      SizedBox(width: 125, child: Padding(padding: const EdgeInsets.symmetric(horizontal: 10), child: Text('Type', style: TextStyle(fontWeight: FontWeight.bold, color: headerTextColor, fontSize: 13.5)))),
                      _vDivider(borderColor),
                      SizedBox(width: 115, child: Padding(padding: const EdgeInsets.symmetric(horizontal: 10), child: Text('Dose', style: TextStyle(fontWeight: FontWeight.bold, color: headerTextColor, fontSize: 13.5)))),
                      _vDivider(borderColor),
                      SizedBox(width: 150, child: Padding(padding: const EdgeInsets.symmetric(horizontal: 10), child: Text('Expiry Date *', style: TextStyle(fontWeight: FontWeight.bold, color: headerTextColor, fontSize: 13.5)))),
                      _vDivider(borderColor),
                      SizedBox(width: 185, child: Padding(padding: const EdgeInsets.symmetric(horizontal: 10), child: Text('Quantity to Add *', style: TextStyle(fontWeight: FontWeight.bold, color: headerTextColor, fontSize: 13.5)))),
                    ],
                  ),
                ),
                Divider(height: 1, color: borderColor),
                // ── Rows (Virtualised ListView.builder for instant 60 FPS performance) ──
                Expanded(
                  child: ListView.separated(
                    itemCount: _filteredList.length,
                    separatorBuilder: (_, index) => Divider(height: 1, color: borderColor),
                    itemBuilder: (context, index) {
                      final item = _filteredList[index];
                      final code = item['code'] as String? ?? 'MED-GEN';
                      final inStockQty = _inStockQuantities[code] ?? 0;
                      final isInStock = inStockQty > 0;
                      final isChecked = _selectedItems[code] ?? false;
                      final expDate = _expiryDates[code] ?? DateTime.now().add(const Duration(days: 365));
                      final bg = isChecked ? rowBgSelected : (index % 2 == 0 ? rowBgNormal : rowBgAlt);

                      return Container(
                        height: 58,
                        color: bg,
                        child: Row(
                          children: [
                            // Select Checkbox
                            SizedBox(
                              width: 110,
                              child: Center(
                                child: Tooltip(
                                  message: isChecked ? 'Deselect item' : 'Select item to add stock',
                                  child: Checkbox(
                                    value: isChecked,
                                    activeColor: _teal,
                                    onChanged: (val) {
                                      setState(() {
                                        final flag = val ?? false;
                                        _selectedItems[code] = flag;
                                        if (flag) {
                                          final currentQty = int.tryParse(_qtyControllers[code]?.text ?? '0') ?? 0;
                                          if (currentQty == 0) {
                                            _qtyControllers[code]?.text = '20';
                                          }
                                        }
                                      });
                                    },
                                  ),
                                ),
                              ),
                            ),
                            _vDivider(borderColor),

                            // Code / Barcode
                            SizedBox(
                              width: 145,
                              child: Padding(
                                padding: const EdgeInsets.symmetric(horizontal: 10),
                                child: Container(
                                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
                                  decoration: BoxDecoration(
                                    color: isDark ? const Color(0xFF0C4A6E) : Colors.grey.shade100,
                                    borderRadius: BorderRadius.circular(6),
                                    border: Border.all(
                                      color: isDark ? const Color(0xFF0284C7) : Colors.grey.shade300,
                                    ),
                                  ),
                                  child: Text(
                                    code,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                      fontFamily: 'monospace',
                                      fontSize: 11.5,
                                      fontWeight: FontWeight.bold,
                                      color: isDark ? const Color(0xFF7DD3FC) : _textDark,
                                    ),
                                  ),
                                ),
                              ),
                            ),
                            _vDivider(borderColor),

                            // Formula Name
                            Expanded(
                              flex: 4,
                              child: Padding(
                                padding: const EdgeInsets.symmetric(horizontal: 10),
                                child: Row(
                                  children: [
                                    Expanded(
                                      child: Text(
                                        item['formula'] as String? ?? item['name'] as String? ?? '',
                                        overflow: TextOverflow.ellipsis,
                                        style: TextStyle(
                                          fontWeight: FontWeight.bold,
                                          color: textColor,
                                          fontSize: 13.5,
                                        ),
                                      ),
                                    ),
                                    if (isInStock)
                                      Container(
                                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                                        margin: const EdgeInsets.only(left: 6),
                                        decoration: BoxDecoration(
                                          color: isDark ? const Color(0xFF065F46) : const Color(0xFFD1FAE5),
                                          borderRadius: BorderRadius.circular(12),
                                          border: Border.all(color: isDark ? const Color(0xFF059669) : const Color(0xFF10B981)),
                                        ),
                                        child: Text(
                                          'In Stock: $inStockQty',
                                          style: TextStyle(
                                            fontSize: 10.5,
                                            color: isDark ? const Color(0xFF34D399) : const Color(0xFF065F46),
                                            fontWeight: FontWeight.bold,
                                          ),
                                        ),
                                      ),
                                  ],
                                ),
                              ),
                            ),
                            if (_canManageProforma) ...[
                              _vDivider(borderColor),
                              // Actions / Audit Column (Edit, Delete, History)
                              SizedBox(
                                width: 120,
                                child: Row(
                                  mainAxisAlignment: MainAxisAlignment.center,
                                  children: [
                                    IconButton(
                                      icon: Icon(Icons.edit_note_rounded, size: 20, color: isDark ? const Color(0xFF38BDF8) : _teal),
                                      tooltip: 'Edit Formula Name (HQ/Chairman)',
                                      onPressed: () => _showEditMedicineNameDialog(item),
                                      padding: EdgeInsets.zero,
                                      constraints: const BoxConstraints(),
                                    ),
                                    const SizedBox(width: 8),
                                    IconButton(
                                      icon: const Icon(Icons.delete_outline_rounded, size: 19, color: _red),
                                      tooltip: 'Delete from Proforma (HQ/Chairman)',
                                      onPressed: () => _showDeleteMedicineDialog(item),
                                      padding: EdgeInsets.zero,
                                      constraints: const BoxConstraints(),
                                    ),
                                    const SizedBox(width: 8),
                                    IconButton(
                                      icon: Icon(Icons.history_rounded, size: 18, color: isDark ? const Color(0xFF94A3B8) : Colors.grey.shade600),
                                      tooltip: 'View Audit Log & Change Reasons',
                                      onPressed: () => _showAuditTrailDialog(item),
                                      padding: EdgeInsets.zero,
                                      constraints: const BoxConstraints(),
                                    ),
                                  ],
                                ),
                              ),
                            ],
                            _vDivider(borderColor),

                            // Type
                            SizedBox(
                              width: 125,
                              child: Padding(
                                padding: const EdgeInsets.symmetric(horizontal: 8),
                                child: Chip(
                                  label: Text(
                                    item['type'] as String? ?? 'Tablet',
                                    style: const TextStyle(fontSize: 11, color: Colors.white, fontWeight: FontWeight.bold),
                                  ),
                                  backgroundColor: _getTypeBadgeColor(item['type'] as String? ?? 'Tablet'),
                                  visualDensity: VisualDensity.compact,
                                  padding: EdgeInsets.zero,
                                ),
                              ),
                            ),
                            _vDivider(borderColor),

                            // Dose
                            SizedBox(
                              width: 115,
                              child: Padding(
                                padding: const EdgeInsets.symmetric(horizontal: 10),
                                child: Text(
                                  item['dose'] as String? ?? '-',
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(color: isDark ? const Color(0xFFCBD5E1) : _textDark, fontSize: 13),
                                ),
                              ),
                            ),
                            _vDivider(borderColor),

                            // Expiry Date
                            SizedBox(
                              width: 150,
                              child: Padding(
                                padding: const EdgeInsets.symmetric(horizontal: 8),
                                child: InkWell(
                                  onTap: () => _pickExpiryDate(code),
                                  borderRadius: BorderRadius.circular(6),
                                  child: Container(
                                    height: 38,
                                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                                    decoration: BoxDecoration(
                                      border: Border.all(color: isDark ? const Color(0xFF38BDF8) : _teal.withValues(alpha: 0.5)),
                                      borderRadius: BorderRadius.circular(6),
                                      color: isDark ? const Color(0xFF334155) : _white,
                                    ),
                                    child: Row(
                                      mainAxisAlignment: MainAxisAlignment.center,
                                      children: [
                                        Icon(Icons.calendar_today, size: 13, color: isDark ? const Color(0xFF38BDF8) : _teal),
                                        const SizedBox(width: 6),
                                        Text(
                                          DateFormat('yyyy-MM-dd').format(expDate),
                                          style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: isDark ? Colors.white : _tealDark),
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                              ),
                            ),
                            _vDivider(borderColor),

                            // Quantity Stepper
                            SizedBox(
                              width: 185,
                              child: Row(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  IconButton(
                                    icon: const Icon(Icons.remove_circle_outline, color: _red, size: 20),
                                    onPressed: () {
                                      final current = int.tryParse(_qtyControllers[code]?.text ?? '0') ?? 0;
                                      if (current > 0) {
                                        _qtyControllers[code]?.text = (current - 1).toString();
                                      }
                                    },
                                  ),
                                  SizedBox(
                                    width: 64,
                                    height: 38,
                                    child: TextField(
                                      controller: _qtyControllers[code],
                                      keyboardType: TextInputType.number,
                                      textAlign: TextAlign.center,
                                      inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                                      style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.bold, color: textColor),
                                      decoration: InputDecoration(
                                        isDense: true,
                                        contentPadding: const EdgeInsets.symmetric(vertical: 8),
                                        border: OutlineInputBorder(borderRadius: BorderRadius.circular(6)),
                                        filled: isDark,
                                        fillColor: isDark ? const Color(0xFF334155) : null,
                                      ),
                                      onChanged: (val) {
                                        final qty = int.tryParse(val) ?? 0;
                                        if (qty > 0 && _selectedItems[code] != true) {
                                          setState(() => _selectedItems[code] = true);
                                        }
                                      },
                                    ),
                                  ),
                                  IconButton(
                                    icon: const Icon(Icons.add_circle_outline, color: _green600, size: 20),
                                    onPressed: () {
                                      final current = int.tryParse(_qtyControllers[code]?.text ?? '0') ?? 0;
                                      _qtyControllers[code]?.text = (current + 1).toString();
                                      if (_selectedItems[code] != true) {
                                        setState(() => _selectedItems[code] = true);
                                      }
                                    },
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _vDivider(Color color) {
    return Container(width: 1, height: double.infinity, color: color);
  }

  Widget _buildEmptyState() {
    final isDark = _isDark;
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(FontAwesomeIcons.magnifyingGlass, size: 48, color: isDark ? const Color(0xFF64748B) : Colors.grey),
          const SizedBox(height: 16),
          Text(
            'No master proforma items matching "${_searchCtrl.text}"',
            style: TextStyle(fontSize: 16, color: isDark ? const Color(0xFFCBD5E1) : _textMid),
          ),
        ],
      ),
    );
  }

  Widget _buildBottomToolbar() {
    final count = _selectedCount;
    final isDark = _isDark;
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF1E293B) : Colors.white,
        border: Border(top: BorderSide(color: isDark ? const Color(0xFF334155) : Colors.grey.shade200)),
        boxShadow: const [
          BoxShadow(color: Color(0x1A000000), blurRadius: 10, offset: Offset(0, -4)),
        ],
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  '$count of ${_proformaMasterList.length} Medicines Selected',
                  style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16, color: isDark ? Colors.white : _tealDark),
                ),
                const SizedBox(height: 2),
                Text(
                  'Showing ${_filteredList.length} of ${_proformaMasterList.length} total catalog medicines • Specifications protected.',
                  style: TextStyle(fontSize: 11.5, color: isDark ? const Color(0xFF94A3B8) : _textMid),
                ),
              ],
            ),
          ),
          const SizedBox(width: 16),
          ElevatedButton.icon(
            style: ElevatedButton.styleFrom(
              backgroundColor: count > 0 ? (isDark ? const Color(0xFF0F766E) : _teal) : Colors.grey,
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
              elevation: 4,
            ),
            onPressed: count > 0 && !_isSavingBatch ? _saveBatchToInventory : null,
            icon: _isSavingBatch
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2),
                  )
                : const Icon(FontAwesomeIcons.floppyDisk, color: Colors.white, size: 16),
            label: Text(
              _isSavingBatch ? 'Adding to Inventory...' : 'Add Selected to Stock',
              style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 14),
            ),
          ),
        ],
      ),
    );
  }

  Color _getTypeBadgeColor(String type) {
    if (_isDark) {
      switch (type.trim().toLowerCase()) {
        case 'tablet':
          return const Color(0xFF1D4ED8);
        case 'capsule':
          return const Color(0xFF7E22CE);
        case 'syrup':
          return const Color(0xFFC2410C);
        case 'injection':
          return const Color(0xFFB91C1C);
        case 'drip':
          return const Color(0xFF0F766E);
        case 'drip set':
          return const Color(0xFF0E7490);
        case 'syringe':
          return const Color(0xFFBE185D);
        case 'cannula':
        case 'needle':
        case 'cannula & needle':
        case 'cannula / needle':
          return const Color(0xFF9D174D);
        case 'nebulization':
          return const Color(0xFF4338CA);
        case 'dressing item':
          return const Color(0xFF334155);
        case 'consumables':
          return const Color(0xFF0F766E);
        default:
          return const Color(0xFF334155);
      }
    }
    switch (type.trim().toLowerCase()) {
      case 'tablet':
        return const Color(0xFF1565C0);
      case 'capsule':
        return const Color(0xFF6A1B9A);
      case 'syrup':
        return const Color(0xFFE65100);
      case 'injection':
        return const Color(0xFFC62828);
      case 'drip':
        return const Color(0xFF00695C);
      case 'drip set':
        return const Color(0xFF00838F);
      case 'syringe':
        return const Color(0xFFAD1457);
      case 'cannula':
      case 'needle':
      case 'cannula & needle':
      case 'cannula / needle':
        return const Color(0xFF7B1FA2);
      case 'nebulization':
        return const Color(0xFF283593);
      case 'dressing item':
        return const Color(0xFF455A64);
      case 'consumables':
        return const Color(0xFF00796B);
      default:
        return const Color(0xFF455A64);
    }
  }
}
