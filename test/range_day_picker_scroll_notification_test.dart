// FILE: test/range_day_picker_scroll_notification_test.dart
//
// ============================================================================
// WHAT THIS FILE DOES
// ============================================================================
// Regression test for the Phase 9.5 Group D dropdown-dismiss-on-scroll
// fix in `lib/screens/range_day/range_day_detail_screen.dart`.
//
// The Range Day target picker uses `Autocomplete<TargetRow>` with an
// inline `ListView.builder` as its options view. Without intervention,
// scrolling the options list dismisses the entire overlay because:
//
//   1. The outer `SingleChildScrollView` (the phone body, line 2549)
//      has `keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag`.
//   2. Per Flutter SDK, that installs a
//      `NotificationListener<ScrollUpdateNotification>` that calls
//      `FocusManager.instance.primaryFocus?.unfocus()` whenever it
//      sees a drag-update notification anywhere in its subtree.
//   3. ScrollUpdateNotifications bubble through the WIDGET-TREE
//      ancestry — independent of pointer routing. The overlay's
//      element IS a descendant of the SingleChildScrollView (the
//      Autocomplete state lives in the screen body), so every tick
//      of inner-list scrolling fires `unfocus()` and the
//      Autocomplete's focus-loss handler tears the overlay down.
//   4. Fix: wrap the inner ListView in
//      `NotificationListener<ScrollNotification>(
//         onNotification: (_) => true,
//         child: ListView.builder(...),
//       )`.
//      `true` = "handled, do not bubble" — the outer listener never
//      sees the inner list's drags.
//
// This file tests the CONTRACT — that a `NotificationListener` wrapping
// a scrollable, returning `true` from `onNotification`, stops scroll
// notifications from reaching an outer listener. It's a pure-Flutter
// invariant; if Flutter ever changed how notification bubbling worked,
// this test would catch the regression before the actual screen broke.
//
// ============================================================================
// SIDE EFFECTS
// ============================================================================
// None. Pure widget test, no DB, no Firebase, no plugins.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets(
      'NotificationListener<ScrollNotification>(onNotification: (_) => true) '
      'stops inner scroll notifications from reaching an outer listener',
      (tester) async {
    // Track notifications that reach the OUTER listener. The fix is
    // working iff this list stays empty after we drag the inner list.
    final outerSeen = <ScrollNotification>[];

    // Simulated Range Day shape:
    //   outer SingleChildScrollView (kbd dismiss simulated as
    //   NotificationListener counting drag updates)
    //     → child: tall content with a finite ListView inside it
    //       → wrapper: NotificationListener<ScrollNotification>
    //                  with onNotification: (_) => true
    //         → ListView.builder (the dropdown overlay's options list
    //           in the real screen)
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: NotificationListener<ScrollNotification>(
            onNotification: (n) {
              outerSeen.add(n);
              return false;
            },
            child: SingleChildScrollView(
              // No keyboardDismissBehavior here — we're testing the
              // bubble-stop, not the unfocus behaviour. The bubble
              // stop is the LOAD-BEARING property; if it works the
              // unfocus path can't fire.
              child: SizedBox(
                height: 1200,
                child: Align(
                  alignment: Alignment.topCenter,
                  child: SizedBox(
                    height: 300,
                    width: 240,
                    // The wrapper that fixes the bug.
                    child: NotificationListener<ScrollNotification>(
                      onNotification: (_) => true,
                      child: ListView.builder(
                        physics: const ClampingScrollPhysics(),
                        itemCount: 50,
                        itemBuilder: (context, i) =>
                            ListTile(title: Text('item $i')),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );

    // Drag the inner ListView vertically. Without the swallow wrapper,
    // ScrollUpdateNotifications would bubble through to `outerSeen`.
    await tester.drag(find.byType(ListView), const Offset(0, -120));
    await tester.pumpAndSettle();

    expect(outerSeen, isEmpty,
        reason:
            'Outer NotificationListener should never see scroll '
            'notifications from the inner ListView when the inner is '
            'wrapped in NotificationListener<ScrollNotification>(onNotification: '
            '(_) => true). If this list is non-empty, the bubble-stop '
            'contract is broken — the dropdown will dismiss on scroll '
            'in production.');
  });

  testWidgets(
      'Without the swallow wrapper, inner scroll notifications DO reach '
      'the outer listener (sanity check on the test setup)',
      (tester) async {
    // This is the BAD case — same harness, but the inner ListView is
    // NOT wrapped in a swallowing NotificationListener. The outer
    // listener should see drag notifications. This proves the
    // notification-bubbling mechanism is in effect AND that the fix's
    // swallow behaviour is meaningful.
    final outerSeen = <ScrollNotification>[];

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: NotificationListener<ScrollNotification>(
            onNotification: (n) {
              outerSeen.add(n);
              return false;
            },
            child: SingleChildScrollView(
              child: SizedBox(
                height: 1200,
                child: Align(
                  alignment: Alignment.topCenter,
                  child: SizedBox(
                    height: 300,
                    width: 240,
                    child: ListView.builder(
                      physics: const ClampingScrollPhysics(),
                      itemCount: 50,
                      itemBuilder: (context, i) =>
                          ListTile(title: Text('item $i')),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );

    await tester.drag(find.byType(ListView), const Offset(0, -120));
    await tester.pumpAndSettle();

    expect(outerSeen, isNotEmpty,
        reason:
            'Sanity check: an unwrapped inner ListView should fire '
            'ScrollNotifications that bubble to the outer listener. '
            'If this list is empty, the test harness is broken (e.g. '
            'the drag did not actually scroll the inner list, or '
            "Flutter's notification bubbling changed). The first "
            'test\'s "no bubbling" assertion is then false-positive '
            'and meaningless.');
  });
}
