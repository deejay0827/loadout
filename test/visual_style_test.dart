// FILE: test/visual_style_test.dart
//
// ============================================================================
// WHAT THIS FILE DOES
// ============================================================================
// Round-trip, legacy-alias-migration, and safe-fallback regression
// tests for the [VisualStyle] enum's persistence contract after the
// VFP Phase 3 tier rename (`cartoon`/`polished`/`photo` →
// `stylized`/`scenic`/`photographic`). Pins:
//
//   1. `enum.persistKey` matches `enum.name` for every value (the
//      stable storage shape).
//   2. `fromPersistKey` returns the matching enum for every current
//      key string.
//   3. `fromPersistKey` migrates the four pre-Phase-3 dev-build keys
//      (`'polished'`, `'photo'`, `'cartoon'`, `'realistic'`) forward
//      to `stylized` — the documented legacy-alias migration.
//   4. `fromPersistKey` falls back to `stylized` for null / empty /
//      unknown strings (the safe default).
//   5. Round-trip: `VisualStyle.fromPersistKey(value.persistKey) ==
//      value` for every value.
//   6. The signature stays nullable (`String? key`) — exercised by
//      the explicit `null` case.
//
// ============================================================================
// WHY IT EXISTS IN THE ARCHITECTURE
// ============================================================================
// `VisualStyle.fromPersistKey` is the single boundary between the
// SharedPreferences string and the typed tier enum. VFP Phase 3
// removed two enum values and added two; without these pins a
// regression could (a) drop a legacy-alias arm and brick a
// developer's pre-Phase-3 prefs entry, (b) flip the safe default
// away from `stylized`, or (c) narrow the nullable signature (the
// V6.11 Phase 3 Group A contract requires it stay `String?` +
// expression-switch). All three would ship silently.
//
// ============================================================================
// SIDE EFFECTS
// ============================================================================
// None. Pure enum value-type tests.

import 'package:flutter_test/flutter_test.dart';
import 'package:loadout/models/visual_style.dart';

void main() {
  group('VisualStyle — persistKey + fromPersistKey contract', () {
    test('persistKey matches enum.name for every value', () {
      expect(VisualStyle.stylized.persistKey, 'stylized');
      expect(VisualStyle.scenic.persistKey, 'scenic');
      expect(VisualStyle.photographic.persistKey, 'photographic');
    });

    test('fromPersistKey returns the matching enum for current keys', () {
      expect(VisualStyle.fromPersistKey('stylized'), VisualStyle.stylized);
      expect(VisualStyle.fromPersistKey('scenic'), VisualStyle.scenic);
      expect(
          VisualStyle.fromPersistKey('photographic'),
          VisualStyle.photographic);
    });

    test(
        'fromPersistKey migrates pre-VFP-Phase-3 dev-build keys to stylized',
        () {
      // LoadOut has not shipped, so there are no production prefs to
      // migrate — but a developer's pre-Phase-3 SharedPreferences
      // entry must resolve to the nearest surviving tier instead of
      // blanking the scene. These four arms are the documented
      // legacy-alias migration (V6.11 Phase 3 Group A).
      expect(VisualStyle.fromPersistKey('polished'), VisualStyle.stylized);
      expect(VisualStyle.fromPersistKey('photo'), VisualStyle.stylized);
      expect(VisualStyle.fromPersistKey('cartoon'), VisualStyle.stylized);
      expect(VisualStyle.fromPersistKey('realistic'), VisualStyle.stylized);
    });

    test('fromPersistKey falls back to stylized for null', () {
      // Also pins the nullable `String?` signature — this call would
      // not compile if the parameter were narrowed to non-null.
      expect(VisualStyle.fromPersistKey(null), VisualStyle.stylized);
    });

    test('fromPersistKey falls back to stylized for empty string', () {
      expect(VisualStyle.fromPersistKey(''), VisualStyle.stylized);
    });

    test('fromPersistKey falls back to stylized for unknown strings', () {
      expect(VisualStyle.fromPersistKey('high_contrast'),
          VisualStyle.stylized);
      expect(VisualStyle.fromPersistKey('night_vision'),
          VisualStyle.stylized);
      expect(VisualStyle.fromPersistKey('STYLIZED'), VisualStyle.stylized,
          reason:
              'Case-sensitive — only the lowercase enum.name string '
              'parses to its own value; anything else (including a '
              'wrong-case variant) takes the safe stylized fallback. '
              'Pinning this catches a future bug where someone '
              'normalises the input mid-flight.');
    });

    test('round-trip preserves every value', () {
      for (final v in VisualStyle.values) {
        expect(VisualStyle.fromPersistKey(v.persistKey), v);
      }
    });
  });

  group('VisualStyle — pref-key constant', () {
    test('kVisualStylePrefKey is stable', () {
      expect(kVisualStylePrefKey, 'visual_style');
    });
  });
}
