import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../database/database.dart';
import '../../repositories/brass_lot_repository.dart';
import 'brass_lot_form_screen.dart';

/// Threshold (firings since last anneal) at which we show the soft
/// "anneal soon" hint chip on the list. Six firings is a common rule of
/// thumb on premium 6mm/6.5mm brass; users who anneal more aggressively
/// can ignore it.
const int _annealSoonAfterFirings = 5;

class BrassLotsListScreen extends StatelessWidget {
  const BrassLotsListScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final repo = context.read<BrassLotRepository>();
    return Scaffold(
      appBar: AppBar(title: const Text('Brass Lots')),
      body: StreamBuilder<List<BrassLotRow>>(
        stream: repo.watchAll(),
        builder: (context, snap) {
          if (snap.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          }
          final lots = snap.data ?? const <BrassLotRow>[];
          if (lots.isEmpty) {
            return const Center(
              child: Text('No brass lots yet. Tap + to add your first.'),
            );
          }
          return ListView.separated(
            itemCount: lots.length,
            separatorBuilder: (_, _) => const Divider(height: 1),
            itemBuilder: (context, i) {
              final l = lots[i];
              return _BrassLotTile(
                lot: l,
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => BrassLotFormScreen(existing: l),
                  ),
                ),
                onDismissed: () => repo.delete(l.id),
              );
            },
          );
        },
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: () => Navigator.of(context).push(
          MaterialPageRoute(builder: (_) => const BrassLotFormScreen()),
        ),
        child: const Icon(Icons.add),
      ),
    );
  }
}

class _BrassLotTile extends StatelessWidget {
  const _BrassLotTile({
    required this.lot,
    required this.onTap,
    required this.onDismissed,
  });

  final BrassLotRow lot;
  final VoidCallback onTap;
  final VoidCallback onDismissed;

  bool get _annealSoon =>
      lot.firingCount >= _annealSoonAfterFirings && lot.lastAnnealed == null;

  String _formatDate(DateTime d) {
    String two(int n) => n.toString().padLeft(2, '0');
    return '${d.year}-${two(d.month)}-${two(d.day)}';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final subtitle = [
      lot.caliber,
      '${lot.count} cases',
      'Fired ${lot.firingCount}x',
      if (lot.lastAnnealed != null)
        'Annealed ${_formatDate(lot.lastAnnealed!)}',
    ].join(' · ');

    return Dismissible(
      key: ValueKey('brass_lot_${lot.id}'),
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
                title: const Text('Delete This Brass Lot?'),
                content: Text('"${lot.name}" will be removed.'),
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
      onDismissed: (_) => onDismissed(),
      child: ListTile(
        title: Text(lot.name),
        subtitle: Text(subtitle),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (_annealSoon)
              Container(
                margin: const EdgeInsets.only(right: 8),
                padding:
                    const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: theme.colorScheme.primary.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(
                    color: theme.colorScheme.primary.withValues(alpha: 0.35),
                  ),
                ),
                child: Text(
                  'Anneal Soon',
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: theme.colorScheme.primary,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            const Icon(Icons.chevron_right),
          ],
        ),
        onTap: onTap,
      ),
    );
  }
}
