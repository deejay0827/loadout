// FILE: lib/screens/recipes/smart_import_screen.dart
//
// ============================================================================
// WHAT THIS FILE DOES
// ============================================================================
// Smart Import wizard. Lets a user import recipes from a `.csv` or
// `.xlsx` file even when the column names don't match our schema —
// the auto-suggester proposes a mapping, the user confirms or
// overrides it, and we ingest every row.
//
// Five steps:
//   1. Pick file (CSV or XLSX).
//   2. Header row + preview (sample rows, "where is your header?").
//   3. Column mapping (the meat — dropdown per column).
//   4. Validation summary (heads-up about missing important fields).
//   5. Import + result (progress + success summary + CTA back to list).
//
// **Free, not Pro-gated.** The whole point of this flow is to remove
// the conversion barrier for Excel reloaders.
//
// ============================================================================
// WHY IT EXISTS IN THE ARCHITECTURE
// ============================================================================
// The original `CsvImportService` only auto-detected a small set of
// fixed header aliases. Anyone whose Excel sheet used a custom column
// name had to either rename their columns first or write off the
// import entirely. Smart Import fixes that with an in-app mapping UI
// that surfaces one row per spreadsheet column with the auto-suggested
// destination field already pre-selected.
//
// Survey data (CLAUDE.md) showed 33% of reloaders track loads in
// Excel. This is the conversion path; gating it would defeat the
// purpose.
//
// ============================================================================
// WHY THIS IS HARDER THAN IT LOOKS
// ============================================================================
// 1. **Mapping UI must scale to wide spreadsheets.** Some sheets have
//    20+ columns. The mapping list is a `ListView` of cards — one per
//    column — each showing the column name, the top 3 sample values,
//    and a destination dropdown. We render in a scrollable view rather
//    than a `DataTable` because the dropdowns have to be inline and
//    rich (with hint text + chip).
//
// 2. **Validation is non-blocking.** The summary screen warns about
//    missing important fields (no Recipe Name column, no caliber
//    mapped, etc.) but lets the user proceed if they really want to.
//    The only hard requirement is a Recipe Name mapping — without it,
//    every row would skip.
//
// 3. **Saved mappings are scoped to file shape.** The service hashes
//    the normalized header row; we look up that hash in
//    SharedPreferences before applying the auto-suggester. If a saved
//    mapping exists, it overrides the auto-suggestions (the user
//    already curated this once — don't undo their work).
//
// 4. **Step navigation is deliberately one-way back.** A user who
//    advances to step 3 and pops back to step 2 keeps their column
//    mapping; we re-derive headers + sample but the mapping persists
//    in `_columnFieldByHeader` keyed on header label.

import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../repositories/recipe_repository.dart';
import '../../services/spreadsheet_import_service.dart';
import 'recipes_list_screen.dart';

class SmartImportScreen extends StatefulWidget {
  const SmartImportScreen({super.key});

  @override
  State<SmartImportScreen> createState() => _SmartImportScreenState();
}

enum _Step { pickFile, preview, mapping, summary, importing, done }

class _SmartImportScreenState extends State<SmartImportScreen> {
  _Step _step = _Step.pickFile;

  File? _file;
  SpreadsheetPreview? _preview;
  SpreadsheetImportService? _service;

  /// Header label -> destination field. "Don't import" columns are
  /// simply absent.
  final Map<String, FieldId> _columnFieldByHeader = {};

  int _headerRowIndex = 0;
  int _skipAfterHeader = 0;

  /// Progress during the actual import (step `importing`).
  int _processed = 0;
  int _total = 0;
  SpreadsheetImportResult? _result;
  String? _errorMessage;

  /// Available presets the user has saved.
  List<ImportMappingPreset> _presets = const [];

  @override
  void initState() {
    super.initState();
    _loadPresets();
  }

  Future<void> _loadPresets() async {
    final repo = context.read<RecipeRepository>();
    final svc = SpreadsheetImportService(repo);
    final list = await svc.loadPresets();
    if (!mounted) return;
    setState(() {
      _presets = list;
      _service = svc;
    });
  }

  // ─────────── step transitions ───────────

  Future<void> _pickFile() async {
    // Resolve dependencies BEFORE the first await so we never reach
    // back into the BuildContext after the async file-picker call.
    final repo = context.read<RecipeRepository>();
    final picked = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: const ['csv', 'xlsx'],
      withData: false,
    );
    if (picked == null || picked.files.isEmpty) return;
    final path = picked.files.single.path;
    if (path == null) {
      _setError('Could not read the selected file path.');
      return;
    }
    final file = File(path);
    final svc = _service ?? SpreadsheetImportService(repo);
    setState(() {
      _file = file;
      _service = svc;
      _step = _Step.preview;
      _columnFieldByHeader.clear();
      _headerRowIndex = 0;
      _skipAfterHeader = 0;
      _errorMessage = null;
    });
    await _refreshPreview();
  }

  Future<void> _refreshPreview() async {
    final file = _file;
    final svc = _service;
    if (file == null || svc == null) return;
    setState(() => _errorMessage = null);
    final preview = await svc.parsePreview(
      file,
      headerRowIndex: _headerRowIndex,
      skipAfterHeader: _skipAfterHeader,
    );
    if (!mounted) return;
    if (preview.hasFatalError) {
      setState(() {
        _errorMessage = preview.fatalError;
        _preview = null;
      });
      return;
    }
    // Try saved mapping; fall back to suggestions.
    final saved = await svc.loadSavedMappingForSignature(
      preview.headerSignature,
    );
    if (!mounted) return;
    final mapping = <String, FieldId>{};
    if (saved != null && saved.isNotEmpty) {
      mapping.addAll(saved);
    } else {
      for (var i = 0; i < preview.headers.length; i++) {
        final s = preview.suggestions[i];
        if (s.suggestedField != null) {
          mapping[preview.headers[i]] = s.suggestedField!;
        }
      }
    }
    setState(() {
      _preview = preview;
      _columnFieldByHeader
        ..clear()
        ..addAll(mapping);
    });
  }

  void _resetMappingToSuggestions() {
    final preview = _preview;
    if (preview == null) return;
    setState(() {
      _columnFieldByHeader.clear();
      for (var i = 0; i < preview.headers.length; i++) {
        final s = preview.suggestions[i];
        if (s.suggestedField != null) {
          _columnFieldByHeader[preview.headers[i]] = s.suggestedField!;
        }
      }
    });
  }

  void _applyPreset(ImportMappingPreset preset) {
    final preview = _preview;
    if (preview == null) return;
    setState(() {
      _columnFieldByHeader.clear();
      for (final header in preview.headers) {
        final f = preset.headerToField[header];
        if (f != null) _columnFieldByHeader[header] = f;
      }
    });
  }

  Future<void> _runImport() async {
    final file = _file;
    final svc = _service;
    final preview = _preview;
    if (file == null || svc == null || preview == null) return;
    setState(() {
      _step = _Step.importing;
      _processed = 0;
      _total = preview.totalDataRows;
      _errorMessage = null;
    });
    // Persist the mapping under this file-shape signature so re-importing
    // a similarly-shaped file in the future loads it automatically.
    await svc.saveMappingForSignature(
      preview.headerSignature,
      Map<String, FieldId>.from(_columnFieldByHeader),
    );
    final result = await svc.importRows(
      file: file,
      mapping: Map<String, FieldId>.from(_columnFieldByHeader),
      headerRowIndex: _headerRowIndex,
      skipAfterHeader: _skipAfterHeader,
      onProgress: (processed, total) {
        if (!mounted) return;
        setState(() {
          _processed = processed;
          _total = total;
        });
      },
    );
    if (!mounted) return;
    setState(() {
      _result = result;
      _step = _Step.done;
    });
  }

  void _setError(String message) {
    setState(() => _errorMessage = message);
  }

  // ─────────── render ───────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Smart Import'),
        leading: IconButton(
          icon: const Icon(Icons.close),
          tooltip: 'Cancel',
          onPressed: () => Navigator.of(context).pop(),
        ),
      ),
      body: SafeArea(
        child: switch (_step) {
          _Step.pickFile => _PickFileStep(
              onPick: _pickFile,
              error: _errorMessage,
              presetsCount: _presets.length,
            ),
          _Step.preview => _PreviewStep(
              preview: _preview,
              file: _file,
              error: _errorMessage,
              headerRowIndex: _headerRowIndex,
              skipAfterHeader: _skipAfterHeader,
              onHeaderRowChanged: (v) {
                setState(() => _headerRowIndex = v);
                // ignore: discarded_futures
                _refreshPreview();
              },
              onSkipChanged: (v) {
                setState(() => _skipAfterHeader = v);
                // ignore: discarded_futures
                _refreshPreview();
              },
              onContinue: () => setState(() => _step = _Step.mapping),
              onBack: () => setState(() => _step = _Step.pickFile),
            ),
          _Step.mapping => _MappingStep(
              preview: _preview!,
              columnFieldByHeader: _columnFieldByHeader,
              presets: _presets,
              onChanged: (header, field) {
                setState(() {
                  if (field == null) {
                    _columnFieldByHeader.remove(header);
                  } else {
                    _columnFieldByHeader[header] = field;
                  }
                });
              },
              onResetToSuggestions: _resetMappingToSuggestions,
              onApplyPreset: _applyPreset,
              onSavePreset: _promptSavePreset,
              onContinue: () => setState(() => _step = _Step.summary),
              onBack: () => setState(() => _step = _Step.preview),
            ),
          _Step.summary => _SummaryStep(
              preview: _preview!,
              columnFieldByHeader: _columnFieldByHeader,
              onImport: _runImport,
              onBack: () => setState(() => _step = _Step.mapping),
            ),
          _Step.importing => _ImportingStep(
              processed: _processed,
              total: _total,
            ),
          _Step.done => _DoneStep(
              result: _result!,
              onViewRecipes: () {
                Navigator.of(context).pop();
                // Pop back to recipes list — assume caller pushed onto
                // recipes tab. If not, a no-op is fine.
              },
              onImportAnother: () => setState(() {
                _step = _Step.pickFile;
                _file = null;
                _preview = null;
                _columnFieldByHeader.clear();
                _result = null;
              }),
            ),
        },
      ),
    );
  }

  Future<void> _promptSavePreset() async {
    final svc = _service;
    final preview = _preview;
    if (svc == null || preview == null) return;
    final controller = TextEditingController();
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Save Mapping Preset'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(
            labelText: 'Preset name',
            hintText: 'e.g. My Excel Loads Template',
          ),
          textInputAction: TextInputAction.done,
          onSubmitted: (v) => Navigator.of(ctx).pop(v.trim()),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(controller.text.trim()),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    if (name == null || name.isEmpty) return;
    final preset = ImportMappingPreset(
      id: DateTime.now().millisecondsSinceEpoch.toString(),
      name: name,
      headerToField: Map<String, FieldId>.from(_columnFieldByHeader),
      headerSignature: preview.headerSignature,
    );
    await svc.savePreset(preset);
    final updated = await svc.loadPresets();
    if (!mounted) return;
    setState(() => _presets = updated);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Saved preset "$name".')),
    );
  }
}

// ─────────── step widgets ───────────

class _PickFileStep extends StatelessWidget {
  const _PickFileStep({
    required this.onPick,
    required this.error,
    required this.presetsCount,
  });

  final VoidCallback onPick;
  final String? error;
  final int presetsCount;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ListView(
      padding: const EdgeInsets.all(20),
      children: [
        Card(
          color: theme.colorScheme.primaryContainer.withValues(alpha: 0.4),
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(Icons.auto_fix_high,
                    color: theme.colorScheme.primary),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Smart Import',
                        style: theme.textTheme.titleLarge,
                      ),
                      const SizedBox(height: 6),
                      Text(
                        'Bring your loads in from any spreadsheet — even '
                        'one with completely custom column names. We\'ll '
                        'suggest how each column maps to LoadOut\'s fields '
                        'and you confirm.',
                        style: theme.textTheme.bodyMedium,
                      ),
                      const SizedBox(height: 6),
                      Chip(
                        label: const Text('Free for everyone'),
                        visualDensity: VisualDensity.compact,
                        backgroundColor: theme.colorScheme.primary.withValues(
                          alpha: 0.15,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 16),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Pick your spreadsheet',
                    style: theme.textTheme.titleMedium),
                const SizedBox(height: 4),
                Text(
                  'Supported: CSV (.csv) and Excel (.xlsx). Up to a few '
                  'thousand rows.',
                  style: theme.textTheme.bodySmall,
                ),
                const SizedBox(height: 12),
                FilledButton.icon(
                  onPressed: onPick,
                  icon: const Icon(Icons.folder_open),
                  label: const Text('Choose file'),
                ),
                if (error != null) ...[
                  const SizedBox(height: 12),
                  _InlineError(message: error!),
                ],
              ],
            ),
          ),
        ),
        if (presetsCount > 0) ...[
          const SizedBox(height: 12),
          Text(
            'Tip: any saved mapping presets will appear after you pick a file.',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ],
    );
  }
}

class _PreviewStep extends StatelessWidget {
  const _PreviewStep({
    required this.preview,
    required this.file,
    required this.error,
    required this.headerRowIndex,
    required this.skipAfterHeader,
    required this.onHeaderRowChanged,
    required this.onSkipChanged,
    required this.onContinue,
    required this.onBack,
  });

  final SpreadsheetPreview? preview;
  final File? file;
  final String? error;
  final int headerRowIndex;
  final int skipAfterHeader;
  final ValueChanged<int> onHeaderRowChanged;
  final ValueChanged<int> onSkipChanged;
  final VoidCallback onContinue;
  final VoidCallback onBack;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final p = preview;
    if (error != null) {
      return Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            _InlineError(message: error!),
            const SizedBox(height: 16),
            FilledButton(
              onPressed: onBack,
              child: const Text('Pick another file'),
            ),
          ],
        ),
      );
    }
    if (p == null) {
      return const Center(child: CircularProgressIndicator());
    }
    return Column(
      children: [
        Expanded(
          child: ListView(
            padding: const EdgeInsets.all(20),
            children: [
              Text(
                'Step 1 of 4 — Preview',
                style: theme.textTheme.labelLarge?.copyWith(
                  color: theme.colorScheme.primary,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                'Pick the row that has your column names',
                style: theme.textTheme.titleLarge,
              ),
              const SizedBox(height: 6),
              Text(
                'Most spreadsheets have headers on row 1. If yours has a '
                'title or metadata block first, bump the row up.',
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 16),
              Row(
                children: [
                  Expanded(
                    child: _StepperField(
                      label: 'Header row',
                      value: headerRowIndex + 1,
                      min: 1,
                      max: 20,
                      onChanged: (v) => onHeaderRowChanged(v - 1),
                    ),
                  ),
                  const SizedBox(width: 16),
                  Expanded(
                    child: _StepperField(
                      label: 'Skip rows below header',
                      value: skipAfterHeader,
                      min: 0,
                      max: 20,
                      onChanged: onSkipChanged,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              Text(
                '${p.totalDataRows} data row'
                '${p.totalDataRows == 1 ? '' : 's'} below the header.',
                style: theme.textTheme.bodyMedium,
              ),
              const SizedBox(height: 12),
              Text(
                'Sample',
                style: theme.textTheme.titleMedium,
              ),
              const SizedBox(height: 8),
              _SamplePreviewTable(preview: p),
            ],
          ),
        ),
        _StepFooter(
          onBack: onBack,
          onContinue: onContinue,
          continueLabel: 'Continue',
          continueEnabled: p.headers.isNotEmpty && p.totalDataRows > 0,
        ),
      ],
    );
  }
}

class _StepperField extends StatelessWidget {
  const _StepperField({
    required this.label,
    required this.value,
    required this.min,
    required this.max,
    required this.onChanged,
  });

  final String label;
  final int value;
  final int min;
  final int max;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return InputDecorator(
      decoration: InputDecoration(
        labelText: label,
        border: const OutlineInputBorder(),
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 12,
          vertical: 8,
        ),
      ),
      child: Row(
        children: [
          IconButton(
            icon: const Icon(Icons.remove),
            visualDensity: VisualDensity.compact,
            onPressed: value > min ? () => onChanged(value - 1) : null,
          ),
          Expanded(
            child: Center(
              child: Text(
                '$value',
                style: theme.textTheme.titleMedium,
              ),
            ),
          ),
          IconButton(
            icon: const Icon(Icons.add),
            visualDensity: VisualDensity.compact,
            onPressed: value < max ? () => onChanged(value + 1) : null,
          ),
        ],
      ),
    );
  }
}

class _SamplePreviewTable extends StatelessWidget {
  const _SamplePreviewTable({required this.preview});

  final SpreadsheetPreview preview;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final headers = preview.headers;
    final samples = preview.sampleRows;
    if (headers.isEmpty) {
      return Text(
        'No columns detected on this row.',
        style: theme.textTheme.bodyMedium?.copyWith(
          color: theme.colorScheme.error,
        ),
      );
    }
    return Card(
      child: SizedBox(
        height: 220,
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: SingleChildScrollView(
            child: DataTable(
              headingRowHeight: 40,
              dataRowMinHeight: 32,
              dataRowMaxHeight: 40,
              columns: [
                for (final h in headers)
                  DataColumn(
                    label: Text(
                      h.isEmpty ? '(blank)' : h,
                      style: theme.textTheme.labelMedium,
                    ),
                  ),
              ],
              rows: [
                for (final row in samples)
                  DataRow(
                    cells: [
                      for (var i = 0; i < headers.length; i++)
                        DataCell(
                          ConstrainedBox(
                            constraints: const BoxConstraints(maxWidth: 200),
                            child: Text(
                              i < row.length ? row[i] : '',
                              overflow: TextOverflow.ellipsis,
                              style: theme.textTheme.bodySmall,
                            ),
                          ),
                        ),
                    ],
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _MappingStep extends StatelessWidget {
  const _MappingStep({
    required this.preview,
    required this.columnFieldByHeader,
    required this.presets,
    required this.onChanged,
    required this.onResetToSuggestions,
    required this.onApplyPreset,
    required this.onSavePreset,
    required this.onContinue,
    required this.onBack,
  });

  final SpreadsheetPreview preview;
  final Map<String, FieldId> columnFieldByHeader;
  final List<ImportMappingPreset> presets;
  final void Function(String header, FieldId? field) onChanged;
  final VoidCallback onResetToSuggestions;
  final ValueChanged<ImportMappingPreset> onApplyPreset;
  final VoidCallback onSavePreset;
  final VoidCallback onContinue;
  final VoidCallback onBack;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final hasName =
        columnFieldByHeader.values.contains(FieldId.name);
    return Column(
      children: [
        Expanded(
          child: ListView(
            padding: const EdgeInsets.all(20),
            children: [
              Text(
                'Step 2 of 4 — Map your columns',
                style: theme.textTheme.labelLarge?.copyWith(
                  color: theme.colorScheme.primary,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                'What does each column mean?',
                style: theme.textTheme.titleLarge,
              ),
              const SizedBox(height: 6),
              Text(
                'We\'ve guessed for you. Adjust any that look wrong, or '
                'pick "Don\'t import" for columns we shouldn\'t bring '
                'across.',
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  ActionChip(
                    avatar: const Icon(Icons.refresh, size: 18),
                    label: const Text('Reset to suggestions'),
                    onPressed: onResetToSuggestions,
                  ),
                  ActionChip(
                    avatar: const Icon(Icons.bookmark_add_outlined, size: 18),
                    label: const Text('Save this mapping'),
                    onPressed: onSavePreset,
                  ),
                  if (presets.isNotEmpty)
                    PopupMenuButton<ImportMappingPreset>(
                      tooltip: 'Apply saved preset',
                      itemBuilder: (ctx) => [
                        for (final p in presets)
                          PopupMenuItem(
                            value: p,
                            child: Text(p.name),
                          ),
                      ],
                      onSelected: onApplyPreset,
                      child: Chip(
                        avatar: const Icon(
                          Icons.bookmark_outline,
                          size: 18,
                        ),
                        label: const Text('Apply preset'),
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 16),
              for (var i = 0; i < preview.headers.length; i++)
                _ColumnMappingCard(
                  header: preview.headers[i],
                  suggestion: preview.suggestions[i],
                  sampleValues: [
                    for (final r in preview.sampleRows)
                      if (i < r.length) r[i],
                  ].where((v) => v.trim().isNotEmpty).take(3).toList(),
                  selected: columnFieldByHeader[preview.headers[i]],
                  alreadyMappedElsewhere: _findOtherHeaderForField(
                    columnFieldByHeader,
                    preview.headers[i],
                  ),
                  onChanged: (field) =>
                      onChanged(preview.headers[i], field),
                ),
            ],
          ),
        ),
        if (!hasName) _NoNameWarning(),
        _StepFooter(
          onBack: onBack,
          onContinue: onContinue,
          continueLabel: 'Continue',
          continueEnabled: hasName,
        ),
      ],
    );
  }

  /// Returns the other header that's currently mapped to the same
  /// field as `header`, if any. Used to show a "duplicate mapping"
  /// hint on the card.
  Map<FieldId, String> _findOtherHeaderForField(
    Map<String, FieldId> mapping,
    String header,
  ) {
    final result = <FieldId, String>{};
    for (final e in mapping.entries) {
      if (e.key == header) continue;
      result[e.value] = e.key;
    }
    return result;
  }
}

class _ColumnMappingCard extends StatelessWidget {
  const _ColumnMappingCard({
    required this.header,
    required this.suggestion,
    required this.sampleValues,
    required this.selected,
    required this.alreadyMappedElsewhere,
    required this.onChanged,
  });

  final String header;
  final MappingSuggestion suggestion;
  final List<String> sampleValues;
  final FieldId? selected;
  final Map<FieldId, String> alreadyMappedElsewhere;
  final void Function(FieldId? field) onChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final autoSuggested = suggestion.suggestedField != null &&
        suggestion.suggestedField == selected &&
        suggestion.confidence >= 0.6;
    final selectedOption =
        selected == null ? null : kFieldById[selected];
    final duplicateOf = selected == null
        ? null
        : alreadyMappedElsewhere[selected];
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Text(
                    header.isEmpty ? '(blank column)' : header,
                    style: theme.textTheme.titleMedium,
                  ),
                ),
                if (autoSuggested)
                  Chip(
                    label: const Text('Auto-suggested'),
                    visualDensity: VisualDensity.compact,
                    backgroundColor: theme.colorScheme.primary.withValues(
                      alpha: 0.15,
                    ),
                  ),
              ],
            ),
            if (sampleValues.isNotEmpty) ...[
              const SizedBox(height: 4),
              Text(
                'Sample: ${sampleValues.join(' · ')}',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ],
            const SizedBox(height: 10),
            DropdownButtonFormField<FieldId?>(
              initialValue: selected,
              isExpanded: true,
              decoration: const InputDecoration(
                border: OutlineInputBorder(),
                isDense: true,
                labelText: 'Maps to',
              ),
              items: [
                const DropdownMenuItem<FieldId?>(
                  value: null,
                  child: Text("Don't import"),
                ),
                for (final f in kFieldOptions)
                  DropdownMenuItem<FieldId?>(
                    value: f.id,
                    child: Text(
                      f.unitSuffix == null
                          ? f.label
                          : '${f.label} (${f.unitSuffix})',
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
              ],
              onChanged: onChanged,
            ),
            if (selectedOption?.hint != null) ...[
              const SizedBox(height: 4),
              Text(
                selectedOption!.hint!,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
            if (duplicateOf != null) ...[
              const SizedBox(height: 6),
              Text(
                'Heads up: "$duplicateOf" is also mapped to '
                '${kFieldById[selected]?.label ?? ''}. The last column '
                'wins.',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.tertiary,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _NoNameWarning extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      width: double.infinity,
      color: theme.colorScheme.errorContainer,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      child: Row(
        children: [
          Icon(Icons.error_outline, color: theme.colorScheme.error),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              'You need to map at least one column to "Recipe Name" '
              'before continuing.',
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onErrorContainer,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _SummaryStep extends StatelessWidget {
  const _SummaryStep({
    required this.preview,
    required this.columnFieldByHeader,
    required this.onImport,
    required this.onBack,
  });

  final SpreadsheetPreview preview;
  final Map<String, FieldId> columnFieldByHeader;
  final VoidCallback onImport;
  final VoidCallback onBack;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final mappedFields = columnFieldByHeader.values.toSet();
    final missingCommon = <FieldId>[];
    // FieldId overrides == / hashCode, so a const set element trips
    // Dart 3's `const_set_element_not_primitive_equality` rule. A
    // non-const list backs the same intent and is rebuilt cheaply.
    final commonFields = <FieldId>[
      FieldId.caliber,
      FieldId.powder,
      FieldId.powderChargeGr,
      FieldId.bullet,
      FieldId.bulletWeightGr,
    ];
    for (final f in commonFields) {
      if (!mappedFields.contains(f)) missingCommon.add(f);
    }
    return Column(
      children: [
        Expanded(
          child: ListView(
            padding: const EdgeInsets.all(20),
            children: [
              Text(
                'Step 3 of 4 — Review',
                style: theme.textTheme.labelLarge?.copyWith(
                  color: theme.colorScheme.primary,
                ),
              ),
              const SizedBox(height: 6),
              Text('Ready to import',
                  style: theme.textTheme.titleLarge),
              const SizedBox(height: 16),
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Icon(Icons.upload_file,
                              color: theme.colorScheme.primary),
                          const SizedBox(width: 8),
                          Text(
                            'We\'ll import ${preview.totalDataRows} '
                            'recipe${preview.totalDataRows == 1 ? '' : 's'}.',
                            style: theme.textTheme.titleMedium,
                          ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      Text(
                        'Rows missing a recipe name will be skipped.',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 12),
              if (missingCommon.isNotEmpty)
                Card(
                  color: theme.colorScheme.tertiaryContainer.withValues(
                    alpha: 0.5,
                  ),
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Icon(Icons.info_outline,
                                color: theme.colorScheme.tertiary),
                            const SizedBox(width: 8),
                            Text('Heads up',
                                style: theme.textTheme.titleMedium),
                          ],
                        ),
                        const SizedBox(height: 8),
                        Text(
                          'Some common fields aren\'t mapped. The import '
                          'will still work — those fields just stay '
                          'blank on the imported recipes.',
                          style: theme.textTheme.bodyMedium,
                        ),
                        const SizedBox(height: 8),
                        Wrap(
                          spacing: 6,
                          runSpacing: 6,
                          children: [
                            for (final f in missingCommon)
                              Chip(
                                label: Text(
                                  kFieldById[f]?.label ?? f.id,
                                ),
                                visualDensity: VisualDensity.compact,
                              ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
              const SizedBox(height: 12),
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('Mapping summary',
                          style: theme.textTheme.titleMedium),
                      const SizedBox(height: 8),
                      for (final h in preview.headers)
                        Padding(
                          padding: const EdgeInsets.symmetric(vertical: 2),
                          child: Row(
                            children: [
                              Expanded(
                                child: Text(
                                  h.isEmpty ? '(blank)' : h,
                                  style: theme.textTheme.bodyMedium,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                              const Icon(Icons.arrow_forward, size: 14),
                              const SizedBox(width: 6),
                              Expanded(
                                child: Text(
                                  columnFieldByHeader.containsKey(h)
                                      ? kFieldById[columnFieldByHeader[h]]
                                              ?.label ??
                                          ''
                                      : 'skipped',
                                  style: theme.textTheme.bodyMedium?.copyWith(
                                    color: columnFieldByHeader.containsKey(h)
                                        ? theme.colorScheme.primary
                                        : theme.colorScheme.onSurfaceVariant,
                                  ),
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                            ],
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
        _StepFooter(
          onBack: onBack,
          onContinue: onImport,
          continueLabel: 'Import',
          continueEnabled: true,
        ),
      ],
    );
  }
}

class _ImportingStep extends StatelessWidget {
  const _ImportingStep({required this.processed, required this.total});

  final int processed;
  final int total;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final value = total == 0 ? null : processed / total;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('Importing…', style: theme.textTheme.titleLarge),
            const SizedBox(height: 16),
            LinearProgressIndicator(value: value),
            const SizedBox(height: 8),
            Text(
              total == 0
                  ? 'Reading file…'
                  : '$processed of $total rows',
              style: theme.textTheme.bodySmall,
            ),
          ],
        ),
      ),
    );
  }
}

class _DoneStep extends StatelessWidget {
  const _DoneStep({
    required this.result,
    required this.onViewRecipes,
    required this.onImportAnother,
  });

  final SpreadsheetImportResult result;
  final VoidCallback onViewRecipes;
  final VoidCallback onImportAnother;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ListView(
      padding: const EdgeInsets.all(20),
      children: [
        const SizedBox(height: 24),
        Center(
          child: Icon(
            Icons.check_circle_outline,
            size: 80,
            color: theme.colorScheme.primary,
          ),
        ),
        const SizedBox(height: 12),
        Center(
          child: Text(
            'Imported ${result.imported} recipe'
            '${result.imported == 1 ? '' : 's'}.',
            style: theme.textTheme.headlineSmall,
            textAlign: TextAlign.center,
          ),
        ),
        const SizedBox(height: 8),
        if (result.skipped > 0)
          Center(
            child: Text(
              '${result.skipped} row${result.skipped == 1 ? '' : 's'} '
              'skipped (missing recipe name).',
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
              textAlign: TextAlign.center,
            ),
          ),
        if (result.hasErrors) ...[
          const SizedBox(height: 12),
          Card(
            color: theme.colorScheme.errorContainer.withValues(alpha: 0.5),
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('${result.errors.length} warning'
                      '${result.errors.length == 1 ? '' : 's'}',
                      style: theme.textTheme.titleSmall),
                  const SizedBox(height: 6),
                  for (final e in result.errors.take(5))
                    Text('• $e', style: theme.textTheme.bodySmall),
                  if (result.errors.length > 5)
                    Text(
                      '…and ${result.errors.length - 5} more.',
                      style: theme.textTheme.bodySmall,
                    ),
                ],
              ),
            ),
          ),
        ],
        const SizedBox(height: 16),
        Center(
          child: Text(
            'Tap any imported recipe to add details.',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
            textAlign: TextAlign.center,
          ),
        ),
        const SizedBox(height: 16),
        // Privacy reassurance — older / spreadsheet users want to see
        // explicitly that their data isn't being uploaded. Wording
        // matches CLAUDE.md §13.
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          decoration: BoxDecoration(
            color: theme.colorScheme.primaryContainer.withValues(alpha: 0.4),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(
                Icons.shield_outlined,
                size: 18,
                color: theme.colorScheme.primary,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  'Your data stays on your phone. No upload, no '
                  'account required.',
                  style: theme.textTheme.bodySmall,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 24),
        FilledButton.icon(
          icon: const Icon(Icons.list_alt),
          label: const Text('View Recipes'),
          onPressed: onViewRecipes,
        ),
        const SizedBox(height: 8),
        TextButton.icon(
          icon: const Icon(Icons.add_circle_outline),
          label: const Text('Import another file'),
          onPressed: onImportAnother,
        ),
      ],
    );
  }
}

class _StepFooter extends StatelessWidget {
  const _StepFooter({
    required this.onBack,
    required this.onContinue,
    required this.continueLabel,
    required this.continueEnabled,
  });

  final VoidCallback onBack;
  final VoidCallback onContinue;
  final String continueLabel;
  final bool continueEnabled;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Row(
          children: [
            TextButton.icon(
              onPressed: onBack,
              icon: const Icon(Icons.arrow_back),
              label: const Text('Back'),
            ),
            const Spacer(),
            FilledButton.icon(
              onPressed: continueEnabled ? onContinue : null,
              icon: const Icon(Icons.arrow_forward),
              label: Text(continueLabel),
            ),
          ],
        ),
      ),
    );
  }
}

class _InlineError extends StatelessWidget {
  const _InlineError({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: theme.colorScheme.errorContainer,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        children: [
          Icon(Icons.error_outline, color: theme.colorScheme.error),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              message,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onErrorContainer,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// Re-exported for entry-point convenience.
typedef SmartImportEntry = SmartImportScreen;

// Avoid unused-import lint for `recipes_list_screen.dart` — kept in the
// imports so `Navigator.popUntil` style transitions stay near the
// recipes list type once future iterations need them.
// ignore: unused_element
RecipesListScreen _placeholder() => const RecipesListScreen();
