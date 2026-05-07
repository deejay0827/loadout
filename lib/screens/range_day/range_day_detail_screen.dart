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
import '../../repositories/range_day_repository.dart';
import '../../repositories/recipe_repository.dart';
import '../../repositories/reticle_repository.dart';
import '../../repositories/target_repository.dart';
import '../../services/ballistics/atmosphere.dart';
import '../../services/ballistics/drag_functions.dart';
import '../../services/ballistics/environment.dart';
import '../../services/ballistics/projectile.dart';
import '../../services/ballistics/solver.dart';
import '../../services/ballistics/units.dart' as bu;
import '../../services/ble/ble_service.dart';
import '../../services/ble/garmin_xero_service.dart';
import '../../services/ble/kestrel_service.dart';
import '../../services/hit_probability_service.dart';
import '../../services/unit_service.dart';
import '../../services/weather_service.dart';
import '../../utils/responsive.dart';
import '../../widgets/pro_gate.dart';
import '../../widgets/reticle_picker.dart';
import '../../widgets/reticle_renderer.dart';
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
    _reticlesFuture = context.read<ReticleRepository>().allReticles();
    // Default the per-session correction unit to the global angle pref.
    final units = context.read<UnitService>();
    _correctionUnit =
        units.unitFor(UnitCategory.angle).toLowerCase() == 'mrad'
            ? 'mil'
            : (units.unitFor(UnitCategory.angle).toLowerCase() == 'moa'
                ? 'moa'
                : 'mil');
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
    // ignore: discarded_futures
    _kestrelSub?.cancel();
    for (final c in [
      _distanceCtrl,
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
        shotAzimuthDegrees: 0,
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
      final samples = solveTrajectory(
        projectile: projectile,
        environment: environment,
        shot: shot,
        sampleRangesYards: ladder,
      );

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
    return SingleChildScrollView(
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
    );
  }

  /// Two-column tablet / desktop layout. Left: setup / env / solution.
  /// Right: target plot / DOPE / moving target.
  Widget _wideBody() {
    return Row(
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
      ],
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
      ],
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
    final stats = _groupStats(yards);
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
                  child: _smallStat('Group',
                      stats == null ? '—' : '${stats.groupIn.toStringAsFixed(2)}"'),
                ),
                Expanded(
                  child: _smallStat('MOA',
                      stats == null ? '—' : stats.groupMoa.toStringAsFixed(2)),
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

  /// Compute simple group statistics for the current shot impacts.
  /// Returns null if fewer than 2 shots are recorded.
  _GroupStats? _groupStats(double yards) {
    if (_shots.length < 2) return null;
    if (_selectedTarget == null) return null;
    // Convert normalized impact coords to inches on the target. Width
    // and height map to ±widthIn/2 / ±heightIn/2.
    final w = _selectedTarget!.widthIn;
    final h = _selectedTarget!.heightIn;
    final pts = <Offset>[];
    for (final s in _shots) {
      final xIn = s.impactX * (w / 2);
      final yIn = s.impactY * (h / 2);
      pts.add(Offset(xIn, yIn));
    }
    // Extreme spread = max pairwise distance.
    double maxD = 0;
    for (var i = 0; i < pts.length; i++) {
      for (var j = i + 1; j < pts.length; j++) {
        final dx = pts[i].dx - pts[j].dx;
        final dy = pts[i].dy - pts[j].dy;
        final d = math.sqrt(dx * dx + dy * dy);
        if (d > maxD) maxD = d;
      }
    }
    final moa = yards <= 0 ? 0.0 : bu.inchesToMoaAtYards(maxD, yards);
    return _GroupStats(groupIn: maxD, groupMoa: moa);
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

class _GroupStats {
  const _GroupStats({required this.groupIn, required this.groupMoa});
  final double groupIn;
  final double groupMoa;
}
