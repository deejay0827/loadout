// FILE: lib/screens/onboarding/onboarding_screen.dart
//
// ============================================================================
// WHAT THIS FILE DOES
// ============================================================================
// Renders the "Quick Tour" — an eight-page horizontal walkthrough that
// introduces LoadOut's features. Reachable as the Quick Tour target from
// `HowItWorksScreen` and from the legacy "How To Use LoadOut" drawer
// entry. The screen is intentionally linear: swipe (or tap "Next")
// forward, swipe back, or tap "Skip" / "Get Started" at any point to
// dismiss.
//
// The eight pages, in order:
//
//   1. Welcome to LoadOut
//   2. Track Your Recipes
//   3. Catalog Your Firearms
//   4. Cartridge Specifications (SAAMI / CIP)
//   5. Reloading Glossary
//   6. LoadOut Pro                 (has a "View Pro Plans" inline CTA)
//   7. Safety First
//   8. Ready to Reload             ("Get Started" CTA, dismisses)
//
// Each page is described by the file-private `_OnboardingPage` data
// class — icon, title, list of bullet strings, and an optional
// `actionLabel` + `_PageActionType` pair. `_PageActionType.viewPro`
// pushes `PaywallScreen` as a fullscreen dialog. `_PageActionType.finish`
// closes the onboarding flow.
//
// Layout pieces:
//
//   - `PageView.builder` drives the horizontal swipe behaviour.
//   - `_OnboardingPageView` renders one page: a 96px brass-coloured
//     hero icon, a centered title, a list of bullets (each bullet is
//     a small brass dot + body-large text), and the optional inline
//     action button.
//   - `_DotIndicator` is a custom-painted page indicator. The active
//     dot animates wider via `AnimatedContainer`. Implemented inline
//     to avoid pulling in a third-party indicator package for what's
//     essentially a few `Container`s in a `Row`.
//   - The bottom bar has a "Back" button (disabled on page 0) and a
//     primary "Next" / "Get Started" button (label flips on the last
//     page). The AppBar has a "Skip" text button on the right.
//
// On dismiss (via "Skip", "Get Started", or the action-finish
// callback), `_markSeenAndClose` writes `true` to the
// `OnboardingScreen.seenPrefKey` SharedPreferences key
// (`'onboarding_seen_v1'`) fire-and-forget — the disk write is not
// awaited because it doesn't need to block the pop. Future versions
// of the app can re-show the tour on a major UX change by bumping the
// suffix to `_v2` etc.
//
// ============================================================================
// WHY IT EXISTS IN THE ARCHITECTURE
// ============================================================================
// The onboarding flow gives a brand-new user a guided overview of
// LoadOut's primary surfaces (Recipes, Firearms, SAAMI, Glossary, Pro,
// Safety) before they start tapping around the home screen. It's
// optional — the user can skip out — but it's the easiest entry-point
// for someone who downloaded the app on a recommendation and doesn't
// know what reloading software is supposed to look like.
//
// `HowItWorksScreen` exposes this screen as the "Quick Tour" card at
// the top of its topical menu. Reaching the tour through the topical
// menu rather than auto-launching it on first run is deliberate — we
// preserve the user's ability to immediately start using the app, with
// the tour available as an opt-in refresher.
//
// ============================================================================
// WHY THIS IS HARDER THAN IT LOOKS
// ============================================================================
// Two things worth knowing:
//
//   1. The custom `_DotIndicator` exists to avoid a `smooth_page_indicator`
//      style dependency just for one screen. The three `AnimatedContainer`s
//      in a `Row` give us a perfectly fine animated indicator without
//      pinning another package. If you find yourself reaching for a
//      package, ask first whether the same effect can be done in a few
//      `Container`s.
//   2. The `assert((actionLabel == null) == (actionType == null), ...)`
//      in `_OnboardingPage` protects the data-class invariant that
//      action label and action type are either both set or both null.
//      Forgetting one of the two would compile but produce a card
//      with no action.
//
// ============================================================================
// WHO CONSUMES THIS FILE
// ============================================================================
// - `lib/screens/how_it_works/how_it_works_screen.dart` — the Quick
//   Tour card pushes this screen as a `MaterialPageRoute(fullscreenDialog:
//   true)`.
// - `lib/screens/home/home_screen.dart` — the legacy "How To Use
//   LoadOut" drawer entry pushes this screen.
//
// ============================================================================
// SIDE EFFECTS
// ============================================================================
// - Writes `true` to the SharedPreferences key
//   `OnboardingScreen.seenPrefKey` ('onboarding_seen_v1') on dismiss.
// - Indirectly: pushes `PaywallScreen` for the `viewPro` action,
//   which has its own RevenueCat-driven side effects.

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../theme/app_theme.dart';
import '../paywall/paywall_screen.dart';

/// Multi-page guided walkthrough that introduces LoadOut's features.
/// Reachable from the side drawer ("How To Use LoadOut"). After the user
/// completes or skips the flow, a SharedPreferences flag is set so future
/// versions can suppress an auto-show on first launch.
class OnboardingScreen extends StatefulWidget {
  const OnboardingScreen({super.key});

  /// Persisted under this key once the user has completed or skipped
  /// onboarding. Versioned so we can re-show on major UX changes by
  /// bumping to `_v2` etc.
  static const String seenPrefKey = 'onboarding_seen_v1';

  @override
  State<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends State<OnboardingScreen> {
  final _controller = PageController();
  int _index = 0;

  late final List<_OnboardingPage> _pages = [
    _OnboardingPage(
      icon: Icons.workspace_premium,
      title: 'Welcome to LoadOut',
      bullets: const [
        'Your local-first reloading tracker.',
        'All data stays on this device — your loads, firearms, and components '
            'never leave.',
        "Tap 'Next' to learn how to use the app.",
      ],
    ),
    _OnboardingPage(
      icon: Icons.receipt_long,
      title: 'Track Your Recipes',
      bullets: const [
        "A 'recipe' is your specific load formula: caliber, powder, charge, "
            'bullet, primer, brass.',
        'Use the Recipes tab (bottom-left) to add, edit, and search your '
            'loads.',
        "Toggle 'Detailed' or 'All' to see advanced fields like CBTO, seating "
            'depth, and shoulder bump.',
      ],
    ),
    _OnboardingPage(
      icon: Icons.handshake,
      title: 'Catalog Your Firearms',
      bullets: const [
        'Add each rifle, pistol, or shotgun to track shots fired and barrel '
            'life.',
        'Pick from the reference catalog (Ruger, Tikka, Bergara, etc.) or add '
            'a custom build.',
        'Each firearm shows total shots fired across all your recipes.',
      ],
    ),
    _OnboardingPage(
      icon: Icons.straighten,
      title: 'Cartridge Specifications',
      bullets: const [
        'Look up SAAMI/CIP dimensions for 200+ cartridges.',
        'Pick any cartridge to see bullet, case, body, neck, shoulder, rim, '
            'and pressure data.',
        'Pro: technical drawings of cartridge and chamber profiles.',
      ],
    ),
    _OnboardingPage(
      icon: Icons.menu_book,
      title: 'Reloading Glossary',
      bullets: const [
        "Quick reference for reloading terms — from 'CBTO' to 'shoulder "
            "bump'.",
        'Open from the side menu (top-left).',
        'Search for a term or browse alphabetically.',
      ],
    ),
    _OnboardingPage(
      icon: Icons.workspace_premium_outlined,
      title: 'LoadOut Pro',
      bullets: const [
        'Pro unlocks: technical cartridge drawings, advanced ballistics, '
            'future cloud backup.',
        'Three plans: monthly, yearly, lifetime.',
        'Restore prior purchases from the paywall screen.',
      ],
      actionLabel: 'View Pro Plans',
      actionType: _PageActionType.viewPro,
    ),
    _OnboardingPage(
      icon: Icons.warning_amber,
      title: 'Safety First',
      bullets: const [
        'Reloading ammunition is inherently dangerous.',
        'Always cross-reference loads against current published manuals '
            '(Hodgdon, Sierra, Hornady, etc.).',
        'LoadOut is reference data — not a substitute for proper training, '
            'manuals, or experience.',
        "If you're new to reloading, work with someone experienced before "
            'producing live ammo.',
      ],
    ),
    _OnboardingPage(
      icon: Icons.rocket_launch,
      title: 'Ready to Reload',
      bullets: const [
        'Start by adding your first firearm or recipe.',
        'All your data stays on this device, always.',
        "Tap 'Get Started' to begin.",
      ],
      actionLabel: 'Get Started',
      actionType: _PageActionType.finish,
    ),
  ];

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  /// Persist the "seen" flag and pop. Fire-and-forget — we don't block
  /// the close on the disk write.
  void _markSeenAndClose([bool result = true]) {
    SharedPreferences.getInstance().then((prefs) {
      prefs.setBool(OnboardingScreen.seenPrefKey, true);
    });
    Navigator.of(context).pop(result);
  }

  void _onNext() {
    if (_index >= _pages.length - 1) {
      _markSeenAndClose();
      return;
    }
    _controller.nextPage(
      duration: const Duration(milliseconds: 280),
      curve: Curves.easeInOut,
    );
  }

  void _onBack() {
    if (_index == 0) return;
    _controller.previousPage(
      duration: const Duration(milliseconds: 280),
      curve: Curves.easeInOut,
    );
  }

  void _openPaywall() {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => const PaywallScreen(),
        fullscreenDialog: true,
      ),
    );
  }

  void _handlePageAction(_PageActionType type) {
    switch (type) {
      case _PageActionType.viewPro:
        _openPaywall();
      case _PageActionType.finish:
        _markSeenAndClose();
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isLast = _index == _pages.length - 1;
    final isFirst = _index == 0;

    return Scaffold(
      appBar: AppBar(
        title: const Text('How To Use LoadOut'),
        actions: [
          TextButton(
            onPressed: _markSeenAndClose,
            child: Text(
              'Skip',
              style: TextStyle(
                color: theme.colorScheme.primary,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: PageView.builder(
                controller: _controller,
                onPageChanged: (i) => setState(() => _index = i),
                itemCount: _pages.length,
                itemBuilder: (context, i) {
                  final page = _pages[i];
                  return _OnboardingPageView(
                    page: page,
                    onAction: page.actionType == null
                        ? null
                        : () => _handlePageAction(page.actionType!),
                  );
                },
              ),
            ),
            const SizedBox(height: 8),
            _DotIndicator(
              count: _pages.length,
              activeIndex: _index,
              activeColor: theme.colorScheme.primary,
              inactiveColor: theme.colorScheme.onSurface.withValues(alpha: 0.25),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
              child: Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      onPressed: isFirst ? null : _onBack,
                      child: const Text('Back'),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: FilledButton(
                      onPressed: _onNext,
                      child: Text(isLast ? 'Get Started' : 'Next'),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Action a page may expose via an inline button below its bullet content.
enum _PageActionType { viewPro, finish }

/// Plain data container for a single onboarding page. All copy lives here
/// rather than in the build method to keep the screen body readable.
class _OnboardingPage {
  const _OnboardingPage({
    required this.icon,
    required this.title,
    required this.bullets,
    this.actionLabel,
    this.actionType,
  }) : assert(
          (actionLabel == null) == (actionType == null),
          'actionLabel and actionType must be set together',
        );

  final IconData icon;
  final String title;
  final List<String> bullets;
  final String? actionLabel;
  final _PageActionType? actionType;
}

/// Renders a single page: hero icon, title, bullet list, optional action
/// button. Scrolls if content exceeds available height (shorter screens).
class _OnboardingPageView extends StatelessWidget {
  const _OnboardingPageView({required this.page, this.onAction});

  final _OnboardingPage page;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(24, 32, 24, 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Icon(
            page.icon,
            size: 96,
            color: AppTheme.brass,
          ),
          const SizedBox(height: 24),
          Text(
            page.title,
            style: theme.textTheme.headlineMedium,
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 24),
          for (final bullet in page.bullets)
            Padding(
              padding: const EdgeInsets.only(bottom: 14),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Padding(
                    padding: const EdgeInsets.only(top: 6, right: 12),
                    child: Container(
                      width: 6,
                      height: 6,
                      decoration: BoxDecoration(
                        color: theme.colorScheme.primary,
                        shape: BoxShape.circle,
                      ),
                    ),
                  ),
                  Expanded(
                    child: Text(
                      bullet,
                      style: theme.textTheme.bodyLarge,
                    ),
                  ),
                ],
              ),
            ),
          if (page.actionLabel != null && onAction != null) ...[
            const SizedBox(height: 16),
            FilledButton.tonal(
              onPressed: onAction,
              child: Text(page.actionLabel!),
            ),
          ],
        ],
      ),
    );
  }
}

/// Custom animated dot indicator — avoids adding a new dependency just for
/// this. Active dot is wider and uses the brass/primary colour; inactive
/// dots are dimmed.
class _DotIndicator extends StatelessWidget {
  const _DotIndicator({
    required this.count,
    required this.activeIndex,
    required this.activeColor,
    required this.inactiveColor,
  });

  final int count;
  final int activeIndex;
  final Color activeColor;
  final Color inactiveColor;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        for (int i = 0; i < count; i++)
          AnimatedContainer(
            duration: const Duration(milliseconds: 240),
            curve: Curves.easeOut,
            margin: const EdgeInsets.symmetric(horizontal: 4),
            width: i == activeIndex ? 22 : 8,
            height: 8,
            decoration: BoxDecoration(
              color: i == activeIndex ? activeColor : inactiveColor,
              borderRadius: BorderRadius.circular(4),
            ),
          ),
      ],
    );
  }
}
