import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../services/auth_service.dart';
import '../../services/entitlement_notifier.dart';
import '../../theme/app_theme.dart';
import '../firearms/firearms_list_screen.dart';
import '../glossary/glossary_screen.dart';
import '../guide/reloading_guide_screen.dart';
import '../how_it_works/how_it_works_screen.dart';
import '../paywall/paywall_screen.dart';
import '../privacy/privacy_screen.dart';
import '../recipes/recipes_list_screen.dart';
import '../saami/saami_screen.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  /// Switches the home shell's bottom-nav to [index] from anywhere in
  /// the widget tree below it. Used by topic CTAs in
  /// [HowItWorksScreen] that pop back to the shell and then jump to a
  /// specific tab (Recipes, Firearms, SAAMI Specs).
  ///
  /// No-op if no [HomeScreen] ancestor is found, or if [index] is out
  /// of range.
  static void switchTab(BuildContext context, int index) {
    final state = context.findAncestorStateOfType<HomeScreenState>();
    state?.switchTab(index);
  }

  @override
  State<HomeScreen> createState() => HomeScreenState();
}

class HomeScreenState extends State<HomeScreen> {
  int _index = 0;

  static const _titles = ['Recipes', 'Firearms', 'SAAMI Specs'];
  static const _pages = <Widget>[
    RecipesListScreen(),
    FirearmsListScreen(),
    SaamiScreen(),
  ];

  /// Public so [HowItWorksScreen] CTAs can jump to a tab via
  /// [HomeScreen.switchTab]. Bounds-checked and a no-op if [index]
  /// is out of range.
  void switchTab(int index) {
    if (index < 0 || index >= _pages.length) return;
    setState(() => _index = index);
  }

  void _openPaywall() {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => const PaywallScreen(),
        fullscreenDialog: true,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isPro = context.watch<EntitlementNotifier>().isPro;
    return Scaffold(
      drawer: const _MainDrawer(),
      appBar: AppBar(
        title: Text(_titles[_index]),
        actions: [
          IconButton(
            tooltip: isPro ? 'LoadOut Pro' : 'Upgrade to Pro',
            icon: Icon(
              isPro
                  ? Icons.workspace_premium
                  : Icons.workspace_premium_outlined,
            ),
            onPressed: _openPaywall,
          ),
        ],
      ),
      body: IndexedStack(index: _index, children: _pages),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _index,
        onDestinationSelected: (i) => setState(() => _index = i),
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.list_alt_outlined),
            selectedIcon: Icon(Icons.list_alt),
            label: 'Recipes',
          ),
          NavigationDestination(
            icon: Icon(Icons.handshake_outlined),
            selectedIcon: Icon(Icons.handshake),
            label: 'Firearms',
          ),
          NavigationDestination(
            icon: Icon(Icons.straighten_outlined),
            selectedIcon: Icon(Icons.straighten),
            label: 'SAAMI',
          ),
        ],
      ),
    );
  }
}

/// Side drawer for secondary destinations (Glossary, Privacy) and the
/// sign-out action. Reachable from the AppBar's leading hamburger.
class _MainDrawer extends StatelessWidget {
  const _MainDrawer();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Drawer(
      child: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Brand header — charcoal background, brass serif wordmark.
            Container(
              padding: const EdgeInsets.fromLTRB(20, 24, 20, 20),
              color: AppTheme.gunmetalDeep,
              child: Text(
                'LoadOut',
                style: theme.textTheme.titleLarge?.copyWith(
                  fontFamily: 'serif',
                  color: AppTheme.brass,
                  fontWeight: FontWeight.w600,
                  fontSize: 26,
                  letterSpacing: 0.5,
                ),
              ),
            ),
            const SizedBox(height: 8),
            ListTile(
              leading: const Icon(Icons.help_outline),
              title: const Text('How It Works'),
              onTap: () {
                Navigator.of(context).pop();
                Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => const HowItWorksScreen(),
                  ),
                );
              },
            ),
            ListTile(
              leading: const Icon(Icons.auto_stories_outlined),
              title: const Text('Reloading Guide'),
              onTap: () {
                Navigator.of(context).pop();
                Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => const ReloadingGuideScreen(),
                  ),
                );
              },
            ),
            ListTile(
              leading: const Icon(Icons.menu_book_outlined),
              title: const Text('Glossary'),
              onTap: () {
                Navigator.of(context).pop();
                Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => const GlossaryScreen(),
                  ),
                );
              },
            ),
            ListTile(
              leading: const Icon(Icons.privacy_tip_outlined),
              title: const Text('Privacy Policy'),
              onTap: () {
                Navigator.of(context).pop();
                Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => const PrivacyScreen(),
                  ),
                );
              },
            ),
            const Spacer(),
            const Divider(height: 1),
            ListTile(
              leading: const Icon(Icons.logout),
              title: const Text('Sign Out'),
              onTap: () {
                Navigator.of(context).pop();
                context.read<AuthService>().signOut();
              },
            ),
          ],
        ),
      ),
    );
  }
}
