// lib/models/donation_box_models.dart
//
// Data models for the Donation Box collection system.
// A DonationBox is a physical collection box placed at a location.
// A BoxOpening records each time a box is opened and its contents collected.

class DonationBox {
  final String id;           // Hive key / Firestore doc ID
  final String boxNumber;    // e.g. "BOX-001"
  final String holderName;   // Person who keeps the box
  final String holderPhone;  // Contact number
  final String holderAddress;// Full address
  final String area;         // Area / locality / sector
  final String branchId;
  final String branchName;
  final String registeredDate; // yyyy-MM-dd
  final bool isActive;
  final String notes;
  final String syncStatus;   // 'pending', 'synced'
  final String? firestoreId;
  final String? lastOpenedDate; // yyyy-MM-dd — last time box was opened
  final double? lastOpenedAmount;

  // ── Physical Box Lifecycle & Incident Audit ──
  final String status;       // 'active', 'snatched', 'stolen', 'broken', 'replaced', 'decommissioned'
  final String? incidentType;// 'snatched', 'stolen', 'broken'
  final String? incidentDate;// yyyy-MM-dd
  final String? incidentReportedBy;
  final String? incidentNotes;
  final String? policeReportNo;
  final double? estimatedCashLost;
  final String? replacedByBoxId;     // New box assigned if replaced
  final String? replacementForBoxId; // Previous compromised box ID

  const DonationBox({
    required this.id,
    required this.boxNumber,
    required this.holderName,
    this.holderPhone = '',
    this.holderAddress = '',
    this.area = '',
    required this.branchId,
    required this.branchName,
    required this.registeredDate,
    this.isActive = true,
    this.notes = '',
    this.syncStatus = 'pending',
    this.firestoreId,
    this.lastOpenedDate,
    this.lastOpenedAmount,
    this.status = 'active',
    this.incidentType,
    this.incidentDate,
    this.incidentReportedBy,
    this.incidentNotes,
    this.policeReportNo,
    this.estimatedCashLost,
    this.replacedByBoxId,
    this.replacementForBoxId,
  });

  factory DonationBox.fromMap(Map<dynamic, dynamic> map, String key) {
    final rawStatus = (map['status'] as String? ?? '').toLowerCase().trim();
    final isActiveVal = map['isActive'] as bool? ?? true;
    final resolvedStatus = rawStatus.isNotEmpty
        ? rawStatus
        : (isActiveVal ? 'active' : 'decommissioned');

    return DonationBox(
      id:                  key,
      boxNumber:           map['boxNumber']           ?? '',
      holderName:          map['holderName']          ?? '',
      holderPhone:         map['holderPhone']         ?? '',
      holderAddress:       map['holderAddress']       ?? '',
      area:                map['area']                ?? '',
      branchId:            map['branchId']            ?? '',
      branchName:          map['branchName']          ?? '',
      registeredDate:      map['registeredDate']      ?? '',
      isActive:            isActiveVal && resolvedStatus == 'active',
      notes:               map['notes']               ?? '',
      syncStatus:          map['syncStatus']          ?? 'pending',
      firestoreId:         map['firestoreId']         as String?,
      lastOpenedDate:      map['lastOpenedDate']      as String?,
      lastOpenedAmount:    (map['lastOpenedAmount'] as num?)?.toDouble(),
      status:              resolvedStatus,
      incidentType:        map['incidentType']        as String?,
      incidentDate:        map['incidentDate']        as String?,
      incidentReportedBy:  map['incidentReportedBy']  as String?,
      incidentNotes:       map['incidentNotes']       as String?,
      policeReportNo:      map['policeReportNo']      as String?,
      estimatedCashLost:   (map['estimatedCashLost'] as num?)?.toDouble(),
      replacedByBoxId:     map['replacedByBoxId']     as String?,
      replacementForBoxId: map['replacementForBoxId'] as String?,
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'boxNumber':           boxNumber,
      'holderName':          holderName,
      'holderPhone':         holderPhone,
      'holderAddress':       holderAddress,
      'area':                area,
      'branchId':            branchId,
      'branchName':          branchName,
      'registeredDate':      registeredDate,
      'isActive':            isActive,
      'notes':               notes,
      'syncStatus':          syncStatus,
      'status':              status,
      if (firestoreId != null) 'firestoreId': firestoreId,
      if (lastOpenedDate != null) 'lastOpenedDate': lastOpenedDate,
      if (lastOpenedAmount != null) 'lastOpenedAmount': lastOpenedAmount,
      if (incidentType != null) 'incidentType': incidentType,
      if (incidentDate != null) 'incidentDate': incidentDate,
      if (incidentReportedBy != null) 'incidentReportedBy': incidentReportedBy,
      if (incidentNotes != null) 'incidentNotes': incidentNotes,
      if (policeReportNo != null) 'policeReportNo': policeReportNo,
      if (estimatedCashLost != null) 'estimatedCashLost': estimatedCashLost,
      if (replacedByBoxId != null) 'replacedByBoxId': replacedByBoxId,
      if (replacementForBoxId != null) 'replacementForBoxId': replacementForBoxId,
    };
  }

  DonationBox copyWith({
    String? boxNumber,
    String? holderName,
    String? holderPhone,
    String? holderAddress,
    String? area,
    bool? isActive,
    String? notes,
    String? syncStatus,
    String? firestoreId,
    String? lastOpenedDate,
    double? lastOpenedAmount,
    String? status,
    String? incidentType,
    String? incidentDate,
    String? incidentReportedBy,
    String? incidentNotes,
    String? policeReportNo,
    double? estimatedCashLost,
    String? replacedByBoxId,
    String? replacementForBoxId,
  }) {
    return DonationBox(
      id:                  id,
      boxNumber:           boxNumber           ?? this.boxNumber,
      holderName:          holderName          ?? this.holderName,
      holderPhone:         holderPhone         ?? this.holderPhone,
      holderAddress:       holderAddress       ?? this.holderAddress,
      area:                area                ?? this.area,
      branchId:            branchId,
      branchName:          branchName,
      registeredDate:      registeredDate,
      isActive:            isActive            ?? this.isActive,
      notes:               notes               ?? this.notes,
      syncStatus:          syncStatus          ?? this.syncStatus,
      firestoreId:         firestoreId         ?? this.firestoreId,
      lastOpenedDate:      lastOpenedDate      ?? this.lastOpenedDate,
      lastOpenedAmount:    lastOpenedAmount    ?? this.lastOpenedAmount,
      status:              status              ?? this.status,
      incidentType:        incidentType        ?? this.incidentType,
      incidentDate:        incidentDate        ?? this.incidentDate,
      incidentReportedBy:  incidentReportedBy  ?? this.incidentReportedBy,
      incidentNotes:       incidentNotes       ?? this.incidentNotes,
      policeReportNo:      policeReportNo      ?? this.policeReportNo,
      estimatedCashLost:   estimatedCashLost   ?? this.estimatedCashLost,
      replacedByBoxId:     replacedByBoxId     ?? this.replacedByBoxId,
      replacementForBoxId: replacementForBoxId ?? this.replacementForBoxId,
    );
  }

  /// Convenience state getters
  bool get isCompromised => status == 'snatched' || status == 'stolen' || status == 'broken';
  bool get isSnatched => status == 'snatched';
  bool get isStolen => status == 'stolen';
  bool get isBroken => status == 'broken';
  bool get isReplaced => status == 'replaced';
  bool get isDecommissioned => status == 'decommissioned';

  /// Days since the box was last opened. Returns null if never opened.
  int? get daysSinceLastOpened {
    if (lastOpenedDate == null || lastOpenedDate!.isEmpty) return null;
    final last = DateTime.tryParse(lastOpenedDate!);
    if (last == null) return null;
    return DateTime.now().difference(last).inDays;
  }

  /// Whether the box is overdue (not opened for > 30 days)
  bool get isOverdue {
    if (!isActive || isCompromised || isReplaced || isDecommissioned) return false;
    final days = daysSinceLastOpened;
    if (days == null) {
      // Never opened — check if registered > 30 days ago
      final reg = DateTime.tryParse(registeredDate);
      if (reg == null) return false;
      return DateTime.now().difference(reg).inDays > 30;
    }
    return days > 30;
  }
}

class BoxOpening {
  final String id;          // Hive key / Firestore doc ID
  final String boxId;       // Reference to DonationBox.id
  final String boxNumber;   // Denormalized for display
  final String openDate;    // yyyy-MM-dd
  final double amount;
  final String collectedBy;
  final String branchId;
  final String branchName;
  final String notes;
  final String syncStatus;  // 'pending', 'synced'
  final String? firestoreId;
  final String? timestamp;
  final String? physicalReceiptNo; // Paper/manual receipt book #

  const BoxOpening({
    required this.id,
    required this.boxId,
    required this.boxNumber,
    required this.openDate,
    required this.amount,
    required this.collectedBy,
    required this.branchId,
    required this.branchName,
    this.notes = '',
    this.syncStatus = 'pending',
    this.firestoreId,
    this.timestamp,
    this.physicalReceiptNo,
  });

  factory BoxOpening.fromMap(Map<dynamic, dynamic> map, String key) {
    return BoxOpening(
      id:                key,
      boxId:             map['boxId']             ?? '',
      boxNumber:         map['boxNumber']         ?? '',
      openDate:          map['openDate']          ?? '',
      amount:            (map['amount'] as num?)?.toDouble() ?? 0.0,
      collectedBy:       map['collectedBy']       ?? '',
      branchId:          map['branchId']          ?? '',
      branchName:        map['branchName']        ?? '',
      notes:             map['notes']             ?? '',
      syncStatus:        map['syncStatus']        ?? 'pending',
      firestoreId:       map['firestoreId']       as String?,
      timestamp:         map['timestamp']         as String?,
      physicalReceiptNo: (map['physicalReceiptNo'] ?? map['bookReceiptNo']) as String?,
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'boxId':             boxId,
      'boxNumber':         boxNumber,
      'openDate':          openDate,
      'amount':            amount,
      'collectedBy':       collectedBy,
      'branchId':          branchId,
      'branchName':        branchName,
      'notes':             notes,
      'syncStatus':        syncStatus,
      if (firestoreId != null) 'firestoreId': firestoreId,
      if (timestamp != null) 'timestamp': timestamp,
      if (physicalReceiptNo != null && physicalReceiptNo!.isNotEmpty)
        'physicalReceiptNo': physicalReceiptNo,
    };
  }

  BoxOpening copyWith({
    String? syncStatus,
    String? firestoreId,
    String? physicalReceiptNo,
  }) {
    return BoxOpening(
      id:                id,
      boxId:             boxId,
      boxNumber:         boxNumber,
      openDate:          openDate,
      amount:            amount,
      collectedBy:       collectedBy,
      branchId:          branchId,
      branchName:        branchName,
      notes:             notes,
      syncStatus:        syncStatus        ?? this.syncStatus,
      firestoreId:       firestoreId       ?? this.firestoreId,
      timestamp:         timestamp,
      physicalReceiptNo: physicalReceiptNo ?? this.physicalReceiptNo,
    );
  }
}

/// Person-level audit summary showing lifetime money output vs accidents/incidents
class PersonBoxAuditSummary {
  final String personName;
  final String phone;
  final String area;
  final String branchId;
  final String branchName;
  final int totalBoxesAssigned;
  final int activeBoxesCount;
  final int compromisedBoxesCount;
  final int snatchedCount;
  final int stolenCount;
  final int brokenCount;
  final int replacedCount;
  final double totalMoneyOutput;
  final double totalEstimatedCashLost;
  final int totalOpeningsCount;
  final String? lastOpenedDate;
  final List<DonationBox> boxes;

  const PersonBoxAuditSummary({
    required this.personName,
    required this.phone,
    this.area = '',
    required this.branchId,
    required this.branchName,
    required this.totalBoxesAssigned,
    required this.activeBoxesCount,
    required this.compromisedBoxesCount,
    this.snatchedCount = 0,
    this.stolenCount = 0,
    this.brokenCount = 0,
    this.replacedCount = 0,
    required this.totalMoneyOutput,
    this.totalEstimatedCashLost = 0.0,
    this.totalOpeningsCount = 0,
    this.lastOpenedDate,
    required this.boxes,
  });

  int get totalIncidents => snatchedCount + stolenCount + brokenCount;

  /// Risk rating based on accidents vs money output
  String get riskRating {
    if (totalIncidents >= 2) return 'High Accident Risk';
    if (totalIncidents == 1) return 'Incident Reported';
    if (totalMoneyOutput > 50000) return 'Top Output / Trusted';
    return 'Normal / Stable';
  }
}

/// Yearly report data for a single month
class BoxMonthlyReport {
  final int month;           // 1-12
  final String monthName;    // "January", "February", etc.
  final bool wasOpened;
  final String? openDate;    // Date within the month it was opened
  final double amount;       // 0 if not opened
  final String? collectedBy;
  final String? notes;

  const BoxMonthlyReport({
    required this.month,
    required this.monthName,
    required this.wasOpened,
    this.openDate,
    this.amount = 0.0,
    this.collectedBy,
    this.notes,
  });
}
