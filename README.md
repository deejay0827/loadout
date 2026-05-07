# LoadOut

A local-first ammo reloading tracker for iOS and Android, built in Flutter. Reloaders catalog their recipes, firearms, brass lots, batches, and load-development experiments without sending any of that data to a backend. The app ships with a 200+ cartridge SAAMI reference, a glossary, an exterior-ballistics solver (Pro), an AI reloading assistant (Pro), and encrypted cloud backup to the user's own iCloud / Drive (Pro).

The promise: **your reloading data lives only on your device** unless *you* explicitly export it or opt in to the encrypted-backup feature.

> Audience for this README: a developer (probably future-you) returning to the codebase after weeks or months. It complements the more agent-friendly `CLAUDE.md` — read both. Code paths in this document are absolute (`/Users/general/Development/Applications/LoadOut/...`) so they grep cleanly.

---

## 1. Quick start

```sh
git clone <repo>
cd LoadOut
flutter pub get
flutter run                                # iOS or Android — pick a device
```

iOS-specific:

```sh
open ios/Runner.xcworkspace                # ALWAYS the workspace, never the .xcodeproj
flutter build ios --debug --no-codesign    # quick compile sanity (no signing chore)
```

Android-specific: `flutter run` is enough. Debug keystore is wired through Firebase, so Google sign-in and email-link verification work out of the box.

### First-run flow

1. **DisclaimerScreen** — full-screen legal disclaimer, recorded in `SharedPreferences` under `disclaimer_accepted_v1` once accepted. Subsequent launches show a quick reminder dialog. (See `lib/screens/disclaimer/disclaimer_screen.dart`.)
2. **Auth gate** (`_AuthGate` in `lib/app.dart`) — `LoginScreen` until Firebase Auth emits a non-null user, then `HomeScreen`.
3. **HomeScreen** — bottom-nav shell with five tabs (Recipes, Firearms, Batches, Ballistics, SAAMI). The first launch also seeds the reference catalog from `assets/seed_data/*.json` into SQLite via `SeedLoader.seedIfNeeded()`.

### Common commands

```sh
flutter analyze                                    # MUST be clean before commit
dart run build_runner build                        # regen drift code after schema changes
dart run build_runner watch --delete-conflicting-outputs   # watch mode
flutter test                                       # run the test suite
firebase deploy --only hosting                     # AASA + assetlinks updates
```

---

## 2. High-level architecture

```
+--------------------------------------------------+
|  UI (lib/screens/, lib/widgets/)                 |
|  Recipes / Firearms / Batches / Ballistics /     |
|  SAAMI / BrassLots / LoadDev / AI Chat / Backup  |
+--------------------------------------------------+
|  Repositories (lib/repositories/)                |
|  RecipeRepo / FirearmRepo / ComponentRepo /      |
|  BrassLotRepo / BatchRepo / ProcessStepRepo /    |
|  LoadDevelopmentRepo                             |
+--------------------------------------------------+
|  Services (lib/services/)                        |
|  AppDatabase (drift / SQLite)                    |
|  AuthService (Firebase Auth, 7 providers)        |
|  Ballistics solver (pure Dart, MPM)              |
|  ExportService + BackupCrypto (AES-256-GCM)      |
|  iCloudBackupService / DriveBackupService        |
|  PurchasesService + EntitlementNotifier          |
|  AiChatService (Anthropic Messages API)          |
+--------------------------------------------------+
|  External                                        |
|  Firebase Auth | RevenueCat | Anthropic API |    |
|  iCloud Drive  | Google Drive (appDataFolder)    |
+--------------------------------------------------+
```

**The flow from a user tap to a database write**, end-to-end:

1. User taps "Save" on `RecipeFormScreen` → `_save()` builds a `UserLoadsCompanion`.
2. Repo call: `context.read<RecipeRepository>().upsert(companion)`.
3. Repository → `db.into(db.userLoads).insert(...)` (drift typed insert).
4. drift translates that into a parameterized `INSERT` against the SQLite connection opened in `lib/database/database.dart`.
5. The insert returns the new row id; the form pops, the list rebuilds via the repository's stream.

**Composition root.** `lib/main.dart` boots Firebase, opens the drift database, runs `SeedLoader.seedIfNeeded()`, initializes RevenueCat, then hands the singletons to `LoadOutApp`. `lib/app.dart` declares one `MultiProvider` with every service the rest of the tree needs — every screen reads its dependencies via `context.read<T>()` / `context.watch<T>()`.

---

## 3. The data model (drift schema v5)

Schema lives in `lib/database/database.dart`. drift generates `database.g.dart` from it (NEVER edit the `.g.dart` file by hand). `schemaVersion = 5` as of this release.

### Reference tables (read-only, seeded from `assets/seed_data/`)

| Table | Holds | Seeded from |
|---|---|---|
| `Manufacturers` | One row per brand × `kind` (`powder`/`bullet`/`primer`/`brass`/`firearm`/`parts`). Unique on `(name, kind)`. | All seed JSONs, deduped. |
| `Cartridges` | 200+ rows. SAAMI/CIP dimensions: case length, COAL, body/shoulder/neck diameter, shoulder angle, MAP psi, twist rate, primer type, etc. | `cartridges.json` |
| `Powders` | Manufacturer FK + name + type + form + burn rate. | `powders.json` |
| `Bullets` | Manufacturer FK + line + diameter + weight + design + jacket + G1/G7 BCs. | `bullets.json` |
| `Primers` | Manufacturer FK + model code (e.g. `GM205M`) + size + magnum flag + `productLine` (marketing name). | `primers.json` |
| `BrassProducts` | Brand × tier × calibers offered. | `brass.json` |
| `FirearmsRef` | Brand + model + type + action + calibers offered. | `firearms.json` |
| `FirearmParts` | Replacement parts catalog with compatibility list. | `firearm_parts.json` |

These are **read by `ComponentRepository`**, **read by `SaamiScreen`** for the cartridge picker / spec card, and **read by autocomplete dropdowns** throughout the recipe form. Users never write to them.

### User-data tables (writable, exported by `ExportService`)

| Table | Read/write surfaces |
|---|---|
| `CustomComponents` | User-typed powders/bullets/primers/brass/cartridges that appear alongside reference items in dropdowns. Unique on `(kind, name)`. Wired through `ComponentRepository.addCustom*`. |
| `UserLoads` | The recipe table. **57 fields across 9 sections** in `RecipeFormScreen`. Linked to lot tables and (optionally) brass lot. CRUD via `RecipeRepository`. |
| `UserFirearms` | User's firearms with rifle/barrel detail (twist, throat erosion CBTO, last throat measurement). CRUD via `FirearmRepository`. |
| `BrassLots` | One labeled jug/box of cases. `firingCount` increments cascade from "Fire X rounds" on `BatchDetailScreen`. CRUD via `BrassLotRepository`. |
| `Batches` | One loading session: count, fired count, recipe FK, brass-lot FK, firearm FK, `processStateJson` (per-step checklist). CRUD via `BatchRepository`. |
| `UserProcessSteps` | User-customized reloading-process steps. 8 standard steps are seeded on fresh installs and v4 migrations. Per-cartridge-type applicability flags. CRUD via `ProcessStepRepository`. |
| `TestSessions` | One range trip with velocity stats (avg/SD/ES/CV), accuracy (group/MOA dispersion), environmentals. Linked to recipe + firearm + (optional) batch. |
| `PowderLots` / `BulletLots` / `PrimerLots` | Per-jug/per-box tracking. Recipes link to a lot via FK; the lot label survives even if the powder canister is consumed. |
| `UserCustomFields` / `UserCustomFieldValues` | User-defined fields on recipes/firearms/batches/brass-lots. `fieldType ∈ {text,number,boolean,date}`. |
| `LoadDevelopmentSessions` | Charge-ladder or seating-ladder experiments. Holds rung array as `rungsJson`, the user-selected `nodeValue`, and FK back to source recipe. Read by `LoadDevelopmentDetailScreen`. |

### Where seeding happens

- `lib/database/seed_loader.dart` reads `assets/seed_data/*.json` and inserts into the reference tables. Runs **once** on first launch, gated by `db.needsSeed`.
- `db.primersAreEmpty` re-seeds primers after the v3 migration drops them (so the new `productLine` column populates).
- `db.cartridgesNeedReseed` spot-checks `9mm Luger`'s `bodyDiameterIn` to detect a v2-migrated DB that still has `null` SAAMI dimensions; triggers a re-seed.
- The 8 standard `UserProcessSteps` are seeded by `_seedStandardProcessSteps()` from both `onCreate` (fresh installs) and the v4 migration step.

---

## 4. Feature inventory

### 4.1 Bottom-nav tabs

| Tab | File | Notes |
|---|---|---|
| **Recipes** | `lib/screens/recipes/recipes_list_screen.dart` + `recipe_form_screen.dart` (~95 KB) | 57 fields across 9 sections. Search filter at the top, three-level density toggle (Basic/Detailed/All), lot pickers (powder/bullet/primer/brass), inline custom fields. |
| **Firearms** | `lib/screens/firearms/` | Form covers manufacturer, model, type, action, caliber, barrel length, twist, shots fired, throat-erosion CBTO, last throat measurement date, `referenceFirearmId` link. |
| **Batches** | `lib/screens/batches/` | List + form + detail. Detail screen shows a caliber-filtered process checklist driven by `UserProcessSteps.appliesTo*`. "Fire X rounds" cascades into `BrassLots.firingCount`. |
| **Ballistics** | `lib/screens/ballistics/ballistics_screen.dart` (Pro) | See section 5. |
| **SAAMI Specs** | `lib/screens/saami/saami_screen.dart` | Cartridge picker + spec card. Renders cartridge + chamber drawings (Pro-gated drawings via `lib/widgets/cartridge_diagram.dart`). |

### 4.2 Drawer destinations

| Item | File |
|---|---|
| How It Works | `lib/screens/how_it_works/how_it_works_screen.dart` (topical menu + Quick Tour, deep-links into tabs via `HomeScreen.switchTab`) |
| Reloading Guide | `lib/screens/guide/reloading_guide_screen.dart` (8 stages of reloading, high-level) |
| Glossary | `lib/screens/glossary/glossary_screen.dart` (searchable terms reference) |
| Brass Lots | `lib/screens/brass_lots/` |
| Load Development | `lib/screens/load_development/` (Pro) |
| Reloading Steps | `lib/screens/process_steps/process_steps_screen.dart` (workflow editor) |
| Reloading Assistant | `lib/screens/ai_chat/ai_chat_screen.dart` (Pro, see section 9) |
| Backup & Export | `lib/screens/backup/backup_screen.dart` (Pro for cloud; local always free, see section 6) |
| Privacy Policy | `lib/screens/privacy/privacy_screen.dart` |
| Sign Out | `AuthService.signOut()` |

---

## 5. Deep-dive: Ballistics Calculator

Code lives under `lib/services/ballistics/`. The solver is a **Modified Point-Mass (MPM)** implementation in the McCoy / Litz tradition — a 3D point-mass equation of motion with empirical add-ons for the corrections that a true 6-DOF would otherwise need. At typical small-arms ranges the difference vs. a full 6-DOF is well below 0.1 MOA.

### State vector

`_State` in `solver.dart` (3 position + 3 velocity + time):

- `(x, y, z)` — bullet position in meters (x downrange, y up, z right of LoS)
- `(vx, vy, vz)` — velocity in m/s
- `t` — elapsed time in seconds since muzzle exit

Spin rate is computed once at the muzzle from twist (`Projectile.initialSpinRadPerSec`) but is NOT integrated as a state variable — spin drift is added post-integration via the Litz formula (see below).

### Forces in the equations of motion

Implemented in `_derivative()`:

1. **Gravity** — constant `_gravity = 9.80665 m/s²` downward. Earth's curvature is intentionally ignored (under 0.5" at 1500 yd).
2. **Aerodynamic drag** — applied along the *relative* wind vector (so wind drift falls out of the same expression).

   ```
   a_drag = (π/8) · i · D² / m  ·  ρ · v · Cd_std · (-v_relative)
          = dragK              ·  ρ · v · Cd       · (-v_relative)
   ```

   `dragK` is precomputed once. `Cd_std` comes from the drag-function table at the current Mach number (see "Drag function library" below). Form factor `i = SD / BC` is computed in `Projectile.formFactor`.

3. **Coriolis** — `a_cor = -2 Ω × v_bullet` in a north-east-up local frame. The Earth-rate components are precomputed once into `Environment.earthRotationVector` projected by shot azimuth. Toggleable via `includeCoriolis`.
4. **Wind** — folded into the drag term by computing `v_relative = v_bullet - v_air`, where `v_air` is `environment.windVector`.

### Integrator

Classical 4th-order Runge–Kutta (`_rk4Step`). Default `dt = 0.001 s`. Inside the **transonic band** (Mach 0.85–1.20) where the Cd curve has sharp features, the step is refined to `dt = 0.0002 s` (5× finer). Stop conditions:

- `state.x >= targetRangeM` — sample interpolation walks until the bullet crosses each requested range.
- `state.y < -50.0 m` — bullet hit the dirt.
- `state.speed < fpsToMps(100)` — went deeply subsonic / dead.
- `state.t >= 10.0 s` — failsafe.

### Drag function library

`lib/services/ballistics/drag_functions.dart`. Six standard projectile drag families:

| Model | Reference shape | Library coverage |
|---|---|---|
| **G1** | Ingalls flat-base, 2-caliber tangent ogive | Full-resolution table (1890s standard, default for hunting / pistol bullets) |
| **G7** | 1-caliber boat-tail, 10° boat-tail | Full-resolution (modern long-range bullets — Berger, Hornady ELD, Sierra MK) |
| **G2** | Aberdeen J | Abbreviated |
| **G5** | Short boat-tail | Abbreviated |
| **G6** | Flat-base spitzer | Abbreviated |
| **G8** | Modern flat-base | Abbreviated |

`dragCoefficient(model, mach)` does a binary search + linear interpolation between adjacent table samples. Below the first sample it clamps to the first value, above the last sample to the last.

### Atmosphere model

`lib/services/ballistics/atmosphere.dart`:

- ICAO Standard Atmosphere reference constants (sea level: 288.15 K, 101325 Pa, 1.225 kg/m³, sound = 340.294 m/s).
- Lapse rate `0.0065 K/m` up to ~11 km.
- Specific gas constants for dry air (`287.058 J/(kg·K)`) and water vapor (`461.495`).
- Humid-air density via Dalton's law of partial pressures, with **saturation vapor pressure from the Tetens formula**: `P_sat = 610.78 · exp(17.27 · T_C / (T_C + 237.3))` Pa. (Magnus is comparable; we picked Tetens for its simpler form.)
- `densityAltitudeFt` inverts the standard-atmosphere density formula to give the equivalent ICAO altitude — handy one-number summary on the trajectory output card.

Three constructors: `Atmosphere.icaoStd()`, `Atmosphere.station(...)` (real weather report), `Atmosphere.fromAltitudeFt(...)` (ICAO standard at altitude).

### Stability + spin drift (post-integration)

In `Projectile`:

- **Miller stability factor `Sg`** — from Miller's "A New Rule for Estimating Rifling Twist" (Precision Shooting, March 2005). Velocity-corrected by `(V/2800)^(1/3)`.
- **Litz spin drift** — applied AFTER integration, not in the EoM:

   ```
   Sd = 1.25 · (Sg + 1.2) · t^1.83    [inches]
   ```

  Right-hand twist drifts the bullet right (+z). The result is added to `windDriftInches` for users who want the lumped figure, and exposed separately as `spinDriftInches` for breakdown.

### Zero solver

`_findDepartureAngle()` in `solver.dart` is a **bisection** on muzzle-elevation angle θ:

1. Start with the analytic small-angle estimate `θ₀ ≈ ½ g R / v₀²`.
2. Bracket the answer in `[θ₀ - 0.020, θ₀ + 0.040]` rad (window expands up to 8 times if needed).
3. Bisect 40 iterations or until residual at zero range falls below 1e-4 m (~0.1 mm at 1000 yd).

The line of sight tilts down from `+sightHeightM` at the muzzle to `0` at zero range, then below — so `losY(x) = sightHeightM · (1 - x/zeroRangeM)`. Drop is reported as `losY - bullet.y` (positive = below LoS, what shooters expect).

### What is NOT in the solver

Compared to a full McCoy MPM / 6-DOF, we omit:

1. **Bullet pitch / yaw / precession** — full 6-DOF integrates angular momentum. We model only the post-integration spin-drift correction.
2. **Aerodynamic jump from cant** — `ShotInputs.muzzleCantDeg` is exposed but not currently applied. Would feed an initial vertical-angle perturbation proportional to crosswind × cant.
3. **Earth's curvature** — flat-Earth, constant gravity. Documented as <0.5" at 1500 yd.
4. **Drag table interpolation order** — linear, not cubic-spline. Sufficient for a Mach-resolution input curve.
5. **Mass/CG offsets**, gyroscopic damping, Magnus force.

### Test fixture

`test/ballistics_test.dart` covers a hand-verified case: 6.5 Creedmoor, 140gr Hornady ELD-M, MV 2750 fps, G7 BC 0.298, 1:8 twist, ICAO standard, 100 yd zero. Asserts:

- 100 yd drop ≈ 0
- 1000 yd drop in (300, 440) inches
- 1000 yd spin drift in (2, 15) inches
- 1000 yd velocity in (900, 1500) fps
- ICAO sea-level density = 1.225 kg/m³ ± 1e-3
- G1 muzzle Cd = 0.2629 ± 1e-3, G7 = 0.1198 ± 1e-3 (matches published tables)

### Recommended further reading

- Robert L. McCoy — *Modern Exterior Ballistics* (1999). The canonical text for Modified Point-Mass.
- Bryan Litz — *Applied Ballistics for Long-Range Shooting* (2009). Source of the spin-drift formula and many practical corrections.

---

## 6. Deep-dive: Backup & Export

All user-data flows through `lib/services/export_service.dart` and (for cloud) `lib/services/backup_crypto.dart`. The driver UI is `lib/screens/backup/backup_screen.dart`.

### Local export (always free)

1. `ExportService.exportToJson()` walks `kUserDataTableOrder` (a hand-maintained, FK-safe ordering: `custom_components` → `*_lots` → `user_process_steps` → `user_firearms` → `user_loads` → `batches` → `test_sessions` → `user_custom_fields` → `user_custom_field_values`).
2. Each table dumps via the drift-generated `Row.toJson()` so unknown columns auto-roll-forward as the schema evolves.
3. Output wrapper (pretty-printed JSON):

   ```json
   {
     "loadout_export_version": 1,
     "exported_at": "2026-05-07T12:34:56.000Z",
     "schema_version": 5,
     "tables": { "user_loads": [...], ... }
   }
   ```

4. Reference tables (`Cartridges`, `Powders`, `Bullets`, `Primers`, `BrassProducts`, `FirearmsRef`, `FirearmParts`, `Manufacturers`) are intentionally **excluded** — they ship with every install and would only inflate backups.

5. `writeExportToTempFile({filename})` stages the JSON to `getTemporaryDirectory()` with a timestamped filename, returns the `File` for `share_plus` to hand off to the system share sheet.

6. **Importing** (`importFromJson(json, {mode})`):
   - Validates the wrapper:
     - Inbound `loadout_export_version` > our `kLoadOutExportVersion` → fatal "newer version of LoadOut".
     - Inbound `schema_version` > runtime `db.schemaVersion` → fatal "Backup uses database schema vX, but this app is on vY".
     - Older payloads accepted (forward-compatible).
   - Walks `kUserDataTableOrder` so FK targets land before referrers.
   - **Merge mode** (`ImportMergeMode`):
     - `skipDuplicates` (default) — keep local row, count inbound as `skipped`.
     - `overwrite` — `InsertMode.insertOrReplace` clobbers local rows.
   - Whole import runs inside a single `db.transaction(...)` for atomicity.
   - Unknown table names are silently ignored (forward-compatibility safety net).
   - Returns `ImportSummary` with per-table `added/skipped/errors` counts.

### Cloud backup (Pro, opt-in, encrypted client-side)

#### Encryption (`backup_crypto.dart`)

| Property | Value |
|---|---|
| Cipher | **AES-256-GCM** (authenticated encryption — confidentiality + integrity in one) |
| KDF | **PBKDF2-HMAC-SHA256**, **200,000 iterations** (matches OWASP 2023 SHA-256 PBKDF2 guidance) |
| Salt | 16 bytes from `Random.secure()` per call |
| Nonce | 12 bytes (AES-GCM standard) per call |
| Auth tag | 16 bytes |
| Min passphrase | 8 chars (enforced in `BackupCrypto._validatePassphrase`) |

Blob layout:

```
0..8    magic "LOADOUT1\0"  (9 bytes)
9       version             (1 byte, currently 1)
10..25  salt                (16 bytes)
26..37  nonce               (12 bytes)
38..53  GCM tag             (16 bytes)
54..    ciphertext          (variable)
```

**Threat model**:

1. **The encrypted blob is treated as PUBLIC.** We assume any cloud provider it lives on (iCloud, Drive) MIGHT leak it. Confidentiality + integrity rely entirely on the user's passphrase.
2. The user's device is trusted while the app is running. The 32-byte derived key sits in plain memory during one operation, then goes out of scope. We DO NOT persist the key, the passphrase, or any convenience cache.
3. Wrong passphrase or any tampered byte → `SecretBoxAuthenticationError` → re-thrown as `BackupDecryptException`.
4. No LoadOut-side identifiers (install id, user id, anything analytics-shaped) appear in the plaintext. Plaintext is purely the JSON the user typed.

#### iCloud Drive (iOS-only) — `lib/services/icloud_backup_service.dart`

- Plugin: `icloud_storage` 2.x.
- Container: `iCloud.com.johnsondigital.loadout` (declared in `ios/Runner/Runner.entitlements`).
- The capability **must be enabled** at developer.apple.com → Identifiers → `com.johnsondigital.loadout` → "iCloud Documents". Until it is, `isAvailable()` returns false and the Backup screen surfaces a "Sign in to iCloud in Settings" message instead of crashing. (Tracked in `LAUNCH_CHECKLIST.md`.)
- Files land in `Documents/Backups/<filename>.lo1` inside the container — visible in Files.app to the user. LoadOut never sees the blob (the container is per-app private; `list()` filters to `.lo1` files for safety).

#### Google Drive (cross-platform) — `lib/services/drive_backup_service.dart`

- Scope: `https://www.googleapis.com/auth/drive.appdata` (the special **per-app appDataFolder** — hidden from the user's Drive UI; even the user can't see these files in `drive.google.com`). Quotas come out of normal Drive allotment.
- Auth flow (google_sign_in 7.x):
  1. `GoogleSignIn.instance.initialize()` once per process.
  2. `authenticate(scopeHint: ['email', 'profile'])`.
  3. `account.authorizationClient.authorizeScopes([driveAppdataScope])` — separate consent sheet on iOS.
- The bridge `extension_google_sign_in_as_googleapis_auth` is **not yet compatible** with the v7 singleton API, so `_GoogleAuthClient` (a small `http.BaseClient` subclass) injects bearer tokens manually. That client feeds the v3 `drive.DriveApi`.
- File naming: every blob suffixed `.lo1`. `_findByName` is used on upload to update in-place rather than leave duplicates.

### Restore flow (`backup_screen.dart`)

User picks a blob → enters passphrase → derive key (PBKDF2) → AES-GCM decrypt → choose merge mode → `ExportService.importFromJson()`.

---

## 7. Deep-dive: Privacy positioning

The marketing claim and in-app privacy dialog say:

> Your reloading data — recipes, firearms, custom components, brass lots, batches, custom fields — is stored only on this device.

Concrete behavior:

- **All user reloading data** lives in the on-device SQLite DB opened in `lib/database/database.dart`. There is no network sync.
- **Firebase Auth** (the only Firebase service used at runtime) processes email addresses and OAuth tokens during sign-in. That is the only personal data leaving the device.
- **Cloud backup is opt-in.** Encrypted on-device with the user's passphrase, uploaded to the user's own iCloud or Drive. LoadOut never receives the encrypted blob and cannot decrypt it (the passphrase never leaves the device).
- **Local export is always free.** Plain JSON, written to a temp file, handed to the system share sheet — LoadOut servers are not involved.
- **Uninstalling deletes the data.** No cloud mirror.

Reference: `PRIVACY_POLICY.md` is canonical. The in-app dialog text lives in `_DisclaimerGate` / `_showPrivacyDialog`. **Do not add cloud-backed storage of user reloading data without revisiting all three** (in-app dialog, store privacy disclosures, landing-page copy).

---

## 8. Deep-dive: Pro gating

Single entitlement `pro` configured in RevenueCat. Two SKUs:

| SKU | Tier | Price |
|---|---|---|
| `loadout_pro_yearly` | Yearly | **$39.99/yr** |
| `loadout_pro_lifetime` | Lifetime | **$79.99** |

(Decision 2026-05-07 — no monthly tier. Reloading is a slow-cycle hobby; monthly subs churn hard. See `LAUNCH_CHECKLIST.md`.)

### Code

- `lib/services/purchases_service.dart` — wraps `purchases_flutter`.
- `lib/services/entitlement_notifier.dart` — `ChangeNotifier` exposing `isPro`. Subscribes to `PurchasesService.customerInfoStream`. Provided via `provider` so any widget can do `context.watch<EntitlementNotifier>()`.
- `lib/services/revenue_cat_config.dart` — the (PUBLIC) API keys. iOS key (`appl_*`) is real; Android key (`test_*`) is the onboarding test key pending Play Console identity verification — replace with `goog_*` once available.
- `lib/screens/paywall/paywall_screen.dart` — upgrade UI.

### Gating helpers

- `ProGate(feature: 'Smart import', child: ...)` — inline render gate. Renders `child` if Pro, else a lock tile that opens the paywall.
- `ensurePro(context)` — action gate. Returns `true` if Pro; otherwise opens the paywall and returns `true` only if the user upgraded during the visit.

```dart
// Inline
ProGate(feature: 'Ballistics calculator', child: BallisticsScreen())

// Action
onTap: () async {
  if (!await ensurePro(context)) return;
  await runImport();
}
```

### Cross-platform entitlement linking

The auth-state listener in `_AuthGate` calls `PurchasesService.setAppUserId(user.uid)` on sign-in and `setAppUserId(null)` on sign-out. **A user who buys Pro on iOS sees Pro on Android when they sign in with the same Firebase account.**

### What's currently Pro-gated

- Cartridge / chamber drawings on `SaamiScreen`
- Ballistics Calculator (`BallisticsScreen`)
- AI Reloading Assistant (`AiChatScreen`)
- Cloud backup (iCloud / Drive — local export stays free)
- Load Development (`LoadDevelopmentListScreen`)

Setup runbook for App Store Connect, Play Console, and the RevenueCat dashboard: `REVENUECAT_SETUP.md`.

---

## 9. Deep-dive: AI chat (liability)

`lib/services/ai_chat_service.dart` + `lib/services/ai_chat_config.dart`.

### Three-layer safety filter

1. **System prompt** (`kReloadingAssistantSystemPrompt`) — the model is told in absolute terms: never give specific load data (charge weights, COAL targets, pressure values, primer recommendations). Always redirect to current published manuals (Hodgdon, Sierra, Hornady, Lyman, etc.).
2. **Output regex check** (`AiChatService.looksLikeLoadData`) — 3-of-3 heuristic: response must contain a charge-weight pattern (`\d{1,2}(\.\d{1,2})?\s*(gr|grains?)`) AND a known powder name (~75 powders) AND a known cartridge name (~60 cartridges) to trip. Two of three is allowed (so general talk like "Varget is popular for the .308" passes).
3. **Visible disclaimer** — every conversation surfaces the standard "cross-check current published manuals" reminder.

When the regex trips, the assistant turn is replaced with `kSafetyRefusal` and styled as an error bubble. The quota burns anyway (a determined adversary shouldn't get free retries).

### Quota

30 questions / Pro user / calendar month. Resets on the 1st (period key `YYYY-MM` in `SharedPreferences`). Failed network calls don't burn quota; safety-filter hits do.

### Model + key handling

- Model: `claude-sonnet-4-7`, max 600 output tokens.
- Endpoint: `https://api.anthropic.com/v1/messages` with `anthropic-version: 2023-06-01`.
- Key currently lives in `AiChatConfig.anthropicApiKey` as `REPLACE_ME_ANTHROPIC_KEY`. **Until set to a real key, `AiChatConfig.isPlaceholder` returns true** and the chat UI renders a "coming soon" state — safe to ship without keys.

### Long-term plan

The Anthropic API key SHOULD NOT ship in the binary. Move to a backend proxy (Cloud Function) that:

1. Authenticates the user via Firebase ID token.
2. Verifies Pro entitlement against RevenueCat.
3. Applies the per-user quota server-side.
4. Holds the Anthropic key as a server secret.

Client request shape, safety filter, and quota accounting won't change — only the URL and credential header.

---

## 10. File tour (`lib/`)

```
lib/
  main.dart                    Cold-start: Firebase init, drift open, seed, RevenueCat, runApp
  app.dart                     Widget tree root, MultiProvider, _DisclaimerGate, _AuthGate
  firebase_options.dart        Generated by flutterfire configure
  theme/
    app_theme.dart             Brass/gunmetal palette + light/dark themes
  database/
    database.dart              drift schema (v5), all 22 tables, MigrationStrategy
    database.g.dart            GENERATED — never edit
    seed_loader.dart           Reads assets/seed_data/*.json into SQLite on first run
  repositories/
    component_repository.dart  Reference + custom components for dropdowns
    firearm_repository.dart    UserFirearms CRUD + adjustShotsFired
    recipe_repository.dart     UserLoads CRUD
    brass_lot_repository.dart  BrassLots CRUD
    batch_repository.dart      Batches + TestSessions CRUD
    process_step_repository.dart  UserProcessSteps CRUD
    load_development_repository.dart  LoadDevelopmentSessions CRUD
  services/
    auth_service.dart          Wraps FirebaseAuth — 7 providers + email link
    purchases_service.dart     RevenueCat SDK wrapper + customer info stream
    revenue_cat_config.dart    Public API keys + entitlement key + isPlaceholder
    entitlement_notifier.dart  ChangeNotifier exposing isPro
    export_service.dart        Local JSON export/import + ImportSummary
    backup_crypto.dart         AES-256-GCM + PBKDF2 (200k iter)
    cloud_backup.dart          CloudBackupProvider abstract + CloudBackupMetadata
    icloud_backup_service.dart iOS iCloud Drive provider
    drive_backup_service.dart  Cross-platform Google Drive (appDataFolder) provider
    ai_chat_config.dart        Anthropic key + model + quota constants
    ai_chat_service.dart       Anthropic Messages API + safety filter + quota
    ballistics/
      atmosphere.dart          ICAO ISA + Tetens humid-air density + density-altitude
      drag_functions.dart      G1/G2/G5/G6/G7/G8 tables + interpolation
      environment.dart         Wind vector + earth-rotation projection
      projectile.dart          Bullet shape, BC, Miller stability
      solver.dart              MPM solver — RK4 + adaptive transonic step + zero bisection
      units.dart               yards/m, fps/mps, in/m, gr/kg, J/ft-lb conversions
  screens/
    auth/login_screen.dart     Sign-in (7 providers + email link)
    disclaimer/disclaimer_screen.dart   Full-screen legal disclaimer (first run)
    home/home_screen.dart      Bottom-nav shell (5 tabs) + drawer
    onboarding/onboarding_screen.dart   First-run intro (currently optional)
    privacy/privacy_screen.dart Privacy policy as in-app screen
    recipes/                   Recipes list + 95KB form (57 fields, 9 sections)
    firearms/                  Firearms list + form
    batches/                   Batches list + form + detail (process checklist)
    brass_lots/                Brass lots list + form
    load_development/          Pro: charge-ladder + seating-ladder experiments
    process_steps/             Workflow editor for UserProcessSteps
    saami/saami_screen.dart    Cartridge picker + spec card (+ Pro drawings)
    ballistics/                Pro: trajectory solver UI
    glossary/glossary_screen.dart   Searchable terms reference
    guide/reloading_guide_screen.dart   8 stages of reloading (high-level)
    how_it_works/how_it_works_screen.dart   Topical menu + Quick Tour
    ai_chat/ai_chat_screen.dart Pro: Anthropic-backed chat with safety filter
    backup/backup_screen.dart  Local export + cloud backup driver (Pro for cloud)
    paywall/paywall_screen.dart RevenueCat offerings + purchase flow
  widgets/
    cartridge_diagram.dart     Cartridge + chamber drawings (Pro-gated)
    component_field.dart       Autocomplete with typed-custom field
    primer_cascade_field.dart  Cascading manufacturer → product line → name picker
    pro_gate.dart              ProGate widget + ensurePro() action gate
    disclaimer_overlay.dart    showLaunchDisclaimer() reminder dialog
```

---

## 11. Migration history

| Version | What it added |
|---|---|
| **v1** | Initial schema: minimal `UserLoads` + `UserFirearms` + reference tables (`Manufacturers`, `Cartridges`, `Powders`, `Bullets`, `Primers`, `BrassProducts`, `FirearmsRef`, `FirearmParts`, `CustomComponents`). |
| **v2** | Extended SAAMI/CIP fields on `Cartridges`: body diameter, shoulder diameter, shoulder angle, neck diameter, neck length, base-to-shoulder, base-to-neck, rim diameter, rim thickness, primer type, twist rate, MAP psi, bore/groove diameter, case subtype, SAAMI doc reference. The migration adds the columns; `cartridgesNeedReseed` getter spot-checks `9mm Luger.bodyDiameterIn` to decide whether to re-seed. |
| **v3** | `Primers.productLine` (manufacturer marketing names) for the cascading primer dropdown. **Migration deletes existing primer rows** + primer-kind manufacturer rows so `seedIfNeeded` re-runs and populates the new column. User data untouched. |
| **v4** | The big one. **9 new tables**: `PowderLots`, `BulletLots`, `PrimerLots`, `BrassLots`, `UserProcessSteps`, `Batches`, `TestSessions`, `UserCustomFields`, `UserCustomFieldValues`. **40+ new columns on `UserLoads`** (status, useCase, lot FKs, bullet sorting flags, distance-to-lands, jump, runout, pressure indicators, process/equipment provenance). **6 new columns on `UserFirearms`** (barrel manufacturer, chamber reamer, tuner setting, cumulative round count, throat erosion CBTO, last throat measurement). Seeds the 8 standard process steps. |
| **v5** | `LoadDevelopmentSessions` for charge-ladder + seating-ladder experiments. |

**Rule:** every schema change adds an `if (from < N) { ... }` block in `MigrationStrategy.onUpgrade` — fall-through, NOT `else if`. SQLite cannot drop or alter columns once they exist; only add. Run `dart run build_runner build` after every change to `database.dart`.

---

## 12. Common dev workflows

### Adding a new field to UserLoads (recipe form)

1. Edit `lib/database/database.dart` — add the column to the `UserLoads` class.
2. Bump `schemaVersion` to N+1.
3. Add an `if (from < N+1) { await m.addColumn(userLoads, userLoads.<newField>); }` block in `MigrationStrategy.onUpgrade`.
4. Run `dart run build_runner build`.
5. In `lib/screens/recipes/recipe_form_screen.dart`, add a `_FieldDef` entry.
6. Assign it to the right `_Section`.
7. Test on a real device (migrations only fire on existing installs — fresh installs go through `onCreate`).

### Adding a new screen

1. Create a file under `lib/screens/<area>/<your_screen>.dart`.
2. Add a drawer entry in `_MainDrawer` in `lib/screens/home/home_screen.dart`, or take a slot in `_navItems` for a new bottom-nav tab.
3. If the screen needs a repository, wire it into `MultiProvider` in `lib/app.dart` — and pull it via `context.read<MyRepo>()`.

### Adding a new SAAMI cartridge

1. Edit `assets/seed_data/cartridges.json` — match the shape of existing entries.
2. Either flush the simulator's app data, OR bump `schemaVersion` and trigger a re-seed via `cartridgesNeedReseed` (see existing v2 path).

### Updating a primer's marketing name

1. Edit `assets/seed_data/primers.json` — adjust the `productLine` field.
2. Re-seed. The v3 migration auto-clears `Primers` so it re-seeds on next launch; for further updates after v3, you'd add a new migration block that nukes the table.

---

## 13. Testing

```sh
flutter analyze                     # MUST be clean before commit
flutter test                        # full suite
flutter test test/ballistics_test.dart  # solver regression
```

| Test file | Covers |
|---|---|
| `test/ballistics_test.dart` | 6.5CM 140gr ELD-M baseline, atmosphere sea-level density, drag-table samples (G1/G7), unit conversion roundtrips. |
| `test/export_service_test.dart` | Round-trip export → fresh DB import, `skipDuplicates` vs `overwrite` behavior, future export-version rejection, AES-GCM round-trip, wrong-passphrase rejection, tamper detection (single-byte flip), nonce uniqueness across calls. |
| `test/widget_test.dart` | Placeholder. Replace with real coverage — known launch-checklist item. |

More tests are needed across drift integration (`NativeDatabase.memory()`), repositories, and key UI smoke flows. CI is not yet set up.

---

## 14. Build commands cheat sheet

```sh
# Daily
flutter pub get
flutter analyze
flutter run
flutter test

# After schema change
dart run build_runner build
# or
dart run build_runner watch --delete-conflicting-outputs

# iOS
open ios/Runner.xcworkspace                # NOT the .xcodeproj
flutter build ios --debug --no-codesign    # quick compile sanity

# Android
flutter run                                # debug keystore wired through Firebase
flutter build apk --release                # needs release keystore SHA in Firebase + assetlinks

# Firebase
firebase deploy --only hosting             # AASA + assetlinks updates
flutterfire configure --project=loadout-precision-reloading

# RevenueCat / IAP
# (see REVENUECAT_SETUP.md — runbook for App Store Connect + Play Console + dashboard)
```

---

## 15. Identifiers (quick reference)

| | |
|---|---|
| App name | **LoadOut** |
| Store name | **LoadOut: Precision Reloading** |
| Bundle ID / Android package | `com.johnsondigital.loadout` |
| Firebase project ID | `loadout-precision-reloading` |
| Apple Team ID | `7265YL85SB` |
| Hosting URL | https://loadout-precision-reloading.web.app |
| iCloud container | `iCloud.com.johnsondigital.loadout` |
| Flutter SDK | `^3.11.5` (see `pubspec.yaml`) |
| App version | `1.0.0+1` |

---

## 16. Pointers to other docs

- **`CLAUDE.md`** — agent-friendly project guide (the canonical short-form architecture description; complements this README).
- **`SETUP.md`** — day-to-day commands and predates the v4/v5 schema work; read with a grain of salt — this README is authoritative.
- **`LAUNCH_CHECKLIST.md`** — pre-launch open items (Apple JWT rotation, Azure secret rotation, release keystore SHA, Associated Domains capability, etc.).
- **`REVENUECAT_SETUP.md`** — App Store Connect + Play Console + RevenueCat dashboard setup.
- **`PRIVACY_POLICY.md`** — full privacy stance (the hosted version is what app stores link to).
- **`ROADMAP.md`** — product direction, Free vs Pro split, sequencing.
- **`assets/seed_data/README.md`** — seed data format reference.
