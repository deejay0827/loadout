// FILE: lib/screens/range_day/range_day_screen.dart
//
// ============================================================================
// WHAT THIS FILE DOES
// ============================================================================
// The Range Day **History** screen — a calm, low-clutter index of every
// `RangeDaySession` the user has created, sorted newest-first. Tapping a row
// opens `RangeDayDetailScreen` for that session. Browse-only: there is no
// "+ new session" affordance here. New sessions are always started by
// tapping the "Range Day" tab in the bottom nav, which now opens a fresh
// `RangeDayDetailScreen` directly. This screen is reached only from the
// History `IconButton` in that detail screen's AppBar.
//
// Range-day UX is deliberately mode-shift work. The user opens this screen
// at the range, often with gloves, sun glare, and one eye on the clock — so
// the design avoids ornamentation and pushes per-session detail into the
// detail screen rather than crowding rows here.
//
// ============================================================================
// WHO CONSUMES THIS FILE
// ============================================================================
// - lib/screens/range_day/range_day_detail_screen.dart pushes it from the
//   AppBar's History action (`_openHistory`).

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../database/database.dart';
import '../../repositories/range_day_repository.dart';
import '../../widgets/range_day_safety.dart';
import 'range_day_detail_screen.dart';

class RangeDayScreen extends StatelessWidget {
  const RangeDayScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final repo = context.read<RangeDayRepository>();
    return Scaffold(
      appBar: AppBar(
        title: const Text('Range Day History'),
      ),
      body: RangeDayErrorBoundary(
        label: 'Range Day list',
        child: StreamBuilder<List<RangeDaySessionRow>>(
          stream: repo.watchAll(),
          builder: (context, snap) {
            if (snap.hasError) {
              // DB closed mid-tab-switch, schema mismatch, etc. Show a
              // friendly retry path instead of a blank screen.
              return _SessionsLoadError(
                message: 'Could not load Range Day sessions.',
                onRetry: () {
                  // Force a rebuild — the StreamBuilder re-subscribes
                  // on the next frame.
                  (context as Element).markNeedsBuild();
                },
              );
            }
            if (snap.connectionState == ConnectionState.waiting) {
              return const Center(child: CircularProgressIndicator());
            }
            final rows = snap.data ?? const <RangeDaySessionRow>[];
            if (rows.isEmpty) {
              return const _EmptyState();
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
      ),
    );
  }

  Future<void> _openDetail(BuildContext context, {int? sessionId}) async {
    await safeAsync<void>(
      context,
      userMessage: 'Could not open this session.',
      body: () async {
        await Navigator.of(context).push(
          MaterialPageRoute(
            builder: (_) => RangeDayDetailScreen(sessionId: sessionId),
          ),
        );
      },
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
    try {
      await repo.deleteSession(session.id);
      messenger.showSnackBar(
        SnackBar(content: Text('"${session.name}" deleted.')),
      );
    } catch (error, stack) {
      debugPrint('[range_day] deleteSession failed: $error');
      debugPrintStack(stackTrace: stack, label: 'deleteSession');
      // Inline (not asyncErrorSnackBar) to avoid reaching across the
      // dialog's async gap into the parent BuildContext.
      messenger.showSnackBar(
        SnackBar(
          behavior: SnackBarBehavior.floating,
          duration: const Duration(seconds: 4),
          content: Text(
            'Could not delete "${session.name}". Please try again.',
            maxLines: 3,
            overflow: TextOverflow.ellipsis,
          ),
          action: SnackBarAction(
            label: 'Dismiss',
            onPressed: () => messenger.hideCurrentSnackBar(),
          ),
        ),
      );
    }
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

/// Soft-failure state for the sessions stream. Mirrors `_EmptyState`'s
/// visual weight so the user isn't faced with a stack trace.
class _SessionsLoadError extends StatelessWidget {
  const _SessionsLoadError({required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

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
              Icons.error_outline,
              size: 56,
              color: theme.colorScheme.error,
            ),
            const SizedBox(height: 16),
            Text(message, style: theme.textTheme.titleMedium),
            const SizedBox(height: 8),
            Text(
              'Your sessions are saved on this device. Try reloading — '
              'this can happen briefly while the database catches up.',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium,
            ),
            const SizedBox(height: 24),
            FilledButton.icon(
              onPressed: onRetry,
              icon: const Icon(Icons.refresh),
              label: const Text('Reload'),
            ),
          ],
        ),
      ),
    );
  }
}

/// Empty state shown when the user has zero saved sessions. Browse-only —
/// History never spawns a new session; the user returns to the Range Day
/// tab in the bottom nav (or pops back to the in-progress detail screen
/// they opened History from) to do that.
class _EmptyState extends StatelessWidget {
  const _EmptyState();

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
              'Sessions you save will show up here. Open the Range Day '
              'tab to start a new session.',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium,
            ),
          ],
        ),
      ),
    );
  }
}
