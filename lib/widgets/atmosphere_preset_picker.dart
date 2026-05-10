// FILE: lib/widgets/atmosphere_preset_picker.dart
//
// ============================================================================
// WHAT THIS FILE DOES
// ============================================================================
// Inline atmosphere-preset picker rendered at the top of the Environment
// section on both the Ballistics and Range Day Setup screens.
//
//     Atmosphere:  [Custom ▼]              [💾 Save as preset]
//                   ─────────
//                   · Camp Atterbury summer
//                   · Camp Atterbury winter
//                   · Big Sandy
//                   ─────────
//                   · Manage presets
//
// Picking a preset auto-fills the four atmosphere fields via the
// `onApplyPreset` callback. Picking "Manage presets" pushes
// `AtmospherePresetsScreen`. The dropdown shows "Custom" when the live
// values do not match any saved preset (within numeric tolerance).
//
// `onSaveAsPreset` is the "💾" button that opens the Save-as-preset
// dialog with the current values pre-filled.
//
// This widget is purely visual + state-management. It does NOT modify
// the host screen's text controllers — the host owns all fields and
// chooses how to map a preset's columns onto its UI. The picker just
// hands back the `AtmospherePresetRow` and lets the host decide.

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../database/database.dart';
import '../repositories/atmosphere_preset_repository.dart';
import '../screens/atmosphere/atmosphere_presets_screen.dart';

/// Live atmosphere readings the host screen wants matched against the
/// preset library. Used to decide whether the picker shows a specific
/// preset name or falls back to "Custom".
class AtmosphereSnapshot {
  const AtmosphereSnapshot({
    required this.stationPressureInHg,
    required this.temperatureF,
    required this.humidityPct,
    this.altitudeFt,
  });

  final double? stationPressureInHg;
  final double? temperatureF;
  final double? humidityPct;
  final double? altitudeFt;

  /// True when every required atmosphere field on this snapshot matches
  /// the equivalent field on [preset] within a small tolerance. Used to
  /// pick "Custom" vs a specific preset name in the picker dropdown.
  /// Optional altitude only contributes when the preset has it set —
  /// otherwise we ignore it on the snapshot side too.
  bool matches(AtmospherePresetRow preset) {
    bool near(double? a, double b, double tol) =>
        a != null && (a - b).abs() <= tol;
    if (!near(stationPressureInHg, preset.stationPressureInHg, 0.005)) {
      return false;
    }
    if (!near(temperatureF, preset.temperatureF, 0.5)) return false;
    if (!near(humidityPct, preset.humidityPct, 0.5)) return false;
    if (preset.altitudeFt != null) {
      if (altitudeFt == null) return false;
      if ((altitudeFt! - preset.altitudeFt!).abs() > 5) return false;
    }
    return true;
  }
}

/// Inline picker widget. Lays out as
/// `Atmosphere: [dropdown ▼]    [Save as preset]`. Sized to live inside
/// a `_SectionCard` body or a `Padding` near the top of the Environment
/// fields.
class AtmospherePresetPicker extends StatelessWidget {
  const AtmospherePresetPicker({
    super.key,
    required this.snapshot,
    required this.onApplyPreset,
    required this.onSaveAsPreset,
    this.dense = false,
  });

  /// The live atmosphere readings to compare against the preset library.
  final AtmosphereSnapshot snapshot;

  /// Called when the user picks a preset from the dropdown. The host
  /// screen is responsible for writing the preset's values into its
  /// own text controllers.
  final void Function(AtmospherePresetRow preset) onApplyPreset;

  /// Called when the user taps the "Save as preset" trailing button.
  /// The host must read its current Environment fields and pass them to
  /// [showSaveAtmospherePresetDialog]. Disabled if null.
  final VoidCallback? onSaveAsPreset;

  /// When true, lays out using compact `OutlinedButton` styling
  /// suitable for the narrower Range Day environment card. The
  /// Ballistics screen leaves it false for a roomier look.
  final bool dense;

  @override
  Widget build(BuildContext context) {
    final repo = context.read<AtmospherePresetRepository>();
    final theme = Theme.of(context);
    return StreamBuilder<List<AtmospherePresetRow>>(
      stream: repo.watchAll(),
      builder: (context, snap) {
        final presets = snap.data ?? const <AtmospherePresetRow>[];
        AtmospherePresetRow? matched;
        for (final p in presets) {
          if (snapshot.matches(p)) {
            matched = p;
            break;
          }
        }
        // "None" when no saved preset matches the current readings —
        // chosen over "Custom" because the dropdown's purpose is
        // picking a saved range, and "Custom" implied the user had
        // entered a one-off configuration on purpose. "None" reads
        // honestly: nothing is selected.
        final selectorLabel = matched?.name ?? 'None';
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            // Subtitle above the row spells out what the picker is.
            // The label says "Range" because each saved preset is
            // tied to a place the user shoots — "Camp Atterbury
            // summer", "Big Sandy". The subtitle makes it clear we
            // mean saved environmental conditions, not a distance.
            Text(
              'Saved environmental conditions for a range or trip.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 6),
            Row(
              children: [
                Text(
                  'Range',
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                    fontWeight: FontWeight.w500,
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: () => _onTap(context, presets, matched),
                    style: OutlinedButton.styleFrom(
                      alignment: Alignment.centerLeft,
                      padding: dense
                          ? const EdgeInsets.symmetric(
                              horizontal: 10, vertical: 6)
                          : const EdgeInsets.symmetric(
                              horizontal: 12, vertical: 10),
                    ),
                    icon: Icon(
                      matched == null
                          ? Icons.place_outlined
                          : Icons.check_circle_outline,
                      size: 16,
                    ),
                    label: Row(
                      children: [
                        Expanded(
                          child: Text(
                            selectorLabel,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        const Icon(Icons.arrow_drop_down, size: 18),
                      ],
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                IconButton(
                  tooltip: 'Save Current Conditions for a Place You Shoot',
                  icon: const Icon(Icons.bookmark_add_outlined),
                  onPressed: onSaveAsPreset,
                ),
              ],
            ),
          ],
        );
      },
    );
  }

  Future<void> _onTap(
    BuildContext context,
    List<AtmospherePresetRow> presets,
    AtmospherePresetRow? selected,
  ) async {
    final result = await showModalBottomSheet<_AtmospherePickResult>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (_) => _AtmospherePickerSheet(
        presets: presets,
        selectedId: selected?.id,
      ),
    );
    if (!context.mounted) return;
    if (result == null) return;
    if (result.openManage) {
      await Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => const AtmospherePresetsScreen(),
        ),
      );
      return;
    }
    if (result.preset != null) {
      onApplyPreset(result.preset!);
    }
  }
}

class _AtmospherePickResult {
  const _AtmospherePickResult({this.preset, this.openManage = false});
  final AtmospherePresetRow? preset;
  final bool openManage;
}

class _AtmospherePickerSheet extends StatelessWidget {
  const _AtmospherePickerSheet({
    required this.presets,
    required this.selectedId,
  });

  final List<AtmospherePresetRow> presets;
  final int? selectedId;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SafeArea(
      child: ListView(
        shrinkWrap: true,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
            child: Text(
              'Pick a Saved Range',
              style: theme.textTheme.titleSmall,
            ),
          ),
          if (presets.isEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
              child: Text(
                'No saved ranges yet. Save the conditions at a place you '
                'shoot, then switch between them in one tap.',
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ),
          for (final p in presets)
            ListTile(
              leading: Icon(
                p.id == selectedId
                    ? Icons.radio_button_checked
                    : Icons.radio_button_unchecked,
                color: p.id == selectedId
                    ? theme.colorScheme.primary
                    : null,
              ),
              title: Text(p.name),
              subtitle: Text(formatPresetSummary(p)),
              onTap: () => Navigator.of(context)
                  .pop(_AtmospherePickResult(preset: p)),
            ),
          const Divider(height: 1),
          ListTile(
            leading: const Icon(Icons.settings_outlined),
            title: const Text('Manage Saved Ranges'),
            onTap: () => Navigator.of(context)
                .pop(const _AtmospherePickResult(openManage: true)),
          ),
        ],
      ),
    );
  }
}
