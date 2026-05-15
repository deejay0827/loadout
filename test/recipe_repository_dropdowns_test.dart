// FILE: test/recipe_repository_dropdowns_test.dart
//
// ============================================================================
// WHAT THIS FILE DOES
// ============================================================================
// Drift round-trip tests for the Phase Two Group 2 (v42) recipe
// Status + Use Case dropdown reference tables. Confirms:
//
//   1. `RecipeRepository.allStatuses()` round-trips inserted rows
//      preserving value + label.
//   2. `RecipeRepository.allUseCases()` round-trips the same way.
//   3. Each table is independent (empty status table doesn't
//      affect use cases and vice-versa).
//   4. Order returned matches the seed-author insertion order
//      (drift's default SELECT order on rowid).
//
// Pre-Phase-Two-Group-2 these dropdowns were backed by private
// const record lists in `recipe_form_screen.dart`; the value /
// label pairs were a compile-time tautology. After Group 2 they
// live in seeded drift tables, and the round-trip contract has to
// be pinned. A future refactor that swaps column wiring or drops
// the label field would otherwise ship silently and degrade the
// dropdown UX to raw enum-style values.
//
// ============================================================================
// WHY IT EXISTS IN THE ARCHITECTURE
// ============================================================================
// Phase Two Group 2 chose `Future<List<({String value, String label})>>`
// for the repository return type (preserving both the persisted
// enum-style key AND the display label) rather than the spec's
// looser `Future<List<String>>` — see the spec deviation surfaced
// in Group 2's FINDINGS. These tests pin that contract.
//
// ============================================================================
// WHY THIS IS HARDER THAN IT LOOKS
// ============================================================================
// - The repository returns a `List<({String value, String label})>`
//   Dart record, not a typed class. The test uses positional
//   member access (`.value`, `.label`) which the analyzer infers
//   without an explicit type annotation.
// - The drift `Value` symbol collides with flutter_test's `isNull`
//   matcher; this file follows the same `show Value` pattern as
//   `recipe_repository_templates_test.dart` even though we don't
//   need `Value` here. (Including drift's unrestricted import
//   would shadow `isNull` — defensive future-proofing.)
//
// ============================================================================
// WHO CONSUMES THIS FILE
// ============================================================================
// - `flutter test` (CI gate).
//
// ============================================================================
// SIDE EFFECTS
// ============================================================================
// None. In-memory drift; no I/O.

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:loadout/database/database.dart';
import 'package:loadout/repositories/recipe_repository.dart';

void main() {
  late AppDatabase db;
  late RecipeRepository repo;

  setUp(() {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    repo = RecipeRepository(db);
  });

  tearDown(() async {
    await db.close();
  });

  group('RecipeRepository.allStatuses', () {
    test('empty table returns an empty list', () async {
      final result = await repo.allStatuses();
      expect(result, isEmpty);
    });

    test('round-trips value + label pairs in insertion order',
        () async {
      await db.into(db.recipeStatuses).insert(
            RecipeStatusesCompanion.insert(
              value: 'active',
              label: 'Active',
            ),
          );
      await db.into(db.recipeStatuses).insert(
            RecipeStatusesCompanion.insert(
              value: 'testing',
              label: 'Testing',
            ),
          );
      await db.into(db.recipeStatuses).insert(
            RecipeStatusesCompanion.insert(
              value: 'retired',
              label: 'Retired',
            ),
          );

      final statuses = await repo.allStatuses();
      expect(statuses, hasLength(3));
      expect(statuses[0].value, 'active');
      expect(statuses[0].label, 'Active');
      expect(statuses[1].value, 'testing');
      expect(statuses[1].label, 'Testing');
      expect(statuses[2].value, 'retired');
      expect(statuses[2].label, 'Retired');
    });
  });

  group('RecipeRepository.allUseCases', () {
    test('empty table returns an empty list', () async {
      final result = await repo.allUseCases();
      expect(result, isEmpty);
    });

    test('round-trips the four shipping use cases', () async {
      const seed = [
        (value: 'match', label: 'Match'),
        (value: 'practice', label: 'Practice'),
        (value: 'hunting', label: 'Hunting'),
        (value: 'plinking', label: 'Plinking'),
      ];
      for (final s in seed) {
        await db.into(db.recipeUseCases).insert(
              RecipeUseCasesCompanion.insert(
                value: s.value,
                label: s.label,
              ),
            );
      }

      final useCases = await repo.allUseCases();
      expect(useCases, hasLength(4));
      for (var i = 0; i < seed.length; i++) {
        expect(useCases[i].value, seed[i].value);
        expect(useCases[i].label, seed[i].label);
      }
    });
  });

  group('table independence', () {
    test('inserting use cases does not affect allStatuses() result',
        () async {
      await db.into(db.recipeUseCases).insert(
            RecipeUseCasesCompanion.insert(
              value: 'match',
              label: 'Match',
            ),
          );

      expect(await repo.allStatuses(), isEmpty);
      expect(await repo.allUseCases(), hasLength(1));
    });

    test('inserting statuses does not affect allUseCases() result',
        () async {
      await db.into(db.recipeStatuses).insert(
            RecipeStatusesCompanion.insert(
              value: 'active',
              label: 'Active',
            ),
          );

      expect(await repo.allUseCases(), isEmpty);
      expect(await repo.allStatuses(), hasLength(1));
    });
  });
}
