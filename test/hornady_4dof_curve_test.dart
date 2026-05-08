// FILE: test/hornady_4dof_curve_test.dart
//
// Sanity test for the real Hornady 4DOF Cd-vs-Mach curves bundled in
// `assets/seed_data/drag_curves/curves.json`. Compares two solver runs
// for the canonical 6.5 Creedmoor / 140 gr ELD-Match load:
//
//   A) The standard G7 + BC path (BC = 0.298, the published Hornady
//      G7 for the 140 gr ELD-Match).
//   B) The same projectile but with the real 4DOF Cd table swapped in
//      via [Projectile.customDragCurve].
//
// The two trajectories must agree at 1000 yd within a few-tenths-of-a-mil
// envelope. A 4DOF curve and a G7 BC are expressing the same physical
// reality from different angles — the 4DOF curve is the Doppler-radar
// truth, the G7 BC is a single-number summary fit to the same bullet.
// They should never disagree by more than ~0.3 mil at 1000 yd. A bigger
// gap means either the scrape pulled the wrong row, the curve loaded
// the wrong fields, or the Projectile is bypassing `customDragCurve`.
//
// The test reads `assets/seed_data/drag_curves/curves.json` directly
// off disk (the asset bundle is unavailable in unit tests) and locates
// the Hornady ELD-Match 6.5 mm 140 gr entry by its `manufacturer`,
// `line`, `weight_gr`, and `diameter_in` columns — the same fields
// the seed loader uses to populate the `DragCurves` drift table.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:loadout/services/ballistics/atmosphere.dart';
import 'package:loadout/services/ballistics/custom_drag.dart';
import 'package:loadout/services/ballistics/drag_functions.dart';
import 'package:loadout/services/ballistics/environment.dart';
import 'package:loadout/services/ballistics/projectile.dart';
import 'package:loadout/services/ballistics/solver.dart';

void main() {
  group('Hornady 4DOF curve — 6.5 CM 140 ELD-Match sanity', () {
    test('real 4DOF curve matches G7+BC trajectory within 0.3 mil at 1000 yd',
        () {
      // Load curves.json from the source tree. The Flutter test runner's
      // working directory is the project root.
      final file = File('assets/seed_data/drag_curves/curves.json');
      expect(file.existsSync(), isTrue,
          reason: 'curves.json should be checked into the repo');
      final root = json.decode(file.readAsStringSync()) as Map<String, dynamic>;
      final list = (root['curves'] as List<dynamic>);
      expect(list, isNotEmpty,
          reason: 'curves.json should contain at least the priority bullets');

      // Find the Hornady 6.5mm 140gr ELD-Match curve. Loose match on
      // weight (±0.5 gr) and diameter (±0.0015 in) — same tolerances
      // the factory_load_repository uses.
      final entry = list.cast<Map<String, dynamic>>().firstWhere(
            (e) =>
                (e['manufacturer'] as String).toLowerCase() == 'hornady' &&
                (e['line'] as String).toLowerCase().contains('eld') &&
                (e['line'] as String).toLowerCase().contains('match') &&
                ((e['weight_gr'] as num).toDouble() - 140).abs() < 0.5 &&
                ((e['diameter_in'] as num).toDouble() - 0.264).abs() < 0.0015,
            orElse: () => <String, dynamic>{},
          );
      expect(entry, isNotEmpty,
          reason: 'curves.json must include 6.5mm 140 gr Hornady ELD-Match');

      // Build a CustomDragCurve from the JSON datapoints.
      final datapoints = (entry['datapoints'] as List<dynamic>)
          .cast<Map<String, dynamic>>();
      final points = datapoints
          .map((d) => MachCd(
                mach: (d['mach'] as num).toDouble(),
                cd: (d['cd'] as num).toDouble(),
              ))
          .toList(growable: false);
      expect(points.length, greaterThanOrEqualTo(15),
          reason: 'a real 4DOF table should have ~30 samples');
      final curve = CustomDragCurve.fromPoints(
        id: entry['id'] as String? ?? 'hornady_4dof_test',
        displayName: entry['line'] as String,
        family: CdmFamily.hornady4dof,
        bulletWeightGr: (entry['weight_gr'] as num).toDouble(),
        bulletDiameterIn: (entry['diameter_in'] as num).toDouble(),
        manufacturer: entry['manufacturer'] as String?,
        line: entry['line'] as String?,
        source: entry['source'] as String?,
        points: points,
      );

      // Two projectiles: same bullet, different drag input. The G7
      // path is the legacy one — `bc=0.298` is the Hornady-published
      // G7 BC for the 6.5mm 140 gr ELD-Match. The 4DOF path uses the
      // real Cd table; its BC field is ignored at solve time per the
      // Projectile contract.
      final g7 = Projectile(
        diameterIn: 0.264,
        weightGr: 140,
        bc: 0.298,
        dragModel: DragModel.g7,
        lengthIn: 1.355,
        twistInches: 8,
      );
      final fourDof = Projectile(
        diameterIn: 0.264,
        weightGr: 140,
        // `bc` and `dragModel` are no-ops here because customDragCurve
        // takes precedence, but we still pass placeholders so the
        // constructor's invariants hold.
        bc: 0.0,
        dragModel: DragModel.g7,
        lengthIn: 1.355,
        twistInches: 8,
        customDragCurve: curve,
      );

      // Sea level, ICAO standard atmosphere, 2710 fps, zeroed at 100
      // yd. Match the prompt's sanity-test fixture.
      final env = Environment.fromImperial(
        atmosphere: Atmosphere.icaoStd(),
        windSpeedMph: 0,
        windFromDegrees: 90,
        shotAzimuthDegrees: 0,
        latitudeDegrees: 40,
        targetElevationFt: 0,
      );
      const shot = ShotInputs(
        muzzleVelocityFps: 2710,
        sightHeightIn: 1.5,
        zeroRangeYards: 100,
      );

      final samplesG7 = solveTrajectory(
        projectile: g7,
        environment: env,
        shot: shot,
        sampleRangesYards: const [100, 1000],
      );
      final samples4Dof = solveTrajectory(
        projectile: fourDof,
        environment: env,
        shot: shot,
        sampleRangesYards: const [100, 1000],
      );

      expect(samplesG7.length, 2);
      expect(samples4Dof.length, 2);

      // Both should be near-zero at 100 yd (zero range).
      expect(samplesG7[0].dropInches.abs(), lessThan(1.0));
      expect(samples4Dof[0].dropInches.abs(), lessThan(1.0));

      // Convert drop inches → mil for comparison at 1000 yd.
      // 1 mil at 1000 yd ≈ 36 inches.
      final dropG7Mil = samplesG7[1].dropInches / 36.0;
      final drop4DofMil = samples4Dof[1].dropInches / 36.0;
      final deltaMil = (dropG7Mil - drop4DofMil).abs();

      // Print the diagnostic so a CI failure is easy to read.
      // Keeping this `print` (not `debugPrint`) so it shows up in
      // `flutter test` raw output.
      // ignore: avoid_print
      print('  G7+BC: ${samplesG7[1].dropInches.toStringAsFixed(2)} in '
          '(${dropG7Mil.toStringAsFixed(3)} mil)');
      // ignore: avoid_print
      print('  4DOF : ${samples4Dof[1].dropInches.toStringAsFixed(2)} in '
          '(${drop4DofMil.toStringAsFixed(3)} mil)');
      // ignore: avoid_print
      print('  Δ    : ${deltaMil.toStringAsFixed(3)} mil');

      expect(
        deltaMil,
        lessThan(0.3),
        reason:
            '4DOF curve and G7+BC must agree within 0.3 mil at 1000 yd; '
            'larger delta indicates wrong row, missing data, or the '
            'solver bypassing customDragCurve. (G7 drop = '
            '${samplesG7[1].dropInches.toStringAsFixed(1)} in, '
            '4DOF drop = ${samples4Dof[1].dropInches.toStringAsFixed(1)} in)',
      );
    });
  });
}
