// FILE: lib/widgets/reticle_picker.dart
//
// ============================================================================
// WHAT THIS FILE DOES
// ============================================================================
// Reusable reticle picker. Embed this in any form — firearm form, range-
// day setup, ballistics profile editor — and it shows the user a
// compact preview tile with the currently-selected reticle, lets them
// tap to open a search-and-pick modal that lists every reticle in the
// catalog, and reports the selection back via a callback.
//
// Public API:
//
// ```dart
// ReticlePickerField(
//   label: 'Reticle',
//   selected: pickedReticleRow,    // ReticleRow? — nullable for "none"
//   onChanged: (row) {
//     setState(() => pickedReticleRow = row);
//   },
//   restrictToOpticId: 12,         // optional: prefer reticles linked
//                                  // to this optic
// )
// ```
//
// The picker handles its own data fetch — it reads the singleton
// `ReticleRepository` from `Provider`, so the parent only has to wire
// `Provider<ReticleRepository>` once at the root (already done in
// `lib/app.dart`).
//
// Layout:
//
//   ┌────────────────────────────────────────────┐
//   │ Reticle                                    │  ← label
//   ├────────────────────────────────────────────┤
//   │ [█][ Vortex EBR-7C MRAD                    │  ← preview + name
//   │     [×]  Razor HD Gen II reticles    [v]   │  ← family + chevron
//   └────────────────────────────────────────────┘
//
// Tapping anywhere on the tile opens a modal bottom sheet with a search
// field and a scrollable list. Each row in the list shows a 64×64
// preview thumbnail rendered with the same `ReticleRenderer`.
//
// ============================================================================
// WHY IT EXISTS
// ============================================================================
// Multiple screens (firearm form, range day, future ballistics work)
// need the same picker, so we wrap it once. Picking from the full
// catalog with no filter is the common case; `restrictToOpticId` adds
// a "compatible" filter for the range-day flow where the user has
// already chosen which optic they're shooting through.
//
// ============================================================================
// WHO CONSUMES THIS FILE
// ============================================================================
// - `lib/screens/firearms/firearm_form_screen.dart` — picker on the
//   Optics card, beneath the optics dropdown.
// - `lib/screens/range_day/...` — surfaces by the parallel agent for
//   their reticle / aim-point UI.

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../data/reticle_library.dart';
import '../database/database.dart';
import '../repositories/reticle_repository.dart';
import 'reticle_renderer.dart';

/// Reusable form field that lets the user pick a reticle. Renders a
/// label, a preview tile with the selected reticle's name and family,
/// and a chevron. Tapping opens a modal-bottom-sheet picker.
class ReticlePickerField extends StatelessWidget {
  const ReticlePickerField({
    super.key,
    required this.selected,
    required this.onChanged,
    this.label = 'Reticle',
    this.allowNone = true,
    this.restrictToOpticId,
  });

  /// Currently selected reticle (drift row), or null for "no reticle".
  final ReticleRow? selected;

  /// Called with the user's selection. `null` means "no reticle" if
  /// `allowNone` is true.
  final ValueChanged<ReticleRow?> onChanged;

  /// Field label text. Defaults to "Reticle".
  final String label;

  /// Whether the picker offers a "None / iron sights" choice. Defaults
  /// to true so a firearm without an optic can keep this field clear.
  final bool allowNone;

  /// Optional optic id to highlight reticles compatible with this
  /// optic. We don't currently filter the list — every reticle is
  /// always pickable — but the row that matches the optic's
  /// `Optics.reticleId` shows a small "default" badge.
  final int? restrictToOpticId;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final repo = context.read<ReticleRepository>();
    final selectedDef = selected != null ? repo.definitionFromRow(selected!) : null;
    return InkWell(
      onTap: () => _open(context),
      borderRadius: BorderRadius.circular(8),
      child: InputDecorator(
        decoration: InputDecoration(
          labelText: label,
          contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        ),
        child: Row(
          children: [
            // Preview thumbnail (or a placeholder when nothing's picked).
            SizedBox(
              width: 56,
              height: 56,
              child: selectedDef != null
                  ? ReticleRenderer(
                      reticle: selectedDef,
                      displayUnit:
                          selectedDef.nativeUnit == ReticleNativeUnit.moa
                              ? 'moa'
                              : 'mil',
                      size: const Size(56, 56),
                      showUnitOverlay: false,
                      color: theme.colorScheme.primary,
                    )
                  : Container(
                      decoration: BoxDecoration(
                        border: Border.all(
                          color: theme.colorScheme.outlineVariant,
                        ),
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: Icon(
                        Icons.crop_free_outlined,
                        size: 22,
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(
                    selected == null
                        ? 'None / iron sights'
                        : '${selected!.manufacturerId} ${selected!.model}',
                    style: theme.textTheme.bodyLarge,
                    overflow: TextOverflow.ellipsis,
                  ),
                  if (selected?.family != null)
                    Text(
                      selected!.family!,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                ],
              ),
            ),
            Icon(Icons.expand_more, color: theme.colorScheme.onSurfaceVariant),
          ],
        ),
      ),
    );
  }

  Future<void> _open(BuildContext context) async {
    final repo = context.read<ReticleRepository>();
    final result = await showModalBottomSheet<_ReticleSelection>(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => _ReticlePickerSheet(
        repo: repo,
        selectedId: selected?.id,
        allowNone: allowNone,
        restrictToOpticId: restrictToOpticId,
      ),
    );
    if (result == null) return;
    if (result.cleared) {
      onChanged(null);
    } else if (result.row != null) {
      onChanged(result.row);
    }
  }
}

/// Internal modal sheet that drives the picker. We isolate it so the
/// parent rebuild doesn't rebuild the search state.
class _ReticleSelection {
  const _ReticleSelection({this.row, this.cleared = false});
  final ReticleRow? row;
  final bool cleared;
}

class _ReticlePickerSheet extends StatefulWidget {
  const _ReticlePickerSheet({
    required this.repo,
    required this.selectedId,
    required this.allowNone,
    required this.restrictToOpticId,
  });

  final ReticleRepository repo;
  final int? selectedId;
  final bool allowNone;
  final int? restrictToOpticId;

  @override
  State<_ReticlePickerSheet> createState() => _ReticlePickerSheetState();
}

class _ReticlePickerSheetState extends State<_ReticlePickerSheet> {
  final TextEditingController _searchController = TextEditingController();
  String _query = '';
  Future<List<ReticleRow>>? _future;
  Future<int?>? _defaultIdFuture;

  @override
  void initState() {
    super.initState();
    _future = widget.repo.allReticles();
    if (widget.restrictToOpticId != null) {
      _defaultIdFuture =
          widget.repo.byOptic(widget.restrictToOpticId!).then((r) => r?.id);
    }
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final media = MediaQuery.of(context);
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.only(bottom: media.viewInsets.bottom),
        child: SizedBox(
          height: media.size.height * 0.8,
          child: Column(
            children: [
              const SizedBox(height: 12),
              Container(
                width: 36,
                height: 4,
                decoration: BoxDecoration(
                  color: theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.4),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        'Pick a reticle',
                        style: theme.textTheme.titleLarge,
                      ),
                    ),
                    if (widget.allowNone)
                      TextButton(
                        onPressed: () => Navigator.of(context)
                            .pop(const _ReticleSelection(cleared: true)),
                        child: const Text('None'),
                      ),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: TextField(
                  controller: _searchController,
                  decoration: const InputDecoration(
                    hintText: 'Search by manufacturer or model',
                    prefixIcon: Icon(Icons.search),
                    isDense: true,
                  ),
                  onChanged: (v) => setState(() => _query = v.trim().toLowerCase()),
                ),
              ),
              const SizedBox(height: 8),
              Expanded(
                child: FutureBuilder<List<ReticleRow>>(
                  future: _future,
                  builder: (context, snap) {
                    if (snap.connectionState == ConnectionState.waiting) {
                      return const Center(
                        child: CircularProgressIndicator(),
                      );
                    }
                    if (snap.hasError) {
                      return Center(
                        child: Text(
                          'Failed to load reticles: ${snap.error}',
                          style: theme.textTheme.bodyMedium,
                        ),
                      );
                    }
                    final all = snap.data ?? const <ReticleRow>[];
                    final filtered = _query.isEmpty
                        ? all
                        : all.where((r) {
                            final hay =
                                '${r.manufacturerId} ${r.model} ${r.family ?? ''}'
                                    .toLowerCase();
                            return hay.contains(_query);
                          }).toList();
                    if (filtered.isEmpty) {
                      return Center(
                        child: Text(
                          'No reticles match "${_searchController.text}"',
                          style: theme.textTheme.bodyMedium?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                      );
                    }
                    return FutureBuilder<int?>(
                      future: _defaultIdFuture ?? Future.value(null),
                      builder: (context, defaultSnap) {
                        final defaultId = defaultSnap.data;
                        return ListView.separated(
                          itemCount: filtered.length,
                          separatorBuilder: (_, _) =>
                              Divider(height: 1, color: theme.dividerColor),
                          itemBuilder: (context, i) {
                            final row = filtered[i];
                            final selected = row.id == widget.selectedId;
                            final isDefault = defaultId == row.id;
                            final def = widget.repo.definitionFromRow(row);
                            return ListTile(
                              leading: SizedBox(
                                width: 64,
                                height: 64,
                                child: ReticleRenderer(
                                  reticle: def,
                                  displayUnit: def.nativeUnit ==
                                          ReticleNativeUnit.moa
                                      ? 'moa'
                                      : 'mil',
                                  size: const Size(64, 64),
                                  showUnitOverlay: false,
                                  color: theme.colorScheme.primary,
                                ),
                              ),
                              title: Text(
                                '${row.manufacturerId} ${row.model}',
                                style: theme.textTheme.bodyLarge,
                              ),
                              subtitle: Text(
                                [
                                  if (row.family != null) row.family!,
                                  '${row.nativeUnit.toUpperCase()} • ${_typeLabel(row.type)}',
                                  if (isDefault) 'default for selected optic',
                                ].join(' • '),
                                style: theme.textTheme.bodySmall?.copyWith(
                                  color: theme.colorScheme.onSurfaceVariant,
                                ),
                              ),
                              trailing: selected
                                  ? Icon(
                                      Icons.check,
                                      color: theme.colorScheme.primary,
                                    )
                                  : null,
                              onTap: () => Navigator.of(context)
                                  .pop(_ReticleSelection(row: row)),
                            );
                          },
                        );
                      },
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  static String _typeLabel(String type) {
    switch (type) {
      case 'ffp':
        return 'FFP';
      case 'sfp':
        return 'SFP';
      case 'fixed':
        return 'Fixed';
      default:
        return type.toUpperCase();
    }
  }
}
