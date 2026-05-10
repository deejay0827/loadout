// FILE: lib/widgets/range_day_safety.dart
//
// ============================================================================
// WHAT THIS FILE DOES
// ============================================================================
// Shared "soft-failure" helpers used by every Range Day screen
// (`range_day_screen.dart`, `range_day_detail_screen.dart`,
// `scope_view_screen.dart`, `hit_probability_map_screen.dart`,
// `bc_truing_screen.dart`, `scope_tracking_screen.dart`). Three exports:
//
//   * [RangeDayErrorBoundary] — a `StatefulWidget` that hooks
//     `FlutterError.onError` for the duration of its subtree's lifetime.
//     If a synchronous render-time exception fires inside `child`, the
//     boundary swaps in a friendly error card with "Reload" and "Back"
//     buttons instead of letting the red error screen reach the user.
//     The previous global handler is preserved and forwarded to so
//     Crashlytics, debugPrint, etc. still get the report.
//   * [safeAsync] — a top-level helper that wraps an async callback,
//     catches every exception, surfaces a [SnackBar] with the supplied
//     `userMessage`, and returns `null` on failure. Use it whenever a
//     Range Day handler touches I/O, plugins, or platform code.
//   * [asyncErrorSnackBar] — the canonical error [SnackBar] (floating,
//     4 seconds, "Dismiss" action) used by [safeAsync] and by inline
//     try/catch blocks that don't fit the `safeAsync` shape.
//
// ============================================================================
// WHY IT EXISTS IN THE ARCHITECTURE
// ============================================================================
// Range Day is the single most mode-shifty surface in the app — outdoors,
// gloved hands, sun glare, BLE devices flapping in and out, sensor
// services dropping samples, weather APIs timing out, .fit-file parses
// hitting unexpected data. The user has been clear: a crash on this
// screen is unacceptable. Centralizing the fallback patterns here keeps
// every Range Day screen's body code clean while guaranteeing a uniform
// "snackbar / inline error tile / friendly fallback" UX.
//
// ============================================================================
// WHY THIS IS HARDER THAN IT LOOKS
// ============================================================================
// * `FlutterError.onError` is a global. If the boundary ever forgets to
//   restore the previous handler in `dispose()`, the next screen
//   (post-pop) still has our handler installed and will silently swallow
//   future render errors. We capture the previous handler in
//   `initState`, install our wrapper, and restore the previous handler
//   in `dispose` — even if the boundary tree never fired.
// * The boundary handles RENDER-TIME errors (from inside `build`), not
//   uncaught async errors. Async errors come from event handlers, which
//   is what `safeAsync` covers. Both pieces are needed for full
//   coverage.
// * `setState` after a thrown error must NOT throw again. The error
//   card is built from constant primitives so a paint failure inside
//   the fallback would bubble up through the parent (which we cannot
//   protect against here — but the parent of a Range Day screen is the
//   Navigator/MaterialApp, which Flutter already guards).
// * `safeAsync` deliberately allows the optional `mounted` callback so
//   callers from `StatefulWidget` can pass `() => mounted` and the
//   helper skips the SnackBar after a navigation pop instead of
//   crashing on a disposed `ScaffoldMessenger`.
//
// ============================================================================
// WHO CONSUMES THIS FILE
// ============================================================================
// - lib/screens/range_day/range_day_screen.dart
// - lib/screens/range_day/range_day_detail_screen.dart
// - lib/screens/range_day/scope_view_screen.dart
// - lib/screens/range_day/hit_probability_map_screen.dart
// - lib/screens/range_day/bc_truing_screen.dart
// - lib/screens/range_day/scope_tracking_screen.dart
//
// ============================================================================
// SIDE EFFECTS
// ============================================================================
// * Mutates `FlutterError.onError` while a `RangeDayErrorBoundary` is
//   mounted (restored on dispose).
// * Shows `SnackBar`s via the nearest `ScaffoldMessenger`.
// * `debugPrint`s the underlying error + stack trace so engineers can
//   see what was swallowed in dev builds.

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

/// Wraps a Range Day subtree so any render-time exception is replaced by
/// a friendly error card instead of Flutter's red error screen.
///
/// Place it directly inside the `Scaffold.body` for the screen — it
/// fills its parent so the fallback card stretches to the available
/// area.
class RangeDayErrorBoundary extends StatefulWidget {
  const RangeDayErrorBoundary({
    super.key,
    required this.child,
    this.label,
  });

  final Widget child;

  /// Optional friendly noun for the "Something went wrong on this
  /// {label}" copy. Defaults to "screen".
  final String? label;

  @override
  State<RangeDayErrorBoundary> createState() => _RangeDayErrorBoundaryState();
}

class _RangeDayErrorBoundaryState extends State<RangeDayErrorBoundary> {
  FlutterExceptionHandler? _previousHandler;
  FlutterErrorDetails? _caught;
  // Bumped on "Reload" so the child subtree gets a fresh element key —
  // any stale state that contributed to the failure gets thrown away.
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
    // Forward to the previous handler first — Crashlytics, debugPrint,
    // etc. still need to see what happened.
    _previousHandler?.call(details);
    debugPrint(
      '[RangeDayErrorBoundary] caught: ${details.exceptionAsString()}',
    );
    if (!mounted) return;
    // Schedule the rebuild after the current frame so we don't try to
    // rebuild while Flutter is mid-paint.
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

  @override
  Widget build(BuildContext context) {
    if (_caught != null) {
      return _ErrorCard(
        label: widget.label ?? 'screen',
        details: _caught!,
        onReload: _reload,
        onBack: () {
          if (Navigator.of(context).canPop()) {
            Navigator.of(context).pop();
          } else {
            _reload();
          }
        },
      );
    }
    // KeyedSubtree forces a fresh element subtree on reload so cached
    // state inside the child doesn't reproduce the same crash.
    return KeyedSubtree(
      key: ValueKey('range_day_boundary_$_epoch'),
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
    return Center(
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
              'Your data is safe. Try reloading the screen, or back out '
              'and try again.',
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
    );
  }
}

/// Run [body] and surface any thrown exception as a [SnackBar] with
/// [userMessage]. Returns the body's result on success, or `null` on
/// failure.
///
/// `mounted` is an optional callback the caller can pass from a
/// `StatefulWidget` (`() => mounted`) so the SnackBar is skipped if the
/// widget popped before the future resolved.
Future<T?> safeAsync<T>(
  BuildContext context, {
  required Future<T> Function() body,
  required String userMessage,
  bool Function()? mounted,
}) async {
  try {
    return await body();
  } catch (error, stack) {
    debugPrint('[safeAsync] $userMessage → $error');
    debugPrintStack(stackTrace: stack, label: 'safeAsync');
    final stillMounted = mounted?.call() ?? true;
    if (!stillMounted) return null;
    if (!context.mounted) return null;
    ScaffoldMessenger.of(context).showSnackBar(
      asyncErrorSnackBar(context, userMessage, error),
    );
    return null;
  }
}

/// Canonical error [SnackBar] for Range Day soft-failure paths. Floating
/// behavior, four-second duration, "Dismiss" action.
SnackBar asyncErrorSnackBar(
  BuildContext context,
  String userMessage,
  Object error,
) {
  return SnackBar(
    behavior: SnackBarBehavior.floating,
    duration: const Duration(seconds: 4),
    content: Text(
      userMessage,
      maxLines: 3,
      overflow: TextOverflow.ellipsis,
    ),
    action: SnackBarAction(
      label: 'Dismiss',
      onPressed: () {
        ScaffoldMessenger.of(context).hideCurrentSnackBar();
      },
    ),
  );
}

/// Inline error tile for use inside a `FutureBuilder` / `StreamBuilder`
/// `snapshot.hasError` branch. Mirrors the empty-state visual weight so
/// it doesn't overwhelm the surrounding card layout.
///
/// Pass `onRetry` to surface a "Try again" button (e.g. to swap the
/// underlying future on the parent's setState).
class RangeDayInlineError extends StatelessWidget {
  const RangeDayInlineError({
    super.key,
    required this.message,
    this.onRetry,
  });

  final String message;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: theme.colorScheme.errorContainer.withValues(alpha: 0.4),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        children: [
          Icon(
            Icons.error_outline,
            size: 18,
            color: theme.colorScheme.error,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              message,
              style: theme.textTheme.bodySmall,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          if (onRetry != null)
            TextButton(
              onPressed: onRetry,
              child: const Text('Retry'),
            ),
        ],
      ),
    );
  }
}
