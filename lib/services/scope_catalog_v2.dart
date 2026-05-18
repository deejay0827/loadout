// FILE: lib/services/scope_catalog_v2.dart
//
// ============================================================================
// WHAT THIS FILE DOES
// ============================================================================
// In-memory, lazy-loaded read-only service for the Range Day Realistic v2.3
// scope + reticle catalog. Loads three flat-array JSON assets from
// `assets/seed_data/`:
//
//   * `scopes.json`               — 194 scope rows, each with a stable
//                                    string `id` (e.g. `vortex_razor_hd_gen_iii_6_36x56_ffp`).
//   * `reticles.json`             — 52 reticle rows, each with a stable
//                                    string `id` (e.g. `loadout_mil_tree_flare`).
//   * `scope_reticle_options.json`— 194 junction rows mapping
//                                    `{scope_id, reticle_id}`, one per scope.
//
// Exposes three typed models — [ScopeV2Row], [ReticleV2Row], and
// [ScopeReticleOptionV2Row] — plus four lookup methods that the firearm
// form's "Default Scope & Reticle" section and Range Day's pre-population
// path consume:
//
//   * `allScopes()` — every scope, alpha-sorted by manufacturer + model.
//   * `allReticles()` — every reticle, alpha-sorted.
//   * `scopeById(id)` / `reticleById(id)` — single-row lookups.
//   * `defaultReticleIdForScope(id)` — resolve the auto-selected reticle
//     when the user picks a scope on the firearm form.
//
// Soft-fails on missing / malformed assets by returning an empty list —
// the firearm form's pickers render an empty-state message rather than
// crashing.
//
// ============================================================================
// WHY IT EXISTS IN THE ARCHITECTURE
// ============================================================================
// Per the Range Day Realistic v2.3 brief (§6A.4), the firearm form gains
// a "Default Scope & Reticle" section. The scope picker offers any row
// from `scopes.json`; picking a scope auto-selects the reticle from
// `scope_reticle_options.json`. Both columns are persisted on
// `UserFirearms.defaultScopeId` / `UserFirearms.defaultReticleId` as
// string ids (NOT drift integer FKs) so they can survive a re-seed and
// stay stable when the catalog is republished via Firebase Storage
// (CLAUDE.md § 28).
//
// The legacy `lib/services/scope_catalog_service.dart` reads an older
// `optics.json` shape that was merged into `scopes.json` during the
// v2.3 catalog migration. That service still backs the legacy
// "Find by My Scope" picker on the reticle picker widget — kept
// untouched here to limit the scope of this change. This new file is a
// purpose-built v2.3 read-path that doesn't depend on any of the legacy
// merge / normalization gymnastics.
//
// ============================================================================
// WHY THIS IS HARDER THAN IT LOOKS
// ============================================================================
//   * The three JSONs are loaded INDEPENDENTLY and joined in-memory. The
//     join is by string id, not by manufacturer + model — so there is
//     no string normalization (case, whitespace, punctuation) to worry
//     about. The id is the contract.
//   * `scope_reticle_options.json` is a 1:N junction in principle, but
//     today every scope_id appears EXACTLY ONCE (194 scopes / 194 rows).
//     `defaultReticleIdForScope` returns the first match it finds —
//     when the catalog grows a second mapping per scope (e.g. "ships
//     with EBR-7D" vs "ships with TReMoR3") this will need an
//     `isDefault` field on the junction rows, or a different
//     resolution rule. Today, first match = only match.
//   * Asset reads are async but each is small (<100KB). The service
//     caches the parsed result for the process lifetime; first call
//     awaits, subsequent calls return synchronously. Tests can call
//     [debugResetCache] to force a re-read against a mock root bundle.
//   * No DB writes. No network. Stateless beyond the in-memory cache.
//
// ============================================================================
// WHO CONSUMES THIS FILE
// ============================================================================
//   * `lib/screens/firearms/firearm_form_screen.dart` — the "Default
//     Scope & Reticle" section's scope and reticle pickers, plus the
//     auto-select-reticle-on-scope-pick path.
//   * `lib/screens/range_day/range_day_detail_screen.dart` —
//     `_applyFirearmDefaults` reads the firearm's saved
//     `defaultReticleId` string id back to a drift `ReticleRow` so the
//     existing `_selectedReticleRow` / `_selectedReticle` state can
//     pre-populate when the user picks a firearm.
//
// ============================================================================
// SIDE EFFECTS
// ============================================================================
// - Three `rootBundle.loadString(...)` reads on first call (cached for
//   process lifetime).
// - No DB I/O, no network, no globals beyond the singleton instance.

import 'dart:convert';

import 'package:flutter/services.dart' show rootBundle;

/// One row from `scopes.json`. Carries the fields the firearm form's
/// picker displays, the two FOV-interpolation inputs the Visual
/// Fidelity Program's `FovInterpolator` (VFP Phase 11) consumes
/// ([fovAt100ydFtMaxZoom], [sfpCalibrationZoom]), and the iron-sight
/// sighting-picture inputs (VFP Phase 2; consumed by the firearm-form
/// optic picker and `IronSightsPainter`, VFP Phase 21). Iron-sight
/// rows are discriminated by `category == "iron-sights"` (see
/// [isIronSights]); every iron-sight field is nullable and absent on
/// the 194 non-iron rows, so this is purely additive. Remaining JSON
/// columns (single-zoom `fov_at_100yd_ft`, `click_value_moa`,
/// `max_elevation_moa`, `max_windage_moa`, eye relief, etc.) stay in
/// the raw JSON and are read by the renderer / solver directly — note
/// `click_value_moa` / `max_elevation_moa` / `max_windage_moa`
/// already exist in the schema and are REUSED for iron sights, not
/// re-added here (VFP Phase 2 Group A §0.5 finding).
class ScopeV2Row {
  const ScopeV2Row({
    required this.id,
    required this.manufacturer,
    required this.modelName,
    this.category,
    this.focalPlane,
    this.magnificationMin,
    this.magnificationMax,
    this.fovAt100ydFtMaxZoom,
    this.sfpCalibrationZoom,
    this.frontSightType,
    this.frontSightWidthMm,
    this.frontSightDiameterMm,
    this.rearSightType,
    this.rearSightApertureMm,
    this.rearSightDepthMm,
    this.sightRadiusIn,
    this.elevationAdjustment,
    this.windageAdjustment,
  });

  /// Stable string id from `scopes.json`, e.g.
  /// `vortex_razor_hd_gen_iii_6_36x56_ffp`. Used as the FK value
  /// stored on `UserFirearms.defaultScopeId`.
  final String id;
  final String manufacturer;
  final String modelName;
  final String? category;
  final String? focalPlane;
  final num? magnificationMin;
  final num? magnificationMax;

  /// Manufacturer-published field of view, in feet at 100 yards, at the
  /// scope's MAXIMUM magnification. The existing JSON `fov_at_100yd_ft`
  /// is the min-zoom (widest) FOV; this is the narrow end. Null when the
  /// manufacturer does not publish a max-zoom value — FOV interpolation
  /// (VFP Phase 11 `FovInterpolator`) then falls back to single-FOV
  /// behaviour. Populated from cited manufacturer specs in VFP Phase 1.
  final double? fovAt100ydFtMaxZoom;

  /// For second-focal-plane scopes: the magnification at which the
  /// reticle subtensions read true. Null for FFP scopes, and null for
  /// SFP scopes where the manufacturer does not publish a calibration
  /// magnification (they rarely do — the SFP-true-at-max-mag convention
  /// is an operator decision, NOT sourced data, so this stays null
  /// until the operator rules per the VFP Phase 1 Group B report).
  final double? sfpCalibrationZoom;

  // --- Iron-sight sighting-picture fields (VFP Phase 2) ---
  // All nullable; present only on `category == "iron-sights"` rows
  // (added in VFP Phase 2 Group B). Canonical value sets are operator-
  // finalized in Group A and documented in docs/IRON_SIGHTS_SCHEMA.md.

  /// Front sight geometry class. Canonical: `post` | `blade` | `bead`
  /// | `fiber_optic`. Null for non-iron-sight rows.
  final String? frontSightType;

  /// Front blade/post width in millimetres (post / blade types).
  final double? frontSightWidthMm;

  /// Front bead/fiber diameter in millimetres (bead / fiber_optic).
  final double? frontSightDiameterMm;

  /// Rear sight geometry class. Canonical: `notch` | `aperture` |
  /// `ghost_ring` | `buckhorn` | `tang_peep`. Null for non-iron rows.
  final String? rearSightType;

  /// Rear aperture inner diameter in millimetres (aperture /
  /// ghost_ring types).
  final double? rearSightApertureMm;

  /// Rear notch depth in millimetres (notch / buckhorn types).
  final double? rearSightDepthMm;

  /// Sight radius (front-to-rear sight distance) in inches — drives
  /// perceived sight separation in the sighting-picture render.
  final double? sightRadiusIn;

  /// Which sight carries elevation adjustment. Canonical: `fixed` |
  /// `rear` | `front` | `both`.
  final String? elevationAdjustment;

  /// Which sight carries windage adjustment. Canonical: `fixed` |
  /// `rear` | `front` | `both`.
  final String? windageAdjustment;

  /// True when this row is an iron-sight optic. The discriminator is
  /// `category == "iron-sights"` (a free-string category value; no
  /// exhaustive switch keys off scope category, so adding it is
  /// non-breaking — VFP Phase 2 Group A §0.5 verification). Consumed
  /// by the firearm-form optic picker (Group C) and the iron-sights
  /// consumer-contract trace (Group D).
  bool get isIronSights => category == 'iron-sights';

  /// `"<Manufacturer> <Model>"`. The form's autocomplete uses this as
  /// the visible label so the user reads what they'd say out loud.
  String get displayLabel => '$manufacturer $modelName';

  /// Lowercased haystack for the autocomplete's substring matcher.
  String get searchHaystack =>
      '${manufacturer.toLowerCase()} ${modelName.toLowerCase()}';

  /// Compact secondary line for the dropdown — "FFP · 6-36x" / "Red
  /// Dot" / "SFP · 5-25x" depending on which fields are populated.
  /// Empty string when no category / magnification info is available.
  String get secondaryLine {
    final parts = <String>[];
    if (focalPlane != null && focalPlane!.isNotEmpty) {
      parts.add(focalPlane!.toUpperCase());
    } else if (category != null && category!.isNotEmpty) {
      parts.add(_titleCase(category!));
    }
    final lo = magnificationMin;
    final hi = magnificationMax;
    if (lo != null && hi != null) {
      if (lo == hi) {
        parts.add('${_trimNum(lo)}x');
      } else {
        parts.add('${_trimNum(lo)}-${_trimNum(hi)}x');
      }
    }
    return parts.join(' · ');
  }

  static ScopeV2Row? fromJson(Map<String, dynamic> m) {
    final id = (m['id'] as String?)?.trim();
    final mfg = (m['manufacturer'] as String?)?.trim();
    final model = (m['model_name'] as String?)?.trim();
    if (id == null || id.isEmpty) return null;
    if (mfg == null || mfg.isEmpty) return null;
    if (model == null || model.isEmpty) return null;
    return ScopeV2Row(
      id: id,
      manufacturer: mfg,
      modelName: model,
      category: (m['category'] as String?)?.trim(),
      focalPlane: (m['focal_plane'] as String?)?.trim(),
      magnificationMin: m['magnification_min'] is num
          ? m['magnification_min'] as num
          : null,
      magnificationMax: m['magnification_max'] is num
          ? m['magnification_max'] as num
          : null,
      fovAt100ydFtMaxZoom:
          (m['fov_at_100yd_ft_max_zoom'] as num?)?.toDouble(),
      sfpCalibrationZoom: (m['sfp_calibration_zoom'] as num?)?.toDouble(),
      frontSightType: (m['front_sight_type'] as String?)?.trim(),
      frontSightWidthMm: (m['front_sight_width_mm'] as num?)?.toDouble(),
      frontSightDiameterMm:
          (m['front_sight_diameter_mm'] as num?)?.toDouble(),
      rearSightType: (m['rear_sight_type'] as String?)?.trim(),
      rearSightApertureMm:
          (m['rear_sight_aperture_mm'] as num?)?.toDouble(),
      rearSightDepthMm: (m['rear_sight_depth_mm'] as num?)?.toDouble(),
      sightRadiusIn: (m['sight_radius_in'] as num?)?.toDouble(),
      elevationAdjustment: (m['elevation_adjustment'] as String?)?.trim(),
      windageAdjustment: (m['windage_adjustment'] as String?)?.trim(),
    );
  }
}

/// One row from `reticles.json`. Same minimal projection — only the
/// fields the firearm form's reticle dropdown needs to display.
class ReticleV2Row {
  const ReticleV2Row({
    required this.id,
    required this.manufacturer,
    required this.model,
    this.family,
    this.type,
    this.nativeUnit,
  });

  /// Stable string id from `reticles.json`, e.g.
  /// `loadout_mil_tree_flare`. Stored on
  /// `UserFirearms.defaultReticleId`.
  final String id;
  final String manufacturer;
  final String model;
  final String? family;
  final String? type;
  final String? nativeUnit;

  /// `"<Manufacturer> <Model>"`, matching the firearm form's scope
  /// label shape so the section reads consistently. For LoadOut-
  /// originals the manufacturer is always `"LoadOut"` per CLAUDE.md
  /// § 30.
  String get displayLabel => '$manufacturer $model';

  String get searchHaystack =>
      '${manufacturer.toLowerCase()} ${model.toLowerCase()} '
      '${(family ?? '').toLowerCase()}';

  /// "MIL · FFP" / "MOA · SFP". Empty when fields are missing.
  String get secondaryLine {
    final parts = <String>[];
    if (nativeUnit != null && nativeUnit!.isNotEmpty) {
      parts.add(nativeUnit!.toUpperCase());
    }
    if (type != null && type!.isNotEmpty) {
      parts.add(type!.toUpperCase());
    }
    if (family != null && family!.isNotEmpty) {
      parts.add(family!);
    }
    return parts.join(' · ');
  }

  static ReticleV2Row? fromJson(Map<String, dynamic> m) {
    final id = (m['id'] as String?)?.trim();
    final mfg = (m['manufacturer'] as String?)?.trim();
    final model = (m['model'] as String?)?.trim();
    if (id == null || id.isEmpty) return null;
    if (mfg == null || mfg.isEmpty) return null;
    if (model == null || model.isEmpty) return null;
    return ReticleV2Row(
      id: id,
      manufacturer: mfg,
      model: model,
      family: (m['family'] as String?)?.trim(),
      type: (m['type'] as String?)?.trim(),
      nativeUnit: (m['nativeUnit'] as String?)?.trim(),
    );
  }
}

/// One row from `scope_reticle_options.json`. Maps a `scope_id` to its
/// recommended `reticle_id`. Today this is 1:1 — every scope in
/// `scopes.json` has exactly one mapping row — but the model holds
/// the `notes` field too for future surface use.
class ScopeReticleOptionV2Row {
  const ScopeReticleOptionV2Row({
    required this.scopeId,
    required this.reticleId,
    this.notes,
  });

  final String scopeId;
  final String reticleId;
  final String? notes;

  static ScopeReticleOptionV2Row? fromJson(Map<String, dynamic> m) {
    final scopeId = (m['scope_id'] as String?)?.trim();
    final reticleId = (m['reticle_id'] as String?)?.trim();
    if (scopeId == null || scopeId.isEmpty) return null;
    if (reticleId == null || reticleId.isEmpty) return null;
    return ScopeReticleOptionV2Row(
      scopeId: scopeId,
      reticleId: reticleId,
      notes: (m['notes'] as String?)?.trim(),
    );
  }
}

/// Singleton service. Loads the three JSON assets once per process and
/// caches the parsed lists. Tests can reset the cache via
/// [debugResetCache].
class ScopeCatalogV2Service {
  ScopeCatalogV2Service._();
  static final ScopeCatalogV2Service instance = ScopeCatalogV2Service._();

  List<ScopeV2Row>? _scopes;
  List<ReticleV2Row>? _reticles;
  Map<String, String>? _reticleIdByScopeId;

  Future<void> _ensureLoaded() async {
    if (_scopes != null && _reticles != null && _reticleIdByScopeId != null) {
      return;
    }
    // Each asset is loaded independently — a malformed file for one
    // kind shouldn't take down the others. Empty list on failure is
    // the soft-fail contract.
    _scopes = await _loadScopes();
    _reticles = await _loadReticles();
    _reticleIdByScopeId = await _loadJunction();
  }

  Future<List<ScopeV2Row>> _loadScopes() async {
    try {
      final raw = await rootBundle.loadString('assets/seed_data/scopes.json');
      final decoded = json.decode(raw) as List<dynamic>;
      final out = <ScopeV2Row>[];
      for (final entry in decoded) {
        if (entry is! Map<String, dynamic>) continue;
        final row = ScopeV2Row.fromJson(entry);
        if (row != null) out.add(row);
      }
      out.sort((a, b) {
        final mfgCmp = a.manufacturer
            .toLowerCase()
            .compareTo(b.manufacturer.toLowerCase());
        if (mfgCmp != 0) return mfgCmp;
        return a.modelName.toLowerCase().compareTo(b.modelName.toLowerCase());
      });
      return out;
    } catch (_) {
      return const <ScopeV2Row>[];
    }
  }

  Future<List<ReticleV2Row>> _loadReticles() async {
    try {
      final raw = await rootBundle.loadString('assets/seed_data/reticles.json');
      final decoded = json.decode(raw) as List<dynamic>;
      final out = <ReticleV2Row>[];
      for (final entry in decoded) {
        if (entry is! Map<String, dynamic>) continue;
        final row = ReticleV2Row.fromJson(entry);
        if (row != null) out.add(row);
      }
      out.sort((a, b) {
        final mfgCmp = a.manufacturer
            .toLowerCase()
            .compareTo(b.manufacturer.toLowerCase());
        if (mfgCmp != 0) return mfgCmp;
        return a.model.toLowerCase().compareTo(b.model.toLowerCase());
      });
      return out;
    } catch (_) {
      return const <ReticleV2Row>[];
    }
  }

  Future<Map<String, String>> _loadJunction() async {
    try {
      final raw = await rootBundle
          .loadString('assets/seed_data/scope_reticle_options.json');
      final decoded = json.decode(raw) as List<dynamic>;
      // First-wins resolution. Today every scope_id appears exactly
      // once; if a future catalog adds multiple mappings per scope,
      // the first one wins and the rest are silently dropped. See
      // the file header for the upgrade path.
      final out = <String, String>{};
      for (final entry in decoded) {
        if (entry is! Map<String, dynamic>) continue;
        final row = ScopeReticleOptionV2Row.fromJson(entry);
        if (row == null) continue;
        out.putIfAbsent(row.scopeId, () => row.reticleId);
      }
      return out;
    } catch (_) {
      return const <String, String>{};
    }
  }

  /// Every scope in the catalog, sorted by manufacturer + model.
  Future<List<ScopeV2Row>> allScopes() async {
    await _ensureLoaded();
    return _scopes!;
  }

  /// Every reticle in the catalog, sorted by manufacturer + model.
  Future<List<ReticleV2Row>> allReticles() async {
    await _ensureLoaded();
    return _reticles!;
  }

  /// Single-scope lookup by string id. Returns null when the id
  /// doesn't appear in `scopes.json` (catalog drift — the previously-
  /// saved id no longer exists).
  Future<ScopeV2Row?> scopeById(String? id) async {
    if (id == null || id.isEmpty) return null;
    await _ensureLoaded();
    for (final s in _scopes!) {
      if (s.id == id) return s;
    }
    return null;
  }

  /// Single-reticle lookup by string id. Returns null when the id
  /// doesn't appear in `reticles.json`.
  Future<ReticleV2Row?> reticleById(String? id) async {
    if (id == null || id.isEmpty) return null;
    await _ensureLoaded();
    for (final r in _reticles!) {
      if (r.id == id) return r;
    }
    return null;
  }

  /// Recommended reticle id for the given scope id, per
  /// `scope_reticle_options.json`. Returns null when the scope id
  /// has no mapping (catalog gap) — the firearm form falls back to
  /// "no reticle pre-selected, user picks freely" in that case.
  Future<String?> defaultReticleIdForScope(String? scopeId) async {
    if (scopeId == null || scopeId.isEmpty) return null;
    await _ensureLoaded();
    return _reticleIdByScopeId![scopeId];
  }

  /// Test-only hook for forcing a re-read of the assets. Production
  /// code should never call this.
  void debugResetCache() {
    _scopes = null;
    _reticles = null;
    _reticleIdByScopeId = null;
  }
}

String _titleCase(String s) {
  if (s.isEmpty) return s;
  return s
      .split(RegExp(r'\s+'))
      .map((w) => w.isEmpty
          ? w
          : '${w[0].toUpperCase()}${w.substring(1).toLowerCase()}')
      .join(' ');
}

String _trimNum(num v) {
  // 6 -> "6", 6.5 -> "6.5", 1.0 -> "1". Mirrors the magnification
  // formatting the marketing copy uses.
  if (v == v.truncate()) return v.truncate().toString();
  return v.toString();
}
