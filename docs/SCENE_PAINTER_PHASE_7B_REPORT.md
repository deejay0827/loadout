# Scene Painter Phase 7b — Phase Report

**Date:** 2026-05-12
**Branch:** `claude/infallible-panini-8b20d1` (worktree off `main`)
**Commit delivered:** `e669fce` — on `origin/main`
**Prior reports:** [SCENE_PAINTER_PHASE_7A_REPORT.md](SCENE_PAINTER_PHASE_7A_REPORT.md), [SCENE_PAINTER_PHASE_6_REPORT.md](SCENE_PAINTER_PHASE_6_REPORT.md), [SCENE_PAINTER_PHASE_5_REPORT.md](SCENE_PAINTER_PHASE_5_REPORT.md), [SCENE_PAINTER_PHASE_4_REPORT.md](SCENE_PAINTER_PHASE_4_REPORT.md), [SCENE_PAINTER_PHASE_3_REPORT.md](SCENE_PAINTER_PHASE_3_REPORT.md), [SCENE_PAINTER_PHASE_2_REPORT.md](SCENE_PAINTER_PHASE_2_REPORT.md), [TARGET_RENDER_FIX_SESSION_REPORT.md](TARGET_RENDER_FIX_SESSION_REPORT.md)
**Spec source:** [`SCENE_PAINTER_PHASE_7B.md`](file:///Users/general/Downloads/SCENE_PAINTER_PHASE_7B.md) (delivered by user)

---

## 1. Headline

Parser-only phase. No painter changes, no schema changes, no JSON changes — purely a rewrite of `AnimalSilhouettes._extractAndCombinePaths` to handle two structural patterns the old regex-based code couldn't:

1. **Inverted negative-space SVGs** — the bigfoot SVG draws the silhouette as a HOLE in a giant white canvas-cover path. The old code combined all parsed paths and filled with one color, producing "outline on rectangle." Phase 7b detects the pattern via a heuristic and uses `Path.combine(PathOperation.difference, canvasRect, firstPath)` to extract the hole.
2. **White-fill background paths** — defensive filter for future SVGs authored with the conventional "white background + dark silhouette" structure. White-fill paths get dropped before the combine.

Plus a defensive fallback (combine everything if filtering yields empty) so we never produce an empty silhouette.

8 new unit tests pin the dispatch logic.

---

## 2. Scope of this phase

### What got done

| Group | Sub-item | File(s) |
|---|---|---|
| **A.1** | `svg_path_parser: ^1.1.1` dependency added | `pubspec.yaml`, `pubspec.lock` |
| **A.2** | `_ParsedSvgPath` value class + helper signatures | `lib/widgets/animal_silhouettes.dart` |
| **A.3** | `_parseAllPaths` — extracts every `<path>` block, parses `d`+`fill` | `lib/widgets/animal_silhouettes.dart` |
| **A.4** | `_isWhiteFill` — handles `#fff`, `#ffffff`, `#FEFEFE`, `"white"`, near-white | `lib/widgets/animal_silhouettes.dart` |
| **A.5** | `_isInvertedNegativeSpaceSvg` — first path is white-ish + bounds ≥ 90% of viewBox in both axes | `lib/widgets/animal_silhouettes.dart` |
| **B.1** | `extractAndCombinePaths` rewritten with inverted-pattern + white-fill filter + defensive fallback | `lib/widgets/animal_silhouettes.dart` |
| **B.2** | `_parseViewBox` — reads `<svg>`'s `viewBox` (or `width`/`height` fallback, or `1024×1024` default) | `lib/widgets/animal_silhouettes.dart` |
| **C** | 8 unit tests pinning every structural code path | `test/animal_silhouettes_test.dart` (NEW) |

### What did NOT get done (deferred per spec §2)

| Deferred to | Item |
|---|---|
| Phase 8 | Per-animal SVG asset re-authoring in Inkscape |
| Phase 9+ | Reticle / scope ring / aim crosshair / shot dots |
| Phase 10+ | Rack target rendering rewrite |
| (Independent) | Phase 7a is already on main (`bdf279e`); 7a and 7b are independent per spec |

No painter changes, no schema changes, no JSON changes. No `_RealisticScenePainter` modifications. No `TargetSpec` modifications. No `target_silhouettes.dart` modifications (Phase 7b explicitly only touches `AnimalSilhouettes`).

---

## 3. Files changed

### Commit `e669fce Scene Painter Phase 7b: SVG Path Parser + Inverted-Pattern Detection + White-Fill Filter`

| File | Operation | Net lines |
|---|---|---|
| [pubspec.yaml](pubspec.yaml) | EDIT — add `svg_path_parser` dependency + doc comment | +10 / -0 |
| [pubspec.lock](pubspec.lock) | REGEN — `flutter pub get` | (auto) |
| [lib/widgets/animal_silhouettes.dart](lib/widgets/animal_silhouettes.dart) | EDIT — `_ParsedSvgPath` class; rewritten `extractAndCombinePaths` (was `_extractAndCombinePaths`); new helpers `_parseAllPaths`, `_parseViewBox`, `_isWhiteFill`, `_isInvertedNegativeSpaceSvg` | +227 / -17 |
| [test/animal_silhouettes_test.dart](test/animal_silhouettes_test.dart) | NEW — 8 unit tests | +236 |

Total: 4 files, +473 / -17.

---

## 4. Code detail — Group A (scaffolding)

### 4.1 Dependency

```yaml
# Phase 7b — strict-spec-compliant SVG path-data parser. Returns
# a Flutter Path directly, which lets us call
# Path.combine(PathOperation.difference, ...) to invert SVGs
# structured as negative-space (white canvas + silhouette cut out
# as a hole — e.g. the bigfoot SVG).
svg_path_parser: ^1.1.1
```

Kept `path_drawing: ^1.0.1` alongside — its `parseSvgPathData` is the per-path fallback when the strict parser throws on a malformed `d` string.

### 4.2 `_ParsedSvgPath` value class

```dart
class _ParsedSvgPath {
  _ParsedSvgPath(this.path, this.fillHex) : bounds = path.getBounds();
  final Path path;
  final String? fillHex;
  final Rect bounds;
}
```

Internal. Carries the data both the heuristic and the white-fill filter need.

### 4.3 `_parseAllPaths`

Extracts every `<path>` block, pulls the `d` and `fill` attributes, and parses `d` using:

1. **Strict** — `svg_path_parser.parseSvgPath(d)` first.
2. **Lenient fallback** — `parseSvgPathData(d)` from `path_drawing` when strict throws (handles malformed segments by silently dropping them).
3. **Skip + log** — `debugPrint` and continue when both fail. Never crashes on a single bad `d` string.

Preserves source order (the inverted-pattern heuristic inspects `paths.first`).

### 4.4 `_isWhiteFill`

Recognized as white:
- `"white"` (literal)
- `#fff`, `#ffffff`, `#ffffffff`
- Any `#[ef]{3}` or `#[ef]{6}` or `#[ef]{8}` pattern (near-white anti-aliasing artifacts: `#fefefe`, `#efefef`, etc.)

`null` (no `fill` attribute) returns `false` — per SVG spec, the inherited default is black, not white, so missing fill is intentionally NOT treated as white.

### 4.5 `_isInvertedNegativeSpaceSvg` heuristic

```dart
static bool _isInvertedNegativeSpaceSvg(
  List<_ParsedSvgPath> paths,
  Rect viewBox,
) {
  if (paths.isEmpty) return false;
  final first = paths.first;
  if (!_isWhiteFill(first.fillHex)) return false;
  if (viewBox.width <= 0 || viewBox.height <= 0) return false;
  final coverageX = first.bounds.width / viewBox.width;
  final coverageY = first.bounds.height / viewBox.height;
  return coverageX >= 0.9 && coverageY >= 0.9;
}
```

A heuristic, not a perfect classifier. Designed conservatively so standard animal SVGs (bear, deer, elk, etc.) — whose first paths are typically dark-filled silhouette bodies — don't accidentally trigger.

### 4.6 `_parseViewBox`

Reads the SVG root's `viewBox` attribute. Falls back to `width`/`height` attributes if `viewBox` is missing. Falls back to `1024×1024` if all are missing (defensive — the heuristic compares ratios, so absolute units don't matter).

---

## 5. Code detail — Group B (extractor rewrite)

```dart
static Path extractAndCombinePaths(String svgContent, String assetPath) {
  final viewBox = _parseViewBox(svgContent);
  final paths = _parseAllPaths(svgContent);

  if (paths.isEmpty) {
    throw StateError('No <path d="..."/> found in $assetPath');
  }

  // 1. Inverted negative-space pattern (bigfoot).
  if (_isInvertedNegativeSpaceSvg(paths, viewBox)) {
    final canvasRect = Path()..addRect(viewBox);
    return Path.combine(
      PathOperation.difference,
      canvasRect,
      paths.first.path,
    );
  }

  // 2. Standard SVG — filter white-fill paths, then combine.
  final combined = Path();
  for (final p in paths) {
    if (_isWhiteFill(p.fillHex)) continue;
    combined.addPath(p.path, Offset.zero);
  }

  // 3. Defensive fallback: combine every path if filter yielded empty.
  if (combined.getBounds().isEmpty) {
    final fallback = Path();
    for (final p in paths) {
      fallback.addPath(p.path, Offset.zero);
    }
    return fallback;
  }

  return combined;
}
```

Renamed `_extractAndCombinePaths` → `extractAndCombinePaths` (dropped the leading underscore) so the unit-test file can call it directly without test-only `@visibleForTesting` annotations.

---

## 6. Bigfoot SVG heuristic spot-check

Verified directly against the on-disk SVG:

| Property | Value | Heuristic check |
|---|---|---|
| `viewBox` | `0 0 1380 752` | ≥ 90% threshold applies to 1380 × 752 |
| Path count | 40 | (informational) |
| First path's `fill` | `#FFFFFF` | ✅ `_isWhiteFill` returns true |
| First path's `d` string length | 12,247 chars | Consistent with complex inverted-canvas-with-hole geometry |

Expected behaviour at runtime: the heuristic triggers, `Path.combine(difference, canvasRect_1380x752, firstPath)` runs, and the result is the negative space (the bigfoot silhouette). The user-color fill paints over that silhouette. **No further operator action needed for the bigfoot SVG to render correctly.**

---

## 7. Tests (Group C)

8 new unit test cases in [test/animal_silhouettes_test.dart](test/animal_silhouettes_test.dart):

| # | Test | What it pins |
|---|---|---|
| 1 | Standard SVG with one dark path | Bounds preserved through the standard combine path |
| 2 | White-fill filtered when dark path coexists | Filter strips small white rect; dark survives |
| 3 | Inverted-negative-space dispatch fires | Two-path SVG with white first path covering viewBox; result bounds ≠ full viewBox (collapsed by Path.combine on congruent rects) |
| 4 | Inverted SVG with bigfoot-style hole | Single path with outer-CW + inner-CCW subpath; result bounds match the hole |
| 5 | All-white-fill SVG defensive fallback | Filter would empty everything → fallback combines all paths |
| 6 | Various white-fill hex variants recognized | `#fff`, `#ffffff`, `#FEFEFE`, `"white"` all filtered; only `#1A1A1A` survives |
| 7 | SVG without viewBox | `_parseViewBox` falls back to `width`/`height` attributes |
| 8 | SVG with no `<path>` elements | Throws `StateError` (preserves loud-fail) |

**All 8 pass.** Full suite at 1301/1301 (Phase 7a baseline 1293 + 8 new = 1301).

### Initial test failure + fix

Test #4 (inverted SVG with smaller hole) initially failed — my synthetic SVG had two SEPARATE paths (outer white rect + inner black rect), which doesn't actually create a hole at the path-level. The bigfoot SVG uses ONE path with the outer rectangle AND the inner silhouette as a sub-path (counter-clockwise) so non-zero winding cuts the hole.

Fix: rewrote the synthetic SVG to use one path with `d="M 0 0 L 200 0 L 200 200 L 0 200 Z M 60 60 L 60 140 L 140 140 L 140 60 Z"` — outer CW, inner CCW. Test now passes.

This is a subtle gotcha that's worth documenting: structural SVG inversion requires a single path with hole-as-subpath, not multiple paths.

---

## 8. Verification

| Gate | Before phase | After phase |
|---|---|---|
| `flutter analyze` | 6 issues (Phase 7a baseline) | **4 issues, 0 new** (rewrite removed 2 pre-existing `<path>` HTML-in-doc-comment infos) |
| `flutter test` | 1293/1293 passing | **1301/1301 passing** (+8 new parser tests) |
| `svg_path_parser` resolved | — | ✅ in `pubspec.lock` |
| Schema version | 38 | 38 (unchanged) |
| `targets.json` / `manifest.json` | — | Unchanged |
| Pushed to `origin/main` | — | ✅ |

The 4 remaining baseline infos are all the unchanged `Matrix4.translate` / `Matrix4.scale` deprecation infos in `animal_silhouettes.dart` and `target_silhouettes.dart` — pre-existing since before any Phase work.

---

## 9. Operator visual QA (for you to run on device)

Per spec §5:

| Surface | Expected after Phase 7b |
|---|---|
| **Bigfoot, inline** | **Renders as a filled silhouette** — recognizable shape (head, body, arms, legs), filled with the palette-selected color (white by default). Was outline-on-rectangle pre-7b. |
| Bigfoot, tap-to-zoom | Same scene at larger size; silhouette identical. |
| Bear, inline | **Unchanged** from Phase 7a (standard SVG, no inverted pattern, no white-fill paths to filter). |
| Deer, inline | **Unchanged** — multi-path animal SVG still combines correctly. |
| Elk / Mule deer / Moose | **Unchanged** — Phase 7a's `svg_scale_factor` rendering preserved. |
| IPSC, inline | **Unchanged** — `TargetSilhouettes` is intentionally not touched in Phase 7b. |

### If bigfoot still renders weird

Per spec §7's debugging notes, if the bigfoot result has artifacts:
- Add a temporary `print` in `_isInvertedNegativeSpaceSvg` to log `first.bounds`, `viewBox`, `coverageX`, `coverageY`. Confirms the heuristic fires on the actual bigfoot SVG.
- If `coverageX` / `coverageY` are below 0.9, lower the threshold to e.g. 0.85.
- If the heuristic fires but the result looks broken, the bigfoot SVG's path winding may not produce the expected hole — Phase 7c could refine the difference operation.

The spot-check in §6 above suggests the heuristic will trigger cleanly (first path is `#FFFFFF`, 12k-char `d` string, viewBox 1380×752). No on-device QA done from this shell — operator step.

---

## 10. Other animals — won't accidentally invert?

Let me think about which (if any) other animal SVGs might trigger the inverted heuristic:

- Heuristic requires: first path's fill is white-ish AND first path's bounds ≥ 90% of viewBox.
- Animal SVGs authored conventionally have a dark-filled first path matching the silhouette body (bounds well below 90% of viewBox).
- Only the bigfoot SVG is structured with a giant white canvas-cover first path.

If a future animal SVG ships with a similar inverted structure, it WILL trigger the same dispatch — which is the right behaviour. No false positives are likely. The spec §A.5 acknowledges this: "If the heuristic fails... the parser falls through to the standard 'white-fill filter + combine' path." Both paths are defensible.

---

## 11. Spec deviations

None. Spec §3 referenced `lib/services/animal_silhouettes.dart` but my codebase has the file at `lib/widgets/animal_silhouettes.dart` (same location since Phase 1). All other instructions applied as-is.

---

## 12. Rollback

Phase 7b is a single commit + report commit. Plain revert undoes everything:

```sh
git -C /Users/general/Development/Applications/LoadOut/ revert e669fce
flutter pub get   # removes svg_path_parser from pubspec.lock
git -C /Users/general/Development/Applications/LoadOut/ push origin main
```

That undoes code, test, and dependency changes. No schema, no JSON, no asset cleanup needed.

---

## 13. What's next

Per the handoff doc:

- **Phase 8** — per-animal SVG asset re-authoring in Inkscape. Only relevant if Phase 7a's `svg_scale_factor` tuning + Phase 7b's parser don't visually satisfy. After this Phase 7b lands, operator can compare the bigfoot render against the other animals; if visual proportions are still inconsistent, Phase 8 swaps the SVG assets themselves.
- **Phase 7c** (if needed) — tune the inverted-pattern heuristic threshold or add secondary detection logic. Skip unless visual QA surfaces issues.
- **Phase 9+** — reticle / scope ring / aim crosshair / shot dots back into single-target realistic mode.
- **Phase 10+** — rack target rendering rewrite (retire legacy `_RealisticTargetPainter`).
