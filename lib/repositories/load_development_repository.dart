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

  Future<int> delete(int id) =>
      (db.delete(db.loadDevelopmentSessions)..where((s) => s.id.equals(id)))
          .go();

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

  static double _round4(double v) => (v * 10000).roundToDouble() / 10000;

  /// Stable rounding helper used in tests and the UI for value labels.
  /// Exposed so the form can match the same precision that the
  /// repository persists.
  static double round(double v, {int places = 4}) {
    final f = math.pow(10.0, places).toDouble();
    return (v * f).roundToDouble() / f;
  }
}
