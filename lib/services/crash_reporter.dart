// FILE: lib/services/crash_reporter.dart
//
// ============================================================================
// WHAT THIS FILE DOES
// ============================================================================
// `CrashReporter` is the single chokepoint between LoadOut's runtime and
// Firebase Crashlytics. Every piece of the app that wants to surface a
// crash, a non-fatal error, a contextual key/value, or a breadcrumb goes
// through this service rather than calling `FirebaseCrashlytics.instance`
// directly.
//
// The service exposes four public methods:
//
//   * `initialize({ required bool enabled, required AppContext ctx })`
//     — wires `FlutterError.onError` and `PlatformDispatcher.instance.onError`
//     so framework errors and async errors flow into `recordError`. Called
//     once from `main.dart` after Firebase is up.
//   * `setKey(String key, Object value)` — adds a custom Crashlytics key
//     attached to the next crash report. Used for "current route",
//     "auth state", "active firearm id", etc.
//   * `log(String message)` — appends a breadcrumb to the local log. The
//     breadcrumb is included verbatim with the next recorded crash. Cheap
//     and silent — call it freely from screen-entry points, save handlers,
//     navigator listeners, etc.
//   * `recordError(error, stack, { reason, fatal, extras })` — records a
//     non-fatal or fatal error. Attaches every key in `extras` to the
//     report before dispatch.
//   * `recordFlutterError(FlutterErrorDetails details)` — recordError
//     for the Flutter-framework-shaped variant. Wraps
//     `FirebaseCrashlytics.instance.recordFlutterError`.
//
// All methods are no-ops when:
//   * Crashlytics is unsupported on the running platform (web / macOS).
//   * The user has opted out of crash reporting (`crashlytics_enabled`
//     pref = false).
//   * Firebase failed to initialise.
//
// `AppErrorBoundary` (the universal in-tree error wrap, see
// `lib/widgets/app_error_boundary.dart`) calls `recordFlutterError` from
// its captured `FlutterError.onError` interceptor. Async / zone errors go
// through `recordError` directly. Both paths set the same set of
// contextual custom keys before recording so the resulting report has
// everything an engineer needs to reconstruct the failure mode.
//
// ============================================================================
// WHY IT EXISTS IN THE ARCHITECTURE
// ============================================================================
// The user's directive: "we don't track everything the user does in the
// app, so when an error happens, capture every detail that helps us
// resolve the issue later." Crashlytics by itself records a stack trace
// and the device's basic facts (OS, app version, time). That's not
// enough — without breadcrumbs and custom keys we can't tell which
// screen the user was on, whether they were signed in, which firearm
// they had selected, or what the last successful action was. A
// concentrated `CrashReporter` lets every piece of the app contribute
// context once, in a privacy-aware way (no PII, no recipe contents),
// and have all of that flow into the same report when something
// breaks.
//
// Centralising also keeps `FirebaseCrashlytics.instance.*` calls out of
// every screen — they go through this service, which silently no-ops
// on unsupported platforms instead of throwing `MissingPluginException`
// on macOS / web.
//
// ============================================================================
// WHY THIS IS HARDER THAN IT LOOKS
// ============================================================================
//   * `FlutterError.onError` and `PlatformDispatcher.instance.onError`
//     are GLOBAL singletons. Whichever code installs a handler last
//     wins. We have to coordinate carefully with the per-screen
//     `RangeDayErrorBoundary` / `AppErrorBoundary` widgets, which also
//     hook `FlutterError.onError` to capture build-time errors and
//     show a friendly fallback. The pattern: each boundary captures
//     the previous handler in `initState` and forwards to it; the
//     CrashReporter installs the BASE handler that does the
//     Crashlytics record. So a crash inside a Range Day screen
//     bubbles: boundary captures → forwards to CrashReporter →
//     Crashlytics records. Disposing the boundary restores the
//     CrashReporter handler.
//
//   * Privacy boundary. Crashlytics's automatic device fingerprint
//     (OS, model, locale, region) is fine. PII is not. We never set
//     custom keys whose values include user-typed strings (recipe
//     names, firearm names, notes), Firebase UIDs (only the auth
//     STATE — anonymous / signed-in / signed-out), or anything from
//     `UserLoads` / `UserFirearms` / `RangeDaySessions` content
//     beyond row IDs. Row IDs are safe — they're per-install
//     auto-increment integers with no inherent meaning to anyone
//     outside the device.
//
//   * The opt-in flag (`crashlytics_enabled`) lives in
//     SharedPreferences. Reading it is async (and can fail).
//     `initialize` reads it once, caches the result, and uses the
//     cache for every subsequent call. A user who flips the toggle
//     in Settings during a session needs the app to re-initialise
//     (or just see the change effective on the next launch). v1
//     ships the latter — the Settings tile that flips the pref is
//     paired with a "restart the app to take effect" hint.
//
//   * `recordError` is async but most callers (UI handlers,
//     boundaries) want fire-and-forget. The method returns a
//     `Future<void>` callers can `await` if they care, but every
//     internal call is `// ignore: discarded_futures` so a slow
//     network round-trip to Crashlytics never blocks the UI.
//
// ============================================================================
// WHO CONSUMES THIS FILE
// ============================================================================
//   - lib/main.dart — calls `initialize` after Firebase is up.
//   - lib/widgets/app_error_boundary.dart — calls `recordFlutterError`
//     and `setKey` from inside the `FlutterError.onError` capture.
//   - lib/widgets/range_day_safety.dart — `RangeDayErrorBoundary` is
//     now a thin wrapper around the same machinery.
//   - lib/services/breadcrumb_navigator_observer.dart — calls `log` on
//     every route change.
//   - Any handler that wants to drop a breadcrumb or record a
//     non-fatal error.
//
// ============================================================================
// SIDE EFFECTS
// ============================================================================
//   * Mutates `FlutterError.onError` and `PlatformDispatcher.instance.onError`
//     globally during `initialize`. `RangeDayErrorBoundary` /
//     `AppErrorBoundary` widgets layer on top via
//     install-on-mount + restore-on-dispose.
//   * Writes to Firebase Crashlytics: custom keys, log lines, error
//     records. The plugin batches and uploads asynchronously when the
//     device has network.
//   * `debugPrint`s every captured error in dev builds so engineers
//     see what was reported.

import 'dart:async';
import 'dart:io' show Platform;

import 'package:firebase_crashlytics/firebase_crashlytics.dart';
import 'package:flutter/foundation.dart';

/// Lightweight bundle of app-level context the CrashReporter attaches
/// to every report it dispatches. Set once on `initialize` from
/// `main.dart` so reports include the app version, schema version,
/// and platform without each call site having to repeat them.
///
/// All fields are deliberately non-PII. The `appVersion` comes from
/// `pubspec.yaml`; the `dbSchemaVersion` is the drift schema number;
/// the `platform` and `osVersion` mirror what Crashlytics's automatic
/// device fingerprint already records (we set them as custom keys
/// anyway so they appear inline in the report's "keys" tab rather
/// than buried under "device").
class CrashReporterContext {
  const CrashReporterContext({
    required this.appVersion,
    required this.dbSchemaVersion,
    required this.platform,
    required this.osVersion,
  });

  final String appVersion;
  final int dbSchemaVersion;
  final String platform;
  final String osVersion;
}

/// Singleton chokepoint between LoadOut and Firebase Crashlytics.
/// Use `CrashReporter.instance` everywhere — `FirebaseCrashlytics`
/// should not be referenced outside this file.
class CrashReporter {
  CrashReporter._();
  static final CrashReporter instance = CrashReporter._();

  // True after `initialize` succeeds AND the user has opt-in turned on
  // AND the platform supports Crashlytics. Every public method is a
  // no-op when this is false.
  bool _enabled = false;

  /// Visible for tests; production code should call `initialize`
  /// instead. Lets a test exercise `recordError` / `setKey` /
  /// `log` without a real Firebase project on the line.
  @visibleForTesting
  void debugSetEnabled(bool enabled) {
    _enabled = enabled;
  }

  /// True when Crashlytics is wired up + the user has opt-in. Useful
  /// for surfacing a "crash reports are on" indicator in Settings →
  /// Diagnostics; the rest of the app should just call `setKey`,
  /// `log`, and `recordError` regardless and let those no-op when
  /// disabled.
  bool get isEnabled => _enabled;

  /// Wire `FlutterError.onError` and `PlatformDispatcher.instance.onError`
  /// so every framework + async error flows into Crashlytics. Sets
  /// the baseline custom keys (app version, schema version, platform).
  /// Call once from `main.dart` AFTER Firebase has initialised AND
  /// after the user's opt-in flag has been read.
  ///
  /// `enabled` reflects two booleans AND'd together: Crashlytics
  /// platform support AND the user's `crashlytics_enabled` pref.
  /// When false, this method just returns — handlers stay at whatever
  /// the framework's defaults are (a red error screen in dev, a
  /// silent log in release).
  Future<void> initialize({
    required bool enabled,
    required CrashReporterContext ctx,
  }) async {
    _enabled = enabled;
    if (!enabled) return;

    try {
      await FirebaseCrashlytics.instance
          .setCrashlyticsCollectionEnabled(true);
    } catch (e) {
      debugPrint('CrashReporter.initialize: collection toggle failed: $e');
      _enabled = false;
      return;
    }

    // Baseline keys — set once so EVERY future crash report carries
    // them inline. Crashlytics also automatically captures app +
    // device fingerprint; these are the LoadOut-specific facts that
    // help the engineer recognise a regression in a particular
    // schema version or platform.
    await _setKeyInternal('app_version', ctx.appVersion);
    await _setKeyInternal('db_schema_version', ctx.dbSchemaVersion);
    await _setKeyInternal('platform', ctx.platform);
    await _setKeyInternal('os_version', ctx.osVersion);

    // Forward Flutter-framework errors (build / layout / paint /
    // gesture). `recordFlutterError` handles the FlutterErrorDetails
    // shape natively and pulls the diagnostic context out of it.
    FlutterError.onError = (details) {
      // Always log to debug console too — engineers running the app
      // locally see the same trace they'd see without Crashlytics.
      FlutterError.dumpErrorToConsole(details);
      // Fire-and-forget the upload; don't block the next frame.
      // ignore: discarded_futures
      _safeRecordFlutterError(details);
    };

    // Forward async / isolate / plugin errors that the framework
    // doesn't see directly. Returning `true` tells the platform we've
    // handled the error so it doesn't escalate to a hard crash on
    // top of our own report.
    PlatformDispatcher.instance.onError = (error, stack) {
      debugPrint('[CrashReporter] async error: $error');
      // ignore: discarded_futures
      _safeRecordError(error, stack, fatal: true);
      return true;
    };
  }

  /// Attach a contextual custom key to the next crash report.
  /// Cheap; safe to call anywhere. Strings, numbers, booleans only —
  /// objects are converted via `toString()` by the plugin.
  ///
  /// PRIVACY: the value MUST NOT carry PII. Caller is responsible
  /// for not passing a recipe name, firearm name, user UID, or any
  /// free-form text the user typed. Use stable identifiers (route
  /// names, enum values, row IDs, booleans) instead.
  Future<void> setKey(String key, Object value) async {
    if (!_enabled) return;
    await _setKeyInternal(key, value);
  }

  Future<void> _setKeyInternal(String key, Object value) async {
    try {
      await FirebaseCrashlytics.instance.setCustomKey(key, value);
    } catch (e) {
      // Crashlytics is best-effort. Failing to set a key shouldn't
      // affect the user; debugPrint covers dev visibility.
      debugPrint('CrashReporter.setKey($key): $e');
    }
  }

  /// Append a breadcrumb to the local Crashlytics log. The next
  /// crash report includes the last several breadcrumbs verbatim —
  /// reconstruct the user's path through the app without tracking
  /// them globally.
  ///
  /// Always echoes to `debugPrint` (with a `[breadcrumb]` prefix)
  /// so engineers running the app see the same flow live.
  void log(String message) {
    debugPrint('[breadcrumb] $message');
    if (!_enabled) return;
    try {
      FirebaseCrashlytics.instance.log(message);
    } catch (_) {
      // Intentionally silent — breadcrumbs are nice-to-have. Every
      // breadcrumb call is hot path (route observer, save handlers).
    }
  }

  /// Record a non-fatal error with a stack trace. Use this from
  /// catch-blocks in handlers that recovered gracefully but want
  /// engineering to know the failure happened.
  ///
  /// `extras` are merged into the report's custom keys for THIS
  /// crash only — useful for "the file path that 404'd",
  /// "the cartridge ID that wasn't in the catalog", etc.
  Future<void> recordError(
    Object error,
    StackTrace? stack, {
    String? reason,
    bool fatal = false,
    Map<String, Object>? extras,
  }) async {
    debugPrint('[CrashReporter] ${reason ?? "error"}: $error');
    if (stack != null) {
      debugPrintStack(stackTrace: stack, label: 'CrashReporter');
    }
    if (!_enabled) return;
    if (extras != null) {
      for (final entry in extras.entries) {
        await _setKeyInternal(entry.key, entry.value);
      }
    }
    await _safeRecordError(error, stack, reason: reason, fatal: fatal);
  }

  /// Record a Flutter-framework error. Used by the boundary widgets'
  /// `FlutterError.onError` capture path. Equivalent to
  /// `recordError` but takes the framework's `FlutterErrorDetails`
  /// shape directly so the plugin's diagnostic-context formatter
  /// runs.
  Future<void> recordFlutterError(FlutterErrorDetails details) async {
    debugPrint(
      '[CrashReporter] flutter error: ${details.exceptionAsString()}',
    );
    if (!_enabled) return;
    await _safeRecordFlutterError(details);
  }

  Future<void> _safeRecordError(
    Object error,
    StackTrace? stack, {
    String? reason,
    bool fatal = false,
  }) async {
    try {
      await FirebaseCrashlytics.instance.recordError(
        error,
        stack,
        reason: reason,
        fatal: fatal,
      );
    } catch (e) {
      debugPrint('CrashReporter.recordError dispatch failed: $e');
    }
  }

  Future<void> _safeRecordFlutterError(FlutterErrorDetails details) async {
    try {
      await FirebaseCrashlytics.instance.recordFlutterError(details);
    } catch (e) {
      debugPrint('CrashReporter.recordFlutterError dispatch failed: $e');
    }
  }
}

/// True when `firebase_crashlytics` has native bindings on the
/// running platform. Mirrors `_isCrashlyticsSupported` in `main.dart`
/// — duplicated here so the service can be used in places that don't
/// import `main.dart`.
bool isCrashlyticsSupportedPlatform() {
  if (kIsWeb) return false;
  try {
    return Platform.isIOS || Platform.isAndroid;
  } catch (_) {
    // `Platform` throws on web; the kIsWeb branch above should catch
    // it but defence in depth.
    return false;
  }
}
