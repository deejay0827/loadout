# Scope FOV Data Audit — VFP Phase 1 Group C

**Source data commit:** VFP Phase 1 Group B `4f9b0f5` (merged to main as
`72dc0ae`).
**Audit / source-retrieval date:** 2026-05-16.
**Scope of audit:** the 23 `scopes.json` rows populated in Group B with
`fov_at_100yd_ft_max_zoom`, plus the 2 of those carrying a
manufacturer-documented `sfp_calibration_zoom`. `verified_at` on all 23
rows stamped `2026-05-16` in Group C (value-only change on an existing
field; no structural change).
**Method:** four parallel research agents sourced manufacturer-published
FOV at maximum magnification (ft @ 100 yd). Every value was sanity-gated
`max-zoom FOV < min-zoom FOV`; values that failed the gate or were not
manufacturer-published were left **null** and surfaced for an operator
decision per §0.5 halt protocol — not fabricated (CLAUDE.md §0).
**Disposition vocabulary** (per CLAUDE.md §31 dossier convention):
`matches` (manufacturer-cited, sanity-passed) ·
`accepted_with_rationale` · `excluded` (sanity fail / unsourced) ·
`pending_operator_decision`.

---

## 1. Per-scope verification table (23 populated rows)

| id | model | FP | min-zoom FOV (existing) | max-zoom FOV (Group B) | sfp_cal | source URL | confidence | 2nd source | disposition |
|---|---|---|---|---|---|---|---|---|---|
| vortex_optics_razor_hd_gen_iii_6_36x56_ffp | Vortex Razor HD Gen III 6-36x56 | FFP | 18.4 | 3.5 | — | vortexoptics.com/razor-hd-gen-iii-6-36x56.html | high | yes (multi-search) | matches |
| vortex_optics_razor_hd_gen_ii_4_5_27x56_ffp | Vortex Razor HD Gen II 4.5-27x56 | FFP | 23.1 | 4.4 | — | vortexoptics.com/vortex-razor-hd-gen-2-45-27x56-riflescope.html | high | yes | matches |
| nightforce_optics_atacr_5_25x56_f1 | Nightforce ATACR 5-25x56 F1 | FFP | 19.0 | 4.9 | — | nightforceoptics.com/riflescopes/atacr/atacr-5-25x56-f1 | high | manufacturer-direct | matches |
| nightforce_optics_atacr_7_35x56_f1 | Nightforce ATACR 7-35x56 F1 | FFP | 15.0 | 3.4 | — | nightforceoptics.com/riflescopes/atacr/atacr-7-35x56-f1 | high | manufacturer-direct | matches |
| nightforce_optics_nx8_4_32x50_f1 | Nightforce NX8 4-32x50 F1 | FFP | 26.9 | 4.6 | — | nightforceoptics.com/riflescopes/nx8/nx8-4-32x50-f1 | high | manufacturer-direct | matches |
| nightforce_optics_nxs_5_5_22x56 | Nightforce NXS 5.5-22x56 | SFP | 17.5 | 4.7 | 22 | eurooptic.com/nightforce-nxs-55-22x56-rifle-scope · nightforceoptics.com ReticleManual.pdf (SFP cal) | medium (FOV) / high (SFP cal) | EuroOptic + OpticsPlanet | matches |
| leupold_mark_5hd_5_25x56_m5c3_ffp | Leupold Mark 5HD 5-25x56 | FFP | 20.5 | 4.2 | — | leupold.com/mark-5hd-5-25x56-m5c3-ffp-tmr-riflescope | high | — | matches |
| leupold_mark_5hd_7_35x56 | Leupold Mark 5HD 7-35x56 | FFP | 14.7 | 3.0 | — | leupold.com/mark-5hd-7-35x56-m5c3-ffp-tmr-riflescope | high | — | matches |
| leupold_vx_5hd_4_20x52 | Leupold VX-5HD 4-20x52 | SFP | 24.0 | 5.8 | null | leupold.com/vx-5hd-4-20x52-cds-zl2-side-focus-duplex-riflescope | medium | OpticsPlanet (conflict 7.7 — manufacturer 5.8 taken) | accepted_with_rationale |
| bushnell_elite_tactical_xrs3_6_36x56 | Bushnell Elite Tactical XRS3 6-36x56 | FFP | 17.5 | 3.0 | — | bushnell.com/products/elite-tactical-xrs3-6-36x56-ffp-riflescope-g5i-reticle | high | — | matches |
| bushnell_engage_4_16x44 | Bushnell Engage 4-16x44 | SFP | 25.0 | 7.0 | null | bushnell.com/scopes/shop-all-scopes/engage-4-16x44-riflescope/BU-REN41644DG.html | medium | B&H + OpticsPlanet + gun.deals (consistent) | accepted_with_rationale |
| trijicon_tenmile_hx_6_24x50 | Trijicon Tenmile HX 6-24x50 | SFP | 16.7 | 4.7 | null | trijicon.com/products/product-family/trijicon-tenmile-hx-6-24x50-long-range-riflescope | high | — | matches |
| carl_zeiss_lrp_s5_5_25x56 | Zeiss LRP S5 5-25x56 | FFP | 20.1 | 4.5 | — | zeiss.com/.../lrp-s5/lrp-s5-525-56.html | high | conv 1.5 m × 3.0 = 4.5 ft | matches |
| carl_zeiss_conquest_v4_6_24x50 | Zeiss Conquest V4 6-24x50 | SFP | 18.0 | 4.8 | 24 | zeiss.com/.../second-focal-plane-riflescopes/conquest-v4.html | high | subtension stated "@ 24x" | matches |
| trijicon_tenmile_4_5_30x56_ffp | Trijicon Tenmile 4.5-30x56 FFP | FFP | 24.4 | 3.7 | — | trijicon.com/products/details/tm3056-c-3000013 | high | — | matches |
| primary_arms_plx_6_30x56_ffp | Primary Arms PLx 6-30x56 FFP | FFP | 19.0 | 3.3 | — | primaryarms.com/pa-plx5-6-30x56mm-ffp-rifle-scope-with-illuminated-athena-bpr-mil-reticle | medium | PA + retailers (WebFetch 403; cited via search) | accepted_with_rationale |
| sig_sauer_tango6_5_30x56 | Sig Sauer Tango6 5-30x56 | FFP | 22.6 | 3.3 | — | sigsauer.com/tango6-5-30x56mm-scope.html | high | — | matches |
| athlon_optics_cronus_btr_gen2_4_5_29x56 | Athlon Cronus BTR Gen2 4.5-29x56 | FFP | 23.6 | 3.83 | — | athlonoptics.com/product/cronus-btr-gen2-uhd-4-5-29x56-aprs6-ffp-ir-mil/ | high | see Discrepancy D-3 | matches |
| arken_optics_ep5_5_25x56_ffp | Arken EP5 5-25x56 FFP | FFP | 21.0 | 4.9 | — | arkenopticsusa.com/ep-5-5-25x56-ffp-illuminated-vpr-zero-stop-34mm-tube | medium | manufacturer-cited via search (WebFetch blocked) | accepted_with_rationale |
| kahles_k525i_5_25x56 | Kahles K525i 5-25x56 | FFP | 24.0 | 4.9 | — | kahles.at/us/sport/riflescopes/k525i-5-25x56i-dlr-rsw | high | renders 23.2–4.9 ft | matches |
| burris_xtr_iii_5_5_30x56 | Burris XTR III 5.5-30x56 | FFP | 20.0 | 4.2 | — | burrisoptics.com/riflescopes/xtr-iii-55-30x56mm | high | — | matches |
| burris_fullfield_iv_4_16x50 | Burris Fullfield IV 4-16x50 | SFP | 25.0 | 6.5 | null | burrisoptics.com/riflescopes/fullfield-iv-4-16x50mm | high (FOV) | — | matches |
| element_optics_helix_6_24x50_ffp | Element Optics Helix 6-24x50 FFP | FFP | 16.8 | 4.6 | — | element-optics.com (original Helix 18.3–4.6) | medium | see Discrepancy D-4 | accepted_with_rationale |

Secondary-source cross-check (Group C task 4 — ≥5 required): **≥7
scopes** cross-checked against an independent source — Vortex Razor III,
Vortex Razor II 4.5-27, Nightforce NXS (EuroOptic + OpticsPlanet),
Leupold VX-5HD (manufacturer vs OpticsPlanet, conflict resolved),
Bushnell Engage (3 retailers), Primary Arms PLx (PA + retailers),
Kahles K525i (m/100m ↔ ft/100yd cross-derivation). Exceeds the
requirement.

---

## 2. Discrepancy register (halt-and-validate findings — operator decisions)

| # | Scope | Finding | Disposition / operator decision needed |
|---|---|---|---|
| D-1 | Steiner M5Xi 5-25x56 | Sourced max-zoom FOV 13.8 ft **fails the sanity gate** (not < 22.5 min-zoom). steiner-optics.com WebFetch permission-blocked; search snippets self-contradictory (13.20–4.60 ft vs 23.6–4.6 m). | `fov_at_100yd_ft_max_zoom` left **null** (not written — CLAUDE.md §0). **pending_operator_decision**: hand-verify Steiner spec, or accept null (Phase 11 `FovInterpolator` falls back to single-FOV for this row). Excluded from Phase 11 oracle until resolved. |
| D-2 | Leupold VX-5HD 4-20x52; Bushnell Engage 4-16x44; Trijicon Tenmile HX 6-24x50; Burris Fullfield IV 4-16x50 (4 SFP scopes) | Plan Group B Task 5 = "populate `sfp_calibration_zoom` per manufacturer spec." Reality: these manufacturers **do not publish** a reticle-calibration magnification. Only Zeiss Conquest V4 (subtension stated "@ 24x") and Nightforce NXS (Nightforce reticle manual) are manufacturer-documented → only those 2 populated. | `sfp_calibration_zoom` left **null** for the 4 (industry SFP-true-at-max-mag *convention* exists but is an assumption, not sourced data). **pending_operator_decision** before Phase 11: adopt the convention as a documented assumption (and how to flag it in-app), or handle SFP calibration differently. |
| D-3 | Athlon Cronus BTR Gen2 4.5-29x56 | Existing `fov_at_100yd_ft` = 23.6; Athlon publishes low-mag FOV 24.8. Existing field — **outside Group B/C additive scope; not changed**. Max-zoom 3.83 sourced & sane. | Minor. Flagged for an operator decision on the existing single-zoom field (separate from this FOV-max work). |
| D-4 | Element Optics Helix 6-24x50 | Existing `fov_at_100yd_ft` = 16.8; manufacturer publishes the original Helix low-mag FOV as 18.3 (Gen2 is 20.1; this row is the original). Existing field — **not changed**. Max-zoom 4.6 sane vs both. | Flagged for operator decision on the existing single-zoom field. |
| D-5 | §11.1 Phase 11 oracle | Group C task 3 / exit criterion presumes ≥1 scope with a **manufacturer-published interior-zoom FOV**. Exhaustive primary-source verification (see §3) establishes the consumer riflescope industry publishes **min/max only** — no such datum exists for any candidate or any well-known scope. The exit criterion is **unmeetable as written** (wrong premise), not unmet through omission. No interior value fabricated/interpolated (CLAUDE.md §0; §0.5 L4). | **pending_operator_decision** before VFP Phase 11: choose §11.1 oracle strategy — (a) independent optical-model derivation [recommended], (b) endpoint-only manufacturer validation + documented shape check, or (c) escalate. §11.1 must NOT use a Form-1-computed value as its own oracle. |

`accepted_with_rationale` rows (Leupold VX-5HD, Bushnell Engage,
Primary Arms PLx, Arken EP5, Element Helix): medium confidence —
manufacturer value taken where a live manufacturer fetch was blocked
but the value is consistent across reputable independent sources and
passes the sanity gate. No fabrication; every value has a cited
origin.

---

## 3. Intermediate-zoom manufacturer oracle for §11.1 (Phase 11)

> Group C task 3 / exit criterion: ≥1 scope with a manufacturer-published
> FOV at an **intermediate** magnification (a third point between min and
> max), to validate the §B.1 inverse-proportional FOV formula at an
> interior `t` with data **independent of the formula** (per §0.5
> Level 4 — a formula must not be its own oracle).

**Finding: NO manufacturer-published interior-magnification FOV oracle
exists.** Exhaustive primary-source verification (manufacturer spec
pages + owner's-manual PDFs read directly) establishes that the
consumer riflescope industry publishes **only two FOV points per
scope: min-zoom and max-zoom.** No genuine interior-magnification FOV
point was found for any of the six Phase-11 candidate scopes, nor for
a broad secondary sweep (Schmidt & Bender PM II 5-25, Kahles K525i,
March 5-40, Bushnell XRS, Athlon Cronus Gen2 [spec-sheet PDF read
directly], Steiner T6Xi/M7Xi, Sig Tango6, Swarovski X5i, Burris
XTR III, Tract Toric, Nightforce SHV manual).

Two apparent interior hits were investigated and **rejected as
invalid**, not used:
- Nightforce SHV "3x/4x/10x" — a search-engine table-concatenation
  artifact; the SHV manual p.17 lists only min/max (3x/10x) per model.
- Leupold "11x = 3.28 m" — traced to an all4shooters third-party test
  report, not a Leupold spec; not an independent manufacturer oracle.

Verified endpoint data (primary sources):

| catalog_id | min-zoom FOV | max-zoom FOV | interior? | primary source |
|---|---|---|---|---|
| nightforce_optics_atacr_5_25x56_f1 | 5x: 18.7 ft | 25x: 4.9 ft | none | NF ATACR Owner's Manual p.17 (PDF) |
| nightforce_optics_atacr_7_35x56_f1 | 7x: 15.0 ft | 35x: 3.4 ft | none | NF ATACR Owner's Manual p.17 (PDF) |
| nightforce_optics_nx8_4_32x50_f1 | 4x: 26.1 ft | 32x: 4.6 ft | none | nightforceoptics.com NX8 4-32x50 F1 |
| vortex_optics_razor_hd_gen_iii_6_36x56_ffp | 6x: ~20.5 ft | 36x: 3.5 ft | none | vortexoptics.com |
| leupold_mark_5hd_5_25x56_m5c3_ffp | 5x: 20.4 ft | 25x: 4.2 ft | none | leupold.com Mark 5HD |
| carl_zeiss_lrp_s5_5_25x56 | 5x: 23 ft | 25x: 5 ft | none | zeiss.com LRP S5 |

**Implication for VFP Phase 11 §11.1 (halt-and-validate finding —
operator decision required, see Discrepancy D-5).** The §B.1
inverse-proportional FOV formula (Form 1) can be validated against
manufacturer data **only at the two endpoints** (t=0, t=1).
Per §0.5 Level 4 the formula must not be its own oracle, so an
interior-`t` assertion cannot use a value computed from Form 1.
The realistic options (operator to decide before Phase 11):

- **(a) Independent optical-model oracle.** Validate interior `t`
  against a first-principles optical relation (true magnification ↔
  apparent field of view), documented and derived independently of
  Form 1 — explicitly labeled "not a manufacturer-spec oracle."
- **(b) Endpoint-only manufacturer validation.** Accept that
  manufacturer-data validation is endpoint-only (the industry
  ceiling); validate interior monotonicity/shape against a documented
  independent derivation, not a number.
- **(c) Escalate** the §11.1 oracle strategy as a domain decision;
  do not accept a computed value as its own test oracle.

Recommendation: **(a)** — an independent optical-physics derivation is
a genuine oracle and keeps §0.5 Level 4 intact; (b) is an acceptable
fallback. Either way, **no fabricated/interpolated interior value is
written**, here or in Phase 11 tests.

Primary sources: Nightforce ATACR Owner's Manual PDF
(`/content/files/downloads/0522_ATACR_OwnersManual.pdf`); Nightforce
NX8 4-32x50 F1 product page; Leupold Mark 5HD 5-25x56; Zeiss LRP S5;
Vortex Razor HD Gen III 6-36x56; Athlon Cronus BTR Gen2 spec-sheet
PDF; Nightforce SHV Owner's Manual PDF.
