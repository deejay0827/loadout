// FILE: lib/screens/firearms/quick_add_firearm_screen.dart
//
// ============================================================================
// WHAT THIS FILE DOES
// ============================================================================
// One-screen, no-sections firearm form aimed at users who just want to log
// "another rifle" with a name and a caliber. Captures only:
//
//   1. Name (required)
//   2. Caliber (with autocomplete from the cartridges catalog)
//   3. Optional "Pick from Catalog" link that pushes the long-form
//      [FirearmFormScreen] in catalog-picker mode after persisting the
//      partially-filled row.
//
// On save the form writes a `UserFirearmsCompanion` to `FirearmRepository`
// the same way the long-form firearm screen does, then pops back to the
// firearms list.
//
// ============================================================================
// WHY IT EXISTS IN THE ARCHITECTURE
// ============================================================================
// The long-form `FirearmFormScreen` exposes every column on the
// `UserFirearms` table (manufacturer, model, type, action, twist rate,
// throat erosion, optic + reticle links, ballistics defaults, etc.). For
// users who just want to track "I shot 100 rounds out of my Bergara
// today" without filling in 15 fields, that's overkill. Quick Add gives
// them a notebook-line entry — name + caliber — and gets out of the way.
//
// Reachable from the new "Quick" extended FAB on
// `FirearmsListScreen`. The original `+` FAB still pushes the detailed
// form for power users who want every field.
//
// ============================================================================
// WHY THIS IS HARDER THAN IT LOOKS
// ============================================================================
// 1. **Same underlying table as the detailed form.** Both Quick Add and
//    `FirearmFormScreen` write `UserFirearmsCompanion` rows. Saving here
//    and then opening the firearm in the detailed form has to feel
//    seamless — same id, same caliber, same name. We achieve that by
//    reusing `FirearmRepository.insert` (no separate API).
// 2. **Custom calibers must persist.** When the user types a caliber
//    that isn't in the cartridges catalog, we record it via
//    `ComponentRepository.addCustomComponent('cartridge', value)` so it
//    appears in future autocomplete dropdowns. Without this, every new
//    quick-add entry with a niche caliber would create a one-off
//    string that doesn't match the catalog and never appears as a
//    suggestion.
// 3. **"Switch to detailed" preserves the row id.** After saving the
//    minimal row, we resolve it back to a `UserFirearmRow` via
//    `getById` and `pushReplacement` the long form so back-button
//    returns the user to the firearms list, not back into Quick Add.
//
// ============================================================================
// WHO CONSUMES THIS FILE
// ============================================================================
// - lib/screens/firearms/firearms_list_screen.dart — the new "Quick"
//   extended FAB pushes this screen.

import 'package:drift/drift.dart' as drift;
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../database/database.dart';
import '../../repositories/component_repository.dart';
import '../../repositories/firearm_repository.dart';
import '../../widgets/component_field.dart';
import 'firearm_form_screen.dart';

class QuickAddFirearmScreen extends StatefulWidget {
  const QuickAddFirearmScreen({super.key});

  @override
  State<QuickAddFirearmScreen> createState() => _QuickAddFirearmScreenState();
}

class _QuickAddFirearmScreenState extends State<QuickAddFirearmScreen> {
  final _formKey = GlobalKey<FormState>();

  final _name = TextEditingController();
  final _caliber = TextEditingController();

  bool _busy = false;

  @override
  void dispose() {
    _name.dispose();
    _caliber.dispose();
    super.dispose();
  }

  /// Persist the row, returning its new id (or null on validation
  /// failure). Shared between [_save] (insert + pop) and
  /// [_switchToDetailed] (insert + push detailed form).
  Future<int?> _persist({required bool showSnack}) async {
    if (!_formKey.currentState!.validate()) return null;
    final repo = context.read<FirearmRepository>();
    final components = context.read<ComponentRepository>();
    setState(() => _busy = true);
    try {
      // Persist a typed-in caliber that isn't already known so it
      // appears in future autocomplete dropdowns. Mirrors long-form.
      final caliber = _caliber.text.trim();
      if (caliber.isNotEmpty) {
        final known = await components.componentLabels('cartridge');
        if (!known.contains(caliber)) {
          await components.addCustomComponent('cartridge', caliber);
        }
      }
      final id = await repo.insert(
        UserFirearmsCompanion(
          name: drift.Value(_name.text.trim()),
          caliber: drift.Value(caliber.isEmpty ? null : caliber),
        ),
      );
      if (mounted && showSnack) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Firearm saved.')),
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
    final repo = context.read<FirearmRepository>();
    final row = await repo.getById(id);
    if (row == null || !mounted) return;
    Navigator.of(context).pushReplacement(
      MaterialPageRoute(
        builder: (_) => FirearmFormScreen(existing: row),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Quick Add Firearm')),
      body: AbsorbPointer(
        absorbing: _busy,
        child: Form(
          key: _formKey,
          child: ListView(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
            children: [
              TextFormField(
                controller: _name,
                decoration: const InputDecoration(
                  labelText: 'Name *',
                  helperText: 'e.g. "Bergara HMR 6.5CM"',
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
                helper: 'Optional — pick from catalog or type your own',
              ),
              const SizedBox(height: 24),
              FilledButton(
                onPressed: _busy ? null : _save,
                child: const Text('Save Firearm'),
              ),
              const SizedBox(height: 12),
              Center(
                child: TextButton.icon(
                  onPressed: _busy ? null : _switchToDetailed,
                  icon: const Icon(Icons.tune),
                  label: const Text('Pick from catalog · detailed'),
                ),
              ),
              const SizedBox(height: 4),
              Center(
                child: Text(
                  'Adds manufacturer, model, twist rate, optic, and more.',
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
