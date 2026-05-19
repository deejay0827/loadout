// FILE: lib/screens/settings/app_preferences_screen.dart
//
// ============================================================================
// WHAT THIS FILE DOES
// ============================================================================
// Settings → App preferences submenu. Hosts the shipping preferences
// that affect day-to-day editing experience:
//   * Beginner Mode toggle
//   * Auto-save frequency picker + leave-without-saving policy picker
//   * Language picker
//   * Units of Measurement (master + per-category)
//
// The auto-save controls are two list tiles backed by single-choice
// modal sheets:
//   * "Auto-save frequency" — `Off`, `After Any Change`, `Every
//     Minute`, `Every 5 Minutes`, `Every 10 Minutes`. Persists via
//     [AutoSaveService.setFrequency] under
//     `auto_save_frequency`.
//   * "When you leave without saving" — `Ask me each time`, `Discard
//     changes`, `Save changes automatically`. Persists via
//     [AutoSaveService.setUnsavedChangesPolicy] under
//     `unsaved_changes_policy`.
//
// ============================================================================
// WHY IT EXISTS IN THE ARCHITECTURE
// ============================================================================
// "App preferences" is the natural home for cross-cutting toggles that
// affect every form / screen. The user expects to find Beginner Mode,
// units, and language together — bundling them into one submenu lets us
// keep the top-level Settings page short.

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../l10n/app_localizations.dart';
import '../../models/visual_style.dart';
import '../../services/auto_save_service.dart';
import '../../services/beginner_mode_service.dart';
import '../../services/locale_service.dart';
import '../../services/unit_service.dart';
import '../../services/visual_style_notifier.dart';
import '../atmosphere/atmosphere_presets_screen.dart';

class AppPreferencesScreen extends StatelessWidget {
  const AppPreferencesScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final autoSave = context.watch<AutoSaveService>();
    final beginner = context.watch<BeginnerModeService>();
    final units = context.watch<UnitService>();
    final localeService = context.watch<LocaleService>();
    final visualStyle = context.watch<VisualStyleNotifier>();
    final l = AppLocalizations.of(context)!;
    return Scaffold(
      appBar: AppBar(title: const Text('App Preferences')),
      body: ListView(
        children: [
          SwitchListTile(
            secondary: const Icon(Icons.school_outlined),
            title: const Text('Beginner Mode'),
            subtitle: const Text(
              'Keeps the recipe form simple, shows extra hints, and '
              'starts you in the Quick Add screen. Turn off when you '
              'want every field at your fingertips.',
            ),
            value: beginner.isEnabled,
            onChanged: (v) {
              // ignore: discarded_futures
              beginner.setEnabled(v);
            },
          ),
          const _SectionHeader('Auto-save'),
          _AutoSaveFrequencyTile(service: autoSave),
          _UnsavedChangesPolicyTile(service: autoSave),
          // VFP Phase 3 — visual tier picker. Three tiers: stylized
          // (procedural scene with the full atmospheric-effects pass —
          // the entry tier, ex-`polished`), scenic (upcoming 2.5D
          // photo backdrop, VFP Phase 6), photographic (upcoming full
          // 3D, VFP Phase 23). Scenic / photographic render as stylized
          // until their painters land. Persisted via VisualStyleNotifier;
          // the Range Day AppBar shows a synced compact toggle.
          const _SectionHeader('Visual Style'),
          _VisualStyleTile(service: visualStyle),
          // Language picker.
          _LanguageTile(
            localeService: localeService,
            title: l.settingsLanguage,
            subtitle: l.settingsLanguageSubtitle,
            systemDefaultLabel: l.settingsLanguageSystem,
          ),
          // Atmosphere presets (v17). Shortcut to the Manage Presets
          // screen so users who don't go through the inline picker can
          // still find the library.
          ListTile(
            leading: const Icon(Icons.cloud_outlined),
            title: const Text('Atmosphere Presets'),
            subtitle: const Text(
              'Save and reuse named atmosphere conditions (e.g. "Camp '
              'Atterbury summer", "Big Sandy") on Ballistics and Range Day.',
            ),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute(
                builder: (_) => const AtmospherePresetsScreen(),
              ),
            ),
          ),
          const _SectionHeader('Units of Measurement'),
          _UnitsSection(units: units),
        ],
      ),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader(this.title);

  final String title;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
      child: Text(
        title.toUpperCase(),
        style: theme.textTheme.labelSmall?.copyWith(
          color: theme.colorScheme.primary,
          letterSpacing: 0.8,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

/// Renders the master Imperial / Metric switch + a per-category list,
/// modeled on the Strelok / Ballistics Calculator units page.
///
/// The master switch sets every category at once. The per-category
/// segmented buttons let advanced users mix systems (e.g. metric for
/// range but imperial for bullet weight). Changing the master switch
/// resets all per-category overrides.
class _UnitsSection extends StatelessWidget {
  const _UnitsSection({required this.units});

  final UnitService units;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Master switch.
          SegmentedButton<UnitSystem>(
            segments: const [
              ButtonSegment(
                value: UnitSystem.imperial,
                label: Text('Use Imperial'),
              ),
              ButtonSegment(
                value: UnitSystem.metric,
                label: Text('Use Metric'),
              ),
            ],
            selected: {units.system},
            onSelectionChanged: (s) {
              // ignore: discarded_futures
              units.setSystem(s.first);
            },
            showSelectedIcon: false,
          ),
          const SizedBox(height: 8),
          Text(
            'Pick your default. You can fine-tune individual measurements below.',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 16),
          for (final cat in UnitCategory.values) ...[
            _UnitCategoryRow(units: units, category: cat),
            const SizedBox(height: 10),
          ],
        ],
      ),
    );
  }
}

/// One row inside the Units section: the category title on top, a
/// horizontally-scrolling segmented button below.
class _UnitCategoryRow extends StatelessWidget {
  const _UnitCategoryRow({required this.units, required this.category});

  final UnitService units;
  final UnitCategory category;

  @override
  Widget build(BuildContext context) {
    final options = kUnitOptions[category] ?? const <String>[];
    final current = units.unitFor(category);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          unitCategoryLabel(category),
          style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                fontWeight: FontWeight.w500,
              ),
        ),
        const SizedBox(height: 6),
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: SegmentedButton<String>(
            segments: [
              for (final u in options)
                ButtonSegment(value: u, label: Text(unitDisplayLabel(u))),
            ],
            selected: {current},
            onSelectionChanged: (s) {
              // ignore: discarded_futures
              units.setOverride(category, s.first);
            },
            showSelectedIcon: false,
          ),
        ),
      ],
    );
  }
}

/// Settings list-tile that opens a bottom-sheet picker for the UI
/// language. The tile's trailing label reflects the current selection
/// (or "System default" when no override is set).
class _LanguageTile extends StatelessWidget {
  const _LanguageTile({
    required this.localeService,
    required this.title,
    required this.subtitle,
    required this.systemDefaultLabel,
  });

  final LocaleService localeService;
  final String title;
  final String subtitle;
  final String systemDefaultLabel;

  @override
  Widget build(BuildContext context) {
    final code = localeService.languageCode;
    final currentLabel = code == null
        ? systemDefaultLabel
        : kLanguageDisplayNames[code] ?? code;
    return ListTile(
      leading: const Icon(Icons.language_outlined),
      title: Text(title),
      subtitle: Text(subtitle),
      trailing: Text(
        currentLabel,
        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
      ),
      onTap: () => _openPicker(context),
    );
  }

  Future<void> _openPicker(BuildContext context) async {
    final selected = await showModalBottomSheet<_LanguagePickerResult>(
      context: context,
      builder: (ctx) => _LanguagePickerSheet(
        currentCode: localeService.languageCode,
        systemDefaultLabel: systemDefaultLabel,
      ),
    );
    if (selected == null) return;
    // ignore: discarded_futures
    localeService.setLanguageCode(selected.code);
  }
}

class _LanguagePickerSheet extends StatelessWidget {
  const _LanguagePickerSheet({
    required this.currentCode,
    required this.systemDefaultLabel,
  });

  final String? currentCode;
  final String systemDefaultLabel;

  @override
  Widget build(BuildContext context) {
    final rows = <_LanguagePickerRowData>[
      _LanguagePickerRowData(code: null, label: systemDefaultLabel),
      for (final code in kSupportedLanguageCodes)
        _LanguagePickerRowData(
          code: code,
          label: kLanguageDisplayNames[code] ?? code,
        ),
    ];
    return SafeArea(
      child: ListView(
        shrinkWrap: true,
        children: [
          for (final row in rows)
            ListTile(
              leading: Icon(
                row.code == currentCode
                    ? Icons.radio_button_checked
                    : Icons.radio_button_unchecked,
                color: row.code == currentCode
                    ? Theme.of(context).colorScheme.primary
                    : null,
              ),
              title: Text(row.label),
              onTap: () => Navigator.of(context).pop(
                _LanguagePickerResult(row.code),
              ),
            ),
        ],
      ),
    );
  }
}

class _LanguagePickerRowData {
  const _LanguagePickerRowData({required this.code, required this.label});
  final String? code;
  final String label;
}

class _LanguagePickerResult {
  const _LanguagePickerResult(this.code);
  final String? code;
}

/// Settings list-tile for the auto-save frequency. The trailing label
/// reflects the current selection ("Off" / "After Any Change" / etc.)
/// and tapping the row opens a single-choice modal sheet of the five
/// [AutoSaveFrequency] values.
class _AutoSaveFrequencyTile extends StatelessWidget {
  const _AutoSaveFrequencyTile({required this.service});

  final AutoSaveService service;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: const Icon(Icons.bolt_outlined),
      title: const Text('Auto-save frequency'),
      subtitle: Text(
        'Your edits save ${_frequencySubtitleSuffix(service.frequency)}.',
      ),
      trailing: Text(
        service.frequency.label,
        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
      ),
      onTap: () => _openFrequencyPicker(context),
    );
  }

  static String _frequencySubtitleSuffix(AutoSaveFrequency f) {
    switch (f) {
      case AutoSaveFrequency.off:
        return 'only when you tap Done / Save';
      case AutoSaveFrequency.onChange:
        return 'a couple seconds after each change';
      case AutoSaveFrequency.every1min:
        return 'every minute while there are changes';
      case AutoSaveFrequency.every5min:
        return 'every 5 minutes while there are changes';
      case AutoSaveFrequency.every10min:
        return 'every 10 minutes while there are changes';
    }
  }

  Future<void> _openFrequencyPicker(BuildContext context) async {
    final selected = await showModalBottomSheet<AutoSaveFrequency>(
      context: context,
      builder: (ctx) => _SingleChoiceSheet<AutoSaveFrequency>(
        title: 'Auto-save frequency',
        values: AutoSaveFrequency.values,
        labelOf: (v) => v.label,
        current: service.frequency,
      ),
    );
    if (selected == null) return;
    // ignore: discarded_futures
    service.setFrequency(selected);
  }
}

/// Settings list-tile for what to do when the user pops the form
/// with unsaved changes pending. Same pattern as
/// [_AutoSaveFrequencyTile].
class _UnsavedChangesPolicyTile extends StatelessWidget {
  const _UnsavedChangesPolicyTile({required this.service});

  final AutoSaveService service;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: const Icon(Icons.exit_to_app_outlined),
      title: const Text('When you leave without saving'),
      subtitle: const Text(
        'Choose what happens to pending edits when you back out of '
        'a form before the next auto-save fires.',
      ),
      trailing: Text(
        service.unsavedChangesPolicy.label,
        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
      ),
      onTap: () => _openPolicyPicker(context),
    );
  }

  Future<void> _openPolicyPicker(BuildContext context) async {
    final selected = await showModalBottomSheet<UnsavedChangesPolicy>(
      context: context,
      builder: (ctx) => _SingleChoiceSheet<UnsavedChangesPolicy>(
        title: 'When you leave without saving',
        values: UnsavedChangesPolicy.values,
        labelOf: (v) => v.label,
        current: service.unsavedChangesPolicy,
      ),
    );
    if (selected == null) return;
    // ignore: discarded_futures
    service.setUnsavedChangesPolicy(selected);
  }
}

/// Small reusable single-choice sheet. One radio-style row per
/// value; tapping pops the sheet with the selected value, the parent
/// persists it to its service.
class _SingleChoiceSheet<T> extends StatelessWidget {
  const _SingleChoiceSheet({
    required this.title,
    required this.values,
    required this.labelOf,
    required this.current,
  });

  final String title;
  final List<T> values;
  final String Function(T) labelOf;
  final T current;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
            child: Text(
              title,
              style: Theme.of(context).textTheme.titleMedium,
            ),
          ),
          for (final v in values)
            ListTile(
              leading: Icon(
                v == current
                    ? Icons.radio_button_checked
                    : Icons.radio_button_unchecked,
                color: v == current
                    ? Theme.of(context).colorScheme.primary
                    : null,
              ),
              title: Text(labelOf(v)),
              onTap: () => Navigator.of(context).pop(v),
            ),
          const SizedBox(height: 8),
        ],
      ),
    );
  }
}

/// VFP Phase 3 — visual tier picker tile. Three-segment
/// `SegmentedButton<VisualStyle>` with labels (Stylized / Scenic /
/// Photographic) plus helper text below explaining what each does.
///
/// Mirrors the layout pattern used by [_UnitsSection]'s master
/// switch — segmented control inside a Padding-wrapped Column with
/// optional explanatory text underneath. Writes go through
/// [VisualStyleNotifier.setStyle] (which persists +
/// notifies). Reads from the watched service so the Range Day
/// AppBar's compact toggle stays in sync — both surfaces see the
/// same `style` getter and rebuild on any change.
class _VisualStyleTile extends StatelessWidget {
  const _VisualStyleTile({required this.service});

  final VisualStyleNotifier service;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SegmentedButton<VisualStyle>(
            segments: const [
              ButtonSegment<VisualStyle>(
                value: VisualStyle.stylized,
                label: Text('Stylized'),
                icon: Icon(Icons.auto_awesome_outlined),
              ),
              ButtonSegment<VisualStyle>(
                value: VisualStyle.scenic,
                label: Text('Scenic'),
                icon: Icon(Icons.landscape_outlined),
              ),
              ButtonSegment<VisualStyle>(
                value: VisualStyle.photographic,
                label: Text('Photographic'),
                icon: Icon(Icons.photo_camera_outlined),
              ),
            ],
            selected: {service.style},
            showSelectedIcon: false,
            onSelectionChanged: (sel) {
              // Fire-and-forget persistence — notifier writes
              // synchronously to its in-memory cache before
              // notifying listeners, so the UI updates before the
              // SharedPrefs round-trip.
              // ignore: discarded_futures
              service.setStyle(sel.first);
            },
          ),
          const SizedBox(height: 8),
          Text(
            'Stylized is the default — the procedural scene with '
            'atmospheric effects (subtle DOF, ground haze, drop '
            'shadow, warm color grade, vignette, film grain). Scenic '
            '(2.5D photo backdrop) and Photographic (full 3D) are '
            'upcoming higher tiers; until they ship they render the '
            'same as Stylized.',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}
