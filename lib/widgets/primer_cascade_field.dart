// FILE: lib/widgets/primer_cascade_field.dart
//
// ============================================================================
// WHAT THIS FILE DOES
// ============================================================================
// Defines `PrimerCascadeField`, a two-stage cascading dropdown for picking
// a primer in the recipe form. Stage one is a manufacturer dropdown
// ("Federal", "CCI", "Winchester", "Remington", …). Stage two appears as
// soon as a manufacturer is chosen and lists THAT manufacturer's primer
// products by their full marketing label, e.g.
// `"Premium Gold Medal Small Rifle Match #GM205M"` rather than the bare
// part number `"GM205M"`. The product list comes from the `productLine`
// column on `Primers` rows that was added in seed-data v3 specifically
// to support this widget.
//
// Public API:
//   - `controller`        — the parent form's `TextEditingController`. The
//                            stored value is the canonical
//                            `"<Brand> #<Name>"` string (e.g.
//                            `"Federal #210M"`), identical in shape to
//                            what the legacy `ComponentField` produced.
//                            Existing recipes round-trip; the rest of the
//                            app — including
//                            `ComponentRepository.primerByLabel` for the
//                            primer-size auto-fill on the recipe form —
//                            keeps working unchanged.
//   - `onSelected(label)` — fires once when the user picks a product from
//                            the second dropdown. Receives the full
//                            canonical label.
//
// State tracked inside `_PrimerCascadeFieldState`:
//   - `_customSentinel`        — the magic string `"__custom__"` used as the
//                                 dropdown value for the "Other / Custom…"
//                                 option, so we can distinguish "user picked
//                                 the escape hatch" from "user picked a real
//                                 manufacturer that happens to be named X".
//   - `_futureBrands`          — the future returned by
//                                 `primerManufacturers()`. Resolved once,
//                                 used to populate the brand dropdown.
//   - `_selectedBrand`         — name of the currently selected manufacturer,
//                                 or `_customSentinel` for free-form mode,
//                                 or null on first build.
//   - `_selectedPrimerName`    — the bare model number once the user has
//                                 picked a product (e.g. `"GM205M"`).
//                                 Stays null until they do.
//   - `_futureProducts`        — future for the product list of the picked
//                                 brand. Re-issued every time the brand
//                                 changes.
//   - `_customController`      — separate `TextEditingController` for the
//                                 free-form text field that appears in
//                                 custom mode. Pre-populated from the parent
//                                 controller so users can edit, not retype.
//
// Key methods:
//   - `_hydrateFromController(text)` — invoked from `initState`. Parses an
//     incoming canonical label (`"Federal #210M"`) via
//     `ComponentRepository.splitPrimerStorageLabel`, and pre-selects both
//     dropdowns so editing an existing recipe shows the user what was
//     stored. If the parse fails (legacy data, custom entry, empty) we
//     either drop into custom mode or leave both dropdowns unset.
//   - `_onExternalControllerChange()` — listener on the parent controller.
//     Re-hydrates state when the parent resets the field (e.g. tapping
//     "New Recipe" clears the form). Guarded with equality checks to
//     avoid `setState` loops.
//   - `_onBrandChanged(value)` — runs when the brand dropdown changes.
//     Either issues a fresh `primersByManufacturer(brand)` future or, for
//     the custom sentinel, tears down the products future and copies the
//     custom text into the parent controller.
//   - `_onProductChanged(p)` — runs when the product dropdown changes.
//     Builds the canonical label via
//     `ComponentRepository.primerStorageLabel` and writes it to the
//     parent controller, then fires `onSelected`.
//   - `_onCustomTextChanged(value)` — pipes free-form text directly to the
//     parent controller in custom mode.
//
// `_PlaceholderHint` is a tiny private widget that renders a one-line
// italicized hint ("Pick a primer brand to see available products.") when
// no brand has been picked yet.
//
// ============================================================================
// WHY IT EXISTS IN THE ARCHITECTURE
// ============================================================================
// Reloaders identify primers in two different ways:
//
//   - GUNR-style part-number labels  ("Federal #205M", "CCI #BR4")
//     used in load-data publications and forum threads.
//   - Marketing-name labels          ("Premium Gold Medal Small Rifle
//                                      Match", "Benchrest Small Rifle")
//     used on the actual box at the store.
//
// New reloaders see "#205M" on a Hodgdon load chart and have no idea that
// "Federal Gold Medal Match Small Rifle" on the shelf in front of them is
// the same thing. The flat, single-field `ComponentField` legacy primer
// picker only displayed the part-number form, so we hid the marketing
// label that connects the two worlds. The cascading dropdown shows BOTH
// — the marketing line AND the part number — so the picker doubles as a
// "what's on the shelf" lookup.
//
// We could not just replace the existing storage format. Existing recipes
// in the wild already store `"Federal #210M"` as a single string, and
// other places in the app (the primer-size auto-fill, anything that
// renders a recipe summary) parse that exact format. So this widget
// READS via the cascading UI but WRITES the same canonical string the old
// widget did. That gives us the new UX without forcing a migration.
//
// ============================================================================
// WHY THIS IS HARDER THAN IT LOOKS
// ============================================================================
// 1. ROUND-TRIPPING THE STORED LABEL. To show the right brand and product
//    when an existing recipe is loaded, `_hydrateFromController` parses
//    the canonical label, looks up the manufacturer's products, and
//    matches by `name`. If the manufacturer name in the stored label
//    doesn't match anything in the seeded primers table (e.g. the user
//    saved a custom value through the legacy widget), we fall back to
//    custom mode rather than silently dropping the data.
// 2. THE EXTERNAL-CONTROLLER LOOP. The parent can reset the controller
//    (clear the recipe, load a different recipe). We listen for that and
//    re-hydrate. But re-hydration calls `setState`, which writes back to
//    the controller, which fires the listener again. We break the loop
//    by checking each piece of state for equality before calling
//    `setState`.
// 3. CUSTOM-MODE ESCAPE HATCH. Not every primer the user might want is in
//    the catalog (Russian Murom KVB-7, obscure benchrest brands, etc.).
//    The "Other / Custom…" option in the brand dropdown, encoded by the
//    `_customSentinel` string, swaps the second dropdown for a free-form
//    `TextFormField`. Whatever the user types becomes the canonical
//    stored value verbatim, no `"<Brand> #<Name>"` prefix.
// 4. TWO FUTURES. The brand list comes from one query, the products
//    list from a second query that depends on the brand. We use two
//    nested `FutureBuilder`s rather than a single one because each
//    future has a different lifetime and the products future re-issues
//    every time `_onBrandChanged` runs.
// 5. `DropdownButtonFormField<PrimerRow>` USES THE ENTIRE ROW AS THE
//    VALUE. Dart equality on drift `PrimerRow` is reference-based, so we
//    cannot pre-select by simply passing in a freshly-fetched row.
//    Instead we scan the products list for one whose `name` matches the
//    pre-selected `_selectedPrimerName` and pass THAT exact instance to
//    `initialValue`.
//
// ============================================================================
// WHO CONSUMES THIS FILE
// ============================================================================
// - lib/screens/loads/load_form_screen.dart — the primer row in the
//   recipe form is the only caller today.
//
// ============================================================================
// SIDE EFFECTS
// ============================================================================
// - Reads from SQLite via `ComponentRepository.primerManufacturers()` and
//   `primersByManufacturer(brand)`. No writes — the widget only mutates
//   the parent's `TextEditingController`.

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../database/database.dart';
import '../repositories/component_repository.dart';

/// Two-stage cascading dropdown for primer selection.
///
/// First dropdown picks a manufacturer (e.g. "Federal"). Second dropdown
/// then loads the products for that manufacturer and shows them with their
/// marketing name plus model number, e.g.
/// `"Premium Gold Medal Small Rifle Match #GM205M"`.
///
/// The widget persists the user's pick into a single [TextEditingController]
/// using the `"<Brand> #<Name>"` format, identical to the legacy
/// [ComponentField] behavior, so existing recipes load and save unchanged.
///
/// A "type your own" fallback is provided for users whose primer isn't in
/// the catalog: pick "Other / Custom…" in the brand dropdown to expose a
/// free-form text field.
class PrimerCascadeField extends StatefulWidget {
  const PrimerCascadeField({
    super.key,
    required this.controller,
    this.onSelected,
  });

  /// Stores the canonical `"<Brand> #<Name>"` label (e.g. `"Federal #210M"`).
  /// Same shape used by the prior single [ComponentField] so the rest of the
  /// app — including [ComponentRepository.primerByLabel] for primer-size
  /// auto-fill — keeps working unchanged.
  final TextEditingController controller;

  /// Fires when the user picks a primer from the dropdown (not on every
  /// keystroke of the custom text field). Receives the canonical label.
  final ValueChanged<String>? onSelected;

  @override
  State<PrimerCascadeField> createState() => _PrimerCascadeFieldState();
}

class _PrimerCascadeFieldState extends State<PrimerCascadeField> {
  static const String _customSentinel = '__custom__';

  Future<List<String>>? _futureBrands;
  String? _selectedBrand;
  String? _selectedPrimerName; // null until product is picked
  Future<List<PrimerRow>>? _futureProducts;
  late TextEditingController _customController;

  @override
  void initState() {
    super.initState();
    _customController = TextEditingController(text: widget.controller.text);
    _futureBrands = context.read<ComponentRepository>().primerManufacturers();
    // Try to pre-select brand + product from the existing controller value.
    _hydrateFromController(widget.controller.text);
    widget.controller.addListener(_onExternalControllerChange);
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onExternalControllerChange);
    _customController.dispose();
    super.dispose();
  }

  /// Re-hydrate when the parent form resets the controller (e.g. clears for
  /// "New Recipe"). Avoid loops by only setting state when something changed.
  void _onExternalControllerChange() {
    final text = widget.controller.text;
    final parsed = ComponentRepository.splitPrimerStorageLabel(text);
    if (parsed == null) {
      // Either empty or custom value
      if (_selectedBrand != _customSentinel || _customController.text != text) {
        setState(() {
          _selectedBrand = text.isEmpty ? null : _customSentinel;
          _selectedPrimerName = null;
          _customController.text = text;
        });
      }
      return;
    }
    if (_selectedBrand != parsed.manufacturer ||
        _selectedPrimerName != parsed.primerName) {
      setState(() {
        _selectedBrand = parsed.manufacturer;
        _selectedPrimerName = parsed.primerName;
        _futureProducts = context
            .read<ComponentRepository>()
            .primersByManufacturer(parsed.manufacturer);
      });
    }
  }

  void _hydrateFromController(String text) {
    final parsed = ComponentRepository.splitPrimerStorageLabel(text);
    if (parsed != null) {
      _selectedBrand = parsed.manufacturer;
      _selectedPrimerName = parsed.primerName;
      _futureProducts = context
          .read<ComponentRepository>()
          .primersByManufacturer(parsed.manufacturer);
    } else if (text.isNotEmpty) {
      _selectedBrand = _customSentinel;
      _customController.text = text;
    }
  }

  void _onBrandChanged(String? value) {
    if (value == null) return;
    setState(() {
      _selectedBrand = value;
      _selectedPrimerName = null;
      if (value == _customSentinel) {
        _futureProducts = null;
        // Preserve any existing custom text the user typed before
        widget.controller.text = _customController.text;
      } else {
        _futureProducts =
            context.read<ComponentRepository>().primersByManufacturer(value);
        // Clear stored value until a product is picked
        widget.controller.text = '';
      }
    });
  }

  void _onProductChanged(PrimerRow? p) {
    if (p == null || _selectedBrand == null) return;
    final label =
        ComponentRepository.primerStorageLabel(_selectedBrand!, p);
    setState(() {
      _selectedPrimerName = p.name;
      widget.controller.text = label;
    });
    widget.onSelected?.call(label);
  }

  void _onCustomTextChanged(String value) {
    widget.controller.text = value;
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<List<String>>(
      future: _futureBrands,
      builder: (context, snap) {
        final brands = snap.data ?? const <String>[];
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            DropdownButtonFormField<String>(
              initialValue: _selectedBrand,
              isExpanded: true,
              decoration: const InputDecoration(
                labelText: 'Primer Brand',
                helperText: 'Pick a manufacturer or choose "Other / Custom"',
              ),
              items: [
                for (final b in brands)
                  DropdownMenuItem<String>(value: b, child: Text(b)),
                const DropdownMenuItem<String>(
                  value: _customSentinel,
                  child: Text('Other / Custom…'),
                ),
              ],
              onChanged: _onBrandChanged,
            ),
            const SizedBox(height: 12),
            if (_selectedBrand == null)
              const _PlaceholderHint(
                text: 'Pick a primer brand to see available products.',
              )
            else if (_selectedBrand == _customSentinel)
              TextFormField(
                controller: _customController,
                onChanged: _onCustomTextChanged,
                decoration: const InputDecoration(
                  labelText: 'Custom Primer',
                  helperText: 'Type the brand and model, e.g. "Murom KVB-7"',
                ),
              )
            else
              FutureBuilder<List<PrimerRow>>(
                future: _futureProducts,
                builder: (context, prodSnap) {
                  if (prodSnap.connectionState == ConnectionState.waiting) {
                    return const Padding(
                      padding: EdgeInsets.symmetric(vertical: 12),
                      child: LinearProgressIndicator(minHeight: 2),
                    );
                  }
                  final products = prodSnap.data ?? const <PrimerRow>[];
                  PrimerRow? selected;
                  for (final p in products) {
                    if (p.name == _selectedPrimerName) {
                      selected = p;
                      break;
                    }
                  }
                  // Open-menu items: two-line layout — marketing name on
                  // top (wraps to 2 lines if long), SKU `#name` rendered as
                  // a small brass-tinted chip below. Avoids the
                  // "Premium Gold Medal Large Pistol Match #GM1..."
                  // ellipsis-truncation problem entirely. `itemHeight: null`
                  // lets each row size to its content instead of being
                  // clamped to the default 48 px.
                  //
                  // Closed-state (selectedItemBuilder): a single-line
                  // compact label so the field doesn't suddenly grow tall
                  // when a long primer is selected. Truncates with ellipsis
                  // on the closed field — that's fine because the user
                  // chose it and just needs a quick "yes that's the one"
                  // confirmation.
                  return DropdownButtonFormField<PrimerRow>(
                    initialValue: selected,
                    isExpanded: true,
                    itemHeight: null,
                    decoration: const InputDecoration(
                      labelText: 'Primer Product',
                    ),
                    selectedItemBuilder: (context) => [
                      for (final p in products)
                        Align(
                          alignment: AlignmentDirectional.centerStart,
                          child: Text(
                            ComponentRepository.primerProductLabel(p),
                            overflow: TextOverflow.ellipsis,
                            maxLines: 1,
                          ),
                        ),
                    ],
                    items: [
                      for (final p in products)
                        DropdownMenuItem<PrimerRow>(
                          value: p,
                          child: _PrimerProductRow(primer: p),
                        ),
                    ],
                    onChanged: _onProductChanged,
                  );
                },
              ),
          ],
        );
      },
    );
  }
}

class _PlaceholderHint extends StatelessWidget {
  const _PlaceholderHint({required this.text});
  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(top: 4, bottom: 8),
      child: Text(
        text,
        style: theme.textTheme.bodySmall?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
          fontStyle: FontStyle.italic,
        ),
      ),
    );
  }
}

/// Two-line layout for one item in the primer-product dropdown:
///
///   Line 1: marketing name (`productLine`), allowed to wrap up to 2 lines
///           so the longest names ("Premium Gold Medal Large Rifle Magnum
///           Match") aren't truncated.
///   Line 2: model number `#name` rendered as a small brass-tinted chip,
///           shown for every primer regardless of whether the marketing
///           name fits on one line. The chip becomes a quick scan target
///           when the user is hunting for a specific SKU.
///
/// Layout uses `Padding` + `Column` rather than `ListTile`'s built-in
/// title/subtitle slots because `ListTile` enforces its own internal
/// padding and doesn't compose cleanly inside a `DropdownMenuItem`.
class _PrimerProductRow extends StatelessWidget {
  const _PrimerProductRow({required this.primer});

  final PrimerRow primer;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final productLine = primer.productLine;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (productLine != null && productLine.isNotEmpty)
            Text(
              productLine,
              softWrap: true,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodyMedium?.copyWith(
                fontWeight: FontWeight.w500,
              ),
            ),
          if (productLine != null && productLine.isNotEmpty)
            const SizedBox(height: 4),
          // Brass-tinted SKU chip — same style cue as the SAAMI doc /
          // case-subtype chips on the spec screen, so the eye learns "brass
          // chip = identifier" across the whole app.
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
            decoration: BoxDecoration(
              color: theme.colorScheme.primary.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(6),
              border: Border.all(
                color: theme.colorScheme.primary.withValues(alpha: 0.30),
              ),
            ),
            child: Text(
              '#${primer.name}',
              style: theme.textTheme.labelSmall?.copyWith(
                color: theme.colorScheme.primary,
                fontWeight: FontWeight.w600,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
