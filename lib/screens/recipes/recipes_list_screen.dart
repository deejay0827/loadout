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
// whichever fields are populated. Tapping a tile pushes
// `RecipeFormScreen(existing: r)` for editing; the floating action button
// pushes a blank `RecipeFormScreen()` for creating a new recipe.
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

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../database/database.dart';
import '../../repositories/recipe_repository.dart';
import '../../services/beginner_mode_service.dart';
import '../../utils/responsive.dart';
import 'photo_import_screen.dart';
import 'quick_add_recipe_screen.dart';
import 'recipe_form_screen.dart';
import 'smart_import_screen.dart';

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

  @override
  Widget build(BuildContext context) {
    final repo = context.read<RecipeRepository>();
    final isWide = Breakpoints.isWide(context);
    // Beginner Mode short-circuits the FAB straight into Quick Add.
    // Power users (Beginner Mode off) get the two-button picker so the
    // long form is one tap away. Quick Add itself still surfaces a
    // "Switch to detailed" link inside the screen for both audiences.
    final beginnerOn = context.watch<BeginnerModeService>().isEnabled;

    final list = _RecipesList(
      onTap: (r) {
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
      selectedRecipeId: isWide ? _selectedRecipeId : null,
      onDelete: (id) async {
        await repo.delete(id);
        if (mounted && _selectedRecipeId == id) {
          setState(() => _selectedRecipeId = null);
        }
      },
    );

    final fab = FloatingActionButton(
      heroTag: 'recipes_fab',
      onPressed: () {
        if (beginnerOn) {
          Navigator.of(context).push(
            MaterialPageRoute(
              builder: (_) => const QuickAddRecipeScreen(),
            ),
          );
        } else {
          _showAddOptions(context, isWide: isWide);
        }
      },
      child: const Icon(Icons.add),
    );

    if (!isWide) {
      return Scaffold(
        body: list,
        floatingActionButton: fab,
      );
    }

    return Scaffold(
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
            child: _selectedRecipeId == null
                ? const _EmptyDetailPane(
                    message:
                        'Select a recipe to view or edit it, or tap + to create one.',
                  )
                : _RecipeDetailPane(
                    key: ValueKey('recipe_detail_${_selectedRecipeId!}'),
                    recipeId: _selectedRecipeId!,
                  ),
          ),
        ],
      ),
      floatingActionButton: fab,
    );
  }

  /// Bottom-sheet "Quick Add" / "Detailed Recipe" picker. Shown in place
  /// of an instant push so beginners default into Quick Add but power
  /// users can reach the full form in one extra tap.
  void _showAddOptions(BuildContext context, {required bool isWide}) {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (sheetCtx) {
        final theme = Theme.of(sheetCtx);
        return SafeArea(
          top: false,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 4, 20, 12),
                child: Text(
                  'Add a Recipe',
                  style: theme.textTheme.titleLarge,
                ),
              ),
              ListTile(
                leading: Icon(
                  Icons.bolt,
                  color: theme.colorScheme.primary,
                ),
                title: const Text('Quick Add'),
                subtitle: const Text(
                  'Just the basics — like a notebook line',
                ),
                onTap: () {
                  Navigator.of(sheetCtx).pop();
                  Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) => const QuickAddRecipeScreen(),
                    ),
                  );
                },
              ),
              ListTile(
                leading: Icon(
                  Icons.tune,
                  color: theme.colorScheme.primary,
                ),
                title: const Text('Detailed Recipe'),
                subtitle: const Text(
                  'Every field — CBTO, primer, brass lots, pressure, more',
                ),
                onTap: () {
                  Navigator.of(sheetCtx).pop();
                  Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) => const RecipeFormScreen(),
                    ),
                  );
                },
              ),
              const Divider(height: 1),
              ListTile(
                leading: Icon(
                  Icons.table_chart_outlined,
                  color: theme.colorScheme.primary,
                ),
                title: const Text('Import from spreadsheet'),
                subtitle: const Text(
                  'Bring loads in from a CSV or Excel file — free.',
                ),
                onTap: () {
                  Navigator.of(sheetCtx).pop();
                  Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) => const SmartImportScreen(),
                    ),
                  );
                },
              ),
              if (PhotoImportScreen.isSupportedPlatform)
                ListTile(
                  leading: Icon(
                    Icons.photo_camera_outlined,
                    color: theme.colorScheme.primary,
                  ),
                  title: const Text('Import from photo'),
                  subtitle: const Text(
                    'Snap a notebook page — read on this device. Free.',
                  ),
                  onTap: () {
                    Navigator.of(sheetCtx).pop();
                    Navigator.of(context).push(
                      MaterialPageRoute(
                        builder: (_) => const PhotoImportScreen(),
                      ),
                    );
                  },
                ),
              const SizedBox(height: 8),
            ],
          ),
        );
      },
    );
  }
}

/// Recipe list (master pane) — the same `StreamBuilder<List<UserLoadRow>>`
/// + `Dismissible` swipe-to-delete pattern that used to live inline. Tap
/// behaviour is delegated upstream so the parent can decide whether to
/// push a route (phone) or update detail-pane state (wide).
class _RecipesList extends StatelessWidget {
  const _RecipesList({
    required this.onTap,
    required this.onDelete,
    this.selectedRecipeId,
  });

  final ValueChanged<UserLoadRow> onTap;
  final ValueChanged<int> onDelete;
  final int? selectedRecipeId;

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
        final recipes = snap.data ?? const <UserLoadRow>[];
        if (recipes.isEmpty) {
          return const Center(
            child: Text('No recipes yet. Tap + to create your first.'),
          );
        }
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
            final selected = selectedRecipeId == r.id;
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
              child: ListTile(
                title: Text(r.name),
                subtitle: subtitle.isEmpty ? null : Text(subtitle),
                trailing: const Icon(Icons.chevron_right),
                selected: selected,
                selectedTileColor:
                    theme.colorScheme.primary.withValues(alpha: 0.12),
                onTap: () => onTap(r),
              ),
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
