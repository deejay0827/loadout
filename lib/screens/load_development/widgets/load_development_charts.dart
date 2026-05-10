// FILE: lib/screens/load_development/widgets/load_development_charts.dart
//
// ============================================================================
// WHAT THIS FILE DOES
// ============================================================================
// Hand-rolled charts shared by every load-development method-specific
// detail screen (OCW, Audette Ladder, Satterlee, Generic). All charts
// use Flutter's `CustomPaint` directly to keep the dependency surface
// small and to match the visual language of `TrajectoryChart` in
// `lib/screens/ballistics/widgets/trajectory_chart.dart`.
//
// Public widgets:
//   * `LoadDevelopmentXyScatter` — draws (chargeGr, value) points and
//     an optional connecting line. Used by the OCW vertical-vs-charge
//     plot and the Satterlee MV-vs-charge plot.
//   * `LoadDevelopmentBarChart` — vertical bars per charge. Used by
//     the per-charge group-size plot and the per-charge SD plot.
//   * `LoadDevelopmentImpactPlot` — fixed-aspect impact diagram (POA
//     at the centre, X positive right / Y positive UP). Used by the
//     OCW shot-grid card to show all impacts at one charge weight.
//
// Each widget renders an empty-state hint when there's nothing to
// plot, so callers can place them unconditionally without guarding.
//
// ============================================================================
// WHY IT EXISTS IN THE ARCHITECTURE
// ============================================================================
// The legacy `LoadDevelopmentDetailScreen` (the JSON-blob screen)
// inlines its own bar / line painters. The method-specific screens
// added in v31 share these widgets so the visual rhythm stays
// consistent across OCW / Ladder / Satterlee / Generic surfaces and
// so a future fl_chart migration only has to touch one file.
//
// ============================================================================
// WHY THIS IS HARDER THAN IT LOOKS
// ============================================================================
// 1. Y-axis sign convention. On a paper target a positive Y means
//    "above point of aim," but on a Flutter Canvas a positive Y means
//    "down the screen." The painters convert at the boundary so
//    callers can supply data in shooter coordinates (Y up = positive)
//    and the chart still renders correctly.
// 2. Single-point degeneracy. With one (charge, value) point the
//    range span is 0 and the X-axis divisor would be NaN. Each
//    painter falls back to `1.0` for the span when the data has zero
//    range so the point still draws at the left edge.
// 3. Highlight semantics. OCW and Satterlee both want to colour a
//    range of charges as "the recommended flat / plateau" — passed in
//    via `highlightCharges` (a Set<double>) compared after rounding
//    to four places to dodge floating-point equality.
//
// ============================================================================
// WHO CONSUMES THIS FILE
// ============================================================================
// - lib/screens/load_development/ocw_test_screen.dart
// - lib/screens/load_development/ladder_test_screen.dart
// - lib/screens/load_development/satterlee_test_screen.dart
// - lib/screens/load_development/generic_test_screen.dart
//
// ============================================================================
// SIDE EFFECTS
// ============================================================================
// None — pure rendering.

import 'package:flutter/material.dart';

/// Single-series scatter / line chart of (chargeGr, value) pairs.
///
/// Draws each point as a small filled circle. When [drawLine] is true,
/// connects consecutive points with a polyline.
class LoadDevelopmentXyScatter extends StatelessWidget {
  const LoadDevelopmentXyScatter({
    super.key,
    required this.points,
    required this.yAxisLabel,
    this.highlightCharges = const <double>{},
    this.drawLine = true,
    this.height = 220,
    this.emptyMessage,
  });

  /// Points to plot, in (chargeGr, value) order. Caller is responsible
  /// for sorting; we don't sort here so a caller plotting in event
  /// order still works.
  final List<({double chargeGr, double value})> points;

  /// Label rendered to the left of the y-axis (e.g. "Mean Y (in)").
  final String yAxisLabel;

  /// Charge values that should render in the primary brand colour
  /// rather than the muted secondary colour. Compared after rounding
  /// each plotted point's chargeGr to four decimals.
  final Set<double> highlightCharges;

  /// When true (default), draws a polyline through the points.
  final bool drawLine;

  /// Plot area height in logical pixels. Default 220.
  final double height;

  /// Override for the empty-state hint text.
  final String? emptyMessage;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (points.isEmpty) {
      return SizedBox(
        height: height,
        child: Center(
          child: Text(
            emptyMessage ??
                'Log shots with charge and impact to see the chart.',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
              fontStyle: FontStyle.italic,
            ),
            textAlign: TextAlign.center,
          ),
        ),
      );
    }
    return SizedBox(
      height: height,
      child: CustomPaint(
        size: Size.infinite,
        painter: _XyScatterPainter(
          points: points,
          yAxisLabel: yAxisLabel,
          highlightCharges: {for (final c in highlightCharges) _round4(c)},
          drawLine: drawLine,
          gridColor: theme.colorScheme.outline.withValues(alpha: 0.3),
          primary: theme.colorScheme.primary,
          secondary: theme.colorScheme.onSurface.withValues(alpha: 0.55),
          tickStyle: TextStyle(
            fontSize: 10,
            color:
                theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.85),
          ),
          axisLabelStyle: TextStyle(
            fontSize: 10,
            color: theme.colorScheme.onSurfaceVariant,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
    );
  }
}

class _XyScatterPainter extends CustomPainter {
  _XyScatterPainter({
    required this.points,
    required this.yAxisLabel,
    required this.highlightCharges,
    required this.drawLine,
    required this.gridColor,
    required this.primary,
    required this.secondary,
    required this.tickStyle,
    required this.axisLabelStyle,
  });

  final List<({double chargeGr, double value})> points;
  final String yAxisLabel;
  final Set<double> highlightCharges;
  final bool drawLine;
  final Color gridColor;
  final Color primary;
  final Color secondary;
  final TextStyle tickStyle;
  final TextStyle axisLabelStyle;

  @override
  void paint(Canvas canvas, Size size) {
    if (points.isEmpty) return;
    const padLeft = 48.0;
    const padRight = 12.0;
    const padTop = 16.0;
    const padBottom = 32.0;
    final plotW = size.width - padLeft - padRight;
    final plotH = size.height - padTop - padBottom;

    final xs = points.map((p) => p.chargeGr).toList();
    final ys = points.map((p) => p.value).toList();
    final minX = xs.reduce((a, b) => a < b ? a : b);
    final maxX = xs.reduce((a, b) => a > b ? a : b);
    final minY = ys.reduce((a, b) => a < b ? a : b);
    final maxY = ys.reduce((a, b) => a > b ? a : b);
    final spanX = (maxX - minX).abs() < 1e-9 ? 1.0 : (maxX - minX);
    final yPadding = (maxY - minY).abs() < 1e-9 ? 1.0 : (maxY - minY) * 0.15;
    final yLow = minY - yPadding;
    final yHigh = maxY + yPadding;
    final spanY = (yHigh - yLow).abs() < 1e-9 ? 1.0 : (yHigh - yLow);

    final gridPaint = Paint()
      ..color = gridColor
      ..strokeWidth = 1;
    // Y gridlines + labels (4 divisions).
    for (var i = 0; i <= 4; i++) {
      final frac = i / 4.0;
      final y = padTop + plotH * frac;
      canvas.drawLine(
          Offset(padLeft, y), Offset(padLeft + plotW, y), gridPaint);
      final v = yHigh - frac * spanY;
      _drawLabel(
        canvas,
        v.abs() < 100 ? v.toStringAsFixed(2) : v.toStringAsFixed(0),
        Offset(4, y - 7),
        tickStyle,
      );
    }
    // X tick labels at first / mid / last point only — keeps it readable.
    final ticks = <int>[0, points.length ~/ 2, points.length - 1];
    for (final i in {...ticks}) {
      if (i < 0 || i >= points.length) continue;
      final fx = (xs[i] - minX) / spanX;
      final x = padLeft + plotW * fx;
      canvas.drawLine(
        Offset(x, padTop),
        Offset(x, padTop + plotH),
        gridPaint,
      );
      _drawLabel(
        canvas,
        xs[i].toStringAsFixed(xs[i] >= 100 ? 1 : 2),
        Offset(x - 14, padTop + plotH + 4),
        tickStyle,
      );
    }
    // Y-axis label (rotated would be nicer but Canvas rotation adds
    // complexity; place it horizontally above the top tick).
    _drawLabel(
      canvas,
      yAxisLabel,
      Offset(2, 0),
      axisLabelStyle,
    );

    // Polyline.
    if (drawLine) {
      final linePaint = Paint()
        ..color = secondary.withValues(alpha: 0.7)
        ..strokeWidth = 2
        ..style = PaintingStyle.stroke;
      final path = Path();
      for (var i = 0; i < points.length; i++) {
        final fx = (xs[i] - minX) / spanX;
        final fy = (yHigh - ys[i]) / spanY;
        final x = padLeft + plotW * fx;
        final y = padTop + plotH * fy;
        if (i == 0) {
          path.moveTo(x, y);
        } else {
          path.lineTo(x, y);
        }
      }
      canvas.drawPath(path, linePaint);
    }

    // Points.
    for (var i = 0; i < points.length; i++) {
      final fx = (xs[i] - minX) / spanX;
      final fy = (yHigh - ys[i]) / spanY;
      final x = padLeft + plotW * fx;
      final y = padTop + plotH * fy;
      final hot = highlightCharges.contains(_round4(xs[i]));
      final pointPaint = Paint()
        ..color = hot ? primary : secondary.withValues(alpha: 0.85)
        ..style = PaintingStyle.fill;
      canvas.drawCircle(Offset(x, y), hot ? 6 : 4, pointPaint);
    }
  }

  void _drawLabel(Canvas canvas, String s, Offset offset, TextStyle style) {
    final tp = TextPainter(
      text: TextSpan(text: s, style: style),
      textDirection: TextDirection.ltr,
    )..layout();
    tp.paint(canvas, offset);
  }

  @override
  bool shouldRepaint(covariant _XyScatterPainter old) =>
      old.points != points ||
      old.highlightCharges != highlightCharges ||
      old.primary != primary;
}

/// Single-series vertical bar chart of (chargeGr, value) pairs.
class LoadDevelopmentBarChart extends StatelessWidget {
  const LoadDevelopmentBarChart({
    super.key,
    required this.bars,
    required this.yAxisLabel,
    this.highlightCharges = const <double>{},
    this.height = 220,
    this.emptyMessage,
  });

  final List<({double chargeGr, double value})> bars;
  final String yAxisLabel;
  final Set<double> highlightCharges;
  final double height;
  final String? emptyMessage;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (bars.isEmpty) {
      return SizedBox(
        height: height,
        child: Center(
          child: Text(
            emptyMessage ?? 'No data to plot yet.',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
              fontStyle: FontStyle.italic,
            ),
            textAlign: TextAlign.center,
          ),
        ),
      );
    }
    return SizedBox(
      height: height,
      child: CustomPaint(
        size: Size.infinite,
        painter: _BarPainter(
          bars: bars,
          yAxisLabel: yAxisLabel,
          highlightCharges: {for (final c in highlightCharges) _round4(c)},
          gridColor: theme.colorScheme.outline.withValues(alpha: 0.3),
          primary: theme.colorScheme.primary,
          secondary: theme.colorScheme.onSurface.withValues(alpha: 0.45),
          tickStyle: TextStyle(
            fontSize: 10,
            color:
                theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.85),
          ),
          axisLabelStyle: TextStyle(
            fontSize: 10,
            color: theme.colorScheme.onSurfaceVariant,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
    );
  }
}

class _BarPainter extends CustomPainter {
  _BarPainter({
    required this.bars,
    required this.yAxisLabel,
    required this.highlightCharges,
    required this.gridColor,
    required this.primary,
    required this.secondary,
    required this.tickStyle,
    required this.axisLabelStyle,
  });

  final List<({double chargeGr, double value})> bars;
  final String yAxisLabel;
  final Set<double> highlightCharges;
  final Color gridColor;
  final Color primary;
  final Color secondary;
  final TextStyle tickStyle;
  final TextStyle axisLabelStyle;

  @override
  void paint(Canvas canvas, Size size) {
    if (bars.isEmpty) return;
    const padLeft = 48.0;
    const padRight = 12.0;
    const padTop = 16.0;
    const padBottom = 32.0;
    final plotW = size.width - padLeft - padRight;
    final plotH = size.height - padTop - padBottom;

    final values = bars.map((b) => b.value).toList();
    final maxV = values.reduce((a, b) => a > b ? a : b);
    final minV = 0.0;
    final spanV = (maxV - minV).abs() < 1e-9 ? 1.0 : (maxV - minV);

    final gridPaint = Paint()
      ..color = gridColor
      ..strokeWidth = 1;
    // Y gridlines + labels (4 divisions).
    for (var i = 0; i <= 4; i++) {
      final frac = i / 4.0;
      final y = padTop + plotH * (1 - frac);
      canvas.drawLine(
          Offset(padLeft, y), Offset(padLeft + plotW, y), gridPaint);
      final v = minV + frac * spanV;
      _drawLabel(
        canvas,
        v < 100 ? v.toStringAsFixed(1) : v.toStringAsFixed(0),
        Offset(4, y - 7),
        tickStyle,
      );
    }
    _drawLabel(canvas, yAxisLabel, Offset(2, 0), axisLabelStyle);

    // Bars.
    final stride = plotW / bars.length;
    final barW = stride * 0.7;
    final gap = (stride - barW) / 2;
    for (var i = 0; i < bars.length; i++) {
      final left = padLeft + stride * i + gap;
      final h = plotH * (bars[i].value / spanV);
      final hot = highlightCharges.contains(_round4(bars[i].chargeGr));
      final paint = Paint()
        ..color = hot ? primary : secondary.withValues(alpha: 0.5)
        ..style = PaintingStyle.fill;
      final rect = Rect.fromLTWH(left, padTop + plotH - h, barW, h);
      canvas.drawRRect(
        RRect.fromRectAndRadius(rect, const Radius.circular(2)),
        paint,
      );
      _drawLabel(
        canvas,
        bars[i].chargeGr.toStringAsFixed(2),
        Offset(left + barW / 2 - 14, padTop + plotH + 4),
        tickStyle,
      );
    }
  }

  void _drawLabel(Canvas canvas, String s, Offset offset, TextStyle style) {
    final tp = TextPainter(
      text: TextSpan(text: s, style: style),
      textDirection: TextDirection.ltr,
    )..layout();
    tp.paint(canvas, offset);
  }

  @override
  bool shouldRepaint(covariant _BarPainter old) =>
      old.bars != bars ||
      old.highlightCharges != highlightCharges ||
      old.primary != primary;
}

/// Fixed-aspect impact diagram. Renders point-of-aim as crosshairs at
/// the centre and each impact as a small dot. Useful for visualising
/// the per-charge shot grid in OCW.
class LoadDevelopmentImpactPlot extends StatelessWidget {
  const LoadDevelopmentImpactPlot({
    super.key,
    required this.impacts,
    required this.extentIn,
    this.height = 220,
    this.label,
  });

  /// Impacts in shooter coordinates (X positive right, Y positive UP),
  /// inches relative to point of aim.
  final List<({double xIn, double yIn})> impacts;

  /// Half-extent of the plot in inches (i.e. the plot covers
  /// `[-extentIn, +extentIn]` on both axes). Caller decides; typically
  /// the largest abs coordinate plus a margin.
  final double extentIn;

  final double height;
  final String? label;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SizedBox(
      height: height,
      child: CustomPaint(
        size: Size.infinite,
        painter: _ImpactPainter(
          impacts: impacts,
          extentIn: extentIn,
          axisColor: theme.colorScheme.outline.withValues(alpha: 0.4),
          centerColor: theme.colorScheme.onSurface.withValues(alpha: 0.55),
          dotColor: theme.colorScheme.primary,
          tickStyle: TextStyle(
            fontSize: 9,
            color:
                theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.85),
          ),
          label: label,
          labelStyle: TextStyle(
            fontSize: 11,
            color: theme.colorScheme.onSurfaceVariant,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
    );
  }
}

class _ImpactPainter extends CustomPainter {
  _ImpactPainter({
    required this.impacts,
    required this.extentIn,
    required this.axisColor,
    required this.centerColor,
    required this.dotColor,
    required this.tickStyle,
    required this.labelStyle,
    this.label,
  });

  final List<({double xIn, double yIn})> impacts;
  final double extentIn;
  final Color axisColor;
  final Color centerColor;
  final Color dotColor;
  final TextStyle tickStyle;
  final TextStyle labelStyle;
  final String? label;

  @override
  void paint(Canvas canvas, Size size) {
    final extent = extentIn <= 0 ? 1.0 : extentIn;
    // Square plot centred horizontally — keeps X / Y proportional.
    final side = size.shortestSide - 32;
    final left = (size.width - side) / 2;
    final top = (size.height - side) / 2;
    final centre = Offset(left + side / 2, top + side / 2);

    // Border + crosshairs.
    final framePaint = Paint()
      ..color = axisColor
      ..strokeWidth = 1
      ..style = PaintingStyle.stroke;
    canvas.drawRect(Rect.fromLTWH(left, top, side, side), framePaint);
    final crossPaint = Paint()
      ..color = centerColor
      ..strokeWidth = 1;
    canvas.drawLine(
        Offset(left, centre.dy), Offset(left + side, centre.dy), crossPaint);
    canvas.drawLine(
        Offset(centre.dx, top), Offset(centre.dx, top + side), crossPaint);

    // Axis tick labels: -extent / 0 / +extent on X and Y.
    String tickLabel(double v) =>
        v == 0 ? '0' : (v > 0 ? '+' : '') + v.toStringAsFixed(1);
    _drawLabel(
      canvas,
      tickLabel(-extent),
      Offset(left - 8, centre.dy + 2),
      tickStyle,
    );
    _drawLabel(
      canvas,
      tickLabel(extent),
      Offset(left + side - 6, centre.dy + 2),
      tickStyle,
    );
    _drawLabel(
      canvas,
      tickLabel(extent),
      Offset(centre.dx + 4, top - 4),
      tickStyle,
    );
    _drawLabel(
      canvas,
      tickLabel(-extent),
      Offset(centre.dx + 4, top + side - 12),
      tickStyle,
    );

    // Impacts.
    final dotPaint = Paint()
      ..color = dotColor
      ..style = PaintingStyle.fill;
    for (final p in impacts) {
      // Convert shooter-Y (positive up) → screen-Y (positive down).
      final fx = (p.xIn / extent).clamp(-1.0, 1.0);
      final fy = (-p.yIn / extent).clamp(-1.0, 1.0);
      final x = centre.dx + fx * side / 2;
      final y = centre.dy + fy * side / 2;
      canvas.drawCircle(Offset(x, y), 4, dotPaint);
    }

    if (label != null) {
      _drawLabel(canvas, label!, Offset(left, top + side + 4), labelStyle);
    }
  }

  void _drawLabel(Canvas canvas, String s, Offset offset, TextStyle style) {
    final tp = TextPainter(
      text: TextSpan(text: s, style: style),
      textDirection: TextDirection.ltr,
    )..layout();
    tp.paint(canvas, offset);
  }

  @override
  bool shouldRepaint(covariant _ImpactPainter old) =>
      old.impacts != impacts ||
      old.extentIn != extentIn ||
      old.dotColor != dotColor ||
      old.label != label;
}

double _round4(double v) => (v * 10000).roundToDouble() / 10000;
