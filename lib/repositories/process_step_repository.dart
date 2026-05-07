// FILE: lib/repositories/process_step_repository.dart
//
// ============================================================================
// WHAT THIS FILE DOES
// ============================================================================
// Owns all database operations for `UserProcessSteps`, the user-curated
// list of reloading process steps (e.g. "Tumble brass", "Resize",
// "Trim", "Prime", "Charge", "Seat", "Crimp"). This is the master list
// that powers the per-batch checklist on the batch detail screen.
//
// Each step has applicability flags for `pistol`, `rifle`, and `shotgun`,
// because a few steps (e.g. trim length checks) only matter for some
// caliber types. Each step also has an `isStandard` flag — eight default
// steps were seeded by the schema-v4 migration with `isStandard: true`.
// Standard steps can be renamed and re-toggled but cannot be deleted;
// only user-added steps (`isStandard: false`) can be removed.
//
// Public methods on `ProcessStepRepository`:
//   * `watchAll()` / `getAll()` — live stream / one-shot list of all
//     process steps in display order (`sortOrder` ascending).
//   * `getById(id)` — single-row lookup.
//   * `stepsForType(type)` — returns the subset of steps applicable to
//     a given caliber type. `type` is one of `'pistol' | 'rifle' |
//     'shotgun'` (anything else falls through to `'rifle'` as a
//     defensive default). Used by the batch detail screen to render
//     the per-batch checklist with the right items hidden.
//   * `insertCustom({name, description, appliesToPistol, ...})` — add
//     a brand-new user-defined step. Always non-standard. Default
//     applicability is rifle-only; pass the named flags to override.
//     The new step is automatically appended to the end of the list
//     (sortOrder = current max + 1).
//   * `update(id, entry)` — generic update. Note: unlike most other
//     repositories in this project, this one does NOT auto-bump an
//     `updatedAt` timestamp because the schema doesn't have one — the
//     process-step list is conceptually a config/setting, not user
//     data with a history.
//   * `delete(id)` — only succeeds for non-standard steps. Returns
//     `false` (and writes nothing) for standard rows; the caller
//     should suppress its delete UI for `isStandard: true` items.
//   * `reorder(ordered)` — persists a new ordering after a long-press
//     drag in the settings screen. Pass the steps in their new order;
//     the method writes monotonically-increasing `sortOrder` values
//     starting at 1, all in a single drift transaction so no
//     intermediate inconsistent state is visible.
//
// Pseudo-code for the batch checklist:
//   final steps = await processRepo.stepsForType('rifle');
//   for (final step in steps) {
//     final done = batchProcessState.contains(step.id);
//     // render checklist row
//   }
//
// ============================================================================
// WHY IT EXISTS IN THE ARCHITECTURE
// ============================================================================
// Same repository-pattern reasoning. Worth a short note on the
// settings/data divide: process-step definitions are config (what
// steps exist, in what order, with what applicability), while
// per-batch completion is data (which steps are done on THIS batch).
// The completion state lives on `Batches.processStateJson` (managed
// by `BatchRepository.setProcessState`), not here. This split lets
// the user edit the master list freely — adding, renaming,
// reordering — without invalidating any batch's completion state.
//
// Constructed in `lib/app.dart` as `ProcessStepRepository(db)` and
// provided to the widget tree.
//
// ============================================================================
// WHY THIS IS HARDER THAN IT LOOKS
// ============================================================================
// 1. **Reorder-in-a-transaction.** `reorder()` rewrites the
//    `sortOrder` column on every row in the supplied list. Doing this
//    naively (one update per row outside a transaction) would mean
//    each `watch()` subscriber sees N intermediate states as the
//    rewrites trickle in. Wrapping the loop in `db.transaction(() async
//    { ... })` makes the entire batch of writes atomic — drift only
//    notifies its watchers once, after the transaction commits, so the
//    list view animates a single jump from old order to new order.
//    Critical for a smooth drag-and-drop UX.
//
// 2. **Standard-vs-custom asymmetry.** Standard steps are protected
//    against deletion at the repository layer (the early return in
//    `delete`), not at the schema layer. The schema has no foreign
//    key cascade or check constraint preventing it; the rule lives
//    here. UI code should also hide its delete affordance when
//    `isStandard: true`, but if it doesn't, this method's `false`
//    return is the safety net.
//
// 3. **`stepsForType` does not query in SQL.** It loads everything
//    via `getAll()` and filters in Dart. With 8 default + a handful
//    of user-added steps, an in-memory filter is far cheaper than
//    rebuilding a SQL query for each of three possible types.
//
// 4. **Default applicability is "rifle-only".** `insertCustom` defaults
//    `appliesToRifle: true`, the others false. Most reloaders are
//    primarily rifle shooters and a step-not-shown is more annoying
//    than a step-shown-when-not-needed. The form screen typically
//    presents toggles for all three so the user can pick.
//
// ============================================================================
// WHO CONSUMES THIS FILE
// ============================================================================
// - lib/screens/process_steps/* (settings screen for managing the
//   master step list) — calls `watchAll`, `insertCustom`, `update`,
//   `delete`, `reorder`.
// - lib/screens/batches/batch_detail_screen.dart — calls
//   `stepsForType(batch.callerType)` to render the per-batch
//   checklist. The completion state is persisted via
//   `BatchRepository.setProcessState`.
// - lib/app.dart — constructs and provides the singleton.
//
// ============================================================================
// SIDE EFFECTS
// ============================================================================
// Reads and writes against the local SQLite database via drift. The
// `reorder` method opens a drift transaction; everything else uses
// auto-committed single statements. No JSON encode/decode here (the
// `processStateJson` blob lives on `Batches`, not on
// `UserProcessSteps`). No cross-table cascades.

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
