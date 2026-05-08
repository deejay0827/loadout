// FILE: lib/widgets/quick_add_fab_stack.dart
//
// ============================================================================
// WHAT THIS FILE DOES
// ============================================================================
// A bottom-right FAB cluster used on every list screen that has both a
// "Quick Add" (notebook-line minimal form) and a full add path
// (detailed form / import wizard / template picker). Renders an
// extended Quick FAB above a circular `+` FAB:
//
//        ┌────────────┐
//        │ ⚡ Quick   │  ← FloatingActionButton.extended, brass-tinted
//        └────────────┘
//
//        ┌────┐
//        │  + │           ← FloatingActionButton, default scheme
//        └────┘
//
// The Quick FAB pushes the screen-specific quick form with one tap;
// the `+` FAB opens the existing bottom-sheet add menu (or pushes the
// detailed form, depending on the screen).
//
// ============================================================================
// WHY IT EXISTS IN THE ARCHITECTURE
// ============================================================================
// Pre-launch user research showed Quick Add (the notebook-line form)
// is the most-used entry point for recipes — but it lived three taps
// deep behind the single `+` FAB → bottom-sheet → "Quick Add" row. By
// pulling Quick Add up to a separate visible FAB, the most common
// action becomes a one-tap reach. The `+` FAB stays for the full set
// of add options.
//
// Same pattern applies to firearms, brass lots, and batches: each has
// a "minimal create" path (name + a couple of fields) and a "detailed
// create" path with everything. Sharing this widget keeps the
// behaviour consistent across screens — same colors, same elevation,
// same spacing — without each list screen reinventing the layout.
//
// ============================================================================
// WHY THIS IS HARDER THAN IT LOOKS
// ============================================================================
// 1. **Distinct hero tags.** Each `FloatingActionButton` in the
//    widget tree must have a unique hero tag (Flutter uses them to
//    animate FAB transitions across routes). The two FABs in this
//    cluster derive their tags from a single `tagPrefix` parameter:
//    `<prefix>_quick` for the extended FAB and `<prefix>_add` for
//    the round one. Callers must pass distinct prefixes per list
//    screen.
// 2. **The cluster always overlays the list.** Flutter's
//    `Scaffold.floatingActionButton` floats over the body content
//    regardless of scroll state, so this is automatic. The widget
//    itself is a `Column(mainAxisSize: MainAxisSize.min)` so it
//    doesn't try to fill height, which would break the
//    bottom-right docking.
// 3. **Extended FAB doesn't cover the round FAB on small screens.**
//    The 12px gap between the two FABs is just enough that on
//    narrow phones in landscape (where there's already minimal
//    bottom space) the cluster doesn't crowd into the keyboard or
//    the bottom-nav. Keeping both visible at all times is a
//    deliberate choice — hiding the Quick FAB on small layouts
//    would defeat the purpose.
//
// ============================================================================
// WHO CONSUMES THIS FILE
// ============================================================================
// - lib/screens/recipes/recipes_list_screen.dart
// - lib/screens/firearms/firearms_list_screen.dart
// - lib/screens/brass_lots/brass_lots_list_screen.dart
// - lib/screens/batches/batches_list_screen.dart

import 'package:flutter/material.dart';

/// Two-FAB cluster used on the four primary list screens. Pass a
/// distinct [tagPrefix] per screen so the underlying hero animations
/// don't collide across tabs.
class QuickAddFabStack extends StatelessWidget {
  const QuickAddFabStack({
    super.key,
    required this.tagPrefix,
    required this.quickIcon,
    required this.quickLabel,
    required this.onQuickPressed,
    required this.onAddPressed,
    this.addTooltip = 'More options',
  });

  /// Unique prefix used to derive both FABs' hero tags. Must differ
  /// across list screens.
  final String tagPrefix;

  /// Icon shown on the extended Quick FAB. Use a glyph that signals
  /// speed (e.g. [Icons.bolt]).
  final IconData quickIcon;

  /// Label shown on the extended Quick FAB. Short — under 8 chars
  /// reads well at every supported width.
  final String quickLabel;

  /// Called when the user taps the Quick FAB.
  final VoidCallback onQuickPressed;

  /// Called when the user taps the `+` FAB.
  final VoidCallback onAddPressed;

  /// Tooltip text for the `+` FAB. Defaults to "More options".
  final String addTooltip;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        FloatingActionButton.extended(
          heroTag: '${tagPrefix}_quick',
          onPressed: onQuickPressed,
          icon: Icon(quickIcon),
          label: Text(quickLabel),
          // Brass-tinted variant — uses the secondary container so the
          // Quick FAB reads as related-but-distinct from the standard
          // primary `+` FAB.
          backgroundColor: theme.colorScheme.secondaryContainer,
          foregroundColor: theme.colorScheme.onSecondaryContainer,
        ),
        const SizedBox(height: 12),
        FloatingActionButton(
          heroTag: '${tagPrefix}_add',
          tooltip: addTooltip,
          onPressed: onAddPressed,
          child: const Icon(Icons.add),
        ),
      ],
    );
  }
}
