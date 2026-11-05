import 'package:cloud_firestore/cloud_firestore.dart';

class StockItem {
  final String id;
  final String name;
  double quantity;
  final String unit;
  Timestamp lastUpdated;

  StockItem({
    required this.id,
    required this.name,
    this.quantity = 0.0,
    required this.unit,
    required this.lastUpdated,
  });

  factory StockItem.fromMap(Map<String, dynamic> map, String id) {
    final rawQty = map['quantity'];
    final qty = rawQty is num ? rawQty.toDouble() : (double.tryParse(rawQty?.toString() ?? '') ?? 0.0);
    final rawTs = map['lastUpdated'] ?? map['updatedAt'];
    Timestamp ts;
    if (rawTs is Timestamp) {
      ts = rawTs;
    } else if (rawTs is DateTime) {
      ts = Timestamp.fromDate(rawTs);
    } else if (rawTs is String && DateTime.tryParse(rawTs) != null) {
      ts = Timestamp.fromDate(DateTime.parse(rawTs));
    } else {
      ts = Timestamp.now();
    }
    return StockItem(
      id: id,
      name: (map['name'] ?? '').toString(),
      quantity: qty,
      unit: (map['unit'] ?? 'kg').toString(),
      lastUpdated: ts,
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'name': name,
      'quantity': quantity,
      'unit': unit,
      'lastUpdated': lastUpdated,
    };
  }
}
