// FILE: lib/services/asset_updater_configs.dart
//
// ============================================================================
// WHAT THIS FILE DOES
// ============================================================================
// The concrete [AssetUpdaterConfig] instances + the relocated public
// constants that other code imports. VFP Phase 4 Group C ships ONE:
//
//   * `seedCatalogConfig` — reproduces the entire former
//     `SeedUpdater` behaviour BIT-FOR-BIT (same manifest path, same
//     allowlist, same full filename security boundary, same
//     `_validateShape`, same `<docs>/seed_data/` storage root, same
//     `seed_version_` prefix, same 8 MB cap, AND the
//     `seed_needs_reseed_<key>=true` post-apply trigger that
//     `seed_loader.dart` reads to perform the deferred DB re-seed).
//
// Group D adds `photoAssetConfig` here.
//
// The public consts `allowedKeys`, `seedVersionPrefix`,
// `seedNeedsReseedPrefix` are RELOCATED here verbatim from the
// deleted `seed_updater.dart` so existing importers
// (`seed_loader.dart`, the regression test) keep the SAME VALUES —
// only the import path moves (value-preserving relocation is
// behaviourally inert; the §412 risk is about changing the value,
// which we do not).
//
// ============================================================================
// WHY THIS IS HARDER THAN IT LOOKS
// ============================================================================
//   * `allowedKeys` MUST stay the exact set the bundled manifest
//     uses — `asset_updater_allowlist_test.dart` asserts the
//     bundled manifest's keys are a subset. No add/remove here.
//   * `_isSafeSeedFilename` is the COMPLETE former
//     `_isSafeManifestFilename` (path-traversal / backslash /
//     leading-slash / depth / hidden / shell-metachar / `.json`) —
//     §0.5 C-b: NOT a bare `.endsWith('.json')`. The regression
//     test pins this boundary; it must not soften.
//   * `seedCatalogConfig.storageRootProvider` ignores its `key`
//     arg and returns the ONE shared `<docs>/seed_data` dir
//     (SeedUpdater used a single dir for every key — preserved).
//     The photo config (Group D) is per-category instead.
//   * `manifestStoragePath` = `seed_data/manifest.json` and
//     `storagePathForFile` = `seed_data/<filename>` — the real
//     live bucket layout (CLAUDE.md §28), §0.5 C-a (NOT the spec's
//     illustrative `manifests/seed.json`).
//
// ============================================================================
// WHO CONSUMES THIS FILE
// ============================================================================
//   * lib/main.dart — `AssetUpdater(config: seedCatalogConfig)`.
//   * lib/database/seed_loader.dart — `show seedNeedsReseedPrefix`.
//   * test/asset_updater_allowlist_test.dart.
//
// ============================================================================
// SIDE EFFECTS
// ============================================================================
//   * `seedCatalogConfig.storageRootProvider` creates
//     `<applicationDocumentsDirectory>/seed_data/` if missing
//     (exactly as the former `_ensureSeedDataDir`).
//   * `onAssetApplied` writes `seed_needs_reseed_<key>` to
//     SharedPreferences.

import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'asset_updater_config.dart';

// ---------------------------------------------------------------------------
// Relocated public constants (verbatim values from the deleted
// seed_updater.dart — only the home moves; values are preserved).
// ---------------------------------------------------------------------------

/// SharedPreferences key prefix for per-file seed version tracking
/// (e.g. `seed_version_cartridges`). MUST stay `'seed_version_'` —
/// field-installed apps key off this; drift orphans tracking.
const String seedVersionPrefix = 'seed_version_';

/// SharedPreferences key prefix for the deferred-re-seed flag
/// (e.g. `seed_needs_reseed_cartridges`). Set true on a successful
/// download; `SeedLoader` reads + clears it on the next launch.
const String seedNeedsReseedPrefix = 'seed_needs_reseed_';

/// Logical manifest keys recognised for the seed catalog. Anything
/// outside this set is ignored — the load-bearing security boundary.
/// Every entry lines up with a `seed_loader.dart` reseed branch.
/// `asset_updater_allowlist_test.dart` asserts the bundled
/// manifest's keys are a subset of this. VERBATIM from the former
/// `SeedUpdater.allowedKeys` — no additions/removals in the refactor.
const Set<String> allowedKeys = <String>{
  // Bundled-since-v1 reference tables.
  'cartridges',
  'powders',
  'bullets',
  'primers',
  'brass',
  'firearms',
  'firearm_parts',
  // 'optics' removed in v2.3 (merged into scopes.json).
  // v8 onwards.
  'targets',
  'reticles',
  // v12 — measured drag curves.
  'drag_curves',
  // v14 — factory loads supplement.
  'factory_loads',
  // v19 — target racks reference catalog.
  'target_racks',
  // v22 — verified scope + reticle catalog (v2.3 merged).
  'scopes_v2',
  'scope_reticle_options',
  // v23 — curated manufactured-ammo catalog.
  'manufactured_ammo',
  // v33 — custom-build component catalogs (one file per kind).
  'firearm_components_chassis',
  'firearm_components_barrels',
  'firearm_components_triggers',
  'firearm_components_buttstocks',
  'firearm_components_muzzle_brakes',
  'firearm_components_suppressors',
  'firearm_components_bipods',
  // v41 — recipe templates seeded reference table.
  'recipe_templates',
  // v42 — recipe Status + Use Case seeded reference tables.
  'recipe_statuses',
  'recipe_use_cases',
};

/// Manifest keys whose payload is a flat JSON array (vs the legacy
/// `{manufacturers:[...]}` shape). VERBATIM from the former
/// `SeedUpdater._flatArrayKeys`.
const Set<String> _flatArrayKeys = <String>{
  'cartridges',
  'targets',
  'reticles',
  'drag_curves',
  'factory_loads',
  'target_racks',
  'scopes_v2',
  'reticles_v2',
  'scope_reticle_options',
  'manufactured_ammo',
};

// ---------------------------------------------------------------------------
// seedCatalogConfig — bit-for-bit former SeedUpdater behaviour.
// ---------------------------------------------------------------------------

/// COMPLETE former `_isSafeManifestFilename` (§0.5 C-b — NOT a bare
/// extension check). Allows simple basenames + one subdirectory
/// level; rejects backslashes, leading slash, `..`/`.`, hidden
/// files, deeper nesting, shell metacharacters, non-`.json`.
bool _isSafeSeedFilename(String filename) {
  if (filename.isEmpty) return false;
  if (filename.contains('\\')) return false;
  if (filename.startsWith('/')) return false;
  if (!filename.endsWith('.json')) return false;
  final parts = filename.split('/');
  if (parts.length > 2) return false;
  for (final part in parts) {
    if (part.isEmpty) return false;
    if (part == '.' || part == '..') return false;
    if (part.startsWith('.')) return false;
    if (part.contains(RegExp(r'[\s\x00\$`;<>]'))) return false;
  }
  return true;
}

/// Former `_validateShape`, as a throwing `contentValidator`. Decodes
/// the bytes as UTF-8 JSON and asserts the top-level structure for
/// `entry.key`. Throws [AssetValidationException] on mismatch (the
/// updater then keeps the local copy — never a partial overwrite).
void _validateSeedShape(List<int> bytes, AssetEntry entry) {
  final Object? decoded;
  try {
    decoded = json.decode(utf8.decode(bytes));
  } on FormatException catch (e) {
    throw AssetValidationException('${entry.filename}: bad JSON ($e)');
  }
  if (_flatArrayKeys.contains(entry.key) ||
      entry.key.startsWith('firearm_components_')) {
    if (decoded is! List) {
      throw AssetValidationException(
          '${entry.filename}: expected a top-level JSON array');
    }
    return;
  }
  if (decoded is! Map<String, dynamic> || decoded['manufacturers'] is! List) {
    throw AssetValidationException(
        '${entry.filename}: expected {manufacturers:[...]}');
  }
}

/// Ensures `<applicationDocumentsDirectory>/seed_data/` exists and
/// returns it — exactly the former `_ensureSeedDataDir`. The `key`
/// is ignored: every seed file shares this one directory (the photo
/// config is per-category instead).
Future<Directory> _seedRoot(String key) async {
  final docs = await getApplicationDocumentsDirectory();
  final dir = Directory(p.join(docs.path, 'seed_data'));
  if (!await dir.exists()) {
    await dir.create(recursive: true);
  }
  return dir;
}

/// The seed-catalog live-update configuration. Reproduces the former
/// `SeedUpdater` observable behaviour bit-for-bit (see file header).
final AssetUpdaterConfig seedCatalogConfig = AssetUpdaterConfig(
  allowlist: allowedKeys,
  filenameValidator: _isSafeSeedFilename,
  contentValidator: _validateSeedShape,
  storageRootProvider: _seedRoot,
  storagePathForFile: (filename) => 'seed_data/$filename',
  versionTrackerPrefix: seedVersionPrefix, // 'seed_version_' — verbatim
  manifestStoragePath: 'seed_data/manifest.json', // real live path
  writeStrategy: WriteStrategy.text,
  maxFileBytes: 8 * 1024 * 1024, // former _maxSeedBytes — verbatim
  contentDecoder: utf8.decode,
  // §0.5 C-c — the launch-critical deferred-re-seed trigger the
  // revised spec's config omitted. Former SeedUpdater set this
  // immediately after the version bump (seed_updater.dart:285).
  onAssetApplied: (key, version, prefs) async {
    await prefs.setBool('$seedNeedsReseedPrefix$key', true);
  },
);
