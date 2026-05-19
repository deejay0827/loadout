// FILE: lib/widgets/blurred_pro_teaser.dart
//
// ============================================================================
// WHAT THIS FILE DOES
// ============================================================================
// Defines `BlurredProTeaser` — the canonical "teaser-blur Option 2"
// Pro-gating UX primitive for the Visual Fidelity Program (VFP)
// surfaces. It wraps an arbitrary `child` (a live preview / scene /
// sample image) and:
//
//   - Pro user → returns `child` verbatim. Zero overhead, identical
//     render path, full interactivity. The blur/CTA layers never
//     enter the tree.
//   - Free user → keeps `child` ALIVE in the widget tree (it still
//     runs its build/paint logic and rebuilds when its inputs change
//     — e.g. a slider above it drives a re-render) but rasterises it
//     through a Gaussian `ImageFilter.blur`, and paints a readability
//     scrim + a centred "Unlock with Pro" call-to-action over it.
//
// The load-bearing behaviour (VFP teaser-blur Option 2): the blurred
// preview RESPONDS TO CONTROL CHANGES IN REAL TIME. Because `child`
// stays in the tree, dragging a zoom slider or cycling the visual
// tier rebuilds `child`, and `ImageFiltered` re-rasterises the new
// content still blurred. The free user can feel every control work;
// they just cannot read the content clearly or commit a selection.
//
// `BlurredProTeaser` does NOT itself gate commit actions. Commit
// gating (tap-to-select, tap-to-expand, save, lock-in) stays the
// caller's responsibility at those specific handlers, wired through
// `ensurePro(context)` (lib/widgets/pro_gate.dart). The optional
// `onCommit` makes the centred CTA pill a direct, supplementary
// unlock tap-target; it is the ONLY pointer-absorbing element when
// set — everything else passes through to the live child so
// scroll / pan / pinch / slider gestures keep working for free users.
//
// Props:
//   - `child`     — the live preview content. Built once by the
//                   caller and passed in unchanged for free AND Pro
//                   (no duplicated render path — the operator's
//                   explicit requirement).
//   - `ctaText`   — surface-specific CTA copy. PLACEHOLDER strings
//                   today; final copy is operator-owned (surfaced
//                   for review as a candidate-string list).
//   - `onCommit`  — optional. When non-null the CTA pill is tappable
//                   and calls this (typically `() => ensurePro(ctx)`).
//                   When null the pill is a pure label (IgnorePointer)
//                   and the surface gates commits at its own handlers.
//   - `blurSigma` — Gaussian sigma, tunable per surface. Default 8.0
//                   (operator spec). Lower it on heavy surfaces if
//                   the per-frame re-raster proves costly (see PERF).
//   - `overlayIcon` / `semanticLabel` — CTA affordance + a11y.
//
// ============================================================================
// WHY IT EXISTS IN THE ARCHITECTURE
// ============================================================================
// VFP Phase 3 Group B (operator decision A2 + teaser-blur Option 2)
// makes the entire Range Day target / reticle / preview / zoom
// surface Pro-only, but enforces it through a live-blurred teaser
// rather than a hard paywall. Re-implementing "blur the subtree,
// keep it live, overlay a CTA, flip instantly on purchase" at each
// of the ~10 gated surfaces would duplicate the blur/scrim/CTA
// composition and the watch-vs-read entitlement subtlety everywhere.
// Centralising it here keeps the teaser visual language consistent
// and keeps the render code identical for free and Pro (only the
// blur layer toggles), which is the explicit operator requirement
// for avoiding a two-path rendering fork.
//
// It is the teaser-flavoured sibling of `ProGate` / `ensurePro`
// (lib/widgets/pro_gate.dart). `ProGate` replaces the child with a
// lock tile (hard gate, used for non-VFP Pro features). This widget
// keeps the child visible-but-blurred (soft teaser, the canonical
// VFP-surface pattern). Both read the same `EntitlementNotifier`.
//
// ============================================================================
// WHY THIS IS HARDER THAN IT LOOKS
// ============================================================================
// 1. ImageFiltered, NOT BackdropFilter. `BackdropFilter` blurs what
//    is painted BEHIND it (the backdrop); it would NOT blur `child`.
//    `ImageFiltered` blurs the child subtree's own raster while
//    leaving it live in the tree — exactly the requirement. Getting
//    this wrong silently blurs nothing (or the wrong layer).
// 2. The CTA must not eat the child's gestures. Free users must keep
//    scrolling lists, panning/pinching scenes, dragging sliders. The
//    scrim is `IgnorePointer`; only the optional centred CTA pill
//    (small, centred) absorbs taps, and only when `onCommit` is set.
//    A naive full-area tap-absorber over a scrollable kills scroll —
//    this widget deliberately never does that.
// 3. watch vs read. `build` uses `context.watch<EntitlementNotifier>`
//    so a successful purchase rebuilds every teaser and they all flip
//    to the clear child simultaneously — no restart. (Same contract
//    as `ProGate`.)
// 4. PERF — operator-flagged validation item. `ImageFiltered`
//    re-rasterises `child` every time `child` repaints. On a surface
//    whose `child` rebuilds every frame during a continuous slider
//    drag (e.g. the `TargetPlot` CustomPaint scene) on a low-end
//    device, a large-sigma blur per frame can drop frames. Mitigations
//    baked in: the blurred subtree is wrapped in a `RepaintBoundary`
//    so its raster is isolated (the scrim/CTA do not re-raster when
//    the child animates and vice-versa), `TileMode.decal` avoids edge
//    clamp work, and `blurSigma` is per-surface tunable. If a wired
//    surface still drags on real low-end hardware, that is a genuine
//    finding to surface before committing the pattern (per the
//    operator's explicit instruction) — escalations: lower sigma,
//    blur a throttled last-settled raster instead of per-frame, or
//    downscale-then-blur.
//
// ============================================================================
// WHO CONSUMES THIS FILE
// ============================================================================
// - Every VFP-gated visual surface (VFP Phase 3 Group B): the reticle
//   picker list + sample/preview images (lib/widgets/reticle_picker.dart,
//   reticle_full_screen_view.dart, reticle_thumbnail.dart), and the
//   Range Day target plot / inline scope-view preview / visual-tier
//   picker / animated-mover card
//   (lib/screens/range_day/range_day_detail_screen.dart,
//   scope_view_screen.dart).
// - Search the codebase for `BlurredProTeaser(` for every call site.
// - Canonical pattern + API documented in docs/PRO_GATING.md and
//   CLAUDE.md §"Pro-gating UX pattern".
//
// ============================================================================
// SIDE EFFECTS
// ============================================================================
// - None. Pure presentational widget. No navigation, no SharedPrefs,
//   no network. `onCommit` (caller-supplied) is what may push the
//   paywall; this widget only invokes the callback.

import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../services/entitlement_notifier.dart';

/// Canonical VFP "teaser-blur Option 2" Pro gate. Renders [child]
/// verbatim for Pro users; for free users keeps [child] live but
/// blurred under a CTA. See the file header for the full contract.
///
/// ```dart
/// BlurredProTeaser(
///   ctaText: 'Unlock with Pro',
///   onCommit: () => ensurePro(context),
///   child: theLivePreview,
/// )
/// ```
class BlurredProTeaser extends StatelessWidget {
  const BlurredProTeaser({
    super.key,
    required this.child,
    required this.ctaText,
    this.onCommit,
    this.blurSigma = 8.0,
    this.overlayIcon = Icons.lock_outline,
    this.semanticLabel,
  });

  /// The live preview / scene / sample image. Built once by the
  /// caller and passed unchanged for free AND Pro — there is no
  /// separate free render path.
  final Widget child;

  /// Surface-specific CTA copy. Placeholder today; final copy is
  /// operator-owned (see docs/PRO_GATING.md candidate-string list).
  final String ctaText;

  /// Optional commit handler. When non-null the centred CTA pill is
  /// tappable and calls this (typically `() => ensurePro(context)`).
  /// When null the pill is a pure, non-interactive label and the
  /// surface gates commits at its own handlers.
  final VoidCallback? onCommit;

  /// Gaussian blur sigma applied to [child] for free users. Tunable
  /// per surface; default 8.0. See the header PERF note.
  final double blurSigma;

  /// Icon shown on the CTA pill (defaults to a lock).
  final IconData overlayIcon;

  /// Accessibility label for the CTA. Defaults to [ctaText].
  final String? semanticLabel;

  @override
  Widget build(BuildContext context) {
    // watch (not read): a successful purchase fires
    // EntitlementNotifier.notifyListeners(), rebuilding every teaser so
    // they all flip to the clear child at once — no restart.
    final isPro = context.watch<EntitlementNotifier>().isPro;
    if (isPro) return child;

    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    final ctaPill = DecoratedBox(
      decoration: BoxDecoration(
        color: scheme.surface.withValues(alpha: 0.92),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: scheme.primary),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.18),
            blurRadius: 8,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(overlayIcon, size: 18, color: scheme.primary),
            const SizedBox(width: 8),
            Flexible(
              child: Text(
                ctaText,
                textAlign: TextAlign.center,
                style: theme.textTheme.labelLarge?.copyWith(
                  color: scheme.primary,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ],
        ),
      ),
    );

    return Stack(
      fit: StackFit.passthrough,
      children: [
        // The child stays LIVE (it still rebuilds when its inputs —
        // sliders, tier picker — change); ImageFiltered re-rasterises
        // that new content still blurred. RepaintBoundary isolates the
        // blur raster so the scrim/CTA do not re-raster with the child
        // and vice-versa (PERF, see header note 4).
        RepaintBoundary(
          child: ImageFiltered(
            imageFilter: ui.ImageFilter.blur(
              sigmaX: blurSigma,
              sigmaY: blurSigma,
              // decal: transparent outside the child's bounds rather
              // than clamping edge pixels — no smeared border at the
              // blur boundary and slightly cheaper than clamp.
              tileMode: TileMode.decal,
            ),
            child: child,
          ),
        ),

        // Readability scrim. IgnorePointer so EVERY gesture (scroll,
        // pan, pinch, slider drag, item tap) passes straight through
        // to the live child — only the optional centred pill below
        // ever absorbs input.
        Positioned.fill(
          child: IgnorePointer(
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    scheme.scrim.withValues(alpha: 0.10),
                    scheme.scrim.withValues(alpha: 0.28),
                  ],
                ),
              ),
            ),
          ),
        ),

        // Centred CTA. When onCommit is set this small pill is the
        // ONLY pointer-absorbing element (a direct, supplementary
        // unlock tap-target); gestures anywhere else still reach the
        // live child. When onCommit is null the pill is wrapped in
        // IgnorePointer (pure label) and the surface gates commits at
        // its own handlers.
        Positioned.fill(
          child: Center(
            child: onCommit == null
                ? IgnorePointer(
                    child: Semantics(
                      label: semanticLabel ?? ctaText,
                      child: ctaPill,
                    ),
                  )
                : Semantics(
                    button: true,
                    label: semanticLabel ?? ctaText,
                    child: Material(
                      type: MaterialType.transparency,
                      child: InkWell(
                        borderRadius: BorderRadius.circular(999),
                        onTap: onCommit,
                        child: ctaPill,
                      ),
                    ),
                  ),
          ),
        ),
      ],
    );
  }
}
