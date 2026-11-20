// lib/pages/dispensary/dispensar/universal_proforma_sheet.dart

import 'dart:async';
import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/material.dart';
import 'package:gmwf/design/design_system.dart';
import 'package:gmwf/pages/home/home_module_host.dart';
import 'package:flutter/services.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:intl/intl.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:gmwf/services/local_storage_service.dart';
import 'package:gmwf/services/master_proforma_service.dart';
import 'package:gmwf/services/stock/stock_actions.dart';
import 'package:gmwf/services/stock/stock_pool.dart';
import 'package:gmwf/services/stock/stock_reader.dart';
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
  Color get _teal => context.comfort.brand;
  static const _textDark = SoftPalette.slate800;
  static const _textMid = SoftPalette.slate600;
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

  ValueListenable<Box>? _stockListenable;

  @override
  void initState() {
    super.initState();
    _loadProformaData();
    _searchCtrl.addListener(_filterData);

    // Kept so dispose() removes the listener from the same listenable (see doctor panel).
    if (Hive.isBoxOpen(LocalStorageService.stockBox)) {
      _stockListenable = Hive.box(LocalStorageService.stockBox).listenable()
        ..addListener(_debouncedReloadProforma);
    } else {
      LocalStorageService.ensureBoxOpen(LocalStorageService.stockBox).then((box) {
        if (mounted && box.isOpen) {
          _stockListenable = box.listenable()..addListener(_debouncedReloadProforma);
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
      _stockListenable?.removeListener(_debouncedReloadProforma);
      _stockListenable = null;
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
    final packBarcodeCtrl = TextEditingController();
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

                  // Proforma Barcode (001–999) & Item Code (Separate Fields)
                  Row(
                    children: [
                      Expanded(
                        flex: 2,
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text('Proforma Barcode (001–999) *', style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600, color: isDark ? SoftPalette.sky350 : _teal)),
                            const SizedBox(height: 4),
                            TextField(
                              controller: barcodeCtrl,
                              keyboardType: TextInputType.number,
                              inputFormatters: [
                                FilteringTextInputFormatter.digitsOnly,
                                LengthLimitingTextInputFormatter(3),
                              ],
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
                  const SizedBox(height: 12),
                  Text('Pack Barcode (Optional)', style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600, color: isDark ? SoftPalette.sky350 : _teal)),
                  const SizedBox(height: 4),
                  TextField(
                    controller: packBarcodeCtrl,
                    style: TextStyle(color: isDark ? SoftPalette.gray50 : _textDark, fontSize: 13),
                    decoration: InputDecoration(
                      hintText: 'External / manufacturer barcode (e.g. 8964000123456)',
                      hintStyle: TextStyle(color: isDark ? SoftPalette.slate550 : SoftPalette.gray300, fontSize: 12),
                      filled: true,
                      fillColor: isDark ? SoftPalette.slate900 : SoftPalette.gray50,
                      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
                    ),
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

                final rawBarcodeInput = barcodeCtrl.text.trim();
                final barcode = rawBarcodeInput.isEmpty
                    ? MasterProformaService.getNextRollNumber()
                    : MasterProformaService.normalizeProformaBarcode(rawBarcodeInput);
                if (barcode == null) {
                  AppToast.showSnackBar(context, const SnackBar(content: Text('Proforma Barcode must be a 3-digit number from 001 to 999'), backgroundColor: SoftPalette.red400));
                  return;
                }
                if (MasterProformaService.findExactBarcodeMatch(barcode) != null) {
                  AppToast.showSnackBar(context, SnackBar(content: Text('Proforma Barcode $barcode is already assigned to another medicine'), backgroundColor: SoftPalette.red400));
                  return;
                }
                final packBarcode = packBarcodeCtrl.text.trim();
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
                  if (packBarcode.isNotEmpty) 'packBarcode': packBarcode,
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
                  if (packBarcode.isNotEmpty) 'packBarcode': packBarcode,
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

  /// Queues an audit entry for the cloud inventory_log (Medicine Ledger history). Stock
  /// figures themselves travel as stock-book movements, never through this.
  Future<void> _uploadInventoryLog(String branch, Map<String, dynamic> logData) async {
    try {
      await LocalStorageService.enqueueSync({
        'type': 'save_inventory_log',
        'branchId': branch,
        'data': logData,
      });
    } catch (e) {
      debugPrint('[Proforma] inventory log upload queue failed: $e');
    }
  }

  /// Branch this sheet works on (falls back to this PC's branch).
  String _resolvedBranch() {
    var b = widget.branchId.trim();
    if (b.isEmpty || b.toLowerCase() == 'default' || b.toLowerCase() == 'all') {
      b = LocalStorageService.getActiveBranchId() ?? 'karachi';
    }
    return b;
  }

  /// The real stock pool for [branch]: its active camp (never "all"). Null when the branch
  /// has camps but none is chosen.
  StockPool? _stockPool(String branch) =>
      StockPool.of(branch, CampSessionService.getActiveCamp(branch),
          fallbackCamp: CampSessionService.getActiveCamp(branch));

  void _loadProformaData() {
    final list = MasterProformaService.getAllProformaItems();
    final defaultExp = DateTime.now().add(const Duration(days: 365));
    // Stock book: batches of this PC's pool (branch + active camp).
    final List<Map<String, dynamic>> existingStock = [];
    try {
      final pool = _stockPool(_resolvedBranch());
      if (pool != null) {
        for (final rec in StockReader.batches(pool)) {
          if (rec['status'] == 'deleted') continue;
          existingStock.add(Map<String, dynamic>.from(rec));
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
            colorScheme: ColorScheme.light(
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
      final String activeBranch = _resolvedBranch();
      // Stock book: everything goes into ONE real pool (never "all").
      final pool = _stockPool(activeBranch);
      if (pool == null) {
        if (mounted) {
          setState(() => _isSavingBatch = false);
          AppToast.showSnackBar(context,
            const SnackBar(
              content: Text('Please choose a camp first, then add the medicines to stock.'),
              backgroundColor: _red,
            ),
          );
        }
        return;
      }
      final poolBatches = StockReader.batches(pool);
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

      final String activeCamp = pool.camp ?? '';

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

        // Search this pool's batches for an existing item matching Name/Formula + Type + Dose (or exact barcode)
        final cleanCode = code.trim().toLowerCase();
        final cleanN = (formula.isNotEmpty ? formula : name).trim().toLowerCase().replaceAll(RegExp(r'\s+'), ' ');
        final cleanF = formula.trim().toLowerCase().replaceAll(RegExp(r'\s+'), ' ');
        final cleanT = type.trim().toLowerCase().replaceAll(RegExp(r'\s+'), '');
        final cleanD = dose.trim().toLowerCase().replaceAll(RegExp(r'\s+'), '');

        Map<String, dynamic>? existingStockData;

        for (final val in poolBatches) {
          {
            final map = Map<String, dynamic>.from(val);

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
          final existingDocId = (existingStockData['medicineId'] ?? existingStockData['id'] ?? code).toString();

          // Stock book: ONE restock movement (+qty) on that batch; price/expiry as details.
          // StockActions applies it here and sends it to the LAN server and the cloud.
          await StockActions.restock(
            pool,
            existingDocId,
            qty.toDouble(),
            details: {
              if (price > 0) 'price': price,
              if (exp.isNotEmpty) 'expiryDate': exp,
              'lastUpdated': DateTime.now().toIso8601String(),
            },
            ref: 'proforma restock',
          );
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
          await _uploadInventoryLog(activeBranch, logData);
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
          'price': price,
          'expiryDate': exp,
          'isProforma': true,
          'source': 'Universal Proforma Catalog',
          'addedBy': addedBy,
          'performedByName': addedBy,
          'performedByRole': performedByRole,
          'performedByUid': performedByUid,
          'createdAt': DateTime.now().toIso8601String(),
          'lastUpdated': DateTime.now().toIso8601String(),
        };

        // Stock book: a new batch in this pool with its first stock (the pool stamps
        // branch/camp on the record). A unique opKey, so re-importing the same batch id
        // later (e.g. after it was removed) still adds its stock.
        await StockActions.addBatch(pool, docId, stockData,
            initialQty: qty.toDouble(),
            ref: 'proforma import',
            opKey: 'proforma-${DateTime.now().microsecondsSinceEpoch}');
        // A second line for the same medicine in this import now restocks this batch.
        poolBatches.add({...stockData, 'id': docId, 'medicineId': docId, 'pool': pool.key, 'quantity': qty});
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

        // Save locally to audit logs Hive box, and queue it for the cloud inventory_log
        await LocalStorageService.saveLocalInventoryLog(logData);
        await _uploadInventoryLog(activeBranch, logData);
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
        final dark = Hive.box('app_settings').get('is_dark_mode');
        if (dark != null) return dark == true;
      }
    } catch (_) {}
    if (!mounted) return false;
    return Theme.of(context).brightness == Brightness.dark;
  }

  @override
  Widget build(BuildContext context) {
    final c = context.comfort;
    final hideAppBar = widget.isEmbedded || HomeModuleHost.isModuleRoot(context);

    return Scaffold(
      backgroundColor: c.background,
      appBar: hideAppBar
          ? null
          : AppBar(
              backgroundColor: c.surface,
              foregroundColor: c.textPrimary,
              surfaceTintColor: Colors.transparent,
              elevation: 0,
              automaticallyImplyLeading: false,
              leading: (!widget.isEmbedded && Navigator.canPop(context))
                  ? AppBackButton(color: c.textPrimary)
                  : null,
              iconTheme: IconThemeData(color: c.textPrimary),
              title: Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: c.brandSoft,
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Icon(FontAwesomeIcons.fileExcel, color: c.brand, size: 18),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          'Universal Proforma Sheet',
                          style: TextStyle(
                            color: c.textPrimary,
                            fontWeight: FontWeight.w700,
                            fontSize: 16,
                          ),
                        ),
                        Text(
                          'Master Generic Formula Catalog (Universal)',
                          style: TextStyle(
                            color: c.textSecondary,
                            fontSize: 11.5,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              actions: [
                if (_canManageProforma)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 4),
                    child: ElevatedButton.icon(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: c.brand,
                        foregroundColor: c.onBrand,
                        padding: const EdgeInsets.symmetric(horizontal: 12),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                        elevation: 0,
                      ),
                      onPressed: _showAddMedicineDialog,
                      icon: const Icon(Icons.add_circle_outline, size: 16),
                      label: const Text(
                        'Add Medicine',
                        style: TextStyle(fontWeight: FontWeight.w700, fontSize: 12),
                      ),
                    ),
                  ),
                IconButton(
                  tooltip: 'Auto-Select Items with Qty > 0',
                  icon: Icon(FontAwesomeIcons.listCheck, color: c.brand, size: 17),
                  onPressed: _selectItemsWithQty,
                ),
                const SizedBox(width: 8),
              ],
              bottom: PreferredSize(
                preferredSize: const Size.fromHeight(1),
                child: Divider(height: 1, color: c.border),
              ),
            ),
      body: BlurredUnderDialogBackground(
        child: Column(
          children: [
            // ── Top KPI Row + Search & Filter Bar ────────────────────────────
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

  Widget _buildKpiCard({
    required IconData icon,
    required Color accentColor,
    required Color bgTint,
    required String value,
    required String label,
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

  Widget _buildFilterHeader() {
    final c = context.comfort;
    final isCompact = GBreakpoint.isCompact(context);
    final selectedCount = _selectedCount;

    final card1 = _buildKpiCard(
      icon: Icons.menu_book_rounded,
      accentColor: c.brand,
      bgTint: c.brandSoft,
      value: '${_proformaMasterList.length}',
      label: 'Catalog Formulas',
    );
    final card2 = _buildKpiCard(
      icon: Icons.filter_alt_outlined,
      accentColor: c.info,
      bgTint: c.infoBg,
      value: '${_filteredList.length}',
      label: 'Showing Matching',
    );
    final card3 = _buildKpiCard(
      icon: Icons.inventory_2_outlined,
      accentColor: c.success,
      bgTint: c.successBg,
      value: '${_inStockCodes.length}',
      label: 'Already In Stock',
    );
    final card4 = _buildKpiCard(
      icon: Icons.check_circle_outline_rounded,
      accentColor: selectedCount > 0 ? c.warning : c.textSecondary,
      bgTint: selectedCount > 0 ? c.warningBg : c.surfaceSunken,
      value: '$selectedCount',
      label: 'Selected to Add',
    );

    final searchField = Container(
      height: 38,
      decoration: BoxDecoration(
        color: c.surfaceSunken,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: c.borderStrong),
      ),
      child: TextField(
        controller: _searchCtrl,
        cursorColor: c.brand,
        style: TextStyle(color: c.textPrimary, fontSize: 13),
        decoration: InputDecoration(
          hintText: 'Search Proforma by barcode, item code, name, or formula...',
          hintStyle: TextStyle(color: c.textMuted, fontSize: 12),
          prefixIcon: Icon(Icons.search_rounded, color: c.brand, size: 18),
          suffixIcon: _searchCtrl.text.isNotEmpty
              ? IconButton(
                  icon: Icon(Icons.close_rounded, size: 16, color: c.textSecondary),
                  padding: EdgeInsets.zero,
                  onPressed: () => _searchCtrl.clear(),
                )
              : null,
          border: InputBorder.none,
          contentPadding: const EdgeInsets.symmetric(vertical: 10, horizontal: 12),
        ),
      ),
    );

    final autoSelectBtn = SizedBox(
      height: 38,
      child: OutlinedButton.icon(
        style: OutlinedButton.styleFrom(
          backgroundColor: c.surfaceSunken,
          foregroundColor: c.brand,
          side: BorderSide(color: c.brand.withValues(alpha: 0.45)),
          padding: const EdgeInsets.symmetric(horizontal: 12),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        ),
        onPressed: _selectItemsWithQty,
        icon: const Icon(FontAwesomeIcons.checkDouble, size: 13),
        label: const Text(
          'Auto Select Qty > 0',
          style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700),
        ),
      ),
    );

    final addMedicineBtn = _canManageProforma
        ? SizedBox(
            height: 38,
            child: ElevatedButton.icon(
              style: ElevatedButton.styleFrom(
                backgroundColor: c.brand,
                foregroundColor: c.onBrand,
                elevation: 0,
                padding: const EdgeInsets.symmetric(horizontal: 12),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
              ),
              onPressed: _showAddMedicineDialog,
              icon: const Icon(Icons.add_circle_outline_rounded, size: 16),
              label: const Text(
                'Add Medicine',
                style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700),
              ),
            ),
          )
        : null;

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        // Row 1 — 4 Soft-Tinted KPI Cards
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
          child: isCompact
              ? Column(
                  children: [
                    Row(
                      children: [
                        Expanded(child: card1),
                        const SizedBox(width: 8),
                        Expanded(child: card2),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        Expanded(child: card3),
                        const SizedBox(width: 8),
                        Expanded(child: card4),
                      ],
                    ),
                  ],
                )
              : Row(
                  children: [
                    Expanded(child: card1),
                    const SizedBox(width: 8),
                    Expanded(child: card2),
                    const SizedBox(width: 8),
                    Expanded(child: card3),
                    const SizedBox(width: 8),
                    Expanded(child: card4),
                  ],
                ),
        ),

        // Row 2 — Unified c.surface Filter & Action Card
        Container(
          margin: const EdgeInsets.fromLTRB(12, 0, 12, 8),
          padding: EdgeInsets.symmetric(
            horizontal: isCompact ? 10 : 12,
            vertical: isCompact ? 8 : 10,
          ),
          decoration: BoxDecoration(
            color: c.surface,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: c.border),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (isCompact) ...[
                searchField,
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    autoSelectBtn,
                    if (addMedicineBtn != null) addMedicineBtn,
                  ],
                ),
              ] else
                Row(
                  children: [
                    Expanded(child: searchField),
                    const SizedBox(width: 8),
                    autoSelectBtn,
                    if (addMedicineBtn != null) ...[
                      const SizedBox(width: 8),
                      addMedicineBtn,
                    ],
                  ],
                ),
              const SizedBox(height: 8),
              SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(
                  children: [
                    for (int i = 0; i < _typeCategories.length; i++) ...[
                      if (i > 0) const SizedBox(width: 6),
                      Builder(builder: (_) {
                        final cat = _typeCategories[i];
                        final isSelected = _selectedTypeFilter == cat;
                        return InkWell(
                          onTap: () {
                            setState(() {
                              _selectedTypeFilter = cat;
                              _filterData();
                            });
                          },
                          borderRadius: BorderRadius.circular(20),
                          child: AnimatedContainer(
                            duration: const Duration(milliseconds: 180),
                            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                            decoration: BoxDecoration(
                              color: isSelected ? c.brand : c.surfaceSunken,
                              borderRadius: BorderRadius.circular(20),
                              border: Border.all(color: isSelected ? c.brand : c.border),
                            ),
                            child: Text(
                              cat,
                              style: TextStyle(
                                fontSize: 12,
                                fontWeight: isSelected ? FontWeight.w700 : FontWeight.w600,
                                color: isSelected ? c.onBrand : c.textSecondary,
                              ),
                            ),
                          ),
                        );
                      }),
                    ],
                  ],
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildExcelGridSheet([double? availableHeight]) {
    final c = context.comfort;
    final isDark = _isDark;
    final double tableWidth = _canManageProforma ? 1360 : 1240;

    final headerTextColor = c.textSecondary;
    final borderColor = c.border;

    return Container(
      margin: const EdgeInsets.fromLTRB(12, 0, 12, 8),
      decoration: BoxDecoration(
        color: c.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: c.border),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(14),
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: SizedBox(
            width: tableWidth,
            height: availableHeight != null
                ? (availableHeight - 10).clamp(100.0, double.infinity)
                : null,
            child: Column(
              children: [
                // ── Header Row ──
                Container(
                  height: 42,
                  color: c.surfaceSunken,
                  child: Row(
                    children: [
                      SizedBox(
                        width: 100,
                        child: Row(
                          children: [
                            Checkbox(
                              value: _selectAllChecked,
                              activeColor: c.brand,
                              onChanged: _toggleSelectAll,
                            ),
                            Text(
                              'Select',
                              style: TextStyle(
                                fontWeight: FontWeight.w700,
                                color: headerTextColor,
                                fontSize: 12,
                              ),
                            ),
                          ],
                        ),
                      ),
                      _vDivider(borderColor),
                      SizedBox(
                        width: 85,
                        child: Center(
                          child: Text(
                            'Barcode',
                            style: TextStyle(
                              fontWeight: FontWeight.w700,
                              color: headerTextColor,
                              fontSize: 12,
                            ),
                          ),
                        ),
                      ),
                      _vDivider(borderColor),
                      SizedBox(
                        width: 145,
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 10),
                          child: Text(
                            'Item Code',
                            style: TextStyle(
                              fontWeight: FontWeight.w700,
                              color: headerTextColor,
                              fontSize: 12,
                            ),
                          ),
                        ),
                      ),
                      _vDivider(borderColor),
                      Expanded(
                        flex: 4,
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 10),
                          child: Text(
                            'Medicine Formula (Generic)',
                            style: TextStyle(
                              fontWeight: FontWeight.w700,
                              color: headerTextColor,
                              fontSize: 12,
                            ),
                          ),
                        ),
                      ),
                      if (_canManageProforma) ...[
                        _vDivider(borderColor),
                        SizedBox(
                          width: 120,
                          child: Center(
                            child: Text(
                              'Actions',
                              style: TextStyle(
                                fontWeight: FontWeight.w700,
                                color: headerTextColor,
                                fontSize: 12,
                              ),
                            ),
                          ),
                        ),
                      ],
                      _vDivider(borderColor),
                      SizedBox(
                        width: 125,
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 10),
                          child: Text(
                            'Type',
                            style: TextStyle(
                              fontWeight: FontWeight.w700,
                              color: headerTextColor,
                              fontSize: 12,
                            ),
                          ),
                        ),
                      ),
                      _vDivider(borderColor),
                      SizedBox(
                        width: 115,
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 10),
                          child: Text(
                            'Dose',
                            style: TextStyle(
                              fontWeight: FontWeight.w700,
                              color: headerTextColor,
                              fontSize: 12,
                            ),
                          ),
                        ),
                      ),
                      _vDivider(borderColor),
                      SizedBox(
                        width: 150,
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 10),
                          child: Text(
                            'Expiry Date *',
                            style: TextStyle(
                              fontWeight: FontWeight.w700,
                              color: headerTextColor,
                              fontSize: 12,
                            ),
                          ),
                        ),
                      ),
                      _vDivider(borderColor),
                      SizedBox(
                        width: 185,
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 10),
                          child: Text(
                            'Quantity to Add *',
                            style: TextStyle(
                              fontWeight: FontWeight.w700,
                              color: headerTextColor,
                              fontSize: 12,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                Divider(height: 1, color: c.borderStrong),
                // ── Rows (Virtualised ListView.builder for instant 60 FPS performance) ──
                Expanded(
                  child: ListView.separated(
                    itemCount: _filteredList.length,
                    separatorBuilder: (_, index) => Divider(height: 1, color: borderColor),
                    itemBuilder: (context, index) {
                      final item = _filteredList[index];
                      final code = item['code'] as String? ?? 'MED-GEN';
                      final itemCode = (item['itemCode'] ?? item['code'] ?? '').toString();
                      final barcode = (item['barcode'] ?? item['rollNo'] ?? '').toString().trim().isNotEmpty &&
                              int.tryParse((item['barcode'] ?? item['rollNo'] ?? '').toString().trim()) != null
                          ? (item['barcode'] ?? item['rollNo'] ?? '').toString().trim().padLeft(3, '0')
                          : (item['rollNo'] ?? '').toString().trim().isNotEmpty
                              ? (item['rollNo'] ?? '').toString().trim().padLeft(3, '0')
                              : (index + 1).toString().padLeft(3, '0');
                      final inStockQty = _inStockQuantities[code] ?? 0;
                      final isInStock = inStockQty > 0;
                      final isChecked = _selectedItems[code] ?? false;
                      final expDate = _expiryDates[code] ?? DateTime.now().add(const Duration(days: 365));
                      final medType = item['type'] as String? ?? 'Tablet';
                      final rawTc = _getTypeBadgeColor(medType);
                      final typeColor = isDark ? Color.lerp(rawTc, SoftPalette.gray50, 0.3)! : rawTc;
                      final bg = isChecked
                          ? c.brandSoft.withValues(alpha: isDark ? 0.35 : 0.55)
                          : (index.isEven ? c.surface : c.surfaceSunken.withValues(alpha: 0.4));

                      return Container(
                        height: 54,
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
                                    activeColor: c.brand,
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
                                    color: c.brandSoft,
                                    borderRadius: BorderRadius.circular(6),
                                    border: Border.all(color: c.brand.withValues(alpha: 0.3)),
                                  ),
                                  child: Text(
                                    barcode,
                                    style: TextStyle(
                                      fontFamily: 'monospace',
                                      fontSize: 12,
                                      fontWeight: FontWeight.w700,
                                      color: c.brandStrong,
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
                                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                                  decoration: BoxDecoration(
                                    color: c.surfaceSunken,
                                    borderRadius: BorderRadius.circular(6),
                                    border: Border.all(color: c.border),
                                  ),
                                  child: Text(
                                    itemCode.isNotEmpty ? itemCode : code,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                      fontFamily: 'monospace',
                                      fontSize: 11.5,
                                      fontWeight: FontWeight.w600,
                                      color: c.textSecondary,
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
                                          fontWeight: FontWeight.w700,
                                          color: c.textPrimary,
                                          fontSize: 13.5,
                                        ),
                                      ),
                                    ),
                                    if (isInStock)
                                      Container(
                                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                                        margin: const EdgeInsets.only(left: 6),
                                        decoration: BoxDecoration(
                                          color: c.successBg,
                                          borderRadius: BorderRadius.circular(12),
                                          border: Border.all(color: c.success.withValues(alpha: 0.35)),
                                        ),
                                        child: Text(
                                          'In Stock: $inStockQty',
                                          style: TextStyle(
                                            fontSize: 10.5,
                                            color: c.success,
                                            fontWeight: FontWeight.w700,
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
                                      icon: Icon(Icons.edit_note_rounded, size: 20, color: c.brand),
                                      tooltip: 'Edit Formula Name (HQ/Chairman)',
                                      onPressed: () => _showEditMedicineNameDialog(item),
                                      padding: EdgeInsets.zero,
                                      constraints: const BoxConstraints(),
                                    ),
                                    const SizedBox(width: 8),
                                    IconButton(
                                      icon: Icon(Icons.delete_outline_rounded, size: 19, color: c.danger),
                                      tooltip: 'Delete from Proforma (HQ/Chairman)',
                                      onPressed: () => _showDeleteMedicineDialog(item),
                                      padding: EdgeInsets.zero,
                                      constraints: const BoxConstraints(),
                                    ),
                                    const SizedBox(width: 8),
                                    IconButton(
                                      icon: Icon(Icons.history_rounded, size: 18, color: c.textMuted),
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

                            // Type (Soft-tinted pill)
                            SizedBox(
                              width: 125,
                              child: Padding(
                                padding: const EdgeInsets.symmetric(horizontal: 10),
                                child: Align(
                                  alignment: Alignment.centerLeft,
                                  child: Container(
                                    padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
                                    decoration: BoxDecoration(
                                      color: typeColor.withValues(alpha: isDark ? 0.2 : 0.12),
                                      borderRadius: BorderRadius.circular(8),
                                      border: Border.all(color: typeColor.withValues(alpha: 0.35)),
                                    ),
                                    child: Text(
                                      medType,
                                      overflow: TextOverflow.ellipsis,
                                      style: TextStyle(
                                        fontSize: 11,
                                        color: typeColor,
                                        fontWeight: FontWeight.w700,
                                      ),
                                    ),
                                  ),
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
                                  style: TextStyle(color: c.textSecondary, fontSize: 12.5),
                                ),
                              ),
                            ),
                            _vDivider(borderColor),

                            // Expiry Date
                            SizedBox(
                              width: 150,
                              child: Padding(
                                padding: const EdgeInsets.symmetric(horizontal: 10),
                                child: InkWell(
                                  onTap: () => _pickExpiryDate(code),
                                  borderRadius: BorderRadius.circular(8),
                                  child: Container(
                                    height: 34,
                                    padding: const EdgeInsets.symmetric(horizontal: 8),
                                    decoration: BoxDecoration(
                                      border: Border.all(color: c.borderStrong),
                                      borderRadius: BorderRadius.circular(8),
                                      color: c.surfaceSunken,
                                    ),
                                    child: Row(
                                      mainAxisAlignment: MainAxisAlignment.center,
                                      children: [
                                        Icon(Icons.calendar_today_rounded, size: 13, color: c.brand),
                                        const SizedBox(width: 6),
                                        Text(
                                          DateFormat('yyyy-MM-dd').format(expDate),
                                          style: TextStyle(
                                            fontSize: 12,
                                            fontWeight: FontWeight.w600,
                                            color: c.textPrimary,
                                          ),
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
                                  InkWell(
                                    onTap: () {
                                      final current = int.tryParse(_qtyControllers[code]?.text ?? '0') ?? 0;
                                      if (current > 0) {
                                        _qtyControllers[code]?.text = (current - 1).toString();
                                      }
                                    },
                                    borderRadius: BorderRadius.circular(7),
                                    child: Container(
                                      width: 28,
                                      height: 28,
                                      decoration: BoxDecoration(
                                        color: c.surfaceSunken,
                                        borderRadius: BorderRadius.circular(7),
                                        border: Border.all(color: c.border),
                                      ),
                                      child: Icon(Icons.remove_rounded, size: 16, color: c.textSecondary),
                                    ),
                                  ),
                                  const SizedBox(width: 6),
                                  Container(
                                    width: 58,
                                    height: 32,
                                    alignment: Alignment.center,
                                    decoration: BoxDecoration(
                                      color: c.surfaceSunken,
                                      borderRadius: BorderRadius.circular(8),
                                      border: Border.all(
                                        color: isChecked ? c.brand : c.borderStrong,
                                      ),
                                    ),
                                    child: TextField(
                                      controller: _qtyControllers[code],
                                      keyboardType: TextInputType.number,
                                      textAlign: TextAlign.center,
                                      inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                                      cursorColor: c.brand,
                                      style: TextStyle(
                                        fontSize: 13,
                                        fontWeight: FontWeight.w700,
                                        color: c.textPrimary,
                                      ),
                                      decoration: const InputDecoration(
                                        isDense: true,
                                        border: InputBorder.none,
                                        contentPadding: EdgeInsets.symmetric(vertical: 6),
                                      ),
                                      onChanged: (val) {
                                        final qty = int.tryParse(val) ?? 0;
                                        if (qty > 0 && _selectedItems[code] != true) {
                                          setState(() => _selectedItems[code] = true);
                                        }
                                      },
                                    ),
                                  ),
                                  const SizedBox(width: 6),
                                  InkWell(
                                    onTap: () {
                                      final current = int.tryParse(_qtyControllers[code]?.text ?? '0') ?? 0;
                                      _qtyControllers[code]?.text = (current + 1).toString();
                                      if (_selectedItems[code] != true) {
                                        setState(() => _selectedItems[code] = true);
                                      }
                                    },
                                    borderRadius: BorderRadius.circular(7),
                                    child: Container(
                                      width: 28,
                                      height: 28,
                                      decoration: BoxDecoration(
                                        color: c.brandSoft,
                                        borderRadius: BorderRadius.circular(7),
                                        border: Border.all(color: c.brand.withValues(alpha: 0.3)),
                                      ),
                                      child: Icon(Icons.add_rounded, size: 16, color: c.brand),
                                    ),
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
    final c = context.comfort;
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(FontAwesomeIcons.magnifyingGlass, size: 48, color: c.textMuted),
          const SizedBox(height: 16),
          Text(
            'No master proforma items matching "${_searchCtrl.text}"',
            style: TextStyle(fontSize: 15, color: c.textSecondary, fontWeight: FontWeight.w600),
          ),
        ],
      ),
    );
  }

  Widget _buildBottomToolbar() {
    final c = context.comfort;
    final count = _selectedCount;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: c.surface,
        border: Border(top: BorderSide(color: c.border)),
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
                  style: TextStyle(
                    fontWeight: FontWeight.w700,
                    fontSize: 15,
                    color: c.textPrimary,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  'Showing ${_filteredList.length} of ${_proformaMasterList.length} total catalog medicines • Specifications protected.',
                  style: TextStyle(fontSize: 11.5, color: c.textSecondary),
                ),
              ],
            ),
          ),
          const SizedBox(width: 16),
          ElevatedButton.icon(
            style: ElevatedButton.styleFrom(
              backgroundColor: count > 0 ? c.brand : c.surfaceSunken,
              foregroundColor: count > 0 ? c.onBrand : c.textMuted,
              disabledBackgroundColor: c.surfaceSunken,
              disabledForegroundColor: c.textMuted,
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 13),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
              elevation: 0,
            ),
            onPressed: count > 0 && !_isSavingBatch ? _saveBatchToInventory : null,
            icon: _isSavingBatch
                ? SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(color: c.onBrand, strokeWidth: 2),
                  )
                : const Icon(FontAwesomeIcons.floppyDisk, size: 15),
            label: Text(
              _isSavingBatch ? 'Adding to Inventory...' : 'Add Selected to Stock',
              style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 13.5),
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
