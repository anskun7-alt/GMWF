import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:intl/intl.dart';
import 'package:hive_flutter/hive_flutter.dart';
import '../../services/local_storage_service.dart';
import '../../services/sync_service.dart';

class DasterkhwaanFoodLogScreen extends StatefulWidget {
  final String branchId;
  final String? userName;

  const DasterkhwaanFoodLogScreen({
    super.key,
    required this.branchId,
    this.userName,
  });

  @override
  State<DasterkhwaanFoodLogScreen> createState() => _DasterkhwaanFoodLogScreenState();
}

class _DasterkhwaanFoodLogScreenState extends State<DasterkhwaanFoodLogScreen> {
  String _filterSource = 'All'; // All, Cooked In-House, Outside / Hotel
  DateTime _selectedDate = DateTime.now();
  final DateFormat _dateFmt = DateFormat('yyyy-MM-dd');
  final DateFormat _displayDateFmt = DateFormat('EEE, dd MMM yyyy');
  final DateFormat _timeFmt = DateFormat('hh:mm a');

  @override
  void initState() {
    super.initState();
    _ensureBox();
  }

  Future<void> _ensureBox() async {
    if (!Hive.isBoxOpen(LocalStorageService.dasterkhwaanFoodLogsBox)) {
      await LocalStorageService.openBoxSafe(LocalStorageService.dasterkhwaanFoodLogsBox);
      if (mounted) setState(() {});
    }
  }

  bool get _isDark => Theme.of(context).brightness == Brightness.dark;

  Color get _primaryColor => const Color(0xFF0D9488); // Teal
  Color get _cookedColor => const Color(0xFFE8572A); // Orange / Cooking
  Color get _outsideColor => const Color(0xFF6366F1); // Indigo / Hotel Delivery

  @override
  Widget build(BuildContext context) {
    final isDark = _isDark;
    final dateKey = _dateFmt.format(_selectedDate);

    return Scaffold(
      backgroundColor: isDark ? const Color(0xFF0F172A) : const Color(0xFFF8FAFC),
      appBar: AppBar(
        backgroundColor: isDark ? const Color(0xFF1E293B) : Colors.white,
        elevation: 0,
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Dasterkhwaan Food Log',
              style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.w800,
                color: isDark ? Colors.white : const Color(0xFF0F172A),
              ),
            ),
            Text(
              'Branch: ${widget.branchId.toUpperCase()} • ${_displayDateFmt.format(_selectedDate)}',
              style: TextStyle(
                fontSize: 12,
                color: isDark ? const Color(0xFF94A3B8) : const Color(0xFF64748B),
              ),
            ),
          ],
        ),
        actions: [
          IconButton(
            tooltip: 'Select Date',
            icon: Icon(Icons.calendar_month_rounded, color: isDark ? Colors.white70 : const Color(0xFF334155)),
            onPressed: _pickDate,
          ),
          const SizedBox(width: 8),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        backgroundColor: _cookedColor,
        foregroundColor: Colors.white,
        icon: const Icon(Icons.add_rounded),
        label: const Text('Add Food Entry', style: TextStyle(fontWeight: FontWeight.bold)),
        onPressed: () => _openAddFoodLogSheet(context),
      ),
      body: Column(
        children: [
          _buildFilterBar(isDark),
          Expanded(
            child: !Hive.isBoxOpen(LocalStorageService.dasterkhwaanFoodLogsBox)
                ? const Center(child: CircularProgressIndicator(color: Color(0xFF0D9488)))
                : ValueListenableBuilder<Box>(
                    valueListenable: Hive.box(LocalStorageService.dasterkhwaanFoodLogsBox).listenable(),
                    builder: (context, box, _) {
                      final allItems = <Map<String, dynamic>>[];
                      for (final entry in box.toMap().entries) {
                        if (entry.value is Map) {
                          final data = Map<String, dynamic>.from(entry.value as Map);
                          data['id'] ??= entry.key.toString();
                          if ((data['dateKey']?.toString() ?? '') == dateKey &&
                              (data['branchId']?.toString().toLowerCase() ?? '') == widget.branchId.toLowerCase()) {
                            allItems.add(data);
                          }
                        }
                      }

                      var items = allItems;
                      if (_filterSource == 'Cooked') {
                        items = items.where((i) => i['sourceType'] == 'cooked').toList();
                      } else if (_filterSource == 'Outside') {
                        items = items.where((i) => i['sourceType'] == 'outside').toList();
                      }

                      items.sort((a, b) {
                        final rawA = a['createdAt'] ?? a['timestamp'];
                        final rawB = b['createdAt'] ?? b['timestamp'];
                        final DateTime dtA = rawA is Timestamp ? rawA.toDate() : (rawA is String ? (DateTime.tryParse(rawA) ?? DateTime(1970)) : (rawA is DateTime ? rawA : DateTime(1970)));
                        final DateTime dtB = rawB is Timestamp ? rawB.toDate() : (rawB is String ? (DateTime.tryParse(rawB) ?? DateTime(1970)) : (rawB is DateTime ? rawB : DateTime(1970)));
                        return dtB.compareTo(dtA);
                      });

                      if (items.isEmpty) {
                        return _buildEmptyState(isDark);
                      }

                      return ListView.builder(
                        padding: const EdgeInsets.fromLTRB(16, 8, 16, 80),
                        itemCount: items.length,
                        itemBuilder: (context, index) => _buildFoodLogCard(items[index], isDark),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }

  Widget _buildFilterBar(bool isDark) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF1E293B) : Colors.white,
        border: Border(bottom: BorderSide(color: isDark ? const Color(0xFF334155) : const Color(0xFFE2E8F0))),
      ),
      child: Row(
        children: [
          _filterChip('All Logs', 'All', isDark),
          const SizedBox(width: 8),
          _filterChip('🔥 Cooked In-House', 'Cooked', isDark, activeColor: _cookedColor),
          const SizedBox(width: 8),
          _filterChip('🏨 Hotel / Outside', 'Outside', isDark, activeColor: _outsideColor),
        ],
      ),
    );
  }

  Widget _filterChip(String label, String value, bool isDark, {Color? activeColor}) {
    final selected = _filterSource == value;
    final color = activeColor ?? _primaryColor;
    return InkWell(
      onTap: () => setState(() => _filterSource = value),
      borderRadius: BorderRadius.circular(20),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: selected ? color.withValues(alpha: isDark ? 0.25 : 0.12) : Colors.transparent,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
            color: selected ? color : (isDark ? const Color(0xFF475569) : const Color(0xFFCBD5E1)),
            width: selected ? 1.5 : 1,
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 12,
            fontWeight: selected ? FontWeight.w800 : FontWeight.w500,
            color: selected ? (isDark ? Colors.white : color) : (isDark ? const Color(0xFF94A3B8) : const Color(0xFF64748B)),
          ),
        ),
      ),
    );
  }

  Widget _buildEmptyState(bool isDark) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              padding: const EdgeInsets.all(20),
              decoration: BoxDecoration(
                color: isDark ? const Color(0xFF1E293B) : const Color(0xFFF1F5F9),
                shape: BoxShape.circle,
              ),
              child: Icon(Icons.restaurant_menu_rounded, size: 48, color: isDark ? const Color(0xFF64748B) : const Color(0xFF94A3B8)),
            ),
            const SizedBox(height: 16),
            Text(
              'No food logs found for this date',
              style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.bold,
                color: isDark ? Colors.white : const Color(0xFF1E293B),
              ),
            ),
            const SizedBox(height: 6),
            Text(
              'Tap "Add Food Entry" below to record cooked or hotel food.',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 13, color: isDark ? const Color(0xFF94A3B8) : const Color(0xFF64748B)),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildFoodLogCard(Map<String, dynamic> item, bool isDark) {
    final isCooked = item['sourceType'] == 'cooked';
    final themeColor = isCooked ? _cookedColor : _outsideColor;
    final dishName = item['dishName']?.toString() ?? 'Food Item';
    final quantity = item['quantity']?.toString() ?? '1';
    final mealType = item['mealType']?.toString() ?? 'Lunch';
    final sourceDetail = isCooked
        ? (item['cookName'] != null && item['cookName'].toString().isNotEmpty ? 'Cook: ${item['cookName']}' : 'Cooked In-House')
        : (item['vendorName'] != null && item['vendorName'].toString().isNotEmpty ? 'Hotel/Vendor: ${item['vendorName']}' : 'Outside Sourced');

    final rawTs = item['createdAt'] ?? item['timestamp'];
    final DateTime? ts = rawTs is Timestamp
        ? rawTs.toDate()
        : (rawTs is String
            ? DateTime.tryParse(rawTs)
            : (rawTs is DateTime ? rawTs : null));
    final timeStr = ts != null ? _timeFmt.format(ts) : '';

    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF1E293B) : Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: isDark ? const Color(0xFF334155) : const Color(0xFFE2E8F0)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: isDark ? 0.2 : 0.04),
            blurRadius: 8,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Header Bar
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            decoration: BoxDecoration(
              color: themeColor.withValues(alpha: isDark ? 0.2 : 0.08),
              borderRadius: const BorderRadius.vertical(top: Radius.circular(15)),
            ),
            child: Row(
              children: [
                Icon(
                  isCooked ? Icons.soup_kitchen_rounded : Icons.storefront_rounded,
                  size: 16,
                  color: themeColor,
                ),
                const SizedBox(width: 6),
                Text(
                  isCooked ? 'COOKED IN-HOUSE' : 'HOTEL / OUTSIDE SOURCED',
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 0.5,
                    color: themeColor,
                  ),
                ),
                const Spacer(),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                  decoration: BoxDecoration(
                    color: isDark ? const Color(0xFF0F172A) : Colors.white,
                    borderRadius: BorderRadius.circular(6),
                    border: Border.all(color: themeColor.withValues(alpha: 0.3)),
                  ),
                  child: Text(
                    mealType.toUpperCase(),
                    style: TextStyle(fontSize: 10, fontWeight: FontWeight.bold, color: themeColor),
                  ),
                ),
                if (timeStr.isNotEmpty) ...[
                  const SizedBox(width: 8),
                  Text(
                    timeStr,
                    style: TextStyle(fontSize: 11, color: isDark ? Colors.white60 : const Color(0xFF64748B)),
                  ),
                ],
              ],
            ),
          ),

          // Body Content
          Padding(
            padding: const EdgeInsets.all(14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            dishName,
                            style: TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.w800,
                              color: isDark ? Colors.white : const Color(0xFF0F172A),
                            ),
                          ),
                          const SizedBox(height: 4),
                          Row(
                            children: [
                              Icon(Icons.person_outline_rounded, size: 14, color: isDark ? const Color(0xFF94A3B8) : const Color(0xFF64748B)),
                              const SizedBox(width: 4),
                              Text(
                                sourceDetail,
                                style: TextStyle(
                                  fontSize: 12.5,
                                  fontWeight: FontWeight.w600,
                                  color: isDark ? const Color(0xFFCBD5E1) : const Color(0xFF475569),
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                      decoration: BoxDecoration(
                        color: isDark ? const Color(0xFF0F172A) : const Color(0xFFF1F5F9),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Column(
                        children: [
                          Text('PORTIONS', style: TextStyle(fontSize: 9, fontWeight: FontWeight.bold, color: isDark ? const Color(0xFF64748B) : const Color(0xFF94A3B8))),
                          Text(quantity, style: TextStyle(fontSize: 14, fontWeight: FontWeight.w900, color: themeColor)),
                        ],
                      ),
                    ),
                  ],
                ),

                // Procurement / Cost Details for Outside
                if (!isCooked && item['isPurchased'] == true && item['cost'] != null) ...[
                  const SizedBox(height: 10),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                    decoration: BoxDecoration(
                      color: const Color(0xFF10B981).withValues(alpha: isDark ? 0.15 : 0.08),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: const Color(0xFF10B981).withValues(alpha: 0.3)),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(Icons.payments_outlined, size: 14, color: Color(0xFF10B981)),
                        const SizedBox(width: 6),
                        Text(
                          'Purchased Cost: PKR ${item['cost']}',
                          style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: Color(0xFF10B981)),
                        ),
                      ],
                    ),
                  ),
                ],

                if (item['remarks'] != null && item['remarks'].toString().trim().isNotEmpty) ...[
                  const SizedBox(height: 8),
                  Text(
                    'Note: ${item['remarks']}',
                    style: TextStyle(
                      fontSize: 12,
                      fontStyle: FontStyle.italic,
                      color: isDark ? const Color(0xFF94A3B8) : const Color(0xFF64748B),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _pickDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _selectedDate,
      firstDate: DateTime(2023),
      lastDate: DateTime(2030),
      builder: (context, child) {
        return Theme(
          data: _isDark ? ThemeData.dark() : ThemeData.light(),
          child: child!,
        );
      },
    );
    if (picked != null && picked != _selectedDate) {
      setState(() => _selectedDate = picked);
    }
  }

  void _openAddFoodLogSheet(BuildContext context) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => _AddFoodLogSheet(
        branchId: widget.branchId,
        userName: widget.userName,
        defaultDate: _selectedDate,
      ),
    );
  }
}

class _AddFoodLogSheet extends StatefulWidget {
  final String branchId;
  final String? userName;
  final DateTime defaultDate;

  const _AddFoodLogSheet({
    required this.branchId,
    this.userName,
    required this.defaultDate,
  });

  @override
  State<_AddFoodLogSheet> createState() => _AddFoodLogSheetState();
}

class _AddFoodLogSheetState extends State<_AddFoodLogSheet> {
  int _sourceType = 0; // 0 = Cooked In-House, 1 = Hotel / Outside Sourced

  final _dishCtrl = TextEditingController();
  final _qtyCtrl = TextEditingController();
  final _cookCtrl = TextEditingController();
  final _vendorCtrl = TextEditingController();
  final _costCtrl = TextEditingController();
  final _remarksCtrl = TextEditingController();

  String _mealType = 'Lunch';
  bool _isPurchased = true;
  bool _isSaving = false;

  final DateFormat _dateFmt = DateFormat('yyyy-MM-dd');

  @override
  void dispose() {
    _dishCtrl.dispose();
    _qtyCtrl.dispose();
    _cookCtrl.dispose();
    _vendorCtrl.dispose();
    _costCtrl.dispose();
    _remarksCtrl.dispose();
    super.dispose();
  }

  Future<void> _saveEntry() async {
    final dish = _dishCtrl.text.trim();
    final qty = _qtyCtrl.text.trim();
    if (dish.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Please enter food / dish name')));
      return;
    }
    if (qty.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Please enter portions / quantity')));
      return;
    }

    setState(() => _isSaving = true);
    try {
      final dateKey = _dateFmt.format(widget.defaultDate);
      final logId = 'food_log_${DateTime.now().millisecondsSinceEpoch}';
      final logData = <String, dynamic>{
        'id': logId,
        'branchId': widget.branchId.toLowerCase(),
        'dateKey': dateKey,
        'sourceType': _sourceType == 0 ? 'cooked' : 'outside',
        'dishName': dish,
        'quantity': qty,
        'mealType': _mealType,
        'remarks': _remarksCtrl.text.trim(),
        'loggedBy': widget.userName ?? 'Staff',
        'createdAt': DateTime.now().toIso8601String(),
        'synced': false,
      };

      if (_sourceType == 0) {
        logData['cookName'] = _cookCtrl.text.trim();
      } else {
        logData['vendorName'] = _vendorCtrl.text.trim();
        logData['isPurchased'] = _isPurchased;
        if (_isPurchased && _costCtrl.text.trim().isNotEmpty) {
          logData['cost'] = double.tryParse(_costCtrl.text.trim()) ?? _costCtrl.text.trim();
        }
      }

      final box = await LocalStorageService.openBoxSafe(LocalStorageService.dasterkhwaanFoodLogsBox);
      await box.put(logId, logData);

      // Trigger delta sync / server broadcast
      SyncService().triggerUpload();

      if (mounted) {
        Navigator.pop(context);
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('✅ Food entry logged successfully!'),
            backgroundColor: Color(0xFF10B981),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Error saving log: $e'), backgroundColor: Colors.red));
      }
    } finally {
      if (mounted) setState(() => _isSaving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final bg = isDark ? const Color(0xFF1E293B) : Colors.white;
    final textPrimary = isDark ? Colors.white : const Color(0xFF0F172A);

    return Container(
      decoration: BoxDecoration(
        color: bg,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
      ),
      padding: EdgeInsets.only(
        left: 20,
        right: 20,
        top: 16,
        bottom: MediaQuery.of(context).viewInsets.bottom + 24,
      ),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Center(
              child: Container(
                width: 44,
                height: 4,
                decoration: BoxDecoration(
                  color: isDark ? Colors.white24 : Colors.grey.shade300,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            const SizedBox(height: 16),
            Text('Log Dasterkhwaan Food', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w900, color: textPrimary)),
            const SizedBox(height: 4),
            Text('Record food prepared by cook or received from outside restaurant.', style: TextStyle(fontSize: 12, color: isDark ? Colors.white60 : Colors.grey.shade600)),
            const SizedBox(height: 16),

            // Source Selector Tabs
            Container(
              padding: const EdgeInsets.all(4),
              decoration: BoxDecoration(
                color: isDark ? const Color(0xFF0F172A) : const Color(0xFFF1F5F9),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Row(
                children: [
                  Expanded(
                    child: _sourceTab(0, '🔥 Cooked In-House', const Color(0xFFE8572A), isDark),
                  ),
                  Expanded(
                    child: _sourceTab(1, '🏨 Hotel / Outside', const Color(0xFF6366F1), isDark),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),

            // Meal Type Dropdown
            DropdownButtonFormField<String>(
              initialValue: _mealType,
              dropdownColor: bg,
              decoration: _inputDeco('Meal Type', Icons.access_time_rounded, isDark),
              items: ['Lunch', 'Dinner', 'Iftar', 'Sehri', 'Special Meal']
                  .map((t) => DropdownMenuItem(value: t, child: Text(t, style: TextStyle(color: textPrimary))))
                  .toList(),
              onChanged: (v) => setState(() => _mealType = v ?? 'Lunch'),
            ),
            const SizedBox(height: 12),

            // Dish Name
            TextField(
              controller: _dishCtrl,
              style: TextStyle(color: textPrimary),
              decoration: _inputDeco('Dish / Food Name (e.g. Chicken Biryani)', Icons.restaurant_rounded, isDark),
            ),
            const SizedBox(height: 12),

            // Quantity
            TextField(
              controller: _qtyCtrl,
              style: TextStyle(color: textPrimary),
              decoration: _inputDeco('Quantity / Portions (e.g. 150 Plates, 2 Daigs)', Icons.scale_rounded, isDark),
            ),
            const SizedBox(height: 12),

            // Specific fields based on source
            if (_sourceType == 0) ...[
              TextField(
                controller: _cookCtrl,
                style: TextStyle(color: textPrimary),
                decoration: _inputDeco('Cook / Chef Name', Icons.person_rounded, isDark),
              ),
            ] else ...[
              TextField(
                controller: _vendorCtrl,
                style: TextStyle(color: textPrimary),
                decoration: _inputDeco('Hotel / Restaurant / Donor Name', Icons.storefront_rounded, isDark),
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: ChoiceChip(
                      label: const Text('Purchased / Bought'),
                      selected: _isPurchased,
                      onSelected: (v) => setState(() => _isPurchased = true),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: ChoiceChip(
                      label: const Text('Donated / Free'),
                      selected: !_isPurchased,
                      onSelected: (v) => setState(() => _isPurchased = false),
                    ),
                  ),
                ],
              ),
              if (_isPurchased) ...[
                const SizedBox(height: 12),
                TextField(
                  controller: _costCtrl,
                  keyboardType: TextInputType.number,
                  style: TextStyle(color: textPrimary),
                  decoration: _inputDeco('Total Bill Cost (PKR)', Icons.payments_outlined, isDark),
                ),
              ],
            ],

            const SizedBox(height: 12),
            TextField(
              controller: _remarksCtrl,
              style: TextStyle(color: textPrimary),
              maxLines: 2,
              decoration: _inputDeco('Remarks / Notes (Optional)', Icons.notes_rounded, isDark),
            ),
            const SizedBox(height: 20),

            SizedBox(
              width: double.infinity,
              height: 48,
              child: ElevatedButton(
                style: ElevatedButton.styleFrom(
                  backgroundColor: _sourceType == 0 ? const Color(0xFFE8572A) : const Color(0xFF6366F1),
                  foregroundColor: Colors.white,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                ),
                onPressed: _isSaving ? null : _saveEntry,
                child: _isSaving
                    ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2))
                    : const Text('Save Food Log', style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold)),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _sourceTab(int index, String label, Color color, bool isDark) {
    final active = _sourceType == index;
    return GestureDetector(
      onTap: () => setState(() => _sourceType = index),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        padding: const EdgeInsets.symmetric(vertical: 10),
        decoration: BoxDecoration(
          color: active ? (isDark ? color.withValues(alpha: 0.3) : color) : Colors.transparent,
          borderRadius: BorderRadius.circular(10),
        ),
        child: Center(
          child: Text(
            label,
            style: TextStyle(
              fontSize: 13,
              fontWeight: active ? FontWeight.w800 : FontWeight.w600,
              color: active ? Colors.white : (isDark ? Colors.white60 : Colors.grey.shade700),
            ),
          ),
        ),
      ),
    );
  }

  InputDecoration _inputDeco(String label, IconData icon, bool isDark) {
    return InputDecoration(
      labelText: label,
      labelStyle: TextStyle(fontSize: 13, color: isDark ? Colors.white60 : Colors.grey.shade600),
      prefixIcon: Icon(icon, size: 18, color: isDark ? Colors.white60 : Colors.grey.shade600),
      filled: true,
      fillColor: isDark ? const Color(0xFF0F172A) : const Color(0xFFF8FAFC),
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide(color: isDark ? const Color(0xFF334155) : const Color(0xFFE2E8F0))),
      enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide(color: isDark ? const Color(0xFF334155) : const Color(0xFFE2E8F0))),
      focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: Color(0xFF0D9488), width: 1.8)),
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
    );
  }
}
