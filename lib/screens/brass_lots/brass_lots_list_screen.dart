// FILE: lib/screens/brass_lots/brass_lots_list_screen.dart
//
// ============================================================================
// WHAT THIS FILE DOES
// ============================================================================
// Renders the top-level "Brass Lots" list screen. A brass lot is a tracked
// quantity of cases — a labeled batch of brass with a known caliber, count,
// firing history, anneal history, and prep-flag state. The screen subscribes
// to BrassLotRepository.watchAll() and renders one tile per row, with a
// subtitle that joins caliber, on-hand count, firing count, and last-annealed
// date with a middle dot.
//
// A soft-warning "Anneal Soon" hint pill is shown on tiles whose firingCount
// has reached the threshold (5+ firings) AND whose lastAnnealed is null. This
// is intentionally a hint, not a block — users who anneal aggressively can
// ignore it; users who never anneal can permanently dismiss it by setting a
// last-annealed date. Dismiss-to-delete uses a confirmation dialog before
// actually deleting via BrassLotRepository.delete.
//
// ============================================================================
// WHY IT EXISTS IN THE ARCHITECTURE
// ============================================================================
// Brass life is a real metric for serious reloaders — you anneal every 3-5
// firings, you track when cases are about to need trimming, you know which
// lot a particular batch came from. Without dedicated brass-lot tracking,
// reloaders are stuck putting "Lapua lot #4" in a recipe note field and
// losing that data the moment they edit the recipe.
//
// ============================================================================
// WHY THIS IS HARDER THAN IT LOOKS
// ============================================================================
// The "Anneal Soon" threshold is a judgment call — six firings is a common
// rule of thumb on premium 6mm/6.5mm brass but is wrong for everything else.
// We picked 5 as the trigger and made it advisory only so the app never
// blocks the user. Subtitle assembly has to skip null fields gracefully so
// "never annealed" lots don't show "Annealed null".
//
// ============================================================================
// WHO CONSUMES THIS FILE
// ============================================================================
// - lib/screens/home/home_screen.dart (tab destination)
//
// ============================================================================
// SIDE EFFECTS
// ============================================================================
// Reads BrassLotRepository.watchAll() (live SQLite stream). Calls delete on
// dismiss. Pushes BrassLotFormScreen for new + edit.

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
