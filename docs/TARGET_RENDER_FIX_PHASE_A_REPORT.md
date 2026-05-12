# Target Render Fix — Phase A Progress Report

**Branch:** `claude/infallible-panini-8b20d1` (worktree off `main`)
**Date:** 2026-05-12
**Pack applied:** `loadout_target_render_fix_v1.zip` (delivered by user, dated 2026-05-12)
**Phase complete:** A of 6 (catalog replacement). Phases B–F awaiting go-ahead.

---

## 1. What the pack contained

A six-phase coordinated fix for four observed rendering bugs in LoadOut v2.3:

| # | Bug | Root cause (pack's diagnosis) | Fix layer |
|---|---|---|---|
| 1 | Bear/Boar/Deer/Elk/Coyote rendering as procedural cartoons (4 stick legs, round head, dot eye) instead of authored SVGs | `AnimalSilhouettes` preloads 16 SVGs but no painter calls `pathFromCache` to draw them; painters dispatch `shape: "bear"` to a hand-drawn `_paintAnimal` cartoon | New unified `paintTargetShape` dispatch reads `shape_id` and routes to the SVG cache |
| 2 | 36×60 rectangle renders as a square in the realistic-scene preview | Suspected: layout aspect-cap interaction or camelCase/snake_case mismatch in seed loader | Catalog unification + painter rewrite + defensive aspect assertion guard |
| 3 | Missing pole between rectangle target and dirt mound in realistic scene | Suspected: target's bottom overlapping pole's top due to bug #2, or color blend with mound | Investigation steps + defensive paint-order option |
| 4 | Catalog had 8 broken-camelCase animal duplicate entries with vital-zone copy never wired in | Phase 2 migrated to snake_case for animals but left the old camelCase rows behind; nothing read the `notes` field | Wholesale catalog overhaul: 58 rows, all snake_case |

**Pack file inventory:**

| Path in pack | Operation | Maps to |
|---|---|---|
| `assets/seed_data/targets.json` | Replace wholesale | same path |
| `lib/widgets/target_shape_dispatch.dart` | Create new file | same path |
| `patches/animal_silhouettes.patch.md` | Apply str-replace edit | `lib/widgets/animal_silhouettes.dart` |
| `patches/target_silhouettes.patch.md` | Apply str-replace edit | `lib/widgets/target_silhouettes.dart` |
| `patches/scope_daytime_backdrop.patch.md` | Apply 4 edits (deletes) | `lib/widgets/scope_daytime_backdrop.dart` |
| `patches/target_plot.patch.md` | Apply 7 edits | `lib/screens/range_day/widgets/target_plot.dart` |
| `patches/range_day_detail_screen.patch.md` | Apply 4 edits | `lib/screens/range_day/range_day_detail_screen.dart` |
| `spec/SCHEMA_AND_LOADER_SPEC.md` | Apply across 4 files | drift schema + `TargetSpec` + seed loader |

---

## 2. Verification audit (before any edit)

Dispatched an `Explore` agent to confirm the pack's 11 claims about the current codebase. **Every claim verified true.** Key findings:

| Claim | Verified | Citation |
|---|---|---|
| `targets.json` has 65 rows, mixed casing (49 camelCase + 16 snake_case animal rows) | ✅ | `assets/seed_data/targets.json` |
| Seed loader reads both case variants but **drops `shape_id`** | ✅ | [seed_loader.dart:815-838](lib/database/seed_loader.dart:815) reads `width_in`/`widthIn` fallback chain but ignores `shape_id` entirely. **This is the root cause of bug #1** — the user's authored bear.svg is loaded into cache but the discriminator never reaches `TargetSpec`. |
| `TargetSpec` has no `shapeId` field | ✅ | [target_plot.dart:165](lib/screens/range_day/widgets/target_plot.dart:165) confirmed |
| Drift `schemaVersion` is 35 | ✅ | [database.dart:2319](lib/database/database.dart:2319) confirmed |
| `Targets` table has no `shapeId` column | ✅ | [database.dart:1508](lib/database/database.dart:1508) confirmed |
| `pathFromCache` synchronous accessors missing | ✅ | [animal_silhouettes.dart:123](lib/widgets/animal_silhouettes.dart:123) has `_pathCache` private map; [target_silhouettes.dart:99](lib/widgets/target_silhouettes.dart:99) same. Neither exposes a synchronous read — that's why `CustomPainter.paint` (synchronous, can't await) cannot consume the cache. |
| All five animal enum values + `_paintAnimal` still present | ✅ | [scope_daytime_backdrop.dart:110-126](lib/widgets/scope_daytime_backdrop.dart:110) enum values; line 858 method declaration |
| `target_shape_dispatch.dart` doesn't exist | ✅ | file absent — needs creation in Phase D |
| Painters at expected line numbers | ✅ | `_paintTargetSilhouette:1412`, `_drawSilhouette:1914`, `_paintIpscSilhouette:1472`, `_paintPole:1142` all match |
| `_TargetThumbnailPainter` cartoon helpers at expected line numbers | ✅ | `_paintAnimal:9890`, `_paintIpscSilhouette:9693`, `_paintPopper:9779`, `_paintTexasStar:10065` all match |
| Seed loader function | ✅ | `_seedTargets()` at [seed_loader.dart:815](lib/database/seed_loader.dart:815) |

**Conclusion:** The pack's diagnosis is internally consistent and matches the live codebase. No surprises. Safe to proceed.

---

## 3. Phase A — what changed

**Sole edit:** replaced `assets/seed_data/targets.json` with the pack's 58-row unified-schema version.

| Metric | Before | After |
|---|---|---|
| Row count | 65 | 58 |
| Rows with camelCase keys (`widthIn` / `heightIn`) | 49 | 0 |
| Rows with snake_case keys (`width_in` / `height_in`) | 16 | 58 |
| Rows with `shape_id` field | 16 (animals only) | 18 (16 animals + 2 poppers) |
| Animal rows with vital-zone duplicate copy | 8 broken | 0 |
| Rectangle rows with two-dimension names | partial | 15/15 (all rectangles + NRA + F-Class + Bullseye + Dueling Tree) |

**Rectangle entries (all 15 now have dimensions in the name):**

- `Rectangle 12×18 in` through `Rectangle 36×60 in` (6 base rectangles)
- `NRA SR-1 Reduced 12.71×12.71 in (100 yd)`, `NRA SR-21 19×19 in (200 yd)`, `NRA MR-1 21×21 in (300 yd)`, `NRA LR 36×36 in (600 yd)`
- `F-Class F-Open 72×72 in (1000 yd)`, `F-Class F-T/R 36×36 in (600 yd)`
- `Bullseye Slow-Fire Pistol 10.5×10.5 in (25 yd)` and `(50 yd)`
- `Dueling Tree 36×60 in`

---

## 4. Pre-flight asset-map check

Before copying, validated that every `shape_id` in the new catalog resolves to a real asset via the existing `_shapeIdToAsset` maps:

| Source | Count | Result |
|---|---|---|
| Animal asset map ([animal_silhouettes.dart:102-119](lib/widgets/animal_silhouettes.dart:102)) | 16 entries | All 16 catalog animal `shape_id` values resolve cleanly |
| Target asset map ([target_silhouettes.dart](lib/widgets/target_silhouettes.dart)) | 7 entries | All 2 catalog popper `shape_id` values resolve cleanly |
| Unrecognized `shape_id` values | — | 0 (none) |

---

## 5. Issues encountered + resolutions

| Status | Issue | Resolution |
|---|---|---|
| ⚠️ then ✅ | Initial sanity-check script reported "16 missing SVGs" because I was looking for `bear_profile.svg` directly on disk | False alarm. The `shape_id` values are **logical keys** that map to physical filenames (`bear.svg`, etc.) via `_shapeIdToAsset`. Corrected the check to read the actual asset map; all 18 references resolved. |
| ⚠️ then ✅ | First `flutter analyze` returned 14 issues including 8 hard errors on `AppLocalizations` / `l10n/app_localizations.dart` | Diagnosed as pre-existing — the worktree had never run `flutter pub get`, so the `gen_l10n` generated facade wasn't on disk. Per CLAUDE.md §16, this is the expected behavior of Flutter's first-party l10n pipeline. Ran `flutter pub get`, which regenerated the missing files; analyze dropped to 6 baseline infos. **None of the 14 issues were caused by Phase A.** |

---

## 6. Final Phase A verification

```
flutter pub get        → 0 errors, 2 untranslated-message warnings (pre-existing, pt_BR + sv)
flutter analyze        → 6 issues, all pre-existing infos:
                          - 2× <path> HTML-in-doc-comment infos in animal_silhouettes.dart
                          - 2× deprecated Matrix4.translate/scale infos in animal_silhouettes.dart
                          - 2× deprecated Matrix4.translate/scale infos in target_silhouettes.dart
                         0 new issues from Phase A
flutter test           → 1290/1290 passing (+1289 ~1 skipped). No regressions.
```

Test count is 1290; the pack's PROMPT.md anticipated 1271. The suite has grown since the pack was authored — unrelated to this work.

---

## 7. Files touched

| File | Operation | Diff scope |
|---|---|---|
| `assets/seed_data/targets.json` | Wholesale replacement | 65 → 58 rows, uniform snake_case, +`shape_id` on 2 popper rows, simplified animal `notes` to "Side angle of a [animal] target.", every rectangle has dimensions in name |
| `pubspec.lock` | Auto-regenerated by `flutter pub get` | (no semantic change — same package versions) |
| `lib/l10n/app_localizations.dart` + 15 `app_localizations_*.dart` | Auto-generated by `flutter pub get` | (these are generated files; `flutter: generate: true` in pubspec triggers regen) |

**No source code changed in Phase A.** All `lib/` and `test/` files are untouched.

---

## 8. Files NOT touched (per pack's sensitive-file fence)

Per the PROMPT.md fence, the following are off-limits and were not opened, read, or modified:

- `lib/config/revenue_cat_config.dart`
- `lib/config/onedrive_config.dart`
- `lib/config/ai_*_config.dart`
- `lib/services/backup_crypto.dart`
- `lib/services/purchases_service.dart`
- `lib/services/auth_service.dart`
- `lib/services/biometric_service.dart`
- `lib/services/cloud_backup_service.dart`
- `ios/Runner/Info.plist`

Math-audit fence (also untouched, per Phase 3 v2.3 lock):

- `lib/services/solver.dart`
- `lib/services/hit_probability_service.dart`
- `lib/services/hit_probability_map_service.dart`

---

## 9. What remains (Phases B–F)

| Phase | Status | Scope |
|---|---|---|
| A — Catalog replacement | ✅ Complete | This phase |
| B — Schema + seed loader plumbing | ⏳ Awaiting go-ahead | Drift schema 35→36, add `shapeId TEXT NULL` column to `Targets` table, add migration step, add `String? shapeId` to `TargetSpec`, surface it through `TargetSpec.fromRow`, rewire `_seedTargets()` to read `shape_id` (and migrate to snake_case-only key reads). Touches 3 files: `lib/database/database.dart`, `lib/screens/range_day/widgets/target_plot.dart` (where `TargetSpec` lives), `lib/database/seed_loader.dart`. Includes a `dart run build_runner build` regen step. |
| C — SVG cache accessors | ⏳ Awaiting go-ahead | Add `static Path? pathFromCache(String shapeId)` to both `AnimalSilhouettes` and `TargetSilhouettes`. Purely additive; no existing call sites change. |
| D — New unified dispatch file | ⏳ Awaiting go-ahead | Copy `lib/widgets/target_shape_dispatch.dart` from the pack. Self-contained file that imports `animal_silhouettes.dart`, `target_silhouettes.dart`, and `scope_daytime_backdrop.dart`. |
| E — Painter unification + cartoon deletion | ⏳ Awaiting go-ahead | Three patches: delete 5 animal enum values + `_paintAnimal` from `scope_daytime_backdrop.dart`; rewire `_paintTargetSilhouette` + `_drawSilhouette` in `target_plot.dart` (7 edits including the rectangle-aspect Edit 6 and missing-pole Edit 7 investigations); delete `_paintAnimal` + `_paintIpscSilhouette` + `_paintPopper` from `range_day_detail_screen.dart` and replace dispatch switch with `paintTargetShape`. |
| F — Visual QA report for project lead | ⏳ Awaiting go-ahead | Produce a checklist for manual on-device verification: animal SVGs render correctly across picker / preview / realistic scene; 36×60 rectangle is tall in realistic scene; pole is visible between target and mound; IPSC silhouette matches USPSA Metric spec; Pepper Popper renders authored SVG. |

---

## 10. Risk assessment going into Phase B

Phase B is the single most invasive phase in the plan because it bumps the drift schema version. Considerations:

| Risk | Severity | Mitigation in the pack |
|---|---|---|
| Schema migration corrupts existing user installs | 🟢 Low | The migration only adds a nullable column (`shapeId TEXT NULL`). No data rewrite, no constraint changes. Forward-compatible with v35 data — rollback is "revert the bump and re-run build_runner". |
| `build_runner` regen produces stale `database.g.dart` | 🟢 Low | The `--delete-conflicting-outputs` flag is in the PROMPT.md command. Standard pattern in this repo. |
| `TargetSpec` field addition breaks existing constructors | 🟢 Low | The pack specifies `String? shapeId` with default `null`, additive on the constructor — every existing call site keeps working. |
| `test/database_schema_v35_test.dart` asserts the old version | ⚠️ Possible | Need to copy to v36 variant if such a test exists. PROMPT.md flags this. |

No irreversible actions in Phase B. Safe to proceed on user go-ahead.

---

## 11. Recommendations going forward

| | Recommendation |
|---|---|
| 1 | Continue with **Phase B** next. Halt-and-report cadence per PROMPT.md. |
| 2 | Phase B's `dart run build_runner build --delete-conflicting-outputs` is the one command that can briefly leave `database.g.dart` in a broken state. If interrupted between schema edit and regen, re-run the build_runner command. |
| 3 | Phase E Edits 6 + 7 (rectangle aspect bug, missing pole) are documented as **investigation steps with a defensive fix candidate** rather than known fixes. Expect that this requires running the app on a device or simulator to confirm the symptom shape after Edits 1–5 land. Visual QA in Phase F is where these surface. |
| 4 | The pack flags **Texas Star realistic scene** as a known regression deferred to v2.4. Not in scope for this fix. |
| 5 | The pack flags **startup-crash investigation + Range Day error investigation** as separate work items. Not in scope for this fix. |

---

## 12. Rollback (if needed before any further phase)

Phase A is fully self-contained:

```sh
git checkout -- assets/seed_data/targets.json
```

That single command reverts everything. The `flutter pub get` artifacts (`lib/l10n/app_localizations*.dart`) are .gitignored generated files and don't need explicit cleanup.

The drift schema is still v35 (Phase B hasn't run), so no migration cleanup is needed.
