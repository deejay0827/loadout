// FILE: lib/repositories/firearm_repository.dart
//
// ============================================================================
// WHAT THIS FILE DOES
// ============================================================================
// Owns all database operations for the user's personal firearms inventory —
// the rifles, pistols, and shotguns the user has added on the Firearms
// screen. The underlying drift table is `UserFirearms` (defined in
// `lib/database/database.dart`); this file is the only Dart code that
// reads or writes it.
//
// Public methods on `FirearmRepository`:
//   * `watchAll()` — returns a live `Stream<List<UserFirearmRow>>` of every
//     firearm the user has added, alphabetized by name. The list view
//     subscribes via `StreamBuilder` and rebuilds whenever a row is
//     inserted, updated, or deleted — no manual refresh required.
//     Pseudo-code: `firearmRepo.watchAll().listen((rows) => render(rows));`
//   * `getById(id)` — one-shot lookup of a single firearm row. Returns
//     `null` if no row matches. Used by the form screen when the user
//     opens an existing firearm to edit it.
//   * `insert(entry)` — insert a new firearm; returns the new row's
//     primary key.
//   * `update(id, entry)` — update an existing firearm. Auto-bumps the
//     `updatedAt` timestamp on the way through. Returns `true` if a row
//     was actually changed.
//   * `delete(id)` — hard-delete by primary key. Returns the number of
//     rows deleted (0 or 1).
//   * `adjustShotsFired(id, delta)` — increments (or decrements, with
//     a negative delta) the `shotsFired` counter on a firearm, clamped
//     to non-negative. Used by the firearm detail screen for tracking
//     barrel life across range trips.
//
// The schema also has a nullable `referenceFirearmId` foreign key that
// links a user-owned firearm back to a row in the seeded `FirearmsRef`
// catalog. Setting that link happens through the normal `update` /
// `insert` path — there is no dedicated `linkToReferenceFirearm` method;
// callers just set the field on the companion before calling `update`.
//
// ============================================================================
// WHY IT EXISTS IN THE ARCHITECTURE
// ============================================================================
// Same repository pattern as the rest of the app. The screen widgets
// (`firearms_list_screen.dart`, `firearm_form_screen.dart`) never call
// drift APIs directly — they call this repository, which centralizes the
// query construction (e.g. ordering by `name`) and the `updatedAt` bump
// rules. If we ever needed to add validation, audit logging, or a sync
// hook, this is the single place that would change.
//
// The repository is constructed once in `lib/app.dart` and provided to
// the widget tree via `Provider<FirearmRepository>`. Screens read it with
// `context.read<FirearmRepository>()`.
//
// (For Dart/Flutter newcomers: drift uses **companion** objects to
// represent "a row I'm building, but every column is optional". When you
// `insert(...)`, you pass a `UserFirearmsCompanion.insert(name: ..., type:
// ..., ...)` that drift turns into an SQL INSERT statement. The
// `Value(...)` wrapper distinguishes "set this column to null" from
// "leave this column alone". On update, columns wrapped in `Value(...)`
// are written; columns left out are not touched.)
//
// ============================================================================
// WHY THIS IS HARDER THAN IT LOOKS
// ============================================================================
// Mostly straightforward CRUD. Two subtleties worth flagging:
//
// 1. The `update` method auto-applies `updatedAt: Value(DateTime.now())`
//    via `entry.copyWith(updatedAt: Value(DateTime.now()))`. Callers do
//    NOT need to pass `updatedAt` themselves; if they do, this line
//    overwrites it. This guarantees the list view always sorts edited
//    rows correctly.
//
// 2. `adjustShotsFired` reads-then-writes — it has to load the current
//    count to compute the new value. This is not transactional, so a
//    pathological concurrent edit could lose an increment. In practice
//    the only writers are the form screen and the "fire batch" cascade,
//    which are user-driven and serialized by the UI thread, so the race
//    is theoretical. The clamp `(current.shotsFired + delta).clamp(0,
//    1 << 31)` prevents underflow when the user rolls back a counter
//    too far, and prevents overflow at 2^31 (an absurdly high count
//    that no realistic shooter will hit).
//
// ============================================================================
// WHO CONSUMES THIS FILE
// ============================================================================
// - lib/screens/firearms/firearms_list_screen.dart — calls `watchAll()`
//   to render the live list, and `delete(id)` from the swipe-to-delete
//   gesture.
// - lib/screens/firearms/firearm_form_screen.dart — calls `getById`,
//   `insert`, `update`. The form is reused for both "add" and "edit"
//   flows; which method runs depends on whether an `id` was passed in.
// - lib/screens/batches/* (or wherever the fire-batch flow lives) — calls
//   `adjustShotsFired` when the user marks rounds fired so the firearm's
//   shot counter ticks up alongside the batch's `firedCount`.
// - lib/app.dart — constructs and provides the singleton.
//
// ============================================================================
// SIDE EFFECTS
// ============================================================================
// Reads and writes against the local SQLite database via drift. No JSON
// encoding/decoding. No cross-table cascades (the firearm table is
// stand-alone — the brass-lot cascade lives in `BrassLotRepository`, and
// the batch's `firearmId` foreign key is purely informational, not
// enforced as ON DELETE CASCADE). No network. No shared preferences.

import 'package:drift/drift.dart';

import '../database/database.dart';

class FirearmRepository {
  FirearmRepository(this.db);
  final AppDatabase db;

  Stream<List<UserFirearmRow>> watchAll() =>
      (db.select(db.userFirearms)..orderBy([(f) => OrderingTerm.asc(f.name)]))
          .watch();

  Future<UserFirearmRow?> getById(int id) =>
      (db.select(db.userFirearms)..where((f) => f.id.equals(id)))
          .getSingleOrNull();

  Future<int> insert(UserFirearmsCompanion entry) =>
      db.into(db.userFirearms).insert(entry);

  Future<bool> update(int id, UserFirearmsCompanion entry) =>
      (db.update(db.userFirearms)..where((f) => f.id.equals(id)))
          .write(entry.copyWith(updatedAt: Value(DateTime.now())))
          .then((rows) => rows > 0);

  Future<int> delete(int id) =>
      (db.delete(db.userFirearms)..where((f) => f.id.equals(id))).go();

  /// Increment shots fired by [delta] (can be negative).
  Future<void> adjustShotsFired(int id, int delta) async {
    final current = await getById(id);
    if (current == null) return;
    final next = (current.shotsFired + delta).clamp(0, 1 << 31);
    await (db.update(db.userFirearms)..where((f) => f.id.equals(id))).write(
      UserFirearmsCompanion(
        shotsFired: Value(next),
        updatedAt: Value(DateTime.now()),
      ),
    );
  }
}
