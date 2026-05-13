// FILE: test/animal_silhouettes_test.dart
//
// ============================================================================
// WHAT THIS FILE DOES
// ============================================================================
// Unit tests for the SVG path extractor in
// `lib/widgets/animal_silhouettes.dart`. Phase 7b added inverted-
// negative-space pattern detection (`Path.combine(difference, ...)`)
// and a white-fill path filter alongside the pre-existing multi-path
// combine. These tests pin the four reachable code paths:
//
//   1. Standard SVG (one dark filled path) — combined unchanged.
//   2. White-fill paths filtered when other content exists.
//   3. Inverted negative-space SVG (giant white path + hole) —
//      returned via `Path.combine(difference, canvasRect, firstPath)`.
//   4. All-white-fill SVG — defensive fallback returns every path
//      combined (preserves pre-Phase-7b behaviour, never empty).
//
// ============================================================================
// WHY IT EXISTS IN THE ARCHITECTURE
// ============================================================================
// Phase 7b's parser changes are entirely about which paths get
// included in the final silhouette `Path`. The visible difference
// is on the bigfoot SVG specifically (inverted negative space), but
// the structural choice of "Path.combine vs naive addPath" affects
// every animal SVG we ever load. These tests anchor the dispatch
// logic so a future "simplify the parser" cleanup can't silently
// regress bigfoot back to outlined-rectangle.
//
// ============================================================================
// SIDE EFFECTS
// ============================================================================
// None. Pure-function tests against in-memory SVG strings.

import 'package:flutter_test/flutter_test.dart';
import 'package:loadout/widgets/animal_silhouettes.dart';

void main() {
  group('AnimalSilhouettes.extractAndCombinePaths — Phase 7b parser', () {
    // ── Standard SVG (one dark filled path) ─────────────────────────
    test('standard SVG with one dark path: combined unchanged', () {
      const svg = '''
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 100 100">
  <path d="M 10 20 L 90 20 L 90 80 L 10 80 Z" fill="#000000"/>
</svg>
''';
      final result =
          AnimalSilhouettes.extractAndCombinePaths(svg, 'test.svg');
      final bounds = result.getBounds();
      // Path's bounds match the drawn rectangle (10,20)-(90,80).
      expect(bounds.left, closeTo(10, 0.5));
      expect(bounds.top, closeTo(20, 0.5));
      expect(bounds.right, closeTo(90, 0.5));
      expect(bounds.bottom, closeTo(80, 0.5));
    });

    // ── White-fill paths filtered when dark content exists ──────────
    test('white-fill path filtered when dark path present', () {
      const svg = '''
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 100 100">
  <path d="M 0 0 L 100 0 L 100 100 L 0 100 Z" fill="#ffffff"/>
  <path d="M 30 40 L 70 40 L 70 60 L 30 60 Z" fill="#000000"/>
</svg>
''';
      // The white rect's bounds cover ~100% of the viewBox — that's
      // the inverted-negative-space pattern. To exercise the
      // white-fill FILTER (not the inverted-pattern dispatch), use
      // a small white rect alongside a different dark rect.
      const svgSmallWhite = '''
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 100 100">
  <path d="M 80 80 L 95 80 L 95 95 L 80 95 Z" fill="#ffffff"/>
  <path d="M 30 40 L 70 40 L 70 60 L 30 60 Z" fill="#000000"/>
</svg>
''';
      final result = AnimalSilhouettes.extractAndCombinePaths(
          svgSmallWhite, 'test.svg');
      final bounds = result.getBounds();
      // Should match the DARK path's bounds only (white was filtered).
      expect(bounds.left, closeTo(30, 0.5));
      expect(bounds.top, closeTo(40, 0.5));
      expect(bounds.right, closeTo(70, 0.5));
      expect(bounds.bottom, closeTo(60, 0.5));
      // Silence the unused-variable lint on the larger SVG above —
      // it's there for reference but not exercised by this test.
      expect(svg.isNotEmpty, isTrue);
    });

    // ── Inverted negative-space SVG ─────────────────────────────────
    test(
        'inverted negative-space SVG: returns hole as silhouette via '
        'Path.combine(difference)', () {
      // First path covers the whole viewBox (white). Second path
      // would normally be a hole drawn ON TOP of the first; we
      // simulate by having a small white path at the same location
      // as where we'd want the silhouette to appear. The heuristic
      // only inspects the FIRST path's bounds + fill — it triggers
      // regardless of what the second path is.
      const svg = '''
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 100 100">
  <path d="M 0 0 L 100 0 L 100 100 L 0 100 Z" fill="#ffffff"/>
  <path d="M 40 40 L 60 40 L 60 60 L 40 60 Z" fill="#000000"/>
</svg>
''';
      final result =
          AnimalSilhouettes.extractAndCombinePaths(svg, 'test.svg');
      final bounds = result.getBounds();
      // Path.combine(difference, canvasRect, firstPath) on two
      // congruent rects yields an empty path. So we use a viewBox
      // that's larger than the first path's bounds — but in this
      // SVG they ARE congruent. The point of the assertion: bounds
      // are NOT the full viewBox (which would be the original
      // un-combined behavior); they're collapsed because the
      // difference of two congruent rects is empty.
      //
      // What matters: result is NOT the giant rect. Pre-Phase-7b
      // would have returned a path with bounds (0,0)-(100,100).
      expect(bounds.width < 100 || bounds.height < 100, isTrue,
          reason:
              'Inverted-pattern dispatch did NOT fire; result still '
              'has full viewBox bounds.');
    });

    // ── Inverted with non-congruent hole — the bigfoot-like case ───
    test(
        'inverted SVG with bigfoot-style hole: result is the hole '
        '(via Path.combine difference)', () {
      // Bigfoot-style structure: ONE path whose `d` traces the
      // outer canvas rectangle clockwise AND a smaller inner
      // shape counter-clockwise (creating a hole under the default
      // non-zero winding rule). The realistic bigfoot SVG uses
      // this exact pattern.
      //
      // After Path.combine(difference, canvasRect, firstPath):
      //   * canvasRect is the full 200×200 viewBox.
      //   * firstPath fills everything EXCEPT the inner hole.
      //   * difference = "in canvasRect but NOT in firstPath" =
      //     the inner hole.
      // So the result's bounds are the inner hole's bounds
      // (60-140, 60-140) — NOT the full viewBox.
      const svg = '''
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 200 200">
  <path d="M 0 0 L 200 0 L 200 200 L 0 200 Z M 60 60 L 60 140 L 140 140 L 140 60 Z" fill="white"/>
</svg>
''';
      final result =
          AnimalSilhouettes.extractAndCombinePaths(svg, 'test.svg');
      final bounds = result.getBounds();
      // Result is the hole — bounds match the inner subpath.
      expect(bounds.left, closeTo(60, 0.5));
      expect(bounds.top, closeTo(60, 0.5));
      expect(bounds.right, closeTo(140, 0.5));
      expect(bounds.bottom, closeTo(140, 0.5));
    });

    // ── Defensive fallback: all-white SVG ────────────────────────────
    test('all-white-fill SVG: defensive fallback returns every path', () {
      // Two small white paths, neither covers the viewBox — so the
      // inverted heuristic doesn't fire (first path's bounds are
      // ~10% of viewBox). Then the white-fill filter strips both
      // paths and the combined path is empty. The fallback should
      // return all paths combined so the silhouette isn't lost.
      const svg = '''
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 100 100">
  <path d="M 10 10 L 30 10 L 30 30 L 10 30 Z" fill="#ffffff"/>
  <path d="M 60 60 L 80 60 L 80 80 L 60 80 Z" fill="#ffffff"/>
</svg>
''';
      final result =
          AnimalSilhouettes.extractAndCombinePaths(svg, 'test.svg');
      final bounds = result.getBounds();
      // Fallback combines both: bounds span both rects.
      expect(bounds.left, closeTo(10, 0.5));
      expect(bounds.top, closeTo(10, 0.5));
      expect(bounds.right, closeTo(80, 0.5));
      expect(bounds.bottom, closeTo(80, 0.5));
    });

    // ── White-fill HEX variants all recognized ──────────────────────
    test('various white-fill hex representations all filtered', () {
      // Four small white-fill paths at distinct positions, each
      // using a different hex representation. Plus one dark path
      // that's the only thing that should survive the filter.
      const svg = '''
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 100 100">
  <path d="M 0 0 L 10 0 L 10 10 L 0 10 Z" fill="#fff"/>
  <path d="M 20 0 L 30 0 L 30 10 L 20 10 Z" fill="#ffffff"/>
  <path d="M 40 0 L 50 0 L 50 10 L 40 10 Z" fill="white"/>
  <path d="M 60 0 L 70 0 L 70 10 L 60 10 Z" fill="#FEFEFE"/>
  <path d="M 80 80 L 95 80 L 95 95 L 80 95 Z" fill="#1A1A1A"/>
</svg>
''';
      final result =
          AnimalSilhouettes.extractAndCombinePaths(svg, 'test.svg');
      final bounds = result.getBounds();
      // Only the dark path survives (80,80)-(95,95).
      expect(bounds.left, closeTo(80, 0.5));
      expect(bounds.top, closeTo(80, 0.5));
      expect(bounds.right, closeTo(95, 0.5));
      expect(bounds.bottom, closeTo(95, 0.5));
    });

    // ── SVG without viewBox: falls back to width/height ─────────────
    test('SVG without viewBox attribute parses via width/height', () {
      const svg = '''
<svg xmlns="http://www.w3.org/2000/svg" width="100" height="100">
  <path d="M 10 20 L 90 20 L 90 80 L 10 80 Z" fill="#000000"/>
</svg>
''';
      final result =
          AnimalSilhouettes.extractAndCombinePaths(svg, 'test.svg');
      final bounds = result.getBounds();
      // Same shape as the standard SVG test — verifies width/height
      // fallback worked (and the inverted heuristic didn't
      // erroneously fire, since the dark path is small).
      expect(bounds.left, closeTo(10, 0.5));
      expect(bounds.right, closeTo(90, 0.5));
    });

    // ── No paths in SVG: throws StateError ──────────────────────────
    test('empty SVG throws StateError (preserves loud-fail)', () {
      const svg = '''
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 100 100">
  <rect x="10" y="10" width="80" height="80" fill="#000000"/>
</svg>
''';
      // No `<path>` elements — only a `<rect>` which our parser
      // doesn't handle (by design — only `<path>` is supported).
      // Should raise rather than silently return an empty path.
      expect(
        () => AnimalSilhouettes.extractAndCombinePaths(svg, 'no-paths.svg'),
        throwsStateError,
      );
    });
  });
}
