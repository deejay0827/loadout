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
// model with G1/G7 drag tables and spin-drift correction. The
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
import '../../repositories/drag_curve_repository.dart';
import '../../repositories/firearm_repository.dart';
import '../../repositories/manufactured_ammo_repository.dart';
import '../../repositories/recipe_repository.dart';
import '../../services/ballistics/atmosphere.dart';
import '../../services/ballistics/custom_drag.dart';
import '../../services/ballistics/drag_functions.dart';
import '../../services/ballistics/environment.dart';
import '../../services/ballistics/projectile.dart';
import '../../services/ballistics/solver.dart';
import '../../services/ballistics/units.dart';
import '../../services/ballistics/wind_bracket_service.dart';
import '../../services/auto_save_service.dart';
import '../../services/ble/kestrel_service.dart';
import '../../services/cloud_sync_service.dart';
import '../../services/entitlement_notifier.dart';
import '../../services/unit_service.dart';
import '../../services/weather_service.dart';
import '../../utils/responsive.dart';
import '../../screens/atmosphere/atmosphere_presets_screen.dart';
import '../../widgets/atmosphere_preset_picker.dart';
import '../../widgets/favorite_star_button.dart';
import '../../widgets/glossary_label.dart';
import '../../widgets/missing_inputs_card.dart';
import '../../widgets/pro_gate.dart';
import '../../widgets/unsaved_changes_dispatcher.dart';
import 'internal_ballistics_screen.dart';
import 'widgets/contribution_breakdown.dart';
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

  /// Fields that are blocking a profile save, populated when the
  /// user taps "Save as Profile" / "Update Profile" against an
  /// incomplete form. When non-empty:
  ///   * The four affected TextFields render with red `errorText:
  ///     'Required'` indicators.
  ///   * A [MissingInputsCard] surfaces above the Save buttons
  ///     listing exactly which fields are blocking.
  /// Cleared on the next text edit so the indicators don't linger
  /// after the user fixes a field.
  MissingInputs _missingProfileInputs = MissingInputs.empty;

  /// Per-screen autosave plumbing. Shared with Recipe so the user's
  /// frequency + unsaved-changes preferences govern this screen the
  /// same way. Constructed in initState; only fires when an active
  /// profile is set (otherwise `onSave` returns null, which the
  /// controller treats as "form not valid yet, skip this save").
  late final AutoSaveController _autoSave;

  // ─────────────────────── Rifle picker ───────────────────────
  /// One-shot list of the user's firearms, fetched on initState. Null until
  /// the future resolves; empty list means the user has no firearms saved.
  Future<List<UserFirearmRow>>? _firearmsFuture;
  UserFirearmRow? _selectedFirearm;
  /// Set when the rifle the user picked has no twist rate field — the UI
  /// shows a small inline hint to make this obvious without forcing a
  /// fallback value.
  bool _twistMissingFromFirearm = false;

  // ─────────────────────── Bullet / recipe picker ───────────────────────
  /// One-shot list of every bullet in the reference catalog, joined with
  /// its manufacturer. Null until the future resolves.
  Future<List<({BulletRow bullet, ManufacturerRow mfg})>>? _bulletsFuture;
  ({BulletRow bullet, ManufacturerRow mfg})? _selectedBullet;

  /// Live stream of the user's saved recipes. Drives the unified
  /// "Pick a Saved Load or Bullet" picker so the user can start
  /// from one of their own recipes instead of digging through the
  /// raw bullet catalog.
  Stream<List<UserLoadRow>>? _recipesStream;
  UserLoadRow? _selectedRecipe;

  /// One-shot list of curated manufactured-ammo (factory load)
  /// rows. The catalog is small (~20 entries) and read-only, so we
  /// fetch once. Adds a third source alongside recipes + bullets in
  /// the projectile picker per user request: "this section should
  /// allow me to pick my recipes [and] manufactured ammo."
  Future<List<ManufacturedAmmoRow>>? _ammoFuture;
  ManufacturedAmmoRow? _selectedAmmo;

  /// Indicates whether the currently-selected bullet has a matching
  /// curve in the custom-drag catalog. Drives the "Custom drag
  /// available" badge on the bullet picker. Refreshed in
  /// [_applyBulletSelection] / [_clearBulletSelection].
  bool _bulletHasCustomCurve = false;

  // ─────────────────────── Custom drag curve ───────────────────────
  /// One-shot list of every drag curve in the catalog. Used by the
  /// "Custom" drag-function path to populate the curve dropdown.
  Future<List<DragCurveRow>>? _dragCurvesFuture;

  /// True when the user has picked the "Custom" entry on the drag-
  /// function selector. While true, [_bcCtrl] is hidden because
  /// custom curves don't use a BC.
  bool _useCustomDragCurve = false;

  /// The selected custom curve. Null when [_useCustomDragCurve] is
  /// false or when the catalog is empty.
  DragCurveRow? _selectedDragCurve;

  // ─────────────────────── Projectile ───────────────────────
  // ALL projectile / muzzle / zero / atmosphere fields default to
  // EMPTY (CLAUDE.md § 0 anti-fake-data rule). The user picks a
  // load / profile / common factory load to populate them, OR
  // types values directly into the calculator. Computing against
  // pre-filled "6.5 CM 140gr ELD-M" defaults the user never picked
  // is exactly the customer-trust failure mode this rule exists
  // to prevent.
  final _diameterCtrl = TextEditingController();
  final _weightCtrl = TextEditingController();
  final _lengthCtrl = TextEditingController();
  final _bcCtrl = TextEditingController();
  final _twistCtrl = TextEditingController();
  DragModel _dragModel = DragModel.g7;

  // ─────────────────────── Calculator Tab Toggle ───────────────────────
  // Top-of-screen SegmentedButton flips between External Ballistics
  // (the trajectory solver, this screen's original surface) and
  // Internal Ballistics (the pressure / MV predictor formerly
  // reached only via the Resources tile). Both are first-class
  // peers — the toggle replaces the old bottom-of-page entry
  // button so users see both calculators the moment they open
  // Ballistics.
  //
  // The Internal tab embeds `InternalBallisticsScreen` with
  // `wrapInScaffold: false` so it doesn't render its own
  // AppBar inside this screen's Scaffold. When the user opens
  // Internal via the inline "Don't Know Your MV?" link on the
  // External form, [_internalPrefill] carries the overlap fields
  // and [_acceptPredictedMv] fires after a successful predict
  // (writes the predicted velocity into the External form's MV
  // field, switches the tab back to External).
  _CalculatorTab _activeCalculator = _CalculatorTab.external;
  InternalBallisticsPrefill? _internalPrefill;

  // ─────────────────────── Muzzle / Zero ───────────────────────
  final _muzzleVelCtrl = TextEditingController();
  final _sightHeightCtrl = TextEditingController();
  final _zeroRangeCtrl = TextEditingController();
  final _shotAzimuthCtrl = TextEditingController();
  final _targetElevationCtrl = TextEditingController();

  // ─────────────────────── Environment ───────────────────────
  // Empty by default. The solver uses ICAO standard atmosphere as
  // an internal fallback for empty temp/pressure/humidity/altitude;
  // the form labels these as "(ICAO standard)" hints so the user
  // knows the source. Explicitly entering values overrides.
  final _tempCtrl = TextEditingController();
  final _pressureCtrl = TextEditingController();
  final _humidityCtrl = TextEditingController();
  final _altitudeCtrl = TextEditingController();
  final _windSpeedCtrl = TextEditingController();
  final _windDirCtrl = TextEditingController();
  /// Wind-bracket uncertainty (mph). Empty hides the bracket card —
  /// the user opts in by typing a value rather than us prescribing
  /// "2 mph default" and then deriving low/high holds the user
  /// would attribute to themselves.
  final _windUncertaintyCtrl = TextEditingController();
  final _latitudeCtrl = TextEditingController();

  // ─────────────────────── Advanced (v16) ───────────────────────
  // Fields hidden behind an "Advanced" expansion: aerodynamic jump
  // multiplier, Mach number readout (computed), zero atmosphere, plus
  // the per-firearm/per-load v16 inputs (twist direction, sight scale,
  // powder temp sensitivity). All optional — defaults preserve current
  // solver behaviour.
  final _twistDirCtrl = TextEditingController(text: 'right');
  String _twistDirection = 'right';
  final _sightScaleVerticalCtrl = TextEditingController(text: '');
  final _sightScaleHorizontalCtrl = TextEditingController(text: '');
  final _zeroPressureInHgCtrl = TextEditingController(text: '');
  final _zeroTemperatureFCtrl = TextEditingController(text: '');
  final _zeroHumidityPctCtrl = TextEditingController(text: '');
  final _powderTempSensitivityCtrl = TextEditingController(text: '');
  final _powderReferenceTempCtrl = TextEditingController(text: '');
  final _aerodynamicJumpCtrl = TextEditingController(text: '');
  // Empty default — anti-fake-data rule. Empty parses to 0
  // (level shot) downstream so behaviour is unchanged for users
  // who don't enter a value, but the field doesn't display a "0"
  // the user might mistake for their own input.
  final _inclineAngleCtrl = TextEditingController();
  bool _advancedExpanded = false;

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

  /// Snapshot of the inputs that produced [_samples]. We hold on to
  /// these so the contribution-breakdown widget can re-solve variants
  /// (gravity off, drag off, etc.) without re-parsing the form.
  /// Cleared whenever `_samples` is cleared.
  Projectile? _lastSolvedProjectile;
  Environment? _lastSolvedEnvironment;
  ShotInputs? _lastSolvedShot;
  List<double>? _lastSolvedRanges;

  /// Wind speed (mph) and uncertainty (mph) captured at the time of
  /// the most recent solve — drives the wind-bracket card. Cleared
  /// alongside `_samples`.
  double? _lastSolvedWindMph;
  double? _lastSolvedWindUncertaintyMph;

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
    _dragCurvesFuture = context.read<DragCurveRepository>().allCurves();
    _profilesStream = context.read<BallisticProfileRepository>().watchAll();
    _recipesStream = context.read<RecipeRepository>().watchAll();
    _ammoFuture = context.read<ManufacturedAmmoRepository>().allRows();
    _restoreRangePreferences();
    _loadWeatherHintFlag();
    _autoSave = AutoSaveController(
      service: context.read<AutoSaveService>(),
      onSave: _runAutoSave,
      onSavedToCloud: () =>
          context.read<CloudSyncService>().scheduleSyncUp(),
    );
    // Wire every text controller to autosave's notifyDirty so the
    // dirty flag flips on edits even when the user has the
    // "no profile selected" state — the dispatcher uses that to
    // decide whether to engage the unsaved-changes dialog. We route
    // through `_notifyDirtyFromController` so programmatic writes
    // (load profile, unit conversion, weather pull, Kestrel push)
    // can suppress the spurious dirty flag they would otherwise
    // produce.
    for (final c in _autoSaveControllers()) {
      c.addListener(_notifyDirtyFromController);
    }
  }

  /// True while a programmatic batch of controller assignments is in
  /// flight (loading a profile, unit conversion, weather fetch). The
  /// per-controller listener defers to this — when set, listener
  /// callbacks become no-ops so the controller's text writes don't
  /// pretend the user typed something.
  bool _suppressAutoSaveDirty = false;

  void _notifyDirtyFromController() {
    if (_suppressAutoSaveDirty) return;
    _autoSave.notifyDirty();
  }

  /// Every text controller that should mark the form dirty when the
  /// user types into it. Centralized so initState wiring +
  /// dispose-time unwiring stay in sync.
  List<TextEditingController> _autoSaveControllers() => <TextEditingController>[
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
        _windUncertaintyCtrl,
        _latitudeCtrl,
        _twistDirCtrl,
        _sightScaleVerticalCtrl,
        _sightScaleHorizontalCtrl,
        _zeroPressureInHgCtrl,
        _zeroTemperatureFCtrl,
        _zeroHumidityPctCtrl,
        _powderTempSensitivityCtrl,
        _powderReferenceTempCtrl,
        _aerodynamicJumpCtrl,
        _inclineAngleCtrl,
        _rangeMinCtrl,
        _rangeMaxCtrl,
      ];

  /// AutoSave entry point. The Ballistics screen autosaves changes
  /// back to the *active profile*; if no profile is selected, this
  /// returns null to tell the controller to skip the save and stay
  /// idle (no profile = nowhere to write).
  ///
  /// Returns the active profile's row id on success.
  Future<int?> _runAutoSave() async {
    final p = _activeProfile;
    if (p == null) return null;
    final repo = context.read<BallisticProfileRepository>();
    await repo.update(p.id, _buildProfileCompanion(p.name));
    final fresh = await repo.getById(p.id);
    if (!mounted) return p.id;
    if (fresh != null) {
      // Don't call setState — the controller's status notifier
      // already drives the banner. Updating _activeProfile here just
      // keeps the in-memory copy of the row aligned with what we
      // just persisted. setState would trigger a rebuild that
      // re-reads the controllers, which (in metric mode) re-runs
      // unit conversion on every save.
      _activeProfile = fresh;
    }
    return p.id;
  }

  /// Reads the latest [UnitService] state and rewrites the controllers
  /// whenever the user has flipped a category since the last build.
  /// Called at the top of [build] so changes propagate without restart.
  ///
  /// The field text is treated as **already in the displayed unit**;
  /// when the user toggles, we invert from the OLD display unit back
  /// to canonical (imperial), then forward to the NEW display unit.
  /// This preserves the physical quantity the user typed.
  ///
  /// Sets `_suppressAutoSaveDirty` for the duration of the batch so
  /// the listener-triggered `notifyDirty()` calls don't pretend the
  /// user typed anything. The active ballistic profile is only ever
  /// dirty from real edits.
  void _syncDisplayedUnits(UnitService units) {
    _suppressAutoSaveDirty = true;
    try {
      _syncDisplayedUnitsInner(units);
    } finally {
      _suppressAutoSaveDirty = false;
    }
  }

  void _syncDisplayedUnitsInner(UnitService units) {
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
    _suppressAutoSaveDirty = true;
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
    // The controller assignments above were ignored by the
    // autosave-listener wrapper because we set `_suppressAutoSaveDirty`
    // first. Clear it now that the batch is done and explicitly
    // mark the form clean — nothing changed semantically.
    _suppressAutoSaveDirty = false;
    _autoSave.markClean();
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

  /// Walk the four fields a saved profile MUST have to compute a
  /// future firing solution: bullet weight, bullet diameter, BC,
  /// muzzle velocity. Returns a [MissingInputs] bundle the caller
  /// uses to drive the per-field red `errorText:` AND a
  /// [MissingInputsCard] above the Save buttons.
  ///
  /// Zero range and sight height are NOT in the required list —
  /// `_buildProfileCompanion` substitutes 100 yd / 1.5 in defaults
  /// when blank, which produces a usable (if generic) profile. The
  /// four required fields can't be defaulted: a profile without a
  /// real BC or MV is useless.
  MissingInputs _collectMissingProfileInputs() {
    final entries = <MissingInputEntry>[];
    bool isBlank(String s) =>
        s.trim().isEmpty || double.tryParse(s.trim()) == null;
    if (isBlank(_weightCtrl.text)) {
      entries.add(const MissingInputEntry(
        fieldId: 'bulletWeight',
        label: 'Bullet Weight',
      ));
    }
    if (isBlank(_diameterCtrl.text)) {
      entries.add(const MissingInputEntry(
        fieldId: 'bulletDiameter',
        label: 'Bullet Diameter',
      ));
    }
    if (isBlank(_bcCtrl.text)) {
      entries.add(const MissingInputEntry(
        fieldId: 'bc',
        label: 'Ballistic Coefficient',
      ));
    }
    if (isBlank(_muzzleVelCtrl.text)) {
      entries.add(const MissingInputEntry(
        fieldId: 'muzzleVelocity',
        label: 'Muzzle Velocity',
      ));
    }
    return MissingInputs(entries: entries);
  }

  /// `errorText:` decision for the four profile-required fields.
  /// Returns 'Required' when the field is in the missing-inputs
  /// bundle, else null. Read inline by each TextField's
  /// `decoration:`.
  String? _profileErrorTextFor(String fieldId) =>
      _missingProfileInputs.contains(fieldId) ? 'Required' : null;

  /// Hook on every keystroke into one of the four profile-required
  /// fields. Clears stale missing-inputs state so the user fixing
  /// a flagged field sees the red indicator vanish immediately.
  void _clearStaleProfileMissing() {
    if (_missingProfileInputs.isNotEmpty) {
      setState(() => _missingProfileInputs = MissingInputs.empty);
    }
  }

  Future<void> _onSaveAsProfile() async {
    // Pre-save validation. If the four required fields aren't all
    // filled in, refuse the save, surface the missing-inputs card,
    // and turn each affected field's `errorText:` red. The user
    // sees both the summary (top of form) AND the per-field hint.
    final missing = _collectMissingProfileInputs();
    if (missing.isNotEmpty) {
      setState(() => _missingProfileInputs = missing);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            "Can't save profile yet — fill in the highlighted fields.",
          ),
          duration: Duration(seconds: 3),
        ),
      );
      return;
    }
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
      setState(() {
        _activeProfile = fresh;
        _missingProfileInputs = MissingInputs.empty;
      });
    }
    messenger.showSnackBar(
      SnackBar(content: Text('Profile "$name" saved.')),
    );
  }

  Future<void> _onUpdateProfile() async {
    final p = _activeProfile;
    if (p == null) return;
    // Same pre-save validation as Save-As: an existing profile that
    // gets emptied out shouldn't be persisted with zeros.
    final missing = _collectMissingProfileInputs();
    if (missing.isNotEmpty) {
      setState(() => _missingProfileInputs = missing);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            "Can't update profile yet — fill in the highlighted fields.",
          ),
          duration: Duration(seconds: 3),
        ),
      );
      return;
    }
    final repo = context.read<BallisticProfileRepository>();
    final messenger = ScaffoldMessenger.of(context);
    await repo.update(p.id, _buildProfileCompanion(p.name));
    if (!mounted) return;
    final fresh = await repo.getById(p.id);
    if (!mounted) return;
    if (fresh != null) {
      setState(() {
        _activeProfile = fresh;
        _missingProfileInputs = MissingInputs.empty;
      });
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
    // Tear down autosave first so a final tick can't fire after the
    // controllers have been disposed.
    for (final c in _autoSaveControllers()) {
      c.removeListener(_notifyDirtyFromController);
    }
    _autoSave.dispose();
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
      _windUncertaintyCtrl,
      _latitudeCtrl,
      _rangeMinCtrl,
      _rangeMaxCtrl,
      // ── v16 advanced-section controllers ──
      _twistDirCtrl,
      _sightScaleVerticalCtrl,
      _sightScaleHorizontalCtrl,
      _zeroPressureInHgCtrl,
      _zeroTemperatureFCtrl,
      _zeroHumidityPctCtrl,
      _powderTempSensitivityCtrl,
      _powderReferenceTempCtrl,
      _aerodynamicJumpCtrl,
      _inclineAngleCtrl,
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

      // Atmosphere defaults to ICAO standard when empty
      // (CLAUDE.md § 0). The user sees "(ICAO standard)" hints on
      // the form labels so they know the source. Entering any
      // value overrides. Note that the user-typed values are in
      // their CHOSEN display unit, so we still go through the
      // unit-conversion helpers; the ICAO fallbacks are in
      // canonical (°F / inHg / %RH / ft) and bypass conversion.
      final tempDisp = _parseOpt(_tempCtrl.text);
      final temp = tempDisp == null
          ? 59.0
          : _tempToCanonical(tempDisp, units.unitFor(UnitCategory.temperature));
      final pressureDisp = _parseOpt(_pressureCtrl.text);
      final pressure = pressureDisp == null
          ? 29.92
          : _pressureToCanonical(
              pressureDisp, units.unitFor(UnitCategory.pressure));
      final humidity = _parseOpt(_humidityCtrl.text) ?? 50.0;
      final altitude = _parseOpt(_altitudeCtrl.text) ?? 0.0;
      final windSpeed = _windToCanonical(
        double.tryParse(_windSpeedCtrl.text.trim()) ?? 0,
        units.unitFor(UnitCategory.windSpeed),
      );
      final windDir = double.tryParse(_windDirCtrl.text.trim()) ?? 0;
      // Wind uncertainty stays in the user's chosen wind-speed unit;
      // the wind-bracket card consumes it in mph after the same
      // conversion the solver applies to wind speed.
      final windUncRaw =
          double.tryParse(_windUncertaintyCtrl.text.trim()) ?? 0;
      final windUncMph = windUncRaw <= 0
          ? 0.0
          : _windToCanonical(
              windUncRaw,
              units.unitFor(UnitCategory.windSpeed),
            );
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

      // Build the custom drag curve only when the user has selected
      // both "Custom" on the drag-function selector AND a specific
      // curve from the dropdown. If "Custom" is selected without a
      // curve picked we fail loudly rather than silently fall back —
      // the UI's empty-curve hint already tells the user to pick one.
      CustomDragCurve? customCurve;
      if (_useCustomDragCurve) {
        final row = _selectedDragCurve;
        if (row == null) {
          throw const FormatException(
              'Custom drag curve selected but no curve picked. Choose '
              'one from the dropdown or switch back to a G-curve.');
        }
        customCurve = DragCurveRepository.toCustomDragCurve(row);
      }

      final projectile = Projectile(
        diameterIn: diameter,
        weightGr: weight,
        // BC is ignored when a custom curve is set (Projectile.formFactor
        // returns 1.0 for that case), but we still pass it through so
        // the field's value is preserved if the user toggles back.
        bc: bc,
        dragModel: _dragModel,
        lengthIn: length,
        twistInches: twist,
        customDragCurve: customCurve,
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
      // Scope tracking calibration. The dedicated input fields
      // ("Sight scale vertical / horizontal") feed directly into
      // ShotInputs; values default to 1.0 when the field is blank
      // or unparseable so the math stays sane. The solver multiplies
      // drop, wind, spin drift, aero jump, and incline delta by
      // these scale factors (see solver.dart:1008). When either
      // value differs from 1.0 the result card surfaces a chip so
      // the user notices a non-default calibration is in effect.
      final scaleV =
          double.tryParse(_sightScaleVerticalCtrl.text.trim()) ?? 1.0;
      final scaleH =
          double.tryParse(_sightScaleHorizontalCtrl.text.trim()) ?? 1.0;
      final shot = ShotInputs(
        muzzleVelocityFps: mv,
        sightHeightIn: sightHeight,
        zeroRangeYards: zeroRange,
        sightScaleVertical: scaleV,
        sightScaleHorizontal: scaleH,
      );

      final samples = solveTrajectory(
        projectile: projectile,
        environment: environment,
        shot: shot,
        sampleRangesYards: ranges,
      );

      setState(() {
        _samples = samples;
        _lastSolvedProjectile = projectile;
        _lastSolvedEnvironment = environment;
        _lastSolvedShot = shot;
        _lastSolvedRanges = ranges;
        _lastSolvedWindMph = windSpeed;
        _lastSolvedWindUncertaintyMph = windUncMph > 0 ? windUncMph : null;
      });
    } on FormatException catch (e) {
      setState(() {
        _error = e.message;
        _samples = const [];
        _lastSolvedProjectile = null;
        _lastSolvedEnvironment = null;
        _lastSolvedShot = null;
        _lastSolvedRanges = null;
        _lastSolvedWindMph = null;
        _lastSolvedWindUncertaintyMph = null;
      });
    } catch (e) {
      setState(() {
        _error = 'Could not solve: $e';
        _samples = const [];
        _lastSolvedProjectile = null;
        _lastSolvedEnvironment = null;
        _lastSolvedShot = null;
        _lastSolvedRanges = null;
        _lastSolvedWindMph = null;
        _lastSolvedWindUncertaintyMph = null;
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

  // _parseAny was used for atmosphere fields before they switched to
  // empty-with-ICAO-fallback semantics. Removed in the CLAUDE.md § 0
  // sweep; `_parseOpt(...) ?? <ICAO default>` is the current pattern.

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

  /// Display label for a user recipe in the projectile picker.
  /// `r.name` is the canonical recipe name shown everywhere else
  /// in the app — keep it consistent so the user matches the
  /// dropdown entry to their Recipes-tab listing without having
  /// to translate.
  String _recipeLabel(UserLoadRow r) => r.name;

  /// Display label for a manufactured ammo entry. Mirrors the
  /// `_AmmoProjectileEntry.label` formula — keep them in sync so
  /// the Autocomplete's `initialValue` matches the option text.
  String _ammoLabel(ManufacturedAmmoRow a) =>
      '${a.manufacturer} ${a.cartridge} ${a.name}';

  /// Apply a manufactured-ammo selection to the projectile fields.
  /// The catalog entry carries diameter / weight / MV / BC — the
  /// full set of inputs needed for a firing solution — so picking
  /// an ammo row is the closest equivalent to picking a load:
  /// every ballistics field gets populated from the published
  /// data. The user still owns the right to override anything
  /// they typed (we don't clobber a non-empty field unless the
  /// catalog row carries a value for it).
  void _applyAmmoSelection(ManufacturedAmmoRow ammo) {
    final units = context.read<UnitService>();
    setState(() {
      _selectedAmmo = ammo;
      // Other selection sources lose precedence when ammo is picked.
      _selectedRecipe = null;
      _selectedBullet = null;
      _bulletHasCustomCurve = false;
      _diameterCtrl.text = ammo.bulletDiameterIn.toStringAsFixed(3);
      _weightCtrl.text = _formatNumber(_bulletWeightFromCanonical(
          ammo.bulletWeightGr, units.unitFor(UnitCategory.bulletWeight)));
      _muzzleVelCtrl.text = _formatNumber(_velocityFromCanonical(
          ammo.muzzleVelocityFps, units.unitFor(UnitCategory.velocity)));
      // Prefer G7 for rifle loads, G1 for pistol / rimfire.
      final g7 = ammo.bcG7;
      final g1 = ammo.bcG1;
      if (g7 != null) {
        _bcCtrl.text = g7.toStringAsFixed(3);
        _dragModel = DragModel.g7;
      } else if (g1 != null) {
        _bcCtrl.text = g1.toStringAsFixed(3);
        _dragModel = DragModel.g1;
      }
    });
    _autoSave.notifyDirty();
  }

  /// Apply a user recipe selection to the projectile fields.
  /// Recipes don't carry diameter / BC directly (the recipe row
  /// only has bullet name + weight), so the user still has to
  /// supply diameter / BC manually unless the bullet matches a
  /// catalog row by name. We populate what we can from the recipe
  /// row and leave the rest blank for the user to fill in (or for
  /// a follow-up bullet-catalog fuzzy-match to populate).
  void _applyRecipeSelection(UserLoadRow recipe) {
    setState(() {
      _selectedRecipe = recipe;
      _selectedBullet = null; // recipe pick supersedes bullet pick
      _bulletHasCustomCurve = false;
      // Weight is on the recipe row when it was filled in. The
      // recipe's weight is in grains (canonical); convert to the
      // user's chosen bullet-weight unit before dropping it in.
      final units = context.read<UnitService>();
      if (recipe.bulletWeightGr != null) {
        _weightCtrl.text = _formatNumber(_bulletWeightFromCanonical(
          recipe.bulletWeightGr!,
          units.unitFor(UnitCategory.bulletWeight),
        ));
      }
      // Diameter / BC don't live on UserLoadRow directly — the
      // recipe row only knows the bullet's NAME. Resolve the actual
      // bullet record below (async) so we can back-fill diameter +
      // BC + caliber-implied drag model. The fuzzy match looks the
      // bullet up by `recipe.bullet` against the catalog and
      // populates whatever fields are still empty.
    });
    _autoSave.notifyDirty();
    _backfillFromRecipeBullet(recipe);
  }

  /// Back-fill diameter / BC / drag model from the catalog bullet
  /// matching `recipe.bullet`. Best-effort: a recipe storing
  /// "Berger 109gr Hybrid" tries to find that bullet in the catalog;
  /// when found, populates the projectile fields the recipe row
  /// itself doesn't carry. Skipped for any field the user has
  /// already typed into — never clobber explicit input.
  Future<void> _backfillFromRecipeBullet(UserLoadRow recipe) async {
    final bulletName = recipe.bullet?.trim();
    if (bulletName == null || bulletName.isEmpty) return;
    try {
      final units = context.read<UnitService>();
      final repo = context.read<ComponentRepository>();
      // Compose a label the catalog lookup will recognise. The
      // recipe's `bullet` often already includes the manufacturer
      // (e.g. "Berger 109gr Hybrid Target") but may not include the
      // weight suffix the picker uses — append it from the row when
      // we have it so `bulletByLabel` can match cleanly.
      final wt = recipe.bulletWeightGr;
      final wtSuffix = (wt != null && bulletName.toLowerCase().contains('gr'))
          ? ''
          : (wt != null ? ' ${_formatNumber(wt)}gr' : '');
      final hit = await repo.bulletByLabel('$bulletName$wtSuffix');
      if (!mounted || hit == null) return;
      setState(() {
        if (_diameterCtrl.text.trim().isEmpty) {
          _diameterCtrl.text = hit.bullet.diameterIn.toStringAsFixed(3);
        }
        if (_weightCtrl.text.trim().isEmpty) {
          _weightCtrl.text = _formatNumber(_bulletWeightFromCanonical(
              hit.bullet.weightGr, units.unitFor(UnitCategory.bulletWeight)));
        }
        if (_bcCtrl.text.trim().isEmpty) {
          final g7 = hit.bullet.bcG7;
          final g1 = hit.bullet.bcG1;
          if (g7 != null) {
            _bcCtrl.text = g7.toStringAsFixed(3);
            _dragModel = DragModel.g7;
          } else if (g1 != null) {
            _bcCtrl.text = g1.toStringAsFixed(3);
            _dragModel = DragModel.g1;
          }
        }
      });
      _autoSave.notifyDirty();
    } catch (e) {
      debugPrint('[ballistics] _backfillFromRecipeBullet failed: $e');
    }
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
    // Async lookup of the matching custom drag curve. We don't auto-
    // switch the user to "Custom" — that would surprise them — but we
    // do surface a small "Custom drag available" badge on the picker.
    _refreshBulletCustomCurveBadge(sel);
  }

  /// Clears the bullet picker AND blanks the projectile fields the
  /// pick had populated (diameter, weight, BC, length). Without
  /// blanking the fields the user would tap "Clear" and see the
  /// fields stay full of the previous bullet's data — exactly the
  /// "fake placeholder" failure mode CLAUDE.md § 0 warns against.
  /// Drag model resets to G7 (the default for VLD-style bullets).
  /// Length is intentionally cleared too — picking a bullet doesn't
  /// always populate length, but if it did, we blank it on clear.
  /// `_selectedRecipe` is also cleared so the recipe picker doesn't
  /// stay highlighted with a stale selection.
  void _clearBulletSelection() {
    setState(() {
      _selectedBullet = null;
      _selectedRecipe = null;
      _selectedAmmo = null;
      _bulletHasCustomCurve = false;
      _diameterCtrl.clear();
      _weightCtrl.clear();
      _bcCtrl.clear();
      _lengthCtrl.clear();
      _dragModel = DragModel.g7;
    });
  }

  /// Look up whether the selected bullet has a matching custom drag
  /// curve in the catalog and update [_bulletHasCustomCurve] for the
  /// badge. Catches errors silently — a stale lookup just leaves the
  /// badge hidden.
  Future<void> _refreshBulletCustomCurveBadge(
      ({BulletRow bullet, ManufacturerRow mfg}) sel) async {
    final repo = context.read<DragCurveRepository>();
    try {
      final match = await repo.findCurveForBullet(
        manufacturer: sel.mfg.name,
        line: sel.bullet.line,
        weightGr: sel.bullet.weightGr,
        diameterIn: sel.bullet.diameterIn,
      );
      if (!mounted) return;
      // Guard against a later selection arriving while this lookup
      // was in flight: only update the badge if the bullet we looked
      // up is still the one selected.
      if (_selectedBullet?.bullet.id != sel.bullet.id) return;
      setState(() {
        _bulletHasCustomCurve = match != null;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _bulletHasCustomCurve = false;
      });
    }
  }

  /// Format a firearm row for the rifle picker dropdown:
  /// `"<name> — <caliber>"`.
  String _firearmLabel(UserFirearmRow f) {
    final cal = (f.caliber ?? '').trim();
    if (cal.isEmpty) return f.name;
    return '${f.name} — $cal';
  }

  /// Parse a twist-rate string like `"1:8"`, `"1:7.50"`, `"8"`, or
  /// `"1 in 8"` into a decimal inches-per-turn value. Returns null
  /// if no number can be recovered.
  ///
  /// Historically returned `int?` and rounded — that silently
  /// mangled `1:7.50` to `8`, both in the displayed twist field and
  /// in the solver's spin-drift computation. Fixed 2026-05-10 to
  /// preserve the decimal.
  double? _parseTwistRate(String? raw) {
    if (raw == null || raw.trim().isEmpty) return null;
    // Pull out the last number in the string — handles "1:8", "1 in 8",
    // "1:7.50", "7.7" consistently.
    final matches = RegExp(r'(\d+(?:\.\d+)?)').allMatches(raw);
    if (matches.isEmpty) return null;
    final last = matches.last.group(1)!;
    return double.tryParse(last);
  }

  /// Drop a trailing `.0` so an integer twist rate displays as `"8"`
  /// rather than `"8.0"`, while keeping decimals like `"7.5"` intact.
  String _formatTwist(double v) {
    if (v == v.truncateToDouble()) return v.toStringAsFixed(0);
    final s = v.toString();
    return s.endsWith('.0') ? s.substring(0, s.length - 2) : s;
  }

  void _applyFirearmSelection(UserFirearmRow f) {
    final units = context.read<UnitService>();
    setState(() {
      _selectedFirearm = f;
      // Twist rate.
      final twist = _parseTwistRate(f.twistRate);
      if (twist != null) {
        _twistCtrl.text = _formatTwist(twist);
        _twistMissingFromFirearm = false;
      } else {
        _twistMissingFromFirearm = true;
      }
      // Zero range / sight height — only overwrite when the firearm
      // has a value, so we never blow away whatever the user typed
      // manually. Firearm columns store canonical imperial values; the
      // controllers display values in the user's chosen unit, so each
      // line below converts before assigning. MV used to live on the
      // firearm too — dropped at schema v33 because MV changes
      // per-load. The user pulls MV via the External Ballistics
      // calculator's Garmin Xero / Photo OCR capture buttons or types
      // it manually.
      if (f.defaultZeroRangeYd != null) {
        _zeroRangeCtrl.text = _formatNumber(_rangeFromCanonical(
            f.defaultZeroRangeYd!.toDouble(),
            units.unitFor(UnitCategory.range)));
      }
      if (f.sightHeightIn != null) {
        _sightHeightCtrl.text = _formatNumber(_smallLenFromCanonical(
            f.sightHeightIn!, units.unitFor(UnitCategory.smallLength)));
      }
      // ── v15 firearm fields: twist direction + sight scale + zero atmo ──
      // Pre-fill the Advanced section so the user sees the firearm's
      // saved precision inputs without having to retype them. Only
      // overwrite when the firearm has a value — preserves any free-
      // typed values the user already entered.
      _twistDirection = f.twistDirection;
      // Sight scales: don't overwrite when the firearm carries the
      // schema default of 1.0, so the user's blank-means-no-correction
      // intuition holds. Same convention as the firearm form.
      if (f.sightScaleVertical != 1.0) {
        _sightScaleVerticalCtrl.text =
            f.sightScaleVertical.toStringAsFixed(3);
      }
      if (f.sightScaleHorizontal != 1.0) {
        _sightScaleHorizontalCtrl.text =
            f.sightScaleHorizontal.toStringAsFixed(3);
      }
      if (f.zeroPressureInHg != null) {
        _zeroPressureInHgCtrl.text =
            f.zeroPressureInHg!.toStringAsFixed(2);
      }
      if (f.zeroTemperatureF != null) {
        _zeroTemperatureFCtrl.text =
            f.zeroTemperatureF!.toStringAsFixed(0);
      }
      if (f.zeroHumidityPct != null) {
        _zeroHumidityPctCtrl.text =
            f.zeroHumidityPct!.toStringAsFixed(0);
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
    _autoSave.notifyDirty();
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
    return UnsavedChangesScope(
      controller: _autoSave,
      child: Scaffold(
      appBar: AppBar(
        title: const Text('Ballistics Calculator'),
      ),
      body: ProGate(
        feature: 'Ballistics Calculator',
        child: Column(
          children: [
            if (showWeatherHint) _weatherHintBanner(),
            // Top-of-screen calculator toggle. Always visible, both
            // tabs are first-class peers. The old bottom-of-page
            // "Predict Pressure & MV" entry button was removed in
            // favour of this — discoverability up, scroll-to-find
            // out.
            _calculatorTabToggle(),
            Expanded(
              child: _activeCalculator == _CalculatorTab.internal
                  ? _internalCalculatorBody()
                  : SingleChildScrollView(
                      padding:
                          const EdgeInsets.fromLTRB(16, 12, 16, 32),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          _profilePickerCard(),
                          const SizedBox(height: 8),
                          if (_missingProfileInputs.isNotEmpty) ...[
                            MissingInputsCard(
                              missing: _missingProfileInputs,
                              headline: "Can't save profile yet",
                              detail:
                                  'Fill in the highlighted fields below '
                                  'so the profile has everything the '
                                  'solver needs.',
                            ),
                            const SizedBox(height: 8),
                          ],
                          _firearmSection(),
                          const SizedBox(height: 8),
                          _projectileSection(),
                          const SizedBox(height: 8),
                          _muzzleZeroSection(),
                          const SizedBox(height: 8),
                          _environmentSection(),
                          const SizedBox(height: 8),
                          _advancedSection(),
                          const SizedBox(height: 8),
                          _outputSection(),
                          const SizedBox(height: 16),
                          _DisclaimerFooter(),
                        ],
                      ),
                    ),
            ),
            // Bottom-of-page Save / Done button — full width, sticky
            // (does not scroll with content). Per CLAUDE.md UX rule:
            // full-size save buttons live at the bottom of the page.
            // Label adapts to the autosave + profile state:
            //   * No active profile → "Save as Profile" (creates row)
            //   * Profile + autosave on → "Done" (already persisting)
            //   * Profile + autosave off → "Save" (manual flush via
            //     update of the existing row)
            _bottomSaveButton(),
          ],
        ),
      ),
      ),
    );
  }

  // ─────────────────────── Sections ───────────────────────

  /// Sticky bottom Save / Done button. Adapts its label to the
  /// current autosave + profile state per the CLAUDE.md UX rule
  /// (autosave on → "Done"; autosave off → "Save"; no profile yet
  /// → "Save as Profile" since there's nothing for autosave to
  /// flush to). Wrapped in a SafeArea so it doesn't slip under
  /// the home indicator on iOS.
  Widget _bottomSaveButton() {
    final theme = Theme.of(context);
    final autoSaveOn = context.watch<AutoSaveService>()
        .frequency
        .savesAutomatically;
    final hasProfile = _activeProfile != null;
    final String label;
    final VoidCallback onPressed;
    if (!hasProfile) {
      label = 'Save as Profile';
      onPressed = _onSaveAsProfile;
    } else if (autoSaveOn) {
      label = 'Done';
      onPressed = () => Navigator.of(context).maybePop();
    } else {
      label = 'Save';
      onPressed = _onUpdateProfile;
    }
    return Material(
      color: theme.colorScheme.surface,
      elevation: 4,
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
          child: SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              onPressed: onPressed,
              icon: Icon(hasProfile && autoSaveOn
                  ? Icons.check
                  : Icons.save_outlined),
              label: Text(label),
            ),
          ),
        ),
      ),
    );
  }

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
            final raw = snap.data ?? const <BallisticProfileRow>[];
            // Favorites-first sort. The repository's `watchAll` is
            // already natural-sorted by name; we stable-partition so
            // favorites surface at the top while preserving the
            // alphabetic ordering within each bucket. The dropdown
            // entries get a small `★ ` typographic glyph prefix
            // (not an emoji — see `CLAUDE.md` § 6) so users can
            // visually scan favorites at a glance.
            final favorites = <BallisticProfileRow>[];
            final others = <BallisticProfileRow>[];
            for (final p in raw) {
              if (p.isFavorite) {
                favorites.add(p);
              } else {
                others.add(p);
              }
            }
            final profiles = [...favorites, ...others];
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
                  Row(
                    children: [
                      Expanded(
                        child: DropdownButtonFormField<int?>(
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
                                // Prefix favorited entries with a "★ "
                                // typographic glyph so users can spot
                                // them when the dropdown is open. This
                                // is NOT an emoji — `CLAUDE.md` § 6
                                // explicitly allows the unicode star
                                // for cases where an `Icon` widget
                                // can't fit (DropdownMenuItem text
                                // can't host a Row easily inside the
                                // collapsed selected-item view).
                                child: Text(
                                  p.isFavorite ? '★ ${p.name}' : p.name,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                          ],
                          onChanged: (id) {
                            if (id == null) {
                              setState(() => _activeProfile = null);
                              return;
                            }
                            final picked = profiles.firstWhere(
                                (p) => p.id == id,
                                orElse: () => profiles.first);
                            _applyProfile(picked);
                          },
                        ),
                      ),
                      // Star toggle for the currently-selected profile.
                      // Disabled when no profile is selected — the
                      // toggle has nothing to flip in that case.
                      if (selected != null)
                        Padding(
                          padding: const EdgeInsets.only(left: 4),
                          child: FavoriteStarButton(
                            isFavorite: selected.isFavorite,
                            onToggle: () => context
                                .read<BallisticProfileRepository>()
                                .toggleFavorite(selected!.id),
                          ),
                        ),
                    ],
                  ),
                // Update / Delete only render when a saved profile is
                // active. For a brand-new (Unsaved) calculator session
                // there's nothing to update or delete, and showing the
                // disabled buttons just looked like junk on the screen.
                // The primary "Save as Profile" CTA lives at the bottom
                // of the page (see the build method's footer) so the
                // Profiles card stays focused on selection /
                // management of EXISTING profiles.
                if (selected != null) ...[
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    children: [
                      OutlinedButton.icon(
                        icon: const Icon(Icons.delete_outline, size: 16),
                        label: const Text('Delete'),
                        onPressed: _onDeleteProfile,
                      ),
                    ],
                  ),
                ],
              ],
            );
          },
        ),
      ),
    );
  }

  Widget _firearmSection() {
    // Wrap the FutureBuilder around the section card so the entire
    // card collapses (not just its body) when the user has no
    // saved firearms. A "No firearms" placeholder card was just
    // visual noise on the calculator surface.
    return FutureBuilder<List<UserFirearmRow>>(
      future: _firearmsFuture,
      builder: (context, outerSnap) {
        if (outerSnap.connectionState == ConnectionState.done &&
            (outerSnap.data ?? const <UserFirearmRow>[]).isEmpty) {
          return const SizedBox.shrink();
        }
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
              // Hide the entire Firearms section when the user has no
              // saved firearms — same anti-noise pattern as the Range
              // Day profile / firearm dropdowns. The user's own
              // typed-in projectile / muzzle / zero values still drive
              // the solver; firearms are an optional pre-fill layer.
              if (firearms.isEmpty) {
                return const SizedBox.shrink();
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
      },
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
                  onChanged: (_) => _clearStaleProfileMissing(),
                  decoration: InputDecoration(
                    // Diameter stays in inches by convention — cartridge
                    // designations ("6.5mm", ".308") still map to bullet
                    // diameters in inches even in metric workflows.
                    label: const GlossaryLabel(
                      text: 'Diameter (in)',
                      glossaryTerm: 'Bullet diameter vs. groove diameter',
                    ),
                    helperText: 'e.g. 0.264 for 6.5mm',
                    errorText: _profileErrorTextFor('bulletDiameter'),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: TextField(
                  controller: _weightCtrl,
                  keyboardType: const TextInputType.numberWithOptions(
                      decimal: true),
                  onChanged: (_) => _clearStaleProfileMissing(),
                  decoration: InputDecoration(
                    label: GlossaryLabel(
                      text: 'Weight ($bulletWt)',
                      glossaryTerm: 'Sectional Density',
                    ),
                    suffixText: bulletWt,
                    errorText: _profileErrorTextFor('bulletWeight'),
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
                    label: GlossaryLabel(
                      text: 'Length ($smallLen, optional)',
                      glossaryTerm: 'Miller stability formula',
                    ),
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
                    label: GlossaryLabel(
                      text: 'Twist (1:in)',
                      glossaryTerm: 'Twist rate',
                    ),
                    helperText: 'e.g. 8 for 1:8',
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              // BC is hidden when a custom drag curve is active because
              // CDM/DSF curves replace the BC + reference-shape pair —
              // there's no reference projectile to scale against. We
              // render an explanation in its place so the row keeps
              // its width and the drag-function selector doesn't jump.
              if (!_useCustomDragCurve)
                Expanded(
                  child: TextField(
                    controller: _bcCtrl,
                    keyboardType: const TextInputType.numberWithOptions(
                        decimal: true),
                    onChanged: (_) => _clearStaleProfileMissing(),
                    decoration: InputDecoration(
                      label: const GlossaryLabel(
                        text: 'BC',
                        glossaryTerm: 'Ballistic Coefficient — G1',
                      ),
                      helperText: 'In the chosen drag-model family',
                      errorText: _profileErrorTextFor('bc'),
                    ),
                  ),
                )
              else
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    child: Text(
                      'Custom curves don\'t use a BC — the curve already '
                      'captures the bullet\'s real Cd vs Mach.',
                      style:
                          Theme.of(context).textTheme.bodySmall?.copyWith(
                                color: Theme.of(context)
                                    .colorScheme
                                    .onSurfaceVariant,
                              ),
                    ),
                  ),
                ),
              const SizedBox(width: 12),
              Expanded(child: _dragFunctionSelector()),
            ],
          ),
          if (_useCustomDragCurve) ...[
            const SizedBox(height: 12),
            _customDragCurvePicker(),
          ],
        ],
      ),
    );
  }

  /// Combined drag-function selector. The user picks between G1/G2/G5/
  /// G6/G7/G8 (the standard reference projectile families) and "Custom",
  /// which switches the calculator to use a manufacturer-supplied
  /// CDM/DSF curve from the seeded catalog. We model "Custom" as a
  /// nullable sentinel because Dart enums don't allow us to extend
  /// [DragModel] without breaking the solver.
  ///
  /// The "Custom (CDM / DSF)" entry is Pro-only — the catalog ships 300
  /// measured Hornady 4DOF curves and gating those is one of the named
  /// Pro pitch buckets. Free users see the row labelled "Pro"; tapping
  /// it routes through `ensurePro` to the paywall.
  Widget _dragFunctionSelector() {
    // Sentinel value the dropdown exposes for the "Custom" entry.
    // Kept inside the closure so it doesn't leak into other call
    // sites — the toggle is private to this widget.
    const customSentinel = -1;
    final isPro = context.watch<EntitlementNotifier>().isPro;
    final currentValue =
        _useCustomDragCurve ? customSentinel : _dragModel.index;
    return DropdownButtonFormField<int>(
      initialValue: currentValue,
      isExpanded: true,
      decoration: const InputDecoration(
        label: GlossaryLabel(
          text: 'Drag function',
          glossaryTerm: 'Drag',
        ),
      ),
      items: [
        for (final m in DragModel.values)
          DropdownMenuItem(
            value: m.index,
            child: Text(m.label, overflow: TextOverflow.ellipsis),
          ),
        DropdownMenuItem(
          value: customSentinel,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Flexible(
                child: Text(
                  'Custom (CDM / DSF)',
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              if (!isPro) ...[
                const SizedBox(width: 6),
                _proBadge(),
              ],
            ],
          ),
        ),
      ],
      onChanged: (v) async {
        if (v == null) return;
        if (v == customSentinel) {
          // Pro-gate: free users see the paywall; if they upgrade we
          // continue into custom-drag mode, otherwise we bail without
          // changing state.
          if (!await ensurePro(context)) return;
          if (!mounted) return;
          setState(() {
            _useCustomDragCurve = true;
          });
          _autoSave.notifyDirty();
          return;
        }
        setState(() {
          _useCustomDragCurve = false;
          _selectedDragCurve = null;
          _dragModel = DragModel.values[v];
        });
        _autoSave.notifyDirty();
      },
    );
  }

  /// Compact "Pro" pill rendered next to gated entries in dropdowns and
  /// inline rows on the ballistics screen. Brass-tinted to match the
  /// rest of the app's monetization affordances.
  Widget _proBadge() {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      decoration: BoxDecoration(
        color: theme.colorScheme.primary.withValues(alpha: 0.16),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(
          color: theme.colorScheme.primary.withValues(alpha: 0.55),
          width: 0.8,
        ),
      ),
      child: Text(
        'Pro',
        style: theme.textTheme.labelSmall?.copyWith(
          color: theme.colorScheme.primary,
          fontWeight: FontWeight.w600,
          fontSize: 10,
          letterSpacing: 0.2,
        ),
      ),
    );
  }

  /// Inline chip surfaced above the DOPE table when the most-recent
  /// solve used a non-default scope tracking calibration. We read
  /// the values from `_lastSolvedShot` rather than the live
  /// controllers so the chip always reflects the actual numbers
  /// that produced the displayed table — even if the user has
  /// since edited the input fields and not re-solved yet. Hidden
  /// when both scales are 1.000 so the common case stays clean.
  Widget _scopeTrackingActiveChip() {
    final shot = _lastSolvedShot;
    if (shot == null) return const SizedBox.shrink();
    final v = shot.sightScaleVertical;
    final h = shot.sightScaleHorizontal;
    if ((v - 1.0).abs() < 1e-6 && (h - 1.0).abs() < 1e-6) {
      return const SizedBox.shrink();
    }
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: theme.colorScheme.tertiaryContainer.withValues(alpha: 0.45),
          borderRadius: BorderRadius.circular(6),
          border: Border.all(
            color: theme.colorScheme.tertiary.withValues(alpha: 0.5),
            width: 0.8,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.tune,
              size: 14,
              color: theme.colorScheme.onTertiaryContainer,
            ),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                'Scope tracking calibration active · '
                'V ${v.toStringAsFixed(3)} · H ${h.toStringAsFixed(3)}',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onTertiaryContainer,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Curve-selection dropdown shown only when the user has picked
  /// "Custom" on the drag-function selector. Sources its list from
  /// [_dragCurvesFuture]; an empty catalog renders an explanatory
  /// helper-text instead of a useless empty dropdown.
  Widget _customDragCurvePicker() {
    return FutureBuilder<List<DragCurveRow>>(
      future: _dragCurvesFuture,
      builder: (context, snap) {
        if (snap.connectionState == ConnectionState.waiting) {
          return const Padding(
            padding: EdgeInsets.symmetric(vertical: 8),
            child: LinearProgressIndicator(),
          );
        }
        final curves = snap.data ?? const <DragCurveRow>[];
        if (curves.isEmpty) {
          return Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Text(
              'No custom drag curves are bundled in this build. Switch '
              'back to a G-curve, or add curve files to '
              'assets/seed_data/drag_curves/curves.json.',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
            ),
          );
        }
        return DropdownButtonFormField<int>(
          initialValue: _selectedDragCurve?.id,
          isExpanded: true,
          decoration: const InputDecoration(
            labelText: 'Custom drag curve',
            helperText:
                'Doppler-radar Cd vs Mach for a specific bullet — replaces '
                'BC + G-curve.',
          ),
          items: [
            for (final c in curves)
              DropdownMenuItem(
                value: c.id,
                child: Text(
                  DragCurveRepository.displayLabel(c),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
          ],
          onChanged: (id) {
            if (id == null) return;
            final picked = curves.firstWhere(
              (c) => c.id == id,
              orElse: () => curves.first,
            );
            setState(() {
              _selectedDragCurve = picked;
            });
            _autoSave.notifyDirty();
          },
        );
      },
    );
  }

  Widget _bulletPicker() {
    // Unified picker over BOTH the user's saved recipes AND the
    // bullet catalog. Recipes surface first (the user's own
    // materials are always more relevant than browsing the raw
    // catalog), then catalog bullets. Picking a recipe populates
    // bullet name + weight from the recipe row; picking a bullet
    // populates diameter + weight + BC + drag model. The picker is
    // labeled "Pick a Saved Load or Bullet" to reflect both
    // sources — the old "Pick from catalog" wording was incorrect
    // since catalog-only doesn't tell the user their own loads
    // belong here too.
    return StreamBuilder<List<UserLoadRow>>(
      stream: _recipesStream,
      builder: (context, recipesSnap) {
        return FutureBuilder<List<ManufacturedAmmoRow>>(
          future: _ammoFuture,
          builder: (context, ammoSnap) {
            return FutureBuilder<List<({BulletRow bullet, ManufacturerRow mfg})>>(
              future: _bulletsFuture,
              builder: (context, snap) {
                if (snap.connectionState == ConnectionState.waiting) {
                  return const Padding(
                    padding: EdgeInsets.symmetric(vertical: 8),
                    child: LinearProgressIndicator(),
                  );
                }
                final bullets = snap.data ?? const [];
                final recipes = recipesSnap.data ?? const <UserLoadRow>[];
                final ammo = ammoSnap.data ?? const <ManufacturedAmmoRow>[];
                // Build the unified entry list — three sources stacked
                // by relevance: the user's saved recipes first (their
                // own materials), then curated manufactured ammo (the
                // factory loads they're most likely to actually shoot),
                // then the broad bullet catalog.
                final entries = <_ProjectileEntry>[
                  for (final r in recipes) _RecipeProjectileEntry(r),
                  for (final a in ammo) _AmmoProjectileEntry(a),
                  for (final b in bullets) _BulletProjectileEntry(b.bullet, b.mfg),
                ];
            // Resolve the current display string for the
            // Autocomplete's initial value. Precedence (most recent
            // user action wins): recipe → manufactured-ammo → bullet.
            // `_clearBulletSelection` clears all three, but a stale
            // race could leave more than one populated for one frame.
            final initialText = _selectedRecipe != null
                ? _recipeLabel(_selectedRecipe!)
                : _selectedAmmo != null
                    ? _ammoLabel(_selectedAmmo!)
                    : (_selectedBullet == null
                        ? ''
                        : _bulletLabel(
                            _selectedBullet!.bullet, _selectedBullet!.mfg));
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Autocomplete<_ProjectileEntry>(
                        initialValue: TextEditingValue(text: initialText),
                        displayStringForOption: (e) => e.label,
                        optionsBuilder: (te) {
                          final q = te.text.trim().toLowerCase();
                          if (q.isEmpty) return entries;
                          final tokens = q
                              .split(RegExp(r'\s+'))
                              .where((t) => t.isNotEmpty)
                              .toList(growable: false);
                          if (tokens.isEmpty) return entries;
                          return entries.where((e) {
                            final label = e.label.toLowerCase();
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
                              labelText: 'Pick a Saved Load or Bullet',
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
                        onSelected: (entry) {
                          switch (entry) {
                            case _RecipeProjectileEntry(:final recipe):
                              _applyRecipeSelection(recipe);
                            case _AmmoProjectileEntry(:final ammo):
                              _applyAmmoSelection(ammo);
                            case _BulletProjectileEntry(
                                :final bullet,
                                :final mfg
                              ):
                              _applyBulletSelection(
                                  (bullet: bullet, mfg: mfg));
                          }
                        },
                        optionsViewBuilder: (context, onSelected, options) {
                          final theme = Theme.of(context);
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
                                    final IconData icon;
                                    final String subtitle;
                                    switch (e) {
                                      case _RecipeProjectileEntry _:
                                        icon = Icons.science_outlined;
                                        subtitle = 'My Recipe';
                                      case _AmmoProjectileEntry _:
                                        icon = Icons.inventory_2_outlined;
                                        subtitle = 'Manufactured Ammo';
                                      case _BulletProjectileEntry _:
                                        icon = Icons.album_outlined;
                                        subtitle = 'Bullet Catalog';
                                    }
                                    return ListTile(
                                      dense: true,
                                      leading: Icon(
                                        icon,
                                        size: 18,
                                        color: theme.colorScheme.primary,
                                      ),
                                      title: Text(e.label),
                                      subtitle: Text(subtitle),
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
                  onPressed: (_selectedBullet == null &&
                          _selectedRecipe == null &&
                          _selectedAmmo == null)
                      ? null
                      : _clearBulletSelection,
                  icon: const Icon(Icons.refresh, size: 18),
                  label: const Text('Clear'),
                ),
              ],
            ),
            // "Custom drag available" badge — surfaces when the user
            // picks a bullet that has a matching CDM/DSF curve in the
            // catalog. Tapping it switches the calculator to that
            // curve in one move (no rummaging in the drag-function
            // dropdown).
            if (_bulletHasCustomCurve)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: _customDragAvailableBadge(),
              ),
          ],
        );
      },
            );
          },
        );
      },
    );
  }

  /// Small chip-like banner surfaced under the bullet picker when the
  /// selected bullet has a matching custom drag curve in the catalog.
  /// Tapping it auto-applies the matching curve and switches the
  /// drag-function selector to "Custom".
  ///
  /// The catalog ships measured Hornady 4DOF curves and is Pro-only.
  /// Free users see the same "Custom drag available" affordance, but
  /// with a "Pro" badge appended; tapping routes through `ensurePro`.
  Widget _customDragAvailableBadge() {
    final theme = Theme.of(context);
    final isPro = context.watch<EntitlementNotifier>().isPro;
    return InkWell(
      borderRadius: BorderRadius.circular(8),
      onTap: () async {
        final sel = _selectedBullet;
        if (sel == null) return;
        // Pro-gate: free users get the paywall before we apply the
        // measured curve. If they upgrade we continue; otherwise bail
        // (the bullet's G7 BC stays on the row, which is the documented
        // graceful fallback).
        if (!await ensurePro(context)) return;
        if (!mounted) return;
        final repo = context.read<DragCurveRepository>();
        final match = await repo.findCurveForBullet(
          manufacturer: sel.mfg.name,
          line: sel.bullet.line,
          weightGr: sel.bullet.weightGr,
          diameterIn: sel.bullet.diameterIn,
        );
        if (!mounted || match == null) return;
        setState(() {
          _useCustomDragCurve = true;
          _selectedDragCurve = match;
        });
      },
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: theme.colorScheme.primaryContainer.withAlpha(120),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: theme.colorScheme.primary.withAlpha(80),
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.show_chart,
              size: 16,
              color: theme.colorScheme.primary,
            ),
            const SizedBox(width: 6),
            Text(
              isPro
                  ? 'Custom drag available — tap to apply'
                  : 'Hornady 4DOF curve available — tap to upgrade',
              style: theme.textTheme.labelSmall?.copyWith(
                color: theme.colorScheme.primary,
              ),
            ),
            if (!isPro) ...[
              const SizedBox(width: 6),
              _proBadge(),
            ],
          ],
        ),
      ),
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
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    TextField(
                      controller: _muzzleVelCtrl,
                      keyboardType: const TextInputType.numberWithOptions(
                          decimal: true),
                      onChanged: (_) => _clearStaleProfileMissing(),
                      decoration: InputDecoration(
                        label: GlossaryLabel(
                          text: 'Muzzle velocity ($velUnit)',
                          glossaryTerm: 'Muzzle Velocity',
                        ),
                        suffixText: velUnit,
                        errorText: _profileErrorTextFor('muzzleVelocity'),
                      ),
                    ),
                    // Inline pivot to the Internal Ballistics tab
                    // pre-filled with the bullet specs the user has
                    // already typed. Surfaced precisely when the user
                    // is missing MV (no chronograph data yet) — the
                    // moment they tap, the Internal calculator opens
                    // with the matching fields populated and "Use
                    // This MV" comes back to fill this field. The
                    // link hides once MV is filled to avoid clutter
                    // on the common path where the user has chrono
                    // data and just types it.
                    AnimatedBuilder(
                      animation: _muzzleVelCtrl,
                      builder: (context, _) {
                        if (_muzzleVelCtrl.text.trim().isNotEmpty) {
                          return const SizedBox.shrink();
                        }
                        return Padding(
                          padding: const EdgeInsets.only(top: 4),
                          child: Align(
                            alignment: Alignment.centerLeft,
                            child: TextButton.icon(
                              onPressed: _openInternalForMvPredict,
                              icon: const Icon(
                                Icons.calculate_outlined,
                                size: 16,
                              ),
                              label: const Text("Don't Know Your MV?"),
                              style: TextButton.styleFrom(
                                visualDensity: VisualDensity.compact,
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 8,
                                ),
                              ),
                            ),
                          ),
                        );
                      },
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: TextField(
                  controller: _sightHeightCtrl,
                  keyboardType: const TextInputType.numberWithOptions(
                      decimal: true),
                  decoration: InputDecoration(
                    label: GlossaryLabel(
                      text: 'Sight height ($smallLen)',
                      glossaryTerm: 'Eye relief',
                    ),
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
                    label: GlossaryLabel(
                      text: 'Zero range ($rangeUnit)',
                      glossaryTerm: 'DOPE',
                    ),
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
                    label: GlossaryLabel(
                      text: 'Shot azimuth (°)',
                      glossaryTerm: 'Azimuth',
                    ),
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
              label: GlossaryLabel(
                text: 'Target elevation Δ (ft)',
                glossaryTerm: 'Incline / decline angle',
              ),
              helperText: 'Positive = uphill',
            ),
          ),
        ],
      ),
    );
  }

  // ─────────────────────── Atmosphere preset picker ───────────────────────

  /// Build the [AtmosphereSnapshot] used by the inline picker to
  /// determine whether the live values match a saved preset. The
  /// controllers hold values in the user's chosen display unit, so we
  /// convert each one back to canonical (inHg / °F / %) before passing
  /// to the picker. Any field that fails to parse becomes null on the
  /// snapshot — `AtmosphereSnapshot.matches` treats that as "won't
  /// match anything".
  AtmosphereSnapshot _atmosphereSnapshotForPicker(UnitService units) {
    double? toCanonicalPressure(String s) {
      final v = double.tryParse(s.trim());
      if (v == null) return null;
      return _pressureToCanonical(
          v, units.unitFor(UnitCategory.pressure));
    }

    double? toCanonicalTemp(String s) {
      final v = double.tryParse(s.trim());
      if (v == null) return null;
      return _tempToCanonical(
          v, units.unitFor(UnitCategory.temperature));
    }

    return AtmosphereSnapshot(
      stationPressureInHg: toCanonicalPressure(_pressureCtrl.text),
      temperatureF: toCanonicalTemp(_tempCtrl.text),
      humidityPct: double.tryParse(_humidityCtrl.text.trim()),
      altitudeFt: double.tryParse(_altitudeCtrl.text.trim()),
    );
  }

  /// Apply a saved atmosphere preset to the four Environment controllers.
  /// Values stored on `AtmospherePresetRow` are canonical imperial; we
  /// convert each one to the user's current display unit before writing
  /// back to the controllers. Triggers a recompute so the trajectory
  /// chart updates immediately.
  void _applyAtmospherePreset(AtmospherePresetRow preset) {
    final units = context.read<UnitService>();
    setState(() {
      _pressureCtrl.text = _formatNumber(_pressureFromCanonical(
          preset.stationPressureInHg,
          units.unitFor(UnitCategory.pressure)));
      _tempCtrl.text = _formatNumber(_tempFromCanonical(
          preset.temperatureF, units.unitFor(UnitCategory.temperature)));
      _humidityCtrl.text = preset.humidityPct.toStringAsFixed(0);
      if (preset.altitudeFt != null) {
        _altitudeCtrl.text = preset.altitudeFt!.toStringAsFixed(0);
      }
    });
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        duration: const Duration(seconds: 2),
        content: Text('Loaded "${preset.name}"'),
      ),
    );
  }

  /// Captures the live atmosphere fields into a new
  /// [AtmospherePresetRow]. Reads each field, converts back to
  /// canonical imperial, and opens the Save-as-preset dialog with the
  /// values pre-filled.
  Future<void> _onSaveCurrentAsAtmospherePreset() async {
    final units = context.read<UnitService>();
    final messenger = ScaffoldMessenger.of(context);
    final pressureText = _pressureCtrl.text.trim();
    final tempText = _tempCtrl.text.trim();
    final humidityText = _humidityCtrl.text.trim();
    final pressure = double.tryParse(pressureText);
    final temp = double.tryParse(tempText);
    final humidity = double.tryParse(humidityText);
    if (pressure == null || temp == null || humidity == null) {
      messenger.showSnackBar(
        const SnackBar(
          content: Text(
              'Fill in pressure, temperature, and humidity before saving.'),
        ),
      );
      return;
    }
    final pressureInHg = _pressureToCanonical(
        pressure, units.unitFor(UnitCategory.pressure));
    final tempF = _tempToCanonical(
        temp, units.unitFor(UnitCategory.temperature));
    final altitudeFt = double.tryParse(_altitudeCtrl.text.trim());
    await showSaveAtmospherePresetDialog(
      context,
      stationPressureInHg: pressureInHg,
      temperatureF: tempF,
      humidityPct: humidity,
      altitudeFt: altitudeFt,
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
      // Surface every captured value so the user sees what was pulled
      // — instead of fields silently filling. Multi-line snackbar
      // gives the long content room to breathe; 6s gives enough time
      // to read.
      messenger.showSnackBar(
        SnackBar(
          duration: const Duration(seconds: 6),
          content: Text(
            '✓ Pulled from your location\n'
            '  Altitude: ${result.elevationFt.toStringAsFixed(0)} ft  ·  '
            'Station: ${result.stationPressureInHg.toStringAsFixed(2)} inHg  ·  '
            'Temp: ${result.tempF.toStringAsFixed(0)}°F  ·  '
            'Humidity: ${result.humidityPct.toStringAsFixed(0)}%  ·  '
            'Wind: ${result.windSpeedMph.toStringAsFixed(0)} mph @ '
            '${result.windDirectionDeg.toStringAsFixed(0)}°',
          ),
          action: SnackBarAction(
            label: 'Save as preset',
            onPressed: () {
              // ignore: discarded_futures
              showSaveAtmospherePresetDialog(
                context,
                stationPressureInHg: result.stationPressureInHg,
                temperatureF: result.tempF,
                humidityPct: result.humidityPct,
                altitudeFt: result.elevationFt,
              );
            },
          ),
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
        label: const Text('Stop Using Kestrel'),
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
    if (!mounted) return;
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
          AtmospherePresetPicker(
            snapshot: _atmosphereSnapshotForPicker(units),
            onApplyPreset: _applyAtmospherePreset,
            onSaveAsPreset: _onSaveCurrentAsAtmospherePreset,
          ),
          const SizedBox(height: 12),
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
                    label: GlossaryLabel(
                      text: 'Pressure ($pressureLabel)',
                      glossaryTerm: 'Station pressure',
                    ),
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
                    label: GlossaryLabel(
                      text: 'Elevation (ft)',
                      glossaryTerm: 'Density altitude',
                    ),
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
                    label: GlossaryLabel(
                      text: 'Wind ($windLabel)',
                      glossaryTerm: 'Wind drift',
                    ),
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
                    label: GlossaryLabel(
                      text: 'Wind from (°)',
                      glossaryTerm: 'Wind direction (from convention)',
                    ),
                    helperText: '0=tail, 90=right',
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          // wind-bracket uncertainty input. Drives the wind-bracket
          // card in the Output section; setting it to 0 hides the card.
          TextField(
            controller: _windUncertaintyCtrl,
            keyboardType: const TextInputType.numberWithOptions(
                decimal: true),
            decoration: InputDecoration(
              label: GlossaryLabel(
                text: 'Wind uncertainty (± $windLabel)',
                glossaryTerm: 'Wind uncertainty',
              ),
              helperText:
                  'How sure are you of the wind speed? Drives the '
                  'wind-bracket card. Set to 0 to hide.',
              helperMaxLines: 2,
              suffixText: windLabel,
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _latitudeCtrl,
            keyboardType: const TextInputType.numberWithOptions(
                decimal: true, signed: true),
            decoration: const InputDecoration(
              label: GlossaryLabel(
                text: 'Latitude (°N)',
                glossaryTerm: 'Latitude',
              ),
              helperText: 'Used by Coriolis',
            ),
          ),
        ],
      ),
    );
  }

  /// Advanced inputs section. Hidden by default behind an
  /// `ExpansionTile` so the default ballistics screen doesn't get
  /// cluttered. When opened, exposes:
  ///
  ///   * Aerodynamic jump multiplier (industry-standard spin-drift jump term)
  ///   * Twist direction (right/left) — flips spin-drift sign
  ///   * Sight scale factors (vertical / horizontal) — corrects scopes
  ///     whose tracking does not match advertised mil/MOA values
  ///   * Powder temperature sensitivity (fps/°C) + reference temp (°C)
  ///   * Zero atmosphere (pressure / temperature / humidity)
  ///   * Incline / decline angle (slope of fire)
  ///
  /// All optional. When left blank, the solver uses its existing
  /// defaults. Free-typed values always take priority over auto-fill
  /// from a picked firearm/load.
  Widget _advancedSection() {
    final theme = Theme.of(context);
    return Card(
      clipBehavior: Clip.antiAlias,
      child: Theme(
        data: theme.copyWith(dividerColor: Colors.transparent),
        child: ExpansionTile(
          initiallyExpanded: _advancedExpanded,
          onExpansionChanged: (v) => setState(() => _advancedExpanded = v),
          tilePadding: const EdgeInsets.fromLTRB(16, 4, 12, 4),
          childrenPadding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
          leading: Icon(Icons.science_outlined,
              size: 20, color: theme.colorScheme.primary),
          title: Text(
            'Advanced',
            style: theme.textTheme.titleMedium,
          ),
          subtitle: Text(
            'Stability and form factor, aerodynamic jump, twist '
            'direction, sight scale, powder temp sensitivity, zero '
            'atmosphere, incline.',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          children: [
            // Stability + form factor read-out (free / informational).
            // Hides cleanly when bullet inputs aren't sufficient yet.
            _stabilityAndFormFactor(),
            const SizedBox(height: 12),
            // Twist direction.
            Row(
              children: [
                Expanded(
                  child: Text(
                    'Twist direction',
                    style: theme.textTheme.bodyMedium,
                  ),
                ),
                SegmentedButton<String>(
                  showSelectedIcon: false,
                  segments: const [
                    ButtonSegment<String>(
                      value: 'right',
                      label: Text('Right'),
                    ),
                    ButtonSegment<String>(
                      value: 'left',
                      label: Text('Left'),
                    ),
                  ],
                  selected: {_twistDirection},
                  onSelectionChanged: (s) {
                    setState(() => _twistDirection = s.first);
                    _autoSave.notifyDirty();
                  },
                ),
              ],
            ),
            const SizedBox(height: 12),
            // Sight scale.
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _sightScaleVerticalCtrl,
                    keyboardType: const TextInputType.numberWithOptions(
                        decimal: true),
                    decoration: const InputDecoration(
                      labelText: 'Sight scale vertical',
                      hintText: '1.000',
                      helperText: '1.000 = no correction',
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: TextField(
                    controller: _sightScaleHorizontalCtrl,
                    keyboardType: const TextInputType.numberWithOptions(
                        decimal: true),
                    decoration: const InputDecoration(
                      labelText: 'Sight scale horizontal',
                      hintText: '1.000',
                      helperText: '1.000 = no correction',
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            // Aerodynamic jump multiplier.
            TextField(
              controller: _aerodynamicJumpCtrl,
              keyboardType: const TextInputType.numberWithOptions(
                  decimal: true, signed: true),
              decoration: const InputDecoration(
                label: GlossaryLabel(
                  text: 'Aerodynamic jump (multiplier)',
                  glossaryTerm: 'Aerodynamic jump',
                ),
                hintText: 'e.g. 0.0 (off) or ±0.05',
                helperText:
                    'aerodynamic jump term. Positive multiplier '
                    'tilts the bullet axis with crosswind on launch.',
                helperMaxLines: 3,
              ),
            ),
            const SizedBox(height: 12),
            // Powder temp sensitivity (fps/°C + reference °C).
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _powderTempSensitivityCtrl,
                    keyboardType: const TextInputType.numberWithOptions(
                        decimal: true, signed: true),
                    decoration: const InputDecoration(
                      labelText: 'Powder temp sens (fps/°C)',
                      hintText: 'e.g. 0.4',
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: TextField(
                    controller: _powderReferenceTempCtrl,
                    keyboardType: const TextInputType.numberWithOptions(
                        decimal: true, signed: true),
                    decoration: const InputDecoration(
                      labelText: 'Reference (°C)',
                      hintText: 'e.g. 15.6',
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            // Zero atmosphere.
            Text(
              'Zero atmosphere (where you sighted in)',
              style: theme.textTheme.labelLarge?.copyWith(
                color: theme.colorScheme.primary,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _zeroPressureInHgCtrl,
                    keyboardType: const TextInputType.numberWithOptions(
                        decimal: true),
                    decoration: const InputDecoration(
                      labelText: 'Zero pressure (inHg)',
                      hintText: 'e.g. 29.92',
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: TextField(
                    controller: _zeroTemperatureFCtrl,
                    keyboardType: const TextInputType.numberWithOptions(
                        decimal: true, signed: true),
                    decoration: const InputDecoration(
                      labelText: 'Zero temp (°F)',
                      hintText: 'e.g. 65',
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _zeroHumidityPctCtrl,
              keyboardType:
                  const TextInputType.numberWithOptions(decimal: true),
              decoration: const InputDecoration(
                labelText: 'Zero humidity (%)',
                hintText: 'e.g. 50',
              ),
            ),
            const SizedBox(height: 12),
            // Incline / decline.
            TextField(
              controller: _inclineAngleCtrl,
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
                signed: true,
              ),
              decoration: const InputDecoration(
                labelText: 'Incline / decline (°)',
                helperText: 'Positive = uphill; negative = downhill',
                helperMaxLines: 2,
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Sister-calculator pivot button. The external-ballistics screen
  /// (this one) answers "where will the bullet land?"; the internal
  /// calculator answers "is this load over pressure?". A reloader who
  /// Top-of-screen calculator toggle. Two tabs: External Ballistics
  /// (the trajectory solver, this screen's original surface) and
  /// Internal Ballistics (the pressure / MV predictor formerly only
  /// reached via Resources or a bottom-of-page button). Both are
  /// first-class peers — see [_activeCalculator] for the rationale.
  Widget _calculatorTabToggle() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
      child: SegmentedButton<_CalculatorTab>(
        segments: const [
          ButtonSegment<_CalculatorTab>(
            value: _CalculatorTab.external,
            label: Text('External Ballistics'),
            icon: Icon(Icons.timeline_outlined),
          ),
          ButtonSegment<_CalculatorTab>(
            value: _CalculatorTab.internal,
            label: Text('Internal Ballistics'),
            icon: Icon(Icons.calculate_outlined),
          ),
        ],
        selected: {_activeCalculator},
        onSelectionChanged: (selection) {
          setState(() {
            _activeCalculator = selection.first;
            // Switching tabs by user action clears any prefill from a
            // previous "Don't Know Your MV?" handoff so the next visit
            // to Internal starts clean unless the user re-invokes the
            // link.
            if (_activeCalculator == _CalculatorTab.external) {
              _internalPrefill = null;
            }
          });
        },
      ),
    );
  }

  /// Body of the Internal Ballistics tab. Embeds the standalone
  /// `InternalBallisticsScreen` widget WITHOUT its Scaffold + AppBar
  /// (`wrapInScaffold: false`) so the calculator nests cleanly under
  /// this screen's existing Scaffold. Hands the screen its
  /// pre-fill (if a "Don't Know Your MV?" link populated it) and the
  /// `onMvAccepted` callback that closes the loop by writing the
  /// predicted velocity into the External form's MV field and
  /// flipping the tab back to External.
  Widget _internalCalculatorBody() {
    return InternalBallisticsScreen(
      // Re-key on prefill identity so a fresh handoff (user taps the
      // link a second time after editing inputs) actually re-mounts
      // the state and applies the new prefill in initState. Without
      // this, Flutter would keep the existing State and ignore the
      // new prefill values.
      key: ValueKey(_internalPrefill),
      wrapInScaffold: false,
      prefill: _internalPrefill,
      onMvAccepted: _acceptPredictedMv,
    );
  }

  /// Inline link rendered next to the Muzzle Velocity field. Only
  /// shown when MV is empty — the user has all the OTHER recipe
  /// inputs typed but doesn't know their velocity. Tapping flips
  /// the calculator tab to Internal with a prefill carrying every
  /// matching field this screen already knows.
  void _openInternalForMvPredict() {
    String? nonEmpty(TextEditingController c) {
      final t = c.text.trim();
      return t.isEmpty ? null : t;
    }

    setState(() {
      // External Ballistics carries bullet diameter / weight / length.
      // It does NOT track COAL, barrel length, charge, powder, case
      // capacity, or case length — those are reloading-recipe inputs
      // the Internal calculator owns. The user fills the gap on the
      // Internal tab; we just save them re-typing what we already
      // know. Bore diameter sensibly defaults to bullet diameter
      // (rifling lands sit a few thou under, but the user can edit).
      _internalPrefill = InternalBallisticsPrefill(
        bulletWeightGr: nonEmpty(_weightCtrl),
        bulletDiameterIn: nonEmpty(_diameterCtrl),
        bulletLengthIn: nonEmpty(_lengthCtrl),
        boreDiameterIn: nonEmpty(_diameterCtrl),
      );
      _activeCalculator = _CalculatorTab.internal;
    });
  }

  /// Receives a predicted muzzle velocity from the embedded Internal
  /// calculator (user tapped "Use This MV"). Writes it back into the
  /// External form's MV field, flips the tab back to External, and
  /// shows a snackbar so the user sees the value landed.
  void _acceptPredictedMv(double fps) {
    if (!mounted) return;
    setState(() {
      _muzzleVelCtrl.text = fps.toStringAsFixed(0);
      _activeCalculator = _CalculatorTab.external;
      _internalPrefill = null;
    });
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('Predicted MV ${fps.toStringAsFixed(0)} fps applied.'),
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
            // Tracking-calibration tell-tale. Renders only when the
            // last solve used a non-default scope tracking scale so
            // the user sees that their drop / wind numbers are being
            // multiplied by a non-1.0 calibration. Hidden in the
            // common 1.000 / 1.000 case.
            _scopeTrackingActiveChip(),
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
            // wind-bracket card. Hides when uncertainty is 0 /
            // null. Anchored on the longest range in the ladder so
            // the bracket envelope is meaningful (long range is
            // where wind error matters).
            if (_lastSolvedProjectile != null &&
                _lastSolvedEnvironment != null &&
                _lastSolvedShot != null &&
                _lastSolvedRanges != null &&
                _lastSolvedWindMph != null &&
                _lastSolvedWindUncertaintyMph != null)
              _windBracketCard(
                projectile: _lastSolvedProjectile!,
                environment: _lastSolvedEnvironment!,
                shot: _lastSolvedShot!,
                rangeYards: _lastSolvedRanges!.last,
                windMph: _lastSolvedWindMph!,
                windUncertaintyMph: _lastSolvedWindUncertaintyMph!,
              ),
            const SizedBox(height: 16),
            // Per-effect contribution breakdown for the DOPE row the
            // user picks. Default-collapsed because the full solve
            // already answers the everyday question; this is the
            // "show me where the numbers come from" deep dive.
            if (_lastSolvedProjectile != null &&
                _lastSolvedEnvironment != null &&
                _lastSolvedShot != null &&
                _lastSolvedRanges != null)
              ContributionBreakdown(
                projectile: _lastSolvedProjectile!,
                environment: _lastSolvedEnvironment!,
                shot: _lastSolvedShot!,
                sampleRangesYards: _lastSolvedRanges!,
                fullSamples: _samples,
                unit: _unit,
              ),
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

  /// wind-bracket card. Computes the windage hold at three wind
  /// speeds — `wind − uncertainty`, `wind`, `wind + uncertainty` — and
  /// renders all three so the shooter can see the +/- envelope of
  /// their wind hold given how unsure they are of the wind speed. Per
  /// industry standard (exterior-ballistics literature vol. 1, ch. 5
  /// and *Applied Ballistics* 3rd ed., ch. 11), the shooter dials the
  /// MID hold; LOW and HIGH are the boundaries the bullet will fall
  /// within if the wind reading is off. Returns a `SizedBox.shrink()`
  /// when the bracket service can't produce a result (uncertainty 0,
  /// solver error, etc.).
  Widget _windBracketCard({
    required Projectile projectile,
    required Environment environment,
    required ShotInputs shot,
    required double rangeYards,
    required double windMph,
    required double windUncertaintyMph,
  }) {
    final theme = Theme.of(context);
    final result = computeWindBracket(
      projectile: projectile,
      environment: environment,
      shot: shot,
      rangeYards: rangeYards,
      windEstimateMph: windMph,
      windUncertaintyMph: windUncertaintyMph,
    );
    if (result == null) return const SizedBox.shrink();
    final units = context.watch<UnitService>();
    final windUnit = unitDisplayLabel(units.unitFor(UnitCategory.windSpeed));
    final rangeUnit = unitDisplayLabel(units.unitFor(UnitCategory.range));
    String fmtWind(double mph) {
      final disp = _windFromCanonical(mph, units.unitFor(UnitCategory.windSpeed));
      return '${disp.toStringAsFixed(1)} $windUnit';
    }

    String fmtRange(double yd) {
      final disp = _rangeFromCanonical(yd, units.unitFor(UnitCategory.range));
      return '${disp.toStringAsFixed(0)} $rangeUnit';
    }

    String fmtHold(double inches, double yd) {
      switch (_unit) {
        case AngleUnit.inches:
          final disp = units.convertSmallLength(inches);
          final lbl = unitDisplayLabel(
              units.unitFor(UnitCategory.smallLength));
          return '${disp.toStringAsFixed(1)} $lbl';
        case AngleUnit.moa:
          if (yd <= 0) return '—';
          return '${inchesToMoaAtYards(inches, yd).toStringAsFixed(1)} MOA';
        case AngleUnit.mil:
          if (yd <= 0) return '—';
          return '${inchesToMilAtYards(inches, yd).toStringAsFixed(2)} mil';
      }
    }

    // Wind-direction "o'clock" hint — converts windFromDegrees in the
    // shooter-relative frame (0 = behind, 90 = right) to a clock face
    // (6 = behind, 3 = right, 12 = front, 9 = left). The shooter
    // visualizes the wind on a clock the way the target visualizes it,
    // so 0° (wind from behind) reads as "6 o'clock wind".
    String windClock() {
      final from = environment.windFromDegrees;
      var raw = (6 - (from / 30.0).round()) % 12;
      if (raw < 0) raw += 12;
      final hour = raw == 0 ? 12 : raw;
      return "$hour o'clock";
    }

    return Card(
      clipBehavior: Clip.antiAlias,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.air,
                    color: theme.colorScheme.primary, size: 18),
                const SizedBox(width: 8),
                Text(
                  'Wind bracket · ${fmtRange(rangeYards)}',
                  style: theme.textTheme.titleMedium,
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              'Estimated ${fmtWind(result.windMidMph)} @ ${windClock()} '
              '· ± ${fmtWind(windUncertaintyMph)}',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 12),
            _windBracketRow(
                label: 'Low (${fmtWind(result.windLowMph)})',
                value: fmtHold(result.low.windDriftInches,
                    result.low.rangeYards),
                emphasis: false),
            const SizedBox(height: 6),
            _windBracketRow(
                label: 'Mid (${fmtWind(result.windMidMph)})',
                value: fmtHold(result.mid.windDriftInches,
                    result.mid.rangeYards),
                emphasis: true),
            const SizedBox(height: 6),
            _windBracketRow(
                label: 'High (${fmtWind(result.windHighMph)})',
                value: fmtHold(result.high.windDriftInches,
                    result.high.rangeYards),
                emphasis: false),
            const SizedBox(height: 10),
            Text(
              'Hold the mid; the bracket is your +/- bound if you '
              'misjudge the wind.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
                fontStyle: FontStyle.italic,
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Single line in the wind-bracket card: "Low (6 mph) ← 0.55 mil".
  /// `emphasis = true` for the Mid row gets the primary color.
  Widget _windBracketRow({
    required String label,
    required String value,
    required bool emphasis,
  }) {
    final theme = Theme.of(context);
    return Row(
      children: [
        Expanded(
          flex: 5,
          child: Text(
            label,
            style: theme.textTheme.bodyMedium?.copyWith(
              fontWeight: emphasis ? FontWeight.w600 : FontWeight.w400,
              color: emphasis
                  ? theme.colorScheme.primary
                  : theme.colorScheme.onSurface,
            ),
          ),
        ),
        Expanded(
          flex: 4,
          child: Text(
            value,
            textAlign: TextAlign.right,
            style: theme.textTheme.bodyMedium?.copyWith(
              fontWeight: emphasis ? FontWeight.w700 : FontWeight.w500,
              fontFeatures: const [FontFeature.tabularFigures()],
              color: emphasis
                  ? theme.colorScheme.primary
                  : theme.colorScheme.onSurface,
            ),
          ),
        ),
      ],
    );
  }

  /// Stability + form-factor read-out shown inside the Advanced
  /// section. Free, informational. Hides cleanly when the user
  /// hasn't entered the inputs needed to compute Sg (length / twist).
  Widget _stabilityAndFormFactor() {
    final theme = Theme.of(context);
    final diameter = double.tryParse(_diameterCtrl.text.trim());
    final weight = double.tryParse(_weightCtrl.text.trim());
    final length = double.tryParse(_lengthCtrl.text.trim());
    final twist = double.tryParse(_twistCtrl.text.trim());
    final bc = double.tryParse(_bcCtrl.text.trim());
    final mv = double.tryParse(_muzzleVelCtrl.text.trim());
    if (diameter == null ||
        weight == null ||
        diameter <= 0 ||
        weight <= 0) {
      return const SizedBox.shrink();
    }
    final projectile = Projectile(
      diameterIn: diameter,
      weightGr: weight,
      bc: bc ?? 0.0,
      dragModel: _dragModel,
      lengthIn: length,
      twistInches: twist,
    );

    final mvFps = mv ?? 2800;
    final miller = projectile.millerStability(mvFps);
    final pejsa = projectile.pejsaStability(mvFps);
    final i7 = projectile.formFactorI7;

    final hasStability = miller != null && pejsa != null;
    final hasFormFactor = !i7.isNaN;
    if (!hasStability && !hasFormFactor) {
      return const SizedBox.shrink();
    }

    return Container(
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(8),
      ),
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.flight_takeoff,
                  size: 16, color: theme.colorScheme.primary),
              const SizedBox(width: 6),
              GlossaryLabel(
                text: 'Stability and form factor',
                glossaryTerm: 'Miller stability formula',
                style: theme.textTheme.labelLarge?.copyWith(
                  color: theme.colorScheme.primary,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
          if (hasStability) ...[
            const SizedBox(height: 8),
            _stabilityRow('Miller Sg', miller),
            const SizedBox(height: 4),
            _stabilityRow('Pejsa Sg', pejsa),
            if (miller < 1.4 || pejsa < 1.4) ...[
              const SizedBox(height: 6),
              Text(
                'Both Sg > 1.4 needed for reliable flight; below that '
                'the bullet flies at marginal stability and BC degrades.',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.error,
                ),
              ),
            ],
          ] else ...[
            const SizedBox(height: 6),
            Text(
              'Add bullet length and twist rate to see stability factor.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
                fontStyle: FontStyle.italic,
              ),
            ),
          ],
          if (hasFormFactor) ...[
            const SizedBox(height: 10),
            Tooltip(
              message:
                  "Form factor compares this bullet's drag to the G7 "
                  'reference. Lower is better. <1.0 is more efficient '
                  'than the reference.',
              child: _formFactorRow(i7),
            ),
          ] else if (_dragModel == DragModel.g7 &&
              (bc ?? 0) > 0 &&
              !hasFormFactor) ...[
            const SizedBox(height: 6),
          ] else if (_dragModel != DragModel.g7) ...[
            const SizedBox(height: 6),
            Text(
              'Switch to G7 BC to see form factor (i7).',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
                fontStyle: FontStyle.italic,
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _stabilityRow(String label, double sg) {
    final theme = Theme.of(context);
    final Color color;
    final IconData icon;
    final String verdict;
    if (sg >= 1.5) {
      color = const Color(0xFF2E7D32); // green
      icon = Icons.check_circle;
      verdict = 'Stable';
    } else if (sg >= 1.0) {
      color = const Color(0xFFEF6C00); // amber
      icon = Icons.warning_amber;
      verdict = 'Marginal';
    } else {
      color = theme.colorScheme.error;
      icon = Icons.error;
      verdict = 'Unstable';
    }
    // "Miller Sg" / "Pejsa Sg" route to the corresponding glossary
    // entry; soft-fails to plain Text on a miss.
    final glossaryHint = label.startsWith('Miller')
        ? 'Miller stability formula'
        : (label.startsWith('Pejsa') ? 'Pejsa stability' : null);
    return Row(
      children: [
        SizedBox(
          width: 110,
          child: GlossaryLabel(
            text: label,
            glossaryTerm: glossaryHint,
            style: theme.textTheme.bodyMedium,
          ),
        ),
        SizedBox(
          width: 56,
          child: Text(
            sg.toStringAsFixed(2),
            style: theme.textTheme.bodyMedium?.copyWith(
              fontFeatures: const [FontFeature.tabularFigures()],
              fontWeight: FontWeight.w600,
              color: color,
            ),
          ),
        ),
        Icon(icon, size: 14, color: color),
        const SizedBox(width: 4),
        Text(
          verdict,
          style: theme.textTheme.bodySmall?.copyWith(color: color),
        ),
      ],
    );
  }

  Widget _formFactorRow(double i7) {
    final theme = Theme.of(context);
    final Color color;
    final IconData icon;
    final String verdict;
    if (i7 < 0.95) {
      color = const Color(0xFF2E7D32);
      icon = Icons.check_circle;
      verdict = 'Efficient';
    } else if (i7 <= 1.05) {
      color = const Color(0xFFEF6C00);
      icon = Icons.warning_amber;
      verdict = 'Average';
    } else {
      color = theme.colorScheme.error;
      icon = Icons.error;
      verdict = 'High drag';
    }
    return Row(
      children: [
        SizedBox(
          width: 110,
          child: GlossaryLabel(
            text: 'Form factor (i7)',
            glossaryTerm: 'Form factor (i7)',
            style: theme.textTheme.bodyMedium,
          ),
        ),
        SizedBox(
          width: 56,
          child: Text(
            i7.toStringAsFixed(3),
            style: theme.textTheme.bodyMedium?.copyWith(
              fontFeatures: const [FontFeature.tabularFigures()],
              fontWeight: FontWeight.w600,
              color: color,
            ),
          ),
        ),
        Icon(icon, size: 14, color: color),
        const SizedBox(width: 4),
        Text(
          verdict,
          style: theme.textTheme.bodySmall?.copyWith(color: color),
        ),
      ],
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
          // v16 — aerodynamic jump contribution per range. The solver
          // already breaks this out as `aerodynamicJumpInches` on each
          // TrajectorySample, so surfacing it as a column is just a
          // formatting concern. Signed value (positive = adds drop).
          DataColumn(
              label: Text('AeroJump (in)', style: headerStyle),
              numeric: true),
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
                // Aerodynamic jump contribution. Signed in raw inches
                // — keeping the breakdown column unit-free is fine
                // since this is a contribution, not a primary ballistic
                // output.
                DataCell(
                  Text(
                    s.aerodynamicJumpInches.toStringAsFixed(1),
                    style: cellStyle,
                  ),
                ),
              ],
            ),
        ],
      ),
    );
  }
}

// ─────────────────────── Projectile picker entry types ───────────────────────

/// Sealed entry type for the unified projectile picker. The
/// Autocomplete widget surfaces both the user's saved recipes
/// AND the bullet catalog in a single search box; this sealed
/// type lets us pattern-match in the `onSelected` callback to
/// route to the right populate-fields helper.
sealed class _ProjectileEntry {
  String get label;
}

class _RecipeProjectileEntry extends _ProjectileEntry {
  _RecipeProjectileEntry(this.recipe);
  final UserLoadRow recipe;
  @override
  String get label => recipe.name;
}

class _BulletProjectileEntry extends _ProjectileEntry {
  _BulletProjectileEntry(this.bullet, this.mfg);
  final BulletRow bullet;
  final ManufacturerRow mfg;
  @override
  String get label {
    final wt = bullet.weightGr.toStringAsFixed(
        bullet.weightGr.truncateToDouble() == bullet.weightGr ? 0 : 1);
    return '${mfg.name} ${bullet.line} ${wt}gr';
  }
}

class _AmmoProjectileEntry extends _ProjectileEntry {
  _AmmoProjectileEntry(this.ammo);
  final ManufacturedAmmoRow ammo;
  @override
  String get label =>
      '${ammo.manufacturer} ${ammo.cartridge} ${ammo.name}';
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
        'curves and spin-drift correction. Output is a planning aid; '
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

/// Discriminator for the top-of-screen calculator tab toggle. The
/// External tab is the historical Ballistics screen (trajectory
/// solver); the Internal tab embeds [InternalBallisticsScreen]
/// without its Scaffold so the pressure / MV predictor lives as a
/// peer surface rather than a hidden bottom-of-page link.
enum _CalculatorTab { external, internal }
