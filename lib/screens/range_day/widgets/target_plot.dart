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
import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';

import '../../../data/reticle_library.dart';
import '../../../database/database.dart';
import '../../../models/target_center_point.dart';
import '../../../models/visual_style.dart';
import '../../../widgets/animal_silhouettes.dart';
import '../../../widgets/reticle_renderer.dart';
import '../../../widgets/scope_daytime_backdrop.dart';
import '../../../widgets/target_silhouettes.dart';
import 'scene_input.dart';

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
///
/// Phase 9.5 — [category] gates which SVG helper to dispatch to:
///   * `ipsc`   → `TargetSilhouettes['ipsc']`
///   * `animal` → `AnimalSilhouettes[shapeId]` (shapeId = species)
///   * `special` + `shapeId == 'pepper_popper'` → TargetSilhouettes
///   * anything else (`circle` / `square` / `rectangle` /
///     `special` + `texas_star`) → null; caller renders procedurally
/// Phase 9.8.B — top-level rack slot rect computation. Both the
/// realistic painter ([_RealisticScenePainter._paintRack]) AND the
/// gesture handler ([TargetPlot._handleTap] for rack mode) need
/// slot rects in the SAME canvas coordinates, otherwise the user
/// taps a visible slot and the hit test thinks they tapped
/// elsewhere. Co-locating the rect math in one place removes the
/// divergence risk.
///
/// Returns per-slot rects anchored per [rack.mountStructure]:
///   * `hanging_rail` — top edge below the rail (rail at
///     `horizonY - canvas_h * 0.18`, slot top at `rail_y + 6 + 4 *
///     inPerPx`).
///   * `standing_stake` — bottom edge at the top of the stake
///     (stake height = `slot.heightIn * 1.5 * inPerPx`).
///   * `popper_base` — bottom edge at `horizonY - baseHeight`
///     (base height = `max(slot.widthIn * inPerPx * 0.75, 6 px)`;
///     base trapezoid renders between slot bottom and horizon).
///   * `silhouette_stand` — bottom edge at `horizonY`
///     (silhouette is ground-anchored; stake renders BEHIND it).
///
/// Horizontal: each slot's center is `canvasCenterX +
/// slot.offsetXFromCenterIn * inPerPx`. Phase 9.6 catalog ships
/// pre-computed `x_offset_in` per slot.
///
/// Overflow guard: if natural span exceeds canvas width minus an
/// 8 px margin, every slot's horizontal position scales uniformly
/// to fit. (Currently unused at default canvas sizes.)
List<Rect> computeRackSlotRects(
  Size canvas,
  RackSpec rack, {
  double horizonFrac = 0.75,
  double inchesPerCanvasHeight = 150.0,
}) {
  if (rack.slots.isEmpty) return const [];
  final w = canvas.width;
  final h = canvas.height;
  final inPerPx = h / inchesPerCanvasHeight;
  final horizonY = horizonFrac * h;
  final canvasCenterX = w / 2;
  final natural = <Rect>[];
  for (final slot in rack.slots) {
    final slotW = slot.widthIn * inPerPx;
    final slotH = slot.heightIn * inPerPx;
    final slotCenterX =
        canvasCenterX + slot.offsetXFromCenterIn * inPerPx;
    double slotCenterY;
    switch (rack.mountStructure) {
      case 'standing_stake':
        final stakeHeight = slot.heightIn * 1.5 * inPerPx;
        final slotBottomY = horizonY - stakeHeight;
        slotCenterY = slotBottomY - slotH / 2;
        break;
      case 'hanging_rail':
        final railY = horizonY - w * 0.18;
        final slotTopY = railY + 6 + 4 * inPerPx;
        slotCenterY = slotTopY + slotH / 2;
        break;
      case 'popper_base':
        final baseHeight = math.max(slotW * 0.75, 6.0);
        final slotBottomY = horizonY - baseHeight;
        slotCenterY = slotBottomY - slotH / 2;
        break;
      case 'silhouette_stand':
      default:
        slotCenterY = horizonY - slotH / 2;
        break;
    }
    natural.add(Rect.fromCenter(
      center: Offset(slotCenterX, slotCenterY),
      width: slotW,
      height: slotH,
    ));
  }
  // Overflow guard — scale uniformly so the rack fits inside the
  // canvas with an 8 px margin per side.
  const margin = 8.0;
  final leftmost = natural.map((r) => r.left).reduce(math.min);
  final rightmost = natural.map((r) => r.right).reduce(math.max);
  final span = rightmost - leftmost;
  final available = w - 2 * margin;
  if (span <= available) {
    return natural;
  }
  final scale = available / span;
  return natural.map((r) {
    final newCenterX =
        canvasCenterX + (r.center.dx - canvasCenterX) * scale;
    return Rect.fromCenter(
      center: Offset(newCenterX, r.center.dy),
      width: r.width,
      height: r.height,
    );
  }).toList();
}

Path? resolveTargetSvgPath(
  Rect bounds,
  String category,
  String? shapeId, {
  double scaleFactor = 1.0,
}) {
  switch (category) {
    case 'ipsc':
      // IPSC catalog rows have shape_id == null; the dispatch key
      // is the category, not the per-row shape_id.
      if (TargetSilhouettes.isTargetShape('ipsc')) {
        return TargetSilhouettes.cachedScaledPath(
          bounds,
          'ipsc',
          scaleFactor: scaleFactor,
        );
      }
      return null;
    case 'animal':
      if (shapeId == null) return null;
      if (AnimalSilhouettes.isAnimalShape(shapeId)) {
        return AnimalSilhouettes.cachedScaledPath(
          bounds,
          shapeId,
          scaleFactor: scaleFactor,
        );
      }
      return null;
    case 'special':
      // texas_star is procedural; pepper_popper has an SVG.
      if (shapeId == 'pepper_popper' &&
          TargetSilhouettes.isTargetShape(shapeId!)) {
        return TargetSilhouettes.cachedScaledPath(
          bounds,
          shapeId,
          scaleFactor: scaleFactor,
        );
      }
      return null;
    default:
      // circle / square / rectangle — procedural, never SVG.
      return null;
  }
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
    required this.category,
    this.shapeId,
    required this.widthIn,
    required this.heightIn,
    required this.colorHex,
    this.centerPoint = TargetCenterPoint.defaultCenter,
    this.svgScaleFactor = 1.0,
  });

  /// Phase 9.5 category-driven taxonomy. Replaces the v38 `shape`
  /// field. Values: `circle` | `square` | `rectangle` | `ipsc` |
  /// `animal` | `special`. Drives chip filtering AND painter
  /// dispatch — see the `_RealisticScenePainter` switch below.
  final String category;

  /// Optional discriminator within a [category]. Carries the
  /// species name for `animal` (e.g. `bear`, `mule_deer`), the
  /// apparatus type for `special` (e.g. `pepper_popper`,
  /// `texas_star`), and null for everything else.
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
  /// 18 in × 30 in white IPSC silhouette. This matches the canonical
  /// IPSC (USPSA Metric) competition cardboard target so a fresh
  /// user opening Range Day sees a recognizable, distance-relevant
  /// target. They can swap to any other catalog target via the
  /// picker.
  factory TargetSpec.defaultPaper() => const TargetSpec(
        category: 'ipsc',
        widthIn: 18,
        heightIn: 30,
        colorHex: '#ffffff',
      );

  factory TargetSpec.fromRow(TargetRow row) => TargetSpec(
        category: row.category,
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
/// derive it from its `RackSlot` (v40+) without dragging the drift
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
    required this.category,
    required this.offsetXFromCenterIn,
    this.shapeId,
    this.colorHex = '#ffffff',
  });

  /// Plate / popper / silhouette width in inches.
  final double widthIn;

  /// Plate / popper / silhouette height in inches.
  final double heightIn;

  /// Phase 9.5 — `circle | square | rectangle | ipsc | animal |
  /// special`. Matches the [TargetSpec.category] vocabulary so the
  /// rack painter's dispatch can share helpers with the single-target
  /// painter. Renamed from the v38 `shape` field — `silhouette` from
  /// the legacy vocabulary mapped to `ipsc` here, and `popper` / `star`
  /// mapped to `special` (with `shapeId` carrying the specific apparatus).
  final String category;

  /// Phase 9.5 — optional SVG dispatch key. Populated for
  /// `special`-category apparatus (`pepper_popper`, `texas_star`) so the
  /// painter can route to the right shape. `circle` / `square` /
  /// `rectangle` slots leave it null.
  final String? shapeId;

  /// X offset from the rack's geometric center, in inches. Positive =
  /// right, negative = left. Used to lay out children horizontally
  /// under the cross-bar.
  final double offsetXFromCenterIn;

  /// CSS-style hex color, e.g. "#ffffff". Defaults to white.
  final String colorHex;
}

/// Top-level outline-stroke width for the ACTIVE rack child / single-
/// target silhouette in realistic mode. Exposed at top level so the
/// `test/rack_rendering_test.dart` regression can assert the ratio
/// against [kRackInactiveStrokeWidth] without breaking when the
/// painter internals are refactored.
///
/// Phase 9.6 Group E.5 — tightened from 2.5 to 2.0 to match the
/// Phase 9.6 spec's explicit "2px black stroke" for the active rack
/// slot. The v2.3 brief had originally illustrated 2.5px as an
/// example; Phase 9.6 fixes the exact value. The active stroke is
/// also pure black (`#000000`) rather than the near-black 0x1a1a1a
/// used for inactive plates, so the active highlight pops against
/// the cream plate fill.
const double kRackActiveStrokeWidth = 2.0;

/// Companion to [kRackActiveStrokeWidth]: outline-stroke width for
/// NON-active rack children. Same rationale as the active constant.
const double kRackInactiveStrokeWidth = 1.0;

class TargetPlot extends StatelessWidget {
  const TargetPlot({
    super.key,
    required this.target,
    required this.shots,
    required this.onTapAt,
    required this.onLongPressShot,
    this.onActiveRackSlotChange,
    this.onLongPress,
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
    this.sizeFloorEnabled = true,
    this.visualStyle = VisualStyle.cartoon,
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

  /// Phase 9.8.B — fired when the user taps a non-active slot in
  /// rack mode. Parent screen wires this to its
  /// `_selectedRackChildPosition` setter so the tapped slot becomes
  /// active. Null = tap-to-activate disabled (single-target mode or
  /// caller doesn't want this behaviour). The chip row above the
  /// scene continues to work regardless — tap-to-activate is an
  /// additional affordance, not a replacement.
  final void Function(int newActiveSlotIndex)? onActiveRackSlotChange;

  /// Phase 9.8.B.4 — fired when the user long-presses the rendered
  /// scene at a point that DOESN'T land on a recorded shot dot.
  /// Picker preview surfaces wire this to the enlarge-zoom dialog
  /// (long-press the small inline preview → open the full-screen
  /// view). The Range Day workspace passes null because it doesn't
  /// have an enlarge dialog AND its long-press is reserved for
  /// shot-edit interactions via [onLongPressShot]. Shot-edit
  /// behaviour still takes precedence — a long-press that lands
  /// near a shot dot fires [onLongPressShot] and skips this
  /// fallback.
  final VoidCallback? onLongPress;

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

  /// Phase 8 Group B — pass-through for `_RealisticScenePainter`'s
  /// `sizeFloorEnabled`. When true, targets smaller than 4" are
  /// scaled up uniformly so they remain visible at the new
  /// physical-dim sizing. Default true; user-toggleable via the
  /// Range Day picker's "Enlarge small targets" switch.
  /// Has no effect outside realistic mode.
  final bool sizeFloorEnabled;

  /// Phase 10 Group B.3 — pass-through for `_RealisticScenePainter`'s
  /// `visualStyle`. Defaults to `VisualStyle.cartoon` so non-Range-
  /// Day callers (preview thumbnails, dialog widgets) that don't
  /// have a notifier on hand still compile. Range Day call sites
  /// pass `context.watch<VisualStyleNotifier>().style` so the
  /// painter sees the user's current choice and the scene
  /// repaints when they flip modes via Settings or the AppBar
  /// toggle. Group A introduced the field on the painter; Group C
  /// + later light up the actual rendering branches.
  final VisualStyle visualStyle;

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
          // Phase 9.8.B — when in rack mode AND
          // [onActiveRackSlotChange] is wired up AND the user taps a
          // non-active slot, fire the callback to make that slot
          // active. Falls through to the regular `_handleTap` for
          // taps that don't hit any slot (e.g. tapping the sky or
          // the grass) and for taps inside the already-active slot.
          // Single-target mode bypasses this entirely.
          final rackSlotRects = layout.isRack && rackChildren != null
              ? computeRackSlotRects(
                  outerSize,
                  RackSpec(
                    mountStructure: rackMountStyle ?? 'hanging_rail',
                    slots: rackChildren!,
                  ),
                )
              : const <Rect>[];
          return GestureDetector(
            onTapDown: (details) {
              if (onActiveRackSlotChange != null &&
                  rackSlotRects.isNotEmpty) {
                final activeIdx = activeRackChildIndex ?? 0;
                for (var i = 0; i < rackSlotRects.length; i++) {
                  if (i == activeIdx) continue;
                  if (rackSlotRects[i].contains(details.localPosition)) {
                    onActiveRackSlotChange!(i);
                    return;
                  }
                }
              }
              _handleTap(details.localPosition, targetRect);
            },
            onLongPressStart: (details) =>
                _handleLongPress(details.localPosition, targetRect),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: Stack(
                children: [
                  if (viewMode == TargetPlotViewMode.realistic)
                    CustomPaint(
                      size: outerSize,
                      // Phase 9.7 Group D — both modes go through the
                      // unified [_RealisticScenePainter] via the
                      // sealed-type [SceneInput] API. Rack mode
                      // constructs a [RackScene] with the active
                      // slot index; single mode constructs a
                      // [SingleTargetScene] with the existing target.
                      // The pre-9.7 legacy rack painter has been
                      // deleted in Group D; this is the only painter.
                      painter: _RealisticScenePainter(
                        sceneInput: layout.isRack && rackChildren != null
                            ? RackScene(
                                rack: RackSpec(
                                  mountStructure: rackMountStyle ??
                                      'hanging_rail',
                                  slots: rackChildren!,
                                ),
                                activeSlotIndex:
                                    activeRackChildIndex ?? 0,
                              )
                            : SingleTargetScene(target: target),
                        colorHexOverride: colorHexOverride,
                        sizeFloorEnabled: sizeFloorEnabled,
                        // Phase 10 Group B.3 — the visual style flows
                        // down from the parent widget. Range Day call
                        // sites pass `context.watch<VisualStyleNotifier>().style`
                        // so the painter repaints when the user
                        // flips the Settings segment or the AppBar
                        // toggle (the notifier's
                        // `notifyListeners()` triggers a rebuild on
                        // the watching screen, which rebuilds
                        // TargetPlot, which reconstructs the painter
                        // with the new style; `shouldRepaint`
                        // (updated in Group A) sees the diff and
                        // repaints).
                        visualStyle: visualStyle,
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
    if (norm == null) {
      // Long-press landed OUTSIDE the target rectangle (gutter /
      // framing). Fire the surface-level [onLongPress] fallback if
      // wired — used by the picker preview to surface the
      // enlarge-zoom dialog.
      onLongPress?.call();
      return;
    }
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
    // Touch slop ~ 8% of target width — generous for gloved range use.
    if (closest != null && closestDist2 < 0.08 * 0.08) {
      onLongPressShot(closest);
      return;
    }
    // Phase 9.8.B.4 — no shot near the long-press location. Fire the
    // surface-level [onLongPress] fallback if wired. Picker preview
    // surfaces use this to open the enlarge dialog; the Range Day
    // workspace passes null (the workspace doesn't have an enlarge
    // dialog).
    onLongPress?.call();
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
///
/// Phase 9.7 — handles BOTH single-target and rack-mode rendering
/// via the sealed-type [SceneInput] dispatch. Single mode runs the
/// [_paintSingle] branch (pole + mound + grass-tufts rig); rack mode
/// runs [_paintRack] (mount-structure rig + multi-slot scene). The
/// pre-9.7 legacy `_RealisticTargetPainter` class was deleted in
/// Group D — this is the only realistic-mode painter now.
class _RealisticScenePainter extends CustomPainter {
  _RealisticScenePainter({
    required this.sceneInput,
    this.colorHexOverride,
    this.sizeFloorEnabled = true,
    this.visualStyle = VisualStyle.cartoon,
  });

  /// Phase 9.7 Group B — painter input is now a [SceneInput] sealed
  /// type. `SingleTargetScene` runs the existing single-target code
  /// path verbatim (pixel parity gate against `b60f9e9`). `RackScene`
  /// throws [UnimplementedError] in Group B; Group C lands the
  /// `_paintRack` branch with mount-structure dispatch + multi-slot
  /// rendering.
  final SceneInput sceneInput;

  /// Phase 10 Group A — user-controlled visual style. `cartoon`
  /// (default) renders the existing procedural scene unchanged.
  /// `polished` and `photo` will light up atmospheric effects in
  /// Group C and later (saveLayer scaffold, DOF blur, ground haze,
  /// drop shadow, color grade, vignette, film grain). In Group A
  /// the field exists but is unused — the paint pass is identical
  /// for all three values until Group C lands.
  ///
  /// Photo mode aliases to polished at the dispatch site (Phase 12 /
  /// 13 will light up photo's own rendering); the enum preserves
  /// the user's actual selection so future phases don't need a
  /// migration.
  final VisualStyle visualStyle;

  /// Phase 10 Group C.1 / Group D — single source of truth for the
  /// photo→polished alias. Every effect dispatch inside this painter
  /// reads `_effectiveStyle`, not `visualStyle`, so the alias is
  /// enforced in exactly one place. When Phase 12 / 13 light up
  /// photo's own rendering, the `photo => polished` arm flips to
  /// `photo => photo` and every downstream branch picks it up for
  /// free.
  ///
  /// Returns `cartoon` when the user picked cartoon; otherwise
  /// `polished` (covers both `polished` and `photo` until Phase 12).
  VisualStyle get _effectiveStyle => switch (visualStyle) {
        VisualStyle.cartoon => VisualStyle.cartoon,
        VisualStyle.polished => VisualStyle.polished,
        VisualStyle.photo => VisualStyle.polished,
      };

  /// The focus target (the geometry that drives aim / shots / scope
  /// ring anchoring + the single-target paint body's box-sizing). For
  /// `SingleTargetScene` this is the scene's own target. For
  /// `RackScene` this is the active slot's geometry, projected into a
  /// transient `TargetSpec`.
  ///
  /// Phase 9.7 Group B — kept as a getter named `target` (not
  /// `_focusTarget`) so the ~20 existing `target.x` references inside
  /// the painter's helpers (`_drawSpecial`, `_paintTarget`,
  /// `shouldRepaint`, etc.) continue to compile without per-call-site
  /// rewrites. The pre-9.7 implementation stored `target` as a
  /// constructor field; the 9.7 implementation derives it from the
  /// scene input. Same call site, different storage shape.
  ///
  /// The clamp on `activeSlotIndex` is defensive — a stale Range Day
  /// session row pointing at a slot that no longer exists falls back
  /// to the first slot rather than throwing.
  TargetSpec get target => switch (sceneInput) {
        SingleTargetScene(:final target) => target,
        RackScene(:final rack, :final activeSlotIndex) => () {
            final i = activeSlotIndex.clamp(0, rack.slots.length - 1);
            final s = rack.slots[i];
            return TargetSpec(
              category: s.category,
              shapeId: s.shapeId,
              widthIn: s.widthIn,
              heightIn: s.heightIn,
              colorHex: s.colorHex,
            );
          }(),
      };

  final String? colorHexOverride;

  /// Phase 8 Group B — when true, targets smaller than
  /// `_minVisibleSizeInches` (4") scale up uniformly so the smaller
  /// dimension hits the floor. Keeps tiny targets visible at the
  /// new physical-dim sizing. Default true; user can flip via the
  /// Range Day picker's "Enlarge small targets" switch.
  final bool sizeFloorEnabled;

  // ── Layout constants ─────────────────────────────────────────────
  /// Horizon position: sky/grass boundary as a fraction of canvas H.
  /// Tuned to 0.75 (was 0.70 in Phase 4) — more sky overhead at the
  /// new target position gives a sense of "looking up at the target"
  /// rather than the target sitting flat on a wide grass strip.
  static const double _horizonFrac = 0.75;
  /// Reference scale denominator: 1 inch = H / _inchesPerCanvasHeight px.
  /// Phase 8 tuned 200 → 150 — the canvas now represents a ~150"
  /// vertical field-of-view, balancing the smaller new "physical
  /// dimensions" target rendering (a 60" bear is ~30% canvas height,
  /// not 40%) against still seeing the full target + scene at a
  /// glance. Earlier values: 300 (Phase 1), 200 (Phase 4), 150 (Phase 8).
  static const double _inchesPerCanvasHeight = 150.0;
  /// Visible pole stub height as a fraction of the target's rendered
  /// height. Phase 6 set this to 0.25; Phase 8 keeps it but the
  /// target height is now derived from physical dimensions rather
  /// than a fixed box fraction.
  static const double _visiblePoleFracOfTarget = 0.25;
  /// Phase 8 Group B — floor for the smaller physical dimension.
  /// When `sizeFloorEnabled` is true (the default, user-facing
  /// "Enlarge small targets" switch), any target whose smaller
  /// dimension is below this value is uniformly scaled UP so the
  /// smaller dimension hits the floor. Without this, a 1" patch
  /// would render at ~1.5 px on a 234-tall preview — essentially
  /// invisible. With the floor it's clamped to a 4"-equivalent
  /// size (~6 px at 234-tall), which is small but visible.
  /// Toggle OFF gives realistic-scale rendering.
  static const double _minVisibleSizeInches = 4.0;

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
  /// Phase 9 Group C.4 — canvas-h-relative (was target-box-relative).
  /// Phase 7a originally tied the tree to `targetBoxH` because the box
  /// was a fixed 0.40 × canvas height; that math implicitly made it
  /// canvas-h-relative. Phase 8's physical-dim sizing made the target
  /// box variable, so a 1" circle would render with a tiny tree and
  /// a 120" moose with an oversized tree. 0.30 × canvas H matches
  /// the Phase 7a visual at the typical Phase-7-target size; the tree
  /// stays the same size across all targets now.
  static const double _treeHeightFracOfCanvas = 0.30;
  static const double _treeXFracOfCanvas = 0.85;
  static const Color _treeTrunkColor = Color(0xff5c3a1e); // dark brown
  static const Color _treeCrownColor = Color(0xff4a6a2f); // dark conifer green

  @override
  void paint(Canvas canvas, Size size) {
    if (size.width <= 0 || size.height <= 0) return;

    // Phase 10 Group C.1 — photo mode aliases to polished via the
    // `_effectiveStyle` getter (single source of truth). Every
    // downstream conditional in this painter reads the getter so
    // the alias is enforced in exactly one place.

    // Phase 10 Group C.2 — saveLayer scaffold for polished + photo.
    // Group F will hang the color-grade / vignette / grain compositing
    // off the restore of this layer; Group D + E add intermediate
    // layers between this open and restore. For Group C the scaffold
    // is intentionally a no-op: open the layer with a default Paint(),
    // run the existing paint pass unchanged, restore. The cartoon
    // path is byte-identical because the if-guard skips the saveLayer
    // entirely. Polished + photo render through one extra layer; with
    // a default Paint() that layer is a straight passthrough, so the
    // visible output is identical until Group D lights up effects.
    final usePolishedLayer = _effectiveStyle != VisualStyle.cartoon;
    if (usePolishedLayer) {
      canvas.saveLayer(Offset.zero & size, Paint());
    }

    // Phase 9.7 — sealed-type dispatch. Single-target rendering runs
    // the verbatim Phase 9.6 body via [_paintSingle] (pixel-parity
    // gate against `b60f9e9` was Group B). Rack rendering runs
    // [_paintRack] (mount-structure rig + multi-slot scene; landed
    // in Group C + Group C.1/C.2 hotfixes). The pre-9.7 legacy rack
    // painter was deleted in Group D — this dispatch is now the
    // single source of truth for realistic-mode rendering.
    switch (sceneInput) {
      case SingleTargetScene():
        _paintSingle(canvas, size);
      case RackScene(:final rack, :final activeSlotIndex):
        _paintRack(canvas, size, rack, activeSlotIndex);
    }

    if (usePolishedLayer) {
      // Group F lands color-grade + vignette + film-grain
      // composites here, between the scene paint and the restore.
      // Group C ships the restore as a no-op so the scaffold is
      // visually inert (the saveLayer with a default Paint draws
      // straight through on restore).
      canvas.restore();
    }
  }

  /// Phase 9.7 Group B extraction — the verbatim Phase 9.6 paint()
  /// body. Single-target rendering path. Pixel-parity gate against
  /// `b60f9e9`. The body reads `target.x` against the painter's
  /// derived `target` getter (which returns the focus target from the
  /// scene input); for `SingleTargetScene` the getter just unwraps
  /// the scene's target, so behaviour is identical to the pre-9.7
  /// `final TargetSpec target` field.
  void _paintSingle(Canvas canvas, Size size) {
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

    // Phase 8 Group B — target box derived from PHYSICAL dimensions
    // (widthIn / heightIn ÷ inPerPx) rather than a fixed canvas
    // fraction. A 1" patch renders ~1.5px; a 60" bear renders
    // ~94px-wide at H=234. The natural aspect ratio is preserved
    // automatically because both dimensions come from the same
    // catalog row.
    //
    // Pre-Phase-8 box-sizing constants (_targetBoxWidthFrac,
    // _targetBoxHeightFrac) were retired — the inch-driven sizing
    // makes them irrelevant.
    double effWIn = target.widthIn;
    double effHIn = target.heightIn;

    // Min-size floor: when `sizeFloorEnabled` (default true), scale
    // up uniformly so the smaller dimension hits the floor.
    // Preserves natural aspect so a 1" circle still renders round.
    // Floor is currently 4" → ~6px on a 234-tall preview.
    if (sizeFloorEnabled) {
      final smaller =
          effWIn < effHIn ? effWIn : effHIn;
      if (smaller > 0 && smaller < _minVisibleSizeInches) {
        final scale = _minVisibleSizeInches / smaller;
        effWIn *= scale;
        effHIn *= scale;
      }
    }

    // `inPerPx` is misnamed — it's actually PIXELS PER INCH
    // (h / inchesPerCanvasHeight). Existing scenery callers
    // (`18.0 * inPerPx` for mound height, etc.) rely on this
    // semantic. New box-sizing follows the same pattern:
    // pixels = inches × (pixels/inch).
    final targetW = effWIn * inPerPx;
    final targetH = effHIn * inPerPx;

    // Phase 9.5 — discriminator simplified to `category == 'animal'`
    // (was: shape == 'silhouette' && shape_id != null && shape_id !=
    // 'ipsc'). The category field cleanly separates animals from
    // IPSC silhouettes; the pole/mound rendering skips for animals
    // only. cp.verticalFromTop is IGNORED for animals — only
    // horizontal matters because the bottom is fixed at horizonY.
    final isGroundStanding = target.category == 'animal';

    final cp = target.centerPoint;
    final poleX = w / 2;
    final Rect targetRect;
    final double visiblePoleHeight;
    final double visualPoleTopY;
    final double visualPoleHeight;

    if (isGroundStanding) {
      // Animal: feet at horizonY; silhouette extends UP into the
      // sky region. horizontal_from_left positions the silhouette's
      // anchor point at canvas center (poleX), so a left-facing
      // animal at 0.6 has its mid-body roughly centered.
      final targetBottom = horizonY;
      final targetTop = targetBottom - targetH;
      final targetLeft = poleX - cp.horizontalFromLeft * targetW;
      targetRect = Rect.fromLTWH(targetLeft, targetTop, targetW, targetH);
      // No pole rendering — initialise to harmless defaults so
      // any consumer (just `visualPoleHeight` for now) doesn't
      // dereference uninitialised values. The non-animal branch
      // below paints the pole; we skip it.
      visiblePoleHeight = 0;
      visualPoleTopY = horizonY;
      visualPoleHeight = 0;
    } else {
      // Phase 8 Group A inversion (unchanged for non-animals):
      // pole FIXED at canvas center; target rect solved backwards
      // from cp + the pole anchors.
      visiblePoleHeight = targetH * _visiblePoleFracOfTarget;
      visualPoleTopY = moundApexY - visiblePoleHeight - 0.5 * targetH;
      final targetLeft = poleX - cp.horizontalFromLeft * targetW;
      final targetTop = visualPoleTopY - cp.verticalFromTop * targetH;
      targetRect =
          Rect.fromLTWH(targetLeft, targetTop, targetW, targetH);
      visualPoleHeight = moundApexY - visualPoleTopY;
    }

    // Paint order — animals get backdrop → TARGET (no mound, no
    // pole, no pole-base ring, no horizon tufts). Non-animals keep
    // the full Phase 8 order with mound + pole + tufts + base ring.
    //
    // Phase 10 Group D — the backdrop pass (sky + distant hills +
    // treeline + grass + tall grass + foreground tree) is funneled
    // through [_paintBackdrop], which in polished/photo mode wraps
    // the distant pair in a `saveLayer(blur σ=1.5)` and emits a
    // ground-haze gradient band over the horizon afterward. Cartoon
    // mode is byte-identical — the helper's polished guards are
    // skipped.
    _paintBackdrop(canvas, size, horizonY, inPerPx);
    if (!isGroundStanding) {
      _paintMound(canvas, w, horizonY, inPerPx);
      _paintPole(canvas, poleX, visualPoleTopY, visualPoleHeight,
          visiblePoleHeight);
      _paintGrassTufts(canvas, w, horizonY, inPerPx);
      _paintPoleBaseRing(canvas, poleX, moundApexY, visiblePoleHeight);
    }
    _paintTarget(canvas, targetRect);
  }

  /// Phase 10 Group D — shared backdrop pass for the single-target
  /// and rack scenes. Used to be six inline calls in each of
  /// [_paintSingle] / [_paintRack]; centralising the sequence here
  /// keeps the polished-mode effects in one place and prevents the
  /// two paths from drifting.
  ///
  /// Paint order (top of scene → front of scene):
  ///   1. Sky gradient — always cartoon, no blur (a blur on the
  ///      sky would smudge the horizon line we anchor the ground
  ///      haze to).
  ///   2. Distant hills + treeline — cartoon in [VisualStyle.cartoon];
  ///      wrapped in a `saveLayer(blur σ=1.5)` in polished/photo so
  ///      the far field reads as atmospheric depth rather than
  ///      crisp silhouettes.
  ///   3. Grass + tall grass + foreground tree — always cartoon, no
  ///      blur. These are the FOREGROUND backdrop helpers per the
  ///      Phase 10 spec; they have to stay sharp so the DOF effect
  ///      reads as "near vs far," not "everything's blurred."
  ///   4. Ground haze — a horizontal gradient band painted over the
  ///      horizon line in polished/photo only. White, alpha 0 at the
  ///      top edge and alpha 0.18 at the bottom edge (spec §Effect-
  ///      specifications ground haze), srcOver, anchored
  ///      `horizon_y - 0.06 H` to `horizon_y + 0.01 H`. Visual goal:
  ///      atmospheric perspective; the horizon feels softened by
  ///      distance haze.
  ///
  /// The DOF blur σ=1.5 and the haze alpha 0.18 are the spec's
  /// starting parameters used verbatim — no aesthetic invention.
  /// Both can be tuned in a follow-up if cold-restart QA finds
  /// them too strong or too weak; per the Phase 10 spec the haze
  /// alpha range to consider is 0.15-0.25.
  void _paintBackdrop(
    Canvas canvas,
    Size size,
    double horizonY,
    double inPerPx,
  ) {
    final w = size.width;
    final h = size.height;
    final polish = _effectiveStyle != VisualStyle.cartoon;

    // 1. Sky — outside any blur layer so the horizon line is crisp.
    _paintSky(canvas, w, h, horizonY);

    // 2. Distant backdrop — wrapped in a blur saveLayer in
    //    polished/photo. The saveLayer is INSIDE the outer
    //    polished-mode wrap (opened in [paint]) so Group F's color
    //    grade still applies to the blurred output.
    if (polish) {
      canvas.saveLayer(
        Offset.zero & size,
        Paint()..imageFilter = ImageFilter.blur(sigmaX: 1.5, sigmaY: 1.5),
      );
    }
    _paintDistantHills(canvas, w, horizonY);
    _paintTreeline(canvas, w, horizonY);
    if (polish) {
      canvas.restore();
    }

    // 3. Foreground backdrop — sharp in every mode.
    _paintGrass(canvas, w, h, horizonY);
    _paintTallGrass(canvas, w, h, horizonY, inPerPx);
    _paintForegroundTree(canvas, w, h, horizonY);

    // 4. Ground haze — polished/photo only. Painted AFTER the
    //    foreground backdrop so grass / tall grass / tree along
    //    the horizon are washed by the gradient (consistent
    //    atmospheric perspective). Painted BEFORE the mid-scene
    //    content (mound, pole, target/slots, mount rig) so those
    //    elements appear in front of the haze, anchored visually
    //    to the foreground.
    if (polish) {
      _paintGroundHaze(canvas, size, horizonY);
    }
  }

  /// Phase 10 Group D — horizontal white gradient band that softens
  /// the horizon in polished/photo mode. Spec §Effect-specifications
  /// ground haze, parameters used verbatim:
  ///
  ///   * Top edge:     horizon_y − canvas_h × 0.06
  ///   * Bottom edge:  horizon_y + canvas_h × 0.01
  ///   * Top alpha:    0.0 (transparent)
  ///   * Bottom alpha: 0.18 (subtle white wash)
  ///   * Color:        Colors.white
  ///   * Blend mode:   srcOver (default; we don't set it explicitly)
  ///
  /// The band straddles the horizon with the bulk above it (~7%
  /// of canvas height above vs 1% below) so the wash falls on the
  /// distant elements rather than the grass field. Painted with a
  /// LinearGradient (top → bottom alpha) inside a `drawRect` rather
  /// than a saveLayer-with-filter approach, because we want the
  /// haze to COMPOSITE OVER existing content, not transform a
  /// captured layer.
  ///
  /// Visual goal: atmospheric perspective. Strength is tunable in
  /// the 0.15-0.25 alpha range per spec; surface in the Group D
  /// report if cold-restart QA wants an adjustment.
  void _paintGroundHaze(Canvas canvas, Size size, double horizonY) {
    final w = size.width;
    final h = size.height;
    final topY = horizonY - h * 0.06;
    final bottomY = horizonY + h * 0.01;
    final rect = Rect.fromLTRB(0, topY, w, bottomY);
    final paint = Paint()
      ..shader = LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [
          Colors.white.withValues(alpha: 0.0),
          Colors.white.withValues(alpha: 0.18),
        ],
      ).createShader(rect);
    canvas.drawRect(rect, paint);
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
    double h,
    double horizonY,
  ) {
    // Phase 9 Group C.4 — was `targetBoxH * _treeHeightFracOfTarget`
    // (target-relative). That coupling produced tiny trees for small
    // targets and giant trees for large ones after Phase 8's
    // physical-dim sizing. Now `h * _treeHeightFracOfCanvas` —
    // canvas-relative, invariant across target sizes.
    final treeHeight = h * _treeHeightFracOfCanvas;
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

  /// Single-target draw. Reads the painter's derived [target] getter
  /// (single-target rendering path). For rack-mode slot rendering see
  /// [_drawCategoryShape] below — same dispatch logic but with
  /// caller-supplied spec and paints.
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
    _drawCategoryShape(canvas, rect, target, fillPaint, outlinePaint);
  }

  /// Phase 9.5 — category-driven shape dispatch. SVG-capable
  /// categories (`ipsc`, `animal`) try the SVG path first via
  /// [resolveTargetSvgPath]; procedural categories (`circle`,
  /// `square`, `rectangle`) draw directly; `special` routes by
  /// `shape_id` sub-discriminator (pepper_popper, texas_star).
  ///
  /// Phase 9.7 Group C extraction — the dispatch was inline in
  /// `_paintTarget`. Pulled out so rack-mode slot rendering can
  /// reuse the SAME category dispatch with per-slot fill / outline
  /// paints, without going through the painter's `target` getter
  /// (which is tied to the active slot for [RackScene]).
  void _drawCategoryShape(
    Canvas canvas,
    Rect rect,
    TargetSpec spec,
    Paint fillPaint,
    Paint outlinePaint,
  ) {
    final svgPath = resolveTargetSvgPath(
      rect,
      spec.category,
      spec.shapeId,
      scaleFactor: spec.svgScaleFactor,
    );
    if (svgPath != null) {
      canvas.drawPath(svgPath, fillPaint);
      canvas.drawPath(svgPath, outlinePaint);
      return;
    }

    switch (spec.category) {
      case 'circle':
        final r = rect.shortestSide / 2;
        canvas.drawCircle(rect.center, r, fillPaint);
        canvas.drawCircle(rect.center, r, outlinePaint);
        break;
      case 'ipsc':
        final ipsc = buildIpscPath(rect);
        canvas.drawPath(ipsc, fillPaint);
        canvas.drawPath(ipsc, outlinePaint);
        break;
      case 'special':
        _drawSpecial(canvas, rect, fillPaint, outlinePaint, spec.shapeId);
        break;
      case 'square':
      case 'rectangle':
      default:
        canvas.drawRect(rect, fillPaint);
        canvas.drawRect(rect, outlinePaint);
        break;
    }
  }

  /// Phase 9.5 — Texas Star: 5-pointed star path with two radii
  /// (outer = `min(w,h) / 2`, inner = `outer * 0.4`), 5 points at
  /// 72° intervals, starting at -90° (point up). Fill with the
  /// row's color, stroke 1px black for definition.
  void _drawTexasStar(
    Canvas canvas,
    Rect rect,
    Paint fillPaint,
    Paint outlinePaint,
  ) {
    final cx = rect.center.dx;
    final cy = rect.center.dy;
    final outer = (rect.width < rect.height ? rect.width : rect.height) / 2;
    final inner = outer * 0.4;
    final path = Path();
    // 10 vertices alternating outer / inner around a circle.
    // Start at -90° (point up).
    for (int i = 0; i < 10; i++) {
      final r = i.isEven ? outer : inner;
      final angle = -math.pi / 2 + i * (math.pi / 5);
      final x = cx + r * math.cos(angle);
      final y = cy + r * math.sin(angle);
      if (i == 0) {
        path.moveTo(x, y);
      } else {
        path.lineTo(x, y);
      }
    }
    path.close();
    canvas.drawPath(path, fillPaint);
    canvas.drawPath(path, outlinePaint);
  }

  /// Phase 9.5 — `category: 'special'` apparatus dispatch. Routes by
  /// `shape_id` to per-apparatus painters. Currently supports
  /// `pepper_popper` (fall-through to procedural IPSC-like geometry
  /// — the SVG path is normally already resolved at the top of
  /// `_paintTarget` so this branch only fires when the SVG cache is
  /// cold) and `texas_star`. Future apparatuses (plate_rack,
  /// dueling_tree_steel, etc.) add new cases here.
  /// `special`-category apparatus dispatch. Routes by `shapeId` to
  /// per-apparatus painters.
  ///
  /// Phase 9.7 Group C — takes `shapeId` as a parameter so rack-mode
  /// rendering can dispatch per-slot (each rack slot can have its
  /// own `shapeId`) without going through the painter's `target`
  /// getter (which only resolves the active slot for [RackScene]).
  /// Single-target callers pass `target.shapeId`.
  void _drawSpecial(
    Canvas canvas,
    Rect rect,
    Paint fillPaint,
    Paint outlinePaint,
    String? shapeId,
  ) {
    switch (shapeId) {
      case 'texas_star':
        _drawTexasStar(canvas, rect, fillPaint, outlinePaint);
        break;
      case 'pepper_popper':
      default:
        // SVG-cache-cold fallback: draw a rect placeholder so the
        // operator sees SOMETHING. The next repaint after preload
        // returns the authored popper silhouette.
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
    // Phase 9.7 Group B — repaint on scene-type change (Single↔Rack),
    // OR if the focus target changed inside the same scene type, OR
    // if any non-scene painter knob changed.
    //
    // The focus-target comparison handles BOTH cases automatically:
    // for SingleTargetScene it's the scene's own target (existing
    // Phase 9.6 behavior), for RackScene it's the active slot's
    // geometry (Group C will add a slot-list comparison on top so a
    // non-active slot change still triggers repaint).
    if (old.sceneInput.runtimeType != sceneInput.runtimeType) return true;
    return old.target.category != target.category ||
        old.target.shapeId != target.shapeId ||
        old.target.widthIn != target.widthIn ||
        old.target.heightIn != target.heightIn ||
        old.target.colorHex != target.colorHex ||
        old.target.svgScaleFactor != target.svgScaleFactor ||
        old.target.centerPoint.verticalFromTop !=
            target.centerPoint.verticalFromTop ||
        old.target.centerPoint.horizontalFromLeft !=
            target.centerPoint.horizontalFromLeft ||
        old.colorHexOverride != colorHexOverride ||
        old.sizeFloorEnabled != sizeFloorEnabled ||
        // Phase 10 Group A — repaint when the user toggles visual
        // style (cartoon → polished → photo or back). In Group A
        // the paint pass ignores this field (no effects yet); the
        // comparison is in place so once Group C lights up the
        // dispatch, a style change immediately repaints the scene.
        old.visualStyle != visualStyle;
  }

  // ──────────────────────────────────────────────────────────────────
  // Phase 9.7 Group C — Rack rendering
  // ──────────────────────────────────────────────────────────────────
  //
  // The unified rack render. Reuses the single-target's common
  // backdrop layers (sky / hills / treeline / grass / tall grass /
  // foreground tree) and the per-category shape dispatch
  // ([_drawCategoryShape]), and adds:
  //   * Slot-positioning math (center-to-center spacing per
  //     `RackChildSpec.offsetXFromCenterIn`, ground-anchored
  //     vertical per `mountStructure`).
  //   * 4 mount-structure drawers (rail / standing stake / popper
  //     base no-op / silhouette stand), drawn UNDER the slots so
  //     the slots render on top of the rig.
  //   * Per-slot stroke (active = 2.0 px pure-black, inactive =
  //     1.0 px black @ 70% opacity).
  //
  // What's deliberately NOT rendered (vs single-target mode):
  //   * Mound — single-target's brown earth pile under the pole.
  //   * Pole — single-target's vertical lumber stand.
  //   * Pole-base ring — single-target's disturbed-earth shadow.
  //   * Grass tufts clustered around the pole base —
  //     [_paintGrassTufts] is single-target-only too. (Field-wide
  //     tall grass via [_paintTallGrass] DOES paint for both
  //     modes — that's part of the common backdrop.)
  //
  // What's NOT YET rendered (matches single-target realistic mode):
  //   aim point, shot dots, scope ring, precision reticle. These
  //   were absent from single-target realistic mode pre-9.7 and
  //   stay absent post-9.7 for symmetry. The legacy
  //   `_RealisticTargetPainter` had its own scope-ring + reticle;
  //   Group D removes that with the legacy painter.

  /// Phase 9.7 Group C — unified rack rendering. Called from `paint()`
  /// when [sceneInput] is a [RackScene].
  ///
  /// Order of operations (matches single-target paint() except for
  /// the rig + slot-loop substitution):
  ///   1. Common backdrop (sky / hills / treeline / grass / tall
  ///      grass / foreground tree).
  ///   2. Compute per-slot rects from `offsetXFromCenterIn` +
  ///      mount-structure-specific vertical anchoring.
  ///   3. Mount-structure rig (rail / stakes / silhouette stands;
  ///      poppers are self-mounting so popper_base has no rig
  ///      pass).
  ///   4. Iterate slots in `position` order, draw each via
  ///      [_drawCategoryShape] with the slot's spec + a per-slot
  ///      stroke (active vs inactive).
  void _paintRack(
    Canvas canvas,
    Size size,
    RackSpec rack,
    int activeSlotIndex,
  ) {
    if (rack.slots.isEmpty) return;
    final w = size.width;
    final h = size.height;
    final inPerPx = h / _inchesPerCanvasHeight;
    final horizonY = _horizonFrac * h;
    // Phase 9.8.B — slot rect math now lives in the top-level
    // [computeRackSlotRects] helper (shared with the gesture handler).
    // `canvasCenterX` removed here — only the helper needs it.

    // ── 1. Common backdrop ───────────────────────────────────────
    // Phase 10 Group D — shared helper. Same sequence as the
    // single-target path; in polished/photo it adds DOF blur on
    // the distant pair + a ground-haze gradient over the horizon.
    // Cartoon mode is byte-identical to pre-Phase-10.
    _paintBackdrop(canvas, size, horizonY, inPerPx);

    // ── 2. Slot rects ────────────────────────────────────────────
    // Phase 9.8.B — slot rect computation lives at file scope
    // (`computeRackSlotRects`) so the gesture handler in
    // [TargetPlot.build] can hit-test against the SAME rects the
    // painter draws. Pre-9.8.B the math lived only inside this
    // painter; tap-to-activate would have needed to duplicate it.
    final slotRects = computeRackSlotRects(
      size,
      rack,
      horizonFrac: _horizonFrac,
      inchesPerCanvasHeight: _inchesPerCanvasHeight,
    );

    // ── 3. Mount-structure rig ──────────────────────────────────
    switch (rack.mountStructure) {
      case 'standing_stake':
        _paintStandingStakesRig(canvas, slotRects, horizonY);
        break;
      case 'silhouette_stand':
        _paintSilhouetteStandsRig(canvas, slotRects, horizonY, inPerPx);
        break;
      case 'popper_base':
        // Phase 9.7 Group C.2 hotfix — popper bases ARE a separate
        // rig pass, not part of the popper silhouette's procedural
        // drawer. Legacy `_RealisticTargetPainter._paintPopperBases`
        // drew concrete trapezoids under each popper; ported here as
        // `_paintPopperBasesRig`. Without this the poppers float on
        // grass with no concrete base under them — the operator's
        // QA on commit 9531c86 caught the missing rig.
        _paintPopperBasesRig(canvas, slotRects, horizonY);
        break;
      case 'hanging_rail':
      default:
        _paintHangingRailRig(canvas, w, slotRects, horizonY, inPerPx);
        break;
    }

    // ── 4. Slot fill + per-slot stroke ──────────────────────────
    final clampedActive =
        activeSlotIndex.clamp(0, rack.slots.length - 1);
    for (var i = 0; i < rack.slots.length; i++) {
      final slot = rack.slots[i];
      final slotRect = slotRects[i];
      final isActive = i == clampedActive;
      // Build a TargetSpec for the slot so the shared category-shape
      // dispatch resolves the same as single-target rendering.
      final spec = TargetSpec(
        category: slot.category,
        shapeId: slot.shapeId,
        widthIn: slot.widthIn,
        heightIn: slot.heightIn,
        colorHex: slot.colorHex,
      );
      // Phase 9.7 Group C stroke rule: active = 2.0 px pure-black,
      // inactive = 1.0 px black @ 70% opacity. Ratio 2.0× — well
      // above the ≥1.5× regression test threshold in
      // test/rack_rendering_test.dart.
      //
      // Phase 9.8.A — slot fill now consults `colorHexOverride`
      // first. The override is a user-picked color from the rack
      // picker's swatch row (mirror of the single-target swatch).
      // Applied uniformly across every slot in the rack — per-slot
      // overrides are out of scope for v1. Null override = use the
      // slot's authored `colorHex` from the seed catalog.
      final fillPaint = Paint()
        ..color = _parseHexColor(colorHexOverride ?? slot.colorHex);
      final outlinePaint = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = isActive ? 2.0 : 1.0
        ..color = isActive
            ? const Color(0xff000000)
            : const Color(0xff000000).withValues(alpha: 0.70);
      _drawCategoryShape(
        canvas,
        slotRect,
        spec,
        fillPaint,
        outlinePaint,
      );
    }
  }

  // Phase 9.8.B — the per-slot rect computation moved to the top-level
  // `computeRackSlotRects` helper (above `resolveTargetSvgPath`) so
  // [TargetPlot]'s gesture handler can hit-test against the SAME rects
  // this painter draws. Single source of truth — see the helper's
  // doc comment for the math.

  /// `hanging_rail` mount rig per spec §C.2:
  ///   * Brass-tinted (`#C5A572`) horizontal bar, 6 px tall, with a
  ///     2 px black stroke top + bottom.
  ///   * Bar extends from leftmost slot center - 12 in to rightmost
  ///     slot center + 12 in (12 in overhang per side).
  ///   * Tripod legs at each end: outer leg foot offset outward by
  ///     `canvasW * 0.10`, inner leg foot inward by `canvasW * 0.04`.
  ///     2 px dark-gray (`#4a4a4a`) stroke.
  ///   * Per-slot chain: 1 px black vertical line from bar bottom to
  ///     slot top.
  void _paintHangingRailRig(
    Canvas canvas,
    double canvasW,
    List<Rect> slotRects,
    double horizonY,
    double inPerPx,
  ) {
    if (slotRects.isEmpty) return;
    // Recompute rail_y from the slot top: every hanging-rail slot has
    // its top edge at rail_y + 6 + 4*inPerPx (see _computeRackSlotRects).
    // Invert that to find rail_y, so the rig and the slots stay
    // perfectly aligned regardless of which value the layout used.
    final slotTopY = slotRects.first.top;
    final railTopY = slotTopY - 4 * inPerPx - 6;
    final railBottomY = railTopY + 6;

    final leftmostX = slotRects.first.center.dx;
    final rightmostX = slotRects.last.center.dx;
    final extensionPx = 12 * inPerPx;
    final barLeftX = leftmostX - extensionPx;
    final barRightX = rightmostX + extensionPx;

    // Bar
    const brass = Color(0xffc5a572);
    const black = Color(0xff000000);
    final barFill = Paint()..color = brass;
    final barStroke = Paint()
      ..color = black
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.0;
    final barRect = Rect.fromLTRB(barLeftX, railTopY, barRightX, railBottomY);
    canvas.drawRect(barRect, barFill);
    // Two stroked lines (top + bottom) read as a 2 px black stroke on
    // each edge — cleaner than stroking the full rect (which would
    // also stroke the short left/right ends that disappear under the
    // tripod legs).
    canvas.drawLine(
      Offset(barLeftX, railTopY),
      Offset(barRightX, railTopY),
      barStroke,
    );
    canvas.drawLine(
      Offset(barLeftX, railBottomY),
      Offset(barRightX, railBottomY),
      barStroke,
    );

    // Tripod legs at each end
    const darkGray = Color(0xff4a4a4a);
    final legPaint = Paint()
      ..color = darkGray
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.0;
    final outerOffset = canvasW * 0.10;
    final innerOffset = canvasW * 0.04;
    final railCenterY = (railTopY + railBottomY) / 2;

    // Left tripod
    canvas.drawLine(
      Offset(barLeftX, railCenterY),
      Offset(barLeftX - outerOffset, horizonY),
      legPaint,
    );
    canvas.drawLine(
      Offset(barLeftX, railCenterY),
      Offset(barLeftX + innerOffset, horizonY),
      legPaint,
    );
    // Right tripod
    canvas.drawLine(
      Offset(barRightX, railCenterY),
      Offset(barRightX + outerOffset, horizonY),
      legPaint,
    );
    canvas.drawLine(
      Offset(barRightX, railCenterY),
      Offset(barRightX - innerOffset, horizonY),
      legPaint,
    );

    // Per-slot chains
    final chainPaint = Paint()
      ..color = black
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.0;
    for (final slotRect in slotRects) {
      final cx = slotRect.center.dx;
      canvas.drawLine(
        Offset(cx, railBottomY),
        Offset(cx, slotRect.top),
        chainPaint,
      );
    }
  }

  /// `standing_stake` mount rig per spec §C.2:
  ///   * Per slot, a 3 px wide vertical stake from `horizonY` up to
  ///     the slot's bottom edge.
  ///   * Stake fill `#3a3a3a` (dark gray), 1 px black stroke.
  ///   * Stake height = `slot.heightIn * 1.5 * inPerPx` (taller than
  ///     plate, so plate appears mounted at chest height of the
  ///     stake).
  void _paintStandingStakesRig(
    Canvas canvas,
    List<Rect> slotRects,
    double horizonY,
  ) {
    const darkGray = Color(0xff3a3a3a);
    const black = Color(0xff000000);
    final fillPaint = Paint()..color = darkGray;
    final strokePaint = Paint()
      ..color = black
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.0;
    const stakeWidth = 3.0;
    for (final slotRect in slotRects) {
      final cx = slotRect.center.dx;
      final stakeRect = Rect.fromLTRB(
        cx - stakeWidth / 2,
        slotRect.bottom,
        cx + stakeWidth / 2,
        horizonY,
      );
      canvas.drawRect(stakeRect, fillPaint);
      canvas.drawRect(stakeRect, strokePaint);
    }
  }

  /// `popper_base` mount rig (Phase 9.7 Group C.2 hotfix). Ports the
  /// legacy `_RealisticTargetPainter._paintPopperBases` behaviour:
  /// each popper sits on a concrete trapezoidal base, lit-from-upper-
  /// left convention (shadow on the right half of the trapezoid).
  ///
  /// Base geometry per slot:
  ///   * top at `slotRect.bottom` (popper's feet rest on the base).
  ///   * bottom at `horizonY` (base sits on the grass line).
  ///   * top half-width = `slotW * 0.75` (top is slightly wider than
  ///     the popper).
  ///   * bottom half-width = `slotW * 1.0` (bottom widens further).
  ///   * fill = light gray (`#9a9a9a`); shadow on right half =
  ///     darker gray (`#666666`).
  void _paintPopperBasesRig(
    Canvas canvas,
    List<Rect> slotRects,
    double horizonY,
  ) {
    final basePaint = Paint()..color = const Color(0xff9a9a9a);
    final shadowPaint = Paint()..color = const Color(0xff666666);
    for (final r in slotRects) {
      final cw = r.width;
      final topY = r.bottom;
      final botY = horizonY;
      if (botY <= topY) continue; // degenerate (popper extends past horizon)
      final topHalfW = cw * 0.75;
      final botHalfW = cw * 1.0;
      final cx = r.center.dx;
      final basePath = Path()
        ..moveTo(cx - topHalfW, topY)
        ..lineTo(cx + topHalfW, topY)
        ..lineTo(cx + botHalfW, botY)
        ..lineTo(cx - botHalfW, botY)
        ..close();
      canvas.drawPath(basePath, basePaint);
      // Right-side shadow wedge — half-trapezoid from center-top to
      // outer-bottom-right.
      final shadowPath = Path()
        ..moveTo(cx, topY)
        ..lineTo(cx + topHalfW, topY)
        ..lineTo(cx + botHalfW, botY)
        ..lineTo(cx, botY)
        ..close();
      canvas.drawPath(shadowPath, shadowPaint);
    }
  }

  /// `silhouette_stand` mount rig per spec §C.2:
  ///   * Per slot, a 2 px wide short stake BEHIND the silhouette.
  ///   * Stake fill `#3a3a3a` (dark gray).
  ///   * Stake length = `slot.heightIn * 0.6 * inPerPx`. Stake bottom
  ///     at `horizonY`, stake top above.
  ///   * Silhouette renders on top of the stake (later z-order), with
  ///     its own bottom edge at `horizonY` (ground-anchored).
  void _paintSilhouetteStandsRig(
    Canvas canvas,
    List<Rect> slotRects,
    double horizonY,
    double inPerPx,
  ) {
    const darkGray = Color(0xff3a3a3a);
    final paint = Paint()..color = darkGray;
    const stakeWidth = 2.0;
    for (final slotRect in slotRects) {
      final cx = slotRect.center.dx;
      // Stake length = slot height × 0.6 (in inches × inPerPx).
      // slotRect.height is already pixels, so length_px =
      // slot.heightIn * 0.6 * inPerPx = (slotRect.height) * 0.6.
      final stakeLength = slotRect.height * 0.6;
      final stakeRect = Rect.fromLTRB(
        cx - stakeWidth / 2,
        horizonY - stakeLength,
        cx + stakeWidth / 2,
        horizonY,
      );
      canvas.drawRect(stakeRect, paint);
    }
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
    switch (target.category) {
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
    if (old.target.category != target.category) return true;
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
