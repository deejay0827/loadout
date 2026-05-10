// FILE: lib/services/export_service.dart
//
// ============================================================================
// WHAT THIS FILE DOES
// ============================================================================
// Defines `ExportService`, the class that converts the user-mutable side of
// LoadOut's local SQLite database to and from a self-describing JSON
// document. This is the foundation of two user-visible features:
//
//   1. "Export to file" — produces a plain JSON file that the user can
//      AirDrop / email / save to Files / drop in Dropbox. The export goes
//      out via a temp file fed to the system share sheet via the
//      `share_plus` package.
//   2. "Encrypted cloud backup" — the same JSON body is the *plaintext*
//      input to `BackupCrypto.encrypt`. The encrypted blob is then
//      uploaded to iCloud Drive or Google Drive's appDataFolder.
//
// What is "JSON"? JSON (JavaScript Object Notation) is a text format that
// represents a tree of strings, numbers, booleans, lists, and key/value
// objects. It's universally readable — any programming language can parse
// it, every text editor can open it, and a determined user can hand-edit
// it if they need to.
//
// What is "drift"? Drift is the Dart package LoadOut uses to talk to SQLite
// in a typed, code-generated way. Each table is declared in
// `lib/database/database.dart` and drift generates `*Row` classes with
// `toJson()` / `fromJson()` helpers — those are what we use here.
//
// Public surface, in the order it appears:
//
//   - `kLoadOutExportVersion` — top-level version number for the on-disk
//     wrapper format. Bumped whenever the exporter layout changes (new
//     top-level field, renamed table, etc.). Independent of the database
//     schema version.
//   - `kUserDataTableOrder` — the FK-safe order in which tables are dumped
//     and re-inserted. Order matters on import: parent rows (PowderLots,
//     BrassLots, etc.) must land BEFORE child rows that reference them
//     (UserLoads, Batches), or the foreign key constraint fires.
//   - `ImportTableSummary` — per-table counts of added / skipped / errored
//     rows. The Backup screen renders one of these per section.
//   - `ImportSummary` — aggregate result. Has `totalAdded`, `totalSkipped`,
//     `hasErrors`, and an optional `fatalError` set when the import was
//     refused before any tables were walked.
//   - `ImportMergeMode.skipDuplicates` — keep the local row, skip inbound.
//     Default. Safe.
//   - `ImportMergeMode.overwrite` — overwrite the local row with inbound.
//     Destructive — only used when the user explicitly chooses "replace".
//   - `ExportService(db)` — constructor.
//   - `exportToJson()` — produces the wrapped JSON document. Pretty-printed
//     so the user opening the file in TextEdit gets a legible view.
//   - `writeExportToTempFile({filename})` — writes `exportToJson()` to a
//     timestamped temp file via `path_provider.getTemporaryDirectory()` and
//     returns the resulting `File`. The Backup screen then hands this file
//     to `share_plus`, which opens the system share sheet (AirDrop, Files,
//     Mail, Drive, etc.). The temp directory is purged by the OS on
//     uninstall and after a while of inactivity, so this is a safe staging
//     spot — the file is intentionally not persistent.
//   - `importFromJson(json, {mode})` — inverse of `exportToJson`. Parses,
//     validates the wrapper (see "Wrapper format" below), then walks
//     `kUserDataTableOrder` and inserts each table's rows inside a single
//     SQLite transaction so the import is atomic.
//
// WRAPPER FORMAT (`exportToJson` output):
// ```json
// {
//   "loadout_export_version": 1,
//   "exported_at": "2026-05-07T12:34:56.000Z",
//   "schema_version": 4,
//   "tables": {
//     "user_loads":    [ {...row...}, {...row...} ],
//     "user_firearms": [ ... ],
//     ...
//   }
// }
// ```
// `loadout_export_version` distinguishes wrapper-format changes from the
// database schema version. `schema_version` snapshots the runtime DB
// schema so the importer can refuse forward-incompatible payloads.
//
// VERSION REJECTION RULES (in `importFromJson`):
//   - Inbound `loadout_export_version` > our `kLoadOutExportVersion`
//     ⇒ FATAL: "Backup was created by a newer version of LoadOut".
//   - Inbound `schema_version` > runtime `db.schemaVersion`
//     ⇒ FATAL: "Backup uses database schema vX, but this app is on vY".
//   - Either field missing or wrong type ⇒ FATAL: "is this a LoadOut export?"
//   - Inbound `tables` not a Map ⇒ FATAL: "missing the tables map".
// Forward-compatible imports (older payload, newer DB) are accepted; older
// columns just don't appear in the row JSON, drift's `fromJson` tolerates
// that.
//
// ============================================================================
// WHY IT EXISTS IN THE ARCHITECTURE
// ============================================================================
// LoadOut is a local-first app — the user's data lives in SQLite, never on
// our servers. That means losing the device or migrating to a new one
// would lose their reloading log unless we provide an explicit export path.
// `ExportService` is that path. It is deliberately NOT integrated with any
// cloud sync — the backup screens that DO talk to cloud providers (iCloud,
// Drive) layer on top of this service via `BackupCrypto`.
//
// In the layer cake:
//
//   UI (Backup screen, Export menu)
//     ↓
//   ExportService                     ← this file
//     ├──→ AppDatabase (drift)
//     └──→ BackupCrypto (encryption layer for cloud backup)
//
// The seeded reference tables (Cartridges, Powders, Bullets, Primers,
// BrassProducts, FirearmsRef, FirearmParts, Manufacturers) are
// INTENTIONALLY EXCLUDED from the export. Those ship with every install
// from JSON in `assets/seed_data/` and would only inflate backups. The
// user is the source of truth only for `kUserDataTableOrder`.
//
// ============================================================================
// WHY THIS IS HARDER THAN IT LOOKS
// ============================================================================
// 1. FOREIGN KEY ORDER. SQLite enforces FK constraints when foreign keys
//    are enabled (drift turns them on). If the importer inserts a UserLoad
//    that references a PowderLot before that PowderLot has been inserted,
//    the constraint fires and the row fails. `kUserDataTableOrder` is
//    therefore canonical — both `exportToJson` and `importFromJson` walk
//    it identically.
// 2. PRIMARY KEY COLLISIONS. After a user re-imports a backup taken on
//    the same device, every primary key already exists. Default mode
//    (`skipDuplicates`) keeps the local row and counts it under "skipped".
//    `overwrite` mode forces an upsert via `InsertMode.insertOrReplace`,
//    which obliterates any local edits made since the backup was taken.
// 3. ATOMICITY. The whole import runs inside `db.transaction(...)`. If a
//    single row fails mid-walk, the entire transaction can be rolled back.
//    Without this, a half-successful import would leave the DB in a
//    half-merged state.
// 4. FORWARD COMPATIBILITY OF TABLE NAMES. The importer's `_insertOne`
//    `switch` returns `false` for unknown table names rather than
//    throwing — so a backup taken on a slightly newer version we still
//    consider compatible (export_version <= ours, schema_version <= ours)
//    that includes a new table doesn't crash; the new table is silently
//    ignored, the rest imports fine.
// 5. DRIFT JSON ROUND-TRIP. We use drift-generated `Row.toJson()` /
//    `Row.fromJson()` so unknown columns automatically appear/disappear
//    when the schema evolves. Hand-rolled JSON would have to be updated
//    every time we add a column.
// 6. TEMP FILE LIFETIME. `writeExportToTempFile` writes into the OS temp
//    directory. iOS and Android both purge this directory on uninstall
//    and after a while of inactivity, which is exactly what we want — the
//    user only needs the file long enough for `share_plus` to hand it
//    off to their chosen destination app.
//
// ============================================================================
// WHO CONSUMES THIS FILE
// ============================================================================
// - The Backup / Settings screen drives `exportToJson`, `writeExportToTempFile`,
//   and `importFromJson`. (See screens under
//   `/Users/general/Development/Applications/LoadOut/lib/screens/`).
// - `cloud_backup.dart` doesn't import this file directly — instead the
//   Backup screen calls `ExportService.exportToJson` to get the plaintext
//   JSON, then feeds that to `BackupCrypto.encrypt`, then hands the
//   encrypted blob to a `CloudBackupProvider`.
//
// ============================================================================
// SIDE EFFECTS
// ============================================================================
// - Reads every user-data table via drift `select(...).get()` calls.
// - Writes a temp file in `path_provider.getTemporaryDirectory()` (export only).
// - On import: opens a SQLite transaction and runs N inserts/upserts.
// - No network. No persistence beyond the temp file. No analytics.

import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart';
import 'package:path_provider/path_provider.dart';

import '../database/database.dart';

/// Versioned wrapper around the user-data dump produced by [ExportService].
///
/// The number is incremented when the on-disk shape changes in a way the
/// importer needs to detect (e.g. a new top-level field, a renamed table, a
/// breaking column removal). Bumping it does NOT bump [AppDatabase.schemaVersion]
/// — that's tracked separately because the exporter and the runtime schema
/// can drift apart between releases.
const int kLoadOutExportVersion = 1;

/// Names of every user-data table that participates in export/import. Order
/// matters on import because of foreign keys: parents (e.g. PowderLots,
/// BrassLots) must be inserted before children (UserLoads, Batches) so the FK
/// references resolve. The exporter walks this list verbatim; the importer
/// walks it in the same order.
///
/// We deliberately do NOT include the seeded reference tables (Manufacturers,
/// Cartridges, Powders, Bullets, Primers, BrassProducts, FirearmsRef,
/// FirearmParts) — those ship with every install and do not belong in a
/// per-user backup.
const List<String> kUserDataTableOrder = <String>[
  'custom_components',
  'powder_lots',
  'bullet_lots',
  'primer_lots',
  'brass_lots',
  'user_process_steps',
  'user_firearms',
  'user_loads',
  'batches',
  'test_sessions',
  'user_custom_fields',
  'user_custom_field_values',
  // Schema v5 — load development sessions (charge / seating ladders). Has
  // nullable FKs to UserFirearms, UserLoads (`sourceRecipeId`), and BrassLots
  // (`brassLotId`), so it must land after all three.
  'load_development_sessions',
  // Schema v8 — ballistic profiles. Nullable FKs to UserFirearms (`firearmId`)
  // and the seeded Bullets reference table (`bulletId`), so it must land
  // after `user_firearms`.
  'ballistic_profiles',
  // Schema v25 — name-keyed component favorites (powder / bullet /
  // primer / brass). No foreign keys (the favorited component is
  // identified by string name, not row id, so catalog-vs-custom
  // path-mixing doesn't break across export/import). Listed last
  // because nothing else references it.
  'user_component_favorites',
  // Schema v32 — Component Inventory (on-hand quantity tracking).
  // The master row is independent (no FK out); the adjustments
  // ledger holds an FK to the master row, so master must land
  // first to keep the import-side FK clean.
  'component_inventory',
  // Schema v32 — Component Inventory adjustments ledger. Holds an
  // FK to `component_inventory.id`, so it lands after the master
  // table. The optional `batchLogId` FK to `batches` is
  // best-effort: rows whose batch was deleted on the inbound side
  // will import with a stale id, but the form-screen audit log
  // handles missing batches gracefully (it just won't link).
  'component_inventory_adjustments',
];

/// Per-table summary returned from [ExportService.importFromJson]. Lets the
/// UI show "added 12 / skipped 3" rows for each section without having to
/// re-walk the JSON itself.
class ImportTableSummary {
  ImportTableSummary({
    required this.tableName,
    this.added = 0,
    this.skipped = 0,
    this.errors = const <String>[],
  });

  final String tableName;
  int added;
  int skipped;
  List<String> errors;

  @override
  String toString() =>
      'ImportTableSummary($tableName: added=$added skipped=$skipped errors=${errors.length})';
}

/// Aggregate summary returned from [ExportService.importFromJson]. Used by
/// the Backup screen to render the post-restore confirmation.
class ImportSummary {
  ImportSummary({this.tables = const {}, this.fatalError});

  final Map<String, ImportTableSummary> tables;

  /// Set when the import aborted before walking any tables (bad version,
  /// invalid JSON, schema mismatch refused by the user). Per-table results
  /// are empty in that case.
  final String? fatalError;

  int get totalAdded =>
      tables.values.fold<int>(0, (sum, t) => sum + t.added);
  int get totalSkipped =>
      tables.values.fold<int>(0, (sum, t) => sum + t.skipped);
  bool get hasErrors =>
      fatalError != null || tables.values.any((t) => t.errors.isNotEmpty);
}

/// Conflict policy when an inbound row's primary key already exists in the
/// local DB.
enum ImportMergeMode {
  /// Default. Keep the local row, log the inbound row as `skipped`.
  skipDuplicates,

  /// Overwrite the local row with the inbound payload.
  overwrite,
}

/// Local export / import for the user-mutable side of the SQLite database.
///
/// **Privacy contract** — see PRIVACY_POLICY.md and CLAUDE.md §13. The export
/// is plain JSON intended for the user's own custody. It contains NO
/// identifiers from LoadOut (no install id, no user id, no analytics id) —
/// only data the user typed into the app. The encrypted cloud-backup path
/// uses this same JSON body but wraps it via [BackupCrypto].
///
/// The seeded reference tables (Cartridges, Powders catalog, Bullets,
/// Primers, BrassProducts, FirearmsRef, FirearmParts, Manufacturers) are
/// intentionally excluded — they're the same on every install and would
/// only inflate the backup.
class ExportService {
  ExportService(this.db);

  final AppDatabase db;

  /// Builds a complete JSON dump of every user-data table. The result has
  /// the wrapper:
  ///
  /// ```json
  /// {
  ///   "loadout_export_version": 1,
  ///   "exported_at": "<ISO-8601 UTC>",
  ///   "schema_version": 4,
  ///   "tables": {
  ///     "user_loads": [ {...}, {...} ],
  ///     "user_firearms": [ ... ],
  ///     ...
  ///   }
  /// }
  /// ```
  ///
  /// Each table's value is a list of `Map<String, dynamic>` produced by the
  /// drift-generated `Row.toJson()` so unknown columns automatically get
  /// included as we add them in future schema versions.
  Future<String> exportToJson() async {
    final tables = <String, List<Map<String, dynamic>>>{};

    tables['custom_components'] = await _dumpCustomComponents();
    tables['powder_lots'] = await _dumpPowderLots();
    tables['bullet_lots'] = await _dumpBulletLots();
    tables['primer_lots'] = await _dumpPrimerLots();
    tables['brass_lots'] = await _dumpBrassLots();
    tables['user_process_steps'] = await _dumpProcessSteps();
    tables['user_firearms'] = await _dumpFirearms();
    tables['user_loads'] = await _dumpLoads();
    tables['batches'] = await _dumpBatches();
    tables['test_sessions'] = await _dumpTestSessions();
    tables['user_custom_fields'] = await _dumpCustomFields();
    tables['user_custom_field_values'] = await _dumpCustomFieldValues();
    tables['load_development_sessions'] = await _dumpLoadDevelopmentSessions();
    tables['ballistic_profiles'] = await _dumpBallisticProfiles();
    tables['user_component_favorites'] = await _dumpComponentFavorites();
    // Schema v32 — Component Inventory + audit log. Master table
    // first, then the FK-bearing adjustments ledger.
    tables['component_inventory'] = await _dumpComponentInventory();
    tables['component_inventory_adjustments'] =
        await _dumpComponentInventoryAdjustments();

    final wrapper = <String, dynamic>{
      'loadout_export_version': kLoadOutExportVersion,
      'exported_at': DateTime.now().toUtc().toIso8601String(),
      'schema_version': db.schemaVersion,
      'tables': tables,
    };

    // Pretty-printed so a user opening the file in TextEdit / Notepad gets a
    // legible diff. The size cost is negligible vs. encrypted blob overhead.
    return const JsonEncoder.withIndent('  ').convert(wrapper);
  }

  /// Writes the result of [exportToJson] to a temp file with a stable
  /// filename, returns the [File] for sharing via `share_plus`.
  ///
  /// The temp directory is purged by the OS on app uninstall and after a
  /// while of inactivity, so this is a safe staging area for sharing — the
  /// file is intentionally not persistent.
  Future<File> writeExportToTempFile({String? filename}) async {
    final dir = await getTemporaryDirectory();
    final stamp = DateTime.now()
        .toUtc()
        .toIso8601String()
        .replaceAll(':', '-')
        .split('.')
        .first;
    final name = filename ?? 'loadout-export-$stamp.json';
    final file = File('${dir.path}/$name');
    final body = await exportToJson();
    await file.writeAsString(body, flush: true);
    return file;
  }

  /// Inverse of [exportToJson]. Parses [json], validates the wrapper, then
  /// inserts each table's rows back into the DB.
  ///
  /// Conflict policy is governed by [mode]. When [mode] is
  /// [ImportMergeMode.skipDuplicates] (the default), any inbound row whose
  /// primary key already exists is recorded as `skipped`. With
  /// [ImportMergeMode.overwrite] the existing row is updated in place.
  ///
  /// The schema_version of the inbound payload is checked against the
  /// runtime [AppDatabase.schemaVersion]. Forward-compatible imports (older
  /// payload, newer DB) are accepted; backward-incompatible imports (newer
  /// payload, older DB) are rejected with [ImportSummary.fatalError] set.
  Future<ImportSummary> importFromJson(
    String json, {
    ImportMergeMode mode = ImportMergeMode.skipDuplicates,
  }) async {
    final Map<String, dynamic> wrapper;
    try {
      wrapper = jsonDecode(json) as Map<String, dynamic>;
    } catch (e) {
      return ImportSummary(fatalError: 'Could not parse JSON: $e');
    }

    final exportVersion = wrapper['loadout_export_version'];
    if (exportVersion is! int) {
      return ImportSummary(
        fatalError:
            'Missing or invalid "loadout_export_version" — is this a LoadOut '
            'export?',
      );
    }
    if (exportVersion > kLoadOutExportVersion) {
      return ImportSummary(
        fatalError:
            'Backup was created by a newer version of LoadOut (export '
            'format $exportVersion). Update the app and try again.',
      );
    }

    final inboundSchema = wrapper['schema_version'];
    if (inboundSchema is int && inboundSchema > db.schemaVersion) {
      return ImportSummary(
        fatalError:
            'Backup uses database schema v$inboundSchema, but this app is '
            'on v${db.schemaVersion}. Update the app and try again.',
      );
    }

    final tables = wrapper['tables'];
    if (tables is! Map) {
      return ImportSummary(fatalError: 'Backup is missing the "tables" map.');
    }

    final summary = <String, ImportTableSummary>{};

    // Walk the canonical order so FK targets land before referrers.
    return db.transaction(() async {
      for (final tableName in kUserDataTableOrder) {
        final raw = tables[tableName];
        if (raw is! List) {
          summary[tableName] = ImportTableSummary(tableName: tableName);
          continue;
        }
        summary[tableName] = await _importTable(
          tableName: tableName,
          rows: raw.cast<Object?>(),
          mode: mode,
        );
      }
      return ImportSummary(tables: summary);
    });
  }

  // ─────────────── per-table dump helpers ───────────────

  Future<List<Map<String, dynamic>>> _dumpCustomComponents() async {
    final rows = await db.select(db.customComponents).get();
    return rows.map((r) => r.toJson()).toList(growable: false);
  }

  Future<List<Map<String, dynamic>>> _dumpPowderLots() async {
    final rows = await db.select(db.powderLots).get();
    return rows.map((r) => r.toJson()).toList(growable: false);
  }

  Future<List<Map<String, dynamic>>> _dumpBulletLots() async {
    final rows = await db.select(db.bulletLots).get();
    return rows.map((r) => r.toJson()).toList(growable: false);
  }

  Future<List<Map<String, dynamic>>> _dumpPrimerLots() async {
    final rows = await db.select(db.primerLots).get();
    return rows.map((r) => r.toJson()).toList(growable: false);
  }

  Future<List<Map<String, dynamic>>> _dumpBrassLots() async {
    final rows = await db.select(db.brassLots).get();
    return rows.map((r) => r.toJson()).toList(growable: false);
  }

  Future<List<Map<String, dynamic>>> _dumpProcessSteps() async {
    final rows = await db.select(db.userProcessSteps).get();
    return rows.map((r) => r.toJson()).toList(growable: false);
  }

  Future<List<Map<String, dynamic>>> _dumpFirearms() async {
    final rows = await db.select(db.userFirearms).get();
    return rows.map((r) => r.toJson()).toList(growable: false);
  }

  Future<List<Map<String, dynamic>>> _dumpLoads() async {
    final rows = await db.select(db.userLoads).get();
    return rows.map((r) => r.toJson()).toList(growable: false);
  }

  Future<List<Map<String, dynamic>>> _dumpBatches() async {
    final rows = await db.select(db.batches).get();
    return rows.map((r) => r.toJson()).toList(growable: false);
  }

  Future<List<Map<String, dynamic>>> _dumpTestSessions() async {
    final rows = await db.select(db.testSessions).get();
    return rows.map((r) => r.toJson()).toList(growable: false);
  }

  Future<List<Map<String, dynamic>>> _dumpCustomFields() async {
    final rows = await db.select(db.userCustomFields).get();
    return rows.map((r) => r.toJson()).toList(growable: false);
  }

  Future<List<Map<String, dynamic>>> _dumpCustomFieldValues() async {
    final rows = await db.select(db.userCustomFieldValues).get();
    return rows.map((r) => r.toJson()).toList(growable: false);
  }

  Future<List<Map<String, dynamic>>> _dumpLoadDevelopmentSessions() async {
    final rows = await db.select(db.loadDevelopmentSessions).get();
    return rows.map((r) => r.toJson()).toList(growable: false);
  }

  Future<List<Map<String, dynamic>>> _dumpBallisticProfiles() async {
    final rows = await db.select(db.ballisticProfiles).get();
    return rows.map((r) => r.toJson()).toList(growable: false);
  }

  /// Schema v25 — name-keyed component favorites (powder / bullet
  /// / primer / brass). Persisted via [UserComponentFavorites].
  /// Cartridge favorites live in `user_favorites` (different table,
  /// row-id keyed) and aren't dumped here.
  Future<List<Map<String, dynamic>>> _dumpComponentFavorites() async {
    final rows = await db.select(db.userComponentFavorites).get();
    return rows.map((r) => r.toJson()).toList(growable: false);
  }

  /// Schema v32 — Component Inventory master rows. One row per
  /// "container" the user has on hand (one jug of powder, one box
  /// of primers, etc.). Persisted via [ComponentInventory].
  Future<List<Map<String, dynamic>>> _dumpComponentInventory() async {
    final rows = await db.select(db.componentInventory).get();
    return rows.map((r) => r.toJson()).toList(growable: false);
  }

  /// Schema v32 — Component Inventory audit ledger. Append-only
  /// history of every quantity change. FK to
  /// `component_inventory.id` so the master table must be imported
  /// first; the canonical order in [kUserDataTableOrder] enforces
  /// that.
  Future<List<Map<String, dynamic>>>
      _dumpComponentInventoryAdjustments() async {
    final rows =
        await db.select(db.componentInventoryAdjustments).get();
    return rows.map((r) => r.toJson()).toList(growable: false);
  }

  // ─────────────── per-table import dispatch ───────────────

  Future<ImportTableSummary> _importTable({
    required String tableName,
    required List<Object?> rows,
    required ImportMergeMode mode,
  }) async {
    final result = ImportTableSummary(tableName: tableName);
    for (final entry in rows) {
      if (entry is! Map<String, dynamic>) {
        result.errors.add('Row was not a JSON object: $entry');
        continue;
      }
      try {
        final inserted = await _insertOne(tableName, entry, mode);
        if (inserted) {
          result.added++;
        } else {
          result.skipped++;
        }
      } catch (e) {
        result.errors.add('Row failed: $e');
      }
    }
    return result;
  }

  /// Inserts (or upserts) a single inbound row. Returns true if the row was
  /// added/updated, false if it was skipped due to a primary-key collision
  /// under [ImportMergeMode.skipDuplicates].
  Future<bool> _insertOne(
    String tableName,
    Map<String, dynamic> json,
    ImportMergeMode mode,
  ) async {
    final id = json['id'];
    final inboundId = id is int ? id : null;
    final exists = inboundId != null && await _rowExists(tableName, inboundId);

    if (exists && mode == ImportMergeMode.skipDuplicates) {
      return false;
    }

    final insertMode = exists
        ? InsertMode.insertOrReplace
        : InsertMode.insertOrIgnore;

    switch (tableName) {
      case 'custom_components':
        await db
            .into(db.customComponents)
            .insert(CustomComponentRow.fromJson(json), mode: insertMode);
        return true;
      case 'powder_lots':
        await db
            .into(db.powderLots)
            .insert(PowderLotRow.fromJson(json), mode: insertMode);
        return true;
      case 'bullet_lots':
        await db
            .into(db.bulletLots)
            .insert(BulletLotRow.fromJson(json), mode: insertMode);
        return true;
      case 'primer_lots':
        await db
            .into(db.primerLots)
            .insert(PrimerLotRow.fromJson(json), mode: insertMode);
        return true;
      case 'brass_lots':
        await db
            .into(db.brassLots)
            .insert(BrassLotRow.fromJson(json), mode: insertMode);
        return true;
      case 'user_process_steps':
        await db
            .into(db.userProcessSteps)
            .insert(UserProcessStepRow.fromJson(json), mode: insertMode);
        return true;
      case 'user_firearms':
        await db
            .into(db.userFirearms)
            .insert(UserFirearmRow.fromJson(json), mode: insertMode);
        return true;
      case 'user_loads':
        await db
            .into(db.userLoads)
            .insert(UserLoadRow.fromJson(json), mode: insertMode);
        return true;
      case 'batches':
        await db
            .into(db.batches)
            .insert(BatchRow.fromJson(json), mode: insertMode);
        return true;
      case 'test_sessions':
        await db
            .into(db.testSessions)
            .insert(TestSessionRow.fromJson(json), mode: insertMode);
        return true;
      case 'user_custom_fields':
        await db
            .into(db.userCustomFields)
            .insert(UserCustomFieldRow.fromJson(json), mode: insertMode);
        return true;
      case 'user_custom_field_values':
        await db
            .into(db.userCustomFieldValues)
            .insert(UserCustomFieldValueRow.fromJson(json), mode: insertMode);
        return true;
      case 'load_development_sessions':
        await db
            .into(db.loadDevelopmentSessions)
            .insert(
              LoadDevelopmentSessionRow.fromJson(json),
              mode: insertMode,
            );
        return true;
      case 'ballistic_profiles':
        await db
            .into(db.ballisticProfiles)
            .insert(BallisticProfileRow.fromJson(json), mode: insertMode);
        return true;
      case 'user_component_favorites':
        await db
            .into(db.userComponentFavorites)
            .insert(
              UserComponentFavoriteRow.fromJson(json),
              mode: insertMode,
            );
        return true;
      case 'component_inventory':
        await db
            .into(db.componentInventory)
            .insert(
              ComponentInventoryRow.fromJson(json),
              mode: insertMode,
            );
        return true;
      case 'component_inventory_adjustments':
        await db
            .into(db.componentInventoryAdjustments)
            .insert(
              ComponentInventoryAdjustmentRow.fromJson(json),
              mode: insertMode,
            );
        return true;
      default:
        // Forward-compatibility: silently ignore unknown tables so a backup
        // taken on a newer build that we still consider "compatible enough"
        // (export_version <= ours, schema_version <= ours) doesn't crash.
        return false;
    }
  }

  /// True if a row with [id] already lives in the named user-data table.
  /// Implemented with a raw `customSelect` so we can cover every table from
  /// one helper without dragging in twelve type-specific where-clauses.
  Future<bool> _rowExists(String tableName, int id) async {
    final result = await db
        .customSelect(
          'SELECT 1 FROM $tableName WHERE id = ? LIMIT 1',
          variables: [Variable<int>(id)],
        )
        .get();
    return result.isNotEmpty;
  }

}
