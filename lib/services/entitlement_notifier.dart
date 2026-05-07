// FILE: lib/services/entitlement_notifier.dart
//
// ============================================================================
// WHAT THIS FILE DOES
// ============================================================================
// Defines `EntitlementNotifier`, a Flutter `ChangeNotifier` that exposes a
// single boolean — `isPro` — and emits a "something changed" signal whenever
// it flips. Widgets read this notifier through Flutter's `provider` package
// and rebuild themselves automatically when entitlement state changes (after
// a purchase, a restore, an expiry, etc.).
//
// What is a `ChangeNotifier`? It's Flutter's simplest "tell me when this
// changes" object. It owns some piece of state, and when that state changes
// it calls `notifyListeners()`. Any widget that did `context.watch<X>()` for
// that notifier gets rebuilt with the new value. We picked it (over a
// `StreamProvider<bool>`) so callers can also call helpers like `refresh()`
// imperatively without rewiring the provider tree.
//
// Public surface:
//
//   - `EntitlementNotifier(purchases)` — constructor. Subscribes to
//     `PurchasesService.customerInfoStream` (a stream of RevenueCat
//     `CustomerInfo` snapshots) and primes `_isPro` with the current state.
//     If the underlying `PurchasesService` was never configured (placeholder
//     keys path), the constructor short-circuits — `isPro` stays false but
//     the notifier still wires up cleanly.
//   - `isPro` — boolean read by widgets. Returns `true` when the dev override
//     is set AND the build is debug; otherwise reflects the real RevenueCat
//     entitlement state.
//   - `refresh()` — force a one-shot re-fetch of `CustomerInfo`. Useful right
//     after a successful purchase to flip the UI before the listener event
//     lands.
//   - `entitlementKey` — diagnostic getter that returns the entitlement
//     identifier from `RevenueCatConfig`.
//   - `dispose()` — cancels the stream subscription. Called by Flutter when
//     the provider is torn down.
//
// `debugForceProActive` (compile-time constant) lets developers reach
// Pro-gated UI in debug builds without going through a real sandbox purchase.
// In release builds `kDebugMode` is a const-false, so the dead branch is
// stripped by the Dart compiler — the override has zero effect on shipped
// binaries.
//
// ============================================================================
// WHY IT EXISTS IN THE ARCHITECTURE
// ============================================================================
// The layer cake for the monetization stack:
//
//   UI (Pro-gated screens, ProGate widget, ensurePro action gate)
//     ↓ context.watch<EntitlementNotifier>()
//   EntitlementNotifier                ← this file
//     ↓ subscribes to
//   PurchasesService.customerInfoStream
//     ↓ wraps
//   purchases_flutter / Purchases SDK
//
// Without this notifier, every Pro-gated widget would have to subscribe to
// the RevenueCat stream itself, decode `CustomerInfo`, and compare the
// active entitlement key. Centralizing that logic here means each widget
// just reads a boolean.
//
// ============================================================================
// WHY THIS IS HARDER THAN IT LOOKS
// ============================================================================
// 1. FIRST-FRAME RENDER ORDER. The first event from the RevenueCat stream
//    arrives some milliseconds after the SDK boots. Without the priming
//    `refresh()` call in the constructor, the very first frame after a
//    cold start would render every Pro user as "not pro" and only flip
//    once the listener fires.
// 2. PLACEHOLDER-KEYS PATH. When `RevenueCatConfig.isPlaceholder` is true
//    the SDK is never configured (so `customerInfoStream` would never emit).
//    We have to check `_purchases.isConfigured` BEFORE subscribing to avoid
//    listening on a dead stream.
// 3. DEV OVERRIDE FAIL-SAFE. `debugForceProActive` is hardcoded to true
//    during development. The pre-release checklist requires flipping this
//    to false before any TestFlight or App Store build — see comment block
//    above the constant.
// 4. NOTIFY EQUALS-CHECK. We only call `notifyListeners()` when the value
//    actually flips. Re-emitting on every stream event would cause needless
//    widget rebuilds.
//
// ============================================================================
// WHO CONSUMES THIS FILE
// ============================================================================
// - /Users/general/Development/Applications/LoadOut/lib/app.dart provides this
//   notifier to the widget tree via `ChangeNotifierProvider`.
// - /Users/general/Development/Applications/LoadOut/lib/widgets/pro_gate.dart
//   reads `isPro` to render the gated child or a Pro upsell.
// - /Users/general/Development/Applications/LoadOut/lib/screens/paywall/paywall_screen.dart
//   calls `refresh()` after a purchase succeeds to flip Pro-gated UI before
//   the next stream event lands.
//
// ============================================================================
// SIDE EFFECTS
// ============================================================================
// - Subscribes to `PurchasesService.customerInfoStream` for the lifetime of
//   the notifier. Calls `notifyListeners()` whenever `_isPro` flips.
// - `refresh()` makes a synchronous-style call into RevenueCat to pull the
//   latest `CustomerInfo`.
// - No persistence, no network beyond what RevenueCat does internally.

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:purchases_flutter/purchases_flutter.dart';

import 'purchases_service.dart';
import 'revenue_cat_config.dart';

/// Lightweight [ChangeNotifier] over [PurchasesService.customerInfoStream] so
/// widgets can `context.watch<EntitlementNotifier>().isPro` without each
/// reading [CustomerInfo] themselves.
///
/// We picked ChangeNotifier (rather than `StreamProvider<bool>`) so consumers
/// can also call helpers like [refresh] imperatively without rewiring the
/// provider tree.
class EntitlementNotifier extends ChangeNotifier {
  EntitlementNotifier(this._purchases) {
    if (_purchases.isConfigured) {
      _sub = _purchases.customerInfoStream.listen(
        _handleCustomerInfo,
        onError: (Object e) =>
            debugPrint('EntitlementNotifier: stream error: $e'),
      );
      // Prime with the current state so widgets don't render "not pro" for
      // the first frame after a restart while waiting for the first event.
      // ignore: discarded_futures
      refresh();
    }
  }

  /// **DEV ONLY:** when true (and running in debug mode), [isPro] always
  /// returns `true` so Pro-gated UI is reachable without going through a
  /// real sandbox purchase. Has no effect in release builds (kDebugMode is
  /// const-false there, so the dead branch gets stripped).
  ///
  /// Flip back to `false` before cutting any TestFlight / App Store build.
  static const bool debugForceProActive = true;

  final PurchasesService _purchases;
  StreamSubscription<CustomerInfo>? _sub;

  bool _isPro = false;

  /// Whether the current user has the Pro entitlement active.
  bool get isPro {
    if (debugForceProActive && kDebugMode) return true;
    return _isPro;
  }

  /// Force a re-fetch of [CustomerInfo] and update [isPro] accordingly.
  /// Useful right after a successful purchase to ensure the UI flips
  /// before the listener event lands.
  Future<void> refresh() async {
    if (!_purchases.isConfigured) return;
    try {
      final info = await _purchases.getCustomerInfo();
      _handleCustomerInfo(info);
    } catch (e) {
      debugPrint('EntitlementNotifier.refresh: $e');
    }
  }

  void _handleCustomerInfo(CustomerInfo info) {
    final next = PurchasesService.isProEntitled(info);
    if (next != _isPro) {
      _isPro = next;
      notifyListeners();
    }
  }

  /// Returns the active entitlement key for diagnostics. Null when the user
  /// has no active Pro entitlement.
  static String get entitlementKey => RevenueCatConfig.proEntitlement;

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }
}
