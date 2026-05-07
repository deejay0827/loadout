import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../database/database.dart';
import '../../repositories/load_development_repository.dart';
import '../../services/entitlement_notifier.dart';
import '../../widgets/pro_gate.dart';
import 'load_development_detail_screen.dart';
import 'new_load_development_screen.dart';

/// Top-level list of saved load-development sessions.
///
/// Pro-gated: free users see the upsell card from [ProGate]; Pro users see
/// the full list with FAB and dismiss-to-delete.
class LoadDevelopmentListScreen extends StatelessWidget {
  const LoadDevelopmentListScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final isPro = context.watch<EntitlementNotifier>().isPro;
    return Scaffold(
      appBar: AppBar(title: const Text('Load Development')),
      body: ProGate(
        feature: 'Load Development',
        child: const _LoadDevelopmentBody(),
      ),
      floatingActionButton: !isPro
          ? null
          : FloatingActionButton(
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => const NewLoadDevelopmentScreen(),
                ),
              ),
              child: const Icon(Icons.add),
            ),
    );
  }
}

class _LoadDevelopmentBody extends StatelessWidget {
  const _LoadDevelopmentBody();

  @override
  Widget build(BuildContext context) {
    final repo = context.read<LoadDevelopmentRepository>();
    return StreamBuilder<List<LoadDevelopmentSessionRow>>(
      stream: repo.watchAll(),
      builder: (context, snap) {
        if (snap.connectionState == ConnectionState.waiting) {
          return const Center(child: CircularProgressIndicator());
        }
        final sessions = snap.data ?? const <LoadDevelopmentSessionRow>[];
        if (sessions.isEmpty) {
          return const _EmptyState();
        }
        return ListView.separated(
          itemCount: sessions.length,
          separatorBuilder: (_, _) => const Divider(height: 1),
          itemBuilder: (context, i) {
            final s = sessions[i];
            return _SessionTile(
              session: s,
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) =>
                      LoadDevelopmentDetailScreen(sessionId: s.id),
                ),
              ),
              onDelete: () => repo.delete(s.id),
            );
          },
        );
      },
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.science_outlined,
              size: 56,
              color: theme.colorScheme.primary.withValues(alpha: 0.55),
            ),
            const SizedBox(height: 12),
            Text(
              'No development sessions yet',
              style: theme.textTheme.titleMedium,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 8),
            Text(
              'Start a charge-weight or seating-depth ladder to find the '
              'best node for your load.',
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

class _SessionTile extends StatelessWidget {
  const _SessionTile({
    required this.session,
    required this.onTap,
    required this.onDelete,
  });

  final LoadDevelopmentSessionRow session;
  final VoidCallback onTap;
  final VoidCallback onDelete;

  String _formatDate(DateTime d) {
    String two(int n) => n.toString().padLeft(2, '0');
    return '${d.year}-${two(d.month)}-${two(d.day)}';
  }

  bool get _isComplete => session.nodeValue != null;

  String get _typeLabel =>
      session.sessionType == 'seating_ladder' ? 'Seating' : 'Charge';

  String _subtitle() {
    final rungs =
        LoadDevelopmentRepository.decodeRungs(session.rungsJson);
    final rungCount = rungs.isEmpty ? session.rungCount : rungs.length;
    final fired = rungs.where((r) => r.fired || r.hasData).length;
    final unit = session.sessionType == 'seating_ladder' ? 'in' : 'gr';
    return [
      '$rungCount rungs',
      'fired $fired',
      _typeLabel,
      '${session.startValue}–${session.endValue} $unit',
    ].join(' · ');
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final pillColor = _isComplete
        ? theme.colorScheme.primary
        : theme.colorScheme.secondary;
    final pillLabel = _isComplete ? 'Complete' : 'In Progress';

    return Dismissible(
      key: ValueKey('load_dev_${session.id}'),
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
                title: const Text('Delete This Session?'),
                content:
                    Text('"${session.name}" and its data will be removed.'),
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
        title: Text(session.name),
        subtitle: Text(
          '${_subtitle()} · ${_formatDate(session.updatedAt)}',
        ),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              decoration: BoxDecoration(
                color: pillColor.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(
                  color: pillColor.withValues(alpha: 0.35),
                ),
              ),
              child: Text(
                pillLabel,
                style: theme.textTheme.labelSmall?.copyWith(
                  color: pillColor,
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
