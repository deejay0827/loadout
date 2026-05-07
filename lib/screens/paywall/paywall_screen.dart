import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:purchases_flutter/purchases_flutter.dart';

import '../../services/entitlement_notifier.dart';
import '../../services/purchases_service.dart';
import '../../services/revenue_cat_config.dart';

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
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 32),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _Hero(theme: theme),
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

class _Hero extends StatelessWidget {
  const _Hero({required this.theme});

  final ThemeData theme;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Icon(
          Icons.workspace_premium,
          size: 56,
          color: theme.colorScheme.primary,
        ),
        const SizedBox(height: 12),
        Text(
          'LoadOut Pro',
          style: theme.textTheme.headlineSmall?.copyWith(
            fontWeight: FontWeight.w600,
          ),
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 8),
        Text(
          'Unlock technical cartridge drawings, the ballistics '
          'calculator, cloud backup, and every future Pro feature. '
          'Yearly subscription or one-time Lifetime purchase.',
          style: theme.textTheme.bodyMedium,
          textAlign: TextAlign.center,
        ),
      ],
    );
  }
}

class _PackageCard extends StatelessWidget {
  const _PackageCard({
    required this.package,
    required this.enabled,
    required this.onSubscribe,
  });

  final Package package;
  final bool enabled;
  final VoidCallback onSubscribe;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final product = package.storeProduct;
    final intro = product.introductoryPrice;
    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(color: theme.colorScheme.outlineVariant),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    _packageTitle(package),
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
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
