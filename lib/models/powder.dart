class Powder {
  Powder({
    required this.id,
    required this.manufacturer,
    required this.name,
    this.lotNumber,
    this.quantityOnHandGr = 0,
  });

  final String id;
  final String manufacturer;
  final String name;
  final String? lotNumber;
  final double quantityOnHandGr;

  Map<String, dynamic> toMap() => {
        'manufacturer': manufacturer,
        'name': name,
        'lotNumber': lotNumber,
        'quantityOnHandGr': quantityOnHandGr,
      };

  factory Powder.fromMap(String id, Map<String, dynamic> map) => Powder(
        id: id,
        manufacturer: map['manufacturer'] as String? ?? '',
        name: map['name'] as String? ?? '',
        lotNumber: map['lotNumber'] as String?,
        quantityOnHandGr: (map['quantityOnHandGr'] as num?)?.toDouble() ?? 0,
      );
}
