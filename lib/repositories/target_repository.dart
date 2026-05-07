// FILE: lib/repositories/target_repository.dart
//
// Owns reads against the [Targets] reference catalog. Targets are seeded
// from `assets/seed_data/targets.json` on first launch (see
// `seed_loader.dart`); this repository never writes to the table.
//
// Public methods:
//   * `watchAll()` — live `Stream<List<TargetRow>>` of every seeded
//     target, naturally sorted by name (so "AR500 12 in" lands after
//     "AR500 8 in").
//   * `getById(id)` — one-shot lookup of a single target.
//   * `getByCategory(category)` — list filtered to one of `paper`,
//     `steel`, `reactive`, `game-silhouette`. Used by the Range Day
//     filter chips above the picker.

import '../database/database.dart';
import '../utils/natural_sort.dart';

class TargetRepository {
  TargetRepository(this.db);
  final AppDatabase db;

  /// Streams every seeded target, naturally sorted by name. Re-emits
  /// when (rare) inserts happen via SeedLoader.
  Stream<List<TargetRow>> watchAll() {
    return db.select(db.targets).watch().map((rows) {
      final list = [...rows];
      list.sort((a, b) => naturalCompare(a.name, b.name));
      return list;
    });
  }

  /// Snapshot of every target, naturally sorted by name. Used by callers
  /// that just need the list once (e.g. the picker dropdown that renders
  /// inside a [DropdownMenu]).
  Future<List<TargetRow>> allTargets() async {
    final rows = await db.select(db.targets).get();
    final list = [...rows];
    list.sort((a, b) => naturalCompare(a.name, b.name));
    return list;
  }

  /// One-shot lookup by primary key.
  Future<TargetRow?> getById(int id) =>
      (db.select(db.targets)..where((t) => t.id.equals(id)))
          .getSingleOrNull();

  /// Filters by `category` (`paper | steel | reactive | game-silhouette`),
  /// naturally sorted by name. Used by the Range Day filter chips.
  Future<List<TargetRow>> getByCategory(String category) async {
    final rows = await (db.select(db.targets)
          ..where((t) => t.category.equals(category)))
        .get();
    final list = [...rows];
    list.sort((a, b) => naturalCompare(a.name, b.name));
    return list;
  }
}
