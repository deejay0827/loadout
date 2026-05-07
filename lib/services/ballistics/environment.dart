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
