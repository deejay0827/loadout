// FILE: test/load_development_methods_test.dart
//
// ============================================================================
// WHAT THIS FILE DOES
// ============================================================================
// Unit tests for the v31 method-aware load-development analysis layer.
// Covers the four named-method analyzers (OCW node, Satterlee
// plateau, Audette ladder dispersion, per-charge statistical roll-up),
// the group-size primitives (extreme spread, mean radius), schema
// round-trip via an in-memory drift database, and the standard set
// of edge cases (empty test, single-shot test, all-shots-same-charge,
// out-of-order data).
//
// ============================================================================
// WHY IT EXISTS IN THE ARCHITECTURE
// ============================================================================
// Algorithms in `LoadDevelopmentRepository` are pure static functions
// over `List<LoadDevelopmentShotRow>` — no database access required —
// so they're ideal for unit testing without needing a Flutter test
// harness. Schema round-trip tests use `NativeDatabase.memory()` so
// no actual SQLite file is touched.
//
// ============================================================================
// WHO RUNS THIS FILE
// ============================================================================
// `flutter test test/load_development_methods_test.dart` — runs in CI
// via the standard package's `flutter test` target.

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:loadout/database/database.dart';
import 'package:loadout/repositories/load_development_repository.dart';

/// Convenience constructor for synthetic shot rows — full positional
/// arguments would be 9 mandatory fields.
LoadDevelopmentShotRow shot({
  int id = 0,
  int sessionId = 1,
  required double chargeGr,
  required int shotIndex,
  double? velocityFps,
  double? impactXIn,
  double? impactYIn,
  String? notes,
}) {
  return LoadDevelopmentShotRow(
    id: id,
    sessionId: sessionId,
    chargeGr: chargeGr,
    shotIndex: shotIndex,
    velocityFps: velocityFps,
    impactXIn: impactXIn,
    impactYIn: impactYIn,
    notes: notes,
    createdAt: DateTime(2026, 5, 9),
  );
}

void main() {
  group('OCW node detection', () {
    test('finds the flat spot in a synthetic vertical-impact curve', () {
      // Charges 40.0–41.5 in 0.3 steps. Vertical impacts walk down,
      // then plateau at 41.0–41.6 (flat spot), then walk up again.
      final shots = <LoadDevelopmentShotRow>[
        shot(chargeGr: 40.0, shotIndex: 1, impactYIn: -3.0),
        shot(chargeGr: 40.3, shotIndex: 1, impactYIn: -2.0),
        shot(chargeGr: 40.6, shotIndex: 1, impactYIn: -1.0),
        shot(chargeGr: 40.9, shotIndex: 1, impactYIn: 0.0),
        // Flat spot: three consecutive charges within ±0.2 in.
        shot(chargeGr: 41.2, shotIndex: 1, impactYIn: 0.4),
        shot(chargeGr: 41.5, shotIndex: 1, impactYIn: 0.3),
        shot(chargeGr: 41.8, shotIndex: 1, impactYIn: 0.5),
        // Then climbs.
        shot(chargeGr: 42.1, shotIndex: 1, impactYIn: 1.5),
        shot(chargeGr: 42.4, shotIndex: 1, impactYIn: 3.0),
      ];
      final result = LoadDevelopmentRepository.analyzeOcwNode(shots);
      expect(result.chargesAnalyzed, 9);
      expect(result.flatChargeIndices, isNotEmpty);
      // The longest flat spot is the 41.2 / 41.5 / 41.8 cluster — the
      // detector should pick its centre.
      expect(result.flatChargeIndices, containsAll([41.2, 41.5, 41.8]));
      expect(result.recommendedChargeGr, 41.5);
    });

    test('averages multi-shot impacts per charge before detecting flat spot',
        () {
      // Three shots per charge — the per-charge mean Y should drive
      // the analysis (Newberry's protocol).
      final shots = <LoadDevelopmentShotRow>[
        shot(chargeGr: 40.0, shotIndex: 1, impactYIn: -2.0),
        shot(chargeGr: 40.0, shotIndex: 2, impactYIn: -1.5),
        shot(chargeGr: 40.0, shotIndex: 3, impactYIn: -2.5),
        shot(chargeGr: 40.5, shotIndex: 1, impactYIn: 0.0),
        shot(chargeGr: 40.5, shotIndex: 2, impactYIn: 0.5),
        shot(chargeGr: 40.5, shotIndex: 3, impactYIn: -0.5),
        shot(chargeGr: 41.0, shotIndex: 1, impactYIn: 0.2),
        shot(chargeGr: 41.0, shotIndex: 2, impactYIn: 0.0),
        shot(chargeGr: 41.0, shotIndex: 3, impactYIn: 0.4),
        shot(chargeGr: 41.5, shotIndex: 1, impactYIn: 1.5),
        shot(chargeGr: 41.5, shotIndex: 2, impactYIn: 2.0),
        shot(chargeGr: 41.5, shotIndex: 3, impactYIn: 1.8),
      ];
      // Per-charge means: -2.0, 0.0, 0.2, 1.77.
      // With default threshold 0.5: 40.5→41.0 delta is 0.2 (flat),
      // 41.0→41.5 delta is 1.57 (not flat).
      final result = LoadDevelopmentRepository.analyzeOcwNode(shots);
      expect(result.chargesAnalyzed, 4);
      expect(result.flatChargeIndices, [40.5, 41.0]);
      expect(result.recommendedChargeGr, 41.0);
    });

    test('returns null when no flat spot exists', () {
      // Monotonic climbing curve with no plateau under threshold.
      final shots = <LoadDevelopmentShotRow>[
        for (var i = 0; i < 6; i++)
          shot(
            chargeGr: 40.0 + i * 0.3,
            shotIndex: 1,
            impactYIn: -3.0 + i * 1.5, // 1.5"-per-step climb
          ),
      ];
      final result = LoadDevelopmentRepository.analyzeOcwNode(shots);
      expect(result.recommendedChargeGr, isNull);
      expect(result.flatChargeIndices, isEmpty);
    });

    test('respects custom verticalThresholdIn override', () {
      // A 0.4 in step. With default threshold 0.5 it counts as flat;
      // with a tighter 0.3 threshold it does not.
      final shots = <LoadDevelopmentShotRow>[
        shot(chargeGr: 40.0, shotIndex: 1, impactYIn: -2.0),
        shot(chargeGr: 40.3, shotIndex: 1, impactYIn: -1.6),
        shot(chargeGr: 40.6, shotIndex: 1, impactYIn: -1.2),
        shot(chargeGr: 40.9, shotIndex: 1, impactYIn: 0.0),
      ];
      final loose = LoadDevelopmentRepository.analyzeOcwNode(
        shots,
        verticalThresholdIn: 0.5,
      );
      expect(loose.flatChargeIndices, isNotEmpty);
      final tight = LoadDevelopmentRepository.analyzeOcwNode(
        shots,
        verticalThresholdIn: 0.3,
      );
      expect(tight.flatChargeIndices, isEmpty);
    });
  });

  group('Satterlee plateau detection', () {
    test('finds the longest plateau in a synthetic MV ramp', () {
      // Velocities ramp up, then plateau (38.0–38.4 share ~2700 fps),
      // then ramp again.
      final shots = <LoadDevelopmentShotRow>[
        shot(chargeGr: 37.0, shotIndex: 1, velocityFps: 2580),
        shot(chargeGr: 37.2, shotIndex: 1, velocityFps: 2620),
        shot(chargeGr: 37.4, shotIndex: 1, velocityFps: 2660),
        shot(chargeGr: 37.6, shotIndex: 1, velocityFps: 2680),
        // Plateau begins.
        shot(chargeGr: 37.8, shotIndex: 1, velocityFps: 2700),
        shot(chargeGr: 38.0, shotIndex: 1, velocityFps: 2705),
        shot(chargeGr: 38.2, shotIndex: 1, velocityFps: 2708),
        shot(chargeGr: 38.4, shotIndex: 1, velocityFps: 2710),
        // Then ramps again.
        shot(chargeGr: 38.6, shotIndex: 1, velocityFps: 2745),
        shot(chargeGr: 38.8, shotIndex: 1, velocityFps: 2790),
      ];
      final result = LoadDevelopmentRepository.analyzeSatterleePlateau(shots);
      expect(result.chargesAnalyzed, 10);
      expect(result.plateauChargeIndices, isNotEmpty);
      // Plateau covers 37.8 → 38.4 (rises 5/3/2 fps per step) — all
      // under default 12 fps threshold. The plateau before the first
      // 30-fps spike at 38.6.
      expect(result.plateauChargeIndices,
          containsAll([37.8, 38.0, 38.2, 38.4]));
      // Centre of 4-charge plateau at index 2 → 38.2.
      expect(result.recommendedChargeGr, 38.2);
    });

    test('returns null when velocity ramps too steeply', () {
      // Every step >> 12 fps — no plateau possible.
      final shots = <LoadDevelopmentShotRow>[
        shot(chargeGr: 37.0, shotIndex: 1, velocityFps: 2600),
        shot(chargeGr: 37.2, shotIndex: 1, velocityFps: 2650),
        shot(chargeGr: 37.4, shotIndex: 1, velocityFps: 2700),
        shot(chargeGr: 37.6, shotIndex: 1, velocityFps: 2750),
      ];
      final result = LoadDevelopmentRepository.analyzeSatterleePlateau(shots);
      expect(result.recommendedChargeGr, isNull);
    });

    test('respects custom maxRiseFps override', () {
      // 6 fps rise per step — under 12 fps default, over 5 fps tight
      // threshold.
      final shots = <LoadDevelopmentShotRow>[
        shot(chargeGr: 37.0, shotIndex: 1, velocityFps: 2700),
        shot(chargeGr: 37.2, shotIndex: 1, velocityFps: 2706),
        shot(chargeGr: 37.4, shotIndex: 1, velocityFps: 2712),
        shot(chargeGr: 37.6, shotIndex: 1, velocityFps: 2718),
      ];
      final loose = LoadDevelopmentRepository.analyzeSatterleePlateau(shots);
      expect(loose.plateauChargeIndices, isNotEmpty);
      final tight = LoadDevelopmentRepository.analyzeSatterleePlateau(
        shots,
        maxRiseFps: 5,
      );
      expect(tight.plateauChargeIndices, isEmpty);
    });
  });

  group('Group statistics', () {
    test('computes extreme spread on synthetic shot grid', () {
      // Three shots; max distance is between (-1, 0) and (1, 0) = 2.0.
      final shots = <LoadDevelopmentShotRow>[
        shot(chargeGr: 40, shotIndex: 1, impactXIn: -1.0, impactYIn: 0.0),
        shot(chargeGr: 40, shotIndex: 2, impactXIn: 0.0, impactYIn: 0.5),
        shot(chargeGr: 40, shotIndex: 3, impactXIn: 1.0, impactYIn: 0.0),
      ];
      expect(LoadDevelopmentRepository.computeExtremeSpreadIn(shots), 2.0);
    });

    test('mean radius is the average distance from centroid', () {
      // 4 shots forming a square at (±1, ±1). Centroid (0, 0).
      // Distance from each is sqrt(2) ≈ 1.41. Mean = sqrt(2).
      final shots = <LoadDevelopmentShotRow>[
        shot(chargeGr: 40, shotIndex: 1, impactXIn: 1.0, impactYIn: 1.0),
        shot(chargeGr: 40, shotIndex: 2, impactXIn: -1.0, impactYIn: 1.0),
        shot(chargeGr: 40, shotIndex: 3, impactXIn: -1.0, impactYIn: -1.0),
        shot(chargeGr: 40, shotIndex: 4, impactXIn: 1.0, impactYIn: -1.0),
      ];
      final mr = LoadDevelopmentRepository.computeMeanRadiusIn(shots);
      expect(mr, closeTo(1.41421, 1e-4));
    });

    test('extreme spread is 0 for an empty / single-shot group', () {
      expect(LoadDevelopmentRepository.computeExtremeSpreadIn([]), 0.0);
      expect(
        LoadDevelopmentRepository.computeExtremeSpreadIn([
          shot(chargeGr: 40, shotIndex: 1, impactXIn: 0.5, impactYIn: 0.5),
        ]),
        0.0,
      );
    });
  });

  group('Per-charge statistical roll-up', () {
    test('SD / ES / mean MV are computed per charge bucket', () {
      // Two charges. First has 3 shots (chrono), second has 2.
      final shots = <LoadDevelopmentShotRow>[
        shot(chargeGr: 40.0, shotIndex: 1, velocityFps: 2700),
        shot(chargeGr: 40.0, shotIndex: 2, velocityFps: 2710),
        shot(chargeGr: 40.0, shotIndex: 3, velocityFps: 2705),
        shot(chargeGr: 40.5, shotIndex: 1, velocityFps: 2740),
        shot(chargeGr: 40.5, shotIndex: 2, velocityFps: 2760),
      ];
      final stats = LoadDevelopmentRepository.computePerChargeStats(shots);
      expect(stats.length, 2);
      // Sorted ascending by charge.
      expect(stats[0].chargeGr, 40.0);
      expect(stats[0].shotCount, 3);
      // Mean of (2700, 2710, 2705) = 2705.
      expect(stats[0].meanVelocityFps, closeTo(2705, 0.01));
      // SD (Bessel n-1) = sqrt((25 + 25 + 0)/2) = 5.
      expect(stats[0].sdVelocityFps, closeTo(5.0, 0.01));
      // ES = max - min = 10.
      expect(stats[0].esVelocityFps, 10.0);

      expect(stats[1].chargeGr, 40.5);
      expect(stats[1].shotCount, 2);
      expect(stats[1].meanVelocityFps, 2750);
      // SD of two samples = sqrt(2 * 100^2 / 2) = wait, with n=2:
      // mean = 2750. Each shot 10 off mean. SD = sqrt(200/1) = sqrt(200).
      expect(stats[1].sdVelocityFps, closeTo(14.142, 0.01));
      expect(stats[1].esVelocityFps, 20);
    });

    test('null SD and group stats when only one shot', () {
      final shots = <LoadDevelopmentShotRow>[
        shot(chargeGr: 40.0, shotIndex: 1, velocityFps: 2700),
      ];
      final stats = LoadDevelopmentRepository.computePerChargeStats(shots);
      expect(stats.single.shotCount, 1);
      expect(stats.single.meanVelocityFps, 2700);
      expect(stats.single.sdVelocityFps, isNull);
      expect(stats.single.esVelocityFps, 0);
      expect(stats.single.extremeSpreadIn, isNull);
    });
  });

  group('Audette ladder vertical spread', () {
    test('spread = max mean Y minus min mean Y across all charges', () {
      final shots = <LoadDevelopmentShotRow>[
        shot(chargeGr: 40.0, shotIndex: 1, impactYIn: -2.0),
        shot(chargeGr: 40.5, shotIndex: 1, impactYIn: -0.5),
        shot(chargeGr: 41.0, shotIndex: 1, impactYIn: 0.0),
        shot(chargeGr: 41.5, shotIndex: 1, impactYIn: 1.5),
      ];
      final spread =
          LoadDevelopmentRepository.computeLadderVerticalSpreadIn(shots);
      expect(spread, closeTo(3.5, 1e-9));
    });

    test('spread is 0 when fewer than 2 charges have impact data', () {
      expect(LoadDevelopmentRepository.computeLadderVerticalSpreadIn([]), 0.0);
      expect(
        LoadDevelopmentRepository.computeLadderVerticalSpreadIn([
          shot(chargeGr: 40, shotIndex: 1, impactYIn: 0.5),
        ]),
        0.0,
      );
    });
  });

  group('Edge cases', () {
    test('all shots at the same charge — analyzers return null', () {
      // One charge bucket only — flat-spot detector / plateau detector
      // need at least 3 buckets to do anything useful.
      final shots = <LoadDevelopmentShotRow>[
        shot(chargeGr: 40.0, shotIndex: 1, impactYIn: 0.0, velocityFps: 2700),
        shot(chargeGr: 40.0, shotIndex: 2, impactYIn: 0.5, velocityFps: 2710),
        shot(chargeGr: 40.0, shotIndex: 3, impactYIn: 0.2, velocityFps: 2705),
      ];
      expect(
        LoadDevelopmentRepository.analyzeOcwNode(shots).recommendedChargeGr,
        isNull,
      );
      expect(
        LoadDevelopmentRepository.analyzeSatterleePlateau(shots)
            .recommendedChargeGr,
        isNull,
      );
    });

    test('OCW handles out-of-order shots correctly', () {
      // Shots arrive in arbitrary order; the analyzer must sort by
      // charge before walking consecutive pairs.
      final shots = <LoadDevelopmentShotRow>[
        shot(chargeGr: 41.2, shotIndex: 1, impactYIn: 0.4),
        shot(chargeGr: 40.9, shotIndex: 1, impactYIn: 0.0),
        shot(chargeGr: 41.5, shotIndex: 1, impactYIn: 0.3),
        shot(chargeGr: 40.6, shotIndex: 1, impactYIn: -1.0),
        shot(chargeGr: 41.8, shotIndex: 1, impactYIn: 0.5),
      ];
      final result = LoadDevelopmentRepository.analyzeOcwNode(shots);
      expect(result.flatChargeIndices, isNotEmpty);
      // The flat spot should still cover the same charges.
      expect(result.flatChargeIndices, containsAll([40.9, 41.2, 41.5, 41.8]));
    });

    test('analyzers tolerate completely empty input', () {
      final empty = <LoadDevelopmentShotRow>[];
      expect(
        LoadDevelopmentRepository.analyzeOcwNode(empty).recommendedChargeGr,
        isNull,
      );
      expect(
        LoadDevelopmentRepository.analyzeSatterleePlateau(empty)
            .recommendedChargeGr,
        isNull,
      );
      expect(LoadDevelopmentRepository.computeLadderVerticalSpreadIn(empty),
          0.0);
      expect(
        LoadDevelopmentRepository.computePerChargeStats(empty),
        isEmpty,
      );
    });
  });

  group('Schema round-trip via in-memory drift', () {
    late AppDatabase db;
    late LoadDevelopmentRepository repo;

    setUp(() {
      db = AppDatabase.forTesting(NativeDatabase.memory());
      repo = LoadDevelopmentRepository(db);
    });

    tearDown(() async {
      await db.close();
    });

    test('insert session + insert shots + query returns the same data',
        () async {
      // Insert a session.
      final sessionId = await repo.insert(
        LoadDevelopmentSessionsCompanion.insert(
          name: 'Test OCW',
          sessionType: 'charge_ladder',
          methodKind: const Value('ocw'),
          startValue: 40.0,
          endValue: 41.5,
          stepValue: 0.3,
          rungCount: 6,
          distanceYd: const Value(100),
          shotsPerCharge: const Value(3),
        ),
      );
      expect(sessionId, isPositive);

      // Insert 9 shots: 3 at each of 3 charges.
      for (final c in [40.0, 40.3, 40.6]) {
        for (var i = 1; i <= 3; i++) {
          await repo.insertShot(
            LoadDevelopmentShotsCompanion.insert(
              sessionId: sessionId,
              chargeGr: c,
              shotIndex: i,
              velocityFps: Value(2700.0 + (c - 40.0) * 30 + i * 1.5),
              impactYIn: Value((c - 40.0) - 1.0),
            ),
          );
        }
      }

      final shots = await repo.getShots(sessionId);
      expect(shots.length, 9);
      // Sorted by chargeGr then shotIndex (per repo contract).
      expect(shots.first.chargeGr, 40.0);
      expect(shots.first.shotIndex, 1);
      expect(shots.last.chargeGr, 40.6);
      expect(shots.last.shotIndex, 3);

      // Round-trip the analysis as a sanity check that the row data
      // matches what we inserted.
      final stats = LoadDevelopmentRepository.computePerChargeStats(shots);
      expect(stats.length, 3);
      expect(stats.first.shotCount, 3);
    });

    test('delete session cascades to shots', () async {
      final sessionId = await repo.insert(
        LoadDevelopmentSessionsCompanion.insert(
          name: 'Test',
          sessionType: 'charge_ladder',
          methodKind: const Value('generic'),
          startValue: 40.0,
          endValue: 41.0,
          stepValue: 0.3,
          rungCount: 4,
        ),
      );
      await repo.insertShot(
        LoadDevelopmentShotsCompanion.insert(
          sessionId: sessionId,
          chargeGr: 40.0,
          shotIndex: 1,
          velocityFps: const Value(2700),
        ),
      );
      expect((await repo.getShots(sessionId)).length, 1);

      await repo.delete(sessionId);
      // Shot rows should be gone too.
      expect((await repo.getShots(sessionId)).length, 0);
      expect(await repo.getById(sessionId), isNull);
    });

    test('updateShot writes only the patched columns', () async {
      final sessionId = await repo.insert(
        LoadDevelopmentSessionsCompanion.insert(
          name: 'Test',
          sessionType: 'charge_ladder',
          methodKind: const Value('generic'),
          startValue: 40.0,
          endValue: 41.0,
          stepValue: 0.3,
          rungCount: 4,
        ),
      );
      final shotId = await repo.insertShot(
        LoadDevelopmentShotsCompanion.insert(
          sessionId: sessionId,
          chargeGr: 40.0,
          shotIndex: 1,
          velocityFps: const Value(2700),
          impactXIn: const Value(0.5),
        ),
      );
      // Patch only impactYIn — the other fields must survive untouched.
      await repo.updateShot(
        shotId,
        const LoadDevelopmentShotsCompanion(
          impactYIn: Value(-0.25),
        ),
      );
      final shots = await repo.getShots(sessionId);
      expect(shots.single.velocityFps, 2700);
      expect(shots.single.impactXIn, 0.5);
      expect(shots.single.impactYIn, -0.25);
    });
  });
}
