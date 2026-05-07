// FILE: lib/services/ballistics/atmosphere.dart
//
// ============================================================================
// WHAT THIS FILE DOES
// ============================================================================
// This file models the air the bullet flies through. The solver only needs
// two scalars from the atmosphere:
//
//   1. `density` — air density in kg/m³. Air is heavier (denser) at sea
//      level, in cold weather, at high pressure, and when dry. Density
//      directly scales the drag force on the bullet.
//
//   2. `speedOfSound` — the local speed of sound in m/s. The bullet's
//      velocity divided by this value gives its MACH NUMBER, which is the
//      index into the drag function lookup table (see drag_functions.dart).
//
// Public API:
//
//   * `class IcaoStd` — a holder for sea-level reference constants from the
//     International Civil Aviation Organization (ICAO) Standard Atmosphere:
//       - seaLevelTempK = 288.15  (15.0 °C)
//       - seaLevelPressurePa = 101 325 Pa  (1 atm = 1013.25 hPa)
//       - seaLevelDensity = 1.225 kg/m³
//       - seaLevelSpeedOfSound = 340.294 m/s  (~1116.45 fps)
//       - lapseRateKPerM = 0.0065 K/m  (temperature drops 6.5 K per km of
//         elevation up to ~11 km)
//       - rDryAir = 287.058 J/(kg·K)  (specific gas constant for dry air)
//       - rWaterVapor = 461.495 J/(kg·K)  (specific gas constant for H₂O)
//       - gammaDryAir = 1.4  (ratio of specific heats Cp/Cv for diatomic gas)
//       - g0 = 9.80665 m/s²  (standard gravity)
//
//   * `class Atmosphere` — an immutable snapshot of air conditions:
//       - density, speedOfSound, temperatureK, pressurePa, relativeHumidity
//       - `mach(velocityMps)` — convert m/s to Mach number.
//       - `densityAltitudeFt` — return the equivalent ICAO altitude that
//         has this same density.
//
//   * Three constructors:
//       - `Atmosphere.icaoStd()` — sea-level reference, useful for testing.
//       - `Atmosphere.station({ tempF, stationPressureInHg, humidityPct,
//         altitudeFt })` — build from a real weather report.
//       - `Atmosphere.fromAltitudeFt(altitudeFt)` — fall back to ICAO
//         standard at the given altitude (no humidity, no temperature
//         deviation from standard).
//
// ============================================================================
// THE PHYSICS / MATH
// ============================================================================
// ----------------------------------------------------------------------------
// AIR DENSITY: ρ = P / (R · T)
// ----------------------------------------------------------------------------
// The ideal gas law says density (mass/volume) scales linearly with
// pressure and inversely with absolute temperature:
//
//     ρ = P / (R · T)
//
// where R is the SPECIFIC gas constant of the gas (different for dry air
// vs water vapor) and T is in Kelvin. So:
//
//   * Higher pressure (low elevation, fair weather) → denser air → MORE
//     drag on the bullet.
//   * Higher temperature (hot day) → thinner air → LESS drag.
//   * Higher humidity → slightly thinner air, because water vapor
//     (molecular mass 18) is lighter than dry air (effective mass 29).
//     This is counter-intuitive — humid air is thinner!
//
// For HUMID air, we treat the air as a mixture of two ideal gases (dry air
// + water vapor) by Dalton's law of partial pressures:
//
//     P_total = P_dry + P_vapor
//
// and the density of the mixture is the sum of the partial densities:
//
//     ρ = P_dry / (R_dry · T) + P_vapor / (R_vapor · T)
//
// The vapor partial pressure is computed from relative humidity and the
// SATURATION vapor pressure (the maximum amount of vapor air can hold at
// that temperature). We use the TETENS formula:
//
//     P_sat = 610.78 · exp(17.27 · T_C / (T_C + 237.3))    [Pa]
//
// where T_C is in Celsius. Tetens is accurate to about 0.5% across the
// temperature range a shooter cares about (-30°C to +50°C). Magnus is a
// near-equivalent alternative; we picked Tetens for its simpler form.
// Then P_vapor = (relative_humidity / 100) · P_sat.
//
// ----------------------------------------------------------------------------
// DENSITY ALTITUDE
// ----------------------------------------------------------------------------
// "Density altitude" is a single-number summary of "how thin is the air for
// ballistic purposes": it's the altitude in the ICAO standard atmosphere
// that has the same density as the current air. Hot + humid + high
// elevation = high density altitude = thinner air = LESS drag = bullet
// drops less and drifts less. A 95°F summer day at 5000 ft elevation can
// have a density altitude of 8000+ ft.
//
// The `densityAltitudeFt` getter inverts the standard-atmosphere density
// formula to recover the equivalent altitude. Useful as a one-number
// summary on the trajectory output card.
//
// ----------------------------------------------------------------------------
// SPEED OF SOUND: c = sqrt(γ · R · T)
// ----------------------------------------------------------------------------
// The speed of sound in an ideal gas depends only on temperature (in K) to
// first order:
//
//     c = sqrt(γ · R · T)
//
// where γ (gamma) = 1.4 is the ratio of specific heats Cp/Cv for diatomic
// gases, R is the specific gas constant, and T is absolute temperature.
//
// At 15°C (sea level, standard) this gives c = 340.294 m/s, or ~1116 fps.
// At -10°C: ~325 m/s. At +35°C: ~352 m/s. So the bullet's Mach number
// changes ~8% just from temperature variation across reasonable shooting
// conditions, even though its velocity is identical.
//
// Humidity has a small effect: the effective gas constant of moist air is
// slightly higher than dry air (water vapor has a higher specific R), and
// γ is slightly lower. Net effect: humid air conducts sound slightly
// faster — but the magnitude is below 0.5% even at 100% RH and 100°F. We
// approximate by adjusting only R via:
//
//     R_eff = R_dry · (1 + 0.61 · q)
//
// where q is specific humidity (mass of vapor / mass of moist air). The
// 0.61 factor is the standard meteorological approximation.
//
// ----------------------------------------------------------------------------
// ICAO STANDARD ATMOSPHERE (used by `fromAltitudeFt`)
// ----------------------------------------------------------------------------
// Below 11 km (the troposphere) the standard atmosphere assumes
// temperature decreases linearly with altitude:
//
//     T(h) = T_0 − L · h           (L = lapse rate = 6.5 K/km)
//
// and pressure follows from hydrostatic equilibrium of the ideal gas:
//
//     P(h) / P_0 = (T(h) / T_0)^(g / (R · L))
//
// Density then drops out of P = ρ R T. This gives a single-parameter model
// of the atmosphere that's accurate enough for ballistics when only
// altitude is known.
//
// ----------------------------------------------------------------------------
// REFERENCES
// ----------------------------------------------------------------------------
//   * U.S. Standard Atmosphere 1976 (effectively identical to ICAO ISA up
//     to 32 km).
//   * Bryan Litz, "Applied Ballistics for Long-Range Shooting", chapter 7
//     (atmospheric effects).
//   * Picard, Davis, Gläser, Fujii (2008), "Revised formula for the
//     density of moist air".
//
// ============================================================================
// WHY IT EXISTS IN THE ARCHITECTURE
// ============================================================================
// Imports `units.dart` only. Imported by `environment.dart` (which holds an
// `Atmosphere` plus wind / Coriolis info) and the solver. Splitting it out
// from `Environment` lets us:
//
//   1. Compute density and speed of sound once, freeze them, and re-use
//      them across thousands of integration steps without recomputing.
//   2. Test atmospheric math in isolation — easy comparison against
//      published density-altitude calculators.
//   3. Reuse the same `Atmosphere` instance across multiple solver runs
//      with different bullets / wind conditions.
//
// ============================================================================
// WHY THIS IS HARDER THAN IT LOOKS
// ============================================================================
//   * STATION VS SEA-LEVEL CORRECTED PRESSURE. This is the single biggest
//     source of user error. Most consumer weather apps and TV forecasts
//     report sea-level CORRECTED pressure (~30 inHg almost everywhere on
//     Earth at sea-level conditions). The solver wants the actual
//     barometric reading at the firing position. At 5000 ft elevation,
//     true station pressure is ~24.9 inHg while sea-level corrected is
//     ~30. Plugging the corrected value into `Atmosphere.station` will
//     compute air density as if the user is at sea level, which
//     under-predicts drop and drift at altitude. The doc-comment on the
//     `stationPressureInHg` parameter warns about this; the safer path
//     for users without a barometer is `Atmosphere.fromAltitudeFt`.
//
//   * Humidity over-correction: the dry-air formula already gives most of
//     the answer. Forgetting humidity entirely costs <0.5% in density at
//     normal shooting conditions. Don't expect humidity sliders to make a
//     huge difference at typical ranges.
//
//   * Unit gotchas: `tempF` is Fahrenheit, `tempK` (internal) is Kelvin.
//     The Tetens formula needs Celsius. Conversion `tK − 273.15`.
//
//   * The lapse-rate formula breaks down above the tropopause (~11 km).
//     Above that, temperature is roughly constant or rises through the
//     stratosphere. We don't expect small-arms shooters at those altitudes,
//     but `fromAltitudeFt` would return wrong answers above ~36 000 ft.
//
//   * Density altitude assumes the standard atmosphere is the reference.
//     Reporting "density altitude = 8000 ft" tells the user the air is as
//     thin as standard 8000 ft, regardless of where they actually are.
//
//   * The constructor parameter `altitudeFt` on `Atmosphere.station` is a
//     no-op for the math (it's there for diagnostic display) — the density
//     calculation is purely from station pressure and temperature.
//
// ============================================================================
// WHO CONSUMES THIS FILE
// ============================================================================
//   - lib/services/ballistics/environment.dart (holds an Atmosphere)
//   - lib/services/ballistics/solver.dart      (reads density and
//                                                speedOfSound from
//                                                environment.atmosphere
//                                                during integration)
//   - any future UI screen that wants to display density altitude.
//
// ============================================================================
// SIDE EFFECTS
// ============================================================================
// None. `Atmosphere` is immutable after construction. All math is local.
// ============================================================================

/// ICAO Standard Atmosphere model + density-altitude helpers.
///
/// The solver wants two scalars from the atmosphere:
///
///   * `density` (kg/m³) — used in the drag force.
///   * `speedOfSound` (m/s) — used to convert velocity into Mach number,
///     which indexes the drag function table.
///
/// Both follow from temperature, pressure, and humidity. We implement:
///
///   * the **ICAO standard atmosphere** to give a reference density at
///     altitude (used internally and as a sanity check);
///   * a corrected **density** from station temperature, station
///     barometric pressure (uncorrected for altitude), and relative
///     humidity using the Magnus / Tetens water-vapor pressure formula
///     and Dalton's law for the dry-air portion;
///   * a **speed of sound** from absolute temperature and humidity
///     (humid air has a slightly lower γ and lower R_specific because
///     water vapor is lighter than dry air — but the effect is small,
///     <0.5% even at 100% RH and 100°F).
///
/// Sources:
/// * U.S. Standard Atmosphere 1976 (≈ICAO ISA up to 32 km).
/// * Bryan Litz, *Applied Ballistics for Long-Range Shooting*, ch. 7.
/// * Picard, Davis, Gläser, Fujii (2008) for humid-air density.
library;

import 'dart:math' as math;

import 'units.dart';

/// Sea-level ICAO standard atmosphere conditions.
class IcaoStd {
  IcaoStd._();

  /// 15.0 °C in Kelvin.
  static const double seaLevelTempK = 288.15;

  /// 1013.25 hPa in Pascals.
  static const double seaLevelPressurePa = 101_325.0;

  /// Standard sea-level dry-air density (kg/m³).
  static const double seaLevelDensity = 1.225;

  /// Standard sea-level speed of sound (m/s) → ~1116.45 fps.
  static const double seaLevelSpeedOfSound = 340.294;

  /// Temperature lapse rate, 0–11 km of the troposphere (K/m).
  static const double lapseRateKPerM = 0.0065;

  /// Specific gas constant for dry air (J / kg / K).
  static const double rDryAir = 287.058;

  /// Specific gas constant for water vapor (J / kg / K).
  static const double rWaterVapor = 461.495;

  /// Ratio of specific heats for dry air.
  static const double gammaDryAir = 1.4;

  /// Standard gravity (m/s²).
  static const double g0 = 9.80665;
}

/// A frozen snapshot of the air the bullet is flying through.
class Atmosphere {
  /// Construct an [Atmosphere] from absolute SI quantities.
  /// Most callers will use [Atmosphere.station] instead.
  const Atmosphere({
    required this.density,
    required this.speedOfSound,
    required this.temperatureK,
    required this.pressurePa,
    required this.relativeHumidity,
  });

  /// Sea-level ICAO standard atmosphere. Useful as a default and for
  /// validation against published reference solutions.
  factory Atmosphere.icaoStd() {
    return const Atmosphere(
      density: IcaoStd.seaLevelDensity,
      speedOfSound: IcaoStd.seaLevelSpeedOfSound,
      temperatureK: IcaoStd.seaLevelTempK,
      pressurePa: IcaoStd.seaLevelPressurePa,
      relativeHumidity: 0.0,
    );
  }

  /// Compute density and speed of sound from a station weather report.
  ///
  /// * [tempF] — station temperature, °F.
  /// * [stationPressureInHg] — *uncorrected* station barometric
  ///   pressure (the absolute reading), inches of mercury. Most
  ///   weather apps report **sea-level corrected** pressure, which is
  ///   wrong here; either use a true station pressure or use
  ///   [Atmosphere.fromAltitudeFt] instead.
  /// * [humidityPct] — relative humidity, 0–100.
  /// * [altitudeFt] — station elevation, feet AMSL. Only used as a
  ///   sanity-check; the density math works directly from pressure and
  ///   temperature, so altitude does not feed into the calculation when
  ///   `stationPressureInHg` is the true barometric reading.
  factory Atmosphere.station({
    required double tempF,
    required double stationPressureInHg,
    required double humidityPct,
    double altitudeFt = 0,
  }) {
    final tK = fToK(tempF);
    final pPa = inHgToPa(stationPressureInHg);
    final rh = (humidityPct.clamp(0.0, 100.0)) / 100.0;

    // Saturation vapor pressure (Pa) via Tetens equation. Accurate to
    // about 0.5% across normal shooting temperatures.
    final tC = tK - 273.15;
    final pSat = 610.78 * math.exp((17.27 * tC) / (tC + 237.3));
    final pVapor = rh * pSat;
    final pDry = pPa - pVapor;

    // Ideal gas: ρ = P/(R T) for each component, summed.
    final density = pDry / (IcaoStd.rDryAir * tK) +
        pVapor / (IcaoStd.rWaterVapor * tK);

    // Speed of sound in humid air. We approximate with the dry-air
    // formula c = sqrt(γ R T) and apply a small humidity correction.
    // The error on ignoring humidity entirely is <0.5%; we pick up
    // most of it by adjusting the effective gas constant.
    //
    // Effective R = R_dry × (1 + 0.61 × q) where q is specific humidity
    // (mass of vapor / mass of moist air).
    final q = pVapor / (pVapor + pDry) *
        (IcaoStd.rDryAir / IcaoStd.rWaterVapor);
    final rEff = IcaoStd.rDryAir * (1.0 + 0.61 * q);
    final speedOfSound = math.sqrt(IcaoStd.gammaDryAir * rEff * tK);

    return Atmosphere(
      density: density,
      speedOfSound: speedOfSound,
      temperatureK: tK,
      pressurePa: pPa,
      relativeHumidity: rh,
    );
  }

  /// Return the ICAO standard atmosphere at the given altitude (feet).
  /// Useful when only altitude is known.
  factory Atmosphere.fromAltitudeFt(double altitudeFt) {
    final h = feetToMeters(altitudeFt);
    final tK = IcaoStd.seaLevelTempK - IcaoStd.lapseRateKPerM * h;
    // Hydrostatic / lapse-rate formula.
    final pressureRatio = math.pow(
      tK / IcaoStd.seaLevelTempK,
      IcaoStd.g0 / (IcaoStd.rDryAir * IcaoStd.lapseRateKPerM),
    ).toDouble();
    final pPa = IcaoStd.seaLevelPressurePa * pressureRatio;
    final density = pPa / (IcaoStd.rDryAir * tK);
    final speedOfSound =
        math.sqrt(IcaoStd.gammaDryAir * IcaoStd.rDryAir * tK);
    return Atmosphere(
      density: density,
      speedOfSound: speedOfSound,
      temperatureK: tK,
      pressurePa: pPa,
      relativeHumidity: 0.0,
    );
  }

  /// Air density at the firing point (kg/m³).
  final double density;

  /// Local speed of sound (m/s).
  final double speedOfSound;

  /// Absolute temperature (K).
  final double temperatureK;

  /// Absolute station pressure (Pa).
  final double pressurePa;

  /// Relative humidity, 0–1.
  final double relativeHumidity;

  /// Mach number for [velocityMps].
  double mach(double velocityMps) => velocityMps / speedOfSound;

  /// Density-altitude estimate (feet AMSL) — the altitude in the ICAO
  /// standard atmosphere that has the same density as this snapshot.
  /// Useful for displaying a simple summary of the atmospheric impact.
  double get densityAltitudeFt {
    // Invert the standard-atmosphere density formula.
    //
    //   ρ/ρ0 = (T/T0)^(g/RL - 1)
    //
    // where T = T0 - L h, so:
    //
    //   T/T0 = (ρ/ρ0)^(1 / (g/RL - 1))
    //
    // and h = (T0 - T)/L.
    final exponent =
        IcaoStd.g0 / (IcaoStd.rDryAir * IcaoStd.lapseRateKPerM) - 1.0;
    final tRatio = math.pow(density / IcaoStd.seaLevelDensity, 1.0 / exponent);
    final tK = IcaoStd.seaLevelTempK * tRatio;
    final hMeters = (IcaoStd.seaLevelTempK - tK) / IcaoStd.lapseRateKPerM;
    return metersToFeet(hMeters);
  }
}
