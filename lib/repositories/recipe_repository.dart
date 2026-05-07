// FILE: lib/repositories/recipe_repository.dart
//
// ============================================================================
// WHAT THIS FILE DOES
// ============================================================================
// Owns three loosely-related slices of database CRUD that all hang off the
// recipe form:
//   1. The recipes themselves (saved load records).
//   2. The four per-component "lot" tables (powder lots, bullet lots,
//      primer lots, brass lots) — minimum-viable inserts so the user can
//      create a lot inline from the recipe form without leaving the
//      screen.
//   3. The schema-v4 user-defined custom-fields infrastructure (define
//      a new field once, attach values to many entities).
//
// **IMPORTANT NAMING ASYMMETRY.** This file is named `recipe_repository.dart`
// and the class is `RecipeRepository`, but the underlying drift table is
// still `UserLoads` (with row class `UserLoadRow` and companion
// `UserLoadsCompanion`). The user-facing terminology was changed from
// "load" to "recipe" without renaming the schema, because renaming a
// drift table requires bumping `schemaVersion` and writing a migration.
// Future-you: the words "load" and "recipe" in this codebase are
// synonyms — anything in the schema layer says "load", anything UI-facing
// says "recipe".
//
// Public methods on `RecipeRepository`:
//
// **Recipes (UserLoads):**
//   * `watchAll()` — live stream of every recipe, newest-edited first.
//   * `getById(id)` — one-shot single-row lookup.
//   * `insert(entry)` — insert a new recipe; returns the new id.
//   * `update(id, entry)` — update existing recipe; auto-bumps
//     `updatedAt`. Returns true if a row changed.
//   * `delete(id)` — hard delete; returns row count.
//
// **Lot helpers (one set per component kind):**
//   * `allPowderLots()` / `createPowderLot(...)` — list + minimal insert.
//   * `allBulletLots()` / `createBulletLot(...)` — same.
//   * `allPrimerLots()` / `createPrimerLot(...)` — same.
//   * `allBrassLots()` / `createBrassLot(...)` — same. Brass lots have
//     extra fields (count, caliber, headstamp lot) since the dedicated
//     Brass Lots screen exposes the full lifecycle, but this minimal
//     creator is here so the recipe form can stamp a lot id without
//     leaving the recipe context.
//
// **Custom fields (schema v4):**
//   * `customFieldsForEntity(entityType)` — list every user-defined field
//     attached to an entity type (`'recipe' | 'firearm' | 'batch' |
//     'brass-lot'`), in display order.
//   * `createCustomField(...)` — define a brand-new custom field.
//   * `customFieldValuesForEntity(entityType, entityId)` — fetch the
//     stored values for one specific row, returned as a `fieldId -> value`
//     map. Missing entries are simply absent from the map.
//   * `setCustomFieldValue({fieldId, entityId, value})` — upsert a single
//     value. Pass `null` or `''` to clear.
//
// Pseudo-code for a typical recipe save:
//   final newPowderLotId = await repo.createPowderLot(name: 'Lot A',
//       manufacturer: 'Hodgdon', dateOpened: DateTime.now());
//   await repo.insert(UserLoadsCompanion.insert(
//       caliber: '6.5 Creedmoor', powder: 'Hodgdon H4350',
//       powderLotId: Value(newPowderLotId), ...));
//
// ============================================================================
// WHY IT EXISTS IN THE ARCHITECTURE
// ============================================================================
// Same repository-pattern reasoning as the rest of the app: keep all SQL
// in one place per logical area, keep widgets free of drift boilerplate,
// keep `updatedAt` handling consistent. The recipe form is one of the
// most query-heavy screens in the app — it has to load the recipe, list
// every lot of every component kind, and persist any inline-created lots
// before saving the recipe. Bundling all of those queries here keeps the
// form simpler.
//
// The custom-fields helpers are technically not recipe-specific (they
// also serve firearm and batch screens), but they live here because
// schema v4 introduced them at the same time as several recipe-specific
// changes and there is no separate `MetadataRepository` in this codebase.
// If the custom-fields feature grows, splitting it into its own
// repository would be a clean refactor.
//
// Constructed and provided in `lib/app.dart` as `RecipeRepository(db)`.
// Screens reach it with `context.read<RecipeRepository>()`.
//
// (For Dart/Flutter readers new to drift: a `Stream<T>` returned by
// `.watch()` is a live query — drift re-runs the SELECT and re-emits
// whenever any row in the involved tables changes. The form's
// `StreamBuilder` rebuilds automatically; we never manually call
// `setState` after a save.)
//
// ============================================================================
// WHY THIS IS HARDER THAN IT LOOKS
// ============================================================================
// 1. **Schema-name drift.** The class says `Recipe`, but every drift
//    type still says `UserLoad`. New contributors will reach for
//    `RecipeRepository.insert(RecipeCompanion(...))` and the type
//    checker will complain. The companion is `UserLoadsCompanion`. A
//    rename would require a migration; we deliberately avoided it.
//
// 2. **Two different upsert semantics.** Most lot creators are pure
//    inserts (ids surface to the recipe form as foreign keys). Custom
//    field values, however, are upserts via `insertOnConflictUpdate`,
//    keyed on `(fieldId, entityId)` — the schema declares that pair as
//    the unique constraint, so reusing the same pair overwrites the
//    `value` instead of creating duplicates. Calling code never sees
//    a separate "update" method, just `setCustomFieldValue`.
//
// 3. **Custom-field lifecycle.** Deleting a custom field is NOT
//    exposed here. Custom fields are user-curated metadata and the UI
//    deliberately makes them sticky — the only way to "remove" one is
//    to clear all of its values (which leaves the field definition in
//    the catalog). If a destructive delete becomes a feature, it will
//    need a cascade to `UserCustomFieldValues`.
//
// 4. **`createBrassLot` is intentionally minimal.** It only stamps the
//    fields the recipe form needs (name, manufacturer, caliber, optional
//    headstamp/notes/count). Annealing history, neck wall thickness,
//    trim length, etc. are managed from the dedicated Brass Lots
//    screen via `BrassLotRepository`. Don't add more fields here unless
//    the recipe form needs them.
//
// ============================================================================
// WHO CONSUMES THIS FILE
// ============================================================================
// - lib/screens/loads/loads_list_screen.dart — calls `watchAll()` for
//   the live list, `delete(id)` from swipe-to-delete.
// - lib/screens/loads/load_form_screen.dart — calls `getById`, `insert`,
//   `update`, and the four `create*Lot` helpers when the user creates a
//   new lot inline. Also calls every custom-field method to render and
//   persist user-defined fields on the recipe form.
// - lib/screens/firearms/firearm_form_screen.dart and the batch form —
//   both also use the custom-field helpers (since custom fields are
//   per-entity-type, not per-screen).
// - lib/app.dart — constructs and provides the singleton.
//
// ============================================================================
// SIDE EFFECTS
// ============================================================================
// Reads and writes against the local SQLite database via drift. No JSON
// encoding/decoding (the schema-v5 `LoadDevelopmentSessions.rungsJson`
// blob is handled in `LoadDevelopmentRepository`, not here). The
// `update` method silently overwrites whatever `updatedAt` the caller
// supplies. No cross-table cascades — deletes do not chain to lots or
// custom-field values; the schema does not declare ON DELETE CASCADE
// for those edges.

import 'package:drift/drift.dart';

import '../database/database.dart';
import '../utils/natural_sort.dart';

/// Repository for user-saved recipes (load records).
///
/// Note: the underlying Drift table is still named `user_loads` /
/// [UserLoads] / [UserLoadRow] / [UserLoadsCompanion] for compatibility.
/// User-facing terminology says "recipe"; the schema kept its original
/// names to avoid a migration.
///
/// Also exposes lightweight CRUD for the per-component lot tables
/// ([PowderLots], [BulletLots], [PrimerLots], [BrassLots]) and the
/// schema-v4 custom-fields infrastructure ([UserCustomFields],
/// [UserCustomFieldValues]). Recipe forms use these helpers directly.
class RecipeRepository {
  RecipeRepository(this.db);
  final AppDatabase db;

  // ─────────────────────── Recipes ───────────────────────

  Stream<List<UserLoadRow>> watchAll() =>
      (db.select(db.userLoads)..orderBy([(l) => OrderingTerm.desc(l.updatedAt)]))
          .watch();

  Future<UserLoadRow?> getById(int id) =>
      (db.select(db.userLoads)..where((l) => l.id.equals(id)))
          .getSingleOrNull();

  Future<int> insert(UserLoadsCompanion entry) =>
      db.into(db.userLoads).insert(entry);

  Future<bool> update(int id, UserLoadsCompanion entry) =>
      (db.update(db.userLoads)..where((l) => l.id.equals(id)))
          .write(entry.copyWith(updatedAt: Value(DateTime.now())))
          .then((rows) => rows > 0);

  Future<int> delete(int id) =>
      (db.delete(db.userLoads)..where((l) => l.id.equals(id))).go();

  // ─────────────────────── Powder Lots ───────────────────────

  Future<List<PowderLotRow>> allPowderLots() async {
    final rows = await db.select(db.powderLots).get();
    final list = [...rows];
    list.sort((a, b) {
      final c = naturalCompare(a.manufacturer ?? '', b.manufacturer ?? '');
      if (c != 0) return c;
      return naturalCompare(a.name, b.name);
    });
    return list;
  }

  Future<int> createPowderLot({
    String? manufacturer,
    required String name,
    String? lotNumber,
    DateTime? dateOpened,
    String? notes,
  }) =>
      db.into(db.powderLots).insert(
            PowderLotsCompanion.insert(
              manufacturer: Value(manufacturer),
              name: name,
              lotNumber: Value(lotNumber),
              dateOpened: Value(dateOpened),
              notes: Value(notes),
            ),
          );

  // ─────────────────────── Bullet Lots ───────────────────────

  Future<List<BulletLotRow>> allBulletLots() async {
    final rows = await db.select(db.bulletLots).get();
    final list = [...rows];
    list.sort((a, b) {
      final c = naturalCompare(a.manufacturer ?? '', b.manufacturer ?? '');
      if (c != 0) return c;
      return naturalCompare(a.name, b.name);
    });
    return list;
  }

  Future<int> createBulletLot({
    String? manufacturer,
    required String name,
    String? lotNumber,
    DateTime? dateOpened,
    String? notes,
  }) =>
      db.into(db.bulletLots).insert(
            BulletLotsCompanion.insert(
              manufacturer: Value(manufacturer),
              name: name,
              lotNumber: Value(lotNumber),
              dateOpened: Value(dateOpened),
              notes: Value(notes),
            ),
          );

  // ─────────────────────── Primer Lots ───────────────────────

  Future<List<PrimerLotRow>> allPrimerLots() async {
    final rows = await db.select(db.primerLots).get();
    final list = [...rows];
    list.sort((a, b) {
      final c = naturalCompare(a.manufacturer ?? '', b.manufacturer ?? '');
      if (c != 0) return c;
      return naturalCompare(a.name, b.name);
    });
    return list;
  }

  Future<int> createPrimerLot({
    String? manufacturer,
    required String name,
    String? lotNumber,
    DateTime? dateOpened,
    String? notes,
  }) =>
      db.into(db.primerLots).insert(
            PrimerLotsCompanion.insert(
              manufacturer: Value(manufacturer),
              name: name,
              lotNumber: Value(lotNumber),
              dateOpened: Value(dateOpened),
              notes: Value(notes),
            ),
          );

  // ─────────────────────── Brass Lots ───────────────────────

  Future<List<BrassLotRow>> allBrassLots() async {
    final rows = await db.select(db.brassLots).get();
    final list = [...rows];
    list.sort((a, b) {
      final c = naturalCompare(a.manufacturer ?? '', b.manufacturer ?? '');
      if (c != 0) return c;
      return naturalCompare(a.name, b.name);
    });
    return list;
  }

  /// Inline brass-lot creation from the recipe form. Full BrassLots CRUD
  /// (count, firing count, anneal history, neck wall thickness, etc.) lives
  /// on the dedicated Brass Lots screen — this helper just stamps the
  /// minimum required fields so the recipe can reference an id.
  Future<int> createBrassLot({
    required String name,
    String? manufacturer,
    required String caliber,
    String? headstampLot,
    int count = 0,
    String? notes,
  }) =>
      db.into(db.brassLots).insert(
            BrassLotsCompanion.insert(
              name: name,
              manufacturer: Value(manufacturer),
              caliber: caliber,
              headstampLot: Value(headstampLot),
              count: count,
              notes: Value(notes),
            ),
          );

  // ─────────────────────── Custom Fields ───────────────────────

  /// Returns every user-defined custom field for the given entity type
  /// (`'recipe' | 'firearm' | 'batch' | 'brass-lot'`), in display order.
  Future<List<UserCustomFieldRow>> customFieldsForEntity(String entityType) =>
      (db.select(db.userCustomFields)
            ..where((f) => f.entityType.equals(entityType))
            ..orderBy([
              (f) => OrderingTerm.asc(f.sortOrder),
              (f) => OrderingTerm.asc(f.fieldName),
            ]))
          .get();

  Future<int> createCustomField({
    required String entityType,
    required String name,
    required String type,
    String? unitSuffix,
    int sortOrder = 0,
  }) =>
      db.into(db.userCustomFields).insert(
            UserCustomFieldsCompanion.insert(
              entityType: entityType,
              fieldName: name,
              fieldType: type,
              unitSuffix: Value(unitSuffix),
              sortOrder: Value(sortOrder),
            ),
          );

  /// Returns a `fieldId -> value` map for every custom field bound to
  /// `(entityType, entityId)`. Missing rows simply do not appear in the
  /// map — the caller treats them as null.
  Future<Map<int, String?>> customFieldValuesForEntity(
    String entityType,
    int entityId,
  ) async {
    final rows = await (db.select(db.userCustomFieldValues).join([
      innerJoin(
        db.userCustomFields,
        db.userCustomFields.id
            .equalsExp(db.userCustomFieldValues.fieldId),
      ),
    ])
          ..where(db.userCustomFields.entityType.equals(entityType) &
              db.userCustomFieldValues.entityId.equals(entityId)))
        .get();
    return {
      for (final r in rows)
        r.readTable(db.userCustomFieldValues).fieldId:
            r.readTable(db.userCustomFieldValues).value,
    };
  }

  /// Upserts a single value for a custom field. A null [value] clears the
  /// stored entry but keeps the row for history; pass an empty string to
  /// achieve the same result.
  Future<void> setCustomFieldValue({
    required int fieldId,
    required int entityId,
    String? value,
  }) async {
    await db.into(db.userCustomFieldValues).insertOnConflictUpdate(
          UserCustomFieldValuesCompanion.insert(
            fieldId: fieldId,
            entityId: entityId,
            value: Value(value),
            updatedAt: Value(DateTime.now()),
          ),
        );
  }
}
