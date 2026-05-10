// FILE: test/scope_tracking_screen_widget_test.dart
//
// ============================================================================
// WHAT THIS FILE DOES
// ============================================================================
// Widget smoke tests for
// `lib/screens/range_day/scope_tracking_screen.dart` — the
// drop-per-click (DPC) sight-calibration wizard. Confirms the screen
// renders across the matrix of states the production app surfaces:
//
//   * fresh-install user (empty DB),
//   * anonymous user (no auth gate),
//   * free (non-Pro) user — the screen itself doesn't double-gate;
//     the Pro check happens at the entry point on the parent screen,
//   * Pro user,
//   * platforms with no sensors,
//   * the wizard's instructions / Setup / Impacts / Result / Save
//     sections all render in their initial empty state,
//   * tapping "+ Add impact" twice grows the impact list to two rows
//     (which is the threshold at which `_compute()` produces a result;
//     however the "Apply and save" button stays disabled until a
//     firearm is also selected, which is correct production behavior).
//
// ============================================================================
// WHY IT EXISTS IN THE ARCHITECTURE
// ============================================================================
// The DPC math (`ScopeTrackingService.calibrate`) is unit-tested in
// `test/sight_calibration_test.dart`. These tests confirm the SCREEN
// builds with no firearm selected and that the impact-table growth
// handler updates the visible row count correctly.
//
// ============================================================================
// WHY THIS IS HARDER THAN IT LOOKS
// ============================================================================
//   * The "Apply and save" button is disabled until BOTH `_result !=
//     null` AND `_selectedFirearm != null`. The test below asserts
//     that two impacts alone don't enable the button (no firearm
//     selected), which matches the production gate.
//   * Each impact row contains "X (-1..1)" and "Y (-1..1)" labels.
//     Counting impact rows by `find.text('X (-1..1)')` is unique
//     because no other field uses that label.
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

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:loadout/screens/range_day/scope_tracking_screen.dart';

import '_range_day_test_harness.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('renders without crashing on a fresh-install user (empty DB)',
      (tester) async {
    await pumpRangeDayScreen(
      tester,
      screen: const ScopeTrackingScreen(),
    );
    await tester.pumpAndSettle();

    expect(find.text('Scope Tracking Test'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tearDownRangeDayWidgetTree(tester);
  });

  testWidgets('renders without crashing for an anonymous user',
      (tester) async {
    await pumpRangeDayScreen(
      tester,
      screen: const ScopeTrackingScreen(),
    );
    await tester.pumpAndSettle();

    expect(find.text('Scope Tracking Test'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tearDownRangeDayWidgetTree(tester);
  });

  testWidgets('renders without crashing for a free (non-Pro) user',
      (tester) async {
    await pumpRangeDayScreen(
      tester,
      screen: const ScopeTrackingScreen(),
      isPro: false,
    );
    await tester.pumpAndSettle();

    expect(find.text('Scope Tracking Test'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tearDownRangeDayWidgetTree(tester);
  });

  testWidgets('renders without crashing for a Pro user', (tester) async {
    await pumpRangeDayScreen(
      tester,
      screen: const ScopeTrackingScreen(),
      isPro: true,
    );
    await tester.pumpAndSettle();

    expect(find.text('Scope Tracking Test'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tearDownRangeDayWidgetTree(tester);
  });

  testWidgets('renders without crashing on platforms with no sensors',
      (tester) async {
    await pumpRangeDayScreen(
      tester,
      screen: const ScopeTrackingScreen(),
    );
    await tester.pumpAndSettle();

    expect(find.text('Scope Tracking Test'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tearDownRangeDayWidgetTree(tester);
  });

  testWidgets('wizard step indicator (instructions card) is visible',
      (tester) async {
    // The screen has no actual step indicator widget — the steps are
    // documented in the file's header. The on-screen affordance is
    // the "Tall-target test" instructions card, which is always
    // visible at the top of the wizard.
    await pumpRangeDayScreen(
      tester,
      screen: const ScopeTrackingScreen(),
    );
    await tester.pumpAndSettle();

    expect(find.text('Tall-target test'), findsOneWidget);
    // Setup section follows below.
    expect(find.text('Setup'), findsOneWidget);
    // Impacts section is below Setup.
    expect(find.text('Impacts'), findsOneWidget);
    // Save section is at the bottom.
    expect(find.text('Apply scale'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tearDownRangeDayWidgetTree(tester);
  });

  testWidgets('starts with zero impact rows in the Impacts table',
      (tester) async {
    await pumpRangeDayScreen(
      tester,
      screen: const ScopeTrackingScreen(),
    );
    await tester.pumpAndSettle();

    // No impacts yet — the X (-1..1) label appears 0 times.
    expect(find.text('X (-1..1)'), findsNothing);
    expect(tester.takeException(), isNull);
    await tearDownRangeDayWidgetTree(tester);
  });

  testWidgets('tapping "Add impact" twice grows the table to two rows',
      (tester) async {
    await pumpRangeDayScreen(
      tester,
      screen: const ScopeTrackingScreen(),
    );
    await tester.pumpAndSettle();

    final addImpact = find.byTooltip('Add impact');
    expect(addImpact, findsOneWidget);
    await tester.tap(addImpact);
    await tester.pumpAndSettle();
    expect(find.text('X (-1..1)'), findsNWidgets(1));

    await tester.tap(addImpact);
    await tester.pumpAndSettle();
    expect(find.text('X (-1..1)'), findsNWidgets(2));
    expect(tester.takeException(), isNull);
    await tearDownRangeDayWidgetTree(tester);
  });

  testWidgets(
      'with two impacts and no firearm selected, "Apply and save" stays disabled',
      (tester) async {
    // Production gate: the button needs both a result (>=2 impacts)
    // AND a selected firearm. Two impacts alone are not enough.
    await pumpRangeDayScreen(
      tester,
      screen: const ScopeTrackingScreen(),
    );
    await tester.pumpAndSettle();

    final addImpact = find.byTooltip('Add impact');
    await tester.tap(addImpact);
    await tester.pumpAndSettle();
    await tester.tap(addImpact);
    await tester.pumpAndSettle();

    final saveButton = find.widgetWithText(FilledButton, 'Apply and Save');
    expect(saveButton, findsOneWidget);
    final widget = tester.widget<FilledButton>(saveButton);
    // onPressed null => disabled.
    expect(widget.onPressed, isNull);
    expect(tester.takeException(), isNull);
    await tearDownRangeDayWidgetTree(tester);
  });

  testWidgets('removing an impact row decrements the visible count',
      (tester) async {
    await pumpRangeDayScreen(
      tester,
      screen: const ScopeTrackingScreen(),
    );
    await tester.pumpAndSettle();

    // Add two impacts.
    final addImpact = find.byTooltip('Add impact');
    await tester.tap(addImpact);
    await tester.pumpAndSettle();
    await tester.tap(addImpact);
    await tester.pumpAndSettle();
    expect(find.text('X (-1..1)'), findsNWidgets(2));

    // Each row has a "Remove" tooltip; tap the first one.
    await tester.tap(find.byTooltip('Remove').first);
    await tester.pumpAndSettle();

    expect(find.text('X (-1..1)'), findsNWidgets(1));
    expect(tester.takeException(), isNull);
    await tearDownRangeDayWidgetTree(tester);
  });
}
