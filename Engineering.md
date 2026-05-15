# Engineering.md — LoadOut engineering reference

```
================================================================================
WHAT THIS FILE COVERS
================================================================================
System architecture, tech stack, schema, repositories, services, file
layout, build/run commands, Firebase setup, authentication, cloud-sync
internals, AI Smart Import internals, hard fences, deployment, and the
auto-commit + auto-merge workflow.

A standalone "Recipes engineering" section at the end (§ 19) consolidates
everything specific to the recipes surface — schema, services, import
architecture, autosave, custom fields. Read § 19 before touching anything
under `lib/screens/recipes/` or the related repositories.

Read this before touching schema, repositories, services, configuration,
deployment, or anything that crosses the device/server boundary.

================================================================================
WHAT THIS FILE DOES NOT COVER
================================================================================
- Solver math, drag tables, ballistic corrections → Ballistics.md
- Screen layouts, picker behavior, scene painter → UI.md
- Voice, brand promises, copy guidelines → Marketing.md
```

---

## 1. Architecture overview

### One-paragraph summary

Flutter app on Dart, four ship platforms (iOS / Android / macOS / web), one codebase. User data is local-only via `drift` (SQLite on native; OPFS / IndexedDB on web). Firebase handles authentication only — no Firestore in production, no Cloud Storage of reloading data. Cloud Sync (Pro) end-to-end encrypts on device before uploading to the user's own iCloud Drive / Google Drive / OneDrive. RevenueCat client-side checks Pro entitlement. Anthropic API is invoked only for the opt-in AI Smart Import overlay (an in-review-screen card on photo imports, not a standalone screen), routed through a Cloudflare Worker proxy that enforces a per-Pro-user monthly cap. Crashlytics is the only telemetry surface (opt-out fatal-crash reporting; PII redacted).

### Key architectural decisions

| Decision | Why |
|---|---|
| Local-first SQLite via drift | "We don't see what we don't have" privacy posture; no backend cost; no GDPR/CCPA data-processor relationship over reloading data |
| Firebase Auth only (no Firestore for user data) | Industry-trusted auth at zero cost; reloading data stays off the wire |
| RevenueCat for IAP | Single SDK for App Store + Play Store; entitlement sync via Firebase UID linking |
| Cloudflare Worker proxy for Anthropic | Per-Pro-user cap enforcement; keeps the Anthropic API key off the client; pseudonymous logging only |
| AES-256-GCM + PBKDF2 200k for Cloud Sync | Strong encryption; passphrase never leaves the device; lost-passphrase = lost-data is acceptable per privacy contract |
| Flutter across iOS / Android / macOS / web | One codebase; same drift schema across platforms |
| Unified Recipe Import landing screen (§ 19.4) | One canonical entry point for every import source; source detection from input rather than menu picks |

---

## 2. Tech stack

| Layer | Technology |
|---|---|
| Language | Dart |
| Framework | Flutter |
| Local DB | `drift` (SQLite on native, WASM-OPFS on web) |
| Auth | Firebase Authentication |
| IAP | RevenueCat (iOS `appl_*` key, Android `goog_*` key) |
| AI proxy | Cloudflare Worker at `anthropic-proxy.loadout-precision-reloading.workers.dev` |
| Crash reporting | Firebase Crashlytics (opt-out; PII redacted) |
| Weather | open-meteo.com REST API |
| OCR | Google ML Kit text recognition (on-device) |
| Cloud storage (user's own) | iCloud Drive (`icloud_storage`), Google Drive (`googleapis`), Microsoft OneDrive (`Files.ReadWrite.AppFolder` via PKCE) |
| Secure storage | `flutter_secure_storage` (iOS Keychain / Android Keystore) |
| Biometric auth | `local_auth` |
| BLE | `flutter_blue_plus` |
| SVG rendering | `flutter_svg` + custom parser (`svg_path_parser`) |
| QR scanning | `mobile_scanner` |
| QR / barcode permission | `permission_handler` |
| Camera + gallery | `image_picker` |
| File picker | `file_picker` |

---

## 3. Identifiers

| | |
|---|---|
| App name | LoadOut |
| Store name | LoadOut: Precision Reloading |
| Bundle ID / package | `com.johnsondigital.loadout` |
| Watch bundle | `com.johnsondigital.loadout.watchkitapp` |
| Wear OS package | `com.johnsondigital.loadout.wear` |
| Firebase project ID | `loadout-precision-reloading` |
| Apple Team ID | `7265YL85SB` |
| Firebase console | https://console.firebase.google.com/project/loadout-precision-reloading |
| Hosting URL | https://loadout-precision-reloading.web.app |
| Marketing host | `loadout-precision-reloading.web.app` |
| Default Storage bucket | `gs://loadout-precision-reloading.firebasestorage.app` |

---

## 4. Database (drift)

### Current schema version

**v40** (stable since Phase 9.5 Group C — 2026-05-14).

> **AUDIT-PENDING (Phase Two item #11).** The schema-version history table below is incomplete. The recipe form references migrations not represented here (e.g. "v4 numeric controllers," "v15 ballistic-precision inputs"). Phase Two walks `lib/database/database.dart`'s `MigrationStrategy` and reconstructs the v1→v40 sequence. Until then, the canonical history lives in `database.dart` itself; the table below is a partial summary.

### Bumping schema

1. Edit `lib/database/database.dart`. Add / modify the relevant `Table` class.
2. Bump `schemaVersion` integer.
3. Write the matching `MigrationStrategy` step. The `database.g.dart` generated file will guide you; the operator-side migration is plain SQL.
4. Run `dart run build_runner build` to regenerate `database.g.dart`.
5. Test the migration on a real device — schema bumps should never go to TestFlight without device verification.

### Schema-version history (partial)

| Version | Phase | Change |
|---|---|---|
| v25 | Pre-painter | `UserComponentFavorites` table — name-keyed favorites for powder / bullet / primer / brass with one-shot SharedPreferences migration |
| v36 → v37 | Painter Phase 6 | Added `center_point` field to targets |
| v37 → v38 | Painter Phase 7a | Added `svg_scale_factor` field to targets |
| v38 → v39 | Scene Painter Phase 9.5 Group A | Target taxonomy collapse — drops the legacy `shape` text column, introduces a closed-set `category` enum (`circle` / `square` / `rectangle` / `ipsc` / `animal` / `special`). Drop+recreate migration on `Targets` since the table is reference-only and pre-launch |
| v39 → v40 | Scene Painter Phase 9.5 Group C | Rack model collapse — drops the legacy `TargetRackChildren` FK child table entirely; each rack's children now ride inline on a new `TargetRacks.slotsJson` column via the drift TypeConverter `RackSlotsConverter` (see `lib/database/rack_slot.dart`). Drop+recreate migration |

Earlier recipe-side migrations (v4 numeric controllers, v15 ballistic-precision inputs including powder temp sensitivity, charge tolerance, bullet weight tolerance, bullet BTO tolerance, web expansion, distance/jump to lands, loaded neck diameter, runout TIR, etc.) are real but not yet documented here. See `database.dart` for ground truth.

### Repositories

- **`ComponentRepository`** — wraps queries against cartridges, powders, bullets, primers, brass, plus the custom-component tables. Also owns `caliberLabelForBulletDiameter(double in)` (§ 19.9).
- **`RecipeRepository`** (formerly LoadRepository in older docs) — `UserLoads` CRUD and queries, plus lot CRUD (`createPowderLot` / `createPrimerLot` / `createBulletLot` / `createBrassLot`), custom-field CRUD (`createCustomField` / `setCustomFieldValue` / `customFieldsForEntity` / `customFieldValuesForEntity`), and the `mostUsedComponentNames(kind)` query for picker frequency sorting.
- **`FirearmRepository`** — firearm CRUD + shots-fired increment.
- **`FavoritesRepository`** — int-row-id-keyed favorites table (`UserFavorites`), used for cartridge / reticle / target favorites. Plus the watch stream API the autocomplete picker subscribes to.

For component favorites (powder / bullet / primer / brass), see `ComponentFavoritesService` — name-keyed, stored in `UserComponentFavorites`.

### Target catalog schema (canonical design)

The target catalog is a clean example of the docs-describe-right-design principle in action. Two fields, each with exactly one job:

```
category: enum (required)
  Values: 'circle' | 'square' | 'rectangle' | 'ipsc'
        | 'animal' | 'special'
  Drives: chip filtering AND painter dispatch
  Every row has exactly one value.

shape_id: optional string
  Used ONLY where a category has multiple distinct items that need
  per-item rendering or lookup. Two categories use it today:

    - animal:  species name ('deer', 'bear', 'bigfoot', 'mule_deer',
               'elk', 'moose', 'pronghorn', 'mountain_lion', 'coyote',
               'fox', 'rabbit', 'groundhog', 'prairie_dog', 'wild_turkey',
               'pheasant', 'boar') — drives per-species SVG lookup.
    - special: apparatus type ('pepper_popper', 'texas_star', and future
               additions like 'plate_rack', 'dueling_tree_steel',
               'falling_plates', 'bowling_pins') — drives per-apparatus
               painter dispatch.

  Null for every other category.
```

The `shape` field that existed in earlier iterations is **dropped** — it carried information already encoded in `category` and added a brittle "shape == silhouette + shape_id != ipsc" exclusion that's been a regular source of bugs.

Distribution across the 91 rows:

| category | count | notes |
|---|---|---|
| `circle` | 13 | 1 in through 24 in |
| `square` | 6 | 2 in through 12 in |
| `rectangle` | 15 | 6 generic + 9 named competition (NRA, F-Class, Bullseye, Dueling Tree) |
| `ipsc` | 6 | All six IPSC silhouette variants |
| `animal` | 48 | 16 species × 3 sizes — `shape_id` set per species |
| `special` | 3 | Pepper poppers + Texas Star — `shape_id` per apparatus |

The `special` umbrella exists for low-volume target types that share the "uncommon / reactive / standalone" pattern but each have distinct rendering. Adding a future apparatus (plate rack, steel dueling tree, falling plates) is a one-row catalog change with a new `shape_id` value plus a painter case — no schema bump, no enum growth. This parallels the animal umbrella exactly.

### Chip filtering (all positive matches)

Five chips above the picker. Every predicate is `category == X` — no negative matches, no compound expressions.

```dart
Circle:    category == 'circle'
Square:    category == 'square'
Rectangle: category == 'rectangle'
IPSC:      category == 'ipsc'
Animal:    category == 'animal'
```

A 6th `Special` chip (`category == 'special'`) is available if the special bucket grows. Today's 3 specialty rows are reachable via the unfiltered view — see UI.md § 9 for the active UI decision.

### Painter dispatch (also category-driven)

```dart
// Rendering strategy
final usesSvg        = category == 'ipsc' || category == 'animal'
                       || (category == 'special' && _shapeIdUsesSvg(shape_id));
final groundStanding = category == 'animal';

// Per-category drawer
switch (category) {
  case 'circle':    drawCircle(dims);
  case 'square':    drawSquare(dims);
  case 'rectangle': drawRectangle(dims);
  case 'ipsc':      drawSvg('ipsc', dims);
  case 'animal':    drawAnimalSvg(shape_id, dims);    // shape_id = species
  case 'special':   drawSpecial(shape_id, dims);      // routes by apparatus type
}
```

`drawSpecial` switches on `shape_id` to the apparatus-specific drawer (popper, star, etc.). Mix of procedural and SVG per apparatus.

Single field drives the chip layer, the dispatch layer, and the rendering-strategy decision. `shape_id` is consulted only inside categories that need within-category disambiguation.

### Migration (shipped in Phase 9.5 Group A — v38 → v39)

The category-driven taxonomy shipped on 2026-05-14 via a drop+recreate migration on `Targets` (reference-only table; pre-launch posture means no user data to preserve). The migration:

1. Rewrote `assets/seed_data/targets.json` with `category` enum values + per-row `shape_id` for animal species and special apparatus.
2. Dropped the legacy `shape` column entirely on disk.
3. Replaced predicates in `range_day_detail_screen.dart` and dispatch in `target_plot.dart` with the closed-set switch shown above.
4. Bumped schema v38 → v39 and re-ran `dart run build_runner build`.

See `lib/database/database.dart` `onUpgrade` step `if (from < 39)` for the migration SQL.

### Target rack schema (canonical design — shipped in Phase 9.5 Group C, v40)

Racks are ordered arrangements of targets — KYL drills, equal-size plate racks, popper banks, mixed-shape stages. The naive model (hardcoded rack-type enum: "5-Plate KYL," "5-Plate Equal Rack," etc.) has the same brittleness as the old `shape` field: every new rack configuration needs a new enum entry, and natural variations like "KYL with squares instead of circles" or "mixed shapes" don't fit cleanly.

**On-disk model (shipped):** one `TargetRacks` row per rack, with each rack's children encoded inline on a single JSON column (`slotsJson`) via the drift `TypeConverter` `RackSlotsConverter` in [`lib/database/rack_slot.dart`](lib/database/rack_slot.dart). Callers see a typed `List<RackSlot>`; the converter handles the JSON round-trip and defensive sort. The legacy v19 `TargetRackChildren` FK child table is dropped.

```
TargetRack (drift Table)
  id:               int autoincrement
  name:             text (required, shown in picker)
  description:      text?
  rackKind:         text   ('hanging_rail' | 'standing_stakes' | 'popper_base'
                            | 'individual_posts' | 'rotating_hub' | …)
  totalWidthIn:     real
  totalHeightIn:    real
  notes:            text?
  slotsJson:        text   ← typed as `List<RackSlot>` via RackSlotsConverter

RackSlot (lib/database/rack_slot.dart — immutable value type)
  position:         int     (natural sort key)
  name:             string  (slot label inside the rack)
  category:         enum    ('circle' | 'square' | 'rectangle' | 'ipsc'
                            | 'animal' | 'special') — same as target catalog
  shapeId:          string? (per category: species for animal, apparatus
                            type for special)
  widthIn / heightIn: real  (physical dimensions)
  offsetXIn / offsetYIn: real (position relative to rack anchor)
  colorHex:         string? (optional override; defaults from category)
```

A slot is a strict subset of a target catalog row — same `category` enum, same `shape_id` semantics, same physical-dimension model. The rack painter renders each slot using the same per-target painter logic that handles solo targets, just iterated across the rack.

The converter's `fromSql` sorts defensively by `position` and returns an unmodifiable list, so cached reference-data rack rows can't be mutated mid-paint. See CLAUDE.md § 32.2 for the broader "RackSlot + TypeConverter" pattern for any future structured-but-bounded child collection.

### Why this design absorbs every rack variant we anticipate

| Rack | Slots |
|---|---|
| 5-Plate KYL (Circles, 12→2 in) | circle 12, circle 8, circle 6, circle 4, circle 2 |
| 5-Plate KYL (Squares, 12→2 in) | square 12, square 8, square 6, square 4, square 2 |
| 5 Equal Circles (6 in) | circle 6 × 5 |
| 5 Equal Squares (4 in) | square 4 × 5 |
| Mixed KYL (alternating shapes) | circle 12, square 8, circle 6, square 4, circle 2 |
| 5-Popper Rack | special:pepper_popper × 5 |
| Animal silhouette stage | animal:deer, animal:elk, animal:bear, animal:coyote, animal:fox |
| IPSC 3-target stage | ipsc:18×30 × 3 |

One schema, every configuration. Adding a new arrangement is one JSON object in the seed file — no schema bump, no painter case, no chip-predicate update.

### Seed rack catalog

Ship ~10-15 curated common configurations in `assets/seed_data/target_racks.json`. Names are operator-defined and read naturally in the picker:

- 5-Plate KYL (Circles, 12→2 in)
- 5-Plate KYL (Squares, 12→2 in)
- 5 Equal Circles (6 in)
- 5 Equal Circles (4 in)
- 5 Equal Squares (4 in)
- 3-Plate Decreasing (Circles, 12→6 in)
- 5-Popper Rack
- IPSC Stage (3 silhouettes)
- IDPA Open Stage

The exact starter list is curated separately during the migration.

### User-defined racks (future)

There is **no** `UserRacks` drift table today. Range Day's "build my own rack" flow is not yet wired; the existing `TargetRacks` reference catalog covers every shipped rack. The eventual user-rack path is on the Phase Two backlog and would reuse the same `slotsJson` shape so the painter doesn't need to learn a second data model.

### Migration (shipped in Phase 9.5 Group A + C — v38 → v40)

The two rack-related migrations rode together since both touch overlapping code paths (catalog seed, picker, painter):

1. **v38 → v39 (Group A):** rewrote `assets/seed_data/targets.json` with the new `category` taxonomy. Drop+recreate on `Targets`.
2. **v39 → v40 (Group C):** rewrote `assets/seed_data/target_racks.json` in the slots-based format; dropped the v19 `TargetRackChildren` FK child table entirely; introduced `TargetRacks.slotsJson` with `RackSlotsConverter`; updated the rack painter to iterate the typed slot list and delegate to the per-slot painter for each.

See `lib/database/database.dart` `onUpgrade` steps `if (from < 39)` and `if (from < 40)` for the migration SQL. `lib/database/rack_slot.dart` holds the `RackSlot` value type and the `RackSlotsConverter` TypeConverter; the regression suite is `test/rack_slot_converter_test.dart`.

### Tables (overview)

User-data tables (synced; participate in Cloud Sync):
- `UserLoads`, `UserFirearms`, `UserBatches`, `UserBrassLots`
- `UserBallisticProfiles`, `UserRangeDaySessions`
- `UserFavorites` (cartridge / reticle / target favorites)
- `UserComponentFavorites` (powder / bullet / primer / brass favorites)
- `UserCustomFields` + `UserCustomFieldValues` (Pro — see § 19.7; **Pro gate AUDIT-PENDING**)
- `PowderLots`, `PrimerLots`, `BulletLots`, `BrassLots` (per-recipe lot tracking)
- Various custom-component tables

Reference catalog tables (seeded from JSON; not user data):
- `Cartridges`, `Powders`, `Bullets`, `Primers`, `Brass`, `Firearms`, `FirearmParts`
- `Reticles`, `Scopes`, `Targets`, `TargetRacks`
- `ManufacturedAmmo`, `FactoryLoads`
- `RecipeTemplates` (Phase Two Group 1, v41)
- `RecipeStatuses`, `RecipeUseCases` (Phase Two Group 2, v42 — recipe form's Status and Use Case dropdowns; each row is a `(value, label)` pair where `value` is the enum-style key persisted on `UserLoads.status` / `UserLoads.useCase` and `label` is the dropdown display string)

For the per-column detail on `UserLoads` (the recipes table), see § 19.2.

---

## 5. Seed data + live catalog updates

The reference catalog ships as JSON in `assets/seed_data/` and seeds into SQLite on first run. A live update mechanism allows shipping JSON corrections without a store release.

### First-run seeding

`lib/database/seed_loader.dart`'s `seedIfNeeded()` walks the manifest at app startup, reading `assets/seed_data/*.json` and writing into SQLite.

### Live updates (Firebase Storage)

Pulls on cold start from `gs://loadout-precision-reloading.firebasestorage.app/seed_data/`. See `lib/services/seed_updater.dart`. Compares the bucket's `manifest.json` to the bundled one; if a category has a higher version, downloads the updated JSON and re-seeds.

### Seed data is the source of truth

Edits should always go to `assets/seed_data/` first, then be uploaded to the bucket. Never edit in place in the bucket.

### Current manifest

| Manifest version | files.targets.version | When |
|---|---|---|
| 16 | 10 | Post-Phase-9.8 + Phase-One Recipes (current — 2026-05-15) |

---

## 6. Authentication

### Supported providers

7 sign-in methods, all configured in Firebase Authentication:

1. Email / password
2. Email link (passwordless)
3. Anonymous (Continue as Guest)
4. Google
5. Apple
6. Microsoft (Azure AD)
7. Yahoo

### Adding a new auth provider

1. In the provider's portal (Microsoft Azure AD / Yahoo / etc.), register a web app with redirect URL `https://loadout-precision-reloading.firebaseapp.com/__/auth/handler`.
2. Get OAuth client ID + secret.
3. POST to Identity Platform admin API:

```sh
TOKEN=$(gcloud auth print-access-token)
curl -X POST \
  "https://identitytoolkit.googleapis.com/admin/v2/projects/loadout-precision-reloading/defaultSupportedIdpConfigs?idpId=<provider>.com" \
  -H "Authorization: Bearer $TOKEN" \
  -H "x-goog-user-project: loadout-precision-reloading" \
  -H "Content-Type: application/json" \
  -d '{"enabled": true, "clientId": "...", "clientSecret": "..."}'
```

4. Add a "Continue with X" button to `LoginScreen`. Use `_auth.signInWithProvider(<Provider>AuthProvider())` for the OAuth-popup flow, or a native package if one exists.

### Apple Sign-In specifics

- Service ID + Key required. `.p8` private key must be stored securely (1Password or similar) — Apple `.p8` files cannot be re-downloaded.
- JWT client_secret must be regenerated every **180 days**. Calendar reminder for ~mid-October 2026.
- Re-issue under the new org Team ID after personal-to-org Apple Developer conversion.

### First-launch session clear

Firebase Auth's iOS refresh token persists in the system Keychain across app uninstalls. On the very first launch on a given install (detected via `app_launched_before` SharedPreferences flag), `main.dart` calls `FirebaseAuth.instance.signOut()`. Flag is set BEFORE the sign-out to avoid loop-on-crash.

---

## 7. Cloud Sync internals

### Encryption

| Layer | Specification |
|---|---|
| Content cipher | AES-256-GCM |
| Key derivation | PBKDF2 with 200,000 iterations |
| Passphrase source | User-chosen, never persisted off-device |
| Blob destination | User's own iCloud Drive / Google Drive / OneDrive container |
| LoadOut backend involvement | None — the encrypted blob is between the user's device and their cloud provider |

### Sync cadence

| Mode | Cadence |
|---|---|
| Cloud Backup (manual) | One-shot on user tap "Backup now" |
| Cloud Sync (continuous) | Auto-syncs ~5 seconds after each AutoSave fires (debounced) + on app launch + on manual "Sync Now" tap |

### Conflict resolution

**Last-writer-wins by row `updatedAt`.** Tables without `updatedAt` fall back to `createdAt`. If neither has a clock, remote wins (preserves manual-restore semantics).

### Failure modes

| Failure | Behavior |
|---|---|
| Decryption fails (wrong passphrase) | Local DB untouched. UI surfaces "passphrase needed" status. |
| Schema-version mismatch (incoming > local) | Rejected. User is told to update the app on this device. |
| Network error | Retry on next AutoSave tick. AppBar indicator dot reflects state. |

### Source files

- `lib/services/backup_crypto.dart` — encryption primitives (HARD FENCE)
- `lib/services/cloud_backup_service.dart` — manual one-shot (HARD FENCE)
- `lib/services/cloud_sync_service.dart` — continuous sync
- `lib/services/icloud_backup_service.dart` / `lib/services/google_drive_backup_service.dart` / `lib/services/onedrive_backup_service.dart` — provider adapters

---

## 8. AI Smart Import internals

### Overview

The only Anthropic-using surface in the app today. **AI Smart Import is implemented as an inline overlay card (`_ImproveWithAiCard`) inside `photo_import_review_screen.dart` — it is not a standalone screen.** Translation tool for OCR cleanup. Pro, opt-in per use.

> **Naming clarification.** The file `lib/screens/recipes/spreadsheet_import_screen.dart` (formerly `smart_import_screen.dart`, renamed in Phase One Group 2 on 2026-05-14) is the **spreadsheet** column-mapping wizard, not the AI feature. The two have nothing in common architecturally; only the old filename suggested a relationship. "AI Smart Import" refers exclusively to the photo-review overlay (`_ImproveWithAiCard`); "Spreadsheet Import" refers to the CSV/XLSX flow.

### When the card renders

The `_ImproveWithAiCard` only appears when all three are true:

1. The master Settings → AI toggle is on (`kAiSmartImportEnabledPrefKey`).
2. Either the user is Pro and the proxy is configured (`!AiSmartImportConfig.isPlaceholder`), OR a BYOK key is present in `flutter_secure_storage` keyed `byok_anthropic_key`.
3. At least one parsed field has confidence below 0.6 — no point bothering AI for a clean parse.

When the user taps "Improve with AI," the call routes through `AiSmartImportService.improveDraft(ocrText, initialDraft)`. The returned `RecipeDraft` is merged into the form, but only for fields the user hasn't manually edited (tracked via `_editedFields`).

### Architecture

Two execution modes:

| Mode | Path |
|---|---|
| **Hosted** (default for Pro users) | Request → Cloudflare Worker proxy at `anthropic-proxy.loadout-precision-reloading.workers.dev` (with user's Firebase ID token) → Anthropic API |
| **BYOK** (bring-your-own-key) | Request → directly to `api.anthropic.com` with user's pasted Anthropic key (stored in `flutter_secure_storage` keyed `byok_anthropic_key`); skips proxy and cap. Free users with BYOK can use the feature too. |

### Per-Pro-user monthly cap

**20 imports per Pro user per calendar month**, set by `MONTHLY_CAP` in `cloud_worker/anthropic-proxy/src/quota.ts:43` (lowered from 30 on 2026-05-08). BYOK users bypass the cap.

### What the Worker logs

- Timestamp
- Short UID prefix (4 chars)
- HTTP status code
- Latency
- Anthropic token counts (input + output)

**Never the request body.** Anthropic's API terms forbid training on API requests; verify before each renewal.

### What the request body contains

- OCR'd text from the photo (output of on-device ML Kit)
- On-device parser's draft (structured recipe shape with confidence flags)
- Optional reference-catalog hints (e.g. "user's nearby powders are H4350, Varget")

**Never:** saved recipes, firearms, brass lots, batches, ballistic profiles, custom fields, or anything else from the on-device DB.

### Default state

OFF in Settings → AI. User has to flip a master toggle AND tap "Improve with AI" per-import.

---

## 9. RevenueCat + Pro entitlement

### Product IDs

| Product | Type | Price |
|---|---|---|
| `loadout_pro_yearly` | Auto-renewing subscription | $39.99 / yr |
| `loadout_pro_lifetime` | Non-consumable | $79.99 once |

Single entitlement: `pro`.

### Cross-platform sync

Pro entitlement is linked to Firebase Auth UID at sign-in. A user who buys on iOS sees Pro on Android with the same account. RevenueCat handles the linking; client-side check via `Purchases.getCustomerInfo()`.

### Source files

- `lib/services/purchases_service.dart` — RevenueCat wrapper (HARD FENCE)
- `lib/services/revenue_cat_config.dart` — keys (HARD FENCE — never commit real values to a public repo)
- `lib/services/pro_gate.dart` — `ProGate` widget for feature-level gating

### Pro features (canonical list)

Per Marketing.md § 3:

- Cloud Sync (continuous, encrypted)
- Cloud Backup (manual, encrypted)
- Hornady 4DOF / custom drag curves
- Bluetooth devices (Kestrel 5xxx Link, Garmin Xero, 5 BLE rangefinders)
- Scope View Pro + training mode
- Moving Target Lead
- Live weather pull (ballistics + firearm zero)
- GPS altitude (Range Day)
- AI Smart Import (the overlay card — see § 8)
- AI Reloading Assistant (Coming Soon)
- Load Development (OCW, Audette Ladder, Satterlee, ladders)
- Internal Ballistics Calculator (Powley)
- Custom Fields (unlimited) — **gate posture AUDIT-PENDING for recipes; see § 19.7**

The Pro entitlement check is `context.watch<EntitlementNotifier>().isPro`. Gating widgets use `ProGate` or call `await ensurePro(context)` before pushing a Pro route.

---

## 10. File layout

```
lib/
  main.dart                  Firebase init + DB open + seed + runApp
  app.dart                   Providers + auth gate + deep-link listener
  firebase_options.dart      Generated by `flutterfire configure`
  database/
    database.dart            Drift schema + AppDatabase
    database.g.dart          Generated — do not edit
    seed_loader.dart         First-run JSON → SQLite
  data/
    # Phase Two Group 1 (v41, 2026-05-15) deleted lib/data/recipe_templates.dart.
    # Templates now seeded from assets/seed_data/recipe_templates.json into the
    # RecipeTemplates drift table; the model lives at lib/models/recipe_template.dart.
  repositories/              ComponentRepository, RecipeRepository,
                             FirearmRepository, FavoritesRepository
  services/
    auth_service.dart                 HARD FENCE
    backup_crypto.dart                HARD FENCE
    biometric_service.dart            HARD FENCE
    cloud_backup_service.dart         HARD FENCE
    cloud_sync_service.dart
    purchases_service.dart            HARD FENCE
    revenue_cat_config.dart           HARD FENCE
    onedrive_config.dart              HARD FENCE
    ai_smart_import_service.dart
    ai_smart_import_config.dart       HARD FENCE
    auto_save_service.dart
    beginner_mode_service.dart
    component_favorites_service.dart
    photo_import_service.dart
    recipe_parser.dart
    recipe_pdf_service.dart
    recipe_print_service.dart
    recipe_qr_service.dart
    seed_updater.dart
    spreadsheet_import_service.dart   Spreadsheet preview / mapping / import
    unit_service.dart
    weather_service.dart
    ble/                              BLE adapters per device
      garmin_xero_service.dart        Garmin .fit import (Pro)
  screens/
    auth/login_screen.dart
    home/home_screen.dart             5-tab bottom-nav shell
    recipes/                          See § 19.1 for the full recipe-surface inventory
      recipes_list_screen.dart
      recipe_form_screen.dart
      quick_add_recipe_screen.dart
      spreadsheet_import_screen.dart         CSV / XLSX wizard (renamed from smart_import_screen.dart in Phase One Group 2)
      photo_import_screen.dart
      photo_import_review_screen.dart
      multi_page_import_review_screen.dart
      recipe_qr_scan_screen.dart
      recipe_import_landing_screen.dart      Canonical "Import a Recipe" entry point (Phase One Group 5)
      recipe_import_source.dart              RecipeImportSourceKind enum + extension detection helper (Phase One Group 5)
    firearms/, batches/, ballistics/, range_day/
    glossary/, saami/, paywall/
    settings/, sync/, disclaimers/
    load_development/
  widgets/
    animal_silhouettes.dart           Animal SVG loader + parser
    target_silhouettes.dart           Parallel parser (IPSC + poppers)
    component_field.dart              Autocomplete picker for catalog kinds
    glossary_label.dart
    pro_gate.dart
    auto_save_banner.dart
    auto_save_first_time_hint.dart
    empty_state_card.dart
    favorite_star_button.dart
    import_options_section.dart       Thin shim with a single "Import a Recipe" tile that pushes recipe_import_landing_screen (Phase One Group 5). Kept the AI Smart Import settings deep-link tile + cloud-restore tiles untouched — those are separate concepts from per-recipe import.
    lookup_loads_sheet.dart
    primer_cascade_field.dart
    quick_add_fab_stack.dart
    recipe_qr_share_sheet.dart
    range_day_safety.dart             (safeAsync helper)
    unsaved_changes_dispatcher.dart
  models/
    target_center_point.dart
  utils/
    natural_sort.dart
    responsive.dart
  theme/app_theme.dart

assets/seed_data/                     Bundled reference catalog (JSON)
assets/silhouettes/animals/*.svg
assets/silhouettes/targets/*.svg
public/                               Firebase Hosting source (AASA + assetlinks)
ios/Runner/Runner.entitlements
ios/RunnerWatchApp/                   Apple Watch scaffold
android/app/src/main/AndroidManifest.xml
android/wear/                         Wear OS scaffold
cloud_worker/anthropic-proxy/         Cloudflare Worker source

CLAUDE.md                             Top-level router
Marketing.md, Engineering.md, Ballistics.md, UI.md
LAUNCH_CHECKLIST.md
PRIVACY_POLICY.md
LOADOUT_PROJECT_HANDOFF.md            Session-restore doc

test/                                 Test suite; count tracked in § 16
```

---

## 11. Build + run commands

```sh
flutter pub get                                    # install deps
dart run build_runner build                        # regen drift code after schema changes
dart run build_runner watch                        # watch mode while editing schema

flutter run                                        # iOS or Android device
flutter analyze                                    # lint
flutter test                                       # run test suite
flutter build ios --debug --no-codesign            # quick iOS compile sanity
flutter build apk --debug                          # quick Android compile sanity

firebase deploy --only hosting                     # update AASA / assetlinks
firebase deploy --only storage                     # deploy storage.rules
gsutil -m cp assets/seed_data/*.json \
  gs://loadout-precision-reloading.firebasestorage.app/seed_data/  # update live catalog
```

### After every commit

| Gate | Expected |
|---|---|
| `flutter analyze` | 6 issues, 0 errors — pre-existing `Matrix4.translate` / `Matrix4.scale` deprecation infos in `animal_silhouettes.dart` (×4) and `target_silhouettes.dart` (×2) |
| `flutter test --exclude-tags=slow` | All passing — current count tracked in § 16. Use `tool/test-fast.sh` for the dev-loop wrapper. |

> **Local-setup gotcha (l10n).** A bare `flutter pub get` does **not** always regenerate the localizations facade (`.dart_tool/flutter_gen/gen_l10n/app_localizations.dart`). If `flutter analyze` reports `Target of URI doesn't exist: 'l10n/app_localizations.dart'` (8 errors clustered in `lib/app.dart`, `onboarding_screen.dart`, `app_preferences_screen.dart`), run `flutter gen-l10n` once. Investigation of the `pub get` → gen-l10n trigger is on the Phase Two queue.

---

## 12. Hard fences (do NOT touch)

Configuration files and services that are off-limits during routine work. Touching them requires explicit operator sign-off.

### Sensitive config

- `lib/services/revenue_cat_config.dart`
- `lib/services/onedrive_config.dart`
- `lib/services/ai_smart_import_config.dart`
- `Info.plist`

### Sensitive services

- `lib/services/backup_crypto.dart`
- `lib/services/purchases_service.dart`
- `lib/services/auth_service.dart`
- `lib/services/biometric_service.dart`
- `lib/services/cloud_backup_service.dart`

### Math-audit boundary

- `lib/services/ballistics/solver.dart`
- `lib/services/ballistics/hit_probability_service.dart`
- `lib/services/ballistics/hit_probability_map_service.dart`

Changes to math files trigger a re-validation against the published Applied Ballistics example tables. Don't touch without an explicit ballistics-work spec.

### Frozen UI

- `_RealisticTargetPainter` (rack-mode painter in `lib/screens/range_day/widgets/target_plot.dart`) — frozen until Phase 11+.

---

## 13. Workflow conventions

### Auto-commit + auto-merge (Workflow Rule v3)

The repo runs auto-commit + auto-merge to `main`. Commits land directly on `main` after passing CI. This is intentional — for a solo-developer / small-team project, it removes PR friction without losing the ability to revert.

The discipline is **halt-and-validate per group**: every logical change gets its own commit so reverts are clean. Don't batch "while I'm in here" cleanups into the same commit.

### Halt-and-validate group convention

Every multi-step phase prompt is structured as a sequence of halt-and-validate groups. Each group:

1. Single logical change.
2. Commit + push to `main`.
3. Report: `flutter analyze` count, `flutter test` count, 1-sentence summary, cold-restart-needed flag.
4. **Operator confirms before next group starts.**

Real, not advisory. Reverts target individual groups.

### Audit cycle (for unknown-territory phases)

1. Chat-Claude writes a first-draft spec tagged AUDIT-PENDING.
2. Operator hands it to Claude Code with the audit prompt (read-only; no commits).
3. Claude Code returns a critique.
4. Operator shares the critique back.
5. Chat-Claude revises.
6. Final spec ships for execution.

Currently in flight: **Scene Painter Phase 10** — visual-style mode toggle for the scene painter (Groups A–C landed: foundation, toggle surfaces, polished rendering scaffold). **Phase One — Recipes: Unified Smart Import + Targeted Cleanup** completed on 2026-05-15 (six halt-and-validate groups; see Phase Two queue at § 19.10 for deferred work). See UI.md § 18 for the longer roadmap.

---

## 14. Firebase + hosting

### Auth providers

All 7 configured (see § 6).

### Hosting (used for AASA / assetlinks)

- `loadout-precision-reloading.web.app` serves AASA at `/.well-known/apple-app-site-association` and assetlinks at `/.well-known/assetlinks.json` for the Universal Links / App Links integration.
- Deploy: `firebase deploy --only hosting`.

### Storage

- Bucket: `gs://loadout-precision-reloading.firebasestorage.app`
- Used for: live catalog updates (`seed_data/*.json`)
- Rules: `read: if true` for `seed_data/*` (so unauthenticated installs can fetch); `write: if request.auth != null` (so only signed-in developers can mutate).
- Deploy rules: `firebase deploy --only storage`

### Firestore (legacy, dormant)

`firestore.rules` and the `(default)` Firestore database are still provisioned but unused. Could be deleted, but kept dormant in case the privacy posture changes. Hosting still uses Firebase, so don't delete the project.

### Crashlytics

Opt-out (default ON). PII redacted by SDK. Fatal crashes only — no non-fatal event reporting.

---

## 15. Companion apps (Apple Watch + Wear OS)

### Current state

- **Apple Watch** — SwiftUI scaffold at `ios/RunnerWatchApp/`. watchOS 10.0+. Bridge: `WatchSessionBridge.swift` activated automatically by `AppDelegate.didInitializeImplicitFlutterEngine`. `WatchConnectivity` channels respond to `isWatchPaired` / `isReachable`.
- **Wear OS** — Compose for Wear OS at `android/wear/`. Wear OS 3 / Android 11+. Bridge: `WatchBridge` instantiation in `MainActivity.configureFlutterEngine` (Google Play Services Wearable Data Layer).

### Manual Xcode wiring still required

For the iOS watch target itself, the manual Xcode wiring documented in this section of `LOADOUT_PROJECT_HANDOFF.md`-style notes is still needed. Specifically: the watch target's bundle ID, signing capability, deployment target, and the Flutter-side dependency on the bridge.

### What's missing

The phone-side code that pushes recipe / DOPE / firearm-glance state into the bridge on every save. Wire protocol is defined; the channels are alive — what's missing is the phone-side senders.

Safer external claim: "companion apps in development; pairing infrastructure live."

---

## 16. Test suite

### Counts

| Gate | State |
|---|---|
| `flutter test --exclude-tags=slow` | **1389 passing + 1 skipped, 0 failed** as of 2026-05-15 (post-Phase-One Recipes). The +45 vs. 2026-05-13 baseline comes from Phase One Groups 3 + 5 (caliber-from-diameter regression suite + recipe-import source-enum suite) plus interleaved Phase 9.8 / Phase 10 work. |
| `flutter analyze` | **6 issues, 0 errors** (pre-existing deprecation infos) |

### Test runner conventions

- `dart_test.yaml` registers a `slow` tag with a 30 s timeout and sets the default timeout to 15 s + concurrency 4.
- Every `testWidgets(...)` call site tags itself `slow`. Unit tests are untagged.
- `tool/test-fast.sh` is the dev-loop wrapper — calls `flutter test --exclude-tags=slow`. Use this in halt-and-validate group reports unless a group specifically touches widget tests.

### Coverage areas

- Solver tests (self-consistency ±0.01 mil, published cross-check ±0.1 mil against Applied Ballistics 4th ed. example tables)
- Repository tests with `NativeDatabase.memory()`
- SVG parser tests (Patterns A–E, including the old complex IPSC SVG fixture)
- Catalog assertions (row counts, unique IDs, naming conventions)
- Cloud sync round-trip tests (encrypt → upload → download → decrypt)
- Recipe parser tests (handwriting alias dictionary, OCR-cleanup heuristics)
- Spreadsheet import service tests (header signature, preset save/load, suggestion mapping)
- Recipe QR service tests (encode + decode, dedupe key)

### Pre-existing infos that we tolerate

- `Matrix4.translate` / `Matrix4.scale` deprecations in `animal_silhouettes.dart` (4) and `target_silhouettes.dart` (2). 6 total. Pre-Phase-1.

---

## 17. Deployment

### Pre-launch checklist

Full list in `LAUNCH_CHECKLIST.md`. Summary:

- Apple Developer enrollment (currently personal; convert to organization before launch — see LAUNCH_CHECKLIST.md § Business / legal setup)
- App Store Connect listing
- Privacy Policy URL + Terms of Service URL
- Sign in with Apple capability (Apple requires it if any other social sign-in is offered)
- Age rating (likely 17+)
- Google Play developer account ($25 one-time)
- Play Console app listing + Data Safety form
- Privacy Policy URL
- Content rating questionnaire

### IAP setup

- RevenueCat project: LoadOut
- App Store Connect: `loadout_pro_yearly` ($39.99/yr) + `loadout_pro_lifetime` ($79.99). Do NOT create `loadout_pro_monthly` ever.
- Google Play: same two SKUs at the same prices.
- RevenueCat dashboard: connect both stores; create `pro` entitlement; attach both products; create `default` offering with yearly + lifetime packages.

### Versioning + release process

TBD — not yet formalized. Likely semver in `pubspec.yaml`.

---

## 18. Reference files (engineering)

- `pubspec.yaml` — dependencies, app version, asset declarations
- `firebase.json` — Firebase project config (hosting, storage rules)
- `firestore.rules` — legacy, dormant
- `storage.rules` — Firebase Storage access for live catalog updates
- `lib/database/database.dart` — drift schema (v40)
- `lib/database/rack_slot.dart` — `RackSlot` value type + `RackSlotsConverter` TypeConverter for `TargetRacks.slotsJson` (Phase 9.5 Group C, v40)
- `lib/database/seed_loader.dart` — first-run seeding
- `lib/services/*` — service layer
- `cloud_worker/anthropic-proxy/` — Cloudflare Worker source
- `ios/Runner/Runner.entitlements` — Sign In with Apple + Associated Domains
- `android/app/src/main/AndroidManifest.xml` — Android intent filter for App Links
- `assets/seed_data/manifest.json` — current manifest version 15
- `LAUNCH_CHECKLIST.md` — pre-launch task tracker

---

## 19. Recipes engineering

This section is the canonical reference for the recipes surface — schema, services, screens, import architecture, autosave, custom fields. Read it before touching `lib/screens/recipes/*` or the related repositories.

The rest of `Engineering.md` covers cross-cutting concerns. § 19 is recipes-specific.

### 19.1 File inventory

The recipes surface lives in `lib/screens/recipes/`:

| File | Role | Status |
|---|---|---|
| `recipes_list_screen.dart` | List + master/detail (wide layouts) + multi-select PDF share + swipe-to-delete | Live |
| `recipe_form_screen.dart` | Full recipe form (Core / Extended / Full detail levels, 10 sections, ~60 fields, autosave, lot pickers, custom fields, share menu, Pro hooks) | Live |
| `quick_add_recipe_screen.dart` | One-screen, notebook-line capture form (recipe name + caliber + powder + charge + bullet + weight + COAL/CBTO + notes) | Live (COAL/CBTO axis toggle landed in Phase One Group 4) |
| `spreadsheet_import_screen.dart` | CSV / XLSX column-mapping wizard | Live (renamed from `smart_import_screen.dart` in Phase One Group 2; class renamed to `SpreadsheetImportScreen`; behavior unchanged) |
| `photo_import_screen.dart` | Camera / gallery capture → ML Kit OCR → `RecipeParser` → review | Live (iOS/Android only) |
| `photo_import_review_screen.dart` | Editable parsed draft with confidence bars; hosts the AI Smart Import overlay card | Live |
| `multi_page_import_review_screen.dart` | Batch photo review — one card per detected entry, discard checkboxes, Save All | Live |
| `recipe_qr_scan_screen.dart` | Fullscreen camera-based QR scanner for LoadOut recipe shares | Live |
| `recipe_import_landing_screen.dart` | **Canonical entry point** for every import source — file-extension routing, see § 19.4 | Live (added in Phase One Group 5) |
| `recipe_import_source.dart` | `RecipeImportSourceKind` enum + `detectKindFromFileExtension` helper | Live (added in Phase One Group 5) |

Supporting widgets (under `lib/widgets/`):

| File | Role | Status |
|---|---|---|
| `component_field.dart` | Autocomplete picker for cartridge / powder / bullet / primer / brass; favorites + frequent + general ordering | Live |
| `import_options_section.dart` | Thin shim with a single "Import a Recipe" tile that pushes `RecipeImportLandingScreen`, plus the AI Smart Import settings deep-link tile and the cloud-restore tiles (iCloud / Drive / OneDrive). The six recipe-import tiles that used to live here folded into the landing screen in Phase One Group 5. | Live |
| `quick_add_fab_stack.dart` | Two-FAB cluster (Quick + Standard) used on the recipes list |
| `glossary_label.dart` | Tappable domain-term wrapper for in-form definitions |
| `auto_save_banner.dart` / `auto_save_first_time_hint.dart` | AppBar-level autosave status indicator + first-time onboarding tooltip |
| `unsaved_changes_dispatcher.dart` | `UnsavedChangesScope` widget — coordinates back-button intercept with autosave controller |
| `primer_cascade_field.dart` | Specialized picker for primer brand → size that supersedes plain `ComponentField` on the primer row |
| `recipe_qr_share_sheet.dart` | Unified share sheet (QR + clipboard + PDF inline) shown from the form's AppBar |
| `pro_gate.dart` | `ProGate` widget + `ensurePro(context)` helper |
| `empty_state_card.dart` | First-run nudge card on empty lists |
| `favorite_star_button.dart` | Compact star toggle used in list rows |

### 19.2 Recipe schema (UserLoads)

The `UserLoads` drift table is the recipes table. Despite the naming asymmetry (table is `UserLoads`; UI vocabulary is "recipes"), there is no migration plan to rename it.

Columns (canonical reference — see `lib/database/database.dart` for the authoritative list):

| Column | Type | Notes |
|---|---|---|
| `id` | int PK | |
| `name` | text | Required at save time; `_runAutoSave` synthesizes a fallback if blank |
| `caliber` | text? | |
| `status` | text? | One of `_statusOptions` |
| `useCase` | text? | One of `_useCaseOptions` |
| `powder` | text? | |
| `powderChargeGr` | real? | |
| `powderLotId` | int? | FK to `PowderLots.id` |
| `chargeToleranceGr` | real? | v4 |
| `powderTempSensitivityFpsPerCelsius` | real? | v15 |
| `powderReferenceTempCelsius` | real | v15 default = 15.6 (60 °F) |
| `primer` | text? | |
| `primerSize` | text? | |
| `primerDepthCps` | real? | |
| `primerLotId` | int? | FK to `PrimerLots.id` |
| `primerSeatingForceLbs` | real? | v4 |
| `bullet` | text? | |
| `bulletWeightGr` | real? | |
| `bulletLotId` | int? | FK to `BulletLots.id` |
| `bulletLengthIn` | real? | v4 |
| `bulletBaseToOgiveIn` | real? | v4 |
| `bulletBearingSurfaceIn` | real? | v4 |
| `bulletMeplatTrimmed` | bool | |
| `bulletPointed` | bool | |
| `bulletWeightSorted` | bool | |
| `bulletWeightToleranceGr` | real? | v4 |
| `bulletBtoSorted` | bool | |
| `bulletBtoToleranceIn` | real? | v4 |
| `bulletDiameterSorted` | bool | |
| `seatingDepthIn` | real? | |
| `cbtoIn` | real? | |
| `brass` | text? | |
| `brassLotId` | int? | FK to `BrassLots.id` |
| `primerPocketSize` | text? | |
| `shoulderBumpIn` | real? | |
| `mandrelSizeIn` | real? | |
| `bushingSizeIn` | real? | |
| `coalIn` | real? | |
| `distanceToLandsIn` | real? | v4 |
| `jumpToLandsIn` | real? | v4 |
| `loadedNeckDiameterIn` | real? | v4 |
| `bulletRunoutTirIn` | real? | v4 |
| `pressureNotes` | text? | |
| `boltLift` | text? | enum-like string |
| `ejectorMarks` | bool | |
| `crateredPrimers` | bool | |
| `webExpansion200In` | real? | |
| `primerFlatness` | int? | 1-5 scale |
| `loadingDate` | datetime? | |
| `dateEstablished` | datetime? | First-saved-on date; survives autosave reissues. Distinct from `createdAt` (which can shift if the row is reimported). |
| `roundsLoadedInBatch` | int? | |
| `pressUsed` | text? | |
| `sizingDieUsed` | text? | |
| `seatingDieUsed` | text? | |
| `scaleUsed` | text? | |
| `scaleCalibrationDate` | datetime? | |
| `comparatorInsertUsed` | text? | |
| `chronographUsed` | text? | |
| `boreState` | text? | |
| `loadedBy` | text? | |
| `notes` | text? | |
| `isFavorite` | bool | Used by `RecipeRepository.watchAll` for favorites-first sort |
| `createdAt` / `updatedAt` | datetime | Cloud Sync conflict resolution uses these |

### Related tables

- `PowderLots`, `PrimerLots`, `BulletLots`, `BrassLots` — per-recipe lot tracking. Created via `_LotPickerField`'s "+ Create New" tile; written via `RecipeRepository.createPowderLot` / etc.
- `UserCustomFields` (definitions) + `UserCustomFieldValues` (values) — Pro custom fields (§ 19.7).
- `UserComponentFavorites` (schema v25) — name-keyed favorites for powder / bullet / primer / brass.
- `UserFavorites` — int row-id keyed favorites for cartridge / reticle / target.

### 19.3 Services consumed by the recipes surface

| Service | Role | Path |
|---|---|---|
| `RecipeRepository` | UserLoads CRUD; lot CRUD; custom-field CRUD; `mostUsedComponentNames(kind)` for picker frequency | `lib/repositories/recipe_repository.dart` |
| `ComponentRepository` | Catalog access (cartridges, powders, bullets, primers, brass); `addCustomComponent`; `componentLabels`; `caliberLabelForBulletDiameter` (Phase One Group 3 — see § 19.9). | `lib/repositories/component_repository.dart` |
| `FavoritesRepository` | Int-row-id favorites (cartridge / reticle / target); stream API for live UI updates | `lib/repositories/favorites_repository.dart` |
| `ComponentFavoritesService` | Name-keyed favorites for powder / bullet / primer / brass | `lib/services/component_favorites_service.dart` |
| `AutoSaveService` + `AutoSaveController` | Frequency policies, dirty tracking, debounced save; controller per form instance | `lib/services/auto_save_service.dart` |
| `BeginnerModeService` | Master toggle for in-form beginner tooltips and glossary shortcut | `lib/services/beginner_mode_service.dart` |
| `RecipeParser` | OCR-text → `RecipeDraft` heuristic parser; handwriting alias dictionary (444 entries) | `lib/services/recipe_parser.dart` |
| `PhotoImportService` | Image capture wrapper + ML Kit text recognizer lifecycle | `lib/services/photo_import_service.dart` |
| `SpreadsheetImportService` | CSV/XLSX preview, header signature, mapping presets, row import | `lib/services/spreadsheet_import_service.dart` |
| `RecipeQrService` | Encode + decode of the `LO1:` magic-prefix share string; `dedupeKey()` for local dedupe | `lib/services/recipe_qr_service.dart` |
| `RecipePdfService` | Polished single-recipe PDF + multi-recipe batch PDF | `lib/services/recipe_pdf_service.dart` |
| `RecipePrintService` | Plain-text recipe export (copy-pastable) | `lib/services/recipe_print_service.dart` |
| `AiSmartImportService` | Anthropic call (hosted via Worker proxy or BYOK direct); see § 8 | `lib/services/ai_smart_import_service.dart` |
| `GarminXeroService` | `.fit` file parse; velocity stats (avg / ES / SD) | `lib/services/ble/garmin_xero_service.dart` |
| `UnitService` | Display-unit toggling (label-only — canonical storage stays imperial) | `lib/services/unit_service.dart` |
| `CloudSyncService` | `scheduleSyncUp()` called from autosave success path; see § 7 | `lib/services/cloud_sync_service.dart` |

### 19.4 Import architecture

The recipes surface supports many import sources, all reached through a single canonical entry point: `RecipeImportLandingScreen` (added in Phase One Group 5 on 2026-05-14). The user picks the SOURCE; the screen detects the source kind from the input (file extension for the file picker, OS API for photos, content shape for paste) and routes to the existing per-source flow. Per-source flows did not change — the landing screen is a router.

### Source taxonomy

| Kind (`RecipeImportSourceKind`) | Triggered by | Routes to | Status |
|---|---|---|---|
| `spreadsheet` | File picker, `.csv` / `.xlsx` / `.xls` | `SpreadsheetImportScreen` | Live via Recipe Import Landing |
| `photoSingle` | "Take a Photo" or "Pick From Gallery" tile | `PhotoImportScreen` → `PhotoImportReviewScreen` | Live via Recipe Import Landing (iOS/Android only) |
| `photoMultiPage` | Multi-page batch gallery pick | Multi-page capture → `MultiPageImportReviewScreen` | Live via Recipe Import Landing (iOS/Android only) |
| `loadoutJson` | File picker, `.json` | LoadOut JSON re-import handler (`LoadoutFileImportService.importFromJson` reading the picked file's contents) | Live via Recipe Import Landing |
| `qrCode` | "Scan a Recipe QR" tile | `RecipeQrScanScreen` | Live via Recipe Import Landing |
| `clipboard` | "Paste From Clipboard" tile | Materialize text to temp `.csv`, push `SpreadsheetImportScreen(initialFile:)` | Live via Recipe Import Landing |
| `garminFit` | File picker, `.fit` (Pro) | Today: informational SnackBar pointing at the recipe form's Pro Tools section. The recipe form's inline `_onImportGarminFit` handler is heavily entangled with form state (notes / chronograph / autosave wiring); extracting it to a context-free service for landing-screen invocation is a Phase Two task. | Live on the recipe form; landing-screen route deferred to Phase Two |
| `msWordDoc` | File picker, `.docx` / `.doc` | — | **Coming Soon** (Phase Two) |
| `msOneNote` | File picker, `.one` | — | **Coming Soon** (Phase Two; realistic path = OneNote export to `.docx` first) |
| `garminXeroPhoto` | Photo of Xero display (OCR vs `.fit`) | — | **Coming Soon** (Phase Two) |

### Detection helper

`detectKindFromFileExtension(filename)` (in `recipe_import_source.dart`) maps a filename to a `RecipeImportSourceKind` based on the extension only. Case-insensitive. Returns `null` for unsupported extensions; callers surface "Unsupported file type" via snackbar.

Photos do **not** route through the file extension helper — they route through the dedicated photo-picker path in `PhotoImportScreen`. This split exists because photos arrive from a different OS API (`image_picker`) than files.

### Landing screen UX (engineering view; UI chat owns copy/styling)

```
┌─────────────────────────────────────┐
│ Import a Recipe              [X]    │
├─────────────────────────────────────┤
│  Bring a recipe in from anywhere    │
│                                     │
│  📷 Take a photo                    │  ← iOS/Android only
│  🖼  Pick from gallery               │  ← iOS/Android only
│  📂 Choose a file                   │
│     CSV · Excel · LoadOut JSON      │
│     · Garmin .fit (Pro)             │
│  📋 Paste from clipboard            │
│  📷 Scan a recipe QR                │
│                                     │
│  Coming soon                        │
│   · Microsoft Word document         │
│   · Microsoft OneNote               │
│   · Garmin Xero chronograph photo   │
└─────────────────────────────────────┘
```

Behaviors:

- Photo tiles are **hidden** when `PhotoImportScreen.isSupportedPlatform` is false (macOS, web). Photo capture doesn't ship on those platforms today.
- Garmin .fit appears under "Choose a file" only when `EntitlementNotifier.isPro` is true. Non-Pro users picking a `.fit` see the standard Pro paywall.
- Coming Soon tiles render as visible-but-disabled `ListTile`s. Discoverability beats surprise.

### Per-source flow notes

**Spreadsheet** — six-step state machine (`pickFile` → `preview` → `mapping` → `summary` → `importing` → `done`). Mappings are persisted under a SHA-based file-shape signature, so re-importing a similarly-shaped file auto-applies the prior mapping. Named presets (`ImportMappingPreset`) let the user save and re-apply mappings by name.

**Photo single** — `PhotoImportService.captureAndRecognize(source)` runs ML Kit text recognition on-device. The first call downloads the OCR model (~30 MB on-device, no network). The result is `RecipeDraft` with per-field confidence values; `PhotoImportReviewScreen` renders confidence bars (≥0.75 green, 0.5–0.75 amber, <0.5 red) under each field. The AI Smart Import overlay card renders only when conditions in § 8 are met.

**Photo multi-page** — same OCR pipeline as single, but the capture screen segments each page into recipe entries using whitespace-gap heuristics. The review screen renders one `_EntryCard` per detected entry with discard checkboxes; Save All inserts every non-discarded card. AI Smart Import is not yet wired here (Phase Two opportunity).

**LoadOut JSON re-import** — full-fidelity restore of a previous in-app local export. Bypasses the parser (the JSON already has structured fields).

**QR code** — fullscreen `mobile_scanner` camera preview. Fast-rejects payloads without the `LO1:` magic prefix. Decodes via `RecipeQrService.decodeShareString`, dedupes against local rows by `(name, cartridge, powder, charge)`, inserts via `RecipeRepository.insert`. Returns a `RecipeQrScanResult` on success.

**Clipboard** — text content is materialized into a temp `.csv` file and routed through the spreadsheet wizard. Empty clipboard surfaces a snackbar without routing.

**Garmin .fit** — `GarminXeroService.importFitFile(path)` parses the binary FIT file, computes average / ES / SD across shot velocities, and surfaces a summary the user can drop into a recipe's notes. Pro-gated. Lives on the recipe form's Pro Tools section (`_onImportGarminFit`); the landing-screen tile shows an informational SnackBar pointing the user there. Extracting the form-side handler into a context-free service for landing-screen invocation is a Phase Two task (the handler today is tightly coupled to the recipe form's `_notes` / `_chronographUsed` controllers and the autosave dirty-flag wiring).

### 19.5 Recipe form (`recipe_form_screen.dart`)

The recipe form is data-driven via three core types:

- **`_FieldId`** — enum with one value per visible field. Stable key for filter matching, section membership, widget keys.
- **`_FieldDef`** — declarative metadata for one field: id, label, minimum `DetailLevel`, alias tokens (for filter search), beginner tooltip, builder closure.
- **`_Section`** — collapsible section: id, title, ordered `fieldIds`, optional `pairs` (2-up rendering on desktop widths ≥1024 px).

Adding a new field is a three-touch operation: append to `_FieldId`, add a `_FieldDef` inside `_buildFieldDefs`, add the id to a section's `fieldIds`.

### Detail levels

`DetailLevel.basic` / `.detailed` / `.all` — UI labels are Core / Extended / Full (the segmented button in the sticky header). Levels are nested: basic ⊂ detailed ⊂ all. SharedPreferences key `recipe_form_detail_level` (legacy enum values retained for back-compat).

Switching levels triggers `_scrollToSection(_lastExpandedSectionId)` — the form auto-scrolls back to whichever section the user was working in. The `_lastExpandedSectionId` state tracks user intent via `ExpansionTile.onExpansionChanged`. Section `GlobalKey`s are allocated once in `initState`.

### Filter

The search field above the sections is token-based: every whitespace-separated token in the query must appear (case-insensitively) in either the field's label or one of its aliases. The Notes field is always visible regardless of detail level when no filter is active. A matching field surfaces even if its declared level is higher than the active toggle.

### Save paths

Two paths today:

- **`_runAutoSave`** — the `AutoSaveController.onSave` callback. Builds a companion, decides insert vs update by `_autoSave.currentRowId`, also writes custom-field values.
- **`_save({popAfter})`** — the manual Save / Done handler. Wraps `_autoSave.forceSave()` so the same canonical path runs and the row id round-trips back into the controller.

The two paths are kept in lockstep by routing both through `_autoSave.forceSave()`. **AUDIT-PENDING (Phase Two item #10)** — consolidating to one path is on the queue.

### Share menu

The form's AppBar share button is a `PopupMenuButton<_RecipeShareFormat>` with three actions:

- **Share via QR** — unified share sheet (`showRecipeQrShareSheet`) exposing QR + clipboard + PDF inline
- **Share as PDF** — direct `RecipePdfService.share`
- **Share as text** — `RecipePrintService.share`

Visible only after the recipe has been saved at least once (a draft has no id to share). Pending autosave flushes before the artifact is generated so what ships matches what's on screen.

### Pro hooks

- **Garmin .fit import** — `OutlinedButton` near the bottom of the form, `_onImportGarminFit`. Routes through `ensurePro(context)`.
- **Run Load Development** — only renders on existing recipes (`widget.existing != null`). Routes through `ensurePro(context)` to push `NewMethodTestScreen(preselectedSourceRecipeId: id)`.

### Lot pickers

`_LotPickerField<T>` is a typed wrapper around `DropdownButtonFormField<int>` with a "+ Create New" sentinel value (`_createNewSentinel = -1`). The `onChanged` handler short-circuits on the sentinel and calls `onCreate()` instead of propagating -1 to the parent.

Four lot kinds: powder, primer, bullet, brass. Each has its own future (`_powderLotsFuture` etc.) loaded in `initState` and replaced when the user creates a new lot.

### 19.6 Autosave

`AutoSaveController` wraps an `AutoSaveService`. The service holds the global frequency policy (Off / After Any Change / Every 1/5/10 Minutes). The controller is per-form-instance.

Wiring (in `recipe_form_screen.dart` `initState`):

1. `_autoSave = AutoSaveController(service:, onSave: _runAutoSave, initialSavedRowId: widget.existing?.id, onSavedToCloud: () => cloudSync.scheduleSyncUp())`.
2. Every text controller has `c.addListener(_autoSave.notifyDirty)`.
3. Discrete-state changes (dropdowns, checkboxes, dates) call `_autoSave.notifyDirty()` from their `onChanged`.

Visible surfaces:

- `AutoSaveBanner(controller:)` — AppBar status indicator (saved / saving / error).
- `AutoSaveFirstTimeHint` — first-launch tooltip explaining the autosave model.
- `UnsavedChangesScope(controller:)` — back-button intercept that prompts Save / Discard / Cancel when autosave is Off and there are unsaved changes.

When autosave is **Off**, the form renders a Save + Done pair at the bottom. When autosave is **on at any frequency**, only Done renders (saves already happen in the background; Done just pops).

### 19.7 Custom fields

Per Marketing.md § 3, custom fields are a Pro feature ("unlimited per recipe / firearm / batch"). The schema supports them generally; the recipe form is the first surface to expose them.

> **AUDIT-PENDING (Phase Two item #2).** Marketing.md says Pro. `_buildCustomFieldsSection` in `recipe_form_screen.dart` shows no visible Pro gate. Either the code is missing the gate (launch blocker) or the gate is somewhere the audit missed. Phase Two confirms or fixes — likely via `ProGate` wrapping the "+ Add Field" affordance plus a policy decision for non-Pro users editing existing custom-field values.

### Tables

- **`UserCustomFields`** — definitions (id, entity scope ('recipe' / 'firearm' / 'batch'), display name, editor type, optional unit suffix).
- **`UserCustomFieldValues`** — values (recipe id, field id, value text). Single value column; serialization per editor type.

### Editor types

| Type | UI | Serialization |
|---|---|---|
| `text` | `TextFormField` | Raw text |
| `number` | `TextFormField` with `keyboardType: number` and optional unit suffix | Raw text; parsed at read time |
| `boolean` | `Switch` | `'true'` / `'false'` |
| `date` | `_DateField` (date picker) | ISO-8601 |

Adding a fifth editor type requires two touches: the editor render path in `_buildCustomFieldEditor` AND the save loop in `_runAutoSave` (the controller-collection-to-value-map path).

### Lifecycle

- Field list is loaded via `RecipeRepository.customFieldsForEntity('recipe')` as a `Future` in `initState`.
- Per-field controllers are lazily constructed via `putIfAbsent` on `_customControllers` — no allocation for unused fields.
- Values are loaded for an edit via `_loadCustomValues(repo, existingId)`.
- "+ Add Field" opens `_showAddCustomFieldDialog`, which inserts into `UserCustomFields` and refreshes the future.
- Controllers dispose in the form's `dispose` alongside the standard set.

### 19.8 Quick Add (`quick_add_recipe_screen.dart`)

One-screen, no-section, notebook-line capture form. Captures the fields a reloader writes in their notebook:

1. Recipe Name (optional — `_generateName` synthesizes one at save)
2. Caliber
3. Powder + charge (gr)
4. Bullet + weight (gr)
5. COAL or CBTO axis toggle + a single dimension field (Phase One Group 4 — `_DimensionAxis` enum + `_dimension` controller; save routes to `coalIn` xor `cbtoIn` based on the selected axis; templates with a `coalIn` value force axis = COAL, templates with `cbtoIn` only force axis = CBTO).
6. Notes

Plus a "Start from a template" picker that pre-fills all five fields with a published-data starting load.

### Templates

Templates ship in `assets/seed_data/recipe_templates.json` and seed into the `RecipeTemplates` drift table on first run via `SeedLoader._seedRecipeTemplates()`. The Quick Add picker reads them via `RecipeRepository.allTemplates()` (typed `List<RecipeTemplate>` from `lib/models/recipe_template.dart`). Phase Two Group 1 (2026-05-15, schema v41, manifest v17) moved them out of the retired `lib/data/recipe_templates.dart` static const list so they ride the manifest-versioned live update pipeline (§ 5) — corrections and additions ship without an App Store push.

Each template carries a `recommendedDetailLevel` annotation (`quick` / `core` / `extended` / `full`). Today's five shipping templates are all `quick` (load-defining fields only — caliber + powder + charge + bullet + weight + COAL/CBTO + notes). The `templatesByDetailLevel(...)` repository method lets future pickers filter by the form's mode after Phase Three's Quick → Regular bridge redesign.

The template disclaimer banner (`RecipeTemplate.disclaimer` static const) is always shown — published starting loads are reference points, not recommendations. The string lives on the model class rather than as a top-level const so we can specialise per-template later if subsonic or other categories need different wording.

### Quick → Regular bridge

Today, "Switch to Regular" follows one of two paths:

- **No name** → push `RecipeFormScreen(initialDraft: companion)` with the partial draft. Treated as a brand-new unsaved row.
- **Has name** → persist first, then push `RecipeFormScreen(existing: row)` via `pushReplacement`. Treated as an existing edit.

The two paths exist because the regular form's autosave-vs-manual-save semantics depend on whether `widget.existing` is set. **AUDIT-PENDING (Phase Two item #1)** — three candidate redesigns are on deck:

- **A.** Always persist on Switch (autosave-style). Single path. Drawback: a user tapping Switch by mistake creates a row.
- **B.** Always treat as draft. Lose less state on back-from-Switch. Drawback: form's first-save semantics get more complex.
- **C.** Collapse Quick and Regular into one form with a `mode` flag. Quick = Core detail level + some sections collapsed. Eliminates the bridge entirely. Biggest refactor; cleanest end state.

Operator picks the path in Phase Two.

### 19.9 Caliber-from-diameter mapping

When the user picks a bullet from the autocomplete on the recipe form, the form back-fills the caliber field by mapping the bullet's diameter to a colloquial caliber label.

The canonical method is `ComponentRepository.caliberLabelForBulletDiameter(double diameterIn)` (Phase One Group 3 — 2026-05-14). Iterates `_kCaliberFamiliesByDiameter` (a 14-entry `final Map<double, String>` at `lib/repositories/component_repository.dart` file level), returns the entry with the smallest residual diameter within ±0.0015 inches tolerance, returns null when no entry matches.

The map is `final`, not `const`, because Dart bans `const Map<double, _>` (double overrides `==` / `hashCode` for NaN + signed-zero semantics). The signature is `Future<String?>` even though the body is synchronous, so call sites stay forward-compatible with a future catalog-backed implementation. The map is inherently a separate dataset from the cartridge catalog (four entries — `6mm` / `6.5mm` / `7mm` / `9mm` — are metric family labels that don't appear as standalone cartridge names; several imperial entries have leading-token collisions with cartridge names like `.25-06` vs `.257`), so a leading-token-from-name extraction over the catalog would be too brittle.

A `// TODO(phase-2): move to assets/seed_data/caliber_families.json` comment on the map marks the eventual move to the live-update pipeline (§ 5). The regression suite is `test/component_repository_caliber_test.dart` — 24 tests including 16 round-trip assertions, 4 boundary checks, tolerance / null / negative defensives, and a tie-break test.

### 19.10 Phase Two queue (recipes surface)

Items deliberately deferred from Phase One. Each is sized to be its own halt-and-validate phase.

1. Quick → Regular bridge redesign (see 19.8) — pick one of A / B / C.
2. Custom fields Pro gate audit (see 19.7) — confirm or fix.
3. `ComponentField` `kind: String` → `ComponentKind` enum.
4. Recipe templates → seed JSON (see 19.8).
5. `ComponentField` listener-leak hardening — eliminate the two-controllers mirror by making the parent controller serve as the Autocomplete's controller.
6. Unified `RecipeDraftEditor` widget — collapse `_PhotoImportReviewScreenState` and `_EntryFormState` (multi-page).
7. Unified field taxonomy — merge `_FieldId` (form-private) and `FieldId` (spreadsheet-public) under one canonical `RecipeFieldId`.
8. New import sources go Live — Word `.docx`, OneNote, Garmin Xero photo.
9. `_pruneSelection` in `recipes_list_screen.dart` moves into a Stream transform (today it's an `addPostFrameCallback`-deferred `setState`).
10. Two-save-paths consolidation in `recipe_form_screen.dart` (`_save` + `_runAutoSave`).
11. Schema version history reconstruction — walk `database.dart`'s migration steps to fill the partial table in § 4.

Each Phase Two item is independent. They can ship in any order based on operator priority.
