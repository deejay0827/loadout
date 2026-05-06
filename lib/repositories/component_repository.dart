import '../models/brass.dart';
import '../models/bullet.dart';
import '../models/caliber.dart';
import '../models/powder.dart';
import '../models/primer.dart';
import '../services/firestore_service.dart';

class ComponentRepository {
  ComponentRepository({FirestoreService? service})
      : _service = service ?? FirestoreService();

  final FirestoreService _service;

  Stream<List<Caliber>> watchCalibers() => _service
      .userCollection('calibers')
      .snapshots()
      .map((s) => s.docs.map((d) => Caliber.fromMap(d.id, d.data())).toList());

  Stream<List<Bullet>> watchBullets() => _service
      .userCollection('bullets')
      .snapshots()
      .map((s) => s.docs.map((d) => Bullet.fromMap(d.id, d.data())).toList());

  Stream<List<Powder>> watchPowders() => _service
      .userCollection('powders')
      .snapshots()
      .map((s) => s.docs.map((d) => Powder.fromMap(d.id, d.data())).toList());

  Stream<List<Primer>> watchPrimers() => _service
      .userCollection('primers')
      .snapshots()
      .map((s) => s.docs.map((d) => Primer.fromMap(d.id, d.data())).toList());

  Stream<List<Brass>> watchBrass() => _service
      .userCollection('brass')
      .snapshots()
      .map((s) => s.docs.map((d) => Brass.fromMap(d.id, d.data())).toList());

  Future<void> addCaliber(Caliber c) =>
      _service.userCollection('calibers').add(c.toMap());
  Future<void> addBullet(Bullet b) =>
      _service.userCollection('bullets').add(b.toMap());
  Future<void> addPowder(Powder p) =>
      _service.userCollection('powders').add(p.toMap());
  Future<void> addPrimer(Primer p) =>
      _service.userCollection('primers').add(p.toMap());
  Future<void> addBrass(Brass b) =>
      _service.userCollection('brass').add(b.toMap());
}
