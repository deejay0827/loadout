# CLAUDE.md — Marketing reference for LoadOut

```
================================================================================
WHAT THIS FILE DOES
================================================================================
Internal marketing reference for LoadOut. The single source of truth for
anyone writing copy: app-store listings, support replies, paywall pitch,
landing pages, podcast sponsorships, social posts, comparison pages.
Tone is direct + factual; this doc is the briefing, not the deliverable.

================================================================================
WHY IT EXISTS IN THE ARCHITECTURE
================================================================================
The engineering CLAUDE.md (`/Users/general/Development/Applications/LoadOut/CLAUDE.md`)
describes how LoadOut works. This file translates that into the precise
language a marketer / copywriter / support agent needs to talk about the
product without making claims that aren't true. When the two conflict,
the engineering doc wins and this one gets corrected.

================================================================================
WHY THIS IS HARDER THAN IT LOOKS
================================================================================
- Reloaders are skeptical of marketing copy. Vague adjectives lose them;
  numbers + specifics earn trust. "258 reticles" beats "many reticles."
- We have a multi-layered IP posture (reticles are LoadOut original /
  public domain only — no trademarked reticle names ship in the catalog).
  Marketing copy that name-drops a trademarked reticle is wrong AND
  legally risky.
- "Free" alone is misleading because we have a Pro tier. Always say
  "free tier" or describe what's free.
- Some features are scaffolded but not shipped (Apple Watch / Wear OS,
  AI Reloading Assistant chat). Marketing copy MUST flag these as
  "Coming Soon" rather than imply they're live.
- The privacy claim is structurally true ("we don't run a backend that
  stores reloading data") but has narrow exceptions (Firebase Auth
  tokens, RevenueCat purchase events, opt-in Crashlytics, opt-in AI
  Smart Import, opt-in weather pull). Glossing the exceptions reads as
  dishonesty to the audience that cares most.

================================================================================
WHO CONSUMES THIS FILE
================================================================================
- Anyone writing marketing copy, landing pages, app-store listings,
  support replies, or product comparisons.
- The Claude Project chat window we run for marketing brainstorming.
- New team members onboarding to "what is LoadOut, exactly?"

================================================================================
SIDE EFFECTS
================================================================================
None. Pure documentation.
```

---

## 1. Identity, voice, brand promises

### Names and identifiers

| | |
|---|---|
| App name (in-app) | **LoadOut** |
| App Store / Play Store name | **LoadOut: Precision Reloading** |
| Apple Bundle ID | `com.johnsondigital.loadout` |
| Android package | `com.johnsondigital.loadout` |
| Watch bundle | `com.johnsondigital.loadout.watchkitapp` |
| Wear OS package | `com.johnsondigital.loadout.wear` |
| Firebase project | `loadout-precision-reloading` |
| Marketing host | `loadout-precision-reloading.web.app` |
| Support email | `support@loadoutapp.com` |
| Brand colors | Charcoal `#1F2937` + brass `#C5A572` |
| Wordmark | Brass-tinted serif on charcoal |

### Voice

Direct, technical-but-not-jargon-soaked, respectful of the reloading
craft. Reloaders are adults; speak to them as such.

- **Use:** "reloader," "shooter," "user." All interchangeable.
- **Avoid:** "customer" (too transactional), "client" (too B2B),
  "consumer" (insulting in this audience).
- **Use specific numbers** instead of adjectives. "203 cartridges with
  full SAAMI specs" beats "extensive cartridge library."
- **Say what's true** about Coming Soon features. "Shipping in v1.1"
  beats "available now" if it isn't.
- **Cite the source** when the math is borrowed. *Applied Ballistics*,
  McCoy, Miller, ICAO — name the paper / book and let readers verify.

Avoid in copy: "revolutionary," "game-changing," "AI-powered" (we have
narrow AI but it's a translation tool, not an assistant), "easy"
without qualification (reloading is a serious activity), "for everyone"
(we have a specific audience), exclamation points in headlines, emoji
in landing pages or App Store copy.

### The local-first promise

This is the headline brand promise. It is structurally true; it is the
biggest single differentiator vs every cloud-first competitor. Memorize
the exact wording:

> **Your reloading data lives only on your device. We don't run a
> backend that stores recipes, firearms, or range-day sessions. We
> don't track what you do in the app. We don't sell your data.**

The narrow, honest exceptions:

| Exception | When | What we see |
|---|---|---|
| Firebase Auth | When user signs in (sign-in is **optional**) | Email + OAuth tokens |
| RevenueCat | When user buys / restores Pro | Purchase event + UID |
| Crashlytics | If user opted in (default ON, off-able in Settings) | Fatal crash stack traces, PII redacted by SDK |
| open-meteo.com | Pro user taps "Pull weather" | Lat/lon, no identity |
| AI Smart Import (opt-in) | Pro user taps "Improve with AI" on a single import | OCR'd text from one photo only |
| Cloud Backup / Cloud Sync | User opts in, picks provider, sets passphrase | **Encrypted blob only — we hold no key** |

What we explicitly do NOT see: recipes, loads, lots, brass, batches,
range-day sessions, ballistic profiles, custom fields, photos, CSV /
Excel imports, AI chat history (the chat surface isn't shipped),
firearms inventory, or any usage telemetry.

### "No proprietary lock-in"

Local-first is sibling to "your data is portable." Concretely:

- The on-device store is SQLite (`drift`). The user can read it.
- Local export is plain JSON — included in the free tier.
- Cloud backup / sync blobs are end-to-end encrypted with a
  user-chosen passphrase. If LoadOut shut down tomorrow, the user
  retains every byte locally and can decrypt their own backups.
- No "tier-locked export" gimmick. Free users export the same JSON
  Pro users do.

Use this in copy as the rebuttal to "what if you go out of business?"

---

## 2. What LoadOut actually IS today

A local-first ammo reloading + ballistics tracker on **iOS, Android,
macOS, and the web.** The same Dart codebase compiles for all four
through Flutter; data lives in on-device SQLite via `drift` (and OPFS /
IndexedDB through drift's WASM build on web).

### Five primary tabs

The bottom-nav shell hosts five tabs in this order:

1. **Recipes** — load / handload management.
2. **Firearms** — rifle / pistol inventory + zero / ballistic defaults.
3. **Batches** — multi-recipe batch tracking and process logging.
4. **Ballistics** — the solver + DOPE + WEZ / hit probability tooling.
5. **Range Day** — the day-of-shooting workspace.

**SAAMI Specs** used to be a sixth bottom-nav tab. As of the current
build it lives at **Settings → SAAMI Specs**. Reference data isn't a
daily-use destination; the bottom nav was decluttered. Marketing copy
should not refer to SAAMI as a primary tab.

### Companion apps (transport live — Coming Soon for shipped payloads)

- **Apple Watch** — SwiftUI scaffold, watchOS 10.0+. Phone-side
  bridge (`WatchSessionBridge.swift`) is now activated automatically
  by `AppDelegate.didInitializeImplicitFlutterEngine`; the
  `WatchConnectivity` channels respond to `isWatchPaired` /
  `isReachable` queries the moment the engine is up. The watch app
  target itself still needs the manual Xcode wiring documented in
  engineering CLAUDE.md § 15. Source: `ios/RunnerWatchApp/`.
- **Wear OS** — Compose for Wear OS, Wear OS 3 / Android 11+. Gradle
  module + bridge are wired automatically by
  `MainActivity.configureFlutterEngine` (Google Play Services
  Wearable Data Layer). Source: `android/wear/`.

Both are placeholder UIs today (DOPE / Active Load / Stage Timer
screens compile but no live payloads are sent yet from the phone).
Be honest in copy: "companion apps in development" is correct;
"ships with Apple Watch app" is misleading. The wire protocol is
defined and the channels are alive — what's missing is the
phone-side code that pushes recipe / DOPE / firearm-glance state
into the bridge on every save.

### Drawer (secondary destinations)

The hamburger drawer lists: How It Works, Reloading Guide, Glossary,
**Resources** (new — SAAMI Specs and other reference material;
moved out of Settings), Brass Lots, Load Development, Reloading
Steps, AI Reloading Assistant (Coming Soon), Backup & Export,
Settings, Privacy Policy, Sign Out.

**Resources vs Settings:** Resources holds *read-only reference
material* (SAAMI cartridge specs today; future: Reloading Guide,
Powder Burn-Rate Chart). Settings holds *preferences and account*
(account, app prefs, watch & wear, connected devices, AI features,
privacy & data, data sources, help & support). The split keeps
Settings focused on configuration the user changes, while reference
material lives where users actually look for it.

### Authentication & sign-in

**Sign-in is required to enter the app — but anonymous is one of
the always-available options.** Every launch routes to LoginScreen
unless the device already has a Firebase Auth session cached. There
is no "use the app without signing in at all" path; what we offer
instead is a one-tap **Continue as Guest** that creates an
anonymous Firebase user. A guest user has full access to recipes,
firearms, batches, ballistics, Range Day, SAAMI specs, the AI chat
(when shipped), and local JSON export. Cloud Sync, Cloud Backup,
and Pro entitlement restore require a real account; we surface the
upgrade path on those features only.

**LoginScreen layout (top-down):**

1. **Continue as Guest** card — primary call-to-action with an
   icon, title, and one-line privacy note ("No email, no password —
   your data stays on this device. You can upgrade to a real
   account later if you want cloud backup or cross-device sync.").
2. "or sign in to back up + sync" divider.
3. Email / password fields, "Sign In" / "Create Account"
   FilledButton, "Forgot password?" link.
4. Divider.
5. Social provider buttons — Continue with **Google**, **Apple**,
   **Microsoft**, **Yahoo**.
6. **Email Me a Sign-In Link** affordance (passwordless, deep-link
   based).
7. Get help signing in (mailto support).

**First-launch enforcement.** On iOS, Firebase Auth's refresh token
persists in the system Keychain across app uninstalls — so a
"fresh install" was previously already-signed-in. On the very
first launch on a given install (detected via the
`app_launched_before` SharedPreferences flag), `main.dart` calls
`FirebaseAuth.instance.signOut()` to clear any cached session. The
flag is set BEFORE the sign-out so a crash mid-flow can't loop the
user. Subsequent launches see the marker and skip — returning users
go straight to HomeScreen via the cached refresh token.

**Biometric unlock — present but NOT promoted.** Settings → Account
exposes a "Unlock with biometrics" toggle for users who want it
(`local_auth` plugin; iOS `NSFaceIDUsageDescription` + Android
`USE_BIOMETRIC` / `USE_FINGERPRINT` declared). Hidden when the
device has no biometric enrolled. **Hidden when the user is
anonymous** — biometric is only offered to real-account users
because the anonymous Firebase account is device-local; binding
biometric to it would sell false security.

**Don't lead with biometric in marketing copy.** It's a quality-of-
life toggle, not a flagship capability. Keep it out of headlines,
home-page bullets, App Store screenshot captions, and the "Pro
features" pitch. Mention it only when the user-facing surface
(Settings) is being explained, and only as one bullet among others.

If asked specifically (FAQ, support reply, advanced-feature page),
the factual description is: "Settings → Account has an optional
biometric unlock for users with a real account. The platform
biometric prompt runs locally; no biometric data leaves the
device. Anonymous users don't see the toggle."

**What we DON'T claim:**

- We don't say "biometric login" — biometric is an unlock gate on
  top of Firebase's existing session, not a separate auth method.
- We don't say "Face ID required" — the toggle is opt-in.
- We don't put a fingerprint icon on the home page or in App Store
  screenshots.

---

## 3. The Pro tier

**One paid tier. Two SKUs. No monthly. No "Pro Plus."**

| Plan | Price | Notes |
|---|---|---|
| Free | $0 | Generous; see Free vs Pro table below. |
| Pro Yearly | **$39.99 / yr** | Default plan. |
| Pro Lifetime | **$79.99 once** | Pays for itself in 2 yr vs yearly. |

RevenueCat product IDs: `loadout_pro_yearly`, `loadout_pro_lifetime`.
Single entitlement: `pro`. Linked to Firebase Auth UID at sign-in so a
user who buys Pro on iOS sees Pro on Android with the same account.

### Pro features (canonical list)

This list mirrors `/Users/general/Development/Applications/LoadOut/CLAUDE.md`
§ Monetization. When the in-app `ProGate` set drifts from this list,
the pitch goes wrong; keep them aligned.

| Feature | What it gates |
|---|---|
| **Cloud Sync** | Continuous, end-to-end encrypted sync to user's iCloud Drive / Google Drive / OneDrive |
| **Cloud Backup (manual)** | One-shot encrypted backup to user's own cloud |
| **Hornady 4DOF / custom drag curves** | Doppler-radar measured Cd-vs-Mach curves; CDM imports |
| **Bluetooth devices** | Kestrel 5xxx Link, Garmin Xero (.fit), 5 BLE rangefinders |
| **Scope View Pro** | Reticle visualization with hold-off rendering |
| **Scope View training mode** | Free-aim drag, skill-level timing, animated mover, ambush guides |
| **Moving Target Lead** | Lead computation in mil / MOA / inches |
| **Live weather pull (ballistics)** | open-meteo lookup on the ballistics screen |
| **Live weather pull (firearm zero)** | Same lookup from the firearm form's Zero Atmosphere |
| **GPS altitude (Range Day sensors)** | Altitude → station-pressure derivation |
| **AI Smart Import** | OCR-improvement Anthropic call (opt-in per use) |
| **AI Reloading Assistant chat** | Coming Soon at v1.0; Pro when shipped |
| **Load Development** | OCW (Newberry), Audette Ladder, Satterlee 10-shot, Generic charge ladders, and Seating Depth ladders. Per-charge SD / ES / mean MV / group size; OCW vertical-impact flat-spot detection; Satterlee MV plateau detection; group-vs-charge plotting. Cited published sources for each method. |
| **Internal Ballistics Calculator** | Powley method predictor for muzzle velocity and peak chamber pressure from a hypothetical recipe. Closes the GRT / QuickLOAD gap on mobile. Validation: ±10% MV / ±15% pressure across the test corpus. |
| **Custom fields (unlimited)** | Per-recipe / per-firearm / per-batch user-defined fields |

The free tier ships **everything else** — recipes, firearms, batches,
the full ballistics solver core, Range Day basics, on-device photo
OCR, local JSON export, all reference catalogs, the glossary, SAAMI
specs, manual encrypted backup (export + upload-yourself), and the
companion-app scaffolds.

### What the paywall pitch leads with

The in-app paywall (`lib/screens/paywall/paywall_screen.dart`
`_FeaturesShowcase`) renders six cards in this order. Use the same
order in landing-page hero copy:

1. **Cross-device cloud sync** — encrypted on device with the user's
   passphrase; we never see the blob.
2. **Real Hornady 4DOF measured drag curves** — Doppler-radar Cd-vs-Mach,
   not a math approximation.
3. **Bluetooth devices** — Kestrel + Garmin Xero + every major rangefinder
   incl. Vectronix Terrapin X.
4. **Scope View Pro + training mode.**
5. **Live weather + GPS altitude.**
6. **AI Smart Import** — translation tool. Reading-only. Off by default.
7. **Load development** — OCW (Newberry), Audette Ladder, Satterlee
   10-shot, and Generic charge ladders with statistical analysis,
   per-charge SD / ES / mean MV / group size, and node detection.

The **AI Reloading Assistant** stays out of this pitch on purpose. It's
Coming Soon at v1.0 and the chat framing trips reloaders' "AI-powered"
allergy. Mention it in roadmap copy; never lead with it.

---

## 4. Recipes

The recipe surface is the heart of the app — the thing reloaders open
the most.

### Two FAB buttons: Quick + Standard

Tap **+** in Recipes and you get a stacked FAB cluster:

- **Quick** (extended FAB, brass-tinted) — opens `QuickAddRecipeScreen`
  for fast notebook-style capture.
- **+ Standard** (round FAB) — opens the full `RecipeFormScreen`.

The Quick form intentionally drops the advanced fields (COAL, CBTO,
seating depth, mandrel, shoulder bump). It's for capturing a load while
your hands are still messy from the bench.

### Recipe name is OPTIONAL

Both forms generate a fallback name from the load-defining fields if
the user doesn't type one — e.g. **"6.5 CM 140gr H4350 — May 9 8:42 PM"**.
The fallback is computed at save time, so the user can always change it
later. **"Switch to Regular" from the Quick form does NOT require a
name** — the auto-generated name applies to the regular form too.

### Detail level toggle: Core / Extended / Full

The Standard recipe form has a three-position segmented control labeled
**Core / Extended / Full** (renamed from the older "Basic / Detailed /
Full" labels — copy must use the current labels).

- **Core** — recipe name, caliber, powder, charge, bullet, primer,
  brass, notes. The fields a reloader can write on a notebook line.
- **Extended** — adds CBTO, seating depth, primer / brass setup, lot
  pickers.
- **Full** — adds pressure indicators, process notes, temperature
  sensitivity, jump to lands, mandrel size, etc.

Beginner Mode (a separate Settings toggle) anchors the form at Core
and hides the segmented control.

**Full mode is now navigable rather than one long scroll.** In Full
mode the form starts with only the two primary sections (Load
Identification and Powder) expanded; the other seven (Primer,
Bullet, Brass, Loaded Round Dimensions, Pressure Indicators,
Process / Equipment / Provenance, Custom Fields, Notes) collapse
by default. Users navigate by tapping section headers. **Switching
modes preserves data AND landing position:** every controller
survives a Core ↔ Extended ↔ Full switch (no field is ever
discarded), and the form auto-scrolls back to the section the user
last expanded — so editing Powder in Core then flipping to Full
lands the user inside the expanded Powder section, not at the top
of the form.

### Empty-state next-action cards

Every primary list — Recipes, Firearms, Brass Lots, Batches —
shows an `EmptyStateCard` instead of a one-liner when the list has
zero rows. Each card has a heading, a one-paragraph explanation,
and inline action buttons that mirror the FAB. Recipes shows two
side-by-side buttons: **Quick** (FilledButton, ⚡ icon) and
**Standard** (OutlinedButton, + icon). Firearms / Brass Lots /
Batches each show a single primary button. The cards disappear the
moment the user adds their first row.

### Smart defaults that learn

Component pickers (caliber, powder, bullet, primer, brass) sort
options by **Favorites → Frequently used → general (alphabetical)**.

- **Favorites** — for cartridge: the user's `UserFavorites`
  rows (toggled from the SAAMI screen). For powder / bullet /
  primer / brass: name-keyed favorites in the
  `UserComponentFavorites` drift table (toggled by tapping the
  star next to a row in the dropdown). Favorites participate in
  Cloud Sync and exports.
- **Frequently used** — derived from a `GROUP BY` over the user's
  `UserLoads` rows (top 5 most-used names per kind). Renders with
  a small history-clock icon as the leading indicator in the
  dropdown.
- **General** — the rest, in upstream alphabetical order.

In marketing copy: "What you usually shoot is at the top of every
picker. The app learns the powders, primers, bullets, and brass
you actually use."

### Imports section (collapsed into one)

Both Quick and Regular now expose imports in a single **Imports**
section. Sources covered today:

- **Spreadsheet** (CSV / Excel) — fuzzy header mapping wizard.
- **Photo** (on-device OCR) — ML Kit text recognition + 444-entry
  handwriting alias dictionary.
- **File** — re-import LoadOut JSON exports.
- **Another reloading app** — CSV with format detection (Hornady 4DOF
  export, GRT, QuickLOAD, Strelok export shapes recognized).
- **Paste from clipboard** — best-effort heuristic parse.
- **AI Smart Import** (Pro) — only fires when on-device parser flags
  low confidence, AND the user explicitly taps "Improve with AI."
- **iCloud Drive / Google Drive / OneDrive** — alongside the system
  file picker, so the user can pull a CSV directly from their cloud.
- **QR scan** — scan another LoadOut user's recipe QR.

### Auto-save (Settings → App Preferences)

Two prefs control auto-save behavior across recipe + ballistic profile
forms (Range Day uses its own flow):

| Frequency option | Behavior |
|---|---|
| Off | Save only when user taps Done / Save |
| After Any Change | 2-second debounce after each edit |
| Every 1 Minute | Periodic timer; saves dirty form |
| Every 5 Minutes | Periodic timer |
| Every 10 Minutes | Periodic timer |

Default for new installs: **After Any Change**.

| Unsaved-changes-on-pop policy | Behavior |
|---|---|
| Ask each time | Save / Discard / Cancel dialog |
| Discard | Silently throw away changes |
| Save automatically | Silently flush on pop |

When auto-save is **Off**, the form shows a TWO-button toolbar — **Save**
(stays on the page) and **Done** (saves + leaves). At any other
frequency the screen has a single Done button because saves happen in
the background.

### Recipe sharing

- **PDF** — single recipe export to a printable card. Free.
- **QR code** — `LO1:`-prefixed magic string, scannable by the QR
  scanner in another LoadOut user's recipe-import flow. Free.

### Custom fields (Pro)

Unlimited user-defined fields per recipe / per firearm / per batch. Free
users see existing custom fields read-only; Pro users add and edit them.

---

## 5. Firearms

Per-firearm tracking includes:

- **Shots-fired counter.** Auto-increments when a Range Day shot is
  logged against the firearm.
- **Sight scale calibration** (vertical + horizontal). Exposed as a
  static field today; the DPC auto-calibration wizard is on the
  roadmap.
- **Default zero** (distance + atmosphere preset).
- **Default muzzle velocity** + temperature sensitivity.
- **Default sight height** above bore.
- **Twist rate** + barrel length — feed Miller stability + spin drift
  in the solver.

### Favorites (new)

Star a firearm and it bubbles to the top of every picker (Range Day,
Recipe form, Batch form). Stars work directly in dropdowns AND in list
views. See § 13 below.

---

## 6. Batches

Multi-recipe batch tracking. Less prominent in the UI than Recipes /
Range Day, but lives at the same level — its own bottom-nav tab. Use
case: tracking 100 rounds loaded across two recipes for a match
weekend. Less interesting in marketing copy than Recipes; mention but
don't lead with it.

---

## 7. Ballistics

The solver and the math are documented openly in
`/Users/general/Development/Applications/LoadOut/lib/services/ballistics/`.

### Solver core

- **Modified Point Mass (MPM)** with Cash-Karp adaptive RK45
  integration (1e-4 m tolerance). McCoy-style differential equations
  with add-ons.
- **Drag tables:** G1, G2, G5, G6, G7, G8 (all six standard tables).
- **Custom drag curves** (Pro): Hornady 4DOF measured curves
  pre-shipped, plus user-imported CDM files. Interpolated with
  Fritsch-Carlson PCHIP (smoother than linear in the transonic
  region).

### precision corrections (all on by default)

- **Spin drift** (industry-standard published formula).
- **Coriolis** — horizontal + Eötvös vertical (full 3D `−2 Ω × v`).
- **Aerodynamic jump** from cross-wind — explicit per-sample
  correction, plus the cant×crosswind angular term from *Modern
  Advancements* Vol. III.
- **Pejsa stability** as an alternate spin-drift model.
- **Miller stability** — velocity-corrected gyroscopic stability factor.
- **Form factor i7** — computed internally; surfaced on the bullet
  detail screen as info.

### Two-tier solver test tolerance

The test suite enforces:

- **Self-consistency:** ±0.01 mil agreement between solver runs across
  refactors.
- **Published cross-check:** ±0.1 mil agreement against the published
  example tables in *Applied Ballistics for Long-Range Shooting* 4th
  ed. (citation in test file).

### Atmosphere

- ICAO standard atmosphere as fallback.
- Station pressure (vs sea-level) — separate input.
- Density altitude derivation.
- Tetens humid-air vapor-pressure correction.
- **Atmosphere presets** — saved named profiles (e.g. "Camp Perry
  June," "Whittington July") with a picker that swaps every
  environment field at once.
- **Zero atmosphere** held separately from runtime atmosphere on the
  ballistic profile, so a sea-level zero applies correctly at altitude.

### Pro analysis services

- **WEZ analysis** — Monte Carlo hit probability across the engagement
  window with sensitivity breakdown (which input drives misses?).
  Pro-gated.
- **BC truing** — paste observed drops at distance, get a corrected
  ballistic coefficient via bisection / golden-section search.
  Pro-gated.
- **Scope Tracking Test** — DPC / tall-target calibration that
  verifies the user's turret tracks the labelled values. Pro-gated.
  (Formerly "Sight Calibration" — renamed for plain-English
  shooter-side terminology; the underlying service file is still
  `sight_calibration_service.dart`.)

### Free analysis services (still substantial)

- **Wind bracket** — base ± low / high holds.
- **Hit probability (single aim point)** — Monte Carlo dispersion with
  per-source breakdown (group / wind / range / MV).
- **Group statistics** — extreme spread, mean radius, σ horizontal /
  vertical, group MOA, **90% confidence interval band once N≥3**,
  centroid + zero-adjust recommendation.
- **Last-shot correction** — "hold up X mil, right Y" to bring next
  shot back to the aim point.

---

## 8. Range Day

The day-of-shooting workspace. The screen the user lives in WHILE at
the range.

### Behavior

- **Always opens fresh on tab tap.** "Tapping Range Day always starts a
  brand-new session" was an explicit product requirement. Saved
  sessions live in a History menu in the AppBar.
- **AppBar title is constant "Range Day."** Per-session names live in
  the History list, not the AppBar.
- **AppBar actions:** Quick / Full mode toggle, History
  (saved-sessions list), Recalculate.
- **Quick / Full mode toggle (live).** A compact two-segment
  control in the AppBar (⚡ Quick / 🎚 Full). Quick mode collapses
  the screen to **Setup + Firing Solution** — the bare minimum a
  shooter needs at the line. Full mode reveals every advanced
  card (Environment, Wind Bracket, Hit Probability, Target Plot,
  Group Stats, Last Shot Correction, Moving Target, DOPE, Notes).
  Choice persists across visits via SharedPreferences
  (`range_day_mode` key); fresh installs default to Quick. On wide
  layouts (tablet / desktop), Quick mode collapses the two-column
  layout to a single 720px-capped centered column; Full mode keeps
  the two-column layout.
- **Auto-saves on every field change** (debounced); rack picks now
  persist across app restarts.

### Sections (top-down on phone, two-column on tablet)

1. **Solution strip** (pinned at top, slim) — active load + distance +
   target + wind + drop + windage. "Glance → fire → glance" without
   scrolling.
2. **Setup** — target picker (with shape filter: Circle / Square /
   Rectangle / Silhouette), distance, ballistic profile, load,
   firearm, reticle. Shot azimuth + Incline / Decline are full-mode-only.
3. **Environment** — temp, pressure, humidity, elevation, wind. Pull
   from weather (Pro), atmosphere preset picker, live Kestrel toggle
   when paired.
4. **Solution** — drop, wind, time of flight, velocity, energy. Largest
   text on the screen. Wind Bracket, Hit Probability gauge, Target Plot.
5. **Group stats** — ES, MR, group MOA, σh / σv, 90% CI band (N≥3),
   centroid + zero-adjust.
6. **Last shot correction** — only renders once shots > 0.
7. **DOPE card** — 100 yd-step trajectory ladder.
8. **Moving Target** (Pro) — speed + direction → lead computation. *Now
   a pushed route, not an inline card.*
9. **Notes.**
10. **Advanced Analysis** — pushed routes for **Hit Probability Map**
    (Monte Carlo across the engagement window — formerly "WEZ
    Analysis"), **BC Truing**, and **Scope Tracking Test** (formerly
    "Sight Calibration").

Group Stats and Moving Target moved from inline cards to **pushed
routes** for screen-real-estate reasons.

### Defaults (fresh session)

- **Default reticle:** **Classic Mil Hash (Generic)** — the
  public-domain mil hash pattern. ID: `pd_mil_hash_generic`.
  Renders in BLACK on the daytime backdrop (the brass theme tint
  blended into the sky / grass and was hard to read).
- **Default target:** **18 in × 30 in white IPSC silhouette.**
- **Default load (empty state):** the load picker offers 19 curated
  factory cartridges in a "Pick a Common Load" bottom sheet (see § 12).
- **User favorites override defaults** — a favorited reticle / target
  on a fresh session bumps the LoadOut default out.

### Target Plot view modes

Two view modes for the Target Plot widget (toggle persists across app
restarts via `SharedPreferences`):

- **Realistic** — scope ring overlay + sky / grass / dirt backdrop;
  single targets sit on a pole, KYL racks hang from chains.
- **Target-Focused** — target dominates the frame for accurate dot
  placement.

### Rack support (schema-level)

The Range Day target picker has a **single / rack** segmented toggle.
Six rack types ship today (`assets/seed_data/target_racks.json`):

- 5-Plate KYL
- 5-Plate Equal Rack
- 5-Plate Square Rack
- 5-Pepper Popper Rack
- 3-Plate Decreasing
- IDPA Open Stage

Rack mode shows an "active child" picker so the shooter can sequence
through plates within the rack. The persisted state survives app
restarts.

---

## 9. Reticles & scopes

This is the most legally sensitive section in the app. **Read it
carefully before writing any copy that names a reticle.**

### The IP posture: LoadOut original + public domain only

The reticle catalog ships **only LoadOut-original archetypes and
public-domain reticles**. **No trademarked or licensed reticle names
appear in the catalog.** This is a deliberate, recent change driven by
IP / licensing risk analysis (see
`/Users/general/Development/Applications/LoadOut/docs/RETICLE_LICENSING.md`).

The risks we are deliberately not taking:

- **Horus Vision LLC** (TReMoR / H59 series) is litigious. Reproducing
  geometry — even approximate — could be claimed as design-patent or
  copyright infringement.
- **Brand-specific reticle marks** (EBR, MOAR, MIL-XT, P4F, ACOG,
  ACSS, etc.) carry trademark + design-patent exposure.
- Other ballistic apps (Strelok Pro, AB Quantum) ship the brand names;
  they have a licensing posture or operating risk we don't share.

### Picker grouping

The reticle picker groups its 40+ entries into five user-facing
sections so beginners aren't faced with a flat wall: **Mil
reticles**, **MOA reticles**, **Classic** (formerly labelled
"Public domain" — renamed for plain-English readability),
**Combat / Tactical**, **Red dots**. The sections render only when
two or more buckets have matches (a popular-tag chip filter that
narrows results to a single bucket falls back to a flat list, no
header noise). Within each section, favorites still bubble to the
top.

**Internal data note.** The renamed "Classic" label is a
display-time transform on top of the existing seed data — rows in
the database still have `manufacturerId = "Public domain"`, but the
picker rewrites that to "Classic" everywhere it renders. This means
the rename is invisible to backups, JSON exports, and the SQLite
file — only the user-facing UI changed. If we later move to a real
DB rename we'll add a one-shot migration; for now the display
transform keeps the change low-risk.

### What ships today (43 reticles total)

**24 LoadOut-original archetypes** (`loadout_*` IDs):

- Mil Tree family — Default, Compact, Medium, Dense, Christmas Tree,
  Hash (6 variants).
- MOA Tree family — same six variants.
- MOA Hash, Mil Hash.
- SFP Mil-Drop, SFP MOA-Drop, BDC.
- Combat, Combat with BDC, DMR-BDC, Hunting BDC.
- Red Dot 2 / 4 / 6 MOA, Red Dot + Ring.
- Holographic Ring + Dot.

**19 public-domain reticles** (`pd_*` IDs):

- Mil-Dot (USMC), Mil Hash (Generic).
- Plex, Crosshair (fine / medium / heavy).
- German #1 / #4 / #4A / #8.
- Post and Crosshair, Picket Post.
- Circle and Dot, Circle and Cross.
- Chevron, Dotted Crosshair, Iron Sight Ring.
- Post and Dot, Diamond.

### Scope NAMES are kept (factual identification)

We ship 47 scopes across 26 brands today
(`assets/seed_data/scopes.json`). Naming a scope is **factual product
identification** — saying "Vortex Razor HD Gen III 6-36x56 FFP" is
descriptive, not infringing. This is also nominative fair use under US
trademark doctrine: you can't identify the product without the name.

Brands shipped: Vortex Optics, Nightforce Optics, Schmidt & Bender,
Leupold, Tangent Theta, Zero Compromise Optic, Hensoldt, Kahles,
Bushnell, Sig Sauer, Athlon Optics, Element Optics, Burris, Arken
Optics, Primary Arms, Aimpoint, EOTech, Trijicon, Holosun, ZeroTech
Optics, Riton Optics, Swarovski Optik, Carl Zeiss, Meopta, DEON
Optical Design (March), Sightron.

### "Find by my scope"

The reticle picker has a **"Find by my scope"** affordance — the user
types their scope (e.g. "Schmidt & Bender PMII 5-25x56") and the picker
maps it to the LoadOut-original archetype that does the equivalent
hold-off math. The mapping is approximate; the math (subtensions) is
accurate. This is the bridge that makes a brand-agnostic catalog usable
to a shooter who's only ever held the branded reticle.

### Marketing rules for reticles

- **Never name a trademarked reticle** in copy as if we ship it. We
  don't.
- **Do** describe scopes by their actual product name when comparing.
- **Do** describe LoadOut reticles by their LoadOut name ("LoadOut
  Default Mil Tree," "LoadOut Christmas Tree MOA").
- For copy that needs a "we cover the equivalents" pitch, say
  something like: "If your scope ships with a TReMoR3 or an EBR-7C,
  use the LoadOut Mil Tree archetype — same hold-off math, no
  licensing complications." That's accurate AND honest.

---

## 10. Targets

`assets/seed_data/targets.json` ships 52 entries across 4 shape
families: Circle, Square, Rectangle, Silhouette.

- **Default for fresh Range Day sessions:** 18 in × 30 in **white** IPSC
  silhouette.
- **5-color override palette** in the picker: White / Orange / Brown /
  Yellow / Red. Black silhouettes render via the `silhouette` shape
  primitive itself, not via tint.
- Categories: paper, steel, reactive, game-silhouette.
- Rack support (6 rack types — see § 8) for KYL plates, IDPA stages,
  pepper poppers.

---

## 11. Glossary (in-app)

`assets/seed_data/`-free, lives in source code at
`lib/screens/glossary/glossary_screen.dart`.

- **142 terms** across **10 categories:**
  - Cartridge anatomy & dimensions
  - Ballistics
  - Range day & shooting
  - Optics & reticles
  - Load development
  - Powder & burn behavior
  - Primers
  - Brass & case prep
  - Reloading process
  - Firearm-side
- Search bar at the top, alphabetical within each category.
- **34 entries** include a worked example (1–3 sentence walkthrough
  with concrete values) that expands on tap.
- **Tappable labels app-wide.** Every domain term in the recipe /
  ballistic / load development / Range Day forms is wrapped in a
  `GlossaryLabel` widget. Tap the label → bottom sheet with the
  definition + an "Open in Glossary" button that pre-filters the
  glossary screen on that term.
- **Landing tiles for new users.** Above the category list (when
  no search is active), the glossary surfaces two curated tiles:
  **"New to reloading"** (21 foundational terms — COAL,
  headspace, pressure signs, charge weight, neck tension,
  annealing, etc.) and **"Range Day workflow"** (22 firing-line
  terms — mil, MOA, drop, wind drift, DOPE, density altitude,
  cant, hold-over). Tapping a tile filters the glossary to that
  curated subset; a "Show all" chip clears the filter. Beginners
  who don't know what to search for get an entry point that isn't
  "scroll 142 terms looking for the right one."

**Beginner Mode + glossary integration.** When Beginner Mode is on
(Settings → App preferences), the `(?)` help glyph next to a
glossary-tracked label renders in the theme's primary color the
**first time** the user encounters that term in a session, then
fades to subtle gray on subsequent appearances. The session-scoped
"first-occurrence" tracker is in-memory only (resets on app
restart) — fresh sessions get fresh emphasis on terms the user has
seen before. This is the "auto-tooltip" behavior in marketing
copy; technically it's "first-occurrence emphasis," not an
auto-popup.

The glossary is **always free** — no paywall, no sign-in. Same for
SAAMI specs (now under the Resources drawer destination).

---

## 12. The two-database model — bullets vs ammunition

A nuance worth understanding before writing copy. We ship **two distinct
catalogs of bullet-related data**:

### Catalog A: Bullets (the projectile alone)

- Used by: **Recipes** + ballistic profiles.
- Example: Berger 109gr Hybrid Target.
- The reloader picks a bullet, then supplies powder + powder charge
  separately.
- File: `assets/seed_data/bullets.json` (10 manufacturers).

### Catalog B: Manufactured Ammunition (factory cartridges)

- Used by: **Ballistic profiles** + Range Day "Common Loads" picker.
- Example: Hornady 6.5 CM 140gr ELD-Match (factory-loaded round).
- No powder data (manufacturer doesn't publish it). DOES carry MV +
  BC + standard deviation.
- File: `assets/seed_data/manufactured_ammo.json` — **19 curated
  factory loads today**, in `lib/services/common_loads_catalog.dart`'s
  Range Day empty-state picker. Brands: Hornady, Berger, Federal, CCI,
  Sierra.
- Plus a much larger reference catalog at
  `assets/seed_data/factory_loads.json` — **4,143 factory ammo SKUs
  across 37 manufacturers** with published MV + G1 / G7 BC. Used for
  reference / lookups, not the empty-state picker.

The two databases never cross-consume. A recipe needs powder; a factory
load doesn't.

---

## 13. Favorites

A simple but high-impact UX layer. Wherever a reference list shows up,
a star icon bubbles favorited entries to the top.

Surfaces with favorite-star support:

- Recipes (list + detail).
- Firearms (list + detail).
- Ballistic Profiles (list + picker).
- Cartridges (in the SAAMI screen + recipe / firearm form pickers).
- Reticles (Range Day + firearm-form picker).
- Targets (Range Day picker).
- **Component dropdowns** — powder, bullet, primer, brass. Each
  dropdown row has a tappable star in the trailing slot;
  favoriting bubbles the entry to the top of the picker.

### Behavior

- Stars work directly in the dropdown / list view, not just the
  detail screen. For component pickers (powder / bullet / primer /
  brass), the trailing star toggles favorite state without
  dismissing the dropdown.
- A favorited reticle on a fresh Range Day session becomes the
  default reticle (overriding the Classic Mil Hash default).
- A favorited target on a fresh Range Day session becomes the
  default target (overriding the 18×30 silhouette).
- **Cartridge / reticle / target favorites** live in the
  `UserFavorites` join table (int row-id keyed) — same as before.
- **Component favorites** (powder / bullet / primer / brass) live
  in the `UserComponentFavorites` table (name-keyed; survives
  catalog re-seeds AND custom-component renames). Schema v25.

### Sync + export coverage

All favorites participate in the standard export / restore / Cloud
Sync pipeline:

- **JSON export** (Backup & Export screen) — `user_favorites` and
  `user_component_favorites` are dumped alongside every other
  user-data table.
- **Cloud Sync (Pro)** — same encrypted blob, last-writer-wins
  reconciliation per row. A favorite added on iPhone shows up on
  iPad on the next sync pull.
- **Manual restore** — pulls favorites back along with everything
  else.

In marketing copy: "Star your go-to load, your favorite powder,
your usual primer — they're at the top of every picker on every
device."

---

## 14. Auto-save

See § 4 for the user-facing behavior. For copy purposes:

- **Frequency:** Off / After Any Change / 1 min / 5 min / 10 min.
- **Unsaved-changes-on-pop policy:** Ask each time / Discard / Save
  automatically.
- Recipe + Ballistic Profile share one implementation
  (`UnsavedChangesScope` widget + `AutoSaveController`).
- Range Day uses its own auto-save flow (debounced per-field-change).

In copy: "You will not lose work to a back-button. Auto-save is on by
default; how aggressive it is is your call."

---

## 15. AI Smart Import (Pro, opt-in per use)

The **only** Anthropic-using surface in the app today.

### What it is

A translation tool. Takes the on-device OCR's draft of a notebook
photo and asks Claude to fix the messy bits — handwriting the device's
ML Kit couldn't parse cleanly, ambiguous fractions, smudged digits.
Returns a structured patch on the recipe shape. Nothing else.

### How it works

- Default: **OFF** in Settings → AI. User has to flip a master toggle
  AND tap "Improve with AI" per-import to fire it.
- **Hosted mode** (default for Pro users): request goes through a
  Cloudflare Worker proxy at
  `anthropic-proxy.loadout-precision-reloading.workers.dev` with the
  user's Firebase ID token. Per-Pro-user cap of **20 imports / month**.
- **BYOK mode**: user pastes their own Anthropic API key
  (`flutter_secure_storage` keyed `byok_anthropic_key`); requests go
  straight to `api.anthropic.com`. Skips the proxy and the cap. Free
  users with BYOK can use the feature too.

### Privacy contract (verbatim)

- The Worker logs **timestamp, short UID prefix, status code, latency,
  token counts** — **never the request body**.
- The only data sent: OCR'd text from the photo + on-device parser's
  draft + (optional) reference-catalog hints.
- **Never sent:** saved recipes, firearms, brass lots, batches,
  ballistic profiles, custom fields, anything else from the on-device
  DB.
- BYOK mode: key lives in iOS Keychain / Android Keystore.
- Anthropic's API terms forbid training on API requests; verify
  before each renewal.

### Marketing language

Use these exact phrases:

- "Translation tool, not an assistant."
- "Reads OCR'd text from photos you took. Nothing else."
- "Off by default. Per-import opt-in."
- "Anthropic does not train on API requests."
- Avoid: "AI assistant," "AI-powered," "smart" (the feature name is
  "AI Smart Import"; don't extend the adjective elsewhere).

The reloader skeptic framing is load-bearing. Marketing must reflect
it.

---

## 16. AI Reloading Assistant (planned, Coming Soon)

A separate Anthropic surface from AI Smart Import. **Not shipped today.**

The drawer entry "AI Reloading Assistant" routes to a Coming Soon
placeholder. Marketing copy must say "Coming Soon" or "Shipping in
v1.1" — never imply it's live.

When shipped, it will be Pro-gated and have its own privacy section,
its own service, and its own risk surface. It is NOT a multi-turn
extension of AI Smart Import. Treat them as two unrelated features
that share a vendor.

---

## 17. Bluetooth devices (Pro)

**7 BLE-enabled devices supported.** All are gated behind the Pro
entitlement because manual entry is always free elsewhere in the app
and the firmware integrations cost real engineering per brand. All
device adapters live in `lib/services/ble/`.

| Device | Channels | Status |
|---|---|---|
| **Kestrel 5xxx Link** | Live temp, station pressure, humidity, wind speed/direction, density altitude | Validated |
| **Garmin Xero C1 Pro** | Per-shot velocity, average FPS, ES, SD (via .fit file import) | Validated |
| **Sig Sauer KILO BDX** | LOS distance, incline, shoot-to range | BETA — reverse-engineered |
| **Bushnell BDX** | LOS distance, sometimes incline | BETA — reverse-engineered |
| **Vortex Razor HD 4000 / Fury HD AB** | LOS distance, incline, shoot-to range | BETA — reverse-engineered |
| **Leica Geovid Pro** | LOS distance, incline, shoot-to range | BETA — reverse-engineered |
| **Vectronix Terrapin X** | LOS distance, incline, **+ magnetic azimuth** | BETA — reverse-engineered |

### Vectronix is the unique one

The Vectronix Terrapin X is the only rangefinder LoadOut supports that
**publishes a magnetic azimuth alongside LOS distance**. Range Day's
quick-fill affordance offers a single-tap "Use distance + azimuth"
button that fills the distance field, the incline-corrected range, AND
the shot azimuth field — saving the shooter a separate compass-capture
step. This is mil/LE-grade equipment and worth highlighting in copy
aimed at that audience.

### Marketing rules for BLE

- Use the BETA badge in copy when describing reverse-engineered
  rangefinders. The badge is in the app itself; honesty is the right
  posture.
- "Every major rangefinder" is fine for headline copy. The list above
  is the long-form.
- Don't claim an integration we don't ship. We don't have MagnetoSpeed,
  LabRadar, Calypso wind meters, or WeatherFlow — competitors do.

---

## 18. Cloud Sync + Cloud Backup

Both are Pro features. Same encryption, different cadence.

### Encryption model (identical for both)

- **AES-256-GCM** content encryption.
- **PBKDF2 with 200,000 iterations** for passphrase derivation.
- The user picks the passphrase; LoadOut never sees it.
- The encrypted blob lives in the user's own iCloud Drive / Google
  Drive / Microsoft OneDrive container.
- LoadOut runs no backend that receives this blob.
- **Lost passphrase = lost data.** The Cloud Sync screen has a red
  warning to that effect. This is by design.

### Cloud Backup (manual)

- One-shot export, encrypted, uploaded to user's chosen provider.
- "Backup now" button. "Restore from backup" picks the file back up.

### Cloud Sync (continuous)

- Auto-syncs ~5 seconds after each AutoSave fires (debounced).
- Pulls on app launch + a manual "Sync Now" button.
- Conflict policy: **last-writer-wins by row `updatedAt`**. Tables
  without `updatedAt` fall back to `createdAt`; if neither has a clock,
  remote wins (preserves manual-restore semantics).
- Decryption failure leaves the local DB untouched, surfaces a
  "passphrase needed" status.
- Schema-version mismatch (incoming > local) is rejected — user is
  told to update the app on this device.
- AppBar indicator dot shows sync state.

### Marketing claim language

- "Encrypted on your device with a passphrase only you know."
- "Uploaded to YOUR own iCloud Drive, Google Drive, or OneDrive."
- "We never see the encrypted blob."
- "We can't recover a lost passphrase, by design."

The "by design" framing is important — we aren't sloppy, we're
deliberately limiting our own capability.

---

## 19. Anti-positioning (what we DON'T do, deliberately)

This list is as important as the feature list. Reloaders read product
copy for what's omitted as much as what's included.

- **No general analytics.** No Google Analytics, Mixpanel, Amplitude,
  Segment, anything. Even anonymized event analytics violates the
  "we don't track you" promise. Crashlytics is the one exception
  (opt-out fatal-crash reporting only, PII redacted).
- **No social-feed surfaces.** No likes, comments, shares, follows on
  reloading data. We are not building "Instagram for guns." Future
  shared-recipe / community-library features are deferred — too much
  surface for launch.
- **No proprietary export format.** Always JSON (free tier). No
  "tier-locked" format gimmick.
- **No subscription tiers above Pro.** No "Pro Plus." No "Elite." One
  paid tier, two SKUs, done.
- **No Doppler-radar custom drag models we make ourselves.** That's
  Applied Ballistics' moat — they have the Doppler radar and the
  partnerships. We aggregate publicly-available manufacturer 4DOF
  data (Hornady), let users true their own BC, and ship quality G7
  defaults. Honest framing: "we don't have an in-house Doppler
  facility" beats pretending we do.
- **No phone-home for license verification.** Pro entitlement check is
  RevenueCat client-side; a sign-in is what links it across devices.
- **No mandatory account.** Sign-in is optional. Anonymous users get
  every core feature except continuous Cloud Sync (manual backup is
  still free).

---

## 20. Disclosures + IP posture (matters legally + as marketing asset)

### "Data Sources & Credits" screen

Settings → Data Sources & Credits is a respectful in-app
acknowledgment of every brand whose published data underpins our
catalog. Source: `lib/screens/disclaimers/data_sources_screen.dart`.

Categories with brand lists:

- **Powder** — Accurate, Alliant, Hodgdon, IMR, Lovex / Sellier &
  Bellot, Norma, Ramshot, Shooter's World, Vihtavuori, Winchester.
- **Primers** — CCI, Federal, Fiocchi, Ginex, Murom, Remington, RWS,
  Sellier & Bellot, Tula, Vihtavuori, Winchester, Wolf.
- **Brass** — ADG / Atlas Development Group, Alpha Munitions,
  Capstone / Berger, Federal, Hornady, IMI, Lapua, Norma, Nosler,
  Peterson Cartridge, PPU, Remington, Sako, Sellier & Bellot,
  Starline, Top Brass, Weatherby, Winchester.
- **Bullets** — Barnes, Berger, Federal, Hammer Bullets, Hornady,
  Lapua, Lehigh Defense, Nosler, Sierra, Speer.
- **Cartridge specifications** — SAAMI + CIP.
- **Firearms** — 40 brands (Accuracy International through Winchester).
- **Optics** — 26 brands (see § 9).
- **Firearm parts & accessories** — 50+ brands.
- **Manufactured ammunition** — Berger, CCI, Federal, Hornady, Sierra.
- **Ballistic-math literature** — published Applied Ballistics
  literature (*Applied Ballistics for Long-Range Shooting*,
  *Modern Advancements in Long-Range Shooting* Vols. I–III,
  *Accuracy and Precision for Long-Range Shooting*), Robert L.
  McCoy's *Modern Exterior Ballistics* (1999), Don Miller's 2005
  *Precision Shooting* stability paper, ICAO standard atmosphere.
- **Open-source software** — Flutter, drift, sqlite3, etc.

### Standard non-affiliation disclaimer

Required adjacent to any list of brand names in marketing copy:

> All product names, model designations, and specifications belong
> to their respective owners. LoadOut is not affiliated with,
> sponsored by, or endorsed by any company listed.

The in-app version adds a corrections email
(`support@loadoutapp.com`). Use the same channel in marketing for
brand-correction requests.

### Reticle posture (re-stating)

The reticle catalog is **LoadOut original + public domain only**. No
trademarked or licensed reticle names. See § 9.

---

## 21. Competitive position

Source of truth:
`/Users/general/Development/Applications/LoadOut/marketing/competitive_audit_v2.md`.
Don't recap that doc here — read it before writing comparison copy.
The four-column audit (LoadOut vs Strelok / BC2026, AB Quantum,
Ballistic AE) is current as of 2026-05-08.

### One-line frames per competitor

- **Strelok / Ballistic Calculator 2026** — calculator with a deeper
  cartridge / reticle catalog. We win on: reloading workspace, encrypted
  cloud sync, Hornady 4DOF curves, lifetime pricing, photo OCR,
  6 platforms, disclosed solver. They win on: raw catalog count, brand
  pedigree (19 yr).
- **Applied Ballistics Quantum** — chief-ballistician's product;
  Applied-Ballistics-authored math, Doppler-radar CDM library, $700+
  Kestrel hardware unlocks Pro. We win on: reloading workspace, photo
  OCR, lifetime pricing, free-tier scope, multi-platform,
  **passphrase-only Cloud Sync** (theirs is server-decryptable). They
  win on: Doppler CDM library, full WEZ + sensitivity, chief-ballistician
  brand, AB Spotter AI, AB Learn.
- **Ballistic AE** — premium iOS solver; JBM engine, 5,000 projectile
  library, $30 one-time + $9.99 Kestrel IAP. We win on:
  cross-platform (they're iOS-only), reloading workspace, photo OCR,
  Hornady 4DOF, full WEZ. They win on: raw projectile count,
  Apple-ecosystem polish, lower 5-yr cost.
- **Hornady 4DOF app** — free, Hornady-bullet only. Niche; we ingest
  the same dataset under the Pro tier and pair it with a workspace.
- **GeoBallistics BalisticArc** — desktop / mil-LE focus.
- **JBM Ballistics** — open math, low-fidelity UI; the engine
  underneath Ballistic AE.
- **GRT / QuickLOAD** — load development simulators (gun and
  cartridge interior ballistics). We're the workspace and the
  exterior solver, not the interior simulator. We import their CSV.

### Honest framing rules

- **Don't claim parity with Doppler-CDM data we don't have.** AB
  Quantum has it; we don't. We compete on workspace + free-tier
  generosity + privacy, not Doppler depth.
- **Don't claim Strelok's 19-year track record.** It's their moat.
- **Do** claim "industry-standard exterior-ballistics math." Use of
  the published Applied-Ballistics formulas is correct;
  "Applied-Ballistics-endorsed" or "Applied-Ballistics-affiliated" is not.
- **Do** lead with the "no LoadOut backend ever sees your data"
  claim against AB Quantum specifically. Their AB Quantum Sync is
  almost certainly server-decryptable; we're not.

---

## 22. Marketing voice rules (style guide)

A short tactical checklist for any copy review:

1. **Direct, second-person.** "You" not "the user."
2. **Specific numbers over adjectives.** "203 cartridges with full
   SAAMI specs," not "extensive cartridge library."
3. **No emojis** in landing pages, App Store / Play Store copy, paywall
   copy, in-app surfaces, this doc, or formal channels. Limited use OK
   in casual social (one or two per post).
4. **No exclamation marks in headlines.** Reloaders are deliberate.
5. **Cite the source** for borrowed math. "*Applied Ballistics for
   Long-Range Shooting* 2nd ed., 2016" — cite the BOOK, not the
   company. We use the published methodology, not the commercial
   product built on top of it.
6. **Privacy as a feature, not a disclaimer.** "Your data lives on
   your device" reads as a benefit, not a legal hedge.
7. **Always include the safety frame** for any specific load data:
   *"These values are starting points from published reloading data.
   Always verify against your current reloading manual before
   loading. Never start at maximum charge."* Same wording as the
   in-app disclaimer.
8. **Don't slap "AI" on everything.** AI Smart Import is the only AI
   feature that ships. The chat is Coming Soon. Be precise.
9. **"Free" alone is misleading.** Use "free tier" or describe what
   the free tier includes. Avoid "free with Pro upgrade" framing —
   that reads as a bait-and-switch.
10. **Reloader / shooter / user are interchangeable.** Pick one per
    paragraph; don't switch mid-thought.

---

## 23. Useful stats + numbers for copy

Cite these directly. Counts current as of 2026-05-09 from
`assets/seed_data/`:

- **203 cartridges** with full SAAMI specs (`cartridges.json`).
- **4,143 factory ammo SKUs** across 37 manufacturers
  (`factory_loads.json`) — reference catalog.
- **19 curated factory loads** in the Range Day "Common Loads"
  picker (`manufactured_ammo.json`).
- **300+ Hornady 4DOF measured Cd-vs-Mach curves**
  (`drag_curves/curves.json`) — Pro.
- **47 scopes across 26 brands** (`scopes.json`).
- **43 reticles** (24 LoadOut-original + 19 public-domain) — see § 9.
- **52 target shapes** across 4 shape families (`targets.json`).
- **6 target rack types** (`target_racks.json`).
- **142 glossary terms across 10 categories**, with **34 worked
  examples**.
- **40 firearm brands** in the reference library (`firearms.json`).
- **50+ firearm-parts brands** in the parts catalog
  (`firearm_parts.json`).
- **7 sign-in methods** including anonymous (sign-in is **optional**).
- **4 platforms shipping today** — iOS, Android, macOS, web.
- **2 companion apps scaffolded** (Apple Watch + Wear OS — Coming Soon).
- **Modified Point-Mass solver** with Cash-Karp adaptive RK45
  (1e-4 m tolerance), all 6 standard drag tables (G1, G2, G5, G6, G7, G8),
  plus PCHIP-interpolated custom drag curves.
- **AES-256-GCM + PBKDF2-200k** encryption for Cloud Sync / Cloud
  Backup.
- **One Pro tier, two SKUs:** $39.99 / yr or $79.99 lifetime.

Numbers to NOT cite without verification:

- "258 reticles" — outdated; we ship 43 today after the LoadOut-
  original / public-domain rebuild.
- "156 optics across 21 brands" — outdated; we ship 47 across 26.
- "290 reticles" / "290+ reticles" — outdated.
- "200+ cartridges" is OK; the precise count is 203.
- "6 platforms" — outdated until Apple Watch / Wear OS ship payloads.
  Today it's 4.
- "55 target shapes" — outdated; the count is 52.

---

## 24. Standard objections + responses

| Objection | Response |
|---|---|
| "Strelok is cheaper / I already have Strelok." | "Strelok is a calculator. LoadOut is the workspace where the loads going into the calculator actually live — recipes, brass, batches, range day. We're 33% cheaper at the yearly tier ($39.99 vs $59.99) and offer a lifetime they don't." |
| "I don't trust apps with my data." | "Your reloading data never leaves your device unless you explicitly turn on Cloud Sync. Even then, it's encrypted with your passphrase before it leaves your phone, and we never have the passphrase. We have no backend that stores your loads. We can't see what we don't have." |
| "I'm too set in my ways to switch." | "You don't have to switch. Snap a photo of your notebook page when you finish a session — we'll extract the recipes in 60 seconds, on your device. Keep using paper if you want. The app becomes a searchable backup of your paper logs." |
| "I'm not technical." | "Open it. Tap the Quick FAB. Type your load like you'd write it on paper. Save. Done. Beginner Mode hides every advanced field; turn it off when you're ready." |
| "What if you go out of business?" | "Your data is local SQLite + JSON export at any time. If we shut down tomorrow, you keep everything. We can't lock you in because we don't host you." |
| "Why pay a subscription if there's a lifetime?" | "You don't have to. The free tier covers recipes, the ballistics solver, Range Day basics, photo OCR, every reference catalog, and the glossary. Pro adds Bluetooth devices, Hornady 4DOF curves, Cloud Sync, training-mode tooling, and the AI assistant when it ships. Pick whichever fits — yearly if you want to try it, lifetime if you're sure." |
| "Doesn't AB Quantum already do this with the math?" | "AB Quantum is an excellent ballistics calculator with a Doppler-radar drag library we don't try to match. It also has zero recipe / brass / batch tracking, requires a $700+ Kestrel to unlock Pro features for hardware buyers, and ships sync we'd describe differently than they do. We're the workspace; they're the math. Different jobs." |

---

## 25. Reference files (where the canonical facts live)

Keep this doc in sync with the source.

- `/Users/general/Development/Applications/LoadOut/CLAUDE.md` —
  engineering reference. **Authoritative when this doc disagrees.**
- `/Users/general/Development/Applications/LoadOut/docs/RETICLE_LICENSING.md`
  — IP posture for reticles.
- `/Users/general/Development/Applications/LoadOut/marketing/competitive_audit_v2.md`
  — competitive positioning.
- `/Users/general/Development/Applications/LoadOut/marketing/app_store_connect.md`
  — App Store listing copy.
- `/Users/general/Development/Applications/LoadOut/marketing/play_store.md`
  — Play Store listing copy.
- `/Users/general/Development/Applications/LoadOut/lib/services/common_loads_catalog.dart`
  — the 19 curated factory loads in the Range Day picker.
- `/Users/general/Development/Applications/LoadOut/lib/services/auto_save_service.dart`
  — auto-save model and frequencies.
- `/Users/general/Development/Applications/LoadOut/lib/screens/range_day/range_day_detail_screen.dart`
  — Range Day model. Read the file header, not the body.
- `/Users/general/Development/Applications/LoadOut/lib/screens/disclaimers/data_sources_screen.dart`
  — the in-app credits screen and the canonical brand lists.
- `/Users/general/Development/Applications/LoadOut/lib/screens/glossary/glossary_screen.dart`
  — glossary terms (`kGlossaryTerms`) and category definitions.
- `/Users/general/Development/Applications/LoadOut/assets/seed_data/`
  — every reference catalog (cartridges, scopes, reticles, targets,
  factory loads, etc.).
- `/Users/general/Development/Applications/LoadOut/lib/screens/paywall/paywall_screen.dart`
  — the Pro pitch as the user sees it.

---

## 26. Factual gaps / open items

Items where this doc lacks a definitive answer. Resolve these before
launch copy goes out.

1. ~~**Range Day Quick / Full mode toggle.**~~ ✅ **RESOLVED**
   (2026-05-09). The toggle is live in the Range Day AppBar — see
   § 8 for the behaviour. Marketing copy mentioning "Quick mode for
   fast field use" is now factually correct.
2. **Apple Watch / Wear OS feature payloads.** ⚠️ Partially
   resolved. The phone-side bridges are now activated automatically
   on app launch (`WatchSessionBridge.activate(messenger:)` on iOS,
   `WatchBridge` instantiation in `MainActivity` on Android). The
   wire protocol is defined and the channels respond. **What's
   still NOT shipping yet** is the phone-side code that pushes
   recipe / DOPE / firearm-glance state into the bridge on every
   save. Don't claim "Apple Watch app ships with v1" — the watch
   target itself still needs the manual Xcode wiring documented in
   engineering CLAUDE.md § 15. Safer claim: "companion apps in
   development; pairing infrastructure live."
3. **AI Reloading Assistant ship date.** "v1.1" in earlier copy; not
   confirmed. Use "Coming Soon" rather than a version number.
4. ~~**Per-Pro AI Smart Import monthly cap.**~~ ✅ **RESOLVED**
   (2026-05-09). Cap is **20 imports per Pro user per calendar
   month**, set by `MONTHLY_CAP` in
   `cloud_worker/anthropic-proxy/src/quota.ts:43` (lowered from 30
   on 2026-05-08). Both engineering CLAUDE.md § 20 and this doc
   are aligned.
5. **Translation review.** Six languages scaffolded (English + DE /
   ES / FR / IT / RU); a native-speaker review hasn't happened. Don't
   advertise "fluent in 6 languages." Safer claim: "available in
   English; additional languages in beta."
6. **Marketing screenshots.** App Store / Play Store screenshots
   should be regenerated against the current Range Day (now with
   the Quick / Full toggle), Recipes-with-two-FABs and the new
   empty-state cards, the reticle-picker (now category-grouped
   with the "Classic" section header), the LoginScreen (now with
   the prominent "Continue as Guest" card), and the Resources
   drawer destination. The reticle-picker IP scrub also
   invalidates any older screenshot that shows a branded reticle
   name. **Don't show the biometric Settings toggle in marketing
   screenshots** — it's a quiet quality-of-life feature, not a
   pitched capability.

### Resolved in 2026-05-09 sweep (for diff context)

The following landed since the prior version of this doc and are
now reflected throughout:

- Range Day Quick / Full toggle (live).
- Recipe form Full-mode auto-collapses secondary sections, scrolls
  to user's last-active section on mode switch, ScrollController
  + onDrag keyboard dismissal fixed the auto-scroll-to-edge bug.
- Smart defaults: Favorites → Frequently used → general for every
  component picker (caliber, powder, bullet, primer, brass).
- Component favorites in drift (`UserComponentFavorites`, schema
  v25) — synced via Cloud Sync, dumped in JSON exports.
- `UserComponentFavorites` migration includes a one-shot
  copy-from-SharedPreferences for v1 users so existing favorites
  carry forward.
- Empty-state next-action cards on Recipes / Firearms / Brass
  Lots / Batches lists.
- Reticle picker grouping (Mil / MOA / Classic / Combat / Red
  dots).
- "Public domain" → "Classic" rename (display-time transform; DB
  unchanged).
- Glossary landing tiles ("New to reloading", "Range Day
  workflow").
- Beginner Mode functional (auto-tooltip emphasis, hides BYOK in
  AI Settings, defaults recipe form to Core).
- Authentication overhaul: first-launch Keychain clear, prominent
  Continue as Guest. Optional biometric unlock toggle exists in
  Settings → Account (real-account users only; not promoted in
  marketing — see § 2.5).
- SAAMI Specs moved out of Settings into the new Resources drawer
  destination.
- AI Smart Import cap aligned at 20/month between code, engineering
  doc, and marketing doc.
- Companion app phone-side bridges activated automatically on
  launch.
