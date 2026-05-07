// FILE: lib/data/reticle_seed_defaults.dart
//
// ============================================================================
// WHAT THIS FILE DOES
// ============================================================================
// Hard-coded fallback library of reticle definitions to seed into the
// `Reticles` SQLite table when no `reticles.json` is present in
// `assets/seed_data/`. Without it the dropdown in the Range Day picker
// would be empty on a fresh install — instead we ship the four most
// recognisable patterns so the picker has something useful from minute
// one.
//
// `seedDefaultReticlesIfEmpty(db)` is idempotent: it only writes when
// `db.reticlesAreEmpty` is true. Callers can fire-and-forget on app
// start (or lazily on first picker open).
//
// The actual definition data lives in `_defaultDefinitions` below. Each
// entry is a [ReticleDefinition] built directly in code — no JSON
// round-trip — because the structures are tiny.

import 'package:drift/drift.dart';

import '../database/database.dart';
import 'reticle_library.dart';

/// Idempotently seed the four default reticle definitions into the
/// `Reticles` table. Returns immediately if any rows already exist.
Future<void> seedDefaultReticlesIfEmpty(AppDatabase db) async {
  if (!await db.reticlesAreEmpty) return;
  await db.batch((b) {
    for (final def in _defaultDefinitions) {
      b.insert(
        db.reticles,
        ReticlesCompanion.insert(
          manufacturerId: def.manufacturer,
          model: def.model,
          family: Value(def.family),
          type: _typeText(def.type),
          nativeUnit: _unitText(def.nativeUnit),
          maxExtentUnits: def.maxExtentUnits,
          definitionJson: def.elementsAsJson(),
          notes: Value(def.notes),
        ),
      );
    }
  });
}

String _typeText(ReticleType t) {
  switch (t) {
    case ReticleType.firstFocalPlane:
      return 'ffp';
    case ReticleType.secondFocalPlane:
      return 'sfp';
    case ReticleType.fixed:
      return 'fixed';
  }
}

String _unitText(ReticleNativeUnit u) {
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

/// Build a centred horizontal + vertical crosshair list with hash marks
/// every `step` native units out to ±extent.
List<ReticleElement> _hashGrid({
  required double extent,
  required double step,
  double tickLen = 0.4,
  double thickness = 0.04,
  bool labelMajor = true,
}) {
  final out = <ReticleElement>[];
  // Crosshairs.
  out.add(CrosshairLine(
    startX: -extent,
    startY: 0,
    endX: extent,
    endY: 0,
    thicknessMil: thickness,
  ));
  out.add(CrosshairLine(
    startX: 0,
    startY: -extent,
    endX: 0,
    endY: extent,
    thicknessMil: thickness,
  ));
  // Center dot.
  out.add(const CenterDot(radiusUnits: 0.06));

  for (var i = 1; i * step <= extent + 0.001; i++) {
    final v = (i * step).toDouble();
    final isMajor = i % 2 == 0;
    out.add(HashMark(
      x: v,
      y: 0,
      lengthUnits: tickLen * (isMajor ? 1.4 : 1.0),
      thicknessUnits: thickness,
      axis: HashAxis.horizontal,
    ));
    out.add(HashMark(
      x: -v,
      y: 0,
      lengthUnits: tickLen * (isMajor ? 1.4 : 1.0),
      thicknessUnits: thickness,
      axis: HashAxis.horizontal,
    ));
    out.add(HashMark(
      x: 0,
      y: v,
      lengthUnits: tickLen * (isMajor ? 1.4 : 1.0),
      thicknessUnits: thickness,
      axis: HashAxis.vertical,
    ));
    out.add(HashMark(
      x: 0,
      y: -v,
      lengthUnits: tickLen * (isMajor ? 1.4 : 1.0),
      thicknessUnits: thickness,
      axis: HashAxis.vertical,
    ));
    if (labelMajor && isMajor) {
      out.add(FloatingNumber(
        x: v + tickLen,
        y: -tickLen,
        text: i.toString(),
        fontSizeUnits: 0.55,
      ));
      out.add(FloatingNumber(
        x: -tickLen,
        y: -v - tickLen,
        text: i.toString(),
        fontSizeUnits: 0.55,
      ));
    }
  }
  return out;
}

final List<ReticleDefinition> _defaultDefinitions = [
  ReticleDefinition(
    id: 'mil_hash_5',
    manufacturer: 'Generic',
    model: 'Mil hash · ±5 mil',
    family: 'Generic mil reticles',
    type: ReticleType.firstFocalPlane,
    nativeUnit: ReticleNativeUnit.mil,
    maxExtentUnits: 5,
    elements: _hashGrid(extent: 5, step: 0.5),
    notes: 'Generic hash-mark mil reticle, ±5 mil tree.',
  ),
  ReticleDefinition(
    id: 'mil_hash_10',
    manufacturer: 'Generic',
    model: 'Mil hash · ±10 mil',
    family: 'Generic mil reticles',
    type: ReticleType.firstFocalPlane,
    nativeUnit: ReticleNativeUnit.mil,
    maxExtentUnits: 10,
    elements: _hashGrid(extent: 10, step: 1.0),
    notes: 'Generic ±10 mil hash reticle (similar to EBR-style).',
  ),
  ReticleDefinition(
    id: 'mil_dot_classic',
    manufacturer: 'Generic',
    model: 'Mil-Dot · ±5 mil',
    family: 'Mil-Dot reticles',
    type: ReticleType.secondFocalPlane,
    nativeUnit: ReticleNativeUnit.mil,
    maxExtentUnits: 5,
    elements: const [
      CrosshairLine(
          startX: -5, startY: 0, endX: 5, endY: 0, thicknessMil: 0.05),
      CrosshairLine(
          startX: 0, startY: -5, endX: 0, endY: 5, thicknessMil: 0.05),
      CenterDot(radiusUnits: 0.06),
      CenterDot(x: 1, y: 0, radiusUnits: 0.1),
      CenterDot(x: -1, y: 0, radiusUnits: 0.1),
      CenterDot(x: 2, y: 0, radiusUnits: 0.1),
      CenterDot(x: -2, y: 0, radiusUnits: 0.1),
      CenterDot(x: 3, y: 0, radiusUnits: 0.1),
      CenterDot(x: -3, y: 0, radiusUnits: 0.1),
      CenterDot(x: 4, y: 0, radiusUnits: 0.1),
      CenterDot(x: -4, y: 0, radiusUnits: 0.1),
      CenterDot(x: 0, y: 1, radiusUnits: 0.1),
      CenterDot(x: 0, y: -1, radiusUnits: 0.1),
      CenterDot(x: 0, y: 2, radiusUnits: 0.1),
      CenterDot(x: 0, y: -2, radiusUnits: 0.1),
      CenterDot(x: 0, y: 3, radiusUnits: 0.1),
      CenterDot(x: 0, y: -3, radiusUnits: 0.1),
      CenterDot(x: 0, y: 4, radiusUnits: 0.1),
      CenterDot(x: 0, y: -4, radiusUnits: 0.1),
    ],
    notes: 'Classic USMC mil-dot pattern (5 mil per side).',
  ),
  ReticleDefinition(
    id: 'moa_hash_30',
    manufacturer: 'Generic',
    model: 'MOA hash · ±30 MOA',
    family: 'Generic MOA reticles',
    type: ReticleType.firstFocalPlane,
    nativeUnit: ReticleNativeUnit.moa,
    maxExtentUnits: 30,
    elements: _hashGrid(extent: 30, step: 2.0, tickLen: 1.0, thickness: 0.12),
    notes: 'Generic MOA hash reticle (±30 MOA tree).',
  ),
  ReticleDefinition(
    id: 'duplex_classic',
    manufacturer: 'Generic',
    model: 'Duplex',
    family: 'Hunting reticles',
    type: ReticleType.secondFocalPlane,
    nativeUnit: ReticleNativeUnit.moa,
    maxExtentUnits: 24,
    elements: const [
      CrosshairLine(
          startX: -6, startY: 0, endX: 6, endY: 0, thicknessMil: 0.08),
      CrosshairLine(
          startX: 0, startY: -6, endX: 0, endY: 6, thicknessMil: 0.08),
      CrosshairLine(
          startX: -24,
          startY: 0,
          endX: -6,
          endY: 0,
          thicknessMil: 0.6),
      CrosshairLine(
          startX: 6, startY: 0, endX: 24, endY: 0, thicknessMil: 0.6),
      CrosshairLine(
          startX: 0,
          startY: -24,
          endX: 0,
          endY: -6,
          thicknessMil: 0.6),
      CrosshairLine(
          startX: 0, startY: 6, endX: 0, endY: 24, thicknessMil: 0.6),
      CenterDot(radiusUnits: 0.05),
    ],
    notes: 'Classic hunting duplex post reticle.',
  ),
];
