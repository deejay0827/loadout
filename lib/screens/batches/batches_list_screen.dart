// FILE: lib/screens/batches/batches_list_screen.dart
//
// ============================================================================
// WHAT THIS FILE DOES
// ============================================================================
// Renders the top-level "Batches" list screen. A batch represents a physical
// quantity of loaded ammunition produced from a recipe — for example "100
// rounds of 6.5 Creedmoor Hornady ELD-M 140gr loaded on 2026-04-12, fired 37".
// The screen is a streamed ListView fed by BatchRepository.watchAll(), which
// returns BatchWithRefs records that join Batches against UserLoads, BrassLots,
// and UserFirearms so the tile can show recipe name, brass-lot name, and a
// fire-progress count without doing any further lookups.
//
// Each tile renders a status pill computed from firedCount vs count: "Loaded"
// when nothing has been shot yet, "In Process" while shots remain, "Fired Out"
// once firedCount has caught up to count. Tapping a tile pushes the batch
// detail screen; the FAB pushes the batch form for creation; swipe-to-dismiss
// triggers a confirmation dialog and then deletes via BatchRepository.delete.
//
// ============================================================================
// WHY IT EXISTS IN THE ARCHITECTURE
// ============================================================================
// Recipes describe how to load ammunition; batches describe specific physical
// production runs of that ammunition. Without this list a reloader has no way
// to track "I loaded 50 rounds of recipe X last weekend, with brass lot Y, and
// I've fired 12 of them at the range so far." It is reachable from the home
// screen drawer / bottom-nav as the primary entry point into the batching
// subsystem.
//
// ============================================================================
// WHY THIS IS HARDER THAN IT LOOKS
// ============================================================================
// The status pill colors and labels have to be computed from raw counts (no
// stored status field) and stay in sync with reality if the user edits the
// batch from the detail screen. Using a Stream avoids a stale-data class of
// bugs. The Dismissible wrapper has to coordinate with a confirmation dialog
// before allowing the actual delete, otherwise an accidental swipe nukes a
// batch the user spent five minutes filling in.
//
// ============================================================================
// WHO CONSUMES THIS FILE
// ============================================================================
// - lib/screens/home/home_screen.dart (mounts it as a tab destination)
//
// ============================================================================
// SIDE EFFECTS
// ============================================================================
// Reads batches via BatchRepository.watchAll() (live SQLite stream). Calls
// BatchRepository.delete on dismiss. Pushes BatchDetailScreen / BatchFormScreen
// through the navigator.

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../repositories/batch_repository.dart';
import '../../utils/responsive.dart';
import '../../widgets/empty_state_card.dart';
import 'batch_detail_screen.dart';
import 'batch_form_screen.dart';

class BatchesListScreen extends StatefulWidget {
  const BatchesListScreen({super.key});

  @override
  State<BatchesListScreen> createState() => _BatchesListScreenState();
}

class _BatchesListScreenState extends State<BatchesListScreen> {
  // Right-pane selection on wide layouts. Detail content is read by id
  // because [BatchDetailScreen] already does its own data lookups.
  int? _selectedBatchId;

  @override
  Widget build(BuildContext context) {
    final repo = context.read<BatchRepository>();
    final isWide = Breakpoints.isWide(context);

    final list = StreamBuilder<List<BatchWithRefs>>(
      stream: repo.watchAll(),
      builder: (context, snap) {
        if (snap.connectionState == ConnectionState.waiting) {
          return const Center(child: CircularProgressIndicator());
        }
        final rows = snap.data ?? const <BatchWithRefs>[];
        if (rows.isEmpty) {
          // First-launch nudge. Disappears the moment the user opens
          // a batch. Inline button mirrors the FAB.
          return SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 96),
            child: EmptyStateCard(
              heading: 'Start your first batch',
              body:
                  'A batch is one production run — pick a recipe, '
                  'pick a brass lot, set how many rounds you\'re '
                  'loading, and step through the process.',
              actions: [
                FilledButton.icon(
                  onPressed: () => Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) => const BatchFormScreen(),
                    ),
                  ),
                  icon: const Icon(Icons.add),
                  label: const Text('Start batch'),
                ),
              ],
            ),
          );
        }
        return ListView.separated(
          itemCount: rows.length,
          separatorBuilder: (_, _) => const Divider(height: 1),
          itemBuilder: (context, i) => _BatchTile(
            row: rows[i],
            selected: isWide && _selectedBatchId == rows[i].batch.id,
            onTap: () {
              if (isWide) {
                setState(() => _selectedBatchId = rows[i].batch.id);
              } else {
                Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) =>
                        BatchDetailScreen(batchId: rows[i].batch.id),
                  ),
                );
              }
            },
            onDelete: () async {
              await repo.delete(rows[i].batch.id);
              if (mounted && _selectedBatchId == rows[i].batch.id) {
                setState(() => _selectedBatchId = null);
              }
            },
          ),
        );
      },
    );

    final fab = FloatingActionButton(
      heroTag: 'batches_fab',
      onPressed: () => Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => const BatchFormScreen()),
      ),
      child: const Icon(Icons.add),
    );

    if (!isWide) {
      return Scaffold(
        appBar: AppBar(title: const Text('Batches')),
        body: list,
        floatingActionButton: fab,
      );
    }

    return Scaffold(
      appBar: AppBar(title: const Text('Batches')),
      body: Row(
        children: [
          SizedBox(width: 360, child: list),
          const VerticalDivider(width: 1, thickness: 1),
          Expanded(
            child: _selectedBatchId == null
                ? const _BatchEmptyDetailPane(
                    message:
                        'Select a batch to view details, or tap + to start one.',
                  )
                : BatchDetailScreen(
                    key: ValueKey('batch_detail_${_selectedBatchId!}'),
                    batchId: _selectedBatchId!,
                  ),
          ),
        ],
      ),
      floatingActionButton: fab,
    );
  }
}

class _BatchEmptyDetailPane extends StatelessWidget {
  const _BatchEmptyDetailPane({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.layers_outlined,
              size: 56,
              color: theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.6),
            ),
            const SizedBox(height: 12),
            Text(
              message,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }
}

class _BatchTile extends StatelessWidget {
  const _BatchTile({
    required this.row,
    required this.onTap,
    required this.onDelete,
    this.selected = false,
  });

  final BatchWithRefs row;
  final VoidCallback onTap;
  final VoidCallback onDelete;
  final bool selected;

  /// Three-state UI label derived from `firedCount` vs `count`.
  ({String label, Color background, Color foreground}) _statusPill(
    BuildContext context,
  ) {
    final theme = Theme.of(context);
    final b = row.batch;
    if (b.firedCount <= 0) {
      return (
        label: 'Loaded',
        background: theme.colorScheme.primary.withValues(alpha: 0.12),
        foreground: theme.colorScheme.primary,
      );
    }
    if (b.firedCount >= b.count) {
      return (
        label: 'Fired Out',
        background:
            theme.colorScheme.surfaceContainerHigh.withValues(alpha: 0.6),
        foreground: theme.colorScheme.onSurfaceVariant,
      );
    }
    return (
      label: 'In Process',
      background: theme.colorScheme.secondary.withValues(alpha: 0.12),
      foreground: theme.colorScheme.secondary,
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final b = row.batch;
    final pill = _statusPill(context);
    final subtitle = [
      if (row.recipe != null) row.recipe!.name,
      if (row.brassLot != null) 'Lot: ${row.brassLot!.name}',
      '${b.firedCount} / ${b.count}',
    ].whereType<String>().join(' · ');

    return Dismissible(
      key: ValueKey('batch_${b.id}'),
      direction: DismissDirection.endToStart,
      background: Container(
        color: theme.colorScheme.errorContainer,
        alignment: Alignment.centerRight,
        padding: const EdgeInsets.only(right: 24),
        child: const Icon(Icons.delete),
      ),
      confirmDismiss: (_) async {
        return await showDialog<bool>(
              context: context,
              builder: (_) => AlertDialog(
                title: const Text('Delete This Batch?'),
                content: Text('"${b.name}" will be removed.'),
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
            ) ??
            false;
      },
      onDismissed: (_) => onDelete(),
      child: ListTile(
        title: Text(b.name),
        subtitle: subtitle.isEmpty ? null : Text(subtitle),
        selected: selected,
        selectedTileColor: theme.colorScheme.primary.withValues(alpha: 0.12),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              decoration: BoxDecoration(
                color: pill.background,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(
                  color: pill.foreground.withValues(alpha: 0.35),
                ),
              ),
              child: Text(
                pill.label,
                style: theme.textTheme.labelSmall?.copyWith(
                  color: pill.foreground,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            const SizedBox(width: 8),
            const Icon(Icons.chevron_right),
          ],
        ),
        onTap: onTap,
      ),
    );
  }
}
