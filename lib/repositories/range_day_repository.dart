// FILE: lib/repositories/range_day_repository.dart
//
// Owns CRUD over [RangeDaySessions] and [ShotImpacts]. The Range Day
// workspace lets the user record where each shot landed during a range
// trip and re-runs the ballistics solver as wind / environment / range
// changes; this repository is the persistence side of that.
//
// Public methods on [RangeDayRepository]:
//
//   * `watchAll()` — live `Stream<List<RangeDaySessionRow>>`, newest
//     first by `date`. Used by the sessions list at the top of the
//     Range Day screen.
//   * `getById(id)` — one-shot single-session lookup.
//   * `insertSession(entry)` — insert; returns the new id.
//   * `updateSession(id, entry)` — update; auto-bumps `updatedAt`.
//   * `deleteSession(id)` — hard delete. Cascades to ShotImpacts via
//     an explicit child-row delete (drift does NOT enforce ON DELETE
//     CASCADE — we do it ourselves, in a transaction).
//
//   Shot impact CRUD (children of a session):
//   * `streamShotsForSession(sessionId)` — live stream of shots for one
//     session, ordered by `shotNumber`. The visual target widget reads
//     this to render the impact dots.
//   * `shotsForSession(sessionId)` — one-shot snapshot, same order.
//   * `insertShot(entry)` — insert a single impact; returns the id.
//   * `updateShot(id, entry)` — update notes / coords on an existing
//     impact.
//   * `deleteShot(id)` — hard delete a single impact.
//   * `clearShotsForSession(sessionId)` — drop every shot in a session
//     (for the "Clear all shots" confirm flow).
//   * `nextShotNumberForSession(sessionId)` — returns the highest
//     existing `shotNumber` + 1, or 1 if none. Used by the tap-to-record
//     flow so each new shot gets a stable, monotonically increasing
//     label.

import 'package:drift/drift.dart';

import '../database/database.dart';

class RangeDayRepository {
  RangeDayRepository(this.db);
  final AppDatabase db;

  // ─────────────────────── Sessions ───────────────────────

  /// Streams every session, most-recent first. Driven from `date`
  /// (the user-facing range-trip date) rather than `updatedAt` so the
  /// list ordering matches the user's mental model even after they
  /// edit an old session's notes.
  Stream<List<RangeDaySessionRow>> watchAll() =>
      (db.select(db.rangeDaySessions)
            ..orderBy([(s) => OrderingTerm.desc(s.date)]))
          .watch();

  Future<RangeDaySessionRow?> getById(int id) =>
      (db.select(db.rangeDaySessions)..where((s) => s.id.equals(id)))
          .getSingleOrNull();

  Future<int> insertSession(RangeDaySessionsCompanion entry) =>
      db.into(db.rangeDaySessions).insert(entry);

  Future<bool> updateSession(int id, RangeDaySessionsCompanion entry) =>
      (db.update(db.rangeDaySessions)..where((s) => s.id.equals(id)))
          .write(entry.copyWith(updatedAt: Value(DateTime.now())))
          .then((rows) => rows > 0);

  /// Hard-deletes a session and every shot impact recorded against it.
  /// Wrapped in a transaction so a partial delete can never leave
  /// orphan shots referencing a missing session.
  Future<void> deleteSession(int id) async {
    await db.transaction(() async {
      await (db.delete(db.shotImpacts)
            ..where((s) => s.rangeDaySessionId.equals(id)))
          .go();
      await (db.delete(db.rangeDaySessions)..where((s) => s.id.equals(id)))
          .go();
    });
  }

  // ─────────────────────── Shot impacts ───────────────────────

  /// Live stream of shots for [sessionId], ordered by `shotNumber`
  /// ascending. The visual target widget subscribes to this so each
  /// new tap appears immediately.
  Stream<List<ShotImpactRow>> streamShotsForSession(int sessionId) {
    return (db.select(db.shotImpacts)
          ..where((s) => s.rangeDaySessionId.equals(sessionId))
          ..orderBy([(s) => OrderingTerm.asc(s.shotNumber)]))
        .watch();
  }

  /// One-shot snapshot of shots for [sessionId], same ordering as the
  /// stream. Used by the group-statistics calculator.
  Future<List<ShotImpactRow>> shotsForSession(int sessionId) {
    return (db.select(db.shotImpacts)
          ..where((s) => s.rangeDaySessionId.equals(sessionId))
          ..orderBy([(s) => OrderingTerm.asc(s.shotNumber)]))
        .get();
  }

  Future<int> insertShot(ShotImpactsCompanion entry) =>
      db.into(db.shotImpacts).insert(entry);

  Future<bool> updateShot(int id, ShotImpactsCompanion entry) =>
      (db.update(db.shotImpacts)..where((s) => s.id.equals(id)))
          .write(entry)
          .then((rows) => rows > 0);

  Future<int> deleteShot(int id) =>
      (db.delete(db.shotImpacts)..where((s) => s.id.equals(id))).go();

  Future<int> clearShotsForSession(int sessionId) =>
      (db.delete(db.shotImpacts)
            ..where((s) => s.rangeDaySessionId.equals(sessionId)))
          .go();

  /// Returns the next shot number to use for [sessionId]. Computed by
  /// finding the max existing `shotNumber` and adding 1; returns 1 if
  /// no shots exist yet. Not transactional — we accept a tiny race
  /// window because realistic input is one shot per ~5 seconds.
  Future<int> nextShotNumberForSession(int sessionId) async {
    final shots = await shotsForSession(sessionId);
    if (shots.isEmpty) return 1;
    final maxN = shots.map((s) => s.shotNumber).reduce((a, b) => a > b ? a : b);
    return maxN + 1;
  }
}
