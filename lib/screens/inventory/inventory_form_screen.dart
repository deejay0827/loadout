// FILE: lib/screens/inventory/inventory_form_screen.dart
//
// ============================================================================
// WHAT THIS FILE DOES
// ============================================================================
// Add-or-edit form for one [ComponentInventory] row. Five sections
// vertically: Identification (kind picker, component name field
// hooked up to [ComponentField] for autocomplete against the
// catalog), Quantity & Reorder (current quantity + optional
// reorder threshold), Cost & Lot (optional unit cost in USD,
// optional lot number, opened-on date), Notes, and (only on
// existing rows) an Audit Log card listing every adjustment row
// for this inventory item.
//
// On existing rows a Quick Actions card sits at the top of the
// form with two buttons: Quick Adjust (opens
// [InventoryAdjustDialog]) and Mark Opened (sets `openedAt = now`
// and writes an `'opened'`-reason adjustment row with delta=0).
//
// Same AutoSave wrapper as every other LoadOut form, which keeps
// Cloud Sync up-to-date as the user types.
//
// ============================================================================
// WHY IT EXISTS IN THE ARCHITECTURE
// ============================================================================
// Reached from [InventoryListScreen] — the FAB (new row) and tile
// tap (edit). The Quick Actions are the highest-traffic
// interactions in the inventory subsystem; Mark Opened in
// particular wants to be one tap, not three.
//
// ============================================================================
// WHY THIS IS HARDER THAN IT LOOKS
// ============================================================================
//   * **Kind drives the unit.** Switching the kind picker has to
//     (a) re-derive the unit string the controller writes back to
//     SQLite and (b) update the ComponentField's `kind`
//     parameter so the autocomplete dropdown refilters against
//     the right catalog. We do the latter by keying the
//     `ComponentField` widget on `_kind` so it rebuilds whenever
//     the kind changes.
//   * **Quantity is editable but not ballistics-affecting.**
//     Inventory counts (CLAUDE.md § 0 fourth bucket) can carry
//     placeholder defaults — we pre-fill `quantity = 0` for new
//     rows so the increment dialogs feel like additions to a
//     fresh container.
//   * **The `kind` is locked on existing rows.** Changing kind
//     after rows have been created would invalidate the unit
//     string (and potentially the audit log's interpretation of
//     `delta`); the dropdown is disabled when editing an existing
//     row to keep that consistent.
//   * **No cascading delete UX.** Tapping Delete on the form pops
//     a confirm dialog; the repo's `delete` method handles the
//     adjustment-ledger cascade in a single transaction. Mirror
//     of how the brass-lot list handles dismiss.
//
// ============================================================================
// WHO CONSUMES THIS FILE
// ============================================================================
// - lib/screens/inventory/inventory_list_screen.dart
//
// ============================================================================
// SIDE EFFECTS
// ============================================================================
// Reads / writes via `ComponentInventoryRepository`. Auto-save
// wrapper batches writes through the same path as the explicit
// Save button. Cloud Sync notify hook fires after every successful
// save (no-op when sync is disabled / non-Pro).

import 'package:drift/drift.dart' as drift;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../database/database.dart';
import '../../repositories/component_inventory_repository.dart';
import '../../services/auto_save_service.dart';
import '../../services/cloud_sync_service.dart';
import '../../widgets/auto_save_banner.dart';
import '../../widgets/auto_save_first_time_hint.dart';
import '../../widgets/component_field.dart';
import 'inventory_adjust_dialog.dart';

class InventoryFormScreen extends StatefulWidget {
  const InventoryFormScreen({super.key, this.existing});

  final ComponentInventoryRow? existing;

  @override
  State<InventoryFormScreen> createState() => _InventoryFormScreenState();
}

class _InventoryFormScreenState extends State<InventoryFormScreen> {
  final _formKey = GlobalKey<FormState>();

  late final TextEditingController _componentName;
  late final TextEditingController _quantity;
  late final TextEditingController _reorderThreshold;
  late final TextEditingController _unitCost;
  late final TextEditingController _lotNumber;
  late final TextEditingController _notes;

  String _kind = kInventoryKindPowder;
  DateTime? _openedAt;
  bool _busy = false;

  late final AutoSaveController _autoSave;

  @override
  void initState() {
    super.initState();
    final e = widget.existing;
    _kind = e?.kind ?? kInventoryKindPowder;
    _componentName = TextEditingController(text: e?.componentName ?? '');
    // Inventory counter (CLAUDE.md § 0 fourth bucket — non-
    // ballistics). Pre-fill with 0 for new rows so the user can
    // increment by typing rather than starting from blank; saved
    // value on edit.
    _quantity = TextEditingController(
      text: e == null ? '0' : _formatForEdit(e.quantity, e.unit),
    );
    _reorderThreshold = TextEditingController(
      text: e?.reorderThreshold == null
          ? ''
          : _formatForEdit(e!.reorderThreshold!, e.unit),
    );
    _unitCost = TextEditingController(text: e?.unitCostUsd?.toString() ?? '');
    _lotNumber = TextEditingController(text: e?.lotNumber ?? '');
    _notes = TextEditingController(text: e?.notes ?? '');
    _openedAt = e?.openedAt;

    _autoSave = AutoSaveController(
      service: context.read<AutoSaveService>(),
      onSave: _runAutoSave,
      initialSavedRowId: widget.existing?.id,
      onSavedToCloud: () =>
          context.read<CloudSyncService>().scheduleSyncUp(),
    );

    for (final c in [
      _componentName,
      _quantity,
      _reorderThreshold,
      _unitCost,
      _lotNumber,
      _notes,
    ]) {
      c.addListener(_autoSave.notifyDirty);
    }
  }

  @override
  void dispose() {
    _autoSave.dispose();
    for (final c in [
      _componentName,
      _quantity,
      _reorderThreshold,
      _unitCost,
      _lotNumber,
      _notes,
    ]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<int?> _runAutoSave() async {
    final name = _componentName.text.trim();
    if (name.isEmpty) return null;
    final repo = context.read<ComponentInventoryRepository>();
    final entry = _buildCompanion();
    final existingId = _autoSave.currentRowId;
    if (existingId == null) {
      return repo.insert(entry);
    }
    await repo.update(existingId, entry);
    return existingId;
  }

  ComponentInventoryCompanion _buildCompanion() {
    return ComponentInventoryCompanion(
      kind: drift.Value(_kind),
      componentName: drift.Value(_componentName.text.trim()),
      quantity: drift.Value(_parseDouble(_quantity) ?? 0.0),
      unit: drift.Value(unitForKind(_kind)),
      reorderThreshold: drift.Value(_parseDouble(_reorderThreshold)),
      unitCostUsd: drift.Value(_parseDouble(_unitCost)),
      lotNumber: drift.Value(_nullIfEmpty(_lotNumber)),
      openedAt: drift.Value(_openedAt),
      notes: drift.Value(_nullIfEmpty(_notes)),
    );
  }

  double? _parseDouble(TextEditingController c) {
    final t = c.text.trim();
    if (t.isEmpty) return null;
    return double.tryParse(t);
  }

  String? _nullIfEmpty(TextEditingController c) {
    final t = c.text.trim();
    return t.isEmpty ? null : t;
  }

  String _formatDate(DateTime d) {
    String two(int n) => n.toString().padLeft(2, '0');
    return '${d.year}-${two(d.month)}-${two(d.day)}';
  }

  /// Format a stored quantity for the edit form. Powder gets up to
  /// one decimal; counts render as integers. Trailing ".0" is
  /// stripped so an integer-valued powder stored as 1462.0 renders
  /// as "1462" rather than "1462.0".
  String _formatForEdit(double value, String unit) {
    if (unit == 'gr') {
      final fixed = value.toStringAsFixed(1);
      return fixed.endsWith('.0') ? fixed.substring(0, fixed.length - 2) : fixed;
    }
    return value.round().toString();
  }

  Future<void> _pickOpenedDate() async {
    final now = DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: _openedAt ?? now,
      firstDate: DateTime(now.year - 30),
      lastDate: DateTime(now.year + 1),
    );
    if (!mounted) return;
    if (picked != null) {
      setState(() => _openedAt = picked);
      _autoSave.notifyDirty();
    }
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() => _busy = true);

    final repo = context.read<ComponentInventoryRepository>();
    final messenger = ScaffoldMessenger.of(context);
    final navigator = Navigator.of(context);

    final entry = _buildCompanion();
    final existingId = _autoSave.currentRowId;

    if (existingId == null) {
      await repo.insert(entry);
      messenger.showSnackBar(
        const SnackBar(content: Text('Inventory row saved.')),
      );
    } else {
      await repo.update(existingId, entry);
      messenger.showSnackBar(
        const SnackBar(content: Text('Inventory row updated.')),
      );
    }

    if (mounted) navigator.pop();
  }

  Future<void> _markOpened() async {
    final repo = context.read<ComponentInventoryRepository>();
    final messenger = ScaffoldMessenger.of(context);
    final id = widget.existing?.id;
    if (id == null) return;
    final now = DateTime.now();

    // Persist the openedAt change directly + record an audit row
    // with delta=0 / reason='opened' so the ledger keeps a marker.
    await repo.update(
      id,
      ComponentInventoryCompanion(openedAt: drift.Value(now)),
    );
    await repo.adjust(
      id,
      delta: 0,
      reason: kAdjustReasonOpened,
      notes: 'Container opened',
    );

    if (!mounted) return;
    setState(() => _openedAt = now);
    messenger.showSnackBar(
      const SnackBar(content: Text('Marked opened today.')),
    );
  }

  Future<void> _delete() async {
    final id = widget.existing?.id;
    if (id == null) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Delete This Row?'),
        content: Text(
          '"${_componentName.text.trim()}" and its adjustment history will '
          'be removed. This cannot be undone.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton.tonal(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    final repo = context.read<ComponentInventoryRepository>();
    final messenger = ScaffoldMessenger.of(context);
    final navigator = Navigator.of(context);
    await repo.delete(id);
    if (!mounted) return;
    messenger.showSnackBar(
      const SnackBar(content: Text('Inventory row deleted.')),
    );
    navigator.pop();
  }

  // ─────────────────────── UI ───────────────────────

  @override
  Widget build(BuildContext context) {
    final isEdit = widget.existing != null;
    final autoSaveOn = context.watch<AutoSaveService>().isEnabled;
    return PopScope(
      canPop: true,
      onPopInvokedWithResult: (didPop, _) async {
        await _autoSave.flush();
      },
      child: Scaffold(
        appBar: AppBar(
          title: Text(isEdit ? 'Edit Inventory Row' : 'New Inventory Row'),
          actions: [
            if (isEdit)
              IconButton(
                tooltip: 'Delete',
                icon: const Icon(Icons.delete_outline),
                onPressed: _busy ? null : _delete,
              ),
          ],
        ),
        body: AutoSaveFirstTimeHint(
          child: Column(
            children: [
              AutoSaveBanner(controller: _autoSave),
              Expanded(
                child: Form(
                  key: _formKey,
                  child: ListView(
                    padding: const EdgeInsets.all(16),
                    children: [
                      if (isEdit) _quickActions(),
                      if (isEdit) const SizedBox(height: 12),
                      _Section(
                        title: 'Identification',
                        children: [
                          DropdownButtonFormField<String>(
                            initialValue: _kind,
                            isExpanded: true,
                            decoration:
                                const InputDecoration(labelText: 'Kind *'),
                            // Disabled for existing rows — see file
                            // header for why.
                            onChanged: isEdit
                                ? null
                                : (v) {
                                    if (v == null) return;
                                    setState(() => _kind = v);
                                    _autoSave.notifyDirty();
                                  },
                            items: [
                              for (final k in kInventoryKindOrder)
                                DropdownMenuItem(
                                  value: k,
                                  child: Text(displayKindSingular(k)),
                                ),
                            ],
                          ),
                          const SizedBox(height: 12),
                          // Re-key on _kind so the autocomplete
                          // re-fetches the catalog when the user
                          // flips between powder / primer / etc.
                          ComponentField(
                            key: ValueKey('inventory_componentField_$_kind'),
                            kind: _kind,
                            label: 'Component Name *',
                            controller: _componentName,
                            validator: (v) =>
                                (v == null || v.trim().isEmpty)
                                    ? 'Required'
                                    : null,
                          ),
                        ],
                      ),
                      const SizedBox(height: 16),
                      _Section(
                        title: 'Quantity & Reorder',
                        children: [
                          TextFormField(
                            controller: _quantity,
                            decoration: InputDecoration(
                              labelText: 'On Hand',
                              suffixText: unitForKind(_kind),
                            ),
                            keyboardType:
                                const TextInputType.numberWithOptions(
                                    decimal: true),
                            inputFormatters: [
                              FilteringTextInputFormatter.allow(
                                RegExp(r'[0-9.]'),
                              ),
                            ],
                          ),
                          const SizedBox(height: 12),
                          TextFormField(
                            controller: _reorderThreshold,
                            decoration: InputDecoration(
                              labelText: 'Low-Stock Threshold (Optional)',
                              suffixText: unitForKind(_kind),
                              helperText:
                                  'Show "Low Stock" when on-hand drops below this value.',
                            ),
                            keyboardType:
                                const TextInputType.numberWithOptions(
                                    decimal: true),
                            inputFormatters: [
                              FilteringTextInputFormatter.allow(
                                RegExp(r'[0-9.]'),
                              ),
                            ],
                          ),
                        ],
                      ),
                      const SizedBox(height: 16),
                      _Section(
                        title: 'Cost & Lot',
                        children: [
                          TextFormField(
                            controller: _unitCost,
                            decoration: const InputDecoration(
                              labelText: 'Unit Cost (USD, Optional)',
                              prefixText: '\$ ',
                            ),
                            keyboardType:
                                const TextInputType.numberWithOptions(
                                    decimal: true),
                          ),
                          const SizedBox(height: 12),
                          TextFormField(
                            controller: _lotNumber,
                            decoration: const InputDecoration(
                              labelText: 'Lot / Batch Number (Optional)',
                            ),
                          ),
                          const SizedBox(height: 12),
                          _openedDateField(),
                        ],
                      ),
                      const SizedBox(height: 16),
                      _Section(
                        title: 'Notes',
                        children: [
                          TextFormField(
                            controller: _notes,
                            decoration:
                                const InputDecoration(labelText: 'Notes'),
                            maxLines: 4,
                          ),
                        ],
                      ),
                      if (isEdit) ...[
                        const SizedBox(height: 16),
                        _AuditLogCard(inventoryId: widget.existing!.id),
                      ],
                      const SizedBox(height: 24),
                      FilledButton(
                        onPressed: _busy ? null : _save,
                        child: Text(_finalButtonLabel(autoSaveOn, isEdit)),
                      ),
                      const SizedBox(height: 24),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  String _finalButtonLabel(bool autoSaveOn, bool isEdit) {
    if (autoSaveOn) return 'Done';
    return isEdit ? 'Save Changes' : 'Create Inventory Row';
  }

  Widget _quickActions() {
    final theme = Theme.of(context);
    return Card(
      clipBehavior: Clip.antiAlias,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Text(
                'Quick Actions',
                style: theme.textTheme.labelLarge?.copyWith(
                  color: theme.colorScheme.primary,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: () {
                      InventoryAdjustDialog.show(context, widget.existing!);
                    },
                    icon: const Icon(Icons.exposure_outlined),
                    label: const Text('Quick Adjust'),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: _markOpened,
                    icon: const Icon(Icons.lock_open_outlined),
                    label: const Text('Mark Opened'),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _openedDateField() {
    return InputDecorator(
      decoration: const InputDecoration(labelText: 'Opened On (Optional)'),
      child: Row(
        children: [
          Expanded(
            child: Text(
              _openedAt == null ? 'Never' : _formatDate(_openedAt!),
            ),
          ),
          if (_openedAt != null)
            IconButton(
              tooltip: 'Clear',
              icon: const Icon(Icons.clear),
              onPressed: () {
                setState(() => _openedAt = null);
                _autoSave.notifyDirty();
              },
            ),
          IconButton(
            tooltip: 'Pick Date',
            icon: const Icon(Icons.calendar_today_outlined),
            onPressed: _pickOpenedDate,
          ),
        ],
      ),
    );
  }
}

/// Audit log of every adjustment for this inventory row, newest
/// first. Subscribes to a live stream so deductions from the
/// Quick Adjust dialog appear immediately.
class _AuditLogCard extends StatelessWidget {
  const _AuditLogCard({required this.inventoryId});

  final int inventoryId;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final repo = context.read<ComponentInventoryRepository>();
    return Card(
      clipBehavior: Clip.antiAlias,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 12, 12, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Text(
                'Adjustment History',
                style: theme.textTheme.labelLarge?.copyWith(
                  color: theme.colorScheme.primary,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            StreamBuilder<List<ComponentInventoryAdjustmentRow>>(
              stream: repo.watchAdjustments(inventoryId),
              builder: (context, snap) {
                if (snap.connectionState == ConnectionState.waiting) {
                  return const Padding(
                    padding: EdgeInsets.all(12),
                    child: Center(child: CircularProgressIndicator()),
                  );
                }
                final rows =
                    snap.data ?? const <ComponentInventoryAdjustmentRow>[];
                if (rows.isEmpty) {
                  return Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 4,
                      vertical: 8,
                    ),
                    child: Text(
                      'No adjustments recorded yet. Quick Adjust writes to '
                      'this log automatically.',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  );
                }
                return Column(
                  children: [
                    for (final r in rows.take(10))
                      _AdjustmentRow(row: r),
                    if (rows.length > 10)
                      Padding(
                        padding: const EdgeInsets.only(top: 8),
                        child: Text(
                          'Showing the most recent 10 of ${rows.length} adjustments.',
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ),
                  ],
                );
              },
            ),
          ],
        ),
      ),
    );
  }
}

class _AdjustmentRow extends StatelessWidget {
  const _AdjustmentRow({required this.row});

  final ComponentInventoryAdjustmentRow row;

  String _formatDateTime(DateTime d) {
    String two(int n) => n.toString().padLeft(2, '0');
    return '${d.year}-${two(d.month)}-${two(d.day)} '
        '${two(d.hour)}:${two(d.minute)}';
  }

  String _reasonLabel(String reason) {
    switch (reason) {
      case kAdjustReasonManual:
        return 'Manual';
      case kAdjustReasonBatch:
        return 'Batch';
      case kAdjustReasonAdjustment:
        return 'Recount';
      case kAdjustReasonOpened:
        return 'Opened';
      default:
        return reason;
    }
  }

  String _formatDelta(double value) {
    final abs = value.abs();
    final fixed = abs == abs.truncateToDouble()
        ? abs.toStringAsFixed(0)
        : abs.toStringAsFixed(1);
    if (value > 0) return '+$fixed';
    if (value < 0) return '−$fixed';
    return '0';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final positive = row.delta > 0;
    final negative = row.delta < 0;
    final color = positive
        ? theme.colorScheme.primary
        : negative
            ? theme.colorScheme.error
            : theme.colorScheme.onSurfaceVariant;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          SizedBox(
            width: 64,
            child: Text(
              _formatDelta(row.delta),
              style: theme.textTheme.bodyMedium?.copyWith(
                color: color,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  _formatDateTime(row.createdAt),
                  style: theme.textTheme.bodySmall,
                ),
                if (row.notes != null && row.notes!.trim().isNotEmpty)
                  Text(
                    row.notes!,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
              ],
            ),
          ),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
            decoration: BoxDecoration(
              color: theme.colorScheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(4),
            ),
            child: Text(
              _reasonLabel(row.reason),
              style: theme.textTheme.labelSmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _Section extends StatelessWidget {
  const _Section({required this.title, required this.children});

  final String title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      clipBehavior: Clip.antiAlias,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 12, 12, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Container(
              alignment: Alignment.centerLeft,
              margin: const EdgeInsets.only(bottom: 12),
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 6,
                ),
                decoration: BoxDecoration(
                  color: theme.colorScheme.primary.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(
                    color: theme.colorScheme.primary.withValues(alpha: 0.35),
                  ),
                ),
                child: Text(
                  title,
                  style: theme.textTheme.labelLarge?.copyWith(
                    color: theme.colorScheme.primary,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ),
            ...children,
          ],
        ),
      ),
    );
  }
}
