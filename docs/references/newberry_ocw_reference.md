# Newberry Optimal Charge Weight (OCW) — BFP Phase 29 Reference

**Method designer**: Dan Newberry
**Canonical URL**: `https://www.ocwreloading.com/` (now redirects to BangSteel.com); methodology pages still accessible
**Trademark / IP notice (verbatim)**: *"'Optimal Charge Weight' and the acronym OCW as regards the reloading of metallic firearm cartridges are the intellectual property of Dan Newberry. If using these terms in your own writings, please refer your readers to this webpage for concept clarification."*

## IP Posture for LoadOut Audit Chain

| What we use | Status |
|---|---|
| The general procedure (charge increments, round-robin sequence, group analysis) | ✅ Public methodology, taught widely, factual procedure |
| The terms "Optimal Charge Weight" and "OCW" | ⚠️ Trademarked. Link back to ocwreloading.com per Newberry's request. |
| Newberry's specific prose | ❌ Don't reproduce verbatim. Paraphrase and cite. |
| Targets and diagrams | ❌ Don't redistribute his target designs. |

## The OCW Method — Core Procedure

**Goal**: Find a "resilient" powder charge — one whose POI doesn't shift dramatically with small variations in charge weight, primer hotness, neck tension, etc. The theory is that the bullet exits the muzzle at the most-stable point in the barrel's vibration cycle, making the load tolerant to small input variations.

**Steps** (paraphrased from publicly-documented procedure):

1. **Determine starting and max charges** from at least 3 published sources (e.g., Hodgdon, Sierra, Hornady manuals — citing them as references, not redistributing).
2. **Calculate test increments**: 2% of max charge for standard cartridges, 3% for magnums. Some refinements suggest 0.7-1.0% increments for finer resolution.
3. **Build test charges**: Start at 7-10% below max, step up in increments to ~1% above max (with proper safety margins).
4. **Load 3 cartridges per charge level**.
5. **Fire in round-robin sequence**: One shot at each charge level in rotation, repeating until all 3 shots per charge are fired. This averages out shooter variation and barrel temperature effects across charge levels.
6. **Analyze targets**: Look for 3 consecutive charge levels whose groups land at the same point of impact (POI). This is the "OCW node" or "accuracy node."
7. **Select OCW**: Choose the **center charge** of the 3-consecutive-same-POI string.
8. **Optional seating depth tuning** in 0.005"-0.010" increments after OCW is found.

## Scatter Nodes

A key OCW concept: "scatter nodes" appear ~1.5% away from OCW nodes on the charge weight continuum. At a scatter node, group dispersion increases significantly. Newberry's theory: scatter nodes correspond to bullet exit at the worst point in the barrel's vibration cycle.

For LoadOut implementation: charge weight predictions should flag scatter-node regions (±1.5% from identified accuracy nodes) as zones to avoid.

## Theoretical Foundation: Chris Long's Optimum Barrel Time (OBT)

Closely related framework: Chris Long's OBT theory provides the physics-based foundation for OCW.
- Source: Chris Long published on his website (now archived at various locations)
- Theory: Barrel longitudinal shockwave reflects from muzzle. Optimal bullet exit timing corresponds to nodes where muzzle vibration velocity is minimized.
- Formulas: OBT times are computed from barrel length and steel wave speed.

**OBT is a separate methodology** related to (but distinct from) OCW. Both can be cited for the physics underlying barrel-time-based load development. For LoadOut: if the app supports barrel-time computation, OBT is the canonical primary source.

## Phase 29 Verification Targets

For BFP audit, LoadOut's OCW workflow should verify:

| Field | Newberry's specification | LoadOut should match |
|---|---|---|
| Charge increment (standard cartridge) | 2.0% of max charge | ✅ Verify in code |
| Charge increment (magnum cartridge) | 3.0% of max charge | ✅ Verify in code |
| Charge range start | Max minus 7-10% | ✅ Verify lower bound |
| Charge range end | Max plus ~1% (with safety margin) | ✅ Verify upper bound + safety logic |
| Group analysis criterion | 3 consecutive same-POI groups | ✅ Verify algorithm |
| OCW selection | Center of the 3-consecutive string | ✅ Verify selection logic |
| Scatter node distance | 1.5% from OCW node | ✅ Verify warning/avoidance logic |
| Round-robin firing | Fire in rotation, not sequentially | ✅ Verify UI workflow |
| Attribution | Method credited to Dan Newberry, link to ocwreloading.com | ✅ Verify in app UI/docs |

## Critical Limitations of OCW (documented by Newberry and others)

These should be reflected in LoadOut's UX/documentation:

1. **Shooter error**: OCW assumes consistent shooter execution. The round-robin method helps but doesn't eliminate human variability.
2. **Barrel condition**: Requires barrel in good condition. Worn throats or fouled bores invalidate results.
3. **Cold-clean-bore shift**: First shot from a cold/clean barrel may not match warm-bore groups. Some shooters fire foulers separately.
4. **Pressure signs trump theory**: If pressure signs appear at any charge in the test, abort regardless of group quality.

## Phase 29 Source Authoritativeness

Cite (in order of authoritativeness):

1. **ocwreloading.com / BangSteel.com** — Newberry's canonical site (note: ocwreloading.com redirects to BangSteel.com as of 2025+, but technical content still hosted)
2. **PrecisionRifleBlog.com** — `https://precisionrifleblog.com/2012/10/19/7mm-rem-mag-load-dev-part-3-optimal-charge-weight/` — well-known secondary writeup
3. **Forum reproductions** — Sniper's Hide, AccurateShooter, etc. — for cross-verification of the procedure description

For LoadOut, the cleanest citation chain:
- Primary: Newberry, D. *Optimal Charge Weight Load Development*. ocwreloading.com / BangSteel.com
- Secondary: PrecisionRifleBlog OCW coverage (Cal, 2012)
- Theoretical foundation: Long, C. *Optimum Barrel Time*. (Phase 29 may want to surface this as a separate reference if LoadOut implements OBT calculations.)

## Outstanding for Phase 29 Build

When LoadOut's actual Phase 29 implementation is audited:
- Verify the OCW workflow respects Newberry's documented procedure
- Verify proper attribution in the app (Newberry's trademark request)
- Verify scatter node warning logic
- Verify Chris Long OBT cross-reference if OBT calculations are implemented
- Check that the workflow doesn't redistribute Newberry's prose or target designs

## Status

✅ Phase 29 source identified and methodology captured for audit chain
⏳ Pending: Chris Long OBT source location (separate search if Phase 29 implementation requires)
