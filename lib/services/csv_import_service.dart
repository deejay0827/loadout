// FILE: lib/services/csv_import_service.dart
//
// ============================================================================
// WHAT THIS FILE DOES
// ============================================================================
// Tolerant CSV → recipe importer. Reads a `.csv` file the user picked
// with `file_picker`, parses the header row to figure out which column
// maps to which recipe field, walks the body rows, and inserts each as
// a `UserLoadsCompanion` via `RecipeRepository`.
//
// The parser is intentionally tolerant about column names — Excel
// reloaders use a wide variety of headers and we want the same import
// to work for "Recipe Name", "title", "load name", and "name" without
// asking the user to rename columns. See `_kAliases` for the full
// alias map.
//
// Public surface:
//
//   - `CsvImportService(repo)` — constructor.
//   - `parsePreview(csvText)` — reads only the header + a small sample
//     of body rows, returns a `CsvImportPreview` with the detected
//     column mapping plus a row count. Used by the Backup screen to
//     show "Found 47 rows. Detected columns: ..." before the user
//     commits to the import.
//   - `import(csvText, {onProgress})` — full import. Walks every body
//     row, inserts the ones that have a `name`, returns a
//     `CsvImportResult` with counts of imported / skipped rows and a
//     small list of error messages.
//
// Public types:
//
//   - `CsvImportPreview` — the dry-run result. Lists detected columns
//     (so the UI can show "Recipe Name, Caliber, Powder, Charge (gr),
//     Bullet, Bullet Weight"), total row count, and unrecognised
//     column headers (rendered greyed out so the user can verify
//     nothing they expected to map was missed).
//   - `CsvImportResult` — the post-import counts. `imported` is the
//     number of `UserLoads` rows successfully inserted. `skipped` is
//     rows we couldn't parse (missing recipe name). `errors` carries
//     a small list of human-readable strings (capped at 10) for the
//     UI to show at the end.
//
// ============================================================================
// WHY IT EXISTS IN THE ARCHITECTURE
// ============================================================================
// Survey data: 33% of reloaders who track their loads use Excel. They
// already have the data structured; the friction is "type it all into
// the app." A tolerant CSV importer flips that into a 30-second
// onboarding action.
//
// Tolerance is the differentiator. A strict importer that demanded
// columns be named exactly "powder_charge_gr" would force the user to
// edit their spreadsheet first — which most won't bother doing. The
// alias map is wide enough that any reasonable header lands on the
// right field.
//
// ============================================================================
// WHY THIS IS HARDER THAN IT LOOKS
// ============================================================================
// 1. **Embedded commas + quoted fields.** A naive `String.split(',')`
//    fails on a row like `"Match load, 6.5 CM",6.5 Creedmoor,...`. The
//    parser implements RFC-4180 quoting: double-quoted fields can
//    contain commas, escaped quotes appear as `""` inside, and
//    unquoted fields are taken verbatim. Edge case: trailing
//    whitespace inside quotes is preserved (it might be intentional);
//    outside quotes it's stripped.
//
// 2. **Mixed line endings.** Spreadsheets exported from Windows have
//    `\r\n`; from Mac have `\n`. We split on `\n` and trim trailing
//    `\r` per line, so both work.
//
// 3. **Header normalisation.** Header values are lower-cased,
//    whitespace-collapsed to a single space, and underscores treated
//    as spaces before the alias lookup. So `Powder_Charge` → `powder
//    charge` → matches the alias `'powder charge'`.
//
// 4. **Numeric tolerance.** Numbers may carry a unit suffix in the
//    cell ("41.5gr"). The parser strips known suffixes (`gr`, `grain`,
//    `grains`, `in`, `inches`) before `double.tryParse`. Failing to
//    parse a numeric cell is logged as a warning, not an abort — the
//    rest of the row still imports.
//
// 5. **Skipped rows are not errors.** A row missing a recipe name is
//    counted in `skipped`. A row that contains junk in a numeric cell
//    is still imported (with the bad cell left blank) and the issue
//    is added to `errors`. The Backup screen UI shows both counts.
//
// 6. **Back-pressure on large files.** `import()` accepts an optional
//    `onProgress` callback fired once per row. The Backup screen wires
//    this to a progress indicator so a user importing thousands of
//    rows knows the import is making progress. Without it, the UI
//    would feel frozen.
//
// ============================================================================
// WHO CONSUMES THIS FILE
// ============================================================================
// - lib/screens/backup/backup_screen.dart — "Import from CSV" tile
//   reads a file via `file_picker`, calls `parsePreview` to show the
//   user what was detected, then calls `import` if they confirm.

import 'package:drift/drift.dart' show Value;

import '../database/database.dart';
import '../repositories/recipe_repository.dart';

/// Recipe field that a CSV column can be mapped to.
///
/// Stable names — used as keys in [CsvImportPreview.detectedColumns].
enum CsvField {
  name,
  caliber,
  powder,
  powderChargeGr,
  bullet,
  bulletWeightGr,
  primer,
  brass,
  coal,
  cbto,
  notes,
}

/// Human-readable label for a [CsvField], used in the preview UI.
extension CsvFieldLabel on CsvField {
  String get label {
    switch (this) {
      case CsvField.name:
        return 'Recipe Name';
      case CsvField.caliber:
        return 'Caliber';
      case CsvField.powder:
        return 'Powder';
      case CsvField.powderChargeGr:
        return 'Powder Charge (gr)';
      case CsvField.bullet:
        return 'Bullet';
      case CsvField.bulletWeightGr:
        return 'Bullet Weight (gr)';
      case CsvField.primer:
        return 'Primer';
      case CsvField.brass:
        return 'Brass';
      case CsvField.coal:
        return 'COAL';
      case CsvField.cbto:
        return 'CBTO';
      case CsvField.notes:
        return 'Notes';
    }
  }
}

/// Header alias map. Keys are normalised header strings (lower-case,
/// underscores treated as spaces, whitespace collapsed). Values are the
/// matching [CsvField]. Add aliases here as users send us spreadsheets
/// we couldn't import.
const Map<String, CsvField> _kAliases = {
  // Recipe name
  'name': CsvField.name,
  'recipe': CsvField.name,
  'recipe name': CsvField.name,
  'load': CsvField.name,
  'load name': CsvField.name,
  'title': CsvField.name,
  // Caliber / cartridge
  'caliber': CsvField.caliber,
  'calibre': CsvField.caliber,
  'cartridge': CsvField.caliber,
  'chambering': CsvField.caliber,
  // Powder
  'powder': CsvField.powder,
  'propellant': CsvField.powder,
  // Powder charge
  'charge': CsvField.powderChargeGr,
  'charge gr': CsvField.powderChargeGr,
  'powder charge': CsvField.powderChargeGr,
  'powder charge gr': CsvField.powderChargeGr,
  'grains': CsvField.powderChargeGr,
  'gr': CsvField.powderChargeGr,
  'powder weight': CsvField.powderChargeGr,
  // Bullet
  'bullet': CsvField.bullet,
  'projectile': CsvField.bullet,
  // Bullet weight
  'bullet weight': CsvField.bulletWeightGr,
  'bullet gr': CsvField.bulletWeightGr,
  'bullet grains': CsvField.bulletWeightGr,
  'weight': CsvField.bulletWeightGr,
  'projectile weight': CsvField.bulletWeightGr,
  // Primer
  'primer': CsvField.primer,
  'primer brand': CsvField.primer,
  'primer model': CsvField.primer,
  // Brass
  'brass': CsvField.brass,
  'case': CsvField.brass,
  'cases': CsvField.brass,
  // Cartridge dimensions
  'coal': CsvField.coal,
  'oal': CsvField.coal,
  'overall length': CsvField.coal,
  'cartridge overall length': CsvField.coal,
  'cbto': CsvField.cbto,
  'base to ogive': CsvField.cbto,
  // Notes
  'notes': CsvField.notes,
  'comments': CsvField.notes,
  'comment': CsvField.notes,
  'memo': CsvField.notes,
  'remarks': CsvField.notes,
};

/// Result of a dry-run parse — header detection plus body row count.
/// The Backup screen UI uses this to show the user "Found N rows.
/// Detected columns: ..." before they commit to the import.
class CsvImportPreview {
  CsvImportPreview({
    required this.totalRows,
    required this.detectedColumns,
    required this.unrecognisedHeaders,
    this.fatalError,
  });

  /// Number of body rows in the CSV (excluding the header).
  final int totalRows;

  /// Columns that mapped successfully. Order is the column order in
  /// the source CSV.
  final List<({CsvField field, String header})> detectedColumns;

  /// Headers we couldn't recognise. Shown greyed out in the UI so the
  /// user can spot a typo and either rename the column or accept the
  /// drop.
  final List<String> unrecognisedHeaders;

  /// Set when the CSV is malformed enough that we can't proceed (no
  /// rows, no header, mismatched quotes). UI shows this verbatim.
  final String? fatalError;

  bool get hasFatalError => fatalError != null;

  /// True when at least the recipe-name column was detected. Without
  /// it, every row would be skipped — so we surface the issue early.
  bool get canImport =>
      !hasFatalError &&
      detectedColumns.any((c) => c.field == CsvField.name);
}

/// Result of a real import. Counts imported vs skipped rows and
/// carries a small list of errors (capped) for the post-import UI.
class CsvImportResult {
  CsvImportResult({
    required this.imported,
    required this.skipped,
    required this.errors,
  });

  final int imported;
  final int skipped;

  /// Human-readable issues encountered during import. Capped at 10 so
  /// the UI doesn't have to deal with thousands of identical messages
  /// for a malformed file.
  final List<String> errors;

  bool get hasErrors => errors.isNotEmpty;
}

/// Tolerant CSV → `UserLoads` importer. Stateful only in that it holds
/// the [RecipeRepository] handed in at construction; every call is
/// otherwise self-contained.
class CsvImportService {
  CsvImportService(this.repo);

  final RecipeRepository repo;

  /// Maximum number of error strings retained on a [CsvImportResult].
  /// Beyond this, additional errors are silently dropped — the UI only
  /// has room for a handful and listing thousands of "row 17:
  /// could not parse '41.5gr'" would be useless noise.
  static const int _kMaxErrorsRetained = 10;

  /// Reads the header + counts body rows without writing anything to
  /// the DB. Used to drive the "Found N rows. Detected columns: ..."
  /// preview before the user commits.
  CsvImportPreview parsePreview(String csvText) {
    final List<List<String>> parsed;
    try {
      parsed = _parseRows(csvText);
    } catch (e) {
      return CsvImportPreview(
        totalRows: 0,
        detectedColumns: const [],
        unrecognisedHeaders: const [],
        fatalError: 'Could not parse CSV: $e',
      );
    }
    if (parsed.isEmpty) {
      return CsvImportPreview(
        totalRows: 0,
        detectedColumns: const [],
        unrecognisedHeaders: const [],
        fatalError: 'CSV is empty.',
      );
    }
    final header = parsed.first;
    final detected = <({CsvField field, String header})>[];
    final unrecognised = <String>[];
    final usedFields = <CsvField>{};
    for (final raw in header) {
      final trimmed = raw.trim();
      if (trimmed.isEmpty) {
        unrecognised.add(trimmed);
        continue;
      }
      final field = _kAliases[_normaliseHeader(trimmed)];
      if (field == null || usedFields.contains(field)) {
        unrecognised.add(trimmed);
      } else {
        detected.add((field: field, header: trimmed));
        usedFields.add(field);
      }
    }
    return CsvImportPreview(
      totalRows: parsed.length - 1,
      detectedColumns: detected,
      unrecognisedHeaders: unrecognised,
    );
  }

  /// Parses [csvText], inserts each body row as a recipe, and returns
  /// import counts. Rows missing a recipe-name cell are counted in
  /// `skipped`; rows whose numeric cells fail to parse are still
  /// imported (with the bad cell blank) and recorded in `errors`.
  ///
  /// [onProgress] fires once per row processed (1-based, including
  /// skipped rows). Set [onProgress] to null on small files where
  /// progress updates would just churn UI work.
  Future<CsvImportResult> import(
    String csvText, {
    void Function(int processed, int total)? onProgress,
  }) async {
    final List<List<String>> parsed;
    try {
      parsed = _parseRows(csvText);
    } catch (e) {
      return CsvImportResult(
        imported: 0,
        skipped: 0,
        errors: ['Could not parse CSV: $e'],
      );
    }
    if (parsed.length < 2) {
      return CsvImportResult(
        imported: 0,
        skipped: 0,
        errors: const ['CSV had a header but no data rows.'],
      );
    }
    final header = parsed.first;
    final mapping = <int, CsvField>{};
    final usedFields = <CsvField>{};
    for (var i = 0; i < header.length; i++) {
      final field = _kAliases[_normaliseHeader(header[i].trim())];
      if (field == null || usedFields.contains(field)) continue;
      mapping[i] = field;
      usedFields.add(field);
    }
    if (!mapping.values.contains(CsvField.name)) {
      return CsvImportResult(
        imported: 0,
        skipped: 0,
        errors: const [
          'No recipe-name column was detected. Add a column called '
              '"Name" or "Recipe Name" and try again.',
        ],
      );
    }

    var imported = 0;
    var skipped = 0;
    final errors = <String>[];

    for (var rowIndex = 1; rowIndex < parsed.length; rowIndex++) {
      final row = parsed[rowIndex];
      final companion = _rowToCompanion(row, mapping, rowIndex, errors);
      if (companion == null) {
        skipped++;
      } else {
        try {
          await repo.insert(companion);
          imported++;
        } catch (e) {
          skipped++;
          if (errors.length < _kMaxErrorsRetained) {
            errors.add('Row ${rowIndex + 1} insert failed: $e');
          }
        }
      }
      onProgress?.call(rowIndex, parsed.length - 1);
    }

    return CsvImportResult(
      imported: imported,
      skipped: skipped,
      errors: errors,
    );
  }

  /// Reduce a header value to a canonical form for alias lookup.
  /// `'  Powder_Charge_(GR) '` → `'powder charge gr'`.
  String _normaliseHeader(String raw) {
    final lower = raw.toLowerCase().trim();
    // Replace common noise characters with whitespace, then collapse
    // whitespace to a single space.
    final cleaned = lower.replaceAll(RegExp(r'[_\-()/]'), ' ');
    return cleaned.replaceAll(RegExp(r'\s+'), ' ').trim();
  }

  /// Apply the column mapping to a single row, returning the recipe
  /// companion or null if the row should be skipped (missing name).
  /// Cell-level parse failures get appended to [errors] but do NOT
  /// abort the row.
  UserLoadsCompanion? _rowToCompanion(
    List<String> row,
    Map<int, CsvField> mapping,
    int rowIndex,
    List<String> errors,
  ) {
    String? name;
    String? caliber;
    String? powder;
    String? bullet;
    String? primer;
    String? brass;
    String? notes;
    double? powderChargeGr;
    double? bulletWeightGr;
    double? coalIn;
    double? cbtoIn;

    for (var col = 0; col < row.length; col++) {
      final field = mapping[col];
      if (field == null) continue;
      final raw = row[col].trim();
      if (raw.isEmpty) continue;
      switch (field) {
        case CsvField.name:
          name = raw;
        case CsvField.caliber:
          caliber = raw;
        case CsvField.powder:
          powder = raw;
        case CsvField.powderChargeGr:
          powderChargeGr = _parseNumeric(raw);
          if (powderChargeGr == null && errors.length < _kMaxErrorsRetained) {
            errors.add(
                'Row ${rowIndex + 1}: could not parse charge "$raw"');
          }
        case CsvField.bullet:
          bullet = raw;
        case CsvField.bulletWeightGr:
          bulletWeightGr = _parseNumeric(raw);
          if (bulletWeightGr == null &&
              errors.length < _kMaxErrorsRetained) {
            errors.add(
                'Row ${rowIndex + 1}: could not parse bullet weight "$raw"');
          }
        case CsvField.primer:
          primer = raw;
        case CsvField.brass:
          brass = raw;
        case CsvField.coal:
          coalIn = _parseNumeric(raw);
        case CsvField.cbto:
          cbtoIn = _parseNumeric(raw);
        case CsvField.notes:
          notes = raw;
      }
    }
    if (name == null || name.isEmpty) return null;
    return UserLoadsCompanion(
      name: Value(name),
      caliber: Value(caliber),
      powder: Value(powder),
      powderChargeGr: Value(powderChargeGr),
      bullet: Value(bullet),
      bulletWeightGr: Value(bulletWeightGr),
      primer: Value(primer),
      brass: Value(brass),
      coalIn: Value(coalIn),
      cbtoIn: Value(cbtoIn),
      notes: Value(notes),
    );
  }

  /// Strip a trailing unit suffix and parse what remains as a double.
  /// Returns null on failure. Tolerates `41.5gr`, `41.5 grain`,
  /// `41.5 grains`, `2.800in`, `2.800 inches`.
  double? _parseNumeric(String raw) {
    var s = raw.trim();
    // Strip common unit suffixes case-insensitively.
    s = s.replaceFirst(
      RegExp(r'(grains|grain|gr|inches|in)\s*$', caseSensitive: false),
      '',
    );
    s = s.trim();
    if (s.isEmpty) return null;
    return double.tryParse(s);
  }

  /// Tokenise [csvText] into a `List<List<String>>` honouring
  /// double-quoted fields (RFC-4180-ish). Trims trailing `\r` from
  /// each line so Windows line endings work. Throws on truly broken
  /// input (unterminated quoted field at EOF).
  List<List<String>> _parseRows(String csvText) {
    final rows = <List<String>>[];
    var current = <String>[];
    final buf = StringBuffer();
    var inQuotes = false;
    var i = 0;
    while (i < csvText.length) {
      final ch = csvText[i];
      if (inQuotes) {
        if (ch == '"') {
          // Lookahead: an escaped `""` inside a quoted field becomes
          // a literal `"`.
          if (i + 1 < csvText.length && csvText[i + 1] == '"') {
            buf.write('"');
            i += 2;
            continue;
          }
          inQuotes = false;
          i++;
          continue;
        }
        buf.write(ch);
        i++;
      } else {
        if (ch == '"') {
          inQuotes = true;
          i++;
        } else if (ch == ',') {
          current.add(buf.toString());
          buf.clear();
          i++;
        } else if (ch == '\n') {
          var cell = buf.toString();
          // Strip trailing \r left over from CRLF endings.
          if (cell.isNotEmpty && cell.endsWith('\r')) {
            cell = cell.substring(0, cell.length - 1);
          }
          current.add(cell);
          buf.clear();
          if (!_isAllEmpty(current)) {
            rows.add(current);
          }
          current = <String>[];
          i++;
        } else if (ch == '\r') {
          // Standalone \r (Mac classic). Treat the same as \n.
          current.add(buf.toString());
          buf.clear();
          if (!_isAllEmpty(current)) {
            rows.add(current);
          }
          current = <String>[];
          // Skip a following \n if this was actually \r\n.
          if (i + 1 < csvText.length && csvText[i + 1] == '\n') {
            i += 2;
          } else {
            i++;
          }
        } else {
          buf.write(ch);
          i++;
        }
      }
    }
    if (inQuotes) {
      throw const FormatException(
        'Unterminated quoted field. Make sure every " has a matching close.',
      );
    }
    // Flush whatever's left as the trailing row.
    var lastCell = buf.toString();
    if (lastCell.isNotEmpty && lastCell.endsWith('\r')) {
      lastCell = lastCell.substring(0, lastCell.length - 1);
    }
    if (lastCell.isNotEmpty || current.isNotEmpty) {
      current.add(lastCell);
      if (!_isAllEmpty(current)) {
        rows.add(current);
      }
    }
    return rows;
  }

  bool _isAllEmpty(List<String> row) {
    for (final cell in row) {
      if (cell.trim().isNotEmpty) return false;
    }
    return true;
  }
}
