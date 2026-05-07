// FILE: lib/screens/ballistics/ballistics_screen.dart
//
// ============================================================================
// WHAT THIS FILE DOES
// ============================================================================
// Renders the Pro-gated Ballistics Calculator. The user types in inputs
// describing a bullet, the rifle's zero, atmospheric conditions, and the
// list of ranges they want a solution at; tapping "Calculate Trajectory"
// runs the external-ballistics solver and renders a drop/wind table plus
// a small chart. There is also a "Export DOPE card to clipboard" button
// that formats the table as plain text. ("DOPE" is shooter slang for
// "Data On Previous Engagements" — the table you read off when dialing
// elevation/wind for a known range.)
//
// External ballistics is the physics of a bullet AFTER it leaves the
// muzzle: gravity drops the bullet, drag from the air slows it, crosswind
// pushes it sideways, the bullet's own spin pushes it slightly sideways
// too (spin drift / yaw of repose), and at extreme range the Earth's
// rotation matters (Coriolis). The solver computes all of those.
//
// The screen is laid out in four collapsible "Section" cards (built by
// the file-private `_SectionCard` widget):
//
//   1. Projectile  — diameter (in), weight (gr — grains), optional length
//      (in) and twist rate (1:N inches), ballistic coefficient (BC), and
//      a drag-model dropdown (`DragModel.g1` or `DragModel.g7` — the two
//      reference projectile shapes BCs are quoted against).
//   2. Muzzle / Zero — muzzle velocity (fps), sight height above bore
//      (in), zero range (yd), shot azimuth (° from north — used by
//      Coriolis), target elevation Δ (ft).
//   3. Environment — temperature (°F), station pressure (inHg, NOT
//      sea-level corrected — important distinction), humidity (%),
//      altitude (ft), wind speed (mph), wind direction (° "from"),
//      latitude (°N — Coriolis input).
//   4. Output — comma-separated list of sample ranges (yd), unit toggle
//      (Inch / MOA / Mil — the three angular conventions for scope
//      adjustment), the rendered DOPE table, the trajectory chart, and
//      the Export-to-clipboard button.
//
// The `AngleUnit` enum (`inches`, `moa`, `mil`) drives a `SegmentedButton`
// and the `_DopeTable._fmtAngle()` formatter. MOA = "minutes of angle"
// (1/60 of a degree, ≈ 1.047" at 100yd). Mil = milliradian (1/1000 of a
// radian, ≈ 3.6" at 100yd).
//
// On Calculate, `_compute()` parses the controllers, builds the input
// records (`Projectile`, `Atmosphere.station`, `Environment.fromImperial`,
// `ShotInputs`), and calls `solveTrajectory(...)`. On parse error or
// solver failure, an `_error` string is rendered in a red error card.
//
// ============================================================================
// WHY IT EXISTS IN THE ARCHITECTURE
// ============================================================================
// The ballistics calculator is a Pro-tier feature. Wrapping the body in
// `ProGate(feature: 'Ballistics Calculator', child: ...)` ensures the
// content is only rendered when the user has the `pro` entitlement; non-
// Pro users see the gated UI from `lib/widgets/pro_gate.dart` instead.
//
// All of the actual ballistics math lives in `lib/services/ballistics/`
// — this file is purely the form-and-render shell. Keeping inputs and
// outputs here, but the solver in a pure-Dart library, lets the solver
// be unit-tested in isolation and lets the formula stay self-contained
// rather than bleed into widget code.
//
// The solver this screen drives is a Modified Point-Mass (MPM) Level-3
// model with G1/G7 drag tables and Litz-style spin-drift correction. The
// "modified" part is the spin-drift and Coriolis terms layered on top of
// the simpler point-mass integration. The italic disclaimer at the bottom
// of the screen says exactly this.
//
// ============================================================================
// WHY THIS IS HARDER THAN IT LOOKS
// ============================================================================
// Three rough edges:
//
//   1. Unit confusion. Reloaders use grains (mass, 1/7000 lb), inches,
//      yards, feet per second, inches of mercury for pressure. Field
//      labels like "Pressure (inHg) — station, not corrected" matter:
//      most weather apps report SEA-LEVEL pressure ("altimeter setting"),
//      and feeding that to the solver will silently produce wrong drops
//      because the air is denser at altitude than the same-pressure-
//      corrected reading suggests. The helper text in the form is the
//      only thing keeping the user from this trap.
//   2. Wind direction convention. The wind input is the direction the
//      wind is blowing FROM, in degrees clockwise from north — same
//      convention as a weather report. "0 = tail" / "90 = right" in the
//      helper text translates that to the shooter's frame.
//   3. The DOPE export uses fixed-width formatting via `padLeft`. It
//      relies on `FontFeature.tabularFigures()` in the on-screen table
//      to make digits monospaced; the clipboard text is plain ASCII
//      and will look ragged if the user pastes it into a proportional
//      font, which is something to live with.
//
// ============================================================================
// WHO CONSUMES THIS FILE
// ============================================================================
// - `lib/screens/home/home_screen.dart` — adds a `BallisticsScreen()` as
//   one of the bottom-nav tab screens.
//
// ============================================================================
// SIDE EFFECTS
// ============================================================================
// - Reads from many `TextEditingController`s (form state, in-memory).
// - Calls into the pure-Dart ballistics solver in
//   `lib/services/ballistics/solver.dart`. No network, no DB.
// - Writes the formatted DOPE card to the system clipboard via
//   `Clipboard.setData(...)`. Triggered only on the user tapping
//   "Export DOPE card to clipboard."

import 'dart:async';

import 'package:drift/drift.dart' as drift;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../database/database.dart';
import '../../repositories/ballistic_profile_repository.dart';
import '../../repositories/component_repository.dart';
import '../../repositories/firearm_repository.dart';
import '../../services/ballistics/atmosphere.dart';
import '../../services/ballistics/drag_functions.dart';
import '../../services/ballistics/environment.dart';
import '../../services/ballistics/projectile.dart';
import '../../services/ballistics/solver.dart';
import '../../services/ballistics/units.dart';
import '../../services/ble/kestrel_service.dart';
import '../../services/entitlement_notifier.dart';
import '../../services/unit_service.dart';
import '../../services/weather_service.dart';
import '../../utils/responsive.dart';
import '../../widgets/pro_gate.dart';
import 'widgets/trajectory_chart.dart';

/// SharedPreferences keys for the range increment / min / max persistence.
const _kRangeIncrementKey = 'ballistics_range_increment_yd';
const _kRangeMinKey = 'ballistics_range_min_yd';
const _kRangeMaxKey = 'ballistics_range_max_yd';

/// Persisted "user has seen the Pro weather hint" flag for the first-run
/// MaterialBanner shown on top of the ballistics screen. Once `true`
/// the banner is suppressed forever — the hint exists to surface the
/// new feature, not to be dismissed-and-re-shown.
const _kWeatherHintShownKey = 'ballistics_weather_hint_shown';

/// Allowed bounds for the user-typed start / end ranges.
const _kRangeMinMin = 0;
const _kRangeMinMax = 1900;
const _kRangeMaxMin = 100;
const _kRangeMaxMax = 2000;

/// Default start range when no preference is stored. The solver treats
/// 0 yd as invalid (the first non-zero ladder rung is what gets sent),
/// so 0 here just means "start the ladder at the increment".
const _kRangeMinDefault = 0;

/// Default end range when no preference is stored. Matches the value
/// pre-filled in the End-range field on a fresh install.
const _kRangeMaxDefault = 1000;

/// Default range increment when nothing is selected yet — used so the
/// trajectory ladder always has a sensible default before the user
/// taps a chip. 100 yd matches the historical comma-separated default.
const _kRangeIncrementDefault = 100;

/// Cap on the number of ladder rungs a chip preset will produce. Above
/// roughly fifty rows, the DOPE table & chart get sluggish on phones,
/// and 50 rows already covers a 10-yd ladder out to 500 yd.
const _kRangeLadderCap = 50;

/// Top-level ballistics screen. Pro-gated.
///
/// Implements a Level 3 (Modified Point-Mass) external ballistics
/// calculator. Takes a projectile description, muzzle / zero
/// conditions, and environmental conditions (atmosphere, wind,
/// latitude / shot azimuth for Coriolis); produces a drop & wind table
/// at user-specified ranges plus a small trajectory + drift chart.
class BallisticsScreen extends StatefulWidget {
  const BallisticsScreen({super.key});

  @override
  State<BallisticsScreen> createState() => _BallisticsScreenState();
}

enum AngleUnit { inches, moa, mil }

class _BallisticsScreenState extends State<BallisticsScreen> {
  // ─────────────────────── Saved profiles ───────────────────────
  /// Live stream of saved profiles, used to populate the dropdown at
  /// the top of the screen. Subscribed once on initState; the list
  /// refreshes automatically after any insert / update / delete.
  Stream<List<BallisticProfileRow>>? _profilesStream;
  BallisticProfileRow? _activeProfile;

  // ─────────────────────── Rifle picker ───────────────────────
  /// One-shot list of the user's firearms, fetched on initState. Null until
  /// the future resolves; empty list means the user has no firearms saved.
  Future<List<UserFirearmRow>>? _firearmsFuture;
  UserFirearmRow? _selectedFirearm;
  /// Set when the rifle the user picked has no twist rate field — the UI
  /// shows a small inline hint to make this obvious without forcing a
  /// fallback value.
  bool _twistMissingFromFirearm = false;

  // ─────────────────────── Bullet picker ───────────────────────
  /// One-shot list of every bullet in the reference catalog, joined with
  /// its manufacturer. Null until the future resolves.
  Future<List<({BulletRow bullet, ManufacturerRow mfg})>>? _bulletsFuture;
  ({BulletRow bullet, ManufacturerRow mfg})? _selectedBullet;

  // ─────────────────────── Projectile ───────────────────────
  final _diameterCtrl = TextEditingController(text: '0.264');
  final _weightCtrl = TextEditingController(text: '140');
  final _lengthCtrl = TextEditingController(text: '1.355');
  final _bcCtrl = TextEditingController(text: '0.298');
  final _twistCtrl = TextEditingController(text: '8');
  DragModel _dragModel = DragModel.g7;

  // ─────────────────────── Muzzle / Zero ───────────────────────
  final _muzzleVelCtrl = TextEditingController(text: '2750');
  final _sightHeightCtrl = TextEditingController(text: '1.5');
  final _zeroRangeCtrl = TextEditingController(text: '100');
  final _shotAzimuthCtrl = TextEditingController(text: '0');
  final _targetElevationCtrl = TextEditingController(text: '0');

  // ─────────────────────── Environment ───────────────────────
  final _tempCtrl = TextEditingController(text: '59'); // ICAO 15°C = 59°F
  final _pressureCtrl = TextEditingController(text: '29.92');
  final _humidityCtrl = TextEditingController(text: '50');
  final _altitudeCtrl = TextEditingController(text: '0');
  final _windSpeedCtrl = TextEditingController(text: '10');
  final _windDirCtrl = TextEditingController(text: '90');
  final _latitudeCtrl = TextEditingController(text: '40');

  // ─────────────────────── Output settings ───────────────────────
  final _rangeMinCtrl =
      TextEditingController(text: _kRangeMinDefault.toString());
  final _rangeMaxCtrl =
      TextEditingController(text: _kRangeMaxDefault.toString());
  AngleUnit _unit = AngleUnit.moa;

  /// Selected range increment for the quick-fill chips. Defaults to
  /// `_kRangeIncrementDefault` so the trajectory ladder is well-defined
  /// from a fresh install — the chips only shape it, they don't gate it.
  int _rangeIncrement = _kRangeIncrementDefault;

  List<TrajectorySample> _samples = const [];
  String? _error;

  // ─────────────────────── Weather (Pro) ───────────────────────
  /// Spinner-on flag for the cloud icon button. Disables the button
  /// while a fetch is in flight so the user can't fire two requests
  /// in parallel.
  bool _weatherFetching = false;

  /// Wall-clock time of the most recent successful weather fetch.
  /// Drives the "Updated 2:34 PM" subtitle on the Environment header.
  DateTime? _weatherFetchedAt;

  /// First-run hint state. `_weatherHintHydrated` is false until the
  /// SharedPreferences read completes; once it's true, the banner
  /// shows iff `_weatherHintShown` is false.
  bool _weatherHintHydrated = false;
  bool _weatherHintShown = true;

  // ─────────────────────── Kestrel (Pro, BLE) ───────────────────────
  /// True iff the user has opted to drive the Environment fields from
  /// a connected Kestrel meter rather than the open-meteo fetch /
  /// manual entry. When true, every incoming [KestrelReading] is
  /// pushed into the controllers and the cloud-fetch button is
  /// suppressed in favour of a "Stop using Kestrel" affordance.
  bool _useKestrel = false;

  /// Kestrel reading subscription — alive only while [_useKestrel] is
  /// true and a device is connected.
  StreamSubscription<KestrelReading>? _kestrelSub;

  // ─────────────────────── Unit tracking ───────────────────────
  // The controllers above hold text in the user's CURRENT display unit
  // (imperial by default; switches to metric values when the user
  // toggles units in Settings). The `_lastSeen*` fields below capture
  // the unit each controller was last rendered in so a Settings change
  // can convert the existing text to the new unit instead of leaving
  // the same number with a different label, which would mis-state the
  // physical quantity.
  String? _lastSeenVelocity;
  String? _lastSeenSmallLen;
  String? _lastSeenRange;
  String? _lastSeenTemp;
  String? _lastSeenWind;
  String? _lastSeenPressure;
  String? _lastSeenBulletWeight;

  @override
  void initState() {
    super.initState();
    _firearmsFuture = context.read<FirearmRepository>().allFirearms();
    _bulletsFuture =
        context.read<ComponentRepository>().allBulletsWithManufacturer();
    _profilesStream = context.read<BallisticProfileRepository>().watchAll();
    _restoreRangePreferences();
    _loadWeatherHintFlag();
  }

  /// Reads the latest [UnitService] state and rewrites the controllers
  /// whenever the user has flipped a category since the last build.
  /// Called at the top of [build] so changes propagate without restart.
  ///
  /// The field text is treated as **already in the displayed unit**;
  /// when the user toggles, we invert from the OLD display unit back
  /// to canonical (imperial), then forward to the NEW display unit.
  /// This preserves the physical quantity the user typed.
  void _syncDisplayedUnits(UnitService units) {
    // Velocity (fps / m/s).
    final velUnit = units.unitFor(UnitCategory.velocity);
    if (_lastSeenVelocity != null && _lastSeenVelocity != velUnit) {
      _convertCtrl(_muzzleVelCtrl, _lastSeenVelocity!, velUnit, _velocityToCanonical, _velocityFromCanonical);
    }
    _lastSeenVelocity = velUnit;

    // Small length (in / cm) — sight height + bullet length follow this
    // unit. Bullet diameter is intentionally NOT converted: cartridge
    // designations are still imperial worldwide ("6.5mm" means 0.264"
    // bullet diameter, not 0.264 cm), so reloaders type diameter in
    // inches regardless of system.
    final smallLenUnit = units.unitFor(UnitCategory.smallLength);
    if (_lastSeenSmallLen != null && _lastSeenSmallLen != smallLenUnit) {
      _convertCtrl(_sightHeightCtrl, _lastSeenSmallLen!, smallLenUnit, _smallLenToCanonical, _smallLenFromCanonical);
      _convertCtrl(_lengthCtrl, _lastSeenSmallLen!, smallLenUnit, _smallLenToCanonical, _smallLenFromCanonical);
    }
    _lastSeenSmallLen = smallLenUnit;

    // Range (yd / m) — applies to zero range, range min/max.
    final rangeUnit = units.unitFor(UnitCategory.range);
    if (_lastSeenRange != null && _lastSeenRange != rangeUnit) {
      _convertCtrl(_zeroRangeCtrl, _lastSeenRange!, rangeUnit, _rangeToCanonical, _rangeFromCanonical);
      _convertCtrl(_rangeMinCtrl, _lastSeenRange!, rangeUnit, _rangeToCanonical, _rangeFromCanonical);
      _convertCtrl(_rangeMaxCtrl, _lastSeenRange!, rangeUnit, _rangeToCanonical, _rangeFromCanonical);
    }
    _lastSeenRange = rangeUnit;

    // Temperature (°F / °C).
    final tempUnit = units.unitFor(UnitCategory.temperature);
    if (_lastSeenTemp != null && _lastSeenTemp != tempUnit) {
      _convertCtrl(_tempCtrl, _lastSeenTemp!, tempUnit, _tempToCanonical, _tempFromCanonical);
    }
    _lastSeenTemp = tempUnit;

    // Wind speed (mph / m/s / km/h).
    final windUnit = units.unitFor(UnitCategory.windSpeed);
    if (_lastSeenWind != null && _lastSeenWind != windUnit) {
      _convertCtrl(_windSpeedCtrl, _lastSeenWind!, windUnit, _windToCanonical, _windFromCanonical);
    }
    _lastSeenWind = windUnit;

    // Pressure (inHg / mmHg / hPa).
    final pressureUnit = units.unitFor(UnitCategory.pressure);
    if (_lastSeenPressure != null && _lastSeenPressure != pressureUnit) {
      _convertCtrl(_pressureCtrl, _lastSeenPressure!, pressureUnit, _pressureToCanonical, _pressureFromCanonical);
    }
    _lastSeenPressure = pressureUnit;

    // Bullet weight (gr / g).
    final bulletWeightUnit = units.unitFor(UnitCategory.bulletWeight);
    if (_lastSeenBulletWeight != null && _lastSeenBulletWeight != bulletWeightUnit) {
      _convertCtrl(_weightCtrl, _lastSeenBulletWeight!, bulletWeightUnit, _bulletWeightToCanonical, _bulletWeightFromCanonical);
    }
    _lastSeenBulletWeight = bulletWeightUnit;
  }

  /// Convert the text of a controller from one display unit to another.
  /// `toCanonical(value, unit)` converts a display value in `unit` back
  /// to imperial; `fromCanonical(value, unit)` converts imperial back
  /// to display. We chain them: oldDisplay → canonical → newDisplay.
  void _convertCtrl(
    TextEditingController ctrl,
    String fromUnit,
    String toUnit,
    double Function(double, String) toCanonical,
    double Function(double, String) fromCanonical,
  ) {
    final raw = double.tryParse(ctrl.text.trim());
    if (raw == null) return;
    final canonical = toCanonical(raw, fromUnit);
    final newDisplay = fromCanonical(canonical, toUnit);
    ctrl.text = _formatNumber(newDisplay);
  }

  /// Trim trailing zeros so converted values look natural — `2.50` →
  /// `2.5`, `100.0` → `100`. Caps at 4 decimals to keep precision sane
  /// for short distances when converting to inches → cm.
  String _formatNumber(double v) {
    if (v.isNaN || v.isInfinite) return '0';
    final s = v.toStringAsFixed(4);
    final trimmed = s.replaceFirst(RegExp(r'\.?0+$'), '');
    return trimmed.isEmpty ? '0' : trimmed;
  }

  // Per-category conversion helpers used by [_syncDisplayedUnits].
  // They all return canonical = imperial (fps, in, yd, °F, mph, inHg).
  double _velocityToCanonical(double v, String unit) {
    if (unit == unitMps) return v / 0.3048;
    return v;
  }
  double _velocityFromCanonical(double fps, String unit) {
    if (unit == unitMps) return fps * 0.3048;
    return fps;
  }
  double _smallLenToCanonical(double v, String unit) {
    if (unit == unitCm) return v / 2.54;
    return v;
  }
  double _smallLenFromCanonical(double inches, String unit) {
    if (unit == unitCm) return inches * 2.54;
    return inches;
  }
  double _rangeToCanonical(double v, String unit) {
    if (unit == unitM) return v / 0.9144;
    return v;
  }
  double _rangeFromCanonical(double yd, String unit) {
    if (unit == unitM) return yd * 0.9144;
    return yd;
  }
  double _tempToCanonical(double v, String unit) {
    if (unit == unitDegC) return v * 9.0 / 5.0 + 32.0;
    return v;
  }
  double _tempFromCanonical(double f, String unit) {
    if (unit == unitDegC) return (f - 32.0) * 5.0 / 9.0;
    return f;
  }
  double _windToCanonical(double v, String unit) {
    if (unit == unitMps) return v / 0.44704;
    if (unit == unitKph) return v / 1.609344;
    return v;
  }
  double _windFromCanonical(double mph, String unit) {
    if (unit == unitMps) return mph * 0.44704;
    if (unit == unitKph) return mph * 1.609344;
    return mph;
  }
  double _pressureToCanonical(double v, String unit) {
    if (unit == unitMmHg) return v / 25.4;
    if (unit == unitHpa) return v / 33.8639;
    return v;
  }
  double _pressureFromCanonical(double inHg, String unit) {
    if (unit == unitMmHg) return inHg * 25.4;
    if (unit == unitHpa) return inHg * 33.8639;
    return inHg;
  }
  double _bulletWeightToCanonical(double v, String unit) {
    if (unit == unitG) return v / 0.06479891;
    return v;
  }
  double _bulletWeightFromCanonical(double gr, String unit) {
    if (unit == unitG) return gr * 0.06479891;
    return gr;
  }

  /// One-shot read of the "have we shown the weather hint yet?" flag.
  /// Called once from initState; the banner stays hidden until this
  /// resolves so we never flash it then immediately retract it.
  Future<void> _loadWeatherHintFlag() async {
    final prefs = await SharedPreferences.getInstance();
    final shown = prefs.getBool(_kWeatherHintShownKey) ?? false;
    if (!mounted) return;
    setState(() {
      _weatherHintShown = shown;
      _weatherHintHydrated = true;
    });
  }

  /// Persists the "hint dismissed" flag and immediately collapses the
  /// banner. Called by the "Got it" button on the MaterialBanner.
  Future<void> _dismissWeatherHint() async {
    setState(() => _weatherHintShown = true);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kWeatherHintShownKey, true);
  }

  /// Snapshots the current form state into a `BallisticProfilesCompanion`.
  /// Used by both Save (insert) and Update (write existing).
  BallisticProfilesCompanion _buildProfileCompanion(String name) {
    // Profile columns are NAMED with an explicit imperial unit
    // ("bulletWeightGr", "muzzleVelocityFps", ...). The controller text
    // is in the user's chosen DISPLAY unit; convert each value back to
    // canonical imperial so loading the profile from any unit setting
    // restores the same physical quantity.
    final units = context.read<UnitService>();
    double? toFps(String s) {
      final v = double.tryParse(s);
      if (v == null) return null;
      return _velocityToCanonical(v, units.unitFor(UnitCategory.velocity));
    }
    double? toIn(String s) {
      final v = double.tryParse(s);
      if (v == null) return null;
      return _smallLenToCanonical(v, units.unitFor(UnitCategory.smallLength));
    }
    int? toYd(String s) {
      final v = double.tryParse(s);
      if (v == null) return null;
      return _rangeToCanonical(v, units.unitFor(UnitCategory.range)).round();
    }
    double? toGr(String s) {
      final v = double.tryParse(s);
      if (v == null) return null;
      return _bulletWeightToCanonical(
          v, units.unitFor(UnitCategory.bulletWeight));
    }
    double? toF(String s) {
      final v = double.tryParse(s);
      if (v == null) return null;
      return _tempToCanonical(v, units.unitFor(UnitCategory.temperature));
    }
    double? toInHg(String s) {
      final v = double.tryParse(s);
      if (v == null) return null;
      return _pressureToCanonical(v, units.unitFor(UnitCategory.pressure));
    }
    double? toMph(String s) {
      final v = double.tryParse(s);
      if (v == null) return null;
      return _windToCanonical(v, units.unitFor(UnitCategory.windSpeed));
    }
    return BallisticProfilesCompanion(
      name: drift.Value(name),
      bulletWeightGr: drift.Value(toGr(_weightCtrl.text) ?? 0),
      bulletDiameterIn: drift.Value(double.tryParse(_diameterCtrl.text) ?? 0),
      ballisticCoefficient: drift.Value(double.tryParse(_bcCtrl.text) ?? 0),
      dragModel: drift.Value(_dragModel == DragModel.g7 ? 'g7' : 'g1'),
      bulletLengthIn: drift.Value(toIn(_lengthCtrl.text)),
      muzzleVelocityFps: drift.Value(toFps(_muzzleVelCtrl.text) ?? 0),
      zeroRangeYd: drift.Value(toYd(_zeroRangeCtrl.text) ?? 100),
      sightHeightIn: drift.Value(toIn(_sightHeightCtrl.text) ?? 1.5),
      twistRate: drift.Value(_twistCtrl.text.trim().isEmpty
          ? null
          : _twistCtrl.text.trim()),
      firearmId: drift.Value(_selectedFirearm?.id),
      bulletId: drift.Value(_selectedBullet?.bullet.id),
      temperatureF: drift.Value(toF(_tempCtrl.text)),
      pressureInHg: drift.Value(toInHg(_pressureCtrl.text)),
      humidityPct: drift.Value(double.tryParse(_humidityCtrl.text)),
      elevationFt: drift.Value(double.tryParse(_altitudeCtrl.text)),
      windSpeedMph: drift.Value(toMph(_windSpeedCtrl.text)),
      windDirectionDeg: drift.Value(double.tryParse(_windDirCtrl.text)),
      latitudeDeg: drift.Value(double.tryParse(_latitudeCtrl.text)),
      firingAzimuthDeg: drift.Value(double.tryParse(_shotAzimuthCtrl.text)),
      rangeIncrementYd: drift.Value(_rangeIncrement),
      rangeMinYd: drift.Value(_readClampedMinRange()),
      rangeMaxYd: drift.Value(_readClampedMaxRange()),
    );
  }

  /// Pushes a profile's stored values back into the calculator's
  /// controllers + state. Restores environment fields only when the
  /// profile actually saved them (nullable columns); otherwise leaves
  /// the existing values alone, which keeps the SharedPreferences
  /// fallback intact.
  ///
  /// All profile columns store canonical (imperial) values; the
  /// controllers display values in the user's CHOSEN unit. Convert
  /// each loaded value from canonical to display before assigning so
  /// a metric reloader sees grams / cm / m on screen even though the
  /// row was saved in grains / inches / yards.
  void _applyProfile(BallisticProfileRow p) {
    final units = context.read<UnitService>();
    setState(() {
      _activeProfile = p;
      _weightCtrl.text = _formatNumber(_bulletWeightFromCanonical(
          p.bulletWeightGr, units.unitFor(UnitCategory.bulletWeight)));
      _diameterCtrl.text = p.bulletDiameterIn.toStringAsFixed(3);
      _bcCtrl.text = p.ballisticCoefficient.toStringAsFixed(3);
      _dragModel =
          p.dragModel.toLowerCase() == 'g1' ? DragModel.g1 : DragModel.g7;
      if (p.bulletLengthIn != null) {
        _lengthCtrl.text = _formatNumber(_smallLenFromCanonical(
            p.bulletLengthIn!, units.unitFor(UnitCategory.smallLength)));
      }
      if (p.twistRate != null) _twistCtrl.text = p.twistRate!;
      _muzzleVelCtrl.text = _formatNumber(_velocityFromCanonical(
          p.muzzleVelocityFps, units.unitFor(UnitCategory.velocity)));
      _zeroRangeCtrl.text = _formatNumber(_rangeFromCanonical(
          p.zeroRangeYd.toDouble(), units.unitFor(UnitCategory.range)));
      _sightHeightCtrl.text = _formatNumber(_smallLenFromCanonical(
          p.sightHeightIn, units.unitFor(UnitCategory.smallLength)));
      if (p.temperatureF != null) {
        _tempCtrl.text = _formatNumber(_tempFromCanonical(
            p.temperatureF!, units.unitFor(UnitCategory.temperature)));
      }
      if (p.pressureInHg != null) {
        _pressureCtrl.text = _formatNumber(_pressureFromCanonical(
            p.pressureInHg!, units.unitFor(UnitCategory.pressure)));
      }
      if (p.humidityPct != null) {
        _humidityCtrl.text = _trimTrailingZeros(p.humidityPct!);
      }
      if (p.elevationFt != null) {
        _altitudeCtrl.text = _trimTrailingZeros(p.elevationFt!);
      }
      if (p.windSpeedMph != null) {
        _windSpeedCtrl.text = _formatNumber(_windFromCanonical(
            p.windSpeedMph!, units.unitFor(UnitCategory.windSpeed)));
      }
      if (p.windDirectionDeg != null) {
        _windDirCtrl.text = _trimTrailingZeros(p.windDirectionDeg!);
      }
      if (p.latitudeDeg != null) {
        _latitudeCtrl.text = _trimTrailingZeros(p.latitudeDeg!);
      }
      if (p.firingAzimuthDeg != null) {
        _shotAzimuthCtrl.text = _trimTrailingZeros(p.firingAzimuthDeg!);
      }
      _rangeIncrement = p.rangeIncrementYd;
      _rangeMinCtrl.text = _formatNumber(_rangeFromCanonical(
          p.rangeMinYd.toDouble(), units.unitFor(UnitCategory.range)));
      _rangeMaxCtrl.text = _formatNumber(_rangeFromCanonical(
          p.rangeMaxYd.toDouble(), units.unitFor(UnitCategory.range)));
    });
  }

  String _trimTrailingZeros(double v) {
    final s = v.toString();
    if (!s.contains('.')) return s;
    return s.replaceFirst(RegExp(r'\.?0+$'), '');
  }

  /// Pop-up name dialog for "Save as Profile". Returns null on cancel.
  Future<String?> _promptForProfileName({String initial = ''}) async {
    final controller = TextEditingController(text: initial);
    final formKey = GlobalKey<FormState>();
    final result = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Name this profile'),
        content: Form(
          key: formKey,
          child: TextFormField(
            controller: controller,
            autofocus: true,
            decoration: const InputDecoration(
              labelText: 'Name',
              hintText: 'e.g. 6.5 CM 140gr ELD-M Tikka',
            ),
            validator: (v) =>
                (v == null || v.trim().isEmpty) ? 'Required' : null,
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () {
              if (!formKey.currentState!.validate()) return;
              Navigator.pop(ctx, controller.text.trim());
            },
            child: const Text('Save'),
          ),
        ],
      ),
    );
    controller.dispose();
    return result;
  }

  Future<void> _onSaveAsProfile() async {
    // Capture the BuildContext-derived dependencies BEFORE the async
    // showDialog call. Lint flags otherwise — and after `_promptForProfileName`
    // returns there's no guarantee the State is still mounted.
    final repo = context.read<BallisticProfileRepository>();
    final messenger = ScaffoldMessenger.of(context);
    final name = await _promptForProfileName(
      initial: _selectedFirearm == null
          ? ''
          : '${_selectedFirearm!.name} ${_weightCtrl.text}gr',
    );
    if (name == null) return;
    final id = await repo.insert(_buildProfileCompanion(name));
    if (!mounted) return;
    final fresh = await repo.getById(id);
    if (!mounted) return;
    if (fresh != null) {
      setState(() => _activeProfile = fresh);
    }
    messenger.showSnackBar(
      SnackBar(content: Text('Profile "$name" saved.')),
    );
  }

  Future<void> _onUpdateProfile() async {
    final p = _activeProfile;
    if (p == null) return;
    final repo = context.read<BallisticProfileRepository>();
    final messenger = ScaffoldMessenger.of(context);
    await repo.update(p.id, _buildProfileCompanion(p.name));
    if (!mounted) return;
    final fresh = await repo.getById(p.id);
    if (!mounted) return;
    if (fresh != null) {
      setState(() => _activeProfile = fresh);
    }
    messenger.showSnackBar(
      SnackBar(content: Text('Profile "${p.name}" updated.')),
    );
  }

  Future<void> _onDeleteProfile() async {
    final p = _activeProfile;
    if (p == null) return;
    // Capture before any await to satisfy use_build_context_synchronously.
    final messenger = ScaffoldMessenger.of(context);
    final repo = context.read<BallisticProfileRepository>();
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete profile?'),
        content: Text(
          'This will remove "${p.name}" from your saved profiles. The '
          'calculator inputs stay where they are.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await repo.delete(p.id);
    if (!mounted) return;
    setState(() => _activeProfile = null);
    messenger.showSnackBar(
      SnackBar(content: Text('Profile "${p.name}" deleted.')),
    );
  }

  Future<void> _restoreRangePreferences() async {
    final prefs = await SharedPreferences.getInstance();
    final inc = prefs.getInt(_kRangeIncrementKey);
    final min = prefs.getInt(_kRangeMinKey);
    final max = prefs.getInt(_kRangeMaxKey);
    if (!mounted) return;
    setState(() {
      if (inc != null && inc > 0) {
        _rangeIncrement = inc;
      }
      if (min != null && min >= _kRangeMinMin && min <= _kRangeMinMax) {
        _rangeMinCtrl.text = min.toString();
      }
      if (max != null && max >= _kRangeMaxMin && max <= _kRangeMaxMax) {
        _rangeMaxCtrl.text = max.toString();
      }
    });
  }

  @override
  void dispose() {
    for (final c in [
      _diameterCtrl,
      _weightCtrl,
      _lengthCtrl,
      _bcCtrl,
      _twistCtrl,
      _muzzleVelCtrl,
      _sightHeightCtrl,
      _zeroRangeCtrl,
      _shotAzimuthCtrl,
      _targetElevationCtrl,
      _tempCtrl,
      _pressureCtrl,
      _humidityCtrl,
      _altitudeCtrl,
      _windSpeedCtrl,
      _windDirCtrl,
      _latitudeCtrl,
      _rangeMinCtrl,
      _rangeMaxCtrl,
    ]) {
      c.dispose();
    }
    // ignore: discarded_futures
    _kestrelSub?.cancel();
    super.dispose();
  }

  // ─────────────────────── Compute ───────────────────────

  void _compute() {
    setState(() {
      _error = null;
    });
    try {
      // Read the user-typed values (in their CHOSEN display unit) and
      // convert to canonical imperial before handing off to the solver.
      // The solver itself never knows about the user's unit preference;
      // unit awareness is strictly a UI-boundary concern.
      final units = context.read<UnitService>();
      // NOTE: bullet diameter is conventionally entered in inches even by
      // metric reloaders ("0.264 for 6.5mm") since cartridge designations
      // are still imperial. We do not unit-convert it.
      final diameter = _parsePos(_diameterCtrl.text, 'Bullet diameter');
      final weight = _bulletWeightToCanonical(
        _parsePos(_weightCtrl.text, 'Bullet weight'),
        units.unitFor(UnitCategory.bulletWeight),
      );
      final bc = _parsePos(_bcCtrl.text, 'BC');
      final twist = _parseOpt(_twistCtrl.text);
      // Bullet length follows the small-length unit so it converts
      // alongside sight height when the user toggles units.
      final lengthDisp = _parseOpt(_lengthCtrl.text);
      final length = lengthDisp == null
          ? null
          : _smallLenToCanonical(
              lengthDisp,
              units.unitFor(UnitCategory.smallLength),
            );

      final mv = _velocityToCanonical(
        _parsePos(_muzzleVelCtrl.text, 'Muzzle velocity'),
        units.unitFor(UnitCategory.velocity),
      );
      final sightHeight = _smallLenToCanonical(
        _parsePos(_sightHeightCtrl.text, 'Sight height'),
        units.unitFor(UnitCategory.smallLength),
      );
      final zeroRange = _rangeToCanonical(
        _parsePos(_zeroRangeCtrl.text, 'Zero range'),
        units.unitFor(UnitCategory.range),
      );
      final shotAzimuth = double.tryParse(_shotAzimuthCtrl.text.trim()) ?? 0.0;

      final temp = _tempToCanonical(
        _parseAny(_tempCtrl.text, 'Temperature'),
        units.unitFor(UnitCategory.temperature),
      );
      final pressure = _pressureToCanonical(
        _parsePos(_pressureCtrl.text, 'Pressure'),
        units.unitFor(UnitCategory.pressure),
      );
      final humidity = _parseAny(_humidityCtrl.text, 'Humidity');
      final altitude = _parseAny(_altitudeCtrl.text, 'Altitude');
      final windSpeed = _windToCanonical(
        double.tryParse(_windSpeedCtrl.text.trim()) ?? 0,
        units.unitFor(UnitCategory.windSpeed),
      );
      final windDir = double.tryParse(_windDirCtrl.text.trim()) ?? 0;
      final latitude = double.tryParse(_latitudeCtrl.text.trim()) ?? 0;
      final tgtElev = double.tryParse(_targetElevationCtrl.text.trim()) ?? 0;

      // Diagnose specific causes before building the ladder so the
      // user gets a clear, actionable error instead of a generic
      // "no ladder" message.
      final minYd = _readClampedMinRange();
      final maxYd = _readClampedMaxRange();
      if (maxYd <= minYd) {
        throw FormatException(
            'Max yardage ($maxYd yd) must be greater than '
            'Min yardage ($minYd yd). Increase the max or lower the min.');
      }
      if (_rangeIncrement <= 0) {
        throw const FormatException(
            'Pick a range increment (10, 25, 50, or 100 yd) to build '
            'the trajectory ladder.');
      }
      final ranges = _buildRangeLadder();
      if (ranges.isEmpty) {
        throw FormatException(
            'Min yardage ($minYd) + increment (${_rangeIncrement.round()} yd) '
            'overshoots max ($maxYd). Lower the increment, raise the max, '
            'or lower the min.');
      }

      final projectile = Projectile(
        diameterIn: diameter,
        weightGr: weight,
        bc: bc,
        dragModel: _dragModel,
        lengthIn: length,
        twistInches: twist,
      );
      final atmosphere = Atmosphere.station(
        tempF: temp,
        stationPressureInHg: pressure,
        humidityPct: humidity,
        altitudeFt: altitude,
      );
      final environment = Environment.fromImperial(
        atmosphere: atmosphere,
        windSpeedMph: windSpeed,
        windFromDegrees: windDir,
        shotAzimuthDegrees: shotAzimuth,
        latitudeDegrees: latitude,
        targetElevationFt: tgtElev,
      );
      final shot = ShotInputs(
        muzzleVelocityFps: mv,
        sightHeightIn: sightHeight,
        zeroRangeYards: zeroRange,
      );

      final samples = solveTrajectory(
        projectile: projectile,
        environment: environment,
        shot: shot,
        sampleRangesYards: ranges,
      );

      setState(() {
        _samples = samples;
      });
    } on FormatException catch (e) {
      setState(() {
        _error = e.message;
        _samples = const [];
      });
    } catch (e) {
      setState(() {
        _error = 'Could not solve: $e';
        _samples = const [];
      });
    }
  }

  double _parsePos(String s, String label) {
    final v = double.tryParse(s.trim());
    if (v == null || v <= 0) {
      throw FormatException('$label must be a positive number.');
    }
    return v;
  }

  double _parseAny(String s, String label) {
    final v = double.tryParse(s.trim());
    if (v == null) {
      throw FormatException('$label is invalid.');
    }
    return v;
  }

  double? _parseOpt(String s) {
    final t = s.trim();
    if (t.isEmpty) return null;
    return double.tryParse(t);
  }

  /// Build the list of sample-range yardages the solver will be called
  /// with, derived from the Min Yardage / Max Yardage / increment chip.
  ///
  /// Rules:
  /// - The first rung is `min` if `min > 0`, else the increment (the
  ///   solver rejects 0-yard ranges).
  /// - Every subsequent rung adds `increment`, stopping at or below
  ///   `max`. We always cap at `_kRangeLadderCap` rungs.
  /// - If `max <= min` we return an empty list — `_compute` surfaces a
  ///   user-facing FormatException in that case.
  List<double> _buildRangeLadder() {
    final inc = _rangeIncrement;
    if (inc <= 0) return const [];
    final minYd = _readClampedMinRange();
    final maxYd = _readClampedMaxRange();
    if (maxYd <= minYd) return const [];
    final start = minYd > 0 ? minYd : inc;
    if (start > maxYd) return const [];
    final out = <double>[];
    for (var v = start; v <= maxYd; v += inc) {
      out.add(v.toDouble());
      if (out.length >= _kRangeLadderCap) break;
    }
    return out;
  }

  // ─────────────────────── Pickers ───────────────────────

  /// Format a bullet for the dropdown:
  /// `"Hornady ELD-Match 6.5mm 140gr"`.
  String _bulletLabel(BulletRow b, ManufacturerRow mfg) {
    final wt = b.weightGr.toStringAsFixed(
        b.weightGr.truncateToDouble() == b.weightGr ? 0 : 1);
    return '${mfg.name} ${b.line} ${_caliberDisplay(b.diameterIn)} ${wt}gr';
  }

  /// Convert a bullet diameter in inches to a colloquial caliber label
  /// (e.g. `0.264` → `"6.5mm"`, `0.308` → `".308"`). Falls back to the raw
  /// inch value if the diameter doesn't match a common cartridge family.
  String _caliberDisplay(double diameterIn) {
    // Tolerance-based matching — seed values have small rounding variations.
    bool nearly(double a, double b) => (a - b).abs() < 0.0015;
    if (nearly(diameterIn, 0.172)) return '.17';
    if (nearly(diameterIn, 0.204)) return '.204';
    if (nearly(diameterIn, 0.224)) return '.224';
    if (nearly(diameterIn, 0.243)) return '6mm';
    if (nearly(diameterIn, 0.257)) return '.257';
    if (nearly(diameterIn, 0.264)) return '6.5mm';
    if (nearly(diameterIn, 0.277)) return '.277';
    if (nearly(diameterIn, 0.284)) return '7mm';
    if (nearly(diameterIn, 0.308)) return '.308';
    if (nearly(diameterIn, 0.338)) return '.338';
    if (nearly(diameterIn, 0.355) || nearly(diameterIn, 0.356)) return '9mm';
    if (nearly(diameterIn, 0.358)) return '.358';
    if (nearly(diameterIn, 0.400)) return '.40';
    if (nearly(diameterIn, 0.451) || nearly(diameterIn, 0.452)) return '.45';
    return diameterIn.toStringAsFixed(3);
  }

  void _applyBulletSelection(({BulletRow bullet, ManufacturerRow mfg}) sel) {
    final units = context.read<UnitService>();
    setState(() {
      _selectedBullet = sel;
      // Bullet diameter stays in inches by convention (cartridge
      // designations).
      _diameterCtrl.text = sel.bullet.diameterIn.toStringAsFixed(3);
      // Convert canonical grain weight to whatever the user picked.
      _weightCtrl.text = _formatNumber(_bulletWeightFromCanonical(
          sel.bullet.weightGr, units.unitFor(UnitCategory.bulletWeight)));
      // Prefer G7 BC when available (better fit for VLD-style boat-tail
      // bullets); fall back to G1 otherwise. Switch the drag model to
      // match so the BC and the curve agree.
      final g7 = sel.bullet.bcG7;
      final g1 = sel.bullet.bcG1;
      if (g7 != null) {
        _bcCtrl.text = g7.toStringAsFixed(3);
        _dragModel = DragModel.g7;
      } else if (g1 != null) {
        _bcCtrl.text = g1.toStringAsFixed(3);
        _dragModel = DragModel.g1;
      }
      // The Bullets table doesn't track length — leave the field alone so
      // the user can fill it in for stability calculations if they have
      // the spec sheet handy.
    });
  }

  void _clearBulletSelection() {
    setState(() {
      _selectedBullet = null;
    });
  }

  /// Format a firearm row for the rifle picker dropdown:
  /// `"<name> — <caliber>"`.
  String _firearmLabel(UserFirearmRow f) {
    final cal = (f.caliber ?? '').trim();
    if (cal.isEmpty) return f.name;
    return '${f.name} — $cal';
  }

  /// Parse a twist-rate string like `"1:8"`, `"8"`, or `"1 in 8"` into an
  /// integer (e.g. `8`). Returns null if no integer can be recovered.
  int? _parseTwistRate(String? raw) {
    if (raw == null || raw.trim().isEmpty) return null;
    // Pull out the last integer in the string — handles "1:8", "1 in 8",
    // "8", "8.5" (rounded to 8) consistently.
    final matches = RegExp(r'(\d+(?:\.\d+)?)').allMatches(raw);
    if (matches.isEmpty) return null;
    final last = matches.last.group(1)!;
    final asDouble = double.tryParse(last);
    if (asDouble == null) return null;
    return asDouble.round();
  }

  void _applyFirearmSelection(UserFirearmRow f) {
    final units = context.read<UnitService>();
    setState(() {
      _selectedFirearm = f;
      // Twist rate.
      final twist = _parseTwistRate(f.twistRate);
      if (twist != null) {
        _twistCtrl.text = twist.toString();
        _twistMissingFromFirearm = false;
      } else {
        _twistMissingFromFirearm = true;
      }
      // MV / zero range / sight height — only overwrite when the firearm
      // has a value, so we never blow away whatever the user typed
      // manually. Firearm columns store canonical imperial values; the
      // controllers display values in the user's chosen unit, so each
      // line below converts before assigning.
      if (f.defaultMuzzleVelocityFps != null) {
        _muzzleVelCtrl.text = _formatNumber(_velocityFromCanonical(
            f.defaultMuzzleVelocityFps!,
            units.unitFor(UnitCategory.velocity)));
      }
      if (f.defaultZeroRangeYd != null) {
        _zeroRangeCtrl.text = _formatNumber(_rangeFromCanonical(
            f.defaultZeroRangeYd!.toDouble(),
            units.unitFor(UnitCategory.range)));
      }
      if (f.sightHeightIn != null) {
        _sightHeightCtrl.text = _formatNumber(_smallLenFromCanonical(
            f.sightHeightIn!, units.unitFor(UnitCategory.smallLength)));
      }
    });
  }

  void _clearFirearmSelection() {
    setState(() {
      _selectedFirearm = null;
      _twistMissingFromFirearm = false;
    });
  }

  // ─────────────────────── Range chips ───────────────────────

  Future<void> _selectRangeIncrement(int incrementYd) async {
    setState(() {
      _rangeIncrement = incrementYd;
    });
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_kRangeIncrementKey, incrementYd);
  }

  /// Reads the start-range field, converts from the user's chosen
  /// range unit to canonical yards, clamps to [_kRangeMinMin]…
  /// [_kRangeMinMax], and falls back to [_kRangeMinDefault] if empty /
  /// non-numeric.
  int _readClampedMinRange() {
    final raw = double.tryParse(_rangeMinCtrl.text.trim());
    if (raw == null) return _kRangeMinDefault;
    final unit = context.read<UnitService>().unitFor(UnitCategory.range);
    final yd = _rangeToCanonical(raw, unit).round();
    return yd.clamp(_kRangeMinMin, _kRangeMinMax);
  }

  /// Reads the end-range field, converts from the user's chosen
  /// range unit to canonical yards, clamps to [_kRangeMaxMin]…
  /// [_kRangeMaxMax], and falls back to [_kRangeMaxDefault] if empty /
  /// non-numeric.
  int _readClampedMaxRange() {
    final raw = double.tryParse(_rangeMaxCtrl.text.trim());
    if (raw == null) return _kRangeMaxDefault;
    final unit = context.read<UnitService>().unitFor(UnitCategory.range);
    final yd = _rangeToCanonical(raw, unit).round();
    return yd.clamp(_kRangeMaxMin, _kRangeMaxMax);
  }

  /// Persists the start-range field on edit so the user's preference
  /// survives across launches.
  Future<void> _onRangeMinChanged() async {
    final minYd = _readClampedMinRange();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_kRangeMinKey, minYd);
  }

  /// Persists the end-range field on edit so the user's preference
  /// survives across launches.
  Future<void> _onRangeMaxChanged() async {
    final maxYd = _readClampedMaxRange();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_kRangeMaxKey, maxYd);
  }

  // ─────────────────────── Export ───────────────────────

  Future<void> _exportDope() async {
    if (_samples.isEmpty) return;
    final buf = StringBuffer();
    buf.writeln('LoadOut DOPE card');
    buf.writeln('-----------------');
    buf.writeln('MV: ${_muzzleVelCtrl.text} fps');
    buf.writeln('Bullet: ${_weightCtrl.text} gr ${_diameterCtrl.text}" '
        '(${_dragModel.short} BC ${_bcCtrl.text})');
    buf.writeln('Zero: ${_zeroRangeCtrl.text} yd, '
        'sight ${_sightHeightCtrl.text}" above bore');
    buf.writeln('Twist: ${_twistCtrl.text}"');
    buf.writeln('Wind: ${_windSpeedCtrl.text} mph from '
        '${_windDirCtrl.text}°');
    buf.writeln('Temp: ${_tempCtrl.text}°F  '
        'Pressure: ${_pressureCtrl.text} inHg  '
        'RH: ${_humidityCtrl.text}%');
    buf.writeln('');
    buf.writeln(
        'Range   Drop      Wind     Velocity  Energy  ToF    Mach');
    for (final s in _samples) {
      buf.writeln('${s.rangeYards.toStringAsFixed(0).padLeft(4)} yd  '
          '${_fmtAngle(s.dropInches, s.rangeYards).padLeft(8)}  '
          '${_fmtAngle(s.windDriftInches, s.rangeYards).padLeft(7)}  '
          '${s.velocityFps.toStringAsFixed(0).padLeft(6)} fps  '
          '${s.energyFtLb.toStringAsFixed(0).padLeft(5)}  '
          '${s.timeSec.toStringAsFixed(2).padLeft(5)}s  '
          '${s.machNumber.toStringAsFixed(2)}');
    }
    await Clipboard.setData(ClipboardData(text: buf.toString()));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('DOPE card copied to clipboard')),
    );
  }

  String _fmtAngle(double inches, double yards) {
    switch (_unit) {
      case AngleUnit.inches:
        return '${inches.toStringAsFixed(1)}"';
      case AngleUnit.moa:
        if (yards <= 0) return '—';
        return '${inchesToMoaAtYards(inches, yards).toStringAsFixed(1)} M';
      case AngleUnit.mil:
        if (yards <= 0) return '—';
        return '${inchesToMilAtYards(inches, yards).toStringAsFixed(2)} mil';
    }
  }

  // ─────────────────────── Build ───────────────────────

  @override
  Widget build(BuildContext context) {
    final showWeatherHint = _weatherHintHydrated && !_weatherHintShown;
    // Subscribe to UnitService so the screen rebuilds when the user
    // toggles units in Settings, then convert any controller text whose
    // category just changed.
    final units = context.watch<UnitService>();
    _syncDisplayedUnits(units);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Ballistics Calculator'),
      ),
      body: ProGate(
        feature: 'Ballistics Calculator',
        child: Column(
          children: [
            if (showWeatherHint) _weatherHintBanner(),
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _profilePickerCard(),
                    const SizedBox(height: 8),
                    _firearmSection(),
                    const SizedBox(height: 8),
                    _projectileSection(),
                    const SizedBox(height: 8),
                    _muzzleZeroSection(),
                    const SizedBox(height: 8),
                    _environmentSection(),
                    const SizedBox(height: 8),
                    _outputSection(),
                    const SizedBox(height: 16),
                    _DisclaimerFooter(),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ─────────────────────── Sections ───────────────────────

  /// Slim card at the top of the screen that lets the user pick / save
  /// a [BallisticProfileRow]. Live-streams from [BallisticProfileRepository]
  /// so newly-saved profiles appear in the dropdown without manual
  /// refresh.
  Widget _profilePickerCard() {
    final theme = Theme.of(context);
    return Card(
      clipBehavior: Clip.antiAlias,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
        child: StreamBuilder<List<BallisticProfileRow>>(
          stream: _profilesStream,
          builder: (context, snap) {
            final profiles = snap.data ?? const <BallisticProfileRow>[];
            // Re-resolve _activeProfile by id whenever the stream emits
            // so an Update keeps the dropdown selection correct.
            BallisticProfileRow? selected;
            if (_activeProfile != null) {
              for (final p in profiles) {
                if (p.id == _activeProfile!.id) {
                  selected = p;
                  break;
                }
              }
            }
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 10, vertical: 6),
                      decoration: BoxDecoration(
                        color: theme.colorScheme.primary
                            .withValues(alpha: 0.12),
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(
                          color: theme.colorScheme.primary
                              .withValues(alpha: 0.35),
                        ),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.bookmark_outline,
                              size: 14, color: theme.colorScheme.primary),
                          const SizedBox(width: 6),
                          Text(
                            'Profiles',
                            style: theme.textTheme.labelLarge?.copyWith(
                              color: theme.colorScheme.primary,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ],
                      ),
                    ),
                    const Spacer(),
                    if (selected == null)
                      Text(
                        'Unsaved',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                  ],
                ),
                const SizedBox(height: 8),
                if (profiles.isEmpty)
                  Text(
                    'Save the current inputs as a named profile to switch '
                    'between rifles or loads in one tap.',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  )
                else
                  DropdownButtonFormField<int?>(
                    initialValue: selected?.id,
                    isExpanded: true,
                    decoration: const InputDecoration(
                      labelText: 'Active Profile',
                      isDense: true,
                    ),
                    items: <DropdownMenuItem<int?>>[
                      const DropdownMenuItem<int?>(
                        value: null,
                        child: Text('— New / Unsaved —'),
                      ),
                      for (final p in profiles)
                        DropdownMenuItem<int?>(
                          value: p.id,
                          child: Text(
                            p.name,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                    ],
                    onChanged: (id) {
                      if (id == null) {
                        setState(() => _activeProfile = null);
                        return;
                      }
                      final picked = profiles
                          .firstWhere((p) => p.id == id, orElse: () => profiles.first);
                      _applyProfile(picked);
                    },
                  ),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    OutlinedButton.icon(
                      icon: const Icon(Icons.save_outlined, size: 16),
                      label: const Text('Save as Profile'),
                      onPressed: _onSaveAsProfile,
                    ),
                    OutlinedButton.icon(
                      icon: const Icon(Icons.sync_outlined, size: 16),
                      label: const Text('Update'),
                      onPressed:
                          selected == null ? null : _onUpdateProfile,
                    ),
                    OutlinedButton.icon(
                      icon: const Icon(Icons.delete_outline, size: 16),
                      label: const Text('Delete'),
                      onPressed:
                          selected == null ? null : _onDeleteProfile,
                    ),
                  ],
                ),
              ],
            );
          },
        ),
      ),
    );
  }

  Widget _firearmSection() {
    return _SectionCard(
      title: 'Rifle / Firearm',
      icon: Icons.handshake_outlined,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          FutureBuilder<List<UserFirearmRow>>(
            future: _firearmsFuture,
            builder: (context, snap) {
              if (snap.connectionState == ConnectionState.waiting) {
                return const Padding(
                  padding: EdgeInsets.symmetric(vertical: 8),
                  child: LinearProgressIndicator(),
                );
              }
              final firearms = snap.data ?? const <UserFirearmRow>[];
              if (firearms.isEmpty) {
                return Text(
                  'No firearms saved yet. Add one on the Firearms tab to '
                  'pre-fill twist, MV, zero range, and sight height here.',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                        fontStyle: FontStyle.italic,
                      ),
                );
              }
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Autocomplete<UserFirearmRow>(
                    initialValue: TextEditingValue(
                      text: _selectedFirearm == null
                          ? ''
                          : _firearmLabel(_selectedFirearm!),
                    ),
                    displayStringForOption: _firearmLabel,
                    optionsBuilder: (te) {
                      final q = te.text.trim().toLowerCase();
                      if (q.isEmpty) return firearms;
                      // Tokenized match: every whitespace-separated word
                      // in the query must appear somewhere in the label
                      // (e.g. "tikka 6.5" matches "Tikka T3x — 6.5 CM").
                      final tokens = q.split(RegExp(r'\s+'))
                          .where((t) => t.isNotEmpty)
                          .toList(growable: false);
                      if (tokens.isEmpty) return firearms;
                      return firearms.where((f) {
                        final label = _firearmLabel(f).toLowerCase();
                        for (final t in tokens) {
                          if (!label.contains(t)) return false;
                        }
                        return true;
                      });
                    },
                    fieldViewBuilder: (
                      context,
                      textCtrl,
                      focusNode,
                      onFieldSubmitted,
                    ) {
                      return TextField(
                        controller: textCtrl,
                        focusNode: focusNode,
                        autocorrect: false,
                        enableSuggestions: false,
                        textCapitalization: TextCapitalization.none,
                        // `readOnly: true` would block typing entirely.
                        // We keep typing on for filtering, but on tap
                        // with an empty field we nudge a tiny no-op so
                        // Flutter's Autocomplete recomputes options
                        // and shows the panel.
                        onTap: () {
                          if (textCtrl.text.isEmpty) {
                            // Bounce a space → empty to force the
                            // options list to surface on focus.
                            textCtrl.text = ' ';
                            textCtrl.text = '';
                          }
                        },
                        decoration: InputDecoration(
                          labelText: 'Pick a firearm',
                          // Chevron makes it visually obvious this is a
                          // tap-to-browse dropdown, not a search box.
                          prefixIcon: const Icon(Icons.expand_more),
                          helperText:
                              'Pre-fills twist, MV, zero range, sight height',
                          suffixIcon: textCtrl.text.isEmpty
                              ? null
                              : IconButton(
                                  icon: const Icon(Icons.close),
                                  tooltip: 'Clear',
                                  onPressed: () {
                                    textCtrl.clear();
                                    _clearFirearmSelection();
                                  },
                                ),
                        ),
                        onSubmitted: (_) => onFieldSubmitted(),
                      );
                    },
                    onSelected: _applyFirearmSelection,
                    optionsViewBuilder: (context, onSelected, options) {
                      return Align(
                        alignment: Alignment.topLeft,
                        child: Material(
                          elevation: 4,
                          child: ConstrainedBox(
                            constraints:
                                const BoxConstraints(maxHeight: 360),
                            child: ListView.builder(
                              shrinkWrap: true,
                              padding: EdgeInsets.zero,
                              itemCount: options.length,
                              itemBuilder: (context, i) {
                                final f = options.elementAt(i);
                                return ListTile(
                                  dense: true,
                                  title: Text(_firearmLabel(f)),
                                  onTap: () => onSelected(f),
                                );
                              },
                            ),
                          ),
                        ),
                      );
                    },
                  ),
                  if (_twistMissingFromFirearm) ...[
                    const SizedBox(height: 6),
                    Text(
                      'Twist not set on this firearm — enter manually.',
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                            color: Theme.of(context)
                                .colorScheme
                                .onSurfaceVariant,
                          ),
                    ),
                  ],
                ],
              );
            },
          ),
        ],
      ),
    );
  }

  Widget _projectileSection() {
    final units = context.watch<UnitService>();
    final smallLen = unitDisplayLabel(units.unitFor(UnitCategory.smallLength));
    final bulletWt = unitDisplayLabel(units.unitFor(UnitCategory.bulletWeight));
    return _SectionCard(
      title: 'Projectile',
      icon: Icons.album_outlined,
      child: Column(
        children: [
          _bulletPicker(),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _diameterCtrl,
                  keyboardType: const TextInputType.numberWithOptions(
                      decimal: true),
                  decoration: const InputDecoration(
                    // Diameter stays in inches by convention — cartridge
                    // designations ("6.5mm", ".308") still map to bullet
                    // diameters in inches even in metric workflows.
                    labelText: 'Diameter (in)',
                    helperText: 'e.g. 0.264 for 6.5mm',
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: TextField(
                  controller: _weightCtrl,
                  keyboardType: const TextInputType.numberWithOptions(
                      decimal: true),
                  decoration: InputDecoration(
                    labelText: 'Weight ($bulletWt)',
                    suffixText: bulletWt,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _lengthCtrl,
                  keyboardType: const TextInputType.numberWithOptions(
                      decimal: true),
                  decoration: InputDecoration(
                    labelText: 'Length ($smallLen, optional)',
                    helperText: 'For Miller stability calc',
                    suffixText: smallLen,
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: TextField(
                  controller: _twistCtrl,
                  keyboardType: const TextInputType.numberWithOptions(
                      decimal: true),
                  decoration: const InputDecoration(
                    labelText: 'Twist (1:in)',
                    helperText: 'e.g. 8 for 1:8',
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _bcCtrl,
                  keyboardType: const TextInputType.numberWithOptions(
                      decimal: true),
                  decoration: const InputDecoration(
                    labelText: 'BC',
                    helperText: 'In the chosen drag-model family',
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: DropdownButtonFormField<DragModel>(
                  initialValue: _dragModel,
                  isExpanded: true,
                  decoration: const InputDecoration(
                    labelText: 'Drag function',
                  ),
                  items: [
                    for (final m in DragModel.values)
                      DropdownMenuItem(
                        value: m,
                        child: Text(m.label, overflow: TextOverflow.ellipsis),
                      ),
                  ],
                  onChanged: (v) {
                    if (v != null) setState(() => _dragModel = v);
                  },
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _bulletPicker() {
    return FutureBuilder<List<({BulletRow bullet, ManufacturerRow mfg})>>(
      future: _bulletsFuture,
      builder: (context, snap) {
        if (snap.connectionState == ConnectionState.waiting) {
          return const Padding(
            padding: EdgeInsets.symmetric(vertical: 8),
            child: LinearProgressIndicator(),
          );
        }
        final entries = snap.data ?? const [];
        return Row(
          children: [
            Expanded(
              child: Autocomplete<({BulletRow bullet, ManufacturerRow mfg})>(
                initialValue: TextEditingValue(
                  text: _selectedBullet == null
                      ? ''
                      : _bulletLabel(_selectedBullet!.bullet,
                          _selectedBullet!.mfg),
                ),
                displayStringForOption: (e) =>
                    _bulletLabel(e.bullet, e.mfg),
                optionsBuilder: (te) {
                  final q = te.text.trim().toLowerCase();
                  if (q.isEmpty) return entries;
                  // Tokenize on whitespace and require EVERY token to
                  // appear somewhere in the label. This is what lets a
                  // search like "berger 109" find
                  // "Berger Long Range Hybrid Target 6mm 109gr" — the
                  // tokens don't have to be adjacent in the label.
                  final tokens = q.split(RegExp(r'\s+'))
                      .where((t) => t.isNotEmpty)
                      .toList(growable: false);
                  if (tokens.isEmpty) return entries;
                  return entries.where((e) {
                    final label =
                        _bulletLabel(e.bullet, e.mfg).toLowerCase();
                    for (final t in tokens) {
                      if (!label.contains(t)) return false;
                    }
                    return true;
                  });
                },
                fieldViewBuilder: (
                  context,
                  textCtrl,
                  focusNode,
                  onFieldSubmitted,
                ) {
                  return TextField(
                    controller: textCtrl,
                    focusNode: focusNode,
                    autocorrect: false,
                    enableSuggestions: false,
                    textCapitalization: TextCapitalization.none,
                    decoration: InputDecoration(
                      labelText: 'Pick from catalog',
                      prefixIcon: const Icon(Icons.search),
                      suffixIcon: textCtrl.text.isEmpty
                          ? null
                          : IconButton(
                              icon: const Icon(Icons.close),
                              tooltip: 'Clear',
                              onPressed: () {
                                textCtrl.clear();
                                _clearBulletSelection();
                              },
                            ),
                    ),
                    onSubmitted: (_) => onFieldSubmitted(),
                  );
                },
                onSelected: _applyBulletSelection,
                optionsViewBuilder: (context, onSelected, options) {
                  return Align(
                    alignment: Alignment.topLeft,
                    child: Material(
                      elevation: 4,
                      child: ConstrainedBox(
                        constraints:
                            const BoxConstraints(maxHeight: 360),
                        child: ListView.builder(
                          shrinkWrap: true,
                          padding: EdgeInsets.zero,
                          itemCount: options.length,
                          itemBuilder: (context, i) {
                            final e = options.elementAt(i);
                            return ListTile(
                              dense: true,
                              title: Text(_bulletLabel(e.bullet, e.mfg)),
                              onTap: () => onSelected(e),
                            );
                          },
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),
            const SizedBox(width: 8),
            TextButton.icon(
              onPressed:
                  _selectedBullet == null ? null : _clearBulletSelection,
              icon: const Icon(Icons.refresh, size: 18),
              label: const Text('Clear'),
            ),
          ],
        );
      },
    );
  }

  Widget _muzzleZeroSection() {
    final units = context.watch<UnitService>();
    final velUnit = unitDisplayLabel(units.unitFor(UnitCategory.velocity));
    final smallLen = unitDisplayLabel(units.unitFor(UnitCategory.smallLength));
    final rangeUnit = unitDisplayLabel(units.unitFor(UnitCategory.range));
    return _SectionCard(
      title: 'Muzzle / Zero',
      icon: Icons.center_focus_strong_outlined,
      child: Column(
        children: [
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _muzzleVelCtrl,
                  keyboardType: const TextInputType.numberWithOptions(
                      decimal: true),
                  decoration: InputDecoration(
                    labelText: 'Muzzle velocity ($velUnit)',
                    suffixText: velUnit,
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: TextField(
                  controller: _sightHeightCtrl,
                  keyboardType: const TextInputType.numberWithOptions(
                      decimal: true),
                  decoration: InputDecoration(
                    labelText: 'Sight height ($smallLen)',
                    suffixText: smallLen,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _zeroRangeCtrl,
                  keyboardType: const TextInputType.numberWithOptions(
                      decimal: true),
                  decoration: InputDecoration(
                    labelText: 'Zero range ($rangeUnit)',
                    suffixText: rangeUnit,
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: TextField(
                  controller: _shotAzimuthCtrl,
                  keyboardType: const TextInputType.numberWithOptions(
                      decimal: true, signed: true),
                  decoration: const InputDecoration(
                    labelText: 'Shot azimuth (°)',
                    // Beginner-friendly: spell out the compass values
                    // and call out that this is for Coriolis. Most
                    // shooters under 1000 yd can leave this at 0.
                    helperText:
                        'Compass direction of the shot: 0=N, 90=E, '
                        '180=S, 270=W. Used for Coriolis at long range '
                        '— leave 0 if unsure.',
                    helperMaxLines: 3,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _targetElevationCtrl,
            keyboardType: const TextInputType.numberWithOptions(
                decimal: true, signed: true),
            decoration: const InputDecoration(
              labelText: 'Target elevation Δ (ft)',
              helperText: 'Positive = uphill',
            ),
          ),
        ],
      ),
    );
  }

  // ─────────────────────── Weather fetch ───────────────────────

  /// Pro-gated handler wired to the cloud icon on the Environment
  /// section's header. Walks through the gate, then the location +
  /// network handshake in [WeatherService], then writes the
  /// resulting fields into the controllers. Surface every failure as
  /// a friendly snackbar; never let an exception crash the screen.
  Future<void> _onUseMyLocation() async {
    if (!await ensurePro(context)) return;
    if (!mounted) return;
    // Capture the messenger BEFORE the async fetch so we don't trip
    // `use_build_context_synchronously` after awaits.
    final messenger = ScaffoldMessenger.of(context);
    final units = context.read<UnitService>();
    setState(() => _weatherFetching = true);
    try {
      final result = await WeatherService().fetchForCurrentLocation();
      if (!mounted) return;
      // Weather service returns canonical imperial values; convert to
      // the user's chosen display unit before assigning to controllers.
      setState(() {
        _tempCtrl.text = _formatNumber(_tempFromCanonical(
            result.tempF, units.unitFor(UnitCategory.temperature)));
        _pressureCtrl.text = _formatNumber(_pressureFromCanonical(
            result.stationPressureInHg,
            units.unitFor(UnitCategory.pressure)));
        _humidityCtrl.text = result.humidityPct.toStringAsFixed(0);
        _altitudeCtrl.text = result.elevationFt.toStringAsFixed(0);
        _windSpeedCtrl.text = _formatNumber(_windFromCanonical(
            result.windSpeedMph, units.unitFor(UnitCategory.windSpeed)));
        _windDirCtrl.text = result.windDirectionDeg.toStringAsFixed(0);
        _weatherFetchedAt = result.fetchedAt;
      });
      messenger.showSnackBar(
        SnackBar(
          content: Text('Weather updated · ${_formatClock(result.fetchedAt)}'),
        ),
      );
    } on WeatherFetchException catch (e) {
      if (!mounted) return;
      messenger.showSnackBar(SnackBar(content: Text(e.userMessage)));
    } catch (_) {
      if (!mounted) return;
      messenger.showSnackBar(
        const SnackBar(
            content: Text('Couldn\'t fetch weather. Try again later.')),
      );
    } finally {
      if (mounted) setState(() => _weatherFetching = false);
    }
  }

  /// Format a `DateTime` as a 12-hour clock with AM/PM (e.g.
  /// `"2:34 PM"`). Used by the "Updated …" subtitle and snackbar.
  String _formatClock(DateTime t) {
    final hour24 = t.hour;
    final hour12 = hour24 == 0 ? 12 : (hour24 > 12 ? hour24 - 12 : hour24);
    final mm = t.minute.toString().padLeft(2, '0');
    final period = hour24 < 12 ? 'AM' : 'PM';
    return '$hour12:$mm $period';
  }

  /// Trailing widget rendered in the Environment section's header. A
  /// small "Use my location" cloud icon button with a "PRO" chip next
  /// to it so non-Pro users see what they'd be unlocking. The button
  /// flips to a spinner while the fetch is in flight.
  ///
  /// When a Kestrel is connected and [_useKestrel] is true, the cloud
  /// fetch button is replaced by a "Stop using Kestrel" pill — Kestrel
  /// readings are local + faster + more accurate than open-meteo, so
  /// we deliberately steer the user toward keeping that on once paired.
  Widget _environmentTrailing() {
    final theme = Theme.of(context);
    final isPro = context.watch<EntitlementNotifier>().isPro;
    final kestrel = context.watch<KestrelService>();
    if (_useKestrel && kestrel.device != null) {
      return TextButton.icon(
        onPressed: _onStopUsingKestrel,
        icon: const Icon(Icons.bluetooth_connected, size: 16),
        label: const Text('Stop using Kestrel'),
        style: TextButton.styleFrom(
          padding:
              const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        ),
      );
    }
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (!isPro)
          Container(
            padding:
                const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
            decoration: BoxDecoration(
              color: theme.colorScheme.primary.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(6),
              border: Border.all(
                color: theme.colorScheme.primary.withValues(alpha: 0.5),
              ),
            ),
            child: Text(
              'PRO',
              style: theme.textTheme.labelSmall?.copyWith(
                color: theme.colorScheme.primary,
                fontWeight: FontWeight.w700,
                letterSpacing: 0.5,
              ),
            ),
          ),
        // Show "Use Kestrel" when one is paired but the user hasn't
        // opted in yet — surfaces the better data source the moment
        // they have it.
        if (isPro && kestrel.device != null && !_useKestrel)
          IconButton(
            tooltip: 'Pull live readings from Kestrel',
            icon: const Icon(Icons.bluetooth, size: 20),
            onPressed: _onStartUsingKestrel,
          ),
        IconButton(
          tooltip: 'Use my location',
          onPressed: _weatherFetching ? null : _onUseMyLocation,
          icon: _weatherFetching
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.cloud_outlined),
        ),
      ],
    );
  }

  /// Subscribe to the live Kestrel feed and pipe readings into the
  /// environment controllers. Pro-gated. No-op if no Kestrel is
  /// connected — the UI only surfaces this affordance when the device
  /// is present.
  Future<void> _onStartUsingKestrel() async {
    if (!await ensurePro(context)) return;
    if (!mounted) return;
    final kestrel = context.read<KestrelService>();
    if (kestrel.device == null) return;
    await _kestrelSub?.cancel();
    _kestrelSub = kestrel.readings.listen(_applyKestrelReading);
    setState(() => _useKestrel = true);
    // Apply the latest reading immediately so the UI doesn't sit on
    // stale values until the next 1-Hz tick.
    final latest = kestrel.lastReading;
    if (latest != null) {
      _applyKestrelReading(latest);
    }
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Pulling live data from Kestrel.')),
    );
  }

  /// Cancel the live subscription. Leaves the existing controller
  /// values where they are; the user can re-enter manually or pull
  /// open-meteo from here.
  Future<void> _onStopUsingKestrel() async {
    await _kestrelSub?.cancel();
    _kestrelSub = null;
    if (!mounted) return;
    setState(() => _useKestrel = false);
  }

  void _applyKestrelReading(KestrelReading r) {
    if (!mounted) return;
    setState(() {
      _tempCtrl.text = r.tempF.toStringAsFixed(1);
      _pressureCtrl.text = r.stationPressureInHg.toStringAsFixed(2);
      _humidityCtrl.text = r.humidityPct.toStringAsFixed(0);
      _windSpeedCtrl.text = r.windSpeedMph.toStringAsFixed(1);
      _windDirCtrl.text = r.windDirectionDeg.toStringAsFixed(0);
      _weatherFetchedAt = r.receivedAt;
    });
  }

  /// First-run MaterialBanner above the ballistics body. Tells Pro
  /// (and prospective Pro) users where the new "Use my location"
  /// affordance lives. Suppressed once the user dismisses it; the
  /// `_kWeatherHintShownKey` SharedPreference makes the dismissal
  /// stick across launches.
  Widget _weatherHintBanner() {
    final theme = Theme.of(context);
    return Material(
      color: theme.colorScheme.primaryContainer,
      elevation: 0,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 12, 12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(
              Icons.cloud_outlined,
              size: 18,
              color: theme.colorScheme.onPrimaryContainer,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'New: Pull Current Weather',
                    style: theme.textTheme.titleSmall?.copyWith(
                      color: theme.colorScheme.onPrimaryContainer,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    'Pro users can pull current weather from their location. '
                    'Tap the cloud icon in Environment.',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onPrimaryContainer,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            TextButton(
              style: TextButton.styleFrom(
                foregroundColor: theme.colorScheme.onPrimaryContainer,
              ),
              onPressed: () {
                // ignore: discarded_futures
                _dismissWeatherHint();
              },
              child: const Text('Got it'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _environmentSection() {
    final updatedAt = _weatherFetchedAt;
    final units = context.watch<UnitService>();
    final tempLabel = unitDisplayLabel(units.unitFor(UnitCategory.temperature));
    final pressureLabel =
        unitDisplayLabel(units.unitFor(UnitCategory.pressure));
    final windLabel = unitDisplayLabel(units.unitFor(UnitCategory.windSpeed));
    final subtitle = _useKestrel
        ? (updatedAt == null
            ? 'Kestrel · waiting for first reading'
            : 'Kestrel · updated ${_formatClock(updatedAt)}')
        : (updatedAt == null
            ? null
            : 'Updated ${_formatClock(updatedAt)}');
    return _SectionCard(
      title: 'Environment',
      icon: Icons.air_outlined,
      subtitle: subtitle,
      trailing: _environmentTrailing(),
      child: Column(
        children: [
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _tempCtrl,
                  keyboardType: const TextInputType.numberWithOptions(
                      decimal: true, signed: true),
                  decoration: InputDecoration(
                    labelText: 'Temperature ($tempLabel)',
                    suffixText: tempLabel,
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: TextField(
                  controller: _pressureCtrl,
                  keyboardType: const TextInputType.numberWithOptions(
                      decimal: true),
                  decoration: InputDecoration(
                    labelText: 'Pressure ($pressureLabel)',
                    helperText: 'Station, not corrected',
                    suffixText: pressureLabel,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _humidityCtrl,
                  keyboardType: const TextInputType.numberWithOptions(
                      decimal: true),
                  decoration: const InputDecoration(
                    labelText: 'Humidity (%)',
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: TextField(
                  controller: _altitudeCtrl,
                  keyboardType: const TextInputType.numberWithOptions(
                      decimal: true, signed: true),
                  decoration: const InputDecoration(
                    // Elevation stays in feet — the solver normalizes
                    // station pressure with feet, and altitude has no
                    // dedicated unit category in the Settings list.
                    labelText: 'Elevation (ft)',
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _windSpeedCtrl,
                  keyboardType: const TextInputType.numberWithOptions(
                      decimal: true),
                  decoration: InputDecoration(
                    labelText: 'Wind ($windLabel)',
                    suffixText: windLabel,
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: TextField(
                  controller: _windDirCtrl,
                  keyboardType: const TextInputType.numberWithOptions(
                      decimal: true),
                  decoration: const InputDecoration(
                    labelText: 'Wind from (°)',
                    helperText: '0=tail, 90=right',
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _latitudeCtrl,
            keyboardType: const TextInputType.numberWithOptions(
                decimal: true, signed: true),
            decoration: const InputDecoration(
              labelText: 'Latitude (°N)',
              helperText: 'Used by Coriolis',
            ),
          ),
        ],
      ),
    );
  }

  Widget _outputSection() {
    final theme = Theme.of(context);
    final units = context.watch<UnitService>();
    final rangeUnit = unitDisplayLabel(units.unitFor(UnitCategory.range));
    return _SectionCard(
      title: 'Output',
      icon: Icons.table_rows_outlined,
      initiallyExpanded: true,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Range-increment chip group on its own line.
          _rangeIncrementChips(),
          const SizedBox(height: 12),
          // Min range on its own line. Unit-aware so the user enters
          // the value in their chosen range unit; stored canonical
          // value is yards.
          TextField(
            controller: _rangeMinCtrl,
            keyboardType: const TextInputType.numberWithOptions(
                decimal: true),
            // Decimals allowed because metric users may want
            // sub-meter precision; we still .round() to int yards
            // when feeding the solver.
            autocorrect: false,
            enableSuggestions: false,
            decoration: InputDecoration(
              labelText: 'Min Range',
              helperText:
                  'Trajectory ladder starts here (0 = first increment)',
              suffixText: rangeUnit,
            ),
            onSubmitted: (_) => _onRangeMinChanged(),
            onEditingComplete: _onRangeMinChanged,
          ),
          const SizedBox(height: 12),
          // Max range on its own line.
          TextField(
            controller: _rangeMaxCtrl,
            keyboardType: const TextInputType.numberWithOptions(
                decimal: true),
            autocorrect: false,
            enableSuggestions: false,
            decoration: InputDecoration(
              labelText: 'Max Range',
              helperText: 'Trajectory ladder ends at or before this range',
              suffixText: rangeUnit,
            ),
            onSubmitted: (_) => _onRangeMaxChanged(),
            onEditingComplete: _onRangeMaxChanged,
          ),
          const SizedBox(height: 12),
          // Angle unit selector on its own line.
          SegmentedButton<AngleUnit>(
            segments: const [
              ButtonSegment(
                value: AngleUnit.inches,
                label: Text('Inch'),
              ),
              ButtonSegment(
                value: AngleUnit.moa,
                label: Text('MOA'),
              ),
              ButtonSegment(
                value: AngleUnit.mil,
                label: Text('Mil'),
              ),
            ],
            selected: {_unit},
            onSelectionChanged: (s) {
              setState(() => _unit = s.first);
            },
            showSelectedIcon: false,
          ),
          const SizedBox(height: 20),
          // Prominent full-width Calculate button below all inputs and
          // above the chart / DOPE table. This is the primary CTA on the
          // screen, so we lean into the FilledButton "primary brass"
          // styling rather than burying it in the form.
          FilledButton.icon(
            onPressed: _compute,
            icon: const Icon(Icons.calculate_outlined),
            label: const Text('Calculate Trajectory'),
          ),
          if (_error != null) ...[
            const SizedBox(height: 12),
            Card(
              color: theme.colorScheme.errorContainer,
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Text(
                  _error!,
                  style: TextStyle(
                    color: theme.colorScheme.onErrorContainer,
                  ),
                ),
              ),
            ),
          ],
          const SizedBox(height: 16),
          if (_samples.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 24),
              child: Text(
                'Run "Calculate Trajectory" to generate the drop table.',
                textAlign: TextAlign.center,
                style: theme.textTheme.bodyMedium?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                      fontStyle: FontStyle.italic,
                    ),
              ),
            )
          else ...[
            // DOPE table first — most reloaders treat this as their
            // "ballistic chart" (it's what they print on a card and
            // tape to the rifle). On desktop widths we lift the chart
            // alongside the table so the user can see both at a glance;
            // narrower screens stack them vertically as before.
            if (Breakpoints.isDesktop(context))
              IntrinsicHeight(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      flex: 5,
                      child: _DopeTable(samples: _samples, unit: _unit),
                    ),
                    const SizedBox(width: 16),
                    Expanded(
                      flex: 4,
                      child: TrajectoryChart(samples: _samples),
                    ),
                  ],
                ),
              )
            else ...[
              _DopeTable(samples: _samples, unit: _unit),
              const SizedBox(height: 16),
              TrajectoryChart(samples: _samples),
            ],
            const SizedBox(height: 16),
            OutlinedButton.icon(
              onPressed: _exportDope,
              icon: const Icon(Icons.copy_outlined),
              label: const Text('Export DOPE card to clipboard'),
            ),
          ],
        ],
      ),
    );
  }

  Widget _rangeIncrementChips() {
    // The range-increment is stored in canonical yards (the solver
    // contract), so the chips also expose imperial values. We label
    // them with the user's chosen range unit only when imperial; when
    // the user is on metric the chips still represent yard increments
    // because the underlying range-ladder math is yard-based — the
    // displayed Min/Max above already convert. Showing "yd" verbatim
    // would be misleading on metric, so we render a unit-less number
    // and let the helper text on the range fields explain context.
    const presets = [10, 25, 50, 100];
    final units = context.watch<UnitService>();
    final isImperialRange =
        units.unitFor(UnitCategory.range) == unitYd;
    return Align(
      alignment: Alignment.centerLeft,
      child: Wrap(
        spacing: 6,
        runSpacing: 6,
        children: [
          for (final inc in presets)
            ChoiceChip(
              label: Text(isImperialRange ? '$inc yd' : '$inc'),
              selected: _rangeIncrement == inc,
              onSelected: (_) => _selectRangeIncrement(inc),
            ),
        ],
      ),
    );
  }
}

// ─────────────────────── Section card ───────────────────────

class _SectionCard extends StatelessWidget {
  const _SectionCard({
    required this.title,
    required this.icon,
    required this.child,
    this.initiallyExpanded = true,
    this.subtitle,
    this.trailing,
  });

  final String title;
  final IconData icon;
  final Widget child;
  final bool initiallyExpanded;

  /// Optional small text rendered under the title pill (e.g.
  /// "Updated 2:34 PM" once the user has fetched weather). When null
  /// the row collapses cleanly.
  final String? subtitle;

  /// Optional trailing widget rendered to the right of the title pill
  /// (e.g. the "Use my location" cloud icon on the Environment
  /// section). When null the [ExpansionTile]'s own chevron occupies
  /// the trailing slot as usual.
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      clipBehavior: Clip.antiAlias,
      child: ExpansionTile(
        initiallyExpanded: initiallyExpanded,
        tilePadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
        // Top padding here is load-bearing: without it, the floating
        // label of the first TextField in each section visually clips
        // behind the bottom edge of the title row above. Material's
        // floating-label position sits half-inside / half-above the
        // input's top border, so the label needs ~8 px of breathing
        // room between the section header and the first field.
        childrenPadding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
        title: Row(
          children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              decoration: BoxDecoration(
                color: theme.colorScheme.primary.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(
                  color: theme.colorScheme.primary.withValues(alpha: 0.35),
                ),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(icon, size: 14, color: theme.colorScheme.primary),
                  const SizedBox(width: 6),
                  Text(
                    title,
                    style: theme.textTheme.labelLarge?.copyWith(
                      color: theme.colorScheme.primary,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
            ),
            if (trailing != null) ...[
              const Spacer(),
              trailing!,
            ],
          ],
        ),
        subtitle: subtitle == null
            ? null
            : Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Text(
                  subtitle!,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
        children: [child],
      ),
    );
  }
}

// ─────────────────────── DOPE table ───────────────────────

class _DopeTable extends StatelessWidget {
  const _DopeTable({required this.samples, required this.unit});

  final List<TrajectorySample> samples;
  final AngleUnit unit;

  /// Drop / wind reading at the row's [yards] range. The screen-wide
  /// segmented button selects whether the linear inches are rendered
  /// raw, in MOA, or in mils — independent of the global Settings
  /// units (per the requirement that this picker is per-output-row,
  /// not a global preference).
  ///
  /// When the user picked `inches` we additionally honor the global
  /// small-length unit so a metric reloader sees centimeters instead
  /// of inches in this column.
  String _fmtAngle(BuildContext context, double inches, double yards) {
    switch (unit) {
      case AngleUnit.inches:
        final units = context.read<UnitService>();
        final disp = units.convertSmallLength(inches);
        return disp.toStringAsFixed(1);
      case AngleUnit.moa:
        if (yards <= 0) return '—';
        return inchesToMoaAtYards(inches, yards).toStringAsFixed(1);
      case AngleUnit.mil:
        if (yards <= 0) return '—';
        return inchesToMilAtYards(inches, yards).toStringAsFixed(2);
    }
  }

  String _unitSuffix(BuildContext context) {
    switch (unit) {
      case AngleUnit.inches:
        final units = context.read<UnitService>();
        return unitDisplayLabel(units.unitFor(UnitCategory.smallLength));
      case AngleUnit.moa:
        return 'MOA';
      case AngleUnit.mil:
        return 'mil';
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final units = context.watch<UnitService>();
    final headerStyle = theme.textTheme.labelMedium?.copyWith(
      color: theme.colorScheme.primary,
      fontWeight: FontWeight.w600,
    );
    final cellStyle = theme.textTheme.bodySmall?.copyWith(
      fontFeatures: const [FontFeature.tabularFigures()],
    );
    final dropWindSuffix = _unitSuffix(context);
    final rangeUnit = unitDisplayLabel(units.unitFor(UnitCategory.range));
    final velUnit = unitDisplayLabel(units.unitFor(UnitCategory.velocity));
    final energyUnit = unitDisplayLabel(units.unitFor(UnitCategory.energy));
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: DataTable(
        headingRowHeight: 36,
        dataRowMinHeight: 32,
        dataRowMaxHeight: 36,
        columnSpacing: 18,
        columns: [
          DataColumn(label: Text('Range', style: headerStyle)),
          DataColumn(
              label: Text('Drop ($dropWindSuffix)', style: headerStyle),
              numeric: true),
          DataColumn(
              label: Text('Wind ($dropWindSuffix)', style: headerStyle),
              numeric: true),
          DataColumn(
              label: Text('Vel ($velUnit)', style: headerStyle), numeric: true),
          DataColumn(
              label: Text('Energy ($energyUnit)', style: headerStyle),
              numeric: true),
          DataColumn(
              label: Text('ToF (s)', style: headerStyle), numeric: true),
          DataColumn(
              label: Text('Mach', style: headerStyle), numeric: true),
        ],
        rows: [
          for (final s in samples)
            DataRow(
              cells: [
                DataCell(
                  Text(
                    '${units.convertRange(s.rangeYards).toStringAsFixed(0)} '
                    '$rangeUnit',
                    style: cellStyle,
                  ),
                ),
                DataCell(Text(_fmtAngle(context, s.dropInches, s.rangeYards),
                    style: cellStyle)),
                DataCell(Text(
                    _fmtAngle(context, s.windDriftInches, s.rangeYards),
                    style: cellStyle)),
                DataCell(Text(
                    units.convertVelocity(s.velocityFps).toStringAsFixed(0),
                    style: cellStyle)),
                DataCell(Text(
                    units.convertEnergy(s.energyFtLb).toStringAsFixed(0),
                    style: cellStyle)),
                DataCell(
                    Text(s.timeSec.toStringAsFixed(2), style: cellStyle)),
                DataCell(
                    Text(s.machNumber.toStringAsFixed(2), style: cellStyle)),
              ],
            ),
        ],
      ),
    );
  }
}

// ─────────────────────── Disclaimer ───────────────────────

class _DisclaimerFooter extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 8, 4, 8),
      child: Text(
        'Solver is a Modified Point-Mass (MPM) model with G1/G7 standard drag '
        'curves and Litz spin-drift correction. Output is a planning aid; '
        'verify in the field before relying on these numbers for any '
        'consequential shot.',
        style: theme.textTheme.bodySmall?.copyWith(
          fontStyle: FontStyle.italic,
          color: theme.colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }
}
