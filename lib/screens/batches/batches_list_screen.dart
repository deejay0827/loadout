import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../repositories/batch_repository.dart';
import 'batch_detail_screen.dart';
import 'batch_form_screen.dart';

class BatchesListScreen extends StatelessWidget {
  const BatchesListScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final repo = context.read<BatchRepository>();
    return Scaffold(
      appBar: AppBar(title: const Text('Batches')),
      body: StreamBuilder<List<BatchWithRefs>>(
        stream: repo.watchAll(),
        builder: (context, snap) {
          if (snap.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          }
          final rows = snap.data ?? const <BatchWithRefs>[];
          if (rows.isEmpty) {
            return const Center(
              child: Text('No batches yet. Tap + to start your first.'),
            );
          }
          return ListView.separated(
            itemCount: rows.length,
            separatorBuilder: (_, _) => const Divider(height: 1),
            itemBuilder: (context, i) => _BatchTile(
              row: rows[i],
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => BatchDetailScreen(batchId: rows[i].batch.id),
                ),
              ),
              onDelete: () => repo.delete(rows[i].batch.id),
            ),
          );
        },
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: () => Navigator.of(context).push(
          MaterialPageRoute(builder: (_) => const BatchFormScreen()),
        ),
        child: const Icon(Icons.add),
      ),
    );
  }
}

class _BatchTile extends StatelessWidget {
  const _BatchTile({
    required this.row,
    required this.onTap,
    required this.onDelete,
  });

  final BatchWithRefs row;
  final VoidCallback onTap;
  final VoidCallback onDelete;

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
