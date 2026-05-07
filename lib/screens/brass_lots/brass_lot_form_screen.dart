// FILE: lib/screens/brass_lots/brass_lot_form_screen.dart
//
// ============================================================================
// WHAT THIS FILE DOES
// ============================================================================
// Add-or-edit form for a Brass Lot. Five sections vertically: Identification
// (name, manufacturer, caliber, headstamp/lot number), Quantity & Life
// (on-hand count, firing count, last-annealed date, anneal method), Measurements
// (avg weight in grains, case capacity in gr H2O, trim-to and last-trim
// length in inches, neck wall thickness in inches), Prep Flags (neck turned
// + neck-turn depth, primer pocket uniformed, flash hole deburred), and
// Notes. The caliber field is a ComponentField so the user can either pick
// a known cartridge or type a custom name; on save, a typed-in unknown
// caliber is persisted as a custom cartridge component so it shows up in
// future caliber dropdowns.
//
// On existing lots, a Quick Actions card is shown at the top of the form
// with three buttons: Fire Rounds (increments firingCount via a numeric
// dialog), Mark Annealed (sets lastAnnealed to today + writes anneal method),
// and Adjust Count (set the on-hand case count, e.g. after losing some
// cases at the range). Each Quick Action is a focused single-purpose dialog
// so the user doesn't have to scroll through the whole form to make a
// common in-the-moment update.
//
// ============================================================================
// WHY IT EXISTS IN THE ARCHITECTURE
// ============================================================================
// Reached from BrassLotsListScreen — both the FAB (new) and tap-to-open
// (edit). The Quick Actions card is the highest-traffic interaction in the
// brass-lot subsystem; a reloader at the bench wants Mark Annealed in one
// tap, not three.
//
// ============================================================================
// WHY THIS IS HARDER THAN IT LOOKS
// ============================================================================
// Caliber is free-form text but is also the join key into the cartridges
// catalog elsewhere — letting a user create a brass lot with caliber
// "6.5cm" instead of "6.5 Creedmoor" silently breaks downstream lookups.
// We work around that by ensuring the typed caliber gets registered as a
// custom cartridge when it isn't already known. Anneal method values are
// hyphenated lowercase ("salt-bath") to match schema convention while the
// dropdown labels are human-readable ("Salt Bath"). The Neck Turn Depth
// field only persists when neckTurned is true — saving 0.0015" depth on a
// not-turned lot would be misleading metadata.
//
// ============================================================================
// WHO CONSUMES THIS FILE
// ============================================================================
// - lib/screens/brass_lots/brass_lots_list_screen.dart (FAB + tile tap)
//
// ============================================================================
// SIDE EFFECTS
// ============================================================================
// Inserts/updates BrassLotRepository on save. ComponentRepository writes a
// custom cartridge when the caliber is not in the known set. Quick Actions
// call recordFiring, markAnnealed, setCount on BrassLotRepository.

import 'package:drift/drift.dart' as drift;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../database/database.dart';
import '../../repositories/brass_lot_repository.dart';
import '../../repositories/component_repository.dart';
import '../../widgets/component_field.dart';

/// Allowed values for the Anneal Method dropdown. Stored lowercased to
/// match the schema's `'amp' | 'salt-bath' | 'flame'` convention; the
/// "None" option is just a UI sentinel that maps back to null.
const List<({String value, String label})> _annealMethodOptions = [
  (value: 'amp', label: 'AMP'),
  (value: 'salt-bath', label: 'Salt Bath'),
  (value: 'flame', label: 'Flame'),
];

class BrassLotFormScreen extends StatefulWidget {
  const BrassLotFormScreen({super.key, this.existing});

  final BrassLotRow? existing;

  @override
  State<BrassLotFormScreen> createState() => _BrassLotFormScreenState();
}

class _BrassLotFormScreenState extends State<BrassLotFormScreen> {
  final _formKey = GlobalKey<FormState>();

  late final TextEditingController _name;
  late final TextEditingController _manufacturer;
  late final TextEditingController _caliber;
  late final TextEditingController _headstampLot;
  late final TextEditingController _count;
  late final TextEditingController _firingCount;
  late final TextEditingController _avgWeight;
  late final TextEditingController _caseCapacity;
  late final TextEditingController _trimToLength;
  late final TextEditingController _lastTrimLength;
  late final TextEditingController _neckWallThickness;
  late final TextEditingController _neckTurnDepth;
  late final TextEditingController _notes;

  String? _annealMethod;
  DateTime? _lastAnnealed;
  bool _neckTurned = false;
  bool _pocketUniformed = false;
  bool _flashHoleDeburred = false;

  bool _busy = false;

  @override
  void initState() {
    super.initState();
    final e = widget.existing;
    _name = TextEditingController(text: e?.name ?? '');
    _manufacturer = TextEditingController(text: e?.manufacturer ?? '');
    _caliber = TextEditingController(text: e?.caliber ?? '');
    _headstampLot = TextEditingController(text: e?.headstampLot ?? '');
    _count = TextEditingController(text: (e?.count ?? 0).toString());
    _firingCount =
        TextEditingController(text: (e?.firingCount ?? 0).toString());
    _avgWeight =
        TextEditingController(text: e?.avgWeightGr?.toString() ?? '');
    _caseCapacity =
        TextEditingController(text: e?.caseCapacityGrH2o?.toString() ?? '');
    _trimToLength =
        TextEditingController(text: e?.trimToLengthIn?.toString() ?? '');
    _lastTrimLength =
        TextEditingController(text: e?.lastTrimLengthIn?.toString() ?? '');
    _neckWallThickness = TextEditingController(
      text: e?.neckWallThicknessIn?.toString() ?? '',
    );
    _neckTurnDepth =
        TextEditingController(text: e?.neckTurnDepthIn?.toString() ?? '');
    _notes = TextEditingController(text: e?.notes ?? '');

    _annealMethod = e?.annealMethod;
    _lastAnnealed = e?.lastAnnealed;
    _neckTurned = e?.neckTurned ?? false;
    _pocketUniformed = e?.pocketUniformed ?? false;
    _flashHoleDeburred = e?.flashHoleDeburred ?? false;
  }

  @override
  void dispose() {
    for (final c in [
      _name,
      _manufacturer,
      _caliber,
      _headstampLot,
      _count,
      _firingCount,
      _avgWeight,
      _caseCapacity,
      _trimToLength,
      _lastTrimLength,
      _neckWallThickness,
      _neckTurnDepth,
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

  int _parseInt(TextEditingController c) {
    final v = int.tryParse(c.text.trim()) ?? 0;
    return v < 0 ? 0 : v;
  }

  String? _nullIfEmpty(TextEditingController c) {
    final t = c.text.trim();
    return t.isEmpty ? null : t;
  }

  String _formatDate(DateTime d) {
    String two(int n) => n.toString().padLeft(2, '0');
    return '${d.year}-${two(d.month)}-${two(d.day)}';
  }

  Future<void> _pickAnnealDate() async {
    final now = DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: _lastAnnealed ?? now,
      firstDate: DateTime(now.year - 30),
      lastDate: DateTime(now.year + 1),
    );
    if (picked != null) setState(() => _lastAnnealed = picked);
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() => _busy = true);

    final repo = context.read<BrassLotRepository>();
    final components = context.read<ComponentRepository>();
    final messenger = ScaffoldMessenger.of(context);
    final navigator = Navigator.of(context);

    // Make sure a typed-in caliber is persisted as a custom cartridge so
    // it shows up in future caliber dropdowns.
    final caliberText = _caliber.text.trim();
    if (caliberText.isNotEmpty) {
      final known = await components.componentLabels('cartridge');
      if (!known.contains(caliberText)) {
        await components.addCustomComponent('cartridge', caliberText);
      }
    }

    final entry = BrassLotsCompanion(
      name: drift.Value(_name.text.trim()),
      manufacturer: drift.Value(_nullIfEmpty(_manufacturer)),
      caliber: drift.Value(_caliber.text.trim()),
      headstampLot: drift.Value(_nullIfEmpty(_headstampLot)),
      count: drift.Value(_parseInt(_count)),
      firingCount: drift.Value(_parseInt(_firingCount)),
      lastAnnealed: drift.Value(_lastAnnealed),
      annealMethod: drift.Value(_annealMethod),
      avgWeightGr: drift.Value(_parseDouble(_avgWeight)),
      caseCapacityGrH2o: drift.Value(_parseDouble(_caseCapacity)),
      trimToLengthIn: drift.Value(_parseDouble(_trimToLength)),
      lastTrimLengthIn: drift.Value(_parseDouble(_lastTrimLength)),
      neckWallThicknessIn: drift.Value(_parseDouble(_neckWallThickness)),
      neckTurned: drift.Value(_neckTurned),
      neckTurnDepthIn:
          drift.Value(_neckTurned ? _parseDouble(_neckTurnDepth) : null),
      pocketUniformed: drift.Value(_pocketUniformed),
      flashHoleDeburred: drift.Value(_flashHoleDeburred),
      notes: drift.Value(_nullIfEmpty(_notes)),
    );

    if (widget.existing == null) {
      await repo.insert(entry);
      messenger.showSnackBar(
        const SnackBar(content: Text('Brass lot saved.')),
      );
    } else {
      await repo.update(widget.existing!.id, entry);
      messenger.showSnackBar(
        const SnackBar(content: Text('Brass lot updated.')),
      );
    }

    if (mounted) navigator.pop();
  }

  // ───── Detail-screen actions (only available on existing lots) ─────

  Future<void> _recordFiring() async {
    final repo = context.read<BrassLotRepository>();
    final messenger = ScaffoldMessenger.of(context);
    final controller = TextEditingController(text: '1');
    final result = await showDialog<int>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Record Firing'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text(
              'How many times has each case been fired? Increments the '
              'lot firing count.',
            ),
            const SizedBox(height: 12),
            TextField(
              controller: controller,
              keyboardType: TextInputType.number,
              inputFormatters: [FilteringTextInputFormatter.digitsOnly],
              decoration: const InputDecoration(labelText: 'Firings'),
              autofocus: true,
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () {
              final n = int.tryParse(controller.text.trim());
              Navigator.pop(ctx, (n ?? 0) > 0 ? n : 1);
            },
            child: const Text('Record'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (result == null || widget.existing == null) return;

    await repo.recordFiring(widget.existing!.id, result);
    final next =
        (_parseInt(_firingCount) + result).clamp(0, 1 << 31).toString();
    setState(() => _firingCount.text = next);
    messenger.showSnackBar(
      SnackBar(content: Text('Recorded $result firing(s).')),
    );
  }

  Future<void> _markAnnealed() async {
    final repo = context.read<BrassLotRepository>();
    final messenger = ScaffoldMessenger.of(context);
    String? picked = _annealMethod ?? 'amp';
    final result = await showDialog<({DateTime when, String? method})>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setLocal) => AlertDialog(
          title: const Text('Mark Annealed'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text('Sets the last-anneal date to today.'),
              const SizedBox(height: 12),
              DropdownButtonFormField<String>(
                initialValue: picked,
                isExpanded: true,
                decoration: const InputDecoration(labelText: 'Method'),
                items: [
                  for (final m in _annealMethodOptions)
                    DropdownMenuItem(value: m.value, child: Text(m.label)),
                ],
                onChanged: (v) => setLocal(() => picked = v),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(
                ctx,
                (when: DateTime.now(), method: picked),
              ),
              child: const Text('Mark Annealed'),
            ),
          ],
        ),
      ),
    );
    if (result == null || widget.existing == null) return;

    await repo.markAnnealed(widget.existing!.id, result.method);
    setState(() {
      _lastAnnealed = result.when;
      _annealMethod = result.method;
    });
    messenger.showSnackBar(
      const SnackBar(content: Text('Marked annealed.')),
    );
  }

  Future<void> _adjustCount() async {
    final repo = context.read<BrassLotRepository>();
    final controller = TextEditingController(text: _count.text);
    final result = await showDialog<int>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Adjust Count'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text(
              'Set the new on-hand case count for this lot. Use this when '
              'cases are lost, split, or replenished.',
            ),
            const SizedBox(height: 12),
            TextField(
              controller: controller,
              keyboardType: TextInputType.number,
              inputFormatters: [FilteringTextInputFormatter.digitsOnly],
              decoration: const InputDecoration(labelText: 'New Count'),
              autofocus: true,
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () {
              final n = int.tryParse(controller.text.trim());
              Navigator.pop(ctx, n ?? 0);
            },
            child: const Text('Save'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (result == null || widget.existing == null) return;

    await repo.setCount(widget.existing!.id, result);
    setState(() => _count.text = result.toString());
  }

  // ─────────────────────── UI ───────────────────────

  @override
  Widget build(BuildContext context) {
    final isEdit = widget.existing != null;
    return Scaffold(
      appBar: AppBar(title: Text(isEdit ? 'Edit Brass Lot' : 'New Brass Lot')),
      body: Form(
        key: _formKey,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            if (isEdit) _quickActions(),
            if (isEdit) const SizedBox(height: 12),
            _Section(
              title: 'Identification',
              children: [
                TextFormField(
                  controller: _name,
                  decoration: const InputDecoration(labelText: 'Name *'),
                  validator: (v) =>
                      (v == null || v.trim().isEmpty) ? 'Required' : null,
                ),
                const SizedBox(height: 12),
                TextFormField(
                  controller: _manufacturer,
                  decoration:
                      const InputDecoration(labelText: 'Manufacturer'),
                ),
                const SizedBox(height: 12),
                ComponentField(
                  kind: 'cartridge',
                  label: 'Caliber *',
                  controller: _caliber,
                  validator: (v) =>
                      (v == null || v.trim().isEmpty) ? 'Required' : null,
                ),
                const SizedBox(height: 12),
                TextFormField(
                  controller: _headstampLot,
                  decoration: const InputDecoration(
                    labelText: 'Headstamp / Lot #',
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            _Section(
              title: 'Quantity & Life',
              children: [
                TextFormField(
                  controller: _count,
                  decoration:
                      const InputDecoration(labelText: 'Count (current)'),
                  keyboardType: TextInputType.number,
                  inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                ),
                const SizedBox(height: 12),
                TextFormField(
                  controller: _firingCount,
                  decoration:
                      const InputDecoration(labelText: 'Firing Count'),
                  keyboardType: TextInputType.number,
                  inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                ),
                const SizedBox(height: 12),
                _annealDateField(),
                const SizedBox(height: 12),
                DropdownButtonFormField<String>(
                  initialValue: _annealMethod,
                  isExpanded: true,
                  decoration:
                      const InputDecoration(labelText: 'Anneal Method'),
                  items: [
                    const DropdownMenuItem<String>(
                      value: null,
                      child: Text('None'),
                    ),
                    for (final m in _annealMethodOptions)
                      DropdownMenuItem(value: m.value, child: Text(m.label)),
                  ],
                  onChanged: (v) => setState(() => _annealMethod = v),
                ),
              ],
            ),
            const SizedBox(height: 16),
            _Section(
              title: 'Measurements',
              children: [
                TextFormField(
                  controller: _avgWeight,
                  decoration: const InputDecoration(
                    labelText: 'Avg Brass Weight (gr)',
                    suffixText: 'gr',
                  ),
                  keyboardType:
                      const TextInputType.numberWithOptions(decimal: true),
                ),
                const SizedBox(height: 12),
                TextFormField(
                  controller: _caseCapacity,
                  decoration: const InputDecoration(
                    labelText: 'Case Capacity (gr H2O)',
                    suffixText: 'gr H2O',
                  ),
                  keyboardType:
                      const TextInputType.numberWithOptions(decimal: true),
                ),
                const SizedBox(height: 12),
                TextFormField(
                  controller: _trimToLength,
                  decoration: const InputDecoration(
                    labelText: 'Trim-To Length (in)',
                    suffixText: 'in',
                  ),
                  keyboardType:
                      const TextInputType.numberWithOptions(decimal: true),
                ),
                const SizedBox(height: 12),
                TextFormField(
                  controller: _lastTrimLength,
                  decoration: const InputDecoration(
                    labelText: 'Last Trim Length Measured (in)',
                    suffixText: 'in',
                  ),
                  keyboardType:
                      const TextInputType.numberWithOptions(decimal: true),
                ),
                const SizedBox(height: 12),
                TextFormField(
                  controller: _neckWallThickness,
                  decoration: const InputDecoration(
                    labelText: 'Neck Wall Thickness (in)',
                    suffixText: 'in',
                  ),
                  keyboardType:
                      const TextInputType.numberWithOptions(decimal: true),
                ),
              ],
            ),
            const SizedBox(height: 16),
            _Section(
              title: 'Prep Flags',
              children: [
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Neck Turned'),
                  value: _neckTurned,
                  onChanged: (v) => setState(() => _neckTurned = v),
                ),
                if (_neckTurned)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: TextFormField(
                      controller: _neckTurnDepth,
                      decoration: const InputDecoration(
                        labelText: 'Neck Turn Depth (in)',
                        suffixText: 'in',
                      ),
                      keyboardType: const TextInputType.numberWithOptions(
                        decimal: true,
                      ),
                    ),
                  ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Primer Pocket Uniformed'),
                  value: _pocketUniformed,
                  onChanged: (v) => setState(() => _pocketUniformed = v),
                ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Flash Hole Deburred'),
                  value: _flashHoleDeburred,
                  onChanged: (v) => setState(() => _flashHoleDeburred = v),
                ),
              ],
            ),
            const SizedBox(height: 16),
            _Section(
              title: 'Notes',
              children: [
                TextFormField(
                  controller: _notes,
                  decoration: const InputDecoration(labelText: 'Notes'),
                  maxLines: 4,
                ),
              ],
            ),
            const SizedBox(height: 24),
            FilledButton(
              onPressed: _busy ? null : _save,
              child: Text(isEdit ? 'Save Changes' : 'Create Brass Lot'),
            ),
            const SizedBox(height: 24),
          ],
        ),
      ),
    );
  }

  Widget _quickActions() {
    final theme = Theme.of(context);
    return Card(
      clipBehavior: Clip.antiAlias,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Text(
                'Quick Actions',
                style: theme.textTheme.labelLarge?.copyWith(
                  color: theme.colorScheme.primary,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: _recordFiring,
                    icon: const Icon(Icons.local_fire_department_outlined),
                    label: const Text('Fire Rounds'),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: _markAnnealed,
                    icon: const Icon(Icons.bolt_outlined),
                    label: const Text('Mark Annealed'),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            OutlinedButton.icon(
              onPressed: _adjustCount,
              icon: const Icon(Icons.exposure_outlined),
              label: const Text('Adjust Count'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _annealDateField() {
    return InputDecorator(
      decoration: const InputDecoration(labelText: 'Last Annealed Date'),
      child: Row(
        children: [
          Expanded(
            child: Text(
              _lastAnnealed == null
                  ? 'Never'
                  : _formatDate(_lastAnnealed!),
            ),
          ),
          if (_lastAnnealed != null)
            IconButton(
              tooltip: 'Clear',
              icon: const Icon(Icons.clear),
              onPressed: () => setState(() => _lastAnnealed = null),
            ),
          IconButton(
            tooltip: 'Pick date',
            icon: const Icon(Icons.calendar_today_outlined),
            onPressed: _pickAnnealDate,
          ),
        ],
      ),
    );
  }
}

/// Brass-tinted section header + bordered card. Mirrors the recipe form's
/// section pattern.
class _Section extends StatelessWidget {
  const _Section({required this.title, required this.children});

  final String title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      clipBehavior: Clip.antiAlias,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 12, 12, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Container(
              alignment: Alignment.centerLeft,
              margin: const EdgeInsets.only(bottom: 12),
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 6,
                ),
                decoration: BoxDecoration(
                  color: theme.colorScheme.primary.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(
                    color: theme.colorScheme.primary.withValues(alpha: 0.35),
                  ),
                ),
                child: Text(
                  title,
                  style: theme.textTheme.labelLarge?.copyWith(
                    color: theme.colorScheme.primary,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ),
            ...children,
          ],
        ),
      ),
    );
  }
}
