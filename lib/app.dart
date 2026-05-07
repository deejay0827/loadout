import 'dart:async';

import 'package:app_links/app_links.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'database/database.dart';
import 'repositories/batch_repository.dart';
import 'repositories/brass_lot_repository.dart';
import 'repositories/component_repository.dart';
import 'repositories/firearm_repository.dart';
import 'repositories/load_development_repository.dart';
import 'repositories/process_step_repository.dart';
import 'repositories/recipe_repository.dart';
import 'screens/auth/login_screen.dart';
import 'screens/disclaimer/disclaimer_screen.dart';
import 'screens/home/home_screen.dart';
import 'services/auth_service.dart';
import 'services/entitlement_notifier.dart';
import 'services/purchases_service.dart';
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
        ChangeNotifierProvider<EntitlementNotifier>(
          create: (ctx) => EntitlementNotifier(ctx.read<PurchasesService>()),
        ),
        StreamProvider<User?>(
          create: (context) => context.read<AuthService>().authStateChanges,
          initialData: null,
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
