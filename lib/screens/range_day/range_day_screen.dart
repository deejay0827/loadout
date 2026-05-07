// FILE: lib/screens/range_day/range_day_screen.dart
//
// ============================================================================
// WHAT THIS FILE DOES
// ============================================================================
// The Range Day tab's list screen — a calm, low-clutter index of every
// `RangeDaySession` the user has created. Tapping a row opens
// `RangeDayDetailScreen` for that session; the AppBar has a single "+" action
// for spinning up a brand-new session.
//
// Range-day UX is deliberately mode-shift work. The user opens this screen
// at the range, often with gloves, sun glare, and one eye on the clock — so
// the design avoids ornamentation and pushes per-session detail into the
// detail screen rather than crowding rows here.
//
// ============================================================================
// WHO CONSUMES THIS FILE
// ============================================================================
// - lib/screens/home/home_screen.dart adds it as the fifth bottom-nav tab.

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../database/database.dart';
import '../../repositories/range_day_repository.dart';
import 'range_day_detail_screen.dart';

class RangeDayScreen extends StatelessWidget {
  const RangeDayScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final repo = context.read<RangeDayRepository>();
    return Scaffold(
      appBar: AppBar(
        title: const Text('Range Day'),
        actions: [
          IconButton(
            tooltip: 'New session',
            icon: const Icon(Icons.add),
            onPressed: () => _openDetail(context),
          ),
        ],
      ),
      body: StreamBuilder<List<RangeDaySessionRow>>(
        stream: repo.watchAll(),
        builder: (context, snap) {
          if (snap.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          }
          final rows = snap.data ?? const <RangeDaySessionRow>[];
          if (rows.isEmpty) {
            return _EmptyState(onCreate: () => _openDetail(context));
          }
          return ListView.separated(
            padding: const EdgeInsets.symmetric(vertical: 8),
            itemCount: rows.length,
            separatorBuilder: (_, _) => const Divider(height: 1),
            itemBuilder: (context, i) {
              final s = rows[i];
              return _SessionTile(
                session: s,
                onTap: () => _openDetail(context, sessionId: s.id),
                onDelete: () => _confirmDelete(context, s),
              );
            },
          );
        },
      ),
    );
  }

  Future<void> _openDetail(BuildContext context, {int? sessionId}) async {
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => RangeDayDetailScreen(sessionId: sessionId),
      ),
    );
  }

  Future<void> _confirmDelete(
    BuildContext context,
    RangeDaySessionRow session,
  ) async {
    final messenger = ScaffoldMessenger.of(context);
    final repo = context.read<RangeDayRepository>();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete session?'),
        content: Text(
          'This deletes "${session.name}" and every shot recorded against '
          'it. This cannot be undone.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await repo.deleteSession(session.id);
    messenger.showSnackBar(
      SnackBar(content: Text('"${session.name}" deleted.')),
    );
  }
}

/// One row in the sessions list. Compact two-line layout: session name on
/// the top line, date / distance / firearm summary on the bottom.
class _SessionTile extends StatelessWidget {
  const _SessionTile({
    required this.session,
    required this.onTap,
    required this.onDelete,
  });

  final RangeDaySessionRow session;
  final VoidCallback onTap;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final dateLabel = _formatDate(session.date);
    final distance = '${session.distanceYd.toStringAsFixed(0)} yd';
    final subtitle = '$dateLabel · $distance';
    return Dismissible(
      key: ValueKey(session.id),
      direction: DismissDirection.endToStart,
      background: Container(
        color: theme.colorScheme.errorContainer,
        alignment: Alignment.centerRight,
        padding: const EdgeInsets.only(right: 16),
        child: Icon(Icons.delete_outline,
            color: theme.colorScheme.onErrorContainer),
      ),
      confirmDismiss: (_) async {
        onDelete();
        return false;
      },
      child: ListTile(
        leading: Container(
          width: 40,
          height: 40,
          decoration: BoxDecoration(
            color: theme.colorScheme.primary.withValues(alpha: 0.12),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Icon(
            Icons.gps_fixed,
            color: theme.colorScheme.primary,
            size: 22,
          ),
        ),
        title: Text(
          session.name,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: theme.textTheme.titleMedium,
        ),
        subtitle: Text(
          subtitle,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        trailing: const Icon(Icons.chevron_right),
        onTap: onTap,
      ),
    );
  }

  String _formatDate(DateTime d) {
    const months = [
      'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
      'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
    ];
    return '${months[d.month - 1]} ${d.day}, ${d.year}';
  }
}

/// First-run state shown when the user has zero sessions. One CTA button.
class _EmptyState extends StatelessWidget {
  const _EmptyState({required this.onCreate});
  final VoidCallback onCreate;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.gps_fixed,
              size: 56,
              color: theme.colorScheme.primary.withValues(alpha: 0.6),
            ),
            const SizedBox(height: 16),
            Text(
              'No range sessions yet',
              style: theme.textTheme.titleMedium,
            ),
            const SizedBox(height: 8),
            Text(
              'Pick a target, dial in distance and conditions, and track '
              'where each shot lands. Sessions stay on your device.',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium,
            ),
            const SizedBox(height: 24),
            FilledButton.icon(
              onPressed: onCreate,
              icon: const Icon(Icons.add),
              label: const Text('Start a session'),
            ),
          ],
        ),
      ),
    );
  }
}
