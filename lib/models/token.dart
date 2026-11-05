class Token {
  final String id;
  final String patientId;
  final DateTime createdAt;
  final int number;

  Token({
    required this.id,
    required this.patientId,
    required this.createdAt,
    required this.number,
  });

  factory Token.fromMap(Map<String, dynamic> map) {
    final rawCreated = map['createdAt'];
    final createdDt = rawCreated is DateTime
        ? rawCreated
        : (DateTime.tryParse(rawCreated?.toString() ?? '') ?? DateTime.now());
    final rawNum = map['number'] ?? map['tokenNumber'];
    final numVal = rawNum is num ? rawNum.toInt() : (int.tryParse(rawNum?.toString() ?? '') ?? 0);
    return Token(
      id: (map['id'] ?? map['serial'] ?? '').toString(),
      patientId: (map['patientId'] ?? '').toString(),
      createdAt: createdDt,
      number: numVal,
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'patientId': patientId,
      'createdAt': createdAt.toIso8601String(),
      'number': number,
    };
  }
}
