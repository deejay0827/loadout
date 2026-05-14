// FILE: lib/screens/range_day/widgets/scene_input.dart
//
// ============================================================================
// WHAT THIS FILE DOES
// ============================================================================
// Defines the [SceneInput] sealed type that drives the Range Day
// realistic painter ([_RealisticScenePainter] in `target_plot.dart`).
// Two concrete subtypes:
//
//   * [SingleTargetScene] — one target on a pole + mound. Carries a
//     [TargetSpec] (the existing single-target geometry record from
//     `target_plot.dart`).
//   * [RackScene] — multi-slot rack. Carries a [RackSpec] bundling
//     the rack's mount structure with its list of [RackChildSpec]
//     slots, plus the 0-indexed active slot for picker / aim / scope
//     ring anchoring.
//
// Plus a small [RackSpec] value type that bundles `mountStructure`
// (`hanging_rail | standing_stake | popper_base | silhouette_stand`,
// per the Phase 9.6 catalog) with the slot list. The painter consumes
// this as a unit; the parent screen builds it once per render from
// the loaded `TargetRackRow` + `slotsJson`.
//
// ============================================================================
// WHY IT EXISTS IN THE ARCHITECTURE
// ============================================================================
// Phase 9.7's goal is to unify single-target and rack rendering under
// one painter ([_RealisticScenePainter]). The painter dispatches on
// scene type, NOT on a `bool isRack` flag — because Dart's sealed-class
// exhaustiveness lets the compiler enforce that any `switch (sceneInput)`
// over [SceneInput] covers both subtypes. A future
// [DistanceCalibrationScene] or [PhotoBackedScene] would surface the
// new case as an exhaustiveness error at every switch site, instead
// of silently falling through a default branch.
//
// The file is deliberately tiny and import-light. Group A (Phase 9.7)
// adds it without touching any existing code; Group B then wires
// [SceneInput] into [_RealisticScenePainter]'s constructor; Group C
// implements the rack-rendering branch.
//
// ============================================================================
// WHY THIS IS HARDER THAN IT LOOKS
// ============================================================================
//   * Dart's sealed-class exhaustiveness is COMPILE-TIME ONLY. Adding
//     a new [SceneInput] subtype is a breaking change at every switch
//     site over [SceneInput] — by design, the analyzer surfaces the
//     missing case. Keep the subtypes intentional; do not add a third
//     "just in case." Phase 9.7 spec §"Out of scope" explicitly
//     reserves additional subtypes for future phases.
//   * [SingleTargetScene] and [RackScene] both use `final class`
//     modifier (not `class`). The `final` modifier prevents external
//     subclassing AND prevents implementation by external classes —
//     so a future caller can't write
//     `class FakeSceneInput implements SceneInput` and bypass the
//     intended pair. This is the canonical Dart 3 pattern for closed
//     sums.
//   * [SceneInput]'s `const SceneInput()` constructor is required by
//     `sealed class` semantics so subclasses can be `const`. Trying
//     to omit it produces an "implicitly-generated default constructor
//     can't be referenced" analyzer error from the subclass `const`
//     constructors.
//   * [RackSpec] is intentionally MINIMAL: just `mountStructure` +
//     `slots`. Anything else the painter needs (canvas dimensions,
//     scope ring radius, lowLightMode flag) stays as separate
//     painter-constructor parameters. The point of the SceneInput
//     refactor is the dispatch shape, not a god-object refactor.
//
// ============================================================================
// WHO CONSUMES THIS FILE
// ============================================================================
//   * `lib/screens/range_day/widgets/target_plot.dart` —
//     [_RealisticScenePainter]'s constructor + `paint()` dispatch
//     (Phase 9.7 Group B + Group C).
//   * `test/scene_input_test.dart` — sealed-exhaustiveness contract
//     test (Group A.2).
//
// ============================================================================
// SIDE EFFECTS
// ============================================================================
//   * None. Pure value types and a sealed-type hierarchy. No I/O, no
//     plugins, no platform channels, no DB.

import 'target_plot.dart' show RackChildSpec, TargetSpec;

/// Sealed input type for [_RealisticScenePainter]. Either a single
/// target ([SingleTargetScene]) or a multi-slot rack ([RackScene]).
/// Use a `switch` expression over a [SceneInput] value to dispatch
/// per-type rendering; Dart's compile-time exhaustiveness guarantees
/// both subtypes are covered.
sealed class SceneInput {
  const SceneInput();
}

/// A single target painted on a pole + mound rig with the existing
/// Phase 9.5 single-target dispatch.
final class SingleTargetScene extends SceneInput {
  const SingleTargetScene({required this.target});

  /// The target's geometry, category, color, and SVG dispatch key.
  /// Same record the pre-9.7 `_RealisticScenePainter` constructor
  /// took directly as `target:`.
  final TargetSpec target;
}

/// A multi-slot rack scene. Carries the rack's mount structure +
/// every slot's spec, plus the 0-indexed active slot.
///
/// The painter:
///   1. Draws the mount structure (rail / stakes / popper bases /
///      silhouette stands) per [RackSpec.mountStructure].
///   2. Iterates [RackSpec.slots] and draws each at its
///      `offsetXFromCenterIn` position.
///   3. Draws the active slot at index [activeSlotIndex] with a
///      2.0 px black outline (vs 1.0 px 70%-opacity black for
///      inactive slots).
///
/// The Phase 9.7 spec locks the mount-structure vocabulary to four
/// canonical values: `hanging_rail | standing_stake | popper_base |
/// silhouette_stand`. Unknown values fall through to `hanging_rail`
/// per the painter's existing dispatch fallback.
final class RackScene extends SceneInput {
  const RackScene({
    required this.rack,
    required this.activeSlotIndex,
  });

  /// The rack's mount structure + slot list.
  final RackSpec rack;

  /// 0-based index of the active slot inside [rack.slots]. The active
  /// slot is the one that receives aim-point taps, shot dots, and the
  /// distinctive 2.0 px black outline. The painter clamps to
  /// `[0, slots.length - 1]` defensively — an out-of-range index from
  /// a stale Range Day session can't crash the render.
  final int activeSlotIndex;
}

/// Bundles a rack's mount structure with its slot list. Pulled out
/// of [RackScene] so the parent screen can construct it once per
/// render without re-deriving the mount string at every painter
/// constructor call.
class RackSpec {
  const RackSpec({
    required this.mountStructure,
    required this.slots,
  });

  /// One of `hanging_rail | standing_stake | popper_base |
  /// silhouette_stand`. Drives the mount-drawer dispatch inside
  /// [_RealisticScenePainter]'s `_paintRack` branch. Stays a free-
  /// form string (not an enum) so a future mount type can be added
  /// without forcing a sealed-enum migration; unknown values fall
  /// through to `hanging_rail` per the painter's dispatch fallback.
  final String mountStructure;

  /// Every shootable in the rack, in `position` order (the rack's
  /// intended engagement sequence). The painter renders slots in
  /// this order so overdraw is deterministic — the active slot's
  /// outline goes on top of the slot fill, but inactive slots
  /// never overlap each other (slots are positioned by
  /// `offsetXFromCenterIn`).
  final List<RackChildSpec> slots;
}
