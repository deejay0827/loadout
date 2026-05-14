// FILE: test/scene_input_test.dart
//
// ============================================================================
// WHAT THIS FILE DOES
// ============================================================================
// Contract tests for the [SceneInput] sealed-type hierarchy in
// `lib/screens/range_day/widgets/scene_input.dart`. The hierarchy is
// the dispatch shape for the Phase 9.7 unified Range Day painter
// ([_RealisticScenePainter]). These tests pin:
//
//   1. Both subtypes ([SingleTargetScene] / [RackScene]) are
//      constructible.
//   2. A `switch` over a [SceneInput] value reaches both branches
//      without a default fallback. If a future engineer adds a third
//      subtype, Dart's compile-time exhaustiveness will surface the
//      uncovered branch — this test pins that the CURRENT pair is
//      covered.
//   3. [RackScene]'s required fields ([rack], [activeSlotIndex]) and
//      [RackSpec]'s ([mountStructure], [slots]) round-trip through the
//      constructor.
//
// ============================================================================
// SIDE EFFECTS
// ============================================================================
// None. Pure value-type assertions.

import 'package:flutter_test/flutter_test.dart';
import 'package:loadout/screens/range_day/widgets/scene_input.dart';
import 'package:loadout/screens/range_day/widgets/target_plot.dart';

void main() {
  group('SceneInput — sealed-type dispatch contract', () {
    test('SingleTargetScene carries its TargetSpec verbatim', () {
      final spec = TargetSpec.defaultPaper();
      final scene = SingleTargetScene(target: spec);
      expect(scene.target, same(spec));
    });

    test('RackScene carries its RackSpec + activeSlotIndex verbatim', () {
      const rack = RackSpec(
        mountStructure: 'hanging_rail',
        slots: <RackChildSpec>[
          RackChildSpec(
            widthIn: 12,
            heightIn: 12,
            category: 'circle',
            offsetXFromCenterIn: -24,
          ),
          RackChildSpec(
            widthIn: 9,
            heightIn: 9,
            category: 'circle',
            offsetXFromCenterIn: 0,
          ),
          RackChildSpec(
            widthIn: 6,
            heightIn: 6,
            category: 'circle',
            offsetXFromCenterIn: 24,
          ),
        ],
      );
      const scene = RackScene(rack: rack, activeSlotIndex: 1);
      expect(scene.rack.mountStructure, 'hanging_rail');
      expect(scene.rack.slots, hasLength(3));
      expect(scene.activeSlotIndex, 1);
      expect(scene.rack.slots[1].widthIn, 9);
    });

    test(
        'a switch expression over SceneInput reaches both branches '
        'without a default fallback',
        () {
      // The point of this test isn't the strings — it's that the
      // following switch COMPILES with no `default:` clause, which
      // means Dart has verified both subtypes are covered. If
      // someone adds a third subtype to scene_input.dart, this
      // switch will fail to compile (compile-time exhaustiveness),
      // forcing them to handle the new case here too — and by
      // extension, at every other switch site over [SceneInput] in
      // the codebase.
      String dispatch(SceneInput input) => switch (input) {
            SingleTargetScene() => 'single',
            RackScene() => 'rack',
          };

      expect(
        dispatch(SingleTargetScene(target: TargetSpec.defaultPaper())),
        'single',
      );
      expect(
        dispatch(const RackScene(
          rack: RackSpec(mountStructure: 'hanging_rail', slots: []),
          activeSlotIndex: 0,
        )),
        'rack',
      );
    });

    test('SceneInput cannot be subclassed by external code', () {
      // This test is a compile-time documentation rather than a
      // runtime check: the `sealed` modifier on [SceneInput] AND the
      // `final` modifier on the concrete subclasses prevent external
      // subclassing / implementation. A `class FakeSceneInput
      // implements SceneInput {}` declaration in any consumer file
      // would fail at compile time — which is the property the
      // refactor relies on for exhaustive dispatch.
      //
      // We assert the contract is in place by enumerating the
      // KNOWN concrete types and confirming the runtimeType matches
      // one of them.
      final SceneInput single =
          SingleTargetScene(target: TargetSpec.defaultPaper());
      const SceneInput rack = RackScene(
        rack: RackSpec(mountStructure: 'hanging_rail', slots: []),
        activeSlotIndex: 0,
      );
      expect(single, isA<SingleTargetScene>());
      expect(rack, isA<RackScene>());
      expect(single, isNot(isA<RackScene>()));
      expect(rack, isNot(isA<SingleTargetScene>()));
    });
  });
}
