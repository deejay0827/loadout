# Phase One — Recipes: Unified Smart Import + Targeted Cleanup — Completion Report

**Phase ID:** Phase One — Recipes
**Spec:** `PHASE_ONE_RECIPES_UNIFIED_IMPORT.md` (operator-supplied)
**Workflow:** Workflow Rule v3 — halt-and-validate per group
**Dates:** 2026-05-14 → 2026-05-15 (single-day span across UTC midnight)
**Status:** ✅ Complete — all six groups shipped to `main`
**Final gates:** `flutter analyze` 6 issues / 0 errors. `flutter test --exclude-tags=slow` 1389 passing + 1 skipped + 0 failed (+45 from baseline). 8 new slow-tagged widget tests verified directly.

---

## Executive summary

Phase One consolidated the fragmented recipe-import surface behind a single canonical entry point, removed a long-standing naming collision ("Smart Import" the spreadsheet wizard vs. "AI Smart Import" the photo-review overlay), elevated the bullet-diameter → caliber-family lookup from a form-private hardcoded table to a repository method, closed a long-advertised feature gap on Quick Add (COAL/CBTO axis toggle), and brought `Engineering.md` back into sync with the repo. Six halt-and-validate groups shipped sequentially to `main`; no group required a rollback or follow-up patch within the phase.

The phase also surfaced two infrastructure issues that ARE NOT recipe-related but were discovered during the work and documented as Phase Two items / Engineering.md gotchas:

- A bare `flutter pub get` does not always regenerate `.dart_tool/flutter_gen/gen_l10n/` — a fresh checkout's first `flutter analyze` reports 8 spurious `Target of URI doesn't exist: 'l10n/app_localizations.dart'` errors that disappear after `flutter gen-l10n` runs once.
- Widget tests that pump a `BeginnerModeService` consumer leak a pending Timer if the test does not explicitly dispose the widget tree before the framework's `!timersPending` invariant check. Documented as a reusable test pattern in `test/quick_add_coal_cbto_test.dart`.

---

## Pre-flight findings (before Group 1 started)

| Discovery | Detail |
|---|---|
| Engineering.md was NOT in the repo | The supplied draft (`~/Downloads/Engineering.md`, 63 KB, dated 2026-05-14) was the target state. Group 1's job was to drop it in + reconcile against current code. |
| Schema version doc claim was stale | Doc said v38 (line 97). Actual code: **v40** (`lib/database/database.dart:2350`). Phase 9.5 Group A shipped v38→v39 (category enum on Targets, drops legacy `shape` column); Phase 9.5 Group C shipped v39→v40 (rack model collapse to inline `TargetRacks.slotsJson` via `RackSlotsConverter`, drops legacy `TargetRackChildren` FK child table). |
| Phase 9.5 described as future migration | Doc lines 207-209 + 279-287 described Phase 9.5 as a planned "mechanical migration"; it had already shipped. Doc needed past-tense rewording. |
| Manifest claim stale | Doc said `manifest_version: 11`, `files.targets.version: 8`. Actual: **15** and **10**. Manifest also moved to **16** during Phase One (interleaved scene-painter seed-data work). |
| `UserRacks` table claim was wrong | Doc described a `UserRacks` drift table for user-defined racks; the table does NOT exist in code. Forward-looking aspirational content needed softening to "future, on the Phase Two backlog." |
| Phase 10 claim stale | Doc said Phase 10 (visual-style mode toggle) was in flight. Reality at Group 1 time: Phase 9.8 was in flight (commit `5d32932` was the latest). Phase 10 Groups A-C landed DURING Phase One. |
| Baseline gates differed from doc expectations | Doc expected `flutter analyze` 4/0, `flutter test` 1316. Actual: **6/0** (2 extra pre-existing `Matrix4` deprecation infos in `target_silhouettes.dart` the doc's count missed) and **1344+1 skipped** (test count grew across recent scene-painter work). |
| `dateEstablished` column missing from doc | Section 19.2 UserLoads schema table did not list the column; it exists in `database.dart`. Added in Group 1. |

---

## Group-by-group detail

Each group is one logical change, one commit, one push to `main`. Reports follow the spec's mandated format.

### Group 1 — Engineering.md baseline sync (docs only)

```
Group 1: Engineering.md baseline sync
flutter analyze: 6 issues, 0 errors — unchanged from baseline
flutter test:    1344 passing + 1 skipped, 0 failed — unchanged
Summary:         Engineering.md updated to reflect current repo state with audit-pending markers.
Cold restart:    no
```

**Commit:** `e139f93` (1216 insertions, new file).

**Files touched:** `Engineering.md` only.

**Surgical edits applied to the supplied draft:**
- Schema version v38 → v40 (3 call sites: § 4 current-version, § 18 reference-files, narrative throughout).
- Schema-version history table: added v38→v39 (category enum) and v39→v40 (RackSlotsConverter) rows.
- § 4 target-catalog migration section: rewritten from future-tense ("the migration phase (Phase 9.5) is mechanical") to past-tense ("shipped in Phase 9.5 Group A on 2026-05-14").
- § 4 target-rack schema: rewritten as shipped reality including the inline `RackSlot` value type + `RackSlotsConverter` TypeConverter pattern from `lib/database/rack_slot.dart`. The aspirational `UserRacks` claim softened to "future, on the Phase Two backlog."
- § 5 manifest version 11 → 15, `files.targets.version` 8 → 10.
- § 13 in-flight phase Phase 10 → Phase 9.8 (with Phase One Recipes also marked in flight).
- § 16 test/analyze baseline counts updated.
- § 19.2 added missing `dateEstablished` column.
- § 19.3 `caliberLabelForBulletDiameter` marked "ships in Phase One Group 3" (today is hardcoded form-private method).
- § 19.4 import architecture: marked landing screen as "target state delivered by Group 5."
- § 19.8 COAL/CBTO axis row: marked "ships in Phase One Group 4."
- § 19.9 caliber-from-diameter: flipped back to "Today is hardcoded; Phase One Group 3 moves to ComponentRepository."
- New "Local-setup gotcha (l10n)" callout in § 11 documenting the pub-get-doesn't-trigger-gen-l10n issue and the `flutter gen-l10n` workaround.

**No code touched; analyze + tests unchanged.**

---

### Group 2 — Rename `smart_import_screen.dart` → `spreadsheet_import_screen.dart`

```
Group 2: Rename smart_import → spreadsheet_import
flutter analyze: 6 issues, 0 errors — unchanged from baseline
flutter test:    1344 passing + 1 skipped, 0 failed — unchanged
Summary:         File + class renamed across the repo; behavior, user-visible title,
                 constructor signature, and Free chip all unchanged.
Cold restart:    no
```

**Commit:** `c495dc1` (6 files, 45 insertions / 30 deletions; `git mv` preserves history at 96% similarity).

**Files touched:**
- `lib/screens/recipes/smart_import_screen.dart` → `lib/screens/recipes/spreadsheet_import_screen.dart` (renamed via `git mv`).
- Inside the renamed file: class `SmartImportScreen` → `SpreadsheetImportScreen`, State class `_SmartImportScreenState` → `_SpreadsheetImportScreenState`, typedef RHS updated, file header `FILE:` path + WHAT/WHY prose reworded, new "Naming history" callout added in header.
- 4 external callsites:
  - `lib/screens/backup/backup_screen.dart` — 1 import path + 1 class ref.
  - `lib/screens/onboarding/onboarding_screen.dart` — 1 import path + 1 class ref.
  - `lib/screens/onboarding/import_sources_screen.dart` — 1 import path + 3 class refs (1 MaterialPageRoute + 2 doc-comment references).
  - `lib/widgets/import_options_section.dart` — 1 import path + 8 class refs (3 MaterialPageRoute calls + 5 doc-comment references).
- 1 doc-comment update in `lib/services/spreadsheet_import_service.dart`.

**Deliberate holds (per spec):**
- User-visible AppBar title text "Smart Import" stays (UI-chat decision on the new copy).
- Behavior unchanged: state machine, mapping logic, presets, file-shape signature, the "Free for everyone" chip, the constructor signature (`initialFile`, `titleOverride`).
- `SmartImportEntry` typedef LHS name preserved (dead but out of Group 2 scope; renaming it is a Phase Two cleanup).

**Surprise during this group:** the analyzer was the right tool to find every callsite — running `flutter analyze` after the rename produced a clean error list of every unresolved import / class reference, and the fix was mechanical from there. No grep-after-the-fact needed.

---

### Group 3 — `_caliberLabelFromDiameter` → `ComponentRepository.caliberLabelForBulletDiameter`

```
Group 3: Diameter→caliber moved to ComponentRepository
flutter analyze: 6 issues, 0 errors — unchanged from baseline
flutter test:    1368 passing + 1 skipped, 0 failed — +24 new caliber tests
Summary:         Hardcoded 14-entry diameter table replaced with a repository method backed
                 by a final Map<double,String> at the lib level, marked TODO(phase-2) for
                 seed-JSON migration.
Cold restart:    no
```

**Commit:** `46f28fd` (3 files; 333 insertions / 26 deletions).

**Files touched:**
- `lib/repositories/component_repository.dart`:
  - New top-level `_kCaliberDiameterToleranceIn = 0.0015` constant (preserves the retired method's `nearly()` tolerance verbatim).
  - New top-level `_kCaliberFamiliesByDiameter` map. **`final`, not `const`** — Dart bans `const Map<double, _>` because `double` overrides `==` / `hashCode` (NaN + signed-zero semantics). 14 entries lifted from the retired form-private method.
  - New public `Future<String?> caliberLabelForBulletDiameter(double diameterIn)`. Iterates the map, returns the entry with the smallest residual diameter within tolerance. Future-wrapped (even though synchronous) so call sites stay forward-compatible with a future catalog-backed implementation.
  - `// TODO(phase-2): move to assets/seed_data/caliber_families.json` on the map.
- `lib/screens/recipes/recipe_form_screen.dart`:
  - `_backfillFromBullet` updated to await `repo.caliberLabelForBulletDiameter(...)`.
  - Private `_caliberLabelFromDiameter` (lines 1190-1207 pre-commit) deleted.
- `test/component_repository_caliber_test.dart` (new): 24 tests covering 14 round-trip assertions, 4 boundary checks, out-of-corpus / zero / negative null returns, and a tie-break test for diameters within tolerance of multiple entries.

**Design discussion — why the map stays at the repository instead of becoming catalog-driven today:**

The spec offered two paths (line 220-223):
1. Catalog-driven: extract leading token from cartridge name, group by diameter, pick shortest.
2. Hardcoded map at the repository level (with TODO for seed-JSON migration).

I picked path 2 because path 1 has too many edge cases:
- 4 of 14 entries are metric family labels (`6mm`, `6.5mm`, `7mm`, `9mm`) that don't appear as standalone cartridge names. `.380 ACP` at 0.355" maps to `9mm` family, not `.380`.
- Several imperial entries have leading-token collisions: `.25-06 Rem` vs `.257 Roberts` at 0.257"; `.270 Winchester` vs `.277 Fury` at 0.277"; `9x19 Parabellum` vs `.380 ACP` at 0.355".
- A leading-token extraction over the catalog would be brittle enough to need a fix-up table anyway.

The right end state is a `caliber_families.json` seed file — documented as Phase Two work. For Phase One, the map at the repository is the minimum-change correct shape.

**Surprise / fix during this group:** my initial implementation used `const Map<double, String>`, which the analyzer rejected with `const_map_key_not_primitive_equality`. Switched to `final`. Added a file-level comment explaining the rationale so a future maintainer doesn't try to revert. Also: my first version of the boundary test asserted that `0.3095` matches `.308` (boundary at +0.0015) — but IEEE 754 means `(0.3095 - 0.308).abs() ≈ 0.0014999999999999998` OR `0.0015000000000000346` depending on rounding mode; the retired method's strict `< 0.0015` semantics return null at the boundary. Fixed the test to stay 0.0001 inside / outside the boundary instead of testing at exact boundary values.

---

### Group 4 — Quick Add COAL/CBTO axis toggle

```
Group 4: Quick Add COAL/CBTO field
flutter analyze: 6 issues, 0 errors — unchanged from baseline
flutter test --exclude-tags=slow: 1368 passing + 1 skipped, 0 failed — unchanged
flutter test test/quick_add_coal_cbto_test.dart: 4 new slow-tagged tests passing
Summary:         COAL/CBTO axis toggle + dimension field added per file header.
Cold restart:    no
```

**Commit:** `75344d9` (3 files; 363 insertions, new test file).

**Files touched:**
- `lib/data/recipe_templates.dart`: added `cbtoIn` nullable double field to `RecipeTemplate`. Five shipping templates use only `coalIn`; `cbtoIn` stays null on all of them.
- `lib/screens/recipes/quick_add_recipe_screen.dart`:
  - Added `enum _DimensionAxis { coal, cbto }` (file-private, deliberately mirrors the same-named enum in `photo_import_review_screen.dart`; Phase Two item #7 unifies them).
  - Added `_DimensionAxis _axis = _DimensionAxis.coal` state.
  - Added `_dimension` TextEditingController + dispose pair.
  - Updated `_applyTemplate` to honor template COAL/CBTO: COAL takes precedence when both are set; CBTO if only CBTO is set; field cleared if neither set.
  - Updated `_buildCompanion` to write `coalIn` xor `cbtoIn` based on `_axis`; the inactive column is explicitly nulled to prevent stale values from before an axis swap.
  - Added the SegmentedButton + dimension TextFormField between Bullet Weight and Notes. Label + helper flip based on axis ("COAL (in)" / "CBTO (in)" + "Cartridge overall length" / "Cartridge base-to-ogive"). Suffix always "in".
- `test/quick_add_coal_cbto_test.dart` (new): 4 slow-tagged widget tests covering default axis, axis toggle, CBTO-mode save, COAL-mode save (the last two exercise end-to-end including a drift round-trip via `recipeRepo.allOnce()`).

**Test-plumbing fight, fully documented in the test file's header:**

1. The first run failed with `find.text('COAL')` matching 0 widgets — the SegmentedButton was below the 800x600 default test viewport in the lazy-built ListView. Fixed by setting `tester.view.physicalSize = Size(800, 2400)` in the harness so every tile builds.
2. The second run failed with "Timer is still pending after widget tree was disposed" — `BeginnerModeService._hydrate()` schedules an unawaited Future via `SharedPreferences.getInstance()` that outlives `pumpAndSettle()`. Fixed by pre-warming `SharedPreferences.getInstance()` once in setUp + an explicit `pumpWidget(SizedBox.shrink()) + pumpAndSettle()` at the end of assertion-only tests to dispose the prior tree before the framework's `!timersPending` invariant check.
3. The third run failed with `find.widgetWithText(ButtonSegment<dynamic>, 'CBTO')` matching 0 — `ButtonSegment` is a data class, not a Widget; the ancestor search fails. Dropped that line; `find.text('CBTO').first` works for tapping the segment label directly.
4. The fourth run failed with `scrollUntilVisible(find.widgetWithText(FilledButton, 'Save Recipe'), 300)` throwing "Too many elements" — the lazy ListView builds widgets transiently during scroll. Replaced with a direct tap (viewport is tall enough that the button is always in the tree).

Each fix is documented in the test file with comments so a future test author hits these once, not four times.

---

### Group 5 — Unified Recipe Import landing screen

```
Group 5: Unified Recipe Import landing screen
flutter analyze: 6 issues, 0 errors — unchanged from baseline
flutter test --exclude-tags=slow: 1389 passing + 1 skipped, 0 failed (+14 new source-enum tests)
flutter test test/recipe_import_landing_screen_test.dart: 4 slow-tagged tests passing
Summary:         Single canonical import entry point with file-extension routing.
                 ImportOptionsSection collapsed from 6 recipe-import tiles to a single
                 "Import a Recipe" tile pushing the new landing screen.
Cold restart:    yes (new route registered)
```

**Commit:** `ccabcd8` (5 files; 706 insertions / 154 deletions).

**Files added:**
- `lib/screens/recipes/recipe_import_source.dart`: `enum RecipeImportSourceKind` (10 values: 7 live + 3 Coming Soon), `bool isLiveRecipeImportKind(kind)` exhaustive-switch discriminator, `RecipeImportSourceKind? detectKindFromFileExtension(name)` case-insensitive helper.
- `lib/screens/recipes/recipe_import_landing_screen.dart`: `RecipeImportLandingScreen` Scaffold + ListView with 5 live tiles, Coming Soon block with 3 disabled tiles, explanatory section for Garmin .fit. `static push(context, onImported:)` convenience. `_openFilePicker` runs picked filename through `detectKindFromFileExtension` and dispatches via `_routeFor`. Spreadsheet pushes `SpreadsheetImportScreen(initialFile:)`, photo pushes `PhotoImportScreen()`, JSON re-imports via `LoadoutFileImportService.importFromJson` reading the picked file's contents, QR pushes `RecipeQrScanScreen.route()`, clipboard materialises text to a temp `.csv` and routes through the spreadsheet wizard.
- `test/recipe_import_source_test.dart`: 14 unit tests covering `detectKindFromFileExtension` + `isLiveRecipeImportKind`.
- `test/recipe_import_landing_screen_test.dart`: 4 slow-tagged widget tests covering page title, always-on live tiles, Coming Soon tile count + chip count, disabled-tile assertion.

**Files modified:**
- `lib/widgets/import_options_section.dart`: collapsed 6 recipe-import tiles (spreadsheet, photo, QR, file, another-app CSV, clipboard) into ONE "Import a Recipe" tile that pushes the landing screen. Kept the AI Smart Import settings deep-link tile + 3 cloud-restore tiles (different concepts from per-recipe import). Removed 5 private route handlers (`_openSpreadsheetWizard`, `_openPhotoImport`, `_openRecipeQrScan`, `_runLoadoutFileImport`, `_openAnotherAppCsvImport`, `_runClipboardImport`). Pruned imports accordingly; analyzer caught one I over-pruned (the `_CloudImportRow` class lower in the file still uses RecipeRepository / safeAsync / LoadoutFileImportService) and I restored those.

**Design discussion — Garmin .fit landing-screen route deferred to Phase Two:**

The spec line 327 said "Garmin .fit routes to the existing inline-on-recipe-form handler (with a small refactor to expose it as a standalone method on a service)." That "small refactor" turned out to be larger than Group 5 should swallow:

- The form-side `_onImportGarminFit` is tightly coupled to the recipe form's state — it writes the session summary into the form's `_notes` text controller, default-fills the `_chronographUsed` controller, and fires `_autoSave.notifyDirty()`. A context-free service would have no place to put the parsed data.
- The right end state is probably: landing-screen `.fit` opens a recipe form pre-loaded with the .fit summary in notes. But that requires adding an `initialNotes` parameter (or richer initial-draft handling) to `RecipeFormScreen`.

Phase One Group 5 instead surfaces an informational SnackBar from the landing screen tile pointing the user at the recipe form's Pro Tools section. Documented in the source enum's docstring + the landing screen's file header + Engineering.md § 19.4. Phase Two completes the route.

**Design discussion — AI Smart Import + cloud restore NOT moved to the landing screen:**

The spec said "every 'import a recipe' affordance routes through the landing screen, including the buttons currently inside `ImportOptionsSection`." AI Smart Import is a recipe IMPROVEMENT overlay (the `_ImproveWithAiCard` photo-review overlay), not a recipe-by-recipe import. The cloud-restore tiles restore from an encrypted full-DB backup — also a different concept. Both stayed on `ImportOptionsSection` as separate non-import tiles. Engineering.md § 19.1 documents the distinction.

**Surprise during this group:** my landing-screen widget test asserted `findsNWidgets(3)` for "Coming Soon" text — actual was 4 because I rendered a section heading "Coming Soon" above the disabled tiles. Updated to `findsNWidgets(4)` with a comment explaining the +1.

---

### Group 6 — Engineering.md final pass

```
Group 6: Engineering.md final pass
flutter analyze: 6 issues, 0 errors — unchanged from baseline
flutter test --exclude-tags=slow: 1389 passing + 1 skipped, 0 failed — unchanged
Summary:         Docs reflect post-Phase-One state; every "ships in Phase One Group N"
                 status note flipped to current state.
Cold restart:    no
```

**Commit:** `de39404` (1 file; 28 insertions / 29 deletions).

**Files touched:** `Engineering.md` only.

**Flipped sections:**
- § 5 manifest version 15 → 16 (manifest moved during the Phase 9.8 / Phase 10 work interleaved with Phase One).
- § 8 AI Smart Import naming clarification: future-tense → past-tense.
- § 10 file layout: removed `smart_import_screen.dart`, added live entries for `spreadsheet_import_screen.dart`, `recipe_import_landing_screen.dart`, `recipe_import_source.dart`. `widgets/import_options_section.dart` line rewritten to describe the shim shape.
- § 13 in-flight phase: Phase 9.8 → Phase 10 Groups A-C. Phase One Recipes marked complete with pointer to § 19.10.
- § 16 test counts: 1344 → 1389 (with +45 breakdown inline so future audits don't have to reverse-engineer).
- § 19.1 file inventory: every "Ships in Phase One Group N" status flipped to "Live" with a parenthetical citing the Group that delivered it.
- § 19.3 services: `caliberLabelForBulletDiameter` flipped from "ships in Group 3" to live.
- § 19.4 import architecture: rewritten lede from "today they're reached via separate tiles ... Phase One Group 5 introduces" to "all reached through a single canonical entry point". Source-taxonomy table Status column flipped. `garminFit` honestly described as live on the recipe form, landing-screen route deferred.
- § 19.4 Garmin .fit per-source flow note: rewritten to current state.
- § 19.8 Quick Add COAL/CBTO line: rewritten from "ships in Group 4" to live with implementation contract.
- § 19.9 caliber-from-diameter: rewritten as unified description of the live implementation.

§ 19.10 Phase Two queue (recipes surface) was already in the supplied draft; left as-is.

---

## Discussion points + concerns raised during the phase

### Engineering.md "ships in Group N" status notes pattern (Group 1)

The spec line 100-101 introduced an approach I hadn't used before: a target-state doc that explicitly marks parts of itself as "not yet shipped" via per-section status notes. The pattern works well — it means the doc describes the architecture you want even before code catches up, and Group 6's final pass is just a search-replace from "ships in Group N" to "live." Recommend using this pattern on future multi-group phases.

### Sidecar `.claude/settings.local.json` modifications

This file is gitignored-but-tracked permission-accumulation state. Across the six commits, it grew by ~30 lines of new "Bash(...)" auto-allow entries from the work itself. I deliberately left it modified (unstaged) every commit rather than sweeping it into Phase One commits. Operator should decide whether to commit-and-curate or revert. NOT a Phase Two item per spec scope; raised here as a sidecar.

### l10n facade not regenerating from `flutter pub get` (Pre-flight)

A fresh checkout / cold worktree hits 8 errors on `flutter analyze` from missing `lib/l10n/app_localizations.dart`. The fix is one-time `flutter gen-l10n` (the project has `flutter: generate: true` in `pubspec.yaml` per § 16 of `lib/services/component_field.dart`-style internal docs). Documented in Engineering.md § 11 as a local-setup gotcha. Phase Two item: investigate why the pub-get → gen-l10n trigger doesn't fire and either fix it or document a `tool/setup.sh` wrapper.

### Widget test stability — pending-Timer footgun (Group 4)

Encountered during Group 4 and now part of the project's test patterns:
1. Any test that pumps a widget tree containing a `BeginnerModeService` consumer must pre-warm `SharedPreferences.getInstance()` in setUp.
2. Assertion-only tests (no Save tap, no Navigator.pop) must explicitly dispose the widget tree at the end via `pumpWidget(SizedBox.shrink())` + `pumpAndSettle()`.

Documented in `test/quick_add_coal_cbto_test.dart`'s file header so the next widget-test author doesn't repeat the four-iteration debugging cycle.

### `SmartImportEntry` typedef left in place (Group 2)

A dead `typedef SmartImportEntry = SpreadsheetImportScreen` in the renamed file has no callers — verified via `grep -rnE "SmartImportEntry"`. Removing it would be a "while I'm in here" cleanup per CLAUDE.md § 0b rule 4 and spec line 14 — deliberately not done. Phase Two cleanup if anyone cares.

### Garmin .fit landing-screen route deferred (Group 5)

The original spec contemplated landing-screen → file-picker → `.fit` → `GarminXeroService.importFitFile` parse → "drop summary into a recipe." The form-side handler is tightly coupled to the recipe form's state controllers. A clean landing-screen route needs either (a) a new `initialNotes` parameter on RecipeFormScreen or (b) a context-free `.fit` import flow that ends in a fresh-recipe-form push pre-loaded with the summary. Both are bigger than Group 5 scope. The landing-screen tile today shows an informational SnackBar pointing the user at the recipe form. Phase Two completes.

### Photo tile UX collision (Group 5)

The landing screen has two photo tiles: "Take a Photo" and "Pick From Gallery." Both currently route to the same `PhotoImportScreen()`, which has its own internal source picker. This is honest about the existing UX (no behavior change) but is suboptimal from a "one tap to action" perspective. Phase Two item: either give `PhotoImportScreen` a constructor parameter to skip the internal source picker when the landing screen has already disambiguated, OR collapse the two tiles into one.

### Phase 10 + Phase 9.8 work interleaved with Phase One

Phase One Recipes ran across the same time window as Scene Painter Phase 9.8.B.3 / 9.8.B.4 / 9.8.C / 9.8.D + Phase 10 Groups A-C + the AppBar overflow hotfix. Each Phase One group's `git pull --ff-only` absorbed 3-6 unrelated commits before my own commit landed. No conflicts arose — different file regions throughout — but the `flutter test` baselines drifted slightly between groups as the other work added its own tests. Group 6's count breakdown explains the +45 vs the 2026-05-13 baseline.

---

## Phase Two queue (documented in Engineering.md § 19.10)

| # | Item | Origin |
|---|---|---|
| 1 | Quick → Regular bridge redesign (pick A/B/C from the spec) | Original spec |
| 2 | Custom fields Pro gate audit | Original spec |
| 3 | `ComponentField` `kind: String` → enum | Original spec |
| 4 | Recipe templates → `assets/seed_data/recipe_templates.json` | Original spec |
| 5 | `ComponentField` listener-leak hardening (parent-owns-controller refactor) | Original spec |
| 6 | Unified `RecipeDraftEditor` widget — collapse photo / multi-page review states | Original spec |
| 7 | Unified field taxonomy `_FieldId` ↔ `FieldId` → canonical `RecipeFieldId` | Original spec |
| 8 | New import sources go Live — Word `.docx`, OneNote, Garmin Xero photo | Original spec |
| 9 | `_pruneSelection` → Stream transform in `recipes_list_screen.dart` | Original spec |
| 10 | Two-save-paths consolidation in `recipe_form_screen.dart` | Original spec |
| 11 | Schema-version history reconstruction (walk `database.dart`'s MigrationStrategy) | Original spec |

**Added during Phase One** (not in the original spec):

| Item | Origin | Detail |
|---|---|---|
| Garmin .fit landing-screen route | Group 5 discussion | Extract the form-side `_onImportGarminFit` handler into a context-free service so the landing screen can invoke it. Touches `RecipeFormScreen` constructor surface. |
| l10n facade gen-l10n trigger investigation | Pre-flight | `flutter pub get` doesn't always regenerate `.dart_tool/flutter_gen/gen_l10n/`. Document in `tool/setup.sh` or fix the trigger. |
| `caliber_families.json` seed migration | Group 3 TODO | Move `_kCaliberFamiliesByDiameter` to a seed JSON + drift table so the catalog live-update pipeline (§ 5) covers it. |
| `SmartImportEntry` typedef removal | Group 2 sidecar | Dead, no callers, intentionally left in place this phase. |
| Photo tile UX collision on landing screen | Group 5 discussion | Two tiles ("Take a Photo" / "Pick From Gallery") route to the same `PhotoImportScreen` which has its own internal source picker. Collapse or pass a constructor hint. |

---

## Final-gates summary

| Gate | Baseline (pre-Phase-One) | Final (post-Phase-One) | Delta |
|---|---|---|---|
| `flutter analyze` | 6 issues, 0 errors | **6 issues, 0 errors** | Unchanged |
| `flutter test --exclude-tags=slow` | 1344 passing + 1 skipped | **1389 passing + 1 skipped** | **+45 tests** (+24 caliber + 14 source-enum + 7 from interleaved Phase 9.8/10 work) |
| Slow widget tests | n/a | **8 new** (4 Quick Add COAL/CBTO + 4 landing screen) | Verified via direct file runs |
| Manifest version | 15 | 16 | Bumped during interleaved seed-data work |
| Schema version | v40 | v40 | Unchanged (no migrations this phase) |
| Recipes screens | 8 | 10 | +2 (`recipe_import_landing_screen.dart`, `recipe_import_source.dart`) |
| Renamed files | 0 | 1 | `smart_import_screen.dart` → `spreadsheet_import_screen.dart` |

## Commit ledger (chronological)

| # | Commit | Title |
|---|---|---|
| 1 | `e139f93` | Engineering.md: Phase One Group 1 baseline sync |
| 2 | `c495dc1` | Phase One Group 2: rename smart_import_screen -> spreadsheet_import_screen |
| 3 | `46f28fd` | Phase One Group 3: caliber-from-diameter -> ComponentRepository |
| 4 | `75344d9` | Phase One Group 4: COAL/CBTO axis toggle on Quick Add |
| 5 | `ccabcd8` | Phase One Group 5: unified Recipe Import landing screen |
| 6 | `de39404` | Phase One Group 6: Engineering.md final pass |

All six commits on `main`, pushed to `origin/main`. No reverts, no hotfixes, no follow-up patches within the phase.

---

## What the operator needs to do that I cannot

| Item | Why I can't | What you'd actually do |
|---|---|---|
| Decide `.claude/settings.local.json` curation | Permission-accumulation file; commit policy is operator-judgment | Either commit + audit, or revert the accumulated auto-allows |
| Approve the AppBar title copy ("Smart Import" → ?) | UI-chat decision per spec line 155 | Pick the new user-visible title; I'll update `_SpreadsheetImportScreenState` build accordingly |
| Cross-device QA on the landing screen | Real-device smoke is operator-only | Cold-restart on iOS + Android, walk the 5 live tiles + 3 Coming Soon tiles, confirm each route lands on the expected screen |
| Pick a Phase Two ordering | Operator priority decision | Choose from the 16-item queue above |
| Decide whether to ship Garmin .fit landing-screen route in Phase Two or defer further | Product decision — depends on Garmin Xero customer signal | If shipping, the implementation path is documented above |

---

## Sidecar cleanup items (not committed; for operator awareness)

- `.claude/settings.local.json` accumulated ~30 lines of new Bash auto-allow entries from the work. Left modified (unstaged) every commit. Not in any Phase One commit.
- `.claude/scheduled_tasks.lock` is a worktree-local lock from a misfired `ScheduleWakeup` I called once during Group 2 (wrong tool — that tool is for `/loop` dynamic mode). Harmless; gitignored.

---

End of report.
