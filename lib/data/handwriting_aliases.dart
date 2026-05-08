// FILE: lib/data/handwriting_aliases.dart
//
// ============================================================================
// WHAT THIS FILE DOES
// ============================================================================
// Handwriting / shorthand alias dictionary used by `RecipeParser` to bridge
// the gap between what reloaders WRITE in their notebooks and what the
// reference catalog stores. Three public maps:
//
//   - `kPowderHandwritingAliases` — powder name shorthand. "H4350" / "h
//     4350" / "H 4350" / "Hodgdon 4350" all resolve to canonical "H4350".
//     "RL16" / "RL-16" / "R-L 16" / "Reloder 16" / "Re16" all resolve to
//     "Reloder 16". 50+ entries covering Hodgdon, IMR, Alliant, Vihtavuori,
//     Norma, Accurate, Ramshot, Western, Winchester.
//   - `kBulletHandwritingAliases` — bullet abbreviation map. "ELDM" /
//     "ELD-M" / "ELD M" / "ELD Match" all resolve to canonical "ELD-M".
//     Common families: ELD-M, ELD-X, A-Tip, SST, V-MAX, MatchKing (SMK),
//     Tipped MatchKing (TMK), Berger Hybrid (VLD), Berger Match Hybrid
//     Target (MHT), Nosler Ballistic Tip (BT), Accubond (AB), partition
//     (NPT), TSX, TTSX, TMK, GameKing (SGK), Pro-Hunter, A-MAX,
//     Hyb / Hyb Tgt, BTHP, FMJ, JHP.
//   - `kCaliberHandwritingAliases` — caliber alias map. ".308" / "308" /
//     ".308 W" / ".308 Win" / "308 Win" / "7.62x51" / "7.62 NATO" all
//     resolve to ".308 Winchester". Same pattern for the 30+ most common
//     reloading cartridges.
//
// All lookups are case-insensitive: callers should `.toLowerCase()` both
// sides before matching. The values are CANONICAL names (the form the
// catalog stores). The keys are everything users actually scribble.
//
// One helper, `expandHandwritingTokens(line)`, normalizes a single OCR
// line and returns the union of canonical hits found in it. Used by the
// parser to bridge between the alias maps and its catalog-driven matchers.
//
// ============================================================================
// WHY IT EXISTS IN THE ARCHITECTURE
// ============================================================================
// The launch survey says 66% of reloaders track loads in pen-and-paper
// notebooks. The photo-import flow is the conversion path for that cohort.
// The recipe parser already had a small abbreviation map embedded inline,
// but expanding it mid-method would have buried the heuristic logic. By
// pulling the shorthand dictionary out into its own module:
//
//   1. The data is easy to grow — anyone adding a new powder line drops
//      a row into one place; no parser code changes.
//   2. The maps are unit-testable in isolation (see
//      `test/handwriting_aliases_test.dart`).
//   3. Translators / power users can submit additions without learning
//      the parser internals.
//
// ============================================================================
// WHY THIS IS HARDER THAN IT LOOKS
// ============================================================================
// 1. **Cursive-OCR collisions.** ML Kit transposes "I" / "1" / "l", "0"
//    / "O", "5" / "S", "8" / "B". Each row in the alias map should
//    survive the most likely transposition, so common variants like
//    "H4350" must coexist with "H435O" (zero-vs-O), "H435O" (oh-vs-zero),
//    and "H43SO" (S-for-five). We DO NOT enumerate every transposition —
//    that explodes combinatorially. Instead we add the highest-frequency
//    misreads we've observed in QA + the user-friendly shorthands.
//
// 2. **Word boundaries matter.** A naive `contains` for "H1" would match
//    "H1000" AND "H1100" AND "H110" AND any number starting with "H1".
//    The parser already filters with `\b` regexes; this file just
//    provides the keys. The parser is responsible for deciding the
//    longest-match wins.
//
// 3. **Ambiguous abbreviations.** "BT" is "Ballistic Tip" (Nosler) AND
//    "Boat Tail" (used as a generic shape). When two canonical mappings
//    are plausible we prefer the more specific one ("Ballistic Tip") and
//    let the parser fall back to the descriptor in the bullet line if
//    the catalog doesn't have a Nosler BT match.
//
// 4. **Caliber aliases include both ".308" and "308".** Users write
//    both. The parser's `_findCaliber` already strips leading dots, so
//    we list the dotted form once and rely on the parser to normalize.
//    For pure-number designators ("6.5 PRC", "6.5 CM") the dotted form
//    is the canonical and there is no leading-dot variant.
//
// ============================================================================
// WHO CONSUMES THIS FILE
// ============================================================================
// - lib/services/recipe_parser.dart — looks up tokens against these maps
//   when the OCR text doesn't directly hit a catalog entry.
// - test/handwriting_aliases_test.dart — sanity checks the dictionary
//   shape and the helper.
//
// ============================================================================
// SIDE EFFECTS
// ============================================================================
// None. Pure const data + one pure helper.

/// Powder name handwriting / shorthand → canonical catalog name.
///
/// Keys are case-insensitive variants reloaders actually write
/// (notebooks rarely match a vendor's official spelling). Values are
/// the canonical names the LoadOut catalog stores.
///
/// Coverage (50+ entries):
///   - Hodgdon: H4350, H4831, H4831SC, H4895, H1000, H50BMG, H110, Varget,
///     Trail Boss, US 869, BL-C(2), BL-C2.
///   - IMR: IMR4350, IMR4451, IMR4955, IMR4166, IMR8208 XBR, IMR4831,
///     IMR4895, IMR3031.
///   - Alliant: Reloder 16 (RL16), Reloder 17 (RL17), Reloder 23 (RL23),
///     Reloder 26 (RL26), Reloder 33 (RL33), Reloder 50 (RL50), Power
///     Pistol, Bullseye, Unique, Blue Dot, Green Dot.
///   - Vihtavuori: N140, N150, N160, N165, N170, N133, N550, N565, N568.
///   - Accurate / Western: AA2200, AA2230, AA2520, AA2700, AA4350,
///     Accurate Magpro.
///   - Ramshot: Big Game, Hunter, Magnum, TAC, Wild Boar, X-Terminator.
///   - Norma: 200, 203B, 204, MRP, URP.
///   - Winchester: 760, StaBALL HD, Match.
///   - Shotshell / pistol stragglers folded in for completeness.
const Map<String, String> kPowderHandwritingAliases = {
  // ───── Hodgdon rifle ─────
  'h4350': 'H4350',
  'h 4350': 'H4350',
  'h-4350': 'H4350',
  'hodgdon 4350': 'H4350',
  'hodgdon h4350': 'H4350',
  'h435': 'H4350', // OCR'd cursive zero often dropped
  'h4831': 'H4831',
  'h 4831': 'H4831',
  'h-4831': 'H4831',
  'hodgdon 4831': 'H4831',
  'h4831sc': 'H4831SC',
  'h4831 sc': 'H4831SC',
  'h-4831sc': 'H4831SC',
  'h4895': 'H4895',
  'h 4895': 'H4895',
  'h-4895': 'H4895',
  'h1000': 'H1000',
  'h 1000': 'H1000',
  'h-1000': 'H1000',
  'h50bmg': 'H50BMG',
  'h 50 bmg': 'H50BMG',
  'h110': 'H110',
  'h 110': 'H110',
  'us869': 'US 869',
  'us 869': 'US 869',
  'bl-c2': 'BL-C(2)',
  'bl-c(2)': 'BL-C(2)',
  'blc2': 'BL-C(2)',
  'blc(2)': 'BL-C(2)',
  'varget': 'Varget',
  'var get': 'Varget',
  'trail boss': 'Trail Boss',
  // ───── IMR rifle ─────
  'imr4350': 'IMR4350',
  'imr 4350': 'IMR4350',
  'imr-4350': 'IMR4350',
  '4350': 'IMR4350', // ambiguous with H4350; the parser disambiguates
  'imr4451': 'IMR4451',
  'imr 4451': 'IMR4451',
  'imr-4451': 'IMR4451',
  'imr4955': 'IMR4955',
  'imr 4955': 'IMR4955',
  'imr-4955': 'IMR4955',
  'imr4166': 'IMR4166',
  'imr 4166': 'IMR4166',
  'imr-4166': 'IMR4166',
  'imr8208 xbr': 'IMR8208 XBR',
  'imr 8208 xbr': 'IMR8208 XBR',
  'imr8208': 'IMR8208 XBR',
  '8208': 'IMR8208 XBR',
  '8208 xbr': 'IMR8208 XBR',
  'imr4831': 'IMR4831',
  'imr 4831': 'IMR4831',
  'imr-4831': 'IMR4831',
  'imr4895': 'IMR4895',
  'imr 4895': 'IMR4895',
  'imr-4895': 'IMR4895',
  'imr3031': 'IMR3031',
  'imr 3031': 'IMR3031',
  '3031': 'IMR3031',
  // ───── Alliant ─────
  'rl16': 'Reloder 16',
  'rl 16': 'Reloder 16',
  'rl-16': 'Reloder 16',
  'r-l 16': 'Reloder 16',
  're16': 'Reloder 16',
  're-16': 'Reloder 16',
  'reloder 16': 'Reloder 16',
  'reloader 16': 'Reloder 16',
  'rl17': 'Reloder 17',
  'rl 17': 'Reloder 17',
  'rl-17': 'Reloder 17',
  're17': 'Reloder 17',
  'reloder 17': 'Reloder 17',
  'reloader 17': 'Reloder 17',
  'rl23': 'Reloder 23',
  'rl 23': 'Reloder 23',
  'rl-23': 'Reloder 23',
  're23': 'Reloder 23',
  'reloder 23': 'Reloder 23',
  'rl26': 'Reloder 26',
  'rl 26': 'Reloder 26',
  'rl-26': 'Reloder 26',
  're26': 'Reloder 26',
  'reloder 26': 'Reloder 26',
  'rl33': 'Reloder 33',
  'rl 33': 'Reloder 33',
  'reloder 33': 'Reloder 33',
  'rl50': 'Reloder 50',
  'reloder 50': 'Reloder 50',
  'power pistol': 'Power Pistol',
  'bullseye': 'Bullseye',
  'unique': 'Unique',
  'blue dot': 'Blue Dot',
  'green dot': 'Green Dot',
  // ───── Vihtavuori ─────
  'n133': 'N133',
  'n-133': 'N133',
  'n 133': 'N133',
  'vv n133': 'N133',
  'vihtavuori n133': 'N133',
  'n140': 'N140',
  'n-140': 'N140',
  'n 140': 'N140',
  'vv n140': 'N140',
  'vihtavuori n140': 'N140',
  'n150': 'N150',
  'n-150': 'N150',
  'n 150': 'N150',
  'vv n150': 'N150',
  'vihtavuori n150': 'N150',
  'n160': 'N160',
  'n-160': 'N160',
  'n 160': 'N160',
  'vv n160': 'N160',
  'vihtavuori n160': 'N160',
  'n165': 'N165',
  'n-165': 'N165',
  'n 165': 'N165',
  'vv n165': 'N165',
  'n170': 'N170',
  'n-170': 'N170',
  'n 170': 'N170',
  'vv n170': 'N170',
  'n550': 'N550',
  'n-550': 'N550',
  'n 550': 'N550',
  'n565': 'N565',
  'n-565': 'N565',
  'n 565': 'N565',
  'n568': 'N568',
  'n-568': 'N568',
  // ───── Accurate / Western ─────
  'aa2200': 'AA2200',
  'aa 2200': 'AA2200',
  'a2200': 'AA2200',
  'aa2230': 'AA2230',
  'aa 2230': 'AA2230',
  'a2230': 'AA2230',
  'aa2520': 'AA2520',
  'aa 2520': 'AA2520',
  'aa2700': 'AA2700',
  'aa 2700': 'AA2700',
  'aa4350': 'AA4350',
  'aa 4350': 'AA4350',
  'magpro': 'Accurate Magpro',
  'mag pro': 'Accurate Magpro',
  'accurate magpro': 'Accurate Magpro',
  'accurate 4350': 'AA4350',
  // ───── Ramshot ─────
  'big game': 'Ramshot Big Game',
  'ramshot big game': 'Ramshot Big Game',
  'ramshot hunter': 'Ramshot Hunter',
  'ramshot magnum': 'Ramshot Magnum',
  'ramshot tac': 'Ramshot TAC',
  'ramshot tac powder': 'Ramshot TAC',
  'wild boar': 'Ramshot Wild Boar',
  'x-terminator': 'Ramshot X-Terminator',
  'xterminator': 'Ramshot X-Terminator',
  // ───── Norma ─────
  'norma 200': 'Norma 200',
  'norma 203b': 'Norma 203B',
  'norma 204': 'Norma 204',
  'norma mrp': 'Norma MRP',
  'mrp': 'Norma MRP',
  'urp': 'Norma URP',
  // ───── Winchester ─────
  'win 760': 'Winchester 760',
  'winchester 760': 'Winchester 760',
  'w760': 'Winchester 760',
  'staball hd': 'StaBALL HD',
  'sta-ball hd': 'StaBALL HD',
  'win match': 'Winchester Match',
  // ───── Misc rifle ─────
  'cfe223': 'CFE223',
  'cfe 223': 'CFE223',
  'cfe-223': 'CFE223',
  'cfe black': 'CFE BLK',
  'cfe blk': 'CFE BLK',
  'tac': 'Ramshot TAC',
  'benchmark': 'Hodgdon Benchmark',
  'hodgdon benchmark': 'Hodgdon Benchmark',
};

/// Bullet line shorthand / abbreviation → canonical line name.
///
/// Keys are case-insensitive shorthand reloaders write in notebooks.
/// Values are canonical product-line names the LoadOut catalog uses
/// (so a downstream catalog-match can find the manufacturer + line).
///
/// Coverage (50+ entries):
///   - Hornady: ELD-M, ELD-X, A-Tip, SST, V-MAX, A-MAX, BTHP Match,
///     Interlock, GMX, CX.
///   - Sierra: MatchKing (SMK), Tipped MatchKing (TMK), GameKing (SGK),
///     Pro-Hunter, BlitzKing.
///   - Berger: Hybrid (VLD), VLD, Match Hybrid Target (MHT), OTM Tactical,
///     Long Range Hybrid Target (LRHT), Elite Hunter, Classic Hunter.
///   - Nosler: Ballistic Tip (BT), AccuBond (AB), Partition (NPT),
///     E-Tip, Custom Competition (CC).
///   - Barnes: TSX, TTSX, LRX, MRX.
///   - Lapua: Scenar, Scenar-L, Naturalis.
///   - Speer: Hot-Cor, Grand Slam, Gold Dot.
///   - Generic / cross-vendor: BTHP, FMJ, JHP, Hyb (Berger Hybrid), MK
///     (military match-king clone shorthand).
const Map<String, String> kBulletHandwritingAliases = {
  // ───── Hornady ─────
  'eldm': 'ELD-M',
  'eld m': 'ELD-M',
  'eld-m': 'ELD-M',
  'eld match': 'ELD Match',
  'eldmatch': 'ELD Match',
  'eldx': 'ELD-X',
  'eld x': 'ELD-X',
  'eld-x': 'ELD-X',
  'a-tip': 'A-Tip',
  'a tip': 'A-Tip',
  'atip': 'A-Tip',
  'sst': 'SST',
  'v-max': 'V-MAX',
  'vmax': 'V-MAX',
  'v max': 'V-MAX',
  'a-max': 'A-MAX',
  'amax': 'A-MAX',
  'a max': 'A-MAX',
  'bthp match': 'BTHP Match',
  'interlock': 'InterLock',
  'inter lock': 'InterLock',
  'gmx': 'GMX',
  'cx': 'CX',
  // ───── Sierra ─────
  'smk': 'MatchKing',
  's-mk': 'MatchKing',
  'matchking': 'MatchKing',
  'match king': 'MatchKing',
  'tmk': 'Tipped MatchKing',
  't-mk': 'Tipped MatchKing',
  'tipped matchking': 'Tipped MatchKing',
  'tipped match king': 'Tipped MatchKing',
  'sgk': 'GameKing',
  'gameking': 'GameKing',
  'game king': 'GameKing',
  'pro-hunter': 'Pro-Hunter',
  'pro hunter': 'Pro-Hunter',
  'prohunter': 'Pro-Hunter',
  'blitzking': 'BlitzKing',
  'blitz king': 'BlitzKing',
  // ───── Berger ─────
  'hyb': 'Hybrid',
  'hyb tgt': 'Hybrid Target',
  'hybrid tgt': 'Hybrid Target',
  'hybrid target': 'Hybrid Target',
  'mht': 'Match Hybrid Target',
  'match hybrid target': 'Match Hybrid Target',
  'lrht': 'Long Range Hybrid Target',
  'long range hybrid target': 'Long Range Hybrid Target',
  'long range hybrid tgt': 'Long Range Hybrid Target',
  'vld': 'VLD',
  'vld target': 'VLD Target',
  'vld tgt': 'VLD Target',
  'vld hunting': 'VLD Hunting',
  'otm': 'OTM Tactical',
  'otm tac': 'OTM Tactical',
  'otm tactical': 'OTM Tactical',
  'elite hunter': 'Elite Hunter',
  'classic hunter': 'Classic Hunter',
  // ───── Nosler ─────
  'bt': 'Ballistic Tip',
  'b-tip': 'Ballistic Tip',
  'ballistic tip': 'Ballistic Tip',
  'ab': 'AccuBond',
  'accubond': 'AccuBond',
  'accu-bond': 'AccuBond',
  'accu bond': 'AccuBond',
  'npt': 'Partition',
  'partition': 'Partition',
  'e-tip': 'E-Tip',
  'etip': 'E-Tip',
  'cc': 'Custom Competition',
  'custom competition': 'Custom Competition',
  'rdf': 'RDF',
  // ───── Barnes ─────
  'tsx': 'TSX',
  'ttsx': 'TTSX',
  'lrx': 'LRX',
  'mrx': 'MRX',
  // ───── Lapua ─────
  'scenar': 'Scenar',
  'scenar-l': 'Scenar-L',
  'scenar l': 'Scenar-L',
  'naturalis': 'Naturalis',
  // ───── Speer ─────
  'hot-cor': 'Hot-Cor',
  'hot cor': 'Hot-Cor',
  'hotcor': 'Hot-Cor',
  'grand slam': 'Grand Slam',
  'gold dot': 'Gold Dot',
  // ───── Generic / cross-vendor ─────
  'bthp': 'BTHP',
  'b.t.h.p.': 'BTHP',
  'fmj': 'FMJ',
  'fmjbt': 'FMJ-BT',
  'fmj-bt': 'FMJ-BT',
  'jhp': 'JHP',
  'sp': 'Soft Point',
  'soft point': 'Soft Point',
  'sjhp': 'Semi-Jacketed Hollow Point',
  'mk': 'MatchKing',
};

/// Caliber alias → canonical SAAMI name. Catches the everyday shorthand
/// ("308 Win", ".308", "7.62 NATO") and resolves to the canonical name
/// the catalog uses (".308 Winchester").
///
/// Keys are lower-cased exactly as a user might write them. The parser
/// normalizes whitespace before lookup, so "308win" and "308 Win" both
/// work.
///
/// Coverage (60+ entries) for the most common reloading cartridges:
///   - .22-.30 rifle: .22 Hornet, .218 Bee, .222 Rem, .223 Rem / 5.56,
///     .22-250, .220 Swift, .224 Valkyrie, 22 Creedmoor, 22 ARC.
///   - 6mm: 6mm BR, 6mm Dasher, 6 ARC, 6mm Creedmoor, 6mm GT, 6 PPC,
///     6 BRA, 6 BRX, .243 Win.
///   - 6.5mm: 6.5 Creedmoor, 6.5 PRC, 6.5x55, 6.5 Grendel, 6.5x47,
///     .260 Rem, .264 Win Mag.
///   - 7mm: 7 PRC, 7mm-08, 7mm Rem Mag, .280 Rem, .284 Win, 7mm SAUM.
///   - .30 cal: .308 Win / 7.62x51, .30-06, .30-30, .300 PRC, .300
///     Win Mag, .300 RUM, .300 Norma Mag, .300 Blackout / 300 BLK,
///     .300 H&H, .300 WSM, .30 Carbine.
///   - Magnum / heavies: .338 Lapua, .338 Win Mag, .375 H&H, .338-378,
///     .375 Ruger, .416 Rigby.
///   - Pistol: 9mm Luger, 9x19, .45 ACP, .40 S&W, .380 ACP, .357 Mag,
///     .38 Spl, .44 Mag, 10mm Auto, .44-40, .454 Casull.
const Map<String, String> kCaliberHandwritingAliases = {
  // ───── .22 caliber rifle ─────
  '.22 hornet': '.22 Hornet',
  '22 hornet': '.22 Hornet',
  '.218 bee': '.218 Bee',
  '218 bee': '.218 Bee',
  '.222 rem': '.222 Remington',
  '222 rem': '.222 Remington',
  '222': '.222 Remington',
  '.223': '.223 Remington',
  '.223 rem': '.223 Remington',
  '223 rem': '.223 Remington',
  '223': '.223 Remington',
  '5.56': '5.56x45mm NATO',
  '5.56 nato': '5.56x45mm NATO',
  '5.56x45': '5.56x45mm NATO',
  '556': '5.56x45mm NATO',
  '.22-250': '.22-250 Remington',
  '22-250': '.22-250 Remington',
  '22 250': '.22-250 Remington',
  '.220 swift': '.220 Swift',
  '220 swift': '.220 Swift',
  '.224 valk': '.224 Valkyrie',
  '224 valk': '.224 Valkyrie',
  '.224 valkyrie': '.224 Valkyrie',
  '224 valkyrie': '.224 Valkyrie',
  '22 creedmoor': '.22 Creedmoor',
  '22 cm': '.22 Creedmoor',
  '22 creed': '.22 Creedmoor',
  '22 arc': '.22 ARC',
  // ───── 6mm rifle ─────
  '6mm br': '6mm BR',
  '6 br': '6mm BR',
  '6 mm br': '6mm BR',
  '6mm br norma': '6mm BR Norma',
  '6mm dasher': '6mm Dasher',
  '6 dasher': '6mm Dasher',
  'dasher': '6mm Dasher',
  '6 arc': '6mm ARC',
  '6mm arc': '6mm ARC',
  '6mm cm': '6mm Creedmoor',
  '6mm creed': '6mm Creedmoor',
  '6mm creedmoor': '6mm Creedmoor',
  '6 cm': '6mm Creedmoor',
  '6cm': '6mm Creedmoor',
  '6 creed': '6mm Creedmoor',
  '6 creedmoor': '6mm Creedmoor',
  '6mm gt': '6mm GT',
  '6 gt': '6mm GT',
  '6 ppc': '6mm PPC',
  '6mm ppc': '6mm PPC',
  '6 bra': '6mm BRA',
  '6mm bra': '6mm BRA',
  '6 brx': '6mm BRX',
  '6mm brx': '6mm BRX',
  '.243': '.243 Winchester',
  '.243 win': '.243 Winchester',
  '243 win': '.243 Winchester',
  '243': '.243 Winchester',
  // ───── 6.5mm rifle ─────
  '6.5 cm': '6.5 Creedmoor',
  '6.5cm': '6.5 Creedmoor',
  '6.5 creed': '6.5 Creedmoor',
  '6.5 creedmoor': '6.5 Creedmoor',
  '6.5 prc': '6.5 PRC',
  '6.5prc': '6.5 PRC',
  '6.5x55': '6.5x55 Swedish',
  '6.5 x 55': '6.5x55 Swedish',
  '6.5x55 swede': '6.5x55 Swedish',
  '6.5 grendel': '6.5 Grendel',
  '6.5 gren': '6.5 Grendel',
  '6.5x47': '6.5x47 Lapua',
  '6.5x47 lapua': '6.5x47 Lapua',
  '.260 rem': '.260 Remington',
  '260 rem': '.260 Remington',
  '260': '.260 Remington',
  '.264 win mag': '.264 Winchester Magnum',
  '264 win mag': '.264 Winchester Magnum',
  '264 win': '.264 Winchester Magnum',
  // ───── 7mm rifle ─────
  '7 prc': '7mm PRC',
  '7mm prc': '7mm PRC',
  '7-08': '7mm-08 Remington',
  '7mm-08': '7mm-08 Remington',
  '7mm 08': '7mm-08 Remington',
  '7mm rem mag': '7mm Remington Magnum',
  '7 rem mag': '7mm Remington Magnum',
  '7 mag': '7mm Remington Magnum',
  '7mm rm': '7mm Remington Magnum',
  '7rm': '7mm Remington Magnum',
  '.280 rem': '.280 Remington',
  '280 rem': '.280 Remington',
  '280': '.280 Remington',
  '.280 ai': '.280 Ackley Improved',
  '280 ai': '.280 Ackley Improved',
  '.284 win': '.284 Winchester',
  '284 win': '.284 Winchester',
  '7mm saum': '7mm SAUM',
  '7 saum': '7mm SAUM',
  // ───── .30 caliber ─────
  '.308': '.308 Winchester',
  '308': '.308 Winchester',
  '.308 w': '.308 Winchester',
  '.308 win': '.308 Winchester',
  '308 w': '.308 Winchester',
  '308 win': '.308 Winchester',
  '7.62x51': '7.62x51mm NATO',
  '7.62 x 51': '7.62x51mm NATO',
  '7.62x51 nato': '7.62x51mm NATO',
  '7.62 nato': '7.62x51mm NATO',
  '.30-06': '.30-06 Springfield',
  '30-06': '.30-06 Springfield',
  '30 06': '.30-06 Springfield',
  '3006': '.30-06 Springfield',
  '.30-30': '.30-30 Winchester',
  '30-30': '.30-30 Winchester',
  '30 30': '.30-30 Winchester',
  '.300 prc': '.300 PRC',
  '300 prc': '.300 PRC',
  '.300 win mag': '.300 Winchester Magnum',
  '300 win mag': '.300 Winchester Magnum',
  '300 wm': '.300 Winchester Magnum',
  '.300 wm': '.300 Winchester Magnum',
  '.300 rum': '.300 Remington Ultra Magnum',
  '300 rum': '.300 Remington Ultra Magnum',
  '.300 norma': '.300 Norma Magnum',
  '300 norma': '.300 Norma Magnum',
  '.300 norma mag': '.300 Norma Magnum',
  '.300 blk': '.300 AAC Blackout',
  '300 blk': '.300 AAC Blackout',
  '.300 blackout': '.300 AAC Blackout',
  '300 blackout': '.300 AAC Blackout',
  '.300 aac': '.300 AAC Blackout',
  '300 aac': '.300 AAC Blackout',
  '.300 h&h': '.300 H&H Magnum',
  '300 h&h': '.300 H&H Magnum',
  '.300 wsm': '.300 WSM',
  '300 wsm': '.300 WSM',
  '.30 carbine': '.30 Carbine',
  '30 carbine': '.30 Carbine',
  // ───── Magnum / heavies ─────
  '.338 lapua': '.338 Lapua Magnum',
  '338 lapua': '.338 Lapua Magnum',
  '338 lap': '.338 Lapua Magnum',
  '.338 win mag': '.338 Winchester Magnum',
  '338 win mag': '.338 Winchester Magnum',
  '.375 h&h': '.375 H&H Magnum',
  '375 h&h': '.375 H&H Magnum',
  '.338-378': '.338-378 Weatherby Magnum',
  '338-378': '.338-378 Weatherby Magnum',
  '.375 ruger': '.375 Ruger',
  '375 ruger': '.375 Ruger',
  '.416 rigby': '.416 Rigby',
  '416 rigby': '.416 Rigby',
  // ───── Pistol ─────
  '9mm': '9mm Luger',
  '9 mm': '9mm Luger',
  '9mm luger': '9mm Luger',
  '9x19': '9mm Luger',
  '9 x 19': '9mm Luger',
  '.45 acp': '.45 ACP',
  '45 acp': '.45 ACP',
  '.40 s&w': '.40 S&W',
  '40 s&w': '.40 S&W',
  '.380 acp': '.380 ACP',
  '380 acp': '.380 ACP',
  '.357 mag': '.357 Magnum',
  '357 mag': '.357 Magnum',
  '.357 magnum': '.357 Magnum',
  '357 magnum': '.357 Magnum',
  '.38 spl': '.38 Special',
  '38 spl': '.38 Special',
  '.38 special': '.38 Special',
  '38 special': '.38 Special',
  '.44 mag': '.44 Remington Magnum',
  '44 mag': '.44 Remington Magnum',
  '.44 magnum': '.44 Remington Magnum',
  '44 magnum': '.44 Remington Magnum',
  '10mm': '10mm Auto',
  '10mm auto': '10mm Auto',
  '.44-40': '.44-40 Winchester',
  '44-40': '.44-40 Winchester',
  '.454 casull': '.454 Casull',
  '454 casull': '.454 Casull',
};

/// Parse a fraction-or-mixed-fraction handwritten charge weight into a
/// double. Reloaders writing "41 1/2", "41½", "41-1/2", or "41.5" all
/// mean 41.5 grains. Returns the parsed value, or `null` if the input
/// can't be coerced.
///
/// Accepted forms:
///   - Plain decimal: "41.5", "44", "150"
///   - Mixed fraction: "41 1/2", "41-1/2", "41 1\/2"
///   - Bare fraction: "1/2", "3/4"
///   - Unicode vulgar fractions: "41½", "41¼", "41¾", "41⅓", "41⅔"
///   - Comma decimal: "41,5" (European locale)
double? parseHandwrittenCharge(String raw) {
  if (raw.isEmpty) return null;
  final s = raw.trim();

  // Map of vulgar fractions to their decimal values. Keep the most
  // common ones — adding more is cheap but unused additions just bloat
  // the table.
  const vulgar = <String, double>{
    '½': 0.5,
    '¼': 0.25,
    '¾': 0.75,
    '⅓': 1 / 3,
    '⅔': 2 / 3,
    '⅕': 0.2,
    '⅖': 0.4,
    '⅗': 0.6,
    '⅘': 0.8,
    '⅙': 1 / 6,
    '⅚': 5 / 6,
    '⅛': 0.125,
    '⅜': 0.375,
    '⅝': 0.625,
    '⅞': 0.875,
  };

  // Vulgar fraction attached to an integer ("41½").
  for (final entry in vulgar.entries) {
    if (s.endsWith(entry.key)) {
      final intPart = s.substring(0, s.length - entry.key.length).trim();
      if (intPart.isEmpty) return entry.value;
      final asInt = int.tryParse(intPart);
      if (asInt != null) return asInt + entry.value;
    }
    if (s == entry.key) return entry.value;
  }

  // Mixed fraction with a hyphen or whitespace separator: "41 1/2",
  // "41-1/2".
  final mixed = RegExp(r'^(\d+)[\s\-](\d+)/(\d+)$').firstMatch(s);
  if (mixed != null) {
    final whole = int.tryParse(mixed.group(1)!);
    final num = int.tryParse(mixed.group(2)!);
    final den = int.tryParse(mixed.group(3)!);
    if (whole != null && num != null && den != null && den != 0) {
      return whole + num / den;
    }
  }

  // Bare fraction: "1/2".
  final bare = RegExp(r'^(\d+)/(\d+)$').firstMatch(s);
  if (bare != null) {
    final num = int.tryParse(bare.group(1)!);
    final den = int.tryParse(bare.group(2)!);
    if (num != null && den != null && den != 0) {
      return num / den;
    }
  }

  // Plain decimal — accept either '.' or ',' as the separator.
  final normalized = s.replaceAll(',', '.');
  return double.tryParse(normalized);
}

/// Resolve a handwriting / shorthand token to its canonical name.
///
/// Performs case-insensitive lookup against [kPowderHandwritingAliases],
/// returning `null` if no canonical mapping exists. Whitespace is
/// normalized (collapsed runs of internal whitespace, leading / trailing
/// trimmed) before the lookup.
String? canonicalPowderName(String raw) {
  return kPowderHandwritingAliases[_normalize(raw)];
}

/// Resolve a handwriting / shorthand bullet token to its canonical line
/// name. Same shape as [canonicalPowderName].
String? canonicalBulletLine(String raw) {
  return kBulletHandwritingAliases[_normalize(raw)];
}

/// Resolve a handwriting / shorthand caliber token to its canonical
/// SAAMI name. Same shape as [canonicalPowderName].
String? canonicalCaliberName(String raw) {
  return kCaliberHandwritingAliases[_normalize(raw)];
}

/// Lower-case + collapse internal whitespace runs. Used internally by
/// the canonical-name helpers so callers don't have to pre-normalize.
String _normalize(String raw) {
  return raw.trim().toLowerCase().replaceAll(RegExp(r'\s+'), ' ');
}

/// Walk a raw OCR line / paragraph and return every canonical hit
/// across all three alias tables. The result is a small record that
/// the recipe parser can layer over its catalog-driven matches.
///
/// The walk is deliberately greedy: tries the longest sliding-window
/// substrings first so "Reloder 16" beats "Reloder" or "16". Caps at
/// six tokens per direction to keep the walk O(n) on practical inputs.
HandwritingExpansion expandHandwritingTokens(String text) {
  final powders = <String>{};
  final bullets = <String>{};
  final calibers = <String>{};

  // Tokenize on whitespace and punctuation that doesn't appear inside
  // canonical names. Keeps periods, hyphens, slashes, and ampersands
  // because canonical names use them.
  final tokens = text
      .split(RegExp(r'[\s,;:|()\[\]{}]+'))
      .where((t) => t.isNotEmpty)
      .toList(growable: false);

  // Greedy sliding window: try 6-token, 5-token, ..., 1-token windows
  // starting at each index. First hit wins for that index range; we
  // then advance past the matched window. The window cap is clamped to
  // however many tokens remain so the loop never asks for a slice past
  // the end of the list.
  var i = 0;
  while (i < tokens.length) {
    var matched = false;
    final maxWindow = (tokens.length - i).clamp(1, 6);
    for (var w = maxWindow; w >= 1; w--) {
      final window = tokens.sublist(i, i + w).join(' ');
      final norm = _normalize(window);
      final powder = kPowderHandwritingAliases[norm];
      final bullet = kBulletHandwritingAliases[norm];
      final caliber = kCaliberHandwritingAliases[norm];
      if (powder != null) {
        powders.add(powder);
        i += w;
        matched = true;
        break;
      }
      if (bullet != null) {
        bullets.add(bullet);
        i += w;
        matched = true;
        break;
      }
      if (caliber != null) {
        calibers.add(caliber);
        i += w;
        matched = true;
        break;
      }
    }
    if (!matched) i++;
  }

  return HandwritingExpansion(
    powders: powders,
    bullets: bullets,
    calibers: calibers,
  );
}

/// Result of a handwriting-pass scan: the canonical names that matched
/// for each component kind. The parser merges these with its catalog
/// hits.
class HandwritingExpansion {
  const HandwritingExpansion({
    required this.powders,
    required this.bullets,
    required this.calibers,
  });

  final Set<String> powders;
  final Set<String> bullets;
  final Set<String> calibers;
}
