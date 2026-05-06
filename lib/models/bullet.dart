class Bullet {
  Bullet({
    required this.id,
    required this.manufacturer,
    required this.model,
    required this.weightGr,
    required this.diameterIn,
    this.bcG1,
    this.bcG7,
    this.lotNumber,
    this.quantityOnHand = 0,
  });

  final String id;
  final String manufacturer;
  final String model;
  final double weightGr;
  final double diameterIn;
  final double? bcG1;
  final double? bcG7;
  final String? lotNumber;
  final int quantityOnHand;

  Map<String, dynamic> toMap() => {
        'manufacturer': manufacturer,
        'model': model,
        'weightGr': weightGr,
        'diameterIn': diameterIn,
        'bcG1': bcG1,
        'bcG7': bcG7,
        'lotNumber': lotNumber,
        'quantityOnHand': quantityOnHand,
      };

  factory Bullet.fromMap(String id, Map<String, dynamic> map) => Bullet(
        id: id,
        manufacturer: map['manufacturer'] as String? ?? '',
        model: map['model'] as String? ?? '',
        weightGr: (map['weightGr'] as num?)?.toDouble() ?? 0,
        diameterIn: (map['diameterIn'] as num?)?.toDouble() ?? 0,
        bcG1: (map['bcG1'] as num?)?.toDouble(),
        bcG7: (map['bcG7'] as num?)?.toDouble(),
        lotNumber: map['lotNumber'] as String?,
        quantityOnHand: (map['quantityOnHand'] as num?)?.toInt() ?? 0,
      );
}
