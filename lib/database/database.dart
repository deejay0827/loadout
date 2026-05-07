import 'package:drift/drift.dart';
import 'package:drift_flutter/drift_flutter.dart';
import 'package:path_provider/path_provider.dart';

part 'database.g.dart';

// ─────────────────────── Reference tables (read-only seed) ───────────────────────

@DataClassName('ManufacturerRow')
class Manufacturers extends Table {
  IntColumn get id => integer().autoIncrement()();
  TextColumn get name => text()();
  TextColumn get country => text().nullable()();
  /// 'powder' | 'bullet' | 'primer' | 'brass' | 'firearm' | 'parts'
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
  ],
)
class AppDatabase extends _$AppDatabase {
  AppDatabase() : super(_open());

  AppDatabase.forTesting(super.e);

  @override
  int get schemaVersion => 3;

  @override
  MigrationStrategy get migration => MigrationStrategy(
        onCreate: (m) => m.createAll(),
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
        },
      );

  static QueryExecutor _open() {
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
}
