// FILE: lib/services/spreadsheet_import_service.dart
//
// ============================================================================
// WHAT THIS FILE DOES
// ============================================================================
// Smart spreadsheet importer for `.csv` and `.xlsx` files. Replaces the
// simple-alias `CsvImportService` with a flow that:
//
//   1. Parses any spreadsheet — CSV or Excel — into a normalized
//      `List<List<String>>` grid of cells.
//   2. Returns a `SpreadsheetPreview` describing the headers, the first
//      few sample rows, the auto-suggested mapping per column, and any
//      unmapped headers.
//   3. Given a user-confirmed mapping, walks the rows and inserts each
//      as a `UserLoadsCompanion` via `RecipeRepository`.
//
// The auto-suggester combines:
//   - **Alias dictionaries** per recipe field (the same kind of map the
//     legacy CSV importer used, but now scored continuously instead of
//     bucketed all-or-nothing).
//   - **Jaro-Winkler similarity** for fuzzy header matching ("Crg." →
//     "charge", "Bullet Mfr" → "bullet"). Implemented inline because
//     the algorithm is short.
//
// Each column gets a confidence score in [0..1]; we pick the best match
// per field, fall back to "don't import" when the best score < 0.6, and
// expose all of that to the UI so the user can override.
//
// Public surface:
//
//   - `SpreadsheetImportService(repo)` — repository handle.
//   - `parsePreview(file)` — async; reads the file, returns a
//     `SpreadsheetPreview` with the grid + suggested mapping.
//   - `importRows(...)` — async; given the user's confirmed mapping,
//     walks every body row and inserts into UserLoads. Returns
//     `SpreadsheetImportResult` (counts + errors).
//   - `kFieldOptions` / `FieldOption` — the catalog of recipe fields the
//     UI shows in the dropdowns. Stable IDs persisted in saved
//     mappings.
//
// ============================================================================
// WHY IT EXISTS IN THE ARCHITECTURE
// ============================================================================
// 33% of reloaders track loads in Excel; almost every one of them has
// idiosyncratic column names ("Crg gr", "Loadname", "Bullet Make") that
// the strict CSV importer can't auto-detect. Forcing a user to rename
// columns before they can try the app is a stiff conversion barrier.
// Smart Import flips that into a 30-second flow: pick file → confirm
// the suggested mapping → done.
//
// Feature is intentionally **free**, not Pro-gated. The point is to
// remove a conversion barrier — gating it would defeat the purpose.
//
// ============================================================================
// WHY THIS IS HARDER THAN IT LOOKS
// ============================================================================
// 1. **Two parsers behind one façade.** CSV uses RFC-4180 quoting (we
//    own the parser). XLSX uses the `excel` package, which returns
//    typed `Data?` cells; we coerce everything to a `String` using the
//    same rules a human would write into a CSV (numbers stringified
//    without trailing zeroes, dates as `YYYY-MM-DD`).
//
// 2. **Headers may not be on row 1.** Some Excel sheets carry a logo,
//    a metadata block, or a printed-style title row. The mapping UI
//    lets the user pick a header row index; the parser normalizes
//    around that.
//
// 3. **Column collisions.** If a user maps two columns to the same
//    field, the LATER column wins. We don't surface that as an error
//    because there's a perfectly valid case (their sheet has both
//    "Charge" and "Charge gr" containing the same data) and forcing
//    them to "fix" it would be friction.
//
// 4. **Tolerant numeric parsing.** "41.5gr", "41.5 grains", "  41.5 ",
//    "2.825" all parse to the right double. Non-numeric strings like
//    "varies" yield null + a warning, not a row abort.
//
// 5. **No dependency on the catalog.** The user can map a column to
//    `caliber` even if no row matches an existing reference cartridge.
//    The recipe form already accepts custom strings, so we just write
//    the literal string.
//
// 6. **Saved mappings are per-file-shape.** We hash the *normalized
//    header row* (lower-cased + trimmed + joined with commas) and use
//    that as a key in `csv_mapping_<headerHash>`. So re-importing a
//    file with the same column structure auto-loads the user's last
//    confirmed mapping.
//
// 7. **Presets are user-named templates.** A user who imports the same
//    file shape every month can save the mapping as
//    "My Excel Loads Template" and pick it from a list next time. Stored
//    as JSON under SharedPreferences key `import_mapping_presets`.
//
// ============================================================================
// WHO CONSUMES THIS FILE
// ============================================================================
// - lib/screens/recipes/smart_import_screen.dart — the wizard UI.
// - test/spreadsheet_import_service_test.dart — round-trip CSV test.
//
// ============================================================================
// SIDE EFFECTS
// ============================================================================
// - Reads `file.readAsBytes()` for XLSX and `file.readAsString()` for
//   CSV (with a latin-1 fallback for CP-1252 Excel exports).
// - Writes new `UserLoads` rows via `RecipeRepository.insert`.
// - `loadSavedMappingFor(file)` and `saveMappingFor(file, mapping)`
//   touch SharedPreferences. `loadPresets` / `savePreset` /
//   `deletePreset` touch SharedPreferences.

import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:excel/excel.dart' as xlsx;
import 'package:shared_preferences/shared_preferences.dart';

import '../database/database.dart';
import '../repositories/recipe_repository.dart';

/// Stable identifier for one of our destination recipe fields. Kept as
/// a string so saved mappings survive enum reordering and so the UI can
/// stash `FieldId? -> column index` maps in JSON.
class FieldId {
  const FieldId._(this.id);

  final String id;

  static const FieldId name = FieldId._('name');
  static const FieldId caliber = FieldId._('caliber');
  static const FieldId powder = FieldId._('powder');
  static const FieldId powderChargeGr = FieldId._('powderChargeGr');
  static const FieldId chargeToleranceGr = FieldId._('chargeToleranceGr');
  static const FieldId bullet = FieldId._('bullet');
  static const FieldId bulletWeightGr = FieldId._('bulletWeightGr');
  static const FieldId bulletLengthIn = FieldId._('bulletLengthIn');
  static const FieldId primer = FieldId._('primer');
  static const FieldId brass = FieldId._('brass');
  static const FieldId coalIn = FieldId._('coalIn');
  static const FieldId cbtoIn = FieldId._('cbtoIn');
  static const FieldId seatingDepthIn = FieldId._('seatingDepthIn');
  static const FieldId primerDepthCps = FieldId._('primerDepthCps');
  static const FieldId shoulderBumpIn = FieldId._('shoulderBumpIn');
  static const FieldId mandrelSizeIn = FieldId._('mandrelSizeIn');
  static const FieldId distanceToLandsIn = FieldId._('distanceToLandsIn');
  static const FieldId jumpToLandsIn = FieldId._('jumpToLandsIn');
  static const FieldId loadedNeckDiameterIn = FieldId._('loadedNeckDiameterIn');
  static const FieldId bulletRunoutTirIn = FieldId._('bulletRunoutTirIn');
  static const FieldId bushingSizeIn = FieldId._('bushingSizeIn');
  static const FieldId useCase = FieldId._('useCase');
  static const FieldId status = FieldId._('status');
  static const FieldId pressUsed = FieldId._('pressUsed');
  static const FieldId sizingDieUsed = FieldId._('sizingDieUsed');
  static const FieldId seatingDieUsed = FieldId._('seatingDieUsed');
  static const FieldId scaleUsed = FieldId._('scaleUsed');
  static const FieldId chronographUsed = FieldId._('chronographUsed');
  static const FieldId loadedBy = FieldId._('loadedBy');
  static const FieldId loadingDate = FieldId._('loadingDate');
  static const FieldId dateEstablished = FieldId._('dateEstablished');
  static const FieldId notes = FieldId._('notes');

  static const List<FieldId> all = [
    name,
    caliber,
    powder,
    powderChargeGr,
    chargeToleranceGr,
    bullet,
    bulletWeightGr,
    bulletLengthIn,
    primer,
    brass,
    coalIn,
    cbtoIn,
    seatingDepthIn,
    primerDepthCps,
    shoulderBumpIn,
    mandrelSizeIn,
    distanceToLandsIn,
    jumpToLandsIn,
    loadedNeckDiameterIn,
    bulletRunoutTirIn,
    bushingSizeIn,
    useCase,
    status,
    pressUsed,
    sizingDieUsed,
    seatingDieUsed,
    scaleUsed,
    chronographUsed,
    loadedBy,
    loadingDate,
    dateEstablished,
    notes,
  ];

  static FieldId? byId(String? id) {
    if (id == null) return null;
    for (final f in all) {
      if (f.id == id) return f;
    }
    return null;
  }

  @override
  bool operator ==(Object other) => other is FieldId && other.id == id;

  @override
  int get hashCode => id.hashCode;
}

/// UI metadata for a `FieldId`. Used by the mapping screen to render
/// the dropdown labels and lookup the per-field aliases.
class FieldOption {
  const FieldOption({
    required this.id,
    required this.label,
    required this.aliases,
    this.isNumeric = false,
    this.unitSuffix,
    this.required = false,
    this.hint,
  });

  final FieldId id;
  final String label;

  /// Aliases the auto-suggester scores incoming column names against.
  final List<String> aliases;

  /// True for fields that must be coerced to a `double`.
  final bool isNumeric;

  /// Optional unit suffix (e.g. "gr", "in") shown alongside the label
  /// to clarify expected units.
  final String? unitSuffix;

  /// True for `name` — without it we can't insert any rows.
  final bool required;

  /// Optional one-liner hint shown under the dropdown.
  final String? hint;
}

/// Catalog of every field a column can be mapped to. Order influences
/// the dropdown sort order in the UI; required first, then most-common,
/// then detailed.
final List<FieldOption> kFieldOptions = [
  const FieldOption(
    id: FieldId.name,
    label: 'Recipe Name',
    aliases: [
      'recipe',
      'name',
      'title',
      'load',
      'load name',
      'recipe name',
      'load id',
      'loadname',
    ],
    required: true,
    hint: 'Required — every imported recipe needs a name.',
  ),
  const FieldOption(
    id: FieldId.caliber,
    label: 'Caliber',
    aliases: [
      'caliber',
      'calibre',
      'cal',
      'cartridge',
      'chambering',
      'cartridge type',
    ],
  ),
  const FieldOption(
    id: FieldId.powder,
    label: 'Powder',
    aliases: [
      'powder',
      'pwdr',
      'pdr',
      'propellant',
      'powder type',
      'powder brand',
    ],
  ),
  const FieldOption(
    id: FieldId.powderChargeGr,
    label: 'Powder Charge',
    aliases: [
      'charge',
      'charge gr',
      'grains',
      'gr',
      'powder charge',
      'powder weight',
      'powder grains',
      'crg',
      'crg gr',
    ],
    isNumeric: true,
    unitSuffix: 'gr',
  ),
  const FieldOption(
    id: FieldId.chargeToleranceGr,
    label: 'Charge Tolerance',
    aliases: ['charge tolerance', 'charge tol', 'powder tolerance'],
    isNumeric: true,
    unitSuffix: 'gr',
  ),
  const FieldOption(
    id: FieldId.bullet,
    label: 'Bullet',
    aliases: [
      'bullet',
      'bllt',
      'blt',
      'projectile',
      'proj',
      'bullet brand',
      'bullet name',
    ],
  ),
  const FieldOption(
    id: FieldId.bulletWeightGr,
    label: 'Bullet Weight',
    aliases: [
      'bullet weight',
      'bullet gr',
      'weight',
      'wt',
      'bullet wt',
      'projectile weight',
      'proj weight',
      'bullet grains',
    ],
    isNumeric: true,
    unitSuffix: 'gr',
  ),
  const FieldOption(
    id: FieldId.bulletLengthIn,
    label: 'Bullet Length',
    aliases: ['bullet length', 'projectile length', 'bullet len'],
    isNumeric: true,
    unitSuffix: 'in',
  ),
  const FieldOption(
    id: FieldId.primer,
    label: 'Primer',
    aliases: [
      'primer',
      'prmr',
      'prim',
      'primer brand',
      'primer model',
      'primer type',
    ],
  ),
  const FieldOption(
    id: FieldId.brass,
    label: 'Brass',
    aliases: ['brass', 'case', 'cases', 'brass brand', 'brass mfr'],
  ),
  const FieldOption(
    id: FieldId.coalIn,
    label: 'COAL',
    aliases: [
      'coal',
      'oal',
      'overall length',
      'cartridge oal',
      'cartridge overall length',
      'col',
    ],
    isNumeric: true,
    unitSuffix: 'in',
  ),
  const FieldOption(
    id: FieldId.cbtoIn,
    label: 'CBTO',
    aliases: [
      'cbto',
      'base to ogive',
      'bto',
      'cartridge base to ogive',
    ],
    isNumeric: true,
    unitSuffix: 'in',
  ),
  const FieldOption(
    id: FieldId.seatingDepthIn,
    label: 'Seating Depth',
    aliases: ['seating depth', 'seat depth', 'seater depth'],
    isNumeric: true,
    unitSuffix: 'in',
  ),
  const FieldOption(
    id: FieldId.primerDepthCps,
    label: 'Primer Depth',
    aliases: ['primer depth', 'primer seating depth'],
    isNumeric: true,
    unitSuffix: 'thou',
  ),
  const FieldOption(
    id: FieldId.shoulderBumpIn,
    label: 'Shoulder Bump',
    aliases: ['shoulder bump', 'bump'],
    isNumeric: true,
    unitSuffix: 'in',
  ),
  const FieldOption(
    id: FieldId.mandrelSizeIn,
    label: 'Mandrel Size',
    aliases: ['mandrel', 'mandrel size'],
    isNumeric: true,
    unitSuffix: 'in',
  ),
  const FieldOption(
    id: FieldId.distanceToLandsIn,
    label: 'Distance to Lands',
    aliases: ['distance to lands', 'dist to lands'],
    isNumeric: true,
    unitSuffix: 'in',
  ),
  const FieldOption(
    id: FieldId.jumpToLandsIn,
    label: 'Jump to Lands',
    aliases: ['jump to lands', 'jump'],
    isNumeric: true,
    unitSuffix: 'in',
  ),
  const FieldOption(
    id: FieldId.loadedNeckDiameterIn,
    label: 'Loaded Neck Diameter',
    aliases: ['loaded neck diameter', 'neck diameter loaded'],
    isNumeric: true,
    unitSuffix: 'in',
  ),
  const FieldOption(
    id: FieldId.bulletRunoutTirIn,
    label: 'Bullet Runout (TIR)',
    aliases: ['runout', 'bullet runout', 'tir'],
    isNumeric: true,
    unitSuffix: 'in',
  ),
  const FieldOption(
    id: FieldId.bushingSizeIn,
    label: 'Bushing Size',
    aliases: ['bushing', 'bushing size'],
    isNumeric: true,
    unitSuffix: 'in',
  ),
  const FieldOption(
    id: FieldId.useCase,
    label: 'Use Case',
    aliases: ['use case', 'purpose', 'use'],
    hint: 'e.g. match, practice, hunting, plinking',
  ),
  const FieldOption(
    id: FieldId.status,
    label: 'Status',
    aliases: ['status', 'state'],
    hint: 'active / testing / retired',
  ),
  const FieldOption(
    id: FieldId.pressUsed,
    label: 'Press',
    aliases: ['press', 'press used'],
  ),
  const FieldOption(
    id: FieldId.sizingDieUsed,
    label: 'Sizing Die',
    aliases: ['sizing die', 'size die'],
  ),
  const FieldOption(
    id: FieldId.seatingDieUsed,
    label: 'Seating Die',
    aliases: ['seating die', 'seater die'],
  ),
  const FieldOption(
    id: FieldId.scaleUsed,
    label: 'Scale',
    aliases: ['scale', 'scale used', 'powder scale'],
  ),
  const FieldOption(
    id: FieldId.chronographUsed,
    label: 'Chronograph',
    aliases: ['chronograph', 'chrono', 'chronograph used'],
  ),
  const FieldOption(
    id: FieldId.loadedBy,
    label: 'Loaded By',
    aliases: ['loaded by', 'loader', 'reloader'],
  ),
  const FieldOption(
    id: FieldId.loadingDate,
    label: 'Loading Date',
    aliases: [
      'loading date',
      'date loaded',
      'load date',
      'date',
      'loaded on',
    ],
    hint: 'When this batch was assembled.',
  ),
  const FieldOption(
    id: FieldId.dateEstablished,
    label: 'Date Established',
    aliases: ['date established', 'first loaded', 'first developed'],
    hint: 'When you first developed this load.',
  ),
  const FieldOption(
    id: FieldId.notes,
    label: 'Notes',
    aliases: ['notes', 'comments', 'comment', 'memo', 'remarks', 'observation'],
    hint: 'Anything else you want to remember about this load.',
  ),
];

/// Fast lookup `FieldId -> FieldOption` to render the mapping UI.
final Map<FieldId, FieldOption> kFieldById = {
  for (final f in kFieldOptions) f.id: f,
};

/// Outcome of `parsePreview`. Ready to drive the mapping wizard.
class SpreadsheetPreview {
  SpreadsheetPreview({
    required this.headers,
    required this.sampleRows,
    required this.totalDataRows,
    required this.suggestions,
    required this.headerSignature,
    this.fatalError,
  });

  /// Header values (from the chosen header row), in column order.
  final List<String> headers;

  /// First ~5 data rows after the header, padded to header.length.
  final List<List<String>> sampleRows;

  /// Number of data rows below the header (excluding empty rows).
  final int totalDataRows;

  /// Auto-suggested mapping per column, with a confidence score.
  /// Indexed by column index. Score < 0.6 means "show as 'Don't import'
  /// by default."
  final List<MappingSuggestion> suggestions;

  /// Stable hash of the header row used to look up saved mappings for
  /// files of the same shape.
  final String headerSignature;

  final String? fatalError;

  bool get hasFatalError => fatalError != null;
}

class MappingSuggestion {
  MappingSuggestion({
    required this.header,
    required this.suggestedField,
    required this.confidence,
    required this.alternatives,
  });

  /// The original (verbatim) header value the column carries.
  final String header;

  /// Best-match field, or null when nothing crossed the threshold.
  final FieldId? suggestedField;

  /// Confidence score in [0..1] for `suggestedField`.
  final double confidence;

  /// Top runners-up (excluding the chosen one), each with their score.
  /// Useful for the UI "did you mean ...?" affordance.
  final List<({FieldId field, double score})> alternatives;
}

/// Outcome of `importRows`. Counts plus capped error list.
class SpreadsheetImportResult {
  SpreadsheetImportResult({
    required this.imported,
    required this.skipped,
    required this.errors,
  });

  final int imported;
  final int skipped;
  final List<String> errors;

  bool get hasErrors => errors.isNotEmpty;
}

/// File-shape preset the user named ("My Excel Loads"). Stored in
/// SharedPreferences as a JSON list under `import_mapping_presets`.
class ImportMappingPreset {
  ImportMappingPreset({
    required this.id,
    required this.name,
    required this.headerToField,
    this.headerSignature,
  });

  final String id;
  String name;

  /// Header label (verbatim from the spreadsheet) -> destination field.
  /// Headers that mapped to "don't import" are simply absent.
  final Map<String, FieldId> headerToField;

  /// Optional file-shape signature so we can auto-pick this preset on a
  /// matching file.
  String? headerSignature;

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'headerSignature': headerSignature,
        'headerToField': {
          for (final e in headerToField.entries) e.key: e.value.id,
        },
      };

  static ImportMappingPreset? fromJson(Map<String, dynamic> json) {
    final id = json['id'];
    final name = json['name'];
    if (id is! String || name is! String) return null;
    final raw = json['headerToField'];
    if (raw is! Map) return null;
    final mapping = <String, FieldId>{};
    for (final entry in raw.entries) {
      final field = FieldId.byId(entry.value as String?);
      if (field != null) mapping[entry.key as String] = field;
    }
    final signature = json['headerSignature'];
    return ImportMappingPreset(
      id: id,
      name: name,
      headerToField: mapping,
      headerSignature: signature is String ? signature : null,
    );
  }
}

/// CSV / XLSX import service. Stateless aside from the [RecipeRepository]
/// handed in at construction.
class SpreadsheetImportService {
  SpreadsheetImportService(this.repo);

  final RecipeRepository repo;

  /// Cap on retained per-row error strings so the UI doesn't try to
  /// render thousands of warnings on a malformed file.
  static const int _maxErrorsRetained = 25;

  /// Maximum sample rows shown in the preview wizard.
  static const int _maxSampleRows = 5;

  static const String _kPresetsKey = 'import_mapping_presets';

  // ─────────── public API ───────────

  /// Reads the file and returns a preview ready for the mapping UI.
  /// Uses the file extension to choose between the CSV and XLSX
  /// parsers.
  Future<SpreadsheetPreview> parsePreview(
    File file, {
    int headerRowIndex = 0,
    int skipAfterHeader = 0,
  }) async {
    final ext = _extensionOf(file);
    List<List<String>> rows;
    try {
      rows = ext == 'xlsx'
          ? await _parseXlsx(file)
          : await _parseCsv(file);
    } catch (e) {
      return SpreadsheetPreview(
        headers: const [],
        sampleRows: const [],
        totalDataRows: 0,
        suggestions: const [],
        headerSignature: '',
        fatalError: 'Could not read file: $e',
      );
    }
    if (rows.length <= headerRowIndex) {
      return SpreadsheetPreview(
        headers: const [],
        sampleRows: const [],
        totalDataRows: 0,
        suggestions: const [],
        headerSignature: '',
        fatalError: 'File has no data on row ${headerRowIndex + 1}.',
      );
    }
    final headers = rows[headerRowIndex]
        .map((s) => s.trim())
        .toList(growable: false);
    final dataStart = headerRowIndex + 1 + skipAfterHeader;
    final dataRows = <List<String>>[];
    for (var i = dataStart; i < rows.length; i++) {
      final r = rows[i];
      if (_isAllEmpty(r)) continue;
      // Pad / trim to header length so column indexing is stable.
      final padded = List<String>.filled(headers.length, '');
      for (var c = 0; c < headers.length && c < r.length; c++) {
        padded[c] = r[c];
      }
      dataRows.add(padded);
    }
    final sampleRows = dataRows.take(_maxSampleRows).toList(growable: false);
    final suggestions = _buildSuggestions(headers);
    final signature = _signatureForHeaders(headers);
    return SpreadsheetPreview(
      headers: headers,
      sampleRows: sampleRows,
      totalDataRows: dataRows.length,
      suggestions: suggestions,
      headerSignature: signature,
    );
  }

  /// Parse the file again and ingest using the user-confirmed mapping.
  ///
  /// `mapping` is `headerLabel -> FieldId`. Headers absent from the
  /// map are treated as "don't import this column."
  ///
  /// `onProgress` (optional) fires once per processed row.
  Future<SpreadsheetImportResult> importRows({
    required File file,
    required Map<String, FieldId> mapping,
    int headerRowIndex = 0,
    int skipAfterHeader = 0,
    void Function(int processed, int total)? onProgress,
  }) async {
    final ext = _extensionOf(file);
    List<List<String>> rows;
    try {
      rows = ext == 'xlsx' ? await _parseXlsx(file) : await _parseCsv(file);
    } catch (e) {
      return SpreadsheetImportResult(
        imported: 0,
        skipped: 0,
        errors: ['Could not read file: $e'],
      );
    }
    if (rows.length <= headerRowIndex + 1) {
      return SpreadsheetImportResult(
        imported: 0,
        skipped: 0,
        errors: const ['File has a header but no data rows.'],
      );
    }
    final headers =
        rows[headerRowIndex].map((s) => s.trim()).toList(growable: false);

    // header-label -> column-index lookup. If a header repeats, the
    // last occurrence wins (mirrors the column-collision rule above).
    final colByHeader = <String, int>{};
    for (var i = 0; i < headers.length; i++) {
      colByHeader[headers[i]] = i;
    }
    // column-index -> FieldId
    final colToField = <int, FieldId>{};
    for (final entry in mapping.entries) {
      final col = colByHeader[entry.key];
      if (col == null) continue;
      colToField[col] = entry.value;
    }
    if (!colToField.values.contains(FieldId.name)) {
      return SpreadsheetImportResult(
        imported: 0,
        skipped: 0,
        errors: const [
          'Mapping is missing a Recipe Name column. Pick one and retry.',
        ],
      );
    }

    final dataStart = headerRowIndex + 1 + skipAfterHeader;
    final total = rows.length - dataStart;
    var processed = 0;
    var imported = 0;
    var skipped = 0;
    final errors = <String>[];

    for (var i = dataStart; i < rows.length; i++) {
      processed++;
      final row = rows[i];
      if (_isAllEmpty(row)) {
        // Skip blank rows silently — common in Excel sheets that pad
        // out the bottom of the table.
        onProgress?.call(processed, total);
        continue;
      }
      final companion = _rowToCompanion(row, colToField, i + 1, errors);
      if (companion == null) {
        skipped++;
      } else {
        try {
          await repo.insert(companion);
          imported++;
        } catch (e) {
          skipped++;
          if (errors.length < _maxErrorsRetained) {
            errors.add('Row ${i + 1} insert failed: $e');
          }
        }
      }
      onProgress?.call(processed, total);
    }

    return SpreadsheetImportResult(
      imported: imported,
      skipped: skipped,
      errors: errors,
    );
  }

  /// Saved-mapping API: keyed on a stable file-shape signature. Files
  /// with the same column structure share a saved mapping so the user
  /// doesn't have to re-pick every time.
  Future<Map<String, FieldId>?> loadSavedMappingForSignature(
    String signature,
  ) async {
    if (signature.isEmpty) return null;
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString('csv_mapping_$signature');
    if (raw == null) return null;
    try {
      final json = jsonDecode(raw);
      if (json is! Map) return null;
      final mapping = <String, FieldId>{};
      for (final e in json.entries) {
        final f = FieldId.byId(e.value as String?);
        if (f != null) mapping[e.key as String] = f;
      }
      return mapping;
    } catch (_) {
      return null;
    }
  }

  Future<void> saveMappingForSignature(
    String signature,
    Map<String, FieldId> mapping,
  ) async {
    if (signature.isEmpty) return;
    final prefs = await SharedPreferences.getInstance();
    final json = {
      for (final e in mapping.entries) e.key: e.value.id,
    };
    await prefs.setString('csv_mapping_$signature', jsonEncode(json));
  }

  Future<List<ImportMappingPreset>> loadPresets() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_kPresetsKey);
    if (raw == null) return const [];
    try {
      final list = jsonDecode(raw);
      if (list is! List) return const [];
      return list
          .whereType<Map<String, dynamic>>()
          .map(ImportMappingPreset.fromJson)
          .whereType<ImportMappingPreset>()
          .toList();
    } catch (_) {
      return const [];
    }
  }

  Future<void> savePreset(ImportMappingPreset preset) async {
    final all = await loadPresets();
    all.removeWhere((p) => p.id == preset.id);
    all.add(preset);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _kPresetsKey,
      jsonEncode(all.map((p) => p.toJson()).toList()),
    );
  }

  Future<void> deletePreset(String id) async {
    final all = await loadPresets();
    all.removeWhere((p) => p.id == id);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _kPresetsKey,
      jsonEncode(all.map((p) => p.toJson()).toList()),
    );
  }

  // ─────────── auto-suggester ───────────

  /// Compute a suggestion per column. Each candidate field is scored
  /// against the column's header by max-similarity over its alias list.
  /// Whichever field has the highest score becomes the suggestion (when
  /// it crosses the threshold).
  List<MappingSuggestion> _buildSuggestions(List<String> headers) {
    final usedFields = <FieldId>{};
    final suggestions = <MappingSuggestion>[];
    // Precompute scores per column to allow conflict resolution.
    final perColumn = <List<({FieldId field, double score})>>[];
    for (final raw in headers) {
      final scores = <({FieldId field, double score})>[];
      final norm = _normaliseHeader(raw);
      if (norm.isEmpty) {
        perColumn.add(scores);
        continue;
      }
      for (final option in kFieldOptions) {
        var best = 0.0;
        for (final alias in option.aliases) {
          final s = _similarity(norm, alias);
          if (s > best) best = s;
        }
        scores.add((field: option.id, score: best));
      }
      scores.sort((a, b) => b.score.compareTo(a.score));
      perColumn.add(scores);
    }

    // Two-pass assignment:
    //  Pass A — high-confidence claims. A column whose best score is
    //    >= 0.85 AND substantially better than its runner-up gets to
    //    claim that field outright. This prevents weaker overlaps
    //    (e.g. "Powder Type" matching "powder charge") from stealing
    //    a field that belongs to a near-perfect match somewhere else.
    //  Pass B — fill the rest with the best unclaimed match per
    //    column, threshold-gated. Columns whose top field is taken
    //    AND whose runner-up is below threshold get defaulted to
    //    "Don't import" instead of being force-mapped to a marginal
    //    runner-up — much better than guessing.
    final picks = List<MappingSuggestion?>.filled(headers.length, null);
    final orderedIndices = List<int>.generate(headers.length, (i) => i);
    orderedIndices.sort((a, b) {
      final sa = perColumn[a].isEmpty ? 0.0 : perColumn[a].first.score;
      final sb = perColumn[b].isEmpty ? 0.0 : perColumn[b].first.score;
      return sb.compareTo(sa);
    });
    const dominanceMargin = 0.15;
    // Pass A: high-confidence claims. A column whose top score is
    // either an exact alias hit (≥ 0.99) OR sufficiently dominant
    // over its runner-up gets to claim that field outright. The
    // exact-alias short-circuit catches headers like "Charge gr"
    // that match an alias verbatim — even when other fields scored
    // close because they share a token. Without this, e.g. "Charge
    // gr" (perfect match for `powderChargeGr`) could lose its field
    // to a weaker overlapping match somewhere else.
    for (final i in orderedIndices) {
      final scores = perColumn[i];
      if (scores.isEmpty) continue;
      final top = scores.first;
      final runnerUp = scores.length > 1 ? scores[1].score : 0.0;
      final exactHit = top.score >= 0.99;
      final dominant = top.score >= 0.85 &&
          (top.score - runnerUp) >= dominanceMargin;
      if (!exactHit && !dominant) continue;
      if (usedFields.contains(top.field)) continue;
      usedFields.add(top.field);
      picks[i] = MappingSuggestion(
        header: headers[i],
        suggestedField: top.field,
        confidence: top.score,
        alternatives: scores
            .where((s) => s.field != top.field)
            .take(3)
            .toList(growable: false),
      );
    }
    // Pass B: fill the rest with best unclaimed AT a high threshold.
    // Pass-B picks are inherently lower-quality (the column's TOP
    // field was taken or didn't dominate), so we want a stiff bar to
    // avoid false positives like "Powder Type" → `scaleUsed` (which
    // matches by happenstance via Jaro-Winkler character similarity
    // alone). Below the threshold we default to "Don't import" —
    // better an honest miss than a wrong guess.
    const passBThreshold = 0.85;
    for (final i in orderedIndices) {
      if (picks[i] != null) continue;
      final scores = perColumn[i];
      FieldId? chosen;
      var chosenScore = 0.0;
      for (final s in scores) {
        if (usedFields.contains(s.field)) continue;
        chosen = s.field;
        chosenScore = s.score;
        break;
      }
      final alternatives = scores
          .where((s) => s.field != chosen)
          .take(3)
          .toList(growable: false);
      // Tightened: require pass-B picks to clear ≥ 0.85. Below that
      // we'd be guessing more than we'd be helping.
      if (chosen != null && chosenScore >= passBThreshold) {
        usedFields.add(chosen);
      } else {
        chosen = null;
        chosenScore = 0.0;
      }
      picks[i] = MappingSuggestion(
        header: headers[i],
        suggestedField: chosen,
        confidence: chosenScore,
        alternatives: alternatives,
      );
    }
    for (final p in picks) {
      suggestions.add(p!);
    }
    return suggestions;
  }

  /// Reduce a header to canonical form for similarity scoring.
  /// `'  Powder_Charge_(GR) '` → `'powder charge gr'`.
  String _normaliseHeader(String raw) {
    final lower = raw.toLowerCase().trim();
    final cleaned = lower.replaceAll(RegExp(r'[_\-()/]'), ' ');
    return cleaned.replaceAll(RegExp(r'\s+'), ' ').trim();
  }

  /// Combined similarity used by the auto-suggester. Exact match
  /// returns 1.0; otherwise we compute three signals — token
  /// overlap, substring containment, and Jaro-Winkler — and combine
  /// them with explicit floors and ceilings so noisy matches don't
  /// produce confident-looking scores.
  ///
  /// Behaviour:
  /// - Exact alias match (string-equal) → 1.0.
  /// - Substring containment in either direction → 0.95.
  /// - Significant token overlap (Jaccard ≥ 0.5) → bumped to ≥ 0.9.
  /// - Otherwise we fall back to Jaro-Winkler, capped at 0.7 — so a
  ///   coincidental character similarity (e.g. "Powder Type" vs
  ///   "scale used") can't claim to be confident enough for an
  ///   auto-pick. The user can still override in the dropdown, and
  ///   the score lands in the alternatives list.
  double _similarity(String a, String b) {
    if (a == b) return 1.0;
    final aTokens = a.split(' ').where((t) => t.isNotEmpty).toSet();
    final bTokens = b.split(' ').where((t) => t.isNotEmpty).toSet();
    final inter = aTokens.intersection(bTokens).length;
    final union = aTokens.union(bTokens).length;
    final jaccard = union == 0 ? 0.0 : inter / union;
    final containment = a.contains(b) || b.contains(a);
    if (containment) return 0.95;
    if (jaccard >= 0.5) {
      // Strong shared-token signal — small Jaro-Winkler bonus tops it
      // off but the floor is already comfortably high.
      return 0.9 + (jaccard - 0.5) * 0.2;
    }
    if (jaccard > 0) {
      // Some shared tokens — middling confidence; still better than
      // pure character similarity.
      return 0.6 + jaccard * 0.4;
    }
    // No token overlap — fall back to Jaro-Winkler but cap so a
    // coincidental character match can't claim confidence ≥ 0.7. This
    // keeps cases like "Powder Type" / "Bullet Model" out of the
    // auto-suggested column and into "Don't import" by default.
    final jw = _jaroWinkler(a, b);
    return jw > 0.7 ? 0.7 : jw;
  }

  /// Jaro-Winkler similarity — short-form here for free, no extra dep.
  /// Returns 1.0 for identical strings, 0.0 for fully disjoint.
  double _jaroWinkler(String s1, String s2) {
    if (s1.isEmpty && s2.isEmpty) return 1.0;
    if (s1.isEmpty || s2.isEmpty) return 0.0;
    final m1 = s1.length;
    final m2 = s2.length;
    final matchDistance = (m1 > m2 ? m1 : m2) ~/ 2 - 1;
    final s1Matches = List<bool>.filled(m1, false);
    final s2Matches = List<bool>.filled(m2, false);
    var matches = 0;
    for (var i = 0; i < m1; i++) {
      final start = i - matchDistance < 0 ? 0 : i - matchDistance;
      final end = i + matchDistance + 1 > m2 ? m2 : i + matchDistance + 1;
      for (var j = start; j < end; j++) {
        if (s2Matches[j]) continue;
        if (s1[i] != s2[j]) continue;
        s1Matches[i] = true;
        s2Matches[j] = true;
        matches++;
        break;
      }
    }
    if (matches == 0) return 0.0;
    var transpositions = 0;
    var k = 0;
    for (var i = 0; i < m1; i++) {
      if (!s1Matches[i]) continue;
      while (!s2Matches[k]) {
        k++;
      }
      if (s1[i] != s2[k]) transpositions++;
      k++;
    }
    transpositions ~/= 2;
    final m = matches.toDouble();
    final jaro = (m / m1 + m / m2 + (m - transpositions) / m) / 3.0;
    // Jaro-Winkler boost for matching prefix up to 4 chars.
    var prefix = 0;
    for (var i = 0; i < (m1 < m2 ? m1 : m2) && i < 4; i++) {
      if (s1[i] == s2[i]) {
        prefix++;
      } else {
        break;
      }
    }
    return jaro + prefix * 0.1 * (1 - jaro);
  }

  String _signatureForHeaders(List<String> headers) {
    if (headers.isEmpty) return '';
    final norm = headers.map(_normaliseHeader).join('|');
    return _hashOf(norm);
  }

  String _hashOf(String s) {
    // Lightweight non-crypto hash — adequate for prefs key disambiguation.
    var h = 0x811c9dc5;
    for (final c in s.codeUnits) {
      h ^= c;
      h = (h * 0x01000193) & 0xffffffff;
    }
    return h.toRadixString(16).padLeft(8, '0');
  }

  // ─────────── per-row materialization ───────────

  UserLoadsCompanion? _rowToCompanion(
    List<String> row,
    Map<int, FieldId> colToField,
    int rowNumber,
    List<String> errors,
  ) {
    String? name;
    String? caliber;
    String? powder;
    String? bullet;
    String? primer;
    String? brass;
    String? notes;
    String? useCase;
    String? status;
    String? pressUsed;
    String? sizingDieUsed;
    String? seatingDieUsed;
    String? scaleUsed;
    String? chronographUsed;
    String? loadedBy;
    DateTime? loadingDate;
    DateTime? dateEstablished;
    double? powderChargeGr;
    double? chargeToleranceGr;
    double? bulletWeightGr;
    double? bulletLengthIn;
    double? coalIn;
    double? cbtoIn;
    double? seatingDepthIn;
    double? primerDepthCps;
    double? shoulderBumpIn;
    double? mandrelSizeIn;
    double? distanceToLandsIn;
    double? jumpToLandsIn;
    double? loadedNeckDiameterIn;
    double? bulletRunoutTirIn;
    double? bushingSizeIn;

    for (var col = 0; col < row.length; col++) {
      final field = colToField[col];
      if (field == null) continue;
      final raw = row[col].trim();
      if (raw.isEmpty) continue;
      void numeric(double? Function(double v) assign, {String? unit}) {
        final v = parseTolerantNumeric(raw);
        if (v == null) {
          if (errors.length < _maxErrorsRetained) {
            errors.add(
              'Row $rowNumber: could not parse "$raw" as a number for '
              '${kFieldById[field]?.label ?? field.id}.',
            );
          }
          return;
        }
        assign(v);
      }

      if (field == FieldId.name) {
        name = raw;
      } else if (field == FieldId.caliber) {
        caliber = raw;
      } else if (field == FieldId.powder) {
        powder = raw;
      } else if (field == FieldId.powderChargeGr) {
        numeric((v) => powderChargeGr = v);
      } else if (field == FieldId.chargeToleranceGr) {
        numeric((v) => chargeToleranceGr = v);
      } else if (field == FieldId.bullet) {
        bullet = raw;
      } else if (field == FieldId.bulletWeightGr) {
        numeric((v) => bulletWeightGr = v);
      } else if (field == FieldId.bulletLengthIn) {
        numeric((v) => bulletLengthIn = v);
      } else if (field == FieldId.primer) {
        primer = raw;
      } else if (field == FieldId.brass) {
        brass = raw;
      } else if (field == FieldId.coalIn) {
        numeric((v) => coalIn = v);
      } else if (field == FieldId.cbtoIn) {
        numeric((v) => cbtoIn = v);
      } else if (field == FieldId.seatingDepthIn) {
        numeric((v) => seatingDepthIn = v);
      } else if (field == FieldId.primerDepthCps) {
        numeric((v) => primerDepthCps = v);
      } else if (field == FieldId.shoulderBumpIn) {
        numeric((v) => shoulderBumpIn = v);
      } else if (field == FieldId.mandrelSizeIn) {
        numeric((v) => mandrelSizeIn = v);
      } else if (field == FieldId.distanceToLandsIn) {
        numeric((v) => distanceToLandsIn = v);
      } else if (field == FieldId.jumpToLandsIn) {
        numeric((v) => jumpToLandsIn = v);
      } else if (field == FieldId.loadedNeckDiameterIn) {
        numeric((v) => loadedNeckDiameterIn = v);
      } else if (field == FieldId.bulletRunoutTirIn) {
        numeric((v) => bulletRunoutTirIn = v);
      } else if (field == FieldId.bushingSizeIn) {
        numeric((v) => bushingSizeIn = v);
      } else if (field == FieldId.useCase) {
        useCase = raw;
      } else if (field == FieldId.status) {
        status = raw;
      } else if (field == FieldId.pressUsed) {
        pressUsed = raw;
      } else if (field == FieldId.sizingDieUsed) {
        sizingDieUsed = raw;
      } else if (field == FieldId.seatingDieUsed) {
        seatingDieUsed = raw;
      } else if (field == FieldId.scaleUsed) {
        scaleUsed = raw;
      } else if (field == FieldId.chronographUsed) {
        chronographUsed = raw;
      } else if (field == FieldId.loadedBy) {
        loadedBy = raw;
      } else if (field == FieldId.loadingDate) {
        final dt = parseTolerantDate(raw);
        if (dt == null && errors.length < _maxErrorsRetained) {
          errors.add(
            'Row $rowNumber: could not parse "$raw" as a date for '
            'Loading Date.',
          );
        }
        loadingDate = dt;
      } else if (field == FieldId.dateEstablished) {
        final dt = parseTolerantDate(raw);
        if (dt == null && errors.length < _maxErrorsRetained) {
          errors.add(
            'Row $rowNumber: could not parse "$raw" as a date for '
            'Date Established.',
          );
        }
        dateEstablished = dt;
      } else if (field == FieldId.notes) {
        notes = raw;
      }
    }

    if (name == null || name.isEmpty) return null;

    return UserLoadsCompanion(
      name: Value(name),
      caliber: Value(caliber),
      powder: Value(powder),
      powderChargeGr: Value(powderChargeGr),
      chargeToleranceGr: Value(chargeToleranceGr),
      bullet: Value(bullet),
      bulletWeightGr: Value(bulletWeightGr),
      bulletLengthIn: Value(bulletLengthIn),
      primer: Value(primer),
      brass: Value(brass),
      coalIn: Value(coalIn),
      cbtoIn: Value(cbtoIn),
      seatingDepthIn: Value(seatingDepthIn),
      primerDepthCps: Value(primerDepthCps),
      shoulderBumpIn: Value(shoulderBumpIn),
      mandrelSizeIn: Value(mandrelSizeIn),
      distanceToLandsIn: Value(distanceToLandsIn),
      jumpToLandsIn: Value(jumpToLandsIn),
      loadedNeckDiameterIn: Value(loadedNeckDiameterIn),
      bulletRunoutTirIn: Value(bulletRunoutTirIn),
      bushingSizeIn: Value(bushingSizeIn),
      useCase: Value(useCase),
      status: Value(status),
      pressUsed: Value(pressUsed),
      sizingDieUsed: Value(sizingDieUsed),
      seatingDieUsed: Value(seatingDieUsed),
      scaleUsed: Value(scaleUsed),
      chronographUsed: Value(chronographUsed),
      loadedBy: Value(loadedBy),
      loadingDate: Value(loadingDate),
      dateEstablished: Value(dateEstablished),
      notes: Value(notes),
    );
  }

  /// Tolerant date parser. Accepts ISO 8601 (`2026-05-07`), American
  /// `MM/DD/YYYY`, and the Excel-rendered `YYYY-MM-DD HH:MM`. Returns
  /// null on anything else — caller treats null as a parse warning.
  static DateTime? parseTolerantDate(String raw) {
    final s = raw.trim();
    if (s.isEmpty) return null;
    final iso = DateTime.tryParse(s);
    if (iso != null) return iso;
    // MM/DD/YYYY or M/D/YYYY (US notation common in Excel exports).
    final us = RegExp(r'^(\d{1,2})/(\d{1,2})/(\d{2,4})$').firstMatch(s);
    if (us != null) {
      final month = int.parse(us.group(1)!);
      final day = int.parse(us.group(2)!);
      var year = int.parse(us.group(3)!);
      if (year < 100) year += 2000;
      try {
        return DateTime(year, month, day);
      } catch (_) {
        return null;
      }
    }
    return null;
  }

  /// Tolerant numeric parser. Accepts:
  ///   - "41.5", "41.5 ", " 41.5"
  ///   - "41.5gr", "41.5 grains", "41.5 grain"
  ///   - "2.825in", "2.825 inches"
  ///   - "1,234.5" (US thousands separator)
  ///   - returns null for blanks or strings like "varies".
  static double? parseTolerantNumeric(String raw) {
    var s = raw.trim();
    if (s.isEmpty) return null;
    // Strip common unit suffixes case-insensitively.
    s = s.replaceFirst(
      RegExp(r'(grains|grain|gr|inches|in|thou|thousandths)\s*$',
          caseSensitive: false),
      '',
    );
    s = s.trim();
    // Remove US-style thousands separators: "1,234.5" -> "1234.5". Keep
    // one comma if it's in the position of a European decimal mark
    // (single comma, no period) — flip to a period in that case.
    if (s.contains(',') && !s.contains('.')) {
      // Treat as European decimal notation if the comma appears
      // exactly once and is followed by 1–3 digits.
      final m = RegExp(r'^(-?\d+),(\d{1,3})$').firstMatch(s);
      if (m != null) {
        s = '${m.group(1)}.${m.group(2)}';
      } else {
        s = s.replaceAll(',', '');
      }
    } else {
      s = s.replaceAll(',', '');
    }
    return double.tryParse(s);
  }

  // ─────────── parsers ───────────

  String _extensionOf(File file) {
    final p = file.path.toLowerCase();
    final dot = p.lastIndexOf('.');
    if (dot == -1) return '';
    return p.substring(dot + 1);
  }

  Future<List<List<String>>> _parseCsv(File file) async {
    String content;
    try {
      content = await file.readAsString();
    } catch (_) {
      // Excel sometimes emits CP-1252; fall back to latin1.
      content = await file.readAsString(encoding: latin1);
    }
    return parseCsvText(content);
  }

  /// Public for unit testing — parses the raw text and returns rows.
  static List<List<String>> parseCsvText(String csvText) {
    final rows = <List<String>>[];
    var current = <String>[];
    final buf = StringBuffer();
    var inQuotes = false;
    var i = 0;
    while (i < csvText.length) {
      final ch = csvText[i];
      if (inQuotes) {
        if (ch == '"') {
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
          if (cell.isNotEmpty && cell.endsWith('\r')) {
            cell = cell.substring(0, cell.length - 1);
          }
          current.add(cell);
          buf.clear();
          rows.add(current);
          current = <String>[];
          i++;
        } else if (ch == '\r') {
          current.add(buf.toString());
          buf.clear();
          rows.add(current);
          current = <String>[];
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
        'Unterminated quoted field in CSV. Make sure every " has a '
        'matching close.',
      );
    }
    var lastCell = buf.toString();
    if (lastCell.isNotEmpty && lastCell.endsWith('\r')) {
      lastCell = lastCell.substring(0, lastCell.length - 1);
    }
    if (lastCell.isNotEmpty || current.isNotEmpty) {
      current.add(lastCell);
      rows.add(current);
    }
    return rows;
  }

  Future<List<List<String>>> _parseXlsx(File file) async {
    final bytes = await file.readAsBytes();
    final book = xlsx.Excel.decodeBytes(bytes);
    if (book.tables.isEmpty) {
      throw const FormatException('Workbook contains no sheets.');
    }
    // Use the first sheet. Multi-sheet workbooks default to sheet 1;
    // future iteration could let the user pick.
    final sheet = book.tables.values.first;
    final rows = <List<String>>[];
    for (final row in sheet.rows) {
      final cells = <String>[];
      for (final cell in row) {
        cells.add(_xlsxCellToString(cell));
      }
      rows.add(cells);
    }
    return rows;
  }

  String _xlsxCellToString(xlsx.Data? cell) {
    if (cell == null) return '';
    final v = cell.value;
    if (v == null) return '';
    if (v is xlsx.TextCellValue) {
      return v.value.text ?? '';
    }
    if (v is xlsx.IntCellValue) {
      return v.value.toString();
    }
    if (v is xlsx.DoubleCellValue) {
      final d = v.value;
      // Round-trip through toString without trailing ".0" for integers.
      if (d == d.roundToDouble()) {
        return d.toInt().toString();
      }
      return d.toString();
    }
    if (v is xlsx.BoolCellValue) {
      return v.value ? 'TRUE' : 'FALSE';
    }
    if (v is xlsx.DateCellValue) {
      // YYYY-MM-DD — readable, sortable, parseable by `DateTime.parse`
      // if the recipe form ever wants to pull dates out of imports.
      final m = v.month.toString().padLeft(2, '0');
      final d = v.day.toString().padLeft(2, '0');
      return '${v.year}-$m-$d';
    }
    if (v is xlsx.DateTimeCellValue) {
      final m = v.month.toString().padLeft(2, '0');
      final d = v.day.toString().padLeft(2, '0');
      final hh = v.hour.toString().padLeft(2, '0');
      final mm = v.minute.toString().padLeft(2, '0');
      return '${v.year}-$m-$d $hh:$mm';
    }
    if (v is xlsx.TimeCellValue) {
      final hh = v.hour.toString().padLeft(2, '0');
      final mm = v.minute.toString().padLeft(2, '0');
      return '$hh:$mm';
    }
    if (v is xlsx.FormulaCellValue) {
      return v.formula;
    }
    // Fall through for any future cell types.
    return v.toString();
  }

  bool _isAllEmpty(List<String> row) {
    for (final cell in row) {
      if (cell.trim().isNotEmpty) return false;
    }
    return true;
  }
}
