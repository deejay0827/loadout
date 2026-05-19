// FILE: lib/widgets/reticle_full_screen_view.dart
//
// ============================================================================
// WHAT THIS FILE DOES
// ============================================================================
// Full-screen reticle preview modal. Shows a single [ReticleDefinition]
// inside a circular eyepiece-style FOV, rendered on top of the
// procedural daytime range backdrop ([ScopeDaytimeBackdrop]) so the
// user can see how the reticle would actually look against a target
// during a daylight range session.
//
// Public API:
//
// ```dart
// showReticleFullScreenPreview(
//   context,
//   reticle: someReticleDefinition,
//   reticleLabel: 'Vortex EBR-7C MRAD',
// );
// ```
//
// VFP Phase 3 Group B (operator decision A2 + teaser-blur Option 2):
// this "sample reticle image" is a Pro-gated VFP surface. The modal
// still OPENS for free users (exploration is free — they can launch
// it and feel the product), but the FOV render itself is wrapped in
// [BlurredProTeaser]: Pro users see the reticle crisp with no
// overlay; free users see it Gaussian-blurred under a "See the full
// reticle · Pro" CTA whose tap routes through `ensurePro` to the
// `PaywallScreen`. Tap-anywhere-else still dismisses (escape stays
// free — the teaser must never trap the user). The §30
// interoperability caption is rendered OUTSIDE the blur and stays
// fully legible for everyone — it is a legal disclaimer, never a
// thing to tease. Render code is identical for free and Pro; only
// the blur layer toggles.
//
// ============================================================================
// WHY IT EXISTS IN THE ARCHITECTURE
// ============================================================================
// The picker dropdown shows tiny generic glyphs — too small to
// evaluate a reticle's tree-style holdovers, floating numbers, or
// hash spacing. The user needs a "show me this at full size" gesture.
// A dedicated trailing icon launches this full-size render instead of
// expanding the list-row glyph, keeping the row scannable.
//
// Under A2 the ENTIRE VFP visual surface — including this sample
// reticle image — is Pro. Rather than a hard `ProGate` lock tile
// (which would replace the render with a lock and kill the upsell's
// strongest signal), this surface uses the canonical VFP teaser-blur:
// free users still open it and see the reticle's shape and density
// through the blur, which is the most direct "this is exactly what
// you'd unlock" conversion cue. The fully-clear render is the Pro
// payoff. See docs/PRO_GATING.md + CLAUDE.md §"Pro-gating UX pattern".
//
// (Historical note: pre-VFP-Phase-3 this preview was deliberately
// FREE — "no Pro upsell to evaluate a reticle." The A2 decision
// superseded that; this header was rewritten to match per the
// authority-hierarchy rule. Do not re-introduce the free claim.)
//
// ============================================================================
// WHY THIS IS HARDER THAN IT LOOKS
// ============================================================================
//   * The §30 interoperability caption MUST stay clear and legible
//     even for free users — it is a load-bearing legal disclaimer.
//     The [BlurredProTeaser] therefore wraps ONLY the circular FOV
//     render, never the caption Column beneath it. Widening the blur
//     to the caption would be an IP-posture regression.
//   * Tap-to-dismiss must keep working through the teaser. The
//     `BlurredProTeaser` scrim is `IgnorePointer`, so a tap on the
//     blurred FOV falls through to the full-screen dismiss layer
//     behind it (the modal closes); only the small centred CTA pill
//     absorbs taps and routes to `ensurePro`. The user is never
//     trapped behind the tease.
//   * The reticle's color must contrast both the bright sky AND the
//     darker grass / mound. We use a high-contrast dark-with-thin-
//     white-stroke compromise so the reticle reads on every part of
//     the backdrop without compositing tricks. (The blur is applied
//     ON TOP of that composited render for free users.)
//   * Center the FOV regardless of SafeArea inset; the modal is shown
//     via `showDialog` so the `Center` + `LayoutBuilder` pattern keeps
//     it stable across keyboard / notch / dynamic-island geometry.
//
// ============================================================================
// WHO CONSUMES THIS FILE
// ============================================================================
// - `lib/widgets/reticle_picker.dart` — the picker's full-screen
//   "Preview" trailing icon launches this via
//   [showReticleFullScreenPreview]. Opening is free; the rendered
//   content gates via the teaser-blur.
//
// ============================================================================
// SIDE EFFECTS
// ============================================================================
// - For a free user, tapping the CTA pill pushes the `PaywallScreen`
//   (via `ensurePro` inside [BlurredProTeaser]'s onCommit). Otherwise
//   pure UI; pops itself when the user taps to dismiss.

import 'package:flutter/material.dart';

import '../data/reticle_library.dart';
import 'blurred_pro_teaser.dart';
import 'pro_gate.dart';
import 'reticle_renderer.dart';
import 'scope_daytime_backdrop.dart';

// `ReticleInteroperabilityLabel` lives in `reticle_renderer.dart`; the
// import above brings it into scope here.

/// Open the full-screen reticle preview modal. Returns when the user
/// dismisses it (no result — the preview is read-only).
Future<void> showReticleFullScreenPreview(
  BuildContext context, {
  required ReticleDefinition reticle,
  required String reticleLabel,
  BackdropTargetSilhouette target = BackdropTargetSilhouette.ipsc,
}) {
  return showDialog<void>(
    context: context,
    barrierDismissible: true,
    barrierColor: Colors.black87,
    builder: (ctx) => _ReticleFullScreenView(
      reticle: reticle,
      reticleLabel: reticleLabel,
      target: target,
    ),
  );
}

class _ReticleFullScreenView extends StatelessWidget {
  const _ReticleFullScreenView({
    required this.reticle,
    required this.reticleLabel,
    required this.target,
  });

  final ReticleDefinition reticle;
  final String reticleLabel;
  final BackdropTargetSilhouette target;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: SafeArea(
        child: Stack(
          fit: StackFit.expand,
          children: [
            // Full-screen tap-to-dismiss layer behind everything.
            Positioned.fill(
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () => Navigator.of(context).pop(),
                child: Container(color: Colors.black),
              ),
            ),
            // Top label.
            Positioned(
              left: 0,
              right: 0,
              top: 16,
              child: Text(
                reticleLabel,
                textAlign: TextAlign.center,
                style: theme.textTheme.titleMedium?.copyWith(
                  color: Colors.white,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            // Centered FOV — fits the smaller of width / height.
            // The interoperability caption sits directly underneath
            // the FOV inside a Column so it follows the preview as
            // it scales with screen size, rather than floating at a
            // fixed bottom offset where it could overlap the dismiss
            // hint on short screens. CLAUDE.md § 30 liability
            // checklist requires the caption on every preview
            // surface; the inverse color flag swaps the muted
            // onSurfaceVariant tint for a high-contrast white tint
            // so the label reads on the modal's black scaffold.
            Center(
              child: LayoutBuilder(
                builder: (ctx, constraints) {
                  final maxSide = constraints.biggest.shortestSide;
                  final fovSide = maxSide * 0.85;
                  return Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      // VFP Phase 3 Group B (A2 / teaser-blur Option 2).
                      // Pro → verbatim crisp render. Free → the FOV is
                      // Gaussian-blurred under a "See the full reticle"
                      // CTA; the scrim is IgnorePointer so a tap on the
                      // blurred FOV still falls through to the dismiss
                      // layer behind, and only the centred pill routes
                      // to ensurePro. The §30 caption is rendered BELOW,
                      // OUTSIDE this teaser, so it stays fully legible
                      // for free users (legal disclaimer — never blur).
                      BlurredProTeaser(
                        // Placeholder CTA copy; final string operator-
                        // owned (docs/PRO_GATING.md candidate list).
                        ctaText: 'See the full reticle · Pro',
                        onCommit: () => ensurePro(context),
                        child: SizedBox(
                          width: fovSide,
                          height: fovSide,
                          child: ClipOval(
                            child: Stack(
                              fit: StackFit.expand,
                              children: [
                                ScopeDaytimeBackdrop(
                                  target: target,
                                  // Larger target than the default 16% so
                                  // the preview emphasizes "how the reticle
                                  // sits on a target" rather than scenery.
                                  targetWidthFraction: 0.22,
                                ),
                                // Reticle rendered on top of the backdrop.
                                // Use a dark line color (brand-safe black
                                // with a thin highlight) so it reads on
                                // both sky and grass.
                                Center(
                                  child: ReticleRenderer(
                                    reticle: reticle,
                                    displayUnit: reticle.nativeUnit ==
                                            ReticleNativeUnit.moa
                                        ? 'moa'
                                        : 'mil',
                                    size: Size(fovSide, fovSide),
                                    showUnitOverlay: false,
                                    color: const Color(0xff111111),
                                  ),
                                ),
                                // Eyepiece ring + soft black bezel so the
                                // backdrop doesn't bleed past the FOV edge.
                                Positioned.fill(
                                  child: IgnorePointer(
                                    child: CustomPaint(
                                      painter: _EyepieceRingPainter(),
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(height: 12),
                      // Interoperability caption — directly under the
                      // FOV per CLAUDE.md § 30. The label resolves the
                      // §7.7 per-origin template (LoadOut Original /
                      // Public Domain Reticle / Calibrated to ...) from
                      // the active reticle's `subtensionOrigin` +
                      // `calibrationProvenance`. Width-bounded to the
                      // preview so it wraps cleanly on narrow phones
                      // rather than running edge-to-edge.
                      ConstrainedBox(
                        constraints: BoxConstraints(maxWidth: fovSide),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 16),
                          child: ReticleInteroperabilityLabel(
                            align: TextAlign.center,
                            inverse: true,
                            subtensionOrigin: reticle.subtensionOrigin,
                            calibrationProvenance:
                                reticle.calibrationProvenance,
                          ),
                        ),
                      ),
                    ],
                  );
                },
              ),
            ),
            // Tap-to-dismiss hint at the bottom.
            Positioned(
              left: 0,
              right: 0,
              bottom: 24,
              child: Text(
                'Tap anywhere to dismiss',
                textAlign: TextAlign.center,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: Colors.white70,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Thin inner ring around the FOV edge so the preview reads as a
/// scope eyepiece, not just a circular crop.
class _EyepieceRingPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    if (size.width <= 0 || size.height <= 0) return;
    final radius = size.shortestSide / 2 - 2;
    final center = Offset(size.width / 2, size.height / 2);
    canvas.drawCircle(
      center,
      radius,
      Paint()
        ..color = Colors.black.withValues(alpha: 0.55)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 4,
    );
    canvas.drawCircle(
      center,
      radius - 2,
      Paint()
        ..color = Colors.white24
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.0,
    );
  }

  @override
  bool shouldRepaint(covariant _EyepieceRingPainter old) => false;
}
