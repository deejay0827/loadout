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

## Firestore

- [ ] Audit `firestore.rules` before production — current rules are
  per-user only, no field-level validation.
- [ ] Configure scheduled Firestore backups (exports to GCS).
- [ ] Add composite indexes as queries grow.
- [ ] Decide on Spark vs Blaze plan. Spark is fine for early users; Blaze
  unlocks scheduled exports, Cloud Functions, phone auth, etc.

## Business / legal setup

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

## Production hardening

- [ ] Replace placeholder `test/widget_test.dart` with real coverage —
  models, repositories (with FakeFirebaseFirestore), auth flows.
- [ ] Add Firebase Crashlytics.
- [ ] Add Firebase Analytics.
- [ ] Set up CI (GitHub Actions or similar) for `flutter analyze` + tests
  on every PR.
- [ ] Versioning / release process.
