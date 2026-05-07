// FILE: lib/data/reticle_library.dart
//
// ============================================================================
// WHAT THIS FILE DOES
// ============================================================================
// Public types for the LoadOut reticle library. A "reticle" is the etched
// or projected aiming pattern inside a rifle scope, red-dot, or LPVO
// (e.g. Vortex EBR-7C MRAD, Nightforce MIL-XT, the legacy USMC Mil-Dot).
// Every brand publishes a different mix of crosshair lines, hash marks,
// holdover dots, and floating numbers; this file defines the smallest
// vocabulary of element types we need to reproduce a recognisable
// rendering of any of them.
//
// The seed catalog (`assets/seed_data/reticles.json`) and the on-device
// SQLite reference table (`Reticles`, schema v11) both store reticle
// elements as JSON arrays whose entries match `ReticleElement.toJson()`
// here. The renderer (`lib/widgets/reticle_renderer.dart`) reads the
// decoded `ReticleDefinition` and paints it onto a `CustomPainter`
// canvas using the conversion described below.
//
// ============================================================================
// DESIGN NOTES
// ============================================================================
// All reticle coordinates are stored in the reticle's *native unit*
// (mil, MOA, IPSC sub-tensions, BDC steps). The renderer converts
// native units to widget pixels by:
//
//   pixelsPerUnit = (size.shortestSide * 0.45) / (maxExtentUnits / scale)
//
// This means `maxExtentUnits` ([reticle.maxExtentUnits]) is the half-extent
// from center to the edge of the visible reticle (e.g. 10 for "10 mil to
// each side"). With `scale: 1.0`, that half-extent fills 45% of the
// shortest widget side, which gives a comfortable border around the
// reticle on a square canvas while still leaving room for unit overlays
// in the corner.
//
// `displayUnit` on the renderer can differ from `nativeUnit` — in that
// case the geometry of the reticle stays unchanged but any text labels
// (floating numbers) are converted using the standard mil ↔ MOA
// conversion (1 mil = 3.43775 MOA).
//
// `maxExtentUnits` is approximate — a Mil-Dot reticle is typically drawn
// out to 4-5 mil per side, an EBR-7C ranges to 10 mil per side, and most
// MOA reticles publish out to 30 MOA. Those are the values used for
// most of the seed entries.
//
// ============================================================================
// ELEMENT TYPES
// ============================================================================
// `CrosshairLine` — a straight line from (startX,startY) to (endX,endY)
// in native units. Used for the main horizontal and vertical crosshair,
// plus any tertiary lines (e.g. wind dots).
//
// `HashMark` — a single tick perpendicular to a crosshair axis. The
// `axis` field is `horizontal` if the tick is along the horizontal
// crosshair (so the tick draws vertically), `vertical` if the tick is
// along the vertical crosshair (so the tick draws horizontally).
//
// `CenterDot` — a filled or open circle. Most reticles have one at
// (0, 0); some BDC reticles place additional dots at known holdover
// distances.
//
// `FloatingNumber` — a small floating numeric label, typically used to
// annotate large hash marks ("2", "4", "6", "8" in mils for example).
//
// `HoldoverDot` — a labelled holdover dot used by BDC-style reticles
// (Dead-Hold BDC, Strike Eagle's AR-BDC3). Renders identical to a
// `CenterDot` with `open: false`, but kept as a distinct type so the
// JSON schema and seed data make their intent clear.
//
// ============================================================================
// SERIALIZATION
// ============================================================================
// Every concrete `ReticleElement` carries a unique `type` string in its
// JSON form (`crosshair`, `hash`, `dot`, `number`, `holdover`). The
// `ReticleElement.fromJson(...)` static method dispatches on that field
// and returns the right concrete subtype.
//
// `ReticleDefinition.fromJson(...)` consumes the shape stored in the
// seed file:
//
// ```
// {
//   "id": "vortex_ebr7c_mrad",
//   "manufacturer": "Vortex",
//   "model": "EBR-7C MRAD",
//   "family": "Razor HD Gen II reticles",
//   "type": "ffp",
//   "nativeUnit": "mil",
//   "maxExtentUnits": 10,
//   "elements": [
//     {"type":"crosshair","startX":-10,"startY":0,"endX":10,"endY":0,"thickness":0.04,"primary":true},
//     {"type":"hash","x":1,"y":0,"length":0.4,"thickness":0.04,"axis":"horizontal"},
//     ...
//   ],
//   "notes": "Vortex's most popular precision-rifle MRAD reticle."
// }
// ```

import 'dart:convert';

/// Whether the reticle is on the first focal plane (etched on the front
/// erector lens, so its subtensions stay correct at every magnification),
/// the second focal plane (rear, so subtensions only match at the
/// reticle-spec magnification), or fixed (a non-zoom optic — red dot,
/// prism). Used both for the unit overlay text and to decide whether to
/// scale the rendered reticle with magnification (a future hook).
enum ReticleType { firstFocalPlane, secondFocalPlane, fixed }

/// The reticle's native angular unit. Most precision rifle reticles are
/// either `mil` (Vortex EBR-7C, Nightforce MIL-XT, Schmidt & Bender P4F)
/// or `moa` (Leupold TMOA, Vortex EBR-2D MOA). `ipsc` and `bdc` are
/// included for shape-specific reticles (Trijicon BAC chevron, Dead-Hold
/// BDC) where the subtensions are tied to the reticle's calibrated load
/// rather than a true angular unit.
enum ReticleNativeUnit { mil, moa, ipsc, bdc }

/// Whether a hash mark is drawn perpendicular to the horizontal axis
/// (axis = horizontal: the tick stands vertically, used to subdivide the
/// horizontal crosshair) or perpendicular to the vertical axis (axis =
/// vertical: the tick lies horizontally, used to subdivide the vertical
/// crosshair).
enum HashAxis { horizontal, vertical }

/// One drawable element inside a reticle definition. Sealed so the
/// renderer can `switch` on the runtime type without a default branch.
sealed class ReticleElement {
  const ReticleElement();

  /// Encode this element as a JSON-compatible map. The `type` field
  /// distinguishes subtypes for `ReticleElement.fromJson(...)`.
  Map<String, dynamic> toJson();

  /// Parse one element from the seed JSON. Returns the right concrete
  /// subtype based on the `type` field.
  static ReticleElement fromJson(Map<String, dynamic> json) {
    final type = json['type'] as String;
    switch (type) {
      case 'crosshair':
        return CrosshairLine(
          startX: (json['startX'] as num).toDouble(),
          startY: (json['startY'] as num).toDouble(),
          endX: (json['endX'] as num).toDouble(),
          endY: (json['endY'] as num).toDouble(),
          thicknessMil: (json['thickness'] as num?)?.toDouble() ?? 0.04,
          primary: json['primary'] as bool? ?? true,
        );
      case 'hash':
        return HashMark(
          x: (json['x'] as num).toDouble(),
          y: (json['y'] as num).toDouble(),
          lengthUnits: (json['length'] as num).toDouble(),
          thicknessUnits: (json['thickness'] as num?)?.toDouble() ?? 0.04,
          axis: (json['axis'] as String? ?? 'horizontal') == 'vertical'
              ? HashAxis.vertical
              : HashAxis.horizontal,
        );
      case 'dot':
        return CenterDot(
          x: (json['x'] as num?)?.toDouble() ?? 0.0,
          y: (json['y'] as num?)?.toDouble() ?? 0.0,
          radiusUnits: (json['radius'] as num).toDouble(),
          open: json['open'] as bool? ?? false,
        );
      case 'number':
        return FloatingNumber(
          x: (json['x'] as num).toDouble(),
          y: (json['y'] as num).toDouble(),
          text: json['text'] as String,
          fontSizeUnits: (json['size'] as num?)?.toDouble() ?? 0.5,
        );
      case 'holdover':
        return HoldoverDot(
          x: (json['x'] as num).toDouble(),
          y: (json['y'] as num).toDouble(),
          radiusUnits: (json['radius'] as num?)?.toDouble() ?? 0.06,
        );
      default:
        throw ArgumentError('Unknown reticle element type: $type');
    }
  }
}

/// A straight line from (`startX`,`startY`) to (`endX`,`endY`) in the
/// reticle's native units, with center at (0, 0). Used for both
/// horizontal and vertical crosshairs and any auxiliary lines (e.g.
/// floating wind brackets in a Tremor reticle).
///
/// `primary` is a hint to the renderer / future zoom logic: primary
/// lines stay visible at all zoom levels, secondary lines may disappear
/// when zoomed out. For now the renderer treats both the same.
class CrosshairLine extends ReticleElement {
  const CrosshairLine({
    required this.startX,
    required this.startY,
    required this.endX,
    required this.endY,
    this.thicknessMil = 0.04,
    this.primary = true,
  });

  final double startX;
  final double startY;
  final double endX;
  final double endY;

  /// Stroke width in the reticle's native unit. Renderer converts
  /// to pixels using the same `pixelsPerUnit` factor.
  final double thicknessMil;

  /// `true` for the main horizontal/vertical crosshair (always
  /// rendered). `false` for tertiary lines that may be hidden at low
  /// zoom (currently rendered identically).
  final bool primary;

  @override
  Map<String, dynamic> toJson() => {
        'type': 'crosshair',
        'startX': startX,
        'startY': startY,
        'endX': endX,
        'endY': endY,
        'thickness': thicknessMil,
        'primary': primary,
      };
}

/// A single tick mark perpendicular to a crosshair axis. `axis ==
/// horizontal` means "this tick belongs to the horizontal crosshair,
/// so it renders as a short vertical line at (x, y)". `axis ==
/// vertical` means "this tick belongs to the vertical crosshair, so
/// it renders as a short horizontal line at (x, y)".
class HashMark extends ReticleElement {
  const HashMark({
    required this.x,
    required this.y,
    required this.lengthUnits,
    this.thicknessUnits = 0.04,
    required this.axis,
  });

  final double x;
  final double y;

  /// Total tick length in native units (the renderer draws half that
  /// length above and half below the crosshair).
  final double lengthUnits;
  final double thicknessUnits;
  final HashAxis axis;

  @override
  Map<String, dynamic> toJson() => {
        'type': 'hash',
        'x': x,
        'y': y,
        'length': lengthUnits,
        'thickness': thicknessUnits,
        'axis': axis == HashAxis.horizontal ? 'horizontal' : 'vertical',
      };
}

/// A circle centered at (`x`, `y`). `open: true` draws an outline,
/// `false` draws a filled disc. Most reticles have a single center
/// dot at (0, 0); some include additional dots elsewhere.
class CenterDot extends ReticleElement {
  const CenterDot({
    this.x = 0.0,
    this.y = 0.0,
    required this.radiusUnits,
    this.open = false,
  });

  final double x;
  final double y;
  final double radiusUnits;
  final bool open;

  @override
  Map<String, dynamic> toJson() => {
        'type': 'dot',
        'x': x,
        'y': y,
        'radius': radiusUnits,
        'open': open,
      };
}

/// A small text label floating at (`x`, `y`). Used by reticles that
/// label major hash marks with their subtension value (e.g. "2", "4",
/// "6" mil). Font size is in native units so the label scales with
/// the reticle when the widget grows.
class FloatingNumber extends ReticleElement {
  const FloatingNumber({
    required this.x,
    required this.y,
    required this.text,
    this.fontSizeUnits = 0.5,
  });

  final double x;
  final double y;
  final String text;
  final double fontSizeUnits;

  @override
  Map<String, dynamic> toJson() => {
        'type': 'number',
        'x': x,
        'y': y,
        'text': text,
        'size': fontSizeUnits,
      };
}

/// A holdover dot on a BDC-style reticle. Renders identically to a
/// filled `CenterDot` but kept as a distinct type so seed data can
/// declare intent (and a future renderer can highlight it on hover).
class HoldoverDot extends ReticleElement {
  const HoldoverDot({
    required this.x,
    required this.y,
    this.radiusUnits = 0.06,
  });

  final double x;
  final double y;
  final double radiusUnits;

  @override
  Map<String, dynamic> toJson() => {
        'type': 'holdover',
        'x': x,
        'y': y,
        'radius': radiusUnits,
      };
}

/// One reticle definition. Constructed either from a `Reticles` row
/// (via the repository) or directly from a JSON entry in
/// `assets/seed_data/reticles.json`.
class ReticleDefinition {
  const ReticleDefinition({
    required this.id,
    required this.manufacturer,
    required this.model,
    this.family,
    required this.type,
    required this.nativeUnit,
    required this.elements,
    required this.maxExtentUnits,
    this.notes,
  });

  /// Stable string id used as a join key elsewhere (custom reticles
  /// added by the user could re-use this with a `custom_<n>` prefix).
  /// Built into the seed file as a snake-case manufacturer + model
  /// slug, e.g. "vortex_ebr7c_mrad".
  final String id;
  final String manufacturer;
  final String model;

  /// Optional grouping label for the picker dropdown, e.g.
  /// "Razor HD Gen III reticles". Several reticles can share a family.
  final String? family;
  final ReticleType type;
  final ReticleNativeUnit nativeUnit;
  final List<ReticleElement> elements;

  /// Half-extent (from center to edge) of the reticle's intended
  /// visible area, in native units. The renderer fits this to 45% of
  /// the widget's shortest side at scale = 1.0.
  final double maxExtentUnits;
  final String? notes;

  /// Decode a `ReticleDefinition` from one entry in `reticles.json`.
  factory ReticleDefinition.fromJson(Map<String, dynamic> json) {
    return ReticleDefinition(
      id: json['id'] as String,
      manufacturer: json['manufacturer'] as String,
      model: json['model'] as String,
      family: json['family'] as String?,
      type: _parseType(json['type'] as String),
      nativeUnit: _parseUnit(json['nativeUnit'] as String),
      maxExtentUnits: (json['maxExtentUnits'] as num).toDouble(),
      elements: (json['elements'] as List<dynamic>)
          .map((e) => ReticleElement.fromJson(e as Map<String, dynamic>))
          .toList(growable: false),
      notes: json['notes'] as String?,
    );
  }

  /// Build a `ReticleDefinition` from a row in the `Reticles` drift
  /// table plus its serialized `definitionJson` element list. The
  /// caller is responsible for giving us the row's stable string id
  /// (the reference catalog uses the seed-file id; user-defined
  /// reticles synthesize one from their primary key).
  factory ReticleDefinition.fromRow({
    required String id,
    required String manufacturer,
    required String model,
    String? family,
    required String type,
    required String nativeUnit,
    required double maxExtentUnits,
    required String definitionJson,
    String? notes,
  }) {
    final elementsJson = json.decode(definitionJson) as List<dynamic>;
    return ReticleDefinition(
      id: id,
      manufacturer: manufacturer,
      model: model,
      family: family,
      type: _parseType(type),
      nativeUnit: _parseUnit(nativeUnit),
      maxExtentUnits: maxExtentUnits,
      elements: elementsJson
          .map((e) => ReticleElement.fromJson(e as Map<String, dynamic>))
          .toList(growable: false),
      notes: notes,
    );
  }

  /// Encode just the `elements` list as JSON — the format the
  /// `Reticles.definitionJson` column stores.
  String elementsAsJson() =>
      json.encode(elements.map((e) => e.toJson()).toList());

  /// Encode the full definition (used when the user-data layer wants
  /// to round-trip a custom reticle).
  Map<String, dynamic> toJson() => {
        'id': id,
        'manufacturer': manufacturer,
        'model': model,
        if (family != null) 'family': family,
        'type': _typeToString(type),
        'nativeUnit': _unitToString(nativeUnit),
        'maxExtentUnits': maxExtentUnits,
        'elements': elements.map((e) => e.toJson()).toList(),
        if (notes != null) 'notes': notes,
      };

  /// Parse the seed-file/database string for `type` into the enum.
  /// Accepts either the canonical short form ("ffp", "sfp", "fixed")
  /// or the full enum name as a fallback.
  static ReticleType _parseType(String s) {
    switch (s) {
      case 'ffp':
      case 'first':
      case 'firstFocalPlane':
        return ReticleType.firstFocalPlane;
      case 'sfp':
      case 'second':
      case 'secondFocalPlane':
        return ReticleType.secondFocalPlane;
      case 'fixed':
        return ReticleType.fixed;
      default:
        throw ArgumentError('Unknown reticle type: $s');
    }
  }

  static String _typeToString(ReticleType t) {
    switch (t) {
      case ReticleType.firstFocalPlane:
        return 'ffp';
      case ReticleType.secondFocalPlane:
        return 'sfp';
      case ReticleType.fixed:
        return 'fixed';
    }
  }

  static ReticleNativeUnit _parseUnit(String s) {
    switch (s) {
      case 'mil':
      case 'mrad':
        return ReticleNativeUnit.mil;
      case 'moa':
        return ReticleNativeUnit.moa;
      case 'ipsc':
        return ReticleNativeUnit.ipsc;
      case 'bdc':
        return ReticleNativeUnit.bdc;
      default:
        throw ArgumentError('Unknown reticle native unit: $s');
    }
  }

  static String _unitToString(ReticleNativeUnit u) {
    switch (u) {
      case ReticleNativeUnit.mil:
        return 'mil';
      case ReticleNativeUnit.moa:
        return 'moa';
      case ReticleNativeUnit.ipsc:
        return 'ipsc';
      case ReticleNativeUnit.bdc:
        return 'bdc';
    }
  }
}

/// Conversion factor: 1 mil = 3.43775 MOA. Used by the renderer to
/// relabel floating numbers when the user requests a different display
/// unit from the reticle's native unit.
const double milToMoa = 3.43775;

/// Convert a value in `from` units to `to` units. Returns the value
/// unchanged when the units match. Treats `ipsc` and `bdc` as native-
/// only — those reticles don't have a meaningful angular conversion.
double convertReticleUnit({
  required double value,
  required ReticleNativeUnit from,
  required ReticleNativeUnit to,
}) {
  if (from == to) return value;
  if (from == ReticleNativeUnit.mil && to == ReticleNativeUnit.moa) {
    return value * milToMoa;
  }
  if (from == ReticleNativeUnit.moa && to == ReticleNativeUnit.mil) {
    return value / milToMoa;
  }
  return value;
}
