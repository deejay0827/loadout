// FILE: lib/services/component_favorites_service.dart
//
// ============================================================================
// WHAT THIS FILE DOES
// ============================================================================
// Persists per-kind favorite component NAMES (powder, bullet, primer,
// brass) to SharedPreferences and exposes them as a reactive
// [ChangeNotifier]. Drives the "Favorites first" prefix of the
// `Favorites → Frequently used → general` ordering rule that
// `ComponentField` applies to dropdown options.
//
// Public API:
//   * `bool isFavorite(String kind, String name)` — has the user
//     favorited this exact label for this kind?
//   * `Set<String> favorites(String kind)` — read-only snapshot of
//     the favorited labels for one kind (empty set when none).
//   * `Future<void> toggleFavorite(String kind, String name)` —
//     flip the favorite state. Idempotent on whitespace-trimmed
//     empty strings (no-op).
//   * `bool get isHydrated` — true once the SharedPreferences load
//     completed; widgets that build before hydration see empty sets
//     and rebuild once `notifyListeners()` fires.
//
// Cartridges DO NOT use this service. Cartridge favorites continue
// to live in [FavoritesRepository] (the `UserFavorites` join table)
// because cartridge picker rows are int-keyed and the SAAMI screen
// already provides a toggle UI on top of that schema. Powder /
// bullet / primer / brass favorites are name-keyed (which lets a
// favorite survive across catalog vs custom-component paths) and
// don't have a parallel "manage favorites" surface — the dropdown's
// trailing star is the only toggle.
//
// ============================================================================
// WHY IT EXISTS IN THE ARCHITECTURE
// ============================================================================
// The recipe form's component pickers (powder, bullet, primer,
// brass) need to surface the user's "I always shoot this" list at
// the top of the dropdown. The existing favorites mechanism is
// row-id-keyed and cartridge-only; extending it to name-keyed
// reference data would require a migration, a column-type change
// from `int` to `text`, AND a parallel cleanup path for orphaned
// names (the catalog gets re-seeded; a row id favorite becomes
// dangling, but a name favorite stays live until the user toggles
// it). SharedPreferences sidesteps all of that — favorites are
// owned by the user's name, not the catalog's row id.
//
// The trade-off: Cloud Sync today doesn't include SharedPreferences
// in its encrypted payload. A user who enables Cloud Sync sees
// their favorites stay on the device they originally starred them
// from. That's an acceptable scope cut for v1 — the favorites here
// are an at-the-fingertips convenience, not a primary data type.
// If we later want them to sync, we'd either teach Cloud Sync to
// pull from SharedPreferences OR migrate this list to a
// `UserComponentFavorites` drift table. Document the choice loudly
// when we make it.
//
// ============================================================================
// WHY THIS IS HARDER THAN IT LOOKS
// ============================================================================
//   * **Hydration before reads.** Like every other prefs-backed
//     service, the in-memory state is empty until `_hydrate()`
//     completes. Widgets that build during the gap see empty
//     `favorites(kind)` and rebuild on `notifyListeners()`. Don't
//     gate UI on `isHydrated` — the empty-set fallback is what we
//     actually want during the first frame.
//   * **Trim before mutation.** "Varget " and "Varget" are the
//     same powder. We trim incoming names so a stray space doesn't
//     create a phantom favorite that never matches a dropdown row.
//   * **No cross-kind leakage.** Each kind's favorites live under
//     its own SharedPreferences key (`component_favorites_<kind>`)
//     so editing one set never accidentally rewrites another. The
//     kinds are validated against [_kSupportedKinds]; an unknown
//     kind becomes a no-op rather than raising — this lets future
//     callers (e.g. a hypothetical "lot" favorites picker) target
//     this service without crashing if the operator ships them
//     before the supported-kinds list is updated.
//
// ============================================================================
// WHO CONSUMES THIS FILE
// ============================================================================
// - lib/widgets/component_field.dart — reads favorites for
//   dropdown ordering, exposes a tap-on-star toggle in the rows.
// - lib/app.dart — provides the singleton.
//
// ============================================================================
// SIDE EFFECTS
// ============================================================================
// Reads / writes SharedPreferences under
// `component_favorites_powder`, `component_favorites_bullet`,
// `component_favorites_primer`, `component_favorites_brass`.

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Component kinds that this service knows about. Passing any other
/// kind to the public API silently no-ops (returns empty / does
/// nothing) so that unknown kinds can't corrupt the prefs store.
const List<String> _kSupportedKinds = ['powder', 'bullet', 'primer', 'brass'];

const String _kKeyPrefix = 'component_favorites_';

/// Per-kind favorite component names, persisted to
/// SharedPreferences. See file-header for the full contract.
class ComponentFavoritesService extends ChangeNotifier {
  ComponentFavoritesService() {
    // ignore: discarded_futures
    _hydrate();
  }

  final Map<String, Set<String>> _byKind = {};
  bool _hydrated = false;

  bool get isHydrated => _hydrated;

  Future<void> _hydrate() async {
    final prefs = await SharedPreferences.getInstance();
    for (final kind in _kSupportedKinds) {
      final raw = prefs.getStringList('$_kKeyPrefix$kind') ?? const <String>[];
      _byKind[kind] = raw.toSet();
    }
    _hydrated = true;
    notifyListeners();
  }

  /// True when `name` is currently favorited under `kind`. Returns
  /// false for unknown kinds.
  bool isFavorite(String kind, String name) {
    final set = _byKind[kind];
    if (set == null) return false;
    return set.contains(name);
  }

  /// Read-only snapshot of the favorited names for `kind`. Returns
  /// an empty set for unknown kinds OR while still hydrating.
  Set<String> favorites(String kind) {
    final set = _byKind[kind];
    if (set == null) return const <String>{};
    return Set<String>.unmodifiable(set);
  }

  /// Flip the favorite state for `(kind, name)`. Idempotent on
  /// empty / whitespace-only names (returns immediately). Notifies
  /// listeners synchronously, then writes to SharedPreferences in
  /// the background.
  Future<void> toggleFavorite(String kind, String name) async {
    if (!_kSupportedKinds.contains(kind)) return;
    final trimmed = name.trim();
    if (trimmed.isEmpty) return;
    final set = _byKind.putIfAbsent(kind, () => <String>{});
    if (set.contains(trimmed)) {
      set.remove(trimmed);
    } else {
      set.add(trimmed);
    }
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList('$_kKeyPrefix$kind', set.toList());
  }
}
