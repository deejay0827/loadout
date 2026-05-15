// FILE: lib/screens/range_day/widgets/popper_path.dart
//
// ============================================================================
// WHAT THIS FILE DOES
// ============================================================================
// Phase 11 Group A — exposes `drawPepperPopperPath(Rect rect) → Path`, a
// procedural drawer for the IPSC pepper popper silhouette. Returns a single
// closed `Path` that traces the outer silhouette inside the input bounding
// rect: circular head, narrow neck, concave shoulder transition, slightly
// flared body with rounded base corners.
//
// Replaces `assets/silhouettes/targets/pepper_popper.svg` for rendering
// purposes only. The SVG file stays in the repo + storage bucket as legacy
// provenance; the dispatch in `_drawCategoryShape` + `_drawSpecial` now
// routes `shape_id == 'pepper_popper'` through this function instead of the
// SVG resolver.
//
// Geometry is parameterized off the bounding rect's width (w) and height (h)
// per the Phase 11 spec §Architecture-decisions. Every measurement is a
// fixed fraction of one of those dimensions, so the silhouette scales
// uniformly with the rack slot rect at any size.
//
// ============================================================================
// WHY IT EXISTS IN THE ARCHITECTURE
// ============================================================================
// The pepper popper SVG, at preview canvas sizes (~30 × 130 px in rack
// mode), read as a tall thin rectangle because the bowling-pin curves in
// the SVG were too subtle to survive that resolution. Mathematically defined
// curves solve the resolution problem — the head circle, shoulder Bezier,
// and base corner arcs all scale crisply regardless of the rect size.
//
// ============================================================================
// WHY THIS IS HARDER THAN IT LOOKS
// ============================================================================
// - The head's circular diameter is `h × 0.25`; the neck width is `w × 0.40`.
//   For typical popper aspect ratios (tall narrow rect, `h × 0.125 > w × 0.20`)
//   the head circle is wider than the neck, so the silhouette traces the
//   head down to the point where the circle's right/left edge intersects
//   the neck's vertical edges, then continues down as the neck. If the
//   aspect ratio ever degenerated to a wide-and-short rect, the
//   discriminant for that intersection goes negative; we clamp at 0 in
//   that degenerate case so the trace doesn't NaN. The catalog ships
//   popper rack slots in the tall-and-narrow regime so this is defensive
//   guarding, not a runtime hot path.
// - The shoulder transition uses cubic Beziers with control points pulled
//   downward by `h × 0.06` from the neck-bottom endpoints, giving the
//   characteristic concave necked-out curve rather than a straight
//   diagonal. Without this offset the silhouette would look hexagonal.
// - The body sides are mathematically a straight line from shoulder corner
//   to body base corner. Since the shoulder is at `w × 0.92` and the base
//   is at `w × 1.00`, the body has a subtle outward flare visible at
//   large sizes — matches the real-world IPSC popper profile.
// - The base corners use `Path.arcToPoint` with `Radius.circular(w × 0.06)`
//   in clockwise direction. Small radius (~6 % of w) gives a rounded base
//   that reads as a steel popper rather than a sharp-cornered silhouette.
// - The trace direction is clockwise from the top of the head. All
//   `arcToPoint` calls use `clockwise: true`, all line segments are
//   ordered to match. Reversing the direction would invert the path's
//   fill rule and could break fill rendering.
//
// ============================================================================
// WHO CONSUMES THIS FILE
// ============================================================================
// - `_drawCategoryShape` in `lib/screens/range_day/widgets/target_plot.dart`
//   short-circuits to this drawer when `category == 'special'` and
//   `shape_id == 'pepper_popper'`, skipping the SVG resolver.
// - `_drawSpecial` in the same file also routes `pepper_popper` here
//   (the SVG-cold fallback case, now using the procedural path instead
//   of a placeholder rectangle).
// - `_paintTargetShadow` in the same file (Phase 10 Group E drop shadow)
//   uses this path for the shadow of `pepper_popper` slots so the drop
//   shadow follows the silhouette geometry, not just a bounds rect.
// - `test/popper_path_test.dart` exercises the drawer directly.
//
// ============================================================================
// SIDE EFFECTS
// ============================================================================
// None. Pure path construction from input rect. No global state, no I/O.

import 'dart:math' as math;

import 'package:flutter/material.dart';

/// Builds the procedural IPSC pepper-popper silhouette inside [rect].
///
/// The path is closed and traces the outer silhouette clockwise from the
/// top of the head. Suitable for `canvas.drawPath(path, fillPaint)` +
/// `canvas.drawPath(path, strokePaint)` to render a filled silhouette
/// with outline. Path bounds match [rect] (width touches both vertical
/// edges at the base; height spans `rect.top` to `rect.bottom`).
Path drawPepperPopperPath(Rect rect) {
  final w = rect.width;
  final h = rect.height;
  final cx = rect.left + w / 2;

  // ── Head: full circle, diameter h × 0.25 ────────────────────────
  final headRadius = h * 0.125;
  final headCenterY = rect.top + headRadius;

  // ── Neck: vertical band, width w × 0.40 ─────────────────────────
  final neckHalfW = w * 0.20;
  final neckBottomY = rect.top + h * 0.36;

  // ── Shoulders: concave transition from neck to body ─────────────
  // Upper width matches the neck (w × 0.40); lower width matches the
  // body's shoulder-top (w × 0.92).
  final shoulderLowerY = rect.top + h * 0.48;
  final shoulderHalfW = w * 0.46;

  // ── Body: slight outward flare from shoulder to base ────────────
  // Shoulder half-width w × 0.46, base half-width w × 0.50, rounded
  // base corners with radius w × 0.06.
  final bodyBaseHalfW = w * 0.50;
  final cornerRadius = w * 0.06;
  final bodyBottomY = rect.bottom;
  final straightBodyBottomY = bodyBottomY - cornerRadius;

  // Where the head circle intersects the neck's vertical edges. Used as
  // the tangent point where the silhouette exits the head and enters the
  // neck.
  //
  //   Head circle equation: (x − cx)² + (y − headCenterY)² = headRadius²
  //   At x = cx + neckHalfW:
  //     (y − headCenterY)² = headRadius² − neckHalfW²
  //     y = headCenterY + √(headRadius² − neckHalfW²)   (lower intersection)
  //
  // For typical popper aspect ratios `headRadius > neckHalfW` so the
  // discriminant is positive. If the aspect ratio ever inverts
  // (`h × 0.125 < w × 0.20`, i.e. wider-than-tall popper slot — does
  // not happen in the shipped catalog), the discriminant goes negative;
  // we clamp at 0 to avoid `NaN`. In the clamped degenerate case the
  // trace jumps from the head's vertical tangent straight to the neck
  // top, which reads slightly off but never crashes.
  final discriminant = headRadius * headRadius - neckHalfW * neckHalfW;
  final dy = discriminant > 0 ? math.sqrt(discriminant) : 0.0;
  final headExitY = headCenterY + dy;

  // Control-point Y offset for the shoulder cubic Bezier. Pulls the
  // control points downward from the neck-bottom endpoints to give the
  // concave necked-out curve rather than a straight diagonal.
  final shoulderCtrlYOffset = h * 0.06;

  final path = Path();

  // 1. Top of head.
  path.moveTo(cx, rect.top);

  // 2. Arc clockwise along the right side of the head, exiting where the
  //    circle meets the neck's right vertical edge.
  path.arcToPoint(
    Offset(cx + neckHalfW, headExitY),
    radius: Radius.circular(headRadius),
    clockwise: true,
  );

  // 3. Down the right side of the neck.
  path.lineTo(cx + neckHalfW, neckBottomY);

  // 4. Cubic Bezier shoulder transition outward to the body shoulder.
  //    Control points pulled DOWN by `shoulderCtrlYOffset` from the
  //    endpoints to give the concave necked-out curve.
  path.cubicTo(
    cx + neckHalfW,
    neckBottomY + shoulderCtrlYOffset,
    cx + shoulderHalfW,
    shoulderLowerY - shoulderCtrlYOffset,
    cx + shoulderHalfW,
    shoulderLowerY,
  );

  // 5. Down the right body side, slight outward taper to the base.
  path.lineTo(cx + bodyBaseHalfW, straightBodyBottomY);

  // 6. Rounded bottom-right corner (quarter arc, clockwise).
  path.arcToPoint(
    Offset(cx + bodyBaseHalfW - cornerRadius, bodyBottomY),
    radius: Radius.circular(cornerRadius),
    clockwise: true,
  );

  // 7. Horizontal line across the base, between the two corner arcs.
  path.lineTo(cx - bodyBaseHalfW + cornerRadius, bodyBottomY);

  // 8. Rounded bottom-left corner (quarter arc, clockwise).
  path.arcToPoint(
    Offset(cx - bodyBaseHalfW, straightBodyBottomY),
    radius: Radius.circular(cornerRadius),
    clockwise: true,
  );

  // 9. Up the left body side, mirror of step 5.
  path.lineTo(cx - shoulderHalfW, shoulderLowerY);

  // 10. Cubic Bezier shoulder transition inward to the neck, mirror of
  //     step 4.
  path.cubicTo(
    cx - shoulderHalfW,
    shoulderLowerY - shoulderCtrlYOffset,
    cx - neckHalfW,
    neckBottomY + shoulderCtrlYOffset,
    cx - neckHalfW,
    neckBottomY,
  );

  // 11. Up the left side of the neck.
  path.lineTo(cx - neckHalfW, headExitY);

  // 12. Arc clockwise along the left side of the head back to the top.
  path.arcToPoint(
    Offset(cx, rect.top),
    radius: Radius.circular(headRadius),
    clockwise: true,
  );

  // 13. Close (effectively a no-op since step 12 returned to the start).
  path.close();
  return path;
}
