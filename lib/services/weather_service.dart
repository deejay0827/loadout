// FILE: lib/services/weather_service.dart
//
// ============================================================================
// WHAT THIS FILE DOES
// ============================================================================
// Pulls "right now" weather observations for the ballistics calculator's
// Environment section. The flow is:
//
//   1. Ask the OS for the user's coarse location, prompting for the
//      `WhenInUse` permission if it isn't already granted.
//   2. Call open-meteo.com's free `/v1/forecast` endpoint with the
//      lat/lon, asking for current temperature, station pressure,
//      humidity, wind speed, wind direction, and elevation.
//   3. Convert units where open-meteo's response disagrees with the
//      ballistics solver's expected units, then return a typed
//      [WeatherFetchResult] to the caller.
//
// open-meteo is the right pick for this feature because:
//   - It requires no API key and no signup (the privacy posture for
//     LoadOut is "your reloading data never leaves the device" — we
//     can keep that promise here because the only thing we send to
//     open-meteo is coarse lat/lon, with no LoadOut-side server).
//   - Its free tier covers the per-user fetch volume this app would
//     ever generate.
//   - It exposes BOTH `pressure_msl` (sea-level corrected, which is
//     what most weather apps display) AND `surface_pressure` (the
//     actual pressure at the reporting station's elevation, which is
//     what the external-ballistics solver wants). LoadOut's
//     Environment section labels its pressure field "Pressure (inHg)
//     — station, not corrected", and the solver downstream
//     [Atmosphere.station] takes station pressure straight in. We
//     ALWAYS want `surface_pressure` here. Feeding sea-level pressure
//     into the solver at altitude silently produces wrong drops.
//
// ============================================================================
// WHY IT EXISTS IN THE ARCHITECTURE
// ============================================================================
// The Pro upgrade for the Ballistics screen makes "Use my location"
// available as a one-tap fill of the Environment section. Centralizing
// the fetch + permission handshake here keeps the ballistics screen
// free of network code, isolates the units-conversion gotchas in one
// place, and makes the service trivially mockable when a unit test
// needs a deterministic environment.
//
// ============================================================================
// WHO CONSUMES THIS FILE
// ============================================================================
// - lib/screens/ballistics/ballistics_screen.dart — the cloud icon in
//   the Environment section's header calls
//   [WeatherService.fetchForCurrentLocation] when tapped.
//
// ============================================================================
// SIDE EFFECTS
// ============================================================================
// - Triggers an OS-level location permission prompt on first call (and
//   on any subsequent call where the user previously denied without
//   "Don't ask again"). The user's lat/lon never leaves their device
//   except as the URL query parameters of the open-meteo request, and
//   nothing is persisted anywhere — the result is in-memory only.
// - Performs a single HTTPS GET against api.open-meteo.com.

import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:geolocator/geolocator.dart';
import 'package:http/http.dart' as http;

/// Conversion factor: 1 inHg ≈ 33.8639 hPa. Used to coerce
/// open-meteo's `surface_pressure` (returned in hPa even when the
/// query asks for inHg — the unit hint applies to MSL pressure only)
/// into the inHg the ballistics solver expects.
const double _kHpaPerInHg = 33.8639;

/// Conversion factor: 1 metre ≈ 3.28084 feet. open-meteo always
/// returns elevation in metres regardless of unit-hint parameters.
const double _kFeetPerMetre = 3.28084;

/// Convert sea-level pressure to station pressure given the station's
/// altitude in feet and ambient temperature in °F.
///
/// Uses the standard barometric formula approximation
/// `station = sea_level × (1 - altitude_ft / 145366.45)^5.255`. The
/// (1 − altitude / scale-height) form is the truncated barometric
/// equation valid up to a few thousand metres — plenty for any
/// shooting position. Temperature isn't part of the formula because
/// the standard atmosphere already builds in a 6.5 °C/km lapse rate;
/// we accept the parameter so callers don't have to plumb it into a
/// future temperature-corrected variant separately.
///
/// Returns inHg when called with inHg input, mbar when called with
/// mbar input — the relation is unitless. Negative or zero altitude
/// returns the input unchanged.
double seaLevelToStationPressure(
  double seaLevelPressure,
  double altitudeFt,
) {
  if (altitudeFt <= 0) return seaLevelPressure;
  final altitudeRatio = 1.0 - altitudeFt / 145366.45;
  if (altitudeRatio <= 0) return seaLevelPressure;
  // Use math.pow with explicit double to avoid integer-promotion bugs.
  return seaLevelPressure * math.pow(altitudeRatio, 5.255).toDouble();
}

/// Result of a single weather lookup. All fields are in the
/// imperial units the ballistics screen / solver expects.
class WeatherFetchResult {
  const WeatherFetchResult({
    required this.tempF,
    required this.stationPressureInHg,
    required this.humidityPct,
    required this.elevationFt,
    required this.windSpeedMph,
    required this.windDirectionDeg,
    required this.fetchedAt,
  });

  /// Temperature at 2m above ground, °F.
  final double tempF;

  /// Station (surface) pressure, inHg. NOT corrected to mean sea level
  /// — this is the value the external ballistics solver wants.
  final double stationPressureInHg;

  /// Relative humidity at 2m, percent (0–100).
  final double humidityPct;

  /// Reporting station's surface elevation, feet above mean sea level.
  final double elevationFt;

  /// Wind speed at 10m, mph.
  final double windSpeedMph;

  /// Direction the wind is coming FROM, degrees clockwise from north.
  /// 0 = north, 90 = east, etc. Same convention as a weather report
  /// and as the ballistics screen's "Wind from (°)" field.
  final double windDirectionDeg;

  /// Wall-clock time the fetch completed. Used by the UI for the
  /// "Updated 2:34 PM" subtitle.
  final DateTime fetchedAt;
}

/// Generic failure surfaced to the UI. The screen shows the
/// [userMessage] verbatim in a snackbar — keep it short and friendly.
class WeatherFetchException implements Exception {
  const WeatherFetchException(this.userMessage, {this.cause});

  /// Friendly, end-user-readable message. The Ballistics screen
  /// displays this as-is in a [SnackBar].
  final String userMessage;

  /// Underlying error (if any) — kept for diagnostics; never shown to
  /// the user.
  final Object? cause;

  @override
  String toString() =>
      'WeatherFetchException($userMessage)${cause == null ? '' : ' caused by $cause'}';
}

/// Network + permission-handshake wrapper around open-meteo's free
/// forecast endpoint. Stateless; spin up a fresh instance per call.
class WeatherService {
  WeatherService({http.Client? httpClient}) : _client = httpClient ?? http.Client();

  final http.Client _client;

  /// Base URL of the open-meteo current-conditions endpoint. Documented
  /// at https://open-meteo.com/en/docs.
  static const String _baseUrl = 'https://api.open-meteo.com/v1/forecast';

  /// Default network-level timeout for the open-meteo call. Long
  /// enough to handle a slow LTE link, short enough that a stuck
  /// request doesn't lock the spinner forever.
  static const Duration _httpTimeout = Duration(seconds: 12);

  /// Resolves the device's current location, calls open-meteo, and
  /// returns the parsed [WeatherFetchResult]. Throws
  /// [WeatherFetchException] with a user-friendly message on any
  /// failure path (permission, service-disabled, network, parse).
  Future<WeatherFetchResult> fetchForCurrentLocation() async {
    final position = await _resolvePosition();
    final uri = Uri.parse(_baseUrl).replace(queryParameters: <String, String>{
      'latitude': position.latitude.toStringAsFixed(4),
      'longitude': position.longitude.toStringAsFixed(4),
      // Note: pressure_msl + surface_pressure are both requested. We
      // use surface_pressure (station) downstream; pressure_msl is
      // included only so open-meteo applies the inHg unit hint
      // somewhere — surface_pressure itself comes back in hPa.
      'current': 'temperature_2m,relative_humidity_2m,pressure_msl,'
          'surface_pressure,wind_speed_10m,wind_direction_10m',
      'temperature_unit': 'fahrenheit',
      'wind_speed_unit': 'mph',
      'precipitation_unit': 'inch',
      'pressure_unit': 'inHg',
    });

    final http.Response response;
    try {
      response = await _client.get(uri).timeout(_httpTimeout);
    } on TimeoutException catch (e) {
      throw WeatherFetchException(
        'Couldn\'t reach the weather service. Try again later.',
        cause: e,
      );
    } catch (e) {
      throw WeatherFetchException(
        'Couldn\'t reach the weather service. Try again later.',
        cause: e,
      );
    }

    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw WeatherFetchException(
        'Couldn\'t reach the weather service. Try again later.',
        cause: 'HTTP ${response.statusCode}',
      );
    }

    return _parse(response.body, position);
  }

  /// Permission + service-enabled handshake. Returns a fresh
  /// [Position] or throws a [WeatherFetchException] tagged with the
  /// failure mode.
  Future<Position> _resolvePosition() async {
    final bool serviceEnabled;
    try {
      serviceEnabled = await Geolocator.isLocationServiceEnabled();
    } catch (e) {
      throw WeatherFetchException(
        'Location is turned off on this device.',
        cause: e,
      );
    }
    if (!serviceEnabled) {
      throw const WeatherFetchException(
          'Location is turned off on this device.');
    }

    LocationPermission permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
    }
    if (permission == LocationPermission.deniedForever ||
        permission == LocationPermission.denied) {
      throw const WeatherFetchException(
          'Location permission required. Enable it in Settings.');
    }

    try {
      // Coarse-grained location is sufficient for weather; using
      // [LocationAccuracy.medium] keeps the GPS fix latency reasonable
      // and respects the user's privacy expectations (they didn't
      // ask for pinpoint accuracy).
      return await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.medium,
          timeLimit: Duration(seconds: 15),
        ),
      );
    } catch (e) {
      throw WeatherFetchException(
        'Couldn\'t determine your location. Try again outdoors.',
        cause: e,
      );
    }
  }

  /// Parse open-meteo's JSON payload into a [WeatherFetchResult],
  /// applying the unit conversions the ballistics solver expects.
  WeatherFetchResult _parse(String body, Position position) {
    final Map<String, dynamic> root;
    try {
      root = json.decode(body) as Map<String, dynamic>;
    } catch (e) {
      throw WeatherFetchException(
        'Weather service returned an unexpected response.',
        cause: e,
      );
    }

    final current = root['current'];
    if (current is! Map<String, dynamic>) {
      throw const WeatherFetchException(
          'Weather service returned an unexpected response.');
    }
    final units = root['current_units'];
    final unitsMap = units is Map<String, dynamic> ? units : const <String, dynamic>{};

    final tempF = _asDouble(current['temperature_2m']);
    final humidity = _asDouble(current['relative_humidity_2m']);
    final windMph = _asDouble(current['wind_speed_10m']);
    final windDir = _asDouble(current['wind_direction_10m']);
    final elevationMetres = _asDouble(root['elevation']);
    final elevationFt = elevationMetres * _kFeetPerMetre;

    // open-meteo's `surface_pressure` ignores `pressure_unit` and is
    // returned in hPa — verify against the units block but always
    // assume hPa unless the units block explicitly says inHg. When
    // the field is absent (rare — typically only at obscure marine
    // grid points) we fall back to converting `pressure_msl` to
    // station pressure via the standard atmosphere formula using the
    // station altitude reported by open-meteo.
    final surfacePressureUnit =
        (unitsMap['surface_pressure'] as String?)?.toLowerCase().trim();
    double stationPressureInHg;
    final surfaceVal = current['surface_pressure'];
    if (surfaceVal != null) {
      final raw = _asDouble(surfaceVal);
      stationPressureInHg = surfacePressureUnit == 'inhg'
          ? raw
          : raw / _kHpaPerInHg;
    } else {
      // Fallback: derive station pressure from sea-level pressure using
      // the station's altitude. open-meteo always returns
      // `pressure_msl` so this branch is reliable when surface_pressure
      // is missing.
      final mslRaw = _asDouble(current['pressure_msl']);
      final mslUnit =
          (unitsMap['pressure_msl'] as String?)?.toLowerCase().trim();
      final mslInHg =
          mslUnit == 'inhg' ? mslRaw : mslRaw / _kHpaPerInHg;
      stationPressureInHg =
          seaLevelToStationPressure(mslInHg, elevationFt);
    }

    return WeatherFetchResult(
      tempF: tempF,
      stationPressureInHg: stationPressureInHg,
      humidityPct: humidity.clamp(0, 100).toDouble(),
      elevationFt: elevationFt,
      windSpeedMph: windMph,
      windDirectionDeg: ((windDir % 360) + 360) % 360,
      fetchedAt: DateTime.now(),
    );
  }

  /// Coerce a JSON value to double. open-meteo sometimes returns
  /// integers (e.g. `humidity: 50`) and sometimes doubles
  /// (`temperature: 71.4`); both must round-trip cleanly.
  double _asDouble(Object? value) {
    if (value is num) return value.toDouble();
    if (value is String) {
      final parsed = double.tryParse(value);
      if (parsed != null) return parsed;
    }
    throw const WeatherFetchException(
        'Weather service returned an unexpected response.');
  }
}
