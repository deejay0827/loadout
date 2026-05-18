# Satterlee 10-Shot Method — BFP Phase 31 Reference

**Method designer**: Scott Satterlee, prominent long-range / PRS competitor
**Also known as**: 10 Round Load Development Ladder Test, Satterlee Method, Velocity Flat-Spot Method
**Canonical primary source**: The 6.5 Guys interview with Scott Satterlee, `http://www.65guys.com/10-round-load-development-ladder-test/`

## Source Authoritativeness

| Source | Status |
|---|---|
| 6.5 Guys article + video with direct Satterlee quotes | ✅ Primary, public, attributed |
| Scott Satterlee's own social/training presence | Various Sniper's Hide, Modern Day Sniper, Reddit r/longrange posts; no consolidated authoritative page |
| Critical analyses (Sniper's Hide, AccurateShooter) | ✅ Secondary, useful for understanding limitations |

## IP Posture

The method has been published publicly with Satterlee's direct collaboration via 6.5 Guys. The procedure itself is well-documented common knowledge. Direct quotes from Satterlee can be paraphrased; the 6.5 Guys article itself shouldn't be redistributed wholesale.

## The 10-Shot Method — Core Procedure

**Goal**: Identify a "velocity flat spot" — a narrow charge range where consecutive powder charges produce nearly identical velocities. The theory is that a velocity flat spot corresponds to an internal-ballistics node where the relationship between charge and velocity briefly plateaus (typically due to combustion efficiency / barrel time / harmonic effects), and that this corresponds to an accuracy node.

**Steps** (paraphrased from Satterlee's documented procedure):

1. **Determine max charge** from published reloading manuals (which are referenced, not redistributed).
2. **Calculate start charge**: 1.5 grains below max.
3. **Build 10 cartridges** in 0.2 grain increments. Example for a cartridge with max ~52.0 gr: 50.0, 50.2, 50.4, 50.6, 50.8, 51.0, 51.2, 51.4, 51.6, 51.8 (or extend to 52.0).
4. **Fire over a chronograph** — Satterlee specifically recommends Magnetospeed for muzzle-velocity accuracy; modern Labradar also acceptable.
5. **Look for velocity flat spots** — consecutive 2-4 charges where velocity changes <10-15 fps despite 0.4-0.8 gr of additional powder.
6. **Identify center of flat spot** as candidate accuracy node.
7. **Verify by loading 5 cartridges** at the center charge and re-firing for SD. Target ES <10 fps; ideally <5 fps.

## Satterlee's Theoretical Position (paraphrased from interviews)

Satterlee's stated view is that the underlying mechanism is **velocity-based**, not charge-based:
- Different powders can produce the same accuracy if they produce the same MV with the same bullet
- The "node" is really an optimal-velocity zone for the bullet/cartridge/barrel combination
- Implication: once a flat-spot is found in one powder, the same MV with a different powder should also be accurate

This is a meaningful theoretical claim. It aligns with the "Optimum Barrel Time" framing (Chris Long) — barrel time is determined by MV and barrel length, not by charge weight directly.

## Phase 31 Verification Targets

For BFP audit, LoadOut's Satterlee workflow should verify:

| Field | Satterlee's specification | LoadOut should match |
|---|---|---|
| Total rounds | 10 (one per charge) | ✅ Verify in code |
| Charge increment | 0.2 gr | ✅ Verify (consider scaling with case size — Satterlee's spec is fixed 0.2 gr) |
| Range start | Max minus 1.5 gr | ✅ Verify |
| Range span | 1.8 grain spread (10 × 0.2 gr) | ✅ Verify |
| Required equipment | Chronograph (Magnetospeed or Labradar preferred) | ✅ Verify in app — UI should require MV capture |
| Flat-spot detection | 2-4 consecutive charges with <15 fps spread | ✅ Verify algorithm |
| Selection | Center of flat-spot range | ✅ Verify selection logic |
| Verification step | 5 rounds at center charge, ES <10 fps target | ✅ Verify follow-on workflow exists |
| Attribution | Credit Satterlee; link to 6.5 Guys source | ✅ Verify in app UI/docs |

## CRITICAL Limitations — Phase 31 MUST Surface These

This is the most statistically controversial of the load development methods LoadOut supports. The BFP audit chain should ensure LoadOut presents these limitations honestly:

1. **Sample size = 1 per charge**: A 10-shot ladder with 1 shot per charge has no within-charge variance estimate. Random shot-to-shot velocity noise (typically 10-25 fps SD even with good ammunition) can produce false flat spots.

2. **Non-replicability**: Multiple shooters have documented that running 5 identical 10-shot ladders produces 5 different flat-spot locations. (Sniper's Hide and AccurateShooter forum analyses with paired data.)

3. **Statistical critique**: From a strict-stats perspective, n=1 per charge cannot distinguish a true flat spot from random noise. The flat spot needs to be 2+ standard deviations larger than expected noise to be statistically meaningful — which often requires sample sizes of 5+ per charge (i.e., the OCW or multi-shot approach).

4. **Satterlee's own evolution**: Forum discussions note that Satterlee himself reportedly no longer teaches this method in its original 1-shot-per-charge form, having moved toward multi-shot verification.

5. **Most useful when**: 
   - Cartridge/powder combinations where load data is sparse and pressure-ladder behavior is unknown — Satterlee's method then doubles as a pressure-finding test
   - Confirming a velocity target rather than discovering a node from scratch
   - Combined with OCW or Audette ladder as complementary methods (not as sole load development)

6. **Least useful when**:
   - Small charge increments (0.1 gr) — overlapping velocity noise makes signal undetectable
   - Powders with non-monotonic charge-velocity behavior near book max
   - Cold/hot barrel effects mask the signal (the first few shots of a cold/clean barrel often show faster-than-average MV trend that creates spurious flat spots)

## LoadOut UX Recommendations (for Phase 31 implementation)

Given the statistical weakness of the method, the audit chain should ensure LoadOut:

1. **Doesn't oversell the method**. UI should be clear: "candidate node from 10-shot ladder" not "optimal load identified."
2. **Always recommends the 5-shot verification step**. Skipping verification turns a candidate flat spot into a guess.
3. **Warns about flyer sensitivity**. A single bad shot at any charge level can fabricate or destroy a flat spot.
4. **Suggests combining with paper-group methods** (OCW or Audette) for higher-confidence load selection.
5. **Documents the n=1 limitation** somewhere accessible.
6. **Doesn't make the velocity flat spot the only signal** — if MV data is captured, also flag the SD at the center charge as the real quality measure.

## Status

✅ Phase 31 source identified and methodology captured for audit chain
✅ Critical statistical limitations documented for safety/honesty in UX
⚠️ Phase 31 implementation should be more cautious in its UX than for OCW (Phase 29) or Audette (Phase 30) because of the statistical weakness
