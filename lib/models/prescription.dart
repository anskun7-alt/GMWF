// lib/models/prescription.dart
import 'package:cloud_firestore/cloud_firestore.dart';

class Prescription {
  final String id;
  final String patientId;
  final String branchId;
  final String doctorId;
  final List<Map<String, dynamic>> items; // {medId, name, qty, price}
  final num total;
  final String status; // pending, ready, dispensed, completed
  final int daysOfMedicine;
  final num extraCharge;
  final Timestamp? createdAt;
  final Timestamp? updatedAt;

  Prescription({
    required this.id,
    required this.patientId,
    required this.branchId,
    required this.doctorId,
    required this.items,
    required this.total,
    required this.status,
    this.daysOfMedicine = 1,
    this.extraCharge = 0,
    this.createdAt,
    this.updatedAt,
  });

  factory Prescription.fromDoc(DocumentSnapshot doc) {
    final rawData = doc.data();
    final d = rawData is Map ? Map<String, dynamic>.from(rawData) : <String, dynamic>{};
    final rawItems = d['items'] ?? d['medicines'] ?? [];
    final itemsList = <Map<String, dynamic>>[];
    if (rawItems is Iterable) {
      for (final item in rawItems) {
        if (item is Map) itemsList.add(Map<String, dynamic>.from(item));
      }
    }
    Timestamp? parseTs(dynamic v) {
      if (v is Timestamp) return v;
      if (v is DateTime) return Timestamp.fromDate(v);
      if (v is String) {
        final dt = DateTime.tryParse(v);
        if (dt != null) return Timestamp.fromDate(dt);
      }
      return null;
    }
    return Prescription(
      id: doc.id,
      patientId: (d['patientId'] ?? '').toString(),
      branchId: (d['branchId'] ?? '').toString(),
      doctorId: (d['doctorId'] ?? '').toString(),
      items: itemsList,
      total: (d['total'] is num) ? (d['total'] as num) : (num.tryParse(d['total']?.toString() ?? '') ?? 0),
      status: (d['status'] ?? 'pending').toString(),
      daysOfMedicine: (d['daysOfMedicine'] is num)
          ? (d['daysOfMedicine'] as num).toInt()
          : (int.tryParse(d['daysOfMedicine']?.toString() ?? '') ?? 1),
      extraCharge: (d['extraCharge'] is num)
          ? (d['extraCharge'] as num)
          : (num.tryParse(d['extraCharge']?.toString() ?? '') ?? 0),
      createdAt: parseTs(d['createdAt']),
      updatedAt: parseTs(d['updatedAt']),
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'patientId': patientId,
      'branchId': branchId,
      'doctorId': doctorId,
      'items': items,
      'total': total,
      'status': status,
      'daysOfMedicine': daysOfMedicine,
      'extraCharge': extraCharge,
      'createdAt': createdAt ?? FieldValue.serverTimestamp(),
      'updatedAt': updatedAt ?? FieldValue.serverTimestamp(),
    };
  }
}
