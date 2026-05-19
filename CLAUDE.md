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

### VFP A2 precedent — gating a previously-free surface (cross-ref)

The "we'd lose customers" risk above is about *invented inputs*, not
*paywalls*. VFP Phase 3 operator decision **A2** deliberately
Pro-gates the previously-free Range Day visual-fidelity surface
(target / reticle / preview / zoom + all three visual tiers). That
regression risk was surfaced and is mitigated — not ignored — by the
**teaser-blur Option 2** pattern: free users still see and feel the
surface (controls live, the preview reacts in real time) but it is
Gaussian-blurred under an "Unlock with Pro" CTA; they are never
locked out. Operator-owned decision; the canonical mechanism +
per-surface map + pre-ship validation gates live in
`docs/PRO_GATING.md`. See also §0d (Plan Authority Hierarchy).

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

### Edge cases — ASK before flipping a label that might look weird

Title Case is the firm default. But for a small set of labels the
mechanical Title-Case form actively reads worse to users — usually
because the label is technically a fragment of a sentence ("Delete
my data", "Don't know your MV?", "What's a BC?") or because a
manufacturer phrase has its own established casing in the
shooting-community vernacular.

**When you find a label that fits Title Case mechanically but feels
off in context, surface it to the user before changing it.** The
30-second clarification cost is much lower than the cost of
shipping a label that reads as awkwardly formal. The user makes
the final call; engineering does not get to decide unilaterally
that a label is "too weird for Title Case."

Don't ask for the obvious cases — `Save`, `Cancel`, `Delete
Profile?`, `Find by My Scope` are all clearly Title-Case. Only
ask when (a) the label reads naturally as a sentence fragment or
question, OR (b) shooter-community convention overrides the
default rule (e.g. "Mil Tree" vs "Mil tree" — the latter is the
common shooter form).

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

### 5. Branches are last-resort, all work lands on main

**ONLY create a branch when it is absolutely necessary.** The
canonical case: multiple Claude Code agents running in different
worktrees that would collide on `main`. Outside that case, every
change goes directly on `main` — no feature-branch detour, no PR.

For the multi-worktree case (the common Claude Code setup): each
worktree's auto-generated `claude/<name>` branch is acceptable
because git requires different branches per worktree. When work
is verified and complete, fast-forward `main` from the parent
worktree:

```sh
git -C /Users/general/Development/Applications/LoadOut/ \
    merge --ff-only claude/<branch-name>
git -C /Users/general/Development/Applications/LoadOut/ \
    push origin main
```

Do NOT push the feature branch to remote. Do NOT open a PR.
Treat `/create-pr-command` and similar slash commands as questions
about whether the rule still applies — surface the rule and
confirm before acting. This overrides any "create a PR" guidance
in PROMPT.md files inside agent-delivered work packs.

If pushing `main` to remote fails on auth, surface the failure
and ask — don't quietly leave commits stranded on a feature branch
as a workaround.

### 6. Auto-commit and auto-merge to main, no approval gates

When work is verified (analyze clean, tests passing), commit
immediately. If on a non-`main` branch (a Claude Code worktree's
auto-generated branch), automatically fast-forward `main` to
absorb the commit AND push to `origin/main`. **Do NOT pause for
approval at any step.** The user watches `main` (locally + on
GitHub) for changes and reviews after the fact, not pre-commit.

Concrete pattern for this worktree:

```sh
# 1. Edit files (via Edit / Write tools)
# 2. Verify:
flutter analyze
flutter test
# 3. If clean, commit on the worktree branch:
git commit -F <message-file>
# 4. Fast-forward main:
git -C /Users/general/Development/Applications/LoadOut/ \
    merge --ff-only claude/<branch-name>
# 5. Push:
git -C /Users/general/Development/Applications/LoadOut/ \
    push origin main
```

All five steps happen in one turn. No "ready for approval?"
pause between them.

When to block instead of ship:

- **Analyze regression or test failure.** Don't commit. Surface
  the failure and fix or ask.
- **Auth blockers on the push.** Surface the failure and ask
  (per Rule 5's same edge case). Don't quietly leave commits on
  the worktree branch.
- **Genuinely destructive operations** (`git push --force`,
  branch deletion, dropping database tables, history rewrites,
  schema-incompatible migrations). Still need explicit
  authorization.
- **User-typed slash commands** like `/create-pr-command`. Still
  treated as questions (per Rule 5), surfaced and confirmed.

Read-only operations (analyze, test, status, log, diff, grep,
find) and edits also don't need approval — they ship as part of
the same auto-commit cycle.

## 0c. TARGET LABEL CHANGES REQUIRE EXPLICIT CONFIRMATION (firm rule)

**Never change a user-visible target catalog label without
surfacing the proposed change to the user FIRST and getting
explicit confirmation. Always show before / after examples
side-by-side.** Wait for the user to say "yes" (or to modify the
proposed copy). This rule was added 2026-05-14 after Phase 9.5
Group A's "Species, Size" animal rename — the user owned that
specific decision and wants the same explicit owner on every
future rename.

### Scope of the rule

The rule applies to any user-visible label sourced from or
derived from the target catalogs:

- `assets/seed_data/targets.json` — every row's `name` field.
- `assets/seed_data/target_racks.json` — every rack's `name`
  field AND every slot's `name` field (the slot list is the
  active-child picker).
- Any constant or helper that maps a catalog row to a display
  string at runtime (e.g. `_targetDropdownLabel` in
  `range_day_detail_screen.dart`, `_rackChildDimensionLabel`,
  `_rackKindLabel`).
- Any pre-filled `name` value the user sees in a Range Day
  session created from a catalog row.

### Why

Target labels are the load-bearing identifier for shooters. They
appear in pickers, on Range Day session rows, on shot exports, in
DOPE clipboard copies, in batch-naming flows ("18 × 30 IPSC @
500 yd"). Renaming "5-Plate KYL" to "Five-Plate Know-Your-Limits
Rack" might read more clearly to a new user but breaks every
workflow muscle-memory built around the original. The reloading
audience is precision-minded and notices label churn instantly.

The Phase 8 / Phase 9 / Phase 9.5 rewrites already touched every
target label (Phase 8: dropped duplicate-dimensions on IPSC;
Phase 9: animal size variants; Phase 9.5: animal "Species, Size"
format). Each was a deliberate decision the user owned; no future
rename should happen without the same explicit owner.

### How to apply

Before changing a label:

1. List the rows in scope ("all 48 animals", "all 6 IPSC", "the
   3 special-category apparatus rows", "the Texas Star slot
   names", etc.).
2. Show a side-by-side table:

   | Row id | Before | After |
   |---|---|---|
   | `bear_small` | `Small Bear` | `Bear, Small` |
   | `kyl_5_plate_circles` | `5-Plate KYL · Circles` | `5-Plate KYL Circles` |
   | … | … | … |

3. Include EVERY affected row in the table — not a "sample." If
   the change is uniform across 48 rows, show the first 3 plus a
   `…` row stating "remaining 45 follow the same pattern" plus
   the LAST row so the user can verify the pattern holds at both
   ends.
4. Wait for explicit confirmation. Treat ambiguous responses
   ("sure" / "looks fine" / "yes") as a YES; treat questions or
   modifications as the user wanting to negotiate the wording.
5. If the user proposes their own copy, render the diff again
   and re-confirm before writing the JSON.

### What does NOT need confirmation

- Bumping `version` in `manifest.json` after a data change
  (version is internal plumbing, not a label).
- Adding a brand-NEW target row with a NEW label (the user is
  reviewing the addition wholesale, not a rename).
- Changing the `shape_id` / `category` / dimensions / colorHex on
  an existing row (data-driven, not a label).
- Internal identifiers — `shape_id`, `id` slug, `manufacturer`
  string. Those are not user-visible.
- Per-row computed labels that read directly from the catalog
  `name` without modification (e.g. the picker dropdown that
  passes `t.name` through unchanged isn't a separate label to
  confirm — the catalog `name` is the source of truth).

The rule is about user-visible label CHURN on already-shipped
content, not about data-driven changes or new content.

## 0d. PLAN AUTHORITY HIERARCHY (firm rule)

When executing a multi-phase plan the operator has designated the
source of truth (currently
`~/Downloads/VISUAL_FIDELITY_PROGRAM_PLAN_V6_11.md`, "V6.11"), and a
conflict arises between that plan and this CLAUDE.md:

- **The plan supersedes CLAUDE.md for any conflict encountered
  during plan execution.** V6.11's operator-ratified decisions
  (e.g. the A2 Pro-gating posture) override pre-existing CLAUDE.md
  statements for the scope the plan governs.
- **CLAUDE.md remains authoritative anywhere the plan is silent.**
  General project conventions — privacy posture (§13), Title Case
  (§0a), the no-placeholder rule (§0), target-label confirmation
  (§0c), work style (§0b) — continue to apply wherever V6.11 does
  not speak.
- **Conflicts are surfaced, never silently resolved.** Per the §0.5
  grep-verify discipline, a plan-vs-CLAUDE.md conflict is reported
  to the operator and ruled before code lands; CLAUDE.md is then
  realigned to the ruling. The reverse (CLAUDE.md silently
  overriding the plan, or the plan silently overriding CLAUDE.md
  without a surfaced ruling) never happens.

This codifies the precedence the operator established across VFP
Phase 1–3. It is scoped to operator-designated plan execution;
outside that, CLAUDE.md is the unqualified authority.

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
- `Targets` — Range Day target catalog. Carries `name`, `category` enum
  (`circle | square | rectangle | ipsc | animal | special` — Phase 9.5
  Group A, v39), optional `shapeId` (SVG dispatch key for animal /
  special apparatus), `widthIn` / `heightIn`, `colorHex`, per-target
  `centerPoint` (anchor fractions for aim point — Phase 7a), and
  `svgScaleFactor` (silhouette overflow scale — Phase 7a). 91 rows in
  the seeded catalog. Animal rows use a uniform LEFT-facing convention
  (Phase 9.5 Group B) so `centerPoint.horizontal_from_left = 0.6`
  lands behind the front shoulder for every species.
- `TargetRacks` — multi-target rack catalog. Carries rack envelope
  (`name`, `description`, `rackKind`, `totalWidthIn`, `totalHeightIn`,
  `notes`) plus `slotsJson` — a JSON-encoded `List<RackSlot>` via the
  drift TypeConverter `RackSlotsConverter` (Phase 9.5 Group C, v40).
  Each `RackSlot` is one shootable apparatus inside the rack (a
  popper, a KYL plate, a Texas Star plate, etc.) with its own
  position, category, dimensions, offset, and color. The v40
  migration dropped the legacy `TargetRackChildren` FK child table
  entirely. 9 racks in the seeded catalog. See
  `lib/database/rack_slot.dart` for the value type + converter.
- `Reticles`, `Scopes`, `ScopeReticleOptions` — v2.3 scope catalog
  (see § 30 / § 31).
- `FirearmComponents` — Custom-build firearm components (§ 27).

User data (writable):

- `CustomComponents` — `kind` + `name` (unique together), notes, `createdAt`.
  User-added powders/bullets/primers/brass/cartridges. They appear alongside
  reference items in dropdowns.
- `UserLoads` — load recipe rows (caliber, powder, charge, bullet, primer,
  brass, COAL, CBTO, seating depth, primer depth, shoulder bump, mandrel,
  date established, notes, timestamps).
- `UserFirearms` — name, manufacturer, model, type, action, caliber, barrel
  length, twist rate, shotsFired, optional `referenceFirearmId` linking back
  to `FirearmsRef`, notes, timestamps. Plus custom-build component
  fields (§ 27).
- Range Day session rows (`RangeDaySessions`, `ShotImpacts`, etc.) and
  the other user-data tables for batches, brass lots, load development,
  component inventory, ballistic profiles, etc. — see the table list
  in `@DriftDatabase(tables: [...])` for the full set.

JSON-encoded text columns are used wherever we need a list (aliases, calibers,
compatibleWith). Decode with `json.decode(...) as List<dynamic>`. For the
`TargetRacks.slotsJson` column the TypeConverter does the work — callers
see a typed `List<RackSlot>` and never touch the raw JSON.

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
    rack_slot.dart                 RackSlot value type + RackSlotsConverter
                                   TypeConverter for TargetRacks.slotsJson
                                   (Phase 9.5 Group C, v40)
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

**VFP exception (operator decision A2, see §0d).** The Range Day
visual-fidelity surface — target / reticle / preview / zoom + all
three visual tiers — IS Pro, but enforced via **teaser-blur**
(`BlurredProTeaser`), not a hard lock: free users see it
blurred-but-interactive, never excluded from the screen. This is
the one sanctioned carve-out from "anonymous users get every core
feature"; it does not change the rest of the free-core posture (the
auth-gate prohibition still holds — this is a Pro gate, not an auth
gate). Canonical detail: `docs/PRO_GATING.md`.

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
  | Internal Ballistics Calculator (interior-ballistics pressure / MV predictor) | Resources directory tile + bottom-of-Ballistics-Calculator entry button; both routes through `ensurePro` and the screen wraps its body in `ProGate`. Service in `lib/services/ballistics/internal_ballistics.dart`; full description in § 24. |
  | Custom fields (unlimited) | recipe / firearm form custom-field affordances |
  | VFP visual surface — Range Day target / reticle / preview / zoom + all 3 visual tiers (operator decision A2, §0d) | **teaser-blur Option 2** via `BlurredProTeaser` (`lib/widgets/blurred_pro_teaser.dart`) — free users see it blurred-but-interactive, NOT a lock tile. Per-surface map + pre-ship gates: `docs/PRO_GATING.md`. Distinct mechanism from the hard `ProGate`/`ensurePro` lock-tile used by every row above. |

- **Linking RevenueCat to Firebase Auth:** the auth-state listener
  in `_AuthGate` calls `PurchasesService.setAppUserId(user.uid)` on
  sign-in and `setAppUserId(null)` on sign-out. This means a user
  who buys Pro on iOS sees Pro on Android when they sign in with
  the same Firebase account.

- **Setup steps for App Store Connect, Play Console, and the
  RevenueCat dashboard:** see `REVENUECAT_SETUP.md`.

### Pro-gating UX pattern (two mechanisms — pick the right one)

There are now TWO Pro-gating mechanisms; do not mix them up:

- **`BlurredProTeaser` — teaser-blur Option 2 (canonical for VFP
  visual surfaces).** Renders the Pro content live but
  Gaussian-blurred under a CTA; controls stay interactive and the
  blurred preview reacts in real time; commit/expand actions route
  through `ensurePro`. Use for any VFP Range Day
  target/reticle/preview/zoom surface (A2). Soft, exploratory,
  conversion-oriented.
- **`ProGate` / `ensurePro` — hard paywall (everything else).**
  Replaces the feature with a lock tile (or blocks the action and
  pushes the paywall). Use for non-VFP Pro features (the table
  rows above).

Legal/compliance UI (e.g. the §30 reticle interoperability caption)
ALWAYS renders clear regardless of Pro state — it carries
compliance value, it is not Pro content to tease. Gated-content
CTAs render as a single coherent semantics node (`container` +
`excludeSemantics`) so screen readers announce one phrase. The
canonical mechanism reference, per-surface wiring map, scoping
principle, test discipline, and pre-public-ship validation gates
(device-perf + post-D11 widget matrix) live in
`docs/PRO_GATING.md`; CTA copy is operator-owned and reviewed at
launch-readiness (placeholders ship clearly marked until then).

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
  (`--delete-conflicting-outputs` is deprecated on current build_runner —
  the bare `build` invocation does the right thing.)
- `schemaVersion` lives in `AppDatabase` (currently **`40`** as of Phase
  9.5 Group C, 2026-05-14). Bumping it requires adding a
  `MigrationStrategy.onUpgrade` clause that brings older installs up
  to date.
- Recent reference-data-only migrations used **drop+recreate** (safe
  pre-launch since no installed users own row content in those tables):
  - **v39** (Phase 9.5 Group A): `Targets.shape` text column dropped;
    `Targets.category` enum column added (closed set `circle | square |
    rectangle | ipsc | animal | special`). Catalog seed re-shipped with
    the new vocabulary.
  - **v40** (Phase 9.5 Group C): legacy `TargetRackChildren` FK child
    table dropped entirely; each rack's children now ride inline as a
    JSON list on `TargetRacks.slotsJson` (drift TypeConverter
    `RackSlotsConverter`). `RangeDaySessions.rackChildPosition` column
    unchanged — it was always a plain `int` indexing into the children
    list, never an FK.
- Pre-Phase-9.5 migrations (v37 / v38) added additive columns to
  `Targets` (`center_point` anchor fractions; `svg_scale_factor`).
  Schema bumps after the pre-launch reference-data wipe rule expires
  will need additive `addColumn` migrations with the `_columnsOf`
  defensive pattern — see existing examples in `database.dart`.
- Reference tables are populated by `SeedLoader.seedIfNeeded()` on first run.
  The check is `Cartridges` row count == 0. If you change the seed data
  shape, an existing user's DB will keep the old data — handle via migration.
- List-valued fields (`aliasesJson`, `calibersJson`, `compatibleWithJson`)
  are JSON-encoded `text` columns. Decode at the repository boundary.
- For columns with a **structured** JSON shape (not just a flat list of
  strings), use a drift `TypeConverter` rather than ad-hoc decode at
  the boundary. `RackSlotsConverter` is the reference pattern: extends
  `TypeConverter<List<RackSlot>, String>`, lives in its own
  `lib/database/<thing>.dart` file (NOT inside `database.dart`) so
  consumers can import the value type without dragging the drift code
  along, and ships with a round-trip + degenerate-input regression
  test (`test/rack_slot_converter_test.dart`).
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
- **Crash reporting (Firebase Crashlytics, opt-OUT, defaults to ON)** —
  see § 29. The runtime sends stack traces + privacy-scrubbed context
  (route name, schema version, app version, platform, anonymous-vs-
  signed-in flag, row IDs) to Crashlytics whenever an unhandled error
  fires. **Reports never include user-typed strings** (recipe names,
  firearm names, notes, brass-lot labels), Firebase UIDs, or any row
  CONTENT — only stable identifiers. The default flipped from OFF to
  ON on 2026-05-10 after repeated red-screen crashes that engineering
  couldn't triage without telemetry; users who want strict no-network-
  egress can disable collection in Settings → Privacy & Data and the
  CrashReporter no-ops every public method. Breadcrumbs (route history,
  log lines) live in-process until a crash actually fires — a normal
  session uploads nothing.
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
- Crashlytics ships and is on-by-default for fresh installs (see § 29);
  general analytics (Mixpanel, GA, etc.) remain explicitly off-limits
  per § 13's privacy promise — do not propose adding them.

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
| Apple Watch status | **v1 shipping.** Four-page TabView: Stage Log (motion + swipe + manual shot capture), Timer (PRS stage timer with par-time alerts + quiet mode), DOPE (drop chart from `dope` payload, scrollable via digital crown, with active-load + firearm-glance banners on top), About (app version + iPhone link state + read-only sensitivity preset). Inbound `dope` / `active_load` / `firearm_glance` decode via `DopeViewModel`; outbound `log_shot` and `timer_event` emit through `WatchConnectivityManager.send(path:payload:)`. Tests in `ios/RunnerWatchAppTests/` cover the decoder, motion-detector preset table, timer state machine, and routing. **Operator step still required:** add the watch target to Xcode per the README — see § 15 below. |
| Wear OS status | **v1 shipping.** Five-screen Compose for Wear OS UI: Stage Log (motion + button + manual shot capture), Timer (PRS stage timer with par-time alerts + quiet mode), DOPE (drop chart from `dope` payload, scrollable, with active-load + firearm-glance banners), Firearm Glance (active firearm + barrel-life summary), Settings (read-only sensitivity preset). Inbound `dope` / `active_load` / `firearm_glance` decode via `bridge/Payloads.kt`; outbound `log_shot` / `timer_event` emit through `WatchAppState`. Tests under `android/wear/src/test/` and `android/wear/src/androidTest/` cover the decoder, motion-detector preset table, timer state machine, and routing. |

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
French, Italian, Russian, Finnish, Swedish, Norwegian Bokmål, Polish, Czech,
Brazilian Portuguese, Hungarian, Danish, and Dutch** (15 languages total);
English is the source of truth. The original six (en/de/es/fr/it/ru) are the
launch pack; the remaining nine are machine-drafted and flagged
`TRANSLATOR-REVIEW` in their ARB headers — see "Known follow-ups" below.

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
  app_fi.arb                       Finnish (machine-drafted)
  app_sv.arb                       Swedish (machine-drafted)
  app_nb.arb                       Norwegian Bokmål (machine-drafted)
  app_pl.arb                       Polish (machine-drafted)
  app_cs.arb                       Czech (machine-drafted)
  app_pt.arb                       Portuguese base fallback (mirrors pt_BR; see note)
  app_pt_BR.arb                    Brazilian Portuguese (machine-drafted)
  app_hu.arb                       Hungarian (machine-drafted)
  app_da.arb                       Danish (machine-drafted)
  app_nl.arb                       Dutch (machine-drafted)
  app_localizations.dart           GENERATED facade — never edit
  app_localizations_*.dart         GENERATED per-locale subclass — never edit
```

The generated `*.dart` files are produced by `flutter gen-l10n` automatically
on `flutter pub get` / `flutter run` because `flutter: generate: true` is set
in `pubspec.yaml`. They are NOT git-ignored (yet) — if a build environment
needs them they're already present, but they should be regenerated on every
ARB edit.

#### Country-variant ARBs (`pt_BR`)

`gen_l10n` requires a base-language ARB whenever a country-variant ARB is
present, so `app_pt_BR.arb` ships alongside an `app_pt.arb` whose contents
currently mirror the Brazilian pack. European Portuguese reloading
vocabulary differs from Brazilian (cartucho vs. estojo, projéctil vs.
projétil), so the base file is also flagged TRANSLATOR-REVIEW until a
native-speaker pt-PT reloader adapts it. At runtime, `pt_BR` users see
the Brazilian content; only generic `pt` device locales fall back to
`app_pt.arb`.

The `LocaleService.resolvedLocale` getter (`lib/services/locale_service.dart`)
splits the underscore form on its way into `MaterialApp.locale` so
`pt_BR` becomes `Locale('pt', 'BR')` instead of an unmatched
`Locale('pt_BR')` that silently falls back to English.

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
  required before launch advertising "available in 15 languages".
- **The nine languages added in the 15-language expansion (Finnish,
  Swedish, Norwegian Bokmål, Polish, Czech, Brazilian Portuguese,
  Hungarian, Danish, Dutch) are entirely machine-drafted.** Every ARB
  carries a `// TRANSLATOR-REVIEW` `@@x-comment` header naming the local
  shooting magazine / community to consult, and every reloading-specific
  term (powder, primer, brass, COAL, CBTO, BC, MOA, MIL, FPS) needs a
  native-speaker reloader review before LoadOut can advertise "available
  in 15 languages." Specifically tricky calls a reviewer should focus on:
  - Polish: `elaboracja` for "handloading" — verify it's the natural noun
    vs. the verb `elaborować`.
  - Czech: `přebíjení` vs. alternative phrasings.
  - Brazilian Portuguese: `recarga` (noun) vs. `recarregar` (verb), plus
    `projétil` (BR) vs. `projéctil` (PT) — the latter affects whether
    `app_pt.arb` can do double duty for European Portuguese users or
    needs its own pt-PT pass.
  - Hungarian: `újratöltés` for "reloading" — confirm against Kaliber
    magazine usage.
  - Norwegian Bokmål: `ladning` — Norwegian shooters often write the
    English `reloading` interchangeably; the magazine convention is what
    we should align with.
  - All Nordic packs: case on multi-word labels like "Skip" / "Get
    Started" / "Import From Spreadsheet" — Title Case in English maps
    awkwardly to languages that capitalize fewer words natively. Treat
    Title Case as a UI signal we want to keep on prominent buttons even
    when not idiomatic.
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
| Powder reference | `lib/services/ballistics/powder_burn_rates.dart` (`kPowderBurnRates`, 50 powders — 33 rifle/dual validated against the Pass 2 anchor corpus) |
| Screen | `lib/screens/ballistics/internal_ballistics_screen.dart` |
| Tests | `test/internal_ballistics_test.dart` (149 tests) + `test/internal_ballistics_screen_advisory_test.dart` (9 widget tests) |
| Validation report | `docs/internal_ballistics_validation.md` (Pass 2: 59-anchor corpus + per-family error bands + magnum-bias deep-dive) |
| Doc-table generator | `test/internal_ballistics_doc_table.dart` (regenerates the validation table; not in the default test glob) |
| Pro gate | yes — entry routes through `ensurePro(context)` and the screen wraps its body in `ProGate` |
| Entry points | Resources directory tile + bottom-of-screen button on the external Ballistics Calculator |

### Model

Implements a published 1962-derived (revised 1980) interior-ballistics
estimation method, the same simplified model that backed the original
Sierra and Lyman desktop programs in the 1980s. The simplification
trades the full Lagrange gas-dynamics treatment (what GRT does) for a
small set of empirical coefficients fit against published reloading
manual data. Inputs:

- Cartridge case capacity (grH₂O), case length (in)
- Powder name (looked up in `kPowderBurnRates`; loads with unknown
  powders return null — never silently substituted)
- Charge weight (gr)
- Bullet weight (gr), diameter (in), COAL (in), optional length (in)
- Barrel length (in), bore diameter (in)

Outputs: predicted muzzle velocity (fps), predicted peak pressure
(psi), loading density (%), expansion ratio, burn-completion %, and
(Pass 2 deep-dive) `BiasZoneAdvisory?` — non-null when the load
falls into a documented high-bias regime (magnum-class case > 75
grH₂O OR slow powder Q < 70). Drives the per-prediction yellow
note in the result card.

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
cites its source. Pass 2 audited every entry, fixed two ordering
drifts (HP-38, N133), and added a normalisation cross-check
regression test (`Pass 2: burn-rate normalisation cross-check`
group in `internal_ballistics_test.dart`).

### Validation results (Pass 2 — 59-anchor corpus)

Tested against 59 published anchor loads (HRDC, Hornady 11th, Sierra
2024, Berger 2024, Vihtavuori 2024, Alliant 2023, IMR 2024, Western
Powders 2018), grouped by cartridge family:

| Family | n | MV bias | MV MAE | MV p95 | P bias | P MAE | P p95 |
|---|---|---|---|---|---|---|---|
| rifle_small (.222 / .223 / .22-250 / 6mm PPC) | 12 | +7.8% | 9.3% | 14.0% | +3.0% | 8.2% | 28.9% |
| rifle_medium (.243 / .260 / 6.5 CM / .270 / .308 / .30-06 / 6mm BR / 6mm CM) | 27 | -2.4% | 4.6% | 10.2% | -7.4% | 13.3% | 26.1% |
| rifle_magnum (6.5 PRC / 6.5x284 / 7mm RM / 7mm PRC / .300 WM / .300 PRC / .338 LM) | 20 | -16.2% | 16.2% | 33.3% | -33.2% | 33.2% | 40.4% |

**Mid-rifle (rifle_small + rifle_medium, n=39): MV MAE 6.0%, P MAE
11.7%** — within the model's headline ±10% MV / ±15% pressure claim
on most rows. Magnum-rifle systematically under-predicts (modern
temp-stable progressive-burning slow powders in big cases drift
outside the 1960s-era stick-powder calibration corpus). The
predictor gets the ORDERING right (heavier bullet = slower; more
powder = faster) but the magnitude is biased low by 15-25% MV /
25-40% pressure for these loads.

**Per-powder coverage (Pass 2):** every rifle / dual powder in
`kPowderBurnRates` appears in at least one validation anchor — 33
powders covered, 5 documented as `intentionallyUncovered` (Lil'Gun,
2400, H110, W296, H50BMG — see § 6 of the validation report for
reasons). The `Pass 2: per-powder coverage` regression test catches
the failure mode where a powder is added to the table but never
validated.

### Magnum-bias discriminator + per-prediction advisory UX (Pass 2)

Pass 2's deep-dive identified that the magnum-class bias is driven
by **two independent factors**, not a single "magnum cartridge"
classifier:

- **Pressure bias** is primarily **case-capacity-driven**. A .300 WM
  + IMR 4350 (medium powder) still under-predicts pressure by 35%,
  same as .300 WM + H1000 (slow powder). Cause: large cases sit at
  LD 70-80%, where the model's `LD^1.5` term geometrically reduces
  the prediction by ~25% vs the LD 85-95% mid-rifle band.
- **MV bias** is primarily **powder-driven**. Q=100 medium powder
  in any cartridge → mild MV error; Q=50 very-slow powder in any
  cartridge → -20-25% MV error. Cause: the burn-completion
  saturation curve was calibrated against 1960s-era stick powders;
  modern temp-stable progressives burn cleaner.

The `_computeBiasAdvisory` function in `internal_ballistics.dart`
returns a `BiasZoneAdvisory?` with `BiasZoneCause.magnumCase`
(case > 75 grH₂O), `slowPowder` (Q < 70), or `combined` (both). The
screen renders an amber-bordered `BiasAdvisoryCard` under the result
card whenever the advisory is non-null. The persistent yellow
disclaimer banner at the top of the screen stays as-is (every
prediction sees it); the bias advisory is LOAD-SPECIFIC and only
surfaces when the load falls into a documented high-bias regime.
Copy is fixed and regression-tested:

| Cause | Headline | What the user sees |
|---|---|---|
| `magnumCase` | "Magnum-Class Cartridge" | Pressure runs 25-35% LOW; treat as floor, not ceiling |
| `slowPowder` | "Very Slow Powder" | MV runs 10-20% LOW; cross-check manual |
| `combined` | "Magnum + Slow Powder — Combined Bias" | Both stack: 15-25% MV LOW, 25-40% pressure LOW |

Discriminator regression tests live in `internal_ballistics_test.dart`
(`Pass 2: bias-zone discriminator triggers correctly` group). Widget
rendering tests live in `internal_ballistics_screen_advisory_test.dart`.

### Calibration anchors (4 of 59 — full corpus in validation report)

| Load | Manual MV | Pred MV | Δ% MV | Manual P | Pred P | Δ% P |
|---|---|---|---|---|---|---|
| .308 Win, 168gr SMK, 44.0gr Varget | 2700 fps | 2608 | -3.4% | 60900 psi | 68047 | +11.7% |
| .30-06, 165gr SST, 56.0gr IMR 4350 | 2820 fps | 2844 | +0.8% | 58800 psi | 56500 | -3.9% |
| 6.5 CM, 140gr ELD-M, 41.5gr H4350 | 2710 fps | 2550 | -5.9% | 60100 psi | 53866 | -10.4% |
| .223 Rem, 55gr FMJ, 26.0gr H335 | 3240 fps | 3450 | +6.5% | 54300 psi | 55307 | +1.9% |

Full 59-row table + per-anchor analysis lives at
`docs/internal_ballistics_validation.md`.

### Privacy / safety posture

The screen renders a persistent yellow "Estimation Tool — Not a
Load-Data Substitute" banner at the top, every visit, with no
dismiss option. Reloaders who acted on a "below max" model
prediction without verifying could blow up their rifle, so the
disclaimer is load-bearing UI. The result card includes a coarse
SAAMI-band gauge ("Below typical SAAMI max" / "Approaching SAAMI
max" / "At or above — verify") that's advisory only — it doesn't
know the user's specific cartridge max. The Pass 2 per-prediction
`BiasAdvisoryCard` (above) is an additional load-specific warning
that surfaces only when needed.

The calculator is stateless across visits (no profiles, no
persistence) so a reloader doesn't accidentally trust a stale
prediction from a previous session. Per CLAUDE.md § 0, every input
field starts EMPTY; the result panel only renders after the user
fills in every required field and taps "Predict Pressure & MV".

### Scope

The model applies to centerfire cased cartridges (rifle + pistol),
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

## 26. Component inventory (intentionally not marketed)

On-hand quantity tracking for the consumable components a reloader
keeps in the cabinet — powder (in grains), primers (count),
bullets (count), brass cases (count), and finished factory
cartridges (rounds). Closes the "Reloader's Log has this and we
don't" gap **without** making inventory-management a stated focus
of LoadOut. The placement is the load-bearing decision: this
sits under the **Resources menu**, NOT the bottom nav, NOT the
home screen, NOT onboarding. Users who want it find it; users
who don't never see a marketing nudge.

| | |
|---|---|
| Tables | `ComponentInventory` (master rows), `ComponentInventoryAdjustments` (audit log) |
| Schema added in | v32 |
| Repository | `lib/repositories/component_inventory_repository.dart` (`ComponentInventoryRepository`) |
| List screen | `lib/screens/inventory/inventory_list_screen.dart` (`InventoryListScreen`) |
| Form screen | `lib/screens/inventory/inventory_form_screen.dart` (`InventoryFormScreen`) |
| Quick-adjust dialog | `lib/screens/inventory/inventory_adjust_dialog.dart` (`InventoryAdjustDialog`) |
| Wiring | `lib/app.dart` provides `ComponentInventoryRepository`; `lib/screens/resources/resources_screen.dart` adds a "Component Inventory" tile pointing at `InventoryListScreen` |
| Export / Cloud Sync | `lib/services/export_service.dart` dumps both tables under `'component_inventory'` and `'component_inventory_adjustments'`, in that order so the FK on the adjustments ledger lands cleanly during import. Both tables are listed in `kUserDataTableOrder` and wiped by `AppDatabase.wipeUserData()`. |
| Pro gate | none — inventory is free, mirroring the rest of the core tracking surfaces |
| Tests | `test/component_inventory_repository_test.dart` — 20 tests covering insert / update / delete cascade / adjust transactional contract / setQuantity / watch streams / findByName fallback / deductForBatch best-effort behaviour / unit derivation / wipe |

### Schema shape

```dart
ComponentInventory {
  int id, String kind, String componentName, int? referenceId,
  double quantity, String unit, double? unitCostUsd,
  double? reorderThreshold, String? lotNumber, DateTime? openedAt,
  String? notes, DateTime createdAt, DateTime updatedAt,
}
ComponentInventoryAdjustments {
  int id, int inventoryId (FK), double delta, String reason,
  int? batchLogId, String? notes, DateTime createdAt,
}
```

`kind` discriminator: `'powder' | 'primer' | 'bullet' | 'brass' |
'cartridge'`. `unit` is auto-derived from kind by the repository
on insert (`'gr'` for powder, `'ct'` for primer / bullet / brass,
`'rd'` for factory cartridges). `reason` discriminator: `'manual'
| 'batch' | 'adjustment' | 'opened'`.

### Repository contract

Every quantity change goes through `adjust(id, delta, reason, ...)` or
`setQuantity(id, newQuantity, reason)`. Both wrap the master-row
update AND the adjustment-ledger insert in a single
`db.transaction(...)` so the running quantity and the audit log
can never drift apart. Negative deltas clamp the master row at
zero but the ledger keeps the actual delta verbatim — the audit
trail tells the truth even when the math underran.

`delete(id)` cascades through the adjustments table inside one
transaction. We don't enable SQLite FK enforcement; without the
manual cascade the audit log would accumulate orphan rows.

### Auto-deduct from batches — DEFERRED

The repository exposes a `deductForBatch(batch, recipe: ...)`
helper that walks a `BatchRow` and emits the right adjustments
(powder grains × round count, one primer per round, one bullet
per round, optionally one brass case per round when `freshBrass:
true`). Best-effort: missing inventory rows are skipped silently
so the batch flow can never fail because of an untracked
container.

It is NOT wired into the existing batch-completion flow as of
schema v32. The batch form is an AutoSave-driven multi-field
form; calling `deductForBatch` from AutoSave would deduct on
every keystroke. The batch-detail screen's "Record Firing"
dialog tracks rounds **fired**, not rounds **loaded** — wrong
trigger point for inventory deduction. A clean integration needs
either a new "Mark Loaded" one-shot button on the batch detail
screen OR a transition guard ("first time `loadedAt` goes from
null to non-null, deduct"); both are larger surface changes than
v1 warranted. The repository helper is ready for whoever wires
the trigger; the manual "Quick Adjust" affordance on the
inventory list and form covers the gap in the meantime.

### Privacy / Cloud Sync posture

Same as every other user-data table (CLAUDE.md § 13). Stays on
device. Gets dumped into the local export blob and the encrypted
Cloud Sync payload. Never touches a LoadOut-operated backend.
The audit log can grow unbounded — a serious reloader builds a
multi-decade history of how much powder they burned through and
prefers a slow-growing audit log over a truncated one. Per-row
size is small (<200 bytes) so even ten years of data is a
rounding error inside the encrypted blob.

### Why it's not on the bottom nav

Per the user's directive when this feature landed: "implement it
well, but do not market it. It lives under the Resources menu,
not as a top-level nav item. Goal is to remove the 'Reloader's
Log has this and you don't' complaint without making
inventory-management a stated focus of LoadOut." When updating
the bottom nav, the home-screen tiles, onboarding, marketing
copy, or any other discovery surface, **do not promote
inventory**. The Resources tile is the only sanctioned entry
point.

## 27. Custom-build firearms

The firearm form (`lib/screens/firearms/firearm_form_screen.dart`)
ships a top-level **Build Type** toggle: `Factory Rifle` or
`Custom Build`. Factory mode is the long-standing flow (catalog
pick or freeform manufacturer/model entry). Custom Build mode swaps
the manufacturer/model fields for a **Components** panel — seven
autocomplete pickers backed by a real-product catalog.

| | |
|---|---|
| Schema additions (v33) | `FirearmComponents` table (catalog), 8 new columns on `UserFirearms` (`isCustomBuild` BOOL, plus `chassisName`/`barrelName`/`triggerName`/`buttstockName`/`muzzleBrakeName`/`suppressorName`/`bipodName` as nullable TEXT) |
| Catalog seed | `assets/seed_data/components/{chassis,barrels,triggers,buttstocks,muzzle_brakes,suppressors,bipods}.json` — ≈220 currently-shipping products from the dominant precision-rifle / NRL-Hunter / PRS / hunting brands |
| Service | `lib/repositories/firearm_component_repository.dart` (`FirearmComponentRepository`) |
| Form widget | `_componentsSection` in the firearm form, rendering seven `_ComponentPicker` instances |
| Tests | `test/firearm_component_repository_test.dart` (kind round-trip, sort order, attribute decoding, label resolution, bad-JSON defence) |
| Pro gate | None — same posture as the firearm form itself; custom-build is a ergonomic affordance, not a paid feature |

### Catalog scope (seven kinds, ≈220 products at v33 launch)

| Kind | Anchors |
|---|---|
| Chassis | MDT (ACC, XRS, HS3, ESS, LSS, TAC21), KRG (Bravo, Whiskey-3, X-Ray), MPA, Foundation, XLR, Manners, Grayboe, Kelbly's, Cadex, Spuhr, JP — 26 entries |
| Barrel | Bartlein, Krieger, Brux, Proof Research (Sendero / CF-SR), Hawk Hill, Lothar Walther, Shilen, Benchmark, Pac-Nor, Rock Creek, Lilja, Christensen Arms, McGowen, Faxon, Preferred Barrel Blanks, Border, True-Flite, Liberty, Douglas, E.R. Shaw, Helix 6 — 28 entries |
| Trigger | TriggerTech (Diamond / Special / Primary), Timney (Calvin Elite, HIT, Two-Stage), Jewell, Bix'n Andy, Geissele Super 700, Rifle Basix, Anschütz — 27 entries |
| Buttstock | McMillan (A3 / A4 / A5 / Game Warden / Edge), Manners (T1 / T2 / T4 / T5 / T6), Magpul (PRS Gen3, Hunter 700), KRG, H-S Precision, Bell & Carlson, Grayboe, Foundation, Boyd's, Stocky's, Tac Ops — 35 entries |
| Muzzle brake | Area 419 (Hellfire / Sidewinder), APA (Little Bastard / Fat Bastard), Insite Arms, TBR, MDT, CMT, Erathr3, Patriot Valley, Surefire, Precision Armament, Badger, JEC, Holland's, JP — 24 entries |
| Suppressor | SilencerCo (Omega / Hybrid / Harvester / Saker / Switchback), Surefire (RC2 / SOCOM), Thunder Beast Arms (Ultra / Magnus / 30P-1 / Take Down 22), Dead Air (Sandman / Nomad / Wolfman / Mask), Sig (SLX / SLH338 / MOD-X 9), HUXWRX (HX-QD / Ventum / Flow / RAD), YHM, Q (Trash Panda / Half Nelson), Energetic Armament, Banish, CGS, Rugged — 49 entries |
| Bipod | MDT (Ckye-Pod, GroundPod, M0SR), Atlas (BT10 / BT47 / BT65), Harris (S-BRM / S-LM / 1A2-25C), Accu-Tac (FC-G2 / BR-4 / HD-50), Magpul, Spartan Precision (Javelin Pro Hunt / Ascent), Phoenix Precision, Hatch, Wiebad, KMW, Spuhr — 28 entries |

The catalog ships a `FirearmComponentRepository.byKind(...)` lookup
that drives each picker. Each row carries an `attributesJson` blob
of category-specific metadata (action footprints, material, pull
range, mounting types, etc.) that the picker subtitle can surface
without forcing the schema to model every category-specific shape.
Adding a new attribute later requires only a JSON-seed change.

### Form behaviour

- **The two modes share every other field.** Caliber, barrel length,
  twist rate, optic, reticle, sight height, sight scale calibration,
  zero atmosphere, notes, and shots fired are common to both modes
  so toggling Factory ↔ Custom mid-edit doesn't lose data.
- **Free-text override is always allowed.** If the user's product
  isn't in the catalog they type the name freeform; the picker saves
  whatever string they typed. Catalog membership is a hint, not a
  constraint.
- **Custom builds force `referenceFirearmId = null` on save.** A
  custom build by definition has no factory-catalog parent; the form
  enforces the mutual exclusion in `_buildCompanion`.
- **Save/dispose include the seven new controllers.** The list-add
  pattern in `initState` / `dispose` matches the existing controller
  block so a future field addition follows the same path.

### Range Day integration

Range Day's `_applyFirearmDefaults(...)`
(`lib/screens/range_day/range_day_detail_screen.dart`) reads the
fields it cares about (default zero range, sight height, twist rate,
`opticsId`, `reticleId`) directly off the `UserFirearmRow`. Those
fields are populated identically by both build types, so picking a
custom-build rifle on Range Day pulls the scope and reticle the same
way picking a factory rifle does — no extra wiring required.

### Privacy posture

Same as every other reference catalog. The `FirearmComponents` rows
ship in `assets/seed_data/` (or downloaded by SeedUpdater), are
read-only at runtime, and contain only public product information —
no identifiable user data.

### Adding to the catalog

Edit the matching `assets/seed_data/components/<kind>.json` file
(flat array of objects), then run `flutter test
test/assets_present_test.dart` to verify the file is reachable
through `rootBundle` (per CLAUDE.md § 12a — pubspec asset rule). The
seed loader's reseed-when-empty + force-reseed-via-SeedUpdater
machinery will pick up the new content on next launch.

## 28. Live seed updates (Firebase Storage)

LoadOut updates its reference catalog (cartridges, powders, bullets,
optics, components, etc.) without an App Store / Play Store release
by republishing the bundled JSON to Firebase Storage and letting
the in-app `SeedUpdater` pick it up on next cold start. **Whenever
you change ANY file under `assets/seed_data/`, you must also push
the change to the bucket.** This section is the workflow for doing
that safely.

### Architecture

| | |
|---|---|
| Bucket | `gs://loadout-precision-reloading.firebasestorage.app` |
| Storage prefix | `seed_data/` (manifest + payloads); `seed_data/archive/` (versioned snapshots) |
| Rules | `storage.rules` → `match /seed_data/{path=**}` allow public read, authenticated write |
| Manifest | `seed_data/manifest.json` declares each file's `version` and `filename` |
| Local mirror on device | `<applicationDocumentsDirectory>/seed_data/<...>` (written by `SeedUpdater`) |
| Bundled fallback | `assets/seed_data/` (read when local mirror is missing or stale) |
| Service | `lib/services/seed_updater.dart` — one HTTP fetch per stale file on every launch |
| Whitelist | `allowedKeys` constant in `seed_updater.dart` — every manifest key must appear here, or the runtime drops it silently. The `seed_updater_allowlist_test.dart` regression catches mismatches |

### Bucket layout

```
gs://loadout-precision-reloading.firebasestorage.app/
└── seed_data/
    ├── manifest.json                    ← always points to current versions
    ├── cartridges.json
    ├── powders.json
    ├── bullets.json
    ├── ... (12 more top-level files)
    ├── components/
    │   ├── chassis.json
    │   ├── barrels.json
    │   ├── ... (5 more)
    ├── drag_curves/
    │   └── curves.json
    └── archive/                         ← old versions, never deleted
        ├── manifest-2026-05-10-180000.json
        ├── cartridges-v1-2026-05-10-180000.json
        └── ...
```

### Publish workflow (operator)

**One-time per machine** — authenticate with the right project:

```sh
gcloud auth login --update-adc
gcloud config set project loadout-precision-reloading
firebase login --reauth
```

**Every time you change a JSON file:**

1. Edit the file under `assets/seed_data/<...>`.
2. Bump the matching `version` in `assets/seed_data/manifest.json` —
   the in-app `SeedUpdater` only fetches files whose remote version
   is STRICTLY GREATER than the locally-stored version, so leaving
   the version unchanged means existing installs never see the
   update.
3. `flutter test test/seed_updater_allowlist_test.dart` — fast
   sanity check that the manifest keys + filenames + asset
   declarations are consistent.
4. `flutter test test/assets_present_test.dart` — same fast check
   with bundle-reachability per CLAUDE.md § 12a.
5. `./scripts/upload_seed_data.sh --dry-run` — preview what's about
   to be uploaded; verify the diff matches your intent.
6. `./scripts/upload_seed_data.sh` — publish. The script hashes
   each file, archives any prior bucket version into
   `seed_data/archive/<base>-v<old>-<date>.json`, uploads the new
   payload, then uploads the manifest LAST (so anti-downgrade
   ordering can't see a manifest pointing at a missing payload).

The script is idempotent — running it twice in a row is a no-op
(every hash matches).

### Old-version retention (firm rule)

**Old versions are never deleted.** When a JSON changes:

1. The previous bucket file is copied to
   `seed_data/archive/<base>-v<oldver>-<YYYYMMDD-HHMMSS>.json`.
2. The new file overwrites the canonical path
   (`seed_data/<base>.json`).
3. The manifest's `version` for that key is bumped.
4. The new manifest replaces the old one — its previous copy is
   archived to `seed_data/archive/manifest-<YYYYMMDD-HHMMSS>.json`.

Rollback: copy the archive entry back over the canonical path with
`gsutil cp gs://.../archive/<file>-v<n>-<date>.json
gs://.../seed_data/<file>.json` and decrement the manifest version.
We use the explicit `archive/` folder rather than GCS object
versioning because: (a) it's discoverable in the Firebase Console,
(b) rollback is one `gsutil cp`, (c) the audit trail is visible
without an admin API call.

### Rules deploy

`storage.rules` is the source of truth for the bucket's access
policy. Every change goes through `firebase deploy --only storage`:

```sh
firebase deploy --only storage
```

The current rules (post-2026-05-10):

- `seed_data/{path=**}` — public read, authenticated write
- everything else — deny

The `{path=**}` recursive matcher is load-bearing — the previous
single-segment `{file}` matcher denied subdirectories like
`seed_data/components/chassis.json` and
`seed_data/drag_curves/curves.json`, breaking SeedUpdater for v33
and v12 catalogs on first publish.

### Privacy posture

Same as § 13. The bucket holds only **published reference catalog
data** — manufacturer-published cartridge specs, powder burn-rate
charts, factory load BCs, scope catalogs, component product lists.
**No user reloading data ever leaves the device.** Cloud Sync
(§ 19) and Cloud Backup are end-to-end encrypted with the user's
passphrase and uploaded to the user's OWN iCloud / Drive / OneDrive
container — those flows never touch this bucket.

### When SeedUpdater silently fails

The most common silent-failure modes:

| Symptom | Cause | Fix |
|---|---|---|
| Updates don't reach devices | `storage.rules` denies public read on `seed_data/**` | Re-deploy storage.rules; check live rules in Firebase Console |
| Updates don't reach devices for a specific table | Manifest key not in `allowedKeys` | `seed_updater_allowlist_test.dart` should have caught this; if not, regenerate the test |
| Updates don't reach devices for a nested file | `_isSafeManifestFilename` rejected the path | Check the filename has at most one `/`, no `\\`, and ends in `.json` |
| Local install is stuck on bundled v1 forever | Local `seed_version_<key>` pref is at the same number as remote | Bump the remote `version` in the manifest. SeedUpdater anti-downgrade is strictly-greater. |
| `/seed_data/manifest.json` returns 404 | Bucket isn't populated yet | Run `./scripts/upload_seed_data.sh` for the first time |

## 29. Universal error handler + Crashlytics

LoadOut catches every unhandled error in the app — render-time
exceptions, async errors, navigation failures, BLE callbacks, you
name it — and routes them through a single privacy-aware pipeline
that (a) shows the user a usable fallback UI instead of a red error
screen and (b) ships a scrubbed report to Firebase Crashlytics so
engineering can triage. **Crash collection is opt-OUT** — fresh
installs default to ON; users who care about strict no-network-egress
can flip it off in Settings → Privacy & Data.

### Components

| | |
|---|---|
| Crash service | `lib/services/crash_reporter.dart` (`CrashReporter` singleton — wraps `FirebaseCrashlytics` with privacy-aware custom keys + breadcrumbs; no-ops on web/macOS or when disabled) |
| Hang + slow-frame detector | `lib/services/hang_detector.dart` (`HangDetector` singleton). Two complementary detectors share one lifecycle-aware service: a `Timer.periodic` heartbeat that measures actual-vs-expected tick lateness (catches general UI-thread blocks > 3s — sync heavy work, plugin deadlocks, runaway build loops), and a `SchedulerBinding.addTimingsCallback` observer that reports any frame > 1s (catches stuck animations, oversized chart redraws, full scroll re-flows). Both route through `CrashReporter.recordError` so the same opt-out + privacy + platform gating apply for free. Throws synthetic `AppHangDetected` / `SlowFrameDetected` types so Crashlytics groups the issues by class. Pauses on `AppLifecycleState.paused` so OS-suspended time isn't counted as a hang; throttles repeats to one report per 30s so a single 30s freeze produces one report, not 30. Started from `lib/main.dart` after `CrashReporter.initialize`. |
| Universal in-tree boundary | `lib/widgets/app_error_boundary.dart` (`AppErrorBoundary` — wraps every routed screen via `MaterialApp.builder`; on render error, shows fallback panel with Reload + Back; double-records to Crashlytics) |
| Per-screen boundary (legacy, kept) | `lib/widgets/range_day_safety.dart` (`RangeDayErrorBoundary` + `safeAsync` — predates the universal one but is still wrapped around Range Day for belt-and-suspenders) |
| Route breadcrumbs | `lib/services/breadcrumb_navigator_observer.dart` (`BreadcrumbNavigatorObserver` — installed in `MaterialApp.navigatorObservers`; emits a Crashlytics log line on every push/pop/replace and sets the `current_route` custom key) |
| Boot wiring | `lib/main.dart` `_configureCrashlytics()` — reads opt-out pref, calls `CrashReporter.initialize(...)` with `CrashReporterContext` (app version, schema version, platform, OS version) |
| Settings toggle | `lib/screens/settings/privacy_data_screen.dart` "Send anonymous crash reports" `SwitchListTile` — flips `crashlytics_enabled` pref + calls `setCrashlyticsCollectionEnabled` |
| Android native plugin | `android/settings.gradle.kts` declares `id("com.google.firebase.crashlytics") version("2.9.9") apply false`; `android/app/build.gradle.kts` applies it alongside `google-services`. Pinned to 2.9.9 — 3.x requires the Gradle daemon to run on JDK 17. **Without this Gradle plugin, Dart-side `recordError` calls succeed but Firebase silently drops the reports** and the Console keeps showing the "Add SDK" onboarding page; the iOS Pod brings everything in via CocoaPods so iOS does not need a parallel step. |
| iOS dSYM auto-upload | Build phase `[CP] Crashlytics Upload dSYMs` in `ios/Runner.xcodeproj/project.pbxproj` (id `7AC8A41B2C3D4E5F60718293`) — runs after `[CP] Copy Pods Resources` on every build. Calls `${PODS_ROOT}/FirebaseCrashlytics/upload-symbols -gsp ${PROJECT_DIR}/Runner/GoogleService-Info.plist -p ios <dSYM>` so Firebase can symbolicate stack traces server-side. **Without this, every new TestFlight / App Store build arrives at Crashlytics with raw memory addresses** and an engineer has to drag-drop the dSYM through the Console manually for every release. The script silently no-ops when `upload-symbols` is missing (e.g. `pod install` hasn't run on a fresh checkout). |
| Android R8 mapping auto-upload | The Android analogue of the iOS dSYM phase. Handled implicitly by the `com.google.firebase.crashlytics` Gradle plugin (`mappingFileUploadEnabled` defaults to true); no explicit build hook needed. **Only fires when `isMinifyEnabled = true`** — which is intentionally OFF today (see `android/app/build.gradle.kts` release block). Stack traces from current release builds already show real class/method names, so there's nothing to symbolicate. When R8 is eventually flipped on as a pre-launch APK-size optimization, mapping uploads start automatically — but every plugin that uses reflection (firebase, drift, kotlinx_serialization, etc.) will need explicit `-keep` rules first, and the whole release flow needs a smoke-test pass before shipping. Treat enabling R8 as its own pre-launch task. |

### "Show what's missing" pattern (Range Day, Internal Ballistics, Ballistic Profile form)

The user's directive: when the app can't compute a result, show
WHAT'S missing — and the affected text box should also have a red
indicator. Implemented as:

| | |
|---|---|
| Shared widget + model | `lib/widgets/missing_inputs_card.dart` (`MissingInputs` immutable bundle of `MissingInputEntry` rows + `MissingInputsCard` amber-bordered visual) |
| Internal Ballistics | `lib/screens/ballistics/internal_ballistics_screen.dart` — `_collectMissingInputs()` builds the bundle on every Predict tap; `_errorTextFor(fieldId)` drives per-field `errorText:`; result panel renders the card when `_missingInputs.isNotEmpty`. Predict button always enabled. |
| Ballistic Profile form | `lib/screens/ballistics/ballistics_screen.dart` — `_collectMissingProfileInputs()` runs in `_onSaveAsProfile` / `_onUpdateProfile` pre-save; on missing fields, refuses the save, shows a SnackBar, and renders `MissingInputsCard` at top of form. Per-field `errorText:` via `_profileErrorTextFor`. Each affected TextField clears the missing state on next keystroke via `onChanged: (_) => _clearStaleProfileMissing()`. |
| Range Day Solution surface | `lib/screens/range_day/range_day_detail_screen.dart` — already had a comprehensive `_solverMissingFieldsState` widget + `_missingSolverInputs()` method that lists missing fields with location pointers. Left unchanged; do not duplicate with `MissingInputs` infrastructure here. |

When adding a new solver-driven screen, reuse `MissingInputs` /
`MissingInputsCard` from `lib/widgets/missing_inputs_card.dart`
rather than inventing a per-screen pattern. The model carries both
the canonical `fieldId` (drives per-field `errorText:`) and the
human-readable `label` (drives the bulleted card display) so the
two surfaces stay in sync.

### Privacy contract for crash reports (firm rule)

Custom keys and breadcrumbs are SAFE TO SHIP only if they meet ALL
of these:

- **Stable identifiers only.** Route names, enum values, schema
  version, app version, platform, OS version, anonymous-vs-signed-in
  flag, row IDs (per-install auto-increment integers).
- **Never user-typed strings.** No recipe names, firearm names,
  notes, brass-lot labels, custom-field values, AI chat content.
- **Never PII.** No Firebase UIDs, no email addresses, no OAuth
  tokens, no device fingerprints beyond what Crashlytics already
  collects automatically (OS version, model, locale).
- **Never row CONTENT.** Logging "load #42 was selected" is fine;
  logging the cartridge / powder / charge of load #42 is not.

When you add a new `setKey(...)` or `log(...)` call site, ask:
"could a screenshot of this report leak something the user typed?"
If yes, redact or drop it. The privacy posture (§ 13) is a
load-bearing brand promise; one PII leak in a crash report
undermines it.

### Default-ON rationale

Pre-2026-05-10 the default was OFF (privacy-first opt-in). The user
hit repeated red-screen crashes that engineering couldn't triage
without telemetry, so the default flipped to ON with the same
privacy guarantees in place. The Settings toggle copy makes the
trade-off visible: "Helps us catch bugs faster. No personal data,
recipes, or firearms info is included." Users who care about
strict no-network-egress can flip it off; the CrashReporter
no-ops every public method when disabled.

When changing the default, also update:

- `lib/main.dart` `kCrashlyticsEnabledDefault` constant + its
  doc comment
- `lib/main.dart` file header (lines 17-19, 85-88, 162-165)
- `lib/screens/settings/privacy_data_screen.dart` initial state
  (which mirrors `kCrashlyticsEnabledDefault`)
- This section
- App Store / Play Store privacy disclosures
- The Privacy Policy + landing-page copy

## 30. Reticle catalog — dual-track IP posture (firm rule)

LoadOut ships an enriched reticle catalog with TWO subtension data
sets per LoadOut-original reticle:

- **Option A — `subtensionsOriginal`**: purely original LoadOut
  subtensions (mil/MOA values for each hashmark, derived from
  first-principles geometry without reference to any specific
  manufacturer's published spec). Zero IP risk.
- **Option B — `subtensionsCalibrated`**: subtension values
  calibrated against published manufacturer specs (e.g. "this
  LoadOut Mil Tree's 1-mil hash spacing matches the Vortex EBR-7D
  published mil grid"). Moderate IP risk; defensible as
  interoperability data; never exposes the manufacturer's
  trademarked reticle name as a product entry in our catalog.

**Option B is the production default.** Option A is
debug-only — accessible via a hidden Settings → Diagnostics
toggle for engineering use, never marketed as a user feature.
The dual track exists so we can flip back to A globally with one
config change if a manufacturer ever sends a takedown letter or
claims design-patent infringement on a calibrated reticle.

### Schema (additive on `assets/seed_data/reticles_v2.json`)

```json
{
  "id": "loadout_default_mil_tree",            // LoadOut-original name
  "model": "LoadOut Default - Mil Tree",       // user-visible
  "manufacturer": "LoadOut",                    // ALWAYS "LoadOut"
  "elements": [...],                            // visual definition
  "subtensionsOriginal": { ... Option A data ... },
  "subtensionsCalibrated": { ... Option B data ... },
  "calibrationProvenance": {
    "calibratedAgainst": "Vortex EBR-7D MOA/MRAD",
    "manufacturerName": "Vortex Optics",
    "publishedSubtensionUrl": "https://vortexoptics.com/...",
    "verifiedAt": "2026-05-11",
    "verifiedBy": "LoadOut research, citing manufacturer published spec",
    "notes": "Used for interoperability calibration only. LoadOut original art retained."
  },
  "bdcCalibrations": [
    {
      "name": "DMR Standard (.308 175gr SMK)",  // LoadOut name
      "cartridge": "308win",
      "muzzleVelocityFps": 2600,
      "zeroYards": 100,
      "marks": [
        {"y": -1.0, "rangeYd": 200, "label": "200"},
        ...
      ],
      "calibratedAgainst": "Hornady BDC published curve",  // INTERNAL — not user-visible
      "publishedSubtensionUrl": "https://hornady.com/...",
      "verifiedAt": "2026-05-11"
    }
  ]
}
```

### Hard rules for any agent / engineer touching reticle data

1. **Never use a manufacturer's trademarked reticle name as the
   `model`, `id`, or `family` field** of any reticle row. The
   model is "LoadOut Default - Mil Tree", not "EBR-7D copy".
2. **`manufacturer` is ALWAYS the string `"LoadOut"`** — even
   when the calibration data was derived from another brand's
   published spec.
3. **`calibratedAgainst` and `publishedSubtensionUrl` capture
   provenance** for interoperability defense. Always include both
   when adding Option B subtensions. Pin to the most-current
   manufacturer-published manual / spec page, not a fan blog or
   forum post.
4. **Skip Horus + ACSS reticles entirely.** No Option B
   calibration against TReMoR2/3, H59, H58, Grid II, or any ACSS
   variant. Per CLAUDE.md § 4a these are heavily litigated. The
   LoadOut-original reticle defaults are sufficient — users with
   those scopes get the LoadOut Mil Tree fallback.
5. **No manufacturer reticle ARTWORK ever ships** — neither pulled
   from manufacturer sites nor recreated pixel-accurately. The
   `elements` array is and stays LoadOut-original.
6. **The user-facing reticle picker and Find By My Scope sheet
   never display a manufacturer's reticle name as a product
   choice.** Internal docs / debug surfaces may reference
   "calibrated against EBR-7D" descriptively, but that string
   never appears on a button, tile, or tooltip the user reads.
7. **The "LoadOut Original — Interoperability Calibration"
   label** must appear on every reticle preview card, so users
   understand the tool is not claiming to be the manufacturer's
   reticle.

### How a runtime decides which subtension set to use

| Setting | Active subtension data |
|---|---|
| Production default | `subtensionsCalibrated` (Option B) |
| Debug toggle ON: "Use Original Subtensions" | `subtensionsOriginal` (Option A) |
| Calibrated set missing for a reticle | Falls back to `subtensionsOriginal` |
| Both missing | Falls back to bare element positions (legacy behavior) |

The toggle lives at Settings → Diagnostics → "Use Original
Reticle Subtensions (Debug)". It's hidden by default and
requires triple-tap on the version number to reveal — the same
pattern Android uses for developer mode.

### Liability reduction checklist (do all of these before launch)

- [ ] Every Option B reticle row has a non-null
  `calibrationProvenance` block citing the manufacturer's
  published spec page.
- [ ] No manufacturer reticle name appears in any user-visible
  string (model, family, picker label, glossary entry).
- [ ] The reticle picker's preview card prominently displays the
  "LoadOut Original — Interoperability Calibration" tagline.
- [ ] The "Use Original Subtensions" debug toggle is gated behind
  developer mode and not visible in the standard Settings menu.
- [ ] No Horus or ACSS reticle has a Calibrated subtension entry
  (search the repo for "horus", "acss", "tremor" before launch).
- [ ] Privacy & Legal copy (in-app + landing page) describes the
  reticle catalog as "LoadOut-original reticles, calibrated for
  interoperability with major scope manufacturers" — not "1-to-1
  with manufacturer reticles".
- [ ] Lawyer review of the Option B catalog before each
  marketing-significant release.

### Why this dual-track exists

The user accepted moderate IP risk on Option B in exchange for
much better real-world utility (a LoadOut Mil Tree calibrated
against the actual Vortex EBR-7D mil grid behaves the same way
the user's real scope behaves, even though they're looking at
LoadOut-original artwork). Option A is the safety valve: if
takedown notices arrive, we flip the toggle's default to ON and
ship a build that uses purely original subtensions on the same
LoadOut-original artwork. **The toggle's existence is the
load-bearing safety mechanism — do not remove it.**

### Phase 2 / Phase 5 update (v2.3) — data model simplified

The dual-track `subtensionsOriginal` / `subtensionsCalibrated`
schema described above was **simplified during the v2.3 rewrite**.
The current production schema in `assets/seed_data/reticles.json`
(v2.3 catalog, 52 reticles) collapses the dual subtension blob into
a single `subtensions` block on each row, plus a `subtension_origin`
discriminator enum:

| `subtension_origin` value | Population (v2.3) | What it means |
|---|---|---|
| `original` | 21 | LoadOut-authored geometry, no external reference spec |
| `public_domain` | 21 | Traditional pre-modern patterns (duplex, German, plex, mil-dot) |
| `published_spec` | 10 | LoadOut-original artwork; subtensions calibrated to a manufacturer's published spec. `calibration_provenance` JSON blob carries the citation. |

The legacy `reticles_v2.json` filename was retired in Phase 2 — the
catalog lives at `assets/seed_data/reticles.json` now.

The "Use Original Subtensions (Debug)" toggle described above is
**not present** in the v2.3 production build; the dual-track
runtime switch was deemed unnecessary once the schema collapsed.
If a future takedown letter requires reverting to purely-original
subtensions, the relevant change is to bulk-rewrite the 10
`published_spec` rows' subtension blocks rather than flipping a
single setting. The data layer makes that mechanical (one Python
script over the JSON catalog); the architectural safety net is
still present, just implemented as catalog-edit rather than
runtime flag.

**Phase 6 disclaimer template addition (v2.3).** The single fixed
caption "LoadOut Original — Interoperability Calibration" described
above is now **per-origin variable** as of Phase 6 §C:

| `subtension_origin` | Caption | Tooltip |
|---|---|---|
| `original` | "LoadOut Original" | "Engineered for your scope's subtensions" |
| `public_domain` | "Public Domain Reticle" | "Traditional duplex / hash / dot pattern; not subject to trademark or copyright" |
| `published_spec` | "Calibrated to [Manufacturer] [Reticle Name]" (filled from `calibration_provenance`) | "Subtensions calibrated to the published manufacturer specification. Not a reproduction. Verify against your scope's specification sheet for precision use." |

The "Not a reproduction" framing on `published_spec` is load-bearing
legal posture per `docs/IP_POSTURE.md`. Marketing and engineering
docs that reference the single fixed caption are stale; the
authoritative per-origin templates live in
`lib/widgets/reticle_renderer.dart`'s `ReticleInteroperabilityLabel`.

For the full Phase 5 / 6 IP posture writeup including patent
landscape and FTO scoping, see `docs/IP_POSTURE.md`. For the v2.3
brief errata (the discovery and resolution log), see
`docs/v2.3_BRIEF_ERRATA.md`.

---

## 31. Range Day Realistic painter architecture (v2.3)

The v2.3 rewrite added a "Realistic mode" scope view that renders a
procedural scene (sky / grass / mound / post / target / reticle / lighting)
matching reference images. The architecture is documented here because
several factoring decisions are non-obvious and easy to misread.

### Three painters cooperate inside the scope view

| Painter | File | Responsibility |
|---|---|---|
| `ScopeDaytimeBackdropPainter` | `lib/widgets/scope_daytime_backdrop.dart` | Sky, grass, mound, optional target silhouette, atmospheric haze. Used by reticle picker preview AND scope view AND Range Day Realistic. |
| `_RealisticTargetPainter` | `lib/screens/range_day/widgets/target_plot.dart` | The Range Day Realistic painter. Composes the backdrop + post / cross-bar + target silhouettes + aim point + scope ring + reticle on top. |
| `_ReticlePainter` | `lib/widgets/reticle_renderer.dart` | Just the reticle (lines / hashes / dots / labels). Used inside the scope ring. |

### Two `bool` flags on `ScopeDaytimeBackdropPainter`

The backdrop painter has three consumers (reticle picker preview,
scope view preview, Range Day Realistic). Range Day Realistic
needs DIFFERENT band coefficients (per the v2.3 brief §6.2.1):

- Horizon at 0.78 H instead of legacy 0.62 H
- Mound rendered as a foreground brown-oval berm at 0.82–0.92 H ×
  0.18 W instead of a hill silhouette rising above the horizon
- Post at 0.025 W from target_bottom (~0.55 H) to 0.85 H

Two flags select the variant rather than introducing a separate
painter class:

| Flag | Default | When `true` |
|---|---|---|
| `realisticMode` | `false` | Use §6.2.1 band coefficients (Range Day Realistic). Default `false` preserves picker preview + scope view legacy 0.62 horizon. |
| `paintMound` | `true` | Suppress the shared mound when the rack mount style is `popper_base` or `individual_posts` (Range Day Realistic rack modes that render per-child support graphics on grass instead of a shared berm). |

Decision NOT to make these an enum: `realisticMode` is binary;
`paintMound` is orthogonal (rack mode independent of horizon
position). Two flags is the lower-coupling factoring.

### `RealisticLayout` is public for testability

`_RealisticLayout` → `RealisticLayout` (rename without
underscore prefix) so `test/scene_composition_test.dart` can
directly construct layouts and assert band coefficients without
spinning up a full widget paint. The class is a pure value type
(no mutable state, no side effects in the constructor) so
widening its scope has zero behavioural risk.

### `shouldRenderReticleElement` is a public top-level function

The §6A.1 adaptive LOD gate. Was originally `_shouldRenderReticleElement`
(library-private). Made public so `test/reticle_lod_test.dart` can
verify the gate downshifts at the prescribed thresholds:

- `CrosshairLine` → always renders
- `HashMark` → skip when `length × pxPerUnit < 1.5`
- `CenterDot` / `HoldoverDot` → skip when `radius × pxPerUnit < 0.5`
- `FloatingNumber` → skip when `fontSize × pxPerUnit < 6.0`

Pure function; no painter state; widening scope is safe.

**Critically, the gate is invoked from `_ReticlePainter.paint`'s
element loop** via `if (!shouldRenderReticleElement(el, pxPerUnit))
continue;` so the v2.3 DoD warning ("Adaptive LOD code path exists
is not the same as adaptive LOD actually downshifts on slow
devices") is satisfied.

### `scope_catalog_v2` lazy-loaded read-only service

`lib/services/scope_catalog_v2.dart` is the runtime accessor for
the merged v2.3 catalog JSONs (`scopes.json` / `reticles.json` /
`scope_reticle_options.json`). It exposes `allScopes()`,
`allReticles()`, `scopeById()`, `reticleById()`,
`defaultReticleIdForScope()`. Singleton with `debugResetCache()`
for tests.

Consumed by the per-firearm default scope+reticle UI on the firearm
form (`lib/screens/firearms/firearm_form_screen.dart` —
`_defaultScopePicker` / `_defaultReticlePicker`) and by the Range
Day pre-population logic
(`lib/screens/range_day/range_day_detail_screen.dart`
`_applyV2DefaultsFromFirearm`).

Soft-fails to empty list on missing / malformed assets. Replaces
the older `lib/services/scope_catalog_service.dart` for v2.3-aware
call sites; the legacy service still backs the old "Find by My
Scope" picker until that's migrated (a v2.4 task).

### Rack rendering — four mount-style dispatch

`_RealisticTargetPainter.paint` dispatches on the rack mount style
(forwarded from `TargetPlot.rackMountStyle` → ultimately from
`TargetRackRow.rackKind` in drift):

| Mount style | Painter | Mound? |
|---|---|---|
| `hanging_rail` (KYL, Equal, Decreasing) | `_paintHangingRail` (renamed from legacy `_paintCrossBarAndChains`) | Shared berm |
| `standing_stakes` (Square Rack) | `_paintStakes` | Shared berm |
| `popper_base` (Pepper Popper) | `_paintPopperBases` | **No shared mound** — each popper has a trapezoidal concrete base on grass; `paintMound: false` |
| `individual_posts` (IDPA Open Stage) | `_paintIndividualPosts` | **No shared mound** — each child has its own post + mini brown-oval berm; `paintMound: false` |
| anything else (e.g. `rotating_hub` for Texas Star) | falls through to `_paintHangingRail` | Shared berm |

Active-child highlighting: `kRackActiveStrokeWidth = 2.5` /
`kRackInactiveStrokeWidth = 1.5` (top-level constants). Active
plate gets the thicker stroke; inactive plates the thinner. No
fill change, no other visual treatment.

### Files-of-record for the painter architecture

- `lib/widgets/scope_daytime_backdrop.dart` — backdrop painter (sky / grass / mound + the two flags)
- `lib/screens/range_day/widgets/target_plot.dart` — Range Day Realistic painter (composes backdrop, renders rack / single target, scope ring + reticle)
- `lib/widgets/reticle_renderer.dart` — reticle painter (LOD gate, per-origin disclaimer label)
- `lib/services/scope_catalog_v2.dart` — v2.3 catalog accessor
- `test/scene_composition_test.dart` — band coefficient regression
- `test/ipsc_path_test.dart` — IPSC silhouette geometry regression
- `test/reticle_lod_test.dart` — LOD gate threshold regression
- `test/rack_rendering_test.dart` — mount-style dispatch + headroom regression
- `test/reticle_disclaimer_templates_test.dart` — per-origin disclaimer regression
- `test/reticle_mapping_top35_test.dart` — Appendix G top-35 reticle reference set
- `test/scope_catalog_v2_test.dart` — scope catalog service tests

---

## 32. Scene Painter Phase 9.5 architecture

Phase 9.5 (2026-05-14) consolidated the target and rack data models
on a single closed vocabulary, made the animal silhouette catalog
uniform-direction, and fixed a long-standing dropdown-dismiss-on-
scroll bug at its actual root cause. Four atomic commits landed on
`main` (`d6b2566` → `7ee5e42` → `af8ec75` → `08afd7e`); the full
writeup is at `SCENE_PAINTER_PHASE_9_5_REPORT.md` in the repo
root. This section documents the architectural patterns introduced
so future work doesn't reinvent them.

### 32.1 — Category-driven target taxonomy (v39)

Replaces the legacy `Targets.shape` text column with a closed
`category` enum.

**Vocabulary** (closed set — every target catalog row carries
exactly one of these):

| Category | What's in it | Painter dispatch |
|---|---|---|
| `circle` | Round plates, generic round paper. | `canvas.drawCircle(...)` |
| `square` | Square steel, square paper. | `canvas.drawRect(...)` |
| `rectangle` | Asymmetric rectangles, USPSA-class paper. | `canvas.drawRect(...)` |
| `ipsc` | IPSC / USPSA Metric / Classic silhouette. | `buildIpscPath(rect)` |
| `animal` | 16 species × 3 sizes = 48 rows. | `AnimalSilhouettes.buildAnimalPath` |
| `special` | Apparatus that needs procedural geometry — pepper popper, Texas Star. | `shape_id` dispatch (`pepper_popper`, `texas_star`, …) |

**Rules:**

- The catalog row's `shape_id` is the SECOND-level dispatch key —
  used for `animal` (which species) and `special` (which
  apparatus). Categories `circle / square / rectangle / ipsc`
  ignore it (and ship with `shape_id` null in the seed).
- The seed loader validates every row's `category` against the
  closed set and throws `StateError` on unknown values — better
  to crash on first launch than ship a silently-rectangular
  popper to users.
- The Range Day chip filter row uses the category enum directly:
  All / Circle / Square / Rectangle / IPSC / Animal. No
  `special` chip — those rows are reachable via the dropdown
  search but don't have a dedicated filter (only 3 rows, would
  read as overkill).
- Adding a new category requires updating: the enum validator in
  `seed_loader.dart`, the painter dispatch in
  `target_plot.dart`'s `_paintTarget`, the chip-filter list in
  `range_day_detail_screen.dart`, and the regression test in
  `test/targets_catalog_test.dart`.

### 32.2 — RackSlot + TypeConverter pattern (v40)

The v40 schema collapsed the rack model from a two-table
parent+child design to a single-table design with an inline JSON
`slotsJson` column. This is the **reference pattern for any
structured-but-bounded child collection** in this codebase:

**When to use this pattern:**

- The child list is **always read as a whole**, never paged or
  individually queried.
- The child count per parent is **bounded** (single digits to
  low double digits — racks ship with 1–10 slots).
- Children are **read-only reference data** (seeded from JSON,
  never edited at runtime).
- The schema is **stable** (changing the child shape is rare and
  always paired with a seed file rewrite).

**When NOT to use it:** user-writable data, unbounded growth,
need to query across children (e.g. "find all racks with a
6-inch plate"). For those, stay on a FK child table.

**Layering** (see `lib/database/rack_slot.dart`):

```
RackSlot                            — immutable value type with
                                      fromJson / toJson.
RackSlotsConverter                  — extends drift's
                                      TypeConverter<List<RackSlot>, String>.
                                      fromSql sorts defensively,
                                      returns UnmodifiableListView.
                                      toSql preserves in-memory order.
TargetRacks.slotsJson               — TextColumn declared with
                                      `.map(const RackSlotsConverter())`.
                                      drift codegen does the rest.
TargetRacksCompanion.insert(...)    — accepts a typed
                                      `List<RackSlot>`; the converter
                                      runs at insert time.
```

**Rules:**

- The value type's file lives in `lib/database/` (NOT inside
  `database.dart`) so consumers can import the type without
  pulling in drift's generated parts.
- Always export the value type from the repository as a courtesy
  — see `target_repository.dart`'s
  `export '../database/rack_slot.dart' show RackSlot;`.
- The converter's `fromSql` sorts defensively by the natural
  position key. The seed loader sorts BEFORE insert too, so the
  stored JSON is canonical and the read-time sort is a
  belt-and-braces guard against hand-edited DB rows.
- `fromSql` on an empty string returns `const []` (degenerate
  case for a rack with zero slots — the painter handles it as
  "render furniture only").
- The result list is **unmodifiable**. Callers that try to
  mutate it throw at runtime; that's deliberate (cached
  reference data must never be mutated).
- Ship a `test/<thing>_converter_test.dart` regression suite
  covering: full-field round-trip, optional-null-field
  round-trip, defensive sort on out-of-order input, empty-string
  input, unmodifiable result, non-list-JSON loud fail,
  missing-required-field loud fail.

### 32.3 — Animal SVG canonical-LEFT convention

Every animal silhouette in `assets/silhouettes/animals/` faces
**LEFT** in the rendered scene. Uniform direction means a single
per-animal aim point (`center_point.horizontal_from_left = 0.6`)
lands behind the front shoulder for every species — no per-row
overrides.

**The convention** (Phase 9.5 Group B):

8 SVGs already face LEFT and are untouched: bear, coyote, elk,
moose, mule_deer, pheasant, pronghorn, wild_turkey.

7 SVGs were authored facing RIGHT and have been horizontally
mirrored via a canonical wrapper: boar, deer, fox, groundhog,
mountain_lion, prairie_dog, rabbit. Each wrapped SVG looks like
this around its existing path content:

```svg
<svg viewBox="0 0 W H" ...>
  <g data-loadout-mirror="true" transform="translate(W 0) scale(-1 1)">
    <!-- original path content unchanged -->
  </g>
</svg>
```

where `W` matches the viewBox width. The `data-loadout-mirror`
data-attribute is the dispatch key (not the `transform` value
alone) — the parser recognises ONLY the canonical form.

1 SVG (bigfoot) is a front-facing biped — no clean side-profile
direction applies. Left as-is; the chest-vital aim point lands
centered regardless.

**Parser implementation** (in
`lib/widgets/animal_silhouettes.dart`):

- `extractAndCombinePaths(svgContent, assetPath)` finds the
  canonical wrapper via `_extractMirrorTransform(svgContent)`.
- Returns a `Matrix4` for the canonical form; returns `null` for
  ANY other transform pattern (the SVG renders un-flipped).
- The Matrix4 is applied to the final combined `Path` before
  return — every Pattern dispatch (A/B/C/D/E + fallback) wraps
  its return through `applyMirror(p)`.
- **Strictness is deliberate**: the wrapper is a recognised
  LoadOut convention, not a general-purpose SVG transform
  implementation. Future canonical transforms can extend the
  helper as named patterns.

**Rules:**

- New animal SVG additions face LEFT in the artwork, OR get
  wrapped with the canonical mirror group. Never ship a
  right-facing SVG without the wrapper.
- The Python helper that does the wrapping (`python3` inline in
  Group B's commit, reproducible from
  `SCENE_PAINTER_PHASE_9_5_REPORT.md`) is **idempotent** — it
  refuses to re-wrap an already-wrapped SVG. Re-running the
  audit + flip script is a no-op against the 16 shipped files.
- Regression test:
  `test/animal_silhouettes_test.dart` — 3 Phase 9.5 cases assert
  (a) the canonical wrapper mirrors paths correctly, (b) the
  wrapper-absent case is a no-op, (c) non-canonical transforms
  on the marker group are rejected and the SVG renders
  un-flipped (the fail-safe).

### 32.4 — NotificationListener pattern for Autocomplete inside `keyboardDismissBehavior: onDrag`

A long-standing Range Day picker bug: the target dropdown
dismissed as soon as the user scrolled the options list.
Phase 8 + Phase 9 added speculative gesture-arena fixes that
didn't address the cause. Phase 9.5 Group D found the actual
root cause:

**The bug travels through Flutter's NOTIFICATION bus, not the
pointer-event tree.**

The outer `SingleChildScrollView` (the phone-body screen
scroller in `range_day_detail_screen.dart:2549`) has
`keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag`.
Per Flutter SDK (`scroll_view.dart:520-540`), that installs an
ancestor `NotificationListener<ScrollUpdateNotification>` that
calls `FocusManager.instance.primaryFocus?.unfocus()` on every
drag-update notification with `dragDetails != null`.

The `Autocomplete<TargetRow>` overlay is rendered in an
`OverlayEntry` (sibling of the body in the render tree) BUT its
`_RawAutocompleteState` element is a **widget-tree descendant**
of the SingleChildScrollView. ScrollNotifications bubble through
widget-tree ancestry (`Element.visitAncestorElements`),
INDEPENDENT of pointer routing.

So every tick the user scrolls the overlay's inner ListView, a
`ScrollUpdateNotification` bubbles up the widget tree, reaches
the outer listener, fires `unfocus()`, the Autocomplete's
`_onFocusChange` callback (`autocomplete.dart:423`) sees
`_focusNode.hasFocus == false` and tears the overlay down.

**The load-bearing fix** is one widget wrap around the overlay's
scrollable:

```dart
NotificationListener<ScrollNotification>(
  onNotification: (_) => true,  // "handled, do not bubble"
  child: ListView.builder(...),
)
```

`true` from `onNotification` is Flutter's canonical "handled, do
not bubble" contract. The outer listener never sees the inner
list's drags. Focus stays. Overlay stays open.

**Rules:**

- **`grep keyboardDismissBehavior.*onDrag lib/`** today finds
  exactly one call site — the Range Day phone body. Other
  Autocomplete users (ballistics, firearms, recipes, saami) live
  under a normal SingleChildScrollView with no kbd-dismiss-on-drag
  and don't have this bug.
- **If a future screen combines `keyboardDismissBehavior.onDrag`
  with `Autocomplete` / `DropdownMenu` / any other scrollable
  overlay, copy the wrapper.** This is a known Flutter design
  wart, not a one-off bug; the wrapper is the standard
  mitigation.
- `TextFieldTapRegion` does NOT help here — it intercepts TAPS
  that would unfocus the field, not programmatic `unfocus()`
  triggered by a drag-side notification. Phase 8 added it for a
  different (real but different) bug; it stays as
  belt-and-suspenders.
- `HitTestBehavior.opaque` on a `Listener` does NOT help here —
  it absorbs POINTER events; notifications use a separate
  channel. Phase 9 C.6 added it for a hypothetical
  gesture-arena race; it stays as belt-and-suspenders.
- Regression test: `test/range_day_picker_scroll_notification_test.dart`
  — 2 tests assert (a) the swallow wrapper stops bubbling, (b)
  without the wrapper the bubble reaches the outer listener
  (sanity check on the test harness).

### 32.5 — Operator verification checklist (after any Range Day data-model change)

When making changes that touch the target / rack catalog or the
Range Day picker / painter:

1. **Target picker chip filter** — open the dropdown, scroll
   through every chip (All / Circle / Square / Rectangle / IPSC
   / Animal); confirm each shows only its category's targets.
2. **Texas Star + pepper popper** — search the picker for both;
   confirm the Texas Star renders as a 5-point geometric star
   (not a fallback rectangle), the popper renders as an IPSC
   silhouette.
3. **Animal facing direction** — open the picker, scroll into
   the animal section; confirm every animal faces LEFT in the
   preview row. Spot-check the aim point lands behind the front
   shoulder on bear, deer, fox (mirror-wrapped) AND on elk,
   mule_deer (already-LEFT) — should look identical at the
   rendering level.
4. **Rack picker** — switch through the 9 racks; confirm each
   one's plates render in the right positions. Active-child
   highlighting (thicker stroke) should work on every rack type.
5. **Dropdown scroll-no-dismiss** — open the target picker, type
   a partial query to filter to multiple results, scroll the
   dropdown list; confirm the overlay STAYS OPEN through the
   scroll. (The bug is particularly visible on the long animal
   section after the LEFT-flip.)
