// FILE: lib/screens/glossary/glossary_screen.dart
//
// ============================================================================
// WHAT THIS FILE DOES
// ============================================================================
// Renders the in-app reloading glossary: a searchable, alphabetized list
// of terms grouped by topic (cartridge anatomy, ballistics, powder, etc.).
// Reachable from the side drawer entry "Glossary" and from the in-form
// `GlossaryLabel` widget's "Open in Glossary" button (pre-filtered via
// the `initialQuery` constructor parameter).
//
// All content is held in the public `const List<GlossaryTerm>
// kGlossaryTerms = [...]` at the top of the file. Each `GlossaryTerm`
// carries a term, an optional acronym, a category, a definition, an
// optional 1–3 sentence worked `example`, and an optional
// `exampleNumbers` chip with concrete values. `GlossaryTerm.matches(query)`
// does case-insensitive substring search across ALL FIVE text fields,
// so a user searching for a phrase from a worked example finds the
// right entry. The class and table are public so
// `lib/services/glossary_lookup.dart` and `lib/widgets/glossary_label.dart`
// can read them without duplicating data.
//
// The category tags (`_catCartridge`, `_catBallistics`, `_catRangeDay`,
// `_catOptics`, `_catLoadDev`, `_catPowder`, `_catPrimers`, `_catBrass`,
// `_catProcess`, `_catFirearm`) are defined as `const String`s so they
// appear by reference in every term and have one canonical spelling.
// The `_categoryOrder` list locks display order across the screen.
//
// `GlossaryScreen` is a `StatefulWidget` with two pieces of state:
//
//   - `_searchController` — drives the search text field. Pre-seeded
//     from `widget.initialQuery` if the caller passed one.
//   - `_query` — the current trimmed query string
//
// Rebuilds on every keystroke. `_filterAndGroup()` filters
// `kGlossaryTerms` by matching against `_query`, groups the survivors
// into a `Map<category, List<GlossaryTerm>>`, sorts terms alphabetically
// inside each group, and returns the map.
//
// The body renders the search field at the top (with a clear-button
// suffix when non-empty), an optional match-count line ("12 matches"),
// and either an empty-state placeholder or a list of `_CategorySection`
// cards. Each section card has a tinted header (category name + count)
// and a list of `_GlossaryTermTile` rows.
//
// Each `_GlossaryTermTile` always shows the term, optional acronym,
// and definition. If the term carries a worked `example`, a chevron
// at the right edge signals the row is tappable; tapping reveals an
// "Example" panel below the definition with the example text and (if
// present) a small numeric chip from `exampleNumbers`. Entries WITHOUT
// an `example` don't render the chevron and don't respond to taps —
// there's nothing to reveal. When the user is actively searching, the
// matching tiles auto-expand the example panel via
// `initiallyExpanded: true` so example-text matches are immediately
// visible.
//
// ============================================================================
// WHY IT EXISTS IN THE ARCHITECTURE
// ============================================================================
// Reloading has a dense vocabulary (CBTO, headspace, shoulder bump,
// freebore, BC G1 vs G7, MOA vs Mil, etc.) and the rest of the app
// uses these terms freely in field labels and tooltips. The glossary
// is the in-app safety net for users who haven't memorized every piece
// of jargon — they can swipe out the side drawer, search for a term,
// and read a plain-English definition without leaving the app. The
// worked `example` field on the most-confused terms takes the user
// the next step: from "I know what density altitude IS" to "I see
// what 8400 ft DA looks like in the ballistics solver."
//
// Several other screens in the codebase use this file as a layout
// pattern reference for the search-then-grouped-cards UX: a top
// `TextField`, a count-of-matches line, and `Card`-wrapped sections
// with a tinted header. If you're building a similar screen, this is
// the canonical template.
//
// ============================================================================
// WHY THIS IS HARDER THAN IT LOOKS
// ============================================================================
// Three mildly subtle things:
//
//   1. The `_GlossaryTermTile` is keyed by the search-mode default in
//      its parent `_CategorySection` so search-state transitions force
//      a fresh widget identity (and therefore a fresh `_expanded`
//      initialization in `initState`). Without this, a tile that the
//      user manually expanded would lose its expanded state on the
//      next search-state transition; with it, search re-mounts the
//      tile with the appropriate default.
//   2. Tapping a tile is a no-op when `term.example == null` — the
//      `InkWell.onTap` is set to `null` (not just an empty closure)
//      so the row doesn't ripple, and the chevron is omitted entirely.
//      Mixing entries with and without examples in the same list is
//      intentional: not every term needs a worked example.
//   3. The "no matches" empty-state and the search-clear button both
//      need to gracefully handle the user mid-typing. Trimming the
//      query (`value.trim()`) keeps a leading-space keystroke from
//      collapsing the entire result set.
//
// Otherwise this is a straightforward filter-and-render screen.
//
// ============================================================================
// WHO CONSUMES THIS FILE
// ============================================================================
// - `lib/screens/home/home_screen.dart` — the side drawer's "Glossary"
//   entry pushes this screen.
// - `lib/screens/how_it_works/how_it_works_screen.dart` — the
//   "Glossary" topic CTA pushes this screen.
// - `lib/widgets/glossary_label.dart` — the in-form "Open in Glossary"
//   button pushes this screen with `initialQuery` set so it lands
//   pre-filtered on the term the user tapped.
// - `lib/services/glossary_lookup.dart` — reads `kGlossaryTerms` to
//   resolve a label string to a definition without rendering the
//   screen.
//
// ============================================================================
// SIDE EFFECTS
// ============================================================================
// None — pure rendering of compile-time `const` data. No I/O, no
// network, no plugin calls.

import 'package:flutter/material.dart';

/// A single glossary entry. Acronym is optional; not every term abbreviates.
///
/// Renamed from `_GlossaryTerm` to `GlossaryTerm` so the inline help
/// widget (`lib/widgets/glossary_label.dart`) and lookup service
/// (`lib/services/glossary_lookup.dart`) can consume the same authoritative
/// table without duplicating definitions. The class and `kGlossaryTerms`
/// const list below ARE the single source of truth for in-app jargon
/// definitions; everything else just reads from them.
///
/// `example` is an optional second-tier explanation: a 1–3 sentence
/// worked example that's hidden by default and revealed when the user
/// taps the row in the glossary screen. `exampleNumbers` is a short
/// numeric callout (e.g. "10 mph crosswind, 600 yd, .264 cal 140gr")
/// that renders as a small chip beside the example. Use these only
/// for the most-likely-to-need-clarification entries — terms whose
/// definition reads cleanly without an example don't need one. The
/// `matches(query)` method also searches `example` text so a user
/// searching for a phrase from a worked example finds the right entry.
class GlossaryTerm {
  final String term;
  final String? acronym;
  final String category;
  final String definition;
  final String? example;
  final String? exampleNumbers;

  const GlossaryTerm({
    required this.term,
    this.acronym,
    required this.category,
    required this.definition,
    this.example,
    this.exampleNumbers,
  });

  bool matches(String query) {
    if (query.isEmpty) return true;
    final q = query.toLowerCase();
    return term.toLowerCase().contains(q) ||
        (acronym?.toLowerCase().contains(q) ?? false) ||
        definition.toLowerCase().contains(q) ||
        (example?.toLowerCase().contains(q) ?? false) ||
        (exampleNumbers?.toLowerCase().contains(q) ?? false);
  }
}

const String _catCartridge = 'Cartridge anatomy & dimensions';
const String _catBallistics = 'Ballistics';
const String _catRangeDay = 'Range day & shooting';
const String _catOptics = 'Optics & reticles';
const String _catLoadDev = 'Load development';
const String _catPowder = 'Powder & burn behavior';
const String _catPrimers = 'Primers';
const String _catBrass = 'Brass & case prep';
const String _catProcess = 'Reloading process';
const String _catFirearm = 'Firearm-side';

/// Display order for category sections.
const List<String> _categoryOrder = [
  _catCartridge,
  _catBallistics,
  _catRangeDay,
  _catOptics,
  _catLoadDev,
  _catPowder,
  _catPrimers,
  _catBrass,
  _catProcess,
  _catFirearm,
];

/// The authoritative glossary table. Public so the in-form help widget
/// (`GlossaryLabel`) and lookup service (`GlossaryLookup`) can resolve
/// label strings to entries without duplicating definitions.
const List<GlossaryTerm> kGlossaryTerms = [
  // Cartridge anatomy & dimensions
  GlossaryTerm(
    term: 'Cartridge Overall Length',
    acronym: 'COAL',
    category: _catCartridge,
    definition:
        'The length of a loaded cartridge measured from the base of the case to the tip of the bullet (meplat). Useful for fitting a magazine, but it varies with bullet shape.',
    example:
        '30-06 with a 168gr SMK at 3.330 in COAL: bullet sits 0.020 in off the lands in a SAAMI-spec chamber. Magazines are usually built for 3.34 max. You can chase the lands by lengthening to 3.345, but the bullet won\'t feed.',
    exampleNumbers: '30-06, 168gr SMK, COAL 3.330 in',
  ),
  GlossaryTerm(
    term: 'Cartridge Base To Ogive',
    acronym: 'CBTO',
    category: _catCartridge,
    definition:
        'The length from the base of the case to a fixed point on the bullet ogive, measured with a comparator. More repeatable than COAL because it ignores meplat variation.',
    example:
        'Same 30-06 / 168gr SMK: caliper-and-comparator measurement to the ogive = 2.660 in CBTO. Two boxes of the same lot of bullets each give CBTO 2.660 ± 0.002 — much more repeatable than COAL, which varies with meplat.',
    exampleNumbers: '30-06, 168gr SMK, CBTO 2.660 in ± 0.002',
  ),
  GlossaryTerm(
    term: 'Headspace',
    category: _catCartridge,
    definition:
        'The distance between the bolt face and the chamber feature that stops the cartridge (shoulder, case mouth, rim, or belt, depending on cartridge design). Excessive headspace can lead to case stretch or separation.',
  ),
  GlossaryTerm(
    term: 'Case head',
    category: _catCartridge,
    definition:
        'The thick base of the cartridge case containing the primer pocket. It is the strongest part of the case and bears the rearward thrust of firing.',
  ),
  GlossaryTerm(
    term: 'Case web',
    category: _catCartridge,
    definition:
        'The transition zone just forward of the case head where the brass is still thick. Case head separations typically begin here as the metal thins from repeated sizing.',
  ),
  GlossaryTerm(
    term: 'Case body',
    category: _catCartridge,
    definition:
        'The main cylindrical (or slightly tapered) section of the case between the web and the shoulder. It holds the bulk of the powder charge.',
  ),
  GlossaryTerm(
    term: 'Case shoulder',
    category: _catCartridge,
    definition:
        'The angled transition between the body and the neck on a bottlenecked cartridge. The shoulder is the headspacing datum on most modern bottleneck rounds.',
  ),
  GlossaryTerm(
    term: 'Case neck',
    category: _catCartridge,
    definition:
        'The narrow portion of the case that grips the bullet. Neck wall thickness and condition strongly influence neck tension and concentricity.',
  ),
  GlossaryTerm(
    term: 'Case mouth',
    category: _catCartridge,
    definition:
        'The open end of the case where the bullet is seated. It is chamfered and deburred during case prep to ease bullet seating without shaving copper.',
  ),
  GlossaryTerm(
    term: 'Ogive',
    category: _catCartridge,
    definition:
        'The curved forward portion of a bullet between the bearing surface and the meplat. The shape of the ogive heavily influences ballistic coefficient.',
  ),
  GlossaryTerm(
    term: 'Bearing surface',
    category: _catCartridge,
    definition:
        'The cylindrical, full-diameter portion of the bullet that engages the rifling. Length and uniformity of the bearing surface affect pressure and consistency.',
  ),
  GlossaryTerm(
    term: 'Boattail',
    category: _catCartridge,
    definition:
        'A taper on the rear of a bullet that reduces base drag, especially at supersonic and transonic speeds. Common on long-range and match bullets.',
  ),
  GlossaryTerm(
    term: 'Meplat',
    category: _catCartridge,
    definition:
        'The flat or rounded tip at the very front of a bullet. Meplat-to-meplat variation is one reason CBTO is preferred over COAL for measuring seated depth.',
  ),
  GlossaryTerm(
    term: 'Cannelure',
    category: _catCartridge,
    definition:
        'A knurled or rolled groove around the bullet (or sometimes the case) used as a crimping point. Helps prevent bullet setback in semi-autos and tube magazines.',
  ),
  GlossaryTerm(
    term: 'Crimp',
    category: _catCartridge,
    definition:
        'A deformation of the case mouth onto the bullet to lock it in place. The two main styles are taper crimp (used for cartridges that headspace on the case mouth) and roll crimp (used with cannelured bullets, often for revolvers and lever guns).',
  ),
  GlossaryTerm(
    term: 'Taper crimp',
    category: _catCartridge,
    definition:
        'A crimp that gradually tightens the case mouth around the bullet without rolling it inward. Standard for semi-auto pistol rounds that headspace on the case mouth.',
  ),
  GlossaryTerm(
    term: 'Roll crimp',
    category: _catCartridge,
    definition:
        'A crimp that rolls the case mouth into the bullet cannelure. Used for heavy-recoiling revolver loads and tube-fed lever guns to keep bullets from walking under recoil.',
  ),
  GlossaryTerm(
    term: 'Neck tension',
    category: _catCartridge,
    definition:
        'The interference fit between the sized case neck and the bullet. Consistent neck tension is widely considered important for low-ES, low-SD loads.',
  ),
  GlossaryTerm(
    term: 'Throat',
    category: _catCartridge,
    definition:
        'The unrifled portion of the bore just forward of the chamber where the bullet jumps before engaging the lands. Throats erode with use and lengthen over the life of a barrel.',
  ),
  GlossaryTerm(
    term: 'Freebore',
    category: _catCartridge,
    definition:
        'A measurement related to the length of the throat — the distance a bullet travels before contacting the rifling. Different cartridges and chamber reamers specify different freebore lengths.',
  ),
  GlossaryTerm(
    term: 'Lands and grooves',
    category: _catCartridge,
    definition:
        'The raised lands and recessed grooves cut as rifling inside the bore. The lands engrave the bullet and impart spin; the grooves define the bullet diameter the bore was cut for.',
  ),
  GlossaryTerm(
    term: 'Twist rate',
    category: _catCartridge,
    definition:
        'How fast the rifling spins the bullet, expressed as one turn per N inches (e.g. 1:8). Faster twists stabilize longer, heavier bullets.',
    example:
        '6.5 Creedmoor 140gr ELD-M is happy in 1:8 twist (Sg ≈ 1.86 at sea level). Drop to 1:9 and Sg drops to ~1.4 — marginal at altitude or in cold weather. AR-15 with heavy 77gr SMK needs 1:7 or 1:8; 1:9 starts to keyhole.',
    exampleNumbers: '140gr 6.5: 1:8 → Sg 1.86, 1:9 → 1.4',
  ),
  GlossaryTerm(
    term: 'Bullet diameter vs. groove diameter',
    category: _catCartridge,
    definition:
        'Bullet diameter is the actual diameter of the projectile; groove diameter is the bore measurement at the bottom of the rifling grooves. The bullet should match (or very slightly exceed) groove diameter for a proper seal.',
  ),
  GlossaryTerm(
    term: 'Case capacity (H₂O grains)',
    category: _catCartridge,
    definition:
        'Internal volume of a fired or sized case, traditionally measured in grains of water. Useful for comparing brass brands and predicting pressure differences with the same charge.',
  ),

  // Ballistics
  GlossaryTerm(
    term: 'Minute of Angle',
    acronym: 'MOA',
    category: _catBallistics,
    definition:
        'An angular measurement equal to 1/60 of a degree, roughly 1.047 inches at 100 yards. Used for scope adjustments and group size.',
    example:
        '1 MOA at 100 yd = 1.047 inches. At 500 yd, 1 MOA = 5.24 inches. At 1000 yd, 1 MOA = 10.47 inches. To shift a group 6 inches at 600 yd, dial 6 / (6 × 1.047) = ~0.95 MOA.',
    exampleNumbers: '1 MOA: 1.047 in @ 100 yd, 10.47 in @ 1000 yd',
  ),
  GlossaryTerm(
    term: 'Milliradian',
    acronym: 'MIL',
    category: _catBallistics,
    definition:
        'An angular measurement equal to 1/1000 of a radian, roughly 3.6 inches at 100 yards or 10 cm at 100 m. Common on tactical and modern long-range optics.',
    example:
        '1 mil at 100 yd = 3.6 inches; at 1000 yd = 36 inches. To dial 0.5 mil right, that\'s 18 inches at 1000 yd, 1.8 inches at 100 yd. Most precision turrets click in 0.1 mil = 0.36 inch / 100 yd.',
    exampleNumbers: '1 mil: 3.6 in @ 100 yd, 36 in @ 1000 yd',
  ),
  GlossaryTerm(
    term: 'Ballistic Coefficient — G1',
    acronym: 'BC G1',
    category: _catBallistics,
    definition:
        'A measure of a bullet\'s drag relative to the G1 standard projectile (a flat-base, pointed reference shape). Convenient at common distances but tends to overstate performance for modern boattail bullets at long range.',
  ),
  GlossaryTerm(
    term: 'Ballistic Coefficient — G7',
    acronym: 'BC G7',
    category: _catBallistics,
    definition:
        'BC referenced to the G7 standard projectile (a long boattail shape). Generally preferred for VLD and long-range bullets because it tracks their drag curve more accurately than G1.',
  ),
  GlossaryTerm(
    term: 'Sectional Density',
    acronym: 'SD (sectional density)',
    category: _catBallistics,
    definition:
        'A bullet\'s mass divided by the square of its diameter. Higher SD generally means better penetration and is one input to ballistic coefficient.',
  ),
  GlossaryTerm(
    term: 'Standard Deviation (sample)',
    acronym: 'SD (statistics)',
    category: _catBallistics,
    definition:
        'A statistical measure of velocity variation across a string of shots. Note: this acronym collides with Sectional Density — context decides which is meant.',
    example:
        '10-shot string from a chronograph: 2705, 2710, 2712, 2698, 2715, 2708, 2702, 2710, 2706, 2714 fps. Mean = 2708, sample SD ≈ 5.4 fps. Match-grade is single-digit; factory ammo is often 15–25 fps.',
    exampleNumbers: '10-shot string, 2698–2715 fps → SD ≈ 5.4 fps',
  ),
  GlossaryTerm(
    term: 'Extreme Spread',
    acronym: 'ES',
    category: _catBallistics,
    definition:
        'The difference between the highest and lowest velocity in a shot string. A simple, widely cited consistency metric, though SD is generally a more robust descriptor.',
  ),
  GlossaryTerm(
    term: 'Muzzle Velocity',
    acronym: 'MV / FPS',
    category: _catBallistics,
    definition:
        'The velocity of the bullet as it leaves the muzzle, usually reported in feet per second (FPS). It anchors every external ballistics calculation downrange.',
  ),
  GlossaryTerm(
    term: 'Wind drift',
    category: _catBallistics,
    definition:
        'The horizontal deflection of a bullet caused by crosswind. Drift grows non-linearly with distance and is one of the dominant error sources at long range.',
  ),
  GlossaryTerm(
    term: 'Spin drift',
    category: _catBallistics,
    definition:
        'A small horizontal deflection caused by the bullet\'s gyroscopic spin (also called gyroscopic or yaw-of-repose drift). Direction follows the rifling twist; it becomes noticeable at long range.',
    example:
        'Right-twist barrel + 1.5 second time of flight at 1000 yd: bullet drifts about 1 mil to the right purely from gyroscopic precession. Faster twist = more spin drift; same with longer time of flight (slower bullets, longer ranges).',
    exampleNumbers: 'Right twist, 1.5s ToF, 1000 yd → ~1 mil right',
  ),
  GlossaryTerm(
    term: 'Coriolis effect',
    category: _catBallistics,
    definition:
        'A measurement related to the apparent deflection of a bullet caused by Earth\'s rotation during flight. Generally only relevant at extreme long range.',
    example:
        '1000 yd shot due north at 40°N latitude with a 0.5 BC G7 bullet at 2710 fps: Coriolis pushes impact about 0.25 mil RIGHT (because Earth rotated under the bullet during its 1.5s time of flight). Fire south, impact shifts 0.25 mil LEFT.',
    exampleNumbers: '1000 yd, 40°N, 2710 fps → ~0.25 mil',
  ),
  GlossaryTerm(
    term: 'Yaw',
    category: _catBallistics,
    definition:
        'Angular misalignment between the bullet\'s axis and its line of flight. Excessive yaw degrades accuracy and can occur out of an unstable barrel-bullet pairing.',
  ),
  GlossaryTerm(
    term: 'Drag',
    category: _catBallistics,
    definition:
        'The aerodynamic force decelerating the bullet in flight. Drag varies with velocity, air density, and bullet shape, and is captured indirectly by the ballistic coefficient.',
  ),
  GlossaryTerm(
    term: 'Form factor',
    category: _catBallistics,
    definition:
        'A scalar describing how a bullet\'s drag compares to the reference projectile (G1, G7, etc.). Lower form factor means a more aerodynamically efficient bullet.',
    example:
        'Berger 140gr Hybrid Target: G7 BC = 0.319, sectional density = 0.287. i7 = 0.287 / (G7 standard at same SD) = roughly 0.95. Numbers below 1.0 = sleeker than the G7 standard at the same weight, less drag per the same SD.',
    exampleNumbers: 'Berger 140gr Hybrid, G7 BC 0.319, i7 ≈ 0.95',
  ),

  // Powder & burn behavior
  GlossaryTerm(
    term: 'Burn rate',
    category: _catPowder,
    definition:
        'How quickly a powder converts to gas under chamber conditions. Faster powders peak pressure sooner and suit smaller cases; slower powders suit larger cases and heavier bullets.',
    example:
        'For 9mm 124gr (small case, light bullet) you\'d pick a fast powder like Titegroup or W231. For 6.5 Creedmoor 140gr (medium case, heavy bullet for caliber) a slower powder — H4350, RL-16, Varget — fills the case and peaks pressure at the right point in the barrel.',
    exampleNumbers: '9mm: Titegroup. 6.5 CM: H4350.',
  ),
  GlossaryTerm(
    term: 'Extruded powder',
    category: _catPowder,
    definition:
        'Powder formed into small cylindrical sticks (also called stick powder). Generally meters less consistently through volumetric throwers than ball powder but is widely used in rifle loads.',
  ),
  GlossaryTerm(
    term: 'Spherical (ball) powder',
    category: _catPowder,
    definition:
        'Powder formed into small round or flattened spheres. Meters very well through powder throwers and tends to be temperature-sensitive depending on the formulation.',
  ),
  GlossaryTerm(
    term: 'Flake powder',
    category: _catPowder,
    definition:
        'Powder shaped into small flat disks. Common in shotgun and pistol loads; bulky, fast-burning, and meters acceptably in most measures.',
  ),
  GlossaryTerm(
    term: 'Charge weight',
    acronym: 'gr (grains)',
    category: _catPowder,
    definition:
        'The mass of powder in a single load, measured in grains (1 grain ≈ 0.0648 g). Reloading data is published in grains; never confuse grains with grams.',
  ),
  GlossaryTerm(
    term: 'Case fill / load density',
    category: _catPowder,
    definition:
        'How much of the case\'s internal volume the powder charge occupies. Higher load density tends to give more consistent ignition; very low fill can produce erratic velocities.',
  ),
  GlossaryTerm(
    term: 'Pressure',
    acronym: 'CUP / PSI',
    category: _catPowder,
    definition:
        'Peak chamber pressure during firing, measured by transducer (PSI) or older copper crusher methods (CUP). SAAMI and CIP publish maximum allowable pressures per cartridge.',
  ),
  GlossaryTerm(
    term: 'Pressure signs',
    category: _catPowder,
    definition:
        'Physical indicators of overpressure: cratered or pierced primers, ejector marks on the case head, sticky bolt lift, flattened primers, and case head expansion. They are unreliable on their own — the safest path is to stay within published data.',
  ),
  GlossaryTerm(
    term: 'Temperature sensitivity',
    category: _catPowder,
    definition:
        'How much a powder\'s velocity and pressure shift with ambient temperature. Powders marketed as temperature-stable (e.g. Vihtavuori N500-series, Alliant Reloder 16/26, Hodgdon Extreme/StaBALL) are formulated to minimize this drift.',
  ),
  GlossaryTerm(
    term: 'Compressed load',
    category: _catPowder,
    definition:
        'A load in which the powder column is compressed by the seated bullet. Many published rifle loads are slightly compressed; heavy compression can affect ignition and seated depth stability.',
  ),
  GlossaryTerm(
    term: 'Bridging',
    category: _catPowder,
    definition:
        'A condition where powder kernels jam against each other and resist flowing through a drop tube, funnel, or case neck. Common with long extruded powders and small case necks.',
  ),

  // Primers
  GlossaryTerm(
    term: 'Boxer primer',
    category: _catPrimers,
    definition:
        'A primer design with a single central flash hole and a self-contained anvil. Used on virtually all U.S. commercial brass and is what makes that brass reloadable.',
  ),
  GlossaryTerm(
    term: 'Berdan primer',
    category: _catPrimers,
    definition:
        'A primer design where the anvil is part of the case and there are two off-center flash holes. Common on European and military surplus brass; not practically reloadable with standard tools.',
  ),
  GlossaryTerm(
    term: 'Small / large pistol / rifle primers',
    category: _catPrimers,
    definition:
        'Standard primer sizing. Pistol and rifle primers of the same diameter are not interchangeable: rifle primers have harder cups and different brisance to suit their applications.',
  ),
  GlossaryTerm(
    term: 'Magnum primer',
    category: _catPrimers,
    definition:
        'A primer with a hotter, longer-duration flame. Often called for with ball powders, very large cases, or cold-weather loads where ignition needs help.',
  ),
  GlossaryTerm(
    term: 'Benchrest primer',
    category: _catPrimers,
    definition:
        'A primer batch held to tighter manufacturing tolerances, marketed for precision shooters chasing low velocity SD. Real-world benefit is debated but common among match handloaders.',
  ),
  GlossaryTerm(
    term: 'Primer pocket uniformity / depth',
    category: _catPrimers,
    definition:
        'A case prep step that cuts each primer pocket to a uniform depth and bottom geometry. The goal is consistent primer seating depth, which can improve ignition consistency.',
  ),
  GlossaryTerm(
    term: 'Primer crimp / crimp removal',
    category: _catPrimers,
    definition:
        'Many military cases have a ring or stake crimp swaged into the primer pocket to retain the primer. It must be cut or swaged out before a new primer can be seated.',
  ),
  GlossaryTerm(
    term: 'Primer cup hardness',
    category: _catPrimers,
    definition:
        'The hardness of the metal cup containing the priming compound. Harder cups resist piercing in high-pressure or AR-pattern actions; softer cups are easier for light striker hits to ignite.',
  ),

  // Brass / case prep
  GlossaryTerm(
    term: 'Annealing',
    category: _catBrass,
    definition:
        'Heating the case neck and shoulder to relieve work-hardening from repeated sizing. Done correctly, it extends case life and stabilizes neck tension.',
  ),
  GlossaryTerm(
    term: 'Trimming',
    category: _catBrass,
    definition:
        'Cutting cases back to a consistent length after they grow from firing and sizing. Overlong cases can pinch into the throat and spike pressure.',
  ),
  GlossaryTerm(
    term: 'Chamfer / deburr',
    category: _catBrass,
    definition:
        'Beveling the inside (chamfer) and outside (deburr) of the case mouth after trimming. A clean chamfer lets bullets seat without shaving jacket material.',
  ),
  GlossaryTerm(
    term: 'Full length sizing',
    category: _catBrass,
    definition:
        'Resizing the entire case body, shoulder, and neck back toward factory dimensions. Reliable for semi-autos and any rifle where chambering must be effortless.',
  ),
  GlossaryTerm(
    term: 'Neck-only sizing',
    category: _catBrass,
    definition:
        'Resizing only the neck and leaving the body fire-formed to the chamber. Often used by bolt-action precision shooters who keep brass with a single rifle.',
  ),
  GlossaryTerm(
    term: 'Body die',
    category: _catBrass,
    definition:
        'A die that sizes the case body and bumps the shoulder without touching the neck. Used in conjunction with separate neck sizing setups (bushing dies, mandrels).',
  ),
  GlossaryTerm(
    term: 'Shoulder bump',
    category: _catBrass,
    definition:
        'Pushing the case shoulder back a small, controlled amount (typically 0.001–0.003") relative to its fired position. Provides reliable chambering without overworking the brass.',
    example:
        'Fired 6.5 Creedmoor case measures 1.553 in shoulder-to-base with a comparator. Size in your full-length die and re-measure: 1.551 in = 0.002" bump. Smooth bolt close, brass life maximized; bump 0.005" and you\'ll feel it loose, or skip the bump and the bolt fights you.',
    exampleNumbers: 'Fired 1.553 in → sized 1.551 in (0.002" bump)',
  ),
  GlossaryTerm(
    term: 'Mandrel sizing',
    category: _catBrass,
    definition:
        'Setting final neck inside diameter by pulling or pushing a precise rod (mandrel) through the neck after sizing. Tends to give very uniform neck tension and good concentricity.',
  ),
  GlossaryTerm(
    term: 'Primer pocket cleaning / uniforming',
    category: _catBrass,
    definition:
        'Cleaning carbon out of fired primer pockets and optionally cutting them to a uniform depth. Both help primers seat squarely and consistently.',
  ),
  GlossaryTerm(
    term: 'Case capacity weight sorting',
    category: _catBrass,
    definition:
        'Weighing prepped, empty cases as a proxy for internal volume and grouping similar cases together. The relationship between weight and capacity is imperfect but often correlates.',
  ),
  GlossaryTerm(
    term: 'Spring back',
    category: _catBrass,
    definition:
        'The small amount a sized case (or neck) elastically expands after leaving the die. It is why bushings are typically chosen a couple thousandths under final desired diameter.',
  ),

  // Reloading process
  GlossaryTerm(
    term: 'Decapping / depriming',
    category: _catProcess,
    definition:
        'Punching the spent primer out of a fired case, usually with a decapping pin in the sizing die or a dedicated decapping die. Often the first step of case prep.',
  ),
  GlossaryTerm(
    term: 'Sizing die',
    category: _catProcess,
    definition:
        'A die that resizes a fired case toward chamber-ready dimensions. Comes in full length, neck, body, and bushing variants.',
  ),
  GlossaryTerm(
    term: 'Seating die',
    category: _catProcess,
    definition:
        'A die that pushes the bullet into the case to a target depth. Micrometer-top seating dies give repeatable, fine seating-depth adjustments.',
  ),
  GlossaryTerm(
    term: 'Crimping die',
    category: _catProcess,
    definition:
        'A die dedicated to applying a roll or taper crimp as a separate step from seating. Separating the operations often yields better consistency than crimp-while-seating.',
  ),
  GlossaryTerm(
    term: 'Powder dispenser / thrower',
    category: _catProcess,
    definition:
        'A device that dispenses a measured charge of powder by volume (mechanical thrower) or weight (electronic dispenser). Volume-based throwers are fast; weight-based dispensers are precise.',
  ),
  GlossaryTerm(
    term: 'Beam vs. electronic scale',
    category: _catProcess,
    definition:
        'Beam scales use mechanical balance and need no calibration drift management; electronic scales are fast and convenient but require warm-up, calibration, and protection from drafts. Many handloaders verify with both.',
  ),
  GlossaryTerm(
    term: 'OAL gauge / Hornady comparator',
    category: _catProcess,
    definition:
        'Tools for measuring CBTO and finding the distance from the bolt face to the lands in your specific chamber. Essential for tuning seating depth.',
  ),
  GlossaryTerm(
    term: 'Concentricity gauge',
    category: _catProcess,
    definition:
        'A fixture that measures runout of the loaded bullet relative to the case body. Helps diagnose dies, brass, and seating issues that produce crooked rounds.',
  ),
  GlossaryTerm(
    term: 'Chronograph',
    category: _catProcess,
    definition:
        'An instrument for measuring projectile velocity. Common types include optical screens, magnetic (MagnetoSpeed), and Doppler radar units (LabRadar, Garmin Xero, Caldwell Velocimeter).',
  ),
  GlossaryTerm(
    term: 'Load development',
    category: _catProcess,
    definition:
        'The process of working up a load by varying charge, seating depth, and components while observing pressure and group behavior. Common methods include ladder tests, OCW, the Satterlee 10-shot, and the Audette ladder.',
  ),
  GlossaryTerm(
    term: 'Ladder test',
    category: _catProcess,
    definition:
        'A load development method where each shot uses a slightly larger charge, fired at a distant target to spot vertical clusters that suggest a stable charge window.',
  ),
  GlossaryTerm(
    term: 'OCW (Optimal Charge Weight)',
    acronym: 'OCW',
    category: _catProcess,
    definition:
        'A load development method that fires round-robin groups across a charge range looking for a "scatter node" where point of impact is insensitive to small charge changes. Popularized by Dan Newberry.',
  ),
  GlossaryTerm(
    term: 'Satterlee 10-shot test',
    category: _catProcess,
    definition:
        'A load development method that fires a single round at each of 10 ascending charges over a chronograph and looks for a velocity flat spot. Its statistical validity is debated, but it remains popular.',
  ),
  GlossaryTerm(
    term: 'Audette ladder',
    category: _catProcess,
    definition:
        'The classic ladder test described by Creighton Audette: one shot per charge, ascending, fired at long range to read vertical stringing on the target.',
  ),
  GlossaryTerm(
    term: 'Velocity / accuracy node',
    category: _catProcess,
    definition:
        'A charge or seating-depth window where the load is relatively insensitive to small changes — either in velocity (flat spot on a velocity curve) or accuracy (stable group point of impact).',
  ),
  GlossaryTerm(
    term: 'Scatter node vs. flat node',
    category: _catProcess,
    definition:
        'Terminology from OCW: a "scatter node" is the unstable charge zone where groups open and shift; a "flat node" is the stable window between scatter nodes where the rifle shoots well across a small charge range.',
  ),

  // Firearm-side
  GlossaryTerm(
    term: 'Barrel length',
    category: _catFirearm,
    definition:
        'Length of the barrel from breech to muzzle (or muzzle device shoulder, depending on convention). Longer barrels generally yield more velocity, up to the burn-rate limit of the powder.',
  ),
  GlossaryTerm(
    term: 'Action',
    category: _catFirearm,
    definition:
        'The mechanism that loads, locks, and unloads cartridges. Common types include bolt action, semi-automatic, lever action, pump, and break-open.',
  ),
  GlossaryTerm(
    term: 'Headspacing',
    category: _catFirearm,
    definition:
        'How a chamber controls the position of the cartridge so the primer is the correct distance from the bolt face. Different cartridges headspace on the shoulder, case mouth, rim, or belt.',
  ),
  GlossaryTerm(
    term: 'Chamber',
    category: _catFirearm,
    definition:
        'The rear portion of the bore that supports the cartridge during firing. Chamber dimensions are cut to a reamer print derived from SAAMI or CIP specs.',
  ),
  GlossaryTerm(
    term: 'SAAMI vs. CIP specs',
    category: _catFirearm,
    definition:
        'SAAMI (U.S.) and CIP (Europe) are the two main standards bodies that publish chamber, cartridge, and pressure specifications. The two specs sometimes differ slightly for the same nominal cartridge.',
  ),
  GlossaryTerm(
    term: 'Free-floated barrel',
    category: _catFirearm,
    definition:
        'A barrel that does not contact the stock or handguard along its length. Eliminates inconsistent stock pressure on the barrel and is a common precision feature.',
  ),
  GlossaryTerm(
    term: 'Bedding',
    category: _catFirearm,
    definition:
        'How the action is mated to the stock or chassis. Common methods include pillar bedding (metal pillars for screw torque), glass bedding (epoxy fit), and V-block / chassis systems.',
  ),
  GlossaryTerm(
    term: 'Cant / level your reticle',
    category: _catFirearm,
    definition:
        'Cant is any roll of the rifle around the bore axis; a tilted reticle shifts impact horizontally as you dial elevation. Using a bubble level on the scope or rail keeps the reticle vertical.',
  ),
  GlossaryTerm(
    term: 'Velocity loss per inch (rule of thumb)',
    category: _catFirearm,
    definition:
        'A rough rule of thumb: cutting a rifle barrel typically loses on the order of 20–50 fps per inch, depending on cartridge and powder. Treat this as an estimate, not a prediction.',
  ),

  // ─────────────── Range day & shooting ───────────────
  GlossaryTerm(
    term: 'Azimuth',
    category: _catRangeDay,
    definition:
        'The compass direction your rifle is pointed, measured in degrees clockwise from north (0° = north, 90° = east, 180° = south, 270° = west). Used by the ballistic solver for the Coriolis correction at long range, since Earth\'s rotation deflects bullets differently depending on which direction you fire.',
    example:
        'You\'re shooting at a steel target due east — that\'s 90°. Type 90 in the Shot Azimuth field. Coriolis at 1000 yd at 40°N latitude shifts impact ~0.3 mil right; fire west and the same shot drifts 0.3 mil left.',
    exampleNumbers: 'Due east = 90°, due west = 270°',
  ),
  GlossaryTerm(
    term: 'Incline / decline angle',
    category: _catRangeDay,
    definition:
        'The slope of fire — positive for shots uphill, negative for shots downhill. Bullets drop with respect to GRAVITY (vertical), but you aim along the SLOPE, so a 30° uphill or downhill shot needs less elevation hold than a flat shot of the same line-of-sight distance. The "improved rifleman\'s rule" handles this correction inside the solver.',
  ),
  GlossaryTerm(
    term: 'Hold / Holdover',
    category: _catRangeDay,
    definition:
        'The amount you aim ABOVE the target to compensate for bullet drop, expressed in mil, MOA, or inches at the target. The opposite for wind is a "wind hold" or "lead." Holds are measured against the reticle\'s subtensions; you can either dial the turret OR hold off using reticle hash marks.',
    example:
        '6.5 Creedmoor 140gr at 800 yd needs 5.6 mil of drop compensation. You can dial 5.6 mil up on the elevation turret and hold center, OR leave the turret at zero and hold the 5.6-mil hash on the target. The bullet impact is the same.',
    exampleNumbers: '6.5 CM, 800 yd → 5.6 mil hold or dial',
  ),
  GlossaryTerm(
    term: 'DOPE',
    acronym: 'DOPE',
    category: _catRangeDay,
    definition:
        'Data On Previous Engagement. The verified holds (drop and wind) for a specific load + rifle + atmosphere across a range of distances, typically captured in a chart or saved in an app. Live-fire DOPE is more reliable than calculator output because it bakes in your real bullet, your real barrel, and your real atmosphere.',
    example:
        'After a long-range session you log: 100 yd = 0 mil, 300 yd = 0.9 mil, 500 yd = 2.5 mil, 700 yd = 4.6 mil, 1000 yd = 8.8 mil. Next time you face wind 5 mph from 3 o\'clock at 600 yd, you dial 3.4 mil up + hold 0.5 mil left and trust the dope.',
    exampleNumbers: '500 yd = 2.5 mil, 1000 yd = 8.8 mil',
  ),
  GlossaryTerm(
    term: 'Drop',
    category: _catRangeDay,
    definition:
        'How far below your line of sight the bullet has fallen by the time it reaches the target — caused by gravity. Expressed in inches, mil, or MOA. The hold needed to compensate equals the drop: 9.8 MOA of drop means dial 9.8 MOA up.',
  ),
  GlossaryTerm(
    term: 'Wind drift',
    category: _catRangeDay,
    definition:
        'How far the wind pushes the bullet off line by the time it reaches the target. Crosswind from your right pushes the bullet to your left and vice versa; tailwind / headwind have a much smaller effect than crosswind. Hold INTO the wind to compensate.',
  ),
  GlossaryTerm(
    term: 'Lead',
    category: _catRangeDay,
    definition:
        'The amount you aim AHEAD of a moving target so the bullet arrives where the target is going, not where it is. Equals target speed × time of flight. A walking person at 600 yd needs roughly 0.5 mil of lead with a typical match load.',
    example:
        '6.5 Creedmoor 140gr ELD-M at 2710 fps: 1000 yd time of flight = 1.46s. Lead for a 4 fps walking target = 4 × 1.46 = 5.8 inches; about 0.5 mil of horizontal lead at that range.',
    exampleNumbers: 'Walker (4 fps), 1000 yd, 1.46s ToF → 0.5 mil lead',
  ),
  GlossaryTerm(
    term: 'Cant correction',
    category: _catRangeDay,
    definition:
        'When the rifle is rolled (canted) around the bore axis, dialing elevation up no longer goes straight up — it shifts impact horizontally as well as vertically. The cant correction adjusts the displayed hold so it matches what you see through the scope. The phone\'s gyro reads cant in real time.',
    example:
        '5° rifle cant + 8 mil of dialed elevation at 1000 yd: impact moves about 0.7 mil sideways (8 × sin 5°). Level the reticle to zero out cant; the in-app cant tile reads cant from the phone\'s gyro and warns you when it exceeds 1°.',
    exampleNumbers: '5° cant × 8 mil dial → 0.7 mil horizontal error',
  ),
  GlossaryTerm(
    term: 'Aerodynamic jump',
    category: _catRangeDay,
    definition:
        'A small VERTICAL component of wind drift caused by the bullet briefly tipping into the wind as it leaves the muzzle. Usually a few tenths of a mil at long range — small but real. Bryan Litz quantified the formula for production bullets.',
    example:
        '10 mph crosswind from your right + Sg = 1.7 (a typical 6.5 Creedmoor 140 ELD-M): aero jump adds about 0.1 mil DOWNWARD displacement at 1000 yd. Small but real — visible at extreme range.',
    exampleNumbers: '10 mph crosswind, Sg 1.7, 1000 yd → ~0.1 mil down',
  ),
  GlossaryTerm(
    term: 'Density altitude',
    acronym: 'DA',
    category: _catRangeDay,
    definition:
        'A single number that summarizes how "thin" the air is, expressed as the altitude in the standard atmosphere with the same density as your current conditions. High DA (hot, low pressure, humid, high elevation) means less drag, less drop. Many shooters track DA on their data card so they can pull a single hold for the conditions.',
    example:
        '59 °F, 29.92 inHg, 0 ft elevation = 0 ft DA (sea level). 90 °F, 24.5 inHg, 5000 ft elevation = 8400 ft DA. The bullet travels through "thinner air" at 8400 ft DA, less drag, less drop — a 1000 yd shot drops about 1 mil less than at sea level.',
    exampleNumbers: '90 °F, 24.5 inHg, 5000 ft → 8400 ft DA',
  ),
  GlossaryTerm(
    term: 'Station pressure',
    category: _catRangeDay,
    definition:
        'The actual barometric pressure at your shooting location, NOT corrected to sea level. Weather reports usually give sea-level-corrected pressure (~30 inHg even in Denver); your ballistic solver wants the raw station value (~24 inHg in Denver). A Kestrel reads station pressure directly.',
    example:
        'Your Kestrel reads 24.6 inHg at the firing line in Denver. The TV weather report says 30.05 — but that\'s been corrected to sea level. Use the 24.6 station pressure in your solver, not 30.05.',
    exampleNumbers: 'Denver: station 24.6 inHg vs sea-level 30.05',
  ),
  GlossaryTerm(
    term: 'ICAO standard atmosphere',
    category: _catRangeDay,
    definition:
        'The reference atmosphere used as the baseline for ballistic tables: 59 °F, 29.92 inHg sea-level pressure, 78% humidity, 0 ft elevation. When you have no measured environmental data, the solver uses ICAO standard so the answer is at least defensible — but real conditions can shift drop by 0.5+ mil at 1000 yd.',
  ),
  GlossaryTerm(
    term: 'Wind direction (from convention)',
    category: _catRangeDay,
    definition:
        'Wind direction is reported as the direction the wind is blowing FROM, in degrees. A 90° wind is from your right (east in absolute terms), pushing the bullet to your left. Many ballistic apps also accept "clock position" — 3 o\'clock = 90°.',
  ),
  GlossaryTerm(
    term: 'Magnetic declination',
    category: _catRangeDay,
    definition:
        'The angle between true north (geographic) and magnetic north (compass-reads). Varies by location — e.g. about +14° in Maine, near 0° in central US, about -10° in Washington state. Coriolis math wants TRUE north, so the solver applies declination to convert the phone\'s magnetic-compass azimuth into a true bearing.',
  ),
  GlossaryTerm(
    term: 'Latitude',
    category: _catRangeDay,
    definition:
        'Your location\'s degrees north or south of the equator. Coriolis deflection scales with latitude — strong near the poles, zero at the equator. The solver uses this for the Coriolis correction along with shot azimuth.',
  ),
  GlossaryTerm(
    term: 'Group',
    category: _catRangeDay,
    definition:
        'A cluster of shots fired at the same aim point under the same conditions. The "group size" usually means extreme spread — center-to-center of the two widest impacts. A small group means the rifle, load, and shooter are consistent; the absolute position of the group is a separate question (zero / point of impact).',
  ),
  GlossaryTerm(
    term: 'Group MOA',
    category: _catRangeDay,
    definition:
        'Group size expressed in minutes of angle, normalizing across distance. A 1-inch group at 100 yd is roughly 1 MOA; the SAME rifle\'s group at 200 yd would be ~2 inches but still 1 MOA. Useful for comparing groups fired at different distances.',
    example:
        '10 shots at 600 yd, extreme spread (center-to-center of the two widest impacts) = 6.5 inches. 6.5 / (6 × 1.047) = 1.03 MOA. A 1 MOA rifle at 600 yd.',
    exampleNumbers: '6.5 in @ 600 yd → 1.03 MOA',
  ),
  GlossaryTerm(
    term: 'Mean radius',
    acronym: 'MR',
    category: _catRangeDay,
    definition:
        'The average distance from each shot to the group\'s center (centroid). More statistically meaningful than extreme spread because it uses every shot, not just the two outliers. Bryan Litz prefers MR for benchmarking precision.',
    example:
        '5 shots at 100 yd, distances from group centroid: 0.4, 0.5, 0.5, 0.6, 0.7 inches. Mean radius = (0.4 + 0.5 + 0.5 + 0.6 + 0.7) / 5 = 0.54 inches. Smaller MR = tighter group; less sensitive to one outlier than ES.',
    exampleNumbers: '0.4, 0.5, 0.5, 0.6, 0.7 in → MR 0.54 in',
  ),
  GlossaryTerm(
    term: 'Centroid',
    category: _catRangeDay,
    definition:
        'The geometric center of a group of shots — the mean of every shot\'s X and Y coordinates. Useful for "zero adjustment": if the centroid is 1 inch high and 0.5 inch right, dial down 1 MOA and left 0.5 MOA.',
  ),
  GlossaryTerm(
    term: 'Confidence interval (90%)',
    acronym: 'CI',
    category: _catRangeDay,
    definition:
        'A statistical range you\'re 90% sure contains the rifle\'s "true" precision. Three-shot groups have wide CI bands (a 0.5 MOA group could be a 0.2 or 1.5 MOA rifle); 10-shot groups tighten the CI dramatically. Litz publishes CI tables so you can interpret a group size honestly.',
    example:
        '3-shot group of 0.5 MOA → 90% CI is roughly 0.2 to 1.5 MOA (a 0.5 MOA group could be a 0.2 OR a 1.5 MOA rifle, with 3 shots you can\'t tell). 10-shot group of 0.5 MOA → 90% CI is roughly 0.4 to 0.7 MOA.',
    exampleNumbers: '3 shots: 0.2–1.5 MOA. 10 shots: 0.4–0.7 MOA.',
  ),
  GlossaryTerm(
    term: 'Hit probability',
    category: _catRangeDay,
    definition:
        'The probability your next shot lands inside the target outline, given your group size, range uncertainty, wind uncertainty, and muzzle velocity SD. A 95% hit probability at 600 yd on an IPSC silhouette is "first-round hit" territory; <50% is gambling.',
    example:
        'IPSC silhouette (12 in × 24 in) at 600 yd. Inputs: 1 MOA group, 12 fps MV SD, ±5 yd range error, ±2 mph wind error. WEZ output: 87% hit probability per shot. Wind goes ±5 mph (you\'re guessing harder) → drops to 65%.',
    exampleNumbers: 'IPSC, 600 yd, 1 MOA, 12 fps SD → 87% hit',
  ),
  GlossaryTerm(
    term: 'Weapon Employment Zone',
    acronym: 'WEZ',
    category: _catRangeDay,
    definition:
        'A Monte-Carlo simulation that runs your shot N times against random samples of your input uncertainties (wind ±, range ±, group MOA, MV SD), and reports the percentage of simulated shots that hit the target. The output is a hit-probability curve as range increases.',
    example:
        'IPSC silhouette (12 in × 24 in) at 600 yd. Inputs: 1 MOA group, 12 fps MV SD, ±5 yd range error, ±2 mph wind error. WEZ output: 87% hit probability per shot. Wind goes ±5 mph (you\'re guessing harder) → drops to 65%.',
    exampleNumbers: 'IPSC, 600 yd, ±2 mph wind → 87% hit',
  ),
  GlossaryTerm(
    term: 'BC truing',
    category: _catRangeDay,
    definition:
        'Adjusting the published ballistic coefficient (BC) of a bullet so the solver\'s predicted drops match your observed drops. Take a few impact measurements at long range, feed them in, and the calculator regresses a corrected BC for YOUR specific bullet, barrel, atmosphere, and chronograph reading.',
    example:
        'Catalog BC G7 = 0.298. You shoot at 1000 yd and observe 9.0 mil drop, but the solver predicts 8.5 mil. Feed both into BC truing → corrected BC G7 = 0.281, now solver matches your observed drop.',
    exampleNumbers: 'Catalog 0.298 → trued 0.281 (1000 yd, 9.0 mil)',
  ),
  GlossaryTerm(
    term: 'Sight calibration',
    category: _catRangeDay,
    definition:
        'A "tall target test" that verifies your scope\'s clicks match the labeled value. Dial a known amount (say 10 mil), fire at a measured tall target, and check whether the impact moved exactly that amount. Many scopes track 1–3% off advertised; a derived scale factor goes into the solver.',
    example:
        'Dial 10 mil up at a tall target 100 yd away. Measure the impact: it moved 365 inches up. 10 mil at 100 yd should be 360 inches — your scope tracks at 365/360 = 1.014 (1.4% over). Save that scale; the solver scales every dial command.',
    exampleNumbers: '10 mil dialed, 365 in measured → 1.014× scale',
  ),
  GlossaryTerm(
    term: 'Pejsa stability',
    category: _catRangeDay,
    definition:
        'Arthur Pejsa\'s formula for the gyroscopic stability factor (Sg) — a single-pass approximation that\'s less data-hungry than Miller\'s. Sg ≥ 1.5 is generally considered stable for long-range work. The stability tile in the app uses both Pejsa and Miller; if they disagree, look at twist rate, bullet length, and atmospheric density.',
    example:
        'Berger 140gr Hybrid: bullet length 1.41 in, twist 1:8, MV 2750 fps, 59 °F. Pejsa Sg ≈ 1.78. Above 1.5 = stable for long-range work.',
    exampleNumbers: 'Berger 140gr, 1:8 twist, 2750 fps → Sg 1.78',
  ),
  GlossaryTerm(
    term: 'Miller stability formula',
    category: _catRangeDay,
    definition:
        'Don Miller\'s standard formula for the gyroscopic stability factor (Sg). Inputs: bullet length, diameter, weight, twist rate, and air density. Sg < 1.0 = unstable (bullet tumbles), 1.0–1.4 = marginal, ≥ 1.5 = stable, ≥ 2.0 = very stable. The aerodynamic-jump correction also derives from Sg.',
    example:
        'Same Berger 140gr at 1:8 twist, 2750 fps, sea level: Miller Sg = 1.86. Pejsa = 1.78. Both ≥ 1.5 → bullet is comfortably stable. If the rifle ran 1:9 twist instead, Miller drops to 1.4 — marginal.',
    exampleNumbers: 'Berger 140gr, 1:8 → Sg 1.86. 1:9 → Sg 1.4',
  ),
  GlossaryTerm(
    term: 'Form factor (i7)',
    category: _catRangeDay,
    definition:
        'Form factor i7 is the ratio of a bullet\'s drag to the standard G7 drag profile at the same Mach number. A bullet with i7 < 1.0 has less drag than the G7 standard (higher BC); > 1.0 has more drag (lower BC). The same bullet has different i-values relative to G1 vs G7.',
    example:
        'Berger 140gr Hybrid Target: G7 BC = 0.319, sectional density = 0.287. i7 = 0.287 / (G7 standard at same SD) = roughly 0.95. Numbers below 1.0 = sleeker than the G7 standard at the same weight, less drag per the same SD.',
    exampleNumbers: 'Berger 140gr Hybrid, G7 BC 0.319, i7 ≈ 0.95',
  ),
  GlossaryTerm(
    term: 'Custom Drag Model',
    acronym: 'CDM',
    category: _catRangeDay,
    definition:
        'A bullet-specific drag curve derived from Doppler radar measurement, replacing the G1 / G7 standard curve. Applied Ballistics maintains the largest commercial CDM library; Hornady publishes 4DOF CDM data. CDM is more accurate than published BC at extreme range, but only available for popular bullets.',
    example:
        'Berger 140gr Hybrid Target\'s published Doppler-derived CDM at Mach 2.5 = drag coefficient 0.297. The G7 standard at Mach 2.5 = 0.302. The CDM\'s per-Mach values replace the G7 lookup in the solver, accurate at every velocity instead of one BC.',
    exampleNumbers: 'Berger 140gr CDM @ Mach 2.5 = 0.297',
  ),
  GlossaryTerm(
    term: 'Hornady 4DOF',
    category: _catRangeDay,
    definition:
        'Hornady\'s "four-degrees-of-freedom" ballistic solver that uses a CDM for each Hornady bullet (axial drag) plus pitch / yaw / spin tracking. More accurate than G7 for Hornady ammunition at ranges past 1000 yd. LoadOut imports 4DOF custom drag tables for use as the drag model on a per-bullet basis.',
    example:
        'Hornady 4DOF custom drag table for 6.5 Creedmoor 147 ELD-M includes axial drag at every Mach + spin / yaw tracking. At 1500 yd it predicts 14.8 mil drop where G7 (BC 0.351) predicts 14.4 mil — Hornady knows their bullet\'s actual drag profile better than any single BC can capture.',
    exampleNumbers: '6.5 CM 147 ELD-M @ 1500 yd: 4DOF 14.8 vs G7 14.4 mil',
  ),

  // ─────────────── Optics & reticles ───────────────
  GlossaryTerm(
    term: 'Reticle',
    category: _catOptics,
    definition:
        'The aiming pattern inside the scope — crosshairs, dots, hash marks, or a mil grid. Modern precision reticles are "tree" or "Christmas tree" patterns with hashes for fast holdover; hunting reticles are simpler (BDC dots or duplex crosshairs).',
  ),
  GlossaryTerm(
    term: 'First Focal Plane',
    acronym: 'FFP',
    category: _catOptics,
    definition:
        'The reticle is in front of the scope\'s magnification optics, so it grows and shrinks WITH the magnification. A 1-mil hash always represents 1 mil at every magnification. Standard for precision rifle scopes — dial up to a closer view, hold-offs still work without math.',
    example:
        '10× magnification + a 1 mil hash on a FFP reticle: hash subtends exactly 1 mil at the target. Switch to 25× — same hash STILL = 1 mil. Holdovers work without math at any zoom.',
    exampleNumbers: 'FFP: 1 mil hash = 1 mil at any magnification',
  ),
  GlossaryTerm(
    term: 'Second Focal Plane',
    acronym: 'SFP',
    category: _catOptics,
    definition:
        'The reticle is behind the magnification optics, so it stays the same visual size regardless of zoom. The labeled subtension only matches at ONE specific magnification (usually max). At lower magnifications the math doesn\'t work — so SFP scopes are usually used at one fixed power for hold-off.',
    example:
        'SFP scope rated for hold-off at 10×: 1 mil-marked hash IS 1 mil at 10×. At 5× the same hash visually represents 2 mil at the target (because the target image is half the size of 10×). Math required if you hold off at non-rated power.',
    exampleNumbers: 'SFP rated @ 10×: hash = 1 mil. @ 5× hash = 2 mil',
  ),
  GlossaryTerm(
    term: 'Subtension',
    category: _catOptics,
    definition:
        'How much angular space (in mil or MOA) a feature on the reticle covers. A "0.2 mil hash spacing" subtension means each minor hash mark on the reticle represents 0.2 mil. Subtensions are how you translate "the impact landed two hashes low" into a usable correction.',
  ),
  GlossaryTerm(
    term: 'Tube diameter',
    category: _catOptics,
    definition:
        'The outer diameter of the scope\'s main tube — typically 1 inch, 30mm, 34mm, or 35mm/36mm on premium tactical scopes. Larger tubes give more elevation/windage travel but require larger scope rings.',
  ),
  GlossaryTerm(
    term: 'Objective lens',
    category: _catOptics,
    definition:
        'The front lens of the scope, in mm. Larger objectives gather more light (better in low light) but the scope sits higher above the bore and is heavier. 50–56 mm is common for precision scopes; 32–44 mm for hunting / general purpose.',
  ),
  GlossaryTerm(
    term: 'Click value',
    category: _catOptics,
    definition:
        'How much the impact shifts per detent of the elevation or windage turret. Common values: 1/4 MOA, 1/8 MOA, 0.1 mil, 0.05 mil. The smaller the click, the finer the adjustment — but more clicks per mil means more turret rotation for the same dial.',
  ),
  GlossaryTerm(
    term: 'Travel per rotation',
    category: _catOptics,
    definition:
        'How many MOA or mil are in one full turn of the elevation turret. 10 mil per turn is standard on a precision turret; 25 MOA per turn on the MOA equivalent. Affects whether a 1000-yd hold needs one rotation or two — and how easy it is to lose track of which "level" you\'re on.',
  ),
  GlossaryTerm(
    term: 'Max elevation / windage',
    category: _catOptics,
    definition:
        'Total adjustable travel of the turrets, usually expressed in mil or MOA. More elevation = able to dial farther distances without holdover. A 30 mil scope reaches significantly farther than a 12 mil scope on a typical 6.5 Creedmoor.',
  ),
  GlossaryTerm(
    term: 'Eye relief',
    category: _catOptics,
    definition:
        'The distance behind the eyepiece where you get a full, clear sight picture. Too close = scope-bite; too far = a black ring around the image. Precision scopes have ~3.5–4 in eye relief; magnum-recoil hunting scopes have more.',
  ),
  GlossaryTerm(
    term: 'Parallax (optics)',
    category: _catOptics,
    definition:
        'When the reticle and target image are NOT in the same focal plane, moving your head shifts the apparent point of aim. Adjustable-parallax (side-focus or AO) scopes let you focus the target image at the reticle plane, eliminating this error. Critical for precision shooting past 200 yd.',
  ),
  GlossaryTerm(
    term: 'Field of view',
    acronym: 'FOV',
    category: _catOptics,
    definition:
        'How wide an area you can see through the scope at a given range, usually quoted in feet at 100 yd. Higher magnification = narrower FOV. A 4×24 hunting scope might show 24 ft at 100 yd; a 25×56 might show 4 ft.',
  ),
  GlossaryTerm(
    term: 'Mil-dot reticle',
    category: _catOptics,
    definition:
        'A classic tactical reticle pattern with dots spaced 1 mil apart along the crosshairs. Originally a Marine Corps design for ranging; modern descendants (mil-hash, mil-grid, Christmas tree) use small hashes instead of dots for finer holds.',
  ),
  GlossaryTerm(
    term: 'Christmas tree reticle',
    category: _catOptics,
    definition:
        'A modern precision reticle pattern that adds a wide grid of holdover hashes BELOW the crosshair, narrowing toward the bottom — visually resembling a Christmas tree. Lets the shooter hold for both drop AND wind on the same reticle without dialing. Common on Horus, MIL-XT, and TReMoR-family designs.',
  ),

  // ─────────────── Load development ───────────────
  GlossaryTerm(
    term: 'Mean velocity',
    category: _catLoadDev,
    definition:
        'The average muzzle velocity of a string of shots, in fps. Combined with standard deviation, mean velocity is the headline output of a chronograph session — feed both into the solver for honest predictions.',
  ),
  GlossaryTerm(
    term: 'MV Standard Deviation',
    acronym: 'MV SD',
    category: _catLoadDev,
    definition:
        'Standard deviation of muzzle velocity across a chronographed string. Match-grade is single-digit (≤ 9 fps); factory ammo is often 15–25 fps. SD compounds with range — 10 fps SD becomes ~1 ft of vertical at 1000 yd, alone.',
    example:
        '6.5 Creedmoor at 2710 fps mean, 10 fps MV SD. At 1000 yd, the velocity spread translates to ~12 in (~0.3 mil) of vertical dispersion at the target — independent of any other error source. Halve SD to 5 fps and it drops to ~6 in.',
    exampleNumbers: '10 fps SD @ 1000 yd → ~0.3 mil vertical',
  ),
  GlossaryTerm(
    term: 'Range uncertainty',
    category: _catLoadDev,
    definition:
        'How wrong your distance-to-target estimate could plausibly be, expressed as ± yards. Even a quality rangefinder may be ±5 yd at 1000 yd; an unsupported guess could be ±50 yd. The WEZ tool uses this as one Monte-Carlo input.',
  ),
  GlossaryTerm(
    term: 'Wind uncertainty',
    category: _catLoadDev,
    definition:
        'How wrong your wind-call could plausibly be, in mph. Even experienced shooters call wind ± 2 mph on a clean day; ± 4–5 mph in gusty terrain. WEZ uses this to compute the horizontal half of the hit-probability ellipse.',
  ),
  GlossaryTerm(
    term: 'Powder factor',
    category: _catLoadDev,
    definition:
        'Bullet weight (grains) × muzzle velocity (fps) ÷ 1000. Used by competition rules (USPSA, IDPA, Steel Challenge) to define minor / major / no-score thresholds. Reloaders pick a charge that comfortably exceeds the floor without overloading the case.',
  ),
];

class GlossaryScreen extends StatefulWidget {
  /// Optional pre-filtered query. When non-empty, the search field is
  /// pre-filled and the matching category sections are auto-expanded —
  /// used by the in-form `GlossaryLabel` widget's "Open in Glossary"
  /// button so the user lands directly on the term they tapped.
  final String? initialQuery;

  const GlossaryScreen({super.key, this.initialQuery});

  @override
  State<GlossaryScreen> createState() => _GlossaryScreenState();
}

class _GlossaryScreenState extends State<GlossaryScreen> {
  late final TextEditingController _searchController;
  String _query = '';

  /// Active landing-tile filter, when the user tapped one of the
  /// "Suggested for new reloaders" / "Suggested for the Range Day
  /// workflow" tiles. Restricts the visible glossary to a curated
  /// subset whose `term` strings are listed in [_LandingFilter.terms].
  /// Null means no landing filter is active (search-only view, or the
  /// initial overview with the tiles visible).
  _LandingFilter? _landingFilter;

  @override
  void initState() {
    super.initState();
    final initial = widget.initialQuery?.trim() ?? '';
    _searchController = TextEditingController(text: initial);
    _query = initial;
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Map<String, List<GlossaryTerm>> _filterAndGroup() {
    Iterable<GlossaryTerm> stream = kGlossaryTerms.where((t) => t.matches(_query));
    final landing = _landingFilter;
    if (landing != null) {
      final allowed = landing.terms;
      stream = stream.where((t) => allowed.contains(t.term));
    }
    final filtered = stream.toList();
    final grouped = <String, List<GlossaryTerm>>{};
    for (final term in filtered) {
      grouped.putIfAbsent(term.category, () => []).add(term);
    }
    // Preserve insertion order within categories; sort terms alphabetically
    // for stable display within each category.
    for (final list in grouped.values) {
      list.sort((a, b) => a.term.toLowerCase().compareTo(b.term.toLowerCase()));
    }
    return grouped;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final textTheme = theme.textTheme;
    final grouped = _filterAndGroup();
    final isSearching = _query.isNotEmpty;
    final hasLandingFilter = _landingFilter != null;
    // Landing tiles only show on the "fresh" overview state — no
    // search query AND no landing filter active. The moment the user
    // engages either, we hide the tiles to make room for results.
    final showLandingTiles = !isSearching && !hasLandingFilter;
    final visibleCategories =
        _categoryOrder.where((c) => grouped.containsKey(c)).toList();
    final totalMatches = grouped.values.fold<int>(0, (a, b) => a + b.length);

    return Scaffold(
      appBar: AppBar(title: const Text('Glossary')),
      body: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
              child: TextField(
                controller: _searchController,
                textInputAction: TextInputAction.search,
                onChanged: (value) => setState(() => _query = value.trim()),
                decoration: InputDecoration(
                  hintText: 'Search terms, acronyms, or definitions',
                  prefixIcon: const Icon(Icons.search),
                  suffixIcon: _query.isEmpty
                      ? null
                      : IconButton(
                          icon: const Icon(Icons.clear),
                          tooltip: 'Clear search',
                          onPressed: () {
                            _searchController.clear();
                            setState(() => _query = '');
                          },
                        ),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                  isDense: true,
                ),
              ),
            ),
            if (isSearching)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    totalMatches == 1
                        ? '1 match'
                        : '$totalMatches matches',
                    style: textTheme.bodySmall,
                  ),
                ),
              ),
            // Active-landing-filter chip. Lets the user back out of a
            // landing-tile filter without first having to clear the
            // (empty) search box. Shown as a row with the filter
            // label + a clear-X button.
            if (hasLandingFilter)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        'Showing: ${_landingFilter!.label}'
                        '  ($totalMatches term${totalMatches == 1 ? '' : 's'})',
                        style: textTheme.bodyMedium?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                    TextButton.icon(
                      onPressed: () => setState(() => _landingFilter = null),
                      icon: const Icon(Icons.clear, size: 16),
                      label: const Text('Show all'),
                      style: TextButton.styleFrom(
                        visualDensity: VisualDensity.compact,
                      ),
                    ),
                  ],
                ),
              ),
            Expanded(
              child: visibleCategories.isEmpty
                  ? Center(
                      child: Padding(
                        padding: const EdgeInsets.all(24),
                        child: Text(
                          'No terms match "$_query".',
                          style: textTheme.bodyMedium,
                          textAlign: TextAlign.center,
                        ),
                      ),
                    )
                  : ListView.builder(
                      padding: const EdgeInsets.fromLTRB(12, 4, 12, 24),
                      // +1 row when landing tiles are visible (rendered
                      // before any category section).
                      itemCount: visibleCategories.length +
                          (showLandingTiles ? 1 : 0),
                      itemBuilder: (context, index) {
                        if (showLandingTiles && index == 0) {
                          return _LandingTilesRow(
                            onPick: (filter) =>
                                setState(() => _landingFilter = filter),
                          );
                        }
                        final catIndex =
                            showLandingTiles ? index - 1 : index;
                        final category = visibleCategories[catIndex];
                        final entries = grouped[category]!;
                        return _CategorySection(
                          category: category,
                          // When the user tapped a landing tile, expand
                          // every category since the user has already
                          // declared what they want to see — no point
                          // making them tap again to expand each
                          // section. Otherwise expand only when
                          // searching (existing behaviour).
                          terms: entries,
                          autoExpand: isSearching || hasLandingFilter,
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Curated set of glossary terms surfaced behind one landing tile.
/// Both lists are deliberately short — the goal is "give a beginner
/// 15-25 essential terms to anchor on", not "show every relevant
/// term." Entries that don't match a real `kGlossaryTerms` entry
/// silently drop out via the `where` filter in `_filterAndGroup`.
class _LandingFilter {
  const _LandingFilter({required this.label, required this.terms});
  final String label;
  final Set<String> terms;
}

/// Suggested-terms tile rendering above the category list. Two tiles
/// side-by-side on tablet widths, stacked on phones. Each tile spells
/// out a short rationale so a beginner immediately understands which
/// path to start on.
class _LandingTilesRow extends StatelessWidget {
  const _LandingTilesRow({required this.onPick});
  final ValueChanged<_LandingFilter> onPick;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 8, 4, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 0, 8, 6),
            child: Text(
              'Suggested terms',
              style: theme.textTheme.titleSmall?.copyWith(
                fontWeight: FontWeight.w700,
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          LayoutBuilder(
            builder: (context, constraints) {
              // Two cards side-by-side once the body is at least
              // 560px wide; stacked vertically below that. Avoids a
              // half-width tile that wraps awkwardly on phones.
              final wide = constraints.maxWidth >= 560;
              final cards = [
                _LandingTile(
                  heading: 'New to reloading',
                  body:
                      'Foundational vocabulary every reloader hits in '
                      'the first few sessions: COAL, headspace, '
                      'pressure signs, charge weight, neck tension.',
                  icon: Icons.school_outlined,
                  onTap: () => onPick(_kBeginnerLandingFilter),
                ),
                _LandingTile(
                  heading: 'Range Day workflow',
                  body:
                      'Terms a shooter sees at the firing line: mil, '
                      'MOA, drop, wind drift, DOPE, density altitude, '
                      'cant, hold-over.',
                  icon: Icons.gps_fixed,
                  onTap: () => onPick(_kRangeDayLandingFilter),
                ),
              ];
              if (wide) {
                return Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Expanded(child: cards[0]),
                    const SizedBox(width: 8),
                    Expanded(child: cards[1]),
                  ],
                );
              }
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  cards[0],
                  const SizedBox(height: 8),
                  cards[1],
                ],
              );
            },
          ),
        ],
      ),
    );
  }
}

class _LandingTile extends StatelessWidget {
  const _LandingTile({
    required this.heading,
    required this.body,
    required this.icon,
    required this.onTap,
  });
  final String heading;
  final String body;
  final IconData icon;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      elevation: 0,
      color: theme.colorScheme.surfaceContainerHighest,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: theme.colorScheme.outlineVariant),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  Icon(icon, size: 20, color: theme.colorScheme.primary),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      heading,
                      style: theme.textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  Icon(
                    Icons.chevron_right,
                    size: 20,
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ],
              ),
              const SizedBox(height: 6),
              Text(
                body,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Beginner-essentials filter — the foundational reloading vocabulary
/// a new reloader meets in their first 5–10 sessions. Each term must
/// appear in [kGlossaryTerms]; orphan strings silently drop out. Keep
/// this list tight: the point of the tile is "where to start," not
/// "every term that might apply."
final _LandingFilter _kBeginnerLandingFilter = _LandingFilter(
  label: 'New to reloading',
  terms: const {
    'Cartridge Overall Length',
    'Cartridge Base To Ogive',
    'Headspace',
    'Crimp',
    'Neck tension',
    'Twist rate',
    'Charge weight',
    'Pressure',
    'Pressure signs',
    'Annealing',
    'Full length sizing',
    'Shoulder bump',
    'Trimming',
    'Chamfer / deburr',
    'Magnum primer',
    'Small / large pistol / rifle primers',
    'Boxer primer',
    'Standard Deviation (sample)',
    'Extreme Spread',
    'Muzzle Velocity',
    'Ladder test',
  },
);

/// Range-day-workflow filter — the terms a shooter encounters at the
/// firing line, on the wind call, and in the ballistics solver.
final _LandingFilter _kRangeDayLandingFilter = _LandingFilter(
  label: 'Range Day workflow',
  terms: const {
    'Minute of Angle',
    'Milliradian',
    'Drop',
    'Wind drift',
    'Spin drift',
    'Coriolis effect',
    'DOPE',
    'Hold / Holdover',
    'Cant / level your reticle',
    'Density altitude',
    'Station pressure',
    'Azimuth',
    'Incline / decline angle',
    'Group MOA',
    'Mean radius',
    'Hit probability',
    'Ballistic Coefficient — G1',
    'Ballistic Coefficient — G7',
    'Reticle',
    'First Focal Plane',
    'Second Focal Plane',
    'Click value',
  },
);

class _CategorySection extends StatelessWidget {
  final String category;
  final List<GlossaryTerm> terms;
  final bool autoExpand;

  const _CategorySection({
    required this.category,
    required this.terms,
    required this.autoExpand,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final textTheme = theme.textTheme;
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 6),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            color: theme.colorScheme.surfaceContainerHighest,
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    category,
                    style: textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                Text(
                  '${terms.length}',
                  style: textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
          for (int i = 0; i < terms.length; i++) ...[
            if (i > 0) const Divider(height: 1),
            _GlossaryTermTile(
              term: terms[i],
              initiallyExpanded: autoExpand,
            ),
          ],
        ],
      ),
    );
  }
}

/// A single row in a category's term list.
///
/// Layout shows term + acronym + definition by default. If the term
/// carries a worked `example`, a chevron at the right edge indicates
/// the row is tappable; tapping reveals an "Example:" panel below the
/// definition with the example text and (if present) a small numeric
/// chip from `exampleNumbers`. Tap again to collapse.
///
/// `initiallyExpanded` is the search-driven default — when the user
/// is actively searching we auto-expand so example text matches are
/// immediately visible. After the first build the user's local taps
/// take over via `_expanded`. The widget is keyed by the
/// `initiallyExpanded` value in `_CategorySection` so search-state
/// transitions force a fresh widget identity (and therefore a fresh
/// `_expanded` initialization).
///
/// Entries WITHOUT an example don't render the chevron and don't
/// respond to taps — there's nothing to reveal.
class _GlossaryTermTile extends StatefulWidget {
  final GlossaryTerm term;
  final bool initiallyExpanded;

  const _GlossaryTermTile({
    required this.term,
    required this.initiallyExpanded,
  });

  @override
  State<_GlossaryTermTile> createState() => _GlossaryTermTileState();
}

class _GlossaryTermTileState extends State<_GlossaryTermTile>
    with SingleTickerProviderStateMixin {
  late bool _expanded;
  late final AnimationController _chevronController;

  @override
  void initState() {
    super.initState();
    final hasExample = widget.term.example != null;
    _expanded = hasExample && widget.initiallyExpanded;
    _chevronController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 180),
      value: _expanded ? 1.0 : 0.0,
    );
  }

  @override
  void dispose() {
    _chevronController.dispose();
    super.dispose();
  }

  void _toggle() {
    if (widget.term.example == null) return;
    setState(() {
      _expanded = !_expanded;
      if (_expanded) {
        _chevronController.forward();
      } else {
        _chevronController.reverse();
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final textTheme = theme.textTheme;
    final colors = theme.colorScheme;
    final hasExample = widget.term.example != null;

    final headerRow = Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                widget.term.term,
                style: textTheme.titleSmall
                    ?.copyWith(fontWeight: FontWeight.w600),
              ),
              if (widget.term.acronym != null) ...[
                const SizedBox(height: 2),
                Text(
                  widget.term.acronym!,
                  style: textTheme.bodySmall?.copyWith(
                    color: colors.onSurfaceVariant,
                  ),
                ),
              ],
              const SizedBox(height: 6),
              Text(
                widget.term.definition,
                style: textTheme.bodyMedium,
              ),
            ],
          ),
        ),
        if (hasExample) ...[
          const SizedBox(width: 12),
          // Padding-aligned to the term title so the chevron doesn't
          // float visually low next to a multi-line definition.
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: RotationTransition(
              turns: Tween<double>(begin: 0.0, end: 0.5)
                  .animate(_chevronController),
              child: Icon(
                Icons.expand_more,
                color: colors.onSurfaceVariant,
              ),
            ),
          ),
        ],
      ],
    );

    final examplePanel = !_expanded || !hasExample
        ? const SizedBox.shrink()
        : Padding(
            padding: const EdgeInsets.only(top: 12),
            child: Container(
              decoration: BoxDecoration(
                color: colors.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(
                  color: colors.outlineVariant,
                  width: 0.5,
                ),
              ),
              padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Example',
                    style: textTheme.labelSmall?.copyWith(
                      fontWeight: FontWeight.w700,
                      color: colors.primary,
                      letterSpacing: 0.5,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    widget.term.example!,
                    style: textTheme.bodySmall?.copyWith(height: 1.4),
                  ),
                  if (widget.term.exampleNumbers != null) ...[
                    const SizedBox(height: 8),
                    Container(
                      decoration: BoxDecoration(
                        color: colors.primary.withValues(alpha: 0.08),
                        borderRadius: BorderRadius.circular(6),
                      ),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 4,
                      ),
                      child: Text(
                        widget.term.exampleNumbers!,
                        style: textTheme.labelSmall?.copyWith(
                          fontFeatures: const [FontFeature.tabularFigures()],
                          color: colors.primary,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          );

    return InkWell(
      onTap: hasExample ? _toggle : null,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            headerRow,
            AnimatedSize(
              duration: const Duration(milliseconds: 180),
              curve: Curves.easeInOut,
              child: examplePanel,
            ),
          ],
        ),
      ),
    );
  }
}
