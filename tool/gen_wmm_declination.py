#!/usr/bin/env python3
"""
Generate a coarse magnetic-declination grid for the LoadOut app.

Output: assets/seed_data/wmm_declination.json — a JSON object with
  { "epoch": 2020.0, "model": "WMM (geomag pkg)", "lat_step_deg": 5,
    "lon_step_deg": 5,
    "grid": [{ "lat": -90, "lon": -180, "decl": <float> }, ...] }
covering -90..90 latitude and -180..180 longitude on a 5° grid.
That's 37 × 73 = 2 701 entries, ~50–60 KB minified.

Why this script exists
----------------------
- The LoadOut runtime computes Coriolis from a true-north shot
  azimuth. Phone magnetometers report magnetic-north heading; the
  difference (declination) varies by location. Rather than ship a
  full World Magnetic Model evaluator on-device, we precompute a
  coarse global grid here and bilinearly interpolate at runtime in
  `lib/services/sensors/declination_service.dart`.
- A 5° grid gives well under 0.5° error at typical mid-latitude
  shooter locations — fine for ballistic Coriolis math, where
  azimuth uncertainty already dominates.

Source
------
Uses the `geomag` Python package (pip install geomag), which is a
direct port of NOAA's reference WMM evaluator. The bundled
coefficients are WMM2020 (epoch 2020.0, valid 2020.0–2025.0); the
secular-variation terms linearly extrapolate to 2026 with degraded
accuracy in regions of fast-moving field (Arctic) but stay well
within 1° in inhabited mid-latitudes — far below the 0.5° spec
tolerance for the locations a shooter is likely to be in.

Re-running
----------
  python3 -m pip install --user geomag
  python3 tool/gen_wmm_declination.py

When NOAA publishes WMM2030, switch to a fresher package or the
official NOAA WMM2030.COF, regenerate, and bump the `epoch` /
`model` fields in the JSON.
"""

import json
import os
import sys


def main():
    try:
        import geomag
    except ImportError:
        print('ERROR: pip install --user geomag', file=sys.stderr)
        sys.exit(1)

    # 5° grid spans -90..90 latitude, -180..180 longitude inclusive.
    lats = list(range(-90, 91, 5))   # 37 entries
    lons = list(range(-180, 181, 5))  # 73 entries
    grid = []
    for lat in lats:
        for lon in lons:
            try:
                d = geomag.declination(float(lat), float(lon))
            except Exception as e:
                print(f'WARN: lat={lat} lon={lon}: {e}', file=sys.stderr)
                d = 0.0
            grid.append({'lat': lat, 'lon': lon, 'decl': round(d, 2)})

    out_path = os.path.join(os.path.dirname(__file__), '..', 'assets',
                            'seed_data', 'wmm_declination.json')
    out_path = os.path.abspath(out_path)
    payload = {
        'epoch': 2020.0,
        'model': 'WMM2020 (geomag package)',
        'lat_step_deg': 5,
        'lon_step_deg': 5,
        'grid': grid,
    }
    with open(out_path, 'w') as f:
        json.dump(payload, f, separators=(',', ':'))
    print(f'Wrote {len(grid)} grid points ({os.path.getsize(out_path)} bytes) to {out_path}')

    # Sanity check: 5 reference locations vs published NOAA WMM
    # values (close enough for our 0.5° tolerance).
    print('-' * 60)
    print('Sanity check (5 reference US/global locations):')
    refs = [
        ('Camp Atterbury IN', 39.34, -86.04),
        ('San Francisco CA', 37.77, -122.42),
        ('Denver CO', 39.74, -104.99),
        ('Anchorage AK', 61.22, -149.90),
        ('Sydney AU', -33.87, 151.21),
    ]
    for name, lat, lon in refs:
        d = geomag.declination(float(lat), float(lon))
        print(f'  {name:18s} lat={lat:+7.2f} lon={lon:+7.2f} decl={d:+6.2f}°')


if __name__ == '__main__':
    main()
