// FILE: lib/screens/range_day/hit_probability_map_screen.dart
//
// ============================================================================
// WHAT THIS FILE DOES
// ============================================================================
// User-facing screen for the Hit Probability Map feature (formerly known
// internally as "WEZ" — Weapon Employment Zone). The user picks a load +
// firearm + target, tunes their uncertainty inputs, and sees a
// hit-probability-vs-range curve plus the variance contribution
// breakdown. Pro-gated.
//
// Layout (single scrollable column):
//   1. Setup card        — load, firearm, target, projectile inputs.
//   2. Inputs card       — group MOA, wind ±, range ±, MV SD sliders.
//   3. Curve card        — `HitProbabilityMapCurvePainter` plot of hit %
//                          vs range.
//   4. Bands card        — "≥ 90% hit out to X yd" thresholds.
//   5. Breakdown card    — variance contribution at the reference range.
//   6. Save button       — persist the result to `WezProfiles` (the drift
//                          table name is preserved for storage compat;
//                          renaming requires a schema migration).
//
// The curve recomputes lazily after a 400ms debounce. The Pro gate is
// applied once at the route entry point (see `range_day_detail_screen`'s
// "Hit Probability Map" button); we don't double-gate the screen body —
// the user can't get here without already being Pro or having dismissed
// the paywall.
//
// All math comes from `HitProbabilityMapService`; this file only owns
// presentation, debounced state management, and persistence.

import 'dart:async';

import 'package:drift/drift.dart' show Value;
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../database/database.dart';
import '../../repositories/firearm_repository.dart';
import '../../repositories/recipe_repository.dart';
import '../../repositories/target_repository.dart';
import '../../services/hit_probability_map_service.dart';
import '../../services/hit_probability_service.dart';
import '../../widgets/range_day_safety.dart';

class HitProbabilityMapScreen extends StatefulWidget {
  const HitProbabilityMapScreen({
    super.key,
    this.initialLoadId,
    this.initialFirearmId,
    this.initialTargetId,
    this.initialDistanceYd,
  });

  /// Optionally pre-select an active recipe.
  final int? initialLoadId;

  /// Optionally pre-select an active firearm.
  final int? initialFirearmId;

  /// Optionally pre-select a target shape.
  final int? initialTargetId;

  /// If supplied, drives the variance-breakdown reference range and the
  /// chart's vertical highlight bar.
  final double? initialDistanceYd;

  @override
  State<HitProbabilityMapScreen> createState() =>
      _HitProbabilityMapScreenState();
}

class _HitProbabilityMapScreenState extends State<HitProbabilityMapScreen> {
  // ─────────────────────── Setup pickers ───────────────────────
  UserLoadRow? _selectedLoad;
  UserFirearmRow? _selectedFirearm;
  TargetRow? _selectedTarget;
  Future<List<UserLoadRow>>? _loadsFuture;
  Future<List<UserFirearmRow>>? _firearmsFuture;
  Future<List<TargetRow>>? _targetsFuture;

  // ─────────────────────── Projectile / shot inputs ───────────────────────
  // Filled from the picked load + firearm; user can override.
  double _bcG7 = 0.298;
  double _muzzleVelocityFps = 2710;
  double _bulletWeightGr = 140;
  double _bulletDiameterIn = 0.264;

  // ─────────────────────── Range band ───────────────────────
  final double _rangeMinYd = 100;
  final double _rangeMaxYd = 1500;
  final double _rangeStepYd = 25;

  // ─────────────────────── Uncertainty inputs ───────────────────────
  double _groupMoa = 1.0;
  double _windUncertaintyMph = 2.0;
  double _rangeUncertaintyYd = 5.0;
  double _mvSdFps = 12.0;

  // ─────────────────────── Reference range (for breakdown) ───────────────────────
  double _referenceRangeYd = 600;

  // ─────────────────────── Computed result ───────────────────────
  HitProbabilityMapResult? _result;
  Timer? _debounce;
  bool _computing = false;
  String? _profileName;

  @override
  void initState() {
    super.initState();
    _loadsFuture = context.read<RecipeRepository>().watchAll().first;
    _firearmsFuture = context.read<FirearmRepository>().allFirearms();
    _targetsFuture = context.read<TargetRepository>().allTargets();
    if (widget.initialDistanceYd != null) {
      _referenceRangeYd = widget.initialDistanceYd!.clamp(_rangeMinYd, _rangeMaxYd);
    }
    // Hydrate selections after the first frame so we have a context.
    //
    // The outer `if (!mounted) return;` guards against a fast pop —
    // user opens this screen, immediately backs out before the first
    // frame's post-frame callback fires. Without it, the async
    // `_hydrateInitialSelections()` keeps running on a disposed state
    // and any `setState` it triggers raises
    // `setState() called after dispose`. Inner `if (mounted)` checks
    // already exist on each setState site, but they only catch the
    // case where the await returns AFTER dispose; if the post-frame
    // itself fires after dispose (rare but possible during fast
    // navigation), the early return short-circuits before any await
    // is even started.
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
        setState(() => _selectedLoad = found);
        _onLoadChanged(found);
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
        setState(() => _selectedFirearm = found);
        _onFirearmChanged(found);
      }
    }
    if (widget.initialTargetId != null) {
      final targets = await _targetsFuture;
      TargetRow? found;
      if (targets != null) {
        for (final t in targets) {
          if (t.id == widget.initialTargetId) {
            found = t;
            break;
          }
        }
      }
      if (found != null && mounted) {
        setState(() => _selectedTarget = found);
      }
    }
  }

  @override
  void dispose() {
    _debounce?.cancel();
    super.dispose();
  }

  // ─────────────────────── Compute ───────────────────────

  void _scheduleCompute() {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 400), _compute);
  }

  Future<void> _compute() async {
    if (!mounted) return;
    if (_selectedTarget == null) {
      setState(() => _result = null);
      return;
    }
    setState(() => _computing = true);
    final svc = context.read<HitProbabilityMapService>();
    final ranges = <double>[];
    for (var r = _rangeMinYd; r <= _rangeMaxYd + 0.5; r += _rangeStepYd) {
      ranges.add(r);
    }
    final shape = parseTargetShape(_selectedTarget!.shape);
    // Run the compute on the platform thread — the service is fast
    // enough at the default 60-point density (~150ms on a phone).
    // Wrapping in a Future to give the UI a frame to render the
    // "Computing…" state before the math starts.
    await Future<void>.delayed(Duration.zero);
    final result = svc.compute(
      rangesYd: ranges,
      referenceRangeYd: _referenceRangeYd,
      targetWidthIn: _selectedTarget!.widthIn,
      targetHeightIn: _selectedTarget!.heightIn,
      shape: shape,
      assumedGroupMoa: _groupMoa,
      windUncertaintyMph: _windUncertaintyMph,
      rangeUncertaintyYd: _rangeUncertaintyYd,
      mvSdFps: _mvSdFps,
      bcG7: _bcG7,
      muzzleVelocityFps: _muzzleVelocityFps,
      bulletWeightGr: _bulletWeightGr,
      bulletDiameterIn: _bulletDiameterIn,
    );
    if (!mounted) return;
    setState(() {
      _result = result;
      _computing = false;
    });
  }

  void _onLoadChanged(UserLoadRow? load) {
    setState(() {
      _selectedLoad = load;
      if (load?.bulletWeightGr != null) {
        _bulletWeightGr = load!.bulletWeightGr!;
      }
    });
    _scheduleCompute();
  }

  void _onFirearmChanged(UserFirearmRow? firearm) {
    setState(() {
      _selectedFirearm = firearm;
      if (firearm?.defaultMuzzleVelocityFps != null) {
        _muzzleVelocityFps = firearm!.defaultMuzzleVelocityFps!;
      }
    });
    _scheduleCompute();
  }

  // ─────────────────────── Save ───────────────────────

  Future<void> _saveProfile() async {
    final result = _result;
    final target = _selectedTarget;
    final messenger = ScaffoldMessenger.of(context);
    if (result == null || target == null) {
      messenger.showSnackBar(
        const SnackBar(content: Text('Pick a target and compute first.')),
      );
      return;
    }
    final name = _profileName?.trim().isNotEmpty == true
        ? _profileName!.trim()
        : _suggestedProfileName();
    final db = context.read<AppDatabase>();
    final ok = await safeAsync<bool>(
      context,
      mounted: () => mounted,
      userMessage:
          'Could not save the Hit Probability Map profile. Please try again.',
      body: () async {
        await db.into(db.wezProfiles).insert(WezProfilesCompanion.insert(
              name: name,
              loadId: Value(_selectedLoad?.id),
              firearmId: Value(_selectedFirearm?.id),
              targetWidthIn: target.widthIn,
              targetHeightIn: target.heightIn,
              targetShape: target.shape,
              groupMoa: _groupMoa,
              windUncertaintyMph: _windUncertaintyMph,
              rangeUncertaintyYd: _rangeUncertaintyYd,
              mvSdFps: _mvSdFps,
              curveJson: result.curveJsonString(),
              computedAt: result.computedAt,
            ));
        return true;
      },
    );
    if (ok != true) return;
    if (!mounted) return;
    messenger.showSnackBar(
      SnackBar(content: Text('Saved Hit Probability Map profile "$name"')),
    );
  }

  String _suggestedProfileName() {
    final parts = <String>[];
    if (_selectedLoad?.name != null) parts.add(_selectedLoad!.name);
    if (_selectedTarget?.name != null) parts.add(_selectedTarget!.name);
    if (parts.isEmpty) parts.add('Hit Probability Map profile');
    return parts.join(' · ');
  }

  // ─────────────────────── Build ───────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Hit Probability Map'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: 'Recalculate',
            onPressed: _compute,
          ),
        ],
      ),
      body: RangeDayErrorBoundary(
        label: 'hit probability map',
        child: SafeArea(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _setupCard(),
                const SizedBox(height: 12),
                _inputsCard(),
                const SizedBox(height: 12),
                _curveCard(),
                const SizedBox(height: 12),
                _bandsCard(),
                const SizedBox(height: 12),
                _breakdownCard(),
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
            Row(
              children: [
                Icon(Icons.tune, color: theme.colorScheme.primary),
                const SizedBox(width: 8),
                Text('Setup', style: theme.textTheme.titleMedium),
              ],
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
                  decoration: const InputDecoration(
                    labelText: 'Load (optional)',
                    isDense: true,
                  ),
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
                  onChanged: _onLoadChanged,
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
                    labelText: 'Firearm (optional)',
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
                  onChanged: _onFirearmChanged,
                );
              },
            ),
            const SizedBox(height: 8),
            FutureBuilder<List<TargetRow>>(
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
                final targets = snap.data ?? const [];
                return DropdownButtonFormField<TargetRow?>(
                  initialValue: _selectedTarget,
                  isExpanded: true,
                  decoration: const InputDecoration(
                    labelText: 'Target',
                    isDense: true,
                  ),
                  items: [
                    const DropdownMenuItem<TargetRow?>(
                      value: null,
                      child: Text('— pick a target —'),
                    ),
                    for (final t in targets)
                      DropdownMenuItem<TargetRow?>(
                        value: t,
                        child: Text(
                          '${t.name} '
                          '(${t.widthIn.toStringAsFixed(0)}×'
                          '${t.heightIn.toStringAsFixed(0)}")',
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                  ],
                  onChanged: (v) {
                    setState(() => _selectedTarget = v);
                    _scheduleCompute();
                  },
                );
              },
            ),
            const SizedBox(height: 12),
            Row(children: [
              Expanded(
                child: _numberField(
                  label: 'BC (G7)',
                  value: _bcG7,
                  onChanged: (v) => setState(() {
                    _bcG7 = v;
                    _scheduleCompute();
                  }),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: _numberField(
                  label: 'MV (fps)',
                  value: _muzzleVelocityFps,
                  onChanged: (v) => setState(() {
                    _muzzleVelocityFps = v;
                    _scheduleCompute();
                  }),
                ),
              ),
            ]),
            const SizedBox(height: 8),
            Row(children: [
              Expanded(
                child: _numberField(
                  label: 'Bullet wt (gr)',
                  value: _bulletWeightGr,
                  onChanged: (v) => setState(() {
                    _bulletWeightGr = v;
                    _scheduleCompute();
                  }),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: _numberField(
                  label: 'Diameter (in)',
                  value: _bulletDiameterIn,
                  onChanged: (v) => setState(() {
                    _bulletDiameterIn = v;
                    _scheduleCompute();
                  }),
                ),
              ),
            ]),
          ],
        ),
      ),
    );
  }

  Widget _inputsCard() {
    final theme = Theme.of(context);
    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Icon(Icons.precision_manufacturing,
                    color: theme.colorScheme.primary),
                const SizedBox(width: 8),
                Text('Uncertainties',
                    style: theme.textTheme.titleMedium),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              'These uncertainties feed the WEZ dispersion model. '
              'Tighten any of them to lift the curve.',
              style: theme.textTheme.bodySmall,
            ),
            const SizedBox(height: 8),
            _slider(
              label: 'Group at 100 yd',
              value: _groupMoa,
              min: 0.1,
              max: 3.0,
              divisions: 29,
              suffix: 'MOA',
              onChanged: (v) => setState(() {
                _groupMoa = v;
                _scheduleCompute();
              }),
            ),
            _slider(
              label: 'Wind uncertainty',
              value: _windUncertaintyMph,
              min: 0,
              max: 10,
              divisions: 20,
              suffix: '± mph',
              onChanged: (v) => setState(() {
                _windUncertaintyMph = v;
                _scheduleCompute();
              }),
            ),
            _slider(
              label: 'Range uncertainty',
              value: _rangeUncertaintyYd,
              min: 0,
              max: 30,
              divisions: 30,
              suffix: '± yd',
              onChanged: (v) => setState(() {
                _rangeUncertaintyYd = v;
                _scheduleCompute();
              }),
            ),
            _slider(
              label: 'MV SD',
              value: _mvSdFps,
              min: 0,
              max: 30,
              divisions: 30,
              suffix: 'fps',
              onChanged: (v) => setState(() {
                _mvSdFps = v;
                _scheduleCompute();
              }),
            ),
            const Divider(height: 24),
            _slider(
              label: 'Reference range',
              value: _referenceRangeYd,
              min: _rangeMinYd,
              max: _rangeMaxYd,
              divisions: ((_rangeMaxYd - _rangeMinYd) / 25).round(),
              suffix: 'yd',
              onChanged: (v) => setState(() {
                _referenceRangeYd = v;
                _scheduleCompute();
              }),
            ),
          ],
        ),
      ),
    );
  }

  Widget _curveCard() {
    final theme = Theme.of(context);
    final result = _result;
    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Icon(Icons.show_chart, color: theme.colorScheme.primary),
                const SizedBox(width: 8),
                Text('Hit probability vs range',
                    style: theme.textTheme.titleMedium),
                const Spacer(),
                if (_computing)
                  const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
              ],
            ),
            const SizedBox(height: 12),
            if (result == null)
              SizedBox(
                height: 220,
                child: Center(
                  child: Text(
                    _selectedTarget == null
                        ? 'Pick a target to plot the curve.'
                        : 'Computing…',
                    style: theme.textTheme.bodyMedium,
                  ),
                ),
              )
            else
              SizedBox(
                height: 220,
                child: CustomPaint(
                  painter: HitProbabilityMapCurvePainter(
                    curve: result.curve,
                    referenceRangeYd: _referenceRangeYd,
                    rangeMinYd: _rangeMinYd,
                    rangeMaxYd: _rangeMaxYd,
                    primaryColor: theme.colorScheme.primary,
                    gridColor: theme.colorScheme.outlineVariant,
                    textStyle: theme.textTheme.bodySmall ?? const TextStyle(),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _bandsCard() {
    final theme = Theme.of(context);
    final r = _result;
    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(children: [
              Icon(Icons.bar_chart, color: theme.colorScheme.primary),
              const SizedBox(width: 8),
              Text('Effective range bands',
                  style: theme.textTheme.titleMedium),
            ]),
            const SizedBox(height: 8),
            for (final t in const [0.90, 0.75, 0.50, 0.25])
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 2),
                child: _bandRow(t, r),
              ),
            if (r == null)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  'Pick a target to compute effective ranges.',
                  style: theme.textTheme.bodySmall,
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _bandRow(double threshold, HitProbabilityMapResult? r) {
    final theme = Theme.of(context);
    final maxYd = r?.maxRangeAtHitProbabilityAtLeast(threshold);
    final pct = (threshold * 100).round();
    final label = '≥ $pct% hit';
    final value = maxYd == null
        ? '—'
        : '${_rangeMinYd.toStringAsFixed(0)} – ${maxYd.toStringAsFixed(0)} yd';
    return Row(
      children: [
        SizedBox(width: 90, child: Text(label, style: theme.textTheme.bodyMedium)),
        Expanded(
          child: Text(
            value,
            style: theme.textTheme.titleSmall?.copyWith(
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
        ),
      ],
    );
  }

  Widget _breakdownCard() {
    final theme = Theme.of(context);
    final r = _result;
    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(children: [
              Icon(Icons.pie_chart, color: theme.colorScheme.primary),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  'Variance contribution at '
                  '${_referenceRangeYd.toStringAsFixed(0)} yd',
                  style: theme.textTheme.titleMedium,
                ),
              ),
            ]),
            const SizedBox(height: 4),
            Text(
              'Tells you which knob to tune to lift the curve. '
              'At long range wind dominates; at short range group does.',
              style: theme.textTheme.bodySmall,
            ),
            const SizedBox(height: 12),
            if (r == null)
              const Text('—')
            else ...[
              for (final f in r.factorsAtReferenceRange)
                _breakdownRow(f),
            ],
          ],
        ),
      ),
    );
  }

  Widget _breakdownRow(HitProbabilityMapVarianceFactor f) {
    final theme = Theme.of(context);
    final pct = (f.fractionOfVariance * 100).round();
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(children: [
        SizedBox(width: 70, child: Text(f.label, style: theme.textTheme.bodyMedium)),
        Expanded(
          child: ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: LinearProgressIndicator(
              value: f.fractionOfVariance,
              backgroundColor: theme.colorScheme.surfaceContainerHighest,
              minHeight: 8,
            ),
          ),
        ),
        const SizedBox(width: 8),
        SizedBox(
          width: 60,
          child: Text(
            '$pct%',
            textAlign: TextAlign.right,
            style: theme.textTheme.bodyMedium?.copyWith(
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
        ),
      ]),
    );
  }

  Widget _saveCard() {
    final theme = Theme.of(context);
    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(children: [
              Icon(Icons.save_outlined, color: theme.colorScheme.primary),
              const SizedBox(width: 8),
              Text('Save profile', style: theme.textTheme.titleMedium),
            ]),
            const SizedBox(height: 8),
            TextField(
              decoration: InputDecoration(
                labelText: 'Profile name',
                hintText: _suggestedProfileName(),
                isDense: true,
              ),
              onChanged: (v) => setState(() => _profileName = v),
            ),
            const SizedBox(height: 12),
            FilledButton.icon(
              icon: const Icon(Icons.save),
              label: const Text('Save Hit Probability Map profile'),
              onPressed: _result == null ? null : _saveProfile,
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
      decoration: InputDecoration(
        labelText: label,
        isDense: true,
      ),
      onChanged: (s) {
        final v = double.tryParse(s);
        if (v != null && v > 0) onChanged(v);
      },
    );
  }

  Widget _slider({
    required String label,
    required double value,
    required double min,
    required double max,
    required int divisions,
    required String suffix,
    required ValueChanged<double> onChanged,
  }) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(children: [
            Expanded(
              child: Text(label, style: theme.textTheme.bodyMedium),
            ),
            Text(
              '${value.toStringAsFixed(suffix == 'MOA' ? 2 : (value < 10 ? 1 : 0))} $suffix',
              style: theme.textTheme.titleSmall,
            ),
          ]),
          Slider(
            value: value.clamp(min, max),
            min: min,
            max: max,
            divisions: divisions,
            onChanged: onChanged,
          ),
        ],
      ),
    );
  }
}

// ============================================================================
// Hit Probability Map curve painter
// ============================================================================
//
// Draws the hit-probability-vs-range curve. The chart is a simple
// mil-spec affair:
//
//   * X axis: range (yd), labeled at the left/middle/right.
//   * Y axis: probability (0..100%), with horizontal gridlines at
//     25 / 50 / 75 / 90%.
//   * Curve: filled under-the-line in primary color (brass) at low
//     opacity; the curve itself drawn as a 2px stroke in primary
//     color.
//   * Reference range: a vertical highlight bar at the user's
//     chosen reference range.
//
// The painter is stateless. The screen widget calls `setState` to
// trigger repaints when the curve / inputs change.

class HitProbabilityMapCurvePainter extends CustomPainter {
  HitProbabilityMapCurvePainter({
    required this.curve,
    required this.referenceRangeYd,
    required this.rangeMinYd,
    required this.rangeMaxYd,
    required this.primaryColor,
    required this.gridColor,
    required this.textStyle,
  });

  final List<HitProbabilityMapPoint> curve;
  final double referenceRangeYd;
  final double rangeMinYd;
  final double rangeMaxYd;
  final Color primaryColor;
  final Color gridColor;
  final TextStyle textStyle;

  static const double _padLeft = 36;
  static const double _padRight = 12;
  static const double _padTop = 8;
  static const double _padBottom = 24;

  @override
  void paint(Canvas canvas, Size size) {
    if (curve.isEmpty) return;
    final chartLeft = _padLeft;
    final chartRight = size.width - _padRight;
    final chartTop = _padTop;
    final chartBottom = size.height - _padBottom;
    final chartW = chartRight - chartLeft;
    final chartH = chartBottom - chartTop;

    double xFor(double rangeYd) {
      final f = (rangeYd - rangeMinYd) / (rangeMaxYd - rangeMinYd);
      return chartLeft + chartW * f.clamp(0.0, 1.0);
    }

    double yFor(double prob01) {
      return chartBottom - chartH * prob01.clamp(0.0, 1.0);
    }

    // ── Gridlines + Y labels ──────────────────────────────────────
    final gridPaint = Paint()
      ..color = gridColor
      ..strokeWidth = 1;
    for (final t in const [0.25, 0.50, 0.75, 0.90]) {
      final y = yFor(t);
      canvas.drawLine(
        Offset(chartLeft, y),
        Offset(chartRight, y),
        gridPaint,
      );
      _drawText(canvas, '${(t * 100).toInt()}%',
          Offset(chartLeft - 4, y - 6),
          align: _TextAlign.right);
    }
    // Frame (top + bottom + left).
    canvas.drawLine(Offset(chartLeft, chartTop),
        Offset(chartRight, chartTop), gridPaint);
    canvas.drawLine(Offset(chartLeft, chartBottom),
        Offset(chartRight, chartBottom), gridPaint);
    canvas.drawLine(Offset(chartLeft, chartTop),
        Offset(chartLeft, chartBottom), gridPaint);

    // ── X labels ──────────────────────────────────────
    _drawText(canvas, '${rangeMinYd.toInt()}',
        Offset(chartLeft, chartBottom + 4));
    final mid = (rangeMinYd + rangeMaxYd) / 2;
    _drawText(canvas, '${mid.toInt()}',
        Offset(xFor(mid) - 12, chartBottom + 4));
    _drawText(canvas, '${rangeMaxYd.toInt()} yd',
        Offset(chartRight - 30, chartBottom + 4));

    // ── Reference vertical bar ──────────────────────────────────────
    final refX = xFor(referenceRangeYd);
    final refPaint = Paint()
      ..color = primaryColor.withValues(alpha: 0.18)
      ..strokeWidth = 4;
    canvas.drawLine(Offset(refX, chartTop), Offset(refX, chartBottom), refPaint);

    // ── Filled area under the curve ──────────────────────────────────────
    final path = Path()..moveTo(xFor(curve.first.rangeYd), chartBottom);
    for (final p in curve) {
      path.lineTo(xFor(p.rangeYd), yFor(p.hitProbability));
    }
    path.lineTo(xFor(curve.last.rangeYd), chartBottom);
    path.close();
    final fillPaint = Paint()
      ..color = primaryColor.withValues(alpha: 0.18)
      ..style = PaintingStyle.fill;
    canvas.drawPath(path, fillPaint);

    // ── Curve stroke ──────────────────────────────────────
    final strokePath = Path();
    for (var i = 0; i < curve.length; i++) {
      final p = curve[i];
      final x = xFor(p.rangeYd);
      final y = yFor(p.hitProbability);
      if (i == 0) {
        strokePath.moveTo(x, y);
      } else {
        strokePath.lineTo(x, y);
      }
    }
    final strokePaint = Paint()
      ..color = primaryColor
      ..strokeWidth = 2.0
      ..style = PaintingStyle.stroke
      ..strokeJoin = StrokeJoin.round
      ..strokeCap = StrokeCap.round;
    canvas.drawPath(strokePath, strokePaint);

    // ── Reference dot ──────────────────────────────────────
    // Find / interpolate the curve's prob at the reference range.
    final refProb = _interpolateAt(referenceRangeYd);
    if (refProb != null) {
      final dotY = yFor(refProb);
      final dotPaint = Paint()..color = primaryColor;
      canvas.drawCircle(Offset(refX, dotY), 4.5, dotPaint);
      _drawText(
        canvas,
        '${(refProb * 100).round()}%',
        Offset(refX + 6, dotY - 14),
      );
    }
  }

  double? _interpolateAt(double rangeYd) {
    if (curve.isEmpty) return null;
    if (rangeYd <= curve.first.rangeYd) return curve.first.hitProbability;
    if (rangeYd >= curve.last.rangeYd) return curve.last.hitProbability;
    for (var i = 1; i < curve.length; i++) {
      final a = curve[i - 1];
      final b = curve[i];
      if (rangeYd >= a.rangeYd && rangeYd <= b.rangeYd) {
        final span = b.rangeYd - a.rangeYd;
        if (span <= 0) return a.hitProbability;
        final t = (rangeYd - a.rangeYd) / span;
        return a.hitProbability + t * (b.hitProbability - a.hitProbability);
      }
    }
    return curve.last.hitProbability;
  }

  void _drawText(
    Canvas canvas,
    String text,
    Offset offset, {
    _TextAlign align = _TextAlign.left,
  }) {
    final tp = TextPainter(
      text: TextSpan(text: text, style: textStyle),
      textDirection: TextDirection.ltr,
    )..layout();
    Offset effective = offset;
    if (align == _TextAlign.right) {
      effective = Offset(offset.dx - tp.width, offset.dy);
    } else if (align == _TextAlign.center) {
      effective = Offset(offset.dx - tp.width / 2, offset.dy);
    }
    tp.paint(canvas, effective);
  }

  @override
  bool shouldRepaint(covariant HitProbabilityMapCurvePainter old) {
    return old.curve != curve ||
        old.referenceRangeYd != referenceRangeYd ||
        old.rangeMinYd != rangeMinYd ||
        old.rangeMaxYd != rangeMaxYd ||
        old.primaryColor != primaryColor;
  }
}

enum _TextAlign { left, center, right }
