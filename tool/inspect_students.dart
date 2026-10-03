import 'dart:io';
import 'package:hive/hive.dart';

void main() async {
  final hiveDir = 'C:\\Users\\win\\AppData\\Roaming\\com.example\\gmwf\\gmwf_hive';
  Hive.init(hiveDir);
  final bioBox = await Hive.openBox('local_biometric_credentials');
  final userBox = await Hive.openBox('local_users');
  final stdBox = await Hive.openBox('local_madrassa_students');

  // Build guardian map by student ID
  final guardianByStudentId = <String, Map<String, dynamic>>{};
  for (final k in userBox.keys) {
    final v = userBox.get(k);
    if (v is Map) {
      final sIds = v['studentIds'];
      if (sIds is List) {
        for (final sId in sIds) {
          final idStr = sId.toString().trim();
          guardianByStudentId[idStr] = {
            'guardianName': (v['name'] ?? '').toString().trim(),
            'guardianCnic': (v['cnic'] ?? '').toString().trim(),
            'contactPhone': (v['phone'] ?? '').toString().trim(),
          };
        }
      }
    }
  }

  int updated = 0;
  for (final k in bioBox.keys) {
    final v = bioBox.get(k);
    if (v is Map && v['entityType'] == 'madrassa_student') {
      final rawBranch = (v['branchId'] ?? 'gujrat').toString().toLowerCase().trim();
      final branch = rawBranch == 'karachi' ? 'gujrat' : rawBranch; // fix misplaced karachi branch
      final id = k.toString().replaceAll(RegExp(r'^(gujrat__std__|karachi__std__)+'), '').trim();
      final realStudentName = (v['entityName'] ?? '').toString().trim();
      final pin = (v['biometricPin'] ?? '').toString().trim();

      if (realStudentName.isEmpty || realStudentName == 'Madrassa Student') continue;

      final gInfo = guardianByStudentId[id] ?? {};
      final stdKey = '${branch}__std__$id';
      final existing = stdBox.get(stdKey);
      final prevMap = (existing is Map) ? Map<String, dynamic>.from(existing) : <String, dynamic>{};

      // Determine proper roll number from pin or existing
      final pinInt = int.tryParse(pin);
      String rollNumber = prevMap['rollNumber']?.toString() ?? '';
      if (rollNumber.isEmpty || rollNumber == 'null') {
        if (pinInt != null && pinInt >= 3001 && pinInt <= 3050) {
          rollNumber = (pinInt - 3000).toString();
        }
      }

      final studentRecord = <String, dynamic>{
        ...prevMap,
        'id': id,
        'branchId': branch,
        'name': realStudentName,
        'studentName': realStudentName,
        'biometricPin': pin,
        'pin': pin,
        'rollNumber': rollNumber.isNotEmpty ? rollNumber : prevMap['rollNumber'] ?? '1',
        'class': prevMap['class'] ?? 'Hifz',
        'status': prevMap['status'] ?? 'active',
        'batch': prevMap['batch'] ?? 'active',
        if (gInfo['guardianName'] != null && gInfo['guardianName'].isNotEmpty)
          'guardianName': gInfo['guardianName'],
        if (gInfo['contactPhone'] != null && gInfo['contactPhone'].isNotEmpty)
          'contactPhone': gInfo['contactPhone'],
        if (gInfo['guardianCnic'] != null && gInfo['guardianCnic'].isNotEmpty)
          'guardianCnic': gInfo['guardianCnic'],
        'lastUpdatedAt': DateTime.now().toIso8601String(),
      };

      await stdBox.put(stdKey, studentRecord);
      updated++;
      print('Repaired: Roll $rollNumber => Student: "$realStudentName", Guardian: "${studentRecord['guardianName']}", PIN: $pin');
    }
  }

  await stdBox.flush();
  print('Successfully updated $updated student records in local_madrassa_students box.');
  exit(0);
}
