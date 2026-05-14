// FILE: test/rack_rendering_test.dart
//
// ============================================================================
// WHAT THIS FILE DOES
// ============================================================================
// Regression suite for §6A.3 multi-target rack rendering — the
// Phase 4f scope-extension to `RealisticLayout.compute` and
// `_RealisticTargetPainter` in
// `lib/screens/range_day/widgets/target_plot.dart`.
//
// Each mount style (`hanging_rail`, `standing_stakes`, `popper_base`,
// `individual_posts`, plus the `null`/unknown fallback) gets its own
// fixture asserting:
//
//   * Children land at the expected vertical position for that
//     mount style. Hanging-rail, standing-stakes, and individual-
//     posts all keep the legacy "child top at 0.26 H" layout
//     (~ cross-bar at 0.20 H plus a chain segment below). Popper-
//     base bottom-aligns its children on the grass line at 0.78 H.
//   * The headroom invariant holds even when a `popper_base` rack
//     declares pathologically tall poppers — the rack scales down
//     uniformly so child_top stays ≥ 0.12 H.
//   * Unknown mount-style strings (e.g. `rotating_hub`, deferred to
//     v2.4) fall through to the hanging-rail layout silently.
//   * Active-vs-inactive outline-stroke ratio is at least 1.5×
//     (i.e. the active child renders at ≥ 50% thicker outline per
//     the v2.3 brief §6A.3 line 1244).
//
// ============================================================================
// WHY IT EXISTS IN THE ARCHITECTURE
// ============================================================================
// Phase 4f introduces the first mount-style-aware code path through
// `target_plot.dart`. Up to this point every rack rendered with the
// hanging-rail furniture regardless of the rack's actual mount
// style; Phase 4f branches on `rackMountStyle` to give each rack
// type the ground furniture it deserves. The branching covers
// vertical layout (popper_base bottom-on-grass) AND ground
// furniture (stakes / posts / berms), and the two sets of changes
// are easy to drift apart in a future refactor. Locking the
// expected per-style positions here pins both halves of the
// behaviour and surfaces any accidental change at test time.
//
// ============================================================================
// SIDE EFFECTS
// ============================================================================
// None. Pure value-type construction — the painter itself isn't
// exercised here (rasterising into a `PictureRecorder` and decoding
// the result back into pixels is way more machinery than these
// invariants need). The visual side is covered by Phase 5 manual
// verification per the brief.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:loadout/screens/range_day/widgets/target_plot.dart';

void main() {
  // ─────────────────────────────────────────────────────────────────────
  // Fixture builders.
  //
  // Every test runs against a canonical 600 × 800 (3:4 portrait
  // scope view). The two rack shapes covered — a 5-popper rack and
  // a 5-plate KYL — exercise both small and tall children so the
  // popper-base vertical branch and the hanging-rail vertical
  // branch produce visibly different child rects. Fixtures are
  // SYNTHETIC test data (intentionally decoupled from the seed
  // catalog) so a future Phase 9.x seed-data change doesn't
  // ripple into these painter tests. The Phase 9.6 seed catalog
  // ships poppers at 7.87 × 33.46 and KYL at 12/8/6/4/2 — these
  // fixtures don't track those specs.
  // ─────────────────────────────────────────────────────────────────────

  /// Synthetic 5-popper rack (8 × 18 in each, 12 in spacing).
  /// Used for `popper_base` painter dispatch tests.
  List<RackChildSpec> makeFivePopperChildren() {
    return [
      const RackChildSpec(
        widthIn: 8,
        heightIn: 18,
        category: 'ipsc',
        offsetXFromCenterIn: -24,
      ),
      const RackChildSpec(
        widthIn: 8,
        heightIn: 18,
        category: 'ipsc',
        offsetXFromCenterIn: -12,
      ),
      const RackChildSpec(
        widthIn: 8,
        heightIn: 18,
        category: 'ipsc',
        offsetXFromCenterIn: 0,
      ),
      const RackChildSpec(
        widthIn: 8,
        heightIn: 18,
        category: 'ipsc',
        offsetXFromCenterIn: 12,
      ),
      const RackChildSpec(
        widthIn: 8,
        heightIn: 18,
        category: 'ipsc',
        offsetXFromCenterIn: 24,
      ),
    ];
  }

  /// Synthetic 5-plate KYL rack (5/4/3/2/1 in circles, 12 in
  /// spacing). Used for hanging_rail / standing_stake /
  /// silhouette_stand tests so the tests run against a shape
  /// distinct from the popper rack. Synthetic — does NOT match
  /// the Phase 9.6 catalog's kyl_5_plate_circles seed (12/8/6/4/2).
  List<RackChildSpec> makeFiveKylChildren() {
    return [
      const RackChildSpec(
        widthIn: 5,
        heightIn: 5,
        category: 'circle',
        offsetXFromCenterIn: -28,
      ),
      const RackChildSpec(
        widthIn: 4,
        heightIn: 4,
        category: 'circle',
        offsetXFromCenterIn: -16,
      ),
      const RackChildSpec(
        widthIn: 3,
        heightIn: 3,
        category: 'circle',
        offsetXFromCenterIn: -4,
      ),
      const RackChildSpec(
        widthIn: 2,
        heightIn: 2,
        category: 'circle',
        offsetXFromCenterIn: 8,
      ),
      const RackChildSpec(
        widthIn: 1,
        heightIn: 1,
        category: 'circle',
        offsetXFromCenterIn: 20,
      ),
    ];
  }

  // ─────────────────────────────────────────────────────────────────────
  // Vertical positioning per mount style.
  // ─────────────────────────────────────────────────────────────────────

  group('RealisticLayout.compute — hanging_rail mount style', () {
    test('children top at ~ 0.26 H (cross-bar at 0.20 H + chain)', () {
      // h = 800; cross-bar at 0.20 * 800 = 160; chain length is
      // max(h * 0.06, 24) = 48; expected child top ≈ 160 + 48 = 208 px.
      // Allow some slack for the chain-length implementation detail
      // (max(h * 0.06, 24)).
      final layout = RealisticLayout.compute(
        outerSize: const Size(600, 800),
        targetWidthIn: 5,
        targetHeightIn: 5,
        rackChildren: makeFiveKylChildren(),
        activeRackChildIndex: 0,
        rackMountStyle: 'hanging_rail',
      );
      expect(layout.isRack, isTrue);
      expect(layout.childRects, hasLength(5));
      // Every child top should sit at the same Y (uniform "hanging
      // from a rail" pattern).
      final tops = layout.childRects.map((r) => r.top).toSet();
      expect(tops, hasLength(1),
          reason: 'all KYL children should hang from the same rail height');
      final childTop = layout.childRects.first.top;
      expect(childTop, closeTo(800 * 0.26, 5.0),
          reason: 'KYL child top should sit near 0.26 H (cross-bar + chain)');
    });

    test('cross-bar Y at 0.20 H regardless of child sizes', () {
      final layout = RealisticLayout.compute(
        outerSize: const Size(600, 800),
        targetWidthIn: 5,
        targetHeightIn: 5,
        rackChildren: makeFiveKylChildren(),
        activeRackChildIndex: 0,
        rackMountStyle: 'hanging_rail',
      );
      expect(layout.crossBarY, closeTo(800 * 0.20, 0.5));
    });
  });

  group('RealisticLayout.compute — standing_stakes mount style', () {
    test('children top at ~ 0.26 H (shares the hanging-rail layout)', () {
      // standing_stakes keeps the legacy vertical layout — only the
      // ground-furniture renderer changes. The child rectangles are
      // identical to the hanging_rail rack.
      final layout = RealisticLayout.compute(
        outerSize: const Size(600, 800),
        targetWidthIn: 5,
        targetHeightIn: 5,
        rackChildren: makeFiveKylChildren(),
        activeRackChildIndex: 0,
        rackMountStyle: 'standing_stakes',
      );
      expect(layout.isRack, isTrue);
      final childTop = layout.childRects.first.top;
      expect(childTop, closeTo(800 * 0.26, 5.0),
          reason: 'standing_stakes child top should match hanging_rail');
    });
  });

  group('RealisticLayout.compute — individual_posts mount style', () {
    test('children top at ~ 0.26 H (shares the hanging-rail layout)', () {
      // individual_posts also uses the hanging-rail vertical layout
      // — only the ground furniture (per-child wooden post + small
      // earth-berm oval) differs.
      final layout = RealisticLayout.compute(
        outerSize: const Size(600, 800),
        targetWidthIn: 5,
        targetHeightIn: 5,
        rackChildren: makeFiveKylChildren(),
        activeRackChildIndex: 0,
        rackMountStyle: 'individual_posts',
      );
      expect(layout.isRack, isTrue);
      final childTop = layout.childRects.first.top;
      expect(childTop, closeTo(800 * 0.26, 5.0),
          reason: 'individual_posts child top should match hanging_rail');
    });
  });

  group('RealisticLayout.compute — popper_base mount style', () {
    test('children BOTTOM at 0.78 H (sitting on the grass line)', () {
      // 5-popper rack — poppers are 18 in tall × 8 in wide. The
      // popper_base branch bottom-aligns each child on the grass
      // line at 0.78 H (where the realistic-mode backdrop's grass
      // starts). Different from every other mount style which
      // top-aligns children at ~ 0.26 H.
      final layout = RealisticLayout.compute(
        outerSize: const Size(600, 800),
        targetWidthIn: 8,
        targetHeightIn: 18,
        rackChildren: makeFivePopperChildren(),
        activeRackChildIndex: 0,
        rackMountStyle: 'popper_base',
      );
      expect(layout.isRack, isTrue);
      // Every popper should share the same bottom Y.
      final bottoms = layout.childRects.map((r) => r.bottom).toSet();
      expect(bottoms, hasLength(1),
          reason: 'popper_base children should share a single grass-line bottom');
      // Bottom = 0.78 * 800 = 624.
      expect(layout.childRects.first.bottom, closeTo(800 * 0.78, 1.0),
          reason: 'popper_base child bottoms should sit on the grass at 0.78 H');
    });

    test('headroom preserved: tall poppers stay above 0.12 H', () {
      // Pathological case: a "tall popper" rack at 30 in tall × 6 in
      // wide poppers at 500 yd. Even if the natural pxPerInch
      // would push the popper top above 0.12 H, the popper_base
      // branch scales the rack down uniformly so the tallest child
      // top stays AT OR BELOW the 0.12 H ceiling (i.e. ≥ 0.12 H
      // measured from the top of the canvas).
      //
      // 30 in tall × 6 in wide; 5 children at 12 in spacing.
      final tallPoppers = [
        for (var i = -2; i <= 2; i++)
          RackChildSpec(
            widthIn: 6,
            heightIn: 30,
            category: 'ipsc',
            offsetXFromCenterIn: i * 12.0,
          ),
      ];
      final layout = RealisticLayout.compute(
        outerSize: const Size(600, 800),
        targetWidthIn: 6,
        targetHeightIn: 30,
        rackChildren: tallPoppers,
        activeRackChildIndex: 2,
        rackMountStyle: 'popper_base',
      );
      // 0.12 * 800 = 96. Allow a 1 px epsilon for cap rounding.
      expect(layout.childRects.first.top, greaterThanOrEqualTo(96 - 1.0),
          reason: 'tall popper_base rack must respect 0.12 H headroom');
    });
  });

  group('RealisticLayout.compute — unknown / null mount style fallback', () {
    test('rotating_hub falls through to hanging_rail layout', () {
      // `rotating_hub` is deferred to v2.4 per Phase 2 errata. The
      // compute branch should fall through to the default rack
      // layout (child top at 0.26 H) so the rack still renders
      // sensibly when the seed data carries the new value.
      final layout = RealisticLayout.compute(
        outerSize: const Size(600, 800),
        targetWidthIn: 5,
        targetHeightIn: 5,
        rackChildren: makeFiveKylChildren(),
        activeRackChildIndex: 0,
        rackMountStyle: 'rotating_hub',
      );
      expect(layout.isRack, isTrue);
      final childTop = layout.childRects.first.top;
      expect(childTop, closeTo(800 * 0.26, 5.0),
          reason: 'rotating_hub should fall through to hanging_rail layout');
    });

    test('null mount style uses default rack layout', () {
      // The legacy code path (no rackMountStyle passed in) is the
      // hanging-rail layout. This guards against accidentally
      // breaking the existing v2.3 rack render when migrating new
      // seed data.
      final layout = RealisticLayout.compute(
        outerSize: const Size(600, 800),
        targetWidthIn: 5,
        targetHeightIn: 5,
        rackChildren: makeFiveKylChildren(),
        activeRackChildIndex: 0,
        rackMountStyle: null,
      );
      expect(layout.isRack, isTrue);
      final childTop = layout.childRects.first.top;
      expect(childTop, closeTo(800 * 0.26, 5.0),
          reason: 'null mount style should use the default rack layout');
    });
  });

  // ─────────────────────────────────────────────────────────────────────
  // Active-vs-inactive stroke-width ratio.
  // ─────────────────────────────────────────────────────────────────────

  group('Active vs inactive outline stroke widths', () {
    test('active stroke is ≥ 1.5× the inactive stroke', () {
      // Per §6A.3 line 1244: "the active plate renders with a 50%
      // thicker stroke (e.g., 2.5px instead of 1.5px)." The
      // exported constants live at the top of `target_plot.dart`
      // — asserting their ratio here catches a future
      // "consistency-cleanup" pass that nudges them back toward the
      // legacy 1.6 / 1.2 values.
      expect(kRackActiveStrokeWidth / kRackInactiveStrokeWidth,
          greaterThanOrEqualTo(1.5),
          reason: 'active stroke must be at least 50% thicker than inactive');
    });

    test('both stroke widths are positive', () {
      expect(kRackActiveStrokeWidth, greaterThan(0));
      expect(kRackInactiveStrokeWidth, greaterThan(0));
    });

    test('active stroke matches the brief example (2.5 px)', () {
      // The brief gives a concrete example value; pinning it here
      // keeps the visual weight stable across refactors. The brief
      // doesn't mandate exactly 2.5 — "e.g., 2.5px" — but the
      // landed value is 2.5 and pinning it surfaces any drift.
      expect(kRackActiveStrokeWidth, closeTo(2.5, 0.01));
    });

    test('inactive stroke matches the brief example (1.5 px)', () {
      expect(kRackInactiveStrokeWidth, closeTo(1.5, 0.01));
    });
  });
}
