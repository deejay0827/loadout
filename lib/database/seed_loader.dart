// FILE: lib/database/seed_loader.dart
//
// ============================================================================
// WHAT THIS FILE DOES
// ============================================================================
// On launch (called from `main.dart` right after the database opens), this
// class reads the JSON catalog files in `assets/seed_data/` —
// `cartridges.json`, `powders.json`, `bullets.json`, `primers.json`,
// `brass.json`, `firearms.json`, `firearm_parts.json` — and inserts their
// contents into the reference tables defined in `database.dart`. Those
// tables (`Cartridges`, `Powders`, `Bullets`, `Primers`, `BrassProducts`,
// `FirearmsRef`, `FirearmParts`, plus the shared `Manufacturers` lookup)
// are what populate every component dropdown the user sees in the
// recipe form, the firearm form, and the SAAMI lookup screen.
//
// As of the live-catalog-update feature, JSON content can come from one of
// two locations, with the documents directory taking priority:
//
//   1. `<applicationDocumentsDirectory>/seed_data/<filename>` — written by
//      `SeedUpdater` after a successful Firebase Storage download.
//   2. `assets/seed_data/<filename>` — the bundled fallback that ships
//      with every install.
//
// `_readSeedString(filename)` is the single helper that hides this
// preference. Every `_seedX` method calls it instead of `rootBundle`
// directly, so a brand-new install just reads bundled assets, an updated
// install reads the freshly-downloaded copy, and an install that hit a
// network failure falls back to bundled silently.
//
// `seedIfNeeded()` is the single public entry point. It checks two
// classes of conditions:
//
//   - The legacy "the DB is empty / migrated and needs catch-up" flags
//     (`firstRun`, `primersMissing`, `cartridgesNeedReseed`, plus per-table
//     emptiness for the other reference tables).
//   - The "an update was just downloaded; please re-seed" flags written by
//     `SeedUpdater` to SharedPreferences (`seed_needs_reseed_<key>`).
//
// If any of these are true for a given table, the table is re-seeded
// (deleting existing rows and orphan-cleaning the matching `Manufacturers`
// rows where applicable, to avoid unique-constraint collisions). User
// data tables (`UserLoads`, `UserFirearms`, `CustomComponents`, etc.) are
// NEVER touched by this code — only the reference catalog moves.
//
// ============================================================================
// WHY IT EXISTS IN THE ARCHITECTURE
// ============================================================================
// The local-first promise of LoadOut means there is no remote API to call
// for "list all known powder types" — that catalog has to be on-device
// from the moment the app first opens. Bundling the data as JSON in
// `assets/` and seeding it into SQLite gives the user a fully populated,
// offline-capable component picker on the very first launch with no
// network request.
//
// Storing the catalog in SQLite (rather than reading the JSON each time
// a dropdown opens) lets us issue real SQL queries against it later —
// cascading dropdowns, manufacturer filters, alias lookups for the
// SAAMI screen, joining `UserLoads.powder` against `Powders.name`.
// The JSON is the source-of-truth file the team edits; SQLite is the
// query surface the running app uses.
//
// The conditional re-seed logic also enables hot-fixes via Firebase
// Storage. The team can ship a corrected powder name or a new cartridge
// by uploading a new JSON + bumping its version in `manifest.json`.
// `SeedUpdater` downloads it, sets `seed_needs_reseed_<key>`, and the
// next launch's `seedIfNeeded()` swaps the rows in SQLite. No App Store
// or Play Store release required.
//
// ============================================================================
// WHY THIS IS HARDER THAN IT LOOKS
// ============================================================================
// The dispatch logic in `seedIfNeeded` is deliberately union-of-conditions:
// for each reference table we OR together "the table is empty / stale" and
// "an update was just downloaded." If either is true we re-seed that
// table. Mixing the branches the wrong way would either leave the catalog
// stale (broken UI) or duplicate-insert and crash on unique constraints.
// This is why the function reads all flags up front and gates each seed
// step explicitly.
//
// For tables other than `Cartridges` and `Primers` the re-seed path also
// has to clean up `Manufacturers` rows of the matching `kind` — otherwise
// re-running `_seedX()` would try to re-insert manufacturer rows whose
// `(name, kind)` already exist and crash. The cleanup deletes only the
// specific kind, so re-seeding bullets doesn't disturb powder or primer
// manufacturer rows.
//
// The fall-back to `Value.absent()` for fields that may be missing from
// older JSON shapes is critical. `Value.absent()` tells drift "leave
// this column at its default" instead of "set this column to null."
// They're different — using `Value(null)` on a non-nullable column with
// a default would override the default with NULL and crash. Whenever
// you add a new optional field to the seed JSON, gate it behind
// `m.containsKey(...)` and emit `Value.absent()` when absent. This
// keeps older datasets shipping without rebuilding every JSON file.
//
// `_manufacturerId(...)` is shared across the seeds because manufacturers
// can produce more than one component category (Federal makes both
// primers AND brass). The helper looks up by `(name, kind)` — a unique
// composite — and inserts a new row only if no match exists. This is
// why `Manufacturers` has a unique key on `(name, kind)` rather than
// just `name`.
//
// All inserts happen inside `db.transaction(() async { ... })`. If any
// step fails, the transaction rolls back and the database stays in its
// previous state. Without this, a partial seed would leave the app in
// a broken half-populated condition that would never self-heal.
//
// `db.batch((b) => b.insertAll(...))` batches multiple INSERTs into one
// SQL statement on SQLite's side, dramatically reducing the latency of
// seeding thousands of rows. Issuing them one at a time would noticeably
// slow first launch.
//
// ============================================================================
// WHO CONSUMES THIS FILE
// ============================================================================
// - `lib/main.dart` — instantiates `SeedLoader(db)` and calls
//   `seedIfNeeded()` on every launch, before `runApp()`.
// - `lib/services/seed_updater.dart` — the producer side of the
//   `seed_needs_reseed_<key>` flags this file consumes.
// - Indirectly, every UI surface that reads from the seeded reference
//   tables: `lib/screens/loads/load_form_screen.dart` (component
//   dropdowns), `lib/screens/firearms/firearm_form_screen.dart`,
//   `lib/screens/saami/saami_screen.dart`, etc.
//
// ============================================================================
// SIDE EFFECTS
// ============================================================================
// - Reads up to 7 JSON files. Each read prefers
//   `<applicationDocumentsDirectory>/seed_data/<filename>` (when
//   `SeedUpdater` has cached an update) and falls back to
//   `assets/seed_data/<filename>` (bundled).
// - Writes potentially thousands of rows into SQLite (cartridges,
//   manufacturers, powders, bullets, primers, brass products, firearms,
//   firearm parts) inside one transaction.
// - On re-seed paths, deletes existing rows in the targeted reference
//   table (and orphan-cleans matching `Manufacturers` rows by kind)
//   before re-inserting.
// - Clears any `seed_needs_reseed_<key>` SharedPreferences flag once the
//   corresponding re-seed completes.
// - User data tables are NEVER read or written by this file.

import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/recipe_template.dart';
import '../models/target_center_point.dart';
import '../services/asset_updater_configs.dart' show seedNeedsReseedPrefix;
import 'database.dart';
import 'rack_slot.dart';

/// SharedPreferences key prefix matching `AssetUpdater(seedCatalogConfig)`'s
/// `seed_needs_reseed_<key>` flags (VFP Phase 4 Group C — the const
/// relocated from the deleted `seed_updater.dart` with its VALUE
/// preserved verbatim, so this is behaviourally inert).
const _kReseedPrefix = seedNeedsReseedPrefix;

/// Reads bundled / downloaded JSON files in `seed_data/` and populates the
/// reference tables on first run, on table emptiness, or when an update
/// has been downloaded by [SeedUpdater].
class SeedLoader {
  SeedLoader(this.db);
  final AppDatabase db;

  Future<void> seedIfNeeded() async {
    final firstRun = await db.needsSeed;
    final prefs = await SharedPreferences.getInstance();

    bool flag(String key) =>
        prefs.getBool('$_kReseedPrefix$key') == true;

    final cartridgesReseed =
        firstRun || await db.cartridgesNeedReseed || flag('cartridges');
    final powdersReseed =
        firstRun || await db.powdersAreEmpty || flag('powders');
    final bulletsReseed =
        firstRun || await db.bulletsAreEmpty || flag('bullets');
    final primersReseed =
        firstRun || await db.primersAreEmpty || flag('primers');
    final brassReseed =
        firstRun || await db.brassProductsAreEmpty || flag('brass');
    final firearmsReseed =
        firstRun || await db.firearmsRefAreEmpty || flag('firearms');
    final firearmPartsReseed =
        firstRun || await db.firearmPartsAreEmpty || flag('firearm_parts');
    // [v2.3 hotfix 2026-05-12] `optics.json` was deleted in Phase 2 (merged
    // into `scopes.json`), but the corresponding `opticsReseed` /
    // `_seedOptics()` plumbing remained in place. Result: on first launch
    // (cleared cache), `_seedOptics()` tried to load the deleted file and
    // crashed with "Unable to load asset: assets/seed_data/optics.json".
    // The fix removes the entire optics-reseed branch. The legacy `Optics`
    // drift table stays in the schema (cleaning it up requires a v36 drop
    // migration — deferred to v2.4); it just stays empty going forward.
    // `ScopeCatalogService` (`lib/services/scope_catalog_service.dart`)
    // is already defensive against a missing optics.json at its rootBundle
    // load site, so the legacy "Find by My Scope" picker degrades to
    // scope_reticle_options-only entries instead of crashing.
    final targetsReseed =
        firstRun || await db.targetsAreEmpty || flag('targets');
    final reticlesReseed =
        firstRun || await db.reticlesAreEmpty || flag('reticles');
    final dragCurvesReseed =
        firstRun || await db.dragCurvesAreEmpty || flag('drag_curves');
    // Target racks ship as a sibling reference catalog to the
    // single-target [Targets] table. Re-seed when the table is empty
    // (first run / post-migration) or when SeedUpdater flagged a new
    // download via the 'target_racks' pref key.
    final targetRacksReseed =
        firstRun || await db.targetRacksAreEmpty || flag('target_racks');
    // [v2.3 hotfix 2026-05-12] `verifiedScopesReseed` retired alongside
    // `_seedVerifiedScopes()`. The legacy v22 seeder read three files
    // in a shape that Phase 2 flattened:
    //   * `scopes.json` — was `{ "manufacturers": [{ "models": [...] }] }`,
    //     is now `[ { "id": "...", "manufacturer": "...", ... }, ... ]`.
    //     The original `_readJsonObject('scopes.json')` crashed with
    //     "type 'List<dynamic>' is not a subtype of type 'Map<String,
    //     dynamic>' in type cast" on cold start.
    //   * `reticles_v2.json` — DELETED in Phase 2 (merged into
    //     reticles.json). Would have crashed step 2 with the same
    //     missing-asset error as optics.json.
    //   * `scope_reticle_options.json` — was `{ "options": [...] }`,
    //     is now `[ { "scope_id": "...", "reticle_id": "..." }, ... ]`.
    //     Would have crashed step 3 with the same Map-vs-List cast.
    //
    // None of the three legacy drift tables this method populated
    // (`ScopeManufacturers`, `ScopeModels`, `ScopeReticleOptions`) is
    // queried anywhere in production code. `ScopeCatalogService` reads
    // `scopes.json` / `scope_reticle_options.json` directly via
    // rootBundle; the new `scope_catalog_v2.dart` does the same. The
    // drift tables stay empty going forward; cleaning them up requires
    // a v36 schema migration (deferred to v2.4 alongside `Optics`).
    // The `scopes_v2` SeedUpdater allowlist key stays — it tracks the
    // bucket version for `scopes.json`, which IS still used at runtime.
    // Curated manufactured-ammo catalog (added schema v23). Feeds the
    // Range Day "Pick a common factory load" empty-state picker. Lifted
    // out of a hand-coded Dart list so it can be live-updated via
    // SeedUpdater without an App Store push.
    final manufacturedAmmoReseed = firstRun ||
        await db.manufacturedAmmoAreEmpty ||
        flag('manufactured_ammo');
    // Custom-build component catalog (added schema v33). Seven JSON
    // files under `assets/seed_data/components/` covering chassis /
    // barrels / triggers / buttstocks / muzzle brakes / suppressors /
    // bipods. The form's "Custom Build" mode pickers query these.
    final firearmComponentsReseed = firstRun ||
        await db.firearmComponentsAreEmpty ||
        flag('firearm_components');
    // Recipe templates (added schema v41, Phase Two Group 1).
    // Curated starter loads surfaced from Quick Add's template
    // picker. Moved from a static const Dart list to seed JSON so
    // they ride the manifest-versioned live update path.
    final recipeTemplatesReseed = firstRun ||
        await db.recipeTemplatesAreEmpty ||
        flag('recipe_templates');
    // Recipe Status + Use Case dropdowns (added schema v42, Phase
    // Two Group 2). Moved from private const record lists in
    // `recipe_form_screen.dart` so post-launch additions ride the
    // manifest-versioned update path.
    final recipeStatusesReseed = firstRun ||
        await db.recipeStatusesAreEmpty ||
        flag('recipe_statuses');
    final recipeUseCasesReseed = firstRun ||
        await db.recipeUseCasesAreEmpty ||
        flag('recipe_use_cases');

    final any = cartridgesReseed ||
        powdersReseed ||
        bulletsReseed ||
        primersReseed ||
        brassReseed ||
        firearmsReseed ||
        firearmPartsReseed ||
        // opticsReseed retired in the v2.3 hotfix (see above).
        targetsReseed ||
        reticlesReseed ||
        dragCurvesReseed ||
        targetRacksReseed ||
        // verifiedScopesReseed retired in the v2.3 hotfix (see above).
        manufacturedAmmoReseed ||
        firearmComponentsReseed ||
        recipeTemplatesReseed ||
        recipeStatusesReseed ||
        recipeUseCasesReseed;
    if (!any) return;

    await db.transaction(() async {
      // Cartridges: re-seed when first run OR when an existing install is
      // missing the v2 SAAMI/CIP dimension fields OR when SeedUpdater
      // flagged the file. The v2 migration only added the columns;
      // without this re-seed users see "—" for body / shoulder / neck /
      // rim dimensions even though the JSON has them.
      if (cartridgesReseed) {
        if (!firstRun) {
          await db.delete(db.cartridges).go();
        }
        await _seedCartridges();
      }
      // For the other reference tables we re-seed when the table is
      // empty (firstRun, post-migration, or a force-reseed via
      // SeedUpdater). Each branch wipes its own table + matching
      // Manufacturers rows so re-inserts don't collide on unique keys.
      if (powdersReseed) {
        if (!firstRun) {
          await db.delete(db.powders).go();
          await (db.delete(db.manufacturers)
                ..where((m) => m.kind.equals('powder')))
              .go();
        }
        await _seedPowders();
      }
      if (bulletsReseed) {
        if (!firstRun) {
          await db.delete(db.bullets).go();
          await (db.delete(db.manufacturers)
                ..where((m) => m.kind.equals('bullet')))
              .go();
        }
        await _seedBullets();
      }
      if (brassReseed) {
        if (!firstRun) {
          await db.delete(db.brassProducts).go();
          await (db.delete(db.manufacturers)
                ..where((m) => m.kind.equals('brass')))
              .go();
        }
        await _seedBrass();
      }
      if (firearmsReseed) {
        if (!firstRun) {
          await db.delete(db.firearmsRef).go();
          await (db.delete(db.manufacturers)
                ..where((m) => m.kind.equals('firearm')))
              .go();
        }
        await _seedFirearms();
      }
      if (firearmPartsReseed) {
        if (!firstRun) {
          await db.delete(db.firearmParts).go();
          await (db.delete(db.manufacturers)
                ..where((m) => m.kind.equals('parts')))
              .go();
        }
        await _seedFirearmParts();
      }
      // [v2.3 hotfix] Legacy `_seedOptics()` block removed — optics.json
      // no longer exists in the catalog. See the explanatory comment on
      // the `opticsReseed` retirement above. The legacy Optics drift
      // table stays empty; consumers are defensive against that state.
      if (targetsReseed) {
        // Targets do not share `Manufacturers` rows — `Targets.manufacturer`
        // is a free-form text column, so we just clear and re-seed.
        if (!firstRun) {
          await db.delete(db.targets).go();
        }
        // Phase 9.8.B.2 — stale docs-mirror self-heal. If the seed
        // validation throws (typically because the docs-mirror file
        // is from an older schema, e.g. pre-Phase-9.5 had a
        // material-based `category` instead of the v9.5 enum),
        // delete the stale mirror and retry from the bundled asset.
        // The bundled asset is always in sync with the running app
        // code, so the retry is the canonical recovery. SeedUpdater
        // will re-download a fresh mirror from Firebase Storage on
        // a future cold start IF the remote version is strictly
        // greater than the bundled version.
        //
        // The second attempt uses `forceBundled: true` so even if
        // the deletion failed for OS reasons (locked file, etc.),
        // the read still skips the mirror. A second failure rethrows
        // — that means the BUNDLED asset itself is malformed, which
        // IS a genuine crash-on-launch (engineering bug, not stale
        // data).
        try {
          await _seedTargets();
        } catch (_) {
          await _invalidateStaleMirror('targets.json');
          // If the cleared row partial-batch landed before the throw,
          // wipe again so the retry inserts a clean set.
          if (!firstRun) {
            await db.delete(db.targets).go();
          }
          await _seedTargets(forceBundled: true);
        }
      }
      if (reticlesReseed) {
        // Reticles do not share `Manufacturers` rows — `Reticles.manufacturerId`
        // is a free-form text column (matches `Manufacturers.name` for
        // 'optics' kind when one exists, but doesn't have to). Just clear
        // and re-seed.
        if (!firstRun) {
          await db.delete(db.reticles).go();
        }
        await _seedReticles();
      }
      if (dragCurvesReseed) {
        // Drag curves are independent of `Manufacturers` — the table
        // stores manufacturer as free-form text, mirroring how reticles
        // and targets handle their brand labels. Wipe and re-seed.
        if (!firstRun) {
          await db.delete(db.dragCurves).go();
        }
        await _seedDragCurves();
      }
      if (targetRacksReseed) {
        // Target racks are independent of `Manufacturers`. v40
        // (Phase 9.5 Group C) collapsed the FK child table into an
        // inline `slotsJson` column on `TargetRacks`, so the reseed
        // path is now a single-table wipe-and-replace.
        if (!firstRun) {
          await db.delete(db.targetRacks).go();
        }
        await _seedTargetRacks();
      }
      // [v2.3 hotfix] Legacy `_seedVerifiedScopes()` block removed —
      // Phase 2 flattened scopes.json and scope_reticle_options.json
      // (Map → List) and deleted reticles_v2.json. The seeder's
      // three sequential reads against the old shapes all crash; no
      // production code reads the drift tables it populated. See the
      // explanatory comment on the `verifiedScopesReseed` retirement
      // above. The drift tables stay empty (v36 cleanup deferred to
      // v2.4 alongside `Optics`).
      if (manufacturedAmmoReseed) {
        // Curated manufactured-ammo catalog. No shared `Manufacturers`
        // dependency — the table stores manufacturer as free-form text
        // (mirrors how reticles / targets / drag curves carry their
        // brand label). Wipe and re-seed so a new download cleanly
        // replaces the previous catalog.
        if (!firstRun) {
          await db.delete(db.manufacturedAmmo).go();
        }
        await _seedManufacturedAmmo();
      }
      if (firearmComponentsReseed) {
        // Custom-build component catalog. Same free-form-manufacturer
        // pattern as `manufacturedAmmo` — no `Manufacturers` FK, just
        // a string column on each row. Wipe + reinsert so a refreshed
        // JSON cleanly replaces the previous corpus on the next
        // launch.
        if (!firstRun) {
          await db.delete(db.firearmComponents).go();
        }
        await _seedFirearmComponents();
      }
      if (recipeTemplatesReseed) {
        // Recipe templates (Phase Two Group 1, v41). Reference-only
        // catalog; no `Manufacturers` FK, no user data lives on the
        // table. Wipe + reinsert so a refreshed JSON cleanly
        // replaces the previous template set on next launch — same
        // pattern as `manufacturedAmmo` and `firearmComponents`.
        if (!firstRun) {
          await db.delete(db.recipeTemplates).go();
        }
        await _seedRecipeTemplates();
      }
      if (recipeStatusesReseed) {
        // Recipe Status dropdown options (Phase Two Group 2, v42).
        // Reference-only; wipe + reinsert pattern matches the
        // other v41+ reference tables.
        if (!firstRun) {
          await db.delete(db.recipeStatuses).go();
        }
        await _seedRecipeStatuses();
      }
      if (recipeUseCasesReseed) {
        // Recipe Use Case dropdown options (Phase Two Group 2, v42).
        if (!firstRun) {
          await db.delete(db.recipeUseCases).go();
        }
        await _seedRecipeUseCases();
      }
      // Re-seed primers if they're missing — the v3 migration intentionally
      // clears them so the new productLine field gets populated for
      // upgrading users without nuking the rest of the DB. The forced
      // path also re-seeds when SeedUpdater downloaded a new
      // primers.json.
      if (primersReseed) {
        // The v3 migration already wipes primers + primer manufacturers,
        // so the empty case doesn't need cleanup. The force path does.
        final primersEmpty = await db.primersAreEmpty;
        if (!firstRun && !primersEmpty) {
          await db.delete(db.primers).go();
          await (db.delete(db.manufacturers)
                ..where((m) => m.kind.equals('primer')))
              .go();
        }
        await _seedPrimers();
      }
    });

    // Clear any "needs reseed" flags that we just satisfied. Only clear
    // flags whose corresponding table actually got re-seeded above.
    Future<void> clearIf(bool didReseed, String key) async {
      if (didReseed && flag(key)) {
        await prefs.remove('$_kReseedPrefix$key');
      }
    }

    await clearIf(cartridgesReseed, 'cartridges');
    await clearIf(powdersReseed, 'powders');
    await clearIf(bulletsReseed, 'bullets');
    await clearIf(primersReseed, 'primers');
    await clearIf(brassReseed, 'brass');
    await clearIf(firearmsReseed, 'firearms');
    await clearIf(firearmPartsReseed, 'firearm_parts');
    // [v2.3 hotfix] 'optics' reseed flag retired with the optics.json
    // catalog. Future installs no longer carry a `seed_reseed_optics`
    // pref; existing installs with the pref set will just have it sit
    // unread until the next SharedPreferences clear. Harmless.
    await clearIf(targetsReseed, 'targets');
    await clearIf(reticlesReseed, 'reticles');
    await clearIf(dragCurvesReseed, 'drag_curves');
    await clearIf(targetRacksReseed, 'target_racks');
    // [v2.3 hotfix] verifiedScopesReseed retired alongside
    // _seedVerifiedScopes(). The `scopes_v2` SeedUpdater pref key
    // (the user-side reseed flag) stays in the namespace — anything
    // SeedUpdater writes there sits unread until the next clear.
    // Harmless.
    await clearIf(manufacturedAmmoReseed, 'manufactured_ammo');
    await clearIf(firearmComponentsReseed, 'firearm_components');
  }

  Future<int> _manufacturerId(
    String name,
    String? country,
    String kind,
  ) async {
    final existing = await (db.select(db.manufacturers)
          ..where((m) => m.name.equals(name) & m.kind.equals(kind)))
        .getSingleOrNull();
    if (existing != null) return existing.id;
    return db.into(db.manufacturers).insert(
          ManufacturersCompanion.insert(
            name: name,
            kind: kind,
            country: Value(country),
          ),
        );
  }

  /// Reads a seed JSON file as a UTF-8 string, preferring the live-update
  /// copy in `<docs>/seed_data/<filename>` over the bundled asset. Falls
  /// back to the bundled copy whenever the local file is missing or
  /// unreadable so we always have *something* to seed from.
  ///
  /// When [forceBundled] is true (set by [_invalidateStaleMirrorAndRetry]
  /// after a validation failure), the docs-mirror preference is skipped
  /// entirely. Used by the stale-mirror self-heal path: if a `_seedX`
  /// call validates the docs-mirror data and finds it unreadable
  /// (Phase 9.8.B.2 — schema migrations like Phase 9.5 Group A's
  /// category-driven taxonomy can render older docs-mirror files
  /// invalid), the loader deletes the stale mirror and re-runs the
  /// seed step with `forceBundled: true` so the BUNDLED asset (which
  /// is always in sync with the running app code) wins.
  Future<String> _readSeedString(
    String filename, {
    bool forceBundled = false,
  }) async {
    if (!forceBundled) {
      try {
        final docsDir = await getApplicationDocumentsDirectory();
        final localFile =
            File(p.join(docsDir.path, 'seed_data', filename));
        if (await localFile.exists()) {
          return await localFile.readAsString();
        }
      } catch (_) {
        // If the documents directory is somehow unavailable, fall through
        // to the bundled asset rather than crashing on launch.
      }
    }
    return rootBundle.loadString('assets/seed_data/$filename');
  }

  /// Phase 9.8.B.2 — stale docs-mirror self-heal. Deletes the
  /// docs-mirror copy of [filename] (if present) so subsequent reads
  /// fall through to the bundled asset. Called from the
  /// validation-failure recovery path in `_seedX` methods.
  ///
  /// The mirror could be stale for several reasons:
  ///   * App version was upgraded with new bundled seed data, and the
  ///     mirror (last downloaded from Firebase Storage) is from an
  ///     older app version with an older schema. The current canonical
  ///     example: a pre-Phase-9.5 mirror has `shape: "circle"` and a
  ///     material `category: "paper" / "steel" / "target"`; the
  ///     post-Phase-9.5 loader expects `category` to be one of the
  ///     v9.5 enum values.
  ///   * Firebase Storage was rolled back to an older payload.
  ///   * The mirror was hand-edited and corrupted.
  ///
  /// In all cases the bundled asset is the source of truth at app
  /// version N, so deleting the mirror is the correct recovery.
  /// SeedUpdater on next cold start will re-download the mirror from
  /// Firebase IF Firebase has a newer version than the bundled asset
  /// (the existing strictly-greater version check in
  /// `seed_updater.dart` does the right thing).
  Future<void> _invalidateStaleMirror(String filename) async {
    try {
      final docsDir = await getApplicationDocumentsDirectory();
      final localFile =
          File(p.join(docsDir.path, 'seed_data', filename));
      if (await localFile.exists()) {
        await localFile.delete();
      }
    } catch (_) {
      // Best-effort. If we can't delete the mirror, the next read
      // will still try it and fail again — but the operator will
      // at least see the same loud error twice (instead of silently
      // limping along with stale data).
    }
  }

  Future<List<dynamic>> _readJsonList(
    String filename, {
    bool forceBundled = false,
  }) async {
    final raw = await _readSeedString(filename, forceBundled: forceBundled);
    return json.decode(raw) as List<dynamic>;
  }

  Future<Map<String, dynamic>> _readJsonObject(
    String filename, {
    bool forceBundled = false,
  }) async {
    final raw = await _readSeedString(filename, forceBundled: forceBundled);
    return json.decode(raw) as Map<String, dynamic>;
  }

  Future<void> _seedCartridges() async {
    final data = await _readJsonList('cartridges.json');
    final batch = <CartridgesCompanion>[];
    for (final entry in data) {
      final m = entry as Map<String, dynamic>;
      batch.add(CartridgesCompanion.insert(
        name: m['name'] as String,
        type: m['type'] as String,
        bulletDiameterIn: Value((m['bulletDiameterIn'] as num?)?.toDouble()),
        caseLengthIn: Value((m['caseLengthIn'] as num?)?.toDouble()),
        maxCoalIn: Value((m['maxCoalIn'] as num?)?.toDouble()),
        gauge: Value((m['gauge'] as num?)?.toDouble()),
        shellLengthIn: Value((m['shellLengthIn'] as num?)?.toDouble()),
        parentCase: Value(m['parentCase'] as String?),
        yearIntroduced: Value(m['yearIntroduced'] as int?),
        aliasesJson: Value(json.encode(m['aliases'] ?? const [])),
        // Extended SAAMI/CIP fields — fall back to absent if the JSON entry
        // doesn't carry them yet (the seed dataset is being filled in over time).
        bodyDiameterIn: m.containsKey('bodyDiameterIn')
            ? Value((m['bodyDiameterIn'] as num?)?.toDouble())
            : const Value.absent(),
        shoulderDiameterIn: m.containsKey('shoulderDiameterIn')
            ? Value((m['shoulderDiameterIn'] as num?)?.toDouble())
            : const Value.absent(),
        shoulderAngleDeg: m.containsKey('shoulderAngleDeg')
            ? Value((m['shoulderAngleDeg'] as num?)?.toDouble())
            : const Value.absent(),
        neckDiameterIn: m.containsKey('neckDiameterIn')
            ? Value((m['neckDiameterIn'] as num?)?.toDouble())
            : const Value.absent(),
        neckLengthIn: m.containsKey('neckLengthIn')
            ? Value((m['neckLengthIn'] as num?)?.toDouble())
            : const Value.absent(),
        baseToShoulderIn: m.containsKey('baseToShoulderIn')
            ? Value((m['baseToShoulderIn'] as num?)?.toDouble())
            : const Value.absent(),
        baseToNeckIn: m.containsKey('baseToNeckIn')
            ? Value((m['baseToNeckIn'] as num?)?.toDouble())
            : const Value.absent(),
        rimDiameterIn: m.containsKey('rimDiameterIn')
            ? Value((m['rimDiameterIn'] as num?)?.toDouble())
            : const Value.absent(),
        rimThicknessIn: m.containsKey('rimThicknessIn')
            ? Value((m['rimThicknessIn'] as num?)?.toDouble())
            : const Value.absent(),
        primerType: m.containsKey('primerType')
            ? Value(m['primerType'] as String?)
            : const Value.absent(),
        twistRate: m.containsKey('twistRate')
            ? Value(m['twistRate'] as String?)
            : const Value.absent(),
        maxAvgPressurePsi: m.containsKey('maxAvgPressurePsi')
            ? Value((m['maxAvgPressurePsi'] as num?)?.toInt())
            : const Value.absent(),
        boreDiameterIn: m.containsKey('boreDiameterIn')
            ? Value((m['boreDiameterIn'] as num?)?.toDouble())
            : const Value.absent(),
        grooveDiameterIn: m.containsKey('grooveDiameterIn')
            ? Value((m['grooveDiameterIn'] as num?)?.toDouble())
            : const Value.absent(),
        caseSubtype: m.containsKey('caseSubtype')
            ? Value(m['caseSubtype'] as String?)
            : const Value.absent(),
        saamiDoc: m.containsKey('saamiDoc')
            ? Value(m['saamiDoc'] as String?)
            : const Value.absent(),
      ));
    }
    await db.batch((b) => b.insertAll(db.cartridges, batch));
  }

  Future<void> _seedPowders() async {
    final root = await _readJsonObject('powders.json');
    for (final mfg in root['manufacturers'] as List<dynamic>) {
      final m = mfg as Map<String, dynamic>;
      final mid = await _manufacturerId(
        m['name'] as String,
        m['country'] as String?,
        'powder',
      );
      final products = m['products'] as List<dynamic>;
      final batch = products.map((p) {
        final prod = p as Map<String, dynamic>;
        return PowdersCompanion.insert(
          manufacturerId: mid,
          name: prod['name'] as String,
          type: prod['type'] as String,
          form: Value(prod['form'] as String?),
          burnRate: Value(prod['burnRate'] as String?),
          notes: Value(prod['notes'] as String?),
        );
      }).toList();
      await db.batch((b) => b.insertAll(db.powders, batch));
    }
  }

  Future<void> _seedBullets() async {
    final root = await _readJsonObject('bullets.json');
    for (final mfg in root['manufacturers'] as List<dynamic>) {
      final m = mfg as Map<String, dynamic>;
      final mid = await _manufacturerId(
        m['name'] as String,
        m['country'] as String?,
        'bullet',
      );
      final batch = (m['products'] as List<dynamic>).map((p) {
        final prod = p as Map<String, dynamic>;
        return BulletsCompanion.insert(
          manufacturerId: mid,
          line: prod['line'] as String,
          diameterIn: (prod['diameterIn'] as num).toDouble(),
          weightGr: (prod['weightGr'] as num).toDouble(),
          design: Value(prod['design'] as String?),
          jacket: Value(prod['jacket'] as String?),
          application: Value(prod['application'] as String?),
          bcG1: Value((prod['bcG1'] as num?)?.toDouble()),
          bcG7: Value((prod['bcG7'] as num?)?.toDouble()),
          notes: Value(prod['notes'] as String?),
        );
      }).toList();
      await db.batch((b) => b.insertAll(db.bullets, batch));
    }
  }

  Future<void> _seedPrimers() async {
    final root = await _readJsonObject('primers.json');
    for (final mfg in root['manufacturers'] as List<dynamic>) {
      final m = mfg as Map<String, dynamic>;
      final mid = await _manufacturerId(
        m['name'] as String,
        m['country'] as String?,
        'primer',
      );
      final batch = (m['products'] as List<dynamic>).map((p) {
        final prod = p as Map<String, dynamic>;
        return PrimersCompanion.insert(
          manufacturerId: mid,
          name: prod['name'] as String,
          size: prod['size'] as String,
          magnum: Value(prod['magnum'] as bool? ?? false),
          grade: Value(prod['grade'] as String?),
          // productLine added in seed-data schema v3; older versions of the
          // JSON omit it, so fall back to absent in that case.
          productLine: prod.containsKey('productLine')
              ? Value(prod['productLine'] as String?)
              : const Value.absent(),
          notes: Value(prod['notes'] as String?),
        );
      }).toList();
      await db.batch((b) => b.insertAll(db.primers, batch));
    }
  }

  Future<void> _seedBrass() async {
    final root = await _readJsonObject('brass.json');
    for (final mfg in root['manufacturers'] as List<dynamic>) {
      final m = mfg as Map<String, dynamic>;
      final mid = await _manufacturerId(
        m['name'] as String,
        m['country'] as String?,
        'brass',
      );
      await db.into(db.brassProducts).insert(BrassProductsCompanion.insert(
            manufacturerId: mid,
            tier: Value(m['tier'] as String?),
            calibersJson: Value(json.encode(m['calibers'] ?? const [])),
            notes: Value(m['notes'] as String?),
          ));
    }
  }

  Future<void> _seedFirearms() async {
    final root = await _readJsonObject('firearms.json');
    for (final mfg in root['manufacturers'] as List<dynamic>) {
      final m = mfg as Map<String, dynamic>;
      final mid = await _manufacturerId(
        m['name'] as String,
        m['country'] as String?,
        'firearm',
      );
      final batch = (m['products'] as List<dynamic>).map((p) {
        final prod = p as Map<String, dynamic>;
        // Per-caliber spec map (added schema v34). Lets a multi-
        // chambering rifle declare different barrel lengths and twist
        // rates per caliber. The form auto-updates when the user
        // picks a different chambering. Optional — entries that omit
        // it default to '{}' and the form uses the row-level
        // `barrelLengthIn` / `twistRate` fields. See
        // `FirearmsRef.caliberSpecsJson` for the JSON schema.
        final caliberSpecs = prod['caliberSpecs'];
        return FirearmsRefCompanion.insert(
          manufacturerId: mid,
          model: prod['model'] as String,
          type: prod['type'] as String,
          action: Value(prod['action'] as String?),
          calibersJson: Value(json.encode(prod['calibers'] ?? const [])),
          notes: Value(prod['notes'] as String?),
          // Factory-spec fields added in seed-data v2; entries that omit
          // these keys (or set them to null) leave the columns null, so
          // the form falls back to user input as it did before.
          barrelLengthIn: prod.containsKey('barrelLengthIn')
              ? Value((prod['barrelLengthIn'] as num?)?.toDouble())
              : const Value.absent(),
          twistRate: prod.containsKey('twistRate')
              ? Value(prod['twistRate'] as String?)
              : const Value.absent(),
          caliberSpecsJson: caliberSpecs is Map
              ? Value(json.encode(caliberSpecs))
              : const Value.absent(),
        );
      }).toList();
      await db.batch((b) => b.insertAll(db.firearmsRef, batch));
    }
  }

  Future<void> _seedFirearmParts() async {
    final root = await _readJsonObject('firearm_parts.json');
    for (final mfg in root['manufacturers'] as List<dynamic>) {
      final m = mfg as Map<String, dynamic>;
      final mid = await _manufacturerId(
        m['name'] as String,
        m['country'] as String?,
        'parts',
      );
      final batch = (m['products'] as List<dynamic>).map((p) {
        final prod = p as Map<String, dynamic>;
        return FirearmPartsCompanion.insert(
          manufacturerId: mid,
          name: prod['name'] as String,
          category: prod['category'] as String,
          compatibleWithJson:
              Value(json.encode(prod['compatibleWith'] ?? const [])),
          notes: Value(prod['notes'] as String?),
        );
      }).toList();
      await db.batch((b) => b.insertAll(db.firearmParts, batch));
    }
  }

  /// Seed the [FirearmComponents] catalog from the seven JSON files
  /// under `assets/seed_data/components/`. Each file is a flat array
  /// of product objects (`{manufacturer, model, productLine?, notes,
  /// ...category-specific...}`). Canonical columns are extracted; the
  /// rest of each object is JSON-encoded into `attributesJson` for
  /// future surfaces that want to show, e.g. action footprints under
  /// each chassis or pull-range under each trigger.
  ///
  /// Added schema v33 — see CLAUDE.md § 27 (Custom-build firearm
  /// components catalog). The discriminator strings stored here
  /// (`'chassis'` / `'barrel'` / `'trigger'` / `'buttstock'` /
  /// `'muzzleBrake'` / `'suppressor'` / `'bipod'`) are the same ones
  /// the firearm form's autocomplete pickers query for, and the same
  /// ones [FirearmComponentRepository] expects.
  Future<void> _seedFirearmComponents() async {
    const sources = <String, String>{
      'chassis': 'components/chassis.json',
      'barrel': 'components/barrels.json',
      'trigger': 'components/triggers.json',
      'buttstock': 'components/buttstocks.json',
      'muzzleBrake': 'components/muzzle_brakes.json',
      'suppressor': 'components/suppressors.json',
      'bipod': 'components/bipods.json',
    };
    // Canonical column names — every other key in a product object
    // flows into the `attributesJson` blob so per-category fields
    // (actionFootprints, material, pullRangeOz, mounting, etc.)
    // remain accessible to the UI without bloating the table schema
    // with seven category-specific column sets.
    const canonicalKeys = {'manufacturer', 'model', 'productLine', 'notes'};
    for (final entry in sources.entries) {
      final kind = entry.key;
      final filename = entry.value;
      final raw = await _readSeedString(filename);
      final data = json.decode(raw) as List<dynamic>;
      final batch = data.map((p) {
        final prod = p as Map<String, dynamic>;
        final attributes = <String, dynamic>{
          for (final e in prod.entries)
            if (!canonicalKeys.contains(e.key)) e.key: e.value,
        };
        return FirearmComponentsCompanion.insert(
          kind: kind,
          manufacturer: prod['manufacturer'] as String,
          model: prod['model'] as String,
          productLine: Value(prod['productLine'] as String?),
          notes: Value(prod['notes'] as String?),
          attributesJson: Value(json.encode(attributes)),
        );
      }).toList();
      await db.batch((b) => b.insertAll(db.firearmComponents, batch));
    }
  }

  // [v2.3 hotfix 2026-05-12] `_seedOptics()` removed. The optics.json
  // catalog was merged into scopes.json during Phase 2; this method
  // was orphaned and crashed on first launch trying to load the
  // deleted file. Cleanup of the legacy `Optics` drift table itself
  // is deferred to v2.4 (requires a v36 schema migration to drop the
  // table cleanly). Consumers (ScopeCatalogService /
  // FindByScopeSheet) are defensive against an empty Optics table.

  /// Seed the [Targets] reference catalog from `assets/seed_data/targets.json`.
  /// The JSON shape is a flat array of objects (no per-manufacturer
  /// nesting like powders / bullets / firearms) because target
  /// "manufacturers" are free-form labels — multiple unrelated companies
  /// make the same shape of target, and many targets are generic with no
  /// real maker.
  ///
  /// Migration note (v18 → material-agnostic dedup): the catalog used
  /// to ship "AR500 Plate N in" / "AR550 Plate N in" pairs that
  /// differed only by the `materialKind` discriminator. Hit probability
  /// only depends on size and shape, so the steel grades were collapsed
  /// to a single `'steel'` material with one "Steel Plate N in" per
  /// size. We chose option (a) from the design notes — a one-shot
  /// re-seed via the v18 `onUpgrade` clause that wipes the [Targets]
  /// table — because targets is a pure reference table (users cannot
  /// add custom targets via the UI today), so deleting and re-inserting
  /// is the simplest path. The picker's stale-id guard handles any
  /// `RangeDaySessions.targetId` that pointed at an AR500/AR550 row.
  Future<void> _seedTargets({bool forceBundled = false}) async {
    final data = await _readJsonList('targets.json',
        forceBundled: forceBundled);
    final batch = <TargetsCompanion>[];
    for (final entry in data) {
      final m = entry as Map<String, dynamic>;
      // [v2.3 hotfix 2026-05-12] `targets.json` ships mixed-case field
      // names: the 49 conventional rows authored pre-v2.3 use
      // camelCase (`widthIn` / `heightIn` / `colorHex`); the 16 animal
      // rows added in Phase 2 use snake_case (`width_in` / `height_in`
      // / `color_hex`). The pre-hotfix loader read camelCase only,
      // which crashed on cold start with
      //   "type 'Null' is not a subtype of type 'num' in type cast"
      // the first time the seeder hit an animal row.
      //
      // Defensive read: prefer snake_case (the v2.3 catalog convention
      // — see the rack-mount-style rewire at `_seedTargetRacks` for
      // the same pattern) and fall back to camelCase for the legacy
      // rows. Future targets.json catalog edits should write
      // snake_case; the data-normalisation sweep (rewriting the 49
      // legacy rows to snake_case) is deferred to v2.4.
      final widthIn = (m['width_in'] ?? m['widthIn']) as num;
      final heightIn = (m['height_in'] ?? m['heightIn']) as num;
      final colorHex =
          (m['color_hex'] as String?) ?? (m['colorHex'] as String?);
      // v2.3 / v36 — `shape_id` is the SVG dispatch key. Non-null for
      // the 16 animal rows (matching `AnimalSilhouettes` keys) and the
      // popper / IPSC rows; null for procedural shapes (circles,
      // rectangles, Texas Star).
      final shapeId = m['shape_id'] as String?;
      // v37 — `center_point` is the per-target geometric anchor for
      // pole positioning (and future visual anchors). Null block →
      // default 0.5/0.5 (= rect center, same as the Phase 5 anchor).
      final centerPoint = TargetCenterPoint.fromJson(
        m['center_point'] as Map<String, dynamic>?,
      );
      // v38 — `svg_scale_factor` is a multiplier on the natural
      // fit-to-box scale applied by the silhouette helpers. Default
      // 1.0; problem animals (antlers / horns / tall tails) author
      // 1.2-1.4 so their authored SVG overflows the rect into the
      // sky region.
      final svgScaleFactor =
          (m['svg_scale_factor'] as num?)?.toDouble() ?? 1.0;
      // Phase 9.5 — `category` enum drives the painter dispatch.
      // Validate at load time so any catalog typo raises loud
      // (a stray "circles" / "ipsk" / "Special" stops the seed
      // before it pollutes the table).
      const validCategories = <String>{
        'circle',
        'square',
        'rectangle',
        'ipsc',
        'animal',
        'special',
      };
      final category = m['category'] as String;
      if (!validCategories.contains(category)) {
        throw StateError(
          "targets.json row '${m['name']}': invalid category "
          "'$category' (must be one of $validCategories).",
        );
      }
      batch.add(TargetsCompanion.insert(
        name: m['name'] as String,
        category: category,
        shapeId: Value(shapeId),
        widthIn: widthIn.toDouble(),
        heightIn: heightIn.toDouble(),
        // Default to white when missing from the JSON. The slimmed
        // v28 catalog ships every entry as `#ffffff` per user
        // feedback ("all targets should have white as the default
        // color"); the `??` fallback keeps the loader resilient if
        // a future entry omits the field.
        colorHex: colorHex ?? '#ffffff',
        notes: Value(m['notes'] as String?),
        verticalCenterPctFromTop: Value(centerPoint.verticalFromTop),
        horizontalCenterPctFromLeft:
            Value(centerPoint.horizontalFromLeft),
        svgScaleFactor: Value(svgScaleFactor),
      ));
    }
    await db.batch((b) => b.insertAll(db.targets, batch));
  }

  /// Seed the [TargetRacks] reference catalog from
  /// `assets/seed_data/target_racks.json`. The JSON shape is an object
  /// with a top-level `racks` array; each rack carries a `children`
  /// array describing the in-rack layout.
  ///
  /// v40 (Phase 9.5 Group C) — the child layout is stored INLINE on
  /// each rack as a JSON array on the `slotsJson` column (TypeConverter
  /// `RackSlotsConverter`). The previous parent + FK-children
  /// arrangement was dropped because the slot list is always read as
  /// a whole, never individually. Per-rack inserts are slow but the
  /// seed dataset is tiny (~9 racks) so the extra round-trips don't
  /// matter.
  Future<void> _seedTargetRacks() async {
    final root = await _readJsonObject('target_racks.json');
    final racks = (root['racks'] as List<dynamic>? ?? const <dynamic>[]);
    if (racks.isEmpty) return;

    // Phase 9.5 (v40) — closed enum for rack-slot `category`. Mirrors
    // the same set used by single targets in `_seedTargets`. The seed
    // loader fails loudly on unknown categories so a hand-edited
    // target_racks.json can't ship a misspelled value to users.
    const validCategories = <String>{
      'circle',
      'square',
      'rectangle',
      'ipsc',
      'animal',
      'special',
    };

    for (final entry in racks) {
      final m = entry as Map<String, dynamic>;
      // Phase 9.6 Group D — `mount_structure` is the spec-canonical
      // field name for the mount taxonomy
      // (`hanging_rail | standing_stake | popper_base |
      // silhouette_stand`). Falls back to the Phase 2.3 `mount_style`
      // alias, then the legacy `rack_kind` field. The drift column
      // name stays `rackKind` regardless of which JSON key supplied
      // the value — they all carry the same semantic.
      final mountStyle = (m['mount_structure'] as String?) ??
          (m['mount_style'] as String?) ??
          (m['rack_kind'] as String);

      // Phase 9.5 — build the slot list from the JSON `children`
      // array (the field name stays `children` in JSON for backwards
      // compatibility with hand-authored seeds; the Dart-side type
      // is `List<RackSlot>` now). Empty `children` → empty slot list
      // → the rack still inserts (the painter handles the degenerate
      // case as "no shootables, render only the rack furniture").
      final children =
          (m['children'] as List<dynamic>? ?? const <dynamic>[]);
      final slots = <RackSlot>[];
      for (final c in children) {
        final cm = c as Map<String, dynamic>;
        // Prefer the v2.3 §6A.3 `x_offset_in` / `y_offset_in` field
        // names. Legacy `offset_x_in` / `offset_y_in` retained as
        // fallback so the seed_loader works against the dual-field
        // JSON rows the Phase 2.8 agent produced.
        final xOffset =
            (cm['x_offset_in'] as num?) ?? (cm['offset_x_in'] as num);
        final yOffset =
            (cm['y_offset_in'] as num?) ?? (cm['offset_y_in'] as num);
        // v40 — Phase 9.5: the per-slot category enum. Prefer the
        // new `category` field; fall back to the legacy `shape`
        // string with a small remap (`silhouette` → `ipsc`,
        // `popper` / `star` → `special`) so seed files mid-migration
        // still load. The remap is deliberate: it matches the
        // `_targetsShapeToCategory` mapping in `_seedTargets`.
        final rawCategory =
            (cm['category'] as String?) ?? (cm['shape'] as String);
        final category = switch (rawCategory) {
          'silhouette' => 'ipsc',
          'popper' => 'special',
          'star' => 'special',
          final s => s,
        };
        if (!validCategories.contains(category)) {
          throw StateError(
              "target_racks.json rack '${m['name']}' slot "
              "'${cm['name']}': invalid category '$category'. "
              'Allowed: $validCategories.');
        }
        slots.add(RackSlot(
          position: cm['position'] as int,
          shapeId: cm['shape_id'] as String?,
          name: cm['name'] as String,
          category: category,
          widthIn: (cm['width_in'] as num).toDouble(),
          heightIn: (cm['height_in'] as num).toDouble(),
          offsetXIn: xOffset.toDouble(),
          offsetYIn: yOffset.toDouble(),
          sizeRank: cm['size_rank'] as int? ?? 1,
          colorHex: cm['color_hex'] as String? ?? '#ffffff',
        ));
      }
      // Author-time order may have skipped or duplicated positions;
      // the converter sorts defensively on read, but we sort here
      // too so the stored JSON is canonical.
      slots.sort((a, b) => a.position.compareTo(b.position));

      await db.into(db.targetRacks).insert(
            TargetRacksCompanion.insert(
              name: m['name'] as String,
              description: Value(m['description'] as String?),
              rackKind: mountStyle,
              totalWidthIn: (m['total_width_in'] as num).toDouble(),
              totalHeightIn: (m['total_height_in'] as num).toDouble(),
              notes: Value(m['notes'] as String?),
              slotsJson: slots,
            ),
          );
    }
  }

  /// Seed the [RecipeTemplates] reference catalog from
  /// `assets/seed_data/recipe_templates.json` (Phase Two Group 1,
  /// v41). The JSON shape is `{ "version": N, "templates": [...] }`;
  /// each entry parses via `RecipeTemplate.fromJson`, which throws
  /// on an unknown `recommendedDetailLevel` enum value — we surface
  /// the throw rather than silently degrading so a typo in the
  /// seed file is loud at startup, not silent in production.
  ///
  /// `useCase` lives on the model but not on the drift row; it
  /// pre-fills the recipe's Use Case field at apply time, not
  /// stored on the template itself. (Workflow templates link
  /// recipe→use_case independently.)
  Future<void> _seedRecipeTemplates() async {
    final root = await _readJsonObject('recipe_templates.json');
    final entries =
        (root['templates'] as List<dynamic>? ?? const <dynamic>[]);
    for (final entry in entries) {
      final t =
          RecipeTemplate.fromJson(entry as Map<String, dynamic>);
      await db.into(db.recipeTemplates).insert(
            RecipeTemplatesCompanion.insert(
              id: t.id,
              name: t.name,
              description: Value(t.description),
              recommendedDetailLevel: t.recommendedDetailLevel.name,
              caliber: Value(t.caliber),
              powder: Value(t.powder),
              powderChargeGr: Value(t.powderChargeGr),
              bullet: Value(t.bullet),
              bulletWeightGr: Value(t.bulletWeightGr),
              coalIn: Value(t.coalIn),
              cbtoIn: Value(t.cbtoIn),
              useCase: Value(t.useCase),
              notes: Value(t.notes),
            ),
          );
    }
  }

  /// Seed the [RecipeStatuses] reference catalog from
  /// `assets/seed_data/recipe_statuses.json` (Phase Two Group 2,
  /// v42). The JSON shape is `{ "version": N, "statuses": [
  /// { "value": "...", "label": "..." }, ... ] }`. Each row's
  /// `value` doubles as the primary key (it's the enum-style
  /// string persisted on `UserLoads.status`).
  Future<void> _seedRecipeStatuses() async {
    final root = await _readJsonObject('recipe_statuses.json');
    final entries =
        (root['statuses'] as List<dynamic>? ?? const <dynamic>[]);
    for (final entry in entries) {
      final m = entry as Map<String, dynamic>;
      await db.into(db.recipeStatuses).insert(
            RecipeStatusesCompanion.insert(
              value: m['value'] as String,
              label: m['label'] as String,
            ),
          );
    }
  }

  /// Seed the [RecipeUseCases] reference catalog from
  /// `assets/seed_data/recipe_use_cases.json` (Phase Two Group 2,
  /// v42). Same shape as `_seedRecipeStatuses`; different file +
  /// JSON list key.
  Future<void> _seedRecipeUseCases() async {
    final root = await _readJsonObject('recipe_use_cases.json');
    final entries =
        (root['useCases'] as List<dynamic>? ?? const <dynamic>[]);
    for (final entry in entries) {
      final m = entry as Map<String, dynamic>;
      await db.into(db.recipeUseCases).insert(
            RecipeUseCasesCompanion.insert(
              value: m['value'] as String,
              label: m['label'] as String,
            ),
          );
    }
  }

  /// Seed the [Reticles] reference catalog from
  /// `assets/seed_data/reticles.json`. The JSON shape is a flat array;
  /// each entry already carries an `elements` list whose JSON
  /// representation matches `ReticleElement.toJson()`. We re-encode it
  /// here so the column stores compact JSON regardless of the source
  /// formatting.
  ///
  /// Verified-data fields (`verified`, `sourceUrl`, `verifiedAt`,
  /// `designer`, `license`) are honored when present in the JSON. The
  /// audit-cleanup pass that introduced these fields explicitly stamped
  /// every brand-labeled-but-generic-art row with `verified: false`,
  /// so reading the field from the JSON is a defense-in-depth check on
  /// top of the schema column default. Entries without the field
  /// (legacy / future additions that forget to set it) inherit the
  /// schema default of `false` -- the safe fallback.
  Future<void> _seedReticles() async {
    final data = await _readJsonList('reticles.json');
    final batch = <ReticlesCompanion>[];
    for (final entry in data) {
      final m = entry as Map<String, dynamic>;
      // Pull verified-data fields if present; otherwise fall through to
      // `Value.absent()` so the schema's column defaults apply.
      // The explicit type parameter on `Value.absent<T>()` is required —
      // without it Dart infers `Value<dynamic>` from the conditional and
      // the drift companion's strongly-typed setters reject the
      // assignment at compile time.
      final verifiedValue = m.containsKey('verified')
          ? Value(m['verified'] as bool)
          : const Value<bool>.absent();
      final sourceUrlValue = m.containsKey('sourceUrl')
          ? Value(m['sourceUrl'] as String?)
          : const Value<String?>.absent();
      final verifiedAtStr = m['verifiedAt'] as String?;
      final verifiedAtValue = verifiedAtStr != null
          ? Value(DateTime.tryParse(verifiedAtStr))
          : const Value<DateTime?>.absent();
      final designerValue = m.containsKey('designer')
          ? Value(m['designer'] as String?)
          : const Value<String?>.absent();
      final licenseValue = m.containsKey('license')
          ? Value(m['license'] as String?)
          : const Value<String?>.absent();
      // [v2.3 hotfix 2026-05-12] `subtensionOrigin` + `calibrationProvenance`
      // populate from the v2.3 JSON fields. Phase 6 §C's per-origin
      // disclaimer template reads these via the picker's drift query;
      // pre-hotfix, `_seedReticles` didn't pass them through, so the
      // drift column was NULL on every seeded row and the disclaimer
      // silently fell back to the legacy "LoadOut Original —
      // Interoperability Calibration" string instead of per-origin
      // text. Production-shipping installs would never have seen the
      // three-template disclaimer feature until this fix lands. The
      // `?? 'original'` matches the drift column default for rows
      // missing the field; the `calibration_provenance` JSON object is
      // re-encoded into a string blob to match the column's nullable-
      // text type.
      final subtensionOriginValue = Value(
        (m['subtension_origin'] as String?) ?? 'original',
      );
      final calibrationProvenanceValue = Value(
        m['calibration_provenance'] != null
            ? json.encode(m['calibration_provenance'])
            : null,
      );
      batch.add(ReticlesCompanion.insert(
        manufacturerId: m['manufacturer'] as String,
        model: m['model'] as String,
        family: Value(m['family'] as String?),
        type: m['type'] as String,
        nativeUnit: m['nativeUnit'] as String,
        maxExtentUnits: (m['maxExtentUnits'] as num).toDouble(),
        definitionJson: json.encode(m['elements']),
        notes: Value(m['notes'] as String?),
        verified: verifiedValue,
        sourceUrl: sourceUrlValue,
        verifiedAt: verifiedAtValue,
        designer: designerValue,
        license: licenseValue,
        subtensionOrigin: subtensionOriginValue,
        calibrationProvenance: calibrationProvenanceValue,
      ));
    }
    await db.batch((b) => b.insertAll(db.reticles, batch));
  }

  /// Seed the [DragCurves] reference catalog from
  /// `assets/seed_data/drag_curves/curves.json`. The JSON shape is an
  /// object with a top-level `curves` array; each curve has:
  ///   - `name`, `manufacturer`, `line`
  ///   - `weight_gr`, `diameter_in`
  ///   - `datapoints`: array of `{mach, cd}` (sorted ascending by mach)
  ///   - `source`, `notes` (optional)
  ///
  /// The leading `_template.json` placeholder file is ignored — only
  /// the `curves.json` entry from the manifest is read. We expect the
  /// `curves` array to be populated over time with verified
  /// manufacturer-published Doppler-radar drag tables (Berger CDM,
  /// Hornady DSF / 4DOF). An empty array is a perfectly valid state
  /// — the calculator simply won't show any pre-built custom curves
  /// in the dropdown until entries are added.
  Future<void> _seedDragCurves() async {
    final root = await _readJsonObject('drag_curves/curves.json');
    final list = (root['curves'] as List<dynamic>? ?? const <dynamic>[]);
    if (list.isEmpty) return;

    // Dedupe by the table's UNIQUE-constraint signature
    // (manufacturer, line, weight_gr, diameter_in) BEFORE the insert
    // batch. The Hornady 4DOF scrape is the authoritative source today
    // and contains 9 signature collisions (most notably 20 entries
    // labeled "Custom/Custom/106.0/0.243" — different test bullets
    // submitted by different users in Hornady's DB but indistinguishable
    // at our column granularity). Without dedupe, the batch insert
    // fails partway through with SqliteException(2067) "UNIQUE
    // constraint failed", crashing the app at first launch. We keep
    // the first occurrence per signature; the agent that re-runs the
    // scrape can refine the JSON later if needed.
    final seen = <(String, String, double, double)>{};
    final batch = <DragCurvesCompanion>[];
    for (final entry in list) {
      final m = entry as Map<String, dynamic>;
      final datapoints = (m['datapoints'] as List<dynamic>);
      // Validate every point is finite + positive Cd before persisting,
      // mirroring the runtime guard in `CustomDragCurve.fromPoints`.
      for (final dp in datapoints) {
        final dpMap = dp as Map<String, dynamic>;
        final mach = (dpMap['mach'] as num).toDouble();
        final cd = (dpMap['cd'] as num).toDouble();
        if (!mach.isFinite || mach < 0 || !cd.isFinite || cd <= 0) {
          throw StateError(
            'Drag curve "${m['name']}" has invalid datapoint '
            '(mach=$mach, cd=$cd)',
          );
        }
      }
      final manufacturer = m['manufacturer'] as String;
      final line = m['line'] as String;
      final weightGr = (m['weight_gr'] as num).toDouble();
      final diameterIn = (m['diameter_in'] as num).toDouble();
      final sig = (manufacturer, line, weightGr, diameterIn);
      if (!seen.add(sig)) continue; // skip duplicate signature
      batch.add(DragCurvesCompanion.insert(
        manufacturer: manufacturer,
        line: line,
        weightGr: weightGr,
        diameterIn: diameterIn,
        datapointsJson: json.encode(datapoints),
        source: Value(m['source'] as String?),
        notes: Value(m['notes'] as String?),
      ));
    }
    // Belt-and-suspenders: also use insertOrIgnore so a future
    // double-seed (re-run via SeedUpdater after a remote update) is a
    // no-op rather than a crash. The first run's rows already exist;
    // SQLite simply skips any insert that violates the UNIQUE.
    await db.batch(
      (b) => b.insertAll(db.dragCurves, batch, mode: InsertMode.insertOrIgnore),
    );
  }

  // [v2.3 hotfix 2026-05-12] `_seedVerifiedScopes()` removed.
  //
  // The legacy v22-era seeder read three files in shapes that Phase 2
  // restructured:
  //
  //   * `scopes.json` was `{ "manufacturers": [...] }` — Phase 2
  //     flattened to a top-level array of scope rows. The original
  //     `_readJsonObject('scopes.json')` crashed cold-start with
  //     "type 'List<dynamic>' is not a subtype of type
  //     'Map<String, dynamic>' in type cast".
  //   * `reticles_v2.json` was deleted in Phase 2 (merged into
  //     reticles.json). Even with the scopes.json fix, step 2 would
  //     have crashed with the same missing-asset error as the
  //     retired `_seedOptics()`.
  //   * `scope_reticle_options.json` was `{ "options": [...] }` —
  //     Phase 2 flattened the same way as scopes.json. Step 3 would
  //     have crashed with the same Map-vs-List cast.
  //
  // The drift tables this method populated (`ScopeManufacturers`,
  // `ScopeModels`, `ScopeReticleOptions`) are NOT queried anywhere in
  // production code. `ScopeCatalogService` reads `scopes.json` and
  // `scope_reticle_options.json` directly via rootBundle; the v2.3
  // `scope_catalog_v2` service does the same. Cleaning up the orphan
  // drift tables is deferred to v2.4 (requires a v36 schema migration
  // to drop them cleanly alongside `Optics`).

  /// Seed the [ManufacturedAmmo] curated catalog (schema v23) from
  /// `assets/seed_data/manufactured_ammo.json`. The JSON shape is a
  /// flat array of objects:
  ///
  ///   * `manufacturer`, `cartridge`, `name` — required strings.
  ///   * `bulletWeightGr`, `bulletDiameterIn`, `muzzleVelocityFps`
  ///     — required numbers.
  ///   * `bcG7`, `bcG1`, `standardDeviationFps`, `notes`,
  ///     `sourceUrl`, `verifiedAt` — optional / nullable.
  ///
  /// Defensive parsing: skip rows that don't carry the required
  /// fields rather than crashing the whole seed pass. The picker UI
  /// tolerates an empty catalog (renders "no common loads available")
  /// so a partial seed degrades gracefully.
  Future<void> _seedManufacturedAmmo() async {
    final data = await _readJsonList('manufactured_ammo.json');
    final batch = <ManufacturedAmmoCompanion>[];
    for (final entry in data) {
      final m = entry as Map<String, dynamic>;
      final manufacturer = m['manufacturer'] as String?;
      final cartridge = m['cartridge'] as String?;
      final name = m['name'] as String?;
      final bulletWeightGr = (m['bulletWeightGr'] as num?)?.toDouble();
      final bulletDiameterIn = (m['bulletDiameterIn'] as num?)?.toDouble();
      final muzzleVelocityFps = (m['muzzleVelocityFps'] as num?)?.toDouble();
      if (manufacturer == null ||
          cartridge == null ||
          name == null ||
          bulletWeightGr == null ||
          bulletDiameterIn == null ||
          muzzleVelocityFps == null) {
        // ignore: avoid_print
        print(
          'seed_loader: skipping manufactured_ammo row "$manufacturer / '
          '$name": missing required field '
          '(manufacturer/cartridge/name/bulletWeightGr/bulletDiameterIn/muzzleVelocityFps)',
        );
        continue;
      }
      final verifiedAtStr = m['verifiedAt'] as String?;
      final verifiedAt = verifiedAtStr != null
          ? DateTime.tryParse(verifiedAtStr)
          : null;
      batch.add(ManufacturedAmmoCompanion.insert(
        manufacturer: manufacturer,
        cartridge: cartridge,
        name: name,
        bulletWeightGr: bulletWeightGr,
        bulletDiameterIn: bulletDiameterIn,
        muzzleVelocityFps: muzzleVelocityFps,
        standardDeviationFps:
            Value((m['standardDeviationFps'] as num?)?.toDouble()),
        bcG7: Value((m['bcG7'] as num?)?.toDouble()),
        bcG1: Value((m['bcG1'] as num?)?.toDouble()),
        notes: Value(m['notes'] as String?),
        sourceUrl: Value(m['sourceUrl'] as String?),
        verifiedAt: Value(verifiedAt),
      ));
    }
    if (batch.isNotEmpty) {
      await db.batch((b) => b.insertAll(db.manufacturedAmmo, batch));
    }
  }
}
