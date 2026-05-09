// FILE: lib/widgets/component_field.dart
//
// ============================================================================
// WHAT THIS FILE DOES
// ============================================================================
// Defines `ComponentField`, the autocomplete-style picker that the recipe
// form (`load_form_screen.dart`) and the firearm form use whenever the
// user has to choose a component from the catalog: cartridge, powder,
// bullet, primer (legacy single-field path), or brass. Built on top of
// Flutter's stock `Autocomplete<String>` widget — that's the widget the
// SDK exposes for "type-to-search dropdown over a fixed list of options."
//
// Public API (the constructor parameters):
//   - `kind`                — one of `'powder' | 'bullet' | 'primer' | 'brass'
//                              | 'cartridge'`. Selects which catalog the
//                              repository should hand back.
//   - `label`               — the floating label that sits above the field
//                              (e.g. "Cartridge / Caliber").
//   - `controller`          — the parent form's `TextEditingController`. The
//                              widget mirrors changes both directions so the
//                              parent always has the user's current text.
//   - `helper`              — optional helper text below the field.
//   - `validator`           — optional `FormField` validator. Forwarded
//                              straight through to the inner `TextFormField`.
//   - `onSelected(label)`   — fires ONCE, when the user taps a row in the
//                              dropdown. NOT a per-keystroke listener — for
//                              that, watch `controller` directly. This is
//                              what `load_form_screen.dart` hooks into to
//                              auto-fill bullet diameter / primer size when
//                              a known catalog item is picked.
//
// Matching algorithm (see `optionsBuilder`):
// The user's query is lowercased, trimmed, and split on whitespace. Every
// resulting token must appear (case-insensitively) somewhere in the option
// label for that option to survive the filter. So `"6 GT"` matches
// `"6mm GT"` and `"22 GT"` does NOT match `".30-06 Springfield"`. This is
// deliberately looser than prefix-only matching — reloaders type cartridges
// in many forms (`"6mm"`, `"6 mm"`, `".308"`, `"308 Win"`) and want them
// all to find the right row.
//
// Favorite-cartridge sorting (schema v24): when `kind == 'cartridge'`,
// the widget subscribes to
// `FavoritesRepository.watchFavoriteIds(kFavoriteCartridge)` and
// re-orders the dropdown options so favorited cartridges appear first
// (alphabetical within each bucket — the upstream
// `componentLabels('cartridge')` is already natural-sorted, so
// stable-partitioning preserves that ordering inside each bucket).
// Each favorited row in the dropdown carries a small filled-star icon
// in the trailing slot as a visual indicator only — taps still pick
// the row, since toggling favorites lives on the SAAMI screen to
// keep this dropdown un-cluttered. Other component kinds (powder,
// bullet, primer, brass) skip the favorites subscription entirely.
//
// State tracked inside `_ComponentFieldState`:
//   - `_futureOptions`     — the list of catalog labels for the configured
//                             `kind`, fetched once during `initState` from
//                             the `ComponentRepository`. Held as a Future so
//                             we can render a `FutureBuilder` and rebuild
//                             once the SQLite query completes.
//   - `_innerController`   — the `TextEditingController` Flutter's
//                             `Autocomplete` creates internally and hands to
//                             us in `fieldViewBuilder`. We capture it the
//                             first time so we can wire ONE listener.
//   - `_innerListener`     — the `VoidCallback` that mirrors edits from the
//                             autocomplete-owned controller back to the
//                             parent's controller.
//
// Key methods:
//   - `initState()`        — kicks off the SQLite query for `componentLabels`.
//   - `dispose()`          — removes the listener so the autocomplete
//                             controller doesn't keep us alive.
//   - `_ensureWiring(ctrl)` — the critical helper. See WHY THIS IS HARDER
//                             below. Wires the listener exactly once and
//                             tears down the prior wiring if the autocomplete
//                             ever swaps controllers.
//   - `build()`            — wraps the `Autocomplete<String>` in a
//                             `FutureBuilder` so the option list resolves
//                             asynchronously without blocking first paint.
//
// ============================================================================
// WHY IT EXISTS IN THE ARCHITECTURE
// ============================================================================
// LoadOut's recipe form has six identical-shaped picker rows (cartridge,
// bullet, powder, primer, brass, plus optional ones). Without a shared
// widget, every screen would re-implement the "fetch labels, filter as
// the user types, mirror to a parent controller" dance. That's a lot of
// drift opportunity — one variant treats `null` differently, one calls
// `componentLabels` on every keystroke, one forgets to expose `onSelected`,
// and the screens drift apart.
//
// `ComponentField` collapses all of that to a 5-line invocation, while
// preserving the hook the parent needs (the `onSelected` callback) for the
// "auto-fill bullet diameter when you pick from the catalog" affordance.
// It is also the home of the autocorrect/suggestions OFF flags described
// below; making sure those stay consistent across every component picker
// is part of the "don't drift" payoff.
//
// ============================================================================
// WHY THIS IS HARDER THAN IT LOOKS
// ============================================================================
// 1. THE LISTENER LEAK. Flutter's `Autocomplete<String>` calls
//    `fieldViewBuilder` on every rebuild — and rebuilds happen on every
//    keystroke, every focus change, every parent setState. If you write
//    `textCtrl.addListener(...)` directly inside `fieldViewBuilder`,
//    you accumulate one listener per rebuild. Within a few seconds of
//    typing, every keystroke is firing a hundred listeners. Symptom:
//    typing in the field gets visibly laggy, and the controller mirrors
//    fire repeatedly with the same value. The fix is `_ensureWiring`:
//    capture the autocomplete-owned controller the first time we see it,
//    wire ONE listener, and noop on subsequent builds (`identical` check).
//    `_innerController` is null until the very first `fieldViewBuilder`
//    call — that's why we capture it lazily there rather than in
//    `initState`.
// 2. TWO CONTROLLERS, ONE FIELD. The parent owns its `TextEditingController`
//    (so it can read the value on submit). `Autocomplete<String>` insists
//    on owning ITS OWN controller (it uses it internally to drive the
//    options list). Both have to stay in sync, which is what the listener
//    does in both directions: parent → autocomplete on the initial sync,
//    autocomplete → parent on every keystroke.
// 3. `onSelected` IS NOT `onChanged`. `onSelected` fires when the user
//    picks a row from the dropdown, NOT when they keystroke their way to
//    a string that happens to match a catalog entry. Per-keystroke logic
//    (validation, etc.) belongs on a `controller.addListener` in the
//    PARENT form, not here.
// 4. AUTOCORRECT / KEYBOARD SUGGESTIONS OFF. iOS keyboards love to
//    "fix" `"6mm"` to `"6 mm"`, `".308"` to `". 308"`, and `"GM205M"` to
//    `"Gm205m"`. These transforms happen invisibly at the OS level and
//    silently corrupt cataloged-component lookups. We therefore set
//    `autocorrect: false`, `enableSuggestions: false`, and
//    `textCapitalization: TextCapitalization.none` on the inner field.
//    The in-app suggestions list is the source of truth.
// 5. `take(60)` IS NOT A LIMIT, IT'S A PERFORMANCE GUARDRAIL. The
//    cartridge catalog has 200+ rows; rendering all of them in a
//    dropdown would be wasteful. Sixty is enough that any prefix the
//    user types narrows the list to something visually reasonable, but
//    doesn't drive O(N) layout cost on the first build.
//
// ============================================================================
// WHO CONSUMES THIS FILE
// ============================================================================
// - lib/screens/loads/load_form_screen.dart — recipe-form pickers for
//   cartridge, bullet, powder, brass (primer uses `PrimerCascadeField` now).
// - lib/screens/firearms/firearm_form_screen.dart — caliber picker on the
//   firearm form.
//
// ============================================================================
// SIDE EFFECTS
// ============================================================================
// - Reads from SQLite via `ComponentRepository.componentLabels(kind)` once
//   per mount. No writes.
// - Mutates the `controller` passed in by the parent on every keystroke
//   inside the autocomplete-owned text field, and on selection.

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../repositories/component_repository.dart';
import '../repositories/favorites_repository.dart';
import '../repositories/recipe_repository.dart';
import '../services/component_favorites_service.dart';

/// Text field with autocomplete suggestions from a component catalog.
/// Users can pick a suggestion or type a new value; values not in the
/// catalog are persisted as "custom" components on save (by the parent
/// form).
///
/// Matching is token-based: every whitespace-separated token in the
/// query must appear (case-insensitively) as a substring in the option
/// label. So `"6 GT"` matches `"6mm GT"` but not `".30-06 Springfield"`.
///
/// The optional [onSelected] callback fires when the user picks a
/// suggestion (taps an entry in the dropdown). It does NOT fire on
/// every keystroke — for that, listen to [controller] directly.
class ComponentField extends StatefulWidget {
  const ComponentField({
    super.key,
    required this.kind,
    required this.label,
    required this.controller,
    this.helper,
    this.validator,
    this.onSelected,
  });

  /// One of: 'powder' | 'bullet' | 'primer' | 'brass' | 'cartridge'.
  final String kind;
  final String label;
  final TextEditingController controller;
  final String? helper;
  final String? Function(String?)? validator;

  /// Called when the user picks a suggestion from the dropdown. The
  /// value passed is the full selected label (e.g. `"Federal #210M"`).
  final ValueChanged<String>? onSelected;

  @override
  State<ComponentField> createState() => _ComponentFieldState();
}

class _ComponentFieldState extends State<ComponentField> {
  late Future<List<String>> _futureOptions;

  /// For `kind == 'cartridge'` we additionally fetch the cartridge
  /// rows so we can map an option label back to a cartridge id and
  /// check whether it's currently favorited. The bullet/powder/primer
  /// /brass kinds use the name-keyed [ComponentFavoritesService]
  /// instead, so this map stays null for those.
  Future<Map<String, int>>? _futureCartridgeNameToId;

  /// "Frequently used" labels for this kind, derived from the user's
  /// saved recipes. Refreshed in [initState] (one-shot — close-and-
  /// reopen the field to pick up brand-new entries during the same
  /// session, which matches the granularity of `componentLabels`).
  /// Empty list when the user has no recipes touching this kind yet.
  late Future<List<String>> _futureFrequent;

  /// The TextEditingController owned by [Autocomplete] — captured the
  /// first time `fieldViewBuilder` runs so we can attach the listener
  /// exactly once.
  TextEditingController? _innerController;
  VoidCallback? _innerListener;

  @override
  void initState() {
    super.initState();
    final repo = context.read<ComponentRepository>();
    _futureOptions = repo.componentLabels(widget.kind);
    final recipes = context.read<RecipeRepository>();
    _futureFrequent = recipes.mostUsedComponentNames(widget.kind);
    if (widget.kind == 'cartridge') {
      // Build a label → id lookup for the cartridge catalog so we can
      // resolve a dropdown option string back to a row id and check
      // whether it's favorited. The catalog is small (~200 rows) and
      // fetched once during the field's lifetime.
      _futureCartridgeNameToId = repo.allCartridges().then((rows) {
        final map = <String, int>{};
        for (final c in rows) {
          map[c.name] = c.id;
        }
        return map;
      });
    }
  }

  @override
  void dispose() {
    if (_innerController != null && _innerListener != null) {
      _innerController!.removeListener(_innerListener!);
    }
    super.dispose();
  }

  /// Wires up the Autocomplete-owned controller exactly once. Subsequent
  /// builds reuse the same controller, so listeners do not accumulate.
  void _ensureWiring(TextEditingController autocompleteCtrl) {
    if (identical(_innerController, autocompleteCtrl)) return;

    // Tear down any prior wiring (defensive — Autocomplete typically keeps
    // the same controller for the field's lifetime).
    if (_innerController != null && _innerListener != null) {
      _innerController!.removeListener(_innerListener!);
    }

    _innerController = autocompleteCtrl;
    if (autocompleteCtrl.text != widget.controller.text) {
      autocompleteCtrl.text = widget.controller.text;
    }

    _innerListener = () {
      if (widget.controller.text != autocompleteCtrl.text) {
        widget.controller.text = autocompleteCtrl.text;
      }
    };
    autocompleteCtrl.addListener(_innerListener!);
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<List<String>>(
      future: _futureOptions,
      builder: (context, snap) {
        final options = snap.data ?? const <String>[];
        return FutureBuilder<List<String>>(
          future: _futureFrequent,
          builder: (context, freqSnap) {
            final frequent = freqSnap.data ?? const <String>[];
            if (widget.kind == 'cartridge') {
              // Cartridge kind keeps using FavoritesRepository (the
              // existing UserFavorites table) — see `kFavoriteCartridge`.
              // We layer the favorites set + the name→id map and the
              // frequent list into a single `_buildAutocomplete` call.
              return FutureBuilder<Map<String, int>>(
                future: _futureCartridgeNameToId,
                builder: (context, mapSnap) {
                  final nameToId = mapSnap.data ?? const <String, int>{};
                  return StreamBuilder<Set<int>>(
                    stream: context
                        .read<FavoritesRepository>()
                        .watchFavoriteIds(kFavoriteCartridge),
                    builder: (context, favSnap) {
                      final favIds = favSnap.data ?? const <int>{};
                      final favoriteLabels = <String>{
                        for (final entry in nameToId.entries)
                          if (favIds.contains(entry.value)) entry.key,
                      };
                      return _buildAutocomplete(
                        options: options,
                        frequentLabels: frequent,
                        favoriteLabels: favoriteLabels,
                        cartridgeNameToId: nameToId,
                      );
                    },
                  );
                },
              );
            }
            // Powder / bullet / primer / brass: name-keyed favorites
            // via [ComponentFavoritesService]. Watch so toggling a
            // star in the dropdown reflows the list immediately.
            final favorites =
                context.watch<ComponentFavoritesService>().favorites(widget.kind);
            return _buildAutocomplete(
              options: options,
              frequentLabels: frequent,
              favoriteLabels: favorites,
              cartridgeNameToId: const <String, int>{},
            );
          },
        );
      },
    );
  }

  /// Internal helper that builds the actual `Autocomplete<String>`.
  /// Applies the priority ordering rule
  /// (`Favorites → Frequently used → general`) to the dropdown options
  /// in [optionsBuilder], and renders a tappable star icon on each
  /// dropdown row so users can toggle favorites without leaving the
  /// recipe form.
  ///
  /// [favoriteLabels]: the labels currently favorited for this kind.
  /// Always non-null; an empty set means "no favorites yet" and the
  /// favorites-first prefix is skipped.
  ///
  /// [frequentLabels]: the labels the user has used most often,
  /// already in usage-count-desc order. The dropdown shows them as
  /// the second tier — favorites at top, then frequents that aren't
  /// already favorited, then everything else (alphabetical via
  /// upstream `componentLabels`).
  ///
  /// [cartridgeNameToId]: empty for non-cartridge kinds. For
  /// cartridge, lets the star toggle resolve a label back to its
  /// row id so we can reach into [FavoritesRepository] correctly.
  Widget _buildAutocomplete({
    required List<String> options,
    required List<String> frequentLabels,
    required Set<String> favoriteLabels,
    required Map<String, int> cartridgeNameToId,
  }) {
    /// Apply the `Favorites → Frequently used → general` ordering to
    /// a candidate list of post-filter options. Stable inside each
    /// bucket (favorites preserve upstream ordering, frequent
    /// preserves usage-count desc, general preserves the alphabetical
    /// upstream ordering from `componentLabels`). Skips entries
    /// already surfaced in an earlier bucket so each label appears
    /// at most once.
    Iterable<String> withPriorityOrder(Iterable<String> filtered) {
      if (favoriteLabels.isEmpty && frequentLabels.isEmpty) {
        return filtered;
      }
      final filteredSet = filtered.toSet();
      final seen = <String>{};
      final ordered = <String>[];
      // Bucket 1: favorites that survived the filter.
      for (final o in filtered) {
        if (favoriteLabels.contains(o) && seen.add(o)) {
          ordered.add(o);
        }
      }
      // Bucket 2: frequent (excluding anything already shown).
      for (final f in frequentLabels) {
        if (filteredSet.contains(f) && seen.add(f)) {
          ordered.add(f);
        }
      }
      // Bucket 3: everything else, in upstream order.
      for (final o in filtered) {
        if (seen.add(o)) ordered.add(o);
      }
      return ordered;
    }

    return Autocomplete<String>(
      initialValue: TextEditingValue(text: widget.controller.text),
      optionsBuilder: (te) {
        final query = te.text.trim().toLowerCase();
        if (query.isEmpty) return withPriorityOrder(options).take(60);
        final tokens = query
            .split(RegExp(r'\s+'))
            .where((t) => t.isNotEmpty)
            .toList(growable: false);
        if (tokens.isEmpty) return withPriorityOrder(options).take(60);
        final filtered = options.where((o) {
          final lower = o.toLowerCase();
          for (final t in tokens) {
            if (!lower.contains(t)) return false;
          }
          return true;
        });
        return withPriorityOrder(filtered).take(60);
      },
      fieldViewBuilder: (context, textCtrl, focusNode, _) {
        // Wire up exactly once — repeated builds of fieldViewBuilder
        // would otherwise keep adding listeners and slow down taps.
        _ensureWiring(textCtrl);
        return TextFormField(
          controller: textCtrl,
          focusNode: focusNode,
          // Turn off OS-level autocorrect / autocomplete chips. Component
          // names are technical strings ("6mm GT", "Federal #210M") that
          // the keyboard should not be guessing at — the in-app
          // suggestions list is the source of truth.
          autocorrect: false,
          enableSuggestions: false,
          textCapitalization: TextCapitalization.none,
          decoration: InputDecoration(
            labelText: widget.label,
            helperText: widget.helper ?? 'Pick from list or type your own',
          ),
          validator: widget.validator,
        );
      },
      onSelected: (sel) {
        widget.controller.text = sel;
        widget.onSelected?.call(sel);
      },
      optionsViewBuilder: (context, onSelected, options) {
        final theme = Theme.of(context);
        // Pre-compute the "frequent but not favorited" set so the
        // row builder can render its leading icon in O(1). Frequent
        // labels that ARE favorited just get the favorite star —
        // we don't double-decorate.
        final frequentSet = <String>{
          for (final f in frequentLabels)
            if (!favoriteLabels.contains(f)) f,
        };
        return Align(
          alignment: Alignment.topLeft,
          child: Material(
            elevation: 4,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 320),
              child: ListView.builder(
                shrinkWrap: true,
                padding: EdgeInsets.zero,
                itemCount: options.length,
                itemBuilder: (context, i) {
                  final opt = options.elementAt(i);
                  final isFav = favoriteLabels.contains(opt);
                  final isFrequent = frequentSet.contains(opt);
                  // Leading icon: history clock for "frequent",
                  // nothing otherwise. Favorites get their star in
                  // the trailing slot (along with the toggle hit-
                  // target), so we don't double up.
                  final leading = isFrequent
                      ? Icon(
                          Icons.history,
                          size: 16,
                          color: theme.colorScheme.onSurfaceVariant,
                        )
                      : null;
                  return ListTile(
                    dense: true,
                    leading: leading,
                    title: Text(opt),
                    // Trailing star is now TAPPABLE for every kind.
                    // Tap row body → pick the component (existing
                    // behaviour); tap the star → toggle favorite
                    // without dismissing the dropdown. Hit target
                    // is a small `IconButton` so users don't fat-
                    // finger the row tap.
                    trailing: IconButton(
                      icon: Icon(
                        isFav ? Icons.star : Icons.star_border,
                        size: 18,
                        color: isFav
                            ? theme.colorScheme.primary
                            : theme.colorScheme.onSurfaceVariant,
                      ),
                      tooltip: isFav
                          ? 'Remove from favorites'
                          : 'Add to favorites',
                      onPressed: () => _toggleFavorite(
                        opt,
                        cartridgeNameToId: cartridgeNameToId,
                      ),
                      visualDensity: VisualDensity.compact,
                    ),
                    onTap: () => onSelected(opt),
                  );
                },
              ),
            ),
          ),
        );
      },
    );
  }

  /// Toggle the favorite state for [name] in the right backend.
  /// Cartridge favorites live in the [FavoritesRepository] (int
  /// row-id keyed via `UserFavorites`); every other kind lives in
  /// the name-keyed [ComponentFavoritesService]. The row id lookup
  /// runs through [cartridgeNameToId] which the caller already
  /// pre-computed for cartridge kind, so the toggle stays
  /// synchronous from the user's perspective.
  Future<void> _toggleFavorite(
    String name, {
    required Map<String, int> cartridgeNameToId,
  }) async {
    if (widget.kind == 'cartridge') {
      final id = cartridgeNameToId[name];
      if (id == null) return;
      await context
          .read<FavoritesRepository>()
          .toggleFavorite(kFavoriteCartridge, id);
    } else {
      await context
          .read<ComponentFavoritesService>()
          .toggleFavorite(widget.kind, name);
    }
  }
}
