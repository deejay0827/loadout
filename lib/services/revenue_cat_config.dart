// FILE: lib/services/revenue_cat_config.dart
//
// ============================================================================
// WHAT THIS FILE DOES
// ============================================================================
// A tiny constants-only class that holds:
//
//   - `iosApiKey` — the iOS PUBLIC API key issued by RevenueCat.
//   - `androidApiKey` — the Android PUBLIC API key issued by RevenueCat.
//   - `proEntitlement` — the entitlement identifier (`'pro'`) configured in
//     the RevenueCat dashboard. Must match exactly or every user looks
//     "not pro" forever.
//   - `isPlaceholder` — boolean that returns true when either key still
//     holds a `REPLACE_ME_*` placeholder. Used by `PurchasesService.initialize`
//     and the paywall to short-circuit when keys aren't real yet.
//
// IMPORTANT: these are PUBLIC keys, the kind that is intentionally safe to
// commit to a public repo. RevenueCat's threat model is built on the
// assumption that the client API key is visible. Real secrets that could
// be abused — App Store Connect API key, Google service account JSON, the
// App-Specific Shared Secret — live on RevenueCat's server side and never
// come anywhere near the binary.
//
// ============================================================================
// WHY IT EXISTS IN THE ARCHITECTURE
// ============================================================================
// Putting these strings in one named class instead of inlining them in
// `PurchasesService` gives us:
// 1. Single source of truth — `EntitlementNotifier` and `PurchasesService`
//    both reference `proEntitlement`, ruling out drift between the two.
// 2. Placeholder detection — `isPlaceholder` lets multiple call sites bail
//    out gracefully when running with default in-tree values, rather than
//    each one doing its own string check.
// 3. Easy review — when the Android key gets upgraded from the onboarding
//    test_* key to a real goog_* key, the diff is one line in one file.
//
// ============================================================================
// WHY THIS IS HARDER THAN IT LOOKS
// ============================================================================
// 1. THE ANDROID KEY IS STILL `test_*`. RevenueCat issues a project-wide
//    "onboarding test key" before Play Console identity is verified. That
//    key still routes against the sandbox so the SDK initializes cleanly,
//    but it cannot validate real Play purchases. The `isPlaceholder`
//    treats `test_*` as configured (NOT a placeholder) so the SDK does
//    initialize against RevenueCat's sandbox during development.
// 2. ENTITLEMENT KEY DRIFT. The `'pro'` string here MUST match exactly the
//    entitlement identifier configured at app.revenuecat.com. There's no
//    runtime check that catches a mismatch — every user just silently
//    looks "not pro". Mistakes here are caught only at QA time.
// 3. KEY ROTATION. If RevenueCat ever rotates either key, every shipped
//    binary stops working until users update. This file is the canonical
//    place to track that.
//
// ============================================================================
// WHO CONSUMES THIS FILE
// ============================================================================
// - /Users/general/Development/Applications/LoadOut/lib/services/purchases_service.dart
//   reads `iosApiKey`, `androidApiKey`, `isPlaceholder`, `proEntitlement`.
// - /Users/general/Development/Applications/LoadOut/lib/services/entitlement_notifier.dart
//   reads `proEntitlement` (via the `entitlementKey` getter).
// - /Users/general/Development/Applications/LoadOut/lib/screens/paywall/paywall_screen.dart
//   reads `isPlaceholder` to render its "Pro not yet available" state.
//
// ============================================================================
// SIDE EFFECTS
// ============================================================================
// None. Pure constants and a derived getter. Zero runtime behavior beyond
// returning these values when asked.

/// RevenueCat API keys.
///
/// - iOS: real public key (`appl_*`) issued after the iOS app was set up
///   in the RevenueCat dashboard. Sandbox + production purchases route
///   through this key.
/// - Android: still the project-wide **onboarding test key** (`test_*`)
///   pending Play Console identity verification. Replace with a `goog_*`
///   key once the Android app is set up in RevenueCat.
///
/// These are PUBLIC keys (safe to commit) — the actual secrets (App Store
/// Connect API key, Google service account JSON, App-Specific Shared
/// Secret) live on the RevenueCat server side and never come near the
/// client.
class RevenueCatConfig {
  static const String iosApiKey = 'appl_gxAWIbbwkvywccAzLMWASShyoxx';
  static const String androidApiKey = 'test_VArPeRYeXEvZeHqaPqpUTDRDKaW';

  /// Entitlement identifier configured in the RevenueCat dashboard.
  /// Active when the user has any Pro subscription/purchase active.
  static const String proEntitlement = 'pro';

  /// Whether the embedded API keys still hold placeholder values. When true,
  /// services should bail out gracefully instead of calling into the SDK
  /// (no offerings to fetch, no products to display).
  ///
  /// The onboarding `test_*` key is treated as configured (not a placeholder)
  /// so the SDK actually initializes against RevenueCat's sandbox.
  static bool get isPlaceholder =>
      iosApiKey.startsWith('REPLACE_ME') ||
      androidApiKey.startsWith('REPLACE_ME');
}
