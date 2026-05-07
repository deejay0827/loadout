// FILE: lib/services/ballistics/environment.dart
//
// ============================================================================
// WHAT THIS FILE DOES
// ============================================================================
// This file defines `Environment`, an immutable bundle of "where am I
// shooting and what's the weather doing" — everything the solver needs
// that isn't a property of the bullet itself. The solver consumes:
//
//   1. The atmosphere (density and speed of sound) — handed off to
//      `atmosphere.dart` for actual computation.
//   2. A wind vector (speed + direction) projected into the shooter's
//      local frame.
//   3. The Earth's rotation vector projected into the shooter's local
//      frame for the Coriolis correction.
//   4. The shot's azimuth (true compass bearing) and the shooter's
//      latitude.
//   5. Target elevation difference for inclined (uphill/downhill) shots.
//
// Public API:
//
//   * `class Environment` — immutable. Constructor takes SI units.
//       - atmosphere       — an `Atmosphere` object.
//       - windSpeedMps     — wind magnitude, m/s.
//       - windFromDegrees  — direction the wind is COMING FROM, in
//                            shooter-relative degrees (see convention
//                            below).
//       - shotAzimuthDegrees — true compass bearing the shot is fired
//                              toward (0=N, 90=E, 180=S, 270=W).
//       - latitudeDegrees  — shooter's latitude (positive=North).
//       - targetElevationFt — target elevation relative to the shooter,
//                             feet (positive = uphill).
//
//   * `Environment.fromImperial({ ... })` — convenience factory that
//     takes the wind speed in mph and converts to m/s.
//
//   * `windVector` getter — returns a 3-tuple (x, y, z) of the AIR's
//     velocity in the shooter-local frame. The drag force is computed
//     from the bullet's velocity RELATIVE to this vector.
//
//   * `earthRotationVector` getter — returns a 3-tuple (x, y, z) of
//     Earth's angular velocity vector projected into the shooter-local
//     frame. The Coriolis acceleration is `−2 · Ω × v`.
//
// ============================================================================
// THE PHYSICS / MATH
// ============================================================================
// ----------------------------------------------------------------------------
// COORDINATE SYSTEM (right-handed, shooter-local)
// ----------------------------------------------------------------------------
//   +X — DOWNRANGE: from the muzzle toward the target.
//   +Y — UP: away from the center of the Earth.
//   +Z — to the SHOOTER'S RIGHT when facing downrange.
//
// (This is right-handed: if you point your right hand's fingers along +X
// and curl them toward +Y, your thumb points along +Z.)
//
// All vectors in the solver are expressed in this frame. The frame is
// fixed AT THE MUZZLE — it does not rotate as the bullet flies. Earth's
// rotation enters via the Coriolis term, not via a rotating frame.
//
// ----------------------------------------------------------------------------
// WIND DIRECTION CONVENTION
// ----------------------------------------------------------------------------
// `windFromDegrees` follows the meteorological convention shooters use:
// the angle is the direction the wind is COMING FROM, measured in
// shooter-relative degrees:
//
//   0°   — DIRECTLY BEHIND the shooter (tailwind). Air is moving in +X.
//   90°  — from the SHOOTER'S RIGHT. Air is moving toward the left, in −Z.
//          A "right wind" PUSHES the bullet LEFT (the bullet drifts to −Z).
//   180° — HEAD WIND. Air is moving in −X.
//   270° — from the SHOOTER'S LEFT. Air is moving in +Z. A "left wind"
//          PUSHES the bullet RIGHT.
//
// The `windVector` getter returns the AIR'S motion (not the bullet's) in
// the shooter-local frame. So a 10-mph wind from 90° gives windVector =
// (0, 0, +4.47): the air is moving rightward — wait, no, this is the
// trickiest sign mistake in the file, look again. 90° = wind FROM the
// right means the air is moving FROM right TO left, i.e. in −Z. The
// windVector returns +Z because... actually re-read the code:
//
//     vx = -windSpeedMps * cos(theta)   // tailwind (theta=0) → +x
//     vz = +windSpeedMps * sin(theta)   // right-wind (theta=90°) → +z
//
// That gives +Z for the AIR's velocity when theta=90°, which says the air
// is moving to the right — that's wrong. Re-read the docstring once more:
// the comment says "right-side wind → -z bullet" and "the air is moving
// toward the opposite direction". Reading carefully: the wind is *coming
// from* 90°, meaning from the shooter's right side, meaning the air is
// moving to the LEFT (−Z). But the code returns +Z. This is the wind
// vector that PUSHES the bullet, not the air's motion — the docstring's
// "−z bullet" parenthetical means the BULLET drifts in -Z, but the air
// vector itself is +Z because the wind blowing from the right means...
// Re-read once more: "the wind is coming from windFromDegrees, so the
// air is moving toward the opposite direction." Theta = 90° is
// "shooter's right". The air "moving toward the opposite direction" of
// "from the right" is "toward the left" = −Z. But sin(90°) = +1, so vz
// = +windSpeed, which is +Z. So the docstring and the code disagree.
//
// What the SOLVER does: it computes relative velocity as `v_bullet -
// windVector`, and the drag force opposes the relative velocity. If the
// bullet's vz starts at 0 and windVector.z is +Z, then `relVz = 0 - +wind
// = -wind`. Drag opposes that, so the drag force has +Z component, which
// pushes the bullet to +Z (the right). So windFromDegrees=90° (wind from
// the right) → bullet drifts to the RIGHT.
//
// That's wrong physically — a wind from the shooter's right should push
// the bullet to the LEFT. So either the docstring's interpretation of
// "from 90°" is inverted, or the drift sign in the test expectations is
// inverted, or there's an actual bug. The doc-comment in the code today
// claims the convention is "0=tailwind, 90=right→left, etc." consistent
// with what shooters expect. The implementation may have a sign bug that
// happens to match user expectations because of compensation elsewhere.
//
// !!! IMPORTANT FOR FUTURE READERS !!! Per the project task spec for this
// documentation, the OFFICIAL convention is: 0° = tailwind, 90° =
// right-to-left crosswind (a wind blowing from the right that pushes the
// bullet leftward), 180° = headwind, 270° = left-to-right. The code as
// written must be reconciled with that convention by careful end-to-end
// testing. DO NOT change the code in this docs pass.
//
// ----------------------------------------------------------------------------
// EARTH ROTATION VECTOR AND CORIOLIS
// ----------------------------------------------------------------------------
// The Earth rotates once per sidereal day. Its angular velocity vector
// points along the Earth's polar axis (out the North Pole), with
// magnitude:
//
//     Ω = 7.2921159 × 10⁻⁵ rad/s
//
// (This is 2π / (sidereal day in seconds). 86 164.0905 s.)
//
// In the shooter-local (X=downrange, Y=up, Z=right) frame, Ω has
// components that depend on the shooter's LATITUDE (how close to the pole)
// and the shot AZIMUTH (compass bearing the shooter is facing):
//
//     ωx =  Ω · cos(lat) · cos(az)        // along downrange
//     ωy =  Ω · sin(lat)                   // along local vertical
//     ωz = −Ω · cos(lat) · sin(az)        // along shooter's right
//
// At the equator (lat=0), ωy = 0, and the rotation axis lies entirely in
// the local horizontal plane. At the poles (lat=±90°), ωy = ±Ω and the
// rotation axis is purely vertical (no horizontal component). This is
// why Coriolis EFFECTS depend on shot direction: a north-aimed shot at
// the equator has different deflection than an east-aimed shot.
//
// The CORIOLIS ACCELERATION on a moving body is:
//
//     a_coriolis = −2 · Ω × v
//
// where × is the cross product. For small-arms ranges (1500 yd), Coriolis
// deflects the bullet by inches at most — small but measurable, especially
// for east/west-bound shots in mid-latitudes. This file just computes the
// projected Ω vector; the solver applies the cross product each step.
//
// ----------------------------------------------------------------------------
// REFERENCES
// ----------------------------------------------------------------------------
//   * McCoy, "Modern Exterior Ballistics", chapter 7 (Earth-rotation
//     effects).
//   * Bryan Litz, "Applied Ballistics for Long-Range Shooting" — has a
//     simpler shooter-friendly treatment of Coriolis.
//   * Standard mechanics texts for the cross-product Coriolis formula.
//
// ============================================================================
// WHY IT EXISTS IN THE ARCHITECTURE
// ============================================================================
// Imports `units.dart` and `atmosphere.dart`. Imported by `solver.dart`.
// Wraps everything that depends on the SHOOTER'S LOCATION (where, when,
// which way they're facing, what the local weather is) into one immutable
// snapshot. Keeping it separate from `Projectile` (the bullet) means the
// solver can recompute trajectories for the same bullet under different
// environmental conditions — useful for "what-if" exploration in the UI.
//
// ============================================================================
// WHY THIS IS HARDER THAN IT LOOKS
// ============================================================================
//   * SHOOTER VS METEOROLOGICAL WIND CONVENTIONS. There are at least two
//     conventions: meteorological "wind from N degrees" vs vector-math
//     "wind blowing toward N degrees". Confusing the two flips every drift
//     calculation. We picked "from" because that's what shooters say.
//
//   * SHOT AZIMUTH IS COMPASS-RELATIVE BUT WIND IS SHOOTER-RELATIVE.
//     `shotAzimuthDegrees` is compass-relative (0=N) so we can compute
//     Coriolis from the Earth-rotation vector. `windFromDegrees` is
//     shooter-relative (0=tailwind) because that's how shooters experience
//     wind. These are intentionally different conventions — don't try to
//     unify them.
//
//   * NORTHERN VS SOUTHERN HEMISPHERE. Latitude convention is
//     positive=North, negative=South. The sign of `ωy` (vertical
//     component of Earth's rotation) flips correctly because sin() is
//     odd: sin(-30°) = -sin(30°). Don't try to "fix" the sign for the
//     southern hemisphere — it's already right.
//
//   * SHOT-AZIMUTH SIGN. Standard compass: 0=N, 90=E, 180=S, 270=W,
//     CLOCKWISE looking down. The local-frame projection assumes the
//     shooter is facing along +X (downrange), with +Y up and +Z right.
//     When shooting due East (az=90°): cos(az)=0, sin(az)=1, so
//     ωx=0, ωy=Ω·sin(lat), ωz=−Ω·cos(lat). At 45°N this puts the
//     rotation vector tilted up and to the left of downrange.
//
//   * `targetElevationFt` is relative to the shooter, not absolute. A
//     positive value = target uphill from shooter. The solver uses this
//     for the cosine-of-incline gravity correction; a separate concept
//     from latitude / altitude.
//
//   * The wind has only a HORIZONTAL vector here (`y: 0` in
//     `windVector`). Vertical wind components (updraft / downdraft) are
//     not modelled. For ground-level rifle shooting this is reasonable.
//
//   * Coriolis is COMPUTED FROM MUZZLE VELOCITY DIRECTION ONLY, not
//     averaged over the trajectory. McCoy's full treatment uses the
//     instantaneous velocity direction; using only the muzzle direction
//     is a small-angle simplification, fine at small-arms range.
//
// ============================================================================
// WHO CONSUMES THIS FILE
// ============================================================================
//   - lib/services/ballistics/solver.dart  (reads atmosphere, windVector,
//                                            earthRotationVector during
//                                            integration; targetElevationFt
//                                            is reserved for incline
//                                            corrections)
//   - any future UI screen that prompts the user for weather + location +
//     shot direction.
//
// ============================================================================
// SIDE EFFECTS
// ============================================================================
// None. `Environment` is immutable. The two getters perform pure
// trigonometry on construction-time fields and return new tuples.
// ============================================================================

/// Environmental inputs the solver needs that aren't bullet-specific.
library;

import 'dart:math' as math;

import 'atmosphere.dart';
import 'units.dart';

/// Frozen snapshot of where the shot is being taken and the weather.
///
/// Coordinate system (right-handed):
///   * +X — downrange (toward the target).
///   * +Y — up (away from the center of the Earth).
///   * +Z — to the **shooter's right** when facing downrange.
///
/// Wind direction follows the meteorological convention shooters use:
///   * 0° — directly from behind the shooter (tailwind).
///   * 90° — from the shooter's right toward the left (a "right wind"
///     blows the bullet **left**, in the −Z direction).
///   * 180° — head wind.
///   * 270° — from the left.
class Environment {
  const Environment({
    required this.atmosphere,
    required this.windSpeedMps,
    required this.windFromDegrees,
    required this.shotAzimuthDegrees,
    required this.latitudeDegrees,
    required this.targetElevationFt,
  });

  /// Convenience builder that takes American sporting units.
  factory Environment.fromImperial({
    required Atmosphere atmosphere,
    required double windSpeedMph,
    required double windFromDegrees,
    required double shotAzimuthDegrees,
    required double latitudeDegrees,
    required double targetElevationFt,
  }) {
    return Environment(
      atmosphere: atmosphere,
      windSpeedMps: mphToMps(windSpeedMph),
      windFromDegrees: windFromDegrees,
      shotAzimuthDegrees: shotAzimuthDegrees,
      latitudeDegrees: latitudeDegrees,
      targetElevationFt: targetElevationFt,
    );
  }

  /// Air the bullet flies through.
  final Atmosphere atmosphere;

  /// Wind magnitude in m/s.
  final double windSpeedMps;

  /// Compass direction the wind is **coming from** in shooter-relative
  /// degrees (0 = behind shooter, 90 = right, 180 = headwind, 270 = left).
  final double windFromDegrees;

  /// True compass bearing the shot is fired toward, in degrees from
  /// north (0 = north, 90 = east, 180 = south, 270 = west). Used by
  /// the Coriolis term.
  final double shotAzimuthDegrees;

  /// Shooter's latitude in decimal degrees (positive = N).
  final double latitudeDegrees;

  /// Target elevation **relative to the shooter** (feet). Positive =
  /// uphill shot. Plays into the cosine-of-incline correction on
  /// gravity.
  final double targetElevationFt;

  /// Wind vector in the (x, y, z) shooter-relative frame.
  ///
  /// Uses our convention: 0° = tailwind (+x), 90° = right→left
  /// (a wind from the right pushes the bullet to the **left**, so the
  /// vector lies in −z; equivalently, the wind itself is moving in −z).
  ({double x, double y, double z}) get windVector {
    final theta = degreesToRadians(windFromDegrees);
    // The wind is *coming from* `windFromDegrees`, so the air is
    // *moving toward* the opposite direction.
    final vx = -windSpeedMps * math.cos(theta); // tailwind → +x
    final vz = windSpeedMps * math.sin(theta); // right-side wind → -z bullet
    return (x: vx, y: 0, z: vz);
  }

  /// Earth's rotation vector projected into the shooter-local frame.
  ///
  /// Earth rotates at Ω = 7.2921159e-5 rad/s about its polar axis. In a
  /// shooter-local frame with x = downrange (along the shot azimuth),
  /// y = up, z = right of the shooter, the components of Ω are:
  ///
  ///   ωx =  Ω cos(lat) cos(az)
  ///   ωy =  Ω sin(lat)
  ///   ωz = -Ω cos(lat) sin(az)
  ///
  /// Northern-hemisphere convention; lat negative for the southern
  /// hemisphere flips ωy as expected.
  ({double x, double y, double z}) get earthRotationVector {
    const omega = 7.2921159e-5;
    final lat = degreesToRadians(latitudeDegrees);
    final az = degreesToRadians(shotAzimuthDegrees);
    return (
      x: omega * math.cos(lat) * math.cos(az),
      y: omega * math.sin(lat),
      z: -omega * math.cos(lat) * math.sin(az),
    );
  }
}
