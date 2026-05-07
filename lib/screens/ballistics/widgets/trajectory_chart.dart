// FILE: lib/screens/ballistics/widgets/trajectory_chart.dart
//
// ============================================================================
// WHAT THIS FILE DOES
// ============================================================================
// Renders a small two-line chart visualizing the result of an external
// ballistics solve: a "drop" curve (how far the bullet falls below
// line-of-sight at each range) and a "wind drift" curve (how far the
// bullet is pushed sideways by crosswind), both plotted against range.
//
// `TrajectoryChart` is a `StatelessWidget` that consumes a
// `List<TrajectorySample>` produced by the solver in
// `lib/services/ballistics/solver.dart`. Each `TrajectorySample`
// carries a range (yards), a drop (inches below line-of-sight), a
// wind-drift (inches), plus velocity, energy, time-of-flight, and Mach
// number. The chart only uses the first three.
//
// The widget builds:
//
//   - A 220-pixel-tall `CustomPaint` whose painter is `_ChartPainter`.
//     `CustomPaint` is Flutter's escape hatch into raw 2D drawing —
//     a `CustomPainter` is given a `Canvas` and a `Size` and draws
//     whatever it wants (lines, paths, text). We use it because the
//     chart shapes are simple and the cost of pulling in a charting
//     package would be larger than the painter itself.
//   - A horizontal legend underneath: a small coloured bar + label
//     for each of the two series.
//
// `_ChartPainter.paint(canvas, size)` lays out:
//
//   - Padding (36 left for Y labels, 12 right, 12 top, 22 bottom).
//   - A 4×4 grid of horizontal and vertical guide lines in the
//     theme's outline colour at 30% alpha.
//   - The `dropPath` — a polyline through every sample's
//     (rangeYards, dropInches) plotted with `dropColor` (the brand
//     brass primary) at 2px stroke. Y axis: 0" at the top of the
//     plot, max-drop at the bottom (drop is positive-down by
//     convention, matching how a shooter intuits "the bullet drops").
//   - The `windPath` — only rendered when `maxWind > 0.001` (i.e.
//     non-zero wind input). Same Y scale as drop, in the theme's
//     secondary colour.
//   - Y-axis labels: "0"" at the top, the rounded max-drop value
//     ("48"" or similar) near the bottom.
//   - X-axis labels: "0" at the left, the rounded max-range
//     ("1000 yd") at the right.
//
// `_drawLabel` is a tiny helper that constructs a `TextPainter`,
// lays it out, and paints it at the given offset — the standard
// idiom for drawing text into a `CustomPaint` because `Canvas` itself
// has no drawText method that takes a styled `String`.
//
// ============================================================================
// WHY IT EXISTS IN THE ARCHITECTURE
// ============================================================================
// The `BallisticsScreen` already shows a numeric DOPE table; the chart
// is a quick visual confirmation that the trajectory looks sensible
// before the user trusts the table. Many input mistakes (e.g. using
// G1 BC against a long boattail bullet, or feeding sea-level pressure
// instead of station pressure) produce a curve whose shape is
// obviously wrong even when individual numbers look plausible.
//
// Both curves share a single Y axis. Independent scales for drop vs
// wind would make the relationship between them harder to read, and
// since we only need an at-a-glance shape check rather than precise
// drift comparisons, "let drop dominate the scale and overlay wind on
// the same axis" is the right tradeoff.
//
// ============================================================================
// WHY THIS IS HARDER THAN IT LOOKS
// ============================================================================
// `CustomPainter.shouldRepaint` returns `oldDelegate.samples != samples`.
// That's a reference comparison, not a deep equality — the
// `BallisticsScreen` builds a NEW list every solve, so reference
// inequality is the right signal. If a caller ever started mutating
// the list in place, this would silently fail to repaint.
//
// `yMax.clamp(1.0, double.infinity)` defends against degenerate input
// where every drop value is zero (very short ranges with no gravity
// applied). Without the clamp, the `value / yMax` divide would produce
// NaN.
//
// The wind threshold (`maxWind > 0.001`) suppresses a flat-zero wind
// line that would just sit on the X axis and add visual noise. If the
// user enters zero wind, no wind curve is drawn at all.
//
// ============================================================================
// WHO CONSUMES THIS FILE
// ============================================================================
// - `lib/screens/ballistics/ballistics_screen.dart` — instantiates
//   one `TrajectoryChart(samples: _samples)` in its Output section
//   after a successful solve.
//
// ============================================================================
// SIDE EFFECTS
// ============================================================================
// None — pure rendering. No I/O, no network, no plugin calls. The
// painter draws lines and text into a Canvas; that's it.

import 'package:flutter/material.dart';

import '../../../services/ballistics/solver.dart';

/// Two-curve chart showing trajectory drop and wind drift over range.
class TrajectoryChart extends StatelessWidget {
  const TrajectoryChart({
    super.key,
    required this.samples,
  });

  final List<TrajectorySample> samples;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (samples.isEmpty) {
      return const SizedBox(height: 240);
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          height: 240,
          child: CustomPaint(
            size: Size.infinite,
            painter: _ChartPainter(
              samples: samples,
              gridColor: theme.colorScheme.outline.withValues(alpha: 0.3),
              dropColor: theme.colorScheme.primary,
              windColor: theme.colorScheme.secondary,
              labelStyle: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ) ??
                  const TextStyle(),
              tickLabelStyle: TextStyle(
                fontSize: 9.5,
                color: theme.colorScheme.onSurfaceVariant
                    .withValues(alpha: 0.7),
              ),
            ),
          ),
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 16,
          runSpacing: 6,
          children: [
            _Legend(color: theme.colorScheme.primary, label: 'Drop (in)'),
            _Legend(color: theme.colorScheme.secondary, label: 'Wind drift (in)'),
          ],
        ),
      ],
    );
  }
}

class _Legend extends StatelessWidget {
  const _Legend({required this.color, required this.label});
  final Color color;
  final String label;
  @override
  Widget build(BuildContext context) {
    return Row(mainAxisSize: MainAxisSize.min, children: [
      Container(
        width: 14,
        height: 4,
        decoration: BoxDecoration(
          color: color,
          borderRadius: BorderRadius.circular(2),
        ),
      ),
      const SizedBox(width: 6),
      Text(label, style: Theme.of(context).textTheme.bodySmall),
    ]);
  }
}

class _ChartPainter extends CustomPainter {
  _ChartPainter({
    required this.samples,
    required this.gridColor,
    required this.dropColor,
    required this.windColor,
    required this.labelStyle,
    required this.tickLabelStyle,
  });

  final List<TrajectorySample> samples;
  final Color gridColor;
  final Color dropColor;
  final Color windColor;
  final TextStyle labelStyle;
  final TextStyle tickLabelStyle;

  @override
  void paint(Canvas canvas, Size size) {
    if (samples.isEmpty) return;

    // Generous left padding leaves room for the y-axis tick labels.
    // Bottom padding accommodates the per-100-yd x-axis tick labels plus
    // a small "yd" unit annotation underneath. Right padding keeps the
    // last x-axis tick from clipping against the chart edge.
    const padLeft = 44.0;
    const padRight = 18.0;
    const padTop = 12.0;
    const padBottom = 36.0;

    final plotW = size.width - padLeft - padRight;
    final plotH = size.height - padTop - padBottom;

    // X axis spans from the first sample's range to the last. Historically
    // this was hard-coded to 0, but the Output section now lets the user
    // pick a non-zero Min Yardage; pulling minRange off the samples list
    // keeps the curve filling the plot rather than starting partway across.
    final maxRange = samples.last.rangeYards;
    final minRange = samples.first.rangeYards;
    // Defensive: if minRange == maxRange (single sample) we'd divide by
    // zero in the toPlot() helper. Treat the X axis as a degenerate
    // range and force a tiny denominator so we still render the point.
    final rangeSpan = (maxRange - minRange).abs() < 1e-9
        ? 1.0
        : maxRange - minRange;

    final maxDrop = samples
        .map((s) => s.dropInches)
        .reduce((a, b) => a > b ? a : b);
    final maxWind = samples
        .map((s) => s.windDriftInches.abs())
        .fold<double>(0, (a, b) => a > b ? a : b);

    // Combined Y axis (independent scales for drop vs wind would be
    // confusing — we let drop dominate but offer wind on the same
    // scale so the relationship between them is clear).
    final yMax = maxDrop.clamp(1.0, double.infinity);

    final gridPaint = Paint()
      ..color = gridColor
      ..strokeWidth = 1;

    // X tick spacing: every 100 yd by default, every 200 yd past 1000 yd
    // to keep the labels from crowding.
    final xTickSpacing = maxRange > 1000 ? 200.0 : 100.0;

    // Horizontal gridlines + intermediate y-axis tick labels. Drawing 4
    // lines (0, 33%, 66%, 100%) lets the user read off rough drop values
    // without an axis legend. Drop is displayed as a negative inch value
    // because that's how shooters refer to it ("the bullet is 200" low").
    const yDivisions = 3;
    for (var i = 0; i <= yDivisions; i++) {
      final frac = i / yDivisions;
      final y = padTop + plotH * frac;
      canvas.drawLine(
        Offset(padLeft, y),
        Offset(padLeft + plotW, y),
        gridPaint,
      );
      final inchesAtTick = -(yMax * frac);
      final label =
          inchesAtTick == 0 ? '0' : '${inchesAtTick.toStringAsFixed(0)}"';
      _drawLabel(
        canvas,
        label,
        Offset(2, y - 7),
        tickLabelStyle,
      );
    }

    // Vertical gridlines + tick labels at each xTickSpacing yard mark.
    // First tick is the smallest multiple of xTickSpacing strictly greater
    // than minRange (so we don't double-stack with the explicit min-range
    // label below). End at the last multiple at or before maxRange.
    final firstTick =
        ((minRange / xTickSpacing).floorToDouble() + 1) * xTickSpacing;
    for (var v = firstTick; v <= maxRange + 0.0001; v += xTickSpacing) {
      final fx = (v - minRange) / rangeSpan;
      final x = padLeft + plotW * fx;
      canvas.drawLine(
        Offset(x, padTop),
        Offset(x, padTop + plotH),
        gridPaint,
      );
      // Tick label centred under the gridline; clamp the x offset so the
      // last label can't overflow off the right edge.
      final tp = TextPainter(
        text: TextSpan(text: v.toStringAsFixed(0), style: tickLabelStyle),
        textDirection: TextDirection.ltr,
        textAlign: TextAlign.center,
      )..layout();
      final labelX = (x - tp.width / 2)
          .clamp(0.0, size.width - tp.width);
      tp.paint(canvas, Offset(labelX, padTop + plotH + 6));
    }

    // Min-range tick at the y-axis baseline. When minRange is 0 this just
    // says "0"; for non-zero starts (e.g. 200-yd ladder) it shows the
    // actual starting yardage so the user isn't left guessing.
    {
      final minLabel = minRange == 0
          ? '0'
          : minRange.toStringAsFixed(0);
      final tp = TextPainter(
        text: TextSpan(text: minLabel, style: tickLabelStyle),
        textDirection: TextDirection.ltr,
        textAlign: TextAlign.center,
      )..layout();
      tp.paint(canvas, Offset(padLeft - tp.width / 2, padTop + plotH + 6));
    }

    // "yd" unit annotation centred below the x-axis ticks.
    {
      final tp = TextPainter(
        text: TextSpan(text: 'yd', style: tickLabelStyle),
        textDirection: TextDirection.ltr,
        textAlign: TextAlign.center,
      )..layout();
      tp.paint(
        canvas,
        Offset(padLeft + plotW / 2 - tp.width / 2, padTop + plotH + 20),
      );
    }

    Offset toPlot(double range, double value) {
      final fx = (range - minRange) / rangeSpan;
      final fy = (value / yMax).clamp(-1.0, 1.0);
      return Offset(padLeft + plotW * fx, padTop + plotH * fy);
    }

    // Drop curve (downward = positive Y on screen since drop > 0).
    final dropPath = Path();
    for (var i = 0; i < samples.length; i++) {
      final p = toPlot(samples[i].rangeYards, samples[i].dropInches);
      if (i == 0) {
        dropPath.moveTo(p.dx, p.dy);
      } else {
        dropPath.lineTo(p.dx, p.dy);
      }
    }
    canvas.drawPath(
      dropPath,
      Paint()
        ..color = dropColor
        ..strokeWidth = 2
        ..style = PaintingStyle.stroke,
    );

    // Wind drift — display as offset from zero on the same vertical scale.
    if (maxWind > 0.001) {
      final windPath = Path();
      for (var i = 0; i < samples.length; i++) {
        final p = toPlot(
          samples[i].rangeYards,
          samples[i].windDriftInches,
        );
        if (i == 0) {
          windPath.moveTo(p.dx, p.dy);
        } else {
          windPath.lineTo(p.dx, p.dy);
        }
      }
      canvas.drawPath(
        windPath,
        Paint()
          ..color = windColor
          ..strokeWidth = 2
          ..style = PaintingStyle.stroke,
      );
    }
  }

  void _drawLabel(
      Canvas canvas, String text, Offset offset, TextStyle style) {
    final tp = TextPainter(
      text: TextSpan(text: text, style: style),
      textDirection: TextDirection.ltr,
      textAlign: TextAlign.left,
    )..layout();
    tp.paint(canvas, offset);
  }

  @override
  bool shouldRepaint(covariant _ChartPainter oldDelegate) {
    return oldDelegate.samples != samples;
  }
}
