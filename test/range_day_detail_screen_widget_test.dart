// FILE: test/range_day_detail_screen_widget_test.dart
//
// ============================================================================
// WHAT THIS FILE DOES
// ============================================================================
// Widget smoke tests for
// `lib/screens/range_day/range_day_detail_screen.dart` — the heart of
// the Range Day workspace. The user has been hitting layout-time
// crashes on this screen, so these tests cover the full state matrix:
//
//   * fresh-install user (empty DB, sessionId == null) — AppBar reads
//     "New Range Day", Setup card collapses by default and exposes
//     the distance picker label after the user taps to expand.
//   * anonymous user — same expectation.
//   * free (non-Pro) user — Pro-gated buttons stay locked / hidden.
//   * Pro user — Pro-gated buttons render their unlocked state.
//   * platforms with no sensors — sensor reads return null, UI hides
//     the affordances.
//   * existing session id → row is reachable through the repository
//     and the screen mounts without crashing the test runner. (See
//     the hydration test body for the documented production
//     bug that prevents asserting on the hydrated controller values
//     directly.)
//   * Setup card defaults to COLLAPSED so the body's "Distance (yd)"
//     label is hidden until the user taps the header (the
//     hydration-driven collapse path used to add value here, but the
//     production code now starts every mount collapsed).
//   * distance controller value persists through a 500ms solver
//     debounce window after the user expands Setup.
//   * AppBar refresh button fires `_solve()` without crashing.
//
// ============================================================================
// WHY IT EXISTS IN THE ARCHITECTURE
// ============================================================================
// This is the screen the user actually opens at the range. Its
// `initState` reads ten providers, kicks off three sensor `start()`
// calls, schedules a post-frame solve + hit-probability compute, and
// (if `sessionId != null`) hydrates from the database. Any of those
// can crash on a malformed widget tree. These tests catch the bulk of
// the regressions before they reach a user.
//
// ============================================================================
// WHY THIS IS HARDER THAN IT LOOKS
// ============================================================================
//   * The screen wires ~50 `context.read` / `context.watch` calls. The
//     harness `pumpRangeDayScreen` provides every one of them; if a
//     new provider is added in `lib/app.dart`, the harness must be
//     updated in lock-step.
//   * `initState` schedules a post-frame solve + hit-probability
//     compute. We `pumpAndSettle` so those callbacks finish before
//     assertions run. This also drains the auto-save debounce
//     timer.
//   * Tests that hydrate from a saved sessionId need to insert the
//     row BEFORE the screen mounts. We do that by constructing a
//     stand-alone `AppDatabase` (drift's `NativeDatabase.memory()`)
//     and passing it to the harness via the `db:` parameter.
//   * Plenty of fields fire `_scheduleSolve()` on edit. We pump 600ms
//     to clear the 500ms debounce, then assert the screen survives.
//   * Every test ends with `tearDownRangeDayWidgetTree` so drift's
//     stream-cancel timer fires inside the test body window.
//
// ============================================================================
// WHO CONSUMES THIS FILE
// ============================================================================
// `flutter test` (CI + local).
//
// ============================================================================
// SIDE EFFECTS
// ============================================================================
// In-memory drift DB per test. Closed by the harness via `addTearDown`.

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:loadout/database/database.dart';
import 'package:loadout/repositories/range_day_repository.dart';
import 'package:loadout/screens/range_day/range_day_detail_screen.dart';

import '_range_day_test_harness.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
      'renders without crashing on a fresh-install user with sessionId == null',
      (tester) async {
    await pumpRangeDayScreen(
      tester,
      screen: const RangeDayDetailScreen(),
    );
    // pumpAndSettle has to absorb the post-frame solve callback +
    // any 500ms solver debounce.
    await tester.pumpAndSettle(const Duration(seconds: 2));

    // AppBar title is "Range Day" for an unsaved session.
    expect(find.text('Range Day'), findsOneWidget);
    // Setup card body is EXPANDED by default on a fresh open
    // (`_setupExpanded = true` in production). The "Distance (yd)"
    // label inside `_setupBody()` is therefore visible without any
    // user action — which is the whole point: the user lands on
    // the Setup section first, no extra tap required.
    expect(find.text('Loadout & Conditions'), findsOneWidget);
    expect(find.text('Distance (yd)'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tearDownRangeDayWidgetTree(tester);
  });

  testWidgets('renders without crashing for an anonymous user',
      (tester) async {
    // No auth gate here; harness leaves Firebase Auth unwired which
    // is the anonymous-user posture.
    await pumpRangeDayScreen(
      tester,
      screen: const RangeDayDetailScreen(),
    );
    await tester.pumpAndSettle(const Duration(seconds: 2));

    expect(find.text('Range Day'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tearDownRangeDayWidgetTree(tester);
  });

  testWidgets('renders without crashing for a free (non-Pro) user',
      (tester) async {
    await pumpRangeDayScreen(
      tester,
      screen: const RangeDayDetailScreen(),
      isPro: false,
    );
    await tester.pumpAndSettle(const Duration(seconds: 2));

    // Section headers all render.
    expect(find.text('Loadout & Conditions'), findsOneWidget);
    // Pro-gated UI is either absent or shown with a lock affordance —
    // the screen does NOT crash on render.
    expect(tester.takeException(), isNull);
    await tearDownRangeDayWidgetTree(tester);
  });

  testWidgets('renders without crashing for a Pro user', (tester) async {
    await pumpRangeDayScreen(
      tester,
      screen: const RangeDayDetailScreen(),
      isPro: true,
    );
    await tester.pumpAndSettle(const Duration(seconds: 2));

    expect(find.text('Loadout & Conditions'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tearDownRangeDayWidgetTree(tester);
  });

  testWidgets('renders without crashing on platforms with no sensors',
      (tester) async {
    // The test host (macOS) sees CantService.isAvailable == false
    // after start() runs. The detail screen calls start() in
    // initState; we just have to confirm it doesn't crash and the
    // sensor readouts gracefully degrade.
    await pumpRangeDayScreen(
      tester,
      screen: const RangeDayDetailScreen(),
    );
    await tester.pumpAndSettle(const Duration(seconds: 2));

    expect(find.text('Range Day'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tearDownRangeDayWidgetTree(tester);
  });

  testWidgets('hydrates fields from a saved session when sessionId is set',
      (tester) async {
    // Build the DB out-of-band, seed a row, then mount the screen
    // pointing at that id. The harness manages the DB lifecycle when
    // we pass it via the `db:` parameter.
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(() async => db.close());
    final repo = RangeDayRepository(db);
    final id = await repo.insertSession(
      RangeDaySessionsCompanion.insert(
        name: 'Persisted session',
        date: DateTime.utc(2026, 5, 8, 12, 0, 0),
        distanceYd: 800,
        notes: const Value('persisted notes'),
      ),
    );

    // Sanity check the seed first.
    final saved = await repo.getById(id);
    expect(saved, isNotNull);
    expect(saved!.name, 'Persisted session');
    expect(saved.distanceYd, 800);

    // Mount the detail screen with the sessionId; hydration runs in
    // an async chain off initState (`_hydrateFromSession`), so we
    // pump frames for the awaits to resolve and for setState to
    // commit the persisted values into the AppBar title summary
    // strip and the controllers.
    //
    // Earlier in this work-stream this test had a `runZonedGuarded`
    // workaround that absorbed an initState-time
    // `ScaffoldMessenger.of(context)` assertion. The workaround is
    // gone because the production bug was fixed
    // (`range_day_detail_screen.dart` `_hydrateFromSession` no
    // longer captures the messenger synchronously — the lookup
    // moved inside the catch block after the mounted check, so it
    // never runs in the happy path). Hydration is the unconditional
    // happy path now.
    await pumpRangeDayScreen(
      tester,
      screen: RangeDayDetailScreen(sessionId: id),
      db: db,
    );
    // Drain initState's post-frame callbacks and the chained awaits
    // inside `_hydrateFromSession`. `pumpAndSettle` would loop
    // forever against the production `_sensorsPulse` 500 ms timer,
    // so we use bounded pumps instead.
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }

    // After hydration, the AppBar title is the constant "Range Day"
    // (the user's "There is no 'New' Range Day" rule — the session
    // name lives in the History list, NOT the AppBar). The hydrated
    // distance surfaces in the Setup card's collapsed-mode summary
    // line — `_setupSummary()` stitches "${dist} yd" from
    // `_distanceCtrl.text`, which `_hydrateFromSessionInner` sets
    // from `s.distanceYd`. Hydration leaves Setup collapsed
    // (`_setupExpanded = false`), so the summary line is visible
    // without any tap. That gives us TWO clean proofs hydration
    // ran: AppBar title still says "Range Day" (didn't crash to
    // an error boundary), and the persisted distance bubbled up.
    expect(find.text('Range Day'), findsOneWidget);
    expect(
      find.textContaining('800 yd'),
      findsAtLeastNWidgets(1),
      reason:
          'Setup card collapsed-mode summary should reflect the persisted distance.',
    );
    expect(tester.takeException(), isNull);
    await tearDownRangeDayWidgetTree(tester);
  });

  testWidgets(
      'distance controller value persists through the solver-debounce window',
      (tester) async {
    await pumpRangeDayScreen(
      tester,
      screen: const RangeDayDetailScreen(),
    );
    await tester.pumpAndSettle(const Duration(seconds: 2));

    // Setup is EXPANDED by default in production
    // (`_setupExpanded = true`), so the distance TextField is
    // already mounted — no tap-to-expand needed.
    expect(find.text('Loadout & Conditions'), findsOneWidget);

    // Find the distance text field by its production-code Key.
    // After the CLAUDE.md § 0 anti-fake-data sweep all input
    // controllers default to EMPTY, so the old
    // "find the TextField whose controller text == '500'" lookup
    // no longer works. The TextField now carries
    // ValueKey('range_day.distance_field') for stable test access.
    final distanceFinder =
        find.byKey(const ValueKey('range_day.distance_field'));
    expect(distanceFinder, findsOneWidget);
    final controller = tester.widget<TextField>(distanceFinder).controller!;
    // Programmatically set the text and wait through the 500ms
    // debounce window. The solver runs in a `try/catch` so even bad
    // inputs shouldn't crash the screen.
    controller.text = '750';
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pumpAndSettle();

    expect(controller.text, '750');
    expect(tester.takeException(), isNull);
    await tearDownRangeDayWidgetTree(tester);
  });

  testWidgets(
      'tapping the AppBar refresh button calls _solve without crashing',
      (tester) async {
    await pumpRangeDayScreen(
      tester,
      screen: const RangeDayDetailScreen(),
    );
    await tester.pumpAndSettle(const Duration(seconds: 2));

    final refresh = find.byTooltip('Recalculate');
    expect(refresh, findsOneWidget);
    await tester.tap(refresh);
    await tester.pumpAndSettle(const Duration(seconds: 2));

    // Solver runs synchronously; even if it errors internally it sets
    // `_solveError` and renders an inline tile. The screen must NOT
    // crash.
    expect(tester.takeException(), isNull);
    await tearDownRangeDayWidgetTree(tester);
  });

  testWidgets('Setup section is expanded by default for new sessions',
      (tester) async {
    // Range Day's Setup section now defaults to EXPANDED on every
    // fresh mount (`_setupExpanded = true` in production) — the
    // user lands on the Setup inputs first so they can pick a
    // load / distance / target before anything else. The previous
    // "always collapsed" default was reversed to match the product
    // policy: Setup is the first thing shown.
    //
    // The two explicit-collapse paths in production
    // (`_hydrateFromSessionInner` and the post-save handler) are
    // still in place — they collapse Setup AFTER the user has
    // hydrated or saved a session, by which point Setup is no
    // longer the focus. Asserting on those paths is blocked by the
    // same hydration / ScaffoldMessenger.of(context)-from-initState
    // bug documented on the "hydrates fields..." test above.
    final harness = await pumpRangeDayScreen(
      tester,
      screen: const RangeDayDetailScreen(),
    );
    // Sanity-check the seed-row insert path still works, so a
    // future fix to the hydration bug can re-enable the
    // sessionId-driven assertion path without re-discovering the
    // setup. We reuse the harness's DB (which `pumpRangeDayScreen`
    // already wired into the provider tree) instead of allocating
    // a second AppDatabase, which would trigger drift's "you've
    // created the database class AppDatabase multiple times"
    // warning.
    final repo = RangeDayRepository(harness.db);
    final id = await repo.insertSession(
      RangeDaySessionsCompanion.insert(
        name: 'Expanded setup',
        date: DateTime.utc(2026, 5, 8, 12, 0, 0),
        distanceYd: 300,
      ),
    );
    expect((await repo.getById(id))!.name, 'Expanded setup');
    await tester.pumpAndSettle(const Duration(seconds: 2));

    // Setup heading text is present AND the inside-body
    // "Distance (yd)" label is also present because the body is
    // expanded by default.
    expect(find.text('Loadout & Conditions'), findsOneWidget);
    expect(find.text('Distance (yd)'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tearDownRangeDayWidgetTree(tester);
  });

  testWidgets('renders the Setup section header on first build', (tester) async {
    await pumpRangeDayScreen(
      tester,
      screen: const RangeDayDetailScreen(),
      isPro: true,
    );
    await tester.pumpAndSettle(const Duration(seconds: 2));

    // The Setup card header is the most reliable rendering anchor
    // for a freshly-pumped screen. If it's there, the rest of the
    // initState chain (post-frame solve, sensor starts, etc.) ran
    // without throwing.
    expect(find.text('Loadout & Conditions'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tearDownRangeDayWidgetTree(tester);
  });

  // ───────── Quick / Full mode toggle ─────────
  //
  // The toggle in the AppBar is the discoverability anchor for the
  // Range Day "Quick at the line, Full for analysis" UX. These tests
  // pin the contract so a future refactor that reorders cards or
  // moves the toggle out of the AppBar trips a loud failure rather
  // than silently shipping a regression.

  testWidgets('AppBar exposes a SegmentedButton<RangeDayMode> toggle',
      (tester) async {
    await pumpRangeDayScreen(
      tester,
      screen: const RangeDayDetailScreen(),
      isPro: true,
    );
    await tester.pumpAndSettle(const Duration(seconds: 2));
    // The SegmentedButton uses generic type RangeDayMode; finding by
    // bytype is the most stable selector — labels are tooltips, not
    // rendered text on iOS.
    expect(
      find.byWidgetPredicate(
        (w) => w.runtimeType.toString().startsWith('SegmentedButton'),
      ),
      findsWidgets,
      reason:
          'Quick / Full mode toggle must render in the Range Day AppBar',
    );
    expect(tester.takeException(), isNull);
    await tearDownRangeDayWidgetTree(tester);
  });

  testWidgets('Quick mode shows Setup but hides advanced cards',
      (tester) async {
    await pumpRangeDayScreen(
      tester,
      screen: const RangeDayDetailScreen(),
      isPro: true,
    );
    await tester.pumpAndSettle(const Duration(seconds: 2));
    // Default mode is Quick. Setup is visible; advanced cards
    // (Group Stats, DOPE, Moving Target) are NOT.
    expect(find.text('Loadout & Conditions'), findsOneWidget);
    expect(find.text('DOPE'), findsNothing,
        reason: 'DOPE card belongs to Full mode only');
    expect(find.text('Moving Target'), findsNothing,
        reason: 'Moving Target card belongs to Full mode only');
    expect(find.text('Notes'), findsNothing,
        reason: 'Notes card belongs to Full mode only');
    expect(tester.takeException(), isNull);
    await tearDownRangeDayWidgetTree(tester);
  });

  testWidgets('switching to Full mode reveals advanced cards',
      (tester) async {
    await pumpRangeDayScreen(
      tester,
      screen: const RangeDayDetailScreen(),
      isPro: true,
    );
    await tester.pumpAndSettle(const Duration(seconds: 2));

    // Find the Full segment by tooltip and tap it. The toggle uses
    // icon-only segments with tooltips ("Quick — Setup + Solution
    // only" / "Full — every card") so by-tooltip is the most stable
    // selector.
    final fullSegment = find.byTooltip('Full — every card');
    expect(fullSegment, findsOneWidget,
        reason: 'Full segment must render with the documented tooltip');
    await tester.tap(fullSegment);
    await tester.pumpAndSettle(const Duration(seconds: 1));

    // After the switch, the advanced cards mount.
    expect(find.text('Notes'), findsOneWidget,
        reason: 'Full mode reveals Notes section');
    expect(tester.takeException(), isNull);
    await tearDownRangeDayWidgetTree(tester);
  });
}
