// FILE: lib/repositories/optics_repository.dart
//
// ============================================================================
// WHAT THIS FILE DOES
// ============================================================================
// Owns all reads of the seeded `Optics` reference catalog (added in schema
// v7) for the rifle-scope dropdown on the firearm form. The underlying
// drift table is `Optics`; manufacturer info lives in the shared
// `Manufacturers` table joined on `manufacturerId`.
//
// Public methods on `OpticsRepository`:
//   * `allOptics()` — one-shot snapshot of every optic in the reference
//     catalog joined with its manufacturer. Returned as a list of records
//     `({OpticRow optic, ManufacturerRow manufacturer})`, naturally sorted
//     by manufacturer name then model. The dropdown on the firearm form
//     is the only consumer; nothing else needs a stream.
//   * `byId(id)` — one-shot lookup of a single optic by primary key.
//     Used by the firearm form when the user opens an existing firearm
//     to edit it: we hand-back the saved `opticsId` and the form needs
//     to find the matching `_OpticEntry` so the dropdown shows it
//     pre-selected.
//
// ============================================================================
// WHY IT EXISTS IN THE ARCHITECTURE
// ============================================================================
// Same repository pattern used everywhere else in the app. Rather than
// having `firearm_form_screen.dart` issue raw drift queries against the
// `Optics` and `Manufacturers` tables, all of that lives here. Adding
// validation, stream-based UI, or filtering by category later only
// requires changing this one file.
//
// The repository is constructed once in `lib/app.dart` and provided to
// the widget tree via `Provider<OpticsRepository>`. Screens read it with
// `context.read<OpticsRepository>()`.
//
// ============================================================================
// WHO CONSUMES THIS FILE
// ============================================================================
// - lib/screens/firearms/firearm_form_screen.dart — uses `allOptics()`
//   to populate the optic-pick dropdown.
// - lib/app.dart — constructs and provides the singleton.
//
// ============================================================================
// SIDE EFFECTS
// ============================================================================
// Reads against the local SQLite database via drift. No writes (this is
// a reference-catalog repository, like `ComponentRepository`'s reference
// firearms surface). No network. No shared preferences.

import 'package:drift/drift.dart';

import '../database/database.dart';
import '../utils/natural_sort.dart';

typedef OpticEntry = ({OpticRow optic, ManufacturerRow manufacturer});

class OpticsRepository {
  OpticsRepository(this.db);
  final AppDatabase db;

  /// Returns every optic in the reference catalog joined with its
  /// manufacturer. Naturally sorted by manufacturer name, then model
  /// (so "Vortex Razor HD Gen II" comes before "Vortex Razor HD Gen III"
  /// and "Schmidt & Bender PM II 3-20x50" sorts correctly against
  /// "PM II 5-25x56").
  Future<List<OpticEntry>> allOptics() async {
    final rows = await (db.select(db.optics).join([
      innerJoin(db.manufacturers,
          db.manufacturers.id.equalsExp(db.optics.manufacturerId)),
    ])).get();
    final list = rows.map((row) {
      final optic = row.readTable(db.optics);
      final mfg = row.readTable(db.manufacturers);
      return (optic: optic, manufacturer: mfg);
    }).toList();
    list.sort((a, b) {
      final mfgCmp = naturalCompare(a.manufacturer.name, b.manufacturer.name);
      if (mfgCmp != 0) return mfgCmp;
      return naturalCompare(a.optic.model, b.optic.model);
    });
    return list;
  }

  /// One-shot lookup of a single optic by primary key. Returns null if
  /// no row matches.
  Future<OpticRow?> byId(int id) =>
      (db.select(db.optics)..where((o) => o.id.equals(id)))
          .getSingleOrNull();
}
