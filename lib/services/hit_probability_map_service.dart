// FILE: lib/services/hit_probability_map_service.dart
//
// ============================================================================
// WHAT THIS FILE DOES
// ============================================================================
// Computes the Hit Probability Map curve (formerly known internally as
// "WEZ" — Weapon Employment Zone): hit probability vs range, given a
// target geometry and the shooter's intrinsic uncertainty envelope
// (group capability, wind call, range estimate, MV SD).
//
// The output is the standard "WEZ chart" published in *Modern
// Advancements in Long Range Shooting Vol 1*: a curve that starts
// near 100% at short range,
// drops as variance accumulates, and crosses meaningful thresholds (90 / 75
// / 50 / 25%) at successively longer distances. The shooter uses it to answer
// "what's my realistic engagement distance for this target?" — the answer
// isn't "max effective range" (a velocity-only number), it's "the range at
// which my hit probability falls below acceptable."
//
// Public API:
//
//   * `class HitProbabilityMapPoint` — one (rangeYd, hitProbability0to1)
//     pair. The curve is a `List<HitProbabilityMapPoint>` returned in
//     ascending range order.
//
//   * `class HitProbabilityMapResult` — the computed curve plus the
//     variance contribution breakdown at one user-chosen reference range.
//     The breakdown tells the shooter what to fix to improve the curve
//     (the coaching framing): at short range group dominates, at long
//     range wind dominates.
//
//   * `class HitProbabilityMapVarianceFactor` — one entry in the breakdown
//     (label + fraction-of-variance 0..1 + 1-sigma contribution in inches
//     at the reference range).
//
//   * `class HitProbabilityMapService` — stateless. The single
//     `compute(...)` method is pure functional; no I/O, no side effects.
//
// ============================================================================
// THE MATH
// ============================================================================
// For each range R in the requested band:
//
//   1. Run the ballistic solver at R (BallisticsAccuracy.fast — same setting
//      HitProbabilityService uses for its perturbation re-solves).
//   2. Compute the four 1-sigma dispersion contributions at R:
//        σ_group = group_inches_at_R / 4
//                = (group_moa × 1.047 × R / 100) / 4
//        σ_wind  = |drift_at_wind+u − drift_at_wind−u| / 4
//        σ_range = |drop_at_R+u − drop_at_R−u| / 4
//        σ_mv    = |drop_at_MV+SD − drop_at_MV−SD| / 4
//      The /4 factor matches HitProbabilityService: ±U is a 2-sigma window
//      (4-sigma extreme spread), so dividing the spread by 4 recovers σ.
//   3. Combine per axis:
//        σ_x = sqrt(σ_group² + σ_wind²)
//        σ_y = sqrt(σ_group² + σ_range² + σ_mv²)
//   4. Hit probability = 2D Gaussian integral over the target shape.
//      Implementation: deterministic Monte Carlo with 2000 samples per range
//      (tuned for the curve — total cost stays under 200ms on a phone for
//      a 60-point curve). The MC seed is derived from the inputs so two
//      identical compute calls return the same curve (the displayed
//      thresholds shouldn't jiggle as the user types).
//
// PERFORMANCE
//
// The variance perturbations are the expensive part. For a 60-point curve
// the naive implementation runs the solver 5 × 60 = 300 times. We cache the
// "no perturbation" trajectory across all range samples — the solver's
// `sampleRangesYards` parameter accepts a list and returns one sample per
// range from a SINGLE integration, so we get the base trajectory in one
// solve. That collapses 60 base solves to 1.
//
// The wind / range / MV perturbations still need their own solves per range,
// but we batch them via the same trick: one solve at MV+SD with all sample
// ranges (gives all the warm-MV drops at once), one at MV-SD, one at
// wind+U, one at wind-U. Range perturbations can't be batched the same way
// (each requested range needs a different perturbed range), but they're the
// minority of the variance budget at typical distances.
//
// Net cost: 4 batched perturbation solves + N "off-by-rangeUncertainty"
// micro-solves ≈ 4 + 60 = 64 solves on a 60-point curve, each at
// BallisticsAccuracy.fast. On a phone that's ~3 ms × 64 ≈ 200 ms — at the
// upper edge of the requested 200ms budget. We further amortize range
// perturbations by skipping them when rangeUncertaintyYd <= 0.
//
// ============================================================================
// COACHING-FRAMING BREAKDOWN
// ============================================================================
// At a single user-chosen "reference range" we compute the four σ
// contributions and report each as a fraction of total variance:
//
//     fraction_i = σ_i² / Σ σ_j²
//
// (variance composition is linear because the contributions are independent
// Gaussians; sigma composition is the Pythagorean sum.)
//
// the coaching observation: at short range σ_group is the dominant term
// (the rifle's intrinsic capability), so a tighter group is the lever to
// pull. At long range σ_wind dominates because crosswind drift scales with
// time-of-flight, which grows much faster than range. The MV-SD term
// becomes a meaningful contributor past ~600 yd as drop sensitivity to MV
// grows. The range-uncertainty term is roughly constant in fraction-of-
// variance terms once it kicks in.
//
// We surface the breakdown so the user can see which knob to turn. The UI
// renders it as a stacked-bar or pie-chart-style breakdown alongside the
// curve.
//
// ============================================================================
// WHY IT EXISTS IN THE ARCHITECTURE
// ============================================================================
// The core math overlaps with `HitProbabilityService.compute()` (single
// aim point, single distance). Rather than refactor that service to do
// curve sampling, we keep it focused on the per-frame "what's the hit
// probability at the user's exact aim point right now?" question and put
// the curve-sampling math here. They share the same baseline ideas —
// 4-sigma spread / 4 = 1-sigma, Pythagorean sum on each axis, MC
// integration — and they intentionally use the same conventions so the
// numbers agree at a single point.
//
// ============================================================================
// REFERENCES
// ============================================================================
//   * industry-standard, "Modern Advancements in Long Range Shooting Volume 1",
//     ch. 4 (Weapon Employment Zone Analysis). The methodology.
//   * industry-standard, "Applied Ballistics for Long Range Shooting" 2nd ed. —
//     same dispersion math as `HitProbabilityService.compute`.
//   * `lib/services/hit_probability_service.dart` — the per-point version
//     of the same calculation.

import 'dart:convert';
import 'dart:math' as math;

import 'ballistics/atmosphere.dart';
import 'ballistics/drag_functions.dart';
import 'ballistics/environment.dart';
import 'ballistics/projectile.dart';
import 'ballistics/solver.dart';
import 'hit_probability_service.dart';

/// One point on the Hit Probability Map curve. Range in yards (ascending
/// order across the list), hit probability as a 0..1 fraction.
class HitProbabilityMapPoint {
  const HitProbabilityMapPoint({
    required this.rangeYd,
    required this.hitProbability,
  });

  final double rangeYd;
  final double hitProbability;

  Map<String, double> toJson() => {'r': rangeYd, 'p': hitProbability};

  static HitProbabilityMapPoint fromJson(Map<String, dynamic> j) =>
      HitProbabilityMapPoint(
        rangeYd: (j['r'] as num).toDouble(),
        hitProbability: (j['p'] as num).toDouble(),
      );
}

/// One contributor to the dispersion breakdown at a single reference range.
class HitProbabilityMapVarianceFactor {
  const HitProbabilityMapVarianceFactor({
    required this.label,
    required this.contribIn,
    required this.fractionOfVariance,
  });

  /// Display label (e.g. "Group", "Wind", "Range", "MV").
  final String label;

  /// 1-sigma contribution to total dispersion at the reference range, in
  /// inches.
  final double contribIn;

  /// 0..1 share of total variance (Σ σ²). Bars sum to 1.0 across the
  /// four factors.
  final double fractionOfVariance;
}

/// Output of [HitProbabilityMapService.compute].
class HitProbabilityMapResult {
  const HitProbabilityMapResult({
    required this.curve,
    required this.referenceRangeYd,
    required this.factorsAtReferenceRange,
    required this.computedAt,
  });

  /// The hit-probability-vs-range curve, sorted ascending by range.
  final List<HitProbabilityMapPoint> curve;

  /// Range in yards the [factorsAtReferenceRange] breakdown was computed
  /// at. Caller-chosen.
  final double referenceRangeYd;

  /// Per-source variance contributions at [referenceRangeYd].
  final List<HitProbabilityMapVarianceFactor> factorsAtReferenceRange;

  /// Wall-clock when the result was computed. Persisted onto
  /// `WezProfiles.computedAt` when the user saves the result. NOTE: the
  /// underlying drift table is still named `WezProfiles` for storage
  /// compatibility — renaming it requires a schema migration. The Dart
  /// surface uses the new "Hit Probability Map" naming.
  final DateTime computedAt;

  /// Smallest range at which `hitProbability` drops below [threshold01].
  /// Returns null if the curve never drops below the threshold within
  /// the sampled band. `threshold01` is in 0..1 (e.g. 0.5 for 50 %).
  double? rangeAtHitProbabilityBelow(double threshold01) {
    for (final p in curve) {
      if (p.hitProbability < threshold01) return p.rangeYd;
    }
    return null;
  }

  /// Largest range still meeting [threshold01]. Inverse phrasing of
  /// [rangeAtHitProbabilityBelow]; useful for the "≥ 75% range band"
  /// summary widget.
  double? maxRangeAtHitProbabilityAtLeast(double threshold01) {
    double? best;
    for (final p in curve) {
      if (p.hitProbability >= threshold01) {
        best = p.rangeYd;
      } else {
        // Curve is monotonically non-increasing in expectation; once we
        // see one sample below, later samples will also be below. Bail.
        // The non-increasing assumption can be locally violated by
        // Monte Carlo noise (~1 pp), but we don't want to silently keep
        // walking past a transition.
        return best;
      }
    }
    return best;
  }

  /// Serializes [curve] to a JSON string compatible with
  /// `WezProfiles.curveJson` (the legacy drift column name is preserved
  /// to avoid a schema migration; see the class doc above).
  String curveJsonString() =>
      jsonEncode(curve.map((p) => p.toJson()).toList());

  /// Inverse of [curveJsonString]; returns the points in ascending
  /// range order regardless of source ordering.
  static List<HitProbabilityMapPoint> curveFromJson(String s) {
    final list = (jsonDecode(s) as List)
        .map((e) => HitProbabilityMapPoint.fromJson(e as Map<String, dynamic>))
        .toList()
      ..sort((a, b) => a.rangeYd.compareTo(b.rangeYd));
    return list;
  }
}

/// Stateless service. Construct once per provider scope.
class HitProbabilityMapService {
  const HitProbabilityMapService();

  /// Number of Monte Carlo samples per range point. 2000 keeps the curve
  /// stable to ~1 percentage point and a 60-point curve runs in ~150ms
  /// on a phone (versus ~600ms at 10000 samples). The MC noise floor is
  /// well below the noise floor of the variance perturbations themselves.
  static const int _samplesPerPoint = 2000;

  /// Compute the Hit Probability Map curve and the variance-contribution
  /// breakdown at the chosen reference range.
  ///
  /// `rangesYd` is the list of distances to evaluate, ascending order.
  /// Typical: `[100, 125, ..., 1500]` (60 points at 25-yd steps).
  ///
  /// `referenceRangeYd` is where the
  /// [HitProbabilityMapResult.factorsAtReferenceRange] breakdown is
  /// computed. Doesn't have to be in `rangesYd` — the breakdown re-runs
  /// the same per-range math at that single distance. A typical default
  /// is the median of `rangesYd` or one of the "≥ 50 % hit" boundary
  /// ranges.
  HitProbabilityMapResult compute({
    required List<double> rangesYd,
    required double referenceRangeYd,
    // Target geometry.
    required double targetWidthIn,
    required double targetHeightIn,
    required TargetShape shape,
    // Uncertainty inputs.
    required double assumedGroupMoa,
    required double windUncertaintyMph,
    required double rangeUncertaintyYd,
    required double mvSdFps,
    // Projectile / shot.
    required double bcG7,
    required double muzzleVelocityFps,
    double bulletWeightGr = 140,
    double bulletDiameterIn = 0.264,
    double sightHeightIn = 1.5,
    double zeroRangeYd = 100,
    // Environment.
    double tempF = 59,
    double pressureInHg = 29.92,
    double humidityPct = 50,
    double elevationFt = 0,
    double windSpeedMph = 0,
    double windDirDeg = 270,
    double latitudeDeg = 40,
    // Aim offset on the target (inches relative to center).
    double aimOffsetXIn = 0,
    double aimOffsetYIn = 0,
  }) {
    if (rangesYd.isEmpty) {
      return HitProbabilityMapResult(
        curve: const [],
        referenceRangeYd: referenceRangeYd,
        factorsAtReferenceRange: const [],
        computedAt: DateTime.now(),
      );
    }

    // Sanitize.
    final groupMoa = assumedGroupMoa.clamp(0.05, 20).toDouble();
    final windU = windUncertaintyMph.clamp(0, 30).toDouble();
    final rangeU = rangeUncertaintyYd.clamp(0, 200).toDouble();
    final mvSd = mvSdFps.clamp(0, 200).toDouble();
    final ranges = List<double>.of(rangesYd)..sort();

    // Build solver inputs once.
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
    Environment env({double? wind}) => Environment.fromImperial(
          atmosphere: atmosphere,
          windSpeedMph: wind ?? windSpeedMph,
          windFromDegrees: windDirDeg,
          shotAzimuthDegrees: 0,
          latitudeDegrees: latitudeDeg,
          targetElevationFt: 0,
        );

    List<TrajectorySample> solveAtAll({
      required double mv,
      required double wind,
      required List<double> sampleRanges,
    }) {
      try {
        return solveTrajectory(
          projectile: projectile,
          environment: env(wind: wind),
          shot: ShotInputs(
            muzzleVelocityFps: mv,
            sightHeightIn: sightHeightIn,
            zeroRangeYards: zeroRangeYd,
          ),
          sampleRangesYards: sampleRanges,
          includeSpinDrift: false,
          includeCoriolis: false,
          includeAerodynamicJump: false,
          accuracy: BallisticsAccuracy.fast,
        );
      } catch (_) {
        return const [];
      }
    }

    // The four batched solves we use across every range. Each returns one
    // sample per element of `ranges`.
    final baseSamples = solveAtAll(
      mv: muzzleVelocityFps,
      wind: windSpeedMph,
      sampleRanges: ranges,
    );
    final windHiSamples = windU > 0
        ? solveAtAll(
            mv: muzzleVelocityFps,
            wind: windSpeedMph + windU,
            sampleRanges: ranges,
          )
        : <TrajectorySample>[];
    final windLoSamples = windU > 0
        ? solveAtAll(
            mv: muzzleVelocityFps,
            wind: windSpeedMph - windU,
            sampleRanges: ranges,
          )
        : <TrajectorySample>[];
    final mvHiSamples = mvSd > 0
        ? solveAtAll(
            mv: muzzleVelocityFps + mvSd,
            wind: windSpeedMph,
            sampleRanges: ranges,
          )
        : <TrajectorySample>[];
    final mvLoSamples = mvSd > 0
        ? solveAtAll(
            mv: math.max(100, muzzleVelocityFps - mvSd),
            wind: windSpeedMph,
            sampleRanges: ranges,
          )
        : <TrajectorySample>[];

    final curve = <HitProbabilityMapPoint>[];
    for (var i = 0; i < ranges.length; i++) {
      final R = ranges[i];

      final sigmas = _sigmasForRange(
        rangeYd: R,
        groupMoa: groupMoa,
        windU: windU,
        rangeU: rangeU,
        mvSd: mvSd,
        baseSamples: baseSamples,
        windHiSamples: windHiSamples,
        windLoSamples: windLoSamples,
        mvHiSamples: mvHiSamples,
        mvLoSamples: mvLoSamples,
        sampleIndex: i,
        muzzleVelocityFps: muzzleVelocityFps,
        windSpeedMph: windSpeedMph,
        solver: solveAtAll,
      );

      final p = _monteCarloHitProbability(
        seed: _seedFromInputs(
          R, groupMoa, windU, rangeU, mvSd, aimOffsetXIn, aimOffsetYIn,
          targetWidthIn, targetHeightIn, shape.index,
        ),
        aimOffsetXIn: aimOffsetXIn,
        aimOffsetYIn: aimOffsetYIn,
        targetWidthIn: targetWidthIn,
        targetHeightIn: targetHeightIn,
        shape: shape,
        sigmaX: sigmas.x,
        sigmaY: sigmas.y,
      );
      curve.add(HitProbabilityMapPoint(rangeYd: R, hitProbability: p));
    }

    // Variance contribution at the reference range (re-run the σ
    // calculation against a fresh, on-demand solve at exactly that
    // distance so the breakdown matches the user's chosen point even
    // if it isn't in the sampled curve).
    final refSigmasRaw = _sigmasForReferenceRange(
      referenceRangeYd: referenceRangeYd,
      groupMoa: groupMoa,
      windU: windU,
      rangeU: rangeU,
      mvSd: mvSd,
      muzzleVelocityFps: muzzleVelocityFps,
      windSpeedMph: windSpeedMph,
      solver: solveAtAll,
    );
    final factors = _breakdownFactors(refSigmasRaw);

    return HitProbabilityMapResult(
      curve: curve,
      referenceRangeYd: referenceRangeYd,
      factorsAtReferenceRange: factors,
      computedAt: DateTime.now(),
    );
  }

  // ─────────────────────── Variance computation ───────────────────────

  /// Per-source 1-sigma contributions at one range (from cached batched
  /// solves), composed into the per-axis sigmas the MC integrator needs.
  ({
    double x,
    double y,
    double group,
    double wind,
    double range,
    double mv,
  }) _sigmasForRange({
    required double rangeYd,
    required double groupMoa,
    required double windU,
    required double rangeU,
    required double mvSd,
    required List<TrajectorySample> baseSamples,
    required List<TrajectorySample> windHiSamples,
    required List<TrajectorySample> windLoSamples,
    required List<TrajectorySample> mvHiSamples,
    required List<TrajectorySample> mvLoSamples,
    required int sampleIndex,
    required double muzzleVelocityFps,
    required double windSpeedMph,
    required List<TrajectorySample> Function({
      required double mv,
      required double wind,
      required List<double> sampleRanges,
    }) solver,
  }) {
    final groupSigma =
        (groupMoa * 1.047) * rangeYd / 100.0 / 4;

    double safe(List<TrajectorySample> ss, int i) {
      if (i < 0 || i >= ss.length) return 0;
      return ss[i].dropInches;
    }

    double safeWind(List<TrajectorySample> ss, int i) {
      if (i < 0 || i >= ss.length) return 0;
      return ss[i].windDriftInches;
    }

    final windSigma = (windU > 0 &&
            windHiSamples.isNotEmpty &&
            windLoSamples.isNotEmpty)
        ? (safeWind(windHiSamples, sampleIndex) -
                    safeWind(windLoSamples, sampleIndex))
                .abs() /
            4
        : 0.0;

    final mvSigma = (mvSd > 0 &&
            mvHiSamples.isNotEmpty &&
            mvLoSamples.isNotEmpty)
        ? (safe(mvHiSamples, sampleIndex) - safe(mvLoSamples, sampleIndex))
                .abs() /
            4
        : 0.0;

    // Range uncertainty isn't batchable across multiple sample ranges
    // because the perturbed range is per-point. We do one micro-solve
    // pair per range — these are the bulk of the cost.
    double rangeSigma = 0;
    if (rangeU > 0) {
      final hi = solver(
        mv: muzzleVelocityFps,
        wind: windSpeedMph,
        sampleRanges: [math.min(5000, rangeYd + rangeU)],
      );
      final lo = solver(
        mv: muzzleVelocityFps,
        wind: windSpeedMph,
        sampleRanges: [math.max(1, rangeYd - rangeU)],
      );
      if (hi.isNotEmpty && lo.isNotEmpty) {
        rangeSigma = (hi.first.dropInches - lo.first.dropInches).abs() / 4;
      }
    }

    final sigmaX = math.sqrt(groupSigma * groupSigma + windSigma * windSigma);
    final sigmaY = math.sqrt(groupSigma * groupSigma +
        rangeSigma * rangeSigma +
        mvSigma * mvSigma);

    return (
      x: sigmaX,
      y: sigmaY,
      group: groupSigma,
      wind: windSigma,
      range: rangeSigma,
      mv: mvSigma,
    );
  }

  /// Same as [_sigmasForRange] but doesn't reuse cached batched solves —
  /// runs fresh solves at exactly the reference range. Used only for the
  /// breakdown widget at one chosen distance.
  ({
    double group,
    double wind,
    double range,
    double mv,
  }) _sigmasForReferenceRange({
    required double referenceRangeYd,
    required double groupMoa,
    required double windU,
    required double rangeU,
    required double mvSd,
    required double muzzleVelocityFps,
    required double windSpeedMph,
    required List<TrajectorySample> Function({
      required double mv,
      required double wind,
      required List<double> sampleRanges,
    }) solver,
  }) {
    final groupSigma =
        (groupMoa * 1.047) * referenceRangeYd / 100.0 / 4;

    double windSigma = 0;
    if (windU > 0) {
      final hi = solver(
        mv: muzzleVelocityFps,
        wind: windSpeedMph + windU,
        sampleRanges: [referenceRangeYd],
      );
      final lo = solver(
        mv: muzzleVelocityFps,
        wind: windSpeedMph - windU,
        sampleRanges: [referenceRangeYd],
      );
      if (hi.isNotEmpty && lo.isNotEmpty) {
        windSigma =
            (hi.first.windDriftInches - lo.first.windDriftInches).abs() / 4;
      }
    }

    double mvSigma = 0;
    if (mvSd > 0) {
      final hi = solver(
        mv: muzzleVelocityFps + mvSd,
        wind: windSpeedMph,
        sampleRanges: [referenceRangeYd],
      );
      final lo = solver(
        mv: math.max(100, muzzleVelocityFps - mvSd),
        wind: windSpeedMph,
        sampleRanges: [referenceRangeYd],
      );
      if (hi.isNotEmpty && lo.isNotEmpty) {
        mvSigma = (hi.first.dropInches - lo.first.dropInches).abs() / 4;
      }
    }

    double rangeSigma = 0;
    if (rangeU > 0) {
      final hi = solver(
        mv: muzzleVelocityFps,
        wind: windSpeedMph,
        sampleRanges: [math.min(5000, referenceRangeYd + rangeU)],
      );
      final lo = solver(
        mv: muzzleVelocityFps,
        wind: windSpeedMph,
        sampleRanges: [math.max(1, referenceRangeYd - rangeU)],
      );
      if (hi.isNotEmpty && lo.isNotEmpty) {
        rangeSigma = (hi.first.dropInches - lo.first.dropInches).abs() / 4;
      }
    }

    return (
      group: groupSigma,
      wind: windSigma,
      range: rangeSigma,
      mv: mvSigma,
    );
  }

  /// Composes the four sigmas into a labeled, fraction-of-variance list.
  List<HitProbabilityMapVarianceFactor> _breakdownFactors(
    ({double group, double wind, double range, double mv}) s,
  ) {
    final vGroup = s.group * s.group;
    final vWind = s.wind * s.wind;
    final vRange = s.range * s.range;
    final vMv = s.mv * s.mv;
    final total = vGroup + vWind + vRange + vMv;
    double frac(double v) => total > 0 ? v / total : 0.0;
    return [
      HitProbabilityMapVarianceFactor(
        label: 'Group',
        contribIn: s.group,
        fractionOfVariance: frac(vGroup),
      ),
      HitProbabilityMapVarianceFactor(
        label: 'Wind',
        contribIn: s.wind,
        fractionOfVariance: frac(vWind),
      ),
      HitProbabilityMapVarianceFactor(
        label: 'Range',
        contribIn: s.range,
        fractionOfVariance: frac(vRange),
      ),
      HitProbabilityMapVarianceFactor(
        label: 'MV',
        contribIn: s.mv,
        fractionOfVariance: frac(vMv),
      ),
    ];
  }

  // ─────────────────────── Monte Carlo integration ───────────────────────

  /// Box–Muller transform: takes two uniform [0,1) samples and returns
  /// one standard-normal sample. Same as in HitProbabilityService — the
  /// curve and the per-point card use a consistent dispersion model.
  static double _normal(math.Random rng) {
    double u1 = rng.nextDouble();
    while (u1 == 0) {
      u1 = rng.nextDouble();
    }
    final u2 = rng.nextDouble();
    return math.sqrt(-2.0 * math.log(u1)) * math.cos(2 * math.pi * u2);
  }

  static double _monteCarloHitProbability({
    required int seed,
    required double aimOffsetXIn,
    required double aimOffsetYIn,
    required double targetWidthIn,
    required double targetHeightIn,
    required TargetShape shape,
    required double sigmaX,
    required double sigmaY,
  }) {
    if (sigmaX <= 0.001 && sigmaY <= 0.001) {
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
    final rng = math.Random(seed);
    var hits = 0;
    for (var i = 0; i < _samplesPerPoint; i++) {
      final dx = _normal(rng) * sigmaX;
      final dy = _normal(rng) * sigmaY;
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
    return hits / _samplesPerPoint;
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
        final r = math.min(hx, hy);
        return (x * x + y * y) <= r * r;
      case TargetShape.square:
      case TargetShape.rectangle:
      case TargetShape.irregular:
      case TargetShape.silhouette:
        return x.abs() <= hx && y.abs() <= hy;
    }
  }

  /// Reproducibility hash: identical inputs always produce the same
  /// curve. Without this the displayed thresholds would jiggle by ~1pp
  /// every keystroke as the underlying Random reseed changed.
  static int _seedFromInputs(
    double range,
    double groupMoa,
    double windU,
    double rangeU,
    double mvSd,
    double aimX,
    double aimY,
    double w,
    double h,
    int shapeIdx,
  ) {
    final s = '${range.toStringAsFixed(0)}|$groupMoa|$windU|$rangeU|$mvSd|'
        '${aimX.toStringAsFixed(2)}|${aimY.toStringAsFixed(2)}|$w|$h|$shapeIdx';
    var hash = 0x811C9DC5;
    for (final code in s.codeUnits) {
      hash ^= code;
      hash = (hash * 0x01000193) & 0x7fffffff;
    }
    return hash;
  }
}
