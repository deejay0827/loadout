// FILE: lib/widgets/disclaimer_overlay.dart
//
// ============================================================================
// WHAT THIS FILE DOES
// ============================================================================
// Defines a single top-level function, `showLaunchDisclaimer(context)`,
// that pops up a small reminder dialog ("Always verify recipe data...
// you accept all risk") on top of whatever screen is currently visible.
// The dialog has a single "I Understand" button. It cannot be dismissed by
// tapping outside or hitting the back button (`barrierDismissible: false`).
// The function returns a `Future<void>` that completes when the user taps
// the button.
//
// `showDialog` is Flutter's standard helper for displaying a modal route
// over the current screen. The dialog's `AlertDialog` widget is the
// platform's standard "title + content + buttons" pattern.
//
// ============================================================================
// WHY IT EXISTS IN THE ARCHITECTURE
// ============================================================================
// LoadOut has two distinct disclaimer surfaces, and it's easy to confuse
// them:
//
//   1. The first-launch BLOCKING gate — `lib/screens/disclaimer/
//      disclaimer_screen.dart`. Full-screen, scroll-to-bottom required,
//      checkbox + Accept button. Persisted via the
//      `disclaimer_accepted_v1` SharedPreferences key. The user can never
//      reach the rest of the app without going through it once.
//
//   2. THIS file — a per-launch REMINDER. After the gate has been
//      accepted, the app shows this short dialog once each time the
//      process starts up. It's a brief safety reinforcement, not a gate.
//
// The reminder is triggered from `_DisclaimerGate` in `lib/app.dart` after
// it has confirmed that the gate-acceptance flag is set. By the time this
// dialog renders, the user has already accepted the long-form disclaimer
// at least once.
//
// ============================================================================
// WHY THIS IS HARDER THAN IT LOOKS
// ============================================================================
// Not particularly tricky. The only subtle bit is that the function uses
// `dialogContext` (the build context of the dialog itself) rather than
// the outer `context` argument when calling `Navigator.of(...).pop()`.
// That's the standard pattern: popping with the dialog's own context
// reliably tears down the dialog without affecting the route underneath.
//
// `barrierDismissible: false` is intentional — the user must tap the
// button. If they could tap-outside-to-dismiss, the reminder would be a
// banner-of-the-day rather than something they actually saw.
//
// ============================================================================
// WHO CONSUMES THIS FILE
// ============================================================================
// - `lib/app.dart` (`_DisclaimerGate`) — `await showLaunchDisclaimer(...)`
//   once per process lifetime, after confirming the first-launch gate has
//   already been accepted.
//
// ============================================================================
// SIDE EFFECTS
// ============================================================================
// Pushes a modal route onto Flutter's navigator stack. No persistence,
// no I/O, no plugins. Pure UI side effect.

import 'package:flutter/material.dart';

/// Shows a short, non-persistent reloading-safety reminder once per app
/// launch via [showDialog]. The user must tap "I understand" to dismiss.
Future<void> showLaunchDisclaimer(BuildContext context) {
  return showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (dialogContext) {
      final theme = Theme.of(dialogContext);
      return AlertDialog(
        title: const Text('Reminder'),
        content: SingleChildScrollView(
          child: Text(
            'Always verify recipe data against current manufacturer '
            'publications. LoadOut is reference information only — never '
            'your sole source. Reloading is dangerous; you accept all risk.',
            style: theme.textTheme.bodyMedium,
          ),
        ),
        actions: [
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('I Understand'),
          ),
        ],
      );
    },
  );
}
