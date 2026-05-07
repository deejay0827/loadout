// FILE: lib/services/ble/garmin_xero_service.dart
//
// ============================================================================
// WHAT THIS FILE DOES
// ============================================================================
// Garmin Xero C1 Pro chronograph integration. Two paths:
//
//   1. **.fit file import (shipping path).** The Xero exports a
//      Garmin FIT activity file containing one record per shot in the
//      session, with fields like `chrono_velocity_avg`,
//      `chrono_velocity_max`, etc. We parse the FIT binary structure
//      and pull the per-shot velocities out, then return them as a
//      typed [GarminXeroSession]. This is the path users hit today
//      via "Import .fit from Garmin" buttons in the recipe form and
//      the range-day session detail.
//
//   2. **Live BLE pairing (placeholder).** The Xero broadcasts a
//      proprietary Garmin GATT service whose live spec is not public.
//      We surface the pairing flow as "coming soon" — shipping a
//      half-broken pairing flow is worse than not shipping one.
//      A future patch will populate `connect()` once the protocol is
//      reverse-engineered to a level we'd ship.
//
// FIT files use a packed binary format: a header, then a sequence of
// (definition message, data message) pairs. Definition messages
// describe the field layout for an upcoming data-message stream;
// data messages carry the actual values. We do NOT parse the entire
// FIT spec — only the subset Garmin Xero writes (file-id, session,
// record). Cleanly typed extraction; falls through to "no shots
// found" when the file shape is unexpected, so the user gets a
// readable error rather than a crash.
//
// ============================================================================
// WHO CONSUMES THIS FILE
// ============================================================================
// - lib/screens/devices/devices_screen.dart           (status chip)
// - lib/screens/recipes/recipe_form_screen.dart       (Process section)
// - lib/screens/range_day/range_day_session_screen.dart  (per-shot merge)
//
// ============================================================================
// SIDE EFFECTS
// ============================================================================
// - .fit parsing is in-memory only; nothing is persisted by this file.
//   Callers stash the parsed values in their own DB tables.
// - Live BLE pairing: not implemented yet; `connectLive()` always
//   throws [BleException] with a "coming soon" message.

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'ble_service.dart';

/// One shot from a Garmin Xero session.
class GarminXeroShot {
  const GarminXeroShot({
    required this.shotNumber,
    required this.velocityFps,
    this.timestamp,
  });

  /// 1-based shot number within the session.
  final int shotNumber;

  /// Muzzle velocity, fps.
  final double velocityFps;

  /// Wall-clock time of the shot, if recorded.
  final DateTime? timestamp;
}

/// Parsed summary of a single FIT export.
class GarminXeroSession {
  const GarminXeroSession({
    required this.shots,
    required this.averageFps,
    required this.extremeSpreadFps,
    required this.standardDeviationFps,
  });

  /// One entry per shot. Empty list ≠ failure — the file may genuinely
  /// have had zero shots; the UI surfaces a clear "no shots found"
  /// message rather than treating empty as success.
  final List<GarminXeroShot> shots;

  /// Mean of [shots.velocityFps]. 0 when the list is empty.
  final double averageFps;

  /// Max minus min velocity, fps. 0 when there are <2 shots.
  final double extremeSpreadFps;

  /// Sample standard deviation of [shots.velocityFps], fps. 0 when
  /// there are <2 shots.
  final double standardDeviationFps;
}

/// Adapter for Garmin Xero C1 Pro. v1 supports .fit import only;
/// `connectLive()` is a stub for the future direct-BLE path.
class GarminXeroService {
  GarminXeroService(this._ble);

  // ignore: unused_field — wired in for the future live-BLE path.
  final BleService _ble;

  /// Stub. Returns a "coming soon" error today so the UI's pairing
  /// button can show a friendly snackbar.
  Future<void> connectLive() async {
    throw const BleException(
      'Live Garmin Xero pairing is coming soon. For now, use Import .fit.',
    );
  }

  /// Parse a Garmin FIT file at [path] and return its shot list.
  /// Throws [GarminXeroParseException] with a user-friendly message
  /// on any failure.
  Future<GarminXeroSession> importFitFile(String path) async {
    final file = File(path);
    final List<int> bytes;
    try {
      bytes = await file.readAsBytes();
    } catch (e) {
      throw GarminXeroParseException(
        "Couldn't read that file. Try a different one.",
        cause: e,
      );
    }
    return parseFitBytes(bytes);
  }

  /// Parse a FIT file from an in-memory byte buffer. Visible for unit
  /// tests so we can drive the parser with hand-crafted fixtures.
  static GarminXeroSession parseFitBytes(List<int> data) {
    final velocities = _extractVelocities(data);
    if (velocities.isEmpty) {
      throw const GarminXeroParseException(
        "Couldn't find any shot velocities in that file. "
        'Make sure it\'s a Xero session export.',
      );
    }
    final shots = <GarminXeroShot>[
      for (int i = 0; i < velocities.length; i++)
        GarminXeroShot(
          shotNumber: i + 1,
          velocityFps: velocities[i],
        ),
    ];
    final stats = _computeStats(velocities);
    return GarminXeroSession(
      shots: shots,
      averageFps: stats.average,
      extremeSpreadFps: stats.extremeSpread,
      standardDeviationFps: stats.stdDev,
    );
  }

  // ───────────────────── FIT decoding ─────────────────────

  /// Pulls per-record velocity values from a FIT byte stream.
  ///
  /// We parse only the subset of FIT we need: header + record /
  /// definition messages. Each "record" data message Garmin Xero
  /// writes contains a `chrono_velocity` field (units: m/s, scaled
  /// per the FIT field definition). We convert m/s → fps and return
  /// the list in file order.
  ///
  /// Returns an empty list on any parse failure rather than throwing,
  /// so the caller can surface a single "no shots found" copy.
  static List<double> _extractVelocities(List<int> raw) {
    if (raw.length < 14) return const [];
    final bd = ByteData.sublistView(Uint8List.fromList(raw));

    // Header: 1 byte size, 1 byte protocol version, 2 bytes profile
    // version, 4 bytes data size, 4 bytes magic ".FIT".
    final headerSize = bd.getUint8(0);
    if (headerSize < 12 || headerSize > raw.length) return const [];
    final dataSize = bd.getUint32(4, Endian.little);
    final dataEnd = headerSize + dataSize;
    if (dataEnd > raw.length) return const [];
    if (raw[8] != 0x2E ||
        raw[9] != 0x46 ||
        raw[10] != 0x49 ||
        raw[11] != 0x54) {
      // No '.FIT' magic — not a Garmin FIT file.
      return const [];
    }

    // Per-local-message-type definitions. Index 0..15.
    final defs = List<_FitDefinition?>.filled(16, null);

    final velocities = <double>[];
    int offset = headerSize;
    try {
      while (offset < dataEnd) {
        final recHeader = bd.getUint8(offset);
        offset += 1;
        final isDefinition = (recHeader & 0x40) != 0;
        final localType = recHeader & 0x0F;
        if (isDefinition) {
          final def = _readDefinition(bd, offset);
          if (def == null) break;
          defs[localType] = def.definition;
          offset = def.cursor;
        } else {
          final def = defs[localType];
          if (def == null) {
            // Unknown definition; we can't reliably skip without
            // knowing the message size. Bail out of further parsing.
            break;
          }
          final v = _readDataMessage(bd, offset, def);
          if (v != null) velocities.add(v);
          offset += def.totalSize;
        }
      }
    } catch (_) {
      // Bail out gracefully on any malformed message; return what we
      // have so far.
    }
    return velocities;
  }

  static _FitDefRead? _readDefinition(ByteData bd, int start) {
    int offset = start;
    if (offset + 5 > bd.lengthInBytes) return null;
    // Reserved, architecture, global message number (uint16), num fields.
    offset += 1; // reserved
    final arch = bd.getUint8(offset);
    offset += 1;
    final endian = arch == 0 ? Endian.little : Endian.big;
    final globalMsgNum = bd.getUint16(offset, endian);
    offset += 2;
    final numFields = bd.getUint8(offset);
    offset += 1;
    if (offset + numFields * 3 > bd.lengthInBytes) return null;
    int totalSize = 0;
    final fields = <_FitField>[];
    for (int i = 0; i < numFields; i++) {
      final defNum = bd.getUint8(offset);
      offset += 1;
      final size = bd.getUint8(offset);
      offset += 1;
      final baseType = bd.getUint8(offset);
      offset += 1;
      fields.add(_FitField(
        defNum: defNum,
        size: size,
        baseType: baseType,
        offset: totalSize,
      ));
      totalSize += size;
    }
    return _FitDefRead(
      definition: _FitDefinition(
        globalMsgNum: globalMsgNum,
        endian: endian,
        fields: fields,
        totalSize: totalSize,
      ),
      cursor: offset,
    );
  }

  /// Returns the velocity in fps, or null if this data message isn't a
  /// chrono record / doesn't carry a velocity field.
  static double? _readDataMessage(
    ByteData bd,
    int start,
    _FitDefinition def,
  ) {
    // FIT global message numbers we care about. The Xero writes
    // chrono velocity inside "record" (#20) messages with a
    // device-specific field number. We try both the standard
    // 'speed' (#6 on record) and Garmin's chrono extension fields
    // (commonly reported as field 7 on a chrono session). If
    // neither matches we return null.
    if (def.globalMsgNum != 20) return null;
    if (start + def.totalSize > bd.lengthInBytes) return null;
    for (final f in def.fields) {
      // Try the standard `speed` field first (defNum 6 on record),
      // then the chrono-specific defNums Garmin has been observed
      // emitting (7 = primary chrono velocity per public reverse-
      // engineering). Both are stored as uint16 m/s * 1000.
      if (f.defNum == 6 || f.defNum == 7) {
        if (f.baseType != 0x84 && f.baseType != 0x86) {
          continue; // not a uint16 / uint32 — not a speed field
        }
        final raw = f.baseType == 0x84
            ? bd.getUint16(start + f.offset, def.endian)
            : bd.getUint32(start + f.offset, def.endian);
        if (raw == 0xFFFF || raw == 0xFFFFFFFF) {
          continue; // FIT "invalid" sentinel
        }
        // FIT speed scale is 1000 (i.e. units = m/s * 1000).
        final mps = raw / 1000.0;
        // m/s → fps (1 m/s ≈ 3.28084 fps).
        return mps * 3.28084;
      }
    }
    return null;
  }

  // ───────────────────── stats helpers ─────────────────────

  static _VelocityStats _computeStats(List<double> v) {
    if (v.isEmpty) return const _VelocityStats(0, 0, 0);
    if (v.length == 1) return _VelocityStats(v.first, 0, 0);
    final mean = v.reduce((a, b) => a + b) / v.length;
    double minV = v.first, maxV = v.first;
    double sumSq = 0;
    for (final x in v) {
      if (x < minV) minV = x;
      if (x > maxV) maxV = x;
      final d = x - mean;
      sumSq += d * d;
    }
    final variance = sumSq / (v.length - 1);
    final stdDev = variance <= 0 ? 0.0 : _sqrt(variance);
    return _VelocityStats(mean, maxV - minV, stdDev);
  }

  /// Tiny sqrt without pulling in dart:math, so the file's intent is
  /// crystal clear at the call site (and no dependency leak risk).
  static double _sqrt(double x) {
    if (x <= 0) return 0;
    double guess = x / 2;
    for (int i = 0; i < 12; i++) {
      guess = 0.5 * (guess + x / guess);
    }
    return guess;
  }
}

class GarminXeroParseException implements Exception {
  const GarminXeroParseException(this.userMessage, {this.cause});

  final String userMessage;
  final Object? cause;

  @override
  String toString() =>
      'GarminXeroParseException($userMessage)${cause == null ? '' : ' caused by $cause'}';
}

class _FitDefinition {
  const _FitDefinition({
    required this.globalMsgNum,
    required this.endian,
    required this.fields,
    required this.totalSize,
  });

  final int globalMsgNum;
  final Endian endian;
  final List<_FitField> fields;
  final int totalSize;
}

class _FitField {
  const _FitField({
    required this.defNum,
    required this.size,
    required this.baseType,
    required this.offset,
  });

  final int defNum;
  final int size;
  final int baseType;
  final int offset;
}

class _FitDefRead {
  const _FitDefRead({required this.definition, required this.cursor});
  final _FitDefinition definition;
  final int cursor;
}

class _VelocityStats {
  const _VelocityStats(this.average, this.extremeSpread, this.stdDev);
  final double average;
  final double extremeSpread;
  final double stdDev;
}
