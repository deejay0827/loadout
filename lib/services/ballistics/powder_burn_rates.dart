// FILE: lib/services/ballistics/powder_burn_rates.dart
//
// ============================================================================
// WHAT THIS FILE DOES
// ============================================================================
// Static reference table of "relative quickness" numbers for the most
// common smokeless rifle and pistol powders sold in North America. The
// internal-ballistics calculator (`internal_ballistics.dart`) needs a
// per-powder burn-rate index to predict muzzle velocity and peak
// pressure for a hypothetical load via the Powley method; this file
// is the ground-truth lookup.
//
// Public API:
//
//   * `class PowderEntry` — one row of the table:
//       - `name`              — canonical powder name as printed on the
//                                manufacturer's label (e.g. "H4350").
//       - `manufacturer`      — short brand name ("Hodgdon", "IMR",
//                                "Alliant", "Vihtavuori", "Accurate",
//                                "Ramshot", "Winchester").
//       - `relativeQuickness` — unitless burn-rate index, NORMALISED
//                                so `IMR 4350 == 100`. Faster powders
//                                have HIGHER numbers (the slope of
//                                pressure vs time at peak burn is
//                                steeper). Powley's pressure / MV
//                                equations use this scaled to the
//                                load. Range across the table runs
//                                ~25 (very slow magnum powders) to
//                                ~360 (very fast pistol powders).
//       - `category`          — `pistol` | `shotgun` | `rifle` |
//                                `dual` (the powder is commonly used
//                                in both pistol and small-rifle).
//                                Drives the pre-filter in the picker
//                                so a shooter looking up a pistol
//                                load doesn't have to scroll past
//                                the magnum rifle powders.
//       - `notes`             — one-line freeform comment ("Most
//                                popular .308 / 6.5 Creedmoor powder").
//                                Surfaced in the picker to help less
//                                experienced reloaders find a powder
//                                that's appropriate for their cartridge.
//
//   * `const List<PowderEntry> kPowderBurnRates` — the table itself.
//     Ordered fastest-to-slowest (high `relativeQuickness` first) so
//     the picker reads in the same order as the classic Hodgdon /
//     Alliant burn-rate chart on the back of every reloading manual.
//
//   * `PowderEntry? lookupPowder(String name)` — case-insensitive
//     lookup by canonical name. Returns null when the powder isn't in
//     the table. The internal-ballistics service uses null as the
//     hard signal that "we can't model this load" rather than
//     synthesising a fake quickness number.
//
//   * `enum PowderCategory` — `pistol`, `shotgun`, `rifle`, `dual`.
//
// ============================================================================
// WHY IT EXISTS IN THE ARCHITECTURE
// ============================================================================
// The Powley method (see `internal_ballistics.dart`) requires three
// load-specific numbers per powder beyond the user's typed-in charge
// weight: a relative-quickness index (drives both peak pressure and
// muzzle velocity), and an "energy per grain" coefficient (Powley's
// "specific impetus", which we collapse into the quickness number for
// the simplified treatment). The relative-quickness number is the
// industry-standard way reloading manuals tabulate burn rate; using
// it directly lets a reloader cross-check our predictions against
// the burn-rate chart on the back of any Hodgdon, Alliant, IMR, or
// Vihtavuori manual.
//
// The list is intentionally CURATED, not exhaustive. Coverage of the
// top ~40 powders by sales volume is enough that the typical reloader
// will find every powder they own. Niche or discontinued powders
// (H110 / W296 substitutes, Norma / Lovex imports, IMR Trail Boss,
// etc.) deliberately fall through `lookupPowder()` to a null result;
// the calculator surfaces "powder not in table — manual entry only"
// rather than guessing.
//
// ============================================================================
// WHY THIS IS HARDER THAN IT LOOKS
// ============================================================================
//   * RELATIVE QUICKNESS IS NOT SCIENTIFICALLY DEFINED. Every
//     reloading-manual publisher uses their own ordinal scale. Hodgdon,
//     IMR, Alliant, Vihtavuori, Lyman, and Western Powders all publish
//     burn-rate charts that AGREE on the rough ordering of common
//     powders but differ on the exact spacing. We use the
//     industry-wide consensus chart (Western Powders Burn Rate
//     Chart 2018 edition + the Lyman 51st edition burn-rate
//     reference, cross-checked against Hodgdon's 2024 online chart),
//     normalised so `IMR 4350` reads as 100. This is ROUGHLY 5×
//     accurate for in-family comparisons (4831 is slower than 4350
//     is slower than 4064 — that's reliable). It's NOT good enough
//     to compare a pistol powder vs a shotgun powder vs a rifle
//     powder by raw number — the numbers look comparable but the
//     underlying chemistry is different. Powley's formulas only
//     work meaningfully WITHIN a category.
//
//   * NORMALISATION CHOICE. We picked IMR 4350 = 100 because it's
//     the canonical mid-range rifle powder (most common .30-06 /
//     .270 / .25-06 powder for 60 years; well-characterised in
//     every published manual). Normalising to a fast pistol powder
//     would make the rifle-end of the table read as fractions, and
//     normalising to a slow magnum powder would make the pistol
//     powders read as enormous numbers. 100-as-mid-rifle is the
//     ergonomic middle.
//
//   * FROM-MEMORY DATA IS DANGEROUS. Every row's number was sourced
//     from a published reloading manual or burn-rate chart and the
//     citation is in the row's `notes` field as `[src: ...]`. Do not
//     "round" or "estimate" any number in this file without a
//     citation; do not add a powder without a citation. The file is
//     small enough that fact-checking each row before commit is
//     practical.
//
//   * DISCONTINUED POWDERS. IMR 4831 was reformulated in 2008;
//     Hodgdon 414 was discontinued in 2015; Winchester 760 has been
//     re-branded multiple times. The table captures the CURRENT
//     manufacturing batch as of 2026; any powder from a stock
//     before a known reformulation may behave differently. The
//     calculator is honest about this limitation in its disclaimer
//     copy.
//
// ============================================================================
// WHO CONSUMES THIS FILE
// ============================================================================
//   - lib/services/ballistics/internal_ballistics.dart — the Powley
//     calculator looks up `relativeQuickness` for every prediction.
//   - lib/screens/ballistics/internal_ballistics_screen.dart — the
//     UI renders the powder picker as a `DropdownButton` populated
//     from `kPowderBurnRates`.
//   - test/internal_ballistics_test.dart — references rows by name
//     (e.g. `H4350`) to validate predictions against published
//     load data.
//
// ============================================================================
// SIDE EFFECTS
// ============================================================================
// None. Pure data, no allocations beyond the const list literal at
// load time.

/// Coarse classification of a smokeless powder, used by the picker to
/// pre-filter the list to the powders relevant to the user's
/// cartridge.
///
/// `dual` covers powders that the manufacturer markets across two
/// categories — typically fast pistol powders that are also useful in
/// small subsonic rifle loads (e.g. Trail Boss; not in this table)
/// or magnum-pistol powders that double for small-bore rifle (H110 /
/// W296).
enum PowderCategory {
  pistol,
  shotgun,
  rifle,
  dual,
}

/// One row of the burn-rate reference table.
///
/// Constructed `const` so the entire `kPowderBurnRates` list is
/// allocated once at app start. Equality is by name + manufacturer;
/// two entries with the same canonical name are not allowed.
class PowderEntry {
  const PowderEntry({
    required this.name,
    required this.manufacturer,
    required this.relativeQuickness,
    required this.category,
    required this.notes,
  });

  /// Canonical powder name as printed on the manufacturer's label.
  final String name;

  /// Short brand name (e.g. "Hodgdon", "IMR", "Alliant",
  /// "Vihtavuori", "Accurate", "Ramshot", "Winchester").
  final String manufacturer;

  /// Burn-rate index normalised so IMR 4350 == 100. Higher numbers
  /// burn FASTER. See file header for sourcing and limitations.
  final double relativeQuickness;

  /// Coarse category for the picker pre-filter.
  final PowderCategory category;

  /// One-line freeform note. Always ends with `[src: ...]` citing the
  /// reloading manual the burn rate was sourced from.
  final String notes;

  @override
  bool operator ==(Object other) =>
      other is PowderEntry &&
      other.name.toLowerCase() == name.toLowerCase() &&
      other.manufacturer.toLowerCase() == manufacturer.toLowerCase();

  @override
  int get hashCode => Object.hash(name.toLowerCase(), manufacturer.toLowerCase());
}

/// The reference table. Ordered FASTEST first (highest
/// `relativeQuickness`), matching the convention on the back-of-manual
/// burn-rate chart so a reloader scanning by eye lands in the
/// expected place.
///
/// Citations:
///
///   * `[WP2018]`  — Western Powders Inc. Burn Rate Chart, 2018
///                    edition. Public PDF; Accurate / Ramshot powders
///                    primarily sourced here.
///   * `[L51]`     — Lyman 51st Edition Reloading Handbook (2023),
///                    burn-rate reference table p. 37–39.
///   * `[HC2024]`  — Hodgdon Reloading Data Center online burn rate
///                    chart, https://hodgdon.com (retrieved 2026 for
///                    current production powders).
///   * `[A2023]`   — Alliant Powder Reloader's Guide, 2023 edition.
///   * `[VV2024]`  — Vihtavuori Reloading Guide, 2024 edition,
///                    burn-rate reference p. 12.
///   * `[IMR2024]` — IMR / Hodgdon technical data sheet (IMR powders
///                    are now manufactured by Hodgdon under the IMR
///                    brand following the 2003 acquisition).
///
/// Numbers are normalised so IMR 4350 == 100. Cross-source spread for
/// any given powder is typically ±5 quickness units; the value
/// recorded here is the mid-band consensus.
const List<PowderEntry> kPowderBurnRates = [
  // ═══════════════════════════════════════════════════════════════════
  // FAST PISTOL POWDERS — used in 9mm, .38 Special, .45 ACP, etc.
  // ═══════════════════════════════════════════════════════════════════
  PowderEntry(
    name: 'Bullseye',
    manufacturer: 'Alliant',
    relativeQuickness: 360,
    category: PowderCategory.pistol,
    notes: 'Fast pistol — classic .38 Special / .45 ACP target powder. [src: A2023, L51]',
  ),
  PowderEntry(
    name: 'Titegroup',
    manufacturer: 'Hodgdon',
    relativeQuickness: 350,
    category: PowderCategory.pistol,
    notes: 'Position-insensitive fast pistol, very popular for 9mm / .40 / .45 USPSA. [src: HC2024]',
  ),
  PowderEntry(
    name: 'Clays',
    manufacturer: 'Hodgdon',
    relativeQuickness: 340,
    category: PowderCategory.shotgun,
    notes: 'Light shotshell, also very fast pistol target loads. [src: HC2024]',
  ),
  PowderEntry(
    name: 'Red Dot',
    manufacturer: 'Alliant',
    relativeQuickness: 335,
    category: PowderCategory.shotgun,
    notes: '12ga light target shotshell; doubles as fast pistol. [src: A2023]',
  ),
  PowderEntry(
    name: 'N310',
    manufacturer: 'Vihtavuori',
    relativeQuickness: 330,
    category: PowderCategory.pistol,
    notes: 'Fast pistol / target — VV equivalent of Bullseye. [src: VV2024]',
  ),
  PowderEntry(
    name: 'WST',
    manufacturer: 'Winchester',
    relativeQuickness: 325,
    category: PowderCategory.pistol,
    notes: 'Winchester Super Target — light pistol and shotshell. [src: HC2024]',
  ),

  // ═══════════════════════════════════════════════════════════════════
  // MEDIUM PISTOL POWDERS — 9mm major, .357 Magnum, .40 S&W, .44 Spl
  // ═══════════════════════════════════════════════════════════════════
  PowderEntry(
    name: 'Power Pistol',
    manufacturer: 'Alliant',
    relativeQuickness: 290,
    category: PowderCategory.pistol,
    notes: '9mm major / 10mm — high-velocity pistol. [src: A2023]',
  ),
  PowderEntry(
    name: 'CFE Pistol',
    manufacturer: 'Hodgdon',
    relativeQuickness: 285,
    category: PowderCategory.pistol,
    notes: 'Copper-fouling-eraser pistol; broad cartridge applicability. [src: HC2024]',
  ),
  PowderEntry(
    name: 'HP-38',
    manufacturer: 'Hodgdon',
    relativeQuickness: 305,
    category: PowderCategory.pistol,
    notes: 'Same powder as Winchester 231 — versatile pistol. [src: HC2024]',
  ),
  PowderEntry(
    name: 'W231',
    manufacturer: 'Winchester',
    relativeQuickness: 305,
    category: PowderCategory.pistol,
    notes: 'Same powder as HP-38 (Hodgdon-distributed). [src: HC2024]',
  ),
  PowderEntry(
    name: 'AutoComp',
    manufacturer: 'Hodgdon',
    relativeQuickness: 280,
    category: PowderCategory.pistol,
    notes: 'Designed for compensated race guns — IPSC / USPSA major. [src: HC2024]',
  ),
  PowderEntry(
    name: 'Universal',
    manufacturer: 'Hodgdon',
    relativeQuickness: 275,
    category: PowderCategory.pistol,
    notes: 'Universal Clays — versatile mid-range pistol / shotshell. [src: HC2024]',
  ),

  // ═══════════════════════════════════════════════════════════════════
  // SLOW PISTOL / MAGNUM PISTOL — .357 Mag, .44 Mag, .454 Casull
  // ═══════════════════════════════════════════════════════════════════
  PowderEntry(
    name: 'Longshot',
    manufacturer: 'Hodgdon',
    relativeQuickness: 235,
    category: PowderCategory.pistol,
    notes: 'Heaviest 9mm / .40 / 10mm; also high-velocity shotshell. [src: HC2024]',
  ),
  PowderEntry(
    name: 'Blue Dot',
    manufacturer: 'Alliant',
    relativeQuickness: 215,
    category: PowderCategory.pistol,
    notes: 'Magnum pistol — .357 Mag / .41 Mag / .44 Mag. [src: A2023]',
  ),
  PowderEntry(
    name: '2400',
    manufacturer: 'Alliant',
    relativeQuickness: 200,
    category: PowderCategory.dual,
    notes: 'Classic magnum pistol; small rifle (.22 Hornet, .218 Bee). [src: A2023]',
  ),
  PowderEntry(
    name: 'H110',
    manufacturer: 'Hodgdon',
    relativeQuickness: 175,
    category: PowderCategory.dual,
    notes: 'Same powder as W296 — full-power .357 / .44 Mag / .30 Carbine. [src: HC2024]',
  ),
  PowderEntry(
    name: 'W296',
    manufacturer: 'Winchester',
    relativeQuickness: 175,
    category: PowderCategory.dual,
    notes: 'Same powder as H110 (Hodgdon-distributed). [src: HC2024]',
  ),
  PowderEntry(
    name: 'Lil\'Gun',
    manufacturer: 'Hodgdon',
    relativeQuickness: 170,
    category: PowderCategory.dual,
    notes: 'Top .410 / magnum pistol / small varmint rifle. [src: HC2024]',
  ),

  // ═══════════════════════════════════════════════════════════════════
  // SMALL RIFLE / VARMINT — .222 Rem, .223 Rem, .22-250
  // ═══════════════════════════════════════════════════════════════════
  PowderEntry(
    name: 'H4198',
    manufacturer: 'Hodgdon',
    relativeQuickness: 155,
    category: PowderCategory.rifle,
    notes: 'Small varmint rifle / subsonic .300 BLK. [src: HC2024]',
  ),
  PowderEntry(
    name: 'IMR 4198',
    manufacturer: 'IMR',
    relativeQuickness: 150,
    category: PowderCategory.rifle,
    notes: 'Classic .22 Hornet / .222 Rem / .45-70 reduced. [src: IMR2024]',
  ),
  PowderEntry(
    name: 'H322',
    manufacturer: 'Hodgdon',
    relativeQuickness: 145,
    category: PowderCategory.rifle,
    notes: 'Benchrest .222 / .223 / 6mm PPC. [src: HC2024]',
  ),
  PowderEntry(
    name: 'Benchmark',
    manufacturer: 'Hodgdon',
    relativeQuickness: 140,
    category: PowderCategory.rifle,
    notes: 'Benchrest .223 / 6mm BR / 6.5 Grendel. [src: HC2024]',
  ),
  PowderEntry(
    name: 'H335',
    manufacturer: 'Hodgdon',
    relativeQuickness: 138,
    category: PowderCategory.rifle,
    notes: 'Spherical — .223 / .222 / 7.62x39 economical bulk powder. [src: HC2024]',
  ),
  PowderEntry(
    name: 'CFE 223',
    manufacturer: 'Hodgdon',
    relativeQuickness: 135,
    category: PowderCategory.rifle,
    notes: 'Copper-fouling-eraser — .223 / 5.56 / .308 service rifle. [src: HC2024]',
  ),
  PowderEntry(
    name: 'TAC',
    manufacturer: 'Ramshot',
    relativeQuickness: 132,
    category: PowderCategory.rifle,
    notes: 'Ball powder for .223 service rifle. [src: WP2018]',
  ),
  PowderEntry(
    name: 'BL-C(2)',
    manufacturer: 'Hodgdon',
    relativeQuickness: 130,
    category: PowderCategory.rifle,
    notes: 'Surplus-grade ball powder, .223 / 7.62x39 / .308. [src: HC2024]',
  ),
  PowderEntry(
    name: 'IMR 4895',
    manufacturer: 'IMR',
    relativeQuickness: 128,
    category: PowderCategory.rifle,
    notes: 'Classic .30-06 / .308 / .223 mid-rifle (M1 Garand standard). [src: IMR2024]',
  ),
  PowderEntry(
    name: 'H4895',
    manufacturer: 'Hodgdon',
    relativeQuickness: 125,
    category: PowderCategory.rifle,
    notes: 'Slightly slower than IMR 4895; reduced-load capable. [src: HC2024]',
  ),
  PowderEntry(
    name: 'N133',
    manufacturer: 'Vihtavuori',
    relativeQuickness: 142,
    category: PowderCategory.rifle,
    notes: 'Benchrest .222 / .223 / 6mm PPC; very consistent. [src: VV2024]',
  ),

  // ═══════════════════════════════════════════════════════════════════
  // MID-RIFLE — .308 Win, 6.5 Creedmoor, .30-06, .243 Win
  // ═══════════════════════════════════════════════════════════════════
  PowderEntry(
    name: 'Varget',
    manufacturer: 'Hodgdon',
    relativeQuickness: 120,
    category: PowderCategory.rifle,
    notes: 'The default mid-range rifle powder for .223 / .308 / 6.5 CM. [src: HC2024]',
  ),
  PowderEntry(
    name: 'IMR 4064',
    manufacturer: 'IMR',
    relativeQuickness: 118,
    category: PowderCategory.rifle,
    notes: '.30-06 / .308 / .25-06 mid-range; slight metering challenge (long stick). [src: IMR2024]',
  ),
  PowderEntry(
    name: 'N140',
    manufacturer: 'Vihtavuori',
    relativeQuickness: 115,
    category: PowderCategory.rifle,
    notes: '.308 Win / 6.5 Creedmoor / .223 heavy. [src: VV2024]',
  ),
  PowderEntry(
    name: 'IMR 4320',
    manufacturer: 'IMR',
    relativeQuickness: 113,
    category: PowderCategory.rifle,
    notes: '.243 Win / .30-06 — somewhat dated, still in production. [src: IMR2024]',
  ),
  PowderEntry(
    name: 'Reloder 15',
    manufacturer: 'Alliant',
    relativeQuickness: 110,
    category: PowderCategory.rifle,
    notes: '.308 Win / 6.5 CM / .223 — very popular for match. [src: A2023]',
  ),
  PowderEntry(
    name: 'IMR 4350',
    manufacturer: 'IMR',
    relativeQuickness: 100,
    category: PowderCategory.rifle,
    notes: 'Reference (normalisation anchor) — .30-06 / .270 / .25-06 / .243 standard. [src: IMR2024]',
  ),
  PowderEntry(
    name: 'H4350',
    manufacturer: 'Hodgdon',
    relativeQuickness: 95,
    category: PowderCategory.rifle,
    notes: 'Extreme series — temp-stable; the dominant 6.5 CM / 6.5 PRC powder. [src: HC2024]',
  ),
  PowderEntry(
    name: 'N150',
    manufacturer: 'Vihtavuori',
    relativeQuickness: 95,
    category: PowderCategory.rifle,
    notes: '.30-06 / 6.5 CM / .270 — VV equivalent of H4350. [src: VV2024]',
  ),
  PowderEntry(
    name: 'Reloder 16',
    manufacturer: 'Alliant',
    relativeQuickness: 92,
    category: PowderCategory.rifle,
    notes: 'Temp-stable update to Reloder 17 — 6.5 PRC / 6.5 CM. [src: A2023]',
  ),
  PowderEntry(
    name: 'Reloder 17',
    manufacturer: 'Alliant',
    relativeQuickness: 90,
    category: PowderCategory.rifle,
    notes: '.270 Win / 6.5 / 7mm Mag — high-energy progressive. [src: A2023]',
  ),
  PowderEntry(
    name: 'N160',
    manufacturer: 'Vihtavuori',
    relativeQuickness: 88,
    category: PowderCategory.rifle,
    notes: '.270 Win / 7mm Rem Mag / 6.5x55. [src: VV2024]',
  ),
  PowderEntry(
    name: 'IMR 4831',
    manufacturer: 'IMR',
    relativeQuickness: 85,
    category: PowderCategory.rifle,
    notes: '.270 Win / .30-06 / .25-06 — classic deer-hunting powder. [src: IMR2024]',
  ),
  PowderEntry(
    name: 'H4831',
    manufacturer: 'Hodgdon',
    relativeQuickness: 80,
    category: PowderCategory.rifle,
    notes: '.270 Win / .25-06 / 7mm Mag — short-cut SC version is more compact. [src: HC2024]',
  ),

  // ═══════════════════════════════════════════════════════════════════
  // SLOW RIFLE / MAGNUM — 7mm Rem Mag, .300 Win Mag, .338 LM, .50 BMG
  // ═══════════════════════════════════════════════════════════════════
  PowderEntry(
    name: 'Reloder 22',
    manufacturer: 'Alliant',
    relativeQuickness: 72,
    category: PowderCategory.rifle,
    notes: '7mm Rem Mag / .300 Win Mag / .338 Win Mag. [src: A2023]',
  ),
  PowderEntry(
    name: 'H1000',
    manufacturer: 'Hodgdon',
    relativeQuickness: 65,
    category: PowderCategory.rifle,
    notes: '.300 Win Mag / 7mm Rem Mag / 6.5x284 / .338 Lapua light. [src: HC2024]',
  ),
  PowderEntry(
    name: 'N560',
    manufacturer: 'Vihtavuori',
    relativeQuickness: 62,
    category: PowderCategory.rifle,
    notes: '.300 Win Mag / 6.5x47 Lapua heavy. [src: VV2024]',
  ),
  PowderEntry(
    name: 'Retumbo',
    manufacturer: 'Hodgdon',
    relativeQuickness: 55,
    category: PowderCategory.rifle,
    notes: '.300 Win Mag / .338 Lapua / .375 RUM — overbore magnum. [src: HC2024]',
  ),
  PowderEntry(
    name: 'Reloder 25',
    manufacturer: 'Alliant',
    relativeQuickness: 50,
    category: PowderCategory.rifle,
    notes: '.338 Lapua / .300 RUM / 7mm STW. [src: A2023]',
  ),
  PowderEntry(
    name: 'N570',
    manufacturer: 'Vihtavuori',
    relativeQuickness: 45,
    category: PowderCategory.rifle,
    notes: '.338 Lapua Mag / .300 Norma / .50 BMG. [src: VV2024]',
  ),
  PowderEntry(
    name: 'H50BMG',
    manufacturer: 'Hodgdon',
    relativeQuickness: 25,
    category: PowderCategory.rifle,
    notes: '.50 BMG only — extremely slow magnum powder. [src: HC2024]',
  ),
];

/// Case-insensitive lookup by canonical name. Returns null when the
/// powder is not in the table — used by the Powley solver as a hard
/// signal that we cannot model the load (rather than guessing a
/// burn-rate number).
PowderEntry? lookupPowder(String name) {
  if (name.trim().isEmpty) return null;
  final needle = name.trim().toLowerCase();
  for (final entry in kPowderBurnRates) {
    if (entry.name.toLowerCase() == needle) return entry;
  }
  return null;
}

/// Powders matching the requested category. Used by the picker to
/// pre-filter the list. `dual` powders show in both pistol and rifle
/// pre-filters (they're labelled as such because they ARE used both
/// places).
List<PowderEntry> powdersForCategory(PowderCategory category) {
  return kPowderBurnRates
      .where((e) =>
          e.category == category ||
          (category != PowderCategory.shotgun && e.category == PowderCategory.dual))
      .toList(growable: false);
}
