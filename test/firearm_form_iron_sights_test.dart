// FILE: test/firearm_form_iron_sights_test.dart
//
// ============================================================================
// WHAT THIS FILE DOES
// ============================================================================
// Guards the VFP Phase 2 Group C decision contract for the firearm
// form's "Default Scope & Reticle" section: when the selected optic
// is an iron sight, the form hides the reticle picker (shows the
// read-only sight-type summary instead) AND clears any carried-over
// `_defaultReticleId`; for scopes / red dots the reticle picker
// behaves exactly as before. The single decision input is
// `ScopeV2Row.isIronSights` (== `category == "iron-sights"`), used
// inline at both firearm-form call sites (`_onDefaultScopePicked`
// reticle-clear gate and `_defaultScopeReticleSection` render gate).
//
// Rather than pump the 3,450-line FirearmFormScreen (heavy provider /
// drift / AutoSave harness, brittle), this tests the contract's
// inputs directly: (1) the row-level predicate over constructed
// ScopeV2Row instances, and (2) the live-catalog data the form
// relies on — every `iron-sights` row resolves to NO reticle mapping
// (which is *why* the form shows none / clears it), while every
// non-iron scope still has one.
//
// ============================================================================
// WHY IT EXISTS IN THE ARCHITECTURE
// ============================================================================
// VFP Phase 2 Group B added 19 iron-sight rows to scopes.json with no
// scope_reticle_options mapping (iron sights have no reticle). Group C
// makes the firearm form coherent for that category. Without this
// guard, a regression that (a) stopped treating `iron-sights` as the
// discriminator, or (b) re-introduced a stale reticle on an iron
// optic, would ship silently. The broader Range Day / ScopeViewInputs
// null-guard is VFP Phase 2 Group D's scope (this only guards the
// firearm-form decision + its catalog inputs).
//
// ============================================================================
// WHY THIS IS HARDER THAN IT LOOKS
// ============================================================================
// - The "show reticle picker?" decision is `!(scope?.isIronSights ??
//   false)` — a NULL scope must still show the picker (preserves the
//   pre-Phase-2 behavior of an unset optic), so the predicate is not
//   simply `scope.isIronSights`.
// - The reticle-clear path only matters when a reticle was already
//   set; the catalog-level guarantee (iron rows have no mapping) is
//   the structural reason the form never auto-fills one.
//
// ============================================================================
// WHO CONSUMES THIS FILE
// ============================================================================
//   * `flutter test test/firearm_form_iron_sights_test.dart` — direct.
//   * `flutter test` — full-suite glob.
//
// ============================================================================
// SIDE EFFECTS
// ============================================================================
// - Reads scopes.json / reticles.json / scope_reticle_options.json
//   via rootBundle (ScopeCatalogV2Service).
// - Resets the ScopeCatalogV2Service cache between tests.

import 'package:flutter_test/flutter_test.dart';

import 'package:loadout/services/scope_catalog_v2.dart';

/// Mirrors the inline decision used at both firearm-form call sites:
/// the reticle picker shows for scopes / red dots / an unset optic,
/// and is hidden for iron-sight optics. Kept here as the documented
/// contract under test (the form uses the equivalent inline
/// expression `_defaultScopeRow?.isIronSights ?? false`).
bool reticlePickerShownFor(ScopeV2Row? optic) =>
    !(optic?.isIronSights ?? false);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => ScopeCatalogV2Service.instance.debugResetCache());

  ScopeV2Row row({required String id, String? category}) => ScopeV2Row(
        id: id,
        manufacturer: 'X',
        modelName: 'Y',
        category: category,
      );

  group('Group C decision predicate', () {
    test('iron-sight optic hides the reticle picker', () {
      final iron = row(id: 'ar15_a2_rifle_irons', category: 'iron-sights');
      expect(iron.isIronSights, isTrue);
      expect(reticlePickerShownFor(iron), isFalse);
    });

    test('scope / red-dot / unknown-category optic shows the picker', () {
      for (final c in const ['rifle-scope', 'red-dot', 'lpvo', 'prism']) {
        final s = row(id: 'x', category: c);
        expect(s.isIronSights, isFalse, reason: c);
        expect(reticlePickerShownFor(s), isTrue, reason: c);
      }
    });

    test('null optic still shows the picker (pre-Phase-2 behavior)', () {
      // A firearm with no optic picked must keep the reticle picker —
      // the predicate is NOT plain `scope.isIronSights`.
      expect(reticlePickerShownFor(null), isTrue);
      expect(row(id: 'x', category: null).isIronSights, isFalse);
    });
  });

  group('live-catalog contract the firearm form relies on', () {
    test('every iron-sight row resolves to NO reticle mapping', () async {
      // This is *why* the form shows no reticle / clears it for iron
      // optics: defaultReticleIdForScope is null for them by design.
      final svc = ScopeCatalogV2Service.instance;
      final scopes = await svc.allScopes();
      final irons = scopes.where((s) => s.isIronSights).toList();
      expect(irons, isNotEmpty,
          reason: 'Group B authored iron-sight rows must be present');
      for (final s in irons) {
        final rid = await svc.defaultReticleIdForScope(s.id);
        expect(rid, isNull,
            reason:
                '${s.id} is an iron sight — it must carry no '
                'scope_reticle_options mapping (Group C/D contract)');
        expect(reticlePickerShownFor(s), isFalse, reason: s.id);
      }
    });

    test('every non-iron scope still resolves to a reticle (unchanged)',
        () async {
      final svc = ScopeCatalogV2Service.instance;
      final scopes = await svc.allScopes();
      final misses = <String>[];
      for (final s in scopes.where((s) => !s.isIronSights)) {
        if (await svc.defaultReticleIdForScope(s.id) == null) {
          misses.add(s.id);
        }
      }
      expect(misses, isEmpty,
          reason: 'Group C must not regress the magnified-optic '
              'reticle-mapping invariant. Missing: $misses');
    });
  });
}
