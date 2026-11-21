import 'package:flutter/material.dart';
import 'package:gmwf/design/tokens/comfort_colors.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:intl/intl.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';
import '../../services/local_storage_service.dart';
import 'utils/madrassa_local_storage.dart';
import 'widgets/madrassa_erp.dart';

class StudentFeeLedgerScreen extends StatefulWidget {
  final String branchId;
  final String studentId;
  final String? studentName;
  final String? fatherName;
  final String? rollNumber;
  final double? monthlyFee;

  const StudentFeeLedgerScreen({
    Key? key,
    required this.branchId,
    required this.studentId,
    this.studentName,
    this.fatherName,
    this.rollNumber,
    this.monthlyFee,
  }) : super(key: key);

  @override
  State<StudentFeeLedgerScreen> createState() => _StudentFeeLedgerScreenState();
}

class _StudentFeeLedgerScreenState extends State<StudentFeeLedgerScreen> {
  int _selectedYear = DateTime.now().year;
  bool _isLoading = true;
  List<Map<String, dynamic>> _feeRecords = [];
  Map<String, dynamic>? _studentData;

  @override
  void initState() {
    super.initState();
    _loadData();
  }

  Future<void> _loadData() async {
    setState(() => _isLoading = true);
    await LocalStorageService.ensureBoxOpen(LocalStorageService.madrassaFeesBox);
    await LocalStorageService.ensureBoxOpen(LocalStorageService.madrassaStudentsBox);

    final studentsBox = Hive.box(LocalStorageService.madrassaStudentsBox);
    final sKey = '${widget.branchId.toLowerCase().trim()}__std__${widget.studentId}';
    final rawStudent = studentsBox.get(sKey);
    if (rawStudent is Map) {
      _studentData = Map<String, dynamic>.from(rawStudent);
    }

    final feesBox = Hive.box(LocalStorageService.madrassaFeesBox);
    final prefix = '${widget.branchId.toLowerCase().trim()}__fee__';
    final List<Map<String, dynamic>> records = [];

    for (final key in feesBox.keys) {
      final keyStr = key.toString();
      if (keyStr.startsWith(prefix) && keyStr.endsWith('__${widget.studentId}')) {
        final raw = feesBox.get(key);
        if (raw is Map) {
          records.add(Map<String, dynamic>.from(raw));
        }
      }
    }

    // Sort descending by year and month
    records.sort((a, b) {
      final yA = (a['year'] ?? 0) as int;
      final yB = (b['year'] ?? 0) as int;
      if (yA != yB) return yB.compareTo(yA);
      final mA = (a['month'] ?? 0) as int;
      final mB = (b['month'] ?? 0) as int;
      return mB.compareTo(mA);
    });

    if (mounted) {
      setState(() {
        _feeRecords = records;
        _isLoading = false;
      });
    }
  }

  double get _totalPaid => _feeRecords.fold(0.0, (sum, r) => sum + ((r['amountPaid'] ?? 0) as num).toDouble());
  double get _totalDiscount => _feeRecords.fold(0.0, (sum, r) => sum + ((r['discount'] ?? 0) as num).toDouble());
  double get _totalDue => _feeRecords.fold(0.0, (sum, r) => sum + ((r['balanceDue'] ?? 0) as num).toDouble());

  String _getMonthName(int month) {
    if (month < 1 || month > 12) return 'Month $month';
    const months = [
      'January', 'February', 'March', 'April', 'May', 'June',
      'July', 'August', 'September', 'October', 'November', 'December'
    ];
    return months[month - 1];
  }

  /// Amount already paid for [year]/[month] (running total stored on the record).
  double _priorPaidFor(int year, int month) {
    if (!Hive.isBoxOpen(LocalStorageService.madrassaFeesBox)) return 0.0;
    final key = '${MadrassaLocalStorage.normalizeBranch(widget.branchId.toLowerCase().trim())}'
        '__fee__${year}_${month}__${widget.studentId}';
    final existing = Hive.box(LocalStorageService.madrassaFeesBox).get(key);
    return existing is Map ? ((existing['amountPaid'] as num?)?.toDouble() ?? 0.0) : 0.0;
  }

  Future<void> _recordPaymentDialog() async {
    final double initialFee = (widget.monthlyFee ?? _studentData?['monthlyFee'] ?? 0.0).toDouble();
    final totalFeeCtrl = TextEditingController(text: initialFee > 0 ? initialFee.toStringAsFixed(0) : '0');
    final dueNow = (initialFee - _priorPaidFor(_selectedYear, DateTime.now().month)).clamp(0.0, double.infinity);
    final amountCtrl = TextEditingController(text: dueNow > 0 ? dueNow.toStringAsFixed(0) : '0');
    final discountCtrl = TextEditingController(text: '0');
    final noteCtrl = TextEditingController();
    int selectedMonth = DateTime.now().month;
    int selectedYear = _selectedYear;
    String paymentMethod = 'Cash';

    final result = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDlgState) {
          final total = double.tryParse(totalFeeCtrl.text.trim()) ?? 0.0;
          final amount = double.tryParse(amountCtrl.text.trim()) ?? 0.0;
          final discount = double.tryParse(discountCtrl.text.trim()) ?? 0.0;
          // Earlier installments for the selected month count too (the save adds to them).
          final priorPaid = _priorPaidFor(selectedYear, selectedMonth);
          final remaining = (total - priorPaid - amount - discount).clamp(0.0, double.infinity);
          final isCleared = remaining <= 0.0;

          final c = ctx.comfort;

          return AlertDialog(
            backgroundColor: c.surface,
            shape: const RoundedRectangleBorder(borderRadius: MadrassaErp.cardRadius),
            title: Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: c.brandSoft,
                    borderRadius: MadrassaErp.radius,
                  ),
                  child: Icon(Icons.payment, color: c.brand, size: 20),
                ),
                const SizedBox(width: 10),
                Text('Collect / Deduct Fee Payment', style: TextStyle(fontSize: 17, fontWeight: FontWeight.bold, color: c.textPrimary)),
              ],
            ),
            content: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: DropdownButtonFormField<int>(
                          value: selectedMonth,
                          decoration: InputDecoration(
                            labelText: 'Month',
                            labelStyle: TextStyle(color: c.textMuted),
                            filled: true,
                            fillColor: c.surfaceSunken,
                            border: OutlineInputBorder(borderRadius: MadrassaErp.radius, borderSide: BorderSide(color: c.border)),
                            enabledBorder: OutlineInputBorder(borderRadius: MadrassaErp.radius, borderSide: BorderSide(color: c.border)),
                          ),
                          dropdownColor: c.surface,
                          items: List.generate(12, (i) => DropdownMenuItem(value: i + 1, child: Text(_getMonthName(i + 1), style: TextStyle(color: c.textPrimary)))),
                          onChanged: (v) {
                            if (v != null) setDlgState(() => selectedMonth = v);
                          },
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: DropdownButtonFormField<int>(
                          value: selectedYear,
                          decoration: InputDecoration(
                            labelText: 'Year',
                            labelStyle: TextStyle(color: c.textMuted),
                            filled: true,
                            fillColor: c.surfaceSunken,
                            border: OutlineInputBorder(borderRadius: MadrassaErp.radius, borderSide: BorderSide(color: c.border)),
                            enabledBorder: OutlineInputBorder(borderRadius: MadrassaErp.radius, borderSide: BorderSide(color: c.border)),
                          ),
                          dropdownColor: c.surface,
                          items: [selectedYear - 1, selectedYear, selectedYear + 1]
                              .map((y) => DropdownMenuItem(value: y, child: Text('$y', style: TextStyle(color: c.textPrimary))))
                              .toList(),
                          onChanged: (v) {
                            if (v != null) setDlgState(() => selectedYear = v);
                          },
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: totalFeeCtrl,
                    keyboardType: TextInputType.number,
                    style: TextStyle(color: c.textPrimary),
                    onChanged: (_) => setDlgState(() {}),
                    decoration: InputDecoration(
                      labelText: 'Total Monthly Fee (PKR)',
                      labelStyle: TextStyle(color: c.textMuted),
                      prefixText: 'Rs. ',
                      prefixStyle: TextStyle(color: c.textPrimary),
                      filled: true,
                      fillColor: c.surfaceSunken,
                      border: OutlineInputBorder(borderRadius: MadrassaErp.radius, borderSide: BorderSide(color: c.border)),
                      enabledBorder: OutlineInputBorder(borderRadius: MadrassaErp.radius, borderSide: BorderSide(color: c.border)),
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: amountCtrl,
                    keyboardType: TextInputType.number,
                    style: TextStyle(color: c.textPrimary),
                    onChanged: (_) => setDlgState(() {}),
                    decoration: InputDecoration(
                      labelText: 'Amount Paid by Parent (Deducted) (PKR)',
                      labelStyle: TextStyle(color: c.textMuted),
                      prefixText: 'Rs. ',
                      prefixStyle: TextStyle(color: c.textPrimary),
                      filled: true,
                      fillColor: c.surfaceSunken,
                      border: OutlineInputBorder(borderRadius: MadrassaErp.radius, borderSide: BorderSide(color: c.border)),
                      enabledBorder: OutlineInputBorder(borderRadius: MadrassaErp.radius, borderSide: BorderSide(color: c.border)),
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: discountCtrl,
                    keyboardType: TextInputType.number,
                    style: TextStyle(color: c.textPrimary),
                    onChanged: (_) => setDlgState(() {}),
                    decoration: InputDecoration(
                      labelText: 'Discount / Concession (PKR)',
                      labelStyle: TextStyle(color: c.textMuted),
                      prefixText: 'Rs. ',
                      prefixStyle: TextStyle(color: c.textPrimary),
                      filled: true,
                      fillColor: c.surfaceSunken,
                      border: OutlineInputBorder(borderRadius: MadrassaErp.radius, borderSide: BorderSide(color: c.border)),
                      enabledBorder: OutlineInputBorder(borderRadius: MadrassaErp.radius, borderSide: BorderSide(color: c.border)),
                    ),
                  ),
                  const SizedBox(height: 12),
                  // Live deduction breakdown card showing what remains
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: (isCleared ? c.success : c.danger).withValues(alpha: 0.08),
                      borderRadius: MadrassaErp.radius,
                      border: Border.all(
                        color: isCleared ? c.success : c.danger,
                        width: 1.2,
                      ),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Text('Total Monthly Fee:', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w500, color: c.textPrimary)),
                            Text('Rs. ${total.toStringAsFixed(0)}', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12, color: c.textPrimary)),
                          ],
                        ),
                        const SizedBox(height: 4),
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Text('Amount Paid (Deducted):', style: TextStyle(fontSize: 12, color: c.success, fontWeight: FontWeight.w600)),
                            Text('- Rs. ${amount.toStringAsFixed(0)}', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12, color: c.success)),
                          ],
                        ),
                        if (discount > 0) ...[
                          const SizedBox(height: 4),
                          Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              Text('Concession / Discount:', style: TextStyle(fontSize: 12, color: c.warning, fontWeight: FontWeight.w600)),
                              Text('- Rs. ${discount.toStringAsFixed(0)}', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12, color: c.warning)),
                            ],
                          ),
                        ],
                        Divider(height: 12, color: c.border),
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Text(
                              isCleared ? 'Status: Fully Cleared 🎉' : 'Remaining Balance Due:',
                              style: TextStyle(
                                fontWeight: FontWeight.bold,
                                fontSize: 13,
                                color: isCleared ? c.success : c.danger,
                              ),
                            ),
                            Text(
                              'Rs. ${remaining.toStringAsFixed(0)}',
                              style: TextStyle(
                                fontWeight: FontWeight.bold,
                                fontSize: 16,
                                color: isCleared ? c.success : c.danger,
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 12),
                  DropdownButtonFormField<String>(
                    value: paymentMethod,
                    decoration: InputDecoration(
                      labelText: 'Payment Method',
                      labelStyle: TextStyle(color: c.textMuted),
                      filled: true,
                      fillColor: c.surfaceSunken,
                      border: OutlineInputBorder(borderRadius: MadrassaErp.radius, borderSide: BorderSide(color: c.border)),
                      enabledBorder: OutlineInputBorder(borderRadius: MadrassaErp.radius, borderSide: BorderSide(color: c.border)),
                    ),
                    dropdownColor: c.surface,
                    items: const [
                      DropdownMenuItem(value: 'Cash', child: Text('Cash')),
                      DropdownMenuItem(value: 'Bank Transfer', child: Text('Bank Transfer')),
                      DropdownMenuItem(value: 'JazzCash/EasyPaisa', child: Text('JazzCash / EasyPaisa')),
                      DropdownMenuItem(value: 'Online', child: Text('Online / Card')),
                    ],
                    onChanged: (v) {
                      if (v != null) setDlgState(() => paymentMethod = v);
                    },
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: noteCtrl,
                    style: TextStyle(color: c.textPrimary),
                    decoration: InputDecoration(
                      labelText: 'Notes / Remarks',
                      labelStyle: TextStyle(color: c.textMuted),
                      filled: true,
                      fillColor: c.surfaceSunken,
                      border: OutlineInputBorder(borderRadius: MadrassaErp.radius, borderSide: BorderSide(color: c.border)),
                      enabledBorder: OutlineInputBorder(borderRadius: MadrassaErp.radius, borderSide: BorderSide(color: c.border)),
                    ),
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(ctx).pop(false),
                child: Text('Cancel', style: TextStyle(color: c.textMuted)),
              ),
              ElevatedButton(
                style: ElevatedButton.styleFrom(
                  backgroundColor: c.brand,
                  foregroundColor: c.onBrand,
                  elevation: 0,
                  shape: const RoundedRectangleBorder(borderRadius: MadrassaErp.radius),
                ),
                onPressed: () async {
                  final receiptId = 'REC-${DateTime.now().millisecondsSinceEpoch.toString().substring(6)}';

                  // amountPaid is a running total for the month (monthly report
                  // reads it that way): add this installment to what was already
                  // paid instead of replacing it. The save below keeps the
                  // record's auditLog and broadcasts it on the LAN.
                  final box = await LocalStorageService.ensureBoxOpen(LocalStorageService.madrassaFeesBox);
                  final existingKey = '${MadrassaLocalStorage.normalizeBranch(widget.branchId.toLowerCase().trim())}'
                      '__fee__${selectedYear}_${selectedMonth}__${widget.studentId}';
                  final existing = box.get(existingKey);
                  final priorPaid = existing is Map ? ((existing['amountPaid'] as num?)?.toDouble() ?? 0.0) : 0.0;
                  final totalPaid = priorPaid + amount;
                  final balance = (total - totalPaid - discount).clamp(0.0, double.infinity);
                  final cleared = balance <= 0.0;

                  // Unified sync and audit log recording
                  await MadrassaLocalStorage.saveFeePaymentLocalAndSync(
                    branchId: widget.branchId,
                    studentId: widget.studentId,
                    studentName: widget.studentName ?? _studentData?['name'] ?? 'Student',
                    rollNumber: widget.rollNumber ?? _studentData?['rollNumber'] ?? '',
                    year: selectedYear,
                    month: selectedMonth,
                    amountDue: total,
                    amountPaid: totalPaid,
                    discount: discount,
                    balanceDue: balance,
                    paymentMethod: paymentMethod,
                    receiptId: receiptId,
                    status: cleared ? 'paid' : (totalPaid > 0 || discount > 0 ? 'partial' : 'unpaid'),
                    markedBy: 'HQ Manager',
                    markedByRole: 'hq manager',
                    note: noteCtrl.text.trim(),
                  );

                  if (ctx.mounted) Navigator.of(ctx).pop(true);
                },
                child: const Text('Save & Print Receipt'),
              ),
            ],
          );
        },
      ),
    );

    if (result == true) {
      await _loadData();
      // Print the month just paid; _feeRecords.first is the latest month.
      final paid = _feeRecords.firstWhere(
        (r) => r['year'] == selectedYear && r['month'] == selectedMonth,
        orElse: () => _feeRecords.isNotEmpty ? _feeRecords.first : const <String, dynamic>{},
      );
      if (paid.isNotEmpty) {
        await _printReceipt(paid);
      }
    }
  }

  Future<void> _printReceipt(Map<String, dynamic> record) async {
    final doc = pw.Document();
    final stdName = widget.studentName ?? _studentData?['name'] ?? 'Student';
    final fName = widget.fatherName ?? _studentData?['fatherName'] ?? '';
    final rId = record['receiptId'] ?? 'N/A';
    final mName = _getMonthName(record['month'] ?? 1);
    final year = record['year'] ?? DateTime.now().year;
    final amt = record['amountPaid'] ?? 0;
    final disc = record['discount'] ?? 0;
    final due = record['balanceDue'] ?? 0;
    final totalFee = record['totalFee'] ?? record['amountDue'] ?? 0;
    final method = record['paymentMethod'] ?? 'Cash';
    final date = DateFormat('dd MMM yyyy, hh:mm a').format(DateTime.tryParse(record['paidAt'] ?? '') ?? DateTime.now());

    doc.addPage(
      pw.Page(
        pageFormat: PdfPageFormat.roll80,
        build: (pw.Context context) {
          return pw.Column(
            crossAxisAlignment: pw.CrossAxisAlignment.center,
            children: [
              pw.Text('GHULAM MUHAMMAD WELFARE', style: pw.TextStyle(fontWeight: pw.FontWeight.bold, fontSize: 13)),
              pw.Text('MADRASSA & EDUCATION SYSTEM', style: pw.TextStyle(fontWeight: pw.FontWeight.bold, fontSize: 10)),
              pw.Text('Fee Payment Receipt', style: const pw.TextStyle(fontSize: 10)),
              pw.Divider(thickness: 0.5),
              pw.Align(
                alignment: pw.Alignment.centerLeft,
                child: pw.Column(
                  crossAxisAlignment: pw.CrossAxisAlignment.start,
                  children: [
                    pw.Text('Receipt #: $rId', style: const pw.TextStyle(fontSize: 8)),
                    pw.Text('Date: $date', style: const pw.TextStyle(fontSize: 8)),
                    pw.Text('Student: $stdName', style: pw.TextStyle(fontWeight: pw.FontWeight.bold, fontSize: 9)),
                    if (fName.isNotEmpty) pw.Text('Father: $fName', style: const pw.TextStyle(fontSize: 8)),
                    pw.Text('Period: $mName $year', style: const pw.TextStyle(fontSize: 8)),
                    pw.Text('Method: $method', style: const pw.TextStyle(fontSize: 8)),
                  ],
                ),
              ),
              pw.Divider(thickness: 0.5),
              if (totalFee > 0)
                pw.Row(mainAxisAlignment: pw.MainAxisAlignment.spaceBetween, children: [
                  pw.Text('Total Fee:', style: const pw.TextStyle(fontSize: 8)),
                  pw.Text('Rs. $totalFee', style: const pw.TextStyle(fontSize: 8)),
                ]),
              pw.Row(mainAxisAlignment: pw.MainAxisAlignment.spaceBetween, children: [
                pw.Text('Amount Paid (Deducted):', style: pw.TextStyle(fontWeight: pw.FontWeight.bold, fontSize: 9)),
                pw.Text('Rs. $amt', style: pw.TextStyle(fontWeight: pw.FontWeight.bold, fontSize: 9)),
              ]),
              if (disc > 0)
                pw.Row(mainAxisAlignment: pw.MainAxisAlignment.spaceBetween, children: [
                  pw.Text('Discount / Concession:', style: const pw.TextStyle(fontSize: 8)),
                  pw.Text('Rs. $disc', style: const pw.TextStyle(fontSize: 8)),
                ]),
              if (due > 0)
                pw.Row(mainAxisAlignment: pw.MainAxisAlignment.spaceBetween, children: [
                  pw.Text('Remaining Balance Due:', style: const pw.TextStyle(fontSize: 8, color: PdfColors.red)),
                  pw.Text('Rs. $due', style: const pw.TextStyle(fontSize: 8, color: PdfColors.red)),
                ])
              else
                pw.Row(mainAxisAlignment: pw.MainAxisAlignment.spaceBetween, children: [
                  pw.Text('Status:', style: const pw.TextStyle(fontSize: 8, color: PdfColors.green)),
                  pw.Text('FULLY CLEARED', style: const pw.TextStyle(fontSize: 8, color: PdfColors.green)),
                ]),
              pw.Divider(thickness: 0.5),
              pw.Text('Thank you for your payment.', style: const pw.TextStyle(fontSize: 7)),
            ],
          );
        },
      ),
    );

    await Printing.layoutPdf(
      onLayout: (PdfPageFormat format) async => doc.save(),
      name: 'Receipt_$rId.pdf',
    );
  }

  @override
  Widget build(BuildContext context) {
    final c = context.comfort;
    final stdName = widget.studentName ?? _studentData?['name'] ?? 'Student';
    final fName = widget.fatherName ?? _studentData?['fatherName'] ?? '';

    return Scaffold(
      backgroundColor: c.surfaceSunken,
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('$stdName - Fee Ledger', style: TextStyle(fontSize: 17, fontWeight: FontWeight.bold, color: c.textPrimary)),
            if (fName.isNotEmpty)
              Text('S/O $fName | ID: ${widget.studentId}', style: TextStyle(fontSize: 12, color: c.textMuted)),
          ],
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: 'Refresh Ledger',
            onPressed: _loadData,
          ),
          IconButton(
            icon: const Icon(Icons.add_card),
            tooltip: 'Collect Fee',
            onPressed: _recordPaymentDialog,
          ),
        ],
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : Column(
              children: [
                // Summary cards
                Container(
                  padding: const EdgeInsets.all(16),
                  color: c.surfaceSunken,
                  child: Row(
                    children: [
                      _buildSummaryCard('Total Paid', 'Rs. ${_totalPaid.toStringAsFixed(0)}', c.success, Icons.check_circle_outline),
                      const SizedBox(width: 8),
                      _buildSummaryCard('Total Concession', 'Rs. ${_totalDiscount.toStringAsFixed(0)}', c.warning, Icons.discount_outlined),
                      const SizedBox(width: 8),
                      _buildSummaryCard('Outstanding Due', 'Rs. ${_totalDue.toStringAsFixed(0)}', c.danger, Icons.pending_actions),
                    ],
                  ),
                ),
                // Filter bar
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                  child: Row(
                    children: [
                      Text('Fee History', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: c.textPrimary)),
                      const Spacer(),
                      ElevatedButton.icon(
                        icon: const Icon(Icons.add, size: 16),
                        label: const Text('Record Payment'),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: c.brand,
                          foregroundColor: c.onBrand,
                          elevation: 0,
                          shape: const RoundedRectangleBorder(borderRadius: MadrassaErp.radius),
                        ),
                        onPressed: _recordPaymentDialog,
                      ),
                    ],
                  ),
                ),
                Divider(height: 1, color: c.border),
                // Ledger List
                Expanded(
                  child: _feeRecords.isEmpty
                      ? Center(
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Icon(Icons.receipt_long_outlined, size: 64, color: c.textMuted.withValues(alpha: 0.5)),
                              const SizedBox(height: 12),
                              Text('No fee records found for this student', style: TextStyle(fontSize: 15, color: c.textMuted)),
                              const SizedBox(height: 12),
                              ElevatedButton(
                                style: ElevatedButton.styleFrom(
                                  backgroundColor: c.brand,
                                  foregroundColor: c.onBrand,
                                  elevation: 0,
                                  shape: const RoundedRectangleBorder(borderRadius: MadrassaErp.radius),
                                ),
                                onPressed: _recordPaymentDialog,
                                child: const Text('Collect First Payment'),
                              ),
                            ],
                          ),
                        )
                      : ListView.separated(
                          padding: const EdgeInsets.all(16),
                          itemCount: _feeRecords.length,
                          separatorBuilder: (_, __) => const SizedBox(height: 8),
                          itemBuilder: (ctx, idx) {
                            final r = _feeRecords[idx];
                            final monthName = _getMonthName(r['month'] ?? 1);
                            final year = r['year'] ?? DateTime.now().year;
                            final amount = r['amountPaid'] ?? 0;
                            final discount = r['discount'] ?? 0;
                            final due = r['balanceDue'] ?? 0;
                            final status = r['status'] ?? 'Paid';
                            final receiptId = r['receiptId'] ?? 'N/A';
                            final paidDate = r['paidAt'] != null
                                ? DateFormat('dd MMM yyyy').format(DateTime.tryParse(r['paidAt']) ?? DateTime.now())
                                : '';

                            final isPaid = status.toString().toLowerCase() == 'paid';
                            final isPartial = status.toString().toLowerCase() == 'partial';

                            return Container(
                              decoration: BoxDecoration(
                                color: c.surface,
                                borderRadius: MadrassaErp.cardRadius,
                                border: Border.all(color: c.border),
                              ),
                              child: ListTile(
                                leading: Container(
                                  width: 40,
                                  height: 40,
                                  decoration: BoxDecoration(
                                    color: isPaid
                                        ? c.success.withValues(alpha: 0.12)
                                        : (isPartial ? c.warning.withValues(alpha: 0.12) : c.danger.withValues(alpha: 0.12)),
                                    borderRadius: MadrassaErp.radius,
                                  ),
                                  child: Icon(
                                    isPaid
                                        ? Icons.check
                                        : (isPartial ? Icons.pie_chart_outline_rounded : Icons.pending_actions_rounded),
                                    color: isPaid ? c.success : (isPartial ? c.warning : c.danger),
                                    size: 20,
                                  ),
                                ),
                                title: Text('$monthName $year', style: TextStyle(fontWeight: FontWeight.bold, color: c.textPrimary, fontSize: 14)),
                                subtitle: Text(
                                  'Receipt: $receiptId • Date: $paidDate\nMethod: ${r['paymentMethod'] ?? 'Cash'} ${discount > 0 ? '• Concession: Rs. $discount' : ''}',
                                  style: TextStyle(color: c.textMuted, fontSize: 12),
                                ),
                                isThreeLine: true,
                                trailing: Column(
                                  mainAxisAlignment: MainAxisAlignment.center,
                                  crossAxisAlignment: CrossAxisAlignment.end,
                                  children: [
                                    Text('Paid: Rs. $amount', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14, color: c.success)),
                                    if (due > 0)
                                      Text('Remains: Rs. $due', style: TextStyle(fontSize: 11, color: c.danger, fontWeight: FontWeight.bold))
                                    else
                                      Text('Cleared', style: TextStyle(fontSize: 11, color: c.success, fontWeight: FontWeight.w600)),
                                  ],
                                ),
                                onTap: () => _printReceipt(r),
                              ),
                            );
                          },
                        ),
                ),
              ],
            ),
    );
  }

  Widget _buildSummaryCard(String title, String value, Color color, IconData icon) {
    return Expanded(
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.08),
          borderRadius: MadrassaErp.cardRadius,
          border: Border.all(color: color.withValues(alpha: 0.25)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(5),
                  decoration: BoxDecoration(
                    color: color.withValues(alpha: 0.14),
                    borderRadius: MadrassaErp.radius,
                  ),
                  child: Icon(icon, size: 14, color: color),
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    title,
                    style: TextStyle(fontSize: 11, color: color, fontWeight: FontWeight.w600),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(value, style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: color)),
          ],
        ),
      ),
    );
  }
}
