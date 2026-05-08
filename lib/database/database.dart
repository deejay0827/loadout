// FILE: lib/database/database.dart
//
// ============================================================================
// WHAT THIS FILE DOES
// ============================================================================
// Defines the LoadOut app's entire on-device SQLite schema using `drift` —
// a typed Dart ORM (Object-Relational Mapper). Drift is the preferred way
// to talk to SQLite from Flutter: instead of writing raw SQL strings, you
// describe each table as a Dart class that extends `Table`, declare its
// columns as typed getters (`IntColumn`, `TextColumn`, `RealColumn`,
// `BoolColumn`, `DateTimeColumn`), and a build-time code generator
// produces all the boilerplate to insert, query, update, and delete rows
// with full Dart type safety.
//
// The class declarations in this file fall into two groups. First are the
// "reference" tables — `Manufacturers`, `Cartridges`, `Powders`, `Bullets`,
// `Primers`, `BrassProducts`, `FirearmsRef`, `FirearmParts`. These are
// effectively read-only catalogs seeded from the JSON files in
// `assets/seed_data/` on first launch (see `seed_loader.dart`); the user
// never edits them, the dropdowns in the UI just pull from them. Second
// are the user data tables — `CustomComponents`, `UserLoads`,
// `UserFirearms`, `BrassLots`, `Batches`, `TestSessions`, `PowderLots`,
// `BulletLots`, `PrimerLots`, `UserProcessSteps`, `UserCustomFields`,
// `UserCustomFieldValues`, `LoadDevelopmentSessions`. These hold the
// reloader's actual recipes, firearms, batches, range data, and custom
// fields. They are the entire reason for the local-first architecture
// described in `CLAUDE.md`.
//
// Below the table declarations is the `AppDatabase` class. The
// `@DriftDatabase(tables: [...])` annotation on it is what triggers the
// code generator: drift inspects the listed tables and emits a sibling
// file `database.g.dart` (which you must NEVER edit by hand — re-run
// `dart run build_runner build` after schema changes). That generated
// file defines `_$AppDatabase`, the mixin our class extends; it provides
// the typed `select(...)`, `insert(...)`, `update(...)`, `delete(...)`
// methods plus generated companions like `UserLoadsCompanion` for
// constructing rows.
//
// `schemaVersion` is currently 14. The `MigrationStrategy` defines two
// callbacks: `onCreate` runs on a fresh install (creates every table, then
// seeds the 8 standard reloading process steps), and `onUpgrade` runs
// when an installed user opens a build with a newer `schemaVersion`. The
// upgrade path adds columns and tables additively, preserving user data,
// while occasionally invalidating reference tables so they get re-seeded
// from the latest JSON. The three boolean getters at the bottom
// (`needsSeed`, `primersAreEmpty`, `cartridgesNeedReseed`) are how
// `seed_loader.dart` detects whether seeding (or re-seeding) needs to
// run — they spot-check specific rows that should always exist and
// always have certain fields populated.
//
// ============================================================================
// WHY IT EXISTS IN THE ARCHITECTURE
// ============================================================================
// SQLite is the storage engine for everything LoadOut knows about a user.
// There is no Firestore, no cloud sync, no remote API for user data. This
// file is the single source of truth for the schema; if it doesn't
// declare a column, that column doesn't exist on disk and the rest of
// the app can't store the value.
//
// The `@DriftDatabase` class also acts as the central repository handle —
// every repository class in `lib/repositories/` takes an `AppDatabase` in
// its constructor and uses it to issue queries. `app.dart` provides the
// singleton `AppDatabase` to the whole widget tree via `provider`, so
// every screen and repository points at the same SQLite connection.
//
// The migration strategy is the contract that lets the schema evolve
// without breaking existing users. Each time we change anything that
// affects on-disk shape, we must bump `schemaVersion` and add an
// `onUpgrade` clause. Skip that and an existing user's app crashes on
// next launch with "no such column" errors.
//
// ============================================================================
// WHY THIS IS HARDER THAN IT LOOKS
// ============================================================================
// `database.g.dart` is generated. Editing it manually will be silently
// overwritten by the next `build_runner` run. After any change to this
// file, run `dart run build_runner build` (or
// `dart run build_runner watch --delete-conflicting-outputs` for
// continuous regeneration). Forgetting this leaves the project in a
// non-compiling state because the generated companions and `_$AppDatabase`
// mixin won't reflect the new schema.
//
// SQLite cannot drop or alter columns once they exist — only add. So
// `onUpgrade` is constrained to adding columns and tables. If a column
// needs to change type, the migration must create a new column, copy
// data, and stop reading the old one. We have not had to do this yet.
//
// JSON-encoded text columns (`aliasesJson`, `calibersJson`,
// `compatibleWithJson`, `processStateJson`, `rungsJson`) are how we store
// list/map values without a separate child table. They look like strings
// to SQLite but get decoded at the repository boundary with
// `json.decode(...)`. This trades query-ability (you can't easily WHERE
// against a JSON value) for schema simplicity. Don't introduce JSON
// columns when a child table would let you query the values; do
// introduce them for tag-like data the user just sees.
//
// `currentDateAndTime` is a drift-provided default that records "now"
// when the row is inserted. It's the standard way to backfill
// `createdAt` / `updatedAt` columns. Drift translates this to SQLite's
// `CURRENT_TIMESTAMP` under the hood.
//
// The migration sequence in `onUpgrade` is `if (from < 2) { ... }
// if (from < 3) { ... } if (from < 4) { ... } if (from < 5) { ... }
// if (from < 6) { ... } if (from < 7) { ... }` —
// drift gives you the user's old schema version and you fall through
// every gap that needs catching up. Don't use `else if`: a user three
// versions behind needs every block to run in order.
//
// The v3 migration intentionally clears `Primers` and the `primer`-kind
// `Manufacturers` rows. Without that, the new `productLine` column would
// stay null for every existing primer, and the cascading dropdown in the
// recipe form would lose the marketing names. The user-data tables
// (`UserLoads`, `UserFirearms`, `CustomComponents`) are NEVER deleted by
// any migration — that would lose the user's work.
//
// `cartridgesNeedReseed` spot-checks "9mm Luger" because that's a stable
// canary cartridge that has been in the seed data since v1 and was
// extended with the v2 SAAMI dimensional fields. If it exists but
// `bodyDiameterIn` is null, the user is on a v2-migrated database that
// needs the cartridges re-seeded so the new fields populate.
//
// ============================================================================
// WHO CONSUMES THIS FILE
// ============================================================================
// - `lib/main.dart` — instantiates `AppDatabase()`, which opens the
//   SQLite connection and runs migrations.
// - `lib/database/seed_loader.dart` — calls `db.needsSeed`,
//   `db.primersAreEmpty`, `db.cartridgesNeedReseed` to decide what to
//   re-seed; uses the generated companions to insert rows.
// - `lib/repositories/component_repository.dart` — reads the reference
//   tables (`Powders`, `Bullets`, `Primers`, `BrassProducts`,
//   `Manufacturers`, `Cartridges`) for dropdown menus.
// - `lib/repositories/firearm_repository.dart` — CRUD over `UserFirearms`
//   and `FirearmsRef`.
// - `lib/repositories/recipe_repository.dart` — CRUD over `UserLoads`.
// - `lib/repositories/brass_lot_repository.dart` — CRUD over `BrassLots`.
// - `lib/repositories/batch_repository.dart` — CRUD over `Batches` and
//   `TestSessions`.
// - `lib/repositories/process_step_repository.dart` — CRUD over
//   `UserProcessSteps`.
// - `lib/repositories/load_development_repository.dart` — CRUD over
//   `LoadDevelopmentSessions`.
// - Indirectly: every UI screen via the repositories above.
//
// ============================================================================
// SIDE EFFECTS
// ============================================================================
// - `AppDatabase()` constructor opens (or creates) the `loadout` SQLite
//   file in the OS application support directory, runs `onCreate` on
//   fresh installs, runs `onUpgrade` when an installed app opens a
//   build with a newer `schemaVersion`. This blocks the calling future
//   until SQLite finishes initializing.
// - `_seedStandardProcessSteps()` writes 8 rows into `UserProcessSteps`
//   on fresh installs and v4 migrations.
// - The v3 migration deletes every row in `Primers` and every
//   primer-kind row in `Manufacturers` to force a re-seed.
// - The schema version field controls one-shot migration writes that
//   alter the on-disk shape. Bumping it without an accompanying
//   migration block will cause SQLite errors on next launch.

import 'package:drift/drift.dart';
import 'package:drift_flutter/drift_flutter.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:path_provider/path_provider.dart';

part 'database.g.dart';

// ─────────────────────── Reference tables (read-only seed) ───────────────────────

@DataClassName('ManufacturerRow')
class Manufacturers extends Table {
  IntColumn get id => integer().autoIncrement()();
  TextColumn get name => text()();
  TextColumn get country => text().nullable()();
  /// 'powder' | 'bullet' | 'primer' | 'brass' | 'firearm' | 'parts' |
  /// 'optics' | 'ammo'
  TextColumn get kind => text()();

  @override
  List<Set<Column>> get uniqueKeys => [
        {name, kind},
      ];
}

@DataClassName('CartridgeRow')
class Cartridges extends Table {
  IntColumn get id => integer().autoIncrement()();
  TextColumn get name => text().unique()();
  /// 'pistol' | 'rifle' | 'shotgun'
  TextColumn get type => text()();
  RealColumn get bulletDiameterIn => real().nullable()();
  RealColumn get caseLengthIn => real().nullable()();
  RealColumn get maxCoalIn => real().nullable()();
  RealColumn get gauge => real().nullable()();
  RealColumn get shellLengthIn => real().nullable()();
  TextColumn get parentCase => text().nullable()();
  IntColumn get yearIntroduced => integer().nullable()();
  /// JSON array of alias strings
  TextColumn get aliasesJson => text().withDefault(const Constant('[]'))();

  // ── Extended SAAMI/CIP dimensional fields (added schema v2) ──
  RealColumn get bodyDiameterIn => real().nullable()();
  RealColumn get shoulderDiameterIn => real().nullable()();
  RealColumn get shoulderAngleDeg => real().nullable()();
  RealColumn get neckDiameterIn => real().nullable()();
  RealColumn get neckLengthIn => real().nullable()();
  RealColumn get baseToShoulderIn => real().nullable()();
  RealColumn get baseToNeckIn => real().nullable()();
  RealColumn get rimDiameterIn => real().nullable()();
  RealColumn get rimThicknessIn => real().nullable()();
  /// 'small-pistol' | 'large-pistol' | 'small-rifle' | 'large-rifle' | 'berdan'
  TextColumn get primerType => text().nullable()();
  /// e.g. '1:8'
  TextColumn get twistRate => text().nullable()();
  IntColumn get maxAvgPressurePsi => integer().nullable()();
  RealColumn get boreDiameterIn => real().nullable()();
  RealColumn get grooveDiameterIn => real().nullable()();
  /// 'bottleneck' | 'straight' | 'belted-bottleneck' | etc.
  TextColumn get caseSubtype => text().nullable()();
  /// 'Z299.1' | 'Z299.3' | 'Z299.4'
  TextColumn get saamiDoc => text().nullable()();
}

@DataClassName('PowderRow')
class Powders extends Table {
  IntColumn get id => integer().autoIncrement()();
  IntColumn get manufacturerId => integer().references(Manufacturers, #id)();
  TextColumn get name => text()();
  TextColumn get type => text()();
  TextColumn get form => text().nullable()();
  TextColumn get burnRate => text().nullable()();
  TextColumn get notes => text().nullable()();
}

@DataClassName('BulletRow')
class Bullets extends Table {
  IntColumn get id => integer().autoIncrement()();
  IntColumn get manufacturerId => integer().references(Manufacturers, #id)();
  TextColumn get line => text()();
  RealColumn get diameterIn => real()();
  RealColumn get weightGr => real()();
  TextColumn get design => text().nullable()();
  TextColumn get jacket => text().nullable()();
  TextColumn get application => text().nullable()();
  RealColumn get bcG1 => real().nullable()();
  RealColumn get bcG7 => real().nullable()();
  TextColumn get notes => text().nullable()();
}

@DataClassName('PrimerRow')
class Primers extends Table {
  IntColumn get id => integer().autoIncrement()();
  IntColumn get manufacturerId => integer().references(Manufacturers, #id)();
  /// Model number / code (e.g. "GM205M", "WLR", "9.5M"). Used in `Federal #205M`
  /// style labels and on box headstamps.
  TextColumn get name => text()();
  TextColumn get size => text()();
  BoolColumn get magnum => boolean().withDefault(const Constant(false))();
  TextColumn get grade => text().nullable()();
  /// Manufacturer's marketing name for the product family
  /// (e.g. "Premium Gold Medal Small Rifle Match"). Shown in the product
  /// dropdown alongside `#name` so non-experts can recognize what they're
  /// picking. Added in schema v3. Nullable to allow custom user-added primers
  /// to omit it.
  TextColumn get productLine => text().nullable()();
  TextColumn get notes => text().nullable()();
}

@DataClassName('BrassProductRow')
class BrassProducts extends Table {
  IntColumn get id => integer().autoIncrement()();
  IntColumn get manufacturerId => integer().references(Manufacturers, #id)();
  TextColumn get tier => text().nullable()();
  /// JSON array of caliber names this brass is offered in
  TextColumn get calibersJson => text().withDefault(const Constant('[]'))();
  TextColumn get notes => text().nullable()();
}

@DataClassName('FirearmRefRow')
class FirearmsRef extends Table {
  IntColumn get id => integer().autoIncrement()();
  IntColumn get manufacturerId => integer().references(Manufacturers, #id)();
  TextColumn get model => text()();
  /// 'pistol' | 'rifle' | 'shotgun'
  TextColumn get type => text()();
  /// 'semi-auto' | 'bolt-action' | etc.
  TextColumn get action => text().nullable()();
  TextColumn get calibersJson => text().withDefault(const Constant('[]'))();
  TextColumn get notes => text().nullable()();

  // ── Factory-spec fields used to auto-fill the firearm form (added v9) ──
  /// Most-common factory barrel length in inches for the documented model
  /// variant. Nullable for entries where we don't have reliable spec data.
  RealColumn get barrelLengthIn => real().nullable()();
  /// Standard factory twist rate, e.g. "1:8" or "1:9.84". Nullable for
  /// entries where the spec varies by sub-variant or isn't documented.
  TextColumn get twistRate => text().nullable()();
}

@DataClassName('FirearmPartRow')
class FirearmParts extends Table {
  IntColumn get id => integer().autoIncrement()();
  IntColumn get manufacturerId => integer().references(Manufacturers, #id)();
  TextColumn get name => text()();
  TextColumn get category => text()();
  TextColumn get compatibleWithJson => text().withDefault(const Constant('[]'))();
  TextColumn get notes => text().nullable()();
}

/// User-saved ballistic profile (added schema v8). A "profile" is a
/// named, reusable bundle of inputs to the ballistics calculator
/// (projectile, MV/zero, environment defaults, range output prefs) so
/// the user can switch between configurations like "6.5 CM 140gr ELD-M
/// Tikka" or "300 PRC 225gr Hornady" without retyping every field.
///
/// Environment fields are nullable because the ballistics screen falls
/// back to its `SharedPreferences`-stored defaults when a profile field
/// is null. `firearmId` and `bulletId` are optional links back to the
/// rows that originally provided the values; they let the UI re-resolve
/// the source rifle / bullet for display, but the stored numeric values
/// remain the source of truth.
@DataClassName('BallisticProfileRow')
class BallisticProfiles extends Table {
  IntColumn get id => integer().autoIncrement()();
  TextColumn get name => text()();
  // Projectile.
  RealColumn get bulletWeightGr => real()();
  RealColumn get bulletDiameterIn => real()();
  RealColumn get ballisticCoefficient => real()();
  /// 'g1' | 'g7'
  TextColumn get dragModel => text()();
  RealColumn get bulletLengthIn => real().nullable()();
  // Muzzle / zero.
  RealColumn get muzzleVelocityFps => real()();
  IntColumn get zeroRangeYd => integer()();
  RealColumn get sightHeightIn => real()();
  TextColumn get twistRate => text().nullable()();
  // Optional source links.
  IntColumn get firearmId => integer().nullable()();
  IntColumn get bulletId => integer().nullable()();
  // Environment defaults — nullable; calculator falls back to global prefs.
  RealColumn get temperatureF => real().nullable()();
  RealColumn get pressureInHg => real().nullable()();
  RealColumn get humidityPct => real().nullable()();
  RealColumn get elevationFt => real().nullable()();
  RealColumn get windSpeedMph => real().nullable()();
  RealColumn get windDirectionDeg => real().nullable()();
  RealColumn get latitudeDeg => real().nullable()();
  RealColumn get firingAzimuthDeg => real().nullable()();
  // Output prefs.
  IntColumn get rangeIncrementYd => integer()();
  IntColumn get rangeMinYd => integer()();
  IntColumn get rangeMaxYd => integer()();
  TextColumn get notes => text().nullable()();
  DateTimeColumn get createdAt => dateTime().withDefault(currentDateAndTime)();
  DateTimeColumn get updatedAt => dateTime().withDefault(currentDateAndTime)();
}

/// Reference catalog of rifle scopes / optics. Seeded from
/// `assets/seed_data/optics.json` (added schema v7). The dropdown on the
/// firearm form lets the user pick the optic mounted on a given rifle so
/// the ballistics calculator can later surface the make/model alongside
/// the rifle name. Sight height is intentionally NOT stored here — it's a
/// function of the rings/mount the user chooses, not the optic, so it
/// remains a per-firearm field on `UserFirearms.sightHeightIn`.
@DataClassName('OpticRow')
class Optics extends Table {
  IntColumn get id => integer().autoIncrement()();
  IntColumn get manufacturerId => integer().references(Manufacturers, #id)();
  TextColumn get model => text()();
  /// 'rifle-scope' | 'lpvo' | 'red-dot' | 'prism' | 'spotting'
  TextColumn get category => text()();
  /// e.g. "6-36x" or "1-6x" or "1x".
  TextColumn get magnification => text()();
  /// Objective lens diameter in mm. 0 for non-objective optics (most red dots).
  IntColumn get objectiveMm => integer()();
  /// Main tube diameter in mm (30, 34, 35, 36 etc.). 0 for tubeless reflex sights.
  IntColumn get tubeMm => integer()();
  /// 'first' | 'second' | 'n/a'
  TextColumn get focalPlane => text()();
  /// Free-form reticle name / family.
  TextColumn get reticle => text()();
  /// 'MOA' | 'MIL' (turret adjustment unit).
  TextColumn get adjustmentUnit => text()();
  /// Minimum side-focus / parallax setting in yards (nullable; rare on red dots).
  IntColumn get parallaxMinYd => integer().nullable()();
  /// Optic weight in ounces (nullable).
  RealColumn get weightOz => real().nullable()();
  TextColumn get notes => text().nullable()();

  // ── Default reticle link (added schema v11) ──
  /// Optional FK to a row in `Reticles`. Lets the seed catalog declare
  /// "this optic ships with this reticle" so the firearm form's reticle
  /// picker can pre-select the right entry the moment the user picks
  /// a Razor Gen II off the optics list. Nullable because most catalog
  /// scopes can be ordered with multiple reticle options.
  IntColumn get reticleId => integer().nullable()();
}

/// Reference catalog of scope reticles (added schema v11). One row per
/// reticle pattern (Vortex EBR-7C MRAD, Nightforce MIL-XT, the legacy
/// USMC Mil-Dot, etc.). The actual element list (lines, hash marks,
/// dots, floating numbers) is JSON-encoded in `definitionJson` because
/// it varies wildly in size between reticles and isn't useful to query
/// against from SQL.
///
/// Seeded from `assets/seed_data/reticles.json`. `manufacturerId` here
/// is a free-form `text` column (rather than an FK to `Manufacturers`)
/// so the seeder doesn't have to resolve the manufacturer table before
/// inserting reticles, and so a brand whose only listing is a reticle
/// (e.g. an aftermarket reticle in a third-party scope) doesn't have
/// to be added to `Manufacturers` separately.
@DataClassName('ReticleRow')
class Reticles extends Table {
  IntColumn get id => integer().autoIncrement()();
  /// Manufacturer name (matches `Manufacturers.name` for `kind = 'optics'`
  /// rows when one exists). Stored as text so seed loading doesn't depend
  /// on the order of `Manufacturers` inserts.
  TextColumn get manufacturerId => text()();
  /// Model / pattern name, e.g. "EBR-7C MRAD".
  TextColumn get model => text()();
  /// Optional grouping label, e.g. "Razor HD Gen II reticles".
  TextColumn get family => text().nullable()();
  /// 'ffp' | 'sfp' | 'fixed'
  TextColumn get type => text()();
  /// 'mil' | 'moa' | 'ipsc' | 'bdc'
  TextColumn get nativeUnit => text()();
  /// Half-extent (center to edge) of the rendered reticle in native units.
  /// e.g. 10 for "10 mil to each side".
  RealColumn get maxExtentUnits => real()();
  /// JSON array of element objects (see `lib/data/reticle_library.dart`).
  TextColumn get definitionJson => text()();
  TextColumn get notes => text().nullable()();
  DateTimeColumn get createdAt => dateTime().withDefault(currentDateAndTime)();
}

/// Reference catalog of custom drag curves (CDMs / DSFs) for specific
/// bullets (added schema v12). Modern long-range bullet vendors publish
/// per-bullet drag-coefficient tables — Berger calls them Custom Drag
/// Models (CDMs), Hornady calls them DSFs / 4DOF data — that are
/// dramatically more accurate than a single-number BC against a generic
/// G7 reference shape.
///
/// Each row stores one bullet's `(mach, cd)` table, JSON-encoded in
/// `datapointsJson`. The ballistics screen lets the user pick a curve
/// from this catalog as an alternative to the G1/G2/G5/G6/G7/G8
/// dropdown; when a curve is selected, the Projectile receives a
/// `CustomDragCurve` instance and the solver bypasses the G-table
/// path. Custom curves do NOT use a BC — the curve already captures
/// the bullet's real Cd-vs-Mach relationship — so the BC field is
/// hidden in the UI when a curve is active.
///
/// Seeded from `assets/seed_data/drag_curves/*.json` on first launch
/// (see `seed_loader.dart`). The repository layer reads rows from
/// here and constructs `CustomDragCurve` instances for the solver.
@DataClassName('DragCurveRow')
class DragCurves extends Table {
  IntColumn get id => integer().autoIncrement()();
  /// Manufacturer / brand (e.g. "Berger", "Hornady"). Stored as text
  /// rather than an FK to `Manufacturers` because the source of these
  /// curves is editorial — many curves come from the manufacturer's
  /// public ballistic-tool data — and the manufacturer name on the
  /// curve does not have to round-trip to a `Manufacturers` row.
  TextColumn get manufacturer => text()();
  /// Bullet line / family (e.g. "Hybrid Target", "ELD-Match", "VLD").
  TextColumn get line => text()();
  /// Bullet mass in grains.
  RealColumn get weightGr => real()();
  /// Bullet diameter in inches (e.g. 0.264 for 6.5mm).
  RealColumn get diameterIn => real()();
  /// JSON array of `{"mach": x, "cd": y}` objects, sorted ascending by
  /// Mach. Decoded by `CustomDragCurve.fromDatapointsJson`.
  TextColumn get datapointsJson => text()();
  /// Free-form provenance / source citation
  /// (e.g. "Berger Bullets CDM file 2024-01-15").
  TextColumn get source => text().nullable()();
  TextColumn get notes => text().nullable()();
  DateTimeColumn get createdAt => dateTime().withDefault(currentDateAndTime)();

  /// `(manufacturer, line, weightGr, diameterIn)` together identify a
  /// curve so a re-seed (or a manifest-driven update) can detect that
  /// "Berger 6.5mm 140gr Hybrid Target" already exists rather than
  /// inserting a duplicate. Unique constraint mirrors the seed-loader's
  /// behaviour for other catalogs.
  @override
  List<Set<Column>> get uniqueKeys => [
        {manufacturer, line, weightGr, diameterIn},
      ];
}

/// Reference catalog of factory ammunition products (added schema v14).
/// Distinct from `Bullets` (which catalogs reloading-component bullet
/// projectiles). A `FactoryLoads` row is one published factory cartridge
/// SKU — e.g. "Hornady Match 6.5 Creedmoor 140 gr ELD-M" — with the
/// manufacturer's published muzzle velocity and ballistic coefficient.
///
/// Drives the "Factory Ammo" picker in the ballistics calculator and the
/// Range Day workspace. Intentionally NOT surfaced in the recipe form —
/// recipes are for handloaders, factory ammo doesn't belong there.
///
/// Seeded from `assets/seed_data/factory_loads.json`. Manufacturer rows
/// are looked up / inserted in the shared `Manufacturers` table with
/// `kind = 'ammo'`, alongside the existing `bullet`, `powder`, etc.
/// kinds. The shared `Manufacturers` row keeps brand metadata in one
/// place even when the same brand also appears under a different kind
/// (e.g. Hornady appears as both `bullet` and `ammo`).
@DataClassName('FactoryLoadRow')
class FactoryLoads extends Table {
  IntColumn get id => integer().autoIncrement()();
  IntColumn get manufacturerId => integer().references(Manufacturers, #id)();
  /// Marketing product line (e.g. "Match", "Precision Hunter", "ELD-X").
  /// Free-form text — manufacturers don't share a vocabulary here.
  TextColumn get productLine => text()();
  /// Cartridge name as the manufacturer prints it on the box
  /// (e.g. "6.5 Creedmoor", ".308 Win"). Loose match against the
  /// `Cartridges` reference catalog name + aliases at query time.
  TextColumn get caliber => text()();
  /// Bullet name as listed on the box (e.g. "ELD Match", "InterLock SP",
  /// "TGK"). Distinct from the reloading `Bullets.line` because factory
  /// product bullets sometimes carry box-only names that don't appear in
  /// the reloading-bullet catalog.
  TextColumn get bulletName => text()();
  RealColumn get bulletWeightGr => real()();
  RealColumn get bulletDiameterIn => real().nullable()();
  RealColumn get bcG1 => real().nullable()();
  RealColumn get bcG7 => real().nullable()();
  /// Manufacturer-published muzzle velocity in fps. Note: this is from
  /// the test barrel listed in the spec sheet; real-world velocity
  /// varies with barrel length and chamber, and the user can override
  /// the value in the calculator.
  RealColumn get factoryMvFps => real().nullable()();
  /// Test barrel length the published MV was measured against, in
  /// inches. Lets advanced users translate to their real barrel via a
  /// rough rule-of-thumb correction. Nullable when the manufacturer
  /// doesn't list it.
  RealColumn get testBarrelLengthIn => real().nullable()();
  /// Manufacturer SKU / part number (e.g. "81500", "FGMM65CRD140").
  TextColumn get partNumber => text().nullable()();
  TextColumn get notes => text().nullable()();
  DateTimeColumn get createdAt => dateTime().withDefault(currentDateAndTime)();
}

// ─────────────────────── User data tables ───────────────────────

/// Custom components (powders/bullets/primers/brass/cartridges) the user
/// added themselves. They appear alongside reference items in dropdowns.
@DataClassName('CustomComponentRow')
class CustomComponents extends Table {
  IntColumn get id => integer().autoIncrement()();
  /// 'powder' | 'bullet' | 'primer' | 'brass' | 'cartridge'
  TextColumn get kind => text()();
  TextColumn get name => text()();
  TextColumn get notes => text().nullable()();
  DateTimeColumn get createdAt => dateTime().withDefault(currentDateAndTime)();

  @override
  List<Set<Column>> get uniqueKeys => [
        {kind, name},
      ];
}

// ─────────────────────── Component lots (user, schema v4) ───────────────────────
//
// Lightweight per-lot tracking for consumable components. A "lot" is one
// labeled jug/box/can/case the user has on hand. Recipes can point at a lot
// to remember which physical container produced a particular result.

@DataClassName('PowderLotRow')
class PowderLots extends Table {
  IntColumn get id => integer().autoIncrement()();
  TextColumn get manufacturer => text().nullable()();
  /// Product / model name (e.g. "Varget", "H4350").
  TextColumn get name => text()();
  TextColumn get lotNumber => text().nullable()();
  DateTimeColumn get dateOpened => dateTime().nullable()();
  TextColumn get notes => text().nullable()();
  DateTimeColumn get createdAt => dateTime().withDefault(currentDateAndTime)();
}

@DataClassName('BulletLotRow')
class BulletLots extends Table {
  IntColumn get id => integer().autoIncrement()();
  TextColumn get manufacturer => text().nullable()();
  TextColumn get name => text()();
  TextColumn get lotNumber => text().nullable()();
  DateTimeColumn get dateOpened => dateTime().nullable()();
  TextColumn get notes => text().nullable()();
  DateTimeColumn get createdAt => dateTime().withDefault(currentDateAndTime)();
}

@DataClassName('PrimerLotRow')
class PrimerLots extends Table {
  IntColumn get id => integer().autoIncrement()();
  TextColumn get manufacturer => text().nullable()();
  TextColumn get name => text()();
  TextColumn get lotNumber => text().nullable()();
  DateTimeColumn get dateOpened => dateTime().nullable()();
  TextColumn get notes => text().nullable()();
  DateTimeColumn get createdAt => dateTime().withDefault(currentDateAndTime)();
}

// ─────────────────────── Brass lots (user, schema v4, feature #10) ───────────────────────

@DataClassName('BrassLotRow')
class BrassLots extends Table {
  IntColumn get id => integer().autoIncrement()();
  /// User-facing label (e.g. "Lapua 6.5CM lot A — purchased 2024-08").
  TextColumn get name => text()();
  TextColumn get manufacturer => text().nullable()();
  TextColumn get caliber => text()();
  TextColumn get headstampLot => text().nullable()();
  /// Current count of cases remaining in this lot.
  IntColumn get count => integer()();
  /// How many times the cases in this lot have been fired.
  IntColumn get firingCount => integer().withDefault(const Constant(0))();
  DateTimeColumn get lastAnnealed => dateTime().nullable()();
  /// 'amp' | 'salt-bath' | 'flame'
  TextColumn get annealMethod => text().nullable()();
  RealColumn get avgWeightGr => real().nullable()();
  RealColumn get caseCapacityGrH2o => real().nullable()();
  RealColumn get trimToLengthIn => real().nullable()();
  RealColumn get lastTrimLengthIn => real().nullable()();
  RealColumn get neckWallThicknessIn => real().nullable()();
  BoolColumn get neckTurned => boolean().withDefault(const Constant(false))();
  RealColumn get neckTurnDepthIn => real().nullable()();
  BoolColumn get pocketUniformed => boolean().withDefault(const Constant(false))();
  BoolColumn get flashHoleDeburred => boolean().withDefault(const Constant(false))();
  TextColumn get notes => text().nullable()();
  DateTimeColumn get createdAt => dateTime().withDefault(currentDateAndTime)();
  DateTimeColumn get updatedAt => dateTime().withDefault(currentDateAndTime)();
}

// ─────────────────────── User process steps (schema v4, feature #11) ───────────────────────

@DataClassName('UserProcessStepRow')
class UserProcessSteps extends Table {
  IntColumn get id => integer().autoIncrement()();
  /// Human-readable name (e.g. "Tumble", "Anneal", "Trim", "Crimp").
  TextColumn get name => text()();
  IntColumn get sortOrder => integer()();
  BoolColumn get appliesToPistol => boolean().withDefault(const Constant(true))();
  BoolColumn get appliesToRifle => boolean().withDefault(const Constant(true))();
  BoolColumn get appliesToShotgun => boolean().withDefault(const Constant(false))();
  /// True for the 8 default reloading stages seeded in schema v4. Lets the
  /// UI distinguish "system" steps from steps the user added.
  BoolColumn get isStandard => boolean().withDefault(const Constant(false))();
  TextColumn get description => text().nullable()();
  DateTimeColumn get createdAt => dateTime().withDefault(currentDateAndTime)();
}

@DataClassName('UserLoadRow')
class UserLoads extends Table {
  IntColumn get id => integer().autoIncrement()();
  TextColumn get name => text()();
  TextColumn get caliber => text().nullable()();
  TextColumn get powder => text().nullable()();
  RealColumn get powderChargeGr => real().nullable()();
  TextColumn get bullet => text().nullable()();
  RealColumn get bulletWeightGr => real().nullable()();
  TextColumn get primer => text().nullable()();
  TextColumn get brass => text().nullable()();
  RealColumn get coalIn => real().nullable()();
  RealColumn get cbtoIn => real().nullable()();
  RealColumn get seatingDepthIn => real().nullable()();
  RealColumn get primerDepthCps => real().nullable()();
  RealColumn get shoulderBumpIn => real().nullable()();
  RealColumn get mandrelSizeIn => real().nullable()();
  DateTimeColumn get dateEstablished => dateTime().nullable()();
  TextColumn get notes => text().nullable()();
  DateTimeColumn get createdAt => dateTime().withDefault(currentDateAndTime)();
  DateTimeColumn get updatedAt => dateTime().withDefault(currentDateAndTime)();

  // ── Phase 1 expansion (added schema v4, feature #15) ──
  // All new columns are nullable so existing recipes keep working unchanged.

  // Load identification.
  /// 'active' | 'testing' | 'retired'. Null treated as 'active' by the UI.
  TextColumn get status => text().nullable()();
  /// 'match' | 'practice' | 'hunting' | 'plinking' | free-form
  TextColumn get useCase => text().nullable()();

  // Powder lot detail.
  IntColumn get powderLotId => integer().nullable().references(PowderLots, #id)();
  /// ± grain tolerance / scale resolution used while charging.
  RealColumn get chargeToleranceGr => real().nullable()();

  // Primer detail.
  IntColumn get primerLotId => integer().nullable().references(PrimerLots, #id)();
  RealColumn get primerSeatingForceLbs => real().nullable()();

  // Bullet detail.
  IntColumn get bulletLotId => integer().nullable().references(BulletLots, #id)();
  RealColumn get bulletLengthIn => real().nullable()();
  RealColumn get bulletBaseToOgiveIn => real().nullable()();
  RealColumn get bulletBearingSurfaceIn => real().nullable()();
  BoolColumn get bulletMeplatTrimmed => boolean().withDefault(const Constant(false))();
  BoolColumn get bulletPointed => boolean().withDefault(const Constant(false))();
  BoolColumn get bulletWeightSorted => boolean().withDefault(const Constant(false))();
  RealColumn get bulletWeightToleranceGr => real().nullable()();
  BoolColumn get bulletBtoSorted => boolean().withDefault(const Constant(false))();
  RealColumn get bulletBtoToleranceIn => real().nullable()();
  BoolColumn get bulletDiameterSorted => boolean().withDefault(const Constant(false))();

  // Brass detail (link to a tracked lot; the legacy `brass` text remains for
  // free-form labels).
  IntColumn get brassLotId => integer().nullable().references(BrassLots, #id)();

  // Seating / loaded round.
  RealColumn get distanceToLandsIn => real().nullable()();
  RealColumn get jumpToLandsIn => real().nullable()();
  RealColumn get loadedNeckDiameterIn => real().nullable()();
  RealColumn get bulletRunoutTirIn => real().nullable()();
  RealColumn get bushingSizeIn => real().nullable()();

  // Pressure indicators (qualitative + quantitative).
  TextColumn get pressureNotes => text().nullable()();
  /// 'normal' | 'sticky' (kept as text for forward compatibility).
  TextColumn get boltLift => text().nullable()();
  BoolColumn get ejectorMarks => boolean().withDefault(const Constant(false))();
  BoolColumn get crateredPrimers => boolean().withDefault(const Constant(false))();
  RealColumn get webExpansion200In => real().nullable()();
  /// 1-5 scale (1 = rounded edges, 5 = flat / cratered).
  IntColumn get primerFlatness => integer().nullable()();

  // Process / equipment / provenance.
  DateTimeColumn get loadingDate => dateTime().nullable()();
  IntColumn get roundsLoadedInBatch => integer().nullable()();
  TextColumn get pressUsed => text().nullable()();
  TextColumn get sizingDieUsed => text().nullable()();
  TextColumn get seatingDieUsed => text().nullable()();
  TextColumn get scaleUsed => text().nullable()();
  DateTimeColumn get scaleCalibrationDate => dateTime().nullable()();
  TextColumn get comparatorInsertUsed => text().nullable()();
  TextColumn get chronographUsed => text().nullable()();
  /// 'clean' | 'seasoned' | 'fouled'
  TextColumn get boreState => text().nullable()();
  TextColumn get loadedBy => text().nullable()();

  // ── Ballistic precision (added schema v16) ──
  /// Powder temperature sensitivity, fps per °C. Positive values mean the
  /// load runs faster as the propellant warms. Modern temperature-stable
  /// powders (Hodgdon Extreme, IMR Enduron, Vihtavuori N5xx) report < 0.5
  /// fps/°C; older single-base ball powders can run 1.5–3 fps/°C. Null
  /// means "no temperature sensitivity adjustment" — the solver uses the
  /// load's tabulated MV as-is.
  RealColumn get powderTempSensitivityFpsPerCelsius => real().nullable()();
  /// Reference temperature (°C) the [powderTempSensitivityFpsPerCelsius]
  /// is calibrated against. Defaults to 15.6 °C (60 °F), the SAAMI
  /// reference temperature. The solver computes the runtime MV
  /// adjustment as `(currentTempC - referenceTempC) × sensitivity`.
  RealColumn get powderReferenceTempCelsius =>
      real().withDefault(const Constant(15.6))();
}

@DataClassName('UserFirearmRow')
class UserFirearms extends Table {
  IntColumn get id => integer().autoIncrement()();
  TextColumn get name => text()();
  TextColumn get manufacturer => text().nullable()();
  TextColumn get model => text().nullable()();
  TextColumn get type => text().nullable()();
  TextColumn get action => text().nullable()();
  TextColumn get caliber => text().nullable()();
  RealColumn get barrelLengthIn => real().nullable()();
  TextColumn get twistRate => text().nullable()();
  IntColumn get shotsFired => integer().withDefault(const Constant(0))();
  /// If picked from reference catalog, the FirearmsRef.id; null for custom.
  IntColumn get referenceFirearmId => integer().nullable()();
  TextColumn get notes => text().nullable()();
  DateTimeColumn get createdAt => dateTime().withDefault(currentDateAndTime)();
  DateTimeColumn get updatedAt => dateTime().withDefault(currentDateAndTime)();

  // ── Rifle / barrel detail (added schema v4, feature #15) ──
  TextColumn get barrelManufacturer => text().nullable()();
  /// Free-form text — chamber reamer print number, e.g. PT&G #XYZ.
  TextColumn get chamberReamerPrint => text().nullable()();
  TextColumn get tunerSetting => text().nullable()();
  /// Cached roll-up of UserLoads × test sessions, refreshed on save.
  IntColumn get cumulativeRoundCountSnapshot => integer().nullable()();
  /// Current CBTO-to-touch — drifts as the throat erodes.
  RealColumn get throatErosionCbtoIn => real().nullable()();
  DateTimeColumn get lastThroatMeasurementDate => dateTime().nullable()();

  // ── Ballistics defaults (added schema v6) ──
  /// Last-measured / preferred muzzle velocity for this firearm.
  /// Used by the ballistics calculator's rifle picker to pre-fill MV.
  RealColumn get defaultMuzzleVelocityFps => real().nullable()();
  /// Typical zero range in yards (e.g. 100 or 200).
  IntColumn get defaultZeroRangeYd => integer().nullable()();
  /// Center of optic above bore axis, typically 1.5–2.0 in.
  RealColumn get sightHeightIn => real().nullable()();

  // ── Optic link (added schema v7) ──
  /// Optional link to a row in `Optics` representing the scope mounted on
  /// this firearm. Setting it does NOT auto-populate `sightHeightIn`
  /// because sight height depends on the rings/mount, not the optic.
  IntColumn get opticsId => integer().nullable()();

  // ── Reticle link (added schema v11) ──
  /// Optional link to a row in `Reticles` representing the reticle in
  /// the scope mounted on this firearm. Distinct from `opticsId` because
  /// a single optic model can ship with multiple reticle options and
  /// users sometimes swap reticles after purchase. The firearm form's
  /// reticle picker pre-fills this from the linked optic's
  /// `Optics.reticleId` if one is set.
  IntColumn get reticleId => integer().nullable()();

  // ── Ballistic precision (added schema v16) ──
  /// Direction of the rifling twist as viewed from behind the muzzle.
  /// `'right'` is the dominant US convention; `'left'` flips the sign of
  /// the spin-drift correction in the solver. Defaults to `'right'`.
  TextColumn get twistDirection =>
      text().withDefault(const Constant('right'))();
  /// Vertical sight scale factor — multiplies the elevation hold
  /// reported by the solver. Used when the user has measured a
  /// turret-tracking error (e.g. a scope that dials 0.95 mil for a
  /// commanded 1.00 mil). Defaults to 1.0 (no correction).
  RealColumn get sightScaleVertical =>
      real().withDefault(const Constant(1.0))();
  /// Horizontal sight scale factor — same idea, applied to the windage
  /// hold. Defaults to 1.0.
  RealColumn get sightScaleHorizontal =>
      real().withDefault(const Constant(1.0))();
  /// Atmospheric pressure (inHg) at the time the rifle was zeroed.
  /// When all three zero-atmosphere fields are non-null, the solver
  /// computes the bore-axis-to-line-of-sight offset under the zero
  /// atmosphere and applies it as a constant correction at runtime,
  /// eliminating the "I zeroed at sea level but I'm shooting at
  /// 5000 ft" elevation error. Null falls back to the runtime
  /// atmosphere (legacy behaviour).
  RealColumn get zeroPressureInHg => real().nullable()();
  /// Air temperature (°F) at the time the rifle was zeroed. See
  /// [zeroPressureInHg] for behaviour.
  RealColumn get zeroTemperatureF => real().nullable()();
  /// Relative humidity (%) at the time the rifle was zeroed. See
  /// [zeroPressureInHg] for behaviour.
  RealColumn get zeroHumidityPct => real().nullable()();
}

// ─────────────────────── Batches (user, schema v4, feature #12) ───────────────────────

@DataClassName('BatchRow')
class Batches extends Table {
  IntColumn get id => integer().autoIncrement()();
  TextColumn get name => text()();
  IntColumn get recipeId => integer().nullable().references(UserLoads, #id)();
  IntColumn get brassLotId => integer().nullable().references(BrassLots, #id)();
  IntColumn get firearmId => integer().nullable().references(UserFirearms, #id)();
  /// Total rounds loaded in this batch.
  IntColumn get count => integer()();
  IntColumn get firedCount => integer().withDefault(const Constant(0))();
  DateTimeColumn get loadedAt => dateTime().nullable()();
  /// JSON map of step name → bool (e.g. {"tumble":true,"trim":false,...}).
  /// Lets the UI render the user-defined process checklist for this batch.
  TextColumn get processStateJson => text().withDefault(const Constant('{}'))();
  TextColumn get notes => text().nullable()();
  DateTimeColumn get createdAt => dateTime().withDefault(currentDateAndTime)();
  DateTimeColumn get updatedAt => dateTime().withDefault(currentDateAndTime)();
}

// ─────────────────────── Test sessions (user, schema v4) ───────────────────────
//
// One row per range trip / firing event. Separating session-level metrics
// (velocity statistics, group sizes, environmentals) from the recipe lets
// the user track how a single recipe performs across many shoots.

@DataClassName('TestSessionRow')
class TestSessions extends Table {
  IntColumn get id => integer().autoIncrement()();
  IntColumn get recipeId => integer().nullable().references(UserLoads, #id)();
  IntColumn get firearmId => integer().nullable().references(UserFirearms, #id)();
  IntColumn get batchId => integer().nullable().references(Batches, #id)();
  TextColumn get name => text().nullable()();
  DateTimeColumn get sessionDate => dateTime()();
  IntColumn get sampleSize => integer().nullable()();

  // Velocity statistics.
  RealColumn get velocityAvgFps => real().nullable()();
  RealColumn get velocityMedianFps => real().nullable()();
  RealColumn get velocityHighFps => real().nullable()();
  RealColumn get velocityLowFps => real().nullable()();
  RealColumn get velocityEsFps => real().nullable()();
  RealColumn get velocitySdFps => real().nullable()();
  RealColumn get velocityCvPct => real().nullable()();
  RealColumn get velocitySdCi95Fps => real().nullable()();
  RealColumn get coldBoreOffsetFps => real().nullable()();
  RealColumn get velocityDriftSlope => real().nullable()();

  // Accuracy.
  IntColumn get distanceYd => integer().nullable()();
  RealColumn get groupSizeMoa => real().nullable()();
  RealColumn get verticalDispersionMoa => real().nullable()();
  RealColumn get horizontalDispersionMoa => real().nullable()();
  RealColumn get meanRadiusMoa => real().nullable()();

  // Environmentals.
  RealColumn get temperatureF => real().nullable()();
  RealColumn get densityAltitudeFt => real().nullable()();
  RealColumn get barometricStationInHg => real().nullable()();
  RealColumn get humidityPct => real().nullable()();
  RealColumn get windSpeedMph => real().nullable()();
  RealColumn get windDirectionDeg => real().nullable()();
  RealColumn get rangeElevationFt => real().nullable()();

  TextColumn get notes => text().nullable()();
  DateTimeColumn get createdAt => dateTime().withDefault(currentDateAndTime)();
}

// ─────────────────────── Load development sessions (schema v5, feature #16) ───────────────────────
//
// A "load development session" is a structured experiment for finding the
// best charge weight (charge ladder) or seating depth (seating ladder) for
// a given combination of cartridge + components + firearm. The experiment
// fixes everything except one variable, generates N rung recipes at evenly
// spaced values, and (after firing) collects per-rung chrono / accuracy
// data so the user can pick a "node" (charge weight or CBTO that
// minimizes the variable being optimized).

@DataClassName('LoadDevelopmentSessionRow')
class LoadDevelopmentSessions extends Table {
  IntColumn get id => integer().autoIncrement()();
  TextColumn get name => text()();
  /// 'charge_ladder' | 'seating_ladder'
  TextColumn get sessionType => text()();
  TextColumn get cartridge => text().nullable()();
  IntColumn get firearmId => integer().nullable().references(UserFirearms, #id)();
  /// Source recipe (only for seating ladders, where charge is already locked)
  IntColumn get sourceRecipeId => integer().nullable().references(UserLoads, #id)();
  TextColumn get powder => text().nullable()();
  TextColumn get bullet => text().nullable()();
  TextColumn get primer => text().nullable()();
  IntColumn get brassLotId => integer().nullable().references(BrassLots, #id)();
  RealColumn get startValue => real()();
  RealColumn get endValue => real()();
  RealColumn get stepValue => real()();
  IntColumn get rungCount => integer()();
  /// User-selected "node" once analysis completes
  RealColumn get nodeValue => real().nullable()();
  /// JSON: per-rung data (chrono / accuracy / pressure notes)
  TextColumn get rungsJson => text().withDefault(const Constant('[]'))();
  TextColumn get notes => text().nullable()();
  DateTimeColumn get createdAt => dateTime().withDefault(currentDateAndTime)();
  DateTimeColumn get updatedAt => dateTime().withDefault(currentDateAndTime)();
}

// ─────────────────────── Range Day (schema v10) ───────────────────────
//
// The Range Day workspace is a tool the user opens *at* the range. It pulls
// together a target, a distance, a ballistic profile (or load+firearm), and
// current environmental conditions, runs the ballistics solver, and lets
// the shooter record where their actual shots landed on the chosen target.
//
// Three tables make this work:
//
//   * `Targets` — the reference catalog of targets the user can shoot at,
//     seeded from `assets/seed_data/targets.json`. Read-only at runtime.
//   * `RangeDaySessions` — one row per range trip, holding the session-level
//     setup (target picked, distance, environment defaults, links to the
//     active ballistic profile / load / firearm).
//   * `ShotImpacts` — one row per shot fired during a session, with the
//     impact location stored as normalized (-1..1, -1..1) coordinates on
//     the chosen target (so the same row works regardless of how the
//     target is rendered on screen — paper plate or 24-inch steel).

/// Reference catalog of common targets a shooter might use. Seeded from
/// `assets/seed_data/targets.json`. Read-only at runtime.
@DataClassName('TargetRow')
class Targets extends Table {
  IntColumn get id => integer().autoIncrement()();
  TextColumn get name => text()();
  /// Manufacturer / brand. Nullable for generic targets ("8 in AR500
  /// plate") that are not specific to one maker.
  TextColumn get manufacturer => text().nullable()();
  /// 'paper' | 'steel' | 'reactive' | 'game-silhouette'
  TextColumn get category => text()();
  /// 'circle' | 'square' | 'rectangle' | 'silhouette' | 'irregular'
  TextColumn get shape => text()();
  /// Outer-bound width of the target in inches (the visible / scoreable
  /// area). For circles this equals heightIn.
  RealColumn get widthIn => real()();
  /// Outer-bound height of the target in inches.
  RealColumn get heightIn => real()();
  /// 'paper' | 'cardboard' | 'steel-ar500' | 'steel-ar550' | 'polymer' |
  /// 'game-3d'.
  TextColumn get materialKind => text()();
  /// CSS-style hex color (e.g. "#fff8c4"). Used by the visual target
  /// renderer so the on-screen plot resembles the real target.
  TextColumn get colorHex => text()();
  TextColumn get notes => text().nullable()();
  DateTimeColumn get createdAt => dateTime().withDefault(currentDateAndTime)();
}

/// One row per range-day workspace the user opened. The session is a
/// container for the setup (target / distance / profile / load / firearm
/// / environment) plus the shot-impact rows that hang off it.
@DataClassName('RangeDaySessionRow')
class RangeDaySessions extends Table {
  IntColumn get id => integer().autoIncrement()();
  /// User-facing label (defaults to `<MMM d>` followed by the distance).
  TextColumn get name => text()();
  DateTimeColumn get date => dateTime()();
  TextColumn get notes => text().nullable()();
  /// Optional FK to the active ballistic profile.
  IntColumn get ballisticProfileId => integer().nullable()();
  /// Optional FK to a saved recipe (UserLoads.id) being shot today.
  IntColumn get recipeId => integer().nullable()();
  /// Optional FK to the user's firearm (UserFirearms.id) being shot today.
  IntColumn get firearmId => integer().nullable()();
  /// Optional FK to the chosen target (Targets.id).
  IntColumn get targetId => integer().nullable()();
  /// Distance to target, yards.
  RealColumn get distanceYd => real()();
  // Environment defaults — same shape as BallisticProfiles env fields so
  // the solver gets identical inputs whether driven from a profile or a
  // session.
  RealColumn get temperatureF => real().nullable()();
  RealColumn get pressureInHg => real().nullable()();
  RealColumn get humidityPct => real().nullable()();
  RealColumn get elevationFt => real().nullable()();
  RealColumn get windSpeedMph => real().nullable()();
  RealColumn get windDirectionDeg => real().nullable()();
  DateTimeColumn get createdAt => dateTime().withDefault(currentDateAndTime)();
  DateTimeColumn get updatedAt => dateTime().withDefault(currentDateAndTime)();

  // ── Hit-probability + reticle aim (added v11) ──
  /// Aim point on the target, normalized to [-1, 1] across the target
  /// width. Null means the shooter hasn't placed an aim point yet
  /// (default behaviour treats that as dead center, 0,0).
  RealColumn get aimPointX => real().nullable()();
  /// Aim point on the target, normalized to [-1, 1] across the target
  /// height (+1 = top, -1 = bottom).
  RealColumn get aimPointY => real().nullable()();
  /// User's known group capability at 100 yd, in MOA. Drives the
  /// dispersion model in [HitProbabilityService]. Default 1.0 MOA — a
  /// modest hunting-rifle baseline.
  RealColumn get assumedGroupMoa => real().nullable()();
  /// How confident the shooter is in their wind call. ±mph treated as
  /// a 2-sigma window. Default 2.0.
  RealColumn get windUncertaintyMph => real().nullable()();
  /// How confident the shooter is in their range estimate. ±yd as a
  /// 2-sigma window. Default 5.0.
  RealColumn get rangeUncertaintyYd => real().nullable()();
  /// Optional FK to the `Reticles` row to render on the target plot.
  IntColumn get reticleId => integer().nullable()();
  /// Per-session preference for the post-shot correction display.
  /// 'mil' | 'moa' | 'inches'. Defaults to the app-wide angle unit.
  TextColumn get correctionUnit =>
      text().withDefault(const Constant('mil'))();

  // ── Captured sensor readings (added v13) ──
  /// Captured cant (rifle level) at session-setup time, in degrees.
  /// Positive = rifle canted right relative to the calibrated zero.
  /// Persisted only when the user taps "Capture current readings" in
  /// the Sensors panel; null if the capture button was never used. The
  /// solver consumes the *live* `CantService.cantDegrees`, so this
  /// column is purely a record of the conditions at the time of
  /// capture, useful for after-the-fact review of a session.
  RealColumn get cantDegrees => real().nullable()();
  /// Captured shot azimuth (compass heading) at session-setup time, in
  /// degrees. 0 = N, 90 = E, 180 = S, 270 = W. Mirrors the value typed
  /// into / read from the Shot Azimuth field — captured here so it's
  /// preserved next to the cant for archival purposes even if the
  /// shooter later edits the field.
  RealColumn get shotAzimuthDegrees => real().nullable()();

  // ── Ballistic precision (added schema v15) ──
  /// Incline / decline angle of the shot, in degrees. Positive = uphill,
  /// negative = downhill. The solver applies the improved-rifleman's
  /// rule (drop scaled by `cos(angle)^1.5`) when this field is non-null.
  /// Null means "level shot" — no correction.
  RealColumn get inclineAngleDeg => real().nullable()();
}

/// One row per shot recorded during a range-day session. Impact coordinates
/// are stored normalized to [-1, 1] on each axis so the same row renders
/// correctly on any size of target widget. (-1, -1) is bottom-left, (0, 0)
/// is dead center, (1, 1) is top-right.
@DataClassName('ShotImpactRow')
class ShotImpacts extends Table {
  IntColumn get id => integer().autoIncrement()();
  IntColumn get rangeDaySessionId =>
      integer().references(RangeDaySessions, #id)();
  /// 1-based shot number in the session.
  IntColumn get shotNumber => integer()();
  /// Normalized horizontal position on the target ([-1, 1]; -1 = left
  /// edge, +1 = right edge). Persists independent of the target's
  /// physical dimensions so different targets can share the same impact
  /// math at render time.
  RealColumn get impactX => real()();
  /// Normalized vertical position on the target ([-1, 1]; -1 = bottom
  /// edge, +1 = top edge).
  RealColumn get impactY => real()();
  TextColumn get notes => text().nullable()();
  RealColumn get velocityFps => real().nullable()();
  DateTimeColumn get recordedAt =>
      dateTime().withDefault(currentDateAndTime)();
}

// ─────────────────────── Custom user-defined fields (schema v4) ───────────────────────

@DataClassName('UserCustomFieldRow')
class UserCustomFields extends Table {
  IntColumn get id => integer().autoIncrement()();
  /// 'recipe' | 'firearm' | 'batch' | 'brass-lot'
  TextColumn get entityType => text()();
  TextColumn get fieldName => text()();
  /// 'text' | 'number' | 'boolean' | 'date'
  TextColumn get fieldType => text()();
  /// Optional unit/suffix shown next to the value (e.g. "gr", "fps").
  TextColumn get unitSuffix => text().nullable()();
  IntColumn get sortOrder => integer().withDefault(const Constant(0))();
  DateTimeColumn get createdAt => dateTime().withDefault(currentDateAndTime)();

  @override
  List<Set<Column>> get uniqueKeys => [
        {entityType, fieldName},
      ];
}

@DataClassName('UserCustomFieldValueRow')
class UserCustomFieldValues extends Table {
  IntColumn get id => integer().autoIncrement()();
  IntColumn get fieldId => integer().references(UserCustomFields, #id)();
  /// Row id in the entity's table (UserLoads.id, UserFirearms.id, etc.).
  IntColumn get entityId => integer()();
  /// Stored as text; UI casts based on the FieldDef's fieldType.
  TextColumn get value => text().nullable()();
  DateTimeColumn get updatedAt => dateTime().withDefault(currentDateAndTime)();

  @override
  List<Set<Column>> get uniqueKeys => [
        {fieldId, entityId},
      ];
}

// ─────────────────────── Database ───────────────────────

@DriftDatabase(
  tables: [
    Manufacturers,
    Cartridges,
    Powders,
    Bullets,
    Primers,
    BrassProducts,
    FirearmsRef,
    FirearmParts,
    CustomComponents,
    UserLoads,
    UserFirearms,
    // Schema v4 additions.
    PowderLots,
    BulletLots,
    PrimerLots,
    BrassLots,
    UserProcessSteps,
    Batches,
    TestSessions,
    UserCustomFields,
    UserCustomFieldValues,
    // Schema v5 additions.
    LoadDevelopmentSessions,
    // Schema v7 additions.
    Optics,
    // Schema v8 additions.
    BallisticProfiles,
    // Schema v10 additions.
    Targets,
    RangeDaySessions,
    ShotImpacts,
    // Schema v11 additions.
    Reticles,
    // Schema v12 additions.
    DragCurves,
    // Schema v14 additions.
    FactoryLoads,
  ],
)
class AppDatabase extends _$AppDatabase {
  AppDatabase() : super(_open());

  AppDatabase.forTesting(super.e);

  @override
  int get schemaVersion => 15;

  @override
  MigrationStrategy get migration => MigrationStrategy(
        onCreate: (m) async {
          await m.createAll();
          // Fresh installs get the standard reloading workflow seeded so the
          // batch-checklist UI has something to show out of the box.
          await _seedStandardProcessSteps();
        },
        onUpgrade: (m, from, to) async {
          if (from < 2) {
            // v2 added extended SAAMI/CIP fields to Cartridges. Existing rows
            // keep their data; new columns start null until the next re-seed.
            await m.addColumn(cartridges, cartridges.bodyDiameterIn);
            await m.addColumn(cartridges, cartridges.shoulderDiameterIn);
            await m.addColumn(cartridges, cartridges.shoulderAngleDeg);
            await m.addColumn(cartridges, cartridges.neckDiameterIn);
            await m.addColumn(cartridges, cartridges.neckLengthIn);
            await m.addColumn(cartridges, cartridges.baseToShoulderIn);
            await m.addColumn(cartridges, cartridges.baseToNeckIn);
            await m.addColumn(cartridges, cartridges.rimDiameterIn);
            await m.addColumn(cartridges, cartridges.rimThicknessIn);
            await m.addColumn(cartridges, cartridges.primerType);
            await m.addColumn(cartridges, cartridges.twistRate);
            await m.addColumn(cartridges, cartridges.maxAvgPressurePsi);
            await m.addColumn(cartridges, cartridges.boreDiameterIn);
            await m.addColumn(cartridges, cartridges.grooveDiameterIn);
            await m.addColumn(cartridges, cartridges.caseSubtype);
            await m.addColumn(cartridges, cartridges.saamiDoc);
          }
          if (from < 3) {
            // v3 added Primers.productLine — manufacturer marketing names
            // shown alongside the model number in the cascading primer
            // dropdown.
            await m.addColumn(primers, primers.productLine);
            // Wipe the primer catalog (and its manufacturer rows) so that
            // next launch's `seedIfNeeded` re-runs the primer seed and
            // populates the new productLine column. User data
            // (custom_components, user_loads, user_firearms) is untouched.
            // Note: cartridges is the canary `seedIfNeeded` checks, so we
            // don't need to nuke cartridges to retrigger; we explicitly
            // re-seed primers ourselves below at first opportunity.
            await delete(primers).go();
            await (delete(manufacturers)..where((m) => m.kind.equals('primer')))
                .go();
          }
          if (from < 4) {
            // v4 — recipe expansion (#15), brass lots (#10), custom process
            // steps (#11), batches (#12), test sessions, component lots, and
            // custom fields. All additive; user data is preserved.

            // 1. Create the new tables.
            await m.createTable(powderLots);
            await m.createTable(bulletLots);
            await m.createTable(primerLots);
            await m.createTable(brassLots);
            await m.createTable(userProcessSteps);
            await m.createTable(batches);
            await m.createTable(testSessions);
            await m.createTable(userCustomFields);
            await m.createTable(userCustomFieldValues);

            // 2. Extend UserLoads with the Phase 1 recipe-expansion columns.
            await m.addColumn(userLoads, userLoads.status);
            await m.addColumn(userLoads, userLoads.useCase);
            await m.addColumn(userLoads, userLoads.powderLotId);
            await m.addColumn(userLoads, userLoads.chargeToleranceGr);
            await m.addColumn(userLoads, userLoads.primerLotId);
            await m.addColumn(userLoads, userLoads.primerSeatingForceLbs);
            await m.addColumn(userLoads, userLoads.bulletLotId);
            await m.addColumn(userLoads, userLoads.bulletLengthIn);
            await m.addColumn(userLoads, userLoads.bulletBaseToOgiveIn);
            await m.addColumn(userLoads, userLoads.bulletBearingSurfaceIn);
            await m.addColumn(userLoads, userLoads.bulletMeplatTrimmed);
            await m.addColumn(userLoads, userLoads.bulletPointed);
            await m.addColumn(userLoads, userLoads.bulletWeightSorted);
            await m.addColumn(userLoads, userLoads.bulletWeightToleranceGr);
            await m.addColumn(userLoads, userLoads.bulletBtoSorted);
            await m.addColumn(userLoads, userLoads.bulletBtoToleranceIn);
            await m.addColumn(userLoads, userLoads.bulletDiameterSorted);
            await m.addColumn(userLoads, userLoads.brassLotId);
            await m.addColumn(userLoads, userLoads.distanceToLandsIn);
            await m.addColumn(userLoads, userLoads.jumpToLandsIn);
            await m.addColumn(userLoads, userLoads.loadedNeckDiameterIn);
            await m.addColumn(userLoads, userLoads.bulletRunoutTirIn);
            await m.addColumn(userLoads, userLoads.bushingSizeIn);
            await m.addColumn(userLoads, userLoads.pressureNotes);
            await m.addColumn(userLoads, userLoads.boltLift);
            await m.addColumn(userLoads, userLoads.ejectorMarks);
            await m.addColumn(userLoads, userLoads.crateredPrimers);
            await m.addColumn(userLoads, userLoads.webExpansion200In);
            await m.addColumn(userLoads, userLoads.primerFlatness);
            await m.addColumn(userLoads, userLoads.loadingDate);
            await m.addColumn(userLoads, userLoads.roundsLoadedInBatch);
            await m.addColumn(userLoads, userLoads.pressUsed);
            await m.addColumn(userLoads, userLoads.sizingDieUsed);
            await m.addColumn(userLoads, userLoads.seatingDieUsed);
            await m.addColumn(userLoads, userLoads.scaleUsed);
            await m.addColumn(userLoads, userLoads.scaleCalibrationDate);
            await m.addColumn(userLoads, userLoads.comparatorInsertUsed);
            await m.addColumn(userLoads, userLoads.chronographUsed);
            await m.addColumn(userLoads, userLoads.boreState);
            await m.addColumn(userLoads, userLoads.loadedBy);

            // 3. Extend UserFirearms with the rifle/barrel detail columns.
            await m.addColumn(userFirearms, userFirearms.barrelManufacturer);
            await m.addColumn(userFirearms, userFirearms.chamberReamerPrint);
            await m.addColumn(userFirearms, userFirearms.tunerSetting);
            await m.addColumn(
                userFirearms, userFirearms.cumulativeRoundCountSnapshot);
            await m.addColumn(userFirearms, userFirearms.throatErosionCbtoIn);
            await m.addColumn(
                userFirearms, userFirearms.lastThroatMeasurementDate);

            // 4. Seed the standard reloading workflow steps so existing
            //    installs get the same out-of-box checklist as fresh ones.
            await _seedStandardProcessSteps();
          }
          if (from < 5) {
            // v5 — Load Development sessions (feature #16). Adds a single
            // table for grouping a series of charge-weight or seating-depth
            // ladder recipes into one experiment.
            await m.createTable(loadDevelopmentSessions);
          }
          if (from < 6) {
            // v6 — Ballistics defaults on UserFirearms. Three nullable
            // columns let the user save per-firearm muzzle velocity, zero
            // range, and sight height so the ballistics calculator's
            // rifle picker can pre-fill those fields.
            await m.addColumn(
                userFirearms, userFirearms.defaultMuzzleVelocityFps);
            await m.addColumn(userFirearms, userFirearms.defaultZeroRangeYd);
            await m.addColumn(userFirearms, userFirearms.sightHeightIn);
          }
          if (from < 7) {
            // v7 — Optics catalog + per-firearm opticsId link. Adds the
            // `Optics` reference table (seeded from optics.json) and a
            // nullable `opticsId` column on UserFirearms so a user can
            // record which scope/red-dot is mounted on each rifle. Sight
            // height stays a per-firearm field because it depends on the
            // rings/mount the user picks, not the optic itself.
            await m.createTable(optics);
            await m.addColumn(userFirearms, userFirearms.opticsId);
          }
          if (from < 8) {
            // v8 — BallisticProfiles. A purely additive table that lets
            // the user save named bundles of ballistics-calculator
            // inputs (projectile, MV/zero, environment, output prefs)
            // and switch between them. No existing column changes.
            await m.createTable(ballisticProfiles);
          }
          if (from < 9) {
            // v9 — `barrelLengthIn` and `twistRate` columns on FirearmsRef
            // so the firearm form can auto-fill those fields when the user
            // picks a model from the catalog. Wipe the firearms reference
            // catalog (and its manufacturer rows) so next launch's
            // `seedIfNeeded` re-runs the firearm seed and populates the
            // new columns from JSON. UserFirearms (the user's saved guns)
            // is untouched.
            await m.addColumn(firearmsRef, firearmsRef.barrelLengthIn);
            await m.addColumn(firearmsRef, firearmsRef.twistRate);
            await delete(firearmsRef).go();
            await (delete(manufacturers)..where((m) => m.kind.equals('firearm')))
                .go();
          }
          if (from < 10) {
            // v10 — Range Day workspace. Adds three purely additive tables:
            // `Targets` (reference catalog seeded from targets.json),
            // `RangeDaySessions` (per-session setup + environment), and
            // `ShotImpacts` (per-shot impact records). No existing column
            // changes; user data preserved.
            await m.createTable(targets);
            await m.createTable(rangeDaySessions);
            await m.createTable(shotImpacts);
          }
          if (from < 11) {
            // v11 — Reticle library + hit-probability inputs on Range Day
            // sessions. Shared bump with the parallel reticle agent.
            // Additive only:
            //   * Creates the `Reticles` reference table.
            //   * Adds `reticleId` to `Optics` (default reticle for the
            //     scope) and `UserFirearms` (the user's actual reticle).
            //   * Adds 7 nullable columns + a default-text column on
            //     `RangeDaySessions` for aim point, dispersion inputs,
            //     selected reticle, and correction-unit preference.
            await m.createTable(reticles);
            await m.addColumn(optics, optics.reticleId);
            await m.addColumn(userFirearms, userFirearms.reticleId);
            await m.addColumn(rangeDaySessions, rangeDaySessions.aimPointX);
            await m.addColumn(rangeDaySessions, rangeDaySessions.aimPointY);
            await m.addColumn(
                rangeDaySessions, rangeDaySessions.assumedGroupMoa);
            await m.addColumn(
                rangeDaySessions, rangeDaySessions.windUncertaintyMph);
            await m.addColumn(
                rangeDaySessions, rangeDaySessions.rangeUncertaintyYd);
            await m.addColumn(rangeDaySessions, rangeDaySessions.reticleId);
            await m.addColumn(
                rangeDaySessions, rangeDaySessions.correctionUnit);
          }
          if (from < 12) {
            // v12 — Custom drag curves catalog. Adds the `DragCurves`
            // reference table (seeded from
            // `assets/seed_data/drag_curves/*.json`) so the ballistics
            // calculator can use per-bullet Doppler-radar drag curves
            // (Berger CDM, Hornady DSF / 4DOF) instead of the standard
            // G1/G2/G5/G6/G7/G8 curve + BC fit. Additive only — no
            // existing column or table changes; user data is preserved.
            await m.createTable(dragCurves);
          }
          if (from < 13) {
            // v13 — Captured cant + shot-azimuth on RangeDaySessions.
            // Two nullable REAL columns added so the user can tap
            // "Capture current readings" in the Sensors panel and have
            // the live cant + heading frozen onto the session row for
            // after-the-fact review. The solver still consumes the
            // *live* CantService for cant correction; these columns are
            // archival. Additive only — no existing column or table
            // changes; user data is preserved.
            await m.addColumn(
                rangeDaySessions, rangeDaySessions.cantDegrees);
            await m.addColumn(
                rangeDaySessions, rangeDaySessions.shotAzimuthDegrees);
          }
          if (from < 14) {
            // v14 — Factory ammunition catalog. Adds the `FactoryLoads`
            // reference table (seeded from
            // `assets/seed_data/factory_loads.json`) so the ballistics
            // calculator and Range Day workspace can offer a "Factory
            // Ammo" picker that surfaces published cartridge SKUs with
            // factory MV + BC. Distinct from the reloading-component
            // `Bullets` catalog — factory loads are full cartridges
            // (not handload components) and are intentionally NOT
            // surfaced in the recipe form. Additive only.
            await m.createTable(factoryLoads);
          }
          if (from < 15) {
            // v15 — Ballistic-precision inputs. Nine purely additive
            // columns spread across three existing tables so the solver
            // can model effects it previously ignored. Every new column
            // either (a) is nullable and treated as "no effect" by the
            // solver, or (b) carries a default value that reproduces the
            // legacy behaviour for existing rows. As a result, every
            // pre-v15 recipe / firearm / range-day session continues to
            // produce identical trajectories until the user opts into
            // one of the new fields.
            //
            // UserLoads:
            //   * `powderTempSensitivityFpsPerCelsius` — fps/°C velocity
            //     drift; nullable so a load without a measured value
            //     skips the temperature adjustment entirely.
            //   * `powderReferenceTempCelsius` — calibration temperature
            //     for the sensitivity, defaulting to 15.6 °C
            //     (60 °F, the SAAMI reference).
            //
            // UserFirearms:
            //   * `twistDirection` — `'right' | 'left'`; defaults to
            //     `'right'` so existing firearms behave unchanged.
            //   * `sightScaleVertical` / `sightScaleHorizontal` —
            //     multiplicative scope-tracking corrections, default 1.0.
            //   * `zeroPressureInHg` / `zeroTemperatureF` /
            //     `zeroHumidityPct` — atmospheric snapshot at zeroing
            //     time. Nullable; the solver falls back to the runtime
            //     atmosphere when any of the three is missing.
            //
            // RangeDaySessions:
            //   * `inclineAngleDeg` — uphill/downhill shot angle.
            //     Nullable; the solver skips the rifleman's-rule
            //     correction when null.
            await m.addColumn(
                userLoads, userLoads.powderTempSensitivityFpsPerCelsius);
            await m.addColumn(
                userLoads, userLoads.powderReferenceTempCelsius);
            await m.addColumn(userFirearms, userFirearms.twistDirection);
            await m.addColumn(
                userFirearms, userFirearms.sightScaleVertical);
            await m.addColumn(
                userFirearms, userFirearms.sightScaleHorizontal);
            await m.addColumn(userFirearms, userFirearms.zeroPressureInHg);
            await m.addColumn(userFirearms, userFirearms.zeroTemperatureF);
            await m.addColumn(userFirearms, userFirearms.zeroHumidityPct);
            await m.addColumn(
                rangeDaySessions, rangeDaySessions.inclineAngleDeg);
          }
        },
      );

  /// Inserts the 8 standard reloading stages into [userProcessSteps]. Used
  /// from both `onCreate` (fresh install) and the v4 `onUpgrade` path so
  /// every install ends up with the same default workflow.
  Future<void> _seedStandardProcessSteps() async {
    final defaults = <UserProcessStepsCompanion>[
      UserProcessStepsCompanion.insert(
        name: 'Inspect & Sort Brass',
        sortOrder: 1,
        isStandard: const Value(true),
        appliesToShotgun: const Value(true),
        description: const Value(
          'Check each case for damage, then group by headstamp and lot before '
          'starting case prep.',
        ),
      ),
      UserProcessStepsCompanion.insert(
        name: 'Resize / Decap',
        sortOrder: 2,
        isStandard: const Value(true),
        description: const Value(
          'Return fired brass toward chamber-ready dimensions and remove the '
          'spent primer.',
        ),
      ),
      UserProcessStepsCompanion.insert(
        name: 'Trim, Chamfer, Deburr',
        sortOrder: 3,
        isStandard: const Value(true),
        description: const Value(
          'Bring case length back into spec, then bevel the inside and outside '
          'of the case mouth.',
        ),
      ),
      UserProcessStepsCompanion.insert(
        name: 'Anneal',
        sortOrder: 4,
        isStandard: const Value(true),
        description: const Value(
          'Optionally relieve work-hardening in the case neck and shoulder to '
          'extend brass life and stabilize neck tension.',
        ),
      ),
      UserProcessStepsCompanion.insert(
        name: 'Prime',
        sortOrder: 5,
        isStandard: const Value(true),
        description: const Value(
          'Seat a fresh primer into a clean, prepared primer pocket.',
        ),
      ),
      UserProcessStepsCompanion.insert(
        name: 'Charge with Powder',
        sortOrder: 6,
        isStandard: const Value(true),
        description: const Value(
          'Drop a verified, weighed powder charge into each primed case.',
        ),
      ),
      UserProcessStepsCompanion.insert(
        name: 'Seat Bullet',
        sortOrder: 7,
        isStandard: const Value(true),
        description: const Value(
          'Press a bullet into the charged case to a consistent depth specified '
          'by your recipe.',
        ),
      ),
      UserProcessStepsCompanion.insert(
        name: 'Final Inspection / Crimp',
        sortOrder: 8,
        isStandard: const Value(true),
        description: const Value(
          'Optionally crimp the case mouth, then verify the finished round '
          'against a gauge or chamber.',
        ),
      ),
    ];
    await batch((b) => b.insertAll(userProcessSteps, defaults));
  }

  /// Drop every row in every user-data table. The reference catalog
  /// (Cartridges, Powders, Bullets, Primers, BrassProducts, FirearmsRef,
  /// FirearmParts, Optics, Manufacturers) is left untouched — the user
  /// keeps the seeded dropdown content. The standard reloading process
  /// steps are re-inserted at the end so the batch checklist UI still
  /// has something to render after the wipe.
  ///
  /// Used by Settings → "Delete my data". Caller is expected to also
  /// sign the user out of Firebase Auth and pop back to the home shell;
  /// this method only handles SQLite.
  Future<void> wipeUserData() async {
    await transaction(() async {
      // Children first (foreign-key safety even though we don't enforce
      // FK constraints in drift). Order chosen to mirror typical
      // dependency direction.
      await delete(shotImpacts).go();
      await delete(rangeDaySessions).go();
      await delete(userCustomFieldValues).go();
      await delete(userCustomFields).go();
      await delete(loadDevelopmentSessions).go();
      await delete(testSessions).go();
      await delete(batches).go();
      await delete(brassLots).go();
      await delete(primerLots).go();
      await delete(bulletLots).go();
      await delete(powderLots).go();
      await delete(userFirearms).go();
      await delete(userLoads).go();
      await delete(customComponents).go();
      await delete(ballisticProfiles).go();
      await delete(userProcessSteps).go();
      await _seedStandardProcessSteps();
    });
  }

  static QueryExecutor _open() {
    if (kIsWeb) {
      // Web: drift uses a sqlite3 WASM build + a web worker, both served
      // alongside the Flutter assets in `web/`. The actual storage backend
      // (OPFS / IndexedDB / in-memory fallback) is selected by drift at
      // runtime based on what the browser supports.
      //
      // Files expected in the deployed `web/` directory (see CLAUDE.md →
      // Web platform):
      //   - sqlite3.wasm           (downloaded from
      //     https://github.com/simolus3/sqlite3.dart/releases)
      //   - drift_worker.dart.js   (built with
      //     `dart compile js -O2 -o web/drift_worker.dart.js web/drift_worker.dart`)
      //
      // If either file is missing the database open will fail and the app
      // crashes on launch — the build script in CLAUDE.md re-emits both
      // every time `flutter build web` is invoked.
      return driftDatabase(
        name: 'loadout',
        web: DriftWebOptions(
          sqlite3Wasm: Uri.parse('sqlite3.wasm'),
          driftWorker: Uri.parse('drift_worker.dart.js'),
        ),
      );
    }
    return driftDatabase(
      name: 'loadout',
      native: const DriftNativeOptions(
        databaseDirectory: getApplicationSupportDirectory,
      ),
    );
  }

  /// True if the reference tables are empty (i.e. first run).
  Future<bool> get needsSeed async {
    final count = await (selectOnly(cartridges)..addColumns([cartridges.id.count()]))
        .map((row) => row.read(cartridges.id.count()) ?? 0)
        .getSingle();
    return count == 0;
  }

  /// True when the primer catalog is empty. Used by the v3 migration path
  /// to re-seed primers (which gain the `productLine` column) without
  /// touching the rest of the DB.
  Future<bool> get primersAreEmpty async {
    final count = await (selectOnly(primers)..addColumns([primers.id.count()]))
        .map((row) => row.read(primers.id.count()) ?? 0)
        .getSingle();
    return count == 0;
  }

  /// True when an existing install is missing the v2 SAAMI/CIP dimension
  /// fields (added in schema v2). The migration adds the columns but does
  /// not re-seed; this getter detects that staleness by spot-checking a
  /// known cartridge (9mm Luger) for a populated body diameter — if a
  /// well-known seed value is null, the v2 data needs to be re-seeded.
  Future<bool> get cartridgesNeedReseed async {
    final row = await (select(cartridges)
          ..where((c) => c.name.equals('9mm Luger'))
          ..limit(1))
        .getSingleOrNull();
    if (row == null) return false; // empty DB; needsSeed handles that path
    return row.bodyDiameterIn == null;
  }

  // ── Per-table emptiness getters (used by SeedLoader on first run /
  //    after a SeedUpdater download). Each one mirrors `primersAreEmpty`
  //    above — small but explicit, so we don't need a generic helper that
  //    has to fight Dart's type system over `selectOnly(...)` inputs. ──

  /// True when the powders catalog is empty.
  Future<bool> get powdersAreEmpty async {
    final count = await (selectOnly(powders)..addColumns([powders.id.count()]))
        .map((row) => row.read(powders.id.count()) ?? 0)
        .getSingle();
    return count == 0;
  }

  /// True when the bullets catalog is empty.
  Future<bool> get bulletsAreEmpty async {
    final count = await (selectOnly(bullets)..addColumns([bullets.id.count()]))
        .map((row) => row.read(bullets.id.count()) ?? 0)
        .getSingle();
    return count == 0;
  }

  /// True when the brass-products catalog is empty.
  Future<bool> get brassProductsAreEmpty async {
    final count = await (selectOnly(brassProducts)
          ..addColumns([brassProducts.id.count()]))
        .map((row) => row.read(brassProducts.id.count()) ?? 0)
        .getSingle();
    return count == 0;
  }

  /// True when the firearms reference catalog is empty.
  Future<bool> get firearmsRefAreEmpty async {
    final count = await (selectOnly(firearmsRef)
          ..addColumns([firearmsRef.id.count()]))
        .map((row) => row.read(firearmsRef.id.count()) ?? 0)
        .getSingle();
    return count == 0;
  }

  /// True when the aftermarket-parts catalog is empty.
  Future<bool> get firearmPartsAreEmpty async {
    final count = await (selectOnly(firearmParts)
          ..addColumns([firearmParts.id.count()]))
        .map((row) => row.read(firearmParts.id.count()) ?? 0)
        .getSingle();
    return count == 0;
  }

  /// True when the optics catalog is empty.
  Future<bool> get opticsAreEmpty async {
    final count = await (selectOnly(optics)..addColumns([optics.id.count()]))
        .map((row) => row.read(optics.id.count()) ?? 0)
        .getSingle();
    return count == 0;
  }

  /// True when the targets catalog is empty.
  Future<bool> get targetsAreEmpty async {
    final count = await (selectOnly(targets)..addColumns([targets.id.count()]))
        .map((row) => row.read(targets.id.count()) ?? 0)
        .getSingle();
    return count == 0;
  }

  /// True when the reticles catalog is empty. Used by the reticle
  /// repository to decide whether to insert the default library on
  /// first launch.
  Future<bool> get reticlesAreEmpty async {
    final count =
        await (selectOnly(reticles)..addColumns([reticles.id.count()]))
            .map((row) => row.read(reticles.id.count()) ?? 0)
            .getSingle();
    return count == 0;
  }

  /// True when the custom drag curves catalog is empty. Used by the
  /// seed loader to decide whether to insert the bundled CDM / DSF
  /// library on first launch (or after a v12 migration).
  Future<bool> get dragCurvesAreEmpty async {
    final count = await (selectOnly(dragCurves)
          ..addColumns([dragCurves.id.count()]))
        .map((row) => row.read(dragCurves.id.count()) ?? 0)
        .getSingle();
    return count == 0;
  }

  /// True when the factory-ammunition catalog is empty. Used by the
  /// seed loader to decide whether to insert the bundled factory-loads
  /// library on first launch (or after a v14 migration).
  Future<bool> get factoryLoadsAreEmpty async {
    final count = await (selectOnly(factoryLoads)
          ..addColumns([factoryLoads.id.count()]))
        .map((row) => row.read(factoryLoads.id.count()) ?? 0)
        .getSingle();
    return count == 0;
  }
}
