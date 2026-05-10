// FILE: lib/screens/inventory/inventory_adjust_dialog.dart
//
// ============================================================================
// WHAT THIS FILE DOES
// ============================================================================
// A focused dialog for fast quantity adjustments on a single
// [ComponentInventory] row. Two modes via a segmented control:
//
//   * **Adjust** — relative change (`+10`, `-50`). Calls
//     `ComponentInventoryRepository.adjust(id, delta: ..., reason:
//     'manual', notes: ...)`.
//   * **Set To** — absolute reset (used after a physical recount).
//     Calls `ComponentInventoryRepository.setQuantity(id,
//     newQuantity: ..., reason: 'adjustment', notes: ...)`.
//
// Both paths write a row to the audit-log table inside the same
// transaction as the master-row update, so the running quantity
// and the history can never drift apart.
//
// Usage:
//   await InventoryAdjustDialog.show(context, inventoryRow);
//
// The static `show` helper opens the dialog and returns when the
// user dismisses it. Callers don't have to handle the result —
// the live `watchAll()` stream on the list screen picks up the
// change automatically.
//
// ============================================================================
// WHY IT EXISTS IN THE ARCHITECTURE
// ============================================================================
// The list screen needs a one-tap "decrement by 50" affordance for
// the common case of "I just loaded 50 rounds, drop my primer
// count by 50". Forcing the user into the full form for that is
// friction. This dialog packages the operation tightly: pick mode,
// type the number, confirm.
//
// ============================================================================
// WHY THIS IS HARDER THAN IT LOOKS
// ============================================================================
//   * **The Sign matters.** In Adjust mode, the user types a
//     SIGNED number (`-50` to consume, `+10` to replenish). The
//     dialog accepts the leading `-` AND offers "Add" / "Subtract"
//     toggle buttons that flip the sign for the user, so a
//     reloader at the bench can stay one-handed.
//   * **The unit string.** Powder is "gr", primer/bullet/brass is
//     "ct", cartridge is "rd". The dialog displays the unit as a
//     suffix next to the input field so the user is reminded what
//     they're entering.
//   * **Null delta = no-op.** The Save button is disabled when the
//     parsed value is zero or null, so a tap on Save with an empty
//     field doesn't write a vacuous audit row.
//
// ============================================================================
// WHO CONSUMES THIS FILE
// ============================================================================
// - lib/screens/inventory/inventory_list_screen.dart — Quick
//   Adjust trailing icon on every tile.
// - lib/screens/inventory/inventory_form_screen.dart — Quick
//   Actions card on the form.
//
// ============================================================================
// SIDE EFFECTS
// ============================================================================
// Calls `ComponentInventoryRepository.adjust` or `setQuantity`,
// which writes through to SQLite inside a transaction and emits
// new values on `watchAll()`. No network. No shared preferences.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../database/database.dart';
import '../../repositories/component_inventory_repository.dart';

enum _AdjustMode { adjust, setTo }

class InventoryAdjustDialog extends StatefulWidget {
  const InventoryAdjustDialog({
    super.key,
    required this.row,
  });

  final ComponentInventoryRow row;

  /// Convenience helper — opens the dialog as a modal.
  static Future<void> show(
    BuildContext context,
    ComponentInventoryRow row,
  ) {
    return showDialog<void>(
      context: context,
      builder: (_) => InventoryAdjustDialog(row: row),
    );
  }

  @override
  State<InventoryAdjustDialog> createState() => _InventoryAdjustDialogState();
}

class _InventoryAdjustDialogState extends State<InventoryAdjustDialog> {
  late final TextEditingController _amount;
  late final TextEditingController _notes;
  _AdjustMode _mode = _AdjustMode.adjust;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    // The amount field is a quantity entry, not a ballistics input
    // — defaulting to '' (empty) makes the dialog feel inert; we
    // pre-fill nothing so the keyboard's first keystroke goes
    // straight into the field.
    _amount = TextEditingController();
    _notes = TextEditingController();
  }

  @override
  void dispose() {
    _amount.dispose();
    _notes.dispose();
    super.dispose();
  }

  bool get _hasValue {
    final v = double.tryParse(_amount.text.trim());
    if (v == null) return false;
    if (_mode == _AdjustMode.adjust && v == 0) return false;
    return true;
  }

  Future<void> _save() async {
    final repo = context.read<ComponentInventoryRepository>();
    final messenger = ScaffoldMessenger.of(context);
    final navigator = Navigator.of(context);
    final value = double.tryParse(_amount.text.trim());
    if (value == null) return;
    setState(() => _busy = true);
    final notes = _notes.text.trim().isEmpty ? null : _notes.text.trim();

    if (_mode == _AdjustMode.adjust) {
      await repo.adjust(
        widget.row.id,
        delta: value,
        reason: kAdjustReasonManual,
        notes: notes,
      );
    } else {
      await repo.setQuantity(
        widget.row.id,
        newQuantity: value,
        reason: kAdjustReasonAdjustment,
        notes: notes,
      );
    }

    if (!mounted) return;
    setState(() => _busy = false);
    messenger.showSnackBar(
      SnackBar(
        content: Text(
          _mode == _AdjustMode.adjust
              ? 'Inventory updated.'
              : 'Inventory reset.',
        ),
      ),
    );
    navigator.pop();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final unit = widget.row.unit;
    return AlertDialog(
      title: Text(widget.row.componentName),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'On hand: ${_formatQuantity(widget.row.quantity, unit)} $unit',
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 12),
            SegmentedButton<_AdjustMode>(
              segments: const [
                ButtonSegment(
                  value: _AdjustMode.adjust,
                  label: Text('Adjust'),
                  icon: Icon(Icons.exposure_outlined),
                ),
                ButtonSegment(
                  value: _AdjustMode.setTo,
                  label: Text('Set To'),
                  icon: Icon(Icons.edit_outlined),
                ),
              ],
              selected: {_mode},
              onSelectionChanged: (sel) {
                setState(() {
                  _mode = sel.first;
                });
              },
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _amount,
              autofocus: true,
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
                signed: true,
              ),
              inputFormatters: [
                FilteringTextInputFormatter.allow(RegExp(r'[-0-9.]')),
              ],
              decoration: InputDecoration(
                labelText: _mode == _AdjustMode.adjust
                    ? 'Change'
                    : 'New Quantity',
                hintText: _mode == _AdjustMode.adjust
                    ? '-50, +10, etc.'
                    : 'e.g. 1500',
                suffixText: unit,
              ),
              onChanged: (_) => setState(() {}),
            ),
            if (_mode == _AdjustMode.adjust) ...[
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      onPressed: () => _flipSign(positive: false),
                      child: const Text('Subtract'),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: OutlinedButton(
                      onPressed: () => _flipSign(positive: true),
                      child: const Text('Add'),
                    ),
                  ),
                ],
              ),
            ],
            const SizedBox(height: 16),
            TextField(
              controller: _notes,
              decoration: const InputDecoration(
                labelText: 'Note (Optional)',
              ),
              maxLines: 2,
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _busy ? null : () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: !_hasValue || _busy ? null : _save,
          child: const Text('Save'),
        ),
      ],
    );
  }

  /// Flip the sign of the typed value to match the requested
  /// polarity. Empty fields stay empty (the user hasn't typed
  /// anything yet); a `-50` becomes `50` if `positive=true`, etc.
  void _flipSign({required bool positive}) {
    final raw = _amount.text.trim();
    if (raw.isEmpty) return;
    final cleaned = raw.startsWith('-') ? raw.substring(1) : raw;
    _amount.text = positive ? cleaned : '-$cleaned';
    _amount.selection = TextSelection.fromPosition(
      TextPosition(offset: _amount.text.length),
    );
    setState(() {});
  }
}

String _formatQuantity(double value, String unit) {
  if (unit == 'gr') {
    final fixed = value.toStringAsFixed(1);
    return fixed.endsWith('.0') ? fixed.substring(0, fixed.length - 2) : fixed;
  }
  return value.round().toString();
}
