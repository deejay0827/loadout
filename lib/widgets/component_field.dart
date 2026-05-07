import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../repositories/component_repository.dart';

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

  /// The TextEditingController owned by [Autocomplete] — captured the
  /// first time `fieldViewBuilder` runs so we can attach the listener
  /// exactly once.
  TextEditingController? _innerController;
  VoidCallback? _innerListener;

  @override
  void initState() {
    super.initState();
    _futureOptions =
        context.read<ComponentRepository>().componentLabels(widget.kind);
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
        return Autocomplete<String>(
          initialValue: TextEditingValue(text: widget.controller.text),
          optionsBuilder: (te) {
            final query = te.text.trim().toLowerCase();
            if (query.isEmpty) return options.take(60);
            final tokens = query
                .split(RegExp(r'\s+'))
                .where((t) => t.isNotEmpty)
                .toList(growable: false);
            if (tokens.isEmpty) return options.take(60);
            return options.where((o) {
              final lower = o.toLowerCase();
              for (final t in tokens) {
                if (!lower.contains(t)) return false;
              }
              return true;
            }).take(60);
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
            return Align(
              alignment: Alignment.topLeft,
              child: Material(
                elevation: 4,
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxHeight: 280),
                  child: ListView.builder(
                    shrinkWrap: true,
                    padding: EdgeInsets.zero,
                    itemCount: options.length,
                    itemBuilder: (context, i) {
                      final opt = options.elementAt(i);
                      return ListTile(
                        dense: true,
                        title: Text(opt),
                        onTap: () => onSelected(opt),
                      );
                    },
                  ),
                ),
              ),
            );
          },
        );
      },
    );
  }
}
