// FILE: lib/database/seed_loader.dart
//
// ============================================================================
// WHAT THIS FILE DOES
// ============================================================================
// On launch (called from `main.dart` right after the database opens), this
// class reads the bundled JSON catalog files in `assets/seed_data/` —
// `cartridges.json`, `powders.json`, `bullets.json`, `primers.json`,
// `brass.json`, `firearms.json`, `firearm_parts.json` — and inserts their
// contents into the reference tables defined in `database.dart`. Those
// tables (`Cartridges`, `Powders`, `Bullets`, `Primers`, `BrassProducts`,
// `FirearmsRef`, `FirearmParts`, plus the shared `Manufacturers` lookup)
// are what populate every component dropdown the user sees in the
// recipe form, the firearm form, and the SAAMI lookup screen.
//
// The seed data ships as part of the Flutter app bundle: at build time
// the contents of `assets/` get copied into the iOS / Android binary,
// and at runtime `rootBundle.loadString(path)` reads them back as a
// `String`. `json.decode()` then parses that string into Dart maps and
// lists. The seed methods (`_seedCartridges`, `_seedPowders`,
// `_seedBullets`, `_seedPrimers`, `_seedBrass`, `_seedFirearms`,
// `_seedFirearmParts`) walk the parsed structure and emit batched
// drift inserts via the generated `*Companion.insert(...)` helpers.
//
// `seedIfNeeded()` is the single public entry point. It checks three
// flags exposed by `AppDatabase`: `firstRun` (the cartridge table is
// empty, i.e. brand-new install), `primersMissing` (the primer table is
// empty — happens after a v3 migration deliberately wipes primers to
// force a re-seed with the new `productLine` column), and
// `cartridgesNeedReseed` (the cartridges exist but are missing the v2
// SAAMI/CIP dimensional fields, indicating an upgraded install that
// needs a refresh). If none are true, the function returns immediately.
// Otherwise the appropriate seed methods run inside one drift
// transaction so the database is never half-populated.
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
// The conditional re-seed logic exists because the schema and the data
// shape evolve over time. When v2 added SAAMI dimensions to existing
// cartridges, the migration could only `ALTER TABLE` to add the
// columns — populating them required re-running the seed. Rather than
// blow away the database and ask users to re-enter their loads, the
// re-seed pattern lets us refresh just the reference data while
// leaving user data (`UserLoads`, `UserFirearms`, `CustomComponents`)
// completely untouched.
//
// ============================================================================
// WHY THIS IS HARDER THAN IT LOOKS
// ============================================================================
// The dispatch logic in `seedIfNeeded` is deliberately three-pronged:
//   - If `firstRun` we seed everything.
//   - If only `cartridgesNeedReseed` we re-seed cartridges (deleting
//     existing rows first to avoid unique-constraint collisions on
//     `name`).
//   - If only `primersMissing` we re-seed primers.
// Mixing those branches incorrectly would either skip data that needs
// to be present (broken UI) or duplicate-insert and crash on unique
// constraints. This is why the function reads all three flags up front
// and gates each seed step explicitly.
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
// - Indirectly, every UI surface that reads from the seeded reference
//   tables: `lib/screens/loads/load_form_screen.dart` (component
//   dropdowns), `lib/screens/firearms/firearm_form_screen.dart`,
//   `lib/screens/saami/saami_screen.dart`, etc.
//
// ============================================================================
// SIDE EFFECTS
// ============================================================================
// - Reads up to 7 JSON files from the bundled `assets/seed_data/`
//   directory via `rootBundle.loadString`.
// - Writes potentially thousands of rows into SQLite (cartridges,
//   manufacturers, powders, bullets, primers, brass products, firearms,
//   firearm parts) inside one transaction.
// - On v3 migrations + re-seed paths, deletes existing rows in the
//   targeted reference table before re-inserting (to avoid unique
//   constraint collisions on `name`).
// - No network I/O. No cloud calls. Reference data stays entirely
//   on-device.

import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:flutter/services.dart' show rootBundle;

import 'database.dart';

/// Reads the bundled JSON files in `assets/seed_data/` and populates the
/// reference tables on first run. Idempotent — checks `needsSeed` first.
class SeedLoader {
  SeedLoader(this.db);
  final AppDatabase db;

  Future<void> seedIfNeeded() async {
    final firstRun = await db.needsSeed;
    final primersMissing = await db.primersAreEmpty;
    final cartridgesNeedReseed = await db.cartridgesNeedReseed;
    if (!firstRun && !primersMissing && !cartridgesNeedReseed) return;

    await db.transaction(() async {
      // Cartridges: re-seed when first run OR when an existing install is
      // missing the v2 SAAMI/CIP dimension fields. The v2 migration only
      // added the columns; without this re-seed users see "—" for body /
      // shoulder / neck / rim dimensions even though the JSON has them.
      if (firstRun || cartridgesNeedReseed) {
        if (cartridgesNeedReseed && !firstRun) {
          await db.delete(db.cartridges).go();
        }
        await _seedCartridges();
      }
      if (firstRun) {
        await _seedPowders();
        await _seedBullets();
        await _seedBrass();
        await _seedFirearms();
        await _seedFirearmParts();
      }
      // Re-seed primers if they're missing — the v3 migration intentionally
      // clears them so the new productLine field gets populated for
      // upgrading users without nuking the rest of the DB.
      if (firstRun || primersMissing) {
        await _seedPrimers();
      }
    });
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

  Future<List<dynamic>> _readJsonList(String path) async {
    final raw = await rootBundle.loadString(path);
    return json.decode(raw) as List<dynamic>;
  }

  Future<Map<String, dynamic>> _readJsonObject(String path) async {
    final raw = await rootBundle.loadString(path);
    return json.decode(raw) as Map<String, dynamic>;
  }

  Future<void> _seedCartridges() async {
    final data = await _readJsonList('assets/seed_data/cartridges.json');
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
    final root = await _readJsonObject('assets/seed_data/powders.json');
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
    final root = await _readJsonObject('assets/seed_data/bullets.json');
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
    final root = await _readJsonObject('assets/seed_data/primers.json');
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
    final root = await _readJsonObject('assets/seed_data/brass.json');
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
    final root = await _readJsonObject('assets/seed_data/firearms.json');
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
    final root = await _readJsonObject('assets/seed_data/firearm_parts.json');
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
}
