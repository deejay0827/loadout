// FILE: lib/screens/atmosphere/atmosphere_presets_screen.dart
//
// ============================================================================
// WHAT THIS FILE DOES
// ============================================================================
// Manage Presets screen for the atmosphere library. Reachable from:
//   * The "Manage presets" item in the Environment-section atmosphere
//     picker on `BallisticsScreen` and `RangeDayDetailScreen`.
//   * Settings → App preferences → "Atmosphere presets".
//
// Renders a list of `AtmospherePresetRow`s, each with:
//   * Title — the preset's name.
//   * Subtitle — a `<pressure inHg> · <tempF°F> · <humidity% RH>` summary.
//   * Trailing chevron + `Dismissible` swipe-to-delete with confirm.
//
// FAB pushes [AtmospherePresetFormScreen] for new entries; tapping a
// row pushes it pre-populated for edit.
//
// ============================================================================
// WHY IT EXISTS IN THE ARCHITECTURE
// ============================================================================
// the "Applied Ballistics" methodology calls for the shooter to
// keep a small library of named atmosphere profiles ("Camp Atterbury
// summer", "Big Sandy match", "Cold dry day") so they can switch between
// known sets of conditions in two taps rather than re-typing four
// numeric fields. This screen owns the lifecycle of that library.
//
// The same drift table backs this screen, the inline pickers on the
// Ballistics + Range Day environment cards, and the "save current
// conditions as a preset" dialog wired to the Pull Weather / Capture
// from sensors buttons.

import 'package:drift/drift.dart' as drift;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../database/database.dart';
import '../../repositories/atmosphere_preset_repository.dart';

/// Top-level Manage Presets screen. Renders a live list of saved
/// atmosphere profiles, plus a FAB that opens the form for a new one.
class AtmospherePresetsScreen extends StatelessWidget {
  const AtmospherePresetsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final repo = context.read<AtmospherePresetRepository>();
    return Scaffold(
      appBar: AppBar(title: const Text('Atmosphere Presets')),
      body: StreamBuilder<List<AtmospherePresetRow>>(
        stream: repo.watchAll(),
        builder: (context, snap) {
          if (snap.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          }
          final presets = snap.data ?? const <AtmospherePresetRow>[];
          if (presets.isEmpty) {
            return const _EmptyState();
          }
          return ListView.separated(
            itemCount: presets.length,
            separatorBuilder: (_, _) => const Divider(height: 1),
            itemBuilder: (context, i) {
              final p = presets[i];
              return _AtmospherePresetTile(
                preset: p,
                onTap: () {
                  Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) =>
                          AtmospherePresetFormScreen(existing: p),
                    ),
                  );
                },
                onDismissed: () async {
                  await repo.delete(p.id);
                },
              );
            },
          );
        },
      ),
      floatingActionButton: FloatingActionButton(
        heroTag: 'atmosphere_presets_fab',
        onPressed: () => Navigator.of(context).push(
          MaterialPageRoute(
            builder: (_) => const AtmospherePresetFormScreen(),
          ),
        ),
        child: const Icon(Icons.add),
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState();

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
              Icons.cloud_outlined,
              size: 56,
              color: theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.6),
            ),
            const SizedBox(height: 12),
            Text(
              'No atmosphere presets yet.\n'
              'Save the conditions you shoot in most often so you can switch '
              'between them in one tap.',
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

class _AtmospherePresetTile extends StatelessWidget {
  const _AtmospherePresetTile({
    required this.preset,
    required this.onTap,
    required this.onDismissed,
  });

  final AtmospherePresetRow preset;
  final VoidCallback onTap;
  final VoidCallback onDismissed;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final subtitle = formatPresetSummary(preset);
    return Dismissible(
      key: ValueKey('atmosphere_preset_${preset.id}'),
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
                title: const Text('Delete this preset?'),
                content: Text('"${preset.name}" will be removed.'),
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
        title: Text(preset.name),
        subtitle: Text(subtitle),
        trailing: const Icon(Icons.chevron_right),
        onTap: onTap,
      ),
    );
  }
}

/// Format the four core atmosphere fields into a one-line summary string
/// suitable for use in list-tile subtitles. Public because the inline
/// pickers on the Ballistics + Range Day screens use the same string.
String formatPresetSummary(AtmospherePresetRow p) {
  final parts = <String>[
    '${p.stationPressureInHg.toStringAsFixed(2)} inHg',
    '${p.temperatureF.toStringAsFixed(0)}°F',
    '${p.humidityPct.toStringAsFixed(0)}% RH',
  ];
  if (p.altitudeFt != null) {
    parts.add('${p.altitudeFt!.toStringAsFixed(0)} ft');
  }
  return parts.join(' · ');
}

// ─────────────────────── Form screen ───────────────────────

/// Edit / create form for a single [AtmospherePresetRow]. When [existing]
/// is null, "Save" inserts a new row; otherwise it updates by id.
class AtmospherePresetFormScreen extends StatefulWidget {
  const AtmospherePresetFormScreen({super.key, this.existing});

  /// Pass the existing row to edit, or null to create a new preset.
  final AtmospherePresetRow? existing;

  @override
  State<AtmospherePresetFormScreen> createState() =>
      _AtmospherePresetFormScreenState();
}

class _AtmospherePresetFormScreenState
    extends State<AtmospherePresetFormScreen> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _nameCtrl;
  late final TextEditingController _pressureCtrl;
  late final TextEditingController _tempCtrl;
  late final TextEditingController _humidityCtrl;
  late final TextEditingController _altitudeCtrl;
  late final TextEditingController _latCtrl;
  late final TextEditingController _lonCtrl;
  late final TextEditingController _notesCtrl;

  bool _saving = false;

  @override
  void initState() {
    super.initState();
    final e = widget.existing;
    _nameCtrl = TextEditingController(text: e?.name ?? '');
    _pressureCtrl = TextEditingController(
        text: e == null ? '' : e.stationPressureInHg.toStringAsFixed(2));
    _tempCtrl = TextEditingController(
        text: e == null ? '' : e.temperatureF.toStringAsFixed(0));
    _humidityCtrl = TextEditingController(
        text: e == null ? '' : e.humidityPct.toStringAsFixed(0));
    _altitudeCtrl = TextEditingController(
        text: e?.altitudeFt == null ? '' : e!.altitudeFt!.toStringAsFixed(0));
    _latCtrl = TextEditingController(
        text: e?.latitudeDeg == null ? '' : e!.latitudeDeg!.toStringAsFixed(4));
    _lonCtrl = TextEditingController(
        text:
            e?.longitudeDeg == null ? '' : e!.longitudeDeg!.toStringAsFixed(4));
    _notesCtrl = TextEditingController(text: e?.notes ?? '');
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    _pressureCtrl.dispose();
    _tempCtrl.dispose();
    _humidityCtrl.dispose();
    _altitudeCtrl.dispose();
    _latCtrl.dispose();
    _lonCtrl.dispose();
    _notesCtrl.dispose();
    super.dispose();
  }

  Future<void> _onSave() async {
    if (!_formKey.currentState!.validate()) return;
    final repo = context.read<AtmospherePresetRepository>();
    final messenger = ScaffoldMessenger.of(context);
    final navigator = Navigator.of(context);
    setState(() => _saving = true);
    try {
      final altitudeText = _altitudeCtrl.text.trim();
      final latText = _latCtrl.text.trim();
      final lonText = _lonCtrl.text.trim();
      final notesText = _notesCtrl.text.trim();
      if (widget.existing == null) {
        await repo.insert(
          AtmospherePresetsCompanion.insert(
            name: _nameCtrl.text.trim(),
            stationPressureInHg: double.parse(_pressureCtrl.text.trim()),
            temperatureF: double.parse(_tempCtrl.text.trim()),
            humidityPct: double.parse(_humidityCtrl.text.trim()),
            altitudeFt: altitudeText.isEmpty
                ? const drift.Value.absent()
                : drift.Value(double.parse(altitudeText)),
            latitudeDeg: latText.isEmpty
                ? const drift.Value.absent()
                : drift.Value(double.parse(latText)),
            longitudeDeg: lonText.isEmpty
                ? const drift.Value.absent()
                : drift.Value(double.parse(lonText)),
            notes: notesText.isEmpty
                ? const drift.Value.absent()
                : drift.Value(notesText),
          ),
        );
      } else {
        await repo.update(
          widget.existing!.id,
          AtmospherePresetsCompanion(
            name: drift.Value(_nameCtrl.text.trim()),
            stationPressureInHg:
                drift.Value(double.parse(_pressureCtrl.text.trim())),
            temperatureF: drift.Value(double.parse(_tempCtrl.text.trim())),
            humidityPct: drift.Value(double.parse(_humidityCtrl.text.trim())),
            altitudeFt: drift.Value(
                altitudeText.isEmpty ? null : double.parse(altitudeText)),
            latitudeDeg:
                drift.Value(latText.isEmpty ? null : double.parse(latText)),
            longitudeDeg:
                drift.Value(lonText.isEmpty ? null : double.parse(lonText)),
            notes: drift.Value(notesText.isEmpty ? null : notesText),
          ),
        );
      }
      if (!mounted) return;
      navigator.pop();
    } catch (e) {
      if (!mounted) return;
      messenger.showSnackBar(
        SnackBar(content: Text('Failed to save: $e')),
      );
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final isEdit = widget.existing != null;
    return Scaffold(
      appBar: AppBar(
        title: Text(isEdit ? 'Edit preset' : 'New preset'),
        actions: [
          if (isEdit)
            IconButton(
              tooltip: 'Delete',
              icon: const Icon(Icons.delete_outline),
              onPressed: _saving ? null : _onDeletePressed,
            ),
        ],
      ),
      body: Form(
        key: _formKey,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 96),
          children: [
            TextFormField(
              controller: _nameCtrl,
              decoration: const InputDecoration(
                labelText: 'Name',
                helperText:
                    'E.g. "Camp Atterbury summer" or "Cold dry day".',
              ),
              textInputAction: TextInputAction.next,
              validator: (v) {
                if (v == null || v.trim().isEmpty) return 'Required';
                return null;
              },
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(
                  child: TextFormField(
                    controller: _pressureCtrl,
                    keyboardType: const TextInputType.numberWithOptions(
                        decimal: true),
                    inputFormatters: _decimalOnly,
                    decoration: const InputDecoration(
                      labelText: 'Station pressure (inHg)',
                      helperText: 'Not sea-level',
                    ),
                    validator: _requiredDouble,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: TextFormField(
                    controller: _tempCtrl,
                    keyboardType: const TextInputType.numberWithOptions(
                        decimal: true, signed: true),
                    inputFormatters: _signedDecimalOnly,
                    decoration: const InputDecoration(
                      labelText: 'Temperature (°F)',
                    ),
                    validator: _requiredDouble,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(
                  child: TextFormField(
                    controller: _humidityCtrl,
                    keyboardType: const TextInputType.numberWithOptions(
                        decimal: true),
                    inputFormatters: _decimalOnly,
                    decoration: const InputDecoration(
                      labelText: 'Humidity (%)',
                    ),
                    validator: _requiredDouble,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: TextFormField(
                    controller: _altitudeCtrl,
                    keyboardType: const TextInputType.numberWithOptions(
                        decimal: true, signed: true),
                    inputFormatters: _signedDecimalOnly,
                    decoration: const InputDecoration(
                      labelText: 'Altitude (ft)',
                      helperText: 'Optional',
                    ),
                    validator: _optionalDouble,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(
                  child: TextFormField(
                    controller: _latCtrl,
                    keyboardType: const TextInputType.numberWithOptions(
                        decimal: true, signed: true),
                    inputFormatters: _signedDecimalOnly,
                    decoration: const InputDecoration(
                      labelText: 'Latitude',
                      helperText: 'Optional',
                    ),
                    validator: _optionalDouble,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: TextFormField(
                    controller: _lonCtrl,
                    keyboardType: const TextInputType.numberWithOptions(
                        decimal: true, signed: true),
                    inputFormatters: _signedDecimalOnly,
                    decoration: const InputDecoration(
                      labelText: 'Longitude',
                      helperText: 'Optional',
                    ),
                    validator: _optionalDouble,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            TextFormField(
              controller: _notesCtrl,
              minLines: 2,
              maxLines: 5,
              decoration: const InputDecoration(
                labelText: 'Notes',
                helperText:
                    'Optional. Where the preset was captured, time of '
                    'day, conditions, etc.',
              ),
            ),
            const SizedBox(height: 24),
            FilledButton.icon(
              onPressed: _saving ? null : _onSave,
              icon: _saving
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.save_outlined),
              label: Text(isEdit ? 'Save changes' : 'Save preset'),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _onDeletePressed() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Delete this preset?'),
        content: Text('"${widget.existing!.name}" will be removed.'),
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
    if (confirmed != true) return;
    if (!mounted) return;
    final repo = context.read<AtmospherePresetRepository>();
    final navigator = Navigator.of(context);
    await repo.delete(widget.existing!.id);
    if (!mounted) return;
    navigator.pop();
  }

  static String? _requiredDouble(String? v) {
    if (v == null || v.trim().isEmpty) return 'Required';
    final n = double.tryParse(v.trim());
    if (n == null) return 'Invalid number';
    return null;
  }

  static String? _optionalDouble(String? v) {
    if (v == null || v.trim().isEmpty) return null;
    final n = double.tryParse(v.trim());
    if (n == null) return 'Invalid number';
    return null;
  }

  static final _decimalOnly = <TextInputFormatter>[
    FilteringTextInputFormatter.allow(RegExp(r'[0-9.]')),
  ];
  static final _signedDecimalOnly = <TextInputFormatter>[
    FilteringTextInputFormatter.allow(RegExp(r'[0-9.\-]')),
  ];
}

// ─────────────────────── Save-as-preset dialog ───────────────────────

/// Inline dialog launched from the "Save as preset" button on the
/// Ballistics + Range Day environment cards, and from the "Save these
/// conditions as a preset?" snackbar action that follows a successful
/// weather pull or sensor capture. Pre-populates the four core fields
/// (and the optional ones, if provided) so the user just types a name.
///
/// Returns the new preset's id on success, or null if the user
/// cancelled.
Future<int?> showSaveAtmospherePresetDialog(
  BuildContext context, {
  required double stationPressureInHg,
  required double temperatureF,
  required double humidityPct,
  double? altitudeFt,
  double? latitudeDeg,
  double? longitudeDeg,
  String? defaultName,
}) async {
  return showDialog<int>(
    context: context,
    builder: (_) => _SaveAsPresetDialog(
      stationPressureInHg: stationPressureInHg,
      temperatureF: temperatureF,
      humidityPct: humidityPct,
      altitudeFt: altitudeFt,
      latitudeDeg: latitudeDeg,
      longitudeDeg: longitudeDeg,
      defaultName: defaultName,
    ),
  );
}

class _SaveAsPresetDialog extends StatefulWidget {
  const _SaveAsPresetDialog({
    required this.stationPressureInHg,
    required this.temperatureF,
    required this.humidityPct,
    this.altitudeFt,
    this.latitudeDeg,
    this.longitudeDeg,
    this.defaultName,
  });

  final double stationPressureInHg;
  final double temperatureF;
  final double humidityPct;
  final double? altitudeFt;
  final double? latitudeDeg;
  final double? longitudeDeg;
  final String? defaultName;

  @override
  State<_SaveAsPresetDialog> createState() => _SaveAsPresetDialogState();
}

class _SaveAsPresetDialogState extends State<_SaveAsPresetDialog> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _nameCtrl;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _nameCtrl = TextEditingController(text: widget.defaultName ?? '');
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    final repo = context.read<AtmospherePresetRepository>();
    final navigator = Navigator.of(context);
    setState(() => _saving = true);
    try {
      final id = await repo.insert(
        AtmospherePresetsCompanion.insert(
          name: _nameCtrl.text.trim(),
          stationPressureInHg: widget.stationPressureInHg,
          temperatureF: widget.temperatureF,
          humidityPct: widget.humidityPct,
          altitudeFt: widget.altitudeFt == null
              ? const drift.Value.absent()
              : drift.Value(widget.altitudeFt),
          latitudeDeg: widget.latitudeDeg == null
              ? const drift.Value.absent()
              : drift.Value(widget.latitudeDeg),
          longitudeDeg: widget.longitudeDeg == null
              ? const drift.Value.absent()
              : drift.Value(widget.longitudeDeg),
        ),
      );
      if (!mounted) return;
      navigator.pop(id);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('Failed to save: $e')));
      setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final summary = <String>[
      '${widget.stationPressureInHg.toStringAsFixed(2)} inHg',
      '${widget.temperatureF.toStringAsFixed(0)}°F',
      '${widget.humidityPct.toStringAsFixed(0)}% RH',
      if (widget.altitudeFt != null)
        '${widget.altitudeFt!.toStringAsFixed(0)} ft',
    ].join(' · ');
    return AlertDialog(
      title: const Text('Save as preset'),
      content: Form(
        key: _formKey,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              summary,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
            ),
            const SizedBox(height: 12),
            TextFormField(
              controller: _nameCtrl,
              autofocus: true,
              decoration: const InputDecoration(
                labelText: 'Name',
                helperText:
                    'E.g. "Camp Atterbury summer" or "Big Sandy".',
              ),
              validator: (v) {
                if (v == null || v.trim().isEmpty) return 'Required';
                return null;
              },
              onFieldSubmitted: (_) => _save(),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _saving ? null : () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _saving ? null : _save,
          child: _saving
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Text('Save'),
        ),
      ],
    );
  }
}
