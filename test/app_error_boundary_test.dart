// FILE: test/app_error_boundary_test.dart
//
// Widget tests for `lib/widgets/app_error_boundary.dart`. Covers:
//
//   * Boundary catches a render-time exception thrown from inside
//     its child and renders the fallback card.
//   * "Reload" rebuilds the child subtree (epoch bumps).
//   * Disabled CrashReporter doesn't break anything (the disabled
//     no-op path is the default in widget tests anyway).
//   * `label` propagates to the fallback copy.
//
// We don't try to verify Crashlytics-side behaviour — the
// CrashReporter is in its disabled default state during widget
// tests, so the boundary's `recordFlutterError` calls become
// no-ops. The boundary's UX behaviour (catch + fallback + reload)
// is what the tests exercise.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:loadout/services/crash_reporter.dart';
import 'package:loadout/widgets/app_error_boundary.dart';

void main() {
  setUp(() {
    CrashReporter.instance.debugSetEnabled(false);
  });

  Widget wrap(Widget child) {
    return MaterialApp(
      home: Scaffold(
        body: child,
      ),
    );
  }

  testWidgets(
    'renders child when no error',
    (tester) async {
      await tester.pumpWidget(wrap(
        const AppErrorBoundary(
          label: 'unit-test-screen',
          child: Text('happy path'),
        ),
      ));
      expect(find.text('happy path'), findsOneWidget);
      expect(find.text('Something went wrong on this unit-test-screen'),
          findsNothing);
    },
  );

  testWidgets(
    'catches a render-time exception and shows the fallback',
    (tester) async {
      // A widget whose build method throws.
      final boundary = AppErrorBoundary(
        label: 'unit-test-screen',
        child: Builder(builder: (_) => throw StateError('boom from build')),
      );

      // The build throw routes through `FlutterError.onError` —
      // pump-and-settle so the post-frame setState fires.
      await tester.pumpWidget(wrap(boundary));
      // The framework needs an extra frame for the boundary's
      // post-frame setState to land.
      await tester.pump();
      await tester.pump();

      // Fallback copy is rendered.
      expect(find.text('Something went wrong on this unit-test-screen'),
          findsOneWidget);
      expect(find.byIcon(Icons.error_outline), findsOneWidget);
      // Both action buttons are present.
      expect(find.text('Back'), findsOneWidget);
      expect(find.text('Reload'), findsOneWidget);

      // The thrown exception itself bubbled up through Flutter's
      // standard error channel — `tester.takeException()` clears
      // the queued error so the test framework doesn't fail the
      // test on top of our captured failure.
      final captured = tester.takeException();
      expect(captured, isA<StateError>());
    },
  );

  testWidgets(
    'label defaults to "screen" when not provided',
    (tester) async {
      final boundary = AppErrorBoundary(
        child: Builder(builder: (_) => throw StateError('boom')),
      );
      await tester.pumpWidget(wrap(boundary));
      await tester.pump();
      await tester.pump();

      expect(find.text('Something went wrong on this screen'), findsOneWidget);
      tester.takeException();
    },
  );

  testWidgets(
    'Reload bumps epoch and rebuilds child subtree',
    (tester) async {
      // We use a stateful child that throws on the first build only.
      // After the boundary catches and the user taps Reload, the
      // child is reconstructed with a fresh element subtree (per the
      // KeyedSubtree epoch) so its build runs again — this time
      // succeeding.
      final boundary = AppErrorBoundary(
        label: 'unit-test-screen',
        child: const _ThrowOnceWidget(),
      );
      _ThrowOnceWidget.shouldThrow = true;

      await tester.pumpWidget(wrap(boundary));
      await tester.pump();
      await tester.pump();

      expect(find.text('Something went wrong on this unit-test-screen'),
          findsOneWidget);
      tester.takeException();

      // Flip the static so the next build won't throw, then tap
      // Reload.
      _ThrowOnceWidget.shouldThrow = false;
      await tester.tap(find.text('Reload'));
      await tester.pumpAndSettle();

      // Fallback gone, the recovered child renders.
      expect(find.text('happy after reload'), findsOneWidget);
      expect(find.text('Something went wrong on this unit-test-screen'),
          findsNothing);
    },
  );
}

/// Throws on first build (controlled by static flag), renders
/// "happy after reload" on subsequent builds. Used to exercise the
/// boundary's reload flow.
class _ThrowOnceWidget extends StatelessWidget {
  const _ThrowOnceWidget();

  // Static state — the test flips it between the initial build and
  // the post-reload build.
  static bool shouldThrow = false;

  @override
  Widget build(BuildContext context) {
    if (shouldThrow) {
      throw StateError('intentional first-build failure');
    }
    return const Text('happy after reload');
  }
}
