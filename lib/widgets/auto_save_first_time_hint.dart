// FILE: lib/widgets/auto_save_first_time_hint.dart
//
// ============================================================================
// WHAT THIS FILE DOES
// ============================================================================
// One-time, non-blocking onboarding for autosave. Renders a Material 3
// `MaterialBanner` at the top of any form once — and only once — across
// all four autosave-enabled forms. Tapping "Got it" dismisses the banner
// and persists `auto_save_hint_shown=true` on [AutoSaveService] so it
// never reappears.
//
// Important: this is *deliberately not* an `AlertDialog`. The hint
// must not block interaction — beginners landing on a form for the
// first time should see it, learn the autosave behavior, and continue
// editing without a forced acknowledgment step.
//
// Implementation detail: the widget is a thin convenience wrapper. It
// reads [AutoSaveService] from `context.watch`, decides whether to
// show, and exposes a `child` slot that wraps the actual form body.
// When the hint is showing, the banner sits above the child via a
// `Column`. Calling `markFirstTimeHintShown` is what removes it.
//
// ============================================================================
// WHY IT EXISTS IN THE ARCHITECTURE
// ============================================================================
// We want autosave to feel transparent, not magical. A subtle one-time
// banner at the top of the first form they open is the cheapest way to
// say "your edits are safe, you don't need to worry about losing them."
// Putting the logic in a single widget means each form just wraps its
// content with `AutoSaveFirstTimeHint(controller: ..., child: ...)`
// and the rest is automatic.
//
// ============================================================================
// WHO CONSUMES THIS FILE
// ============================================================================
// - lib/screens/recipes/recipe_form_screen.dart
// - lib/screens/firearms/firearm_form_screen.dart
// - lib/screens/batches/batch_form_screen.dart
// - lib/screens/brass_lots/brass_lot_form_screen.dart
//
// ============================================================================
// SIDE EFFECTS
// ============================================================================
// Calls `AutoSaveService.markFirstTimeHintShown()` when the user taps
// "Got it" — that flips the persisted preference.

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../services/auto_save_service.dart';

class AutoSaveFirstTimeHint extends StatelessWidget {
  const AutoSaveFirstTimeHint({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final service = context.watch<AutoSaveService>();
    final shouldShow = service.isHydrated &&
        service.frequency.savesAutomatically &&
        !service.hasShownFirstTimeHint;
    if (!shouldShow) return child;
    final theme = Theme.of(context);
    return Column(
      children: [
        Material(
          color: theme.colorScheme.primaryContainer,
          elevation: 0,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 12, 12),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(
                  Icons.bolt_outlined,
                  size: 18,
                  color: theme.colorScheme.onPrimaryContainer,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Auto-save is on',
                        style: theme.textTheme.titleSmall?.copyWith(
                          color: theme.colorScheme.onPrimaryContainer,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        'Your changes save automatically. You can turn this '
                        'off in Settings.',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onPrimaryContainer,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                TextButton(
                  style: TextButton.styleFrom(
                    foregroundColor: theme.colorScheme.onPrimaryContainer,
                  ),
                  onPressed: () {
                    // ignore: discarded_futures
                    service.markFirstTimeHintShown();
                  },
                  child: const Text('Got it'),
                ),
              ],
            ),
          ),
        ),
        Expanded(child: child),
      ],
    );
  }
}
