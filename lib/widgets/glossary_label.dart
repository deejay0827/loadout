// FILE: lib/widgets/glossary_label.dart
//
// ============================================================================
// WHAT THIS FILE DOES
// ============================================================================
// `GlossaryLabel` renders a tappable form-field label that, on tap,
// shows a bottom-sheet modal with the matching glossary entry's
// definition (and optional worked example), plus an "Open in
// Glossary" button that pushes the full `GlossaryScreen` filtered to
// the term. It's the in-form learning surface for jargon — novices
// can tap "Drop" or "CBTO" without leaving the form they're filling
// in.
//
// The widget delegates lookup to `GlossaryLookup.find(...)`. When no
// glossary entry matches the supplied label string, the widget
// renders as a plain `Text` (no `(?)` glyph) so the UI never lies
// about the existence of help. When a match is found, the widget
// renders a `Row` of `[Text, (?)]` wrapped in an `InkWell` so taps
// anywhere on the label open the modal.
//
// API:
//
//   GlossaryLabel(
//     text: 'Drop',                   // visible label text
//     glossaryTerm: 'Drop',           // optional: explicit lookup key,
//                                     // falls back to `text` if null
//     style: TextStyle(...),          // optional: matches existing
//                                     // label style; the widget
//                                     // applies the style to the
//                                     // visible text without
//                                     // mutating it.
//     showHelpIcon: true,             // optional: show the trailing
//                                     // (?) glyph; defaults true.
//   )
//
// `GlossaryLabel.formLabel(...)` is a convenience constructor for the
// most common case (a label inside an `InputDecoration.label` slot)
// that pre-applies the theme's `bodyMedium` font weight.
//
// ============================================================================
// WHY IT EXISTS IN THE ARCHITECTURE
// ============================================================================
// LoadOut's reloading vocabulary is dense (BC G1, CBTO, density
// altitude, spin drift, aerodynamic jump, Litz CI). Without an
// in-form learning affordance, novices have to leave the form, open
// the side drawer, search the glossary, then come back. That's
// friction enough to make the form abandon-able. This widget is the
// minimum-viable mitigation: tap a label, get a definition, optionally
// jump to the full entry. The same widget lives across the recipe
// form, ballistics screen, range day, group stats, moving target, and
// load development screens — one consistent affordance everywhere.
//
// ============================================================================
// WHY THIS IS HARDER THAN IT LOOKS
// ============================================================================
// - `InputDecoration.labelText` only accepts a `String`, not a
//   widget. To use this in an existing `TextFormField`, callers must
//   either (a) move the label out of the decoration and put a
//   `GlossaryLabel` above the field, or (b) use
//   `InputDecoration.label: GlossaryLabel(...)` which DOES accept a
//   widget. We prefer (b) when the surrounding form's spacing tolerates
//   the slight style differences between Material's floating label
//   and our row-of-Text-plus-glyph.
// - The "(?)" glyph must NEVER render when no glossary match exists —
//   that's a usability promise. The widget calls `GlossaryLookup.find`
//   once per build; on a miss it returns a plain `Text`.
// - The bottom sheet must be safe to invoke from any context (a form
//   inside a scaffold, a modal-on-modal stack, etc.). We use
//   `showModalBottomSheet` with `useSafeArea: true` and a max-height
//   constraint so it doesn't push past the keyboard.
// - Because `GlossaryLookup` is cheap (Map exact + ~80-entry scan),
//   we don't memoize per-instance — the lookup happens in `build()`
//   without observable cost on screens with 50+ labels.
//
// ============================================================================
// WHO CONSUMES THIS FILE
// ============================================================================
// - `lib/screens/range_day/range_day_detail_screen.dart`
// - `lib/screens/range_day/group_stats_screen.dart`
// - `lib/screens/range_day/moving_target_screen.dart`
// - `lib/screens/recipes/recipe_form_screen.dart`
// - `lib/screens/ballistics/ballistics_screen.dart`
// - `lib/screens/load_development/load_development_detail_screen.dart`
// - Other forms can adopt the widget freely; the API is intentionally
//   small enough that a one-line wrap converts a `Text(label)` into a
//   `GlossaryLabel(text: label)`.
//
// ============================================================================
// SIDE EFFECTS
// ============================================================================
// - On tap, opens a modal bottom sheet (`showModalBottomSheet`).
// - The "Open in Glossary" button inside the sheet pushes
//   `GlossaryScreen` onto the navigator with a pre-filled query.
// - No persistent state, no I/O, no analytics.

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../screens/glossary/glossary_screen.dart';
import '../services/beginner_mode_service.dart';
import '../services/glossary_first_seen_tracker.dart';
import '../services/glossary_lookup.dart';

/// Tappable form-field label that surfaces the glossary definition
/// for the term in a bottom-sheet modal.
class GlossaryLabel extends StatelessWidget {
  /// Visible label text.
  final String text;

  /// Explicit lookup key. Falls back to [text] when null. Use this
  /// when the visible label decorates the term (e.g. "Drop (mil)") or
  /// when one screen needs to point at a glossary entry whose name
  /// differs from the visible label (e.g. labelling a chip "Sg" but
  /// pointing at "Miller stability formula").
  final String? glossaryTerm;

  /// Optional text style applied to the visible label. When null, the
  /// widget defers to the ambient `DefaultTextStyle`.
  final TextStyle? style;

  /// Whether to render the trailing `(?)` glyph when a glossary
  /// match exists. Defaults true; set to false for compact rows
  /// where the glyph would crowd other UI.
  final bool showHelpIcon;

  /// Optional max-line override forwarded to the underlying [Text]
  /// so callers can constrain wrapping inside narrow chips.
  final int? maxLines;

  /// Optional overflow override forwarded to the underlying [Text].
  final TextOverflow? overflow;

  const GlossaryLabel({
    super.key,
    required this.text,
    this.glossaryTerm,
    this.style,
    this.showHelpIcon = true,
    this.maxLines,
    this.overflow,
  });

  @override
  Widget build(BuildContext context) {
    final lookupKey = (glossaryTerm == null || glossaryTerm!.trim().isEmpty)
        ? text
        : glossaryTerm!;
    final entry = GlossaryLookup.find(lookupKey);
    if (entry == null) {
      // Soft-fail: render exactly the same Text the caller would have
      // produced before the upgrade. Never leak a non-functional (?)
      // glyph into the UI.
      return Text(
        text,
        style: style,
        maxLines: maxLines,
        overflow: overflow,
      );
    }
    final theme = Theme.of(context);
    final color = style?.color ?? DefaultTextStyle.of(context).style.color;

    // Beginner Mode → first-occurrence emphasis. We consult the
    // BeginnerModeService and the session-scoped seen-tracker; when
    // the term is "new" to this session AND Beginner Mode is on,
    // the (?) glyph renders in the theme's primary colour at full
    // opacity so the user actually NOTICES that an explainer exists.
    // Subsequent appearances of the same term render in the muted
    // gray below — the emphasis fires once per session per term, not
    // every build.
    //
    // Safe-fallback: if either provider isn't in scope (e.g. a
    // standalone widget test pumping just this label), the lookup
    // returns false / null and the emphasis path silently degrades
    // to the existing subtle look.
    final beginnerOn = _readBeginnerOn(context);
    final seen = _readSeen(context);
    final emphasized = beginnerOn &&
        showHelpIcon &&
        seen != null &&
        !seen.hasSeen(entry.term);
    if (emphasized) {
      // `emphasized == true` implies `seen != null` per the && chain
      // above; Dart's flow analysis narrows the type for us inside
      // this branch. Schedule mark-seen for after this frame so we
      // don't mutate shared state during a build pass. The next
      // rebuild reads `seen.hasSeen(entry.term) == true` and falls
      // back to the muted glyph.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        seen.markSeen(entry.term);
      });
    }

    final glyphColor = emphasized
        ? theme.colorScheme.primary
        : (color?.withValues(alpha: 0.6) ??
            theme.colorScheme.onSurfaceVariant);
    final glyphSize = emphasized ? 16.0 : 14.0;

    return InkWell(
      onTap: () => _showSheet(context, entry),
      borderRadius: BorderRadius.circular(6),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 2),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Flexible(
              child: Text(
                text,
                style: style,
                maxLines: maxLines,
                overflow: overflow,
              ),
            ),
            if (showHelpIcon) ...[
              const SizedBox(width: 4),
              Icon(
                Icons.help_outline,
                size: glyphSize,
                color: glyphColor,
                semanticLabel: 'Show definition',
              ),
            ],
          ],
        ),
      ),
    );
  }

  /// Read the session-scoped first-seen tracker if it's been provided.
  /// Returns null when no `Provider<GlossaryFirstSeenTracker>` is in
  /// scope so widget tests that pump just a label compile cleanly.
  GlossaryFirstSeenTracker? _readSeen(BuildContext context) {
    try {
      return Provider.of<GlossaryFirstSeenTracker>(context, listen: false);
    } catch (_) {
      return null;
    }
  }

  /// Read [BeginnerModeService.isEnabled] without throwing when no
  /// provider is in scope. Mirrors [_readSeen]'s defensive pattern so
  /// widget tests for this label don't have to scaffold the whole
  /// provider tree just to render one (?) glyph.
  bool _readBeginnerOn(BuildContext context) {
    try {
      return Provider.of<BeginnerModeService>(context, listen: false)
          .isEnabled;
    } catch (_) {
      return false;
    }
  }

  static void _showSheet(BuildContext context, GlossaryTerm entry) {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      showDragHandle: true,
      builder: (sheetContext) => _GlossarySheet(entry: entry),
    );
  }
}

class _GlossarySheet extends StatelessWidget {
  final GlossaryTerm entry;

  const _GlossarySheet({required this.entry});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final textTheme = theme.textTheme;
    final media = MediaQuery.of(context);
    return ConstrainedBox(
      constraints: BoxConstraints(maxHeight: media.size.height * 0.7),
      child: SingleChildScrollView(
        padding: EdgeInsets.fromLTRB(
          20,
          4,
          20,
          20 + media.viewInsets.bottom,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              entry.term,
              style: textTheme.titleLarge?.copyWith(
                fontWeight: FontWeight.w600,
              ),
            ),
            if (entry.acronym != null) ...[
              const SizedBox(height: 4),
              Text(
                entry.acronym!,
                style: textTheme.titleSmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ],
            const SizedBox(height: 8),
            Text(
              entry.category,
              style: textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 16),
            Text(
              entry.definition,
              style: textTheme.bodyMedium?.copyWith(height: 1.4),
            ),
            if (entry.example != null && entry.example!.trim().isNotEmpty) ...[
              const SizedBox(height: 16),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: theme.colorScheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Example',
                      style: textTheme.labelLarge?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    if (entry.exampleNumbers != null &&
                        entry.exampleNumbers!.trim().isNotEmpty) ...[
                      const SizedBox(height: 4),
                      Text(
                        entry.exampleNumbers!,
                        style: textTheme.bodySmall?.copyWith(
                          fontFeatures: const [FontFeature.tabularFigures()],
                          color: theme.colorScheme.primary,
                        ),
                      ),
                    ],
                    const SizedBox(height: 6),
                    Text(
                      entry.example!,
                      style: textTheme.bodyMedium?.copyWith(height: 1.4),
                    ),
                  ],
                ),
              ),
            ],
            const SizedBox(height: 20),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                onPressed: () {
                  Navigator.of(context).pop();
                  Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) => GlossaryScreen(
                        initialQuery: entry.term,
                      ),
                    ),
                  );
                },
                icon: const Icon(Icons.menu_book_outlined),
                label: const Text('Open in Glossary'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
