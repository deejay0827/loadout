enum PrimerSize { smallPistol, largePistol, smallRifle, largeRifle, smallPistolMagnum, largePistolMagnum, smallRifleMagnum, largeRifleMagnum }

class Primer {
  Primer({
    required this.id,
    required this.manufacturer,
    required this.model,
    required this.size,
    this.lotNumber,
    this.quantityOnHand = 0,
  });

  final String id;
  final String manufacturer;
  final String model;
  final PrimerSize size;
  final String? lotNumber;
  final int quantityOnHand;

  Map<String, dynamic> toMap() => {
        'manufacturer': manufacturer,
        'model': model,
        'size': size.name,
        'lotNumber': lotNumber,
        'quantityOnHand': quantityOnHand,
      };

  factory Primer.fromMap(String id, Map<String, dynamic> map) => Primer(
        id: id,
        manufacturer: map['manufacturer'] as String? ?? '',
        model: map['model'] as String? ?? '',
        size: PrimerSize.values.firstWhere(
          (s) => s.name == map['size'],
          orElse: () => PrimerSize.smallRifle,
        ),
        lotNumber: map['lotNumber'] as String?,
        quantityOnHand: (map['quantityOnHand'] as num?)?.toInt() ?? 0,
      );
}
