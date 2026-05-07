import 'package:drift/drift.dart';

import '../database/database.dart';

/// CRUD + lifecycle helpers for [BrassLots].
///
/// [count] is the number of cases currently on hand for the lot, while
/// [firingCount] is the number of times those cases have been through a
/// firing cycle. They move independently:
///
///   * `recordFiring` increments [firingCount] without touching [count] —
///     a 100-case lot still has 100 cases after the trip; it's just one
///     firing closer to needing an anneal.
///   * `adjustCount` is for replenishment / loss tracking (e.g. tossing a
///     split case).
class BrassLotRepository {
  BrassLotRepository(this.db);
  final AppDatabase db;

  Stream<List<BrassLotRow>> watchAll() => (db.select(db.brassLots)
        ..orderBy([
          (l) => OrderingTerm.asc(l.caliber),
          (l) => OrderingTerm.asc(l.name),
        ]))
      .watch();

  Future<List<BrassLotRow>> getAll() => (db.select(db.brassLots)
        ..orderBy([
          (l) => OrderingTerm.asc(l.caliber),
          (l) => OrderingTerm.asc(l.name),
        ]))
      .get();

  Future<BrassLotRow?> getById(int id) =>
      (db.select(db.brassLots)..where((l) => l.id.equals(id)))
          .getSingleOrNull();

  Future<int> insert(BrassLotsCompanion entry) =>
      db.into(db.brassLots).insert(entry);

  Future<bool> update(int id, BrassLotsCompanion entry) =>
      (db.update(db.brassLots)..where((l) => l.id.equals(id)))
          .write(entry.copyWith(updatedAt: Value(DateTime.now())))
          .then((rows) => rows > 0);

  Future<int> delete(int id) =>
      (db.delete(db.brassLots)..where((l) => l.id.equals(id))).go();

  /// Bumps [firingCount] by [delta] (typically positive). Used by the lot
  /// detail screen and by the batch-fire cascade. Clamped to non-negative.
  Future<void> recordFiring(int id, int delta) async {
    final current = await getById(id);
    if (current == null) return;
    final next = (current.firingCount + delta).clamp(0, 1 << 31);
    await (db.update(db.brassLots)..where((l) => l.id.equals(id))).write(
      BrassLotsCompanion(
        firingCount: Value(next),
        updatedAt: Value(DateTime.now()),
      ),
    );
  }

  /// Adjusts the on-hand case [count] by [delta] (can be negative). Clamped
  /// at zero. For losses, splits, lost cases at the range, etc.
  Future<void> adjustCount(int id, int delta) async {
    final current = await getById(id);
    if (current == null) return;
    final next = (current.count + delta).clamp(0, 1 << 31);
    await (db.update(db.brassLots)..where((l) => l.id.equals(id))).write(
      BrassLotsCompanion(
        count: Value(next),
        updatedAt: Value(DateTime.now()),
      ),
    );
  }

  /// Sets [count] directly. Used when the user wants to re-baseline (e.g.
  /// after counting cases in the bin).
  Future<void> setCount(int id, int newCount) async {
    final v = newCount < 0 ? 0 : newCount;
    await (db.update(db.brassLots)..where((l) => l.id.equals(id))).write(
      BrassLotsCompanion(
        count: Value(v),
        updatedAt: Value(DateTime.now()),
      ),
    );
  }

  /// Marks the lot as just-annealed: stamps [lastAnnealed] = now and
  /// records the [method].
  Future<void> markAnnealed(int id, String? method) async {
    await (db.update(db.brassLots)..where((l) => l.id.equals(id))).write(
      BrassLotsCompanion(
        lastAnnealed: Value(DateTime.now()),
        annealMethod: Value(method),
        updatedAt: Value(DateTime.now()),
      ),
    );
  }
}
