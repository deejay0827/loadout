import 'dart:async';

import 'package:app_links/app_links.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'repositories/component_repository.dart';
import 'repositories/load_repository.dart';
import 'screens/auth/login_screen.dart';
import 'screens/home/home_screen.dart';
import 'services/auth_service.dart';
import 'theme/app_theme.dart';

class LoadOutApp extends StatelessWidget {
  const LoadOutApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        Provider<AuthService>(create: (_) => AuthService()),
        Provider<LoadRepository>(create: (_) => LoadRepository()),
        Provider<ComponentRepository>(create: (_) => ComponentRepository()),
        StreamProvider<User?>(
          create: (context) => context.read<AuthService>().authStateChanges,
          initialData: null,
        ),
      ],
      child: MaterialApp(
        title: 'LoadOut',
        theme: AppTheme.light,
        darkTheme: AppTheme.dark,
        home: const _AuthGate(),
      ),
    );
  }
}

class _AuthGate extends StatefulWidget {
  const _AuthGate();

  @override
  State<_AuthGate> createState() => _AuthGateState();
}

class _AuthGateState extends State<_AuthGate> {
  StreamSubscription<Uri>? _linkSub;

  @override
  void initState() {
    super.initState();
    _initDeepLinks();
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

  @override
  void dispose() {
    _linkSub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final user = context.watch<User?>();
    return user == null ? const LoginScreen() : const HomeScreen();
  }
}
