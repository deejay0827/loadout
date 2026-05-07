// FILE: lib/repositories/component_repository.dart
//
// ============================================================================
// WHAT THIS FILE DOES
// ============================================================================
// This is the "bridge" between the seeded reference catalog (cartridges,
// powders, bullets, primers, brass, reference firearms) and the UI dropdowns
// that let users pick a component when building a recipe. It returns flat,
// alphabetized lists of human-readable strings that can be dropped straight
// into an autocomplete or dropdown widget.
//
// Public methods at a glance (all live on `ComponentRepository`):
//   * `allCartridges()` / `watchCartridges()` / `cartridgeByName(name)` —
//     read the full cartridge reference set (one-shot or live stream),
//     plus a single-row lookup by exact name.
//   * `componentLabels(kind)` — the workhorse. Given a kind string of
//     `"powder" | "bullet" | "primer" | "brass" | "cartridge"`, returns
//     the COMBINED list of formatted labels for both reference rows and
//     user-added custom components. Each kind formats differently:
//       - powder: `"<Mfg> <Powder Name>"` (e.g. `"Hodgdon Varget"`)
//       - bullet: `"<Mfg> <Line> <Weight>gr"` (e.g. `"Berger Hybrid 105gr"`)
//       - primer: `"<Mfg> #<PrimerId>"` (e.g. `"Federal #210M"`)
//       - brass:  `"<Mfg>"` (e.g. `"Lapua"`)
//       - cartridge: just the cartridge name (e.g. `"6.5 Creedmoor"`)
//     Pseudo-code call: `final powders = await repo.componentLabels('powder');`
//   * `addCustomComponent(kind, name, notes)` — upsert a user-defined
//     component. UI calls this when the user types a name not in the
//     reference list and wants to save it.
//   * `primerByLabel(label)` — parses a string like `"Federal #210M"`
//     and returns the matching `PrimerRow`. Used by the recipe form to
//     auto-fill primer size when a user picks a known primer from the
//     dropdown.
//   * `primerManufacturers()` / `primersByManufacturer(name)` — feed the
//     two halves of the cascading primer field on the recipe form
//     (brand dropdown + product dropdown).
//   * `primerProductLabel(p)` / `primerStorageLabel(mfg, p)` /
//     `splitPrimerStorageLabel(label)` — three static label helpers that
//     keep the on-screen format and the on-disk format in sync.
//   * `allReferenceFirearms()` — joins firearms reference rows with their
//     manufacturers and decodes the JSON-encoded calibers list. Used by
//     the firearm form's "pick from catalog" mode.
//
// Note on token-based fuzzy matching (the SAAMI cartridge picker): that
// happens upstream in the picker widget. This file just provides the raw
// data; the matching algorithm lives in the widget layer.
//
// ============================================================================
// WHY IT EXISTS IN THE ARCHITECTURE
// ============================================================================
// LoadOut uses the **repository pattern**. A repository is a thin Dart class
// that owns all of the database queries for one logical area of the app
// (here: components / reference data). Screens and widgets never talk to
// drift directly — they call `componentRepository.componentLabels('powder')`
// and get back a `List<String>`. This means:
//   * SQL/drift internals stay in one place. If we change the schema or
//     swap drift for another ORM, we only edit this file.
//   * Screen widgets stay free of database boilerplate (joins, ordering,
//     companion objects). Their `build` methods read like UI code, not
//     query code.
//   * Repositories can be mocked in tests — the screen depends on a
//     `ComponentRepository` interface, not on a live SQLite database.
//
// The UI reaches this repository through `Provider`. In `lib/app.dart` we
// construct a single `ComponentRepository(db)` at startup and provide it to
// the widget tree. A screen reads it with
// `context.read<ComponentRepository>()`. There is no global singleton.
//
// (For readers new to Dart/Flutter: `Stream<T>` is Dart's async-iterable.
// `db.select(...).watch()` returns a `Stream` that pushes a fresh `List`
// every time the underlying table changes. The UI subscribes via
// `StreamBuilder` and rebuilds automatically — that's how list views stay
// "live" without manual refreshes.)
//
// ============================================================================
// WHY THIS IS HARDER THAN IT LOOKS
// ============================================================================
// The non-obvious part is the union semantics. `componentLabels(kind)`
// returns a single flat list that mixes two sources — the seeded reference
// catalog (manufacturer-joined SQL queries) and the user's custom
// components (a separate `CustomComponents` table keyed by `kind` + `name`).
// Reference rows are formatted differently per kind (bullet weight gets
// a `gr` suffix; primer ID gets a `#` prefix), while custom components
// are stored as opaque strings so they always come back as-is. The order
// is "reference first (alphabetized), then customs (alphabetized)" so that
// the dropdown shows curated names at the top and the user's additions
// underneath.
//
// The primer label scheme is the other gotcha. A primer needs three
// representations:
//   * Cascading-dropdown UI: brand picked separately, then a per-brand
//     product label that excludes the brand (`primerProductLabel`).
//   * On-disk storage in `UserLoads.primer`: a single string with the
//     brand baked in (`primerStorageLabel`), so old recipes round-trip
//     cleanly even when a user later renames a brand.
//   * Edit mode: the stored string has to be split back into a
//     (manufacturer, primerName) pair to pre-select the dropdowns
//     (`splitPrimerStorageLabel`).
// All three forms have to agree byte-for-byte or the dropdown won't
// recognize a saved value. The static helpers exist precisely to keep
// every screen using the same parser.
//
// ============================================================================
// WHO CONSUMES THIS FILE
// ============================================================================
// - lib/screens/loads/load_form_screen.dart and the recipe form widgets in
//   lib/widgets/component_field.dart — call `componentLabels(kind)` to
//   power autocomplete dropdowns, plus `primerByLabel` /
//   `primersByManufacturer` for the cascading primer field.
// - lib/screens/saami/saami_screen.dart — uses `watchCartridges` /
//   `cartridgeByName` to drive the SAAMI cartridge picker and spec card.
// - lib/screens/firearms/firearm_form_screen.dart — uses
//   `allReferenceFirearms` to let the user pick from the catalog.
// - lib/app.dart — constructs the repository and provides it via
//   `Provider<ComponentRepository>`.
//
// ============================================================================
// SIDE EFFECTS
// ============================================================================
// Reads/writes against the local SQLite database via drift. The only writes
// are `addCustomComponent` (insertOnConflictUpdate into `CustomComponents`).
// JSON encode/decode happens at the boundary for `FirearmsRef.calibersJson`
// only. No network calls, no shared preferences, no file I/O.

import 'dart:convert';

import 'package:drift/drift.dart';

import '../database/database.dart';

/// Reads reference + custom components and exposes them as flat option lists
/// for dropdowns. Also writes user-added custom components.
class ComponentRepository {
  ComponentRepository(this.db);
  final AppDatabase db;

  // ───── Cartridges ─────

  Future<List<CartridgeRow>> allCartridges() => db.select(db.cartridges).get();

  Stream<List<CartridgeRow>> watchCartridges() =>
      (db.select(db.cartridges)..orderBy([(c) => OrderingTerm.asc(c.name)]))
          .watch();

  Future<CartridgeRow?> cartridgeByName(String name) =>
      (db.select(db.cartridges)..where((c) => c.name.equals(name)))
          .getSingleOrNull();

  // ───── Powders / bullets / primers / brass — unified label helpers ─────

  /// Returns label strings for the given component kind, combining reference
  /// data with user-added custom components.
  Future<List<String>> componentLabels(String kind) async {
    final results = <String>[];
    switch (kind) {
      case 'powder':
        final rows = await (db.select(db.powders).join([
          innerJoin(db.manufacturers,
              db.manufacturers.id.equalsExp(db.powders.manufacturerId)),
        ])
              ..orderBy([
                OrderingTerm.asc(db.manufacturers.name),
                OrderingTerm.asc(db.powders.name),
              ]))
            .get();
        for (final row in rows) {
          final mfg = row.readTable(db.manufacturers);
          final p = row.readTable(db.powders);
          results.add('${mfg.name} ${p.name}');
        }
        break;
      case 'bullet':
        final rows = await (db.select(db.bullets).join([
          innerJoin(db.manufacturers,
              db.manufacturers.id.equalsExp(db.bullets.manufacturerId)),
        ])
              ..orderBy([
                OrderingTerm.asc(db.manufacturers.name),
                OrderingTerm.asc(db.bullets.line),
                OrderingTerm.asc(db.bullets.weightGr),
              ]))
            .get();
        for (final row in rows) {
          final mfg = row.readTable(db.manufacturers);
          final b = row.readTable(db.bullets);
          final wt = b.weightGr.toStringAsFixed(b.weightGr.truncateToDouble() == b.weightGr ? 0 : 1);
          results.add('${mfg.name} ${b.line} ${wt}gr');
        }
        break;
      case 'primer':
        final rows = await (db.select(db.primers).join([
          innerJoin(db.manufacturers,
              db.manufacturers.id.equalsExp(db.primers.manufacturerId)),
        ])
              ..orderBy([
                OrderingTerm.asc(db.manufacturers.name),
                OrderingTerm.asc(db.primers.name),
              ]))
            .get();
        for (final row in rows) {
          final mfg = row.readTable(db.manufacturers);
          final p = row.readTable(db.primers);
          // Prepend a `#` to the primer ID so labels read like
          // "Federal #210M" or "Winchester #WLR".
          results.add('${mfg.name} #${p.name}');
        }
        break;
      case 'brass':
        final rows = await (db.select(db.brassProducts).join([
          innerJoin(db.manufacturers,
              db.manufacturers.id.equalsExp(db.brassProducts.manufacturerId)),
        ])
              ..orderBy([OrderingTerm.asc(db.manufacturers.name)]))
            .get();
        for (final row in rows) {
          final mfg = row.readTable(db.manufacturers);
          results.add(mfg.name);
        }
        break;
      case 'cartridge':
        final rows = await (db.select(db.cartridges)
              ..orderBy([(c) => OrderingTerm.asc(c.name)]))
            .get();
        results.addAll(rows.map((r) => r.name));
        break;
    }
    final customs = await (db.select(db.customComponents)
          ..where((c) => c.kind.equals(kind))
          ..orderBy([(c) => OrderingTerm.asc(c.name)]))
        .get();
    results.addAll(customs.map((c) => c.name));
    return results;
  }

  Future<int> addCustomComponent(String kind, String name, {String? notes}) =>
      db.into(db.customComponents).insertOnConflictUpdate(
            CustomComponentsCompanion.insert(
              kind: kind,
              name: name,
              notes: Value(notes),
            ),
          );

  /// Look up a primer reference row by a fully-formatted label of the form
  /// `"<Manufacturer> #<PrimerId>"` (e.g. `"Federal #210M"`). Returns
  /// `null` if the label doesn't match the format or no row is found.
  ///
  /// Used by the recipe form to auto-fill primer size when a user picks
  /// a known primer from the dropdown.
  Future<PrimerRow?> primerByLabel(String label) async {
    final hashIdx = label.indexOf('#');
    if (hashIdx <= 0 || hashIdx == label.length - 1) return null;
    final mfgName = label.substring(0, hashIdx).trim();
    final primerName = label.substring(hashIdx + 1).trim();
    if (mfgName.isEmpty || primerName.isEmpty) return null;

    final rows = await (db.select(db.primers).join([
      innerJoin(db.manufacturers,
          db.manufacturers.id.equalsExp(db.primers.manufacturerId)),
    ])
          ..where(db.manufacturers.name.equals(mfgName) &
              db.primers.name.equals(primerName)))
        .get();
    if (rows.isEmpty) return null;
    return rows.first.readTable(db.primers);
  }

  // ───── Primer cascading dropdown helpers ─────

  /// All primer manufacturer names, alphabetical. Used to populate the
  /// brand dropdown of the cascading primer field.
  Future<List<String>> primerManufacturers() async {
    final rows = await (db.select(db.manufacturers)
          ..where((m) => m.kind.equals('primer'))
          ..orderBy([(m) => OrderingTerm.asc(m.name)]))
        .get();
    return rows.map((m) => m.name).toList();
  }

  /// All primer products from a given manufacturer, sorted by product line
  /// then model number. Used to populate the product dropdown of the
  /// cascading primer field once a brand is chosen.
  Future<List<PrimerRow>> primersByManufacturer(String manufacturerName) async {
    final rows = await (db.select(db.primers).join([
      innerJoin(db.manufacturers,
          db.manufacturers.id.equalsExp(db.primers.manufacturerId)),
    ])
          ..where(db.manufacturers.name.equals(manufacturerName))
          ..orderBy([
            OrderingTerm.asc(db.primers.size),
            OrderingTerm.asc(db.primers.name),
          ]))
        .get();
    return rows.map((r) => r.readTable(db.primers)).toList();
  }

  /// Build the canonical user-facing label for a primer product.
  ///
  /// Format: `"<ProductLine> #<Name>"` if a product line exists, otherwise
  /// just `"#<Name>"`. The brand name is intentionally excluded since the
  /// cascading dropdown shows brand and product separately. For storage in
  /// the recipe (where only one string is persisted), use
  /// [primerStorageLabel] instead.
  static String primerProductLabel(PrimerRow p) {
    final pl = p.productLine;
    return pl == null || pl.isEmpty ? '#${p.name}' : '$pl #${p.name}';
  }

  /// The string we persist in `UserLoads.primer` when a user picks a primer
  /// from the dropdown. Keeps the existing `"<Brand> #<Name>"` shape so
  /// older recipes remain compatible and [primerByLabel] keeps working.
  static String primerStorageLabel(String manufacturer, PrimerRow p) {
    return '$manufacturer #${p.name}';
  }

  /// Parse a stored primer label like `"Federal #210M"` into its components.
  /// Returns `(manufacturer, primerName)` or `null` if the label isn't in
  /// the canonical format. Used by the cascading field to pre-select the
  /// dropdowns when editing an existing recipe.
  static ({String manufacturer, String primerName})? splitPrimerStorageLabel(
      String label) {
    final hashIdx = label.indexOf('#');
    if (hashIdx <= 0 || hashIdx == label.length - 1) return null;
    final mfg = label.substring(0, hashIdx).trim();
    final name = label.substring(hashIdx + 1).trim();
    if (mfg.isEmpty || name.isEmpty) return null;
    return (manufacturer: mfg, primerName: name);
  }

  // ───── Reference firearms ─────

  Future<List<({FirearmRefRow firearm, ManufacturerRow manufacturer, List<String> calibers})>>
      allReferenceFirearms() async {
    final rows = await (db.select(db.firearmsRef).join([
      innerJoin(db.manufacturers,
          db.manufacturers.id.equalsExp(db.firearmsRef.manufacturerId)),
    ])
          ..orderBy([
            OrderingTerm.asc(db.manufacturers.name),
            OrderingTerm.asc(db.firearmsRef.model),
          ]))
        .get();
    return rows.map((row) {
      final firearm = row.readTable(db.firearmsRef);
      final mfg = row.readTable(db.manufacturers);
      final calibers = (json.decode(firearm.calibersJson) as List<dynamic>)
          .cast<String>();
      return (firearm: firearm, manufacturer: mfg, calibers: calibers);
    }).toList();
  }
}
