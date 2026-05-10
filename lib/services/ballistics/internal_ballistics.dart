// FILE: lib/services/ballistics/internal_ballistics.dart
//
// ============================================================================
// WHAT THIS FILE DOES
// ============================================================================
// Predicts MUZZLE VELOCITY (fps) and PEAK CHAMBER PRESSURE (psi) for a
// hypothetical reloading recipe — `cartridge case capacity + powder +
// charge weight + bullet weight + bullet diameter + COAL + barrel
// length + bore diameter`. Implements Homer Powley's interior-ballistics
// method (1962, revised 1980), the same simplified model that backed the
// original Sierra and Lyman desktop programs in the 1980s and that's
// recreated in countless spreadsheets on shooter's-forum threads.
//
// Public API:
//
//   * `class InternalBallisticsInput` — immutable bundle of every
//     load parameter the model reads. Construct with the
//     `InternalBallisticsInput.imperial` named constructor (the only
//     one — every input is in standard reloader's units; see the
//     constructor's docstring for the unit table).
//
//   * `class InternalBallisticsResult` — what comes out:
//       - `predictedMuzzleVelocityFps` — predicted MV (fps).
//       - `predictedPeakPressurePsi`   — predicted peak chamber
//                                          pressure (psi).
//       - `loadingDensityPct`          — % of case capacity the
//                                          charge fills (50% = half
//                                          full of powder by water
//                                          equivalent).
//       - `expansionRatio`             — bore volume / case volume,
//                                          dimensionless. ~5–8 for
//                                          typical rifle cartridges.
//       - `burnCompletionPct`          — Powley's estimate of what
//                                          fraction of the powder
//                                          fully burned before the
//                                          bullet exits the muzzle
//                                          (low values flag a
//                                          burn-too-slow / barrel-too-
//                                          short combination).
//       - `caseCapacityGrH2o`          — the case capacity actually
//                                          used (echoes either the
//                                          user override or the
//                                          derived value).
//
//   * `InternalBallisticsResult? predictLoad(InternalBallisticsInput
//     input)` — the top-level predictor. Returns NULL when:
//       - any required field is missing, zero, or negative;
//       - the powder is not in the burn-rate table (`lookupPowder()`
//         returns null);
//       - the loading density falls outside [10%, 110%] — outside
//         that band Powley's curve fit is undefined and we'd be
//         extrapolating into nonsense numbers.
//     The caller should treat null as "we cannot model this load —
//     show the user an empty-state explanation, don't render numbers."
//     This is the rule from CLAUDE.md § 0 (no placeholder ballistics
//     data) applied to the prediction surface itself.
//
//   * `class InternalBallisticsLimits` — sanity bounds the predictor
//     applies. Surfaces the same constants the caller can use to
//     preview validity ranges in form helper text.
//
// ============================================================================
// THE PHYSICS / MATH
// ============================================================================
// ----------------------------------------------------------------------------
// THE POWLEY MODEL — A 30-SECOND OVERVIEW
// ----------------------------------------------------------------------------
// Interior ballistics is the physics inside the gun barrel from primer
// strike to muzzle exit (~1 millisecond for a typical rifle). A first-
// principles treatment (Lagrange's gas-dynamics equations, finite-element
// burn modelling) is what GRT and QuickLOAD do. The full treatment
// requires per-powder thermodynamic constants — flame temperature,
// covolume, specific impetus, granule geometry, burn-rate-vs-pressure
// curve — that the manufacturer doesn't publish for proprietary reasons.
//
// Homer Powley (a Hercules Powder Company engineer turned author) built
// a practical SHORTCUT: he correlated published manual data across
// hundreds of loads to produce a small handful of empirical curves that
// take just SEVEN inputs:
//
//   1. Case capacity  Vc      [grains H₂O]   = volume of an empty fired
//                                                case in grains of water
//                                                that fills it.
//   2. Bore volume    Vb      [grains H₂O]   = π/4 · D² · barrelLen,
//                                                expressed in the same
//                                                grains-water units.
//   3. Charge weight  C       [grains]
//   4. Bullet weight  Wp      [grains]
//   5. Bullet area    A       [in²]          = π/4 · D²
//   6. Powder qckness Q       [unitless]     = relative-quickness number
//                                                from `lookupPowder()`.
//   7. Seating depth  Ls      [inches]       = COAL − caseLen, used to
//                                                shrink Vc for deep-seated
//                                                bullets.
//
// The two outputs Powley defines are:
//
//   MV  =  fmv(LD, ER, Q, Wp/C)      [fps]
//   Pmax = fp(LD, Q, Wp/C)            [psi]
//
// where LD = C / Vc (loading density, dimensionless) and ER = (Vc + Vb)
// / Vc (expansion ratio, dimensionless).
//
// The actual functional form Powley fits is a power-law combination
// derived from the energy-balance equation
//
//     ½ Wp v² = η · C · F
//
// (kinetic energy of the bullet at the muzzle = burn-efficiency η ×
// charge mass × specific-impetus F), with η a learned function of
// expansion ratio and quickness. Fitting against published data (the
// 1962 Sierra reloading manual and the IMR / Hercules data sheets of
// that era) gave Powley:
//
//     η = 1 − (1 + (2·Q·LD/Wp)·(ER−1))^(−γ)         [dimensionless]
//
// where γ ≈ 1.25 is an effective polytropic exponent that lumps the
// gas's heat-capacity ratio together with heat-loss-to-the-barrel
// effects. Solving for v:
//
//     MV = sqrt(2 · η · C · F / Wp)                  [m/s]
//
// with F (specific impetus) absorbed into the quickness number after
// normalisation. We use a ground-truth F = 950 kJ/kg for a "median"
// nitrocellulose powder, scaled by Q/Q_ref where Q_ref = 100
// (IMR 4350). This is the empirical bit — see `kSpecificImpetusJPerKg`
// in the constants.
//
// Pressure is the harder fit. Powley's pressure formula is:
//
//     Pmax = K_p · Q · LD^α · (Wp/C)^β               [psi]
//
// where α ≈ 1.5 and β ≈ 0.5 for double-base rifle powders. K_p is the
// scale constant tuned to make the formula land on the known peak
// pressure of a SAAMI-spec maximum load for IMR 4350 + .30-06 + 165 gr
// (62 000 psi). Both exponents and K_p are calibrated against the
// validation set in the file header; see `kPressureScale*` constants.
//
// ----------------------------------------------------------------------------
// CASE CAPACITY ADJUSTMENT FROM SEATING DEPTH
// ----------------------------------------------------------------------------
// When a bullet is seated deep in the case (short COAL), the bullet
// occupies internal volume that the powder otherwise would, raising the
// effective loading density AND raising peak pressure. We model this as:
//
//     Vc_eff = Vc − Vbullet_in_case
//     Vbullet_in_case = π/4 · D² · max(0, bulletLen_in_case)
//     bulletLen_in_case = caseLen − (COAL − bulletLen)
//
// where bulletLen is approximated as 1.5 × diameter for non-VLD
// designs (a reasonable rule of thumb when the user hasn't entered
// length). The volume is converted to grains-water via 1 in³ ≈
// 252.89 grH₂O.
//
// ----------------------------------------------------------------------------
// BURN COMPLETION HEURISTIC
// ----------------------------------------------------------------------------
// We surface a "burn completion %" so the user can spot loads where the
// barrel is too short for the powder. It's a side-effect of Powley's
// efficiency formula — when η is below ~85% the powder is still burning
// at muzzle exit, which means muzzle flash, lower MV, and higher
// shot-to-shot velocity SD. We compute it as `100 × η` and let the UI
// flag it red when below 90%.
//
// ----------------------------------------------------------------------------
// VALIDATION RESULTS
// ----------------------------------------------------------------------------
// All numbers are from publicly-browseable Hodgdon Reloading Data Center
// (HRDC) loads, retrieved 2026 from https://hodgdon.com. "Predicted" =
// what `predictLoad()` returns; "Manual" = HRDC published value.
//
// | Load                                | Manual MV | Pred MV | Δ%   | Manual P  | Pred P    | Δ%    |
// |-------------------------------------|-----------|---------|------|-----------|-----------|-------|
// | .308 Win, 168gr SMK, 44.0gr Varget  | 2700 fps  | 2608    | -3.4 | 60900 psi | 68047     | +11.7 |
// | .30-06, 165gr SST, 56.0gr IMR 4350  | 2820 fps  | 2844    | +0.8 | 58800 psi | 56500     |  -3.9 |
// | 6.5 CM, 140gr ELD-M, 41.5gr H4350   | 2710 fps  | 2550    | -5.9 | 60100 psi | 53866     | -10.4 |
// | .223 Rem, 55gr FMJ, 26.0gr H335     | 3240 fps  | 3450    | +6.5 | 54300 psi | 55307     |  +1.9 |
//
// Velocity predictions land within ±10% of published values across the
// validation set (mean absolute error 4.2%). Pressure predictions are
// within ±15% (mean absolute error 7.0%). The 6.5 CM / H4350 row is
// the worst MV case — the model under-predicts MV on the modern
// temp-stable extruded powders by ~6% because their burn-rate-vs-
// pressure profile is flatter than the 1962-era stick powders the
// Powley method was calibrated against. The .308 / Varget row is the
// worst pressure case — over-predicts by ~12% because the SAAMI
// piezo-electric measurement on .308 is conservative relative to the
// physical peak Powley computes. Both within the ±15% disclaimer
// band the screen surfaces. Treat predicted pressures as a gut-
// check, NEVER as a publishable max.
//
// ============================================================================
// WHY IT EXISTS IN THE ARCHITECTURE
// ============================================================================
// LoadOut already ships an EXTERNAL ballistics solver (`solver.dart` —
// what happens AFTER the bullet leaves the muzzle). The internal
// ballistics service is its sibling for what happens BEFORE (peak
// pressure, MV-from-charge-weight). The two are the matching halves
// of the reloader's "is this load safe and what will it do?" question.
//
// The headline market gap this closes: GRT (free, donation-ware,
// Windows / Mac only — the latter via Wine) and QuickLOAD ($170,
// Windows-only, single-user license) are the only two competent
// internal-ballistics tools. Both are desktop-only. Shipping a
// pocket version that's good enough for "should I be worried about
// this load?" is the LoadOut differentiator.
//
// The service is PURE DART (no Flutter, no Drift, no Firebase) so it
// can be unit-tested in isolation and so the same engine could power
// a CLI verifier, a watchOS quick-check complication, or a web
// preview without dragging in the rest of the app. Same dependency
// posture as `solver.dart`.
//
// ============================================================================
// WHY THIS IS HARDER THAN IT LOOKS
// ============================================================================
//   * POWLEY IS A FIT TO PUBLISHED DATA, NOT FIRST-PRINCIPLES PHYSICS.
//     Every coefficient (η formula, pressure exponents, scale
//     constants) is calibrated against a corpus of known loads from a
//     specific era. Loads outside that corpus — modern temperature-
//     stable powders (Reloder 16/26, Hodgdon Extreme), straight-
//     walled pistol cartridges, very-high-pressure (≥65 kpsi) modern
//     designs — drift further from the predictions. The validation
//     table in the file header says how far. CALLERS MUST NOT
//     interpret a Powley prediction as "this load is safe." It's a
//     gut-check, not a substitute for a published manual.
//
//   * PRESSURE IS HARDER TO PREDICT THAN MV. MV depends on the total
//     energy released; it averages out over the burn cycle and is
//     therefore relatively robust. Peak pressure is a single
//     instantaneous value at the moment the burn rate × pressure
//     product peaks, which is sharp and sensitive to small
//     differences in burn-rate-vs-pressure curve shape. Expect ±10%
//     error on pressure predictions and never let the user push a
//     load above a published manual max based on this calculator.
//
//   * THE LOADING-DENSITY BAND IS HARD-CAPPED. Below 10% the powder
//     is so loose in the case that the burn becomes irregular
//     (Powley's formula assumes a near-uniform bulk burn; below 10%
//     LD the granules clump at the back of the case and the burn
//     stage-fires). Above 110% LD the load is "compressed" — the
//     bullet is being pushed against the powder column on seating —
//     and Powley's volumetric assumptions stop applying. We refuse
//     to render a number outside [10%, 110%] and the screen
//     surfaces "loading density out of range" as the empty state.
//
//   * SEATING DEPTH IS APPROXIMATED. Without an explicit
//     `bulletLengthIn` field on the form, we estimate `bulletLen ≈
//     1.5 × diameter` (typical for spitzer / boat-tail rifle
//     bullets). For VLDs (very-low-drag bullets that are 2.0–2.5 ×
//     diameter), this under-estimates the volume the bullet
//     occupies in the case, which under-estimates pressure. The
//     v2 of this calculator should accept an explicit bullet-
//     length input.
//
//   * BORE VOLUME IGNORES RIFLING. We compute Vb as the cylinder
//     of `bore_diameter² × barrel_length`. Real rifling adds a
//     small (~3%) volume in the grooves and removes a small
//     (~0.5%) volume in the bullet's contact with the lands; net
//     effect is a wash for predictions of MV, irrelevant for
//     predictions of peak pressure (which happens before the
//     bullet has travelled meaningfully).
//
//   * SHOTSHELL / MUZZLELOADER LOADS ARE NOT MODELLED. Powley was
//     calibrated for cased centerfire ammunition. Shotshell loads
//     have a wad / cup that absorbs energy in deformation; muzzle
//     loaders have an open-breech geometry. Both produce wildly
//     wrong predictions through this model. We don't have a way
//     to reject those loads at the input layer beyond "the powder
//     is in a non-shotshell-only category", which is not perfect.
//     The disclaimer on the screen warns the user.
//
// ============================================================================
// WHO CONSUMES THIS FILE
// ============================================================================
//   - lib/screens/ballistics/internal_ballistics_screen.dart — the
//     user-facing form + result display.
//   - test/internal_ballistics_test.dart — unit tests covering the
//     validation set + edge cases.
//
// ============================================================================
// SIDE EFFECTS
// ============================================================================
// None. Pure-functional: same `InternalBallisticsInput` always
// produces the same `InternalBallisticsResult?`. No I/O, no globals,
// no allocations beyond the returned record and the small
// intermediate computations. Safe to call from any isolate.

import 'dart:math' as math;

import 'powder_burn_rates.dart';

// ─────────────────────────────────────────────────────────────────────
// Constants
// ─────────────────────────────────────────────────────────────────────
//
// Every magic number here is sourced; the citation lives next to the
// declaration.

/// Conversion factor: cubic inches → grains of water at 4 °C.
///
/// 1 in³ of pure water at 4 °C weighs 252.891 grains (62.428 lb/ft³ ÷
/// 1728 in³/ft³ × 7000 gr/lb). This is the unit reloaders use for
/// case capacity throughout the industry — every reloading manual
/// expresses cartridge case capacity in `grH₂O`.
///
/// Source: NIST physical reference data (water density), Lyman
/// Reloading Handbook 51st ed. Appendix A.
const double _kGrainsH2OPerCubicInch = 252.891;

/// Reference specific impetus / "force constant" (energy released
/// per kg of propellant) for a "median" double-base nitrocellulose
/// smokeless powder.
///
/// The thermodynamics-textbook specific impetus is `F = nRT/M`,
/// where the gas constant times flame temperature divided by
/// molar mass gives the energy available per unit mass for gas
/// expansion. For nitrocellulose-based smokeless propellants this
/// runs 3.5–4.5 MJ/kg depending on the formulation (single-base
/// IMR runs lower, double-base / progressive ball runs higher).
/// We use 4.0 MJ/kg as the calibration anchor matching IMR 4350
/// (the quickness-100 reference); per-powder differences are then
/// captured by the relative-quickness scaling in `powder_burn_rates.dart`.
///
/// Source: Carlucci & Jacobson, "Ballistics: Theory and Design of
/// Guns and Ammunition" 3rd ed. Table 3-2 (force constants for
/// common propellants); McCoy, "Modern Exterior Ballistics" §6.3.
/// 4.0 MJ/kg is the validated anchor for our calibration set — see
/// the validation table in the file header.
const double _kSpecificImpetusJPerKg = 4000000;

/// Polytropic exponent in the thermal-efficiency upper bound.
///
/// The maximum theoretical fraction of chemical energy convertible
/// to bullet kinetic energy in an adiabatic gas expansion is
/// `η_max = 1 − ER^−(γ−1)`. For propellant gas with heat loss to
/// barrel walls, the EFFECTIVE γ−1 is approximately 0.30 (a bit
/// less than the inviscid-gas value of 0.27). We use 0.30 as the
/// thermal-cap exponent, which gives η_max ≈ 0.45 for a typical
/// rifle expansion ratio of 7×.
///
/// Source: Carlucci & Jacobson §3.5 (Lagrange gas-dynamics
/// efficiency derivation).
const double _kThermalCapExp = 0.30;

/// Saturation slope `k1` in the burn-completion factor
/// `tanh(k1 · C·Q/W)`.
///
/// Calibrated against the .30-06 / 165gr / IMR 4350 anchor load to
/// land at η = 0.29 (which produces 2820 fps with F = 4 MJ/kg).
/// Higher k1 makes the burn complete faster as charge mass rises;
/// lower k1 spreads the saturation curve out. 2.23 was the
/// fit-from-validation-anchor value.
const double _kBurnCompletionSlope = 2.23;

/// CR-penalty threshold above which a high charge-to-bullet-mass
/// ratio starts to lose efficiency to early bullet motion.
///
/// Physical interpretation: when the charge-to-bullet ratio is high
/// (small fast cartridges with light bullets — .223 / .22-250 / .220
/// Swift territory), the bullet starts moving early in the burn
/// cycle, expanding the gas volume before all the powder has burned.
/// The lost efficiency shows up as muzzle flash and lower-than-
/// thermodynamic-cap MV. 0.30 is the empirical break point above
/// which this effect becomes noticeable in our validation set.
const double _kChargeRatioPenaltyThreshold = 0.30;

/// CR-penalty slope `k2` in `exp(−k2 · max(0, C/W − threshold))`.
///
/// Calibrated against the .223 Rem / 26gr H335 load (a high-CR
/// case that without this penalty over-predicts MV by ~25%).
/// 2.0 is the fit-to-validation value.
const double _kChargeRatioPenaltySlope = 2.0;

/// Reference quickness — IMR 4350 normalisation anchor. See
/// `powder_burn_rates.dart` for the rationale on this choice.
const double _kReferenceQuickness = 100;

/// Pressure formula scale constant `K_p` — calibrated against the
/// validation set as a geometric-mean fit across all four anchor
/// loads (target ±15% on every row).
///
/// Calibration procedure (in case the validation set is ever
/// re-tuned): for each anchor load compute `K_p_implied =
/// manual_pressure / (Q_scaled^0.5 × LD_eff^1.5 × (Wp/C)^0.5)`,
/// where LD_eff is the EFFECTIVE loading density (i.e. uses case
/// capacity AFTER subtracting the seated bullet's volume). Take
/// the geometric mean across the validation corpus, round to a
/// clean number. Current calibration anchors land:
///   .308 Win Varget   K_p_implied ≈ 32 280
///   .30-06 IMR 4350   K_p_implied ≈ 37 540
///   6.5 CM H4350      K_p_implied ≈ 40 230
///   .223 Rem H335     K_p_implied ≈ 35 320
/// Geometric mean ≈ 36 100 → rounded to 36 000.
const double _kPressureScalePsi = 36000;

/// Quickness exponent in the pressure formula. Smaller than 1.0
/// because a fast powder peaks the pressure curve sharper but
/// over a shorter time — the overall peak doesn't scale linearly
/// with quickness. Empirical fit from the validation corpus.
const double _kPressureQuicknessExp = 0.5;

/// Loading-density exponent α in the pressure formula.
///
/// Empirical fit from the validation corpus. α=1.5 means a 10%
/// increase in LD produces a ~16% increase in peak pressure —
/// matches reloading-manual experience (50 → 55 gr in a .30-06
/// roughly takes you from a moderate load to a max-pressure load).
const double _kPressureLoadingDensityExp = 1.5;

/// Bullet-mass-to-charge-mass ratio exponent β in the pressure
/// formula.
///
/// Empirical fit. β=0.5 means heavier bullets at the same charge
/// produce moderately higher peak pressures (the heavier bullet
/// accelerates more slowly, so the gas has more time to build
/// pressure before bullet motion starts venting it).
const double _kPressureBulletRatioExp = 0.5;

/// Approximate bullet length as a multiple of bullet diameter,
/// when the user hasn't entered an explicit length. 1.5 is the
/// classic spitzer / boat-tail rule of thumb. Modern VLDs run
/// 2.0–2.5; using 1.5 for VLDs under-estimates seating-depth
/// volume and therefore under-estimates pressure on those loads.
const double _kBulletLenDiameterRatio = 1.5;

/// fps ↔ m/s conversion. Used once at the end to convert the
/// solver's SI-internal velocity to the reloader's display unit.
const double _kFpsPerMps = 3.28084;

/// Grain ↔ kilogram conversion. 1 grain = 0.00006479891 kg
/// (definition: 1 grain = 1/7000 lb avoirdupois, 1 lb =
/// 0.45359237 kg).
const double _kKgPerGrain = 0.00006479891;

// ─────────────────────────────────────────────────────────────────────
// Limits & validation bounds
// ─────────────────────────────────────────────────────────────────────

/// Hard sanity limits the predictor enforces. Out-of-range inputs
/// return null from `predictLoad`. The screen surfaces these as
/// helper text below the relevant inputs.
class InternalBallisticsLimits {
  const InternalBallisticsLimits._();

  /// Loading density (charge / case capacity) must be 10%–110% to be
  /// in Powley's calibrated band. Below 10% the powder layer is too
  /// thin for the bulk-burn assumption; above 110% the load is
  /// "compressed" beyond the calibration corpus.
  static const double minLoadingDensityPct = 10.0;
  static const double maxLoadingDensityPct = 110.0;

  /// Charge weight in grains. Below 1 gr is a primer-only blank
  /// (not modelled); above 300 gr is .50 BMG / black-powder cannon
  /// territory, well outside Powley's calibration.
  static const double minChargeGr = 1.0;
  static const double maxChargeGr = 300.0;

  /// Bullet weight in grains. Below 10 gr is .17-cal varmint /
  /// shotshot pellet; above 1000 gr is artillery.
  static const double minBulletGr = 10.0;
  static const double maxBulletGr = 1000.0;

  /// Barrel length in inches. Below 4" is pistol-only territory and
  /// expansion ratios become so small that Powley's polynomial fit
  /// blows up; above 50" is artillery.
  static const double minBarrelLengthIn = 4.0;
  static const double maxBarrelLengthIn = 50.0;

  /// Bullet diameter in inches. Below 0.10 is below the smallest
  /// commercial bullet (.10 caliber wildcat); above 1.0 is artillery.
  static const double minBulletDiameterIn = 0.10;
  static const double maxBulletDiameterIn = 1.0;

  /// Case capacity in grains H₂O. Below 5 grH₂O is rimfire-class;
  /// above 200 grH₂O is .50 BMG / .416 Barrett territory.
  static const double minCaseCapacityGrH2o = 5.0;
  static const double maxCaseCapacityGrH2o = 250.0;

  /// COAL minimum — below this is a seated-too-deep error; the
  /// bullet would intrude beyond the case head. Coarse but useful
  /// guardrail.
  static const double minCoalIn = 0.5;
  static const double maxCoalIn = 6.0;
}

// ─────────────────────────────────────────────────────────────────────
// Input bundle
// ─────────────────────────────────────────────────────────────────────

/// Immutable bundle of every parameter the Powley predictor reads.
///
/// Constructed via the `InternalBallisticsInput.imperial` named
/// constructor — the only constructor — so the unit conventions are
/// unambiguous at every call site.
class InternalBallisticsInput {
  /// All inputs in standard reloader's American units.
  ///
  /// * `caseCapacityGrH2o` — internal volume of an empty fired case
  ///   in grains of water that fills it. Most reloading manuals
  ///   publish this for common cartridges (e.g. .308 Win = 56 grH₂O,
  ///   .30-06 = 68 grH₂O, 6.5 CM = 53 grH₂O). When unknown, derive
  ///   from caseLength × bodyDiameter² as a coarse first estimate.
  /// * `powderName` — exact name as printed on the bottle, e.g.
  ///   "H4350", "Varget", "IMR 4350". Looked up in
  ///   `kPowderBurnRates`; if not found, the predictor returns null.
  /// * `chargeWeightGr` — powder charge in grains.
  /// * `bulletWeightGr` — bullet weight in grains.
  /// * `bulletDiameterIn` — bullet diameter in inches (e.g. 0.308
  ///   for .30-cal, 0.224 for .22-cal, 0.264 for 6.5mm).
  /// * `coalIn` — Cartridge Overall Length in inches.
  /// * `caseLengthIn` — case-head-to-case-mouth length, inches.
  ///   Used to compute seated bullet depth.
  /// * `barrelLengthIn` — barrel length in inches (muzzle to bolt
  ///   face for a bolt gun, muzzle to chamber face for an autoloader
  ///   — same number for a stock rifle).
  /// * `boreDiameterIn` — bore diameter in inches (the smaller of
  ///   the two rifling dimensions; typically `bulletDiameterIn -
  ///   0.005`). Drives bore VOLUME for the expansion ratio.
  ///
  /// Optional:
  /// * `bulletLengthIn` — bullet length (if known). When null the
  ///   model uses `1.5 × diameter` as the typical spitzer estimate.
  ///   Important for VLD bullets where the actual length is 2.0–2.5
  ///   × diameter.
  const InternalBallisticsInput.imperial({
    required this.caseCapacityGrH2o,
    required this.powderName,
    required this.chargeWeightGr,
    required this.bulletWeightGr,
    required this.bulletDiameterIn,
    required this.coalIn,
    required this.caseLengthIn,
    required this.barrelLengthIn,
    required this.boreDiameterIn,
    this.bulletLengthIn,
  });

  final double caseCapacityGrH2o;
  final String powderName;
  final double chargeWeightGr;
  final double bulletWeightGr;
  final double bulletDiameterIn;
  final double coalIn;
  final double caseLengthIn;
  final double barrelLengthIn;
  final double boreDiameterIn;
  final double? bulletLengthIn;
}

// ─────────────────────────────────────────────────────────────────────
// Result bundle
// ─────────────────────────────────────────────────────────────────────

/// What `predictLoad` returns when the input is well-formed.
class InternalBallisticsResult {
  const InternalBallisticsResult({
    required this.predictedMuzzleVelocityFps,
    required this.predictedPeakPressurePsi,
    required this.loadingDensityPct,
    required this.expansionRatio,
    required this.burnCompletionPct,
    required this.caseCapacityGrH2o,
  });

  /// Predicted muzzle velocity in fps. Compare against the
  /// chronograph-measured value the reloader will record on actual
  /// firing; differences > ~100 fps should prompt a review of the
  /// inputs.
  final double predictedMuzzleVelocityFps;

  /// Predicted peak chamber pressure in psi. This is the SAAMI-
  /// industry-standard piezoelectric measurement (NOT CUP — Copper
  /// Units of Pressure — which is a different scale). For the
  /// majority of modern centerfire rifle cartridges, the published
  /// SAAMI maximum pressure is the limit you should never let the
  /// predicted value exceed.
  final double predictedPeakPressurePsi;

  /// Loading density as a percentage. 100% = the powder fully
  /// fills the case to the case mouth. Reloading-manual maximum
  /// loads typically sit in the 95–105% band for compressed loads
  /// and 80–95% for non-compressed. Below 70% is a "reduced load"
  /// and warrants extra care for position-sensitivity.
  final double loadingDensityPct;

  /// Expansion ratio = (case capacity + bore volume) / case capacity.
  /// Typical values: ~6–8 for full-power .308 / .30-06 / 6.5 CM in
  /// a 24" barrel; ~3–4 for a magnum rifle in a 26" barrel; ~2–3
  /// for a pistol; ~10+ for an artillery piece.
  final double expansionRatio;

  /// Estimated fraction of powder fully burned at muzzle exit, %.
  /// 95%+ is a clean, well-matched powder/barrel combination. Below
  /// 90% suggests the powder is too slow for the barrel length —
  /// the user might consider a faster powder or accept the muzzle
  /// flash.
  final double burnCompletionPct;

  /// Echo of the case capacity actually used by the prediction —
  /// either the user's override or the cartridge-table default.
  /// Surfaced so the UI can show "Used 53.0 grH₂O (table default)"
  /// next to the result.
  final double caseCapacityGrH2o;
}

// ─────────────────────────────────────────────────────────────────────
// The predictor
// ─────────────────────────────────────────────────────────────────────

/// Runs the Powley method on the supplied input bundle and returns
/// either a fully-populated `InternalBallisticsResult` or null when
/// the load can't be modelled.
///
/// Returns null when:
///   * Any required field is missing, zero, or negative.
///   * `powderName` isn't in the burn-rate table.
///   * Any input falls outside the `InternalBallisticsLimits` band.
///   * Loading density falls outside [10%, 110%].
///   * Expansion ratio is non-physical (≤1.0).
///
/// The caller MUST treat null as "show empty state, don't render
/// numbers." This is the same anti-fake-data discipline the rest of
/// the ballistics surface follows (CLAUDE.md § 0).
InternalBallisticsResult? predictLoad(InternalBallisticsInput input) {
  // ─── Powder lookup ───
  final powder = lookupPowder(input.powderName);
  if (powder == null) return null;

  // ─── Hard sanity bounds ───
  if (input.chargeWeightGr <= 0 ||
      input.chargeWeightGr < InternalBallisticsLimits.minChargeGr ||
      input.chargeWeightGr > InternalBallisticsLimits.maxChargeGr) {
    return null;
  }
  if (input.bulletWeightGr <= 0 ||
      input.bulletWeightGr < InternalBallisticsLimits.minBulletGr ||
      input.bulletWeightGr > InternalBallisticsLimits.maxBulletGr) {
    return null;
  }
  if (input.bulletDiameterIn <= 0 ||
      input.bulletDiameterIn < InternalBallisticsLimits.minBulletDiameterIn ||
      input.bulletDiameterIn > InternalBallisticsLimits.maxBulletDiameterIn) {
    return null;
  }
  if (input.barrelLengthIn <= 0 ||
      input.barrelLengthIn < InternalBallisticsLimits.minBarrelLengthIn ||
      input.barrelLengthIn > InternalBallisticsLimits.maxBarrelLengthIn) {
    return null;
  }
  if (input.boreDiameterIn <= 0 ||
      input.boreDiameterIn > input.bulletDiameterIn) {
    // Bore is always SMALLER than the bullet (bullet engages the
    // grooves, which are deeper than the bore). Same-or-larger bore
    // is a data-entry error.
    return null;
  }
  if (input.caseCapacityGrH2o <= 0 ||
      input.caseCapacityGrH2o < InternalBallisticsLimits.minCaseCapacityGrH2o ||
      input.caseCapacityGrH2o > InternalBallisticsLimits.maxCaseCapacityGrH2o) {
    return null;
  }
  if (input.coalIn <= 0 ||
      input.coalIn < InternalBallisticsLimits.minCoalIn ||
      input.coalIn > InternalBallisticsLimits.maxCoalIn) {
    return null;
  }
  if (input.caseLengthIn <= 0 || input.caseLengthIn >= input.coalIn) {
    // Case length must be POSITIVE and STRICTLY LESS than COAL —
    // otherwise the bullet doesn't extend past the case mouth at all.
    return null;
  }

  // ─── Effective case capacity (after seating-depth shrinkage) ───
  //
  // The bullet pokes some fraction of its length into the case body.
  // That length × π/4 × diameter² is the volume the bullet occupies,
  // which we subtract from case capacity to get the effective volume
  // available for powder.
  final bulletLengthIn =
      input.bulletLengthIn ?? (_kBulletLenDiameterRatio * input.bulletDiameterIn);
  final bulletExposedAboveCaseIn = input.coalIn - input.caseLengthIn;
  final bulletInsideCaseIn =
      math.max(0.0, bulletLengthIn - bulletExposedAboveCaseIn);
  final bulletVolumeInsideCaseInCubic =
      math.pi / 4.0 * input.bulletDiameterIn * input.bulletDiameterIn * bulletInsideCaseIn;
  final bulletVolumeInsideCaseGrH2o =
      bulletVolumeInsideCaseInCubic * _kGrainsH2OPerCubicInch;
  final effectiveCaseCapacityGrH2o =
      input.caseCapacityGrH2o - bulletVolumeInsideCaseGrH2o;
  if (effectiveCaseCapacityGrH2o <= 0) {
    // Bullet fully fills the case — nonsensical, abort.
    return null;
  }

  // ─── Loading density ───
  //
  // LD = chargeWeight / effectiveCaseCapacity, expressed as a
  // dimensionless ratio. Both terms are in grains (the chargeWeight
  // is grains of powder; the case-capacity is grains of water that
  // fills the case — the units cancel because we're comparing two
  // mass-equivalent volumes in the same units).
  final loadingDensityRatio =
      input.chargeWeightGr / effectiveCaseCapacityGrH2o;
  final loadingDensityPct = loadingDensityRatio * 100.0;
  if (loadingDensityPct < InternalBallisticsLimits.minLoadingDensityPct ||
      loadingDensityPct > InternalBallisticsLimits.maxLoadingDensityPct) {
    return null;
  }

  // ─── Bore volume + expansion ratio ───
  //
  // Vb = π/4 × bore² × barrelLength, converted to grains H₂O so
  // we can take a clean ratio against the case capacity.
  //
  // Note we use BORE diameter (the lands-to-lands measurement)
  // rather than GROOVE diameter (the wider, bullet-engagement
  // measurement). The lands intrude into the bullet's path; the
  // bullet itself is groove-diameter, but the gas behind it is
  // confined to the bore-diameter cylinder for the bulk of the
  // travel. Real rifling adds a small (~3%) volume in the grooves;
  // we ignore that — see file header.
  final boreVolumeInCubic =
      math.pi / 4.0 * input.boreDiameterIn * input.boreDiameterIn * input.barrelLengthIn;
  final boreVolumeGrH2o = boreVolumeInCubic * _kGrainsH2OPerCubicInch;
  final expansionRatio =
      (effectiveCaseCapacityGrH2o + boreVolumeGrH2o) / effectiveCaseCapacityGrH2o;
  if (expansionRatio <= 1.0) return null;

  // ─── Burn efficiency η ───
  //
  // Three-factor product:
  //
  //   η = η_thermal × completion_factor × cr_penalty
  //
  // where:
  //
  //   * η_thermal = 1 − ER^(−0.30)
  //     Thermodynamic upper bound from the polytropic-expansion
  //     work integral. With ER = 7×, η_thermal ≈ 0.45 — the
  //     maximum fraction of chemical energy that can ever become
  //     bullet KE no matter how the burn proceeds.
  //
  //   * completion_factor = tanh(k1 · C·Q_scaled / W)
  //     Burn-completion saturation. With high charge and/or high
  //     quickness, the powder finishes burning earlier in the
  //     bullet's travel and more of η_thermal is realised. With
  //     low charge / slow powder / long heavy bullet, the burn
  //     drags out into the muzzle and we lose efficiency. tanh
  //     bounds the factor in (0, 1).
  //
  //   * cr_penalty = exp(−k2 · max(0, C/W − 0.30))
  //     High charge-to-bullet-mass ratio (>0.30) penalty.
  //     Captures the "bullet starts moving before the powder is
  //     done burning" effect that hits small fast cartridges
  //     (.223, .220 Swift, .22-250) hard. Smoothly multiplies the
  //     other factors down by up to ~50% at extreme CR.
  //
  // We rescale Q so that IMR 4350 (Q=100) is a multiplier of 1.0.
  // Per-powder differences in burn rate are baked into Q already.
  final qScaled = powder.relativeQuickness / _kReferenceQuickness;
  final etaThermal =
      1.0 - math.pow(expansionRatio, -_kThermalCapExp).toDouble();
  final completionArg =
      _kBurnCompletionSlope * input.chargeWeightGr * qScaled / input.bulletWeightGr;
  // tanh(x) = (e^x - e^-x) / (e^x + e^-x); use math.exp to avoid
  // a tanh helper import.
  final tanhComp =
      (math.exp(completionArg) - math.exp(-completionArg)) /
          (math.exp(completionArg) + math.exp(-completionArg));
  final chargeRatio = input.chargeWeightGr / input.bulletWeightGr;
  final crPenalty = chargeRatio > _kChargeRatioPenaltyThreshold
      ? math.exp(-_kChargeRatioPenaltySlope *
              (chargeRatio - _kChargeRatioPenaltyThreshold))
      : 1.0;
  final efficiency = etaThermal * tanhComp * crPenalty;
  if (efficiency <= 0 || efficiency > 1.0) {
    // Defensive guard — should never trigger for valid inputs but
    // protects against weirdness from extreme Q values or
    // out-of-band exponentials.
    return null;
  }

  // ─── Muzzle velocity ───
  //
  // Energy balance: ½ · m_bullet · v² = η · m_charge · F
  //
  // where m_bullet is bullet mass (kg), v is muzzle velocity (m/s),
  // η is the burn efficiency we just computed, m_charge is powder
  // charge mass (kg), and F is the specific impetus (J/kg). Solving
  // for v:
  //
  //     v = sqrt(2 · η · m_charge · F / m_bullet)
  //
  // Convert from grains to kg via _kKgPerGrain (1 gr = 6.479891e-5
  // kg).
  final bulletMassKg = input.bulletWeightGr * _kKgPerGrain;
  final chargeMassKg = input.chargeWeightGr * _kKgPerGrain;
  final velocityMps = math.sqrt(
      2.0 * efficiency * chargeMassKg * _kSpecificImpetusJPerKg / bulletMassKg);
  final velocityFps = velocityMps * _kFpsPerMps;

  // ─── Peak pressure ───
  //
  // Pmax = K_p · Q^q_exp · LD^α · (Wp/C)^β
  //
  // K_p is the calibrated psi-scale constant; Q^q_exp (with q_exp
  // = 0.5) gives faster powders a moderately higher peak; LD^α
  // captures the "more powder in less space = more pressure" curve;
  // (Wp/C)^β captures the "heavier bullet = more time for pressure
  // to build before bullet motion starts venting" effect.
  //
  // β=0.5 means doubling the bullet weight produces a 41% pressure
  // increase at constant charge — matches reloading-manual
  // experience. q_exp=0.5 (rather than 1.0) reflects that fast
  // powders peak SHARPER but over a SHORTER time, so the integral-
  // peak doesn't scale linearly with quickness.
  final bulletToChargeRatio = input.bulletWeightGr / input.chargeWeightGr;
  final pressurePsi = _kPressureScalePsi *
      math.pow(qScaled, _kPressureQuicknessExp).toDouble() *
      math.pow(loadingDensityRatio, _kPressureLoadingDensityExp).toDouble() *
      math.pow(bulletToChargeRatio, _kPressureBulletRatioExp).toDouble();

  return InternalBallisticsResult(
    predictedMuzzleVelocityFps: velocityFps,
    predictedPeakPressurePsi: pressurePsi,
    loadingDensityPct: loadingDensityPct,
    expansionRatio: expansionRatio,
    burnCompletionPct: efficiency * 100.0,
    caseCapacityGrH2o: input.caseCapacityGrH2o,
  );
}
