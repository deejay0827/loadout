// FILE: lib/screens/range_day/bc_truing_screen.dart
//
// ============================================================================
// WHAT THIS FILE DOES
// ============================================================================
// User-facing UI for the published BC truing methodology. Pro-gated.
//
// The user picks a load + firearm + a list of (range, observed-drop)
// pairs. The screen runs `BcTruingService.trueBcFromObservations(...)`
// in real time as the user edits the table, displays the resulting
// trued BC plus a residual table, and lets them save the result as a
// `TruedBcOverride` row keyed on (loadId, firearmId, dragModel).
//
// The "before / after" panel surfaces the catalog-vs-trued BC delta and
// the residual under each BC so the shooter can decide whether to apply
// the truing.
//
// Layout (single scrollable column):
//   1. Setup card        — load + firearm pickers, atmospheric inputs,
//                          drag model.
//   2. Observations card — table of (range, observed-drop) pairs the
//                          user can add / edit / remove.
//   3. Result card       — trued BC, before/after deltas, RMS residual,
//                          per-observation residual table.
//   4. Save card         — name + save button.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../database/database.dart';
import '../../repositories/firearm_repository.dart';
import '../../repositories/recipe_repository.dart';
import '../../services/ballistics/atmosphere.dart';
import '../../services/ballistics/drag_functions.dart';
import '../../services/ballistics/environment.dart';
import '../../services/ballistics/projectile.dart';
import '../../services/ballistics/solver.dart';
import '../../services/ballistics/units.dart' as bu;
import '../../services/bc_truing_service.dart';
import '../../widgets/range_day_safety.dart';

class BcTruingScreen extends StatefulWidget {
  const BcTruingScreen({
    super.key,
    this.initialLoadId,
    this.initialFirearmId,
  });

  final int? initialLoadId;
  final int? initialFirearmId;

  @override
  State<BcTruingScreen> createState() => _BcTruingScreenState();
}

class _BcTruingScreenState extends State<BcTruingScreen> {
  UserLoadRow? _selectedLoad;
  UserFirearmRow? _selectedFirearm;
  Future<List<UserLoadRow>>? _loadsFuture;
  Future<List<UserFirearmRow>>? _firearmsFuture;

  // Projectile baseline.
  double _bcG7 = 0.298;
  double _muzzleVelocityFps = 2710;
  double _bulletWeightGr = 140;
  final double _bulletDiameterIn = 0.264;
  final double _bulletLengthIn = 1.355;
  final double _twistInches = 8.0;
  DragModel _dragModel = DragModel.g7;

  // Environment.
  double _tempF = 59;
  double _pressureInHg = 29.92;
  double _humidityPct = 50;
  double _elevationFt = 0;

  // Shot inputs.
  double _zeroRangeYd = 100;
  double _sightHeightIn = 1.5;

  // Observations the user has entered.
  final List<_EditableObservation> _observations = [
    _EditableObservation(rangeYd: 600),
    _EditableObservation(rangeYd: 800),
    _EditableObservation(rangeYd: 1000),
  ];

  BcTruingResult? _result;
  Timer? _debounce;

  @override
  void initState() {
    super.initState();
    _loadsFuture = context.read<RecipeRepository>().watchAll().first;
    _firearmsFuture = context.read<FirearmRepository>().allFirearms();
    // Outer mounted guard — see the matching comment in
    // `hit_probability_map_screen.dart`. Protects against fast pop (user
    // opens the screen, immediately backs out before the first frame).
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted) return;
      await _hydrateInitialSelections();
      if (!mounted) return;
      _scheduleCompute();
    });
  }

  Future<void> _hydrateInitialSelections() async {
    if (widget.initialLoadId != null) {
      final loads = await _loadsFuture;
      UserLoadRow? found;
      if (loads != null) {
        for (final l in loads) {
          if (l.id == widget.initialLoadId) {
            found = l;
            break;
          }
        }
      }
      if (found != null && mounted) {
        setState(() {
          _selectedLoad = found;
          if (found!.bulletWeightGr != null) {
            _bulletWeightGr = found.bulletWeightGr!;
          }
        });
      }
    }
    if (widget.initialFirearmId != null) {
      final firearms = await _firearmsFuture;
      UserFirearmRow? found;
      if (firearms != null) {
        for (final f in firearms) {
          if (f.id == widget.initialFirearmId) {
            found = f;
            break;
          }
        }
      }
      if (found != null && mounted) {
        setState(() {
          _selectedFirearm = found;
          if (found!.defaultMuzzleVelocityFps != null) {
            _muzzleVelocityFps = found.defaultMuzzleVelocityFps!;
          }
          if (found.sightHeightIn != null) {
            _sightHeightIn = found.sightHeightIn!;
          }
          if (found.defaultZeroRangeYd != null) {
            _zeroRangeYd = found.defaultZeroRangeYd!.toDouble();
          }
        });
      }
    }
  }

  @override
  void dispose() {
    _debounce?.cancel();
    super.dispose();
  }

  void _scheduleCompute() {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 300), _compute);
  }

  void _compute() {
    if (!mounted) return;
    final svc = context.read<BcTruingService>();
    final filtered = _observations
        .where((o) => o.rangeYd > 0 && o.observedDropMil != null)
        .toList();
    if (filtered.isEmpty) {
      setState(() => _result = null);
      return;
    }
    final projectile = Projectile(
      diameterIn: _bulletDiameterIn,
      weightGr: _bulletWeightGr,
      bc: _bcG7,
      dragModel: _dragModel,
      lengthIn: _bulletLengthIn,
      twistInches: _twistInches,
    );
    final atmosphere = Atmosphere.station(
      tempF: _tempF,
      stationPressureInHg: _pressureInHg,
      humidityPct: _humidityPct,
      altitudeFt: _elevationFt,
    );
    final environment = Environment.fromImperial(
      atmosphere: atmosphere,
      windSpeedMph: 0,
      windFromDegrees: 90,
      shotAzimuthDegrees: 0,
      latitudeDegrees: 40,
      targetElevationFt: 0,
    );
    final shot = ShotInputs(
      muzzleVelocityFps: _muzzleVelocityFps,
      sightHeightIn: _sightHeightIn,
      zeroRangeYards: _zeroRangeYd,
    );

    // Annotate observations with the catalog-BC predicted drop so the
    // UI can show "before truing" alongside "after truing".
    final annotated = <BcTruingObservation>[];
    for (final o in filtered) {
      double? predicted;
      try {
        final samples = solveTrajectory(
          projectile: projectile,
          environment: environment,
          shot: shot,
          sampleRangesYards: [o.rangeYd],
          includeSpinDrift: false,
          includeCoriolis: false,
          includeAerodynamicJump: false,
          accuracy: BallisticsAccuracy.fast,
        );
        if (samples.isNotEmpty) {
          predicted = bu.inchesToMilAtYards(
            samples.first.dropInches,
            samples.first.rangeYards,
          );
        }
      } catch (_) {
        // ignore — predicted stays null
      }
      annotated.add(BcTruingObservation(
        rangeYd: o.rangeYd,
        observedDropMil: o.observedDropMil!,
        predictedDropMil: predicted,
      ));
    }

    final result = svc.trueBcFromObservations(
      nominalBc: _bcG7,
      observations: annotated,
      baselineProjectile: projectile,
      environment: environment,
      shot: shot,
    );
    setState(() => _result = result);
  }

  Future<void> _saveOverride() async {
    final result = _result;
    if (result == null) return;
    final messenger = ScaffoldMessenger.of(context);
    if (_selectedLoad == null || _selectedFirearm == null) {
      messenger.showSnackBar(
        const SnackBar(
          content: Text(
              'BC truing requires a saved load AND firearm to bind the override to.'),
        ),
      );
      return;
    }
    final db = context.read<AppDatabase>();
    final dragModelStr = _dragModelString(_dragModel);
    // Upsert — the unique key is (loadId, firearmId, dragModel).
    final loadId = _selectedLoad!.id;
    final firearmId = _selectedFirearm!.id;
    final ok = await safeAsync<bool>(
      context,
      mounted: () => mounted,
      userMessage: 'Could not save the trued BC. Please try again.',
      body: () async {
        await db.transaction(() async {
          await (db.delete(db.truedBcOverrides)
                ..where((t) => t.loadId.equals(loadId))
                ..where((t) => t.firearmId.equals(firearmId))
                ..where((t) => t.dragModel.equals(dragModelStr)))
              .go();
          await db.into(db.truedBcOverrides).insert(
                TruedBcOverridesCompanion.insert(
                  loadId: _selectedLoad!.id,
                  firearmId: _selectedFirearm!.id,
                  dragModel: dragModelStr,
                  nominalBc: result.nominalBc,
                  truedBc: result.truedBc,
                  truingDistanceYd: result.maxObservationRangeYd,
                  observationJson: result.observationJsonString(),
                  truedAt: DateTime.now(),
                ),
              );
        });
        return true;
      },
    );
    if (ok != true) return;
    if (!mounted) return;
    messenger.showSnackBar(
      SnackBar(
        content: Text(
          'Saved trued BC ${result.truedBc.toStringAsFixed(3)} '
          '(was ${result.nominalBc.toStringAsFixed(3)})',
        ),
      ),
    );
  }

  String _dragModelString(DragModel m) {
    switch (m) {
      case DragModel.g1:
        return 'g1';
      case DragModel.g2:
        return 'g2';
      case DragModel.g5:
        return 'g5';
      case DragModel.g6:
        return 'g6';
      case DragModel.g7:
        return 'g7';
      case DragModel.g8:
        return 'g8';
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('BC Truing'),
      ),
      body: RangeDayErrorBoundary(
        label: 'BC truing',
        child: SafeArea(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _setupCard(),
                const SizedBox(height: 12),
                _observationsCard(),
                const SizedBox(height: 12),
                _resultCard(),
                const SizedBox(height: 12),
                _saveCard(),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _setupCard() {
    final theme = Theme.of(context);
    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(children: [
              Icon(Icons.tune, color: theme.colorScheme.primary),
              const SizedBox(width: 8),
              Text('Setup', style: theme.textTheme.titleMedium),
            ]),
            const SizedBox(height: 4),
            Text(
              'Pick a saved load + firearm so the trued BC saves as an '
              'override on this combination. Atmospheric inputs should '
              'match the conditions when you took the dope.',
              style: theme.textTheme.bodySmall,
            ),
            const SizedBox(height: 8),
            FutureBuilder<List<UserLoadRow>>(
              future: _loadsFuture,
              builder: (context, snap) {
                if (snap.hasError) {
                  return RangeDayInlineError(
                    message: 'Could not load recipes: ${snap.error}',
                    onRetry: () {
                      setState(() {
                        _loadsFuture = context
                            .read<RecipeRepository>()
                            .watchAll()
                            .first;
                      });
                    },
                  );
                }
                final loads = snap.data ?? const [];
                return DropdownButtonFormField<UserLoadRow?>(
                  initialValue: _selectedLoad,
                  isExpanded: true,
                  decoration:
                      const InputDecoration(labelText: 'Load', isDense: true),
                  items: [
                    const DropdownMenuItem<UserLoadRow?>(
                      value: null,
                      child: Text('— pick a load —'),
                    ),
                    for (final l in loads)
                      DropdownMenuItem<UserLoadRow?>(
                        value: l,
                        child: Text(l.name, overflow: TextOverflow.ellipsis),
                      ),
                  ],
                  onChanged: (v) {
                    setState(() {
                      _selectedLoad = v;
                      if (v?.bulletWeightGr != null) {
                        _bulletWeightGr = v!.bulletWeightGr!;
                      }
                    });
                    _scheduleCompute();
                  },
                );
              },
            ),
            const SizedBox(height: 8),
            FutureBuilder<List<UserFirearmRow>>(
              future: _firearmsFuture,
              builder: (context, snap) {
                if (snap.hasError) {
                  return RangeDayInlineError(
                    message: 'Could not load firearms: ${snap.error}',
                    onRetry: () {
                      setState(() {
                        _firearmsFuture =
                            context.read<FirearmRepository>().allFirearms();
                      });
                    },
                  );
                }
                final firearms = snap.data ?? const [];
                return DropdownButtonFormField<UserFirearmRow?>(
                  initialValue: _selectedFirearm,
                  isExpanded: true,
                  decoration: const InputDecoration(
                    labelText: 'Firearm',
                    isDense: true,
                  ),
                  items: [
                    const DropdownMenuItem<UserFirearmRow?>(
                      value: null,
                      child: Text('— pick a firearm —'),
                    ),
                    for (final f in firearms)
                      DropdownMenuItem<UserFirearmRow?>(
                        value: f,
                        child: Text(f.name, overflow: TextOverflow.ellipsis),
                      ),
                  ],
                  onChanged: (v) {
                    setState(() {
                      _selectedFirearm = v;
                      if (v?.defaultMuzzleVelocityFps != null) {
                        _muzzleVelocityFps = v!.defaultMuzzleVelocityFps!;
                      }
                      if (v?.sightHeightIn != null) {
                        _sightHeightIn = v!.sightHeightIn!;
                      }
                      if (v?.defaultZeroRangeYd != null) {
                        _zeroRangeYd = v!.defaultZeroRangeYd!.toDouble();
                      }
                    });
                    _scheduleCompute();
                  },
                );
              },
            ),
            const SizedBox(height: 12),
            Row(children: [
              Expanded(
                child: _numberField(
                  label: 'BC (catalog)',
                  value: _bcG7,
                  onChanged: (v) {
                    setState(() => _bcG7 = v);
                    _scheduleCompute();
                  },
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: DropdownButtonFormField<DragModel>(
                  initialValue: _dragModel,
                  decoration: const InputDecoration(
                    labelText: 'Drag model',
                    isDense: true,
                  ),
                  items: const [
                    DropdownMenuItem(value: DragModel.g1, child: Text('G1')),
                    DropdownMenuItem(value: DragModel.g7, child: Text('G7')),
                  ],
                  onChanged: (v) {
                    if (v != null) {
                      setState(() => _dragModel = v);
                      _scheduleCompute();
                    }
                  },
                ),
              ),
            ]),
            const SizedBox(height: 8),
            Row(children: [
              Expanded(
                child: _numberField(
                  label: 'MV (fps)',
                  value: _muzzleVelocityFps,
                  onChanged: (v) {
                    setState(() => _muzzleVelocityFps = v);
                    _scheduleCompute();
                  },
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: _numberField(
                  label: 'Zero (yd)',
                  value: _zeroRangeYd,
                  onChanged: (v) {
                    setState(() => _zeroRangeYd = v);
                    _scheduleCompute();
                  },
                ),
              ),
            ]),
            const SizedBox(height: 8),
            Row(children: [
              Expanded(
                child: _numberField(
                  label: 'Temp (°F)',
                  value: _tempF,
                  onChanged: (v) {
                    setState(() => _tempF = v);
                    _scheduleCompute();
                  },
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: _numberField(
                  label: 'Pressure (inHg)',
                  value: _pressureInHg,
                  onChanged: (v) {
                    setState(() => _pressureInHg = v);
                    _scheduleCompute();
                  },
                ),
              ),
            ]),
            const SizedBox(height: 8),
            Row(children: [
              Expanded(
                child: _numberField(
                  label: 'Humidity (%)',
                  value: _humidityPct,
                  onChanged: (v) {
                    setState(() => _humidityPct = v);
                    _scheduleCompute();
                  },
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: _numberField(
                  label: 'Altitude (ft)',
                  value: _elevationFt,
                  onChanged: (v) {
                    setState(() => _elevationFt = v);
                    _scheduleCompute();
                  },
                ),
              ),
            ]),
          ],
        ),
      ),
    );
  }

  Widget _observationsCard() {
    final theme = Theme.of(context);
    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(children: [
              Icon(Icons.list_alt, color: theme.colorScheme.primary),
              const SizedBox(width: 8),
              Expanded(
                child: Text('Observations',
                    style: theme.textTheme.titleMedium),
              ),
              IconButton(
                tooltip: 'Add row',
                icon: const Icon(Icons.add),
                onPressed: () {
                  setState(() {
                    final lastRange = _observations.isEmpty
                        ? 600.0
                        : _observations.last.rangeYd + 100;
                    _observations.add(_EditableObservation(rangeYd: lastRange));
                  });
                },
              ),
            ]),
            const SizedBox(height: 4),
            Text(
              'Type the observed drop in mils at each range. The drop is '
              'what you actually had to hold or dial to hit the impact '
              'point — not the catalog prediction.',
              style: theme.textTheme.bodySmall,
            ),
            const SizedBox(height: 8),
            for (var i = 0; i < _observations.length; i++)
              _observationRow(i),
          ],
        ),
      ),
    );
  }

  Widget _observationRow(int i) {
    final obs = _observations[i];
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(children: [
        Expanded(
          flex: 3,
          child: TextFormField(
            initialValue: obs.rangeYd > 0 ? obs.rangeYd.toStringAsFixed(0) : '',
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: const InputDecoration(
              labelText: 'Range (yd)',
              isDense: true,
            ),
            onChanged: (s) {
              final v = double.tryParse(s);
              if (v != null && v > 0) {
                obs.rangeYd = v;
                _scheduleCompute();
              }
            },
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          flex: 4,
          child: TextFormField(
            initialValue: obs.observedDropMil?.toStringAsFixed(2) ?? '',
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: const InputDecoration(
              labelText: 'Observed drop (mil)',
              isDense: true,
            ),
            onChanged: (s) {
              obs.observedDropMil = double.tryParse(s);
              _scheduleCompute();
            },
          ),
        ),
        IconButton(
          tooltip: 'Remove',
          icon: const Icon(Icons.delete_outline),
          onPressed: () {
            setState(() => _observations.removeAt(i));
            _scheduleCompute();
          },
        ),
      ]),
    );
  }

  Widget _resultCard() {
    final theme = Theme.of(context);
    final result = _result;
    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(children: [
              Icon(Icons.assessment, color: theme.colorScheme.primary),
              const SizedBox(width: 8),
              Text('Trued BC', style: theme.textTheme.titleMedium),
            ]),
            const SizedBox(height: 8),
            if (result == null)
              Text(
                'Add at least one observation to compute the trued BC.',
                style: theme.textTheme.bodyMedium,
              )
            else ...[
              Row(children: [
                _bigStat(
                  'Catalog BC',
                  result.nominalBc.toStringAsFixed(3),
                ),
                const SizedBox(width: 16),
                _bigStat(
                  'Trued BC',
                  result.truedBc.toStringAsFixed(3),
                ),
                const SizedBox(width: 16),
                _bigStat(
                  'Δ',
                  '${result.truedBc - result.nominalBc >= 0 ? '+' : ''}'
                      '${(result.truedBc - result.nominalBc).toStringAsFixed(3)}',
                ),
              ]),
              const SizedBox(height: 12),
              Text(
                'RMS residual under the trued BC: '
                '${result.rmsResidualMil.toStringAsFixed(3)} mil',
                style: theme.textTheme.bodyMedium,
              ),
              const SizedBox(height: 8),
              Text(
                'Per-observation residuals (predicted under trued BC '
                'minus observed):',
                style: theme.textTheme.bodySmall,
              ),
              const SizedBox(height: 4),
              for (var i = 0; i < result.observations.length; i++)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 2),
                  child: Row(children: [
                    SizedBox(
                      width: 70,
                      child: Text(
                        '${result.observations[i].rangeYd.toStringAsFixed(0)} yd',
                        style: theme.textTheme.bodyMedium,
                      ),
                    ),
                    Expanded(
                      child: Text(
                        'observed ${result.observations[i].observedDropMil.toStringAsFixed(2)} mil'
                        '${result.observations[i].predictedDropMil != null ? ' · catalog ${result.observations[i].predictedDropMil!.toStringAsFixed(2)}' : ''}',
                        style: theme.textTheme.bodySmall,
                      ),
                    ),
                    Text(
                      '${result.residualsMil[i] >= 0 ? '+' : ''}'
                      '${result.residualsMil[i].toStringAsFixed(3)} mil',
                      style: theme.textTheme.bodyMedium?.copyWith(
                        fontFeatures: const [FontFeature.tabularFigures()],
                      ),
                    ),
                  ]),
                ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _bigStat(String label, String value) {
    final theme = Theme.of(context);
    return Expanded(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: theme.textTheme.bodySmall),
          Text(
            value,
            style: theme.textTheme.headlineSmall?.copyWith(
              fontFeatures: const [FontFeature.tabularFigures()],
              color: theme.colorScheme.primary,
            ),
          ),
        ],
      ),
    );
  }

  Widget _saveCard() {
    final theme = Theme.of(context);
    final canSave = _result != null &&
        _selectedLoad != null &&
        _selectedFirearm != null;
    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(children: [
              Icon(Icons.save_outlined, color: theme.colorScheme.primary),
              const SizedBox(width: 8),
              Text('Apply override', style: theme.textTheme.titleMedium),
            ]),
            const SizedBox(height: 4),
            Text(
              'The trued BC will replace the catalog BC for this load × '
              'firearm × drag model when the solver runs.',
              style: theme.textTheme.bodySmall,
            ),
            const SizedBox(height: 12),
            FilledButton.icon(
              icon: const Icon(Icons.save),
              label: const Text('Save trued BC'),
              onPressed: canSave ? _saveOverride : null,
            ),
          ],
        ),
      ),
    );
  }

  Widget _numberField({
    required String label,
    required double value,
    required ValueChanged<double> onChanged,
  }) {
    return TextFormField(
      initialValue: value.toString(),
      keyboardType: const TextInputType.numberWithOptions(decimal: true),
      decoration: InputDecoration(labelText: label, isDense: true),
      onChanged: (s) {
        final v = double.tryParse(s);
        if (v != null) onChanged(v);
      },
    );
  }
}

class _EditableObservation {
  _EditableObservation({required this.rangeYd});
  double rangeYd;
  double? observedDropMil;
}
