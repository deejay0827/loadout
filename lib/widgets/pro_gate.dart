// FILE: lib/widgets/pro_gate.dart
//
// ============================================================================
// WHAT THIS FILE DOES
// ============================================================================
// Defines the two ways the rest of the app puts a "Pro feature" boundary
// between a free user and a paid feature:
//
//   - `ProGate` — a STATELESS WIDGET that wraps an arbitrary `child`
//     widget. If the current `EntitlementNotifier` reports `isPro == true`
//     the widget renders `child` normally. Otherwise it renders a small
//     locked-tile card (`Card` + `ListTile` with a lock icon and a "Pro
//     Feature" subtitle) that, when tapped, pushes the `PaywallScreen`.
//     Use this whenever a Pro feature appears INLINE in the UI: a button
//     in a list, an expanded section in a detail screen, etc.
//   - `ensurePro(context)` — an async TOP-LEVEL FUNCTION (not a widget).
//     Returns `true` immediately if the user is already Pro. Otherwise
//     pushes the `PaywallScreen` as a fullscreen modal and resolves to
//     `true` only if the user successfully upgraded during the visit
//     (either because the paywall popped with `result == true`, or
//     because the entitlement notifier switched to Pro while the paywall
//     was open and the user dismissed it via the system back gesture).
//     Use this when the gate is on an ACTION rather than a piece of UI:
//     "before this button does anything, make sure the user is Pro."
//
// `ProGate` props:
//   - `feature` — string name of the gated feature, shown on the lock
//                  tile so the user knows what they'd be unlocking
//                  (e.g. "Smart import").
//   - `child`   — the widget to show when the user is Pro.
//   - `dense`   — when true, render the lock tile in a denser layout
//                  suitable for inline list rows. Defaults to a roomier
//                  card.
//
// `ProGate.build` reads the entitlement state via
// `context.watch<EntitlementNotifier>()`. Watching (vs. reading) is
// deliberate: when the user finishes an in-app purchase, the notifier
// fires `notifyListeners()`, which rebuilds every `ProGate` so they all
// flip from "locked tile" to "child" simultaneously. No app restart, no
// pull-to-refresh.
//
// `ensurePro` reads via `context.read<EntitlementNotifier>()` because
// it's a one-shot check, not a subscription. After the paywall closes
// it re-reads the same notifier in case `notifyListeners()` fired during
// the modal's lifetime.
//
// ============================================================================
// WHY IT EXISTS IN THE ARCHITECTURE
// ============================================================================
// Every Pro feature in LoadOut needs the same tri-state behavior:
//   1. Pro user — show the feature.
//   2. Free user — show a locked affordance that explains what they'd
//      get if they upgraded and offers a 1-tap path to the paywall.
//   3. Free user mid-purchase — close the paywall and update every
//      gated UI on screen without a refresh.
//
// Re-implementing that in every screen would mean every feature has its
// own `Consumer<EntitlementNotifier>` + its own paywall-route push +
// its own "what does this feature look like locked?" card. Centralizing
// it here keeps the visual language consistent ("lock icon, 'Pro
// Feature' subtitle, chevron-right") and keeps the upgrade path one
// hop away from any feature.
//
// `ensurePro` is the action-flavored counterpart for code paths where
// there's no UI to wrap — the user taps "Import recipes from CSV" and
// before the import code runs we want to make sure they're Pro. Wrapping
// the whole import button in a `ProGate` would still render the import
// button (just locked); `ensurePro` lets the caller branch on the
// result and, e.g., pop a snackbar instead.
//
// ============================================================================
// WHY THIS IS HARDER THAN IT LOOKS
// ============================================================================
// 1. WATCH VS. READ. `ProGate.build` MUST use `watch` so it rebuilds
//    when the entitlement flips. `ensurePro` MUST use `read` so it
//    doesn't subscribe inside an async function (which would risk
//    listener leaks). Mixing these up either freezes the UI in the
//    locked state after a successful purchase, or silently subscribes
//    to provider updates from an async path.
// 2. POPPING WITHOUT A RESULT. The paywall is pushed with
//    `fullscreenDialog: true`, which on iOS exposes a swipe-down
//    gesture to dismiss. If the user buys Pro and then swipes the
//    paywall away, the route pops with `null`, NOT `true`. We
//    re-check `entitlements.isPro` after the paywall closes and treat
//    that as "successful upgrade." Without this fallback the user
//    could be Pro, the paywall would close, and the calling action
//    would still be told "no, they didn't upgrade."
// 3. PROVIDER SCOPE. Both surfaces depend on `EntitlementNotifier`
//    being available in the widget tree above this widget — see
//    `lib/app.dart` for where it's provided. If a screen is pushed
//    outside that scope (e.g. via a transient overlay), `watch`
//    throws.
//
// ============================================================================
// WHO CONSUMES THIS FILE
// ============================================================================
// - Any feature that needs gating. Currently:
//   - lib/screens/loads/* — Pro recipe features (advanced exports,
//     unlimited recipes once the free-tier limit lands, etc.).
//   - lib/screens/firearms/* — Pro firearm-form fields.
//   - lib/screens/glossary/* — none today, but the paywall is reachable
//     from the home screen menu.
// - Search the codebase for `ProGate(` or `ensurePro(` to see every
//   call site.
//
// ============================================================================
// SIDE EFFECTS
// ============================================================================
// - `ensurePro` pushes a fullscreen `MaterialPageRoute<bool>` for the
//   `PaywallScreen` when invoked on a non-Pro user. The paywall itself
//   has its own side effects (initiates StoreKit / Play Billing flows
//   via `purchases_flutter`), but this file is purely the routing
//   wrapper.
// - No SharedPreferences writes, no network, no SQLite.

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../screens/paywall/paywall_screen.dart';
import '../services/entitlement_notifier.dart';

/// Inline Pro feature gate. Renders [child] when the user has Pro,
/// otherwise renders a lock tile that opens the [PaywallScreen] on tap.
///
/// ```dart
/// ProGate(
///   feature: 'Smart import',
///   child: ImportButton(...),
/// )
/// ```
class ProGate extends StatelessWidget {
  const ProGate({
    super.key,
    required this.feature,
    required this.child,
    this.dense = false,
  });

  /// Human-readable feature name shown on the lock tile (e.g. "Smart import").
  final String feature;

  /// Widget rendered when the user has Pro.
  final Widget child;

  /// When true, render a more compact tile suitable for inline placement
  /// inside list rows. Defaults to a roomier card layout.
  final bool dense;

  @override
  Widget build(BuildContext context) {
    final isPro = context.watch<EntitlementNotifier>().isPro;
    if (isPro) return child;
    final theme = Theme.of(context);
    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: theme.colorScheme.outlineVariant),
      ),
      child: ListTile(
        dense: dense,
        leading: Icon(Icons.lock_outline, color: theme.colorScheme.primary),
        title: Text(feature),
        subtitle: const Text('Pro Feature'),
        trailing: const Icon(Icons.chevron_right),
        onTap: () => ensurePro(context),
      ),
    );
  }
}

/// Action gate. Resolves to true if the user is already Pro, otherwise
/// shows the [PaywallScreen] and resolves to true only if the user
/// upgraded during the visit.
///
/// ```dart
/// onTap: () async {
///   if (!await ensurePro(context)) return;
///   await runImport();
/// }
/// ```
Future<bool> ensurePro(BuildContext context) async {
  final entitlements = context.read<EntitlementNotifier>();
  if (entitlements.isPro) return true;
  final upgraded = await Navigator.of(context).push<bool>(
    MaterialPageRoute(
      builder: (_) => const PaywallScreen(),
      fullscreenDialog: true,
    ),
  );
  // Re-check the notifier in case the paywall popped without an explicit
  // result (e.g. via system back gesture) but a purchase still completed.
  return entitlements.isPro || upgraded == true;
}
