import 'package:drift/drift.dart';

import '../database/database.dart';

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

  Future<List<PowderLotRow>> allPowderLots() =>
      (db.select(db.powderLots)
            ..orderBy([
              (l) => OrderingTerm.asc(l.manufacturer),
              (l) => OrderingTerm.asc(l.name),
            ]))
          .get();

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

  Future<List<BulletLotRow>> allBulletLots() =>
      (db.select(db.bulletLots)
            ..orderBy([
              (l) => OrderingTerm.asc(l.manufacturer),
              (l) => OrderingTerm.asc(l.name),
            ]))
          .get();

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

  Future<List<PrimerLotRow>> allPrimerLots() =>
      (db.select(db.primerLots)
            ..orderBy([
              (l) => OrderingTerm.asc(l.manufacturer),
              (l) => OrderingTerm.asc(l.name),
            ]))
          .get();

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

  Future<List<BrassLotRow>> allBrassLots() =>
      (db.select(db.brassLots)
            ..orderBy([
              (l) => OrderingTerm.asc(l.manufacturer),
              (l) => OrderingTerm.asc(l.name),
            ]))
          .get();

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
