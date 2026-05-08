// FILE: lib/screens/range_day/range_day_detail_screen.dart
//
// ============================================================================
// WHAT THIS FILE DOES
// ============================================================================
// The Range Day workspace itself — the screen the user lives in WHILE at the
// range. Renders five collapsible sections in a single scrollable column on
// phones, and a two-column layout on tablets / desktops:
//
//   1. Setup        — target / distance / profile / load / firearm pickers.
//                     Collapses to a one-line summary after first save so
//                     the user isn't staring at five dropdowns mid-session.
//   2. Environment  — temp, pressure, humidity, elevation, wind. Pull-from-
//                     weather button (Pro). Collapses similarly.
//   3. Solution     — firing solution computed from the active inputs.
//                     Drop, wind, time of flight, velocity, energy. The
//                     biggest text on the screen — readable at arm's length.
//   4. Target plot  — visual target with tap-to-record shots. Group stats
//                     under the plot.
//   5. Moving target (Pro) — speed + direction inputs that compute lead
//                            in mil / MOA / inches.
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

import '../../data/reticle_library.dart';
import '../../database/database.dart';
import '../../repositories/ballistic_profile_repository.dart';
import '../../repositories/firearm_repository.dart';
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
import '../../services/ble/ble_service.dart';
import '../../services/ble/bushnell_rangefinder_service.dart';
import '../../services/ble/garmin_xero_service.dart';
import '../../services/ble/kestrel_service.dart';
import '../../services/ble/leica_geovid_service.dart';
import '../../services/ble/rangefinder_reading.dart';
import '../../services/ble/sig_kilo_service.dart';
import '../../services/ble/vortex_rangefinder_service.dart';
import '../../services/entitlement_notifier.dart';
import '../../services/hit_probability_service.dart';
import '../../services/sensors/cant_service.dart';
import '../../services/sensors/inclinometer_service.dart';
import '../../services/sensors/magnetometer_service.dart';
import '../../services/unit_service.dart';
import '../../services/weather_service.dart';
import '../../utils/responsive.dart';
import '../../widgets/pro_gate.dart';
import '../../widgets/reticle_picker.dart';
import 'scope_view_screen.dart';
import 'widgets/target_plot.dart';

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

  BallisticProfileRow? _selectedProfile;
  Stream<List<BallisticProfileRow>>? _profilesStream;

  UserLoadRow? _selectedLoad;
  Future<List<UserLoadRow>>? _loadsFuture;

  UserFirearmRow? _selectedFirearm;
  Future<List<UserFirearmRow>>? _firearmsFuture;

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

  // ─────────────────────── Moving target (Pro) ───────────────────────
  final _moverSpeedCtrl = TextEditingController(text: '3');
  /// 'rtl' (right-to-left), 'ltr' (left-to-right). Used to flip lead sign.
  String _moverDirection = 'rtl';

  // ─────────────────────── Section collapse ───────────────────────
  bool _setupExpanded = true;
  bool _environmentExpanded = true;
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

  // ─────────────────────── Captured sensor readings (v13) ───────────────────────
  /// Captured cant (rifle level) at the time the user tapped "Capture
  /// current readings". Null means no capture has been performed for
  /// this session yet. Persists to `RangeDaySessions.cantDegrees` so
  /// reopening the session shows the value that was active at the
  /// time of capture, even if the device has since moved.
  // ignore: unused_field
  double? _capturedCantDeg;
  /// Captured shot azimuth (compass heading) at the time of capture.
  /// Mirrored into the `_shotAzimuthCtrl` field at capture time and
  /// persisted to `RangeDaySessions.shotAzimuthDegrees`.
  // ignore: unused_field
  double? _capturedAzimuthDeg;
  /// Wall-clock when the user last tapped "Capture current readings".
  /// Drives the "Captured 12s ago" caption in the Sensors panel. Not
  /// persisted — purely a UI nicety for the active session.
  // ignore: unused_field
  DateTime? _capturedAt;

  /// Latest hit-probability result. Recomputed lazily (300ms debounce).
  HitProbabilityResult? _hitProb;
  Timer? _hitProbDebounce;

  @override
  void initState() {
    super.initState();
    _targetsFuture = context.read<TargetRepository>().allTargets();
    _profilesStream = context.read<BallisticProfileRepository>().watchAll();
    _loadsFuture = _loadAllRecipes();
    _firearmsFuture = context.read<FirearmRepository>().allFirearms();
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
    }
  }

  Future<List<UserLoadRow>> _loadAllRecipes() async {
    final repo = context.read<RecipeRepository>();
    final stream = repo.watchAll();
    final first = await stream.first;
    return first;
  }

  Future<void> _hydrateFromSession(int id) async {
    // Capture every repository up front so we don't reach into the
    // BuildContext after an `await`.
    final rangeDayRepo = context.read<RangeDayRepository>();
    final targetRepo = context.read<TargetRepository>();
    final profileRepo = context.read<BallisticProfileRepository>();
    final firearmRepo = context.read<FirearmRepository>();
    final recipeRepo = context.read<RecipeRepository>();
    final reticleRepo = context.read<ReticleRepository>();

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
      _correctionUnit =
          (s.correctionUnit.isEmpty ? 'mil' : s.correctionUnit);
      // v13 — captured cant + azimuth. If the previous save included a
      // captured shot azimuth, mirror it into the editable text field
      // so the field reflects the persisted value when the session is
      // re-opened. Cant is *display-only* in the captured row; the
      // solver always uses the live CantService value if cant
      // correction is enabled.
      _capturedCantDeg = s.cantDegrees;
      _capturedAzimuthDeg = s.shotAzimuthDegrees;
      if (s.shotAzimuthDegrees != null) {
        _shotAzimuthCtrl.text =
            s.shotAzimuthDegrees!.toStringAsFixed(0);
      }
      // v15 ballistic precision — incline / decline angle.
      if (s.inclineAngleDeg != null) {
        _inclineAngleCtrl.text = s.inclineAngleDeg!.toStringAsFixed(1);
      }
      _setupExpanded = false;
      _environmentExpanded = false;
    });
    // Resolve the foreign keys now that we know we're editing.
    if (s.targetId != null) {
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
    // v11 — hydrate reticle (if any).
    if (s.reticleId != null) {
      final reticleRow = await reticleRepo.byId(s.reticleId!);
      if (mounted && reticleRow != null) {
        setState(() {
          _selectedReticleRow = reticleRow;
          _selectedReticle = reticleRepo.definitionFromRow(reticleRow);
        });
      }
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
    _scheduleSolve();
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
    final target = _selectedTarget;
    if (target == null) {
      setState(() => _hitProb = null);
      return;
    }
    final widthIn = target.widthIn;
    final heightIn = target.heightIn;
    final shape = parseTargetShape(target.shape);
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
      });
    } on FormatException catch (e) {
      setState(() {
        _solveError = e.message;
        _solution = null;
        _dopeRows = const [];
      });
    } catch (e) {
      setState(() {
        _solveError = 'Could not solve: $e';
        _solution = null;
        _dopeRows = const [];
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
    final defaultName = _selectedTarget == null
        ? 'Range day · ${distance.toStringAsFixed(0)} yd'
        : '${_selectedTarget!.name} · ${distance.toStringAsFixed(0)} yd';
    return RangeDaySessionsCompanion(
      name: drift.Value(_session?.name ?? defaultName),
      date: drift.Value(_session?.date ?? DateTime.now()),
      notes: drift.Value(_notesCtrl.text.trim().isEmpty
          ? null
          : _notesCtrl.text.trim()),
      ballisticProfileId: drift.Value(_selectedProfile?.id),
      recipeId: drift.Value(_selectedLoad?.id),
      firearmId: drift.Value(_selectedFirearm?.id),
      targetId: drift.Value(_selectedTarget?.id),
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
    );
  }

  Future<void> _saveSession({bool collapseSetup = false}) async {
    final repo = context.read<RangeDayRepository>();
    final messenger = ScaffoldMessenger.of(context);
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
    notesCtrl.dispose();
    velCtrl.dispose();
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
    await repo.clearShotsForSession(_session!.id);
    if (!mounted) return;
    setState(() => _shots = const []);
    messenger.showSnackBar(
      const SnackBar(content: Text('Shots cleared.')),
    );
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
      });
      _scheduleSolve();
      _scheduleAutoSave();
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
    final kestrel = context.read<KestrelService>();
    if (kestrel.device == null) return;
    await _kestrelSub?.cancel();
    _kestrelSub = kestrel.readings.listen(_applyKestrelReading);
    setState(() => _useKestrel = true);
    final last = kestrel.lastReading;
    if (last != null) _applyKestrelReading(last);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Pulling live data from Kestrel.')),
    );
  }

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
    final scaffoldTitle = _session?.name ?? 'New Range Day';
    return Scaffold(
      appBar: AppBar(
        title: Text(
          scaffoldTitle,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        actions: [
          IconButton(
            tooltip: 'Recalculate',
            icon: const Icon(Icons.refresh),
            onPressed: _solve,
          ),
        ],
      ),
      body: SafeArea(
        child: isWide ? _wideBody() : _phoneBody(),
      ),
    );
  }

  /// Single-column phone layout.
  Widget _phoneBody() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _solutionStrip(),
        Expanded(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _setupCard(),
                const SizedBox(height: 12),
                _environmentCard(),
                const SizedBox(height: 12),
                _solutionCard(),
                const SizedBox(height: 12),
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
            ),
          ),
        ),
      ],
    );
  }

  /// Two-column tablet / desktop layout. Left: setup / env / solution.
  /// Right: target plot / DOPE / moving target.
  Widget _wideBody() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _solutionStrip(),
        Expanded(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                flex: 5,
                child: SingleChildScrollView(
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
                      _groupStatsCard(),
                      const SizedBox(height: 12),
                      _hitProbCard(),
                      const SizedBox(height: 12),
                      _notesCard(),
                    ],
                  ),
                ),
              ),
              Expanded(
                flex: 6,
                child: SingleChildScrollView(
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
    if (_selectedTarget != null) parts.add(_selectedTarget!.name);
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
        labelText: 'Shot azimuth (°)',
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
                labelText: 'Incline / decline angle (°)',
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
                child: Row(
                  children: [
                    OutlinedButton.icon(
                      onPressed: _captureInclineFromSensor,
                      icon: const Icon(Icons.straighten, size: 16),
                      label: const Text('Capture from sensor'),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Builder(builder: (ctx) {
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
                    ),
                  ],
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
  Widget _captureEnvironmentFromSensorsButton() {
    final theme = Theme.of(context);
    return Card(
      margin: EdgeInsets.zero,
      color: theme.colorScheme.surfaceContainerHigh,
      child: Padding(
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
              'Pulls GPS lat/lon, altitude, station pressure, true '
              'azimuth (compass), cant (rifle level), and incline (slope '
              'of fire) into the session in one tap.',
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
      ),
    );
  }

  /// Handler for the consolidated "Capture environment from sensors"
  /// button. Walks the live sensors + GPS handshake, then surfaces a
  /// detailed snackbar so the user sees what was captured.
  Future<void> _captureEnvironmentFromSensors() async {
    final messenger = ScaffoldMessenger.of(context);
    final cantSvc = context.read<CantService>();
    final magSvc = context.read<MagnetometerService>();
    final inclineSvc = context.read<InclinometerService>();
    final cant = cantSvc.cantDegrees;
    final heading = magSvc.headingDegrees;
    final incline = inclineSvc.inclineDegrees;
    // Pull location-derived values via the existing weather service —
    // it already wraps the geolocator handshake AND reports station
    // pressure + altitude in one round trip.
    WeatherFetchResult? weather;
    try {
      weather = await WeatherService().fetchForCurrentLocation();
    } on WeatherFetchException catch (e) {
      messenger.showSnackBar(SnackBar(content: Text(e.userMessage)));
    } catch (_) {
      messenger.showSnackBar(
        const SnackBar(content: Text('Couldn\'t fetch weather.')),
      );
    }
    if (!mounted) return;
    setState(() {
      _capturedCantDeg = cant;
      _capturedAzimuthDeg = heading;
      _capturedAt = DateTime.now();
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
    messenger.showSnackBar(
      SnackBar(
        duration: const Duration(seconds: 6),
        content: Text(summary),
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
    final cant = context.watch<CantService>().cantDegrees;
    final cantAvail = context.watch<CantService>().isAvailable;
    final heading = context.watch<MagnetometerService>().headingDegrees;
    final headingAvail = context.watch<MagnetometerService>().isAvailable;
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
                Text('Cant', style: theme.textTheme.titleSmall),
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
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
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
                  ),
                  if (cantSvc.calibrationOffsetDeg.abs() > 0.05) ...[
                    const SizedBox(width: 8),
                    IconButton(
                      tooltip: 'Clear calibration',
                      icon: const Icon(Icons.refresh, size: 20),
                      onPressed: cantSvc.clearCalibration,
                    ),
                  ],
                ],
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
                Text('Heading', style: theme.textTheme.titleSmall),
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
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
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
                  ),
                ],
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
    return ReticlePickerField(
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
                    label: 'Group at 100 yd',
                    suffix: 'MOA',
                    value: _assumedGroupMoa,
                    onChanged: (v) {
                      setState(() => _assumedGroupMoa = v);
                      _scheduleHitProb();
                      _scheduleAutoSave();
                    },
                  ),
                  const SizedBox(height: 8),
                  _capabilityNumberField(
                    label: 'Wind uncertainty',
                    suffix: '± mph',
                    value: _windUncertaintyMph,
                    onChanged: (v) {
                      setState(() => _windUncertaintyMph = v);
                      _scheduleHitProb();
                      _scheduleAutoSave();
                    },
                  ),
                  const SizedBox(height: 8),
                  _capabilityNumberField(
                    label: 'Range uncertainty',
                    suffix: '± yd',
                    value: _rangeUncertaintyYd,
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

  Widget _capabilityNumberField({
    required String label,
    required String suffix,
    required double value,
    required void Function(double) onChanged,
  }) {
    final ctrl = TextEditingController(text: _trimZeros(value));
    return TextField(
      controller: ctrl,
      keyboardType:
          const TextInputType.numberWithOptions(decimal: true),
      decoration: InputDecoration(
        border: const OutlineInputBorder(),
        labelText: label,
        suffixText: suffix,
        isDense: true,
      ),
      onChanged: (s) {
        final v = double.tryParse(s.trim());
        if (v != null && v >= 0) onChanged(v);
      },
    );
  }

  Widget _targetPicker() {
    final categories = ['all', 'paper', 'steel', 'reactive', 'game-silhouette'];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('Target', style: Theme.of(context).textTheme.labelLarge),
        const SizedBox(height: 6),
        Wrap(
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
        const SizedBox(height: 8),
        FutureBuilder<List<TargetRow>>(
          future: _targetsFuture,
          builder: (context, snap) {
            if (snap.connectionState == ConnectionState.waiting) {
              return const LinearProgressIndicator();
            }
            final all = snap.data ?? const <TargetRow>[];
            final filtered = _targetCategoryFilter == 'all'
                ? all
                : all.where((t) => t.category == _targetCategoryFilter).toList();
            if (filtered.isEmpty) {
              return Text(
                'No targets in this category yet.',
                style: Theme.of(context).textTheme.bodySmall,
              );
            }
            return DropdownButtonFormField<int?>(
              initialValue: _selectedTarget?.id,
              isExpanded: true,
              decoration: const InputDecoration(
                border: OutlineInputBorder(),
                hintText: 'Pick a target',
              ),
              items: [
                const DropdownMenuItem<int?>(
                  value: null,
                  child: Text('— None —'),
                ),
                ...filtered.map((t) => DropdownMenuItem<int?>(
                      value: t.id,
                      child: Text(
                        t.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    )),
              ],
              onChanged: (id) {
                final picked = id == null
                    ? null
                    : filtered.firstWhere((t) => t.id == id);
                setState(() => _selectedTarget = picked);
                _scheduleAutoSave();
              },
            );
          },
        ),
      ],
    );
  }

  Widget _distancePicker() {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('Distance (yd)', style: theme.textTheme.labelLarge),
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
        Wrap(
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
        _rangefinderQuickFill(),
      ],
    );
  }

  /// "Use last reading" affordance — if any of the four supported BLE
  /// rangefinder adapters is connected and has a recent measurement,
  /// surface a button to drop that value into the distance input.
  ///
  /// Picks the freshest reading across all connected rangefinders so a
  /// user with two paired devices still gets a sensible default. Hidden
  /// entirely when no rangefinder is connected — the picker has plenty
  /// of clutter without an always-on disabled button.
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
              '${freshest.label}: ${yards.toStringAsFixed(0)} yd · $freshLabel',
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
              });
              _scheduleSolve();
              _scheduleAutoSave();
            },
            child: const Text('Use last reading'),
          ),
        ],
      ),
    );
  }

  Widget _profilePicker() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          'Ballistic profile',
          style: Theme.of(context).textTheme.labelLarge,
        ),
        const SizedBox(height: 6),
        StreamBuilder<List<BallisticProfileRow>>(
          stream: _profilesStream,
          builder: (context, snap) {
            final profiles = snap.data ?? const <BallisticProfileRow>[];
            return DropdownButtonFormField<int?>(
              initialValue: _selectedProfile?.id,
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
                ...profiles.map((p) => DropdownMenuItem<int?>(
                      value: p.id,
                      child: Text(p.name,
                          maxLines: 1, overflow: TextOverflow.ellipsis),
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
            );
          },
        ),
      ],
    );
  }

  Widget _loadPicker() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('Load', style: Theme.of(context).textTheme.labelLarge),
        const SizedBox(height: 6),
        FutureBuilder<List<UserLoadRow>>(
          future: _loadsFuture,
          builder: (context, snap) {
            final loads = snap.data ?? const <UserLoadRow>[];
            return DropdownButtonFormField<int?>(
              initialValue: _selectedLoad?.id,
              isExpanded: true,
              decoration: const InputDecoration(
                border: OutlineInputBorder(),
                hintText: 'Optional — link a recipe',
              ),
              items: [
                const DropdownMenuItem<int?>(
                  value: null,
                  child: Text('— None —'),
                ),
                ...loads.map((l) => DropdownMenuItem<int?>(
                      value: l.id,
                      child: Text(l.name,
                          maxLines: 1, overflow: TextOverflow.ellipsis),
                    )),
              ],
              onChanged: (id) {
                if (id == null) {
                  setState(() => _selectedLoad = null);
                  _scheduleAutoSave();
                  return;
                }
                final l = loads.firstWhere((l) => l.id == id);
                setState(() => _selectedLoad = l);
                _applyLoadDefaults(l);
                _scheduleAutoSave();
              },
            );
          },
        ),
      ],
    );
  }

  Widget _firearmPicker() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('Firearm', style: Theme.of(context).textTheme.labelLarge),
        const SizedBox(height: 6),
        FutureBuilder<List<UserFirearmRow>>(
          future: _firearmsFuture,
          builder: (context, snap) {
            final firearms = snap.data ?? const <UserFirearmRow>[];
            return DropdownButtonFormField<int?>(
              initialValue: _selectedFirearm?.id,
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
                ...firearms.map((f) => DropdownMenuItem<int?>(
                      value: f.id,
                      child: Text(f.name,
                          maxLines: 1, overflow: TextOverflow.ellipsis),
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
            );
          },
        ),
      ],
    );
  }

  // ─────────────────────── Environment card ───────────────────────

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
          Consumer<KestrelService>(
            builder: (ctx, kestrel, _) {
              if (kestrel.device == null) return const SizedBox.shrink();
              if (_useKestrel) {
                return Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Row(
                    children: [
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed: _onStopUsingKestrel,
                          icon: const Icon(Icons.bluetooth_connected),
                          label: const Text('Stop using Kestrel'),
                        ),
                      ),
                    ],
                  ),
                );
              }
              return Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Row(
                  children: [
                    Expanded(
                      child: FilledButton.icon(
                        onPressed: _onStartUsingKestrel,
                        icon: const Icon(Icons.bluetooth),
                        label: const Text('Use Kestrel readings'),
                      ),
                    ),
                  ],
                ),
              );
            },
          ),
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
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
              ),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: _onImportGarminFit,
                  icon: const Icon(Icons.speed),
                  label: const Text('Import Garmin .fit (Pro)'),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _envField(
      TextEditingController controller, String label, String suffix) {
    return TextField(
      controller: controller,
      keyboardType:
          const TextInputType.numberWithOptions(signed: true, decimal: true),
      decoration: InputDecoration(
        border: const OutlineInputBorder(),
        labelText: label,
        suffixText: suffix,
        isDense: true,
      ),
      onChanged: (_) {
        _scheduleSolve();
        _scheduleAutoSave();
      },
    );
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
                Text('Firing solution',
                    style: theme.textTheme.titleMedium),
              ],
            ),
            const SizedBox(height: 12),
            if (_solveError != null)
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: theme.colorScheme.errorContainer,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  _solveError!,
                  style: TextStyle(color: theme.colorScheme.onErrorContainer),
                ),
              )
            else if (_solution == null)
              Text('Solving…', style: theme.textTheme.bodyMedium)
            else
              _solutionBody(_solution!),
          ],
        ),
      ),
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
    final spec = _selectedTarget == null
        ? TargetSpec.defaultPaper()
        : TargetSpec.fromRow(_selectedTarget!);
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
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => ScopeViewScreen(inputs: inputs),
      ),
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
            child: Text(
              label,
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
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            )),
        Text(value,
            style: theme.textTheme.titleMedium?.copyWith(
              fontFeatures: const [FontFeature.tabularFigures()],
            )),
      ],
    );
  }

  // ─────────────────────── DOPE card ───────────────────────

  Widget _dopeCard() {
    final theme = Theme.of(context);
    if (_dopeRows.isEmpty) {
      return Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Text('DOPE table will appear once a solution computes.',
              style: theme.textTheme.bodyMedium),
        ),
      );
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
    if (_selectedTarget != null) buf.writeln('Target: ${_selectedTarget!.name}');
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
    await Clipboard.setData(ClipboardData(text: buf.toString()));
    if (!mounted) return;
    messenger.showSnackBar(
      const SnackBar(content: Text('DOPE copied to clipboard')),
    );
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
            const SizedBox(height: 12),
            if (_shotsStream != null)
              StreamBuilder<List<ShotImpactRow>>(
                stream: _shotsStream,
                initialData: _shots,
                builder: (context, snap) {
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
                    aimPointX: _aimPointX,
                    aimPointY: _aimPointY,
                    onAimPointSet: _setAimPoint,
                    reticle: _selectedReticle,
                    reticleDisplayUnit: reticleUnit,
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
                aimPointX: _aimPointX,
                aimPointY: _aimPointY,
                onAimPointSet: _setAimPoint,
                reticle: _selectedReticle,
                reticleDisplayUnit: reticleUnit,
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
                Text('Hit probability',
                    style: theme.textTheme.titleMedium),
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
            Text(
              'In MIL: ${dyIn >= 0 ? "↑" : "↓"} '
              '${dyMil.toStringAsFixed(2)} mil  '
              '${dxIn >= 0 ? "→" : "←"} '
              '${dxMil.toStringAsFixed(2)} mil',
              style: theme.textTheme.bodySmall,
            ),
            Text(
              'In MOA: ${dyIn >= 0 ? "↑" : "↓"} '
              '${dyMoa.toStringAsFixed(1)} MOA  '
              '${dxIn >= 0 ? "→" : "←"} '
              '${dxMoa.toStringAsFixed(1)} MOA',
              style: theme.textTheme.bodySmall,
            ),
            Text(
              'In inches at ${dist.toStringAsFixed(0)} yd: '
              '${dyIn >= 0 ? "↑" : "↓"} ${dyIn.abs().toStringAsFixed(1)}"  '
              '${dxIn >= 0 ? "→" : "←"} ${dxIn.abs().toStringAsFixed(1)}"',
              style: theme.textTheme.bodySmall,
            ),
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
        const SizedBox(height: 12),
        _zeroAdjustBlock(stats, yards),
      ],
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
    return Tooltip(
      message: tooltip,
      child: Row(
        children: [
          Icon(icon, size: 16, color: theme.colorScheme.primary),
          const SizedBox(width: 8),
          SizedBox(
            width: 64,
            child: Text(label,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                )),
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
    final cant = context.watch<CantService>().cantDegrees;
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
      child: Text(text,
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
                fontWeight: FontWeight.w600,
              )),
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
