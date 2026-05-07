import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../services/auth_service.dart';
import '../../services/entitlement_notifier.dart';
import '../../theme/app_theme.dart';
import '../ai_chat/ai_chat_screen.dart';
import '../backup/backup_screen.dart';
import '../ballistics/ballistics_screen.dart';
import '../batches/batches_list_screen.dart';
import '../brass_lots/brass_lots_list_screen.dart';
import '../firearms/firearms_list_screen.dart';
import '../glossary/glossary_screen.dart';
import '../load_development/load_development_list_screen.dart';
import '../process_steps/process_steps_screen.dart';
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
  /// specific tab (Recipes, Firearms, Batches, Ballistics, SAAMI).
  ///
  /// No-op if no [HomeScreen] ancestor is found, or if [index] is out
  /// of range (valid range: 0–4).
  static void switchTab(BuildContext context, int index) {
    final state = context.findAncestorStateOfType<HomeScreenState>();
    state?.switchTab(index);
  }

  @override
  State<HomeScreen> createState() => HomeScreenState();
}

class HomeScreenState extends State<HomeScreen> {
  int _index = 0;

  static const _titles = [
    'Recipes',
    'Firearms',
    'Batches',
    'Ballistics',
    'SAAMI Specs',
  ];

  static const _pages = <Widget>[
    RecipesListScreen(),
    FirearmsListScreen(),
    BatchesListScreen(),
    BallisticsScreen(),
    SaamiScreen(),
  ];

  static const _navItems = <_NavItemData>[
    _NavItemData(
      label: 'Recipes',
      icon: Icons.list_alt_outlined,
      selectedIcon: Icons.list_alt,
    ),
    _NavItemData(
      label: 'Firearms',
      icon: Icons.handshake_outlined,
      selectedIcon: Icons.handshake,
    ),
    _NavItemData(
      label: 'Batches',
      icon: Icons.layers_outlined,
      selectedIcon: Icons.layers,
    ),
    _NavItemData(
      label: 'Ballistics',
      icon: Icons.calculate_outlined,
      selectedIcon: Icons.calculate,
    ),
    _NavItemData(
      label: 'SAAMI',
      icon: Icons.straighten_outlined,
      selectedIcon: Icons.straighten,
    ),
  ];

  /// Public so [HowItWorksScreen] CTAs can jump to a tab via
  /// [HomeScreen.switchTab]. Bounds-checked and a no-op if [index]
  /// is out of range. Valid indexes: 0=Recipes, 1=Firearms,
  /// 2=Batches, 3=Ballistics, 4=SAAMI.
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
      bottomNavigationBar: _ScrollableBottomNav(
        items: _navItems,
        selectedIndex: _index,
        onSelected: (i) => setState(() => _index = i),
      ),
    );
  }
}

/// Static metadata for one slot in [_ScrollableBottomNav].
class _NavItemData {
  const _NavItemData({
    required this.label,
    required this.icon,
    required this.selectedIcon,
  });

  final String label;
  final IconData icon;
  final IconData selectedIcon;
}

/// Horizontally-scrollable replacement for [NavigationBar].
///
/// Keeps the same selected-index semantics as [NavigationBar], but
/// lets us host more than the 3–5 destinations Material's fixed-tab
/// widget is comfortable with. On a typical iPhone width the five
/// current items fit without scrolling; if more get added the bar
/// scrolls horizontally. Brass-tinted pill marks the active tab and
/// animates between positions.
class _ScrollableBottomNav extends StatefulWidget {
  const _ScrollableBottomNav({
    required this.items,
    required this.selectedIndex,
    required this.onSelected,
  });

  final List<_NavItemData> items;
  final int selectedIndex;
  final ValueChanged<int> onSelected;

  @override
  State<_ScrollableBottomNav> createState() => _ScrollableBottomNavState();
}

class _ScrollableBottomNavState extends State<_ScrollableBottomNav> {
  static const double _barHeight = 72;
  static const double _itemMinWidth = 64;
  static const double _itemMaxWidth = 96;
  static const Duration _animDuration = Duration(milliseconds: 200);

  final ScrollController _scrollController = ScrollController();
  // One key per item so we can ensure-visible the selected one.
  late List<GlobalKey> _itemKeys = List<GlobalKey>.generate(
    widget.items.length,
    (_) => GlobalKey(),
  );

  @override
  void didUpdateWidget(covariant _ScrollableBottomNav oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.items.length != oldWidget.items.length) {
      _itemKeys = List<GlobalKey>.generate(
        widget.items.length,
        (_) => GlobalKey(),
      );
    }
    if (widget.selectedIndex != oldWidget.selectedIndex) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _scrollSelectedIntoView();
      });
    }
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  void _scrollSelectedIntoView() {
    if (!mounted) return;
    final ctx = _itemKeys[widget.selectedIndex].currentContext;
    if (ctx == null) return;
    Scrollable.ensureVisible(
      ctx,
      duration: _animDuration,
      curve: Curves.easeOut,
      alignment: 0.5,
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Material(
      // Match AppBar / scaffold so the bar reads as a continuation of
      // the chrome rather than a floating element.
      color: scheme.surface,
      elevation: 0,
      child: SafeArea(
        top: false,
        child: SizedBox(
          height: _barHeight,
          child: LayoutBuilder(
            builder: (context, constraints) {
              // Try to make every item fit on screen; once the
              // natural width drops below `_itemMinWidth` we let the
              // ListView take over and scroll horizontally.
              final naturalWidth =
                  constraints.maxWidth / widget.items.length;
              final itemWidth = naturalWidth.clamp(
                _itemMinWidth,
                _itemMaxWidth,
              );
              return ListView.builder(
                controller: _scrollController,
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 8),
                physics: const BouncingScrollPhysics(),
                itemCount: widget.items.length,
                itemBuilder: (context, i) {
                  final item = widget.items[i];
                  final selected = i == widget.selectedIndex;
                  return _NavItem(
                    key: _itemKeys[i],
                    width: itemWidth,
                    data: item,
                    selected: selected,
                    onTap: () => widget.onSelected(i),
                    primaryColor: scheme.primary,
                    indicatorColor: scheme.primary.withValues(alpha: 0.18),
                    unselectedColor: scheme.onSurface.withValues(alpha: 0.7),
                    fadedColor: scheme.onSurface.withValues(alpha: 0.65),
                    animDuration: _animDuration,
                  );
                },
              );
            },
          ),
        ),
      ),
    );
  }
}

/// One slot in the scrollable bar. Renders its own animated pill
/// background instead of a separate cross-bar indicator widget — that
/// way the indicator naturally moves with the item it belongs to and
/// we get the scroll-aware behavior for free.
class _NavItem extends StatelessWidget {
  const _NavItem({
    super.key,
    required this.width,
    required this.data,
    required this.selected,
    required this.onTap,
    required this.primaryColor,
    required this.indicatorColor,
    required this.unselectedColor,
    required this.fadedColor,
    required this.animDuration,
  });

  final double width;
  final _NavItemData data;
  final bool selected;
  final VoidCallback onTap;
  final Color primaryColor;
  final Color indicatorColor;
  final Color unselectedColor;
  final Color fadedColor;
  final Duration animDuration;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: width,
      child: Semantics(
        label: data.label,
        button: true,
        selected: selected,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(20),
          child: Center(
            child: AnimatedContainer(
              duration: animDuration,
              curve: Curves.easeOut,
              margin: const EdgeInsets.symmetric(
                vertical: 8,
                horizontal: 4,
              ),
              padding: const EdgeInsets.symmetric(
                vertical: 6,
                horizontal: 8,
              ),
              decoration: BoxDecoration(
                color: selected ? indicatorColor : Colors.transparent,
                borderRadius: BorderRadius.circular(20),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  AnimatedSwitcher(
                    duration: animDuration,
                    transitionBuilder: (child, anim) =>
                        ScaleTransition(scale: anim, child: child),
                    child: Icon(
                      selected ? data.selectedIcon : data.icon,
                      key: ValueKey(selected),
                      size: 24,
                      color: selected ? primaryColor : unselectedColor,
                    ),
                  ),
                  const SizedBox(height: 2),
                  AnimatedDefaultTextStyle(
                    duration: animDuration,
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight:
                          selected ? FontWeight.w600 : FontWeight.w500,
                      color: selected ? primaryColor : fadedColor,
                      letterSpacing: 0.2,
                    ),
                    child: Text(
                      data.label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      textAlign: TextAlign.center,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
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
              leading: const Icon(Icons.inventory_2_outlined),
              title: const Text('Brass Lots'),
              onTap: () {
                Navigator.of(context).pop();
                Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => const BrassLotsListScreen(),
                  ),
                );
              },
            ),
            ListTile(
              leading: const Icon(Icons.science_outlined),
              title: const Text('Load Development'),
              onTap: () {
                Navigator.of(context).pop();
                Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => const LoadDevelopmentListScreen(),
                  ),
                );
              },
            ),
            ListTile(
              leading: const Icon(Icons.checklist_outlined),
              title: const Text('Reloading Steps'),
              onTap: () {
                Navigator.of(context).pop();
                Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => const ProcessStepsScreen(),
                  ),
                );
              },
            ),
            ListTile(
              leading: const Icon(Icons.smart_toy_outlined),
              title: const Text('Reloading Assistant'),
              onTap: () {
                Navigator.of(context).pop();
                Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => const AiChatScreen(),
                  ),
                );
              },
            ),
            ListTile(
              leading: const Icon(Icons.cloud_upload_outlined),
              title: const Text('Backup & Export'),
              onTap: () {
                Navigator.of(context).pop();
                Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => const BackupScreen(),
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
