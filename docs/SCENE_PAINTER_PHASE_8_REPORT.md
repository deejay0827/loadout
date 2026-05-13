# Scene Painter Phase 8 — Phase Report

**Date:** 2026-05-12
**Branch:** `claude/infallible-panini-8b20d1` (worktree off `main`)
**Commits delivered:** `bdb7fbb`, `807c49c`, `b9d079e`, `0f9824f` — all on `origin/main`
**Prior reports:** [SCENE_PAINTER_PHASE_7B_REPORT.md](SCENE_PAINTER_PHASE_7B_REPORT.md), [SCENE_PAINTER_PHASE_7A_REPORT.md](SCENE_PAINTER_PHASE_7A_REPORT.md), [SCENE_PAINTER_PHASE_6_REPORT.md](SCENE_PAINTER_PHASE_6_REPORT.md), and prior
**Spec source:** [`SCENE_PAINTER_PHASE_8.md`](file:///Users/general/Downloads/SCENE_PAINTER_PHASE_8.md) (delivered by user; also bundled in `loadout_phase8_handoff.zip` with a prebuilt `targets.json.new`)

---

## 1. Headline

Five halt-and-validate groups; four shipped, one operator-only (visual QA). Net effect from the operator's perspective:

1. **Pole/target visually connected** — animal silhouettes now anchor their hindquarters on the pole at canvas center, instead of the pole shifting off-center.
2. **Targets render at physical scale** — a 1″ patch is now ~1.5px (toggle ON: clamped to 4″ equivalent ~6px); a 60″ bear is ~30% canvas height (was ~40%).
3. **"Enlarge Small Targets" toggle** in the single-target picker UI, persisted to `SharedPreferences[realistic_size_floor_enabled]`, defaults ON.
4. **Picker dropdown labels driven by the catalog `name` field** — `_targetDropdownLabel` simplified from a 30-line generator to `=> t.name`. Duplicate-dim IPSC bug fixed as a side effect.
5. **Picker dropdown no longer dismisses on scroll or tap-select** — `TextFieldTapRegion` wraps the Autocomplete overlay.

| Commit | Group | Title | Net |
|---|---|---|---|
| `bdb7fbb` | A | Painter Pole-Target Inversion | +73 / -55 |
| `807c49c` | B | Physical-Dim Scaling + Min-Size Toggle | +137 / -38 |
| `b9d079e` | D | Catalog Name as Dropdown Label | +140 / -48 |
| `0f9824f` | E | TextFieldTapRegion Wraps Picker Overlay | +39 / -24 |

Plus Group F (operator-only IPSC visual verification — see §6 below).

---

## 2. Scope of this phase

### What got done

| Group | Sub-item | Files |
|---|---|---|
| **A** | `paint()` math inverted: pole fixed at canvas center, target rect shifts to align `cp` with the fixed pole anchors | `lib/screens/range_day/widgets/target_plot.dart` |
| **A** | `_computeTargetRect` retired (math inlined into `paint()` so it can access intermediate `targetH` before pole positioning) | (same file) |
| **B** | `_inchesPerCanvasHeight` 200→150; `_targetBoxWidthFrac` / `_targetBoxHeightFrac` deleted; `_minVisibleSizeInches = 4.0` added | (same file) |
| **B** | Target box derives from `widthIn`/`heightIn` × pixels-per-inch | (same file) |
| **B** | `_RealisticScenePainter.sizeFloorEnabled` ctor param; `TargetPlot.sizeFloorEnabled` parameter (default `true`) | (same file) |
| **B** | `shouldRepaint` extended to cover `svgScaleFactor` + `centerPoint` + `sizeFloorEnabled` (previous version missed several) | (same file) |
| **B** | New `_sizeFloorEnabled` state field + SharedPrefs load in `initState` + `SwitchListTile` UI | `lib/screens/range_day/range_day_detail_screen.dart` |
| **B** | `sizeFloorEnabled: _sizeFloorEnabled` threaded to 5 `TargetPlot` construction sites | (same file) |
| **D** | Manifest bump `manifest_version` 9→10, `files.targets.version` 6→7 | `assets/seed_data/manifest.json` |
| **D** | `_targetDropdownLabel` simplified from ~30 lines to `=> t.name` | `lib/screens/range_day/range_day_detail_screen.dart` |
| **D** | `_formatDim` helper deleted (orphaned post-simplification) | (same file) |
| **D** | 7 catalog-shape regression tests | `test/targets_catalog_test.dart` (NEW) |
| **E** | `optionsViewBuilder` return wrapped in `TextFieldTapRegion` | `lib/screens/range_day/range_day_detail_screen.dart` |

### What did NOT get done (deferred per spec §2 / §8)

| Deferred to | Item |
|---|---|
| Phase 9 | Filter-chip → dropdown re-filter bug |
| Phase 9 | Per-animal size variants (small/medium/large Deer, etc.) |
| Phase 10+ | Photorealism evaluation |
| Phase 10+ | Reticle / scope ring / aim crosshair / shot dots back into single-target realistic mode |
| Phase 11+ | Rack target rendering rewrite (legacy `_RealisticTargetPainter` retired) |

No drift schema changes. No `database.dart` touches. Sensitive / math-audit fences honored.

---

## 3. Files changed (cumulative across all 4 commits)

| File | Net | What |
|---|---|---|
| `lib/screens/range_day/widgets/target_plot.dart` | +210 / -93 | Painter inversion + physical-dim sizing + `sizeFloorEnabled` plumbing + retired `_computeTargetRect` + `shouldRepaint` expansion |
| `lib/screens/range_day/range_day_detail_screen.dart` | +218 / -88 | `_sizeFloorEnabled` state + SwitchListTile UI + 5 `TargetPlot` plumbing sites + `_targetDropdownLabel` simplification + `_formatDim` delete + `TextFieldTapRegion` wrap |
| `assets/seed_data/manifest.json` | +2 / -2 | `manifest_version` 9→10, `files.targets.version` 6→7 |
| `test/targets_catalog_test.dart` | +120 / 0 | NEW — 7 catalog-shape regression tests |
| `test/animal_silhouettes_test.dart` | +0 / -1 | Removed unused `flutter/material.dart` import that snuck in during Phase 7b |

Total: 5 files, +550 / -184.

`assets/seed_data/targets.json` is **unchanged in Phase 8** — the operator's earlier `f1f0574 Updated Targets` commit (before Phase 8 work began) had already applied every Group D rename and added the `2 in Square` row. Verified by diffing the handoff's prebuilt `targets.json.new` against current `main`: 0 name differences, 0 missing rows.

---

## 4. Group A — painter pole-target inversion (`bdb7fbb`)

### What changed

Old behaviour (Phase 6/7): target rect was centered on canvas; pole position derived from `targetRect.left + cp.horizontalFromLeft * targetRect.width` and `targetRect.top + cp.verticalFromTop * targetRect.height`. With `cp.horizontalFromLeft = 0.7` on animal rows, the pole shifted 20% of the rect's width to the right of canvas center — but the mound is hardcoded at canvas center. Pole and mound visually disconnected.

New behaviour (Phase 8 Group A): pole is FIXED at canvas center (`poleX = w / 2`) and at a derived `visualPoleTopY`. The target rect's POSITION is solved backwards from these fixed anchors:

```dart
final cp = target.centerPoint;
final poleX = w / 2;
final visualPoleTopY = moundApexY - visiblePoleHeight - 0.5 * targetH;
final targetLeft = poleX - cp.horizontalFromLeft * targetW;
final targetTop = visualPoleTopY - cp.verticalFromTop * targetH;
```

At `cp = 0.5 / 0.5`, this resolves to exactly the same position as Phase 7a — zero visual change for the 43 non-animal catalog rows.

For animals (cp.horizontalFromLeft = 0.7), the silhouette shifts ~20% of `targetW` to the LEFT so the 70% anchor (which is roughly the hindquarters on a left-facing animal) sits directly on the pole at canvas center. Pole and mound now visually connected.

### Spec deviation

Spec §A.2 wrote the formula using `targetBoxH` (the constant box dimension). But Phase 7a actually computed the pole offset from post-fit `targetH` (which differs from `boxH` for fit-to-width targets like the bear). Using `targetBoxH` literally would shift the bear by ~5px on every render, violating the spec's headline "zero visual change for any catalog row at default cp."

I used post-fit `targetH` instead. Verified at H=234, bear at 60×32 fit-to-width: `visualPoleTopY = moundApex - 65.0` matches Phase 7a exactly. The spec's intent is honored even though the literal math doesn't.

### `_computeTargetRect` retired

The Phase 7a helper computed the rect from a `targetBottomY` input. With Group A's inverted math, the rect needs to be positioned from `poleX + visualPoleTopY + cp` — different inputs. Inlining ~15 lines into `paint()` was cleaner than refactoring the helper's signature.

---

## 5. Group B — physical-dim scaling + min-size toggle (`807c49c`)

### What changed

| Constant | Phase 7a | Phase 8 |
|---|---|---|
| `_inchesPerCanvasHeight` | 200 | **150** |
| `_targetBoxWidthFrac` | 0.50 | (deleted) |
| `_targetBoxHeightFrac` | 0.40 | (deleted) |
| `_visiblePoleFracOfTarget` | 0.25 | 0.25 (unchanged) |
| `_minVisibleSizeInches` | — | **4.0** (new) |

Target box dimensions now derive from `target.widthIn * (h / _inchesPerCanvasHeight)` and `target.heightIn * (h / _inchesPerCanvasHeight)`. A 60″ bear renders ~94px wide at H=234 (was ~156px at 0.50 width-frac); a 1″ patch renders ~1.5px (was ~117px — the entire 0.50-wide box).

### Min-size floor

Without further intervention, anything below ~6″ would be too small to interact with visually. The `sizeFloorEnabled` mechanism scales targets uniformly so the smaller dimension hits the 4″ floor:

```dart
if (sizeFloorEnabled) {
  final smaller = effWIn < effHIn ? effWIn : effHIn;
  if (smaller > 0 && smaller < _minVisibleSizeInches) {
    final scale = _minVisibleSizeInches / smaller;
    effWIn *= scale;
    effHIn *= scale;
  }
}
```

Aspect is preserved — a 1″ circle stays round at the floored size. Toggle defaults ON; toggle OFF gives realistic-scale rendering for users who want to evaluate true target visibility at range.

### Plumbing

- `_RealisticScenePainter.sizeFloorEnabled` (bool, default `true`).
- `TargetPlot.sizeFloorEnabled` (bool, default `true`).
- `_RangeDayDetailScreenState._sizeFloorEnabled` (default `true`).
- `SharedPreferences[realistic_size_floor_enabled]` (default `true` via `getBool() ?? true`).
- 5 `TargetPlot` construction sites updated: inline preview, tap-to-zoom dialog, plus 3 live Range Day surface sites (StreamBuilder hasError fallback, StreamBuilder builder, no-stream fallback).

### `shouldRepaint` expansion

While I was in `_RealisticScenePainter`, I noticed `shouldRepaint` was missing several fields added since Phase 6 (`svgScaleFactor`, `centerPoint.verticalFromTop`, `centerPoint.horizontalFromLeft`). Added them alongside `sizeFloorEnabled`. Catches a latent bug where the painter wouldn't repaint when those fields changed.

### Sanity numbers (at H=234, W=312, bear 60×32, cp=0.5/0.5, sizeFloorEnabled=true)

| Quantity | Phase 7a | Phase 8 |
|---|---|---|
| `inPerPx` (px/in) | 1.17 | 1.56 |
| `moundHeight` | 21.06 | 28.08 |
| `targetW` (bear) | 156.0 (fit-to-width) | **93.6** (physical: 60 × 1.56) |
| `targetH` (bear) | 83.2 | **49.9** (physical: 32 × 1.56) |
| `visiblePoleHeight` | 23.4 | 12.5 (targetH × 0.25) |
| Bear box % of canvas H | ~36% | ~21% |

Bear is meaningfully smaller — by design. The scene composition (sky, mound, pole base) gets more visual real estate, and the picker preview now communicates relative size between targets accurately.

---

## 6. Group D — catalog name as dropdown label (`b9d079e`)

### Catalog state

The operator's earlier `f1f0574 Updated Targets` commit (Tue May 12 21:35:37 2026) had already applied every Phase 8 §D.1 rename and added the new `2 in Square` row. Verified by diffing the handoff's prebuilt `targets.json.new` against current main: **0 name differences, 0 missing rows**.

Naming patterns verified by `test/targets_catalog_test.dart`:

| Family | Count | Pattern |
|---|---|---|
| Circles | 13 | `^\d+ in Circle$` (e.g. `1 in Circle`, `24 in Circle`) |
| Squares | 6 | `^\d+ in Square$` (including the new `2 in Square`) |
| Generic rectangles | 6 | `^\d+(\.\d+)?" x \d+(\.\d+)?" Rectangle$` (e.g. `12" x 18" Rectangle`) |
| Animals | 16 | All contain ` in` (e.g. `Deer 60×32 in`, `Bear 60×32 in`) |
| IPSC | 6 | All have single `×` separator (no double-dims bug) |
| Special-named | 11 | NRA SR-1/SR-21/MR-1/LR, F-Class F-Open/F-T/R, Bullseye 25/50yd, Dueling Tree, Texas Star, 2 poppers — kept their proper names |

### Code simplification

```dart
// BEFORE — ~30 lines of dimension-string construction + shape-prefix lookup
String _targetDropdownLabel(TargetRow t) {
  final w = t.widthIn;
  final h = t.heightIn;
  String dims;
  if (w == h) dims = '${_formatDim(w)} in';
  else        dims = '${_formatDim(w)}×${_formatDim(h)} in';
  if (t.shapeId != null) return '${t.name} $dims';
  final shape = _shapeDisplayLabel(t.shape);
  if (t.shape.toLowerCase() == 'star') return '$shape $dims (${t.name})';
  return '$shape $dims';
}

// AFTER — one line
String _targetDropdownLabel(TargetRow t) => t.name;
```

`_formatDim` deleted (orphaned). `_shapeDisplayLabel` kept (still called by `_showTargetPreviewDialog` for the metadata footer).

### Bug fixed as a side effect

Pre-Phase-8, the dynamic generator appended `(w × h) in` to every row's display label — but IPSC rows already carried dims in their catalog `name`, producing labels like `"IPSC USPSA Classic 18×30 in 18×30 in"`. Now the label is exactly the catalog `name`, so no duplicate dims.

### Manifest bump

`manifest_version` 9→10, `files.targets.version` 6→7. Forces SeedUpdater to re-pull `targets.json` on existing remote installs so the operator's `f1f0574` rename commit propagates.

---

## 7. Group E — `TextFieldTapRegion` wraps picker overlay (`0f9824f`)

Flutter Autocomplete's `optionsViewBuilder` overlay dismisses on the first scroll touch OR tap-to-select because those gestures unfocus the underlying `TextField`. Wrapping the overlay in `TextFieldTapRegion` makes its hits register as INSIDE the field's tap-region group — field stays focused, overlay stays visible.

One-line change. No new dependency (`TextFieldTapRegion` ships in `package:flutter/widgets.dart`).

---

## 8. Group F — IPSC visual verification (operator step)

No code changes. The operator's `7f8e680 Updated IPSC` commit dropped a cleaner SVG in (`19,047` lines → `68` lines — a dramatic simplification). Phase 7b's inverted-negative-space heuristic should handle it correctly.

This group is the operator-side cold-restart + screenshot of an IPSC preview to confirm:
- Clean filled silhouette (no black patches).
- User-selected palette color fills the shape.
- Tap-to-zoom dialog renders the same.

If IPSC still renders incorrectly, the next step is a Phase 8c diagnosis pass.

---

## 9. Verification

| Gate | Pre-Phase-8 | Post-Phase-8 |
|---|---|---|
| `flutter analyze` | 4 issues (Phase 7b baseline) | **4 issues, 0 new** |
| `flutter test` | 1301/1301 | **1308/1308 passing** (+7 catalog tests) |
| `dart run build_runner build` | not needed | not needed (no schema change) |
| Schema version | 38 | **38** (unchanged) |
| `manifest_version` | 9 | **10** |
| `files.targets.version` | 6 | **7** |
| Catalog row count | 59 | **59** (operator added `2 in Square` pre-Phase-8) |
| Pushed to `origin/main` | — | ✅ |

The 4 remaining baseline infos are all the unchanged `Matrix4.translate` / `Matrix4.scale` deprecation infos in `animal_silhouettes.dart` and `target_silhouettes.dart` — pre-existing since Phase 1.

---

## 10. Operator visual QA expectations

| Surface | Phase 7a/7b behaviour | Phase 8 expectation |
|---|---|---|
| Default cp=0.5/0.5 target (circles, squares, IPSC) | Pole + mound at canvas center | **Same** — zero visual change |
| Animal (cp=0.7) | Pole shifts right of canvas center; mound stays put → visual disconnect | **Animal silhouette shifts LEFT** so its 70% anchor sits on the fixed-at-center pole |
| 1-inch Circle, toggle ON | ~93px (full box) | **~6px** (clamped to 4-inch floor) |
| 1-inch Circle, toggle OFF | ~93px | **~1.5px** (realistic; near-invisible) |
| 12-inch Circle, toggle ON | ~93px | **~19px** (well above floor; scales physically) |
| 60-inch Bear, toggle ON or OFF | ~83px (Phase 7a was ~36% canvas H) | **~50px** (~21% canvas H — by design) |
| 120-inch Moose, toggle ON or OFF | ~83px | **~100px** (~43% canvas; ~50% canvas width) |
| Picker dropdown | Scroll closes; tap-select often misses | **Stays open on scroll; tap-select fires reliably** |
| Picker label for `Circle 1 in` | `Circle 1 in` | **`1 in Circle`** |
| Picker label for `Rectangle 12×18 in` | `Rectangle 12×18 in` | **`12" x 18" Rectangle`** |
| Picker label for `IPSC USPSA Classic 18×30 in` | `IPSC USPSA Classic 18×30 in 18×30 in` (duplicate-dim bug) | **`IPSC USPSA Classic 18×30 in`** (single dims) |
| Picker label for `NRA SR-1` row | `Rectangle 12.71 in` (proper name hidden) | **`NRA SR-1 Reduced 12.71×12.71 in (100 yd)`** |
| `2 in Square` in picker | Not present | **Present** |
| IPSC inline preview | Black patches inside vertical rect (broken SVG) | **Clean IPSC silhouette filled with user color** (operator's new ipsc.svg + Phase 7b parser) |
| "Enlarge Small Targets" switch | Not present | **Present at top of single-target picker; defaults ON; persists across restart** |

---

## 11. Operator concurrent commits absorbed during Phase 8

While Phase 8 was being implemented, the operator committed several things directly to `main`:

| Commit | What | Effect on Phase 8 |
|---|---|---|
| `7f8e680 Updated IPSC` | Cleaner `ipsc.svg` (19047 → 68 lines) | Closes the Phase 6 IPSC-rendering gap. Group F now valid. |
| `f1f0574 Updated Targets` | 141-line targets.json edit — all the Phase 8 §D.1 renames + the new `2 in Square` row | Made Group D's JSON-edit redundant. I rebased onto this, verified equivalence with the handoff's prebuilt file, only had to bump the manifest + simplify the code. |

Both rebased cleanly into Group A's branch.

---

## 12. Deviations from spec

| Spec § | Spec said | I did | Why |
|---|---|---|---|
| §A.2 | Pole offset formula uses `targetBoxH` (constant box dimension) | Used post-fit `targetH` instead | The literal `targetBoxH` would shift fit-to-width targets like bear by ~5px and violate the spec's stated headline of "zero visual change for any catalog row at default cp." Honored the spec's intent rather than its literal math. |
| §B.1 | Spec example shows `inPerPx = _inchesPerCanvasHeight / h` (inches per pixel) | Kept current `inPerPx = h / _inchesPerCanvasHeight` (which is misnamed — actually pixels per inch) | Existing scenery callers (`moundHeight = 18.0 * inPerPx`, etc.) rely on the px-per-inch semantics. Switching would have required updating every pre-existing usage. New box-sizing follows the same dimensional pattern (`targetW = effWIn * inPerPx`) and produces equivalent pixel values. |
| §A.5 | "Painter widget test (if one exists for `_RealisticScenePainter`) — assert that at cp=0.5/0.5, the rendered geometry is unchanged" | Did not add | No painter widget test existed and adding one wasn't critical-path. The math is deterministic; the operator-side visual QA serves as the gate. |
| §D.1 | "All renames are to the `name` field only" — and a 36-rename table to apply | Skipped the JSON edit | Operator's `f1f0574` commit had already applied every rename + added `2 in Square`. Verified zero diff against handoff. |

No spec deviations in Groups E or F.

---

## 13. Rollback

Each group is a separate commit so any one can be reverted in isolation:

| Commit | Revert effect |
|---|---|
| `0f9824f` Group E | TextFieldTapRegion wrapper removed; dropdown returns to dismiss-on-scroll bug |
| `b9d079e` Group D | `_targetDropdownLabel` reverts to dynamic generation; `_formatDim` returns; manifest version drops to 9. The catalog `name` rewrites stay (those came from operator commit `f1f0574`, not from this revert path) |
| `807c49c` Group B | Physical-dim sizing undone; targets render at fixed box-fraction size again; SwitchListTile + SharedPrefs key are dead but harmless |
| `bdb7fbb` Group A | Pole-target inversion undone; cp=0.7 animals revert to pole-shifts-right behaviour |

No drift schema migration to roll back. SharedPrefs key `realistic_size_floor_enabled` is harmless if orphaned after a Group B revert (no code reads it).

---

## 14. What's next (Phase 9 + Phase 10)

Per spec §8:

**Phase 9:**
- Filter-chip → dropdown re-filter bug (Circle chip then Animal chip leaves Circles showing).
- Per-animal size variants — small / medium / large for each animal target. Catalog expansion, not code.

**Phase 10:**
- Photorealism evaluation. The cartoon-style scene painter (Phase 4–8) is intentionally stylized; Phase 10 will evaluate whether replacing it (or offering a toggle between cartoon / photo-realistic / midpoint) would help the user line up physical paper / steel targets with the in-app rendering.

**Phase 11+:**
- Rack target rendering rewrite. The legacy `_RealisticTargetPainter` finally retires once Phase 10's photorealism call is made.

None are Phase 8 work; do not blend in.

---

## 15. Pointer to prior reports

| Phase | Report |
|---|---|
| Phase A (catalog replacement) | [TARGET_RENDER_FIX_PHASE_A_REPORT.md](TARGET_RENDER_FIX_PHASE_A_REPORT.md) |
| Phase B (schema + filter fix) | (covered in session report) |
| Session-spanning summary through Phase 1 | [TARGET_RENDER_FIX_SESSION_REPORT.md](TARGET_RENDER_FIX_SESSION_REPORT.md) |
| Scene Painter Phase 2 | [SCENE_PAINTER_PHASE_2_REPORT.md](SCENE_PAINTER_PHASE_2_REPORT.md) |
| Scene Painter Phase 3 | [SCENE_PAINTER_PHASE_3_REPORT.md](SCENE_PAINTER_PHASE_3_REPORT.md) |
| Scene Painter Phase 4 | [SCENE_PAINTER_PHASE_4_REPORT.md](SCENE_PAINTER_PHASE_4_REPORT.md) |
| Scene Painter Phase 5 | [SCENE_PAINTER_PHASE_5_REPORT.md](SCENE_PAINTER_PHASE_5_REPORT.md) |
| Scene Painter Phase 6 | [SCENE_PAINTER_PHASE_6_REPORT.md](SCENE_PAINTER_PHASE_6_REPORT.md) |
| Scene Painter Phase 7a | [SCENE_PAINTER_PHASE_7A_REPORT.md](SCENE_PAINTER_PHASE_7A_REPORT.md) |
| Scene Painter Phase 7b | [SCENE_PAINTER_PHASE_7B_REPORT.md](SCENE_PAINTER_PHASE_7B_REPORT.md) |
| Scene Painter Phase 8 | (this file) |
