// FILE: lib/widgets/reticle_renderer.dart
//
// ============================================================================
// WHAT THIS FILE DOES
// ============================================================================
// Stateless widget that draws a [ReticleDefinition] onto a Flutter canvas.
// The reticle's drawable elements are defined in
// `lib/data/reticle_library.dart`; this widget interprets them, scales
// them to the available widget size, optionally re-anchors the reticle
// to a non-center "aim point" pixel, and paints them with a
// [CustomPainter].
//
// The widget is the visual half of two pieces of work:
//
//   * `ReticleDefinition` (data) — JSON-decoded subtension, holdover and
//     hash mark layout. Lives in `lib/data/reticle_library.dart`.
//   * `ReticleRenderer` (UI) — this file. Translates a definition into
//     a CustomPainter and renders it.
//
// We're stateless: the parent widget owns the picked reticle, the aim
// point pixel, the color, the scale, etc. All we do is paint.
//
// ============================================================================
// COORDINATE CONVENTION
// ============================================================================
// Reticle elements are stored in the reticle's *native unit* (mil, MOA,
// ipsc, bdc). At render time we convert to widget pixels using:
//
//   pixelsPerUnit = (size.shortestSide * 0.45) / maxExtentUnits * scale
//
// where `maxExtentUnits` is the reticle's half-extent (so 1.0 unit at
// scale 1.0 in a 280×280 canvas works out to ~12.6 px). The center of
// the reticle is `aimPoint` if provided, otherwise the canvas center.
// Reticle Y axis: +1 = up (positive native units = up). Flutter canvas:
// +Y = down. So we flip Y when we map element coordinates to pixels.

import 'package:flutter/material.dart';

import '../data/reticle_library.dart';

class ReticleRenderer extends StatelessWidget {
  const ReticleRenderer({
    super.key,
    required this.reticle,
    required this.displayUnit,
    this.scale = 1.0,
    this.color,
    this.aimPoint,
    this.size = const Size(280, 280),
    this.showUnitOverlay = true,
  });

  /// The reticle definition to render.
  final ReticleDefinition reticle;

  /// 'mil' or 'moa' — only changes the labels on FloatingNumber elements.
  /// The reticle geometry stays in native units.
  final String displayUnit;

  /// Multiplier applied to the auto-fit scale. 1.0 = the reticle's
  /// half-extent fills 45% of the shortest widget side.
  final double scale;

  /// Override stroke color. Defaults to the theme's `colorScheme.primary`.
  final Color? color;

  /// Pixel offset (relative to the widget) where the reticle center
  /// should sit. Null = centered.
  final Offset? aimPoint;

  /// Canvas size. The widget can be embedded in any constraint — we
  /// honour the explicit size first and fall back to the parent's
  /// constraints if the parent gives us a finite box.
  final Size size;

  /// Whether to paint the corner unit overlay ("MIL @ FFP"). Disabled
  /// by callers that render small thumbnails (e.g. the picker preview)
  /// where the label would crowd the reticle.
  final bool showUnitOverlay;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final lineColor = color ?? theme.colorScheme.primary;
    return SizedBox(
      width: size.width,
      height: size.height,
      child: CustomPaint(
        size: size,
        painter: _ReticlePainter(
          reticle: reticle,
          displayUnit: displayUnit,
          scale: scale,
          lineColor: lineColor,
          aimPoint: aimPoint,
          showUnitOverlay: showUnitOverlay,
        ),
      ),
    );
  }
}

class _ReticlePainter extends CustomPainter {
  _ReticlePainter({
    required this.reticle,
    required this.displayUnit,
    required this.scale,
    required this.lineColor,
    required this.aimPoint,
    required this.showUnitOverlay,
  });

  final ReticleDefinition reticle;
  final String displayUnit;
  final double scale;
  final Color lineColor;
  final Offset? aimPoint;
  final bool showUnitOverlay;

  @override
  void paint(Canvas canvas, Size size) {
    if (reticle.maxExtentUnits <= 0) return;
    // Pixels per native unit (mil/MOA). 0.45 leaves a comfortable margin
    // around the visible reticle on a square canvas.
    final pxPerUnit =
        (size.shortestSide * 0.45) / reticle.maxExtentUnits * scale;
    final centre = aimPoint ?? Offset(size.width / 2, size.height / 2);

    Offset toPx(double xUnits, double yUnits) {
      // Native +Y is up; Flutter canvas +Y is down — so flip the Y term.
      return Offset(
        centre.dx + xUnits * pxPerUnit,
        centre.dy - yUnits * pxPerUnit,
      );
    }

    final stroke = Paint()
      ..color = lineColor
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.butt;

    final fill = Paint()
      ..color = lineColor
      ..style = PaintingStyle.fill;

    for (final el in reticle.elements) {
      switch (el) {
        case CrosshairLine():
          stroke.strokeWidth = (el.thicknessMil * pxPerUnit).clamp(0.6, 6.0);
          canvas.drawLine(
            toPx(el.startX, el.startY),
            toPx(el.endX, el.endY),
            stroke,
          );
        case HashMark():
          stroke.strokeWidth =
              (el.thicknessUnits * pxPerUnit).clamp(0.4, 4.0);
          final half = el.lengthUnits / 2;
          if (el.axis == HashAxis.horizontal) {
            // Tick stands vertically across the horizontal axis.
            canvas.drawLine(
              toPx(el.x, el.y - half),
              toPx(el.x, el.y + half),
              stroke,
            );
          } else {
            // Tick lies horizontally across the vertical axis.
            canvas.drawLine(
              toPx(el.x - half, el.y),
              toPx(el.x + half, el.y),
              stroke,
            );
          }
        case CenterDot():
          final r = (el.radiusUnits * pxPerUnit).clamp(0.6, 8.0);
          if (el.open) {
            stroke.strokeWidth = (r * 0.25).clamp(0.5, 2.0);
            canvas.drawCircle(toPx(el.x, el.y), r, stroke);
          } else {
            canvas.drawCircle(toPx(el.x, el.y), r, fill);
          }
        case HoldoverDot():
          final r = (el.radiusUnits * pxPerUnit).clamp(0.6, 8.0);
          canvas.drawCircle(toPx(el.x, el.y), r, fill);
        case FloatingNumber():
          // Convert label only if display unit differs from native unit.
          final native = reticle.nativeUnit;
          final asMoa = displayUnit.toLowerCase() == 'moa';
          final asMil = displayUnit.toLowerCase() == 'mil';
          final shouldConvert =
              (asMoa && native == ReticleNativeUnit.mil) ||
                  (asMil && native == ReticleNativeUnit.moa);
          final asDouble = double.tryParse(el.text);
          final label = (shouldConvert && asDouble != null)
              ? convertReticleUnit(
                  value: asDouble,
                  from: native,
                  to: asMoa
                      ? ReticleNativeUnit.moa
                      : ReticleNativeUnit.mil,
                ).toStringAsFixed(0)
              : el.text;
          final fs = (el.fontSizeUnits * pxPerUnit).clamp(8.0, 24.0);
          final tp = TextPainter(
            text: TextSpan(
              text: label,
              style: TextStyle(
                color: lineColor,
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

    // Aim-point indicator. Draws a small open ring around the reticle's
    // (0, 0) when the caller passed an explicit aim point that differs
    // noticeably from the geometric center. Lets the user see where the
    // crosshair is sitting on the target plot in Range Day.
    if (aimPoint != null) {
      final geomCenter = Offset(size.width / 2, size.height / 2);
      if ((aimPoint! - geomCenter).distance > 1.0) {
        canvas.drawCircle(
          aimPoint!,
          4.0,
          Paint()
            ..color = lineColor.withValues(alpha: 0.6)
            ..strokeWidth = 1.0
            ..style = PaintingStyle.stroke,
        );
      }
    }

    if (showUnitOverlay) {
      _drawUnitOverlay(canvas, size);
    }
  }

  void _drawUnitOverlay(Canvas canvas, Size size) {
    // Skip the overlay if the canvas is too small to fit it without
    // overlapping the reticle.
    if (size.shortestSide < 90) return;
    final unitLabel = displayUnit.toUpperCase();
    final planeLabel = switch (reticle.type) {
      ReticleType.firstFocalPlane => 'FFP',
      ReticleType.secondFocalPlane => 'SFP',
      ReticleType.fixed => 'FIXED',
    };
    final tp = TextPainter(
      text: TextSpan(
        text: '$unitLabel @ $planeLabel',
        style: TextStyle(
          color: lineColor.withValues(alpha: 0.7),
          fontSize: 10,
          fontWeight: FontWeight.w500,
          letterSpacing: 0.5,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    tp.paint(canvas, const Offset(8, 6));
  }

  @override
  bool shouldRepaint(covariant _ReticlePainter old) {
    return old.reticle.id != reticle.id ||
        old.displayUnit != displayUnit ||
        old.scale != scale ||
        old.lineColor != lineColor ||
        old.aimPoint != aimPoint ||
        old.showUnitOverlay != showUnitOverlay;
  }
}
