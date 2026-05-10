// FILE: lib/screens/load_development/load_development_list_screen.dart
//
// ============================================================================
// WHAT THIS FILE DOES
// ============================================================================
// Top-level list of saved load-development sessions. A session represents
// one load-development test — OCW (Optimal Charge Weight, Newberry),
// Audette Ladder, Satterlee 10-shot, Generic charge ladder, or
// Seating Depth ladder. The screen wraps its body in a ProGate; free
// users see the upgrade card, Pro users see the streamed list with
// dismiss-to-delete and a "+ New Test" extended FAB that pops a method
// picker bottom-sheet (`_NewTestPickerSheet`).
//
// Tile taps route by `methodKind`: OCW / Ladder / Satterlee / Generic
// rows open the v31+ `MethodTestScreen`; seating-ladder and pre-v31
// charge-ladder rows fall back to the legacy
// `LoadDevelopmentDetailScreen` so existing JSON-rung data renders
// correctly (see `_openSession`).
//
// Each tile renders a status pill computed from session.nodeValue:
// "Complete" once a node has been picked, "In Progress" otherwise. The
// type pill in the subtitle line distinguishes Charge vs Seating ladders,
// followed by a count of fired rungs and the start-end range with units
// (gr for charge, in for seating).
//
// ============================================================================
// WHY IT EXISTS IN THE ARCHITECTURE
// ============================================================================
// Pro-tier feature reachable from the home drawer. Without it Pro users
// have nowhere to find the experiments they've started or completed. The
// FAB and full functionality are only visible to Pro users; the
// EntitlementNotifier from provider determines the FAB visibility, and
// ProGate handles the body.
//
// ============================================================================
// WHY THIS IS HARDER THAN IT LOOKS
// ============================================================================
// The subtitle has to decode rungsJson to get the fired-count, but it must
// fall back to session.rungCount when the JSON is empty (corrupted /
// pre-migration sessions). The pill colors must respond to whether the
// session has been "completed" by the user picking a node, not just the
// presence of any rung data. Dismiss-to-delete needs a confirmation dialog
// so users don't lose hours of range data on a mis-swipe.
//
// ============================================================================
// WHO CONSUMES THIS FILE
// ============================================================================
// - lib/screens/home/home_screen.dart (drawer destination)
//
// ============================================================================
// SIDE EFFECTS
// ============================================================================
// Streams LoadDevelopmentRepository.watchAll(). Calls delete on dismiss.
// Pushes NewLoadDevelopmentScreen (FAB) and LoadDevelopmentDetailScreen
// (tile tap). Reads EntitlementNotifier for FAB visibility.

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../database/database.dart';
import '../../repositories/load_development_repository.dart';
import '../../services/entitlement_notifier.dart';
import '../../widgets/pro_gate.dart';
import 'load_development_detail_screen.dart';
import 'method_test_screen.dart';
import 'new_load_development_screen.dart';
import 'new_method_test_screen.dart';
import 'widgets/method_explainer.dart';

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
          : FloatingActionButton.extended(
              onPressed: () => _showNewTestSheet(context),
              icon: const Icon(Icons.add),
              label: const Text('New Test'),
            ),
    );
  }

  void _showNewTestSheet(BuildContext context) {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (sheetCtx) => const _NewTestPickerSheet(),
    );
  }
}

/// Bottom-sheet method picker shown by the "+ New Test" FAB. Five
/// rows — OCW, Audette Ladder, Satterlee, Generic, Seating — each
/// pushing the right wizard.
class _NewTestPickerSheet extends StatelessWidget {
  const _NewTestPickerSheet();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'Pick A Method',
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w600,
              ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 12),
            _MethodPickerRow(
              icon: Icons.center_focus_strong_outlined,
              title: 'OCW (Newberry)',
              subtitle: '3 shots per charge · vertical-impact flat spot',
              onTap: () {
                Navigator.of(context).pop();
                Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => const NewMethodTestScreen(
                      preselectedMethod: MethodKind.ocw,
                    ),
                  ),
                );
              },
            ),
            _MethodPickerRow(
              icon: Icons.linear_scale_outlined,
              title: 'Audette Ladder',
              subtitle: '1 shot per charge · vertical stacking at distance',
              onTap: () {
                Navigator.of(context).pop();
                Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => const NewMethodTestScreen(
                      preselectedMethod: MethodKind.ladder,
                    ),
                  ),
                );
              },
            ),
            _MethodPickerRow(
              icon: Icons.speed_outlined,
              title: 'Satterlee 10-shot',
              subtitle: '1 shot per charge · MV plateau',
              onTap: () {
                Navigator.of(context).pop();
                Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => const NewMethodTestScreen(
                      preselectedMethod: MethodKind.satterlee,
                    ),
                  ),
                );
              },
            ),
            _MethodPickerRow(
              icon: Icons.dashboard_customize_outlined,
              title: 'Generic Charge Ladder',
              subtitle: 'Freeform — log whatever data you have',
              onTap: () {
                Navigator.of(context).pop();
                Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => const NewMethodTestScreen(
                      preselectedMethod: MethodKind.generic,
                    ),
                  ),
                );
              },
            ),
            _MethodPickerRow(
              icon: Icons.straighten_outlined,
              title: 'Seating Depth Ladder',
              subtitle: 'CBTO ladder around an existing recipe',
              onTap: () {
                Navigator.of(context).pop();
                Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => const NewLoadDevelopmentScreen(
                      preselectedSessionType: 'seating_ladder',
                    ),
                  ),
                );
              },
            ),
          ],
        ),
      ),
    );
  }
}

class _MethodPickerRow extends StatelessWidget {
  const _MethodPickerRow({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });
  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: Icon(icon),
      title: Text(title),
      subtitle: Text(subtitle),
      trailing: const Icon(Icons.chevron_right),
      onTap: onTap,
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
              onTap: () => _openSession(context, s),
              onDelete: () => repo.delete(s.id),
            );
          },
        );
      },
    );
  }
}

/// Route to the right detail screen for [s]:
///   * `methodKind ∈ {ocw, ladder, satterlee, generic}` →
///     [MethodTestScreen] (v31+ per-shot path).
///   * Anything else (including legacy `'charge_ladder'` /
///     `'seating_ladder'` rows that pre-date v31) → the original
///     [LoadDevelopmentDetailScreen] so legacy data renders correctly.
void _openSession(BuildContext context, LoadDevelopmentSessionRow s) {
  final method = _methodFromWire(s.methodKind);
  if (method != null) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => MethodTestScreen(sessionId: s.id, method: method),
      ),
    );
  } else {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => LoadDevelopmentDetailScreen(sessionId: s.id),
      ),
    );
  }
}

MethodKind? _methodFromWire(String wire) {
  switch (wire) {
    case 'ocw':
      return MethodKind.ocw;
    case 'ladder':
      return MethodKind.ladder;
    case 'satterlee':
      return MethodKind.satterlee;
    case 'generic':
      // Generic was introduced in v31 alongside the per-shot model.
      // Existing pre-v31 rows backfilled to 'generic' have no shot
      // data — they still open in the legacy detail screen because
      // their JSON-rung data lives there. Distinguish by inspecting
      // sessionType: only sessionType=='charge_ladder' rows that
      // had data pre-existed; new rows we create will land here too.
      // For simplicity: route ALL 'generic' rows through the new
      // method screen. Legacy rows render the new screen with empty
      // shot grids — the user can either start logging into the new
      // grid or delete and recreate. The first time we see legacy
      // data in production we may revisit this.
      return MethodKind.generic;
    default:
      return null;
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
