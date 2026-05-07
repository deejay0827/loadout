// FILE: lib/app.dart
//
// ============================================================================
// WHAT THIS FILE DOES
// ============================================================================
// This is the root of the widget tree — the top-level UI component that
// Flutter renders first. In Flutter, every UI element ("widget") nests
// inside another widget; the screen you see is the leaves of a tree whose
// root sits here. `LoadOutApp.build(...)` returns a `MaterialApp`, which is
// the standard top-level widget that wires up navigation, theming, and
// localization for an app that follows Google's Material design language.
//
// The interesting work this file does is dependency injection. Flutter
// itself has no built-in DI container, so the LoadOut app uses the
// `provider` package — a popular, lightweight state management library that
// builds on top of Flutter's `InheritedWidget` mechanism. The
// `MultiProvider` widget at the top of `build()` declares every long-lived
// service the rest of the app needs: the SQLite database, the auth
// service, the seven repository classes that wrap database tables, the
// RevenueCat purchases service, and the `EntitlementNotifier` that
// publishes "is this user a Pro subscriber?" as observable state. The
// `Provider<T>` form creates objects, and the `ChangeNotifierProvider<T>`
// form additionally listens for `notifyListeners()` calls so widgets that
// read it can rebuild when state changes. The `StreamProvider<User?>`
// turns Firebase Auth's "the signed-in user changed" stream into a value
// any descendant widget can read with `context.watch<User?>()`.
//
// Below `MultiProvider` is the routing logic, implemented as a chain of
// gate widgets. `_DisclaimerGate` checks `SharedPreferences` for the
// versioned `disclaimer_accepted_v1` flag and shows the full-screen
// disclaimer until the user accepts; once accepted it shows a per-launch
// reminder dialog and renders `_AuthGate`. `_AuthGate` initializes
// platform deep-link handling (iOS Universal Links / Android App Links via
// `app_links`) so email-link sign-in callbacks resolve properly, mirrors
// the Firebase Auth user ID into RevenueCat so entitlements follow the
// user across devices, then shows either `LoginScreen` or `HomeScreen`
// based on whether `User?` is null.
//
// ============================================================================
// WHY IT EXISTS IN THE ARCHITECTURE
// ============================================================================
// Centralizing all provider declarations here means the rest of the app can
// pull dependencies from `BuildContext` without ever calling a constructor
// directly. A screen deep in the tree just writes
// `context.read<RecipeRepository>()` and gets the singleton wired up here.
// This keeps each screen testable in isolation (you can rebuild that
// subtree against a fake repository) and avoids passing constructor
// arguments through every layer.
//
// The two gates exist because both checks (legal disclaimer accepted? user
// signed in?) need to run before the user is allowed near the home
// screen, and both checks involve async work (reading prefs, listening
// to Firebase). Splitting them into separate widgets keeps each
// responsibility narrow and lets the disclaimer state survive sign-out
// without being tangled up with auth state.
//
// `themeMode: ThemeMode.dark` is a deliberate brand decision: the app icon,
// landing page, and onboarding are all designed in the brass-on-gunmetal
// dark palette. The light theme exists as a courtesy for users who flip
// system appearance, but dark is the canonical look.
//
// ============================================================================
// WHY THIS IS HARDER THAN IT LOOKS
// ============================================================================
// `Provider` ordering matters. `EntitlementNotifier` reads `PurchasesService`
// out of context during its constructor, so `PurchasesService` MUST be
// listed above it in the `providers:` list. Get this order wrong and you
// crash on first build with "Could not find PurchasesService in context."
//
// Deep-link handling has two surfaces: `appLinks.getInitialLink()` returns
// the URI that launched the app (cold start case), while
// `appLinks.uriLinkStream` fires for links that arrive while the app is
// already running. Both have to be wired up or one of the email-link
// flows breaks. The subscription must be cancelled in `dispose()` to
// avoid leaks.
//
// `discarded_futures` lints are intentionally suppressed in
// `_initPurchasesUserSync` — the auth state listener is sync (a `void`
// callback), but the body needs to call an async method
// (`setAppUserId`). We genuinely don't want to await it (would block the
// stream) and we genuinely don't care about the result, so the lint is
// silenced where it would otherwise complain.
//
// `_DisclaimerGate` uses a private `_launchReminderShown` flag instead of
// state to remember it already showed the per-launch dialog. Without
// that, every state rebuild after acceptance would re-show the dialog —
// it has to fire exactly once per app launch.
//
// ============================================================================
// WHO CONSUMES THIS FILE
// ============================================================================
// - `lib/main.dart` — instantiates `LoadOutApp` and passes it to `runApp`.
// - Every screen and widget in `lib/screens/` and `lib/widgets/` reads its
//   dependencies from the `MultiProvider` declared here via
//   `context.read<T>()` or `context.watch<T>()`.
// - `lib/screens/disclaimer/disclaimer_screen.dart` — rendered by
//   `_DisclaimerGate` until the user accepts.
// - `lib/screens/auth/login_screen.dart` and
//   `lib/screens/home/home_screen.dart` — the two terminal destinations
//   `_AuthGate` switches between.
//
// ============================================================================
// SIDE EFFECTS
// ============================================================================
// - Reads/writes `SharedPreferences` for the disclaimer-accepted flag.
// - Subscribes to two Firebase streams (auth state, deep links) and one
//   `app_links` stream; subscriptions are tracked for disposal.
// - Calls `PurchasesService.setAppUserId()` whenever the Firebase Auth
//   user changes — this round-trips to the RevenueCat servers.
// - Schedules a post-frame callback to show the launch-reminder dialog;
//   that involves `showDialog`, which pushes a route on the navigator.
// - Provides every long-lived service to the widget tree; constructor
//   side effects of those services (e.g. opening database connections,
//   setting up Firestore listeners) fire on first read.

import 'dart:async';

import 'package:app_links/app_links.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'database/database.dart';
import 'repositories/ballistic_profile_repository.dart';
import 'repositories/batch_repository.dart';
import 'repositories/brass_lot_repository.dart';
import 'repositories/component_repository.dart';
import 'repositories/firearm_repository.dart';
import 'repositories/load_development_repository.dart';
import 'repositories/optics_repository.dart';
import 'repositories/process_step_repository.dart';
import 'repositories/range_day_repository.dart';
import 'repositories/recipe_repository.dart';
import 'repositories/reticle_repository.dart';
import 'repositories/target_repository.dart';
import 'screens/auth/login_screen.dart';
import 'screens/disclaimer/disclaimer_screen.dart';
import 'screens/home/home_screen.dart';
import 'services/auth_service.dart';
import 'services/auto_save_service.dart';
import 'services/beginner_mode_service.dart';
import 'services/ble/ble_service.dart';
import 'services/ble/kestrel_service.dart';
import 'services/entitlement_notifier.dart';
import 'services/hit_probability_service.dart';
import 'services/purchases_service.dart';
import 'services/unit_service.dart';
import 'theme/app_theme.dart';
import 'widgets/disclaimer_overlay.dart';

/// Pref key for the legal disclaimer acceptance flag. Versioned so that
/// updating the disclaimer text in a future release can force re-acceptance
/// by bumping the suffix (e.g. `disclaimer_accepted_v2`).
const _disclaimerPrefKey = 'disclaimer_accepted_v1';

class LoadOutApp extends StatelessWidget {
  const LoadOutApp({
    super.key,
    required this.database,
    required this.purchases,
  });

  final AppDatabase database;
  final PurchasesService purchases;

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        Provider<AppDatabase>.value(value: database),
        Provider<PurchasesService>.value(value: purchases),
        Provider<AuthService>(create: (_) => AuthService()),
        Provider<RecipeRepository>(create: (_) => RecipeRepository(database)),
        Provider<FirearmRepository>(create: (_) => FirearmRepository(database)),
        Provider<ComponentRepository>(
          create: (_) => ComponentRepository(database),
        ),
        Provider<OpticsRepository>(
          create: (_) => OpticsRepository(database),
        ),
        Provider<ReticleRepository>(
          create: (_) => ReticleRepository(database),
        ),
        Provider<BrassLotRepository>(
          create: (_) => BrassLotRepository(database),
        ),
        Provider<BatchRepository>(create: (_) => BatchRepository(database)),
        Provider<ProcessStepRepository>(
          create: (_) => ProcessStepRepository(database),
        ),
        Provider<LoadDevelopmentRepository>(
          create: (_) => LoadDevelopmentRepository(database),
        ),
        Provider<BallisticProfileRepository>(
          create: (_) => BallisticProfileRepository(database),
        ),
        Provider<TargetRepository>(
          create: (_) => TargetRepository(database),
        ),
        Provider<RangeDayRepository>(
          create: (_) => RangeDayRepository(database),
        ),
        // Stateless service — provided once for the Range Day screen's
        // hit-probability gauge. Pure-functional, so a single instance is
        // safe across the whole tree.
        Provider<HitProbabilityService>(
          create: (_) => const HitProbabilityService(),
        ),
        ChangeNotifierProvider<AutoSaveService>(
          create: (_) => AutoSaveService(),
        ),
        ChangeNotifierProvider<BeginnerModeService>(
          create: (_) => BeginnerModeService(),
        ),
        ChangeNotifierProvider<UnitService>(
          create: (_) => UnitService(),
        ),
        ChangeNotifierProvider<EntitlementNotifier>(
          create: (ctx) => EntitlementNotifier(ctx.read<PurchasesService>()),
        ),
        // BLE services. Provided once and shared across the app so a
        // Kestrel connection established on the Devices screen survives
        // a navigation back to Ballistics. The BleService is lazy — its
        // adapter-state subscription doesn't fire until something asks
        // for the radio state.
        ChangeNotifierProvider<BleService>(
          create: (_) {
            final svc = BleService();
            // ignore: discarded_futures
            svc.initialize();
            return svc;
          },
        ),
        ChangeNotifierProvider<KestrelService>(
          create: (ctx) => KestrelService(ctx.read<BleService>()),
        ),
        // Seed the auth-state stream with `FirebaseAuth.instance.currentUser`,
        // which is the SYNCHRONOUSLY-available cached user from the prior
        // session. Without this seeding, `initialData: null` made every
        // already-logged-in user briefly see `LoginScreen` on cold start
        // because `authStateChanges` first emits asynchronously (~100-300ms
        // after the SDK rehydrates the cached token). The flash was visible
        // and confusing — it looked like the app was about to ask for
        // re-login and then jumped past the screen.
        //
        // With the seed:
        //   - Returning users (cached session) → initialData is the cached
        //     User, _AuthGate routes straight to HomeScreen, no LoginScreen
        //     flash.
        //   - Brand-new users / signed-out users → initialData is null,
        //     _AuthGate shows LoginScreen and stays there until they log in.
        //   - Edge case: a stale cached user whose token was revoked
        //     server-side will briefly see HomeScreen before
        //     authStateChanges emits null and bounces them back to
        //     LoginScreen. This is a very rare event and an acceptable
        //     trade for fixing the every-launch flash.
        StreamProvider<User?>(
          create: (context) => context.read<AuthService>().authStateChanges,
          initialData: FirebaseAuth.instance.currentUser,
        ),
      ],
      child: MaterialApp(
        title: 'LoadOut',
        theme: AppTheme.light,
        darkTheme: AppTheme.dark,
        themeMode: ThemeMode.dark, // Brand identity defaults to dark.
        home: const _DisclaimerGate(),
      ),
    );
  }
}

/// Gate that shows the full-screen disclaimer until the user accepts it,
/// then hands off to [_AuthGate] and surfaces the per-launch reminder
/// dialog exactly once.
class _DisclaimerGate extends StatefulWidget {
  const _DisclaimerGate();

  @override
  State<_DisclaimerGate> createState() => _DisclaimerGateState();
}

class _DisclaimerGateState extends State<_DisclaimerGate> {
  bool _loading = true;
  bool _accepted = false;
  bool _launchReminderShown = false;

  @override
  void initState() {
    super.initState();
    _loadAcceptance();
  }

  Future<void> _loadAcceptance() async {
    final prefs = await SharedPreferences.getInstance();
    final accepted = prefs.getBool(_disclaimerPrefKey) ?? false;
    if (!mounted) return;
    setState(() {
      _accepted = accepted;
      _loading = false;
    });
  }

  Future<void> _onAccept() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_disclaimerPrefKey, true);
    if (!mounted) return;
    setState(() => _accepted = true);
  }

  void _maybeShowLaunchReminder() {
    if (_launchReminderShown) return;
    _launchReminderShown = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      showLaunchDisclaimer(context);
    });
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Scaffold(
        body: Center(child: CircularProgressIndicator()),
      );
    }
    if (!_accepted) {
      return DisclaimerScreen(onAccept: _onAccept);
    }
    _maybeShowLaunchReminder();
    return const _AuthGate();
  }
}

class _AuthGate extends StatefulWidget {
  const _AuthGate();

  @override
  State<_AuthGate> createState() => _AuthGateState();
}

class _AuthGateState extends State<_AuthGate> {
  StreamSubscription<Uri>? _linkSub;
  StreamSubscription<User?>? _authSub;

  @override
  void initState() {
    super.initState();
    _initDeepLinks();
    _initPurchasesUserSync();
  }

  Future<void> _initDeepLinks() async {
    final appLinks = AppLinks();
    final auth = context.read<AuthService>();

    final initialUri = await appLinks.getInitialLink();
    if (initialUri != null) {
      await auth.tryCompleteEmailLink(initialUri.toString());
    }

    _linkSub = appLinks.uriLinkStream.listen((uri) {
      auth.tryCompleteEmailLink(uri.toString());
    });
  }

  /// Mirror the Firebase Auth user into RevenueCat so entitlement state
  /// follows the user across devices. Runs once at gate mount with the
  /// current user, then again every time auth state changes.
  void _initPurchasesUserSync() {
    final purchases = context.read<PurchasesService>();
    final auth = context.read<AuthService>();
    // Fire once with the current user (if any) so the SDK's app user ID
    // matches Firebase before any purchases happen this session.
    // ignore: discarded_futures
    purchases.setAppUserId(auth.currentUser?.uid);
    _authSub = auth.authStateChanges.listen((user) {
      // ignore: discarded_futures
      purchases.setAppUserId(user?.uid);
    });
  }

  @override
  void dispose() {
    _linkSub?.cancel();
    _authSub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final user = context.watch<User?>();
    return user == null ? const LoginScreen() : const HomeScreen();
  }
}
