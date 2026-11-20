// lib/pages/school/models/school_student.dart
//
// A School student record. Phase 2 of the School ERP plan (2026-11-17) split the
// admission number (unique per branch, issued once) from the roll number
// (per class-section per academic year), and added the status lifecycle,
// class history, siblings data and the madrassa link fields.

/// One dated status change (see students/student_models.dart for the rules).
class SchoolStudentStatusChange {
  final String from;
  final String to;
  final String effectiveDate; // yyyy-MM-dd
  final String reason;
  final String by;
  final String at; // ISO time the change was recorded

  const SchoolStudentStatusChange({
    required this.from,
    required this.to,
    required this.effectiveDate,
    this.reason = '',
    this.by = '',
    this.at = '',
  });

  factory SchoolStudentStatusChange.fromMap(Map m) => SchoolStudentStatusChange(
        from: m['from']?.toString() ?? '',
        to: m['to']?.toString() ?? '',
        effectiveDate: m['effectiveDate']?.toString() ?? '',
        reason: m['reason']?.toString() ?? '',
        by: m['by']?.toString() ?? '',
        at: m['at']?.toString() ?? '',
      );

  Map<String, dynamic> toMap() => {
        'from': from,
        'to': to,
        'effectiveDate': effectiveDate,
        'reason': reason,
        'by': by,
        'at': at,
      };
}

/// One dated class/section move.
class SchoolStudentClassChange {
  final String fromGrade;
  final String fromSection;
  final String toGrade;
  final String toSection;
  final String effectiveDate;
  final String by;
  final String at;

  const SchoolStudentClassChange({
    required this.fromGrade,
    required this.fromSection,
    required this.toGrade,
    required this.toSection,
    required this.effectiveDate,
    this.by = '',
    this.at = '',
  });

  factory SchoolStudentClassChange.fromMap(Map m) => SchoolStudentClassChange(
        fromGrade: m['fromGrade']?.toString() ?? '',
        fromSection: m['fromSection']?.toString() ?? '',
        toGrade: m['toGrade']?.toString() ?? '',
        toSection: m['toSection']?.toString() ?? '',
        effectiveDate: m['effectiveDate']?.toString() ?? '',
        by: m['by']?.toString() ?? '',
        at: m['at']?.toString() ?? '',
      );

  Map<String, dynamic> toMap() => {
        'fromGrade': fromGrade,
        'fromSection': fromSection,
        'toGrade': toGrade,
        'toSection': toSection,
        'effectiveDate': effectiveDate,
        'by': by,
        'at': at,
      };
}

class SchoolStudent {
  final String id;

  /// Admission number, unique per branch (e.g. `GRT-0012`). Older records used
  /// one typed number for both admission and roll; those keep it in both.
  final String admissionNo;

  /// Roll number inside the class-section for the academic year.
  final String rollNo;
  final String name;
  final String guardianName;
  final String guardianPhone;
  final String guardianCnic;
  final String bformNo;
  final String fatherProfession;
  final String previousSchool;
  final String grade; // e.g. "1", "KG-1", "9th"
  final String section; // e.g. "A", "B"
  final String academicGroup; // e.g. "General", "Science (Biology)"
  final String academicYear; // e.g. "2026-27"
  final String dob;
  final String gender;

  /// active | suspended | left | graduated | void (old records: dropped = left).
  final String status;
  final String statusDate;
  final String statusReason;
  final List<SchoolStudentStatusChange> statusHistory;
  final List<SchoolStudentClassChange> classHistory;
  final String photoUrl;
  final String guardianCnicUrl;
  final String bformUrl;
  final List<Map<String, String>> additionalDocuments;
  final String branchId;
  final String admissionDate;
  final String address;
  final String biometricPin;
  final String bloodGroup;
  final String emergencyContact;
  final bool parentSignatureConfirmed;

  /// Madrassa student id this record was copied from (read-only link; the
  /// madrassa record is never changed by School).
  final String transferredFromMadrassaId;
  final String transferredAt;
  final String syncStatus; // 'synced', 'pending', 'failed'
  final String lastModified;

  SchoolStudent({
    required this.id,
    String? admissionNo,
    required this.rollNo,
    required this.name,
    required this.guardianName,
    required this.guardianPhone,
    this.guardianCnic = '',
    this.bformNo = '',
    this.fatherProfession = '',
    this.previousSchool = '',
    required this.grade,
    this.section = 'A',
    this.academicGroup = 'General',
    this.academicYear = '',
    this.dob = '',
    this.gender = 'Male',
    this.status = 'active',
    this.statusDate = '',
    this.statusReason = '',
    this.statusHistory = const [],
    this.classHistory = const [],
    this.photoUrl = '',
    this.guardianCnicUrl = '',
    this.bformUrl = '',
    this.additionalDocuments = const [],
    required this.branchId,
    required this.admissionDate,
    this.address = '',
    this.biometricPin = '',
    this.bloodGroup = '',
    this.emergencyContact = '',
    this.parentSignatureConfirmed = false,
    this.transferredFromMadrassaId = '',
    this.transferredAt = '',
    this.syncStatus = 'synced',
    this.lastModified = '',
  }) : admissionNo = admissionNo ?? rollNo;

  /// Old records used "dropped" for students who left.
  static String normalizeStatus(String? raw) {
    final s = (raw ?? '').trim().toLowerCase();
    if (s.isEmpty) return 'active';
    if (s == 'dropped' || s == 'withdrawn' || s == 'inactive') return 'left';
    return s;
  }

  bool get isVoid => status == 'void';
  bool get isActive => status == 'active';

  int get documentCount =>
      (photoUrl.isNotEmpty ? 1 : 0) +
      (guardianCnicUrl.isNotEmpty ? 1 : 0) +
      (bformUrl.isNotEmpty ? 1 : 0) +
      additionalDocuments.where((d) => (d['url'] ?? '').isNotEmpty).length;

  factory SchoolStudent.fromMap(String id, Map<String, dynamic> map) {
    final docs = <Map<String, String>>[];
    if (map['additionalDocuments'] is List) {
      for (final item in map['additionalDocuments']) {
        if (item is Map) {
          docs.add({
            'name': item['name']?.toString() ?? 'Document',
            'url': item['url']?.toString() ?? '',
          });
        }
      }
    }
    List<T> list<T>(Object? raw, T Function(Map) f) =>
        raw is List ? raw.whereType<Map>().map(f).toList() : <T>[];

    final roll = map['rollNo']?.toString() ?? map['admissionNo']?.toString() ?? '';
    final adm = map['admissionNo']?.toString() ?? roll;

    return SchoolStudent(
      id: id,
      admissionNo: adm,
      rollNo: roll,
      name: map['name']?.toString() ?? 'Unknown',
      guardianName: map['guardianName']?.toString() ?? map['fatherName']?.toString() ?? '',
      guardianPhone: map['guardianPhone']?.toString() ?? map['phone']?.toString() ?? '',
      guardianCnic: map['guardianCnic']?.toString() ?? map['fatherCnic']?.toString() ?? '',
      bformNo: map['bformNo']?.toString() ?? map['bForm']?.toString() ?? '',
      fatherProfession: map['fatherProfession']?.toString() ?? map['profession']?.toString() ?? '',
      previousSchool: map['previousSchool']?.toString() ?? map['prevSchool']?.toString() ?? '',
      grade: map['grade']?.toString() ?? '1',
      section: map['section']?.toString() ?? 'A',
      academicGroup: map['academicGroup']?.toString() ?? map['stream']?.toString() ?? 'General',
      academicYear: map['academicYear']?.toString() ?? '',
      dob: map['dob']?.toString() ?? '',
      gender: (map['gender']?.toString().isNotEmpty ?? false) ? map['gender'].toString() : 'Male',
      status: normalizeStatus(map['status']?.toString()),
      statusDate: map['statusDate']?.toString() ?? '',
      statusReason: map['statusReason']?.toString() ?? '',
      statusHistory: list(map['statusHistory'], SchoolStudentStatusChange.fromMap),
      classHistory: list(map['classHistory'], SchoolStudentClassChange.fromMap),
      photoUrl: map['photoUrl']?.toString() ?? '',
      guardianCnicUrl: map['guardianCnicUrl']?.toString() ?? '',
      bformUrl: map['bformUrl']?.toString() ?? '',
      additionalDocuments: docs,
      branchId: map['branchId']?.toString() ?? '',
      admissionDate: map['admissionDate']?.toString() ?? '',
      address: map['address']?.toString() ?? '',
      biometricPin: map['biometricPin']?.toString() ?? '',
      bloodGroup: map['bloodGroup']?.toString() ?? '',
      emergencyContact: map['emergencyContact']?.toString() ?? '',
      parentSignatureConfirmed: map['parentSignatureConfirmed'] == true,
      transferredFromMadrassaId: map['transferredFromMadrassaId']?.toString() ?? '',
      transferredAt: map['transferredAt']?.toString() ?? '',
      syncStatus: map['syncStatus']?.toString() ?? 'synced',
      lastModified: map['lastModified']?.toString() ?? '',
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'rollNo': rollNo,
      'admissionNo': admissionNo,
      'name': name,
      'guardianName': guardianName,
      'fatherName': guardianName,
      'guardianPhone': guardianPhone,
      'phone': guardianPhone,
      'guardianCnic': guardianCnic,
      'fatherCnic': guardianCnic,
      'bformNo': bformNo,
      'bForm': bformNo,
      'fatherProfession': fatherProfession,
      'profession': fatherProfession,
      'previousSchool': previousSchool,
      'prevSchool': previousSchool,
      'grade': grade,
      'section': section,
      'academicGroup': academicGroup,
      'academicYear': academicYear,
      'dob': dob,
      'gender': gender,
      'status': status,
      'statusDate': statusDate,
      'statusReason': statusReason,
      'statusHistory': statusHistory.map((e) => e.toMap()).toList(),
      'classHistory': classHistory.map((e) => e.toMap()).toList(),
      'photoUrl': photoUrl,
      'guardianCnicUrl': guardianCnicUrl,
      'bformUrl': bformUrl,
      'additionalDocuments': additionalDocuments,
      'branchId': branchId,
      'admissionDate': admissionDate,
      'address': address,
      'biometricPin': biometricPin,
      'bloodGroup': bloodGroup,
      'emergencyContact': emergencyContact,
      'parentSignatureConfirmed': parentSignatureConfirmed,
      'transferredFromMadrassaId': transferredFromMadrassaId,
      'transferredAt': transferredAt,
      'syncStatus': syncStatus,
      'lastModified': lastModified,
    };
  }

  SchoolStudent copyWith({
    String? admissionNo,
    String? rollNo,
    String? name,
    String? guardianName,
    String? guardianPhone,
    String? guardianCnic,
    String? bformNo,
    String? fatherProfession,
    String? previousSchool,
    String? grade,
    String? section,
    String? academicGroup,
    String? academicYear,
    String? dob,
    String? gender,
    String? status,
    String? photoUrl,
    String? guardianCnicUrl,
    String? bformUrl,
    List<Map<String, String>>? additionalDocuments,
    String? branchId,
    String? admissionDate,
    String? address,
    String? biometricPin,
  }) {
    return SchoolStudent(
      id: id,
      admissionNo: admissionNo ?? this.admissionNo,
      rollNo: rollNo ?? this.rollNo,
      name: name ?? this.name,
      guardianName: guardianName ?? this.guardianName,
      guardianPhone: guardianPhone ?? this.guardianPhone,
      guardianCnic: guardianCnic ?? this.guardianCnic,
      bformNo: bformNo ?? this.bformNo,
      fatherProfession: fatherProfession ?? this.fatherProfession,
      previousSchool: previousSchool ?? this.previousSchool,
      grade: grade ?? this.grade,
      section: section ?? this.section,
      academicGroup: academicGroup ?? this.academicGroup,
      academicYear: academicYear ?? this.academicYear,
      dob: dob ?? this.dob,
      gender: gender ?? this.gender,
      status: status ?? this.status,
      statusDate: statusDate,
      statusReason: statusReason,
      statusHistory: statusHistory,
      classHistory: classHistory,
      photoUrl: photoUrl ?? this.photoUrl,
      guardianCnicUrl: guardianCnicUrl ?? this.guardianCnicUrl,
      bformUrl: bformUrl ?? this.bformUrl,
      additionalDocuments: additionalDocuments ?? this.additionalDocuments,
      branchId: branchId ?? this.branchId,
      admissionDate: admissionDate ?? this.admissionDate,
      address: address ?? this.address,
      biometricPin: biometricPin ?? this.biometricPin,
      bloodGroup: bloodGroup,
      emergencyContact: emergencyContact,
      parentSignatureConfirmed: parentSignatureConfirmed,
      transferredFromMadrassaId: transferredFromMadrassaId,
      transferredAt: transferredAt,
      syncStatus: syncStatus,
      lastModified: lastModified,
    );
  }
}
