// FILE: test/asset_updater_allowlist_test.dart
//
// ============================================================================
// WHAT THIS FILE DOES
// ============================================================================
// FIRM regression test for the seed-catalog live-update path,
// migrated verbatim from the former `seed_updater_allowlist_test.dart`
// (VFP Phase 4 Group C — `SeedUpdater` → `AssetUpdater(
// seedCatalogConfig)`). It guards TWO things:
//
//   1. (preserved verbatim) the bundled `assets/seed_data/
//      manifest.json` declares only keys `allowedKeys` recognises,
//      every `allowedKeys` entry has a manifest row, and every
//      manifest filename resolves through `rootBundle`.
//   2. (added — §3 Task 2 / §5 backward-compat constraints) the
//      `seedCatalogConfig` reproduces the former `SeedUpdater`
//      behaviour BIT-FOR-BIT: the `seed_version_` /
//      `seed_needs_reseed_` SharedPrefs prefixes, the
//      `seed_data/manifest.json` + `seed_data/<file>` Storage paths,
//      the COMPLETE filename security boundary (not a bare
//      `.endsWith('.json')`), and the `_validateShape` content
//      contract. Drift in any of these orphans field-installed
//      caches or weakens a launch-critical security boundary.
//
// ============================================================================
// WHY IT EXISTS
// ============================================================================
// A missed allowlist key, a changed SharedPrefs prefix, a moved
// storage path, or a softened filename guard are all
// silent-until-a-user-reports-it failures in the launch-critical
// catalog hot-fix path. CI catches them. This test stays FIRM — the
// seed assertions must pass verbatim against any future refactor.
//
// ============================================================================
// SIDE EFFECTS
// ============================================================================
// None. Reads the bundled manifest from the asset bundle; exercises
// pure config predicates.

import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:loadout/services/asset_updater_config.dart';
import 'package:loadout/services/asset_updater_configs.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // -------------------------------------------------------------------------
  // Preserved verbatim from seed_updater_allowlist_test.dart — only the
  // `allowedKeys` source moved (now asset_updater_configs.dart) and the
  // prose says AssetUpdater. Assertions UNCHANGED.
  // -------------------------------------------------------------------------
  group('AssetUpdater(seedCatalogConfig) allowlist <-> bundled manifest',
      () {
    test('every manifest key is in allowedKeys', () async {
      final raw =
          await rootBundle.loadString('assets/seed_data/manifest.json');
      final decoded = json.decode(raw) as Map<String, dynamic>;
      final files = decoded['files'] as Map<String, dynamic>;
      final missing = <String>[];
      for (final key in files.keys) {
        if (!allowedKeys.contains(key)) {
          missing.add(key);
        }
      }
      expect(missing, isEmpty,
          reason:
              'These manifest keys are not in `allowedKeys` in '
              'lib/services/asset_updater_configs.dart — the runtime '
              'would silently drop their updates:\n  '
              '${missing.join("\n  ")}');
    });

    test('every allowedKeys entry is in the bundled manifest', () async {
      final raw =
          await rootBundle.loadString('assets/seed_data/manifest.json');
      final decoded = json.decode(raw) as Map<String, dynamic>;
      final files =
          (decoded['files'] as Map<String, dynamic>).keys.toSet();
      final orphans = <String>[];
      for (final key in allowedKeys) {
        if (!files.contains(key)) {
          orphans.add(key);
        }
      }
      expect(orphans, isEmpty,
          reason:
              'These `allowedKeys` entries have no matching row in '
              'assets/seed_data/manifest.json — either add the file '
              'and bump the manifest, or remove the orphan from '
              '`allowedKeys`:\n  ${orphans.join("\n  ")}');
    });

    test('every manifest filename points at a file that exists in the bundle',
        () async {
      final raw =
          await rootBundle.loadString('assets/seed_data/manifest.json');
      final decoded = json.decode(raw) as Map<String, dynamic>;
      final files = decoded['files'] as Map<String, dynamic>;
      final missing = <String>[];
      for (final entry in files.entries) {
        final spec = entry.value as Map<String, dynamic>;
        final filename = spec['filename'] as String;
        try {
          await rootBundle.load('assets/seed_data/$filename');
        } catch (_) {
          missing.add('${entry.key} → $filename');
        }
      }
      expect(missing, isEmpty,
          reason:
              'These manifest entries point at files that are not '
              'reachable through rootBundle. Either the file is '
              'missing from disk, or pubspec.yaml is missing the '
              "asset declaration (CLAUDE.md § 12a):\n"
              '  ${missing.join("\n  ")}');
    });
  });

  // -------------------------------------------------------------------------
  // ADDED — bit-for-bit backward-compat constants (§3 Task 2 / §5 risks).
  // These pin the exact values whose drift would orphan field-installed
  // caches or weaken the launch-critical security boundary.
  // -------------------------------------------------------------------------
  group('seedCatalogConfig — bit-for-bit former-SeedUpdater contract', () {
    test('SharedPrefs prefixes are exactly the legacy values', () {
      expect(seedVersionPrefix, 'seed_version_');
      expect(seedNeedsReseedPrefix, 'seed_needs_reseed_');
      expect(seedCatalogConfig.versionTrackerPrefix, 'seed_version_');
    });

    test('Storage paths are the real live bucket layout (§0.5 C-a)', () {
      expect(seedCatalogConfig.manifestStoragePath,
          'seed_data/manifest.json');
      expect(seedCatalogConfig.storagePathForFile('cartridges.json'),
          'seed_data/cartridges.json');
      expect(seedCatalogConfig.storagePathForFile('components/chassis.json'),
          'seed_data/components/chassis.json');
    });

    test('write strategy + size cap preserved (§0.5 C-f)', () {
      expect(seedCatalogConfig.writeStrategy, WriteStrategy.text);
      expect(seedCatalogConfig.maxFileBytes, 8 * 1024 * 1024);
      expect(seedCatalogConfig.contentDecoder, isNotNull);
    });

    test('filename validator is the FULL guard, not just .json (§0.5 C-b)',
        () {
      final f = seedCatalogConfig.filenameValidator;
      // Accept: simple basename + one subdir level.
      expect(f('cartridges.json'), isTrue);
      expect(f('components/chassis.json'), isTrue);
      // Reject: the security boundary the spec one-liner would lose.
      expect(f('evil.txt'), isFalse, reason: 'non-.json');
      expect(f('..//etc/passwd.json'), isFalse, reason: 'traversal');
      expect(f('../secrets.json'), isFalse, reason: 'parent-traversal');
      expect(f('a/b/c.json'), isFalse, reason: 'depth > 1 subdir');
      expect(f('\\windows\\x.json'), isFalse, reason: 'backslash');
      expect(f('/abs/x.json'), isFalse, reason: 'absolute');
      expect(f('.hidden.json'), isFalse, reason: 'hidden');
      expect(f('a b.json'), isFalse, reason: 'whitespace metachar');
      expect(f('x;rm -rf.json'), isFalse, reason: 'shell metachar');
      expect(f(''), isFalse);
    });

    test('content validator preserves _validateShape (both shapes)', () {
      final v = seedCatalogConfig.contentValidator;
      Uint8List b(String s) => Uint8List.fromList(utf8.encode(s));
      const flat = AssetEntry(
          key: 'cartridges', version: 2, filename: 'cartridges.json');
      const mfr =
          AssetEntry(key: 'powders', version: 2, filename: 'powders.json');
      const comp = AssetEntry(
          key: 'firearm_components_barrels',
          version: 2,
          filename: 'components/barrels.json');

      // Flat-array keys: top-level must be a List.
      expect(() => v(b('[]'), flat), returnsNormally);
      expect(() => v(b('[{"a":1}]'), flat), returnsNormally);
      expect(() => v(b('{}'), flat),
          throwsA(isA<AssetValidationException>()));
      // firearm_components_* are flat-array too.
      expect(() => v(b('[]'), comp), returnsNormally);
      expect(() => v(b('{}'), comp),
          throwsA(isA<AssetValidationException>()));
      // Manufacturer-shape keys: {manufacturers:[...]}.
      expect(() => v(b('{"manufacturers":[]}'), mfr), returnsNormally);
      expect(() => v(b('[]'), mfr),
          throwsA(isA<AssetValidationException>()));
      expect(() => v(b('{"x":1}'), mfr),
          throwsA(isA<AssetValidationException>()));
      // Garbage JSON → rejected (not a partial overwrite).
      expect(() => v(b('not json'), flat),
          throwsA(isA<AssetValidationException>()));
    });

    test('post-apply hook exists (the §0.5 C-c re-seed trigger)', () {
      // The hook is what sets seed_needs_reseed_<key>; its absence
      // would silently regress the launch-critical re-seed path.
      expect(seedCatalogConfig.onAssetApplied, isNotNull);
    });
  });
}
