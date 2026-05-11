// FILE: lib/widgets/missing_inputs_card.dart
//
// ============================================================================
// WHAT THIS FILE DOES
// ============================================================================
// Shared "we can't compute the result because these inputs are missing"
// surface for the four ballistics-shaped screens in LoadOut:
//
//   * Range Day Solution / DOPE
//   * External Ballistics calculator
//   * Internal Ballistics calculator
//   * Ballistic Profile form
//
// Two exports:
//
//   * [MissingInputs] — immutable bundle of canonical field IDs that
//     are missing PLUS a parallel list of human-readable labels for
//     display. Forms construct one of these as the LAST step of
//     their solver / save validation; if `isEmpty`, the result
//     renders normally; if not, the screen surfaces a [MissingInputsCard]
//     and each affected form field shows its `errorText` instead of
//     a successful value.
//
//   * [MissingInputsCard] — the visual card. Renders an amber-bordered
//     panel with a clear heading ("Can't compute firing solution
//     yet") and a bulleted list of missing field labels. Stays out
//     of the way when there's nothing to show — callers conditionally
//     render the card only when `missing.isNotEmpty`.
//
// The pattern is deliberately simple: a screen tracks its own
// "currently missing fields" set and uses it to drive both the
// per-field `errorText:` (the red indicator the user sees on each
// problem field) and this card (the human-readable explanation).
// Centralising the LIST representation keeps the visual consistent
// across the four screens.
//
// ============================================================================
// WHY IT EXISTS IN THE ARCHITECTURE
// ============================================================================
// User directive (paraphrased): "When we cannot provide a solution
// (ballistics for range day, profiles, or internal), show the user
// what is missing. The field itself should also have a red indicator."
//
// Before this widget, the three solver-driven screens each handled
// "couldn't compute" differently: Range Day showed a "fill in fields"
// banner with no specifics; Internal Ballistics showed a "Cannot
// Model This Load" card with prose but no field list; the Ballistic
// Profile form just relied on `Form.validate()` errors per-field
// without any summary. A shared widget gives the three surfaces the
// same UX: a summary of WHAT'S missing alongside per-field red
// indicators.
//
// Privacy-safe by construction: the model only carries STABLE FIELD
// IDS (canonical names like `'bc'`, `'mv'`, `'caliber'`) and their
// display labels. No user-typed values cross this boundary, so a
// crash report or screenshot never leaks recipe / firearm content.
//
// ============================================================================
// WHY THIS IS HARDER THAN IT LOOKS
// ============================================================================
//   * Field IDs vs. labels. The form's `errorText:` decision lives
//     in the form's build method, which knows the controller binding
//     by ID (`_bcCtrl`, `_mvCtrl`, etc.). The card's bulleted display
//     wants natural prose ("Ballistic Coefficient", "Muzzle Velocity").
//     The model carries BOTH so each consumer reads from the same
//     source of truth.
//
//   * "Required" vs. "Required for solution" distinction. A field
//     can be blank without being a HARD validation error — e.g.
//     atmosphere is optional (the solver falls back to ICAO
//     standard) but BC is mandatory. The card lists ONLY the hard-
//     blocker fields. Optional-but-empty fields don't surface here.
//
//   * Re-validation timing. The card / errorText updates when the
//     form's compute path runs (debounced, post-keystroke). If the
//     user fixes the missing field, the next compute pass should
//     clear the missing-inputs state — every consumer must re-build
//     the [MissingInputs] from current state on each compute, not
//     accumulate stale entries.
//
// ============================================================================
// WHO CONSUMES THIS FILE
// ============================================================================
//   - lib/screens/range_day/range_day_detail_screen.dart — Solution
//     card empty state.
//   - lib/screens/ballistics/internal_ballistics_screen.dart — result
//     panel "Cannot Model This Load" branch.
//   - lib/screens/ballistics/ballistic_profile_form_screen.dart — top
//     of the form when save validation fails.
//
// ============================================================================
// SIDE EFFECTS
// ============================================================================
// None. Pure widget + immutable data class.

import 'package:flutter/material.dart';

/// Immutable bundle of fields that are blocking a computation. Forms
/// produce one on every solver / save attempt; an empty bundle means
/// "all required inputs are present" and the result renders normally.
@immutable
class MissingInputs {
  const MissingInputs({
    this.entries = const <MissingInputEntry>[],
  });

  /// Sentinel "everything's fine" instance. Use this rather than
  /// constructing a fresh empty MissingInputs every time so the
  /// `isEmpty` check is cheap and `==` works trivially.
  static const empty = MissingInputs();

  /// One per missing field, in the order the form wants them
  /// presented in the card.
  final List<MissingInputEntry> entries;

  bool get isEmpty => entries.isEmpty;
  bool get isNotEmpty => entries.isNotEmpty;

  /// True when a field with the given canonical ID is in the missing
  /// list. Used by per-field `errorText:` decisions in the form's
  /// `build` method:
  ///
  /// ```dart
  /// TextFormField(
  ///   controller: _bcCtrl,
  ///   decoration: InputDecoration(
  ///     labelText: 'BC',
  ///     errorText: _missing.contains('bc') ? 'Required for solution' : null,
  ///   ),
  /// )
  /// ```
  bool contains(String fieldId) =>
      entries.any((e) => e.fieldId == fieldId);

  @override
  bool operator ==(Object other) =>
      other is MissingInputs &&
      other.entries.length == entries.length &&
      _entriesMatch(other.entries);

  bool _entriesMatch(List<MissingInputEntry> other) {
    for (var i = 0; i < entries.length; i++) {
      if (entries[i] != other[i]) return false;
    }
    return true;
  }

  @override
  int get hashCode => Object.hashAll(entries);
}

/// One missing-input row. `fieldId` is the canonical ID the form's
/// `errorText:` decision uses; `label` is the human-readable
/// description shown in the card.
@immutable
class MissingInputEntry {
  const MissingInputEntry({
    required this.fieldId,
    required this.label,
    this.detail,
  });

  /// Stable identifier — `'bc'`, `'mv'`, `'distance'`, `'caliber'`,
  /// etc. Match this against per-field `errorText:` decisions.
  final String fieldId;

  /// Title-cased human-readable name shown in the card's bulleted
  /// list — `'Ballistic Coefficient'`, `'Muzzle Velocity'`,
  /// `'Distance to Target'`.
  final String label;

  /// Optional one-line clarification beneath the label. Used when
  /// the field's name alone doesn't make clear WHY it's needed —
  /// e.g. label `'Twist Rate'`, detail `'For spin-drift correction.'`.
  final String? detail;

  @override
  bool operator ==(Object other) =>
      other is MissingInputEntry &&
      other.fieldId == fieldId &&
      other.label == label &&
      other.detail == detail;

  @override
  int get hashCode => Object.hash(fieldId, label, detail);
}

/// Amber-bordered card explaining what inputs the screen is waiting
/// on before it can produce a result. Renders nothing when
/// `missing.isEmpty` (caller can choose to skip the widget entirely;
/// rendering an empty card with this widget is also harmless).
///
/// `headline` defaults to "Can't compute the result yet" but
/// callers should pass a context-specific phrasing — "Can't compute
/// firing solution yet" / "Can't predict pressure & MV yet" /
/// "Can't save profile yet" — so the card reads naturally inside
/// each surface.
class MissingInputsCard extends StatelessWidget {
  const MissingInputsCard({
    super.key,
    required this.missing,
    this.headline = "Can't compute the result yet",
    this.detail,
  });

  final MissingInputs missing;
  final String headline;

  /// Optional one-paragraph context that renders below the headline,
  /// before the bulleted list. Use it to remind the user how to
  /// resolve the missing inputs ("Pick a load above to fill these
  /// in automatically.").
  final String? detail;

  @override
  Widget build(BuildContext context) {
    if (missing.isEmpty) return const SizedBox.shrink();
    final theme = Theme.of(context);
    final amber = theme.brightness == Brightness.dark
        ? const Color(0xFFFFCA70)
        : const Color(0xFFFFA000);
    final amberBg = theme.brightness == Brightness.dark
        ? const Color(0xFF3B2F1F)
        : const Color(0xFFFFF8E1);
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 14, 14, 14),
      decoration: BoxDecoration(
        color: amberBg,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: amber, width: 1.0),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            Icons.error_outline,
            size: 22,
            color: amber,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  headline,
                  style: theme.textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w700,
                    color: theme.colorScheme.onSurface,
                  ),
                ),
                if (detail != null) ...[
                  const SizedBox(height: 6),
                  Text(
                    detail!,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurface,
                      height: 1.35,
                    ),
                  ),
                ],
                const SizedBox(height: 10),
                ...missing.entries.map(
                  (entry) => Padding(
                    padding: const EdgeInsets.only(bottom: 4),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Padding(
                          padding: const EdgeInsets.only(top: 6),
                          child: Container(
                            width: 5,
                            height: 5,
                            decoration: BoxDecoration(
                              color: amber,
                              shape: BoxShape.circle,
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                entry.label,
                                style: theme.textTheme.bodyMedium?.copyWith(
                                  fontWeight: FontWeight.w600,
                                  color: theme.colorScheme.onSurface,
                                ),
                              ),
                              if (entry.detail != null)
                                Text(
                                  entry.detail!,
                                  style: theme.textTheme.bodySmall?.copyWith(
                                    color: theme.colorScheme.onSurfaceVariant,
                                  ),
                                ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
