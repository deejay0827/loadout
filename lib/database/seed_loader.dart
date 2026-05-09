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

import '../services/seed_updater.dart' show seedNeedsReseedPrefix;
import 'database.dart';

/// SharedPreferences key prefix matching `SeedUpdater`'s
/// `seed_needs_reseed_<key>` flags.
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
    final opticsReseed =
        firstRun || await db.opticsAreEmpty || flag('optics');
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
    // Verified scope catalog (added schema v22). Three coordinated
    // tables that must seed together (scopes -> reticles_v2 ->
    // scope_reticle_options) so the join always resolves. We treat
    // them as one reseed unit gated by the [ScopeManufacturers]
    // emptiness check.
    final verifiedScopesReseed = firstRun ||
        await db.scopeManufacturersAreEmpty ||
        flag('scopes_v2');

    final any = cartridgesReseed ||
        powdersReseed ||
        bulletsReseed ||
        primersReseed ||
        brassReseed ||
        firearmsReseed ||
        firearmPartsReseed ||
        opticsReseed ||
        targetsReseed ||
        reticlesReseed ||
        dragCurvesReseed ||
        targetRacksReseed ||
        verifiedScopesReseed;
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
      if (opticsReseed) {
        if (!firstRun) {
          await db.delete(db.optics).go();
          await (db.delete(db.manufacturers)
                ..where((m) => m.kind.equals('optics')))
              .go();
        }
        await _seedOptics();
      }
      if (targetsReseed) {
        // Targets do not share `Manufacturers` rows — `Targets.manufacturer`
        // is a free-form text column, so we just clear and re-seed.
        if (!firstRun) {
          await db.delete(db.targets).go();
        }
        await _seedTargets();
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
        // Target racks are independent of `Manufacturers`. Children
        // are FK-linked to their parent rack, so wipe children FIRST
        // to satisfy the FK constraint, then wipe parents, then
        // re-seed.
        if (!firstRun) {
          await db.delete(db.targetRackChildren).go();
          await db.delete(db.targetRacks).go();
        }
        await _seedTargetRacks();
      }
      if (verifiedScopesReseed) {
        // Verified scope catalog (schema v22). The three tables form
        // a strict parent -> child chain via FK columns:
        //   ScopeManufacturers <- ScopeModels <- ScopeReticleOptions
        //                                  ^         |
        //                                  |         v
        //                                  +----- Reticles
        //
        // Wipe children first to satisfy the FK constraint, then
        // wipe parents, then re-seed top-down. We DO NOT touch the
        // shared `Manufacturers` table here -- the verified scope
        // catalog uses its own dedicated `ScopeManufacturers`
        // namespace so there is no orphan-cleanup needed.
        //
        // Reticles re-seeded here are the v22 verified additions
        // ONLY -- the legacy `reticles.json` rows seeded by
        // _seedReticles() above stay untouched. We identify the
        // verified rows by their `verified = true` flag plus a
        // `sourceUrl` so the wipe never accidentally drops a legacy
        // row.
        if (!firstRun) {
          await db.delete(db.scopeReticleOptions).go();
          await db.delete(db.scopeModels).go();
          await db.delete(db.scopeManufacturers).go();
          // Drop only the v2 verified reticle rows so we can re-seed
          // them with any updates. Legacy `reticles.json` rows are
          // preserved (they have `verified = false` and `sourceUrl`
          // null after the v22 migration).
          await (db.delete(db.reticles)
                ..where((r) => r.sourceUrl.isNotNull()))
              .go();
        }
        await _seedVerifiedScopes();
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
    await clearIf(opticsReseed, 'optics');
    await clearIf(targetsReseed, 'targets');
    await clearIf(reticlesReseed, 'reticles');
    await clearIf(dragCurvesReseed, 'drag_curves');
    await clearIf(targetRacksReseed, 'target_racks');
    await clearIf(verifiedScopesReseed, 'scopes_v2');
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
  Future<String> _readSeedString(String filename) async {
    try {
      final docsDir = await getApplicationDocumentsDirectory();
      final localFile = File(p.join(docsDir.path, 'seed_data', filename));
      if (await localFile.exists()) {
        return await localFile.readAsString();
      }
    } catch (_) {
      // If the documents directory is somehow unavailable, fall through
      // to the bundled asset rather than crashing on launch.
    }
    return rootBundle.loadString('assets/seed_data/$filename');
  }

  Future<List<dynamic>> _readJsonList(String filename) async {
    final raw = await _readSeedString(filename);
    return json.decode(raw) as List<dynamic>;
  }

  Future<Map<String, dynamic>> _readJsonObject(String filename) async {
    final raw = await _readSeedString(filename);
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

  Future<void> _seedOptics() async {
    final root = await _readJsonObject('optics.json');
    for (final mfg in root['manufacturers'] as List<dynamic>) {
      final m = mfg as Map<String, dynamic>;
      final mid = await _manufacturerId(
        m['name'] as String,
        m['country'] as String?,
        'optics',
      );
      final batch = (m['products'] as List<dynamic>).map((p) {
        final prod = p as Map<String, dynamic>;
        return OpticsCompanion.insert(
          manufacturerId: mid,
          model: prod['model'] as String,
          category: prod['category'] as String,
          magnification: prod['magnification'] as String,
          objectiveMm: (prod['objectiveMm'] as num).toInt(),
          tubeMm: (prod['tubeMm'] as num).toInt(),
          focalPlane: prod['focalPlane'] as String,
          reticle: prod['reticle'] as String,
          adjustmentUnit: prod['adjustmentUnit'] as String,
          parallaxMinYd: prod.containsKey('parallaxMin')
              ? Value((prod['parallaxMin'] as num?)?.toInt())
              : const Value.absent(),
          weightOz: prod.containsKey('weightOz')
              ? Value((prod['weightOz'] as num?)?.toDouble())
              : const Value.absent(),
          notes: Value(prod['notes'] as String?),
        );
      }).toList();
      await db.batch((b) => b.insertAll(db.optics, batch));
    }
  }

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
  Future<void> _seedTargets() async {
    final data = await _readJsonList('targets.json');
    final batch = <TargetsCompanion>[];
    for (final entry in data) {
      final m = entry as Map<String, dynamic>;
      batch.add(TargetsCompanion.insert(
        name: m['name'] as String,
        manufacturer: Value(m['manufacturer'] as String?),
        category: m['category'] as String,
        shape: m['shape'] as String,
        widthIn: (m['widthIn'] as num).toDouble(),
        heightIn: (m['heightIn'] as num).toDouble(),
        materialKind: m['materialKind'] as String,
        colorHex: m['colorHex'] as String,
        notes: Value(m['notes'] as String?),
      ));
    }
    await db.batch((b) => b.insertAll(db.targets, batch));
  }

  /// Seed the [TargetRacks] / [TargetRackChildren] reference catalog
  /// from `assets/seed_data/target_racks.json`. The JSON shape is an
  /// object with a top-level `racks` array; each rack carries a
  /// `children` array describing the in-rack layout.
  ///
  /// We insert each parent first to learn its auto-incremented id,
  /// then batch-insert its children with that id as `rackId`. Per-rack
  /// inserts are slower than one big batch but keep the FK wiring
  /// trivial — the seed dataset is tiny (single-digit racks) so the
  /// extra round-trips don't matter.
  Future<void> _seedTargetRacks() async {
    final root = await _readJsonObject('target_racks.json');
    final racks = (root['racks'] as List<dynamic>? ?? const <dynamic>[]);
    if (racks.isEmpty) return;

    for (final entry in racks) {
      final m = entry as Map<String, dynamic>;
      final rackId = await db.into(db.targetRacks).insert(
            TargetRacksCompanion.insert(
              name: m['name'] as String,
              description: Value(m['description'] as String?),
              rackKind: m['rack_kind'] as String,
              totalWidthIn: (m['total_width_in'] as num).toDouble(),
              totalHeightIn: (m['total_height_in'] as num).toDouble(),
              notes: Value(m['notes'] as String?),
            ),
          );
      final children = (m['children'] as List<dynamic>? ?? const <dynamic>[]);
      if (children.isEmpty) continue;
      final childBatch = <TargetRackChildrenCompanion>[];
      for (final c in children) {
        final cm = c as Map<String, dynamic>;
        childBatch.add(TargetRackChildrenCompanion.insert(
          rackId: rackId,
          position: cm['position'] as int,
          name: cm['name'] as String,
          shape: cm['shape'] as String,
          widthIn: (cm['width_in'] as num).toDouble(),
          heightIn: (cm['height_in'] as num).toDouble(),
          offsetXIn: (cm['offset_x_in'] as num).toDouble(),
          offsetYIn: (cm['offset_y_in'] as num).toDouble(),
          colorHex: cm['color_hex'] as String,
        ));
      }
      await db.batch((b) => b.insertAll(db.targetRackChildren, childBatch));
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

  /// Seed the verified scope + reticle catalog (schema v22) from three
  /// JSON files in `assets/seed_data/`:
  ///
  ///   * `scopes.json` -> `ScopeManufacturers` + `ScopeModels`.
  ///   * `reticles_v2.json` -> additive verified rows in the existing
  ///     `Reticles` table (carrying `verified`, `sourceUrl`,
  ///     `verifiedAt`, `designer`, `license`, `subtensionsJson`).
  ///   * `scope_reticle_options.json` -> `ScopeReticleOptions` join
  ///     between scopes and the reticle rows.
  ///
  /// The three files are coupled: the join references rows in the
  /// other two by name, so they must be inserted in dependency order
  /// (manufacturer -> model -> reticle -> option) within a single
  /// transaction. The caller is `seedIfNeeded` which already wraps
  /// the whole thing in `db.transaction(...)`, so failures in any of
  /// the three steps roll back cleanly.
  ///
  /// Defensive parsing: every JSON field is read with explicit null
  /// handling and type coercion. A missing manufacturer or model row
  /// is logged via `print` (so the verified scope row is silently
  /// dropped) rather than crashing the whole seed pass -- one bad
  /// option entry MUST NOT prevent the rest of the catalog from
  /// loading. Logging stays at the `print` level rather than going
  /// through a logging framework because this code only runs once
  /// per install and an operator looking at console output sees the
  /// drop directly.
  Future<void> _seedVerifiedScopes() async {
    // Step 1 -- scopes.json -> ScopeManufacturers + ScopeModels.
    final scopesRoot = await _readJsonObject('scopes.json');
    final manufacturers =
        (scopesRoot['manufacturers'] as List<dynamic>? ?? const <dynamic>[]);
    // Map of display name -> inserted scope-manufacturer id, used to
    // wire models to their parent without re-querying.
    final mfgIdByName = <String, int>{};
    // Map of (manufacturer name, model name) -> inserted scope-model id,
    // used to wire scope_reticle_options entries to their scope row.
    final modelIdByKey = <(String, String), int>{};
    for (final entry in manufacturers) {
      final m = entry as Map<String, dynamic>;
      final mfgName = m['name'] as String?;
      if (mfgName == null) continue;
      final mfgId = await db.into(db.scopeManufacturers).insert(
            ScopeManufacturersCompanion.insert(
              name: mfgName,
              country: Value(m['country'] as String?),
              website: Value(m['website'] as String?),
            ),
          );
      mfgIdByName[mfgName] = mfgId;
      final models = (m['models'] as List<dynamic>? ?? const <dynamic>[]);
      for (final modelEntry in models) {
        final mm = modelEntry as Map<String, dynamic>;
        final modelName = mm['model_name'] as String?;
        if (modelName == null) continue;
        final sourceUrl = mm['source_url'] as String?;
        final verifiedAtStr = mm['verified_at'] as String?;
        // Defensive: a verified scope row MUST carry a source URL +
        // verified_at date. Skip the row if either is missing -- the
        // table schema requires both, and accepting a stub would
        // silently violate the source-of-truth rule.
        if (sourceUrl == null || verifiedAtStr == null) {
          // Cannot persist row without provenance; log and skip.
          // Using print here matches the rest of the seed pipeline.
          // ignore: avoid_print
          print(
            'seed_loader: skipping scope row "$mfgName / $modelName": '
            'missing source_url or verified_at',
          );
          continue;
        }
        final verifiedAt = DateTime.tryParse(verifiedAtStr);
        if (verifiedAt == null) {
          // ignore: avoid_print
          print(
            'seed_loader: skipping scope row "$mfgName / $modelName": '
            'unparseable verified_at "$verifiedAtStr"',
          );
          continue;
        }
        final modelId = await db.into(db.scopeModels).insert(
              ScopeModelsCompanion.insert(
                manufacturerId: mfgId,
                modelName: modelName,
                category: mm['category'] as String? ?? 'rifle-scope',
                magnificationMin: Value(
                  (mm['magnification_min'] as num?)?.toDouble(),
                ),
                magnificationMax: Value(
                  (mm['magnification_max'] as num?)?.toDouble(),
                ),
                objectiveDiameterMm: Value(
                  (mm['objective_diameter_mm'] as num?)?.toInt(),
                ),
                tubeDiameterMm: Value(
                  (mm['tube_diameter_mm'] as num?)?.toInt(),
                ),
                focalPlane: mm['focal_plane'] as String? ?? 'first',
                reticleClass: mm['reticle_class'] as String? ?? 'mrad',
                clickValueMil: Value(
                  (mm['click_value_mil'] as num?)?.toDouble(),
                ),
                clickValueMoa: Value(
                  (mm['click_value_moa'] as num?)?.toDouble(),
                ),
                travelPerRevMil: Value(
                  (mm['travel_per_rev_mil'] as num?)?.toDouble(),
                ),
                travelPerRevMoa: Value(
                  (mm['travel_per_rev_moa'] as num?)?.toDouble(),
                ),
                maxElevationMil: Value(
                  (mm['max_elevation_mil'] as num?)?.toDouble(),
                ),
                maxElevationMoa: Value(
                  (mm['max_elevation_moa'] as num?)?.toDouble(),
                ),
                maxWindageMil: Value(
                  (mm['max_windage_mil'] as num?)?.toDouble(),
                ),
                maxWindageMoa: Value(
                  (mm['max_windage_moa'] as num?)?.toDouble(),
                ),
                eyeReliefIn: Value(
                  (mm['eye_relief_in'] as num?)?.toDouble(),
                ),
                weightOz: Value(
                  (mm['weight_oz'] as num?)?.toDouble(),
                ),
                lengthIn: Value(
                  (mm['length_in'] as num?)?.toDouble(),
                ),
                parallaxMinYd: Value(
                  (mm['parallax_min_yd'] as num?)?.toInt(),
                ),
                sourceUrl: sourceUrl,
                verifiedAt: verifiedAt,
                notes: Value(mm['notes'] as String?),
              ),
            );
        modelIdByKey[(mfgName, modelName)] = modelId;
      }
    }

    // Step 2 -- reticles_v2.json -> additive rows in `Reticles` table.
    // Each row carries a stable string id (e.g. "vortex_ebr7d_mrad_v2")
    // that the join file references. We accumulate a name -> db id map
    // for the join step that follows.
    final reticleIdBySeedId = <String, int>{};
    final reticlesV2 = await _readJsonList('reticles_v2.json');
    for (final entry in reticlesV2) {
      final r = entry as Map<String, dynamic>;
      final seedId = r['id'] as String?;
      if (seedId == null) continue;
      final manufacturerName = r['manufacturer'] as String?;
      final model = r['model'] as String?;
      final type = r['type'] as String?;
      final nativeUnit = r['nativeUnit'] as String?;
      if (manufacturerName == null ||
          model == null ||
          type == null ||
          nativeUnit == null) {
        // ignore: avoid_print
        print(
          'seed_loader: skipping reticles_v2 row "$seedId": missing '
          'required field (manufacturer/model/type/nativeUnit)',
        );
        continue;
      }
      final maxExtent = (r['maxExtentUnits'] as num?)?.toDouble() ?? 10.0;
      final elementsValue = r['elements'];
      // The element list may be an empty array on intentionally-
      // unverified rows (e.g. Horus TReMoR3 placeholder). We persist
      // the empty list as JSON `[]` so the renderer's defensive
      // empty-list check kicks in.
      final elementsJson =
          json.encode(elementsValue is List<dynamic> ? elementsValue : <dynamic>[]);
      final verifiedFlag = r['verified'] as bool? ?? false;
      final sourceUrl = r['sourceUrl'] as String?;
      final verifiedAtStr = r['verifiedAt'] as String?;
      final verifiedAt = verifiedAtStr != null
          ? DateTime.tryParse(verifiedAtStr)
          : null;
      final subtensionsValue = r['subtensions'];
      final subtensionsJson = subtensionsValue == null
          ? null
          : json.encode(subtensionsValue);
      final reticleId = await db.into(db.reticles).insert(
            ReticlesCompanion.insert(
              manufacturerId: manufacturerName,
              model: model,
              family: Value(r['family'] as String?),
              type: type,
              nativeUnit: nativeUnit,
              maxExtentUnits: maxExtent,
              definitionJson: elementsJson,
              notes: Value(r['notes'] as String?),
              verified: Value(verifiedFlag),
              sourceUrl: Value(sourceUrl),
              verifiedAt: Value(verifiedAt),
              designer: Value(r['designer'] as String?),
              license: Value(r['license'] as String?),
              subtensionsJson: Value(subtensionsJson),
            ),
          );
      reticleIdBySeedId[seedId] = reticleId;
    }

    // Step 3 -- scope_reticle_options.json -> ScopeReticleOptions join.
    final optionsRoot = await _readJsonObject('scope_reticle_options.json');
    final options =
        (optionsRoot['options'] as List<dynamic>? ?? const <dynamic>[]);
    final optBatch = <ScopeReticleOptionsCompanion>[];
    for (final entry in options) {
      final o = entry as Map<String, dynamic>;
      final mfgName = o['scope_manufacturer'] as String?;
      final modelName = o['scope_model'] as String?;
      final reticleSeedId = o['reticle_id'] as String?;
      if (mfgName == null || modelName == null || reticleSeedId == null) {
        // ignore: avoid_print
        print(
          'seed_loader: skipping scope_reticle_options row: '
          'missing scope_manufacturer / scope_model / reticle_id',
        );
        continue;
      }
      final scopeModelId = modelIdByKey[(mfgName, modelName)];
      final reticleId = reticleIdBySeedId[reticleSeedId];
      if (scopeModelId == null || reticleId == null) {
        // Soft failure: a join row that doesn't resolve is dropped
        // rather than crashing the whole seed pass. Logged so an
        // operator looking at the console can spot the broken link.
        // ignore: avoid_print
        print(
          'seed_loader: skipping scope_reticle_options row "$mfgName / '
          '$modelName / $reticleSeedId": parent row missing '
          '(scopeModelId=$scopeModelId, reticleId=$reticleId)',
        );
        continue;
      }
      optBatch.add(ScopeReticleOptionsCompanion.insert(
        scopeModelId: scopeModelId,
        reticleId: reticleId,
        manufacturerSku: Value(o['manufacturer_sku'] as String?),
        isDefault: Value(o['is_default'] as bool? ?? false),
        notes: Value(o['notes'] as String?),
      ));
    }
    if (optBatch.isNotEmpty) {
      await db.batch((b) => b.insertAll(db.scopeReticleOptions, optBatch));
    }
  }
}
