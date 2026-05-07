import 'package:drift/drift.dart';

import '../database/database.dart';

/// CRUD + reordering helpers for [UserProcessSteps].
///
/// The eight default steps were seeded by the v4 migration with
/// `isStandard: true`. Standard steps can be renamed and re-toggled but
/// cannot be deleted; only user-added (`isStandard == false`) steps can
/// be removed.
class ProcessStepRepository {
  ProcessStepRepository(this.db);
  final AppDatabase db;

  Stream<List<UserProcessStepRow>> watchAll() =>
      (db.select(db.userProcessSteps)
            ..orderBy([(s) => OrderingTerm.asc(s.sortOrder)]))
          .watch();

  Future<List<UserProcessStepRow>> getAll() =>
      (db.select(db.userProcessSteps)
            ..orderBy([(s) => OrderingTerm.asc(s.sortOrder)]))
          .get();

  Future<UserProcessStepRow?> getById(int id) =>
      (db.select(db.userProcessSteps)..where((s) => s.id.equals(id)))
          .getSingleOrNull();

  /// Returns the steps that apply to the given caliber `type`, in display
  /// order. `type` is `'pistol' | 'rifle' | 'shotgun'`. Used by the batch
  /// detail screen to render the per-batch checklist.
  Future<List<UserProcessStepRow>> stepsForType(String type) async {
    final all = await getAll();
    bool applies(UserProcessStepRow s) {
      switch (type) {
        case 'pistol':
          return s.appliesToPistol;
        case 'shotgun':
          return s.appliesToShotgun;
        case 'rifle':
        default:
          return s.appliesToRifle;
      }
    }

    return all.where(applies).toList();
  }

  /// Insert a brand-new (user-defined) step. Always non-standard, default
  /// rifle-only as documented.
  Future<int> insertCustom({
    required String name,
    String? description,
    bool appliesToPistol = false,
    bool appliesToRifle = true,
    bool appliesToShotgun = false,
  }) async {
    final maxOrder = await _maxSortOrder();
    return db.into(db.userProcessSteps).insert(
          UserProcessStepsCompanion.insert(
            name: name,
            sortOrder: maxOrder + 1,
            appliesToPistol: Value(appliesToPistol),
            appliesToRifle: Value(appliesToRifle),
            appliesToShotgun: Value(appliesToShotgun),
            isStandard: const Value(false),
            description: Value(description),
          ),
        );
  }

  Future<bool> update(int id, UserProcessStepsCompanion entry) =>
      (db.update(db.userProcessSteps)..where((s) => s.id.equals(id)))
          .write(entry)
          .then((rows) => rows > 0);

  /// Deletes a non-standard step. Standard steps return `false` without
  /// touching the database — the caller should suppress its delete UI for
  /// `isStandard` rows.
  Future<bool> delete(int id) async {
    final row = await getById(id);
    if (row == null || row.isStandard) return false;
    final n = await (db.delete(db.userProcessSteps)
          ..where((s) => s.id.equals(id)))
        .go();
    return n > 0;
  }

  /// Persists the new ordering after a long-press drag. Pass the steps in
  /// the order the user just arranged them; this method writes
  /// monotonically-increasing `sortOrder` values starting at 1.
  Future<void> reorder(List<UserProcessStepRow> ordered) async {
    await db.transaction(() async {
      for (int i = 0; i < ordered.length; i++) {
        await (db.update(db.userProcessSteps)
              ..where((s) => s.id.equals(ordered[i].id)))
            .write(UserProcessStepsCompanion(
          sortOrder: Value(i + 1),
        ));
      }
    });
  }

  Future<int> _maxSortOrder() async {
    final rows = await getAll();
    int maxOrder = 0;
    for (final r in rows) {
      if (r.sortOrder > maxOrder) maxOrder = r.sortOrder;
    }
    return maxOrder;
  }
}
