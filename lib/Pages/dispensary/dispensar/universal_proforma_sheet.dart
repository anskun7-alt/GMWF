// lib/pages/dispensary/dispensar/universal_proforma_sheet.dart

import 'dart:async';
import 'package:gmwf/design/tokens/soft_palette.dart';
import 'package:gmwf/design/tokens/comfort_colors.dart';
import 'package:flutter/material.dart';
import 'package:gmwf/design/components/app_toast.dart';
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
import 'package:gmwf/widgets/blurred_dialog_observer.dart';

class UniversalProformaSheetPage extends StatefulWidget {
  final String branchId;
  final bool isDispenser;
  final bool isAdmin;
  final bool isEmbedded;
  final VoidCallback? onBackToInventory;

  const UniversalProformaSheetPage({
    super.key,
    required this.branchId,
    this.isDispenser = true,
    this.isAdmin = false,
    this.isEmbedded = false,
    this.onBackToInventory,
  });

  @override
  State<UniversalProformaSheetPage> createState() => _UniversalProformaSheetPageState();
}

class _UniversalProformaSheetPageState extends State<UniversalProformaSheetPage> {
  // ── Palette ───────────────────────────────────────────────────────────────
  static const _teal = SoftPalette.teal600;
  static const _tealDark = SoftPalette.teal700;
  static const _bg = SoftPalette.gray100;
  static const _white = SoftPalette.gray50;
  static const _headerBg = SoftPalette.teal100m;
  static const _gridBorder = SoftPalette.teal200;
  static const _textDark = SoftPalette.slate800;
  static const _textMid = SoftPalette.slate600;
  static const _textLight = SoftPalette.slate500;
  static const _green600 = SoftPalette.green550;
  static const _red = SoftPalette.red500;

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
          backgroundColor: isDark ? SoftPalette.slate800 : SoftPalette.gray50,
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
                    color: isDark ? SoftPalette.gray50 : _textDark,
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
                    color: isDark ? SoftPalette.gray50A70 : _textDark,
                  ),
                ),
                const SizedBox(height: 14),
                Text(
                  'Mandatory Reason for Deletion *',
                  style: TextStyle(
                    fontSize: 12.5,
                    fontWeight: FontWeight.w600,
                    color: isDark ? SoftPalette.red350 : _red,
                  ),
                ),
                const SizedBox(height: 4),
                TextField(
                  controller: reasonCtrl,
                  maxLines: 2,
                  style: TextStyle(color: isDark ? SoftPalette.gray50 : _textDark, fontSize: 13),
                  decoration: InputDecoration(
                    hintText: 'e.g. Discontinued formulation per Chairman / HQ decision',
                    hintStyle: TextStyle(color: isDark ? SoftPalette.slate550 : SoftPalette.gray300, fontSize: 12.5),
                    filled: true,
                    fillColor: isDark ? SoftPalette.slate900 : SoftPalette.gray50,
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
                foregroundColor: SoftPalette.gray50,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
              ),
              onPressed: () async {
                final reason = reasonCtrl.text.trim();
                if (reason.isEmpty) {
                  AppToast.showSnackBar(context, 
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
                  AppToast.showSnackBar(context, 
                    SnackBar(
                      content: Text('Removed "$name" from Master Proforma Catalog!'),
                      backgroundColor: SoftPalette.teal500,
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
    final nextBarcode = MasterProformaService.getNextRollNumber();
    final barcodeCtrl = TextEditingController(text: nextBarcode);
    final itemCodeCtrl = TextEditingController();
    final reasonCtrl = TextEditingController();
    String selectedType = 'Tablet';

    showDialog(
      context: context,
      builder: (dialogCtx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          backgroundColor: isDark ? SoftPalette.slate800 : SoftPalette.gray50,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          title: Row(
            children: [
              const Icon(Icons.add_circle, color: SoftPalette.teal500, size: 24),
              const SizedBox(width: 10),
              Text(
                'Register Medicine to Master Proforma',
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.bold,
                  color: isDark ? SoftPalette.gray50 : _textDark,
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
                      color: isDark ? SoftPalette.slate350 : SoftPalette.gray500,
                    ),
                  ),
                  const SizedBox(height: 14),

                  // Formula Name
                  Text('Medicine Formula / Generic Name *', style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600, color: isDark ? SoftPalette.sky350 : _teal)),
                  const SizedBox(height: 4),
                  TextField(
                    controller: nameCtrl,
                    style: TextStyle(color: isDark ? SoftPalette.gray50 : _textDark, fontSize: 13.5),
                    decoration: InputDecoration(
                      hintText: 'e.g. Paracetamol + Tramadol (Zaldiar)',
                      hintStyle: TextStyle(color: isDark ? SoftPalette.slate550 : SoftPalette.gray300, fontSize: 13),
                      filled: true,
                      fillColor: isDark ? SoftPalette.slate900 : SoftPalette.gray50,
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
                            Text('Category / Type *', style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600, color: isDark ? SoftPalette.sky350 : _teal)),
                            const SizedBox(height: 4),
                            DropdownButtonFormField<String>(
                              value: selectedType,
                              dropdownColor: isDark ? SoftPalette.slate800 : SoftPalette.gray50,
                              style: TextStyle(color: isDark ? SoftPalette.gray50 : _textDark, fontSize: 13),
                              decoration: InputDecoration(
                                filled: true,
                                fillColor: isDark ? SoftPalette.slate900 : SoftPalette.gray50,
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
                            Text('Dose *', style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600, color: isDark ? SoftPalette.sky350 : _teal)),
                            const SizedBox(height: 4),
                            TextField(
                              controller: doseCtrl,
                              style: TextStyle(color: isDark ? SoftPalette.gray50 : _textDark, fontSize: 13.5),
                              decoration: InputDecoration(
                                hintText: 'e.g. 500 mg, 15 ml',
                                hintStyle: TextStyle(color: isDark ? SoftPalette.slate550 : SoftPalette.gray300, fontSize: 13),
                                filled: true,
                                fillColor: isDark ? SoftPalette.slate900 : SoftPalette.gray50,
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

                  // Barcode & Item Code (Separate Fields)
                  Row(
                    children: [
                      Expanded(
                        flex: 2,
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text('Barcode *', style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600, color: isDark ? SoftPalette.sky350 : _teal)),
                            const SizedBox(height: 4),
                            TextField(
                              controller: barcodeCtrl,
                              style: TextStyle(color: isDark ? SoftPalette.gray50 : _textDark, fontSize: 13),
                              decoration: InputDecoration(
                                hintText: 'e.g. $nextBarcode',
                                hintStyle: TextStyle(color: isDark ? SoftPalette.slate550 : SoftPalette.gray300, fontSize: 12),
                                filled: true,
                                fillColor: isDark ? SoftPalette.slate900 : SoftPalette.gray50,
                                contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                                border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        flex: 3,
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text('Item Code (Optional)', style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600, color: isDark ? SoftPalette.sky350 : _teal)),
                            const SizedBox(height: 4),
                            TextField(
                              controller: itemCodeCtrl,
                              style: TextStyle(color: isDark ? SoftPalette.gray50 : _textDark, fontSize: 13),
                              decoration: InputDecoration(
                                hintText: 'Leave empty to auto-generate',
                                hintStyle: TextStyle(color: isDark ? SoftPalette.slate550 : SoftPalette.gray300, fontSize: 12),
                                filled: true,
                                fillColor: isDark ? SoftPalette.slate900 : SoftPalette.gray50,
                                contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                                border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 14),

                  // Reason for Addition (MANDATORY)
                  Text('Reason for Addition (Mandatory Audit Requirement) *', style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.bold, color: isDark ? SoftPalette.amber300 : SoftPalette.orange500)),
                  const SizedBox(height: 4),
                  TextField(
                    controller: reasonCtrl,
                    maxLines: 2,
                    style: TextStyle(color: isDark ? SoftPalette.gray50 : _textDark, fontSize: 13),
                    decoration: InputDecoration(
                      hintText: 'e.g. Added permanent formula per HQ / Chairman decision',
                      hintStyle: TextStyle(color: isDark ? SoftPalette.slate550 : SoftPalette.gray300, fontSize: 12),
                      filled: true,
                      fillColor: isDark ? SoftPalette.slate900 : SoftPalette.yellow50m,
                      contentPadding: const EdgeInsets.all(10),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(8),
                        borderSide: const BorderSide(color: SoftPalette.amber300),
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
              child: Text('Cancel', style: TextStyle(color: isDark ? SoftPalette.slate350 : SoftPalette.gray500)),
            ),
            ElevatedButton.icon(
              style: ElevatedButton.styleFrom(
                backgroundColor: SoftPalette.teal500,
                foregroundColor: SoftPalette.gray50,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
              ),
              onPressed: () async {
                final name = nameCtrl.text.trim();
                final dose = doseCtrl.text.trim();
                final reason = reasonCtrl.text.trim();
                if (name.isEmpty) {
                  AppToast.showSnackBar(context, const SnackBar(content: Text('Please enter medicine formula/name'), backgroundColor: SoftPalette.red400));
                  return;
                }
                if (reason.isEmpty) {
                  AppToast.showSnackBar(context, const SnackBar(content: Text('Reason for adding to Master Proforma is required for audit recording.'), backgroundColor: SoftPalette.red400));
                  return;
                }

                final uData = _getUserData();
                final performedBy = (uData['username'] ?? uData['name'] ?? uData['displayName'] ?? 'HQ Manager').toString();
                final role = (uData['role'] ?? uData['userRole'] ?? 'HQ Manager').toString();
                final uid = (uData['uid'] ?? uData['id'] ?? FirebaseAuth.instance.currentUser?.uid ?? '').toString();

                final barcode = barcodeCtrl.text.trim().isEmpty ? MasterProformaService.getNextRollNumber() : barcodeCtrl.text.trim().padLeft(3, '0');
                String itemCode = itemCodeCtrl.text.trim();
                if (itemCode.isEmpty) {
                  final initials = name.split(RegExp(r'\s+')).take(3).map((w) => w.isNotEmpty ? w[0].toUpperCase() : '').join();
                  itemCode = 'MED-$initials-${DateTime.now().millisecondsSinceEpoch % 10000}';
                }

                final cleanFormula = MasterProformaService.cleanBrandToFormula(name);

                final auditLog = {
                  'id': 'audit_${DateTime.now().millisecondsSinceEpoch}',
                  'action': 'add_proforma_medicine',
                  'medicineCode': itemCode,
                  'medicineName': cleanFormula,
                  'medicineType': selectedType,
                  'medicineDose': dose,
                  'rollNo': barcode,
                  'barcode': barcode,
                  'itemCode': itemCode,
                  'reason': reason,
                  'performedBy': uid,
                  'performedByName': performedBy,
                  'performedByRole': role,
                  'timestamp': DateTime.now().toIso8601String(),
                  'branchId': widget.branchId,
                };

                final newItem = {
                  'code': itemCode,
                  'itemCode': itemCode,
                  'barcode': barcode,
                  'rollNo': barcode,
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
                  AppToast.showSnackBar(context, 
                    SnackBar(
                      content: Text('Added "$cleanFormula" to Universal Master Proforma with Permanent Audit Log!'),
                      backgroundColor: SoftPalette.teal500,
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
          backgroundColor: isDark ? SoftPalette.slate800 : SoftPalette.gray50,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          title: Row(
            children: [
              const Icon(Icons.edit_note, color: SoftPalette.teal500, size: 24),
              const SizedBox(width: 10),
              Text(
                'Edit Master Proforma Medicine',
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.bold,
                  color: isDark ? SoftPalette.gray50 : _textDark,
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
                      color: isDark ? SoftPalette.slate700 : SoftPalette.gray100,
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Text(code, style: TextStyle(fontFamily: 'monospace', fontSize: 12, fontWeight: FontWeight.bold, color: isDark ? SoftPalette.sky300 : _textDark)),
                  ),
                  const SizedBox(height: 14),

                  // Current values summary
                  Container(
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: isDark ? SoftPalette.slate900 : SoftPalette.gray50,
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: isDark ? SoftPalette.slate700 : SoftPalette.gray150),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('Current Values', style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: isDark ? SoftPalette.slate350 : SoftPalette.gray500)),
                        const SizedBox(height: 4),
                        Row(children: [
                          Chip(label: Text(currentType, style: const TextStyle(fontSize: 10, color: SoftPalette.gray50, fontWeight: FontWeight.bold)), backgroundColor: _getTypeBadgeColor(currentType), visualDensity: VisualDensity.compact, padding: EdgeInsets.zero),
                          const SizedBox(width: 8),
                          Text(currentDose.isNotEmpty ? currentDose : '-', style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: isDark ? SoftPalette.gray50A70 : _textMid)),
                          const SizedBox(width: 8),
                          Expanded(child: Text(currentName, style: TextStyle(fontSize: 12, color: isDark ? SoftPalette.gray50A70 : _textDark), overflow: TextOverflow.ellipsis)),
                        ]),
                      ],
                    ),
                  ),
                  const SizedBox(height: 14),

                  // New Name
                  Text('Formula Name *', style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600, color: isDark ? SoftPalette.sky350 : _teal)),
                  const SizedBox(height: 4),
                  TextField(
                    controller: nameCtrl,
                    style: TextStyle(color: isDark ? SoftPalette.gray50 : _textDark, fontSize: 13.5),
                    decoration: InputDecoration(
                      filled: true,
                      fillColor: isDark ? SoftPalette.slate900 : SoftPalette.gray50,
                      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
                    ),
                  ),
                  const SizedBox(height: 14),

                  // Type Dropdown
                  Text('Type *', style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600, color: isDark ? SoftPalette.sky350 : _teal)),
                  const SizedBox(height: 4),
                  DropdownButtonFormField<String>(
                    value: selectedType,
                    dropdownColor: isDark ? SoftPalette.slate800 : SoftPalette.gray50,
                    style: TextStyle(color: isDark ? SoftPalette.gray50 : _textDark, fontSize: 13),
                    decoration: InputDecoration(
                      filled: true,
                      fillColor: isDark ? SoftPalette.slate900 : SoftPalette.gray50,
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
                  Text('Dose', style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600, color: isDark ? SoftPalette.sky350 : _teal)),
                  const SizedBox(height: 4),
                  TextField(
                    controller: doseCtrl,
                    style: TextStyle(color: isDark ? SoftPalette.gray50 : _textDark, fontSize: 13.5),
                    decoration: InputDecoration(
                      hintText: 'e.g. 500mg, 5ml, Standard',
                      hintStyle: TextStyle(color: isDark ? SoftPalette.slate550 : SoftPalette.gray300, fontSize: 12),
                      filled: true,
                      fillColor: isDark ? SoftPalette.slate900 : SoftPalette.gray50,
                      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
                    ),
                  ),
                  const SizedBox(height: 14),

                  // Reason for Edit (MANDATORY)
                  Text('Reason for Modification (Mandatory Audit) *', style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.bold, color: isDark ? SoftPalette.amber300 : SoftPalette.orange500)),
                  const SizedBox(height: 4),
                  TextField(
                    controller: reasonCtrl,
                    maxLines: 2,
                    style: TextStyle(color: isDark ? SoftPalette.gray50 : _textDark, fontSize: 13),
                    decoration: InputDecoration(
                      hintText: 'e.g. Corrected dose from 250mg to 500mg per HQ directive',
                      hintStyle: TextStyle(color: isDark ? SoftPalette.slate550 : SoftPalette.gray300, fontSize: 12),
                      filled: true,
                      fillColor: isDark ? SoftPalette.slate900 : SoftPalette.yellow50m,
                      contentPadding: const EdgeInsets.all(10),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(8),
                        borderSide: const BorderSide(color: SoftPalette.amber300),
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
              child: Text('Cancel', style: TextStyle(color: isDark ? SoftPalette.slate350 : SoftPalette.gray500)),
            ),
            ElevatedButton.icon(
              style: ElevatedButton.styleFrom(
                backgroundColor: SoftPalette.teal500,
                foregroundColor: SoftPalette.gray50,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
              ),
              onPressed: () async {
                final newName = nameCtrl.text.trim();
                final newDose = doseCtrl.text.trim();
                final newType = selectedType;
                final reason = reasonCtrl.text.trim();
                if (newName.isEmpty) {
                  AppToast.showSnackBar(context, const SnackBar(content: Text('Formula name cannot be empty'), backgroundColor: SoftPalette.red400));
                  return;
                }
                if (reason.isEmpty) {
                  AppToast.showSnackBar(context, const SnackBar(content: Text('Reason for modification is required for audit recording.'), backgroundColor: SoftPalette.red400));
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
                  AppToast.showSnackBar(context, 
                    SnackBar(
                      content: Text('Updated "$currentName" → "$newName" ($newType / $newDose) with Audit Log!'),
                      backgroundColor: SoftPalette.teal500,
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
        backgroundColor: isDark ? SoftPalette.slate800 : SoftPalette.gray50,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Row(
          children: [
            const Icon(Icons.history_rounded, color: SoftPalette.teal500, size: 24),
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
                      color: isDark ? SoftPalette.gray50 : _textDark,
                    ),
                  ),
                  Text(
                    '$name ($code)',
                    style: TextStyle(
                      fontSize: 12,
                      color: isDark ? SoftPalette.slate350 : SoftPalette.gray500,
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
                        Icon(Icons.verified_outlined, size: 36, color: isDark ? SoftPalette.slate550 : SoftPalette.gray300),
                        const SizedBox(height: 10),
                        Text(
                          'Standard Master Seed Item (No edits recorded)',
                          style: TextStyle(fontSize: 13, color: isDark ? SoftPalette.slate350 : SoftPalette.gray500),
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
                                    ? (isDark ? SoftPalette.sky500.withValues(alpha: 0.2) : SoftPalette.slate100)
                                    : (isDark ? SoftPalette.emerald500.withValues(alpha: 0.2) : SoftPalette.green100m),
                                borderRadius: BorderRadius.circular(4),
                              ),
                              child: Text(
                                action.contains('edit') ? '✏️ Name Modified' : '➕ Added to Catalog',
                                style: TextStyle(
                                  fontSize: 11.5,
                                  fontWeight: FontWeight.bold,
                                  color: action.contains('edit')
                                      ? (isDark ? SoftPalette.sky350 : SoftPalette.blue550)
                                      : (isDark ? SoftPalette.emerald300 : SoftPalette.green550),
                                ),
                              ),
                            ),
                            const Spacer(),
                            if (time.isNotEmpty)
                              Text(
                                time.length > 16 ? time.substring(0, 16).replaceAll('T', ' ') : time,
                                style: TextStyle(fontSize: 11, color: isDark ? SoftPalette.slate350 : SoftPalette.gray350),
                              ),
                          ],
                        ),
                        const SizedBox(height: 6),
                        Text(
                          'By: $user ($role)',
                          style: TextStyle(
                            fontSize: 12.5,
                            fontWeight: FontWeight.w600,
                            color: isDark ? SoftPalette.gray50 : _textDark,
                          ),
                        ),
                        if (oldN != null && newN != null) ...[
                          const SizedBox(height: 3),
                          Text(
                            'Changed from "$oldN" to "$newN"',
                            style: TextStyle(fontSize: 12, color: isDark ? SoftPalette.slate200 : SoftPalette.gray550),
                          ),
                        ],
                        const SizedBox(height: 6),
                        Container(
                          padding: const EdgeInsets.all(8),
                          decoration: BoxDecoration(
                            color: isDark ? SoftPalette.slate900 : SoftPalette.yellow50m,
                            borderRadius: BorderRadius.circular(6),
                            border: Border.all(color: isDark ? SoftPalette.slate700 : SoftPalette.yellow150),
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
                                    color: isDark ? SoftPalette.amber200 : SoftPalette.orange600,
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
    final Set<String> seenStockIds = {};
    try {
      if (Hive.isBoxOpen(LocalStorageService.stockBox)) {
        final box = Hive.box(LocalStorageService.stockBox);
        for (final k in box.keys) {
          final val = box.get(k);
          if (val is Map) {
            final m = Map<String, dynamic>.from(val);
            if (m['status'] == 'deleted') continue;

            final kStr = k.toString();
            final rawId = (m['id'] ?? m['medicineId'] ?? m['docId'])?.toString().trim();
            final cleanId = (rawId != null && rawId.isNotEmpty && rawId != 'unknown' && rawId != 'null')
                ? rawId.toLowerCase()
                : (kStr.startsWith('stock:') ? kStr.substring(6).toLowerCase() : kStr.toLowerCase());
            if (seenStockIds.contains(cleanId)) continue;
            seenStockIds.add(cleanId);
            m['id'] = cleanId;

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
    final queryNum = int.tryParse(query);
    setState(() {
      var directMatches = _proformaMasterList.where((item) {
        final name = (item['name'] as String? ?? '').toLowerCase();
        final formula = (item['formula'] as String? ?? '').toLowerCase();
        final code = (item['code'] as String? ?? '').toLowerCase();
        final barcode = (item['barcode'] as String? ?? '').toLowerCase();
        final rollNo = (item['rollNo'] as String? ?? '').toLowerCase();
        final type = item['type'] as String? ?? 'Tablet';

        bool rollMatches = rollNo.contains(query);
        if (!rollMatches && queryNum != null) {
          final rNum = int.tryParse(rollNo);
          if (rNum != null && rNum == queryNum) {
            rollMatches = true;
          }
        }

        final matchesQuery = query.isEmpty ||
            name.contains(query) ||
            formula.contains(query) ||
            code.contains(query) ||
            barcode.contains(query) ||
            rollMatches;

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

      AppToast.showSnackBar(context, 
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
              onPrimary: SoftPalette.gray50,
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
          AppToast.showSnackBar(context, 
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
      AppToast.showSnackBar(context, 
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
        final cleanF = formula.trim().toLowerCase().replaceAll(RegExp(r'\s+'), ' ');
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

            final itemN = MasterProformaService.cleanBrandToFormula((map['name'] ?? '').toString().toLowerCase().trim());
            final itemF = MasterProformaService.cleanBrandToFormula((map['formula'] ?? '').toString().toLowerCase().trim());
            final itemT = (map['type'] ?? map['dosageForm'] ?? '').toString().toLowerCase().trim();
            final itemD = (map['dose'] ?? '').toString().toLowerCase().trim();
            final itemCode = (map['code'] ?? map['barcode'] ?? '').toString().trim().toLowerCase();

            bool isMatch = false;
            if ((itemN == cleanN || itemF == cleanN || itemN == cleanF || (map['name']?.toString().toLowerCase().trim() == cleanN)) &&
                itemT == cleanT && (cleanD.isEmpty || itemD == cleanD || itemD == 'standard')) {
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
            'timestamp': DateTime.now().toIso8601String(),
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

          // LAN Server First routing: a LAN client desk delegates to the LAN server;
          // the LAN Server PC itself (or any offline/standalone PC) enqueues for Firestore sync.
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
          continue;
        }

        final docId = RequestUtils.generateDocId(name, type, dose, exp, campId: activeCamp);
        final barcode = (prof['barcode'] ?? prof['rollNo'] ?? '').toString();
        final itemCode = (prof['itemCode'] ?? prof['code'] ?? '').toString();
        final stockData = {
          'docId': docId,
          'id': docId,
          'medicineId': docId,
          'code': itemCode.isNotEmpty ? itemCode : code,
          'itemCode': itemCode.isNotEmpty ? itemCode : code,
          'barcode': barcode.isNotEmpty ? barcode : code,
          'rollNo': barcode,
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
          'timestamp': DateTime.now().toIso8601String(),
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

        // Offline & LAN Server resilience: enqueue locally (enqueueSync delegates when a LAN client is linked to a LAN server)
        await LocalStorageService.enqueueSync({
          'type': 'add_proforma_stock',
          'branchId': activeBranch,
          'data': stockData,
          'logData': logData,
        });
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
            style: TextStyle(fontSize: 14, color: context.adapt(_textDark)),
          ),
          actions: [
            ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: _teal,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
              ),
              onPressed: () {
                Navigator.of(context, rootNavigator: true).pop(); // Safely dismiss dialog
                if (widget.isEmbedded) {
                  widget.onBackToInventory?.call();
                } else if (Navigator.of(context).canPop()) {
                  Navigator.of(context).pop(true);
                }
              },
              child: const Text('Back to Inventory', style: TextStyle(color: SoftPalette.gray50)),
            ),
          ],
        ),
      );
    } catch (e) {
      if (!mounted) return;
      setState(() => _isSavingBatch = false);
      AppToast.showSnackBar(context, 
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
      backgroundColor: isDark ? SoftPalette.slate900 : _bg,
      appBar: AppBar(
        backgroundColor: isDark ? SoftPalette.slate900 : _tealDark,
        elevation: 2,
        automaticallyImplyLeading: false,
        leading: (!widget.isEmbedded && Navigator.canPop(context))
            ? AppBackButton(color: SoftPalette.gray50)
            : null,
        iconTheme: const IconThemeData(color: SoftPalette.gray50),
        title: Row(
          children: [
            const Icon(FontAwesomeIcons.fileExcel, color: SoftPalette.gray50, size: 22),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text(
                    'Universal Proforma Sheet',
                    style: TextStyle(color: SoftPalette.gray50, fontWeight: FontWeight.bold, fontSize: 18),
                  ),
                  const Text(
                    'Master Generic Formula Catalog (Universal)',
                    style: TextStyle(color: SoftPalette.teal300, fontSize: 11.5, fontWeight: FontWeight.w600),
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
                  backgroundColor: SoftPalette.teal500,
                  foregroundColor: SoftPalette.gray50,
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 0),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                  elevation: 2,
                ),
                onPressed: _showAddMedicineDialog,
                icon: const Icon(Icons.add_circle_outline, size: 16, color: SoftPalette.gray50),
                label: const Text('Add Medicine', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12.5)),
              ),
            ),
          IconButton(
            tooltip: 'Auto-Select Items with Qty > 0',
            icon: const Icon(FontAwesomeIcons.listCheck, color: SoftPalette.gray50, size: 18),
            onPressed: _selectItemsWithQty,
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: BlurredUnderDialogBackground(
        child: Column(
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
      ),
    );
  }

  Widget _buildFilterHeader() {
    final isDark = _isDark;
    return Container(
      color: isDark ? SoftPalette.slate800 : _white,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Column(
        children: [
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _searchCtrl,
                  style: TextStyle(color: isDark ? SoftPalette.gray50 : _textDark),
                  decoration: InputDecoration(
                    hintText: 'Search Proforma by Barcode, Item Code, Name, Formula...',
                    hintStyle: TextStyle(color: isDark ? SoftPalette.slate350 : _textLight),
                    prefixIcon: Icon(Icons.search, color: isDark ? SoftPalette.sky350 : _teal),
                    suffixIcon: _searchCtrl.text.isNotEmpty
                        ? IconButton(
                            icon: Icon(Icons.clear, size: 18, color: isDark ? SoftPalette.slate350 : SoftPalette.gray350),
                            onPressed: () => _searchCtrl.clear(),
                          )
                        : null,
                    filled: true,
                    fillColor: isDark ? SoftPalette.slate900 : _bg,
                    contentPadding: const EdgeInsets.symmetric(vertical: 10, horizontal: 16),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(10),
                      borderSide: BorderSide(color: isDark ? SoftPalette.slate700 : _gridBorder),
                    ),
                    focusedBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(10),
                      borderSide: BorderSide(color: isDark ? SoftPalette.sky350 : _teal, width: 2),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              OutlinedButton.icon(
                style: OutlinedButton.styleFrom(
                  foregroundColor: isDark ? SoftPalette.sky350 : _teal,
                  side: BorderSide(color: isDark ? SoftPalette.sky350 : _teal),
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
                  color: isDark ? SoftPalette.teal550.withValues(alpha: 0.2) : _teal.withValues(alpha: 0.08),
                  borderRadius: BorderRadius.circular(6),
                  border: Border.all(color: isDark ? SoftPalette.teal550 : _teal.withValues(alpha: 0.2)),
                ),
                child: Text(
                  'Total Master Catalog: ${_proformaMasterList.length} Medicines',
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.bold,
                    color: isDark ? SoftPalette.sky350 : _tealDark,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                decoration: BoxDecoration(
                  color: isDark ? SoftPalette.teal750m : SoftPalette.slate100,
                  borderRadius: BorderRadius.circular(6),
                  border: Border.all(color: isDark ? SoftPalette.sky500 : SoftPalette.sky300),
                ),
                child: Text(
                  'Showing: ${_filteredList.length} Matching',
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.bold,
                    color: isDark ? SoftPalette.sky300 : SoftPalette.blue600,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                decoration: BoxDecoration(
                  color: _selectedCount > 0
                      ? (isDark ? SoftPalette.emerald600 : SoftPalette.green100m)
                      : (isDark ? SoftPalette.slate700 : SoftPalette.gray100),
                  borderRadius: BorderRadius.circular(6),
                  border: Border.all(
                    color: _selectedCount > 0
                        ? (isDark ? SoftPalette.emerald350 : SoftPalette.green300)
                        : (isDark ? SoftPalette.slate600 : SoftPalette.gray150),
                  ),
                ),
                child: Text(
                  'Selected: $_selectedCount',
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.bold,
                    color: _selectedCount > 0
                        ? (isDark ? SoftPalette.emerald300 : SoftPalette.green550)
                        : (isDark ? SoftPalette.slate350 : SoftPalette.gray500),
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
                  checkmarkColor: SoftPalette.gray50,
                  label: Text(
                    cat,
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
                      color: isSelected ? SoftPalette.gray50 : (isDark ? SoftPalette.slate200 : _textMid),
                    ),
                  ),
                  selected: isSelected,
                  selectedColor: isDark ? SoftPalette.teal550 : _teal,
                  backgroundColor: isDark ? SoftPalette.slate700 : _bg,
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

    final headerBg = isDark ? SoftPalette.teal550 : _headerBg;
    final headerTextColor = isDark ? SoftPalette.gray50 : _tealDark;
    final rowBgNormal = isDark ? SoftPalette.slate800 : SoftPalette.gray50;
    final rowBgAlt = isDark ? SoftPalette.slate900 : SoftPalette.gray50;
    final rowBgSelected = isDark ? SoftPalette.teal750m : _teal.withValues(alpha: 0.08);
    final borderColor = isDark ? SoftPalette.slate700 : _gridBorder.withValues(alpha: 0.6);
    final textColor = isDark ? SoftPalette.gray50 : _textDark;

    return Container(
      margin: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: rowBgNormal,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: isDark ? SoftPalette.slate700 : _gridBorder),
        boxShadow: const [
          BoxShadow(color: SoftPalette.gray900A6, blurRadius: 6, offset: Offset(0, 3)),
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
                        width: 100,
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
                      SizedBox(width: 85, child: Center(child: Text('Barcode', style: TextStyle(fontWeight: FontWeight.bold, color: headerTextColor, fontSize: 13.5)))),
                      _vDivider(borderColor),
                      SizedBox(width: 145, child: Padding(padding: const EdgeInsets.symmetric(horizontal: 10), child: Text('Item Code', style: TextStyle(fontWeight: FontWeight.bold, color: headerTextColor, fontSize: 13.5)))),
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
                      final itemCode = (item['itemCode'] ?? item['code'] ?? '').toString();
                      final barcode = (item['barcode'] ?? item['rollNo'] ?? '').toString().trim().isNotEmpty && int.tryParse((item['barcode'] ?? item['rollNo'] ?? '').toString().trim()) != null
                          ? (item['barcode'] ?? item['rollNo'] ?? '').toString().trim().padLeft(3, '0')
                          : (item['rollNo'] ?? '').toString().trim().isNotEmpty
                              ? (item['rollNo'] ?? '').toString().trim().padLeft(3, '0')
                              : (index + 1).toString().padLeft(3, '0');
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
                              width: 100,
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

                            // Barcode (Numeric 3-digit badge)
                            SizedBox(
                              width: 85,
                              child: Center(
                                child: Container(
                                  padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 4),
                                  decoration: BoxDecoration(
                                    color: isDark ? SoftPalette.teal550.withValues(alpha: 0.25) : _teal.withValues(alpha: 0.1),
                                    borderRadius: BorderRadius.circular(6),
                                    border: Border.all(
                                      color: isDark ? SoftPalette.sky350.withValues(alpha: 0.4) : _teal.withValues(alpha: 0.3),
                                    ),
                                  ),
                                  child: Text(
                                    barcode,
                                    style: TextStyle(
                                      fontFamily: 'monospace',
                                      fontSize: 12,
                                      fontWeight: FontWeight.bold,
                                      color: isDark ? SoftPalette.sky350 : _teal,
                                    ),
                                  ),
                                ),
                              ),
                            ),
                            _vDivider(borderColor),

                            // Item Code (Alphanumeric formulation code)
                            SizedBox(
                              width: 145,
                              child: Padding(
                                padding: const EdgeInsets.symmetric(horizontal: 10),
                                child: Container(
                                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
                                  decoration: BoxDecoration(
                                    color: isDark ? SoftPalette.sky700 : SoftPalette.gray100,
                                    borderRadius: BorderRadius.circular(6),
                                    border: Border.all(
                                      color: isDark ? SoftPalette.sky500 : SoftPalette.gray150,
                                    ),
                                  ),
                                  child: Text(
                                    itemCode.isNotEmpty ? itemCode : code,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                      fontFamily: 'monospace',
                                      fontSize: 11.5,
                                      fontWeight: FontWeight.bold,
                                      color: isDark ? SoftPalette.sky300 : _textDark,
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
                                          color: isDark ? SoftPalette.emerald600 : SoftPalette.emerald100,
                                          borderRadius: BorderRadius.circular(12),
                                          border: Border.all(color: isDark ? SoftPalette.emerald500 : SoftPalette.emerald350),
                                        ),
                                        child: Text(
                                          'In Stock: $inStockQty',
                                          style: TextStyle(
                                            fontSize: 10.5,
                                            color: isDark ? SoftPalette.emerald300 : SoftPalette.emerald600,
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
                                      icon: Icon(Icons.edit_note_rounded, size: 20, color: isDark ? SoftPalette.sky350 : _teal),
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
                                      icon: Icon(Icons.history_rounded, size: 18, color: isDark ? SoftPalette.slate350 : SoftPalette.gray500),
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
                                    style: const TextStyle(fontSize: 11, color: SoftPalette.gray50, fontWeight: FontWeight.bold),
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
                                  style: TextStyle(color: isDark ? SoftPalette.slate200 : _textDark, fontSize: 13),
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
                                      border: Border.all(color: isDark ? SoftPalette.sky350 : _teal.withValues(alpha: 0.5)),
                                      borderRadius: BorderRadius.circular(6),
                                      color: isDark ? SoftPalette.slate700 : _white,
                                    ),
                                    child: Row(
                                      mainAxisAlignment: MainAxisAlignment.center,
                                      children: [
                                        Icon(Icons.calendar_today, size: 13, color: isDark ? SoftPalette.sky350 : _teal),
                                        const SizedBox(width: 6),
                                        Text(
                                          DateFormat('yyyy-MM-dd').format(expDate),
                                          style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: isDark ? SoftPalette.gray50 : _tealDark),
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
                                        fillColor: isDark ? SoftPalette.slate700 : null,
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
          Icon(FontAwesomeIcons.magnifyingGlass, size: 48, color: isDark ? SoftPalette.slate550 : SoftPalette.gray350),
          const SizedBox(height: 16),
          Text(
            'No master proforma items matching "${_searchCtrl.text}"',
            style: TextStyle(fontSize: 16, color: isDark ? SoftPalette.slate200 : _textMid),
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
        color: isDark ? SoftPalette.slate800 : SoftPalette.gray50,
        border: Border(top: BorderSide(color: isDark ? SoftPalette.slate700 : SoftPalette.gray100)),
        boxShadow: const [
          BoxShadow(color: SoftPalette.gray900A10, blurRadius: 10, offset: Offset(0, -4)),
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
                  style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16, color: isDark ? SoftPalette.gray50 : _tealDark),
                ),
                const SizedBox(height: 2),
                Text(
                  'Showing ${_filteredList.length} of ${_proformaMasterList.length} total catalog medicines • Specifications protected.',
                  style: TextStyle(fontSize: 11.5, color: isDark ? SoftPalette.slate350 : _textMid),
                ),
              ],
            ),
          ),
          const SizedBox(width: 16),
          ElevatedButton.icon(
            style: ElevatedButton.styleFrom(
              backgroundColor: count > 0 ? (isDark ? SoftPalette.teal550 : _teal) : SoftPalette.gray350,
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
              elevation: 4,
            ),
            onPressed: count > 0 && !_isSavingBatch ? _saveBatchToInventory : null,
            icon: _isSavingBatch
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(color: SoftPalette.gray50, strokeWidth: 2),
                  )
                : const Icon(FontAwesomeIcons.floppyDisk, color: SoftPalette.gray50, size: 16),
            label: Text(
              _isSavingBatch ? 'Adding to Inventory...' : 'Add Selected to Stock',
              style: const TextStyle(color: SoftPalette.gray50, fontWeight: FontWeight.bold, fontSize: 14),
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
          return SoftPalette.blue550;
        case 'capsule':
          return SoftPalette.violet550;
        case 'syrup':
          return SoftPalette.orange550;
        case 'injection':
          return SoftPalette.red550;
        case 'drip':
          return SoftPalette.teal550;
        case 'drip set':
          return SoftPalette.sky550;
        case 'syringe':
          return SoftPalette.pink550;
        case 'cannula':
        case 'needle':
        case 'cannula & needle':
        case 'cannula / needle':
          return SoftPalette.pink600;
        case 'nebulization':
          return SoftPalette.indigo600;
        case 'dressing item':
          return SoftPalette.slate700;
        case 'consumables':
          return SoftPalette.teal550;
        default:
          return SoftPalette.slate700;
      }
    }
    switch (type.trim().toLowerCase()) {
      case 'tablet':
        return SoftPalette.blue550;
      case 'capsule':
        return SoftPalette.purple600;
      case 'syrup':
        return SoftPalette.orange400;
      case 'injection':
        return SoftPalette.red550;
      case 'drip':
        return SoftPalette.teal600;
      case 'drip set':
        return SoftPalette.cyan500;
      case 'syringe':
        return SoftPalette.pink550;
      case 'cannula':
      case 'needle':
      case 'cannula & needle':
      case 'cannula / needle':
        return SoftPalette.purple600;
      case 'nebulization':
        return SoftPalette.indigo700;
      case 'dressing item':
        return SoftPalette.slate600;
      case 'consumables':
        return SoftPalette.teal550;
      default:
        return SoftPalette.slate600;
    }
  }
}
