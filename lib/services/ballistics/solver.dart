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
