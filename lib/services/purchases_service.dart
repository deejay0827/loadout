// FILE: lib/services/purchases_service.dart
//
// ============================================================================
// WHAT THIS FILE DOES
// ============================================================================
// Defines `PurchasesService`, the single Dart class that talks to the
// `purchases_flutter` SDK (RevenueCat's official Flutter plugin). Every
// in-app purchase, restore, customer-info fetch, and entitlement check
// flows through methods on this class. The rest of the app NEVER touches
// the `Purchases` API directly — it goes through this wrapper, just like
// `AuthService` mediates Firebase Auth.
//
// What is RevenueCat? RevenueCat is a managed third-party service that sits
// in front of Apple's StoreKit and Google's Play Billing. Both stores have
// dramatically different APIs for "is this person subscribed?" Apple gives
// you receipts, Google gives you purchase tokens, and validating either
// one server-side is non-trivial. RevenueCat normalizes that — they
// validate receipts on their servers, track entitlements per app-user-id,
// and surface a unified `CustomerInfo` object in the SDK. We pay them a
// % of revenue in exchange for not having to write that infrastructure.
//
// Public surface, in the order the methods appear:
//
//   - `isConfigured` — true once `initialize()` has finished. Used as a
//     guard everywhere else: when the API keys are placeholders we skip
//     the SDK boot, and downstream methods become no-ops.
//   - `initialize()` — call once, after Firebase is ready and before
//     `runApp`. Safely no-ops when the keys are placeholders so the app
//     can still launch in dev with no real RevenueCat account.
//   - `setAppUserId(firebaseUid)` — links the RevenueCat identity to the
//     Firebase Auth user. Pass non-null to log in, null to log out. This
//     is the mechanism that makes Pro entitlements follow the user across
//     devices: if they buy Pro on iOS and sign in on Android with the same
//     Firebase account, RevenueCat sees the same app-user-id on both and
//     surfaces the same entitlement.
//   - `customerInfoStream` — broadcast stream of `CustomerInfo` updates
//     fired by the SDK whenever entitlement state changes. Lazily wired
//     on first listen.
//   - `getCustomerInfo()` — direct, one-shot fetch.
//   - `getOfferings()` — pulls the configured offerings (the price tiers
//     yearly + lifetime + monthly) from the App Store / Play Store via
//     RevenueCat. This is what populates the paywall.
//   - `purchase(package)` — runs a real purchase flow. Throws on cancel
//     or failure so the caller can distinguish "user backed out" from
//     "card declined" via the platform error code.
//   - `restorePurchases()` — restores prior purchases tied to the current
//     store account. Required by App Store guidelines for any app with a
//     subscription tier.
//   - `isProEntitled(info)` — STATIC helper. Given any `CustomerInfo`,
//     returns whether the Pro entitlement is active. Static so widgets
//     can call it on a stream snapshot, a one-shot fetch, or a mocked
//     test fixture without an instance.
//   - `dispose()` — currently no callers; defined for completeness so
//     tests can drop the broadcast controller cleanly.
//
// ============================================================================
// WHY IT EXISTS IN THE ARCHITECTURE
// ============================================================================
// In the layer cake:
//
//   UI (paywall, ProGate, EntitlementNotifier)
//     ↓
//   PurchasesService                  ← this file
//     ↓
//   purchases_flutter / Purchases SDK
//     ↓
//   StoreKit (iOS) or Play Billing (Android), via RevenueCat servers
//
// One reason this is its own file: the SDK exposes lots of advanced surface
// area (subscriber attributes, identification, observer mode, etc.) we don't
// want screens to reach into. By exposing only the calls we actually use,
// future SDK upgrades or even a swap to a different IAP provider become
// localized changes.
//
// ============================================================================
// WHY THIS IS HARDER THAN IT LOOKS
// ============================================================================
// 1. PLATFORM-SPECIFIC API KEYS. iOS uses `appl_*` keys, Android uses
//    `goog_*` keys. We branch on `Platform.isIOS` to pick the right one.
//    Mixing them up gives "invalid api key" errors at boot.
// 2. INITIALIZATION ORDER. The SDK MUST be configured before any other
//    `Purchases.*` call. The flow is: Firebase init → (this) `initialize()`
//    → `runApp` → auth resolves → `setAppUserId(uid)`. Calling
//    `setAppUserId` before `initialize` silently does nothing (we guard
//    with `_initialized`), but it would have thrown without the guard.
// 3. LOG-IN / LOG-OUT EDGE CASES. RevenueCat's `logOut` throws if the
//    current user is "anonymous" (has never been logged in). When auth
//    state churns at startup (anonymous → real → signed out), these
//    PlatformExceptions are routine. We catch and log instead of letting
//    them propagate.
// 4. SINGLE PROCESS-LIFETIME LISTENER. `Purchases.addCustomerInfoUpdateListener`
//    can only be added once per process; subsequent calls accumulate. We
//    add it exactly once when the broadcast stream is first subscribed,
//    and the controller is intentionally left open even when the last
//    subscriber drops, since later subscribers may show up.
// 5. ENTITLEMENT KEY MISMATCH. The string passed to `isProEntitled` MUST
//    match the entitlement identifier configured on the RevenueCat
//    dashboard. A typo here means every user looks "not pro" forever,
//    even after a successful purchase. Centralized in `RevenueCatConfig`.
// 6. PURCHASE THROWS. The SDK throws on cancel — it does NOT return a
//    "user cancelled" sentinel. UI code has to catch the exception and
//    inspect the platform error code to distinguish cancel from failure.
//
// ============================================================================
// WHO CONSUMES THIS FILE
// ============================================================================
// - /Users/general/Development/Applications/LoadOut/lib/main.dart calls
//   `initialize()` once during app boot.
// - /Users/general/Development/Applications/LoadOut/lib/app.dart provides this
//   service to the widget tree and calls `setAppUserId(...)` whenever the
//   Firebase Auth user changes.
// - /Users/general/Development/Applications/LoadOut/lib/services/entitlement_notifier.dart
//   subscribes to `customerInfoStream` and uses `isProEntitled`.
// - /Users/general/Development/Applications/LoadOut/lib/screens/paywall/paywall_screen.dart
//   calls `getOfferings`, `purchase`, and `restorePurchases`.
//
// ============================================================================
// SIDE EFFECTS
// ============================================================================
// - Plugin calls into the native `purchases_flutter` SDK, which in turn
//   talks to StoreKit / Play Billing and RevenueCat servers.
// - Network: every method except `isConfigured` and `customerInfoStream`
//   eventually makes a network call.
// - `purchase(package)` triggers the OS-level purchase sheet (Touch ID /
//   Face ID, etc.) — this is the only method that opens UI.
// - Persistence: RevenueCat stores its own cache on-device; the SDK manages
//   that itself. We don't write anything to disk from this file.

import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show PlatformException;
import 'package:purchases_flutter/purchases_flutter.dart';

import 'revenue_cat_config.dart';

/// Wraps the RevenueCat `purchases_flutter` SDK so the rest of the app talks
/// to a single, mockable surface — same pattern as [AuthService] for
/// Firebase Auth.
///
/// The entitlement key checked everywhere is [RevenueCatConfig.proEntitlement]
/// (the lowercase string `'pro'`). It MUST match the entitlement defined in
/// the RevenueCat dashboard, otherwise [isProEntitled] will always return
/// false and nobody will ever unlock Pro.
class PurchasesService {
  PurchasesService();

  bool _initialized = false;
  StreamController<CustomerInfo>? _customerInfoController;

  /// True once [initialize] has finished and the SDK is configured. False if
  /// initialization was skipped because the API keys are placeholders.
  bool get isConfigured => _initialized;

  /// Initialize the RevenueCat SDK. Call once after Firebase is ready and
  /// before [runApp]. Safe to call when API keys are still placeholders —
  /// in that case it logs and returns without configuring the SDK so the
  /// app can launch and the paywall can show its placeholder state.
  ///
  /// Purposely does NOT set the user ID here — that happens later in
  /// [setAppUserId] once Firebase Auth has resolved the current user.
  Future<void> initialize() async {
    if (_initialized) return;
    if (RevenueCatConfig.isPlaceholder) {
      debugPrint(
        'PurchasesService: RevenueCat API keys are placeholders; '
        'skipping SDK configuration.',
      );
      return;
    }

    await Purchases.setLogLevel(
      kReleaseMode ? LogLevel.error : LogLevel.warn,
    );

    final apiKey = Platform.isIOS
        ? RevenueCatConfig.iosApiKey
        : RevenueCatConfig.androidApiKey;
    await Purchases.configure(PurchasesConfiguration(apiKey));

    _initialized = true;
  }

  /// Sync the active app user ID with Firebase Auth. Call whenever the
  /// auth user changes:
  ///   - non-null `firebaseUid` → [Purchases.logIn]
  ///   - null (signed out)      → [Purchases.logOut]
  ///
  /// No-op when the SDK was never configured (placeholder keys path).
  Future<void> setAppUserId(String? firebaseUid) async {
    if (!_initialized) return;
    try {
      if (firebaseUid != null) {
        await Purchases.logIn(firebaseUid);
      } else {
        await Purchases.logOut();
      }
    } on PlatformException catch (e) {
      // Already-logged-out, "anonymous user can't log out" etc. are routine
      // edge cases when auth state churns. Log and continue.
      debugPrint('PurchasesService.setAppUserId: ${e.message}');
    }
  }

  /// Broadcast stream of [CustomerInfo] updates fired by the SDK whenever
  /// entitlement state changes (purchase, restore, expiry, etc.).
  ///
  /// Lazily wires the underlying RevenueCat listener on first listen and
  /// keeps a single subscription alive for the lifetime of this service.
  Stream<CustomerInfo> get customerInfoStream {
    if (_customerInfoController != null) {
      return _customerInfoController!.stream;
    }
    final controller = StreamController<CustomerInfo>.broadcast(
      onCancel: () {
        // Keep the controller alive — the SDK's listener can only be added
        // once per process and there may be other subscribers later.
      },
    );
    _customerInfoController = controller;
    if (_initialized) {
      Purchases.addCustomerInfoUpdateListener(controller.add);
    }
    return controller.stream;
  }

  /// Direct fetch of the current [CustomerInfo]. Useful for one-shot reads
  /// at startup or before showing the paywall.
  Future<CustomerInfo> getCustomerInfo() => Purchases.getCustomerInfo();

  /// Fetch the configured offerings from RevenueCat. Returns null on failure
  /// (errors are logged) so paywall UI can render an error state instead of
  /// crashing.
  Future<Offerings?> getOfferings() async {
    if (!_initialized) return null;
    try {
      return await Purchases.getOfferings();
    } on PlatformException catch (e) {
      debugPrint('PurchasesService.getOfferings: ${e.message}');
      return null;
    }
  }

  /// Purchase [package]. Throws on cancel/error so the caller (paywall) can
  /// distinguish user-cancel from real failures via the platform error code.
  Future<CustomerInfo> purchase(Package package) async {
    final result = await Purchases.purchase(PurchaseParams.package(package));
    return result.customerInfo;
  }

  /// Restore prior purchases tied to the current store account. Throws on
  /// failure; callers show a snackbar with the result either way.
  Future<CustomerInfo> restorePurchases() => Purchases.restorePurchases();

  /// Returns whether [info] has the Pro entitlement currently active.
  /// Static so widgets can call it on a [CustomerInfo] from any source
  /// (stream snapshot, one-shot fetch, mocked test fixture).
  static bool isProEntitled(CustomerInfo info) {
    final entitlement =
        info.entitlements.active[RevenueCatConfig.proEntitlement];
    return entitlement != null && entitlement.isActive;
  }

  /// Tear down the broadcast controller. Currently no callers — the service
  /// lives for the lifetime of the app — but defined for completeness so
  /// tests can drop the listener cleanly.
  Future<void> dispose() async {
    await _customerInfoController?.close();
    _customerInfoController = null;
  }
}
