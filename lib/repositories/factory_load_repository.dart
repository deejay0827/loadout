// FILE: lib/repositories/factory_load_repository.dart
//
// ============================================================================
// WHAT THIS FILE DOES
// ============================================================================
// Bridges the `FactoryLoads` drift table (added schema v14, see
// `database.dart`) with the ballistics calculator and Range Day workspace.
// A "factory load" is one published cartridge SKU — e.g. "Hornady Match
// 6.5 Creedmoor 140 gr ELD-Match" — with the manufacturer's published
// muzzle velocity and ballistic coefficient.
//
// Public API:
//
//   * [FactoryLoadEntry] — joined row of `FactoryLoadRow` + the
//     `ManufacturerRow` it points at, with an optional `DragCurveRow`
//     when the catalog has a custom drag curve matching the load's
//     bullet (looked up loosely on `(manufacturer, bulletName, weight,
//     diameter)`). The screens consume these joined records directly.
//
//   * [allWithCurves] — every factory load in the catalog, ordered by
//     manufacturer / line / caliber / bullet weight, joined with its
//     manufacturer and (optionally) a matching drag curve. Used by
//     the calculator's "Factory Ammo" picker.
//
//   * [byCaliber] — the same joined rows, filtered to a specific
//     cartridge name. The screen uses this when the user has already
//     told the calculator their caliber, to keep the picker manageable.
//
//   * [byId] — single-row lookup. The picker stores only the id of the
//     selected load in the screen state; this getter resolves it back
//     to a joined entry when the user taps Calculate.
//
//   * [watchAll] — live stream of the same set, for any UI that wants
//     to react to a re-seed (e.g. an admin "force re-seed" button).
//
//   * [allManufacturers] — distinct list of manufacturers that have at
//     least one factory load. Used by the cascading picker UI on the
//     ballistics screen.
//
// ============================================================================
// WHY IT EXISTS IN THE ARCHITECTURE
// ============================================================================
// Mirror of `DragCurveRepository` and `OpticsRepository` — a thin layer
// that owns all queries against one reference table. Factory loads are
// intentionally kept OUT of `ComponentRepository` because that layer
// surfaces reloading components for the recipe form, and factory ammo
// is a full cartridge (not a handload component) — see CLAUDE.md
// note "Factory ammo is a SEPARATE entity from reloading components".
//
// ============================================================================
// SIDE EFFECTS
// ============================================================================
// None beyond drift query I/O. All reads.
library;

import 'package:drift/drift.dart';

import '../database/database.dart';
import '../services/ballistics/custom_drag.dart';
import 'drag_curve_repository.dart';

/// Joined factory-load row with its manufacturer and (optionally) a
/// matching custom drag curve. The screens want all three pieces in one
/// fetch — the picker label needs the manufacturer name, the auto-fill
/// path consumes the load's BC + MV, and the "use 4DOF curve" hint
/// surfaces only when the catalog has a matching drag curve.
class FactoryLoadEntry {
  const FactoryLoadEntry({
    required this.load,
    required this.manufacturer,
    this.dragCurve,
  });

  final FactoryLoadRow load;
  final ManufacturerRow manufacturer;
  /// Custom drag curve that matches this load's bullet, if one exists
  /// in the `DragCurves` catalog. Null when no curve is bundled — the
  /// solver still works (it falls back to the load's BC + G7 / G1
  /// curve), but the calculator hides the "Use 4DOF curve" affordance.
  final DragCurveRow? dragCurve;

  /// Composed display label for the picker dropdown:
  /// `"Hornady Match 6.5 Creedmoor 140gr ELD-Match"`.
  String get displayLabel {
    final w = load.bulletWeightGr;
    final weightStr =
        w.truncateToDouble() == w ? w.toStringAsFixed(0) : w.toStringAsFixed(1);
    return '${manufacturer.name} ${load.productLine} ${load.caliber} '
        '${weightStr}gr ${load.bulletName}';
  }

  /// Constructs a [CustomDragCurve] from the linked drag curve, or
  /// returns null when no curve is linked. Keeps the curve-decoding
  /// concern contained inside this entry record so the screen doesn't
  /// have to know about JSON / drift internals.
  CustomDragCurve? toCustomDragCurve() {
    final c = dragCurve;
    if (c == null) return null;
    return DragCurveRepository.toCustomDragCurve(c);
  }
}

class FactoryLoadRepository {
  FactoryLoadRepository(this.db);
  final AppDatabase db;

  /// Watch every factory-load row in the catalog, ordered for display.
  /// Each emit replaces the previous list — drift handles the diffing.
  Stream<List<FactoryLoadRow>> watchAll() {
    return (db.select(db.factoryLoads)
          ..orderBy([
            (t) => OrderingTerm(expression: t.productLine),
            (t) => OrderingTerm(expression: t.caliber),
            (t) => OrderingTerm(expression: t.bulletWeightGr),
          ]))
        .watch();
  }

  /// One-shot fetch of every factory load joined with its manufacturer
  /// and (optionally) a matching drag curve. Used by the calculator's
  /// "Factory Ammo" picker on initial load.
  ///
  /// The drag-curve match is intentionally loose: identical bullet
  /// name, weight within ±0.5 gr, diameter within ±0.0015 in. This
  /// catches "Hornady ELD-Match" against "Hornady ELD-Match" both with
  /// 140 gr / 0.264" but tolerates the ±0.001 rounding noise sometimes
  /// found in published spec sheets.
  Future<List<FactoryLoadEntry>> allWithCurves() async {
    final loads = await (db.select(db.factoryLoads)
          ..orderBy([
            (t) => OrderingTerm(expression: t.productLine),
            (t) => OrderingTerm(expression: t.caliber),
            (t) => OrderingTerm(expression: t.bulletWeightGr),
          ]))
        .get();
    if (loads.isEmpty) return const [];
    final manufacturerIds = loads.map((l) => l.manufacturerId).toSet();
    final manufacturers = await (db.select(db.manufacturers)
          ..where((m) => m.id.isIn(manufacturerIds)))
        .get();
    final mfgById = {for (final m in manufacturers) m.id: m};
    final allCurves = await db.select(db.dragCurves).get();
    final entries = <FactoryLoadEntry>[];
    for (final l in loads) {
      final mfg = mfgById[l.manufacturerId];
      if (mfg == null) continue;
      final curve = _findCurveForLoad(l, mfg, allCurves);
      entries.add(FactoryLoadEntry(
        load: l,
        manufacturer: mfg,
        dragCurve: curve,
      ));
    }
    return entries;
  }

  /// Filtered variant of [allWithCurves]. The screen calls this once
  /// the user selects a caliber to keep the picker compact — a 3 000-
  /// row dropdown is unusable on a phone, but a 50-row dropdown of
  /// "Hornady Match 6.5 Creedmoor 140gr ELD-Match" / "Federal Gold
  /// Medal Berger 6.5 Creedmoor 130gr Hybrid OTM" / etc. is fine.
  ///
  /// Matching on caliber is intentionally exact-string: the seed file
  /// stores the cartridge name as the manufacturer prints it on the
  /// box ("6.5 Creedmoor", ".308 Win"), and the picker UI passes
  /// through whatever the user picked from the cartridge dropdown.
  /// If the spelling differs slightly the cascading picker simply
  /// returns no rows; the user can fall back to the unfiltered
  /// dropdown.
  Future<List<FactoryLoadEntry>> byCaliber(String caliber) async {
    final loads = await (db.select(db.factoryLoads)
          ..where((t) => t.caliber.equals(caliber))
          ..orderBy([
            (t) => OrderingTerm(expression: t.productLine),
            (t) => OrderingTerm(expression: t.bulletWeightGr),
          ]))
        .get();
    if (loads.isEmpty) return const [];
    final manufacturerIds = loads.map((l) => l.manufacturerId).toSet();
    final manufacturers = await (db.select(db.manufacturers)
          ..where((m) => m.id.isIn(manufacturerIds)))
        .get();
    final mfgById = {for (final m in manufacturers) m.id: m};
    final allCurves = await db.select(db.dragCurves).get();
    final entries = <FactoryLoadEntry>[];
    for (final l in loads) {
      final mfg = mfgById[l.manufacturerId];
      if (mfg == null) continue;
      final curve = _findCurveForLoad(l, mfg, allCurves);
      entries.add(FactoryLoadEntry(
        load: l,
        manufacturer: mfg,
        dragCurve: curve,
      ));
    }
    return entries;
  }

  /// Single-row lookup by primary key, joined with its manufacturer
  /// and (optionally) matching drag curve. Used when restoring a
  /// previously-selected factory load from screen state.
  Future<FactoryLoadEntry?> byId(int id) async {
    final l = await (db.select(db.factoryLoads)..where((t) => t.id.equals(id)))
        .getSingleOrNull();
    if (l == null) return null;
    final mfg = await (db.select(db.manufacturers)
          ..where((m) => m.id.equals(l.manufacturerId)))
        .getSingleOrNull();
    if (mfg == null) return null;
    final curves = await db.select(db.dragCurves).get();
    final curve = _findCurveForLoad(l, mfg, curves);
    return FactoryLoadEntry(load: l, manufacturer: mfg, dragCurve: curve);
  }

  /// Distinct list of manufacturers (by name) that have at least one
  /// factory load. Drives the cascading picker — manufacturer first,
  /// then product line, then caliber + weight.
  Future<List<ManufacturerRow>> allManufacturers() async {
    final loads = await db.select(db.factoryLoads).get();
    if (loads.isEmpty) return const [];
    final ids = loads.map((l) => l.manufacturerId).toSet();
    return (db.select(db.manufacturers)
          ..where((m) => m.id.isIn(ids))
          ..orderBy([(m) => OrderingTerm(expression: m.name)]))
        .get();
  }

  /// Find the catalog curve (if any) that matches a factory load's
  /// bullet. Loose match: identical bullet name + weight ±0.5 gr +
  /// diameter ±0.0015 in. Returns null when no curve is bundled.
  static DragCurveRow? _findCurveForLoad(
    FactoryLoadRow load,
    ManufacturerRow mfg,
    List<DragCurveRow> curves,
  ) {
    DragCurveRow? best;
    var bestDelta = double.infinity;
    final loadBulletLower = load.bulletName.toLowerCase();
    final loadDiameter = load.bulletDiameterIn;
    for (final c in curves) {
      // Hard filter: same manufacturer.
      if (c.manufacturer.toLowerCase() != mfg.name.toLowerCase()) continue;
      // Bullet name compares loosely — Hornady ships the same
      // "ELD-Match" bullet under both reloading-component and factory
      // catalogs, so the strings should align after lowercasing.
      final cLineLower = c.line.toLowerCase();
      final lineMatches = cLineLower == loadBulletLower ||
          cLineLower.contains(loadBulletLower) ||
          loadBulletLower.contains(cLineLower);
      if (!lineMatches) continue;
      final dWeight = (c.weightGr - load.bulletWeightGr).abs();
      if (dWeight > 0.5) continue;
      if (loadDiameter != null) {
        final dDiam = (c.diameterIn - loadDiameter).abs();
        if (dDiam > 0.0015) continue;
      }
      final delta = dWeight + (loadDiameter == null
          ? 0.0
          : (c.diameterIn - loadDiameter).abs() * 1000.0);
      if (delta < bestDelta) {
        bestDelta = delta;
        best = c;
      }
    }
    return best;
  }
}
