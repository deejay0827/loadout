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

    test('59 rows total (58 base + 1 new "2 in Square")', () {
      expect(rows.length, 59);
    });

    test('"2 in Square" row exists with correct geometry', () {
      final square2 =
          rows.where((r) => r['name'] == '2 in Square').toList();
      expect(square2, hasLength(1));
      expect(square2.first['shape'], 'square');
      expect(square2.first['width_in'], 2.0);
      expect(square2.first['height_in'], 2.0);
    });

    test('every generic circle name matches ^N in Circle\$', () {
      final circles = rows.where((r) => r['shape'] == 'circle');
      final pat = RegExp(r'^\d+ in Circle$');
      for (final r in circles) {
        expect(pat.hasMatch(r['name'] as String), isTrue,
            reason: "Circle name '${r['name']}' fails pattern");
      }
    });

    test('every generic square name matches ^N in Square\$', () {
      final squares = rows.where((r) => r['shape'] == 'square');
      final pat = RegExp(r'^\d+ in Square$');
      for (final r in squares) {
        expect(pat.hasMatch(r['name'] as String), isTrue,
            reason: "Square name '${r['name']}' fails pattern");
      }
    });

    test('every GENERIC rectangle name matches Phase 8 pattern', () {
      // The 6 generic rectangles ship as `12" x 18" Rectangle` etc.
      // Named-rectangle rows (NRA SR-1, F-Class F-Open, Bullseye,
      // Dueling Tree) keep their proper names and aren't matched
      // by this pattern. Filter to the generic ones by name shape.
      final pat =
          RegExp(r'^\d+(?:\.\d+)?" x \d+(?:\.\d+)?" Rectangle$');
      final genericRects = rows
          .where((r) => r['shape'] == 'rectangle')
          .where((r) => pat.hasMatch(r['name'] as String))
          .toList();
      // The catalog has exactly 6 generic rectangles per Phase 8
      // (12×18, 18×24, 24×30, 24×36, 36×48, 36×60).
      expect(genericRects, hasLength(6));
    });

    test('every animal name contains " in" (dims appended)', () {
      final animals =
          rows.where((r) => r['category'] == 'animal').toList();
      // Phase 8 expanded all 16 animal names from a single noun
      // (e.g. `"Deer"`) to `"Deer 60×32 in"` for picker readability.
      expect(animals, hasLength(16));
      for (final r in animals) {
        expect((r['name'] as String).contains(' in'), isTrue,
            reason: "Animal name '${r['name']}' lacks dimensions");
      }
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
