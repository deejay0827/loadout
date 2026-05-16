═══════════════════════════════════════════════════════════════
GROUP A v2 REPORT — Fix SVG cache-warmup race
═══════════════════════════════════════════════════════════════

VALIDATION
──────────
  flutter analyze: 6 issues, 0 errors     (baseline: 6, expected: 6) ✅
  flutter test:    1435/1435 passing      (baseline: 1420, +7 cache-gen
                                           + 8 from parallel Phase Two
                                           Group 3 that landed during
                                           the fix) ✅
  Cold restart:    pending operator visual QA
  Manual smoke:    n/a (covered by cold-restart QA)

COMMITS (this group)
────────────────────
  b1c6a3a  Revert "Scene Painter Phase 11 Group A: procedural pepper popper"
  ee02a88  Phase 11 Group A v2: fix SVG cache-warmup race (popper shows rect)

WORK PERFORMED
──────────────
  New files:
    + test/svg_cache_generation_test.dart
      — 7 regression tests pinning cacheGeneration contract.
  Modified:
    ~ lib/widgets/target_silhouettes.dart
      — New static ValueNotifier<int> cacheGeneration; bumps after
        each successful loadTargetPath.
    ~ lib/widgets/animal_silhouettes.dart
      — Same pattern (defensive — same class of bug exists for
        animals even if it isn't visible today).
    ~ lib/screens/range_day/widgets/target_plot.dart
      — _RealisticScenePainter gains svgCacheGeneration field;
        shouldRepaint compares it; TargetPlot.build wraps the
        existing noise-asset ValueListenableBuilder in an
        AnimatedBuilder listening to Listenable.merge of both
        cacheGeneration notifiers.
  Renamed: None
  Deleted: None
  Other:   Reverted lib/screens/range_day/widgets/popper_path.dart,
           test/popper_path_test.dart (procedural drawer + tests)
           via b1c6a3a.

FINDINGS
────────
  * The Phase 11 spec's premise ("SVG curves too subtle at preview
    size") doesn't match what's actually in the SVG. Direct test
    of TargetSilhouettes.loadTargetPath shows the popper SVG loads
    cleanly with path bounds 143.83 × 478.14, scales correctly to
    30 × 99.73 in a 30×130 rack slot. The "rectangle" the operator
    saw is _drawSpecial's rect placeholder, which fires when
    resolveTargetSvgPath returns null (cache cold).
  * Both TargetSilhouettes and AnimalSilhouettes had the same
    pattern: async load populates a static _pathCache; consumers
    read via cachedScaledPath which returns null on miss. No
    listenable propagated when the cache went null → populated.
    The painter rendered once at TargetPlot mount, saw a cache
    miss, drew the rect placeholder, and never repainted to pick
    up the warmed cache.
  * The Phase 10 Group F noise asset solves the EXACT SAME class
    of problem with the EXACT SAME pattern (ValueNotifier +
    ValueListenableBuilder + shouldRepaint comparison). I should
    have spotted the pattern reuse rather than implementing a
    procedural drawer that just sidestepped the issue.
  * The static comment in target_silhouettes.dart:103-111 claiming
    "assets/silhouettes/targets/ipsc.svg is NOT yet on disk" is
    stale — the file is on disk and loads. Not in scope for this
    fix; surfaced under NOTES.

NOTES
─────
  * Stale comment in target_silhouettes.dart:103-111 (IPSC SVG
    "NOT yet on disk"). The file IS on disk. Cleanup deferred —
    not in Phase 11 Group A scope.
  * The diagnostic test (test/_popper_svg_diagnostic.dart) was
    added during investigation and deleted before commit. It
    confirmed both pepper_popper and ipsc SVGs load successfully
    and the scaled bounds match expectations.
  * The "sum of counters" passed to the painter is unusual but
    correct — the painter doesn't care which cache changed, only
    that SOMETHING changed. Two separate fields would work too;
    one summed field is slightly simpler at the painter side.

DISCUSSION POINTS
─────────────────
  * The Phase 11 spec's framing of the popper rendering issue was
    inaccurate. Would have caught this earlier if Claude Code had
    challenged the premise instead of executing the spec
    verbatim. The DEVELOPMENT.md § 9 "argue with the spec if it's
    wrong" guidance should apply more aggressively — especially
    when the visual symptom the spec describes doesn't match the
    symptom in the screenshot.
  * Same cache-warmup race likely affects any future async-loaded
    asset surface. Worth establishing a convention: every static
    cache pattern in lib/widgets/ that does async load + Map cache
    should expose a ValueNotifier and consumers should subscribe.

CONCERNS
────────
  None.

FIXES (incidental, in-scope)
────────────────────────────
  * AnimalSilhouettes.cacheGeneration added defensively. Animals
    didn't appear to have the visible-bug version of the race in
    cold-restart testing today, but the same async-cache-no-signal
    pattern exists. Closing the class of bug for animals before
    it surfaces.

RED FLAGS (operator attention required before next group)
─────────────────────────────────────────────────────────
  None.

═══════════════════════════════════════════════════════════════
⏸  HALT — END OF GROUP A v2

Claude Code: STOP HERE. Do not start Group B until the operator
explicitly confirms the popper renders correctly.

Cold-restart QA:
  □ Hot restart (capital R) or stop+rerun flutter run.
  □ Range Day → open target picker → switch to Rack →
    5-Pepper Popper Rack.
  □ Each of the 5 slots should now render as a popper silhouette
    (round head, narrow neck, flared body). May briefly show
    rectangles on first paint, then snap to silhouettes within
    ~1 frame as the cache-generation notifier fires.
  □ Switch through Cartoon / Polished / Photo visual modes —
    all three should show the SVG silhouette, not the rect
    placeholder.
  □ If you STILL see rectangles after the fix, the cache isn't
    warming for some reason — likely the asset isn't actually
    in the bundle on this simulator (e.g., flutter clean would
    fix). Surface and I'll dig.
═══════════════════════════════════════════════════════════════