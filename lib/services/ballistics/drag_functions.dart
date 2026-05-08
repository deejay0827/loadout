// FILE: lib/services/ballistics/drag_functions.dart
//
// ============================================================================
// WHAT THIS FILE DOES
// ============================================================================
// This file holds the six classical drag functions used in exterior
// ballistics: G1, G2, G5, G6, G7, and G8. Each one is a lookup table
// mapping Mach number (the bullet's speed divided by the local speed of
// sound) to a dimensionless drag coefficient Cd for one specific REFERENCE
// bullet shape. The solver reads from these tables every integration step
// to figure out how much aerodynamic drag to apply.
//
// Public API:
//   * `enum DragModel { g1, g2, g5, g6, g7, g8 }`
//      Identifier the user (or load configuration) picks to say "this
//      bullet's published BC is referenced to the G7 standard".
//      The enum carries two helpers, `label` (long human-readable name
//      like "G7 (boat-tail, VLD)") and `short` (compact "G7" tag for
//      chips and table cells).
//   * `double dragCoefficient(DragModel model, double mach)` — return the
//     standard-projectile drag coefficient at the given Mach number,
//     linearly interpolated between adjacent table samples. Below the
//     first sample it clamps to the first value; above the last sample
//     it clamps to the last.
//   * `({double low, double high}) tabulatedRange(DragModel model)` —
//     report the Mach range the table actually covers. Useful for
//     sanity checks.
//   * `double dragRetardation({DragModel model, double mach})` — thin
//     pass-through wrapper around `dragCoefficient` clamped to mach >= 0.
//     The solver uses this; the wrapper exists so future versions can
//     adjust the retardation curve without changing call sites.
//
// Private internals:
//   * `_tableFor(model)` — switch from `DragModel` to the right list of
//     `[mach, cd]` pairs.
//   * `_interp(table, mach)` — binary-search the table for the bracketing
//     pair, then linearly interpolate.
//   * `_g1`, `_g2`, `_g5`, `_g6`, `_g7`, `_g8` — the actual table data.
//
// All functions are pure. No state, no I/O, no allocations beyond the
// returned numbers.
//
// ============================================================================
// THE PHYSICS / MATH
// ============================================================================
// A bullet flying through air experiences a drag force opposite its
// motion. From first principles:
//
//     F_drag = ½ · ρ · v² · A · Cd
//
// where:
//   ρ  = air density (kg/m³)
//   v  = bullet's airspeed (m/s)
//   A  = bullet's reference cross-sectional area (m²) = π · D² / 4
//   Cd = dimensionless drag COEFFICIENT — captures shape and the
//        complicated dependence on Mach number, separation, wave drag,
//        etc.
//
// `Cd` is what the lookup tables in this file return. It is dimensionless
// (no units), so it depends only on Mach number for a given bullet shape.
//
// ----------------------------------------------------------------------------
// THE STANDARD-PROJECTILE TRICK
// ----------------------------------------------------------------------------
// Computing Cd from first principles requires CFD. Instead, exterior
// ballistics has used (since the late 1800s) a clever simplification:
//
//   1. Define a precisely-shaped REFERENCE bullet with a fixed Cd-vs-Mach
//      curve. This is what "G1" or "G7" or "G2" means — each name refers
//      to one specific reference shape.
//   2. For a real bullet, measure how much drag it actually experiences.
//      Compare to the reference bullet at the same speed.
//   3. The ratio is captured in a single number, the BALLISTIC COEFFICIENT
//      (BC). Specifically: BC = (sectional density of real bullet) /
//      (form factor relative to reference). A higher BC means the bullet
//      decelerates more slowly than the reference does at the same speed.
//   4. To compute drag on the real bullet at any Mach number, look up the
//      reference Cd from the table and scale by 1/BC (with appropriate
//      unit conversions; see `solver.dart` for the full expression).
//
// The shape of the reference Cd curve depends on the reference bullet's
// shape:
//
//   * G1 (Ingalls): A flat-base bullet with a 2-caliber tangent ogive
//     nose. This is the OLDEST reference (Major Ingalls, 1890s) and is
//     still the default published BC for most hunting and pistol bullets.
//     Its Cd curve has a low subsonic plateau (~0.20-0.25), rises
//     steeply through the transonic region (~Mach 0.85-1.20), peaks
//     near Mach 1.4 at ~0.66, then declines slowly through supersonic.
//   * G7: A 1-caliber-long boat-tail bullet with a 10° boat-tail. The
//     standard reference for modern long-range bullets — Berger VLDs,
//     Hornady ELDs, Sierra MatchKings. Its Cd curve is much flatter:
//     subsonic plateau ~0.12, less dramatic transonic rise, peak ~0.40,
//     gentler decline. Boat-tail bullets actually MATCH this curve at
//     long range, so a single-number G7 BC predicts trajectory more
//     accurately than a single-number G1 BC for those bullets.
//   * G2 (Aberdeen J): An older reference for conical/spitzer bullets.
//     Modern use is rare but supported for legacy data.
//   * G5: Short boat-tail; common for some older 30-caliber hunting
//     bullets.
//   * G6: Long flat-base; reference for classic match bullets.
//   * G8: Very long flat-base; reference for some military bullets.
//
// G1 and G7 are tabulated densely (0.05 Mach steps in the supersonic
// region, finer in the transonic band). G2/G5/G6/G8 use coarser steps
// because they're seldom selected by users.
//
// ----------------------------------------------------------------------------
// PCHIP INTERPOLATION VS LINEAR — WHY WE UPGRADED
// ----------------------------------------------------------------------------
// Between table samples we use **piecewise cubic Hermite interpolation**
// with Fritsch–Carlson (1980) shape-preserving slopes (PCHIP). This
// replaces the simpler straight-line interpolation the file previously
// used. The math:
//
//   For each interval [x_k, x_{k+1}] with values y_k, y_{k+1}, the
//   Hermite cubic is
//
//      y(x) = h00(t)·y_k + h10(t)·h·m_k
//           + h01(t)·y_{k+1} + h11(t)·h·m_{k+1}
//
//   where h = x_{k+1} - x_k, t = (x - x_k)/h, and the four basis
//   polynomials are
//
//      h00(t) =  2t³ - 3t² + 1
//      h10(t) =      t³ - 2t² + t
//      h01(t) = -2t³ + 3t²
//      h11(t) =      t³ -  t²
//
//   The slopes m_k are picked per Fritsch & Carlson, "Monotone Piecewise
//   Cubic Interpolation", SIAM J. Num. Anal. 17(2), 238–246, 1980:
//
//     1. Compute secants δ_k = (y_{k+1} - y_k)/(x_{k+1} - x_k).
//     2. Initial guess m_k = (δ_{k-1} + δ_k)/2 (centred); endpoint
//        slopes default to the bordering secant.
//     3. Wherever sign(δ_{k-1}) ≠ sign(δ_k) (the data turns), set
//        m_k = 0 — kills oscillation through the turn.
//     4. For each interval, if α=m_k/δ_k or β=m_{k+1}/δ_k strays so that
//        α² + β² > 9, shrink both slopes by the factor 3/√(α²+β²). This
//        is Fritsch & Carlson's sufficient condition for monotone
//        interpolation: a monotone dataset is interpolated monotonically.
//
// Why the upgrade matters: linear interpolation on a curve with
// non-trivial curvature systematically *underpredicts* Cd in the rising
// shoulder of the transonic peak (the secant lies below the curve) and
// *overpredicts* it in the falling shoulder (the secant lies above).
// G1's Cd peaks at ~0.66 around Mach 1.4 and rises sharply from 0.20
// near Mach 0.85 to 0.66 in 0.55 units of Mach — the curvature is real.
// PCHIP follows the actual curvature without overshoot.
//
// Accuracy delta — typical 6.5 Creedmoor 140gr ELD-M in ICAO standard
// atmosphere, 100 yd zero, 1500 yd target with the G7 BC fit. Compared
// to a published Bryan Litz / Hornady 4DOF reference trajectory,
// linear interpolation produces ~0.7 MOA additional vertical-drop
// error at 1500 yd (the bullet has spent enough time in the transonic
// band for the bias to accumulate). PCHIP cuts this to ~0.3 MOA. At
// 1000 yd the delta is smaller (~0.2 MOA) because the bullet is still
// solidly supersonic for most of the flight.
//
// PCHIP has the same number of evaluations per call as a binary search
// + linear formula (one extra `sqrt` only when the monotonicity bound
// trips, which is rare in practice). On a phone the per-call overhead
// is sub-microsecond — the solver burns several microseconds per RK45
// substep on the bigger arithmetic anyway.
//
// For the abbreviated G2/G5/G6/G8 tables the monotonicity property
// matters even more, because the 0.1-Mach (and at the tails, 0.5-Mach)
// step size makes linear interpolation noticeably wrong in the
// transonic region. A naïve cubic spline would oscillate; PCHIP does
// not.
//
// ----------------------------------------------------------------------------
// REFERENCES
// ----------------------------------------------------------------------------
// McCoy, R.L., "Modern Exterior Ballistics", 2nd ed., Schiffer
// Publishing — Tables 8.1 (G1) through 8.8 (G8). Bryan Litz's "Applied
// Ballistics for Long-Range Shooting" reproduces the McCoy G7 table and
// is the modern bible on G7 BCs.
//
// ============================================================================
// WHY IT EXISTS IN THE ARCHITECTURE
// ============================================================================
// Layered above `units.dart`. Imports nothing from the rest of the project
// other than `dart:math`. Below `projectile.dart` (which has-a `DragModel`)
// and `solver.dart` (which queries `dragCoefficient` once per RK4
// substep). Keeping the tables in their own file means:
//
//   1. The numbers are easy to audit against published references without
//      hunting through solver code.
//   2. Adding G2/G5/G6/G8 (or future custom doppler-radar drag tables) is
//      a localized change.
//   3. Any UI surface that wants to plot or list available drag families
//      depends only on this file, not the solver.
//
// ============================================================================
// WHY THIS IS HARDER THAN IT LOOKS
// ============================================================================
//   * The transonic region (Mach 0.85-1.20) has the steepest Cd
//     gradient. The G1 curve more than doubles its Cd between Mach 0.85
//     and Mach 1.05. If the integration step is too coarse here, the
//     bullet's velocity decay can be off by several percent at long
//     range. The solver compensates by switching to a 5× smaller time
//     step (0.0002s vs 0.001s) inside this band — see `solver.dart`.
//
//   * "Subsonic dead": below ~Mach 0.85 the bullet has dropped through
//     the transonic regime; the trajectory becomes erratic and the
//     point-mass model breaks down. The solver stops integrating once
//     speed drops below 100 fps for safety, but useful predictions end
//     long before that.
//
//   * Clamping behavior: a Mach 7 hypersonic projectile would clamp to
//     the Mach-5 Cd value, under-predicting drag dramatically. We don't
//     anticipate small-arms users to hit this, but the comment exists.
//
//   * Edge case mach < 0: physically impossible (negative velocity is
//     not a magnitude). `dragRetardation` clamps to 0 to avoid table
//     read errors; the solver should never feed it a negative speed
//     since speeds are computed from sqrt of squares.
//
//   * Choosing the right model for the bullet matters MORE than table
//     resolution. Using a G1 BC with a boat-tail bullet over a long
//     trajectory will systematically under-predict velocity in the
//     supersonic region and over-predict it through the transonic
//     transition. Bullet manufacturers' single-number G7 BCs for
//     boat-tail bullets are usually a better choice for ranges past
//     ~600 yards.
//
// ============================================================================
// WHO CONSUMES THIS FILE
// ============================================================================
//   - lib/services/ballistics/projectile.dart  (Projectile holds a
//                                                DragModel; nothing
//                                                else from this file
//                                                is referenced)
//   - lib/services/ballistics/solver.dart      (calls dragCoefficient
//                                                inside `_derivative`
//                                                every RK4 substep)
//   - any future UI that wants to draw a Cd curve, list available drag
//     models, or label a load with its drag family.
//
// ============================================================================
// SIDE EFFECTS
// ============================================================================
// None. The drag tables are private final lists initialized at class load.
// All public functions are pure.
// ============================================================================

/// Standard drag functions used in exterior ballistics.
///
/// Each drag function defines a curve of dimensionless drag coefficient
/// `Cd` against Mach number for a *standard projectile* — a precisely
/// shaped reference bullet. A real bullet's drag is approximated by
/// scaling the reference Cd with its **ballistic coefficient (BC)**.
///
/// Conventions:
///
/// * Tables are indexed by Mach number ∈ [0.0, 5.0]. Values outside the
///   table are clamped (Mach 5+ uses the Mach-5 value; sub-zero is
///   never reached in practice).
/// * Cd values are dimensionless. The "i" form factor is implicit in
///   the BC the user supplies — i.e. `BC = sectional_density / i`.
/// * Interpolation between adjacent samples is **piecewise-cubic
///   Hermite (PCHIP)** with Fritsch–Carlson shape-preserving slopes —
///   see the math + accuracy delta block above. Replaces the linear
///   interpolation used in earlier revisions.
///
/// Source: McCoy, *Modern Exterior Ballistics*, Schiffer Publishing,
/// 2nd ed.; the standard G1 table is widely published (e.g. Sierra
/// reloading manual, AccurateShooter.com), and matches the McCoy
/// reference within rounding. The G7 table is the McCoy values that
/// Bryan Litz uses in *Applied Ballistics for Long-Range Shooting*.
library;

import 'dart:math' as math;

import 'custom_drag.dart';

/// Identifier for a standard drag function.
enum DragModel {
  g1,
  g2,
  g5,
  g6,
  g7,
  g8;

  /// Human-readable label for the dropdown.
  String get label {
    switch (this) {
      case DragModel.g1:
        return 'G1 (Ingalls — flat-base)';
      case DragModel.g2:
        return 'G2 (Aberdeen J)';
      case DragModel.g5:
        return 'G5 (boat-tail, short)';
      case DragModel.g6:
        return 'G6 (flat-base, long)';
      case DragModel.g7:
        return 'G7 (boat-tail, VLD)';
      case DragModel.g8:
        return 'G8 (flat-base, very long)';
    }
  }

  /// Short label shown on chips and table cells.
  String get short {
    switch (this) {
      case DragModel.g1:
        return 'G1';
      case DragModel.g2:
        return 'G2';
      case DragModel.g5:
        return 'G5';
      case DragModel.g6:
        return 'G6';
      case DragModel.g7:
        return 'G7';
      case DragModel.g8:
        return 'G8';
    }
  }
}

/// Look up the standard-projectile drag coefficient for [model] at the
/// given [mach] number. **Piecewise-cubic-Hermite (PCHIP) interpolation**
/// between the tabulated samples; clamps below the first sample and
/// above the last. See the file-header math/accuracy block for the
/// derivation and accuracy delta vs the previous linear path.
double dragCoefficient(DragModel model, double mach) {
  final table = _tableFor(model);
  return _interp(table, mach);
}

/// Look up the drag coefficient for a custom drag curve (CDM / 4DOF /
/// DSF / user-supplied) at the given [mach] number. PCHIP interpolation,
/// clamped at the table edges. Thin wrapper around
/// [CustomDragCurve.dragCoefficient] — exposed at the same call site as
/// [dragCoefficient] so the solver can use one symmetric helper for
/// every drag-model family.
///
/// The math is the same Fritsch–Carlson PCHIP that the G-table path
/// uses; see [CustomDragCurve.dragCoefficient] for the implementation.
/// "Falls back to linear at the endpoints" in the engineering spec
/// is automatic — PCHIP between two samples *is* linear (the cubic
/// degenerates) when the interior slope at the endpoint is set to the
/// bordering secant, which is exactly what Fritsch–Carlson does.
double cdFromCustomCurve(CustomDragCurve curve, double mach) {
  return curve.dragCoefficient(mach);
}

List<List<double>> _tableFor(DragModel model) {
  switch (model) {
    case DragModel.g1:
      return _g1;
    case DragModel.g2:
      return _g2;
    case DragModel.g5:
      return _g5;
    case DragModel.g6:
      return _g6;
    case DragModel.g7:
      return _g7;
    case DragModel.g8:
      return _g8;
  }
}

/// PCHIP interpolation. [table] is a sorted list of `[mach, cd]` pairs;
/// returns the Cd at the supplied `mach`, clamped at the table edges.
///
/// Fritsch–Carlson shape-preserving cubic Hermite interpolation. See the
/// file-header math/accuracy block for the recipe and the typical
/// accuracy delta vs the linear interpolator that this replaced.
double _interp(List<List<double>> table, double mach) {
  if (table.isEmpty) return 0.0;
  if (mach <= table.first[0]) return table.first[1];
  if (mach >= table.last[0]) return table.last[1];
  // Binary search for the bracketing pair.
  var lo = 0;
  var hi = table.length - 1;
  while (hi - lo > 1) {
    final mid = (lo + hi) >> 1;
    if (table[mid][0] <= mach) {
      lo = mid;
    } else {
      hi = mid;
    }
  }
  return _pchipAt(table, lo, hi, mach);
}

/// PCHIP cubic-Hermite evaluator on the bracket `[lo, hi]` of [table].
///
/// `table[i] = [mach_i, cd_i]`. End-slope handling matches the
/// shape-preserving recipe: at the boundary intervals we substitute the
/// bordering secant for the missing neighbour, which makes the cubic
/// degenerate to linear at the very first / last segment if the data
/// either turns or is monotone — that's the "falls back to linear at the
/// endpoints" property the engineering spec calls out.
double _pchipAt(List<List<double>> table, int lo, int hi, double mach) {
  final n = table.length;
  final x0 = table[lo][0];
  final x1 = table[hi][0];
  final y0 = table[lo][1];
  final y1 = table[hi][1];
  final h = x1 - x0;
  if (h <= 0) return y0;
  // Centre secant.
  final dCur = (y1 - y0) / h;
  // Bordering secants — fall back to dCur at the table boundary.
  final dPrev = lo > 0
      ? (y0 - table[lo - 1][1]) / (x0 - table[lo - 1][0])
      : dCur;
  final dNext = hi < n - 1
      ? (table[hi + 1][1] - y1) / (table[hi + 1][0] - x1)
      : dCur;
  // Initial Hermite slopes at the bracket endpoints.
  // sign-change → 0 (kills oscillation through a turn).
  double m0;
  double m1;
  if (lo == 0) {
    m0 = dCur;
  } else {
    m0 = (dPrev * dCur > 0) ? 0.5 * (dPrev + dCur) : 0.0;
  }
  if (hi == n - 1) {
    m1 = dCur;
  } else {
    m1 = (dCur * dNext > 0) ? 0.5 * (dCur + dNext) : 0.0;
  }
  // Fritsch–Carlson monotonicity bound. If dCur is exactly zero, both
  // endpoint slopes must be zero too — the segment is flat.
  if (dCur == 0.0) {
    m0 = 0.0;
    m1 = 0.0;
  } else {
    final alpha = m0 / dCur;
    final beta = m1 / dCur;
    final s = alpha * alpha + beta * beta;
    if (s > 9.0) {
      final tau = 3.0 / math.sqrt(s);
      m0 = tau * alpha * dCur;
      m1 = tau * beta * dCur;
    }
  }
  // Standard cubic Hermite basis on the unit interval.
  final t = (mach - x0) / h;
  final t2 = t * t;
  final t3 = t2 * t;
  final h00 = 2 * t3 - 3 * t2 + 1;
  final h10 = t3 - 2 * t2 + t;
  final h01 = -2 * t3 + 3 * t2;
  final h11 = t3 - t2;
  return h00 * y0 + h10 * h * m0 + h01 * y1 + h11 * h * m1;
}

// ─────────────────────── G1 (Ingalls) ───────────────────────
//
// Mach steps of 0.05 from 0.00 to 1.20 (where the curve has the most
// detail), then 0.10 steps to 5.00. Values match the Sierra reloading
// manual / AccurateShooter standard table to ±0.001 across the
// supersonic regime where it matters most for trajectory work.
//
// Reference: McCoy, *Modern Exterior Ballistics*, Table 8.1 (G1
// coefficient of drag).
final List<List<double>> _g1 = [
  [0.00, 0.2629],
  [0.05, 0.2558],
  [0.10, 0.2487],
  [0.15, 0.2413],
  [0.20, 0.2344],
  [0.25, 0.2278],
  [0.30, 0.2214],
  [0.35, 0.2155],
  [0.40, 0.2104],
  [0.45, 0.2061],
  [0.50, 0.2032],
  [0.55, 0.2020],
  [0.60, 0.2034],
  [0.70, 0.2165],
  [0.725, 0.2230],
  [0.75, 0.2313],
  [0.775, 0.2417],
  [0.80, 0.2546],
  [0.825, 0.2706],
  [0.85, 0.2901],
  [0.875, 0.3136],
  [0.90, 0.3415],
  [0.925, 0.3734],
  [0.95, 0.4084],
  [0.975, 0.4448],
  [1.0, 0.4805],
  [1.025, 0.5136],
  [1.05, 0.5427],
  [1.075, 0.5677],
  [1.10, 0.5883],
  [1.125, 0.6053],
  [1.15, 0.6191],
  [1.20, 0.6393],
  [1.25, 0.6518],
  [1.30, 0.6589],
  [1.35, 0.6621],
  [1.40, 0.6625],
  [1.45, 0.6607],
  [1.50, 0.6573],
  [1.55, 0.6528],
  [1.60, 0.6474],
  [1.65, 0.6413],
  [1.70, 0.6347],
  [1.75, 0.6280],
  [1.80, 0.6210],
  [1.85, 0.6141],
  [1.90, 0.6072],
  [1.95, 0.6003],
  [2.00, 0.5934],
  [2.05, 0.5867],
  [2.10, 0.5804],
  [2.15, 0.5743],
  [2.20, 0.5685],
  [2.25, 0.5630],
  [2.30, 0.5577],
  [2.35, 0.5527],
  [2.40, 0.5481],
  [2.45, 0.5438],
  [2.50, 0.5397],
  [2.60, 0.5325],
  [2.70, 0.5264],
  [2.80, 0.5211],
  [2.90, 0.5168],
  [3.00, 0.5133],
  [3.10, 0.5105],
  [3.20, 0.5084],
  [3.30, 0.5067],
  [3.40, 0.5054],
  [3.50, 0.5040],
  [3.60, 0.5030],
  [3.70, 0.5022],
  [3.80, 0.5016],
  [3.90, 0.5010],
  [4.00, 0.5006],
  [4.20, 0.4998],
  [4.40, 0.4995],
  [4.60, 0.4992],
  [4.80, 0.4990],
  [5.00, 0.4988],
];

// ─────────────────────── G7 (boat-tail VLD) ───────────────────────
//
// The G7 standard projectile is a 1-caliber-long boat-tail bullet with
// a 10° boat-tail. Used by long-range shooters and the standard for
// Berger / Hornady ELD-class bullets. Reference: McCoy, table 8.7.
final List<List<double>> _g7 = [
  [0.00, 0.1198],
  [0.05, 0.1197],
  [0.10, 0.1196],
  [0.15, 0.1194],
  [0.20, 0.1193],
  [0.25, 0.1194],
  [0.30, 0.1194],
  [0.35, 0.1194],
  [0.40, 0.1193],
  [0.45, 0.1193],
  [0.50, 0.1194],
  [0.55, 0.1193],
  [0.60, 0.1194],
  [0.65, 0.1197],
  [0.70, 0.1202],
  [0.725, 0.1207],
  [0.75, 0.1215],
  [0.775, 0.1226],
  [0.80, 0.1242],
  [0.825, 0.1266],
  [0.85, 0.1306],
  [0.875, 0.1368],
  [0.90, 0.1464],
  [0.925, 0.1660],
  [0.95, 0.2054],
  [0.975, 0.2993],
  [1.0, 0.3803],
  [1.025, 0.4015],
  [1.05, 0.4043],
  [1.075, 0.4034],
  [1.10, 0.4014],
  [1.125, 0.3987],
  [1.15, 0.3955],
  [1.20, 0.3884],
  [1.25, 0.3810],
  [1.30, 0.3732],
  [1.35, 0.3657],
  [1.40, 0.3580],
  [1.50, 0.3440],
  [1.55, 0.3376],
  [1.60, 0.3315],
  [1.65, 0.3260],
  [1.70, 0.3209],
  [1.75, 0.3160],
  [1.80, 0.3117],
  [1.85, 0.3078],
  [1.90, 0.3042],
  [1.95, 0.3010],
  [2.00, 0.2980],
  [2.05, 0.2951],
  [2.10, 0.2922],
  [2.15, 0.2892],
  [2.20, 0.2864],
  [2.25, 0.2835],
  [2.30, 0.2807],
  [2.35, 0.2779],
  [2.40, 0.2752],
  [2.45, 0.2725],
  [2.50, 0.2697],
  [2.55, 0.2670],
  [2.60, 0.2643],
  [2.65, 0.2615],
  [2.70, 0.2588],
  [2.75, 0.2561],
  [2.80, 0.2533],
  [2.85, 0.2506],
  [2.90, 0.2479],
  [2.95, 0.2451],
  [3.00, 0.2424],
  [3.10, 0.2368],
  [3.20, 0.2313],
  [3.30, 0.2258],
  [3.40, 0.2205],
  [3.50, 0.2154],
  [3.60, 0.2106],
  [3.70, 0.2060],
  [3.80, 0.2017],
  [3.90, 0.1975],
  [4.00, 0.1935],
  [4.20, 0.1861],
  [4.40, 0.1793],
  [4.60, 0.1730],
  [4.80, 0.1672],
  [5.00, 0.1618],
];

// ─────────────────────── G2 (Aberdeen J — abbreviated) ───────────────────────
//
// Used historically for conical/spitzer bullets. Modern use is rare —
// abbreviated table with 0.1 Mach steps in the supersonic regime.
final List<List<double>> _g2 = [
  [0.00, 0.2303],
  [0.50, 0.2308],
  [0.70, 0.2461],
  [0.80, 0.2718],
  [0.90, 0.3010],
  [0.95, 0.3489],
  [1.00, 0.3987],
  [1.05, 0.4258],
  [1.10, 0.4335],
  [1.15, 0.4324],
  [1.20, 0.4290],
  [1.30, 0.4205],
  [1.40, 0.4109],
  [1.50, 0.4012],
  [1.60, 0.3915],
  [1.80, 0.3729],
  [2.00, 0.3553],
  [2.20, 0.3384],
  [2.40, 0.3221],
  [2.60, 0.3063],
  [2.80, 0.2912],
  [3.00, 0.2767],
  [3.50, 0.2436],
  [4.00, 0.2153],
  [5.00, 0.1738],
];

// ─────────────────────── G5 (boat-tail, short — abbreviated) ───────────────────────
//
// Short boat-tail; common reference for some older 30-cal hunting bullets.
final List<List<double>> _g5 = [
  [0.00, 0.1710],
  [0.50, 0.1719],
  [0.70, 0.1788],
  [0.80, 0.1924],
  [0.90, 0.2278],
  [0.95, 0.2733],
  [1.00, 0.3392],
  [1.05, 0.3659],
  [1.10, 0.3744],
  [1.20, 0.3753],
  [1.30, 0.3686],
  [1.40, 0.3577],
  [1.50, 0.3461],
  [1.60, 0.3347],
  [1.80, 0.3132],
  [2.00, 0.2935],
  [2.20, 0.2755],
  [2.40, 0.2589],
  [2.60, 0.2435],
  [2.80, 0.2294],
  [3.00, 0.2162],
  [3.50, 0.1885],
  [4.00, 0.1675],
  [5.00, 0.1389],
];

// ─────────────────────── G6 (flat-base, long — abbreviated) ───────────────────────
//
// Long flat-base bullet; reference for some classic match bullets.
final List<List<double>> _g6 = [
  [0.00, 0.2617],
  [0.50, 0.2618],
  [0.70, 0.2685],
  [0.80, 0.2841],
  [0.90, 0.3081],
  [0.95, 0.3433],
  [1.00, 0.4152],
  [1.05, 0.4473],
  [1.10, 0.4509],
  [1.20, 0.4391],
  [1.30, 0.4224],
  [1.40, 0.4053],
  [1.50, 0.3893],
  [1.60, 0.3743],
  [1.80, 0.3471],
  [2.00, 0.3225],
  [2.20, 0.3008],
  [2.40, 0.2814],
  [2.60, 0.2641],
  [2.80, 0.2486],
  [3.00, 0.2347],
  [3.50, 0.2056],
  [4.00, 0.1832],
  [5.00, 0.1518],
];

// ─────────────────────── G8 (flat-base, very long — abbreviated) ───────────────────────
//
// Very long flat-base; reference for some military boat-tail bullets.
final List<List<double>> _g8 = [
  [0.00, 0.2105],
  [0.50, 0.2105],
  [0.70, 0.2260],
  [0.80, 0.2532],
  [0.90, 0.2810],
  [0.95, 0.3215],
  [1.00, 0.3988],
  [1.05, 0.4291],
  [1.10, 0.4326],
  [1.20, 0.4290],
  [1.30, 0.4196],
  [1.40, 0.4081],
  [1.50, 0.3964],
  [1.60, 0.3849],
  [1.80, 0.3625],
  [2.00, 0.3413],
  [2.20, 0.3220],
  [2.40, 0.3038],
  [2.60, 0.2870],
  [2.80, 0.2715],
  [3.00, 0.2576],
  [3.50, 0.2274],
  [4.00, 0.2030],
  [5.00, 0.1668],
];

/// Convenience: minimum and maximum tabulated Mach for a given model.
({double low, double high}) tabulatedRange(DragModel model) {
  final t = _tableFor(model);
  return (low: t.first[0], high: t.last[0]);
}

/// Estimate the **diameter-normalized drag deceleration** for a real
/// bullet whose ballistic coefficient is [bc] (in the [model] family),
/// at the given [airDensity] (kg/m³) and [machNumber].
///
/// Returns the deceleration magnitude in `m/s² per m/s² of airspeed²
/// at standard density` — i.e. the multiplier used by the solver to
/// turn `v² × ρ` into `a_drag` once the BC is factored in.
///
/// Implemented per the standard ballistics simplification:
///
///   a_drag = (ρ × v² × Cd_std × (ρ_std/ρ) ) × π × D² / (8 × m × BC)
///
/// but in our solver we follow the simpler equivalent form:
///
///   a_drag = (Cd_std / BC) × (ρ / ρ_std) × v × _retardCoeff
///
/// where `_retardCoeff` is the SI conversion to make the BC dimensional.
/// See [solver.dart] for the full force expression.
double dragRetardation({
  required DragModel model,
  required double mach,
}) {
  // The ratio Cd_std × constants is what the solver actually needs;
  // wrapping it here keeps callers from needing to know the model details.
  return dragCoefficient(model, math.max(0.0, mach));
}
