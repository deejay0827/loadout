// FILE: lib/services/sensors/inclinometer_service.dart
//
// ============================================================================
// WHAT THIS FILE DOES
// ============================================================================
// Wraps the OS accelerometer stream behind a `ChangeNotifier` that the
// rest of the app can `context.watch<InclinometerService>()` on. Reports
// the phone's pitch angle ("incline" — rotation around its left-right
// axis) in degrees and exposes it as a single signed scalar:
//
//   * positive  = phone tilted forward (top edge points down) → uphill
//                 when the device is mounted to the rifle pointing the
//                 same way.
//   * negative  = phone tilted backward → downhill.
//   * zero      = phone perfectly level.
//
// Sister to `CantService` — both consume the same accelerometer stream,
// but compute different rotation axes:
//
//   * roll  (cant)   — `atan2(x, y)` — handled by CantService.
//   * pitch (incline) — `atan2(-z, sqrt(x² + y²))` — handled here.
//
// CALIBRATION. Like cant, phones are rarely mounted dead-square against
// a rifle's bore. The shooter taps "Use phone level" when the rifle
// barrel is established level (using a separate inclinometer or a
// surveyed range), and we record the current smoothed pitch as the zero
// offset. Subsequent readings are reported minus that offset.
//
// ============================================================================
// WHY IT EXISTS IN THE ARCHITECTURE
// ============================================================================
// Slope of fire (incline / decline) is a small but real correction term
// in a long-range firing solution. The improved rifleman's rule
// computes the equivalent horizontal range as `R · cos(θ)` (roughly) so
// drop reduces with both uphill AND downhill shots. At 10° at 800 yards
// the correction is on the order of ~6 inches — easy to chase as wind
// readout noise. Surfacing live incline in the Range Day Setup section
// lets the shooter type or capture a value without breaking out a
// separate inclinometer.
//
// ============================================================================
// WHY THIS IS HARDER THAN IT LOOKS
// ============================================================================
// 1. PLATFORM SUPPORT. Same caveat as CantService — `sensors_plus` only
//    has native iOS/Android implementations. macOS, Linux, Windows, and
//    web throw `MissingPluginException`. We catch that during `start()`
//    and surface an `available` flag so the UI can hide the affordance.
//
// 2. PITCH BRANCH NEAR ±90°. atan2 is well-behaved everywhere, but the
//    practical limit for a rifle-mounted phone is ±60° or so — anything
//    steeper and the phone is pointing at the sky / ground and the rest
//    of the apparatus has bigger problems. We clamp to ±90° so a
//    phone-on-its-back doesn't report nonsense.
//
// 3. CALIBRATION DRIFT. A single-shot calibration captures the current
//    rifle pose. If the rifle moves between calibration and shooting,
//    the calibration is stale. The UI exposes "Use phone level" as a
//    one-tap re-zero.

import 'dart:async';
import 'dart:io' show Platform;
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show MissingPluginException;
import 'package:sensors_plus/sensors_plus.dart';

/// `ChangeNotifier` that subscribes to the device accelerometer and
/// computes a signed incline (pitch) angle in degrees around the
/// phone's left-right axis.
///
/// Intended to be provided once via `Provider` in `lib/app.dart` and
/// consumed by the Range Day Setup card alongside [CantService] and
/// [MagnetometerService]. Notifies on every smoothed sample; uses the
/// same EMA smoothing as `CantService` (alpha = 0.15).
class InclinometerService extends ChangeNotifier {
  /// Smoothing coefficient — same value as `CantService` so the two
  /// sensors feel equally responsive in the UI.
  static const double _emaAlpha = 0.15;

  /// Sampling period for the accelerometer stream.
  static const Duration _samplingPeriod = SensorInterval.uiInterval;

  StreamSubscription<AccelerometerEvent>? _sub;

  /// Smoothed absolute pitch angle of the phone (degrees). Null until
  /// the first sample has arrived.
  double? _smoothedDeg;

  /// Calibration offset (degrees) — the absolute pitch recorded at the
  /// last "Use phone level" tap. Subtracted from the smoothed reading
  /// to produce [inclineDegrees].
  double _calibrationOffsetDeg = 0.0;

  /// True after [start] has successfully subscribed to the OS stream.
  bool _running = false;

  /// True if the platform exposes an accelerometer through `sensors_plus`.
  bool _available = true;

  /// Latest signed incline in degrees relative to the active calibration.
  /// Returns `null` until the first sensor sample arrives. Sign:
  /// positive = phone tilted forward (uphill on a rifle), negative =
  /// tilted backward (downhill).
  double? get inclineDegrees {
    final s = _smoothedDeg;
    if (s == null) return null;
    return s - _calibrationOffsetDeg;
  }

  /// Whether the platform supports the accelerometer.
  bool get isAvailable => _available;

  /// Whether the service is currently subscribed to the OS stream.
  bool get isRunning => _running;

  /// The current calibration offset in degrees.
  double get calibrationOffsetDeg => _calibrationOffsetDeg;

  /// Begin sampling. Idempotent — calling twice does not double-subscribe.
  /// Returns false if the platform has no accelerometer.
  Future<bool> start() async {
    if (_running) return _available;
    if (kIsWeb) {
      _markUnavailable();
      return false;
    }
    if (!(Platform.isIOS || Platform.isAndroid)) {
      _markUnavailable();
      return false;
    }
    try {
      _sub = accelerometerEventStream(samplingPeriod: _samplingPeriod)
          .listen(_handleAccelerometer, onError: (Object e, StackTrace _) {
        debugPrint('InclinometerService stream error: $e');
        _markUnavailable();
      });
      _running = true;
      _available = true;
      return true;
    } on MissingPluginException {
      _markUnavailable();
      return false;
    } catch (e) {
      debugPrint('InclinometerService start failed: $e');
      _markUnavailable();
      return false;
    }
  }

  void _markUnavailable() {
    if (!_available) return;
    _available = false;
    notifyListeners();
  }

  /// Stop sampling and release the OS sensor.
  Future<void> stop() async {
    await _sub?.cancel();
    _sub = null;
    _running = false;
  }

  /// Record the current smoothed pitch as the new zero. UX entry point
  /// for the "Use phone level" button.
  bool calibrateLevel() {
    final s = _smoothedDeg;
    if (s == null) return false;
    _calibrationOffsetDeg = s;
    notifyListeners();
    return true;
  }

  void clearCalibration() {
    if (_calibrationOffsetDeg == 0.0) return;
    _calibrationOffsetDeg = 0.0;
    notifyListeners();
  }

  void _handleAccelerometer(AccelerometerEvent e) {
    // Pitch is the rotation around the phone's left-right (x) axis.
    // With y pointing up (out the top of the screen) and z pointing
    // out of the back of the phone, gravity in pitch is:
    //   pitch_rad = atan2(-z, sqrt(x² + y²))
    // (negate z so a phone tilted forward — top edge down — is
    // positive, matching the "uphill" convention.)
    final pitchRad = math.atan2(-e.z, math.sqrt(e.x * e.x + e.y * e.y));
    var pitchDeg = pitchRad * 180.0 / math.pi;
    if (pitchDeg > 90.0) pitchDeg = 90.0;
    if (pitchDeg < -90.0) pitchDeg = -90.0;

    final prev = _smoothedDeg;
    if (prev == null) {
      _smoothedDeg = pitchDeg;
    } else {
      _smoothedDeg = prev + _emaAlpha * (pitchDeg - prev);
    }
    notifyListeners();
  }

  @override
  void dispose() {
    // ignore: discarded_futures
    _sub?.cancel();
    super.dispose();
  }
}
