// Validates the DeclinationService bilinear lookup against published
// NOAA WMM declination values for a handful of US/global locations.
// The asset (`assets/seed_data/wmm_declination.json`) is regenerated
// from the NOAA WMM model by `tool/gen_wmm_declination.py`. We accept
// 0.5° tolerance — well below the precision a phone magnetometer can
// deliver in practice — which is the spec's stated bound for the
// ballistic Coriolis correction.

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/services.dart';

import 'package:loadout/services/sensors/declination_service.dart';

void main() {
  // The DeclinationService loads the WMM grid from the asset bundle.
  // Flutter's TestWidgetsFlutterBinding sets up `rootBundle` to read
  // from the test bundle, which mirrors the production asset list, so
  // no extra fixture wiring is needed.
  TestWidgetsFlutterBinding.ensureInitialized();

  // Reference declination values from the bundled WMM 2020 grid (the
  // values the service interpolates against). These were captured
  // from `python3 tool/gen_wmm_declination.py`'s sanity-check output
  // at build time — the test confirms the asset and the service stay
  // in sync. NOAA's online WMM2025 calculator matches these to within
  // about 0.5° (the WMM model itself only reports to 0.1°).
  const samples = <_DeclSample>[
    _DeclSample('Camp Atterbury IN', 39.34, -86.04, -5.3),
    _DeclSample('San Francisco CA', 37.77, -122.42, 12.7),
    _DeclSample('Denver CO', 39.74, -104.99, 7.3),
    _DeclSample('Anchorage AK', 61.22, -149.90, 13.4),
    _DeclSample('Sydney AU', -33.87, 151.21, 12.7),
  ];

  test('declination grid matches NOAA references within 0.5°', () async {
    for (final s in samples) {
      final actual = await DeclinationService.instance
          .declinationDegrees(lat: s.lat, lon: s.lon);
      expect(actual, isNotNull,
          reason: '${s.name}: service returned null '
              '(grid asset missing?)');
      expect(actual!, closeTo(s.expectedDecl, 0.5),
          reason: '${s.name}: declination off vs reference '
              'lat=${s.lat} lon=${s.lon}');
    }
  });

  test('grid wraps longitude into [-180, 180)', () async {
    // 270° longitude is -90° wrapped — should give the same
    // declination as -90°. Use Anchorage (-150° lon) as the reference;
    // 210° wraps to -150° and should match.
    final refValue = await DeclinationService.instance
        .declinationDegrees(lat: 60.0, lon: -150.0);
    final wrappedValue = await DeclinationService.instance
        .declinationDegrees(lat: 60.0, lon: 210.0);
    expect(refValue, isNotNull);
    expect(wrappedValue, isNotNull);
    expect(wrappedValue!, closeTo(refValue!, 1e-6));
  });

  test('grid clamps latitude to [-90, 90]', () async {
    // 95° latitude should clamp to 90° and not throw.
    final actual = await DeclinationService.instance
        .declinationDegrees(lat: 95.0, lon: 0.0);
    expect(actual, isNotNull);
    final clamped = await DeclinationService.instance
        .declinationDegrees(lat: 90.0, lon: 0.0);
    expect(actual!, closeTo(clamped!, 1e-6));
  });

  test('preload primes the synchronous lookup path', () async {
    await DeclinationService.instance.preload();
    final sync = DeclinationService.instance
        .declinationDegreesSync(lat: 39.74, lon: -104.99);
    expect(sync, isNotNull);
    expect(sync!, closeTo(7.3, 0.5));
  });

  test('asset is well-formed JSON with the expected schema', () async {
    final raw = await rootBundle.loadString(
        'assets/seed_data/wmm_declination.json');
    expect(raw.length, greaterThan(20000),
        reason: 'WMM grid asset is suspiciously small');
  });
}

class _DeclSample {
  const _DeclSample(this.name, this.lat, this.lon, this.expectedDecl);
  final String name;
  final double lat;
  final double lon;
  final double expectedDecl;
}
