import '../models/load.dart';
import '../services/firestore_service.dart';

class LoadRepository {
  LoadRepository({FirestoreService? service})
      : _service = service ?? FirestoreService();

  final FirestoreService _service;

  Stream<List<Load>> watchAll() {
    return _service.userCollection('loads').snapshots().map(
          (snap) => snap.docs.map((d) => Load.fromMap(d.id, d.data())).toList(),
        );
  }

  Future<void> add(Load load) =>
      _service.userCollection('loads').add(load.toMap());

  Future<void> update(Load load) =>
      _service.userCollection('loads').doc(load.id).update(load.toMap());

  Future<void> delete(String id) =>
      _service.userCollection('loads').doc(id).delete();
}
