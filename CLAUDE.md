# CLAUDE.md

Project guide for the LoadOut Flutter app. Optimized for LLM consumption: brief,
practical, focused on what is non-obvious or easy to get wrong.

## 0. NEVER SHIP PLACEHOLDER DATA FOR BALLISTICS-AFFECTING FIELDS (firm rule)

**Anything that flows into the ballistics solver — bullet, rifle,
environment — starts EMPTY. Never pre-fill those fields with
placeholder values, ever.** Yardage / distance fields are the only
exception (see below); non-ballistics fields like inventory counts
can use helpful defaults.

### The four scope buckets

| Category | Examples | Placeholder rule |
|---|---|---|
| **Bullet** | Diameter, weight, length, BC, drag model, twist | **NO placeholder.** Empty until the user picks a load / profile / common factory load. |
| **Rifle** | Muzzle velocity, twist rate, twist direction, MV temp sensitivity | **NO placeholder.** Empty until the user picks a load / profile / firearm. *Named exceptions:* **default zero range** pre-fills to `'100'` yd, **sight height** pre-fills to `'2.0'` in, and **scope tracking calibration** (sight-scale vertical / horizontal) pre-fills to `'1.000'` for new firearms. All three are universal de-facto conventions the user reads as "sensible starting point I can change" — sight scale 1.0 specifically means "no correction" (perfect turret tracking), which is the correct neutral assumption when the user hasn't measured their scope. Edits never overwrite saved values. |
| **Environment** | Temperature, station pressure, humidity, altitude, wind speed, wind direction, latitude (Coriolis) | **NO placeholder.** When all empty, the solver uses ICAO standard internally and the env summary surfaces "Using ICAO standard atmosphere" so the user knows the source. |
| **Yardage / distance** | Range Day target distance, firearm default zero range, ballistics calculator output range | **Placeholder OK** when it materially helps the user (100 yd zero, 500 yd target distance, 1000 yd ladder max). The user reads the placeholder as "sensible default I can change" rather than as their own input. |
| **Non-ballistics** | Brass lot count, batch round count, shots-fired counter, "Record Firing" / "Fire Rounds" dialog steppers, recipe / firearm names | **Placeholder OK.** These don't drive a computed firing solution; defaults are pure ergonomics. |

### Why the bullet / rifle / environment trio is sacred

Reloaders are precision people who immediately distrust an app that
computes a firing solution from invisible defaults. A fake `8 mph @
9 o'clock` wind in the Range Day strip, a `140 gr ELD-Match`
showing up when the user picked nothing, or a "9.8 MOA at 500 yd"
derived from a default BC the user can't see — every one of these
makes them suspect the rest of the screen too. The shooting-side
brand promise is "the math is yours, and ours, and we never invent
your inputs."

This rule has been violated twice and customer-facing both times:

- Range Day was rendering Group Stats / Hit Probability gauges from
  placeholder controllers when the user had picked no load.
- The Range Day Solution strip was showing `Wind 8 mph @ 9 o'clock`
  because `_windSpeedCtrl` defaulted to `'8'`.

The user flagged each as "we'd lose customers." Treat that
literally — for the bullet / rifle / environment fields, this is
the load-bearing brand promise of a precision tool. Yardage and
inventory counters do not carry the same risk.

### What this means in practice

- **Ballistics-affecting `TextEditingController` defaults are empty.**
  `TextEditingController()`, not `TextEditingController(text: '2750')`.
  The solver reads `_parseOpt(...)` and either uses an internal
  ICAO fallback (atmosphere) or refuses to render computed output
  (bullet / rifle).
- **Computed cards refuse to render fake numbers.** When the source
  inputs aren't user-provided (no load picked, no firearm picked,
  no shots logged), the card shows an empty-state explanation —
  never a number derived from placeholders. See `_hasRealLoadData()`
  in `range_day_detail_screen.dart` for the reference pattern.
- **Summary chips, header strips, and exports skip the ballistics
  field entirely when empty.** Don't render `0` / `—` / `N/A` next
  to a fake unit. Reference patterns: Range Day strip wind chip
  (hides when wind = 0), `_envSummary()` (says "Using ICAO standard
  atmosphere" when no env entered), DOPE clipboard text.
- **Atmosphere has a special pattern.** The solver still needs an
  atmosphere; we use ICAO standard as an internal fallback when the
  user hasn't entered actual conditions, AND we tell the user
  visibly that we did so ("Using ICAO standard atmosphere"
  indicator). The user sees the disclosure, not the fake values.
- **Reference catalog rows are NOT placeholder data.** SAAMI specs,
  manufacturer-published BCs, the ICAO standard atmosphere as a
  solver fallback, Hornady 4DOF curves — these are factual published
  values, clearly attributed in the Data Sources screen. Allowed.
- **Default UI selections are allowed** when the user sees them
  and can swap (default Range Day target = "18 × 30 IPSC", default
  reticle = "Classic Mil Hash"). The user can see what was picked.
- **Yardage placeholders should be common, sensible values.**
  Range Day target distance = `'500'` (mid-range PRS distance).
  Firearm default zero range = `'100'` (de-facto reloader
  convention). Ballistics calculator output range = `_kRangeMin /
  _kRangeMaxDefault`. These are rounding errors in the user's mental
  model, not surprising values.

### When in doubt

For bullet / rifle / environment fields: **leave the field empty
and hide / empty-state any downstream surface that would derive
numbers from it.** For yardage: pre-fill with a common-sense
default the user would type anyway. For non-ballistics: use
whatever helps the workflow.

When adding any new form, controller, or computed card, write down
in the file header which inputs flow into ballistics and which
don't. Anything in the first bucket follows the no-placeholder rule.

## 0a. ALWAYS USE TITLE CASE FOR LABELS AND HEADERS (firm rule)

**Every user-visible label or header in this app uses Title Case.**
This applies to AppBar titles, card headers, section labels, button
text, dropdown labels, tab names, empty-state headings, dialog
titles, glossary entries, and any string that names a thing the
user can interact with.

### Why

The app is precision tooling for a meticulous audience. Mixed casing
("Ballistic profile" next to "Firing Solution" next to "saved
loads") reads as sloppy — it's the same kind of small inconsistency
that makes reloaders distrust everything else on the screen.
Consistent Title Case across the surface telegraphs care.

### How to apply

Use AP-style Title Case:
- **Capitalize** the first and last word, plus all nouns, verbs,
  adjectives, adverbs, pronouns, and subordinating conjunctions
  (because, although, if, when).
- **Lowercase** articles (a, an, the), coordinating conjunctions
  (and, but, or, nor), and short prepositions of three letters or
  fewer (in, on, at, of, to, by, for) — UNLESS they're the first
  or last word of the title.
- Always capitalize prepositions of four letters or more (Over,
  With, From, Into, Upon).
- Keep canonical product / brand capitalization as-is even when it
  breaks the rule (LoadOut, iCloud, RevenueCat, ICAO, MOA, MIL,
  COAL, CBTO, BC, fps, ft-lbs, OneDrive).
- Keep parenthetical units lowercased ("Distance (yd)", not
  "Distance (Yd)") — units are technical glyphs, not display text.

### Examples (correct → wrong)

| ✅ Correct | ❌ Wrong |
|---|---|
| Ballistic Profile | Ballistic profile |
| Firing Solution | Firing solution |
| No Saved Ballistic Profiles | No saved ballistic profiles |
| Pick a Common Load | Pick a common load |
| Create a Ballistic Profile | Create a ballistic profile |
| Hit Probability Map | Hit probability map |
| Scope Tracking Test | Scope tracking test |
| Distance (yd) | Distance (Yd) — units stay lowercase |
| Save Session | Save session |

### What's NOT in scope

- **Body copy** — paragraph text, helper text, descriptions, hint
  text inside form fields, error messages. These are sentences;
  they use sentence case.
- **Inline glossary definitions** and other prose blocks.
- **Code identifiers, log messages, debug strings, telemetry tags.**
  These never reach the user.

If in doubt: is this a NAME of something (button, card, section,
screen, picker option)? → Title Case. Is it a SENTENCE describing
something? → sentence case.

## 0b. WORK STYLE (firm rules)

These rules govern how Claude approaches tasks in this repo. The user
has been explicit that they prefer thoroughness over speed and parallel
agent dispatch over sequential single-thread work.

### 1. No time / scope ceilings

**There is no implicit time limit on any task.** Don't say "this is
bigger than time allows" or "I'll defer this to a follow-up because
it's large." Take however much time the right fix needs. The user is
explicit: "I did not give you a time limit." If a task requires
rewriting a 500-line file, refactoring a service, or touching 30
files, do all of it. Half-shipping a feature and leaving the rest
as a TODO is a failure mode here, not a virtue.

The single exception: when an action is genuinely irreversible
(force-push, drop database table on prod, etc.) and the user hasn't
authorised it, ask first. Otherwise, do the whole job.

### 2. Always dispatch unlimited agents in parallel when work can be split

When a task can be decomposed into independent sub-tasks that don't
contend for the same files, **dispatch background agents in parallel
and let them work concurrently with your main-thread work.**
Examples:

- Designing a new seed catalog file (`assets/seed_data/*.json`) →
  dispatch a `general-purpose` agent to write it while you wire the
  consumers in code.
- Finding all code dependencies on a soon-to-be-renamed symbol →
  dispatch an `Explore` agent to grep, while you start the rename.
- Auditing an entire screen surface for label / Title Case
  violations → dispatch in the background, process the punch list
  when it returns.
- Anything that requires READING many files and producing a report
  → almost always faster as a parallel agent than serial reads
  from your own tool budget.

There is no upper bound on how many agents you may dispatch. If
five sub-tasks are independent, launch five agents in one message.
Send them in a SINGLE assistant turn (`run_in_background: true`)
so they execute concurrently rather than serially.

### 3. Default to the parallel path, not the serial one

When you catch yourself thinking "I'll do A first, then B, then C
sequentially because they all touch the codebase" — stop and ask
whether A / B / C touch DIFFERENT files. If yes, parallelise. If
they all conflict on the same file, serial is fine. The cost of
spinning up an extra agent is trivial; the cost of doing serial
work that could have been parallel is real wall-clock time the
user is waiting on.

### 4. When in doubt, do it the right way, not the quick way

If two paths exist — "patch the symptom" vs. "fix the underlying
cause" — pick the underlying-cause path even when it's bigger.
"Quick" patches that leave the same class of bug latent in the
codebase have already burned the user's trust twice (Litz removal
took multiple passes; placeholder data took three rounds). Pay the
upfront cost to make the class of bug impossible.

## 1. What it is

LoadOut is a local-first ammo reloading tracker for **iOS, Android, macOS,
and the web**, built in Flutter. It lets a reloader catalog their loads,
firearms, and components without sending any of that data off-device. The
web target ships the same UI (the responsive `NavigationRail` + master-detail
layout already serves desktop browser widths well) and stores user data in
the browser via OPFS / IndexedDB through drift's WASM build (see § 18).

| | |
|---|---|
| App name | LoadOut |
| Store name | LoadOut: Precision Reloading |
| Bundle ID / Android package | `com.johnsondigital.loadout` |
| Firebase project ID | `loadout-precision-reloading` |
| Flutter SDK | `^3.11.5` (see `pubspec.yaml`) |
| App version | `1.0.0+1` |

## 2. Architecture and data model

The app is **local-first**:

- **SQLite via `drift`** is the only persistent store on device.
- **Firebase Auth is the only Firebase service used at runtime.** No Firestore,
  no Storage, no Functions. (`firestore.rules` and `firestore.indexes.json`
  exist but no code reads or writes Firestore. Treat them as legacy until
  removed.)
- **Reference data** (cartridges, powders, bullets, primers, brass, firearms,
  parts) ships as JSON in `assets/seed_data/` and is seeded into SQLite on
  first launch via `lib/database/seed_loader.dart`.
- **User data** (loads, firearms, custom components) is local-only. It never
  leaves the device. This is a marketing promise — see Privacy posture below.

### Drift tables (`lib/database/database.dart`)

Reference (seeded, read-only at runtime):

- `Manufacturers` — name, country, `kind` (`powder|bullet|primer|brass|firearm|parts`).
- `Cartridges` — name, type (`pistol|rifle|shotgun`), dimensions, `aliasesJson`.
- `Powders` — manufacturer FK, name, type, form, burn rate.
- `Bullets` — manufacturer FK, line, diameter, weight, design, jacket, BCs.
- `Primers` — manufacturer FK, name, size, magnum flag.
- `BrassProducts` — manufacturer FK, tier, `calibersJson`.
- `FirearmsRef` — manufacturer FK, model, type, action, `calibersJson`.
- `FirearmParts` — manufacturer FK, name, category, `compatibleWithJson`.

User data (writable):

- `CustomComponents` — `kind` + `name` (unique together), notes, `createdAt`.
  User-added powders/bullets/primers/brass/cartridges. They appear alongside
  reference items in dropdowns.
- `UserLoads` — load recipe rows (caliber, powder, charge, bullet, primer,
  brass, COAL, CBTO, seating depth, primer depth, shoulder bump, mandrel,
  date established, notes, timestamps).
- `UserFirearms` — name, manufacturer, model, type, action, caliber, barrel
  length, twist rate, shotsFired, optional `referenceFirearmId` linking back
  to `FirearmsRef`, notes, timestamps.

JSON-encoded text columns are used wherever we need a list (aliases, calibers,
compatibleWith). Decode with `json.decode(...) as List<dynamic>`.

### Runtime wiring

- `lib/main.dart` initializes Firebase, opens `AppDatabase`, runs
  `SeedLoader.seedIfNeeded()`, then runs `LoadOutApp`.
- `lib/app.dart` provides `AppDatabase`, `AuthService`, the three repositories,
  and a `StreamProvider<User?>` to the widget tree, then routes between
  `LoginScreen` and `HomeScreen` based on the auth stream. Also wires up
  `app_links` to catch email-link sign-in deep links.

## 3. File structure

```
lib/
  main.dart                        Firebase init + DB seed + runApp
  app.dart                         Root widget, providers, auth gate, deep links
  firebase_options.dart            Generated by flutterfire configure
  theme/app_theme.dart
  database/
    database.dart                  Drift table definitions + AppDatabase class
    database.g.dart                GENERATED — never edit
    seed_loader.dart               Reads assets/seed_data/*.json into SQLite
  repositories/
    component_repository.dart      Reference + custom components for dropdowns
    firearm_repository.dart        UserFirearms CRUD + adjustShotsFired
    load_repository.dart           UserLoads CRUD
  services/
    auth_service.dart              All FirebaseAuth provider wrappers
  screens/
    auth/login_screen.dart
    home/home_screen.dart          Bottom-nav shell: Loads / Firearms / Glossary / SAAMI
    loads/                         loads_list_screen.dart, load_form_screen.dart
    firearms/                      firearms_list_screen.dart, firearm_form_screen.dart
    saami/saami_screen.dart        Cartridge picker + spec card
    glossary/glossary_screen.dart  Searchable reloading-terms reference
  widgets/
    component_field.dart
assets/seed_data/                  JSON source for the reference catalog
public/
  index.html                       Tiny landing page, also handles /auth/* deep-link rewrites
  .well-known/
    apple-app-site-association     Universal Links for iOS
    assetlinks.json                App Links for Android
android/                           Standard Flutter Android scaffold
ios/                               Standard Flutter iOS scaffold
macos/                             Standard Flutter macOS scaffold
web/                               Flutter web platform — see § 18
  index.html                       Branded title + theme color #1F2937
  manifest.json                    PWA manifest (charcoal + brass)
  drift_worker.dart                Drift web worker entry point (compiled to .js)
  drift_worker.dart.js             Built artifact — committed so Hosting deploys can serve it
  sqlite3.wasm                     Drift's sqlite3 WebAssembly build, downloaded from
                                   https://github.com/simolus3/sqlite3.dart/releases
firestore.rules                    Per-user rules; not currently used by the client
firestore.indexes.json             Empty
firebase.json                      Hosting + Firestore + Flutter platform config
LAUNCH_CHECKLIST.md                Pre-launch open items (canonical TODO list)
SETUP.md                           Setup + day-to-day commands
```

> Note: `firestore.rules` and `firestore.indexes.json` are deployed but
> unused by the client. Hosting (`public/`) is still active for the AASA
> and assetlinks files — don't delete it.

## 4. Auth providers configured

All seven sign-in methods are wired through `lib/services/auth_service.dart`:

1. **Email / password** — `signIn`, `signUp` (sends verification email).
2. **Email link (passwordless)** — `sendEmailLink` + `tryCompleteEmailLink`.
   Pending email is stashed in `SharedPreferences` under
   `auth.pendingEmailLinkEmail`. Callback URL is
   `https://loadout-precision-reloading.web.app/auth/link`.
3. **Anonymous** — `signInAnonymously`.
4. **Google** — `google_sign_in` 7.x API (`GoogleSignIn.instance.authenticate`).
5. **Apple** — native sheet via `sign_in_with_apple` on iOS; Firebase OAuth on
   Android.
6. **Microsoft** — Firebase hosted OAuth (`signInWithProvider(MicrosoftAuthProvider())`).
7. **Yahoo** — Firebase hosted OAuth (`signInWithProvider(YahooAuthProvider())`).

**JWT rotation chore (Apple).** Apple caps the Sign in with Apple
`client_secret` JWT at 180 days. Current key needs to be regenerated by
**2026-11-02** (LAUNCH_CHECKLIST.md). The `.p8` private key is the long-lived
material; the JWT must be re-signed every 6 months with the same Team ID, Key
ID, and Services ID, then POSTed to Firebase via the Identity Platform admin
API. Lose the `.p8` and you have to revoke the key in Apple Developer and
mint a new one.

### User auth posture

Sign-in is **optional**. Anonymous users get every core feature:
recipes, firearms, batches, brass lots, ballistics, SAAMI specs, the AI
chat, the glossary, and local JSON export. The bottom-nav and drawer
never nag a guest to sign in.

The only sign-in nudge in the app is on **Backups → Backup & Export**.
When `FirebaseAuth.instance.currentUser` is null or
`currentUser.isAnonymous` is true, the screen shows a dismissible
`_SignInPromptCard` at the top: "Sign in to enable cloud backup of your
loads, firearms, and brass." Tapping past dismisses it for the session
(`_signInPromptDismissed`); local export still works regardless. Cloud
backup itself requires a real account so the encrypted blob has a stable
home across devices.

Account recovery lives in two places:
- `LoginScreen` — a "Forgot Password?" link under the password field
  fires `FirebaseAuth.sendPasswordResetEmail`. A "Get help signing in"
  link below the email-link button opens a `mailto:` to support for the
  cross-device email-link case (LAUNCH_CHECKLIST.md).
- `SettingsScreen` → "Help & Support" — Email support, Restore from
  backup, Restore purchases (calls `PurchasesService.restorePurchases`),
  Privacy Policy, Terms & Safety Disclaimer, and a triple-confirm
  "Delete my data" flow. Delete-my-data calls
  `AppDatabase.wipeUserData()` (drops every row in the user-data tables
  and re-seeds the standard process steps; the reference catalog is
  preserved) then signs the user out.

Future shared-loads / community-library features will require auth but
are intentionally **deferred** — too much surface for launch. Don't
introduce auth gates outside of cloud backup.

## Monetization (RevenueCat)

In-app purchases are handled via RevenueCat (`purchases_flutter`).
Two SKUs only: `loadout_pro_yearly` ($39.99/yr) and
`loadout_pro_lifetime` ($79.99). Single entitlement: `pro`. The app is
pre-launch — no monthly tier exists or ever existed in production.

- **Code:**
  - `lib/services/purchases_service.dart` wraps the SDK.
  - `lib/services/entitlement_notifier.dart` is a `ChangeNotifier`
    that exposes `isPro` and is provided via `provider`.
  - `lib/screens/paywall/paywall_screen.dart` is the upgrade UI.
  - `lib/widgets/pro_gate.dart` provides `ProGate` (inline render
    gate) and `ensurePro(context)` (action gate).
  - `lib/services/revenue_cat_config.dart` holds the public API keys.
    Placeholder values (`REPLACE_ME_*`) make development safe — the
    paywall shows a "Pro not yet available" state when keys are
    placeholders.

- **Adding a Pro gate to a feature:**
  - For inline UI: wrap the widget in `ProGate(feature: 'Smart import',
    child: SmartImportButton())`.
  - For an action: `if (!await ensurePro(context)) return;` at the top
    of the handler.

- **Pro-gated features (canonical list).** When you change which
  bucket something lands in, also touch
  `marketing/CLAUDE.md` § 7's pricing table and § 9's "Pro features
  shipped" list — the in-app paywall pitch and the marketing copy
  have to stay aligned with the actual gates.

  | Feature | Gate call site |
  |---|---|
  | Cloud Sync | `lib/services/cloud_sync_service.dart` (gated via `EntitlementNotifier.isPro`) and `lib/screens/sync/cloud_sync_screen.dart` |
  | Cloud Backup (manual) | `lib/screens/backup/backup_screen.dart` |
  | Hornady 4DOF / custom drag curves | `lib/screens/ballistics/ballistics_screen.dart` `_dragFunctionSelector` (Custom CDM/DSF dropdown row) and `_customDragAvailableBadge` (per-bullet shortcut). Free users see G1/G7 + the bullet's BC. |
  | Bluetooth devices (Kestrel, rangefinders, Garmin Xero) | `lib/screens/devices/*` and the BLE service constructors |
  | Scope View Pro reticle visualization | `lib/screens/range_day/range_day_detail_screen.dart` Scope View entrypoint |
  | Scope View training mode (free-aim, skill timing, animated mover, ambush guides) | helpers in `lib/screens/range_day/scope_training_models.dart` (`AimMode.requiresPro`, `TrainingOverlays.requiresPro`); the scope view panel UI is responsible for routing through `ensurePro` before flipping any of these. |
  | Moving target lead | `lib/screens/range_day/range_day_detail_screen.dart` `_movingTargetCard` (`ProGate(feature: 'Moving target lead', ...)`) |
  | Live weather pull (ballistics screen) | `lib/screens/ballistics/ballistics_screen.dart` `_onUseMyLocation` (`ensurePro` at the top of the handler) |
  | Live weather pull (firearm form Zero Atmosphere) | `lib/screens/firearms/firearm_form_screen.dart` `_captureZeroFromWeather` (`ensurePro` at the top of the handler) |
  | GPS altitude derivation (Range Day "Capture environment from sensors") | `lib/screens/range_day/range_day_detail_screen.dart` `_captureEnvironmentFromSensors` reads `EntitlementNotifier.isPro` and skips the open-meteo call for free users; cant / azimuth / incline stay free. |
  | AI Smart Import (Tier 3 photo OCR for messy handwriting) | wired through `lib/services/photo_import_service.dart` and the recipe import flow; AI-proxy path Pro-gated. |
  | AI Reloading Assistant chat | `lib/screens/ai_chat/*` — Coming Soon at v1.0; will be Pro when shipped. |
  | Load development | `lib/screens/load_development/*` |
  | Internal Ballistics Calculator (Powley pressure / MV predictor) | Resources directory tile + bottom-of-Ballistics-Calculator entry button; both routes through `ensurePro` and the screen wraps its body in `ProGate`. Service in `lib/services/ballistics/internal_ballistics.dart`; full description in § 24. |
  | Custom fields (unlimited) | recipe / firearm form custom-field affordances |

- **Linking RevenueCat to Firebase Auth:** the auth-state listener
  in `_AuthGate` calls `PurchasesService.setAppUserId(user.uid)` on
  sign-in and `setAppUserId(null)` on sign-out. This means a user
  who buys Pro on iOS sees Pro on Android when they sign in with
  the same Firebase account.

- **Setup steps for App Store Connect, Play Console, and the
  RevenueCat dashboard:** see `REVENUECAT_SETUP.md`.

## 5. Common commands

```sh
# Static analysis (do this before any commit)
flutter analyze

# Regenerate drift code after editing database.dart
dart run build_runner build
# Or watch mode
dart run build_runner watch --delete-conflicting-outputs

# Run on a connected device / simulator
flutter run

# Quick iOS compile check without code signing
flutter build ios --debug --no-codesign

# Web: build the static bundle for Firebase Hosting (build/web/)
flutter build web --release

# Web: rebuild the drift worker after editing web/drift_worker.dart
dart compile js -O2 -o web/drift_worker.dart.js web/drift_worker.dart

# Deploy AASA / assetlinks.json (marketing site)
firebase deploy --only hosting:marketing

# Deploy the Flutter web bundle (build/web/)
flutter build web --release && firebase deploy --only hosting:app

# Deploy Firestore rules (currently unused but the rules file exists)
firebase deploy --only firestore:rules --project=loadout-precision-reloading

# Re-sync Firebase platform configs (e.g. after adding a platform)
flutterfire configure --project=loadout-precision-reloading
```

## 6. Drift schema notes

- `lib/database/database.g.dart` is **generated**. Never edit it by hand.
  Re-run `dart run build_runner build` after touching `database.dart`.
- `schemaVersion` lives in `AppDatabase` (currently `8`). Bumping it requires
  adding a `MigrationStrategy.onUpgrade` clause that brings older installs up
  to date. Schema v8 added the `BallisticProfiles` table for saved
  ballistics-calculator configurations.
- Reference tables are populated by `SeedLoader.seedIfNeeded()` on first run.
  The check is `Cartridges` row count == 0. If you change the seed data
  shape, an existing user's DB will keep the old data — handle via migration.
- List-valued fields (`aliasesJson`, `calibersJson`, `compatibleWithJson`)
  are JSON-encoded `text` columns. Decode at the repository boundary.
- Column conventions: `*In` for inches, `*Gr` for grains, `*Cps` for primer
  cup depth thousandths.

## 7. Firebase Auth providers configured via API

The Firebase Console GUI does not expose Microsoft, Yahoo, or Apple toggles in
the same way for a project that has Identity Platform enabled. These were
configured by direct calls to:

```
https://identitytoolkit.googleapis.com/admin/v2/projects/loadout-precision-reloading/...
```

Auth is via `gcloud auth print-access-token`. The Apple OIDC config requires a
JWT signed with the `.p8` key:

- Algorithm: `ES256`
- Header: `{"alg":"ES256","kid":"<Key ID>"}`
- Payload: `iss=<Apple Team ID>`, `sub=<Services ID>`, `aud="https://appleid.apple.com"`,
  `iat=now`, `exp=iat + ≤180 days`
- Library used: Python `PyJWT` with the `cryptography` extra.

The Microsoft/Yahoo configs use a client ID + client secret pair from each
provider's developer portal. Secrets that need rotation are tracked in
`LAUNCH_CHECKLIST.md`.

## 8. iOS gotchas

- **Always open `ios/Runner.xcworkspace`**, never `Runner.xcodeproj`. Pods
  break the bare project.
- `DEVELOPMENT_TEAM = 7265YL85SB` (Johnson Digital Systems org) — set in
  `ios/Runner.xcodeproj/project.pbxproj`.
- `ios/Runner/Runner.entitlements` declares:
  - `com.apple.developer.applesignin` (Sign in with Apple)
  - `com.apple.developer.associated-domains` with
    `applinks:loadout-precision-reloading.web.app` and
    `applinks:loadout-precision-reloading.firebaseapp.com`
- Both capabilities **must be enabled on the App ID** at developer.apple.com →
  Identifiers → `com.johnsondigital.loadout`. If they are not, code signing
  will refuse the build.
- iOS deployment target is **15.0** in both `ios/Podfile` and the Xcode
  project. Background: `cloud_firestore` historically required 14+; we
  removed Firestore but kept 15.0 because plenty of Firebase iOS SDK pieces
  still need 14+ and 15 is a safe floor.
- `ios/Podfile` `post_install` hook forces every Pod target to:
  - `IPHONEOS_DEPLOYMENT_TARGET = 15.0`
  - `ENABLE_USER_SCRIPT_SANDBOXING = NO`

  Do not remove either. Xcode 14+ ships with User Script Sandboxing on by
  default, which breaks the CocoaPods header-symlink scripts and produces
  "sandbox is not in sync with the Podfile.lock" errors.

- `apple-app-site-association` is served from
  `https://loadout-precision-reloading.web.app/.well-known/apple-app-site-association`
  via Firebase Hosting. It declares `appID = 7265YL85SB.com.johnsondigital.loadout`
  and matches the path `/auth/*`.

## 9. Android gotchas

- Package name: `com.johnsondigital.loadout`. Kotlin source path matches
  (`android/app/src/main/kotlin/com/johnsondigital/loadout/MainActivity.kt`).
- `android/app/build.gradle.kts` reads `android/key.properties` (gitignored)
  for the release keystore. If the file exists and has all four required
  fields (`storeFile`, `storePassword`, `keyAlias`, `keyPassword`), release
  builds sign with the real keystore. If it's missing, release builds fall
  back to the debug keystore so `flutter run --release` keeps working on a
  fresh checkout. The debug-signed fallback **must not** be uploaded to the
  Play Store.
- To set up release signing on a new machine:
  1. Run `scripts/generate_release_keystore.sh` (interactive — prompts for
     store password and key password). Writes
     `android/app/loadout_release.keystore`.
  2. `cp android/key.properties.example android/key.properties` and fill in
     the passwords you chose. `key.properties` is `.gitignore`d.
  3. Build: `flutter build appbundle --release` (or `apk --release`).
  4. Back up the keystore + passwords to a password manager. Losing the
     upload key after Play Store publication requires Google support
     intervention.
- Extract the release SHA-1 / SHA-256 with:
  ```sh
  keytool -list -v -keystore android/app/loadout_release.keystore -alias loadout
  ```
- `compileOptions` and `kotlinOptions` are pinned to JDK 17.
- The release keystore SHA-256 must be registered in **two** places before
  a Play Store build will work:
  1. **Firebase Console** → Project Settings → your Android app → SHA
     fingerprints → Add fingerprint. Without this, Google Sign-In and
     email-link verification fail on the release build. (If you switch to
     Play App Signing, register the *App signing key certificate* SHA shown
     in Play Console → Setup → App integrity, not the upload key SHA.)
  2. **`public/.well-known/assetlinks.json`** (Android App Links). Run
     `scripts/update_assetlinks.sh` to merge the release SHA in alongside
     the existing debug SHA, then `firebase deploy --only hosting`.
- Only the **debug** SHA-1 / SHA-256 are registered with the Firebase
  Android app today; same for `assetlinks.json`. Both need the release SHA
  added before Play Store upload — see `LAUNCH_CHECKLIST.md`.
- `android/app/src/main/AndroidManifest.xml` has an
  `<intent-filter android:autoVerify="true">` for
  `https://loadout-precision-reloading.web.app/auth/*` and
  `https://loadout-precision-reloading.firebaseapp.com/auth/*`. Verification
  depends on `assetlinks.json` returning HTTP 200 with the right SHA at:
  `https://loadout-precision-reloading.web.app/.well-known/assetlinks.json`.

## 10. Firebase Hosting

`firebase.json` declares **two** Hosting targets, each pointing at its own
Firebase Hosting site:

| Target | Public dir | Site (operator-created) | Purpose |
|---|---|---|---|
| `marketing` | `public/` | `loadout-precision-reloading` (default) | Landing page, AASA, assetlinks, email-link callback |
| `app` | `build/web/` | `loadout-app` (operator creates a second site in Firebase Console) | The Flutter web build |

`marketing` serves:

- `public/.well-known/apple-app-site-association` — iOS Universal Links
  (Hosting injects `Content-Type: application/json` per the rule in
  `firebase.json`).
- `public/.well-known/assetlinks.json` — Android App Links.
- `public/index.html` — minimal landing page; `firebase.json` rewrites
  `/auth/**` to it so that email-link callbacks resolve to a real URL when
  the app isn't installed.

`app` serves the Flutter web bundle from `build/web/` with a single SPA
rewrite (`** → /index.html`). The `Cross-Origin-{Embedder,Opener}-Policy`
headers are set so the browser will allow drift's WASM build to use
shared-array-buffer-backed APIs (OPFS) when available.

### One-time operator setup (per machine)

The operator must:

1. Create the second Hosting site in Firebase Console
   (project `loadout-precision-reloading` → Hosting → Add another site).
   Name it `loadout-app` (so it lives at
   `https://loadout-app.web.app`).
2. Apply target aliases on the local machine:
   ```sh
   firebase target:apply hosting marketing loadout-precision-reloading
   firebase target:apply hosting app loadout-app
   ```
3. Add `https://loadout-app.web.app` and
   `https://loadout-app.firebaseapp.com` to **Firebase Auth →
   Settings → Authorized domains**, otherwise sign-in popups and
   email-link redirects fail on the web build.
4. For Google Sign-In on web: Firebase Console → Project Settings →
   General → register a **Web** app (separate from iOS/Android) so
   Firebase emits a web client ID that `google_sign_in_web` can pick
   up at runtime. Without this the Google button silently no-ops on
   web.

### Deploy

```sh
firebase deploy --only hosting:marketing      # marketing site
flutter build web --release \
  && firebase deploy --only hosting:app       # web app
```

**Do not run `firebase deploy --only hosting`** with no target — that
deploys both sites, and accidentally pushing a stale `build/web/` to
the app target will overwrite a known-good build.

## 11. Adding a new auth provider

Pattern that has worked for Microsoft, Yahoo, Apple:

1. Register the app on the provider's portal, get a client ID + client
   secret. Authorize the redirect URL
   `https://loadout-precision-reloading.firebaseapp.com/__/auth/handler`.
2. Configure the provider on Firebase via the Identity Platform admin REST
   API (`projects/.../inboundSamlConfigs` or `defaultSupportedIdpConfigs`
   depending on type). Auth via `gcloud auth print-access-token`.
3. Add a method to `AuthService`:
   - For OIDC providers Firebase already supports: a one-liner using
     `signInWithProvider(<Foo>AuthProvider())`.
   - For Apple on iOS: use the native `sign_in_with_apple` flow and convert
     to `OAuthProvider('apple.com').credential(...)`.
4. Add the button to `LoginScreen` (`lib/screens/auth/login_screen.dart`).

## 12. Adding a new reference data category

1. Drop a JSON file at `assets/seed_data/<thing>.json`. Match the shape of
   peers (object with `manufacturers: [...]` for manufacturer-scoped data, or
   a flat array like `cartridges.json`).
2. Declare a new `Table` class in `lib/database/database.dart` and add it to
   the `tables:` list on `@DriftDatabase`.
3. Run `dart run build_runner build`.
4. Add a `_seed<Thing>()` method to `SeedLoader` and call it from
   `seedIfNeeded`.
5. If the UI needs it, add a method to `ComponentRepository` (or a new
   repository) and provide it in `app.dart`.
6. **Bump `schemaVersion`** and add a `MigrationStrategy.onUpgrade` clause
   that creates the new table for installs that already ran v1.

### 12a. Pubspec asset rule (subdirectories don't recurse)

Flutter's `flutter.assets:` declarations do **not** recurse into
subdirectories. A `- assets/seed_data/` line picks up files **directly
inside** that folder, but NOT files in `assets/seed_data/drag_curves/`.
Every new asset subdirectory must be added as its own line in
`pubspec.yaml`:

```yaml
flutter:
  assets:
    - assets/seed_data/
    - assets/seed_data/drag_curves/   # each subdir = its own line
```

Forgetting this is a fresh-install crash, not a compile error —
`flutter analyze` cannot see asset declarations, and the failure
shape is `Unable to load asset: "assets/seed_data/<...>/<...>.json"`
on first launch. The safety net is `test/assets_present_test.dart`,
which walks every file under `assets/seed_data/` and asserts each
one is reachable through `rootBundle`. Run `flutter test
test/assets_present_test.dart` after any asset addition; it fails
fast with the exact missing-asset message before the change ever
reaches a user.

If you introduce a brand-new top-level asset folder (e.g.
`assets/sounds/`), add it to `pubspec.yaml` AND to the `assetDirs`
list at the top of `test/assets_present_test.dart`.

## 13. Privacy posture

The app's marketing claim and in-app privacy copy say, in plain English:

> We don't track you, we don't run a backend that stores your reloading
> data, and any cloud backup or sync is encrypted on your device with
> your own passphrase and uploaded to your own iCloud Drive, Google
> Drive, or OneDrive.

Concretely:

- All user reloading data lives in the on-device SQLite database opened by
  `AppDatabase`. There is no LoadOut-side network sync.
- Firebase Auth (Google) processes email addresses and OAuth tokens during
  sign-in. That is the only personal data leaving the device.
- Local JSON export is always free. The export is written to the device's
  Files / Downloads area and never touches LoadOut infrastructure.
- Optional Pro feature: end-to-end encrypted backup to the user's own
  iCloud Drive (iOS), Google Drive (any platform), or Microsoft OneDrive
  (any platform). The blob is encrypted on device with a user-chosen
  passphrase before upload. **LoadOut never sees the encrypted blob, and
  we never operate any backend that receives reloading data.** Lost
  passphrases are unrecoverable; this is by design.
- Optional Pro feature: continuous **Cloud Sync** (see § 19). Same
  encryption model as the manual backup — encrypted on device with the
  user's passphrase, written to the user's own iCloud / Google Drive /
  OneDrive container. The only differences from manual backup are that
  the upload happens automatically a few seconds after each AutoSave
  fires, and the download happens on app launch + a manual "Sync Now"
  button. **LoadOut still never sees the encrypted blob and runs no
  backend that receives reloading data.**
- Uninstalling the app or wiping the device deletes the on-device data. If
  the user enabled cloud backup or sync, restoring requires
  re-authenticating to their cloud provider and entering the passphrase.
- **AI Smart Import (Pro, opt-in per use)** — see § 20. The only feature
  in the app that sends user-provided text to a third party. Scoped
  exclusively to OCR'd recipe text from the photo-import flow. The
  hosted Cloudflare Worker proxy logs no request bodies; Anthropic's
  API terms forbid training on API requests; Pro users can override
  the proxy with their own Anthropic key (BYOK) for unlimited use.
  The toggle is off by default. **The proxy never receives anything
  besides the OCR'd text the user just produced + a Firebase ID
  token**: no recipes, firearms, brass lots, or anything else from
  the on-device DB.

**Cloud backup and Cloud Sync are approved opt-in features, but only
under the strict client-side encryption model described above.** Do not
add any code path that uploads user reloading data to a LoadOut-operated
backend, sends plaintext (or server-decryptable) backups anywhere, or
weakens the passphrase-only key derivation. Any change to the storage /
sync model has to revisit the in-app disclaimer copy, the privacy
screen, the App Store / Play Store privacy disclosures, and any landing
page copy.

**AI Smart Import is the only AI feature in the app today.** The "AI
Reloading Assistant" chat surface still ships its `Coming Soon`
placeholder and is intentionally NOT wired to the new infrastructure.
Do not extend the AI Smart Import service to cover chat — that's a
separate decision with separate risk surface (multi-turn conversation,
larger context, less constrained outputs). If chat lands later, it
gets its own service / config / privacy section.

## 14. Open items / where to track work

`LAUNCH_CHECKLIST.md` is the canonical pre-launch TODO list. Append to it
when you discover new blockers. As of 2026-05-06 highlights:

- Apple JWT rotation by 2026-11-02.
- Azure AD client secret rotation (chat-history exposure).
- Yahoo client secret rotation (chat-history exposure).
- Release keystore SHA needed in Firebase + `assetlinks.json` before Play
  Store.
- Associated Domains capability needs to be enabled on the App ID.
- Cross-device email-link UX (prompt for email when pending email isn't on
  this device).
- Convert Apple Developer + Play Console accounts from personal to org once
  EIN + DUNS land.
- Replace placeholder `test/widget_test.dart` with real coverage.
- Add Crashlytics + Analytics if/when policy allows.

`SETUP.md` predates the Firestore removal — read with caution; the
authoritative architecture description is this file.

## 15. Companion apps (Apple Watch + Wear OS)

LoadOut ships scaffolding for two native companion apps. They are **not**
Flutter — Flutter has no first-class watchOS or Wear OS support — they are
small native apps that live alongside the Flutter Runner / phone module
and talk to it over each platform's standard transport.

| | Apple Watch | Wear OS |
|---|---|---|
| Source | `ios/RunnerWatchApp/` | `android/wear/` |
| Bundle / app ID | `com.johnsondigital.loadout.watchkitapp` | `com.johnsondigital.loadout.wear` |
| UI framework | SwiftUI (native) | Compose for Wear OS (native) |
| Min OS | watchOS 10.0 | Wear OS 3 / Android 11 (API 30) |
| Phone-watch transport | `WatchConnectivity` (`WCSession`) | Google Play Services Wearable Data Layer |
| Status | "Coming Soon" placeholder UI; transport activated, no payloads sent yet |

Detailed READMEs live next to the source:

- `ios/RunnerWatchApp/README.md` — full Xcode wiring instructions plus
  proposed first-feature payloads.
- `android/wear/README.md` — Gradle setup is already done; lists the
  proposed Data Layer message paths.

### What is wired up automatically

- **Wear OS:** `:wear` is a real Gradle module, registered in
  `android/settings.gradle.kts`. `./gradlew :wear:assembleDebug` builds
  it. The Compose Compiler plugin
  (`org.jetbrains.kotlin.plugin.compose` v2.2.20) is declared at the
  settings level but only the `:wear` module applies it — the Flutter
  `:app` module is unaffected.
- **Phone-side bridges are activated automatically.**
  `MainActivity.configureFlutterEngine` instantiates `WatchBridge`
  (and tears it down in `onDestroy`); `AppDelegate.didInitializeImplicitFlutterEngine`
  calls `WatchSessionBridge.shared.activate(messenger:)` via a
  registrar pulled from the implicit-engine plugin registry. As soon
  as the Flutter engine is up, the Dart `WatchBridgeService` has live
  channels — even if no companion app is paired yet, the channel
  handlers respond to `isWatchPaired` / `isReachable` queries
  correctly.
- **iOS:** the Swift sources, plist, entitlements, and asset catalog
  exist on disk under `ios/RunnerWatchApp/`, plus the iPhone-side
  bridge at `ios/Runner/WatchSessionBridge.swift`. The bridge file
  must still be in the Runner target's Sources build phase (Xcode
  GUI step below); the watchOS target itself still needs to be added
  in Xcode (the project file isn't safe to edit by hand for
  multi-platform targets).

### What requires manual Xcode wiring (one-time)

`Runner.xcodeproj/project.pbxproj` is fragile to edit by hand for
multi-platform targets, so the watchOS target has to be added through
Xcode's GUI:

1. Open `ios/Runner.xcworkspace`.
2. **File → New → Target… → watchOS → App**:
   - Product Name: `RunnerWatchApp`
   - Bundle ID: `com.johnsondigital.loadout.watchkitapp`
   - Embed in Application: `Runner`
   - Interface: SwiftUI, Language: Swift
3. **Delete the auto-generated source files** Xcode created, then
   right-click the new target group and **Add Files to "Runner"…**
   pointing at every file already on disk in `ios/RunnerWatchApp/`
   (the Swift files, `Info.plist`, the `.entitlements`, and the
   `Assets.xcassets` and `Preview Content` folders). "Copy items if
   needed" must be **off**.
4. In **Build Settings** for the watch target set:
   - `INFOPLIST_FILE = RunnerWatchApp/Info.plist`
   - `CODE_SIGN_ENTITLEMENTS = RunnerWatchApp/RunnerWatchApp.entitlements`
   - `DEVELOPMENT_ASSET_PATHS = "RunnerWatchApp/Preview Content"`
   - `WATCHOS_DEPLOYMENT_TARGET = 10.0`
   - `ASSETCATALOG_COMPILER_APPICON_NAME = AppIcon`
   - `ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME = AccentColor`
5. The bridge file `ios/Runner/WatchSessionBridge.swift` is already
   in the Runner target's Sources build phase (committed in
   `Runner.xcodeproj/project.pbxproj`). The activation call in
   `AppDelegate` is also already wired —
   `didInitializeImplicitFlutterEngine` pulls a registrar out of the
   implicit-engine `pluginRegistry` and calls
   `WatchSessionBridge.shared.activate(messenger:)`. Confirm both
   are still in place after any future Flutter SDK migration that
   touches `AppDelegate.swift` or rewrites the Xcode project file.
6. Provision App Group `group.com.johnsondigital.loadout` on
   developer.apple.com and enable it on **both** the Runner and the
   RunnerWatchApp targets. (Optional today — only needed once a feature
   shares state via the App Group container.)

### Integration architecture for future feature work

Both transports are designed to share the same Dart-side service so
features only have to be implemented once. Recommended layering:

```
   ┌────────────────── Flutter (Dart) ──────────────────┐
   │  lib/services/watch_bridge_service.dart            │
   │    sendToWatch(Map payload)                        │
   │    Stream<Map> incoming                            │
   └─────────────┬───────────────────────┬──────────────┘
                 │                       │
       MethodChannel: loadout/watch_bridge
       EventChannel:  loadout/watch_bridge/events
                 │                       │
   ┌─────────────▼─────────────┐  ┌──────▼─────────────────┐
   │ ios/Runner/                │  │ android/app/           │
   │   WatchSessionBridge.swift │  │   WatchBridge.kt       │
   │    └─ WCSession            │  │    └─ MessageClient    │
   │                            │  │       DataClient       │
   └─────────────┬──────────────┘  └──────┬─────────────────┘
                 │                        │
   ┌─────────────▼──────────────┐  ┌──────▼─────────────────┐
   │ ios/RunnerWatchApp/        │  │ android/wear/          │
   │   WatchConnectivityManager │  │   PhoneDataLayerListen │
   │   (SwiftUI)                │  │   MainActivity (Compose│
   └────────────────────────────┘  └────────────────────────┘
```

The phone-side Dart service already has a clear contract; any feature
should be added by:

1. Defining a typed payload (e.g. `class DopeSnapshot`) in
   `lib/models/watch_payloads.dart`.
2. Adding `toJsonForWatch()` and `fromWatchJson()` helpers.
3. Calling `watchBridge.send({...})` from a screen / repository.
4. Implementing the watch-side decoder + UI.

Reserved message paths / dictionary keys (use these consistently across
iOS and Android):

| Path / key | Direction | Purpose |
|---|---|---|
| `active_load` | phone → watch | Currently selected load row |
| `dope` | phone → watch | Drop / windage chart for active load |
| `firearm_glance` | phone → watch | Active firearm + barrel-life summary |
| `log_shot` | watch → phone | Time-stamped shot, queued by `transferUserInfo` (iOS) / Data Layer (Android) when the phone is asleep |
| `timer_event` | bidirectional | Stage-timer start/pause/expired sync |
| `shot_capture_sensitivity` | phone → watch | Watch-shot motion-detect preset (`off` / `low` / `medium` / `high`). The watch's `MotionDetector` decodes the wire string and re-tunes its threshold + sustained-peak window per the table below. |

**Shot capture sensitivity table.** Both watch sides default to
`medium` if the phone hasn't pushed a value. The `MotionDetector` on
each platform persists the most-recent preset locally (`UserDefaults`
on iOS, `SharedPreferences` on Wear OS) so the choice survives across
watch reboots even before the next phone push lands.

| Preset | Threshold (g) | Sustained-peak duration |
|---|---|---|
| Off | (motion detect disabled entirely) | n/a |
| Low | 8.0 | 80 ms |
| Medium | 5.0 | 50 ms |
| High | 3.0 | 30 ms |

### Privacy posture for companion apps

Companion apps must obey the same rule the phone app does (§ 13):
**no LoadOut-operated backend ever sees reloading data.** Concretely:

- **No HTTP / fetch calls from either watch app.** All transport is the
  platform's encrypted peer-to-peer channel (`WatchConnectivity` /
  Wearable Data Layer).
- **No Firebase, RevenueCat, analytics, or crash-reporting SDKs in either
  watch target.** Pro entitlement checks happen on the phone; the watch
  reflects whatever the phone forwards via the bridge.
- The Apple App Group container and any cached Wear OS DataItem are
  on-device only — they never leave the user's wrist.

## 16. Internationalization

LoadOut uses Flutter's first-party `gen_l10n` pipeline (no `easy_localization`,
no `intl_utils`). The app ships translations for **English, German, Spanish,
French, Italian, and Russian**; English is the source of truth.

### Layout

```
l10n.yaml                          gen-l10n config (arb-dir, template, output filename)
lib/l10n/
  app_en.arb                       English source — add new keys HERE first
  app_de.arb                       German
  app_es.arb                       Spanish
  app_fr.arb                       French
  app_it.arb                       Italian
  app_ru.arb                       Russian
  app_localizations.dart           GENERATED facade — never edit
  app_localizations_*.dart         GENERATED per-locale subclass — never edit
```

The generated `*.dart` files are produced by `flutter gen-l10n` automatically
on `flutter pub get` / `flutter run` because `flutter: generate: true` is set
in `pubspec.yaml`. They are NOT git-ignored (yet) — if a build environment
needs them they're already present, but they should be regenerated on every
ARB edit.

### Wiring

- `lib/services/locale_service.dart` is a `ChangeNotifier` that holds the
  user's chosen language tag (or `null` for "follow system locale"). Persists
  to `SharedPreferences` under `app_locale`.
- `lib/app.dart` provides it in `MultiProvider` and wraps `MaterialApp` in a
  `Consumer<LocaleService>` so a Settings → Language change re-resolves
  `AppLocalizations` without a restart. The MaterialApp gets
  `localizationsDelegates: AppLocalizations.localizationsDelegates` and
  `supportedLocales: AppLocalizations.supportedLocales`.
- `lib/screens/settings/settings_screen.dart` exposes the picker via
  `_LanguageTile` → `_LanguagePickerSheet`. The "System default" row maps
  back to `null`.

### Migration pattern (engineers)

To localize one screen / widget:

1. Find every user-visible English literal (`'Save'`, `'Recipe'`, `"You haven't
   added any loads yet"`).
2. Add a key for each one to `lib/l10n/app_en.arb`. Use camelCase, group with
   a prefix (`commonSave`, `recipesEmptyState`, `errorRequiredField`). Add an
   `@key` block right after with a `description` that gives the translator
   enough context — describe WHERE the string appears and WHAT it means.
3. Run `flutter pub get` (or just save and `flutter run` — generation is
   on-the-fly). New keys appear on `AppLocalizations` immediately.
4. In the screen, `import '../../l10n/app_localizations.dart';` and read with
   `final l = AppLocalizations.of(context)!;` at the top of `build()`. Replace
   each literal with `l.<key>`.
5. For widgets that hold a state-built list of strings (the onboarding-deck
   pattern), DO NOT cache the list as `late final` — Flutter rebuilds widgets
   when the locale changes, so build the list inside `build()` against the
   current `AppLocalizations`.
6. Translate the new keys in `app_de.arb`, `app_es.arb`, etc. Missing keys
   silently fall back to English at runtime, so partial translation is safe.
7. Run `flutter analyze` — clean.
8. Run the app, switch language in Settings, eyeball the screen.

### For translators

- Edit only `app_<lang>.arb`. Never touch `app_en.arb` (English is the source
  of truth — bug the engineer if a key needs reworded).
- Each ARB is a flat JSON object. Keep the JSON keys identical to `app_en.arb`;
  translate only the string values. Do not edit `@@locale` or any `@key`
  blocks — those are metadata.
- Use the `@@x-comment` field at the top to leave per-file translator notes
  ("// TRANSLATOR-REVIEW: technical reloading terms in this pack still need a
  native-speaker pass").
- Reloading vocabulary is precise and not always intuitive. If unsure, use the
  shooter-community convention from the major reloading magazine in your
  language (Visier for German, Cibles for French, Armi & Tiro for Italian)
  rather than the dictionary translation. Leave `// TRANSLATOR-REVIEW`
  comments on any guess.
- Some abbreviations (COAL, CBTO, SAAMI, BC, MOA, MIL, FPS) are intentionally
  left in English — they are universal among reloaders. If your language
  community reads them differently, surface it during review.
- Apostrophes inside JSON strings: use `'` for single, `"` is reserved for
  the JSON delimiter. Quote characters inside ICU placeholders need to stay
  matched.

### Adding a new language

1. Copy `lib/l10n/app_en.arb` to `lib/l10n/app_<code>.arb`. Update `@@locale`.
2. Translate every value (or leave `// TRANSLATOR-REVIEW` placeholders).
3. Add the language tag to `kSupportedLanguageCodes` in
   `lib/services/locale_service.dart`, and a display label to
   `kLanguageDisplayNames` (the language's name in its own language).
4. `flutter pub get` to regenerate.
5. Settings → Language picks it up automatically.

### Known follow-ups

- The 30 strings in the initial scaffold cover navigation, common buttons,
  section headers, error messages, and the entire onboarding deck. The
  remaining English literals across `lib/screens/**` (recipe form, ballistics
  inputs, settings tiles other than Language, error snackbars, glossary,
  SAAMI tab, drawer items, dialog titles) still need migration.
- Some technical reloading vocabulary in the German / Russian / Italian
  packs was drafted from a non-native-speaker base and is flagged
  `// TRANSLATOR-REVIEW` in each ARB header. A native-speaker review pass is
  required before launch advertising "available in 6 languages".
- Right-to-left languages (Arabic, Hebrew) are not yet wired. Adding them
  needs `MaterialApp.localizationsDelegates` already includes the RTL
  delegate, so it's "just" a translation effort — but the form layouts have
  not been audited for RTL mirroring.

## 17. Web platform

LoadOut runs in the browser as a Flutter web app, deployed to its own
Firebase Hosting target (see § 10). The same Dart codebase compiles for
mobile, desktop, and web; everything platform-specific is gated behind
`kIsWeb` (or a positive `Platform.isIOS || Platform.isAndroid` check).

### Build and run

```sh
flutter run -d chrome           # local dev
flutter build web --release     # production bundle into build/web/
```

`flutter build web` rebuilds `build/web/main.dart.js` (via dart2js) and
copies the static files in `web/` (including `sqlite3.wasm` and the
prebuilt `drift_worker.dart.js`). The web bundle is roughly 4–5 MB
gzipped on first load; subsequent loads hit the service worker cache.

### Drift on web

Drift on web does not use `path_provider` (there is no filesystem from
the browser's perspective). Instead it uses a sqlite3 WebAssembly build
plus a web worker that hosts the database connection. Both files live
in `web/`:

- `web/sqlite3.wasm` — downloaded from
  https://github.com/simolus3/sqlite3.dart/releases/download/sqlite3-<ver>/sqlite3.wasm
  matching the `sqlite3` Dart package version pinned in `pubspec.lock`
  (currently 3.3.1). Re-download whenever the lockfile pin moves.
- `web/drift_worker.dart` — entry point. Compiled to
  `web/drift_worker.dart.js` with:
  ```sh
  dart compile js -O2 -o web/drift_worker.dart.js web/drift_worker.dart
  ```
  Both `drift_worker.dart` AND `drift_worker.dart.js` are committed.
  `flutter build web` does NOT recompile the worker — it must be
  rebuilt manually any time the drift package version moves or the
  worker source changes.

The connection itself is set up in `lib/database/database.dart`'s
`_open()`:

```dart
return driftDatabase(
  name: 'loadout',
  web: DriftWebOptions(
    sqlite3Wasm: Uri.parse('sqlite3.wasm'),
    driftWorker: Uri.parse('drift_worker.dart.js'),
  ),
);
```

At runtime drift picks the best storage backend the browser supports:

- **OPFS** (Origin-Private File System, Chrome / Edge / modern Safari) —
  durable, fastest. Requires the `Cross-Origin-{Embedder,Opener}-Policy`
  headers set in `firebase.json`'s `app` target.
- **IndexedDB** — fallback when OPFS isn't available. Durable but slower.
- **In-memory** — last-resort fallback when both fail. NOT durable.

The data lives entirely in the user's browser profile. Clearing site
data wipes it. There is no LoadOut-side sync (consistent with § 13).

### kIsWeb gating policy

Some plugins have no working web implementation, or are deliberately not
shipped on web because the platform doesn't host the relevant store.
These features are **gated** with `kIsWeb` (often combined with
`Platform.isIOS || Platform.isAndroid`) so the web build silently hides
them rather than crashing. Current gates:

| Feature | Reason | Where the gate lives |
|---|---|---|
| Photo Import (`google_mlkit_text_recognition`) | ML Kit has no web implementation | `PhotoImportScreen.isSupportedPlatform` (`lib/screens/recipes/photo_import_screen.dart`) |
| BLE devices (Kestrel, Garmin Xero, rangefinders) | `flutter_blue_plus_web` exists but the firmware integrations target mobile OSes | `BleService.isAvailable()` returns `false` on web; the Devices screen still renders, banner says "not available" |
| Cant + magnetometer sensors (Range Day Setup) | No browser API for magnetometer / orientation parity | `CantService.start()` / `MagnetometerService.start()` no-op on web |
| RevenueCat (`purchases_flutter`) | RevenueCat doesn't operate a web storefront for our SKUs | `_isPurchasesSupported` in `lib/main.dart` returns `false` on web. Paywall renders the existing "Pro is not yet available" placeholder. |
| Crashlytics (`firebase_crashlytics`) | Plugin throws `MissingPluginException` on web | `_isCrashlyticsSupported` in `lib/main.dart` |
| iCloud backup (`icloud_storage`) | iOS-only by design | Already gated on `Platform.isIOS` in `IcloudBackupService` |

When adding a new plugin, check pub.dev for the `web` platform tag. If
the plugin doesn't ship a web implementation, wrap every call site in
a `kIsWeb` guard AND hide the UI surface — Flutter will let you compile,
but you'll get a runtime `MissingPluginException` on web the first time
the user touches the feature.

### Auth providers on web

Firebase Auth on web works for the providers we ship:

- Email/password, anonymous, email-link — work out of the box. The
  email-link callback URL stays the same
  (`https://loadout-precision-reloading.web.app/auth/link`); the
  `marketing` Hosting target's `/auth/**` rewrite handles the redirect
  back to the app.
- Apple, Microsoft, Yahoo — Firebase opens the OAuth flow in a popup
  / redirect. No client-side changes needed.
- Google — needs a separate **web** OAuth client ID registered in
  Firebase Console (operator step listed in § 10). The
  `google_sign_in_web` package picks up the client ID at runtime; the
  rest of the `AuthService` API is shared with mobile.

### Layout note

The app's responsive shell (`lib/screens/home/home_screen.dart`) already
uses `NavigationRail` + master-detail at desktop widths, so the web
build looks reasonable in a browser without any extra work. Mobile-width
browsers fall back to the bottom-nav layout.

### Privacy posture on web

The web build keeps the same local-first promise as the mobile builds.
User reloading data lives in the browser's OPFS / IndexedDB store and
never leaves the device. Firebase Auth still processes the user's email
during sign-in (same as mobile). Cloud backup on web is currently
disabled — the icloud / Drive integrations need platform-specific work
before they can run in the browser. This is reflected in the existing
`SignInPromptCard` copy and is fine to leave as a follow-up.

## 18. Microsoft OneDrive OAuth setup (operator step)

LoadOut ships OneDrive as a third Cloud Sync / Cloud Backup provider
alongside iCloud Drive and Google Drive. The Azure AD app registration
is the operator step that gates this — `lib/services/onedrive_config.dart`
holds the public client ID with a `REPLACE_ME_*` placeholder; the rest
of the codebase compiles and runs (the OneDrive cards / picker rows
self-hide behind `OneDriveConfig.isPlaceholder`) until the placeholder
is replaced with a real GUID.

To activate:

1. **portal.azure.com → App registrations → New registration**:
   - Name: `LoadOut OneDrive Sync`
   - Supported account types: **Accounts in any organizational
     directory and personal Microsoft accounts** (the `consumers`
     tenant is what enables `Files.ReadWrite.AppFolder` for personal
     OneDrive).
   - Redirect URIs (Public client / native — mobile and desktop):
     - `loadout://onedrive-callback` (iOS / macOS — also register
       in `ios/Runner/Info.plist` `CFBundleURLTypes`).
     - `msauth.com.johnsondigital.loadout://auth` (Android — also
       register in `android/app/src/main/AndroidManifest.xml`).
2. **API permissions → Add → Microsoft Graph → Delegated**:
   - `Files.ReadWrite.AppFolder`
   - `offline_access` (needed for the refresh-token flow Cloud Sync
     uses).
3. Copy the **Application (client) ID** GUID into
   `OneDriveConfig.clientId`. Leave `tenantId` as `consumers` for the
   personal-OneDrive flow.
4. **No client secret** — public client / native registrations use
   PKCE. There is no `client_secret` to ship in `lib/services/`; the
   actual interactive sign-in lives in
   `lib/screens/sync/cloud_sync_screen.dart` and uses the platform's
   in-app web auth flow.
5. **Rotation cadence**: PKCE-only public client registrations have
   no expiring secret. Review the redirect URIs annually to make sure
   they still match the iOS Info.plist + Android Manifest entries.
   The user-side refresh tokens (cached in `flutter_secure_storage`)
   are rotated automatically by the OAuth flow and Microsoft expires
   unused refresh tokens after 90 days.

`OneDriveBackupService.connectInteractive` is the entry point that
persists the refresh token; the screen drives it after a successful
PKCE exchange. `disconnect()` clears the cached token. Both are gated
on `OneDriveConfig.isPlaceholder` so dev / CI builds with the
placeholder never accidentally try to sign in.

## 19. Cloud Sync (Pro)

Continuous, end-to-end-encrypted, cross-device sync of the user's
reloading data. Layered on top of the existing manual backup/restore
infrastructure. Lives in:

| | |
|---|---|
| Service | `lib/services/cloud_sync_service.dart` (`CloudSyncService`) |
| Encryption | unchanged — `lib/services/backup_crypto.dart` |
| Providers | iCloud (`ICloudBackupService`), Drive (`DriveBackupService`), OneDrive (`OneDriveBackupService`) |
| Screen | `lib/screens/sync/cloud_sync_screen.dart` |
| Indicator | `lib/widgets/cloud_sync_indicator.dart` (AppBar icon + dot) |
| Wiring | `lib/app.dart` provides the service; AutoSaveControllers fire `scheduleSyncUp()` after every save |
| Pro gate | yes — `EntitlementNotifier.isPro` short-circuits every sync operation |
| Passphrase storage | `flutter_secure_storage` keyed `sync_passphrase_<provider>` |

### Storage shape

- One canonical encrypted blob per user, named `loadout_sync.encrypted`,
  in the active provider's app folder (iCloud `Backups/`, Drive
  `appDataFolder`, OneDrive `approot`).
- Same on-disk format as a manual backup — `ExportService.exportToJson()`
  → `BackupCrypto.encrypt(passphrase, json)`. Decrypt is the inverse.

### Mechanics

- **Push (`syncUp`)**: every form save fires `AutoSaveController._runSave`,
  which calls `onSavedToCloud`, which calls `CloudSyncService.scheduleSyncUp`.
  That starts (or restarts) a 5-second debounce timer; when it elapses,
  `syncUp` exports the DB, encrypts, and overwrites the blob.
- **Pull (`syncDown`)**: called once at app launch from
  `_AuthGate._maybePullCloudSyncOnLaunch` and from the manual "Sync
  Now" button. Downloads the blob, decrypts, walks every user-data
  table in `kUserDataTableOrder`, and applies the "newest `updatedAt`
  wins" rule per row. Local-only rows (created since last sync) are
  preserved and pushed by the next `syncUp`.
- **Reconcile**: pull then push, used by the manual "Sync Now" button.
- **Concurrency guard**: a single `_busy` flag prevents two `syncUp`s
  from running in parallel; if a save lands during a sync, a
  `_queuedFollowUp` bit fires one final push at the end.

### Conflict policy

- Last-writer-wins by row `updatedAt`. Tables without `updatedAt`
  fall back to `createdAt`; if neither side has a clock, remote wins
  (preserves manual-restore semantics).
- Decryption failure (`SyncPullOutcome.passphraseMismatch`) leaves
  the local DB untouched and surfaces a "passphrase needed" status.
- Schema-version mismatch (`schema_version` in the inbound payload >
  local) is rejected with a fatal error — the user is told to
  update the app on this device.
- A real CRDT is explicitly out of scope. Personal reloading data on
  two devices is a soft conflict at most.

### Privacy contract

Same as § 13. The encrypted blob lives in the user's own cloud, never
on LoadOut infrastructure. Lost passphrase = lost data — the Cloud
Sync screen has a red warning to that effect.

### Free vs Pro

- Free users see Settings → Cloud Sync (Pro), see the explanation,
  and tapping "Enable" routes through `ensurePro` to the paywall.
  They retain access to the manual one-shot backup on the Backup &
  Export screen.
- Pro users get the full enable / disable / reconcile flow, the
  AppBar indicator dot, and the "Sync Now" button.

## 20. AI Smart Import (Pro, opt-in per use)

The **only** Anthropic-using surface in the app today. Scoped
exclusively to "improve a low-confidence parse from the on-device
photo-import pipeline." Not a chatbot, not a load-development
assistant, not a conversational AI — just a translation tool that
takes the OCR'd text and returns a structured patch on the
`RecipeDraft` shape.

| | |
|---|---|
| Service | `lib/services/ai_smart_import_service.dart` |
| Config  | `lib/services/ai_smart_import_config.dart` |
| Settings UI | `lib/screens/settings/ai_settings_screen.dart` |
| Caller | `lib/screens/recipes/photo_import_review_screen.dart` ("Improve with AI" card) |
| Worker | `cloud_worker/anthropic-proxy/` (Cloudflare Workers + KV) |
| Tests | `test/ai_smart_import_service_test.dart` |
| Pro gate | yes — `ensurePro` routes to paywall for non-Pro non-BYOK users |
| BYOK secure storage | `flutter_secure_storage` keyed `byok_anthropic_key` |
| Master enable pref | `SharedPreferences` keyed `ai_smart_import_enabled`, default off |

### Mode selection (inside the service)

`AiSmartImportService.improveDraft(...)` resolves the mode every
call:

1. **BYOK** — if `flutter_secure_storage[byok_anthropic_key]` is
   set, the request goes straight to `api.anthropic.com` with the
   user's `x-api-key`. No proxy involvement.
2. **Hosted** — else if `EntitlementNotifier.isPro` AND
   `AiSmartImportConfig.isPlaceholder == false`, the request goes
   to the Cloudflare Worker with a Firebase ID token in the
   `Authorization: Bearer` header.
3. **Throws** — else `ProRequiredException` (free user, no BYOK
   key) or `SmartImportNotConfiguredException` (Worker URL is the
   placeholder).

The Worker validates the Firebase token against Firebase's public
JWKs, increments a per-user-per-month counter in KV (default cap
20 — see `cloud_worker/anthropic-proxy/src/quota.ts:43`), forwards
to Anthropic on the LoadOut secret key, and returns
`{ improved_draft, fields_changed, quota }`. Worker logs only
timestamp, short UID prefix, status, latency, and token counts —
**never the request body**.

### Privacy contract

Same as § 13. Specifically:

- The hosted proxy receives **only** the OCR'd text the user just
  imported, the on-device parser's draft, and (optionally) catalog
  hints from the device's reference data. No saved recipes, no
  firearms, no brass lots, no chat history. The Worker's request
  log redacts request bodies.
- BYOK mode skips the proxy entirely. The user's key lives in iOS
  Keychain / Android Keystore, never in `SharedPreferences` or the
  on-device SQLite DB.
- Anthropic's API terms forbid training on API requests; verify
  this before each renewal.
- The master enable toggle in Settings → AI is **off by default**.
  Each photo import requires an explicit per-import "Improve with
  AI" button tap.

### Reloader-skeptic framing

- Settings copy: "AI Smart Import only reads OCR'd text from photos
  you took. We never see your saved recipes, firearms, or chat.
  Anthropic does not train on API requests."
- Button label: "Improve with AI" — utility, not buzz.
- No emoji on this surface. No "AI assistant" terminology.
- Marketing should describe it as a "translation tool," not an
  "assistant."

### Operator deploy

See `cloud_worker/anthropic-proxy/README.md`. Until the operator
runs `wrangler deploy`, `AiSmartImportConfig.isPlaceholder` returns
true and hosted-mode calls fail gracefully with "AI Smart Import
is being set up — please try again later." Local export, on-device
parse, and BYOK mode all keep working through that.

### Hardening backlog

- **Per-user RevenueCat entitlement check at the Worker.** Today
  any signed-in Firebase user (including anonymous) passes auth
  at the Worker; the client-side `ensurePro` is the entitlement
  gate. Before scaling beyond a few thousand Pro users, the Worker
  should call RevenueCat's REST API (cached per-UID for a few
  minutes) and reject non-Pro callers server-side.
- **Custom domain** — replace the default `*.workers.dev` host
  once the marketing domain ships.
- **Translator-review** — the marketing copy still calls AI Smart
  Import "v1.1, Pro, frontend stub today" in some places; sweep
  before launch.

## 21. Bluetooth device compatibility

LoadOut talks to seven BLE-enabled devices across three categories.
All are gated behind the **Pro** entitlement (`EntitlementNotifier.isPro`)
because manual entry is always free elsewhere in the app, and the
firmware integrations cost real engineering time per brand. Each
adapter lives at `lib/services/ble/<brand>_service.dart` and is
provided once via `MultiProvider` in `lib/app.dart`.

| Device | Protocol | UUIDs | Tier | Channels published |
|---|---|---|---|---|
| Kestrel 5xxx Link | proprietary | known-good (validated) | Pro | Live temperature, station pressure, humidity, wind speed/direction, density altitude |
| Garmin Xero C1 Pro | `.fit` import | n/a (file parser, no BLE today) | Pro | Per-shot velocity, average FPS, ES, SD |
| Sig Sauer KILO BDX | BDX | reverse-engineered, BETA | Pro | LOS distance + incline + shoot-to range |
| Bushnell BDX (Forge / Prime / Phantom 2 / Engage / Elite 1 Mile) | proprietary | reverse-engineered, BETA | Pro | LOS distance + (some firmware) incline |
| Vortex Razor HD 4000 / Fury HD AB | proprietary | reverse-engineered, BETA | Pro | LOS distance + incline + shoot-to range |
| Leica Geovid Pro | proprietary | reverse-engineered, BETA | Pro | LOS distance + incline + shoot-to range |
| Vectronix Terrapin X | proprietary | UUIDs flagged BETA (VERIFY-ON-DEVICE) | Pro | LOS distance + incline + azimuth (mil/LE-grade) |

The Vectronix Terrapin X is unique: it's the only rangefinder
LoadOut supports that publishes a magnetic azimuth (compass
bearing) alongside the LOS distance. The Range Day distance
quick-fill picker reads this and offers a single-tap "Use distance
+ azimuth" button that fills the distance field, the
incline-corrected range, AND the shot azimuth field — saving the
shooter from a separate compass-capture step.

### Adding a new BLE rangefinder

1. Create `lib/services/ble/<brand>_service.dart` mirroring the
   existing adapters (`SigKiloService` is the canonical reference).
   It must extend `ChangeNotifier`, expose `lastReading`, and have
   a static `parse<Brand>Frame(...)` method visible for testing.
2. If the device publishes a channel the existing
   `RangefinderReading` shape doesn't cover, add a nullable field
   to `lib/services/ble/rangefinder_reading.dart` rather than
   inventing a per-brand subclass. (Vectronix added `azimuthDeg`.)
3. Register `ChangeNotifierProvider<...Service>` in
   `lib/app.dart`, ordered after the BleService it depends on.
4. Add a `DeviceScanKind.<brand>` enum case in
   `lib/screens/devices/device_scan_screen.dart` and fill in the
   six switch arms (`title`, `emptyLabel`, `connectedMessage`,
   `scanFilters`, `matches`, `listIcon`, `emptyHint`,
   `_resolveConnect`).
5. Add a `_RangefinderCard` to `lib/screens/devices/devices_screen.dart`.
6. Extend `_rangefinderQuickFill()` in
   `lib/screens/range_day/range_day_detail_screen.dart` so the
   freshness sort sees the new device.
7. Write an 8-test unit suite at `test/<brand>_test.dart` matching
   the depth of the existing parsers (short-frame null,
   wrong-marker null, out-of-range distance null, out-of-range
   incline null, valid LOS-only, valid LOS+incline, valid
   LOS+incline+aux, valid IC-range conversion).
8. Update this section's compatibility table and the
   `marketing/CLAUDE.md` Bluetooth ecosystem list.

UUIDs and frame offsets for every reverse-engineered protocol are
flagged with `// TODO(reverse-engineering): verify on device` or
`// VERIFY-ON-DEVICE` in their service files. The BETA badge on
the Devices card stays until real-device validation lands.

## 22. Recipe import sources

LoadOut accepts recipes from seven distinct sources, all routed
through the same `RecipeParser` → `PhotoImportReviewScreen` chain so
the user sees one consistent review surface regardless of where the
text came from. The picker that surfaces these lives at
`lib/screens/onboarding/import_sources_screen.dart`; the welcome
deck's "Bring Your Existing Data" slide deep-links into it.

| Source | Implementation | Platform |
|---|---|---|
| Photo | `PhotoImportScreen` (`google_mlkit_text_recognition` + camera/gallery picker) | iOS, Android |
| CSV / Excel | `SmartImportScreen` (`file_picker` accepting `.csv`/`.xlsx`, column-mapping wizard) | iOS, Android, macOS, web |
| Notes / Text File | `TextImportService.readTextFile` (file picker `.txt`/`.text`/`.md`/`.markdown`/`.rtf`, UTF-8 with Latin-1 fallback) → `RecipeParser` | iOS, Android, macOS, web |
| PDF Document | `TextImportService.rasterizeAndOcrPdf` (`printing.Printing.raster` + ML Kit OCR per page) → `RecipeParser` | iOS, Android |
| Word Document | Guide dialog → file picker accepting any export format (`.pdf`/`.txt`/etc.) → routes through PDF or text path | iOS, Android, macOS, web (with platform caveats on PDF) |
| OneNote | Guide dialog → same generic file picker | iOS, Android, macOS, web (with caveats) |
| Apple Notes (Share Sheet) | `share_handler` plugin: native iOS Share Extension + Android `ACTION_SEND` intent → `ShareHandlerService` → `RecipeParser` | iOS (after one-time Xcode setup — see § 23), Android (out of the box) |

The shared text-input plumbing — building a parser from the live
catalog, reading text files, rasterising + OCR-ing PDFs — lives in
`lib/services/text_import_service.dart`. New import surfaces
should reuse those helpers rather than re-implementing the
catalog-load / OCR / parse dance.

## 23. iOS Share Extension setup (operator step)

The Apple Notes / generic-share inbound flow requires a one-time
Xcode Share Extension target add — same operator-only pattern as
the watch app (§ 15) and the OneDrive OAuth registration (§ 18).
The Dart side, the Android intent filter, and the in-app picker
are all wired up; iOS shows nothing in the share sheet until the
extension target exists.

Full step-by-step Xcode walkthrough lives at
`ios/ShareExtension/README.md` (committed alongside this section).
The summary:

1. `File → New → Target → iOS → Share Extension`, name it
   `ShareExtension`, bundle id
   `com.johnsondigital.loadout.ShareExtension`.
2. Replace the auto-generated `ShareViewController.swift` with a
   minimal subclass of `ShareHandlerIosViewController` carrying
   `appGroupId = "group.com.johnsondigital.loadout"` (the same
   group provisioned for the watch app per § 15).
3. Edit the extension's `Info.plist` so `NSExtensionActivationRule`
   advertises text + URL.
4. Enable the App Group capability on BOTH Runner and ShareExtension.
5. Set `IPHONEOS_DEPLOYMENT_TARGET = 15.0` on the new target to
   match Runner.
6. Add a second target block to `ios/Podfile` that pulls in
   `share_handler_ios`; run `pod install`.
7. Test on a real iOS device (the simulator does not enumerate
   third-party share extensions).

Until the operator runs this once, the app builds and the
ShareHandlerService starts cleanly — share-from-Notes simply does
nothing on iOS while continuing to work on Android.

## 24. Internal ballistics calculator

Pro-gated calculator that predicts muzzle velocity and peak chamber
pressure for a hypothetical reloading recipe — the headline feature
LoadOut was missing relative to GRT (free, donation-ware, Windows /
Mac via Wine) and QuickLOAD ($170+, Windows-only). Both desktops;
LoadOut shipping a competent mobile version is the intended
strategic differentiator.

| | |
|---|---|
| Service | `lib/services/ballistics/internal_ballistics.dart` (`predictLoad(...)`) |
| Powder reference | `lib/services/ballistics/powder_burn_rates.dart` (`kPowderBurnRates`, ~40 powders) |
| Screen | `lib/screens/ballistics/internal_ballistics_screen.dart` |
| Tests | `test/internal_ballistics_test.dart` (16 tests, all passing) |
| Pro gate | yes — entry routes through `ensurePro(context)` and the screen wraps its body in `ProGate` |
| Entry points | Resources directory tile + bottom-of-screen button on the external Ballistics Calculator |

### Model

Implements Homer Powley's interior-ballistics method (1962, revised
1980), the same simplified model that backed the original Sierra
and Lyman desktop programs in the 1980s. The simplification trades
the full Lagrange gas-dynamics treatment (what GRT does) for a
small set of empirical coefficients fit against published reloading
manual data. Inputs:

- Cartridge case capacity (grH₂O), case length (in)
- Powder name (looked up in `kPowderBurnRates`; loads with unknown
  powders return null — never silently substituted)
- Charge weight (gr)
- Bullet weight (gr), diameter (in), COAL (in), optional length (in)
- Barrel length (in), bore diameter (in)

Outputs: predicted muzzle velocity (fps), predicted peak pressure
(psi), loading density (%), expansion ratio, burn-completion %.

The physics formulas, calibration constants, and citations are
documented inline at the top of `internal_ballistics.dart` (file
header, "THE PHYSICS / MATH" section). The four magic constants —
`_kSpecificImpetusJPerKg = 4 MJ/kg`, `_kThermalCapExp = 0.30`,
`_kBurnCompletionSlope = 2.23`, `_kPressureScalePsi = 36000` —
are each calibrated against the validation set anchor loads. The
relative-quickness numbers in `powder_burn_rates.dart` are
normalised so IMR 4350 = 100, sourced from the Western Powders 2018
chart, Lyman 51st edition, Hodgdon's 2024 online chart, the Alliant
2023 Reloader's Guide, and the Vihtavuori 2024 manual; every row
cites its source.

### Validation results

Tested against four published HRDC (Hodgdon Reloading Data Center)
loads, retrieved 2026:

| Load | Manual MV | Pred MV | Δ% MV | Manual P | Pred P | Δ% P |
|---|---|---|---|---|---|---|
| .308 Win, 168gr SMK, 44.0gr Varget | 2700 fps | 2608 | -3.4% | 60900 psi | 68047 | +11.7% |
| .30-06, 165gr SST, 56.0gr IMR 4350 | 2820 fps | 2844 | +0.8% | 58800 psi | 56500 | -3.9% |
| 6.5 CM, 140gr ELD-M, 41.5gr H4350 | 2710 fps | 2550 | -5.9% | 60100 psi | 53866 | -10.4% |
| .223 Rem, 55gr FMJ, 26.0gr H335 | 3240 fps | 3450 | +6.5% | 54300 psi | 55307 | +1.9% |

Mean absolute MV error 4.2% (all rows within ±10%); mean absolute
pressure error 7.0% (all rows within ±15%). The 6.5 CM / H4350
case is the worst MV outlier — the Powley curve under-predicts MV
on the modern temp-stable extruded powders (Hodgdon Extreme series)
by ~6% because their burn-rate-vs-pressure profile is flatter than
the 1962-era stick powders Powley was calibrated against. The .308
/ Varget is the worst pressure outlier — over-predicts by ~12%
because the SAAMI piezo measurement on .308 is conservative
relative to the physical peak Powley computes.

### Privacy / safety posture

The screen renders a persistent yellow "Estimation Tool — Not a
Load-Data Substitute" banner at the top, every visit, with no
dismiss option. Reloaders who acted on a "below max" Powley
prediction without verifying could blow up their rifle, so the
disclaimer is load-bearing UI. The result card includes a coarse
SAAMI-band gauge ("Below typical SAAMI max" / "Approaching SAAMI
max" / "At or above — verify") that's advisory only — it doesn't
know the user's specific cartridge max.

The calculator is stateless across visits (no profiles, no
persistence) so a reloader doesn't accidentally trust a stale
prediction from a previous session. Per CLAUDE.md § 0, every input
field starts EMPTY; the result panel only renders after the user
fills in every required field and taps "Predict Pressure & MV".

### Scope

Powley applies to centerfire cased cartridges (rifle + pistol),
within the [10%, 110%] loading-density band. Out-of-band inputs
return null from `predictLoad(...)`. Shotshell loads, muzzleloaders,
and black-powder cartridges are explicitly NOT modelled — the
calibration corpus doesn't cover them and the predictor would
produce nonsense numbers. There is no v2 plan to extend the model
to a full Lagrange treatment; the right answer there is to point
power users at GRT or QuickLOAD on a desktop.

## 25. Load development (Pro)

Pro-gated workspace for running structured load-development tests.
Five named methods, each with a tailored data-entry workflow,
analysis algorithm, and chart. Reachable from Resources →
"Load Development", from a "Run Load Development" CTA on every
existing recipe form, and from the Range Day active-load row.

| | |
|---|---|
| Repository | `lib/repositories/load_development_repository.dart` |
| Schema (sessions) | `LoadDevelopmentSessions` (v5, extended in v31) |
| Schema (per-shot) | `LoadDevelopmentShots` (v31, new) |
| List screen | `lib/screens/load_development/load_development_list_screen.dart` |
| New-test wizard (v31+) | `lib/screens/load_development/new_method_test_screen.dart` |
| Detail screen (v31+) | `lib/screens/load_development/method_test_screen.dart` |
| Legacy wizard (seating) | `lib/screens/load_development/new_load_development_screen.dart` |
| Legacy detail | `lib/screens/load_development/load_development_detail_screen.dart` |
| Shared widgets | `lib/screens/load_development/widgets/{load_development_charts,method_explainer,shot_entry_card}.dart` |
| Tests | `test/load_development_methods_test.dart` |
| Pro gate | yes — list screen wraps body in `ProGate('Load Development')`; recipe form / Range Day CTAs route through `ensurePro` first |
| Entry points | Resources tile, Home drawer "Load Development", recipe form "Run Load Development", Range Day active-load row "Run Load Development" |

### Methods

Each method's detail screen shows an expandable **Method** card
(`MethodExplainerCard`) with a one-paragraph explainer, a "How to
read the results" section, and a citation block. The plain-English
text body uses sentence case (CLAUDE.md § 0a — Title Case is for
labels, not paragraphs).

#### OCW (Optimal Charge Weight, Newberry)

Three shots per charge across an evenly-stepped charge ladder.
Plot vertical impact vs charge. The OCW node is the centre of a
"flat spot" — a span of consecutive charges where vertical impact
barely changes (default threshold 0.5 inches between adjacent
charges).

- Algorithm: `LoadDevelopmentRepository.analyzeOcwNode(shots)` —
  group shots by `chargeGr`, take mean Y per charge, walk
  consecutive pairs looking for the longest run with delta ≤
  threshold. Returns `OcwAnalysis` with `flatChargeIndices` and
  the `recommendedChargeGr` at the centre of the flat spot.
- Default test setup: step 0.3 gr, 3 shots/charge, 100 yd.
- Source: Newberry, Dan. "Optimal Charge Weight Load Development."
  2002 onward at ocwreloading.com and on 6mmBR.com forums.

#### Audette Ladder

One shot per charge fired at distance (typically 300 yd or
further). Looks for vertical "stacking" — consecutive charges
whose impacts land near each other.

- Algorithm: shares `analyzeOcwNode` (single shot per charge is a
  degenerate OCW — the per-charge mean Y collapses to the single
  shot's Y). Plus `LoadDevelopmentRepository.computeLadderVerticalSpreadIn(shots)`
  for the overall vertical spread summary.
- Default test setup: step 0.3 gr, 1 shot/charge, 300 yd.
- Source: Audette, Creighton. Original method published in
  Precision Shooting magazine in the late 1970s. Single shot per
  charge fired at distance, vertical-stacking analysis.

#### Satterlee 10-shot

Chronograph-driven method: 10 rounds stepping the charge by 0.1–
0.2 grains through the safe range. Plot mean MV vs charge. The
Satterlee plateau is the longest run of consecutive charges where
mean velocity barely climbs.

- Algorithm:
  `LoadDevelopmentRepository.analyzeSatterleePlateau(shots)` —
  group by chargeGr, take mean velocity per charge, walk
  consecutive pairs treating "rise per step ≤ 12 fps" as still on
  the plateau. Returns `SatterleeAnalysis` with
  `plateauChargeIndices` and the `recommendedChargeGr`.
- Default test setup: step 0.2 gr, 1 shot/charge, 100 yd, 10
  charges.
- Source: Satterlee, Scott. "10-Round Load Development Test."
  Spec'd in informal coaching writeups, widely applied in PRS /
  long-range rifle shooting.

#### Generic charge ladder

Freeform — log shots one at a time with whatever data the
shooter collected. The detail screen surfaces all of OCW
detection, Satterlee plateau detection, and "lowest-SD charge"
fallback so the user can pick the analysis that matches their
protocol. The chart cycler flips between SD-vs-charge,
vertical-vs-charge, and group-ES-vs-charge.

#### Seating depth ladder

CBTO ladder around an existing recipe; tunes seating depth for
group / vertical. Routes to the legacy
`LoadDevelopmentDetailScreen` because that surface already has the
seating analysis algorithm and the "Pick This CBTO" recipe
write-back wired up.

### Per-charge statistics

`LoadDevelopmentRepository.computePerChargeStats(shots)` returns
one `PerChargeStats` row per `chargeGr`:

- `meanVelocityFps` / `sdVelocityFps` (Bessel-corrected, n-1) /
  `esVelocityFps` (max - min)
- `meanXIn` / `meanYIn` (group centroid in shooter coordinates,
  Y positive UP)
- `extremeSpreadIn` — largest center-to-center distance between
  any two impacts (`computeExtremeSpreadIn`)
- `meanRadiusIn` — average distance from each impact to the
  group centroid (`computeMeanRadiusIn`)

Rendered as a horizontally-scrollable Material `DataTable` on
every method-specific detail screen.

### Schema delta (v31)

Three coordinated additions on top of the v5 `LoadDevelopmentSessions`
table, all additive so existing ladder sessions are preserved:

1. **New columns on `LoadDevelopmentSessions`:**
   - `methodKind TEXT NOT NULL DEFAULT 'generic'` — `'ocw' |
     'ladder' | 'satterlee' | 'generic' | 'seating'`. Backfilled
     from `sessionType` ('charge_ladder' → 'generic',
     'seating_ladder' → 'seating').
   - `distanceYd INTEGER NULL` — distance to target in yards.
   - `shotsPerCharge INTEGER NULL` — shots fired per charge weight.
2. **New `LoadDevelopmentShots` child table** — one row per fired
   shot, keyed to `sessionId`, with `chargeGr`, `shotIndex`,
   `velocityFps`, `impactXIn`, `impactYIn`, `notes`, `createdAt`.
3. **Migration backfills `methodKind`** on existing rows by mapping
   `sessionType`. The legacy `rungsJson` blob continues to work
   for sessions that pre-date the per-shot model — the legacy
   detail screen reads from the JSON; the new screens read from
   `LoadDevelopmentShots`.

### Pro gating

The list screen wraps its body in `ProGate('Load Development')`.
The "+ New Test" FAB is hidden for free users. The Resources tile
is visible to free users (so they discover the feature and the
upsell pitch on the list screen) but tile tap routes to the list
screen, where the gate fires. Recipe-form and Range-Day "Run Load
Development" CTAs route through `ensurePro(context)` before pushing
the wizard.
