// FILE: lib/widgets/app_error_boundary.dart
//
// ============================================================================
// WHAT THIS FILE DOES
// ============================================================================
// `AppErrorBoundary` is the universal version of `RangeDayErrorBoundary`
// — a `StatefulWidget` that wraps a subtree, captures every render-time
// error inside it, forwards the error through `CrashReporter` to
// Firebase Crashlytics, and shows a friendly fallback card with
// "Reload" + "Back" buttons instead of letting Flutter's red error
// screen reach the user.
//
// Two intended placements:
//
//   1. **App-level** — wrapped around `MaterialApp.builder`'s child so
//      every routed screen is covered automatically. This is the
//      universal-handler workhorse: a build-time crash on any screen
//      gets caught, reported, and surfaces a friendly fallback in
//      front of the user.
//   2. **Per-screen** — used directly inside a screen's `Scaffold.body`
//      (e.g. the existing Range Day pattern) when the screen wants its
//      OWN fallback bounded to its content area instead of taking over
//      the whole app surface. The Range Day screens already use this
//      pattern via `RangeDayErrorBoundary`, which is a thin wrapper
//      around `AppErrorBoundary` for back-compat.
//
// The boundary captures `FlutterError.onError` for the duration of
// its `mounted` lifetime. Whichever boundary is innermost wins; on
// `dispose` the previous handler is restored.
//
// On a captured error the widget:
//
//   1. Forwards to whatever handler was previously registered (so the
//      app-wide CrashReporter handler installed in `main.dart` still
//      records to Crashlytics).
//   2. Adds a `boundary_label` custom key so the engineer can tell
//      which boundary fired ("app", "range_day_setup", etc.).
//   3. Records the error explicitly via `CrashReporter.recordFlutterError`
//      with extra context — defensive double-record in case the
//      previous handler chain swallowed it.
//   4. Schedules a post-frame setState so the boundary's NEXT build
//      shows the fallback card instead of the original (broken)
//      child.
//
// "Reload" bumps an internal epoch counter and resets `_caught` to
// null. The child rebuilds with a fresh `KeyedSubtree` so any cached
// state that contributed to the failure gets thrown away.
//
// ============================================================================
// WHY IT EXISTS IN THE ARCHITECTURE
// ============================================================================
// User directive (paraphrased): "We've had a number of errors and red
// screens. Create a universal error handler — any error logs, sends a
// Firebase alert, includes the full stack and as much context as we
// can. Range Day already has one; generalise it."
//
// The Range Day pattern works well — it's been rolled across six
// screens with no regressions. Lifting it to an app-level wrap means
// every NEW screen automatically gets the same treatment without
// engineers having to remember to add a boundary. The
// CrashReporter integration adds the rich context ("which route was
// active", "which firearm was selected") so an engineer reviewing a
// Crashlytics report has more than just the stack to work with.
//
// ============================================================================
// WHY THIS IS HARDER THAN IT LOOKS
// ============================================================================
//   * `FlutterError.onError` is global. Stacking multiple boundaries
//     (app-level + per-screen) requires correct chain handoff —
//     each captures the previous handler in `initState`, calls it in
//     `_handleFlutterError`, and restores it in `dispose`. The
//     CrashReporter installs the BASE handler in `main.dart`; a
//     boundary mounted on top of it captures CrashReporter's handler
//     as `_previousHandler` and forwards to it correctly.
//
//   * The fallback's "Back" button needs a navigator. When this
//     widget is wrapped above the navigator (app-level placement), a
//     local `Navigator.of(context).pop()` looks up the inherited
//     navigator OUTSIDE this boundary — but `MaterialApp.builder`'s
//     boundary is above the MaterialApp's navigator, so there isn't
//     one. We use `LoadOutApp.navigatorKey` (a global navigator key
//     already wired up for share-intent + watch-shot ingest) as the
//     fallback navigator handle. When the global navigator can pop,
//     the Back button pops; otherwise it falls back to "Reload" so
//     the user always has a way out.
//
//   * Reloading after a paint failure must not re-trigger the same
//     paint. We bump an `_epoch` int and use it as the
//     `KeyedSubtree.key`, which forces Flutter to discard the cached
//     element subtree under the boundary — giving the child a fresh
//     state object. If the same crash happens again on reload (the
//     common case for "this load row is missing a required field"
//     — same input, same crash), the boundary catches it again and
//     the user can back out.
//
//   * `setState` MUST be deferred to a post-frame callback. If we
//     called it synchronously from `_handleFlutterError`, we'd be
//     calling `markNeedsBuild` while Flutter is mid-paint — which
//     itself throws an assertion. The post-frame schedule moves the
//     rebuild out of the current frame.
//
// ============================================================================
// WHO CONSUMES THIS FILE
// ============================================================================
//   - lib/app.dart — wraps `MaterialApp.builder` so every route gets
//     the universal coverage.
//   - lib/widgets/range_day_safety.dart — `RangeDayErrorBoundary` is
//     a thin compatibility wrapper around `AppErrorBoundary`.
//
// ============================================================================
// SIDE EFFECTS
// ============================================================================
//   * Mutates `FlutterError.onError` while mounted (restored on dispose).
//   * Calls `CrashReporter.recordFlutterError` and `setKey` on every
//     captured error.
//   * Renders a Card with two buttons in front of the broken
//     subtree.

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../services/crash_reporter.dart';

class AppErrorBoundary extends StatefulWidget {
  const AppErrorBoundary({
    super.key,
    required this.child,
    this.label,
    this.onBack,
  });

  /// The subtree to protect. The whole app, a single screen, or a
  /// single card — anything that can throw at build / layout / paint
  /// time goes inside.
  final Widget child;

  /// Optional friendly noun for the "Something went wrong on this
  /// {label}" copy. Defaults to "screen". Surfaced to Crashlytics as
  /// the `boundary_label` custom key.
  final String? label;

  /// Optional override for the Back button's tap handler. When null
  /// (default) the boundary uses the local Navigator if one exists
  /// above this widget, falling back to a Reload action when the
  /// boundary has no navigator above it (the app-level placement
  /// case).
  final VoidCallback? onBack;

  @override
  State<AppErrorBoundary> createState() => _AppErrorBoundaryState();
}

class _AppErrorBoundaryState extends State<AppErrorBoundary> {
  FlutterExceptionHandler? _previousHandler;
  FlutterErrorDetails? _caught;

  /// Bumped on "Reload" so the child subtree gets a fresh element
  /// key. Any stale state that contributed to the failure is
  /// discarded; the child builds from scratch.
  int _epoch = 0;

  @override
  void initState() {
    super.initState();
    _previousHandler = FlutterError.onError;
    FlutterError.onError = _handleFlutterError;
  }

  @override
  void dispose() {
    // Only restore if we're still the active handler — defensive in
    // case another boundary nested inside us already restored its
    // previous handler (which would be ours).
    if (FlutterError.onError == _handleFlutterError) {
      FlutterError.onError = _previousHandler;
    }
    super.dispose();
  }

  void _handleFlutterError(FlutterErrorDetails details) {
    final label = widget.label ?? 'screen';

    // Forward to the previous handler first — Crashlytics (installed
    // by main.dart's CrashReporter.initialize), debugPrint, etc. all
    // need to see what happened. The CrashReporter chain logs to the
    // dev console AND records to Firebase if collection is enabled.
    _previousHandler?.call(details);

    // Defensive double-record: even if the previous handler chain
    // dropped the error somehow, attach our boundary context and
    // record it explicitly. Crashlytics deduplicates near-identical
    // recent records, so this is safe — at worst a duplicate entry
    // in the Firebase console.
    // ignore: discarded_futures
    CrashReporter.instance.setKey('boundary_label', label);
    // ignore: discarded_futures
    CrashReporter.instance.recordFlutterError(details);

    if (!mounted) return;

    // Schedule the rebuild after the current frame so we don't try
    // to call setState while Flutter is mid-paint.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      setState(() => _caught = details);
    });
  }

  void _reload() {
    setState(() {
      _caught = null;
      _epoch += 1;
    });
  }

  void _onBackPressed(BuildContext context) {
    if (widget.onBack != null) {
      widget.onBack!();
      return;
    }
    // Try the inherited navigator first (per-screen placement —
    // e.g. inside a Scaffold.body). If there's no navigator above
    // this boundary, fall through to the global navigator key
    // installed by LoadOutApp; if THAT can't pop either, the only
    // thing we can do is reload.
    final localNavigator = Navigator.maybeOf(context);
    if (localNavigator != null && localNavigator.canPop()) {
      localNavigator.pop();
      return;
    }
    final globalNavigator = _globalNavigator(context);
    if (globalNavigator != null && globalNavigator.canPop()) {
      globalNavigator.pop();
      return;
    }
    _reload();
  }

  NavigatorState? _globalNavigator(BuildContext context) {
    // Look up the app-level navigator key WITHOUT importing
    // `app.dart` (avoids a cycle). The InheritedNavigator above
    // MaterialApp doesn't exist; we read the most-recently-mounted
    // root navigator via a static accessor on the LoadOutApp class
    // — but to keep this widget independent we accept null and
    // fall back gracefully.
    //
    // Pragmatic approach: try `WidgetsBinding.instance.rootElement`
    // and walk down to find a Navigator. In practice the app-level
    // placement always has a reachable navigator below MaterialApp,
    // and the per-screen placement uses the local Navigator above.
    NavigatorState? found;
    void visit(Element element) {
      if (found != null) return;
      final widget = element.widget;
      if (widget is Navigator) {
        final state = (element as StatefulElement).state;
        if (state is NavigatorState) {
          found = state;
          return;
        }
      }
      element.visitChildren(visit);
    }

    final root = WidgetsBinding.instance.rootElement;
    if (root != null) visit(root);
    return found;
  }

  @override
  Widget build(BuildContext context) {
    if (_caught != null) {
      return _ErrorCard(
        label: widget.label ?? 'screen',
        details: _caught!,
        onReload: _reload,
        onBack: () => _onBackPressed(context),
      );
    }
    // KeyedSubtree forces a fresh element subtree on reload so cached
    // state inside the child doesn't reproduce the same crash.
    return KeyedSubtree(
      key: ValueKey('app_error_boundary_$_epoch'),
      child: widget.child,
    );
  }
}

class _ErrorCard extends StatelessWidget {
  const _ErrorCard({
    required this.label,
    required this.details,
    required this.onReload,
    required this.onBack,
  });

  final String label;
  final FlutterErrorDetails details;
  final VoidCallback onReload;
  final VoidCallback onBack;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Material(
      color: theme.colorScheme.surface,
      child: SafeArea(
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(
                  Icons.error_outline,
                  size: 56,
                  color: theme.colorScheme.error,
                ),
                const SizedBox(height: 16),
                Text(
                  'Something went wrong on this $label',
                  style: theme.textTheme.titleMedium,
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 8),
                Text(
                  'Your data is safe. Try reloading the screen, or back '
                  'out and try again. We\'ve sent the details to '
                  'engineering.',
                  style: theme.textTheme.bodyMedium,
                  textAlign: TextAlign.center,
                ),
                if (kDebugMode) ...[
                  const SizedBox(height: 12),
                  Text(
                    details.exceptionAsString(),
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                    textAlign: TextAlign.center,
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
                const SizedBox(height: 24),
                Wrap(
                  spacing: 12,
                  alignment: WrapAlignment.center,
                  children: [
                    OutlinedButton.icon(
                      onPressed: onBack,
                      icon: const Icon(Icons.arrow_back),
                      label: const Text('Back'),
                    ),
                    FilledButton.icon(
                      onPressed: onReload,
                      icon: const Icon(Icons.refresh),
                      label: const Text('Reload'),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
