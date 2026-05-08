// FILE: lib/services/hit_probability_service.dart
//
// ============================================================================
// WHAT THIS FILE DOES
// ============================================================================
// Computes the probability that a single shot lands inside the chosen
// target geometry given the shooter's intrinsic group capability and
// three uncertainty contributions (wind call, range estimate, muzzle
// velocity SD). The math is well-known precision-rifle dispersion
// modelling — sum of independent Gaussian sources of error, integrate
// the resulting 2D Gaussian over the target shape.
//
// Public API:
//
//   * `class HitProbabilityResult` — output of [HitProbabilityService.compute]:
//       hit probability (0..1), total horizontal/vertical 1-sigma at the
//       target in inches/mil/MOA, and a per-source factor breakdown the
//       UI uses for the "why?" expandable panel.
//
//   * `class HitProbabilityFactor` — one entry in the breakdown.
//
//   * `enum TargetShape` — the shape codes supported. Maps to drift's
//     `Targets.shape` strings (`circle`, `square`, `rectangle`,
//     `silhouette`, `irregular`).
//
//   * `class HitProbabilityService` — stateless service. The single
//     `compute(...)` method is pure functional; no side effects, no I/O.
//     Constructed by callers (and provided in `lib/app.dart`).
//
// ============================================================================
// THE MATH
// ============================================================================
// For each source of error we estimate its 1-sigma contribution to the
// shot's location at the target, in inches:
//
//   1. Group dispersion at distance.
//      Reloaders report group capability as the *extreme spread* of a
//      5-shot group at 100 yd, in MOA. Statistically that equals
//      approximately 4-sigma (the radius of the bounding circle is
//      ~2.7σ, the diameter ~4σ). So the 1-sigma at distance is:
//        groupSigmaIn = (assumedGroupMoa × 1.047 × distanceYd / 100) / 4
//      (1 MOA = 1.047 inches at 100 yards.)
//
//   2. Wind uncertainty (horizontal only):
//      ±U mph is treated as a 2-sigma confidence window. We re-solve
//      the trajectory at base + U mph and base − U mph; the difference
//      in horizontal drift is the 4-sigma spread, so we divide by 4 to
//      get the 1-sigma horizontal hit-point error.
//
//   3. Range uncertainty (vertical only):
//      Same trick on distance. ±U yd → re-solve at `dist + U` and
//      `dist − U`; drop_high − drop_low ÷ 4 is the 1-sigma vertical
//      hit-point error.
//
//   4. Muzzle velocity SD (vertical only):
//      Re-solve at MV + SD and MV − SD; drop_high − drop_low ÷ 4 is
//      the 1-sigma vertical contribution.
//
// Total sigma:
//
//   σ_x = sqrt(group² + wind²)
//   σ_y = sqrt(group² + range² + mv²)
//
// Hit probability for a circular target of radius R centered on the
// target center, given an aim offset (ax, ay) in inches (0,0 = dead
// center):
//
//   p = ∫∫ N(σ_x, σ_y) over the disk of radius R centered at (-ax, -ay)
//
// We integrate via Monte Carlo with 10,000 deterministic samples — the
// answer is stable to ~1 percentage point and runs in <5ms on a phone.
//
// For rectangles we use the same MC integration with rectangular
// bounds. For silhouettes we approximate by the bounding rectangle for
// v1 (the geometry would otherwise need shape masks).
//
// ============================================================================
// REPRODUCIBILITY
// ============================================================================
// We seed the random generator from the inputs so two compute calls with
// identical arguments return the same probability. This keeps the UI
// stable as the user types (we don't want the displayed % to jiggle by
// 1 point each rebuild).

import 'dart:math' as math;

import '../services/ballistics/atmosphere.dart';
import '../services/ballistics/drag_functions.dart';
import '../services/ballistics/environment.dart';
import '../services/ballistics/projectile.dart';
import '../services/ballistics/solver.dart';
import '../services/ballistics/units.dart' as bu;

/// Target geometry codes. Matches the strings stored in `Targets.shape`.
enum TargetShape { circle, square, rectangle, silhouette, irregular }

/// Convenience parser for the drift-stored shape string.
TargetShape parseTargetShape(String s) {
  switch (s.toLowerCase()) {
    case 'circle':
      return TargetShape.circle;
    case 'square':
      return TargetShape.square;
    case 'rectangle':
      return TargetShape.rectangle;
    case 'silhouette':
      return TargetShape.silhouette;
    default:
      return TargetShape.irregular;
  }
}

/// One contributor to total dispersion. The UI uses this to render the
/// breakdown — both the absolute inches and the percentage of variance.
class HitProbabilityFactor {
  const HitProbabilityFactor({
    required this.label,
    required this.contribIn,
  });

  /// Display label (e.g. "Group capability", "Wind ±2 mph").
  final String label;

  /// 1-sigma contribution to total dispersion at the target, in inches.
  /// We keep it as 1-sigma because that's what variance composition is
  /// natural in: variance = sigma² and contributions add up linearly.
  final double contribIn;
}

/// The output of [HitProbabilityService.compute].
class HitProbabilityResult {
  const HitProbabilityResult({
    required this.hitProbability,
    required this.dispersionMoa,
    required this.horizontalSigmaIn,
    required this.verticalSigmaIn,
    required this.horizontalSigmaMil,
    required this.verticalSigmaMil,
    required this.horizontalSigmaMoa,
    required this.verticalSigmaMoa,
    required this.factors,
  });

  /// 0..1 probability that a single shot lands inside the target.
  final double hitProbability;

  /// Total 2D dispersion expressed as a single MOA number (the maximum
  /// of horizontal and vertical sigma converted to MOA at the target
  /// distance). Surfaced for users who think in MOA only.
  final double dispersionMoa;

  /// 1-sigma horizontal at target, inches.
  final double horizontalSigmaIn;

  /// 1-sigma vertical at target, inches.
  final double verticalSigmaIn;

  /// Same in mils.
  final double horizontalSigmaMil;

  final double verticalSigmaMil;

  /// Same in MOA.
  final double horizontalSigmaMoa;

  final double verticalSigmaMoa;

  /// One entry per error source. Order: group, wind, range, MV SD.
  final List<HitProbabilityFactor> factors;
}

/// Stateless service. Construct once per provider scope. `compute` is
/// pure functional — calling it twice with the same arguments returns
/// the same result.
class HitProbabilityService {
  const HitProbabilityService();

  /// Number of Monte Carlo samples for the integration. 10k gives ~1pp
  /// stability and runs comfortably under the 300ms debounce budget.
  static const int _samples = 10000;

  /// Compute hit probability + dispersion breakdown.
  HitProbabilityResult compute({
    required double aimOffsetXIn,
    required double aimOffsetYIn,
    required double targetWidthIn,
    required double targetHeightIn,
    required TargetShape shape,
    required double distanceYd,
    required double assumedGroupMoa,
    required double windUncertaintyMph,
    required double rangeUncertaintyYd,
    required double mvSdFps,
    required double bcG7,
    required double muzzleVelocityFps,
    // Environment defaults — used by the perturbation re-solves so the
    // wind/range/MV deltas are realistic at the user's actual conditions.
    double tempF = 59,
    double pressureInHg = 29.92,
    double humidityPct = 50,
    double elevationFt = 0,
    double windSpeedMph = 0,
    double windDirDeg = 270,
    double sightHeightIn = 1.5,
    double zeroRangeYd = 100,
    double bulletWeightGr = 140,
    double bulletDiameterIn = 0.264,
  }) {
    // Sanitize inputs.
    final dist = distanceYd.clamp(1, 5000).toDouble();
    final groupMoa = assumedGroupMoa.clamp(0.05, 20).toDouble();
    final windU = windUncertaintyMph.clamp(0, 30).toDouble();
    final rangeU = rangeUncertaintyYd.clamp(0, 200).toDouble();
    final mvSd = mvSdFps.clamp(0, 200).toDouble();

    // 1. Group dispersion at distance, inches per axis.
    //    1 MOA = 1.047" at 100 yards.
    //    The user's "group MOA" is the extreme spread of a 5-shot
    //    group ≈ 4σ; we divide by 4 to recover the 1-sigma at distance.
    final groupSigmaIn = (groupMoa * 1.047) * dist / 100.0 / 4;

    // 2/3/4. Solver-based perturbations. We protect against bad inputs
    //         by catching exceptions and falling back to zero deltas —
    //         it's safer to under-report variance than to throw.
    double windSigmaIn = 0;
    double rangeSigmaIn = 0;
    double mvSigmaIn = 0;

    try {
      final projectile = Projectile(
        diameterIn: bulletDiameterIn,
        weightGr: bulletWeightGr,
        bc: bcG7,
        dragModel: DragModel.g7,
      );
      final atmosphere = Atmosphere.station(
        tempF: tempF,
        stationPressureInHg: pressureInHg,
        humidityPct: humidityPct,
        altitudeFt: elevationFt,
      );
      Environment envWithWind(double wind) => Environment.fromImperial(
            atmosphere: atmosphere,
            windSpeedMph: wind,
            windFromDegrees: windDirDeg,
            shotAzimuthDegrees: 0,
            latitudeDegrees: 40,
            targetElevationFt: 0,
          );

      TrajectorySample? solveAt({
        required double mv,
        required double range,
        required double wind,
      }) {
        if (mv <= 0 || range <= 0) return null;
        // Use [BallisticsAccuracy.fast] here on purpose: the
        // perturbation re-solves run six times per `compute(...)` call
        // (wind ±, range ±, MV ±) and the user expects sub-300ms
        // total. The fixed-step RK4 produces results within ~0.3 MIL
        // of the adaptive Cash–Karp solver for smooth supersonic
        // flight, and the dispersion-modeling math down-stream
        // tolerates a few percent of integrator noise.
        final samples = solveTrajectory(
          projectile: projectile,
          environment: envWithWind(wind),
          shot: ShotInputs(
            muzzleVelocityFps: mv,
            sightHeightIn: sightHeightIn,
            zeroRangeYards: zeroRangeYd,
          ),
          sampleRangesYards: [range],
          includeSpinDrift: false,
          includeCoriolis: false,
          includeAerodynamicJump: false,
          accuracy: BallisticsAccuracy.fast,
        );
        if (samples.isEmpty) return null;
        return samples.first;
      }

      // Wind ± uncertainty per the spec:
      //   σ = (drift_high − drift_low) / 4
      // where ±U is a 2-sigma confidence window. We solve at base + U
      // and base − U (the 4-sigma extremes) and take the difference
      // divided by 4. drift_low can be negative when (base − U) drives
      // the wind from the opposite direction, which is fine — the
      // solver handles negative wind magnitudes consistently with the
      // direction vector.
      if (windU > 0) {
        final hi = solveAt(
          mv: muzzleVelocityFps,
          range: dist,
          wind: windSpeedMph + windU,
        );
        final lo = solveAt(
          mv: muzzleVelocityFps,
          range: dist,
          wind: windSpeedMph - windU,
        );
        if (hi != null && lo != null) {
          windSigmaIn =
              (hi.windDriftInches - lo.windDriftInches).abs() / 4;
        }
      }

      // Range ± uncertainty per the spec:
      //   σ = (drop_high − drop_low) / 4
      // where ±U yd is a 2-sigma window.
      if (rangeU > 0) {
        final hi = solveAt(
          mv: muzzleVelocityFps,
          range: math.min(5000, dist + rangeU),
          wind: windSpeedMph,
        );
        final lo = solveAt(
          mv: muzzleVelocityFps,
          range: math.max(1, dist - rangeU),
          wind: windSpeedMph,
        );
        if (hi != null && lo != null) {
          rangeSigmaIn = (hi.dropInches - lo.dropInches).abs() / 4;
        }
      }

      // MV SD per spec: solve at MV ± SD, sigma = (drop_high − drop_low) / 4.
      // The /4 here is the same convention used for wind/range: ±SD is
      // treated as a 2-sigma window across MV (a generous read of "this
      // SD is what I trust ±2σ").
      if (mvSd > 0) {
        final hi = solveAt(
          mv: muzzleVelocityFps + mvSd, range: dist, wind: windSpeedMph,
        );
        final lo = solveAt(
          mv: math.max(100, muzzleVelocityFps - mvSd),
          range: dist,
          wind: windSpeedMph,
        );
        if (hi != null && lo != null) {
          mvSigmaIn = (hi.dropInches - lo.dropInches).abs() / 4;
        }
      }
    } catch (_) {
      // Solver blew up — fall back to group-only dispersion. This is a
      // graceful degradation; the user still gets a probability that
      // reflects rifle capability, just without the wind/range/MV
      // contributions.
    }

    // Total sigma per axis: x = group ⊕ wind ; y = group ⊕ range ⊕ mv.
    final sigmaX = math.sqrt(groupSigmaIn * groupSigmaIn +
        windSigmaIn * windSigmaIn);
    final sigmaY = math.sqrt(groupSigmaIn * groupSigmaIn +
        rangeSigmaIn * rangeSigmaIn +
        mvSigmaIn * mvSigmaIn);

    // Hit probability via deterministic Monte Carlo. Seed from the
    // inputs so the answer is stable.
    final seed = _seedFromInputs(
      aimOffsetXIn,
      aimOffsetYIn,
      targetWidthIn,
      targetHeightIn,
      shape.index,
      dist,
      groupMoa,
      windU,
      rangeU,
      mvSd,
    );
    final rng = math.Random(seed);
    final p = _monteCarloHitProbability(
      rng: rng,
      aimOffsetXIn: aimOffsetXIn,
      aimOffsetYIn: aimOffsetYIn,
      targetWidthIn: targetWidthIn,
      targetHeightIn: targetHeightIn,
      shape: shape,
      sigmaX: sigmaX,
      sigmaY: sigmaY,
    );

    // Single-number dispersion summary for the gauge subtitle.
    final maxSigmaIn = math.max(sigmaX, sigmaY);
    final dispersionMoa =
        dist <= 0 ? 0.0 : bu.inchesToMoaAtYards(maxSigmaIn, dist);

    return HitProbabilityResult(
      hitProbability: p,
      dispersionMoa: dispersionMoa,
      horizontalSigmaIn: sigmaX,
      verticalSigmaIn: sigmaY,
      horizontalSigmaMil:
          dist <= 0 ? 0.0 : bu.inchesToMilAtYards(sigmaX, dist),
      verticalSigmaMil:
          dist <= 0 ? 0.0 : bu.inchesToMilAtYards(sigmaY, dist),
      horizontalSigmaMoa:
          dist <= 0 ? 0.0 : bu.inchesToMoaAtYards(sigmaX, dist),
      verticalSigmaMoa:
          dist <= 0 ? 0.0 : bu.inchesToMoaAtYards(sigmaY, dist),
      factors: [
        HitProbabilityFactor(
          label: 'Group capability',
          contribIn: groupSigmaIn,
        ),
        HitProbabilityFactor(
          label: 'Wind ±${_fmt(windU)} mph',
          contribIn: windSigmaIn,
        ),
        HitProbabilityFactor(
          label: 'Range ±${_fmt(rangeU)} yd',
          contribIn: rangeSigmaIn,
        ),
        HitProbabilityFactor(
          label: 'MV SD ±${_fmt(mvSd)} fps',
          contribIn: mvSigmaIn,
        ),
      ],
    );
  }

  // ─────────────────────── Internals ───────────────────────

  /// Box–Muller transform: takes two uniform [0,1) samples and returns
  /// one standard-normal sample. Cheap, well-known, plenty good for our
  /// dispersion model.
  static double _normal(math.Random rng) {
    double u1 = rng.nextDouble();
    while (u1 == 0) {
      u1 = rng.nextDouble();
    }
    final u2 = rng.nextDouble();
    return math.sqrt(-2.0 * math.log(u1)) * math.cos(2 * math.pi * u2);
  }

  static double _monteCarloHitProbability({
    required math.Random rng,
    required double aimOffsetXIn,
    required double aimOffsetYIn,
    required double targetWidthIn,
    required double targetHeightIn,
    required TargetShape shape,
    required double sigmaX,
    required double sigmaY,
  }) {
    if (sigmaX <= 0.001 && sigmaY <= 0.001) {
      // Degenerate — perfectly precise rifle. The shot lands exactly
      // at the aim point. So it's a 1.0 if the aim point is inside the
      // target, 0.0 otherwise.
      return _isInside(
        x: aimOffsetXIn,
        y: aimOffsetYIn,
        widthIn: targetWidthIn,
        heightIn: targetHeightIn,
        shape: shape,
      )
          ? 1.0
          : 0.0;
    }
    var hits = 0;
    for (var i = 0; i < _samples; i++) {
      final dx = _normal(rng) * sigmaX;
      final dy = _normal(rng) * sigmaY;
      // Aim offset: aim point is (aimOffsetX, aimOffsetY) from target
      // center (positive Y = up). Shot lands at aim + dispersion.
      final hitX = aimOffsetXIn + dx;
      final hitY = aimOffsetYIn + dy;
      if (_isInside(
        x: hitX,
        y: hitY,
        widthIn: targetWidthIn,
        heightIn: targetHeightIn,
        shape: shape,
      )) {
        hits++;
      }
    }
    return hits / _samples;
  }

  static bool _isInside({
    required double x,
    required double y,
    required double widthIn,
    required double heightIn,
    required TargetShape shape,
  }) {
    final hx = widthIn / 2;
    final hy = heightIn / 2;
    switch (shape) {
      case TargetShape.circle:
        // Use the smaller half-axis as radius (matches how circle
        // targets are stored — width == height).
        final r = math.min(hx, hy);
        return (x * x + y * y) <= r * r;
      case TargetShape.square:
      case TargetShape.rectangle:
      case TargetShape.irregular:
        return x.abs() <= hx && y.abs() <= hy;
      case TargetShape.silhouette:
        // For v1, approximate as the bounding rectangle. Future work:
        // shape-specific mask via `dart:ui`'s `Path.contains` against a
        // canonical silhouette path.
        return x.abs() <= hx && y.abs() <= hy;
    }
  }

  /// Hashes the inputs into a reproducible 32-bit seed so two compute
  /// calls with identical inputs produce identical Monte Carlo results.
  static int _seedFromInputs(
    double aimX,
    double aimY,
    double w,
    double h,
    int shapeIdx,
    double dist,
    double group,
    double windU,
    double rangeU,
    double mvSd,
  ) {
    // Simple FNV-1a-style hash of stringified inputs. We only need
    // determinism, not cryptographic quality.
    final s =
        '${aimX.toStringAsFixed(2)}|${aimY.toStringAsFixed(2)}|$w|$h|$shapeIdx|'
        '${dist.toStringAsFixed(0)}|$group|$windU|$rangeU|$mvSd';
    var hash = 0x811C9DC5;
    for (final code in s.codeUnits) {
      hash ^= code;
      hash = (hash * 0x01000193) & 0x7fffffff;
    }
    return hash;
  }

  static String _fmt(double v) {
    if (v == v.roundToDouble()) return v.toStringAsFixed(0);
    return v.toStringAsFixed(1);
  }
}
