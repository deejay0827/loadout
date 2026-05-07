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
import 'quick_add_recipe_screen.dart';
import 'recipe_form_screen.dart';

class RecipesListScreen extends StatelessWidget {
  const RecipesListScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final repo = context.read<RecipeRepository>();
    return Scaffold(
      body: StreamBuilder<List<UserLoadRow>>(
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
              return Dismissible(
                key: ValueKey('recipe_${r.id}'),
                direction: DismissDirection.endToStart,
                background: Container(
                  color: Theme.of(context).colorScheme.errorContainer,
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
                onDismissed: (_) => repo.delete(r.id),
                child: ListTile(
                  title: Text(r.name),
                  subtitle: subtitle.isEmpty ? null : Text(subtitle),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) => RecipeFormScreen(existing: r),
                    ),
                  ),
                ),
              );
            },
          );
        },
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: () => _showAddOptions(context),
        child: const Icon(Icons.add),
      ),
    );
  }

  /// Bottom-sheet "Quick Add" / "Detailed Recipe" picker. Shown in place
  /// of an instant push so beginners default into Quick Add but power
  /// users can reach the full form in one extra tap.
  void _showAddOptions(BuildContext context) {
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
              const SizedBox(height: 8),
            ],
          ),
        );
      },
    );
  }
}
