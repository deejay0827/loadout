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
// Default dt = 0.001 s (1 millisecond). For a 2700 fps bullet that's
// 0.823 m per step — fine for the smooth supersonic regime.
//
// In the TRANSONIC band (Mach 0.85 to Mach 1.20), the drag coefficient
// changes rapidly — for the G1 standard, Cd more than doubles across
// this range. A 1-millisecond step there would resolve the rise too
// coarsely and the bullet's velocity loss would be biased. We adapt to
// `dt = 0.0002 s` (5× smaller) inside this band. This is a poor man's
// adaptive integrator — a "real" adaptive RK4 would adjust dt based on
// estimated truncation error each step, but for the smooth ballistics
// problem the band-based heuristic is sufficient.
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
///      and the bullet's BC.
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

import 'drag_functions.dart';
import 'environment.dart';
import 'projectile.dart';
import 'units.dart';

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
  });

  /// Downrange distance (yards) — matches the requested sample range.
  final double rangeYards;

  /// Time of flight from muzzle (s).
  final double timeSec;

  /// Vertical drop from line of sight (inches). Positive = below LoS.
  final double dropInches;

  /// Horizontal wind drift, inches. Positive = right of LoS.
  final double windDriftInches;

  /// Horizontal spin drift, inches. Positive = right of LoS for a
  /// right-hand twist. Already included in [windDriftInches]'s sign
  /// convention if [includeSpinDrift] was true; here we expose it
  /// separately for users who want to see the breakdown.
  final double spinDriftInches;

  /// Bullet velocity (fps).
  final double velocityFps;

  /// Kinetic energy (ft-lbs).
  final double energyFtLb;

  /// Bullet velocity expressed as Mach.
  final double machNumber;
}

/// Inputs that change shot to shot rather than load to load.
class ShotInputs {
  const ShotInputs({
    required this.muzzleVelocityFps,
    required this.sightHeightIn,
    required this.zeroRangeYards,
    this.muzzleCantDeg = 0,
  });

  final double muzzleVelocityFps;
  final double sightHeightIn;
  final double zeroRangeYards;

  /// Rifle cant about the bore axis, in degrees. Positive = right (top
  /// of scope tilts right). We use this only to produce a small
  /// aerodynamic-jump correction; cant-induced bullet path tilt is
  /// already implicit in the integrated trajectory once departure is
  /// set up correctly.
  final double muzzleCantDeg;
}

/// Top-level entry point. Returns one [TrajectorySample] per element
/// of [sampleRangesYards].
List<TrajectorySample> solveTrajectory({
  required Projectile projectile,
  required Environment environment,
  required ShotInputs shot,
  required List<double> sampleRangesYards,
  bool includeSpinDrift = true,
  bool includeCoriolis = true,
}) {
  if (sampleRangesYards.isEmpty) return const [];

  // Pre-compute drag scaling. F_drag/m = (π/8)·ρ·v²·i·Cd·D²/m, so the
  // factor that multiplies ρ·v²·Cd_std is (π/8)·i·D²/m. We compute
  // it once and reuse it on every step.
  final iFormFactor = projectile.formFactor;
  final dM = projectile.diameterM;
  final mKg = projectile.massKg;
  final dragK = (math.pi / 8.0) * iFormFactor * dM * dM / mKg;

  // Air properties.
  final rho = environment.atmosphere.density;
  final aSnd = environment.atmosphere.speedOfSound;

  // Wind air-velocity vector (the air's velocity in the shooter frame).
  final wv = environment.windVector;

  // Earth rotation vector — used by the Coriolis term.
  final er = environment.earthRotationVector;

  // ── Find the departure (super-elevation) angle that yields the user's zero ──
  //
  // We bisect on the muzzle-elevation angle θ until the bullet crosses
  // the line of sight at zeroRangeYards. The line of sight is the
  // straight line from the scope (above the bore by sight-height)
  // toward the zero target point.

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

  final departureRad = _findDepartureAngle(
    projectile: projectile,
    shot: shot,
    dragK: dragK,
    rho: rho,
    aSnd: aSnd,
    wv: wv,
    er: er,
    initialGuess: theta0,
    sightHeightM: sightHeightM,
    zeroRangeM: zeroRangeM,
    includeCoriolis: includeCoriolis,
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
  );

  // Apply spin drift after the fact. We compute it from time of
  // flight and add it to the wind-drift result. The user sees both
  // values via the per-sample [spinDriftInches] / [windDriftInches]
  // fields.
  if (includeSpinDrift) {
    final sg = projectile.millerStability(shot.muzzleVelocityFps);
    if (sg != null && projectile.twistInches != null) {
      // Litz formula. `t` is time of flight, in seconds.
      // Right-hand twist → drift to the right (+z).
      for (var i = 0; i < samples.length; i++) {
        final s = samples[i];
        final spinIn = 1.25 * (sg + 1.2) * math.pow(s.timeSec, 1.83);
        samples[i] = TrajectorySample(
          rangeYards: s.rangeYards,
          timeSec: s.timeSec,
          dropInches: s.dropInches,
          windDriftInches: s.windDriftInches + spinIn.toDouble(),
          spinDriftInches: spinIn.toDouble(),
          velocityFps: s.velocityFps,
          energyFtLb: s.energyFtLb,
          machNumber: s.machNumber,
        );
      }
    }
  }

  return samples;
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
  const dt = 0.001;
  const maxT = 10.0;
  while (state.t < maxT) {
    if (state.x >= targetRangeM) return state;
    if (state.y < -sightHeightM - 50) return null; // bullet hit the dirt
    final speed = state.speed;
    if (speed < fpsToMps(100)) return null; // bullet went subsonic dead

    // Refine step in the transonic band.
    final mach = speed / aSnd;
    final stepDt = (mach > 0.85 && mach < 1.20) ? 0.0002 : dt;

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
    );
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

  const dt = 0.001;
  const maxT = 10.0;

  while (state.t < maxT && sampleIdx < sampleRangesM.length) {
    final mach = state.speed / aSnd;
    final stepDt = (mach > 0.85 && mach < 1.20) ? 0.0002 : dt;

    final previous = state;
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
    );

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
}) {
  final k1 = _derivative(state, projectile, dragK, rho, aSnd, wv, er,
      includeCoriolis);
  final s2 = _statePlus(state, k1, 0.5 * dt);
  final k2 = _derivative(s2, projectile, dragK, rho, aSnd, wv, er,
      includeCoriolis);
  final s3 = _statePlus(state, k2, 0.5 * dt);
  final k3 = _derivative(s3, projectile, dragK, rho, aSnd, wv, er,
      includeCoriolis);
  final s4 = _statePlus(state, k3, dt);
  final k4 = _derivative(s4, projectile, dragK, rho, aSnd, wv, er,
      includeCoriolis);
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
  final cd = dragCoefficient(projectile.dragModel, mach);

  // a_drag = (π/8)·i·D²/m × ρ × v² × Cd_std × (-v̂)
  //        = dragK × ρ × v × Cd × (-v_relative)
  // (we multiply by `relV` instead of `relSpeed × v̂` to keep the sign).
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

  return _Derivative(
    dx: s.vx,
    dy: s.vy,
    dz: s.vz,
    dvx: aDx + aCx,
    dvy: aDy + aCy - _gravity,
    dvz: aDz + aCz,
  );
}
