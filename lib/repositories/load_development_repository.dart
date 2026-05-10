// FILE: lib/repositories/load_development_repository.dart
//
// ============================================================================
// WHAT THIS FILE DOES
// ============================================================================
// Owns all database operations and analysis algorithms for **load
// development sessions** — the schema-v5 feature (extended in v31)
// that lets a reloader run a structured load-development test. The
// app supports five named methods today:
//
//   * **OCW (Optimal Charge Weight, Newberry, ~2002)** — 3 shots per
//     charge across a charge ladder, looking for a flat spot in the
//     vertical-impact-vs-charge curve.
//   * **Audette Ladder (Audette, late 1970s)** — single shot per
//     charge fired at distance, looking for shots that "stack"
//     vertically.
//   * **Satterlee 10-shot (Satterlee)** — 10 chronograph rounds
//     stepping the charge by 0.1–0.2 gr, looking for an MV plateau.
//   * **Generic** — any user-defined data-collection workflow with
//     freeform per-rung measurements.
//   * **Seating depth** — CBTO ladder around an existing recipe.
//
// This file has six responsibilities:
//   1. CRUD over `LoadDevelopmentSessions` rows (the table that holds
//      the session metadata + a JSON blob of rung measurements).
//   2. CRUD over the `LoadDevelopmentShots` child table (per-shot
//      rows used by the OCW / Ladder / Satterlee / Generic methods
//      added in v31).
//   3. The `LadderRung` value class + JSON codec for parsing /
//      serializing the per-rung measurement bag.
//   4. The legacy ladder analysis methods — `analyzeChargeNode` and
//      `analyzeSeatingNode` — that turn the JSON-encoded rung data
//      into a recommended node value.
//   5. The new method-specific analysis methods — `analyzeOcwNode`,
//      `analyzeSatterleePlateau`, `computeLadderVerticalSpreadIn`,
//      and `computePerChargeStats` — that operate on the per-shot
//      rows.
//   6. Two recipe writebacks — `applySeatingNodeToRecipe` (CBTO) and
//      `applyChargeNodeToRecipe` (powder charge) — that push a
//      picked node back to the source `UserLoads` row.
//
// **Public types:**
//   * `LadderRung` — immutable record for one row of the ladder. Has
//     `index`, `value` (charge in grains OR CBTO in inches), `fired`
//     flag, and a bag of nullable measurement fields (`velocityAvgFps`,
//     `velocitySdFps`, `velocityEsFps`, `sampleSize`, `groupMoa`,
//     `verticalMoa`, `horizontalMoa`, `distanceYd`, `pressureNotes`,
//     `notes`). Provides `toJson`, `fromJson`, `copyWith`, and
//     `hasData` helpers.
//   * `ChargeAnalysis` — outcome record from `analyzeChargeNode`,
//     bundling `rungsAnalyzed`, `medianSd`, `clusterIndices`, and the
//     `recommendedValue` (the node).
//   * `SeatingAnalysis` — outcome record from `analyzeSeatingNode`
//     with `rungsAnalyzed`, `bestIndex`, `bestScore`, and
//     `recommendedValue` (the recommended CBTO).
//
// **Public methods on `LoadDevelopmentRepository`:**
//
//   CRUD
//     * `watchAll()` — live stream of every session, newest-edited first.
//     * `getAll()` — one-shot variant.
//     * `getById(id)` / `watchById(id)` — single-row lookups.
//     * `insert(entry)` / `update(id, entry)` / `delete(id)` — standard CRUD.
//     * `setRungs(id, rungs)` — JSON-encodes a `List<LadderRung>` and
//       writes it to the session's `rungsJson` column.
//     * `setNode(id, nodeValue)` — persist a chosen node value.
//
//   Static rung helpers
//     * `decodeRungs(raw)` — parse the `rungsJson` blob back into a
//       `List<LadderRung>`. Malformed JSON returns `[]` (the UI stays
//       usable rather than crashing).
//     * `generateRungs({start, end, step})` — produce a deterministic
//       list of rung values from `start` (inclusive) through `end`,
//       stepping by `step`. Defensive fallbacks for `step <= 0` or
//       `end <= start`. All values rounded to 4 decimals.
//     * `buildInitialRungs({start, end, step})` — convenience: wrap
//       the `generateRungs` output in a `List<LadderRung>` with
//       sequential indices and no measurements. Used when starting a
//       new session.
//     * `round(v, places)` — public stable rounding (used by tests
//       and the UI to match repository precision).
//
//   Static analysis (the heart of the file)
//     * `analyzeChargeNode(rungs)` — see "WHY HARDER THAN IT LOOKS".
//     * `analyzeSeatingNode(rungs)` — see same.
//
//   Recipe writeback
//     * `applySeatingNodeToRecipe({recipeId, cbtoIn})` — when the
//       seating analysis picks a winner, push the chosen CBTO back to
//       the source recipe by writing `cbtoIn` (rounded to 4 decimals)
//       on the `UserLoads` row.
//
// Pseudo-code for a typical session lifecycle:
//   final values = generateRungs(start: 41.0, end: 43.0, step: 0.2);
//   final initialRungs = buildInitialRungs(start: 41.0, end: 43.0, step: 0.2);
//   await repo.setRungs(sessionId, initialRungs);
//   // ...user shoots, enters chrono data per rung, calls setRungs again...
//   final analysis = LoadDevelopmentRepository.analyzeChargeNode(latestRungs);
//   if (analysis.recommendedValue != null) {
//     await repo.setNode(sessionId, analysis.recommendedValue!);
//   }
//
// ============================================================================
// WHY IT EXISTS IN THE ARCHITECTURE
// ============================================================================
// Three reasons this gets its own repository:
//   1. The CRUD shape is unique — sessions store nested measurement data
//      as a JSON blob, not as joined rows. A dedicated repo is the
//      cleanest place to own that JSON encode/decode boundary.
//   2. The analysis algorithms are computationally substantial and
//      best kept out of the widget layer. Putting them on the
//      repository keeps them testable in isolation (they're `static`
//      methods that don't even need a database connection).
//   3. The recipe writeback (`applySeatingNodeToRecipe`) is a
//      cross-table operation: a session's analysis result writes back
//      to `UserLoads`. Owning that cross-table write here keeps the
//      flow visible in one file.
//
// Constructed in `lib/app.dart` as `LoadDevelopmentRepository(db)` and
// provided to the widget tree.
//
// (For Dart/Flutter readers new to this idiom: `static` methods on a
// class are just namespaced free functions — they don't need an
// instance and don't touch instance state. The analysis algorithms
// are `static` precisely so they can be called and tested without
// constructing a repository or opening a database.)
//
// ============================================================================
// WHY THIS IS HARDER THAN IT LOOKS
// ============================================================================
// 1. **Storing rungs as JSON instead of rows.** `Rungs` could live in
//    a dedicated `LoadDevelopmentRungs` table with foreign keys, but
//    we store them as a JSON-encoded text column on the session.
//    Tradeoffs:
//      Pro: a session is loaded with one query; saving rungs is one
//      atomic write; schema migrations don't need to touch an
//      auxiliary table; the rung shape can evolve without a migration
//      because `LadderRung.fromJson` ignores unknown keys and provides
//      defaults for missing ones.
//      Con: you cannot SQL-query across rungs (e.g. "find every rung
//      with SD < 5"); every analysis happens in Dart on the decoded
//      list.
//      Mitigation: `decodeRungs` is forgiving — malformed JSON, missing
//      keys, and stray types all degrade to sensible defaults so the
//      UI stays usable even if a future migration leaves a session in
//      a half-decoded state.
//
// 2. **`analyzeChargeNode` (the OCW / Satterlee node finder).**
//    Algorithm:
//      a) Filter to rungs that have a `velocitySdFps`. Need at least 3
//         to do anything useful; below that, return an empty result.
//      b) Compute the **median** velocity SD across those rungs (not
//         the mean — median is robust against one wild rung).
//      c) Walk the rungs in index order looking for the longest run
//         of CONSECUTIVE rungs whose SD is `<= median`.
//      d) The recommended node is the value of the rung at the centre
//         of the winning run (rounded down for even-length clusters
//         via integer division).
//    Why "longest consecutive low-SD run"? Reloaders call this an
//    "OCW node" (Optimal Charge Weight) or "Satterlee node": when
//    several adjacent charge weights all produce similar (low)
//    velocity spread, the load is on an internal-pressure plateau and
//    is forgiving of small powder-charge variation — meaning your
//    load tolerates the tiny day-to-day differences between thrown
//    charges and humidity-affected powder.
//
// 3. **`analyzeSeatingNode` (the seating-depth optimizer).**
//    Algorithm:
//      a) For each rung that has at least one of `groupMoa` or
//         `verticalMoa`, compute the unweighted mean of whatever
//         values are present.
//      b) The rung with the SMALLEST mean wins.
//    Why average group + vertical (and not average group +
//    horizontal)? In seating-depth ladders, vertical dispersion is the
//    primary thing the user is trying to flatten — large horizontals
//    in a seating ladder usually point at wind or shooter error rather
//    than the load itself. Vertical alone can be too noisy if only
//    a few shots are fired, so we average it with overall group size
//    to add a bit of stability.
//
// 4. **`applySeatingNodeToRecipe` is deliberately conservative.** It
//    writes only `cbtoIn`, not `seatingDepthIn`. We could derive the
//    seating depth from CBTO + bullet base-to-ogive, but that math is
//    too brittle to do silently — leave the second number to the user.
//    The comment in the method preserves this rationale.
//
// 5. **`generateRungs` has loop-safety.** The `while (v <= end + 1e-9)`
//    loop has a `safety < 1000` cap to prevent infinite loops if
//    floating-point drift makes the increment fail to advance. The
//    `1e-9` epsilon on the loop bound and the explicit final-rung
//    clamp ensure the user gets exactly the rungs they asked for
//    even when `end - start` isn't an exact multiple of `step`.
//
// 6. **The `_unset` sentinel pattern in `copyWith`.** Dart's named
//    parameters can't distinguish "argument not passed" from
//    "argument passed as null" for nullable types. To support
//    "explicitly clear this nullable field", `copyWith` uses a private
//    sentinel object (`_unset`) as the default. `identical(arg, _unset)`
//    means the caller didn't touch the field; anything else means
//    they did, even null. This is a standard Dart trick for nullable
//    `copyWith`.
//
// ============================================================================
// WHO CONSUMES THIS FILE
// ============================================================================
// - lib/screens/load_development/* (the load-development screens for
//   listing, creating, editing, and analyzing ladder sessions) —
//   primary owner; calls every method on this repository.
// - lib/screens/loads/load_form_screen.dart — passively benefits from
//   `applySeatingNodeToRecipe` (the recipe row gets `cbtoIn` updated
//   when the user accepts a seating node from the development screen).
// - lib/app.dart — constructs and provides the singleton.
// - test/* — the static analysis methods and `generateRungs` /
//   `decodeRungs` are designed to be tested in isolation without a
//   database.
//
// ============================================================================
// SIDE EFFECTS
// ============================================================================
// Reads and writes against the local SQLite database via drift. JSON
// encode/decode at the boundary for `rungsJson`. **Cross-table write:**
// `applySeatingNodeToRecipe` writes to `UserLoads`, not to
// `LoadDevelopmentSessions`, so this repository does write outside
// its primary table. That single cross-table write is the deliberate
// price of keeping the seating-node-applies-to-recipe flow visible in
// one file rather than spread across two repositories.

import 'dart:convert';
import 'dart:math' as math;

import 'package:drift/drift.dart';

import '../database/database.dart';

/// Per-rung measurement bag, decoded from
/// [LoadDevelopmentSessionRow.rungsJson].
///
/// A "rung" is one row on the ladder — a single test load whose only
/// distinguishing feature from its neighbours is the variable being
/// optimized. For a charge-weight ladder, [value] is the powder charge in
/// grains; for a seating-depth ladder, [value] is the CBTO in inches.
///
/// All measurement fields are nullable: rungs are created with their
/// values set when the ladder is generated, but chrono / accuracy data
/// only arrives after the user has shot the rung at the range.
class LadderRung {
  const LadderRung({
    required this.index,
    required this.value,
    this.fired = false,
    this.velocityAvgFps,
    this.velocitySdFps,
    this.velocityEsFps,
    this.sampleSize,
    this.groupMoa,
    this.verticalMoa,
    this.horizontalMoa,
    this.distanceYd,
    this.pressureNotes,
    this.notes,
  });

  final int index;
  final double value;
  final bool fired;
  final double? velocityAvgFps;
  final double? velocitySdFps;
  final double? velocityEsFps;
  final int? sampleSize;
  final double? groupMoa;
  final double? verticalMoa;
  final double? horizontalMoa;
  final int? distanceYd;
  final String? pressureNotes;
  final String? notes;

  /// True when at least one chrono / accuracy field has been entered.
  /// Used by the analysis algorithms to decide which rungs are eligible
  /// for inclusion in the cluster / minimum-finder pass.
  bool get hasData =>
      velocityAvgFps != null ||
      velocitySdFps != null ||
      velocityEsFps != null ||
      groupMoa != null ||
      verticalMoa != null ||
      horizontalMoa != null;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'index': index,
        'value': value,
        'fired': fired,
        if (velocityAvgFps != null) 'velocityAvgFps': velocityAvgFps,
        if (velocitySdFps != null) 'velocitySdFps': velocitySdFps,
        if (velocityEsFps != null) 'velocityEsFps': velocityEsFps,
        if (sampleSize != null) 'sampleSize': sampleSize,
        if (groupMoa != null) 'groupMoa': groupMoa,
        if (verticalMoa != null) 'verticalMoa': verticalMoa,
        if (horizontalMoa != null) 'horizontalMoa': horizontalMoa,
        if (distanceYd != null) 'distanceYd': distanceYd,
        if (pressureNotes != null) 'pressureNotes': pressureNotes,
        if (notes != null) 'notes': notes,
      };

  factory LadderRung.fromJson(Map<String, dynamic> json) {
    double? readDouble(dynamic v) {
      if (v == null) return null;
      if (v is num) return v.toDouble();
      return double.tryParse(v.toString());
    }

    int? readInt(dynamic v) {
      if (v == null) return null;
      if (v is int) return v;
      if (v is num) return v.toInt();
      return int.tryParse(v.toString());
    }

    return LadderRung(
      index: readInt(json['index']) ?? 0,
      value: readDouble(json['value']) ?? 0.0,
      fired: json['fired'] == true,
      velocityAvgFps: readDouble(json['velocityAvgFps']),
      velocitySdFps: readDouble(json['velocitySdFps']),
      velocityEsFps: readDouble(json['velocityEsFps']),
      sampleSize: readInt(json['sampleSize']),
      groupMoa: readDouble(json['groupMoa']),
      verticalMoa: readDouble(json['verticalMoa']),
      horizontalMoa: readDouble(json['horizontalMoa']),
      distanceYd: readInt(json['distanceYd']),
      pressureNotes: json['pressureNotes'] as String?,
      notes: json['notes'] as String?,
    );
  }

  LadderRung copyWith({
    int? index,
    double? value,
    bool? fired,
    Object? velocityAvgFps = _unset,
    Object? velocitySdFps = _unset,
    Object? velocityEsFps = _unset,
    Object? sampleSize = _unset,
    Object? groupMoa = _unset,
    Object? verticalMoa = _unset,
    Object? horizontalMoa = _unset,
    Object? distanceYd = _unset,
    Object? pressureNotes = _unset,
    Object? notes = _unset,
  }) {
    return LadderRung(
      index: index ?? this.index,
      value: value ?? this.value,
      fired: fired ?? this.fired,
      velocityAvgFps: identical(velocityAvgFps, _unset)
          ? this.velocityAvgFps
          : velocityAvgFps as double?,
      velocitySdFps: identical(velocitySdFps, _unset)
          ? this.velocitySdFps
          : velocitySdFps as double?,
      velocityEsFps: identical(velocityEsFps, _unset)
          ? this.velocityEsFps
          : velocityEsFps as double?,
      sampleSize:
          identical(sampleSize, _unset) ? this.sampleSize : sampleSize as int?,
      groupMoa:
          identical(groupMoa, _unset) ? this.groupMoa : groupMoa as double?,
      verticalMoa: identical(verticalMoa, _unset)
          ? this.verticalMoa
          : verticalMoa as double?,
      horizontalMoa: identical(horizontalMoa, _unset)
          ? this.horizontalMoa
          : horizontalMoa as double?,
      distanceYd:
          identical(distanceYd, _unset) ? this.distanceYd : distanceYd as int?,
      pressureNotes: identical(pressureNotes, _unset)
          ? this.pressureNotes
          : pressureNotes as String?,
      notes: identical(notes, _unset) ? this.notes : notes as String?,
    );
  }

  static const Object _unset = Object();
}

/// Outcome of [LoadDevelopmentRepository.analyzeChargeNode].
class ChargeAnalysis {
  const ChargeAnalysis({
    required this.rungsAnalyzed,
    required this.medianSd,
    required this.clusterIndices,
    required this.recommendedValue,
  });

  /// Total rungs included in the analysis (those with a velocity SD).
  final int rungsAnalyzed;

  /// Median velocity SD across the analyzed rungs. Used as the
  /// threshold for the "low-SD" cluster detector.
  final double medianSd;

  /// Indices of the longest run of consecutive rungs whose velocity SD
  /// is at or below the median. Empty if no consecutive cluster exists.
  final List<int> clusterIndices;

  /// Recommended node — the rung value at the middle of the winning
  /// cluster, or `null` if no cluster was found.
  final double? recommendedValue;
}

/// Per-charge statistical roll-up (mean / SD / ES of velocity, mean POI,
/// group size). Returned by
/// [LoadDevelopmentRepository.computePerChargeStats] for every charge
/// weight that has at least one shot logged.
class PerChargeStats {
  const PerChargeStats({
    required this.chargeGr,
    required this.shotCount,
    required this.meanVelocityFps,
    required this.sdVelocityFps,
    required this.esVelocityFps,
    required this.meanXIn,
    required this.meanYIn,
    required this.extremeSpreadIn,
    required this.meanRadiusIn,
  });

  /// Charge weight in grains. The bucket key.
  final double chargeGr;
  /// Number of shots logged at this charge weight.
  final int shotCount;
  /// Sample mean of velocity readings (fps). Null when no chrono data
  /// at this charge.
  final double? meanVelocityFps;
  /// Sample standard deviation of velocity (fps). Null when fewer than
  /// 2 chrono readings at this charge.
  final double? sdVelocityFps;
  /// Extreme spread of velocity (max - min, in fps). Null when no
  /// chrono data.
  final double? esVelocityFps;
  /// Mean X impact (inches, positive right). Null when no impact data.
  final double? meanXIn;
  /// Mean Y impact (inches, positive UP). Null when no impact data.
  final double? meanYIn;
  /// Group extreme spread — the largest center-to-center distance
  /// between any two impacts in this charge bucket. Null when fewer
  /// than 2 impact rows.
  final double? extremeSpreadIn;
  /// Mean radius — the average distance from each impact to the group
  /// centroid. Null when no impact data.
  final double? meanRadiusIn;
}

/// Outcome of [LoadDevelopmentRepository.analyzeOcwNode].
///
/// OCW (Optimal Charge Weight, Newberry) looks for a "flat spot" in
/// the **vertical point-of-impact vs. charge weight** curve. A flat
/// spot identifies a charge range where small powder variations don't
/// change the bullet's vertical landing position — the load is at a
/// barrel-time harmonic node.
class OcwAnalysis {
  const OcwAnalysis({
    required this.chargesAnalyzed,
    required this.flatChargeIndices,
    required this.maxVerticalSpreadIn,
    required this.recommendedChargeGr,
  });

  /// Number of distinct charges with at least one impact-Y row.
  final int chargesAnalyzed;
  /// Charge weights that are part of the recommended flat spot. Empty
  /// when no flat spot was found.
  final List<double> flatChargeIndices;
  /// Vertical-impact spread allowed inside the flat-spot detector.
  /// Default detector threshold is `maxVerticalSpreadIn` inches between
  /// adjacent charges. Stored on the result so callers / tests can
  /// inspect the threshold.
  final double maxVerticalSpreadIn;
  /// Recommended OCW charge — the centre of the longest run of
  /// consecutive charge weights whose mean vertical impact is within
  /// the threshold. Null when no flat spot exists.
  final double? recommendedChargeGr;
}

/// Outcome of [LoadDevelopmentRepository.analyzeSatterleePlateau].
///
/// Satterlee 10-shot looks for a **velocity plateau** — a run of
/// consecutive charge weights where the mean velocity barely changes
/// even though the charge stepped up. The plateau is the load's
/// pressure node; loads tuned to the centre of the plateau tolerate
/// small powder-charge drift better than the surrounding ramp.
class SatterleeAnalysis {
  const SatterleeAnalysis({
    required this.chargesAnalyzed,
    required this.plateauChargeIndices,
    required this.maxVelocityRiseFps,
    required this.recommendedChargeGr,
  });

  /// Number of distinct charges with at least one velocity reading.
  final int chargesAnalyzed;
  /// Charge weights inside the recommended plateau. Empty when no
  /// plateau was found.
  final List<double> plateauChargeIndices;
  /// Per-step velocity rise (fps) the detector treats as "still flat."
  /// Stored on the result for inspection.
  final double maxVelocityRiseFps;
  /// Recommended charge — the centre of the longest plateau.
  final double? recommendedChargeGr;
}

/// Outcome of [LoadDevelopmentRepository.analyzeSeatingNode].
class SeatingAnalysis {
  const SeatingAnalysis({
    required this.rungsAnalyzed,
    required this.bestIndex,
    required this.bestScore,
    required this.recommendedValue,
  });

  final int rungsAnalyzed;
  final int? bestIndex;
  final double? bestScore;

  /// Recommended CBTO — the rung value with the lowest mean of
  /// (groupMoa, verticalMoa) across the analyzed rungs, or `null` if
  /// nothing scored.
  final double? recommendedValue;
}

class LoadDevelopmentRepository {
  LoadDevelopmentRepository(this.db);
  final AppDatabase db;

  // ─────────────────────── CRUD ───────────────────────

  Stream<List<LoadDevelopmentSessionRow>> watchAll() =>
      (db.select(db.loadDevelopmentSessions)
            ..orderBy([(s) => OrderingTerm.desc(s.updatedAt)]))
          .watch();

  Future<List<LoadDevelopmentSessionRow>> getAll() =>
      (db.select(db.loadDevelopmentSessions)
            ..orderBy([(s) => OrderingTerm.desc(s.updatedAt)]))
          .get();

  Future<LoadDevelopmentSessionRow?> getById(int id) =>
      (db.select(db.loadDevelopmentSessions)..where((s) => s.id.equals(id)))
          .getSingleOrNull();

  Stream<LoadDevelopmentSessionRow?> watchById(int id) =>
      (db.select(db.loadDevelopmentSessions)..where((s) => s.id.equals(id)))
          .watchSingleOrNull();

  Future<int> insert(LoadDevelopmentSessionsCompanion entry) =>
      db.into(db.loadDevelopmentSessions).insert(entry);

  Future<bool> update(int id, LoadDevelopmentSessionsCompanion entry) =>
      (db.update(db.loadDevelopmentSessions)..where((s) => s.id.equals(id)))
          .write(entry.copyWith(updatedAt: Value(DateTime.now())))
          .then((rows) => rows > 0);

  /// Delete one session **and** every per-shot row that belongs to it.
  /// Done inside a transaction so the FK constraint can't fire mid-flight.
  Future<int> delete(int id) async {
    return await db.transaction(() async {
      await (db.delete(db.loadDevelopmentShots)
            ..where((s) => s.sessionId.equals(id)))
          .go();
      return await (db.delete(db.loadDevelopmentSessions)
            ..where((s) => s.id.equals(id)))
          .go();
    });
  }

  /// Persist [rungs] back to the session JSON column. Bumps `updatedAt`
  /// implicitly via [update].
  Future<bool> setRungs(int id, List<LadderRung> rungs) async {
    final encoded = json.encode(rungs.map((r) => r.toJson()).toList());
    return await (db.update(db.loadDevelopmentSessions)
            ..where((s) => s.id.equals(id)))
        .write(LoadDevelopmentSessionsCompanion(
          rungsJson: Value(encoded),
          updatedAt: Value(DateTime.now()),
        ))
        .then((rows) => rows > 0);
  }

  /// Persist a chosen [nodeValue] back to the session.
  Future<bool> setNode(int id, double nodeValue) async {
    return await (db.update(db.loadDevelopmentSessions)
            ..where((s) => s.id.equals(id)))
        .write(LoadDevelopmentSessionsCompanion(
          nodeValue: Value(nodeValue),
          updatedAt: Value(DateTime.now()),
        ))
        .then((rows) => rows > 0);
  }

  // ─────────────────────── Rung helpers ───────────────────────

  /// Decode the `rungsJson` column on a row into a list of [LadderRung]s.
  /// Always returns at least an empty list; malformed JSON degrades to
  /// the empty list to keep the UI usable.
  static List<LadderRung> decodeRungs(String raw) {
    if (raw.isEmpty) return const <LadderRung>[];
    try {
      final data = json.decode(raw);
      if (data is! List) return const <LadderRung>[];
      final out = <LadderRung>[];
      for (final entry in data) {
        if (entry is Map) {
          out.add(LadderRung.fromJson(entry.cast<String, dynamic>()));
        }
      }
      return out;
    } catch (_) {
      return const <LadderRung>[];
    }
  }

  /// Generate evenly-spaced rung values from [start] (inclusive) up
  /// through [end], stepping by [step]. The final rung is clamped to
  /// [end] when the step doesn't land exactly. Negative or zero
  /// [step] returns a single rung at [start].
  ///
  /// All values are rounded to four decimal places to avoid the typical
  /// floating-point trail (e.g. `41.30000000000001`) sneaking into
  /// labels and JSON.
  static List<double> generateRungs({
    required double start,
    required double end,
    required double step,
  }) {
    if (step <= 0) return <double>[_round4(start)];
    if (end <= start) return <double>[_round4(start)];
    final out = <double>[];
    double v = start;
    int safety = 0;
    while (v <= end + 1e-9 && safety < 1000) {
      out.add(_round4(v));
      v += step;
      safety++;
    }
    if (out.isEmpty || out.last < end - 1e-9) {
      out.add(_round4(end));
    }
    return out;
  }

  /// Convenience: build the initial rungs list for a new session.
  static List<LadderRung> buildInitialRungs({
    required double start,
    required double end,
    required double step,
  }) {
    final values = generateRungs(start: start, end: end, step: step);
    return [
      for (var i = 0; i < values.length; i++)
        LadderRung(index: i, value: values[i]),
    ];
  }

  // ─────────────────────── Analysis ───────────────────────

  /// Charge-ladder analysis.
  ///
  /// Algorithm: take the rungs that have a `velocitySdFps`, compute the
  /// median SD across them, then walk the rungs in order looking for
  /// the longest stretch of consecutive rungs whose SD is `<= median`.
  /// The recommended node is the value of the rung at the centre of
  /// that stretch (rounded down for even-length clusters).
  ///
  /// The "consecutive low-SD" pattern is the classic OCW / Satterlee
  /// "node" — when several adjacent charge weights all produce similar
  /// (low) velocity spread, the load is operating at an internal
  /// pressure plateau and is forgiving of small powder-charge variation.
  static ChargeAnalysis analyzeChargeNode(List<LadderRung> rungs) {
    final scored = rungs
        .where((r) => r.velocitySdFps != null && r.velocitySdFps! > 0)
        .toList()
      ..sort((a, b) => a.index.compareTo(b.index));

    if (scored.length < 3) {
      return ChargeAnalysis(
        rungsAnalyzed: scored.length,
        medianSd: 0,
        clusterIndices: const <int>[],
        recommendedValue: null,
      );
    }

    final sds = scored.map((r) => r.velocitySdFps!).toList()..sort();
    final mid = sds.length ~/ 2;
    final medianSd = sds.length.isOdd
        ? sds[mid]
        : (sds[mid - 1] + sds[mid]) / 2.0;

    // Walk the scored rungs (which are already in index order) and find
    // the longest consecutive sub-list whose SD is at or below median.
    var bestStart = -1;
    var bestLength = 0;
    var curStart = -1;
    var curLength = 0;
    for (var i = 0; i < scored.length; i++) {
      final sd = scored[i].velocitySdFps!;
      if (sd <= medianSd) {
        if (curLength == 0) curStart = i;
        curLength++;
        if (curLength > bestLength) {
          bestLength = curLength;
          bestStart = curStart;
        }
      } else {
        curLength = 0;
        curStart = -1;
      }
    }

    if (bestStart < 0 || bestLength == 0) {
      return ChargeAnalysis(
        rungsAnalyzed: scored.length,
        medianSd: medianSd,
        clusterIndices: const <int>[],
        recommendedValue: null,
      );
    }

    final clusterRungIndices = <int>[
      for (var i = bestStart; i < bestStart + bestLength; i++) scored[i].index,
    ];
    final centerRung = scored[bestStart + (bestLength ~/ 2)];
    return ChargeAnalysis(
      rungsAnalyzed: scored.length,
      medianSd: medianSd,
      clusterIndices: clusterRungIndices,
      recommendedValue: centerRung.value,
    );
  }

  /// Seating-depth analysis.
  ///
  /// Algorithm: for each rung that has at least one of `groupMoa` or
  /// `verticalMoa`, compute the mean of whatever values are present.
  /// The rung with the smallest score wins.
  ///
  /// Vertical dispersion is weighted equally with overall group size
  /// because in seating-depth optimization vertical is the primary
  /// thing the user is trying to flatten — large horizontals in a
  /// seating ladder usually point at wind or shooter error rather than
  /// the load itself.
  static SeatingAnalysis analyzeSeatingNode(List<LadderRung> rungs) {
    int? bestIdx;
    double? bestScore;
    int analyzed = 0;
    for (final r in rungs) {
      final samples = <double>[
        if (r.groupMoa != null && r.groupMoa! > 0) r.groupMoa!,
        if (r.verticalMoa != null && r.verticalMoa! > 0) r.verticalMoa!,
      ];
      if (samples.isEmpty) continue;
      analyzed++;
      final score = samples.reduce((a, b) => a + b) / samples.length;
      if (bestScore == null || score < bestScore) {
        bestScore = score;
        bestIdx = r.index;
      }
    }
    if (bestIdx == null) {
      return const SeatingAnalysis(
        rungsAnalyzed: 0,
        bestIndex: null,
        bestScore: null,
        recommendedValue: null,
      );
    }
    final winner = rungs.firstWhere((r) => r.index == bestIdx);
    return SeatingAnalysis(
      rungsAnalyzed: analyzed,
      bestIndex: bestIdx,
      bestScore: bestScore,
      recommendedValue: winner.value,
    );
  }

  // ─────────────────────── Per-shot CRUD (v31) ───────────────────────

  /// Stream every shot belonging to [sessionId], ordered by charge
  /// then by shotIndex.
  Stream<List<LoadDevelopmentShotRow>> watchShots(int sessionId) =>
      (db.select(db.loadDevelopmentShots)
            ..where((s) => s.sessionId.equals(sessionId))
            ..orderBy([
              (s) => OrderingTerm.asc(s.chargeGr),
              (s) => OrderingTerm.asc(s.shotIndex),
            ]))
          .watch();

  /// One-shot variant of [watchShots] for places that don't want a stream.
  Future<List<LoadDevelopmentShotRow>> getShots(int sessionId) =>
      (db.select(db.loadDevelopmentShots)
            ..where((s) => s.sessionId.equals(sessionId))
            ..orderBy([
              (s) => OrderingTerm.asc(s.chargeGr),
              (s) => OrderingTerm.asc(s.shotIndex),
            ]))
          .get();

  /// Insert one shot row, returning the new id.
  Future<int> insertShot(LoadDevelopmentShotsCompanion entry) =>
      db.into(db.loadDevelopmentShots).insert(entry);

  /// Update an existing shot row by id. Returns true when at least one
  /// row was rewritten.
  Future<bool> updateShot(int id, LoadDevelopmentShotsCompanion entry) =>
      (db.update(db.loadDevelopmentShots)..where((s) => s.id.equals(id)))
          .write(entry)
          .then((rows) => rows > 0);

  /// Delete one shot row.
  Future<int> deleteShot(int id) =>
      (db.delete(db.loadDevelopmentShots)..where((s) => s.id.equals(id)))
          .go();

  /// Wipe every shot for [sessionId]. Used when the session is
  /// deleted; called inside a transaction for atomicity.
  Future<int> deleteShotsForSession(int sessionId) => (db
          .delete(db.loadDevelopmentShots)
        ..where((s) => s.sessionId.equals(sessionId)))
      .go();

  // ─────────────────────── OCW analysis (Newberry) ───────────────────────

  /// Optimal Charge Weight detection on the **vertical-impact-vs-charge**
  /// curve.
  ///
  /// Algorithm:
  ///   1. Group [shots] by `chargeGr`. Compute mean Y impact per
  ///      charge from rows where `impactYIn != null`.
  ///   2. Sort the (charge, meanY) pairs by charge ascending.
  ///   3. Walk the sorted pairs and find the longest consecutive run
  ///      where `|meanY[i] - meanY[i-1]| <= verticalThresholdIn`.
  ///   4. The recommended charge is the centre of the winning run
  ///      (rounded down for even-length).
  ///
  /// Default `verticalThresholdIn` is 0.5 inches at the user's
  /// distance — Newberry's heuristic that "the bullet didn't move
  /// vertically with the charge change." Caller can override at any
  /// distance.
  ///
  /// Reference: Newberry, Dan. "Optimal Charge Weight Load
  /// Development." 2002 onward. Method published on 6mmBR.com and the
  /// OCW website (`ocwreloading.com`).
  static OcwAnalysis analyzeOcwNode(
    List<LoadDevelopmentShotRow> shots, {
    double verticalThresholdIn = 0.5,
  }) {
    final byCharge = <double, List<double>>{};
    for (final s in shots) {
      if (s.impactYIn == null) continue;
      final key = _round4(s.chargeGr);
      byCharge.putIfAbsent(key, () => <double>[]).add(s.impactYIn!);
    }
    if (byCharge.length < 3) {
      return OcwAnalysis(
        chargesAnalyzed: byCharge.length,
        flatChargeIndices: const <double>[],
        maxVerticalSpreadIn: verticalThresholdIn,
        recommendedChargeGr: null,
      );
    }
    final entries = byCharge.entries
        .map((e) => (
              charge: e.key,
              meanY: e.value.reduce((a, b) => a + b) / e.value.length,
            ))
        .toList()
      ..sort((a, b) => a.charge.compareTo(b.charge));

    var bestStart = -1;
    var bestLength = 1;
    var curStart = 0;
    var curLength = 1;
    for (var i = 1; i < entries.length; i++) {
      final delta = (entries[i].meanY - entries[i - 1].meanY).abs();
      if (delta <= verticalThresholdIn) {
        curLength++;
        if (curLength > bestLength) {
          bestLength = curLength;
          bestStart = curStart;
        }
      } else {
        curStart = i;
        curLength = 1;
      }
    }
    if (bestStart < 0 || bestLength < 2) {
      return OcwAnalysis(
        chargesAnalyzed: byCharge.length,
        flatChargeIndices: const <double>[],
        maxVerticalSpreadIn: verticalThresholdIn,
        recommendedChargeGr: null,
      );
    }
    final flat = <double>[
      for (var i = bestStart; i < bestStart + bestLength; i++) entries[i].charge,
    ];
    final centre = entries[bestStart + (bestLength ~/ 2)].charge;
    return OcwAnalysis(
      chargesAnalyzed: byCharge.length,
      flatChargeIndices: flat,
      maxVerticalSpreadIn: verticalThresholdIn,
      recommendedChargeGr: centre,
    );
  }

  // ─────────────────────── Satterlee plateau ───────────────────────

  /// Satterlee 10-shot plateau detector.
  ///
  /// Algorithm:
  ///   1. Group [shots] by `chargeGr`. Compute mean velocity per
  ///      charge from rows where `velocityFps != null`.
  ///   2. Sort by charge ascending.
  ///   3. Walk consecutive pairs; "still flat" means
  ///      `meanV[i] - meanV[i-1] <= maxRiseFps` (we only count
  ///      flat-or-down steps as plateau, since Satterlee is looking
  ///      for the place where the velocity stops increasing despite
  ///      more powder).
  ///   4. Return the longest plateau and pick its centre as the
  ///      recommended charge.
  ///
  /// Default `maxRiseFps` is 12 fps per step — typical "the velocity
  /// barely moved" threshold for a rifle cartridge stepping by ≤0.2 gr.
  /// Caller can override.
  ///
  /// Reference: Satterlee, Scott. "10-Round Load Development Test."
  /// Spec'd in informal coaching writeups; applied widely in PRS /
  /// long-range shooting. The protocol is "shoot 10 rounds stepping
  /// the charge by 0.1–0.2 gr through the safe range, plot velocity,
  /// pick the centre of the flattest stretch."
  static SatterleeAnalysis analyzeSatterleePlateau(
    List<LoadDevelopmentShotRow> shots, {
    double maxRiseFps = 12.0,
  }) {
    final byCharge = <double, List<double>>{};
    for (final s in shots) {
      if (s.velocityFps == null) continue;
      final key = _round4(s.chargeGr);
      byCharge.putIfAbsent(key, () => <double>[]).add(s.velocityFps!);
    }
    if (byCharge.length < 3) {
      return SatterleeAnalysis(
        chargesAnalyzed: byCharge.length,
        plateauChargeIndices: const <double>[],
        maxVelocityRiseFps: maxRiseFps,
        recommendedChargeGr: null,
      );
    }
    final entries = byCharge.entries
        .map((e) => (
              charge: e.key,
              meanV: e.value.reduce((a, b) => a + b) / e.value.length,
            ))
        .toList()
      ..sort((a, b) => a.charge.compareTo(b.charge));

    var bestStart = -1;
    var bestLength = 1;
    var curStart = 0;
    var curLength = 1;
    for (var i = 1; i < entries.length; i++) {
      final rise = entries[i].meanV - entries[i - 1].meanV;
      if (rise <= maxRiseFps) {
        curLength++;
        if (curLength > bestLength) {
          bestLength = curLength;
          bestStart = curStart;
        }
      } else {
        curStart = i;
        curLength = 1;
      }
    }
    if (bestStart < 0 || bestLength < 2) {
      return SatterleeAnalysis(
        chargesAnalyzed: byCharge.length,
        plateauChargeIndices: const <double>[],
        maxVelocityRiseFps: maxRiseFps,
        recommendedChargeGr: null,
      );
    }
    final plateau = <double>[
      for (var i = bestStart; i < bestStart + bestLength; i++) entries[i].charge,
    ];
    final centre = entries[bestStart + (bestLength ~/ 2)].charge;
    return SatterleeAnalysis(
      chargesAnalyzed: byCharge.length,
      plateauChargeIndices: plateau,
      maxVelocityRiseFps: maxRiseFps,
      recommendedChargeGr: centre,
    );
  }

  // ─────────────────────── Audette Ladder helper ───────────────────────

  /// Audette Ladder vertical dispersion: returns the spread of mean Y
  /// impacts (max - min) across all charges that have at least one
  /// impact. Used by the Ladder detail screen to surface "your shots
  /// stacked within X inches at the centre of the curve" — the
  /// classic Audette read.
  ///
  /// When fewer than 2 charges have impact data, returns 0.
  ///
  /// Reference: Audette, Creighton. Original method published in
  /// Precision Shooting magazine in the late 1970s. Single shot per
  /// charge across a ladder, looking for vertical "stacking" at the
  /// node.
  static double computeLadderVerticalSpreadIn(
    List<LoadDevelopmentShotRow> shots,
  ) {
    final byCharge = <double, List<double>>{};
    for (final s in shots) {
      if (s.impactYIn == null) continue;
      byCharge
          .putIfAbsent(_round4(s.chargeGr), () => <double>[])
          .add(s.impactYIn!);
    }
    if (byCharge.length < 2) return 0.0;
    final means = byCharge.values
        .map((v) => v.reduce((a, b) => a + b) / v.length)
        .toList()
      ..sort();
    return means.last - means.first;
  }

  // ─────────────────────── Cross-charge stats ───────────────────────

  /// Compute SD / ES / mean velocity, group size, and POI per charge
  /// weight. Returns one [PerChargeStats] per distinct `chargeGr`,
  /// sorted by charge ascending.
  ///
  /// Stats:
  ///   * meanVelocity = sample mean of `velocityFps` over the bucket.
  ///   * sdVelocity   = sample standard deviation (Bessel-corrected,
  ///                    n-1 denominator). Null when fewer than 2
  ///                    chrono readings.
  ///   * esVelocity   = max - min of `velocityFps` over the bucket.
  ///   * meanX / meanY = mean impact coordinates over rows where
  ///                    impact data exists.
  ///   * extremeSpread = the largest center-to-center distance between
  ///                    any two impacts in the bucket. Null when
  ///                    fewer than 2 impact rows.
  ///   * meanRadius    = average distance from each impact to the
  ///                    bucket's centroid (mean X, mean Y).
  static List<PerChargeStats> computePerChargeStats(
    List<LoadDevelopmentShotRow> shots,
  ) {
    final byCharge = <double, List<LoadDevelopmentShotRow>>{};
    for (final s in shots) {
      byCharge.putIfAbsent(_round4(s.chargeGr), () => []).add(s);
    }
    final out = <PerChargeStats>[];
    final keys = byCharge.keys.toList()..sort();
    for (final c in keys) {
      final bucket = byCharge[c]!;
      final velocities = bucket
          .where((s) => s.velocityFps != null)
          .map((s) => s.velocityFps!)
          .toList();
      double? meanV;
      double? sdV;
      double? esV;
      if (velocities.isNotEmpty) {
        meanV = velocities.reduce((a, b) => a + b) / velocities.length;
        esV = velocities.reduce(math.max) - velocities.reduce(math.min);
        if (velocities.length >= 2) {
          var sumSq = 0.0;
          for (final v in velocities) {
            final d = v - meanV;
            sumSq += d * d;
          }
          sdV = math.sqrt(sumSq / (velocities.length - 1));
        }
      }

      final impacts = bucket
          .where((s) => s.impactXIn != null && s.impactYIn != null)
          .toList();
      double? meanX;
      double? meanY;
      double? es;
      double? meanRadius;
      if (impacts.isNotEmpty) {
        meanX = impacts.map((s) => s.impactXIn!).reduce((a, b) => a + b) /
            impacts.length;
        meanY = impacts.map((s) => s.impactYIn!).reduce((a, b) => a + b) /
            impacts.length;
        if (impacts.length >= 2) {
          es = computeExtremeSpreadIn(impacts);
        }
        meanRadius = _meanRadius(impacts, centerX: meanX, centerY: meanY);
      }

      out.add(PerChargeStats(
        chargeGr: c,
        shotCount: bucket.length,
        meanVelocityFps: meanV,
        sdVelocityFps: sdV,
        esVelocityFps: esV,
        meanXIn: meanX,
        meanYIn: meanY,
        extremeSpreadIn: es,
        meanRadiusIn: meanRadius,
      ));
    }
    return out;
  }

  /// Group extreme spread = the largest center-to-center distance
  /// between any two impacts. Standard accuracy metric in precision
  /// rifle: the diameter of the smallest circle that contains every
  /// shot. Returns 0 for empty / single-shot groups.
  static double computeExtremeSpreadIn(
    List<LoadDevelopmentShotRow> shots,
  ) {
    final impacts = shots
        .where((s) => s.impactXIn != null && s.impactYIn != null)
        .toList();
    if (impacts.length < 2) return 0.0;
    var maxD = 0.0;
    for (var i = 0; i < impacts.length; i++) {
      for (var j = i + 1; j < impacts.length; j++) {
        final dx = impacts[i].impactXIn! - impacts[j].impactXIn!;
        final dy = impacts[i].impactYIn! - impacts[j].impactYIn!;
        final d = math.sqrt(dx * dx + dy * dy);
        if (d > maxD) maxD = d;
      }
    }
    return maxD;
  }

  /// Group mean radius = average distance from each impact to the
  /// group centroid. Less sensitive to outliers than extreme spread —
  /// PRS shooters quote MR alongside ES because it summarises the
  /// "average shot" cleanly.
  static double computeMeanRadiusIn(
    List<LoadDevelopmentShotRow> shots,
  ) {
    final impacts = shots
        .where((s) => s.impactXIn != null && s.impactYIn != null)
        .toList();
    if (impacts.isEmpty) return 0.0;
    final cx =
        impacts.map((s) => s.impactXIn!).reduce((a, b) => a + b) / impacts.length;
    final cy =
        impacts.map((s) => s.impactYIn!).reduce((a, b) => a + b) / impacts.length;
    return _meanRadius(impacts, centerX: cx, centerY: cy);
  }

  static double _meanRadius(
    List<LoadDevelopmentShotRow> impacts, {
    required double centerX,
    required double centerY,
  }) {
    if (impacts.isEmpty) return 0.0;
    var sum = 0.0;
    for (final s in impacts) {
      final dx = s.impactXIn! - centerX;
      final dy = s.impactYIn! - centerY;
      sum += math.sqrt(dx * dx + dy * dy);
    }
    return sum / impacts.length;
  }

  // ─────────────────────── Recipe writeback ───────────────────────

  /// When a seating-ladder picks a winner, push the chosen CBTO back to
  /// the source recipe. Updates both `cbtoIn` (the CBTO measurement)
  /// and `seatingDepthIn` if a `bulletLengthIn` is known on the
  /// recipe; otherwise just `cbtoIn`.
  Future<bool> applySeatingNodeToRecipe({
    required int recipeId,
    required double cbtoIn,
  }) async {
    final row = await (db.select(db.userLoads)
          ..where((l) => l.id.equals(recipeId)))
        .getSingleOrNull();
    if (row == null) return false;

    // If the recipe has a known case length we could derive the
    // seating depth from CBTO + bullet-base-to-ogive, but that math is
    // too brittle to do silently — leave it to the user. We only
    // touch `seatingDepthIn` when we can derive a sensible delta.
    return await (db.update(db.userLoads)..where((l) => l.id.equals(recipeId)))
        .write(UserLoadsCompanion(
          cbtoIn: Value(_round4(cbtoIn)),
          updatedAt: Value(DateTime.now()),
        ))
        .then((rows) => rows > 0);
  }

  /// When an OCW / Satterlee / Generic charge analysis picks a winner,
  /// push the chosen powder charge back to the source recipe. Only
  /// touches `powderChargeGr`; everything else on the recipe is left
  /// alone so the user can review the change in their loads list.
  Future<bool> applyChargeNodeToRecipe({
    required int recipeId,
    required double chargeGr,
  }) async {
    final row = await (db.select(db.userLoads)
          ..where((l) => l.id.equals(recipeId)))
        .getSingleOrNull();
    if (row == null) return false;
    return await (db.update(db.userLoads)..where((l) => l.id.equals(recipeId)))
        .write(UserLoadsCompanion(
          powderChargeGr: Value(_round4(chargeGr)),
          updatedAt: Value(DateTime.now()),
        ))
        .then((rows) => rows > 0);
  }

  static double _round4(double v) => (v * 10000).roundToDouble() / 10000;

  /// Stable rounding helper used in tests and the UI for value labels.
  /// Exposed so the form can match the same precision that the
  /// repository persists.
  static double round(double v, {int places = 4}) {
    final f = math.pow(10.0, places).toDouble();
    return (v * f).roundToDouble() / f;
  }
}
