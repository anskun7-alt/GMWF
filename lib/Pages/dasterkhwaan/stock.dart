import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:intl/intl.dart';
import 'package:hive_flutter/hive_flutter.dart';
import '../../services/local_storage_service.dart';
import '../../models/stock_item.dart';
import 'widgets/cook_dialog.dart';

class DasterkhwaanStock extends StatefulWidget {
  static const String routeName = '/dasterkhwaan-stock';
  final String? branchId;

  const DasterkhwaanStock({
    super.key,
    this.branchId,
  });

  @override
  State<DasterkhwaanStock> createState() => _DasterkhwaanStockState();
}

class _DasterkhwaanStockState extends State<DasterkhwaanStock> {
  String? _branchId;
  List<StockItem> _allStockItems = [];
  final TextEditingController _searchController = TextEditingController();
  bool _loading = true;
  int _viewMode = 0; // 0 = Stock Items, 1 = Audit & Deductions Log
  late final String _today = DateFormat('yyyy-MM-dd').format(DateTime.now());

  // Goodwill & Charity Palette
  static const Color _primary = Color(0xFFD97706); // Warm Amber Gold
  static const Color _primaryDark = Color(0xFF92400E); // Deep Mahogany Gold
  static const Color _accent = Color(0xFF059669); // Emerald Blessing
  static const Color _surface = Color(0xFFFFFBEB); // Warm Vanilla Cream

  @override
  void initState() {
    super.initState();
    _loadBranchAndStock();
  }

  Future<void> _loadBranchAndStock() async {
    if (widget.branchId != null && widget.branchId!.isNotEmpty && widget.branchId != 'all') {
      setState(() => _branchId = widget.branchId);
      await _loadStockItems();
      return;
    }
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;
    final branches =
        await FirebaseFirestore.instance.collection('branches').get();
    for (final branch in branches.docs) {
      final doc =
          await branch.reference.collection('users').doc(user.uid).get();
      if (doc.exists) {
        setState(() => _branchId = branch.id);
        await _loadStockItems();
        return;
      }
    }
  }

  Future<void> _loadStockItems() async {
    if (_branchId == null) return;
    setState(() => _loading = true);
    final snapshot = await FirebaseFirestore.instance
        .collection('branches')
        .doc(_branchId)
        .collection('dasterkhwaan_stock')
        .orderBy('name')
        .get();
    setState(() {
      _allStockItems =
          snapshot.docs.map((e) => StockItem.fromMap(e.data(), e.id)).toList();
      _loading = false;
    });
  }

  void _showAddItemDialog() {
    final formKey = GlobalKey<FormState>();
    final nameController = TextEditingController();
    String unit = 'kg';
    const units = [
      'kg','gram','liter','piece','packet','bundle','bunch','handi','plate'
    ];

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) => StatefulBuilder(
        builder: (context, setModal) => Padding(
          padding: EdgeInsets.only(
              bottom: MediaQuery.of(context).viewInsets.bottom),
          child: Container(
            decoration: const BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
            ),
            padding: const EdgeInsets.fromLTRB(20, 12, 20, 32),
            child: Form(
              key: formKey,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Center(
                    child: Container(
                        width: 40,
                        height: 4,
                        margin: const EdgeInsets.only(bottom: 20),
                        decoration: BoxDecoration(
                            color: Colors.grey.shade300,
                            borderRadius: BorderRadius.circular(2))),
                  ),
                  Row(children: [
                    Container(
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                          color: _primary.withValues(alpha: 0.1),
                          borderRadius: BorderRadius.circular(12)),
                      child: Icon(Icons.add_box_rounded,
                          color: _primary, size: 22),
                    ),
                    const SizedBox(width: 12),
                    const Text("Add Charity Stock Item",
                        style: TextStyle(
                            fontSize: 18, fontWeight: FontWeight.w800)),
                  ]),
                  const SizedBox(height: 20),
                  TextFormField(
                    controller: nameController,
                    decoration: _inputDeco(
                        label: "Item Name *",
                        icon: Icons.inventory_2_outlined),
                    textCapitalization: TextCapitalization.words,
                    validator: (v) =>
                        v?.trim().isEmpty ?? true ? "Required" : null,
                  ),
                  const SizedBox(height: 14),
                  DropdownButtonFormField<String>(
                    initialValue: unit,
                    decoration:
                        _inputDeco(label: "Unit", icon: Icons.straighten),
                    items: units
                        .map((e) =>
                            DropdownMenuItem(value: e, child: Text(e)))
                        .toList(),
                    onChanged: (v) => setModal(() => unit = v!),
                  ),
                  const SizedBox(height: 24),
                  Row(children: [
                    Expanded(
                      child: TextButton(
                        onPressed: () => Navigator.pop(context),
                        style: TextButton.styleFrom(
                          padding: const EdgeInsets.symmetric(vertical: 14),
                          shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(14)),
                        ),
                        child: const Text("Cancel",
                            style: TextStyle(color: Colors.grey, fontSize: 15)),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      flex: 2,
                      child: ElevatedButton(
                        style: ElevatedButton.styleFrom(
                          backgroundColor: _primary,
                          foregroundColor: Colors.white,
                          padding: const EdgeInsets.symmetric(vertical: 14),
                          shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(14)),
                          elevation: 0,
                        ),
                        onPressed: () async {
                          if (!formKey.currentState!.validate()) return;
                          final name = nameController.text.trim();
                          if (_allStockItems.any((i) => i.name == name)) {
                            _showSnack("Item already exists", isError: true);
                            return;
                          }
                          final ref = FirebaseFirestore.instance
                              .collection('branches')
                              .doc(_branchId)
                              .collection('dasterkhwaan_stock')
                              .doc(name);
                          await ref.set({
                            'name': name,
                            'quantity': 0.0,
                            'unit': unit,
                            'lastUpdated': FieldValue.serverTimestamp(),
                          });

                          // Log creation
                          await _writeAuditLog(
                            itemName: name,
                            changeType: 'received',
                            qtyChanged: 0.0,
                            prevQty: 0.0,
                            newQty: 0.0,
                            unit: unit,
                            notes: 'Item created in Dasterkhwaan Stock Registry',
                          );

                          if (context.mounted) Navigator.pop(context);
                          await _loadStockItems();
                          _showSnack("$name added to stock");
                        },
                        child: const Text("Add Item",
                            style: TextStyle(
                                fontSize: 15, fontWeight: FontWeight.w700)),
                      ),
                    ),
                  ]),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  void _showAdjustDialog(StockItem item, {required bool isIncrement}) {
    final formKey = GlobalKey<FormState>();
    final qtyController = TextEditingController(text: "1.0");
    final notesController = TextEditingController();
    
    // Default reason
    String reason = isIncrement ? 'received' : 'consumed';
    
    final Map<String, String> reasonLabels = isIncrement
        ? {
            'received': 'Stock Received / Purchased / Donated',
            'audit': 'Audit Adjustment (Count Correction)',
          }
        : {
            'consumed': 'Used in Kitchen (Meal Preparation)',
            'wasted': 'Spoiled / Wasted / Damaged Food',
            'expired': 'Expired Stock',
            'audit': 'Audit Adjustment / Discrepancy',
          };

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) => StatefulBuilder(
        builder: (context, setModal) => Padding(
          padding:
              EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
          child: Container(
            decoration: const BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
            ),
            padding: const EdgeInsets.fromLTRB(20, 12, 20, 32),
            child: Form(
              key: formKey,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Center(
                    child: Container(
                        width: 40,
                        height: 4,
                        margin: const EdgeInsets.only(bottom: 20),
                        decoration: BoxDecoration(
                            color: Colors.grey.shade300,
                            borderRadius: BorderRadius.circular(2))),
                  ),
                  Row(children: [
                    Container(
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                        color: isIncrement
                            ? const Color(0xFF059669).withValues(alpha: 0.12)
                            : Colors.red.withValues(alpha: 0.12),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Icon(
                        isIncrement
                            ? Icons.add_circle_outline_rounded
                            : Icons.remove_circle_outline_rounded,
                        color: isIncrement
                            ? const Color(0xFF059669)
                            : Colors.red.shade600,
                        size: 22,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          isIncrement ? "Add Stock / Received" : "Deduct / Record Usage & Waste",
                          style: const TextStyle(
                              fontSize: 18, fontWeight: FontWeight.w800),
                        ),
                        Text(item.name,
                            style: TextStyle(
                                color: Colors.grey[600], fontSize: 13)),
                      ],
                    ),
                  ]),
                  const SizedBox(height: 14),

                  // Current stock indicator
                  Container(
                    padding: const EdgeInsets.all(14),
                    decoration: BoxDecoration(
                      color: const Color(0xFFFEF3C7),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: const Color(0xFFFDE68A)),
                    ),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text("Current Stock Level",
                            style: TextStyle(
                                color: Colors.amber.shade900, fontSize: 13, fontWeight: FontWeight.w500)),
                        Text(
                          "${item.quantity} ${item.unit}",
                          style: TextStyle(
                              fontWeight: FontWeight.w800,
                              color: Colors.amber.shade900,
                              fontSize: 15),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 16),

                  TextFormField(
                    controller: qtyController,
                    keyboardType:
                        const TextInputType.numberWithOptions(decimal: true),
                    decoration: _inputDeco(
                        label: "Quantity (${item.unit}) *",
                        icon: Icons.scale_rounded),
                    validator: (v) {
                      final parsed = double.tryParse(v ?? '');
                      if (parsed == null || parsed <= 0) return "Must be > 0";
                      if (!isIncrement && parsed > item.quantity) {
                        return "Cannot exceed current stock (${item.quantity} ${item.unit})";
                      }
                      return null;
                    },
                  ),
                  const SizedBox(height: 14),

                  DropdownButtonFormField<String>(
                    initialValue: reason,
                    decoration: _inputDeco(
                        label: "Deduction / Stock Reason *",
                        icon: Icons.category_rounded),
                    items: reasonLabels.entries
                        .map((e) => DropdownMenuItem(
                              value: e.key,
                              child: Text(e.value, style: const TextStyle(fontSize: 13)),
                            ))
                        .toList(),
                    onChanged: (v) => setModal(() => reason = v!),
                  ),
                  const SizedBox(height: 14),

                  TextFormField(
                    controller: notesController,
                    decoration: _inputDeco(
                        label: "Audit Notes / Reason Details (Optional)",
                        icon: Icons.notes_rounded),
                    maxLines: 2,
                  ),
                  const SizedBox(height: 24),

                  Row(children: [
                    Expanded(
                      child: TextButton(
                        onPressed: () => Navigator.pop(context),
                        style: TextButton.styleFrom(
                          padding: const EdgeInsets.symmetric(vertical: 14),
                          shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(14)),
                        ),
                        child: const Text("Cancel",
                            style: TextStyle(color: Colors.grey, fontSize: 15)),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      flex: 2,
                      child: ElevatedButton(
                        style: ElevatedButton.styleFrom(
                          backgroundColor: isIncrement
                              ? const Color(0xFF059669)
                              : Colors.red.shade600,
                          foregroundColor: Colors.white,
                          padding: const EdgeInsets.symmetric(vertical: 14),
                          shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(14)),
                          elevation: 0,
                        ),
                        onPressed: () async {
                          if (!formKey.currentState!.validate()) return;
                          final qty = double.parse(qtyController.text);
                          final delta = isIncrement ? qty : -qty;
                          final notes = notesController.text.trim();

                          await _updateStockWithAudit(
                            item: item,
                            delta: delta,
                            reason: reason,
                            notes: notes,
                          );

                          if (context.mounted) Navigator.pop(context);
                          _showSnack(isIncrement
                              ? "Added $qty ${item.unit} to ${item.name}"
                              : "Deducted $qty ${item.unit} from ${item.name}");
                        },
                        child: Text(
                          isIncrement ? "Add Stock" : "Deduct & Record Log",
                          style: const TextStyle(
                              fontSize: 15, fontWeight: FontWeight.w700),
                        ),
                      ),
                    ),
                  ]),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _updateStockWithAudit({
    required StockItem item,
    required double delta,
    required String reason,
    required String notes,
  }) async {
    if (_branchId == null) return;

    final prevQty = item.quantity;
    final newQty = (prevQty + delta).clamp(0.0, 999999.0);

    final ref = FirebaseFirestore.instance
        .collection('branches')
        .doc(_branchId)
        .collection('dasterkhwaan_stock')
        .doc(item.name);

    await ref.update({
      'quantity': newQty,
      'lastUpdated': FieldValue.serverTimestamp(),
    });

    await _writeAuditLog(
      itemName: item.name,
      changeType: reason,
      qtyChanged: delta,
      prevQty: prevQty,
      newQty: newQty,
      unit: item.unit,
      notes: notes,
    );

    await _loadStockItems();
  }

  Future<void> _writeAuditLog({
    required String itemName,
    required String changeType,
    required double qtyChanged,
    required double prevQty,
    required double newQty,
    required String unit,
    required String notes,
  }) async {
    if (_branchId == null) return;

    final user = FirebaseAuth.instance.currentUser;
    final auditUser = user?.email ?? user?.displayName ?? 'Kitchen Auditor';

    await FirebaseFirestore.instance
        .collection('branches')
        .doc(_branchId)
        .collection('dasterkhwaan_stock_logs')
        .add({
      'itemName': itemName,
      'changeType': changeType,
      'quantityChanged': qtyChanged,
      'previousQuantity': prevQty,
      'newQuantity': newQty,
      'unit': unit,
      'notes': notes,
      'auditedBy': auditUser,
      'timestamp': FieldValue.serverTimestamp(),
    });
  }

  void _showSnack(String msg, {bool isError = false}) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Row(children: [
        Icon(
            isError ? Icons.error_outline : Icons.check_circle_outline,
            color: Colors.white,
            size: 18),
        const SizedBox(width: 10),
        Expanded(
            child: Text(msg,
                style: const TextStyle(fontWeight: FontWeight.w600))),
      ]),
      backgroundColor: isError ? const Color(0xFFB71C1C) : _accent,
      behavior: SnackBarBehavior.floating,
      margin: const EdgeInsets.all(16),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
    ));
  }

  InputDecoration _inputDeco(
      {required String label, required IconData icon}) {
    return InputDecoration(
      labelText: label,
      prefixIcon: Icon(icon, color: _primary, size: 20),
      filled: true,
      fillColor: Colors.white,
      border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: Colors.grey.shade300)),
      enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: Colors.grey.shade300)),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: const BorderSide(color: _primary, width: 2),
      ),
      contentPadding:
          const EdgeInsets.symmetric(vertical: 14, horizontal: 16),
    );
  }

  @override
  Widget build(BuildContext context) {
    final filtered = _searchController.text.isEmpty
        ? _allStockItems
        : _allStockItems
            .where((i) => i.name
                .toLowerCase()
                .contains(_searchController.text.toLowerCase()))
            .toList();

    final lowStock =
        _allStockItems.where((i) => i.quantity <= 2).length;

    return Scaffold(
      backgroundColor: _surface,
      body: CustomScrollView(
        slivers: [
          // Header banner with goodwill & charity palette
          SliverAppBar(
            pinned: true,
            expandedHeight: 120,
            backgroundColor: _primaryDark,
            foregroundColor: Colors.white,
            automaticallyImplyLeading: false,
            elevation: 0,
            flexibleSpace: FlexibleSpaceBar(
              background: Container(
                decoration: const BoxDecoration(
                  gradient: LinearGradient(
                    colors: [_primaryDark, _primary],
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                  ),
                ),
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.end,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Container(
                          padding: const EdgeInsets.all(8),
                          decoration: BoxDecoration(
                            color: Colors.white.withValues(alpha: 0.2),
                            shape: BoxShape.circle,
                          ),
                          child: const Icon(Icons.volunteer_activism_rounded, color: Colors.white, size: 24),
                        ),
                        const SizedBox(width: 12),
                        Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text(
                              "Dasterkhwaan Food Inventory",
                              style: TextStyle(
                                  fontSize: 20,
                                  fontWeight: FontWeight.bold,
                                  color: Colors.white),
                            ),
                            Text(
                              "Charity Kitchen Stock & Manual Audit Deductions · Branch: ${_branchId ?? 'all'}",
                              style: TextStyle(
                                  fontSize: 12,
                                  color: Colors.amber.shade100),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),

          // View Mode Selector (Stock Items vs Audit Logs)
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
              child: Container(
                padding: const EdgeInsets.all(4),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: const Color(0xFFFDE68A)),
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: GestureDetector(
                        onTap: () => setState(() => _viewMode = 0),
                        child: Container(
                          padding: const EdgeInsets.symmetric(vertical: 10),
                          decoration: BoxDecoration(
                            color: _viewMode == 0 ? _primary : Colors.transparent,
                            borderRadius: BorderRadius.circular(12),
                          ),
                          alignment: Alignment.center,
                          child: Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Icon(Icons.inventory_2_rounded,
                                  size: 18,
                                  color: _viewMode == 0 ? Colors.white : Colors.grey.shade700),
                              const SizedBox(width: 8),
                              Text(
                                "Stock Inventory (${_allStockItems.length})",
                                style: TextStyle(
                                  fontWeight: FontWeight.bold,
                                  fontSize: 13,
                                  color: _viewMode == 0 ? Colors.white : Colors.grey.shade700,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                    Expanded(
                      child: GestureDetector(
                        onTap: () => setState(() => _viewMode = 1),
                        child: Container(
                          padding: const EdgeInsets.symmetric(vertical: 10),
                          decoration: BoxDecoration(
                            color: _viewMode == 1 ? _primary : Colors.transparent,
                            borderRadius: BorderRadius.circular(12),
                          ),
                          alignment: Alignment.center,
                          child: Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Icon(Icons.history_rounded,
                                  size: 18,
                                  color: _viewMode == 1 ? Colors.white : Colors.grey.shade700),
                              const SizedBox(width: 8),
                              Text(
                                "Audit & Deductions",
                                style: TextStyle(
                                  fontWeight: FontWeight.bold,
                                  fontSize: 13,
                                  color: _viewMode == 1 ? Colors.white : Colors.grey.shade700,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),

          if (_viewMode == 0) ...[
            // Low stock warning banner
            if (lowStock > 0)
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                    decoration: BoxDecoration(
                      color: Colors.red.shade50,
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: Colors.red.shade200),
                    ),
                    child: Row(
                      children: [
                        Icon(Icons.warning_amber_rounded, color: Colors.red.shade700, size: 20),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text(
                            "$lowStock items low on stock (≤ 2 units remaining). Replenish for Dasterkhwaan meals.",
                            style: TextStyle(
                                color: Colors.red.shade900,
                                fontSize: 12,
                                fontWeight: FontWeight.w600),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),

            // Search bar
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                child: TextField(
                  controller: _searchController,
                  onChanged: (_) => setState(() {}),
                  decoration: InputDecoration(
                    hintText: "Search food stock (e.g. Chawal, Aloo, Ghee)...",
                    prefixIcon:
                        Icon(Icons.search, color: Colors.grey[500], size: 20),
                    suffixIcon: _searchController.text.isNotEmpty
                        ? IconButton(
                            icon: const Icon(Icons.clear, size: 18),
                            onPressed: () {
                              _searchController.clear();
                              setState(() {});
                            })
                        : null,
                    filled: true,
                    fillColor: Colors.white,
                    border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(14),
                        borderSide: BorderSide(color: Colors.grey.shade300)),
                    contentPadding: const EdgeInsets.symmetric(
                        vertical: 12, horizontal: 16),
                  ),
                ),
              ),
            ),

            // Stock Items List
            if (_loading)
              const SliverFillRemaining(
                child: Center(
                    child: CircularProgressIndicator(
                        color: _primary, strokeWidth: 2)),
              )
            else if (filtered.isEmpty)
              SliverFillRemaining(
                child: Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(Icons.inventory_2_outlined,
                          size: 72,
                          color: _primary.withValues(alpha: 0.2)),
                      const SizedBox(height: 12),
                      Text("No items found",
                          style: TextStyle(
                              color: Colors.grey[500], fontSize: 15)),
                    ],
                  ),
                ),
              )
            else
              SliverPadding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 100),
                sliver: SliverList(
                  delegate: SliverChildBuilderDelegate(
                    (_, i) {
                      final item = filtered[i];
                      final isLow = item.quantity <= 2;
                      final updated = item.lastUpdated.toDate();
                      return Container(
                        margin: const EdgeInsets.only(bottom: 10),
                        decoration: BoxDecoration(
                          color: Colors.white,
                          borderRadius: BorderRadius.circular(18),
                          border: Border.all(
                            color: isLow
                                ? Colors.red.withValues(alpha: 0.3)
                                : const Color(0xFFFDE68A),
                          ),
                          boxShadow: [
                            BoxShadow(
                                color: Colors.black.withValues(alpha: 0.04),
                                blurRadius: 8,
                                offset: const Offset(0, 2))
                          ],
                        ),
                        child: Padding(
                          padding: const EdgeInsets.all(14),
                          child: Row(
                            children: [
                              Container(
                                width: 48,
                                height: 48,
                                decoration: BoxDecoration(
                                  color: isLow
                                      ? Colors.red.withValues(alpha: 0.08)
                                      : _primary.withValues(alpha: 0.1),
                                  borderRadius: BorderRadius.circular(14),
                                ),
                                child: Icon(
                                  isLow
                                      ? Icons.warning_rounded
                                      : Icons.restaurant_rounded,
                                  color: isLow
                                      ? Colors.red.shade500
                                      : _primary,
                                  size: 22,
                                ),
                              ),
                              const SizedBox(width: 14),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment:
                                      CrossAxisAlignment.start,
                                  children: [
                                    Text(item.name,
                                        style: const TextStyle(
                                            fontWeight: FontWeight.w800,
                                            fontSize: 14)),
                                    const SizedBox(height: 2),
                                    Text(
                                      "Updated ${DateFormat('dd MMM, hh:mm a').format(updated)}",
                                      style: TextStyle(
                                          color: Colors.grey[500],
                                          fontSize: 11),
                                    ),
                                  ],
                                ),
                              ),
                              Container(
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 10, vertical: 4),
                                decoration: BoxDecoration(
                                  color: isLow
                                      ? Colors.red.withValues(alpha: 0.1)
                                      : const Color(0xFFFEF3C7),
                                  borderRadius: BorderRadius.circular(10),
                                  border: Border.all(
                                    color: isLow
                                        ? Colors.red.withValues(alpha: 0.3)
                                        : const Color(0xFFFDE68A),
                                  ),
                                ),
                                child: Text(
                                  "${item.quantity} ${item.unit}",
                                  style: TextStyle(
                                      fontWeight: FontWeight.w800,
                                      color: isLow
                                          ? Colors.red.shade600
                                          : _primaryDark,
                                      fontSize: 13),
                                ),
                              ),
                              const SizedBox(width: 8),
                              Column(
                                children: [
                                  _ActionBtn(
                                    icon: Icons.add_rounded,
                                    color: _accent,
                                    onTap: () => _showAdjustDialog(item,
                                        isIncrement: true),
                                  ),
                                  const SizedBox(height: 4),
                                  _ActionBtn(
                                    icon: Icons.remove_rounded,
                                    color: Colors.red.shade500,
                                    onTap: () => _showAdjustDialog(item,
                                        isIncrement: false),
                                  ),
                                ],
                              ),
                            ],
                          ),
                        ),
                      );
                    },
                    childCount: filtered.length,
                  ),
                ),
              ),
          ] else ...[
            // Audit Logs View
            _buildAuditLogsSliver(),
          ],
        ],
      ),
      floatingActionButton: _viewMode == 0
          ? Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                FloatingActionButton.extended(
                  heroTag: 'logFood',
                  backgroundColor: kWarning,
                  foregroundColor: Colors.white,
                  onPressed: () => showFoodTypeChooser(
                    context,
                    allStockItems: _allStockItems,
                    stockLoaded: !_loading,
                    branchId: _branchId!,
                    today: _today,
                    onDone: _loadStockItems,
                  ),
                  icon: const Icon(Icons.soup_kitchen_rounded, size: 20),
                  label: const Text("Log Food",
                      style: TextStyle(fontWeight: FontWeight.w800, fontSize: 14)),
                  elevation: 4,
                ),
                const SizedBox(height: 10),
                FloatingActionButton.extended(
                  heroTag: 'addStock',
                  backgroundColor: _primary,
                  foregroundColor: Colors.white,
                  onPressed: _showAddItemDialog,
                  icon: const Icon(Icons.add_rounded, size: 22),
                  label: const Text("Add New Stock",
                      style: TextStyle(fontWeight: FontWeight.w800, fontSize: 14)),
                  elevation: 4,
                ),
              ],
            )
          : null,
    );
  }

  Widget _buildAuditLogsSliver() {
    if (_branchId == null) {
      return const SliverFillRemaining(
        child: Center(child: Text("Select a branch to view audit logs")),
      );
    }

    return ValueListenableBuilder(
      valueListenable: Hive.box(LocalStorageService.auditLogsBox).listenable(),
      builder: (context, Box box, _) {
        final normBranch = _branchId!.toLowerCase().trim();
        final List<Map<String, dynamic>> logs = [];
        for (final val in box.values) {
          if (val is! Map) continue;
          final m = Map<String, dynamic>.from(val);
          final mod = m['module']?.toString().toLowerCase();
          final b = (m['branchId'] ?? m['branchContext'])?.toString().toLowerCase().trim();
          if (mod == 'dasterkhwaan' || mod == 'dasterkhwan' || m['entityType'] == 'stock') {
            if (b == null || b.isEmpty || b == 'all' || b == normBranch) {
              logs.add(m);
            }
          }
        }
        logs.sort((a, b) {
          final tA = a['timestamp']?.toString() ?? a['date']?.toString() ?? '';
          final tB = b['timestamp']?.toString() ?? b['date']?.toString() ?? '';
          return tB.compareTo(tA);
        });
        final docs = logs.take(100).toList();
        if (docs.isEmpty) {
          return SliverFillRemaining(
            child: Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.history_rounded, size: 64, color: Colors.grey.shade400),
                  const SizedBox(height: 12),
                  Text("No stock audit or deduction records found",
                      style: TextStyle(color: Colors.grey.shade600, fontSize: 14)),
                ],
              ),
            ),
          );
        }

        return SliverPadding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 100),
          sliver: SliverList(
            delegate: SliverChildBuilderDelegate(
              (context, index) {
                final data = docs[index] is Map ? (docs[index] as Map<String, dynamic>) : (docs[index] as dynamic).data() as Map<String, dynamic>;
                final itemName = data['itemName'] ?? 'Item';
                final changeType = (data['changeType'] ?? 'consumed').toString();
                final qtyChanged = (data['quantityChanged'] as num? ?? 0.0).toDouble();
                final unit = data['unit'] ?? 'kg';
                final notes = data['notes'] ?? '';
                final auditedBy = data['auditedBy'] ?? 'Staff';
                final dynamic rawTs = data['timestamp'] ?? data['date'] ?? data['createdAt'];
                DateTime ts = DateTime.now();
                if (rawTs is Timestamp) {
                  ts = rawTs.toDate();
                } else if (rawTs is String) {
                  ts = DateTime.tryParse(rawTs) ?? DateTime.now();
                } else if (rawTs is DateTime) {
                  ts = rawTs;
                }

                Color badgeColor;
                String typeLabel;
                IconData typeIcon;

                switch (changeType) {
                  case 'consumed':
                    badgeColor = const Color(0xFF059669);
                    typeLabel = 'Used in Kitchen';
                    typeIcon = Icons.soup_kitchen_rounded;
                    break;
                  case 'wasted':
                    badgeColor = Colors.red.shade700;
                    typeLabel = 'Spoiled / Wasted';
                    typeIcon = Icons.delete_outline_rounded;
                    break;
                  case 'expired':
                    badgeColor = Colors.orange.shade800;
                    typeLabel = 'Expired';
                    typeIcon = Icons.event_busy_rounded;
                    break;
                  case 'received':
                    badgeColor = const Color(0xFF2563EB);
                    typeLabel = 'Received / Added';
                    typeIcon = Icons.add_circle_outline_rounded;
                    break;
                  default:
                    badgeColor = Colors.purple.shade700;
                    typeLabel = 'Audit Adjustment';
                    typeIcon = Icons.rule_rounded;
                    break;
                }

                return Container(
                  margin: const EdgeInsets.only(bottom: 10),
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(color: Colors.grey.shade200),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withValues(alpha: 0.03),
                        blurRadius: 6,
                        offset: const Offset(0, 2),
                      ),
                    ],
                  ),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Container(
                        padding: const EdgeInsets.all(10),
                        decoration: BoxDecoration(
                          color: badgeColor.withValues(alpha: 0.1),
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Icon(typeIcon, color: badgeColor, size: 20),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: [
                                Text(
                                  itemName,
                                  style: const TextStyle(
                                      fontWeight: FontWeight.bold, fontSize: 14),
                                ),
                                Container(
                                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                                  decoration: BoxDecoration(
                                    color: badgeColor.withValues(alpha: 0.12),
                                    borderRadius: BorderRadius.circular(8),
                                  ),
                                  child: Text(
                                    typeLabel,
                                    style: TextStyle(
                                        color: badgeColor,
                                        fontSize: 10,
                                        fontWeight: FontWeight.bold),
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 4),
                            Text(
                              "Changed: ${qtyChanged > 0 ? '+' : ''}$qtyChanged $unit",
                              style: TextStyle(
                                fontWeight: FontWeight.w700,
                                color: qtyChanged < 0 ? Colors.red.shade700 : Colors.green.shade700,
                                fontSize: 13,
                              ),
                            ),
                            if (notes.isNotEmpty) ...[
                              const SizedBox(height: 4),
                              Text(
                                "Notes: $notes",
                                style: TextStyle(
                                    color: Colors.grey.shade700,
                                    fontSize: 11,
                                    fontStyle: FontStyle.italic),
                              ),
                            ],
                            const SizedBox(height: 6),
                            Row(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: [
                                Text(
                                  "Audited by: $auditedBy",
                                  style: TextStyle(color: Colors.grey.shade500, fontSize: 10),
                                ),
                                Text(
                                  DateFormat('dd MMM yyyy, hh:mm a').format(ts),
                                  style: TextStyle(color: Colors.grey.shade500, fontSize: 10),
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                );
              },
              childCount: docs.length,
            ),
          ),
        );
      },
    );
  }
}

class _ActionBtn extends StatelessWidget {
  final IconData icon;
  final Color color;
  final VoidCallback onTap;

  const _ActionBtn(
      {required this.icon, required this.color, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 30,
        height: 30,
        decoration: BoxDecoration(
            color: color.withValues(alpha: 0.1),
            borderRadius: BorderRadius.circular(8)),
        child: Icon(icon, color: color, size: 18),
      ),
    );
  }
}
