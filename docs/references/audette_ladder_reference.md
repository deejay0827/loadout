# Audette Ladder Test / Incremental Load Development Method — BFP Phase 30 Reference

**Method designer**: Creighton Oliver Audette (1920-1994), American gunsmith
**Also known as**: Incremental Load Development Method (ILDM), Sweet Spot Method, 20-Round String Method, Ladder Test, "the Ladder"

## Source Authoritativeness

| Source | Type | Status |
|---|---|---|
| Audette, C. *"It Ain't Necessarily So"* in NRA's *National Championship Training Clinics Manual*, "Highpower Rifle Shooting, Volume III" | Original primary | In print (NRA reprint program); copyrighted by NRA |
| Audette articles in *Precision Shooting* magazine | Original primary | Magazine defunct, articles archived in *Precision Shooting Reloading Guide* anthology |
| *Precision Shooting Reloading Guide* | Anthology including Audette material | Out of print; copyrighted |
| PrecisionRifleBlog.com (Cal's coverage) | Authoritative secondary | Public web |
| Long Range Hunting forum archives | Secondary | Public web |

## IP Posture

Audette died in 1994. His articles are copyrighted by their original publishers (NRA, Precision Shooting). The basic ladder methodology, however, is now widely-documented and taught across the precision shooting community as common knowledge — similar status to "the lottery is a probability game" being well-known despite specific textbook treatments being copyrighted.

For LoadOut's audit chain:
- ✅ Cite Audette as method originator with original publication reference
- ✅ Describe procedure in our own words (paraphrase)
- ❌ Don't reproduce Audette's original prose verbatim
- ❌ Don't redistribute the NRA manual or Precision Shooting articles

## The Ladder Test — Core Procedure

**Goal**: Identify the "sweet spot" charge weight where small variations in powder charge cause minimal vertical shift on target — i.e., where the barrel's harmonic motion is briefly stationary at bullet exit, producing tolerance to charge variation.

**Steps** (paraphrased from publicly-documented procedure):

1. **Select components**: bullet, primer, powder, case. Lock these in.
2. **Determine charge range**: Start load to maximum load (per published manuals — manuals are referenced, not redistributed).
3. **Determine increment**: Based on case capacity. Common values:
   - Small cases (e.g., .223, .222): 0.1-0.2 gr increments
   - Medium cases (e.g., .308, .30-06, 6.5 Creedmoor): 0.2-0.3 gr increments
   - Magnum cases (e.g., .300 Win Mag, .338 Lapua): 0.3-0.5 gr increments
4. **Load one round at each charge weight**. Typical test uses 20 rounds (the "20-round string"), each a different charge.
5. **Fire at long distance** — Audette specified 300 yards. The reason: at longer range, the vertical dispersion due to MV differences is amplified, making the harmonic "nodes" more visible. At 100 yards, MV-induced vertical differences are typically smaller than group dispersion.
6. **All shots at the same aim point** on a single tall target.
7. **Number each shot** in the target on hit by charge weight (so you can identify which hole came from which charge).
8. **Analyze the vertical impact pattern**: Look for **consecutive shots that group vertically close together** — these define a "node" or "sweet spot." Outside the node, vertical impact moves quickly with charge weight; inside the node, vertical impact is stationary.
9. **Choose center of the sweet-spot cluster** as the working load.

## Critical Differences vs OCW (Newberry)

| Aspect | Audette Ladder | Newberry OCW |
|---|---|---|
| Rounds per charge | **1** (single shot) | 3 (group) |
| Total rounds | ~20 | ~15-18 (3 × 5-6 charges) |
| Firing pattern | Sequential (low to high charge) | Round-robin |
| Distance | 300 yards (long) | 100 yards |
| Analysis target | Vertical position on single target | POI consistency across multiple targets |
| Decision criterion | Vertical clustering of successive shots | 3 consecutive same-POI groups |
| Sensitive to | Pure harmonic node identification | Combined harmonic + practical variability |

Both methods are valid. OCW is often preferred for hunting loads (round-robin reduces shooter error and tests resilience). Audette is often preferred for benchrest / F-class precision (single-shot maximizes signal-to-noise for harmonic identification).

## Phase 30 Verification Targets

For BFP audit, LoadOut's ladder workflow should verify:

| Field | Audette's specification | LoadOut should match |
|---|---|---|
| Round count | ~20 single shots | ✅ Verify in code |
| Increment by case capacity | 0.1-0.5 gr based on case size | ✅ Verify increment scaling |
| Distance | 300 yards minimum (NOT 100) | ✅ Verify range guidance |
| Aim point | Same for all shots | ✅ Verify aim-point handling |
| Shot identification | Each hit attributable to a specific charge | ✅ Verify target marking workflow |
| Analysis | Vertical clustering of successive shots | ✅ Verify cluster-detection algorithm |
| Output | Sweet-spot charge range; center charge | ✅ Verify selection logic |
| Attribution | Credit Audette as method originator | ✅ Verify in app UI/docs |

## Critical Limitations of Ladder Test (documented widely)

These should be reflected in LoadOut's UX/documentation:

1. **Single-shot dispersion**: With only one shot per charge, individual shot variance is full noise. A flier from poor execution will be indistinguishable from a true harmonic shift.
2. **Wind sensitivity**: At 300 yards, wind drift can mask vertical signal. Test in calm conditions (Audette specifically recommends dawn or dusk).
3. **Shooter error**: Each shot is consequential. The method assumes consistent execution across 20 shots — a tall ask.
4. **Misidentification of nodes**: Some shooters identify "ghost nodes" from chance clustering. Verification with a second ladder test or OCW round-robin is recommended.
5. **Range required**: 300 yards minimum. Many shooters don't have access. Some attempt at 200 yards with degraded but workable signal; 100 yards generally insufficient.

## Velocity Tracking (Modern Enhancement)

Modern practice (post-Audette, since chronographs became cheap):
- Capture muzzle velocity for each round
- Look for **velocity flat-spots** — narrow charge ranges where MV doesn't change much with charge increment
- Velocity flat-spots often correlate with vertical-impact flat-spots (the sweet spot)
- A Labradar or MagnetoSpeed adds a second dimension of evidence to ladder analysis

This is a useful supplement but not part of Audette's original method. For LoadOut: if the app supports MV capture during ladder workflow, velocity-flat-spot detection is a useful Phase 30 feature.

## Status

✅ Phase 30 source identified and methodology captured for audit chain
✅ IP posture defensible (paraphrased methodology, original primary cited, NRA manual referenced not redistributed)
