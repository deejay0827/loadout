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

    final any = cartridgesReseed ||
        powdersReseed ||
        bulletsReseed ||
        primersReseed ||
        brassReseed ||
        firearmsReseed ||
        firearmPartsReseed ||
        opticsReseed;
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
}
