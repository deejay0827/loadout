// FILE: test/_range_day_test_harness.dart
//
// ============================================================================
// WHAT THIS FILE DOES
// ============================================================================
// Shared widget-test scaffolding for the Range Day suite. Exposes one entry
// point — `pumpRangeDayScreen(...)` — that wraps the supplied screen widget
// in the same `MultiProvider` tree the production app uses, but with every
// platform-channel-touching service replaced by a stub. Tests then drive
// the widget through `WidgetTester` exactly like a regular `pumpWidget`
// flow, but never crash from a missing platform plugin.
//
// The harness also exports its stub classes so an individual test that
// wants to override a single override (e.g. flip `EntitlementNotifier` to
// Pro, or hand the screen a `HitProbabilityMapResult` without running the math) can
// reach in without rebuilding the tree from scratch.
//
// Filename starts with `_` so the test runner's default glob
// (`*_test.dart`) skips this file as a top-level test. Tests still
// `import` it explicitly.
//
// ============================================================================
// WHY IT EXISTS IN THE ARCHITECTURE
// ============================================================================
// Five Range Day screens × five identical setup blocks = a ton of
// duplication. Worse, every Range Day screen reads ~10–15 services / repos
// out of context, so each test would otherwise have to declare them all
// independently. Centralizing the harness here keeps every test's
// `pumpWidget` call to one line, and ensures that a future provider added
// in `lib/app.dart` only needs adding here once for the whole Range Day
// suite to keep working.
//
// ============================================================================
// WHY THIS IS HARDER THAN IT LOOKS
// ============================================================================
//   * BLE / sensor services hit `MissingPluginException` if any production
//     code path runs through them in a unit test. We provide REAL service
//     instances (their constructors don't touch FlutterBluePlus or
//     sensors_plus), but DO NOT call `initialize()`. The services'
//     `start()` methods detect the test platform (not iOS / not Android)
//     and bail out early via `_markUnavailable()`, so the screens can
//     call `start()` defensively in `initState` without crashing. The
//     screens that read `cantDegrees` / `inclineDegrees` /
//     `headingDegrees` just see `null` (the pre-first-sample state).
//   * `EntitlementNotifier` would normally subscribe to a RevenueCat
//     stream via a real `PurchasesService`. In tests the SDK is never
//     configured (placeholder keys path), so `_purchases.isConfigured`
//     returns false and the notifier short-circuits its constructor —
//     `isPro` then reflects the fixed test override.
//   * `EntitlementNotifier._devProOverride` defaults to `false` (Free)
//     but is a mutable runtime flag (Settings → Diagnostics). Tests
//     must not depend on a mutable global, so both "free user" and
//     "pro user" tests use [FixedEntitlementNotifier] (a custom
//     subclass exposed below) which overrides `isPro` to return
//     whatever the test set, ignoring the dev-override branch
//     entirely.
//   * `MaterialApp` needs to be the root for `Scaffold`, `Navigator`,
//     `Theme`, etc., to all work. The harness wraps the supplied screen
//     accordingly.
//
// ============================================================================
// WHO CONSUMES THIS FILE
// ============================================================================
//   * test/range_day_screen_widget_test.dart
//   * test/range_day_detail_screen_widget_test.dart
//   * test/hit_probability_map_screen_widget_test.dart
//   * test/bc_truing_screen_widget_test.dart
//   * test/scope_tracking_screen_widget_test.dart
//
// ============================================================================
// SIDE EFFECTS
// ============================================================================
//   * Constructs an in-memory drift `AppDatabase`. Caller is responsible
//     for closing it via `addTearDown` (the harness does this for you
//     when no DB is supplied).
//   * Instantiates real `BleService`, `CantService`, `MagnetometerService`,
//     and `InclinometerService` ChangeNotifiers. None of them subscribe
//     to any plugin until `start()` / `initialize()` is called; the
//     screens under test DO call `start()` but it short-circuits on the
//     test host (macOS) so no platform channels fire.

import 'dart:async';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:loadout/database/database.dart';
import 'package:loadout/repositories/atmosphere_preset_repository.dart';
import 'package:loadout/repositories/ballistic_profile_repository.dart';
import 'package:loadout/repositories/favorites_repository.dart';
import 'package:loadout/repositories/firearm_repository.dart';
import 'package:loadout/repositories/manufactured_ammo_repository.dart';
import 'package:loadout/repositories/optics_repository.dart';
import 'package:loadout/repositories/range_day_repository.dart';
import 'package:loadout/repositories/recipe_repository.dart';
import 'package:loadout/repositories/reticle_repository.dart';
import 'package:loadout/repositories/target_repository.dart';
import 'package:loadout/services/auto_save_service.dart';
import 'package:loadout/services/ble/ble_service.dart';
import 'package:loadout/services/ble/bushnell_rangefinder_service.dart';
import 'package:loadout/services/ble/kestrel_service.dart';
import 'package:loadout/services/ble/leica_geovid_service.dart';
import 'package:loadout/services/ble/sig_kilo_service.dart';
import 'package:loadout/services/ble/vectronix_terrapin_service.dart';
import 'package:loadout/services/ble/vortex_rangefinder_service.dart';
import 'package:loadout/services/bc_truing_service.dart';
import 'package:loadout/services/entitlement_notifier.dart';
import 'package:loadout/services/hit_probability_service.dart';
import 'package:loadout/services/purchases_service.dart';
import 'package:loadout/services/sensors/cant_service.dart';
import 'package:loadout/services/sensors/inclinometer_service.dart';
import 'package:loadout/services/sensors/magnetometer_service.dart';
import 'package:loadout/services/scope_tracking_service.dart';
import 'package:loadout/services/unit_service.dart';
import 'package:loadout/services/hit_probability_map_service.dart';
import 'package:loadout/services/visual_style_notifier.dart';
import 'package:loadout/services/watch_bridge_service.dart';

/// `EntitlementNotifier` subclass with deterministic `isPro`. The
/// production class's `_devProOverride` is a mutable runtime flag
/// (defaults to `false` / Free, flipped via Settings → Diagnostics in
/// debug builds). Tests need a fixed, non-mutable value, so this
/// subclass returns whatever was set at construction time, ignoring
/// the dev-override branch entirely.
class FixedEntitlementNotifier extends EntitlementNotifier {
  FixedEntitlementNotifier(super.purchases, {required bool isPro})
      : _isProOverride = isPro;

  final bool _isProOverride;

  @override
  bool get isPro => _isProOverride;
}

/// Swappable host for the screen-under-test. Lets the harness teardown
/// helper unmount the screen WHILE the parent `MultiProvider` tree is
/// still alive, which matters because production Range Day screens'
/// `dispose()` calls `context.read<...Service>().stop()` to stop
/// sensors. If we swapped the entire `pumpWidget` tree to
/// `SizedBox.shrink()`, the Provider above the screen would be
/// deactivated at the same time the screen's `dispose()` fires — and
/// `context.read` from a deactivated subtree throws. By keeping the
/// MultiProvider mounted and just hiding the child, the screen
/// disposes cleanly first, the Providers can then unmount on the
/// final pumpWidget swap.
class _SwappableScreenHost extends StatefulWidget {
  const _SwappableScreenHost({required this.initialChild});

  final Widget initialChild;

  @override
  State<_SwappableScreenHost> createState() => _SwappableScreenHostState();
}

class _SwappableScreenHostState extends State<_SwappableScreenHost> {
  Widget? _override;

  void hideChild() {
    setState(() => _override = const SizedBox.shrink());
  }

  @override
  Widget build(BuildContext context) {
    return _override ?? widget.initialChild;
  }
}

/// No-op navigator observer used as the default for tests that don't
/// care about route lifecycle. Tests that need to assert
/// `Navigator.push` was called pass their own observer.
class NoOpNavigatorObserver extends NavigatorObserver {}

/// Result of [pumpRangeDayScreen]. Returned by-value so tests can poke
/// at the in-memory DB or flip Pro state.
class RangeDayHarness {
  RangeDayHarness({
    required this.db,
    required this.entitlements,
    required this.purchases,
    required this.navigatorObserver,
  });

  final AppDatabase db;
  final FixedEntitlementNotifier entitlements;
  final PurchasesService purchases;
  final NavigatorObserver navigatorObserver;
}

/// Pump the [screen] widget into the tester wrapped in a fully-provided
/// MaterialApp tree. Returns a [RangeDayHarness] so the caller can
/// insert fixture rows, flip entitlements, or inspect the navigator
/// observer. The DB is closed for the caller via `addTearDown` when
/// the harness creates it; if the caller passes their own [db], they
/// own its lifecycle.
///
/// Pass [isPro] to control `EntitlementNotifier.isPro`; defaults to
/// `false` so screens see the free-tier paths by default.
///
/// Pass an existing [db] to share one DB between multiple `pumpWidget`
/// calls in a single test (e.g. assert the row count after a save).
/// When omitted, a fresh in-memory DB is created and torn down.
Future<RangeDayHarness> pumpRangeDayScreen(
  WidgetTester tester, {
  required Widget screen,
  AppDatabase? db,
  bool isPro = false,
  NavigatorObserver? navigatorObserver,
}) async {
  // Real in-memory drift DB — the production repos work directly. No
  // mocking needed at the persistence layer. Caller can pass their own
  // DB to share state across pumpWidget calls.
  final database = db ?? AppDatabase.forTesting(NativeDatabase.memory());
  if (db == null) {
    // Close the DB AFTER the widget tree has been disposed.
    addTearDown(() async {
      await database.close();
    });
  }

  // Real PurchasesService — never configured (placeholder keys path),
  // so EntitlementNotifier's stream listener is never wired. Safe.
  final purchases = PurchasesService();

  // Custom EntitlementNotifier with deterministic isPro. Bypasses the
  // debug-override branch so "free user" tests work in debug builds.
  final entitlements = FixedEntitlementNotifier(purchases, isPro: isPro);
  addTearDown(entitlements.dispose);

  // Real BLE services. Their constructors are pure — no plugin calls
  // happen until initialize() / startScan(). The Range Day screens
  // read `lastReading` (null until a real device pushes a frame), so
  // leaving the services unscanned is the correct test behavior.
  final ble = BleService();
  addTearDown(ble.dispose);
  final kestrel = KestrelService(ble);
  addTearDown(kestrel.dispose);
  final sigKilo = SigKiloService(ble);
  addTearDown(sigKilo.dispose);
  final bushnell = BushnellRangefinderService(ble);
  addTearDown(bushnell.dispose);
  final vortex = VortexRangefinderService(ble);
  addTearDown(vortex.dispose);
  final leica = LeicaGeovidService(ble);
  addTearDown(leica.dispose);
  final vectronix = VectronixTerrapinService(ble);
  addTearDown(vectronix.dispose);

  // Real sensor services. Their constructors are pure; start() detects
  // the test host (not iOS, not Android) and bails out via
  // _markUnavailable(). Subsequent reads of cantDegrees /
  // inclineDegrees / headingDegrees return null.
  //
  // IMPORTANT: pre-call start() once HERE so the synchronous
  // _markUnavailable -> notifyListeners path fires now, BEFORE the
  // screen's initState runs. The first call flips `_available` to
  // false and emits one notification; subsequent calls (e.g. from
  // RangeDayDetailScreen.initState) hit the `if (!_available)
  // return;` early-out in `_markUnavailable` and become silent
  // no-ops. Without this, the screen's `initState` fires
  // notifyListeners during the build phase and throws "setState
  // called during build". (This is also a real production bug on
  // macOS desktop / web — see the flagged test in
  // `range_day_detail_screen_widget_test.dart`.)
  final cant = CantService();
  addTearDown(cant.dispose);
  // ignore: discarded_futures
  cant.start();
  final magnetometer = MagnetometerService();
  addTearDown(magnetometer.dispose);
  // ignore: discarded_futures
  magnetometer.start();
  final inclinometer = InclinometerService();
  addTearDown(inclinometer.dispose);
  // ignore: discarded_futures
  inclinometer.start();

  // Real ChangeNotifiers for unit / autosave services. Both hydrate
  // from SharedPreferences asynchronously, but the screens we test do
  // not depend on the hydration completing before first frame.
  final units = UnitService();
  addTearDown(units.dispose);
  final autoSave = AutoSaveService();
  addTearDown(autoSave.dispose);
  // Phase 10 Group B / VFP Phase 3 — VisualStyleNotifier mirrors the
  // LocaleService pattern: hydrates from SharedPreferences async,
  // defaults to `VisualStyle.stylized` pre-hydrate. Range Day's AppBar
  // SegmentedButton, the picker preview TargetPlot, and the four
  // workspace TargetPlot call sites all `context.watch` this notifier.
  // Without it registered here, Consumer / context.watch lookups
  // throw `ProviderNotFoundError` and Range Day's
  // RangeDayErrorBoundary swallows the entire screen — every widget
  // test that pumps RangeDayDetailScreen fails as a result.
  final visualStyle = VisualStyleNotifier();
  addTearDown(visualStyle.dispose);

  // Watch bridge in unsupported mode. Range Day screens push to the
  // bridge whenever the user picks a load / firearm / common load /
  // when the solver runs; in tests we want those calls to short-
  // circuit silently rather than try to fire MethodChannel calls
  // against a non-existent platform handler. `isSupportedOverride:
  // false` makes every typed `send*` method an immediate no-op.
  final watchBridge = WatchBridgeService(isSupportedOverride: false);
  addTearDown(watchBridge.dispose);

  final observer = navigatorObserver ?? NoOpNavigatorObserver();

  // Range Day screens are dense — at any width >= 600 logical px the
  // detail screen flips to a two-column "wide" layout (left flex 5,
  // right flex 6). At 600-1000 logical px the left column gets ~270
  // logical px which is too narrow for several of the production
  // card headers (e.g. "Firing solution" + icon, "Group statistics"
  // + n-shot label). We bump to 2560x1920 / DPR 2.0 = 1280x960
  // logical, which gives the left column ~580 px — comfortable for
  // every card header in production.
  // (Without this, tests on the default 800x600 viewport see "RenderFlex
  // overflowed by N pixels" exceptions that get caught by
  // `RangeDayErrorBoundary` and replace the real UI with an error card —
  // any subsequent `find.text('Setup')` then returns nothing because the
  // Setup card was never rendered.)
  tester.view.physicalSize = const Size(2560, 1920);
  tester.view.devicePixelRatio = 2.0;
  addTearDown(() {
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  });

  await tester.pumpWidget(
    MultiProvider(
      providers: [
        Provider<AppDatabase>.value(value: database),
        Provider<PurchasesService>.value(value: purchases),
        Provider<RangeDayRepository>(
          create: (_) => RangeDayRepository(database),
        ),
        Provider<RecipeRepository>(
          create: (_) => RecipeRepository(database),
        ),
        Provider<FirearmRepository>(
          create: (_) => FirearmRepository(database),
        ),
        Provider<BallisticProfileRepository>(
          create: (_) => BallisticProfileRepository(database),
        ),
        Provider<AtmospherePresetRepository>(
          create: (_) => AtmospherePresetRepository(database),
        ),
        Provider<TargetRepository>(
          create: (_) => TargetRepository(database),
        ),
        Provider<OpticsRepository>(
          create: (_) => OpticsRepository(database),
        ),
        // Curated manufactured-ammo catalog (schema v23). Read-only
        // surface that feeds the Range Day "Pick a common factory
        // load" empty-state picker via [CommonLoadsCatalog].
        Provider<ManufacturedAmmoRepository>(
          create: (_) => ManufacturedAmmoRepository(database),
        ),
        Provider<ReticleRepository>(
          create: (_) => ReticleRepository(database),
        ),
        Provider<FavoritesRepository>(
          create: (_) => FavoritesRepository(database),
        ),
        Provider<HitProbabilityService>(
          create: (_) => const HitProbabilityService(),
        ),
        Provider<HitProbabilityMapService>(
          create: (_) => const HitProbabilityMapService(),
        ),
        Provider<BcTruingService>(
          create: (_) => const BcTruingService(),
        ),
        Provider<ScopeTrackingService>(
          create: (_) => const ScopeTrackingService(),
        ),
        ChangeNotifierProvider<UnitService>.value(value: units),
        ChangeNotifierProvider<AutoSaveService>.value(value: autoSave),
        ChangeNotifierProvider<VisualStyleNotifier>.value(
          value: visualStyle,
        ),
        ChangeNotifierProvider<EntitlementNotifier>.value(value: entitlements),
        ChangeNotifierProvider<BleService>.value(value: ble),
        ChangeNotifierProvider<KestrelService>.value(value: kestrel),
        ChangeNotifierProvider<SigKiloService>.value(value: sigKilo),
        ChangeNotifierProvider<BushnellRangefinderService>.value(
          value: bushnell,
        ),
        ChangeNotifierProvider<VortexRangefinderService>.value(value: vortex),
        ChangeNotifierProvider<LeicaGeovidService>.value(value: leica),
        ChangeNotifierProvider<VectronixTerrapinService>.value(
          value: vectronix,
        ),
        ChangeNotifierProvider<CantService>.value(value: cant),
        ChangeNotifierProvider<MagnetometerService>.value(value: magnetometer),
        ChangeNotifierProvider<InclinometerService>.value(value: inclinometer),
        Provider<WatchBridgeService>.value(value: watchBridge),
      ],
      child: MaterialApp(
        navigatorObservers: [observer],
        home: _SwappableScreenHost(initialChild: screen),
      ),
    ),
  );

  // Run the staged-disposal teardown automatically when the test
  // ends, even if the test body throws first. Without this, a failed
  // assertion in the body would skip the explicit
  // `tearDownRangeDayWidgetTree` call, leaving the dispose chain to
  // run later (during the next test's pre-runApp) where the
  // "deactivated widget's ancestor" assertion would leak into THAT
  // test's `takeException()`. Calling the helper a second time
  // (from the test body) is safe — the host is already empty, the
  // navigator already at the root, so the helper short-circuits.
  addTearDown(() async {
    await tearDownRangeDayWidgetTree(tester);
  });

  return RangeDayHarness(
    db: database,
    entitlements: entitlements,
    purchases: purchases,
    navigatorObserver: observer,
  );
}

/// Call at the END of every Range Day widget test to dispose the
/// widget tree before the framework verifies pending timers. Drift's
/// `StreamQueryStore.markAsClosed` schedules a 0-duration `Timer.run`
/// every time a stream subscriber unsubscribes; left unfired, that
/// Timer trips Flutter's "A Timer is still pending even after the
/// widget tree was disposed" invariant check.
///
/// IMPORTANT: production Range Day screens' `dispose()` calls
/// `context.read<...Service>().stop()` to halt sensors. By the time
/// State.dispose() fires, the element is already `defunct`, and
/// `context.read` from a defunct element throws a debug-time
/// assertion "Looking up a deactivated widget's ancestor is unsafe".
/// In a real running app the `FlutterError.onError` chain just logs
/// it, but in widget tests the framework records every error in
/// `_pendingExceptionDetails` and a subsequent `takeException()`
/// would surface it as a spurious test failure. The teardown
/// therefore explicitly consumes each "deactivated ancestor" error
/// via `tester.takeException()` after the pump that produced it.
///
/// The teardown proceeds in staged steps so unrelated dispose
/// ordering bugs (e.g. a real timer leak) still surface in their own
/// errors:
///
///   1. Pop any pushed routes — detail screens reached via
///      `Navigator.push` dispose first, while their Providers
///      (still mounted under the host) are alive.
///   2. Tell the [_SwappableScreenHost] to render
///      `SizedBox.shrink()`. The original `home:` screen disposes
///      while the MultiProvider above it is still mounted.
///   3. Pump `SizedBox.shrink()` at the root — drains the drift
///      stream-cancel `Timer.run` and disposes the MultiProvider /
///      MaterialApp.
///
/// Safe to call even if the test is already failing — wrapped in a
/// try/catch.
Future<void> tearDownRangeDayWidgetTree(WidgetTester tester) async {
  void absorbDeactivatedAncestorError() {
    final pending = tester.takeException();
    if (pending == null) return;
    final message = pending.toString();
    if (!message.contains("deactivated widget's ancestor is unsafe")) {
      // Not the production-dispose footgun we're tolerating — re-raise
      // by setting it as an uncaught error on the test zone so the
      // framework still reports it.
      Zone.current.handleUncaughtError(
        pending,
        pending is Error ? pending.stackTrace ?? StackTrace.current : StackTrace.current,
      );
    }
  }

  try {
    // Step 1: pop any pushed routes (a navigator-push test may have
    // mounted RangeDayDetailScreen on top of the host).
    final navigatorFinder = find.byType(Navigator);
    if (navigatorFinder.evaluate().isNotEmpty) {
      final navState = tester.state<NavigatorState>(navigatorFinder.first);
      for (var i = 0; i < 8 && navState.canPop(); i++) {
        navState.pop();
        await tester.pump();
      }
      await tester.pumpAndSettle();
      absorbDeactivatedAncestorError();
    }
    // Step 2: hide the home screen-under-test under the live Provider
    // tree so its dispose() can read services safely.
    final hostFinder = find.byType(_SwappableScreenHost);
    if (hostFinder.evaluate().isNotEmpty) {
      tester.state<_SwappableScreenHostState>(hostFinder).hideChild();
      await tester.pumpAndSettle();
      absorbDeactivatedAncestorError();
    }
    // Step 3: drop the rest of the tree; the screen has already
    // disposed cleanly.
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
    absorbDeactivatedAncestorError();
  } catch (_) {
    // Already disposed or in an inconsistent state — ignore.
  }
}
