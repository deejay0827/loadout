# Powley Interior Ballistics — BFP Phase 24 Reference

**Method originator**: H. S. Powley (mid-20th century interior ballistician)
**Method name**: Powley Computer (originally a slide rule device, now various web/software implementations)
**Underlying data**: Frankford Arsenal experimental work (~1940s-1960s)
**Most accessible authoritative reference**: `http://kwk.us/powley.html` — Kennedy's online Powley Computer with full documentation and worked examples

## Source Authoritativeness

| Source | Status |
|---|---|
| Powley's original *American Rifleman* / NRA publications (1950s-60s) | ⚠️ Hard to locate; out-of-print magazine archives. Method itself is described in many secondary sources. |
| The Powley pSI Computer (physical slide rule) | ⚠️ Out of production; historical artifact |
| `http://kwk.us/powley.html` (Kennedy) | ✅ Comprehensive web-based implementation with documented equations |
| Fr. Frog's Internal Ballistics page (`https://www.frfrogspad.com/intballi.htm`) | ✅ Authoritative secondary; discusses Frankford Arsenal origins |
| NRA Fact Book of 1988 | ⚠️ Out-of-print; alternative source for chemical energy constant |
| QuickLOAD documentation | ⚠️ Commercial product; references Powley framework |

## IP Posture

The Powley equations themselves have been publicly published since the 1950s-60s. Per kwk.us: *"The equations used in commercial software are proprietary, but those for the Powley Computer have been published."* Powley's framework is well into the public domain as far as the math is concerned. The specific implementations (QuickLOAD, Precise Load, etc.) are commercial software whose code is proprietary, but the Powley equations they implement are public.

For LoadOut's audit chain:
- ✅ Cite Powley as originator; reference kwk.us and Frankford Arsenal origins
- ✅ Use the documented η formula and constants
- ✅ Implement equivalent math in LoadOut
- ❌ Don't redistribute kwk.us's specific code or text wholesale

## The Powley Framework — Core Concepts

### Inputs
- Case capacity (gr H₂O — weight of water filling empty case)
- Case length (in)
- Cartridge length (in)
- Bullet length (in)
- Bullet weight (gr)
- Bullet diameter (in)
- Barrel length (in)

### Derived quantities

| Quantity | Formula / definition |
|---|---|
| **Net Capacity** | Case capacity minus the bullet seating volume |
| **Bullet Travel** | Barrel length minus bullet-base-to-muzzle inside the case |
| **Expansion Ratio (ER)** | Volume behind bullet at muzzle exit / Net case capacity. Range for Powley's data: 5.0 to 13.0 |
| **Mass Ratio (MR)** | Charge weight / Bullet weight. Range for Powley's data: 0.2 to 1.0 |
| **Sectional Density (SD)** | Bullet weight (lb) / Bullet diameter² (in²) |
| **Relative Capacity (RC)** | Net case capacity / Bore cross-sectional area. Characterizes the case (like SD characterizes the bullet). Range from ~0.9 (.30 Carbine) to ~6.0 (some small bore cartridges). Powley predictions work best near RC ≈ 3.0 (.308/.30-06 range) |
| **Quickness** | Powder selection index. Reference scale below. |
| **Kinetic Energy (KE)** | ½ × m × v² where m is bullet mass and v is muzzle velocity |
| **Efficiency (η)** | **KE_bullet / E_chemical** — see below |

### Quickness Reference Scale (for IMR Powders)

```
Quickness    IMR Powder
180          4227
160          4198
135          3031
120          4064
115          4895
110          4320
100          4350    (reference)
 95          4831
```

Higher = faster burning. Powder selection is determined primarily by SD and RC.

## Efficiency (η) — The Critical Formula for LoadOut Phase 24

**This is the H-2 finding's target. The v1 audit flagged a docstring vs code mismatch at `solver.dart` L118 vs L956-1002 regarding Powley η.**

The formula:

```
η = KE_bullet / E_chemical

where:
  KE_bullet = ½ × m_bullet × v_muzzle²  (ft-lb)
  E_chemical = m_charge × e_per_grain   (ft-lb)
```

### Chemical Energy Constant (`e_per_grain`)

Two documented values for IMR-class smokeless powders:

| Source | Value (ft-lb per grain of powder) |
|---|---|
| QuickLOAD average for IMR powders | **185 ft-lb/gn** |
| NRA *Fact Book* (1988) | **178 ft-lb/gn** |

**The difference matters for LoadOut Phase 24**: 185 vs 178 is a 4% difference in chemical energy, which propagates as a 4% difference in computed efficiency for any given load. Phase 24 audit must determine:

1. Which value does LoadOut's code use?
2. Which value does LoadOut's docstring claim?
3. Are they the same? (This is the H-2 question.)
4. Whichever is used, is it properly cited?

### Properties of η

- η is primarily a function of peak pressure and Expansion Ratio
- η increases with **either** higher peak pressure **or** higher ER
- Typical η values for modern rifle cartridges: 25-35% (most of the chemical energy becomes barrel/gas heat, not bullet KE)
- η explains why increasing case capacity doesn't increase MV linearly: bigger case lowers ER, lowering η

### Worked Example (per kwk.us Example 1)

.30-06 with 150 gr SP bullet, IMR 4350:
- Case capacity ≈ 68 gr H₂O
- Charge ≈ 56 gr 4350
- Predicted MV ≈ 2900 fps
- KE_bullet = ½ × (150/7000 lb) × 2900² ≈ 2802 ft-lb
- E_chemical = 56 × 185 = 10,360 ft-lb (using QuickLOAD constant)
- η ≈ 2802 / 10,360 ≈ **27.0%**

(Using 178 instead: E_chemical = 56 × 178 = 9,968; η ≈ 28.1%)

## Phase 24 Verification Targets

For BFP audit, LoadOut's Powley implementation should verify:

| Item | Powley/kwk.us specification | LoadOut should match |
|---|---|---|
| Efficiency formula | η = KE_bullet / E_chemical | ✅ Verify in code |
| Chemical energy constant | 185 ft-lb/gn (QuickLOAD) **OR** 178 ft-lb/gn (NRA 1988) — must be one of these or a citably-justified alternative | ✅ **THIS IS THE H-2 CHECKPOINT** — verify docstring matches code |
| KE calculation | ½ × m × v² in ft-lb (m in lb-mass = grains/7000) | ✅ Verify in code |
| Expansion Ratio | ER = V_behind_bullet_at_muzzle / Net_Capacity | ✅ Verify computation |
| Mass Ratio | MR = m_charge / m_bullet | ✅ Verify computation |
| Working pressure range | 40,000 to 50,000 CUP (~43,500 target) | ✅ Verify Powley-derived loads stay in this range |
| MR validity range | 0.2 to 1.0 | ✅ Verify boundary handling — extrapolation outside this range may be unreliable |
| ER validity range | 5.0 to 13.0 | ✅ Verify boundary handling |
| Best-fit RC | ~3.0 (.308/.30-06 region) | ✅ Document accuracy degrades for high-RC small-bores |
| Citation | Reference Powley with kwk.us and Frankford Arsenal acknowledgments | ✅ Verify in app docs |

## CRITICAL Limitations — Phase 24 MUST Document

These should be visible in LoadOut's documentation and ideally surfaced in UX when relevant:

1. **IMR powder framework only**: Powley equations were derived for single-base IMR-class powders. Double-base powders (Hodgdon Extreme, IMR Enduron, Vihtavuori N-series) behave differently. Predictions for non-IMR powders are extrapolations.

2. **Pressure range tuned for 40-50K CUP**: 
   - **Underestimates** pressure for loads near 50,000 CUP (by up to ~10%)
   - **Overestimates** pressure for loads near 30,000 CUP

3. **Best fit at RC ≈ 3.0**: Highest accuracy for cartridges like .308 Win, .30-06. Less accurate for high-RC small-bores (e.g., .22-250 with low SD bullets can give pressure estimates well below measured).

4. **Conservative powder selection bias**: Load Computer can indicate a powder too fast for safe loading, especially 4227 and 4198. Per kwk.us: *"Be especially wary of predictions for 4227 and 4198."* LoadOut should never recommend a 4198/4227 charge from Powley without explicit pressure-test cross-checking.

5. **Not for low-pressure cartridges**: Don't use Powley for cartridges rated below 52,000 CUP without modification.

6. **All-burnt-before-launch assumption**: Powley assumes the powder is fully consumed before bullet leaves the barrel. Reduced loads, slow powders in short barrels, etc., violate this assumption and give bad predictions.

7. **Pressure measurement basis is CUP, not piezo psi**: Powley's pressure outputs are calibrated against copper crusher measurements. Modern SAAMI standards use piezo (psi). Conversion between CUP and psi is NOT a fixed ratio — varies by cartridge. LoadOut should document this clearly if it outputs Powley pressures.

## Status

✅ Phase 24 primary source captured (the Powley η formula and constants)
✅ H-2 audit checkpoint clearly defined: verify docstring vs code at solver.dart L118 vs L956-1002 against documented constants (185 or 178)
✅ Limitations documented for safety/honesty
⚠️ **Phase 24 still needs**: LoadOut codebase walk to determine which constant is currently used (185 or 178) and resolve the H-2 docstring/code mismatch

## Related Work

For LoadOut's interior ballistics beyond Powley:
- **QuickLOAD** (commercial, Hartmut Brömel) — more general framework covering all powder types
- **Precise Load** (Benedikt Kruthaup, `https://preciseload.com/`) — public-web implementation supporting multiple powder types
- **P-Max** (Geoffrey Kolbe, `https://www.p-max.uk/`) — covers smokeless and black powder
- **McCoy Ch 10** (book arriving Saturday) — academic treatment of interior ballistics; may provide alternative formulation
- **Hatcher's Notebook** (Major General Julian S. Hatcher, 1947) — classic reference for older cartridge interior ballistics
