// FILE: lib/screens/range_day/widgets/target_plot.dart
//
// Visual target widget for the Range Day workspace. Renders the chosen
// target (paper / steel / silhouette) at its real aspect ratio inside a
// box, with each recorded `ShotImpactRow` drawn as a small dot at the
// stored normalized (-1..1, -1..1) position.
//
// Two tap modes (selected by the parent via [tapMode]):
//
//   * `TargetPlotTapMode.aimPoint` — taps move the aim marker via
//     [onAimPointSet]. The marker renders as a small crosshair at the
//     normalized (-1..1, -1..1) location stored on the session row.
//   * `TargetPlotTapMode.recordShot` — taps register a new impact via
//     [onTapAt] (existing behaviour).
//
// When a [reticle] is provided, the renderer paints a [ReticleRenderer]
// overlay anchored on the aim marker (or target center if no aim point
// is set). The reticle visualizes "what the user should see through their
// scope when correctly aimed" — useful for picking the right holdover.
//
// The widget does NOT persist anything itself — it's stateless display +
// gesture detection. The parent screen owns the database side.

import 'package:flutter/material.dart';

import '../../../data/reticle_library.dart';
import '../../../database/database.dart';
import '../../../widgets/reticle_renderer.dart';

/// Two interaction modes for the target plot.
enum TargetPlotTapMode {
  /// Tap moves the aim marker.
  aimPoint,

  /// Tap records a new shot impact (legacy behaviour).
  recordShot,
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

class TargetPlot extends StatelessWidget {
  const TargetPlot({
    super.key,
    required this.target,
    required this.shots,
    required this.onTapAt,
    required this.onLongPressShot,
    this.tapMode = TargetPlotTapMode.recordShot,
    this.aimPointX,
    this.aimPointY,
    this.onAimPointSet,
    this.reticle,
    this.reticleDisplayUnit = 'mil',
  });

  /// Target geometry / color.
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

  /// Aim point in normalized coords; null means no aim placed yet.
  final double? aimPointX;
  final double? aimPointY;

  /// Called in [TargetPlotTapMode.aimPoint] mode when the user taps
  /// inside the target area to (re)place the aim marker.
  final void Function(double normX, double normY)? onAimPointSet;

  /// Optional reticle to render as an overlay on the aim point.
  final ReticleDefinition? reticle;

  /// 'mil' or 'moa' — passed through to the reticle renderer for the
  /// floating-number labels.
  final String reticleDisplayUnit;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AspectRatio(
      aspectRatio: target.widthIn / target.heightIn,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final size = Size(constraints.maxWidth, constraints.maxHeight);
          // Pixel position of the aim marker (used both by the painter
          // for the marker and by the reticle overlay).
          Offset? aimPx;
          if (aimPointX != null && aimPointY != null) {
            aimPx = _normalizedToOffset(aimPointX!, aimPointY!, size);
          }
          return GestureDetector(
            onTapDown: (details) =>
                _handleTap(details.localPosition, size),
            onLongPressStart: (details) =>
                _handleLongPress(details.localPosition, size),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: Stack(
                children: [
                  CustomPaint(
                    size: size,
                    painter: _TargetPainter(
                      target: target,
                      shots: shots,
                      aimPointX: aimPointX,
                      aimPointY: aimPointY,
                      outlineColor: theme.colorScheme.outline,
                      primary: theme.colorScheme.primary,
                      errorColor: theme.colorScheme.error,
                      textColor: theme.colorScheme.onSurface,
                      backgroundColor:
                          theme.colorScheme.surfaceContainerLowest,
                    ),
                  ),
                  // Reticle overlay anchored to the aim marker. When no
                  // aim point is set, the overlay sits at the geometric
                  // center of the target.
                  if (reticle != null)
                    IgnorePointer(
                      // ignore taps so they reach the gesture detector.
                      child: ReticleRenderer(
                        reticle: reticle!,
                        displayUnit: reticleDisplayUnit,
                        scale: 0.75,
                        color: theme.colorScheme.tertiary,
                        aimPoint:
                            aimPx ?? Offset(size.width / 2, size.height / 2),
                        size: size,
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

  void _handleTap(Offset localPos, Size size) {
    final norm = _toNormalized(localPos, size);
    if (norm == null) return;
    if (tapMode == TargetPlotTapMode.aimPoint) {
      final cb = onAimPointSet;
      if (cb != null) cb(norm.dx, norm.dy);
    } else {
      onTapAt(norm.dx, norm.dy);
    }
  }

  /// Convert normalized (-1..1, -1..1) to widget-local pixel coords with
  /// the same flip applied by the painter (top = small y).
  Offset _normalizedToOffset(double nx, double ny, Size size) {
    final cx = size.width / 2;
    final cy = size.height / 2;
    return Offset(cx + nx * cx, cy - ny * cy);
  }

  void _handleLongPress(Offset localPos, Size size) {
    final norm = _toNormalized(localPos, size);
    if (norm == null) return;
    // Find the closest shot within a generous touch radius and surface it
    // up. We compare in NORMALIZED units so the test is consistent across
    // different render sizes.
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
  /// (-1..1, -1..1) coordinates. Returns null if the tap is outside the
  /// rendered target area (we don't want to record a shot if the user
  /// tapped the gutter).
  Offset? _toNormalized(Offset localPos, Size size) {
    final cx = size.width / 2;
    final cy = size.height / 2;
    final nx = (localPos.dx - cx) / cx;
    // Flip Y so +1 = top, -1 = bottom (matches shooter's mental model).
    final ny = -(localPos.dy - cy) / cy;
    if (nx < -1 || nx > 1 || ny < -1 || ny > 1) return null;
    return Offset(nx, ny);
  }
}

/// Custom painter that draws the target shape and overlays shot dots.
class _TargetPainter extends CustomPainter {
  _TargetPainter({
    required this.target,
    required this.shots,
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
    canvas.drawRect(
      Offset.zero & size,
      Paint()..color = backgroundColor,
    );

    final fill = Paint()..color = _parseColor(target.colorHex);
    final outline = Paint()
      ..color = outlineColor
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5;

    // Draw the target shape, centered, occupying ~92% of the box so we
    // leave a small margin for the shot dots that fall near the edge.
    const inset = 0.04;
    final rect = Rect.fromLTWH(
      size.width * inset,
      size.height * inset,
      size.width * (1 - 2 * inset),
      size.height * (1 - 2 * inset),
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
      final aimPx = _normalizedToOffset(aimPointX!, aimPointY!, size);
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
      final centre = _normalizedToOffset(shot.impactX, shot.impactY, size);
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

  /// Convert normalized (-1..1, -1..1) to widget-local pixel coordinates,
  /// flipping Y back to the screen convention (top = small y).
  Offset _normalizedToOffset(double nx, double ny, Size size) {
    final cx = size.width / 2;
    final cy = size.height / 2;
    return Offset(cx + nx * cx, cy - ny * cy);
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
