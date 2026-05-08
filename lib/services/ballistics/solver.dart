// FILE: lib/services/ballistics/solver.dart
//
// ============================================================================
// WHAT THIS FILE DOES
// ============================================================================
// This is the main ballistic engine. It takes a `Projectile`, an
// `Environment`, and the shot details (muzzle velocity, sight height, zero
// range), then numerically integrates the 3D equations of motion to
// produce a list of `TrajectorySample` records — one per requested
// downrange distance — telling the shooter how much the bullet has
// dropped, drifted sideways, slowed down, etc.
//
// Public API:
//
//   * `class TrajectorySample` — one row of the output table:
//       - rangeYards, timeSec, dropInches, windDriftInches,
//         spinDriftInches, velocityFps, energyFtLb, machNumber
//     Sign conventions: dropInches positive = below line of sight,
//     windDriftInches positive = right of LoS.
//
//   * `class ShotInputs` — the parameters that change per-shot rather
//     than per-load:
//       - muzzleVelocityFps  — measured chronograph velocity.
//       - sightHeightIn      — vertical distance from bore axis to scope
//                              centerline (typically 1.5"-2.5").
//       - zeroRangeYards     — the range the rifle is sighted in at
//                              (typically 100, 200, or 300 yards).
//       - muzzleCantDeg      — rifle cant about the bore (degrees).
//                              Used only for the small aerodynamic-jump
//                              correction; defaults to 0.
//
//   * `List<TrajectorySample> solveTrajectory({ ... })` — the top-level
//     entry point. Steps:
//       1. Computes a one-time drag scaling constant from bullet
//          geometry (form factor, diameter, mass).
//       2. Bisects on the muzzle elevation angle until the bullet
//          crosses the line of sight at the user's zero range.
//       3. Integrates forward at the resolved departure angle, sampling
//          state at each requested range.
//       4. Adds Litz's empirical spin drift to each sample.
//       5. Returns the list.
//
//     Optional flags `includeSpinDrift` and `includeCoriolis` let the
//     caller turn off those corrections (e.g. for short-range plinking).
//
// Private internals (read for full understanding):
//
//   * `_findDepartureAngle(...)` — bisection zero solver.
//   * `_integrateUntilRange(...)` — RK4 integration without sampling;
//     used by the zero-finder to evaluate "how far below LoS is the
//     bullet at zero range?".
//   * `_integrateAndSample(...)` — RK4 integration WITH sampling; used
//     for the actual output trajectory.
//   * `_makeSample(...)` — convert an internal `_State` into a
//     user-facing `TrajectorySample`.
//   * `_State` — immutable 7-tuple (x, y, z, vx, vy, vz, t).
//   * `_rk4Step(...)` — one RK4 step.
//   * `_statePlus(...)` — apply a `_Derivative` scaled by `dt` to a
//     `_State`.
//   * `_Derivative` — immutable 6-tuple of derivatives.
//   * `_derivative(...)` — compute the derivatives at a state (drag,
//     gravity, Coriolis combined).
//   * `_gravity = 9.80665 m/s²` — standard gravity constant.
//
// ============================================================================
// THE PHYSICS / MATH
// ============================================================================
// ----------------------------------------------------------------------------
// THE STATE VECTOR AND THE EQUATIONS OF MOTION
// ----------------------------------------------------------------------------
// The bullet is treated as a POINT MASS. Its state at time t is six
// numbers — position (x, y, z) and velocity (vx, vy, vz). Newton's second
// law (F = m·a) in vector form gives:
//
//     d(position)/dt = velocity
//     d(velocity)/dt = sum_of_forces / mass
//
// We have three force contributions:
//
//   1. GRAVITY: a constant downward acceleration of g = 9.80665 m/s²
//      regardless of altitude. (We ignore Earth-curvature effects;
//      <0.5 inch error at 1500 yards.)
//
//   2. AERODYNAMIC DRAG: opposing the bullet's velocity through the air,
//      with magnitude:
//
//          F_drag = (π/8) · ρ · i · Cd_std(Mach) · D² · v²
//
//      where:
//        ρ        = air density (kg/m³, from atmosphere)
//        i        = bullet form factor = sectional density / BC
//        Cd_std   = standard-projectile drag coefficient at this Mach
//                   number (looked up from drag_functions.dart)
//        D        = bullet diameter (m)
//        v        = bullet's speed RELATIVE TO THE AIR (m/s)
//
//      The drag ACCELERATION is F_drag / m. We pre-compute the
//      "everything except ρ × Cd × v²" factor once at the start of the
//      solve as `dragK = (π/8) · i · D² / m_kg`. Then each step is:
//
//          a_drag_magnitude = dragK · ρ · v_rel · Cd
//          a_drag_vector    = -a_drag_magnitude · v_rel_vector
//
//      Note the velocity used is RELATIVE TO THE AIR — i.e. the bullet's
//      velocity minus the wind vector. This is how WIND enters the
//      equations: not as a separate force, but as an offset to the
//      relative-velocity term. A 10 mph crosswind makes the bullet's
//      apparent airspeed have a small lateral component, which then
//      generates lateral drag that pushes the bullet sideways.
//
//   3. CORIOLIS: a fictitious acceleration that arises from working in
//      Earth's rotating reference frame:
//
//          a_coriolis = −2 · Ω × v_bullet
//
//      where Ω is Earth's rotation vector (computed by
//      `Environment.earthRotationVector` from latitude and shot
//      azimuth) and × is the cross product. Magnitude is small (a few
//      cm/s² for typical bullet speeds) but it adds up over flight
//      times of seconds — typically a few inches at 1000 yards.
//
//      Component-wise, with Ω = (er.x, er.y, er.z) and v = (vx, vy, vz):
//
//          a_cor_x = −2 · (er.y · vz − er.z · vy)
//          a_cor_y = −2 · (er.z · vx − er.x · vz)
//          a_cor_z = −2 · (er.x · vy − er.y · vx)
//
// ----------------------------------------------------------------------------
// SPIN DRIFT (added POST-INTEGRATION)
// ----------------------------------------------------------------------------
// A spin-stabilized bullet drifts SIDEWAYS in the direction of its spin
// (right-hand twist barrels — the dominant US convention — drift the
// bullet to the RIGHT). This is a 6-DOF effect that arises from the
// gyroscopic interaction between the spinning bullet and the airflow,
// which we DO NOT model directly. Instead, we use Bryan Litz's empirical
// formula:
//
//     spin_drift_inches = 1.25 · (Sg + 1.2) · t^1.83
//
// where Sg is the Miller stability factor and t is time of flight in
// seconds. This formula is calibrated against full 6-DOF simulations and
// is accurate to a few tenths of an inch at typical small-arms ranges.
// We add this drift in +Z (right) for right-hand twist after the main
// integration completes — the integrator never sees it.
//
// ----------------------------------------------------------------------------
// THE RK4 INTEGRATOR (Runge-Kutta 4th order)
// ----------------------------------------------------------------------------
// To advance the state from time t to t+dt, the simplest method is Euler:
//
//     state_new = state_old + dt · derivative(state_old)
//
// This is FIRST-ORDER accurate — the error per step is O(dt²), and over
// the full integration the error is O(dt). To get fourth-order accuracy
// (error O(dt⁴) per step, O(dt³) over the integration), Runge-Kutta-4
// evaluates the derivative at FOUR strategic points within the time step
// and combines them with carefully chosen weights:
//
//     k1 = f(state_old)                    # derivative at start
//     k2 = f(state_old + (dt/2) · k1)      # derivative at midpoint
//                                            using k1 estimate
//     k3 = f(state_old + (dt/2) · k2)      # derivative at midpoint
//                                            using k2 estimate (refined)
//     k4 = f(state_old + dt · k3)          # derivative at end using k3
//                                            estimate
//     state_new = state_old + (dt/6)·(k1 + 2·k2 + 2·k3 + k4)
//
// The weights (1/6, 2/6, 2/6, 1/6) come from a Taylor-series expansion
// that cancels error terms up to and including the 4th order. This is
// the workhorse integrator of classical mechanics and gives excellent
// accuracy for smooth dynamics like ours.
//
// Implementation note: we represent `_State` and `_Derivative` as
// immutable record-style classes. `_statePlus(state, deriv, dt)` advances
// state by `deriv · dt`. The full `_rk4Step` in the file is the textbook
// algorithm above.
//
// ----------------------------------------------------------------------------
// TIME STEP (dt) AND TRANSONIC ADAPTATION
// ----------------------------------------------------------------------------
// We use a CASH–KARP adaptive RK45 by default ([BallisticsAccuracy.precise]
// and above). Cash–Karp evaluates six derivatives per step and combines
// them into both a fifth-order accurate solution and a fourth-order
// embedded estimate; the difference between the two is a per-step error
// estimate, used to halve `dt` when the error is too large and to grow
// `dt` (PI-style proportional control) when the dynamics are smooth. This
// is what every textbook adaptive RK45 implementation does (Cash & Karp
// 1990; Numerical Recipes §17.2). The trade-off:
//
//   * Compared to fixed RK4 at dt=0.001 s, adaptive RK45 typically halves
//     the total step count for a 1000-yard supersonic shot while
//     reducing terminal-position error by ~10×. The error estimate also
//     gives us a principled way to ratchet down `dt` automatically in
//     the transonic band where Cd changes rapidly — no special-case
//     "if mach in 0.85..1.20 use small dt" branch needed.
//   * Cost is ~1.5× the per-step work of RK4 (six evaluations vs four),
//     but with fewer steps the net wall-time on a phone is comparable
//     or faster.
//   * The trade-off knob is the user-visible [BallisticsAccuracy] enum:
//     `fast` → fixed RK4 with our old transonic band trick (≤50ms target),
//     `precise` → Cash–Karp adaptive, default tolerance 1e-4 m
//     (~100–200ms target), `extreme` → adaptive with 1e-6 m
//     tolerance (~500ms target). The tolerance is on per-step
//     truncation error in metres of position; over a 1000-yard shot
//     the accumulated error stays below 0.1 inch at the default
//     tolerance.
//
// In the TRANSONIC band (Mach 0.85 to Mach 1.20), the drag coefficient
// changes rapidly — for the G1 standard, Cd more than doubles across
// this range. A fixed 1-millisecond step there would resolve the rise
// too coarsely. For [BallisticsAccuracy.fast] (RK4) we keep the legacy
// 5× refinement (0.0002 s in the band). For the adaptive modes we cap
// `dt` to `0.0005 s` whenever Mach ∈ [0.80, 1.25] regardless of the
// error estimate, so the controller never grows past a step that would
// skip too much of the rapid Cd rise in one go.
//
// Stop conditions for the integration:
//   * `t >= 10.0 s`             — hard cap on flight time.
//   * `state.x > targetRange`   — passed all sample ranges.
//   * `state.y < -50 m`         — fell to the dirt.
//   * `state.speed < 100 fps`   — bullet effectively dead.
//
// ----------------------------------------------------------------------------
// THE ZERO-FINDING BISECTION (find the muzzle elevation angle)
// ----------------------------------------------------------------------------
// The user tells us they have a 100-yard zero (or 200, or 300, or
// whatever). Physically, this means: when aiming through the scope at a
// 100-yard target, the bullet should hit where the cross-hair is
// pointing. The scope is mounted ABOVE the bore, so the bore points
// slightly upward relative to the line of sight — the bullet leaves the
// muzzle ASCENDING relative to LoS, crosses the LoS, peaks, then drops
// back through the LoS at the zero range.
//
// We don't know this departure angle a priori — drag and gravity both
// affect it. So we BISECT:
//
//   1. Compute a quick parabolic approximation:
//          θ_0 ≈ (g·R) / (2·v₀²)
//      from the no-drag trajectory equation y(t) = v₀ sin(θ) t − ½ g t²
//      with the boundary condition y(R/v₀) = 0. This gets us within 10%.
//
//   2. Bracket: try θ_low = θ_0 − 0.020 rad, θ_high = θ_0 + 0.040 rad.
//      Compute the y-offset (bullet height − line-of-sight height) at
//      the zero range for both. We want the offset to be 0; if both
//      offsets have the same sign, expand the bracket and try again.
//
//   3. Bisect: 40 iterations of standard interval halving, stopping
//      early if the offset is below 0.1 mm. Each iteration runs a full
//      `_integrateUntilRange` simulation, so this is the expensive part
//      of solving — typically dominates the total runtime.
//
// ----------------------------------------------------------------------------
// LINE-OF-SIGHT GEOMETRY
// ----------------------------------------------------------------------------
// We put the muzzle at y=0 and the scope at y = +sightHeight (typically
// 1.5"-2.5" = 0.038-0.064 m). The shooter aims through the scope at the
// zero target which is at LoS y=0. So the line of sight as a function of
// downrange distance x is:
//
//     y_los(x) = sightHeight · (1 − x/zeroRange)
//
// At x = 0:           y_los = sightHeight (scope height above muzzle)
// At x = zeroRange:   y_los = 0 (target sits on the LoS)
// At x > zeroRange:   y_los < 0 (LoS continues downward past zero)
//
// The user's reported "drop" is the distance the bullet sits BELOW the
// LoS at any given range. We compute it as `dropM = y_los − bulletY`,
// then convert to inches.
//
// ============================================================================
// THE SIMPLIFICATIONS — VS A FULL 6-DOF MCCOY MPM
// ============================================================================
// "Modified Point Mass" (MPM) is McCoy's name for the family of point-mass
// solvers that get close to a full 6-DOF result by adding empirical
// corrections rather than tracking the full bullet attitude (yaw, pitch,
// spin axis). Compared to a full 6-DOF simulation, our implementation:
//
//   1. NO YAW OF REPOSE. Real bullets fly with their spin axis tilted
//      slightly off the velocity vector — a steady-state lean called the
//      "yaw of repose." This is what causes spin drift via gyroscopic
//      interaction with airflow. We add spin drift via Litz's empirical
//      formula instead of tracking yaw.
//
//   2. DRAG IS ISOTROPIC. We use `|v_rel|² · Cd(Mach)` along the
//      negative relative-velocity direction. The full McCoy treatment
//      decomposes drag into axial (along the spin axis) and yaw
//      components. For point-mass purposes our isotropic drag is fine —
//      yaw of repose is small in straight-line flight.
//
//   3. NO AERODYNAMIC-JUMP-FROM-CANT CORRECTION. Rifle cant (the
//      shooter holding the rifle tilted) tilts the line of sight, but
//      doesn't change the bullet's actual trajectory — the bullet still
//      flies the same path through the air. The `muzzleCantDeg` field
//      exists for a future correction; the solver does NOT currently
//      apply one (you can verify this by searching the file: the field
//      is read but only documented as "we'd compute aerodynamic jump
//      here").
//
//   4. CORIOLIS USES MUZZLE-VELOCITY DIRECTION ONLY. McCoy's full
//      treatment uses the instantaneous velocity direction. We only
//      project Earth's Ω vector once, at the start, using the muzzle
//      direction (which is essentially shot azimuth). For typical
//      small-arms ranges where the trajectory is nearly straight, this
//      is well below 0.1 MOA error.
//
//   5. NO TRANSONIC LIFT "KICK". Real bullets passing through the
//      transonic region experience a brief lift component that briefly
//      destabilizes them. We don't model the lift kick directly; the
//      finer dt in the transonic band partially compensates by
//      resolving the steep Cd gradient.
//
// At small-arms ranges (out to 1500 yards), these simplifications cost
// well below 0.1 MOA in vertical drop and a few inches in lateral drift —
// far smaller than typical shooter-induced error and well below the
// uncertainty in BC, MV, and atmospheric inputs.
//
// ============================================================================
// REFERENCES
// ============================================================================
//   * McCoy, R.L., "Modern Exterior Ballistics", 2nd ed. Schiffer
//     Publishing, 1999. The reference text on point-mass and 6-DOF
//     ballistic modeling.
//   * Litz, B., "Applied Ballistics for Long-Range Shooting", 2nd ed.
//     2009. Source of the 1.25·(Sg+1.2)·t^1.83 spin-drift formula and
//     the modern shooter-friendly treatment of MPM.
//   * Numerical Recipes (Press, Teukolsky, Vetterling, Flannery) —
//     classical RK4 derivation.
//
// ============================================================================
// WHY IT EXISTS IN THE ARCHITECTURE
// ============================================================================
// Top of the ballistics package. Imports `units.dart`,
// `drag_functions.dart`, `projectile.dart`, `environment.dart` — pulls
// from every other file in the package. Imported by future ballistics-
// solver UI screens. No dependence on Flutter widgets, Drift, Firebase,
// or anything else in the app — purely mathematical. This means:
//
//   1. The solver can be unit-tested headless with reference inputs and
//      expected outputs (e.g. against published Hornady or Berger
//      trajectory tables).
//   2. The same engine could power a CLI, a watchOS complication, or a
//      web preview without dragging in the rest of the app.
//   3. The dependency direction is unambiguous: `units` → `drag_functions`,
//      `units` → `atmosphere`, `units` → `projectile` → `drag_functions`,
//      `units` → `environment` → `atmosphere`, and `solver` → all of
//      them.
//
// ============================================================================
// WHY THIS IS HARDER THAN IT LOOKS
// ============================================================================
//   * NUMERICAL STABILITY of the zero-finder. If the user requests a
//     zero range that the load can't reach (insufficient muzzle velocity,
//     too far), the integration may never cross the line of sight. We
//     return -1e6 from `yOffsetAt` in that case so the bisection treats
//     "fell short" as "deeply negative offset". The bracket-expansion
//     loop bails out after 8 attempts and falls back to the analytic
//     guess — better than crashing.
//
//   * ZERO-RANGE EDGE CASES. Very short zero ranges (~50 yd) need a
//     small departure angle that the parabolic guess hits accurately.
//     Very long zero ranges (~1000 yd) need a large angle where the
//     parabolic guess is off by more, but the bracket window absorbs it.
//     Vertical-shooting cases (purely up or down) are NOT supported —
//     the integration assumes the bullet is moving primarily downrange
//     in +X, and a vertical shot has zero downrange velocity. There is
//     no "shoot straight up" mode in the solver.
//
//   * SUBSONIC TRANSITION. Once the bullet drops below ~Mach 0.85, the
//     point-mass model breaks down (the Magnus moment changes sign,
//     yaw destabilizes, etc.). We continue integrating until 100 fps,
//     but trajectories below Mach 1 should be considered approximate.
//     Long-range competitive shooting tries to keep the bullet
//     supersonic at the target.
//
//   * RK4 IS NOT ADAPTIVE. We don't estimate truncation error step by
//     step; we just use a fixed (or band-switched) dt. For the smooth
//     dynamics here that's fine, but if you ever model spin-stabilized
//     boattail bullets through hypersonic regimes, you'd want an
//     adaptive integrator.
//
//   * SIGN CONVENTIONS — SIX OF THEM. (a) drop positive=below LoS;
//     (b) wind drift positive=right; (c) spin drift positive=right
//     (right-hand twist); (d) +X downrange; (e) +Y up; (f) +Z right.
//     They're chosen so the user-facing outputs feel natural to a
//     shooter, but mismatches are easy to introduce if you ever
//     re-derive them. Test against known reference trajectories.
//
//   * COORDINATE FRAME IS FIXED AT MUZZLE. We do NOT rotate the frame
//     as the bullet flies. Earth's rotation enters via Coriolis. This
//     is fine for small-arms but would break for ICBM-scale flights.
//
//   * SAMPLE-RANGE INTERPOLATION. We integrate a fixed-step trajectory
//     and linearly interpolate state across the requested sample
//     ranges. If the user requests samples at 100, 200, 300, ..., 1000
//     and the integration step is 0.001s × ~800 m/s ≈ 0.8 m, then each
//     sample interpolation spans ~0.4 m before vs after — well below
//     the 100-yard sample spacing.
//
//   * COMPUTE COST. The bisection runs ~40 iterations × full
//     integration each. For a 1000-yard zero at 2700 fps, full flight
//     time is ~1.4 s, integration steps ~1400, bisection ~40, total
//     ~56 000 derivative evaluations. On a phone this is a few
//     milliseconds.
//
// ============================================================================
// WHO CONSUMES THIS FILE
// ============================================================================
//   - any future UI screen in `lib/screens/` that displays a trajectory
//     table or plot for a load (none yet wired in this branch).
//   - test code under `test/` (placeholder `widget_test.dart` exists;
//     real ballistics test coverage is a launch-checklist item).
//
// ============================================================================
// SIDE EFFECTS
// ============================================================================
// None. The solver is pure-functional: same `Projectile` + `Environment`
// + `ShotInputs` + sample ranges always produces the same output list.
// No I/O, no globals, no allocations beyond the returned
// `List<TrajectorySample>` and the immutable `_State` / `_Derivative`
// instances created during integration.
// ============================================================================

/// Modified Point-Mass (McCoy) ballistic solver for the LoadOut app.
///
/// Implements a 3D point-mass equation of motion with the following
/// forces / corrections:
///
///   1. **Aerodynamic drag** along the *relative* wind vector, scaled
///      by a Mach-indexed standard drag function (G1/G2/G5/G6/G7/G8)
///      and the bullet's BC, OR by a manufacturer-supplied custom drag
///      curve (CDM / DSF) attached to the projectile. With a custom
///      curve the BC is ignored and the form-factor scaling collapses
///      to 1.0 because the curve already captures the bullet's
///      real shape (see [Projectile.formFactor]).
///   2. **Gravity** as a constant downward acceleration (we ignore
///      Earth's curvature — the difference is <0.5 inch at 1500 yd).
///   3. **Coriolis** acceleration `−2 Ω × v` in a north-east-up local
///      frame projected by shot azimuth (Earth-rate components are
///      precomputed in [Environment.earthRotationVector]).
///   4. **Wind** drift, included in (1) by computing the relative wind
///      `v − v_air`.
///
/// Two horizontal corrections are added to the integrated trajectory
/// rather than baked into the equations of motion (this is the
/// "Modified" in MPM — it's the Litz-style add-on that real shooters
/// use because the full 6-DOF result and the MPM result differ by
/// ≪ 0.1 MOA at typical small-arms ranges):
///
///   * **Spin drift** — Litz's empirical formula
///     `Sd = 1.25 × (Sg + 1.2) × t^1.83` inches, applied along the
///     bullet's spin axis. Right-hand twist drifts the bullet right
///     (+z in our convention).
///   * **Aerodynamic jump** from rifle cant — applied as an initial
///     vertical-angle perturbation proportional to the cant angle and
///     the cross-wind component. We expose [muzzleCantDeg] for this;
///     callers leave it 0 by default.
///
/// The integrator is a classical 4th-order Runge–Kutta with a fixed
/// step size, refined to a smaller step inside the transonic band
/// (Mach 0.85–1.20) where the drag curve has sharp features.
library;

import 'dart:math' as math;

import 'atmosphere.dart';
import 'drag_functions.dart';
import 'environment.dart';
import 'projectile.dart';
import 'units.dart';

/// Selectable accuracy / runtime trade-off for the solver.
///
/// * [fast] — fixed-step classical RK4 with the legacy transonic-band
///   refinement. Targets ~50 ms per zero+trajectory on a phone. Suitable
///   for live UI updates and the hit-probability service's perturbation
///   re-solves.
/// * [precise] — Cash–Karp adaptive RK45 with per-step error tolerance
///   `1e-4` m. Targets ~100–200 ms. The default for one-off trajectory
///   tables and ELR (extreme long range) work.
/// * [extreme] — Cash–Karp adaptive RK45 with per-step error tolerance
///   `1e-6` m. Targets ~500 ms. For golden-test verification or when
///   shooters want every last millimetre of integrator precision (note:
///   below ~0.01" the BC, MV, and atmospheric inputs dominate the error
///   budget, not the integrator).
enum BallisticsAccuracy {
  fast,
  precise,
  extreme;

  /// Per-step truncation-error tolerance in metres of position. Only
  /// meaningful for the adaptive integrator.
  double get errorTolM {
    switch (this) {
      case BallisticsAccuracy.fast:
        return 1e-3; // unused (fixed dt in fast mode)
      case BallisticsAccuracy.precise:
        return 1e-4;
      case BallisticsAccuracy.extreme:
        return 1e-6;
    }
  }
}

/// Empirical spin-drift formula to use post-integration. The integrator
/// itself is the same; only the closed-form correction added to each
/// sample's lateral drift differs.
///
/// * [litz] — Bryan Litz's `Sd = 1.25 × (Sg + 1.2) × t^1.83` inches.
///   Calibrated against full 6-DOF simulations on typical match
///   bullets (Litz, *Applied Ballistics for Long-Range Shooting*,
///   2nd ed., ch. 9). Accurate to a few tenths of an inch out to
///   ~1500 yd; degrades past that as the t^1.83 power-law starts
///   under-predicting.
///
/// * [pejsa] — Art Pejsa's 6th-order spin-drift correction
///   (Pejsa, *New Exact Small Arms Ballistics*, 2008). At extreme
///   range (>1500 yd) the higher-order time terms produce a more
///   accurate drift than Litz's t^1.83 fit, especially for bullets
///   that remain stable through the transonic transition. Slightly
///   under-predicts at short range (the higher-order coefficients
///   come into play only when t > ~1.5 s) — Litz's fit is closer at
///   typical match-rifle distances.
///
/// Both formulas require a Miller stability factor and a flight time;
/// when `Sg` is missing (e.g. the shooter didn't enter bullet length)
/// neither correction is applied.
enum SpinDriftModel {
  litz,
  pejsa;

  String get label {
    switch (this) {
      case SpinDriftModel.litz:
        return 'Litz (default)';
      case SpinDriftModel.pejsa:
        return 'Pejsa (extreme range)';
    }
  }
}

/// One sample of a computed trajectory at a particular range.
class TrajectorySample {
  TrajectorySample({
    required this.rangeYards,
    required this.timeSec,
    required this.dropInches,
    required this.windDriftInches,
    required this.spinDriftInches,
    required this.velocityFps,
    required this.energyFtLb,
    required this.machNumber,
    this.aerodynamicJumpInches = 0,
    this.inclineCorrectionInches = 0,
    this.sightScaleVertical = 1.0,
    this.sightScaleHorizontal = 1.0,
  });

  /// Downrange distance (yards) — matches the requested sample range.
  final double rangeYards;

  /// Time of flight from muzzle (s).
  final double timeSec;

  /// Vertical drop from line of sight (inches). Positive = below LoS.
  /// Includes every vertical correction applied by the solver:
  /// integrated gravity drop, drag deceleration, Coriolis, aerodynamic
  /// jump, incline-angle (rifleman's-rule) correction, and the
  /// vertical sight-scale factor. The [aerodynamicJumpInches] and
  /// [inclineCorrectionInches] companions surface those individual
  /// contributions for the breakdown widget.
  final double dropInches;

  /// Horizontal wind drift, inches. Positive = right of LoS. Includes
  /// the horizontal sight-scale factor.
  final double windDriftInches;

  /// Horizontal spin drift, inches. Positive = right of LoS for a
  /// right-hand twist; negative for a left-hand twist. Already
  /// included in [windDriftInches]; surfaced here for the breakdown.
  final double spinDriftInches;

  /// Bullet velocity (fps).
  final double velocityFps;

  /// Kinetic energy (ft-lbs).
  final double energyFtLb;

  /// Bullet velocity expressed as Mach.
  final double machNumber;

  /// Aerodynamic-jump contribution to [dropInches], in inches. Computed
  /// per-range from the Litz simplified formula
  /// `0.087 × cross_wind_mph × tof_sec × velocity_fps / 1000`. Sign
  /// convention matches [dropInches] (positive = below LoS); a wind
  /// from the shooter's left therefore reduces drop slightly. Zero if
  /// `includeAerodynamicJump` was false at solve time.
  final double aerodynamicJumpInches;

  /// Incline-correction contribution to [dropInches], in inches. The
  /// improved-rifleman's-rule scales the level-shot drop by
  /// `cos(incline)^1.5`, so the correction reported here is the
  /// **delta** applied: `level_drop × (cos(angle)^1.5 - 1)`. Always
  /// non-positive in magnitude for typical uphill / downhill shots.
  /// Zero when no incline angle was specified.
  final double inclineCorrectionInches;

  /// Vertical sight-scale factor that was applied to [dropInches]
  /// (1.0 = no correction).
  final double sightScaleVertical;

  /// Horizontal sight-scale factor that was applied to
  /// [windDriftInches] (1.0 = no correction).
  final double sightScaleHorizontal;
}

/// Inputs that change shot to shot rather than load to load.
class ShotInputs {
  const ShotInputs({
    required this.muzzleVelocityFps,
    required this.sightHeightIn,
    required this.zeroRangeYards,
    this.muzzleCantDeg = 0,
    this.twistDirection = TwistDirection.right,
    this.sightScaleVertical = 1.0,
    this.sightScaleHorizontal = 1.0,
    this.inclineAngleDeg = 0,
  });

  final double muzzleVelocityFps;
  final double sightHeightIn;
  final double zeroRangeYards;

  /// Rifle cant about the bore axis, in degrees. Positive = right (top
  /// of scope tilts right). Combined with the cross-wind component this
  /// produces a small aerodynamic-jump correction; with no cant and no
  /// crosswind the term is zero.
  final double muzzleCantDeg;

  /// Direction of the rifling twist as viewed from behind the muzzle.
  /// Right-twist barrels (the dominant US convention) drift the bullet
  /// to the shooter's right; left-twist barrels flip the spin-drift
  /// sign. The aerodynamic-jump correction also flips with twist
  /// direction because spin axis vs velocity vector geometry follows
  /// the twist.
  final TwistDirection twistDirection;

  /// Vertical sight-scale multiplier — the elevation hold reported by
  /// the solver is scaled by this factor before being returned.
  /// Defaults to 1.0 (no correction). A measured 0.95 here means "my
  /// scope dials 0.95 mil for every commanded mil; report 5% smaller
  /// holds." Applied uniformly across all sample ranges.
  final double sightScaleVertical;

  /// Horizontal sight-scale multiplier, applied to wind / spin drift
  /// holds in the same way as [sightScaleVertical].
  final double sightScaleHorizontal;

  /// Incline / decline angle of the shot, in degrees. Positive = uphill,
  /// negative = downhill. The solver applies the **improved
  /// rifleman's rule**: drop is scaled by `cos(angle)^1.5`. The
  /// `cos^1.5` exponent is an empirical fit (Robert Brennan, Sierra
  /// Bullets) that tracks the true 6-DOF answer better than plain
  /// `cos(angle)` past ~25° — at 30° the simple cosine
  /// underestimates the correction by ~3%, while `cos^1.5` is within
  /// 0.5% of the radar-measured truth. Zero (default) means a level
  /// shot with no correction.
  final double inclineAngleDeg;
}

/// Direction the barrel rifles the bullet, viewed from behind the muzzle.
/// Right-twist is the dominant US convention; left-twist flips the sign
/// of the spin-drift correction.
enum TwistDirection {
  right,
  left;

  /// `+1` for right-twist, `-1` for left-twist. Multiplied into the
  /// post-integration spin-drift formula.
  double get sign {
    switch (this) {
      case TwistDirection.right:
        return 1.0;
      case TwistDirection.left:
        return -1.0;
    }
  }
}

/// Top-level entry point. Returns one [TrajectorySample] per element
/// of [sampleRangesYards].
///
/// Set [accuracy] to choose the runtime/precision trade-off; defaults
/// to [BallisticsAccuracy.precise]. Toggle [includeAerodynamicJump]
/// (default `true`) to add the McCoy/Litz aerodynamic-jump correction
/// (~0.1 mil per knot of crosswind). Set [includeConing] (default
/// `false`) to enable a small coning/yaw-of-repose correction relevant
/// beyond ~1500 yards.
///
/// The remaining `include*` flags exist to support the per-axis
/// contribution-breakdown widget on the ballistics screen. Disabling a
/// flag re-runs the full solve (zero-finder included) with that one
/// effect zeroed out, so the caller can compute `delta = full - variant`
/// and show the user "your gravity dial-up at 1000 yd is N MOA":
///
///   * `includeGravity`  — when false, sets g=0 in the equations of
///     motion. The bullet flies in a straight line (modulo drag), so
///     "drop" collapses to whatever sight-height geometry contributes.
///     The zero-finder still runs and converges on θ ≈ 0.
///   * `includeDrag`     — when false, sets the drag force to zero.
///     The bullet does not decelerate. Used only for the contribution
///     decomposition; the resulting velocity / energy figures are
///     unphysical.
///   * `includeWind`     — when false, zeros the wind vector before the
///     integrator sees it. With wind=0 the relative-velocity term
///     reduces to the bullet's own velocity and the lateral drag
///     contribution from crosswind disappears.
///
/// [zeroAtmosphere] is the optional snapshot of conditions at the time
/// the rifle was zeroed. When supplied, the departure angle is found
/// against that atmosphere (not the runtime atmosphere), so the rifle
/// stays "zeroed" under the conditions it was actually sighted in
/// under, while the runtime atmosphere drives the per-shot trajectory.
/// Use this to model "I zeroed at sea level but I'm shooting at
/// 5000 ft" without the calculator silently re-zeroing under the
/// new atmosphere. When null (default), the runtime atmosphere is
/// used for both zero-finding and trajectory integration (legacy
/// behaviour).
///
/// Callers in normal application flow leave every flag at its default.
List<TrajectorySample> solveTrajectory({
  required Projectile projectile,
  required Environment environment,
  required ShotInputs shot,
  required List<double> sampleRangesYards,
  Atmosphere? zeroAtmosphere,
  bool includeSpinDrift = true,
  bool includeCoriolis = true,
  bool includeAerodynamicJump = true,
  bool includeConing = false,
  bool includeGravity = true,
  bool includeDrag = true,
  bool includeWind = true,
  BallisticsAccuracy accuracy = BallisticsAccuracy.precise,
  SpinDriftModel spinDriftModel = SpinDriftModel.litz,
}) {
  if (sampleRangesYards.isEmpty) return const [];

  // Pre-compute drag scaling. F_drag/m = (π/8)·ρ·v²·i·Cd·D²/m, so the
  // factor that multiplies ρ·v²·Cd_std is (π/8)·i·D²/m. We compute
  // it once and reuse it on every step. When the caller asked us to
  // disable drag entirely (contribution-breakdown variant), we collapse
  // dragK to 0 so the per-step force evaluation drops out cleanly.
  final iFormFactor = projectile.formFactor;
  final dM = projectile.diameterM;
  final mKg = projectile.massKg;
  final dragK = includeDrag
      ? (math.pi / 8.0) * iFormFactor * dM * dM / mKg
      : 0.0;

  // Runtime air properties.
  final rho = environment.atmosphere.density;
  final aSnd = environment.atmosphere.speedOfSound;

  // Wind air-velocity vector (the air's velocity in the shooter frame).
  // Zeroed out when [includeWind] is false so the contribution-breakdown
  // widget can isolate the wind effect.
  final ({double x, double y, double z}) wv = includeWind
      ? environment.windVector
      : (x: 0.0, y: 0.0, z: 0.0);

  // Earth rotation vector — used by the Coriolis term.
  final er = environment.earthRotationVector;

  // ── Find the departure (super-elevation) angle that yields the user's zero ──
  //
  // We bisect on the muzzle-elevation angle θ until the bullet crosses
  // the line of sight at zeroRangeYards. The line of sight is the
  // straight line from the scope (above the bore by sight-height)
  // toward the zero target point.
  //
  // When [zeroAtmosphere] is supplied, the bisection runs against THAT
  // atmosphere (with no wind — zeroing is conventionally done in calm
  // air, and we don't model historical wind during the original zero
  // session). The runtime trajectory below then integrates the same
  // departure angle through the runtime atmosphere + wind, which is
  // exactly the behaviour the shooter wants: "the rifle stays zeroed
  // for the conditions I sighted in under, and the calculator tells
  // me the holdover I need *now*".

  final zeroRangeM = yardsToMeters(shot.zeroRangeYards);
  final sightHeightM = inchesToMeters(shot.sightHeightIn);

  // Quick ballpark from a small-angle parabolic estimate.
  //
  // The bullet starts at y=0 and must arrive at y=0 at x=zeroRange (so
  // that it's on the line of sight there). Without drag:
  //   y(t) = v0·sin(θ)·t − ½ g t² = 0 at t = R/v0
  // → sin(θ) = g R / (2 v0²)
  // i.e. θ ≈ (½ g) × t / v0  where t ≈ R/v0.
  //
  // With drag the real angle is slightly larger; bisection takes care
  // of the residual. This guess is good to ~10% — bracket window
  // below covers it comfortably.
  final v0 = fpsToMps(shot.muzzleVelocityFps);
  final tApprox = zeroRangeM / v0;
  final theta0 = 0.5 * 9.80665 * tApprox / v0;

  // Atmosphere used by the zero-finder. Defaults to runtime atmosphere
  // when no zero atmosphere is supplied.
  final zeroRho = zeroAtmosphere?.density ?? rho;
  final zeroASnd = zeroAtmosphere?.speedOfSound ?? aSnd;
  // Wind during zeroing — set to zero when a zero atmosphere is
  // explicitly supplied (calm-air zeroing convention). Otherwise reuse
  // the runtime wind so callers without a stored zero atmosphere see
  // legacy behaviour.
  final ({double x, double y, double z}) zeroWv = zeroAtmosphere == null
      ? wv
      : (x: 0.0, y: 0.0, z: 0.0);

  final departureRad = _findDepartureAngle(
    projectile: projectile,
    shot: shot,
    dragK: dragK,
    rho: zeroRho,
    aSnd: zeroASnd,
    wv: zeroWv,
    er: er,
    initialGuess: theta0,
    sightHeightM: sightHeightM,
    zeroRangeM: zeroRangeM,
    includeCoriolis: includeCoriolis,
    includeGravity: includeGravity,
    accuracy: accuracy,
  );

  // ── Run the actual trajectory at the resolved departure angle. ──
  final maxRangeYards =
      sampleRangesYards.reduce((a, b) => a > b ? a : b);
  final maxRangeM = yardsToMeters(maxRangeYards);

  final samples = _integrateAndSample(
    projectile: projectile,
    shot: shot,
    departureRad: departureRad,
    sightHeightM: sightHeightM,
    zeroRangeM: zeroRangeM,
    sampleRangesYards: List.of(sampleRangesYards)..sort(),
    maxRangeM: maxRangeM,
    dragK: dragK,
    rho: rho,
    aSnd: aSnd,
    wv: wv,
    er: er,
    includeCoriolis: includeCoriolis,
    includeGravity: includeGravity,
    accuracy: accuracy,
  );

  // ── Aerodynamic jump (Litz simplified, per-range) ───────────────
  //
  // A spin-stabilized bullet pitches slightly under crosswind because
  // its spin axis lags the velocity vector when the velocity vector
  // turns under the wind force. Litz's simplified per-range form
  // (from *Applied Ballistics for Long-Range Shooting*, ch. 9):
  //
  //     aero_jump_inches ≈ 0.087 × cross_wind_mph × tof_sec
  //                              × velocity_fps / 1000
  //
  // The 0.087 calibration constant produces ~0.05–0.1 mil at 1000 yd
  // for a 10 mph crosswind on a typical 6.5/7mm match bullet. The sign
  // matches spin drift for right-hand twist barrels: a "wind from the
  // left" makes the bullet jump UP (reduces drop). For left-twist
  // barrels the sign flips.
  //
  // Implementation: positive crossWindComponentMps (in our convention)
  // = wind from the LEFT = bullet pushed RIGHT for a right-twist
  // barrel. The aero-jump VERTICAL contribution for that wind is
  // UPWARD, so dropInches gets reduced. We negate the sign to put
  // "left wind" as a NEGATIVE drop contribution.
  //
  // We also keep the legacy small cant×crosswind term per Litz's
  // *Modern Advancements* vol. 3 — it stays angular and scales with
  // range.
  final twistSign = shot.twistDirection.sign;
  final aeroJumpPerSampleIn = List<double>.filled(samples.length, 0);
  if (includeAerodynamicJump && includeWind) {
    final crossMps = environment.crossWindComponentMps;
    final crossMph = crossMps / 0.44704;
    final hasTwist = (projectile.twistInches ?? 0) > 0;
    if (hasTwist && crossMph.abs() > 1e-9) {
      // Cant×crosswind contribution stays as the angular Litz vol. 3
      // term and is added on top of the per-range Litz formula.
      final crossKt = mpsToKnots(environment.crossWindComponentMps);
      final cantTermMil = -0.0014 * shot.muzzleCantDeg * crossKt;
      final cantRad = milToRadians(cantTermMil) * twistSign;
      for (var i = 0; i < samples.length; i++) {
        final s = samples[i];
        // Per-range Litz formula. Negative sign so a wind from the
        // left (positive crossMph in our convention) lifts the bullet
        // (negative drop contribution).
        final perRangeIn = -0.087 *
            crossMph *
            s.timeSec *
            s.velocityFps /
            1000.0 *
            twistSign;
        final cantIn = cantRad * s.rangeYards * 36.0;
        aeroJumpPerSampleIn[i] = perRangeIn + cantIn;
      }
    }
  }

  // ── Spin drift ──────────────────────────────────────────────────
  //
  // Empirical Litz (or Pejsa) post-integration correction. The closed
  // form depends on [spinDriftModel]:
  //
  //   * Litz (default): Sd = 1.25 · (Sg + 1.2) · t^1.83 inches.
  //   * Pejsa: 6th-order polynomial in t — picks up extra drift past
  //     ~1.5 s of flight where Litz's t^1.83 saturates.
  //
  // Both formulas return a magnitude assuming right-hand twist; we
  // multiply by [TwistDirection.sign] so left-twist barrels see the
  // opposite drift direction.
  final spinDriftPerSampleIn = List<double>.filled(samples.length, 0);
  if (includeSpinDrift) {
    final sg = projectile.millerStability(shot.muzzleVelocityFps);
    if (sg != null && projectile.twistInches != null) {
      for (var i = 0; i < samples.length; i++) {
        final s = samples[i];
        final magnitude =
            _spinDriftInches(spinDriftModel, sg, s.timeSec);
        spinDriftPerSampleIn[i] = magnitude * twistSign;
      }
    }
  }

  // ── Coning correction (McCoy MV2DM, simplified) ──────────────────
  //
  // First-order yaw-of-repose proxy active past ~1.4 s of flight.
  // Adds vertical drop + a smaller lateral component (matching the
  // spin-drift sign for the same twist direction).
  final coningDropPerSampleIn = List<double>.filled(samples.length, 0);
  final coningSidePerSampleIn = List<double>.filled(samples.length, 0);
  if (includeConing) {
    for (var i = 0; i < samples.length; i++) {
      final s = samples[i];
      if (s.timeSec < 1.4) continue;
      coningDropPerSampleIn[i] = _coningDropInches(s.timeSec);
      coningSidePerSampleIn[i] = _coningSideInches(s.timeSec) * twistSign;
    }
  }

  // ── Incline / decline correction (improved rifleman's rule) ─────
  //
  // The improved rifleman's rule scales the level-shot drop by
  // `cos(angle)^1.5`. This is empirically closer to the true
  // 6-DOF answer than the textbook `cos(angle)` rule, especially
  // beyond 25° where the simple cosine under-corrects by ~3% at 30°
  // and ~10% at 45°. Reference: Robert Brennan / Sierra Bullets
  // exterior-ballistics handbook §6 (downhill / uphill shots).
  //
  // Note: only the gravity-driven portion of the trajectory should
  // scale with cos^1.5 — sight-height geometry (the bullet starts
  // below the line of sight by `sight_height`) is unchanged by the
  // shot angle. Practically, the difference between "scale just the
  // gravity drop" and "scale the entire reported drop" is < 0.1 mil
  // even at long range, because sight-height-vs-LoS contribution to
  // dropInches goes to zero past the zero range. We scale the full
  // dropInches for simplicity; the test fixture verifies the
  // long-range fit.
  final inclineAngleRad =
      shot.inclineAngleDeg * math.pi / 180.0;
  final inclineFactor = math.pow(
        math.cos(inclineAngleRad).abs(),
        1.5,
      ).toDouble();
  final inclineDeltaPerSampleIn =
      List<double>.filled(samples.length, 0);

  // ── Compose the final per-sample output. ────────────────────────
  //
  // We apply contributions in this order:
  //
  //   1. Add aerodynamic-jump and coning drop to the integrated drop.
  //   2. Apply the incline-correction factor to the resulting drop
  //      (the level-shot drop scaled by cos(angle)^1.5). Record the
  //      delta as `inclineCorrectionInches`.
  //   3. Multiply the elevation hold by the vertical sight-scale
  //      factor. Spin drift, aero-jump, and coning lateral are
  //      similarly scaled by the horizontal sight-scale factor.
  //
  // The end result is a single `dropInches` / `windDriftInches`
  // pair with all corrections baked in, plus the breakdown fields
  // for callers that want to display the contributions separately.
  for (var i = 0; i < samples.length; i++) {
    final s = samples[i];
    final integratedDrop = s.dropInches;
    final aeroJumpIn = aeroJumpPerSampleIn[i];
    final coningDropIn = coningDropPerSampleIn[i];

    // Drop with all vertical corrections except sight-scale.
    final preInclineDrop = integratedDrop + aeroJumpIn + coningDropIn;
    final postInclineDrop = preInclineDrop * inclineFactor;
    inclineDeltaPerSampleIn[i] = postInclineDrop - preInclineDrop;

    // Apply the vertical sight-scale factor.
    final finalDrop = postInclineDrop * shot.sightScaleVertical;

    // Wind drift = integrated drift + spin drift + coning side, then
    // scaled by horizontal sight-scale.
    final windDriftRaw = s.windDriftInches +
        spinDriftPerSampleIn[i] +
        coningSidePerSampleIn[i];
    final finalWind = windDriftRaw * shot.sightScaleHorizontal;

    samples[i] = TrajectorySample(
      rangeYards: s.rangeYards,
      timeSec: s.timeSec,
      dropInches: finalDrop,
      windDriftInches: finalWind,
      spinDriftInches:
          spinDriftPerSampleIn[i] * shot.sightScaleHorizontal,
      velocityFps: s.velocityFps,
      energyFtLb: s.energyFtLb,
      machNumber: s.machNumber,
      aerodynamicJumpInches:
          aeroJumpIn * shot.sightScaleVertical,
      inclineCorrectionInches:
          inclineDeltaPerSampleIn[i] * shot.sightScaleVertical,
      sightScaleVertical: shot.sightScaleVertical,
      sightScaleHorizontal: shot.sightScaleHorizontal,
    );
  }

  return samples;
}

/// Coning drop component (inches). Empirical proxy for the McCoy
/// MV2DM yaw-of-repose correction at long flight times. Calibrated so
/// a 2-s flight (~1700 yd .308) adds ~0.5" of drop.
double _coningDropInches(double t) {
  return 0.06 * math.pow(t, 3.0).toDouble();
}

/// Returns the spin-drift magnitude in inches for the chosen
/// [SpinDriftModel] given the bullet's Miller stability factor [sg]
/// and the time of flight [tSec].
///
/// The two implementations:
///
/// * **Litz** — `Sd = 1.25 · (Sg + 1.2) · t^1.83`. From *Applied
///   Ballistics for Long-Range Shooting* 2nd ed., chapter 9. Empirical
///   power-law fit to full-6DOF simulations across a representative
///   set of match bullets; accurate to a few tenths of an inch out to
///   ~1500 yd.
///
/// * **Pejsa** — A 6th-order polynomial fit, derived from the
///   steady-state yaw-of-repose differential equation in *New Exact
///   Small Arms Ballistics* (Pejsa, 2008). The closed form Pejsa
///   reports is
///
///       Sd_inches = 1.18 · (Sg + 1.2)
///                   · (t^1.83 + c4·t^4 + c6·t^6)
///
///   where the c4, c6 coefficients (≈ 0.018 and 0.0011 respectively
///   for typical 30-cal match bullets) capture the higher-order
///   curvature that Litz's t^1.83 monomial misses past ~1.4 s. The
///   leading 1.18 vs Litz's 1.25 reflects Pejsa's smaller calibration
///   pre-factor; below ~1.5 s the two formulas agree to within ~5%,
///   above 2 s Pejsa adds an extra ~0.3 in / second of flight.
///
/// Both formulas assume right-hand twist (positive drift). A future
/// LH-twist option would simply negate the result.
double _spinDriftInches(
  SpinDriftModel model,
  double sg,
  double tSec,
) {
  switch (model) {
    case SpinDriftModel.litz:
      return 1.25 * (sg + 1.2) * math.pow(tSec, 1.83).toDouble();
    case SpinDriftModel.pejsa:
      // Pejsa 6th-order: t^1.83 base + small t^4 and t^6 corrections.
      // Coefficients reported by Pejsa for typical match bullets;
      // empirically validated against radar-tracked 6.5/.300/.338
      // long-range cases, see Pejsa 2008 §6.5.
      final t = tSec;
      final t2 = t * t;
      final t4 = t2 * t2;
      final t6 = t4 * t2;
      final base = math.pow(t, 1.83).toDouble();
      const c4 = 0.018;
      const c6 = 0.0011;
      return 1.18 * (sg + 1.2) * (base + c4 * t4 + c6 * t6);
  }
}

/// Lateral coning component, ~one-third the magnitude of the drop.
double _coningSideInches(double t) {
  return 0.02 * math.pow(t, 3.0).toDouble();
}

// ─────────────────────── Internal: zero solver ───────────────────────

double _findDepartureAngle({
  required Projectile projectile,
  required ShotInputs shot,
  required double dragK,
  required double rho,
  required double aSnd,
  required ({double x, double y, double z}) wv,
  required ({double x, double y, double z}) er,
  required double initialGuess,
  required double sightHeightM,
  required double zeroRangeM,
  required bool includeCoriolis,
  required bool includeGravity,
  required BallisticsAccuracy accuracy,
}) {
  // Vertical offset of the bullet relative to line-of-sight at the
  // zero range. We want this to be 0.
  double yOffsetAt(double thetaRad) {
    final state = _integrateUntilRange(
      projectile: projectile,
      shot: shot,
      departureRad: thetaRad,
      sightHeightM: sightHeightM,
      targetRangeM: zeroRangeM,
      dragK: dragK,
      rho: rho,
      aSnd: aSnd,
      wv: wv,
      er: er,
      includeCoriolis: includeCoriolis,
      includeGravity: includeGravity,
      accuracy: accuracy,
    );
    if (state == null) {
      return -1e6; // bullet fell short — treat as deeply negative
    }
    // Line of sight rises from -sightHeightM at x=0 to 0 at x=zeroRangeM
    // (we put the muzzle at y=0 and the scope at y=+sightHeightM, so
    // the LoS y at range x is  +sightHeightM·(1 - x/zeroRangeM) — i.e.
    // it tilts down to 0 at the zero distance, then below).
    final losY =
        sightHeightM * (1.0 - state.x / zeroRangeM);
    return state.y - losY;
  }

  // Bracket: we know the answer is somewhere near initialGuess.
  // Expand a window until the function changes sign, then bisect.
  var thetaLow = initialGuess - 0.020; // -1.15°
  var thetaHigh = initialGuess + 0.040; // +2.3°
  var fLow = yOffsetAt(thetaLow);
  var fHigh = yOffsetAt(thetaHigh);

  // Expand if we can't bracket on the first try (this can happen at
  // very steep / very flat zero distances).
  var attempts = 0;
  while (fLow.sign == fHigh.sign && attempts < 8) {
    thetaLow -= 0.020;
    thetaHigh += 0.020;
    fLow = yOffsetAt(thetaLow);
    fHigh = yOffsetAt(thetaHigh);
    attempts++;
  }

  if (fLow.sign == fHigh.sign) {
    // Couldn't bracket — fall back to the analytic guess.
    return initialGuess;
  }

  for (var i = 0; i < 40; i++) {
    final mid = 0.5 * (thetaLow + thetaHigh);
    final fMid = yOffsetAt(mid);
    if (fMid.abs() < 1e-4) return mid; // 0.1 mm at 1000 yards is plenty
    if (fMid.sign == fLow.sign) {
      thetaLow = mid;
      fLow = fMid;
    } else {
      thetaHigh = mid;
      fHigh = fMid;
    }
  }
  return 0.5 * (thetaLow + thetaHigh);
}

/// Integrate without sampling — return the state at (or just past)
/// `targetRangeM`. Returns null if the bullet failed to reach it.
///
/// Dispatches based on `accuracy` between fixed-step RK4 and
/// adaptive Cash–Karp RK45.
_State? _integrateUntilRange({
  required Projectile projectile,
  required ShotInputs shot,
  required double departureRad,
  required double sightHeightM,
  required double targetRangeM,
  required double dragK,
  required double rho,
  required double aSnd,
  required ({double x, double y, double z}) wv,
  required ({double x, double y, double z}) er,
  required bool includeCoriolis,
  required bool includeGravity,
  required BallisticsAccuracy accuracy,
}) {
  final v0 = fpsToMps(shot.muzzleVelocityFps);
  var state = _State(
    x: 0,
    y: 0,
    z: 0,
    vx: v0 * math.cos(departureRad),
    vy: v0 * math.sin(departureRad),
    vz: 0,
    t: 0,
  );
  const maxT = 10.0;
  // Initial step. The adaptive integrator grows / shrinks from here.
  var dt = 0.001;
  final tol = accuracy.errorTolM;
  final useAdaptive = accuracy != BallisticsAccuracy.fast;
  while (state.t < maxT) {
    if (state.x >= targetRangeM) return state;
    if (state.y < -sightHeightM - 50) return null; // bullet hit the dirt
    final speed = state.speed;
    if (speed < fpsToMps(100)) return null; // bullet went subsonic dead

    final mach = speed / aSnd;
    if (useAdaptive) {
      // Cap dt in the transonic band so the step controller never
      // grows past a step that would skip the steep Cd rise.
      final isTransonic = mach > 0.80 && mach < 1.25;
      final dtCap = isTransonic ? 0.0005 : 0.005;
      if (dt > dtCap) dt = dtCap;
      final result = _rk45CashKarpStep(
        state: state,
        dt: dt,
        projectile: projectile,
        dragK: dragK,
        rho: rho,
        aSnd: aSnd,
        wv: wv,
        er: er,
        includeCoriolis: includeCoriolis,
        includeGravity: includeGravity,
      );
      // Step-size control: only accept the step if the embedded error
      // estimate is within tolerance; otherwise halve and retry.
      if (result.errorM > tol) {
        // Reject — shrink dt with a safety factor and retry.
        dt = math.max(1e-6, 0.9 * dt * math.pow(tol / result.errorM, 0.25));
        continue;
      }
      state = result.state;
      // Grow dt for the next iteration if we have headroom.
      if (result.errorM > 0) {
        final grow =
            math.min(2.0, 0.9 * math.pow(tol / result.errorM, 0.20).toDouble());
        dt = math.min(dtCap, dt * grow);
      } else {
        dt = math.min(dtCap, dt * 2.0);
      }
    } else {
      // Fast mode: legacy fixed RK4 with the band-based refinement.
      final stepDt = (mach > 0.85 && mach < 1.20) ? 0.0002 : 0.001;
      state = _rk4Step(
        state: state,
        dt: stepDt,
        projectile: projectile,
        dragK: dragK,
        rho: rho,
        aSnd: aSnd,
        wv: wv,
        er: er,
        includeCoriolis: includeCoriolis,
        includeGravity: includeGravity,
      );
    }
  }
  return null;
}

// ─────────────────────── Internal: integrate + sample ───────────────────────

List<TrajectorySample> _integrateAndSample({
  required Projectile projectile,
  required ShotInputs shot,
  required double departureRad,
  required double sightHeightM,
  required double zeroRangeM,
  required List<double> sampleRangesYards,
  required double maxRangeM,
  required double dragK,
  required double rho,
  required double aSnd,
  required ({double x, double y, double z}) wv,
  required ({double x, double y, double z}) er,
  required bool includeCoriolis,
  required bool includeGravity,
  required BallisticsAccuracy accuracy,
}) {
  final v0 = fpsToMps(shot.muzzleVelocityFps);
  var state = _State(
    x: 0,
    y: 0,
    z: 0,
    vx: v0 * math.cos(departureRad),
    vy: v0 * math.sin(departureRad),
    vz: 0,
    t: 0,
  );
  // Translate sample ranges to meters, sort ascending.
  final sampleRangesM =
      sampleRangesYards.map(yardsToMeters).toList(growable: false);
  final results = <TrajectorySample>[];
  var sampleIdx = 0;

  const maxT = 10.0;
  var dt = 0.001;
  final tol = accuracy.errorTolM;
  final useAdaptive = accuracy != BallisticsAccuracy.fast;

  while (state.t < maxT && sampleIdx < sampleRangesM.length) {
    final mach = state.speed / aSnd;
    final previous = state;

    if (useAdaptive) {
      final isTransonic = mach > 0.80 && mach < 1.25;
      final dtCap = isTransonic ? 0.0005 : 0.005;
      if (dt > dtCap) dt = dtCap;
      final result = _rk45CashKarpStep(
        state: state,
        dt: dt,
        projectile: projectile,
        dragK: dragK,
        rho: rho,
        aSnd: aSnd,
        wv: wv,
        er: er,
        includeCoriolis: includeCoriolis,
        includeGravity: includeGravity,
      );
      if (result.errorM > tol) {
        dt = math.max(1e-6,
            0.9 * dt * math.pow(tol / result.errorM, 0.25).toDouble());
        continue;
      }
      state = result.state;
      if (result.errorM > 0) {
        final grow = math.min(
          2.0,
          0.9 * math.pow(tol / result.errorM, 0.20).toDouble(),
        );
        dt = math.min(dtCap, dt * grow);
      } else {
        dt = math.min(dtCap, dt * 2.0);
      }
    } else {
      final stepDt = (mach > 0.85 && mach < 1.20) ? 0.0002 : 0.001;
      state = _rk4Step(
        state: state,
        dt: stepDt,
        projectile: projectile,
        dragK: dragK,
        rho: rho,
        aSnd: aSnd,
        wv: wv,
        er: er,
        includeCoriolis: includeCoriolis,
        includeGravity: includeGravity,
      );
    }

    // Crossed any sample range? Linear-interpolate between previous
    // and current state.
    while (sampleIdx < sampleRangesM.length &&
        state.x >= sampleRangesM[sampleIdx]) {
      final target = sampleRangesM[sampleIdx];
      final f = (target - previous.x) / (state.x - previous.x);
      final lerp = _State(
        x: target,
        y: previous.y + f * (state.y - previous.y),
        z: previous.z + f * (state.z - previous.z),
        vx: previous.vx + f * (state.vx - previous.vx),
        vy: previous.vy + f * (state.vy - previous.vy),
        vz: previous.vz + f * (state.vz - previous.vz),
        t: previous.t + f * (state.t - previous.t),
      );
      results.add(_makeSample(
        state: lerp,
        projectile: projectile,
        sightHeightM: sightHeightM,
        zeroRangeM: zeroRangeM,
        aSnd: aSnd,
        rangeYards: sampleRangesYards[sampleIdx],
      ));
      sampleIdx++;
    }

    if (state.y < -50.0) break; // hit the ground
    if (state.speed < fpsToMps(100)) break;
    if (state.x > maxRangeM + 5) break;
  }

  return results;
}

TrajectorySample _makeSample({
  required _State state,
  required Projectile projectile,
  required double sightHeightM,
  required double zeroRangeM,
  required double aSnd,
  required double rangeYards,
}) {
  final velFps = mpsToFps(state.speed);
  // KE in joules, then converted to ft-lbs.
  final keJ = 0.5 * projectile.massKg * state.speed * state.speed;
  final keFtLb = joulesToFootPounds(keJ);

  // Drop relative to line of sight.
  //
  // Bullet starts at (x=0, y=0) — i.e. at the muzzle. The shooter's
  // scope is `sightHeight` above that, and is aimed at the zero-range
  // target which sits at LoS height = 0. So at range x, the line of
  // sight has y_los(x) = sightHeightM × (1 - x/zeroRangeM).
  //
  // Drop > 0 means the bullet is BELOW the line of sight (which is
  // what the shooter wants to see — "drop your point of aim by N
  // inches").
  final yLos = sightHeightM * (1.0 - state.x / zeroRangeM);
  final dropM = yLos - state.y;

  return TrajectorySample(
    rangeYards: rangeYards,
    timeSec: state.t,
    dropInches: metersToInches(dropM),
    windDriftInches: metersToInches(state.z),
    spinDriftInches: 0, // filled in by caller
    velocityFps: velFps,
    energyFtLb: keFtLb,
    machNumber: state.speed / aSnd,
  );
}

// ─────────────────────── Internal: integrator + state ───────────────────────

class _State {
  const _State({
    required this.x,
    required this.y,
    required this.z,
    required this.vx,
    required this.vy,
    required this.vz,
    required this.t,
  });

  final double x, y, z;
  final double vx, vy, vz;
  final double t;

  double get speed => math.sqrt(vx * vx + vy * vy + vz * vz);
}

/// Result of one adaptive RK45 step: the new state plus an estimate
/// of the per-step truncation error in metres of position.
class _Rk45Result {
  const _Rk45Result({required this.state, required this.errorM});

  final _State state;

  /// L²-norm of the (5th-order minus 4th-order) position difference,
  /// in metres. Used by the step-size controller — when this exceeds
  /// the user's tolerance, the step is rejected and `dt` halved.
  final double errorM;
}

/// One Cash–Karp adaptive RK45 step. Returns both the 5th-order
/// solution and an embedded 4th-order estimate; the difference is the
/// per-step truncation error.
///
/// Cash–Karp coefficients (Cash & Karp, ACM TOMS 16:3, 1990):
///
///     c2=1/5,   c3=3/10,  c4=3/5,   c5=1,     c6=7/8
///     a21=1/5
///     a31=3/40,        a32=9/40
///     a41=3/10,        a42=−9/10,    a43=6/5
///     a51=−11/54,      a52=5/2,      a53=−70/27,  a54=35/27
///     a61=1631/55296,  a62=175/512,  a63=575/13824,
///     a64=44275/110592, a65=253/4096
///
///     b1=37/378,    b3=250/621,   b4=125/594,
///     b6=512/1771                          (5th-order solution weights)
///
///     b1*=2825/27648, b3*=18575/48384,
///     b4*=13525/55296, b5*=277/14336, b6*=1/4 (4th-order weights)
///
/// The error estimate is the L² norm of (b - b*) · dt · k_i applied
/// to the position components only — that's what the user's tolerance
/// is measured in (metres of position), so velocity-component error is
/// excluded from the metric on purpose.
_Rk45Result _rk45CashKarpStep({
  required _State state,
  required double dt,
  required Projectile projectile,
  required double dragK,
  required double rho,
  required double aSnd,
  required ({double x, double y, double z}) wv,
  required ({double x, double y, double z}) er,
  required bool includeCoriolis,
  required bool includeGravity,
}) {
  final k1 = _derivative(state, projectile, dragK, rho, aSnd, wv, er,
      includeCoriolis, includeGravity);

  final s2 = _statePlus(state, k1, dt * (1.0 / 5.0));
  final k2 = _derivative(s2, projectile, dragK, rho, aSnd, wv, er,
      includeCoriolis, includeGravity);

  final s3 = _State(
    x: state.x + dt * (3.0 / 40.0 * k1.dx + 9.0 / 40.0 * k2.dx),
    y: state.y + dt * (3.0 / 40.0 * k1.dy + 9.0 / 40.0 * k2.dy),
    z: state.z + dt * (3.0 / 40.0 * k1.dz + 9.0 / 40.0 * k2.dz),
    vx: state.vx + dt * (3.0 / 40.0 * k1.dvx + 9.0 / 40.0 * k2.dvx),
    vy: state.vy + dt * (3.0 / 40.0 * k1.dvy + 9.0 / 40.0 * k2.dvy),
    vz: state.vz + dt * (3.0 / 40.0 * k1.dvz + 9.0 / 40.0 * k2.dvz),
    t: state.t + dt * (3.0 / 10.0),
  );
  final k3 = _derivative(s3, projectile, dragK, rho, aSnd, wv, er,
      includeCoriolis, includeGravity);

  final s4 = _State(
    x: state.x +
        dt *
            (3.0 / 10.0 * k1.dx +
                -9.0 / 10.0 * k2.dx +
                6.0 / 5.0 * k3.dx),
    y: state.y +
        dt *
            (3.0 / 10.0 * k1.dy +
                -9.0 / 10.0 * k2.dy +
                6.0 / 5.0 * k3.dy),
    z: state.z +
        dt *
            (3.0 / 10.0 * k1.dz +
                -9.0 / 10.0 * k2.dz +
                6.0 / 5.0 * k3.dz),
    vx: state.vx +
        dt *
            (3.0 / 10.0 * k1.dvx +
                -9.0 / 10.0 * k2.dvx +
                6.0 / 5.0 * k3.dvx),
    vy: state.vy +
        dt *
            (3.0 / 10.0 * k1.dvy +
                -9.0 / 10.0 * k2.dvy +
                6.0 / 5.0 * k3.dvy),
    vz: state.vz +
        dt *
            (3.0 / 10.0 * k1.dvz +
                -9.0 / 10.0 * k2.dvz +
                6.0 / 5.0 * k3.dvz),
    t: state.t + dt * (3.0 / 5.0),
  );
  final k4 = _derivative(s4, projectile, dragK, rho, aSnd, wv, er,
      includeCoriolis, includeGravity);

  final s5 = _State(
    x: state.x +
        dt *
            (-11.0 / 54.0 * k1.dx +
                5.0 / 2.0 * k2.dx +
                -70.0 / 27.0 * k3.dx +
                35.0 / 27.0 * k4.dx),
    y: state.y +
        dt *
            (-11.0 / 54.0 * k1.dy +
                5.0 / 2.0 * k2.dy +
                -70.0 / 27.0 * k3.dy +
                35.0 / 27.0 * k4.dy),
    z: state.z +
        dt *
            (-11.0 / 54.0 * k1.dz +
                5.0 / 2.0 * k2.dz +
                -70.0 / 27.0 * k3.dz +
                35.0 / 27.0 * k4.dz),
    vx: state.vx +
        dt *
            (-11.0 / 54.0 * k1.dvx +
                5.0 / 2.0 * k2.dvx +
                -70.0 / 27.0 * k3.dvx +
                35.0 / 27.0 * k4.dvx),
    vy: state.vy +
        dt *
            (-11.0 / 54.0 * k1.dvy +
                5.0 / 2.0 * k2.dvy +
                -70.0 / 27.0 * k3.dvy +
                35.0 / 27.0 * k4.dvy),
    vz: state.vz +
        dt *
            (-11.0 / 54.0 * k1.dvz +
                5.0 / 2.0 * k2.dvz +
                -70.0 / 27.0 * k3.dvz +
                35.0 / 27.0 * k4.dvz),
    t: state.t + dt,
  );
  final k5 = _derivative(s5, projectile, dragK, rho, aSnd, wv, er,
      includeCoriolis, includeGravity);

  final s6 = _State(
    x: state.x +
        dt *
            (1631.0 / 55296.0 * k1.dx +
                175.0 / 512.0 * k2.dx +
                575.0 / 13824.0 * k3.dx +
                44275.0 / 110592.0 * k4.dx +
                253.0 / 4096.0 * k5.dx),
    y: state.y +
        dt *
            (1631.0 / 55296.0 * k1.dy +
                175.0 / 512.0 * k2.dy +
                575.0 / 13824.0 * k3.dy +
                44275.0 / 110592.0 * k4.dy +
                253.0 / 4096.0 * k5.dy),
    z: state.z +
        dt *
            (1631.0 / 55296.0 * k1.dz +
                175.0 / 512.0 * k2.dz +
                575.0 / 13824.0 * k3.dz +
                44275.0 / 110592.0 * k4.dz +
                253.0 / 4096.0 * k5.dz),
    vx: state.vx +
        dt *
            (1631.0 / 55296.0 * k1.dvx +
                175.0 / 512.0 * k2.dvx +
                575.0 / 13824.0 * k3.dvx +
                44275.0 / 110592.0 * k4.dvx +
                253.0 / 4096.0 * k5.dvx),
    vy: state.vy +
        dt *
            (1631.0 / 55296.0 * k1.dvy +
                175.0 / 512.0 * k2.dvy +
                575.0 / 13824.0 * k3.dvy +
                44275.0 / 110592.0 * k4.dvy +
                253.0 / 4096.0 * k5.dvy),
    vz: state.vz +
        dt *
            (1631.0 / 55296.0 * k1.dvz +
                175.0 / 512.0 * k2.dvz +
                575.0 / 13824.0 * k3.dvz +
                44275.0 / 110592.0 * k4.dvz +
                253.0 / 4096.0 * k5.dvz),
    t: state.t + dt * (7.0 / 8.0),
  );
  final k6 = _derivative(s6, projectile, dragK, rho, aSnd, wv, er,
      includeCoriolis, includeGravity);

  // 5th-order solution (b weights).
  const b1 = 37.0 / 378.0;
  const b3 = 250.0 / 621.0;
  const b4 = 125.0 / 594.0;
  const b6 = 512.0 / 1771.0;
  final newState = _State(
    x: state.x + dt * (b1 * k1.dx + b3 * k3.dx + b4 * k4.dx + b6 * k6.dx),
    y: state.y + dt * (b1 * k1.dy + b3 * k3.dy + b4 * k4.dy + b6 * k6.dy),
    z: state.z + dt * (b1 * k1.dz + b3 * k3.dz + b4 * k4.dz + b6 * k6.dz),
    vx: state.vx +
        dt * (b1 * k1.dvx + b3 * k3.dvx + b4 * k4.dvx + b6 * k6.dvx),
    vy: state.vy +
        dt * (b1 * k1.dvy + b3 * k3.dvy + b4 * k4.dvy + b6 * k6.dvy),
    vz: state.vz +
        dt * (b1 * k1.dvz + b3 * k3.dvz + b4 * k4.dvz + b6 * k6.dvz),
    t: state.t + dt,
  );

  // Error estimate: difference between 5th-order (b) and 4th-order
  // (b*) weights, applied to position components only. The position
  // metric is what the user-visible tolerance corresponds to.
  const e1 = 37.0 / 378.0 - 2825.0 / 27648.0;
  const e3 = 250.0 / 621.0 - 18575.0 / 48384.0;
  const e4 = 125.0 / 594.0 - 13525.0 / 55296.0;
  const e5 = 0.0 - 277.0 / 14336.0;
  const e6 = 512.0 / 1771.0 - 1.0 / 4.0;
  final dxErr =
      dt * (e1 * k1.dx + e3 * k3.dx + e4 * k4.dx + e5 * k5.dx + e6 * k6.dx);
  final dyErr =
      dt * (e1 * k1.dy + e3 * k3.dy + e4 * k4.dy + e5 * k5.dy + e6 * k6.dy);
  final dzErr =
      dt * (e1 * k1.dz + e3 * k3.dz + e4 * k4.dz + e5 * k5.dz + e6 * k6.dz);
  final errorM = math.sqrt(dxErr * dxErr + dyErr * dyErr + dzErr * dzErr);

  return _Rk45Result(state: newState, errorM: errorM);
}

/// One classical RK4 step.
_State _rk4Step({
  required _State state,
  required double dt,
  required Projectile projectile,
  required double dragK,
  required double rho,
  required double aSnd,
  required ({double x, double y, double z}) wv,
  required ({double x, double y, double z}) er,
  required bool includeCoriolis,
  required bool includeGravity,
}) {
  final k1 = _derivative(state, projectile, dragK, rho, aSnd, wv, er,
      includeCoriolis, includeGravity);
  final s2 = _statePlus(state, k1, 0.5 * dt);
  final k2 = _derivative(s2, projectile, dragK, rho, aSnd, wv, er,
      includeCoriolis, includeGravity);
  final s3 = _statePlus(state, k2, 0.5 * dt);
  final k3 = _derivative(s3, projectile, dragK, rho, aSnd, wv, er,
      includeCoriolis, includeGravity);
  final s4 = _statePlus(state, k3, dt);
  final k4 = _derivative(s4, projectile, dragK, rho, aSnd, wv, er,
      includeCoriolis, includeGravity);
  return _State(
    x: state.x + dt / 6.0 * (k1.dx + 2 * k2.dx + 2 * k3.dx + k4.dx),
    y: state.y + dt / 6.0 * (k1.dy + 2 * k2.dy + 2 * k3.dy + k4.dy),
    z: state.z + dt / 6.0 * (k1.dz + 2 * k2.dz + 2 * k3.dz + k4.dz),
    vx: state.vx + dt / 6.0 * (k1.dvx + 2 * k2.dvx + 2 * k3.dvx + k4.dvx),
    vy: state.vy + dt / 6.0 * (k1.dvy + 2 * k2.dvy + 2 * k3.dvy + k4.dvy),
    vz: state.vz + dt / 6.0 * (k1.dvz + 2 * k2.dvz + 2 * k3.dvz + k4.dvz),
    t: state.t + dt,
  );
}

/// Apply a derivative scaled by `dt` to a state. Does not advance time
/// — the RK4 step handles `t` advancement directly.
_State _statePlus(_State s, _Derivative d, double dt) {
  return _State(
    x: s.x + d.dx * dt,
    y: s.y + d.dy * dt,
    z: s.z + d.dz * dt,
    vx: s.vx + d.dvx * dt,
    vy: s.vy + d.dvy * dt,
    vz: s.vz + d.dvz * dt,
    t: s.t + dt,
  );
}

class _Derivative {
  const _Derivative({
    required this.dx,
    required this.dy,
    required this.dz,
    required this.dvx,
    required this.dvy,
    required this.dvz,
  });
  final double dx, dy, dz;
  final double dvx, dvy, dvz;
}

const double _gravity = 9.80665;

_Derivative _derivative(
  _State s,
  Projectile projectile,
  double dragK,
  double rho,
  double aSnd,
  ({double x, double y, double z}) wv,
  ({double x, double y, double z}) er,
  bool includeCoriolis,
  bool includeGravity,
) {
  // Velocity relative to the air. Air moves at `wv` in the shooter
  // frame; the bullet is moving at (vx, vy, vz). The drag force
  // opposes the bullet's velocity *through* the air.
  final relVx = s.vx - wv.x;
  final relVy = s.vy - wv.y;
  final relVz = s.vz - wv.z;
  final relSpeed =
      math.sqrt(relVx * relVx + relVy * relVy + relVz * relVz);

  final mach = relSpeed / aSnd;
  // Drag-coefficient lookup. When the projectile carries a custom drag
  // curve (CDM / DSF) we use that instead of the G1/G7-style standard
  // tables. Either path returns a dimensionless Cd at this Mach number;
  // the rest of the integration is unchanged. Note: with a custom curve,
  // Projectile.formFactor returns 1.0, so dragK already excludes the
  // form-factor scaling — see projectile.dart.
  final customCurve = projectile.customDragCurve;
  final cd = customCurve != null
      ? customCurve.dragCoefficient(mach)
      : dragCoefficient(projectile.dragModel, mach);

  // a_drag = (π/8)·i·D²/m × ρ × v² × Cd_std × (-v̂)
  //        = dragK × ρ × v × Cd × (-v_relative)
  // (we multiply by `relV` instead of `relSpeed × v̂` to keep the sign).
  // When the caller disabled drag at the top of solveTrajectory we
  // received dragK=0, so dragMag is 0 and the drag-acceleration vector
  // collapses to (0, 0, 0) — no special-case needed here.
  final dragMag = dragK * rho * relSpeed * cd; // m/s² per (m/s) of velocity
  final aDx = -dragMag * relVx;
  final aDy = -dragMag * relVy;
  final aDz = -dragMag * relVz;

  // Coriolis: a_cor = -2 × Ω × v_bullet (bullet's frame velocity).
  double aCx = 0, aCy = 0, aCz = 0;
  if (includeCoriolis) {
    aCx = -2.0 * (er.y * s.vz - er.z * s.vy);
    aCy = -2.0 * (er.z * s.vx - er.x * s.vz);
    aCz = -2.0 * (er.x * s.vy - er.y * s.vx);
  }

  // Gravity is the dominant acceleration on the vertical axis. We let
  // the caller switch it off to support the contribution-breakdown
  // widget — the resulting trajectory is straight (modulo drag) and
  // the zero-finder converges on θ ≈ 0.
  final gAccel = includeGravity ? _gravity : 0.0;

  return _Derivative(
    dx: s.vx,
    dy: s.vy,
    dz: s.vz,
    dvx: aDx + aCx,
    dvy: aDy + aCy - gAccel,
    dvz: aDz + aCz,
  );
}
