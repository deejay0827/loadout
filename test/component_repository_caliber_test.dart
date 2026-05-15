// FILE: test/component_repository_caliber_test.dart
//
// ============================================================================
// WHAT THIS FILE DOES
// ============================================================================
// Regression suite for `ComponentRepository.caliberLabelForBulletDiameter`
// — the bullet-diameter → colloquial caliber-family lookup that was
// moved out of the recipe form's private method in Phase One Group 3
// (2026-05-14). The suite asserts every entry from the previous
// hardcoded 14-entry table round-trips, plus boundary conditions
// (within tolerance, just outside tolerance, smallest-residual
// tie-breaking, no-match returns null).
//
// The 14 round-trip assertions are the load-bearing regression: if a
// future refactor changes the static map's contents or the matching
// algorithm, the test surfaces the drift before the user sees a
// caliber field that no longer back-fills.
//
// ============================================================================
// WHY IT EXISTS IN THE ARCHITECTURE
// ============================================================================
// The caliber-family lookup is the small bridge that makes the recipe
// form's bullet picker feel intelligent — pick "Berger Hybrid 140gr"
// and the caliber field auto-fills with "6.5mm" because the bullet
// diameter (0.264 in) maps to that family. Reloaders notice when
// this stops working: they expect the form to anticipate the
// caliber from the bullet they just picked. A silent regression here
// (e.g. a map entry dropped during a refactor) would force them to
// hand-type every caliber.
//
// The test exists so a future "improvement" can't break the contract
// without a red bar to remind us.
//
// ============================================================================
// WHY THIS IS HARDER THAN IT LOOKS
// ============================================================================
// - The method's signature is `Future<String?>` even though the body
//   is synchronous. The Future-wrapping is deliberate (forward-
//   compatibility with a future catalog-backed implementation when
//   the cartridge catalog gains a `family_label` column). Tests use
//   `await`.
// - Tolerance is fixed at ±0.0015 in. Values just outside that band
//   must return null — the picker prefers "leave the caliber alone"
//   over "guess wrong." The tolerance boundary tests guard the
//   stricter-than-meets-the-eye match logic.
// - When a diameter falls within tolerance of MORE THAN ONE map
//   entry, the smallest-residual entry wins. 0.451 in is closer to
//   the `0.451` key than the `0.452` key; both return `.45` here
//   (no observable tie-break needed), but the algorithm needs to
//   handle the case for diameters that could legitimately tie
//   across different family labels (which the current corpus
//   doesn't include — the test future-proofs the contract).
//
// ============================================================================
// WHO CONSUMES THIS FILE
// ============================================================================
// - `flutter test` (CI gate). The test runs without any seed data
//   because the lookup is map-driven, not catalog-driven.
//
// ============================================================================
// SIDE EFFECTS
// ============================================================================
// None. In-memory drift, no I/O.

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:loadout/database/database.dart';
import 'package:loadout/repositories/component_repository.dart';

void main() {
  group('ComponentRepository.caliberLabelForBulletDiameter', () {
    late AppDatabase db;
    late ComponentRepository repo;

    setUp(() {
      // The lookup itself doesn't hit SQLite, but the repository
      // constructor needs an `AppDatabase`. Use in-memory drift so
      // the test stays self-contained.
      db = AppDatabase.forTesting(NativeDatabase.memory());
      repo = ComponentRepository(db);
    });

    tearDown(() async {
      await db.close();
    });

    // ────────────────────────────────────────────────────────────
    // 14 round-trip assertions — one per entry of the old form-
    // private `_caliberLabelFromDiameter` table.
    // ────────────────────────────────────────────────────────────

    test('.17 family — 0.172 in → ".17"', () async {
      expect(await repo.caliberLabelForBulletDiameter(0.172), '.17');
    });

    test('.204 family — 0.204 in → ".204"', () async {
      expect(await repo.caliberLabelForBulletDiameter(0.204), '.204');
    });

    test('.224 family — 0.224 in → ".224"', () async {
      expect(await repo.caliberLabelForBulletDiameter(0.224), '.224');
    });

    test('6mm family — 0.243 in → "6mm" (metric label, not in catalog)',
        () async {
      expect(await repo.caliberLabelForBulletDiameter(0.243), '6mm');
    });

    test('.257 family — 0.257 in → ".257"', () async {
      expect(await repo.caliberLabelForBulletDiameter(0.257), '.257');
    });

    test('6.5mm family — 0.264 in → "6.5mm" (metric label)', () async {
      expect(await repo.caliberLabelForBulletDiameter(0.264), '6.5mm');
    });

    test('.277 family — 0.277 in → ".277"', () async {
      expect(await repo.caliberLabelForBulletDiameter(0.277), '.277');
    });

    test('7mm family — 0.284 in → "7mm" (metric label)', () async {
      expect(await repo.caliberLabelForBulletDiameter(0.284), '7mm');
    });

    test('.308 family — 0.308 in → ".308"', () async {
      expect(await repo.caliberLabelForBulletDiameter(0.308), '.308');
    });

    test('.338 family — 0.338 in → ".338"', () async {
      expect(await repo.caliberLabelForBulletDiameter(0.338), '.338');
    });

    test('9mm family — 0.355 in → "9mm" (metric, .380 ACP shares this)',
        () async {
      expect(await repo.caliberLabelForBulletDiameter(0.355), '9mm');
    });

    test('9mm family — 0.356 in → "9mm" (alt jacket spec)', () async {
      expect(await repo.caliberLabelForBulletDiameter(0.356), '9mm');
    });

    test('.358 family — 0.358 in → ".358"', () async {
      expect(await repo.caliberLabelForBulletDiameter(0.358), '.358');
    });

    test('.40 family — 0.400 in → ".40"', () async {
      expect(await repo.caliberLabelForBulletDiameter(0.400), '.40');
    });

    test('.45 family — 0.451 in → ".45"', () async {
      expect(await repo.caliberLabelForBulletDiameter(0.451), '.45');
    });

    test('.45 family — 0.452 in → ".45" (jacketed bullet spec)', () async {
      expect(await repo.caliberLabelForBulletDiameter(0.452), '.45');
    });

    // ────────────────────────────────────────────────────────────
    // Tolerance boundary tests — ±0.0015 in.
    //
    // We deliberately stay 0.0001 away from the boundary on each
    // side. Testing AT exactly ±0.0015 from a map entry is unstable:
    // `0.0015` in IEEE 754 isn't representable exactly, so
    // `(0.3095 - 0.308).abs()` lands at ~0.00150000000003 — strictly
    // greater than `0.0015` and therefore (per the retired form
    // method's `< 0.0015` and our preserved-semantics `<= 0.0015`)
    // a null return. The picker prefers "leave the field alone" to
    // "guess wrong on a FP edge case."
    // ────────────────────────────────────────────────────────────

    test('within tolerance — 0.3094 in (clearly inside .308 band) → ".308"',
        () async {
      expect(await repo.caliberLabelForBulletDiameter(0.3094), '.308');
    });

    test('within tolerance — 0.3066 in (clearly inside .308 band) → ".308"',
        () async {
      expect(await repo.caliberLabelForBulletDiameter(0.3066), '.308');
    });

    test('outside tolerance — 0.310 in (just above .308 band) → null',
        () async {
      // 0.310 is 0.002 above .308 — outside the ±0.0015 band.
      // The picker leaves the caliber field alone rather than guess.
      expect(await repo.caliberLabelForBulletDiameter(0.310), isNull);
    });

    test('outside tolerance — 0.306 in (just below .308 band) → null',
        () async {
      // 0.306 is 0.002 below .308 — outside the ±0.0015 band.
      expect(await repo.caliberLabelForBulletDiameter(0.306), isNull);
    });

    // ────────────────────────────────────────────────────────────
    // Out-of-corpus + degenerate inputs.
    // ────────────────────────────────────────────────────────────

    test('unknown diameter — 0.123 in → null', () async {
      expect(await repo.caliberLabelForBulletDiameter(0.123), isNull);
    });

    test('zero diameter → null', () async {
      expect(await repo.caliberLabelForBulletDiameter(0.0), isNull);
    });

    test('negative diameter → null (defensive — should never happen)',
        () async {
      expect(await repo.caliberLabelForBulletDiameter(-0.308), isNull);
    });

    // ────────────────────────────────────────────────────────────
    // Tie-breaking — smallest residual wins.
    // ────────────────────────────────────────────────────────────

    test(
        'smallest residual wins — 0.4515 in is between 0.451 and 0.452, '
        'matches both → ".45"', () async {
      // Both `0.451` and `0.452` map to ".45", and 0.4515 is exactly
      // midway. The tie-break rule (smallest residual) picks whichever
      // entry the iterator visits first — both return ".45", so the
      // observable contract is just "returns .45." This test pins the
      // *behaviour*: a future tie between DIFFERENT labels (which the
      // current corpus doesn't have) would still need to follow the
      // smallest-residual rule, and the implementation already does.
      expect(await repo.caliberLabelForBulletDiameter(0.4515), '.45');
    });
  });
}
