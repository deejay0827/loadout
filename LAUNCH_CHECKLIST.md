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

- [ ] **Enable Associated Domains capability on the App ID** —
  developer.apple.com → Identifiers → `com.johnsondigital.loadout` →
  check **Associated Domains** → Save. Required because the iOS *and*
  macOS entitlements files claim
  `applinks:loadout-precision-reloading.web.app` /
  `.firebaseapp.com`. Without this, code signing will reject the build
  on both platforms. The bundle ID is shared between iOS and macOS, so
  one capability toggle covers both.
- [ ] **Add release keystore SHA-256 to `public/.well-known/assetlinks.json`**
  once a Play Store upload key (or Play App Signing fingerprint) exists.
  Currently only the debug SHA is in the file, which means email-link
  sign-in won't auto-verify on Play Store builds. After updating, run
  `firebase deploy --only hosting`.
- [x] **Cross-device email-link UX.** When the user opens the sign-in
  link on a different device than the one that requested it,
  `tryCompleteEmailLink` returns `EmailLinkOutcome.needsEmail`. The
  `_AuthGate` in `lib/app.dart` shows a "Confirm your email" dialog
  and finishes sign-in via `completeEmailLinkWithEmail`.
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

- [ ] **Add the iOS Share Extension target in Xcode.** The Apple Notes /
  generic share-sheet recipe-import flow is wired up in Dart
  (`lib/services/share_handler_service.dart`), the Android intent
  filter is live, and the `share_handler ^0.0.25` package is in
  `pubspec.yaml`. iOS, however, requires a one-time Xcode Share
  Extension target add — same operator-only pattern as the watch app
  (CLAUDE.md § 15) and the OneDrive OAuth registration (§ 18).
  **Until this lands, LoadOut will not appear in the iOS share sheet
  from Apple Notes / OneNote-on-iOS / any text-share-capable app.**
  Full step-by-step Xcode walkthrough lives at
  `ios/ShareExtension/README.md`. Summary: File → New → Target → iOS
  → Share Extension; bundle id
  `com.johnsondigital.loadout.ShareExtension`; replace
  `ShareViewController.swift` with the minimal `ShareHandlerIosViewController`
  subclass; enable App Group `group.com.johnsondigital.loadout` on
  BOTH Runner and ShareExtension; set
  `IPHONEOS_DEPLOYMENT_TARGET = 15.0`; add a second target block to
  `ios/Podfile` pulling in `share_handler_ios`; `pod install`. Test
  on a real iOS device (the simulator does not enumerate third-party
  share extensions). Plan ~10 minutes operator time.
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

## Cloud Sync / OneDrive

- [ ] **Register the LoadOut OneDrive Sync app on portal.azure.com** and
  paste the Application (client) ID into
  `lib/services/onedrive_config.dart` (`OneDriveConfig.clientId`). See
  `CLAUDE.md` § 18 for the full step-by-step (account types =
  consumers, redirect URIs for iOS + Android, API permissions =
  `Files.ReadWrite.AppFolder` + `offline_access`, no client secret —
  PKCE only). Until this is done, the OneDrive cards / sync provider
  rows self-hide behind `OneDriveConfig.isPlaceholder`.
- [ ] **Verify OneDrive end-to-end** — sign in with a personal
  Microsoft account, confirm the per-app folder is created, run a
  manual cloud backup + restore, then turn on Cloud Sync and confirm
  AutoSave-driven uploads land within ~5s.
- [ ] **App Store / Play Store privacy disclosures** — add a Cloud
  Sync entry alongside the existing Cloud Backup entry. Both ship
  the same encrypted blob to the user's own cloud; the disclosure
  needs to call out the encrypted-at-rest, never-server-decryptable
  posture. Re-confirm on every store submission per CLAUDE.md § 13.
- [ ] **Native PKCE webview for OneDrive sign-in** — today
  `OneDriveBackupService.connectInteractive` is the entry point that
  persists a refresh token, but the actual interactive auth code
  exchange (browser tab + PKCE verifier) hasn't been wired into the
  Cloud Sync screen yet. Pick a webview package (`flutter_web_auth_2`
  or `webview_flutter`), implement the PKCE flow in
  `lib/screens/sync/cloud_sync_screen.dart`, then call
  `connectInteractive` with the resulting tokens. Until this lands,
  OneDrive Cloud Sync surfaces "Connect OneDrive" as a no-op.

## Production hardening

- [ ] Replace placeholder `test/widget_test.dart` with real coverage —
  drift integration tests with `NativeDatabase.memory()`, repository
  tests, key UI smoke tests.
- [ ] Add Firebase Crashlytics.
- [ ] Add Firebase Analytics (privacy-respecting — no logging of
  reloading data).
- [ ] Set up CI (GitHub Actions or similar) for `flutter analyze`
  + `dart run build_runner build` + `flutter test` on every PR.
  `flutter test` is non-negotiable — `test/assets_present_test.dart`
  catches missing `pubspec.yaml flutter.assets:` subdirectory
  declarations (the bug class that crashed the app at startup with
  "Unable to load asset" on a fresh install). Without it in CI, that
  whole class can regress without any compile-time signal.
- [ ] Versioning / release process.

## Reticle & scope data — verification

The verified scope+reticle catalog (schema v22+) ships ~47 scope models
across 19 brands. Some entries are sourced from manufacturer URLs
(`verified: true`); others have approximated geometry or a missing
subtension dictionary (`verified: false` — picker hides them by default).
The list below is the work that requires physical-world access (paper
manuals, dealer relationships) which I can't do programmatically.

- [ ] **Get Tier 3 reticle subtension PDFs** — 24 reticle entries across
  ZeroTech, Riton, Swarovski, Zeiss, Meopta, March, Sightron currently
  ship with `subtensionsJson: null` and `verified: false`. Most
  manufacturer PDFs are not extractable via WebFetch (paywalled,
  login-gated, JS-only viewers). Either:
  - Email each brand's optics-tech contact and request the subtension
    sheet, OR
  - Open the printed user manual that ships in the scope's box and
    type the subtension dimensions into each entry's `subtensionsJson`.
  Once filled, flip `verified: true` per row.
- [ ] **Confirm Hensoldt CCC + NSV reticles exist** — neither pattern is
  published by Hensoldt in any retrievable form. NSV is a night-vision
  attachment line, not a reticle. Confirm with Hensoldt USA whether
  these are real reticle names — if not, delete the entries.
- [ ] **Confirm March-X / March-FX exact SKUs** — DEON's product-code
  suffix pattern (`D50V56TI-MTR-1` etc.) was inferred from retailer
  pages; the box-printed SKU may differ. Photograph the SKU on a
  physical scope and verify against the JSON entries.
- [ ] **Confirm "Riton 5 PRIMAL" → 5 Conquer substitution** — the 5
  Primal 5-25x56 doesn't exist; substituted with the 5 Conquer 5-25x56.
  Documented in the entry's `notes` field. Confirm with Riton USA.
- [ ] **Confirm "Sightron SVII PLR 4.5-30x56" → SVIII 5-40x56
  substitution** — the SVII PLR 4.5-30x56 doesn't exist in the current
  Sightron catalog; substituted with the SVIII 5-40x56 FFP. Confirm
  with Sightron USA.
- [ ] **Source Sig Sauer Tango6T MSR-BDC6 per-yard mil drops** — the
  reticle is calibrated for 5.56/77gr SMK ballistics. Per-yard drops
  in the JSON were estimated from generic 5.56 ballistics; replace
  with the values from Sig's printed reticle manual.
- [ ] **Source Primary Arms ACSS-HUD-DMR per-yard drops for .308** —
  same shape: I estimated for 175gr SMK at 2600 fps. Real per-yard
  values live in PA's reticle PDF (download from primaryarmsoptics.com
  manually since WebFetch returned binary) and replace.
- [ ] **Verify Swarovski X5(i) / Z6i specs** — swarovskioptik.com
  returned 404 from automated WebFetch (rate-limited / bot-detected).
  Specs sourced from Greentop / SportOptics retailer mirrors. Open
  the manufacturer page in a browser and cross-check tube / clicks /
  travel / max-adjust against what we have.
- [ ] **Vortex EBR-2C MRAD/MOA + Horus TReMoR3 / H59 last 2%** — Horus
  reticles ship at ~98% renderable fidelity. The remaining 2% is
  peripheral ranging stadia + accessory bars at the extreme edges.
  Pull the latest Horus PDF revision from horusvision.com/dealer-portal
  (dealer login) and add the missing peripheral elements.
- [ ] **Add a `chevron` element type to the reticle renderer** —
  Horus chevron mil markers are currently approximated with two angled
  `crosshair` segments per chevron (40 chevrons × 2 segments × 2
  reticles = 160 surplus elements). A native `chevron` type in
  `lib/data/reticle_library.dart` + the painter would render cleaner
  and reduce element count. Small renderer change; geometry import is
  already correct, just verbose.

## Custom Drag Models (CDM) — strategic

- [ ] **Aggregate manufacturer-published CDM data instead of trying to
  match Applied Ballistics head-on.** AB's library is proprietary
  Doppler radar measurement and not licensable. The strategic answer
  is to expand our Hornady 4DOF support to also import:
  - Berger Tuning Calculator data (CSV exports — public)
  - Sierra published "match-grade" trajectory tables
  - Lapua published BC-vs-velocity curves
  - Older CDM data on JBM Ballistics
  Build a generic "import per-bullet drag table from CSV" path that
  the user pastes manufacturer data into. Marketing message: "use the
  drag data the bullet maker already publishes for your bullet" —
  not "we matched AB."

## Reticle & scope IP / trademarks (legal review needed)

- [ ] **Get a real lawyer's read on reticle name + geometry use.**
  See `docs/RETICLE_LICENSING.md` for the full risk analysis. Short
  version: **HIGH RISK on the Horus TReMoR / H series** (Horus Vision
  LLC is litigious about IP; trade dress + design patents on the
  geometry); **MEDIUM RISK on brand-specific reticles** (EBR, MOAR,
  MIL-XT, P4F — nominative fair use likely covers using the name to
  identify the scope's reticle option, but rendering an approximation
  of the design is grayer); **LOW / NO RISK on generic patterns**
  (mil-dot, plex, duplex — public domain).
- [ ] **Decide before launch** whether to:
  - (a) Pay for licensing — most likely impossible / too expensive
    for Horus + brand-specific.
  - (b) Replace high-risk named reticles with generic descriptors
    in the picker (e.g. "Horus TReMoR3" → "Horus-style mil grid",
    keep scope/manufacturer names since they're factual).
  - (c) Stay with the current approach (name + approximate render)
    PLUS add a clear disclaimer: "Reticle names and geometric
    representations are used for identification only. LoadOut is
    not affiliated with [Horus Vision LLC, Vortex Optics,
    Nightforce, Schmidt & Bender, etc.]. All trademarks belong to
    their respective owners."
  Option (c) is what most ballistic apps do (Strelok Pro, Geoballistics
  BalisticArc); the lawyer answer determines whether it's enough.
- [ ] **Build a generic "LoadOut Default" reticle as the rendered
  fallback** for the realistic-mode scope view. A clean Christmas-tree
  mil pattern designed by us, our own art. Users still PICK named
  reticles for hold-off math, but the default RENDERED visual is our
  own design — moves Horus geometry off the rendered surface and onto
  the hold-off math surface only (data, not visual reproduction).

## Test infrastructure

- [ ] **Repair the 12 widget tests fixed by removing runZonedGuarded
  workarounds** — long-term, these tests should not depend on the
  workaround pattern. Most landed cleanly (suite is green); the
  rewrites are noted in the test files' header comments. Confirm
  during the next QA pass that the tests still verify what they
  intend to verify, not just that the screen mounts without throwing.
- [ ] **Codify the published Applied-Ballistics / JBM regression suite** — the
  external-validation answer (see CLAUDE.md §20 + `precision_regression_test.dart`).
  ~5–10 reference projectiles × 2 atmospheres × 5–6 ranges, asserting
  each row matches the published *Applied Ballistics* / JBM tables
  within ±0.1 mil at ≤ 1000 yd. The suite is in place; per-row
  citations still need to be filled in by reading from a printed copy
  of *Applied Ballistics for Long-Range Shooting* 2nd ed.

## Hardware / device QA

- [ ] **Real-device QA pass for Range Day**: dropdown filter-chip flow
  (target / category), empty-state load picker (Quick + Common Loads),
  target preview row, fullscreen reticle viewer + daytime backdrop,
  rack-of-targets switch, view-mode toggle (Realistic vs Target-
  Focused), rangefinder pairing.
- [ ] **Test reticle picker `verified` flag UX** — does the warning
  chip on unverified entries read correctly to a power user? Adjust
  copy if it sounds patronizing.
- [ ] **Smoke-test rate limiting** on the AI Smart Import worker —
  fire-hose 30+ requests in a minute and confirm 429 with `Retry-After`
  header. Optional but useful before scaling. (See § AI Smart Import.)
