// FILE: lib/screens/firearms/firearm_form_screen.dart
//
// ============================================================================
// WHAT THIS FILE DOES
// ============================================================================
// The firearm create / edit form. Captures every column the
// `UserFirearms` Drift table exposes — name, manufacturer, model, type,
// action, caliber, barrel length, twist rate, round count, optional
// link to a reference firearm, and free-form notes.
//
// The form opens with a `SegmentedButton<bool>` toggle that controls how
// the manufacturer / model / type / action fields are entered:
//
// * "Pick from Catalog" mode (`_useCatalog = true`) renders a
//   `DropdownButtonFormField<_RefEntry>` populated from
//   `ComponentRepository.allReferenceFirearms()`. Picking a row from the
//   catalog calls `_applyReferenceSelection`, which:
//     - records the row's id in `_referenceFirearmId` so it persists on
//       save,
//     - copies manufacturer / model / type / action into the read-only
//       display tiles,
//     - resets the caliber field if the previously-typed value isn't in
//       the reference firearm's caliber list, and surfaces a nested
//       caliber dropdown limited to that firearm's supported calibers.
//
// * "Custom" mode (`_useCatalog = false`) replaces the catalog dropdown
//   with four free-form `TextFormField`s for manufacturer / model /
//   type / action — the path used for unusual builds, wildcatters, and
//   anything not in the bundled reference catalog.
//
// Below the toggle, common fields appear regardless of mode: caliber
// (via the shared `ComponentField` widget so the dropdown surfaces both
// reference and custom cartridges), barrel length, twist rate, the
// shots-fired stepper (a number field flanked by `+`/`-` filled-tonal
// IconButtons that bump the count by 1), and a multi-line notes field.
//
// On save (`_save`), a typed-in caliber that isn't in the
// `ComponentRepository.componentLabels('cartridge')` set is persisted as
// a `CustomComponent` so it appears in future dropdowns. Then a
// `UserFirearmsCompanion` is built and routed through
// `FirearmRepository.insert` (create) or `.update` (edit).
//
// ============================================================================
// WHY IT EXISTS IN THE ARCHITECTURE
// ============================================================================
// Reachable from `FirearmsListScreen` — both the FAB (create) and tile
// taps (edit). The mode toggle exists because LoadOut ships a curated
// reference catalog of common firearms (`FirearmsRef`), but no catalog
// can be exhaustive. Letting users link to a catalog row when one fits
// keeps their data normalised; letting them type a custom build avoids
// blocking entries that don't have a catalog match.
//
// ============================================================================
// WHY THIS IS HARDER THAN IT LOOKS
// ============================================================================
// The reference catalog dropdown carries a typed `_RefEntry` record
// (firearm row + manufacturer row + decoded calibers list) rather than
// a plain id. That was a deliberate ergonomic choice: the form needs
// the manufacturer name and the calibers list right after a selection,
// and joining all three at render time avoids per-selection async
// gymnastics. The `_refsFuture` is cached on `initState` so the
// dropdown can render synchronously the first time it's shown.
//
// The two-mode toggle has a subtle state-reset gotcha: switching from
// catalog to custom clears `_selectedRef` and `_referenceFirearmId`
// but does NOT clear the manufacturer / model / type / action text
// controllers, so the user can edit on top of a catalog auto-fill.
// Switching from custom to catalog leaves those text values alone too;
// they're only overwritten when an actual catalog row is picked.
//
// `_bumpShots` clamps the round count between 0 and `1 << 31` so a
// runaway tap can't overflow into a negative number, and the text
// validator rejects negatives. Round-count edits inside the form do
// not call `FirearmRepository.adjustShotsFired` — that's a separate
// path used by per-recipe shot logging. The form path overwrites the
// stored count outright.
//
// The "persist typed-in caliber as a custom cartridge" branch is
// asymmetric with the rest of the form: it writes to
// `CustomComponents` independently of the firearm save. If the user
// types a caliber, then changes their mind and types a different one,
// both end up in `CustomComponents` — that's harmless, just clutter
// in future dropdowns.
//
// ============================================================================
// WHO CONSUMES THIS FILE
// ============================================================================
// - `lib/screens/firearms/firearms_list_screen.dart` — pushes
//   `FirearmFormScreen()` via the FAB and
//   `FirearmFormScreen(existing: f)` via list-tile taps.
//
// ============================================================================
// SIDE EFFECTS
// ============================================================================
// - Reads `ComponentRepository.allReferenceFirearms()` for the catalog
//   dropdown.
// - Reads `ComponentRepository.componentLabels('cartridge')` to
//   determine whether the typed-in caliber needs to be persisted.
// - Calls `ComponentRepository.addCustomComponent('cartridge', ...)`
//   for unrecognised typed-in calibers.
// - Calls `FirearmRepository.insert` or `.update`.
// - Shows a confirmation `SnackBar` on save.
// - Pops the navigator on success.

import 'package:drift/drift.dart' as drift;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../database/database.dart';
import '../../repositories/component_repository.dart';
import '../../repositories/firearm_repository.dart';
import '../../widgets/component_field.dart';

typedef _RefEntry = ({
  FirearmRefRow firearm,
  ManufacturerRow manufacturer,
  List<String> calibers,
});

class FirearmFormScreen extends StatefulWidget {
  const FirearmFormScreen({super.key, this.existing});

  final UserFirearmRow? existing;

  @override
  State<FirearmFormScreen> createState() => _FirearmFormScreenState();
}

class _FirearmFormScreenState extends State<FirearmFormScreen> {
  final _formKey = GlobalKey<FormState>();

  late final TextEditingController _name;
  late final TextEditingController _manufacturer;
  late final TextEditingController _model;
  late final TextEditingController _type;
  late final TextEditingController _action;
  late final TextEditingController _caliber;
  late final TextEditingController _barrelLength;
  late final TextEditingController _twistRate;
  late final TextEditingController _shotsFired;
  late final TextEditingController _notes;

  bool _useCatalog = false;
  bool _busy = false;

  Future<List<_RefEntry>>? _refsFuture;
  _RefEntry? _selectedRef;
  int? _referenceFirearmId;

  @override
  void initState() {
    super.initState();
    final e = widget.existing;
    _name = TextEditingController(text: e?.name ?? '');
    _manufacturer = TextEditingController(text: e?.manufacturer ?? '');
    _model = TextEditingController(text: e?.model ?? '');
    _type = TextEditingController(text: e?.type ?? '');
    _action = TextEditingController(text: e?.action ?? '');
    _caliber = TextEditingController(text: e?.caliber ?? '');
    _barrelLength =
        TextEditingController(text: e?.barrelLengthIn?.toString() ?? '');
    _twistRate = TextEditingController(text: e?.twistRate ?? '');
    _shotsFired = TextEditingController(text: (e?.shotsFired ?? 0).toString());
    _notes = TextEditingController(text: e?.notes ?? '');
    _referenceFirearmId = e?.referenceFirearmId;
    _useCatalog = _referenceFirearmId != null;
    _refsFuture =
        context.read<ComponentRepository>().allReferenceFirearms();
  }

  @override
  void dispose() {
    for (final c in [
      _name,
      _manufacturer,
      _model,
      _type,
      _action,
      _caliber,
      _barrelLength,
      _twistRate,
      _shotsFired,
      _notes,
    ]) {
      c.dispose();
    }
    super.dispose();
  }

  double? _parseDouble(TextEditingController c) {
    final t = c.text.trim();
    if (t.isEmpty) return null;
    return double.tryParse(t);
  }

  int _parseShots() {
    final v = int.tryParse(_shotsFired.text.trim()) ?? 0;
    return v < 0 ? 0 : v;
  }

  void _bumpShots(int delta) {
    final next = (_parseShots() + delta).clamp(0, 1 << 31);
    setState(() => _shotsFired.text = next.toString());
  }

  void _applyReferenceSelection(_RefEntry ref) {
    setState(() {
      _selectedRef = ref;
      _referenceFirearmId = ref.firearm.id;
      _manufacturer.text = ref.manufacturer.name;
      _model.text = ref.firearm.model;
      _type.text = ref.firearm.type;
      _action.text = ref.firearm.action ?? '';
      // If the current caliber isn't part of this reference, reset it so the
      // user must explicitly pick from the chooser.
      if (!ref.calibers.contains(_caliber.text)) {
        _caliber.text =
            ref.calibers.length == 1 ? ref.calibers.first : '';
      }
    });
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() => _busy = true);

    final repo = context.read<FirearmRepository>();
    final components = context.read<ComponentRepository>();
    final messenger = ScaffoldMessenger.of(context);
    final navigator = Navigator.of(context);

    // Persist a typed-in caliber as a custom cartridge so it appears in
    // future dropdowns.
    final caliberText = _caliber.text.trim();
    if (caliberText.isNotEmpty) {
      final known = await components.componentLabels('cartridge');
      if (!known.contains(caliberText)) {
        await components.addCustomComponent('cartridge', caliberText);
      }
    }

    String? nullIfEmpty(TextEditingController c) {
      final t = c.text.trim();
      return t.isEmpty ? null : t;
    }

    final entry = UserFirearmsCompanion(
      name: drift.Value(_name.text.trim()),
      manufacturer: drift.Value(nullIfEmpty(_manufacturer)),
      model: drift.Value(nullIfEmpty(_model)),
      type: drift.Value(nullIfEmpty(_type)),
      action: drift.Value(nullIfEmpty(_action)),
      caliber: drift.Value(nullIfEmpty(_caliber)),
      barrelLengthIn: drift.Value(_parseDouble(_barrelLength)),
      twistRate: drift.Value(nullIfEmpty(_twistRate)),
      shotsFired: drift.Value(_parseShots()),
      referenceFirearmId:
          drift.Value(_useCatalog ? _referenceFirearmId : null),
      notes: drift.Value(nullIfEmpty(_notes)),
    );

    if (widget.existing == null) {
      await repo.insert(entry);
      messenger.showSnackBar(const SnackBar(content: Text('Firearm saved.')));
    } else {
      await repo.update(widget.existing!.id, entry);
      messenger
          .showSnackBar(const SnackBar(content: Text('Firearm updated.')));
    }

    if (mounted) navigator.pop();
  }

  @override
  Widget build(BuildContext context) {
    final isEdit = widget.existing != null;
    return Scaffold(
      appBar: AppBar(title: Text(isEdit ? 'Edit Firearm' : 'New Firearm')),
      body: Form(
        key: _formKey,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            TextFormField(
              controller: _name,
              decoration: const InputDecoration(labelText: 'Name *'),
              validator: (v) =>
                  (v == null || v.trim().isEmpty) ? 'Required' : null,
            ),
            const SizedBox(height: 16),
            SegmentedButton<bool>(
              segments: const [
                ButtonSegment(value: true, label: Text('Pick from Catalog')),
                ButtonSegment(value: false, label: Text('Custom')),
              ],
              selected: {_useCatalog},
              onSelectionChanged: (s) {
                setState(() {
                  _useCatalog = s.first;
                  if (!_useCatalog) {
                    _selectedRef = null;
                    _referenceFirearmId = null;
                  }
                });
              },
            ),
            const SizedBox(height: 16),
            if (_useCatalog) ..._catalogFields() else ..._customFields(),
            const SizedBox(height: 12),
            ComponentField(
              kind: 'cartridge',
              label: 'Caliber',
              controller: _caliber,
            ),
            const SizedBox(height: 12),
            TextFormField(
              controller: _barrelLength,
              decoration: const InputDecoration(
                labelText: 'Barrel Length (in)',
                suffixText: 'in',
              ),
              keyboardType:
                  const TextInputType.numberWithOptions(decimal: true),
            ),
            const SizedBox(height: 12),
            TextFormField(
              controller: _twistRate,
              decoration: const InputDecoration(
                labelText: 'Twist Rate',
                hintText: 'e.g. 1:8',
              ),
            ),
            const SizedBox(height: 16),
            _shotsFiredField(context),
            const SizedBox(height: 12),
            TextFormField(
              controller: _notes,
              decoration: const InputDecoration(labelText: 'Notes'),
              maxLines: 4,
            ),
            const SizedBox(height: 24),
            FilledButton(
              onPressed: _busy ? null : _save,
              child: Text(isEdit ? 'Save Changes' : 'Create Firearm'),
            ),
            const SizedBox(height: 24),
          ],
        ),
      ),
    );
  }

  List<Widget> _catalogFields() {
    return [
      FutureBuilder<List<_RefEntry>>(
        future: _refsFuture,
        builder: (context, snap) {
          if (snap.connectionState == ConnectionState.waiting) {
            return const Padding(
              padding: EdgeInsets.symmetric(vertical: 8),
              child: LinearProgressIndicator(),
            );
          }
          final refs = snap.data ?? const <_RefEntry>[];
          if (refs.isEmpty) {
            return const Text(
              'No reference firearms in the catalog. Switch to Custom.',
            );
          }
          // Initialise selected ref from existing referenceFirearmId.
          if (_selectedRef == null && _referenceFirearmId != null) {
            for (final r in refs) {
              if (r.firearm.id == _referenceFirearmId) {
                _selectedRef = r;
                break;
              }
            }
          }
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              DropdownButtonFormField<_RefEntry>(
                initialValue: _selectedRef,
                isExpanded: true,
                decoration:
                    const InputDecoration(labelText: 'Model from Catalog'),
                items: [
                  for (final r in refs)
                    DropdownMenuItem(
                      value: r,
                      child: Text(
                        '${r.manufacturer.name} ${r.firearm.model}',
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                ],
                onChanged: (r) {
                  if (r != null) _applyReferenceSelection(r);
                },
                validator: (v) => v == null ? 'Pick a model' : null,
              ),
              const SizedBox(height: 12),
              if (_selectedRef != null) ...[
                _readOnlyTile('Manufacturer', _selectedRef!.manufacturer.name),
                _readOnlyTile('Model', _selectedRef!.firearm.model),
                _readOnlyTile('Type', _selectedRef!.firearm.type),
                if ((_selectedRef!.firearm.action ?? '').isNotEmpty)
                  _readOnlyTile('Action', _selectedRef!.firearm.action!),
                const SizedBox(height: 8),
                if (_selectedRef!.calibers.isNotEmpty)
                  DropdownButtonFormField<String>(
                    initialValue: _selectedRef!.calibers
                            .contains(_caliber.text)
                        ? _caliber.text
                        : null,
                    isExpanded: true,
                    decoration: const InputDecoration(
                      labelText: 'Caliber for This Firearm',
                    ),
                    items: [
                      for (final c in _selectedRef!.calibers)
                        DropdownMenuItem(value: c, child: Text(c)),
                    ],
                    onChanged: (v) {
                      if (v != null) {
                        setState(() => _caliber.text = v);
                      }
                    },
                  ),
              ],
            ],
          );
        },
      ),
    ];
  }

  List<Widget> _customFields() {
    return [
      TextFormField(
        controller: _manufacturer,
        decoration: const InputDecoration(labelText: 'Manufacturer'),
      ),
      const SizedBox(height: 12),
      TextFormField(
        controller: _model,
        decoration: const InputDecoration(labelText: 'Model'),
      ),
      const SizedBox(height: 12),
      TextFormField(
        controller: _type,
        decoration: const InputDecoration(
          labelText: 'Type',
          hintText: 'pistol / rifle / shotgun',
        ),
      ),
      const SizedBox(height: 12),
      TextFormField(
        controller: _action,
        decoration: const InputDecoration(
          labelText: 'Action',
          hintText: 'e.g. bolt-action, semi-auto',
        ),
      ),
    ];
  }

  Widget _readOnlyTile(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          SizedBox(
            width: 110,
            child: Text(
              label,
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
          Expanded(child: Text(value)),
        ],
      ),
    );
  }

  Widget _shotsFiredField(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Expanded(
          child: TextFormField(
            controller: _shotsFired,
            decoration: const InputDecoration(labelText: 'Shots Fired'),
            keyboardType: TextInputType.number,
            inputFormatters: [FilteringTextInputFormatter.digitsOnly],
            validator: (v) {
              if (v == null || v.trim().isEmpty) return null;
              final n = int.tryParse(v.trim());
              if (n == null || n < 0) return 'Must be a positive integer';
              return null;
            },
            onChanged: (_) => setState(() {}),
          ),
        ),
        const SizedBox(width: 8),
        IconButton.filledTonal(
          onPressed: () => _bumpShots(-1),
          icon: const Icon(Icons.remove),
          tooltip: 'Decrement',
        ),
        const SizedBox(width: 4),
        IconButton.filledTonal(
          onPressed: () => _bumpShots(1),
          icon: const Icon(Icons.add),
          tooltip: 'Increment',
        ),
      ],
    );
  }
}
