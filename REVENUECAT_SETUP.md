# RevenueCat setup — LoadOut

LoadOut uses RevenueCat to handle in-app purchases (a yearly subscription
and a lifetime SKU) on both iOS and Android. The Flutter code is already
wired up via `purchases_flutter`. What's left is configuring the three
pieces that have to be done outside the codebase.

> **Pricing decision (2026-05-07):** Two SKUs only — Yearly **$39.99/yr**
> and Lifetime **$79.99**. Pricing matches the GUNR competitive reference.
> Reasoning: reloading is a seasonal hobby with low open-app cadence;
> monthly subscriptions churn hard. Yearly aligns with hunting/match
> seasons; Lifetime captures committed users. The app is pre-launch — no
> monthly tier exists or ever existed in production, so don't create one
> in App Store Connect, Play Console, or RevenueCat.

## Identifiers we'll use

| | |
|---|---|
| Bundle / package | `com.johnsondigital.loadout` |
| Entitlement | `pro` |
| Products | `loadout_pro_yearly`, `loadout_pro_lifetime` |

## Step 1 — App Store Connect (iOS)

1. Sign in to App Store Connect.
2. Create the LoadOut app entry if you haven't (My Apps → +).
3. Set up tax and banking (required before any IAP can be sold).
4. App Information → Bundle ID matches `com.johnsondigital.loadout`.
5. Generate an App Store Connect API key:
   - Users and Access → Integrations → App Store Connect API → Generate API Key.
   - Role: Admin (RevenueCat needs this to read subscription events).
   - Save the `.p8` file. Note the Key ID and Issuer ID.
6. Create the In-App Purchase products:
   - Features → In-App Purchases → +.
   - **Auto-Renewable Subscription (yearly):**
     - Reference name: "LoadOut Pro Yearly"
     - Product ID: `loadout_pro_yearly`
     - Subscription group: "LoadOut Pro" (create new)
     - Subscription duration: 1 year
     - Price: **$39.99** (USD; localize for other regions)
   - **Non-Consumable (lifetime):**
     - Reference name: "LoadOut Pro Lifetime"
     - Product ID: `loadout_pro_lifetime`
     - Price: **$79.99**
7. Add localized metadata (required by Apple before products can be
   approved): display name, description per locale.
8. Generate an App-Specific Shared Secret:
   - Apps → LoadOut → App Information → App-Specific Shared Secret →
     Generate. Copy this — RevenueCat needs it.

## Step 2 — Google Play Console (Android)

1. Sign in to Google Play Console.
2. Create the app entry if needed.
3. Set up payments profile (Settings → Payments) — required before IAP.
4. Monetize → Products → Subscriptions:
   - Subscription product ID: `loadout_pro_yearly`, base plan: `yearly`,
     auto-renewing, billing period 1 year, price **$39.99/yr**.
5. Monetize → Products → In-app products:
   - `loadout_pro_lifetime`, managed product, single one-time purchase,
     price **$79.99**.
6. Service account for RevenueCat:
   - In Google Cloud Console (linked from Play Console settings),
     create a service account.
   - Role: minimal — just "Service Account User" + grant access in Play
     Console under Users and Permissions.
   - Download the service account JSON key. RevenueCat needs this.
7. Link service account to the app in Play Console: Users and
   Permissions → Invite new user → use the service account email,
   grant "View financial data, orders, and cancellation survey
   responses" + "Manage orders and subscriptions".

## Step 3 — RevenueCat Dashboard

1. Sign up at https://app.revenuecat.com.
2. Create a project: "LoadOut".
3. Add the iOS app:
   - Bundle ID: `com.johnsondigital.loadout`
   - Upload the App Store Connect `.p8` API key + Issuer ID + Key ID.
   - Paste the App-Specific Shared Secret.
4. Add the Android app:
   - Package name: `com.johnsondigital.loadout`
   - Upload the service account JSON.
5. Define the entitlement:
   - Entitlements → New: `pro`.
6. Define products by attaching the App Store and Play Store products:
   - Products → Import from App Store / Play Store.
   - Verify both appear: yearly, lifetime.
   - Attach each product to the `pro` entitlement.
7. Define an offering:
   - Offerings → New: "default".
   - Add two packages: annual, lifetime; each linked to the
     corresponding product.
8. Get the API keys:
   - Project settings → API Keys.
   - Copy the iOS (public) key and the Android (public) key.

## Step 4 — Wire keys into the code

Edit `/Users/general/Development/Applications/LoadOut/lib/services/revenue_cat_config.dart`:

```dart
class RevenueCatConfig {
  static const String iosApiKey = 'appl_xxxxxxxxxxxxxxxxxxxx';
  static const String androidApiKey = 'goog_xxxxxxxxxxxxxxxxxxxx';
  static const String proEntitlement = 'pro';
}
```

The keys are public (RevenueCat calls them "API keys" but they're safe
to commit and ship in client apps; the actual secret keys live on
RevenueCat's servers).

## Step 5 — Sandbox testing

### iOS

1. App Store Connect → Users and Access → Sandbox Testers → +.
2. Create a sandbox account (use a fresh email — Apple requires it not
   match any existing Apple ID).
3. On a real iOS device, sign out of your real App Store account in
   Settings → App Store → Sandbox Account.
4. Run the app via Xcode (sandbox testing only works with TestFlight /
   Xcode-installed builds, not App Store-installed builds).
5. Tap a buy button. Sign in with the sandbox tester. The purchase
   completes for free. Cancellation/renewal happens on accelerated
   timelines (1 month becomes 5 minutes).

### Android

1. Play Console → Setup → License Testing → add a Gmail account as a
   tester.
2. Upload an internal test build to Play Console (Internal testing
   track).
3. Add yourself as a tester for the internal track and accept the
   invitation link on the test device.
4. Install the app via the Play Store testing link.
5. Tap a buy button. The purchase happens for real-currency-amount but
   on a tester account it's automatically refunded after a few minutes.

## Pricing

Set 2026-05-07, matching the GUNR competitive reference:

| SKU | Tier | Price |
|---|---|---|
| `loadout_pro_yearly` | Yearly | **$39.99/yr** |
| `loadout_pro_lifetime` | Lifetime | **$79.99** |

Consider a 14-day free trial on the yearly subscription before launch.

## Going live

Before submitting the app to either store:

- All three products are in "Ready to Submit" status.
- Subscription group has at least one localized display name.
- Privacy Policy URL set in both stores (links to PRIVACY_POLICY.md
  hosted somewhere public — Firebase Hosting works).
- Tax and banking complete in App Store Connect.
- Payments profile complete in Play Console.
