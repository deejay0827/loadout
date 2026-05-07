// FILE: lib/repositories/batch_repository.dart
//
// ============================================================================
// WHAT THIS FILE DOES
// ============================================================================
// Owns all database operations for `Batches`, the table that tracks each
// physical run of loaded ammunition the user has built. A "batch" is the
// concrete, countable thing on the shelf — distinct from a "recipe"
// (the abstract specification) and a "brass lot" (the case stockpile).
// Each batch row references a recipe (what to build), a brass lot (what
// cases to use), and a firearm (intended use), each as nullable foreign
// keys.
//
// Public methods on `BatchRepository`:
//   * `watchAll()` — returns `Stream<List<BatchWithRefs>>`, where
//     `BatchWithRefs` is a record class (a Dart 3 tuple type) bundling
//     each batch with its joined recipe, brass lot, and firearm rows.
//     The list view subscribes via `StreamBuilder` and rebuilds whenever
//     ANY of the four base tables (batches, recipes, brass lots,
//     firearms) emit a change. This is what makes the batch list feel
//     "alive" — a recipe rename or a brass-lot count change updates the
//     batch list immediately without manual refresh.
//   * `getAll()` — one-shot variant of `watchAll`. Same join semantics,
//     no subscription.
//   * `getById(id)` / `watchById(id)` — single-row lookups, one-shot or
//     live.
//   * `insert(entry)` / `update(id, entry)` / `delete(id)` — standard
//     CRUD. `update` auto-bumps `updatedAt`.
//   * `setProcessState(id, json)` — overwrites the saved checklist
//     state for the per-batch process steps (the JSON blob holds which
//     of the user's process steps have been completed for THIS batch).
//   * `recordFiring(id, delta)` — bumps `firedCount` by `delta`,
//     clamped to `[0, count]`. The brass-lot cascade is the **caller's**
//     responsibility: the batch detail screen calls
//     `BrassLotRepository.recordFiring` separately so the two updates
//     can be presented to the user as a single action with shared error
//     handling. See "WHY HARDER THAN IT LOOKS" below.
//
// At the bottom of the file is a private free function `_combineLatest4`
// — a 4-arity stream combinator. Drift's API only ships up to
// `combineLatest3`, but `BatchWithRefs` joins four tables, so this
// helper fills the gap.
//
// Pseudo-code for the typical batch list:
//   batchRepo.watchAll().listen((batches) {
//     for (final b in batches) {
//       print('Batch ${b.batch.id} - recipe ${b.recipe?.caliber}'
//             ' from lot ${b.brassLot?.name} for ${b.firearm?.name}');
//     }
//   });
//
// ============================================================================
// WHY IT EXISTS IN THE ARCHITECTURE
// ============================================================================
// The repository pattern. Batches deserve a dedicated repository because
// they are the interaction point between three other domain entities
// (recipes, brass lots, firearms), and pulling those joins together in
// one place keeps the list-view widget readable. If we let the screen
// build the joined `BatchWithRefs` itself, every change would touch
// both UI and data layers.
//
// Constructed in `lib/app.dart` as `BatchRepository(db)` and provided
// to the widget tree.
//
// (Quick Dart-3 pointer for newcomers: `typedef BatchWithRefs = ({...})`
// declares a **record type** — basically an anonymous class with named
// fields. `({BatchRow batch, UserLoadRow? recipe, ...})` is a type that
// holds those fields. Records are immutable, structurally typed, and
// don't need an explicit class declaration. Compare to a tuple in
// Python, except every member has a name.)
//
// ============================================================================
// WHY THIS IS HARDER THAN IT LOOKS
// ============================================================================
// 1. **The custom 4-arity stream join.** Drift exposes `.watch()` on
//    each table query, returning a stream that emits the latest result
//    of that query whenever its underlying table changes. To show a
//    list with joined data that LIVE-updates when any of the four base
//    tables change, we need to combine four streams. RxDart and many
//    Stream packages provide `combineLatest3` and `combineLatest4`, but
//    we don't pull RxDart in for this single use case. Instead,
//    `_combineLatest4` at the bottom of this file does it manually:
//      - holds the latest event from each source in `la/lb/lc/ld`,
//      - tracks "have I seen at least one event from this source yet"
//        in `sa/sb/sc/sd`,
//      - emits a combined value only once all four sources have
//        emitted at least once,
//      - re-emits on every subsequent emission from any source,
//      - cancels every upstream subscription when the downstream
//        subscription is cancelled (the `controller.onCancel` hook).
//    Why streams instead of one big query? Because keying the list view
//    off `db.userLoads.watch()` etc. lets drift's change-tracker decide
//    when to re-emit; we don't have to manually invalidate.
//
// 2. **The N+1 lookup pattern, on purpose.** `watchAll` builds three
//    `Map<int, Row>` in-memory dictionaries (`loadById`, `lotById`,
//    `firearmById`) and looks each batch's foreign keys up in those.
//    A purist might write a 4-table SQL JOIN. We don't, because:
//      a) drift's stream-watching is per-query — a JOIN gives you ONE
//         stream that re-emits on any of the involved tables, but the
//         per-row maps let us reuse the small base streams for other
//         consumers (and for `getAll`).
//      b) the batch list is small (tens, maybe low hundreds of rows)
//         so the in-memory join is fast.
//
// 3. **The brass-lot cascade is INTENTIONALLY split.** `recordFiring`
//    on this repository only updates the batch's `firedCount`. It does
//    NOT touch the linked brass lot. The contract is that the caller
//    (typically `BatchDetailScreen`) calls
//    `BrassLotRepository.recordFiring(brassLotId, delta)` immediately
//    after, so both sides of the cascade happen in the same UI event
//    handler with shared error reporting. If you need true atomicity,
//    wrap both calls at the call site in `db.transaction(() async {
//    ... })`. Future-you: do not "helpfully" inline the brass-lot
//    write inside this method without revisiting the screens that
//    already call them in pairs.
//
// 4. **`firedCount` clamping.** The clamp is `[0, count]` (not `[0,
//    1 << 31]` like the brass-lot counters), because firing more
//    rounds than were built is a UI bug, not a real-world possibility.
//
// ============================================================================
// WHO CONSUMES THIS FILE
// ============================================================================
// - lib/screens/batches/batches_list_screen.dart — calls `watchAll()`
//   for the live list and renders `BatchWithRefs.recipe.caliber` /
//   `.brassLot.name` / `.firearm.name` in the subtitle.
// - lib/screens/batches/batch_form_screen.dart — calls `getById`,
//   `insert`, `update`.
// - lib/screens/batches/batch_detail_screen.dart — calls `watchById`
//   for live updates of one batch, plus `recordFiring` /
//   `setProcessState` from user actions.
// - lib/app.dart — constructs and provides the singleton.
//
// ============================================================================
// SIDE EFFECTS
// ============================================================================
// Reads and writes against the local SQLite database via drift. No JSON
// decode happens here, but `setProcessState` writes a string the caller
// has already JSON-encoded; the schema column is just `TEXT`, the
// caller defines the format. **Cross-table cascade caveat:**
// `recordFiring` does NOT chain to the linked brass lot — the call
// site is responsible for that.

import 'dart:async';

import 'package:drift/drift.dart';

import '../database/database.dart';

/// Tuple returned by [BatchRepository.watchAll] / [BatchRepository.getAll].
/// Bundles the [BatchRow] together with the joined recipe / brass lot /
/// firearm rows so the list view can render a rich subtitle without
/// firing one query per row.
typedef BatchWithRefs = ({
  BatchRow batch,
  UserLoadRow? recipe,
  BrassLotRow? brassLot,
  UserFirearmRow? firearm,
});

class BatchRepository {
  BatchRepository(this.db);
  final AppDatabase db;

  // ─────────────────────── Reads ───────────────────────

  /// Watches every batch joined with its referenced recipe / brass lot /
  /// firearm rows. Implemented as a `combineLatest` over the four base
  /// table streams — Drift doesn't ship a 4-arity stream combinator, so
  /// the helper is in this file.
  Stream<List<BatchWithRefs>> watchAll() {
    final batches = (db.select(db.batches)
          ..orderBy([(b) => OrderingTerm.desc(b.updatedAt)]))
        .watch();
    final loads = db.select(db.userLoads).watch();
    final lots = db.select(db.brassLots).watch();
    final firearms = db.select(db.userFirearms).watch();

    return _combineLatest4<List<BatchRow>, List<UserLoadRow>,
        List<BrassLotRow>, List<UserFirearmRow>, List<BatchWithRefs>>(
      batches,
      loads,
      lots,
      firearms,
      (bs, ls, bls, fs) {
        final loadById = {for (final l in ls) l.id: l};
        final lotById = {for (final l in bls) l.id: l};
        final firearmById = {for (final f in fs) f.id: f};
        return [
          for (final b in bs)
            (
              batch: b,
              recipe: b.recipeId == null ? null : loadById[b.recipeId!],
              brassLot:
                  b.brassLotId == null ? null : lotById[b.brassLotId!],
              firearm:
                  b.firearmId == null ? null : firearmById[b.firearmId!],
            ),
        ];
      },
    );
  }

  /// One-shot variant of [watchAll].
  Future<List<BatchWithRefs>> getAll() async {
    final bs = await (db.select(db.batches)
          ..orderBy([(b) => OrderingTerm.desc(b.updatedAt)]))
        .get();
    if (bs.isEmpty) return const [];
    final ls = await db.select(db.userLoads).get();
    final bls = await db.select(db.brassLots).get();
    final fs = await db.select(db.userFirearms).get();
    final loadById = {for (final l in ls) l.id: l};
    final lotById = {for (final l in bls) l.id: l};
    final firearmById = {for (final f in fs) f.id: f};
    return [
      for (final b in bs)
        (
          batch: b,
          recipe: b.recipeId == null ? null : loadById[b.recipeId!],
          brassLot: b.brassLotId == null ? null : lotById[b.brassLotId!],
          firearm: b.firearmId == null ? null : firearmById[b.firearmId!],
        ),
    ];
  }

  Future<BatchRow?> getById(int id) =>
      (db.select(db.batches)..where((b) => b.id.equals(id)))
          .getSingleOrNull();

  Stream<BatchRow?> watchById(int id) =>
      (db.select(db.batches)..where((b) => b.id.equals(id)))
          .watchSingleOrNull();

  // ─────────────────────── Writes ───────────────────────

  Future<int> insert(BatchesCompanion entry) =>
      db.into(db.batches).insert(entry);

  Future<bool> update(int id, BatchesCompanion entry) =>
      (db.update(db.batches)..where((b) => b.id.equals(id)))
          .write(entry.copyWith(updatedAt: Value(DateTime.now())))
          .then((rows) => rows > 0);

  Future<int> delete(int id) =>
      (db.delete(db.batches)..where((b) => b.id.equals(id))).go();

  /// Replace the saved process-step checklist state.
  Future<void> setProcessState(int id, String json) async {
    await (db.update(db.batches)..where((b) => b.id.equals(id))).write(
      BatchesCompanion(
        processStateJson: Value(json),
        updatedAt: Value(DateTime.now()),
      ),
    );
  }

  /// Increments [firedCount] by [delta] (typically positive). Clamped at
  /// `[0, count]` so we don't show "Fired 110/100".
  ///
  /// The brass-lot cascade is the caller's responsibility — the batch
  /// detail screen calls [BrassLotRepository.recordFiring] separately when
  /// `brassLotId` is set so the two updates can be presented atomically in
  /// the same UI action.
  Future<void> recordFiring(int id, int delta) async {
    final row = await getById(id);
    if (row == null) return;
    final next = (row.firedCount + delta).clamp(0, row.count);
    await (db.update(db.batches)..where((b) => b.id.equals(id))).write(
      BatchesCompanion(
        firedCount: Value(next),
        updatedAt: Value(DateTime.now()),
      ),
    );
  }
}

/// 4-arity `combineLatest`. Emits a combined value once every source has
/// produced at least one event, then again on every subsequent emission
/// from any source. Cancels every upstream subscription when the
/// downstream subscription is cancelled.
Stream<R> _combineLatest4<A, B, C, D, R>(
  Stream<A> a,
  Stream<B> b,
  Stream<C> c,
  Stream<D> d,
  R Function(A a, B b, C c, D d) combine,
) {
  final controller = StreamController<R>();
  A? la;
  B? lb;
  C? lc;
  D? ld;
  bool sa = false, sb = false, sc = false, sd = false;
  late final List<StreamSubscription<dynamic>> subs;

  void emit() {
    if (sa && sb && sc && sd) {
      controller.add(combine(la as A, lb as B, lc as C, ld as D));
    }
  }

  controller.onListen = () {
    subs = [
      a.listen((v) {
        la = v;
        sa = true;
        emit();
      }, onError: controller.addError),
      b.listen((v) {
        lb = v;
        sb = true;
        emit();
      }, onError: controller.addError),
      c.listen((v) {
        lc = v;
        sc = true;
        emit();
      }, onError: controller.addError),
      d.listen((v) {
        ld = v;
        sd = true;
        emit();
      }, onError: controller.addError),
    ];
  };
  controller.onCancel = () async {
    for (final s in subs) {
      await s.cancel();
    }
  };
  return controller.stream;
}
