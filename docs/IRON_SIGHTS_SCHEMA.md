# Iron Sights Catalog Schema — VFP Phase 2 Group A

**Status:** Proposed for operator finalization at the Group A halt
(plan exit criterion: "Schema design reviewed with operator; sight
type enums finalized"). Storage: **JSON-only** — `scopes.json` rows +
`ScopeV2Row` Dart class. **No Drift migration; `schemaVersion` stays
42** (per VFP §1.8 / Appendix C / the F2/D-6 storage resolution).
**Purely additive:** every field below is nullable and absent on the
194 existing non-iron rows; the parser returns null and existing
consumers are unaffected (verified: 19/19 prior scope-catalog tests
green).

## Discriminator

Iron-sight rows are identified by **`category: "iron-sights"`** — a
new value of the existing free-string `category` field (current
values: `lpvo`, `prism`, `prism-sight`, `red-dot`, `rifle-scope`).
§0.5 verification: no code keys an exhaustive switch off scope
`category`, so adding the value is non-breaking.
`ScopeV2Row.isIronSights => category == 'iron-sights'`.

## New fields (9) — added in Group A

| JSON key | Dart (`ScopeV2Row`) | Type | Applies to | Canonical values |
|---|---|---|---|---|
| `front_sight_type` | `frontSightType` | string | all iron | `post` · `blade` · `bead` · `fiber_optic` |
| `front_sight_width_mm` | `frontSightWidthMm` | double | post / blade | measurement |
| `front_sight_diameter_mm` | `frontSightDiameterMm` | double | bead / fiber_optic | measurement |
| `rear_sight_type` | `rearSightType` | string | all iron | `notch` · `aperture` · `ghost_ring` · `buckhorn` · `tang_peep` |
| `rear_sight_aperture_mm` | `rearSightApertureMm` | double | aperture / ghost_ring | inner-dia measurement |
| `rear_sight_depth_mm` | `rearSightDepthMm` | double | notch / buckhorn | notch-depth measurement |
| `sight_radius_in` | `sightRadiusIn` | double | all iron | front↔rear distance, inches |
| `elevation_adjustment` | `elevationAdjustment` | string | all iron | `fixed` · `rear` · `front` · `both` |
| `windage_adjustment` | `windageAdjustment` | string | all iron | `fixed` · `rear` · `front` · `both` |

Enum-like fields are stored/parsed as trimmed `String?` (mirroring
the existing `category` / `focal_plane` style — the class uses raw
strings for analogous discriminators; no Dart enum is introduced, so
no exhaustive-switch surface is created). Canonical value sets are
documented here and enforced by the Group B seed-authoring + the
Group A parsing tests, not by a Dart enum.

## Reused existing fields (§0.5 finding — NOT re-added)

The plan's task-1 list also names `click_value_moa`,
`max_elevation_moa`, `max_windage_moa`. These **already exist** in
`scopes.json` (top-level scope fields) and are **reused** for iron
sights — not duplicated and not projected into `ScopeV2Row` (they
stay in the raw JSON for the renderer/solver, like `eye_relief_in`
etc.). Iron-sight rows simply populate them in Group B
(`click_value_moa` null for fixed/non-adjustable sights). Operator
to confirm this reuse at the Group A halt.

## Field applicability by sight type (authoring guide for Group B)

- **Front `post` / `blade`** → set `front_sight_width_mm`; leave
  `front_sight_diameter_mm` null.
- **Front `bead` / `fiber_optic`** → set `front_sight_diameter_mm`;
  leave `front_sight_width_mm` null.
- **Rear `aperture` / `ghost_ring`** → set `rear_sight_aperture_mm`;
  leave `rear_sight_depth_mm` null.
- **Rear `notch` / `buckhorn`** → set `rear_sight_depth_mm`; leave
  `rear_sight_aperture_mm` null.
- **`tang_peep`** → treat as an aperture; set `rear_sight_aperture_mm`.
- **`elevation_adjustment` / `windage_adjustment`**: `fixed` for
  non-adjustable military/historical sights; `rear`/`front`/`both`
  per the actual mechanism. When `fixed`, `click_value_moa` /
  `max_*_moa` are null.
- **`sight_radius_in`**: real published sight radius for the host
  rifle/configuration; required for sighting-picture scale (VFP
  Phase 21 `IronSightsPainter`).

## Out of scope for Group A (tracked downstream)

- Iron-sight catalog **rows** (~15–25) — VFP Phase 2 **Group B**
  (real military/manufacturer sight specs, cited; no fabrication per
  CLAUDE.md §0).
- Firearm-form optic-picker UI — **Group C**.
- **Consumer-contract trace (Group D, §0.5 Level 3):** the known
  conflict that `ScopeViewInputs` (`scope_view_screen.dart`) requires
  non-null `scopeMagnification`/`spec1xMagnification` and the
  firearm form auto-pairs a reticle on optic pick — iron sights have
  neither. The plan already schedules this trace in **Group D**; it
  is NOT solved in Group A. Flagged here so Group B/C/D inherit the
  constraint.
- IP posture: iron sights are identified by generic sight *type*,
  never by a manufacturer trade name (§9 / §30 generic-design
  posture); enforced in Group B authoring + the Group D IP sweep.

## Verification commands (real paths — plan's cited path is stale)

```
grep -c "frontSightType" lib/services/scope_catalog_v2.dart      # >=1
flutter test test/scope_catalog_v2_test.dart                     # plan
# cites test/services/scope_catalog_v2_test.dart which does NOT
# exist (D-8-class §0.5 note) — real path has no services/ segment
jq '[.[]|select(.category=="iron-sights")]|length' \
  assets/seed_data/scopes.json                                   # 0 in
# Group A (schema-only); flips to 15-25 after Group B
```
