// lib/pages/school/models/school_fee.dart

class SchoolFeeRecord {
  final String id;
  final String studentId;
  final String studentName;
  final String rollNo;
  final String grade; // e.g. "9th", "10th"
  final String section; // e.g. "A", "B"
  final String monthYear; // e.g. "July 2026"
  final double tuitionFee;
  final double admissionFee;
  final double examFee;
  final double otherCharges;
  final double discount;
  final double totalAmount;
  final double paidAmount;
  final String status; // 'paid', 'partial', 'unpaid'
  final String paymentDate;
  final String paymentMethod; // 'Cash', 'Bank Transfer', 'EasyPaisa', 'JazzCash'
  final String receiptNo;
  final String remarks;
  final String branchId;
  final String lastModified;
  final String syncStatus; // 'synced', 'pending', 'failed'

  SchoolFeeRecord({
    required this.id,
    required this.studentId,
    required this.studentName,
    required this.rollNo,
    required this.grade,
    this.section = 'A',
    required this.monthYear,
    this.tuitionFee = 0.0,
    this.admissionFee = 0.0,
    this.examFee = 0.0,
    this.otherCharges = 0.0,
    this.discount = 0.0,
    double? totalAmount,
    this.paidAmount = 0.0,
    this.status = 'unpaid',
    this.paymentDate = '',
    this.paymentMethod = 'Cash',
    this.receiptNo = '',
    this.remarks = '',
    required this.branchId,
    this.lastModified = '',
    this.syncStatus = 'synced',
  }) : totalAmount = totalAmount ??
            ((tuitionFee + admissionFee + examFee + otherCharges) - discount);

  double get remainingBalance => (totalAmount - paidAmount).clamp(0.0, double.infinity);

  /// paid ≥ total (whole rupees) → paid; anything paid → partial; else unpaid.
  static String statusFor(double total, double paid) {
    if (paid.round() >= total.round() && (total > 0 || paid > 0)) return 'paid';
    if (paid > 0) return 'partial';
    return total <= 0 ? 'paid' : 'unpaid';
  }

  factory SchoolFeeRecord.fromMap(String id, Map<String, dynamic> map) {
    final tuition = (map['tuitionFee'] as num?)?.toDouble() ?? 0.0;
    final admission = (map['admissionFee'] as num?)?.toDouble() ?? 0.0;
    final exam = (map['examFee'] as num?)?.toDouble() ?? 0.0;
    final other = (map['otherCharges'] as num?)?.toDouble() ?? 0.0;
    final disc = (map['discount'] as num?)?.toDouble() ?? 0.0;
    final calcTotal = (tuition + admission + exam + other) - disc;
    final total = (map['totalAmount'] as num?)?.toDouble() ?? calcTotal;
    final paid = (map['paidAmount'] as num?)?.toDouble() ?? 0.0;

    String st = map['status']?.toString() ?? 'unpaid';
    if (paid >= total && total > 0) {
      st = 'paid';
    } else if (paid > 0) {
      st = 'partial';
    }

    return SchoolFeeRecord(
      id: id,
      studentId: map['studentId']?.toString() ?? '',
      studentName: map['studentName']?.toString() ?? 'Student',
      rollNo: map['rollNo']?.toString() ?? '',
      grade: map['grade']?.toString() ?? '1',
      section: map['section']?.toString() ?? 'A',
      monthYear: map['monthYear']?.toString() ?? 'July 2026',
      tuitionFee: tuition,
      admissionFee: admission,
      examFee: exam,
      otherCharges: other,
      discount: disc,
      totalAmount: total,
      paidAmount: paid,
      status: st,
      paymentDate: map['paymentDate']?.toString() ?? '',
      paymentMethod: map['paymentMethod']?.toString() ?? 'Cash',
      receiptNo: map['receiptNo']?.toString() ?? '',
      remarks: map['remarks']?.toString() ?? '',
      branchId: map['branchId']?.toString() ?? '',
      lastModified: map['lastModified']?.toString() ?? '',
      syncStatus: map['syncStatus']?.toString() ?? 'synced',
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'studentId': studentId,
      'studentName': studentName,
      'rollNo': rollNo,
      'grade': grade,
      'section': section,
      'monthYear': monthYear,
      'tuitionFee': tuitionFee,
      'admissionFee': admissionFee,
      'examFee': examFee,
      'otherCharges': otherCharges,
      'discount': discount,
      'totalAmount': totalAmount,
      'paidAmount': paidAmount,
      'status': status,
      'paymentDate': paymentDate,
      'paymentMethod': paymentMethod,
      'receiptNo': receiptNo,
      'remarks': remarks,
      'branchId': branchId,
      'lastModified': lastModified,
      'syncStatus': syncStatus,
    };
  }

  SchoolFeeRecord copyWith({
    String? studentName,
    String? rollNo,
    String? grade,
    String? section,
    String? monthYear,
    double? tuitionFee,
    double? admissionFee,
    double? examFee,
    double? otherCharges,
    double? discount,
    double? totalAmount,
    double? paidAmount,
    String? status,
    String? paymentDate,
    String? paymentMethod,
    String? receiptNo,
    String? remarks,
    String? branchId,
  }) {
    // Total and status are derived, not copied: copying the old total meant a
    // discount never reduced it, and the stored status stayed "unpaid" after payment.
    final t = tuitionFee ?? this.tuitionFee;
    final a = admissionFee ?? this.admissionFee;
    final e = examFee ?? this.examFee;
    final o = otherCharges ?? this.otherCharges;
    final d = discount ?? this.discount;
    final total = totalAmount ?? ((t + a + e + o) - d).clamp(0.0, double.infinity);
    final paid = paidAmount ?? this.paidAmount;
    return SchoolFeeRecord(
      id: id,
      studentId: studentId,
      studentName: studentName ?? this.studentName,
      rollNo: rollNo ?? this.rollNo,
      grade: grade ?? this.grade,
      section: section ?? this.section,
      monthYear: monthYear ?? this.monthYear,
      tuitionFee: t,
      admissionFee: a,
      examFee: e,
      otherCharges: o,
      discount: d,
      totalAmount: total,
      paidAmount: paid,
      status: status ?? statusFor(total, paid),
      paymentDate: paymentDate ?? this.paymentDate,
      paymentMethod: paymentMethod ?? this.paymentMethod,
      receiptNo: receiptNo ?? this.receiptNo,
      remarks: remarks ?? this.remarks,
      branchId: branchId ?? this.branchId,
      lastModified: lastModified,
      syncStatus: syncStatus,
    );
  }
}
