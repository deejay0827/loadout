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
//      title, a short subtitle, and a stack of six bordered benefit
//      cards (one per Pro pitch bucket — see `marketing/CLAUDE.md`
//      § 7 for the canonical list). This is the "what you get"
//      upsell — the same surface the user always sees, regardless of
//      whether RevenueCat has real keys configured yet.
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
// benefit. The six benefit cards mirror the marketing pitch in
// `marketing/CLAUDE.md` § 7 — Cloud Sync, Hornady 4DOF curves,
// Bluetooth devices, Scope View Pro + training mode, live weather +
// GPS altitude, and AI Smart Import. Order matters: cloud sync first
// because it's the cross-cutting value prop everyone benefits from.
// AI Reloading Assistant deliberately stays off this list — it's
// still Coming Soon, and our user-research framing is "reloaders are
// skeptical of AI" so we lead with the concrete benefits.
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
/// "LoadOut Pro" headline, a short three-plan subtitle, and a column
/// of six benefit cards. Pure presentation — no interactivity, no
/// purchase wiring. The six buckets mirror the marketing pitch in
/// `marketing/CLAUDE.md` § 7 and the gated surfaces in the app today.
class _FeaturesShowcase extends StatelessWidget {
  const _FeaturesShowcase();

  // Six clear feature buckets. Order matches `marketing/CLAUDE.md` so
  // the in-app pitch and the marketing copy stay in lockstep:
  //   1. Cross-device cloud sync
  //   2. Real Hornady 4DOF + custom drag curves
  //   3. Bluetooth devices
  //   4. Scope View Pro + training mode
  //   5. Live weather + GPS altitude
  //   6. AI Smart Import (reading-only — recipes from photos)
  //
  // The AI Reloading Assistant deliberately stays out of this list —
  // it's still Coming Soon at v1.0 and the user-research framing is
  // "reloaders are skeptical of AI", so we lead with the concrete
  // benefits instead of the chatbot.
  static const List<_FeatureSpec> _features = [
    _FeatureSpec(
      icon: Icons.cloud_sync_outlined,
      title: 'Cross-device cloud sync',
      description:
          'iCloud, Google Drive, or OneDrive. Encrypted on device with '
          'your passphrase. We never see the blob.',
    ),
    _FeatureSpec(
      icon: Icons.show_chart_outlined,
      title: 'Real Hornady 4DOF + custom drag curves',
      description:
          '300+ measured Cd-vs-Mach curves from Hornady\'s Doppler radar '
          'dataset. More accurate than G7 BC alone in the transonic '
          'region.',
    ),
    _FeatureSpec(
      icon: Icons.bluetooth_searching_outlined,
      title: 'Bluetooth devices',
      description:
          'Kestrel 5xxx Link, Garmin Xero (.fit), Bushnell BDX, Sig KILO, '
          'Vortex Razor, and Leica Geovid. Live data, no manual entry.',
    ),
    _FeatureSpec(
      icon: Icons.center_focus_strong_outlined,
      title: 'Scope View Pro + training mode',
      description:
          'Reticle hold-over visualization. Free-aim drag with predicted '
          'impact. Skill-level timing for movers. Animated targets with '
          'ambush guides.',
    ),
    _FeatureSpec(
      icon: Icons.air_outlined,
      title: 'Live weather + GPS altitude',
      description:
          'Pull station pressure, temperature, humidity, wind, and '
          'altitude from your location in one tap. Auto-fills your '
          'firing solution.',
    ),
    _FeatureSpec(
      icon: Icons.auto_fix_high_outlined,
      title: 'AI Smart Import',
      description:
          'Reads messy handwriting from your reloading notebook photos '
          'and turns it into structured recipes. Reading-only — no '
          'chat, no training.',
    ),
    _FeatureSpec(
      icon: Icons.science_outlined,
      title: 'Load development',
      description:
          'OCW (Newberry), Audette Ladder, Satterlee 10-shot, and '
          'generic charge ladders with statistical analysis. Per-charge '
          'SD, ES, mean MV, group size, and node detection.',
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
            'Three plans. Quarterly, yearly, or lifetime — try Pro your '
            'first year for less with the welcome offer.',
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurface.withValues(alpha: 0.7),
            ),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 20),
          // Six benefit cards stacked vertically. Each is its own
          // bordered surface so the visual rhythm matches the
          // proposal mock-ups (one card per benefit, not one
          // mega-card with rows inside it).
          for (var i = 0; i < _features.length; i++) ...[
            _BenefitCard(spec: _features[i]),
            if (i != _features.length - 1) const SizedBox(height: 12),
          ],
        ],
      ),
    );
  }
}

/// One Pro benefit. A bordered surface with a brass-tinted icon disc,
/// a brass title, and a body paragraph. Slightly lighter background
/// than the gradient so the card edge reads on the page.
class _BenefitCard extends StatelessWidget {
  const _BenefitCard({required this.spec});

  final _FeatureSpec spec;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    return Container(
      decoration: BoxDecoration(
        color: isDark
            ? AppTheme.gunmetalSurface.withValues(alpha: 0.85)
            : Colors.white.withValues(alpha: 0.88),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: AppTheme.brass.withValues(alpha: 0.22),
          width: 1,
        ),
      ),
      padding: const EdgeInsets.fromLTRB(14, 14, 16, 14),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Brass-tinted circular icon backdrop.
          Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              color: AppTheme.brass.withValues(alpha: 0.16),
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
                    fontWeight: FontWeight.w700,
                    fontSize: 15,
                    letterSpacing: 0.1,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  spec.description,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurface.withValues(alpha: 0.78),
                    height: 1.4,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
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
              'unlock cloud sync, real Hornady 4DOF curves, Bluetooth '
              'devices, Scope View Pro, live weather, and AI Smart '
              'Import.',
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
