// FILE: test/targets_catalog_test.dart
//
// ============================================================================
// WHAT THIS FILE DOES
// ============================================================================
// Catalog-shape regression tests for `assets/seed_data/targets.json`.
// Phase 8 Group D rewrote every row's `name` field so the catalog
// directly drives the picker dropdown label (the dynamic
// `_targetDropdownLabel` generator was simplified to `=> t.name`).
// These tests pin the naming patterns so a future catalog edit
// can't silently regress the dropdown UX (e.g. by reintroducing
// duplicate-dimension IPSC names like
// `"IPSC USPSA Classic 18×30 in 18×30 in"` that Phase 8 fixed).
//
// Assertions covered:
//   * Row count is 59 (was 58 pre-Phase-8; +1 for the new
//     `2 in Square` row).
//   * `2 in Square` is present.
//   * Generic circles match `^\d+ in Circle$`.
//   * Generic squares match `^\d+ in Square$`.
//   * Generic rectangles match `^\d+(\.\d+)?" x \d+(\.\d+)?" Rectangle$`.
//   * Animal names all contain ` in` (the appended dims).
//   * IPSC names have NO duplicate dimensions — `count('×') <= 1`.
//
// ============================================================================
// SIDE EFFECTS
// ============================================================================
// None. Pure JSON parse + regex / set assertions.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  group('targets.json — Phase 8 Group D catalog shape', () {
    late List<Map<String, dynamic>> rows;

    setUpAll(() {
      final raw =
          File('assets/seed_data/targets.json').readAsStringSync();
      rows = (jsonDecode(raw) as List).cast<Map<String, dynamic>>();
    });

    test('91 rows total (Phase 9: 43 non-animal + 48 animals)', () {
      // Pre-Phase-9: 59 rows (43 non-animal + 16 animals).
      // Phase 9 Group B expanded each of 16 species to 3 sizes
      // (Small / Medium / Large), bringing the animal count to 48.
      expect(rows.length, 91);
    });

    test('48 animal rows total (16 species × 3 sizes)', () {
      final animals =
          rows.where((r) => r['category'] == 'animal').toList();
      expect(animals, hasLength(48));
    });

    test(
        'every animal has center_point.horizontal_from_left = 0.6 '
        '(Phase 9 — was 0.7 in Phase 7a/8)', () {
      final animals =
          rows.where((r) => r['category'] == 'animal').toList();
      for (final r in animals) {
        final cp = r['center_point'] as Map<String, dynamic>?;
        expect(cp, isNotNull,
            reason:
                "Animal '${r['name']}' is missing center_point");
        expect(cp!['horizontal_from_left'], 0.6,
            reason: "Animal '${r['name']}' has wrong "
                "horizontal_from_left (expected 0.6)");
      }
    });

    test(
        'each of 16 species has 3 size variants '
        '(Small / Medium / Large)', () {
      final animals =
          rows.where((r) => r['category'] == 'animal').toList();
      // Group by shape_id (each species should appear thrice).
      final bySpecies = <String, List<Map<String, dynamic>>>{};
      for (final r in animals) {
        final sid = r['shape_id'] as String?;
        if (sid == null) continue;
        bySpecies.putIfAbsent(sid, () => []).add(r);
      }
      expect(bySpecies, hasLength(16),
          reason: 'Expected 16 unique animal species; got '
              '${bySpecies.length}');
      for (final entry in bySpecies.entries) {
        expect(entry.value, hasLength(3),
            reason: "Species '${entry.key}' should have 3 size "
                "variants; got ${entry.value.length}");
        final names = entry.value.map((r) => r['name'] as String);
        // Phase 9.5 — names are "Species, Size" (e.g. "Bear, Small"),
        // not "Size Species" (e.g. "Small Bear"). The size suffix is
        // what we check for now.
        expect(names.any((n) => n.endsWith(', Small')), isTrue,
            reason: "Species '${entry.key}' missing Small variant");
        expect(names.any((n) => n.endsWith(', Medium')), isTrue,
            reason:
                "Species '${entry.key}' missing Medium variant");
        expect(names.any((n) => n.endsWith(', Large')), isTrue,
            reason: "Species '${entry.key}' missing Large variant");
      }
    });

    test('all row IDs are unique', () {
      final ids = <String>{};
      for (final r in rows) {
        final id = r['id'] as String?;
        if (id == null) continue;
        expect(ids.add(id), isTrue,
            reason: "Duplicate id '$id' found in catalog");
      }
    });

    test('"2 in Square" row exists with correct geometry', () {
      final square2 =
          rows.where((r) => r['name'] == '2 in Square').toList();
      expect(square2, hasLength(1));
      // Phase 9.5 — `shape` field dropped; `category` is the
      // taxonomy now.
      expect(square2.first['category'], 'square');
      expect(square2.first['width_in'], 2.0);
      expect(square2.first['height_in'], 2.0);
    });

    test('every generic circle name matches ^N in Circle\$', () {
      final circles = rows.where((r) => r['category'] == 'circle');
      final pat = RegExp(r'^\d+ in Circle$');
      for (final r in circles) {
        expect(pat.hasMatch(r['name'] as String), isTrue,
            reason: "Circle name '${r['name']}' fails pattern");
      }
    });

    test('every generic square name matches ^N in Square\$', () {
      final squares = rows.where((r) => r['category'] == 'square');
      final pat = RegExp(r'^\d+ in Square$');
      for (final r in squares) {
        expect(pat.hasMatch(r['name'] as String), isTrue,
            reason: "Square name '${r['name']}' fails pattern");
      }
    });

    test('every GENERIC rectangle name matches Phase 8 pattern', () {
      final pat =
          RegExp(r'^\d+(?:\.\d+)?" x \d+(?:\.\d+)?" Rectangle$');
      final genericRects = rows
          .where((r) => r['category'] == 'rectangle')
          .where((r) => pat.hasMatch(r['name'] as String))
          .toList();
      expect(genericRects, hasLength(6));
    });

    test(
        'Phase 9.5 — category enum populated for every row '
        '(circle / square / rectangle / ipsc / animal / special)',
        () {
      const valid = <String>{
        'circle',
        'square',
        'rectangle',
        'ipsc',
        'animal',
        'special',
      };
      for (final r in rows) {
        final c = r['category'];
        expect(c, isA<String>(),
            reason: "Row '${r['name']}' missing category");
        expect(valid.contains(c), isTrue,
            reason: "Row '${r['name']}' has invalid category '$c'");
      }
    });

    test(
        'Phase 9.5 — `shape` field is GONE from every row '
        '(category-driven taxonomy)',
        () {
      for (final r in rows) {
        expect(r.containsKey('shape'), isFalse,
            reason: "Row '${r['name']}' still carries legacy 'shape' field");
      }
    });

    test('Phase 9.5 — animal names use the new "Species, Size" format', () {
      final animals =
          rows.where((r) => r['category'] == 'animal').toList();
      expect(animals, hasLength(48));
      // Phase 9.5 — names are "Bear, Small" / "Mountain Lion, Large"
      // etc. Title-case species; size after a comma. No dimensions in
      // the name.
      final pat = RegExp(r'^[A-Z][a-zA-Z ]+, (Small|Medium|Large)$');
      for (final r in animals) {
        expect(pat.hasMatch(r['name'] as String), isTrue,
            reason: "Animal name '${r['name']}' doesn't match "
                "'Species, Size' format");
      }
    });

    test('Phase 9.5 — special-category rows: pepper_popper + texas_star', () {
      final specials =
          rows.where((r) => r['category'] == 'special').toList();
      expect(specials, hasLength(3),
          reason: '2 poppers + Texas Star = 3 special-category rows');
      final shapeIds = specials.map((r) => r['shape_id']).toSet();
      expect(shapeIds, containsAll(['pepper_popper', 'texas_star']));
    });

    test('Phase 9.5 — category counts match expected', () {
      final counts = <String, int>{};
      for (final r in rows) {
        final c = r['category'] as String;
        counts[c] = (counts[c] ?? 0) + 1;
      }
      expect(counts['circle'], 13);
      expect(counts['square'], 6);
      expect(counts['rectangle'], 15);
      expect(counts['ipsc'], 6);
      expect(counts['animal'], 48);
      expect(counts['special'], 3);
    });

    test('no IPSC name has duplicate dimensions (Phase 8 bugfix)', () {
      // Pre-Phase-8, dynamic `_targetDropdownLabel` appended the
      // (w × h) dimensions to every row's display label — but IPSC
      // rows already had dims in their catalog `name`, producing
      // labels like `"IPSC USPSA Classic 18×30 in 18×30 in"`.
      // Phase 8 fixed this by simplifying the label generator to
      // `=> t.name`; this assertion guards the catalog side: no
      // row's name should carry doubled dimensions.
      for (final r in rows) {
        final name = r['name'] as String;
        expect('×'.allMatches(name).length, lessThanOrEqualTo(1),
            reason: "Row name '$name' carries multiple '×' dim "
                'separators (likely the duplicate-dims bug).');
      }
    });
  });
}
