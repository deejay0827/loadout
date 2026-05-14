// FILE: lib/screens/range_day/scope_view_screen.dart
//
// ============================================================================
// WHAT THIS FILE DOES
// ============================================================================
// Pro feature reachable from the Range Day workspace's firing-solution card.
// Shows the user a full-screen visual approximation of WHAT THEY'D SEE
// THROUGH THEIR SCOPE: a circular field of view containing their reticle
// drawn to scale, with the chosen target rendered at the correct angular
// size for the entered range and magnification.
//
// The screen differentiates from existing visualizers (e.g. Strelok's)
// in four deliberate ways:
//
//   1. **Auto-applied firing solution.** The reticle is RE-ANCHORED at
//      the negative of the dial-up + wind-hold so that the user sees
//      "what should appear in the scope when they have dialed correctly
//      and are holding into the wind." When the firing solution lands
//      at 8 mil down + 1.2 mil right, the reticle's geometric center is
//      drawn 8 mil up + 1.2 mil left of the FOV center, so the crosshair
//      sits ON the target. This is the opposite of the unsolved view
//      (reticle dead center, target offset by drop+wind) and is what a
//      real shooter who has correctly dialed will actually see.
//   2. **Aim point + actual hit overlay.** Small ◉ markers visualize
//      the user's chosen aim point and (if they have recorded shots)
//      the latest impact location, so the user can compare aim ↔ hit
//      directly inside the round FOV.
//   3. **Hit probability badge.** Top-right corner shows a single-glance
//      hit-% chip that ties this view to the rest of the Range Day
//      computation. Unique to LoadOut — Strelok's scope view doesn't
//      know about hit probability at all.
//   4. **Tap-to-switch subtension display.** Tapping the reticle layer
//      cycles the displayed unit (MOA → MIL → inches) so the user can
//      quickly read the same hash-mark spacing in whichever convention
//      matches their scope's turret. Tapping the reticle is the most
//      reliable target on a touch device — it's always near the visual
//      center of the FOV.
//
// ============================================================================
// COORDINATE / SCALING MATH
// ============================================================================
// The FOV is a circle of pixel radius `fovRadiusPx`. We map angles in
// milliradians to pixels via:
//
//     pxPerMil = fovRadiusPx / fovHalfMil
//
// where `fovHalfMil` is the half-extent of angle visible inside the FOV.
// We compute it from the reticle's native unit and chosen scope
// magnification:
//
//     fovHalfMil = (reticle.maxExtentUnits as mil) * (10x / magnification)
//
// for SFP scopes, the reticle's apparent size in the FOV scales inversely
// with magnification (subtensions only match at the reticle's spec
// magnification). For FFP scopes the reticle's apparent size in the FOV
// stays constant — but the perceived FOV does change with magnification,
// so we still apply the scale factor.
//
// Target scaling. A target of physical width W inches at distance D yards
// subtends an angle of (using the small-angle approximation):
//
//     theta_mil = W / (D * 36) * 1000
//
// We render the target as a rectangle / disc of size:
//
//     widthPx = pxPerMil * (W / (D * 36)) * 1000
//
// inside the FOV, centered at the dial-up + wind-hold offset (so the
// target sits where the bullet WOULD land if the rifle were not dialed).
// The reticle is then anchored at `−(dial, wind)` so the crosshair sits
// on the target (the auto-applied firing solution).
//
// ============================================================================
// CLICK-COUNT MATH
// ============================================================================
// Per-click value of a turret depends on the scope:
//   * SFP MOA scopes: typical 0.25 MOA / click.
//   * FFP MIL scopes: typical 0.1 mil / click.
//   * Some high-end scopes use 0.2 mil or 0.125 MOA.
//
// We expose the click value as `clickValuePerUnit`, defaulting to 0.25
// MOA or 0.1 MIL based on the scope's adjustment unit. The user could
// later override this per-optic.

import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../data/reticle_library.dart';
import '../../database/database.dart';
import '../../services/ballistics/units.dart' as bu;
import '../../services/hit_probability_service.dart';
import '../../widgets/range_day_safety.dart';
import '../../widgets/scope_daytime_backdrop.dart';
import 'widgets/target_plot.dart';

/// Subtension display unit for the scope view's tap-to-switch
/// affordance. Cycles MOA → MIL → inches.
enum ScopeSubtensionUnit { moa, mil, inches }

/// All inputs the scope view needs to render. Computed by the parent
/// (Range Day detail screen) from the existing solution + reticle +
/// target state and passed in as one bag.
class ScopeViewInputs {
  const ScopeViewInputs({
    required this.reticle,
    required this.targetSpec,
    required this.dropInches,
    required this.windDriftInches,
    required this.rangeYards,
    required this.aimPointX,
    required this.aimPointY,
    required this.latestImpactX,
    required this.latestImpactY,
    required this.hitProbability,
    required this.scopeMagnification,
    required this.spec1xMagnification,
    required this.scopeFocalPlane,
    required this.adjustmentUnit,
    required this.clickValue,
    this.opticName,
  });

  /// Reticle to render inside the FOV. May be null in the calling code
  /// — but the parent only navigates here once a reticle is selected,
  /// so the view itself treats it as required.
  final ReticleDefinition reticle;

  /// Target geometry. Drives the rendered shape and physical size used
  /// for subtension computation.
  final TargetSpec targetSpec;

  /// Vertical drop at the rendered range, inches. Positive = below LoS
  /// (i.e. the user must dial UP by this amount).
  final double dropInches;

  /// Horizontal wind drift at the rendered range, inches. Positive =
  /// right of LoS (i.e. the user must hold/dial LEFT by this amount).
  final double windDriftInches;

  /// Distance to target, yards. Drives the target's angular size and
  /// the inches/MOA/mil conversions.
  final double rangeYards;

  /// User's aim point in normalized target coords (-1..1, +1 = top).
  /// Null when the user hasn't placed one — treated as dead center.
  final double? aimPointX;
  final double? aimPointY;

  /// Latest recorded impact in the same normalized target coords.
  /// Null when no shots have been recorded yet.
  final double? latestImpactX;
  final double? latestImpactY;

  /// Single-shot hit probability (0..1) reported by
  /// [HitProbabilityService]. Null when not computed.
  final double? hitProbability;

  /// Initial / default scope magnification, e.g. 10.0 for "10x".
  final double scopeMagnification;

  /// Reticle's spec magnification — at this magnification the printed
  /// subtensions match the reticle definition. For FFP scopes this is
  /// effectively any magnification; for SFP scopes it's typically the
  /// max magnification (e.g. 10x on a 4-10x SFP).
  final double spec1xMagnification;

  /// 'first' | 'second' | 'fixed'. Drives whether the rendered reticle
  /// scales with magnification.
  final String scopeFocalPlane;

  /// 'MOA' | 'MIL' — used to seed the click value default and the
  /// initial subtension display unit.
  final String adjustmentUnit;

  /// Per-click value in [adjustmentUnit] units (e.g. 0.25 for a quarter-
  /// MOA scope, 0.1 for a tenth-mil scope).
  final double clickValue;

  /// Optic display name (model + manufacturer), shown as a sub-line in
  /// the AppBar. Optional.
  final String? opticName;
}

/// Full-screen Pro visualizer of "what the user would see through their
/// scope". See file header for the design rationale.
class ScopeViewScreen extends StatefulWidget {
  const ScopeViewScreen({super.key, required this.inputs});

  final ScopeViewInputs inputs;

  @override
  State<ScopeViewScreen> createState() => _ScopeViewScreenState();
}

class _ScopeViewScreenState extends State<ScopeViewScreen>
    with SingleTickerProviderStateMixin {
  late double _magnification;
  late double _rangeYards;
  late ScopeSubtensionUnit _displayUnit;
  late TextEditingController _rangeCtrl;

  // ─── Animated mover state ───────────────────────────────────────────
  //
  // The animated mover (Pro feature) sweeps the target horizontally
  // across the FOV at a user-chosen speed. The slider runs from 0.1×
  // to 4.0× — wide enough that the user can demo at 0.1× ("move the
  // reticle by hand") OR train at 4× ("Race"). The named presets are
  // anchor points along the slider so the user can quickly snap to a
  // remembered cadence.
  //
  // The actual sweep duration scales inversely with the multiplier:
  // `Duration(milliseconds: (kBaseSweepMs / _moverSpeedMultiplier).round())`
  // At 0.1× the sweep takes 50 seconds; at 1× a familiar 5 seconds; at
  // 4× a fast 1.25 seconds.
  static const double _moverSpeedMin = 0.1;
  static const double _moverSpeedMax = 4.0;
  static const int _kBaseSweepMs = 5000; // 1× sweep duration

  /// Named presets shown as tick marks along the slider track.
  /// Editing this list also moves the labeled positions, so keep them
  /// in ascending order.
  static const List<_MoverSpeedPreset> _moverSpeedPresets = [
    _MoverSpeedPreset(value: 0.1, label: 'Demo'),
    _MoverSpeedPreset(value: 0.5, label: 'Slow'),
    _MoverSpeedPreset(value: 1.0, label: 'Normal'),
    _MoverSpeedPreset(value: 2.0, label: 'Fast'),
    _MoverSpeedPreset(value: 4.0, label: 'Race'),
  ];

  bool _animateMover = false;
  double _moverSpeedMultiplier = 1.0;
  late AnimationController _moverController;

  /// Solver bisection range — most consumer scopes peak at 30x; we cap
  /// the slider at the optic's spec max if higher. Always 4.5x as a
  /// floor so the slider feels useful even for low-magnification
  /// optics.
  static const double _minMagnification = 4.5;
  static const double _maxMagnification = 30.0;

  @override
  void initState() {
    super.initState();
    _magnification = widget.inputs.scopeMagnification.clamp(
      _minMagnification,
      _maxMagnification,
    );
    _rangeYards = widget.inputs.rangeYards;
    _displayUnit = widget.inputs.adjustmentUnit.toLowerCase() == 'moa'
        ? ScopeSubtensionUnit.moa
        : ScopeSubtensionUnit.mil;
    _rangeCtrl =
        TextEditingController(text: _rangeYards.toStringAsFixed(0));
    _moverController = AnimationController(
      vsync: this,
      duration: _moverDuration(_moverSpeedMultiplier),
    );
  }

  @override
  void dispose() {
    _rangeCtrl.dispose();
    _moverController.dispose();
    super.dispose();
  }

  /// Sweep duration for [multiplier]. At 1× the sweep takes 5 seconds;
  /// at 0.1× it takes 50 seconds (slow enough to drag the reticle by
  /// hand for a demo).
  Duration _moverDuration(double multiplier) {
    final clamped = multiplier.clamp(_moverSpeedMin, _moverSpeedMax);
    final ms = (_kBaseSweepMs / clamped).round();
    return Duration(milliseconds: ms);
  }

  void _setMoverSpeedMultiplier(double value) {
    final clamped = value.clamp(_moverSpeedMin, _moverSpeedMax);
    setState(() => _moverSpeedMultiplier = clamped);
    final wasAnimating = _moverController.isAnimating;
    _moverController.duration = _moverDuration(clamped);
    if (wasAnimating) {
      _moverController.repeat(reverse: true);
    }
  }

  void _toggleAnimateMover(bool on) {
    setState(() => _animateMover = on);
    if (on) {
      _moverController.repeat(reverse: true);
    } else {
      _moverController.stop();
      _moverController.value = 0.5;
    }
  }

  void _cycleDisplayUnit() {
    setState(() {
      _displayUnit = switch (_displayUnit) {
        ScopeSubtensionUnit.moa => ScopeSubtensionUnit.mil,
        ScopeSubtensionUnit.mil => ScopeSubtensionUnit.inches,
        ScopeSubtensionUnit.inches => ScopeSubtensionUnit.moa,
      };
    });
  }

  void _onRangeChanged(String text) {
    final v = double.tryParse(text.trim());
    if (v == null || v <= 0) return;
    setState(() => _rangeYards = v);
  }

  /// Convert the reticle's native unit value to mils, regardless of
  /// whether the reticle is published in mil or MOA. Used so we can do
  /// all of the angle math in a single unit (mil) inside this screen.
  double _reticleHalfExtentMil() {
    final ext = widget.inputs.reticle.maxExtentUnits;
    return switch (widget.inputs.reticle.nativeUnit) {
      ReticleNativeUnit.mil => ext,
      ReticleNativeUnit.moa => ext / milToMoa,
      // ipsc/bdc reticles don't have a true angular extent — treat
      // them as ~6 mil so the renderer still scales sensibly.
      ReticleNativeUnit.ipsc => 6.0,
      ReticleNativeUnit.bdc => 6.0,
    };
  }

  /// Half-FOV in mils, taking SFP magnification scaling into account.
  /// At the spec magnification the half-FOV equals the reticle's own
  /// half-extent. At higher magnification (zoomed in) the visible
  /// half-extent shrinks; at lower (zoomed out) it grows.
  double _fovHalfMil() {
    final retHalf = _reticleHalfExtentMil();
    if (widget.inputs.scopeFocalPlane.toLowerCase() == 'first') {
      // FFP: reticle subtensions stay constant with mag, so the visible
      // angular FOV is whatever the reticle's max extent is. We add a
      // small margin (1.4x) so the reticle doesn't crowd the FOV edge.
      return retHalf * 1.4;
    }
    // SFP / fixed: visible angular FOV grows as we zoom out and shrinks
    // as we zoom in. Reference at the optic's spec magnification.
    final ref = widget.inputs.spec1xMagnification.clamp(1.0, 60.0);
    final scale = ref / _magnification;
    return (retHalf * 1.4) * scale;
  }

  /// Reticle render scale — for SFP scopes the rendered reticle on
  /// screen also tracks magnification (the reticle physically appears
  /// larger or smaller in the eyepiece). For FFP it stays constant.
  double _reticleRenderScale() {
    if (widget.inputs.scopeFocalPlane.toLowerCase() == 'first') {
      return 1.0;
    }
    final ref = widget.inputs.spec1xMagnification.clamp(1.0, 60.0);
    return _magnification / ref;
  }

  /// Drop in mils at the active range. Sign matches the input
  /// convention (positive = below LoS).
  double _dropMil() => bu.inchesToMilAtYards(
        widget.inputs.dropInches,
        widget.inputs.rangeYards,
      );

  /// Wind drift in mils at the active range. Positive = right of LoS.
  double _windMil() => bu.inchesToMilAtYards(
        widget.inputs.windDriftInches,
        widget.inputs.rangeYards,
      );

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final inputs = widget.inputs;
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: theme.colorScheme.surface,
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Scope View'),
            if (inputs.opticName != null && inputs.opticName!.isNotEmpty)
              Text(
                inputs.opticName!,
                style: theme.textTheme.bodySmall,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
          ],
        ),
        actions: [
          IconButton(
            tooltip: 'Tap reticle to switch units',
            icon: const Icon(Icons.help_outline),
            onPressed: () => _showHelp(context),
          ),
        ],
      ),
      body: RangeDayErrorBoundary(
        label: 'scope view',
        child: SafeArea(
          child: LayoutBuilder(
            builder: (context, constraints) {
              return SingleChildScrollView(
                child: Column(
                  children: [
                    _scopeFovCard(constraints.maxWidth),
                    _controlsCard(),
                    _animatedMoverCard(),
                    _adjustmentsTable(),
                  ],
                ),
              );
            },
          ),
        ),
      ),
    );
  }

  // ─────────────────────── FOV (the round eyepiece) ───────────────────────

  Widget _scopeFovCard(double availableWidth) {
    final theme = Theme.of(context);
    // Make the FOV a square that fits the narrower dimension comfortably.
    final fovSide =
        math.min(availableWidth - 16, MediaQuery.of(context).size.height * 0.6);
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 8, 8, 4),
      child: Stack(
        children: [
          // The black FOV circle. Wrapped in AnimatedBuilder so the
          // mover animation re-paints every frame while it's running.
          // When the animation is stopped the controller's value is
          // `0.5` (centered) and the painter renders the static frame.
          Center(
            child: SizedBox(
              width: fovSide,
              height: fovSide,
              child: ClipOval(
                // Layered eyepiece: daytime range backdrop at the bottom
                // (sky / horizon / grass / mound) so the reticle reads
                // against a representative downrange scene, the existing
                // FOV painter stacked on top (target + markers + reticle
                // + rim labels). The backdrop's own target is set to
                // `none` here because the FOV painter already draws the
                // user's chosen target spec — we only want the scenery
                // from the backdrop layer.
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    const ScopeDaytimeBackdrop(
                      target: BackdropTargetSilhouette.none,
                    ),
                    AnimatedBuilder(
                      animation: _moverController,
                      builder: (context, _) {
                        // Map controller [0..1] to a sweep [-1..+1] so the
                        // target travels left-to-right across the FOV
                        // (`reverse: true` gives us right-to-left on the
                        // return trip without extra math).
                        final phase = _animateMover
                            ? (_moverController.value * 2.0 - 1.0)
                            : 0.0;
                        return CustomPaint(
                          painter: _ScopeFovPainter(
                            reticle: widget.inputs.reticle,
                            reticleRenderScale: _reticleRenderScale(),
                            reticleColor: Colors.greenAccent,
                            targetSpec: widget.inputs.targetSpec,
                            rangeYards: _rangeYards,
                            magnification: _magnification,
                            fovHalfMil: _fovHalfMil(),
                            dropMil: _dropMil(),
                            windMil: _windMil(),
                            aimPointNormX: widget.inputs.aimPointX,
                            aimPointNormY: widget.inputs.aimPointY,
                            latestHitNormX: widget.inputs.latestImpactX,
                            latestHitNormY: widget.inputs.latestImpactY,
                            displayUnit: _displayUnit,
                            targetSweepPhase: phase,
                          ),
                        );
                      },
                    ),
                  ],
                ),
              ),
            ),
          ),
          // Tap the reticle to cycle subtension display unit.
          Positioned.fill(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: _cycleDisplayUnit,
            ),
          ),
          // Hit-probability badge in the top-right corner.
          if (widget.inputs.hitProbability != null)
            Positioned(
              right: 16,
              top: 12,
              child: _hitProbBadge(theme, widget.inputs.hitProbability!),
            ),
          // Magnification chip in the top-left corner (matches the way a
          // real scope's magnification ring sits opposite the eyepiece).
          Positioned(
            left: 16,
            top: 12,
            child: _magnificationBadge(theme),
          ),
          // Subtension unit chip — bottom of the FOV. Tap-zone is the
          // whole FOV but this chip makes the affordance discoverable.
          Positioned(
            left: 0,
            right: 0,
            bottom: 8,
            child: Center(child: _unitChip(theme)),
          ),
        ],
      ),
    );
  }

  Widget _hitProbBadge(ThemeData theme, double p) {
    final pct = (p * 100).clamp(0, 100).round();
    Color bg;
    if (pct >= 75) {
      bg = Colors.greenAccent.shade700;
    } else if (pct >= 40) {
      bg = Colors.amber.shade700;
    } else {
      bg = Colors.redAccent.shade400;
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(20),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.5),
            blurRadius: 4,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.bolt, size: 16, color: Colors.white),
          const SizedBox(width: 4),
          Text(
            '$pct% hit',
            style: theme.textTheme.labelMedium?.copyWith(
              color: Colors.white,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }

  Widget _magnificationBadge(ThemeData theme) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.55),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: Colors.white24),
      ),
      child: Text(
        '${_magnification.toStringAsFixed(1)}x',
        style: theme.textTheme.labelMedium?.copyWith(
          color: Colors.white,
          fontFeatures: const [FontFeature.tabularFigures()],
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }

  Widget _unitChip(ThemeData theme) {
    final label = switch (_displayUnit) {
      ScopeSubtensionUnit.moa => 'MOA · tap reticle to change',
      ScopeSubtensionUnit.mil => 'MIL · tap reticle to change',
      ScopeSubtensionUnit.inches => 'inches · tap reticle to change',
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.55),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: Colors.white24),
      ),
      child: Text(
        label,
        style: theme.textTheme.labelSmall?.copyWith(color: Colors.white70),
      ),
    );
  }

  // ─────────────────────── Controls ───────────────────────

  Widget _controlsCard() {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
      child: Card(
        color: theme.colorScheme.surface,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Icon(Icons.zoom_in, color: theme.colorScheme.primary),
                  const SizedBox(width: 8),
                  Text(
                    'Magnification',
                    style: theme.textTheme.titleSmall,
                  ),
                  const Spacer(),
                  Text(
                    '${_magnification.toStringAsFixed(1)}x',
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
                ],
              ),
              Slider(
                min: _minMagnification,
                max: _maxMagnification,
                divisions: ((_maxMagnification - _minMagnification) * 2).round(),
                value: _magnification,
                onChanged: (v) => setState(() => _magnification = v),
              ),
              const SizedBox(height: 4),
              Row(
                children: [
                  Icon(Icons.straighten, color: theme.colorScheme.primary),
                  const SizedBox(width: 8),
                  Text(
                    'Range',
                    style: theme.textTheme.titleSmall,
                  ),
                  const SizedBox(width: 12),
                  SizedBox(
                    width: 120,
                    child: TextField(
                      controller: _rangeCtrl,
                      decoration: const InputDecoration(
                        isDense: true,
                        suffixText: 'yd',
                        border: OutlineInputBorder(),
                      ),
                      keyboardType:
                          const TextInputType.numberWithOptions(decimal: true),
                      onChanged: _onRangeChanged,
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ─────────────────────── Animated mover (Pro) ───────────────────────
  //
  // Sweeps the target horizontally across the FOV at a user-chosen
  // speed. Useful for two distinct flows:
  //   1. Demo / teaching — at 0.1× the sweep takes 50 seconds, slow
  //      enough that the user can drag the reticle by hand to track
  //      the target while explaining lead concepts.
  //   2. Mover practice — at 4× the target races the FOV in 1.25 s,
  //      matching real PRS / 3-Gun mover stage cadence.
  //
  // The slider is continuous; the named presets show as labels under
  // the track at fixed positions so the user can snap to a remembered
  // cadence.

  Widget _animatedMoverCard() {
    final theme = Theme.of(context);
    final isSlowMode = _moverSpeedMultiplier <= 0.5;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
      child: Card(
        color: theme.colorScheme.surface,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Icon(Icons.directions_run,
                      color: theme.colorScheme.primary),
                  const SizedBox(width: 8),
                  Text(
                    'Animated mover',
                    style: theme.textTheme.titleSmall,
                  ),
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
                  Switch(
                    value: _animateMover,
                    onChanged: _toggleAnimateMover,
                  ),
                ],
              ),
              const SizedBox(height: 4),
              Slider(
                min: _moverSpeedMin,
                max: _moverSpeedMax,
                value: _moverSpeedMultiplier,
                label: '${_moverSpeedMultiplier.toStringAsFixed(2)}×',
                onChanged: _setMoverSpeedMultiplier,
              ),
              // Preset tick labels — Demo / Slow / Normal / Fast / Race.
              // Tappable so the user can snap to a remembered cadence.
              _MoverSpeedPresetRow(
                presets: _moverSpeedPresets,
                min: _moverSpeedMin,
                max: _moverSpeedMax,
                current: _moverSpeedMultiplier,
                onPick: _setMoverSpeedMultiplier,
              ),
              const SizedBox(height: 6),
              Text(
                isSlowMode
                    ? '${_moverSpeedMultiplier.toStringAsFixed(2)}× '
                        '(slow demo mode)'
                    : '${_moverSpeedMultiplier.toStringAsFixed(2)}× speed',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
              if (isSlowMode)
                Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: Text(
                    'Slow enough to move the reticle by hand.',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                      fontStyle: FontStyle.italic,
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  // ─────────────────────── Adjustments table ───────────────────────

  Widget _adjustmentsTable() {
    final theme = Theme.of(context);
    final dropMoa = bu.inchesToMoaAtYards(
      widget.inputs.dropInches,
      widget.inputs.rangeYards,
    );
    final dropMil = _dropMil();
    final windMoa = bu.inchesToMoaAtYards(
      widget.inputs.windDriftInches,
      widget.inputs.rangeYards,
    );
    final windMil = _windMil();

    final clickValue = widget.inputs.clickValue;
    // The click value is in the scope's adjustment unit; convert solution
    // into the same unit before dividing.
    final dropClicks = widget.inputs.adjustmentUnit.toLowerCase() == 'moa'
        ? (dropMoa / clickValue).abs()
        : (dropMil / clickValue).abs();
    final windClicks = widget.inputs.adjustmentUnit.toLowerCase() == 'moa'
        ? (windMoa / clickValue).abs()
        : (windMil / clickValue).abs();

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
      child: Card(
        color: theme.colorScheme.surface,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Icon(Icons.tune, color: theme.colorScheme.primary),
                  const SizedBox(width: 8),
                  Text(
                    'Adjustments at ${widget.inputs.rangeYards.toStringAsFixed(0)} yd',
                    style: theme.textTheme.titleMedium,
                  ),
                ],
              ),
              const SizedBox(height: 4),
              Text(
                'Click value: ${clickValue.toStringAsFixed(2)} ${widget.inputs.adjustmentUnit}',
                style: theme.textTheme.bodySmall,
              ),
              const SizedBox(height: 12),
              DefaultTextStyle.merge(
                style: const TextStyle(
                  fontFeatures: [FontFeature.tabularFigures()],
                ),
                child: Table(
                  columnWidths: const {
                    0: FlexColumnWidth(2),
                    1: FlexColumnWidth(2),
                    2: FlexColumnWidth(2),
                    3: FlexColumnWidth(2),
                    4: FlexColumnWidth(2),
                  },
                  children: [
                    TableRow(
                      decoration: BoxDecoration(
                        color: theme.colorScheme.surfaceContainerHighest,
                      ),
                      children: const [
                        _AdjHeaderCell(''),
                        _AdjHeaderCell('MOA'),
                        _AdjHeaderCell('MIL'),
                        _AdjHeaderCell('inches'),
                        _AdjHeaderCell('clicks'),
                      ],
                    ),
                    TableRow(children: [
                      const _AdjBodyCell.label('Up ↑'),
                      _AdjBodyCell(dropMoa.toStringAsFixed(2)),
                      _AdjBodyCell(dropMil.toStringAsFixed(2)),
                      _AdjBodyCell(
                          widget.inputs.dropInches.toStringAsFixed(1)),
                      _AdjBodyCell(dropClicks.toStringAsFixed(0)),
                    ]),
                    TableRow(children: [
                      const _AdjBodyCell.label('Wind →'),
                      _AdjBodyCell(windMoa.toStringAsFixed(2)),
                      _AdjBodyCell(windMil.toStringAsFixed(2)),
                      _AdjBodyCell(
                          widget.inputs.windDriftInches.toStringAsFixed(1)),
                      _AdjBodyCell(windClicks.toStringAsFixed(0)),
                    ]),
                  ],
                ),
              ),
              const SizedBox(height: 12),
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: theme.colorScheme.tertiaryContainer
                      .withValues(alpha: 0.4),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Row(
                  children: [
                    Icon(
                      Icons.center_focus_strong,
                      size: 18,
                      color: theme.colorScheme.onTertiaryContainer,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        'Reticle is anchored at the firing solution: '
                        'after dialing the elevation/wind above, '
                        'the crosshair will sit on the target.',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onTertiaryContainer,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ─────────────────────── Help dialog ───────────────────────

  void _showHelp(BuildContext context) {
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Scope View'),
        content: const SingleChildScrollView(
          child: Text(
            'A simulation of the view through your scope at the rendered '
            'magnification. The reticle is anchored at the firing solution '
            '(elevation + wind) so the crosshair sits on the target — what '
            'you should see when correctly dialed.\n\n'
            '• Tap the reticle to cycle MOA → MIL → inches.\n'
            '• The aim-point and latest-impact markers show where your '
            'last shot landed relative to your aim.\n'
            '• The badge in the top-right shows single-shot hit '
            'probability for the current setup.',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }
}

class _AdjHeaderCell extends StatelessWidget {
  const _AdjHeaderCell(this.text);
  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 8),
      child: Text(
        text,
        textAlign: TextAlign.center,
        style: Theme.of(context).textTheme.labelLarge?.copyWith(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
      ),
    );
  }
}

class _AdjBodyCell extends StatelessWidget {
  const _AdjBodyCell(this.text) : isLabel = false;
  const _AdjBodyCell.label(this.text) : isLabel = true;

  final String text;
  final bool isLabel;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 10),
      child: Text(
        text,
        textAlign: TextAlign.center,
        style: Theme.of(context).textTheme.bodyLarge?.copyWith(
              fontWeight: isLabel ? FontWeight.w600 : FontWeight.w500,
              color: Theme.of(context).colorScheme.onSurface,
            ),
      ),
    );
  }
}

// ============================================================================
// THE PAINTER
// ============================================================================
//
// Composites:
//   1. Reticle anchored at -(dropMil, windMil) in mil-space — i.e. when
//      the firing solution puts impact 8 mil down and 1.2 mil right of
//      LoS, we draw the reticle's 0,0 at +8 mil up and -1.2 mil left
//      of the FOV center, which makes the crosshair sit on the target.
//   2. Target rendered as a shape sized by `target_size / range × scope_mag`
//      and drawn at FOV center (the reticle moves around it).
//   3. Aim point + latest impact markers (◉) overlaid.
//   4. The reticle painter is drawn with the SAME ReticleRenderer-style
//      element loop as the existing widget; we copied the algorithm so
//      we can supply our own pxPerMil instead of the renderer's
//      half-extent autofit.

class _ScopeFovPainter extends CustomPainter {
  _ScopeFovPainter({
    required this.reticle,
    required this.reticleRenderScale,
    required this.reticleColor,
    required this.targetSpec,
    required this.rangeYards,
    required this.magnification,
    required this.fovHalfMil,
    required this.dropMil,
    required this.windMil,
    required this.aimPointNormX,
    required this.aimPointNormY,
    required this.latestHitNormX,
    required this.latestHitNormY,
    required this.displayUnit,
    this.targetSweepPhase = 0.0,
  });

  final ReticleDefinition reticle;
  final double reticleRenderScale;
  final Color reticleColor;
  final TargetSpec targetSpec;
  final double rangeYards;
  final double magnification;

  /// Half of the angular FOV in milliradians.
  final double fovHalfMil;
  final double dropMil;
  final double windMil;
  final double? aimPointNormX;
  final double? aimPointNormY;
  final double? latestHitNormX;
  final double? latestHitNormY;
  final ScopeSubtensionUnit displayUnit;

  /// Animated-mover phase, [-1, +1]. 0 = target dead-center; -1 = far
  /// left of FOV; +1 = far right. The painter scales the offset to
  /// `0.7 × fovHalfMil` so the target always stays visible inside the
  /// circle.
  final double targetSweepPhase;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.shortestSide <= 0 || fovHalfMil <= 0) return;

    final fovRadiusPx = size.shortestSide / 2 - 4;
    final centerPx = Offset(size.width / 2, size.height / 2);

    // pxPerMil is the same scale that converts BOTH the reticle's
    // native-unit geometry and the target's angular size into pixels.
    final pxPerMil = fovRadiusPx / fovHalfMil;

    // Native-unit → mil scale for the reticle (so a 1-mil hash on a
    // mil reticle and a 1-MOA hash on a MOA reticle each draw at the
    // right physical size).
    final nativeUnitToMil = switch (reticle.nativeUnit) {
      ReticleNativeUnit.mil => 1.0,
      ReticleNativeUnit.moa => 1.0 / milToMoa,
      ReticleNativeUnit.ipsc => 1.0,
      ReticleNativeUnit.bdc => 1.0,
    };
    final pxPerNativeUnit = pxPerMil * nativeUnitToMil * reticleRenderScale;

    // ── 1. Atmospheric / dim-glass backdrop. ────────────────────────────
    //
    // Used to be a flat dark fill (`0xFF050a05`). The parent now layers
    // a procedural daytime range scene (`ScopeDaytimeBackdrop`) BEHIND
    // this painter, so we don't draw a fill here anymore — that would
    // hide the sky / grass / mound / horizon. We do still apply a very
    // subtle vignette inside the FOV ring to suggest scope-glass
    // contrast and stop the reticle from getting lost on the brightest
    // sky pixels.
    final vignette = Paint()
      ..shader = RadialGradient(
        center: Alignment.center,
        radius: 1.05,
        colors: [
          Colors.transparent,
          Colors.black.withValues(alpha: 0.10),
          Colors.black.withValues(alpha: 0.22),
        ],
        stops: const [0.0, 0.85, 1.0],
      ).createShader(Rect.fromCircle(
        center: centerPx,
        radius: fovRadiusPx,
      ));
    canvas.drawCircle(centerPx, fovRadiusPx, vignette);

    // ── 2. Target. Centered at FOV center; the reticle is what moves. ──
    _paintTarget(canvas, centerPx, pxPerMil);

    // ── 3. Aim-point / impact markers (relative to target geometry). ───
    _paintMarkers(canvas, centerPx, pxPerMil);

    // ── 4. Reticle. Anchored so the crosshair sits on the target. ──────
    //
    // Solution: in shooter-space the bullet impacts dropMil DOWN and
    // windMil RIGHT of LoS. To compensate the user dials the turret UP
    // by dropMil and LEFT by windMil — which moves the reticle's
    // perceived center DOWN by dropMil and RIGHT by windMil within the
    // FOV (because the LoS through the reticle swings about the
    // erector). We model that here by offsetting the reticle's drawing
    // origin by (+windMil, -dropMil) in mil-space (canvas Y flipped:
    // we're drawing IN pixel coordinates where +Y is down).
    //
    // Equivalent way to think about it: the reticle's geometric center
    // is what the shooter is now placing on the target. The center had
    // to shift by the negative of the bullet's drop/wind to put the
    // crosshair on the target.
    final reticleCenter = Offset(
      centerPx.dx + windMil * pxPerMil,
      centerPx.dy + dropMil * pxPerMil,
    );
    _paintReticle(canvas, reticleCenter, pxPerNativeUnit);

    // ── 5. FOV outline ring + thin brand-style border. ─────────────────
    canvas.drawCircle(
      centerPx,
      fovRadiusPx,
      Paint()
        ..color = Colors.white24
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5,
    );
    canvas.drawCircle(
      centerPx,
      fovRadiusPx + 2,
      Paint()
        ..color = Colors.black
        ..style = PaintingStyle.stroke
        ..strokeWidth = 4,
    );

    // ── 6. Cardinal subtension labels on the rim. ──────────────────────
    _paintRimSubtensions(canvas, centerPx, fovRadiusPx, pxPerMil);
  }

  void _paintTarget(Canvas canvas, Offset center, double pxPerMil) {
    // angular size = physical / range. Use the small-angle approximation
    // (mil = inches / (yd × 36) × 1000), accurate to <0.5% out to a few
    // thousand yards.
    final widthMil =
        targetSpec.widthIn / (rangeYards * 36.0) * 1000.0;
    final heightMil =
        targetSpec.heightIn / (rangeYards * 36.0) * 1000.0;
    final wPx = widthMil * pxPerMil;
    final hPx = heightMil * pxPerMil;

    // When the animated mover is running, slide the target left/right
    // by `targetSweepPhase × 0.7 × fovHalfMil`. The 0.7 factor leaves a
    // visible margin so the target shape doesn't disappear behind the
    // FOV ring at the extremes.
    final sweepOffsetMil = targetSweepPhase * 0.7 * fovHalfMil;
    final sweepOffsetPx = sweepOffsetMil * pxPerMil;
    final movingCenter = Offset(center.dx + sweepOffsetPx, center.dy);

    final rect = Rect.fromCenter(
      center: movingCenter,
      width: math.max(2, wPx),
      height: math.max(2, hPx),
    );
    final color = _parseColor(targetSpec.colorHex);
    final fill = Paint()..color = color.withValues(alpha: 0.85);
    final outline = Paint()
      ..color = Colors.black
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5;
    switch (targetSpec.category) {
      case 'circle':
        canvas.drawCircle(movingCenter, math.min(wPx, hPx) / 2, fill);
        canvas.drawCircle(movingCenter, math.min(wPx, hPx) / 2, outline);
        break;
      case 'silhouette':
        // Approximate as a rounded rectangle so the shape reads as a
        // human silhouette without dragging in a path resource.
        final rrect = RRect.fromRectAndRadius(
          rect,
          Radius.circular(math.min(wPx, hPx) * 0.15),
        );
        canvas.drawRRect(rrect, fill);
        canvas.drawRRect(rrect, outline);
        break;
      default:
        canvas.drawRect(rect, fill);
        canvas.drawRect(rect, outline);
    }
  }

  void _paintMarkers(Canvas canvas, Offset center, double pxPerMil) {
    final widthMil =
        targetSpec.widthIn / (rangeYards * 36.0) * 1000.0;
    final heightMil =
        targetSpec.heightIn / (rangeYards * 36.0) * 1000.0;
    // Aim point + impact markers are stored relative to the target
    // shape, so they have to follow the target when the mover sweeps.
    final sweepOffsetPx =
        targetSweepPhase * 0.7 * fovHalfMil * pxPerMil;
    Offset normToPx(double nx, double ny) {
      // Norm (-1..1) maps to half-width × pxPerMil in each direction.
      // +y in normalized = up; canvas +y = down, so flip.
      return Offset(
        center.dx + sweepOffsetPx + nx * (widthMil / 2) * pxPerMil,
        center.dy - ny * (heightMil / 2) * pxPerMil,
      );
    }

    // Aim point — small ring (◉) that the reticle is supposed to hit.
    if (aimPointNormX != null && aimPointNormY != null) {
      final p = normToPx(aimPointNormX!, aimPointNormY!);
      final stroke = Paint()
        ..color = Colors.cyanAccent
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.4;
      canvas.drawCircle(p, 7, stroke);
      canvas.drawCircle(
        p,
        2.5,
        Paint()..color = Colors.cyanAccent,
      );
    }

    // Latest hit — solid filled marker in red so it stands apart from
    // the aim point.
    if (latestHitNormX != null && latestHitNormY != null) {
      final p = normToPx(latestHitNormX!, latestHitNormY!);
      canvas.drawCircle(
        p,
        6,
        Paint()..color = const Color(0xFFef5350),
      );
      canvas.drawCircle(
        p,
        6,
        Paint()
          ..color = Colors.white
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.0,
      );
    }
  }

  /// Draws each [ReticleElement] of [reticle] at [center] in pixel space.
  /// Mirrors `lib/widgets/reticle_renderer.dart`'s element loop but uses
  /// our externally-controlled `pxPerNativeUnit` (so we honour the
  /// FOV scaling) instead of the renderer's autofit.
  void _paintReticle(
    Canvas canvas,
    Offset center,
    double pxPerNativeUnit,
  ) {
    Offset toPx(double xUnits, double yUnits) {
      // +y in reticle = up; canvas +y = down. Flip Y when projecting.
      return Offset(
        center.dx + xUnits * pxPerNativeUnit,
        center.dy - yUnits * pxPerNativeUnit,
      );
    }

    final stroke = Paint()
      ..color = reticleColor
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.butt;
    final fill = Paint()
      ..color = reticleColor
      ..style = PaintingStyle.fill;

    for (final el in reticle.elements) {
      switch (el) {
        case CrosshairLine():
          stroke.strokeWidth =
              (el.thicknessMil * pxPerNativeUnit).clamp(0.6, 6.0);
          canvas.drawLine(
            toPx(el.startX, el.startY),
            toPx(el.endX, el.endY),
            stroke,
          );
        case HashMark():
          stroke.strokeWidth =
              (el.thicknessUnits * pxPerNativeUnit).clamp(0.4, 4.0);
          final half = el.lengthUnits / 2;
          if (el.axis == HashAxis.horizontal) {
            canvas.drawLine(
              toPx(el.x, el.y - half),
              toPx(el.x, el.y + half),
              stroke,
            );
          } else {
            canvas.drawLine(
              toPx(el.x - half, el.y),
              toPx(el.x + half, el.y),
              stroke,
            );
          }
        case CenterDot():
          final r = (el.radiusUnits * pxPerNativeUnit).clamp(0.6, 8.0);
          if (el.open) {
            stroke.strokeWidth = (r * 0.25).clamp(0.5, 2.0);
            canvas.drawCircle(toPx(el.x, el.y), r, stroke);
          } else {
            canvas.drawCircle(toPx(el.x, el.y), r, fill);
          }
        case HoldoverDot():
          final r = (el.radiusUnits * pxPerNativeUnit).clamp(0.6, 8.0);
          canvas.drawCircle(toPx(el.x, el.y), r, fill);
        case FloatingNumber():
          final fs =
              (el.fontSizeUnits * pxPerNativeUnit).clamp(8.0, 24.0);
          final tp = TextPainter(
            text: TextSpan(
              text: el.text,
              style: TextStyle(
                color: reticleColor,
                fontSize: fs,
                fontWeight: FontWeight.w500,
              ),
            ),
            textDirection: TextDirection.ltr,
          )..layout();
          final pt = toPx(el.x, el.y);
          tp.paint(canvas, pt - Offset(tp.width / 2, tp.height / 2));
      }
    }
  }

  /// Draw the four cardinal-direction subtension labels around the FOV
  /// rim, in whichever unit the user has tapped to.
  void _paintRimSubtensions(
    Canvas canvas,
    Offset center,
    double fovRadiusPx,
    double pxPerMil,
  ) {
    // We label the visible half-extent in the chosen unit. inches uses
    // a small-angle conversion at the active range.
    final halfMil = fovHalfMil;
    final value = switch (displayUnit) {
      ScopeSubtensionUnit.mil => halfMil,
      ScopeSubtensionUnit.moa => halfMil * milToMoa,
      ScopeSubtensionUnit.inches =>
        halfMil * (rangeYards * 36.0) / 1000.0,
    };
    final unitLabel = switch (displayUnit) {
      ScopeSubtensionUnit.mil => 'mil',
      ScopeSubtensionUnit.moa => 'MOA',
      ScopeSubtensionUnit.inches => 'in',
    };
    final txt = '${value.toStringAsFixed(displayUnit == ScopeSubtensionUnit.inches ? 0 : 1)} $unitLabel';
    final tp = TextPainter(
      text: TextSpan(
        text: txt,
        style: const TextStyle(
          color: Colors.white60,
          fontSize: 11,
          fontWeight: FontWeight.w500,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    // Place at the right rim, just inside the FOV ring.
    tp.paint(
      canvas,
      Offset(
        center.dx + fovRadiusPx - tp.width - 6,
        center.dy - tp.height / 2,
      ),
    );
  }

  Color _parseColor(String hex) {
    final cleaned = hex.replaceAll('#', '');
    if (cleaned.length != 6) return const Color(0xFFf5f5f5);
    return Color(int.parse('ff$cleaned', radix: 16));
  }

  @override
  bool shouldRepaint(covariant _ScopeFovPainter old) {
    return old.reticle.id != reticle.id ||
        old.reticleRenderScale != reticleRenderScale ||
        old.targetSpec.widthIn != targetSpec.widthIn ||
        old.targetSpec.heightIn != targetSpec.heightIn ||
        old.targetSpec.category != targetSpec.category ||
        old.targetSpec.colorHex != targetSpec.colorHex ||
        old.rangeYards != rangeYards ||
        old.magnification != magnification ||
        old.fovHalfMil != fovHalfMil ||
        old.dropMil != dropMil ||
        old.windMil != windMil ||
        old.aimPointNormX != aimPointNormX ||
        old.aimPointNormY != aimPointNormY ||
        old.latestHitNormX != latestHitNormX ||
        old.latestHitNormY != latestHitNormY ||
        old.displayUnit != displayUnit ||
        old.targetSweepPhase != targetSweepPhase;
  }
}

// ============================================================================
// HELPER: build inputs from the Range Day detail screen's state.
// ============================================================================

/// Builds a [ScopeViewInputs] bag from the Range Day workspace's current
/// state. This factory is kept here (next to the screen) so the parent
/// only needs to hand us its raw state and we encapsulate every default
/// (default click value per scope unit, 10x default magnification, etc.).
ScopeViewInputs buildScopeViewInputs({
  required ReticleDefinition reticle,
  required TargetSpec targetSpec,
  required double dropInches,
  required double windDriftInches,
  required double rangeYards,
  required double? aimPointX,
  required double? aimPointY,
  required double? latestImpactX,
  required double? latestImpactY,
  required HitProbabilityResult? hitProb,
  OpticRow? optic,
  String? opticName,
}) {
  // Default magnification = the optic's high mag if known, else 10x.
  // We parse "6-36x" / "4.5-27x" / "1-6x" / "1x" patterns and keep the
  // rightmost numeric token as the spec magnification.
  double specMag = 10.0;
  double initialMag = 10.0;
  String adjustmentUnit = 'MIL';
  String focalPlane = 'first';
  if (optic != null) {
    specMag = _parseMaxMag(optic.magnification) ?? specMag;
    initialMag = specMag.clamp(4.5, 30.0);
    adjustmentUnit = optic.adjustmentUnit.toUpperCase().contains('MOA')
        ? 'MOA'
        : 'MIL';
    focalPlane = optic.focalPlane.toLowerCase();
  }
  // Default click value: 0.25 MOA for SFP MOA, 0.1 MIL for FFP MIL.
  final clickValue = adjustmentUnit == 'MOA' ? 0.25 : 0.1;

  return ScopeViewInputs(
    reticle: reticle,
    targetSpec: targetSpec,
    dropInches: dropInches,
    windDriftInches: windDriftInches,
    rangeYards: rangeYards,
    aimPointX: aimPointX,
    aimPointY: aimPointY,
    latestImpactX: latestImpactX,
    latestImpactY: latestImpactY,
    hitProbability: hitProb?.hitProbability,
    scopeMagnification: initialMag,
    spec1xMagnification: specMag,
    scopeFocalPlane: focalPlane,
    adjustmentUnit: adjustmentUnit,
    clickValue: clickValue,
    opticName: opticName,
  );
}

/// Parses "1-6x", "6-36x", "4.5-27x", "1x" into the upper magnification
/// number. Returns null on parse failure.
double? _parseMaxMag(String s) {
  final m = RegExp(r'(\d+(?:\.\d+)?)\s*x', caseSensitive: false).allMatches(s);
  if (m.isEmpty) return null;
  // Last numeric "Xx" token is the high end of the range.
  return double.tryParse(m.last.group(1) ?? '');
}

/// One named preset along the animated-mover speed slider. Holds the
/// multiplier value and the user-facing label ("Demo", "Slow", …). The
/// label is rendered under the slider track at the value's relative
/// position, and tapping the label snaps the slider to that value.
class _MoverSpeedPreset {
  const _MoverSpeedPreset({required this.value, required this.label});
  final double value;
  final String label;
}

/// Renders the named-preset labels under the animated-mover slider.
/// Each label is a small `TextButton` that snaps the slider to the
/// preset's multiplier when tapped.
class _MoverSpeedPresetRow extends StatelessWidget {
  const _MoverSpeedPresetRow({
    required this.presets,
    required this.min,
    required this.max,
    required this.current,
    required this.onPick,
  });

  final List<_MoverSpeedPreset> presets;
  final double min;
  final double max;
  final double current;
  final void Function(double) onPick;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return LayoutBuilder(
      builder: (context, constraints) {
        return SizedBox(
          height: 24,
          child: Stack(
            clipBehavior: Clip.none,
            children: [
              for (final p in presets) _label(theme, p, constraints.maxWidth),
            ],
          ),
        );
      },
    );
  }

  Widget _label(
    ThemeData theme,
    _MoverSpeedPreset preset,
    double trackWidth,
  ) {
    // Linear position on the slider track. The Slider widget's track
    // padding is roughly 24 px each side; we approximate by leaving
    // 12 px of margin so the labels visually line up with the thumb
    // positions. Off-by-a-few px under typical font metrics is fine —
    // the labels are advisory.
    const double trackPad = 12.0;
    final usable = (trackWidth - trackPad * 2).clamp(1.0, double.infinity);
    final t = ((preset.value - min) / (max - min)).clamp(0.0, 1.0);
    final left = trackPad + t * usable;
    final selected = (preset.value - current).abs() < 0.001;
    return Positioned(
      left: left - 28,
      child: SizedBox(
        width: 56,
        child: TextButton(
          style: TextButton.styleFrom(
            padding: EdgeInsets.zero,
            minimumSize: const Size(0, 0),
            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          ),
          onPressed: () => onPick(preset.value),
          child: Text(
            preset.label,
            textAlign: TextAlign.center,
            style: theme.textTheme.labelSmall?.copyWith(
              color: selected
                  ? theme.colorScheme.primary
                  : theme.colorScheme.onSurfaceVariant,
              fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
            ),
          ),
        ),
      ),
    );
  }
}
