// FILE: lib/screens/brass_lots/quick_add_brass_lot_screen.dart
//
// ============================================================================
// WHAT THIS FILE DOES
// ============================================================================
// One-screen, no-sections brass lot form for users who just want to
// stamp "I picked up 100 cases of Lapua brass today" without filling in
// the full lifecycle form. Captures only:
//
//   1. Headstamp / lot name (required)
//   2. Caliber (with autocomplete from the cartridges catalog)
//   3. Count (number of cases on hand)
//
// On save the form writes a `BrassLotsCompanion` to `BrassLotRepository`
// the same way the long-form brass lot screen does, then pops back to the
// brass lots list.
//
// ============================================================================
// WHY IT EXISTS IN THE ARCHITECTURE
// ============================================================================
// The long-form `BrassLotFormScreen` exposes every column on the
// `BrassLots` table — five sections of fields (identification,
// quantity & life, measurements, prep flags, notes), plus a Quick
// Actions card on existing lots. For the moment-of-restocking
// scenario ("I just got 200 cases at the gun show"), that's overkill.
// Quick Add gives the reloader the three fields they need on the
// shop floor.
//
// Reachable from the new "Quick" extended FAB on
// `BrassLotsListScreen`. The original `+` FAB still pushes the
// detailed form for users who want every field.
//
// ============================================================================
// WHY THIS IS HARDER THAN IT LOOKS
// ============================================================================
// 1. **Caliber is required by the schema.** The `BrassLots` table
//    declares `caliber` as non-nullable text. We make the field
//    required in the form so the save path can't insert an empty
//    string. The detailed form handles this the same way.
// 2. **Custom calibers must persist.** Same as the firearm Quick Add:
//    a typed-in caliber that isn't in the catalog is recorded via
//    `ComponentRepository.addCustomComponent` so it appears in future
//    dropdowns.
// 3. **"Switch to detailed" preserves the row id.** After saving, we
//    resolve back to a `BrassLotRow` and `pushReplacement` the long
//    form so the user can keep editing without back-stack pollution.
//
// ============================================================================
// WHO CONSUMES THIS FILE
// ============================================================================
// - lib/screens/brass_lots/brass_lots_list_screen.dart — the new
//   "Quick" extended FAB pushes this screen.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../database/database.dart';
import '../../repositories/brass_lot_repository.dart';
import '../../repositories/component_repository.dart';
import '../../widgets/component_field.dart';
import 'brass_lot_form_screen.dart';

class QuickAddBrassLotScreen extends StatefulWidget {
  const QuickAddBrassLotScreen({super.key});

  @override
  State<QuickAddBrassLotScreen> createState() =>
      _QuickAddBrassLotScreenState();
}

class _QuickAddBrassLotScreenState extends State<QuickAddBrassLotScreen> {
  final _formKey = GlobalKey<FormState>();

  final _name = TextEditingController();
  final _caliber = TextEditingController();
  final _count = TextEditingController(text: '0');

  bool _busy = false;

  @override
  void dispose() {
    _name.dispose();
    _caliber.dispose();
    _count.dispose();
    super.dispose();
  }

  /// Persist the row, returning its new id (or null on validation
  /// failure). Shared between [_save] (insert + pop) and
  /// [_switchToDetailed] (insert + push detailed form).
  Future<int?> _persist({required bool showSnack}) async {
    if (!_formKey.currentState!.validate()) return null;
    final repo = context.read<BrassLotRepository>();
    final components = context.read<ComponentRepository>();
    setState(() => _busy = true);
    try {
      final caliber = _caliber.text.trim();
      // Persist a typed-in caliber that isn't already known.
      final known = await components.componentLabels('cartridge');
      if (!known.contains(caliber)) {
        await components.addCustomComponent('cartridge', caliber);
      }
      final count = int.tryParse(_count.text.trim()) ?? 0;
      final id = await repo.insert(
        BrassLotsCompanion.insert(
          name: _name.text.trim(),
          caliber: caliber,
          count: count.clamp(0, 1 << 31),
        ),
      );
      if (mounted && showSnack) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Brass lot saved.')),
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
    final repo = context.read<BrassLotRepository>();
    final row = await repo.getById(id);
    if (row == null || !mounted) return;
    Navigator.of(context).pushReplacement(
      MaterialPageRoute(
        builder: (_) => BrassLotFormScreen(existing: row),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Quick Add Brass Lot')),
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
                  labelText: 'Headstamp / Lot Name *',
                  helperText: 'e.g. "Lapua 6.5 CM lot 0124"',
                ),
                validator: (v) => (v == null || v.trim().isEmpty)
                    ? 'Required'
                    : null,
              ),
              const SizedBox(height: 12),
              ComponentField(
                kind: 'cartridge',
                label: 'Caliber *',
                controller: _caliber,
                helper: 'Pick from catalog or type your own',
                validator: (v) => (v == null || v.trim().isEmpty)
                    ? 'Required'
                    : null,
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _count,
                decoration: const InputDecoration(
                  labelText: 'Count',
                  helperText: 'Cases on hand right now',
                ),
                keyboardType: TextInputType.number,
                inputFormatters: [FilteringTextInputFormatter.digitsOnly],
              ),
              const SizedBox(height: 24),
              FilledButton(
                onPressed: _busy ? null : _save,
                child: const Text('Save Brass Lot'),
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
                  'Adds firing count, anneal history, neck wall, prep flags.',
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
