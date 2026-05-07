// FILE: lib/screens/batches/batch_detail_screen.dart
//
// ============================================================================
// WHAT THIS FILE DOES
// ============================================================================
// Per-batch dashboard with three vertical regions. The top is an
// Identification card showing recipe / caliber / brass-lot / firearm with an
// edit button that pushes BatchFormScreen. The middle is a large "Fired Y of
// X" counter with a primary "Fire Rounds" button. The bottom is the per-batch
// process checklist — a list of CheckboxListTile widgets driven by every
// UserProcessSteps row, with persistence into Batches.processStateJson.
//
// The Fire Rounds flow is the load-bearing interaction: it opens an integer
// prompt, clamps the entered value to remaining rounds, then calls
// BatchRepository.recordFiring AND BrassLotRepository.recordFiring (when the
// batch is linked to a brass lot) so the lot's firingCount stays accurate.
// This cascade is the whole reason the Brass Lot dropdown lives on the form.
//
// The checklist is driven by caliber-type filtering: the recipe's caliber is
// looked up against CartridgeRow.type, and only steps whose
// appliesToPistol/Rifle/Shotgun matches the cartridge type are shown. Steps
// not in the stored JSON default to false; steps in the stored JSON but
// missing from the live steps table are dropped silently.
//
// ============================================================================
// WHY IT EXISTS IN THE ARCHITECTURE
// ============================================================================
// Reached from BatchesListScreen on tap. This is where the user spends most
// of their batch-related time — checking off "trim brass / chamfer /
// deprime" while loading, then later "Fire 20 rounds" and watching the
// counter tick down. Without it the batch is a write-once record.
//
// ============================================================================
// WHY THIS IS HARDER THAN IT LOOKS
// ============================================================================
// The dual-write to Batches and BrassLots needs to capture provider refs
// before any await so the Flutter analyzer doesn't complain about
// post-async-gap context use. The checklist needs an in-state override
// (_checklistOverride) to keep the UI responsive while the JSON write to
// SQLite is in flight — without it the checkbox would visibly flicker.
// Caliber-type filtering must default to "rifle" when the recipe has no
// caliber or the caliber doesn't match a known cartridge — rifle is also
// the seeded default for the eight standard stages, so it's the safer
// fallback. The merge between stored state and live steps must be done
// every build so adding/removing steps in the catalog doesn't desync.
//
// ============================================================================
// WHO CONSUMES THIS FILE
// ============================================================================
// - lib/screens/batches/batches_list_screen.dart (tile-tap destination)
//
// ============================================================================
// SIDE EFFECTS
// ============================================================================
// Streams BatchRow from BatchRepository.watchById; loads recipe, brass lot,
// firearm, process steps, and cartridges via their repos. Writes
// processStateJson via BatchRepository.setProcessState. On Fire Rounds:
// BatchRepository.recordFiring + (optional) BrassLotRepository.recordFiring.

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../database/database.dart';
import '../../repositories/batch_repository.dart';
import '../../repositories/brass_lot_repository.dart';
import '../../repositories/component_repository.dart';
import '../../repositories/firearm_repository.dart';
import '../../repositories/process_step_repository.dart';
import '../../repositories/recipe_repository.dart';
import 'batch_form_screen.dart';

/// Per-batch dashboard.
///
/// * Top: identification card showing recipe / caliber / brass lot /
///   firearm. Tap edit to open the form.
/// * Middle: process checklist driven by [UserProcessSteps]. State is
///   persisted in `Batches.processStateJson`. Steps already saved in the
///   JSON keep their values; newly added steps default to false.
/// * Bottom: large "Fired Y of X" counter and a "Fire N rounds" action
///   that cascades the firing-count bump into the linked brass lot.
class BatchDetailScreen extends StatefulWidget {
  const BatchDetailScreen({super.key, required this.batchId});

  final int batchId;

  @override
  State<BatchDetailScreen> createState() => _BatchDetailScreenState();
}

class _BatchDetailScreenState extends State<BatchDetailScreen> {
  Map<String, bool>? _checklistOverride;

  Map<String, bool> _decodeChecklist(String raw) {
    if (raw.isEmpty) return <String, bool>{};
    try {
      final data = json.decode(raw);
      if (data is! Map) return <String, bool>{};
      return {
        for (final entry in data.entries)
          entry.key.toString(): entry.value == true,
      };
    } catch (_) {
      return <String, bool>{};
    }
  }

  Future<void> _persistChecklist(Map<String, bool> state) async {
    final repo = context.read<BatchRepository>();
    await repo.setProcessState(widget.batchId, json.encode(state));
  }

  String _calibreType(UserLoadRow? recipe, List<CartridgeRow> cartridges) {
    // The caliber on a recipe is a free-form label. Look it up by name
    // against the cartridges table to get the canonical type; fall back
    // to "rifle" when no match exists (rifle is also the seeded default
    // for the 8 standard stages, so this is the safer choice).
    final raw = recipe?.caliber?.trim();
    if (raw == null || raw.isEmpty) return 'rifle';
    for (final c in cartridges) {
      if (c.name == raw) return c.type;
    }
    return 'rifle';
  }

  Future<void> _fireRounds(BatchRow batch) async {
    final remaining = batch.count - batch.firedCount;
    if (remaining <= 0) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Batch already fired out.')),
      );
      return;
    }
    // Capture provider/messenger refs before any async gap so the
    // analyzer is happy and we don't risk a re-rendered context.
    final batches = context.read<BatchRepository>();
    final lots = context.read<BrassLotRepository>();
    final messenger = ScaffoldMessenger.of(context);
    final controller = TextEditingController(text: '1');
    final picked = await showDialog<int>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Fire Rounds'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('$remaining round(s) remaining in this batch.'),
            const SizedBox(height: 12),
            TextField(
              controller: controller,
              keyboardType: TextInputType.number,
              inputFormatters: [FilteringTextInputFormatter.digitsOnly],
              decoration: const InputDecoration(labelText: 'Rounds Fired'),
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
              final n = int.tryParse(controller.text.trim()) ?? 0;
              Navigator.pop(ctx, n);
            },
            child: const Text('Record'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (picked == null || picked <= 0) return;

    final delta = picked > remaining ? remaining : picked;

    await batches.recordFiring(widget.batchId, delta);
    if (batch.brassLotId != null) {
      await lots.recordFiring(batch.brassLotId!, delta);
    }
    messenger.showSnackBar(
      SnackBar(
        content: Text(
          'Fired $delta round(s).${batch.brassLotId != null ? " Brass lot updated." : ""}',
        ),
      ),
    );
  }

  Future<void> _resetChecklist(Map<String, bool> current) async {
    final reset = {for (final k in current.keys) k: false};
    setState(() => _checklistOverride = reset);
    await _persistChecklist(reset);
  }

  Future<void> _markAllComplete(Map<String, bool> current) async {
    final all = {for (final k in current.keys) k: true};
    setState(() => _checklistOverride = all);
    await _persistChecklist(all);
  }

  @override
  Widget build(BuildContext context) {
    final batchRepo = context.read<BatchRepository>();
    return Scaffold(
      appBar: AppBar(
        title: const Text('Batch'),
      ),
      body: StreamBuilder<BatchRow?>(
        stream: batchRepo.watchById(widget.batchId),
        builder: (context, snap) {
          if (snap.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          }
          final batch = snap.data;
          if (batch == null) {
            return const Center(child: Text('Batch not found.'));
          }
          return _BatchBody(
            batch: batch,
            checklistOverride: _checklistOverride,
            decodeChecklist: _decodeChecklist,
            calibreType: _calibreType,
            persistChecklist: _persistChecklist,
            onChecklistChanged: (next) {
              setState(() => _checklistOverride = next);
            },
            onFire: () => _fireRounds(batch),
            onReset: (state) => _resetChecklist(state),
            onMarkAll: (state) => _markAllComplete(state),
          );
        },
      ),
    );
  }
}

class _BatchBody extends StatelessWidget {
  const _BatchBody({
    required this.batch,
    required this.checklistOverride,
    required this.decodeChecklist,
    required this.calibreType,
    required this.persistChecklist,
    required this.onChecklistChanged,
    required this.onFire,
    required this.onReset,
    required this.onMarkAll,
  });

  final BatchRow batch;
  final Map<String, bool>? checklistOverride;
  final Map<String, bool> Function(String raw) decodeChecklist;
  final String Function(UserLoadRow? recipe, List<CartridgeRow> cartridges)
      calibreType;
  final Future<void> Function(Map<String, bool>) persistChecklist;
  final ValueChanged<Map<String, bool>> onChecklistChanged;
  final VoidCallback onFire;
  final ValueChanged<Map<String, bool>> onReset;
  final ValueChanged<Map<String, bool>> onMarkAll;

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<_BatchRefs>(
      future: _loadRefs(context),
      builder: (context, snap) {
        if (snap.connectionState == ConnectionState.waiting) {
          return const Center(child: CircularProgressIndicator());
        }
        final refs = snap.data!;
        final stored = decodeChecklist(batch.processStateJson);
        // Merge stored state with the live process steps. Steps not in
        // the stored map default to false; steps in the stored map but
        // missing from the steps table are dropped silently.
        final type = calibreType(refs.recipe, refs.cartridges);
        final relevantSteps = refs.steps.where((s) {
          switch (type) {
            case 'pistol':
              return s.appliesToPistol;
            case 'shotgun':
              return s.appliesToShotgun;
            case 'rifle':
            default:
              return s.appliesToRifle;
          }
        }).toList();
        final effective = {
          for (final s in relevantSteps) s.name: stored[s.name] ?? false,
        };
        // If the parent has already mutated state this frame, prefer it.
        final checklist = checklistOverride ?? effective;

        return ListView(
          padding: const EdgeInsets.all(16),
          children: [
            _identificationCard(context, refs),
            const SizedBox(height: 16),
            _counterCard(context),
            const SizedBox(height: 16),
            _checklistCard(context, relevantSteps, checklist),
            const SizedBox(height: 24),
          ],
        );
      },
    );
  }

  Widget _identificationCard(BuildContext context, _BatchRefs refs) {
    final theme = Theme.of(context);
    return Card(
      clipBehavior: Clip.antiAlias,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 12, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    batch.name,
                    style: theme.textTheme.titleLarge,
                  ),
                ),
                IconButton(
                  tooltip: 'Edit',
                  icon: const Icon(Icons.edit_outlined),
                  onPressed: () => Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) => BatchFormScreen(existing: batch),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            _detail(theme, 'Recipe', refs.recipe?.name ?? '—'),
            _detail(theme, 'Caliber', refs.recipe?.caliber ?? '—'),
            _detail(theme, 'Brass Lot', refs.brassLot?.name ?? '—'),
            _detail(theme, 'Firearm', refs.firearm?.name ?? '—'),
          ],
        ),
      ),
    );
  }

  Widget _detail(ThemeData theme, String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        children: [
          SizedBox(
            width: 100,
            child: Text(
              label,
              style: theme.textTheme.bodySmall,
            ),
          ),
          Expanded(child: Text(value)),
        ],
      ),
    );
  }

  Widget _counterCard(BuildContext context) {
    final theme = Theme.of(context);
    final remaining = batch.count - batch.firedCount;
    return Card(
      clipBehavior: Clip.antiAlias,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _SectionChip(title: 'Fired'),
            const SizedBox(height: 12),
            Center(
              child: Text(
                '${batch.firedCount} / ${batch.count}',
                style: theme.textTheme.displaySmall?.copyWith(
                  color: theme.colorScheme.primary,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            const SizedBox(height: 4),
            Center(
              child: Text(
                '$remaining round(s) remaining',
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ),
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: remaining > 0 ? onFire : null,
              icon: const Icon(Icons.local_fire_department_outlined),
              label: const Text('Fire Rounds'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _checklistCard(
    BuildContext context,
    List<UserProcessStepRow> steps,
    Map<String, bool> state,
  ) {
    return Card(
      clipBehavior: Clip.antiAlias,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 12, 12, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.only(left: 4, bottom: 8),
              child: _SectionChip(title: 'Process Checklist'),
            ),
            if (steps.isEmpty)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 16),
                child: Text(
                  'No process steps configured. Add some on the Reloading '
                  'Steps screen.',
                ),
              )
            else
              for (final s in steps)
                CheckboxListTile(
                  contentPadding: EdgeInsets.zero,
                  value: state[s.name] ?? false,
                  title: Text(s.name),
                  subtitle: (s.description ?? '').isEmpty
                      ? null
                      : Text(s.description!),
                  onChanged: (v) async {
                    final next = Map<String, bool>.from(state);
                    next[s.name] = v ?? false;
                    onChecklistChanged(next);
                    await persistChecklist(next);
                  },
                ),
            if (steps.isNotEmpty) ...[
              const SizedBox(height: 4),
              Row(
                children: [
                  Expanded(
                    child: TextButton.icon(
                      onPressed: () => onReset(state),
                      icon: const Icon(Icons.restart_alt),
                      label: const Text('Reset Checklist'),
                    ),
                  ),
                  Expanded(
                    child: TextButton.icon(
                      onPressed: () => onMarkAll(state),
                      icon: const Icon(Icons.check_circle_outline),
                      label: const Text('Mark All Complete'),
                    ),
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }

  Future<_BatchRefs> _loadRefs(BuildContext context) async {
    final recipes = context.read<RecipeRepository>();
    final lots = context.read<BrassLotRepository>();
    final firearms = context.read<FirearmRepository>();
    final steps = context.read<ProcessStepRepository>();
    final components = context.read<ComponentRepository>();

    final recipeRow = batch.recipeId == null
        ? null
        : await recipes.getById(batch.recipeId!);
    final lotRow = batch.brassLotId == null
        ? null
        : await lots.getById(batch.brassLotId!);
    final firearmRow = batch.firearmId == null
        ? null
        : await firearms.getById(batch.firearmId!);
    final stepsRows = await steps.getAll();
    final cartridges = await components.allCartridges();
    return (
      recipe: recipeRow,
      brassLot: lotRow,
      firearm: firearmRow,
      steps: stepsRows,
      cartridges: cartridges,
    );
  }
}

typedef _BatchRefs = ({
  UserLoadRow? recipe,
  BrassLotRow? brassLot,
  UserFirearmRow? firearm,
  List<UserProcessStepRow> steps,
  List<CartridgeRow> cartridges,
});

/// Brass-tinted chip used as a section header inside cards.
class _SectionChip extends StatelessWidget {
  const _SectionChip({required this.title});

  final String title;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Align(
      alignment: Alignment.centerLeft,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
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
    );
  }
}
