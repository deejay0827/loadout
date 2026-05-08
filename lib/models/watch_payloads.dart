// FILE: lib/models/watch_payloads.dart
//
// ============================================================================
// WHAT THIS FILE DOES
// ============================================================================
// Typed Dart structs for every payload exchanged across the Flutter ↔
// Apple Watch / Wear OS bridge. Each class pairs a constructor with a
// `toJsonForWatch()` method (and, where the watch sends data back, a
// `fromWatchJson()` factory) so the same shape is used in both directions.
//
// Public surface:
//   * `WatchPaths` — string constants for the five reserved bridge paths
//     (`active_load`, `dope`, `firearm_glance`, `log_shot`, `timer_event`).
//     The native iOS/Android sides have mirror copies (`WatchPaths.swift`,
//     `wear/bridge/WatchPaths.kt`); keep all three in sync.
//   * `ShotSource` — string constants describing how the watch detected
//     a shot (`motion`, `swipe`, `manual`).
//   * `DopeRow`, `DopeSnapshot` — phone → watch ballistic solution.
//   * `ActiveLoadSnapshot` — phone → watch "what's loaded right now" card.
//   * `FirearmGlanceSnapshot` — phone → watch firearm + barrel-life.
//   * `ShotLogged` — watch → phone time-stamped shot impact.
//   * `TimerEvent` — bidirectional stage-timer sync.
//
// All payloads use the platform message codecs: `StandardMethodCodec` on
// the Dart side, `[String: Any]` dictionaries on iOS WCSession, and
// JSON-bytes-in-DataMap on Wear OS. Only primitive types appear in the
// JSON (string, num, bool, list, map) so the round-trip is lossless.
//
// ============================================================================
// WHY IT EXISTS IN THE ARCHITECTURE
// ============================================================================
// The watch bridge is implemented in three languages (Dart, Swift, Kotlin)
// and runs across two transports (WatchConnectivity, Wearable Data Layer).
// Centralising the wire format in Dart structs gives feature code one
// place to look up "what does a `dope` payload look like?" and one place
// to break if the contract changes.
//
// Without this file, every screen that pushes data to the watch would
// hand-roll its own `Map<String, Object?>` and inevitably drift out of
// sync with the native sides. Putting path constants next to the payload
// classes also makes it obvious that adding a new path means touching
// three matching files at once.
//
// ============================================================================
// WHY THIS IS HARDER THAN IT LOOKS
// ============================================================================
// 1. **16 KiB envelope budget.** Both transports cap individual payloads:
//    `WCSession.updateApplicationContext` and the Wear OS `DataClient.put-
//    DataItem` ceiling is roughly 16 KiB. We hit that ceiling fastest with
//    `DopeSnapshot`, which is a header + N rows. To stay safe we use
//    single-letter JSON keys (`r/u/w/v/t` per row, `cart/bgr/bn/mv/...`
//    for the header) and round mil values to two decimals before encoding.
//    A 15-row 100–1500 yd ladder serialises to ~700 bytes, leaving plenty
//    of headroom; a 100-row ladder would be over budget.
//
// 2. **Path constants live next to payload classes deliberately.** Adding
//    a new payload means defining the class AND the path together so a
//    grep for either turns up the other — and surfaces the matching iOS
//    + Kotlin files that need updating in parallel.
//
// 3. **Optional fields are conditionally encoded.** Every nullable field
//    is wrapped in `if (foo != null) ...` in `toJsonForWatch()` so the
//    watch decoder doesn't have to differentiate "field absent" from
//    "field set to null". This trims a few bytes per payload and avoids
//    a whole class of decoder bugs on the native side where iOS's
//    `NSNumber` and Kotlin's `JSONObject.get()` both treat `null` as a
//    distinct value.
//
// 4. **`jsonByteSize` is a conservative upper bound.** Production
//    payloads ride the platform's `StandardMessageCodec`, which is denser
//    than UTF-8 JSON. Tests use `jsonByteSize` to assert "well under
//    16 KiB" — if that assertion fails, the codec-encoded payload would
//    have failed sooner.
//
// 5. **`_round` rolls its own pow10 ladder.** `dart:math.pow` returns
//    `num`, not `double`, and is hot-path code on every payload encode;
//    a switch on the most common decimal counts dodges the cast and the
//    library call.
//
// ============================================================================
// WHO CONSUMES THIS FILE
// ============================================================================
// - lib/services/watch_bridge_service.dart — single direct importer.
//   The bridge service serialises outgoing payloads and deserialises
//   incoming ones. Feature code (range day, ballistics, recipe form)
//   talks to the bridge service, not these classes directly.
// - test/* — payload tests instantiate these classes to round-trip
//   through `jsonEncode`/`jsonDecode`.
// - Mirror files (must stay in sync, but DO NOT import this file):
//   * ios/RunnerWatchApp/WatchPaths.swift
//   * ios/RunnerWatchApp/DopeViewModel.swift
//   * android/wear/src/main/java/com/.../bridge/WatchPaths.kt
//   * android/wear/src/main/java/com/.../bridge/Payloads.kt
//
// ============================================================================
// SIDE EFFECTS
// ============================================================================
// None. Pure data classes — no I/O, no globals, no observers.

import 'dart:convert';

/// Reserved bridge paths. Match CLAUDE.md §15 verbatim. Do not rename.
class WatchPaths {
  static const String activeLoad = 'active_load';
  static const String dope = 'dope';
  static const String firearmGlance = 'firearm_glance';
  static const String logShot = 'log_shot';
  static const String timerEvent = 'timer_event';

  const WatchPaths._();
}

/// Sources reported by the watch when logging a shot. The phone trusts
/// the value but only enumerates the three canonical sources for
/// analytics-free filtering.
class ShotSource {
  static const String motion = 'motion';
  static const String swipe = 'swipe';
  static const String manual = 'manual';

  const ShotSource._();
}

/// One row of a downrange ballistic solution. Inches converted to mils
/// and MOA on the watch side using the small-angle approximation
/// (1 mil = inches / range_yd × 27.778; 1 MOA ≈ inches / range_yd × 95.49).
class DopeRow {
  const DopeRow({
    required this.rangeYd,
    required this.dropMil,
    required this.windMil,
    required this.velocityFps,
    required this.timeOfFlightSec,
  });

  /// Downrange distance in yards.
  final int rangeYd;

  /// Vertical hold (positive = up) in mils.
  final double dropMil;

  /// Horizontal hold (positive = right) in mils for the assumed wind.
  final double windMil;

  /// Bullet velocity at this range in fps.
  final double velocityFps;

  /// Time of flight from muzzle in seconds.
  final double timeOfFlightSec;

  Map<String, Object?> toJsonForWatch() => <String, Object?>{
        'r': rangeYd,
        'u': _round(dropMil, 2),
        'w': _round(windMil, 2),
        'v': velocityFps.round(),
        't': _round(timeOfFlightSec, 2),
      };

  static DopeRow fromWatchJson(Map<String, Object?> map) {
    return DopeRow(
      rangeYd: (map['r'] as num).toInt(),
      dropMil: (map['u'] as num).toDouble(),
      windMil: (map['w'] as num).toDouble(),
      velocityFps: (map['v'] as num).toDouble(),
      timeOfFlightSec: (map['t'] as num).toDouble(),
    );
  }
}

/// Compact ballistic snapshot pushed to the watch. Stays under the
/// 16 KiB transport budget by:
///
///   - using single-letter keys for [DopeRow] entries
///   - rounding mil values to two decimals
///   - capping the row count at the requested distance ladder
///
/// A 15-row 100-1500 yd ladder serializes to ~700 bytes JSON.
class DopeSnapshot {
  const DopeSnapshot({
    required this.cartridgeName,
    required this.bulletGr,
    required this.bulletName,
    required this.muzzleVelocityFps,
    required this.zeroRangeYd,
    required this.windSpeedMph,
    required this.windFromDeg,
    required this.dragModel,
    required this.bc,
    required this.rows,
    required this.generatedAtMs,
    this.profileName,
    this.firearmName,
  });

  /// Cartridge name shown on the watch's title line ("6.5 Creedmoor").
  final String cartridgeName;

  /// Bullet weight in grains.
  final double bulletGr;

  /// Bullet model line ("140 ELD-M").
  final String bulletName;

  /// Muzzle velocity in fps.
  final double muzzleVelocityFps;

  /// Zero distance in yards.
  final int zeroRangeYd;

  /// Wind speed in mph used to compute the wind hold.
  final double windSpeedMph;

  /// Wind direction (where wind comes from) in degrees, 0 = N.
  final double windFromDeg;

  /// 'g1' | 'g7'
  final String dragModel;

  /// Ballistic coefficient (in the chosen drag model).
  final double bc;

  /// One [DopeRow] per requested range. Sorted ascending.
  final List<DopeRow> rows;

  /// Wall clock when the snapshot was computed, ms since epoch. Used
  /// by the watch to show "as of X ago" if the user opens the card
  /// after the phone has been asleep.
  final int generatedAtMs;

  /// Optional saved profile name ("PRS Match Load").
  final String? profileName;

  /// Optional firearm name ("Tikka T3x").
  final String? firearmName;

  Map<String, Object?> toJsonForWatch() => <String, Object?>{
        'cart': cartridgeName,
        'bgr': bulletGr,
        'bn': bulletName,
        'mv': muzzleVelocityFps.round(),
        'z': zeroRangeYd,
        'ws': _round(windSpeedMph, 1),
        'wd': _round(windFromDeg, 0),
        'dm': dragModel,
        'bc': _round(bc, 3),
        if (profileName != null) 'pn': profileName,
        if (firearmName != null) 'fn': firearmName,
        'g': generatedAtMs,
        'rows': rows.map((r) => r.toJsonForWatch()).toList(growable: false),
      };

  /// Returns the JSON-encoded byte size, useful for the <16 KiB
  /// guardrail. Test-only — production payloads go through the
  /// bridge's StandardMessageCodec, which is denser, so this is a
  /// conservative upper bound.
  int get jsonByteSize {
    return utf8.encode(jsonEncode(toJsonForWatch())).length;
  }
}

/// Active recipe summary pushed to the watch. Smaller than [DopeSnapshot]
/// — purely text + a couple of numerics for the watch's "what's loaded"
/// header.
class ActiveLoadSnapshot {
  const ActiveLoadSnapshot({
    required this.name,
    required this.cartridgeName,
    this.powderName,
    this.powderChargeGr,
    this.bulletName,
    this.bulletWeightGr,
    this.primer,
    this.brass,
    this.coalIn,
    this.cbtoIn,
  });

  final String name;
  final String cartridgeName;
  final String? powderName;
  final double? powderChargeGr;
  final String? bulletName;
  final double? bulletWeightGr;
  final String? primer;
  final String? brass;
  final double? coalIn;
  final double? cbtoIn;

  Map<String, Object?> toJsonForWatch() => <String, Object?>{
        'n': name,
        'cart': cartridgeName,
        if (powderName != null) 'p': powderName,
        if (powderChargeGr != null) 'pgr': powderChargeGr,
        if (bulletName != null) 'b': bulletName,
        if (bulletWeightGr != null) 'bgr': bulletWeightGr,
        if (primer != null) 'pr': primer,
        if (brass != null) 'br': brass,
        if (coalIn != null) 'coal': coalIn,
        if (cbtoIn != null) 'cbto': cbtoIn,
      };
}

/// Firearm + barrel life summary pushed to the watch.
class FirearmGlanceSnapshot {
  const FirearmGlanceSnapshot({
    required this.name,
    required this.shotsFired,
    this.caliber,
    this.barrelLifeRemainingPct,
  });

  final String name;
  final int shotsFired;
  final String? caliber;

  /// 0.0 .. 1.0 — null when the user hasn't set an expected barrel life.
  final double? barrelLifeRemainingPct;

  Map<String, Object?> toJsonForWatch() => <String, Object?>{
        'n': name,
        's': shotsFired,
        if (caliber != null) 'c': caliber,
        if (barrelLifeRemainingPct != null)
          'l': _round(barrelLifeRemainingPct!, 3),
      };
}

/// Sent watch -> phone every time the user (or motion detector) logs a
/// shot from the wrist.
class ShotLogged {
  const ShotLogged({
    required this.atMsSinceEpoch,
    required this.source,
    this.rangeYd,
    this.peakG,
  });

  /// Epoch-millis timestamp the shot was registered on the watch.
  final int atMsSinceEpoch;

  /// 'motion' | 'swipe' | 'manual'
  final String source;

  /// Range bin the watch was showing when the shot was logged. Helpful
  /// context for the phone-side range-day session if the user is
  /// scrolling DOPE rows.
  final double? rangeYd;

  /// Peak G measured during the motion event, if [source] is 'motion'.
  final double? peakG;

  DateTime get at => DateTime.fromMillisecondsSinceEpoch(atMsSinceEpoch);

  static ShotLogged fromWatchJson(Map<String, Object?> map) {
    return ShotLogged(
      atMsSinceEpoch: (map['at'] as num).toInt(),
      source: (map['src'] as String?) ?? ShotSource.manual,
      rangeYd: (map['r'] as num?)?.toDouble(),
      peakG: (map['g'] as num?)?.toDouble(),
    );
  }

  Map<String, Object?> toJsonForWatch() => <String, Object?>{
        'at': atMsSinceEpoch,
        'src': source,
        if (rangeYd != null) 'r': rangeYd,
        if (peakG != null) 'g': peakG,
      };
}

/// Optional bidirectional event for the competition stage timer. When
/// the user starts the timer on the watch, the watch can push a
/// `start` event so the phone shows the same countdown if it's
/// awake. When the phone receives `expired`, it can vibrate.
class TimerEvent {
  const TimerEvent({
    required this.kind,
    required this.atMsSinceEpoch,
    this.remainingSec,
    this.totalSec,
  });

  /// 'start' | 'pause' | 'resume' | 'reset' | 'tick' | 'warning' | 'expired'
  final String kind;
  final int atMsSinceEpoch;
  final int? remainingSec;
  final int? totalSec;

  static TimerEvent fromWatchJson(Map<String, Object?> map) {
    return TimerEvent(
      kind: (map['k'] as String?) ?? 'tick',
      atMsSinceEpoch: (map['at'] as num).toInt(),
      remainingSec: (map['rem'] as num?)?.toInt(),
      totalSec: (map['tot'] as num?)?.toInt(),
    );
  }

  Map<String, Object?> toJsonForWatch() => <String, Object?>{
        'k': kind,
        'at': atMsSinceEpoch,
        if (remainingSec != null) 'rem': remainingSec,
        if (totalSec != null) 'tot': totalSec,
      };
}

double _round(double value, int decimals) {
  if (decimals <= 0) return value.roundToDouble();
  final factor = _pow10(decimals);
  return (value * factor).roundToDouble() / factor;
}

double _pow10(int n) {
  switch (n) {
    case 0:
      return 1;
    case 1:
      return 10;
    case 2:
      return 100;
    case 3:
      return 1000;
    default:
      var v = 1.0;
      for (var i = 0; i < n; i++) {
        v *= 10;
      }
      return v;
  }
}
