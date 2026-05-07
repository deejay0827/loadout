// FILE: lib/services/ballistics/units.dart
//
// ============================================================================
// WHAT THIS FILE DOES
// ============================================================================
// This file is a flat collection of pure-functional unit conversion helpers.
// Nothing in here has state, allocates objects, or talks to anything else in
// the app. Every function is one line: take a number in unit A, multiply by
// a constant, return a number in unit B.
//
// The reason this file exists at all is that the LoadOut UI lets the user
// type in American sporting units (inches, feet, yards, feet-per-second,
// grains, degrees Fahrenheit, inches of mercury) but the ballistic solver
// is implemented in SI (metres, seconds, kilograms, Pascals, Kelvins) so it
// can use textbook physics formulas without scattering conversion factors
// through the integration loop. Doing the conversions in one well-documented
// place makes the solver code easier to read and the conversions easier to
// audit.
//
// Naming convention is `xToY(value)` — converts `value` from unit `x` into
// unit `y`. So `feetToMeters(100.0)` returns `30.48`. Functions are grouped
// by physical quantity:
//
//   * Length:       inchesToMeters / metersToInches / feetToMeters /
//                   metersToFeet / yardsToMeters / metersToYards /
//                   mmToInches / inchesToMm
//   * Mass:         grainsToKg / kgToGrains / poundsToKg
//   * Speed:        fpsToMps / mpsToFps / mphToMps / mpsToMph
//   * Temperature:  fToC / cToF / fToK / cToK
//   * Pressure:     inHgToPa / paToInHg
//   * Energy:       joulesToFootPounds / footPoundsToJoules
//   * Angles:       degreesToRadians / radiansToDegrees / moaToRadians /
//                   radiansToMoa / milToRadians / radiansToMil
//   * Range angles: inchesToMoaAtYards / inchesToMilAtYards
//   * BC families:  bcG1ToG7 / bcG7ToG1
//
// All functions take and return `double` (Dart's 64-bit IEEE 754 float).
//
// ============================================================================
// THE PHYSICS / MATH
// ============================================================================
// The conversions are mostly NIST-standard exact factors:
//
//   * 1 inch    = 25.4 mm exactly (since 1959 international yard).
//   * 1 foot    = 0.3048 m exactly.
//   * 1 yard    = 0.9144 m exactly (3 feet).
//   * 1 grain   = 1/7000 lb = 64.79891 mg = 6.479891 × 10⁻⁵ kg.
//   * 1 lb      = 0.45359237 kg exactly (international avoirdupois).
//   * 1 fps     = 0.3048 m/s.
//   * 1 mph     = 0.44704 m/s.
//   * 1 inHg    = 3386.389 Pa (NIST).
//   * °F → K:   subtract 32, multiply by 5/9, add 273.15.
//   * 1 J       = 0.7375621493 ft-lb.
//
// Angular units in shooting are subtle:
//
//   * MOA (minute of angle) is 1/60 of a degree of arc. At a downrange
//     distance R, an angle θ subtends a target-plane offset of approximately
//     R · tan(θ). For small angles, MOA ≈ inches/(1.047 × distance/100yd):
//     i.e. one MOA spreads to 1.047 inches at 100 yards. Many shooters round
//     this to "1 MOA = 1 inch at 100 yd" which is a 4.7% error.
//
//   * Mil (milliradian) is 1/1000 of a radian. At 100 yards, 1 mil subtends
//     3.6 inches; at 1000 yards, 36 inches. Used by mil-dot scopes.
//
//   * Both MOA and mil are angular units, so the linear offset they
//     correspond to scales linearly with range. The two helpers
//     `inchesToMoaAtYards` / `inchesToMilAtYards` invert this — given a drop
//     of N inches at R yards, return the angular correction the shooter
//     would dial onto the scope. They use `atan(opposite/adjacent)` rather
//     than the small-angle approximation, but the small-angle form
//     `MOA ≈ inches / (1.047 × yards/100)` is accurate to better than 0.5%
//     out to 1500 yards, which is well past supersonic range for any
//     reasonable rifle cartridge.
//
// ----------------------------------------------------------------------------
// BC FAMILY CONVERSIONS (the awkward ones)
// ----------------------------------------------------------------------------
// `bcG1ToG7` / `bcG7ToG1` are APPROXIMATE — there is no exact algebraic
// relationship between a bullet's ballistic coefficient referenced to one
// drag family and the same bullet's BC referenced to a different family.
//
// Why: a "ballistic coefficient" is a single number that scales a STANDARD
// drag curve (G1, G7, etc.) to match the actual bullet's drag. Different
// standards have different curve shapes. G1 (Ingalls flat-base) has a
// pronounced transonic peak; G7 (10° boat-tail VLD) has a much flatter
// curve. A real boat-tail bullet matches the G7 curve well at one BC value
// and the G1 curve well at a different BC value, but the two values
// describe the SAME bullet. The ratio between them depends on bullet shape
// and varies with velocity.
//
// Bryan Litz's published rule of thumb (Applied Ballistics for Long-Range
// Shooting, 2nd ed.) is roughly BC_G7 ≈ BC_G1 × 0.512, valid for typical
// long-range boat-tail VLDs at supersonic velocities. We use this constant
// only as a fallback when the user supplied one BC family but the solver
// wants the other. Whenever possible, the user should enter the BC value
// for the family their bullet manufacturer publishes, and the solver should
// use that family directly.
//
// ============================================================================
// WHY IT EXISTS IN THE ARCHITECTURE
// ============================================================================
// Lowest layer of the ballistics package. Every other ballistics file
// (`atmosphere.dart`, `projectile.dart`, `environment.dart`, `solver.dart`)
// imports this one. Nothing in here imports anything else from the project,
// so there are no cycles and the dependency direction is unambiguous.
//
// Keeping the conversions in a separate file means:
//   1. The solver code stays readable: `final v0 = fpsToMps(mvFps)` is
//      self-documenting where `final v0 = mvFps * 0.3048` would not be.
//   2. The conversion constants are audited in one place rather than
//      scattered through 600 lines of integration code.
//   3. UI code can convert in either direction without depending on the
//      solver.
//
// ============================================================================
// WHY THIS IS HARDER THAN IT LOOKS
// ============================================================================
//   * Pressure inputs: shooters and weather apps usually report SEA-LEVEL
//     CORRECTED barometric pressure (this is what TV weather forecasts give).
//     The solver wants STATION pressure (the actual reading at the firing
//     position). `inHgToPa` is correct, but the caller must give it the
//     right kind of pressure — see the long warning in `atmosphere.dart`.
//
//   * Temperature: K = (°F − 32) × 5/9 + 273.15. Any of the three steps
//     done in the wrong order yields a near-correct number that is hard to
//     debug. We chain `fToC` then add 273.15 inside `fToK`.
//
//   * MOA at very steep angles: at small angles `tan(θ) ≈ θ` so the
//     small-angle and exact `atan` answers agree. At 45° they don't. Pure
//     vertical shots near zero range are degenerate (the helper returns 0
//     when yards <= 0 to avoid a divide-by-zero).
//
//   * Sign conventions: every conversion in this file is symmetric and
//     monotonic, so signs aren't an issue here. The rest of the solver is
//     not as forgiving.
//
//   * BC family conversion: see the long note above. NEVER round-trip a
//     BC value through `bcG1ToG7` then `bcG7ToG1` and expect the original
//     number back exactly — you'll get the original back because we just
//     multiply and divide by the same constant, but the underlying
//     approximation means neither value perfectly describes the bullet.
//
// ============================================================================
// WHO CONSUMES THIS FILE
// ============================================================================
//   - lib/services/ballistics/atmosphere.dart  (fToK, inHgToPa, feetToMeters,
//                                                metersToFeet)
//   - lib/services/ballistics/projectile.dart  (inchesToMeters, grainsToKg)
//   - lib/services/ballistics/environment.dart (mphToMps, degreesToRadians)
//   - lib/services/ballistics/solver.dart      (fpsToMps, mpsToFps,
//                                                yardsToMeters, metersToInches,
//                                                inchesToMeters,
//                                                joulesToFootPounds)
//   - any future UI screen that displays trajectories.
//
// ============================================================================
// SIDE EFFECTS
// ============================================================================
// None. Every function in this file is pure: same input always yields the
// same output, no I/O, no globals, no allocations beyond the returned
// double.
// ============================================================================

/// Unit conversion helpers for the ballistics module.
///
/// All math inside the solver runs in **SI** (meters, seconds, kilograms,
/// Pascals, Kelvins). The UI takes American sporting units (inches, feet,
/// yards, fps, grains, °F, inHg) and the conversions live here so the solver
/// stays pure.
///
/// Naming convention: `xToY(...)` converts the given quantity from `x`
/// units into `y` units. e.g. `feetToMeters(100)` → `30.48`.
library;

import 'dart:math' as math;

// ─────────────────────── Length ───────────────────────

double inchesToMeters(double inches) => inches * 0.0254;
double metersToInches(double meters) => meters / 0.0254;

double feetToMeters(double feet) => feet * 0.3048;
double metersToFeet(double meters) => meters / 0.3048;

double yardsToMeters(double yards) => yards * 0.9144;
double metersToYards(double meters) => meters / 0.9144;

double mmToInches(double mm) => mm / 25.4;
double inchesToMm(double inches) => inches * 25.4;

// ─────────────────────── Mass ───────────────────────

/// 1 grain = 1/7000 lb = 64.79891 mg = 6.479891e-5 kg
double grainsToKg(double grains) => grains * 6.479891e-5;
double kgToGrains(double kg) => kg / 6.479891e-5;

double poundsToKg(double lb) => lb * 0.45359237;

// ─────────────────────── Speed ───────────────────────

double fpsToMps(double fps) => fps * 0.3048;
double mpsToFps(double mps) => mps / 0.3048;

double mphToMps(double mph) => mph * 0.44704;
double mpsToMph(double mps) => mps / 0.44704;

// ─────────────────────── Temperature ───────────────────────

double fToC(double f) => (f - 32.0) * 5.0 / 9.0;
double cToF(double c) => c * 9.0 / 5.0 + 32.0;
double fToK(double f) => fToC(f) + 273.15;
double cToK(double c) => c + 273.15;

// ─────────────────────── Pressure ───────────────────────

/// 1 inHg = 3386.389 Pa (NIST). Used for barometric pressure inputs.
double inHgToPa(double inHg) => inHg * 3386.389;
double paToInHg(double pa) => pa / 3386.389;

// ─────────────────────── Energy ───────────────────────

double joulesToFootPounds(double j) => j * 0.7375621493;
double footPoundsToJoules(double ftLb) => ftLb / 0.7375621493;

// ─────────────────────── Angles ───────────────────────

double degreesToRadians(double deg) => deg * math.pi / 180.0;
double radiansToDegrees(double rad) => rad * 180.0 / math.pi;

/// 1 MOA = 1/60 degree. At 100 yd one MOA subtends ~1.047 inches.
double moaToRadians(double moa) => moa * math.pi / (180.0 * 60.0);
double radiansToMoa(double rad) => rad * 180.0 * 60.0 / math.pi;

/// 1 milliradian = 1/1000 radian. At 100 yd one mil subtends 3.6 inches.
double milToRadians(double mil) => mil * 1.0e-3;
double radiansToMil(double rad) => rad * 1000.0;

/// Drop in **inches** to angular MOA at the given **range in yards**.
/// Uses tan(angle)=opposite/adjacent. At small angles the small-angle
/// approximation `MOA ≈ inches / (1.047 × distance/100)` is accurate to
/// better than 0.5% out to 1500 yards.
double inchesToMoaAtYards(double inches, double yards) {
  if (yards <= 0) return 0;
  final rangeInches = yards * 36.0;
  return radiansToMoa(math.atan(inches / rangeInches));
}

double inchesToMilAtYards(double inches, double yards) {
  if (yards <= 0) return 0;
  final rangeInches = yards * 36.0;
  return radiansToMil(math.atan(inches / rangeInches));
}

// ─────────────────────── BC family conversions ───────────────────────

/// Approximate G1 ↔ G7 conversion. There is **no exact algebraic
/// relationship** between BCs in different drag families because the drag
/// curves have different shapes. The rule of thumb published by Bryan Litz
/// ("Applied Ballistics for Long-Range Shooting") is roughly
/// `BC_G7 ≈ BC_G1 × 0.512` for typical long-range bullets at supersonic
/// velocities. Useful only as a fallback when the user supplies one but
/// the solver wants the other.
double bcG1ToG7(double bcG1) => bcG1 * 0.512;
double bcG7ToG1(double bcG7) => bcG7 / 0.512;
