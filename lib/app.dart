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
import 'l10n/app_localizations.dart';
import 'repositories/atmosphere_preset_repository.dart';
import 'repositories/ballistic_profile_repository.dart';
import 'repositories/batch_repository.dart';
import 'repositories/brass_lot_repository.dart';
import 'repositories/component_repository.dart';
import 'repositories/drag_curve_repository.dart';
import 'repositories/favorites_repository.dart';
import 'repositories/firearm_repository.dart';
import 'repositories/load_development_repository.dart';
import 'repositories/manufactured_ammo_repository.dart';
import 'repositories/optics_repository.dart';
import 'repositories/process_step_repository.dart';
import 'repositories/range_day_repository.dart';
import 'repositories/recipe_repository.dart';
import 'repositories/reticle_repository.dart';
import 'repositories/target_repository.dart';
import 'screens/auth/login_screen.dart';
import 'screens/disclaimer/disclaimer_screen.dart';
import 'screens/home/home_screen.dart';
import 'services/ai_smart_import_service.dart';
import 'services/auth_service.dart';
import 'services/auto_save_service.dart';
import 'services/beginner_mode_service.dart';
import 'services/ble/ble_service.dart';
import 'services/ble/bushnell_rangefinder_service.dart';
import 'services/ble/kestrel_service.dart';
import 'services/ble/leica_geovid_service.dart';
import 'services/ble/sig_kilo_service.dart';
import 'services/ble/vectronix_terrapin_service.dart';
import 'services/ble/vortex_rangefinder_service.dart';
import 'services/cloud_backup.dart';
import 'services/cloud_sync_service.dart';
import 'services/component_favorites_service.dart';
import 'services/drive_backup_service.dart';
import 'services/entitlement_notifier.dart';
import 'services/bc_truing_service.dart';
import 'services/glossary_first_seen_tracker.dart';
import 'services/hit_probability_service.dart';
import 'services/sight_calibration_service.dart';
import 'services/wez_analysis_service.dart';
import 'services/icloud_backup_service.dart';
import 'services/locale_service.dart';
import 'services/onedrive_backup_service.dart';
import 'services/purchases_service.dart';
import 'services/sensors/cant_service.dart';
import 'services/sensors/inclinometer_service.dart';
import 'services/sensors/magnetometer_service.dart';
import 'services/unit_service.dart';
import 'services/watch_bridge_service.dart';
import 'services/watch_settings_service.dart';
import 'theme/app_theme.dart';
import 'widgets/disclaimer_overlay.dart';

/// Pref key for the legal disclaimer acceptance flag. Versioned so that
/// updating the disclaimer text forces re-acceptance for everyone. Bumped
/// to `_v2` on 2026-05-07 alongside the launch-quality rewrite of the
/// safety disclaimer body — every user who accepted v1 will see the v2
/// content once and have to re-tick the acknowledgement.
const _disclaimerPrefKey = 'disclaimer_accepted_v2';

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
        Provider<DragCurveRepository>(
          create: (_) => DragCurveRepository(database),
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
        // User favorites against reference data (cartridges, reticles,
        // targets) — schema v24. Per-row `isFavorite` columns on
        // UserLoads, UserFirearms, and BallisticProfiles continue to
        // live on those tables; this repository only owns the join
        // table for read-only seed data the user can't mutate.
        Provider<FavoritesRepository>(
          create: (_) => FavoritesRepository(database),
        ),
        Provider<AtmospherePresetRepository>(
          create: (_) => AtmospherePresetRepository(database),
        ),
        Provider<TargetRepository>(
          create: (_) => TargetRepository(database),
        ),
        Provider<RangeDayRepository>(
          create: (_) => RangeDayRepository(database),
        ),
        // Curated manufactured-ammo catalog (schema v23). Read-only
        // surface for the Range Day "Pick a common factory load"
        // empty-state picker, mediated through `CommonLoadsCatalog`.
        Provider<ManufacturedAmmoRepository>(
          create: (_) => ManufacturedAmmoRepository(database),
        ),
        // Stateless service — provided once for the Range Day screen's
        // hit-probability gauge. Pure-functional, so a single instance is
        // safe across the whole tree.
        Provider<HitProbabilityService>(
          create: (_) => const HitProbabilityService(),
        ),
        // Bryan Litz / Applied Ballistics parity services (schema v16).
        // All three are stateless and pure-functional, same as
        // HitProbabilityService — one instance per tree is fine.
        Provider<WezAnalysisService>(
          create: (_) => const WezAnalysisService(),
        ),
        Provider<BcTruingService>(
          create: (_) => const BcTruingService(),
        ),
        Provider<SightCalibrationService>(
          create: (_) => const SightCalibrationService(),
        ),
        ChangeNotifierProvider<AutoSaveService>(
          create: (_) => AutoSaveService(),
        ),
        ChangeNotifierProvider<BeginnerModeService>(
          create: (_) => BeginnerModeService(),
        ),
        // Session-scoped (in-memory) registry of glossary terms the
        // user has already encountered. Backs the first-occurrence
        // emphasis behaviour in [GlossaryLabel] when Beginner Mode
        // is on. No persistence — fresh app launch resets the set.
        Provider<GlossaryFirstSeenTracker>(
          create: (_) => GlossaryFirstSeenTracker(),
        ),
        // Per-kind favorite component NAMES (powder / bullet / primer
        // / brass), persisted to SharedPreferences. Backs the
        // "Favorites first" prefix of the smart-defaults ordering
        // rule in [ComponentField]. Cartridges keep using the
        // existing FavoritesRepository (UserFavorites table) — see
        // the file header on [ComponentFavoritesService] for why
        // the two systems coexist.
        ChangeNotifierProvider<ComponentFavoritesService>(
          create: (_) => ComponentFavoritesService(),
        ),
        ChangeNotifierProvider<UnitService>(
          create: (_) => UnitService(),
        ),
        // User-chosen UI language. `null` means "follow the system
        // locale". MaterialApp below subscribes via Consumer so a
        // language change re-resolves AppLocalizations without a
        // restart.
        ChangeNotifierProvider<LocaleService>(
          create: (_) => LocaleService(),
        ),
        ChangeNotifierProvider<EntitlementNotifier>(
          create: (ctx) => EntitlementNotifier(ctx.read<PurchasesService>()),
        ),
        // AI Smart Import (Pro). Reads OCR'd recipe text the user just
        // photographed and sends it to either LoadOut's hosted Cloudflare
        // Worker proxy or the user's own Anthropic key (BYOK), then
        // returns an improved RecipeDraft. CLAUDE.md §13 / §20 — this is
        // the ONLY surface in the app that talks to Anthropic, and it
        // sees only the OCR'd text the user opted into. Provided once
        // here so PhotoImportReviewScreen and the AI Settings page
        // share the same secure-storage cache + usage counters.
        Provider<AiSmartImportService>(
          create: (ctx) => AiSmartImportService(
            entitlements: ctx.read<EntitlementNotifier>(),
          ),
          dispose: (_, svc) => svc.dispose(),
        ),
        // Cloud Sync (Pro). Continuous, end-to-end-encrypted sync of
        // the user's reloading data to the user's own iCloud / Google
        // Drive / OneDrive — see CLAUDE.md §17 and
        // `lib/services/cloud_sync_service.dart`. Provided once at
        // the root so AutoSaveController, the AppBar indicator, and
        // the Settings → Cloud Sync screen all observe the same
        // notifier. The provider map keys must match
        // `SyncProviderId.*` literals exactly.
        ChangeNotifierProvider<CloudSyncService>(
          create: (ctx) => CloudSyncService(
            database: ctx.read<AppDatabase>(),
            entitlements: ctx.read<EntitlementNotifier>(),
            providers: <String, CloudBackupProvider>{
              SyncProviderId.icloud: ICloudBackupService(),
              SyncProviderId.gdrive: DriveBackupService(),
              SyncProviderId.onedrive: OneDriveBackupService(),
            },
          ),
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
        // Bluetooth rangefinder adapters. One ChangeNotifier per brand so
        // the Devices screen can show per-brand connection state and the
        // Range Day distance picker can read the most recent value from
        // whichever rangefinder the user has connected. All five are
        // BETA — the protocols are reverse-engineered from public
        // sources and need real-device validation.
        ChangeNotifierProvider<SigKiloService>(
          create: (ctx) => SigKiloService(ctx.read<BleService>()),
        ),
        ChangeNotifierProvider<BushnellRangefinderService>(
          create: (ctx) => BushnellRangefinderService(ctx.read<BleService>()),
        ),
        ChangeNotifierProvider<VortexRangefinderService>(
          create: (ctx) => VortexRangefinderService(ctx.read<BleService>()),
        ),
        ChangeNotifierProvider<LeicaGeovidService>(
          create: (ctx) => LeicaGeovidService(ctx.read<BleService>()),
        ),
        ChangeNotifierProvider<VectronixTerrapinService>(
          create: (ctx) => VectronixTerrapinService(ctx.read<BleService>()),
        ),
        // Live device-sensor services for the Range Day Setup section.
        // Provided once and shared so the underlying OS sensor streams
        // are subscribed to only when a screen actually calls start().
        // Both services are graceful no-ops on platforms where the
        // sensors aren't available (macOS, web), exposing
        // `isAvailable == false` so the UI can hide the affordance.
        ChangeNotifierProvider<CantService>(
          create: (_) => CantService(),
        ),
        ChangeNotifierProvider<MagnetometerService>(
          create: (_) => MagnetometerService(),
        ),
        // Sister service to CantService — same accelerometer stream,
        // computed pitch (incline) instead of roll (cant). Used by the
        // Range Day Setup card's "Capture from sensor" button on the
        // incline/decline angle field.
        ChangeNotifierProvider<InclinometerService>(
          create: (_) => InclinometerService(),
        ),
        // Watch bridge + watch settings.
        // The bridge is the transport facade (WatchConnectivity on
        // iOS, Wearable Data Layer on Android). The settings service
        // owns the phone-side preferences (today: shot-capture
        // sensitivity) and pushes them down through the bridge.
        // Provided in this order so the settings service can read the
        // bridge out of context.
        Provider<WatchBridgeService>(
          create: (_) => WatchBridgeService(),
        ),
        ChangeNotifierProvider<WatchSettingsService>(
          create: (ctx) =>
              WatchSettingsService(bridge: ctx.read<WatchBridgeService>()),
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
      child: Consumer<LocaleService>(
        builder: (context, localeService, _) {
          // `localeService.languageCode == null` means "follow the
          // device locale" — we pass `null` to MaterialApp.locale and
          // Flutter's built-in resolution picks the closest supported
          // language from `supportedLocales`, falling back to English
          // when nothing matches.
          final code = localeService.languageCode;
          return MaterialApp(
            title: 'LoadOut',
            theme: AppTheme.light,
            darkTheme: AppTheme.dark,
            themeMode: ThemeMode.dark, // Brand identity defaults to dark.
            locale: code == null ? null : Locale(code),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: const _DisclaimerGate(),
          );
        },
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
    _maybePullCloudSyncOnLaunch();
  }

  /// Best-effort initial Cloud Sync pull on app launch. If the user
  /// has Pro + sync enabled, fire `syncDown` once after the first
  /// frame so any changes made on a different device land before they
  /// start scrolling. Failures are logged-only — we never block the
  /// home screen on cloud reachability.
  void _maybePullCloudSyncOnLaunch() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final svc = context.read<CloudSyncService>();
      if (!svc.isEnabled) return;
      // ignore: discarded_futures
      svc.syncDown();
    });
  }

  Future<void> _initDeepLinks() async {
    final appLinks = AppLinks();

    final initialUri = await appLinks.getInitialLink();
    if (initialUri != null) {
      await _handleEmailLink(initialUri.toString());
    }

    _linkSub = appLinks.uriLinkStream.listen((uri) {
      // ignore: discarded_futures
      _handleEmailLink(uri.toString());
    });
  }

  /// Run [AuthService.tryCompleteEmailLink] and, if the URL is a valid
  /// email-link sign-in URL but the pending email isn't on this device,
  /// prompt the user for it and finish sign-in. Called for both the
  /// cold-start initial URL and warm-app stream URLs.
  Future<void> _handleEmailLink(String link) async {
    final auth = context.read<AuthService>();
    final result = await auth.tryCompleteEmailLink(link);
    if (!mounted) return;
    if (result.outcome == EmailLinkOutcome.needsEmail) {
      await _promptForEmailAndComplete(result.link!);
    }
  }

  /// Cross-device email-link UX. Shows an [AlertDialog] asking for the
  /// email address that requested the link, then calls
  /// [AuthService.completeEmailLinkWithEmail]. On Firebase error (mismatched
  /// email, expired link), surfaces the message via a [SnackBar] so the
  /// user can retry.
  Future<void> _promptForEmailAndComplete(String link) async {
    final email = await showDialog<String>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) => const _EmailLinkPromptDialog(),
    );
    if (email == null || email.isEmpty) return;
    if (!mounted) return;
    final auth = context.read<AuthService>();
    final messenger = ScaffoldMessenger.of(context);
    try {
      await auth.completeEmailLinkWithEmail(link, email);
      // On success, the auth-state stream will rebuild this gate into
      // HomeScreen. No further UI work needed here.
    } on FirebaseAuthException catch (e) {
      if (!mounted) return;
      messenger.showSnackBar(
        SnackBar(content: Text(e.message ?? e.code)),
      );
    } catch (e) {
      if (!mounted) return;
      messenger.showSnackBar(SnackBar(content: Text(e.toString())));
    }
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

/// Modal prompt for the cross-device email-link flow. Returns the entered
/// email via [Navigator.pop], or null if the user cancelled.
class _EmailLinkPromptDialog extends StatefulWidget {
  const _EmailLinkPromptDialog();

  @override
  State<_EmailLinkPromptDialog> createState() => _EmailLinkPromptDialogState();
}

class _EmailLinkPromptDialogState extends State<_EmailLinkPromptDialog> {
  final _controller = TextEditingController();
  final _formKey = GlobalKey<FormState>();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() {
    if (!_formKey.currentState!.validate()) return;
    Navigator.pop(context, _controller.text.trim());
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Confirm your email'),
      content: Form(
        key: _formKey,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text(
              'We need your email address to finish signing you in. This '
              'happens when you opened the sign-in link on a different '
              'device than the one that requested it.',
            ),
            const SizedBox(height: 16),
            TextFormField(
              controller: _controller,
              decoration: const InputDecoration(labelText: 'Email'),
              keyboardType: TextInputType.emailAddress,
              autofillHints: const [AutofillHints.email],
              autofocus: true,
              onFieldSubmitted: (_) => _submit(),
              validator: (v) {
                final value = v?.trim() ?? '';
                if (value.isEmpty) return 'Required';
                if (!value.contains('@')) return 'Enter a valid email';
                return null;
              },
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(onPressed: _submit, child: const Text('Sign in')),
      ],
    );
  }
}
