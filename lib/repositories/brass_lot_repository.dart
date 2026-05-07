// FILE: lib/repositories/brass_lot_repository.dart
//
// ============================================================================
// WHAT THIS FILE DOES
// ============================================================================
// Owns all database operations for `BrassLots`, the table that tracks
// each batch (lot) of brass cases the user owns. A "lot" here means a
// box of cases that share a manufacturer, caliber, headstamp, and
// firing history — the granularity at which a reloader actually
// manages brass.
//
// Beyond standard CRUD, this repository exposes four lifecycle helpers
// that map onto how brass actually wears out and gets used:
//
//   * `recordFiring(id, delta)` — bump `firingCount` (how many times
//     these cases have been through a fire/resize cycle) by `delta`.
//     Does **not** change `count`. A 100-case lot still has 100 cases
//     after the trip; the cases are just one firing closer to needing
//     an anneal or being retired. Called from the brass lot detail
//     screen and from the batch-fire flow when the batch references
//     a lot.
//   * `adjustCount(id, delta)` — relative change to the on-hand
//     `count` (negative for split cases / lost at the range / scrap;
//     positive for re-stocking after picking up brass).
//   * `setCount(id, newCount)` — absolute set of `count`. Used when
//     the user wants to re-baseline by physically counting the bin.
//   * `markAnnealed(id, method)` — stamps `lastAnnealed = now()` and
//     records the method (e.g. "induction", "torch"). Used after a
//     batch annealing session.
//
// Standard CRUD: `watchAll`, `getAll`, `getById`, `insert`, `update`,
// `delete`. The list views are sorted by caliber then lot name so
// reloaders can find lots grouped the way they think about them.
//
// Pseudo-code for a typical fire-batch flow:
//   await brassLotRepo.recordFiring(lotId, batch.firedCount);
//   await batchRepo.recordFiring(batchId, batch.firedCount);
//
// ============================================================================
// WHY IT EXISTS IN THE ARCHITECTURE
// ============================================================================
// The repository pattern again. Why brass lots get their own repository
// (instead of riding inside `RecipeRepository`):
//   * Brass is the only consumable component with a non-trivial
//     lifecycle — counts, firings, annealing history, neck wall
//     thickness — so it benefits from a focused API.
//   * The brass-lot lifecycle is the cascade target when a batch fires
//     rounds. Putting that interaction inside the recipe repo would
//     blur layer boundaries; a dedicated repo keeps the cascade
//     visible.
//
// Constructed in `lib/app.dart` as `BrassLotRepository(db)` and
// provided to the widget tree. Screens use
// `context.read<BrassLotRepository>()`.
//
// ============================================================================
// WHY THIS IS HARDER THAN IT LOOKS
// ============================================================================
// The non-obvious part is the **cascade contract**: when the user marks
// rounds fired on a batch, two things have to happen — the batch's
// `firedCount` ticks up, AND the linked brass lot's `firingCount`
// ticks up. This file owns the second half of that cascade.
//
// The two writes are NOT performed in a single SQL transaction here;
// the batch detail screen calls them separately (via
// `BatchRepository.recordFiring` first, then `BrassLotRepository`
// .recordFiring`). This is intentional: the screen ties them together
// in a single user action with shared error handling, and a brief
// inconsistency window is harmless because the next read will reflect
// whichever update succeeded. If you ever need atomicity (e.g. for
// audit logging), wrap both calls in `db.transaction(() async { ... })`
// at the call site.
//
// `count` and `firingCount` are deliberately decoupled. A naive design
// would tie them together ("each firing decrements the count"), but
// that's wrong: a lot of 100 cases that has been fired 5 times is
// still 100 cases. They lose count only via splits, range loss, or
// retirement — events the user signals through `adjustCount`.
//
// Both `recordFiring` and `adjustCount` use `clamp(0, 1 << 31)` to
// guard against underflow when the user rolls a counter past zero,
// and against overflow at 2^31 (a meaningless huge number that no
// realistic shooter will hit). They are read-then-write, so a
// pathological concurrent edit could lose an increment — in practice
// the UI thread serializes these operations.
//
// ============================================================================
// WHO CONSUMES THIS FILE
// ============================================================================
// - lib/screens/brass_lots/* (the dedicated Brass Lots screens) —
//   primary owner; calls `watchAll()` for the list, the lifecycle
//   helpers from the detail screen.
// - lib/screens/batches/* (batch detail / fire flow) — calls
//   `recordFiring` as part of the cascade when a batch's firedCount
//   advances and `brassLotId` is set.
// - lib/screens/loads/load_form_screen.dart — references brass lots
//   via the recipe form, but creates them through
//   `RecipeRepository.createBrassLot` (which is a thin minimal-fields
//   wrapper around the same `BrassLots` table; the full lifecycle
//   stays here).
// - lib/app.dart — constructs and provides the singleton.
//
// ============================================================================
// SIDE EFFECTS
// ============================================================================
// Reads and writes against the local SQLite database via drift. No
// JSON encoding/decoding here. **Cross-table cascade caveat:** this
// repository is the cascade target when batches fire rounds — the
// caller (typically `BatchRepository` or the batch detail screen) is
// responsible for invoking `recordFiring` on this repo at the same
// time as on `Batches`. There is no automatic database trigger; the
// cascade is enforced at the application layer.

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
