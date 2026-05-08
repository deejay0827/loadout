// FILE: test/watch_payloads_test.dart
//
// Verifies the watch-bridge payload round-trip and the 16 KB transport
// budget stays satisfied for realistic 100-1500 yd ladders.

import 'package:flutter_test/flutter_test.dart';
import 'package:loadout/models/watch_payloads.dart';

void main() {
  group('DopeSnapshot', () {
    test('serializes a 15-row 100-1500 yd ladder under 16 KB', () {
      final rows = <DopeRow>[];
      for (var range = 100; range <= 1500; range += 100) {
        rows.add(DopeRow(
          rangeYd: range,
          dropMil: range * 0.012,
          windMil: range * 0.002,
          velocityFps: 2750 - range * 0.6,
          timeOfFlightSec: range * 0.0015,
        ));
      }
      final snap = DopeSnapshot(
        cartridgeName: '6.5 Creedmoor',
        bulletGr: 140,
        bulletName: '140 ELD-M',
        muzzleVelocityFps: 2750,
        zeroRangeYd: 100,
        windSpeedMph: 8.0,
        windFromDeg: 270,
        dragModel: 'g7',
        bc: 0.315,
        rows: rows,
        generatedAtMs: 1730000000000,
        profileName: 'PRS Match Load',
        firearmName: 'Tikka T3x CTR',
      );
      expect(snap.jsonByteSize, lessThan(16 * 1024));
      // And it should be substantially smaller — the budget is for
      // sanity, not to leave us scraping by.
      expect(snap.jsonByteSize, lessThan(2 * 1024));
    });

    test('toJsonForWatch uses single-letter row keys', () {
      final snap = DopeSnapshot(
        cartridgeName: '6.5 CM',
        bulletGr: 140,
        bulletName: 'ELD-M',
        muzzleVelocityFps: 2700,
        zeroRangeYd: 100,
        windSpeedMph: 5,
        windFromDeg: 270,
        dragModel: 'g7',
        bc: 0.315,
        rows: const [
          DopeRow(
            rangeYd: 600,
            dropMil: 5.4,
            windMil: 0.8,
            velocityFps: 1780,
            timeOfFlightSec: 0.92,
          ),
        ],
        generatedAtMs: 1730000000000,
      );
      final json = snap.toJsonForWatch();
      final rowsJson = json['rows'] as List<dynamic>;
      expect(rowsJson.first, containsPair('r', 600));
      expect(rowsJson.first, containsPair('u', 5.4));
      expect(rowsJson.first, containsPair('w', 0.8));
    });
  });

  group('ShotLogged', () {
    test('round-trips watch -> phone JSON', () {
      const original = ShotLogged(
        atMsSinceEpoch: 1730000000000,
        source: ShotSource.motion,
        rangeYd: 600,
        peakG: 6.4,
      );
      final round = ShotLogged.fromWatchJson(original.toJsonForWatch());
      expect(round.atMsSinceEpoch, original.atMsSinceEpoch);
      expect(round.source, ShotSource.motion);
      expect(round.rangeYd, 600);
      expect(round.peakG, 6.4);
    });

    test('falls back to manual when source is missing', () {
      final r = ShotLogged.fromWatchJson({
        'at': 1730000000000,
      });
      expect(r.source, ShotSource.manual);
    });
  });

  group('TimerEvent', () {
    test('round-trips watch -> phone JSON', () {
      const event = TimerEvent(
        kind: 'warning',
        atMsSinceEpoch: 1730000000000,
        remainingSec: 10,
        totalSec: 90,
      );
      final round = TimerEvent.fromWatchJson(event.toJsonForWatch());
      expect(round.kind, 'warning');
      expect(round.remainingSec, 10);
      expect(round.totalSec, 90);
    });
  });

  group('WatchPaths', () {
    test('reserved-path constants match CLAUDE.md §15 verbatim', () {
      // These are wire-format constants. Renaming any of them is a
      // breaking change that requires synchronized updates across the
      // iOS, Android, and watch targets. CLAUDE.md is the source of
      // truth.
      expect(WatchPaths.activeLoad, 'active_load');
      expect(WatchPaths.dope, 'dope');
      expect(WatchPaths.firearmGlance, 'firearm_glance');
      expect(WatchPaths.logShot, 'log_shot');
      expect(WatchPaths.timerEvent, 'timer_event');
    });
  });
}
