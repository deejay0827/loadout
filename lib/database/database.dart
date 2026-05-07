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
  ],
)
class AppDatabase extends _$AppDatabase {
  AppDatabase() : super(_open());

  AppDatabase.forTesting(super.e);

  @override
  int get schemaVersion => 5;

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
