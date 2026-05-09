// FILE: lib/screens/home/home_screen.dart
//
// ============================================================================
// WHAT THIS FILE DOES
// ============================================================================
// The bottom-nav shell that hosts the app's five primary tabs once the user
// has signed in and accepted the disclaimer. `HomeScreen` is a `StatefulWidget`
// that keeps a single `int _index` for the active tab and renders an
// `IndexedStack` over the five page widgets so that each tab's scroll
// position, search query, and form state survive a tab switch instead of
// being thrown away on every navigation.
//
// The five tabs are (in order): `RecipesListScreen`, `FirearmsListScreen`,
// `BatchesListScreen`, `BallisticsScreen`, `SaamiScreen`. The `AppBar`
// updates its title from `_titles[_index]` and exposes a single trailing
// action — a Pro icon (`Icons.workspace_premium`) that opens
// `PaywallScreen` as a fullscreen dialog. The icon style switches based on
// `EntitlementNotifier.isPro` so existing Pro subscribers see a filled
// medallion.
//
// `_MainDrawer` is the left side drawer reachable from the AppBar's leading
// hamburger. It hosts every secondary destination that didn't earn a slot in
// the bottom nav: How It Works, Reloading Guide, Glossary, Brass Lots, Load
// Development, Reloading Steps, Reloading Assistant, Backup & Export,
// Privacy Policy, and Sign Out. The drawer header uses the brass serif
// wordmark on a charcoal background to mirror the brand identity.
//
// ============================================================================
// WHY IT EXISTS IN THE ARCHITECTURE
// ============================================================================
// This is the auth-gated landing surface routed to from `_AuthGate` in
// `lib/app.dart` once a non-null `User?` arrives on the auth `StreamProvider`
// and disclaimer-acceptance has been recorded. It's the home for everything
// the user does day-to-day with their reloading data, so it has to balance
// quick access (bottom nav) against discoverability (drawer) without making
// the chrome feel cluttered.
//
// `HomeScreen.switchTab(context, index)` is a static helper that lets any
// descendant widget jump to a specific tab without holding a reference to
// the state. It walks the tree with `findAncestorStateOfType<HomeScreenState>`
// and is the mechanism behind topic CTAs in `HowItWorksScreen` — those
// screens push themselves onto the navigator, then on completion pop and
// call `HomeScreen.switchTab(context, 4)` to deep-link the user into, say,
// the SAAMI tab.
//
// ============================================================================
// WHY THIS IS HARDER THAN IT LOOKS
// ============================================================================
// The non-obvious piece is `_ScrollableBottomNav`. Material's
// `NavigationBar` is comfortable hosting 3–5 destinations with fixed-tab
// layout, but five tabs already crowd the bar on smaller iPhone widths and
// any future addition would force destinations into a "more" overflow.
// Instead we render our own horizontally-scrollable bar that:
//
// * uses a `LayoutBuilder` to compute a natural per-item width
//   (`constraints.maxWidth / items.length`) and clamps it between
//   `_itemMinWidth` and `_itemMaxWidth` so items either evenly fill the
//   viewport or scroll horizontally — never get squashed unreadably small;
// * keeps a `GlobalKey` per item so `Scrollable.ensureVisible` can pull the
//   selected destination into view after a programmatic tab switch from
//   `HomeScreen.switchTab` (otherwise that would silently change the index
//   to a tab the user can't see);
// * draws its own animated brass-tinted "pill" indicator inside each
//   `_NavItem` rather than using a separate cross-bar indicator widget. The
//   indicator naturally tracks the item it belongs to as the bar scrolls,
//   without bookkeeping.
//
// `IndexedStack` (rather than a `PageView` or per-tab `Navigator`) is a
// deliberate choice — it preserves widget state across tab switches but
// keeps every tab in the tree, which is fine here because all five tabs are
// cheap stream-backed list screens.
//
// The one tab that deliberately does NOT preserve state is Range Day. The
// product requirement is "tapping the Range Day tab always starts a brand-
// new session"; the saved-sessions list moved out of the bottom nav and is
// now reachable as a History action inside the detail screen's AppBar.
// We honor that without abandoning [IndexedStack] for the other tabs by
// keying the [RangeDayDetailScreen] inside the stack with [_rangeDayEpoch],
// a counter that's incremented every time [_onTabSelected] sees the Range
// Day index. The new key forces Flutter's element machinery to discard the
// previous detail-screen state and mount a fresh one, even though the
// surrounding [IndexedStack] structure is otherwise stable.
//
// ============================================================================
// WHO CONSUMES THIS FILE
// ============================================================================
// - `lib/app.dart` (`_AuthGate.build`) — instantiates `HomeScreen()` once
//   the user is signed in and the disclaimer has been accepted.
// - `lib/screens/how_it_works/how_it_works_screen.dart` — calls
//   `HomeScreen.switchTab` to deep-link the user into a specific tab from
//   topic CTAs.
//
// ============================================================================
// SIDE EFFECTS
// ============================================================================
// - Reads `EntitlementNotifier.isPro` via `context.watch` to drive the Pro
//   icon's filled/outlined state.
// - Pushes a fullscreen `PaywallScreen` route via `_openPaywall`.
// - Pushes drawer-destination routes (HowItWorks, ReloadingGuide, Glossary,
//   BrassLotsList, LoadDevelopmentList, ProcessSteps, AiChat, Backup,
//   Privacy) via `MaterialPageRoute`.
// - Calls `AuthService.signOut()` from the drawer's Sign Out tile.

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../services/auth_service.dart';
import '../../services/beginner_mode_service.dart';
import '../../services/entitlement_notifier.dart';
import '../../theme/app_theme.dart';
import '../../utils/responsive.dart';
import '../../widgets/cloud_sync_indicator.dart';
import '../ai_chat/ai_chat_screen.dart';
import '../backup/backup_screen.dart';
import '../ballistics/ballistics_screen.dart';
import '../batches/batches_list_screen.dart';
import '../brass_lots/brass_lots_list_screen.dart';
import '../firearms/firearms_list_screen.dart';
import '../glossary/glossary_screen.dart';
import '../load_development/load_development_list_screen.dart';
import '../process_steps/process_steps_screen.dart';
import '../range_day/range_day_detail_screen.dart';
import '../guide/reloading_guide_screen.dart';
import '../how_it_works/how_it_works_screen.dart';
import '../paywall/paywall_screen.dart';
import '../privacy/privacy_screen.dart';
import '../recipes/recipes_list_screen.dart';
import '../saami/saami_screen.dart';
import '../settings/settings_screen.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  /// Switches the home shell's bottom-nav to [index] from anywhere in
  /// the widget tree below it. Used by topic CTAs in
  /// [HowItWorksScreen] that pop back to the shell and then jump to a
  /// specific tab (Recipes, Firearms, Batches, Ballistics, Range Day,
  /// SAAMI).
  ///
  /// No-op if no [HomeScreen] ancestor is found, or if [index] is out
  /// of range (valid range: 0–5).
  static void switchTab(BuildContext context, int index) {
    final state = context.findAncestorStateOfType<HomeScreenState>();
    state?.switchTab(index);
  }

  @override
  State<HomeScreen> createState() => HomeScreenState();
}

class HomeScreenState extends State<HomeScreen> {
  int _index = 0;

  /// Index of the Range Day tab inside [_navItems] / [_pages]. Held as
  /// a named const so the tap interceptor in [_onTabSelected] doesn't
  /// have to magic-number it.
  static const int _rangeDayTabIndex = 4;

  /// Bumped every time the user taps the Range Day tab. Used as the
  /// key on the [RangeDayDetailScreen] inside the IndexedStack so each
  /// tap re-instantiates the screen with a fresh, empty session draft —
  /// the saved-sessions list moved to a History action inside the
  /// detail screen's AppBar (see `range_day_detail_screen.dart`'s
  /// `_openHistory`). We deliberately keep [IndexedStack] for the
  /// other tabs (so their scroll position / search query / form state
  /// survive a tab switch) and only sacrifice state preservation on
  /// Range Day, where "always start fresh" is the new product
  /// requirement.
  int _rangeDayEpoch = 0;

  static const _titles = [
    'Recipes',
    'Firearms',
    'Batches',
    'Ballistics',
    'Range Day',
    'SAAMI Specs',
  ];

  /// Builds the per-tab pages that back the [IndexedStack]. The Range
  /// Day tab gets a fresh [RangeDayDetailScreen] keyed by
  /// [_rangeDayEpoch] so every tap of the bottom-nav / rail item
  /// throws away the prior draft and starts a brand-new session. All
  /// other tabs are rebuilt with stable identities so their state is
  /// preserved across tab switches.
  List<Widget> _buildPages() {
    return <Widget>[
      const RecipesListScreen(),
      const FirearmsListScreen(),
      const BatchesListScreen(),
      const BallisticsScreen(),
      // Key bound to _rangeDayEpoch — incremented on every tap of the
      // Range Day tab in _onTabSelected — forces the IndexedStack to
      // discard the previous detail-screen state and mount a fresh
      // one. Without this key, IndexedStack would preserve the prior
      // session draft (and its auto-save row, in-flight BLE
      // subscriptions, etc.) across tabs, defeating "tab tap = new
      // session".
      RangeDayDetailScreen(
        key: ValueKey<int>(_rangeDayEpoch),
      ),
      const SaamiScreen(),
    ];
  }

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
      label: 'Range Day',
      icon: Icons.gps_fixed,
      selectedIcon: Icons.gps_fixed,
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
  /// 2=Batches, 3=Ballistics, 4=Range Day, 5=SAAMI.
  ///
  /// Routes through [_onTabSelected] so a deep-link into Range Day
  /// from a topic CTA also bumps the epoch counter and shows a fresh
  /// detail screen, matching the bottom-nav behavior.
  void switchTab(int index) {
    if (index < 0 || index >= _navItems.length) return;
    _onTabSelected(index);
  }

  /// Centralized tab-selection handler. Sets [_index] and, if the
  /// caller is selecting the Range Day tab, bumps [_rangeDayEpoch] so
  /// the [IndexedStack] re-instantiates [RangeDayDetailScreen] with a
  /// fresh state on every tap. Selecting any other tab leaves the
  /// epoch alone — switching away from Range Day and back later
  /// returns to a fresh tab too because the epoch increments on every
  /// Range Day tap regardless of where the user came from.
  void _onTabSelected(int index) {
    if (index < 0 || index >= _navItems.length) return;
    setState(() {
      _index = index;
      if (index == _rangeDayTabIndex) {
        _rangeDayEpoch++;
      }
    });
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
    final beginnerOn = context.watch<BeginnerModeService>().isEnabled;
    // Wide layouts (tablet / desktop / macOS) get a NavigationRail down
    // the left edge instead of the bottom-nav bar; phone layouts keep
    // the existing horizontally-scrollable bottom nav. The drawer stays
    // available on every layout because it hosts secondary destinations
    // that don't fit on the rail (Glossary, Reloading Guide, etc.).
    final isWide = Breakpoints.isWide(context);
    final isDesktop = Breakpoints.isDesktop(context);

    final actions = <Widget>[
      // Glossary shortcut. Pinned to the AppBar in Beginner Mode so a
      // new reloader can look up "CBTO" or "shoulder bump" without
      // hunting through the drawer. Power users find it in the drawer
      // (and turn Beginner Mode off in Settings to declutter the
      // AppBar).
      if (beginnerOn)
        IconButton(
          tooltip: 'Glossary',
          icon: const Icon(Icons.menu_book_outlined),
          onPressed: () => Navigator.of(context).push(
            MaterialPageRoute(
              builder: (_) => const GlossaryScreen(),
            ),
          ),
        ),
      // Cloud Sync indicator + manual reconcile entry point. Hides
      // itself for free users / users without sync enabled by
      // routing the tap to the Cloud Sync screen (where the paywall
      // lives) instead of the reconcile call. Long-press always
      // pushes the screen.
      const CloudSyncAppBarAction(),
      IconButton(
        tooltip: isPro ? 'LoadOut Pro' : 'Upgrade to Pro',
        icon: Icon(
          isPro
              ? Icons.workspace_premium
              : Icons.workspace_premium_outlined,
        ),
        onPressed: _openPaywall,
      ),
    ];

    // Build the page list once per frame. The Range Day entry is
    // keyed by [_rangeDayEpoch] so each Range Day tab tap rebuilds it
    // fresh; the other tabs keep stable identities and preserve their
    // state across switches.
    final pages = _buildPages();

    return Scaffold(
      drawer: const _MainDrawer(),
      appBar: AppBar(
        title: Text(_titles[_index]),
        actions: actions,
      ),
      body: isWide
          ? _WideShell(
              navItems: _navItems,
              selectedIndex: _index,
              onSelected: _onTabSelected,
              extended: isDesktop,
              child: IndexedStack(index: _index, children: pages),
            )
          : IndexedStack(index: _index, children: pages),
      bottomNavigationBar: isWide
          ? null
          : _ScrollableBottomNav(
              items: _navItems,
              selectedIndex: _index,
              onSelected: _onTabSelected,
            ),
    );
  }
}

/// Wide-screen layout: a [NavigationRail] on the left and the active
/// page on the right. Used on tablets, desktops, and macOS. The rail
/// switches to extended mode (icons + labels) at desktop widths so the
/// extra horizontal real estate isn't wasted.
class _WideShell extends StatelessWidget {
  const _WideShell({
    required this.navItems,
    required this.selectedIndex,
    required this.onSelected,
    required this.extended,
    required this.child,
  });

  final List<_NavItemData> navItems;
  final int selectedIndex;
  final ValueChanged<int> onSelected;
  final bool extended;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      children: [
        SafeArea(
          right: false,
          child: NavigationRail(
            selectedIndex: selectedIndex,
            onDestinationSelected: onSelected,
            extended: extended,
            labelType: extended
                ? NavigationRailLabelType.none
                : NavigationRailLabelType.all,
            useIndicator: true,
            // Brass-tinted indicator pill matches the bottom-nav's
            // selected style so the rail reads as the same "selected"
            // metaphor on wider screens.
            indicatorColor: theme.colorScheme.primary.withValues(alpha: 0.18),
            selectedIconTheme: IconThemeData(color: theme.colorScheme.primary),
            selectedLabelTextStyle: TextStyle(
              color: theme.colorScheme.primary,
              fontWeight: FontWeight.w600,
            ),
            destinations: [
              for (final item in navItems)
                NavigationRailDestination(
                  icon: Icon(item.icon),
                  selectedIcon: Icon(item.selectedIcon),
                  label: Text(item.label),
                ),
            ],
          ),
        ),
        const VerticalDivider(width: 1, thickness: 1),
        Expanded(child: child),
      ],
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
              leading: const Icon(Icons.settings_outlined),
              title: const Text('Settings'),
              onTap: () {
                Navigator.of(context).pop();
                Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => const SettingsScreen(),
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
