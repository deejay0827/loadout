# Scene Painter Phase 7a — Phase Report

**Date:** 2026-05-12
**Branch:** `claude/infallible-panini-8b20d1` (worktree off `main`)
**Commit delivered:** `bdf279e` — on `origin/main`
**Prior reports:** [SCENE_PAINTER_PHASE_6_REPORT.md](SCENE_PAINTER_PHASE_6_REPORT.md), [SCENE_PAINTER_PHASE_5_REPORT.md](SCENE_PAINTER_PHASE_5_REPORT.md), [SCENE_PAINTER_PHASE_4_REPORT.md](SCENE_PAINTER_PHASE_4_REPORT.md), [SCENE_PAINTER_PHASE_3_REPORT.md](SCENE_PAINTER_PHASE_3_REPORT.md), [SCENE_PAINTER_PHASE_2_REPORT.md](SCENE_PAINTER_PHASE_2_REPORT.md), [TARGET_RENDER_FIX_SESSION_REPORT.md](TARGET_RENDER_FIX_SESSION_REPORT.md)
**Spec source:** [`SCENE_PAINTER_PHASE_7A.md`](file:///Users/general/Downloads/SCENE_PAINTER_PHASE_7A.md) (delivered by user, plus `loadout_phase7_handoff.zip` for project context)

---

## 1. Headline

Four scoped changes in four halt-and-validate groups. Addresses the operator's Phase 6 visual-QA feedback:

1. **Tap-to-zoom restored** — inline preview was tap-dead since Phase 3's `_TargetThumbnail` → `TargetPlot` swap. TargetPlot's internal GestureDetector was winning the gesture arena over the outer InkWell. Fixed with `IgnorePointer`.
2. **Animal pole shifts right (`horizontal_from_left: 0.7`)** — JSON-only update on all 16 animal rows. Phase 6's `center_point` plumbing consumes it automatically. Pole moves 20% right within each animal silhouette, anchoring under the hindquarters of left-facing animals instead of through the front legs.
3. **Foreground tree** — new painter helper for depth cue. Single tree silhouette at x = 0.85W, height ≈ 1.2× target box height. Inserted between tall grass and mound in the paint order.
4. **`svg_scale_factor` per target (v37→v38)** — new drift column + JSON field + painter scale multiplier. 7 problem animals (deer/elk/moose/etc.) get values 1.2-1.4 so their authored SVGs overflow the rect (antlers extend into sky), bottom-aligned so the body stays seated.

Plus an unexpected bonus: while I was working, the operator concurrently committed `ipsc.svg` to disk AND added the `loadTargetPath('ipsc')` preload to `main.dart` — closing the Phase 6 known gap. My branch rebased onto those commits cleanly.

---

## 2. Scope of this phase

### What got done

| Group | Sub-item | File(s) |
|---|---|---|
| **A** | Wrap `TargetPlot` in `IgnorePointer` so inner GestureDetector doesn't win the arena | `lib/screens/range_day/range_day_detail_screen.dart` |
| **B** | `horizontal_from_left: 0.7` on all 16 animal rows | `assets/seed_data/targets.json` |
| **B** | Manifest bump (8→9; targets 5→6) | `assets/seed_data/manifest.json` |
| **C** | `_paintForegroundTree` helper + tree palette constants | `lib/screens/range_day/widgets/target_plot.dart` |
| **C** | Paint-order rewire (tree between tall grass and mound) | `lib/screens/range_day/widgets/target_plot.dart` |
| **D.1** | Schema 37→38 + `svgScaleFactor` RealColumn (default 1.0) + migration | `lib/database/database.dart` |
| **D.1** | Regen `database.g.dart` via `build_runner` | `lib/database/database.g.dart` |
| **D.2** | `TargetSpec.svgScaleFactor` field + `fromRow` plumbing | `lib/screens/range_day/widgets/target_plot.dart` |
| **D.3** | Seed loader reads `svg_scale_factor` from JSON | `lib/database/seed_loader.dart` |
| **D.4** | 7 problem animals get `svg_scale_factor` values 1.2-1.4 | `assets/seed_data/targets.json` |
| **D.5** | `AnimalSilhouettes` + `TargetSilhouettes`: `scalePathToBounds` and `cachedScaledPath` accept optional `scaleFactor` | `lib/widgets/animal_silhouettes.dart`, `lib/widgets/target_silhouettes.dart` |
| **D.5** | `resolveTargetSvgPath` threads `scaleFactor` to both helpers | `lib/screens/range_day/widgets/target_plot.dart` |
| **D.5** | `_RealisticScenePainter._paintTarget` passes `target.svgScaleFactor` | `lib/screens/range_day/widgets/target_plot.dart` |
| **Tests** | Schema assertion 37→38; new `svgScaleFactor` test | `test/database_schema_v35_test.dart` |

### What did NOT get done (deferred per spec §2)

| Deferred to | Item |
|---|---|
| Phase 7b | Real SVG path parser for bigfoot (path-inversion + white-fill filter) |
| Phase 8 | Per-animal SVG asset re-authoring in Inkscape (only if scale_factor doesn't satisfy) |
| Phase 9+ | Reticle / scope ring / aim crosshair / shot impact dots |
| Phase 10+ | Rack target rendering rewrite (legacy `_RealisticTargetPainter` untouched) |
| Future | Wind animation on the foreground tree (helper built; no animation code) |

No `_paintIpscSilhouette` deletion attempt — that function lives in the legacy `_RealisticTargetPainter` which is fenced off per spec §2.

---

## 3. Files changed

### Commit `bdf279e Scene Painter Phase 7a: Tap-to-Zoom + Animal Pole-Right + Foreground Tree + svgScaleFactor`

| File | Operation | Net lines |
|---|---|---|
| [lib/database/database.dart](lib/database/database.dart) | EDIT — schema 37→38, new `svgScaleFactor` column, v38 migration step | +25 / -1 |
| [lib/database/database.g.dart](lib/database/database.g.dart) | REGEN | (generated) |
| [lib/database/seed_loader.dart](lib/database/seed_loader.dart) | EDIT — parse `svg_scale_factor` from JSON, write column | +10 / -0 |
| [lib/screens/range_day/widgets/target_plot.dart](lib/screens/range_day/widgets/target_plot.dart) | EDIT — `TargetSpec.svgScaleFactor` field + factory; `resolveTargetSvgPath` plumbs scaleFactor; `_paintForegroundTree` helper + constants; paint-order rewire | +88 / -16 |
| [lib/screens/range_day/range_day_detail_screen.dart](lib/screens/range_day/range_day_detail_screen.dart) | EDIT — wrap `TargetPlot` in `IgnorePointer` for tap-to-zoom | +9 / -1 |
| [lib/widgets/animal_silhouettes.dart](lib/widgets/animal_silhouettes.dart) | EDIT — `cachedScaledPath` + `scalePathToBounds` accept `scaleFactor` | +24 / -8 |
| [lib/widgets/target_silhouettes.dart](lib/widgets/target_silhouettes.dart) | EDIT — same `scaleFactor` plumbing for symmetry | +18 / -6 |
| [assets/seed_data/targets.json](assets/seed_data/targets.json) | EDIT — 16 animals get `horizontal_from_left: 0.7`; 7 get `svg_scale_factor` | +23 / -16 |
| [assets/seed_data/manifest.json](assets/seed_data/manifest.json) | EDIT — `manifest_version` 8→9, `files.targets.version` 5→6 | +2 / -2 |
| [test/database_schema_v35_test.dart](test/database_schema_v35_test.dart) | EDIT — schema assertion 37→38, new v38 column test | +49 / -3 |

Total: 10 files, +369 / -57.

---

## 4. Code detail — Group A (tap-to-zoom fix)

### Diagnosis

The spec said "the GestureDetector that called `_showTargetPreviewDialog` was lost when Phase 3 swapped `_TargetThumbnail` for `TargetPlot`." That diagnosis was partially right — but the actual issue was subtler.

Phase 5's `_targetVisualBox` already had an outer `Material + InkWell` calling `_showTargetPreviewDialog`. So the tap router WAS present. The problem: `TargetPlot` has its own internal `GestureDetector` ([target_plot.dart:494](lib/screens/range_day/widgets/target_plot.dart:494)) that consumed pointer events before they could bubble to the outer InkWell — Flutter's gesture arena gives priority to the most-specific (deepest) recognizer when both could handle the gesture.

### Fix

The spec's prescription (`GestureDetector(behavior: HitTestBehavior.opaque)`) wouldn't have fixed this — the inner GestureDetector still claims hits in its area regardless of the outer detector's hit-test behaviour. The correct mechanism is `IgnorePointer` around `TargetPlot`, which disables hit testing entirely for that subtree:

```dart
final preview = SizedBox(
  height: 234,
  child: IgnorePointer(            // NEW — disables TargetPlot's internal gestures
    child: TargetPlot(
      target: activeTargetSpec,
      shots: const [],
      onTapAt: (_, _) {},
      onLongPressShot: (_) {},
      tapMode: TargetPlotTapMode.aimPoint,
      viewMode: TargetPlotViewMode.realistic,
      colorHexOverride: _selectedTargetColorHex,
    ),
  ),
);
// Existing Material + InkWell wrapper preserved → taps now reach it
// and route to _showTargetPreviewDialog.
```

Outer `InkWell` retained so the tap produces a visual ripple feedback. Best of both worlds.

---

## 5. Code detail — Group B (animal pole-right)

JSON-only change. 16 animal rows updated:

```json
"center_point": {
  "vertical_from_top": 0.5,
  "horizontal_from_left": 0.7
}
```

Non-animal rows (poppers, IPSC, plates, rectangles, Texas Star) untouched at the Phase 6 default `0.5`.

Phase 6's painter consumes this field without further code change:

```dart
final poleX = targetRect.left + cp.horizontalFromLeft * targetRect.width;
```

At 0.7 instead of 0.5, `poleX` shifts 20% of the rect's width to the right. For left-facing animal silhouettes (head left, body right), this places the pole under the hindquarters rather than the front legs.

---

## 6. Code detail — Group C (foreground tree)

### New constants

```dart
static const double _treeHeightFracOfTarget = 1.2;
static const double _treeXFracOfCanvas = 0.85;
static const Color _treeTrunkColor = Color(0xff5c3a1e); // dark brown
static const Color _treeCrownColor = Color(0xff4a6a2f); // dark conifer green
```

### Helper

```dart
void _paintForegroundTree(
  Canvas canvas,
  double w,
  double horizonY,
  double targetBoxH,
) {
  final treeHeight = targetBoxH * _treeHeightFracOfTarget;
  final treeX = w * _treeXFracOfCanvas;
  const double trunkW = 4.0;
  final trunkH = treeHeight * 0.35;
  final crownRadius = treeHeight * 0.32;

  // Trunk rooted at horizon
  canvas.drawRect(
    Rect.fromLTWH(treeX - trunkW / 2, horizonY - trunkH, trunkW, trunkH),
    Paint()..color = _treeTrunkColor,
  );

  // Three overlapping circles for a leafy crown
  final crownCenter = Offset(treeX, horizonY - trunkH - crownRadius);
  final crownPaint = Paint()..color = _treeCrownColor;
  canvas.drawCircle(crownCenter, crownRadius, crownPaint);
  canvas.drawCircle(
    crownCenter.translate(-crownRadius * 0.55, crownRadius * 0.25),
    crownRadius * 0.7, crownPaint);
  canvas.drawCircle(
    crownCenter.translate(crownRadius * 0.55, crownRadius * 0.25),
    crownRadius * 0.7, crownPaint);
}
```

### New paint order

```
 1. Sky
 2. Distant hills
 3. Treeline
 4. Grass field
 5. Tall grass clumps
 6. Foreground tree          (NEW — Phase 7a)
 7. Mound
 8. Pole
 9. Horizon grass tufts
10. Pole base ring
11. Target
```

Tree paints AFTER tall grass and BEFORE mound — establishes depth between foreground grass and dirt pile. Tree x = 0.85W; target rect is centered; they don't overlap.

---

## 7. Code detail — Group D (svg_scale_factor)

### Schema

```dart
RealColumn get svgScaleFactor =>
    real().withDefault(const Constant(1.0))();
```

Migration step (defensive via `_columnsOf` + `delete(targets).go()` for re-seed):

```dart
if (from < 38) {
  final targetsCols = await _columnsOf('targets');
  if (!targetsCols.contains('svg_scale_factor')) {
    await m.addColumn(targets, targets.svgScaleFactor);
  }
  await delete(targets).go();
}
```

### Silhouette scaler

```dart
static Path scalePathToBounds(
  Path source,
  Rect bounds, {
  double scaleFactor = 1.0,
}) {
  final src = source.getBounds();
  if (src.width <= 0 || src.height <= 0) return source;

  final scaleX = bounds.width / src.width;
  final scaleY = bounds.height / src.height;
  final fitScale = scaleX < scaleY ? scaleX : scaleY;  // uniform fit
  final scale = fitScale * scaleFactor;                // NEW

  final scaledWidth = src.width * scale;
  final scaledHeight = src.height * scale;
  final dx = bounds.left + (bounds.width - scaledWidth) / 2 - src.left * scale;
  final dy = bounds.bottom - scaledHeight - src.top * scale;  // bottom-align preserved

  final matrix = Matrix4.identity()
    ..translate(dx, dy)
    ..scale(scale, scale);
  return source.transform(matrix.storage);
}
```

Bottom-alignment is preserved at any `scaleFactor`. At >1.0 the silhouette overflows the rect's TOP edge (antlers / horns / tail feathers extend into the canvas sky region); the bottom stays seated at `bounds.bottom`. No clipping.

### Animals tuned in this phase

| Animal | Scale | Reason |
|---|---|---|
| deer | 1.4 | Antlers stretch SVG taller than body |
| mule_deer | 1.4 | Same — antlers |
| elk | 1.3 | Big antlers, body already larger |
| moose | 1.4 | Tall body + antlers |
| pronghorn | 1.2 | Small horns, mostly body |
| wild_turkey | 1.2 | Tall stance, head/neck |
| pheasant | 1.2 | Tall stance, tail feathers |

The spec listed **`bighorn_ram` at 1.3** as well — but that row doesn't exist in the catalog (verified by listing all 16 animals: bear, bigfoot, boar, coyote, deer, elk, fox, groundhog, moose, mountain_lion, mule_deer, pheasant, prairie_dog, pronghorn, rabbit, wild_turkey). Skipped that one.

Other 9 animals (bear, boar, mountain_lion, coyote, fox, rabbit, groundhog, prairie_dog, bigfoot) omit the field → default 1.0 via the drift column.

---

## 8. Bonus: operator's concurrent commits

While I was working, the operator committed two things directly to `main`:

| Commit | Touched |
|---|---|
| `a777683 Added file.` | New file `assets/silhouettes/targets/ipsc.svg` (9922 lines) |
| `94bf265 updated pic` | Updated `ipsc.svg` (18520/9459 lines net) AND `lib/main.dart` (+1 line — the `TargetSilhouettes.loadTargetPath('ipsc')` preload I flagged in the Phase 6 report) |

This closes the Phase 6 known gap. With the SVG file present and the preload call in `main.dart`, the IPSC dispatch flips from procedural fallback to authored SVG automatically on next cold start — the catalog already carries `shape_id: 'ipsc'` on the 6 IPSC rows (from Phase 6).

My branch rebased cleanly onto these commits (their files don't overlap with any of mine), so the final main timeline reads:

```
bdf279e Scene Painter Phase 7a              <-- my work (rebased)
94bf265 updated pic                          <-- operator
a777683 Added file.                          <-- operator
f47f295 Add Scene Painter Phase 6 report
c73ec72 Scene Painter Phase 6
```

---

## 9. Verification

| Gate | Before phase | After phase |
|---|---|---|
| `flutter analyze` | 6 issues (Phase 6 baseline) | **6 issues, 0 new** |
| `flutter test` | 1292/1292 passing | **1293/1293 passing** (+1 for the new v38 test) |
| Schema version | 37 | **38** |
| `targets.json` animals at `horizontal_from_left: 0.7` | 0 / 16 | **16 / 16** |
| `targets.json` animals with `svg_scale_factor` set | 0 / 7 | **7 / 7** |
| `manifest_version` | 8 | **9** |
| `files.targets.version` | 5 | **6** |
| `build_runner` | — | Clean; new `GeneratedColumn` for `svgScaleFactor` |
| Pushed to `origin/main` | — | ✅ |

---

## 10. Operator visual QA (for you to run on device)

Per spec §5:

| Surface | Expected after Phase 7a |
|---|---|
| Bear, inline | Same as Phase 6 (bear's `svg_scale_factor` = 1.0). Pole shifted 20% right within the bear rect (now under the hindquarters / back). Foreground tree visible at right edge of canvas. |
| Bear, tap-to-zoom | **Opens the dialog** (Group A fix). Larger canvas, same scene composition. |
| Deer, inline | Deer noticeably bigger; antlers extend visibly above the target rect into the sky region. Pole shifted right within the deer rect. |
| Elk / Moose, inline | Same pattern at 1.3 / 1.4 scale. |
| IPSC, inline | Pole still centered (IPSC's `horizontal_from_left` = 0.5; non-animal stayed at 0.5). IPSC SVG now renders from the operator's `ipsc.svg` (bonus operator commit). |
| Mountain lion / fox, inline | **Unchanged** (their `svg_scale_factor` defaults to 1.0). Confirms the default codepath is preserved. |
| Texas Star (procedural) | Procedural fallback still renders. Foreground tree visible. |

### Cold-restart required

To see the JSON changes, the app must cold-start so SeedUpdater + drift v38 migration re-seed the catalog with new `horizontal_from_left` and `svg_scale_factor` values. Hot-reload alone won't pick up data changes.

---

## 11. Tuning knobs

If after visual QA any of the per-animal values feel off:

| Symptom | Knob |
|---|---|
| Antlers still feel cramped on deer / elk | Bump `svg_scale_factor` for that row in `targets.json` (e.g. deer 1.4 → 1.5) |
| Body too big — bear-sized | Lower `svg_scale_factor` (e.g. moose 1.4 → 1.25) |
| Pole still through the front legs | Bump `horizontal_from_left` to 0.75 or 0.80 |
| Pole too far back on small animals | Per-row override — set the animal's `horizontal_from_left` to a smaller value (e.g. rabbit 0.55) |
| Foreground tree too tall / short | `_treeHeightFracOfTarget` (currently 1.2) |
| Foreground tree too close to target | `_treeXFracOfCanvas` (currently 0.85; lower = leftward) |

All values are deterministic and per-row tunable via `targets.json` + manifest bump.

---

## 12. Deviations from spec

| Spec § | Spec said | I did | Why |
|---|---|---|---|
| §A.2 | `GestureDetector(behavior: HitTestBehavior.opaque)` | `IgnorePointer` + existing `InkWell` | `behavior:opaque` doesn't override gesture-arena priority for hits inside the inner detector's area. `IgnorePointer` is the correct mechanism (verified by reading [target_plot.dart:494](lib/screens/range_day/widgets/target_plot.dart:494)). |
| §D.4 | 8 problem animals (including `bighorn_ram` 1.3) | 7 problem animals | `bighorn_ram` doesn't exist in the catalog. Other 7 spec values applied as-is. |

---

## 13. Rollback

Phase 7a is a single commit (`bdf279e`) plus the report commit. Per spec §6, prefer leaving the unused v38 column rather than writing a downgrade migration:

```sh
git -C /Users/general/Development/Applications/LoadOut/ revert bdf279e
git -C /Users/general/Development/Applications/LoadOut/ push origin main
```

That undoes code, JSON, and asset changes. The `svgScaleFactor` drift column stays on disk but `TargetSpec.fromRow` reverts to ignoring it; rows default to 1.0; runtime matches pre-Phase-7a.

The operator's `ipsc.svg` + `main.dart` preload commits are independent and not affected by a Phase 7a revert.

---

## 14. What's next

Phase 7b (independent of 7a): real SVG path parser for bigfoot — path-inversion via `Path.combine(PathOperation.difference, ...)` + white-fill path filter in `animal_silhouettes.dart`'s `_extractAndCombinePaths`.

Phase 8: per-animal SVG asset re-authoring in Inkscape — only relevant if Phase 7a's scale_factor tuning doesn't visually satisfy after operator QA.

Phase 9+: reticle / scope ring / aim crosshair / shot dots back into single-target realistic mode.

Phase 10+: rack target rendering rewrite (retire legacy `_RealisticTargetPainter`).

Future: wind animation on the foreground tree — Phase 7a built the helper shape but no animation code; pairs naturally with a `windDirection` field on `Range Day` session state.
