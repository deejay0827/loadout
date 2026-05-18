# Iron Sights Catalog Audit — VFP Phase 2 Group B

**Source-retrieval date:** 2026-05-18. **Method:** four parallel
research agents sourced real published mil-spec / manufacturer /
reputable-armorer iron-sight dimensions; every value carries a
`source_url`; values not findable from a reputable source were left
**null + "unverified"** (never fabricated — CLAUDE.md §0 / §0.5 L4).
**Storage:** JSON-only, `scopes.json` + `ScopeV2Row` (no Drift;
`schemaVersion` 42). **Additive:** 194 → **213** rows; the 194
non-iron rows are unchanged (iron fields absent → null).
**IP (§9.5/§30):** every `id`/`model` generic or military-historical;
`manufacturer` = "Generic" for all 19; IP sweep = **0 trade names**.
**Disposition vocab** (D-9 taxonomy, applied consistently):
`matches` (all key dims sourced) · `accept_with_rationale` (partial /
representative / by-design-null, documented) · `excluded` (no
sourceable dims — not shipped).

## 1. Authored rows (19) — `category: "iron-sights"`

| id | front (mm) | rear (mm) | sight_radius_in | clicks MOA | conf | disposition | §B.9 |
|---|---|---|---|---|---|---|---|
| ar15_a2_rifle_irons | post 1.59 | aperture 1.78 | 19.75 | 1.0/0.5 | HIGH | matches | ✅ |
| m4_carbine_irons | post 1.59 | aperture 1.78 | 14.5 | ~0.75 | HIGH | matches | ✅ |
| m16a4_rifle_irons | post 1.59 | aperture 1.78 | 19.75 | 0.5 | HIGH | matches | |
| m16a1_rifle_irons | post 1.59 | aperture 1.78 | 19.75 | null | MED-HIGH | accept_with_rationale | |
| akm_pattern_rifle | post null | notch null | 14.9 | null | radius HIGH | accept_with_rationale | ✅ |
| mauser_98k_carbine | post null | notch null | 19.7 | null | radius HIGH | accept_with_rationale | |
| m1_service_rifle | post 2.13 | aperture 1.51 | ~28 | 1.0 | HIGH (rad MED) | matches | |
| no4_service_rifle | blade null | aperture ~2.38 | 28.74 | null | MED | accept_with_rationale | |
| sks_carbine | post 1.83 | notch null | ~19 | null | MED | accept_with_rationale | |
| iron_1911_gi_service | blade 3.00 | notch d2.29 | 6.48 | null | MED | accept_with_rationale | ✅ |
| iron_polymer_service_factory | post 3.56 | notch d2.79 | 6.49 | null | HIGH | matches | ✅ |
| iron_target_match_adjustable | blade 3.18 | notch d null | 6.75 | ~1.0 | MED | accept_with_rationale | |
| iron_service_revolver_fixed | blade 2.54 | notch d1.96 | 6.9 | null | MED | accept_with_rationale | |
| iron_combat_3dot_upgrade | post 3.18 | notch d null | 6.0 | null | HIGH | accept_with_rationale | |
| marbles_pattern_tang_peep | bead Ø1.59 | tang_peep 1.40 | null | null | HIGH | accept_with_rationale | ✅ |
| target_globe_diopter | globe Ø3.8 | aperture 1.75 | null | null | MED | accept_with_rationale | ✅ |
| lever_action_semi_buckhorn | bead Ø1.59 | buckhorn null | null | null | MED | accept_with_rationale | |
| dangerous_game_express | bead Ø null | notch d3.49 | null | null | MED | accept_with_rationale | |
| shotgun_front_bead | bead Ø3.30 | (none) | null | null | HIGH | accept_with_rationale | |

Per-row `source_url` + caveats are in each scopes.json row's `notes`.
`accept_with_rationale` reasons: partial dims where a factory
spec is genuinely unpublished (left null, documented); a
representative midpoint of a continuous/published range (target
globe iris, express V depth — flagged in notes as representative,
not a single spec); or a by-design null (shotgun = no rear sight;
tang/globe = host-mounted radius). Notch `width` was sourced for
some pistols but the finalized schema has only `rear_sight_depth_mm`
(operator deferred notch-width to a future additive field) — width
captured in `notes` as context, not in a field.

All 7 §B.9 worked-example anchors authored (AR-15 A2, M4, AK,
1911 GI, polymer-service, Marble's tang, target globe).

## 2. Exclusions (2) — not shipped (no sourceable dimensions)

| id | reason |
|---|---|
| `ar15_buis_generic` | Generic flip-up BUIS has no canonical published dimensions (post/aperture/radius vary by maker + user rail position). All dims would be null → fails the Group B "entries have dimensions + source" bar. Not a §B.9 anchor. Same posture as the Phase-1 Steiner exclusion. |
| `mosin_91_30_rifle` | Mosin 91/30 sight radius + front-post width + rear-notch depth are not published by any reputable source (only the sight *type* is). Zero sourceable numeric dimensions. Not a §B.9 anchor. Excluded; documented here. |

No fabrication used to "rescue" either row.

**Status for future authoring passes: DELIBERATELY OMITTED, not
"not-yet-added."** Both rows were evaluated, sourced-attempted, and
intentionally excluded because no reputable published numeric
dimensions exist. Do NOT re-author `ar15_buis_generic` or
`mosin_91_30_rifle` in a later pass unless *new sourceable
measurements appear* — re-adding them with estimated/averaged
dimensions would violate CLAUDE.md §0 / §0.5 L4 (the D-9a precedent
applied to authoring). If a future pass needs a generic BUIS or a
Mosin entry, it must bring a citable spec, not a guess.

## 3. §0.5 finding — §B.9 host-dependent sight radius (operator decision)

**Both `tang_peep`/`globe` §B.9 anchors (`marbles_pattern_tang_peep`,
`target_globe_diopter`) have NO catalog-sourceable `sight_radius_in`.**
Tang and globe sights are host-rifle-mounted with no fixed
manufacturer-published radius (it depends entirely on the rifle they
are fitted to). Their *sight geometry* IS sourced (tang peep aperture
1.40 mm; globe insert Ø3.8 mm) — only the radius is null. But the
§B.9 sighting-picture spread math (the "target rifle globe ≈ 1.85
mil" extreme / the "14× spread" claim) is anchored on a sight
radius. Per CLAUDE.md §0 / §0.5 L4 no radius was fabricated.

**Pending operator decision (V6.12 / §B.9 codification — does NOT
block Group B; analogous to D-9d / D-5 deferral posture):**
- (1) Supply a **documented nominal modeling radius** for tang/globe
  (e.g. lever-gun nominal / smallbore-target nominal), recorded in
  the row `notes` + §B.9 explicitly as a *modeling assumption, not a
  sourced spec*, so the §B.9 globe-extreme math has a concrete input.
- (2) Restate §B.9's globe/tang spread examples in a radius-relative
  (or angular-from-aperture) form that does not require a per-row
  radius.
- (3) Accept the rows as authored (radius null, documented) and mark
  the §B.9 globe/tang numeric examples as illustrative-only.

## 4. Verified-after

- `jq length scopes.json` → **213** (194 + 19; additive)
- `jq '[.[]|select(.category=="iron-sights")]|length'` → **19**
- 7/7 §B.9 anchors present; `front_sight_type` ∈ {post 10, blade 4,
  bead 4, globe 1} — all within the finalized canonical 5-set
- IP sweep (id+model+manufacturer, word-boundary) → **0 trade names**
- `flutter analyze` clean; scope-catalog test gate green (Group A
  latent test flipped to the Group B populated assertion: 15-25
  count, 7 anchors, every row dimensioned, non-iron rows still null)

## 5. Cumulative V6.12 codification feed (adds to D-6/7/8/9 + Phase 1)

- **Group A enums FINALIZED** incl. `globe` (front 5-set / rear 5-set
  / adj 4-set ×2); `category: "iron-sights"` non-breaking
  discriminator.
- **D-6-class:** V6.11 task-1/4 `front_sight_type` list omits
  `globe` (present in §B.9 / §4.7 / §0.5-L5); V6.12 must add it.
- **"Reuse not duplicate" sub-rule:** `click_value_moa` /
  `max_*_moa` reused for iron rows (null for fixed sights), not
  duplicated. Codify in V6.12 §30/schema-design.
- **D-8-class path drift (now 2×):** plan-cited
  `test/services/scope_catalog_v2_test.dart` does not exist;
  one-time V6.12 sweep of all `test/` citations recommended.
- **New (Group B):** `tang_peep`/`globe` host-dependent sight
  radius — §B.9 needs a documented modeling-assumption rule (§3
  above). And: notch `width` vs the depth-only schema — a future
  additive `rear_sight_notch_width_mm` field if Phase 21
  `IronSightsPainter` needs it (operator deferred in Group A).

### Operator-locked V6.12 directives (post-Group-B review 2026-05-18)

- **§30 rule 2 — third manufacturer value `"Generic"`** (operator
  amendment). `manufacturer ∈ {"LoadOut","Public Domain","Generic"}`:
  *LoadOut* = LoadOut-authored/redrawn (designer "LoadOut", LoadOut
  family); *Public Domain* = canonical public-domain pattern rows
  (designer "Public domain", `subtension_origin: public_domain`);
  *Generic* = factually-descriptive military/historical/commodity
  equipment rows without commercial trade names (iron-sights, BUIS-
  class) under the §9.5 descriptive exception. Manufacturer trade
  names remain forbidden across all three. The 19 iron rows already
  comply (manufacturer uniformly "Generic"; IP sweep 0 trade names).
- **New disposition class: `expand_enum`** — authoring legitimately
  needs a value the V6.11 schema did not anticipate (first instance:
  `"Generic"` manufacturer). Sits alongside the D-9 five
  (`matches`/`re-cite`/`re-tag`/`accept_with_rationale`/
  `clarify_scope`). Triggers a §0.5 surface + V6.12 feed, not a
  silent add.
- **Tang/globe host-radius rule — LOCKED option (c)** (operator).
  Catalog stores host-INDEPENDENT geometry only
  (`front_sight_diameter_mm`, `rear_sight_aperture_mm`);
  `sight_radius_in = null` for intrinsically host-mounted sights
  (`tang_peep`, `globe`, future host-mounted categories). Phase 21
  `IronSightsPainter` receives `sight_radius_in` as a runtime
  parameter from the host firearm's row. **This already matches the
  as-implemented Group B state — no code change; finding #1 is
  resolved as LOCKED, not pending.**
- **§B.9 worked-example framing clarification** (operator): the §B.9
  numbers (target rifle 1.85 mil; Marble's tang 3.33 mil) are math
  *demonstrations with specific assumed inputs documented inline*,
  NOT catalog-derivable invariants. V6.12 to annotate §B.9 prose
  accordingly.
- **§0.5 finding #2 (scope→reticle invariant)**: handling confirmed
  correct by operator; Group D owns re-broadening the invariant once
  its null-guard design lands (iron rows should then PASS a
  broadened invariant rather than be scope-excluded). Carried to
  Group D as a verifiable exit criterion.

## 6. Group B → Group D handoff (consumer-contract conflict, concrete)

Authoring the 19 rows made the plan-anticipated iron-sight consumer
conflict concrete at the test/invariant layer: the pre-existing
`scope_catalog_v2_test.dart` invariant "every scope has a default
reticle mapping" went RED because the 19 iron rows have **no
`scope_reticle_options.json` mapping (iron sights have no reticle by
design)**. §0.5-correct handling in Group B: the invariant test was
**scoped to non-iron rows** with an explicit comment that the
firearm-form auto-pair / Range Day null-guarding for iron optics is
**VFP Phase 2 Group D**'s designated scope (iron-sights
consumer-contract trace, §0.5 Level 3) — Group B does NOT decide it.
The 194 magnified-optic rows still fully satisfy the invariant (no
regression). Group D must resolve: (a) give iron rows a
`pd_iron_sight_ring`-style mapping, or (b) null-guard
`defaultReticleIdForScope` / firearm-form / `ScopeViewInputs`
consumers for iron optics. Carried, does not block Group B.
