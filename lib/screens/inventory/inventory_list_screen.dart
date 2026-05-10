// FILE: lib/screens/inventory/inventory_list_screen.dart
//
// ============================================================================
// WHAT THIS FILE DOES
// ============================================================================
// The "Component Inventory" list — every container of powder, primers,
// bullets, brass, and factory cartridges the user has tracked. Reached
// from the Resources directory (NOT the bottom nav, by design — see
// CLAUDE.md § 25). The list groups by component kind with section
// headers ("Powders", "Primers", etc.) and renders one tile per row
// with quantity remaining, an optional days-since-opened hint for
// powder, and a "Low Stock" pill when the row's `quantity` falls
// below its `reorderThreshold`.
//
// Key UI elements:
//   * Sticky kind-grouped sections (`StreamBuilder<List<ComponentInventoryRow>>`
//     subscribed to `ComponentInventoryRepository.watchAll()`).
//   * Per-row tile with a "Quick Adjust" trailing icon that opens
//     [InventoryAdjustDialog] for fast +/- changes without entering
//     the form.
//   * Tap-to-edit pushes [InventoryFormScreen] for the full edit
//     experience (cost, reorder threshold, notes, audit log).
//   * FAB pushes a fresh [InventoryFormScreen].
//   * Empty-state card explains the feature without marketing
//     flourish (the user found this screen on purpose; we don't
//     need to pitch them on it).
//
// Master-detail layout on wide screens follows the same pattern as
// [BrassLotsListScreen] — left list, right pane with the form for
// the selected row. Mobile-width devices fall through to a single
// column and push the form into a new route.
//
// ============================================================================
// WHY IT EXISTS IN THE ARCHITECTURE
// ============================================================================
// This is the canonical entry point for inventory. It's not on the
// bottom nav, not on the home screen, not in onboarding — by design.
// The user's directive: "implement it well, but do not market it.
// It lives under the Resources menu, not as a top-level nav item."
// The goal is parity with The Reloader's Log on the inventory
// surface, without making inventory-management a stated focus of
// LoadOut.
//
// ============================================================================
// WHY THIS IS HARDER THAN IT LOOKS
// ============================================================================
//   * **Title Case throughout.** Every label, every section header,
//     every empty-state heading is Title Case (CLAUDE.md § 0a).
//     Body copy (the empty-state paragraph, dialog descriptions) is
//     sentence case.
//   * **Quantity formatting depends on unit.** "gr" (powder) renders
//     with one decimal (1462.4 gr); "ct" / "rd" (counts) render as
//     integers (1462 ct). The helper [_formatQuantity] enforces this
//     so a stray decimal doesn't leak through.
//   * **Low-stock pill is opt-in per row.** The row's
//     `reorderThreshold` is nullable. Null = no pill ever, so a
//     one-time purchase doesn't nag forever.
//   * **Days-since-opened only shows for powder.** Bullets and
//     primers have effectively unlimited shelf life; powder loses
//     burn-rate stability over many years. Showing the hint on
//     every kind would clutter the list with meaningless numbers.
//   * **No marketing copy.** No "Upgrade to track inventory!", no
//     "New!" pill, no onboarding card. This screen sits politely
//     under Resources for users who want it.
//
// ============================================================================
// WHO CONSUMES THIS FILE
// ============================================================================
// - lib/screens/resources/resources_screen.dart — Resources
//   directory pushes us in via the "Component Inventory" tile.
//
// ============================================================================
// SIDE EFFECTS
// ============================================================================
// Reads `ComponentInventoryRepository.watchAll()` (live SQLite
// stream). Pushes the form screen and the adjust dialog. Calls
// `delete` on dismiss. No network. No shared preferences.

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../database/database.dart';
import '../../repositories/component_inventory_repository.dart';
import '../../utils/responsive.dart';
import '../../widgets/empty_state_card.dart';
import 'inventory_adjust_dialog.dart';
import 'inventory_form_screen.dart';

class InventoryListScreen extends StatefulWidget {
  const InventoryListScreen({super.key});

  @override
  State<InventoryListScreen> createState() => _InventoryListScreenState();
}

class _InventoryListScreenState extends State<InventoryListScreen> {
  int? _selectedRowId;

  @override
  Widget build(BuildContext context) {
    final repo = context.read<ComponentInventoryRepository>();
    final isWide = Breakpoints.isWide(context);

    final list = StreamBuilder<List<ComponentInventoryRow>>(
      stream: repo.watchAll(),
      builder: (context, snap) {
        if (snap.connectionState == ConnectionState.waiting) {
          return const Center(child: CircularProgressIndicator());
        }
        final rows = snap.data ?? const <ComponentInventoryRow>[];
        if (rows.isEmpty) {
          return SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 96),
            child: EmptyStateCard(
              heading: 'Add Your First Container',
              body:
                  'Track how much powder, primers, bullets, brass, and '
                  'factory ammo you have on hand. Each row is one '
                  'container — a jug of powder, a tray of bullets, a '
                  'box of primers.',
              actions: [
                FilledButton.icon(
                  onPressed: () => Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) => const InventoryFormScreen(),
                    ),
                  ),
                  icon: const Icon(Icons.add),
                  label: const Text('Add Inventory Row'),
                ),
              ],
            ),
          );
        }

        // Group by kind, preserving the natural-sort order from the
        // repository.
        final grouped = <String, List<ComponentInventoryRow>>{};
        for (final row in rows) {
          grouped.putIfAbsent(row.kind, () => <ComponentInventoryRow>[]).add(row);
        }

        return ListView(
          padding: const EdgeInsets.only(bottom: 96),
          children: [
            for (final kind in kInventoryKindOrder)
              if (grouped[kind] != null && grouped[kind]!.isNotEmpty) ...[
                _SectionHeader(label: displayKindPlural(kind)),
                for (final row in grouped[kind]!)
                  _InventoryTile(
                    row: row,
                    selected: isWide && _selectedRowId == row.id,
                    onTap: () {
                      if (isWide) {
                        setState(() => _selectedRowId = row.id);
                      } else {
                        Navigator.of(context).push(
                          MaterialPageRoute(
                            builder: (_) =>
                                InventoryFormScreen(existing: row),
                          ),
                        );
                      }
                    },
                    onQuickAdjust: () =>
                        _openQuickAdjust(context, row, repo),
                    onDismissed: () async {
                      await repo.delete(row.id);
                      if (mounted && _selectedRowId == row.id) {
                        setState(() => _selectedRowId = null);
                      }
                    },
                  ),
              ],
          ],
        );
      },
    );

    final fab = FloatingActionButton(
      heroTag: 'inventory_fab',
      onPressed: () => Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => const InventoryFormScreen()),
      ),
      child: const Icon(Icons.add),
    );

    if (!isWide) {
      return Scaffold(
        appBar: AppBar(title: const Text('Component Inventory')),
        body: list,
        floatingActionButton: fab,
      );
    }

    return Scaffold(
      appBar: AppBar(title: const Text('Component Inventory')),
      body: Row(
        children: [
          SizedBox(width: 360, child: list),
          const VerticalDivider(width: 1, thickness: 1),
          Expanded(
            child: _selectedRowId == null
                ? const _InventoryEmptyDetailPane(
                    message:
                        'Select a row to view or edit it, or tap + to add one.',
                  )
                : _InventoryDetailPane(
                    key: ValueKey('inventory_detail_$_selectedRowId'),
                    rowId: _selectedRowId!,
                  ),
          ),
        ],
      ),
      floatingActionButton: fab,
    );
  }

  Future<void> _openQuickAdjust(
    BuildContext context,
    ComponentInventoryRow row,
    ComponentInventoryRepository repo,
  ) async {
    await InventoryAdjustDialog.show(context, row);
    // The dialog writes through the repo and the watch stream picks
    // up the change automatically; nothing else to do here.
  }
}

/// Right-pane wrapper that resolves a row id back to a row before
/// embedding [InventoryFormScreen]. Same pattern as the Brass Lots
/// list.
class _InventoryDetailPane extends StatelessWidget {
  const _InventoryDetailPane({super.key, required this.rowId});

  final int rowId;

  @override
  Widget build(BuildContext context) {
    final repo = context.read<ComponentInventoryRepository>();
    return FutureBuilder<ComponentInventoryRow?>(
      future: repo.getById(rowId),
      builder: (context, snap) {
        if (snap.connectionState != ConnectionState.done) {
          return const Center(child: CircularProgressIndicator());
        }
        final row = snap.data;
        if (row == null) {
          return const _InventoryEmptyDetailPane(
            message: 'This row has been deleted.',
          );
        }
        return InventoryFormScreen(existing: row);
      },
    );
  }
}

class _InventoryEmptyDetailPane extends StatelessWidget {
  const _InventoryEmptyDetailPane({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.inventory_2_outlined,
              size: 56,
              color: theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.6),
            ),
            const SizedBox(height: 12),
            Text(
              message,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 6),
      child: Text(
        label,
        style: theme.textTheme.labelLarge?.copyWith(
          color: theme.colorScheme.primary,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

class _InventoryTile extends StatelessWidget {
  const _InventoryTile({
    required this.row,
    required this.onTap,
    required this.onQuickAdjust,
    required this.onDismissed,
    this.selected = false,
  });

  final ComponentInventoryRow row;
  final VoidCallback onTap;
  final VoidCallback onQuickAdjust;
  final VoidCallback onDismissed;
  final bool selected;

  bool get _isLowStock {
    final t = row.reorderThreshold;
    return t != null && row.quantity < t;
  }

  /// Days since the container was opened. Returns null when the
  /// user hasn't logged an opened date — the UI only renders the
  /// hint for powder anyway.
  int? get _daysSinceOpened {
    final opened = row.openedAt;
    if (opened == null) return null;
    final diff = DateTime.now().difference(opened).inDays;
    return diff < 0 ? 0 : diff;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final qty = _formatQuantity(row.quantity, row.unit);
    final subtitleParts = <String>[
      '$qty ${row.unit}',
      if (row.lotNumber != null && row.lotNumber!.trim().isNotEmpty)
        'Lot ${row.lotNumber!.trim()}',
      if (row.kind == kInventoryKindPowder && _daysSinceOpened != null)
        'Opened ${_daysSinceOpened!}d ago',
    ];
    final subtitle = subtitleParts.join(' · ');

    return Dismissible(
      key: ValueKey('inventory_${row.id}'),
      direction: DismissDirection.endToStart,
      background: Container(
        color: theme.colorScheme.errorContainer,
        alignment: Alignment.centerRight,
        padding: const EdgeInsets.only(right: 24),
        child: const Icon(Icons.delete),
      ),
      confirmDismiss: (_) async {
        return await showDialog<bool>(
              context: context,
              builder: (_) => AlertDialog(
                title: const Text('Delete This Row?'),
                content: Text(
                  '"${row.componentName}" and its adjustment history will '
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
            ) ??
            false;
      },
      onDismissed: (_) => onDismissed(),
      child: ListTile(
        title: Text(row.componentName),
        subtitle: Text(subtitle),
        selected: selected,
        selectedTileColor: theme.colorScheme.primary.withValues(alpha: 0.12),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (_isLowStock)
              Container(
                margin: const EdgeInsets.only(right: 8),
                padding: const EdgeInsets.symmetric(
                  horizontal: 8,
                  vertical: 4,
                ),
                decoration: BoxDecoration(
                  color: theme.colorScheme.errorContainer,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(
                    color: theme.colorScheme.error.withValues(alpha: 0.6),
                  ),
                ),
                child: Text(
                  'Low Stock',
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: theme.colorScheme.error,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            IconButton(
              tooltip: 'Quick Adjust',
              icon: const Icon(Icons.exposure_outlined),
              onPressed: onQuickAdjust,
            ),
          ],
        ),
        onTap: onTap,
      ),
    );
  }
}

/// Format a quantity for display. Powder renders with up to one
/// decimal (e.g. "1462.4"); count-units render as integers
/// ("1462"). Trailing ".0" is stripped so an integer-valued powder
/// quantity ("1462.0") renders as "1462".
String _formatQuantity(double value, String unit) {
  if (unit == 'gr') {
    final fixed = value.toStringAsFixed(1);
    return fixed.endsWith('.0') ? fixed.substring(0, fixed.length - 2) : fixed;
  }
  return value.round().toString();
}
