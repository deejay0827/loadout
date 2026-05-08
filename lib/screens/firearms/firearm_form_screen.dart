// FILE: lib/screens/firearms/firearm_form_screen.dart
//
// ============================================================================
// WHAT THIS FILE DOES
// ============================================================================
// The firearm create / edit form. Captures every column the
// `UserFirearms` Drift table exposes — name, manufacturer, model, type,
// action, caliber, barrel length, twist rate, round count, optional
// link to a reference firearm, and free-form notes.
//
// The form opens with a `SegmentedButton<bool>` toggle that controls how
// the manufacturer / model / type / action fields are entered:
//
// * "Pick from Catalog" mode (`_useCatalog = true`) renders a
//   `DropdownButtonFormField<_RefEntry>` populated from
//   `ComponentRepository.allReferenceFirearms()`. Picking a row from the
//   catalog calls `_applyReferenceSelection`, which:
//     - records the row's id in `_referenceFirearmId` so it persists on
//       save,
//     - copies manufacturer / model / type / action into the read-only
//       display tiles,
//     - resets the caliber field if the previously-typed value isn't in
//       the reference firearm's caliber list, and surfaces a nested
//       caliber dropdown limited to that firearm's supported calibers.
//
// * "Custom" mode (`_useCatalog = false`) replaces the catalog dropdown
//   with four free-form `TextFormField`s for manufacturer / model /
//   type / action — the path used for unusual builds, wildcatters, and
//   anything not in the bundled reference catalog.
//
// Below the toggle, common fields appear regardless of mode: caliber
// (via the shared `ComponentField` widget so the dropdown surfaces both
// reference and custom cartridges), barrel length, twist rate, the
// shots-fired stepper (a number field flanked by `+`/`-` filled-tonal
// IconButtons that bump the count by 1), and a multi-line notes field.
//
// On save (`_save`), a typed-in caliber that isn't in the
// `ComponentRepository.componentLabels('cartridge')` set is persisted as
// a `CustomComponent` so it appears in future dropdowns. Then a
// `UserFirearmsCompanion` is built and routed through
// `FirearmRepository.insert` (create) or `.update` (edit).
//
// ============================================================================
// WHY IT EXISTS IN THE ARCHITECTURE
// ============================================================================
// Reachable from `FirearmsListScreen` — both the FAB (create) and tile
// taps (edit). The mode toggle exists because LoadOut ships a curated
// reference catalog of common firearms (`FirearmsRef`), but no catalog
// can be exhaustive. Letting users link to a catalog row when one fits
// keeps their data normalised; letting them type a custom build avoids
// blocking entries that don't have a catalog match.
//
// ============================================================================
// WHY THIS IS HARDER THAN IT LOOKS
// ============================================================================
// The reference catalog dropdown carries a typed `_RefEntry` record
// (firearm row + manufacturer row + decoded calibers list) rather than
// a plain id. That was a deliberate ergonomic choice: the form needs
// the manufacturer name and the calibers list right after a selection,
// and joining all three at render time avoids per-selection async
// gymnastics. The `_refsFuture` is cached on `initState` so the
// dropdown can render synchronously the first time it's shown.
//
// The two-mode toggle has a subtle state-reset gotcha: switching from
// catalog to custom clears `_selectedRef` and `_referenceFirearmId`
// but does NOT clear the manufacturer / model / type / action text
// controllers, so the user can edit on top of a catalog auto-fill.
// Switching from custom to catalog leaves those text values alone too;
// they're only overwritten when an actual catalog row is picked.
//
// `_bumpShots` clamps the round count between 0 and `1 << 31` so a
// runaway tap can't overflow into a negative number, and the text
// validator rejects negatives. Round-count edits inside the form do
// not call `FirearmRepository.adjustShotsFired` — that's a separate
// path used by per-recipe shot logging. The form path overwrites the
// stored count outright.
//
// The "persist typed-in caliber as a custom cartridge" branch is
// asymmetric with the rest of the form: it writes to
// `CustomComponents` independently of the firearm save. If the user
// types a caliber, then changes their mind and types a different one,
// both end up in `CustomComponents` — that's harmless, just clutter
// in future dropdowns.
//
// ============================================================================
// WHO CONSUMES THIS FILE
// ============================================================================
// - `lib/screens/firearms/firearms_list_screen.dart` — pushes
//   `FirearmFormScreen()` via the FAB and
//   `FirearmFormScreen(existing: f)` via list-tile taps.
//
// ============================================================================
// SIDE EFFECTS
// ============================================================================
// - Reads `ComponentRepository.allReferenceFirearms()` for the catalog
//   dropdown.
// - Reads `ComponentRepository.componentLabels('cartridge')` to
//   determine whether the typed-in caliber needs to be persisted.
// - Calls `ComponentRepository.addCustomComponent('cartridge', ...)`
//   for unrecognised typed-in calibers.
// - Calls `FirearmRepository.insert` or `.update`.
// - Shows a confirmation `SnackBar` on save.
// - Pops the navigator on success.

import 'package:drift/drift.dart' as drift;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../database/database.dart';
import '../../repositories/component_repository.dart';
import '../../repositories/firearm_repository.dart';
import '../../repositories/optics_repository.dart';
import '../../repositories/reticle_repository.dart';
import '../../services/auto_save_service.dart';
import '../../services/cloud_sync_service.dart';
import '../../services/unit_service.dart';
import '../../services/weather_service.dart';
import '../../utils/responsive.dart';
import '../../widgets/auto_save_banner.dart';
import '../../widgets/auto_save_first_time_hint.dart';
import '../../widgets/component_field.dart';
import '../../widgets/reticle_picker.dart';

typedef _RefEntry = ({
  FirearmRefRow firearm,
  ManufacturerRow manufacturer,
  List<String> calibers,
});

class FirearmFormScreen extends StatefulWidget {
  const FirearmFormScreen({super.key, this.existing});

  final UserFirearmRow? existing;

  @override
  State<FirearmFormScreen> createState() => _FirearmFormScreenState();
}

class _FirearmFormScreenState extends State<FirearmFormScreen> {
  final _formKey = GlobalKey<FormState>();

  late final TextEditingController _name;
  late final TextEditingController _manufacturer;
  late final TextEditingController _model;
  late final TextEditingController _type;
  late final TextEditingController _action;
  late final TextEditingController _caliber;
  late final TextEditingController _barrelLength;
  late final TextEditingController _twistRate;
  late final TextEditingController _shotsFired;
  late final TextEditingController _notes;
  // Ballistics defaults — pre-fill the ballistics calculator from this firearm.
  late final TextEditingController _defaultMuzzleVelocityFps;
  late final TextEditingController _defaultZeroRangeYd;
  late final TextEditingController _sightHeightIn;

  // ── v15 ballistic precision inputs ──
  // Twist direction defaults to right-twist — the overwhelming majority
  // of factory rifling spins right-handed (clockwise viewed from the
  // breech). 'left' option exists for the small slice of rifles
  // (Savage 12 LRPV varmint, some custom barrels) that don't.
  // Drives the spin-drift sign in the ballistics solver — left-twist
  // rifles drift left at long range instead of right.
  String _twistDirection = 'right';
  // Sight scale factors — most scopes don't track exactly to their
  // advertised mil/MOA values. A 1.000 default means "no correction".
  late final TextEditingController _sightScaleVertical;
  late final TextEditingController _sightScaleHorizontal;
  // Zero atmosphere — the conditions present when the user sighted in.
  // Future ballistics solves use these as the baseline so that today's
  // weather correction is computed relative to zero-day conditions, not
  // to the ICAO standard atmosphere.
  late final TextEditingController _zeroPressureInHg;
  late final TextEditingController _zeroTemperatureF;
  late final TextEditingController _zeroHumidityPct;

  // True iff a "Capture from current weather" pull is in flight.
  bool _zeroWeatherFetching = false;

  // New firearms default to "Pick from Catalog" because most users own
  // a catalog-listed production rifle/pistol. The Custom path is a
  // power-user fallback. For edits we honor whatever the row was
  // saved as (catalog if `referenceFirearmId` was set, custom otherwise).
  bool _useCatalog = true;
  bool _busy = false;

  Future<List<_RefEntry>>? _refsFuture;
  _RefEntry? _selectedRef;
  int? _referenceFirearmId;

  // Optics dropdown state. The dropdown only sets `_opticsId`; sight
  // height stays a separate user-edited field because it depends on
  // rings/mount, not the optic.
  Future<List<OpticEntry>>? _opticsFuture;
  OpticEntry? _selectedOptic;
  int? _opticsId;

  // Reticle picker state. Picked reticle persists on the firearm
  // (`UserFirearms.reticleId`) so the user-installed reticle takes
  // precedence over the optic's catalog default. When the user picks
  // a fresh optic and the saved reticleId hasn't been set yet, we
  // pre-fill from `Optics.reticleId` if the catalog declares one.
  ReticleRow? _selectedReticle;
  int? _reticleId;
  bool _autoFilledReticleFromOptic = false;

  late final AutoSaveController _autoSave;

  @override
  void initState() {
    super.initState();
    final e = widget.existing;
    _name = TextEditingController(text: e?.name ?? '');
    _manufacturer = TextEditingController(text: e?.manufacturer ?? '');
    _model = TextEditingController(text: e?.model ?? '');
    _type = TextEditingController(text: e?.type ?? '');
    _action = TextEditingController(text: e?.action ?? '');
    _caliber = TextEditingController(text: e?.caliber ?? '');
    _barrelLength =
        TextEditingController(text: e?.barrelLengthIn?.toString() ?? '');
    _twistRate = TextEditingController(text: e?.twistRate ?? '');
    _shotsFired = TextEditingController(text: (e?.shotsFired ?? 0).toString());
    _notes = TextEditingController(text: e?.notes ?? '');
    _defaultMuzzleVelocityFps = TextEditingController(
      text: e?.defaultMuzzleVelocityFps?.toString() ?? '',
    );
    _defaultZeroRangeYd = TextEditingController(
      // 100 yd is the de-facto reloader default zero range. Pre-fill
      // it so users don't have to think about it; they can still
      // change it (200 / 25 / etc.) before saving.
      text: (e?.defaultZeroRangeYd ?? 100).toString(),
    );
    _sightHeightIn = TextEditingController(
      text: e?.sightHeightIn?.toString() ?? '',
    );
    // ── v15 ballistic precision inputs ──
    // `twistDirection`, `sightScaleVertical`, `sightScaleHorizontal`
    // all carry schema defaults (right / 1.0 / 1.0). Zero-atmosphere
    // fields are nullable — the form shows blank when null so the
    // user knows they haven't been recorded yet.
    _twistDirection = e?.twistDirection ?? 'right';
    _sightScaleVertical = TextEditingController(
      // Hide the literal "1.0" baseline so the empty field reads as
      // "no correction" — the user only types here when they have
      // a measured tracking error.
      text: (e?.sightScaleVertical == null || e!.sightScaleVertical == 1.0)
          ? ''
          : e.sightScaleVertical.toStringAsFixed(3),
    );
    _sightScaleHorizontal = TextEditingController(
      text:
          (e?.sightScaleHorizontal == null || e!.sightScaleHorizontal == 1.0)
              ? ''
              : e.sightScaleHorizontal.toStringAsFixed(3),
    );
    _zeroPressureInHg = TextEditingController(
      text: e?.zeroPressureInHg?.toStringAsFixed(2) ?? '',
    );
    _zeroTemperatureF = TextEditingController(
      text: e?.zeroTemperatureF?.toStringAsFixed(0) ?? '',
    );
    _zeroHumidityPct = TextEditingController(
      text: e?.zeroHumidityPct?.toStringAsFixed(0) ?? '',
    );
    _referenceFirearmId = e?.referenceFirearmId;
    // For new firearms (e == null) keep the catalog default. For edits,
    // mirror whatever the row was saved as.
    _useCatalog = e == null ? true : (_referenceFirearmId != null);
    _refsFuture =
        context.read<ComponentRepository>().allReferenceFirearms();
    _opticsId = e?.opticsId;
    _opticsFuture = context.read<OpticsRepository>().allOptics();
    _reticleId = e?.reticleId;
    _loadInitialReticle();

    _autoSave = AutoSaveController(
      service: context.read<AutoSaveService>(),
      onSave: _runAutoSave,
      initialSavedRowId: widget.existing?.id,
      // Cloud Sync hook — no-op when sync is disabled / non-Pro.
      onSavedToCloud: () =>
          context.read<CloudSyncService>().scheduleSyncUp(),
    );

    // Wire every text controller to autosave so any keystroke marks
    // the form dirty and restarts the debounce timer.
    for (final c in [
      _name,
      _manufacturer,
      _model,
      _type,
      _action,
      _caliber,
      _barrelLength,
      _twistRate,
      _shotsFired,
      _notes,
      _defaultMuzzleVelocityFps,
      _defaultZeroRangeYd,
      _sightHeightIn,
      _sightScaleVertical,
      _sightScaleHorizontal,
      _zeroPressureInHg,
      _zeroTemperatureF,
      _zeroHumidityPct,
    ]) {
      c.addListener(_autoSave.notifyDirty);
    }
  }

  /// Resolve the saved `reticleId` (if any) into a `ReticleRow` so the
  /// picker can render the preview with the correct reticle pre-filled.
  /// For new firearms, this is a no-op until the user picks an optic
  /// that has a default reticle.
  Future<void> _loadInitialReticle() async {
    if (_reticleId == null) return;
    final repo = context.read<ReticleRepository>();
    final row = await repo.byId(_reticleId!);
    if (!mounted) return;
    setState(() => _selectedReticle = row);
  }

  /// When the user picks a different optic, try to pre-fill the
  /// reticle from that optic's catalog default — but only if the user
  /// hasn't already explicitly chosen a reticle for this firearm.
  Future<void> _maybeAutoFillReticleFromOptic(int? opticsId) async {
    if (opticsId == null) return;
    if (_reticleId != null && !_autoFilledReticleFromOptic) return;
    final repo = context.read<ReticleRepository>();
    final row = await repo.byOptic(opticsId);
    if (row == null || !mounted) return;
    setState(() {
      _selectedReticle = row;
      _reticleId = row.id;
      _autoFilledReticleFromOptic = true;
    });
    _autoSave.notifyDirty();
  }

  /// Builds a `UserFirearmsCompanion` from the current form state and
  /// inserts (first save) or updates (subsequent saves) via
  /// [FirearmRepository]. Returns the row id for the controller to
  /// remember, or null if the form is invalid (e.g. blank name).
  Future<int?> _runAutoSave() async {
    final name = _name.text.trim();
    if (name.isEmpty) return null;
    final repo = context.read<FirearmRepository>();
    final entry = _buildCompanion();
    final existingId = _autoSave.currentRowId;
    if (existingId == null) {
      return repo.insert(entry);
    }
    await repo.update(existingId, entry);
    return existingId;
  }

  String? _nullIfEmpty(TextEditingController c) {
    final t = c.text.trim();
    return t.isEmpty ? null : t;
  }

  /// Common path used by both autosave and the manual Save button so
  /// they emit the same row shape.
  UserFirearmsCompanion _buildCompanion() {
    return UserFirearmsCompanion(
      name: drift.Value(_name.text.trim()),
      manufacturer: drift.Value(_nullIfEmpty(_manufacturer)),
      model: drift.Value(_nullIfEmpty(_model)),
      type: drift.Value(_nullIfEmpty(_type)),
      action: drift.Value(_nullIfEmpty(_action)),
      caliber: drift.Value(_nullIfEmpty(_caliber)),
      barrelLengthIn: drift.Value(_parseDouble(_barrelLength)),
      twistRate: drift.Value(_nullIfEmpty(_twistRate)),
      shotsFired: drift.Value(_parseShots()),
      referenceFirearmId:
          drift.Value(_useCatalog ? _referenceFirearmId : null),
      notes: drift.Value(_nullIfEmpty(_notes)),
      defaultMuzzleVelocityFps:
          drift.Value(_parseDouble(_defaultMuzzleVelocityFps)),
      defaultZeroRangeYd: drift.Value(_parseInt(_defaultZeroRangeYd)),
      sightHeightIn: drift.Value(_parseDouble(_sightHeightIn)),
      opticsId: drift.Value(_opticsId),
      reticleId: drift.Value(_reticleId),
      // ── v15 ballistic precision inputs ──
      twistDirection: drift.Value(_twistDirection),
      // Sight scales fall back to 1.0 (no correction) when blank.
      sightScaleVertical:
          drift.Value(_parseDouble(_sightScaleVertical) ?? 1.0),
      sightScaleHorizontal:
          drift.Value(_parseDouble(_sightScaleHorizontal) ?? 1.0),
      zeroPressureInHg: drift.Value(_parseDouble(_zeroPressureInHg)),
      zeroTemperatureF: drift.Value(_parseDouble(_zeroTemperatureF)),
      zeroHumidityPct: drift.Value(_parseDouble(_zeroHumidityPct)),
    );
  }

  @override
  void dispose() {
    _autoSave.dispose();
    for (final c in [
      _name,
      _manufacturer,
      _model,
      _type,
      _action,
      _caliber,
      _barrelLength,
      _twistRate,
      _shotsFired,
      _notes,
      _defaultMuzzleVelocityFps,
      _defaultZeroRangeYd,
      _sightHeightIn,
      _sightScaleVertical,
      _sightScaleHorizontal,
      _zeroPressureInHg,
      _zeroTemperatureF,
      _zeroHumidityPct,
    ]) {
      c.dispose();
    }
    super.dispose();
  }

  double? _parseDouble(TextEditingController c) {
    final t = c.text.trim();
    if (t.isEmpty) return null;
    return double.tryParse(t);
  }

  int? _parseInt(TextEditingController c) {
    final t = c.text.trim();
    if (t.isEmpty) return null;
    return int.tryParse(t);
  }

  int _parseShots() {
    final v = int.tryParse(_shotsFired.text.trim()) ?? 0;
    return v < 0 ? 0 : v;
  }

  void _bumpShots(int delta) {
    final next = (_parseShots() + delta).clamp(0, 1 << 31);
    setState(() => _shotsFired.text = next.toString());
    _autoSave.notifyDirty();
  }

  void _applyReferenceSelection(_RefEntry ref) {
    setState(() {
      _selectedRef = ref;
      _referenceFirearmId = ref.firearm.id;
      _manufacturer.text = ref.manufacturer.name;
      _model.text = ref.firearm.model;
      _type.text = ref.firearm.type;
      _action.text = ref.firearm.action ?? '';
      // Auto-fill the main Caliber field if the user hasn't typed one
      // that's already in this firearm's caliber list. Use the first
      // catalog caliber as the sensible default — the user can edit
      // the main Caliber field freely. (Multi-caliber rifles like
      // a Tikka T3x with several factory chamberings still resolve
      // cleanly: first caliber wins, user re-types if they own a
      // different one.)
      if (_caliber.text.trim().isEmpty ||
          !ref.calibers.contains(_caliber.text.trim())) {
        if (ref.calibers.isNotEmpty) {
          _caliber.text = ref.calibers.first;
        }
      }
      // Auto-fill barrel length and twist rate from the catalog row, but
      // ONLY when the user hasn't already typed something. This way a
      // re-selection of the same model can't clobber a custom value
      // (a 16" SBR variant of a 20" catalog spec, a re-barreled rifle
      // with a non-standard twist, etc.).
      final refBarrel = ref.firearm.barrelLengthIn;
      if (_barrelLength.text.trim().isEmpty && refBarrel != null) {
        _barrelLength.text = refBarrel.toString();
      }
      final refTwist = ref.firearm.twistRate;
      if (_twistRate.text.trim().isEmpty &&
          refTwist != null &&
          refTwist.isNotEmpty) {
        _twistRate.text = refTwist;
      }
    });
    _autoSave.notifyDirty();
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() => _busy = true);

    final repo = context.read<FirearmRepository>();
    final components = context.read<ComponentRepository>();
    final messenger = ScaffoldMessenger.of(context);
    final navigator = Navigator.of(context);

    // Persist a typed-in caliber as a custom cartridge so it appears in
    // future dropdowns.
    final caliberText = _caliber.text.trim();
    if (caliberText.isNotEmpty) {
      final known = await components.componentLabels('cartridge');
      if (!known.contains(caliberText)) {
        await components.addCustomComponent('cartridge', caliberText);
      }
    }

    final entry = _buildCompanion();
    final existingId = _autoSave.currentRowId;

    if (existingId == null) {
      await repo.insert(entry);
      messenger.showSnackBar(const SnackBar(content: Text('Firearm saved.')));
    } else {
      await repo.update(existingId, entry);
      messenger
          .showSnackBar(const SnackBar(content: Text('Firearm updated.')));
    }

    if (mounted) navigator.pop();
  }

  @override
  Widget build(BuildContext context) {
    final isEdit = widget.existing != null;
    final autoSaveOn = context.watch<AutoSaveService>().isEnabled;
    return PopScope(
      canPop: true,
      onPopInvokedWithResult: (didPop, _) async {
        // Make sure any in-flight edits are committed before the
        // screen is gone. flush() is a no-op when autosave is off.
        await _autoSave.flush();
      },
      child: Scaffold(
        appBar: AppBar(title: Text(isEdit ? 'Edit Firearm' : 'New Firearm')),
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
                      TextFormField(
                        controller: _name,
                        decoration: const InputDecoration(labelText: 'Name *'),
                        validator: (v) =>
                            (v == null || v.trim().isEmpty) ? 'Required' : null,
                      ),
                      const SizedBox(height: 16),
                      SegmentedButton<bool>(
                        segments: const [
                          ButtonSegment(
                              value: true, label: Text('Pick from Catalog')),
                          ButtonSegment(value: false, label: Text('Custom')),
                        ],
                        selected: {_useCatalog},
                        onSelectionChanged: (s) {
                          setState(() {
                            _useCatalog = s.first;
                            if (!_useCatalog) {
                              _selectedRef = null;
                              _referenceFirearmId = null;
                            }
                          });
                          _autoSave.notifyDirty();
                        },
                      ),
                      const SizedBox(height: 16),
                      if (_useCatalog)
                        ..._catalogFields()
                      else
                        ..._customFields(),
                      const SizedBox(height: 12),
                      ComponentField(
                        kind: 'cartridge',
                        label: 'Caliber',
                        controller: _caliber,
                      ),
                      const SizedBox(height: 12),
                      // On wide layouts pair barrel length + twist rate
                      // (both short numeric fields) into a single row so
                      // the form doesn't waste horizontal real estate.
                      // Phone keeps the original stacked layout.
                      //
                      // Barrel length displays in the user's chosen
                      // smallLength unit (in / cm); the persisted column
                      // stays canonical inches. Twist rate is a text
                      // string (e.g. "1:8") and has no unit suffix.
                      Builder(builder: (ctx) {
                        final smallLen = unitDisplayLabel(ctx
                            .watch<UnitService>()
                            .unitFor(UnitCategory.smallLength));
                        return _ResponsiveRowPair(
                          first: TextFormField(
                            controller: _barrelLength,
                            decoration: InputDecoration(
                              labelText: 'Barrel Length ($smallLen)',
                              suffixText: smallLen,
                            ),
                            keyboardType:
                                const TextInputType.numberWithOptions(
                              decimal: true,
                            ),
                          ),
                          // Twist rate row: text field + Right/Left
                          // direction segmented button so the user
                          // declares which way the rifling spins. Right
                          // is the overwhelming default; left-twist
                          // exists on a few specialty rifles and flips
                          // the spin-drift sign at long range.
                          second: _twistRow(),
                        );
                      }),
                      const SizedBox(height: 16),
                      _shotsFiredField(context),
                      const SizedBox(height: 16),
                      _opticsSection(context),
                      const SizedBox(height: 16),
                      _ballisticsDefaultsSection(context),
                      const SizedBox(height: 12),
                      TextFormField(
                        controller: _notes,
                        decoration: const InputDecoration(labelText: 'Notes'),
                        maxLines: 4,
                      ),
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

  /// When autosave is on, the trailing button is just a "Done" — the
  /// data has already saved as the user typed. Off, it stays the
  /// traditional "Save Changes" / "Create Firearm" CTA.
  String _finalButtonLabel(bool autoSaveOn, bool isEdit) {
    if (autoSaveOn) return 'Done';
    return isEdit ? 'Save Changes' : 'Create Firearm';
  }

  List<Widget> _catalogFields() {
    return [
      FutureBuilder<List<_RefEntry>>(
        future: _refsFuture,
        builder: (context, snap) {
          if (snap.connectionState == ConnectionState.waiting) {
            return const Padding(
              padding: EdgeInsets.symmetric(vertical: 8),
              child: LinearProgressIndicator(),
            );
          }
          final refs = snap.data ?? const <_RefEntry>[];
          if (refs.isEmpty) {
            return const Text(
              'No reference firearms in the catalog. Switch to Custom.',
            );
          }
          // Initialise selected ref from existing referenceFirearmId.
          if (_selectedRef == null && _referenceFirearmId != null) {
            for (final r in refs) {
              if (r.firearm.id == _referenceFirearmId) {
                _selectedRef = r;
                break;
              }
            }
          }
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              DropdownButtonFormField<_RefEntry>(
                initialValue: _selectedRef,
                isExpanded: true,
                decoration:
                    const InputDecoration(labelText: 'Model from Catalog'),
                items: [
                  for (final r in refs)
                    DropdownMenuItem(
                      value: r,
                      child: Text(
                        '${r.manufacturer.name} ${r.firearm.model}',
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                ],
                onChanged: (r) {
                  if (r != null) _applyReferenceSelection(r);
                },
                validator: (v) => v == null ? 'Pick a model' : null,
              ),
              const SizedBox(height: 12),
              if (_selectedRef != null) ...[
                _readOnlyTile('Manufacturer', _selectedRef!.manufacturer.name),
                _readOnlyTile('Model', _selectedRef!.firearm.model),
                _readOnlyTile('Type', _selectedRef!.firearm.type),
                if ((_selectedRef!.firearm.action ?? '').isNotEmpty)
                  _readOnlyTile('Action', _selectedRef!.firearm.action!),
                // No inline "Caliber for This Firearm" dropdown — the
                // catalog selection auto-fills the main Caliber field
                // below (`_applyReferenceSelection`), and that field is
                // freely editable so multi-chambering owners can swap
                // to whatever they actually shoot.
              ],
            ],
          );
        },
      ),
    ];
  }

  List<Widget> _customFields() {
    return [
      TextFormField(
        controller: _manufacturer,
        decoration: const InputDecoration(labelText: 'Manufacturer'),
      ),
      const SizedBox(height: 12),
      TextFormField(
        controller: _model,
        decoration: const InputDecoration(labelText: 'Model'),
      ),
      const SizedBox(height: 12),
      TextFormField(
        controller: _type,
        decoration: const InputDecoration(
          labelText: 'Type',
          hintText: 'pistol / rifle / shotgun',
        ),
      ),
      const SizedBox(height: 12),
      TextFormField(
        controller: _action,
        decoration: const InputDecoration(
          labelText: 'Action',
          hintText: 'e.g. bolt-action, semi-auto',
        ),
      ),
    ];
  }

  Widget _readOnlyTile(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          SizedBox(
            width: 110,
            child: Text(
              label,
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
          Expanded(child: Text(value)),
        ],
      ),
    );
  }

  /// Twist rate text field with a Right/Left direction segmented button
  /// to its right. Persists the direction in `_twistDirection` (defaults
  /// to 'right'). Used in the main barrel-spec row.
  Widget _twistRow() {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Expanded(
          child: TextFormField(
            controller: _twistRate,
            decoration: const InputDecoration(
              labelText: 'Twist Rate',
              hintText: 'e.g. 1:8',
            ),
          ),
        ),
        const SizedBox(width: 8),
        // Compact segmented button — single-letter labels keep the row
        // narrow enough to fit on a phone next to the twist text field.
        SegmentedButton<String>(
          showSelectedIcon: false,
          style: SegmentedButton.styleFrom(
            visualDensity: VisualDensity.compact,
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 0),
            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          ),
          segments: const [
            ButtonSegment<String>(
              value: 'right',
              label: Text('R'),
              tooltip: 'Right-hand twist (clockwise from breech)',
            ),
            ButtonSegment<String>(
              value: 'left',
              label: Text('L'),
              tooltip: 'Left-hand twist (counter-clockwise from breech)',
            ),
          ],
          selected: {_twistDirection},
          onSelectionChanged: (s) {
            setState(() => _twistDirection = s.first);
            _autoSave.notifyDirty();
          },
        ),
      ],
    );
  }

  Widget _shotsFiredField(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Expanded(
          child: TextFormField(
            controller: _shotsFired,
            decoration: const InputDecoration(labelText: 'Shots Fired'),
            keyboardType: TextInputType.number,
            inputFormatters: [FilteringTextInputFormatter.digitsOnly],
            validator: (v) {
              if (v == null || v.trim().isEmpty) return null;
              final n = int.tryParse(v.trim());
              if (n == null || n < 0) return 'Must be a positive integer';
              return null;
            },
            onChanged: (_) => setState(() {}),
          ),
        ),
        const SizedBox(width: 8),
        IconButton.filledTonal(
          onPressed: () => _bumpShots(-1),
          icon: const Icon(Icons.remove),
          tooltip: 'Decrement',
        ),
        const SizedBox(width: 4),
        IconButton.filledTonal(
          onPressed: () => _bumpShots(1),
          icon: const Icon(Icons.add),
          tooltip: 'Increment',
        ),
      ],
    );
  }

  /// Optics dropdown — lets the user record which scope/red-dot is mounted
  /// on this firearm. The selection only sets `opticsId`; sight height
  /// stays a separate user-edited field on the ballistics defaults card
  /// because it depends on the rings/mount, not the optic itself.
  Widget _opticsSection(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      margin: EdgeInsets.zero,
      clipBehavior: Clip.antiAlias,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.visibility_outlined,
                    size: 16, color: theme.colorScheme.primary),
                const SizedBox(width: 6),
                Text(
                  'Optics',
                  style: theme.textTheme.labelLarge?.copyWith(
                    color: theme.colorScheme.primary,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              'Optional. Pick the scope or red dot mounted on this firearm. '
              'Sight height (centerline above bore) is on the Ballistics '
              'defaults card below — it depends on your rings/mount, not '
              'the optic.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 12),
            FutureBuilder<List<OpticEntry>>(
              future: _opticsFuture,
              builder: (context, snap) {
                if (snap.connectionState == ConnectionState.waiting) {
                  return const Padding(
                    padding: EdgeInsets.symmetric(vertical: 8),
                    child: LinearProgressIndicator(),
                  );
                }
                final optics = snap.data ?? const <OpticEntry>[];
                if (optics.isEmpty) {
                  return const Text(
                    'No optics in the catalog. Reinstall to re-seed reference '
                    'data, or skip this field.',
                  );
                }
                // Resolve the saved opticsId to the current entry once the
                // future has loaded (mirrors the catalog dropdown pattern).
                if (_selectedOptic == null && _opticsId != null) {
                  for (final o in optics) {
                    if (o.optic.id == _opticsId) {
                      _selectedOptic = o;
                      break;
                    }
                  }
                }
                return DropdownButtonFormField<OpticEntry?>(
                  initialValue: _selectedOptic,
                  isExpanded: true,
                  decoration: const InputDecoration(
                    labelText: 'Mounted Optic',
                    helperText:
                        'Select "None" if no optic, or pick your scope.',
                  ),
                  items: <DropdownMenuItem<OpticEntry?>>[
                    const DropdownMenuItem<OpticEntry?>(
                      value: null,
                      child: Text('None / iron sights'),
                    ),
                    for (final o in optics)
                      DropdownMenuItem<OpticEntry?>(
                        value: o,
                        child: Text(
                          '${o.manufacturer.name} ${o.optic.model}',
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                  ],
                  onChanged: (o) {
                    setState(() {
                      _selectedOptic = o;
                      _opticsId = o?.optic.id;
                    });
                    _autoSave.notifyDirty();
                    // When the user picks a new optic, try to pre-fill
                    // the reticle from the catalog default — but only
                    // if the user hasn't already explicitly chosen a
                    // reticle (so we don't clobber a deliberate pick).
                    if (o != null) {
                      _maybeAutoFillReticleFromOptic(o.optic.id);
                    }
                  },
                );
              },
            ),
            const SizedBox(height: 16),
            // Reticle picker — let the user choose the reticle in the
            // mounted scope. This persists separately from the optic
            // because users can swap reticles after purchase, and
            // because catalog scopes typically ship with several
            // reticle options.
            ReticlePickerField(
              label: 'Reticle',
              selected: _selectedReticle,
              restrictToOpticId: _opticsId,
              onChanged: (row) {
                setState(() {
                  _selectedReticle = row;
                  _reticleId = row?.id;
                  // Once the user explicitly picks a reticle, stop
                  // auto-filling on subsequent optic changes.
                  _autoFilledReticleFromOptic = false;
                });
                _autoSave.notifyDirty();
              },
            ),
            const SizedBox(height: 4),
            // Optic accuracy expansion — vertical / horizontal scale
            // factors. Hidden behind an ExpansionTile so beginners
            // aren't confronted with two scale-factor numbers; long-
            // range shooters open it once after a tracking test.
            _opticAccuracyTile(context),
          ],
        ),
      ),
    );
  }

  /// Optic accuracy section — vertical / horizontal scale factors that
  /// correct for scopes whose tracking does not match the advertised
  /// mil/MOA increments. 1.000 = no correction. Hidden by default.
  Widget _opticAccuracyTile(BuildContext context) {
    final theme = Theme.of(context);
    return Theme(
      // The default M3 ExpansionTile draws a divider line that clashes
      // with the parent Card. Strip it.
      data: theme.copyWith(dividerColor: Colors.transparent),
      child: ExpansionTile(
        tilePadding: EdgeInsets.zero,
        childrenPadding: const EdgeInsets.only(top: 4, bottom: 4),
        leading: Icon(
          Icons.tune,
          size: 18,
          color: theme.colorScheme.primary,
        ),
        title: Text(
          'Optic accuracy (advanced)',
          style: theme.textTheme.labelLarge?.copyWith(
            color: theme.colorScheme.primary,
            fontWeight: FontWeight.w600,
          ),
        ),
        subtitle: Text(
          'Most scopes don\'t track exactly to their advertised increments. '
          'Test by dialing 10 mil up at distance and measuring actual '
          'point-of-impact shift; ratio is your scale factor. Default 1.0 '
          '= no correction.',
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        children: [
          _ResponsiveRowPair(
            first: TextFormField(
              controller: _sightScaleVertical,
              decoration: const InputDecoration(
                labelText: 'Vertical scale',
                hintText: '1.000',
                helperText: '1.000 = exact; 0.950 = scope tracks 5% short',
                helperMaxLines: 2,
              ),
              keyboardType:
                  const TextInputType.numberWithOptions(decimal: true),
              validator: (v) {
                final t = (v ?? '').trim();
                if (t.isEmpty) return null;
                final n = double.tryParse(t);
                if (n == null || n <= 0) return 'Must be positive';
                if (n < 0.5 || n > 2.0) return 'Typical 0.9-1.1';
                return null;
              },
            ),
            second: TextFormField(
              controller: _sightScaleHorizontal,
              decoration: const InputDecoration(
                labelText: 'Horizontal scale',
                hintText: '1.000',
                helperText: '1.000 = exact tracking',
                helperMaxLines: 2,
              ),
              keyboardType:
                  const TextInputType.numberWithOptions(decimal: true),
              validator: (v) {
                final t = (v ?? '').trim();
                if (t.isEmpty) return null;
                final n = double.tryParse(t);
                if (n == null || n <= 0) return 'Must be positive';
                if (n < 0.5 || n > 2.0) return 'Typical 0.9-1.1';
                return null;
              },
            ),
          ),
        ],
      ),
    );
  }

  /// Optional ballistics defaults block. Three nullable fields that the
  /// ballistics calculator's rifle picker can pre-fill once the user picks
  /// this firearm. Wrapped in a small card so the section reads as a
  /// distinct grouping rather than just three loose inputs.
  ///
  /// Unit suffixes (`fps`/`m·s`, `yd`/`m`, `in`/`cm`) are display-only
  /// — the persisted columns stay canonical imperial. The values typed
  /// here are interpreted as canonical imperial too: the ballistics
  /// calculator does its own display↔canonical conversion when it loads
  /// these defaults, so the firearm form needs only to label the inputs
  /// in the user's chosen units.
  Widget _ballisticsDefaultsSection(BuildContext context) {
    final theme = Theme.of(context);
    final units = context.watch<UnitService>();
    final velUnit = unitDisplayLabel(units.unitFor(UnitCategory.velocity));
    final rangeUnit = unitDisplayLabel(units.unitFor(UnitCategory.range));
    final smallLen = unitDisplayLabel(units.unitFor(UnitCategory.smallLength));
    return Card(
      margin: EdgeInsets.zero,
      clipBehavior: Clip.antiAlias,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.gps_fixed_outlined,
                    size: 16, color: theme.colorScheme.primary),
                const SizedBox(width: 6),
                Text(
                  'Ballistics defaults',
                  style: theme.textTheme.labelLarge?.copyWith(
                    color: theme.colorScheme.primary,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              'Optional. Pre-fills the ballistics calculator when this '
              'firearm is selected.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 12),
            _ResponsiveRowPair(
              first: TextFormField(
                controller: _defaultMuzzleVelocityFps,
                decoration: InputDecoration(
                  labelText: 'Default Muzzle Velocity ($velUnit)',
                  helperText: 'Last measured / preferred MV',
                  suffixText: velUnit,
                ),
                keyboardType:
                    const TextInputType.numberWithOptions(decimal: true),
                autocorrect: false,
                enableSuggestions: false,
                validator: (v) {
                  final t = (v ?? '').trim();
                  if (t.isEmpty) return null;
                  final n = double.tryParse(t);
                  if (n == null || n <= 0) {
                    return 'Must be a positive number';
                  }
                  return null;
                },
              ),
              second: TextFormField(
                controller: _defaultZeroRangeYd,
                decoration: InputDecoration(
                  labelText: 'Default Zero Range ($rangeUnit)',
                  helperText: 'Typical: 100-200 $rangeUnit',
                  suffixText: rangeUnit,
                ),
                keyboardType: TextInputType.number,
                inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                autocorrect: false,
                enableSuggestions: false,
                validator: (v) {
                  final t = (v ?? '').trim();
                  if (t.isEmpty) return null;
                  final n = int.tryParse(t);
                  if (n == null || n <= 0) {
                    return 'Must be a positive integer';
                  }
                  return null;
                },
              ),
            ),
            const SizedBox(height: 12),
            TextFormField(
              controller: _sightHeightIn,
              decoration: InputDecoration(
                labelText: 'Sight Height ($smallLen)',
                helperText:
                    'Center of optic above bore axis, typically 1.5–2.0 $smallLen',
                suffixText: smallLen,
              ),
              keyboardType:
                  const TextInputType.numberWithOptions(decimal: true),
              autocorrect: false,
              enableSuggestions: false,
              validator: (v) {
                final t = (v ?? '').trim();
                if (t.isEmpty) return null;
                final n = double.tryParse(t);
                if (n == null || n <= 0) {
                  return 'Must be a positive number';
                }
                return null;
              },
            ),
            const SizedBox(height: 4),
            // Zero conditions expansion. The atmosphere active when the
            // user sighted in. Future ballistics solves use these as
            // the baseline so today's correction is computed relative
            // to zero-day conditions, not to the ICAO standard
            // atmosphere.
            _zeroConditionsTile(context),
          ],
        ),
      ),
    );
  }

  /// Zero conditions section — pressure, temperature, humidity at the
  /// time of sight-in. Used by the ballistics solver as the reference
  /// atmosphere when computing today's correction. Collapsed by
  /// default; surface a "Capture from current weather" button at the
  /// end so users can pull the values automatically when zeroing.
  Widget _zeroConditionsTile(BuildContext context) {
    final theme = Theme.of(context);
    return Theme(
      data: theme.copyWith(dividerColor: Colors.transparent),
      child: ExpansionTile(
        tilePadding: EdgeInsets.zero,
        childrenPadding: const EdgeInsets.only(top: 4, bottom: 4),
        leading: Icon(
          Icons.thermostat_outlined,
          size: 18,
          color: theme.colorScheme.primary,
        ),
        title: Text(
          'Zero conditions',
          style: theme.textTheme.labelLarge?.copyWith(
            color: theme.colorScheme.primary,
            fontWeight: FontWeight.w600,
          ),
        ),
        subtitle: Text(
          'The atmosphere where you sighted in. Future ballistics solves '
          'use these as the baseline so today\'s correction is computed '
          'relative to zero-day, not to the ICAO standard atmosphere.',
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        children: [
          _ResponsiveRowPair(
            first: TextFormField(
              controller: _zeroPressureInHg,
              decoration: const InputDecoration(
                labelText: 'Pressure (inHg)',
                hintText: 'e.g. 29.92',
                helperText: 'Local station pressure that day',
                suffixText: 'inHg',
                helperMaxLines: 2,
              ),
              keyboardType:
                  const TextInputType.numberWithOptions(decimal: true),
              validator: (v) {
                final t = (v ?? '').trim();
                if (t.isEmpty) return null;
                final n = double.tryParse(t);
                if (n == null || n <= 0) return 'Must be positive';
                if (n < 18 || n > 32) return 'Typical 22-31 inHg';
                return null;
              },
            ),
            second: TextFormField(
              controller: _zeroTemperatureF,
              decoration: const InputDecoration(
                labelText: 'Temperature (°F)',
                hintText: 'e.g. 65',
                suffixText: '°F',
              ),
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
                signed: true,
              ),
              validator: (v) {
                final t = (v ?? '').trim();
                if (t.isEmpty) return null;
                final n = double.tryParse(t);
                if (n == null) return 'Must be a number';
                if (n < -40 || n > 140) return 'Out of plausible range';
                return null;
              },
            ),
          ),
          const SizedBox(height: 12),
          TextFormField(
            controller: _zeroHumidityPct,
            decoration: const InputDecoration(
              labelText: 'Humidity (%)',
              hintText: 'e.g. 50',
              suffixText: '%',
            ),
            keyboardType:
                const TextInputType.numberWithOptions(decimal: true),
            validator: (v) {
              final t = (v ?? '').trim();
              if (t.isEmpty) return null;
              final n = double.tryParse(t);
              if (n == null || n < 0 || n > 100) return 'Must be 0-100';
              return null;
            },
          ),
          const SizedBox(height: 12),
          // Capture from current weather button — pulls the user's
          // local pressure / temp / humidity via the existing
          // open-meteo handshake and writes them into the three
          // fields above.
          Align(
            alignment: Alignment.centerLeft,
            child: OutlinedButton.icon(
              onPressed:
                  _zeroWeatherFetching ? null : _captureZeroFromWeather,
              icon: _zeroWeatherFetching
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.cloud_outlined, size: 18),
              label: const Text('Capture from current weather'),
            ),
          ),
        ],
      ),
    );
  }

  /// Pull the current weather and copy the pressure / temp / humidity
  /// into the Zero Conditions fields. Surfaces a snackbar with the
  /// captured values so the user sees what's happening rather than
  /// the fields silently filling. Failures show a friendly message.
  Future<void> _captureZeroFromWeather() async {
    if (!mounted) return;
    setState(() => _zeroWeatherFetching = true);
    final messenger = ScaffoldMessenger.of(context);
    try {
      final result = await WeatherService().fetchForCurrentLocation();
      if (!mounted) return;
      setState(() {
        _zeroPressureInHg.text =
            result.stationPressureInHg.toStringAsFixed(2);
        _zeroTemperatureF.text = result.tempF.toStringAsFixed(0);
        _zeroHumidityPct.text = result.humidityPct.toStringAsFixed(0);
      });
      _autoSave.notifyDirty();
      messenger.showSnackBar(
        SnackBar(
          duration: const Duration(seconds: 5),
          content: Text(
            '✓ Captured zero conditions  ·  '
            '${result.stationPressureInHg.toStringAsFixed(2)} inHg  ·  '
            '${result.tempF.toStringAsFixed(0)}°F  ·  '
            '${result.humidityPct.toStringAsFixed(0)}% RH',
          ),
        ),
      );
    } on WeatherFetchException catch (e) {
      if (!mounted) return;
      messenger.showSnackBar(SnackBar(content: Text(e.userMessage)));
    } catch (_) {
      if (!mounted) return;
      messenger.showSnackBar(
        const SnackBar(
            content: Text('Couldn\'t fetch weather. Try again later.')),
      );
    } finally {
      if (mounted) setState(() => _zeroWeatherFetching = false);
    }
  }
}

/// Lays two form fields side by side on tablet/desktop widths and
/// stacks them vertically on phones. Saves us from peppering every
/// pair of inputs with the same `LayoutBuilder` boilerplate.
class _ResponsiveRowPair extends StatelessWidget {
  const _ResponsiveRowPair({required this.first, required this.second});

  final Widget first;
  final Widget second;

  @override
  Widget build(BuildContext context) {
    if (Breakpoints.isPhone(context)) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          first,
          const SizedBox(height: 12),
          second,
        ],
      );
    }
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(child: first),
        const SizedBox(width: 16),
        Expanded(child: second),
      ],
    );
  }
}
