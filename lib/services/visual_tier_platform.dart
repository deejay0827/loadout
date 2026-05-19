// FILE: lib/services/visual_tier_platform.dart
//
// ============================================================================
// WHAT THIS FILE DOES
// ============================================================================
// Single source of truth for "does THIS platform offer the Scenic +
// Photographic visual tiers?" plus two pure, platform-free helpers
// the tier pickers use so their availability/clamp logic is unit-
// testable without a real platform:
//
//   * `scenicPhotographicSupported` — runtime predicate. `false` on
//     web AND macOS (Stylized only there, per VFP §4.18); `true` on
//     iOS / Android.
//   * `visualTierSegmentValues({required scenicPhotographic})` — the
//     ordered list of `VisualStyle` values a picker should offer:
//     `[stylized]` when unsupported, all three when supported.
//   * `clampVisualTier(style, {required scenicPhotographic})` — maps
//     a (possibly persisted/synced) tier down to `stylized` when the
//     platform can't offer it. LOAD-BEARING: `SegmentedButton`
//     asserts that its `selected` value is one of its segment
//     values, so a device that synced `photographic` from a phone
//     and opened Settings on macOS would CRASH the picker without
//     this clamp.
//
// ============================================================================
// WHY IT EXISTS IN THE ARCHITECTURE
// ============================================================================
// VFP §4.18 mandates `kIsWeb || Platform.isMacOS` guards "throughout"
// (Settings picker, Range Day popup, and — later — the Phase 4+ asset
// pipeline / capability detection). Centralising the predicate here
// means there is exactly ONE place that encodes the rule, every
// consumer reads the same answer, and the pure helpers let widget
// tests assert the availability/clamp behaviour deterministically
// (the real predicate can't vary under `flutter test`, which runs on
// the Dart VM — neither web nor necessarily macOS).
//
// ============================================================================
// WHY THIS IS HARDER THAN IT LOOKS
// ============================================================================
//   * Order matters: `kIsWeb` MUST be evaluated first. It
//     short-circuits, so `Platform.isMacOS` is never reached on web —
//     `dart:io`'s `Platform` throws on web, and only the short-circuit
//     keeps this safe. (`flutter` permits importing `dart:io` for web
//     builds; using `Platform` there is the runtime hazard the
//     short-circuit avoids.)
//   * `kIsWeb` ALONE is NOT enough: it is `false` on macOS desktop, so
//     a `kIsWeb`-only guard would wrongly offer Scenic/Photographic on
//     macOS. The plan calls this out explicitly (§3644-3646) as a
//     repeat footgun — both halves of the OR are required.
//   * The clamp is not cosmetic: it prevents a hard `SegmentedButton`
//     assertion failure on cross-device sync (persisted `photographic`
//     → macOS Settings). The pickers must drive their `selected` /
//     `initialValue` through `clampVisualTier`, never the raw stored
//     value.
//
// ============================================================================
// WHO CONSUMES THIS FILE
// ============================================================================
//   * `lib/screens/settings/app_preferences_screen.dart` — the
//     Settings `SegmentedButton<VisualStyle>` (segments + clamp).
//   * `lib/screens/range_day/range_day_detail_screen.dart` — the
//     Range Day AppBar `PopupMenuButton<VisualStyle>` (items + clamp).
//   * Future VFP Phase 4+ asset-pipeline / capability-detection guards
//     (per §4.18) should read `scenicPhotographicSupported` here too.
//   * `test/visual_tier_platform_test.dart` — pure-helper coverage.
//
// ============================================================================
// SIDE EFFECTS
// ============================================================================
//   * None. Pure platform query + pure functions.

import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show kIsWeb;

import '../models/visual_style.dart';

/// True iff the Scenic + Photographic tiers are offered on the
/// current platform. `false` on web AND macOS (Stylized only, VFP
/// §4.18); `true` on iOS / Android. `kIsWeb` is checked first so
/// `Platform` is never evaluated on web (where it would throw).
bool get scenicPhotographicSupported => !(kIsWeb || Platform.isMacOS);

/// The ordered `VisualStyle` values a picker should expose given
/// platform support. Stylized is always present and always first.
/// Pure (no platform access) so pickers stay testable.
List<VisualStyle> visualTierSegmentValues({
  required bool scenicPhotographic,
}) {
  if (scenicPhotographic) {
    return const [
      VisualStyle.stylized,
      VisualStyle.scenic,
      VisualStyle.photographic,
    ];
  }
  return const [VisualStyle.stylized];
}

/// Clamp a (possibly persisted / cross-device-synced) [style] to one
/// the platform can actually offer. When Scenic/Photographic are
/// unsupported, anything other than `stylized` collapses to
/// `stylized`. Pickers MUST feed their `selected` / `initialValue`
/// through this — feeding a raw `photographic` into a Stylized-only
/// `SegmentedButton` is a hard assertion failure, not a soft mismatch.
VisualStyle clampVisualTier(
  VisualStyle style, {
  required bool scenicPhotographic,
}) {
  if (scenicPhotographic) return style;
  return VisualStyle.stylized;
}

/// The §3.6 per-tier helper sentence shown under the picker for the
/// currently-selected tier. Copy is from VFP plan §3.6 verbatim;
/// final wording is operator-owned (surfaced via the Group B/ C copy
/// review) but these are the spec strings, not placeholders.
String visualTierHelpText(VisualStyle style) {
  switch (style) {
    case VisualStyle.stylized:
      return 'Clean, illustrated rendering with atmospheric depth. '
          'Lowest memory footprint.';
    case VisualStyle.scenic:
      return 'Photographic backdrop with parallax depth and photo '
          'target elements. Realistic 2D experience.';
    case VisualStyle.photographic:
      return 'Full 3D rendering via Filament. Maximum realism. Higher '
          'device requirements; battery and frame rate impact noted '
          'at activation.';
  }
}

/// The §3.6 web/macOS availability note appended under the picker
/// when Scenic/Photographic are hidden. Verbatim from §3.6.
const String kScenicPhotographicUnavailableNote =
    'Scenic and Photographic modes are available on iOS and Android.';
