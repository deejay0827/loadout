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
