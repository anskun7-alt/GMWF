// lib/services/staff_patient_link_service.dart

import 'package:flutter/material.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:gmwf/services/local_storage_service.dart';
import 'package:gmwf/pages/dispensary/doctor/patient_history.dart';

class StaffPatientLinkService {
  /// Normalizes a CNIC string by stripping non-digit characters.
  static String normalizeCnic(String? cnic) {
    if (cnic == null) return '';
    return cnic.replaceAll(RegExp(r'\D'), '').trim();
  }

  /// Normalizes a human name (lowercase, trims, removes punctuation).
  static String normalizeName(String? name) {
    if (name == null) return '';
    return name.toLowerCase().replaceAll(RegExp(r'[^a-z0-9\s]'), '').trim();
  }

  /// High-level method that safely inspects a patient object map.
  /// Rule: Children cannot be staff members; only adults can be staff.
  static Map<String, dynamic>? getStaffInfoFromPatientMap(Map<String, dynamic>? patient) {
    if (patient == null) return null;

    // 1. Explicit child / adult flags
    if (patient['isAdult'] == false) return null;
    if (patient['isChild'] == true) return null;

    // 2. Age check: minors under 18 cannot be staff
    final rawAge = patient['age'] ?? patient['calculatedAge'];
    final parsedAge = rawAge is num ? rawAge.toInt() : int.tryParse(rawAge?.toString() ?? '');
    if (parsedAge != null && parsedAge > 0 && parsedAge < 18) {
      return null;
    }

    // 3. Child identity markers (e.g. relation or child ID)
    final rel = (patient['relation'] ?? patient['relationship'] ?? '').toString().trim().toLowerCase();
    if (rel == 'child' || rel == 'son' || rel == 'daughter' || rel == 'infant' || rel == 'kid') {
      return null;
    }

    final pId = (patient['id'] ?? patient['patientId'] ?? '').toString().toLowerCase();
    if (pId.contains('_child_')) return null;

    // 4. Guardian CNIC without personal adult CNIC implies a dependent child
    final gCnic = normalizeCnic(patient['guardianCnic']?.toString() ?? patient['parentCnic']?.toString());
    final pCnic = normalizeCnic(patient['cnic']?.toString() ?? patient['patientCnic']?.toString());
    if (gCnic.isNotEmpty && pCnic.isEmpty && patient['isAdult'] != true) {
      return null;
    }

    final effectiveCnic = pCnic.isNotEmpty ? pCnic : (patient['isAdult'] == true ? gCnic : null);
    if (effectiveCnic == null || effectiveCnic.isEmpty) {
      // Strict requirement: A patient must have a valid CNIC to be verified as a staff member
      return null;
    }
    final effectiveName = (patient['name'] ?? patient['patientName'])?.toString();

    return getStaffInfoForPatient(
      cnic: effectiveCnic,
      name: effectiveName,
      isAdult: patient['isAdult'],
      age: parsedAge,
    );
  }

  /// Looks up whether a patient with [cnic] is a registered staff member/employee.
  /// Returns a map with staff role, designation, branch, and name, or null if not staff.
  /// STRICT: Only matches via CNIC. Name-only matches are forbidden to prevent
  /// unrelated patients who share the same name as staff (e.g. IT Head) from being assigned staff roles.
  static Map<String, dynamic>? getStaffInfoForPatient({
    String? cnic,
    String? name,
    bool? isAdult,
    dynamic age,
    dynamic isChild,
  }) {
    // A child cannot be an employee or staff member
    if (isAdult == false || isChild == true) return null;
    if (age != null) {
      final parsedAge = age is num ? age.toInt() : int.tryParse(age.toString().trim());
      if (parsedAge != null && parsedAge > 0 && parsedAge < 18) {
        return null;
      }
    }

    final cleanCnic = normalizeCnic(cnic);

    // CNIC is strictly required to verify an employee/staff member
    if (cleanCnic.isEmpty) return null;

    // 1. Search in local_employees
    if (Hive.isBoxOpen(LocalStorageService.employeesBox)) {
      final empBox = Hive.box(LocalStorageService.employeesBox);
      for (final key in empBox.keys) {
        final val = empBox.get(key);
        if (val is! Map) continue;
        final emp = Map<String, dynamic>.from(val);

        if (emp['isActive'] == false) continue;

        final empCnic = normalizeCnic(emp['cnic']?.toString());

        // Strictly match by CNIC only
        if (empCnic.isNotEmpty && cleanCnic == empCnic) {
          final role = (emp['role'] ?? emp['designation'] ?? 'Staff').toString();
          final dept = (emp['department'] ?? 'Office').toString();
          final branch = (emp['branchId'] ?? 'Main').toString();
          final displayName = (emp['name'] ?? emp['employeeName'] ?? name ?? 'Staff').toString();

          return {
            'isStaff': true,
            'role': role,
            'department': dept,
            'branchId': branch,
            'name': displayName,
            'employeeId': emp['localId'] ?? key,
            'userId': emp['userId'],
          };
        }
      }
    }

    // 2. Search in local_users as fallback
    if (Hive.isBoxOpen(LocalStorageService.usersBox)) {
      final uBox = Hive.box(LocalStorageService.usersBox);
      for (final key in uBox.keys) {
        final val = uBox.get(key);
        if (val is! Map) continue;
        final user = Map<String, dynamic>.from(val);

        final roleLower = (user['role'] ?? '').toString().toLowerCase();
        if (roleLower.contains('server') || user['isServerAccount'] == true) continue;

        final uCnic = normalizeCnic(user['cnic']?.toString());

        // Strictly match by CNIC only
        if (uCnic.isNotEmpty && cleanCnic == uCnic) {
          final role = (user['role'] ?? 'Staff').toString();
          final branch = (user['branchId'] ?? 'Main').toString();
          final displayName = (user['name'] ?? user['username'] ?? name ?? 'Staff').toString();

          return {
            'isStaff': true,
            'role': role,
            'department': user['department'] ?? 'General',
            'branchId': branch,
            'name': displayName,
            'userId': user['uid'] ?? key,
          };
        }
      }
    }

    return null;
  }

  /// Locates patient data for a staff member using their CNIC or Name.
  /// Checks local_patients first, then reconstructs from local_prescriptions if needed.
  static Map<String, dynamic>? getPatientForStaff({
    String? cnic,
    String? name,
    String? userId,
  }) {
    final cleanCnic = normalizeCnic(cnic);
    final cleanName = normalizeName(name);

    if (cleanCnic.isEmpty && cleanName.isEmpty) return null;

    // 1. Check local_patients
    if (Hive.isBoxOpen(LocalStorageService.patientsBox)) {
      final pBox = Hive.box(LocalStorageService.patientsBox);

      // Direct CNIC lookup
      if (cleanCnic.isNotEmpty) {
        final direct = pBox.get(cleanCnic);
        if (direct is Map) return Map<String, dynamic>.from(direct);
      }

      // Linear search
      for (final key in pBox.keys) {
        final val = pBox.get(key);
        if (val is! Map) continue;
        final p = Map<String, dynamic>.from(val);
        final pCnic = normalizeCnic(p['cnic']?.toString() ?? p['patientCnic']?.toString());
        final pName = normalizeName(p['name']?.toString() ?? p['patientName']?.toString());

        if ((cleanCnic.isNotEmpty && pCnic == cleanCnic) ||
            (cleanName.isNotEmpty && pName == cleanName)) {
          return p;
        }
      }
    }

    // 2. Check local_prescriptions for matching clinical history
    if (Hive.isBoxOpen(LocalStorageService.prescriptionsBox)) {
      final prBox = Hive.box(LocalStorageService.prescriptionsBox);
      for (final key in prBox.keys) {
        final val = prBox.get(key);
        if (val is! Map) continue;
        final pr = Map<String, dynamic>.from(val);
        final prCnic = normalizeCnic(pr['patientCnic']?.toString() ?? pr['cnic']?.toString());
        final prName = normalizeName(pr['patientName']?.toString() ?? pr['name']?.toString());

        if ((cleanCnic.isNotEmpty && prCnic == cleanCnic) ||
            (cleanName.isNotEmpty && prName == cleanName)) {
          return {
            'id': pr['patientId'] ?? 'staff_${cleanCnic.isNotEmpty ? cleanCnic : cleanName}',
            'patientId': pr['patientId'] ?? 'staff_${cleanCnic.isNotEmpty ? cleanCnic : cleanName}',
            'name': pr['patientName'] ?? pr['name'] ?? name ?? 'Staff Member',
            'patientName': pr['patientName'] ?? pr['name'] ?? name ?? 'Staff Member',
            'cnic': pr['patientCnic'] ?? pr['cnic'] ?? cnic ?? '',
            'branchId': pr['branchId'] ?? 'all',
            'age': pr['age'] ?? 30,
            'gender': pr['gender'] ?? 'Male',
            'isStaff': true,
          };
        }
      }
    }

    return null;
  }

  /// Opens the PatientHistoryPage for a staff member immediately.
  static void openStaffMedicalHistory(
    BuildContext context, {
    required String name,
    String? cnic,
    String? branchId,
    String? role,
  }) {
    final effectiveBranch = (branchId != null && branchId.isNotEmpty && branchId != 'all')
        ? branchId
        : 'karachi';

    final patientRecord = getPatientForStaff(cnic: cnic, name: name) ?? {
      'id': 'staff_${normalizeCnic(cnic).isNotEmpty ? normalizeCnic(cnic) : normalizeName(name)}',
      'patientId': 'staff_${normalizeCnic(cnic).isNotEmpty ? normalizeCnic(cnic) : normalizeName(name)}',
      'name': name,
      'patientName': name,
      'cnic': cnic ?? '',
      'patientCnic': cnic ?? '',
      'branchId': effectiveBranch,
      'isStaff': true,
      'staffRole': role ?? 'Employee',
    };

    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => PatientHistoryPage(
          branchId: effectiveBranch,
          patientData: patientRecord,
        ),
      ),
    );
  }

  /// Builds a visual Staff Badge widget for patient cards and queue items.
  static Widget buildStaffBadge(Map<String, dynamic> staffInfo, {bool isDark = false}) {
    final role = staffInfo['role']?.toString() ?? 'Staff';
    final dept = staffInfo['department']?.toString() ?? '';
    final displayText = dept.isNotEmpty && dept != 'General' && dept != 'Office'
        ? '$role · $dept'
        : role;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF1E3A8A).withValues(alpha: 0.5) : const Color(0xFFEFF6FF),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(
          color: isDark ? const Color(0xFF60A5FA).withValues(alpha: 0.6) : const Color(0xFF3B82F6),
          width: 0.9,
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.badge_rounded,
            size: 11,
            color: isDark ? const Color(0xFF93C5FD) : const Color(0xFF2563EB),
          ),
          const SizedBox(width: 4),
          Text(
            'Staff: $displayText',
            style: TextStyle(
              fontSize: 10.5,
              fontWeight: FontWeight.w700,
              color: isDark ? const Color(0xFF93C5FD) : const Color(0xFF1D4ED8),
              letterSpacing: 0.2,
            ),
          ),
        ],
      ),
    );
  }
}
