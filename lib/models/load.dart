import 'package:cloud_firestore/cloud_firestore.dart';

class Load {
  Load({
    required this.id,
    required this.name,
    required this.caliberId,
    required this.bulletId,
    required this.powderId,
    required this.primerId,
    this.brassId,
    required this.powderChargeGr,
    required this.coalIn,
    this.cbtoIn,
    this.notes,
    this.createdAt,
    this.updatedAt,
  });

  final String id;
  final String name;
  final String caliberId;
  final String bulletId;
  final String powderId;
  final String primerId;
  final String? brassId;
  final double powderChargeGr;
  final double coalIn;
  final double? cbtoIn;
  final String? notes;
  final DateTime? createdAt;
  final DateTime? updatedAt;

  Map<String, dynamic> toMap() => {
        'name': name,
        'caliberId': caliberId,
        'bulletId': bulletId,
        'powderId': powderId,
        'primerId': primerId,
        'brassId': brassId,
        'powderChargeGr': powderChargeGr,
        'coalIn': coalIn,
        'cbtoIn': cbtoIn,
        'notes': notes,
        'createdAt': createdAt == null ? FieldValue.serverTimestamp() : Timestamp.fromDate(createdAt!),
        'updatedAt': FieldValue.serverTimestamp(),
      };

  factory Load.fromMap(String id, Map<String, dynamic> map) => Load(
        id: id,
        name: map['name'] as String? ?? '',
        caliberId: map['caliberId'] as String? ?? '',
        bulletId: map['bulletId'] as String? ?? '',
        powderId: map['powderId'] as String? ?? '',
        primerId: map['primerId'] as String? ?? '',
        brassId: map['brassId'] as String?,
        powderChargeGr: (map['powderChargeGr'] as num?)?.toDouble() ?? 0,
        coalIn: (map['coalIn'] as num?)?.toDouble() ?? 0,
        cbtoIn: (map['cbtoIn'] as num?)?.toDouble(),
        notes: map['notes'] as String?,
        createdAt: (map['createdAt'] as Timestamp?)?.toDate(),
        updatedAt: (map['updatedAt'] as Timestamp?)?.toDate(),
      );
}
