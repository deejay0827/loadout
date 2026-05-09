// FILE: lib/services/glossary_first_seen_tracker.dart
//
// ============================================================================
// WHAT THIS FILE DOES
// ============================================================================
// In-memory, session-scoped registry of glossary terms the user has
// already encountered in the current run of the app. Backs the
// "first-occurrence emphasis" behaviour the [GlossaryLabel] widget
// surfaces when Beginner Mode is on: the help glyph next to a term
// label renders in `colorScheme.primary` the first time the user
// scrolls past that term, then fades to subtle on every subsequent
// appearance.
//
// Public API:
//   * `bool hasSeen(String term)` — has the user encountered this
//     glossary term in this session?
//   * `void markSeen(String term)` — record that the user has now
//     seen the term. Idempotent.
//   * `int get seenCount` — diagnostics / tests.
//
// Resets on every app start (no persistence). The "first occurrence"
// in the gap-fix description is per-session, not per-install — fresh
// session = fresh emphasis pass.
//
// ============================================================================
// WHY IT EXISTS IN THE ARCHITECTURE
// ============================================================================
// `GlossaryLabel` wraps 70+ field labels across recipe form, range
// day, ballistics, group stats, moving target, and load development.
// In Beginner Mode we want the user to *notice* a complex term once,
// not be hammered with primary-coloured glyphs every time the form
// rebuilds. A shared tracker lets every widget consult the same
// "have you seen X" flag without round-tripping through prefs (which
// would bloat with one entry per term per install).
//
// Pure in-memory ChangeNotifier — no persistence, no I/O. Provided
// once at the root via `Provider<GlossaryFirstSeenTracker>` so every
// label can `context.read<>()` it cheaply. Tests construct one
// directly (no Provider needed) since the API is purely a Set.
//
// ============================================================================
// WHY THIS IS HARDER THAN IT LOOKS
// ============================================================================
//   * **Mark on visible-to-user, not on widget build.** A label
//     that's mounted but scrolled offscreen still rebuilds; if we
//     marked seen on every build we'd consume the emphasis before
//     the user actually saw it. We rely on a post-frame callback
//     and the assumption that built widgets paint at least one
//     frame; widgets that build in the offscreen viewport of a
//     `ListView` still mark seen the moment they enter the cache,
//     which is good enough for the "draw attention once" goal —
//     stricter visibility tracking would need a `VisibilityDetector`
//     and isn't worth the dependency.
//   * **Don't notifyListeners on markSeen.** Listeners would cause
//     every label currently rendering to rebuild at the moment the
//     first label marks itself seen, which is both a perf hit AND
//     wrong (the rebuild would change the colour mid-frame in
//     pathological cases). The set is read-only-after-write from
//     each widget's perspective; new builds will pick up the new
//     state on their own.
//
// ============================================================================
// WHO CONSUMES THIS FILE
// ============================================================================
// - lib/widgets/glossary_label.dart — reads + marks per-label.
// - lib/app.dart — provides the singleton instance.
//
// ============================================================================
// SIDE EFFECTS
// ============================================================================
// None. Pure in-memory.

/// Session-scoped registry of glossary terms the user has been
/// shown at least once. Reset on app launch.
class GlossaryFirstSeenTracker {
  final Set<String> _seen = <String>{};

  /// True when [term] has been recorded as seen this session.
  bool hasSeen(String term) => _seen.contains(term);

  /// Mark [term] as seen. Idempotent. Does NOT notify listeners — see
  /// the file-header note for why.
  void markSeen(String term) {
    _seen.add(term);
  }

  /// Diagnostics / tests.
  int get seenCount => _seen.length;
}
