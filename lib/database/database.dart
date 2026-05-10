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
// `schemaVersion` is currently 24. The `MigrationStrategy` defines two
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

  // ── Favorites (added schema v24) ──
  /// User-toggled "starred" flag. Picker / list UIs sort favorites first
  /// when this is true. Defaults to false so existing rows after the
  /// migration remain un-favorited. The toggle lives on
  /// `BallisticProfileRepository.toggleFavorite(id)`.
  BoolColumn get isFavorite =>
      boolean().withDefault(const Constant(false))();
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

  // ── Verified-data fields (added schema v22) ──
  /// Whether the row's geometry has been hand-checked against a
  /// manufacturer / patent-holder published spec. `false` (the default)
  /// means the entry is a placeholder or generic stand-in; UI surfaces
  /// MUST refuse to render unverified rows as if they were the named
  /// reticle. The audit pass that introduced this column flagged most
  /// existing rows as `false` — see `lib/data/reticle_library.dart`
  /// header for the verification rules.
  BoolColumn get verified =>
      boolean().withDefault(const Constant(false))();
  /// URL of the manufacturer / patent-holder spec document the row was
  /// verified against. Required when `verified = true`; ignored when
  /// `verified = false`. Stored verbatim so a future re-audit can hit
  /// the same page.
  TextColumn get sourceUrl => text().nullable()();
  /// Date the row was last verified against `sourceUrl`. Ignored when
  /// `verified = false`.
  DateTimeColumn get verifiedAt => dateTime().nullable()();
  /// Designer / patent-holder for licensed designs (e.g. "Horus Vision
  /// LLC" for every TReMoR3 / TReMoR5 / H59 / H37 row, regardless of
  /// the scope brand the row is wired to via `ScopeReticleOptions`).
  /// Free-form text. Null for in-house brand reticles whose designer
  /// is the same as the manufacturer.
  TextColumn get designer => text().nullable()();
  /// License attribution string shown next to the reticle in the
  /// picker (e.g. "Horus Vision LLC"). Free-form. Null when the
  /// reticle is the manufacturer's own design.
  TextColumn get license => text().nullable()();
  /// JSON-encoded subtension dictionary keyed by the patent-holder /
  /// manufacturer's published vocabulary (see `assets/seed_data/
  /// reticles_v2.json` for the canonical shape). Optional — null when
  /// the geometry in `definitionJson` is sufficient on its own.
  TextColumn get subtensionsJson => text().nullable()();
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

// ─────────────────────── Verified scope/reticle catalog (schema v22) ───────────────────────
//
// The pre-v22 `Optics` + `Reticles` tables coexist with the verified-data
// catalog below. The legacy `Optics` table inlines a single free-form
// `reticle` text field per scope, which forced us to ship one optics row
// per scope-reticle SKU (or worse, one row per scope with the wrong
// reticle picked arbitrarily). The legacy `Reticles` table wires every
// reticle to a single manufacturer string — fine for brand-specific
// patterns like Vortex's EBR-7C, but wrong for licensed designs like
// the Horus TReMoR3 that ship across multiple scope brands (Nightforce,
// Schmidt & Bender, EOTech, US Optics, Bushnell — every TReMoR3 is the
// SAME reticle pattern owned by Horus Vision LLC, not five different
// reticles).
//
// The new model splits the data into three normalised tables:
//
//   * `ScopeManufacturers` — one row per scope brand
//     (e.g. "Vortex Optics", country = "USA", website).
//   * `ScopeModels`        — one row per scope SKU
//     (e.g. "Razor HD Gen III 6-36x56 FFP"). Carries the click value,
//     elevation/windage travel, focal plane, tube/objective, etc.
//   * `ScopeReticleOptions`— many-to-many join. One row per scope-
//     reticle SKU the manufacturer actually ships
//     (e.g. Razor HD Gen II 4.5-27x56 FFP × Horus TReMoR3 MRAD).
//   * `Reticles`           — independent entities, one per pattern.
//                            The Horus TReMoR3 is one `Reticles` row
//                            referenced by every scope that ships it.
//                            (We keep using the existing `Reticles`
//                            table — it gains a few extra columns in
//                            v22 to track verification + source URL.)
//
// Every verified row carries a `sourceUrl` and a `verifiedAt` date so a
// future audit can re-spot-check entries. Rows with `verified = false`
// are placeholders the renderer must NOT draw as if they were real.

/// Brand of rifle scope manufacturer, distinct from the cross-purpose
/// `Manufacturers` table which lumps powder / bullet / primer / brass /
/// firearm / parts / optics / ammo brands together. We split this out
/// so a "Schmidt & Bender" row in `ScopeManufacturers` doesn't have to
/// race against any other reloading-component "Schmidt & Bender" row
/// (and so the verified-scope catalog can be updated independently of
/// the rest of the seed pipeline).
@DataClassName('ScopeManufacturerRow')
class ScopeManufacturers extends Table {
  IntColumn get id => integer().autoIncrement()();
  /// Manufacturer display name (e.g. "Vortex Optics").
  TextColumn get name => text().unique()();
  /// ISO-style country of headquarters (e.g. "USA", "Germany", "Austria").
  TextColumn get country => text().nullable()();
  /// Manufacturer's primary website (no trailing slash).
  TextColumn get website => text().nullable()();
  DateTimeColumn get createdAt => dateTime().withDefault(currentDateAndTime)();
}

/// One verified, sourced scope SKU. Carries the published click value,
/// elevation / windage travel, focal-plane class, tube + objective, and
/// a citation `sourceUrl` so the row can be re-verified later.
///
/// `clickValueMil` and `clickValueMoa` are both nullable — a scope is
/// almost always one or the other, but a few makers ship a "switchable"
/// turret or sell the same body with both turret types. Whichever
/// columns are populated reflect what's published on the manufacturer's
/// spec sheet.
///
/// Travel and max-adjustment columns are stored in the scope's *native*
/// turret unit (mil or MOA). Solver / display code that needs the other
/// unit must convert at use time.
@DataClassName('ScopeModelRow')
class ScopeModels extends Table {
  IntColumn get id => integer().autoIncrement()();
  IntColumn get manufacturerId =>
      integer().references(ScopeManufacturers, #id)();
  /// Model + magnification string as the manufacturer markets it
  /// (e.g. "Razor HD Gen III 6-36x56 FFP").
  TextColumn get modelName => text()();
  /// 'rifle-scope' | 'lpvo' | 'red-dot' | 'prism' | 'spotting'.
  TextColumn get category => text()();
  /// Minimum magnification (e.g. 6 for a 6-36x scope, 1 for a 1-6x LPVO).
  RealColumn get magnificationMin => real().nullable()();
  /// Maximum magnification.
  RealColumn get magnificationMax => real().nullable()();
  /// Objective lens diameter in mm. 0 / null for tubeless red dots.
  IntColumn get objectiveDiameterMm => integer().nullable()();
  /// Main tube diameter in mm (typical: 30, 34, 35, 36).
  IntColumn get tubeDiameterMm => integer().nullable()();
  /// 'first' | 'second' | 'fixed'.
  TextColumn get focalPlane => text()();
  /// 'mrad' | 'moa' | 'switchable'. Drives unit-display defaults; the
  /// per-turret click value below is the authoritative numeric source.
  TextColumn get reticleClass => text()();
  /// Click value in MRAD (e.g. 0.1 for a 0.1-MRAD turret). Null when
  /// this SKU only ships in MOA.
  RealColumn get clickValueMil => real().nullable()();
  /// Click value in MOA (e.g. 0.25 for a 1/4-MOA turret). Null when
  /// this SKU only ships in MRAD.
  RealColumn get clickValueMoa => real().nullable()();
  /// Mil per full elevation-turret rotation (e.g. 10 for "10 mil per
  /// rev"). Null when only the MOA equivalent is published.
  RealColumn get travelPerRevMil => real().nullable()();
  /// MOA per full elevation-turret rotation (e.g. 25 for "25 MOA per
  /// rev"). Null when only the MRAD equivalent is published.
  RealColumn get travelPerRevMoa => real().nullable()();
  /// Total elevation travel in MRAD (e.g. 36.1 for the Razor Gen III).
  RealColumn get maxElevationMil => real().nullable()();
  /// Total elevation travel in MOA (e.g. 120 for the Razor Gen III).
  RealColumn get maxElevationMoa => real().nullable()();
  /// Total windage travel in MRAD (e.g. 15.5 for the Razor Gen III).
  RealColumn get maxWindageMil => real().nullable()();
  /// Total windage travel in MOA (e.g. 52.5 for the Razor Gen III).
  RealColumn get maxWindageMoa => real().nullable()();
  /// Eye relief in inches.
  RealColumn get eyeReliefIn => real().nullable()();
  /// Manufacturer-published weight in ounces.
  RealColumn get weightOz => real().nullable()();
  /// Overall length in inches.
  RealColumn get lengthIn => real().nullable()();
  /// Minimum side-focus / parallax setting in yards.
  IntColumn get parallaxMinYd => integer().nullable()();
  /// Manufacturer's product page URL (the row's citation). Required —
  /// any row without a source URL has not been verified and must not
  /// be inserted via the seed loader.
  TextColumn get sourceUrl => text()();
  /// Date the row was verified against `sourceUrl` (ISO-8601 day
  /// precision is fine).
  DateTimeColumn get verifiedAt => dateTime()();
  TextColumn get notes => text().nullable()();
  DateTimeColumn get createdAt => dateTime().withDefault(currentDateAndTime)();

  @override
  List<Set<Column>> get uniqueKeys => [
        {manufacturerId, modelName},
      ];
}

/// Many-to-many join between `ScopeModels` and `Reticles`. One row per
/// scope-reticle SKU the manufacturer actually ships
/// (e.g. Razor HD Gen II 4.5-27x56 FFP with the EBR-7C MRAD reticle is
/// one row; the same scope body with the Horus TReMoR3 reticle is a
/// second row sharing the same `scopeModelId`).
///
/// `isDefault` flags the manufacturer's default / most-popular reticle
/// for the scope — used by the firearm form to pre-select something
/// reasonable when the user picks the scope without specifying a
/// reticle. `manufacturerSku` carries the model number printed on the
/// box (e.g. "RZR-42708" for the Razor Gen II 4.5-27x56 EBR-7C MRAD)
/// and is used as the row's stable identity for re-seeds.
@DataClassName('ScopeReticleOptionRow')
class ScopeReticleOptions extends Table {
  IntColumn get id => integer().autoIncrement()();
  IntColumn get scopeModelId => integer().references(ScopeModels, #id)();
  IntColumn get reticleId => integer().references(Reticles, #id)();
  /// Manufacturer's stock-keeping unit (e.g. "RZR-42708"). Optional
  /// because some scope-reticle pairs aren't sold under their own SKU.
  TextColumn get manufacturerSku => text().nullable()();
  /// True for the manufacturer's default / most-popular reticle for
  /// this scope. Exactly zero or one row per `scopeModelId` should be
  /// flagged. Not enforced as a DB constraint — the seed pipeline
  /// validates.
  BoolColumn get isDefault => boolean().withDefault(const Constant(false))();
  TextColumn get notes => text().nullable()();
  DateTimeColumn get createdAt => dateTime().withDefault(currentDateAndTime)();

  @override
  List<Set<Column>> get uniqueKeys => [
        {scopeModelId, reticleId},
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

// ─────────────────────── Manufactured ammo (curated subset, schema v23) ───────────────────────
//
// Distinct from [FactoryLoads]:
//   * [FactoryLoads] is the BIG (3 000+ row) factory-ammo catalog, scraped
//     from manufacturer spec sheets and consumed by the ballistics
//     calculator's "Factory Ammo" picker.
//   * [ManufacturedAmmo] is the SMALL (~17 row) curated catalog the Range
//     Day "Pick a common factory load" empty-state picker uses. Rows here
//     are hand-picked match / hunting loads that a first-launch shooter
//     is most likely to recognize, with manufacturer-published Standard
//     Deviation where it has been verified.
//
// Used for: ballistic profiles + the Range Day "Common Loads" picker.
// NEVER used for recipes — recipes need a powder, factory ammo doesn't
// list one. NEVER cross-consumed with [Bullets] — the bullets-only table
// (Berger 109gr Hybrid etc.) feeds recipes + ballistic profiles, the
// manufactured-ammo table feeds ballistic profiles + the Range Day
// common-loads picker. Keeping the two surfaces separate is a contract:
// callers consuming `Bullets` SHOULD NOT see [ManufacturedAmmo] rows,
// and vice versa.
@DataClassName('ManufacturedAmmoRow')
class ManufacturedAmmo extends Table {
  IntColumn get id => integer().autoIncrement()();
  /// Manufacturer name (free-form text, e.g. "Hornady", "Federal", "CCI",
  /// "Berger"). Not FK-linked to `Manufacturers` — the curated list is
  /// small enough that the lookup overhead isn't worth it, and the
  /// rows are read-only from the user's perspective.
  TextColumn get manufacturer => text()();
  /// Cartridge family as the manufacturer prints it on the box
  /// (e.g. "6.5 Creedmoor", "308 Win", "22 LR", "9mm Luger").
  TextColumn get cartridge => text()();
  /// Display name for the load (e.g. "140gr ELD-Match",
  /// "Gold Medal 175gr SMK", "Standard Velocity 40gr").
  TextColumn get name => text()();
  RealColumn get bulletWeightGr => real()();
  RealColumn get bulletDiameterIn => real()();
  /// Manufacturer-published muzzle velocity in fps. Typical 24" barrel
  /// number for centerfire rifle, shorter where appropriate (22 LR /
  /// 9mm). The user can override on the Range Day screen.
  RealColumn get muzzleVelocityFps => real()();
  /// Manufacturer-published Standard Deviation of muzzle velocity, in
  /// fps. Null when the manufacturer doesn't publish it. Drives the WEZ
  /// analysis screen's MV-uncertainty input.
  RealColumn get standardDeviationFps => real().nullable()();
  /// G7 ballistic coefficient. Centerfire rifle loads carry a G7 BC by
  /// convention; null for pistol / rimfire (which only publish G1).
  RealColumn get bcG7 => real().nullable()();
  /// G1 ballistic coefficient. Always populated for pistol / rimfire,
  /// optionally populated for rifle loads where the manufacturer also
  /// publishes a G1 number for legacy compatibility.
  RealColumn get bcG1 => real().nullable()();
  TextColumn get notes => text().nullable()();
  /// Manufacturer's product page URL backing the published MV / SD / BC
  /// numbers. Required for verified entries; null for catalog rows
  /// where the source URL isn't readily available.
  TextColumn get sourceUrl => text().nullable()();
  /// Wall-clock when the published numbers were last verified against
  /// the source URL. Null for unverified entries.
  DateTimeColumn get verifiedAt => dateTime().nullable()();
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

  // ── Favorites (added schema v24) ──
  /// User-toggled "starred" flag. Recipe lists sort favorites first when
  /// this is true; the recipe form, picker dropdowns, and Range Day
  /// recipe pickers all consult it via the new `isFavorite` column.
  /// Defaults to false so existing rows after the migration remain
  /// un-favorited. The toggle lives on
  /// `RecipeRepository.toggleFavorite(id)`.
  BoolColumn get isFavorite =>
      boolean().withDefault(const Constant(false))();
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

  // ── Favorites (added schema v24) ──
  /// User-toggled "starred" flag. Firearm lists / pickers sort favorites
  /// first when this is true. Defaults to false so existing rows after
  /// the migration remain un-favorited. The toggle lives on
  /// `FirearmRepository.toggleFavorite(id)`.
  BoolColumn get isFavorite =>
      boolean().withDefault(const Constant(false))();
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
  /// Legacy two-bucket discriminator: `'charge_ladder' | 'seating_ladder'`.
  ///
  /// Predates the v31 method-aware overhaul. Existing rows keep their
  /// original value so the schema stays additive; new rows continue to
  /// fill it (`charge_ladder` for OCW / Audette / Satterlee / Generic
  /// charge tests, `seating_ladder` for seating tests). New code reads
  /// [methodKind] for fine-grained dispatch.
  TextColumn get sessionType => text()();

  /// v31 method discriminator. One of `'ocw' | 'ladder' | 'satterlee' |
  /// 'generic' | 'seating'`. Always non-null on rows created at v31+;
  /// the v31 migration backfills legacy rows from [sessionType] by
  /// mapping `charge_ladder → 'generic'` and `seating_ladder →
  /// 'seating'`. New screens dispatch on this field.
  TextColumn get methodKind =>
      text().withDefault(const Constant('generic'))();

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
  /// Distance from muzzle to target in YARDS for OCW / Ladder vertical
  /// dispersion analysis. Nullable so seating-only sessions and
  /// pre-v31 rows stay valid; OCW / Ladder / Satterlee detail screens
  /// default to 100 yd in their setup placeholder.
  IntColumn get distanceYd => integer().nullable()();
  /// Number of shots fired per charge weight. OCW = 3 (Newberry); Audette
  /// Ladder = 1; Satterlee = 1 (10 charges × 1 shot, chrono-driven);
  /// Generic = whatever the user logs. Nullable for legacy rows.
  IntColumn get shotsPerCharge => integer().nullable()();
  /// User-selected "node" once analysis completes
  RealColumn get nodeValue => real().nullable()();
  /// JSON: per-rung aggregate data (chrono / accuracy / pressure notes).
  /// New OCW / Ladder / Satterlee shots live in [LoadDevelopmentShots]
  /// instead of this blob — the blob stays for legacy ladders and for
  /// rolled-up summaries.
  TextColumn get rungsJson => text().withDefault(const Constant('[]'))();
  TextColumn get notes => text().nullable()();
  DateTimeColumn get createdAt => dateTime().withDefault(currentDateAndTime)();
  DateTimeColumn get updatedAt => dateTime().withDefault(currentDateAndTime)();
}

/// Per-shot data for OCW / Audette Ladder / Satterlee 10-shot / Generic
/// load-development tests. Each row records one fired shot at a given
/// charge weight, with optional chrono and impact coordinates.
///
/// Why a separate child table instead of a JSON blob on the session:
///   * OCW vertical-vs-charge analysis needs efficient grouping by
///     `chargeGr`, which is awkward against a JSON column.
///   * The user routinely logs shots one-at-a-time at the range; a
///     row-per-shot insert is cheaper than a blob rewrite.
///   * Per-shot impact coordinates (X, Y in inches at distance Y) are
///     the foundation for the group-vs-charge plot.
///
/// All measurement fields are nullable. A row with only `chargeGr` set
/// represents "shot fired but no chrono / no group yet."
@DataClassName('LoadDevelopmentShotRow')
class LoadDevelopmentShots extends Table {
  IntColumn get id => integer().autoIncrement()();
  IntColumn get sessionId =>
      integer().references(LoadDevelopmentSessions, #id)();
  /// Charge weight in grains. Required — every shot in a load-dev test
  /// is "the shot at this charge weight."
  RealColumn get chargeGr => real()();
  /// 1-based ordinal of the shot within its charge. For OCW (3 shots
  /// per charge) this runs 1..3; for Ladder / Satterlee it's always 1.
  IntColumn get shotIndex => integer()();
  /// Muzzle velocity in fps (chrono reading). Nullable.
  RealColumn get velocityFps => real().nullable()();
  /// Impact X in inches relative to point of aim. Positive right,
  /// negative left. Nullable until the user logs the impact.
  RealColumn get impactXIn => real().nullable()();
  /// Impact Y in inches relative to point of aim. Positive UP, negative
  /// DOWN — matches how a shooter reads a target board, NOT how a
  /// screen Y axis grows.
  RealColumn get impactYIn => real().nullable()();
  /// Free-text notes ("called pull", "wind picked up", etc).
  TextColumn get notes => text().nullable()();
  DateTimeColumn get createdAt => dateTime().withDefault(currentDateAndTime)();
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
  /// 'circle' | 'square' | 'rectangle' | 'silhouette' | 'star' |
  /// 'bear' | 'boar' | 'deer' | 'elk' | 'coyote'. The picker
  /// filters by SHAPE; older `category` / `materialKind` /
  /// `manufacturer` columns were dropped in v28 because reloaders
  /// pick by geometry, not by what the target's made of or who
  /// printed the label.
  TextColumn get shape => text()();
  /// Outer-bound width of the target in inches (the visible /
  /// scoreable area). For circles this equals heightIn.
  RealColumn get widthIn => real()();
  /// Outer-bound height of the target in inches.
  RealColumn get heightIn => real()();
  /// CSS-style hex color used by the on-screen target renderer.
  /// The catalog default is `#ffffff` (white); the user picks a
  /// per-session tint from the swatch row in Range Day if they
  /// want a different color.
  TextColumn get colorHex => text()();
  TextColumn get notes => text().nullable()();
  DateTimeColumn get createdAt => dateTime().withDefault(currentDateAndTime)();
}

/// Reference catalog of "target racks" — parent objects that group an
/// ordered list of child targets the shooter engages one at a time. A KYL
/// (Know Your Limits) line of plates, a pepper-popper rack, an IDPA stage
/// with a head + chest, etc. Seeded from
/// `assets/seed_data/target_racks.json` on first launch (see
/// `seed_loader.dart`). Read-only at runtime.
///
/// The visual renderer draws the WHOLE rack so the shooter can pick which
/// child they're shooting; the ballistics solver only consumes whichever
/// child is "active". `totalWidthIn` / `totalHeightIn` describe the visual
/// envelope at the user's distance — used by the on-screen renderer to
/// scale the rack against the field-of-view, not by the solver.
@DataClassName('TargetRackRow')
class TargetRacks extends Table {
  IntColumn get id => integer().autoIncrement()();
  /// Display name shown in the rack picker ("5-Plate KYL", "Pepper
  /// Popper Rack").
  TextColumn get name => text()();
  /// Free-form description of how the rack is intended to be engaged.
  TextColumn get description => text().nullable()();
  /// 'kyl' | 'pepper-popper' | 'plate-rack' | 'idpa-stage' | 'custom'.
  /// Used for grouping in pickers and selecting an icon. Free-form text
  /// rather than an enum so future rack categories don't require a
  /// schema migration.
  TextColumn get rackKind => text()();
  /// Visual envelope width in inches. Drives renderer scaling against
  /// the FOV — NOT a ballistics input. The solver uses each child's
  /// dimensions instead.
  RealColumn get totalWidthIn => real()();
  /// Visual envelope height in inches. See `totalWidthIn`.
  RealColumn get totalHeightIn => real()();
  TextColumn get notes => text().nullable()();
  DateTimeColumn get createdAt => dateTime().withDefault(currentDateAndTime)();
}

/// One row per child plate / popper / silhouette inside a parent
/// [TargetRacks] entry. Children are shot one at a time; the ballistics
/// solver consumes the active child's `widthIn` / `heightIn` /
/// `shape` for hit-probability math.
///
/// `position` is a 0-indexed sort key (left-to-right or near-to-far
/// depending on the rack). `offsetXIn` / `offsetYIn` locate the child
/// relative to the rack's center in inches at the rack's natural scale
/// (positive X = right, positive Y = up).
@DataClassName('TargetRackChildRow')
class TargetRackChildren extends Table {
  IntColumn get id => integer().autoIncrement()();
  /// FK to the parent [TargetRacks] row.
  IntColumn get rackId => integer().references(TargetRacks, #id)();
  /// 0-indexed position within the rack. The repository's `childrenOf`
  /// query orders by this column, so the renderer / picker get a stable
  /// order matching the rack's intended engagement sequence.
  IntColumn get position => integer()();
  /// Per-child label ("Plate 1 (5 in)", "Popper #3"). Shown in the
  /// child-picker menu.
  TextColumn get name => text()();
  /// 'circle' | 'square' | 'rectangle' | 'silhouette' | 'irregular' —
  /// matches the enum used by [Targets.shape] so the same renderer
  /// helpers handle both single targets and rack children.
  TextColumn get shape => text()();
  RealColumn get widthIn => real()();
  RealColumn get heightIn => real()();
  /// X offset from the rack's geometric center, in inches. Positive =
  /// right.
  RealColumn get offsetXIn => real()();
  /// Y offset from the rack's geometric center, in inches. Positive =
  /// up.
  RealColumn get offsetYIn => real()();
  /// CSS-style hex color (e.g. "#ffffff"). Matches the convention used
  /// by [Targets.colorHex] so the renderer can paint rack children with
  /// the same code path as standalone targets.
  TextColumn get colorHex => text()();
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

  // ── Atmosphere preset (added schema v17) ──
  /// Optional FK to the saved [AtmospherePresets] row that pre-filled this
  /// session's environment fields. Purely a UX hint — the actual solver
  /// inputs come from the four atmosphere columns above. When the user
  /// loads a preset on the Range Day screen, this id is captured so
  /// reopening the session shows which preset was active in the picker.
  IntColumn get atmospherePresetId => integer().nullable()();

  // ── Rack mode (added schema v23) ──
  /// Optional FK to the [TargetRacks] row this session is configured
  /// against. Mutually exclusive with [targetId]: when [rackId] is
  /// non-null the session is in rack mode and [targetId] is forced
  /// null on auto-save; when [rackId] is null the session falls
  /// through to the existing single-target [targetId] path. The
  /// active child within the rack is recorded by [rackChildPosition].
  IntColumn get rackId =>
      integer().nullable().references(TargetRacks, #id)();
  /// Zero-based position of the active child inside the rack, matching
  /// `TargetRackChildren.position`. Null when the session is NOT in
  /// rack mode. The renderer / ballistics solver pulls the active
  /// child's geometry by indexing `childrenOf(rackId)` at this
  /// position; a stale value (e.g. seed re-shuffle that dropped the
  /// position) is clamped to the valid range by the picker, never
  /// crashes.
  IntColumn get rackChildPosition => integer().nullable()();
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

// ─────────────────────── Applied Ballistics parity (schema v16) ───────────────────────
//
// Three additive tables that turn LoadOut into a peer of Applied Ballistics on
// math depth without giving up the local-first storage model. All three are
// purely persistent records of analysis the solver could re-derive from the
// raw inputs — we save them so the user can come back to a particular WEZ
// curve, trued BC, or scope-tracking calibration without re-running the math
// each launch. None of these tables are required by the solver; the solver
// keeps using the load's nominal BC and the firearm's static sight-scale
// fields when no override row exists.

/// One saved Weapon Employment Zone (WEZ) profile. A WEZ profile is the
/// (load, firearm, target, uncertainty inputs) → hit-probability-vs-range
/// curve described in *Modern Advancements in Long Range Shooting
/// Vol 1*. The user runs the WEZ analysis screen, tunes the
/// inputs, and saves the result with a name so they can pull it back up
/// later or compare two WEZ profiles side-by-side.
///
/// `curveJson` stores the computed `[(rangeYd, hitPct)]` pairs as a JSON
/// array of `{"r": <yd>, "p": <0..1>}` objects. We persist the curve
/// itself rather than re-running the solver every time the user opens
/// the row because a 60-point curve takes ~150ms on a phone — fine
/// inline, but a noticeable thump on a list / grid view.
@DataClassName('WezProfileRow')
class WezProfiles extends Table {
  IntColumn get id => integer().autoIncrement()();
  TextColumn get name => text()();
  /// Optional FK to UserLoads. Null means the profile was built ad-hoc
  /// from a manually-entered projectile + MV.
  IntColumn get loadId => integer().nullable().references(UserLoads, #id)();
  /// Optional FK to UserFirearms. Null = ad-hoc rifle parameters.
  IntColumn get firearmId =>
      integer().nullable().references(UserFirearms, #id)();
  /// Target geometry — copy of the inputs at compute time.
  RealColumn get targetWidthIn => real()();
  RealColumn get targetHeightIn => real()();
  /// 'circle' | 'rectangle' | 'silhouette' — matches `Targets.shape`.
  TextColumn get targetShape => text()();
  /// Uncertainty inputs — the four sliders on the WEZ screen.
  RealColumn get groupMoa => real()();
  RealColumn get windUncertaintyMph => real()();
  RealColumn get rangeUncertaintyYd => real()();
  RealColumn get mvSdFps => real()();
  /// JSON array of `{"r": rangeYd, "p": hitProb0to1}`. Sorted ascending
  /// by range. Decoded by the WEZ screen on open to redraw the curve
  /// without re-running the solver.
  TextColumn get curveJson => text()();
  /// Wall-clock when the curve was computed. Distinct from `createdAt`
  /// (the row insert) because a future "Recompute" button updates the
  /// curve without inserting a new row.
  DateTimeColumn get computedAt => dateTime()();
  TextColumn get notes => text().nullable()();
  DateTimeColumn get createdAt =>
      dateTime().withDefault(currentDateAndTime)();
}

/// One BC-truing override. the BC truing methodology takes an observed
/// shot impact at a known range and back-solves the effective BC that
/// reproduces the observation. The result is a load-specific, firearm-
/// specific, drag-model-specific override that the solver consults
/// before falling back to the load's nominal BC.
///
/// `observationJson` stores the (range, observed-drop) pairs the truing
/// was derived from, as a JSON array of `{"rangeYd": x, "observedDropMil":
/// y, "predictedDropMil": z}` objects. Single-distance truing is one
/// element; multi-distance truing (the preferred form) has N elements.
///
/// `(loadId, firearmId, dragModel)` is the natural unique key — at any
/// time a particular (recipe × rifle × drag family) has at most one
/// active override. The repository enforces "upsert on this triple"
/// semantics; the unique index here is belt-and-suspenders.
@DataClassName('TruedBcOverrideRow')
class TruedBcOverrides extends Table {
  IntColumn get id => integer().autoIncrement()();
  IntColumn get loadId => integer().references(UserLoads, #id)();
  IntColumn get firearmId => integer().references(UserFirearms, #id)();
  /// 'g1' | 'g7' | 'cdm'. Matches DragModel string values; 'cdm' is
  /// reserved for custom-drag-curve loads where the truing scales the
  /// curve rather than a single-number BC.
  TextColumn get dragModel => text()();
  /// The catalog BC the load was using before truing. Recorded so the
  /// UI can show "trued from 0.326 to 0.314" without consulting the
  /// load row's current BC (which the user might have edited in the
  /// meantime).
  RealColumn get nominalBc => real()();
  /// The trued / effective BC the solver should use for this
  /// (load, firearm, dragModel) combination.
  RealColumn get truedBc => real()();
  /// Distance the truing observation was taken at. For multi-distance
  /// truing this is the longest distance in the observation set
  /// (the most informative point).
  RealColumn get truingDistanceYd => real()();
  /// JSON array of observations. See class docstring for shape.
  TextColumn get observationJson => text()();
  TextColumn get notes => text().nullable()();
  DateTimeColumn get truedAt => dateTime()();
  DateTimeColumn get createdAt =>
      dateTime().withDefault(currentDateAndTime)();

  @override
  List<Set<Column>> get uniqueKeys => [
        {loadId, firearmId, dragModel},
      ];
}

/// One sight-scale calibration (Drop-Per-Click / DPC). Records the
/// outcome of running the DPC wizard against a particular firearm:
/// the user dialed a known elevation or windage amount, fired a small
/// group, and the wizard derived a "true mil-per-click" ratio. The
/// derived ratio is also written to `UserFirearms.sightScaleVertical`
/// or `sightScaleHorizontal` so the solver picks it up immediately;
/// this table preserves the calibration history so the user can see
/// which session each scale factor came from.
///
/// `axis` distinguishes vertical / horizontal calibration runs — they
/// can produce different scale factors and live as separate rows on
/// the firearm.
@DataClassName('SightCalibrationRow')
// ─────────────────────── Atmosphere presets (schema v17) ───────────────────────
//
// User-saved atmospheric profiles. the "Applied Ballistics" methodology
// recommends keeping multiple named profiles (e.g. "Camp Atterbury summer",
// "Big Sandy", "Cold dry day") so the shooter can quickly switch between them
// rather than re-typing pressure / temperature / humidity / altitude every
// time. The picker appears at the top of the Environment section on both the
// Ballistics screen and the Range Day Setup card; selecting a preset auto-fills
// the four core atmosphere fields and the optional altitude.
//
// The `latitudeDeg` / `longitudeDeg` columns are optional metadata — the user
// can capture GPS at the time the preset is created so they remember where the
// readings came from, but the values are not used by the solver. Notes is a
// freeform text field for "morning vs afternoon", "front-of-firing-line", etc.
//
// Additive migration only. Adding a row never affects existing rows; deleting
// one only nullifies the FK on `RangeDaySessions.atmospherePresetId`.
@DataClassName('AtmospherePresetRow')
class AtmospherePresets extends Table {
  IntColumn get id => integer().autoIncrement()();
  /// User-facing name. Free-form; uniqueness enforced by the picker (case
  /// folded) rather than by the schema so renames don't trip a UNIQUE
  /// constraint mid-edit.
  TextColumn get name => text()();
  /// Station pressure (NOT sea-level / altimeter setting). Same canonical
  /// units as `RangeDaySessions.pressureInHg` and the solver's
  /// `Atmosphere.station(stationPressureInHg: ...)` argument.
  RealColumn get stationPressureInHg => real()();
  RealColumn get temperatureF => real()();
  RealColumn get humidityPct => real()();
  /// Optional capture-site altitude (feet). The solver doesn't consume this
  /// directly — the Environment section's Elevation field is what it reads —
  /// but auto-filled into the Elevation control when the user picks a preset.
  RealColumn get altitudeFt => real().nullable()();
  /// Optional GPS latitude at capture time. Display only; the solver's
  /// Coriolis correction reads its own `latitudeDeg` field.
  RealColumn get latitudeDeg => real().nullable()();
  /// Optional GPS longitude at capture time. Display only.
  RealColumn get longitudeDeg => real().nullable()();
  TextColumn get notes => text().nullable()();
  DateTimeColumn get createdAt => dateTime().withDefault(currentDateAndTime)();
  DateTimeColumn get updatedAt => dateTime().withDefault(currentDateAndTime)();
}

class SightCalibrations extends Table {
  IntColumn get id => integer().autoIncrement()();
  IntColumn get firearmId => integer().references(UserFirearms, #id)();
  /// 'vertical' | 'horizontal'.
  TextColumn get axis => text()();
  /// What the scope's turret claims to move per click, in mil. e.g. 0.1
  /// for a "0.1 mil per click" advertised scope. Stored to preserve
  /// the original advertised value even if the user later edits the
  /// firearm row.
  RealColumn get advertisedClickMil => real()();
  /// What the scope actually moved per click, in mil, derived from the
  /// observed centroid offset.
  RealColumn get observedClickMil => real()();
  /// The derived sight scale factor: observed / advertised. e.g. 0.973
  /// for a scope tracking 2.7% short. This is the value written to
  /// `UserFirearms.sightScaleVertical` or `sightScaleHorizontal`.
  RealColumn get derivedScale => real()();
  /// JSON array of the `(impactX, impactY)` observations used. Same
  /// shape as `ShotImpacts` rows — normalized [-1, 1] coords.
  TextColumn get observationJson => text()();
  TextColumn get notes => text().nullable()();
  DateTimeColumn get calibratedAt => dateTime()();
  DateTimeColumn get createdAt =>
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

// ─────────────────────── User Favorites (schema v24) ───────────────────────
//
// Per-user "starred" flag for reference-data rows the user can't mutate
// directly (cartridges, reticles, targets, and any future read-only
// catalog). User-data tables (UserLoads, UserFirearms, BallisticProfiles)
// keep their own `isFavorite` boolean column on the row itself; this join
// table is for the rest. Pickers consume this to compute "is this row
// favorited" and to sort favorites first; the Range Day workspace also
// reads `mostRecentFavoriteId` to seed new sessions with the user's most
// recently favorited reticle / target.

/// User-owned join table mapping a reference-data row to a "favorited"
/// flag. One row per (entityType, entityId) pair — the unique constraint
/// keeps duplicates out and lets `toggleFavorite` use a simple
/// read-then-write pattern. Created in schema v24.
@DataClassName('UserFavoriteRow')
class UserFavorites extends Table {
  IntColumn get id => integer().autoIncrement()();

  /// Discriminator: 'cartridge', 'reticle', 'target'. Not enforced at
  /// the SQLite level — callers use the constants exposed on
  /// `FavoritesRepository` (`kFavoriteCartridge`, `kFavoriteReticle`,
  /// `kFavoriteTarget`) to keep typos out of production data.
  TextColumn get entityType => text()();

  /// Reference-table row id this favorite points at. e.g. a row in the
  /// `Cartridges` / `Reticles` / `Targets` table.
  IntColumn get entityId => integer()();

  DateTimeColumn get createdAt =>
      dateTime().withDefault(currentDateAndTime)();

  @override
  List<Set<Column>> get uniqueKeys => [
        {entityType, entityId},
      ];
}

/// Schema v25: name-keyed favorites for component kinds that don't
/// have stable reference-table row ids (powder / bullet / primer /
/// brass). Cartridge favorites continue to live in [UserFavorites]
/// because cartridges are int-row-id keyed and the SAAMI screen
/// already provides a toggle UI on top of that schema.
///
/// Why a separate table:
///   * Components are picked by NAME (the upstream
///     `componentLabels` returns String). Catalog rows AND
///     custom user-added components share the same picker, so a
///     row-id-keyed favorite would either cover only catalog
///     entries OR break when the user renames a custom
///     component. Name-keyed favorites survive both flows.
///   * Including this in the encrypted Cloud Sync payload is the
///     point of moving from SharedPreferences to drift — the
///     existing sync pipeline (`ExportService.exportToJson` →
///     `CloudSyncService.syncUp`) walks every table in
///     [kUserDataTableOrder] and applies last-writer-wins on the
///     remote pull. Name-keyed rows fit that pipeline as long as
///     we treat (kind, name) as the natural key.
///
/// Migration from SharedPreferences happens once at first launch
/// after the upgrade in [ComponentFavoritesService._migrateFromPrefs].
@DataClassName('UserComponentFavoriteRow')
class UserComponentFavorites extends Table {
  IntColumn get id => integer().autoIncrement()();

  /// Component-kind discriminator: 'powder', 'bullet', 'primer',
  /// 'brass'. Cartridge favorites live in [UserFavorites] (int
  /// row-id keyed) — see the `UserComponentFavorites` table
  /// docstring for why the two systems coexist.
  TextColumn get kind => text()();

  /// User-facing component label (e.g. "Hodgdon Varget", "Sierra
  /// MatchKing 175gr"). Whitespace-trimmed at write time by
  /// [ComponentFavoritesService] so "Varget" and "Varget " can't
  /// duplicate.
  TextColumn get name => text()();

  /// Last update — Cloud Sync's last-writer-wins reconciler reads
  /// this to decide which side to keep when the same
  /// (kind, name) row exists on both devices. Bumped on every
  /// toggle insert (deletion is `DELETE FROM ...`, not an
  /// updatedAt bump, so a delete on device A wins over a create
  /// on device B only if A's delete arrives after the create).
  DateTimeColumn get updatedAt =>
      dateTime().withDefault(currentDateAndTime)();

  DateTimeColumn get createdAt =>
      dateTime().withDefault(currentDateAndTime)();

  @override
  List<Set<Column>> get uniqueKeys => [
        {kind, name},
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
    // Schema v16 additions (Applied Ballistics parity features).
    WezProfiles,
    TruedBcOverrides,
    SightCalibrations,
    // Schema v17 additions (user-saved atmospheric profiles).
    AtmospherePresets,
    // Schema v19 additions (target racks reference catalog).
    TargetRacks,
    TargetRackChildren,
    // Schema v22 additions (verified scope + reticle catalog).
    ScopeManufacturers,
    ScopeModels,
    ScopeReticleOptions,
    // Schema v23 additions (curated manufactured-ammo catalog feeding
    // the Range Day "Pick a common factory load" picker, plus rack
    // mode persistence on RangeDaySessions).
    ManufacturedAmmo,
    // Schema v24 additions (per-row `isFavorite` columns on UserLoads,
    // UserFirearms, BallisticProfiles plus a join table covering
    // reference-data favorites — cartridges, reticles, targets).
    UserFavorites,
    // Schema v25 additions (name-keyed favorites for powder /
    // bullet / primer / brass components — moved from
    // SharedPreferences to drift so they participate in
    // ExportService and Cloud Sync).
    UserComponentFavorites,
    // Schema v31 additions (per-shot data for OCW / Audette Ladder /
    // Satterlee 10-shot / Generic load-development tests; existing
    // `LoadDevelopmentSessions` gained `methodKind`, `distanceYd`,
    // `shotsPerCharge` columns).
    LoadDevelopmentShots,
  ],
)
class AppDatabase extends _$AppDatabase {
  AppDatabase() : super(_open());

  AppDatabase.forTesting(super.e);

  @override
  int get schemaVersion => 31;

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
          if (from < 16) {
            // v16 — Applied Ballistics parity. Three purely
            // additive tables that record the outputs of the new analysis
            // features: WEZ profiles, BC truing overrides, and sight-scale
            // (DPC) calibrations. The solver does not require any of these
            // rows to exist — when they don't, the legacy behaviour kicks
            // in (load's nominal BC, firearm's static `sightScale*`
            // fields). User data is preserved.
            await m.createTable(wezProfiles);
            await m.createTable(truedBcOverrides);
            await m.createTable(sightCalibrations);
          }
          if (from < 17) {
            // v17 — Atmosphere presets. Adds the [AtmospherePresets] table
            // and a nullable FK column on [RangeDaySessions] linking back
            // to the active preset (if any). Both are additive only; the
            // solver doesn't change behaviour because the existing
            // atmosphere fields on `RangeDaySessions` continue to be the
            // authoritative source of inputs. User data is preserved.
            await m.createTable(atmospherePresets);
            await m.addColumn(
                rangeDaySessions, rangeDaySessions.atmospherePresetId);
          }
          if (from < 18) {
            // v18 — Material-agnostic Targets catalog. The
            // `targets.json` seed dataset previously shipped near-
            // duplicate "AR500 Plate N in" / "AR550 Plate N in" pairs
            // distinguished only by `materialKind`. Steel grade affects
            // target durability, not where bullets go, so the catalog
            // was deduped to one "Steel Plate N in" per size and the
            // `materialKind` enum collapsed (`'steel-ar500'` /
            // `'steel-ar550'` → `'steel'`).
            //
            // Wipe the [Targets] table so next launch's
            // `seedIfNeeded` re-inserts the deduped catalog from JSON.
            // Existing `RangeDaySessions.targetId` rows that referenced
            // an AR500/AR550 row will end up pointing at a now-absent
            // id; the target picker's stale-id guard
            // (range_day_detail_screen.dart `_targetPicker`) shows
            // "(picked — hidden by filter)" rather than crashing.
            // User data (RangeDaySessions, ShotImpacts) is preserved
            // — only the reference catalog rotates.
            await delete(targets).go();
          }
          if (from < 19) {
            // v19 — Target Racks reference catalog. Seeded from
            // `assets/seed_data/target_racks.json` via the seed
            // loader on next launch; tables are created additively
            // here so existing user data (RangeDaySessions,
            // ShotImpacts, etc.) is preserved.
            await m.createTable(targetRacks);
            await m.createTable(targetRackChildren);
          }
          if (from < 20) {
            // v20 — Targets renamed to drop leading material words
            // ("Steel Plate 12 in" → "Plate 12 in", etc.) so the
            // picker can group by SHAPE without the name redundantly
            // repeating the material. Wipe the [Targets] table so
            // the next launch's `seedIfNeeded` re-inserts the
            // renamed catalog from JSON. Existing
            // `RangeDaySessions.targetId` rows that referenced the
            // old name are preserved as ids; the picker's stale-id
            // guard (range_day_detail_screen.dart `_targetPicker`)
            // handles ids that no longer resolve. User data
            // (RangeDaySessions, ShotImpacts) is preserved — only
            // the reference catalog rotates.
            await delete(targets).go();
          }
          if (from < 21) {
            // v21 — Followup pass on the v20 rename: a couple of
            // entries still leaked the material word inside the name
            // ("IDPA Cardboard Target" → "IDPA Target"). Wipe the
            // [Targets] table again so the next launch's
            // `seedIfNeeded` re-inserts the cleaned catalog from
            // JSON. Same stale-id behaviour as v20: any
            // `RangeDaySessions.targetId` that pointed at a renamed
            // row falls back to the picker's "(picked — hidden by
            // filter)" guard rather than crashing. User data
            // (RangeDaySessions, ShotImpacts) is preserved.
            await delete(targets).go();
          }
          if (from < 22) {
            // v22 — Verified scope + reticle catalog. Three new tables
            // ([ScopeManufacturers], [ScopeModels],
            // [ScopeReticleOptions]) plus four new columns on the
            // existing [Reticles] table (`verified`, `sourceUrl`,
            // `verifiedAt`, `designer`, `license`, `subtensionsJson`)
            // so the audit pass can mark which legacy reticle entries
            // are accurate-enough to render as the named pattern and
            // which are placeholders. Additive only. The legacy
            // [Optics] / [Reticles] tables are preserved untouched so
            // every existing caller (firearm form optics dropdown,
            // range day reticle picker, scope view) keeps working;
            // the migration off the legacy schema is a follow-up
            // task. Migration steps:
            //
            //   1. Create the three new tables.
            //   2. Add the six new columns to [Reticles] (each is
            //      either nullable or has a default, so existing rows
            //      need no backfill — they all start with
            //      `verified = false`).
            //
            // The [ScopeManufacturers] / [ScopeModels] /
            // [ScopeReticleOptions] tables are populated on next
            // launch by `SeedLoader.seedIfNeeded` from the JSON files
            // under `assets/seed_data/` (`scopes.json`,
            // `scope_reticle_options.json`, plus an additive
            // `reticles_v2.json` that supplements `reticles.json`).
            await m.createTable(scopeManufacturers);
            await m.createTable(scopeModels);
            await m.createTable(scopeReticleOptions);
            await m.addColumn(reticles, reticles.verified);
            await m.addColumn(reticles, reticles.sourceUrl);
            await m.addColumn(reticles, reticles.verifiedAt);
            await m.addColumn(reticles, reticles.designer);
            await m.addColumn(reticles, reticles.license);
            await m.addColumn(reticles, reticles.subtensionsJson);
          }
          if (from < 23) {
            // v23 — Two coordinated additions:
            //
            //   1. New [ManufacturedAmmo] table (curated subset of
            //      factory loads that feeds the Range Day "Pick a
            //      common factory load" empty-state picker). The
            //      previous incarnation of this catalog was a
            //      hand-coded `static const List<CommonLoad>` in
            //      `lib/services/common_loads_catalog.dart`; the v23
            //      migration moves the data into SQLite so the
            //      catalog can be live-updated via SeedUpdater
            //      without an App Store push.
            //   2. Two new nullable columns on [RangeDaySessions]
            //      ([rackId], [rackChildPosition]) so a session in
            //      rack mode survives an app restart. Existing rows
            //      get null values and continue rendering through
            //      the single-target [targetId] path.
            //
            // Both additions are additive — no existing user data is
            // touched. The [ManufacturedAmmo] table is populated on
            // next launch by `SeedLoader.seedIfNeeded` from
            // `assets/seed_data/manufactured_ammo.json`.
            await m.createTable(manufacturedAmmo);
            await m.addColumn(rangeDaySessions, rangeDaySessions.rackId);
            await m.addColumn(
                rangeDaySessions, rangeDaySessions.rackChildPosition);
          }
          if (from < 24) {
            // v24 — User favorites. Two coordinated additions, all
            // additive so existing user data is preserved:
            //
            //   1. New `isFavorite` boolean column on [UserLoads],
            //      [UserFirearms], and [BallisticProfiles]. Each
            //      defaults to `false` so every existing row starts
            //      un-favorited; the user opts in by tapping the
            //      star icon the UI agent will wire up.
            //   2. New [UserFavorites] join table for reference-data
            //      favorites — cartridges, reticles, and targets,
            //      where the row itself is read-only seed data and
            //      can't carry its own boolean column. The unique
            //      key on (entityType, entityId) prevents duplicate
            //      stars and lets the toggle helper round-trip
            //      reads + writes safely. Created empty on upgrade
            //      so the user starts with no reference-data
            //      favorites.
            //
            // The reticle / target favorites become the default for
            // new Range Day sessions (other agents wire that — this
            // migration just lays the storage in place via the
            // `mostRecentFavoriteId(entityType)` helper on
            // `FavoritesRepository`).
            await m.addColumn(userLoads, userLoads.isFavorite);
            await m.addColumn(userFirearms, userFirearms.isFavorite);
            await m.addColumn(
                ballisticProfiles, ballisticProfiles.isFavorite);
            await m.createTable(userFavorites);
          }
          if (from < 25) {
            // v25 — UserComponentFavorites: name-keyed favorites for
            // powder / bullet / primer / brass components. Created
            // empty; the existing-data migration from the legacy
            // SharedPreferences storage runs lazily on first launch
            // via `ComponentFavoritesService._migrateFromPrefs`,
            // not here, because SharedPreferences is async-only and
            // shouldn't block a synchronous migration step.
            await m.createTable(userComponentFavorites);
          }
          if (from < 26) {
            // v26 — wipe targets so the updated catalog ships:
            //   * Texas Star is now shape='star' (was 'circle' — the
            //     painter rendered it as a flat disc).
            //   * Added IPSC Mini (66%), IPSC A4 (75%), IDPA Reduced
            //     (75%) variants per the user's "more sizes" request.
            // The user-data tables (RangeDaySessions etc.) reference
            // targets by INT id; deleting catalog rows is a fk-soft
            // operation here because the picker resolves a missing
            // id to "— None —" without crashing.
            await delete(targets).go();
          }
          if (from < 27) {
            // v27 — full catalog overhaul:
            //   * Targets re-curated to a geometry-first list (50
            //     entries: 13 circles, 5 squares, 5 PRS rectangles,
            //     IPSC/IDPA/competition silhouettes, Texas Star,
            //     plus 8 animal silhouettes — bear / boar / deer /
            //     elk / coyote / hog). Made-up entries removed
            //     (Polymer*, Caldwell*, Birchwood*, etc.).
            //   * Target racks renamed with shape-aware suffixes
            //     ("· Circles", "· Squares") so users can tell a
            //     5-Plate KYL of round plates from a square one.
            //     Added square variants of KYL + 3-Plate Decreasing,
            //     plus a Texas Star rack.
            // Wipe both tables; the seed loader re-populates from the
            // updated JSON on next launch. Deleting rack-children
            // first to honour the FK from `target_rack_children` →
            // `target_racks`.
            await delete(targetRackChildren).go();
            await delete(targetRacks).go();
            await delete(targets).go();
          }
          if (from < 28) {
            // v28 — drop materials from the targets catalog. Per
            // user feedback "I do not want anything whatsoever
            // pertaining to materials for targets," the
            // `manufacturer`, `materialKind`, and `category` columns
            // are removed from the `Targets` table. Reloaders pick
            // by geometry alone now.
            //
            // SQLite's ALTER TABLE doesn't support DROP COLUMN
            // cleanly across all our targets, so we recreate the
            // table with the slimmed schema and let the seed loader
            // re-populate from the (also slimmed) JSON on next
            // launch.
            await customStatement('DROP TABLE IF EXISTS targets');
            await m.createTable(targets);
          }
          if (from < 29) {
            // v29 — IPSC silhouette + popper recurate. The
            // `silhouette` shape was used as a generic catch-all
            // (IPSC, IDPA, B-27, popper variants all collapsed to
            // one painter); per user request we now ship only the
            // 6 official IPSC sizes plus 2 dedicated `popper`-shape
            // entries (Pepper Popper Full + Mini). The `_paintIpsc`
            // and `_paintPopper` painters render each correctly.
            // Wipe targets so the seed loader picks up the new list
            // on next launch.
            await delete(targets).go();
          }
          if (from < 30) {
            // v30 — Adds three LoadOut-original BDC chevron reticles
            // to the catalog (5.56 NATO / 7.62 NATO / .300 BLK
            // supersonic). To pick the new rows up on existing
            // installs we wipe the reticle catalog so the seed
            // loader's `reticlesAreEmpty` check fires on next
            // launch. `ScopeReticleOptions` carries an FK on
            // `Reticles.id`, so it has to be wiped first to satisfy
            // the constraint. Both tables re-seed automatically on
            // the next `seedIfNeeded()` pass.
            //
            // User-facing impact: any saved
            // `UserFirearms.reticleId` / `Optics.reticleId` /
            // `RangeDaySessions.reticleId` integer that pointed at
            // a now-wiped row will dangle until the user picks the
            // reticle again. The columns are nullable and the
            // picker resolves a missing id to "no reticle picked",
            // so this is a one-time minor re-pick rather than a
            // crash or data loss.
            await delete(scopeReticleOptions).go();
            await delete(reticles).go();
          }
          if (from < 31) {
            // v31 — Load Development overhaul. Adds method-specific
            // workflows (OCW / Audette Ladder / Satterlee 10-shot /
            // Generic) on top of the legacy two-bucket schema.
            // Three coordinated additions, all additive so existing
            // ladder sessions are preserved:
            //
            //   1. New columns on `LoadDevelopmentSessions`:
            //        * `methodKind` — disambiguates which protocol
            //          (`'ocw' | 'ladder' | 'satterlee' | 'generic' |
            //          'seating'`).
            //        * `distanceYd` — distance to target in yards
            //          (needed for OCW / Ladder vertical-vs-charge
            //          analysis).
            //        * `shotsPerCharge` — shots fired per charge
            //          weight (3 for OCW, 1 for Ladder / Satterlee,
            //          variable for Generic).
            //   2. New `LoadDevelopmentShots` child table holding
            //      per-shot velocity + impact data. The legacy
            //      `rungsJson` blob continues to work for sessions
            //      that pre-date the per-shot model.
            //   3. Backfill `methodKind` on existing rows: every
            //      `sessionType = 'charge_ladder'` becomes
            //      `methodKind = 'generic'`, and every `sessionType
            //      = 'seating_ladder'` becomes `methodKind =
            //      'seating'`. Existing screens still work because
            //      the legacy detail screen doesn't read
            //      `methodKind`.
            await m.addColumn(
                loadDevelopmentSessions, loadDevelopmentSessions.methodKind);
            await m.addColumn(
                loadDevelopmentSessions, loadDevelopmentSessions.distanceYd);
            await m.addColumn(
              loadDevelopmentSessions,
              loadDevelopmentSessions.shotsPerCharge,
            );
            await m.createTable(loadDevelopmentShots);
            // Backfill methodKind from sessionType for existing rows.
            // Default for the new column is `'generic'` so the
            // charge-ladder rows already match; we only need to
            // rewrite seating-ladder rows.
            await customStatement(
              "UPDATE load_development_sessions "
              "SET method_kind = 'seating' "
              "WHERE session_type = 'seating_ladder'",
            );
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
      // v16 user-data tables — drop before their parents (UserLoads,
      // UserFirearms) so foreign-key references stay consistent even if
      // we ever switch on FK enforcement.
      await delete(wezProfiles).go();
      await delete(truedBcOverrides).go();
      await delete(sightCalibrations).go();
      await delete(shotImpacts).go();
      await delete(rangeDaySessions).go();
      // v17 — atmosphere presets are user-data; wipe them too.
      await delete(atmospherePresets).go();
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
      // v24 — favorites against reference data. The per-row `isFavorite`
      // booleans on UserLoads / UserFirearms / BallisticProfiles are
      // wiped along with the rows above; this drops the join-table
      // entries pointing at the (preserved) reference catalog so the
      // user starts clean after a wipe.
      await delete(userFavorites).go();
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

  /// True when the target-racks catalog is empty. Used by the seed
  /// loader to decide whether to insert the bundled target-racks
  /// library on first launch (or after the v19 migration).
  Future<bool> get targetRacksAreEmpty async {
    final count = await (selectOnly(targetRacks)
          ..addColumns([targetRacks.id.count()]))
        .map((row) => row.read(targetRacks.id.count()) ?? 0)
        .getSingle();
    return count == 0;
  }

  /// True when the [ScopeManufacturers] catalog is empty. Used by the
  /// seed loader to decide whether to seed the verified scope catalog
  /// on first launch (or after the v22 migration).
  Future<bool> get scopeManufacturersAreEmpty async {
    final count = await (selectOnly(scopeManufacturers)
          ..addColumns([scopeManufacturers.id.count()]))
        .map((row) => row.read(scopeManufacturers.id.count()) ?? 0)
        .getSingle();
    return count == 0;
  }

  /// True when the [ScopeModels] catalog is empty. Mirrors
  /// [scopeManufacturersAreEmpty] for the per-SKU spec table.
  Future<bool> get scopeModelsAreEmpty async {
    final count = await (selectOnly(scopeModels)
          ..addColumns([scopeModels.id.count()]))
        .map((row) => row.read(scopeModels.id.count()) ?? 0)
        .getSingle();
    return count == 0;
  }

  /// True when the [ScopeReticleOptions] join is empty. Mirrors
  /// [scopeManufacturersAreEmpty] for the many-to-many table.
  Future<bool> get scopeReticleOptionsAreEmpty async {
    final count = await (selectOnly(scopeReticleOptions)
          ..addColumns([scopeReticleOptions.id.count()]))
        .map((row) => row.read(scopeReticleOptions.id.count()) ?? 0)
        .getSingle();
    return count == 0;
  }

  /// True when the [ManufacturedAmmo] catalog is empty. Used by the
  /// seed loader to decide whether to insert the bundled curated
  /// manufactured-ammo library on first launch (or after the v23
  /// migration).
  Future<bool> get manufacturedAmmoAreEmpty async {
    final count = await (selectOnly(manufacturedAmmo)
          ..addColumns([manufacturedAmmo.id.count()]))
        .map((row) => row.read(manufacturedAmmo.id.count()) ?? 0)
        .getSingle();
    return count == 0;
  }
}
