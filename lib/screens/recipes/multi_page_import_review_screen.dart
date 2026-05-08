// FILE: lib/screens/recipes/multi_page_import_review_screen.dart
//
// ============================================================================
// WHAT THIS FILE DOES
// ============================================================================
// Review screen for the multi-page batch photo-import flow. The capture
// screen runs ML Kit OCR on every picked image, segments each page into
// "entries" using whitespace-gap heuristics, parses each segment with
// the existing [RecipeParser], and pushes this screen with one
// [DetectedEntry] per detected recipe.
//
// Each entry renders as a collapsible card with:
//   * Page / segment label so the user can correlate it with their
//     stack of photos.
//   * Five editable Quick-Add-style fields (recipe name, caliber,
//     powder + charge, bullet + weight, COAL).
//   * A discard checkbox so the user can drop a false-positive without
//     leaving the screen.
//
// "Save All" inserts a `UserLoad` for every non-discarded card via
// [RecipeRepository.insert], creates `CustomComponents` rows for any
// powder / bullet / cartridge values that aren't in the catalog, then
// pops back to the recipes list.
//
// ============================================================================
// WHY IT EXISTS IN THE ARCHITECTURE
// ============================================================================
// The single-recipe photo-import flow already has a per-recipe review
// screen. The batch flow has different constraints — the user might
// have 50 entries to skim, so the per-card UI has to be denser. We
// also can't push a separate review screen per entry because that
// would force the user to "Save & Next" 50 times. One screen, one
// "Save All" button.
//
// All processing is on-device. No data leaves the user's phone.
//
// ============================================================================
// WHO CONSUMES THIS FILE
// ============================================================================
// - lib/screens/recipes/photo_import_screen.dart — pushes this screen
//   from the multi-page batch flow.

import 'dart:io';

import 'package:drift/drift.dart' as drift;
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../database/database.dart';
import '../../repositories/component_repository.dart';
import '../../repositories/recipe_repository.dart';
import '../../services/recipe_parser.dart';

/// One detected recipe entry from a multi-page batch import. Built by
/// the capture screen and handed to this review screen.
class DetectedEntry {
  DetectedEntry({
    required this.sourceImagePath,
    required this.pageNumber,
    required this.segmentNumber,
    required this.ocrText,
    required this.draft,
  });

  /// Absolute path to the photo this entry came from. Rendered as a
  /// thumbnail on the entry card so the user can verify which page the
  /// parsed values came from.
  final String sourceImagePath;

  /// 1-based page number within the picked batch. Shown on the card
  /// label as "Page 3".
  final int pageNumber;

  /// 1-based entry index within the page. Shown as "Page 3 · Entry 2".
  final int segmentNumber;

  /// Raw OCR text from this segment. Used as the recipe's notes
  /// fallback so the user always has the original to refer back to.
  final String ocrText;

  /// Parsed draft. Pre-fills the editable form below.
  final RecipeDraft draft;
}

class MultiPageImportReviewScreen extends StatefulWidget {
  const MultiPageImportReviewScreen({
    super.key,
    required this.entries,
    this.cappedAt,
  });

  final List<DetectedEntry> entries;

  /// When non-null, the OCR pipeline detected more than [cappedAt]
  /// entries and we stopped at this many. Surfaced as a banner so the
  /// user knows to run another import for the remaining pages.
  final int? cappedAt;

  @override
  State<MultiPageImportReviewScreen> createState() =>
      _MultiPageImportReviewScreenState();
}

class _MultiPageImportReviewScreenState
    extends State<MultiPageImportReviewScreen> {
  late final List<_EntryFormState> _states;

  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _states = [
      for (final e in widget.entries) _EntryFormState.from(e),
    ];
  }

  @override
  void dispose() {
    for (final s in _states) {
      s.dispose();
    }
    super.dispose();
  }

  String? _emptyToNull(String s) {
    final t = s.trim();
    return t.isEmpty ? null : t;
  }

  /// Save every non-discarded entry to the recipes table. Mirrors the
  /// single-recipe save in `PhotoImportReviewScreen` so the resulting
  /// rows are indistinguishable from a manually-entered recipe.
  Future<void> _saveAll() async {
    setState(() => _busy = true);
    final repo = context.read<RecipeRepository>();
    final components = context.read<ComponentRepository>();

    Future<void> ensureCustom(String kind, String value) async {
      final v = value.trim();
      if (v.isEmpty) return;
      final known = await components.componentLabels(kind);
      if (!known.contains(v)) {
        await components.addCustomComponent(kind, v);
      }
    }

    var saved = 0;
    try {
      for (final s in _states) {
        if (s.discarded) continue;
        if (s.name.text.trim().isEmpty) {
          // Auto-name unnamed entries from page/segment so users don't
          // hit a wall on Save All — the user can rename later.
          s.name.text = 'Imported entry ${s.pageNumber}-${s.segmentNumber}';
        }
        await Future.wait([
          ensureCustom('cartridge', s.caliber.text),
          ensureCustom('powder', s.powder.text),
          ensureCustom('bullet', s.bullet.text),
        ]);
        await repo.insert(
          UserLoadsCompanion(
            name: drift.Value(s.name.text.trim()),
            caliber: drift.Value(_emptyToNull(s.caliber.text)),
            powder: drift.Value(_emptyToNull(s.powder.text)),
            powderChargeGr:
                drift.Value(double.tryParse(s.powderCharge.text.trim())),
            bullet: drift.Value(_emptyToNull(s.bullet.text)),
            bulletWeightGr:
                drift.Value(double.tryParse(s.bulletWeight.text.trim())),
            coalIn: drift.Value(double.tryParse(s.coal.text.trim())),
            notes: drift.Value(_emptyToNull(s.notes.text)),
          ),
        );
        saved += 1;
      }
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            saved == 1
                ? '1 recipe imported.'
                : '$saved recipes imported.',
          ),
        ),
      );
      // Pop both the review screen and the capture screen so the user
      // lands on the recipes list.
      Navigator.of(context)
        ..pop()
        ..pop();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final keptCount = _states.where((s) => !s.discarded).length;
    final cap = widget.cappedAt;
    return Scaffold(
      appBar: AppBar(
        title: Text('Review ${widget.entries.length} entries'),
        leading: IconButton(
          icon: const Icon(Icons.close),
          tooltip: 'Cancel',
          onPressed: () => Navigator.of(context).pop(),
        ),
      ),
      body: SafeArea(
        child: Column(
          children: [
            if (cap != null)
              Container(
                width: double.infinity,
                padding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                color: theme.colorScheme.errorContainer.withValues(alpha: 0.5),
                child: Row(
                  children: [
                    Icon(
                      Icons.warning_amber_outlined,
                      color: theme.colorScheme.error,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        'Found more than $cap entries — review the first $cap '
                        'shown here and run another import for the rest.',
                        style: theme.textTheme.bodySmall,
                      ),
                    ),
                  ],
                ),
              ),
            Expanded(
              child: AbsorbPointer(
                absorbing: _busy,
                child: ListView.builder(
                  padding: const EdgeInsets.fromLTRB(12, 12, 12, 24),
                  itemCount: _states.length,
                  itemBuilder: (_, i) => _EntryCard(
                    index: i + 1,
                    state: _states[i],
                    onChanged: () => setState(() {}),
                  ),
                ),
              ),
            ),
            SafeArea(
              top: false,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        '$keptCount of ${_states.length} kept',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                    FilledButton.icon(
                      onPressed: (_busy || keptCount == 0) ? null : _saveAll,
                      icon: const Icon(Icons.check),
                      label: Text('Save all ($keptCount)'),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Mutable state for one entry on the review screen. Owns the field
/// controllers + the discarded flag.
class _EntryFormState {
  _EntryFormState({
    required this.sourceImagePath,
    required this.pageNumber,
    required this.segmentNumber,
    required this.ocrText,
    required this.name,
    required this.caliber,
    required this.powder,
    required this.powderCharge,
    required this.bullet,
    required this.bulletWeight,
    required this.coal,
    required this.notes,
  });

  factory _EntryFormState.from(DetectedEntry e) {
    final d = e.draft;
    String formatNum(double v) {
      if (v == v.truncateToDouble()) return v.toStringAsFixed(0);
      return v.toString();
    }

    return _EntryFormState(
      sourceImagePath: e.sourceImagePath,
      pageNumber: e.pageNumber,
      segmentNumber: e.segmentNumber,
      ocrText: e.ocrText,
      name: TextEditingController(text: d.recipeName ?? ''),
      caliber: TextEditingController(text: d.caliber?.value ?? ''),
      powder: TextEditingController(text: d.powder?.value ?? ''),
      powderCharge: TextEditingController(
        text: d.powderChargeGr == null
            ? ''
            : formatNum(d.powderChargeGr!.value),
      ),
      bullet: TextEditingController(text: d.bullet?.value ?? ''),
      bulletWeight: TextEditingController(
        text: d.bulletWeightGr == null
            ? ''
            : formatNum(d.bulletWeightGr!.value),
      ),
      coal: TextEditingController(
        text: d.coalIn == null ? '' : formatNum(d.coalIn!.value),
      ),
      notes: TextEditingController(text: e.ocrText),
    );
  }

  final String sourceImagePath;
  final int pageNumber;
  final int segmentNumber;
  final String ocrText;

  final TextEditingController name;
  final TextEditingController caliber;
  final TextEditingController powder;
  final TextEditingController powderCharge;
  final TextEditingController bullet;
  final TextEditingController bulletWeight;
  final TextEditingController coal;
  final TextEditingController notes;

  /// True when the user has unchecked this entry. Save All skips
  /// discarded entries.
  bool discarded = false;

  void dispose() {
    name.dispose();
    caliber.dispose();
    powder.dispose();
    powderCharge.dispose();
    bullet.dispose();
    bulletWeight.dispose();
    coal.dispose();
    notes.dispose();
  }
}

class _EntryCard extends StatelessWidget {
  const _EntryCard({
    required this.index,
    required this.state,
    required this.onChanged,
  });

  final int index;
  final _EntryFormState state;
  final VoidCallback onChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final label =
        '#$index · Page ${state.pageNumber} · Entry ${state.segmentNumber}';
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 6),
      clipBehavior: Clip.antiAlias,
      child: Opacity(
        opacity: state.discarded ? 0.5 : 1.0,
        child: ExpansionTile(
          initiallyExpanded: !state.discarded,
          tilePadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
          childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          leading: SizedBox(
            width: 40,
            height: 40,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(6),
              child: Image.file(
                File(state.sourceImagePath),
                fit: BoxFit.cover,
                errorBuilder: (_, _, _) => Icon(
                  Icons.image_not_supported_outlined,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ),
          ),
          title: Text(
            state.name.text.isEmpty ? label : state.name.text,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          subtitle: Text(
            state.discarded ? 'Discarded — will not be saved' : label,
            style: theme.textTheme.bodySmall,
          ),
          trailing: Checkbox(
            value: !state.discarded,
            onChanged: (v) {
              state.discarded = !(v ?? false);
              onChanged();
            },
          ),
          children: [
            TextFormField(
              controller: state.name,
              decoration: const InputDecoration(labelText: 'Recipe Name'),
              onChanged: (_) => onChanged(),
            ),
            const SizedBox(height: 8),
            TextFormField(
              controller: state.caliber,
              decoration: const InputDecoration(labelText: 'Caliber'),
            ),
            const SizedBox(height: 8),
            Row(children: [
              Expanded(
                child: TextFormField(
                  controller: state.powder,
                  decoration: const InputDecoration(labelText: 'Powder'),
                ),
              ),
              const SizedBox(width: 8),
              SizedBox(
                width: 100,
                child: TextFormField(
                  controller: state.powderCharge,
                  decoration: const InputDecoration(
                    labelText: 'Charge',
                    suffixText: 'gr',
                  ),
                  keyboardType:
                      const TextInputType.numberWithOptions(decimal: true),
                ),
              ),
            ]),
            const SizedBox(height: 8),
            Row(children: [
              Expanded(
                child: TextFormField(
                  controller: state.bullet,
                  decoration: const InputDecoration(labelText: 'Bullet'),
                ),
              ),
              const SizedBox(width: 8),
              SizedBox(
                width: 100,
                child: TextFormField(
                  controller: state.bulletWeight,
                  decoration: const InputDecoration(
                    labelText: 'Weight',
                    suffixText: 'gr',
                  ),
                  keyboardType:
                      const TextInputType.numberWithOptions(decimal: true),
                ),
              ),
            ]),
            const SizedBox(height: 8),
            TextFormField(
              controller: state.coal,
              decoration: const InputDecoration(
                labelText: 'COAL',
                suffixText: 'in',
              ),
              keyboardType:
                  const TextInputType.numberWithOptions(decimal: true),
            ),
            const SizedBox(height: 8),
            TextFormField(
              controller: state.notes,
              decoration: const InputDecoration(labelText: 'Notes / OCR text'),
              maxLines: 3,
            ),
          ],
        ),
      ),
    );
  }
}
