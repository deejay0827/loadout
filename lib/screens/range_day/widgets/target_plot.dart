// FILE: lib/screens/range_day/widgets/target_plot.dart
//
// ============================================================================
// WHAT THIS FILE DOES
// ============================================================================
// Visual target widget for the Range Day workspace. Renders the chosen
// target (paper / steel / silhouette) inside a box, with each recorded
// `ShotImpactRow` drawn as a small dot at the stored normalized
// (-1..1, -1..1) position.
//
// Two tap modes (selected by the parent via [tapMode]):
//
//   * `TargetPlotTapMode.aimPoint` — taps move the aim marker via
//     [onAimPointSet]. The marker renders as a small crosshair at the
//     normalized (-1..1, -1..1) location stored on the session row.
//   * `TargetPlotTapMode.recordShot` — taps register a new impact via
//     [onTapAt] (existing behaviour).
//
// Two view modes (selected by the parent via [viewMode]):
//
//   * `TargetPlotViewMode.targetFocused` (default) — the target fills the
//     widget box at its true aspect ratio. Best for accurate dot
//     placement: maximum tap area, easiest to long-press a specific
//     impact, easiest to read distance between hits.
//   * `TargetPlotViewMode.realistic` — composes a daytime range scene
//     (sky + grass + dirt mound for singles, sky + grass for racks),
//     places the target on a pole or hangs rack children from chains,
//     and overlays a circular scope reticle on top. Approximates "what
//     you actually see through a scope at the range".
//
// In both modes a tap inside the target area still maps to the same
// normalized (-1..1, -1..1) coordinates so the parent's `onTapAt` /
// `onAimPointSet` callbacks behave identically and previously-recorded
// shots / aim points stay positionally consistent across mode switches.
//
// When a [reticle] is provided in `targetFocused` mode, the renderer
// paints a [ReticleRenderer] overlay anchored on the aim marker (or
// target center if no aim point is set). In `realistic` mode the
// reticle is drawn natively by the painter chain inside the scope ring
// — the [reticle] parameter is accepted but ignored in favour of the
// dedicated precision-mil reticle that matches the reference look.
//
// Rack vs single dispatch (realistic mode):
//
//   * Single target — pole rises from a soft dirt mound; target stands
//     on top.
//   * Rack target ([rackChildren] non-null) — horizontal cross-bar at
//     top; each child hangs from a dashed chain. No dirt mound; grass
//     runs to the bottom edge. The active child (by
//     [activeRackChildIndex]) is rendered at full opacity with a
//     bolder outline and gets the aim-point + shot-dots overlay; the
//     other children render at 70% opacity.
//
// ============================================================================
// WHY IT EXISTS IN THE ARCHITECTURE
// ============================================================================
// Range Day's interactive target surface lives here so the parent
// screen (`range_day_detail_screen.dart`) can stay focused on session
// state + ballistic math. The widget is intentionally stateless —
// every interaction bubbles up through the callback parameters and the
// parent owns the database side.
//
// Realistic mode is intentionally separate from target-focused mode at
// the painter level. They share the (-1..1, -1..1) coordinate contract
// but the visual chains diverge: target-focused mode renders one shape
// onto a flat background, realistic mode composes a full daytime scene
// behind a circular scope. Mixing both into a single painter would
// either bloat its responsibilities or leak realistic-mode concepts
// (sky / grass / scope ring) into the simpler default path.
//
// ============================================================================
// WHY THIS IS HARDER THAN IT LOOKS
// ============================================================================
//   * Normalized coordinates (-1..1, -1..1) are the wire format for
//     persisted shots and aim points. Both view modes share the same
//     coordinate space — the painter / hit-test math just changes the
//     pixel rectangle the (-1..1, -1..1) box occupies. Switching modes
//     never re-normalizes the stored impact rows.
//   * The Y axis is flipped at the screen boundary so +1 = top (matches
//     the shooter's mental model). Don't move that flip out of the
//     widget — every persisted shot in the DB assumes this convention.
//   * Realistic mode composes ScopeDaytimeBackdropPainter (with target
//     silhouette disabled) so the painter chain stays on a single
//     `CustomPaint`. We can't drop the `ScopeDaytimeBackdrop` widget
//     into a Stack here because we want the backdrop, the pole/chains,
//     and the target silhouettes to share one repaint pass + one
//     repaint boundary — keeping the painter call cheap on the hot
//     path.
//   * In rack mode, the (-1..1, -1..1) box is anchored on the *active
//     child*, not the whole rack. Tap math measures from the active
//     child's bounding box so the persisted shot coordinates remain
//     comparable across child switches.
//   * Default aim-point fallback: when both `aimPointX` and `aimPointY`
//     are null, the realistic-mode reticle is drawn at the active
//     target's geometric center (normalized 0, 0) so first-time users
//     see a reticle squarely on the target instead of floating on the
//     scope edge. The target-focused reticle keeps the same fallback
//     for consistency.
//
// ============================================================================
// WHO CONSUMES THIS FILE
// ============================================================================
//   * lib/screens/range_day/range_day_detail_screen.dart — the only
//     consumer today. The parent passes `rackChildren` +
//     `activeRackChildIndex` whenever a rack target is active so the
//     realistic painter knows to render chains instead of a pole.
//
// ============================================================================
// SIDE EFFECTS
// ============================================================================
// None — purely visual. The parent owns persistence and any database
// I/O triggered by the callbacks.

import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../data/reticle_library.dart';
import '../../../database/database.dart';
import '../../../widgets/reticle_renderer.dart';
import '../../../widgets/scope_daytime_backdrop.dart';

/// Two interaction modes for the target plot.
enum TargetPlotTapMode {
  /// Tap moves the aim marker.
  aimPoint,

  /// Tap records a new shot impact (legacy behaviour).
  recordShot,
}

/// Two visual presentations for the target plot. The (-1..1, -1..1)
/// normalized coordinate system is identical in both modes — the only
/// difference is how much of the widget box the target itself fills.
enum TargetPlotViewMode {
  /// Composes a daytime range scene (sky + grass + dirt mound or
  /// chains) with a circular scope reticle overlay. Targets stand on
  /// a pole; rack children hang from chains. Approximates the
  /// "what you'd actually see through a scope" view.
  realistic,

  /// Target fills the widget box at its true aspect ratio. Maximum
  /// tap area + easiest dot placement. Default.
  targetFocused,
}

/// Simple struct describing how the target should render. Lets the
/// parent stay in control of which target row is active without
/// passing the whole [TargetRow] in.
class TargetSpec {
  const TargetSpec({
    required this.shape,
    required this.widthIn,
    required this.heightIn,
    required this.colorHex,
  });

  /// 'circle' | 'square' | 'rectangle' | 'silhouette' | 'irregular'
  final String shape;
  final double widthIn;
  final double heightIn;
  final String colorHex;

  /// Default target used when the user hasn't picked one yet — a
  /// small white square that still gives the user something to tap on.
  factory TargetSpec.defaultPaper() => const TargetSpec(
        shape: 'square',
        widthIn: 12,
        heightIn: 12,
        colorHex: '#ffffff',
      );

  factory TargetSpec.fromRow(TargetRow row) => TargetSpec(
        shape: row.shape,
        widthIn: row.widthIn,
        heightIn: row.heightIn,
        colorHex: row.colorHex,
      );
}

/// One child in a rack. Compact value type so the parent screen can
/// derive it from its `TargetRackChildRow` without dragging the drift
/// type into the widget layer.
///
/// Coordinates: `offsetXFromCenterIn` is in inches relative to the
/// rack's geometric center, positive = right. The realistic painter
/// uses these offsets to lay out children left-to-right under the
/// cross-bar.
class RackChildSpec {
  const RackChildSpec({
    required this.widthIn,
    required this.heightIn,
    required this.shape,
    required this.offsetXFromCenterIn,
    this.colorHex = '#ffffff',
  });

  /// Plate / popper / silhouette width in inches.
  final double widthIn;

  /// Plate / popper / silhouette height in inches.
  final double heightIn;

  /// 'circle' | 'square' | 'rectangle' | 'silhouette' | 'irregular' —
  /// matches the [TargetSpec.shape] vocabulary.
  final String shape;

  /// X offset from the rack's geometric center, in inches. Positive =
  /// right, negative = left. Used to lay out children horizontally
  /// under the cross-bar.
  final double offsetXFromCenterIn;

  /// CSS-style hex color, e.g. "#ffffff". Defaults to white.
  final String colorHex;
}

class TargetPlot extends StatelessWidget {
  const TargetPlot({
    super.key,
    required this.target,
    required this.shots,
    required this.onTapAt,
    required this.onLongPressShot,
    this.tapMode = TargetPlotTapMode.recordShot,
    this.viewMode = TargetPlotViewMode.targetFocused,
    this.aimPointX,
    this.aimPointY,
    this.onAimPointSet,
    this.reticle,
    this.reticleDisplayUnit = 'mil',
    this.rackChildren,
    this.activeRackChildIndex,
  });

  /// Target geometry / color. In rack mode this is the active child's
  /// geometry — the parent is responsible for picking which child is
  /// active and passing its dimensions through.
  final TargetSpec target;

  /// Recorded shots to render. Latest shot is highlighted differently.
  final List<ShotImpactRow> shots;

  /// Called when the user taps inside the target area in
  /// `recordShot` mode. Coordinates are normalized (-1..1 horizontal,
  /// -1..1 vertical with +1 at the top).
  final void Function(double normX, double normY) onTapAt;

  /// Called when the user long-presses a recorded shot dot. The parent
  /// uses this to offer edit / delete on the impact.
  final void Function(ShotImpactRow shot) onLongPressShot;

  /// Active tap interpretation. See [TargetPlotTapMode].
  final TargetPlotTapMode tapMode;

  /// Active visual presentation. See [TargetPlotViewMode]. Defaults to
  /// `targetFocused` (matches behaviour before the toggle existed).
  final TargetPlotViewMode viewMode;

  /// Aim point in normalized coords; null means no aim placed yet.
  /// In realistic mode null falls back to (0, 0) so the reticle lands
  /// on the target center on first display.
  final double? aimPointX;
  final double? aimPointY;

  /// Called in [TargetPlotTapMode.aimPoint] mode when the user taps
  /// inside the target area to (re)place the aim marker.
  final void Function(double normX, double normY)? onAimPointSet;

  /// Optional reticle to render as an overlay on the aim point. Only
  /// used in `targetFocused` mode — `realistic` mode draws a built-in
  /// precision-mil reticle inside the scope ring so the look matches
  /// the reference exactly.
  final ReticleDefinition? reticle;

  /// 'mil' or 'moa' — passed through to the reticle renderer for the
  /// floating-number labels (target-focused mode only).
  final String reticleDisplayUnit;

  /// When non-null, the realistic-mode painter renders this list of
  /// rack children hanging from a horizontal cross-bar with chains.
  /// Only the child at [activeRackChildIndex] is highlighted; the
  /// others render at slightly reduced opacity. When null, the widget
  /// renders a single target on a pole (the default).
  final List<RackChildSpec>? rackChildren;

  /// Index of the active rack child inside [rackChildren] (the child
  /// receiving aim-point taps + shot-dot overlay). Ignored when
  /// [rackChildren] is null. Out-of-range values are clamped.
  final int? activeRackChildIndex;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // Outer-box aspect ratio depends on the view mode. Target-focused
    // matches the target's real ratio so it fills the box; realistic
    // sits the target inside a wider 4:3 frame so there's room for
    // reticle holdovers and an obvious "scope sees more than just the
    // target" feel. We never let realistic mode get narrower than the
    // target itself (very tall targets keep their own ratio).
    final targetRatio = target.widthIn / target.heightIn;
    final outerRatio = viewMode == TargetPlotViewMode.realistic
        ? math.max(targetRatio, 4 / 3)
        : targetRatio;
    return AspectRatio(
      aspectRatio: outerRatio,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final outerSize =
              Size(constraints.maxWidth, constraints.maxHeight);
          // Compute the rectangle the active target occupies inside
          // the outer box. In target-focused mode it fills the box; in
          // realistic mode it's centered above the dirt mound (single)
          // or under the cross-bar (rack). The (-1..1, -1..1)
          // coordinate system is anchored to this rectangle in both
          // modes — that's what keeps tap behavior identical when the
          // user flips the toggle.
          final layout = _RealisticLayout.compute(
            outerSize: outerSize,
            targetWidthIn: target.widthIn,
            targetHeightIn: target.heightIn,
            rackChildren: rackChildren,
            activeRackChildIndex: activeRackChildIndex,
          );
          final targetRect = viewMode == TargetPlotViewMode.targetFocused
              ? Offset.zero & outerSize
              : layout.activeChildRect;
          // Pixel position of the aim marker. Realistic mode falls
          // back to (0, 0) when the parent hasn't set an aim point so
          // the reticle lands on the target center.
          final ax = aimPointX ??
              (viewMode == TargetPlotViewMode.realistic ? 0.0 : null);
          final ay = aimPointY ??
              (viewMode == TargetPlotViewMode.realistic ? 0.0 : null);
          Offset? aimPx;
          if (ax != null && ay != null) {
            aimPx = _normalizedToOffsetIn(ax, ay, targetRect);
          }
          return GestureDetector(
            onTapDown: (details) =>
                _handleTap(details.localPosition, targetRect),
            onLongPressStart: (details) =>
                _handleLongPress(details.localPosition, targetRect),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: Stack(
                children: [
                  if (viewMode == TargetPlotViewMode.realistic)
                    CustomPaint(
                      size: outerSize,
                      painter: _RealisticTargetPainter(
                        target: target,
                        shots: shots,
                        aimPointX: ax,
                        aimPointY: ay,
                        layout: layout,
                        primary: theme.colorScheme.primary,
                        errorColor: theme.colorScheme.error,
                        textColor: theme.colorScheme.onSurface,
                      ),
                    )
                  else
                    CustomPaint(
                      size: outerSize,
                      painter: _TargetPainter(
                        target: target,
                        shots: shots,
                        aimPointX: aimPointX,
                        aimPointY: aimPointY,
                        targetRect: targetRect,
                        outlineColor: theme.colorScheme.outline,
                        primary: theme.colorScheme.primary,
                        errorColor: theme.colorScheme.error,
                        textColor: theme.colorScheme.onSurface,
                        backgroundColor:
                            theme.colorScheme.surfaceContainerLowest,
                      ),
                    ),
                  // Reticle overlay anchored to the aim marker. Only
                  // drawn in target-focused mode — the realistic
                  // painter draws its own precision reticle inside the
                  // scope ring to match the reference exactly. When no
                  // aim point is set, the overlay sits at the geometric
                  // center of the target rectangle (NOT the outer box).
                  if (reticle != null &&
                      viewMode == TargetPlotViewMode.targetFocused)
                    IgnorePointer(
                      // ignore taps so they reach the gesture detector.
                      child: ReticleRenderer(
                        reticle: reticle!,
                        displayUnit: reticleDisplayUnit,
                        scale: 0.75,
                        color: theme.colorScheme.tertiary,
                        aimPoint: aimPx ?? targetRect.center,
                        size: outerSize,
                        showUnitOverlay: false,
                      ),
                    ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  void _handleTap(Offset localPos, Rect targetRect) {
    final norm = _toNormalized(localPos, targetRect);
    if (norm == null) return;
    if (tapMode == TargetPlotTapMode.aimPoint) {
      final cb = onAimPointSet;
      if (cb != null) cb(norm.dx, norm.dy);
    } else {
      onTapAt(norm.dx, norm.dy);
    }
  }

  /// Convert normalized (-1..1, -1..1) to widget-local pixel coords
  /// inside [rect] with the same flip applied by the painter
  /// (top = small y).
  Offset _normalizedToOffsetIn(double nx, double ny, Rect rect) {
    final cx = rect.center.dx;
    final cy = rect.center.dy;
    final halfW = rect.width / 2;
    final halfH = rect.height / 2;
    return Offset(cx + nx * halfW, cy - ny * halfH);
  }

  void _handleLongPress(Offset localPos, Rect targetRect) {
    final norm = _toNormalized(localPos, targetRect);
    if (norm == null) return;
    // Find the closest shot within a generous touch radius and surface it
    // up. We compare in NORMALIZED units so the test is consistent across
    // different render sizes AND across both view modes (the rect that
    // anchors normalized coords differs by mode, but normalized coords
    // themselves are mode-invariant).
    ShotImpactRow? closest;
    double closestDist2 = double.infinity;
    for (final shot in shots) {
      final dx = shot.impactX - norm.dx;
      final dy = shot.impactY - norm.dy;
      final d2 = dx * dx + dy * dy;
      if (d2 < closestDist2) {
        closestDist2 = d2;
        closest = shot;
      }
    }
    if (closest == null) return;
    // Touch slop ~ 8% of target width — generous for gloved range use.
    if (closestDist2 < 0.08 * 0.08) {
      onLongPressShot(closest);
    }
  }

  /// Convert a tap location in widget-local pixels into normalized
  /// (-1..1, -1..1) coordinates anchored on [targetRect]. Returns null
  /// if the tap is outside the rendered target rectangle (we don't want
  /// to record a shot if the user tapped the gutter / framing area).
  Offset? _toNormalized(Offset localPos, Rect targetRect) {
    final cx = targetRect.center.dx;
    final cy = targetRect.center.dy;
    final halfW = targetRect.width / 2;
    final halfH = targetRect.height / 2;
    if (halfW <= 0 || halfH <= 0) return null;
    final nx = (localPos.dx - cx) / halfW;
    // Flip Y so +1 = top, -1 = bottom (matches shooter's mental model).
    final ny = -(localPos.dy - cy) / halfH;
    if (nx < -1 || nx > 1 || ny < -1 || ny > 1) return null;
    return Offset(nx, ny);
  }
}

/// Geometry pre-compute for realistic mode. Holds the pixel rectangles
/// and key Y values shared between every painter pass so they don't
/// recompute the same trig in `paint()`.
///
/// Why a value type and not raw fields on the painter: `shouldRepaint`
/// equality stays trivial — when the layout's hash collides with the
/// previous one, no relayout happened, no repaint needed.
class _RealisticLayout {
  const _RealisticLayout({
    required this.outerSize,
    required this.scopeCenter,
    required this.scopeRadius,
    required this.scopeRingThickness,
    required this.activeChildRect,
    required this.childRects,
    required this.activeChildIndex,
    required this.isRack,
    required this.crossBarY,
    required this.poleX,
    required this.poleTop,
    required this.poleBottom,
  });

  /// Compute the layout for a given outer size + target / rack inputs.
  /// Soft-fails on weird inputs (zero or negative dimensions, empty
  /// rack list) by falling back to sensible defaults so the painter
  /// never blows up at runtime.
  factory _RealisticLayout.compute({
    required Size outerSize,
    required double targetWidthIn,
    required double targetHeightIn,
    required List<RackChildSpec>? rackChildren,
    required int? activeRackChildIndex,
  }) {
    final w = math.max(outerSize.width, 1.0);
    final h = math.max(outerSize.height, 1.0);
    // Scope ring fills ~88% of the smaller dimension and is centered.
    final shortSide = math.min(w, h);
    final scopeRadius = shortSide * 0.44;
    final scopeCenter = Offset(w / 2, h / 2);
    final scopeRingThickness = math.max(scopeRadius * 0.05, 4.0);

    // Treat as rack only if children list is non-empty.
    final isRack = rackChildren != null && rackChildren.isNotEmpty;

    // Single-target layout: target sits on a pole rising from the
    // dirt mound. The active rect occupies ~22% of canvas width so
    // the user has plenty of margin around the target inside the
    // scope ring.
    if (!isRack) {
      final tw = math.max(targetWidthIn, 1.0);
      final th = math.max(targetHeightIn, 1.0);
      final aspect = tw / th;
      // Scale the target by its real aspect ratio. We anchor on width
      // so a wide rectangle stays wide — keeps perceived "look" stable
      // across target shapes.
      final targetWidthPx = w * 0.22;
      final targetHeightPx = targetWidthPx / aspect;
      // Vertical position: target stands just above the horizon
      // (~50% canvas height) so it visually sits on the dirt mound.
      // Horizon y = 50% of canvas height (matches
      // ScopeDaytimeBackdropPainter). The target's bottom edge is
      // 12% of canvas height ABOVE the horizon — same offset the
      // backdrop's mound crest uses.
      final horizonY = h * 0.50;
      final crestY = horizonY - h * 0.12;
      final targetBottom = crestY + h * 0.005;
      final targetTop = targetBottom - targetHeightPx;
      final targetLeft = (w - targetWidthPx) / 2;
      final activeRect = Rect.fromLTWH(
        targetLeft,
        targetTop,
        targetWidthPx,
        targetHeightPx,
      );
      // Pole drops from the target bottom into the dirt mound.
      final poleX = w / 2;
      final poleTop = targetBottom;
      final poleBottom = horizonY + h * 0.05;
      return _RealisticLayout(
        outerSize: outerSize,
        scopeCenter: scopeCenter,
        scopeRadius: scopeRadius,
        scopeRingThickness: scopeRingThickness,
        activeChildRect: activeRect,
        childRects: const [],
        activeChildIndex: -1,
        isRack: false,
        crossBarY: 0,
        poleX: poleX,
        poleTop: poleTop,
        poleBottom: poleBottom,
      );
    }

    // Rack layout: each child is positioned by its
    // `offsetXFromCenterIn` under a horizontal cross-bar near the top
    // of the scene. Compute the per-child rectangles in inches first,
    // then scale the entire rack to fit ~70% of the canvas width.
    final children = rackChildren;
    double rackMinXIn = double.infinity;
    double rackMaxXIn = double.negativeInfinity;
    double rackMaxHeightIn = 0;
    for (final c in children) {
      final cw = math.max(c.widthIn, 0.1);
      final ch = math.max(c.heightIn, 0.1);
      rackMinXIn = math.min(rackMinXIn, c.offsetXFromCenterIn - cw / 2);
      rackMaxXIn = math.max(rackMaxXIn, c.offsetXFromCenterIn + cw / 2);
      rackMaxHeightIn = math.max(rackMaxHeightIn, ch);
    }
    final rackTotalWidthIn =
        math.max(rackMaxXIn - rackMinXIn, 0.1);
    // Inches-to-pixels scale: rack fills ~70% of canvas width OR the
    // target row's height fits inside ~28% of canvas height (whichever
    // is the more constraining).
    final pxPerInchByWidth = (w * 0.70) / rackTotalWidthIn;
    final pxPerInchByHeight = (h * 0.28) / math.max(rackMaxHeightIn, 0.1);
    final pxPerInch = math.min(pxPerInchByWidth, pxPerInchByHeight);

    final crossBarY = h * 0.20;
    final rackCenterX = w / 2;
    final rects = <Rect>[];
    for (final c in children) {
      final cw = math.max(c.widthIn, 0.1) * pxPerInch;
      final ch = math.max(c.heightIn, 0.1) * pxPerInch;
      // Each child hangs from a chain ~ a fixed pixel length below
      // the cross-bar. Top of the child is offset ~ 12% of canvas
      // height below the cross-bar so chains have visible length.
      final chainLengthPx = math.max(h * 0.06, 24.0);
      final childTop = crossBarY + chainLengthPx;
      final childCenterX =
          rackCenterX + c.offsetXFromCenterIn * pxPerInch;
      final childLeft = childCenterX - cw / 2;
      rects.add(Rect.fromLTWH(childLeft, childTop, cw, ch));
    }

    int activeIndex = (activeRackChildIndex ?? 0)
        .clamp(0, children.length - 1)
        .toInt();
    final activeRect = rects[activeIndex];

    return _RealisticLayout(
      outerSize: outerSize,
      scopeCenter: scopeCenter,
      scopeRadius: scopeRadius,
      scopeRingThickness: scopeRingThickness,
      activeChildRect: activeRect,
      childRects: rects,
      activeChildIndex: activeIndex,
      isRack: true,
      crossBarY: crossBarY,
      poleX: 0,
      poleTop: 0,
      poleBottom: 0,
    );
  }

  final Size outerSize;
  final Offset scopeCenter;
  final double scopeRadius;
  final double scopeRingThickness;

  /// Rectangle of the active target / rack child. Normalized
  /// (-1..1, -1..1) coordinates resolve against this rect.
  final Rect activeChildRect;

  /// Per-child rectangles in rack mode (empty for single).
  final List<Rect> childRects;
  final int activeChildIndex;
  final bool isRack;

  /// Y of the rack cross-bar (rack mode only).
  final double crossBarY;

  /// Pole geometry (single mode only).
  final double poleX;
  final double poleTop;
  final double poleBottom;
}

/// CustomPainter for realistic mode. Composes the daytime backdrop
/// (sky / grass / mound) with the pole or rack chains and the active
/// target geometry, then overlays the scope ring + precision reticle.
///
/// Layer order, back to front:
///   1. ScopeDaytimeBackdropPainter (full canvas, target = none).
///   2. Pole (single mode) OR cross-bar + chains (rack mode).
///   3. Target silhouettes — non-active rack children at 70% opacity,
///      then the active target at full opacity (slightly bolder).
///   4. Aim point + shot dots — drawn on the active target.
///   5. Scope ring + precision reticle, on top of everything inside
///      the ring.
class _RealisticTargetPainter extends CustomPainter {
  _RealisticTargetPainter({
    required this.target,
    required this.shots,
    required this.aimPointX,
    required this.aimPointY,
    required this.layout,
    required this.primary,
    required this.errorColor,
    required this.textColor,
  })  : _backdropPainter = ScopeDaytimeBackdropPainter(
          // We render the target ourselves on top of the backdrop so
          // the backdrop only paints the scenery layers.
          target: BackdropTargetSilhouette.none,
          targetWidthFraction: 0,
          targetColor: const Color(0xff5e6552),
        ),
        _polePaint = Paint()..color = const Color(0xff3a3a3a),
        _crossBarPaint = Paint()..color = const Color(0xff2c2c2c),
        _chainPaint = Paint()
          ..color = const Color(0xff4a4a4a)
          ..strokeWidth = 1.6
          ..style = PaintingStyle.stroke,
        _targetFillPaint = Paint()..color = const Color(0xfff2efe6),
        _targetOutlinePaint = Paint()
          ..color = const Color(0xff1a1a1a)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.6,
        _scopeRingPaint = Paint()
          ..color = const Color(0xff0a0a0a)
          ..style = PaintingStyle.stroke,
        _scopeInnerHighlightPaint = Paint()
          ..color = Colors.white.withValues(alpha: 0.18)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.0,
        _reticleLinePaint = Paint()
          ..color = const Color(0xff0a0a0a)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.0,
        _reticleCenterPaint = Paint()..color = const Color(0xffd9352d);

  final TargetSpec target;
  final List<ShotImpactRow> shots;
  final double? aimPointX;
  final double? aimPointY;
  final _RealisticLayout layout;
  final Color primary;
  final Color errorColor;
  final Color textColor;

  // Cached painters / paint objects so paint() never allocates on the
  // hot path. ScopeDaytimeBackdropPainter is instantiated once per
  // RealisticTargetPainter instance and reused for every paint pass.
  final ScopeDaytimeBackdropPainter _backdropPainter;
  final Paint _polePaint;
  final Paint _crossBarPaint;
  final Paint _chainPaint;
  final Paint _targetFillPaint;
  final Paint _targetOutlinePaint;
  final Paint _scopeRingPaint;
  final Paint _scopeInnerHighlightPaint;
  final Paint _reticleLinePaint;
  final Paint _reticleCenterPaint;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.width <= 0 || size.height <= 0) return;

    // 1. Daytime backdrop — sky + grass + mound silhouette + haze.
    _backdropPainter.paint(canvas, size);

    // 2. Pole or cross-bar + chains.
    if (!layout.isRack) {
      _paintPole(canvas);
    } else {
      _paintCrossBarAndChains(canvas, size);
    }

    // 3. Target silhouettes. Non-active rack children render at 70%
    //    opacity; the active child / single target renders at full.
    if (layout.isRack) {
      // Walk children in order so the painter's overdraw is
      // deterministic. Non-active children first (so the active child
      // sits on top if rectangles overlap, which shouldn't happen but
      // we don't want to depend on it).
      // Note: we don't have RackChildSpec here — only the rectangles.
      // The active rect is at layout.activeChildIndex.
      for (var i = 0; i < layout.childRects.length; i++) {
        if (i == layout.activeChildIndex) continue;
        _paintTargetSilhouette(
          canvas,
          layout.childRects[i],
          isActive: false,
          shape: target.shape,
        );
      }
      _paintTargetSilhouette(
        canvas,
        layout.activeChildRect,
        isActive: true,
        shape: target.shape,
      );
    } else {
      _paintTargetSilhouette(
        canvas,
        layout.activeChildRect,
        isActive: true,
        shape: target.shape,
      );
    }

    // 4. Aim point + shot dots — anchored on the active target rect.
    _paintAimAndShots(canvas);

    // 5. Scope ring + precision reticle. The reticle draws inside the
    //    ring; the area outside the ring still shows the backdrop.
    _paintScopeRingAndReticle(canvas);
  }

  void _paintPole(Canvas canvas) {
    // Single-target pole: 5px wide dark grey rectangle from the bottom
    // of the target down into the dirt mound.
    const poleHalfWidth = 2.5;
    final rect = Rect.fromLTWH(
      layout.poleX - poleHalfWidth,
      layout.poleTop,
      poleHalfWidth * 2,
      layout.poleBottom - layout.poleTop,
    );
    canvas.drawRect(rect, _polePaint);
  }

  void _paintCrossBarAndChains(Canvas canvas, Size size) {
    // Horizontal cross-bar across the rack's width — slightly wider
    // than the rack itself so chains visibly hang from a beam, not
    // float in space.
    if (layout.childRects.isEmpty) return;
    double leftMost = double.infinity;
    double rightMost = double.negativeInfinity;
    for (final r in layout.childRects) {
      leftMost = math.min(leftMost, r.left);
      rightMost = math.max(rightMost, r.right);
    }
    // Pad the bar by 4% of the canvas width on each end.
    final pad = size.width * 0.04;
    final barRect = Rect.fromLTRB(
      leftMost - pad,
      layout.crossBarY - 3,
      rightMost + pad,
      layout.crossBarY + 3,
    );
    canvas.drawRect(barRect, _crossBarPaint);
    // Two small dark squares at the bar ends to read as anchor caps.
    final capSide = 6.0;
    canvas.drawRect(
      Rect.fromLTWH(barRect.left - 2, layout.crossBarY - capSide / 2,
          capSide, capSide),
      _crossBarPaint,
    );
    canvas.drawRect(
      Rect.fromLTWH(barRect.right - capSide + 2,
          layout.crossBarY - capSide / 2, capSide, capSide),
      _crossBarPaint,
    );

    // Dashed chain from the bar down to the top of each child. The
    // dash pattern is hand-rolled (no path_drawing dep) so we keep
    // allocations off the hot path: stride math + a short loop with
    // a single Paint object reused per segment.
    for (final r in layout.childRects) {
      final chainTopY = layout.crossBarY + 3;
      final chainBottomY = r.top;
      if (chainBottomY <= chainTopY) continue;
      final chainX = r.center.dx;
      const dashLen = 4.0;
      const gapLen = 3.0;
      double y = chainTopY;
      while (y < chainBottomY) {
        final segEnd = math.min(y + dashLen, chainBottomY);
        canvas.drawLine(
          Offset(chainX, y),
          Offset(chainX, segEnd),
          _chainPaint,
        );
        y = segEnd + gapLen;
      }
    }
  }

  void _paintTargetSilhouette(
    Canvas canvas,
    Rect rect, {
    required bool isActive,
    required String shape,
  }) {
    // Mutate the cached paint objects' alpha + stroke width per call
    // instead of allocating new paints. Active child = full opacity +
    // 1.6px outline. Inactive = 70% opacity + 1.2px outline.
    final fillAlpha = isActive ? 1.0 : 0.70;
    final outlineWidth = isActive ? 1.6 : 1.2;
    _targetFillPaint.color = Color.fromRGBO(0xf2, 0xef, 0xe6,
        fillAlpha);
    _targetOutlinePaint.color = Color.fromRGBO(
        0x1a, 0x1a, 0x1a, isActive ? 1.0 : 0.70);
    _targetOutlinePaint.strokeWidth = outlineWidth;

    switch (shape) {
      case 'circle':
        final r = rect.shortestSide / 2;
        canvas.drawCircle(rect.center, r, _targetFillPaint);
        canvas.drawCircle(rect.center, r, _targetOutlinePaint);
        break;
      case 'silhouette':
        _paintIpscSilhouette(canvas, rect);
        break;
      case 'square':
      case 'rectangle':
      default:
        canvas.drawRect(rect, _targetFillPaint);
        canvas.drawRect(rect, _targetOutlinePaint);
        break;
    }
  }

  void _paintIpscSilhouette(Canvas canvas, Rect rect) {
    // Cardboard-style upper torso: rounded body + rounded head. Same
    // shapes as ScopeDaytimeBackdropPainter._paintTarget for
    // visual consistency.
    final cx = rect.center.dx;
    final widthPx = rect.width;
    final heightPx = rect.height;
    final centerY = rect.center.dy;
    final bodyRect = Rect.fromCenter(
      center: Offset(cx, centerY + heightPx * 0.10),
      width: widthPx,
      height: heightPx * 0.70,
    );
    final headRect = Rect.fromCenter(
      center: Offset(cx, centerY - heightPx * 0.40),
      width: widthPx * 0.55,
      height: heightPx * 0.32,
    );
    final body = RRect.fromRectAndRadius(
      bodyRect,
      Radius.circular(widthPx * 0.10),
    );
    final head = RRect.fromRectAndRadius(
      headRect,
      Radius.circular(widthPx * 0.18),
    );
    canvas.drawRRect(body, _targetFillPaint);
    canvas.drawRRect(head, _targetFillPaint);
    canvas.drawRRect(body, _targetOutlinePaint);
    canvas.drawRRect(head, _targetOutlinePaint);
  }

  void _paintAimAndShots(Canvas canvas) {
    final rect = layout.activeChildRect;

    // Aim marker (small crosshair). Drawn on the active target only,
    // under the shot dots so the dots stay visible.
    if (aimPointX != null && aimPointY != null) {
      final aimPx =
          _normalizedToOffsetIn(aimPointX!, aimPointY!, rect);
      // Use a separate cached paint via in-place mutation of the
      // reticle line paint — same stroke width is fine, but we pick
      // a different color to read on the off-white target.
      final aimPaint = Paint()
        ..color = primary.withValues(alpha: 0.85)
        ..strokeWidth = 1.4
        ..style = PaintingStyle.stroke;
      const armPx = 12.0;
      canvas.drawLine(
        Offset(aimPx.dx - armPx, aimPx.dy),
        Offset(aimPx.dx + armPx, aimPx.dy),
        aimPaint,
      );
      canvas.drawLine(
        Offset(aimPx.dx, aimPx.dy - armPx),
        Offset(aimPx.dx, aimPx.dy + armPx),
        aimPaint,
      );
      canvas.drawCircle(
        aimPx,
        3.0,
        Paint()..color = primary.withValues(alpha: 0.85),
      );
    }

    // Shot dots, drawn on the active target. Latest shot uses the
    // theme error color; older shots are a faded primary.
    for (var i = 0; i < shots.length; i++) {
      final shot = shots[i];
      final isLatest = i == shots.length - 1;
      final dotColor = isLatest
          ? errorColor
          : primary.withValues(alpha: 0.85);
      final centre =
          _normalizedToOffsetIn(shot.impactX, shot.impactY, rect);
      final dotRadius = isLatest ? 7.0 : 5.0;
      canvas.drawCircle(
        centre,
        dotRadius + 1.5,
        Paint()..color = textColor.withValues(alpha: 0.6),
      );
      canvas.drawCircle(centre, dotRadius, Paint()..color = dotColor);
    }
  }

  void _paintScopeRingAndReticle(Canvas canvas) {
    // Save & clip to the scope circle so the reticle (and any
    // overflow elements) stay inside the eyepiece.
    final r = layout.scopeRadius;
    final c = layout.scopeCenter;
    final ringThickness = layout.scopeRingThickness;

    // Save the canvas state so we can clip to the scope circle for
    // the reticle pass and then restore for the ring pass. Cheaper
    // than re-clipping per element and there's no overdraw past the
    // ring edge.
    canvas.save();
    final clipPath = Path()
      ..addOval(Rect.fromCircle(center: c, radius: r - ringThickness / 2));
    canvas.clipPath(clipPath);
    _paintReticle(canvas);
    canvas.restore();

    // Black scope ring (the eye-box).
    _scopeRingPaint.strokeWidth = ringThickness;
    _scopeRingPaint.color = const Color(0xff0a0a0a);
    canvas.drawCircle(c, r - ringThickness / 2, _scopeRingPaint);

    // Inner highlight: a 1px ring just inside the black ring so the
    // scope reads as machined glass, not a flat shape. Subtle.
    canvas.drawCircle(
      c,
      r - ringThickness - 0.5,
      _scopeInnerHighlightPaint,
    );
  }

  /// Built-in precision-mil reticle that matches the reference image:
  /// thin crosshair, hash marks at every 1 mil, numbered every 2 mil
  /// (2 / 4 / 6 / 8 / 10), filled red center dot. Drawn entirely
  /// inside the scope clip.
  void _paintReticle(Canvas canvas) {
    final c = layout.scopeCenter;
    final r = layout.scopeRadius - layout.scopeRingThickness;
    // 10 mil to each side at the visible reticle's half-extent fills
    // ~ 90% of the scope radius (the rest leaves headroom inside the
    // ring for hashes near the edge).
    final pxPerMil = (r * 0.90) / 10.0;

    _reticleLinePaint.color = const Color(0xff0a0a0a);
    _reticleLinePaint.strokeWidth = 1.0;

    // Main horizontal + vertical crosshair. Stop short of center by
    // ~0.4 mil so the center dot stands clean.
    final halfExtentPx = pxPerMil * 10.0;
    canvas.drawLine(
      Offset(c.dx - halfExtentPx, c.dy),
      Offset(c.dx - pxPerMil * 0.3, c.dy),
      _reticleLinePaint,
    );
    canvas.drawLine(
      Offset(c.dx + pxPerMil * 0.3, c.dy),
      Offset(c.dx + halfExtentPx, c.dy),
      _reticleLinePaint,
    );
    canvas.drawLine(
      Offset(c.dx, c.dy - halfExtentPx),
      Offset(c.dx, c.dy - pxPerMil * 0.3),
      _reticleLinePaint,
    );
    canvas.drawLine(
      Offset(c.dx, c.dy + pxPerMil * 0.3),
      Offset(c.dx, c.dy + halfExtentPx),
      _reticleLinePaint,
    );

    // Hash marks at every 1 mil, 0.4 mil long. Major hashes (every
    // 2 mil) are slightly longer + numbered.
    for (var n = 1; n <= 10; n++) {
      final isMajor = n % 2 == 0;
      final hashHalfLen = isMajor ? pxPerMil * 0.32 : pxPerMil * 0.18;
      // Horizontal axis: hashes draw vertically (perpendicular to the
      // horizontal crosshair). Both sides.
      for (final sign in const [-1, 1]) {
        final hx = c.dx + sign * pxPerMil * n;
        canvas.drawLine(
          Offset(hx, c.dy - hashHalfLen),
          Offset(hx, c.dy + hashHalfLen),
          _reticleLinePaint,
        );
      }
      // Vertical axis: hashes draw horizontally. Both sides.
      for (final sign in const [-1, 1]) {
        final hy = c.dy + sign * pxPerMil * n;
        canvas.drawLine(
          Offset(c.dx - hashHalfLen, hy),
          Offset(c.dx + hashHalfLen, hy),
          _reticleLinePaint,
        );
      }
    }

    // Numbered labels at every 2 mil. 10pt-equivalent => ~10px font
    // size on a phone-scale canvas. Positioned just below the
    // horizontal hashes and to the right of the vertical hashes so
    // they don't overlap the crosshair.
    for (var n = 2; n <= 10; n += 2) {
      _drawReticleLabel(canvas,
          Offset(c.dx + pxPerMil * n, c.dy + pxPerMil * 0.6), '$n');
      _drawReticleLabel(canvas,
          Offset(c.dx - pxPerMil * n, c.dy + pxPerMil * 0.6), '$n');
      _drawReticleLabel(canvas,
          Offset(c.dx + pxPerMil * 0.6, c.dy - pxPerMil * n), '$n');
      _drawReticleLabel(canvas,
          Offset(c.dx + pxPerMil * 0.6, c.dy + pxPerMil * n), '$n');
    }

    // Center dot — small filled red circle. The reference image uses
    // a punchy red dot at the geometric center; we keep it small
    // (~1.2 px radius @ 10 mil scope) so it doesn't obscure the aim
    // point on small targets.
    final dotR = math.max(pxPerMil * 0.08, 1.2);
    canvas.drawCircle(c, dotR, _reticleCenterPaint);
  }

  /// Tiny TextPainter for reticle labels. Allocates a fresh
  /// `TextPainter` per label which is fine — the call count is fixed
  /// (16 labels) and TextPainter caching across paints would require
  /// invalidation logic that's not worth the complexity.
  void _drawReticleLabel(Canvas canvas, Offset at, String text) {
    final tp = TextPainter(
      text: TextSpan(
        text: text,
        style: const TextStyle(
          color: Color(0xff0a0a0a),
          fontSize: 9.0,
          fontWeight: FontWeight.w500,
        ),
      ),
      textDirection: TextDirection.ltr,
    );
    tp.layout();
    tp.paint(canvas, at - Offset(tp.width / 2, tp.height / 2));
  }

  /// Convert normalized (-1..1, -1..1) to widget-local pixel
  /// coordinates inside [rect], flipping Y back to screen convention
  /// (top = small y).
  Offset _normalizedToOffsetIn(double nx, double ny, Rect rect) {
    final cx = rect.center.dx;
    final cy = rect.center.dy;
    final halfW = rect.width / 2;
    final halfH = rect.height / 2;
    return Offset(cx + nx * halfW, cy - ny * halfH);
  }

  @override
  bool shouldRepaint(covariant _RealisticTargetPainter old) {
    if (old.target.shape != target.shape) return true;
    if (old.target.widthIn != target.widthIn) return true;
    if (old.target.heightIn != target.heightIn) return true;
    if (old.aimPointX != aimPointX || old.aimPointY != aimPointY) {
      return true;
    }
    if (old.layout.activeChildRect != layout.activeChildRect) return true;
    if (old.layout.isRack != layout.isRack) return true;
    if (old.layout.activeChildIndex != layout.activeChildIndex) return true;
    if (old.layout.childRects.length != layout.childRects.length) return true;
    for (var i = 0; i < layout.childRects.length; i++) {
      if (old.layout.childRects[i] != layout.childRects[i]) return true;
    }
    if (old.shots.length != shots.length) return true;
    for (var i = 0; i < shots.length; i++) {
      final a = shots[i];
      final b = old.shots[i];
      if (a.id != b.id ||
          a.impactX != b.impactX ||
          a.impactY != b.impactY ||
          a.shotNumber != b.shotNumber) {
        return true;
      }
    }
    return false;
  }
}

/// Original target-focused painter. Draws the target shape and overlays
/// shot dots on a flat themed background. Unchanged from the previous
/// implementation — the realistic-mode painter is a separate class so
/// the simple path stays simple.
class _TargetPainter extends CustomPainter {
  _TargetPainter({
    required this.target,
    required this.shots,
    required this.targetRect,
    required this.outlineColor,
    required this.primary,
    required this.errorColor,
    required this.textColor,
    required this.backgroundColor,
    this.aimPointX,
    this.aimPointY,
  });

  final TargetSpec target;
  final List<ShotImpactRow> shots;
  /// Pixel rectangle the target itself occupies. Normalized coordinates
  /// (-1..1, -1..1) are anchored to this rectangle in both view modes.
  final Rect targetRect;
  final Color outlineColor;
  final Color primary;
  final Color errorColor;
  final Color textColor;
  final Color backgroundColor;
  final double? aimPointX;
  final double? aimPointY;

  @override
  void paint(Canvas canvas, Size size) {
    // Background plate so the target stands out against any theme.
    // Always covers the FULL outer box (including the realistic-mode
    // gutter) so there's no flicker between modes.
    canvas.drawRect(
      Offset.zero & size,
      Paint()..color = backgroundColor,
    );

    final fill = Paint()..color = _parseColor(target.colorHex);
    final outline = Paint()
      ..color = outlineColor
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5;

    // Draw the target shape, centered, occupying ~92% of the *target*
    // rectangle so we leave a small margin for the shot dots that fall
    // near the edge. The 4% inset is taken in target-rect units, not
    // outer-box units, so realistic-mode renderings keep the same look
    // around the target itself.
    const inset = 0.04;
    final rect = Rect.fromLTWH(
      targetRect.left + targetRect.width * inset,
      targetRect.top + targetRect.height * inset,
      targetRect.width * (1 - 2 * inset),
      targetRect.height * (1 - 2 * inset),
    );
    switch (target.shape) {
      case 'circle':
        final centre = rect.center;
        final radius = rect.shortestSide / 2;
        canvas.drawCircle(centre, radius, fill);
        canvas.drawCircle(centre, radius, outline);
        // Cross-hairs at 0/0 to give the eye a center reference.
        _drawCenterCross(canvas, rect, outlineColor.withValues(alpha: 0.4));
        break;
      case 'square':
      case 'rectangle':
        canvas.drawRect(rect, fill);
        canvas.drawRect(rect, outline);
        _drawCenterCross(canvas, rect, outlineColor.withValues(alpha: 0.4));
        break;
      case 'silhouette':
        _drawSilhouette(canvas, rect, fill, outline);
        _drawCenterCross(canvas, rect, outlineColor.withValues(alpha: 0.3));
        break;
      default:
        // 'irregular' — render an outlined rectangle with hashed corners
        // so it's visibly different from a rectangle target.
        canvas.drawRect(rect, fill);
        canvas.drawRect(rect, outline);
        break;
    }

    // Aim marker (small crosshair) — drawn under the shot dots so the
    // dots stay visible. Skipped when no aim point is set.
    if (aimPointX != null && aimPointY != null) {
      final aimPx =
          _normalizedToOffsetIn(aimPointX!, aimPointY!, targetRect);
      final aimPaint = Paint()
        ..color = primary.withValues(alpha: 0.85)
        ..strokeWidth = 1.4
        ..style = PaintingStyle.stroke;
      const armPx = 12.0;
      canvas.drawLine(
        Offset(aimPx.dx - armPx, aimPx.dy),
        Offset(aimPx.dx + armPx, aimPx.dy),
        aimPaint,
      );
      canvas.drawLine(
        Offset(aimPx.dx, aimPx.dy - armPx),
        Offset(aimPx.dx, aimPx.dy + armPx),
        aimPaint,
      );
      canvas.drawCircle(
        aimPx,
        3.0,
        Paint()..color = primary.withValues(alpha: 0.85),
      );
    }

    // Draw shot dots. Latest shot gets the primary color; older shots
    // are drawn in a faded primary tint so the eye finds the most recent.
    for (var i = 0; i < shots.length; i++) {
      final shot = shots[i];
      final isLatest = i == shots.length - 1;
      final dotColor = isLatest
          ? errorColor
          : primary.withValues(alpha: 0.85);
      final centre =
          _normalizedToOffsetIn(shot.impactX, shot.impactY, targetRect);
      final dotRadius = isLatest ? 7.0 : 5.0;
      // Outer ring for contrast.
      canvas.drawCircle(
        centre,
        dotRadius + 1.5,
        Paint()..color = textColor.withValues(alpha: 0.6),
      );
      canvas.drawCircle(centre, dotRadius, Paint()..color = dotColor);
      // Shot number label, positioned slightly above-right of the dot.
      _drawShotLabel(canvas, '${shot.shotNumber}',
          centre + Offset(dotRadius + 2, -dotRadius - 2));
    }
  }

  /// Convert normalized (-1..1, -1..1) to widget-local pixel coordinates
  /// inside [rect], flipping Y back to the screen convention
  /// (top = small y).
  Offset _normalizedToOffsetIn(double nx, double ny, Rect rect) {
    final cx = rect.center.dx;
    final cy = rect.center.dy;
    final halfW = rect.width / 2;
    final halfH = rect.height / 2;
    return Offset(cx + nx * halfW, cy - ny * halfH);
  }

  void _drawShotLabel(Canvas canvas, String text, Offset at) {
    final tp = TextPainter(
      text: TextSpan(
        text: text,
        style: TextStyle(
          color: textColor,
          fontSize: 11,
          fontWeight: FontWeight.w600,
          shadows: [
            Shadow(
              color: backgroundColor.withValues(alpha: 0.8),
              offset: const Offset(0, 0),
              blurRadius: 2,
            ),
          ],
        ),
      ),
      textDirection: TextDirection.ltr,
    );
    tp.layout();
    tp.paint(canvas, at);
  }

  void _drawCenterCross(Canvas canvas, Rect rect, Color color) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = 0.8;
    final cx = rect.center.dx;
    final cy = rect.center.dy;
    final armX = rect.width * 0.04;
    final armY = rect.height * 0.04;
    canvas.drawLine(Offset(cx - armX, cy), Offset(cx + armX, cy), paint);
    canvas.drawLine(Offset(cx, cy - armY), Offset(cx, cy + armY), paint);
  }

  /// Tall, narrow, vaguely-humanoid shape for `silhouette` targets.
  /// Approximated as a rounded torso rectangle plus a small head circle.
  /// Doesn't try to be anatomically accurate — just enough to read as a
  /// silhouette.
  void _drawSilhouette(Canvas canvas, Rect rect, Paint fill, Paint outline) {
    final cx = rect.center.dx;
    final headR = rect.width * 0.18;
    final headCenter = Offset(cx, rect.top + headR + rect.height * 0.04);
    // Torso: rounded rect that fills most of the lower 80% of the box.
    final torsoTop = headCenter.dy + headR * 0.8;
    final torsoRect = Rect.fromLTRB(
      rect.left + rect.width * 0.12,
      torsoTop,
      rect.right - rect.width * 0.12,
      rect.bottom,
    );
    final rrect =
        RRect.fromRectAndRadius(torsoRect, Radius.circular(rect.width * 0.08));
    canvas.drawRRect(rrect, fill);
    canvas.drawRRect(rrect, outline);
    canvas.drawCircle(headCenter, headR, fill);
    canvas.drawCircle(headCenter, headR, outline);
  }

  Color _parseColor(String hex) {
    final s = hex.startsWith('#') ? hex.substring(1) : hex;
    if (s.length == 6) {
      final v = int.tryParse(s, radix: 16) ?? 0xffffff;
      return Color(0xff000000 | v);
    }
    if (s.length == 8) {
      final v = int.tryParse(s, radix: 16) ?? 0xffffffff;
      return Color(v);
    }
    return Colors.white;
  }

  @override
  bool shouldRepaint(covariant _TargetPainter old) {
    if (old.target.shape != target.shape) return true;
    if (old.target.widthIn != target.widthIn) return true;
    if (old.target.heightIn != target.heightIn) return true;
    if (old.target.colorHex != target.colorHex) return true;
    if (old.targetRect != targetRect) return true;
    if (old.aimPointX != aimPointX || old.aimPointY != aimPointY) {
      return true;
    }
    if (old.shots.length != shots.length) return true;
    for (var i = 0; i < shots.length; i++) {
      final a = shots[i];
      final b = old.shots[i];
      if (a.id != b.id ||
          a.impactX != b.impactX ||
          a.impactY != b.impactY ||
          a.shotNumber != b.shotNumber) {
        return true;
      }
    }
    return false;
  }
}
