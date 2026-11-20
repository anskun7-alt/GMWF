// lib/pages/school/models/school_grade.dart

class SchoolGrade {
  final String id;
  final String studentId;
  final String studentName;
  final String rollNo;
  final String grade;
  final String section;
  final String subject;
  final String examType; // 'Quiz', 'Assignment', 'Midterm', 'Final'
  final String term;     // 'Term 1', 'Term 2', 'Final Term'
  final double marksObtained;
  final double totalMarks;
  final String date;
  final String enteredBy;
  final String remarks;

  /// Reference to a single shared attachment in `school_grade_attachments`
  /// (Phase 5 — avoids duplicating large base64 files into every student row).
  final String attachmentId;
  final String attachmentUrl; // Legacy inline base64/URL (empty for new saves)
  final String attachmentName; // e.g. "Term1_Marksheet.xlsx", "GradeSheet.pdf"
  final String attachmentType; // 'excel', 'pdf', 'image'
  final String academicYear;
  final String branchId;
  final String syncStatus;
  final String lastModified;

  SchoolGrade({
    required this.id,
    required this.studentId,
    required this.studentName,
    required this.rollNo,
    required this.grade,
    this.section = 'A',
    required this.subject,
    required this.examType,
    required this.term,
    required this.marksObtained,
    required this.totalMarks,
    required this.date,
    required this.enteredBy,
    this.remarks = '',
    this.attachmentId = '',
    this.attachmentUrl = '',
    this.attachmentName = '',
    this.attachmentType = '',
    this.academicYear = '',
    required this.branchId,
    this.syncStatus = 'synced',
    this.lastModified = '',
  });

  double get percentage => totalMarks > 0 ? (marksObtained / totalMarks) * 100 : 0.0;

  String get letterGrade {
    final pct = percentage;
    if (pct >= 90) return 'A+';
    if (pct >= 80) return 'A';
    if (pct >= 70) return 'B';
    if (pct >= 60) return 'C';
    if (pct >= 50) return 'D';
    return 'F';
  }

  double get gpaPoint {
    final pct = percentage;
    if (pct >= 90) return 4.0;
    if (pct >= 80) return 3.7;
    if (pct >= 70) return 3.0;
    if (pct >= 60) return 2.0;
    if (pct >= 50) return 1.0;
    return 0.0;
  }

  factory SchoolGrade.fromMap(String id, Map<String, dynamic> map) {
    return SchoolGrade(
      id: id,
      studentId: map['studentId']?.toString() ?? '',
      studentName: map['studentName']?.toString() ?? 'Student',
      rollNo: map['rollNo']?.toString() ?? '',
      grade: map['grade']?.toString() ?? '1',
      section: map['section']?.toString() ?? 'A',
      subject: map['subject']?.toString() ?? 'General',
      examType: map['examType']?.toString() ?? 'Quiz',
      term: map['term']?.toString() ?? 'Term 1',
      marksObtained: (map['marksObtained'] as num? ?? 0.0).toDouble(),
      totalMarks: (map['totalMarks'] as num? ?? 100.0).toDouble(),
      date: map['date']?.toString() ?? '',
      enteredBy: map['enteredBy']?.toString() ?? 'Teacher',
      remarks: map['remarks']?.toString() ?? '',
      attachmentId: map['attachmentId']?.toString() ?? '',
      attachmentUrl: map['attachmentUrl']?.toString() ?? '',
      attachmentName: map['attachmentName']?.toString() ?? '',
      attachmentType: map['attachmentType']?.toString() ?? '',
      academicYear: map['academicYear']?.toString() ?? '',
      branchId: map['branchId']?.toString() ?? '',
      syncStatus: map['syncStatus']?.toString() ?? 'synced',
      lastModified: map['lastModified']?.toString() ?? '',
    );
  }

  Map<String, dynamic> toMap() {
    return {
      // The id must travel with the record: without it every loaded grade had
      // id '' and re-saves collided on one key.
      'id': id,
      'studentId': studentId,
      'studentName': studentName,
      'rollNo': rollNo,
      'grade': grade,
      'section': section,
      'subject': subject,
      'examType': examType,
      'term': term,
      'marksObtained': marksObtained,
      'totalMarks': totalMarks,
      'date': date,
      'enteredBy': enteredBy,
      'remarks': remarks,
      if (attachmentId.isNotEmpty) 'attachmentId': attachmentId,
      'attachmentUrl': attachmentUrl,
      'attachmentName': attachmentName,
      'attachmentType': attachmentType,
      if (academicYear.isNotEmpty) 'academicYear': academicYear,
      'branchId': branchId,
      'syncStatus': syncStatus,
      'lastModified': lastModified,
    };
  }
}
