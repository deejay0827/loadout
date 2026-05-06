class Brass {
  Brass({
    required this.id,
    required this.manufacturer,
    required this.caliberId,
    this.headstamp,
    this.timesFired = 0,
    this.quantityOnHand = 0,
  });

  final String id;
  final String manufacturer;
  final String caliberId;
  final String? headstamp;
  final int timesFired;
  final int quantityOnHand;

  Map<String, dynamic> toMap() => {
        'manufacturer': manufacturer,
        'caliberId': caliberId,
        'headstamp': headstamp,
        'timesFired': timesFired,
        'quantityOnHand': quantityOnHand,
      };

  factory Brass.fromMap(String id, Map<String, dynamic> map) => Brass(
        id: id,
        manufacturer: map['manufacturer'] as String? ?? '',
        caliberId: map['caliberId'] as String? ?? '',
        headstamp: map['headstamp'] as String?,
        timesFired: (map['timesFired'] as num?)?.toInt() ?? 0,
        quantityOnHand: (map['quantityOnHand'] as num?)?.toInt() ?? 0,
      );
}
