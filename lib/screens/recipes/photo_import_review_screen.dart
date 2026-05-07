// FILE: lib/screens/recipes/photo_import_review_screen.dart
//
// ============================================================================
// WHAT THIS FILE DOES
// ============================================================================
// Editable preview of a `RecipeDraft` produced by the photo-import
// pipeline. Mirrors the field set on `QuickAddRecipeScreen` so a user
// who picks "Photo import -> Save" lands the same kind of recipe row a
// user who typed it in by hand would.
//
// Each parsed field shows three things:
//   1. A standard `TextFormField` defaulted to the parsed value.
//   2. A small linear progress bar color-coded by confidence:
//      ≥ 0.75 green, 0.5..0.75 amber, < 0.5 red. Hidden once the user
//      types into the field (the value is now theirs, not the parser's).
//   3. A "Source: <ocr snippet>" caption beneath the bar, also hidden
//      after edit.
//
// Bottom row has "Discard" (pop without saving) and "Save Recipe"
// (insert a new `UserLoad` row via `RecipeRepository`, snackbar, pop
// back to the recipes list).
//
// ============================================================================
// WHY IT EXISTS IN THE ARCHITECTURE
// ============================================================================
// The OCR + parsing pass is intentionally not a black box. Reloading is
// safety-critical and a misread "41.5 gr" as "415 gr" would be
// dangerous. The review step makes the user the final arbiter — every
// parsed field is editable, every confidence is visible, and the raw
// OCR text gets stashed in the recipe's notes so the original is
// preserved.
//
// ============================================================================
// WHY THIS IS HARDER THAN IT LOOKS
// ============================================================================
// 1. **Confidence-vs-edit interaction.** The confidence bar makes
//    sense only while the field still holds the parser's value. The
//    moment the user edits, the bar becomes misleading — so we hide
//    it. We track edits per-field via a `Set<_FieldKey>` keyed by the
//    target field, listening to each controller.
//
// 2. **Custom components have to be persisted.** Same pattern as
//    Quick Add — if the user keeps the parser's "H4350" value (or
//    types a different powder), we add it to `CustomComponents` so
//    future autocomplete dropdowns surface it.
//
// 3. **Either-COAL-or-CBTO pattern.** Same as Quick Add. The parser
//    might have found one or both; we pick the higher-confidence one
//    as the initial axis selection and let the user toggle.
//
// ============================================================================
// WHO CONSUMES THIS FILE
// ============================================================================
// - `lib/screens/recipes/photo_import_screen.dart` — pushes this
//   screen with the parsed `RecipeDraft`.
//
// ============================================================================
// SIDE EFFECTS
// ============================================================================
// - Calls `RecipeRepository.insert` on save.
// - Calls `ComponentRepository.addCustomComponent` for any user-typed
//   component values that aren't already in the catalog.
// - Pops itself + the photo-import screen on save success so the user
//   lands back on the recipes list.

import 'dart:io';

import 'package:drift/drift.dart' as drift;
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../database/database.dart';
import '../../repositories/component_repository.dart';
import '../../repositories/recipe_repository.dart';
import '../../services/recipe_parser.dart';
import '../../widgets/component_field.dart';

enum _DimensionAxis { coal, cbto }

/// Editable form pre-filled from a parsed photo-import draft. Saves a
/// new recipe via `RecipeRepository.insert` then pops back twice
/// (review + capture screens) so the user lands on the recipes list.
class PhotoImportReviewScreen extends StatefulWidget {
  const PhotoImportReviewScreen({
    super.key,
    required this.draft,
    required this.imagePath,
    required this.ocrText,
  });

  final RecipeDraft draft;
  final String imagePath;
  final String ocrText;

  @override
  State<PhotoImportReviewScreen> createState() =>
      _PhotoImportReviewScreenState();
}

class _PhotoImportReviewScreenState extends State<PhotoImportReviewScreen> {
  final _formKey = GlobalKey<FormState>();

  late final TextEditingController _name;
  late final TextEditingController _caliber;
  late final TextEditingController _powder;
  late final TextEditingController _powderCharge;
  late final TextEditingController _bullet;
  late final TextEditingController _bulletWeight;
  late final TextEditingController _primer;
  late final TextEditingController _brass;
  late final TextEditingController _dimension;
  late final TextEditingController _notes;

  /// Tracks which fields the user has edited away from the parser
  /// default. Once edited, the source-and-confidence affordance under
  /// the field hides.
  final Set<_FieldKey> _editedFields = <_FieldKey>{};

  _DimensionAxis _axis = _DimensionAxis.coal;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    final d = widget.draft;
    _name = TextEditingController(text: d.recipeName ?? '');
    _caliber = TextEditingController(text: d.caliber?.value ?? '');
    _powder = TextEditingController(text: d.powder?.value ?? '');
    _powderCharge = TextEditingController(
      text: d.powderChargeGr == null
          ? ''
          : _formatNum(d.powderChargeGr!.value),
    );
    _bullet = TextEditingController(text: d.bullet?.value ?? '');
    _bulletWeight = TextEditingController(
      text: d.bulletWeightGr == null
          ? ''
          : _formatNum(d.bulletWeightGr!.value),
    );
    _primer = TextEditingController(text: d.primer?.value ?? '');
    _brass = TextEditingController(text: d.brass?.value ?? '');

    // Initial axis: pick the one with non-null AND higher confidence.
    final coalConf = d.coalIn?.confidence ?? -1;
    final cbtoConf = d.cbtoIn?.confidence ?? -1;
    if (cbtoConf > coalConf && d.cbtoIn != null) {
      _axis = _DimensionAxis.cbto;
      _dimension = TextEditingController(text: _formatNum(d.cbtoIn!.value));
    } else if (d.coalIn != null) {
      _axis = _DimensionAxis.coal;
      _dimension = TextEditingController(text: _formatNum(d.coalIn!.value));
    } else if (d.cbtoIn != null) {
      _axis = _DimensionAxis.cbto;
      _dimension = TextEditingController(text: _formatNum(d.cbtoIn!.value));
    } else {
      _dimension = TextEditingController();
    }

    _notes = TextEditingController(text: d.notes ?? '');

    // Attach edit listeners. Track edits relative to the parsed
    // initial value so re-typing the same string doesn't clear the
    // confidence affordance.
    _wireEditListener(_caliber, _FieldKey.caliber, d.caliber?.value);
    _wireEditListener(_powder, _FieldKey.powder, d.powder?.value);
    _wireEditListener(
      _powderCharge,
      _FieldKey.powderCharge,
      d.powderChargeGr == null ? null : _formatNum(d.powderChargeGr!.value),
    );
    _wireEditListener(_bullet, _FieldKey.bullet, d.bullet?.value);
    _wireEditListener(
      _bulletWeight,
      _FieldKey.bulletWeight,
      d.bulletWeightGr == null ? null : _formatNum(d.bulletWeightGr!.value),
    );
    _wireEditListener(_primer, _FieldKey.primer, d.primer?.value);
    _wireEditListener(_brass, _FieldKey.brass, d.brass?.value);
  }

  void _wireEditListener(
    TextEditingController controller,
    _FieldKey key,
    String? initial,
  ) {
    final initialText = initial ?? '';
    controller.addListener(() {
      final edited = controller.text != initialText;
      if (edited && !_editedFields.contains(key)) {
        setState(() => _editedFields.add(key));
      } else if (!edited && _editedFields.contains(key)) {
        setState(() => _editedFields.remove(key));
      }
    });
  }

  @override
  void dispose() {
    _name.dispose();
    _caliber.dispose();
    _powder.dispose();
    _powderCharge.dispose();
    _bullet.dispose();
    _bulletWeight.dispose();
    _primer.dispose();
    _brass.dispose();
    _dimension.dispose();
    _notes.dispose();
    super.dispose();
  }

  String _formatNum(double v) {
    if (v == v.truncateToDouble()) return v.toStringAsFixed(0);
    return v.toString();
  }

  String? _emptyToNull(String s) {
    final t = s.trim();
    return t.isEmpty ? null : t;
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
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

    try {
      await Future.wait([
        ensureCustom('cartridge', _caliber.text),
        ensureCustom('powder', _powder.text),
        ensureCustom('bullet', _bullet.text),
        ensureCustom('primer', _primer.text),
        ensureCustom('brass', _brass.text),
      ]);

      final coalText =
          _axis == _DimensionAxis.coal ? _dimension.text : '';
      final cbtoText =
          _axis == _DimensionAxis.cbto ? _dimension.text : '';

      await repo.insert(
        UserLoadsCompanion(
          name: drift.Value(_name.text.trim()),
          caliber: drift.Value(_emptyToNull(_caliber.text)),
          powder: drift.Value(_emptyToNull(_powder.text)),
          powderChargeGr:
              drift.Value(double.tryParse(_powderCharge.text.trim())),
          bullet: drift.Value(_emptyToNull(_bullet.text)),
          bulletWeightGr:
              drift.Value(double.tryParse(_bulletWeight.text.trim())),
          primer: drift.Value(_emptyToNull(_primer.text)),
          brass: drift.Value(_emptyToNull(_brass.text)),
          coalIn: drift.Value(double.tryParse(coalText.trim())),
          cbtoIn: drift.Value(double.tryParse(cbtoText.trim())),
          notes: drift.Value(_emptyToNull(_notes.text)),
        ),
      );

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Recipe imported from photo.')),
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
    final draft = widget.draft;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Review imported recipe'),
      ),
      body: AbsorbPointer(
        absorbing: _busy,
        child: Form(
          key: _formKey,
          child: ListView(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
            children: [
              // Thumbnail of the captured image so the user can compare
              // the parsed values against the original at a glance.
              ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: AspectRatio(
                  aspectRatio: 4 / 3,
                  child: Image.file(
                    File(widget.imagePath),
                    fit: BoxFit.cover,
                    errorBuilder: (_, _, _) => Container(
                      color: theme.colorScheme.surfaceContainerHighest,
                      alignment: Alignment.center,
                      child: const Icon(Icons.image_not_supported_outlined),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 12),
              Text(
                'Check each field below before saving. Values we\'re less '
                'confident about are highlighted.',
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 16),
              TextFormField(
                controller: _name,
                decoration: const InputDecoration(
                  labelText: 'Recipe Name *',
                ),
                validator: (v) =>
                    (v == null || v.trim().isEmpty) ? 'Required' : null,
              ),
              const SizedBox(height: 12),
              ComponentField(
                kind: 'cartridge',
                label: 'Caliber',
                controller: _caliber,
              ),
              _ConfidenceCaption(
                parsed: draft.caliber,
                edited: _editedFields.contains(_FieldKey.caliber),
              ),
              const SizedBox(height: 12),
              ComponentField(
                kind: 'powder',
                label: 'Powder',
                controller: _powder,
              ),
              _ConfidenceCaption(
                parsed: draft.powder,
                edited: _editedFields.contains(_FieldKey.powder),
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _powderCharge,
                decoration: const InputDecoration(
                  labelText: 'Powder Charge (gr)',
                  suffixText: 'gr',
                ),
                keyboardType:
                    const TextInputType.numberWithOptions(decimal: true),
              ),
              _ConfidenceCaption(
                parsed: draft.powderChargeGr,
                edited: _editedFields.contains(_FieldKey.powderCharge),
              ),
              const SizedBox(height: 12),
              ComponentField(
                kind: 'bullet',
                label: 'Bullet',
                controller: _bullet,
              ),
              _ConfidenceCaption(
                parsed: draft.bullet,
                edited: _editedFields.contains(_FieldKey.bullet),
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _bulletWeight,
                decoration: const InputDecoration(
                  labelText: 'Bullet Weight (gr)',
                  suffixText: 'gr',
                ),
                keyboardType:
                    const TextInputType.numberWithOptions(decimal: true),
              ),
              _ConfidenceCaption(
                parsed: draft.bulletWeightGr,
                edited: _editedFields.contains(_FieldKey.bulletWeight),
              ),
              const SizedBox(height: 12),
              ComponentField(
                kind: 'primer',
                label: 'Primer',
                controller: _primer,
              ),
              _ConfidenceCaption(
                parsed: draft.primer,
                edited: _editedFields.contains(_FieldKey.primer),
              ),
              const SizedBox(height: 12),
              ComponentField(
                kind: 'brass',
                label: 'Brass',
                controller: _brass,
              ),
              _ConfidenceCaption(
                parsed: draft.brass,
                edited: _editedFields.contains(_FieldKey.brass),
              ),
              const SizedBox(height: 16),
              SegmentedButton<_DimensionAxis>(
                segments: const [
                  ButtonSegment(
                    value: _DimensionAxis.coal,
                    label: Text('COAL'),
                  ),
                  ButtonSegment(
                    value: _DimensionAxis.cbto,
                    label: Text('CBTO'),
                  ),
                ],
                selected: {_axis},
                onSelectionChanged: (s) {
                  setState(() {
                    _axis = s.first;
                    final dr = widget.draft;
                    _dimension.text = _axis == _DimensionAxis.coal
                        ? (dr.coalIn == null
                            ? ''
                            : _formatNum(dr.coalIn!.value))
                        : (dr.cbtoIn == null
                            ? ''
                            : _formatNum(dr.cbtoIn!.value));
                  });
                },
              ),
              const SizedBox(height: 8),
              TextFormField(
                controller: _dimension,
                decoration: InputDecoration(
                  labelText: _axis == _DimensionAxis.coal
                      ? 'COAL (in)'
                      : 'CBTO (in)',
                  suffixText: 'in',
                ),
                keyboardType:
                    const TextInputType.numberWithOptions(decimal: true),
              ),
              _ConfidenceCaption(
                parsed: _axis == _DimensionAxis.coal
                    ? widget.draft.coalIn
                    : widget.draft.cbtoIn,
                edited: false,
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _notes,
                decoration: const InputDecoration(
                  labelText: 'Notes',
                  helperText:
                      'Pre-filled with the OCR text — keep it for the record '
                      'or replace with your own.',
                ),
                maxLines: 6,
                minLines: 3,
              ),
              const SizedBox(height: 24),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      onPressed:
                          _busy ? null : () => Navigator.of(context).pop(),
                      child: const Text('Discard'),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    flex: 2,
                    child: FilledButton.icon(
                      onPressed: _busy ? null : _save,
                      icon: const Icon(Icons.save_outlined),
                      label: const Text('Save Recipe'),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Renders the small "Source: …" caption + confidence bar under a
/// parsed field. Hidden once the user starts editing — the bar isn't
/// meaningful for user-typed values.
class _ConfidenceCaption extends StatelessWidget {
  const _ConfidenceCaption({required this.parsed, required this.edited});

  final ParsedField<dynamic>? parsed;
  final bool edited;

  @override
  Widget build(BuildContext context) {
    if (parsed == null || edited) return const SizedBox.shrink();
    final theme = Theme.of(context);
    final value = parsed!.confidence.clamp(0.0, 1.0);
    final color = value >= 0.75
        ? Colors.green
        : value >= 0.5
            ? Colors.amber.shade700
            : Colors.red;
    return Padding(
      padding: const EdgeInsets.only(top: 6, left: 4, right: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(2),
            child: LinearProgressIndicator(
              value: value,
              minHeight: 4,
              backgroundColor: color.withValues(alpha: 0.18),
              valueColor: AlwaysStoppedAnimation(color),
            ),
          ),
          const SizedBox(height: 4),
          Text(
            'Source: ${parsed!.sourceText}',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
        ],
      ),
    );
  }
}

/// Stable identifier for "this field has been edited" tracking. Plain
/// enum — keeps the editor state out of widget rebuilds.
enum _FieldKey {
  caliber,
  powder,
  powderCharge,
  bullet,
  bulletWeight,
  primer,
  brass,
}
