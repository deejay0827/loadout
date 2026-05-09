// FILE: lib/widgets/unsaved_changes_dispatcher.dart
//
// ============================================================================
// WHAT THIS FILE DOES
// ============================================================================
// A reusable `PopScope` wrapper that consults
// [AutoSaveService.unsavedChangesPolicy] every time the user pops a
// form. Three pieces:
//
// * [UnsavedChangesScope] — wraps the form body. Its `controller`
//   exposes `isDirty` (read off the live `AutoSaveController`); when
//   the user requests a pop and the form is dirty, the wrapper
//   intercepts the pop, runs the active policy, and only proceeds
//   when the policy says so.
//
// * [showUnsavedChangesDialog] — the `AlertDialog` shown by the
//   `ask` policy. Three buttons: Save, Discard, Cancel. Returns a
//   [_UnsavedChangesAction] so the caller can run the right
//   follow-up.
//
// * The save path always uses [AutoSaveController.forceSave] (which
//   runs regardless of the active frequency) rather than `flush`,
//   because the user explicitly chose "Save" — the frequency setting
//   shouldn't override their explicit consent.
//
// ============================================================================
// WHY IT EXISTS IN THE ARCHITECTURE
// ============================================================================
// Recipe and Ballistic Profile edit screens have to share the same
// unsaved-changes UX (per the autosave overhaul brief). Duplicating
// the PopScope + dialog code per screen is the kind of thing that
// drifts within a release cycle — copy A gets a fix, copy B doesn't.
// Centralizing it here keeps both screens behaviorally identical and
// makes Range Day's existing on-pop autosave (which uses its own
// debounced flow, NOT [AutoSaveController]) deliberately separate.
//
// ============================================================================
// WHY THIS IS HARDER THAN IT LOOKS
// ============================================================================
// 1. **`canPop: false` is required when we want to intercept.** A
//    `PopScope` with `canPop: true` lets the framework pop before
//    `onPopInvoked` runs, so the dialog would race the navigator. We
//    flip `canPop` based on `isDirty` so the framework only blocks
//    when there's something to consult.
// 2. **`Navigator.maybePop` after the dialog needs the parent
//    navigator.** Capturing it before the await is required —
//    after a dialog the screen's BuildContext may be gone, and
//    using a cached `NavigatorState` avoids the
//    `use_build_context_synchronously` lint AND makes the code
//    correct.
// 3. **Soft-failure on save.** A failed save (DB closed, validation
//    failure) should not abort the pop. The dispatcher reports the
//    failure via a SnackBar and proceeds to pop — staying on the
//    screen with no save would feel broken to the user. The
//    SnackBar is rendered against the Scaffold messenger captured
//    before the await.
//
// ============================================================================
// WHO CONSUMES THIS FILE
// ============================================================================
// - lib/screens/recipes/recipe_form_screen.dart
// - lib/screens/ballistics/ballistics_screen.dart
//   ↑ Both wrap their form body in [UnsavedChangesScope].
//
// ============================================================================
// SIDE EFFECTS
// ============================================================================
// - May show a modal `AlertDialog` (the `ask` policy).
// - May call `AutoSaveController.forceSave()` (the `saveAll` policy
//   and the `ask` → Save branch).
// - May show a SnackBar via the captured ScaffoldMessenger when the
//   save throws.

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../services/auto_save_service.dart';

/// Three exits from the unsaved-changes dialog. Internal — callers
/// receive the resolved decision via the dispatcher's pop logic
/// rather than reading this enum directly.
enum _UnsavedChangesAction { save, discard, cancel }

/// Wraps [child] in a [PopScope] that enforces the
/// [AutoSaveService.unsavedChangesPolicy] preference whenever the
/// user pops the screen.
///
/// `controller` is the form's [AutoSaveController]. The dispatcher
/// reads `controller.isDirty` to decide whether to intercept and
/// `controller.forceSave()` to persist when the policy / user choice
/// is "save."
class UnsavedChangesScope extends StatelessWidget {
  const UnsavedChangesScope({
    super.key,
    required this.controller,
    required this.child,
  });

  final AutoSaveController controller;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    // We don't need to rebuild on policy change — `onPopInvokedWithResult`
    // reads the current value off the service every time the user pops.
    // But we DO want a rebuild when `isDirty` flips, so the framework's
    // `canPop` value is up to date and the system back-gesture honors
    // it without a round-trip through our handler.
    return AnimatedBuilder(
      animation: Listenable.merge([
        controller.status,
        controller.lastSavedAt,
      ]),
      builder: (context, _) {
        final dirty = controller.isDirty;
        return PopScope(
          // When the form is clean, the pop fires through immediately —
          // the framework doesn't even ask us. When it's dirty we
          // disable the auto-pop so we can run the policy first.
          canPop: !dirty,
          onPopInvokedWithResult: (didPop, _) async {
            if (didPop) return; // already popped, nothing to do
            if (!controller.isDirty) {
              // Re-check after the await-free path: if the user
              // somehow ended up here with a clean form (e.g. a save
              // landed mid-gesture), pop directly.
              Navigator.of(context).pop();
              return;
            }
            await _handleDirtyPop(context);
          },
          child: child,
        );
      },
    );
  }

  Future<void> _handleDirtyPop(BuildContext context) async {
    final navigator = Navigator.of(context);
    final messenger = ScaffoldMessenger.of(context);
    final service = context.read<AutoSaveService>();
    final policy = service.unsavedChangesPolicy;

    Future<void> trySaveThenPop() async {
      try {
        await controller.forceSave();
      } catch (e) {
        messenger.showSnackBar(
          SnackBar(content: Text('Save failed: $e')),
        );
      }
      if (!navigator.mounted) return;
      navigator.pop();
    }

    switch (policy) {
      case UnsavedChangesPolicy.discard:
        navigator.pop();
        return;
      case UnsavedChangesPolicy.saveAll:
        await trySaveThenPop();
        return;
      case UnsavedChangesPolicy.ask:
        final action = await _showUnsavedChangesDialog(context);
        if (action == null) return; // dialog dismissed without choice
        if (!navigator.mounted) return;
        switch (action) {
          case _UnsavedChangesAction.save:
            await trySaveThenPop();
            return;
          case _UnsavedChangesAction.discard:
            navigator.pop();
            return;
          case _UnsavedChangesAction.cancel:
            // No-op — stay on the screen.
            return;
        }
    }
  }
}

/// The dialog shown by `UnsavedChangesPolicy.ask`. Returns the
/// user's choice or null if they dismissed without picking.
/// File-private — only the dispatcher uses this directly.
Future<_UnsavedChangesAction?> _showUnsavedChangesDialog(
  BuildContext context,
) {
  return showDialog<_UnsavedChangesAction>(
    context: context,
    barrierDismissible: true,
    builder: (ctx) => AlertDialog(
      title: const Text('Unsaved changes'),
      content: const Text(
        'You have unsaved changes on this form. What would you like '
        'to do?',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(ctx).pop(_UnsavedChangesAction.cancel),
          child: const Text('Cancel'),
        ),
        TextButton(
          onPressed: () =>
              Navigator.of(ctx).pop(_UnsavedChangesAction.discard),
          child: const Text('Discard'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(ctx).pop(_UnsavedChangesAction.save),
          child: const Text('Save'),
        ),
      ],
    ),
  );
}
