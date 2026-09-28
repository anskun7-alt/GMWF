// lib/pages/school/views/school_fee_management_view.dart

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../../../services/image_upload_service.dart';
import '../models/school_fee.dart';
import '../models/school_student.dart';
import '../theme/school_theme.dart';
import '../utils/school_local_storage.dart';
import '../utils/school_auth_helper.dart';
import '../constants/school_constants.dart';
import '../../../design/design_system.dart';

class SchoolFeeManagementView extends StatefulWidget {
  final String branchId;
  final String userName;
  final String userRole;

  const SchoolFeeManagementView({
    super.key,
    required this.branchId,
    required this.userName,
    this.userRole = 'School Admin',
  });

  @override
  State<SchoolFeeManagementView> createState() => _SchoolFeeManagementViewState();
}

class _SchoolFeeManagementViewState extends State<SchoolFeeManagementView> {
  String _selectedGrade = 'All';
  String _selectedSection = 'All';
  String _selectedStatus = 'All';
  String _selectedMonth = DateFormat('MMMM yyyy').format(DateTime.now());
  final TextEditingController _searchCtrl = TextEditingController();

  final List<String> _grades = SchoolConstants.filterGrades;
  final List<String> _sections = ['All', 'A', 'B', 'C'];
  final List<String> _statuses = ['All', 'paid', 'partial', 'unpaid'];

  // Default fee structure per grade
  final Map<String, double> _defaultTuitionFees = SchoolConstants.defaultTuitionFees;

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (SchoolAuthHelper.isTeacher(widget.userRole)) {
      return const SchoolAccessDenied(
        title: 'Confidential Accounts & Fee Records',
        message: 'Student fee management, defaulter records, and institutional collections are confidential administrative data reserved strictly for School Administration and Principal.',
      );
    }
    return StreamBuilder<List<Map<String, dynamic>>>(
      stream: SchoolLocalStorage.streamStudentsCached(widget.branchId),
      builder: (context, studentSnapshot) {
        final rawStudents = studentSnapshot.data ?? [];
        final enrolledStudents = rawStudents
            .map((m) => SchoolStudent.fromMap(m['id'] ?? '', m))
            .where((s) => s.status == 'active')
            .toList();

        return StreamBuilder<List<Map<String, dynamic>>>(
          stream: SchoolLocalStorage.streamFeeRecordsCached(widget.branchId),
          builder: (context, feeSnapshot) {
            final rawFees = feeSnapshot.data ?? [];
            final allFeeRecords = rawFees
                .map((m) => SchoolFeeRecord.fromMap(m['id'] ?? '', m))
                .toList();

            // Create fee records map by student ID for selected month
            final feeMap = <String, SchoolFeeRecord>{};
            for (final f in allFeeRecords) {
              if (f.monthYear.toLowerCase().trim() == _selectedMonth.toLowerCase().trim()) {
                feeMap[f.studentId] = f;
              }
            }

            // Calculate KPI summary stats across all active students for selected month
            double totalExpected = 0;
            double totalCollected = 0;
            int defaultersCount = 0;

            for (final s in enrolledStudents) {
              final existingFee = feeMap[s.id];
              final tuition = existingFee?.tuitionFee ?? (_defaultTuitionFees[s.grade] ?? 3500.0);
              final exam = existingFee?.examFee ?? 0.0;
              final disc = existingFee?.discount ?? 0.0;
              final total = existingFee?.totalAmount ?? ((tuition + exam) - disc);
              final paid = existingFee?.paidAmount ?? 0.0;

              totalExpected += total;
              totalCollected += paid;
              if (paid < total) {
                defaultersCount++;
              }
            }

            final outstandingDues = totalExpected - totalCollected;

            // Apply Filters to student list
            var filteredStudents = enrolledStudents;
            if (_selectedGrade != 'All') {
              filteredStudents = filteredStudents.where((s) => s.grade == _selectedGrade).toList();
            }
            if (_selectedSection != 'All') {
              filteredStudents = filteredStudents.where((s) => s.section == _selectedSection).toList();
            }

            final query = _searchCtrl.text.trim().toLowerCase();
            if (query.isNotEmpty) {
              filteredStudents = filteredStudents.where((s) =>
                s.name.toLowerCase().contains(query) || s.rollNo.toLowerCase().contains(query)
              ).toList();
            }

            if (_selectedStatus != 'All') {
              filteredStudents = filteredStudents.where((s) {
                final fee = feeMap[s.id];
                final status = fee?.status ?? 'unpaid';
                return status.toLowerCase() == _selectedStatus.toLowerCase();
              }).toList();
            }

            return Column(
              children: [
                // KPI Executive Summary Cards
                _buildKPICards(
                  totalExpected: totalExpected,
                  totalCollected: totalCollected,
                  outstandingDues: outstandingDues,
                  defaultersCount: defaultersCount,
                ),

                // Search & Filter Toolbar
                _buildFilterToolbar(),

                const Divider(height: 1),

                // Tabular Fee List
                Expanded(
                  child: filteredStudents.isEmpty
                      ? _buildEmptyState()
                      : ListView.separated(
                          padding: const EdgeInsets.all(16),
                          itemCount: filteredStudents.length,
                          separatorBuilder: (_, __) => const SizedBox(height: 10),
                          itemBuilder: (context, index) {
                            final student = filteredStudents[index];
                            final existingFee = feeMap[student.id] ?? SchoolFeeRecord(
                              id: 'FEE-${student.id}-${_selectedMonth.replaceAll(' ', '_')}',
                              studentId: student.id,
                              studentName: student.name,
                              rollNo: student.rollNo,
                              grade: student.grade,
                              section: student.section,
                              monthYear: _selectedMonth,
                              tuitionFee: _defaultTuitionFees[student.grade] ?? 3500.0,
                              branchId: widget.branchId,
                            );

                            return _buildFeeRowCard(student, existingFee);
                          },
                        ),
                ),
              ],
            );
          },
        );
      },
    );
  }

  Widget _buildKPICards({
    required double totalExpected,
    required double totalCollected,
    required double outstandingDues,
    required int defaultersCount,
  }) {
    final isMobile = GBreakpoint.isMobile(context);

    final cards = [
      _buildSummaryTile(
        label: 'Total Expected Fee',
        value: 'PKR ${totalExpected.toStringAsFixed(0)}',
        icon: Icons.account_balance_wallet_rounded,
        color: const Color(0xFF6366F1),
        bgColor: const Color(0xFFEEF2FF),
      ),
      _buildSummaryTile(
        label: 'Total Fee Collected',
        value: 'PKR ${totalCollected.toStringAsFixed(0)}',
        icon: Icons.payments_rounded,
        color: const Color(0xFF10B981),
        bgColor: const Color(0xFFD1FAE5),
      ),
      _buildSummaryTile(
        label: 'Outstanding Dues',
        value: 'PKR ${outstandingDues.toStringAsFixed(0)}',
        icon: Icons.pending_actions_rounded,
        color: const Color(0xFFEF4444),
        bgColor: const Color(0xFFFEE2E2),
      ),
      _buildSummaryTile(
        label: 'Defaulters Count',
        value: '$defaultersCount Students',
        icon: Icons.person_off_rounded,
        color: const Color(0xFFF59E0B),
        bgColor: const Color(0xFFFEF3C7),
      ),
    ];

    if (isMobile) {
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        color: Colors.white,
        child: LayoutBuilder(
          builder: (context, constraints) {
            final cardWidth = (constraints.maxWidth - 10) / 2;
            return Wrap(
              spacing: 10,
              runSpacing: 10,
              children: cards.map((c) => SizedBox(width: cardWidth, child: c)).toList(),
            );
          },
        ),
      );
    }

    return Container(
      padding: const EdgeInsets.all(16),
      color: Colors.white,
      child: Row(
        children: cards.map((c) => Expanded(child: Padding(padding: const EdgeInsets.symmetric(horizontal: 6), child: c))).toList(),
      ),
    );
  }

  Widget _buildSummaryTile({
    required String label,
    required String value,
    required IconData icon,
    required Color color,
    required Color bgColor,
  }) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: bgColor,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: color.withValues(alpha: 0.2)),
      ),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(10),
            ),
            child: Icon(icon, color: color, size: 20),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(label, style: TextStyle(color: Colors.grey.shade700, fontSize: 11, fontWeight: FontWeight.w500), overflow: TextOverflow.ellipsis),
                const SizedBox(height: 2),
                Text(value, style: TextStyle(color: color, fontSize: 14, fontWeight: FontWeight.bold), overflow: TextOverflow.ellipsis),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildFilterToolbar() {
    final isMobile = GBreakpoint.isCompact(context);

    if (isMobile) {
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        color: const Color(0xFFF8FAFC),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              controller: _searchCtrl,
              onChanged: (_) => setState(() {}),
              decoration: InputDecoration(
                hintText: 'Search student by name or roll number...',
                prefixIcon: const Icon(Icons.search_rounded, color: Color(0xFF6366F1), size: 20),
                filled: true,
                fillColor: Colors.white,
                contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: const BorderSide(color: Color(0xFFE2E8F0))),
              ),
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                _buildDropdown('Class:', _selectedGrade, _grades, (v) => setState(() => _selectedGrade = v!)),
                _buildDropdown('Section:', _selectedSection, _sections, (v) => setState(() => _selectedSection = v!)),
                _buildDropdown('Status:', _selectedStatus, _statuses, (v) => setState(() => _selectedStatus = v!)),
                ElevatedButton.icon(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF10B981),
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                  ),
                  icon: const Icon(Icons.download_rounded, size: 16),
                  label: const Text('Export Fee Report', style: TextStyle(fontSize: 12)),
                  onPressed: _exportFeeReport,
                ),
              ],
            ),
          ],
        ),
      );
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      color: const Color(0xFFF8FAFC),
      child: Row(
        children: [
          // Search box
          Expanded(
            flex: 3,
            child: TextField(
              controller: _searchCtrl,
              onChanged: (_) => setState(() {}),
              decoration: InputDecoration(
                hintText: 'Search student by name or roll number...',
                prefixIcon: const Icon(Icons.search_rounded, color: Color(0xFF6366F1)),
                filled: true,
                fillColor: Colors.white,
                contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: const BorderSide(color: Color(0xFFE2E8F0))),
              ),
            ),
          ),
          const SizedBox(width: 12),

          // Grade Dropdown
          _buildDropdown('Class:', _selectedGrade, _grades, (v) => setState(() => _selectedGrade = v!)),
          const SizedBox(width: 10),

          // Section Dropdown
          _buildDropdown('Section:', _selectedSection, _sections, (v) => setState(() => _selectedSection = v!)),
          const SizedBox(width: 10),

          // Status Dropdown
          _buildDropdown('Status:', _selectedStatus, _statuses, (v) => setState(() => _selectedStatus = v!)),
          const SizedBox(width: 12),

          // Export Defaulters Button
          ElevatedButton.icon(
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFF10B981),
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
            ),
            icon: const Icon(Icons.download_rounded, size: 18),
            label: const Text('Export Fee Report'),
            onPressed: _exportFeeReport,
          ),
        ],
      ),
    );
  }

  Widget _buildDropdown(String label, String value, List<String> items, ValueChanged<String?> onChanged) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: const Color(0xFFCBD5E1)),
      ),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<String>(
          value: value,
          style: const TextStyle(color: Color(0xFF1E293B), fontWeight: FontWeight.bold, fontSize: 13),
          items: items.map((i) => DropdownMenuItem(value: i, child: Text('$label $i'))).toList(),
          onChanged: onChanged,
        ),
      ),
    );
  }

  Widget _buildFeeRowCard(SchoolStudent student, SchoolFeeRecord fee) {
    Color statusColor;
    String statusLabel;

    if (fee.status == 'paid') {
      statusColor = const Color(0xFF10B981);
      statusLabel = 'Paid';
    } else if (fee.status == 'partial') {
      statusColor = const Color(0xFFF59E0B);
      statusLabel = 'Partial (Bal: PKR ${fee.remainingBalance.toStringAsFixed(0)})';
    } else {
      statusColor = const Color(0xFFEF4444);
      statusLabel = 'Unpaid';
    }

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: const Color(0xFFE2E8F0)),
      ),
      child: Row(
        children: [
          // Student Profile Avatar
          Builder(
            builder: (context) {
              final bytes = ImageUploadService.decodeBase64ToBytes(student.photoUrl);
              if (bytes != null && bytes.isNotEmpty) {
                return CircleAvatar(
                  radius: 20,
                  backgroundColor: const Color(0xFF6366F1).withValues(alpha: 0.1),
                  backgroundImage: MemoryImage(bytes),
                );
              } else if (student.photoUrl.startsWith('http')) {
                return CircleAvatar(
                  radius: 20,
                  backgroundColor: const Color(0xFF6366F1).withValues(alpha: 0.1),
                  backgroundImage: NetworkImage(student.photoUrl),
                );
              }
              return CircleAvatar(
                backgroundColor: const Color(0xFF6366F1).withValues(alpha: 0.1),
                child: Text(student.rollNo.isNotEmpty ? student.rollNo : '#', style: const TextStyle(color: Color(0xFF6366F1), fontWeight: FontWeight.bold)),
              );
            },
          ),
          const SizedBox(width: 14),

          Expanded(
            flex: 3,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(student.name, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15, color: Color(0xFF1E293B))),
                const SizedBox(height: 2),
                Text('Class: ${student.grade} - Section ${student.section} • Guardian: ${student.guardianName}', style: const TextStyle(color: Color(0xFF64748B), fontSize: 12)),
              ],
            ),
          ),

          Expanded(
            flex: 2,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Total Due: PKR ${fee.totalAmount.toStringAsFixed(0)}', style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
                Text('Paid: PKR ${fee.paidAmount.toStringAsFixed(0)}', style: const TextStyle(color: Color(0xFF10B981), fontSize: 12)),
              ],
            ),
          ),

          // Status Badge
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            decoration: BoxDecoration(
              color: statusColor.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: statusColor.withValues(alpha: 0.4)),
            ),
            child: Text(
              statusLabel,
              style: TextStyle(color: statusColor, fontWeight: FontWeight.bold, fontSize: 12),
            ),
          ),

          const SizedBox(width: 16),

          // Record Payment Button
          ElevatedButton.icon(
            style: ElevatedButton.styleFrom(
              backgroundColor: SchoolTheme.accent,
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
            ),
            icon: const Icon(Icons.receipt_long_rounded, size: 16),
            label: const Text('Record Payment'),
            onPressed: () => _openRecordPaymentDialog(student, fee),
          ),
        ],
      ),
    );
  }

  void _openRecordPaymentDialog(SchoolStudent student, SchoolFeeRecord fee) {
    final paidCtrl = TextEditingController(text: fee.paidAmount > 0 ? fee.paidAmount.toStringAsFixed(0) : fee.totalAmount.toStringAsFixed(0));
    final discountCtrl = TextEditingController(text: fee.discount.toStringAsFixed(0));
    final receiptCtrl = TextEditingController(text: fee.receiptNo.isNotEmpty ? fee.receiptNo : 'REC-${DateTime.now().millisecondsSinceEpoch.toString().substring(7)}');
    final remarksCtrl = TextEditingController(text: fee.remarks);
    String method = fee.paymentMethod;

    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDlgState) => AlertDialog(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          title: Row(
            children: [
              const Icon(Icons.payments_rounded, color: Color(0xFF10B981)),
              const SizedBox(width: 10),
              Expanded(
                child: Text('Record Fee Payment — ${student.name} (${student.grade})', style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
              ),
            ],
          ),
          content: SizedBox(
            width: 460,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Month: $_selectedMonth • Roll No: ${student.rollNo}', style: const TextStyle(fontWeight: FontWeight.bold, color: Color(0xFF6366F1))),
                const SizedBox(height: 14),

                TextField(
                  controller: paidCtrl,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(labelText: 'Amount Paid (PKR)', border: OutlineInputBorder()),
                ),
                const SizedBox(height: 12),

                TextField(
                  controller: discountCtrl,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(labelText: 'Discount / Concession (PKR)', border: OutlineInputBorder()),
                ),
                const SizedBox(height: 12),

                DropdownButtonFormField<String>(
                  value: method,
                  decoration: const InputDecoration(labelText: 'Payment Method', border: OutlineInputBorder()),
                  items: ['Cash', 'Bank Transfer', 'EasyPaisa', 'JazzCash'].map((m) => DropdownMenuItem(value: m, child: Text(m))).toList(),
                  onChanged: (v) { if (v != null) setDlgState(() => method = v); },
                ),
                const SizedBox(height: 12),

                TextField(
                  controller: receiptCtrl,
                  decoration: const InputDecoration(labelText: 'Receipt No / Ref ID', border: OutlineInputBorder()),
                ),
                const SizedBox(height: 12),

                TextField(
                  controller: remarksCtrl,
                  decoration: const InputDecoration(labelText: 'Remarks / Notes', border: OutlineInputBorder()),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
            ElevatedButton(
              style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF10B981), foregroundColor: Colors.white),
              onPressed: () async {
                final paid = double.tryParse(paidCtrl.text.trim()) ?? 0.0;
                final discount = double.tryParse(discountCtrl.text.trim()) ?? 0.0;
                final updatedFee = fee.copyWith(
                  paidAmount: paid,
                  discount: discount,
                  paymentMethod: method,
                  receiptNo: receiptCtrl.text.trim(),
                  remarks: remarksCtrl.text.trim(),
                  paymentDate: DateFormat('yyyy-MM-dd HH:mm').format(DateTime.now()),
                );

                await SchoolLocalStorage.saveFeeRecord(
                  branchId: widget.branchId,
                  feeId: updatedFee.id,
                  feeData: updatedFee.toMap(),
                  editorName: widget.userName,
                );

                if (context.mounted) {
                  Navigator.pop(ctx);
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text('Payment recorded for ${student.name}!'), backgroundColor: const Color(0xFF10B981)),
                  );
                }
              },
              child: const Text('Save & Print Receipt'),
            ),
          ],
        ),
      ),
    );
  }

  void _exportFeeReport() {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Exporting School Fee Collection & Defaulters Summary Report...'),
        backgroundColor: Color(0xFF6366F1),
      ),
    );
  }

  Widget _buildEmptyState() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: const [
          Icon(Icons.request_quote_rounded, size: 64, color: Colors.grey),
          SizedBox(height: 12),
          Text('No fee records found matching criteria.', style: TextStyle(color: Colors.grey, fontSize: 16, fontWeight: FontWeight.bold)),
        ],
      ),
    );
  }
}
