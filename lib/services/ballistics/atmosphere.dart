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
