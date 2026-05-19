// FILE: test/visual_tier_platform_test.dart
//
// ============================================================================
// WHAT THIS FILE DOES
// ============================================================================
// Pins the PURE, platform-free helpers in
// lib/services/visual_tier_platform.dart that drive VFP Phase 3
// Group C's tier-picker availability + clamp logic:
//
//   * `visualTierSegmentValues(...)` — Stylized-only when
//     Scenic/Photographic unsupported, all three when supported;
//     Stylized always present and always first.
//   * `clampVisualTier(...)` — collapses Scenic/Photographic to
//     Stylized when unsupported; pass-through when supported. This
//     is the load-bearing guard that stops a synced `photographic`
//     preference from crashing a Stylized-only `SegmentedButton`.
//   * `visualTierHelpText(...)` + `kScenicPhotographicUnavailableNote`
//     — the §3.6 verbatim copy (pinned so a copy regression fails
//     loudly; final wording is operator-owned but these are the spec
//     strings).
//
// `scenicPhotographicSupported` itself is platform-dependent
// (`kIsWeb || Platform.isMacOS`). Under `flutter test` it resolves
// against the Dart VM + the host OS, so its VALUE is NOT a
// deterministic unit-test concern — only that it is a stable bool.
// Its real per-platform behaviour (web/macOS hide Scenic+
// Photographic; iOS/Android show them) is covered by the post-D11
// per-surface widget matrix (docs/PRO_GATING.md §6.2), per the
// operator-approved test split.
//
// ============================================================================
// SIDE EFFECTS
// ============================================================================
// None. Pure function tests.

import 'package:flutter_test/flutter_test.dart';
import 'package:loadout/models/visual_style.dart';
import 'package:loadout/services/visual_tier_platform.dart';

void main() {
  group('visualTierSegmentValues', () {
    test('supported → all three tiers, Stylized first', () {
      expect(
        visualTierSegmentValues(scenicPhotographic: true),
        const [
          VisualStyle.stylized,
          VisualStyle.scenic,
          VisualStyle.photographic,
        ],
      );
    });

    test('unsupported → Stylized only', () {
      expect(
        visualTierSegmentValues(scenicPhotographic: false),
        const [VisualStyle.stylized],
      );
    });

    test('Stylized is always present and first (invariant)', () {
      for (final sp in [true, false]) {
        final v = visualTierSegmentValues(scenicPhotographic: sp);
        expect(v, isNotEmpty);
        expect(v.first, VisualStyle.stylized);
      }
    });
  });

  group('clampVisualTier', () {
    test('unsupported → everything collapses to Stylized', () {
      for (final s in VisualStyle.values) {
        expect(
          clampVisualTier(s, scenicPhotographic: false),
          VisualStyle.stylized,
          reason: '$s must clamp to stylized when unsupported',
        );
      }
    });

    test('supported → pass-through (no clamp)', () {
      for (final s in VisualStyle.values) {
        expect(clampVisualTier(s, scenicPhotographic: true), s);
      }
    });

    test('clamp output is always a valid segment value', () {
      // The load-bearing contract: whatever clamp returns MUST be in
      // the segment list for the same platform support — else the
      // SegmentedButton `selected ⊆ segments` assertion fails.
      for (final sp in [true, false]) {
        final segs = visualTierSegmentValues(scenicPhotographic: sp);
        for (final s in VisualStyle.values) {
          final clamped = clampVisualTier(s, scenicPhotographic: sp);
          expect(segs.contains(clamped), isTrue,
              reason: 'clamp($s, sp=$sp)=$clamped must be a segment');
        }
      }
    });
  });

  group('§3.6 copy is pinned (verbatim spec strings)', () {
    test('per-tier helper text', () {
      expect(
        visualTierHelpText(VisualStyle.stylized),
        'Clean, illustrated rendering with atmospheric depth. '
        'Lowest memory footprint.',
      );
      expect(
        visualTierHelpText(VisualStyle.scenic),
        'Photographic backdrop with parallax depth and photo '
        'target elements. Realistic 2D experience.',
      );
      expect(
        visualTierHelpText(VisualStyle.photographic),
        'Full 3D rendering via Filament. Maximum realism. Higher '
        'device requirements; battery and frame rate impact noted '
        'at activation.',
      );
    });

    test('web/macOS availability note', () {
      expect(
        kScenicPhotographicUnavailableNote,
        'Scenic and Photographic modes are available on iOS and '
        'Android.',
      );
    });
  });

  group('scenicPhotographicSupported (platform-dependent — smoke only)',
      () {
    test('is a stable bool (value is a platform/integration concern)',
        () {
      final a = scenicPhotographicSupported;
      final b = scenicPhotographicSupported;
      expect(a, isA<bool>());
      expect(a, b, reason: 'must be stable within a run');
      // Whatever it is, the helpers must stay self-consistent.
      final segs =
          visualTierSegmentValues(scenicPhotographic: a);
      expect(segs.first, VisualStyle.stylized);
    });
  });
}
