// FILE: lib/screens/glossary/glossary_screen.dart
//
// ============================================================================
// WHAT THIS FILE DOES
// ============================================================================
// Renders the in-app reloading glossary: a searchable, alphabetized list
// of terms grouped by topic (cartridge anatomy, ballistics, powder, etc.).
// Reachable from the side drawer entry "Glossary."
//
// All content is held in the file-private `const List<_GlossaryTerm>
// _terms = [...]` at the top of the file. Each `_GlossaryTerm` carries a
// term, an optional acronym, a category string, and a definition.
// `_GlossaryTerm.matches(query)` does case-insensitive substring search
// across all three text fields.
//
// The seven category tags (`_catCartridge`, `_catBallistics`, `_catPowder`,
// `_catPrimers`, `_catBrass`, `_catProcess`, `_catFirearm`) are defined as
// `const String`s so they appear by reference in every term and have one
// canonical spelling. The `_categoryOrder` list locks display order across
// the screen.
//
// `GlossaryScreen` is a `StatefulWidget` with two pieces of state:
//
//   - `_searchController` — drives the search text field
//   - `_query` — the current trimmed query string
//
// Rebuilds on every keystroke. `_filterAndGroup()` filters `_terms` by
// matching against `_query`, groups the survivors into a
// `Map<category, List<_GlossaryTerm>>`, sorts terms alphabetically inside
// each group, and returns the map.
//
// The body renders the search field at the top (with a clear-button
// suffix when non-empty), an optional match-count line ("12 matches"),
// and either an empty-state placeholder or a list of `_CategorySection`
// cards. Each section card has a tinted header (category name + count)
// and a list of `_GlossaryTermTile`s — `ExpansionTile`s that show the
// term + acronym in their tile and reveal the definition on tap.
//
// When the user is actively searching (`isSearching == true`),
// `_GlossaryTermTile`s render with `initiallyExpanded: true` so the
// matching definitions are visible without an extra tap. The
// `PageStorageKey` builds a fresh key whenever the expansion default
// changes, which forces the `ExpansionTile` to rebuild and pick up the
// new state.
//
// ============================================================================
// WHY IT EXISTS IN THE ARCHITECTURE
// ============================================================================
// Reloading has a dense vocabulary (CBTO, headspace, shoulder bump,
// freebore, BC G1 vs G7, MOA vs Mil, etc.) and the rest of the app
// uses these terms freely in field labels and tooltips. The glossary
// is the in-app safety net for users who haven't memorized every piece
// of jargon — they can swipe out the side drawer, search for a term,
// and read a plain-English definition without leaving the app.
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
// Two mildly subtle things:
//
//   1. The `PageStorageKey` on `_GlossaryTermTile` includes the
//      `initiallyExpanded` flag in its key string. That's deliberate:
//      `ExpansionTile` only honors `initiallyExpanded` once, when the
//      tile first builds. When the user starts searching, we want the
//      previously-built tiles to expand; the only reliable way to make
//      that happen is to give them a fresh widget identity, which a
//      different `PageStorageKey` does. Without this, terms wouldn't
//      auto-expand on search-to-search transitions.
//   2. The "no matches" empty-state and the search-clear button both
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
//
// ============================================================================
// SIDE EFFECTS
// ============================================================================
// None — pure rendering of compile-time `const` data. No I/O, no
// network, no plugin calls.

import 'package:flutter/material.dart';

/// A single glossary entry. Acronym is optional; not every term abbreviates.
class _GlossaryTerm {
  final String term;
  final String? acronym;
  final String category;
  final String definition;

  const _GlossaryTerm({
    required this.term,
    this.acronym,
    required this.category,
    required this.definition,
  });

  bool matches(String query) {
    if (query.isEmpty) return true;
    final q = query.toLowerCase();
    return term.toLowerCase().contains(q) ||
        (acronym?.toLowerCase().contains(q) ?? false) ||
        definition.toLowerCase().contains(q);
  }
}

const String _catCartridge = 'Cartridge anatomy & dimensions';
const String _catBallistics = 'Ballistics';
const String _catPowder = 'Powder & burn behavior';
const String _catPrimers = 'Primers';
const String _catBrass = 'Brass & case prep';
const String _catProcess = 'Reloading process';
const String _catFirearm = 'Firearm-side';

/// Display order for category sections.
const List<String> _categoryOrder = [
  _catCartridge,
  _catBallistics,
  _catPowder,
  _catPrimers,
  _catBrass,
  _catProcess,
  _catFirearm,
];

const List<_GlossaryTerm> _terms = [
  // Cartridge anatomy & dimensions
  _GlossaryTerm(
    term: 'Cartridge Overall Length',
    acronym: 'COAL',
    category: _catCartridge,
    definition:
        'The length of a loaded cartridge measured from the base of the case to the tip of the bullet (meplat). Useful for fitting a magazine, but it varies with bullet shape.',
  ),
  _GlossaryTerm(
    term: 'Cartridge Base To Ogive',
    acronym: 'CBTO',
    category: _catCartridge,
    definition:
        'The length from the base of the case to a fixed point on the bullet ogive, measured with a comparator. More repeatable than COAL because it ignores meplat variation.',
  ),
  _GlossaryTerm(
    term: 'Headspace',
    category: _catCartridge,
    definition:
        'The distance between the bolt face and the chamber feature that stops the cartridge (shoulder, case mouth, rim, or belt, depending on cartridge design). Excessive headspace can lead to case stretch or separation.',
  ),
  _GlossaryTerm(
    term: 'Case head',
    category: _catCartridge,
    definition:
        'The thick base of the cartridge case containing the primer pocket. It is the strongest part of the case and bears the rearward thrust of firing.',
  ),
  _GlossaryTerm(
    term: 'Case web',
    category: _catCartridge,
    definition:
        'The transition zone just forward of the case head where the brass is still thick. Case head separations typically begin here as the metal thins from repeated sizing.',
  ),
  _GlossaryTerm(
    term: 'Case body',
    category: _catCartridge,
    definition:
        'The main cylindrical (or slightly tapered) section of the case between the web and the shoulder. It holds the bulk of the powder charge.',
  ),
  _GlossaryTerm(
    term: 'Case shoulder',
    category: _catCartridge,
    definition:
        'The angled transition between the body and the neck on a bottlenecked cartridge. The shoulder is the headspacing datum on most modern bottleneck rounds.',
  ),
  _GlossaryTerm(
    term: 'Case neck',
    category: _catCartridge,
    definition:
        'The narrow portion of the case that grips the bullet. Neck wall thickness and condition strongly influence neck tension and concentricity.',
  ),
  _GlossaryTerm(
    term: 'Case mouth',
    category: _catCartridge,
    definition:
        'The open end of the case where the bullet is seated. It is chamfered and deburred during case prep to ease bullet seating without shaving copper.',
  ),
  _GlossaryTerm(
    term: 'Ogive',
    category: _catCartridge,
    definition:
        'The curved forward portion of a bullet between the bearing surface and the meplat. The shape of the ogive heavily influences ballistic coefficient.',
  ),
  _GlossaryTerm(
    term: 'Bearing surface',
    category: _catCartridge,
    definition:
        'The cylindrical, full-diameter portion of the bullet that engages the rifling. Length and uniformity of the bearing surface affect pressure and consistency.',
  ),
  _GlossaryTerm(
    term: 'Boattail',
    category: _catCartridge,
    definition:
        'A taper on the rear of a bullet that reduces base drag, especially at supersonic and transonic speeds. Common on long-range and match bullets.',
  ),
  _GlossaryTerm(
    term: 'Meplat',
    category: _catCartridge,
    definition:
        'The flat or rounded tip at the very front of a bullet. Meplat-to-meplat variation is one reason CBTO is preferred over COAL for measuring seated depth.',
  ),
  _GlossaryTerm(
    term: 'Cannelure',
    category: _catCartridge,
    definition:
        'A knurled or rolled groove around the bullet (or sometimes the case) used as a crimping point. Helps prevent bullet setback in semi-autos and tube magazines.',
  ),
  _GlossaryTerm(
    term: 'Crimp',
    category: _catCartridge,
    definition:
        'A deformation of the case mouth onto the bullet to lock it in place. The two main styles are taper crimp (used for cartridges that headspace on the case mouth) and roll crimp (used with cannelured bullets, often for revolvers and lever guns).',
  ),
  _GlossaryTerm(
    term: 'Taper crimp',
    category: _catCartridge,
    definition:
        'A crimp that gradually tightens the case mouth around the bullet without rolling it inward. Standard for semi-auto pistol rounds that headspace on the case mouth.',
  ),
  _GlossaryTerm(
    term: 'Roll crimp',
    category: _catCartridge,
    definition:
        'A crimp that rolls the case mouth into the bullet cannelure. Used for heavy-recoiling revolver loads and tube-fed lever guns to keep bullets from walking under recoil.',
  ),
  _GlossaryTerm(
    term: 'Neck tension',
    category: _catCartridge,
    definition:
        'The interference fit between the sized case neck and the bullet. Consistent neck tension is widely considered important for low-ES, low-SD loads.',
  ),
  _GlossaryTerm(
    term: 'Throat',
    category: _catCartridge,
    definition:
        'The unrifled portion of the bore just forward of the chamber where the bullet jumps before engaging the lands. Throats erode with use and lengthen over the life of a barrel.',
  ),
  _GlossaryTerm(
    term: 'Freebore',
    category: _catCartridge,
    definition:
        'A measurement related to the length of the throat — the distance a bullet travels before contacting the rifling. Different cartridges and chamber reamers specify different freebore lengths.',
  ),
  _GlossaryTerm(
    term: 'Lands and grooves',
    category: _catCartridge,
    definition:
        'The raised lands and recessed grooves cut as rifling inside the bore. The lands engrave the bullet and impart spin; the grooves define the bullet diameter the bore was cut for.',
  ),
  _GlossaryTerm(
    term: 'Twist rate',
    category: _catCartridge,
    definition:
        'How fast the rifling spins the bullet, expressed as one turn per N inches (e.g. 1:8). Faster twists stabilize longer, heavier bullets.',
  ),
  _GlossaryTerm(
    term: 'Bullet diameter vs. groove diameter',
    category: _catCartridge,
    definition:
        'Bullet diameter is the actual diameter of the projectile; groove diameter is the bore measurement at the bottom of the rifling grooves. The bullet should match (or very slightly exceed) groove diameter for a proper seal.',
  ),
  _GlossaryTerm(
    term: 'Case capacity (H₂O grains)',
    category: _catCartridge,
    definition:
        'Internal volume of a fired or sized case, traditionally measured in grains of water. Useful for comparing brass brands and predicting pressure differences with the same charge.',
  ),

  // Ballistics
  _GlossaryTerm(
    term: 'Minute of Angle',
    acronym: 'MOA',
    category: _catBallistics,
    definition:
        'An angular measurement equal to 1/60 of a degree, roughly 1.047 inches at 100 yards. Used for scope adjustments and group size.',
  ),
  _GlossaryTerm(
    term: 'Milliradian',
    acronym: 'MIL',
    category: _catBallistics,
    definition:
        'An angular measurement equal to 1/1000 of a radian, roughly 3.6 inches at 100 yards or 10 cm at 100 m. Common on tactical and modern long-range optics.',
  ),
  _GlossaryTerm(
    term: 'Ballistic Coefficient — G1',
    acronym: 'BC G1',
    category: _catBallistics,
    definition:
        'A measure of a bullet\'s drag relative to the G1 standard projectile (a flat-base, pointed reference shape). Convenient at common distances but tends to overstate performance for modern boattail bullets at long range.',
  ),
  _GlossaryTerm(
    term: 'Ballistic Coefficient — G7',
    acronym: 'BC G7',
    category: _catBallistics,
    definition:
        'BC referenced to the G7 standard projectile (a long boattail shape). Generally preferred for VLD and long-range bullets because it tracks their drag curve more accurately than G1.',
  ),
  _GlossaryTerm(
    term: 'Sectional Density',
    acronym: 'SD (sectional density)',
    category: _catBallistics,
    definition:
        'A bullet\'s mass divided by the square of its diameter. Higher SD generally means better penetration and is one input to ballistic coefficient.',
  ),
  _GlossaryTerm(
    term: 'Standard Deviation (sample)',
    acronym: 'SD (statistics)',
    category: _catBallistics,
    definition:
        'A statistical measure of velocity variation across a string of shots. Note: this acronym collides with Sectional Density — context decides which is meant.',
  ),
  _GlossaryTerm(
    term: 'Extreme Spread',
    acronym: 'ES',
    category: _catBallistics,
    definition:
        'The difference between the highest and lowest velocity in a shot string. A simple, widely cited consistency metric, though SD is generally a more robust descriptor.',
  ),
  _GlossaryTerm(
    term: 'Muzzle Velocity',
    acronym: 'MV / FPS',
    category: _catBallistics,
    definition:
        'The velocity of the bullet as it leaves the muzzle, usually reported in feet per second (FPS). It anchors every external ballistics calculation downrange.',
  ),
  _GlossaryTerm(
    term: 'Wind drift',
    category: _catBallistics,
    definition:
        'The horizontal deflection of a bullet caused by crosswind. Drift grows non-linearly with distance and is one of the dominant error sources at long range.',
  ),
  _GlossaryTerm(
    term: 'Spin drift',
    category: _catBallistics,
    definition:
        'A small horizontal deflection caused by the bullet\'s gyroscopic spin (also called gyroscopic or yaw-of-repose drift). Direction follows the rifling twist; it becomes noticeable at long range.',
  ),
  _GlossaryTerm(
    term: 'Coriolis effect',
    category: _catBallistics,
    definition:
        'A measurement related to the apparent deflection of a bullet caused by Earth\'s rotation during flight. Generally only relevant at extreme long range.',
  ),
  _GlossaryTerm(
    term: 'Yaw',
    category: _catBallistics,
    definition:
        'Angular misalignment between the bullet\'s axis and its line of flight. Excessive yaw degrades accuracy and can occur out of an unstable barrel-bullet pairing.',
  ),
  _GlossaryTerm(
    term: 'Drag',
    category: _catBallistics,
    definition:
        'The aerodynamic force decelerating the bullet in flight. Drag varies with velocity, air density, and bullet shape, and is captured indirectly by the ballistic coefficient.',
  ),
  _GlossaryTerm(
    term: 'Form factor',
    category: _catBallistics,
    definition:
        'A scalar describing how a bullet\'s drag compares to the reference projectile (G1, G7, etc.). Lower form factor means a more aerodynamically efficient bullet.',
  ),

  // Powder & burn behavior
  _GlossaryTerm(
    term: 'Burn rate',
    category: _catPowder,
    definition:
        'How quickly a powder converts to gas under chamber conditions. Faster powders peak pressure sooner and suit smaller cases; slower powders suit larger cases and heavier bullets.',
  ),
  _GlossaryTerm(
    term: 'Extruded powder',
    category: _catPowder,
    definition:
        'Powder formed into small cylindrical sticks (also called stick powder). Generally meters less consistently through volumetric throwers than ball powder but is widely used in rifle loads.',
  ),
  _GlossaryTerm(
    term: 'Spherical (ball) powder',
    category: _catPowder,
    definition:
        'Powder formed into small round or flattened spheres. Meters very well through powder throwers and tends to be temperature-sensitive depending on the formulation.',
  ),
  _GlossaryTerm(
    term: 'Flake powder',
    category: _catPowder,
    definition:
        'Powder shaped into small flat disks. Common in shotgun and pistol loads; bulky, fast-burning, and meters acceptably in most measures.',
  ),
  _GlossaryTerm(
    term: 'Charge weight',
    acronym: 'gr (grains)',
    category: _catPowder,
    definition:
        'The mass of powder in a single load, measured in grains (1 grain ≈ 0.0648 g). Reloading data is published in grains; never confuse grains with grams.',
  ),
  _GlossaryTerm(
    term: 'Case fill / load density',
    category: _catPowder,
    definition:
        'How much of the case\'s internal volume the powder charge occupies. Higher load density tends to give more consistent ignition; very low fill can produce erratic velocities.',
  ),
  _GlossaryTerm(
    term: 'Pressure',
    acronym: 'CUP / PSI',
    category: _catPowder,
    definition:
        'Peak chamber pressure during firing, measured by transducer (PSI) or older copper crusher methods (CUP). SAAMI and CIP publish maximum allowable pressures per cartridge.',
  ),
  _GlossaryTerm(
    term: 'Pressure signs',
    category: _catPowder,
    definition:
        'Physical indicators of overpressure: cratered or pierced primers, ejector marks on the case head, sticky bolt lift, flattened primers, and case head expansion. They are unreliable on their own — the safest path is to stay within published data.',
  ),
  _GlossaryTerm(
    term: 'Temperature sensitivity',
    category: _catPowder,
    definition:
        'How much a powder\'s velocity and pressure shift with ambient temperature. Powders marketed as temperature-stable (e.g. Vihtavuori N500-series, Alliant Reloder 16/26, Hodgdon Extreme/StaBALL) are formulated to minimize this drift.',
  ),
  _GlossaryTerm(
    term: 'Compressed load',
    category: _catPowder,
    definition:
        'A load in which the powder column is compressed by the seated bullet. Many published rifle loads are slightly compressed; heavy compression can affect ignition and seated depth stability.',
  ),
  _GlossaryTerm(
    term: 'Bridging',
    category: _catPowder,
    definition:
        'A condition where powder kernels jam against each other and resist flowing through a drop tube, funnel, or case neck. Common with long extruded powders and small case necks.',
  ),

  // Primers
  _GlossaryTerm(
    term: 'Boxer primer',
    category: _catPrimers,
    definition:
        'A primer design with a single central flash hole and a self-contained anvil. Used on virtually all U.S. commercial brass and is what makes that brass reloadable.',
  ),
  _GlossaryTerm(
    term: 'Berdan primer',
    category: _catPrimers,
    definition:
        'A primer design where the anvil is part of the case and there are two off-center flash holes. Common on European and military surplus brass; not practically reloadable with standard tools.',
  ),
  _GlossaryTerm(
    term: 'Small / large pistol / rifle primers',
    category: _catPrimers,
    definition:
        'Standard primer sizing. Pistol and rifle primers of the same diameter are not interchangeable: rifle primers have harder cups and different brisance to suit their applications.',
  ),
  _GlossaryTerm(
    term: 'Magnum primer',
    category: _catPrimers,
    definition:
        'A primer with a hotter, longer-duration flame. Often called for with ball powders, very large cases, or cold-weather loads where ignition needs help.',
  ),
  _GlossaryTerm(
    term: 'Benchrest primer',
    category: _catPrimers,
    definition:
        'A primer batch held to tighter manufacturing tolerances, marketed for precision shooters chasing low velocity SD. Real-world benefit is debated but common among match handloaders.',
  ),
  _GlossaryTerm(
    term: 'Primer pocket uniformity / depth',
    category: _catPrimers,
    definition:
        'A case prep step that cuts each primer pocket to a uniform depth and bottom geometry. The goal is consistent primer seating depth, which can improve ignition consistency.',
  ),
  _GlossaryTerm(
    term: 'Primer crimp / crimp removal',
    category: _catPrimers,
    definition:
        'Many military cases have a ring or stake crimp swaged into the primer pocket to retain the primer. It must be cut or swaged out before a new primer can be seated.',
  ),
  _GlossaryTerm(
    term: 'Primer cup hardness',
    category: _catPrimers,
    definition:
        'The hardness of the metal cup containing the priming compound. Harder cups resist piercing in high-pressure or AR-pattern actions; softer cups are easier for light striker hits to ignite.',
  ),

  // Brass / case prep
  _GlossaryTerm(
    term: 'Annealing',
    category: _catBrass,
    definition:
        'Heating the case neck and shoulder to relieve work-hardening from repeated sizing. Done correctly, it extends case life and stabilizes neck tension.',
  ),
  _GlossaryTerm(
    term: 'Trimming',
    category: _catBrass,
    definition:
        'Cutting cases back to a consistent length after they grow from firing and sizing. Overlong cases can pinch into the throat and spike pressure.',
  ),
  _GlossaryTerm(
    term: 'Chamfer / deburr',
    category: _catBrass,
    definition:
        'Beveling the inside (chamfer) and outside (deburr) of the case mouth after trimming. A clean chamfer lets bullets seat without shaving jacket material.',
  ),
  _GlossaryTerm(
    term: 'Full length sizing',
    category: _catBrass,
    definition:
        'Resizing the entire case body, shoulder, and neck back toward factory dimensions. Reliable for semi-autos and any rifle where chambering must be effortless.',
  ),
  _GlossaryTerm(
    term: 'Neck-only sizing',
    category: _catBrass,
    definition:
        'Resizing only the neck and leaving the body fire-formed to the chamber. Often used by bolt-action precision shooters who keep brass with a single rifle.',
  ),
  _GlossaryTerm(
    term: 'Body die',
    category: _catBrass,
    definition:
        'A die that sizes the case body and bumps the shoulder without touching the neck. Used in conjunction with separate neck sizing setups (bushing dies, mandrels).',
  ),
  _GlossaryTerm(
    term: 'Shoulder bump',
    category: _catBrass,
    definition:
        'Pushing the case shoulder back a small, controlled amount (typically 0.001–0.003") relative to its fired position. Provides reliable chambering without overworking the brass.',
  ),
  _GlossaryTerm(
    term: 'Mandrel sizing',
    category: _catBrass,
    definition:
        'Setting final neck inside diameter by pulling or pushing a precise rod (mandrel) through the neck after sizing. Tends to give very uniform neck tension and good concentricity.',
  ),
  _GlossaryTerm(
    term: 'Primer pocket cleaning / uniforming',
    category: _catBrass,
    definition:
        'Cleaning carbon out of fired primer pockets and optionally cutting them to a uniform depth. Both help primers seat squarely and consistently.',
  ),
  _GlossaryTerm(
    term: 'Case capacity weight sorting',
    category: _catBrass,
    definition:
        'Weighing prepped, empty cases as a proxy for internal volume and grouping similar cases together. The relationship between weight and capacity is imperfect but often correlates.',
  ),
  _GlossaryTerm(
    term: 'Spring back',
    category: _catBrass,
    definition:
        'The small amount a sized case (or neck) elastically expands after leaving the die. It is why bushings are typically chosen a couple thousandths under final desired diameter.',
  ),

  // Reloading process
  _GlossaryTerm(
    term: 'Decapping / depriming',
    category: _catProcess,
    definition:
        'Punching the spent primer out of a fired case, usually with a decapping pin in the sizing die or a dedicated decapping die. Often the first step of case prep.',
  ),
  _GlossaryTerm(
    term: 'Sizing die',
    category: _catProcess,
    definition:
        'A die that resizes a fired case toward chamber-ready dimensions. Comes in full length, neck, body, and bushing variants.',
  ),
  _GlossaryTerm(
    term: 'Seating die',
    category: _catProcess,
    definition:
        'A die that pushes the bullet into the case to a target depth. Micrometer-top seating dies give repeatable, fine seating-depth adjustments.',
  ),
  _GlossaryTerm(
    term: 'Crimping die',
    category: _catProcess,
    definition:
        'A die dedicated to applying a roll or taper crimp as a separate step from seating. Separating the operations often yields better consistency than crimp-while-seating.',
  ),
  _GlossaryTerm(
    term: 'Powder dispenser / thrower',
    category: _catProcess,
    definition:
        'A device that dispenses a measured charge of powder by volume (mechanical thrower) or weight (electronic dispenser). Volume-based throwers are fast; weight-based dispensers are precise.',
  ),
  _GlossaryTerm(
    term: 'Beam vs. electronic scale',
    category: _catProcess,
    definition:
        'Beam scales use mechanical balance and need no calibration drift management; electronic scales are fast and convenient but require warm-up, calibration, and protection from drafts. Many handloaders verify with both.',
  ),
  _GlossaryTerm(
    term: 'OAL gauge / Hornady comparator',
    category: _catProcess,
    definition:
        'Tools for measuring CBTO and finding the distance from the bolt face to the lands in your specific chamber. Essential for tuning seating depth.',
  ),
  _GlossaryTerm(
    term: 'Concentricity gauge',
    category: _catProcess,
    definition:
        'A fixture that measures runout of the loaded bullet relative to the case body. Helps diagnose dies, brass, and seating issues that produce crooked rounds.',
  ),
  _GlossaryTerm(
    term: 'Chronograph',
    category: _catProcess,
    definition:
        'An instrument for measuring projectile velocity. Common types include optical screens, magnetic (MagnetoSpeed), and Doppler radar units (LabRadar, Garmin Xero, Caldwell Velocimeter).',
  ),
  _GlossaryTerm(
    term: 'Load development',
    category: _catProcess,
    definition:
        'The process of working up a load by varying charge, seating depth, and components while observing pressure and group behavior. Common methods include ladder tests, OCW, the Satterlee 10-shot, and the Audette ladder.',
  ),
  _GlossaryTerm(
    term: 'Ladder test',
    category: _catProcess,
    definition:
        'A load development method where each shot uses a slightly larger charge, fired at a distant target to spot vertical clusters that suggest a stable charge window.',
  ),
  _GlossaryTerm(
    term: 'OCW (Optimal Charge Weight)',
    acronym: 'OCW',
    category: _catProcess,
    definition:
        'A load development method that fires round-robin groups across a charge range looking for a "scatter node" where point of impact is insensitive to small charge changes. Popularized by Dan Newberry.',
  ),
  _GlossaryTerm(
    term: 'Satterlee 10-shot test',
    category: _catProcess,
    definition:
        'A load development method that fires a single round at each of 10 ascending charges over a chronograph and looks for a velocity flat spot. Its statistical validity is debated, but it remains popular.',
  ),
  _GlossaryTerm(
    term: 'Audette ladder',
    category: _catProcess,
    definition:
        'The classic ladder test described by Creighton Audette: one shot per charge, ascending, fired at long range to read vertical stringing on the target.',
  ),
  _GlossaryTerm(
    term: 'Velocity / accuracy node',
    category: _catProcess,
    definition:
        'A charge or seating-depth window where the load is relatively insensitive to small changes — either in velocity (flat spot on a velocity curve) or accuracy (stable group point of impact).',
  ),
  _GlossaryTerm(
    term: 'Scatter node vs. flat node',
    category: _catProcess,
    definition:
        'Terminology from OCW: a "scatter node" is the unstable charge zone where groups open and shift; a "flat node" is the stable window between scatter nodes where the rifle shoots well across a small charge range.',
  ),

  // Firearm-side
  _GlossaryTerm(
    term: 'Barrel length',
    category: _catFirearm,
    definition:
        'Length of the barrel from breech to muzzle (or muzzle device shoulder, depending on convention). Longer barrels generally yield more velocity, up to the burn-rate limit of the powder.',
  ),
  _GlossaryTerm(
    term: 'Action',
    category: _catFirearm,
    definition:
        'The mechanism that loads, locks, and unloads cartridges. Common types include bolt action, semi-automatic, lever action, pump, and break-open.',
  ),
  _GlossaryTerm(
    term: 'Headspacing',
    category: _catFirearm,
    definition:
        'How a chamber controls the position of the cartridge so the primer is the correct distance from the bolt face. Different cartridges headspace on the shoulder, case mouth, rim, or belt.',
  ),
  _GlossaryTerm(
    term: 'Chamber',
    category: _catFirearm,
    definition:
        'The rear portion of the bore that supports the cartridge during firing. Chamber dimensions are cut to a reamer print derived from SAAMI or CIP specs.',
  ),
  _GlossaryTerm(
    term: 'SAAMI vs. CIP specs',
    category: _catFirearm,
    definition:
        'SAAMI (U.S.) and CIP (Europe) are the two main standards bodies that publish chamber, cartridge, and pressure specifications. The two specs sometimes differ slightly for the same nominal cartridge.',
  ),
  _GlossaryTerm(
    term: 'Free-floated barrel',
    category: _catFirearm,
    definition:
        'A barrel that does not contact the stock or handguard along its length. Eliminates inconsistent stock pressure on the barrel and is a common precision feature.',
  ),
  _GlossaryTerm(
    term: 'Bedding',
    category: _catFirearm,
    definition:
        'How the action is mated to the stock or chassis. Common methods include pillar bedding (metal pillars for screw torque), glass bedding (epoxy fit), and V-block / chassis systems.',
  ),
  _GlossaryTerm(
    term: 'Cant / level your reticle',
    category: _catFirearm,
    definition:
        'Cant is any roll of the rifle around the bore axis; a tilted reticle shifts impact horizontally as you dial elevation. Using a bubble level on the scope or rail keeps the reticle vertical.',
  ),
  _GlossaryTerm(
    term: 'Velocity loss per inch (rule of thumb)',
    category: _catFirearm,
    definition:
        'A rough rule of thumb: cutting a rifle barrel typically loses on the order of 20–50 fps per inch, depending on cartridge and powder. Treat this as an estimate, not a prediction.',
  ),
];

class GlossaryScreen extends StatefulWidget {
  const GlossaryScreen({super.key});

  @override
  State<GlossaryScreen> createState() => _GlossaryScreenState();
}

class _GlossaryScreenState extends State<GlossaryScreen> {
  final TextEditingController _searchController = TextEditingController();
  String _query = '';

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Map<String, List<_GlossaryTerm>> _filterAndGroup() {
    final filtered = _terms.where((t) => t.matches(_query)).toList();
    final grouped = <String, List<_GlossaryTerm>>{};
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
                      itemCount: visibleCategories.length,
                      itemBuilder: (context, index) {
                        final category = visibleCategories[index];
                        final entries = grouped[category]!;
                        return _CategorySection(
                          category: category,
                          terms: entries,
                          autoExpand: isSearching,
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

class _CategorySection extends StatelessWidget {
  final String category;
  final List<_GlossaryTerm> terms;
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

class _GlossaryTermTile extends StatelessWidget {
  final _GlossaryTerm term;
  final bool initiallyExpanded;

  const _GlossaryTermTile({
    required this.term,
    required this.initiallyExpanded,
  });

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    // Force rebuild of the ExpansionTile when the search-driven default
    // expansion state changes by keying on the value.
    return ExpansionTile(
      key: PageStorageKey<String>(
        '${term.category}:${term.term}:$initiallyExpanded',
      ),
      initiallyExpanded: initiallyExpanded,
      tilePadding: const EdgeInsets.symmetric(horizontal: 16),
      // 12px top padding so the first definition row isn't visually
      // clipped by the term-row above it.
      childrenPadding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
      title: Text(
        term.term,
        style: textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w600),
      ),
      subtitle: term.acronym == null
          ? null
          : Text(
              term.acronym!,
              style: textTheme.bodySmall?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
      children: [
        Align(
          alignment: Alignment.centerLeft,
          child: Text(
            term.definition,
            style: textTheme.bodyMedium,
          ),
        ),
      ],
    );
  }
}
