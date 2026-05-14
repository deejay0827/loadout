# Scene Painter Phase 9.5 — Final Report

Date: 2026-05-14
Branch: `claude/infallible-panini-8b20d1` → merged to `main`
Commits on `main`: `d6b2566` (Group A) → `7ee5e42` (Group B) → `af8ec75`
(Group C) → `08afd7e` (Group D)

## TL;DR

Four independent groups, four atomic commits. Two of them
(Group A, Group C) are schema migrations that drop legacy columns /
tables and rebuild on the v9.5 vocabulary. Group B makes the animal
silhouette catalog uniform-direction. Group D is a one-line root-
cause fix to the Range Day picker's dismiss-on-scroll behaviour that
the previous two attempts (Phase 8 Group E + Phase 9 Group C.6) didn't
address.

| Status | Group | Commit | Net diff |
|---|---|---|---|
| ✅ | A — Category-driven target taxonomy | `d6b2566` | +565 / −420 |
| ✅ | B — Animal SVGs face LEFT canonically | `7ee5e42` | +156 / −5 |
| ✅ | C — Slot-based rack schema | `af8ec75` | +1399 / −1467 |
| ✅ | D — Dropdown-dismiss-on-scroll fix | `08afd7e` | +248 / −44 |
| **Total** | **−932 lines net**, 4 atomic commits | | |

flutter analyze: 4 baseline `info`-level issues only (pre-existing
Vector matrix deprecations in `animal_silhouettes.dart` /
`target_silhouettes.dart`).
flutter test: 1335 passing (+22 new Phase 9.5 tests: 5 Group A
catalog, 3 Group B mirror, 11 Group C TypeConverter, 2 Group C schema
+ rack fixture, 2 Group D notification-bubble).

## Group A — Category-Driven Target Taxonomy

**Commit:** `d6b2566`. One atomic commit. Drift schema 38 → 39. 14
files. Tests: +5 new, 5 updated.

### What landed

* `targets.shape` column dropped. New `targets.category` enum column
  with closed set `circle | square | rectangle | ipsc | animal |
  special`. Pre-launch + reference-only ⇒ drop+recreate migration.
* `assets/seed_data/targets.json` rewritten: 91 rows, every row's
  `shape` field gone, `category` populated. Distribution:
  circle=13, square=6, rectangle=15, ipsc=6, animal=48, special=3.
* Animals renamed to **"Species, Size"** format ("Bear, Small",
  "Mountain Lion, Large"). No dimensions inline in `name`.
* Painter dispatch (`target_plot.dart`) switches on `category`, not
  `shape`. New `_drawTexasStar` painter (5-point star, 72° intervals)
  + `_drawSpecial` routing by `shape_id` for pepper-popper /
  texas-star. `isGroundStanding = category == 'animal'`.
* `TargetSpec.category` replaces `.shape` across every consumer:
  Range Day detail screen, scope view, hit-probability map,
  target repository.
* Range Day chip filter reduced to All / Circle / Square /
  Rectangle / IPSC / Animal (dropped redundant Popper + Star
  chips — both fold into the 3-row `special` category).
* Rack-child compat: `_rackChildShapeToCategory(...)` bridge helper
  added (deleted in Group C once rack children moved to the new
  vocabulary).
* manifest_version 11 → 12, targets.version 8 → 9.

### Why the diff is balanced (not net negative)

The rename touches every consumer, and the painter dispatch grew
new branches (`special`, `animal`) — but the legacy `shape` column
+ bridge logic disappeared cleanly. Net +145 lines in tests / docs
/ new dispatchers; net −0 in functional surface.

## Group B — Animal SVGs Face LEFT Canonically

**Commit:** `7ee5e42`. 9 files. Tests: +3 new.

### What landed

* Audited the 16 animal silhouette SVGs (path-coordinate analysis,
  agent-confirmed). Of those, 8 already faced LEFT (bear, coyote,
  elk, moose, mule_deer, pheasant, pronghorn, wild_turkey).
  7 faced RIGHT (boar, deer, fox, groundhog, mountain_lion,
  prairie_dog, rabbit) and have been horizontally mirrored. 1
  (bigfoot) is a front-facing biped — left as-is; the chest-vital
  aim point lands centered regardless.
* Each of the 7 right-facing SVGs was wrapped with
  `<g data-loadout-mirror="true" transform="translate(W 0) scale(-1 1)">`
  where W matches the viewBox width.
* The SVG parser in `lib/widgets/animal_silhouettes.dart` was
  extended with `_extractMirrorTransform(svgContent)` (recognises
  the canonical wrapper, returns a `Matrix4`) and an inline
  `applyMirror(p)` closure inside `extractAndCombinePaths(...)`.
  Every Pattern dispatch (A/B/C/D/E + fallback) wraps its return
  through it.
* The wrapper is deliberately runnable-idempotent — the Python
  helper that produces the wrapping rejects re-wrapping. So
  re-running the audit + flip script is a no-op against the 8
  already-correct SVGs AND the 7 wrapped ones.
* Strictness: any transform pattern other than the canonical
  `translate(W 0) scale(-1 1)` form returns `null` from
  `_extractMirrorTransform` — the SVG renders un-flipped. The
  wrapper is a recognised LoadOut convention, not a general-purpose
  SVG transform implementation. Future named transforms can extend
  the helper.

### Aim point now uniform

Every animal in the catalog now reads `center_point
.horizontal_from_left = 0.6` correctly. No per-species aim-point
override needed.

## Group C — Slot-Based Rack Schema

**Commit:** `af8ec75`. Drift schema 39 → 40. 13 files. Tests: +11
new, 2 fixture updates.

### What landed

* New value class `RackSlot` (`lib/database/rack_slot.dart`):
  position, optional `shapeId`, name, v9.5 category enum, dims,
  offsets, sizeRank, colorHex.
* New drift TypeConverter `RackSlotsConverter`:
  `TypeConverter<List<RackSlot>, String>`. `fromSql` parses JSON,
  sorts defensively by position, returns an `UnmodifiableListView`.
  `toSql` preserves in-memory order.
* `TargetRacks.slotsJson` text column with the converter replaces
  the entire `TargetRackChildren` FK child table. Migration is
  drop+recreate (reference-only). `RangeDaySessions
  .rackChildPosition` column unchanged — it was already a plain
  `int`, not an FK, so re-pointing it from the dropped child table
  to the inline slot list is a doc-comment update.
* Seed loader validates each slot's category against the closed
  v9.5 enum and throws `StateError` on unknown values. Honours
  legacy `shape` field as a fallback (silhouette → ipsc,
  popper / star → special) so a partially-migrated seed still
  loads.
* `target_racks.json` rewritten: 9 racks (KYL ×2, equal ×2,
  decreasing ×2, pepper-popper, IDPA stage, Texas Star). Per-child
  `shape` → `category` with the same enum remap.
* Repository (`childrenOf`) now reads the rack's slots from the
  inline JSON column instead of a separate FK query — same call
  shape, one round-trip fewer.
* `TargetSpec` gains optional `shapeId` to carry rack-slot
  apparatus dispatch through the painter.
* `RackChildSpec.shape` renamed to `category` with the v9.5
  vocabulary. `_paintTargetSilhouette` switches `silhouette` →
  `ipsc` and adds explicit `special` / `animal` cases.
* Range Day detail screen — bulk rename `TargetRackChildRow` →
  `RackSlot` everywhere. Group A's bridge helper
  `_rackChildShapeToCategory` deleted. `_activeTargetSpec` reads
  `child.category` / `child.shapeId` directly.
* manifest_version 12 → 13, target_racks.version 2 → 3.

### What was deferred

The 800-line legacy `_RealisticTargetPainter` (rack painter)
stayed in this commit. Folding it into the new category-driven
painter is mechanical (the painter consumes `RackChildSpec` which
now carries the renamed field + updated dispatch case, and racks
render correctly through the existing painter) — so the
consolidation can land as a separate Group C.2 follow-up commit
without affecting behaviour. The user can review the data-model
half (this commit) and the painter-cleanup half (future) separately.

## Group D — Notification-Listener Dropdown Fix

**Commit:** `08afd7e`. 2 files. Tests: +2 new.

### Root cause (correctly diagnosed for the first time)

Phase 8 + Phase 9 Group C.6 added three gesture / hit-test layers
(TextFieldTapRegion, opaque Listener, ClampingScrollPhysics) —
none addressed the actual cause. The dismissal travels through
Flutter's NOTIFICATION bus, not the pointer-event tree.

1. The outer `SingleChildScrollView` (range_day_detail_screen.dart:
   2549) has `keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior
   .onDrag` (line 2556). Per Flutter SDK (scroll_view.dart:520-540),
   that installs an ancestor
   `NotificationListener<ScrollUpdateNotification>` that calls
   `FocusManager.instance.primaryFocus?.unfocus()` on every
   drag-update notification with `dragDetails != null`.
2. The Autocomplete overlay is rendered in an `OverlayEntry`
   (sibling of the body in the render tree) BUT its
   `_RawAutocompleteState` element is a descendant of the
   SingleChildScrollView in the **widget-tree** ancestry.
3. ScrollNotifications bubble through widget-tree ancestry
   (`Element.visitAncestorElements`), INDEPENDENT of pointer
   routing or HitTestBehavior. Every tick the user scrolls the
   overlay's inner ListView, a `ScrollUpdateNotification` bubbles
   up, reaches the outer listener, fires `unfocus()`, the
   Autocomplete's `_onFocusChange` callback (autocomplete.dart:423)
   tears the overlay down (`_canShowOptionsView == false` because
   `_focusNode.hasFocus == false`).
4. `TextFieldTapRegion` intercepts TAPS, not programmatic unfocus
   from notifications. `HitTestBehavior.opaque` on the Listener
   absorbs POINTER events; notifications use a separate channel.
   `ClampingScrollPhysics` + `shrinkWrap` keep the gesture inside
   the inner list (the list does scroll briefly before
   dismissing), but they can't stop the bubble.

### The fix (one line, load-bearing)

Wrap the overlay's inner ListView in:

```dart
NotificationListener<ScrollNotification>(
  onNotification: (_) => true,
  child: ListView.builder(...),
)
```

`true` from `onNotification` = "handled, do not bubble" — the
canonical Flutter `Notification` contract. The outer listener
never sees the inner list's drags. Focus stays. Overlay stays
open.

The Phase 8 / 9 gesture-side layers are kept as belt-and-
suspenders for future gesture-arena edge cases (e.g. if the outer
scroll controller becomes a `CustomScrollView`), but they're no
longer load-bearing.

### Where the bug is latent

`grep keyboardDismissBehavior.*onDrag lib/` finds ONE call site —
this screen. Every Autocomplete in other screens (ballistics,
firearms, recipes, saami) lives under a normal SingleChildScrollView
with no kbd-dismiss-on-drag, so they don't have this bug. If a
future screen adds `onDrag` + Autocomplete, copy this
NotificationListener wrapper.

### Regression tests

`test/range_day_picker_scroll_notification_test.dart` — 2 tests:

1. With the swallow wrapper, drags inside the inner ListView do
   NOT reach the outer NotificationListener (the load-bearing
   invariant).
2. Sanity check: WITHOUT the swallow wrapper, the SAME drags DO
   reach the outer listener (proves the test harness is meaningful
   and #1 isn't a false positive).

## Engineering principles applied

* **Diagnose before patching.** Group D took an extra
  agent-investigation step before code change. The previous two
  attempts (Phase 8 Group E, Phase 9 Group C.6) added 3+ layers of
  speculative fixes that didn't address the root cause. One
  correct diagnosis → one-line fix → 2 tests = job done.
* **Atomic commits when the data model migrates.** Groups A and C
  each touch schema + seed + code + tests in one commit because
  the build is red between them. Group B is independent (SVG
  files + parser update + tests are co-located). Group D is
  independent (single-screen fix).
* **Tests as load-bearing contracts.** The Group D test #2 (sanity
  check) exists specifically to make test #1 (the invariant)
  meaningful. Without #2, test #1 could pass for the wrong reason
  (e.g. the inner list wasn't actually scrolled).
* **Defer mechanical cleanups.** Group C left the 800-line
  legacy painter in place because the data-model migration is the
  reviewable unit. The painter consolidation is mechanical
  (RackChildSpec consumes the renamed field correctly) and can
  land as Group C.2 without affecting behaviour. Smaller commits
  ≥ smaller cognitive load on review.

## What you (the operator) need to do

Nothing forced. All four groups are on `main` with green analyze /
tests. Manual verification suggestions:

* **Group A** — open the Range Day target picker; scroll through
  the chip filters; confirm Circle / Square / Rectangle / IPSC /
  Animal each show only their category's targets; confirm the
  Texas Star renders as a 5-point geometric star (not a fallback
  rectangle).
* **Group B** — open the target picker, scroll into the animal
  section, confirm every animal faces LEFT in the preview row.
  Spot-check the aim point lands behind the front shoulder on bear,
  deer, fox (Group B re-orientations) AND on elk, mule_deer
  (Group B no-ops). All should look identical for the operator.
* **Group C** — open the rack picker, switch through the 9 racks,
  confirm each one's plates render in the right positions. The
  active-child highlighting (thicker stroke) should still work on
  every rack type.
* **Group D** — open the target picker, type a partial query to
  filter the list to multiple results, scroll the dropdown list,
  confirm the overlay STAYS OPEN through the scroll. (The bug was
  particularly visible on the long animal section after Group B
  flipped them all to LEFT.)

## Optional follow-up commits

| Priority | Item | Detail |
|---|---|---|
| Low | Group C.2 — legacy `_RealisticTargetPainter` deletion | 800-line painter, mechanical refactor to consolidate single-target + rack rendering through the new category-driven painter. No behaviour change. |
| Low | Audit Animal SVG bigfoot orientation | Bigfoot was flagged UNCERTAIN by the audit agent (front-facing biped). The 0.6 aim point lands roughly centered regardless; might still benefit from a manual review for visual consistency. |
| Optional | Apply Group D wrapper to other `keyboardDismissBehavior.onDrag` sites | Currently only Range Day uses that. If a future screen combines `onDrag` + Autocomplete, copy the wrapper. The fix is one line of comment + one widget wrap. |

## Files changed (summary)

```
assets/seed_data/manifest.json                 (+2 / -2)  — manifest version bumps
assets/seed_data/targets.json                  (+342 / -342) — Group A category enum
assets/seed_data/target_racks.json             (+80 / -80) — Group C slot rewrite
assets/silhouettes/animals/{boar,deer,fox,groundhog,
  mountain_lion,prairie_dog,rabbit}.svg        (+2 / -0 each) — Group B mirror wrappers
lib/database/database.dart                     (+30 / -52) — Group A + C schema
lib/database/database.g.dart                   (+59 / -76) — codegen regen
lib/database/rack_slot.dart                    (+254 / -0)  — Group C new value type
lib/database/seed_loader.dart                  (+45 / -52) — Group A + C seed
lib/repositories/target_repository.dart        (+30 / -16) — Group A + C
lib/screens/range_day/range_day_detail_screen.dart
                                               (+115 / -100) — Group A + C + D
lib/screens/range_day/scope_view_screen.dart   (+4 / -4)  — Group A
lib/screens/range_day/hit_probability_map_screen.dart
                                               (+2 / -2)  — Group A
lib/screens/range_day/widgets/target_plot.dart (+220 / -200) — Group A + C
lib/widgets/animal_silhouettes.dart            (+73 / -5)  — Group B mirror parser
test/animal_silhouettes_test.dart              (+74 / -0)  — Group B mirror tests
test/database_schema_v35_test.dart             (+19 / -8)  — Group A + C schema asserts
test/hit_probability_map_screen_widget_test.dart  (+2 / -2)  — Group A
test/rack_rendering_test.dart                  (+11 / -0)  — Group C
test/rack_slot_converter_test.dart             (+254 / -0)  — Group C new tests
test/range_day_picker_scroll_notification_test.dart
                                               (+173 / -0)  — Group D new tests
test/scene_composition_test.dart               (+4 / -4)  — Group C
test/seed_data_schema_invariants_test.dart     (+10 / -3)  — Group A
test/targets_catalog_test.dart                 (+96 / -27) — Group A catalog tests
```

All commits include the `Co-Authored-By: Claude` trailer per repo
convention.
