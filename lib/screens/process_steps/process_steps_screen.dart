// FILE: lib/screens/process_steps/process_steps_screen.dart
//
// ============================================================================
// WHAT THIS FILE DOES
// ============================================================================
// User-managed catalog of reloading process steps. The 8 default stages were
// seeded on a database migration with isStandard = true (Inspect Brass /
// Resize / Trim / Chamfer & Deburr / Prime / Charge / Seat / Final
// Inspection). The screen is a ReorderableListView fed by
// ProcessStepRepository.watchAll(); long-press a row to drag it into a new
// position, and the new ordering is persisted via repo.reorder(next). The
// per-tile order on this screen drives the order of the process checklist
// rendered on BatchDetailScreen.
//
// Each tile shows a "Standard" pill on isStandard rows. Standard steps can
// be edited (rename, change description, toggle which caliber types they
// apply to) but cannot be deleted — the popup menu suppresses the Delete
// item for them. A dedicated "Add custom step" FAB launches the same
// edit dialog with no `existing` row, defaulting to applies-to-rifle.
//
// ============================================================================
// WHY IT EXISTS IN THE ARCHITECTURE
// ============================================================================
// Reloading workflows differ by caliber and by reloader. A pistol shooter
// might add "Taper Crimp"; a precision rifle shooter might add "Anneal" and
// "Mandrel Necks". The per-batch checklist on BatchDetailScreen needs a
// caliber-aware source of truth, and this screen is where the user curates
// that source of truth.
//
// ============================================================================
// WHY THIS IS HARDER THAN IT LOOKS
// ============================================================================
// Standard steps are partially-mutable: name, description, and
// applies-to-X flags are editable (so a user can rename "Resize" to
// "Resize / Decap" or hide "Anneal" from rifle), but the row itself can't
// be removed because every Batch.processStateJson references step names
// that may have been seeded long ago. ReorderableListView's onReorder
// callback uses the post-removal index convention (subtract 1 from
// newIndex when dragging downward), which is easy to get wrong.
//
// ============================================================================
// WHO CONSUMES THIS FILE
// ============================================================================
// - lib/screens/home/home_screen.dart (drawer destination)
// - lib/screens/batches/batch_detail_screen.dart (reads the same UserProcessSteps
//   table for its checklist; ordering changes here re-render there)
//
// ============================================================================
// SIDE EFFECTS
// ============================================================================
// Reads ProcessStepRepository.watchAll(). Calls reorder, insertCustom,
// update, delete on the same repository.

import 'package:drift/drift.dart' as drift;
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../database/database.dart';
import '../../repositories/process_step_repository.dart';

/// User-managed list of reloading process steps.
///
/// The eight default stages were seeded by the v4 migration with
/// `isStandard: true`. Standard steps are renamable and can have their
/// caliber-applicability toggled, but they cannot be deleted (only
/// hidden from a particular caliber type by clearing all three
/// `appliesTo*` flags).
///
/// Long-press a row to drag it into a new position. The on-screen order
/// drives the order of the per-batch checklist on [BatchDetailScreen].
class ProcessStepsScreen extends StatelessWidget {
  const ProcessStepsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final repo = context.read<ProcessStepRepository>();
    return Scaffold(
      appBar: AppBar(title: const Text('Reloading Steps')),
      body: StreamBuilder<List<UserProcessStepRow>>(
        stream: repo.watchAll(),
        builder: (context, snap) {
          if (snap.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          }
          final steps = snap.data ?? const <UserProcessStepRow>[];
          if (steps.isEmpty) {
            return const Center(
              child: Text('No steps yet. Tap + to add one.'),
            );
          }
          return ReorderableListView.builder(
            padding: const EdgeInsets.symmetric(vertical: 8),
            itemCount: steps.length,
            itemBuilder: (context, i) {
              final s = steps[i];
              return _StepTile(
                key: ValueKey('step_${s.id}'),
                step: s,
              );
            },
            onReorder: (oldIndex, newIndex) async {
              if (oldIndex < newIndex) newIndex -= 1;
              final next = List<UserProcessStepRow>.from(steps);
              final moved = next.removeAt(oldIndex);
              next.insert(newIndex, moved);
              await repo.reorder(next);
            },
          );
        },
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: () => _showEditDialog(context, repo, null),
        child: const Icon(Icons.add),
      ),
    );
  }
}

class _StepTile extends StatelessWidget {
  const _StepTile({super.key, required this.step});

  final UserProcessStepRow step;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final repo = context.read<ProcessStepRepository>();
    final appliesTo = <String>[
      if (step.appliesToPistol) 'Pistol',
      if (step.appliesToRifle) 'Rifle',
      if (step.appliesToShotgun) 'Shotgun',
    ].join(' · ');

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      child: Card(
        clipBehavior: Clip.antiAlias,
        child: ListTile(
          leading: const Padding(
            padding: EdgeInsets.symmetric(vertical: 4),
            child: Icon(Icons.drag_indicator),
          ),
          title: Row(
            children: [
              Expanded(
                child: Text(
                  step.name,
                  style: theme.textTheme.titleMedium,
                ),
              ),
              if (step.isStandard)
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 2,
                  ),
                  decoration: BoxDecoration(
                    color:
                        theme.colorScheme.primary.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(
                      color: theme.colorScheme.primary
                          .withValues(alpha: 0.35),
                    ),
                  ),
                  child: Text(
                    'Standard',
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: theme.colorScheme.primary,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
            ],
          ),
          subtitle: Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if ((step.description ?? '').isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 4),
                    child: Text(step.description!),
                  ),
                if (appliesTo.isNotEmpty)
                  Text(
                    appliesTo,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  )
                else
                  Text(
                    'Not applied to any caliber',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.error,
                      fontStyle: FontStyle.italic,
                    ),
                  ),
              ],
            ),
          ),
          trailing: PopupMenuButton<String>(
            onSelected: (action) async {
              if (action == 'edit') {
                if (!context.mounted) return;
                await _showEditDialog(context, repo, step);
              } else if (action == 'delete') {
                final confirmed = await showDialog<bool>(
                  context: context,
                  builder: (_) => AlertDialog(
                    title: const Text('Delete This Step?'),
                    content: Text('"${step.name}" will be removed.'),
                    actions: [
                      TextButton(
                        onPressed: () => Navigator.pop(context, false),
                        child: const Text('Cancel'),
                      ),
                      FilledButton.tonal(
                        onPressed: () => Navigator.pop(context, true),
                        child: const Text('Delete'),
                      ),
                    ],
                  ),
                );
                if (confirmed == true) {
                  await repo.delete(step.id);
                }
              }
            },
            itemBuilder: (ctx) => [
              const PopupMenuItem(value: 'edit', child: Text('Edit')),
              if (!step.isStandard)
                const PopupMenuItem(
                  value: 'delete',
                  child: Text('Delete'),
                ),
            ],
          ),
          onTap: () => _showEditDialog(context, repo, step),
        ),
      ),
    );
  }
}

/// Add-or-edit form. Standard steps reuse the same dialog — the
/// `isStandard` flag isn't editable, but everything else is.
Future<void> _showEditDialog(
  BuildContext context,
  ProcessStepRepository repo,
  UserProcessStepRow? existing,
) async {
  final nameCtrl = TextEditingController(text: existing?.name ?? '');
  final descCtrl =
      TextEditingController(text: existing?.description ?? '');
  bool pistol = existing?.appliesToPistol ?? false;
  bool rifle = existing?.appliesToRifle ?? true;
  bool shotgun = existing?.appliesToShotgun ?? false;

  final saved = await showDialog<bool>(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setLocal) => AlertDialog(
        title: Text(existing == null ? 'New Step' : 'Edit Step'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              TextField(
                controller: nameCtrl,
                decoration: const InputDecoration(labelText: 'Name *'),
                autofocus: existing == null,
              ),
              const SizedBox(height: 12),
              TextField(
                controller: descCtrl,
                decoration: const InputDecoration(labelText: 'Description'),
                maxLines: 3,
              ),
              const SizedBox(height: 8),
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Applies to Pistol'),
                value: pistol,
                onChanged: (v) => setLocal(() => pistol = v ?? false),
              ),
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Applies to Rifle'),
                value: rifle,
                onChanged: (v) => setLocal(() => rifle = v ?? false),
              ),
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Applies to Shotgun'),
                value: shotgun,
                onChanged: (v) => setLocal(() => shotgun = v ?? false),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () async {
              if (nameCtrl.text.trim().isEmpty) return;
              if (existing == null) {
                await repo.insertCustom(
                  name: nameCtrl.text.trim(),
                  description: descCtrl.text.trim().isEmpty
                      ? null
                      : descCtrl.text.trim(),
                  appliesToPistol: pistol,
                  appliesToRifle: rifle,
                  appliesToShotgun: shotgun,
                );
              } else {
                await repo.update(
                  existing.id,
                  UserProcessStepsCompanion(
                    name: drift.Value(nameCtrl.text.trim()),
                    description: drift.Value(
                      descCtrl.text.trim().isEmpty
                          ? null
                          : descCtrl.text.trim(),
                    ),
                    appliesToPistol: drift.Value(pistol),
                    appliesToRifle: drift.Value(rifle),
                    appliesToShotgun: drift.Value(shotgun),
                  ),
                );
              }
              if (ctx.mounted) Navigator.pop(ctx, true);
            },
            child: Text(existing == null ? 'Create' : 'Save'),
          ),
        ],
      ),
    ),
  );
  nameCtrl.dispose();
  descCtrl.dispose();
  if (saved != true) return;
}
