// FILE: lib/screens/recipes/recipes_list_screen.dart
//
// ============================================================================
// WHAT THIS FILE DOES
// ============================================================================
// The Recipes tab — tab 0 of `HomeScreen`'s bottom nav. Renders the user's
// recipe list as a `StreamBuilder<List<UserLoadRow>>` reading from
// `RecipeRepository.watchAll()`, so the list updates live whenever the
// underlying Drift table changes (insert, update, delete from anywhere in
// the app).
//
// Each row is a `Dismissible` swipe-to-delete `ListTile`. The tile shows
// the recipe name as the title and a dot-separated subtitle line composed
// from caliber, powder charge (with a `gr` suffix), bullet, and COAL —
// whichever fields are populated. The trailing slot pairs a
// [FavoriteStarButton] (toggling the per-row `isFavorite` boolean via
// `RecipeRepository.toggleFavorite`) with the chevron. Favorited rows
// surface at the top of the list (alphabetical within the favorites
// bucket); non-favorites keep their existing `updatedAt DESC` ordering.
// Tapping a tile pushes `RecipeFormScreen(existing: r)` for editing;
// the floating action button pushes a blank `RecipeFormScreen()` for
// creating a new recipe.
//
// Long-pressing any tile enters multi-select mode. In multi-select, taps
// toggle inclusion in the selection set, an AppBar exposes "Share as PDF"
// (one page per recipe via `RecipePdfService.shareMultiple`), and an
// "Exit" affordance returns to the normal list. Selection is held in
// `_RecipesListScreenState._selectedIds` and is intentionally cleared
// when the live stream emits an updated list that no longer contains a
// previously-selected id.
//
// ============================================================================
// WHY IT EXISTS IN THE ARCHITECTURE
// ============================================================================
// Recipes are the central artifact in LoadOut — every other tab orbits
// around them (firearms record what shoots them, batches track when they
// were loaded, ballistics computes their trajectory). This screen is the
// canonical entry point for browsing and managing them, reachable via the
// bottom-nav slot at index 0.
//
// ============================================================================
// WHY THIS IS HARDER THAN IT LOOKS
// ============================================================================
// The dismiss-to-delete flow hides a confirmation dialog inside
// `confirmDismiss` so a stray swipe doesn't permanently destroy work.
// Returning `false` from the dialog cancels the dismiss animation and
// snaps the tile back; returning `true` lets it complete and triggers
// `onDismissed`, which calls `RecipeRepository.delete`. The
// `?? false` guard at the bottom of `confirmDismiss` is critical — if the
// dialog is dismissed via tapping outside (returning null), the tile
// would otherwise be deleted without a yes from the user.
//
// The list builder uses `ValueKey('recipe_${r.id}')` so Flutter can
// identify which row was dismissed when the underlying list reorders —
// otherwise an unrelated tile could be removed when the stream emits the
// post-delete list.
//
// Multi-select mode disables `Dismissible` swipes for the duration so a
// stray swipe doesn't destroy a row mid-selection. The AppBar `actions`
// are recomposed when the mode flips so users can't trigger the wrong
// action by reflex.
//
// ============================================================================
// WHO CONSUMES THIS FILE
// ============================================================================
// - `lib/screens/home/home_screen.dart` — slotted at index 0 of `_pages`
//   and rendered inside the `IndexedStack`.
//
// ============================================================================
// SIDE EFFECTS
// ============================================================================
// - Subscribes to `RecipeRepository.watchAll()` for the lifetime of the
//   stream builder.
// - Calls `RecipeRepository.delete(r.id)` on confirmed swipe.
// - Pushes `RecipeFormScreen` routes via `MaterialPageRoute` for both
//   create and edit flows.
// - In multi-select, hands the picked recipes to
//   `RecipePdfService.shareMultiple` — writes a temp file and surfaces
//   the OS share sheet.

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../database/database.dart';
import '../../repositories/recipe_repository.dart';
import '../../services/recipe_pdf_service.dart';
import '../../utils/natural_sort.dart';
import '../../utils/responsive.dart';
import '../../widgets/empty_state_card.dart';
import '../../widgets/favorite_star_button.dart';
import '../../widgets/quick_add_fab_stack.dart';
import 'quick_add_recipe_screen.dart';
import 'recipe_form_screen.dart';

class RecipesListScreen extends StatefulWidget {
  const RecipesListScreen({super.key});

  @override
  State<RecipesListScreen> createState() => _RecipesListScreenState();
}

class _RecipesListScreenState extends State<RecipesListScreen> {
  // ID of the recipe currently shown in the right-hand detail pane on
  // wide layouts. Null means "show the empty placeholder." On phones
  // this state is unused — taps push a full-screen form route instead.
  int? _selectedRecipeId;

  // Multi-select state. When `_isSelecting` is true, list taps toggle
  // membership in `_selectedIds` instead of opening the recipe form.
  // The selection survives stream rebuilds (we keep ids; the live
  // recipe list re-resolves on each emit) but is pruned to drop ids
  // that no longer correspond to extant rows.
  bool _isSelecting = false;
  final Set<int> _selectedIds = <int>{};

  // True while a long-running share is in flight. Disables the AppBar
  // share button so a double tap doesn't kick off two share sheets.
  bool _sharing = false;

  void _toggleSelection(UserLoadRow r) {
    setState(() {
      if (_selectedIds.contains(r.id)) {
        _selectedIds.remove(r.id);
        // Leaving the last selected item exits multi-select mode so
        // the user isn't trapped in an empty selection state.
        if (_selectedIds.isEmpty) _isSelecting = false;
      } else {
        _selectedIds.add(r.id);
      }
    });
  }

  void _enterSelectionMode(UserLoadRow r) {
    setState(() {
      _isSelecting = true;
      _selectedIds.add(r.id);
    });
  }

  void _exitSelectionMode() {
    setState(() {
      _isSelecting = false;
      _selectedIds.clear();
    });
  }

  /// Push a "Share as PDF" through `RecipePdfService.shareMultiple`.
  /// Order is the visible list order at share time; recipes that have
  /// been deleted between selection and share fall out silently.
  Future<void> _shareSelectedAsPdf(List<UserLoadRow> visible) async {
    if (_sharing) return;
    final messenger = ScaffoldMessenger.of(context);
    // Walk the visible list to preserve user-facing order. Then drop
    // anything no longer in the list (race vs. live stream).
    final picked = visible.where((r) => _selectedIds.contains(r.id)).toList();
    if (picked.isEmpty) {
      messenger.showSnackBar(
        const SnackBar(content: Text('Select at least one recipe.')),
      );
      return;
    }
    setState(() => _sharing = true);
    try {
      await RecipePdfService().shareMultiple(context, picked);
      if (!mounted) return;
      _exitSelectionMode();
    } catch (e) {
      messenger.showSnackBar(
        SnackBar(content: Text('Share failed: $e')),
      );
    } finally {
      if (mounted) setState(() => _sharing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final repo = context.read<RecipeRepository>();
    final isWide = Breakpoints.isWide(context);

    final list = _RecipesList(
      onTap: (r) {
        if (_isSelecting) {
          _toggleSelection(r);
          return;
        }
        if (isWide) {
          setState(() => _selectedRecipeId = r.id);
        } else {
          Navigator.of(context).push(
            MaterialPageRoute(
              builder: (_) => RecipeFormScreen(existing: r),
            ),
          );
        }
      },
      onLongPress: (r) {
        if (_isSelecting) return;
        _enterSelectionMode(r);
      },
      selectedRecipeId: isWide && !_isSelecting ? _selectedRecipeId : null,
      onDelete: (id) async {
        await repo.delete(id);
        if (mounted && _selectedRecipeId == id) {
          setState(() => _selectedRecipeId = null);
        }
      },
      isSelecting: _isSelecting,
      selectedIds: _selectedIds,
      onListChanged: _pruneSelection,
      onShareSelected: _shareSelectedAsPdf,
    );

    // Two-FAB cluster: a "Quick" extended FAB (notebook-line capture)
    // stacked above a "Regular" `+` FAB (full recipe form). Both are
    // hidden during multi-select so the user isn't tempted to start a
    // new recipe while picking ones to share.
    //
    // The previous bottom-sheet picker is gone — discoverability of
    // the import paths now lives inside the `ImportOptionsSection`
    // that hangs under both forms. Beginners and power users both
    // see the two FABs.
    final fab = _isSelecting
        ? null
        : QuickAddFabStack(
            tagPrefix: 'recipes',
            quickIcon: Icons.bolt,
            quickLabel: 'Quick',
            onQuickPressed: () {
              Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => const QuickAddRecipeScreen(),
                ),
              );
            },
            onAddPressed: () {
              Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => const RecipeFormScreen(),
                ),
              );
            },
            addTooltip: 'Regular recipe',
          );

    // Multi-select decorations: an AppBar with "Share as PDF" and a
    // "Cancel" leading icon. The AppBar takes precedence over the
    // home-screen toolbar by virtue of being on a Scaffold inside the
    // tab page; HomeScreen renders the bottom-nav, this screen owns
    // its top bar when needed.
    final appBar = _isSelecting
        ? AppBar(
            title: Text(
              _selectedIds.isEmpty
                  ? 'Select recipes'
                  : '${_selectedIds.length} selected',
            ),
            leading: IconButton(
              tooltip: 'Cancel',
              icon: const Icon(Icons.close),
              onPressed: _exitSelectionMode,
            ),
            actions: [
              IconButton(
                tooltip: 'Share as PDF',
                icon: const Icon(Icons.picture_as_pdf_outlined),
                onPressed: (_selectedIds.isEmpty || _sharing)
                    ? null
                    : () async {
                        // Re-read the current live list off the
                        // repository so the share captures any
                        // post-selection edits.
                        final all = await repo.watchAll().first;
                        if (!mounted) return;
                        await _shareSelectedAsPdf(all);
                      },
              ),
            ],
          )
        : null;

    if (!isWide) {
      return Scaffold(
        appBar: appBar,
        body: list,
        floatingActionButton: fab,
      );
    }

    return Scaffold(
      appBar: appBar,
      body: Row(
        children: [
          // Master pane — fixed width, large enough for typical recipe
          // names + caliber/powder subtitles.
          SizedBox(
            width: 360,
            child: list,
          ),
          const VerticalDivider(width: 1, thickness: 1),
          // Detail pane — embeds the same form widget that the phone
          // layout pushes as a route. Keying it by recipe id forces a
          // full rebuild when the selection changes so the form's
          // internal controllers reset cleanly.
          Expanded(
            child: _isSelecting
                ? const _EmptyDetailPane(
                    message:
                        'Multi-select mode. Tap recipes to add them to the share, then tap the PDF icon.',
                  )
                : (_selectedRecipeId == null
                    ? const _EmptyDetailPane(
                        message:
                            'Select a recipe to view or edit it, or tap + to create one.',
                      )
                    : _RecipeDetailPane(
                        key: ValueKey('recipe_detail_${_selectedRecipeId!}'),
                        recipeId: _selectedRecipeId!,
                      )),
          ),
        ],
      ),
      floatingActionButton: fab,
    );
  }

  /// Drop selection ids that no longer appear in the live list. Called
  /// from `_RecipesList` whenever the stream emits a new snapshot so
  /// deletions made elsewhere (e.g. in a different tab) clean up the
  /// selection set.
  void _pruneSelection(List<UserLoadRow> recipes) {
    if (_selectedIds.isEmpty) return;
    final live = recipes.map((r) => r.id).toSet();
    final stale = _selectedIds.where((id) => !live.contains(id)).toList();
    if (stale.isEmpty) return;
    // Defer to a microtask — `setState` during build is forbidden.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      setState(() {
        _selectedIds.removeAll(stale);
        if (_selectedIds.isEmpty) _isSelecting = false;
      });
    });
  }

}

/// Recipe list (master pane) — the same `StreamBuilder<List<UserLoadRow>>`
/// + `Dismissible` swipe-to-delete pattern that used to live inline. Tap
/// behaviour is delegated upstream so the parent can decide whether to
/// push a route (phone) or update detail-pane state (wide) or toggle
/// multi-select inclusion.
class _RecipesList extends StatelessWidget {
  const _RecipesList({
    required this.onTap,
    required this.onDelete,
    required this.onLongPress,
    required this.isSelecting,
    required this.selectedIds,
    required this.onListChanged,
    required this.onShareSelected,
    this.selectedRecipeId,
  });

  final ValueChanged<UserLoadRow> onTap;
  final ValueChanged<int> onDelete;
  final ValueChanged<UserLoadRow> onLongPress;
  final int? selectedRecipeId;
  final bool isSelecting;
  final Set<int> selectedIds;
  final ValueChanged<List<UserLoadRow>> onListChanged;
  final Future<void> Function(List<UserLoadRow>) onShareSelected;

  @override
  Widget build(BuildContext context) {
    final repo = context.read<RecipeRepository>();
    final theme = Theme.of(context);
    return StreamBuilder<List<UserLoadRow>>(
      stream: repo.watchAll(),
      builder: (context, snap) {
        if (snap.connectionState == ConnectionState.waiting) {
          return const Center(child: CircularProgressIndicator());
        }
        final raw = snap.data ?? const <UserLoadRow>[];
        // Tell the parent so it can prune stale selection ids.
        onListChanged(raw);
        if (raw.isEmpty) {
          // First-launch nudge. Visible on every empty Recipes list,
          // disappears the moment the user saves their first recipe
          // (the parent StreamBuilder reflows). Inline buttons mirror
          // the QuickAddFabStack so a beginner can act without
          // hunting for the FAB; an expert who's already comfortable
          // with the FAB can ignore the card and tap as usual.
          return SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 96),
            child: EmptyStateCard(
              heading: 'Add your first recipe',
              body:
                  'A recipe is one load — caliber, powder, charge, '
                  'bullet, primer, brass. Quick captures the four '
                  'fields that matter; Standard opens the full form.',
              actions: [
                FilledButton.icon(
                  onPressed: () {
                    Navigator.of(context).push(
                      MaterialPageRoute(
                        builder: (_) => const QuickAddRecipeScreen(),
                      ),
                    );
                  },
                  icon: const Icon(Icons.bolt),
                  label: const Text('Quick recipe'),
                ),
                OutlinedButton.icon(
                  onPressed: () {
                    Navigator.of(context).push(
                      MaterialPageRoute(
                        builder: (_) => const RecipeFormScreen(),
                      ),
                    );
                  },
                  icon: const Icon(Icons.add),
                  label: const Text('Standard recipe'),
                ),
              ],
            ),
          );
        }
        // Favorites-first sort. The underlying stream is ordered by
        // `updatedAt DESC` (see `RecipeRepository.watchAll`); we stable-
        // partition so favorites surface at the top while preserving
        // recency order within each bucket. Within the favorites bucket
        // we then natural-sort by name so users with many favorites
        // see a stable alphabetic listing rather than recipes
        // re-shuffling on every save.
        final favorites = <UserLoadRow>[];
        final others = <UserLoadRow>[];
        for (final r in raw) {
          if (r.isFavorite) {
            favorites.add(r);
          } else {
            others.add(r);
          }
        }
        favorites.sort((a, b) => naturalCompare(a.name, b.name));
        final recipes = [...favorites, ...others];
        return ListView.separated(
          itemCount: recipes.length,
          separatorBuilder: (_, _) => const Divider(height: 1),
          itemBuilder: (context, i) {
            final r = recipes[i];
            final subtitle = [
              if (r.caliber != null) r.caliber,
              if (r.powderChargeGr != null) '${r.powderChargeGr}gr',
              if (r.bullet != null) r.bullet,
              if (r.coalIn != null) 'COAL ${r.coalIn}"',
            ].whereType<String>().join(' · ');
            final isSelectedForShare = selectedIds.contains(r.id);
            final isDetailSelected =
                !isSelecting && selectedRecipeId == r.id;
            final tile = ListTile(
              title: Text(r.name),
              subtitle: subtitle.isEmpty ? null : Text(subtitle),
              leading: isSelecting
                  ? Checkbox(
                      value: isSelectedForShare,
                      onChanged: (_) => onTap(r),
                    )
                  : null,
              // Trailing slot pairs the favorite star with the chevron
              // (or shows nothing in multi-select mode so the row's
              // checkbox-on-the-leading-side stays the only affordance).
              // Compact density on the star keeps the chevron in
              // place at the right edge.
              trailing: isSelecting
                  ? null
                  : Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        FavoriteStarButton(
                          isFavorite: r.isFavorite,
                          compact: true,
                          onToggle: () =>
                              repo.toggleFavorite(r.id),
                        ),
                        const Icon(Icons.chevron_right),
                      ],
                    ),
              selected: isSelectedForShare || isDetailSelected,
              selectedTileColor: isSelectedForShare
                  ? theme.colorScheme.primary.withValues(alpha: 0.18)
                  : theme.colorScheme.primary.withValues(alpha: 0.12),
              onTap: () => onTap(r),
              onLongPress: () => onLongPress(r),
            );
            // In multi-select mode, suppress the swipe-to-delete so a
            // stray drag doesn't destroy a row mid-selection.
            if (isSelecting) {
              return KeyedSubtree(
                key: ValueKey('recipe_${r.id}'),
                child: tile,
              );
            }
            return Dismissible(
              key: ValueKey('recipe_${r.id}'),
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
                        title: const Text('Delete This Recipe?'),
                        content: Text('"${r.name}" will be removed.'),
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
              onDismissed: (_) => onDelete(r.id),
              child: tile,
            );
          },
        );
      },
    );
  }
}

/// Right-hand detail pane on wide layouts. Re-fetches the recipe by id
/// (cheap — Drift hits SQLite) and embeds [RecipeFormScreen] inside the
/// shell rather than pushing it as a route. Wrapping in a `Builder`
/// keeps the form's own internal scaffold/appbar — the parent shell
/// already provides the toolbar above the rail.
class _RecipeDetailPane extends StatelessWidget {
  const _RecipeDetailPane({super.key, required this.recipeId});

  final int recipeId;

  @override
  Widget build(BuildContext context) {
    final repo = context.read<RecipeRepository>();
    return FutureBuilder<UserLoadRow?>(
      future: repo.getById(recipeId),
      builder: (context, snap) {
        if (snap.connectionState != ConnectionState.done) {
          return const Center(child: CircularProgressIndicator());
        }
        final row = snap.data;
        if (row == null) {
          return const _EmptyDetailPane(
            message: 'Recipe not found. It may have been deleted.',
          );
        }
        return RecipeFormScreen(existing: row);
      },
    );
  }
}

/// Friendly placeholder shown in the right pane when no recipe is
/// selected (or the previously-selected recipe was deleted).
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
              Icons.list_alt_outlined,
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
