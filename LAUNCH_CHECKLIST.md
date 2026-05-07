# LoadOut — Pre-launch checklist

Things to handle before submitting to the App Store / Play Store. I'll keep
this updated as new items come up.

## Security & credentials

- [ ] **Rotate Azure AD client secret** — current one was pasted in chat
  history (LoadOut app, created 2026-05-06). Once Microsoft sign-in is
  verified end-to-end, regenerate in Azure → Certificates & secrets, send
  the new value, and I'll update Firebase via API.
- [ ] **Plan Azure AD secret expiry rotation** — current secret expires
  ~2028-05-06. Either set a calendar reminder for ~April 2028 or move to a
  certificate-based credential (Azure supports both; certs can have longer
  validity).
- [ ] **Register release keystore SHA-1 / SHA-256 with Firebase (Android)**
  — only the debug keystore is registered today, which means Google
  Sign-In will not work on a Play Store build. Register the upload key
  (or, preferably, the SHA from Play App Signing once a build is
  uploaded).
- [ ] **Rotate Yahoo client secret** — current one was pasted in chat
  history (created 2026-05-06). Yahoo secrets don't auto-expire, but
  regenerate after Yahoo sign-in is verified end-to-end. Yahoo Developer
  → LoadOut app → reset client secret, send new value.
- [ ] **Regenerate Apple Sign-In client_secret JWT** before
  **2026-11-02** (Apple caps the JWT at 180 days; sign-in breaks if it
  expires). Calendar reminder for ~mid-October 2026. Action: re-sign a
  new JWT with the existing `.p8` key (same Team ID, Key ID, Services
  ID), POST to Firebase via Identity Platform API. This will be a
  recurring 6-month chore unless we automate it via Cloud Functions.
- [ ] **Store the Apple `.p8` private key in a password manager** (1Password
  / similar). It's the long-lived material — losing it means revoking
  the key and minting a new one in Apple Developer, which invalidates
  every JWT signed with it. Apple `.p8` files cannot be re-downloaded.
- [ ] Rotate the Apple `.p8` key itself after launch (chat-history
  concern). Generate a new key in Apple Developer → Keys, send me the
  new `.p8` + Key ID, I'll regenerate the JWT.

## Monetization (RevenueCat / IAP)

> **Pricing decision (2026-05-07):** Two SKUs only — Yearly + Lifetime. Reloading is a slow-cycle hobby; monthly subscriptions churn hard on hobby tools. Yearly matches seasonal usage; Lifetime captures committed users. Prices follow the GUNR competitive reference: **Yearly $39.99/yr, Lifetime $79.99**. The app is pre-launch, so there are no monthly subscribers to grandfather — never create the monthly product anywhere.

- [ ] **Sign up for RevenueCat** at https://app.revenuecat.com and create the LoadOut project.
- [ ] **Set up App Store Connect IAP** — create the LoadOut app entry, complete tax and banking, generate an App Store Connect API key (`.p8`) for RevenueCat, generate the App-Specific Shared Secret. Define **two** products: `loadout_pro_yearly` (auto-renewing subscription, **$39.99/yr**), `loadout_pro_lifetime` (non-consumable, **$79.99**). Do NOT create `loadout_pro_monthly`.
- [ ] **Set up Google Play Console IAP** — complete the payments profile, create the service account JSON, define the same two products under Monetize at the same prices.
- [ ] **Connect both stores to RevenueCat** in the RevenueCat dashboard. Create the `pro` entitlement and attach both products to it. Create a `default` offering with **yearly + lifetime** packages only (no monthly).
- [x] iOS RevenueCat key (`appl_*`) plugged into `lib/services/revenue_cat_config.dart`.
- [ ] **Replace the Android RevenueCat key** in `lib/services/revenue_cat_config.dart` with the real `goog_*` key once the Android app is set up in RevenueCat (blocked on Google Play identity verification).
- [ ] **Sandbox-test purchases** — at least one round-trip per platform (purchase, restore, cancel) before any TestFlight / internal-testing build goes out.
- [ ] **Add a Privacy Policy URL** to both store listings (required before IAP can ship).
- [ ] **First Pro feature gate live** — at least one Pro feature actually behind `ProGate` so users can see what they get.

## Authentication

- [ ] **Enable Associated Domains capability on the iOS App ID** —
  developer.apple.com → Identifiers → `com.johnsondigital.loadout` →
  check **Associated Domains** → Save. Required because the entitlements
  file now claims `applinks:loadout-precision-reloading.web.app` /
  `.firebaseapp.com`. Without this, iOS code signing will reject the
  build.
- [ ] **Add release keystore SHA-256 to `public/.well-known/assetlinks.json`**
  once a Play Store upload key (or Play App Signing fingerprint) exists.
  Currently only the debug SHA is in the file, which means email-link
  sign-in won't auto-verify on Play Store builds. After updating, run
  `firebase deploy --only hosting`.
- [ ] **Cross-device email-link UX.** When the user opens the sign-in
  link on a different device than the one that requested it,
  `tryCompleteEmailLink` returns null because the pending email isn't
  in local storage. Add a prompt for the user to enter their email in
  that case.
- [ ] Decide on anonymous → permanent account linking UX
  (`linkWithCredential`).
- [ ] Add a "Verify your email" banner / gate on the home screen for
  users whose `emailVerified` is false (currently we send a verification
  email on signup but don't enforce verification anywhere).
- [ ] Verify the first iOS device build (signing actually succeeds with
  `DEVELOPMENT_TEAM = 7265YL85SB` + Sign In with Apple + Associated
  Domains entitlements). Build compiles clean without code signing as of
  this commit.

## Live catalog updates (Firebase Storage)

The reference catalog (cartridges, powders, bullets, primers, brass,
firearms, parts) is pulled on cold start from Firebase Storage so we can
ship JSON corrections without a store release. See
`lib/services/seed_updater.dart` and `docs/seed-data-deployment.md`.

- [ ] **Enable Firebase Storage on the project** — Firebase Console →
  Storage → Get started. Choose the same region as the rest of the
  project. The default bucket is
  `loadout-precision-reloading.firebasestorage.app`.
- [ ] **Deploy the storage rules** — `storage.rules` is checked into the
  repo and wired into `firebase.json`. Deploy with:
  ```sh
  firebase deploy --only storage
  ```
  These rules grant `read: if true` for `seed_data/*` (so unauthenticated
  installs can fetch updates) and `write: if request.auth != null` (so
  only signed-in developers can mutate the bucket from the console /
  CLI).
- [ ] **Initial bucket population** — upload the seed JSON files to
  `gs://loadout-precision-reloading.firebasestorage.app/seed_data/`:
  - `manifest.json` (copy of `assets/seed_data/manifest.json`)
  - `cartridges.json`, `powders.json`, `bullets.json`, `primers.json`,
    `brass.json`, `firearms.json`, `firearm_parts.json` (one-for-one
    copies of `assets/seed_data/*.json`).

  Easiest path: Firebase Console → Storage → Upload folder. Or via
  `gsutil`:
  ```sh
  gsutil -m cp assets/seed_data/*.json \
    gs://loadout-precision-reloading.firebasestorage.app/seed_data/
  ```
- [ ] **Verify the round-trip** — run the app on a fresh simulator with
  the network on, kill it, edit (say) a cartridge name in a copy of
  `cartridges.json`, bump `cartridges.version` from `1` to `2` in the
  bucket's `manifest.json`, re-upload both, and relaunch the app twice
  (first launch downloads + flags; second launch re-seeds).
- [ ] **Document in `REVENUECAT_SETUP.md` / onboarding** that the seed
  JSON files in `assets/` are the source-of-truth and the bucket should
  always be uploaded from there — never edited in place in the bucket.
- [ ] **Decide on Spark vs Blaze plan.** Firebase Storage is included in
  the Spark plan up to a small free quota that is more than enough for
  text JSON downloads at our user volume.

## Local data store (drift / SQLite)

- [x] **Migrated from Firestore to local SQLite via `drift`.** User reload
  data (loads, firearms, custom components) lives only on the device.
  Firebase Auth still handles identity. `cloud_firestore` removed.
- [ ] Database migrations — `schemaVersion` is 1. Bumping requires writing
  migration steps in `MigrationStrategy`. Test on a real device before
  shipping any schema change.
- [ ] Optional: Cloud backup / multi-device sync as an opt-in feature
  (would need new privacy disclosure). Currently not on the roadmap.
- [ ] Optional: export-to-CSV / JSON so users can back up their loads
  manually.
- [ ] Firestore rules / hosting / database — `firestore.rules` and the
  `(default)` Firestore database are still provisioned but unused. We
  could either delete them or keep them dormant in case the privacy
  posture changes. Hosting is still used for the AASA / assetlinks
  files, so don't delete that.
- [ ] Decide on Spark vs Blaze plan. Spark is fine for current usage
  (Auth + Hosting). Blaze only matters if we re-add Firestore, Cloud
  Functions, or phone auth.

## Business / legal setup

- [ ] **EU Digital Services Act (DSA) trader info** — App Store Connect
  requires a publicly visible address, phone, and email for the EU
  product page. Picking "trader" is required to distribute in the EU
  (and the paid Pro tier makes us a trader). For now, can use personal
  or virtual-mailbox info. Update this **after incorporation** to use
  the LLC's registered business address. Apple Connect → App Information
  → Digital Services Act Compliance.
- [ ] **Get an EIN** (free, instant online via irs.gov/ein) — required for
  business Apple Developer + Play Console accounts.
- [ ] **Get a DUNS number** for the business (free from Dun & Bradstreet,
  5–30 day turnaround) — required by Apple for organization Developer
  accounts.
- [ ] **Convert Apple Developer account from personal → organization**
  before launch. Currently enrolled as personal under
  `info@johnsondigitalsystems.com`. Apple doesn't support an in-place
  upgrade — the workflow is: enroll a new org account with the same email
  (or a separate one), then submit an App Transfer to move the LoadOut
  app from personal to org. Easier to do **before** the app is live and
  generating revenue.
- [ ] Re-issue Sign in with Apple credentials (Services ID, Key) under the
  new org Team ID once converted — those are tied to the Team that
  created them.
- [ ] Same consideration for Google Play: enroll Play Console as a
  business once EIN/DUNS are in place.

## iOS submission

- [ ] Apple Developer Program enrollment ($99/yr) — currently personal,
  see "Business / legal setup" above.
- [ ] App Store Connect listing — name: **LoadOut: Precision Reloading**.
- [ ] Replace default Flutter app icon and launch screen.
- [ ] Privacy Policy URL + Terms of Service URL (required by Apple).
- [ ] **Confirm firearms / reloading content is allowed under App Store
  Review Guidelines** — reloading apps exist in the store but face extra
  scrutiny under guideline 1.4.1. Worth researching before investing in
  store assets.
- [ ] Sign in with Apple capability — Apple requires this if any other
  social sign-in is offered (Google, Microsoft, Yahoo all count).
- [ ] Age rating (likely 17+ given content).
- [ ] Screenshots, app description, keywords.

## Android submission

- [ ] Google Play developer account ($25 one-time).
- [ ] Play Console app listing.
- [ ] Replace default Flutter app icon and launch screen.
- [ ] Privacy Policy URL + Data Safety form.
- [ ] **Confirm firearms / reloading content allowed under Play policies.**
- [ ] Content rating questionnaire.
- [ ] Screenshots.

## App functionality

- [ ] Load development tracking (range data) — schema for batches +
  individual firings (velocity, ES, SD, group size, temperature, date)
  matching the user's existing Excel workflow. Tables not yet created;
  start with `LoadBatches` + `LoadFirings` linked to `UserLoads`.
- [ ] Inventory tracking — quantity-on-hand for powder (gr), bullets
  (count), primers (count), brass (count). Decrement on a "loaded N
  rounds" action.
- [ ] Loading log — record when a recipe was loaded, how many, and which
  brass batch was used.
- [ ] Cost tracking — optional per-component cost so the app can show
  cost-per-round.

## Production hardening

- [ ] Replace placeholder `test/widget_test.dart` with real coverage —
  drift integration tests with `NativeDatabase.memory()`, repository
  tests, key UI smoke tests.
- [ ] Add Firebase Crashlytics.
- [ ] Add Firebase Analytics (privacy-respecting — no logging of
  reloading data).
- [ ] Set up CI (GitHub Actions or similar) for `flutter analyze`
  + `dart run build_runner build` + tests on every PR.
- [ ] Versioning / release process.
