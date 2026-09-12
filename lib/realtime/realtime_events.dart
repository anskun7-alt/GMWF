import 'dart:math';

class RealtimeEvents {
  // ---- Core protocol keys ----
  static const String eventType = 'event_type';
  static const String data = 'data';
  static const String branchId = 'branchId';
  static const String timestamp = 'timestamp';
  static const String clientId = 'client_id';
  static const String senderId = 'sender_id';
  static const String senderRole = '_senderRole';

  // ---- Event types ----
  static const String savePatient = 'save_patient';
  static const String deletePatient = 'delete_patient';

  static const String saveEntry = 'save_entry';
  static const String deleteEntry = 'delete_entry';

  static const String saveUser = 'save_user';
  static const String deleteUser = 'delete_user';

  static const String savePrescription = 'save_prescription';
  static const String deletePrescription = 'delete_prescription';

  static const String saveStockItem = 'save_stock_item';
  static const String deleteStockItem = 'delete_stock_item';

  static const String saveBranch = 'save_branch';
  static const String deleteBranch = 'delete_branch';

  // ---- Employee & Staff Events ----
  static const String saveEmployee = 'save_employee';
  static const String deleteEmployee = 'delete_employee';
  static const String saveBiometricDevice = 'save_biometric_device';
  static const String deleteBiometricDevice = 'delete_biometric_device';

  // ---- Additional events ----
  static const String tokenCreated = 'token_created';
  static const String tokenUpdated = 'token_updated';
  static const String tokenStatusChanged = 'token_status_changed';
  static const String prescriptionCreated = 'prescription_created';
  static const String dispenseCompleted = 'dispense_completed';
  static const String tokenExceptionRequest = 'token_exception_request';
  static const String tokenExceptionApproved = 'token_exception_approved';
  static const String tokenReversalApproved = 'token_reversal_approved';
  static const String saveProformaItem = 'save_proforma_item';
  static const String proformaItemUpdated = 'proforma_item_updated';
  static const String requestCreated = 'request_created';
  static const String requestApproved = 'request_approved';
  static const String requestRejected = 'request_rejected';

  // Offline-first workflow requests are persisted and synchronized by the
  // LAN server rather than written directly by client screens.
  static const String workflowRequest = 'workflow_request';
  static const String workflowDecision = 'workflow_decision';

  // ---- Attendance Events ----
  static const String saveBiometricLog = 'save_biometric_log';
  static const String saveEmployeeAttendance = 'save_employee_attendance';
  static const String saveFacultyAttendance = 'save_faculty_attendance';
  static const String saveStudentAttendance = 'save_student_attendance';

  // ---- Madrassa & School Events ----
  static const String saveMadrassaAdmission = 'save_madrassa_admission';
  static const String saveMadrassaStudent = 'save_madrassa_student';
  static const String saveMadrassaAttendance = 'save_madrassa_attendance';
  static const String deleteMadrassaStudent = 'delete_madrassa_student';
  static const String offboardMadrassaStudent = 'offboard_madrassa_student';
  static const String saveMadrassaFee = 'save_madrassa_fee';
  static const String saveMadrassaFeePayment = 'save_madrassa_fee_payment';
  static const String saveMadrassaDailyLog = 'save_madrassa_daily_log';
  static const String saveMadrassaHifzProgress = 'save_madrassa_hifz_progress';
  static const String saveExamResult = 'save_exam_result';

  // ---- Finance Events ----
  static const String saveExpense = 'save_expense';
  static const String deleteExpense = 'delete_expense';
  static const String saveLoan = 'save_loan';
  static const String deleteLoan = 'delete_loan';
  static const String saveFinanceEntry = 'save_finance_entry';

  // ---- Donations Events ----
  static const String saveDonationReceipt = 'save_donation_receipt';
  static const String saveDonor = 'save_donor';
  static const String saveDonationCollection = 'save_donation_collection';

  // ---- Dasterkhwaan Events ----
  static const String saveDasterkhwanEntry = 'save_dasterkhwan_entry';
  static const String saveDasterkhwanStock = 'save_dasterkhwan_stock';
  static const String saveOfficeBoyToken = 'save_office_boy_token';
  static const String saveKitchenServeLog = 'save_kitchen_serve_log';

  // ---- Library Events ----
  static const String saveLibraryBook = 'save_library_book';
  static const String saveLibraryIssue = 'save_library_issue';
  static const String deleteLibraryBook = 'delete_library_book';

  // ---- Faculty & Staff Events ----
  static const String saveFaculty = 'save_faculty';
  static const String saveStaffProfile = 'save_staff_profile';

  // ---- Supervisor Events ----
  static const String saveSupervisorAction = 'save_supervisor_action';
  static const String approveEditRequest = 'approve_edit_request';
  static const String rejectEditRequest = 'reject_edit_request';

  // ---- Connection events ----
  static const String clientConnected = 'client_connected';
  static const String clientDisconnected = 'client_disconnected';
  static const String clientListUpdate = 'client_list_update';
  static const String clientCountUpdate = 'client_count_update';
  static const String identify = 'identify';
  static const String identified = 'identified';
  static const String identifyRequest = 'identify_request';

  /// CRITICAL: Creates payload with branchId ONLY at top level
  /// This prevents routing confusion where branchId appears in multiple places
  static Map<String, dynamic> payload({
    required String type,
    required Map<String, dynamic> data,
    String? branchId,
    String? senderId,
  }) {
    // Make a clean copy of data WITHOUT branchId to avoid duplicates
    final cleanData = Map<String, dynamic>.from(data);
    cleanData.remove('branchId'); // Remove if accidentally included in data
    
    final msgId = 'msg_${DateTime.now().microsecondsSinceEpoch}_${Random().nextInt(999999)}';
    final version = (data['version'] is int)
        ? (data['version'] as int)
        : (int.tryParse(data['version']?.toString() ?? '') ?? DateTime.now().millisecondsSinceEpoch);
    final deviceId = (data['deviceId'] ?? data['device_id'] ?? data['_deviceId'])?.toString() ?? 'device_local';

    final map = {
      eventType: type,
      'messageId': msgId,
      '_messageId': msgId,
      'version': version,
      'deviceId': deviceId,
      RealtimeEvents.data: cleanData,
      RealtimeEvents.timestamp: DateTime.now().toIso8601String(),
    };

    // Add branchId ONLY at top level if provided
    if (branchId != null && branchId.isNotEmpty) {
      map[RealtimeEvents.branchId] = branchId;
    }

    if (senderId != null) {
      map[RealtimeEvents.senderId] = senderId;
    }

    return map;
  }

  /// Creates a complete prescription payload with ALL required fields
  /// This ensures no data loss during transmission
  static Map<String, dynamic> prescriptionPayload({
    required String prescriptionId,
    required String serial,
    required String patientId,
    required String patientName,
    required String patientAge,
    required String patientGender,
    required String doctorId,
    required String doctorName,
    required String complaint,
    required String diagnosis,
    required List<Map<String, dynamic>> medicines,
    required List<Map<String, dynamic>> labTests,
    String? notes,
    required String tokenNumber,
    required String branchId,
    String status = 'completed',
    Map<String, dynamic>? vitals,
    String? queueType,
  }) {
    return {
      'id': prescriptionId,
      'serial': serial,
      'patientId': patientId,
      'patientName': patientName,
      'patientAge': patientAge,
      'patientGender': patientGender,
      'patientCnic': patientId, // Usually CNIC is used as patientId
      'doctorId': doctorId,
      'doctorName': doctorName,
      'complaint': complaint,
      'condition': complaint, // Include both for compatibility
      'diagnosis': diagnosis,
      'prescriptions': medicines.map((med) => {
        'name': med['name'],
        'quantity': med['quantity'],
        'type': med['type'] ?? 'Tablet',
        'timing': med['timing'] ?? '',
        'meal': med['meal'] ?? '',
        'dosage': med['dosage'] ?? '',
        'inventoryId': med['inventoryId'],
      }).toList(),
      'labResults': labTests.map((lab) => {
        'name': lab['name'],
      }).toList(),
      'notes': notes,
      'tokenNumber': tokenNumber,
      'status': status,
      'createdAt': DateTime.now().toIso8601String(),
      'completedAt': DateTime.now().toIso8601String(),
      'updatedAt': DateTime.now().toIso8601String(),
      'updatedBy': doctorName,
      if (vitals != null) 'vitals': vitals,
      if (queueType != null) 'queueType': queueType,
    };
  }

  /// Creates a complete token/entry payload
  static Map<String, dynamic> tokenPayload({
    required String serial,
    required String patientId,
    required String patientName,
    required String branchId,
    String? patientCnic,
    String? guardianCnic,
    required String queueType,
    required Map<String, dynamic> vitals,
    required String createdBy,
    required String createdByName,
    String status = 'waiting',
  }) {
    final parts = serial.split('-');
    final dateKey = (parts.isNotEmpty && parts[0].toUpperCase() == 'X')
        ? (parts.length > 1 ? parts[1] : '')
        : (parts.isNotEmpty ? parts[0] : '');
    
    return {
      'serial': serial,
      'patientId': patientId,
      'patientName': patientName,
      'patientCnic': patientCnic ?? guardianCnic ?? '',
      if (patientCnic != null && patientCnic.isNotEmpty) 'cnic': patientCnic,
      if (guardianCnic != null && guardianCnic.isNotEmpty) 'guardianCnic': guardianCnic,
      'queueType': queueType,
      'vitals': vitals,
      'status': status,
      'createdAt': DateTime.now().toIso8601String(),
      'createdBy': createdBy,
      'createdByName': createdByName,
      'dateKey': dateKey,
    };
  }

  /// Validation helper
  static bool isValid(Map<String, dynamic> message) {
    return message.containsKey(eventType) && message[eventType] != null;
  }

  /// Extract branchId from message (checks both top level and data)
  static String? branchIdOf(Map<String, dynamic> message) {
    // Priority: top level first, then data
    return message[branchId]?.toString() ?? 
           (message[data] as Map<String, dynamic>?)?[branchId]?.toString();
  }

  /// Extract sender ID from message
  static String? senderIdOf(Map<String, dynamic> message) {
    return message[senderId]?.toString() ?? 
           message[senderRole]?.toString();
  }
}
