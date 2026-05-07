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
// connects to Firebase (the only Google service we use is Firebase Auth for
// sign-in), it opens the on-device SQLite database via the `drift` package
// (a typed Dart ORM that compiles SQL queries from class definitions), it
// calls `SeedLoader.seedIfNeeded()` to populate the reference catalog from
// JSON files bundled in `assets/seed_data/` if the database is empty or
// stale, and finally it initializes RevenueCat (the in-app purchase
// platform) before launching `LoadOutApp`.
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

import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/material.dart';

import 'app.dart';
import 'database/database.dart';
import 'database/seed_loader.dart';
import 'firebase_options.dart';
import 'services/purchases_service.dart';
import 'services/seed_updater.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);

  final db = AppDatabase();
  await SeedLoader(db).seedIfNeeded();

  final purchases = PurchasesService();
  await purchases.initialize();

  // Fire-and-forget pull of the latest reference catalog from Firebase
  // Storage. We deliberately do NOT await this — the user should see the
  // UI immediately on cold start, even on a slow network. Any updates
  // downloaded here are persisted to the documents directory and applied
  // by the next launch's SeedLoader.seedIfNeeded(). See
  // `lib/services/seed_updater.dart` for the full flow.
  unawaited(SeedUpdater(db).checkForUpdates());

  runApp(LoadOutApp(database: db, purchases: purchases));
}
