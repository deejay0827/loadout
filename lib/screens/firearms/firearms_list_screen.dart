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
// The trailing area shows a compact "<n> shots" counter (round count
// fired, sourced from `UserFirearmRow.shotsFired`) followed by the
// chevron. Tapping a tile pushes `FirearmFormScreen(existing: f)`; the
// FAB pushes a blank `FirearmFormScreen()`.
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
import 'firearm_form_screen.dart';

class FirearmsListScreen extends StatelessWidget {
  const FirearmsListScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final repo = context.read<FirearmRepository>();
    return Scaffold(
      body: StreamBuilder<List<UserFirearmRow>>(
        stream: repo.watchAll(),
        builder: (context, snap) {
          if (snap.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          }
          final firearms = snap.data ?? const <UserFirearmRow>[];
          if (firearms.isEmpty) {
            return const Center(
              child: Text('No firearms yet. Tap + to add your first.'),
            );
          }
          return ListView.separated(
            itemCount: firearms.length,
            separatorBuilder: (_, _) => const Divider(height: 1),
            itemBuilder: (context, i) {
              final f = firearms[i];
              final subtitle = [
                if (f.model != null) f.model,
                if (f.caliber != null) f.caliber,
              ].whereType<String>().join(' · ');
              return Dismissible(
                key: ValueKey('firearm_${f.id}'),
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
                onDismissed: (_) => repo.delete(f.id),
                child: ListTile(
                  title: Text(f.name),
                  subtitle: subtitle.isEmpty ? null : Text(subtitle),
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        '${f.shotsFired} shots',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                      const SizedBox(width: 8),
                      const Icon(Icons.chevron_right),
                    ],
                  ),
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) => FirearmFormScreen(existing: f),
                    ),
                  ),
                ),
              );
            },
          );
        },
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: () => Navigator.of(context).push(
          MaterialPageRoute(builder: (_) => const FirearmFormScreen()),
        ),
        child: const Icon(Icons.add),
      ),
    );
  }
}
