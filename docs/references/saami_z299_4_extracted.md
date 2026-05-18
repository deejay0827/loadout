# SAAMI Z299.4-2015 — Extracted Data for LoadOut Phase 27

**Source**: ANSI/SAAMI Z299.4-2015, "Voluntary Industry Performance Standards for Pressure and Velocity of Centerfire Rifle Ammunition for the Use of Commercial Manufacturers"
**Publisher**: Sporting Arms and Ammunition Manufacturers' Institute, Inc.
**URL**: `https://saami.org/wp-content/uploads/2018/01/206.pdf`
**Copyright**: © 2015 SAAMI, All Rights Reserved.
**Posture**: Facts cited; PDF not redistributed in LoadOut.

> Note: The 2025 update PDFs linked from saami.org/technical-information/ansi-saami-standards/ are currently 404'd (CMS issue, not access restriction). The 2015 version is substantively current for cartridges existing in both revisions; SAAMI describes inter-version changes as "minor adjustments of velocities, the addition of new load offerings."

## Pressure Terminology (verbatim definitions, factual)

- **MAP** (Maximum Average Pressure): recommended maximum loading pressure for commercial ammo
- **MPLM** (Maximum Probable Lot Mean): MAP + 2 standard errors, 97.5% confidence
- **MPSM** (Maximum Probable Sample Mean): MPLM + 3 standard errors
- **Standard Deviation**: σ = MAP × 0.04 (4% coefficient of variation)
- Pressure systems: copper crusher (CUP) or piezoelectric transducer (psi)

## Cardinal-Cartridge MAP Values (Piezo Transducer, psi)

LoadOut cardinal cases per v1 audit zip `REFERENCE_VALUES.json`:

| Cartridge | MAP (psi) | MPLM (psi) | MPSM (psi) |
|---|---|---|---|
| **6.5 Creedmoor** | 62,000 | 63,600 | 66,000 |
| **.308 Winchester** | 62,000 | 63,600 | 66,000 |
| **.300 Winchester Magnum** | 64,000 | 65,600 | 68,000 |
| **.338 Lapua Magnum** | 65,000 | 66,600 | 69,100 |
| **.223 Remington** | 55,000 | 56,400 | 58,500 |

## Other relevant cartridges (Piezo Transducer, psi)

| Cartridge | MAP | MPLM | MPSM |
|---|---|---|---|
| 22-250 Rem | 65,000 | 66,600 | 69,100 |
| 6mm Remington | 65,000 | 66,600 | 69,100 |
| .243 Winchester | 60,000 | 61,500 | 63,800 |
| .260 Remington | 60,000 | 61,500 | 63,800 |
| 30-06 Springfield | 60,000 | 61,500 | 63,800 |
| .270 Winchester | 65,000 | 66,600 | 69,100 |
| 7mm Rem Mag | 61,000 | 62,500 | 64,800 |
| 6.5×55 Swedish | 51,000 | 52,300 | 54,200 |

## Cartridges NOT in the 2015 standard (need 2025 update or alternate source)

| Cartridge | Status |
|---|---|
| **6mm Creedmoor** | Not in 2015 standard. Standardized later (~2017-2018). In 2025 update. |
| **.224 Valkyrie** | Not in 2015 standard. Standardized 2018. In 2025 update. |
| **6.5 PRC** | Not in 2015. Standardized 2018. In 2025 update. |
| **.300 PRC** | Not in 2015. Standardized 2018. In 2025 update. |
| **.50 BMG** | Not a SAAMI cartridge. Military / CIP. Use alternative source. |

## Reference Velocity Values (Piezo Transducer, fps @ 15')

For cardinal cartridges (most representative test barrel velocities):

| Cartridge | Bullet (gr) | Reference MV (fps) |
|---|---|---|
| 6.5 Creedmoor | 120 | 2,900 |
| 6.5 Creedmoor | 129 | 2,940 |
| 6.5 Creedmoor | 140 | 2,690 |
| .308 Winchester | 150 | 2,800/2,900/2,980 (3 ref loads) |
| .308 Winchester | 165 | 2,870/2,880 |
| .308 Winchester | 168 | 2,670 |
| .308 Winchester | 175 | 2,600 |
| .308 Winchester | 180 | 2,600 |
| .308 Winchester | 200 | 2,440 |
| .300 Win Mag | 150 | 2,635/3,275/3,390 |
| .300 Win Mag | 165 | 3,110/3,260 |
| .300 Win Mag | 180 | 2,950/3,040/3,080 |
| .300 Win Mag | 190 | 2,875 |
| .300 Win Mag | 200 | 2,800/2,930 |
| .300 Win Mag | 220 | 2,665 |
| .338 Lapua Mag | 250 | 2,950 |
| .338 Lapua Mag | 280 | 2,600 |
| .338 Lapua Mag | 285 | 2,745 |
| .338 Lapua Mag | 300 | 2,620 |
| .223 Remington | 55 | 3,050/3,215 |
| .223 Remington | 62 | 3,000/3,080/3,240 |
| .223 Remington | 69 | 2,985 |
| .223 Remington | 75 | 2,775 |
| .223 Remington | 77 | 2,670/2,785 |

**Velocity tolerance per standard**: ±90 fps from tabulated values for ammunition tested with conforming equipment.

## Standard Atmospheric Conditions (per SAAMI test methodology)

SAAMI testing conditions are referenced to:
- Temperature: not explicitly stated in extracted sections (likely 70°F / 21°C per industry standard)
- Test barrel specs: see Section III
- Velocity measurement: at 15' from muzzle, instrumental velocity

## Detailed Cartridge Dimensions Captured (2015)

Only these had readable text-extracted dimensions in my fetch:
- **338 Lapua Magnum** (p. 116) — complete dimensional data
- **9.3 × 62** (p. 56) — partial
- **26 Nosler / 27 Nosler / 28 Nosler / 30 Nosler / 33 Nosler** — complete

For other cartridges (6.5 CM, .308 Win, .300 Win Mag, .223 Rem), the drawings are rasterized in the PDF and didn't text-extract. The chamber/cartridge drawings exist on pages 37-154 of the 2015 standard but require visual access to the PDF for dimensional verification.

**For Phase 27 verification of LoadOut's cartridge dimension data**:
1. SAAMI's "New & Revised Cartridge & Chamber Drawings" page (separate from main standard) has updated drawings for cartridges revised since 2015
2. For dimension cross-checks, the operator can visually inspect the PDF (downloadable from `https://saami.org/wp-content/uploads/2018/01/206.pdf`)
3. Or fetch the 2025 PDF when SAAMI fixes its CMS

## 338 Lapua Magnum — Complete Cartridge Dimensions (extracted)

| Dimension | Value (inches) | Value (mm) |
|---|---|---|
| Bullet diameter | .3390 −.003 | 8.61 −0.08 |
| Bullet base diameter | .5870 | 14.91 |
| Body diameter at .200" from head | .5454 | 13.853 |
| Rim diameter | .5878 | 14.93 |
| Case length | 2.7244 −.020 | 69.20 −0.51 |
| Cartridge OAL max | 3.6811 −.120 | 93.50 −3.05 |
| Body diameter ahead of belt | (no belt — beltless mag case) | — |
| Shoulder angle | 20° 00' | — |
| Twist (optional) | 1:10 | 254 mm |
| Min bore & groove area | .0881 in² | 56.860 mm² |
| Bore diameter | .330 / .338 | 8.38 / 8.58 |

(338 Lapua specifically had detailed dimension data in the PDF text extraction.)

## Primer & Primer Pocket (extracted)

**Small Rifle Primer**:
- Primer cup OD: 0.1730 - 0.1745" (4.394 - 4.432 mm)
- Pocket diameter: 0.1745 - 0.1765" (4.432 - 4.483 mm)
- Pocket depth: 0.115 - 0.126" (2.92 - 3.20 mm)
- Flash hole: typical 0.080" (varies by cartridge)

**Large Rifle Primer**:
- Primer cup OD: 0.2085 - 0.2100" (5.296 - 5.334 mm)
- Pocket diameter: 0.2105 - 0.2130" (5.347 - 5.410 mm)
- Pocket depth: 0.123 - 0.136" (3.12 - 3.45 mm)

Primers to be seated **flush to 0.008" (0.20 mm) below face of cartridge case head**.

## Bullet Type Abbreviations (extracted)

LEAD: HP, L, LHP, MP
JACKETED: BT, BTHP, FP, FMJ, FMC, HP, JF, JFP, JHP, JSP, MC, OTM, P (Partition), PHP, PSP, **PT (Polymer Tip)**, S (Spitzer), SP, XP
SEMI-JACKETED: SJHP, SJSP
OTHER: HC (Hard Cast), Solid

Note the PT (Polymer Tip) designation — this is the SAAMI-recognized abbreviation for plastic-tipped bullets, relevant to BFP F16 (Courtney-Miller plastic-tip variant).

## IP Posture for LoadOut Audit Chain

**What we use from this standard**:
- MAP values as facts about the industry standard for safety
- Cartridge dimensions as facts about industry-standardized geometry
- Velocity reference values as industry-standard nominal values
- Citation by ANSI number: `ANSI/SAAMI Z299.4-2015`

**What we do NOT do**:
- Redistribute the PDF as part of LoadOut's distribution
- Reproduce extended verbatim text in marketing materials
- Reproduce the cartridge drawings in LoadOut without separate permission

**Distribution status of this reference file**:
- This `.md` file is for the LoadOut development repo, not user-facing distribution
- Contains facts about the standard, plus our own analysis
- Standard SAAMI citation chain applies

## Outstanding Gaps

1. **Detailed dimensions for 6.5 CM, .308 Win, .300 Win Mag, .223 Rem** — drawings didn't text-extract; need visual inspection of PDF or alternate fetch method
2. **6mm Creedmoor, .224 Valkyrie, 6.5 PRC, .300 PRC** — not in 2015 standard; need 2025 update
3. **.50 BMG** — not a SAAMI cartridge; need military STANAG 4625 or CIP reference
4. **Section III test barrel specs** — not extracted; in pages 191+ of the PDF
5. **Section IV proof loads** — not extracted; in pages 351+ of the PDF

## Next Actions

1. Attempt to extract pages 110+ (308 Winchester drawing) from PDF
2. Find a working URL for the 2025 Z299.4 PDF (operator may need to navigate from saami.org directly)
3. For .50 BMG: McCoy 2nd ed will cover military ballistics; check upon arrival
4. For 6mm Creedmoor / .224 Valkyrie / 6.5 PRC: 2025 SAAMI update OR Hornady technical bulletins (factual cartridge specs are extractable)
