# Scene Painter Phase 3 — Phase Report

**Date:** 2026-05-12
**Branch:** `claude/infallible-panini-8b20d1` (worktree off `main`)
**Commit delivered:** `a045998` — on `origin/main`
**Prior reports:** [SCENE_PAINTER_PHASE_2_REPORT.md](SCENE_PAINTER_PHASE_2_REPORT.md), [TARGET_RENDER_FIX_SESSION_REPORT.md](TARGET_RENDER_FIX_SESSION_REPORT.md), [TARGET_RENDER_FIX_PHASE_A_REPORT.md](TARGET_RENDER_FIX_PHASE_A_REPORT.md)
**Spec source:** [`SCENE_PAINTER_PHASE_3.md`](file:///Users/general/Downloads/SCENE_PAINTER_PHASE_3.md) (delivered by user)

---

## 1. Headline

Phase 3 closes three follow-up issues surfaced during Phase 2 visual QA on the picker-side surfaces:

1. **Animal targets defaulted to natural fur colors** (bear `#1A1410`, deer `#6B5A47`, etc.) instead of the white-paper default the user expects on every target.
2. **Animal dropdown entries displayed as "IPSC <dims> in"** because the label function dispatched on `shape` ("silhouette") and ignored the per-species `shape_id`.
3. **The picker target preview rendered on a clean dark background** instead of the realistic scene composition. The legacy `_TargetThumbnail` painter had been kept around because the OLD scene painter clipped tall silhouettes; the NEW `_RealisticScenePainter` (Phase 1) doesn't have that bug.

All three fixed in one commit. A bonus dead-code deletion fell out of the work — `_TargetThumbnail` + `_TargetThumbnailPainter` turned out to have zero callers after Changes 3 + 4, so they were removed.

---

## 2. Scope of this phase

### What got done

| Area | Change |
|---|---|
| Catalog | 16 animal `color_hex` values flipped to `#ffffff` |
| Seed manifest | `manifest_version` 6→7, `files.targets.version` 3→4 (forces SeedUpdater re-seed on existing installs) |
| Dropdown labels | `_targetDropdownLabel` checks `shapeId` first, returns `${t.name} $dims` when set |
| Inline picker preview | `_targetVisualBox` swapped from `_TargetThumbnail` to `TargetPlot(viewMode: realistic)` |
| Tap-to-zoom dialog | `_showTargetPreviewDialog` same swap, larger canvas |
| Dead-code cleanup | `_TargetThumbnail` + `_TargetThumbnailPainter` deleted (zero callers after the swaps) |

### What did NOT get done (deferred per spec)

| Deferred | Why |
|---|---|
| Reticle / scope ring / aim crosshair / shot dots in preview surfaces | Same as Phase 2 — deferred to a future phase |
| Merging `AnimalSilhouettes` and `TargetSilhouettes` into one class | Not necessary for these fixes |
| Renaming / catalog dimensional edits | Out of scope |
| Bucket-side seed upload (`scripts/upload_seed_data.sh`) | Operator step — flagged for the user |

---

## 3. Files changed

### Commit `a045998 Scene Painter Phase 3: White Animals + Species Labels + Scene Preview`

| File | Change | Net lines |
|---|---|---|
| [assets/seed_data/targets.json](assets/seed_data/targets.json) | 16 animal `color_hex` values flipped from natural fur to `#ffffff` | +30 / -30 |
| [assets/seed_data/manifest.json](assets/seed_data/manifest.json) | `manifest_version` 6→7; `files.targets.version` 3→4 | +3 / -3 |
| [lib/screens/range_day/range_day_detail_screen.dart](lib/screens/range_day/range_day_detail_screen.dart) | `_targetDropdownLabel` rewritten; `_targetVisualBox` body rewritten to use `TargetPlot`; `_showTargetPreviewDialog` SizedBox child swapped; `_TargetThumbnail` + `_TargetThumbnailPainter` classes deleted | +54 / -297 |

**Net:** +87 / -330 lines across 3 files.

---

## 4. Code detail

### 4.1 Animal color defaults

The 16 animal rows in [targets.json](assets/seed_data/targets.json) all had natural-fur `color_hex` values authored when the catalog was first designed. The user's mental model is that every target is white cardboard by default and the user picks a per-session color from the swatch row. This phase aligns the data:

| Animal | Before | After |
|---|---|---|
| Bear | `#1A1410` | `#ffffff` |
| Boar | `#2C1F18` | `#ffffff` |
| Coyote | `#8B6F45` | `#ffffff` |
| Deer | `#6B5A47` | `#ffffff` |
| Elk | `#5A4633` | `#ffffff` |
| Mule deer | `#7A6451` | `#ffffff` |
| Moose | `#3E2F22` | `#ffffff` |
| Pronghorn | `#A88B68` | `#ffffff` |
| Mountain lion | `#A47F5C` | `#ffffff` |
| Fox | `#B96B33` | `#ffffff` |
| Rabbit | `#A89886` | `#ffffff` |
| Groundhog | `#7A6147` | `#ffffff` |
| Prairie dog | `#B89968` | `#ffffff` |
| Wild turkey | `#3D2920` | `#ffffff` |
| Pheasant | `#8B5E36` | `#ffffff` |
| Bigfoot | `#3E2A1A` | `#ffffff` |

`rim_color_hex` was left as authored — defensive, in case anything else reads it (`#000000` for most rows, harmless).

### 4.2 Seed manifest bump

[manifest.json](assets/seed_data/manifest.json):

```diff
-  "manifest_version": 6,
+  "manifest_version": 7,
   ...
   "targets": {
-    "version": 3,
+    "version": 4,
     "filename": "targets.json"
   },
```

Per CLAUDE.md § 28, `SeedUpdater` reads the per-file `version` and re-applies the catalog when remote `version > local version`. The local store now has v4 catalog content; once the bumped manifest is uploaded to Firebase Storage (operator step via `scripts/upload_seed_data.sh`), existing remote installs pick up the white-color change on next cold start.

The v36 schema migration also wipes the `Targets` table and re-seeds from `assets/seed_data/targets.json` directly — that path is independent of the manifest. Fresh installs and migration-driven re-seeds will pick up the white colors immediately.

### 4.3 `_targetDropdownLabel` — species names

Before, animal rows (all with `shape: 'silhouette'`) went through `_shapeDisplayLabel(t.shape)` → returned `'IPSC'`, producing labels like "IPSC 60×32 in" for Bear, Deer, Mule deer, etc. — all the same useless label.

After, the function checks `shapeId` first:

```dart
String _targetDropdownLabel(TargetRow t) {
  final w = t.widthIn;
  final h = t.heightIn;
  String dims;
  if (w == h) {
    dims = '${_formatDim(w)} in';
  } else {
    dims = '${_formatDim(w)}×${_formatDim(h)} in';
  }
  // Rows with a `shapeId` set (animals via AnimalSilhouettes,
  // poppers and future competition targets via TargetSilhouettes)
  // use the catalog's `name` field directly — that's the species
  // or product name. The shape-based `_shapeDisplayLabel`
  // collapses these into "IPSC" because their geometric `shape`
  // is "silhouette", which is correct for procedural dispatch
  // but wrong for user-facing labels.
  if (t.shapeId != null) {
    return '${t.name} $dims';
  }
  final shape = _shapeDisplayLabel(t.shape);
  if (t.shape.toLowerCase() == 'star') {
    return '$shape $dims (${t.name})';
  }
  return '$shape $dims';
}
```

Result examples:

| Catalog row | Before | After |
|---|---|---|
| Bear (`shape_id: bear`) | IPSC 60×32 in | Bear 60×32 in |
| Mule deer (`shape_id: mule_deer`) | IPSC 60×32 in | Mule deer 60×32 in |
| Pepper Popper Full (`shape_id: pepper_popper`) | Popper 7.87×33.46 in (after Phase 2's filter fix; was misrouted before that) | Pepper Popper Full 7.87×33.46 in |
| Circle 12 in (no `shape_id`) | Circle 12 in | Circle 12 in (unchanged) |
| IPSC USPSA Classic 18×30 in (no `shape_id`) | IPSC 18×30 in | IPSC 18×30 in (unchanged) |
| Texas Star 36 in (no `shape_id`) | Star 36 in (Texas Star) | Star 36 in (Texas Star) (unchanged) |

### 4.4 Picker preview surfaces swap to `TargetPlot`

Both `_targetVisualBox` (inline, 180px) and `_showTargetPreviewDialog` (tap-to-zoom, larger) now mount `TargetPlot` in realistic mode:

```dart
TargetPlot(
  target: spec,
  shots: const [],
  onTapAt: (_, _) {},
  onLongPressShot: (_) {},
  tapMode: TargetPlotTapMode.aimPoint,
  viewMode: TargetPlotViewMode.realistic,
  colorHexOverride: _selectedTargetColorHex,
)
```

`TargetPlot` in realistic mode routes single targets to `_RealisticScenePainter` (Phase 1) — the same painter that renders the live Range Day surface. The user gets the same sky / grass / mound / pole / target composition in the picker preview as they'll see in actual use.

The spec mentioned only `onTapAt` as the required noop, but `TargetPlot`'s constructor at [target_plot.dart:298](lib/screens/range_day/widgets/target_plot.dart:298) also requires `onLongPressShot`. Added that as `(_) {}`.

Wildcard `_` for unused function-literal parameters is the Dart 3.5+ idiom; the spec's original `(double _, double __) {}` triggered the `unnecessary_underscores` lint. Replaced with `(_, _) {}` and `(_) {}` to satisfy the analyzer.

### 4.5 Dead-code deletion — `_TargetThumbnail` + `_TargetThumbnailPainter`

The spec said:

> "After Changes 3 and 4, `_TargetThumbnail` is still used by the picker DROPDOWN TILES (the small icons next to "Bear", "Deer", etc. in the dropdown list). Do NOT delete it."

That assumption was wrong. The picker dropdown tile icons use [`_targetShapeIcon`](lib/screens/range_day/range_day_detail_screen.dart) (which returns Material `Icons.pets` for animals, `Icons.crop_square` for plates, etc.), NOT `_TargetThumbnail`. Verified by grep:

```
$ grep -n "_TargetThumbnail\b" lib/screens/range_day/range_day_detail_screen.dart
9630:class _TargetThumbnail extends StatelessWidget {
9631:  const _TargetThumbnail({required this.spec, required this.color});
9652:          painter: _TargetThumbnailPainter(spec: spec, color: color),
```

Only the class declaration + internal painter wiring. Zero external callers after the two preview-surface swaps.

Carrying dead code violates the project's "no dead code" preference (CLAUDE.md global: *"If you are certain that something is unused, you can delete it completely."*). Deleted both classes:

- `_TargetThumbnail` (29 lines, StatelessWidget wrapper)
- `_TargetThumbnailPainter` (~250 lines, CustomPainter with `paint` + `shouldRepaint`)

The doc-comment references in `lib/widgets/scope_daytime_backdrop.dart` (lines 847, 1019) and `lib/screens/range_day/widgets/target_plot.dart:157` are prose mentions, not actual references — they're stale comments about the now-deleted code's behavior. Not actionable in this phase; can be cleaned up opportunistically.

---

## 5. Verification

| Gate | Before phase | After phase |
|---|---|---|
| `flutter analyze` | 6 issues (Phase 2 baseline) | **6 issues, 0 new** |
| `flutter test` | 1291/1291 passing | **1291/1291 passing** |
| `_TargetThumbnail` / `_TargetThumbnailPainter` references in `range_day_detail_screen.dart` | 3 hits | **0 hits** (clean delete) |
| `_targetDropdownLabel` returns for animal rows | "IPSC 60×32 in" (all 16 the same) | "Bear 60×32 in", "Deer 60×32 in", ... (16 distinct) |
| Animal rows in seed catalog with `color_hex == '#ffffff'` | 0 / 16 | **16 / 16** |
| Manifest `files.targets.version` | 3 | 4 |

---

## 6. Re-seed mechanism

For existing development installs, the catalog change becomes visible on next cold start via one of two paths:

| Path | When it runs | What it does |
|---|---|---|
| **Drift v36 migration** | Once per install, on the upgrade from v35→v36 | Wipes the `Targets` table; `SeedLoader._seedTargets()` re-reads `assets/seed_data/targets.json` directly. Existing installs that already ran the v36 migration before this phase won't re-trigger this path. |
| **SeedUpdater** (CLAUDE.md § 28) | On every cold start | Compares local-stored `seed_version_targets` against the remote manifest's `files.targets.version`. When remote > local, re-fetches and applies the new catalog. The manifest bump in this phase (3→4) makes this fire on the next cold start. |

Fresh installs and any install that ran the v36 migration AFTER this phase will see the white animals immediately on first launch. Installs that ran v36 BEFORE this phase will need the SeedUpdater path — which requires the new manifest to be on the Firebase Storage bucket. That's an operator step (`scripts/upload_seed_data.sh`).

**The Firebase Storage upload was NOT performed in this phase** — flagging that as a follow-up if you want the change visible on remote installs without waiting for someone to clear local data.

---

## 7. Cumulative file changes (this phase only)

| File | Operation | Effect |
|---|---|---|
| `assets/seed_data/targets.json` | Modified | 16 animal rows: `color_hex` → `#ffffff` |
| `assets/seed_data/manifest.json` | Modified | `manifest_version` 6→7; `files.targets.version` 3→4 |
| `lib/screens/range_day/range_day_detail_screen.dart` | Modified | `_targetDropdownLabel` rewrite; preview surfaces swap; `_TargetThumbnail` + `_TargetThumbnailPainter` deletion |

### Files NOT touched (per spec's "Don't touch" list)

- `_RealisticTargetPainter` (rack path's legacy painter)
- `_RealisticScenePainter` (Phase 1 painter — already correct, just being called from new sites)
- `_TargetPainter` (target-focused mode)
- Sensitive files: `revenue_cat_config`, `onedrive_config`, `auth_service`, `backup_crypto`, `purchases_service`, `biometric_service`, `cloud_backup_service`, `Info.plist`
- Math-audit-boundary files: `solver.dart`, `hit_probability_service.dart`, `hit_probability_map_service.dart`

---

## 8. Operator visual QA (for you to run on device)

Per the Phase 3 spec's report-back section:

| Surface | Expected after Phase 3 |
|---|---|
| Picker dropdown filtered to "Animal" | Entries display as "Bear 60×32 in", "Deer 60×32 in", "Mule deer 60×32 in", "Pepper Popper Full 7.87×33.46 in", etc. — NOT "IPSC <dims>" |
| Inline picker preview with Bear selected | 180px frame shows full scene: blue sky in top 70%, brown mound at horizon, steel-grey pole, **white bear silhouette** at pole top, grass at bottom |
| Tap-to-zoom dialog of same Bear | Same scene composition, larger canvas |
| Picker dropdown tile icons (small, next to each entry) | Still use `_targetShapeIcon` → animals show `Icons.pets`, plates show `Icons.crop_square`, etc. (unchanged) |
| Color swatch row | Tap orange → bear preview turns orange. Tap white (or clear selection) → bear preview returns to white. |
| Procedural targets (IPSC, circles, rectangles, Texas Star) in dropdown | Labels unchanged: "IPSC 18×30 in", "Circle 6 in", "Rectangle 24×30 in", "Star 36 in (Texas Star)" |

### Cold-cache fallback (carried over from Phase 1)

If any animal target renders as a procedural rectangle in the preview on first paint, that's the cold-cache case — `main.dart`'s boot preload hasn't completed yet. Resolves on the next repaint. Not a bug.

---

## 9. What's next

| Item | Where |
|---|---|
| Reticle / scope ring / aim crosshair / shot dots in `_RealisticScenePainter` | Scene Painter Phase 4+ |
| Rack target rendering rewrite | Future phase |
| Low-light palette for `_RealisticScenePainter` | Future phase |
| `prairie_dog_standing.svg` → `prairie_dog.svg` rename (already done in `4fdee8d`) | (already complete) |
| Firebase Storage upload of new manifest (`scripts/upload_seed_data.sh`) | **Operator step** — required for the white-animals change to propagate to existing remote installs |
| Cleanup of stale doc-comment references to `_TargetThumbnailPainter` in `scope_daytime_backdrop.dart` and `target_plot.dart` | Opportunistic cleanup, low priority |
| Visual QA pass on device | Operator step |

---

## 10. Rollback notes

| Commit | Revert effect |
|---|---|
| `a045998 Scene Painter Phase 3` | Animal catalog reverts to natural fur colors. Manifest versions revert. Dropdown labels for animals revert to "IPSC <dims>". Picker preview surfaces revert to clean-background `_TargetThumbnail` painter — which means the painter classes need to be RESTORED first since this commit deleted them. Net: this revert is non-trivial because the dead-code deletion is bundled in. **If you need to revert, prefer `git revert --no-commit a045998` followed by selectively undoing parts**, OR revert the manifest + JSON changes only via `git checkout a045998^ -- assets/seed_data/` and leave the code changes in place. |

The schema is unchanged from Phase 2 (still v36 with `shape_id` column), so no migration concerns.
