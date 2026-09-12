import 'package:cloud_firestore/cloud_firestore.dart';

class Holiday {
  final String id; // Firestore doc id
  final DateTime date;
  final String name;

  Holiday({required this.id, required this.date, required this.name});

  factory Holiday.fromFirestore(DocumentSnapshot doc) {
    final data = doc.data() as Map<String, dynamic>;
    final rawDate = data['date'];
    DateTime parsedDate;
    if (rawDate is Timestamp) {
      parsedDate = rawDate.toDate();
    } else if (rawDate is String) {
      parsedDate = DateTime.tryParse(rawDate) ?? DateTime.now();
    } else if (rawDate is DateTime) {
      parsedDate = rawDate;
    } else {
      parsedDate = DateTime.now();
    }
    return Holiday(
      id: doc.id,
      date: parsedDate,
      name: data['name'] ?? '',
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'date': Timestamp.fromDate(date),
      'name': name,
    };
  }
}
