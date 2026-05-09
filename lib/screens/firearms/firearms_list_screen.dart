// FILE: lib/screens/firearms/firearms_list_screen.dart
//
// ============================================================================
// WHAT THIS FILE DOES
// ============================================================================
// The Firearms tab — tab 1 of `HomeScreen`'s bottom nav. Renders the
// user's firearm collection as a `StreamBuilder<List<UserFirearmRow>>`
// reading from `FirearmRepository.watchAll()`, so adds, edits, and
// deletes from anywhere in the app reflect live in this list.
//
// Each row is a swipe-to-delete `Dismissible` `ListTile`. Title is the
// user-supplied name (e.g. "Bergara B-14 HMR"); subtitle is a
// dot-separated string composed from model and caliber where present.
// The trailing area shows a [FavoriteStarButton] (toggling the per-row
// `isFavorite` boolean via `FirearmRepository.toggleFavorite`), a
// compact "<n> shots" counter (round count fired, sourced from
// `UserFirearmRow.shotsFired`), and the chevron. Favorited firearms
// surface at the top of the list (alphabetical within the favorites
// bucket); non-favorites keep their existing natural-sort order.
// Tapping a tile pushes `FirearmFormScreen(existing: f)`; the FAB
// pushes a blank `FirearmFormScreen()`.
//
// ============================================================================
// WHY IT EXISTS IN THE ARCHITECTURE
// ============================================================================
// Firearms are the second-most-central data type in the app — recipes
// are loaded for specific guns, so the round-count tracking and the
// barrel/twist data this list summarises are core. The bottom-nav slot
// at index 1 ensures it's one tap from anywhere.
//
// ============================================================================
// WHY THIS IS HARDER THAN IT LOOKS
// ============================================================================
// The pattern here is intentionally a near-mirror of
// `RecipesListScreen` — same StreamBuilder, same Dismissible-with-confirm
// flow, same FAB-pushes-form structure — so once you understand one CRUD
// list screen you understand the rest. The only meaningful divergence is
// the trailing shots-fired chip, which is read-only here; round-count
// adjustment lives on the form screen and on the per-firearm detail
// flow elsewhere.
//
// `ValueKey('firearm_${f.id}')` on the `Dismissible` is load-bearing —
// without it, dismissing one tile while the underlying stream emits a
// reordered list could vanish the wrong row.
//
// ============================================================================
// WHO CONSUMES THIS FILE
// ============================================================================
// - `lib/screens/home/home_screen.dart` — slotted at index 1 of
//   `_pages` and rendered inside the `IndexedStack`.
//
// ============================================================================
// SIDE EFFECTS
// ============================================================================
// - Subscribes to `FirearmRepository.watchAll()` for the lifetime of
//   the StreamBuilder.
// - Calls `FirearmRepository.delete(f.id)` on confirmed swipe.
// - Pushes `FirearmFormScreen` for both create and edit flows.

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../database/database.dart';
import '../../repositories/firearm_repository.dart';
import '../../utils/natural_sort.dart';
import '../../utils/responsive.dart';
import '../../widgets/empty_state_card.dart';
import '../../widgets/favorite_star_button.dart';
import 'firearm_form_screen.dart';

class FirearmsListScreen extends StatefulWidget {
  const FirearmsListScreen({super.key});

  @override
  State<FirearmsListScreen> createState() => _FirearmsListScreenState();
}

class _FirearmsListScreenState extends State<FirearmsListScreen> {
  // Right-pane selection on wide layouts. Null means show the empty
  // placeholder. Phone layouts ignore this — taps push a route.
  int? _selectedFirearmId;

  @override
  Widget build(BuildContext context) {
    final repo = context.read<FirearmRepository>();
    final isWide = Breakpoints.isWide(context);

    final list = _FirearmsList(
      selectedFirearmId: isWide ? _selectedFirearmId : null,
      onTap: (f) {
        if (isWide) {
          setState(() => _selectedFirearmId = f.id);
        } else {
          Navigator.of(context).push(
            MaterialPageRoute(
              builder: (_) => FirearmFormScreen(existing: f),
            ),
          );
        }
      },
      onDelete: (id) async {
        await repo.delete(id);
        if (mounted && _selectedFirearmId == id) {
          setState(() => _selectedFirearmId = null);
        }
      },
    );

    final fab = FloatingActionButton(
      heroTag: 'firearms_fab',
      onPressed: () => Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => const FirearmFormScreen()),
      ),
      child: const Icon(Icons.add),
    );

    if (!isWide) {
      return Scaffold(body: list, floatingActionButton: fab);
    }

    return Scaffold(
      body: Row(
        children: [
          SizedBox(width: 360, child: list),
          const VerticalDivider(width: 1, thickness: 1),
          Expanded(
            child: _selectedFirearmId == null
                ? const _EmptyDetailPane(
                    message:
                        'Select a firearm to view or edit it, or tap + to add one.',
                  )
                : _FirearmDetailPane(
                    key: ValueKey('firearm_detail_${_selectedFirearmId!}'),
                    firearmId: _selectedFirearmId!,
                  ),
          ),
        ],
      ),
      floatingActionButton: fab,
    );
  }
}

class _FirearmsList extends StatelessWidget {
  const _FirearmsList({
    required this.onTap,
    required this.onDelete,
    this.selectedFirearmId,
  });

  final ValueChanged<UserFirearmRow> onTap;
  final ValueChanged<int> onDelete;
  final int? selectedFirearmId;

  @override
  Widget build(BuildContext context) {
    final repo = context.read<FirearmRepository>();
    final theme = Theme.of(context);
    return StreamBuilder<List<UserFirearmRow>>(
      stream: repo.watchAll(),
      builder: (context, snap) {
        if (snap.connectionState == ConnectionState.waiting) {
          return const Center(child: CircularProgressIndicator());
        }
        final raw = snap.data ?? const <UserFirearmRow>[];
        if (raw.isEmpty) {
          // First-launch nudge. Disappears once the user has saved a
          // firearm. The inline button mirrors the FAB so a beginner
          // who hasn't noticed the floating + can still get unstuck
          // in one tap.
          return SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 96),
            child: EmptyStateCard(
              heading: 'Add your first firearm',
              body:
                  'Track barrel length, twist rate, action, and shots '
                  'fired so your loads can reference the gun they '
                  'were tuned for.',
              actions: [
                FilledButton.icon(
                  onPressed: () => Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) => const FirearmFormScreen(),
                    ),
                  ),
                  icon: const Icon(Icons.add),
                  label: const Text('Add firearm'),
                ),
              ],
            ),
          );
        }
        // Favorites-first sort. The underlying stream is already
        // natural-sorted by name (see `FirearmRepository.watchAll`);
        // we stable-partition so favorites surface at the top while
        // preserving alphabetical order within both buckets.
        final favorites = <UserFirearmRow>[];
        final others = <UserFirearmRow>[];
        for (final f in raw) {
          if (f.isFavorite) {
            favorites.add(f);
          } else {
            others.add(f);
          }
        }
        favorites.sort((a, b) => naturalCompare(a.name, b.name));
        final firearms = [...favorites, ...others];
        return ListView.separated(
          itemCount: firearms.length,
          separatorBuilder: (_, _) => const Divider(height: 1),
          itemBuilder: (context, i) {
            final f = firearms[i];
            final subtitle = [
              if (f.model != null) f.model,
              if (f.caliber != null) f.caliber,
            ].whereType<String>().join(' · ');
            final selected = selectedFirearmId == f.id;
            return Dismissible(
              key: ValueKey('firearm_${f.id}'),
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
                        title: const Text('Delete This Firearm?'),
                        content: Text('"${f.name}" will be removed.'),
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
              onDismissed: (_) => onDelete(f.id),
              child: ListTile(
                title: Text(f.name),
                subtitle: subtitle.isEmpty ? null : Text(subtitle),
                // Trailing slot is dense — favorite star + shots-fired
                // chip + chevron. Compact density on the star keeps
                // the row tight enough that a long firearm name still
                // gets enough horizontal space.
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    FavoriteStarButton(
                      isFavorite: f.isFavorite,
                      compact: true,
                      onToggle: () => repo.toggleFavorite(f.id),
                    ),
                    Text(
                      '${f.shotsFired} shots',
                      style: theme.textTheme.bodySmall,
                    ),
                    const SizedBox(width: 8),
                    const Icon(Icons.chevron_right),
                  ],
                ),
                selected: selected,
                selectedTileColor:
                    theme.colorScheme.primary.withValues(alpha: 0.12),
                onTap: () => onTap(f),
              ),
            );
          },
        );
      },
    );
  }
}

class _FirearmDetailPane extends StatelessWidget {
  const _FirearmDetailPane({super.key, required this.firearmId});

  final int firearmId;

  @override
  Widget build(BuildContext context) {
    final repo = context.read<FirearmRepository>();
    return FutureBuilder<UserFirearmRow?>(
      future: repo.getById(firearmId),
      builder: (context, snap) {
        if (snap.connectionState != ConnectionState.done) {
          return const Center(child: CircularProgressIndicator());
        }
        final row = snap.data;
        if (row == null) {
          return const _EmptyDetailPane(
            message: 'Firearm not found. It may have been deleted.',
          );
        }
        return FirearmFormScreen(existing: row);
      },
    );
  }
}

class _EmptyDetailPane extends StatelessWidget {
  const _EmptyDetailPane({required this.message});

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
              Icons.handshake_outlined,
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
