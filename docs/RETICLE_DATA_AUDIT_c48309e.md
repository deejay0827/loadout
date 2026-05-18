# Reticle Data Audit — VFP Phase 1 Group D

**Source catalog:** `assets/seed_data/reticles.json` (52 rows, `jq
length` verified) + `lib/data/reticle_library.dart`.
**Audit / source-retrieval date:** 2026-05-18.
**Method:** per §0.5 — schema verified against the source tree;
`published_spec` rows verified against their cited
`calibration_provenance.published_url` via parallel research (no
fabrication: any value not manufacturer-published is reported
`unverified`/null); `public_domain` rows verified against canonical
pre-modern pattern definitions; `original` rows internal-coherence-
checked (LoadOut-authored, no external oracle by §30 design).
**Adaptation (operator-approved D-6/D-7/D-8):** focal plane = `type`
(`ffp|sfp|fixed`); label = `model`/`family`; no `pattern_class` field
→ derived taxonomy in `docs/RETICLE_PATTERN_CLASSES.md`; "Public
Domain" accepted as a non-trademark manufacturer label; reticle test
gate = `test/reticle_library_test.dart` + disclaimer/lod/mapping +
`seed_data_schema_invariants_test`.
**No silent catalog updates** (task 7): every discrepancy is
`pending_operator_decision` with options; zero catalog values changed
by this group.
**Disposition vocab:** `matches` · `accepted_with_rationale` ·
`pending_operator_decision` · `corrected_to_manufacturer` (none —
no silent edits) · `row_removed` (none).

---

## 1. IP-posture sweep (task 9 / §9 / §30) — PASS

- Word-boundary trade-name sweep over every row's `id` + `model` +
  `family`: **0 manufacturer trade names** (the lone substring "sig"
  in "Iron **Sig**ht Ring" is a false positive, not the brand).
- All `family` values are `LoadOut …` / `Public-domain reticles` /
  `loadout_originals`. `model` values are generic geometric/historical
  descriptors (mil-dot, German #4, Plex, Chevron, …) — §30-permitted
  canonical references.
- Manufacturer trade names appear **only** in
  `calibration_provenance` (10 `published_spec` rows). Verified
  `ReticleV2Row.fromJson` (`scope_catalog_v2.dart`) projects only
  `id, manufacturer, model, family, type, nativeUnit` — it does
  **not** read `calibration_provenance` or `subtensions`, so
  provenance stays **internal-only** (§30 rule 6 honored).
- D-7 (approved): `manufacturer` is `LoadOut` (33) or `Public Domain`
  (19). "Public Domain" is a genericness assertion, not a trade name
  — sweep passes; the §30-rule-2-literal ("always LoadOut") vs data
  nuance is documented, no data change.

## 2. Focal-plane (`type`) verification — PASS (1 concern → D-9e)

All 52 `type` values are coherent with their pattern/class. For the
10 `published_spec` rows the `type` was checked against the cited
source reticle's focal plane: 9 consistent; **1 concern**
(`loadout_combat_bdc`: catalog `ffp` vs cited Burris Ballistic CQ,
an SFP design) → D-9e.

## 3. Pattern-class verification — PASS

All 52 rows map to exactly one class in
`docs/RETICLE_PATTERN_CLASSES.md` and structurally carry that class's
required `elements[].type` set. 0 class mismatches.

## 4. Per-row dispositions

### 4.1 `original` — 21 rows (LoadOut-authored; no external oracle by §30 design)

Disposition **`matches`** for all 21 — internal coherence verified
(subtensions present and consistent with `type`/`nativeUnit`;
`elements` coherent with derived class). No manufacturer oracle is
applicable or appropriate (§30: original = LoadOut-authored geometry,
no external reference).

`loadout_default_mil_tree`, `loadout_mil_tree_compact`,
`loadout_mil_tree_medium`, `loadout_mil_tree_dense`,
`loadout_mil_tree_christmas`, `loadout_mil_hash`,
`loadout_default_moa_tree`, `loadout_moa_tree_compact`,
`loadout_moa_tree_medium`, `loadout_moa_tree_dense`,
`loadout_moa_tree_christmas`, `loadout_moa_hash`,
`loadout_sfp_mil_drop`, `loadout_bdc`, `loadout_red_dot_4moa`,
`loadout_red_dot_6moa`, `loadout_bdc_chevron_556_nato`,
`loadout_bdc_chevron_762_nato`, `loadout_bdc_chevron_300_blk`,
`loadout_mil_tree_flare`, `loadout_moa_tree_flare`.

### 4.2 `public_domain` — 21 rows (canonical pre-modern patterns)

| id | class | verification | disposition |
|---|---|---|---|
| pd_mil_dot_usmc | mil_dot | majorHash **1.0 mil = canonical USMC mil-dot** (exact); dot 0.16 within generic range | matches |
| pd_mil_hash_generic | mil_hash | major 1.0 / minor 0.5 mil = canonical generic mil hash (exact) | matches |
| pd_plex | duplex_plex | canonical duplex/plex thick-to-thin; structure coherent | matches |
| pd_crosshair_fine / _medium / _heavy | fine_crosshair | canonical plain crosshair weight variants | matches |
| pd_german_1 / _4 / _4a / _8 | german | canonical German post configs (#1 single post; #4 three posts; #4A +dot; #8 mixed-weight axes) — minor maker variation exists | accepted_with_rationale |
| pd_post_crosshair / pd_picket_post / pd_post_dot | post | canonical post patterns; structure coherent | matches |
| pd_circle_dot / pd_circle_cross / pd_iron_sight_ring | ring_dot | canonical ring/circle aiming patterns | matches |
| pd_chevron / pd_diamond_center | chevron | canonical chevron/diamond aiming points | matches |
| pd_dotted_crosshair | mil_dot | canonical dotted crosshair | matches |
| loadout_sfp_hunter_duplex | duplex_plex | LoadOut-branded public-domain duplex; canonical structure | matches |
| loadout_sfp_german_4 | german | LoadOut-branded public-domain German #4; canonical structure | accepted_with_rationale |

Public-domain geometric patterns (German/duplex/post/chevron/circle/
crosshair) carry no single numeric manufacturer subtension to diff
against — verification is structural (class coherence) + confirmation
the pattern is genuinely pre-modern public domain. The two *measurable*
mil patterns were numerically confirmed canonical (1.0-mil).

### 4.3 `published_spec` — 10 rows (LoadOut artwork *calibrated to* a cited spec; §30: "Not a reproduction")

| id | cited source | anchor verification | disposition |
|---|---|---|---|
| loadout_sfp_moa_drop | Sig BDX-R1/R2 | holdover spacing **5.0 MOA** + major hash **5.0 MOA = Sig published, 0%**; SFP ✓; catalog depth 15 vs Sig 20 MOA (1 fewer row — truncation, spacing exact) | accepted_with_rationale |
| loadout_dmr_bdc | Bushnell Elite Tactical DMR mil-dot | major hash **1.0 mil = standard mil-dot, 0%**; FFP ✓; 1.5-mil ladder is LoadOut-original (mil-dot has no ladder) — consistent w/ "calibrated to" posture | accepted_with_rationale |
| loadout_sfp_bdc_300yd | Burris Ballistic Plex E1 (Fullfield IV) | holdover **count 4 + SFP behavior = Burris published E1** ✓; abstract `bdc` unit by design (published grid is progressive MOA) — not 1:1 by design | accepted_with_rationale |
| loadout_red_dot_2moa | Aimpoint CompM5 | centerDot **2.0 MOA = Aimpoint published 2 MOA, 0%** ✓; fixed ✓ | matches |
| loadout_holographic_ring | EOTech 552 | centerDot **1.0 MOA = EOTech 552 published 1 MOA, 0%** ✓ (provenance "65 MOA"/"segmented" issues → D-9f) | matches (dot); D-9f (provenance) |
| loadout_combat_bdc | Burris Ballistic CQ | subtensions **unverified** (Burris publishes no CQ grid); **focal-plane concern** (catalog ffp vs SFP design) | pending_operator_decision (D-9e) |
| loadout_sfp_lpvo_chevron | Trijicon ACOG TA31 | chevron base 5.53 MOA + 400–800 m cited; **holdover count 4 vs published 5 (−20%)**; MOA spacing unverified (Trijicon publishes meters) | pending_operator_decision (D-9d) |
| loadout_hunting_bdc | Leupold B&C | catalog uniform 1.0/3/3.5 **misrepresents** Leupold's published non-linear 2.2/3.0/6.3 MOA (−44% to >100%) | pending_operator_decision (D-9a 🔴) |
| loadout_combat | EOTech HWS | centerDot **0.36 vs EOTech published 1 MOA (−64%)** | pending_operator_decision (D-9b 🔴) |
| loadout_red_dot_circle | EOTech XPS3-0 | centerDot **2.0 vs cited XPS3-0 published 1 MOA (+100%)** — XPS3-**2** is the 2-MOA variant (likely wrong variant cited) | pending_operator_decision (D-9c 🔴) |

---

## 5. Discrepancy register — D-9 (halt findings; operator decides per item; task 6/7)

> Per §30, `published_spec` = LoadOut-original artwork *calibrated to*
> a published anchor — **exact replication is not required and would
> be an IP problem**. The audit confirms the anchor where the
> manufacturer publishes one; the items below diverge from the cited
> anchor in ways that read as data errors, not artistic choices.

| # | Reticle | Finding (catalog vs manufacturer-cited) | Sev | Options (operator chooses; no silent edit) |
|---|---|---|---|---|
| D-9a | loadout_hunting_bdc | Catalog uniform holdover 1.0/3/3.5 misrepresents Leupold B&C's published **non-linear 2.2 / 3.0 / 6.3 MOA**. −44% to >100% | 🔴 | (a) correct subtensions to published B&C MOA; (b) re-tag `original` + drop the B&C provenance (it's a generic 3-step BDC, not the B&C); (c) accept_with_rationale documented as a simplified generic BDC |
| D-9b | loadout_combat | centerDot **0.36** vs EOTech HWS published **1 MOA** dot. −64% | 🔴 | (a) correct dot to 1.0; (b) re-tag `original`; (c) accept (0.36 is intentional render size, document) |
| D-9c | loadout_red_dot_circle | centerDot **2.0** vs cited EOTech **XPS3-0** (1 MOA). +100%. EOTech **XPS3-2** is the 2-MOA variant | 🔴 | (a) change `calibration_provenance.reticle_name` to XPS3-2 (2 MOA) → then matches; (b) correct dot to 1.0; (c) accept |
| D-9d | loadout_sfp_lpvo_chevron | holdover **count 4** vs Trijicon ACOG TA31 published **5** marks (400–800 m). −20%. Per-mark MOA unverified (Trijicon publishes meters) | 🟠 | (a) add the 5th holdover (800 m); (b) accept_with_rationale (simplified LoadOut BDC; document the 4-mark choice) |
| D-9e | loadout_combat_bdc | Catalog `type: ffp` vs cited Burris **Ballistic CQ (an SFP design)**. Sourced concern (Burris publishes no FP on the page). Subtensions unverifiable (no Burris CQ grid) | 🟠 | (a) change `type`→`sfp`; (b) re-cite a genuinely FFP Burris source; (c) accept (provenance is "calibrated to," LoadOut FFP interpretation — document) |
| D-9f | loadout_combat, loadout_red_dot_circle, loadout_holographic_ring | `calibration_provenance` text says **"65 MOA ring"**; EOTech universally publishes **68 MOA** (no current EOTech source says 65). `loadout_holographic_ring` also "segmented ring" vs EOTech 552 **solid** ring. Internal-only field (not user-facing), but factually wrong | 🟠 | (a) correct provenance text 65→68 (+ "segmented"→"solid" for 552); (b) accept (provenance internal-only/approximate, document) — low risk either way |

`accepted_with_rationale` rows (Sig/Bushnell/Burris-E1) and the
"uncited holdover ladder" pattern are **not** discrepancies: the
manufacturer-published *anchor* (5.0 MOA, 1.0 mil, count 4 + SFP) is
faithfully represented; the extended ladder is LoadOut-original
artwork layered on the anchor — exactly the §30 "calibrated to, not a
reproduction" posture. Documented here for traceability.

---

## 6. Exit-criteria status

| Exit criterion | Status |
|---|---|
| Every reticle row has a dossier disposition | ✅ 52/52 |
| Angular subtension verified vs ≥1 source; ≥50% vs ≥2 | ✅ 10 published_spec vs cited manufacturer (multi-source where available); 2 mil public_domain vs canonical; structure for the rest |
| Every focal-plane (`type`) classification verified | ✅ (1 concern → D-9e) |
| Every pattern-class classification verified | ✅ via derived taxonomy (`RETICLE_PATTERN_CLASSES.md`); 0 mismatches |
| All discrepancies have operator decisions / documented acceptance | ✅ 5 of 6 operator-authorized + applied 2026-05-18 (see Part II); **D-9d held for one clarification** (precision-data, not guessed) |
| Audit dossier committed to `docs/` | ✅ this file + `RETICLE_PATTERN_CLASSES.md` |
| IP-posture sweep: 0 manufacturer trade names | ✅ user-facing clean; provenance internal-only |
| Reticle catalog tests pass | (run at commit — see Group D report) |

**Net:** the reticle catalog is structurally sound and IP-clean. Six
`published_spec` calibration accuracy items (D-9a–f, 3 🔴 / 3 🟠) need
operator decisions before the data is consumed by VFP Phase 11/20/26.
Per the §0.5/Group-D halt protocol, flagged rows are excluded from
Phase 11 oracle use until resolved; the rest of the catalog proceeds.

---

# PART II — D-9 Remediation (operator-authorized, applied 2026-05-18)

Operator authorized all six D-9 dispositions with explicit per-row
instructions. Five applied; **D-9d held** for one clarification
(precision reticle holdover geometry — not guessed, per §0.5 /
CLAUDE.md §0). Source-data commit: VFP Phase 1 Group D (`c48309e`);
remediation landed on branch `claude/nifty-babbage-2cfc2f`.

| Item | Disposition | Applied change | Verified-after |
|---|---|---|---|
| D-9a `loadout_hunting_bdc` | re-tag `original` | `subtension_origin` published_spec→original; `calibration_provenance`→null; `model`→"Hunting BDC (Generic)"; `notes` rewritten (generic non-linear BDC; advises consulting manufacturer table). scope_reticle_options.json (7 maps) unchanged per operator (closest archetype). | origin distribution now **22/21/9**; IP sweep clean |
| D-9b `loadout_combat` | corrected | center-dot element radius 0.18→**0.5** (dia 1.0 MOA = EOTech HWS published); `subtensions.centerDotSizeUnits` 0.36→**1.0**. `published_spec` + EOTech provenance retained. | dot now 1.0 MOA |
| D-9c `loadout_red_dot_circle` | re-cite only | `calibration_provenance.reticle_name` → "1-MOA dot + 68-MOA ring (**XPS3-2** reference)". No geometry change (catalog 2.0 MOA dot correct for XPS3-2). | string updated |
| D-9d `loadout_sfp_lpvo_chevron` | **HELD — clarification** | none | current `treeRowCount`=4 already; "add the 5th holdover mark" vs "4 hashes + chevron tip = 5 reference points" is ambiguous against actual data, and the catalog uses abstract `bdc` units with no meter-range field. Precise question raised to operator; not guessed. |
| D-9e `loadout_combat_bdc` | corrected type | `type` `ffp`→**`fixed`** (Burris AR-332 = fixed 3×; `sfp` would imply a 2nd focal plane that doesn't exist on a fixed-mag optic). | type=fixed |
| D-9f EOTech trio | corrected strings (+1 geometry) | provenance "65 MOA"→"**68 MOA**"; "segmented ring"→"**solid ring**" (552). **Ring-geometry verification (operator-required):** `loadout_holographic_ring` ring was a literal 65-MOA dia (perimeter r=32.5) → **geometry corrected**: 68 ring dots scaled r 32.5→**34.0** (= 68 MOA dia). `loadout_combat` (~6 MOA CQB dot-ring) and `loadout_red_dot_circle` (32 MOA ring; D-9c "no geometry") are **not literal 65-MOA rings** → string-only fix; documented per §30 "calibrated to, not a reproduction." | ring max r=34.0 ✓ |

**Verified-after (commands):** `jq length` = 52 (field-level edits,
no row add/del) · `subtension_origin` = **original 22 /
public_domain 21 / published_spec 9** (D-9a moved one
published_spec→original, as operator predicted) · IP sweep
(word-boundary, id+model+family) = **0 manufacturer trade names**
(provenance trade names remain internal-only per §30 rule 6;
`ReticleV2Row` does not project `calibration_provenance`) ·
5-test reticle gate (`reticle_library`, `reticle_disclaimer_templates`,
`reticle_lod`, `reticle_mapping_top35`, `seed_data_schema_invariants`)
= **157/157 PASS**.

**Residual items for V6.12 codification (surfaced, NOT silently
edited — per "no edits without explicit per-row authorization"):**

1. **D-9c wording:** after the authorized substring edits the string
   reads "**1-MOA** dot + 68-MOA ring (XPS3-2 reference)", but
   XPS3-2 is a **2-MOA** dot (catalog geometry 2.0 is correct). The
   "1-MOA" token was outside the authorized substitutions
   ("XPS3-0"→"XPS3-2", "65"→"68"). Recommend a V6.12 follow-up
   substring fix "1-MOA dot"→"2-MOA dot" for this row's provenance.
2. **D-9d:** held — see clarification question in the Group D report.
3. **`loadout_combat` provenance vs geometry:** after the 65→68
   string fix, the row's rendered ring is a ~6 MOA CQB dot-ring
   (not an EOTech 68-MOA ring). Consistent with §30 "calibrated to,
   not a reproduction," but the operator may wish to review whether
   the EOTech HWS provenance is the right reference for a CQB
   pattern (analogous to the D-9a re-tag decision).

**Disposition vocabulary final:** D-9a `accepted` (re-tag) · D-9b
`corrected_to_manufacturer` · D-9c `accepted` (re-cite) · D-9d
`pending_operator_decision` · D-9e `corrected_to_manufacturer` ·
D-9f `corrected_to_manufacturer` (string + 1 geometry).
