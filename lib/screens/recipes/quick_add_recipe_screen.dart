// FILE: lib/screens/recipes/quick_add_recipe_screen.dart
//
// ============================================================================
// WHAT THIS FILE DOES
// ============================================================================
// One-screen, no-scrolling, no-sections recipe form aimed at the
// pen-and-paper reloader cohort. Captures only the five fields a
// reloader writes in their notebook line:
//
//   1. Recipe name
//   2. Caliber
//   3. Powder + charge (gr)
//   4. Bullet + weight (gr)
//   5. COAL or CBTO (one of)
//   6. Optional notes
//
// Plus a "Start from a template" picker at the top that pre-fills all
// five fields with a published-data starting load (see
// `lib/data/recipe_templates.dart`).
//
// On save the form writes a `UserLoadsCompanion` to `RecipeRepository`
// the same way the long-form recipe screen does, then pops back to the
// recipes list. There is also a "Switch to detailed" link at the bottom
// that pushes `RecipeFormScreen(existing: row)` so the user can keep
// editing the same recipe in the full form.
//
// ============================================================================
// WHY IT EXISTS IN THE ARCHITECTURE
// ============================================================================
// The product survey shows 66% of reloaders use pen and paper. The
// long-form `RecipeFormScreen` (60+ fields, expandable sections, lot
// pickers, custom-fields support, autosave bookkeeping) is overwhelming
// for that audience. Quick Add is the parallel entry point that mirrors
// their existing notebook line — five fields, one tap to save.
//
// Templates exist for the same reason: a beginner who has never picked
// a charge weight needs a known-good starting point. The disclaimer
// banner ("ALWAYS verify against your current reloading manual") is
// non-negotiable — published starting loads are reference points, not
// recommendations, and the UI has to make that loud.
//
// ============================================================================
// WHY THIS IS HARDER THAN IT LOOKS
// ============================================================================
// 1. **Both `RecipeFormScreen` and Quick Add write to the same
//    underlying `UserLoads` table.** Saving here and then opening the
//    recipe in the long form has to feel seamless — same ID, same
//    fields, same edit history. We achieve that by re-using
//    `RecipeRepository.insert` and pushing `RecipeFormScreen(existing: row)`
//    after save when the user picks "Switch to detailed".
//
// 2. **Custom components must still be persisted on save.** When the
//    user types a powder name that isn't in the catalog, Quick Add
//    writes it to `CustomComponents` so it appears in future dropdowns,
//    matching the long-form behaviour. Forgetting that would be a
//    silent regression (next time the user types the same powder, the
//    autocomplete wouldn't suggest it).
//
// 3. **Template application is one-shot.** Picking a template fills
//    the controllers; the user can then edit any field. Switching
//    templates after editing overwrites — that's by design. The
//    template id is held in state purely for the dropdown's selected
//    indicator; we never read it back at save time.
//
// 4. **Either-COAL-or-CBTO pattern.** Notebooks usually carry one or
//    the other, not both. Quick Add presents a segmented switch that
//    swaps the field's label and target controller. The other field
//    gets cleared so save doesn't accidentally write a stale value
//    from before the swap.
//
// ============================================================================
// WHO CONSUMES THIS FILE
// ============================================================================
// - lib/screens/recipes/recipes_list_screen.dart — the FAB opens a
//   small two-option menu ("Quick Add" / "Detailed Recipe") that
//   pushes either this screen or the long form.

import 'package:drift/drift.dart' as drift;
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../data/recipe_templates.dart';
import '../../database/database.dart';
import '../../repositories/component_repository.dart';
import '../../repositories/recipe_repository.dart';
import '../../services/beginner_mode_service.dart';
import '../../widgets/component_field.dart';
import '../glossary/glossary_screen.dart';
import 'photo_import_screen.dart';
import 'recipe_form_screen.dart';
import 'smart_import_screen.dart';

/// One-of dimension axis used for the COAL/CBTO segmented control. Only
/// one is rendered at a time — the other is cleared when the user
/// switches.
enum _DimensionAxis { coal, cbto }

class QuickAddRecipeScreen extends StatefulWidget {
  const QuickAddRecipeScreen({super.key});

  @override
  State<QuickAddRecipeScreen> createState() => _QuickAddRecipeScreenState();
}

class _QuickAddRecipeScreenState extends State<QuickAddRecipeScreen> {
  final _formKey = GlobalKey<FormState>();

  final _name = TextEditingController();
  final _caliber = TextEditingController();
  final _powder = TextEditingController();
  final _powderCharge = TextEditingController();
  final _bullet = TextEditingController();
  final _bulletWeight = TextEditingController();
  final _dimension = TextEditingController();
  final _notes = TextEditingController();

  _DimensionAxis _axis = _DimensionAxis.coal;

  /// Currently-selected template id (if any). Used only as the
  /// dropdown's indicator value.
  String? _selectedTemplateId;

  /// Pre-fill from useCase on the chosen template, if any. Persisted on
  /// save so the resulting recipe carries it forward.
  String? _useCase;

  bool _busy = false;

  @override
  void dispose() {
    _name.dispose();
    _caliber.dispose();
    _powder.dispose();
    _powderCharge.dispose();
    _bullet.dispose();
    _bulletWeight.dispose();
    _dimension.dispose();
    _notes.dispose();
    super.dispose();
  }

  void _applyTemplate(RecipeTemplate t) {
    setState(() {
      _selectedTemplateId = t.id;
      _name.text = t.name;
      _caliber.text = t.caliber;
      _powder.text = t.powder;
      _powderCharge.text = t.powderChargeGr.toString();
      _bullet.text = t.bullet;
      _bulletWeight.text = t.bulletWeightGr.toString();
      // Templates always provide COAL today. Keep the axis on COAL when
      // applying a template, regardless of the user's prior choice — the
      // user can swap to CBTO afterwards if they prefer.
      _axis = _DimensionAxis.coal;
      _dimension.text = t.coalIn?.toString() ?? '';
      _useCase = t.useCase;
      // Append the template's note to anything the user already wrote.
      // Don't blow away their text — they may have typed something first
      // and only then noticed the template picker.
      final existing = _notes.text.trim();
      final fromTemplate = t.notes ?? '';
      if (existing.isEmpty) {
        _notes.text = fromTemplate;
      } else if (fromTemplate.isNotEmpty &&
          !existing.contains(fromTemplate)) {
        _notes.text = '$existing\n\n$fromTemplate';
      }
    });
  }

  /// Build the `UserLoadsCompanion` representing the current form state.
  /// Shared between `_save` (insert + pop) and "Switch to detailed"
  /// (insert + push detailed form).
  UserLoadsCompanion _buildCompanion() {
    final coalText = _axis == _DimensionAxis.coal ? _dimension.text : '';
    final cbtoText = _axis == _DimensionAxis.cbto ? _dimension.text : '';
    return UserLoadsCompanion(
      name: drift.Value(_name.text.trim()),
      caliber: drift.Value(_emptyToNull(_caliber.text)),
      powder: drift.Value(_emptyToNull(_powder.text)),
      powderChargeGr: drift.Value(double.tryParse(_powderCharge.text.trim())),
      bullet: drift.Value(_emptyToNull(_bullet.text)),
      bulletWeightGr: drift.Value(double.tryParse(_bulletWeight.text.trim())),
      coalIn: drift.Value(double.tryParse(coalText.trim())),
      cbtoIn: drift.Value(double.tryParse(cbtoText.trim())),
      useCase: drift.Value(_useCase),
      notes: drift.Value(_emptyToNull(_notes.text)),
    );
  }

  String? _emptyToNull(String s) {
    final t = s.trim();
    return t.isEmpty ? null : t;
  }

  Future<int?> _persist({required bool showSnack}) async {
    if (!_formKey.currentState!.validate()) return null;
    final repo = context.read<RecipeRepository>();
    final components = context.read<ComponentRepository>();
    setState(() => _busy = true);

    // Persist any typed-in component values to CustomComponents so they
    // appear in future dropdowns. Mirrors the long-form behaviour.
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
      ]);
      final id = await repo.insert(_buildCompanion());
      if (mounted && showSnack) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Recipe saved.')),
        );
      }
      return id;
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _save() async {
    final id = await _persist(showSnack: true);
    if (id == null || !mounted) return;
    Navigator.of(context).pop();
  }

  Future<void> _switchToDetailed() async {
    final id = await _persist(showSnack: false);
    if (id == null || !mounted) return;
    final repo = context.read<RecipeRepository>();
    final row = await repo.getById(id);
    if (row == null || !mounted) return;
    // Replace this Quick Add screen with the long form pre-populated
    // with the just-saved row, so back-button returns the user to the
    // recipes list — not back into Quick Add.
    Navigator.of(context).pushReplacement(
      MaterialPageRoute(
        builder: (_) => RecipeFormScreen(existing: row),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // Glossary shortcut surfaces in the AppBar when Beginner Mode is on
    // so a new reloader can look up "COAL" or "CBTO" mid-entry without
    // hunting through the drawer.
    final beginnerOn = context.watch<BeginnerModeService>().isEnabled;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Quick Add Recipe'),
        actions: [
          if (beginnerOn)
            IconButton(
              tooltip: 'Glossary',
              icon: const Icon(Icons.menu_book_outlined),
              onPressed: () {
                Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => const GlossaryScreen(),
                  ),
                );
              },
            ),
        ],
      ),
      body: AbsorbPointer(
        absorbing: _busy,
        child: Form(
          key: _formKey,
          child: ListView(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
            children: [
              _DisclaimerBanner(),
              const SizedBox(height: 12),
              _TemplatePickerCard(
                selectedId: _selectedTemplateId,
                onPick: _applyTemplate,
              ),
              const SizedBox(height: 12),
              _SmartImportEntryCard(
                onTap: () {
                  Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) => const SmartImportScreen(),
                    ),
                  );
                },
              ),
              if (PhotoImportScreen.isSupportedPlatform) ...[
                const SizedBox(height: 12),
                _PhotoImportEntryCard(
                  onTap: () {
                    Navigator.of(context).push(
                      MaterialPageRoute(
                        builder: (_) => const PhotoImportScreen(),
                      ),
                    );
                  },
                ),
              ],
              const SizedBox(height: 16),
              TextFormField(
                controller: _name,
                decoration: const InputDecoration(
                  labelText: 'Recipe Name *',
                  helperText: 'How you want to find this load later',
                ),
                validator: (v) => (v == null || v.trim().isEmpty)
                    ? 'Required'
                    : null,
              ),
              const SizedBox(height: 12),
              ComponentField(
                kind: 'cartridge',
                label: 'Caliber',
                controller: _caliber,
              ),
              const SizedBox(height: 12),
              ComponentField(
                kind: 'powder',
                label: 'Powder',
                controller: _powder,
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _powderCharge,
                decoration: const InputDecoration(
                  labelText: 'Powder Charge (gr)',
                  suffixText: 'gr',
                  helperText: 'How many grains of powder',
                ),
                keyboardType:
                    const TextInputType.numberWithOptions(decimal: true),
              ),
              const SizedBox(height: 12),
              ComponentField(
                kind: 'bullet',
                label: 'Bullet',
                controller: _bullet,
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
              const SizedBox(height: 16),
              _DimensionAxisPicker(
                axis: _axis,
                onChanged: (a) {
                  setState(() {
                    _axis = a;
                    // Clear the field so the value is unambiguous after
                    // a swap.
                    _dimension.text = '';
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
                  helperText: _axis == _DimensionAxis.coal
                      ? 'Cartridge overall length'
                      : 'Cartridge base to ogive',
                ),
                keyboardType:
                    const TextInputType.numberWithOptions(decimal: true),
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _notes,
                decoration: const InputDecoration(
                  labelText: 'Notes',
                  helperText: 'Anything else you want to remember',
                ),
                maxLines: 3,
              ),
              const SizedBox(height: 24),
              FilledButton(
                onPressed: _busy ? null : _save,
                child: const Text('Save Recipe'),
              ),
              const SizedBox(height: 12),
              Center(
                child: TextButton.icon(
                  onPressed: _busy ? null : _switchToDetailed,
                  icon: const Icon(Icons.tune),
                  label: const Text('Switch to detailed'),
                ),
              ),
              const SizedBox(height: 4),
              Center(
                child: Text(
                  'Adds CBTO, primer, brass, pressure indicators, and more.',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Always-visible "verify your manual" banner. Reloading manuals are the
/// source of truth — Quick Add is a notebook, not a load advisor.
class _DisclaimerBanner extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: theme.colorScheme.errorContainer.withValues(alpha: 0.55),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: theme.colorScheme.error.withValues(alpha: 0.5),
        ),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            Icons.warning_amber_outlined,
            color: theme.colorScheme.error,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              kRecipeTemplateDisclaimer,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onErrorContainer,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Compact "start from a template" affordance. Renders an `ExpansionTile`
/// so the picker doesn't take vertical space until the user opens it.
class _TemplatePickerCard extends StatelessWidget {
  const _TemplatePickerCard({
    required this.selectedId,
    required this.onPick,
  });

  final String? selectedId;
  final ValueChanged<RecipeTemplate> onPick;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      clipBehavior: Clip.antiAlias,
      child: ExpansionTile(
        initiallyExpanded: selectedId == null,
        leading: Icon(
          Icons.bolt_outlined,
          color: theme.colorScheme.primary,
        ),
        title: Text(
          'Start from a template',
          style: theme.textTheme.titleSmall,
        ),
        subtitle: Text(
          selectedId == null
              ? 'Optional — pre-fill with a published starting load'
              : 'Template applied — edit any field below',
          style: theme.textTheme.bodySmall,
        ),
        childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
        children: [
          for (final t in kRecipeTemplates)
            ListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              leading: Icon(
                t.id == selectedId
                    ? Icons.radio_button_checked
                    : Icons.radio_button_unchecked,
                color: t.id == selectedId
                    ? theme.colorScheme.primary
                    : theme.colorScheme.onSurfaceVariant,
              ),
              title: Text(t.name),
              subtitle: Text(
                '${t.powderChargeGr} gr ${t.powder.split(' ').last} '
                '· ${t.bulletWeightGr.toStringAsFixed(0)}gr bullet',
                style: theme.textTheme.bodySmall,
              ),
              onTap: () => onPick(t),
            ),
        ],
      ),
    );
  }
}

/// Compact "Import from spreadsheet" affordance on the Quick Add
/// screen. Routes to the Smart Import wizard so a user with an Excel
/// or CSV table doesn't have to retype every recipe by hand.
class _SmartImportEntryCard extends StatelessWidget {
  const _SmartImportEntryCard({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      clipBehavior: Clip.antiAlias,
      child: ListTile(
        leading: Icon(
          Icons.table_chart_outlined,
          color: theme.colorScheme.primary,
        ),
        title: Text(
          'Import from spreadsheet',
          style: theme.textTheme.titleSmall,
        ),
        subtitle: const Text(
          'Bring in many recipes at once from a CSV or Excel file. Free.',
        ),
        trailing: const Icon(Icons.chevron_right),
        onTap: onTap,
      ),
    );
  }
}

/// Compact "Import from photo" affordance on the Quick Add screen.
/// Mirrors `_SmartImportEntryCard` but routes to the on-device OCR
/// flow for pen-and-paper reloaders. Hidden on platforms that don't
/// support `image_picker` + ML Kit (macOS / web).
class _PhotoImportEntryCard extends StatelessWidget {
  const _PhotoImportEntryCard({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      clipBehavior: Clip.antiAlias,
      child: ListTile(
        leading: Icon(
          Icons.photo_camera_outlined,
          color: theme.colorScheme.primary,
        ),
        title: Text(
          'Import from photo',
          style: theme.textTheme.titleSmall,
        ),
        subtitle: const Text(
          'Snap a notebook page — we read it on this device. Free.',
        ),
        trailing: const Icon(Icons.chevron_right),
        onTap: onTap,
      ),
    );
  }
}

/// Two-segment toggle between COAL and CBTO. Notebooks usually carry one
/// or the other; presenting both at once would clutter the form.
class _DimensionAxisPicker extends StatelessWidget {
  const _DimensionAxisPicker({required this.axis, required this.onChanged});

  final _DimensionAxis axis;
  final ValueChanged<_DimensionAxis> onChanged;

  @override
  Widget build(BuildContext context) {
    return SegmentedButton<_DimensionAxis>(
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
      selected: {axis},
      onSelectionChanged: (s) => onChanged(s.first),
    );
  }
}
