import 'package:cloud_firestore/cloud_firestore.dart';

class MadrassaConfig {
  final String id;
  final int year;
  final int month;

  final double baseFee;
  final double ptmDeduction;
  final double messageTotalDeduction;
  final double attendanceMaxDeduction;
  final double uniformMaxDeduction;
  final int ptmDay; // Day of the month (1-31)
  final bool allowStudentLeave;
  final bool enableFees;
  final List<Map<String, dynamic>> auditLog;

  MadrassaConfig({
    required this.id,
    required this.year,
    required this.month,
    this.baseFee = 3000,
    this.ptmDeduction = 700,
    this.messageTotalDeduction = 1300,
    this.attendanceMaxDeduction = 500,
    this.uniformMaxDeduction = 500,
    this.ptmDay = 0,
    this.allowStudentLeave = false,
    this.enableFees = true,
    this.auditLog = const [],
  });

  MadrassaConfig copyWith({
    String? id,
    int? year,
    int? month,
    double? baseFee,
    double? ptmDeduction,
    double? messageTotalDeduction,
    double? attendanceMaxDeduction,
    double? uniformMaxDeduction,
    int? ptmDay,
    bool? allowStudentLeave,
    bool? enableFees,
    List<Map<String, dynamic>>? auditLog,
  }) {
    return MadrassaConfig(
      id: id ?? this.id,
      year: year ?? this.year,
      month: month ?? this.month,
      baseFee: baseFee ?? this.baseFee,
      ptmDeduction: ptmDeduction ?? this.ptmDeduction,
      messageTotalDeduction: messageTotalDeduction ?? this.messageTotalDeduction,
      attendanceMaxDeduction: attendanceMaxDeduction ?? this.attendanceMaxDeduction,
      uniformMaxDeduction: uniformMaxDeduction ?? this.uniformMaxDeduction,
      ptmDay: ptmDay ?? this.ptmDay,
      allowStudentLeave: allowStudentLeave ?? this.allowStudentLeave,
      enableFees: enableFees ?? this.enableFees,
      auditLog: auditLog ?? this.auditLog,
    );
  }

  factory MadrassaConfig.fromMap(Map<String, dynamic> data, {String id = 'current'}) {
    final now = DateTime.now();
    return MadrassaConfig(
      id: id,
      year: (data['year'] as num?)?.toInt() ?? now.year,
      month: (data['month'] as num?)?.toInt() ?? now.month,
      baseFee: (data['baseFee'] as num?)?.toDouble() ?? 3000.0,
      ptmDeduction: (data['ptmDeduction'] as num?)?.toDouble() ?? 700.0,
      messageTotalDeduction: (data['messageTotalDeduction'] as num?)?.toDouble() ?? 1300.0,
      attendanceMaxDeduction: (data['attendanceMaxDeduction'] as num?)?.toDouble() ?? 500.0,
      uniformMaxDeduction: (data['uniformMaxDeduction'] as num?)?.toDouble() ?? 500.0,
      ptmDay: (data['ptmDay'] as num?)?.toInt() ?? 0,
      allowStudentLeave: data['allowStudentLeave'] == true,
      enableFees: data['enableFees'] != false,
      auditLog: List<Map<String, dynamic>>.from(data['auditLog'] ?? []),
    );
  }

  factory MadrassaConfig.fromFirestore(DocumentSnapshot doc) {
    final data = doc.data() as Map<String, dynamic>? ?? {};
    return MadrassaConfig.fromMap(data, id: doc.id);
  }

  Map<String, dynamic> toMap() {
    return {
      'year': year,
      'month': month,
      'baseFee': baseFee,
      'ptmDeduction': ptmDeduction,
      'messageTotalDeduction': messageTotalDeduction,
      'attendanceMaxDeduction': attendanceMaxDeduction,
      'uniformMaxDeduction': uniformMaxDeduction,
      'ptmDay': ptmDay,
      'allowStudentLeave': allowStudentLeave,
      'enableFees': enableFees,
      'auditLog': auditLog,
    };
  }

  DateTime getPtmDate({int? targetYear, int? targetMonth}) {
    final y = targetYear ?? DateTime.now().year;
    final m = targetMonth ?? DateTime.now().month;

    for (final log in auditLog) {
      if (log['type'] == 'ptm_reschedule' &&
          log['year'] == y &&
          log['month'] == m) {
        final newVal = int.tryParse(log['newValue']?.toString() ?? '');
        if (newVal != null && newVal > 0) {
          return DateTime(y, m, newVal);
        }
      }
    }

    if (ptmDay > 0) return DateTime(y, m, ptmDay);

    // Find first Friday of the month
    DateTime date = DateTime(y, m, 1);
    while (date.weekday != DateTime.friday) {
      date = date.add(const Duration(days: 1));
    }
    return date;
  }
}
