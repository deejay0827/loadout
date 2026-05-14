// FILE: test/seed_data_schema_invariants_test.dart
//
// ============================================================================
// WHAT THIS FILE DOES
// ============================================================================
// Per-catalog schema invariants for `assets/seed_data/*.json`. Each
// test asserts the on-disk JSON shape matches what the corresponding
// seed-loader method actually reads — so a future catalog edit that
// drops a required field, or adds a row with the wrong field-name
// casing, trips a unit test BEFORE shipping a first-launch crash.
//
// The trigger: v2.3 close-out shipped two crashes that this kind of
// test would have caught:
//   1. `optics.json` was deleted but `SeedLoader._seedOptics()` still
//      tried to load it — fixed in the v2.3 hotfix, regression
//      covered by `test/seed_loader_optics_removed_test.dart`.
//   2. Phase 2 added 16 animal rows to `targets.json` using snake_case
//      field names (`width_in` / `height_in` / `color_hex`) but the
//      seeder only read camelCase (`widthIn` / `heightIn` / `colorHex`),
//      so the first animal row hit produced
//      "type 'Null' is not a subtype of type 'num' in type cast"
//      on `(m['widthIn'] as num)`. This file's first group locks in
//      that the seeder's dual-casing read covers every row going
//      forward.
//
// ============================================================================
// WHY IT EXISTS IN THE ARCHITECTURE
// ============================================================================
// `test/assets_present_test.dart` confirms every file referenced by
// the manifest is bundle-reachable. `test/seed_updater_allowlist_test.dart`
// confirms the manifest keys match the SeedUpdater allowlist. Neither
// validates the INTERIOR shape of the JSON — only its existence.
// This file fills that gap with a row-level shape check for each
// catalog the seeder actively consumes.
//
// ============================================================================
// SIDE EFFECTS
// ============================================================================
// Reads `assets/seed_data/*.json` from disk via `dart:io`. No bundle,
// no DB, no network.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  group('targets.json — seed_loader._seedTargets schema invariants', () {
    late List<Map<String, dynamic>> rows;

    setUpAll(() {
      final raw = File('assets/seed_data/targets.json').readAsStringSync();
      rows = (jsonDecode(raw) as List).cast<Map<String, dynamic>>();
    });

    test('every row carries name + category (required by Targets schema)',
        () {
      // Phase 9.5 — the legacy `shape` field was retired in favour of a
      // closed `category` enum (circle / square / rectangle / ipsc /
      // animal / special). The Targets table column was renamed
      // accordingly. This invariant catches a seed file that ships
      // without a category — the seed loader would `throw StateError`
      // on first launch rather than dropping the row silently.
      for (final r in rows) {
        expect(r['name'], isA<String>(),
            reason: 'row ${r.toString().substring(0, 60)}... lacks `name`');
        expect(r['category'], isA<String>(),
            reason: 'row ${r['name'] ?? '?'} lacks `category`');
      }
    });

    test('every row carries widthIn OR width_in as a numeric value', () {
      // The seed loader uses a dual-cased read:
      //   final widthIn = (m['width_in'] ?? m['widthIn']) as num;
      // Both keys must therefore yield a non-null num on every row.
      // 49 conventional rows ship camelCase (`widthIn`); 16 animal
      // rows added in Phase 2 ship snake_case (`width_in`). Either
      // form is acceptable — but at least ONE of the two MUST be a
      // numeric value or the cast crashes.
      for (final r in rows) {
        final width = r['width_in'] ?? r['widthIn'];
        expect(width, isA<num>(),
            reason: 'row "${r['name']}" provides neither `width_in` nor '
                '`widthIn` as a numeric value. The seed loader would '
                'crash with "type \'Null\' is not a subtype of type '
                '\'num\' in type cast" on this row.');
      }
    });

    test('every row carries heightIn OR height_in as a numeric value', () {
      for (final r in rows) {
        final height = r['height_in'] ?? r['heightIn'];
        expect(height, isA<num>(),
            reason: 'row "${r['name']}" provides neither `height_in` nor '
                '`heightIn` as a numeric value.');
      }
    });

    test('colorHex / color_hex is null or String on every row', () {
      // The seed loader defaults to '#ffffff' when both are null, so
      // either-or-neither is acceptable. What's NOT acceptable: a
      // non-string non-null value (would crash the `as String?` cast).
      for (final r in rows) {
        final color = r['color_hex'] ?? r['colorHex'];
        expect(color == null || color is String, isTrue,
            reason: 'row "${r['name']}" has a non-string `color_hex` / '
                '`colorHex` value: ${color.runtimeType}');
      }
    });
  });

  group('target_racks.json — _seedTargetRacks schema invariants', () {
    late List<Map<String, dynamic>> racks;

    setUpAll(() {
      final raw = File('assets/seed_data/target_racks.json').readAsStringSync();
      final root = jsonDecode(raw) as Map<String, dynamic>;
      racks = (root['racks'] as List).cast<Map<String, dynamic>>();
    });

    test('every rack provides mount_style OR rack_kind as a String', () {
      // Mirrors `_seedTargetRacks` line 867-868:
      //   final mountStyle =
      //       (m['mount_style'] as String?) ?? (m['rack_kind'] as String);
      // The legacy `rack_kind` is the non-null fallback when `mount_style`
      // is absent. At least one must be a String, or the cast crashes.
      for (final r in racks) {
        final mountOrKind = r['mount_style'] ?? r['rack_kind'];
        expect(mountOrKind, isA<String>(),
            reason: 'rack "${r['name']}" provides neither `mount_style` '
                'nor `rack_kind` as a String.');
      }
    });

    test('every rack provides total_width_in and total_height_in as num', () {
      for (final r in racks) {
        expect(r['total_width_in'], isA<num>(),
            reason: 'rack "${r['name']}" lacks numeric `total_width_in`');
        expect(r['total_height_in'], isA<num>(),
            reason: 'rack "${r['name']}" lacks numeric `total_height_in`');
      }
    });
  });

  group('reticles.json — minimum schema invariants', () {
    late List<Map<String, dynamic>> rows;

    setUpAll(() {
      final raw = File('assets/seed_data/reticles.json').readAsStringSync();
      rows = (jsonDecode(raw) as List).cast<Map<String, dynamic>>();
    });

    test('every row carries id + model + manufacturer + subtension_origin', () {
      for (final r in rows) {
        expect(r['id'], isA<String>(),
            reason: 'reticle row lacks `id`');
        expect(r['model'], isA<String>(),
            reason: 'reticle row "${r['id']}" lacks `model`');
        expect(r['manufacturer'], isA<String>(),
            reason: 'reticle row "${r['id']}" lacks `manufacturer`');
        expect(r['subtension_origin'], isA<String>(),
            reason: 'reticle row "${r['id']}" lacks `subtension_origin`');
      }
    });

    test('every published_spec row has a non-null calibration_provenance', () {
      for (final r in rows.where((r) => r['subtension_origin'] == 'published_spec')) {
        final cp = r['calibration_provenance'];
        expect(cp, isA<Map<String, dynamic>>(),
            reason: 'published_spec reticle "${r['id']}" lacks '
                '`calibration_provenance`. The §7.7 disclaimer template '
                'would render the generic fallback instead of a proper '
                '"Calibrated to [Manufacturer] [Reticle Name]" label.');
        final m = (cp as Map<String, dynamic>)['manufacturer'];
        final n = cp['reticle_name'];
        expect(m, isA<String>(),
            reason: 'published_spec reticle "${r['id']}" has '
                '`calibration_provenance.manufacturer` of wrong type.');
        expect(n, isA<String>(),
            reason: 'published_spec reticle "${r['id']}" has '
                '`calibration_provenance.reticle_name` of wrong type.');
      }
    });
  });

  group('scopes.json — minimum schema invariants', () {
    late List<Map<String, dynamic>> rows;

    setUpAll(() {
      final raw = File('assets/seed_data/scopes.json').readAsStringSync();
      rows = (jsonDecode(raw) as List).cast<Map<String, dynamic>>();
    });

    test('every row carries id + manufacturer + model_name', () {
      for (final r in rows) {
        expect(r['id'], isA<String>(),
            reason: 'scope row lacks `id` (used as scope_reticle_options FK)');
        expect(r['manufacturer'], isA<String>(),
            reason: 'scope row "${r['id']}" lacks `manufacturer`');
        expect(r['model_name'], isA<String>(),
            reason: 'scope row "${r['id']}" lacks `model_name`');
      }
    });

    test('every row has a unique id slug', () {
      final ids = rows.map((r) => r['id'] as String).toList();
      final unique = ids.toSet();
      expect(unique.length, ids.length,
          reason: 'duplicate scope id detected — Phase 5 added 11 rows; '
              'a copy/paste error in the slug derivation would crash '
              'scope_reticle_options lookups.');
    });
  });

  group('scope_reticle_options.json — referential integrity', () {
    test('every scope_id and reticle_id resolves', () {
      final scopes = (jsonDecode(File('assets/seed_data/scopes.json').readAsStringSync()) as List)
          .cast<Map<String, dynamic>>();
      final reticles = (jsonDecode(File('assets/seed_data/reticles.json').readAsStringSync()) as List)
          .cast<Map<String, dynamic>>();
      final options = (jsonDecode(File('assets/seed_data/scope_reticle_options.json').readAsStringSync()) as List)
          .cast<Map<String, dynamic>>();

      final scopeIds = scopes.map((s) => s['id'] as String).toSet();
      final reticleIds = reticles.map((r) => r['id'] as String).toSet();

      for (final o in options) {
        expect(scopeIds.contains(o['scope_id']), isTrue,
            reason: 'scope_reticle_options row references unknown scope_id '
                '"${o['scope_id']}".');
        expect(reticleIds.contains(o['reticle_id']), isTrue,
            reason: 'scope_reticle_options row for scope_id '
                '"${o['scope_id']}" references unknown reticle_id '
                '"${o['reticle_id']}".');
      }
    });
  });
}
