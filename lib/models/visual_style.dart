// FILE: lib/models/visual_style.dart
//
// ============================================================================
// WHAT THIS FILE DOES
// ============================================================================
// Three-value enum that drives the Range Day scene's visual tier.
// `stylized` is the entry tier — the procedural scene WITH the full
// atmospheric-effects pass (DOF blur on distant elements, ground haze,
// soft target drop shadow, color grade, vignette, film grain). It is
// exactly the rendering that shipped pre-VFP-Phase-3 under the old
// `polished` name; the rename is 1:1 and behaviour-preserving.
// `scenic` is the planned 2.5D photo-backdrop-with-parallax middle
// tier; `photographic` is the planned full-3D tier. Neither has a
// renderer yet (VFP Phase 6 lights up Scenic, VFP Phase 23 lights up
// Photographic), so until then the painter's `_effectiveStyle`
// dispatch aliases both down to `stylized` — the user can already
// pick them in the Settings + Range Day toggle UI without breaking
// anything, and Stylized is the guaranteed safety floor.
//
// Public surface:
//   * `VisualStyle` enum — `stylized | scenic | photographic`.
//   * `VisualStyle.persistKey` — the stable string written to
//     SharedPreferences. Equals `enum.name` (`'stylized'` /
//     `'scenic'` / `'photographic'`).
//   * `VisualStyle.fromPersistKey(String?)` — parses a stored value
//     back to an enum. Legacy dev-build keys (`'polished'`, `'photo'`,
//     `'cartoon'`, `'realistic'`) and any unknown / null / empty value
//     all resolve to `stylized` (the safe default + the documented
//     legacy-alias migration).
//
// ============================================================================
// WHY IT EXISTS IN THE ARCHITECTURE
// ============================================================================
// VFP introduces a user-controlled three-tier visual model. Without
// this file, the choice would live as a magic string inside the
// `_RealisticScenePainter` constructor — leaking the storage shape
// into every call site. Pulling it out lets:
//   * `VisualStyleNotifier` (lib/services/visual_style_notifier.dart)
//     hold the current value, persist changes, and notify listeners.
//   * The painter take a `VisualStyle` parameter without dragging
//     SharedPrefs / String parsing into widget code.
//   * Settings + Range Day toggle UIs use a typed
//     `SegmentedButton<VisualStyle>` / `PopupMenuButton<VisualStyle>`
//     instead of string-based switches.
//
// The persistence helper (`persistKey` + `fromPersistKey`) is here
// rather than on the notifier because the value is also referenced
// from tests + (potentially) Cloud Sync export — keeping it on the
// type means the notifier is just I/O orchestration, not protocol.
//
// ============================================================================
// WHY THIS IS HARDER THAN IT LOOKS
// ============================================================================
//   * The persisted string MUST stay stable across the codebase — we
//     store `enum.name`, and `fromPersistKey` tolerates anything else
//     by returning `stylized`. Renaming an enum case would silently
//     reset every stored preference, so don't rename — extend.
//   * `fromPersistKey` is deliberately permissive on null / empty /
//     unknown AND on the four legacy dev-build keys. LoadOut has not
//     shipped, so there are no production preferences to migrate; the
//     legacy arms (`'polished'`/`'photo'`/`'cartoon'`/`'realistic'`
//     → `stylized`) exist purely so a developer's pre-Phase-3 prefs
//     entry resolves to the nearest surviving tier instead of throwing
//     or blanking the scene. The signature MUST stay nullable
//     (`String? key`) and the body MUST stay an expression-switch —
//     the typical caller is `prefs.getString('visual_style')` which
//     returns `String?`, and the permissive-null contract above is
//     deliberate, not an oversight.
//   * `scenic` / `photographic` are real enum values with NO renderer
//     yet. They are intentionally selectable so the picker UI is
//     complete and the user's choice survives to the phase that lights
//     each tier up (no future migration needed). The "render as
//     stylized until then" alias lives at the painter's dispatch site
//     (`target_plot.dart` `_effectiveStyle`), NOT here — keeping the
//     persistence layer honest about what the user actually picked.
//
// ============================================================================
// WHO CONSUMES THIS FILE
// ============================================================================
//   * `lib/services/visual_style_notifier.dart` — owns the SharedPrefs
//     I/O and the ChangeNotifier surface.
//   * `lib/screens/range_day/widgets/target_plot.dart` — the painter's
//     constructor parameter + the `_effectiveStyle` tier-alias switch.
//   * `lib/screens/settings/app_preferences_screen.dart` — the
//     Settings UI's `SegmentedButton<VisualStyle>`.
//   * `lib/screens/range_day/range_day_detail_screen.dart` — the Range
//     Day AppBar's compact `PopupMenuButton<VisualStyle>`.
//   * `test/visual_style_test.dart` — round-trip + legacy-alias-
//     migration tests for the persistKey / fromPersistKey contract.
//
// ============================================================================
// SIDE EFFECTS
// ============================================================================
//   * None. Pure value type + pure string parsing. SharedPrefs I/O
//     lives in `VisualStyleNotifier`.

/// User-controlled visual tier for the Range Day scene. `stylized`
/// (the default) is the procedural scene with the full atmospheric-
/// effects pass — the exact rendering that shipped pre-VFP-Phase-3 as
/// `polished`. `scenic` (2.5D photo backdrop) and `photographic`
/// (full 3D) are planned higher tiers with no renderer yet; until
/// VFP Phase 6 / 23 they render as `stylized` (alias lives at the
/// painter's dispatch site, not here, so the user's pick survives).
enum VisualStyle {
  stylized,
  scenic,
  photographic;

  /// Stable string written to SharedPreferences. Uses `enum.name` so
  /// the storage shape can't drift from the source. Renaming a value
  /// would invalidate every existing stored preference — don't.
  String get persistKey => name;

  /// Parse a SharedPreferences value back into a [VisualStyle].
  /// Pre-VFP-Phase-3 dev-build keys migrate forward to the nearest
  /// surviving tier; unknown / null / empty values fall back to
  /// `stylized` so a corrupted prefs entry can't brick the scene.
  /// Signature stays nullable + expression-switch by contract (see
  /// the file header's "harder than it looks" note).
  static VisualStyle fromPersistKey(String? key) => switch (key) {
        'stylized' => VisualStyle.stylized,
        'scenic' => VisualStyle.scenic,
        'photographic' => VisualStyle.photographic,
        'polished' => VisualStyle.stylized, // legacy alias migration
        'photo' => VisualStyle.stylized, // legacy alias migration
        'realistic' => VisualStyle.stylized, // legacy fallback
        'cartoon' => VisualStyle.stylized, // legacy fallback
        _ => VisualStyle.stylized, // null and unknown → stylized
      };
}

/// SharedPreferences key for the persisted visual-style choice. Lives
/// here so the notifier and any future surface that reads the
/// preference share one constant.
const String kVisualStylePrefKey = 'visual_style';
