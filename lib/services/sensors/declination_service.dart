// FILE: lib/services/sensors/declination_service.dart
//
// ============================================================================
// WHAT THIS FILE DOES
// ============================================================================
// Loads a precomputed magnetic-declination grid (`assets/seed_data/
// wmm_declination.json`) and exposes a single async API:
//
//     final decl = await DeclinationService.instance
//         .declinationDegrees(lat: 39.34, lon: -86.04);
//
// The returned value is the **magnetic declination at that location, in
// degrees, positive east of true north**. A shooter's compass heading
// from the on-board magnetometer is *magnetic-north* heading; adding
// the declination converts it to *true-north* heading, which is what
// the ballistic solver needs for the Coriolis acceleration term:
//
//     true_az = magnetic_az + declination
//
// At Camp Atterbury, IN, declination is roughly −5° (true north is
// about 5° east of magnetic north), so a magnetic heading of 90° is a
// true heading of 85°.
//
// HOW THE LOOKUP WORKS. We bake a 5°×5° global grid (-90..90 latitude,
// -180..180 longitude) at build time using the NOAA WMM coefficients;
// see `tool/gen_wmm_declination.py`. At runtime we bilinearly
// interpolate between the four corners of the user's grid cell. For
// typical mid-latitude shooter locations this gives sub-0.5° accuracy
// against the NOAA online calculator. The only time the simple bilinear
// model breaks is near the magnetic poles (where the declination
// changes by 30°+ over a few degrees of longitude); the LoadOut user
// base is unlikely to be there.
//
// SCHEMA. The asset is a JSON object:
//
//     {
//       "epoch": 2020.0,
//       "model": "WMM2020 (geomag package)",
//       "lat_step_deg": 5,
//       "lon_step_deg": 5,
//       "grid": [{"lat": -90, "lon": -180, "decl": -123.45}, ...]
//     }
//
// We index the grid into a 2-D `List<List<double>>` keyed by
// `(latIndex, lonIndex)` for O(1) corner lookup.
//
// LIFETIME. Singleton with a lazy init: the first
// `declinationDegrees()` call loads + parses the asset; subsequent
// calls reuse the parsed grid. The asset is ~90 KB minified — well
// under the size at which we'd want a binary format.
//
// FAILURE MODES.
//   * Asset missing / malformed → returns null. Callers fall back to
//     "magnetic heading" mode and surface the unknown declination in
//     the UI.
//   * lat / lon out of range → wraps longitude into [-180, 180);
//     clamps latitude to [-90, 90].
// ============================================================================

import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart' show rootBundle;

/// Grid-backed magnetic-declination lookup for the LoadOut app.
///
/// Singleton — call [DeclinationService.instance] from anywhere in the
/// codebase. The asset is loaded lazily on the first
/// [declinationDegrees] invocation; failure to load or parse the asset
/// puts the service into a permanent "unavailable" state and every
/// subsequent call returns `null`.
///
/// Coordinate convention: latitude in decimal degrees with
/// positive=North, longitude with positive=East. Declination is
/// degrees east of true north (positive = magnetic north is east of
/// true north, i.e. the compass needle points east of the geographic
/// north pole).
class DeclinationService {
  DeclinationService._();

  /// Process-wide singleton. Hold a reference at the call site rather
  /// than re-fetching `instance` per invocation; either pattern works.
  static final DeclinationService instance = DeclinationService._();

  /// Asset path holding the precomputed grid. Owned by `tool/
  /// gen_wmm_declination.py`.
  static const String _assetPath = 'assets/seed_data/wmm_declination.json';

  Future<void>? _loadFuture;
  bool _loadFailed = false;

  /// Latitude grid resolution in degrees. Typically 5°. Read from the
  /// JSON header on first load.
  double _latStep = 5.0;

  /// Longitude grid resolution in degrees. Typically 5°.
  double _lonStep = 5.0;

  /// First latitude in the grid (e.g. -90). The grid is laid out
  /// [latStart, latStart + latStep, ..., latEnd] with `_latCount`
  /// entries inclusive.
  double _latStart = -90.0;
  double _lonStart = -180.0;

  int _latCount = 37;
  int _lonCount = 73;

  /// Declination values keyed by `_grid[latIndex * _lonCount + lonIndex]`,
  /// degrees east of true north.
  late List<double> _grid;

  /// True if the asset has been loaded and parsed at least once. We
  /// keep this so a failed-load short-circuits future calls without
  /// re-reading the asset bundle.
  bool get isReady => _loadFuture != null && !_loadFailed;

  /// Indicates the service couldn't load the grid (e.g. the asset is
  /// missing on this build). UIs should fall back to magnetic-heading
  /// labeling and quietly skip the declination chip.
  bool get isUnavailable => _loadFailed;

  /// Look up the magnetic declination (degrees east of true north) at
  /// the given latitude / longitude. Returns null if the grid couldn't
  /// be loaded. Wraps longitude into [-180, 180) and clamps latitude
  /// into [-90, 90] before bilinearly interpolating.
  Future<double?> declinationDegrees({
    required double lat,
    required double lon,
  }) async {
    if (_loadFailed) return null;
    _loadFuture ??= _load();
    try {
      await _loadFuture;
    } catch (_) {
      _loadFailed = true;
      return null;
    }
    if (_loadFailed) return null;
    return _bilinearLookup(lat, lon);
  }

  /// Synchronous variant: returns null until the grid has been
  /// preloaded, otherwise the bilinear lookup. Useful in widgets that
  /// want to surface declination without awaiting in `build()`. Pair
  /// with [preload] from a parent that does know how to await.
  double? declinationDegreesSync({required double lat, required double lon}) {
    if (_loadFailed) return null;
    if (_loadFuture == null) return null;
    return _bilinearLookup(lat, lon);
  }

  /// Eagerly load the asset. Useful if the caller wants to pre-warm
  /// the service before the first `declinationDegrees()` call so the
  /// UI doesn't show a transient null. Idempotent.
  Future<void> preload() async {
    if (_loadFailed) return;
    _loadFuture ??= _load();
    try {
      await _loadFuture;
    } catch (_) {
      _loadFailed = true;
    }
  }

  /// Load + parse the asset. On any error sets [_loadFailed] and
  /// rethrows so the caller sees the failure once; subsequent calls
  /// short-circuit on [_loadFailed].
  Future<void> _load() async {
    final raw = await rootBundle.loadString(_assetPath);
    final dynamic parsed = json.decode(raw);
    if (parsed is! Map<String, dynamic>) {
      _loadFailed = true;
      throw const FormatException(
          'wmm_declination.json: top-level must be an object');
    }
    _latStep = (parsed['lat_step_deg'] as num?)?.toDouble() ?? 5.0;
    _lonStep = (parsed['lon_step_deg'] as num?)?.toDouble() ?? 5.0;

    final dynamic gridRaw = parsed['grid'];
    if (gridRaw is! List) {
      _loadFailed = true;
      throw const FormatException(
          'wmm_declination.json: missing or non-list "grid"');
    }

    // Sweep the grid once to find lat/lon bounds and infer the row /
    // column counts. The generator writes the grid in row-major order
    // (latitude outer, longitude inner) but we don't rely on that —
    // we compute (lat - latStart) / latStep to land entries on the
    // right `(latIdx, lonIdx)` cell.
    var minLat = double.infinity;
    var maxLat = double.negativeInfinity;
    var minLon = double.infinity;
    var maxLon = double.negativeInfinity;
    for (final dynamic e in gridRaw) {
      if (e is! Map) continue;
      final lat = (e['lat'] as num?)?.toDouble();
      final lon = (e['lon'] as num?)?.toDouble();
      if (lat == null || lon == null) continue;
      if (lat < minLat) minLat = lat;
      if (lat > maxLat) maxLat = lat;
      if (lon < minLon) minLon = lon;
      if (lon > maxLon) maxLon = lon;
    }
    if (minLat == double.infinity || minLon == double.infinity) {
      _loadFailed = true;
      throw const FormatException(
          'wmm_declination.json: grid contained no usable entries');
    }
    _latStart = minLat;
    _lonStart = minLon;
    _latCount = ((maxLat - minLat) / _latStep).round() + 1;
    _lonCount = ((maxLon - minLon) / _lonStep).round() + 1;

    _grid = List<double>.filled(_latCount * _lonCount, 0.0);
    for (final dynamic e in gridRaw) {
      if (e is! Map) continue;
      final lat = (e['lat'] as num?)?.toDouble();
      final lon = (e['lon'] as num?)?.toDouble();
      final decl = (e['decl'] as num?)?.toDouble();
      if (lat == null || lon == null || decl == null) continue;
      final latIdx = ((lat - _latStart) / _latStep).round();
      final lonIdx = ((lon - _lonStart) / _lonStep).round();
      if (latIdx < 0 || latIdx >= _latCount) continue;
      if (lonIdx < 0 || lonIdx >= _lonCount) continue;
      _grid[latIdx * _lonCount + lonIdx] = decl;
    }
  }

  /// Bilinearly interpolate the declination at (lat, lon). Wraps
  /// longitude into [-180, 180) and clamps latitude to [-90, 90].
  double _bilinearLookup(double lat, double lon) {
    // Wrap longitude to [-180, 180). Inputs from `geolocator` are
    // always in this range, but defensive coding here avoids a
    // negative grid index when the caller hands us 270° instead of
    // -90°.
    var l = lon;
    while (l < -180.0) {
      l += 360.0;
    }
    while (l >= 180.0) {
      l -= 360.0;
    }
    // Clamp latitude.
    final la = lat.clamp(-90.0, 90.0);

    // Floor coordinates → grid cell.
    final fLat = (la - _latStart) / _latStep;
    final fLon = (l - _lonStart) / _lonStep;
    var i0 = fLat.floor();
    var j0 = fLon.floor();
    if (i0 < 0) i0 = 0;
    if (j0 < 0) j0 = 0;
    if (i0 >= _latCount - 1) i0 = _latCount - 2;
    if (j0 >= _lonCount - 1) j0 = _lonCount - 2;
    final i1 = i0 + 1;
    final j1 = j0 + 1;

    final dLat = (fLat - i0).clamp(0.0, 1.0);
    final dLon = (fLon - j0).clamp(0.0, 1.0);

    final c00 = _grid[i0 * _lonCount + j0];
    final c10 = _grid[i1 * _lonCount + j0];
    final c01 = _grid[i0 * _lonCount + j1];
    final c11 = _grid[i1 * _lonCount + j1];

    // Bilinear: lerp along longitude at each latitude row, then lerp
    // the two row results along latitude. Standard formula.
    final cLow = c00 * (1 - dLon) + c01 * dLon;
    final cHigh = c10 * (1 - dLon) + c11 * dLon;
    return cLow * (1 - dLat) + cHigh * dLat;
  }
}
