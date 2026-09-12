// lib/pages/dispensary/doctor/patient_info.dart (updated)

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:hive/hive.dart';
import 'package:another_flushbar/flushbar.dart';
import '../../../services/local_storage_service.dart';
import '../../../realtime/realtime_manager.dart';
import '../../../realtime/realtime_events.dart';

class PatientInfo extends StatelessWidget {
  final Map<String, dynamic>? patientData;
  final String? doctorId;
  final String? doctorName;
  final String? branchId;
  final ValueChanged<Map<String, dynamic>>? onVitalsUpdated;
  final VoidCallback? onSkipPatient;

  const PatientInfo({
    super.key,
    required this.patientData,
    this.doctorId,
    this.doctorName,
    this.branchId,
    this.onVitalsUpdated,
    this.onSkipPatient,
  });

  static const Color _teal  = Color(0xFF00695C);
  static const Color _amber = Color(0xFFFFA000);

  Widget _buildVital({
    required String label,
    required String value,
    required IconData icon,
    required Color backgroundColor,
    required bool compact,
    String? auditSubtext,
  }) {
    return Container(
      padding: EdgeInsets.symmetric(
        vertical: compact ? 6 : 10,
        horizontal: compact ? 4 : 8,
      ),
      margin: EdgeInsets.symmetric(horizontal: compact ? 2.5 : 4),
      decoration: BoxDecoration(
        color: backgroundColor,
        borderRadius: BorderRadius.circular(compact ? 10 : 14),
        boxShadow: [
          BoxShadow(
            color: backgroundColor.withValues(alpha: 0.35),
            blurRadius: 7,
            offset: const Offset(0, 3),
          ),
        ],
      ),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, color: Colors.white.withValues(alpha: 0.95), size: compact ? 13 : 17),
              const SizedBox(width: 5),
              Flexible(
                child: Text(
                  label,
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.95),
                    fontWeight: FontWeight.bold,
                    fontSize: compact ? 10 : 12.5,
                    letterSpacing: 0.3,
                  ),
                  textAlign: TextAlign.center,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            value,
            style: TextStyle(
              color: Colors.white,
              fontWeight: FontWeight.w900,
              fontSize: compact ? 13 : 18,
              letterSpacing: 0.4,
            ),
            textAlign: TextAlign.center,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          if (auditSubtext != null && auditSubtext.isNotEmpty) ...[
            const SizedBox(height: 2),
            Text(
              auditSubtext,
              style: TextStyle(
                color: Colors.white.withValues(alpha: 0.9),
                fontSize: compact ? 8 : 10,
                fontStyle: FontStyle.italic,
                fontWeight: FontWeight.w500,
              ),
              textAlign: TextAlign.center,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ],
      ),
    );
  }

  void _showEditVitalsDialog(BuildContext context, Map<String, dynamic> patient) {
    final vitals = Map<String, dynamic>.from(patient['vitals'] ?? {});
    final recVitals = (vitals['receptionistVitals'] is Map)
        ? Map<String, dynamic>.from(vitals['receptionistVitals'])
        : <String, dynamic>{};
    final docVitals = (vitals['doctorVitals'] is Map)
        ? Map<String, dynamic>.from(vitals['doctorVitals'])
        : <String, dynamic>{};

    final currentBp = (vitals['bp'] ?? '').toString();
    String initSys = '';
    String initDia = '';
    if (currentBp.contains('/')) {
      final parts = currentBp.split('/');
      initSys = parts[0].trim();
      if (parts.length > 1) initDia = parts[1].trim();
    } else if (currentBp != 'N/A') {
      initSys = currentBp;
    }

    final sysCtrl  = TextEditingController(text: initSys);
    final diaCtrl  = TextEditingController(text: initDia);
    final tempCtrl = TextEditingController(text: (vitals['temp'] ?? '').toString() == 'N/A' ? '' : (vitals['temp'] ?? '').toString());
    final sugarCtrl = TextEditingController(text: (vitals['sugar'] ?? '').toString());
    final weightCtrl = TextEditingController(text: (vitals['weight'] ?? '').toString() == 'N/A' ? '' : (vitals['weight'] ?? '').toString());

    final recBp = recVitals['bp'] ?? vitals['bp'] ?? 'N/A';
    final recTemp = recVitals['temp'] ?? vitals['temp'] ?? 'N/A';
    final recBy = recVitals['addedBy'] ?? patient['createdByName'] ?? 'Receptionist';

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: Colors.teal.shade50,
            borderRadius: BorderRadius.circular(12),
          ),
          child: Row(
            children: [
              Icon(Icons.edit_note_rounded, color: Colors.teal.shade800, size: 24),
              const SizedBox(width: 10),
              Text(
                'Edit Vitals & View Audit',
                style: TextStyle(
                  fontWeight: FontWeight.bold,
                  color: Colors.teal.shade900,
                  fontSize: 16,
                ),
              ),
            ],
          ),
        ),
        content: SizedBox(
          width: 440,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // ── Audit info header: What receptionist added ─────────────
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: Colors.blue.shade50,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: Colors.blue.shade200),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Icon(Icons.support_agent_rounded, size: 18, color: Colors.blue.shade800),
                          const SizedBox(width: 6),
                          Text(
                            'Added by Receptionist ($recBy)',
                            style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12, color: Colors.blue.shade900),
                          ),
                        ],
                      ),
                      const SizedBox(height: 6),
                      Text(
                        'BP: $recBp | Temp: $recTemp°C | Weight: ${recVitals['weight'] ?? 'N/A'} kg',
                        style: TextStyle(fontSize: 12, color: Colors.blue.shade900),
                      ),
                    ],
                  ),
                ),
                if (docVitals.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: Colors.amber.shade50,
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: Colors.amber.shade300),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Icon(Icons.medical_services_rounded, size: 18, color: Colors.amber.shade900),
                            const SizedBox(width: 6),
                            Text(
                              'Previous Doctor Update (${docVitals['updatedBy'] ?? 'Doctor'})',
                              style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12, color: Colors.amber.shade900),
                            ),
                          ],
                        ),
                        const SizedBox(height: 6),
                        Text(
                          'BP: ${docVitals['bp'] ?? 'N/A'} | Temp: ${docVitals['temp'] ?? 'N/A'}°C',
                          style: TextStyle(fontSize: 12, color: Colors.amber.shade900),
                        ),
                      ],
                    ),
                  ),
                ],
                const SizedBox(height: 16),
                Text(
                  'Update Vitals (Doctor):',
                  style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold, color: Colors.teal.shade800),
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: sysCtrl,
                        maxLength: 3,
                        keyboardType: TextInputType.number,
                        inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                        decoration: InputDecoration(
                          labelText: 'Systolic BP',
                          hintText: 'e.g. 120',
                          border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
                          contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                          counterText: '',
                        ),
                      ),
                    ),
                    const Padding(
                      padding: EdgeInsets.symmetric(horizontal: 8),
                      child: Text('/', style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
                    ),
                    Expanded(
                      child: TextField(
                        controller: diaCtrl,
                        maxLength: 3,
                        keyboardType: TextInputType.number,
                        inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                        decoration: InputDecoration(
                          labelText: 'Diastolic BP',
                          hintText: 'e.g. 80',
                          border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
                          contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                          counterText: '',
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: tempCtrl,
                  keyboardType: const TextInputType.numberWithOptions(decimal: true),
                  inputFormatters: [
                    FilteringTextInputFormatter.allow(RegExp(r'[0-9.]')),
                    LengthLimitingTextInputFormatter(5),
                  ],
                  decoration: InputDecoration(
                    labelText: 'Temperature (°C)',
                    hintText: 'e.g. 98.6',
                    prefixIcon: const Icon(Icons.thermostat),
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
                    contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                  ),
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: sugarCtrl,
                        maxLength: 3,
                        keyboardType: TextInputType.number,
                        inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                        decoration: InputDecoration(
                          labelText: 'Sugar (optional)',
                          prefixIcon: const Icon(Icons.opacity),
                          border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
                          contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                          counterText: '',
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: TextField(
                        controller: weightCtrl,
                        maxLength: 3,
                        keyboardType: TextInputType.number,
                        inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                        decoration: InputDecoration(
                          labelText: 'Weight (kg)',
                          prefixIcon: const Icon(Icons.monitor_weight),
                          border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
                          contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                          counterText: '',
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel', style: TextStyle(color: Colors.grey)),
          ),
          ElevatedButton.icon(
            style: ElevatedButton.styleFrom(
              backgroundColor: _teal,
              foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
            ),
            icon: const Icon(Icons.save_rounded, size: 18),
            label: const Text('Save Updated Vitals'),
            onPressed: () async {
              final sys = sysCtrl.text.trim();
              final dia = diaCtrl.text.trim();
              final bpVal = (sys.isNotEmpty && dia.isNotEmpty) ? '$sys/$dia' : (sys.isNotEmpty ? sys : 'N/A');
              final tempVal = tempCtrl.text.trim().isNotEmpty ? tempCtrl.text.trim() : 'N/A';
              final sugarVal = sugarCtrl.text.trim();
              final weightVal = weightCtrl.text.trim().isNotEmpty ? weightCtrl.text.trim() : 'N/A';
              final nowIso = DateTime.now().toIso8601String();
              final docName = doctorName ?? 'Doctor';
              final docId   = doctorId ?? '';

              final auditList = List<Map<String, dynamic>>.from(
                (vitals['auditTrail'] as List<dynamic>?)?.map((e) => Map<String, dynamic>.from(e as Map)) ?? []
              );

              auditList.add({
                'role': 'doctor',
                'action': 'Updated vitals',
                'by': docName,
                'byId': docId,
                'at': nowIso,
                'bp': bpVal,
                'temp': tempVal,
                'weight': weightVal,
                if (sugarVal.isNotEmpty) 'sugar': sugarVal,
              });

              vitals['bp'] = bpVal;
              vitals['temp'] = tempVal;
              vitals['weight'] = weightVal;
              if (sugarVal.isNotEmpty) vitals['sugar'] = sugarVal;
              vitals['doctorVitals'] = {
                'bp': bpVal,
                'temp': tempVal,
                'weight': weightVal,
                if (sugarVal.isNotEmpty) 'sugar': sugarVal,
                'updatedBy': docName,
                'updatedById': docId,
                'updatedAt': nowIso,
              };
              vitals['auditTrail'] = auditList;
              patient['vitals'] = vitals;

              // Save to Hive
              final serial = patient['serial']?.toString() ?? '';
              final bId    = branchId ?? patient['branchId']?.toString() ?? '';
              if (serial.isNotEmpty && bId.isNotEmpty) {
                final entryKey = '$bId-$serial';
                final box = await LocalStorageService.ensureBoxOpen(LocalStorageService.entriesBox);
                final existing = box.get(entryKey);
                if (existing != null) {
                  final updatedEntry = Map<String, dynamic>.from(existing);
                  updatedEntry['vitals'] = vitals;
                  await box.put(entryKey, updatedEntry);

                  try {
                    RealtimeManager().sendMessage({
                      ...RealtimeEvents.payload(
                        type: RealtimeEvents.saveEntry,
                        branchId: bId,
                        data: updatedEntry,
                      ),
                    });
                  } catch (_) {}
                }
              }

              if (context.mounted) {
                Navigator.pop(ctx);
                onVitalsUpdated?.call(vitals);
                Flushbar(
                  message: '✅ Vitals updated and audit trail saved',
                  backgroundColor: Colors.teal.shade700,
                  duration: const Duration(seconds: 3),
                ).show(context);
              }
            },
          ),
        ],
      ),
    );
  }

  void _showAuditTrailDialog(BuildContext context, Map<String, dynamic> patient) {
    final vitals = Map<String, dynamic>.from(patient['vitals'] ?? {});
    final auditList = List<Map<String, dynamic>>.from(
      (vitals['auditTrail'] as List<dynamic>?)?.map((e) => Map<String, dynamic>.from(e as Map)) ?? []
    );

    if (auditList.isEmpty) {
      final recV = (vitals['receptionistVitals'] is Map) ? Map<String, dynamic>.from(vitals['receptionistVitals']) : {};
      final docV = (vitals['doctorVitals'] is Map) ? Map<String, dynamic>.from(vitals['doctorVitals']) : {};

      if (recV.isNotEmpty || vitals['bp'] != null) {
        auditList.add({
          'role': 'receptionist',
          'action': 'Added initial vitals',
          'by': recV['addedBy'] ?? patient['createdByName'] ?? 'Receptionist',
          'at': recV['addedAt'] ?? patient['createdAt'] ?? '',
          'bp': recV['bp'] ?? vitals['bp'] ?? 'N/A',
          'temp': recV['temp'] ?? vitals['temp'] ?? 'N/A',
          'sugar': recV['sugar'] ?? vitals['sugar'] ?? 'N/A',
          'weight': recV['weight'] ?? vitals['weight'] ?? 'N/A',
        });
      }
      if (docV.isNotEmpty) {
        auditList.add({
          'role': 'doctor',
          'action': 'Updated vitals',
          'by': docV['updatedBy'] ?? 'Doctor',
          'at': docV['updatedAt'] ?? '',
          'bp': docV['bp'] ?? 'N/A',
          'temp': docV['temp'] ?? 'N/A',
          'sugar': docV['sugar'] ?? vitals['sugar'] ?? 'N/A',
          'weight': docV['weight'] ?? vitals['weight'] ?? 'N/A',
        });
      }
    }

    showDialog(
      context: context,
      builder: (ctx) => Dialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        clipBehavior: Clip.antiAlias,
        child: Container(
          width: 520,
          decoration: BoxDecoration(
            color: Theme.of(context).brightness == Brightness.dark
                ? const Color(0xFF1E293B)
                : Colors.white,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // ── Header Banner ──────────────────────────────────────────────
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
                decoration: const BoxDecoration(
                  gradient: LinearGradient(
                    colors: [Color(0xFF0F766E), Color(0xFF0D9488)],
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                  ),
                ),
                child: Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                        color: Colors.white.withValues(alpha: 0.18),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: const Icon(Icons.history_toggle_off_rounded,
                          color: Colors.white, size: 24),
                    ),
                    const SizedBox(width: 14),
                    const Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('Vitals Audit Trail',
                              style: TextStyle(
                                  fontSize: 18,
                                  fontWeight: FontWeight.bold,
                                  color: Colors.white)),
                          SizedBox(height: 2),
                          Text('Complete record of patient vital entries',
                              style: TextStyle(
                                  fontSize: 12, color: Colors.white70)),
                        ],
                      ),
                    ),
                    IconButton(
                      icon: const Icon(Icons.close_rounded, color: Colors.white),
                      onPressed: () => Navigator.pop(ctx),
                    ),
                  ],
                ),
              ),

              // ── Content ───────────────────────────────────────────────────
              ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 480),
                child: SingleChildScrollView(
                  padding: const EdgeInsets.all(20),
                  child: auditList.isEmpty
                      ? const Padding(
                          padding: EdgeInsets.symmetric(vertical: 30),
                          child: Center(
                            child: Text(
                              'No vitals audit history available for this entry.',
                              style: TextStyle(color: Colors.grey, fontSize: 14),
                            ),
                          ),
                        )
                      : Column(
                          children: auditList.asMap().entries.map((entry) {
                            final item = entry.value;
                            final isDoc = item['role'] == 'doctor';
                            final roleColor = isDoc ? Colors.amber.shade800 : Colors.teal.shade700;
                            final roleBg = isDoc ? Colors.amber.shade50 : Colors.teal.shade50;
                            final roleIcon = isDoc ? Icons.medical_services_rounded : Icons.support_agent_rounded;

                            final bpStr = (item['bp'] ?? 'N/A').toString();
                            final tempStr = (item['temp'] ?? 'N/A').toString();
                            final sugarStr = (item['sugar'] ?? 'N/A').toString();
                            final weightStr = (item['weight'] ?? 'N/A').toString();
                            final timeRaw = item['at']?.toString() ?? '';
                            final formattedTime = timeRaw.isNotEmpty
                                ? timeRaw.replaceAll('T', ' ').split('.')[0]
                                : '';

                            return Container(
                              margin: const EdgeInsets.only(bottom: 14),
                              padding: const EdgeInsets.all(14),
                              decoration: BoxDecoration(
                                color: roleBg.withValues(alpha: 0.6),
                                borderRadius: BorderRadius.circular(16),
                                border: Border.all(
                                    color: roleColor.withValues(alpha: 0.3),
                                    width: 1.2),
                              ),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Row(
                                    children: [
                                      Container(
                                        padding: const EdgeInsets.all(8),
                                        decoration: BoxDecoration(
                                          color: roleColor,
                                          borderRadius: BorderRadius.circular(10),
                                        ),
                                        child: Icon(roleIcon, color: Colors.white, size: 16),
                                      ),
                                      const SizedBox(width: 10),
                                      Expanded(
                                        child: Column(
                                          crossAxisAlignment: CrossAxisAlignment.start,
                                          children: [
                                            Text(
                                              item['action'] ?? 'Vitals recorded',
                                              style: TextStyle(
                                                  fontWeight: FontWeight.bold,
                                                  fontSize: 14,
                                                  color: roleColor),
                                            ),
                                            if (formattedTime.isNotEmpty)
                                              Text(
                                                'Recorded by ${item['by'] ?? 'User'} • $formattedTime',
                                                style: TextStyle(
                                                    fontSize: 11,
                                                    color: Colors.grey.shade700),
                                              ),
                                          ],
                                        ),
                                      ),
                                      Container(
                                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                                        decoration: BoxDecoration(
                                          color: roleColor.withValues(alpha: 0.15),
                                          borderRadius: BorderRadius.circular(20),
                                        ),
                                        child: Text(
                                          isDoc ? 'DOCTOR' : 'RECEPTIONIST',
                                          style: TextStyle(
                                              fontSize: 10,
                                              fontWeight: FontWeight.bold,
                                              color: roleColor),
                                        ),
                                      ),
                                    ],
                                  ),
                                  const SizedBox(height: 12),
                                  Wrap(
                                    spacing: 8,
                                    runSpacing: 8,
                                    children: [
                                      _auditVitalChip('BP', bpStr, Icons.favorite_rounded, Colors.red.shade700),
                                      _auditVitalChip('Temp', tempStr == 'N/A' ? 'N/A' : '$tempStr°C', Icons.thermostat_rounded, Colors.orange.shade800),
                                      _auditVitalChip('Sugar', sugarStr == 'N/A' ? 'N/A' : '$sugarStr mg/dL', Icons.opacity_rounded, Colors.purple.shade700),
                                      _auditVitalChip('Weight', weightStr == 'N/A' ? 'N/A' : '${weightStr}kg', Icons.monitor_weight_rounded, Colors.green.shade800),
                                    ],
                                  ),
                                ],
                              ),
                            );
                          }).toList(),
                        ),
                ),
              ),

              // ── Footer ────────────────────────────────────────────────────
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
                child: SizedBox(
                  width: double.infinity,
                  child: ElevatedButton(
                    onPressed: () => Navigator.pop(ctx),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFF0F766E),
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(vertical: 12),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                    ),
                    child: const Text('Close Audit Trail', style: TextStyle(fontWeight: FontWeight.bold)),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _auditVitalChip(String label, String value, IconData icon, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: color.withValues(alpha: 0.3)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: color),
          const SizedBox(width: 6),
          Text(
            '$label: ',
            style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: color),
          ),
          Text(
            value,
            style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: Colors.black87),
          ),
        ],
      ),
    );
  }

  String? _resolveGuardianName(Map<String, dynamic> patient) {
    if (patient['guardianName'] != null && patient['guardianName'].toString().trim().isNotEmpty) {
      return patient['guardianName'].toString().trim();
    }
    final gCnic = (patient['guardianCnic'] ?? '').toString().trim();
    if (gCnic.isEmpty) return null;

    try {
      final bId = branchId ?? patient['branchId']?.toString();
      final list = LocalStorageService.searchPatientsByCnicOrGuardian(gCnic, branchId: bId);
      for (final p in list) {
        final isAdult = p['isAdult'] == true ||
            (p['guardianCnic'] == null || (p['guardianCnic'] as String).trim().isEmpty);
        if (isAdult) {
          final gName = (p['patientName'] ?? p['name'] ?? p['fullName'])?.toString().trim();
          if (gName != null && gName.isNotEmpty) return gName;
        }
      }
      if (list.isNotEmpty) {
        final gName = (list.first['patientName'] ?? list.first['name'] ?? list.first['fullName'])?.toString().trim();
        if (gName != null && gName.isNotEmpty) return gName;
      }
    } catch (_) {}
    return null;
  }

  @override
  Widget build(BuildContext context) {
    if (patientData == null || patientData!.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.person_search, size: 50, color: Colors.grey.shade400),
            const SizedBox(height: 8),
            Text(
              "Select a patient to view details",
              style: TextStyle(fontSize: 14, color: Colors.grey.shade700),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      );
    }

    final patient = patientData!;
    final vitals  = Map<String, dynamic>.from(patient['vitals'] ?? {});
    final recVitals = (vitals['receptionistVitals'] is Map) ? Map<String, dynamic>.from(vitals['receptionistVitals']) : {};
    final docVitals = (vitals['doctorVitals'] is Map) ? Map<String, dynamic>.from(vitals['doctorVitals']) : {};
    final hasDocUpdate = docVitals.isNotEmpty;
    final recBp   = recVitals['bp'] ?? (hasDocUpdate ? 'Rec' : null);
    final recTemp = recVitals['temp'] ?? (hasDocUpdate ? 'Rec' : null);
    final recSugar = recVitals['sugar'];
    final recWeight = recVitals['weight'];

    final patientName = (patient['patientName'] ?? patient['name'] ?? 'Unknown Patient').toString();
    final guardianName = _resolveGuardianName(patient);
    final isChild = (patient['guardianCnic'] != null && patient['guardianCnic'].toString().trim().isNotEmpty) ||
        (patient['isAdult'] == false);

    final isDark = Theme.of(context).brightness == Brightness.dark;

    return LayoutBuilder(builder: (context, constraints) {
      final isNarrow = constraints.maxWidth < 600;
      final compact  = constraints.maxWidth < 420;

      final vitalsList = [
        {'label': 'Age',    'value': (vitals['age'] ?? patient['age'] ?? '-').toString(), 'icon': Icons.calendar_today_rounded, 'color': isDark ? const Color(0xFF0F766E) : _teal, 'sub': null},
        {'label': 'Gender', 'value': vitals['gender'] ?? patient['gender'] ?? '-',        'icon': Icons.person_outline_rounded, 'color': isDark ? const Color(0xFF1D4ED8) : Colors.blue.shade700, 'sub': null},
        {'label': 'Blood',  'value': vitals['bloodGroup'] ?? patient['bloodGroup'] ?? '-','icon': Icons.bloodtype_rounded,       'color': isDark ? const Color(0xFFB91C1C) : Colors.red.shade700, 'sub': null},
        {'label': 'BP',     'value': vitals['bp'] ?? '-',                                 'icon': Icons.favorite_rounded,        'color': const Color(0xFFE11D48), 'sub': hasDocUpdate && recBp != null && recBp.toString() != vitals['bp']?.toString() ? 'Rec: $recBp' : null},
        {'label': 'Temp',   'value': vitals['temp'] != null ? "${vitals['temp']}°C" : '-','icon': Icons.thermostat_rounded,      'color': const Color(0xFFD97706), 'sub': hasDocUpdate && recTemp != null && recTemp.toString() != vitals['temp']?.toString() ? 'Rec: $recTemp°C' : null},
        {'label': 'Sugar',  'value': vitals['sugar'] ?? '-',                              'icon': Icons.water_drop_rounded,      'color': const Color(0xFF7C3AED), 'sub': hasDocUpdate && recSugar != null && recSugar.toString() != vitals['sugar']?.toString() ? 'Rec: $recSugar' : null},
        {'label': 'Weight', 'value': vitals['weight'] != null ? "${vitals['weight']}kg" : '-','icon': Icons.monitor_weight_rounded,'color': isDark ? const Color(0xFF15803D) : Colors.green.shade700, 'sub': hasDocUpdate && recWeight != null && recWeight.toString() != vitals['weight']?.toString() ? 'Rec: ${recWeight}kg' : null},
      ];

      return Padding(
        padding: EdgeInsets.symmetric(
          horizontal: isNarrow ? 12 : 16,
          vertical: 10,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            // ── Top Row: Name on Left, Actions on Right ────────────────────
            Row(
              children: [
                Container(
                  width: isNarrow ? 32 : 36,
                  height: isNarrow ? 32 : 36,
                  decoration: BoxDecoration(
                    color: isDark ? const Color(0xFF134E4A) : const Color(0xFFCCFBF1),
                    shape: BoxShape.circle,
                    border: Border.all(
                      color: isDark ? const Color(0xFF2DD4BF) : _teal,
                      width: 1.5,
                    ),
                  ),
                  child: Icon(
                    Icons.person_rounded,
                    color: isDark ? const Color(0xFF2DD4BF) : _teal,
                    size: isNarrow ? 18 : 20,
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Row(
                    children: [
                      Flexible(
                        child: Text(
                          patientName,
                          style: TextStyle(
                            fontSize: isNarrow ? 16 : 19,
                            fontWeight: FontWeight.w900,
                            color: isDark ? Colors.white : const Color(0xFF0F172A),
                            letterSpacing: -0.2,
                          ),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      if (isChild && guardianName != null && guardianName.isNotEmpty) ...[
                        const SizedBox(width: 8),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                          decoration: BoxDecoration(
                            color: isDark ? const Color(0xFF134E4A) : Colors.teal.shade50,
                            borderRadius: BorderRadius.circular(8),
                            border: Border.all(color: isDark ? const Color(0xFF2DD4BF) : Colors.teal.shade200),
                          ),
                          child: Text(
                            'Guardian: $guardianName',
                            style: TextStyle(
                              fontSize: isNarrow ? 10 : 11.5,
                              fontWeight: FontWeight.w700,
                              color: isDark ? const Color(0xFF5EEAD4) : Colors.teal.shade900,
                            ),
                          ),
                        ),
                      ],
                      if (patient['isVitalsOnly'] == true || patient['vitalsOnly'] == true) ...[
                        const SizedBox(width: 8),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                          decoration: BoxDecoration(
                            color: isDark ? const Color(0xFF6B21A8) : Colors.purple.shade700,
                            borderRadius: BorderRadius.circular(8),
                            boxShadow: [
                              BoxShadow(
                                color: Colors.purple.withValues(alpha: 0.25),
                                blurRadius: 4,
                                offset: const Offset(0, 1),
                              ),
                            ],
                          ),
                          child: const Text(
                            '🩺 VITALS ONLY',
                            style: TextStyle(
                              color: Colors.white,
                              fontSize: 10,
                              fontWeight: FontWeight.w800,
                              letterSpacing: 0.3,
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                // Serial Token Badge
                Container(
                  height: 32,
                  padding: EdgeInsets.symmetric(
                    horizontal: isNarrow ? 10 : 14,
                  ),
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: isDark ? const Color(0xFF451A03) : const Color(0xFFFFFBEB),
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(
                      color: isDark ? const Color(0xFFF59E0B) : const Color(0xFFFBBF24),
                      width: 1.5,
                    ),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.amber.withValues(alpha: isDark ? 0.2 : 0.15),
                        blurRadius: 4,
                        offset: const Offset(0, 1),
                      ),
                    ],
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        Icons.confirmation_number_rounded,
                        color: isDark ? const Color(0xFFFBBF24) : const Color(0xFFD97706),
                        size: isNarrow ? 14 : 16,
                      ),
                      const SizedBox(width: 6),
                      Text(
                        patient['serial'] ?? '-',
                        style: TextStyle(
                          color: isDark ? const Color(0xFFFDE68A) : const Color(0xFFB45309),
                          fontSize: isNarrow ? 11.5 : 13,
                          fontWeight: FontWeight.w800,
                          letterSpacing: 0.3,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                // Edit Vitals Button
                InkWell(
                  onTap: () => _showEditVitalsDialog(context, patient),
                  borderRadius: BorderRadius.circular(20),
                  child: Container(
                    height: 32,
                    padding: EdgeInsets.symmetric(
                      horizontal: isNarrow ? 10 : 12,
                    ),
                    decoration: BoxDecoration(
                      color: isDark ? const Color(0xFF0F766E) : _teal,
                      borderRadius: BorderRadius.circular(20),
                      boxShadow: [
                        BoxShadow(
                          color: _teal.withValues(alpha: 0.3),
                          blurRadius: 4,
                          offset: const Offset(0, 1.5),
                        ),
                      ],
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.edit_note_rounded, color: Colors.white, size: isNarrow ? 16 : 18),
                        const SizedBox(width: 4),
                        Text(
                          'Edit BP/Temp',
                          style: TextStyle(
                            fontSize: isNarrow ? 11 : 12,
                            fontWeight: FontWeight.bold,
                            color: Colors.white,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                if (onSkipPatient != null) ...[
                  const SizedBox(width: 8),
                  InkWell(
                    onTap: onSkipPatient,
                    borderRadius: BorderRadius.circular(20),
                    child: Container(
                      height: 32,
                      padding: EdgeInsets.symmetric(
                        horizontal: isNarrow ? 10 : 12,
                      ),
                      decoration: BoxDecoration(
                        color: isDark ? const Color(0xFFC2410C) : const Color(0xFFEA580C),
                        borderRadius: BorderRadius.circular(20),
                        boxShadow: [
                          BoxShadow(
                            color: Colors.deepOrange.withValues(alpha: 0.3),
                            blurRadius: 4,
                            offset: const Offset(0, 1.5),
                          ),
                        ],
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.skip_next_rounded, color: Colors.white, size: isNarrow ? 16 : 18),
                          const SizedBox(width: 4),
                          Text(
                            'Skip',
                            style: TextStyle(
                              fontSize: isNarrow ? 11 : 12,
                              fontWeight: FontWeight.bold,
                              color: Colors.white,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
                if (patient['suggestedDays'] != null) ...[
                  const SizedBox(width: 8),
                  (() {
                    final suggested = (patient['suggestedDays'] as int?) ?? 1;
                    int prescribed = 1;
                    final existingPresc = patient['prescription'];
                    if (existingPresc is Map) {
                      prescribed = (existingPresc['daysOfMedicine'] as int?) ?? 1;
                    } else if (patient['daysOfMedicine'] is int) {
                      prescribed = patient['daysOfMedicine'];
                    }

                    final hasMismatch = suggested != prescribed && existingPresc != null;

                    return Container(
                      height: 32,
                      padding: EdgeInsets.symmetric(
                        horizontal: isNarrow ? 8 : 12,
                      ),
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        color: hasMismatch
                            ? (isDark ? const Color(0xFF451A03) : const Color(0xFFFFF7ED))
                            : (isDark ? const Color(0xFF064E3B) : const Color(0xFFECFDF5)),
                        borderRadius: BorderRadius.circular(20),
                        border: Border.all(
                          color: hasMismatch
                              ? (isDark ? const Color(0xFFF97316) : const Color(0xFFFDBA74))
                              : (isDark ? const Color(0xFF10B981) : const Color(0xFFA7F3D0)),
                          width: 1.2,
                        ),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            hasMismatch ? Icons.warning_amber_rounded : Icons.info_outline_rounded,
                            color: hasMismatch
                                ? (isDark ? const Color(0xFFFB923C) : Colors.orange.shade800)
                                : (isDark ? const Color(0xFF34D399) : const Color(0xFF059669)),
                            size: isNarrow ? 14 : 16,
                          ),
                          const SizedBox(width: 5),
                          Text(
                            hasMismatch
                                ? '$suggested Paid vs $prescribed Prescribed'
                                : '$suggested day${suggested > 1 ? 's' : ''} requested',
                            style: TextStyle(
                              color: hasMismatch
                                  ? (isDark ? const Color(0xFFFED7AA) : Colors.orange.shade900)
                                  : (isDark ? const Color(0xFFA7F3D0) : const Color(0xFF065F46)),
                              fontSize: isNarrow ? 10.5 : 12,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ],
                      ),
                    );
                  })(),
                ],
              ],
            ),

            const SizedBox(height: 10),

            // ── Vital tiles ───────────────────────────────────────────────
            isNarrow
                ? Wrap(
                    spacing: 4,
                    runSpacing: 4,
                    children: vitalsList.map((v) {
                      return SizedBox(
                        width: (constraints.maxWidth - 40) / 4,
                        height: 64,
                        child: _buildVital(
                          label: v['label'] as String,
                          value: v['value'] as String,
                          icon: v['icon'] as IconData,
                          backgroundColor: v['color'] as Color,
                          compact: true,
                          auditSubtext: v['sub'] as String?,
                        ),
                      );
                    }).toList(),
                  )
                : SizedBox(
                    height: 80,
                    child: Row(
                      children: vitalsList.map((v) => Expanded(
                        child: _buildVital(
                          label: v['label'] as String,
                          value: v['value'] as String,
                          icon: v['icon'] as IconData,
                          backgroundColor: v['color'] as Color,
                          compact: compact,
                          auditSubtext: v['sub'] as String?,
                        ),
                      )).toList(),
                    ),
                  ),
          ],
        ),
      );
    });
  }
}
