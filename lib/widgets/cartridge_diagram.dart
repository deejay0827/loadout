// FILE: lib/widgets/cartridge_diagram.dart
//
// ============================================================================
// WHAT THIS FILE DOES
// ============================================================================
// Renders the side-profile drawing that appears on the SAAMI screen when
// the user picks a cartridge. Two flavors:
//
//   - `DiagramMode.cartridge` — the loaded round (case + bullet seated to
//     max COAL).
//   - `DiagramMode.chamber`   — the chamber the round fits into (same
//     case shape minus the bullet, plus a small freebore lip past the
//     case mouth).
//
// Implementation strategy: pure `CustomPaint` over a `CustomPainter`. No
// raster assets are bundled — every line is drawn at runtime from the
// numeric SAAMI/CIP fields on the `CartridgeRow` (case length, body
// diameter, neck diameter, shoulder angle, rim diameter, rim thickness,
// primer type, etc.). That keeps the app binary tiny while letting the
// drawing scale crisply on every device.
//
// Public API (`CartridgeDiagram`):
//   - `cartridge` — the drift `CartridgeRow` from the cartridges table.
//   - `mode`      — `DiagramMode.cartridge` (default) or `.chamber`.
//   - `height`    — target height in logical pixels; width is taken from
//                    the parent. Default 200.
//
// Top-level dispatch in `build()`:
//   - Shotguns get their own simple silhouette via `_ShotshellDiagramPainter`
//     (rim/headspace shape doesn't apply; what matters is gauge + shell
//     length).
//   - Pistol/rifle cartridges flow into `_CartridgeDiagramPainter`. Need
//     at minimum case length + body diameter + bullet diameter to draw
//     anything meaningful; missing those triggers `_Placeholder`.
//
// `_Placeholder` shows a dashed rounded rectangle with an italicized
// "Diagram unavailable" hint. The dashed border is itself a custom
// painter (`_DashedBorderPainter`) that walks the path metrics and
// alternates `extractPath` segments with gaps.
//
// `_CartridgeDiagramPainter` is the heart of the file. Its `paint`
// method does, in order:
//   1. Pulls every dimensional field from the row and decides which are
//      present (rim thickness and shoulder angle are optional).
//   2. Computes the longest dimension (`overall`) and the largest
//      diameter (`maxDia`), then derives a uniform pixel-per-inch
//      `scale` so the whole drawing fits inside the available canvas
//      minus margins. The left margin is wider than the right because
//      it has to hold the rim-diameter callout.
//   3. Builds the TOP HALF of the silhouette as a `Path`, going
//      left-to-right: rim → body → shoulder taper → neck → mouth, then
//      either the bullet ogive (cartridge mode) or a freebore lip
//      (chamber mode). The shoulder taper uses the actual shoulder
//      angle when available; otherwise it falls back to using neck
//      length as a proxy for taper end.
//   4. Mirrors that top-half path across the centerline using the
//      `_mirrorAcross` 4x4 matrix, draws fill + stroke, and overlays a
//      thin dashed centerline.
//   5. Draws all the dimension callouts: case length on top, max COAL on
//      bottom, body / shoulder-angle / neck inline labels, RIM DIAMETER
//      vertical callout on the far left, RIM THICKNESS horizontal
//      callout below the rim, primer-pocket dot + primer-type label,
//      and (cartridge mode) bullet diameter on the right or (chamber
//      mode) bore + groove diameters on the right.
//
// `_ShotshellDiagramPainter` is the simpler partner. Shotshells are
// approximated as two rounded rectangles (brass head + plastic hull)
// with a vertical crimp tick at the mouth. Bore diameter for non-.410
// gauges comes from the gauge formula `bore ≈ 1.67 / gauge^(1/3)`,
// .410 is special-cased as 0.410".
//
// Shared private helpers used by `_CartridgeDiagramPainter`:
//   - `_drawHorizontalDimension` — full callout (line + brackets +
//      arrowheads + label, above or below).
//   - `_drawVerticalDimension`   — same idea, vertical, with the label
//      rotated 90° so it reads bottom-to-top.
//   - `_drawArrow`               — tiny triangular arrowhead at the
//      end of a dimension line.
//   - `_drawDiameterLabel`       — single text label, no line.
//   - `_drawDashedLine`          — used for the centerline.
//   - `_humanPrimer`             — converts seed-data primer keys
//      (`small-rifle`, `large-pistol`, …) to display strings
//      (`Small Rifle`, `Large Pistol`).
//   - `_mirrorAcross(y)`         — returns a `Float64List` shaped like
//      a 4×4 column-major matrix that flips coordinates around the
//      horizontal line `y`. `Path.transform` insists on this exact
//      shape; you cannot pass a `Matrix4` directly.
//   - `_formatLength` / `_formatDiameter` — adaptive precision (length
//      always 3 decimals, diameter 2 if ≥ 0.5", 3 otherwise).
//
// ============================================================================
// WHY IT EXISTS IN THE ARCHITECTURE
// ============================================================================
// The SAAMI screen wants to be the in-app substitute for SAAMI's PDF
// drawings. PDFs are large, copyrighted, and impossible to re-style for
// dark mode or different screen sizes. Rendering from numeric dimension
// fields gives us:
//
//   - A drawing that scales perfectly to any device.
//   - Theme-aware coloring (the stroke is the LoadOut brass color, the
//     text uses the active text-on-surface color).
//   - Zero binary footprint per cartridge.
//   - The freedom to pick which dimensions to emphasize. SAAMI drawings
//     commit equal visual weight to every callout; the LoadOut diagram
//     deliberately calls out RIM DIAMETER and RIM THICKNESS prominently
//     because reloaders care about head/rim dimensions more than
//     anything else. Bolt-face fit, headspace, and pressure-ring
//     expansion all hinge on rim geometry. Marketing dimensions that
//     don't help the reloader (overall length labels in mm, etc.) get
//     dropped.
//
// The widget reads only from a `CartridgeRow` instance, so callers can
// hand it fresh rows from the seeded reference table or hypothetically
// hydrated rows from an unsaved cartridge. There is no I/O inside
// `paint`.
//
// ============================================================================
// WHY THIS IS HARDER THAN IT LOOKS
// ============================================================================
// 1. SCALING TO TWO BUDGETS AT ONCE. The diagram must fit both the
//    horizontal budget (`overall`, the longest dimension) and the
//    vertical budget (`maxDia`, the widest cross-section). We compute
//    `scale = min(scaleByLen, scaleByDia)` so neither axis ever overflows.
//    Calling either budget independently produces a clipped or
//    distorted drawing.
// 2. PATH.TRANSFORM TAKES Float64List, NOT Matrix4. Flutter's
//    `Path.transform` is implemented around a column-major 4x4 matrix
//    represented as a flat `Float64List(16)`. You can hand it a Matrix4
//    by calling `.storage`, but a hand-built one is more explicit. The
//    mirror matrix is mostly identity, with `m[5] = -1` (flip y) and
//    `m[13] = 2y` (re-translate so the line `y` is fixed). Get either
//    one wrong and the bottom half ends up flipped about the wrong
//    axis or shifted off-canvas.
// 3. SHOULDER-ANGLE GEOMETRY. Many cartridge rows have a shoulder angle
//    in degrees but no explicit base-to-neck length. We compute the
//    horizontal taper length from the radial step and the angle:
//    `taperLen = ((shoulderDia - neckDia) / 2) / tan(angle)`. Some rows
//    lack the angle entirely (the older seed dataset), so we fall back
//    to using `neckLen` as a proxy when present, or a worst-case
//    "shoulderDia - neckDia" if even that's missing. Without the
//    fallbacks the path collapses to a vertical jump at the shoulder.
// 4. NULL-SAFETY VS. NULLABLE FIELDS. Dart's flow-analysis only
//    promotes a nullable to non-null inside the same scope where the
//    null check happens, and only against final variables. We assign
//    `shoulderDia`, `neckDia`, `baseToShoulder`, etc. to local `final`
//    references at the top of `paint`, then test `hasShoulder` once and
//    let the analyzer promote those locals everywhere `hasShoulder` is
//    true. Doing the null checks in-line at each use site would force
//    bang operators (`!`) on every dereference.
// 5. STRAIGHT-WALL VS. BOTTLENECK. `caseSubtype == 'straight'`
//    short-circuits the shoulder logic — straight-wall pistol cases
//    (`.45 ACP`, `.38 Spl`) don't have a shoulder, just body straight
//    to mouth.
// 6. CHAMBER MODE EXTRA. Chambers extend slightly past the case mouth
//    to model the freebore (the throat ahead of the rifling). We add
//    `+0.05"` of extra length and cap the silhouette there with a
//    short vertical drop down to the centerline.
// 7. DIMENSION-LABEL OVERLAP. The horizontal margins (`labelTop = 28`,
//    `labelBottom = 32`, `labelLeft = 56`, `labelRight = 80`) were
//    tuned by eye. They reserve enough space for the largest expected
//    label (the vertical rim-diameter callout, which has rotated text)
//    without leaving the silhouette tiny.
// 8. SHOTSHELLS ARE A DIFFERENT BEAST. Gauges aren't expressed as a
//    diameter — they're a count (12-gauge = 12 lead balls of bore
//    diameter weigh one pound). We back the bore out from the gauge
//    formula and special-case .410. Shotshells also lack rim
//    geometry that matters for the reloader the way rifle / pistol
//    rim geometry does, so the painter is far simpler.
//
// ============================================================================
// WHO CONSUMES THIS FILE
// ============================================================================
// - lib/screens/saami/saami_screen.dart — the SAAMI lookup screen renders
//   one diagram in cartridge mode and one in chamber mode side-by-side
//   (or stacked on narrow screens) per selected cartridge.
//
// ============================================================================
// SIDE EFFECTS
// ============================================================================
// - None. `paint` is a pure function of the `CartridgeRow` it was given
//   and the available canvas size. No I/O, no SharedPreferences, no
//   network.

import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../database/database.dart';

/// What to draw inside the [CartridgeDiagram].
enum DiagramMode {
  /// The loaded cartridge silhouette (case + bullet).
  cartridge,

  /// The chamber the cartridge fits into (similar shape with a slight
  /// freebore allowance, no bullet).
  chamber,
}

/// Draws a side-profile cartridge or chamber to scale, sized to the available
/// width. Renders entirely from numeric SAAMI/CIP fields on [cartridge] —
/// nothing is bundled from the SAAMI drawings themselves.
///
/// If the essential dimensional fields aren't available on this cartridge
/// row, renders a dashed-border placeholder explaining what's missing.
class CartridgeDiagram extends StatelessWidget {
  const CartridgeDiagram({
    super.key,
    required this.cartridge,
    this.mode = DiagramMode.cartridge,
    this.height = 200,
  });

  final CartridgeRow cartridge;
  final DiagramMode mode;

  /// Target height of the diagram. Width is taken from the parent.
  final double height;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final type = cartridge.type;

    // Shotguns get their own simple silhouette (gauge + shell length).
    if (type == 'shotgun') {
      final hasShotgunData =
          cartridge.gauge != null && cartridge.shellLengthIn != null;
      if (!hasShotgunData) {
        return _Placeholder(theme: theme, height: height);
      }
      return SizedBox(
        height: height,
        child: CustomPaint(
          painter: _ShotshellDiagramPainter(
            cartridge: cartridge,
            mode: mode,
            stroke: const Color(0xFFC5A572),
            fill: const Color(0xFFC5A572).withValues(alpha: 0.18),
            label: const Color(0xFFC5A572).withValues(alpha: 0.85),
            textColor: theme.colorScheme.onSurface,
          ),
        ),
      );
    }

    // Pistol/rifle path. Need at minimum a case length, a body diameter and
    // bullet diameter to draw something meaningful.
    final hasCore = cartridge.caseLengthIn != null &&
        cartridge.bodyDiameterIn != null &&
        cartridge.bulletDiameterIn != null;
    if (!hasCore) {
      return _Placeholder(theme: theme, height: height);
    }

    return SizedBox(
      height: height,
      child: CustomPaint(
        painter: _CartridgeDiagramPainter(
          cartridge: cartridge,
          mode: mode,
          stroke: const Color(0xFFC5A572),
          fill: const Color(0xFFC5A572).withValues(alpha: 0.18),
          label: const Color(0xFFC5A572).withValues(alpha: 0.85),
          textColor: theme.colorScheme.onSurface,
        ),
      ),
    );
  }
}

class _Placeholder extends StatelessWidget {
  const _Placeholder({required this.theme, required this.height});

  final ThemeData theme;
  final double height;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: height,
      child: CustomPaint(
        painter: _DashedBorderPainter(
          color: theme.colorScheme.outline.withValues(alpha: 0.5),
        ),
        child: Center(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24),
            child: Text(
              'Diagram unavailable — additional SAAMI dimensions '
              'needed for this cartridge.',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
                fontStyle: FontStyle.italic,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Dashed rounded-rectangle border for the placeholder state.
class _DashedBorderPainter extends CustomPainter {
  _DashedBorderPainter({required this.color});

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1;
    final rrect = RRect.fromRectAndRadius(
      Rect.fromLTWH(0.5, 0.5, size.width - 1, size.height - 1),
      const Radius.circular(12),
    );
    final path = Path()..addRRect(rrect);
    final dashPath = _dashed(path, dashLength: 6, gapLength: 4);
    canvas.drawPath(dashPath, paint);
  }

  static Path _dashed(Path source,
      {required double dashLength, required double gapLength}) {
    final dest = Path();
    for (final metric in source.computeMetrics()) {
      double distance = 0;
      bool draw = true;
      while (distance < metric.length) {
        final len = draw ? dashLength : gapLength;
        if (draw) {
          dest.addPath(
            metric.extractPath(distance, distance + len),
            Offset.zero,
          );
        }
        distance += len;
        draw = !draw;
      }
    }
    return dest;
  }

  @override
  bool shouldRepaint(covariant _DashedBorderPainter oldDelegate) =>
      oldDelegate.color != color;
}

/// Pistol/rifle cartridge or chamber painter.
class _CartridgeDiagramPainter extends CustomPainter {
  _CartridgeDiagramPainter({
    required this.cartridge,
    required this.mode,
    required this.stroke,
    required this.fill,
    required this.label,
    required this.textColor,
  });

  final CartridgeRow cartridge;
  final DiagramMode mode;
  final Color stroke;
  final Color fill;
  final Color label;
  final Color textColor;

  @override
  void paint(Canvas canvas, Size size) {
    // Pull dimensions in inches. We've already validated the core ones in the
    // widget; secondary ones can still be null and we degrade gracefully.
    final caseLen = cartridge.caseLengthIn!;
    final bodyDia = cartridge.bodyDiameterIn!;
    final bulletDia = cartridge.bulletDiameterIn!;
    final maxCoal = cartridge.maxCoalIn;
    final shoulderDia = cartridge.shoulderDiameterIn;
    final neckDia = cartridge.neckDiameterIn;
    final neckLen = cartridge.neckLengthIn;
    final shoulderAngle = cartridge.shoulderAngleDeg;
    final baseToShoulder = cartridge.baseToShoulderIn;
    final rimDia = cartridge.rimDiameterIn;
    final rimThk = cartridge.rimThicknessIn;
    final subtype = cartridge.caseSubtype;

    // For chamber rendering, we extend a touch past max-COAL; otherwise we
    // draw to caseLen (cartridge) or maxCoal (cartridge with bullet).
    final overall = mode == DiagramMode.chamber
        ? (maxCoal ?? caseLen + bulletDia * 3) * 1.02
        : (maxCoal ?? caseLen + bulletDia * 3);

    // Largest diameter we need to fit vertically. Rim usually wins, then
    // body or shoulder.
    final maxDia = [
      bodyDia,
      shoulderDia ?? 0,
      neckDia ?? 0,
      bulletDia,
      rimDia ?? bodyDia,
    ].reduce(math.max);

    // Reserve margins for dimension labels. Left margin holds the rim
    // (head) callout — critical reloader data — so it's wider than the
    // right margin. Right margin holds the bullet (cartridge mode) or
    // bore/groove (chamber mode) callouts.
    const labelTop = 28.0;
    const labelBottom = 32.0;
    const labelLeft = 56.0;
    const labelRight = 80.0;

    final drawW = size.width - labelLeft - labelRight;
    final drawH = size.height - labelTop - labelBottom;
    if (drawW <= 0 || drawH <= 0) return;

    // Scale to fit.
    final scaleByLen = drawW / overall;
    final scaleByDia = drawH / maxDia;
    final scale = math.min(scaleByLen, scaleByDia);

    final centerY = labelTop + drawH / 2;
    final originX = labelLeft;

    // Convert inches → pixels.
    double x(double inches) => originX + inches * scale;
    double half(double inches) => inches * scale / 2;

    final straightCase = subtype == 'straight';
    final hasShoulder = !straightCase &&
        shoulderDia != null &&
        baseToShoulder != null &&
        neckDia != null;

    // ── Build the silhouette (top half; we'll mirror later) ─────────────
    final top = Path();

    // Rim — a small rectangular protrusion at the case head.
    final usedRimDia = rimDia ?? bodyDia;
    final usedRimThk = rimThk ?? 0.04;
    final rimYTop = centerY - half(usedRimDia);
    final bodyYTop = centerY - half(bodyDia);

    top.moveTo(x(0), rimYTop);
    top.lineTo(x(usedRimThk), rimYTop);
    top.lineTo(x(usedRimThk), bodyYTop);

    if (hasShoulder) {
      // Body straight section to shoulder start.
      top.lineTo(x(baseToShoulder), bodyYTop);
      // Shoulder taper down to neck diameter.
      final shoulderYTop = centerY - half(shoulderDia);
      final neckYTop = centerY - half(neckDia);
      top.lineTo(x(baseToShoulder), shoulderYTop);
      // The shoulder taper itself: from the shoulder-start radius to the
      // neck radius, advancing horizontally by tan(angle) * (shoulderRadius
      // - neckRadius). If we don't have an angle we approximate by ending
      // the taper at (caseLen - neckLen).
      double neckStartX;
      if (shoulderAngle != null && shoulderAngle > 0) {
        final radial = (shoulderDia - neckDia) / 2;
        final tan = math.tan(shoulderAngle * math.pi / 180);
        final taperLen = tan == 0 ? 0.0 : radial / tan;
        neckStartX = baseToShoulder + taperLen;
      } else if (neckLen != null) {
        neckStartX = caseLen - neckLen;
      } else {
        neckStartX = baseToShoulder + (shoulderDia - neckDia);
      }
      top.lineTo(x(neckStartX), neckYTop);
      // Neck straight to case mouth.
      top.lineTo(x(caseLen), neckYTop);
    } else {
      // Straight wall: body straight to mouth.
      top.lineTo(x(caseLen), bodyYTop);
    }

    // For cartridge mode, append the bullet (ogive + meplat).
    if (mode == DiagramMode.cartridge) {
      final bulletYTop = centerY - half(bulletDia);

      // The "case-mouth Y" — the inside-of-neck level at the mouth. For
      // bottleneck cases that's neckYTop; for straight-wall it's
      // bodyYTop.
      final mouthYTop = hasShoulder
          ? centerY - half(neckDia)
          : centerY - half(bodyDia);

      // Real-cartridge geometry: the bullet's bearing surface sits INSIDE
      // the case neck; only the ogive sticks out past the case mouth.
      // We model that by back-tracking the path from the case mouth into
      // the neck before stepping radially to the bullet's outer wall —
      // so the bullet's base step gets hidden inside the case silhouette
      // instead of appearing as a "floating" feature at the mouth.
      //
      // We only do this when the bullet is NARROWER than the case mouth
      // (the typical case — e.g. 6mm GT 0.243" bullet in a 0.273" neck).
      // If the bullet is wider than the mouth (rare), keep the old
      // behaviour of stepping outward at `caseLen` so the silhouette
      // closes correctly.
      final bulletNarrowerThanMouth = bulletYTop > mouthYTop;
      if (bulletNarrowerThanMouth) {
        // Approximate seating depth — most rifle / pistol bullets seat
        // 0.10 to 0.30" deep in the neck.
        final approxSeatingDepth =
            (bulletDia * 0.6).clamp(0.10, 0.30);
        // The bullet's base sits this far back from the case mouth.
        // Don't let it back-track past the start of the neck.
        final bulletBaseX =
            (caseLen - approxSeatingDepth).clamp(0.0, caseLen);

        // Path is currently at (caseLen, mouthYTop) — the top of the
        // case mouth. Back-track along the neck's top wall to the
        // bullet's base, step radially DOWN to the bullet's outer wall
        // (this step is now BEHIND the case mouth, hidden inside the
        // neck silhouette), then advance forward along the bullet body
        // to the case mouth where the bullet emerges.
        top.lineTo(x(bulletBaseX), mouthYTop);
        top.lineTo(x(bulletBaseX), bulletYTop);
        top.lineTo(x(caseLen), bulletYTop);
      } else {
        // Bullet wider than neck (rare). Step outward at the case mouth
        // — the bullet body wraps the neck OD. Path was already at
        // (caseLen, mouthYTop); step radially OUT to bulletYTop.
        top.lineTo(x(caseLen), bulletYTop);
      }

      // Ogive curve up to the tip at maxCoal.
      final tipX = maxCoal ?? (caseLen + bulletDia * 3);
      final ogiveStartX = caseLen;
      final ogiveLen = (tipX - ogiveStartX).clamp(0.0, double.infinity);
      // Use a quadratic curve from (caseLen, bulletYTop) to (tipX, centerY)
      // with a control point that makes a tangent ogive.
      top.quadraticBezierTo(
        x(ogiveStartX + ogiveLen * 0.55),
        bulletYTop,
        x(tipX),
        centerY,
      );
    } else {
      // Chamber mode: close the silhouette at the case mouth (no bullet).
      // When hasShoulder is true, Dart's flow-analysis promotes neckDia to
      // non-null because hasShoulder is a chain of != null checks against
      // final locals.
      final mouthYTop = hasShoulder
          ? centerY - half(neckDia)
          : centerY - half(bodyDia);
      // Add a small lead/freebore lip then cap.
      top.lineTo(x(caseLen + 0.05), mouthYTop);
      top.lineTo(x(caseLen + 0.05), centerY);
    }

    // Close the top half by returning to the centerline.
    top.lineTo(x(0), centerY);

    // Mirror to the bottom half.
    final bottom = top.transform(_mirrorAcross(centerY));

    // Fill + stroke.
    final fillPaint = Paint()
      ..color = fill
      ..style = PaintingStyle.fill;
    final strokePaint = Paint()
      ..color = stroke
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2
      ..strokeJoin = StrokeJoin.round;

    final combined = Path()
      ..addPath(top, Offset.zero)
      ..addPath(bottom, Offset.zero);

    canvas.drawPath(combined, fillPaint);
    canvas.drawPath(combined, strokePaint);

    // Centerline — thin dashed.
    final cl = Paint()
      ..color = stroke.withValues(alpha: 0.35)
      ..strokeWidth = 0.8;
    _drawDashedLine(
      canvas,
      Offset(x(0), centerY),
      Offset(x(overall), centerY),
      cl,
    );

    // ── Dimension labels ─────────────────────────────────────────────────
    // Case length (top, drawn above the silhouette).
    _drawHorizontalDimension(
      canvas,
      x0: x(0),
      x1: x(caseLen),
      y: labelTop - 12,
      bracketY: labelTop - 4,
      label: '${_formatLength(caseLen)} case',
      color: label,
      textColor: textColor,
    );

    // COAL (only meaningful in cartridge mode).
    if (mode == DiagramMode.cartridge && maxCoal != null) {
      _drawHorizontalDimension(
        canvas,
        x0: x(0),
        x1: x(maxCoal),
        y: size.height - labelBottom + 14,
        bracketY: size.height - labelBottom + 6,
        label: '${_formatLength(maxCoal)} max COAL',
        color: label,
        textColor: textColor,
        below: true,
      );
    }

    // Body diameter — small label near the body section.
    _drawDiameterLabel(
      canvas,
      labelX: x(usedRimThk + 0.04),
      labelY: centerY - half(bodyDia) - 6,
      text: '${_formatDiameter(bodyDia)} body',
      color: textColor,
    );

    // Shoulder angle (if present) — placed near the shoulder.
    // hasShoulder ⇒ baseToShoulder, shoulderDia, neckDia are all non-null.
    if (hasShoulder && shoulderAngle != null && shoulderAngle > 0) {
      final shoulderX = x(baseToShoulder + 0.02);
      _drawDiameterLabel(
        canvas,
        labelX: shoulderX,
        labelY: centerY + half(shoulderDia) + 4,
        text: '${shoulderAngle.toStringAsFixed(0)}° shoulder',
        color: textColor,
      );
    }

    // Neck diameter — small label near the case mouth (bottleneck cases only).
    if (hasShoulder) {
      _drawDiameterLabel(
        canvas,
        labelX: x(caseLen) - 36,
        labelY: centerY - half(neckDia) - 14,
        text: _formatDiameter(neckDia),
        color: textColor,
      );
    }

    // ── Base/Rim callouts — REQUIRED on every diagram ─────────────────────
    // Reloaders care about head/rim dimensions more than almost anything
    // else (bolt-face fit, headspace, pressure ring expansion). These are
    // always shown when the data is available.

    // Vertical rim diameter dimension on the far left.
    _drawVerticalDimension(
      canvas,
      x: x(0) - 28,
      y0: centerY - half(usedRimDia),
      y1: centerY + half(usedRimDia),
      bracketX: x(0) - 22,
      label: '${_formatDiameter(usedRimDia)} rim',
      color: label,
      textColor: textColor,
    );

    // Rim thickness — small horizontal callout below the rim protrusion.
    if (rimThk != null) {
      _drawHorizontalDimension(
        canvas,
        x0: x(0),
        x1: x(usedRimThk),
        y: centerY + half(usedRimDia) + 14,
        bracketY: centerY + half(usedRimDia) + 8,
        label: '${_formatDiameter(rimThk)} thk',
        color: label,
        textColor: textColor,
        below: true,
      );
    }

    // Primer-pocket indicator + label at the case head — purely visual cue
    // that this end is the head, plus the primer-size info reloaders need.
    final primerType = cartridge.primerType;
    if (primerType != null) {
      // Small filled circle representing the primer pocket on the case base.
      final pocketPaint = Paint()
        ..color = stroke.withValues(alpha: 0.45)
        ..style = PaintingStyle.fill;
      canvas.drawCircle(
        Offset(x(0) + 1.5, centerY),
        2.5,
        pocketPaint,
      );
      // Label: "Small Rifle primer", "Large Pistol primer", etc.
      _drawDiameterLabel(
        canvas,
        labelX: x(usedRimThk) + 4,
        labelY: centerY - 5,
        text: '${_humanPrimer(primerType)} primer',
        color: textColor,
      );
    }

    // Bullet diameter (cartridge mode) — labeled near the ogive base.
    if (mode == DiagramMode.cartridge) {
      _drawDiameterLabel(
        canvas,
        labelX: x(caseLen) + 6,
        labelY: centerY - half(bulletDia) - 14,
        text: '${_formatDiameter(bulletDia)} bullet',
        color: textColor,
      );
    }

    // Bore + groove (chamber mode) — labeled at the chamber mouth on the
    // right, since those are barrel dimensions, not cartridge dimensions.
    if (mode == DiagramMode.chamber) {
      final bore = cartridge.boreDiameterIn;
      final groove = cartridge.grooveDiameterIn;
      var rightLabelY = centerY - 8;
      if (bore != null) {
        _drawDiameterLabel(
          canvas,
          labelX: x(caseLen + 0.05) + 6,
          labelY: rightLabelY,
          text: '${_formatDiameter(bore)} bore',
          color: textColor,
        );
        rightLabelY += 12;
      }
      if (groove != null) {
        _drawDiameterLabel(
          canvas,
          labelX: x(caseLen + 0.05) + 6,
          labelY: rightLabelY,
          text: '${_formatDiameter(groove)} groove',
          color: textColor,
        );
      }
    }
  }

  /// Vertical dimension callout (e.g. rim diameter shown on the side).
  /// `bracketX` is the x where the small horizontal "tick" lines extend
  /// out from the dimension line; `x` is where the label sits.
  void _drawVerticalDimension(
    Canvas canvas, {
    required double x,
    required double y0,
    required double y1,
    required double bracketX,
    required String label,
    required Color color,
    required Color textColor,
  }) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = 1;
    canvas.drawLine(Offset(x, y0), Offset(x, y1), paint);
    canvas.drawLine(Offset(x, y0), Offset(bracketX, y0), paint);
    canvas.drawLine(Offset(x, y1), Offset(bracketX, y1), paint);
    // Tiny up + down arrowheads.
    canvas.drawPath(
      Path()
        ..moveTo(x, y0)
        ..lineTo(x - 2, y0 + 4)
        ..lineTo(x + 2, y0 + 4)
        ..close(),
      paint,
    );
    canvas.drawPath(
      Path()
        ..moveTo(x, y1)
        ..lineTo(x - 2, y1 - 4)
        ..lineTo(x + 2, y1 - 4)
        ..close(),
      paint,
    );

    // Rotated text — centered between y0 and y1, just left of the line.
    final span = TextSpan(
      text: label,
      style: TextStyle(
        color: textColor.withValues(alpha: 0.9),
        fontSize: 10,
        fontWeight: FontWeight.w500,
      ),
    );
    final tp = TextPainter(text: span, textDirection: TextDirection.ltr)
      ..layout();
    canvas.save();
    canvas.translate(x - 4, (y0 + y1) / 2 + tp.width / 2);
    canvas.rotate(-math.pi / 2);
    tp.paint(canvas, Offset.zero);
    canvas.restore();
  }

  /// Convert a primer-type seed key into a human-readable label suitable for
  /// the case-head callout.
  static String _humanPrimer(String key) {
    switch (key) {
      case 'small-pistol':
        return 'Small Pistol';
      case 'large-pistol':
        return 'Large Pistol';
      case 'small-rifle':
        return 'Small Rifle';
      case 'large-rifle':
        return 'Large Rifle';
      case 'berdan':
        return 'Berdan';
      case 'rimfire':
        return 'Rimfire';
      default:
        return key;
    }
  }

  /// Returns a 4x4 column-major matrix (as a [Float64List]) that mirrors
  /// the path across the horizontal line `y`. Flutter's [Path.transform]
  /// requires this exact shape, not a `Matrix4`.
  static Float64List _mirrorAcross(double y) {
    final m = Float64List(16);
    // Column 0: x-axis untouched.
    m[0] = 1;
    // Column 1: y is negated.
    m[5] = -1;
    // Column 2: z untouched.
    m[10] = 1;
    // Column 3: translation. Flip-then-shift so the line `y` is fixed.
    // y' = -y + 2y0  →  ty = 2 * y0.
    m[13] = 2 * y;
    m[15] = 1;
    return m;
  }

  void _drawDashedLine(Canvas canvas, Offset a, Offset b, Paint paint) {
    const dash = 4.0;
    const gap = 3.0;
    final delta = b - a;
    final len = delta.distance;
    if (len <= 0) return;
    final unit = delta / len;
    double drawn = 0;
    bool on = true;
    while (drawn < len) {
      final step = on ? dash : gap;
      final from = a + unit * drawn;
      final to = a + unit * math.min(drawn + step, len);
      if (on) canvas.drawLine(from, to, paint);
      drawn += step;
      on = !on;
    }
  }

  void _drawHorizontalDimension(
    Canvas canvas, {
    required double x0,
    required double x1,
    required double y,
    required double bracketY,
    required String label,
    required Color color,
    required Color textColor,
    bool below = false,
  }) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = 1;
    canvas.drawLine(Offset(x0, y), Offset(x1, y), paint);
    canvas.drawLine(Offset(x0, y), Offset(x0, bracketY), paint);
    canvas.drawLine(Offset(x1, y), Offset(x1, bracketY), paint);
    // Tiny arrowheads (left and right).
    _drawArrow(canvas, Offset(x0, y), forward: false, paint: paint);
    _drawArrow(canvas, Offset(x1, y), forward: true, paint: paint);

    final textSpan = TextSpan(
      text: label,
      style: TextStyle(
        color: textColor.withValues(alpha: 0.9),
        fontSize: 10,
        fontWeight: FontWeight.w500,
      ),
    );
    final tp = TextPainter(text: textSpan, textDirection: TextDirection.ltr)
      ..layout();
    final tx = (x0 + x1) / 2 - tp.width / 2;
    final ty = below ? y + 2 : y - tp.height - 2;
    tp.paint(canvas, Offset(tx, ty));
  }

  void _drawArrow(Canvas canvas, Offset tip,
      {required bool forward, required Paint paint}) {
    const size = 4.0;
    final dir = forward ? -1 : 1;
    final p1 = tip + Offset(dir * size, -size / 2);
    final p2 = tip + Offset(dir * size, size / 2);
    final path = Path()
      ..moveTo(tip.dx, tip.dy)
      ..lineTo(p1.dx, p1.dy)
      ..lineTo(p2.dx, p2.dy)
      ..close();
    canvas.drawPath(path, paint);
  }

  void _drawDiameterLabel(
    Canvas canvas, {
    required double labelX,
    required double labelY,
    required String text,
    required Color color,
  }) {
    final span = TextSpan(
      text: text,
      style: TextStyle(
        color: color.withValues(alpha: 0.85),
        fontSize: 10,
        fontWeight: FontWeight.w400,
      ),
    );
    final tp = TextPainter(text: span, textDirection: TextDirection.ltr)
      ..layout();
    tp.paint(canvas, Offset(labelX, labelY));
  }

  String _formatLength(double l) => '${l.toStringAsFixed(3)}"';

  String _formatDiameter(double d) =>
      '${d >= 0.5 ? d.toStringAsFixed(2) : d.toStringAsFixed(3)}"';

  @override
  bool shouldRepaint(covariant _CartridgeDiagramPainter oldDelegate) =>
      oldDelegate.cartridge.id != cartridge.id ||
      oldDelegate.mode != mode ||
      oldDelegate.stroke != stroke ||
      oldDelegate.fill != fill ||
      oldDelegate.label != label ||
      oldDelegate.textColor != textColor;
}

/// Shotshell painter — neutral hull silhouette with a brass head.
class _ShotshellDiagramPainter extends CustomPainter {
  _ShotshellDiagramPainter({
    required this.cartridge,
    required this.mode,
    required this.stroke,
    required this.fill,
    required this.label,
    required this.textColor,
  });

  final CartridgeRow cartridge;
  final DiagramMode mode;
  final Color stroke;
  final Color fill;
  final Color label;
  final Color textColor;

  /// Approximate bore diameter in inches for a given gauge number.
  /// Source: 12ga ≈ 0.729", scales like the gauge formula.
  static double _gaugeBoreIn(double gauge) {
    if (gauge <= 0) return 0.729;
    // Bore (in) ≈ 1.67 / gauge^(1/3); plus a hull-OD allowance later.
    return 1.67 / math.pow(gauge, 1 / 3);
  }

  @override
  void paint(Canvas canvas, Size size) {
    final shellLen = cartridge.shellLengthIn ?? 2.75;
    // The .410 stores its bore in mm-equivalent gauge (~67.6); detect that
    // and use a flat 0.410" bore.
    final isFourTen = (cartridge.gauge ?? 0) > 50;
    final bore = isFourTen ? 0.41 : _gaugeBoreIn(cartridge.gauge ?? 12);
    final hullOd = bore + 0.06; // approximate plastic hull wall.
    final brassLen = shellLen * 0.20; // typical brass head height.

    const labelTop = 28.0;
    const labelBottom = 32.0;
    const labelLeft = 16.0;
    const labelRight = 16.0;
    final drawW = size.width - labelLeft - labelRight;
    final drawH = size.height - labelTop - labelBottom;
    if (drawW <= 0 || drawH <= 0) return;

    final overall = shellLen + 0.05;
    final scale = math.min(drawW / overall, drawH / hullOd);
    final centerY = labelTop + drawH / 2;
    final originX = labelLeft;

    double x(double inches) => originX + inches * scale;
    double half(double inches) => inches * scale / 2;

    // Brass head rectangle.
    final brassRect = Rect.fromLTRB(
      x(0),
      centerY - half(hullOd),
      x(brassLen),
      centerY + half(hullOd),
    );
    // Plastic hull rectangle (slightly smaller diameter).
    final hullRect = Rect.fromLTRB(
      x(brassLen),
      centerY - half(hullOd),
      x(shellLen),
      centerY + half(hullOd),
    );

    final fillPaint = Paint()
      ..color = fill
      ..style = PaintingStyle.fill;
    final strokePaint = Paint()
      ..color = stroke
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2;

    canvas.drawRRect(
        RRect.fromRectAndRadius(brassRect, const Radius.circular(2)), fillPaint);
    canvas.drawRRect(
        RRect.fromRectAndRadius(brassRect, const Radius.circular(2)),
        strokePaint);
    canvas.drawRRect(
        RRect.fromRectAndRadius(hullRect, const Radius.circular(2)), fillPaint);
    canvas.drawRRect(
        RRect.fromRectAndRadius(hullRect, const Radius.circular(2)),
        strokePaint);

    // Crimp dashes at the mouth.
    final crimp = Paint()
      ..color = stroke.withValues(alpha: 0.5)
      ..strokeWidth = 1;
    final crimpX = x(shellLen) - 4;
    canvas.drawLine(
      Offset(crimpX, centerY - half(hullOd) + 3),
      Offset(crimpX, centerY + half(hullOd) - 3),
      crimp,
    );

    // Length label.
    _drawHorizontalDimension(
      canvas,
      x0: x(0),
      x1: x(shellLen),
      y: labelTop - 12,
      bracketY: labelTop - 4,
      label: '${shellLen.toStringAsFixed(2)}" shell',
      color: label,
      textColor: textColor,
    );

    final modeLabel = mode == DiagramMode.chamber ? 'chamber' : 'shell';
    _drawDiameterLabel(
      canvas,
      labelX: x(brassLen) + 4,
      labelY: centerY - half(hullOd) - 14,
      text: '${bore.toStringAsFixed(3)}" bore $modeLabel',
      color: textColor,
    );
  }

  void _drawHorizontalDimension(
    Canvas canvas, {
    required double x0,
    required double x1,
    required double y,
    required double bracketY,
    required String label,
    required Color color,
    required Color textColor,
  }) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = 1;
    canvas.drawLine(Offset(x0, y), Offset(x1, y), paint);
    canvas.drawLine(Offset(x0, y), Offset(x0, bracketY), paint);
    canvas.drawLine(Offset(x1, y), Offset(x1, bracketY), paint);
    final span = TextSpan(
      text: label,
      style: TextStyle(
        color: textColor.withValues(alpha: 0.9),
        fontSize: 10,
        fontWeight: FontWeight.w500,
      ),
    );
    final tp = TextPainter(text: span, textDirection: TextDirection.ltr)
      ..layout();
    final tx = (x0 + x1) / 2 - tp.width / 2;
    final ty = y - tp.height - 2;
    tp.paint(canvas, Offset(tx, ty));
  }

  void _drawDiameterLabel(
    Canvas canvas, {
    required double labelX,
    required double labelY,
    required String text,
    required Color color,
  }) {
    final span = TextSpan(
      text: text,
      style: TextStyle(
        color: color.withValues(alpha: 0.85),
        fontSize: 10,
      ),
    );
    final tp = TextPainter(text: span, textDirection: TextDirection.ltr)
      ..layout();
    tp.paint(canvas, Offset(labelX, labelY));
  }

  @override
  bool shouldRepaint(covariant _ShotshellDiagramPainter oldDelegate) =>
      oldDelegate.cartridge.id != cartridge.id ||
      oldDelegate.mode != mode ||
      oldDelegate.stroke != stroke ||
      oldDelegate.fill != fill ||
      oldDelegate.label != label ||
      oldDelegate.textColor != textColor;
}
