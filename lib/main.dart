// FILE: lib/main.dart
//
// ============================================================================
// WHAT THIS FILE DOES
// ============================================================================
// This is the entry point of the LoadOut app — the very first Dart code that
// runs when the user taps the icon on iOS or Android. In Flutter (Google's
// cross-platform UI toolkit) every app must define a top-level `main()`
// function. That function ends with a call to `runApp(...)`, which hands a
// widget tree to Flutter's rendering engine and starts drawing the first
// frame on screen.
//
// Before `runApp()` runs, this file performs the cold-start work the rest of
// the app assumes is already done. In order: it boots Flutter's binding
// layer (the bridge between Dart and the underlying native platform), it
// connects to Firebase (Auth is the only Firebase product used at runtime;
// Crashlytics is conditionally activated below based on a SharedPreferences
// flag — defaulting to ON for fresh installs so we can triage red-screen
// crashes, but always overridable from Settings → Privacy & Data), it
// reads the `crashlytics_enabled` flag and wires the global Flutter /
// PlatformDispatcher error handlers through `CrashReporter` (the
// privacy-aware Crashlytics wrapper that scrubs PII before upload), it
// opens the on-device SQLite database via
// the `drift` package (a typed Dart ORM that compiles SQL queries from
// class definitions), it calls `SeedLoader.seedIfNeeded()` to populate the
// reference catalog from JSON files bundled in `assets/seed_data/` if the
// database is empty or stale, and finally it initializes RevenueCat (the
// in-app purchase platform) before launching `LoadOutApp`.
//
// The `await` keyword you see throughout means "pause here until this async
// operation finishes." `Future<void>` is Dart's equivalent of "this function
// returns a promise that completes with nothing." The whole `main()` is
// async because each of these initialization steps takes a non-trivial
// amount of time and must finish in a deterministic order.
//
// ============================================================================
// WHY IT EXISTS IN THE ARCHITECTURE
// ============================================================================
// Every Flutter app has exactly one `main.dart` and exactly one `main()`
// entry point — there is no way to skip it. Its role here is to act as the
// composition root: the single place where the app's long-lived dependencies
// (database, purchases service) are constructed and then handed down to the
// widget tree as ready-to-use objects. Doing this work here, before the
// first frame draws, means later code can assume "the database is open" and
// "Firebase is ready" without defensive null-checks or loading states for
// the platform itself.
//
// If this file did not exist (or got the ordering wrong), the rest of the
// app would crash on launch — Firebase calls would throw "no app initialized"
// errors, the home screen would query an empty database before seeding ran,
// and the paywall would have no SDK to talk to.
//
// ============================================================================
// WHY THIS IS HARDER THAN IT LOOKS
// ============================================================================
// `WidgetsFlutterBinding.ensureInitialized()` MUST come before any plugin
// call (Firebase, drift, RevenueCat). Without it, the Dart side has no
// channel to talk to native iOS/Android code, and the Firebase
// initialization will throw. This is the single most common Flutter
// startup bug and the reason it's the very first line.
//
// The seeding step is conditional: `seedIfNeeded()` no-ops on a populated
// database, so an existing user with their loads already saved doesn't
// pay the cost on every launch. But on a true first run the seed JSON is
// large, so this main runs measurably longer the first time the user
// opens the app — that delay is by design and intentional.
//
// RevenueCat initialization can fail offline or with placeholder API keys
// during development; `purchases.initialize()` is written to swallow those
// failures so the app still launches and the paywall just shows a
// "Pro not yet available" state.
//
// ============================================================================
// WHO CONSUMES THIS FILE
// ============================================================================
// - Nobody imports this file. It is the OS-invoked entry point. Flutter's
//   tooling generates a tiny native shim on each platform (iOS
//   `AppDelegate`, Android `MainActivity`) that calls into the Dart VM,
//   which in turn invokes `main()`.
// - `lib/app.dart` is what `main` ends up handing control to via
//   `runApp(LoadOutApp(...))`.
//
// ============================================================================
// SIDE EFFECTS
// ============================================================================
// - Initializes Firebase (network handshake to Google's auth servers on
//   first run; cached on subsequent launches).
// - Reads the `crashlytics_enabled` SharedPreferences flag and either
//   activates Firebase Crashlytics (installing FlutterError.onError /
//   PlatformDispatcher.instance.onError handlers) or explicitly disables
//   collection. The default is ENABLED for fresh installs (so we can
//   triage the red-screen crashes the user reported); users who want
//   strict no-network-egress can flip it off in Settings → Privacy &
//   Data. See `_configureCrashlytics`.
// - Opens / creates the SQLite database file in the app's support
//   directory on disk.
// - On first launch (or after a schema upgrade that requires re-seed):
//   reads ~5 JSON files from the bundled assets and writes thousands of
//   rows into SQLite.
// - Initializes the RevenueCat SDK (which starts a background process and
//   may make a network call to fetch the user's entitlement state).
// - Calls `runApp` which kicks off the Flutter render loop — the screen
//   stays black until the first widget builds, so the steps above are the
//   "splash duration" the user perceives.

import 'dart:async';
import 'dart:io' show Platform;

import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_crashlytics/firebase_crashlytics.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'app.dart';
import 'data/reticle_seed_defaults.dart';
import 'database/database.dart';
import 'database/seed_loader.dart';
import 'firebase_options.dart';
import 'services/crash_reporter.dart';
import 'services/device_compatibility_service.dart';
import 'services/purchases_service.dart';
import 'services/seed_updater.dart';

/// SharedPreferences key driving the Crashlytics opt-in.
///
/// **Default changed 2026-05-10**: was `false` (opt-in), now `true`
/// (opt-out). Users who explicitly flip the "Send anonymous crash
/// reports" switch off in Settings → Diagnostics still get respected
/// — the change is in the value the absence of a stored pref implies.
/// Privacy posture stays intact:
///
///   * The CrashReporter never sends user-typed data (recipe names,
///     firearm names, notes, brass-lot labels, etc.).
///   * Custom keys are stable identifiers only (route names, row IDs,
///     enum values).
///   * Breadcrumbs are local until a crash actually fires — a normal
///     session uploads nothing.
///
/// The justification for the default flip: the user has now seen
/// repeated red-screen crashes that we can't triage without crash
/// reports. Defaulting collection ON gives engineering the visibility
/// to fix them; users who care about strict no-network-egress can
/// still opt out in Settings.
const String kCrashlyticsEnabledPrefKey = 'crashlytics_enabled';

/// The default value for `kCrashlyticsEnabledPrefKey` when no stored
/// pref exists yet. Lives as a top-level constant so the Settings
/// screen can reference the same default when rendering the toggle's
/// initial state on a fresh install.
const bool kCrashlyticsEnabledDefault = true;

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);

  // Detect the very first launch on this install (or a launch after a
  // fresh reinstall on iOS, where Firebase's refresh token persists in
  // the system Keychain across uninstalls and would otherwise auto-
  // restore a stale "logged in" state). When the marker pref is
  // missing we sign Firebase Auth out — the user lands on
  // LoginScreen and explicitly chooses an option. The marker is set
  // immediately so a crash mid-launch doesn't loop us into repeated
  // sign-outs.
  await _enforceLoginOnFirstLaunch();

  // Crashlytics is opt-OUT. Read the SharedPreferences flag (default
  // true → collection ON; see `kCrashlyticsEnabledDefault` for the
  // privacy rationale) and wire the global error handlers via
  // `CrashReporter`. Users who want strict no-network-egress can flip
  // the toggle off in Settings → Privacy & Data; reports never include
  // user-typed strings (recipe names, firearm names, notes), only
  // stable identifiers (route names, row IDs, enum values).
  await _configureCrashlytics();

  final db = AppDatabase();
  await SeedLoader(db).seedIfNeeded();
  // Seed the default reticle library if no reticles.json was loaded by
  // SeedLoader. Idempotent — only writes when the table is empty so the
  // parallel reticle-agent's eventual JSON-backed seeding wins on a
  // future launch.
  await seedDefaultReticlesIfEmpty(db);

  // `purchases_flutter` ships macOS bindings as of 9.x, but the App
  // Store Connect side of the IAP setup is still iOS/Android-only —
  // there is no macOS storefront for the LoadOut Pro SKUs. Skip the
  // SDK boot on macOS (and any future desktop / web build) so the
  // desktop build doesn't try to negotiate with a storefront that
  // doesn't host our products. `PurchasesService.isConfigured` stays
  // false, and the paywall surfaces its "Pro not yet available"
  // placeholder. Cross-device entitlements still propagate through
  // RevenueCat — the user just buys on iOS or Android first.
  final purchases = PurchasesService();
  if (!_isPurchasesSupported) {
    debugPrint(
      'main: RevenueCat is not enabled on this platform; '
      'skipping PurchasesService.initialize().',
    );
  } else {
    await purchases.initialize();
  }

  // Fire-and-forget pull of the latest reference catalog from Firebase
  // Storage. We deliberately do NOT await this — the user should see the
  // UI immediately on cold start, even on a slow network. Any updates
  // downloaded here are persisted to the documents directory and applied
  // by the next launch's SeedLoader.seedIfNeeded(). See
  // `lib/services/seed_updater.dart` for the full flow.
  unawaited(SeedUpdater(db).checkForUpdates());

  // Snapshot the device's OS version BEFORE runApp so the
  // DeviceCompatibilityService is provided with a fully-resolved
  // profile to the widget tree. The detection itself is one platform-
  // channel hop (~1ms on Android, similar on iOS) and the value
  // never changes for the lifetime of the process. Failing detection
  // returns DeviceProfile.unknown — the service still works and
  // simply reports "no gates" for that device.
  final compatibility = await DeviceCompatibilityService.detect();

  runApp(LoadOutApp(
    database: db,
    purchases: purchases,
    compatibility: compatibility,
  ));
}

/// True when `purchases_flutter` has bindings for the current platform.
/// Web and macOS don't ship a binary today, so we gate the SDK boot.
bool get _isPurchasesSupported {
  if (kIsWeb) return false;
  return Platform.isIOS || Platform.isAndroid;
}

/// True when the Crashlytics plugin actually has native bindings on the
/// current platform. The plugin throws `MissingPluginException` on
/// macOS / web today; we gate every call so dev / desktop builds keep
/// working.
bool get _isCrashlyticsSupported {
  if (kIsWeb) return false;
  return Platform.isIOS || Platform.isAndroid;
}

/// SharedPreferences key marking that the app has launched at least
/// once on this install. Drives [_enforceLoginOnFirstLaunch].
const String _kLaunchedBeforePrefKey = 'app_launched_before';

/// Force the user to the LoginScreen on the first launch of every
/// install — including fresh reinstalls on iOS, where Firebase's
/// refresh token persists in the system Keychain across uninstalls
/// and would otherwise silently restore a stale signed-in state.
///
/// The marker pref `app_launched_before` is set BEFORE the
/// `signOut()` call so a crash between sign-out and `runApp` doesn't
/// loop the user into repeated sign-outs. Subsequent launches see the
/// marker and skip this entirely; the auth gate then routes returning
/// users straight to HomeScreen via the cached refresh token.
///
/// Soft-fails on every error (SharedPreferences unavailable, Firebase
/// not yet ready, signOut throwing). The fallback is "behave like
/// before" — the auth gate still routes to LoginScreen if the user
/// is null, just doesn't proactively force the sign-out.
Future<void> _enforceLoginOnFirstLaunch() async {
  try {
    final prefs = await SharedPreferences.getInstance();
    final hasLaunchedBefore = prefs.getBool(_kLaunchedBeforePrefKey) ?? false;
    if (hasLaunchedBefore) return;
    // Mark FIRST so a crash mid-flow doesn't trap the user.
    await prefs.setBool(_kLaunchedBeforePrefKey, true);
    final cached = FirebaseAuth.instance.currentUser;
    if (cached != null) {
      debugPrint(
        'main: first launch — clearing cached Firebase user '
        '(uid prefix ${cached.uid.substring(0, cached.uid.length.clamp(0, 6))}) '
        'so LoginScreen shows.',
      );
      await FirebaseAuth.instance.signOut();
    }
  } catch (e) {
    debugPrint('main: first-launch sign-out check failed: $e');
  }
}

/// Read the user's opt-in choice and route the global error
/// handlers (`FlutterError.onError`,
/// `PlatformDispatcher.instance.onError`) through `CrashReporter`.
///
/// Defaults to ON when no stored preference exists — see
/// `kCrashlyticsEnabledDefault` for the privacy rationale. Users
/// who flip the toggle off in Settings → Diagnostics still get
/// respected; only the implied default for a fresh install
/// changed.
///
/// When the flag is false we still call
/// `setCrashlyticsCollectionEnabled(false)` so the plugin can short
/// out any data it might otherwise queue from native crashes
/// between process launches.
Future<void> _configureCrashlytics() async {
  if (!_isCrashlyticsSupported) {
    // No platform bindings — `CrashReporter` stays in its default
    // disabled state. Every public method on it is a no-op.
    return;
  }

  bool enabled = kCrashlyticsEnabledDefault;
  try {
    final prefs = await SharedPreferences.getInstance();
    enabled = prefs.getBool(kCrashlyticsEnabledPrefKey) ??
        kCrashlyticsEnabledDefault;
  } catch (e) {
    debugPrint('main: could not read Crashlytics opt-in flag: $e');
    // Fail-closed for the read error case specifically: if we can't
    // even ASK SharedPreferences, fall back to disabled. The
    // documented default (ON) only applies when the pref read
    // succeeds and the value is null.
    enabled = false;
  }

  try {
    await FirebaseCrashlytics.instance
        .setCrashlyticsCollectionEnabled(enabled);
  } catch (e) {
    debugPrint('main: could not set Crashlytics collection state: $e');
    return;
  }

  // Hand off to the centralised CrashReporter — it installs the
  // global error handlers, sets the baseline custom keys
  // (app version, schema version, platform, OS version), and
  // exposes `setKey` / `log` / `recordError` to the rest of the
  // app. See `lib/services/crash_reporter.dart`.
  await CrashReporter.instance.initialize(
    enabled: enabled,
    ctx: CrashReporterContext(
      appVersion: '1.1.0+2',
      dbSchemaVersion: 34,
      platform: kIsWeb
          ? 'web'
          : (Platform.isIOS ? 'ios' : 'android'),
      osVersion: kIsWeb ? 'web' : Platform.operatingSystemVersion,
    ),
  );
}
