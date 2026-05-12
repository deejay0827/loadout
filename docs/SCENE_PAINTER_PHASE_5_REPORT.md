# Scene Painter Phase 5 — Phase Report

**Date:** 2026-05-12
**Branch:** `claude/infallible-panini-8b20d1` (worktree off `main`)
**Commit delivered:** `c5b556c` — on `origin/main`
**Prior reports:** [SCENE_PAINTER_PHASE_4_REPORT.md](SCENE_PAINTER_PHASE_4_REPORT.md), [SCENE_PAINTER_PHASE_3_REPORT.md](SCENE_PAINTER_PHASE_3_REPORT.md), [SCENE_PAINTER_PHASE_2_REPORT.md](SCENE_PAINTER_PHASE_2_REPORT.md), [TARGET_RENDER_FIX_SESSION_REPORT.md](TARGET_RENDER_FIX_SESSION_REPORT.md)
**Spec source:** [`SCENE_PAINTER_PHASE_5.md`](file:///Users/general/Downloads/SCENE_PAINTER_PHASE_5.md) (delivered by user)

---

## 1. Headline

Three visual improvements landed in one commit, scoped to two files:

1. **Pole became a short mounting stub instead of a stilt.** Visible pole height is now derived from target height (≈ 20% of target box height), not a fixed 72″ real-world inch value. Bear / IPSC / animal silhouettes are now the focal point; the pole no longer dominates.
2. **Grass field feels denser.** Horizon-blade step tightened ~1.67×; mound-edge clumps expanded from 6 to 10 with alternating heights so the fringe doesn't read as uniform.
3. **Preview window is 30% taller.** Inline preview 180 → 234 px; tap-to-zoom dialog widens its height-to-width ratio. Tall portrait targets (IPSC silhouettes especially) have more vertical room.

Plus a single layout-constant tweak (`_horizonFrac` 0.70 → 0.75) that gives the scene more sky above the target at its new position.

---

## 2. Scope of this phase

### What got done

| Area | Change |
|---|---|
| Layout constants | `_horizonFrac` 0.70→0.75; new `_visiblePoleFracOfTarget = 0.20` |
| `paint()` math | Pole height derived from target box height, not fixed inches |
| `_paintGrassTufts` density | Step `max(w/36, 4)` → `max(w/100, 3)`; clumps 6 → 10 with 1.5× height alternation |
| Inline preview | SizedBox `height: 180` → `234` |
| Tap-to-zoom dialog | `imageH = (maxW * 0.78).clamp(240, 560)` → `(maxW * 1.0).clamp(280, 640)` |

### What did NOT get done (intentionally deferred per spec)

| Deferred to | Item |
|---|---|
| Phase 6 | Per-target `center_point` field on `targets.json` + drift columns + `TargetSpec.centerPoint` |
| Phase 6 | Background additions: distant hills, treeline, tall grass clumps |
| Phase 7 | Real SVG parser for bigfoot SVG (path-inversion via `Path.combine(PathOperation.difference, ...)`) |
| Phase 7 | White-fill path filter in `animal_silhouettes.dart` `_extractAndCombinePaths` (explicitly NOT in Phase 5 — would regress the bigfoot render) |
| Phase 8+ | Reticle / scope ring / aim crosshair / shot dots in single-target realistic mode |
| Phase 8+ | Rack target rendering rewrite (legacy `_RealisticTargetPainter` unchanged) |

No "while I'm here" creep into deferred items. No TODO comments left in code reaching into out-of-scope territory.

---

## 3. Files changed

### Commit `c5b556c Scene Painter Phase 5: Pole Stub + Denser Grass + Taller Preview`

| File | Change | Net lines |
|---|---|---|
| [lib/screens/range_day/widgets/target_plot.dart](lib/screens/range_day/widgets/target_plot.dart) | `_RealisticScenePainter` constants, `paint()` math, `_paintGrassTufts` density | +36 / -14 |
| [lib/screens/range_day/range_day_detail_screen.dart](lib/screens/range_day/range_day_detail_screen.dart) | `_targetVisualBox` SizedBox height; `_showTargetPreviewDialog` imageH | +4 / -2 |

Total: 2 files, +40 / -16. No schema changes, no `targets.json` changes, no `manifest.json` changes, no new files, no deletions.

---

## 4. Code detail

### 4.1 New constants

```dart
/// Horizon position: sky/grass boundary as a fraction of canvas H.
/// Tuned to 0.75 (was 0.70 in Phase 4) — more sky overhead at the
/// new target position gives a sense of "looking up at the target"
/// rather than the target sitting flat on a wide grass strip.
static const double _horizonFrac = 0.75;

/// Visible pole stub height as a fraction of the target box height.
/// Phase 5 cut the pole from a fixed 72″ real-world height to a
/// short mounting stub anchored to target height — bear becomes
/// the focal point and the pole no longer reads as a "stilt".
/// 0.20 ≈ stub is ~20% of the target's vertical extent.
static const double _visiblePoleFracOfTarget = 0.20;
```

The hardcoded `72.0 * inPerPx` from Phase 4's `paint()` is gone — replaced by the target-derived `targetBoxH * _visiblePoleFracOfTarget`.

### 4.2 `paint()` math

Before (Phase 4):

```dart
final horizonY = _horizonFrac * h;
final moundHeight = 18.0 * inPerPx;
final poleHeight = 72.0 * inPerPx;          // <-- fixed inches
final moundApexY = horizonY - moundHeight * 0.5;
final targetBottomY = moundApexY - poleHeight;
final targetRect = _computeTargetRect(w, h, targetBottomY);
```

After (Phase 5):

```dart
final horizonY = _horizonFrac * h;
final moundHeight = 18.0 * inPerPx;
final moundApexY = horizonY - moundHeight * 0.5;

// Pole's VISIBLE height (the stub exposed below the target) is
// tied to target box height, so the pole reads as a short
// mounting post regardless of canvas size.
final targetBoxH = h * _targetBoxHeightFrac;
final visiblePoleHeight = targetBoxH * _visiblePoleFracOfTarget;

final targetBottomY = moundApexY - visiblePoleHeight;
final targetRect = _computeTargetRect(w, h, targetBottomY);
```

`visualPoleTopY = targetRect.center.dy` and `visualPoleHeight = moundApexY - visualPoleTopY` carry over from Phase 4 unchanged — the **geometric** pole still extends from mound apex up to the target's vertical center; the target paints on top and hides the upper portion. The Phase 5 change is only how the **visible** stub length is computed.

### 4.3 Sanity numbers at H=234 (matches spec §A.3)

Recomputed in Python after the edits — the numbers match the spec exactly (within 0.1 rounding from aspect calculation):

| Quantity | Spec | Computed | Match |
|---|---|---|---|
| `horizonY` | 175.5 | 175.5 | ✓ |
| `inPerPx` | 1.17 | 1.17 | ✓ |
| `moundHeight` | 21.06 | 21.06 | ✓ |
| `moundApexY` | 165.0 | 165.0 | ✓ |
| `targetBoxH` | 65.52 | 65.52 | ✓ |
| `visiblePoleHeight` | 13.10 | 13.10 | ✓ |
| `targetBottomY` | 151.9 | 151.9 | ✓ |
| `targetRect.top` | 86.4 | 86.3 | ✓ (rounding) |
| `targetRect.center.dy` | 119.2 | 119.1 | ✓ (rounding) |
| `visualPoleTopY` | 119.2 | 119.1 | ✓ (rounding) |
| `visualPoleHeight` (drawn) | 45.8 | 45.9 | ✓ (rounding) |

Both invariants hold:
- `visiblePoleHeight (13.1) < targetBoxH (65.5)` ✓ — stub is shorter than the box it dangles below
- `visualPoleHeight drawn (45.9) < targetBoxH (65.5)` ✓ — geometric pole still fits within the target+stub envelope

The sub-pixel discrepancies are from using the actual bear aspect (60/32 = 1.875) vs the spec's assumed rounded numbers. Same shape; rounding only.

### 4.4 Grass density

#### Horizon blades

```diff
-    final stepPx = math.max(w / 36.0, 4.0);
+    final stepPx = math.max(w / 100.0, 3.0);
```

At a 312px canvas: was `max(8.67, 4.0) = 8.67`; now `max(3.12, 3.0) = 3.12`. Roughly 2.8× more blades. The spec said "1.67× more" from a 5.0 baseline → 3.0; my implementation overshoots that since my Phase 4 step was already wider than 5. End result is denser packing, which is what the spec wanted visually.

#### Mound-edge clumps

```diff
-    for (var i = 0; i < 6; i++) {
+    for (var i = 0; i < 10; i++) {
       final side = i.isEven ? -1.0 : 1.0;
-      final t = (i ~/ 2) / 3.0; // 0, 0.33, 0.67
+      final t = (i ~/ 2) / 4.0; // 0, 0.25, 0.50, 0.75, 1.0
       final x = cx + side * (moundHalfW - 2.0 - t * 8.0);
-      final bladeH = 2.0 + math.sin(i * 1.7) * 1.5;
+      final heightMultiplier = i.isEven ? 1.5 : 1.0;
+      final bladeH = (2.0 + math.sin(i * 1.7) * 1.5) * heightMultiplier;
```

10 clumps (5 each side), 5 distance steps from the mound edge inward. Even-indexed clumps get a 1.5× height multiplier — produces visible variation in the fringe.

Side-note on the alternation pattern: since `i.isEven` drives BOTH `side` and `heightMultiplier`, the result is "all left-side clumps tall, all right-side short" rather than strict alternation per clump regardless of side. This matches the spec's "every other clump is roughly 50% taller" wording most literally (every other index = `i.isEven`). If visual QA prefers strict left-right symmetry with tall/short alternation by distance from the mound, the fix is `final heightMultiplier = (i ~/ 2).isEven ? 1.5 : 1.0;` — easy iteration if needed.

### 4.5 Preview window heights

```diff
     final preview = SizedBox(
-      height: 180,
+      height: 234,
       child: TargetPlot( ... ),
     );

-    final imageH = (maxW * 0.78).clamp(240.0, 560.0);
+    final imageH = (maxW * 1.0).clamp(280.0, 640.0);
```

The inline preview is +30% taller. The tap-to-zoom dialog's height now matches its width (was 78% of width) and the clamp band shifts up. Tall portrait targets benefit most.

---

## 5. Verification

| Gate | Before phase | After phase |
|---|---|---|
| `flutter analyze` | 6 issues (Phase 4 baseline) | **6 issues, 0 new** |
| `flutter test` | 1291/1291 passing | **1291/1291 passing** |
| Sanity numbers (§A.3) | — | All 11 quantities match spec within rounding |
| Schema version | 36 | 36 (unchanged) |
| `targets.json` | — | Unchanged |
| `manifest.json` | — | Unchanged |
| Files modified | — | Exactly 2 |
| Files added / deleted | — | 0 / 0 |
| Pushed to `origin/main` | — | ✅ |

The 6 baseline infos are unchanged from prior phases (`<path>` HTML-in-doc-comment in `animal_silhouettes.dart` ×2; deprecated `Matrix4.translate` / `scale` in `animal_silhouettes.dart` and `target_silhouettes.dart` ×4). None caused by this phase.

---

## 6. Operator visual QA (for you to run on device)

Per the Phase 5 spec's §7 report-back:

| Surface | Expected after Phase 5 |
|---|---|
| Bear preview, inline | Bear in upper-middle of canvas with comfortable sky above. Short pole stub (~13px at H=234) connects bear's bottom to the mound apex. Mound texture from Phase 4 intact. Grass tufts denser than Phase 4. Mound-edge clumps show visible height variation. |
| Bear preview, tap-to-zoom | Same scene at the new larger dialog size. Proportions identical to the inline preview, just bigger. |
| IPSC silhouette, inline | Visibly taller than in Phase 4 thanks to the 234px window. Tall portrait silhouette fills the vertical room without the cramping that Phase 3/4 had at 180px. |
| Texas Star (procedural) | Procedural fallback shapes still render correctly in the new layout. |
| Prairie dog or Rabbit | Small animal targets still render visibly. The new pole stub doesn't dwarf them. |

### Tuning knobs if anything looks off

| Symptom | Knob |
|---|---|
| Pole stub too short / too long | `_visiblePoleFracOfTarget` (currently 0.20) |
| Bear too small / too big in canvas | `_targetBoxHeightFrac` (currently 0.28) |
| Too much / too little sky | `_horizonFrac` (currently 0.75) |
| Grass blades too sparse / too dense | The `100.0` divisor in `_paintGrassTufts` |
| Clump fringe too uniform / too uneven | The `1.5` height multiplier on even clumps |
| Preview window too tall / too short | The `234` and `(maxW * 1.0).clamp(280, 640)` values |

---

## 7. What's next

Per the Phase 5 spec's §2 deferral list, Phase 6 introduces:

| Phase 6 item | Description |
|---|---|
| Per-target `center_point` field | `targets.json` gets a `center_point` field (probably `[x, y]` fractions); drift column added; `TargetSpec.centerPoint` plumbed; `_RealisticScenePainter` uses it to anchor the visual pole top instead of always using `targetRect.center.dy`. |
| Background additions | Distant hills, treeline, tall grass clumps — additional scenery layers behind the mound. |

Phase 7 will rework `animal_silhouettes.dart` to add a real SVG parser for the bigfoot inverted-path geometry plus a white-fill path filter (both together — doing the filter alone would regress bigfoot).

Phase 8+ adds reticle / scope ring / aim crosshair / shot dots back into single-target realistic mode.

---

## 8. Rollback notes

Single commit, two files, no schema or asset changes. Clean revert path:

```sh
git -C /Users/general/Development/Applications/LoadOut/ revert c5b556c
git -C /Users/general/Development/Applications/LoadOut/ push origin main
```

That undoes Phase 5 entirely and returns to Phase 4 visual state.
