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
//
// ============================================================================
// HOLD-OVER HIGHLIGHTING
// ============================================================================
// When the caller passes a [FiringHoldOver], we paint a filled circle on
// the reticle at the projected (elevationMil, windageMil) coordinate.
// The hold-over is always provided in MIL — we convert internally to the
// reticle's native unit before plotting so the circle lands on whatever
// hash mark a real shooter would use as their hold. Sign convention:
//   * elevationMil > 0  → hold UP (impact below LoS at the range)
//   * windageMil   > 0  → hold RIGHT (wind pushes from the right; the
//                                     shooter holds into the wind)

import 'package:flutter/material.dart';

import '../data/reticle_library.dart';

/// Firing-solution dial that the renderer projects onto the reticle as a
/// hold-over highlight. Both fields are in milliradians; the renderer
/// converts to the reticle's native unit before plotting so a MOA reticle
/// gets the highlight on the right MOA hash.
///
/// Sign convention is "what the shooter is holding for", not the bullet's
/// raw drop / drift:
///   * `elevationMil` positive — hold UP (compensates for bullet drop).
///   * `windageMil`   positive — hold RIGHT (compensates for left-to-right wind).
///
/// Range Day passes the live firing solution into this object after
/// converting the solver's drop / wind drift inches to mils at the active
/// range via [bu.inchesToMilAtYards].
class FiringHoldOver {
  const FiringHoldOver({
    required this.elevationMil,
    required this.windageMil,
  });

  final double elevationMil;
  final double windageMil;

  bool get isZero => elevationMil.abs() < 1e-6 && windageMil.abs() < 1e-6;
}

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
    this.holdOver,
    this.holdOverHighlightColor,
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

  /// When non-null, paint a hold-over highlight at the matching hash on
  /// the reticle. The renderer projects (elevationMil, windageMil) into
  /// the reticle's native units and draws a small filled circle there
  /// — visually telling the shooter "this is the dial / hold the firing
  /// solution is asking for".
  final FiringHoldOver? holdOver;

  /// Override the hold-over highlight color. Defaults to the theme's
  /// secondary at 0.85 alpha so it stands apart from the reticle line
  /// color (which uses primary by default).
  final Color? holdOverHighlightColor;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final lineColor = color ?? theme.colorScheme.primary;
    final highlight = holdOverHighlightColor ??
        theme.colorScheme.secondary.withValues(alpha: 0.85);
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
          holdOver: holdOver,
          holdOverHighlightColor: highlight,
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
    required this.holdOver,
    required this.holdOverHighlightColor,
  });

  final ReticleDefinition reticle;
  final String displayUnit;
  final double scale;
  final Color lineColor;
  final Offset? aimPoint;
  final bool showUnitOverlay;
  final FiringHoldOver? holdOver;
  final Color holdOverHighlightColor;

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

    // Hold-over highlight. The renderer is given the firing solution as
    // (elevationMil, windageMil) — we convert into the reticle's native
    // unit, project to pixel space using the same `pxPerUnit` factor as
    // the elements, and paint a small filled circle there. The shooter
    // sees the matching hash on the reticle "lit up".
    final ho = holdOver;
    if (ho != null) {
      // mil → reticle native unit. For mil reticles this is identity;
      // for MOA reticles we multiply by 3.43775; for IPSC / BDC we treat
      // it as mil-equivalent (those reticles don't have a true angular
      // sub-tension so the highlight ends up plotted at the mil position
      // — best we can do without per-reticle calibration data).
      final milToNative = switch (reticle.nativeUnit) {
        ReticleNativeUnit.mil => 1.0,
        ReticleNativeUnit.moa => milToMoa,
        ReticleNativeUnit.ipsc => 1.0,
        ReticleNativeUnit.bdc => 1.0,
      };
      // Reticle convention: +y up = "hold up" in shooter terms, +x right
      // = "hold right". `elevationMil > 0` means the user holds higher,
      // i.e. the highlight goes ABOVE center (positive native y), which
      // matches the existing reticle layout where holdover hashes sit on
      // the +y axis below the center crosshair when the bullet drops.
      //
      // Wait — the upper half of a precision reticle is the cleared half
      // and the LOWER half (negative y) is where holdover hashes sit (so
      // the crosshair stays clear at ranges where you hold above). To
      // match that, hold-up in elevation corresponds to plotting on the
      // -y side of the reticle (canvas-up, since we flip Y in toPx).
      // That makes the highlight land on the holdover marks the shooter
      // would actually use.
      final holdNativeY = -ho.elevationMil * milToNative;
      final holdNativeX = ho.windageMil * milToNative;
      final pt = toPx(holdNativeX, holdNativeY);
      final r = (size.shortestSide * 0.018).clamp(4.0, 6.5);
      // Soft halo first, then the crisp filled core.
      canvas.drawCircle(
        pt,
        r + 2.5,
        Paint()..color = holdOverHighlightColor.withValues(alpha: 0.25),
      );
      canvas.drawCircle(
        pt,
        r,
        Paint()..color = holdOverHighlightColor,
      );
      // Thin white outline so the dot reads against any reticle color.
      canvas.drawCircle(
        pt,
        r,
        Paint()
          ..color = Colors.white.withValues(alpha: 0.65)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.0,
      );
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
        old.showUnitOverlay != showUnitOverlay ||
        old.holdOver?.elevationMil != holdOver?.elevationMil ||
        old.holdOver?.windageMil != holdOver?.windageMil ||
        old.holdOverHighlightColor != holdOverHighlightColor;
  }
}
