// FILE: lib/repositories/target_repository.dart
//
// ============================================================================
// WHAT THIS FILE DOES
// ============================================================================
// Owns reads against the [Targets] reference catalog AND the parallel
// [TargetRacks] / [TargetRackChildren] catalog. Both are seeded from JSON
// in `assets/seed_data/` on first launch (see `seed_loader.dart`); this
// repository never writes to either table.
//
// Single-target methods:
//   * `watchAll()` — live `Stream<List<TargetRow>>` of every seeded
//     target, naturally sorted by name (so "AR500 12 in" lands after
//     "AR500 8 in").
//   * `allTargets()` — one-shot snapshot version of `watchAll`.
//   * `getById(id)` — one-shot lookup of a single target.
//   * `getByCategory(category)` — list filtered to one of `paper`,
//     `steel`, `reactive`, `game-silhouette`. Used by the Range Day
//     filter chips above the picker.
//
// Target-rack methods:
//   * `allRacks()` — every seeded rack, naturally sorted by name.
//   * `rackById(id)` — one-shot lookup of a single rack.
//   * `childrenOf(rackId)` — every child of one rack, ordered by
//     `position`. Used by the visual renderer + the active-child picker.
//
// ============================================================================
// WHY IT EXISTS IN THE ARCHITECTURE
// ============================================================================
// The Range Day workspace renders both individual targets and multi-target
// racks. Keeping all of those reads behind one repository keeps the call
// sites short and the test seams obvious — every screen takes an
// `AppDatabase`-backed `TargetRepository` from `app.dart` and calls these
// methods directly, never `db.select(...)` inline.
//
// ============================================================================
// WHY THIS IS HARDER THAN IT LOOKS
// ============================================================================
// The rack catalog has two physical tables (parent + children with a FK).
// We deliberately do NOT join here — the renderer wants the parent
// envelope first (to scale the FOV) and only fetches children once the
// rack is on-screen. Returning a single denormalized `(rack, [children])`
// list would force every caller to walk a list-of-lists; instead each
// caller asks for what it needs. `childrenOf` is sorted by `position`
// rather than `name` because position is the rack's intended engagement
// order (left-to-right or near-to-far) and is what the renderer / picker
// treat as the canonical sort key.
//
// ============================================================================
// WHO CONSUMES THIS FILE
// ============================================================================
// - `lib/screens/range_day/range_day_detail_screen.dart` — target + rack
//   pickers.
// - Anywhere a screen needs to display the seeded target / rack catalog.
//
// ============================================================================
// SIDE EFFECTS
// ============================================================================
// - Reads only. No INSERT / UPDATE / DELETE on either catalog table.

import 'package:drift/drift.dart' show OrderingTerm;

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

  /// Filters by SHAPE (`circle | square | rectangle | silhouette |
  /// star | bear | boar | deer | elk | coyote`), naturally sorted by
  /// name. Used by the Range Day filter chips. Replaces the legacy
  /// `getByCategory` which keyed off the `category` column dropped in
  /// schema v28 (per user feedback: reloaders pick by geometry, not
  /// material).
  Future<List<TargetRow>> getByShape(String shape) async {
    final rows = await (db.select(db.targets)
          ..where((t) => t.shape.equals(shape)))
        .get();
    final list = [...rows];
    list.sort((a, b) => naturalCompare(a.name, b.name));
    return list;
  }

  // ─────────────────────── Target racks ───────────────────────

  /// Every seeded rack, naturally sorted by name. Naturally-sorted so
  /// "10-Plate KYL" lands after "5-Plate KYL" — ASCII-sort would put
  /// it first because '1' < '5'.
  Future<List<TargetRackRow>> allRacks() async {
    final rows = await db.select(db.targetRacks).get();
    final list = [...rows];
    list.sort((a, b) => naturalCompare(a.name, b.name));
    return list;
  }

  /// One-shot lookup of a single rack by primary key. Returns null if
  /// the rack id was deleted (e.g. a stale id persisted on a session
  /// row that got re-seeded).
  Future<TargetRackRow?> rackById(int id) =>
      (db.select(db.targetRacks)..where((r) => r.id.equals(id)))
          .getSingleOrNull();

  /// Every child of `rackId`, ordered by `position` (the rack's
  /// intended engagement sequence). Empty list when the rack has no
  /// children — caller should treat that as a malformed seed entry,
  /// since every seeded rack ships at least one child.
  Future<List<TargetRackChildRow>> childrenOf(int rackId) =>
      (db.select(db.targetRackChildren)
            ..where((c) => c.rackId.equals(rackId))
            ..orderBy([(c) => OrderingTerm.asc(c.position)]))
          .get();
}
