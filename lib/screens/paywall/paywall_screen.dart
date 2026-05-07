// FILE: lib/screens/paywall/paywall_screen.dart
//
// ============================================================================
// WHAT THIS FILE DOES
// ============================================================================
// Renders the LoadOut Pro paywall — the full-screen sheet that asks the
// user to purchase the `pro` entitlement. Reachable from the home screen,
// from the onboarding "View Pro Plans" button, and automatically from
// any `ensurePro(context)` action gate when a non-Pro user attempts a
// gated feature.
//
// Layout (top → bottom):
//
//   1. `_FeaturesShowcase` — gradient-backed hero with the "LoadOut Pro"
//      title, a short subtitle, and a frosted card listing the seven
//      headline Pro features. This is the "what you get" upsell — the
//      same surface the user always sees, regardless of whether
//      RevenueCat has real keys configured yet.
//   2. Offerings — either `_PlaceholderState` (when keys are placeholder
//      `REPLACE_ME_*` values), the loading spinner, the `_ErrorState`,
//      or one `_PackageCard` per `Package` in the current offering.
//      The Lifetime card gets a small brass "Best value" badge.
//   3. Restore Purchases text button.
//   4. Auto-renew / Terms footnote.
//
// The page is built around RevenueCat (`purchases_flutter`), the in-app
// purchase platform LoadOut uses to abstract over App Store and Play
// Store IAP. RevenueCat's API surface relevant here:
//
//   - `PurchasesService.getOfferings()` — async, fetches the current
//     `Offerings` bundle from the RevenueCat backend. This contains
//     the available `Package`s for sale (Yearly, Lifetime).
//   - `PurchasesService.purchase(pkg)` — kicks off the platform's IAP
//     sheet for one `Package`, blocks until the OS sheet resolves.
//   - `PurchasesService.restorePurchases()` — re-fetches the user's
//     active entitlements (used by the "Restore Purchases" button).
//   - `EntitlementNotifier.refresh()` — re-reads the customer info
//     after a successful purchase / restore so the rest of the app
//     observes the new `pro` entitlement immediately.
//
// On `initState`, `_loadOfferings()` either short-circuits to `null`
// (when `RevenueCatConfig.isPlaceholder` — i.e. API keys are still
// `REPLACE_ME_*`, so the SDK isn't usable) or calls
// `PurchasesService.getOfferings()`. The result drives a `FutureBuilder`
// that renders one of three states:
//
//   - `_PlaceholderState`  — when keys are placeholders. Friendly
//     "Pro is not yet available" card with a construction icon.
//   - Loading spinner       — while the offerings request is in flight.
//   - `_ErrorState`         — when offerings come back empty (network
//     failure, mis-configured RevenueCat dashboard). Has a Retry button
//     that rebuilds the future.
//   - A column of `_PackageCard`s — for each `Package` in the current
//     offering. Each card has a title (`_packageTitle` falls back to
//     the package type name), the localized price string, and an
//     optional intro-price badge ("Intro: ..."). The "Subscribe"
//     button kicks off `_onPurchase(pkg)`.
//
// `_onPurchase` calls `purchases.purchase(pkg)`, refreshes the
// entitlement notifier, and on success pops the screen with `true`.
// User-cancelled purchases (`PurchasesErrorCode.purchaseCancelledError`)
// are silent — no snackbar, just the user back on the paywall. Other
// errors show a snackbar.
//
// `_onRestore` calls `purchases.restorePurchases()`, refreshes
// entitlements, and shows a snackbar saying either "Purchases restored"
// (and pops with true) or "No previous purchases found."
//
// While either operation is in flight, `_isWorking` is true and the
// screen overlays a translucent black `ColoredBox` with a centered
// progress indicator so the user can't double-tap.
//
// ============================================================================
// WHY IT EXISTS IN THE ARCHITECTURE
// ============================================================================
// The paywall is the single point in the app where the user crosses from
// "free tier" to "Pro tier." Its job is to render the available SKUs,
// kick off the platform's IAP sheet, and let the rest of the app notice
// the new entitlement via `EntitlementNotifier`. After a successful
// purchase or restore, the home screen, the AI chat screen, and the
// ballistics screen all see `EntitlementNotifier.isPro == true` and
// stop rendering their `ProGate` upgrade prompts.
//
// The `_FeaturesShowcase` component fronts the offerings with concrete
// "what you get" copy. App Store reviewers and conversion analytics both
// dislike paywalls that show only price cards with no description of the
// benefit. The seven feature rows correspond 1:1 to features that are
// actually `ProGate`-wrapped in the app today (cartridge drawings, the
// ballistics calculator, AI chat, load development, custom fields) plus
// the two evergreen value props (cloud backup, future Pro features).
//
// `_PlaceholderState` and `_ErrorState` are deliberately separate widgets
// rather than ad-hoc inline blocks. Both render a centered card with an
// icon, a title, a body, and (for the error) a retry button — the same
// pattern as the placeholder/error states in other screens.
//
// ============================================================================
// WHY THIS IS HARDER THAN IT LOOKS
// ============================================================================
// IAP plumbing is unforgiving. A few things this file gets right that
// are easy to get wrong:
//
//   1. `PurchasesErrorHelper.getErrorCode(e)` is the only reliable way
//      to distinguish a user cancellation from a real failure across
//      iOS and Android. Treating "user cancelled" as a snackbar-worthy
//      error is one of the most-complained-about IAP UX bugs.
//   2. `await entitlements.refresh()` AFTER the purchase, BEFORE we
//      pop the screen. Without that, the home screen behind the paywall
//      might rebuild with stale `isPro = false` state and re-show the
//      gate.
//   3. Restoring purchases must be available from the paywall AND must
//      tell the user when no prior purchases exist. App Store review
//      will reject a build that lacks a discoverable restore path.
//
// `RevenueCatConfig.isPlaceholder` lets development builds run without
// real RevenueCat credentials. The placeholder path skips the SDK call
// entirely — calling `getOfferings()` against a placeholder key throws
// rather than failing gracefully. The features showcase still renders
// in this state — only the offerings region falls back to a
// "Pro is not yet available" card.
//
// ============================================================================
// WHO CONSUMES THIS FILE
// ============================================================================
// - `lib/screens/home/home_screen.dart` — drawer entries and Pro CTAs
//   push this screen as a `MaterialPageRoute(fullscreenDialog: true)`.
// - `lib/widgets/pro_gate.dart` — `ensurePro(context)` pushes this
//   screen when a user attempts a Pro action without entitlement.
// - `lib/screens/onboarding/onboarding_screen.dart` — the "View Pro
//   Plans" button on the onboarding Pro page pushes this screen.
// - `lib/screens/how_it_works/how_it_works_screen.dart` — the
//   "LoadOut Pro" topic CTA pushes this screen.
//
// ============================================================================
// SIDE EFFECTS
// ============================================================================
// - Network: RevenueCat SDK calls (offerings fetch, purchase, restore).
//   These also reach the App Store / Play Store via the platform IAP
//   sheets.
// - Triggers the platform's native IAP UI sheet. The user is
//   redirected to Apple/Google's purchase confirmation flow, then
//   returned to LoadOut.
// - Mutates `EntitlementNotifier` after every purchase/restore via
//   `entitlements.refresh()`.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:purchases_flutter/purchases_flutter.dart';

import '../../services/entitlement_notifier.dart';
import '../../services/purchases_service.dart';
import '../../services/revenue_cat_config.dart';
import '../../theme/app_theme.dart';

/// Full-screen paywall presented from the home screen and from any
/// `ensurePro` gate. Loads offerings from RevenueCat lazily and shows
/// the available packages as tappable cards.
class PaywallScreen extends StatefulWidget {
  const PaywallScreen({super.key});

  @override
  State<PaywallScreen> createState() => _PaywallScreenState();
}

class _PaywallScreenState extends State<PaywallScreen> {
  late Future<Offerings?> _offeringsFuture;
  bool _isWorking = false;

  @override
  void initState() {
    super.initState();
    _offeringsFuture = _loadOfferings();
  }

  Future<Offerings?> _loadOfferings() {
    if (RevenueCatConfig.isPlaceholder) {
      // Skip the SDK call entirely in development — keys aren't real yet.
      return Future.value(null);
    }
    return context.read<PurchasesService>().getOfferings();
  }

  Future<void> _onPurchase(Package pkg) async {
    final purchases = context.read<PurchasesService>();
    final entitlements = context.read<EntitlementNotifier>();
    setState(() => _isWorking = true);
    try {
      await purchases.purchase(pkg);
      await entitlements.refresh();
      if (!mounted) return;
      Navigator.of(context).pop(true);
    } on PlatformException catch (e) {
      final code = PurchasesErrorHelper.getErrorCode(e);
      if (code == PurchasesErrorCode.purchaseCancelledError) {
        // User dismissed the platform sheet — silent no-op.
      } else {
        _showSnack(e.message ?? 'Purchase failed.');
      }
    } catch (e) {
      _showSnack('Purchase failed: $e');
    } finally {
      if (mounted) setState(() => _isWorking = false);
    }
  }

  Future<void> _onRestore() async {
    final purchases = context.read<PurchasesService>();
    final entitlements = context.read<EntitlementNotifier>();
    setState(() => _isWorking = true);
    try {
      final info = await purchases.restorePurchases();
      await entitlements.refresh();
      if (!mounted) return;
      final restored = PurchasesService.isProEntitled(info);
      _showSnack(
        restored
            ? "Purchases restored — you're all set!"
            : 'No previous purchases found.',
      );
      if (restored) Navigator.of(context).pop(true);
    } on PlatformException catch (e) {
      _showSnack(e.message ?? 'Restore failed.');
    } catch (e) {
      _showSnack('Restore failed: $e');
    } finally {
      if (mounted) setState(() => _isWorking = false);
    }
  }

  void _showSnack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Upgrade to Pro'),
        leading: IconButton(
          icon: const Icon(Icons.close),
          tooltip: 'Close',
          onPressed: () => Navigator.of(context).pop(false),
        ),
      ),
      body: Stack(
        children: [
          SafeArea(
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const _FeaturesShowcase(),
                  const SizedBox(height: 24),
                  if (RevenueCatConfig.isPlaceholder)
                    const _PlaceholderState()
                  else
                    FutureBuilder<Offerings?>(
                      future: _offeringsFuture,
                      builder: (context, snap) {
                        if (snap.connectionState != ConnectionState.done) {
                          return const Padding(
                            padding: EdgeInsets.symmetric(vertical: 48),
                            child: Center(child: CircularProgressIndicator()),
                          );
                        }
                        final offerings = snap.data;
                        final current = offerings?.current;
                        final packages = current?.availablePackages ?? const [];
                        if (packages.isEmpty) {
                          return _ErrorState(onRetry: () {
                            setState(() {
                              _offeringsFuture = _loadOfferings();
                            });
                          });
                        }
                        return Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            for (final pkg in packages)
                              Padding(
                                padding: const EdgeInsets.only(bottom: 12),
                                child: _PackageCard(
                                  package: pkg,
                                  enabled: !_isWorking,
                                  isBestValue:
                                      pkg.packageType == PackageType.lifetime,
                                  onSubscribe: () => _onPurchase(pkg),
                                ),
                              ),
                          ],
                        );
                      },
                    ),
                  const SizedBox(height: 16),
                  TextButton(
                    onPressed: _isWorking ? null : _onRestore,
                    child: const Text('Restore Purchases'),
                  ),
                  const SizedBox(height: 16),
                  Text(
                    'Subscriptions auto-renew. Cancel anytime in your device '
                    "settings. See LoadOut's Terms and Privacy Policy.",
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                    textAlign: TextAlign.center,
                  ),
                ],
              ),
            ),
          ),
          if (_isWorking)
            const ColoredBox(
              color: Color(0x66000000),
              child: Center(child: CircularProgressIndicator()),
            ),
        ],
      ),
    );
  }
}

/// Hero "what you get" surface. A vertical gradient backdrop holds the
/// "LoadOut Pro" headline, a short two-plan subtitle, and a frosted
/// card listing the seven Pro feature rows. Pure presentation — no
/// interactivity, no purchase wiring. The feature list mirrors the
/// `ProGate`-wrapped surfaces in the app today.
class _FeaturesShowcase extends StatelessWidget {
  const _FeaturesShowcase();

  // Canonical seven features. Ordered roughly by how visible each one is
  // in the existing app: the first three are gated surfaces a user can
  // already see locked, then the cloud/dev/customization tier, then the
  // forward-looking promise.
  static const List<_FeatureSpec> _features = [
    _FeatureSpec(
      icon: Icons.image_outlined,
      title: 'Cartridge & Chamber Drawings',
      description:
          'Visual SAAMI/CIP technical drawings for every cartridge in the catalog.',
    ),
    _FeatureSpec(
      icon: Icons.calculate_outlined,
      title: 'Ballistics Calculator',
      description:
          'Full 6-DOF solver — drop, wind, spin drift, transonic transition. Per-load DOPE charts.',
    ),
    _FeatureSpec(
      icon: Icons.smart_toy_outlined,
      title: 'AI Reloading Assistant',
      description:
          'Ask reloading questions in plain English. 30 questions per month.',
    ),
    _FeatureSpec(
      icon: Icons.cloud_upload_outlined,
      title: 'Cloud Backup',
      description:
          'Encrypted, opt-in backup to your own iCloud or Google Drive.',
    ),
    _FeatureSpec(
      icon: Icons.science_outlined,
      title: 'Load Development',
      description:
          'Charge ladders + seating ladders with auto-node analysis.',
    ),
    _FeatureSpec(
      icon: Icons.add_box_outlined,
      title: 'Custom Fields',
      description: 'Add unlimited custom fields to recipes and firearms.',
    ),
    _FeatureSpec(
      icon: Icons.workspace_premium_outlined,
      title: 'Future Pro Features',
      description:
          'Every Pro feature we ship is included — no upcharges.',
    ),
  ];

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    // Subtle vertical gradient: gunmetal at the top, slightly deeper at
    // the bottom for editorial depth on the headline. Light theme uses a
    // similarly subtle parchment ramp.
    final gradient = LinearGradient(
      begin: Alignment.topCenter,
      end: Alignment.bottomCenter,
      colors: isDark
          ? const [AppTheme.gunmetal, AppTheme.gunmetalDeep]
          : [AppTheme.parchment, theme.colorScheme.surfaceContainer],
    );

    return Container(
      decoration: BoxDecoration(
        gradient: gradient,
        borderRadius: BorderRadius.circular(20),
      ),
      padding: const EdgeInsets.fromLTRB(20, 24, 20, 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Headline
          Text(
            'LoadOut Pro',
            style: theme.textTheme.headlineMedium?.copyWith(
              fontWeight: FontWeight.w700,
              letterSpacing: 0.2,
            ),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 6),
          Text(
            'Two simple plans. Yearly or lifetime.',
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurface.withValues(alpha: 0.7),
            ),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 20),
          // Frosted feature card.
          _FeaturesCard(features: _features),
        ],
      ),
    );
  }
}

/// Frosted-looking card holding the rows of features. Slightly lighter
/// than the surrounding gradient so the card edge reads on the page.
class _FeaturesCard extends StatelessWidget {
  const _FeaturesCard({required this.features});

  final List<_FeatureSpec> features;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    return Container(
      decoration: BoxDecoration(
        color: isDark
            ? AppTheme.gunmetalSurface.withValues(alpha: 0.85)
            : Colors.white.withValues(alpha: 0.85),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: AppTheme.brass.withValues(alpha: 0.18),
          width: 1,
        ),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 18),
      child: Column(
        children: [
          for (var i = 0; i < features.length; i++) ...[
            _FeatureRow(spec: features[i]),
            if (i != features.length - 1) const SizedBox(height: 16),
          ],
        ],
      ),
    );
  }
}

/// A single row inside the features card: brass-tinted icon disc on the
/// left, brass-colored bold title and a one-line plain-text description
/// stacked on the right.
class _FeatureRow extends StatelessWidget {
  const _FeatureRow({required this.spec});

  final _FeatureSpec spec;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Brass-tinted circular icon backdrop.
        Container(
          width: 44,
          height: 44,
          decoration: BoxDecoration(
            color: AppTheme.brass.withValues(alpha: 0.14),
            shape: BoxShape.circle,
          ),
          child: Icon(spec.icon, color: AppTheme.brass, size: 22),
        ),
        const SizedBox(width: 14),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                spec.title,
                style: theme.textTheme.titleSmall?.copyWith(
                  color: AppTheme.brass,
                  fontWeight: FontWeight.w600,
                  fontSize: 15,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                spec.description,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurface.withValues(alpha: 0.75),
                  height: 1.35,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// Minimal data carrier for one feature row. Lives here rather than in a
/// shared model because nothing else in the app references it.
class _FeatureSpec {
  const _FeatureSpec({
    required this.icon,
    required this.title,
    required this.description,
  });

  final IconData icon;
  final String title;
  final String description;
}

class _PackageCard extends StatelessWidget {
  const _PackageCard({
    required this.package,
    required this.enabled,
    required this.onSubscribe,
    this.isBestValue = false,
  });

  final Package package;
  final bool enabled;
  final VoidCallback onSubscribe;
  final bool isBestValue;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final product = package.storeProduct;
    final intro = product.introductoryPrice;
    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(
          color: isBestValue
              ? AppTheme.brass.withValues(alpha: 0.55)
              : theme.colorScheme.outlineVariant,
          width: isBestValue ? 1.5 : 1,
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Flexible(
                        child: Text(
                          _packageTitle(package),
                          style: theme.textTheme.titleMedium?.copyWith(
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                      if (isBestValue) ...[
                        const SizedBox(width: 8),
                        const _BestValueBadge(),
                      ],
                    ],
                  ),
                  const SizedBox(height: 4),
                  Text(
                    product.priceString,
                    style: theme.textTheme.bodyMedium,
                  ),
                  if (intro != null && intro.priceString.isNotEmpty) ...[
                    const SizedBox(height: 2),
                    Text(
                      'Intro: ${intro.priceString}',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.primary,
                      ),
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(width: 12),
            FilledButton(
              onPressed: enabled ? onSubscribe : null,
              child: const Text('Subscribe'),
            ),
          ],
        ),
      ),
    );
  }

  /// Prefer the human-friendly title from the store product; fall back to
  /// the RevenueCat package identifier (e.g. `$rc_annual`). Only Yearly +
  /// Lifetime ship — monthly was never offered to a real user, so no
  /// grandfather case to handle.
  static String _packageTitle(Package p) {
    final title = p.storeProduct.title;
    if (title.isNotEmpty) return title;
    return switch (p.packageType) {
      PackageType.annual => 'Yearly',
      PackageType.lifetime => 'Lifetime',
      _ => p.identifier,
    };
  }
}

/// Brass pill rendered next to the Lifetime title. Pure visual — no
/// state, no semantics beyond the label itself.
class _BestValueBadge extends StatelessWidget {
  const _BestValueBadge();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: AppTheme.brass.withValues(alpha: 0.18),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(
          color: AppTheme.brass.withValues(alpha: 0.55),
          width: 0.8,
        ),
      ),
      child: const Text(
        'Best value',
        style: TextStyle(
          color: AppTheme.brass,
          fontSize: 11,
          fontWeight: FontWeight.w600,
          letterSpacing: 0.2,
        ),
      ),
    );
  }
}

class _PlaceholderState extends StatelessWidget {
  const _PlaceholderState();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(color: theme.colorScheme.outlineVariant),
      ),
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          children: [
            Icon(Icons.construction,
                size: 40, color: theme.colorScheme.primary),
            const SizedBox(height: 12),
            Text(
              'Pro Is Not Yet Available',
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w600,
              ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 8),
            Text(
              "We're putting the finishing touches on subscriptions. "
              'Check back soon — when Pro launches, your purchase will '
              'unlock cloud sync, photo backup, ballistics, and more.',
              style: theme.textTheme.bodyMedium,
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }
}

class _ErrorState extends StatelessWidget {
  const _ErrorState({required this.onRetry});

  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(color: theme.colorScheme.outlineVariant),
      ),
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          children: [
            Icon(Icons.error_outline,
                size: 40, color: theme.colorScheme.error),
            const SizedBox(height: 12),
            Text(
              "Couldn't Load Subscription Options",
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w600,
              ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 8),
            Text(
              'Check your internet connection and try again.',
              style: theme.textTheme.bodyMedium,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 16),
            FilledButton.tonal(
              onPressed: onRetry,
              child: const Text('Retry'),
            ),
          ],
        ),
      ),
    );
  }
}
