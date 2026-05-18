# McCoy Reading Guide — Modern Exterior Ballistics

> **Purpose:** Navigation tool for Claude Code (the executor) when consuming McCoy's *Modern Exterior Ballistics: The Launch and Flight Dynamics of Symmetric Projectiles* during BFP Phase 5, 8, 9, 10, 11, and 12 execution.
>
> **This file is NOT a substitute for the McCoy source.** It tells the executor where to look in McCoy and what to verify; it does not contain McCoy's prose, example tables, or extended text. The owned-hardcover scan at `docs/references/mccoy_owned_scan.pdf` is the source of record. This guide is the index into it.
>
> **Edition referenced:** Schiffer Publishing, 2012 2nd ed reissue. ISBN-13 9780764338250. Pagination identical to the 1999 1st ed Schiffer Military History (which is in the file metadata as well — McCoy's preface is dated March 1998, the 2012 copyright is the reissue). Page numbers below match either edition.
>
> **Source-of-record file at execution time:** `docs/references/mccoy_owned_scan.pdf` containing pages 165–270 (Chapters 8 through 12). The scan is produced from the operator-owned legitimate hardcover.
>
> **Plan reference:** This guide implements the McCoy-consuming portions of the *Ballistics Fidelity Program Plan* (`docs/audit/BFP_PLAN.md` or wherever the current version lives). Phase numbering matches BFP V2+.

---

## Table of Contents

1. **Overview and reading philosophy**
2. **Mapping summary (phase ↔ McCoy section)**
3. **Per-phase reading guides:**
   - Phase 5 — Integrator Discipline
   - Phase 8 — Coordinate System + Sign Convention Sweep
   - Phase 9 — Miller Stability + Pejsa Alternate
   - Phase 10 — Spin Drift
   - Phase 11 — Aerodynamic Jump (closes audit C-1)
   - Phase 12 — Coriolis (horizontal + Eötvös)
   - Phase 13 — Cant × Crosswind Term (secondary McCoy consumption)
4. **By-chapter index**
5. **Hand-verification protocol** (carried from BFP §0.6)
6. **Sign convention reference card**
7. **Format expectations for the owned scan**

---

## 1. Overview and Reading Philosophy

### Why we read McCoy

McCoy 1999 is the canonical English-language reference for Modified Point-Mass ballistics. It is the work that the LoadOut solver's architecture is derived from. The audit chain therefore requires hand-verification of every load-bearing solver formula against McCoy's derivation.

LoadOut also implements Litz's empirical refinements (AJ formula, spin drift formula, Miller stability) on top of the McCoy MPM foundation. For those, McCoy provides the underlying physics; Litz provides the closed-form empirical expressions. Hand-verification therefore happens at two levels:

1. **Physics consistency** — McCoy's derivation tells us what the correction *means* and what variables it should depend on. This catches structural errors (e.g., the v1 audit's C-1 finding: the old AJ formula's `−0.087 · TOF · V` form was structurally wrong because TOF and V don't belong in the AJ formula — McCoy's derivation in §12.9 shows AJ is a fixed muzzle-time angular deflection, not an accumulating effect).
2. **Empirical formula transcription** — Litz's closed-form expressions are checked against their published source separately (Litz Applied Ballistics 4th ed, Modern Advancements Vols I/III). The two-source structure of the verification is intentional: McCoy alone doesn't give you the empirical coefficients; Litz alone doesn't give you the physical justification.

### What this guide does and doesn't do

| This guide does | This guide does not do |
|---|---|
| Tell the executor which McCoy section to read for each phase | Substitute for reading McCoy |
| Cite page numbers and section numbers | Quote McCoy's prose |
| List equations in their generic mathematical form (not copyrightable) | Reproduce McCoy's example tables, figures, or extended derivations |
| Cross-reference LoadOut code sites to the McCoy sections that audit them | Pre-judge what the verification will conclude |
| Provide hand-verification protocol per phase | Replace the BFP plan's §0.6 hand-verification discipline |

### Read in scan order, not phase order

The McCoy scan is contiguous pages 165–270. The executor reads it linearly when first orienting (one read-through) and then jumps to specific sections per phase. This guide is structured per-phase but the executor's first action should be: open the scan, read Ch. 8 § introduction (p. 165), skim Ch. 9 § introduction (p. 187), and Ch. 12 § introduction (p. 252), to build situational awareness before drilling into any specific verification.

---

## 2. Mapping Summary

| BFP Phase | McCoy Sections (primary) | McCoy Sections (cross-reference) | Other source(s) |
|---|---|---|---|
| Phase 5 (Integrator) | §8.4 Numerical Solution (p. 166); §9.4 Numerical Solution of 6-DOF (p. 193) | Ch. 9 generally for MPM context | Numerical Recipes (any edition) for step-independence theory |
| Phase 8 (Sign conventions) | §8.2 EoM (p. 165); §9.2 6-DOF EoM (p. 187); §8.8 Coriolis (p. 178) | Ch. 2 (forces and moments, p. 32–41) for force-direction conventions | LoadOut `solver.dart` self-doc (the six conventions) |
| Phase 9 (Miller stability) | §10.5 Classical Gyroscopic Stability Criterion (p. 230); §10.9 Gyroscopic and Dynamic Stability (p. 233) | §10.6 for context on yaw of repose | Miller, *Precision Shooting* March 2005 — the empirical formula |
| Phase 10 (Spin drift) | §10.6 Yaw of Repose (p. 231); §9.7 MPM model (p. 212) | Ch. 11 swerving motion (p. 240–251) for additional context | Litz, *Modern Advancements* Vol I — empirical spin drift formula |
| Phase 11 (AJ — closes C-1) | §12.9 AJ Due to Crosswind (p. 267); §12.4 Generalized AJ Effect (p. 259); §9.7 MPM model (p. 212) | Ch. 12 entire (p. 252–272) for full AJ context | Litz, *Applied Ballistics* 2nd ed pp 78–79 (or 4th ed equivalent) — empirical formula |
| Phase 12 (Coriolis) | §8.8 Coriolis Effect on Point-Mass Trajectories (p. 178–183) | None additional in McCoy | None — McCoy is the canonical reference for Coriolis in ballistics |
| Phase 13 (Cant × crosswind) | §12 (Lateral Throwoff and AJ chapter) for general context | §12.4 generalized AJ | Litz, *Modern Advancements* Vol III — primary source for the cant × crosswind angular term |

### Notes on phase consumption pattern

- **Phase 12 has the cleanest McCoy mapping** — Coriolis is a six-page treatment in §8.8 with explicit formulas and cardinal cases. Lowest verification overhead.
- **Phase 11 has the heaviest McCoy + Litz dual-source verification** — McCoy gives the physics, Litz gives the empirical formula, the two must be consistent. Highest verification overhead.
- **Phase 8 (sign conventions) is implicit in many sections** — every chapter that defines forces or coordinate frames is a candidate. The executor reads broadly here and produces a cardinal-direction map (per BFP plan §4.4).
- **Phase 5 (integrator) is partly outside McCoy** — McCoy describes the equations to integrate but the choice of integrator (RK4 vs Cash-Karp) is a numerical analysis question. McCoy informs the EoM; step-independence proof comes from numerical analysis literature.

---

## 3. Per-Phase Reading Guides

### Phase 5 — Integrator Discipline

**BFP plan reference:** §10.1 Phase 5 outline. Reconciles `Ballistics.md` (Cash-Karp RK45) vs `solver.dart` self-doc (classical RK4) drift.

**McCoy sections to read:**

- **§8.4 Numerical Solution of the Equations of Motion** (p. 166–169 approx). McCoy describes how the point-mass EoM are integrated numerically. Read for: which integrator family McCoy assumes/recommends, step-size considerations, what "equations of motion" means in this context (i.e., what state variables are being integrated).
- **§9.4 Numerical Solution of Six-Degrees-of-Freedom Trajectories** (p. 193–194). Read for: how 6-DOF integration differs from point-mass; what additional state variables (Euler angles, body rates) are integrated; step-size constraints when angular motion is included.
- **§9.7 The Modified Point-Mass Trajectory Model** (p. 212–214). Read for: how MPM integration relates to pure point-mass — what additional terms are integrated and whether they impose different step constraints.

**LoadOut code sites to verify against:**

- `lib/services/ballistics/solver.dart` — the main integration loop. Find the function that advances trajectory state from time t to t+dt. Identify:
  - The integrator family (RK4, Cash-Karp, or other)
  - The step-size policy (fixed step, adaptive, transonic-refined)
  - The error tolerance (if adaptive)
- Look for landmark comments like `// classical RK4`, `// Cash-Karp`, `// adaptive`, `// step refinement`.

**Specific verification questions:**

1. What integrator does `solver.dart` actually implement? (Read the code.)
2. Does McCoy §8.4 endorse this choice, recommend alternatives, or take no position?
3. If the integrator is fixed-step: what step size? Is it justified by a step-independence argument?
4. If the integrator is adaptive: what tolerance? Does it actually meet the documented 1e-4 m claim per `Ballistics.md` §1?
5. **Step-independence test design:** Pick a representative trajectory (e.g., 1000-yard zero, 2700 fps, .308 175 SMK, sea-level standard atmosphere). Run at step sizes [base, base/2, base/4, base/8]. The trajectory output at sample range must converge. Document the convergence in the group report.
6. Reconcile `Ballistics.md` vs `solver.dart` self-doc — whichever describes the actual code wins; the other gets updated.

**Cardinal-case inputs for hand-derivation:**

These are inputs the executor uses to verify integrator behavior. The values are not from McCoy (no fixed example exists); they're chosen to exercise the integrator at known operating points.

- **Sea-level standard atmosphere; .308 175 SMK; 2650 fps MV; 1000-yard horizontal range.** Computes a benchmark trajectory.
- **Mach 0.85 transonic crossing.** Run with and without step refinement; output must agree within tolerance.
- **High-altitude (15000 ft density altitude); .338 Lapua 285 Hybrid; 2900 fps MV; 1500-yard range.** Stress test.

**Tolerance per BFP §0.5 Level 4:**

- Tier 1 self-consistency: ±0.01 mil between integrator runs at converged step.
- Step-independence test: trajectory at base/8 step must agree with base step output within ±0.01 mil at sample range (otherwise base step is not converged; refine).

**Output format for group report:**

- Identified integrator (with code line reference)
- Step-size policy (with code line reference)
- Step-independence test results (table of sample-range outputs vs step size)
- Reconciliation decision: docs updated to match code, OR code updated to match docs (operator-authority decision in Group A)

---

### Phase 8 — Coordinate System + Sign Convention Sweep

**BFP plan reference:** §10.1 Phase 8 outline. Build cardinal-direction sign-convention test suite. The six sign conventions per `solver.dart` self-doc: drop positive = below LoS; wind drift positive = right; spin drift positive = right; +X downrange; +Y up; +Z right.

**McCoy sections to read:**

- **§8.2 Equations of Motion** (p. 165). McCoy's choice of coordinate frame for point-mass trajectory. Read for: what frame is used (NEU, ENU, body-fixed), what the positive directions are.
- **§9.2 Equations of Motion for Six-Degrees-of-Freedom Trajectories** (p. 187–191). 6-DOF coordinate frame. Read for: body-fixed vs earth-fixed frames, Euler angle conventions, sign of angular rates.
- **§8.8 Coriolis Effect on Point-Mass Trajectories** (p. 178–183). Coriolis sign convention. Read for: which direction of horizontal Coriolis is positive (northward vs southward at the equator; Eötvös sign for east vs west shooting).
- **Chapter 2 Aerodynamic Forces and Moments** (p. 32–41) — *cross-reference*. Read for: drag force direction (opposite velocity), lift direction, Magnus force direction. Each is a sign convention the executor verifies against LoadOut.

**LoadOut code sites to verify against:**

- `lib/services/ballistics/solver.dart` self-doc preamble — the six conventions are stated there.
- Every solver internal function that uses one of the six conventions:
  - `drop` integration site (each correction added to drop)
  - `windageInches` site (wind drift accumulation)
  - `preInclineDrop` and `preInclineWindage` (the pre-incline trajectory)
  - Spin drift addition site
  - Aerodynamic jump addition site (DROP axis — see Phase 11)
  - Coriolis addition site
- `lib/services/ballistics/environment.dart` — shot azimuth convention (compass-style 0=north, 90=east, or math-style 0=east, 90=north). Verify which.

**Specific verification questions:**

1. Does LoadOut use NEU (north-east-up) or ENU (east-north-up) or some other frame?
2. Does shot azimuth use compass convention (cw from north) or math convention (ccw from east)? Both are valid; the implementation must be internally consistent.
3. For each of the six self-doc'd conventions, write a one-line cardinal test:
   - Drop convention: "Bullet fired horizontally at sea level, 1000 yd range — drop value should be POSITIVE (bullet falls below LoS)."
   - Wind drift convention: "10 mph wind from 90° (right-to-left from shooter's perspective, i.e., a left wind) — wind drift should be POSITIVE if convention is right-positive."
   - Spin drift: "Right-twist bullet, 1000 yd range, no wind — spin drift should be POSITIVE (drifts right)."
   - +X downrange: "Range-vs-time output's X coordinate increases monotonically."
   - +Y up: "At zero range, Y = scope height above bore (positive)."
   - +Z right: "Wind drift output's Z coordinate matches wind drift sign convention."
4. For Coriolis specifically: cardinal-azimuth test at fixed latitude. Northward shot at 45° N latitude — Coriolis deflects east (positive Z under +Z=right and shot-aligned conventions). Document.
5. Does McCoy's frame match LoadOut's? If different, document the rotation/reflection that maps one to the other and verify it's applied consistently in the solver.

**Cardinal-case inputs:**

For each of the six conventions, one cardinal axis-direction test (six tests total, possibly with sub-tests for Coriolis at different latitudes/azimuths). These become the BFP Phase 8 test fixtures in `test/ballistics/` per BFP §11.3.

**Tolerance:**

- Sign tests are exact (the output's sign matches expected, not "within tolerance"). Magnitudes are within Tier 1 self-consistency (±0.01 mil).
- Coriolis cardinal tests use Tier 2 published cross-check tolerance (±0.1 mil) against McCoy §8.8 example values (if McCoy provides example outputs for cardinal directions — verify when reading; if not, use hand-derived expected from McCoy's formula).

**Output format for group report:**

- Coordinate frame summary (with code reference)
- Six-convention verification table (each convention, cardinal test input, expected sign, observed sign)
- Coriolis sign cardinal test results
- Any drift items between McCoy's conventions and LoadOut's (with reconciliation decision)

---

### Phase 9 — Miller Stability + Pejsa Alternate

**BFP plan reference:** §10.1 Phase 9 outline. Verify Miller's velocity-corrected SG formula (Litz citation pipeline: Miller's *Precision Shooting* article March 2005). Audit Pejsa alternate.

**McCoy sections to read:**

- **§10.5 The Classical Gyroscopic Stability Criterion** (p. 230). McCoy's treatment of SG > 1 as the stability threshold and the physics underlying it. Read for: the analytical SG formula from which Miller's empirical refinement is derived.
- **§10.9 Gyroscopic and Dynamic Stability of Symmetric Projectiles** (p. 233–234). McCoy's broader stability discussion — gyroscopic vs dynamic stability, the SG ≥ 1.4 marginal threshold rationale.
- **§10.6 Yaw of Repose for Spin-Stabilized Projectiles** (p. 231) — *cross-reference*. The physics that's foundational to spin drift (Phase 10) consumes this section.

**LoadOut code sites to verify against:**

- `lib/services/ballistics/corrections/miller.dart` (or wherever Miller stability is implemented — verify in BFP Phase 1's file inventory).
- Bullet detail screen SG display — the UI surfaces SG to the user; the at-muzzle correction (atmosphere-corrected) is computed for the user's specific conditions.
- Any solver-internal use of SG (Phase 11 AJ formula depends on SG; Phase 10 spin drift formula depends on SG).

**Specific verification questions:**

1. The empirical SG formula LoadOut uses is the Miller 2005 form:
   ```
   SG = 30 m / (t² × d³ × L × (1 + L²))
   ```
   where m = grains, t = twist (calibers/turn), d = diameter (inches), L = length (calibers). Does the LoadOut implementation match this exactly?
2. Velocity correction: at-muzzle SG should be adjusted by `(MV/2800)^(1/3) × (T/518.67)^0.5 × (29.92/P)^0.5` for at-muzzle conditions. Does LoadOut apply this?
3. McCoy's analytical SG (§10.5) and Miller's empirical SG should agree in the regime where Miller's empirical fits hold (typical small-arms projectiles). Hand-derive at the cardinal cases (.308 175 SMK, 6.5 CM 140 ELD-M) using both and document the agreement.
4. Pejsa alternate: does LoadOut implement a Pejsa stability/drift alternate? If yes, where, and how does it compare to Miller? If no, what's the citation chain that justifies Miller as sole authority?

**Cardinal-case inputs:**

Bullets from the v1 audit zip's REFERENCE_VALUES.json (already verified mathematically by Claude Code 2026-05-12):

| Bullet | m (gr) | d (in) | L (in) | L_cal | Twist (in/turn) | Expected SG (Miller @ 2800 fps SL) |
|---|---|---|---|---|---|---|
| 6.5mm 140gr ELD-M | 140 | 0.264 | 1.412 | 5.348 | 8 | 1.51 (per v1 audit) |
| .308 175gr SMK | 175 | 0.308 | 1.240 | 4.026 | 11.25 | 1.84 (per v1 audit) |
| .338 Lapua 285gr Hybrid | 285 | 0.338 | 1.640 | 4.852 | 9.5 | 1.65 (per v1 audit) |

Compute Miller SG for each at the listed conditions; verify match to ±0.01.

**Tolerance:**

- SG values: ±0.01 between LoadOut and hand-derived Miller (Tier 1 self-consistency level).
- Velocity correction: ±0.5% (small adjustment; this is a multiplicative correction).

**Output format for group report:**

- Miller formula transcription verification (against Miller 2005, plus cross-check against McCoy §10.5 analytical form)
- Hand-derived SG table for cardinal bullets
- Velocity correction verification
- Pejsa status (implemented / not implemented / partially implemented)

---

### Phase 10 — Spin Drift

**BFP plan reference:** §10.1 Phase 10 outline. Verify Litz empirical formula `Sd = 1.25 × (SG + 1.2) × t^1.83` (inches at target range, time t in seconds). Cross-check against McCoy's yaw-of-repose physics.

**McCoy sections to read:**

- **§10.6 The Yaw of Repose for Spin-Stabilized Projectiles** (p. 231). The physics: a spinning bullet's nose lags the trajectory slightly (yaw of repose), producing a small lateral force that integrates to spin drift over flight time. Read for: the yaw-of-repose formula, the dependence on SG, the time-dependence of the resulting drift.
- **§9.7 The Modified Point-Mass Trajectory Model** (p. 212) — *cross-reference*. MPM includes yaw of repose as one of the "modifications" over pure point-mass. Read for: how MPM accounts for spin-drift physics within the trajectory integration.
- **Chapter 11 Linearized Swerving Motion** (p. 240–251) — *secondary cross-reference*. Additional context on lateral motion of spinning projectiles. Read selectively if the §10.6 treatment leaves questions.

**LoadOut code sites to verify against:**

- `lib/services/ballistics/corrections/spin_drift.dart` (verify exact filename in BFP Phase 1 inventory).
- The site in `solver.dart` where spin drift is added to the windage axis after integration.

**Specific verification questions:**

1. Does LoadOut implement `Sd = 1.25 × (SG + 1.2) × t^1.83` exactly? (Time t = time of flight to target, in seconds.)
2. Is the result in inches (per Litz) or another unit? Where does the unit conversion happen?
3. Sign: positive Sd means rightward drift for right-twist (per §3.2.2 of BFP plan). Does the implementation enforce twist-direction sign?
4. **Physics consistency check against McCoy §10.6:** the yaw-of-repose-driven drift should be approximately proportional to (SG + small_offset) × t^near_2. Litz's exponent 1.83 is empirical but within the expected range of ~1.8-2.0 from the physics. Hand-derive at cardinal cases using McCoy's formula and compare to Litz's empirical output. Document the agreement (or surface the disagreement as a finding).
5. Cardinal cases: 1000-yard horizontal shot, sea-level standard atmosphere, .308 175 SMK with right-hand twist. Expected spin drift per Litz: hand-derive. Compare to LoadOut output.

**Cardinal-case inputs:**

| Bullet | SG | TOF at 1000 yd (s) | Expected Litz Sd (in) | Expected sign |
|---|---|---|---|---|
| .308 175 SMK | 1.84 | 1.49 (approx, sea-level, 2650 fps MV, G7 BC=0.243) | `1.25 × (1.84 + 1.2) × 1.49^1.83` ≈ `1.25 × 3.04 × 2.13` ≈ 8.09 in | Right (positive, right-twist) |
| 6.5 CM 140 ELD-M | 1.51 | 1.50 (approx) | `1.25 × (1.51 + 1.2) × 1.50^1.83` ≈ 7.30 in | Right (positive, right-twist) |
| .338 Lapua 285 Hybrid | 1.65 | 1.32 (approx) | `1.25 × (1.65 + 1.2) × 1.32^1.83` ≈ 6.07 in | Right (positive, right-twist) |

These approximate values are for orientation; the executor hand-derives precisely from the trajectory at execution time using the actual computed TOF.

**Tolerance:**

- Litz formula self-consistency: ±0.05 mil at sample range (Tier 2 vs Litz Modern Advancements Vol I).
- McCoy physics cross-check: ±15% relative agreement at cardinal cases (this is an order-of-magnitude consistency check, not a precision match, because Litz's empirical formula and McCoy's physical formula come from different derivations).

**Output format for group report:**

- Litz formula transcription verification (LoadOut code vs Litz Modern Advancements Vol I)
- Cardinal-case hand-derivation table
- McCoy physics consistency notes (yaw-of-repose dependence vs Litz empirical exponent)
- Twist-direction sign verification

---

### Phase 11 — Aerodynamic Jump (closes audit C-1)

**BFP plan reference:** §10.1 Phase 11 outline. The C-1 fix: replace `-0.087 × TOF × V × twistSign / 1000` with `−Y_moa_per_mph × crossMph × twistSign × (rangeYd/100) × 1.047` where `Y_moa_per_mph = (SG/100) − (0.0024 × L_cal) + 0.032`. AJ feeds the DROP axis (not windage). Leading negation preserves solver sign convention.

**McCoy sections to read (highest priority of any phase):**

- **§12.9 The Aerodynamic Jump Due to Crosswind** (p. 267–269). The physics: a crosswind acting on a spinning bullet at the muzzle produces a small vertical impact shift (NOT a horizontal shift). Read carefully for: why the shift is vertical (gyroscopic precession converts a lateral force at the muzzle into a vertical deflection); the dependence on bullet properties (SG, length); the fixed-at-muzzle nature of the deflection (not accumulating with TOF or V).
- **§12.4 The Generalized Aerodynamic Jump Effect** (p. 259–263). The broader category — AJ from any small lateral disturbance at the muzzle (in-bore yaw, mass asymmetry, crosswind, etc.). Read for: the unifying physics; the formula structure McCoy uses; the variables that matter.
- **§9.7 The Modified Point-Mass Trajectory Model** (p. 212–214). MPM treatment of AJ — how the correction is incorporated into the trajectory. Read for: is AJ a per-sample correction during integration, a post-integration adjustment, or a muzzle-condition modification?

**LoadOut code sites to verify against:**

- `lib/services/ballistics/solver.dart` ~line 901 (per v1 audit zip) — the current AJ formula site. The C-1 defect is here.
- `lib/services/ballistics/solver.dart` ~line 1003 (per v1 audit zip) — the site where `aeroJumpPerSampleIn[i]` is integrated into `preInclineDrop[i]` (this confirms AJ → DROP axis, not windage).
- `aeroJumpPerSampleIn[]` array allocation and population sites — for understanding how AJ accumulates per integration step.

**Specific verification questions:**

1. **Confirm the C-1 defect.** Run the current code's AJ formula at a cardinal-case input and compare against:
   - The Litz formula's expected output (per Appendix C.1 of BFP plan)
   - McCoy's physical derivation in §12.9
   Both should agree on the order of magnitude and dependency structure; the current `-0.087 × TOF × V` form should fail both checks.
2. **Verify the corrected formula's structure against McCoy §12.9.** The Litz form `Y_moa_per_mph = (SG/100) − (0.0024 × L_cal) + 0.032` should be derivable (in approximate form) from McCoy's general AJ derivation, with the coefficients being empirical fits. The dependency on SG and L_cal should be visible in McCoy's equations.
3. **Confirm the axis.** AJ from crosswind produces a VERTICAL impact shift per McCoy §12.9. LoadOut's solver applies `aeroJumpPerSampleIn[]` to `preInclineDrop` (the drop axis), not to `windageInches` (the wind drift axis). Verify the application site is on the DROP axis. *Note: the v1 audit zip's `EXPECTED_CODE.dart` Section 2 incorrectly applied AJ to windage — that's a known typo in the audit zip, not a real recommendation. The correct axis is DROP.*
4. **Confirm the sign convention.** Per BFP §3.2.2, drop positive = below LoS. AJ from a left-to-right crosswind acting on a right-twist bullet should deflect the bullet UPWARD (toward shooter — reducing apparent drop) on a right-handed twist. The Litz formula's leading negation preserves this: `-Y_moa_per_mph × crossMph × twistSign × ...` produces negative perRangeIn when both crossMph and twistSign are positive, which (when added to drop) reduces the drop value (consistent with "AJ deflects up" for that case).
5. **Verify cardinal-case anchors.** Use the 7 bullets in Appendix C.1 of the BFP plan (carried from v1 audit zip's `REFERENCE_VALUES.json`). The anchor Y_moa_per_mph values should match Litz's published table at the relevant SG and L_cal.

**Cardinal-case inputs (from Appendix C.1 of BFP plan):**

| Bullet | SG | L_cal | Y_moa_per_mph (expected) | Deflection at 1000yd / 10mph crosswind (in) |
|---|---|---|---|---|
| 6.5mm 140gr ELD-M | 1.51 | 5.348 | 0.03426 | 3.587 |
| .308 175gr SMK | 1.84 | 4.026 | 0.04074 | 4.265 |
| .338 Lapua 285gr Hybrid | 1.65 | 4.852 | 0.03686 | 3.859 |
| .50 BMG 750gr A-Max | 1.55 | 4.922 | 0.03569 | 3.737 |
| .224 Valkyrie 90gr SMK | 1.48 | 5.312 | 0.03405 | 3.565 |
| 6mm 105gr Berger Hybrid | 1.52 | 5.041 | 0.03510 | 3.675 |
| .300 Win 215gr Berger | 1.62 | 5.260 | 0.03558 | 3.725 |

**Hand-derivation chain (example, 6.5 CM):**

```
Y = SG/100 − 0.0024 × L_cal + 0.032
  = 1.51/100 − 0.0024 × 5.348 + 0.032
  = 0.0151 − 0.012835 + 0.032
  = 0.034265
  ≈ 0.03426

Deflection at 1000yd / 10mph crosswind
  = -Y × cross_mph × twist_sign × (range_yd / 100) × 1.047
  = -0.03426 × 10 × (-1) × 10 × 1.047   [twist_sign = -1 if leading negation, else +1; sign convention checked separately]
  = 3.587 in
```

Sign of the final number depends on convention chain — the executor verifies the chain end-to-end and documents.

**Tolerance:**

- Y_moa_per_mph: ±0.0001 per anchor (per Appendix C.1 tolerance)
- Deflection: ±0.05 in at sample range (Tier 2 vs Litz 2nd ed pp 78–79 or 4th ed equivalent)
- Tier 2 published cross-check overall: ±0.02 MOA per anchor (per BFP §0.5 Level 4 table)

**Output format for group report:**

- Current solver AJ formula transcription (line reference) — should be the wrong form per C-1
- Corrected Litz formula transcription (replacement code)
- McCoy §12.9 physics consistency notes (dependency structure, vertical axis, fixed-at-muzzle nature)
- 7-bullet anchor verification table
- Sign convention chain documentation
- Test fixture re-baseline list (every test that consumed the old AJ formula's output is re-baselined; report lists each)

---

### Phase 12 — Coriolis (Horizontal + Eötvös Vertical)

**BFP plan reference:** §10.1 Phase 12 outline. Verify `a_coriolis = −2 × Ω × v` 3D vector formulation per McCoy. Horizontal Coriolis (lateral deflection) and Eötvös effect (vertical deflection from eastward/westward motion).

**McCoy sections to read:**

- **§8.8 The Coriolis Effect on Point-Mass Trajectories** (p. 178–183). The full treatment in McCoy. Read for: the 3D vector formula; the decomposition into horizontal (azimuth-dependent) and vertical (Eötvös) components; the sign conventions used; the example values at typical operating points (latitude × azimuth × velocity × range combinations).

**LoadOut code sites to verify against:**

- `lib/services/ballistics/corrections/coriolis.dart` (verify filename in BFP Phase 1 inventory).
- The site in `solver.dart` where Coriolis acceleration enters the integration loop.
- `lib/services/ballistics/environment.dart` shot azimuth field — Coriolis depends on the shooter's compass bearing (north-aimed shots have different Coriolis than east-aimed shots at the same latitude).

**Specific verification questions:**

1. **Vector formulation:** Does LoadOut compute `a = -2 × Ω × v` as a true 3D cross product, or as decomposed scalar terms (horizontal-only with separate Eötvös calculation)? Both are valid implementations; the executor confirms which and verifies internal consistency.
2. **Earth angular velocity Ω:** Magnitude `|Ω| ≈ 7.2921e-5 rad/s` (sidereal rotation). Direction: in a local NEU frame at latitude λ, `Ω = (cos λ, 0, sin λ) × |Ω|` (NEU components: cos λ north, 0 east, sin λ up). Verify LoadOut's representation matches.
3. **Cardinal-direction tests (each becomes a Phase 12 test fixture):**
   - **North shot at 45° N latitude:** Coriolis deflects east. Sign: positive (rightward under +Z=right convention, since east is the shooter's right when facing north).
   - **South shot at 45° N latitude:** Coriolis deflects west. Sign: negative (leftward).
   - **East shot at 45° N latitude:** Coriolis has both horizontal (small, southward — opposite shot direction adjusted) and Eötvös vertical (UPWARD — Eötvös for east-aimed shots reduces apparent gravity). 
   - **West shot at 45° N latitude:** Eötvös DOWNWARD (gravity appears stronger for west-aimed shots).
   - **North shot at equator (0° latitude):** Horizontal Coriolis is zero (cos 0 × 0 component for north-only). Hand-derive from McCoy §8.8 to verify.
   - **North shot at pole (90° N):** Maximum horizontal Coriolis (sin 90° = 1 for the vertical Ω component; the bullet's velocity is horizontal, cross product is maximum). Hand-derive.
4. **Compare McCoy §8.8 example values** (if any) against LoadOut's output at those inputs.

**Cardinal-case inputs:**

| Test | Lat (°) | Azimuth (° from N) | Range (yd) | Expected dominant Coriolis effect |
|---|---|---|---|---|
| North at 45° N | 45 | 0 | 1000 | Horizontal east-positive (right) |
| South at 45° N | 45 | 180 | 1000 | Horizontal west-negative (left) |
| East at 45° N | 45 | 90 | 1000 | Eötvös up + small horizontal south |
| West at 45° N | 45 | 270 | 1000 | Eötvös down + small horizontal north |
| North at equator | 0 | 0 | 1000 | Small, mostly Eötvös-only |
| North at pole | 89 (use 89 not 90 to avoid singularities in some implementations) | 0 | 1000 | Maximum horizontal east-positive |

**Tolerance:**

- Coriolis values: Tier 2 ±0.1 mil at sample range (per BFP §0.5 Level 4).
- Sign tests: exact.

**Output format for group report:**

- Vector formulation verification (3D cross product OR scalar decomposition — which one LoadOut uses)
- Ω magnitude and frame representation verification
- Six-cardinal-direction test table with expected and observed values
- McCoy §8.8 example value cross-check (if McCoy provides them)
- Reconciliation of any sign drift between McCoy and LoadOut

---

### Phase 13 — Cant × Crosswind Term (Secondary McCoy Consumption)

**BFP plan reference:** §10.1 Phase 13 outline. Implement the cant × crosswind angular term per Litz *Modern Advancements* Vol III. This correction is currently NOT IMPLEMENTED in `solver.dart` per its self-doc (the `muzzleCantDeg` field is read but not consumed).

**McCoy sections to read:**

- **Chapter 12 (Lateral Throwoff and Aerodynamic Jump)** (p. 252–272) for general context on lateral disturbances at the muzzle. Cant × crosswind is in the same family of small-angle perturbations as AJ from crosswind.
- McCoy is **not the primary source for the cant × crosswind term.** Litz *Modern Advancements* Vol III is. This phase's McCoy consumption is secondary — for physics consistency only.

**Primary source for Phase 13:** Litz, *Modern Advancements in Long-Range Shooting* Vol III. Reading guide for that book is separate (TBD when book is acquired).

**LoadOut code sites to verify against:**

- `solver.dart` — the `muzzleCantDeg` field consumer (currently a read-but-no-op). The Phase 13 implementation adds the cant × crosswind correction here.

**Specific verification questions:**

1. After implementation: is the correction structurally consistent with McCoy's AJ family of corrections (small-angle perturbations applied at the muzzle, propagating through trajectory as fixed angular deflections)?
2. Does the new code preserve the existing six sign conventions (Phase 8 verification)?

**Tolerance:**

- TBD when Litz Vol III is acquired and the formula is read.

**Output format:** TBD. This phase's full execution plan is drafted in BFP V3+ after Vol III is in the repo.

---

## 4. By-Chapter Index

For reverse navigation — when reading a specific McCoy section, this index lists which BFP phases consume it.

| McCoy Section | Pages | Primary phase consumer(s) | Secondary phase consumer(s) |
|---|---|---|---|
| Ch. 2 (Forces and Moments) | 32–41 | Phase 8 (sign conventions for forces) | Phase 11 (AJ force direction) |
| §3.4 (Firing Uphill and Downhill) | 47–50 | None directly | Phase 15 inclined-shot context (not in scan range) |
| Ch. 5 (Flat-Fire Point Mass) | 88–96 | None | Phase 5 (integrator context — not in scan range) |
| Ch. 8 (Point-Mass Trajectory) | 165–186 | **Phase 5** (§8.4); **Phase 8** (§8.2); **Phase 12** (§8.8) | All external phases (foundational) |
| §8.2 (EoM) | 165 | Phase 8 | Phase 5 |
| §8.4 (Numerical Solution) | 166–169 | **Phase 5** | None |
| §8.5 (Standard Atmospheres) | 166 | Phase 6 (atmosphere) | Phase 8 |
| §8.8 (Coriolis) | 178–183 | **Phase 12** | Phase 8 (sign conventions for Coriolis) |
| Ch. 9 (6-DOF + MPM) | 187–220 | **Phase 5** (§9.4); **Phase 8** (§9.2); **Phase 10** (§9.7); **Phase 11** (§9.7) | All external phases |
| §9.2 (6-DOF EoM) | 187–190 | Phase 8 | Phase 5 |
| §9.4 (6-DOF Numerical Solution) | 193 | Phase 5 | None |
| §9.7 (MPM Model) | 212–213 | **Phase 10** (MPM spin-drift treatment); **Phase 11** (MPM AJ treatment) | All MPM-consuming phases |
| Ch. 10 (Pitching and Yawing) | 221–238 | **Phase 9** (§10.5, §10.9); **Phase 10** (§10.6) | Phase 11 (yaw of repose context) |
| §10.5 (Gyroscopic Stability) | 230 | **Phase 9** | None |
| §10.6 (Yaw of Repose) | 231 | **Phase 10** | Phase 9 |
| §10.9 (Gyroscopic and Dynamic Stability) | 233–234 | **Phase 9** | None |
| Ch. 11 (Swerving Motion) | 240–251 | None directly | Phase 10 (additional spin-drift context) |
| Ch. 12 (Lateral Throwoff and AJ) | 252–272 | **Phase 11** (§12.4, §12.9) | Phase 13 (cant × crosswind context) |
| §12.4 (Generalized AJ Effect) | 259–263 | **Phase 11** | None |
| §12.9 (AJ Due to Crosswind) | 267–269 | **Phase 11** | None |

Sections outside the 165–270 scan range are listed here for completeness but are not in the audit chain unless the scan range is expanded later.

---

## 5. Hand-Verification Protocol (Carried from BFP §0.6)

Every group report that consumes McCoy must include the hand-verification work for each verified formula. The 8-step protocol:

1. **Locate the formula in the published source.** Cite McCoy section number AND page number. If imprecise, halt and ask the operator to refine.
2. **Transcribe the formula verbatim into the group report.** Including variable names, units, and noted assumptions.
3. **Identify the input values.** Cardinal cases: zero, small (linearization regime), the cited example value(s), one non-symmetric interior value.
4. **Hand-compute the formula at each input.** Show intermediate values. Round to McCoy's stated precision.
5. **Compare to McCoy's example (if any).** Expected residual is zero within stated precision.
6. **Compare to LoadOut's current output.** If disagreement, that's the audit finding.
7. **Update test fixtures to match the verified value** (when the disagreement is LoadOut being wrong).
8. **Paste the hand-derivation into the group report.** Reviewer can re-do the arithmetic inline.

Group reports without explicit hand-verification work are rejected per BFP §0.5 Level 4.

---

## 6. Sign Convention Reference Card

Quick reference for the six LoadOut sign conventions (per `solver.dart` self-doc and BFP §3.2.2). Every phase that consumes McCoy must verify its outputs against these conventions.

| Convention | Positive direction | LoadOut variable(s) | McCoy §reference for cross-check |
|---|---|---|---|
| (a) Drop | Below line of sight | `drop`, `preInclineDrop[]`, `dropAtRange` | §8.2 (gravity sign in EoM) |
| (b) Wind drift | Right (shooter's perspective) | `windageInches`, `preInclineWindage[]` | §7 (wind effects); §8.2 (EoM lateral term) |
| (c) Spin drift | Right (right-hand twist convention) | spin drift accumulator | §10.6 (yaw of repose direction) |
| (d) +X | Downrange | trajectory `x[]` array | §8.2 (range axis) |
| (e) +Y | Up | trajectory `y[]` array | §8.2 (vertical axis) |
| (f) +Z | Right | trajectory `z[]` array | §8.2, §8.8 Coriolis (lateral axis) |

For Coriolis specifically: convert McCoy's local-NEU output into LoadOut's shot-aligned XYZ frame using the shot azimuth. Document the conversion in Phase 12 group reports.

---

## 7. Format Expectations for the Owned Scan

When the legitimate hardcover arrives and is scanned, the resulting file should:

- **Live at:** `docs/references/mccoy_owned_scan.pdf`
- **Cover:** Pages 165–270 of the Schiffer 2nd ed reissue (Ch. 8 through Ch. 12 inclusive)
- **Format:** Color or grayscale PDF, 300+ DPI for legibility (200 DPI minimum for tables and equations)
- **Be OCR'd:** Adobe Acrobat, Apple Preview, ABBYY, or equivalent. Searchable text layer so the executor can `grep`-equivalent search by formula or term
- **Include scanned page numbers** matching the printed page numbers (so a citation to "p. 178" lands the reader at the printed p. 178, not the PDF-page-178)

**Sidecar file at:** `docs/references/mccoy_INDEX.md` containing:

```
# McCoy Modern Exterior Ballistics — Repo Provenance

Source: Robert L. McCoy, Modern Exterior Ballistics:
The Launch and Flight Dynamics of Symmetric Projectiles.
Schiffer Publishing, 2012 2nd ed reissue.
ISBN-13: 9780764338250

Acquired: <date>
Acquired from: <seller name> (e.g., Grand Eagle Retail via AbeBooks)
Price paid: $<amount>
Scanned by: <operator name>
Scan date: <date>
Scan device: <flatbed model / phone scanner app>
OCR engine: <Acrobat 2026 / Preview / ABBYY etc.>

Pages scanned: 165–270 (Chapters 8 through 12)
BFP phases consumed: 5, 8, 9, 10, 11, 12
Reading guide: docs/audit/MCCOY_READING_GUIDE.md
```

Commit message for the scan + sidecar:

```
docs(audit): add McCoy MPM reference (legitimately-owned scan, Ch. 8-12)

Source-of-record for BFP Phases 5, 8, 9, 10, 11, 12 hand-verification.
See docs/audit/MCCOY_READING_GUIDE.md for per-phase navigation.

Provenance: see docs/references/mccoy_INDEX.md
```

---

## End of Reading Guide

When the McCoy hardcover arrives, the workflow is:

1. Spot-check pagination: open to p. 165, confirm "The Point-Mass Trajectory" (Ch. 8) starts there. Open to p. 252, confirm "Lateral Throwoff and Aerodynamic Jump" (Ch. 12) starts there. If both match, this reading guide's page citations are correct.
2. Scan pages 165–270, OCR.
3. Commit `mccoy_owned_scan.pdf` + `mccoy_INDEX.md` to `docs/references/`.
4. The first BFP execution phase that consumes McCoy (Phase 5 or later) reads this guide first, then jumps to the relevant scan pages.

If pagination drift is found in step 1 (page numbers shifted between PDF source and your hardcover), update this guide's page citations with the offset and commit the update before any executor consumes it.
