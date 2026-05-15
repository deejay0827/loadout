# Scene Painter Phase 9.8 — Final Report

Date: 2026-05-15
Branch: `claude/infallible-panini-8b20d1` → merged to `main`
Commits on `main` (chronological): `9ab6c10` (A) → `0b0c486` (A.1) →
`9bd2e05` (A.2) → `5d32932` (B) → `72179d1` (B.2 hotfix) →
`43ce043` (B.3) → `a0df32c` (C)

## TL;DR

Three operator feature requests from Phase 9.7 Group C.2 QA, plus
one self-heal hotfix caught by cold-restart. All landed on `main`.
Plus two ops actions (Firebase Storage updates for JSON catalogs +
SVG archive).

| Status | Item | Commit |
|---|---|---|
| ✅ | 9.8.A — Color picker for rack targets | `9ab6c10` |
| ✅ | 9.8.A.1 — Rack swatch shows unconditionally | `0b0c486` |
| ✅ | 9.8.A.2 — Color picker moved to parent (shared placement) | `9bd2e05` |
| ✅ | 9.8.B — Tap target to activate (per-slot hit testing) | `5d32932` |
| ✅ | 9.8.B.2 hotfix — Stale docs-mirror self-heal | `72179d1` |
| ✅ | 9.8.B.3 — Picker preview: single tap activates, double tap enlarges | `43ce043` |
| ✅ | 9.8.C — Multi-size Equal Rack catalog (9 → 13 racks) | `a0df32c` |
| ✅ | Firebase Storage upload — JSON catalogs (v10 targets, v5 racks, v16 manifest) | ops |
| ✅ | Firebase Storage upload — SVG silhouettes archive (18 files) | ops |

flutter analyze: **0 errors, 6 baseline infos** (Vector matrix
deprecations in animal_silhouettes / target_silhouettes, pre-existing).
flutter test: **1344 passing** (one schema-invariant test updated
for 9.8.C's 9→13 rack count change).

## Group 9.8.A — Color picker for rack targets

**Three commits.** Operator surfaced the request at the end of Phase
9.7 Group C.2 QA: "There should be a color picker for the targets
similar to how the singular target has a picker."

**9.8.A (`9ab6c10`)** — initial implementation:
- Mirrored `_targetColorSwatchRow()` into `_rackTargetPickerBody`,
  conditionally inside the `selectedRack != null && rackStillInCatalog`
  block. Reused `_selectedTargetColorHex` state so the picker pick
  persists across Single/Rack toggle.
- `_paintRack` slot loop now consults `colorHexOverride` first,
  falling back to `slot.colorHex`. Applies uniformly across every
  slot (per-rack override; per-slot was out of scope for v1).

**9.8.A.1 (`0b0c486`)** — operator visual QA showed swatch row was
hidden when no rack was selected. Hoisted the swatch call OUT of
the `selectedRack != null` conditional so it renders any time the
user is in rack-picker mode.

**9.8.A.2 (`9bd2e05`)** — operator request: "Let's move the color
picker for the rack and single to directly under the Single - Rack
radio button." Hoisted `_targetColorSwatchRow()` from inside each
picker body to the PARENT `_targetPicker` level (between the
Single/Rack `SegmentedButton` and the branching picker body).
Single source of truth — the swatch row now lives in ONE place,
renders identically for both modes, and stays in the same on-screen
position when the user toggles modes.

## Group 9.8.B — Tap target to activate

**Three commits.** Operator request: "The current/active target
should allow the user to tap the target and it become the active
target. Not just when the target buttons are selected."

**9.8.B (`5d32932`)** — initial implementation:
- Extracted per-slot rect math from the private painter helper to a
  top-level `computeRackSlotRects(Size, RackSpec, ...)` helper.
  Both `_paintRack` AND `TargetPlot.build`'s gesture handler now
  call the SAME function so the visible slot positions and the
  hit-test rects cannot diverge.
- New optional `onActiveRackSlotChange: void Function(int)?`
  callback prop on `TargetPlot`. `GestureDetector.onTapDown` checks
  (in rack mode, when the callback is wired) whether the tap landed
  inside any non-active slot rect; if yes, fires the callback with
  the slot's index and bypasses the regular `_handleTap`. Active-
  slot taps fall through to `_handleTap` as before (shot-recording
  + aim-point setting on the active plate unchanged).
- New `_setActiveRackSlot(int)` helper in the Range Day screen
  consolidates the chip-row + tap-to-activate side effects (setState
  + scheduleSolve + scheduleHitProb + scheduleAutoSave). Wired to
  the three Range Day workspace `TargetPlot` call sites
  (workspace body, not the picker preview).
- Picker preview surfaces (`_targetVisualBox` + `_showTargetPreviewDialog`)
  skipped in 9.8.B because of `IgnorePointer` wrappers.

**9.8.B.2 hotfix (`72179d1`)** — operator hit a cold-restart crash:
`Bad state: targets.json row 'Circle 1 in': invalid category 'target'
(must be one of {circle, square, rectangle, ipsc, animal, special})`.
The row name `'Circle 1 in'` and category value `'target'` are both
pre-Phase-9.5 schema — the operator's docs-mirror
(`<app docs>/seed_data/targets.json`) was stale from before the
Phase 9.5 Group A schema migration. The running app expected v9.5
schema; the mirror disagreed.

**Initial fix attempt (rejected).** I proposed a "graceful fallback"
that translated the legacy `shape` field into a v9.5 `category`
value when validation failed. Operator pushed back: "Why are we
rolling back to anything legacy?" Correctly so — schema translation
is a band-aid that hides stale data behind silent migration. The
operator looks at pre-Phase-8 names like "Circle 1 in" instead of
the current "1 in Circle"; the staleness problem stays buried.

**Adopted fix.** Self-heal at the file-read boundary:
- `_readSeedString(filename, {bool forceBundled})` — new
  `forceBundled` parameter skips the docs-mirror preference,
  reading the bundled asset directly.
- `_invalidateStaleMirror(filename)` — best-effort deletes the
  docs-mirror copy.
- `seedIfNeeded`'s targets branch wraps the `_seedTargets()` call
  in try-catch. On any error: invalidate the mirror, wipe any
  partially-inserted rows, retry with `_seedTargets(forceBundled:
  true)`. The retry reads the bundled asset (which IS current
  schema). If THAT also throws, the bundled asset itself is
  malformed — that's a genuine engineering bug and propagates to
  the unhandled-error reporter (Crashlytics).
- The next cold start uses the freshly-uploaded mirror via
  `SeedUpdater` (assuming we pushed a current version to the
  bucket, which is exactly what the ops upload below did).

**9.8.B.3 (`43ce043`)** — operator refined the tap-to-activate
behaviour on the picker-preview surface: "right now, a single
click opens the picture to be a larger view modal. Make that
enlargement a double click and the activation a single click."

- Removed `IgnorePointer` wrapping `TargetPlot` in `_targetVisualBox`.
- Wired `onActiveRackSlotChange: _setActiveRackSlot` on this
  surface (was skipped in 9.8.B because of IgnorePointer).
- Replaced the outer `InkWell.onTap` (which routed single taps
  to the zoom dialog) with a `GestureDetector.onDoubleTap`. Same
  enlarge-dialog target, double-tap trigger.

Gesture arena: when the user single-taps, the inner `TargetPlot`'s
GestureDetector commits immediately on `onTapDown` (no double-tap
window delay because the inner detector doesn't declare
`onDoubleTap` itself). The outer `GestureDetector.onDoubleTap`
only commits when a second tap arrives within the platform
double-tap window (~300 ms).

## Group 9.8.C — Multi-size Equal Rack catalog

**One commit.** Operator request: "Each category (circle and
square), there should be multiple size target racks." Confirmed
9.8.C as proposed in the catalog expansion table I surfaced for
§ 0c approval.

Catalog grew from 9 racks → **13 racks**:

| Row id | Name | Plates | Mount | Default dist |
|---|---|---|---|---|
| `equal_rack_5_circles` | `5-Plate Equal Rack (6 in Circles)` *(renamed)* | `[6, 6, 6, 6, 6]` | hanging_rail | 100 yd |
| `equal_rack_5_circles_8in` *(NEW)* | `5-Plate Equal Rack (8 in Circles)` | `[8, 8, 8, 8, 8]` | hanging_rail | 150 yd |
| `equal_rack_5_circles_10in` *(NEW)* | `5-Plate Equal Rack (10 in Circles)` | `[10, 10, 10, 10, 10]` | hanging_rail | 200 yd |
| `equal_rack_5_squares` | `5-Plate Equal Rack (4 in Squares)` *(renamed)* | `[4, 4, 4, 4, 4]` | standing_stake | 75 yd |
| `equal_rack_5_squares_6in` *(NEW)* | `5-Plate Equal Rack (6 in Squares)` | `[6, 6, 6, 6, 6]` | standing_stake | 100 yd |
| `equal_rack_5_squares_8in` *(NEW)* | `5-Plate Equal Rack (8 in Squares)` | `[8, 8, 8, 8, 8]` | standing_stake | 125 yd |

Spacing scales proportionally with plate size to keep edge-to-edge
clearance sensible:
- 6" circles → 18 c-to-c; 8" → 24; 10" → 30
- 4" squares → 14 c-to-c; 6" → 21; 8" → 28

Slot naming pattern unchanged (Phase 9.6 D operator-confirmed):
`Plate N (X in dia)` for circles, `Plate N (X in sq)` for squares.
Slot offsets computed center-to-center per the Phase 9.6 spacing
convention.

Picker-side: the existing 7-chip filter (Phase 9.6 D) already
filters racks by slot category; the four new circle + square racks
appear under the Circle / Square chips automatically. No UI code
changed.

manifest_version 15 → 16; target_racks.version 4 → 5.

KYL, Decreasing, Pepper Popper, IPSC Stage, and IDPA Open Stage
all stay single-size (5-Plate KYL etc. are "stepping" racks where
varying plate size IS the point; size variants only make sense for
the Equal Rack family).

## Ops — Firebase Storage uploads

Two upload sessions across the phase:

### Session 1 — JSON catalogs + manifest after Phase 9.6 / 9.7

Before Phase 9.8.A landed, the operator asked for a Firebase Storage
update so the docs-mirror could re-download fresh data after the
9.8.B.2 self-heal cleared the stale local copy. Pushed:

| File | Bucket version | Why it's changing |
|---|---|---|
| `targets.json` | v10 | Phase 9.6 B animal renames + Phase 9.6 C Bear/Bigfoot SVG flips |
| `target_racks.json` | v4 | Phase 9.6 D 9-rack catalog rewrite |
| `manifest.json` | v15 | Bumped accordingly |

Both prior versions archived to `seed_data/archive/` per § 28
"never delete" rule. 20 other catalog files hash-skipped (no churn).

### Session 2 — SVG silhouettes archive

Operator request: "Also upload the SVG files." After clarification
that this is storage-only (no engineering integration — the app
loads SVGs from `rootBundle` not from the bucket), pushed:

```
gs://loadout-precision-reloading.firebasestorage.app/seed_data/silhouettes/
├── animals/  (16 files: bear, bigfoot, boar, coyote, deer, elk, fox,
│               groundhog, moose, mountain_lion, mule_deer, pheasant,
│               prairie_dog, pronghorn, rabbit, wild_turkey)
└── targets/  (2 files: ipsc, pepper_popper)
```

264.7 KiB total. Content-Type `image/svg+xml` set so Firebase
Console previews render correctly. No manifest entries — SVGs are
not consumed by `SeedUpdater`; storage-only.

### Session 3 — JSON catalogs + manifest after Phase 9.8.C

After 9.8.C landed:

| File | Bucket version |
|---|---|
| `target_racks.json` | v5 (13-rack catalog) |
| `manifest.json` | v16 |

Prior versions archived.

## What landed pre-9.8 but worth recalling

| Group | Detail |
|---|---|
| Phase 9.7 D | `_RealisticTargetPainter` deleted (828 lines). `_RealisticScenePainter` is the SINGLE realistic-mode painter, dispatching via `SceneInput` sealed type. |
| Phase 9.7 C / C.1 / C.2 | Unified rack-mode rendering (mount-structure rig, multi-slot loop, active-slot 2.0 px black outline). |
| Phase 9.7 B | `_RealisticScenePainter` constructor migrated to `sceneInput: SceneInput` parameter (single source of truth for the painter input). |
| Phase 9.7 A | `SceneInput` sealed types + contract test. |

## Engineering principles applied (Phase 9.8)

- **No band-aids.** The 9.8.B.2 stale-mirror fix landed cleanly on
  the second try: my "graceful fallback" was correctly rejected as
  a band-aid; the operator's pushback drove the design to a
  proper self-heal at the file-read boundary that invalidates the
  stale mirror and reseeds from the bundled asset.
- **Halt-and-validate when § 0c applies.** Group 9.8.C's catalog
  expansion required operator confirmation of the rack labels +
  size variants. I surfaced the before/after table BEFORE writing
  any JSON, waited for "Confirmed as proposed", then executed.
- **Surface scope decisions, don't bolt onto a group mid-flight.**
  When the operator's QA on 9.8.B's tap-to-activate surfaced the
  refinement "single = activate, double = enlarge", I shipped it
  as 9.8.B.3 as a separate commit rather than reopening 9.8.B.
- **One commit per logical change.** Six code commits + two ops
  uploads across the phase. Each commit's diff is reviewable as a
  unit; no kitchen-sink rewrites.

## Operator verification checklist (cold-restart)

After cold-restart on `a0df32c`:

1. **Stale-mirror self-heal** — first cold-restart should land
   cleanly (the prior `invalid category 'target'` crash is gone).
   First launch deletes the stale local mirror and reseeds from the
   bundled asset; second launch pulls fresh v16 manifest /
   v5 target_racks from Firebase via SeedUpdater.
2. **Color picker placement (9.8.A.2)** — ONE swatch row directly
   under the Single/Rack toggle, visible in both modes, same
   on-screen position when toggling.
3. **Tap-to-activate (9.8.B)** — in Range Day workspace rack mode,
   tapping a non-active slot in the scene should activate it
   (active-slot outline moves to the tapped slot, chip-row
   selection updates).
4. **Picker preview gestures (9.8.B.3)** — single-tap on the
   picker preview activates a slot; double-tap opens the enlarge
   dialog (was: single-tap opens the dialog).
5. **Multi-size rack catalog (9.8.C)** — switch to Rack mode,
   open the dropdown under the `Circle` chip — should now show
   THREE 5-Plate Equal Rack entries (6 in, 8 in, 10 in) plus the
   3-Plate Decreasing and KYL Circles. Same expansion under
   `Square` (4 in / 6 in / 8 in Equal Rack + Decreasing + KYL).

## Files changed (summary)

```
SCENE_PAINTER_PHASE_9_8_REPORT.md                                  (NEW)
assets/seed_data/manifest.json                                     (+6 / -6)
assets/seed_data/target_racks.json                                 (+882 / -68)  — Phase 9.8.C expansion
lib/database/seed_loader.dart                                      (+101 / -13)  — 9.8.B.2 self-heal
lib/screens/range_day/range_day_detail_screen.dart                 (+92 / -45)   — 9.8.A / A.1 / A.2 / B / B.3
lib/screens/range_day/widgets/target_plot.dart                     (+186 / -120) — 9.8.B onActiveRackSlotChange + computeRackSlotRects + colorHexOverride for racks
test/seed_data_schema_invariants_test.dart                         (+12 / -8)    — 9.8.C 9→13 rack count assertion
```

All commits include the `Co-Authored-By: Claude` trailer per repo
convention.

Phase 9.9 is the next-natural cleanup target if you want one — the
SVG-live-update infrastructure (paralleling SeedUpdater for JSON
catalogs) would let you hot-update animal art post-launch. Not in
scope today; scheduled.
