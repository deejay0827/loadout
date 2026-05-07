/// Bullet definition consumed by the ballistic solver.
library;

import 'dart:math' as math;

import 'drag_functions.dart';
import 'units.dart';

/// Physical and aerodynamic properties of the bullet leaving the muzzle.
class Projectile {
  Projectile({
    required this.diameterIn,
    required this.weightGr,
    required this.bc,
    required this.dragModel,
    this.lengthIn,
    this.twistInches,
  });

  /// Bullet diameter, inches.
  final double diameterIn;

  /// Bullet weight, grains.
  final double weightGr;

  /// Ballistic coefficient in the [dragModel] family.
  /// Typical values:
  ///   * G1: 0.3–0.7 for hunting bullets, up to ~0.8 for VLDs.
  ///   * G7: 0.15–0.4 — roughly half the G1 number for the same bullet.
  final double bc;

  /// Drag function family the [bc] is referenced against.
  final DragModel dragModel;

  /// Bullet length, inches. Optional — used only for the Miller spin
  /// stability formula. If null, the Miller calc is skipped (the user
  /// won't see a stability factor; spin drift falls back to the
  /// muzzle-twist-only Litz approximation).
  final double? lengthIn;

  /// Barrel twist rate in inches per turn (e.g. `8.0` for "1:8").
  /// Required for spin drift.
  final double? twistInches;

  // ─────────────────────── SI projections ───────────────────────

  double get diameterM => inchesToMeters(diameterIn);
  double get massKg => grainsToKg(weightGr);

  /// Sectional density (lb/in²). Standard form: SD = m_lb / D_in².
  double get sectionalDensity {
    final mLb = weightGr / 7000.0;
    return mLb / (diameterIn * diameterIn);
  }

  /// Form factor i = SD / BC. Useful in calculations and as a sanity
  /// check (typical i ≈ 1.0 for the matching drag family).
  double get formFactor => sectionalDensity / bc;

  /// Initial spin rate at the muzzle (rad/s) given [muzzleVelocityFps].
  /// Returns 0 if [twistInches] is null (we have no twist information).
  double initialSpinRadPerSec(double muzzleVelocityFps) {
    final t = twistInches;
    if (t == null || t <= 0) return 0;
    // 1 turn per `t` inches, bullet travels `v` fps → revolutions per
    // second = v(fps) × 12 / t. Multiply by 2π for rad/s.
    return muzzleVelocityFps * 12.0 / t * 2.0 * math.pi;
  }

  /// Miller stability factor (Sg). Returns null if [lengthIn] or
  /// [twistInches] is missing.
  ///
  /// Reference: Miller, "A New Rule for Estimating Rifling Twist",
  /// Precision Shooting Magazine, March 2005.
  double? millerStability(double muzzleVelocityFps) {
    final L = lengthIn;
    final T = twistInches;
    if (L == null || T == null || T <= 0) return null;
    final m = weightGr;
    final d = diameterIn;
    // Bullet length in calibers.
    final l = L / d;
    final sg = (30.0 * m) /
        (math.pow(T / d, 2) * math.pow(d, 3) * l * (1.0 + l * l));
    // Velocity correction (Miller): factor up by (V/2800)^(1/3).
    final velCorr = math.pow(muzzleVelocityFps / 2800.0, 1.0 / 3.0);
    return sg * velCorr;
  }
}
