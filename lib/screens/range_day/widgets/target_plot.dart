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
//   * Rack target ([rackChildren] non-null) — ground furniture varies
//     by the active rack's [rackMountStyle] (§6A.3 of the v2.3
//     brief):
//       - `hanging_rail`     : horizontal cross-bar across the top
//                              of the rack, each child hangs from a
//                              short dashed chain (legacy v2.3
//                              behaviour, also the fallback for
//                              unknown / null mount style).
//       - `standing_stakes`  : one thin wood-brown stake under each
//                              child, running from the child's
//                              bottom into the foreground mound.
//       - `popper_base`      : concrete-grey trapezoidal base under
//                              each child sitting on the grass line.
//                              Shared mound suppressed (the per-
//                              child bases ARE the ground furniture).
//       - `individual_posts` : per-child wooden post + small earth-
//                              berm oval. Shared mound suppressed.
//     The active child (by [activeRackChildIndex]) is rendered at
//     full opacity with a thicker outline ([kRackActiveStrokeWidth])
//     and gets the aim-point + shot-dots overlay; the others render
//     at 70% opacity with [kRackInactiveStrokeWidth].
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
import '../../../models/target_center_point.dart';
import '../../../widgets/animal_silhouettes.dart';
import '../../../widgets/reticle_renderer.dart';
import '../../../widgets/scope_daytime_backdrop.dart';
import '../../../widgets/target_silhouettes.dart';

/// Shape dispatch for any painter rendering a [TargetSpec].
///
/// Returns the scaled SVG path when [shapeId] resolves to an authored
/// silhouette in either [AnimalSilhouettes] or [TargetSilhouettes].
/// Returns `null` when [shapeId] is null, unknown, or the path cache
/// is cold — callers fall back to their own procedural rendering in
/// that case (circle / silhouette / star / rectangle / square /
/// generic IPSC).
///
/// Synchronous; safe to call from `CustomPainter.paint`. The path
/// caches consulted here are populated at app boot via the fire-and-
/// forget preload in `main.dart` (Appendix H.4 / M of the Range Day
/// Realistic v2.3 rewrite). A cold-cache null return is transient —
/// the next repaint after preload completes will return the real path.
///
/// Single source of truth for SVG dispatch across the realistic scene
/// painter ([_RealisticScenePainter]) and the picker thumbnail painter
/// (`_TargetThumbnailPainter` in `range_day_detail_screen.dart`). If a
/// new SVG silhouette class ships, add its check here and both
/// painters pick it up.
///
/// [scaleFactor] (v38+) multiplies the natural fit-to-box scale.
/// Forwarded to whichever silhouette helper handles the shapeId.
/// Default 1.0 (callers without per-target tuning get unchanged
/// rendering).
Path? resolveTargetSvgPath(
  Rect bounds,
  String? shapeId, {
  double scaleFactor = 1.0,
}) {
  if (shapeId == null) return null;
  if (AnimalSilhouettes.isAnimalShape(shapeId)) {
    return AnimalSilhouettes.cachedScaledPath(
      bounds,
      shapeId,
      scaleFactor: scaleFactor,
    );
  }
  if (TargetSilhouettes.isTargetShape(shapeId)) {
    return TargetSilhouettes.cachedScaledPath(
      bounds,
      shapeId,
      scaleFactor: scaleFactor,
    );
  }
  return null;
}

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
    this.shapeId,
    required this.widthIn,
    required this.heightIn,
    required this.colorHex,
    this.centerPoint = TargetCenterPoint.defaultCenter,
    this.svgScaleFactor = 1.0,
  });

  /// 'circle' | 'square' | 'rectangle' | 'silhouette' | 'irregular'
  final String shape;

  /// Optional discriminator that routes to a user-authored SVG path
  /// (animal silhouettes, popper). Null for procedural shapes
  /// (circle, square, rectangle, IPSC silhouette, Texas Star, generic
  /// `silhouette`). When non-null, painters look up
  /// `AnimalSilhouettes` / `TargetSilhouettes` by this key.
  final String? shapeId;

  final double widthIn;
  final double heightIn;
  final String colorHex;

  /// Per-target geometric center (v37+). Defaults to 0.5/0.5 — same
  /// anchor as `targetRect.center` in Phase 5 painter math.
  final TargetCenterPoint centerPoint;

  /// Per-target SVG scale-factor multiplier (v38+). The realistic
  /// scene painter multiplies the natural fit-to-box scale by this
  /// value. Defaults to 1.0 (no change). Catalog rows with antlers
  /// / horns that get clipped at the bigger target box use values
  /// like 1.2-1.4 so the silhouette overflows the rect into the
  /// sky region (bottom-alignment is preserved by the silhouette
  /// scaler).
  final double svgScaleFactor;

  /// Default target used when the user hasn't picked one yet — an
  /// 18 in × 30 in white silhouette. This matches the canonical IPSC
  /// (USPSA Metric) competition cardboard target so a fresh user
  /// opening Range Day sees a recognizable, distance-relevant target.
  /// They can swap to any other catalog target via the picker.
  ///
  /// Color is pure white (`#ffffff`); the 18 × 30 inch dimensions
  /// match the silhouette body envelope used by USPSA / IPSC. The
  /// `silhouette` shape value flows through to the painter chain so
  /// the target draws a torso + head outline rather than a flat
  /// rectangle.
  factory TargetSpec.defaultPaper() => const TargetSpec(
        shape: 'silhouette',
        widthIn: 18,
        heightIn: 30,
        colorHex: '#ffffff',
      );

  factory TargetSpec.fromRow(TargetRow row) => TargetSpec(
        shape: row.shape,
        shapeId: row.shapeId,
        widthIn: row.widthIn,
        heightIn: row.heightIn,
        colorHex: row.colorHex,
        centerPoint: TargetCenterPoint(
          verticalFromTop: row.verticalCenterPctFromTop,
          horizontalFromLeft: row.horizontalCenterPctFromLeft,
        ),
        svgScaleFactor: row.svgScaleFactor,
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

/// Top-level outline-stroke width for the ACTIVE rack child / single-
/// target silhouette in realistic mode. Exposed at top level so the
/// `test/rack_rendering_test.dart` regression can assert the ≥1.5×
/// ratio against [kRackInactiveStrokeWidth] without breaking when the
/// painter internals are refactored. Per
/// `range_day_realistic_rewrite_v23.md` §6A.3 line 1244: the active
/// plate renders with a "50% thicker stroke (e.g., 2.5px instead of
/// 1.5px)."
const double kRackActiveStrokeWidth = 2.5;

/// Companion to [kRackActiveStrokeWidth]: outline-stroke width for
/// NON-active rack children. Same rationale as the active constant.
const double kRackInactiveStrokeWidth = 1.5;

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
    this.rackMountStyle,
    this.colorHexOverride,
    this.rangeYards,
    this.lowLightMode = false,
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

  /// Mount-style discriminator for the active rack. Drives which
  /// ground-furniture helper the realistic painter dispatches to when
  /// [rackChildren] is non-null. Recognised values (matching the
  /// v2.3 §6A.3 taxonomy stored on the `TargetRacks.rackKind` drift
  /// column):
  ///
  ///   * `hanging_rail`     — horizontal cross-bar + chains per child
  ///                          (default; also the fallback for unknown
  ///                          values).
  ///   * `standing_stakes`  — one thin wood stake per child rising
  ///                          from the child's bottom into the
  ///                          foreground mound region.
  ///   * `popper_base`      — concrete trapezoidal base under each
  ///                          child sitting on the grass line; the
  ///                          shared mound is suppressed.
  ///   * `individual_posts` — one wooden post + small individual
  ///                          earth-berm oval per child; the shared
  ///                          mound is suppressed.
  ///
  /// `rotating_hub` is deferred to v2.4 per Phase 2 errata; the
  /// painter falls through to `hanging_rail` so the value renders
  /// reasonably. `null` ignores mount-style dispatch entirely (used
  /// by single-target rendering, where `rackChildren` is also null).
  final String? rackMountStyle;

  /// User color override for the active target's tint. Hex string
  /// like `'#cc1f1f'`. When non-null, the target painters substitute
  /// this value for `target.colorHex` (single-target mode) or for
  /// the active rack child's color (rack mode). Inactive rack
  /// children retain their natural cream color so an override
  /// doesn't bleed across the whole rack. Null = use natural color.
  final String? colorHexOverride;

  /// Distance to the target in yards. Used by the realistic-mode
  /// painter to scale the target to its true angular size — a 30"
  /// target at 500 yards subtends only ~1.67 mil and should appear
  /// dwarfed by a 14-mil reticle tree, not larger than it. When
  /// null the painter falls back to the legacy fixed-fraction
  /// scaling (kept so callers without distance context — e.g.
  /// component previews in onboarding — still render).
  final double? rangeYards;

  /// When `true`, the realistic painter switches to the §6A.2 dusk
  /// palette (dark blue sky gradient, darkened green grass, darkened
  /// brown mound) and the target-focused mode's overlaid
  /// [ReticleRenderer] renders illuminated elements in their
  /// authored color. Toggled by the Range Day Realistic "Low Light"
  /// AppBar control on the parent screen. Defaults to `false` so
  /// every other caller (onboarding previews, picker preview)
  /// behaves identically to before.
  final bool lowLightMode;

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
    // Realistic mode locks to 4:3 landscape regardless of target
    // aspect — the scene composition (sky 70%, grass 30%, pole +
    // mound under target) is laid out from the frame, not from the
    // target's own dimensions. Target-focused mode still matches
    // the target's aspect so the silhouette fills the box for
    // accurate dot placement.
    final outerRatio = viewMode == TargetPlotViewMode.realistic
        ? 4 / 3
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
          final layout = RealisticLayout.compute(
            outerSize: outerSize,
            targetWidthIn: target.widthIn,
            targetHeightIn: target.heightIn,
            rackChildren: rackChildren,
            activeRackChildIndex: activeRackChildIndex,
            rackMountStyle: rackMountStyle,
            rangeYards: rangeYards,
            reticle: reticle,
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
                      // Rack targets keep the legacy painter (cross-bar,
                      // chains, stakes, popper bases, individual posts —
                      // all the rack-mount-style dispatch lives there).
                      // Single targets use the new scene painter that
                      // composes sky → grass → mound → pole → target
                      // cleanly. Reticle / aim / shots are deferred to
                      // subsequent phases for the single-target path;
                      // the legacy painter still renders them for racks
                      // until the rack rewrite lands.
                      painter: layout.isRack
                          ? _RealisticTargetPainter(
                              target: target,
                              shots: shots,
                              aimPointX: ax,
                              aimPointY: ay,
                              layout: layout,
                              primary: theme.colorScheme.primary,
                              errorColor: theme.colorScheme.error,
                              textColor: theme.colorScheme.onSurface,
                              colorHexOverride: colorHexOverride,
                              lowLightMode: lowLightMode,
                              rackMountStyle: rackMountStyle,
                            )
                          : _RealisticScenePainter(
                              target: target,
                              colorHexOverride: colorHexOverride,
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
                        colorHexOverride: colorHexOverride,
                      ),
                    ),
                  // Reticle overlay anchored to the aim marker. Only
                  // drawn in target-focused mode — the realistic
                  // painter draws its own precision reticle inside the
                  // scope ring to match the reference exactly. When no
                  // aim point is set, the overlay sits at the geometric
                  // center of the target rectangle (NOT the outer box).
                  // [lowLightMode] is plumbed through so a Range Day
                  // user who flips the Low Light AppBar toggle while
                  // looking at the target-focused view still sees
                  // illuminated reticle elements in their authored
                  // color.
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
                        lowLightMode: lowLightMode,
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
class RealisticLayout {
  const RealisticLayout({
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
  ///
  /// `rangeYards` and `reticle` together drive the realistic
  /// mil-based target sizing. When BOTH are present, the target is
  /// scaled to its true angular size (small-angle approximation
  /// `mil = inches / (yd × 36) × 1000`) and rendered relative to the
  /// reticle's own field-of-view, so a 30" IPSC at 500yd looks
  /// dwarfed next to the reticle's 14-mil tree just like through a
  /// real scope. When either is null, the painter falls back to the
  /// legacy fixed-fraction scaling (22% of canvas width) — keeps
  /// onboarding-deck previews working without distance context.
  ///
  /// `rackMountStyle` is the §6A.3 mount-style discriminator (e.g.
  /// `hanging_rail`, `popper_base`). For most mount styles the
  /// rack layout is identical to v2.3 hanging-rail (children top at
  /// 0.26H), but `popper_base` poppers sit on the grass line —
  /// the layout puts each child's BOTTOM at 0.78H instead of its
  /// top at 0.26H. Unknown / null mount styles fall through to the
  /// hanging-rail layout.
  factory RealisticLayout.compute({
    required Size outerSize,
    required double targetWidthIn,
    required double targetHeightIn,
    required List<RackChildSpec>? rackChildren,
    required int? activeRackChildIndex,
    String? rackMountStyle,
    double? rangeYards,
    ReticleDefinition? reticle,
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
    // dirt mound. Sizing is mil-based when range + reticle are both
    // available, falling back to fixed-fraction otherwise.
    if (!isRack) {
      final tw = math.max(targetWidthIn, 1.0);
      final th = math.max(targetHeightIn, 1.0);
      final aspect = tw / th;

      // ── Sizing ────────────────────────────────────────────────────
      double targetWidthPx;
      double targetHeightPx;
      if (rangeYards != null && rangeYards > 0 && reticle != null) {
        // Mil-based sizing. The reticle's `maxExtentUnits` (in its
        // native unit) is the half-extent visible inside the scope
        // ring. We add 1.4× margin to match the FFP convention used
        // by the full ScopeViewScreen painter (lib/screens/range_day/
        // scope_view_screen.dart `_fovHalfMil`). pxPerMil is then
        // diameter/(2 × halfFovMil).
        final halfExtentNative = math.max(reticle.maxExtentUnits, 1.0);
        // Convert to mil if the reticle's native unit is MOA.
        final halfExtentMil = reticle.nativeUnit == ReticleNativeUnit.moa
            ? halfExtentNative / 3.4377  // mil-per-MOA conversion
            : halfExtentNative;
        final fovHalfMil = halfExtentMil * 1.4;
        final pxPerMil = scopeRadius / fovHalfMil;
        // Small-angle approximation: mil = in / (yd × 36) × 1000
        final widthMil = tw / (rangeYards * 36.0) * 1000.0;
        final heightMil = th / (rangeYards * 36.0) * 1000.0;
        targetWidthPx = widthMil * pxPerMil;
        targetHeightPx = heightMil * pxPerMil;
        // Floor at a pixel — degenerate inputs (rangeYd massive or
        // target tiny) shouldn't render an invisible target. The user
        // still sees ONE pixel that signals the target is there.
        targetWidthPx = math.max(targetWidthPx, 1.0);
        targetHeightPx = math.max(targetHeightPx, 1.0);
        // Cap at 90% of the scope diameter so very-close-range cases
        // (e.g. 25yd plinking) don't overflow the scope ring.
        final maxAllowedPx = scopeRadius * 1.8;
        if (targetWidthPx > maxAllowedPx) {
          final scale = maxAllowedPx / targetWidthPx;
          targetWidthPx *= scale;
          targetHeightPx *= scale;
        }
      } else {
        // Legacy fixed-fraction fallback for callers without distance
        // context. 18% of canvas width: small enough that a tall
        // 18×30 IPSC silhouette (aspect 0.6 → height = 1.667× width)
        // sits entirely above the dirt berm (mound at 0.82–0.92 H),
        // but large enough that the silhouette's head + shoulder
        // taper read as a recognisable bottle shape rather than a
        // featureless rectangle. The user's complaint that the
        // previous 16% rendered "too zoomed in" was symptomatic of
        // the silhouette geometry being too coarse at that size —
        // we've replaced the old two-rects rendering with a real
        // path-based bottle (see `_paintIpscSilhouette`) and bumped
        // the size so the shoulders are clearly visible.
        targetWidthPx = w * 0.18;
        targetHeightPx = targetWidthPx / aspect;
      }

      // ── Vertical positioning (Range Day Realistic §6.2.1) ─────────
      // Per `range_day_realistic_rewrite_v23.md` §6.2.1 the realistic
      // scene composition uses these band coefficients:
      //
      //   Sky region   : 0      → 0.78 H
      //   Grass region : 0.78 H → H
      //   Target       : 0.12 H → 0.55 H (varies by aspect)
      //   Post         : target_bottom → 0.85 H, width 0.025 W
      //   Mound        : 0.82 H → 0.92 H, width 0.18 W
      //
      // The backdrop painter (`scope_daytime_backdrop.dart`) reads
      // the SAME 0.78 horizon when constructed with
      // `realisticMode: true`, so the two stay aligned. Picker /
      // scope-view consumers default to `realisticMode: false` and
      // keep the legacy 0.62 horizon.
      //
      // Default target bottom: 0.55 H. The brief specifies this as
      // "varies by aspect ratio" because very-tall targets (e.g. a
      // popper at high magnification) may push the top above the
      // 0.12 H headroom line — we cap target height so target_top
      // stays ≥ 0.12 H.
      const targetBottomFraction = 0.55;
      const targetHeadroomFraction = 0.12;
      final targetBottom = h * targetBottomFraction;
      final maxTargetHeight =
          targetBottom - h * targetHeadroomFraction; // 0.43 H
      if (targetHeightPx > maxTargetHeight) {
        final scale = maxTargetHeight / targetHeightPx;
        targetWidthPx *= scale;
        targetHeightPx *= scale;
      }
      final targetTop = targetBottom - targetHeightPx;
      final targetLeft = (w - targetWidthPx) / 2;
      final activeRect = Rect.fromLTWH(
        targetLeft,
        targetTop,
        targetWidthPx,
        targetHeightPx,
      );
      // Post drops from target bottom (~0.55 H) to 0.85 H, with the
      // bottom 0.03 H tucked inside the mound (mound spans 0.82–0.92 H)
      // so the post visibly reads as "planted in the dirt." Width is
      // 0.025 W per the brief — derived in `_paintPole` from
      // `outerSize.width`.
      final poleX = w / 2;
      final poleTop = targetBottom;
      final poleBottom = h * 0.85;
      return RealisticLayout(
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
    double pxPerInch = math.min(pxPerInchByWidth, pxPerInchByHeight);

    // Mount-style-specific vertical positioning. Per §6A.3 of the
    // v2.3 brief:
    //
    //   * `popper_base` — poppers sit on the GRASS LINE (their bottom
    //     edge at 0.78H). Tall poppers can therefore push their TOP
    //     above the 0.12H headroom floor; if that happens we scale
    //     the rack down (uniformly) until the tallest child fits.
    //   * Everything else (`hanging_rail`, `standing_stakes`,
    //     `individual_posts`, unknown) — child TOPS at the legacy
    //     0.26H (cross-bar at 0.20H + a chain segment below it).
    //     Stakes / individual posts go DOWN from the child bottom
    //     into the foreground berm region.
    //
    // Mount-style strings are matched against the seed-data §6A.3
    // taxonomy stored on `TargetRacks.rackKind`. Unknown strings
    // (including `rotating_hub`, deferred to v2.4) fall through to
    // the hanging-rail layout. See target_racks.json for the source
    // of truth on which racks ship with which mount style.
    final isPopperBase = rackMountStyle == 'popper_base';

    final crossBarY = h * 0.20;
    final rackCenterX = w / 2;

    if (isPopperBase) {
      // Popper-base mode: children bottom-align on the grass line
      // (0.78H, where the foreground grass starts in realistic
      // backdrops). Check headroom: if the tallest child would push
      // its top above 0.12H, shrink the rack uniformly until it
      // fits. This keeps the popper rendering proportional rather
      // than letting one tall popper crop into the scope ring.
      const grassLineFraction = 0.78;
      const headroomFraction = 0.12;
      final grassY = h * grassLineFraction;
      final maxAllowedHeight = (grassLineFraction - headroomFraction) * h;
      final tallestPx = rackMaxHeightIn * pxPerInch;
      if (tallestPx > maxAllowedHeight && tallestPx > 0) {
        pxPerInch *= maxAllowedHeight / tallestPx;
      }
      final rects = <Rect>[];
      for (final c in children) {
        final cw = math.max(c.widthIn, 0.1) * pxPerInch;
        final ch = math.max(c.heightIn, 0.1) * pxPerInch;
        final childBottom = grassY;
        final childTop = childBottom - ch;
        final childCenterX =
            rackCenterX + c.offsetXFromCenterIn * pxPerInch;
        final childLeft = childCenterX - cw / 2;
        rects.add(Rect.fromLTWH(childLeft, childTop, cw, ch));
      }
      int activeIndex = (activeRackChildIndex ?? 0)
          .clamp(0, children.length - 1)
          .toInt();
      final activeRect = rects[activeIndex];
      return RealisticLayout(
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

    // Default rack layout (hanging_rail + standing_stakes +
    // individual_posts + unknown): children top at 0.26H, hanging-
    // rail-style positioning. Stakes / individual posts paint DOWN
    // from each child's bottom into the foreground berm region in
    // the painter, so the layout doesn't need to change per mount
    // style at this stage.
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

    return RealisticLayout(
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

/// Single-target realistic-mode painter. Composes a static scene:
///
///   1. Sky gradient — top 70% of canvas.
///   2. Grass — solid green, bottom 30%.
///   3. Mound — 60″ × 18″ brown ellipse straddling the horizon line.
///   4. Pole — 4″ × 72″ steel-grey post from mound apex up to target
///      bottom.
///   5. Target — fit inside a 0.50 W × 0.35 H bounding box, aspect
///      preserved, bottom-aligned at the pole's top. Dispatches to
///      AnimalSilhouettes / TargetSilhouettes when [TargetSpec.shapeId]
///      resolves; otherwise falls back to the procedural shape
///      switch (circle / silhouette / rectangle / square).
///
/// Real-world dimensions for the pole and mound are converted to
/// pixels via the reference scale `1 inch = H / 300 pixels`, derived
/// so the combined pole + mound vertical span (90 inches) fills 30%
/// of canvas height. The target's apparent size is decoupled from
/// real dimensions (fit-to-frame) — this is a stylized scene
/// preview, not a scope view at a real range.
///
/// This painter intentionally does NOT draw the reticle, scope ring,
/// aim crosshair, or shot dots — those move to subsequent phases.
/// Rack targets still use [_RealisticTargetPainter]; the dispatch
/// happens in [TargetPlot.build].
///
/// [lowLightMode] is accepted (so the call site doesn't need to
/// branch) but currently ignored — Phase 1 is daytime only. A dusk
/// palette will return when low-light mode is reinstated.
class _RealisticScenePainter extends CustomPainter {
  _RealisticScenePainter({
    required this.target,
    this.colorHexOverride,
  });

  final TargetSpec target;
  final String? colorHexOverride;

  // ── Layout constants ─────────────────────────────────────────────
  /// Horizon position: sky/grass boundary as a fraction of canvas H.
  /// Tuned to 0.75 (was 0.70 in Phase 4) — more sky overhead at the
  /// new target position gives a sense of "looking up at the target"
  /// rather than the target sitting flat on a wide grass strip.
  static const double _horizonFrac = 0.75;
  /// Reference scale denominator: 1 inch = H / _inchesPerCanvasHeight px.
  /// Tuned to 200 (was 300 in Phase 1) so a 60″ mound and a 60″-wide
  /// target end up similar widths on screen — visually coherent rather
  /// than the bear looking 3× wider than the mound it stands on.
  static const double _inchesPerCanvasHeight = 200.0;
  /// Target bounding box dimensions as fractions of canvas.
  /// Phase 6 bumped height 0.28 → 0.40 so the bear / IPSC / animal
  /// silhouettes become the focal point. A 60×32 bear (aspect 1.875)
  /// in a 156×93.6 box at H=234 now fits to width (156 wide × 83.2
  /// tall, bottom-aligned).
  static const double _targetBoxWidthFrac = 0.50;
  static const double _targetBoxHeightFrac = 0.40;
  /// Visible pole stub height as a fraction of the target box height.
  /// Phase 6 bumped 0.20 → 0.25 in concert with the bigger target
  /// box so the pole stub stays visually proportional.
  static const double _visiblePoleFracOfTarget = 0.25;

  // ── Palette ──────────────────────────────────────────────────────
  static const Color _skyTopColor = Color(0xff5e8db8);
  static const Color _skyBottomColor = Color(0xffb8d4e6);
  static const Color _grassColor = Color(0xff6b8c3e);
  static const Color _grassTuftColor = Color(0xff54702f); // darker, for grass blades at horizon and tall-grass clumps
  static const Color _moundFillColor = Color(0xff8b6f47); // medium dirt brown
  static const Color _moundHighlightColor = Color(0xffa8855a); // sandy upper edge
  static const Color _moundShadowColor = Color(0xff5a3f25); // darker brown for shaded surface
  static const Color _moundClumpColor = Color(0xff6f5538); // small clumps of dirt
  static const Color _moundRockColor = Color(0xff3e2a16); // small rocks / dark spots
  static const Color _poleColor = Color(0xff7a7a7a);
  static const Color _poleHighlightColor = Color(0xff9a9a9a);
  static const Color _poleShadowColor = Color(0xff5a5a5a);
  static const Color _poleBaseRingColor = Color(0xff4a3422); // disturbed earth ring around pole base
  static const Color _targetOutlineColor = Color(0xff1a1a1a);
  // Phase 6 — Group C background depth layers
  static const Color _distantHillsColor = Color(0xffa8b5a0); // atmospheric-perspective faded green-grey
  static const Color _treelineColor = Color(0xff3a5a1f); // dark green tree silhouettes against sky

  // Phase 6 — background layer geometry
  static const double _distantHillsMaxHeight = 30.0; // px above horizon at peaks
  static const double _treelineMaxHeight = 12.0; // px above horizon at peaks
  static const int _treelineCount = 12; // individual tree silhouettes
  static const int _tallGrassClumpCount = 5;
  static const double _tallGrassClumpMaxHeight = 15.0; // px tall blade max

  // Phase 7a — foreground tree at right edge for depth cue.
  // Height scales with the target box so the tree's relative size
  // stays consistent across canvas sizes. X-position fixed at 85%
  // canvas width so the tree sits to the right of the centered
  // target rect and never overlaps the silhouette.
  static const double _treeHeightFracOfTarget = 1.2;
  static const double _treeXFracOfCanvas = 0.85;
  static const Color _treeTrunkColor = Color(0xff5c3a1e); // dark brown
  static const Color _treeCrownColor = Color(0xff4a6a2f); // dark conifer green

  @override
  void paint(Canvas canvas, Size size) {
    if (size.width <= 0 || size.height <= 0) return;
    final w = size.width;
    final h = size.height;
    final inPerPx = h / _inchesPerCanvasHeight;

    // Layout math (single source for all paint helpers):
    //   horizon_y          = 0.75 H (sky/grass boundary, Phase 5)
    //   mound straddles horizon, half above, half below
    //   visible pole stub is derived from target box height (Phase 5)
    //   Phase 8: pole is FIXED at canvas center horizontally; pole's
    //     visual top is at a fixed Y. Target rect MOVES so its
    //     center_point lands on the pole, not the other way around.
    //     At default cp=0.5/0.5 this produces zero visual change vs
    //     Phase 7a — only catalog rows with non-default cp (animals
    //     at horizontal_from_left=0.7) shift off canvas center.
    final horizonY = _horizonFrac * h;
    final moundHeight = 18.0 * inPerPx;
    final moundApexY = horizonY - moundHeight * 0.5;

    // Target bounding box dimensions (pre fit-to-aspect).
    final boxW = w * _targetBoxWidthFrac;
    final boxH = h * _targetBoxHeightFrac;

    // Fit-to-box preserving the target's natural aspect. The actual
    // rendered target is `targetW × targetH`, ≤ box in both axes.
    final targetAspect = target.widthIn / target.heightIn;
    final boxAspect = boxW / boxH;
    final double targetW;
    final double targetH;
    if (targetAspect > boxAspect) {
      // Target proportionally wider than box → fit to width.
      targetW = boxW;
      targetH = boxW / targetAspect;
    } else {
      // Target proportionally taller than box → fit to height.
      targetH = boxH;
      targetW = boxH * targetAspect;
    }

    // Visible pole stub uses the BOX height (per Phase 5), not the
    // post-fit targetH — keeps stub proportional to the scene rather
    // than to individual silhouettes.
    final visiblePoleHeight = boxH * _visiblePoleFracOfTarget;

    // Phase 8 Group A: pole position is FIXED, target follows.
    //
    // Pole's geometric top derived to match Phase 7a EXACTLY when
    // cp.verticalFromTop = 0.5. Derivation:
    //   Phase 7a: targetBottomY  = moundApex - visiblePoleHeight
    //             targetTop      = targetBottomY - targetH
    //             visualPoleTopY = targetTop + 0.5 * targetH
    //                            = moundApex - visiblePoleHeight
    //                              - 0.5 * targetH
    // We use that same formula here, then solve BACKWARDS for the
    // target rect from cp + the fixed pole position.
    //
    // (NB: the spec wrote the formula using `targetBoxH` which would
    // diverge from Phase 7a for fit-to-width targets like the bear.
    // We use post-fit `targetH` to honour the spec's stated intent
    // — "zero visual change for any catalog row at default cp" —
    // which the literal `targetBoxH` formulation doesn't deliver.)
    final cp = target.centerPoint;
    final poleX = w / 2;
    final visualPoleTopY =
        moundApexY - visiblePoleHeight - 0.5 * targetH;

    // Solve backwards for target rect position from cp + pole anchors.
    //   targetTop  + cp.verticalFromTop  * targetH = visualPoleTopY
    //   targetLeft + cp.horizontalFromLeft * targetW = poleX
    //
    // CONSTRAINT (no runtime guard): cp.verticalFromTop should not
    // exceed `1.0 - _visiblePoleFracOfTarget` (currently 0.75) or
    // the target rect's bottom drops below the mound apex. All 58
    // current catalog rows have cp.verticalFromTop = 0.5, so this
    // is safe today. Bring back a runtime assert if Phase 9+ adds
    // per-animal vertical tuning that approaches the limit.
    final targetLeft = poleX - cp.horizontalFromLeft * targetW;
    final targetTop = visualPoleTopY - cp.verticalFromTop * targetH;
    final targetRect =
        Rect.fromLTWH(targetLeft, targetTop, targetW, targetH);
    final visualPoleHeight = moundApexY - visualPoleTopY;

    // Phase 7a Group C layer order (extends Phase 6):
    //   sky → distant hills → treeline → grass field → tall grass
    //   → foreground tree → mound → pole → horizon tufts
    //   → pole base ring → target
    // Foreground tree paints AFTER tall grass and BEFORE mound so
    // it reads as a depth layer between the foreground grass and
    // the dirt pile. Tree is at x = 0.85W; target rect is centered;
    // they don't overlap.
    _paintSky(canvas, w, h, horizonY);
    _paintDistantHills(canvas, w, horizonY);
    _paintTreeline(canvas, w, horizonY);
    _paintGrass(canvas, w, h, horizonY);
    _paintTallGrass(canvas, w, h, horizonY, inPerPx);
    _paintForegroundTree(canvas, w, horizonY, boxH);
    _paintMound(canvas, w, horizonY, inPerPx);
    _paintPole(canvas, poleX, visualPoleTopY, visualPoleHeight,
        visiblePoleHeight);
    _paintGrassTufts(canvas, w, horizonY, inPerPx);
    _paintPoleBaseRing(canvas, poleX, moundApexY, visiblePoleHeight);
    _paintTarget(canvas, targetRect);
  }

  void _paintSky(Canvas canvas, double w, double h, double horizonY) {
    final rect = Rect.fromLTWH(0, 0, w, horizonY);
    final paint = Paint()
      ..shader = const LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [_skyTopColor, _skyBottomColor],
      ).createShader(rect);
    canvas.drawRect(rect, paint);
  }

  /// Distant hills behind the horizon. A single cubic-bezier path
  /// forming 3 gentle wide peaks across the canvas width. Filled
  /// with a faded green-grey ("atmospheric perspective"); peaks rise
  /// up to [_distantHillsMaxHeight] px above the horizon. Path closes
  /// along the horizon so the lower portion sits behind the grass
  /// field (painted next).
  ///
  /// Deterministic peak positions driven only by canvas width — same
  /// canvas size always yields the same hills, frame after frame.
  void _paintDistantHills(Canvas canvas, double w, double horizonY) {
    final path = Path();
    path.moveTo(0, horizonY);
    // Three peaks: left at 0.2W, center at 0.5W, right at 0.85W.
    // Peak heights vary slightly so the silhouette isn't symmetric.
    path.cubicTo(
      w * 0.10, horizonY - _distantHillsMaxHeight * 0.55,
      w * 0.15, horizonY - _distantHillsMaxHeight * 1.00,
      w * 0.20, horizonY - _distantHillsMaxHeight * 0.85,
    );
    path.cubicTo(
      w * 0.30, horizonY - _distantHillsMaxHeight * 0.45,
      w * 0.42, horizonY - _distantHillsMaxHeight * 0.95,
      w * 0.50, horizonY - _distantHillsMaxHeight * 0.75,
    );
    path.cubicTo(
      w * 0.60, horizonY - _distantHillsMaxHeight * 0.40,
      w * 0.75, horizonY - _distantHillsMaxHeight * 0.65,
      w * 0.85, horizonY - _distantHillsMaxHeight * 0.55,
    );
    path.cubicTo(
      w * 0.92, horizonY - _distantHillsMaxHeight * 0.30,
      w * 0.97, horizonY - _distantHillsMaxHeight * 0.15,
      w, horizonY,
    );
    path.close();
    canvas.drawPath(path, Paint()..color = _distantHillsColor);
  }

  /// Treeline silhouettes between the hills and the grass field.
  /// [_treelineCount] small dark-green tree shapes (rounded triangles)
  /// spaced across the canvas width with overlapping placement; peak
  /// heights vary deterministically via `sin(i * 1.3)` so neighbours
  /// don't read as identical. Each tree closes its base along the
  /// horizon line — the grass painted next will cover the seam.
  void _paintTreeline(Canvas canvas, double w, double horizonY) {
    final paint = Paint()..color = _treelineColor;
    final treeBaseW = w / (_treelineCount * 0.85); // slight overlap
    for (var i = 0; i < _treelineCount; i++) {
      final cx = (i + 0.5) * (w / _treelineCount);
      // Height varies 0.5..1.0 of the configured max.
      final tHeight = _treelineMaxHeight *
          (0.5 + 0.5 * (math.sin(i * 1.3) + 1.0) * 0.5);
      final halfW = treeBaseW * 0.5;
      final path = Path();
      path.moveTo(cx - halfW, horizonY);
      // Rounded triangle: quad-bezier up to the peak from each side.
      path.quadraticBezierTo(
        cx - halfW * 0.35, horizonY - tHeight * 0.65,
        cx, horizonY - tHeight,
      );
      path.quadraticBezierTo(
        cx + halfW * 0.35, horizonY - tHeight * 0.65,
        cx + halfW, horizonY,
      );
      path.close();
      canvas.drawPath(path, paint);
    }
  }

  /// Tall grass clumps scattered in the foreground grass field
  /// (below the horizon). [_tallGrassClumpCount] clumps, each with
  /// 3-5 vertical blade strokes up to [_tallGrassClumpMaxHeight] px
  /// tall. Positions deterministic via sin/cos of canvas width.
  /// Skips the mound's horizontal extent so clumps don't paint
  /// across the dirt pile.
  void _paintTallGrass(
    Canvas canvas,
    double w,
    double h,
    double horizonY,
    double inPerPx,
  ) {
    final paint = Paint()
      ..color = _grassTuftColor
      ..strokeWidth = 1.0
      ..style = PaintingStyle.stroke;

    final cx = w / 2;
    final moundHalfW = 60.0 * inPerPx * 0.5;
    final grassBand = h - horizonY;

    for (var i = 0; i < _tallGrassClumpCount; i++) {
      // Deterministic positions across the canvas; cosine drives
      // vertical placement within the grass band.
      final clumpX =
          w * (0.10 + 0.80 * ((math.sin(i * 2.3) + 1.0) * 0.5));
      // Skip if the clump would paint on top of the mound.
      if ((clumpX - cx).abs() < moundHalfW) continue;
      // Vertical position: scattered through the grass band, biased
      // slightly toward the front (lower y).
      final clumpY = horizonY +
          grassBand * (0.20 + 0.60 * ((math.cos(i * 1.7) + 1.0) * 0.5));
      // 3..5 blades per clump.
      final blades = 3 + (i % 3);
      for (var j = 0; j < blades; j++) {
        final jitterX = (j - blades * 0.5) * 2.0;
        final bladeH = _tallGrassClumpMaxHeight *
            (0.5 + 0.5 * ((math.sin(i * 3.1 + j * 0.9) + 1.0) * 0.5));
        canvas.drawLine(
          Offset(clumpX + jitterX, clumpY),
          Offset(clumpX + jitterX, clumpY - bladeH),
          paint,
        );
      }
    }
  }

  /// Foreground tree silhouette at the right edge of the canvas.
  /// Provides a near-distance depth cue between the foreground grass
  /// field and the dirt mound. The tree's height scales with the
  /// target box so its size relative to the bear (and other targets)
  /// stays visually consistent across canvas sizes; x-position is
  /// fixed at 85% canvas width so it never overlaps the centered
  /// target rect.
  ///
  /// Geometry: vertical trunk rooted at `horizonY` (so the base
  /// disappears behind the grass field's edge — natural grounding
  /// cue) plus 3 overlapping circles forming a leafy conifer crown.
  /// Reserved for a future `windDirection` field to animate the
  /// crown; Phase 7a builds the helper but no animation code.
  void _paintForegroundTree(
    Canvas canvas,
    double w,
    double horizonY,
    double targetBoxH,
  ) {
    final treeHeight = targetBoxH * _treeHeightFracOfTarget;
    final treeX = w * _treeXFracOfCanvas;
    const double trunkW = 4.0;
    final trunkH = treeHeight * 0.35;
    final crownRadius = treeHeight * 0.32;

    // Trunk rooted at the horizon line.
    final trunkRect = Rect.fromLTWH(
      treeX - trunkW / 2,
      horizonY - trunkH,
      trunkW,
      trunkH,
    );
    canvas.drawRect(trunkRect, Paint()..color = _treeTrunkColor);

    // Three overlapping circles for a leafy crown — center on top,
    // two slightly lower on each side, all at ~70% of the center
    // circle's radius for visual proportion.
    final crownCenter = Offset(treeX, horizonY - trunkH - crownRadius);
    final crownPaint = Paint()..color = _treeCrownColor;
    canvas.drawCircle(crownCenter, crownRadius, crownPaint);
    canvas.drawCircle(
      crownCenter.translate(-crownRadius * 0.55, crownRadius * 0.25),
      crownRadius * 0.7,
      crownPaint,
    );
    canvas.drawCircle(
      crownCenter.translate(crownRadius * 0.55, crownRadius * 0.25),
      crownRadius * 0.7,
      crownPaint,
    );
  }

  void _paintGrass(Canvas canvas, double w, double h, double horizonY) {
    // Solid grass field. The horizon boundary is conveyed by the
    // mound + grass tufts painted on top later, NOT by a hard
    // horizon stroke — which read as artificial separation between
    // scene elements.
    canvas.drawRect(
      Rect.fromLTWH(0, horizonY, w, h - horizonY),
      Paint()..color = _grassColor,
    );
  }

  /// Small grass blades along the horizon line, breaking up the hard
  /// edge between grass and sky / mound. Tufts are short vertical
  /// strokes at varying heights using a darker green than the grass
  /// field — read as blades silhouetted against the sky.
  ///
  /// Skips a band centered on the mound (the mound's silhouette
  /// occupies the horizon there). Deterministic positions via sin().
  void _paintGrassTufts(
    Canvas canvas,
    double w,
    double horizonY,
    double inPerPx,
  ) {
    final paint = Paint()
      ..color = _grassTuftColor
      ..strokeWidth = 1.0
      ..style = PaintingStyle.stroke;

    final cx = w / 2;
    final moundW = 60.0 * inPerPx;
    final moundHalfW = moundW * 0.5;

    // Step across the horizon at small intervals. Skip the band
    // where the mound sits. Step tightened to ~3px (Phase 5) — was
    // ~5-8px in Phase 4. Roughly 1.67× more blades, removes the
    // visible gaps between tufts that read as sparse.
    final stepPx = math.max(w / 100.0, 3.0);
    for (var x = stepPx * 0.5; x < w; x += stepPx) {
      // Skip if inside the mound's horizontal extent (with a small
      // margin so tufts blend with the mound edges).
      if ((x - cx).abs() < moundHalfW - 4.0) continue;
      // Vary blade heights via sin so tufts are not uniform.
      final heightVariation = (math.sin(x * 0.4) + 1.0) * 0.5; // 0..1
      final bladeH = 1.5 + heightVariation * 4.0;
      canvas.drawLine(
        Offset(x, horizonY),
        Offset(x, horizonY - bladeH),
        paint,
      );
    }

    // Darker grass clumps where the mound meets the grass —
    // gives the mound a sense of being EMBEDDED in the ground
    // rather than sitting on top. Phase 5 expanded from 6 → 10
    // clumps (5 each side) and staggered heights via a 1.5×
    // multiplier on alternate indices. Phase 6 fixes the
    // symmetry: the multiplier now keys off the PAIR INDEX
    // `(i ~/ 2).isEven` instead of `i.isEven`, so both left and
    // right clumps at the same distance from the mound center
    // get the same height. Pre-fix, all left-side clumps were
    // tall and all right-side short — visible asymmetry.
    for (var i = 0; i < 10; i++) {
      final side = i.isEven ? -1.0 : 1.0;
      final t = (i ~/ 2) / 4.0; // 0, 0.25, 0.50, 0.75, 1.0
      final x = cx + side * (moundHalfW - 2.0 - t * 8.0);
      final heightMultiplier = (i ~/ 2).isEven ? 1.5 : 1.0;
      final bladeH = (2.0 + math.sin(i * 1.7) * 1.5) * heightMultiplier;
      canvas.drawLine(
        Offset(x, horizonY + 1.0),
        Offset(x, horizonY - bladeH),
        paint,
      );
    }
  }

  void _paintMound(
    Canvas canvas,
    double w,
    double horizonY,
    double inPerPx,
  ) {
    final moundW = 60.0 * inPerPx;
    final moundH = 18.0 * inPerPx;
    final cx = w / 2;

    // 1. Base silhouette — irregular asymmetric pile, NOT a clean
    //    ellipse. Built from cubic-bezier segments forming two
    //    sub-peaks and varied slopes. The path closes along the
    //    horizon, so the lower half of the pile is naturally hidden
    //    by the grass painted above.
    final base = Path();
    base.moveTo(cx - moundW * 0.50, horizonY);
    // Left slope — rises with a bump
    base.cubicTo(
      cx - moundW * 0.42, horizonY - moundH * 0.30,
      cx - moundW * 0.34, horizonY - moundH * 0.70,
      cx - moundW * 0.18, horizonY - moundH * 0.85,
    );
    // First sub-peak (left of center)
    base.cubicTo(
      cx - moundW * 0.08, horizonY - moundH * 0.95,
      cx - moundW * 0.02, horizonY - moundH * 1.00,
      cx + moundW * 0.04, horizonY - moundH * 0.92,
    );
    // Saddle dip and second sub-peak (right of center)
    base.cubicTo(
      cx + moundW * 0.10, horizonY - moundH * 0.82,
      cx + moundW * 0.16, horizonY - moundH * 0.88,
      cx + moundW * 0.24, horizonY - moundH * 0.78,
    );
    // Right slope — descends with a bump
    base.cubicTo(
      cx + moundW * 0.36, horizonY - moundH * 0.50,
      cx + moundW * 0.46, horizonY - moundH * 0.18,
      cx + moundW * 0.50, horizonY,
    );
    base.close();
    canvas.drawPath(base, Paint()..color = _moundFillColor);

    // 2. Shadowed lower-right slope — a slightly translucent darker
    //    overlay on the right side, suggesting the sun's coming from
    //    the upper left (consistent with the pole's left-side
    //    highlight).
    final shadow = Path();
    shadow.moveTo(cx + moundW * 0.04, horizonY - moundH * 0.92);
    shadow.cubicTo(
      cx + moundW * 0.16, horizonY - moundH * 0.85,
      cx + moundW * 0.30, horizonY - moundH * 0.55,
      cx + moundW * 0.50, horizonY,
    );
    shadow.lineTo(cx + moundW * 0.04, horizonY);
    shadow.close();
    canvas.drawPath(
      shadow,
      Paint()..color = _moundShadowColor.withValues(alpha: 0.40),
    );

    // 3. Highlight strokes — three small lighter patches on the
    //    upper-left side suggesting light catching the dirt's
    //    high points.
    final highlight = Paint()
      ..color = _moundHighlightColor.withValues(alpha: 0.55);
    for (var i = 0; i < 3; i++) {
      final t = (i + 1) / 4.0; // 0.25, 0.50, 0.75
      final hx = cx - moundW * 0.32 + (t * moundW * 0.30);
      final hy = horizonY - moundH * (0.50 + 0.30 * math.sin(t * math.pi));
      final hr = math.max(moundH * 0.12 * (1.0 - 0.2 * i), 0.8);
      canvas.drawCircle(Offset(hx, hy), hr, highlight);
    }

    // 4. Clumps — 8 small darker oval blobs distributed across the
    //    pile's surface. Deterministic positions via sin/cos so the
    //    same target paints identically every frame.
    final clump = Paint()..color = _moundClumpColor;
    for (var i = 0; i < 8; i++) {
      final angle = i * 0.78; // ~0.78 rad ≈ 45° step
      final tx = cx + math.sin(angle * 1.7) * moundW * 0.36;
      final tyOffset = math.cos(angle * 1.3) * moundH * 0.45;
      final ty = horizonY - moundH * 0.55 + tyOffset;
      final cw = math.max(moundH * 0.18, 1.0);
      final ch = math.max(moundH * 0.10, 0.6);
      canvas.drawOval(
        Rect.fromCenter(
          center: Offset(tx, ty),
          width: cw,
          height: ch,
        ),
        clump,
      );
    }

    // 5. Rocks — 5 small near-black dots scattered as visible
    //    pebbles/rocks. Smaller than clumps; suggest grit.
    final rock = Paint()..color = _moundRockColor;
    for (var i = 0; i < 5; i++) {
      final angle = i * 1.25;
      final rx = cx + math.sin(angle) * moundW * 0.30;
      final ry = horizonY - moundH * 0.40 + math.cos(angle * 0.9) * moundH * 0.35;
      final rr = math.max(moundH * 0.06, 0.5);
      canvas.drawCircle(Offset(rx, ry), rr, rock);
    }
  }

  void _paintPole(
    Canvas canvas,
    double poleX,
    double poleTopY,
    double poleHeight,
    double visiblePoleHeight,
  ) {
    // Phase 6 Group B: pole width derived from visible pole height
    // (max(2.5, visiblePoleHeight × 0.15)) so the pole stays
    // proportional to its own length. Was a fixed 4" × inPerPx in
    // Phase 5; that scaled with canvas height but not with the new
    // smaller pole stub, which left the pole looking chunky.
    final poleW = math.max(2.5, visiblePoleHeight * 0.15);
    final halfW = poleW / 2;

    // Main body — steel grey
    canvas.drawRect(
      Rect.fromLTWH(poleX - halfW, poleTopY, poleW, poleHeight),
      Paint()..color = _poleColor,
    );

    // Cylinder cue: a 25% wide lighter strip on the left, a 25% wide
    // darker strip on the right. Reads as a round-ish metal post.
    final stripW = math.max(poleW * 0.25, 0.5);
    canvas.drawRect(
      Rect.fromLTWH(poleX - halfW, poleTopY, stripW, poleHeight),
      Paint()..color = _poleHighlightColor,
    );
    canvas.drawRect(
      Rect.fromLTWH(
          poleX + halfW - stripW, poleTopY, stripW, poleHeight),
      Paint()..color = _poleShadowColor,
    );
  }

  /// A small darker oval ring at the pole's base, where the post
  /// enters the mound. Suggests disturbed earth around the post —
  /// the "this is planted in the ground" cue.
  ///
  /// Phase 6 Group A: anchored to the configurable `poleX` instead
  /// of canvas center, so the ring follows the pole when per-target
  /// `center_point` horizontal offsets pull it off-center.
  void _paintPoleBaseRing(
    Canvas canvas,
    double poleX,
    double moundApexY,
    double visiblePoleHeight,
  ) {
    // Phase 6 Group B: ring sizing derived from the pole's own width
    // (which is in turn derived from visiblePoleHeight). Keeps the
    // ring scale proportional as the pole grows / shrinks.
    final poleW = math.max(2.5, visiblePoleHeight * 0.15);
    final ringW = math.max(poleW * 3.0, 6.0);
    final ringH = math.max(poleW * 0.9, 2.0);
    canvas.drawOval(
      Rect.fromCenter(
        center: Offset(poleX, moundApexY + ringH * 0.4),
        width: ringW,
        height: ringH,
      ),
      Paint()..color = _poleBaseRingColor.withValues(alpha: 0.70),
    );
  }

  // _computeTargetRect was retired in Phase 8 Group A — the painter
  // now inlines the fit-to-box + position math in `paint()` because
  // the pole-position derivation needs intermediate values
  // (targetH for visualPoleTopY) that an external helper would
  // either have to return as a tuple or recompute. The inlined
  // version is ~20 lines, well-commented, and the only consumer.

  void _paintTarget(Canvas canvas, Rect rect) {
    // Fill color: override beats target.colorHex; both go through the
    // same hex parser.
    final fillHex = colorHexOverride ?? target.colorHex;
    final fillColor = _parseHexColor(fillHex);
    final fillPaint = Paint()..color = fillColor;
    final outlinePaint = Paint()
      ..color = _targetOutlineColor
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.6;

    // Shared dispatch: SVG path if shapeId resolves, otherwise null.
    // See top-level [resolveTargetSvgPath]. Phase 7a threads the
    // per-target svgScaleFactor through so animals with antlers /
    // horns / tall tails (deer, elk, moose, etc.) can overflow the
    // rect into the sky region.
    final svgPath = resolveTargetSvgPath(
      rect,
      target.shapeId,
      scaleFactor: target.svgScaleFactor,
    );
    if (svgPath != null) {
      canvas.drawPath(svgPath, fillPaint);
      canvas.drawPath(svgPath, outlinePaint);
      return;
    }

    // Procedural fallback.
    switch (target.shape) {
      case 'circle':
        final r = rect.shortestSide / 2;
        canvas.drawCircle(rect.center, r, fillPaint);
        canvas.drawCircle(rect.center, r, outlinePaint);
        break;
      case 'silhouette':
        final ipsc = buildIpscPath(rect);
        canvas.drawPath(ipsc, fillPaint);
        canvas.drawPath(ipsc, outlinePaint);
        break;
      case 'square':
      case 'rectangle':
      default:
        canvas.drawRect(rect, fillPaint);
        canvas.drawRect(rect, outlinePaint);
        break;
    }
  }

  static Color _parseHexColor(String hex) {
    var v = hex.replaceAll('#', '');
    if (v.length == 6) v = 'ff$v';
    return Color(int.parse(v, radix: 16));
  }

  @override
  bool shouldRepaint(_RealisticScenePainter old) {
    return old.target.shape != target.shape ||
        old.target.shapeId != target.shapeId ||
        old.target.widthIn != target.widthIn ||
        old.target.heightIn != target.heightIn ||
        old.target.colorHex != target.colorHex ||
        old.colorHexOverride != colorHexOverride;
  }
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
    this.colorHexOverride,
    this.lowLightMode = false,
    this.rackMountStyle,
  })  : _backdropPainter = ScopeDaytimeBackdropPainter(
          // We render the target ourselves on top of the backdrop so
          // the backdrop only paints the scenery layers. [lowLightMode]
          // is forwarded so the sky / grass / mound palette flips to
          // the §6A.2 dusk variant in lockstep with the parent
          // screen's AppBar toggle. `realisticMode: true` tells the
          // backdrop to use the §6.2.1 band coefficients (horizon at
          // 0.78 H, mound as a foreground berm at 0.82–0.92 H × 0.18 W)
          // instead of the legacy picker / scope-view layout.
          //
          // [paintMound] is `false` ONLY for the two mount styles
          // that bring their own per-child ground furniture — popper
          // bases (concrete trapezoids on the grass line) and
          // individual posts (per-child wooden post + earth berm).
          // For every other mode (single target, hanging rail,
          // standing stakes, unknown rack mount style) the shared
          // foreground berm stays on so the post / stakes look
          // planted in the dirt.
          target: BackdropTargetSilhouette.none,
          targetWidthFraction: 0,
          targetColor: const Color(0xff5e6552),
          lowLightMode: lowLightMode,
          realisticMode: true,
          paintMound: !(rackMountStyle == 'popper_base' ||
              rackMountStyle == 'individual_posts'),
        ),
        // Wood-brown post per §6.2.1 of the v2.3 brief — the legacy
        // dark-grey colour read as a steel pole; the realistic scene
        // wants a lumber target stand.
        _polePaint = Paint()..color = const Color(0xff6f5039),
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
  final RealisticLayout layout;
  final Color primary;
  final Color errorColor;
  final Color textColor;
  /// User-selected color override hex (e.g. `'#cc1f1f'`). Only the
  /// active target / active rack child takes the override; non-active
  /// rack children retain their natural cream color so the override
  /// doesn't visually leak across the whole rack.
  final String? colorHexOverride;

  /// When `true`, the painter's backdrop pulls the §6A.2 dusk palette
  /// (forwarded into [_backdropPainter] via its [ScopeDaytimeBackdropPainter.lowLightMode]
  /// field). The painter's own built-in precision-mil reticle stays
  /// black — only the center dot (which simulates an illuminated
  /// reticle in real scopes) is unaffected because it's already red
  /// in both palettes. Defaults to `false`.
  final bool lowLightMode;

  /// §6A.3 mount-style discriminator for the active rack. Drives
  /// which ground-furniture helper [paint] dispatches to in rack
  /// mode (`hanging_rail` → `_paintHangingRail`, `standing_stakes`
  /// → `_paintStakes`, `popper_base` → `_paintPopperBases`,
  /// `individual_posts` → `_paintIndividualPosts`). Unknown values
  /// — including `rotating_hub`, which is deferred to v2.4 per
  /// Phase 2 errata — fall through to `_paintHangingRail`. Ignored
  /// for single-target rendering; the field is just unused when
  /// `layout.isRack` is false.
  final String? rackMountStyle;

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

    // 2. Pole (single mode) OR rack ground furniture (rack mode).
    //
    // Rack mount-style dispatch per §6A.3 of the v2.3 brief:
    //
    //   * `hanging_rail`     → horizontal cross-bar across the top
    //                          of the children + a chain from the
    //                          bar down to each child.
    //   * `standing_stakes`  → one thin wood-brown stake under each
    //                          child, running from the child's
    //                          bottom down into the foreground mound.
    //   * `popper_base`      → concrete trapezoidal base under each
    //                          child sitting on the grass line; the
    //                          shared mound is hidden upstream via
    //                          [_backdropPainter]'s paintMound flag.
    //   * `individual_posts` → one wooden post + small individual
    //                          earth-berm oval under each child; the
    //                          shared mound is hidden upstream as
    //                          above.
    //   * any other value (including `rotating_hub`, which is
    //     deferred to v2.4 per Phase 2 errata) → falls through to
    //     `hanging_rail` so the rack still renders sensibly.
    if (!layout.isRack) {
      _paintPole(canvas);
    } else {
      switch (rackMountStyle) {
        case 'standing_stakes':
          _paintStakes(canvas, size);
          break;
        case 'popper_base':
          _paintPopperBases(canvas, size);
          break;
        case 'individual_posts':
          _paintIndividualPosts(canvas, size);
          break;
        case 'hanging_rail':
        default:
          // `rotating_hub` lands here too (v2.4 deferral).
          _paintHangingRail(canvas, size);
          break;
      }
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
    // Single-target post per §6.2.1 of the v2.3 brief:
    //
    //   * Width: 0.025 × canvas width (~ 1.6 % of canvas width on each
    //     side of [poleX]). Reads as a 2×2 or 2×4 wooden upright at
    //     typical scope-view canvas sizes.
    //   * Vertical extent: from target_bottom (~ 0.55 H) down to
    //     0.85 H, with the bottom 0.03 H tucked behind the foreground
    //     berm (mound at 0.82–0.92 H) so the post visibly reads as
    //     "planted in the dirt."
    //   * Colour: wood brown ([_polePaint] set in the constructor).
    //
    // Sized off `layout.outerSize.width` (not a fixed pixel count) so
    // the post stays proportional to the scope view across canvas
    // sizes.
    final w = layout.outerSize.width;
    final poleHalfWidth = w * 0.025 * 0.5;
    final rect = Rect.fromLTWH(
      layout.poleX - poleHalfWidth,
      layout.poleTop,
      poleHalfWidth * 2,
      layout.poleBottom - layout.poleTop,
    );
    canvas.drawRect(rect, _polePaint);
  }

  /// Hanging-rail rack mount style — a horizontal dark cross-bar
  /// runs above the children, and each child dangles from a short
  /// dashed chain. Used by KYL, Equal, and Decreasing racks
  /// (§6A.3 mount-style table). The legacy implementation from
  /// Phase 4b; renamed from `_paintCrossBarAndChains` so the mount-
  /// style dispatch reads cleanly at the call site.
  void _paintHangingRail(Canvas canvas, Size size) {
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

  /// Standing-stakes rack mount style — each child rides on its own
  /// thin vertical wood-brown stake that runs from the child's
  /// bottom down into the foreground mound region (which the shared
  /// `_backdropPainter` is still drawing in this mode). Used by
  /// Square Rack and other racks where each child sits on a single
  /// stake instead of hanging from a rail (§6A.3 mount-style
  /// table). Reuses [_polePaint] (wood brown) so the stakes match
  /// the single-target post visually.
  void _paintStakes(Canvas canvas, Size size) {
    if (layout.childRects.isEmpty) return;
    final w = size.width;
    final h = size.height;
    // Stake width: 0.012 of canvas width — half the 0.025W width
    // used by the single-target post in `_paintPole`, because a
    // standing-stakes rack has multiple stakes and a full-width
    // post would crowd the scene. Bottom of each stake terminates
    // at 0.85H (same convention as the single post) so the bottom
    // 0.03H tucks behind the shared mound at 0.82–0.92H. Top of
    // the stake starts at the child's bottom edge so it visibly
    // supports the plate.
    final stakeHalfWidth = w * 0.012 * 0.5;
    final stakeBottomY = h * 0.85;
    for (final r in layout.childRects) {
      // Skip if the child's bottom is already below the mound
      // (degenerate input); the stake would have zero or negative
      // height and Flutter draws an inverted-Y rect as nothing —
      // skipping is cleaner.
      if (r.bottom >= stakeBottomY) continue;
      final stakeRect = Rect.fromLTRB(
        r.center.dx - stakeHalfWidth,
        r.bottom,
        r.center.dx + stakeHalfWidth,
        stakeBottomY,
      );
      canvas.drawRect(stakeRect, _polePaint);
    }
  }

  /// Popper-base rack mount style — each child sits on its own
  /// concrete-grey trapezoidal base directly on the grass line.
  /// The shared foreground mound is suppressed (via the
  /// `paintMound: false` flag on [_backdropPainter]) so the scene
  /// reads as "five poppers standing on the dirt" rather than
  /// "five poppers in front of a brown blob." Used by the
  /// Pepper Popper rack (§6A.3 mount-style table).
  ///
  /// Trapezoid geometry: top width = 1.5× child width, bottom width
  /// = 2× child width, height = 6 inches converted to pixels. The
  /// height is derived from the child's existing inch-to-pixel
  /// scale (rect.width / spec width) so the base looks proportional
  /// regardless of how big the popper renders against the FOV.
  void _paintPopperBases(Canvas canvas, Size size) {
    if (layout.childRects.isEmpty) return;
    // We don't have direct access to the RackChildSpec list at the
    // painter level — only the computed pixel rectangles. Derive a
    // px-per-inch estimate from the popper rack's known spec: the
    // canonical pepper popper is 8 inches wide. We deliberately use
    // a coefficient on rect.width rather than referencing a magic
    // constant because the rack may be scaled down for headroom
    // (per the `popper_base` branch in `RealisticLayout.compute`).
    // Concrete base height = ~0.75 × child width in pixels (a 6-in
    // tall base on an 8-in wide popper → 0.75).
    final basePaint = Paint()..color = const Color(0xff9a9a9a);
    final baseShadow = Paint()..color = const Color(0xff666666);
    for (final r in layout.childRects) {
      final cw = r.width;
      final ch = math.max(cw * 0.75, 6.0); // floor at 6 px so it never vanishes
      // Trapezoid sits below the child with its top at r.bottom.
      final topHalfW = cw * 0.75;  // top width = 1.5× child width / 2
      final botHalfW = cw * 1.0;   // bottom width = 2× child width / 2
      final cx = r.center.dx;
      final topY = r.bottom;
      final botY = r.bottom + ch;
      final path = Path()
        ..moveTo(cx - topHalfW, topY)
        ..lineTo(cx + topHalfW, topY)
        ..lineTo(cx + botHalfW, botY)
        ..lineTo(cx - botHalfW, botY)
        ..close();
      canvas.drawPath(path, basePaint);

      // Subtle shadow on the right side so the base reads as a
      // 3-D wedge, matching the lit-from-upper-left convention used
      // elsewhere in the realistic scene.
      final shadowPath = Path()
        ..moveTo(cx, topY)
        ..lineTo(cx + topHalfW, topY)
        ..lineTo(cx + botHalfW, botY)
        ..lineTo(cx, botY)
        ..close();
      canvas.drawPath(shadowPath, baseShadow);
    }
    // Silently consume `size` so the unused-parameter analyzer
    // info doesn't fire. (Other ground-furniture helpers do read
    // `size`; keeping the signature uniform across the dispatch
    // makes the call site straightforward.)
    _consume(size);
  }

  /// Individual-posts rack mount style — each child gets its own
  /// thin wooden post + a small individual earth-berm oval. The
  /// shared foreground mound is suppressed (per [_backdropPainter]'s
  /// `paintMound: false`) so each child's berm reads on its own.
  /// Used by the IDPA Open Stage rack and similar layouts where
  /// each child is "its own target on its own stand" (§6A.3 mount-
  /// style table).
  void _paintIndividualPosts(Canvas canvas, Size size) {
    if (layout.childRects.isEmpty) return;
    final w = size.width;
    final h = size.height;
    // Post: 0.012 W wide (half the single-target post — there are
    // many of them), running from r.bottom down to 0.84 H. Berm:
    // small earth oval centred under each child, width 1.4× child
    // width, height 0.05 H, top at 0.82 H. The bottom 0.02 H of
    // the post is hidden by the berm.
    final postHalfWidth = w * 0.012 * 0.5;
    final postBottomY = h * 0.84;
    final bermTopY = h * 0.82;
    final bermBottomY = h * 0.87;
    final bermColor = lowLightMode
        ? const Color(0xff3d2f1e) // dusk mound brown (matches backdrop)
        : const Color(0xff7d6d58); // daytime mound brown (matches backdrop)
    final bermShadowColor = lowLightMode
        ? const Color(0xff1a1208).withValues(alpha: 0.55)
        : const Color(0xff5d4f3d).withValues(alpha: 0.45);
    final bermOutlinePaint = Paint()
      ..color = (lowLightMode ? const Color(0xff1a1208) : const Color(0xff4a3d2c))
          .withValues(alpha: 0.55)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.0;
    // Pre-allocate paint objects reused per child.
    final postPaint = _polePaint;
    final bermPaint = Paint()..color = bermColor;
    final bermShadowPaint = Paint()..color = bermShadowColor;

    for (final r in layout.childRects) {
      // Berm first (drawn UNDER the post so the post terminates
      // visually inside the dirt). Width = 1.4× child width.
      final cw = r.width;
      final bermHalfW = cw * 0.70;
      final cx = r.center.dx;
      final bermRect = Rect.fromLTRB(
        cx - bermHalfW,
        bermTopY,
        cx + bermHalfW,
        bermBottomY,
      );
      canvas.drawOval(bermRect, bermPaint);
      // Right-side shadow for the lit-from-upper-left look.
      final shadowRect = Rect.fromLTRB(
        cx + (bermRect.right - cx) * (-0.10),
        bermTopY + (bermBottomY - bermTopY) * 0.15,
        cx + bermHalfW,
        bermBottomY,
      );
      canvas.drawOval(shadowRect, bermShadowPaint);
      // Hairline outline on the top half of the berm so it reads
      // distinct from the surrounding grass.
      final topArc = Path()
        ..addArc(bermRect, math.pi, math.pi);
      canvas.drawPath(topArc, bermOutlinePaint);

      // Post: terminates at 0.84H (above the berm bottom at 0.87H)
      // so the post visibly sinks into the dirt. Skip if degenerate.
      if (r.bottom >= postBottomY) continue;
      final postRect = Rect.fromLTRB(
        cx - postHalfWidth,
        r.bottom,
        cx + postHalfWidth,
        postBottomY,
      );
      canvas.drawRect(postRect, postPaint);
    }
  }

  /// Throwaway helper: silently consume an argument so the analyzer
  /// doesn't flag an unused-parameter info. Cheaper than a per-method
  /// `// ignore: unused_local_variable` comment and keeps the dispatch
  /// signatures uniform.
  void _consume(Object? _) {}

  void _paintTargetSilhouette(
    Canvas canvas,
    Rect rect, {
    required bool isActive,
    required String shape,
  }) {
    // Mutate the cached paint objects' alpha + stroke width per call
    // instead of allocating new paints. Active child = full opacity +
    // [kRackActiveStrokeWidth]px outline. Inactive = 70% opacity +
    // [kRackInactiveStrokeWidth]px outline. Per §6A.3 of the v2.3
    // brief the active child renders with a 50% thicker stroke so
    // it visually pops vs the other children in a rack — the two
    // constants live at the top of this file and are also asserted
    // in `test/rack_rendering_test.dart`. The single-target mode
    // always renders with `isActive: true` because there's nothing
    // for it NOT to be active relative to; the single target picks
    // up the same thicker stroke, which reads as a subtle weight
    // bump and is acceptable.
    final fillAlpha = isActive ? 1.0 : 0.70;
    final outlineWidth =
        isActive ? kRackActiveStrokeWidth : kRackInactiveStrokeWidth;
    // The override only paints the ACTIVE target (single or active
    // rack child). Inactive rack children keep the cream default so
    // the user's color choice doesn't leak across the whole rack.
    if (isActive && colorHexOverride != null) {
      // Inline-parse the override hex (e.g. `#cc1f1f`). The other
      // painter has a `_parseColor` helper; not worth promoting it
      // to a top-level function for one call site.
      final raw = colorHexOverride!.startsWith('#')
          ? colorHexOverride!.substring(1)
          : colorHexOverride!;
      final v = int.tryParse(raw, radix: 16) ?? 0xf2efe6;
      final base = Color(0xff000000 | v);
      _targetFillPaint.color = base.withValues(alpha: fillAlpha);
    } else {
      _targetFillPaint.color = Color.fromRGBO(0xf2, 0xef, 0xe6,
          fillAlpha);
    }
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
    // Delegate to the standalone `buildIpscPath(rect)` helper. Keeping
    // the geometry in a top-level function means the same path used
    // by the realistic painter is testable in isolation (regression
    // fixture in `test/ipsc_path_test.dart` asserts the path always
    // fits inside its bounds for 10 different aspect ratios — see
    // §6.2.6 acceptance test #1 in the v2.3 brief).
    final path = buildIpscPath(rect);
    canvas.drawPath(path, _targetFillPaint);
    canvas.drawPath(path, _targetOutlinePaint);
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
    if (old.colorHexOverride != colorHexOverride) return true;
    if (old.lowLightMode != lowLightMode) return true;
    if (old.rackMountStyle != rackMountStyle) return true;
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
    this.colorHexOverride,
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
  /// User-selected color override hex (e.g. `'#cc1f1f'`). When non-null,
  /// substitutes for `target.colorHex` at fill time. See `TargetPlot`'s
  /// constructor doc for full semantics.
  final String? colorHexOverride;

  @override
  void paint(Canvas canvas, Size size) {
    // Background plate so the target stands out against any theme.
    // Always covers the FULL outer box (including the realistic-mode
    // gutter) so there's no flicker between modes.
    canvas.drawRect(
      Offset.zero & size,
      Paint()..color = backgroundColor,
    );

    final fill = Paint()
      ..color = _parseColor(colorHexOverride ?? target.colorHex);
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
    if (old.colorHexOverride != colorHexOverride) return true;
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
