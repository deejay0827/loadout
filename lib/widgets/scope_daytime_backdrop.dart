// FILE: lib/widgets/scope_daytime_backdrop.dart
//
// ============================================================================
// WHAT THIS FILE DOES
// ============================================================================
// Procedural daytime-range backdrop, painted by a [CustomPainter] so it
// scales cleanly to any canvas size without bitmap assets. Renders, top
// to bottom:
//
//   1. A blue-sky gradient (top half).
//   2. A horizon line at ~50% height.
//   3. A foreground band of green grass (bottom).
//   4. A dirt-mound silhouette in the middle distance, sitting on the
//      grass and rising into the sky.
//   5. A target silhouette centered on the mound, drawn at the user's
//      currently-selected target shape (rectangle, circle, or rounded
//      "IPSC silhouette") with a subtle haze / atmospheric perspective
//      so it reads as "downrange" instead of "right here".
//
// The widget itself ([ScopeDaytimeBackdrop]) is a stateless wrapper:
// drop it into a Stack behind any scope-view UI and the backdrop fills
// the entire constraints. Pair with a `ClipOval` if you want the
// backdrop to appear inside a circular eyepiece.
//
// Public API:
//
// ```dart
// ScopeDaytimeBackdrop(
//   target: BackdropTargetSilhouette.ipsc,
//   targetWidthFraction: 0.18,   // 18% of canvas width (default 0.16)
//   targetColor: Color(0xff8a8074),
// )
// ```
//
// ============================================================================
// WHY IT EXISTS IN THE ARCHITECTURE
// ============================================================================
// The reticle-preview and full-screen scope views both need a
// representative downrange scene to render the reticle on top of —
// otherwise a pure black or solid-colored background gives the user no
// sense of how the reticle would look against a real target during a
// day-light range session. The backdrop is shared between two consumers
// (the picker's full-screen preview and the existing scope-view screen)
// so it lives in `widgets/` rather than embedded in either screen.
//
// Procedural rendering (rather than a bitmap asset) buys us:
//
//   * Zero asset bytes — no PNG ships in the bundle for this.
//   * Crisp output at any DPI / canvas size; no upscaling artifacts.
//   * Trivial color theming — we can re-skin for night-mode in the
//     future by passing a different palette.
//
// ============================================================================
// WHY THIS IS HARDER THAN IT LOOKS
// ============================================================================
//   * The `ClipOval` parent that wraps this in scope view doesn't
//     antialias the gradient edge against the FOV ring — we draw a
//     solid bottom-edge color first to prevent a 1 px seam.
//   * The dirt-mound silhouette uses a smooth Catmull-Rom-style spline
//     baked into a `Path` so the silhouette doesn't look like a
//     polygon. The control points are normalized 0–1 so they scale
//     cleanly with canvas width.
//   * Atmospheric haze on the target is implemented as an overlay
//     with white at low alpha — NOT by lowering the target's main
//     color saturation, because the reticle (drawn on top) is
//     already a color overlay; mucking with the target's RGB would
//     fight with reticle anti-aliasing.
//   * Y axis: Flutter +Y is DOWN. All y values below are described
//     "from the top" of the canvas to keep the math intuitive.
//
// ============================================================================
// WHO CONSUMES THIS FILE
// ============================================================================
// - `lib/widgets/reticle_picker.dart` — full-screen reticle preview
//   modal renders this as the eyepiece backdrop.
// - `lib/screens/range_day/scope_view_screen.dart` — the Pro-gated
//   scope-view replaces its old solid-black FOV fill with this
//   backdrop.
//
// ============================================================================
// SIDE EFFECTS
// ============================================================================
// None. Pure drawing.

import 'dart:math' as math;
import 'package:flutter/material.dart';

/// What target silhouette to draw on top of the dirt mound. Mirrors the
/// shape vocabulary used by `TargetSpec.shape` in the Range Day screens
/// so callers can map their stored target straight through.
enum BackdropTargetSilhouette {
  /// A rounded-rectangle "IPSC" upper-body silhouette. Default fallback
  /// when the caller has no target selected.
  ipsc,

  /// A simple filled circle. Use when the user's target is a paper
  /// 18" / 24" round.
  circle,

  /// A square / rectangle outline. Use when the user's target is a
  /// rectangular plate.
  rectangle,

  /// Texas Star — a reactive 5-plate steel target. Central hub +
  /// five satellite plates joined by armature lines so the shape
  /// reads as a star, not a circle.
  star,

  /// Bear silhouette — bulky body, small head with rounded ears.
  bear,

  /// Boar / wild hog silhouette — stocky body, long snout, two
  /// upright triangular ears.
  boar,

  /// Deer silhouette — slim body, small antlers (one short tine
  /// per side).
  deer,

  /// Elk silhouette — larger version of deer with multi-tine
  /// antlers.
  elk,

  /// Coyote silhouette — dog-like body, pointed ears, downturned
  /// tail.
  coyote,

  /// Pepper popper — bowling-pin reactive steel silhouette.
  /// Round head on top, narrow neck, wider rounded body that
  /// chamfers slightly toward the bottom. Used for both the
  /// full-size (85 cm tall) and mini (56 cm tall) popper variants.
  popper,

  /// No target — pure scenery (sky / grass / mound). The caller
  /// renders its own target on top via a separate painter.
  none,
}

/// Stateless widget that fills its constraints with the procedural
/// daytime backdrop. Place it as the bottom layer of a `Stack` and
/// stack other reticle / target painters on top.
class ScopeDaytimeBackdrop extends StatelessWidget {
  const ScopeDaytimeBackdrop({
    super.key,
    this.target = BackdropTargetSilhouette.ipsc,
    this.targetWidthFraction = 0.16,
    this.targetColor = const Color(0xff5e6552),
    this.size,
  });

  /// Which target silhouette to draw, or [BackdropTargetSilhouette.none]
  /// to skip the target entirely (caller will render its own).
  final BackdropTargetSilhouette target;

  /// Target width as a fraction of canvas width. 0.16 = a comfortable
  /// downrange size that doesn't dominate the FOV. 0.0 hides the
  /// target.
  final double targetWidthFraction;

  /// Fill color of the target silhouette. Default is a desaturated
  /// olive that reads as a steel plate / cardboard silhouette across
  /// most lighting.
  final Color targetColor;

  /// Optional explicit size; otherwise the painter uses the parent's
  /// constraints.
  final Size? size;

  @override
  Widget build(BuildContext context) {
    final painter = ScopeDaytimeBackdropPainter(
      target: target,
      targetWidthFraction: targetWidthFraction,
      targetColor: targetColor,
    );
    if (size != null) {
      return SizedBox(
        width: size!.width,
        height: size!.height,
        child: CustomPaint(painter: painter, size: size!),
      );
    }
    return CustomPaint(painter: painter);
  }
}

/// The actual painter. Exposed so other screens (e.g. scope_view_screen)
/// can compose the backdrop into their own [CustomPaint] alongside
/// reticle / overlay painters without nesting two `CustomPaint`
/// widgets.
class ScopeDaytimeBackdropPainter extends CustomPainter {
  ScopeDaytimeBackdropPainter({
    required this.target,
    required this.targetWidthFraction,
    required this.targetColor,
  });

  final BackdropTargetSilhouette target;
  final double targetWidthFraction;
  final Color targetColor;

  // Sky palette — light blue at zenith fading to a hazy near-horizon.
  // Values from a quick sample of typical mid-day clear-sky photographs.
  static const Color _skyTop = Color(0xffa8d4ff);
  static const Color _skyHorizon = Color(0xffc8dcfa);

  // Grass palette — slightly desaturated natural green that doesn't
  // fight the reticle's bright color when overlaid.
  static const Color _grassNear = Color(0xff8aa970);
  static const Color _grassFar = Color(0xff96b078);

  // Dirt mound color (warm tan-brown that contrasts both sky and grass).
  static const Color _mound = Color(0xff7d6d58);
  static const Color _moundShadow = Color(0xff5d4f3d);

  @override
  void paint(Canvas canvas, Size size) {
    if (size.width <= 0 || size.height <= 0) return;
    final w = size.width;
    final h = size.height;

    // Horizon at ~50% canvas height. Above is sky, below is grass +
    // mound. Tuneable per design later — we expose it as a const here.
    final horizonY = h * 0.50;

    _paintSky(canvas, w, horizonY);
    _paintGrass(canvas, w, h, horizonY);
    _paintMound(canvas, w, h, horizonY);
    _paintTarget(canvas, w, h, horizonY);
    _paintAtmosphericHaze(canvas, w, h, horizonY);
  }

  /// Sky gradient: vivid blue at top fading to a hazy pale blue at the
  /// horizon. Drawn as a single rectangle so the entire upper half
  /// shares the gradient, keeping the painting cheap.
  void _paintSky(Canvas canvas, double w, double horizonY) {
    final rect = Rect.fromLTWH(0, 0, w, horizonY);
    final paint = Paint()
      ..shader = const LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [_skyTop, _skyHorizon],
      ).createShader(rect);
    canvas.drawRect(rect, paint);
  }

  /// Grass — gradient from a far / hazy green at the horizon to a
  /// closer / saturated green at the bottom of the canvas. Plus a
  /// subtle horizon line so the sky / grass meet cleanly.
  void _paintGrass(Canvas canvas, double w, double h, double horizonY) {
    final rect = Rect.fromLTWH(0, horizonY, w, h - horizonY);
    final paint = Paint()
      ..shader = LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: const [_grassFar, _grassNear],
      ).createShader(rect);
    canvas.drawRect(rect, paint);

    // 1 px hairline at the horizon, slightly darker than either side,
    // so the visual seam looks deliberate (a faraway tree-line, not a
    // gradient cut).
    final hairline = Paint()
      ..color = const Color(0xff7a8c66)
      ..strokeWidth = 1.0
      ..style = PaintingStyle.stroke;
    canvas.drawLine(
      Offset(0, horizonY),
      Offset(w, horizonY),
      hairline,
    );
  }

  /// Smooth dirt mound silhouette behind the target. Uses a small set
  /// of normalized control points fed to a quadratic-Bezier path so
  /// the mound reads as a natural earth berm instead of a polygon.
  /// Two passes: a darker shadow on the right side, the lighter mound
  /// proper on top.
  void _paintMound(Canvas canvas, double w, double h, double horizonY) {
    // Mound spans the middle 60% of canvas width, crests at ~12% of
    // canvas height ABOVE the horizon (so it visibly interrupts the
    // skyline without obscuring the FOV).
    final left = w * 0.18;
    final right = w * 0.82;
    final crestY = horizonY - h * 0.12;
    final crestX = w * 0.5;

    final path = Path()
      ..moveTo(left, horizonY)
      // Use a single broad quadratic curve to the crest …
      ..quadraticBezierTo(
        left + (crestX - left) * 0.55, // control: rising slope
        horizonY - h * 0.04,
        crestX - w * 0.08,
        crestY + h * 0.02,
      )
      ..quadraticBezierTo(
        crestX,
        crestY - h * 0.02,
        crestX + w * 0.08,
        crestY + h * 0.02,
      )
      // … then back down to the right base.
      ..quadraticBezierTo(
        crestX + (right - crestX) * 0.45,
        horizonY - h * 0.04,
        right,
        horizonY,
      )
      ..close();

    // Mound body.
    final mound = Paint()..color = _mound;
    canvas.drawPath(path, mound);

    // Right-side shadow (the mound is lit from the upper left). Drawn
    // as a clipped polygon along the right half of the mound silhouette.
    final shadowPath = Path()
      ..moveTo(crestX, crestY - h * 0.02)
      ..quadraticBezierTo(
        crestX + w * 0.04,
        crestY,
        crestX + w * 0.08,
        crestY + h * 0.02,
      )
      ..quadraticBezierTo(
        crestX + (right - crestX) * 0.45,
        horizonY - h * 0.04,
        right,
        horizonY,
      )
      ..lineTo(crestX, horizonY)
      ..close();
    canvas.drawPath(shadowPath, Paint()..color = _moundShadow.withValues(alpha: 0.45));
  }

  /// Target silhouette centered on the mound. Sized in canvas-fraction
  /// terms so the target's apparent angular size in the rendered FOV
  /// stays roughly consistent across screen sizes.
  void _paintTarget(Canvas canvas, double w, double h, double horizonY) {
    if (target == BackdropTargetSilhouette.none) return;
    if (targetWidthFraction <= 0) return;
    final widthPx = w * targetWidthFraction;
    // Per-shape height ratio. IPSC is taller than wide (1.6×); circle
    // / rectangle / star are square; animals are wider than tall
    // (~1.5:1 in real life) so the body reads as a side profile.
    final heightPx = switch (target) {
      BackdropTargetSilhouette.ipsc => widthPx * 1.6,
      BackdropTargetSilhouette.circle => widthPx,
      BackdropTargetSilhouette.rectangle => widthPx,
      BackdropTargetSilhouette.star => widthPx,
      // Popper is very tall + narrow (~4.25:1 height:width). The
      // catalog's full popper is 33.46 x 7.87 in.
      BackdropTargetSilhouette.popper => widthPx * 4.25,
      BackdropTargetSilhouette.bear => widthPx / 1.3,
      BackdropTargetSilhouette.boar => widthPx / 1.6,
      BackdropTargetSilhouette.deer => widthPx / 1.4,
      BackdropTargetSilhouette.elk => widthPx / 1.3,
      BackdropTargetSilhouette.coyote => widthPx / 1.5,
      BackdropTargetSilhouette.none => 0.0,
    };
    final centerX = w * 0.5;
    // Sit the target on the crest of the mound — bottom of the
    // silhouette aligns roughly with the crest's top point.
    final crestY = horizonY - h * 0.12;
    final centerY = crestY - heightPx * 0.5 + h * 0.02;

    final fill = Paint()..color = targetColor;
    final outline = Paint()
      ..color = const Color(0xff2c2924)
      ..style = PaintingStyle.stroke
      ..strokeWidth = math.max(1.0, w * 0.002);

    switch (target) {
      case BackdropTargetSilhouette.ipsc:
        // Cardboard-style upper torso silhouette: rounded rect for the
        // body with a smaller rounded rect on top for the head.
        final bodyRect = Rect.fromCenter(
          center: Offset(centerX, centerY + heightPx * 0.10),
          width: widthPx,
          height: heightPx * 0.70,
        );
        final headRect = Rect.fromCenter(
          center: Offset(centerX, centerY - heightPx * 0.40),
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
        canvas.drawRRect(body, fill);
        canvas.drawRRect(head, fill);
        canvas.drawRRect(body, outline);
        canvas.drawRRect(head, outline);
      case BackdropTargetSilhouette.circle:
        canvas.drawCircle(
          Offset(centerX, centerY),
          widthPx / 2,
          fill,
        );
        canvas.drawCircle(
          Offset(centerX, centerY),
          widthPx / 2,
          outline,
        );
      case BackdropTargetSilhouette.rectangle:
        final rect = Rect.fromCenter(
          center: Offset(centerX, centerY),
          width: widthPx,
          height: heightPx,
        );
        canvas.drawRect(rect, fill);
        canvas.drawRect(rect, outline);
      case BackdropTargetSilhouette.star:
        _paintTexasStar(
          canvas,
          centerX,
          centerY,
          widthPx / 2,
          fill,
          outline,
          w,
        );
      case BackdropTargetSilhouette.bear:
      case BackdropTargetSilhouette.boar:
      case BackdropTargetSilhouette.deer:
      case BackdropTargetSilhouette.elk:
      case BackdropTargetSilhouette.coyote:
        _paintAnimal(
          canvas,
          centerX,
          centerY,
          widthPx,
          heightPx,
          fill,
          outline,
          target,
        );
      case BackdropTargetSilhouette.popper:
        _paintPopper(canvas, centerX, centerY, widthPx, heightPx,
            fill, outline);
      case BackdropTargetSilhouette.none:
        break;
    }
  }

  /// Pepper-popper silhouette: round head on top, narrow neck,
  /// rounded body that chamfers slightly toward the bottom. Mirrors
  /// the thumbnail painter so the inline preview and the daytime
  /// backdrop stay consistent.
  void _paintPopper(
    Canvas canvas,
    double cx,
    double cy,
    double targetW,
    double targetH,
    Paint fill,
    Paint outline,
  ) {
    final left = cx - targetW / 2;
    final right = cx + targetW / 2;
    final top = cy - targetH / 2;
    final bottom = cy + targetH / 2;
    // Geometry breakdown matches `_paintPopper` in
    // `range_day_detail_screen.dart` so the inline thumbnail and the
    // scope backdrop render identical bowling-pin shapes.
    final headBottom = top + targetH * 0.18;
    final neckBottom = headBottom + targetH * 0.06;
    final shoulderBottom = neckBottom + targetH * 0.04;
    final chamferStart = bottom - targetH * 0.07;
    final neckHalfW = targetW * 0.275;
    final bodyHalfW = targetW * 0.475;
    final bottomHalfW = targetW * 0.40;
    final path = Path()
      ..moveTo(cx, top)
      ..arcToPoint(
        Offset(right, (top + headBottom) / 2),
        radius: Radius.circular(targetW / 2),
        clockwise: true,
      )
      ..arcToPoint(
        Offset(cx, headBottom),
        radius: Radius.circular(targetW / 2),
        clockwise: true,
      )
      ..quadraticBezierTo(
        right * 0.55 + cx * 0.45,
        headBottom,
        cx + neckHalfW,
        neckBottom,
      )
      ..quadraticBezierTo(
        cx + neckHalfW,
        shoulderBottom,
        cx + bodyHalfW,
        shoulderBottom + targetH * 0.02,
      )
      ..lineTo(cx + bodyHalfW, chamferStart)
      ..lineTo(cx + bottomHalfW, bottom)
      ..lineTo(cx - bottomHalfW, bottom)
      ..lineTo(cx - bodyHalfW, chamferStart)
      ..lineTo(cx - bodyHalfW, shoulderBottom + targetH * 0.02)
      ..quadraticBezierTo(
        cx - neckHalfW,
        shoulderBottom,
        cx - neckHalfW,
        neckBottom,
      )
      ..quadraticBezierTo(
        left * 0.55 + cx * 0.45,
        headBottom,
        cx,
        headBottom,
      )
      ..arcToPoint(
        Offset(left, (top + headBottom) / 2),
        radius: Radius.circular(targetW / 2),
        clockwise: true,
      )
      ..arcToPoint(
        Offset(cx, top),
        radius: Radius.circular(targetW / 2),
        clockwise: true,
      )
      ..close();
    canvas.drawPath(path, fill);
    canvas.drawPath(path, outline);
  }

  /// Paint an animal silhouette as a recognizable side-profile of the
  /// body type. Ported from `_TargetThumbnailPainter._paintAnimal` in
  /// `lib/screens/range_day/range_day_detail_screen.dart`. Adapted to
  /// the backdrop's coordinate system: the thumbnail painter accepts a
  /// single `maxBox` square and computes an inner aspect-correct body
  /// rect; here the caller has already resolved a `bodyW` / `bodyH`
  /// pair from `widthPx` / `heightPx` against a per-species default
  /// aspect (the backdrop has no `TargetSpec` to read width/height
  /// inches from). The geometry is otherwise identical: rounded body
  /// rect + head + snout + four legs, with antlers / ears / tail
  /// added per species. NOT photorealistic — the goal is a glance-
  /// level read against the daytime backdrop.
  void _paintAnimal(
    Canvas canvas,
    double cx,
    double cy,
    double bodyW,
    double bodyH,
    Paint fill,
    Paint outline,
    BackdropTargetSilhouette kind,
  ) {
    // Body rectangle (rounded) — left half is haunches, right half
    // is shoulder/chest. We anchor to the lower portion of the box
    // so head/antlers can extend above without overflowing.
    final bodyRect = Rect.fromCenter(
      center: Offset(cx - bodyW * 0.05, cy + bodyH * 0.08),
      width: bodyW * 0.78,
      height: bodyH * 0.50,
    );
    final body = RRect.fromRectAndRadius(
      bodyRect, Radius.circular(bodyH * 0.10));
    canvas.drawRRect(body, fill);
    canvas.drawRRect(body, outline);
    // Head — sits forward (right side) at the front of the body.
    final headW = bodyW * 0.28;
    final headH = bodyH * 0.30;
    final headCx = cx + bodyW * 0.32;
    final headCy = cy - bodyH * 0.10;
    final headRect = Rect.fromCenter(
      center: Offset(headCx, headCy),
      width: headW,
      height: headH,
    );
    final head = RRect.fromRectAndRadius(
      headRect, Radius.circular(headH * 0.35));
    canvas.drawRRect(head, fill);
    canvas.drawRRect(head, outline);
    // Snout — short for deer/elk/bear/coyote, longer + thicker for
    // boar so the muzzle reads as the defining feature.
    final isHog = kind == BackdropTargetSilhouette.boar;
    final snoutW = isHog ? headW * 0.55 : headW * 0.40;
    final snoutH = isHog ? headH * 0.50 : headH * 0.30;
    final snoutRect = Rect.fromCenter(
      center: Offset(headCx + headW * 0.45, headCy + headH * 0.10),
      width: snoutW,
      height: snoutH,
    );
    final snout = RRect.fromRectAndRadius(
      snoutRect, Radius.circular(snoutH * 0.4));
    canvas.drawRRect(snout, fill);
    canvas.drawRRect(snout, outline);
    // Legs — four short rectangles under the body.
    final legW = bodyW * 0.06;
    final legH = bodyH * 0.32;
    for (final dx in [-0.30, -0.10, 0.12, 0.28]) {
      final legRect = Rect.fromCenter(
        center: Offset(cx + bodyW * dx, cy + bodyH * 0.40),
        width: legW,
        height: legH,
      );
      canvas.drawRect(legRect, fill);
      canvas.drawRect(legRect, outline);
    }
    // Tail / appendages by species.
    if (kind == BackdropTargetSilhouette.deer ||
        kind == BackdropTargetSilhouette.elk) {
      final isElk = kind == BackdropTargetSilhouette.elk;
      // Antlers — two angled lines branching upward from the head.
      final antlerPaint = Paint()
        ..color = outline.color
        ..style = PaintingStyle.stroke
        ..strokeWidth = math.max(2.0, bodyH * 0.04)
        ..strokeCap = StrokeCap.round;
      final base = Offset(headCx - headW * 0.20, headCy - headH * 0.40);
      final antlerSpan = (isElk ? 0.55 : 0.40) * bodyH;
      final antlerWidth = (isElk ? 0.55 : 0.35) * bodyW;
      // Main antler beams.
      canvas.drawLine(
        base,
        Offset(base.dx - antlerWidth * 0.30, base.dy - antlerSpan),
        antlerPaint,
      );
      canvas.drawLine(
        Offset(base.dx + headW * 0.15, base.dy),
        Offset(base.dx + headW * 0.15 + antlerWidth * 0.25,
            base.dy - antlerSpan),
        antlerPaint,
      );
      // Tine for elk only — extra branch off each main beam.
      if (isElk) {
        canvas.drawLine(
          Offset(base.dx - antlerWidth * 0.15, base.dy - antlerSpan * 0.55),
          Offset(base.dx - antlerWidth * 0.40,
              base.dy - antlerSpan * 0.85),
          antlerPaint,
        );
        canvas.drawLine(
          Offset(base.dx + headW * 0.15 + antlerWidth * 0.12,
              base.dy - antlerSpan * 0.55),
          Offset(base.dx + headW * 0.15 + antlerWidth * 0.35,
              base.dy - antlerSpan * 0.85),
          antlerPaint,
        );
      }
      // Short tail.
      final tail = Rect.fromCenter(
        center: Offset(cx - bodyW * 0.42, cy - bodyH * 0.05),
        width: bodyW * 0.05,
        height: bodyH * 0.12,
      );
      canvas.drawRect(tail, fill);
      canvas.drawRect(tail, outline);
    } else if (kind == BackdropTargetSilhouette.bear) {
      // Two small rounded ears on top of the head.
      for (final dx in [-0.18, 0.18]) {
        final ear = Rect.fromCenter(
          center: Offset(headCx + headW * dx, headCy - headH * 0.55),
          width: headW * 0.30,
          height: headH * 0.32,
        );
        final earR = RRect.fromRectAndRadius(ear, Radius.circular(headH * 0.25));
        canvas.drawRRect(earR, fill);
        canvas.drawRRect(earR, outline);
      }
    } else if (isHog) {
      // Two upright triangular ears.
      for (final dx in [-0.15, 0.15]) {
        final earPath = Path()
          ..moveTo(headCx + headW * dx - headW * 0.10,
              headCy - headH * 0.30)
          ..lineTo(headCx + headW * dx + headW * 0.10,
              headCy - headH * 0.30)
          ..lineTo(headCx + headW * dx, headCy - headH * 0.75)
          ..close();
        canvas.drawPath(earPath, fill);
        canvas.drawPath(earPath, outline);
      }
    } else if (kind == BackdropTargetSilhouette.coyote) {
      // Two pointed ears + a thin downturned tail.
      for (final dx in [-0.18, 0.18]) {
        final earPath = Path()
          ..moveTo(headCx + headW * dx - headW * 0.10,
              headCy - headH * 0.30)
          ..lineTo(headCx + headW * dx + headW * 0.10,
              headCy - headH * 0.30)
          ..lineTo(headCx + headW * dx, headCy - headH * 0.75)
          ..close();
        canvas.drawPath(earPath, fill);
        canvas.drawPath(earPath, outline);
      }
      final tail = Rect.fromCenter(
        center: Offset(cx - bodyW * 0.45, cy + bodyH * 0.18),
        width: bodyW * 0.20,
        height: bodyH * 0.05,
      );
      canvas.drawRect(tail, fill);
      canvas.drawRect(tail, outline);
    }
  }

  /// Paints a Texas Star: central hub with five satellite plates
  /// arranged radially. Ported from
  /// `_TargetThumbnailPainter._paintTexasStar` in
  /// `lib/screens/range_day/range_day_detail_screen.dart`. Adapted
  /// to the backdrop by taking the canvas width `w` so the armature
  /// stroke width can scale against the same `w * 0.002` baseline
  /// used for the rest of the backdrop's outlines (the thumbnail
  /// version scaled against `radius` directly because every
  /// thumbnail spans roughly the same canvas size).
  void _paintTexasStar(
    Canvas canvas,
    double cx,
    double cy,
    double radius,
    Paint fill,
    Paint outline,
    double w,
  ) {
    // Plate sizing — central hub is small; satellite plates are
    // larger and sit at the radius. Five satellites at 72 degrees
    // apart, starting from the top.
    final hubR = radius * 0.18;
    final plateR = radius * 0.22;
    final orbitR = radius * 0.78;
    final armPaint = Paint()
      ..color = outline.color
      ..style = PaintingStyle.stroke
      ..strokeWidth = math.max(1.5, w * 0.0025);
    // Arms first so the plates draw on top.
    for (var i = 0; i < 5; i++) {
      final angle = -math.pi / 2 + i * (2 * math.pi / 5);
      final px = cx + orbitR * math.cos(angle);
      final py = cy + orbitR * math.sin(angle);
      canvas.drawLine(Offset(cx, cy), Offset(px, py), armPaint);
    }
    // Central hub.
    canvas.drawCircle(Offset(cx, cy), hubR, fill);
    canvas.drawCircle(Offset(cx, cy), hubR, outline);
    // Five satellite plates.
    for (var i = 0; i < 5; i++) {
      final angle = -math.pi / 2 + i * (2 * math.pi / 5);
      final px = cx + orbitR * math.cos(angle);
      final py = cy + orbitR * math.sin(angle);
      canvas.drawCircle(Offset(px, py), plateR, fill);
      canvas.drawCircle(Offset(px, py), plateR, outline);
    }
  }

  /// Subtle white-ish overlay on the upper third of the canvas to
  /// suggest atmospheric haze on a downrange object. Dialed in low
  /// alpha so the silhouette + reticle still read clearly.
  void _paintAtmosphericHaze(
    Canvas canvas,
    double w,
    double h,
    double horizonY,
  ) {
    final hazeRect = Rect.fromLTWH(0, horizonY - h * 0.15, w, h * 0.30);
    final paint = Paint()
      ..shader = LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [
          Colors.white.withValues(alpha: 0.10),
          Colors.white.withValues(alpha: 0.0),
        ],
      ).createShader(hazeRect);
    canvas.drawRect(hazeRect, paint);
  }

  @override
  bool shouldRepaint(covariant ScopeDaytimeBackdropPainter old) {
    return old.target != target ||
        old.targetWidthFraction != targetWidthFraction ||
        old.targetColor != targetColor;
  }
}
