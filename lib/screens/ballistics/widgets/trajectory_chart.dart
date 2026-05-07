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
      return const SizedBox(height: 220);
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          height: 220,
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
  });

  final List<TrajectorySample> samples;
  final Color gridColor;
  final Color dropColor;
  final Color windColor;
  final TextStyle labelStyle;

  @override
  void paint(Canvas canvas, Size size) {
    if (samples.isEmpty) return;

    const padLeft = 36.0;
    const padRight = 12.0;
    const padTop = 12.0;
    const padBottom = 22.0;

    final plotW = size.width - padLeft - padRight;
    final plotH = size.height - padTop - padBottom;

    final maxRange = samples.last.rangeYards;
    final minRange = 0.0;

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

    // Grid lines.
    final gridPaint = Paint()
      ..color = gridColor
      ..strokeWidth = 1;
    const gridSteps = 4;
    for (var i = 0; i <= gridSteps; i++) {
      final y = padTop + plotH * i / gridSteps;
      canvas.drawLine(
        Offset(padLeft, y),
        Offset(padLeft + plotW, y),
        gridPaint,
      );
    }
    for (var i = 0; i <= gridSteps; i++) {
      final x = padLeft + plotW * i / gridSteps;
      canvas.drawLine(
        Offset(x, padTop),
        Offset(x, padTop + plotH),
        gridPaint,
      );
    }

    Offset toPlot(double range, double value) {
      final fx = (range - minRange) / (maxRange - minRange);
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

    // Y-axis labels.
    final yLabel0 = '0"';
    final yLabelMax = '${yMax.toStringAsFixed(0)}"';
    _drawLabel(canvas, yLabel0, Offset(2, padTop - 6), labelStyle);
    _drawLabel(
        canvas, yLabelMax, Offset(2, padTop + plotH - 6), labelStyle);

    // X-axis labels.
    final xLabel0 = '0';
    final xLabelMax = '${maxRange.toStringAsFixed(0)} yd';
    _drawLabel(canvas, xLabel0,
        Offset(padLeft - 4, padTop + plotH + 4), labelStyle);
    _drawLabel(
        canvas, xLabelMax,
        Offset(padLeft + plotW - 32, padTop + plotH + 4), labelStyle);
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
