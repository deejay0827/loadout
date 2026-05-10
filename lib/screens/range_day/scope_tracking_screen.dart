// FILE: lib/screens/range_day/scope_tracking_screen.dart
//
// ============================================================================
// WHAT THIS FILE DOES
// ============================================================================
// User-facing UI for the Scope Tracking Test (formerly known internally
// as "Sight Calibration") — Drop-Per-Click (DPC) tracking validation.
// Pro-gated.
//
// This is a wizard-style screen that walks the user through a tall-target
// test:
//
//   Step 1 — Pick a firearm.
//   Step 2 — Pick the calibration axis (vertical / horizontal) and the
//            target geometry.
//   Step 3 — Tell the wizard the dial amount you used (e.g. "10 mil up").
//   Step 4 — Tap impact positions on a target plot. The plot lets you
//            place points at the same normalized [-1, 1] coords used by
//            the rest of the Range Day workspace, so the math is shared.
//   Step 5 — Wizard derives the scale factor. User confirms to write it
//            back to `UserFirearms.sightScaleVertical/Horizontal` and
//            log a `SightCalibrations` row.

import 'package:drift/drift.dart' show Value;
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../database/database.dart';
import '../../repositories/firearm_repository.dart';
import '../../services/scope_tracking_service.dart';
import '../../widgets/range_day_safety.dart';

class ScopeTrackingScreen extends StatefulWidget {
  const ScopeTrackingScreen({super.key, this.initialFirearmId});

  final int? initialFirearmId;

  @override
  State<ScopeTrackingScreen> createState() => _ScopeTrackingScreenState();
}

class _ScopeTrackingScreenState extends State<ScopeTrackingScreen> {
  UserFirearmRow? _selectedFirearm;
  Future<List<UserFirearmRow>>? _firearmsFuture;
  ScopeTrackingAxis _axis = ScopeTrackingAxis.vertical;
  // Target dimensions and distance.
  double _targetWidthIn = 24;
  double _targetHeightIn = 24;
  double _targetDistanceYd = 100;
  // Aim point (default for tall-target test: bottom-center for vertical).
  double _aimPointX = 0.0;
  double _aimPointY = -1.0;
  // Dialed amount (mil — user can flip via segmented control to MOA).
  double _dialMil = 10.0;
  bool _dialInMoa = false;
  // The user's recorded impacts.
  final List<ScopeTrackingObservation> _observations = [];

  ScopeTrackingResult? _result;

  @override
  void initState() {
    super.initState();
    _firearmsFuture = context.read<FirearmRepository>().allFirearms();
    if (widget.initialFirearmId != null) {
      // Outer mounted guard — see the matching comment in
      // `hit_probability_map_screen.dart`. Protects against the user
      // popping this screen before the first frame's post-frame
      // callback fires.
      WidgetsBinding.instance.addPostFrameCallback((_) async {
        if (!mounted) return;
        final firearms = await _firearmsFuture;
        if (!mounted) return;
        UserFirearmRow? found;
        if (firearms != null) {
          for (final f in firearms) {
            if (f.id == widget.initialFirearmId) {
              found = f;
              break;
            }
          }
        }
        if (found != null) {
          setState(() => _selectedFirearm = found);
        }
      });
    }
  }

  void _addImpact(double x, double y) {
    setState(() {
      _observations.add(ScopeTrackingObservation(impactX: x, impactY: y));
    });
    _compute();
  }

  void _removeImpact(int i) {
    setState(() => _observations.removeAt(i));
    _compute();
  }

  void _compute() {
    if (_observations.length < 2) {
      setState(() => _result = null);
      return;
    }
    final svc = context.read<ScopeTrackingService>();
    final dialMil = _dialInMoa ? _dialMil * 0.291 : _dialMil; // 1 MOA ≈ 0.291 mil
    final r = svc.calibrate(
      axis: _axis,
      aimPointX: _aimPointX,
      aimPointY: _aimPointY,
      advertisedDialMil: dialMil,
      targetWidthIn: _targetWidthIn,
      targetHeightIn: _targetHeightIn,
      targetDistanceYd: _targetDistanceYd,
      observations: _observations,
    );
    setState(() => _result = r);
  }

  Future<void> _applyAndSave() async {
    final result = _result;
    final firearm = _selectedFirearm;
    if (result == null || firearm == null) return;
    final db = context.read<AppDatabase>();
    final messenger = ScaffoldMessenger.of(context);
    final navigator = Navigator.of(context);
    final dialMil = _dialInMoa ? _dialMil * 0.291 : _dialMil;
    // Wrap the whole transaction so a closed DB / serialization error
    // surfaces as a snackbar instead of an uncaught exception.
    final ok = await safeAsync<bool>(
      context,
      mounted: () => mounted,
      userMessage:
          'Could not save the scope tracking test. Please try again.',
      body: () async {
        await db.transaction(() async {
          // Log the calibration history.
          await db.into(db.sightCalibrations).insert(
                SightCalibrationsCompanion.insert(
                  firearmId: firearm.id,
                  axis: result.axis.dbValue,
                  advertisedClickMil: dialMil,
                  observedClickMil: result.measuredMil,
                  derivedScale: result.derivedScale,
                  observationJson: result.observationJsonString(),
                  calibratedAt: DateTime.now(),
                ),
              );
          // Apply to the firearm row.
          if (result.axis == ScopeTrackingAxis.vertical) {
            await (db.update(db.userFirearms)
                  ..where((f) => f.id.equals(firearm.id)))
                .write(UserFirearmsCompanion(
              sightScaleVertical: Value(result.derivedScale),
              updatedAt: Value(DateTime.now()),
            ));
          } else {
            await (db.update(db.userFirearms)
                  ..where((f) => f.id.equals(firearm.id)))
                .write(UserFirearmsCompanion(
              sightScaleHorizontal: Value(result.derivedScale),
              updatedAt: Value(DateTime.now()),
            ));
          }
        });
        return true;
      },
    );
    if (ok != true) return;
    if (!mounted) return;
    messenger.showSnackBar(
      SnackBar(
        content: Text(
          'Applied ${result.axis.dbValue} sight scale '
          '${result.derivedScale.toStringAsFixed(3)} to ${firearm.name}',
        ),
      ),
    );
    navigator.pop();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Scope Tracking Test')),
      body: RangeDayErrorBoundary(
        label: 'scope tracking test',
        child: SafeArea(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _instructionsCard(),
                const SizedBox(height: 12),
                _setupCard(),
                const SizedBox(height: 12),
                _impactsCard(),
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

  Widget _instructionsCard() {
    final theme = Theme.of(context);
    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              Icon(Icons.info_outline, color: theme.colorScheme.primary),
              const SizedBox(width: 8),
              Text('Tall-target test', style: theme.textTheme.titleMedium),
            ]),
            const SizedBox(height: 4),
            Text(
              'At the range, set up a tall (or wide) reference target at a '
              'known distance. Aim at one end of a marked line and dial a '
              'known amount up (or right). Fire at least 3 shots and tap '
              'each impact below.',
              style: theme.textTheme.bodySmall,
            ),
          ],
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
            const SizedBox(height: 8),
            FutureBuilder<List<UserFirearmRow>>(
              future: _firearmsFuture,
              builder: (context, snap) {
                if (snap.hasError) {
                  return RangeDayInlineError(
                    message:
                        'Could not load firearms: ${snap.error}',
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
                    setState(() => _selectedFirearm = v);
                  },
                );
              },
            ),
            const SizedBox(height: 12),
            SegmentedButton<ScopeTrackingAxis>(
              segments: const [
                ButtonSegment(
                  value: ScopeTrackingAxis.vertical,
                  label: Text('Elevation'),
                  icon: Icon(Icons.swap_vert),
                ),
                ButtonSegment(
                  value: ScopeTrackingAxis.horizontal,
                  label: Text('Windage'),
                  icon: Icon(Icons.swap_horiz),
                ),
              ],
              selected: {_axis},
              onSelectionChanged: (s) {
                setState(() {
                  _axis = s.first;
                  // Default aim point for the chosen axis.
                  if (_axis == ScopeTrackingAxis.vertical) {
                    _aimPointX = 0;
                    _aimPointY = -1;
                  } else {
                    _aimPointX = -1;
                    _aimPointY = 0;
                  }
                });
                _compute();
              },
            ),
            const SizedBox(height: 12),
            Row(children: [
              Expanded(
                child: _numberField(
                  label: 'Distance (yd)',
                  value: _targetDistanceYd,
                  onChanged: (v) {
                    setState(() => _targetDistanceYd = v);
                    _compute();
                  },
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: _numberField(
                  label: 'Target W (in)',
                  value: _targetWidthIn,
                  onChanged: (v) {
                    setState(() => _targetWidthIn = v);
                    _compute();
                  },
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: _numberField(
                  label: 'Target H (in)',
                  value: _targetHeightIn,
                  onChanged: (v) {
                    setState(() => _targetHeightIn = v);
                    _compute();
                  },
                ),
              ),
            ]),
            const SizedBox(height: 12),
            Row(children: [
              Expanded(
                child: _numberField(
                  label: 'Dial commanded',
                  value: _dialMil,
                  onChanged: (v) {
                    setState(() => _dialMil = v);
                    _compute();
                  },
                ),
              ),
              const SizedBox(width: 8),
              SegmentedButton<bool>(
                segments: const [
                  ButtonSegment(value: false, label: Text('mil')),
                  ButtonSegment(value: true, label: Text('MOA')),
                ],
                selected: {_dialInMoa},
                showSelectedIcon: false,
                onSelectionChanged: (s) {
                  setState(() => _dialInMoa = s.first);
                  _compute();
                },
              ),
            ]),
          ],
        ),
      ),
    );
  }

  Widget _impactsCard() {
    final theme = Theme.of(context);
    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(children: [
              Icon(Icons.adjust, color: theme.colorScheme.primary),
              const SizedBox(width: 8),
              Expanded(
                child: Text('Impacts', style: theme.textTheme.titleMedium),
              ),
              IconButton(
                tooltip: 'Add impact',
                icon: const Icon(Icons.add),
                onPressed: () => _addImpact(0.0, 0.0),
              ),
            ]),
            const SizedBox(height: 4),
            Text(
              'Enter each impact in normalized coordinates: -1 = '
              'left/bottom edge, 0 = center, +1 = right/top edge.',
              style: theme.textTheme.bodySmall,
            ),
            const SizedBox(height: 8),
            for (var i = 0; i < _observations.length; i++)
              _impactRow(i),
          ],
        ),
      ),
    );
  }

  Widget _impactRow(int i) {
    final obs = _observations[i];
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(children: [
        SizedBox(
          width: 36,
          child: Text('#${i + 1}',
              style: Theme.of(context).textTheme.bodyMedium),
        ),
        Expanded(
          child: TextFormField(
            initialValue: obs.impactX.toStringAsFixed(3),
            keyboardType: const TextInputType.numberWithOptions(
              decimal: true,
              signed: true,
            ),
            decoration: const InputDecoration(
              labelText: 'X (-1..1)',
              isDense: true,
            ),
            onChanged: (s) {
              final v = double.tryParse(s);
              if (v != null) {
                setState(() {
                  _observations[i] = ScopeTrackingObservation(
                    impactX: v,
                    impactY: obs.impactY,
                    notes: obs.notes,
                  );
                });
                _compute();
              }
            },
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: TextFormField(
            initialValue: obs.impactY.toStringAsFixed(3),
            keyboardType: const TextInputType.numberWithOptions(
              decimal: true,
              signed: true,
            ),
            decoration: const InputDecoration(
              labelText: 'Y (-1..1)',
              isDense: true,
            ),
            onChanged: (s) {
              final v = double.tryParse(s);
              if (v != null) {
                setState(() {
                  _observations[i] = ScopeTrackingObservation(
                    impactX: obs.impactX,
                    impactY: v,
                    notes: obs.notes,
                  );
                });
                _compute();
              }
            },
          ),
        ),
        IconButton(
          tooltip: 'Remove',
          icon: const Icon(Icons.delete_outline),
          onPressed: () => _removeImpact(i),
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
              Text('Calibration result',
                  style: theme.textTheme.titleMedium),
            ]),
            const SizedBox(height: 8),
            if (result == null)
              Text(
                _observations.length < 2
                    ? 'Add at least two impacts to compute the scale factor.'
                    : 'Computing…',
                style: theme.textTheme.bodyMedium,
              )
            else ...[
              Text(
                'Your scope tracks at '
                '${result.derivedScale.toStringAsFixed(3)}× advertised',
                style: theme.textTheme.titleMedium?.copyWith(
                  color: theme.colorScheme.primary,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                '• Centroid offset: '
                '${result.centroidOffsetIn.toStringAsFixed(2)} in '
                'on the ${result.axis.dbValue} axis',
                style: theme.textTheme.bodyMedium,
              ),
              Text(
                '• Measured: '
                '${result.measuredMil.toStringAsFixed(2)} mil '
                '(commanded ${result.advertisedMil.toStringAsFixed(2)} mil)',
                style: theme.textTheme.bodyMedium,
              ),
              Text(
                '• Group RMS at impact: '
                '${result.groupRmsIn.toStringAsFixed(2)} in '
                '(${result.observations.length} shots)',
                style: theme.textTheme.bodyMedium,
              ),
              if (result.derivedScale < 0.9 || result.derivedScale > 1.1) ...[
                const SizedBox(height: 8),
                Text(
                  '⚠ The derived scale is outside the typical 0.95–1.05 '
                  'range — double-check that the dial amount and impact '
                  'positions are correct before applying.',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.error,
                  ),
                ),
              ],
            ],
          ],
        ),
      ),
    );
  }

  Widget _saveCard() {
    final theme = Theme.of(context);
    final canSave = _result != null && _selectedFirearm != null;
    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(children: [
              Icon(Icons.save_outlined, color: theme.colorScheme.primary),
              const SizedBox(width: 8),
              Text('Apply scale', style: theme.textTheme.titleMedium),
            ]),
            const SizedBox(height: 4),
            Text(
              'Writes the derived factor to '
              'UserFirearms.sightScale${_axis == ScopeTrackingAxis.vertical ? 'Vertical' : 'Horizontal'} '
              'and logs the calibration so you can review it later.',
              style: theme.textTheme.bodySmall,
            ),
            const SizedBox(height: 12),
            FilledButton.icon(
              icon: const Icon(Icons.save),
              label: const Text('Apply and Save'),
              onPressed: canSave ? _applyAndSave : null,
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
      keyboardType:
          const TextInputType.numberWithOptions(decimal: true, signed: true),
      decoration: InputDecoration(labelText: label, isDense: true),
      onChanged: (s) {
        final v = double.tryParse(s);
        if (v != null) onChanged(v);
      },
    );
  }
}
