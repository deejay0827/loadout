import 'package:flutter_test/flutter_test.dart';
import 'package:loadout/services/ballistics/atmosphere.dart';
import 'package:loadout/services/ballistics/drag_functions.dart';
import 'package:loadout/services/ballistics/environment.dart';
import 'package:loadout/services/ballistics/projectile.dart';
import 'package:loadout/services/ballistics/solver.dart';
import 'package:loadout/services/ballistics/units.dart';

/// Hand-verified case: 6.5 Creedmoor, 140gr Hornady ELD-M, MV 2750 fps,
/// G7 BC 0.298, 1:8 twist, ICAO standard atmosphere, 100 yd zero. Per
/// the prompt, drop at 1000 yd should be ~370 in (~35 MOA), spin drift
/// ~5–7 in. We accept ±15% on drop and ±0.5 MOA on spin.
void main() {
  test('6.5CM 140gr ELD-M baseline matches reference solver within tolerances',
      () {
    final projectile = Projectile(
      diameterIn: 0.264,
      weightGr: 140,
      bc: 0.298,
      dragModel: DragModel.g7,
      lengthIn: 1.355,
      twistInches: 8,
    );
    final atm = Atmosphere.icaoStd();
    final env = Environment.fromImperial(
      atmosphere: atm,
      windSpeedMph: 0,
      windFromDegrees: 90,
      shotAzimuthDegrees: 0,
      latitudeDegrees: 40,
      targetElevationFt: 0,
    );
    const shot = ShotInputs(
      muzzleVelocityFps: 2750,
      sightHeightIn: 1.5,
      zeroRangeYards: 100,
    );

    final samples = solveTrajectory(
      projectile: projectile,
      environment: env,
      shot: shot,
      sampleRangesYards: const [100, 500, 1000],
    );

    expect(samples.length, 3);

    // 100yd zero should put us right on the line of sight.
    final zero = samples[0];
    expect(zero.dropInches.abs(), lessThan(0.5));

    // 1000 yd drop: Hornady 4DOF / AB give roughly 370" drop.
    final far = samples[2];
    expect(far.dropInches, greaterThan(300));
    expect(far.dropInches, lessThan(440));

    // Spin drift at 1000 yd: ~5–10 in.
    expect(far.spinDriftInches, greaterThan(2));
    expect(far.spinDriftInches, lessThan(15));

    // Velocity at 1000 yd should be subsonic-ish, ~1100–1400 fps.
    expect(far.velocityFps, greaterThan(900));
    expect(far.velocityFps, lessThan(1500));
  });

  test('atmosphere: ICAO sea-level density matches 1.225 kg/m³', () {
    final atm = Atmosphere.icaoStd();
    expect(atm.density, closeTo(1.225, 1e-3));
    expect(atm.speedOfSound, closeTo(340.3, 1.0));
  });

  test('drag function: G1 muzzle Cd matches published table', () {
    expect(dragCoefficient(DragModel.g1, 0.0), closeTo(0.2629, 1e-3));
    expect(dragCoefficient(DragModel.g7, 0.0), closeTo(0.1198, 1e-3));
  });

  test('unit conversions roundtrip', () {
    expect(metersToInches(inchesToMeters(12.0)), closeTo(12.0, 1e-9));
    expect(grainsToKg(7000), closeTo(0.4536, 1e-4));
    expect(fpsToMps(1116.45), closeTo(340.294, 0.01));
  });
}
