class Caliber {
  Caliber({
    required this.id,
    required this.name,
    this.bulletDiameterIn,
    this.caseLengthIn,
    this.maxCoalIn,
  });

  final String id;
  final String name;
  final double? bulletDiameterIn;
  final double? caseLengthIn;
  final double? maxCoalIn;

  Map<String, dynamic> toMap() => {
        'name': name,
        'bulletDiameterIn': bulletDiameterIn,
        'caseLengthIn': caseLengthIn,
        'maxCoalIn': maxCoalIn,
      };

  factory Caliber.fromMap(String id, Map<String, dynamic> map) => Caliber(
        id: id,
        name: map['name'] as String? ?? '',
        bulletDiameterIn: (map['bulletDiameterIn'] as num?)?.toDouble(),
        caseLengthIn: (map['caseLengthIn'] as num?)?.toDouble(),
        maxCoalIn: (map['maxCoalIn'] as num?)?.toDouble(),
      );
}
