// FILE: lib/screens/range_day/range_day_detail_screen.dart
//
// ============================================================================
// WHAT THIS FILE DOES
// ============================================================================
// The Range Day workspace itself — the screen the user lives in WHILE at the
// range. A persistent slim "solution strip" at the very top renders the
// active load + distance + target + wind + drop + windage and stays put no
// matter how far the user scrolls (the goal is "glance → fire → glance"
// without scrubbing). Below it, a single scrollable column on phones / two
// columns on tablets carries these collapsible sections:
//
//   1. Setup        — target / distance / profile / load / firearm pickers,
//                     plus inline pickers for reticle, shot azimuth, incline,
//                     sensor capture, shooter capability, and the Litz
//                     analysis entrypoints. Collapses to a one-line summary
//                     so the user isn't staring at five dropdowns mid-session.
//   2. Environment  — temp, pressure, humidity, elevation, wind. Pull-from-
//                     weather button (Pro). Atmosphere preset picker. Live
//                     Kestrel toggle when one is paired. Collapses similarly.
//   3. Solution     — firing solution computed from the active inputs.
//                     Drop, wind, time of flight, velocity, energy. The
//                     biggest text on the screen — readable at arm's length.
//                     Plus optional Wind Bracket (Litz +/- envelope), Hit
//                     Probability gauge, and the Target Plot for tap-to-
//                     record-shot interaction.
//   4. Group stats  — extreme spread, mean radius, group MOA, σh / σv, plus
//                     a 90% CI band once N>=3, and the centroid + zero-
//                     adjust block.
//   5. Last shot correction (only when shots > 0) — "hold up X mil, right Y"
//                     to bring the next shot back to the aim point.
//   6. DOPE card    — 100yd-step trajectory ladder. Hidden until the solver
//                     produces a result.
//   7. Moving target (Pro) — speed + direction inputs that compute lead
//                            in mil / MOA / inches.
//   8. Notes        — freeform session notes.
//
// Recompute is debounced (500ms) so changing wind doesn't fire the solver
// on every keystroke. Sessions auto-save once they've been saved at least
// once.

import 'dart:async';
import 'dart:math' as math;

import 'package:drift/drift.dart' as drift;
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../data/reticle_library.dart';
import '../../database/database.dart';
import '../../repositories/ballistic_profile_repository.dart';
import '../../repositories/favorites_repository.dart';
import '../../repositories/firearm_repository.dart';
import '../../repositories/manufactured_ammo_repository.dart';
import '../../repositories/optics_repository.dart';
import '../../repositories/range_day_repository.dart';
import '../../repositories/recipe_repository.dart';
import '../../repositories/reticle_repository.dart';
import '../../repositories/target_repository.dart';
import '../../services/ballistics/atmosphere.dart';
import '../../services/ballistics/drag_functions.dart';
import '../../services/ballistics/environment.dart';
import '../../services/ballistics/group_stats.dart';
import '../../services/ballistics/projectile.dart';
import '../../services/ballistics/solver.dart';
import '../../services/ballistics/units.dart' as bu;
import '../../services/ballistics/wind_bracket_service.dart';
import '../../services/ble/ble_service.dart';
import '../../services/ble/bushnell_rangefinder_service.dart';
import '../../services/ble/garmin_xero_service.dart';
import '../../services/ble/kestrel_service.dart';
import '../../services/ble/leica_geovid_service.dart';
import '../../services/ble/rangefinder_reading.dart';
import '../../services/ble/sig_kilo_service.dart';
import '../../services/ble/vectronix_terrapin_service.dart';
import '../../services/ble/vortex_rangefinder_service.dart';
import '../../services/entitlement_notifier.dart';
import '../../services/hit_probability_service.dart';
import '../../screens/atmosphere/atmosphere_presets_screen.dart';
import '../../services/sensors/cant_service.dart';
import '../../services/common_loads_catalog.dart';
import '../../services/sensors/inclinometer_service.dart';
import '../../services/sensors/magnetometer_service.dart';
import '../../services/unit_service.dart';
import '../../widgets/empty_state_card.dart';
import '../../widgets/favorite_star_button.dart';
import '../../widgets/range_day_safety.dart';
import '../../services/weather_service.dart';
import '../../utils/responsive.dart';
import '../../widgets/atmosphere_preset_picker.dart';
import '../../widgets/glossary_label.dart';
import '../../widgets/pro_gate.dart';
import '../../widgets/reticle_picker.dart';
import '../ballistics/ballistics_screen.dart';
import 'bc_truing_screen.dart';
import 'range_day_mode.dart';
import 'range_day_screen.dart';
import 'scope_view_screen.dart';
import 'sight_calibration_screen.dart';
import 'wez_analysis_screen.dart';
import 'widgets/target_plot.dart';

/// Which kind of "target" the Setup picker is configuring. Mutually
/// exclusive — picking a single target nulls out any rack selection,
/// and vice versa, so downstream code only has to disambiguate via
/// the `_active*` helpers on the screen state. Lives at file scope so
/// it can be referenced from the state class without leaking it into
/// the public surface of the screen.
enum _TargetPickerMode { single, rack }

/// SharedPreferences key for the per-user Target Plot view-mode choice
/// (`realistic` vs `targetFocused`). Stored as the enum's `.name` so
/// the parser tolerates an unknown / corrupt value by falling back to
/// `targetFocused` (the existing default). File-private const because
/// no other surface needs the preference today.
const String _kTargetPlotViewModePrefKey = 'range_day_target_plot_view_mode';

/// Tolerant parser for the persisted [TargetPlotViewMode] string.
/// Returns `targetFocused` for any unknown / null input so a corrupt
/// prefs entry can't brick the screen.
TargetPlotViewMode _targetPlotViewModeFromString(String? raw) {
  switch (raw) {
    case 'realistic':
      return TargetPlotViewMode.realistic;
    case 'targetFocused':
    default:
      return TargetPlotViewMode.targetFocused;
  }
}

class RangeDayDetailScreen extends StatefulWidget {
  const RangeDayDetailScreen({super.key, this.sessionId});

  /// Existing session id to edit, or null to start a new one.
  final int? sessionId;

  @override
  State<RangeDayDetailScreen> createState() => _RangeDayDetailScreenState();
}

class _RangeDayDetailScreenState extends State<RangeDayDetailScreen> {
  // ─────────────────────── Persistence state ───────────────────────
  /// The persisted row, once a session exists in SQLite. Null until the
  /// user taps "Save Session" (or auto-save fires on a fresh session).
  RangeDaySessionRow? _session;

  /// Stream of shots tied to the saved session — null until the session
  /// has been saved. We don't render the stream until then because the
  /// in-memory shots list is the single source of truth for the
  /// recompute path before a save.
  Stream<List<ShotImpactRow>>? _shotsStream;

  Timer? _saveDebounce;
  Timer? _solveDebounce;

  // ─────────────────────── Setup state ───────────────────────
  TargetRow? _selectedTarget;
  String _targetCategoryFilter = 'all';
  Future<List<TargetRow>>? _targetsFuture;

  /// Live set of favorited target ids. Drives the favorite-first sort
  /// in the target dropdown plus the inline star toggle next to the
  /// selected target preview. Reference-data favorites live in the
  /// `UserFavorites` join table (see [FavoritesRepository]) rather
  /// than on `TargetRow` itself, which is why this screen reads them
  /// from a separate stream instead of from the row directly.
  Stream<Set<int>>? _targetFavoriteIdsStream;

  // ─────────────────────── Target racks (in-memory only) ───────────────────────
  //
  // Picking a rack is mutually-exclusive with picking a single target —
  // the small "[Single | Rack]" segmented toggle above the picker
  // selects which kind is being chosen. When a rack is active,
  // [_selectedTarget] is forced to null and the active geometry comes
  // from `_selectedRackChildren[_selectedRackChildPosition]` (a
  // [TargetRackChildRow]). That child's width / height / shape /
  // colorHex feeds every downstream consumer through the
  // `_activeTargetWidthIn` / `_activeTargetHeightIn` /
  // `_activeTargetSpec` helpers below.
  //
  // Rack mode persists across app restarts via the schema v23
  // [RangeDaySessions.rackId] / [rackChildPosition] columns.
  // `_buildSessionCompanion` writes `rackId` + `rackChildPosition`
  // when [_hasActiveRack] is true (forcing `targetId = null` so the
  // two surfaces don't both light up); `_hydrateFromSessionInner`
  // resolves the saved rack via `TargetRepository.rackById` /
  // `childrenOf` and restores [_selectedRack] /
  // [_selectedRackChildren] / [_selectedRackChildPosition] before
  // the first solve runs.
  TargetRackRow? _selectedRack;
  List<TargetRackChildRow> _selectedRackChildren = const [];
  int _selectedRackChildPosition = 0;
  Future<List<TargetRackRow>>? _racksFuture;
  String? _rackChildrenError;

  /// Two-segment toggle picking which kind of target the user is
  /// configuring. [_TargetPickerMode.single] keeps the existing single-
  /// target dropdown UX (default). [_TargetPickerMode.rack] swaps in
  /// the rack dropdown + active-child chips. Hydration on a saved
  /// session lands in [_TargetPickerMode.rack] when the persisted
  /// `RangeDaySessions.rackId` is non-null, otherwise in
  /// [_TargetPickerMode.single].
  _TargetPickerMode _targetPickerMode = _TargetPickerMode.single;

  /// User-selected color hex override for the active target's tint.
  /// Null means "use the target row's natural `colorHex`". Set by the
  /// 5-swatch picker in `_targetColorSwatchRow`. Plumbed into
  /// [TargetPlot] via the `colorHexOverride` constructor arg so the
  /// painter substitutes the override when filling the target shape.
  /// Per-session-only state (not persisted to a column today — would
  /// need a `RangeDaySessions.targetColorHexOverride` column for
  /// cross-restart persistence).
  String? _selectedTargetColorHex;

  BallisticProfileRow? _selectedProfile;
  Stream<List<BallisticProfileRow>>? _profilesStream;

  UserLoadRow? _selectedLoad;
  // Live stream rather than a one-shot future so toggling a load's
  // favorite flag (or saving a new recipe in another tab) re-renders
  // the dropdown without an explicit refresh. Same pattern as
  // `_profilesStream`. Re-assigned on a soft retry after a stream
  // error (`onRetry` in the FutureBuilder→StreamBuilder transition).
  Stream<List<UserLoadRow>>? _loadsStream;

  /// Non-persistent label for a [CommonLoad] the user picked from the
  /// empty-state catalog. Mirrored into the load picker as a "Using
  /// `<name>` defaults" banner so the user knows the BC / MV came from a
  /// canned factory-load row rather than a saved recipe of their own.
  /// Cleared whenever they pick a real recipe or tap "Clear defaults".
  /// Lives in memory only — no DB column, since selecting a common
  /// load deliberately doesn't create a recipe row.
  String? _appliedCommonLoadName;

  UserFirearmRow? _selectedFirearm;
  // Live stream — same rationale as `_loadsStream`. The dropdown
  // re-sorts immediately when the user toggles a firearm's favorite
  // flag, and a freshly added firearm (e.g. from the parallel
  // FirearmFormScreen path) appears without a manual refresh.
  Stream<List<UserFirearmRow>>? _firearmsStream;

  // ─────────────────────── Distance / range ───────────────────────
  final _distanceCtrl = TextEditingController(text: '500');

  // ─────────────────────── Shot azimuth ───────────────────────
  /// Compass direction the rifle is pointing in degrees. 0 = N, 90 = E,
  /// 180 = S, 270 = W. Fed to the ballistics solver as the
  /// [Environment.shotAzimuthDegrees] for the Coriolis correction at
  /// long range. Defaults to 0; users can either type a value or tap
  /// "Use as shot azimuth" on the live magnetometer readout to copy
  /// the current heading in.
  final _shotAzimuthCtrl = TextEditingController(text: '0');

  // ─────────────────────── Incline / decline (v16) ───────────────────────
  /// Slope of fire in degrees. Positive = uphill, negative = downhill.
  /// Fed to the ballistics solver via the improved rifleman's rule. The
  /// "Capture from sensor" button reads the InclinometerService's
  /// current pitch and pushes it here.
  final _inclineAngleCtrl = TextEditingController(text: '0');

  /// Whether to apply the live cant-correction term to the displayed
  /// firing solution. Pro-gated. When true and the [CantService]
  /// reports a non-zero cant, the solver's drop / wind values are
  /// rotated by `cant_rad` so the sight picture the shooter has at
  /// the target matches the displayed correction.
  bool _applyCantCorrection = false;

  // ─────────────────────── Projectile / shot inputs ───────────────────────
  /// All of these are seeded by the active profile / load and can be
  /// edited inline. Stored as the canonical numeric values; the form
  /// renders them via formatted text controllers.
  final _bulletDiameterCtrl = TextEditingController(text: '0.264');
  final _bulletWeightCtrl = TextEditingController(text: '140');
  final _bulletLengthCtrl = TextEditingController(text: '1.355');
  final _bcCtrl = TextEditingController(text: '0.298');
  DragModel _dragModel = DragModel.g7;
  final _muzzleVelCtrl = TextEditingController(text: '2750');
  final _zeroRangeCtrl = TextEditingController(text: '100');
  final _sightHeightCtrl = TextEditingController(text: '1.5');
  final _twistCtrl = TextEditingController(text: '8');

  // ─────────────────────── Environment ───────────────────────
  final _tempCtrl = TextEditingController(text: '59');
  final _pressureCtrl = TextEditingController(text: '29.92');
  final _humidityCtrl = TextEditingController(text: '50');
  final _elevationCtrl = TextEditingController(text: '0');
  final _windSpeedCtrl = TextEditingController(text: '8');
  final _windDirCtrl = TextEditingController(text: '270');
  bool _weatherFetching = false;
  DateTime? _weatherFetchedAt;

  /// True when the user opted to drive Environment from a connected
  /// Kestrel rather than open-meteo / manual entry. See
  /// `lib/screens/ballistics/ballistics_screen.dart` for the same
  /// pattern; the two screens share the [KestrelService] singleton so
  /// connecting in either place enables this affordance everywhere.
  bool _useKestrel = false;
  StreamSubscription<KestrelReading>? _kestrelSub;

  /// Optional FK to the atmosphere preset that pre-filled the four core
  /// environment fields. Mirrored onto [RangeDaySessions.atmospherePresetId]
  /// at save time so reopening the session restores the picker selection.
  /// Null when the user is in "Custom" (free-edited) mode.
  int? _atmospherePresetId;

  // ─────────────────────── Moving target (Pro) ───────────────────────
  final _moverSpeedCtrl = TextEditingController(text: '3');
  /// 'rtl' (right-to-left), 'ltr' (left-to-right). Used to flip lead sign.
  String _moverDirection = 'rtl';

  // ─────────────────────── Section collapse ───────────────────────
  //
  // All collapsible sections start COLLAPSED. The screen has a lot of
  // surface area (target, distance, profile, load, firearm, reticle,
  // shot azimuth, incline, sensors, environment, capability expander,
  // Litz analysis, moving target, save) and auto-expanding two cards
  // on every entry pushed the actual results (DOPE, target plot, hit
  // probability) below the fold. The user explicitly asked for
  // collapsed-by-default behavior — they'll tap a section header
  // when they need it, and `_hydrateFromSession` keeps the post-pick
  // collapse-everything behavior so existing sessions still open
  // straight to the solution view.
  bool _setupExpanded = false;
  bool _environmentExpanded = false;
  bool _movingTargetExpanded = false;

  /// "Sensors" panel inside the Setup card. Collapsed by default so
  /// beginners aren't presented with cant + heading readouts they
  /// don't yet care about. Power users tap once and the panel stays
  /// open for the session.
  bool _sensorsExpanded = false;

  /// 2 Hz "live updates" pulse that drives a tiny rebuild of the
  /// Sensors panel — gives the chip its "throb" feeling without
  /// burning frames on every accelerometer sample.
  bool _sensorsLive = false;
  Timer? _sensorsPulse;

  // ─────────────────────── Solution ───────────────────────
  /// Solution at the user's distance. Null until the first solve runs.
  TrajectorySample? _solution;
  /// DOPE table at canonical 100yd steps from 100..max.
  List<TrajectorySample> _dopeRows = const [];
  /// Last solver error message, surfaced inline under the Solution card.
  String? _solveError;

  /// Snapshot of the solver inputs that produced [_solution] — used
  /// by the wind-bracket card so it can re-solve at low / mid / high
  /// wind without re-parsing the controllers.
  Projectile? _lastSolvedProjectile;
  Environment? _lastSolvedEnvironment;
  ShotInputs? _lastSolvedShot;
  double? _lastSolvedDistanceYd;
  double? _lastSolvedWindMph;

  /// Notes captured for the session.
  final _notesCtrl = TextEditingController();

  /// In-memory shots list — the single source of truth before a session
  /// is saved. After save, it mirrors the stream. We always keep this
  /// in sync so recompute / group stats work with no DB round-trip.
  List<ShotImpactRow> _shots = const [];

  // ─────────────────────── Aim point + reticle (v11) ───────────────────────
  /// Active aim point in normalized target coords (-1..1). null means
  /// the user hasn't placed one yet (treated as dead center for the
  /// hit-probability calc).
  double? _aimPointX;
  double? _aimPointY;

  /// What a tap on the target plot means right now — placing the aim
  /// point or recording an actual impact. Defaults to aim mode so the
  /// user can set up before the first shot.
  TargetPlotTapMode _tapMode = TargetPlotTapMode.aimPoint;

  /// Visual presentation of the target plot — `targetFocused` (the
  /// target fills the box, default for accurate dot placement) or
  /// `realistic` (target sits inside a wider frame, breathing room for
  /// the reticle overlay). Defaults to `targetFocused` so existing
  /// users who never touch the toggle keep their current behaviour.
  /// Persisted under [_kTargetPlotViewModePrefKey] in SharedPreferences;
  /// hydration is fire-and-forget during [initState].
  TargetPlotViewMode _targetPlotViewMode = TargetPlotViewMode.targetFocused;

  /// Whole-screen Quick vs Full visibility mode. Quick collapses the
  /// scroll surface to Setup + Firing Solution (the bare minimum at
  /// the firing line); Full reveals every advanced card (environment
  /// editor, group stats, target plot, hit probability, DOPE, moving
  /// target, wind bracket, notes). Persisted under
  /// [kRangeDayModePrefKey] in SharedPreferences; the screen renders
  /// the default ([RangeDayMode.quick] — the calmer surface) before
  /// the read settles. See [lib/screens/range_day/range_day_mode.dart].
  RangeDayMode _mode = RangeDayMode.quick;

  /// User's known group capability at 100yd, in MOA. Drives dispersion.
  double _assumedGroupMoa = 1.0;
  double _windUncertaintyMph = 2.0;
  double _rangeUncertaintyYd = 5.0;

  /// Per-session correction-unit preference: 'mil' | 'moa' | 'inches'.
  /// Initialised lazily from the global UnitService once we have a
  /// BuildContext.
  String _correctionUnit = 'mil';

  /// Currently picked reticle for the on-target overlay. Null = none.
  ReticleDefinition? _selectedReticle;
  ReticleRow? _selectedReticleRow;

  /// Whether the "shooter capability" expansion in Setup is open.
  bool _capabilityExpanded = false;

  // Stable controllers for the three Shooter Capability number fields.
  // WHY: the previous implementation allocated a new TextEditingController
  // inside `_capabilityNumberField()` on every `build()`, which (a) leaked
  // controllers on every rebuild and (b) discarded any text the user had
  // typed mid-debounce when an unrelated `setState` reflowed the screen.
  // Hoisted here, seeded in `initState`, kept in sync via `_syncCapabilityCtrls`,
  // disposed in `dispose`. Each value is also re-seeded after `setState`
  // updates it (see callers below) so external mutations (e.g. session
  // hydration) update the displayed text.
  late final TextEditingController _capabilityGroupMoaCtrl;
  late final TextEditingController _capabilityWindUncertaintyCtrl;
  late final TextEditingController _capabilityRangeUncertaintyCtrl;

  // ─────────────────────── Captured sensor readings (v13) ───────────────────────
  //
  // The "Capture environment from sensors" button mirrors live cant /
  // azimuth / incline values directly into the corresponding text
  // controllers (`_shotAzimuthCtrl`, `_inclineAngleCtrl`) at capture
  // time. Earlier revisions also held them in dedicated `_captured*`
  // fields for a planned "Captured 12s ago" caption that never shipped.
  // Those fields were write-only — every read site relied on the live
  // controller text instead — so they were removed to keep state
  // honest. The persisted columns `RangeDaySessions.cantDegrees` /
  // `shotAzimuthDegrees` are written from the live controller value at
  // save time (see `_buildSessionCompanion`), not from a separate
  // capture snapshot. If a future revision wants the "captured Ns ago"
  // badge, reintroduce a timestamp alongside the actual read site.

  /// Latest hit-probability result. Recomputed lazily (300ms debounce).
  HitProbabilityResult? _hitProb;
  Timer? _hitProbDebounce;

  /// Scroll controllers for the phone + wide layouts.
  ///
  /// Reason for keeping these as state instead of letting Flutter
  /// allocate ephemeral controllers: when the user types into a
  /// TextField, the keyboard appears, iOS asks Flutter to scroll the
  /// focused field into view, and the scroll position changes. A
  /// transient controller can lose state across `setState` rebuilds
  /// that follow `_scheduleSolve()` / `_scheduleAutoSave()` — the
  /// observed symptom was the page snapping to the very bottom when
  /// the user scrolled past the ballistic-profile section. Pinning a
  /// controller per layout (and disposing in [dispose]) gives a
  /// stable scroll-extent computation, plus we explicitly set
  /// `keyboardDismissBehavior: onDrag` so the keyboard doesn't
  /// fight the flick.
  final ScrollController _phoneScrollCtrl = ScrollController();
  final ScrollController _wideLeftScrollCtrl = ScrollController();
  final ScrollController _wideRightScrollCtrl = ScrollController();

  @override
  void initState() {
    super.initState();
    // Seed the hoisted Shooter Capability controllers from the current
    // state values so the field text matches before the first build runs.
    _capabilityGroupMoaCtrl =
        TextEditingController(text: _trimZeros(_assumedGroupMoa));
    _capabilityWindUncertaintyCtrl =
        TextEditingController(text: _trimZeros(_windUncertaintyMph));
    _capabilityRangeUncertaintyCtrl =
        TextEditingController(text: _trimZeros(_rangeUncertaintyYd));
    _targetsFuture = context.read<TargetRepository>().allTargets();
    // Live stream of favorited target ids — drives the favorite-first
    // sort in the dropdown and the star toggle next to the selected
    // target preview. Reference-data favorites (cartridge, reticle,
    // target) live in `UserFavorites`, not on the source row, so we
    // need a parallel stream the picker can react to.
    _targetFavoriteIdsStream =
        context.read<FavoritesRepository>().watchFavoriteIds(kFavoriteTarget);
    // Kick off the rack catalog read up-front so the rack tab of the
    // target picker doesn't show a spinner the first time the user
    // toggles into it. The picker still surfaces a soft error if the
    // future rejects — see `_rackTargetPickerBody`.
    _racksFuture = context.read<TargetRepository>().allRacks();
    _profilesStream = context.read<BallisticProfileRepository>().watchAll();
    _loadsStream = context.read<RecipeRepository>().watchAll();
    _firearmsStream = context.read<FirearmRepository>().watchAll();
    // Default the per-session correction unit to the global angle pref.
    final units = context.read<UnitService>();
    _correctionUnit =
        units.unitFor(UnitCategory.angle).toLowerCase() == 'mrad'
            ? 'mil'
            : (units.unitFor(UnitCategory.angle).toLowerCase() == 'moa'
                ? 'moa'
                : 'mil');
    // Start the live cant + magnetometer + inclinometer sensors so the
    // Setup section shows live data the moment it opens. start() is a
    // graceful no-op on platforms (macOS / web) without these sensors.
    // ignore: discarded_futures
    context.read<CantService>().start();
    // ignore: discarded_futures
    context.read<InclinometerService>().start();
    // ignore: discarded_futures
    context.read<MagnetometerService>().start();
    if (widget.sessionId != null) {
      _hydrateFromSession(widget.sessionId!);
    } else {
      // Initial solve so the first card renders something useful.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _scheduleSolve();
        _scheduleHitProb();
      });
      // Fresh session: try the user's most-recent favorited reticle /
      // target first, fall back to the LoadOut default Mil Tree
      // archetype / TargetSpec.defaultPaper when the user has no
      // favorites yet. Both lookups are fire-and-forget and soft-
      // fail — a missing favorite can never block the screen.
      // ignore: discarded_futures
      _seedDefaultsFromFavoritesIfPresent();
      // ignore: discarded_futures
      _seedDefaultReticleIfMissing();
    }
    // Pull the persisted Target Plot view mode (Realistic vs
    // Target-Focused). Default is `targetFocused`; the read swaps in
    // `realistic` if the user previously chose it. Fire-and-forget by
    // design — the screen renders the default before the read
    // completes and switches in place once it lands.
    // ignore: discarded_futures
    _hydrateTargetPlotViewMode();
    // Same pattern for the whole-screen Quick vs Full mode.
    // ignore: discarded_futures
    _hydrateRangeDayMode();
  }

  /// On a fresh session, pre-populate the reticle and target with the
  /// user's most-recently-favorited entry of each (when one exists).
  /// Called fire-and-forget from `initState` only when no `sessionId`
  /// was passed in, so existing sessions still hydrate from their
  /// persisted ids untouched.
  ///
  /// Soft-fail policy: any failure (favorite row points at a deleted
  /// reference catalog row, repository throws, the FavoritesRepository
  /// is mid-Cloud-Sync transaction) leaves the screen in its existing
  /// LoadOut Default state — the next call to
  /// [_seedDefaultReticleIfMissing] still runs and falls through to the
  /// `loadout_default_mil_tree` archetype, and the target slot stays
  /// at `null` (the empty-state path uses `TargetSpec.defaultPaper`).
  ///
  /// Both lookups are guarded against the user picking something
  /// before this future settles — the assignment is skipped if the
  /// `_selectedReticleRow` / `_selectedTarget` slot is already set
  /// when the future resolves.
  Future<void> _seedDefaultsFromFavoritesIfPresent() async {
    try {
      final favoritesRepo = context.read<FavoritesRepository>();
      final reticleRepo = context.read<ReticleRepository>();
      final targetRepo = context.read<TargetRepository>();

      final favoriteReticleId =
          await favoritesRepo.mostRecentFavoriteId(kFavoriteReticle);
      if (mounted &&
          favoriteReticleId != null &&
          _selectedReticleRow == null) {
        try {
          final row = await reticleRepo.byId(favoriteReticleId);
          if (mounted && row != null && _selectedReticleRow == null) {
            setState(() {
              _selectedReticleRow = row;
              _selectedReticle = reticleRepo.definitionFromRow(row);
            });
          }
        } catch (e) {
          debugPrint(
              '[range_day] _seedDefaultsFromFavorites reticle lookup failed: $e');
        }
      }

      final favoriteTargetId =
          await favoritesRepo.mostRecentFavoriteId(kFavoriteTarget);
      if (mounted && favoriteTargetId != null && _selectedTarget == null) {
        try {
          final row = await targetRepo.getById(favoriteTargetId);
          if (mounted && row != null && _selectedTarget == null) {
            setState(() => _selectedTarget = row);
            _scheduleSolve();
          }
        } catch (e) {
          debugPrint(
              '[range_day] _seedDefaultsFromFavorites target lookup failed: $e');
        }
      }
    } catch (e) {
      debugPrint(
          '[range_day] _seedDefaultsFromFavoritesIfPresent failed: $e');
    }
  }

  /// Look up the canonical LoadOut Default Mil Tree archetype and
  /// stash it as `_selectedReticle`. Called from `initState` for
  /// fresh sessions and from `_hydrateFromSessionInner` when a saved
  /// session has no reticle id.
  ///
  /// TODO(loadout-default): catalog must include
  /// `loadout_default_mil_tree`. Until the parallel catalog overhaul
  /// publishes the archetype, this method silently no-ops and the
  /// picker stays unset — the rest of the screen is fully usable.
  Future<void> _seedDefaultReticleIfMissing() async {
    try {
      final repo = context.read<ReticleRepository>();
      final row = await repo.byNaturalKey('loadout_default_mil_tree');
      if (!mounted || row == null) return;
      // Only populate if the user hasn't already picked one between
      // initState firing and this future settling.
      if (_selectedReticleRow != null) return;
      setState(() {
        _selectedReticleRow = row;
        _selectedReticle = repo.definitionFromRow(row);
      });
    } catch (e) {
      debugPrint(
          '[range_day] _seedDefaultReticleIfMissing failed: $e');
    }
  }

  /// Read the persisted [TargetPlotViewMode] from SharedPreferences and
  /// apply it. Wrapped in try/catch so a corrupt prefs entry can't
  /// brick the screen — [_targetPlotViewModeFromString] tolerates
  /// unknown values by returning [TargetPlotViewMode.targetFocused].
  Future<void> _hydrateTargetPlotViewMode() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_kTargetPlotViewModePrefKey);
      final next = _targetPlotViewModeFromString(raw);
      if (!mounted) return;
      if (next != _targetPlotViewMode) {
        setState(() => _targetPlotViewMode = next);
      }
    } catch (e) {
      debugPrint('[range_day] _hydrateTargetPlotViewMode failed: $e');
    }
  }

  /// Persist the user's chosen [TargetPlotViewMode]. Called from the
  /// Target Plot card's mini-toggle. Fire-and-forget — the local
  /// `_targetPlotViewMode` is updated synchronously via setState so
  /// the UI flips immediately even if the prefs write is slow.
  Future<void> _persistTargetPlotViewMode(TargetPlotViewMode mode) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_kTargetPlotViewModePrefKey, mode.name);
    } catch (e) {
      debugPrint('[range_day] _persistTargetPlotViewMode failed: $e');
    }
  }

  /// Read the persisted whole-screen [RangeDayMode] (Quick vs Full)
  /// from SharedPreferences and apply it. Mirror of
  /// [_hydrateTargetPlotViewMode] — soft-fails on a corrupt entry by
  /// keeping the default [RangeDayMode.quick]. The parser
  /// ([rangeDayModeFromString]) tolerates unknown / null inputs.
  Future<void> _hydrateRangeDayMode() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(kRangeDayModePrefKey);
      final next = rangeDayModeFromString(raw);
      if (!mounted) return;
      if (next != _mode) {
        setState(() => _mode = next);
      }
    } catch (e) {
      debugPrint('[range_day] _hydrateRangeDayMode failed: $e');
    }
  }

  /// Persist the user's chosen [RangeDayMode]. Called from the AppBar
  /// segmented toggle. Fire-and-forget — `_mode` is updated
  /// synchronously via setState so the screen reflows immediately
  /// even if the prefs write is slow.
  Future<void> _persistRangeDayMode(RangeDayMode mode) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(kRangeDayModePrefKey, mode.name);
    } catch (e) {
      debugPrint('[range_day] _persistRangeDayMode failed: $e');
    }
  }

  Future<void> _hydrateFromSession(int id) async {
    // Capture every repository up front so we don't reach into the
    // BuildContext after an `await`.
    //
    // We deliberately do NOT capture `ScaffoldMessenger.of(context)`
    // here. This method is called from `initState` (synchronously);
    // the inherited-widget lookup that ScaffoldMessenger.of performs
    // walks up the element tree, which trips an `assert` in debug
    // mode if the screen's build hasn't completed. The assertion
    // doesn't fire in release (assert is no-op there), but it dirties
    // every widget test by raising an uncaught zone error and forcing
    // `RangeDayErrorBoundary` to swap in the friendly fallback —
    // turning every Range Day Detail widget test into a workaround
    // for a debug-only diagnostic.
    //
    // Defer the messenger lookup to inside the catch block, after the
    // `mounted` check. By then the screen has rendered at least one
    // frame and ScaffoldMessenger.of is safe.
    final rangeDayRepo = context.read<RangeDayRepository>();
    final targetRepo = context.read<TargetRepository>();
    final profileRepo = context.read<BallisticProfileRepository>();
    final firearmRepo = context.read<FirearmRepository>();
    final recipeRepo = context.read<RecipeRepository>();
    final reticleRepo = context.read<ReticleRepository>();

    // Wrap the entire hydration in try/catch — a missing target/load/
    // profile row (e.g. user deleted it between sessions) or a closed
    // DB on app teardown must NOT take down the screen. The caller
    // simply sees an unhydrated session with a snackbar explaining.
    try {
      await _hydrateFromSessionInner(
        id: id,
        rangeDayRepo: rangeDayRepo,
        targetRepo: targetRepo,
        profileRepo: profileRepo,
        firearmRepo: firearmRepo,
        recipeRepo: recipeRepo,
        reticleRepo: reticleRepo,
      );
    } catch (e, stack) {
      debugPrint('[range_day] _hydrateFromSession failed: $e');
      debugPrintStack(stackTrace: stack, label: '_hydrateFromSession');
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Could not fully load this session. Some fields may be empty.',
          ),
        ),
      );
    }
  }

  Future<void> _hydrateFromSessionInner({
    required int id,
    required RangeDayRepository rangeDayRepo,
    required TargetRepository targetRepo,
    required BallisticProfileRepository profileRepo,
    required FirearmRepository firearmRepo,
    required RecipeRepository recipeRepo,
    required ReticleRepository reticleRepo,
  }) async {
    final s = await rangeDayRepo.getById(id);
    if (s == null || !mounted) return;
    setState(() {
      _session = s;
      _shotsStream = rangeDayRepo.streamShotsForSession(id);
      _distanceCtrl.text = s.distanceYd.toStringAsFixed(0);
      _notesCtrl.text = s.notes ?? '';
      if (s.temperatureF != null) {
        _tempCtrl.text = _trimZeros(s.temperatureF!);
      }
      if (s.pressureInHg != null) {
        _pressureCtrl.text = s.pressureInHg!.toStringAsFixed(2);
      }
      if (s.humidityPct != null) {
        _humidityCtrl.text = _trimZeros(s.humidityPct!);
      }
      if (s.elevationFt != null) {
        _elevationCtrl.text = _trimZeros(s.elevationFt!);
      }
      if (s.windSpeedMph != null) {
        _windSpeedCtrl.text = _trimZeros(s.windSpeedMph!);
      }
      if (s.windDirectionDeg != null) {
        _windDirCtrl.text = _trimZeros(s.windDirectionDeg!);
      }
      // v11 fields.
      _aimPointX = s.aimPointX;
      _aimPointY = s.aimPointY;
      _assumedGroupMoa = s.assumedGroupMoa ?? 1.0;
      _windUncertaintyMph = s.windUncertaintyMph ?? 2.0;
      _rangeUncertaintyYd = s.rangeUncertaintyYd ?? 5.0;
      // Re-seed the hoisted Shooter Capability controllers so the input
      // text reflects the hydrated values when an existing session opens.
      _capabilityGroupMoaCtrl.text = _trimZeros(_assumedGroupMoa);
      _capabilityWindUncertaintyCtrl.text = _trimZeros(_windUncertaintyMph);
      _capabilityRangeUncertaintyCtrl.text = _trimZeros(_rangeUncertaintyYd);
      _correctionUnit =
          (s.correctionUnit.isEmpty ? 'mil' : s.correctionUnit);
      // v13 — captured shot azimuth. If the previous save included a
      // captured shot azimuth, mirror it into the editable text field
      // so the field reflects the persisted value when the session is
      // re-opened. (Cant is read live from CantService when the cant-
      // correction toggle is on; the persisted column is informational
      // only — see the comment block above the captured-sensor section.)
      if (s.shotAzimuthDegrees != null) {
        _shotAzimuthCtrl.text =
            s.shotAzimuthDegrees!.toStringAsFixed(0);
      }
      // v15 ballistic precision — incline / decline angle.
      if (s.inclineAngleDeg != null) {
        _inclineAngleCtrl.text = s.inclineAngleDeg!.toStringAsFixed(1);
      }
      // v17 — atmosphere preset selection.
      _atmospherePresetId = s.atmospherePresetId;
      _setupExpanded = false;
      _environmentExpanded = false;
    });
    // Resolve the foreign keys now that we know we're editing.
    //
    // Rack and single-target modes are mutually exclusive on the
    // database side (auto-save writes one and forces the other null),
    // so we restore rack state first when `rackId` is non-null and
    // skip the single-target lookup entirely. When `rackId` is null,
    // fall through to the existing `targetId` path. Soft-fail on the
    // rack-children fetch — a stale id, a re-seeded catalog, or a
    // closed-DB during teardown all return [] rather than crashing
    // the screen, and the picker simply lands back in single-target
    // mode with an empty rack pick.
    if (s.rackId != null) {
      try {
        final rack = await targetRepo.rackById(s.rackId!);
        if (rack != null) {
          List<TargetRackChildRow> children = const [];
          try {
            children = await targetRepo.childrenOf(rack.id);
          } catch (e) {
            debugPrint(
              '[range_day] _hydrateFromSession childrenOf failed: $e',
            );
            children = const [];
          }
          if (mounted) {
            setState(() {
              _selectedRack = rack;
              _selectedRackChildren = children;
              // Clamp the persisted position into the valid range so
              // a stale value (e.g. seed re-shuffle that dropped the
              // tail child) doesn't index out of bounds.
              final saved = s.rackChildPosition ?? 0;
              _selectedRackChildPosition = children.isEmpty
                  ? 0
                  : saved.clamp(0, children.length - 1);
              _targetPickerMode = _TargetPickerMode.rack;
              // Mutual exclusion: when a rack is active, the legacy
              // single-target selection is forced empty so the UI
              // doesn't render two pickers in conflict.
              _selectedTarget = null;
            });
          }
        }
      } catch (e) {
        debugPrint('[range_day] _hydrateFromSession rackById failed: $e');
      }
    } else if (s.targetId != null) {
      final target = await targetRepo.getById(s.targetId!);
      if (mounted) setState(() => _selectedTarget = target);
    }
    if (s.ballisticProfileId != null) {
      final p = await profileRepo.getById(s.ballisticProfileId!);
      if (mounted && p != null) {
        _applyProfile(p);
      }
    }
    if (s.firearmId != null) {
      final f = await firearmRepo.getById(s.firearmId!);
      if (mounted && f != null) {
        setState(() => _selectedFirearm = f);
        _applyFirearmDefaults(f);
      }
    }
    if (s.recipeId != null) {
      final r = await recipeRepo.getById(s.recipeId!);
      if (mounted && r != null) {
        setState(() => _selectedLoad = r);
        _applyLoadDefaults(r);
      }
    }
    // v11 — hydrate reticle (if any). When the saved session has no
    // reticle picked, fall back to the LoadOut Default Mil Tree
    // archetype so the target plot still renders something useful
    // out of the box. Fire-and-forget; the helper soft-fails when
    // the catalog hasn't seeded the archetype yet.
    if (s.reticleId != null) {
      final reticleRow = await reticleRepo.byId(s.reticleId!);
      if (mounted && reticleRow != null) {
        setState(() {
          _selectedReticleRow = reticleRow;
          _selectedReticle = reticleRepo.definitionFromRow(reticleRow);
        });
      }
    } else {
      // ignore: discarded_futures
      _seedDefaultReticleIfMissing();
    }
    // Pull in existing shots so the in-memory list is never stale during
    // recompute.
    final initialShots = await rangeDayRepo.shotsForSession(id);
    if (mounted) {
      // If the session has shots but no aim point, default to recordShot
      // mode so the user doesn't accidentally move the (absent) aim
      // marker on the first tap. Otherwise stay in aimPoint mode so a
      // brand-new visit places the aim before recording shots.
      setState(() {
        _shots = initialShots;
        if (initialShots.isNotEmpty && _aimPointX == null) {
          _tapMode = TargetPlotTapMode.recordShot;
        }
      });
    }
    _scheduleSolve();
  }

  String _trimZeros(double v) {
    final s = v.toString();
    if (!s.contains('.')) return s;
    return s.replaceFirst(RegExp(r'\.?0+$'), '');
  }

  @override
  void dispose() {
    _saveDebounce?.cancel();
    _solveDebounce?.cancel();
    _hitProbDebounce?.cancel();
    _sensorsPulse?.cancel();
    _phoneScrollCtrl.dispose();
    _wideLeftScrollCtrl.dispose();
    _wideRightScrollCtrl.dispose();
    // ignore: discarded_futures
    _kestrelSub?.cancel();
    // Stop the device sensors when leaving the screen so the OS can
    // clock-gate the radio. All three services are app-singletons
    // (provided in lib/app.dart) so we stop rather than dispose.
    // ignore: discarded_futures
    context.read<CantService>().stop();
    // ignore: discarded_futures
    context.read<MagnetometerService>().stop();
    // ignore: discarded_futures
    context.read<InclinometerService>().stop();
    for (final c in [
      _distanceCtrl,
      _shotAzimuthCtrl,
      _inclineAngleCtrl,
      _bulletDiameterCtrl,
      _bulletWeightCtrl,
      _bulletLengthCtrl,
      _bcCtrl,
      _muzzleVelCtrl,
      _zeroRangeCtrl,
      _sightHeightCtrl,
      _twistCtrl,
      _tempCtrl,
      _pressureCtrl,
      _humidityCtrl,
      _elevationCtrl,
      _windSpeedCtrl,
      _windDirCtrl,
      _moverSpeedCtrl,
      _notesCtrl,
      // Hoisted Shooter Capability controllers — see field declarations.
      _capabilityGroupMoaCtrl,
      _capabilityWindUncertaintyCtrl,
      _capabilityRangeUncertaintyCtrl,
    ]) {
      c.dispose();
    }
    super.dispose();
  }

  // ─────────────────────── Profile / load / firearm application ───────────────────────

  void _applyProfile(BallisticProfileRow p) {
    setState(() {
      _selectedProfile = p;
      _bulletWeightCtrl.text = _trimZeros(p.bulletWeightGr);
      _bulletDiameterCtrl.text = p.bulletDiameterIn.toStringAsFixed(3);
      _bcCtrl.text = p.ballisticCoefficient.toStringAsFixed(3);
      _dragModel =
          p.dragModel.toLowerCase() == 'g1' ? DragModel.g1 : DragModel.g7;
      if (p.bulletLengthIn != null) {
        _bulletLengthCtrl.text = _trimZeros(p.bulletLengthIn!);
      }
      if (p.twistRate != null) _twistCtrl.text = p.twistRate!;
      _muzzleVelCtrl.text = p.muzzleVelocityFps.toStringAsFixed(0);
      _zeroRangeCtrl.text = p.zeroRangeYd.toString();
      _sightHeightCtrl.text = _trimZeros(p.sightHeightIn);
      if (p.temperatureF != null) {
        _tempCtrl.text = _trimZeros(p.temperatureF!);
      }
      if (p.pressureInHg != null) {
        _pressureCtrl.text = p.pressureInHg!.toStringAsFixed(2);
      }
      if (p.humidityPct != null) {
        _humidityCtrl.text = _trimZeros(p.humidityPct!);
      }
      if (p.elevationFt != null) {
        _elevationCtrl.text = _trimZeros(p.elevationFt!);
      }
      if (p.windSpeedMph != null) {
        _windSpeedCtrl.text = _trimZeros(p.windSpeedMph!);
      }
      if (p.windDirectionDeg != null) {
        _windDirCtrl.text = _trimZeros(p.windDirectionDeg!);
      }
    });
    _scheduleSolve();
  }

  void _applyLoadDefaults(UserLoadRow r) {
    setState(() {
      if (r.bulletWeightGr != null) {
        _bulletWeightCtrl.text = _trimZeros(r.bulletWeightGr!);
      }
      if (r.bulletLengthIn != null) {
        _bulletLengthCtrl.text = _trimZeros(r.bulletLengthIn!);
      }
    });
    // Also pick up any trued BC override the user previously saved for
    // this (load, firearm, drag model) triple.
    // ignore: discarded_futures
    _maybeApplyTruedBcOverride();
    _scheduleSolve();
  }

  void _applyFirearmDefaults(UserFirearmRow f) {
    setState(() {
      if (f.defaultMuzzleVelocityFps != null) {
        _muzzleVelCtrl.text = f.defaultMuzzleVelocityFps!.toStringAsFixed(0);
      }
      if (f.defaultZeroRangeYd != null) {
        _zeroRangeCtrl.text = f.defaultZeroRangeYd!.toString();
      }
      if (f.sightHeightIn != null) {
        _sightHeightCtrl.text = _trimZeros(f.sightHeightIn!);
      }
      final twist = _parseTwist(f.twistRate);
      if (twist != null) _twistCtrl.text = twist.toString();
    });
    // Sight scale (DPC calibration) is consumed by the solver via
    // [ShotInputs] in `_solve()`, so a re-solve picks it up. The trued
    // BC override needs an active load too — try to pull it once both
    // sides of the (load × firearm) key are known.
    // ignore: discarded_futures
    _maybeApplyTruedBcOverride();
    _scheduleSolve();
  }

  /// If the user has previously trued the BC for the active
  /// (load × firearm × drag model) triple, replace the BC field with
  /// the trued value and surface a brief snackbar so the user knows
  /// the override is active.
  Future<void> _maybeApplyTruedBcOverride() async {
    final load = _selectedLoad;
    final firearm = _selectedFirearm;
    if (load == null || firearm == null) return;
    final db = context.read<AppDatabase>();
    final dragModelStr = _dragModel.short.toLowerCase();
    // Wrapped — DB lookup runs every load/firearm change, so a transient
    // closed-DB or schema problem must NOT take down the screen. We
    // silently skip applying the override on failure (debugPrint only).
    try {
      final row = await (db.select(db.truedBcOverrides)
            ..where((t) => t.loadId.equals(load.id))
            ..where((t) => t.firearmId.equals(firearm.id))
            ..where((t) => t.dragModel.equals(dragModelStr))
            ..limit(1))
          .getSingleOrNull();
      if (row == null || !mounted) return;
      setState(() {
        _bcCtrl.text = row.truedBc.toStringAsFixed(3);
      });
      _scheduleSolve();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Applied trued BC ${row.truedBc.toStringAsFixed(3)} '
            '(was ${row.nominalBc.toStringAsFixed(3)})',
          ),
          duration: const Duration(seconds: 3),
        ),
      );
    } catch (e, stack) {
      debugPrint('[range_day] _maybeApplyTruedBcOverride failed: $e');
      debugPrintStack(stackTrace: stack, label: '_maybeApplyTruedBcOverride');
    }
  }

  int? _parseTwist(String? raw) {
    if (raw == null || raw.trim().isEmpty) return null;
    final matches = RegExp(r'(\d+(?:\.\d+)?)').allMatches(raw);
    if (matches.isEmpty) return null;
    final last = matches.last.group(1)!;
    final asD = double.tryParse(last);
    return asD?.round();
  }

  // ─────────────────────── Solve ───────────────────────

  /// Debounce the solver so changing wind etc. doesn't run it on every
  /// keystroke. Range-day inputs are touch-and-go — 500ms feels right.
  void _scheduleSolve() {
    _solveDebounce?.cancel();
    _solveDebounce = Timer(const Duration(milliseconds: 500), _solve);
    _scheduleHitProb();
  }

  /// Recompute hit probability lazily. The MC integration is fast but
  /// we still debounce to keep tap-to-aim feeling snappy.
  void _scheduleHitProb() {
    _hitProbDebounce?.cancel();
    _hitProbDebounce =
        Timer(const Duration(milliseconds: 300), _computeHitProb);
  }

  void _computeHitProb() {
    if (!mounted) return;
    final svc = context.read<HitProbabilityService>();
    // Read geometry through the active-target helpers so a rack-active
    // selection feeds the rack child's width / height / shape into the
    // solver instead of (mistakenly) using the rack envelope or
    // skipping the calc entirely.
    final widthIn = _activeTargetWidthIn;
    final heightIn = _activeTargetHeightIn;
    final shapeStr = _activeTargetShape;
    if (widthIn == null || heightIn == null || shapeStr == null) {
      setState(() => _hitProb = null);
      return;
    }
    final shape = parseTargetShape(shapeStr);
    final dist = double.tryParse(_distanceCtrl.text.trim()) ?? 100;
    // Aim offset converts from normalized [-1, 1] to inches at the
    // target by multiplying by the target half-extent. Treat null aim
    // as dead center.
    final aimX = (_aimPointX ?? 0) * widthIn / 2;
    final aimY = (_aimPointY ?? 0) * heightIn / 2;
    final mvSd = _resolveMvSd();
    final mv = double.tryParse(_muzzleVelCtrl.text.trim()) ?? 2750;
    final bc = double.tryParse(_bcCtrl.text.trim()) ?? 0.298;
    final bulletWeight =
        double.tryParse(_bulletWeightCtrl.text.trim()) ?? 140;
    final bulletDiameter =
        double.tryParse(_bulletDiameterCtrl.text.trim()) ?? 0.264;
    final temp = double.tryParse(_tempCtrl.text.trim()) ?? 59;
    final pressure = double.tryParse(_pressureCtrl.text.trim()) ?? 29.92;
    final humidity = double.tryParse(_humidityCtrl.text.trim()) ?? 50;
    final elevation = double.tryParse(_elevationCtrl.text.trim()) ?? 0;
    final windSpeed = double.tryParse(_windSpeedCtrl.text.trim()) ?? 0;
    final windDir = double.tryParse(_windDirCtrl.text.trim()) ?? 270;
    final sightHeight =
        double.tryParse(_sightHeightCtrl.text.trim()) ?? 1.5;
    final zeroRange = double.tryParse(_zeroRangeCtrl.text.trim()) ?? 100;

    try {
      final result = svc.compute(
        aimOffsetXIn: aimX,
        aimOffsetYIn: aimY,
        targetWidthIn: widthIn,
        targetHeightIn: heightIn,
        shape: shape,
        distanceYd: dist,
        assumedGroupMoa: _assumedGroupMoa,
        windUncertaintyMph: _windUncertaintyMph,
        rangeUncertaintyYd: _rangeUncertaintyYd,
        mvSdFps: mvSd,
        bcG7: bc,
        muzzleVelocityFps: mv,
        tempF: temp,
        pressureInHg: pressure,
        humidityPct: humidity,
        elevationFt: elevation,
        windSpeedMph: windSpeed,
        windDirDeg: windDir,
        sightHeightIn: sightHeight,
        zeroRangeYd: zeroRange,
        bulletWeightGr: bulletWeight,
        bulletDiameterIn: bulletDiameter,
      );
      if (!mounted) return;
      setState(() => _hitProb = result);
    } catch (_) {
      if (!mounted) return;
      setState(() => _hitProb = null);
    }
  }

  /// Resolve the muzzle-velocity SD to use for hit probability:
  /// the linked load's chronograph SD (via TestSessions) when known,
  /// else a 12 fps default — the common "decent handload" baseline.
  double _resolveMvSd() {
    // We don't go fetch test session data synchronously here; the user
    // is encouraged to reflect known SD by editing the wind/range
    // uncertainty fields if their data is unusual. 12 fps is a
    // reasonable mid-tier baseline; ELR shooters tune the inputs.
    return 12.0;
  }

  void _solve() {
    if (!mounted) return;
    setState(() => _solveError = null);
    try {
      final bulletDiameter =
          _parsePos(_bulletDiameterCtrl.text, 'Bullet diameter');
      final bulletWeight = _parsePos(_bulletWeightCtrl.text, 'Bullet weight');
      final bc = _parsePos(_bcCtrl.text, 'BC');
      final length = _parseOpt(_bulletLengthCtrl.text);
      final twist = _parseOpt(_twistCtrl.text);
      final muzzleVel = _parsePos(_muzzleVelCtrl.text, 'Muzzle velocity');
      final sightHeight = _parsePos(_sightHeightCtrl.text, 'Sight height');
      final zeroRange = _parsePos(_zeroRangeCtrl.text, 'Zero range');
      final distance = _parsePos(_distanceCtrl.text, 'Distance');

      final temp = _parseAny(_tempCtrl.text, 'Temperature');
      final pressure = _parsePos(_pressureCtrl.text, 'Pressure');
      final humidity = _parseAny(_humidityCtrl.text, 'Humidity');
      final elevation = _parseAny(_elevationCtrl.text, 'Elevation');
      final windSpeed = double.tryParse(_windSpeedCtrl.text.trim()) ?? 0;
      final windDir = double.tryParse(_windDirCtrl.text.trim()) ?? 0;
      final shotAzimuth =
          double.tryParse(_shotAzimuthCtrl.text.trim()) ?? 0;

      final projectile = Projectile(
        diameterIn: bulletDiameter,
        weightGr: bulletWeight,
        bc: bc,
        dragModel: _dragModel,
        lengthIn: length,
        twistInches: twist,
      );
      final atmosphere = Atmosphere.station(
        tempF: temp,
        stationPressureInHg: pressure,
        humidityPct: humidity,
        altitudeFt: elevation,
      );
      final environment = Environment.fromImperial(
        atmosphere: atmosphere,
        windSpeedMph: windSpeed,
        windFromDegrees: windDir,
        shotAzimuthDegrees: shotAzimuth,
        latitudeDegrees: 40,
        targetElevationFt: 0,
      );
      final shot = ShotInputs(
        muzzleVelocityFps: muzzleVel,
        sightHeightIn: sightHeight,
        zeroRangeYards: zeroRange,
      );

      // DOPE ladder: 100..max in 100yd steps, with the user's distance
      // included if it's not on a 100yd boundary.
      final ladder = <double>{
        for (var r = 100.0; r <= distance + 0.001; r += 100) r,
        distance,
      }.toList()
        ..sort();
      var samples = solveTrajectory(
        projectile: projectile,
        environment: environment,
        shot: shot,
        sampleRangesYards: ladder,
      );

      // Cant correction (Pro). The point-mass solver assumes the rifle
      // is held level; if the shooter is canted, the sight picture is
      // rotated against the impact. With cant angle θ:
      //
      //   drop'        = drop · cos(θ) + windDrift · sin(θ)
      //   windDrift'   = windDrift · cos(θ) − drop · sin(θ)
      //
      // The spec's small-angle decomposition is the additive form of
      // the same identity:
      //
      //   cant_correction_drop = sin(θ) · windDrift
      //   cant_correction_wind = −sin(θ) · drop
      //
      // We use the full rotation here for correctness at large cant
      // angles. Only applied when the toggle is on AND the user has
      // Pro AND the cant service has produced a sample.
      final cant = context.read<CantService>().cantDegrees;
      final isPro = context.read<EntitlementNotifier>().isPro;
      if (_applyCantCorrection &&
          isPro &&
          cant != null &&
          cant.abs() > 0.05) {
        final cantRad = cant * math.pi / 180.0;
        final cosC = math.cos(cantRad);
        final sinC = math.sin(cantRad);
        samples = [
          for (final s in samples)
            TrajectorySample(
              rangeYards: s.rangeYards,
              timeSec: s.timeSec,
              dropInches: s.dropInches * cosC + s.windDriftInches * sinC,
              windDriftInches:
                  s.windDriftInches * cosC - s.dropInches * sinC,
              spinDriftInches: s.spinDriftInches,
              velocityFps: s.velocityFps,
              energyFtLb: s.energyFtLb,
              machNumber: s.machNumber,
            ),
        ];
      }

      // The active solution is the sample at the user's chosen distance.
      TrajectorySample? primary;
      for (final s in samples) {
        if ((s.rangeYards - distance).abs() < 0.01) {
          primary = s;
          break;
        }
      }
      setState(() {
        _solution = primary;
        _dopeRows = samples;
        _lastSolvedProjectile = projectile;
        _lastSolvedEnvironment = environment;
        _lastSolvedShot = shot;
        _lastSolvedDistanceYd = distance;
        _lastSolvedWindMph = windSpeed;
      });
    } on FormatException catch (e) {
      setState(() {
        _solveError = e.message;
        _solution = null;
        _dopeRows = const [];
        _lastSolvedProjectile = null;
        _lastSolvedEnvironment = null;
        _lastSolvedShot = null;
        _lastSolvedDistanceYd = null;
        _lastSolvedWindMph = null;
      });
    } catch (e) {
      setState(() {
        _solveError = 'Could not solve: $e';
        _solution = null;
        _dopeRows = const [];
        _lastSolvedProjectile = null;
        _lastSolvedEnvironment = null;
        _lastSolvedShot = null;
        _lastSolvedDistanceYd = null;
        _lastSolvedWindMph = null;
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

  // ─────────────────────── Save ───────────────────────

  RangeDaySessionsCompanion _buildSessionCompanion() {
    final distance =
        double.tryParse(_distanceCtrl.text.trim()) ?? 100;
    // Use the active-target display name so the auto-generated session
    // title reflects either the single target OR the active rack
    // child. Falls back to the generic "Range day · …" when nothing
    // is picked yet.
    final activeName = _activeTargetDisplayName;
    final defaultName = activeName == null
        ? 'Range day · ${distance.toStringAsFixed(0)} yd'
        : '$activeName · ${distance.toStringAsFixed(0)} yd';
    // Rack mode persistence (schema v23). The rack columns and the
    // single-target column are mutually exclusive: when a rack is
    // active we write `targetId = null` so the next load doesn't
    // accidentally fall back to a stale single-target FK; when no
    // rack is active we write both rack columns null so the row
    // continues rendering through the existing `targetId` path.
    final hasActiveRack = _hasActiveRack;
    return RangeDaySessionsCompanion(
      name: drift.Value(_session?.name ?? defaultName),
      date: drift.Value(_session?.date ?? DateTime.now()),
      notes: drift.Value(_notesCtrl.text.trim().isEmpty
          ? null
          : _notesCtrl.text.trim()),
      ballisticProfileId: drift.Value(_selectedProfile?.id),
      recipeId: drift.Value(_selectedLoad?.id),
      firearmId: drift.Value(_selectedFirearm?.id),
      // Rack mode and single-target mode are mutually exclusive — see
      // the comment at the top of `_buildSessionCompanion`.
      targetId: drift.Value(hasActiveRack ? null : _selectedTarget?.id),
      rackId: drift.Value(hasActiveRack ? _selectedRack?.id : null),
      rackChildPosition:
          drift.Value(hasActiveRack ? _selectedRackChildPosition : null),
      distanceYd: drift.Value(distance),
      temperatureF: drift.Value(double.tryParse(_tempCtrl.text)),
      pressureInHg: drift.Value(double.tryParse(_pressureCtrl.text)),
      humidityPct: drift.Value(double.tryParse(_humidityCtrl.text)),
      elevationFt: drift.Value(double.tryParse(_elevationCtrl.text)),
      windSpeedMph: drift.Value(double.tryParse(_windSpeedCtrl.text)),
      windDirectionDeg: drift.Value(double.tryParse(_windDirCtrl.text)),
      // v11 — aim point + dispersion + reticle.
      aimPointX: drift.Value(_aimPointX),
      aimPointY: drift.Value(_aimPointY),
      assumedGroupMoa: drift.Value(_assumedGroupMoa),
      windUncertaintyMph: drift.Value(_windUncertaintyMph),
      rangeUncertaintyYd: drift.Value(_rangeUncertaintyYd),
      reticleId: drift.Value(_selectedReticleRow?.id),
      correctionUnit: drift.Value(_correctionUnit),
      // v15 ballistic precision — incline / decline angle (slope of fire).
      inclineAngleDeg: drift.Value(double.tryParse(_inclineAngleCtrl.text)),
      // v17 — link back to the atmosphere preset that pre-filled the
      // environment fields, if any. The id is cleared eagerly by the
      // picker / weather flows when the snapshot diverges so the FK
      // honestly reflects "this session was last set from this preset"
      // rather than going stale.
      atmospherePresetId: drift.Value(_atmospherePresetId),
    );
  }

  Future<void> _saveSession({bool collapseSetup = false}) async {
    final repo = context.read<RangeDayRepository>();
    final messenger = ScaffoldMessenger.of(context);
    // Save runs on every debounced edit, so a thrown exception here can
    // wedge the autosave loop. Catch + snackbar instead.
    try {
      if (_session == null) {
        final id = await repo.insertSession(_buildSessionCompanion());
        final fresh = await repo.getById(id);
        if (!mounted) return;
        setState(() {
          _session = fresh;
          _shotsStream = repo.streamShotsForSession(id);
          if (collapseSetup) {
            _setupExpanded = false;
            _environmentExpanded = false;
          }
        });
        messenger.showSnackBar(
          const SnackBar(content: Text('Session saved.')),
        );
      } else {
        await repo.updateSession(_session!.id, _buildSessionCompanion());
        final fresh = await repo.getById(_session!.id);
        if (!mounted) return;
        setState(() {
          _session = fresh;
          if (collapseSetup) {
            _setupExpanded = false;
            _environmentExpanded = false;
          }
        });
      }
    } catch (e, stack) {
      debugPrint('[range_day] _saveSession failed: $e');
      debugPrintStack(stackTrace: stack, label: '_saveSession');
      if (!mounted) return;
      messenger.showSnackBar(
        const SnackBar(
          content: Text(
            'Could not save the session. Your changes are still in the form.',
          ),
        ),
      );
    }
  }

  /// Auto-save (debounced) once the session has been saved at least once.
  /// Keeps recipe-style controls feeling sticky without persisting on
  /// every keystroke.
  void _scheduleAutoSave() {
    if (_session == null) return;
    _saveDebounce?.cancel();
    _saveDebounce = Timer(const Duration(milliseconds: 600), () {
      if (mounted) _saveSession();
    });
  }

  // ─────────────────────── Shots ───────────────────────

  Future<void> _recordShot(double normX, double normY) async {
    final messenger = ScaffoldMessenger.of(context);
    final repo = context.read<RangeDayRepository>();
    // Make sure we have a session row to anchor the shot.
    if (_session == null) {
      await _saveSession(collapseSetup: true);
    }
    if (_session == null) return;
    try {
      final shotNum = await repo.nextShotNumberForSession(_session!.id);
      await repo.insertShot(ShotImpactsCompanion.insert(
        rangeDaySessionId: _session!.id,
        shotNumber: shotNum,
        impactX: normX,
        impactY: normY,
      ));
      if (!mounted) return;
      // Sync the in-memory list so render is instant — the stream will
      // also re-emit, which is harmless.
      final fresh = await repo.shotsForSession(_session!.id);
      if (!mounted) return;
      setState(() => _shots = fresh);
      messenger.showSnackBar(
        SnackBar(
          content: Text('Shot $shotNum recorded.'),
          duration: const Duration(milliseconds: 800),
        ),
      );
    } catch (e, stack) {
      debugPrint('[range_day] _recordShot failed: $e');
      debugPrintStack(stackTrace: stack, label: '_recordShot');
      if (!mounted) return;
      messenger.showSnackBar(
        const SnackBar(
          content: Text('Could not record that shot. Try again.'),
        ),
      );
    }
  }

  Future<void> _editShotDialog(ShotImpactRow shot) async {
    final messenger = ScaffoldMessenger.of(context);
    final repo = context.read<RangeDayRepository>();
    final notesCtrl = TextEditingController(text: shot.notes ?? '');
    final velCtrl = TextEditingController(
        text: shot.velocityFps == null
            ? ''
            : shot.velocityFps!.toStringAsFixed(0));
    final result = await showDialog<_ShotEditResult>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Shot ${shot.shotNumber}'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: velCtrl,
              keyboardType: const TextInputType.numberWithOptions(
                  decimal: true),
              decoration: const InputDecoration(
                labelText: 'Velocity (fps, optional)',
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: notesCtrl,
              decoration: const InputDecoration(
                labelText: 'Notes',
              ),
              maxLines: 2,
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, _ShotEditResult.cancel),
            child: const Text('Cancel'),
          ),
          TextButton(
            style: TextButton.styleFrom(
              foregroundColor: Theme.of(ctx).colorScheme.error,
            ),
            onPressed: () => Navigator.pop(ctx, _ShotEditResult.delete),
            child: const Text('Delete'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, _ShotEditResult.save),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    try {
      if (result == _ShotEditResult.save) {
        final vel = double.tryParse(velCtrl.text.trim());
        await repo.updateShot(shot.id, ShotImpactsCompanion(
          notes: drift.Value(
              notesCtrl.text.trim().isEmpty ? null : notesCtrl.text.trim()),
          velocityFps: drift.Value(vel),
        ));
        if (!mounted) return;
        final fresh = await repo.shotsForSession(_session!.id);
        if (!mounted) return;
        setState(() => _shots = fresh);
      } else if (result == _ShotEditResult.delete) {
        await repo.deleteShot(shot.id);
        if (!mounted) return;
        final fresh = await repo.shotsForSession(_session!.id);
        if (!mounted) return;
        setState(() => _shots = fresh);
        messenger.showSnackBar(
          SnackBar(content: Text('Shot ${shot.shotNumber} deleted.')),
        );
      }
    } catch (e, stack) {
      debugPrint('[range_day] _editShotDialog failed: $e');
      debugPrintStack(stackTrace: stack, label: '_editShotDialog');
      if (mounted) {
        messenger.showSnackBar(
          const SnackBar(
            content: Text('Could not update that shot. Try again.'),
          ),
        );
      }
    } finally {
      notesCtrl.dispose();
      velCtrl.dispose();
    }
  }

  Future<void> _confirmClearShots() async {
    if (_session == null || _shots.isEmpty) return;
    final messenger = ScaffoldMessenger.of(context);
    final repo = context.read<RangeDayRepository>();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Clear all shots?'),
        content: const Text(
            'This deletes every recorded impact for this session.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Clear'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await repo.clearShotsForSession(_session!.id);
      if (!mounted) return;
      setState(() => _shots = const []);
      messenger.showSnackBar(
        const SnackBar(content: Text('Shots cleared.')),
      );
    } catch (e, stack) {
      debugPrint('[range_day] _confirmClearShots failed: $e');
      debugPrintStack(stackTrace: stack, label: '_confirmClearShots');
      if (mounted) {
        messenger.showSnackBar(
          const SnackBar(
            content: Text('Could not clear shots. Try again.'),
          ),
        );
      }
    }
  }

  // ─────────────────────── Weather (Pro) ───────────────────────

  Future<void> _onPullWeather() async {
    if (!await ensurePro(context)) return;
    if (!mounted) return;
    setState(() => _weatherFetching = true);
    final messenger = ScaffoldMessenger.of(context);
    try {
      final result = await WeatherService().fetchForCurrentLocation();
      if (!mounted) return;
      setState(() {
        _tempCtrl.text = result.tempF.toStringAsFixed(0);
        _pressureCtrl.text = result.stationPressureInHg.toStringAsFixed(2);
        _humidityCtrl.text = result.humidityPct.toStringAsFixed(0);
        _elevationCtrl.text = result.elevationFt.toStringAsFixed(0);
        _windSpeedCtrl.text = result.windSpeedMph.toStringAsFixed(0);
        _windDirCtrl.text = result.windDirectionDeg.toStringAsFixed(0);
        _weatherFetchedAt = result.fetchedAt;
        // Live values now match a freshly-pulled reading rather than any
        // saved preset, so clear the picker FK back to "Custom".
        _atmospherePresetId = null;
      });
      _scheduleSolve();
      _scheduleAutoSave();
      // Offer to capture this set of conditions as a saved preset so the
      // user can switch back to it in one tap on a future range day.
      messenger.showSnackBar(
        SnackBar(
          duration: const Duration(seconds: 5),
          content: const Text('Pulled current weather.'),
          action: SnackBarAction(
            label: 'Save as preset',
            onPressed: () async {
              final newId = await showSaveAtmospherePresetDialog(
                context,
                stationPressureInHg: result.stationPressureInHg,
                temperatureF: result.tempF,
                humidityPct: result.humidityPct,
                altitudeFt: result.elevationFt,
              );
              if (newId != null && mounted) {
                setState(() => _atmospherePresetId = newId);
                _scheduleAutoSave();
              }
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
        const SnackBar(content: Text('Couldn\'t fetch weather.')),
      );
    } finally {
      if (mounted) setState(() => _weatherFetching = false);
    }
  }

  // ─────────────────────── Kestrel (Pro, BLE) ───────────────────────

  Future<void> _onStartUsingKestrel() async {
    if (!await ensurePro(context)) return;
    if (!mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    try {
      final kestrel = context.read<KestrelService>();
      if (kestrel.device == null) return;
      await _kestrelSub?.cancel();
      _kestrelSub = kestrel.readings.listen(_applyKestrelReading);
      setState(() => _useKestrel = true);
      final last = kestrel.lastReading;
      if (last != null) _applyKestrelReading(last);
      if (!mounted) return;
      messenger.showSnackBar(
        const SnackBar(content: Text('Pulling live data from Kestrel.')),
      );
    } catch (e, stack) {
      debugPrint('[range_day] _onStartUsingKestrel failed: $e');
      debugPrintStack(stackTrace: stack, label: '_onStartUsingKestrel');
      if (!mounted) return;
      messenger.showSnackBar(
        const SnackBar(
          content: Text('Could not start Kestrel stream. Reconnect and try again.'),
        ),
      );
    }
  }

  Future<void> _onStopUsingKestrel() async {
    try {
      await _kestrelSub?.cancel();
    } catch (e, stack) {
      // Cancellation should never throw, but if it does we still want
      // to clear the local "live" state so the toggle reflects reality.
      debugPrint('[range_day] _onStopUsingKestrel cancel failed: $e');
      debugPrintStack(stackTrace: stack, label: '_onStopUsingKestrel');
    }
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
    _scheduleSolve();
    _scheduleAutoSave();
  }

  // ─────────────────────── Garmin Xero (.fit) ───────────────────────

  /// Pro: import shot velocities from a Garmin Xero `.fit` export and
  /// merge them into [_shots] in shot order. Existing impacts keep
  /// their positions; we only fill `velocityFps`. If the .fit file
  /// has more shots than there are recorded impacts, the extras are
  /// dropped (the user can record them by tapping the target before
  /// re-importing if they want them merged in).
  Future<void> _onImportGarminFit() async {
    if (!await ensurePro(context)) return;
    if (!mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    final ble = context.read<BleService>();
    try {
      final picked = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: const ['fit'],
        withData: false,
      );
      if (picked == null || picked.files.isEmpty) return;
      final path = picked.files.single.path;
      if (path == null) {
        messenger.showSnackBar(
          const SnackBar(content: Text("Couldn't read the selected file.")),
        );
        return;
      }
      final session = await GarminXeroService(ble).importFitFile(path);
      if (!mounted) return;
      // Match velocities to existing impacts by shot order.
      final velocities = session.shots.map((s) => s.velocityFps).toList();
      final updated = <ShotImpactRow>[];
      for (int i = 0; i < _shots.length; i++) {
        final shot = _shots[i];
        if (i < velocities.length) {
          updated.add(shot.copyWith(velocityFps: drift.Value(velocities[i])));
        } else {
          updated.add(shot);
        }
      }
      setState(() => _shots = updated);
      // Persist if the session is saved.
      if (_session != null) {
        final repo = context.read<RangeDayRepository>();
        for (final s in updated) {
          if (s.velocityFps == null) continue;
          await repo.updateShot(
            s.id,
            ShotImpactsCompanion(velocityFps: drift.Value(s.velocityFps)),
          );
        }
      }
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            'Imported ${velocities.length} velocities from Garmin .fit. '
            'Avg ${session.averageFps.toStringAsFixed(0)} fps.',
          ),
        ),
      );
    } on GarminXeroParseException catch (e) {
      if (!mounted) return;
      messenger.showSnackBar(SnackBar(content: Text(e.userMessage)));
    } catch (e) {
      if (!mounted) return;
      messenger.showSnackBar(
        SnackBar(content: Text("Couldn't import that file: $e")),
      );
    }
  }

  // ─────────────────────── Build ───────────────────────

  @override
  Widget build(BuildContext context) {
    final isWide = Breakpoints.isWide(context);
    return Scaffold(
      appBar: AppBar(
        // Title is constant "Range Day" — the user explicitly rejected
        // a per-session name in the AppBar ("There is no 'New' Range
        // Day. There is only one"). The session name lives in the
        // History list, not the AppBar.
        title: const Text('Range Day'),
        actions: [
          // Quick / Full toggle. Quick (default) collapses the screen
          // to Setup + Solution — what a user actually needs at the
          // firing line. Full reveals every advanced card. Persisted
          // per-user via SharedPreferences (see [_persistRangeDayMode]).
          // Compact icon-segmented form chosen over labeled segments to
          // keep the AppBar usable on narrow phones alongside the
          // existing History + Recalculate icons.
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: SegmentedButton<RangeDayMode>(
              segments: const [
                ButtonSegment<RangeDayMode>(
                  value: RangeDayMode.quick,
                  icon: Icon(Icons.bolt),
                  tooltip: 'Quick — Setup + Solution only',
                ),
                ButtonSegment<RangeDayMode>(
                  value: RangeDayMode.full,
                  icon: Icon(Icons.tune),
                  tooltip: 'Full — every card',
                ),
              ],
              selected: {_mode},
              showSelectedIcon: false,
              style: SegmentedButton.styleFrom(
                visualDensity: VisualDensity.compact,
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
              onSelectionChanged: (sel) {
                final next = sel.first;
                if (next == _mode) return;
                setState(() => _mode = next);
                // Fire-and-forget — the UI has already reflowed.
                // ignore: discarded_futures
                _persistRangeDayMode(next);
              },
            ),
          ),
          // History entry point. The bottom-nav "Range Day" tab now
          // always opens a fresh detail screen; users reach the saved-
          // sessions list through this action instead of from a
          // dedicated tab. Pushed (not replaced) on top of the current
          // detail so backing out of History returns the user to their
          // in-progress session draft without losing state.
          IconButton(
            tooltip: 'History',
            icon: const Icon(Icons.history),
            onPressed: _openHistory,
          ),
          IconButton(
            tooltip: 'Recalculate',
            icon: const Icon(Icons.refresh),
            onPressed: _solve,
          ),
        ],
      ),
      body: RangeDayErrorBoundary(
        label: 'Range Day session',
        child: SafeArea(
          child: isWide ? _wideBody() : _phoneBody(),
        ),
      ),
    );
  }

  /// Single-column phone layout.
  Widget _phoneBody() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Pinned solver-error banner. Renders only when _solveError is
        // set; otherwise SizedBox.shrink so the layout above the
        // scroll view is unchanged. The banner replaces the inline
        // error tile that used to live inside _solutionCard, which
        // was invisible once the user scrolled past it.
        _solveErrorBanner(),
        _solutionStrip(),
        Expanded(
          child: SingleChildScrollView(
            controller: _phoneScrollCtrl,
            // Dismiss the keyboard as soon as the user starts a drag.
            // Prevents the keyboard's "scroll-focused-field-into-view"
            // helper from racing the user's scroll gesture (the
            // observed cause of the "page jumps to bottom" bug when
            // the distance TextField had focus).
            keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _setupCard(),
                // Everything below Setup except the Solution card is
                // gated to Full mode. Quick mode keeps the surface
                // calm — Setup + Solution only — for the at-the-line
                // user. The session still solves in Quick mode (the
                // solver reads its inputs from the persisted state,
                // not from card visibility).
                if (_mode == RangeDayMode.full) ...[
                  const SizedBox(height: 12),
                  _environmentCard(),
                ],
                const SizedBox(height: 12),
                _solutionCard(),
                if (_mode == RangeDayMode.full) ...[
                  const SizedBox(height: 12),
                  ..._windBracketSection(),
                  _hitProbCard(),
                  const SizedBox(height: 12),
                  _targetPlotCard(),
                  const SizedBox(height: 12),
                  _groupStatsCard(),
                  if (_shots.isNotEmpty) ...[
                    const SizedBox(height: 12),
                    _correctionCard(),
                  ],
                  const SizedBox(height: 12),
                  _movingTargetCard(),
                  const SizedBox(height: 12),
                  _dopeCard(),
                  const SizedBox(height: 12),
                  _notesCard(),
                ],
              ],
            ),
          ),
        ),
      ],
    );
  }

  /// Two-column tablet / desktop layout. Left: setup / env / solution.
  /// Right: target plot / DOPE / moving target.
  ///
  /// Quick mode collapses the wide layout back to a single centered
  /// column — the right-hand cards are all advanced and would render
  /// an empty pane otherwise. The single column is width-capped so it
  /// doesn't stretch awkwardly on a 27" monitor.
  Widget _wideBody() {
    if (_mode == RangeDayMode.quick) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _solveErrorBanner(),
          _solutionStrip(),
          Expanded(
            child: SingleChildScrollView(
              controller: _wideLeftScrollCtrl,
              keyboardDismissBehavior:
                  ScrollViewKeyboardDismissBehavior.onDrag,
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
              child: Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 720),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      _setupCard(),
                      const SizedBox(height: 12),
                      _solutionCard(),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Pinned solver-error banner — same role as in `_phoneBody`.
        _solveErrorBanner(),
        _solutionStrip(),
        Expanded(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                flex: 5,
                child: SingleChildScrollView(
                  controller: _wideLeftScrollCtrl,
                  keyboardDismissBehavior:
                      ScrollViewKeyboardDismissBehavior.onDrag,
                  padding: const EdgeInsets.fromLTRB(16, 12, 8, 32),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      _setupCard(),
                      const SizedBox(height: 12),
                      _environmentCard(),
                      const SizedBox(height: 12),
                      _solutionCard(),
                      const SizedBox(height: 12),
                      // HitProb sits directly under Solution in the wide
                      // layout so the user sees their odds-of-a-hit gauge
                      // before the wind-bracket diagnostic — it's the
                      // headline number, not a footnote.
                      _hitProbCard(),
                      const SizedBox(height: 12),
                      ..._windBracketSection(),
                      _groupStatsCard(),
                      const SizedBox(height: 12),
                      _notesCard(),
                    ],
                  ),
                ),
              ),
              Expanded(
                flex: 6,
                child: SingleChildScrollView(
                  controller: _wideRightScrollCtrl,
                  keyboardDismissBehavior:
                      ScrollViewKeyboardDismissBehavior.onDrag,
                  padding: const EdgeInsets.fromLTRB(8, 12, 16, 32),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      _targetPlotCard(),
                      if (_shots.isNotEmpty) ...[
                        const SizedBox(height: 12),
                        _correctionCard(),
                      ],
                      const SizedBox(height: 12),
                      _dopeCard(),
                      const SizedBox(height: 12),
                      _movingTargetCard(),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  // ─────────────────────── Cards ───────────────────────

  Widget _setupCard() {
    final theme = Theme.of(context);
    final summary = _setupSummary();
    return Card(
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          InkWell(
            onTap: () => setState(() => _setupExpanded = !_setupExpanded),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 8, 12),
              child: Row(
                children: [
                  Icon(Icons.tune, color: theme.colorScheme.primary),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('Setup', style: theme.textTheme.titleMedium),
                        if (!_setupExpanded && summary.isNotEmpty)
                          Padding(
                            padding: const EdgeInsets.only(top: 2),
                            child: Text(
                              summary,
                              style: theme.textTheme.bodySmall,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                      ],
                    ),
                  ),
                  Icon(_setupExpanded
                      ? Icons.expand_less
                      : Icons.expand_more),
                ],
              ),
            ),
          ),
          if (_setupExpanded) _setupBody(),
        ],
      ),
    );
  }

  String _setupSummary() {
    final parts = <String>[];
    final targetName = _activeTargetDisplayName;
    if (targetName != null) parts.add(targetName);
    final dist = double.tryParse(_distanceCtrl.text.trim());
    if (dist != null) parts.add('${dist.toStringAsFixed(0)} yd');
    if (_selectedProfile != null) parts.add(_selectedProfile!.name);
    if (_selectedLoad != null) parts.add(_selectedLoad!.name);
    if (_selectedFirearm != null) parts.add(_selectedFirearm!.name);
    return parts.join(' · ');
  }

  Widget _setupBody() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _targetPicker(),
          const SizedBox(height: 12),
          _distancePicker(),
          const SizedBox(height: 12),
          _profilePicker(),
          const SizedBox(height: 12),
          _loadPicker(),
          const SizedBox(height: 12),
          _firearmPicker(),
          // Stability + form factor read-out — only renders when both
          // a load and firearm have been picked (the Sg formulas need
          // length and twist, which come from those rows). Uses a
          // helper that returns SizedBox.shrink() when inputs are
          // incomplete, so the surrounding layout stays clean.
          _stabilityAndFormFactor(),
          const SizedBox(height: 12),
          _reticlePicker(),
          const SizedBox(height: 12),
          _shotAzimuthRow(),
          const SizedBox(height: 12),
          _inclineAngleRow(),
          const SizedBox(height: 12),
          _orientationRows(),
          const SizedBox(height: 12),
          _captureEnvironmentFromSensorsButton(),
          const SizedBox(height: 12),
          _capabilityExpander(),
          const SizedBox(height: 12),
          _litzAnalysisButtons(),
          const SizedBox(height: 16),
          FilledButton.icon(
            onPressed: () => _saveSession(collapseSetup: true),
            icon: const Icon(Icons.save_outlined),
            label: Text(_session == null ? 'Save Session' : 'Update Session'),
          ),
        ],
      ),
    );
  }

  /// Three Pro-gated entries to the Bryan Litz / Applied Ballistics
  /// parity features (schema v16). Each one routes to its own screen
  /// after `ensurePro` clears.
  Widget _litzAnalysisButtons() {
    final theme = Theme.of(context);
    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: theme.colorScheme.outlineVariant),
      ),
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(children: [
            Icon(Icons.science_outlined,
                color: theme.colorScheme.primary, size: 18),
            const SizedBox(width: 6),
            GlossaryLabel(
              text: 'Litz analysis (Pro)',
              glossaryTerm: 'Confidence interval (90%)',
              style: theme.textTheme.titleSmall,
            ),
          ]),
          const SizedBox(height: 4),
          Text(
            'Probability-based engagement modeling, observed-vs-predicted '
            'BC truing, and tall-target sight calibration.',
            style: theme.textTheme.bodySmall,
          ),
          const SizedBox(height: 8),
          // Align(centerLeft) breaks the infinite-width inheritance from
          // the parent `Column(crossAxisAlignment: stretch)`. Without it,
          // Wrap is told it has infinite width, which it tries to honor —
          // and Material's `OutlinedButton.icon` `_RenderInputPadding`
          // immediately throws "BoxConstraints forces infinite width" at
          // layout time, crashing the screen on first render. Align
          // imposes no width constraint on its child, so the Wrap sizes
          // to its children instead. This is the canonical fix for
          // "Wrap inside a stretching Flex" — see Flutter issue #18781.
          Align(
            alignment: Alignment.centerLeft,
            child: Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                OutlinedButton.icon(
                  icon: const Icon(Icons.show_chart, size: 18),
                  label: const Text('WEZ analysis'),
                  onPressed: () => _openWezAnalysis(),
                ),
                OutlinedButton.icon(
                  icon: const Icon(Icons.assessment_outlined, size: 18),
                  label: const Text('BC truing'),
                  onPressed: () => _openBcTruing(),
                ),
                OutlinedButton.icon(
                  icon: const Icon(Icons.straighten, size: 18),
                  label: const Text('Sight calibration'),
                  onPressed: () => _openSightCalibration(),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _openWezAnalysis() async {
    if (!await ensurePro(context)) return;
    final dist = double.tryParse(_distanceCtrl.text.trim());
    if (!mounted) return;
    await safeAsync<void>(
      context,
      mounted: () => mounted,
      userMessage: 'Could not open WEZ analysis.',
      body: () async {
        await Navigator.of(context).push(MaterialPageRoute(
          builder: (_) => WezAnalysisScreen(
            initialLoadId: _selectedLoad?.id,
            initialFirearmId: _selectedFirearm?.id,
            initialTargetId: _selectedTarget?.id,
            initialDistanceYd: dist,
          ),
        ));
      },
    );
  }

  Future<void> _openBcTruing() async {
    if (!await ensurePro(context)) return;
    if (!mounted) return;
    await safeAsync<void>(
      context,
      mounted: () => mounted,
      userMessage: 'Could not open BC truing.',
      body: () async {
        await Navigator.of(context).push(MaterialPageRoute(
          builder: (_) => BcTruingScreen(
            initialLoadId: _selectedLoad?.id,
            initialFirearmId: _selectedFirearm?.id,
          ),
        ));
      },
    );
  }

  Future<void> _openSightCalibration() async {
    if (!await ensurePro(context)) return;
    if (!mounted) return;
    await safeAsync<void>(
      context,
      mounted: () => mounted,
      userMessage: 'Could not open sight calibration.',
      body: () async {
        await Navigator.of(context).push(MaterialPageRoute(
          builder: (_) => SightCalibrationScreen(
            initialFirearmId: _selectedFirearm?.id,
          ),
        ));
      },
    );
  }

  // ─────────────────────── Shot azimuth ───────────────────────

  /// Number field for the rifle's compass direction. Used for the
  /// long-range Coriolis correction in the firing solution. The
  /// magnetometer "Use as shot azimuth" button (in [_orientationRows])
  /// writes into this controller.
  Widget _shotAzimuthRow() {
    return TextField(
      controller: _shotAzimuthCtrl,
      keyboardType:
          const TextInputType.numberWithOptions(decimal: true, signed: false),
      decoration: const InputDecoration(
        // Using `label:` (a Widget) instead of `labelText:` so the
        // GlossaryLabel widget can render the (?) help glyph and
        // intercept taps for the in-form definition modal. Same
        // floating-label treatment Material gives the string variant.
        label: GlossaryLabel(
          text: 'Shot azimuth (°)',
          glossaryTerm: 'Azimuth',
        ),
        helperText:
            'Compass direction of the shot — 0=N, 90=E, 180=S, 270=W. '
            'Used for Coriolis at long range; leave 0 if unsure.',
        helperMaxLines: 3,
      ),
      onChanged: (_) {
        _scheduleSolve();
        _scheduleAutoSave();
      },
    );
  }

  // ─────────────────────── Incline / decline angle (v16) ───────────────────────

  /// Number field for the slope of fire (positive = uphill,
  /// negative = downhill). Includes a "Capture from sensor" button
  /// that reads the InclinometerService's current pitch and pushes
  /// it into the field. Hidden when the inclinometer service reports
  /// the platform doesn't expose an accelerometer (web/desktop).
  Widget _inclineAngleRow() {
    final theme = Theme.of(context);
    return Consumer<InclinometerService>(
      builder: (context, inclineSvc, _) {
        final available = inclineSvc.isAvailable;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextField(
              controller: _inclineAngleCtrl,
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
                signed: true,
              ),
              decoration: const InputDecoration(
                // Using `label:` (Widget) instead of `labelText:`
                // (String) lets GlossaryLabel render the (?) glyph.
                label: GlossaryLabel(
                  text: 'Incline / decline angle (°)',
                  glossaryTerm: 'Incline / decline angle',
                ),
                helperText:
                    'Slope of fire — positive = uphill, negative = '
                    'downhill. Drop reduces with steep angles via the '
                    'improved rifleman\'s rule.',
                helperMaxLines: 3,
              ),
              onChanged: (_) {
                _scheduleSolve();
                _scheduleAutoSave();
              },
            ),
            if (available)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                // Layout fix: the parent is `Column(crossAxisAlignment:
                // stretch)` (line ~1648), which forwards an infinite-
                // width constraint down. We need to break that chain
                // before reaching `OutlinedButton`, whose internal
                // `RenderConstrainedBox` (the minimum tap-target
                // enforcer at 48dp) would otherwise hand `w=Infinity`
                // to the Material's `RenderPhysicalShape` (shadow
                // renderer), which asserts.
                //
                // We previously tried `Align + Row(MainAxisSize.min) +
                // Flexible`. That LOOKS right but `Align` only loosens
                // its own constraints, and `Row` with the default
                // cross-axis alignment passes `BoxConstraints(maxHeight:
                // ...)` to non-flex children — which has implicit
                // `maxWidth: Infinity`. So the OutlinedButton still
                // received unbounded width and crashed.
                //
                // Canonical fix: `Align(centerLeft) + Wrap`. This is
                // the same pattern `_litzAnalysisButtons` uses (line
                // ~1546) and the chip Wraps elsewhere in this file.
                // `Wrap` lays out children at their intrinsic widths
                // and wraps to a new line if needed, so on a narrow
                // device the live-readout falls below the button
                // instead of crashing.
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Wrap(
                    spacing: 8,
                    runSpacing: 4,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      OutlinedButton.icon(
                        onPressed: _captureInclineFromSensor,
                        icon: const Icon(Icons.straighten, size: 16),
                        label: const Text('Capture from sensor'),
                      ),
                      Builder(builder: (ctx) {
                        final inc = inclineSvc.inclineDegrees;
                        if (inc == null) {
                          return Text(
                            'Live: ...',
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: theme.colorScheme.onSurfaceVariant,
                            ),
                          );
                        }
                        return Text(
                          'Live: ${inc >= 0 ? '+' : ''}'
                          '${inc.toStringAsFixed(1)}°',
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                            fontFeatures: const [
                              FontFeature.tabularFigures()
                            ],
                          ),
                        );
                      }),
                    ],
                  ),
                ),
              ),
          ],
        );
      },
    );
  }

  /// Read the live inclinometer pitch and push it into the angle
  /// controller. Surfaces a snackbar when no sample has arrived yet.
  void _captureInclineFromSensor() {
    final svc = context.read<InclinometerService>();
    final pitch = svc.inclineDegrees;
    final messenger = ScaffoldMessenger.of(context);
    if (pitch == null) {
      messenger.showSnackBar(
        const SnackBar(
          content: Text('No incline sample yet. Try again in a moment.'),
        ),
      );
      return;
    }
    setState(() {
      _inclineAngleCtrl.text = pitch.toStringAsFixed(1);
    });
    _scheduleSolve();
    _scheduleAutoSave();
    messenger.showSnackBar(
      SnackBar(
        duration: const Duration(milliseconds: 1500),
        content: Text(
          'Captured incline ${pitch >= 0 ? '+' : ''}'
          '${pitch.toStringAsFixed(1)}°',
        ),
      ),
    );
  }

  // ─────────────────────── Capture environment from sensors (v16) ───────────────────────

  /// Single tap pulls everything available from the device sensors:
  /// GPS lat/lon + altitude + station-pressure approximation, plus
  /// magnetometer azimuth, accelerometer cant, and inclinometer pitch.
  /// Surfaces a confirmation snackbar with the captured values.
  ///
  /// The button is free for everyone — the cant / heading / incline
  /// pieces are pulled from on-device sensors that don't cost anything.
  /// The GPS altitude / station-pressure derivation is the only
  /// network-dependent part and is Pro-gated. Free users see a small
  /// "Altitude requires Pro" caption under the title so they know
  /// what's missing before they tap.
  Widget _captureEnvironmentFromSensorsButton() {
    final theme = Theme.of(context);
    final isPro = context.watch<EntitlementNotifier>().isPro;
    // Container instead of Card here — this affordance is rendered
    // INSIDE the Environment card body, and a nested Card produced a
    // visual "card-inside-a-card" with a double border. A subtle filled
    // container with a soft outline reads as a content block rather
    // than a separate surface.
    return Container(
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: theme.colorScheme.outlineVariant,
          width: 1,
        ),
      ),
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Icon(Icons.my_location,
                  size: 16, color: theme.colorScheme.primary),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  'One-tap environment capture',
                  style: theme.textTheme.labelLarge?.copyWith(
                    color: theme.colorScheme.primary,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            isPro
                ? 'Pulls GPS lat/lon, altitude, station pressure, true '
                    'azimuth (compass), cant (rifle level), and incline '
                    '(slope of fire) into the session in one tap.'
                : 'Pulls true azimuth (compass), cant (rifle level), '
                    'and incline (slope of fire) from device sensors. '
                    'Altitude requires Pro.',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 8),
          FilledButton.tonalIcon(
            onPressed: _captureEnvironmentFromSensors,
            icon: const Icon(Icons.sensors, size: 18),
            label: const Text('Capture environment from sensors'),
          ),
        ],
      ),
    );
  }

  /// Handler for the consolidated "Capture environment from sensors"
  /// button. Walks the live sensors + GPS handshake, then surfaces a
  /// detailed snackbar so the user sees what was captured.
  ///
  /// Pro-gating: the cant / heading / incline values come from the
  /// device's free local sensors and stay free for everyone. The GPS
  /// altitude → station-pressure derivation is a Pro feature (it
  /// requires a network round trip to open-meteo for the surface
  /// pressure correction). Free users still get cant / heading /
  /// incline; the Altitude field stays at 0 ft (sea level) and the
  /// snackbar adds an "Altitude requires Pro" caption explaining why
  /// the elevation column wasn't filled in.
  Future<void> _captureEnvironmentFromSensors() async {
    final messenger = ScaffoldMessenger.of(context);
    final isPro = context.read<EntitlementNotifier>().isPro;
    // Sensor reads are property accessors so they shouldn't throw, but
    // a misbehaving plugin (or a recent platform change) could. Skip
    // the broken sensor and keep going so the user still gets the
    // ones that DO work.
    double? cant;
    double? heading;
    double? incline;
    try {
      cant = context.read<CantService>().cantDegrees;
    } catch (e) {
      debugPrint('[range_day] CantService read failed: $e');
    }
    try {
      heading = context.read<MagnetometerService>().headingDegrees;
    } catch (e) {
      debugPrint('[range_day] MagnetometerService read failed: $e');
    }
    try {
      incline = context.read<InclinometerService>().inclineDegrees;
    } catch (e) {
      debugPrint('[range_day] InclinometerService read failed: $e');
    }
    // Pull location-derived values via the existing weather service —
    // it already wraps the geolocator handshake AND reports station
    // pressure + altitude in one round trip. Pro-only — free users
    // keep the cant / azimuth / incline fields and skip the network
    // call entirely.
    WeatherFetchResult? weather;
    if (isPro) {
      try {
        weather = await WeatherService().fetchForCurrentLocation();
      } on WeatherFetchException catch (e) {
        messenger.showSnackBar(SnackBar(content: Text(e.userMessage)));
      } catch (_) {
        messenger.showSnackBar(
          const SnackBar(content: Text('Couldn\'t fetch weather.')),
        );
      }
    }
    if (!mounted) return;
    setState(() {
      if (heading != null) {
        _shotAzimuthCtrl.text = heading.toStringAsFixed(0);
      }
      if (incline != null) {
        _inclineAngleCtrl.text = incline.toStringAsFixed(1);
      }
      if (weather != null) {
        _tempCtrl.text = weather.tempF.toStringAsFixed(0);
        _pressureCtrl.text =
            weather.stationPressureInHg.toStringAsFixed(2);
        _humidityCtrl.text = weather.humidityPct.toStringAsFixed(0);
        _elevationCtrl.text = weather.elevationFt.toStringAsFixed(0);
        _windSpeedCtrl.text = weather.windSpeedMph.toStringAsFixed(0);
        _windDirCtrl.text =
            weather.windDirectionDeg.toStringAsFixed(0);
        _weatherFetchedAt = weather.fetchedAt;
      } else if (!isPro) {
        // Default altitude to sea level for free users — the spec calls
        // this out as the graceful fallback so the rest of the
        // ballistics inputs still produce a sensible solution.
        if (_elevationCtrl.text.trim().isEmpty) {
          _elevationCtrl.text = '0';
        }
      }
    });
    _scheduleSolve();
    _scheduleAutoSave();
    final parts = <String>[];
    if (weather != null) {
      parts.add('Altitude: ${weather.elevationFt.toStringAsFixed(0)} ft');
      parts.add(
          'Station: ${weather.stationPressureInHg.toStringAsFixed(2)} inHg');
      parts.add('Temp: ${weather.tempF.toStringAsFixed(0)}°F');
      parts.add('Humidity: ${weather.humidityPct.toStringAsFixed(0)}%');
      parts.add('Wind: ${weather.windSpeedMph.toStringAsFixed(0)} mph @ '
          '${weather.windDirectionDeg.toStringAsFixed(0)}°');
    }
    if (heading != null) {
      parts.add('Azimuth: ${heading.toStringAsFixed(0)}°');
    }
    if (cant != null) {
      parts
          .add('Cant: ${cant >= 0 ? '+' : ''}${cant.toStringAsFixed(1)}°');
    }
    if (incline != null) {
      parts.add('Incline: ${incline >= 0 ? '+' : ''}'
          '${incline.toStringAsFixed(1)}°');
    }
    final summary = parts.isEmpty
        ? 'No sensor data captured. Try again outdoors.'
        : '✓ Captured from your location\n  ${parts.join('  ·  ')}';
    final paywallSuffix = isPro
        ? ''
        : '\nAltitude requires Pro — tap the cloud icon on Ballistics to upgrade.';
    // Attach the "Save as preset" snackbar action only when we got at
    // least the four core atmosphere fields (i.e. weather succeeded).
    SnackBarAction? action;
    if (weather != null) {
      final w = weather;
      action = SnackBarAction(
        label: 'Save as preset',
        onPressed: () async {
          final newId = await showSaveAtmospherePresetDialog(
            context,
            stationPressureInHg: w.stationPressureInHg,
            temperatureF: w.tempF,
            humidityPct: w.humidityPct,
            altitudeFt: w.elevationFt,
          );
          if (newId != null && mounted) {
            setState(() => _atmospherePresetId = newId);
            _scheduleAutoSave();
          }
        },
      );
    }
    messenger.showSnackBar(
      SnackBar(
        duration: const Duration(seconds: 6),
        content: Text('$summary$paywallSuffix'),
        action: action,
      ),
    );
  }

  // ─────────────────────── Orientation (cant + heading) ───────────────────────

  /// The cant (level) and magnetometer (heading) live-readout rows,
  /// wrapped in a collapsible "Sensors" expander. Collapsed by default
  /// so beginners don't have to look at extra readouts they don't yet
  /// care about; the collapsed header still shows live values as a
  /// chip strip:
  ///
  ///     📐 Cant: -0.4° (level)   🧭 Azimuth: 287° (W)   [ Live updates ●○ ]
  ///
  /// Tapping anywhere on the header expands to the full cant + heading
  /// rows with their calibration / "Use as shot azimuth" buttons. Power
  /// users can leave it expanded for the session.
  ///
  /// On platforms without these sensors (macOS, web), the underlying
  /// services report `isAvailable == false` and the rows render a
  /// "Sensor unavailable" placeholder so the screen still degrades
  /// gracefully.
  Widget _orientationRows() {
    final theme = Theme.of(context);
    return Container(
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          InkWell(
            onTap: () => setState(
                () => _sensorsExpanded = !_sensorsExpanded),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 10, 8, 10),
              child: _sensorsHeader(),
            ),
          ),
          if (_sensorsExpanded)
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _cantRow(),
                  const Divider(height: 20),
                  _headingRow(),
                  const SizedBox(height: 8),
                  _liveUpdatesToggle(),
                ],
              ),
            ),
        ],
      ),
    );
  }

  /// Header row for the Sensors expander. When collapsed, mirrors the
  /// live cant + azimuth values as a chip strip so the user gets the
  /// information without expanding. When expanded, shows just the title
  /// + chevron.
  Widget _sensorsHeader() {
    final theme = Theme.of(context);
    if (_sensorsExpanded) {
      return Row(
        children: [
          Icon(Icons.sensors,
              size: 18, color: theme.colorScheme.primary),
          const SizedBox(width: 8),
          Text('Sensors', style: theme.textTheme.titleSmall),
          const Spacer(),
          const Icon(Icons.expand_less),
        ],
      );
    }
    // Read sensor values WITHOUT subscribing. Both CantService and
    // MagnetometerService notify at ~50 Hz; subscribing via
    // `context.watch<>` here triggered ~100 widget rebuilds/sec on the
    // collapsed-header path, which tripped the `parentDataDirty` semantics
    // assertion in the rendering layer (`object.dart:5493`) and crashed
    // a fresh-session Range Day open. The `_liveUpdatesToggle` already
    // owns refresh: when the user opts in, a 2 Hz `Timer.periodic` calls
    // `setState({})` which re-runs this build at a sane rate. When the
    // toggle is off, the chip stays static — that's the documented
    // "off" semantics.
    final cantSvc = context.read<CantService>();
    final magSvc = context.read<MagnetometerService>();
    final cant = cantSvc.cantDegrees;
    final cantAvail = cantSvc.isAvailable;
    final heading = magSvc.headingDegrees;
    final headingAvail = magSvc.isAvailable;
    final cantStr = !cantAvail
        ? '—'
        : (cant == null
            ? '…'
            : '${cant >= 0 ? '+' : ''}${cant.toStringAsFixed(1)}°');
    final headingStr = !headingAvail
        ? '—'
        : (heading == null
            ? '…'
            : '${heading.toStringAsFixed(0)}° ${_compassLabel(heading)}');
    final cantWarn = cant != null && cant.abs() > 2.0;
    return Row(
      children: [
        Icon(Icons.sensors, size: 18, color: theme.colorScheme.primary),
        const SizedBox(width: 8),
        Text('Sensors', style: theme.textTheme.titleSmall),
        const SizedBox(width: 12),
        Icon(Icons.straighten,
            size: 14,
            color: cantWarn
                ? theme.colorScheme.error
                : theme.colorScheme.onSurfaceVariant),
        const SizedBox(width: 2),
        Text(
          cantStr,
          style: theme.textTheme.bodySmall?.copyWith(
            fontFeatures: const [FontFeature.tabularFigures()],
            color: cantWarn ? theme.colorScheme.error : null,
          ),
        ),
        const SizedBox(width: 10),
        Icon(Icons.explore,
            size: 14, color: theme.colorScheme.onSurfaceVariant),
        const SizedBox(width: 2),
        Text(
          headingStr,
          style: theme.textTheme.bodySmall?.copyWith(
            fontFeatures: const [FontFeature.tabularFigures()],
          ),
        ),
        const Spacer(),
        const Icon(Icons.expand_more),
      ],
    );
  }

  /// "Live updates" pulse toggle. The CantService and MagnetometerService
  /// already stream at ~10–15 Hz; this toggle simply feeds a 2 Hz timer
  /// that calls `setState` so the chip strip + bubble level get a
  /// noticeable "refresh" feeling. With it OFF the rebuilds still happen
  /// — just driven by the underlying ChangeNotifier instead of the
  /// timer — but the user sees a deliberate pulse when they enable it.
  Widget _liveUpdatesToggle() {
    return SwitchListTile.adaptive(
      contentPadding: EdgeInsets.zero,
      dense: true,
      title: const Text('Live updates'),
      subtitle: const Text(
          '2 Hz refresh of the cant + heading chip — useful for verifying '
          'the sensors are alive without staring at the readout.'),
      value: _sensorsLive,
      onChanged: (v) {
        setState(() {
          _sensorsLive = v;
          _sensorsPulse?.cancel();
          if (v) {
            _sensorsPulse = Timer.periodic(
              const Duration(milliseconds: 500),
              (_) {
                if (!mounted) return;
                setState(() {});
              },
            );
          }
        });
      },
    );
  }

  /// Live cant (rifle level) row: readout + "Use phone level" button +
  /// Pro-gated "Apply cant correction" toggle.
  Widget _cantRow() {
    final theme = Theme.of(context);
    return Consumer<CantService>(
      builder: (context, cantSvc, _) {
        final available = cantSvc.isAvailable;
        final cant = cantSvc.cantDegrees;
        final readout = !available
            ? 'Sensor unavailable'
            : (cant == null
                ? '—'
                : '${cant >= 0 ? '+' : ''}${cant.toStringAsFixed(1)}°');
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Icon(Icons.straighten,
                    size: 18, color: theme.colorScheme.primary),
                const SizedBox(width: 8),
                GlossaryLabel(
                  text: 'Cant',
                  glossaryTerm: 'Cant correction',
                  style: theme.textTheme.titleSmall,
                ),
                const Spacer(),
                Text(
                  readout,
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontFeatures: const [FontFeature.tabularFigures()],
                    color: !available
                        ? theme.colorScheme.outline
                        : (cant != null && cant.abs() > 2
                            ? theme.colorScheme.error
                            : theme.colorScheme.onSurface),
                  ),
                ),
              ],
            ),
            if (available) ...[
              const SizedBox(height: 8),
              // `Align(centerLeft) + Wrap` — same pattern as
              // `_litzAnalysisButtons`. The previous `Row(Expanded(
              // OutlinedButton) + IconButton)` was vulnerable to the
              // infinite-width crash chain that took down
              // `_inclineAngleRow`: when the Row has two children, the
              // non-flex IconButton receives the Row's `BoxConstraints
              // (maxHeight: ..., maxWidth: Infinity)` cross-axis
              // constraints, and any Material widget inside can blow
              // up. Wrap passes bounded constraints to each child and
              // gracefully falls to a new line on narrow widths.
              Align(
                alignment: Alignment.centerLeft,
                child: Wrap(
                  spacing: 8,
                  runSpacing: 4,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    OutlinedButton.icon(
                      onPressed: cant == null
                          ? null
                          : () {
                              cantSvc.calibrateLevel();
                              ScaffoldMessenger.of(context).showSnackBar(
                                const SnackBar(
                                  content: Text(
                                      'Cant calibration set to current pose.'),
                                  duration: Duration(milliseconds: 1200),
                                ),
                              );
                            },
                      icon: const Icon(Icons.straighten, size: 18),
                      label: const Text('Use phone level'),
                    ),
                    if (cantSvc.calibrationOffsetDeg.abs() > 0.05)
                      IconButton(
                        tooltip: 'Clear calibration',
                        icon: const Icon(Icons.refresh, size: 20),
                        onPressed: cantSvc.clearCalibration,
                      ),
                  ],
                ),
              ),
              const SizedBox(height: 4),
              _cantCorrectionToggle(),
            ],
          ],
        );
      },
    );
  }

  /// Pro-gated toggle: when on, the cant correction is folded into the
  /// displayed firing solution. Free users see a lock chip that opens
  /// the paywall.
  Widget _cantCorrectionToggle() {
    final isPro = context.watch<EntitlementNotifier>().isPro;
    final theme = Theme.of(context);
    if (!isPro) {
      return InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: () => ensurePro(context),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 4),
          child: Row(
            children: [
              Icon(Icons.lock_outline,
                  size: 16, color: theme.colorScheme.primary),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  'Apply cant correction (Pro)',
                  style: theme.textTheme.bodyMedium,
                ),
              ),
              const Icon(Icons.chevron_right, size: 18),
            ],
          ),
        ),
      );
    }
    return SwitchListTile.adaptive(
      contentPadding: EdgeInsets.zero,
      dense: true,
      title: const Text('Apply cant correction'),
      subtitle: const Text(
          'Rotates drop and wind by the live cant angle so the displayed '
          'correction matches your sight picture.'),
      value: _applyCantCorrection,
      onChanged: (v) {
        setState(() => _applyCantCorrection = v);
        _scheduleSolve();
      },
    );
  }

  /// Live magnetometer (heading) row: readout + "Use as shot azimuth"
  /// button. Free-tier feature — the readout is just a sensor read
  /// and the auto-fill is a one-tap convenience.
  Widget _headingRow() {
    final theme = Theme.of(context);
    return Consumer<MagnetometerService>(
      builder: (context, mag, _) {
        final available = mag.isAvailable;
        final heading = mag.headingDegrees;
        final readout = !available
            ? 'Sensor unavailable'
            : (heading == null
                ? '—'
                : '${heading.toStringAsFixed(0)}°  ${_compassLabel(heading)}'
                    '${mag.isTrueNorth ? ' · true' : ' · mag'}');
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Icon(Icons.explore,
                    size: 18, color: theme.colorScheme.primary),
                const SizedBox(width: 8),
                GlossaryLabel(
                  text: 'Heading',
                  glossaryTerm: 'Magnetic declination',
                  style: theme.textTheme.titleSmall,
                ),
                const Spacer(),
                Text(
                  readout,
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontFeatures: const [FontFeature.tabularFigures()],
                    color: available
                        ? theme.colorScheme.onSurface
                        : theme.colorScheme.outline,
                  ),
                ),
              ],
            ),
            if (available) ...[
              const SizedBox(height: 8),
              // Bare button — `_headingRow`'s outer Column has
              // `crossAxisAlignment: stretch`, so the button fills the
              // available width naturally. Dropping the redundant
              // `Row > Expanded` wrapper avoids the brittle pattern
              // where Expanded inside a non-flex Row can crash if any
              // ancestor passes infinite-width constraints.
              OutlinedButton.icon(
                onPressed: heading == null
                    ? null
                    : () {
                        _shotAzimuthCtrl.text =
                            heading.toStringAsFixed(0);
                        _scheduleSolve();
                        _scheduleAutoSave();
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(
                            content: Text(
                                'Shot azimuth set from compass.'),
                            duration: Duration(milliseconds: 1200),
                          ),
                        );
                      },
                icon: const Icon(Icons.explore_outlined, size: 18),
                label: const Text('Use as shot azimuth'),
              ),
              if (!mag.isTrueNorth)
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Text(
                    'Showing magnetic heading. True heading requires a '
                    'magnetic-declination value for your location — set '
                    'one once GPS is available.',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.outline,
                    ),
                  ),
                ),
            ],
          ],
        );
      },
    );
  }

  /// Map a heading in degrees to the closest 8-point compass label.
  String _compassLabel(double deg) {
    const points = [
      'N',
      'NE',
      'E',
      'SE',
      'S',
      'SW',
      'W',
      'NW',
    ];
    final idx = (((deg % 360) + 22.5) ~/ 45) % 8;
    return points[idx];
  }

  // ─────────────────────── Reticle picker ───────────────────────

  Widget _reticlePicker() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ReticlePickerField(
          selected: _selectedReticleRow,
          restrictToOpticId: _selectedFirearm?.opticsId,
          onChanged: (row) {
            if (row == null) {
              setState(() {
                _selectedReticleRow = null;
                _selectedReticle = null;
              });
            } else {
              final repo = context.read<ReticleRepository>();
              setState(() {
                _selectedReticleRow = row;
                _selectedReticle = repo.definitionFromRow(row);
              });
            }
            _scheduleAutoSave();
          },
        ),
        // Inline favorite-star toggle for the picked reticle. Lives
        // outside the ReticlePickerField widget itself because that
        // widget is shared with the firearm form / future surfaces
        // and is owned by the parallel reticle-picker agent. We
        // surface the affordance here in Range Day so a user who
        // finds their preferred reticle at the range can star it
        // and have new sessions default to it (see
        // [_seedDefaultsFromFavoritesIfPresent]).
        if (_selectedReticleRow != null)
          _selectedReticleFavoriteRow(_selectedReticleRow!),
      ],
    );
  }

  /// Compact "Currently selected: `reticle name`  [star]" row that
  /// hangs beneath the [ReticlePickerField]. Watches the
  /// `kFavoriteReticle` set so the star reflects the live state of
  /// `UserFavorites` even after the user toggles it elsewhere
  /// (e.g. SAAMI screen, firearm form). Stays out of the picker
  /// widget itself because that widget is owned by the parallel
  /// agent — see [_reticlePicker].
  Widget _selectedReticleFavoriteRow(ReticleRow row) {
    final theme = Theme.of(context);
    final favoritesRepo = context.read<FavoritesRepository>();
    return StreamBuilder<Set<int>>(
      stream: favoritesRepo.watchFavoriteIds(kFavoriteReticle),
      initialData: const <int>{},
      builder: (context, snap) {
        final favIds = snap.data ?? const <int>{};
        final isFav = favIds.contains(row.id);
        return Padding(
          padding: const EdgeInsets.only(top: 6),
          child: Row(
            children: [
              Icon(Icons.crop_free_outlined,
                  size: 16, color: theme.colorScheme.onSurfaceVariant),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  '${row.manufacturerId} ${row.model}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
              FavoriteStarButton(
                isFavorite: isFav,
                compact: true,
                onToggle: () async {
                  await favoritesRepo.toggleFavorite(
                      kFavoriteReticle, row.id);
                },
              ),
            ],
          ),
        );
      },
    );
  }

  // ─────────────────────── Shooter capability inputs ───────────────────────

  Widget _capabilityExpander() {
    final theme = Theme.of(context);
    return Container(
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          InkWell(
            onTap: () => setState(
                () => _capabilityExpanded = !_capabilityExpanded),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 10, 8, 10),
              child: Row(
                children: [
                  Icon(Icons.precision_manufacturing,
                      size: 18, color: theme.colorScheme.primary),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'Shooter capability',
                      style: theme.textTheme.titleSmall,
                    ),
                  ),
                  Text(
                    '${_assumedGroupMoa.toStringAsFixed(1)} MOA',
                    style: theme.textTheme.bodySmall,
                  ),
                  Icon(
                    _capabilityExpanded
                        ? Icons.expand_less
                        : Icons.expand_more,
                  ),
                ],
              ),
            ),
          ),
          if (_capabilityExpanded)
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _capabilityNumberField(
                    controller: _capabilityGroupMoaCtrl,
                    label: 'Group at 100 yd',
                    suffix: 'MOA',
                    onChanged: (v) {
                      setState(() => _assumedGroupMoa = v);
                      _scheduleHitProb();
                      _scheduleAutoSave();
                    },
                  ),
                  const SizedBox(height: 8),
                  _capabilityNumberField(
                    controller: _capabilityWindUncertaintyCtrl,
                    label: 'Wind uncertainty',
                    suffix: '± mph',
                    onChanged: (v) {
                      setState(() => _windUncertaintyMph = v);
                      _scheduleHitProb();
                      _scheduleAutoSave();
                    },
                  ),
                  const SizedBox(height: 8),
                  _capabilityNumberField(
                    controller: _capabilityRangeUncertaintyCtrl,
                    label: 'Range uncertainty',
                    suffix: '± yd',
                    onChanged: (v) {
                      setState(() => _rangeUncertaintyYd = v);
                      _scheduleHitProb();
                      _scheduleAutoSave();
                    },
                  ),
                  const SizedBox(height: 6),
                  Text(
                    'These values drive the hit-probability gauge — '
                    'tighten group & wind to see your odds climb.',
                    style: theme.textTheme.bodySmall,
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  /// Renders a single Shooter Capability number-input row.
  ///
  /// WHY a passed-in controller: a previous version allocated a fresh
  /// `TextEditingController` inside this helper on every build, which
  /// leaked controllers and broke setState-driven re-seeding (the field
  /// would snap back to its old text whenever an unrelated rebuild
  /// fired between keystrokes). Owning the controllers in State and
  /// disposing them in `dispose()` is the canonical Flutter pattern;
  /// this helper is now a thin renderer.
  Widget _capabilityNumberField({
    required TextEditingController controller,
    required String label,
    required String suffix,
    required void Function(double) onChanged,
  }) {
    final glossaryHint = _capabilityGlossaryHintFor(label);
    return TextField(
      controller: controller,
      keyboardType:
          const TextInputType.numberWithOptions(decimal: true),
      decoration: InputDecoration(
        border: const OutlineInputBorder(),
        // `label:` Widget instead of `labelText:` String so the
        // GlossaryLabel can show the (?) tap-to-define affordance.
        label: GlossaryLabel(
          text: label,
          glossaryTerm: glossaryHint,
        ),
        suffixText: suffix,
        isDense: true,
      ),
      onChanged: (s) {
        final v = double.tryParse(s.trim());
        if (v != null && v >= 0) onChanged(v);
      },
    );
  }

  /// Map group-stats row labels ("ES", "Mean R") to glossary entries.
  String? _groupStatGlossaryHintFor(String label) {
    switch (label) {
      case 'ES':
        return 'Extreme Spread';
      case 'Mean R':
        return 'Mean radius';
      case 'Group':
        return 'Group';
      default:
        return null;
    }
  }

  /// Map shooter-capability labels ("Group at 100 yd") to the
  /// canonical glossary term name. Returns null when the visible
  /// label and the glossary entry name are already equal.
  String? _capabilityGlossaryHintFor(String label) {
    switch (label) {
      case 'Group at 100 yd':
        return 'Group MOA';
      case 'Wind uncertainty':
        return 'Wind uncertainty';
      case 'Range uncertainty':
        return 'Range uncertainty';
      default:
        return null;
    }
  }

  Widget _targetPicker() {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('Target', style: theme.textTheme.labelLarge),
        const SizedBox(height: 6),
        // Single vs Rack mode toggle. Default Single (no behavior
        // change for existing users). Wrapped in Align(centerLeft) so
        // the parent `Column(crossAxisAlignment: stretch)` doesn't
        // force the SegmentedButton to fill the full row — same
        // infinite-width avoidance pattern as the chip Wrap below.
        Align(
          alignment: Alignment.centerLeft,
          child: SegmentedButton<_TargetPickerMode>(
            segments: const [
              ButtonSegment<_TargetPickerMode>(
                value: _TargetPickerMode.single,
                label: Text('Single'),
                icon: Icon(Icons.crop_square, size: 16),
              ),
              ButtonSegment<_TargetPickerMode>(
                value: _TargetPickerMode.rack,
                label: Text('Rack'),
                icon: Icon(Icons.view_column, size: 16),
              ),
            ],
            selected: {_targetPickerMode},
            showSelectedIcon: false,
            onSelectionChanged: (sel) {
              final mode = sel.first;
              if (mode == _targetPickerMode) return;
              setState(() {
                _targetPickerMode = mode;
                // Switching away from rack mode releases the rack
                // selection so downstream geometry consumers fall
                // back to `_selectedTarget`. Switching INTO rack mode
                // releases the single-target selection so the two
                // are mutually exclusive at all times.
                if (mode == _TargetPickerMode.single) {
                  _selectedRack = null;
                  _selectedRackChildren = const [];
                  _selectedRackChildPosition = 0;
                  _rackChildrenError = null;
                } else {
                  _selectedTarget = null;
                }
              });
              _scheduleSolve();
              _scheduleAutoSave();
            },
          ),
        ),
        const SizedBox(height: 8),
        if (_targetPickerMode == _TargetPickerMode.single)
          _singleTargetPickerBody()
        else
          _rackTargetPickerBody(),
      ],
    );
  }

  /// Single-target half of the picker — preserves the existing
  /// category-chip-filtered dropdown UX. Extracted from `_targetPicker`
  /// so the Single/Rack toggle can swap between the two bodies without
  /// duplicating the FutureBuilder + stale-id-guard scaffolding.
  Widget _singleTargetPickerBody() {
    final categories = ['all', 'paper', 'steel', 'reactive', 'game-silhouette'];
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Align(centerLeft) to prevent the parent
        // `Column(crossAxisAlignment: stretch)` from forcing infinite
        // width onto the Wrap, which Material chips would propagate to
        // their internal `_RenderInputPadding` and assert against. Same
        // pattern as `_litzAnalysisButtons`.
        Align(
          alignment: Alignment.centerLeft,
          child: Wrap(
            spacing: 6,
            children: [
              for (final cat in categories)
                ChoiceChip(
                  label: Text(cat == 'all'
                      ? 'All'
                      : cat == 'game-silhouette'
                          ? 'Game'
                          : cat[0].toUpperCase() + cat.substring(1)),
                  selected: _targetCategoryFilter == cat,
                  onSelected: (v) {
                    if (!v) return;
                    setState(() => _targetCategoryFilter = cat);
                  },
                ),
            ],
          ),
        ),
        const SizedBox(height: 8),
        // Outer StreamBuilder watches the favorited target id set so
        // every favorite/unfavorite tap re-sorts the dropdown without
        // a manual setState. The inner FutureBuilder loads the actual
        // catalog rows (one-shot, since the seed catalog doesn't
        // mutate at runtime). The two combine in
        // `_buildTargetDropdown` below.
        StreamBuilder<Set<int>>(
          stream: _targetFavoriteIdsStream,
          initialData: const <int>{},
          builder: (context, favSnap) {
            final favIds = favSnap.data ?? const <int>{};
            return FutureBuilder<List<TargetRow>>(
              future: _targetsFuture,
              builder: (context, snap) {
                if (snap.hasError) {
                  return RangeDayInlineError(
                    message: 'Could not load targets: ${snap.error}',
                    onRetry: () {
                      setState(() {
                        _targetsFuture =
                            context.read<TargetRepository>().allTargets();
                      });
                    },
                  );
                }
                if (snap.connectionState == ConnectionState.waiting) {
                  return const LinearProgressIndicator();
                }
                final all = snap.data ?? const <TargetRow>[];
                return _buildTargetDropdown(theme, all, favIds);
              },
            );
          },
        ),
      ],
    );
  }

  /// Body of the single-target dropdown — split out from
  /// [_singleTargetPickerBody] so the FutureBuilder + StreamBuilder
  /// nesting up there stays readable. Receives the loaded `all`
  /// catalog plus the live `favIds` set, applies the category
  /// filter, sorts favorites first (preserving the existing
  /// natural-sort within each tier), and renders the dropdown +
  /// preview tile + inline favorite-star toggle + color swatch row.
  ///
  /// Favorited rows are surfaced two ways: they sort to the top of
  /// the dropdown menu, AND they get a `★ ` prefix glyph on the
  /// menu-item label so the user can tell what's favorited even
  /// while scrolling through the list. There's no inline-tap-to-
  /// favorite inside the dropdown items themselves —
  /// `DropdownMenuItem` doesn't render trailing actions cleanly —
  /// so the per-target favorite toggle lives next to the selected-
  /// target preview tile below the dropdown instead. That trades a
  /// click off (the user has to pick the row first, then tap the
  /// star) against not breaking the dropdown's tap target.
  Widget _buildTargetDropdown(
    ThemeData theme,
    List<TargetRow> all,
    Set<int> favIds,
  ) {
    final filtered = _targetCategoryFilter == 'all'
        ? all
        : all.where((t) => t.category == _targetCategoryFilter).toList();
    // Favorite-first sort. We deliberately stable-sort: the
    // existing natural-name order from `TargetRepository.allTargets`
    // is preserved within each tier (favorites then non-favorites),
    // so picking the same target twice in a row doesn't move the
    // dropdown's other rows around.
    final orderedFiltered = _sortFavoritesFirst<TargetRow>(
      filtered,
      (t) => favIds.contains(t.id),
    );
    // Build the dropdown items, always including the currently-
    // selected target even when the category filter would hide
    // it.
    //
    // Without this guard, the dropdown crashes the screen when
    // the user picks a target in one category, then switches
    // the category-filter chips: `initialValue` becomes a
    // stale id not present in `items`, and Flutter's
    // `DropdownButtonFormField` asserts "There should be
    // exactly one item with [DropdownButton]'s value: <id>"
    // (Either zero or 2 or more) at layout time.
    //
    // The fix: keep `_selectedTarget` as a stable piece of
    // state regardless of the filter, and inject it into the
    // items list with a clarifying "(picked — hidden by
    // filter)" suffix when the active filter would otherwise
    // exclude it. The user's selection is preserved across
    // filter taps and they always see what they have chosen.
    //
    // The same Stale-id guard pattern protects against a
    // saved-session `_selectedTarget.id` that's no longer in
    // the catalog after a re-seed: collapse to null so
    // Flutter's "exactly one item with this value" assertion
    // is satisfied.
    final selected = _selectedTarget;
    final stillInCatalog =
        selected != null && all.any((t) => t.id == selected.id);
    final selectedHiddenByFilter = selected != null &&
        stillInCatalog &&
        !filtered.any((t) => t.id == selected.id);
    final items = <DropdownMenuItem<int?>>[
      const DropdownMenuItem<int?>(
        value: null,
        child: Text('— None —'),
      ),
      if (selectedHiddenByFilter)
        DropdownMenuItem<int?>(
          value: selected.id,
          child: Text(
            '${favIds.contains(selected.id) ? '★ ' : ''}'
            '${selected.name} (picked — hidden by filter)',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ...orderedFiltered.map((t) => DropdownMenuItem<int?>(
            value: t.id,
            child: Text(
              favIds.contains(t.id) ? '★ ${t.name}' : t.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          )),
    ];
    if (filtered.isEmpty && !selectedHiddenByFilter) {
      return Text(
        'No targets in this category yet.',
        style: theme.textTheme.bodySmall,
      );
    }
    final dropdownValue =
        (selected != null && stillInCatalog) ? selected.id : null;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        DropdownButtonFormField<int?>(
          initialValue: dropdownValue,
          isExpanded: true,
          decoration: const InputDecoration(
            border: OutlineInputBorder(),
            hintText: 'Pick a target',
          ),
          items: items,
          onChanged: (id) {
            if (id == null) {
              setState(() => _selectedTarget = null);
              _scheduleAutoSave();
              return;
            }
            // Look up against the union of (filtered + currently
            // selected) so picking the "(picked — hidden by
            // filter)" pseudo-item is a no-op rather than a
            // `StateError` from `firstWhere`.
            final picked = filtered.firstWhere(
              (t) => t.id == id,
              orElse: () => selected!,
            );
            setState(() => _selectedTarget = picked);
            _scheduleAutoSave();
          },
        ),
        // Preview tile — the user reported they couldn't tell
        // what target they had selected after picking from the
        // dropdown. This row mirrors the selection back to them
        // with the target's shape, name, and dimensions so it's
        // unambiguous before they scroll down to see the
        // computed solution.
        //
        // Trailing slot now also carries a [FavoriteStarButton] so
        // the user can star / unstar the picked target without
        // round-tripping to a different screen. Toggle is wired
        // through [FavoritesRepository] (the join table, not the
        // row) because targets ship as seeded reference data.
        if (selected != null && stillInCatalog)
          _selectedTargetPreview(selected, favIds),
        // Color swatch row — five circular tappable swatches.
        // Tapping one writes `_selectedTargetColorHex`, which
        // overrides the target's natural color in the
        // TargetPlot painters via `colorHexOverride`. Null
        // means "use the target's natural colorHex".
        _targetColorSwatchRow(),
      ],
    );
  }

  /// Stable favorite-first sort. Returns a new list with rows
  /// where `isFav(row)` is true coming first (in their original
  /// order), followed by non-favorites (also in their original
  /// order). Used by every Range Day picker to surface starred
  /// rows at the top of the menu without disturbing the
  /// repository's natural-name sort within each tier.
  List<T> _sortFavoritesFirst<T>(
    List<T> items,
    bool Function(T) isFav,
  ) {
    final favorites = <T>[];
    final others = <T>[];
    for (final item in items) {
      if (isFav(item)) {
        favorites.add(item);
      } else {
        others.add(item);
      }
    }
    return [...favorites, ...others];
  }

  /// Five-color target tint palette. Locked to the colors a real
  /// range target most often takes: white paper (default), orange
  /// reactive paint, brown cardboard / silhouette, yellow steel
  /// reactive, red plate. Replaced the earlier white/yellow/orange/
  /// red/black set on user feedback — black silhouettes are rendered
  /// via the silhouette `shape`, not via tint, so a "black" swatch
  /// was redundant. Brown covers the cardboard IPSC / IDPA case the
  /// old palette missed.
  static const List<String> _kTargetColorSwatches = [
    '#ffffff', // white (default)
    '#ff7700', // orange
    '#8b5a2b', // brown (cardboard)
    '#ffeb00', // yellow
    '#cc1f1f', // red
  ];

  /// Five circular tappable color swatches in a `Wrap` (so a narrow
  /// device wraps gracefully instead of overflowing). The active
  /// swatch — when `_selectedTargetColorHex` matches — gets a thin
  /// gold border. A "Reset" affordance is offered as a sixth subtle
  /// chip on the right when an override is active, returning to the
  /// target's natural color.
  Widget _targetColorSwatchRow() {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(top: 10),
      child: Align(
        alignment: Alignment.centerLeft,
        child: Wrap(
          spacing: 8,
          runSpacing: 6,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            for (final hex in _kTargetColorSwatches)
              _targetColorSwatchButton(hex),
            if (_selectedTargetColorHex != null)
              TextButton(
                onPressed: () {
                  setState(() => _selectedTargetColorHex = null);
                  _scheduleAutoSave();
                },
                style: TextButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                  textStyle: theme.textTheme.bodySmall,
                ),
                child: const Text('Reset'),
              ),
          ],
        ),
      ),
    );
  }

  /// Single circular swatch. Active swatch = thicker gold border + a
  /// check glyph for accessibility (color-blind users still see which
  /// is selected without relying on the border alone).
  Widget _targetColorSwatchButton(String hex) {
    final theme = Theme.of(context);
    final selected = _selectedTargetColorHex == hex;
    Color parse(String h) {
      final raw = h.startsWith('#') ? h.substring(1) : h;
      final v = int.parse(raw, radix: 16);
      return Color(0xff000000 | v);
    }
    final fill = parse(hex);
    // Pick a contrast color for the check glyph based on perceived
    // luminance — white-on-light or black-on-dark would be invisible.
    final luminance = fill.computeLuminance();
    final checkColor = luminance > 0.5 ? Colors.black : Colors.white;
    return Semantics(
      label: 'Target color swatch $hex',
      button: true,
      selected: selected,
      child: InkWell(
        borderRadius: BorderRadius.circular(28),
        onTap: () {
          setState(() => _selectedTargetColorHex = hex);
          _scheduleAutoSave();
        },
        child: Container(
          width: 36,
          height: 36,
          decoration: BoxDecoration(
            color: fill,
            shape: BoxShape.circle,
            border: Border.all(
              color: selected
                  ? theme.colorScheme.primary
                  : theme.colorScheme.outlineVariant,
              width: selected ? 3 : 1,
            ),
          ),
          child: selected
              ? Icon(Icons.check, size: 18, color: checkColor)
              : null,
        ),
      ),
    );
  }

  /// Rack half of the picker — a rack dropdown plus a chip row for
  /// switching the active child within the picked rack. The rack list
  /// comes from `_racksFuture` (loaded once in `initState`) so a slow
  /// SQLite read can't block the screen.
  ///
  /// On error in the rack dropdown we render a `RangeDayInlineError`
  /// with retry; on error loading children we show an inline message
  /// inside the picker card (per the soft-failure contract).
  Widget _rackTargetPickerBody() {
    final theme = Theme.of(context);
    return FutureBuilder<List<TargetRackRow>>(
      future: _racksFuture,
      builder: (context, snap) {
        if (snap.hasError) {
          return RangeDayInlineError(
            message: 'Could not load target racks: ${snap.error}',
            onRetry: () {
              setState(() {
                _racksFuture =
                    context.read<TargetRepository>().allRacks();
              });
            },
          );
        }
        if (snap.connectionState == ConnectionState.waiting) {
          return const LinearProgressIndicator();
        }
        final racks = snap.data ?? const <TargetRackRow>[];
        if (racks.isEmpty) {
          return Text(
            'No racks in the catalog yet.',
            style: theme.textTheme.bodySmall,
          );
        }
        // Stale-id guard — same pattern as the single-target dropdown.
        // If `_selectedRack`'s id is no longer in the catalog (e.g. a
        // re-seed dropped it between sessions), present null to the
        // dropdown so Flutter doesn't assert "exactly one item with
        // value: <id>". The user can re-pick from the now-fresh list.
        final selectedRack = _selectedRack;
        final rackStillInCatalog =
            selectedRack != null && racks.any((r) => r.id == selectedRack.id);
        final dropdownValue =
            (selectedRack != null && rackStillInCatalog) ? selectedRack.id : null;
        final items = <DropdownMenuItem<int?>>[
          const DropdownMenuItem<int?>(
            value: null,
            child: Text('— None —'),
          ),
          ...racks.map((r) => DropdownMenuItem<int?>(
                value: r.id,
                child: Text(
                  '${r.name} · ${_rackKindLabel(r.rackKind)}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              )),
        ];
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            DropdownButtonFormField<int?>(
              initialValue: dropdownValue,
              isExpanded: true,
              decoration: const InputDecoration(
                border: OutlineInputBorder(),
                hintText: 'Pick a rack',
              ),
              items: items,
              onChanged: (id) {
                if (id == null) {
                  setState(() {
                    _selectedRack = null;
                    _selectedRackChildren = const [];
                    _selectedRackChildPosition = 0;
                    _rackChildrenError = null;
                  });
                  _scheduleSolve();
                  _scheduleAutoSave();
                  return;
                }
                final picked = racks.firstWhere(
                  (r) => r.id == id,
                  orElse: () => selectedRack!,
                );
                _onRackSelected(picked);
              },
            ),
            // Active-child chip row. Only renders once a rack is
            // picked AND its children have been loaded successfully.
            if (_rackChildrenError != null) ...[
              const SizedBox(height: 8),
              RangeDayInlineError(
                message: _rackChildrenError!,
                onRetry: selectedRack == null
                    ? null
                    : () => _onRackSelected(selectedRack),
              ),
            ] else if (selectedRack != null &&
                rackStillInCatalog &&
                _selectedRackChildren.isNotEmpty) ...[
              const SizedBox(height: 10),
              Text(
                'Active plate',
                style: theme.textTheme.labelSmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 4),
              // Same Align(centerLeft) bulletproofing as the single-
              // target category chips above — the parent
              // `Column.stretch` would otherwise force infinite width
              // onto the Wrap and crash the chip layout.
              Align(
                alignment: Alignment.centerLeft,
                child: Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    for (var i = 0; i < _selectedRackChildren.length; i++)
                      ChoiceChip(
                        label: Text(_rackChildChipLabel(
                          _selectedRackChildren[i],
                          i,
                        )),
                        selected: _selectedRackChildPosition == i,
                        onSelected: (v) {
                          if (!v) return;
                          setState(() => _selectedRackChildPosition = i);
                          _scheduleSolve();
                          _scheduleHitProb();
                          _scheduleAutoSave();
                        },
                      ),
                  ],
                ),
              ),
              _selectedRackPreview(
                selectedRack,
                _selectedRackChildren[_selectedRackChildPosition.clamp(
                  0,
                  _selectedRackChildren.length - 1,
                )],
              ),
            ],
          ],
        );
      },
    );
  }

  /// Triggered when the user picks a different rack from the rack
  /// dropdown. Loads the rack's children eagerly so the chip row can
  /// render immediately. Soft failure: a repository error sets
  /// `_rackChildrenError` so the picker shows an inline retry instead
  /// of crashing the whole screen.
  Future<void> _onRackSelected(TargetRackRow rack) async {
    // Optimistic state update so the dropdown reflects the new pick
    // while the children load. Clear the error so a retry-after-error
    // path doesn't show the previous failure.
    setState(() {
      _selectedRack = rack;
      _selectedTarget = null;
      _selectedRackChildren = const [];
      _selectedRackChildPosition = 0;
      _rackChildrenError = null;
    });
    final children = await safeAsync<List<TargetRackChildRow>>(
      context,
      mounted: () => mounted,
      userMessage: 'Could not load rack children.',
      body: () => context.read<TargetRepository>().childrenOf(rack.id),
    );
    if (!mounted) return;
    if (children == null) {
      setState(() {
        _rackChildrenError = 'Could not load rack children.';
      });
      return;
    }
    setState(() {
      _selectedRackChildren = children;
      _selectedRackChildPosition = 0;
    });
    _scheduleSolve();
    _scheduleHitProb();
    _scheduleAutoSave();
  }

  /// Display label for a rack-kind enum string. Falls back to the raw
  /// string for unknown / future kinds so a stale catalog never throws.
  String _rackKindLabel(String rackKind) {
    switch (rackKind) {
      case 'kyl':
        return 'KYL';
      case 'pepper-popper':
        return 'Pepper Popper';
      case 'plate-rack':
        return 'Plate Rack';
      case 'idpa-stage':
        return 'IDPA Stage';
      case 'custom':
        return 'Custom';
      default:
        return rackKind;
    }
  }

  /// Compact chip label for a rack child — falls back to "Plate N" if
  /// the child's name is empty. Children are seeded with descriptive
  /// names like "Plate 1 (5 in)" so the chip already conveys the
  /// child's size; this helper is just the safety net.
  String _rackChildChipLabel(TargetRackChildRow c, int index) {
    final name = c.name.trim();
    return name.isEmpty ? 'Plate ${index + 1}' : name;
  }

  /// One-line preview row shown directly under the active-child chip
  /// row. Mirrors the visual weight of `_selectedTargetPreview` so the
  /// user gets the same kind of "you picked this" confirmation in
  /// rack mode that they get in single-target mode. Reads, e.g.,
  /// "5-Plate KYL · Active: Plate 3 (3 in dia)".
  Widget _selectedRackPreview(TargetRackRow rack, TargetRackChildRow active) {
    final theme = Theme.of(context);
    final dims = _rackChildDimensionLabel(active);
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Container(
        decoration: BoxDecoration(
          color: theme.colorScheme.surfaceContainerHighest.withValues(
            alpha: 0.4,
          ),
          borderRadius: BorderRadius.circular(8),
        ),
        padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
        child: Row(
          children: [
            _targetShapeIcon(active.shape, theme),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    rack.name,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 2),
                  Text(
                    'Active: ${active.name} ($dims)',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Dimension label for a rack child. Mirrors `_targetDimensionLabel`
  /// so the rack-active preview reads the same way as the single-
  /// target preview.
  String _rackChildDimensionLabel(TargetRackChildRow c) {
    final w = c.widthIn;
    final h = c.heightIn;
    String fmt(double v) =>
        v == v.roundToDouble() ? v.toStringAsFixed(0) : v.toStringAsFixed(1);
    if (c.shape == 'circle') {
      return '${fmt(w)} in dia';
    }
    if (w == h) {
      return '${fmt(w)} × ${fmt(w)} in';
    }
    return '${fmt(w)} × ${fmt(h)} in';
  }

  // ─────────────────────── Active-target geometry helpers ───────────────────────
  //
  // Downstream consumers (the ballistics solver, the hit-probability
  // service, the Target Plot widget, the group-stats math, the
  // post-shot correction card, the in-app summary strings) all want
  // "the geometry of the thing the shooter is actually aiming at."
  // When a single target is picked, that's `_selectedTarget`. When a
  // rack is picked, it's the active child of the rack. These helpers
  // collapse that branching into a single source of truth so callers
  // don't have to repeat the if/else everywhere.

  /// True iff the user is currently in rack mode AND has picked a rack
  /// AND its children have loaded. Use this to decide whether to read
  /// from `_activeRackChild` or fall back to `_selectedTarget`.
  bool get _hasActiveRack =>
      _selectedRack != null && _selectedRackChildren.isNotEmpty;

  /// The active rack child, or null if no rack is in play. Always
  /// guarded by [_hasActiveRack] in callers — accessing this when the
  /// list is empty would throw.
  TargetRackChildRow? get _activeRackChild {
    if (!_hasActiveRack) return null;
    final i = _selectedRackChildPosition.clamp(
      0,
      _selectedRackChildren.length - 1,
    );
    return _selectedRackChildren[i];
  }

  /// Active target width in inches, or null if no target / rack is
  /// selected. Returns the rack child's width when a rack is active,
  /// else the single target's width.
  double? get _activeTargetWidthIn {
    final child = _activeRackChild;
    if (child != null) return child.widthIn;
    return _selectedTarget?.widthIn;
  }

  /// Active target height in inches, or null if no target / rack is
  /// selected. Returns the rack child's height when a rack is active,
  /// else the single target's height.
  double? get _activeTargetHeightIn {
    final child = _activeRackChild;
    if (child != null) return child.heightIn;
    return _selectedTarget?.heightIn;
  }

  /// Active target shape string ('circle' | 'square' | 'rectangle' |
  /// 'silhouette' | 'irregular'), or null if no target / rack is
  /// selected.
  String? get _activeTargetShape {
    final child = _activeRackChild;
    if (child != null) return child.shape;
    return _selectedTarget?.shape;
  }

  /// Display name of the active aim point — the rack name + active-
  /// child name when a rack is active, else the single target name.
  /// Used by status strips and summary strings.
  String? get _activeTargetDisplayName {
    final child = _activeRackChild;
    if (child != null) return '${_selectedRack!.name} · ${child.name}';
    return _selectedTarget?.name;
  }

  /// True if any kind of target is selected — either a single target
  /// or a rack with at least one loaded child. Use this anywhere the
  /// pre-rack code checked `_selectedTarget != null` and would also
  /// want to accept rack mode.
  ///
  /// Currently no caller branches on "is anything selected" — every
  /// downstream consumer prefers the typed helpers above
  /// (`_activeTargetWidthIn`, `_activeTargetSpec`, etc.) which return
  /// nullable values directly. Kept as a documented helper so future
  /// callers (e.g. an "Add target" empty-state CTA) don't have to
  /// re-derive the rack/single discriminator.
  // ignore: unused_element
  bool get _hasActiveTarget =>
      _selectedTarget != null || _hasActiveRack;

  /// When a rack is active, build the [RackChildSpec] list the
  /// realistic-mode `TargetPlot` needs to render the rack hanging
  /// from chains. Returns null when no rack is active so the
  /// realistic painter falls back to single-target-on-pole.
  ///
  /// `offsetXFromCenterIn` is sourced from `TargetRackChildRow.offsetXIn`,
  /// which is the rack's intended geometric layout in inches relative
  /// to the rack's center. Children with negative offsets render to
  /// the left of center; positive to the right. The realistic
  /// painter divides this by the rack's spread to position children
  /// across the canvas.
  List<RackChildSpec>? get _rackChildrenSpec {
    if (!_hasActiveRack) return null;
    return _selectedRackChildren
        .map((c) => RackChildSpec(
              widthIn: c.widthIn,
              heightIn: c.heightIn,
              shape: c.shape,
              offsetXFromCenterIn: c.offsetXIn,
              colorHex: c.colorHex,
            ))
        .toList();
  }

  /// 0-indexed position of the active rack child, or null when no
  /// rack is active. The realistic painter highlights this child
  /// (full opacity + bolder outline) and renders the others at 70%
  /// opacity.
  int? get _activeRackChildIndex =>
      _hasActiveRack ? _selectedRackChildPosition : null;

  /// Build a [TargetSpec] from the current active aim point so the
  /// [TargetPlot] widget can render whichever geometry is in play
  /// without rack-aware code. Returns null when nothing is selected.
  TargetSpec? get _activeTargetSpec {
    final child = _activeRackChild;
    if (child != null) {
      return TargetSpec(
        shape: child.shape,
        widthIn: child.widthIn,
        heightIn: child.heightIn,
        colorHex: child.colorHex,
      );
    }
    if (_selectedTarget != null) {
      return TargetSpec.fromRow(_selectedTarget!);
    }
    return null;
  }

  /// Inline preview row shown directly under the target dropdown.
  ///
  /// Shows shape icon + name + dimensions + category. The whole row
  /// stays within the Setup card — it's intentionally compact (no
  /// elevation, no card chrome) so it reads as a confirmation of the
  /// dropdown selection rather than a distinct widget.
  /// Mirrors the picked single target back to the user with shape +
  /// dimensions + an inline favorite-star toggle. The `favIds` set
  /// is passed in so the star reflects the live state of the
  /// `UserFavorites` join table without this widget needing its
  /// own subscription.
  Widget _selectedTargetPreview(TargetRow t, Set<int> favIds) {
    final theme = Theme.of(context);
    final dims = _targetDimensionLabel(t);
    final categoryLabel = t.category == 'game-silhouette'
        ? 'Game'
        : (t.category[0].toUpperCase() + t.category.substring(1));
    final isFav = favIds.contains(t.id);
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Container(
        decoration: BoxDecoration(
          color: theme.colorScheme.surfaceContainerHighest.withValues(
            alpha: 0.4,
          ),
          borderRadius: BorderRadius.circular(8),
        ),
        padding: const EdgeInsets.fromLTRB(10, 4, 4, 4),
        child: Row(
          children: [
            _targetShapeIcon(t.shape, theme),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    t.name,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 2),
                  Text(
                    '$dims · $categoryLabel',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
            FavoriteStarButton(
              isFavorite: isFav,
              compact: true,
              onToggle: () async {
                final repo = context.read<FavoritesRepository>();
                await repo.toggleFavorite(kFavoriteTarget, t.id);
              },
            ),
          ],
        ),
      ),
    );
  }

  /// Dimension label for the preview row.
  ///
  /// Circles read "10 in dia" (single dimension is enough); rectangles
  /// and squares read "W × H in"; silhouettes use "W × H in"; if the
  /// target shape is unknown, we fall back to the raw width × height.
  String _targetDimensionLabel(TargetRow t) {
    final w = t.widthIn;
    final h = t.heightIn;
    String fmt(double v) =>
        v == v.roundToDouble() ? v.toStringAsFixed(0) : v.toStringAsFixed(1);
    if (t.shape == 'circle') {
      return '${fmt(w)} in dia';
    }
    if (w == h) {
      return '${fmt(w)} × ${fmt(w)} in';
    }
    return '${fmt(w)} × ${fmt(h)} in';
  }

  /// Small inline shape glyph for the preview row.
  ///
  /// We don't try to render a fancy thumbnail here — the Range Day
  /// target plot already shows the actual target geometry once the
  /// user has set distance + scale. This is just a visual anchor
  /// (circle / square / rectangle / silhouette) so the user knows at
  /// a glance the shape they picked.
  Widget _targetShapeIcon(String shape, ThemeData theme) {
    final color = theme.colorScheme.primary;
    switch (shape) {
      case 'circle':
        return Container(
          width: 28,
          height: 28,
          decoration: BoxDecoration(
            border: Border.all(color: color, width: 2),
            shape: BoxShape.circle,
          ),
        );
      case 'square':
      case 'rectangle':
        return Container(
          width: 28,
          height: 28,
          decoration: BoxDecoration(
            border: Border.all(color: color, width: 2),
            borderRadius: BorderRadius.circular(2),
          ),
        );
      case 'silhouette':
      case 'irregular':
        return Icon(Icons.person_outline, size: 28, color: color);
      default:
        return Icon(Icons.crop_square, size: 28, color: color);
    }
  }

  Widget _distancePicker() {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Align(
          alignment: Alignment.centerLeft,
          child: GlossaryLabel(
            text: 'Distance (yd)',
            glossaryTerm: 'Distance',
            style: theme.textTheme.labelLarge,
          ),
        ),
        const SizedBox(height: 6),
        Row(
          children: [
            Expanded(
              flex: 2,
              child: TextField(
                controller: _distanceCtrl,
                keyboardType: const TextInputType.numberWithOptions(),
                inputFormatters: [
                  FilteringTextInputFormatter.allow(RegExp(r'\d')),
                ],
                decoration: const InputDecoration(
                  border: OutlineInputBorder(),
                  isDense: true,
                  suffixText: 'yd',
                ),
                onChanged: (_) {
                  _scheduleSolve();
                  _scheduleAutoSave();
                },
              ),
            ),
            Expanded(
              flex: 5,
              child: Slider(
                value: (double.tryParse(_distanceCtrl.text) ?? 100)
                    .clamp(50, 2000)
                    .toDouble(),
                min: 50,
                max: 2000,
                divisions: (2000 - 50) ~/ 25,
                label: _distanceCtrl.text,
                onChanged: (v) {
                  setState(() {
                    _distanceCtrl.text = v.round().toString();
                  });
                  _scheduleSolve();
                },
                onChangeEnd: (_) => _scheduleAutoSave(),
              ),
            ),
          ],
        ),
        const SizedBox(height: 4),
        // Same Align(centerLeft) bulletproofing as the ChoiceChip Wrap
        // above and `_litzAnalysisButtons` — protects against parent
        // `Column.stretch` forcing infinite width onto chip children.
        Align(
          alignment: Alignment.centerLeft,
          child: Wrap(
            spacing: 6,
            children: [
              for (final yd in const [100, 200, 300, 500, 1000])
                ActionChip(
                  label: Text('$yd'),
                  onPressed: () {
                    setState(() {
                      _distanceCtrl.text = yd.toString();
                    });
                    _scheduleSolve();
                    _scheduleAutoSave();
                  },
                ),
            ],
          ),
        ),
        _rangefinderQuickFill(),
      ],
    );
  }

  /// "Use last reading" affordance — if any of the five supported BLE
  /// rangefinder adapters is connected and has a recent measurement,
  /// surface a button to drop that value into the distance input.
  ///
  /// Picks the freshest reading across all connected rangefinders so a
  /// user with two paired devices still gets a sensible default. Hidden
  /// entirely when no rangefinder is connected — the picker has plenty
  /// of clutter without an always-on disabled button.
  ///
  /// When the freshest reading is from a device that publishes a
  /// magnetic azimuth (currently Vectronix Terrapin X only), the button
  /// label switches to "Use distance + azimuth" and a single tap fills
  /// in distance, incline-corrected range, AND the shot azimuth field.
  /// This is the integration's headline feature versus the other four
  /// rangefinders which only publish LOS / incline.
  Widget _rangefinderQuickFill() {
    final theme = Theme.of(context);
    final candidates = <_RangefinderCandidate>[
      _RangefinderCandidate(
        label: 'Sig KILO',
        reading: context.watch<SigKiloService>().lastReading,
      ),
      _RangefinderCandidate(
        label: 'Bushnell',
        reading: context.watch<BushnellRangefinderService>().lastReading,
      ),
      _RangefinderCandidate(
        label: 'Vortex',
        reading: context.watch<VortexRangefinderService>().lastReading,
      ),
      _RangefinderCandidate(
        label: 'Leica',
        reading: context.watch<LeicaGeovidService>().lastReading,
      ),
      _RangefinderCandidate(
        label: 'Vectronix Terrapin X',
        reading: context.watch<VectronixTerrapinService>().lastReading,
      ),
    ].where((c) => c.reading != null).toList()
      ..sort((a, b) =>
          b.reading!.receivedAt.compareTo(a.reading!.receivedAt));
    if (candidates.isEmpty) return const SizedBox.shrink();
    final freshest = candidates.first;
    final r = freshest.reading!;
    // Prefer the incline-corrected ("shoot-to") range when the device
    // computed it; fall back to the line-of-sight range otherwise. The
    // ballistics solver wants the actual horizontal distance to the
    // target, which the shoot-to value approximates.
    final yards = r.inclineCorrectedRangeYd ?? r.rangeYd;
    final freshenSeconds =
        DateTime.now().difference(r.receivedAt).inSeconds;
    final freshLabel = freshenSeconds < 60
        ? '${freshenSeconds}s ago'
        : '${(freshenSeconds / 60).round()} min ago';
    // Compose the readout line. When the device gave us a compass
    // bearing (Vectronix Terrapin X), surface it inline so the user
    // can sanity-check before tapping the combined-fill button.
    final readoutPieces = <String>[
      '${freshest.label}: ${yards.toStringAsFixed(0)} yd',
    ];
    if (r.azimuthDeg != null) {
      readoutPieces.add('${r.azimuthDeg!.toStringAsFixed(0)}°');
    }
    readoutPieces.add(freshLabel);
    final hasAzimuth = r.azimuthDeg != null;
    final buttonLabel = hasAzimuth
        ? 'Use distance + azimuth'
        : 'Use last reading';
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Row(
        children: [
          Icon(
            Icons.gps_fixed,
            size: 16,
            color: theme.colorScheme.primary,
          ),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              readoutPieces.join(' · '),
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          TextButton(
            onPressed: () {
              setState(() {
                _distanceCtrl.text = yards.round().toString();
                if (hasAzimuth) {
                  // Vectronix Terrapin X is the only rangefinder we
                  // support that emits a magnetic azimuth alongside the
                  // distance. Mirror it into the shot azimuth field so
                  // the Coriolis / wind-bearing math has the right
                  // input without a second sensor capture.
                  _shotAzimuthCtrl.text = r.azimuthDeg!.toStringAsFixed(0);
                }
              });
              _scheduleSolve();
              _scheduleAutoSave();
              if (hasAzimuth) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(
                    content: Text(
                      'Distance and shot azimuth set from Vectronix Terrapin X.',
                    ),
                  ),
                );
              }
            },
            child: Text(buttonLabel),
          ),
        ],
      ),
    );
  }

  Widget _profilePicker() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Align(
          alignment: Alignment.centerLeft,
          child: GlossaryLabel(
            text: 'Ballistic profile',
            glossaryTerm: 'DOPE',
            style: Theme.of(context).textTheme.labelLarge,
          ),
        ),
        const SizedBox(height: 6),
        StreamBuilder<List<BallisticProfileRow>>(
          stream: _profilesStream,
          builder: (context, snap) {
            if (snap.hasError) {
              return RangeDayInlineError(
                message:
                    'Could not load ballistic profiles: ${snap.error}',
                onRetry: () {
                  setState(() {
                    _profilesStream =
                        context.read<BallisticProfileRepository>().watchAll();
                  });
                },
              );
            }
            final profiles = snap.data ?? const <BallisticProfileRow>[];
            // Favorite-first sort. `BallisticProfileRow.isFavorite` is
            // a per-row boolean (schema v24), so unlike the target
            // picker we don't need a separate stream — the watch
            // already re-emits whenever the row's `isFavorite` flag
            // flips. Stable sort preserves the existing
            // alphabetical-by-name order within each tier.
            final ordered = _sortFavoritesFirst<BallisticProfileRow>(
              profiles,
              (p) => p.isFavorite,
            );
            // Stale-id guard: if the previously-selected profile has
            // been deleted (or the stream is mid-refresh), pinning
            // `initialValue` to its id would crash the dropdown with
            // "There should be exactly one item with [DropdownButton]'s
            // value: <id>". Fall back to null while keeping
            // `_selectedProfile` as state — the rest of the screen
            // continues to use the cached values until the user picks
            // again or the deleted-row state resolves itself.
            final selectedProfileExists = _selectedProfile != null &&
                profiles.any((p) => p.id == _selectedProfile!.id);
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                DropdownButtonFormField<int?>(
                  initialValue:
                      selectedProfileExists ? _selectedProfile!.id : null,
                  isExpanded: true,
                  decoration: const InputDecoration(
                    border: OutlineInputBorder(),
                    hintText: 'Pick a saved profile',
                  ),
                  items: [
                    const DropdownMenuItem<int?>(
                      value: null,
                      child: Text('— None —'),
                    ),
                    ...ordered.map((p) => DropdownMenuItem<int?>(
                          value: p.id,
                          child: Text(
                            p.isFavorite ? '★ ${p.name}' : p.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        )),
                  ],
                  onChanged: (id) {
                    if (id == null) {
                      setState(() => _selectedProfile = null);
                      return;
                    }
                    final p = profiles.firstWhere((p) => p.id == id);
                    _applyProfile(p);
                    _scheduleAutoSave();
                  },
                ),
                // Inline star toggle for the picked profile. The row
                // already has an `isFavorite` boolean; the live
                // `_profilesStream` re-emits on every flip so the
                // visual stays in sync without an extra subscription.
                if (selectedProfileExists)
                  _selectedProfileFavoriteRow(_selectedProfile!),
              ],
            );
          },
        ),
      ],
    );
  }

  /// Compact "Currently selected: `name`  [star]" row beneath the
  /// profile dropdown. Lets the user star / unstar the picked
  /// profile without leaving the screen. Mirrors the same star
  /// affordance the recipe / firearm pickers expose. Wrapped in a
  /// SafeRow so it doesn't try to expand inside the parent
  /// `Column.stretch` — the inner content uses `Expanded` for the
  /// label, the star button is naturally finite-width.
  Widget _selectedProfileFavoriteRow(BallisticProfileRow p) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Row(
        children: [
          Icon(Icons.bookmark_outline,
              size: 16, color: theme.colorScheme.onSurfaceVariant),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              p.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          FavoriteStarButton(
            isFavorite: p.isFavorite,
            compact: true,
            onToggle: () async {
              final repo = context.read<BallisticProfileRepository>();
              await repo.toggleFavorite(p.id);
            },
          ),
        ],
      ),
    );
  }

  Widget _loadPicker() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('Load', style: Theme.of(context).textTheme.labelLarge),
        const SizedBox(height: 6),
        StreamBuilder<List<UserLoadRow>>(
          stream: _loadsStream,
          builder: (context, snap) {
            if (snap.hasError) {
              return RangeDayInlineError(
                message: 'Could not load recipes: ${snap.error}',
                onRetry: () {
                  setState(() {
                    _loadsStream =
                        context.read<RecipeRepository>().watchAll();
                  });
                },
              );
            }
            final loads = snap.data ?? const <UserLoadRow>[];
            // Brand-new user with zero saved recipes: instead of a
            // dropdown that just says "— None —" (and offers no path
            // forward), surface a real empty-state card with two
            // actions — pick a common factory load to seed defaults,
            // or jump to the full ballistics workflow to build a
            // proper saved profile. See `_applyCommonLoad`,
            // `_pickCommonLoad`, and `_openBallisticsScreen` below
            // for the action handlers.
            if (loads.isEmpty) {
              return _loadPickerEmptyState();
            }
            // Favorite-first sort. `UserLoadRow.isFavorite` (schema
            // v24) is the per-row boolean; the live stream re-emits
            // when it flips so the dropdown re-orders without an
            // explicit setState. Stable sort preserves the
            // newest-edited-first ordering inside each tier.
            final orderedLoads = _sortFavoritesFirst<UserLoadRow>(
              loads,
              (l) => l.isFavorite,
            );
            // Stale-id guard — see `_profilePicker` for the rationale.
            // Protects against the user deleting a recipe while a Range
            // Day session still references it (or the recipe stream
            // re-firing with a smaller list mid-render).
            final selectedLoadExists = _selectedLoad != null &&
                loads.any((l) => l.id == _selectedLoad!.id);
            // Pick the picker's hint copy: when the user previously
            // applied a common-load default the dropdown is still
            // empty (no DB row), but we want to surface that the
            // current ballistics inputs came from a canned load.
            final hintText = _appliedCommonLoadName != null
                ? 'Using $_appliedCommonLoadName defaults'
                : 'Optional — link a recipe';
            // Re-resolve the selected row from the latest stream
            // emission so the inline favorite-star reflects the
            // up-to-date `isFavorite` value (the cached
            // `_selectedLoad` was captured at pick time).
            final liveSelected = selectedLoadExists
                ? loads.firstWhere((l) => l.id == _selectedLoad!.id)
                : null;
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (_appliedCommonLoadName != null) ...[
                  _commonLoadDefaultsBanner(),
                  const SizedBox(height: 8),
                ],
                DropdownButtonFormField<int?>(
                  initialValue:
                      selectedLoadExists ? _selectedLoad!.id : null,
                  isExpanded: true,
                  decoration: InputDecoration(
                    border: const OutlineInputBorder(),
                    hintText: hintText,
                  ),
                  items: [
                    const DropdownMenuItem<int?>(
                      value: null,
                      child: Text('— None —'),
                    ),
                    ...orderedLoads.map((l) => DropdownMenuItem<int?>(
                          value: l.id,
                          child: Text(
                            l.isFavorite ? '★ ${l.name}' : l.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        )),
                  ],
                  onChanged: (id) {
                    if (id == null) {
                      setState(() => _selectedLoad = null);
                      _scheduleAutoSave();
                      return;
                    }
                    final l = loads.firstWhere((l) => l.id == id);
                    // Picking a real recipe overrides any previously
                    // applied common-load defaults; the recipe is the
                    // user's canonical choice now.
                    setState(() {
                      _selectedLoad = l;
                      _appliedCommonLoadName = null;
                    });
                    _applyLoadDefaults(l);
                    _scheduleAutoSave();
                  },
                ),
                if (liveSelected != null)
                  _selectedLoadFavoriteRow(liveSelected),
              ],
            );
          },
        ),
      ],
    );
  }

  /// Compact "Currently selected: `name`  [star]" row beneath the
  /// load dropdown. Lets the user star / unstar the picked recipe
  /// without leaving Range Day. Mirrors the affordance the recipe
  /// list screen exposes; the live stream re-emits on every flip
  /// so the icon stays in sync.
  Widget _selectedLoadFavoriteRow(UserLoadRow l) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Row(
        children: [
          Icon(Icons.science_outlined,
              size: 16, color: theme.colorScheme.onSurfaceVariant),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              l.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          FavoriteStarButton(
            isFavorite: l.isFavorite,
            compact: true,
            onToggle: () async {
              final repo = context.read<RecipeRepository>();
              await repo.toggleFavorite(l.id);
            },
          ),
        ],
      ),
    );
  }

  /// Empty-state body for the load picker when the user has no saved
  /// recipes. Exposes two actions: pick a common factory load (opens
  /// `_pickCommonLoad`'s bottom sheet) or jump to BallisticsScreen so
  /// the user can build a saved profile end-to-end.
  Widget _loadPickerEmptyState() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (_appliedCommonLoadName != null) ...[
          _commonLoadDefaultsBanner(),
          const SizedBox(height: 8),
        ],
        EmptyStateCard(
          heading: 'No saved loads yet',
          body:
              'Pick a common factory load to use defaults, or build your '
              'own ballistic profile.',
          actions: [
            FilledButton.icon(
              onPressed: _pickCommonLoad,
              icon: const Icon(Icons.flash_on_outlined),
              label: const Text('Pick a common load'),
            ),
            OutlinedButton.icon(
              onPressed: _openBallisticsScreen,
              icon: const Icon(Icons.tune),
              label: const Text('Create a ballistic profile'),
            ),
          ],
        ),
      ],
    );
  }

  /// Tiny info banner shown above / instead of the load dropdown when
  /// the user has applied a `CommonLoad` from the catalog. The banner
  /// is tappable on its trailing "Clear" button which restores the
  /// original "— None —" state without deleting any user typing —
  /// the controllers keep whatever values are in them.
  Widget _commonLoadDefaultsBanner() {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: theme.colorScheme.primaryContainer,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: theme.colorScheme.outlineVariant),
      ),
      child: Row(
        children: [
          Icon(
            Icons.info_outline,
            size: 18,
            color: theme.colorScheme.onPrimaryContainer,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              'Using $_appliedCommonLoadName defaults — your inputs override',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onPrimaryContainer,
              ),
            ),
          ),
          TextButton(
            onPressed: () {
              setState(() => _appliedCommonLoadName = null);
            },
            child: const Text('Clear'),
          ),
        ],
      ),
    );
  }

  /// Open a modal bottom sheet listing every entry in
  /// [CommonLoadsCatalog] grouped by cartridge, with a search box at
  /// the top. When the user picks one, [_applyCommonLoad] is called
  /// and the sheet dismisses.
  Future<void> _pickCommonLoad() async {
    // Capture the repo before opening the sheet so the picker doesn't
    // have to walk the inherited-widget tree itself. The repo is
    // provided once in `app.dart` and feeds [CommonLoadsCatalog].
    final repo = context.read<ManufacturedAmmoRepository>();
    final picked = await showModalBottomSheet<CommonLoad>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (sheetContext) => _CommonLoadPickerSheet(repo: repo),
    );
    if (picked != null && mounted) {
      _applyCommonLoad(picked);
    }
  }

  /// Mirror the BC / MV / weight / diameter / drag-model fields from a
  /// [CommonLoad] into the live controllers and surface the defaults
  /// banner. We deliberately don't create any DB row — selecting a
  /// common load is just a starting-defaults convenience. The user is
  /// free to edit any of the controllers afterward.
  void _applyCommonLoad(CommonLoad load) {
    setState(() {
      _appliedCommonLoadName = load.name;
      _bcCtrl.text = load.bc.toStringAsFixed(3);
      _muzzleVelCtrl.text = load.muzzleVelocityFps.toStringAsFixed(0);
      _bulletWeightCtrl.text = _trimZeros(load.bulletWeightGr);
      _bulletDiameterCtrl.text = load.bulletDiameterIn.toStringAsFixed(3);
      _dragModel = load.dragModel;
      // Picking a common load nullifies any previous recipe selection
      // because the controllers no longer reflect that recipe's
      // values. The dropdown's "stale-id guard" handles the visual.
      _selectedLoad = null;
    });
    _scheduleSolve();
    _scheduleAutoSave();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('Using ${load.name} defaults'),
        duration: const Duration(seconds: 3),
      ),
    );
  }

  /// Push BallisticsScreen so the user can build a saved ballistic
  /// profile end-to-end. We push directly via MaterialPageRoute (no
  /// named-route lookup) because `lib/app.dart` doesn't define a
  /// routes table — every screen-to-screen jump in the app is an
  /// explicit `MaterialPageRoute`. The load picker now subscribes
  /// to the live `RecipeRepository.watchAll()` stream, so any
  /// newly-saved recipe shows up automatically when the user pops
  /// back — no manual refresh needed.
  Future<void> _openBallisticsScreen() async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => const BallisticsScreen(),
      ),
    );
  }

  /// Opens the saved-sessions list (a.k.a. Range Day History) on top of
  /// this detail screen. Pushing rather than replacing keeps the user's
  /// current draft session intact — backing out of History returns them
  /// to wherever they left off. Wrapped in [safeAsync] so a navigator
  /// failure surfaces a SnackBar instead of an unhandled exception
  /// during a range-day handoff.
  Future<void> _openHistory() async {
    await safeAsync<void>(
      context,
      userMessage: 'Could not open Range Day history.',
      mounted: () => mounted,
      body: () async {
        await Navigator.of(context).push(
          MaterialPageRoute<void>(
            builder: (_) => const RangeDayScreen(),
          ),
        );
      },
    );
  }

  Widget _firearmPicker() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('Firearm', style: Theme.of(context).textTheme.labelLarge),
        const SizedBox(height: 6),
        StreamBuilder<List<UserFirearmRow>>(
          stream: _firearmsStream,
          builder: (context, snap) {
            if (snap.hasError) {
              return RangeDayInlineError(
                message: 'Could not load firearms: ${snap.error}',
                onRetry: () {
                  setState(() {
                    _firearmsStream =
                        context.read<FirearmRepository>().watchAll();
                  });
                },
              );
            }
            final firearms = snap.data ?? const <UserFirearmRow>[];
            // Favorite-first sort. `UserFirearmRow.isFavorite`
            // (schema v24) is the per-row boolean; the live
            // stream re-emits whenever it flips.
            final orderedFirearms = _sortFavoritesFirst<UserFirearmRow>(
              firearms,
              (f) => f.isFavorite,
            );
            // Stale-id guard — see `_profilePicker` for the rationale.
            final selectedFirearmExists = _selectedFirearm != null &&
                firearms.any((f) => f.id == _selectedFirearm!.id);
            // Re-resolve so the inline favorite-star reflects the
            // up-to-date `isFavorite` value.
            final liveSelected = selectedFirearmExists
                ? firearms.firstWhere((f) => f.id == _selectedFirearm!.id)
                : null;
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                DropdownButtonFormField<int?>(
                  initialValue:
                      selectedFirearmExists ? _selectedFirearm!.id : null,
                  isExpanded: true,
                  decoration: const InputDecoration(
                    border: OutlineInputBorder(),
                    hintText: 'Optional — pick the rifle',
                  ),
                  items: [
                    const DropdownMenuItem<int?>(
                      value: null,
                      child: Text('— None —'),
                    ),
                    ...orderedFirearms.map((f) => DropdownMenuItem<int?>(
                          value: f.id,
                          child: Text(
                            f.isFavorite ? '★ ${f.name}' : f.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        )),
                  ],
                  onChanged: (id) {
                    if (id == null) {
                      setState(() => _selectedFirearm = null);
                      _scheduleAutoSave();
                      return;
                    }
                    final f = firearms.firstWhere((f) => f.id == id);
                    setState(() => _selectedFirearm = f);
                    _applyFirearmDefaults(f);
                    _scheduleAutoSave();
                  },
                ),
                if (liveSelected != null)
                  _selectedFirearmFavoriteRow(liveSelected),
              ],
            );
          },
        ),
      ],
    );
  }

  /// Compact "Currently selected: `name`  [star]" row beneath the
  /// firearm dropdown. Mirrors [_selectedLoadFavoriteRow] /
  /// [_selectedProfileFavoriteRow]; the stream-driven rebuild keeps
  /// the icon in sync with [UserFirearms.isFavorite].
  Widget _selectedFirearmFavoriteRow(UserFirearmRow f) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Row(
        children: [
          Icon(Icons.outdoor_grill_outlined,
              size: 16, color: theme.colorScheme.onSurfaceVariant),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              f.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          FavoriteStarButton(
            isFavorite: f.isFavorite,
            compact: true,
            onToggle: () async {
              final repo = context.read<FirearmRepository>();
              await repo.toggleFavorite(f.id);
            },
          ),
        ],
      ),
    );
  }

  // ─────────────────────── Environment card ───────────────────────

  // ─────────────────────── Atmosphere preset picker (v17) ───────────────────────

  /// Build the [AtmosphereSnapshot] used by the inline picker to decide
  /// whether the live env values match a saved preset. Range Day stores
  /// atmosphere fields in canonical imperial (°F / inHg / % / ft) so no
  /// unit conversion is required — same controllers, same units.
  AtmosphereSnapshot _atmosphereSnapshotForPicker() {
    return AtmosphereSnapshot(
      stationPressureInHg: double.tryParse(_pressureCtrl.text.trim()),
      temperatureF: double.tryParse(_tempCtrl.text.trim()),
      humidityPct: double.tryParse(_humidityCtrl.text.trim()),
      altitudeFt: double.tryParse(_elevationCtrl.text.trim()),
    );
  }

  /// Apply the four core columns of [preset] to the Environment
  /// controllers, captures the preset id so the session can persist it,
  /// and triggers a re-solve / auto-save so the change propagates.
  void _applyAtmospherePreset(AtmospherePresetRow preset) {
    setState(() {
      _atmospherePresetId = preset.id;
      _pressureCtrl.text = preset.stationPressureInHg.toStringAsFixed(2);
      _tempCtrl.text = preset.temperatureF.toStringAsFixed(0);
      _humidityCtrl.text = preset.humidityPct.toStringAsFixed(0);
      if (preset.altitudeFt != null) {
        _elevationCtrl.text = preset.altitudeFt!.toStringAsFixed(0);
      }
    });
    _scheduleSolve();
    _scheduleAutoSave();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        duration: const Duration(seconds: 2),
        content: Text('Loaded "${preset.name}"'),
      ),
    );
  }

  /// Reads the current Environment fields and opens the Save-as-preset
  /// dialog with them pre-filled. The Range Day env fields are already
  /// canonical imperial, so they pass straight through.
  Future<void> _onSaveCurrentAsAtmospherePreset() async {
    final messenger = ScaffoldMessenger.of(context);
    final pressure = double.tryParse(_pressureCtrl.text.trim());
    final temp = double.tryParse(_tempCtrl.text.trim());
    final humidity = double.tryParse(_humidityCtrl.text.trim());
    if (pressure == null || temp == null || humidity == null) {
      messenger.showSnackBar(
        const SnackBar(
          content: Text(
              'Fill in pressure, temperature, and humidity before saving.'),
        ),
      );
      return;
    }
    final altitude = double.tryParse(_elevationCtrl.text.trim());
    final newId = await safeAsync<int?>(
      context,
      mounted: () => mounted,
      userMessage: 'Could not save atmosphere preset.',
      body: () async {
        return await showSaveAtmospherePresetDialog(
          context,
          stationPressureInHg: pressure,
          temperatureF: temp,
          humidityPct: humidity,
          altitudeFt: altitude,
        );
      },
    );
    if (newId != null && mounted) {
      setState(() => _atmospherePresetId = newId);
      _scheduleAutoSave();
    }
  }

  Widget _environmentCard() {
    final theme = Theme.of(context);
    final summary = _envSummary();
    return Card(
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          InkWell(
            onTap: () => setState(
                () => _environmentExpanded = !_environmentExpanded),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 8, 12),
              child: Row(
                children: [
                  Icon(Icons.cloud_outlined,
                      color: theme.colorScheme.primary),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('Environment',
                            style: theme.textTheme.titleMedium),
                        if (!_environmentExpanded && summary.isNotEmpty)
                          Padding(
                            padding: const EdgeInsets.only(top: 2),
                            child: Text(
                              summary,
                              style: theme.textTheme.bodySmall,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                      ],
                    ),
                  ),
                  Icon(_environmentExpanded
                      ? Icons.expand_less
                      : Icons.expand_more),
                ],
              ),
            ),
          ),
          if (_environmentExpanded) _environmentBody(),
        ],
      ),
    );
  }

  String _envSummary() {
    final temp = _tempCtrl.text.trim();
    final pressure = _pressureCtrl.text.trim();
    final wind = _windSpeedCtrl.text.trim();
    final dir = _windDirCtrl.text.trim();
    final parts = <String>[];
    if (temp.isNotEmpty) parts.add('$temp°F');
    if (pressure.isNotEmpty) parts.add('$pressure inHg');
    if (wind.isNotEmpty) parts.add('Wind $wind mph @ $dir°');
    return parts.join(' · ');
  }

  Widget _environmentBody() {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          AtmospherePresetPicker(
            dense: true,
            snapshot: _atmosphereSnapshotForPicker(),
            onApplyPreset: _applyAtmospherePreset,
            onSaveAsPreset: _onSaveCurrentAsAtmospherePreset,
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: _envField(_tempCtrl, 'Temp', '°F'),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: _envField(_pressureCtrl, 'Pressure', 'inHg'),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: _envField(_humidityCtrl, 'Humidity', '%'),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: _envField(_elevationCtrl, 'Elevation', 'ft'),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: _envField(_windSpeedCtrl, 'Wind', 'mph'),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: _envField(_windDirCtrl, 'From', '°'),
              ),
            ],
          ),
          if (_weatherFetchedAt != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                _useKestrel
                    ? 'Kestrel · updated ${_formatTime(_weatherFetchedAt!)}'
                    : 'Updated ${_formatTime(_weatherFetchedAt!)}',
                style: theme.textTheme.bodySmall,
              ),
            ),
          const SizedBox(height: 12),
          // Live Kestrel banner / toggle. Hidden when no meter is paired.
          // Kestrel data is more accurate than open-meteo and updates ~1Hz,
          // so when one is available we surface it as the primary action.
          // Bare buttons (no Row+Expanded) — the parent
          // `_environmentBody` Column has `crossAxisAlignment: stretch`
          // which makes the button fill the available width naturally.
          // Earlier code wrapped each in `Row(Expanded(button))` which
          // was redundant and brittle against unbounded-width
          // ancestors.
          Consumer<KestrelService>(
            builder: (ctx, kestrel, _) {
              if (kestrel.device == null) return const SizedBox.shrink();
              if (_useKestrel) {
                return Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: OutlinedButton.icon(
                    onPressed: _onStopUsingKestrel,
                    icon: const Icon(Icons.bluetooth_connected),
                    label: const Text('Stop using Kestrel'),
                  ),
                );
              }
              return Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: FilledButton.icon(
                  onPressed: _onStartUsingKestrel,
                  icon: const Icon(Icons.bluetooth),
                  label: const Text('Use Kestrel readings'),
                ),
              );
            },
          ),
          // Bare button — see comment on the "Import Garmin" button
          // below for the layout rationale. Column(stretch) gives this
          // button tight bounded width naturally.
          OutlinedButton.icon(
            onPressed: (_weatherFetching || _useKestrel)
                ? null
                : _onPullWeather,
            icon: _weatherFetching
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.cloud_download_outlined),
            label: const Text('Pull weather (Pro)'),
          ),
          const SizedBox(height: 8),
          // Bare button — `_environmentBody`'s Column has
          // `crossAxisAlignment: stretch`, so it sets a tight bounded
          // width on its children. Wrapping in `Row > Expanded` was
          // redundant (Expanded inside a Row that itself has bounded
          // width works, but it's a brittle pattern: if any ancestor
          // ever passes infinite-width constraints, Expanded can't
          // resolve its share and the OutlinedButton's internal
          // _RenderInputPadding crashes — the same shape that broke
          // `_inclineAngleRow`). The bare button gets the tight
          // bounded width naturally and renders identically.
          OutlinedButton.icon(
            onPressed: _onImportGarminFit,
            icon: const Icon(Icons.speed),
            label: const Text('Import Garmin .fit (Pro)'),
          ),
        ],
      ),
    );
  }

  Widget _envField(
      TextEditingController controller, String label, String suffix) {
    // Map per-row labels to a known glossary term where one exists.
    // Soft-fails to plain text inside GlossaryLabel when no match.
    final glossaryHint = _envGlossaryHintFor(label);
    return TextField(
      controller: controller,
      keyboardType:
          const TextInputType.numberWithOptions(signed: true, decimal: true),
      decoration: InputDecoration(
        border: const OutlineInputBorder(),
        // Use `label:` (Widget) so the label can show the (?) help
        // glyph and tap-to-define modal. `labelText:` is String-only
        // and would lose the affordance.
        label: GlossaryLabel(
          text: label,
          glossaryTerm: glossaryHint,
        ),
        suffixText: suffix,
        isDense: true,
      ),
      onChanged: (_) {
        _scheduleSolve();
        _scheduleAutoSave();
      },
    );
  }

  /// Map the short environment-grid labels ("Temp", "From") to the
  /// glossary entry that describes the concept. When the entry name
  /// differs from the label visible in the grid, this is where the
  /// link gets pinned.
  String? _envGlossaryHintFor(String label) {
    switch (label) {
      case 'Pressure':
        return 'Station pressure';
      case 'From':
        return 'Wind direction (from convention)';
      case 'Wind':
        return 'Wind drift';
      case 'Elevation':
        return 'Density altitude';
      default:
        return null;
    }
  }

  String _formatTime(DateTime t) {
    final h12 = t.hour % 12 == 0 ? 12 : t.hour % 12;
    final mm = t.minute.toString().padLeft(2, '0');
    final ampm = t.hour >= 12 ? 'PM' : 'AM';
    return '$h12:$mm $ampm';
  }

  // ─────────────────────── Solution card ───────────────────────

  Widget _solutionCard() {
    final theme = Theme.of(context);
    // The solver-error tile that used to live here was removed —
    // when the user had scrolled past Solution it was effectively
    // invisible. Errors now render as a top-pinned MaterialBanner
    // built by `_solveErrorBanner`, so the user sees them even mid-
    // scroll. The Solution card still falls back to "Solving…" while
    // a recompute is pending; in error states the body simply shows
    // the previous valid solution if there was one (no flicker), or
    // the "Solving…" placeholder.
    return Card(
      clipBehavior: Clip.antiAlias,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Icon(Icons.flag_outlined, color: theme.colorScheme.primary),
                const SizedBox(width: 8),
                GlossaryLabel(
                  text: 'Firing solution',
                  glossaryTerm: 'DOPE',
                  style: theme.textTheme.titleMedium,
                ),
              ],
            ),
            const SizedBox(height: 12),
            if (_solution == null)
              Text('Solving…', style: theme.textTheme.bodyMedium)
            else
              _solutionBody(_solution!),
          ],
        ),
      ),
    );
  }

  /// Top-pinned solver-error banner. Returns SizedBox.shrink when
  /// there is no error so the Column above the scroll view collapses
  /// cleanly. Built with `MaterialBanner` (Flutter's standard inline
  /// alert) rather than a custom widget so accessibility and theming
  /// come for free.
  Widget _solveErrorBanner() {
    if (_solveError == null) return const SizedBox.shrink();
    final theme = Theme.of(context);
    return MaterialBanner(
      backgroundColor: theme.colorScheme.errorContainer,
      contentTextStyle:
          TextStyle(color: theme.colorScheme.onErrorContainer),
      padding: const EdgeInsets.fromLTRB(16, 12, 8, 12),
      forceActionsBelow: false,
      leading: Icon(
        Icons.error_outline,
        color: theme.colorScheme.error,
      ),
      content: Text(_solveError!),
      actions: [
        TextButton(
          onPressed: () => setState(() => _solveError = null),
          child: const Text('Dismiss'),
        ),
      ],
    );
  }

  /// Convenience that returns either an empty list (bracket hidden)
  /// or a `[card, SizedBox]` pair so the surrounding layout never
  /// produces double-spacing between cards regardless of whether the
  /// bracket is shown.
  List<Widget> _windBracketSection() {
    if (!_canShowWindBracket()) return const <Widget>[];
    return <Widget>[_windBracketCard(), const SizedBox(height: 12)];
  }

  /// Mirrors the conditions inside [_windBracketCard]; lets the
  /// layout decide whether to allocate spacing without paying the
  /// cost of running the bracket solver itself.
  bool _canShowWindBracket() {
    return _lastSolvedProjectile != null &&
        _lastSolvedEnvironment != null &&
        _lastSolvedShot != null &&
        _lastSolvedDistanceYd != null &&
        _lastSolvedWindMph != null &&
        _windUncertaintyMph > 0;
  }

  /// Litz wind-bracket card. Anchored on the user's distance (not the
  /// long range of the DOPE table) so the hold envelope is calibrated
  /// to the shot the shooter is actually about to take. Hides cleanly
  /// when [_windUncertaintyMph] is 0, the solution panel is in error,
  /// or the bracket service can't produce a result.
  ///
  /// Reference: Litz, *Modern Advancements in Long-Range Shooting*
  /// vol. 1 ch. 5 — the bracket method turns wind-call uncertainty
  /// into a +/- hold the shooter can read off the screen instead of
  /// pretending the wind reading is exact.
  Widget _windBracketCard() {
    final theme = Theme.of(context);
    final projectile = _lastSolvedProjectile;
    final environment = _lastSolvedEnvironment;
    final shot = _lastSolvedShot;
    final distance = _lastSolvedDistanceYd;
    final wind = _lastSolvedWindMph;
    if (projectile == null ||
        environment == null ||
        shot == null ||
        distance == null ||
        wind == null) {
      return const SizedBox.shrink();
    }
    if (_windUncertaintyMph <= 0) return const SizedBox.shrink();
    final result = computeWindBracket(
      projectile: projectile,
      environment: environment,
      shot: shot,
      rangeYards: distance,
      windEstimateMph: wind,
      windUncertaintyMph: _windUncertaintyMph,
    );
    if (result == null) return const SizedBox.shrink();

    String fmtHold(double inches, double yd) {
      final mil = bu.inchesToMilAtYards(inches, yd);
      final moa = bu.inchesToMoaAtYards(inches, yd);
      switch (_correctionUnit) {
        case 'moa':
          return '${moa.toStringAsFixed(1)} MOA · ${mil.toStringAsFixed(2)} mil';
        case 'inches':
          return '${inches.toStringAsFixed(1)} in · ${mil.toStringAsFixed(2)} mil';
        default:
          return '${mil.toStringAsFixed(2)} mil · ${moa.toStringAsFixed(1)} MOA';
      }
    }

    String fmtWind(double mph) => '${mph.toStringAsFixed(1)} mph';

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
                GlossaryLabel(
                  text: 'Wind bracket',
                  glossaryTerm: 'Wind uncertainty',
                  style: theme.textTheme.titleMedium,
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              'Estimated ${fmtWind(result.windMidMph)} @ ${windClock()} '
              '· ± ${fmtWind(_windUncertaintyMph)}',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 12),
            _wbRow('Low (${fmtWind(result.windLowMph)})',
                fmtHold(result.low.windDriftInches, result.low.rangeYards),
                emphasis: false),
            const SizedBox(height: 6),
            _wbRow('Mid (${fmtWind(result.windMidMph)})',
                fmtHold(result.mid.windDriftInches, result.mid.rangeYards),
                emphasis: true),
            const SizedBox(height: 6),
            _wbRow('High (${fmtWind(result.windHighMph)})',
                fmtHold(result.high.windDriftInches, result.high.rangeYards),
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

  Widget _wbRow(String label, String value, {required bool emphasis}) {
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
          flex: 6,
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

  /// Stability + form-factor read-out for the Range Day setup card.
  /// Rendered when both a load and a firearm are selected (the
  /// inputs needed for Sg). Free / informational.
  Widget _stabilityAndFormFactor() {
    if (_selectedLoad == null && _selectedFirearm == null) {
      return const SizedBox.shrink();
    }
    final theme = Theme.of(context);
    final diameter =
        double.tryParse(_bulletDiameterCtrl.text.trim());
    final weight = double.tryParse(_bulletWeightCtrl.text.trim());
    final length = double.tryParse(_bulletLengthCtrl.text.trim());
    final twist = double.tryParse(_twistCtrl.text.trim());
    final bc = double.tryParse(_bcCtrl.text.trim());
    final mv = double.tryParse(_muzzleVelCtrl.text.trim()) ?? 2800;
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
    final miller = projectile.millerStability(mv);
    final pejsa = projectile.pejsaStability(mv);
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
      margin: const EdgeInsets.only(top: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.flight_takeoff,
                  size: 16, color: theme.colorScheme.primary),
              const SizedBox(width: 6),
              Text(
                'Stability and form factor',
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
      color = const Color(0xFF2E7D32);
      icon = Icons.check_circle;
      verdict = 'Stable';
    } else if (sg >= 1.0) {
      color = const Color(0xFFEF6C00);
      icon = Icons.warning_amber;
      verdict = 'Marginal';
    } else {
      color = theme.colorScheme.error;
      icon = Icons.error;
      verdict = 'Unstable';
    }
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

  Widget _solutionBody(TrajectorySample s) {
    final theme = Theme.of(context);
    final yards = s.rangeYards;
    final dropMoa = bu.inchesToMoaAtYards(s.dropInches, yards);
    final windMoa = bu.inchesToMoaAtYards(s.windDriftInches, yards);
    final dropMil = bu.inchesToMilAtYards(s.dropInches, yards);
    final windMil = bu.inchesToMilAtYards(s.windDriftInches, yards);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Center(
          child: Text(
            '${yards.toStringAsFixed(0)} yd',
            style: theme.textTheme.headlineSmall?.copyWith(
              color: theme.colorScheme.primary,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
        const SizedBox(height: 12),
        _bigStat(
          label: 'Drop',
          primary: '${dropMoa.toStringAsFixed(1)} MOA',
          secondary:
              '${dropMil.toStringAsFixed(2)} mil · ${s.dropInches.toStringAsFixed(1)} in',
          isDrop: true,
        ),
        const SizedBox(height: 8),
        _bigStat(
          label: 'Wind',
          primary: '${windMoa.toStringAsFixed(1)} MOA',
          secondary:
              '${windMil.toStringAsFixed(2)} mil · ${s.windDriftInches.toStringAsFixed(1)} in',
          isDrop: false,
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(
              child: _smallStat('Vel',
                  '${s.velocityFps.toStringAsFixed(0)} fps'),
            ),
            Expanded(
              child: _smallStat('Energy',
                  '${s.energyFtLb.toStringAsFixed(0)} ft-lbs'),
            ),
            Expanded(
              child: _smallStat('TOF',
                  '${s.timeSec.toStringAsFixed(2)} s'),
            ),
          ],
        ),
        const SizedBox(height: 12),
        OutlinedButton.icon(
          onPressed: () => _openScopeView(s),
          // Material doesn't ship a `target_rounded` glyph in this
          // Flutter version; `crisis_alert` is the standard
          // concentric-rings target icon and is the closest semantic
          // match for a scope-view affordance.
          icon: const Icon(Icons.crisis_alert),
          label: const Text('Scope View'),
        ),
      ],
    );
  }

  /// Pro-gated: opens the [ScopeViewScreen] visualizer with the current
  /// firing solution + reticle + target. Surfaces a snackbar if a
  /// reticle hasn't been picked yet, since the visualizer needs one.
  Future<void> _openScopeView(TrajectorySample s) async {
    if (!await ensurePro(context)) return;
    if (!mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    final reticle = _selectedReticle;
    if (reticle == null) {
      messenger.showSnackBar(
        const SnackBar(
          content:
              Text('Pick a reticle in Setup to use Scope View.'),
        ),
      );
      return;
    }
    // Latest impact (the most-recent shot on the target plot, if any).
    double? latestImpactX;
    double? latestImpactY;
    if (_shots.isNotEmpty) {
      final latest = _shots.last;
      latestImpactX = latest.impactX;
      latestImpactY = latest.impactY;
    }
    // Resolve optic so we can default magnification, focal plane,
    // adjustment unit. Falls back to safe defaults when the user
    // hasn't linked an optic to the firearm.
    OpticRow? optic;
    String? opticName;
    final opticsId = _selectedFirearm?.opticsId;
    if (opticsId != null) {
      try {
        optic = await context.read<OpticsRepository>().byId(opticsId);
        if (optic != null) {
          opticName = optic.model;
        }
      } catch (_) {
        // Non-fatal — we just render with defaults.
      }
    }
    if (!mounted) return;
    // Use the active-target spec so Scope View shows the rack child's
    // geometry when a rack is in play, instead of falling through to
    // the legacy default-paper placeholder.
    final spec = _activeTargetSpec ?? TargetSpec.defaultPaper();
    await safeAsync<void>(
      context,
      mounted: () => mounted,
      userMessage: 'Could not open Scope View.',
      body: () async {
        final inputs = buildScopeViewInputs(
          reticle: reticle,
          targetSpec: spec,
          dropInches: s.dropInches,
          windDriftInches: s.windDriftInches,
          rangeYards: s.rangeYards,
          aimPointX: _aimPointX,
          aimPointY: _aimPointY,
          latestImpactX: latestImpactX,
          latestImpactY: latestImpactY,
          hitProb: _hitProb,
          optic: optic,
          opticName: opticName,
        );
        if (!mounted) return;
        await Navigator.of(context).push(
          MaterialPageRoute<void>(
            builder: (_) => ScopeViewScreen(inputs: inputs),
          ),
        );
      },
    );
  }

  Widget _bigStat({
    required String label,
    required String primary,
    required String secondary,
    required bool isDrop,
  }) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        children: [
          SizedBox(
            width: 48,
            // GlossaryLabel here surfaces the in-form definition modal
            // for "Drop" / "Wind" stat tiles. Soft-fails to plain Text
            // when no glossary entry resolves (e.g. acronym labels).
            child: GlossaryLabel(
              text: label,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  primary,
                  style: theme.textTheme.headlineMedium?.copyWith(
                    fontFeatures: const [FontFeature.tabularFigures()],
                    color: theme.colorScheme.onSurface,
                  ),
                ),
                Text(
                  secondary,
                  style: theme.textTheme.bodySmall,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _smallStat(String label, String value) {
    final theme = Theme.of(context);
    // Map the short stat-tile labels ("Vel", "TOF") to their full
    // glossary entries so the (?) glyph leads to the right definition.
    final glossaryHint = _smallStatGlossaryHintFor(label);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        GlossaryLabel(
          text: label,
          glossaryTerm: glossaryHint,
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        Text(value,
            style: theme.textTheme.titleMedium?.copyWith(
              fontFeatures: const [FontFeature.tabularFigures()],
            )),
      ],
    );
  }

  /// Map abbreviated stat-tile labels to their glossary entries.
  /// Returning null causes GlossaryLabel to use the visible label as
  /// the lookup key (which still soft-fails to plain Text on a miss).
  String? _smallStatGlossaryHintFor(String label) {
    switch (label) {
      case 'Vel':
        return 'Muzzle Velocity';
      case 'Energy':
        // No direct entry; surface "Drop" definition would be wrong.
        // Return null so GlossaryLabel falls back to plain Text.
        return null;
      case 'TOF':
        return null; // No glossary entry yet for time-of-flight.
      default:
        return null;
    }
  }

  // ─────────────────────── DOPE card ───────────────────────

  Widget _dopeCard() {
    final theme = Theme.of(context);
    // Hide the card entirely when there's no DOPE to render. The
    // Solution card directly above already shows "Solving…" or the
    // solver error in this state, so a placeholder DOPE card was just
    // duplicating the same "no result yet" message in a second card.
    // SizedBox.shrink() collapses the slot so the surrounding spacing
    // strip (`SizedBox(height: 12)`) doesn't leave a phantom gap when
    // the card is missing.
    if (_dopeRows.isEmpty) {
      return const SizedBox.shrink();
    }
    return Card(
      clipBehavior: Clip.antiAlias,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Icon(Icons.table_chart_outlined,
                    color: theme.colorScheme.primary),
                const SizedBox(width: 8),
                Text('DOPE card', style: theme.textTheme.titleMedium),
                const Spacer(),
                IconButton(
                  tooltip: 'Copy DOPE',
                  icon: const Icon(Icons.copy_outlined),
                  onPressed: _copyDope,
                ),
              ],
            ),
            const SizedBox(height: 8),
            DefaultTextStyle.merge(
              style: const TextStyle(
                fontFeatures: [FontFeature.tabularFigures()],
              ),
              child: Table(
                columnWidths: const {
                  0: FlexColumnWidth(2),
                  1: FlexColumnWidth(3),
                  2: FlexColumnWidth(3),
                  3: FlexColumnWidth(3),
                },
                children: [
                  TableRow(
                    decoration: BoxDecoration(
                      color: theme.colorScheme.surfaceContainerHighest,
                    ),
                    children: const [
                      _DopeHeaderCell('Range'),
                      _DopeHeaderCell('Drop'),
                      _DopeHeaderCell('Wind'),
                      _DopeHeaderCell('TOF'),
                    ],
                  ),
                  for (final s in _dopeRows)
                    TableRow(
                      children: [
                        _DopeBodyCell('${s.rangeYards.toStringAsFixed(0)} yd'),
                        _DopeBodyCell(
                            '${bu.inchesToMoaAtYards(s.dropInches, s.rangeYards).toStringAsFixed(1)} M'),
                        _DopeBodyCell(
                            '${bu.inchesToMoaAtYards(s.windDriftInches, s.rangeYards).toStringAsFixed(1)} M'),
                        _DopeBodyCell('${s.timeSec.toStringAsFixed(2)} s'),
                      ],
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _copyDope() async {
    if (_dopeRows.isEmpty) return;
    final messenger = ScaffoldMessenger.of(context);
    final buf = StringBuffer();
    buf.writeln('Range Day DOPE');
    buf.writeln('--------------');
    if (_session != null) buf.writeln(_session!.name);
    final dopeTargetName = _activeTargetDisplayName;
    if (dopeTargetName != null) buf.writeln('Target: $dopeTargetName');
    buf.writeln(
        'MV ${_muzzleVelCtrl.text} fps · BC ${_bcCtrl.text} (${_dragModel.short})');
    buf.writeln(
        'Wind ${_windSpeedCtrl.text} mph @ ${_windDirCtrl.text}° · '
        '${_tempCtrl.text}°F · ${_pressureCtrl.text} inHg');
    buf.writeln('');
    buf.writeln('Range   Drop      Wind      TOF');
    for (final s in _dopeRows) {
      buf.writeln('${s.rangeYards.toStringAsFixed(0).padLeft(4)} yd  '
          '${bu.inchesToMoaAtYards(s.dropInches, s.rangeYards).toStringAsFixed(1).padLeft(6)} M  '
          '${bu.inchesToMoaAtYards(s.windDriftInches, s.rangeYards).toStringAsFixed(1).padLeft(5)} M  '
          '${s.timeSec.toStringAsFixed(2)} s');
    }
    try {
      await Clipboard.setData(ClipboardData(text: buf.toString()));
      if (!mounted) return;
      messenger.showSnackBar(
        const SnackBar(content: Text('DOPE copied to clipboard')),
      );
    } catch (e, stack) {
      debugPrint('[range_day] _copyDope failed: $e');
      debugPrintStack(stackTrace: stack, label: '_copyDope');
      if (!mounted) return;
      messenger.showSnackBar(
        const SnackBar(content: Text('Could not copy DOPE to clipboard.')),
      );
    }
  }

  // ─────────────────────── Target plot card ───────────────────────

  Widget _targetPlotCard() {
    final theme = Theme.of(context);
    final spec = _selectedTarget == null
        ? TargetSpec.defaultPaper()
        : TargetSpec.fromRow(_selectedTarget!);
    final yards = double.tryParse(_distanceCtrl.text) ?? 0;
    final stats = _computeGroupStats(yards);
    final reticleUnit = _correctionUnit == 'moa' ? 'moa' : 'mil';
    return Card(
      clipBehavior: Clip.antiAlias,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Icon(Icons.gps_fixed, color: theme.colorScheme.primary),
                const SizedBox(width: 8),
                Text('Target plot', style: theme.textTheme.titleMedium),
                const Spacer(),
                if (_shots.isNotEmpty)
                  TextButton.icon(
                    onPressed: _confirmClearShots,
                    icon: const Icon(Icons.clear_all, size: 16),
                    label: const Text('Clear'),
                  ),
              ],
            ),
            const SizedBox(height: 8),
            // Tap-mode toggle. The user picks aim mode to set the hold,
            // then flips to record-shot mode once the trigger breaks.
            SegmentedButton<TargetPlotTapMode>(
              segments: const [
                ButtonSegment(
                  value: TargetPlotTapMode.aimPoint,
                  icon: Icon(Icons.adjust, size: 16),
                  label: Text('Aim Point'),
                ),
                ButtonSegment(
                  value: TargetPlotTapMode.recordShot,
                  icon: Icon(Icons.fiber_manual_record, size: 14),
                  label: Text('Record Hit'),
                ),
              ],
              selected: {_tapMode},
              showSelectedIcon: false,
              onSelectionChanged: (s) =>
                  setState(() => _tapMode = s.first),
            ),
            const SizedBox(height: 8),
            Text(
              _tapMode == TargetPlotTapMode.aimPoint
                  ? 'Tap inside the target to set your aim point. The reticle '
                      'overlay shows what you should see through the scope.'
                  : 'Tap inside the target to record where the shot landed. '
                      'Long-press a hit to edit or delete.',
              style: theme.textTheme.bodySmall,
            ),
            const SizedBox(height: 8),
            // View-mode toggle. Realistic = the target sits inside a
            // larger frame (room for the reticle holdovers); Target-
            // Focused = the target fills the box (default; easier dot
            // placement). The (-1..1, -1..1) coordinate space is
            // anchored to the target rectangle in BOTH modes so
            // previously placed aim points + recorded shots stay in
            // the right spot when the user flips the toggle. Compact
            // styling matches other Range Day inline toggles.
            //
            // Bare Row (no Expanded) — `Column.stretch` would make an
            // Expanded child throw, so we keep the toggle at its
            // natural width on the leading edge of the row.
            Row(
              mainAxisAlignment: MainAxisAlignment.start,
              children: [
                SegmentedButton<TargetPlotViewMode>(
                  showSelectedIcon: false,
                  style: SegmentedButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                    padding: const EdgeInsets.symmetric(
                        horizontal: 10, vertical: 4),
                    textStyle: theme.textTheme.bodySmall,
                  ),
                  segments: const [
                    ButtonSegment(
                      value: TargetPlotViewMode.realistic,
                      label: Text('Realistic'),
                      tooltip:
                          'Realistic - target sits inside a wider frame, '
                          'closer to what you see through the scope.',
                    ),
                    ButtonSegment(
                      value: TargetPlotViewMode.targetFocused,
                      label: Text('Target-Focused'),
                      tooltip:
                          'Target-Focused - the target fills the box; '
                          'best for accurate dot placement.',
                    ),
                  ],
                  selected: {_targetPlotViewMode},
                  onSelectionChanged: (sel) {
                    final next = sel.first;
                    if (next == _targetPlotViewMode) return;
                    setState(() => _targetPlotViewMode = next);
                    // ignore: discarded_futures
                    _persistTargetPlotViewMode(next);
                  },
                ),
              ],
            ),
            const SizedBox(height: 12),
            if (_shotsStream != null)
              StreamBuilder<List<ShotImpactRow>>(
                stream: _shotsStream,
                initialData: _shots,
                builder: (context, snap) {
                  if (snap.hasError) {
                    // The shot stream errored — surface a small inline
                    // error and fall back to the in-memory cache so
                    // the user can keep recording.
                    return Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        RangeDayInlineError(
                          message:
                              'Could not load shots: ${snap.error}',
                          onRetry: () {
                            if (_session == null) return;
                            setState(() {
                              _shotsStream = context
                                  .read<RangeDayRepository>()
                                  .streamShotsForSession(_session!.id);
                            });
                          },
                        ),
                        const SizedBox(height: 8),
                        TargetPlot(
                          target: spec,
                          shots: _shots,
                          onTapAt: _recordShot,
                          onLongPressShot: _editShotDialog,
                          tapMode: _tapMode,
                          viewMode: _targetPlotViewMode,
                          aimPointX: _aimPointX,
                          aimPointY: _aimPointY,
                          onAimPointSet: _setAimPoint,
                          reticle: _selectedReticle,
                          reticleDisplayUnit: reticleUnit,
                          rackChildren: _rackChildrenSpec,
                          activeRackChildIndex: _activeRackChildIndex,
                          colorHexOverride: _selectedTargetColorHex,
                        ),
                      ],
                    );
                  }
                  final shots = snap.data ?? const <ShotImpactRow>[];
                  // Keep in-memory cache in sync without triggering a setState
                  // that would loop.
                  if (!_listsEqual(shots, _shots)) {
                    WidgetsBinding.instance.addPostFrameCallback((_) {
                      if (!mounted) return;
                      setState(() => _shots = shots);
                    });
                  }
                  return TargetPlot(
                    target: spec,
                    shots: shots,
                    onTapAt: _recordShot,
                    onLongPressShot: _editShotDialog,
                    tapMode: _tapMode,
                    viewMode: _targetPlotViewMode,
                    aimPointX: _aimPointX,
                    aimPointY: _aimPointY,
                    onAimPointSet: _setAimPoint,
                    reticle: _selectedReticle,
                    reticleDisplayUnit: reticleUnit,
                    rackChildren: _rackChildrenSpec,
                    activeRackChildIndex: _activeRackChildIndex,
                    colorHexOverride: _selectedTargetColorHex,
                  );
                },
              )
            else
              TargetPlot(
                target: spec,
                shots: _shots,
                onTapAt: _recordShot,
                onLongPressShot: (_) {},
                tapMode: _tapMode,
                viewMode: _targetPlotViewMode,
                aimPointX: _aimPointX,
                aimPointY: _aimPointY,
                onAimPointSet: _setAimPoint,
                reticle: _selectedReticle,
                reticleDisplayUnit: reticleUnit,
                rackChildren: _rackChildrenSpec,
                activeRackChildIndex: _activeRackChildIndex,
                colorHexOverride: _selectedTargetColorHex,
              ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: _smallStat('Shots', '${_shots.length}'),
                ),
                Expanded(
                  child: _smallStat(
                      'Group',
                      stats == null
                          ? '—'
                          : '${stats.extremeSpreadIn.toStringAsFixed(2)}"'),
                ),
                Expanded(
                  child: _smallStat(
                      'MOA',
                      stats == null
                          ? '—'
                          : stats.extremeSpreadMoa.toStringAsFixed(2)),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  /// Save the aim point, persist, and re-run the hit-probability calc.
  /// Once the user has placed an aim point they almost certainly want to
  /// record a shot next, so we auto-flip the tap-mode toggle.
  void _setAimPoint(double normX, double normY) {
    setState(() {
      _aimPointX = normX;
      _aimPointY = normY;
      _tapMode = TargetPlotTapMode.recordShot;
    });
    _scheduleHitProb();
    _scheduleAutoSave();
  }

  bool _listsEqual(List<ShotImpactRow> a, List<ShotImpactRow> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i].id != b[i].id) return false;
    }
    return true;
  }

  /// Compute the rich [GroupStats] for the current shot impacts. Returns
  /// null if fewer than 2 shots are recorded or no target is picked.
  ///
  /// Conversion from normalized (-1..1) impact coordinates to inches:
  /// `x_inches = impactX * widthIn / 2`, `y_inches = impactY * heightIn / 2`.
  GroupStats? _computeGroupStats(double yards) {
    if (_shots.length < 2) return null;
    if (_selectedTarget == null) return null;
    final w = _selectedTarget!.widthIn;
    final h = _selectedTarget!.heightIn;
    final pts = [
      for (final s in _shots) Offset(s.impactX * (w / 2), s.impactY * (h / 2)),
    ];
    final bulletDia = double.tryParse(_bulletDiameterCtrl.text.trim()) ?? 0.0;
    return computeGroupStats(
      points: pts,
      distanceYd: yards,
      bulletDiameterIn: bulletDia,
    );
  }

  // ─────────────────────── Moving target (Pro) card ───────────────────────

  Widget _movingTargetCard() {
    final theme = Theme.of(context);
    return Card(
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          InkWell(
            onTap: () => setState(
                () => _movingTargetExpanded = !_movingTargetExpanded),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 8, 12),
              child: Row(
                children: [
                  Icon(Icons.directions_run,
                      color: theme.colorScheme.primary),
                  const SizedBox(width: 8),
                  Text('Moving target',
                      style: theme.textTheme.titleMedium),
                  const SizedBox(width: 8),
                  Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 6, vertical: 2),
                    decoration: BoxDecoration(
                      color: theme.colorScheme.primary
                          .withValues(alpha: 0.18),
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: Text('Pro',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.primary,
                          fontWeight: FontWeight.w600,
                        )),
                  ),
                  const Spacer(),
                  Icon(_movingTargetExpanded
                      ? Icons.expand_less
                      : Icons.expand_more),
                ],
              ),
            ),
          ),
          if (_movingTargetExpanded)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
              child: ProGate(
                feature: 'Moving target lead',
                child: _movingTargetBody(),
              ),
            ),
        ],
      ),
    );
  }

  Widget _movingTargetBody() {
    final theme = Theme.of(context);
    final tof = _solution?.timeSec;
    final speedMph = double.tryParse(_moverSpeedCtrl.text) ?? 0;
    // Lead calc:  lead_inches = speed_mph * mph_to_ips * tof.
    // 1 mph = 17.6 inches/second.
    final yards = double.tryParse(_distanceCtrl.text) ?? 0;
    final leadIn = (tof == null) ? null : speedMph * 17.6 * tof;
    final leadMoa = (leadIn == null || yards <= 0)
        ? null
        : bu.inchesToMoaAtYards(leadIn, yards);
    final leadMil = (leadIn == null || yards <= 0)
        ? null
        : bu.inchesToMilAtYards(leadIn, yards);
    final centerLeadIn = leadIn;
    final frontEdgeLeadIn = (leadIn == null || _selectedTarget == null)
        ? null
        : leadIn - _selectedTarget!.widthIn / 2;
    final frontEdgeLeadMoa =
        (frontEdgeLeadIn == null || yards <= 0)
            ? null
            : bu.inchesToMoaAtYards(frontEdgeLeadIn, yards);
    final frontEdgeLeadMil =
        (frontEdgeLeadIn == null || yards <= 0)
            ? null
            : bu.inchesToMilAtYards(frontEdgeLeadIn, yards);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: TextField(
                controller: _moverSpeedCtrl,
                keyboardType:
                    const TextInputType.numberWithOptions(decimal: true),
                decoration: const InputDecoration(
                  border: OutlineInputBorder(),
                  labelText: 'Speed',
                  suffixText: 'mph',
                  isDense: true,
                ),
                onChanged: (_) => setState(() {}),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: SegmentedButton<String>(
                segments: const [
                  ButtonSegment(value: 'rtl', label: Text('R→L')),
                  ButtonSegment(value: 'ltr', label: Text('L→R')),
                ],
                selected: {_moverDirection},
                showSelectedIcon: false,
                onSelectionChanged: (s) =>
                    setState(() => _moverDirection = s.first),
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        if (tof == null)
          Text(
            'Lead requires a firing solution at the current distance.',
            style: theme.textTheme.bodySmall,
          )
        else ...[
          _bigStat(
            label: 'Center',
            primary: centerLeadIn == null
                ? '—'
                : '${(leadMoa ?? 0).toStringAsFixed(1)} MOA',
            secondary: centerLeadIn == null
                ? '—'
                : '${(leadMil ?? 0).toStringAsFixed(2)} mil · '
                    '${centerLeadIn.toStringAsFixed(1)} in',
            isDrop: false,
          ),
          const SizedBox(height: 8),
          _bigStat(
            label: 'Front',
            primary: frontEdgeLeadIn == null
                ? '—'
                : '${(frontEdgeLeadMoa ?? 0).toStringAsFixed(1)} MOA',
            secondary: frontEdgeLeadIn == null
                ? '—'
                : '${(frontEdgeLeadMil ?? 0).toStringAsFixed(2)} mil · '
                    '${frontEdgeLeadIn.toStringAsFixed(1)} in',
            isDrop: false,
          ),
          const SizedBox(height: 6),
          Text(
            'Front-edge hold = center lead minus half the target’s '
            'visual width. Mover travels '
            '${_moverDirection == 'rtl' ? 'right to left' : 'left to right'}.',
            style: theme.textTheme.bodySmall,
          ),
        ],
      ],
    );
  }

  // ─────────────────────── Hit probability card ───────────────────────

  Widget _hitProbCard() {
    final theme = Theme.of(context);
    final hp = _hitProb;
    if (hp == null || _selectedTarget == null) {
      return Card(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
          child: Row(
            children: [
              Icon(Icons.bar_chart, color: theme.colorScheme.primary),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  _selectedTarget == null
                      ? 'Pick a target to see hit probability.'
                      : 'Computing hit probability…',
                  style: theme.textTheme.bodyMedium,
                ),
              ),
            ],
          ),
        ),
      );
    }
    final pct = (hp.hitProbability * 100).round();
    final pctColor = pct >= 80
        ? Colors.green.shade400
        : (pct >= 50
            ? Colors.amber.shade400
            : theme.colorScheme.error);
    final dist = double.tryParse(_distanceCtrl.text) ?? 0;
    final targetLabel = _selectedTarget == null
        ? ''
        : 'for ${_selectedTarget!.name} at ${dist.toStringAsFixed(0)} yd';
    return Card(
      clipBehavior: Clip.antiAlias,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Icon(Icons.bar_chart, color: theme.colorScheme.primary),
                const SizedBox(width: 8),
                GlossaryLabel(
                  text: 'Hit probability',
                  glossaryTerm: 'Hit probability',
                  style: theme.textTheme.titleMedium,
                ),
              ],
            ),
            const SizedBox(height: 12),
            Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Text(
                  '$pct%',
                  style: theme.textTheme.displayMedium?.copyWith(
                    color: pctColor,
                    fontWeight: FontWeight.w700,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      LinearProgressIndicator(
                        value: hp.hitProbability.clamp(0.0, 1.0),
                        minHeight: 8,
                        color: pctColor,
                        backgroundColor:
                            theme.colorScheme.surfaceContainerHighest,
                      ),
                      const SizedBox(height: 6),
                      Text(
                        targetLabel,
                        style: theme.textTheme.bodySmall,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 14),
            Text(
              'Dispersion at target',
              style: theme.textTheme.labelLarge,
            ),
            const SizedBox(height: 6),
            Row(
              children: [
                Expanded(
                  child: _smallStat(
                    '↕ vertical',
                    '${hp.verticalSigmaIn.toStringAsFixed(1)}"',
                  ),
                ),
                Expanded(
                  child: _smallStat(
                    '↔ horizontal',
                    '${hp.horizontalSigmaIn.toStringAsFixed(1)}"',
                  ),
                ),
                Expanded(
                  child: _smallStat(
                    'Total',
                    '${hp.dispersionMoa.toStringAsFixed(1)} MOA',
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            ExpansionTile(
              tilePadding: EdgeInsets.zero,
              childrenPadding: const EdgeInsets.only(bottom: 8),
              title: Text(
                'Why?',
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.primary,
                  fontWeight: FontWeight.w500,
                ),
              ),
              children: [_factorBreakdown(hp)],
            ),
          ],
        ),
      ),
    );
  }

  Widget _factorBreakdown(HitProbabilityResult hp) {
    final theme = Theme.of(context);
    // Sort factors by variance contribution descending so the worst
    // offender is on top — that's the actionable one.
    final factors = [...hp.factors];
    final totalVariance =
        factors.fold<double>(0, (acc, f) => acc + f.contribIn * f.contribIn);
    factors.sort((a, b) => (b.contribIn * b.contribIn)
        .compareTo(a.contribIn * a.contribIn));
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final f in factors)
          Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    f.label,
                    style: theme.textTheme.bodyMedium,
                  ),
                ),
                Text(
                  '${f.contribIn.toStringAsFixed(1)}"',
                  style: theme.textTheme.bodyMedium,
                ),
                const SizedBox(width: 12),
                SizedBox(
                  width: 48,
                  child: Text(
                    totalVariance <= 0
                        ? '—'
                        : '${((f.contribIn * f.contribIn / totalVariance) * 100).round()}%',
                    textAlign: TextAlign.right,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: theme.colorScheme.primary,
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }

  // ─────────────────────── Post-shot correction card ───────────────────────

  Widget _correctionCard() {
    final theme = Theme.of(context);
    if (_shots.isEmpty || _selectedTarget == null) {
      return const SizedBox.shrink();
    }
    final lastShot = _shots.last;
    final dist = double.tryParse(_distanceCtrl.text) ?? 0;
    if (dist <= 0) return const SizedBox.shrink();
    // Shot impact in inches relative to target center.
    final w = _selectedTarget!.widthIn;
    final h = _selectedTarget!.heightIn;
    final hitX = lastShot.impactX * w / 2;
    final hitY = lastShot.impactY * h / 2;
    // Aim point in inches (treat null as dead center).
    final aimX = (_aimPointX ?? 0) * w / 2;
    final aimY = (_aimPointY ?? 0) * h / 2;
    // Correction vector = aim point − hit (i.e. how far to move the
    // next shot to land on the aim point).
    final dxIn = aimX - hitX;
    final dyIn = aimY - hitY;
    final dxMoa = bu.inchesToMoaAtYards(dxIn.abs(), dist);
    final dyMoa = bu.inchesToMoaAtYards(dyIn.abs(), dist);
    final dxMil = bu.inchesToMilAtYards(dxIn.abs(), dist);
    final dyMil = bu.inchesToMilAtYards(dyIn.abs(), dist);
    // Direction labels.
    final upDown = dyIn >= 0 ? 'up' : 'down';
    final leftRight = dxIn >= 0 ? 'right' : 'left';
    final headlineUnit = _correctionUnit;
    String fmt(double v, String unit) {
      switch (unit) {
        case 'mil':
          return '${v.toStringAsFixed(2)} mil';
        case 'moa':
          return '${v.toStringAsFixed(1)} MOA';
        default:
          return '${v.toStringAsFixed(1)}"';
      }
    }

    final headlineDx = headlineUnit == 'mil'
        ? dxMil
        : (headlineUnit == 'moa' ? dxMoa : dxIn.abs());
    final headlineDy = headlineUnit == 'mil'
        ? dyMil
        : (headlineUnit == 'moa' ? dyMoa : dyIn.abs());

    return Card(
      clipBehavior: Clip.antiAlias,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Icon(Icons.tune, color: theme.colorScheme.primary),
                const SizedBox(width: 8),
                Text(
                  'Last shot correction',
                  style: theme.textTheme.titleMedium,
                ),
                const Spacer(),
                Text(
                  '#${lastShot.shotNumber}',
                  style: theme.textTheme.bodySmall,
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              'Hold $upDown ${fmt(headlineDy, headlineUnit)}, '
              '$leftRight ${fmt(headlineDx, headlineUnit)} '
              'to bring next shot to ${_aimPointX == null ? "center" : "your aim"}.',
              style: theme.textTheme.titleSmall,
            ),
            const SizedBox(height: 12),
            // Unit toggle.
            SegmentedButton<String>(
              segments: const [
                ButtonSegment(value: 'mil', label: Text('MIL')),
                ButtonSegment(value: 'moa', label: Text('MOA')),
                ButtonSegment(value: 'inches', label: Text('Inches')),
              ],
              selected: {_correctionUnit},
              showSelectedIcon: false,
              onSelectionChanged: (s) {
                setState(() => _correctionUnit = s.first);
                _scheduleAutoSave();
              },
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: _smallStat(
                    'Vertical',
                    '${dyIn >= 0 ? "↑" : "↓"} '
                        '${fmt(headlineDy, headlineUnit)}',
                  ),
                ),
                Expanded(
                  child: _smallStat(
                    'Horizontal',
                    '${dxIn >= 0 ? "→" : "←"} '
                        '${fmt(headlineDx, headlineUnit)}',
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            // Single secondary unit instead of three stacked rows.
            // WHY: showing the correction in MIL + MOA + inches all at
            // once is information overload during a live session — the
            // shooter only needs the unit they actually dial, plus one
            // sanity-check unit. Pick the secondary by the user's
            // preference: mil shooters cross-reference MOA, MOA shooters
            // cross-reference mil, inches users cross-reference mil.
            Builder(builder: (context) {
              final String secondaryUnit;
              final double secondaryDx;
              final double secondaryDy;
              switch (headlineUnit) {
                case 'moa':
                  secondaryUnit = 'mil';
                  secondaryDx = dxMil;
                  secondaryDy = dyMil;
                  break;
                case 'inches':
                  secondaryUnit = 'mil';
                  secondaryDx = dxMil;
                  secondaryDy = dyMil;
                  break;
                default:
                  secondaryUnit = 'moa';
                  secondaryDx = dxMoa;
                  secondaryDy = dyMoa;
              }
              return Text(
                'In ${secondaryUnit == 'mil' ? 'MIL' : 'MOA'}: '
                '${dyIn >= 0 ? "↑" : "↓"} '
                '${fmt(secondaryDy, secondaryUnit)}  '
                '${dxIn >= 0 ? "→" : "←"} '
                '${fmt(secondaryDx, secondaryUnit)}',
                style: theme.textTheme.bodySmall,
              );
            }),
          ],
        ),
      ),
    );
  }

  // ─────────────────────── Group statistics card ───────────────────────

  /// "Group statistics" card. Below the firing-solution / hit-probability
  /// summary it answers two questions a precision shooter actually asks
  /// after a range trip:
  ///
  ///   1. How tight was this group? — extreme spread, mean radius,
  ///      group MOA, the outside-edge "caliper" measurement, and the
  ///      horizontal / vertical population standard deviations.
  ///   2. Which way is my zero off? — group centroid (offset from the
  ///      aim point) plus a "Suggested zero adjust" line that flips the
  ///      sign so the shooter can think in scope-turret directions
  ///      ("0.4" right means dial 0.4" left").
  ///
  /// Renders an empty placeholder for 0–1 shots so the card is never
  /// missing — its presence reminds users they can record more shots.
  Widget _groupStatsCard() {
    final theme = Theme.of(context);
    final yards = double.tryParse(_distanceCtrl.text) ?? 0;
    final stats = _computeGroupStats(yards);
    return Card(
      clipBehavior: Clip.antiAlias,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Icon(Icons.scatter_plot, color: theme.colorScheme.primary),
                const SizedBox(width: 8),
                Text('Group statistics',
                    style: theme.textTheme.titleMedium),
                const Spacer(),
                if (stats != null)
                  Text(
                    '${stats.shotCount}-shot group',
                    style: theme.textTheme.bodySmall,
                  ),
              ],
            ),
            const SizedBox(height: 12),
            if (stats == null)
              Text(
                _shots.isEmpty
                    ? 'Record shots on the target plot to see group statistics.'
                    : 'Need ≥2 shots to compute group statistics.',
                style: theme.textTheme.bodyMedium,
              )
            else
              _groupStatsBody(stats, yards),
          ],
        ),
      ),
    );
  }

  /// Renders the three "ES / MR / Group" rows, the SD pair, and the
  /// centroid + zero-adjust paragraph. Unit display for the MOA / MIL
  /// column tracks the per-session correction unit toggle so the user
  /// sees the numbers in the system they're already dialing the scope
  /// in.
  Widget _groupStatsBody(GroupStats stats, double yards) {
    final unit = _correctionUnit;
    String fmtAngle(double inches) {
      switch (unit) {
        case 'mil':
          return yards <= 0
              ? '—'
              : '${bu.inchesToMilAtYards(inches, yards).toStringAsFixed(2)} mil';
        case 'moa':
          return yards <= 0
              ? '—'
              : '${bu.inchesToMoaAtYards(inches, yards).toStringAsFixed(2)} MOA';
        default:
          return ''; // inches: no separate angle column
      }
    }

    final showAngleColumn = unit != 'inches';

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _groupStatRow(
          icon: Icons.adjust,
          label: 'ES',
          tooltip: 'Extreme spread (longest center-to-center)',
          inches: stats.extremeSpreadIn,
          showAngle: showAngleColumn,
          angleText: fmtAngle(stats.extremeSpreadIn),
        ),
        const SizedBox(height: 6),
        _groupStatRow(
          icon: Icons.radio_button_checked,
          label: 'Mean R',
          tooltip: 'Mean distance from each shot to the group centroid',
          inches: stats.meanRadiusIn,
          showAngle: showAngleColumn,
          angleText: fmtAngle(stats.meanRadiusIn),
        ),
        const SizedBox(height: 6),
        _groupStatRow(
          icon: Icons.crop_free,
          label: 'Group',
          tooltip: 'ES + bullet diameter (the outside-edge caliper '
              'measurement)',
          inches: stats.groupSizeIn,
          showAngle: showAngleColumn,
          angleText: fmtAngle(stats.groupSizeIn),
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(
              child: _smallStat(
                'σ horizontal',
                '${stats.horizontalSdIn.toStringAsFixed(2)}"',
              ),
            ),
            Expanded(
              child: _smallStat(
                'σ vertical',
                '${stats.verticalSdIn.toStringAsFixed(2)}"',
              ),
            ),
          ],
        ),
        if (_showCiBlock(stats)) ...[
          const SizedBox(height: 12),
          _groupStatsCiBlock(stats, yards),
        ],
        const SizedBox(height: 12),
        _zeroAdjustBlock(stats, yards),
      ],
    );
  }

  /// True when the supplied stats include a 90% CI on the true group
  /// size — i.e. the sample size is large enough that the Rayleigh
  /// quantile table publishes a multiplier (N ≥ 3).
  bool _showCiBlock(GroupStats stats) =>
      stats.groupSizeCiLow90PctIn != null &&
      stats.groupSizeCiHigh90PctIn != null;

  /// Litz-style 90% confidence-interval block. Shows the user that the
  /// observed group size has uncertainty bands that depend on sample
  /// size, and adds a small coaching caption that gets less alarming
  /// as N grows.
  ///
  /// Color coding (band + label):
  ///   N=3..4   amber  — band is wide, treat with skepticism
  ///   N=5..9   yellow — reasonable, but more shots tighten it fast
  ///   N>=10    green  — solid, diminishing returns past ~20
  ///
  /// At N<3 the band is hidden entirely (no statistically meaningful
  /// CI to publish).
  Widget _groupStatsCiBlock(GroupStats stats, double yards) {
    final theme = Theme.of(context);
    final n = stats.shotCount;
    final unit = _correctionUnit;

    // Tier classification — drives both the color and the caption.
    final ({Color band, Color text, String tier}) palette;
    if (n <= 4) {
      palette = (
        band: Colors.amber.withValues(alpha: 0.18),
        text: theme.brightness == Brightness.dark
            ? Colors.amber.shade200
            : Colors.amber.shade900,
        tier: 'wide',
      );
    } else if (n <= 9) {
      palette = (
        band: Colors.yellow.withValues(alpha: 0.18),
        text: theme.brightness == Brightness.dark
            ? Colors.yellow.shade200
            : Colors.yellow.shade900,
        tier: 'medium',
      );
    } else {
      palette = (
        band: Colors.green.withValues(alpha: 0.18),
        text: theme.brightness == Brightness.dark
            ? Colors.green.shade200
            : Colors.green.shade900,
        tier: 'tight',
      );
    }

    // Range string. If the unit toggle is "moa" or "mil" and we have a
    // distance, prefer the angular form because that's how shooters
    // discuss precision; fall back to inches otherwise.
    String rangeStr;
    if (unit == 'mil' && yards > 0) {
      final lo = bu.inchesToMilAtYards(stats.groupSizeCiLow90PctIn!, yards);
      final hi = bu.inchesToMilAtYards(stats.groupSizeCiHigh90PctIn!, yards);
      rangeStr =
          '${lo.toStringAsFixed(2)} – ${hi.toStringAsFixed(2)} mil';
    } else if (unit != 'inches' &&
        yards > 0 &&
        stats.groupMoaCiLow90Pct != null &&
        stats.groupMoaCiHigh90Pct != null) {
      // Default angular path: MOA (covers `unit == 'moa'` and any
      // future angular variant we add).
      rangeStr =
          '${stats.groupMoaCiLow90Pct!.toStringAsFixed(2)} – '
          '${stats.groupMoaCiHigh90Pct!.toStringAsFixed(2)} MOA';
    } else {
      // Inches mode, or no distance: show inches.
      rangeStr =
          '${stats.groupSizeCiLow90PctIn!.toStringAsFixed(2)}" – '
          '${stats.groupSizeCiHigh90PctIn!.toStringAsFixed(2)}"';
    }

    // Coaching caption tied to sample-size tier. Phrased as
    // observation rather than nag — Litz's whole point is that the
    // shooter should care, not that the app should hector.
    String caption;
    if (n == 3) {
      caption = 'Three shots is enough to start tracking, but the '
          'confidence band is wide. Shoot 2–7 more to halve the '
          'uncertainty.';
    } else if (n == 4) {
      caption = 'Four shots — the band is still wide. One or two more '
          'shots will tighten it noticeably.';
    } else if (n <= 9) {
      caption =
          'Reasonable sample. The CI tightens fast as you add shots.';
    } else if (n < 20) {
      caption = 'Solid sample size.';
    } else {
      caption =
          'Excellent sample size. Diminishing returns past here.';
    }

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: palette.band,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.show_chart, size: 16, color: palette.text),
              const SizedBox(width: 6),
              Text(
                '90% confidence interval',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: palette.text,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(width: 6),
              Tooltip(
                message: 'Statistical confidence interval. The narrower '
                    "this range, the more reliably your group size "
                    "represents your rifle's true precision.",
                child: Icon(
                  Icons.info_outline,
                  size: 14,
                  color: palette.text.withValues(alpha: 0.8),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            'True precision: $rangeStr',
            style: theme.textTheme.titleMedium?.copyWith(
              fontFeatures: const [FontFeature.tabularFigures()],
              color: palette.text,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            caption,
            style: theme.textTheme.bodySmall?.copyWith(
              color: palette.text.withValues(alpha: 0.9),
            ),
          ),
        ],
      ),
    );
  }

  /// One "icon · label · inches · angle" row inside the group stats body.
  /// Tooltip appears on long-press / hover so a curious shooter can see
  /// what the abbreviation stands for without cluttering the row.
  Widget _groupStatRow({
    required IconData icon,
    required String label,
    required String tooltip,
    required double inches,
    required bool showAngle,
    required String angleText,
  }) {
    final theme = Theme.of(context);
    // Map the abbreviated row label to its glossary entry so the (?)
    // tap surfaces the right definition. Soft-fails to plain Text on
    // unknown labels.
    final glossaryHint = _groupStatGlossaryHintFor(label);
    return Tooltip(
      message: tooltip,
      child: Row(
        children: [
          Icon(icon, size: 16, color: theme.colorScheme.primary),
          const SizedBox(width: 8),
          SizedBox(
            width: 72,
            child: GlossaryLabel(
              text: label,
              glossaryTerm: glossaryHint,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          Expanded(
            child: Text(
              '${inches.toStringAsFixed(2)}"',
              style: theme.textTheme.titleMedium?.copyWith(
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
          ),
          if (showAngle)
            SizedBox(
              width: 96,
              child: Text(
                angleText,
                textAlign: TextAlign.right,
                style: theme.textTheme.titleMedium?.copyWith(
                  fontFeatures: const [FontFeature.tabularFigures()],
                  color: theme.colorScheme.primary,
                ),
              ),
            ),
        ],
      ),
    );
  }

  /// "Centroid: 0.4" right, 0.2" low → Suggested zero adjust: 0.4" left
  /// (← 0.07 mil), 0.2" up (↑ 0.03 mil)" — the user-facing reverse of
  /// the centroid offset, so the shooter can directly translate the
  /// numbers into scope-turret clicks.
  Widget _zeroAdjustBlock(GroupStats stats, double yards) {
    final theme = Theme.of(context);
    final cdx = stats.centroidIn.dx;
    final cdy = stats.centroidIn.dy;
    final unit = _correctionUnit;
    String fmtIn(double v) => '${v.abs().toStringAsFixed(2)}"';
    String fmtAngle(double v) {
      switch (unit) {
        case 'mil':
          return yards <= 0
              ? ''
              : '${bu.inchesToMilAtYards(v.abs(), yards).toStringAsFixed(2)} mil';
        case 'moa':
          return yards <= 0
              ? ''
              : '${bu.inchesToMoaAtYards(v.abs(), yards).toStringAsFixed(2)} MOA';
        default:
          return '';
      }
    }

    String centroidLine;
    if (cdx.abs() < 0.05 && cdy.abs() < 0.05) {
      centroidLine = 'Centroid: on aim point';
    } else {
      final h = cdx.abs() < 0.05
          ? ''
          : '${fmtIn(cdx)} ${cdx >= 0 ? 'right' : 'left'}';
      final v = cdy.abs() < 0.05
          ? ''
          : '${fmtIn(cdy)} ${cdy >= 0 ? 'high' : 'low'}';
      final pieces = [h, v].where((s) => s.isNotEmpty).join(', ');
      centroidLine = 'Centroid: $pieces';
    }

    // Zero adjust is the reverse of the centroid: if the group is
    // 0.4" right, the user dials the scope 0.4" LEFT. Sign-flipping
    // the centroid is enough — the labels flip naturally.
    final adjustHRaw = -cdx;
    final adjustVRaw = -cdy;
    final hLabel = adjustHRaw.abs() < 0.05
        ? null
        : (adjustHRaw >= 0 ? ('right', '→') : ('left', '←'));
    final vLabel = adjustVRaw.abs() < 0.05
        ? null
        : (adjustVRaw >= 0 ? ('up', '↑') : ('down', '↓'));

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(centroidLine, style: theme.textTheme.bodyMedium),
          if (hLabel != null || vLabel != null) ...[
            const SizedBox(height: 6),
            Text(
              'Suggested zero adjust:',
              style: theme.textTheme.labelLarge?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 2),
            if (hLabel != null)
              Text(
                '${fmtIn(adjustHRaw)} ${hLabel.$1}'
                '${unit != 'inches' ? '  (${hLabel.$2} ${fmtAngle(adjustHRaw)})' : ''}',
                style: theme.textTheme.bodyMedium,
              ),
            if (vLabel != null)
              Text(
                '${fmtIn(adjustVRaw)} ${vLabel.$1}'
                '${unit != 'inches' ? '  (${vLabel.$2} ${fmtAngle(adjustVRaw)})' : ''}',
                style: theme.textTheme.bodyMedium,
              ),
          ] else ...[
            const SizedBox(height: 6),
            Text(
              'Group is centered — zero looks good.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.primary,
              ),
            ),
          ],
        ],
      ),
    );
  }

  // ─────────────────────── Sticky solution strip ───────────────────────

  /// Slim, always-visible header chip strip with the user's current
  /// firing solution at a glance:
  ///
  ///     6.5 CM · 600 yd · 8" steel
  ///     Wind 8 mph @ 9 o'clock
  ///     Hold ↑ 5.4 mil  → 0.8 mil
  ///
  /// Renders nothing until a solution is available (saves the vertical
  /// real estate while the user is still configuring the session).
  /// Lives at the top of both the phone and tablet bodies so it never
  /// scrolls off — the goal is "glance → fire → glance".
  Widget _solutionStrip() {
    final theme = Theme.of(context);
    final s = _solution;
    final dist = double.tryParse(_distanceCtrl.text.trim()) ?? 0;
    // Read instead of watch — same reason as `_sensorsHeader`. The
    // 2 Hz `_sensorsPulse` timer drives the chip refresh; subscribing
    // here would cause ~50 Hz rebuilds + the `parentDataDirty` storm.
    final cant = context.read<CantService>().cantDegrees;
    if (s == null) return const SizedBox.shrink();
    final loadLabel = _selectedLoad?.name ??
        _selectedProfile?.name ??
        (_bulletWeightCtrl.text.isEmpty
            ? 'Load'
            : '${_bulletWeightCtrl.text.trim()} gr');
    final targetLabel = _selectedTarget?.name ?? 'No target';
    final wind = double.tryParse(_windSpeedCtrl.text.trim()) ?? 0;
    final windDir = double.tryParse(_windDirCtrl.text.trim()) ?? 0;
    final clock = _windClock(windDir);
    final dropMil = bu.inchesToMilAtYards(s.dropInches, s.rangeYards);
    final windMil = bu.inchesToMilAtYards(s.windDriftInches, s.rangeYards);
    final dropMoa = bu.inchesToMoaAtYards(s.dropInches, s.rangeYards);
    final windMoa = bu.inchesToMoaAtYards(s.windDriftInches, s.rangeYards);
    final isMil = _correctionUnit == 'mil';
    final dropStr = isMil
        ? '${dropMil.toStringAsFixed(2)} mil'
        : '${dropMoa.toStringAsFixed(1)} MOA';
    final windStr = isMil
        ? '${windMil.toStringAsFixed(2)} mil'
        : '${windMoa.toStringAsFixed(1)} MOA';
    final cantWarn = cant != null && cant.abs() > 2.0;
    return Material(
      color: theme.colorScheme.surfaceContainerHighest,
      elevation: 1,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    '$loadLabel · ${dist.toStringAsFixed(0)} yd · '
                    '$targetLabel',
                    style: theme.textTheme.bodyMedium?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                if (cant != null) _bubbleLevel(cant, cantWarn),
              ],
            ),
            const SizedBox(height: 2),
            Row(
              children: [
                Icon(Icons.air, size: 14, color: theme.colorScheme.primary),
                const SizedBox(width: 4),
                Text(
                  'Wind ${wind.toStringAsFixed(0)} mph @ $clock',
                  style: theme.textTheme.bodySmall,
                ),
                const SizedBox(width: 12),
                Icon(Icons.arrow_upward,
                    size: 14, color: theme.colorScheme.primary),
                Text(' Hold $dropStr',
                    style: theme.textTheme.bodySmall?.copyWith(
                      fontFeatures: const [FontFeature.tabularFigures()],
                      fontWeight: FontWeight.w500,
                    )),
                const SizedBox(width: 12),
                Icon(
                  s.windDriftInches >= 0
                      ? Icons.arrow_forward
                      : Icons.arrow_back,
                  size: 14,
                  color: theme.colorScheme.primary,
                ),
                Text(' ${windStr.replaceFirst('-', '')}',
                    style: theme.textTheme.bodySmall?.copyWith(
                      fontFeatures: const [FontFeature.tabularFigures()],
                      fontWeight: FontWeight.w500,
                    )),
              ],
            ),
          ],
        ),
      ),
    );
  }

  /// Tiny bubble-level glyph rendered next to the firing-solution strip.
  /// Goes red when the rifle is canted more than 2°. The level is meant
  /// to be a glance-check, not a precision tool — the cant readout in
  /// the Setup → Sensors panel is the authoritative number.
  Widget _bubbleLevel(double cantDeg, bool warn) {
    final theme = Theme.of(context);
    final color = warn ? theme.colorScheme.error : theme.colorScheme.primary;
    return Tooltip(
      message: 'Cant: ${cantDeg >= 0 ? '+' : ''}${cantDeg.toStringAsFixed(1)}°'
          '${warn ? '\nLevel rifle before firing' : ''}',
      child: SizedBox(
        width: 56,
        height: 18,
        child: CustomPaint(
          painter: _BubbleLevelPainter(
            cantDeg: cantDeg,
            color: color,
            track: theme.colorScheme.outline,
          ),
        ),
      ),
    );
  }

  /// Map a "wind from" degree heading to a clock-face label like
  /// "9 o'clock" — what experienced shooters use to communicate wind.
  String _windClock(double fromDeg) {
    // 12 o'clock = 0/360, 3 o'clock = 90, 6 = 180, 9 = 270.
    final d = ((fromDeg % 360) + 360) % 360;
    final hour = ((d / 30).round() % 12);
    final h = hour == 0 ? 12 : hour;
    return "$h o'clock";
  }

  // ─────────────────────── Notes card ───────────────────────

  Widget _notesCard() {
    return Card(
      clipBehavior: Clip.antiAlias,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
        child: TextField(
          controller: _notesCtrl,
          decoration: const InputDecoration(
            border: OutlineInputBorder(),
            labelText: 'Notes',
            hintText:
                'Range conditions, holds that worked, things to try next time…',
          ),
          maxLines: 3,
          onChanged: (_) => _scheduleAutoSave(),
        ),
      ),
    );
  }
}

class _DopeHeaderCell extends StatelessWidget {
  const _DopeHeaderCell(this.text);
  final String text;
  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
      // Wrap DOPE table headers in GlossaryLabel so taps on "Drop" /
      // "Wind" / "TOF" surface the right definition modal. Range and
      // TOF soft-fail to plain Text since they have no glossary entry.
      child: GlossaryLabel(
        text: text,
        style: Theme.of(context).textTheme.bodySmall?.copyWith(
              fontWeight: FontWeight.w600,
            ),
      ),
    );
  }
}

class _DopeBodyCell extends StatelessWidget {
  const _DopeBodyCell(this.text);
  final String text;
  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
      child: Text(text, style: Theme.of(context).textTheme.bodyMedium),
    );
  }
}

enum _ShotEditResult { cancel, save, delete }

/// Small bag of "this device gave us this reading" used by the
/// _rangefinderQuickFill picker to find the freshest reading across
/// all connected rangefinders. The reading is nullable so we can build
/// the candidate list without first filtering — a tiny convenience.
class _RangefinderCandidate {
  const _RangefinderCandidate({required this.label, required this.reading});
  final String label;
  final RangefinderReading? reading;
}

/// Tiny rifle-cant bubble level. Draws a horizontal track with center
/// notches and a small bubble that floats based on the live cant angle.
/// Sized for the sticky solution strip (about 56x18 px).
class _BubbleLevelPainter extends CustomPainter {
  _BubbleLevelPainter({
    required this.cantDeg,
    required this.color,
    required this.track,
  });

  /// Signed cant angle in degrees. Positive = right tilt → bubble drifts
  /// LEFT (because the bubble in a real spirit level moves opposite the
  /// tilt). We display it that way to match a physical level the user
  /// might have on their scope rail.
  final double cantDeg;
  final Color color;
  final Color track;

  @override
  void paint(Canvas canvas, Size size) {
    final cx = size.width / 2;
    final cy = size.height / 2;
    final halfW = size.width / 2 - 4;
    // Track line.
    final trackPaint = Paint()
      ..color = track
      ..strokeWidth = 1.0
      ..style = PaintingStyle.stroke;
    canvas.drawLine(
      Offset(cx - halfW, cy),
      Offset(cx + halfW, cy),
      trackPaint,
    );
    // Center notches.
    final notch = Paint()
      ..color = track
      ..strokeWidth = 1.0;
    canvas.drawLine(
      Offset(cx - 4, cy - 5),
      Offset(cx - 4, cy + 5),
      notch,
    );
    canvas.drawLine(
      Offset(cx + 4, cy - 5),
      Offset(cx + 4, cy + 5),
      notch,
    );
    // Bubble. Cap the visible deflection at ±10° so the bubble doesn't
    // walk off the track if the phone is held sideways.
    final clamped = cantDeg.clamp(-10.0, 10.0);
    final dx = -clamped / 10.0 * halfW;
    canvas.drawCircle(
      Offset(cx + dx, cy),
      4.5,
      Paint()..color = color,
    );
  }

  @override
  bool shouldRepaint(covariant _BubbleLevelPainter old) {
    return old.cantDeg != cantDeg ||
        old.color != color ||
        old.track != track;
  }
}

/// Modal bottom sheet that renders [CommonLoadsCatalog] grouped by
/// cartridge with a search box at the top. Tapping any row pops the
/// sheet with the chosen [CommonLoad] so the caller can apply it to
/// the screen's controllers.
///
/// Stateful because the search field is interactive — every keystroke
/// filters the in-memory load list and rebuilds. The list is loaded
/// once from [ManufacturedAmmoRepository] in `initState` (~17-row
/// catalog — sub-millisecond on SQLite) and the search runs over the
/// cached in-memory copy so each keystroke stays free.
class _CommonLoadPickerSheet extends StatefulWidget {
  const _CommonLoadPickerSheet({required this.repo});

  /// Repository the sheet reads from. Provided by the caller (the
  /// Range Day screen captures it from the inherited widget tree
  /// before opening the sheet) so the sheet itself doesn't have to
  /// walk for it.
  final ManufacturedAmmoRepository repo;

  @override
  State<_CommonLoadPickerSheet> createState() =>
      _CommonLoadPickerSheetState();
}

class _CommonLoadPickerSheetState extends State<_CommonLoadPickerSheet> {
  final _searchCtrl = TextEditingController();
  String _query = '';

  /// Cached list of every load in the catalog. Populated once in
  /// `initState` from the repo. While it's null the sheet renders a
  /// spinner; if the repo returns an empty list we show the
  /// "no common loads available" hint instead of the search list.
  List<CommonLoad>? _allLoads;

  @override
  void initState() {
    super.initState();
    // ignore: discarded_futures
    _loadCatalog();
  }

  Future<void> _loadCatalog() async {
    final loads = await CommonLoadsCatalog.all(widget.repo);
    if (!mounted) return;
    setState(() => _allLoads = loads);
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  /// Group whatever loads the active query selects, preserving the
  /// catalog's natural cartridge ordering. Returns an empty map while
  /// the catalog is still loading (caller renders a spinner) or when
  /// the search query has no matches (caller renders the empty-hint).
  Map<String, List<CommonLoad>> _filteredGrouped() {
    final loads = _allLoads;
    if (loads == null) return const {};
    final q = _query.trim().toLowerCase();
    final filtered = q.isEmpty
        ? loads
        : loads.where((l) {
            if (l.cartridge.toLowerCase().contains(q)) return true;
            if (l.name.toLowerCase().contains(q)) return true;
            final n = l.notes;
            if (n != null && n.toLowerCase().contains(q)) return true;
            return false;
          }).toList(growable: false);
    final grouped = <String, List<CommonLoad>>{};
    for (final l in filtered) {
      grouped.putIfAbsent(l.cartridge, () => <CommonLoad>[]).add(l);
    }
    return grouped;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final grouped = _filteredGrouped();
    final isLoading = _allLoads == null;
    final isCatalogEmpty = _allLoads != null && _allLoads!.isEmpty;
    // Don't assert the list is non-empty — empty result for a typo
    // search query is a valid state. Render an inline empty hint
    // instead so the user can adjust the query.
    final mediaQuery = MediaQuery.of(context);
    return Padding(
      // Keyboard-safe — the sheet's content must avoid the IME
      // overlay so the search field stays visible while typing.
      padding: EdgeInsets.only(bottom: mediaQuery.viewInsets.bottom),
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: mediaQuery.size.height * 0.8,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Pick a common factory load',
                    style: theme.textTheme.titleMedium,
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'Sets BC, muzzle velocity, weight, and diameter. '
                    'Edit anything afterward.',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _searchCtrl,
                    decoration: InputDecoration(
                      prefixIcon: const Icon(Icons.search),
                      hintText: 'Search by cartridge or bullet',
                      isDense: true,
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(8),
                      ),
                      suffixIcon: _query.isEmpty
                          ? null
                          : IconButton(
                              icon: const Icon(Icons.close),
                              onPressed: () {
                                _searchCtrl.clear();
                                setState(() => _query = '');
                              },
                            ),
                    ),
                    onChanged: (v) => setState(() => _query = v),
                  ),
                ],
              ),
            ),
            const Divider(height: 1),
            Flexible(
              child: isLoading
                  ? const Padding(
                      padding: EdgeInsets.all(24),
                      child: Center(child: CircularProgressIndicator()),
                    )
                  : isCatalogEmpty
                      ? _emptyCatalogHint(theme)
                      : grouped.isEmpty
                          ? _emptySearchHint(theme)
                          : ListView(
                              padding: const EdgeInsets.symmetric(
                                  vertical: 8),
                              children: [
                                for (final cartridge in grouped.keys) ...[
                                  Padding(
                                    padding: const EdgeInsets.fromLTRB(
                                        16, 12, 16, 4),
                                    child: Text(
                                      cartridge,
                                      style: theme.textTheme.labelLarge
                                          ?.copyWith(
                                        color: theme.colorScheme.primary,
                                        fontWeight: FontWeight.w600,
                                      ),
                                    ),
                                  ),
                                  for (final load in grouped[cartridge]!)
                                    _LoadRow(
                                      load: load,
                                      onTap: () => Navigator.of(context)
                                          .pop(load),
                                    ),
                                ],
                                const SizedBox(height: 8),
                              ],
                            ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _emptySearchHint(ThemeData theme) {
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.search_off,
              size: 32,
              color: theme.colorScheme.onSurfaceVariant,
            ),
            const SizedBox(height: 8),
            Text(
              'No matches for "$_query"',
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _emptyCatalogHint(ThemeData theme) {
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.inventory_2_outlined,
              size: 32,
              color: theme.colorScheme.onSurfaceVariant,
            ),
            const SizedBox(height: 8),
            Text(
              'No common loads available yet',
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Single tappable row representing one [CommonLoad] in the picker
/// sheet. Shows the bullet name, a one-line "BC · MV · weight"
/// readout, and (when present) the load's notes.
class _LoadRow extends StatelessWidget {
  const _LoadRow({required this.load, required this.onTap});

  final CommonLoad load;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final summary =
        'BC ${load.bc.toStringAsFixed(3)} ${load.dragModel.short} · '
        'MV ${load.muzzleVelocityFps.toStringAsFixed(0)} fps · '
        '${_trimLoadWeight(load.bulletWeightGr)} gr';
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              load.name,
              style: theme.textTheme.bodyLarge,
            ),
            const SizedBox(height: 2),
            Text(
              summary,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            if (load.notes != null) ...[
              const SizedBox(height: 2),
              Text(
                load.notes!,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                  fontStyle: FontStyle.italic,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  /// Drop trailing zeros from a bullet weight so "140.0" renders as
  /// "140". Mirrors the same approach the rest of the screen uses for
  /// numeric controllers.
  static String _trimLoadWeight(double v) {
    final s = v.toStringAsFixed(1);
    return s.endsWith('.0') ? s.substring(0, s.length - 2) : s;
  }
}
