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

import 'dart:convert';

import 'package:drift/drift.dart' as drift;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../database/database.dart';
import '../../repositories/component_repository.dart';
import '../../repositories/firearm_component_repository.dart';
import '../../repositories/firearm_repository.dart';
import '../../repositories/optics_repository.dart';
import '../../repositories/reticle_repository.dart';
import '../ballistics/ballistics_screen.dart';
import '../../services/auto_save_service.dart';
import '../../services/cloud_sync_service.dart';
import '../../services/entitlement_notifier.dart';
import '../../services/unit_service.dart';
import '../../services/weather_service.dart';
import '../../utils/responsive.dart';
import '../../widgets/auto_save_banner.dart';
import '../../widgets/auto_save_first_time_hint.dart';
import '../../widgets/component_field.dart';
import '../../widgets/pro_gate.dart';
import '../../widgets/reticle_picker.dart';

/// Per-caliber factory specs declared on a `FirearmsRef.caliberSpecsJson`
/// entry. Lets a multi-chambering rifle (Accuracy International AT-X
/// — 24" / 1:8 in 6.5 CM, 26" / 1:7.25 in 6mm CM, 16.5"+20" / 1:10 in
/// .308 Win) auto-update barrel length and twist when the user picks
/// a different chambering from the catalog row.
///
/// `barrelLengthsIn` carries one entry for single-barrel-length
/// chamberings and N entries when the manufacturer offers a choice
/// (sorted ascending — manufacturer literature reading order). The
/// form renders a dropdown when N > 1 and a single-value display
/// when N == 1.
class _CaliberSpec {
  const _CaliberSpec({
    required this.barrelLengthsIn,
    required this.twistRate,
  });

  final List<double> barrelLengthsIn;
  final String? twistRate;

  /// Decode one `caliberSpecsJson` map entry into a typed spec.
  /// Returns null when the JSON shape is unexpected (defensive: a
  /// malformed remote update shouldn't crash the form).
  static _CaliberSpec? fromJson(Map<String, dynamic> raw) {
    final lengthsRaw = raw['barrelLengthsIn'];
    if (lengthsRaw is! List) return null;
    final lengths = <double>[];
    for (final v in lengthsRaw) {
      if (v is num) lengths.add(v.toDouble());
    }
    if (lengths.isEmpty) return null;
    final twist = raw['twistRate'];
    return _CaliberSpec(
      barrelLengthsIn: lengths,
      twistRate: twist is String ? twist : null,
    );
  }
}

typedef _RefEntry = ({
  FirearmRefRow firearm,
  ManufacturerRow manufacturer,
  List<String> calibers,
});

/// Decode a `_RefEntry`'s `caliberSpecsJson` blob into a typed
/// `caliber → spec` map. Returns an empty map when the row predates
/// schema v34, when the JSON is empty `{}`, or when the JSON is
/// malformed (defensive — bad seed data shouldn't break the form).
Map<String, _CaliberSpec> _caliberSpecsFor(_RefEntry ref) {
  final raw = ref.firearm.caliberSpecsJson;
  if (raw.isEmpty || raw == '{}') return const <String, _CaliberSpec>{};
  try {
    final decoded = json.decode(raw);
    if (decoded is! Map) return const <String, _CaliberSpec>{};
    final out = <String, _CaliberSpec>{};
    for (final entry in decoded.entries) {
      final key = entry.key;
      final value = entry.value;
      if (key is! String || value is! Map) continue;
      final spec = _CaliberSpec.fromJson(value.cast<String, dynamic>());
      if (spec != null) out[key] = spec;
    }
    return out;
  } catch (_) {
    return const <String, _CaliberSpec>{};
  }
}

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
  // MV is INTENTIONALLY NOT a controller here — see the comment in the form
  // build method where the field used to render. The DB column stays and
  // existing rows preserve their saved value, but the firearm form no
  // longer surfaces an input for it.
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

  // Factory rifles always resolve through the catalog autocomplete
  // (2026-05-10 — the legacy "Pick from Catalog | Custom" inner
  // toggle was removed in favor of unconditional catalog binding).
  // Rows saved before that change with referenceFirearmId == null
  // and freeform manufacturer/model strings still load and save
  // correctly; the catalog picker just doesn't pre-select anything
  // for them. Users can either pick a catalog match for those
  // rifles or convert to Custom Build.
  bool _busy = false;

  Future<List<_RefEntry>>? _refsFuture;
  _RefEntry? _selectedRef;
  int? _referenceFirearmId;

  // ── Custom build mode (added schema v33) ──
  // When `_isCustomBuild` is true, the form swaps the "Pick from
  // Catalog | Custom" factory toggle for a "Components" panel listing
  // chassis / barrel / trigger / buttstock / muzzle brake / suppressor
  // / bipod autocomplete pickers. The selections write through to the
  // matching nullable text columns on `UserFirearms`. Build type is a
  // separate concept from `_useCatalog`: factory rifles can be either
  // catalog-picked or freeform-typed; custom builds are always built
  // from components and have no factory parent (we force
  // `referenceFirearmId = null` on save).
  bool _isCustomBuild = false;
  late final TextEditingController _chassisName;
  late final TextEditingController _barrelName;
  late final TextEditingController _triggerName;
  late final TextEditingController _buttstockName;
  late final TextEditingController _muzzleBrakeName;
  late final TextEditingController _suppressorName;
  late final TextEditingController _bipodName;

  // Manufactured-mode muzzle-device toggle (2026-05-10). A rifle has
  // EITHER a muzzle brake OR a suppressor installed at any given
  // moment — this picks which slot the user is editing right now.
  // Both `_muzzleBrakeName` and `_suppressorName` controllers always
  // exist and are written through on save; the toggle only changes
  // which one the form's component picker is bound to. Switching the
  // toggle does NOT clear the inactive controller — a user who had
  // a brake recorded, switches to suppressor mode, picks a can, then
  // toggles back will see their brake still there.
  //
  // initState picks the saved active side: if the row has a
  // suppressor name and no brake, default 'suppressor'; otherwise
  // 'brake' (the more common case).
  String _muzzleDevice = 'brake';
  // Cached corpus of every component the user might pick. Loaded once
  // on initState and shared across all seven autocomplete pickers
  // (each picker filters client-side by `kind`). The catalog is small
  // (≈220 rows at v33 launch) and never changes during a form
  // session, so re-querying drift on every keystroke would be wasted
  // work.
  Future<List<FirearmComponentEntry>>? _componentsFuture;

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
    // Shots-fired counter; not ballistics-affecting. Pre-fill with
    // 0 for new firearms; saved value on edit. Most users start a
    // new firearm at 0 rounds anyway and increment as they shoot.
    _shotsFired = TextEditingController(text: (e?.shotsFired ?? 0).toString());
    _notes = TextEditingController(text: e?.notes ?? '');
    // `_defaultMuzzleVelocityFps` controller intentionally absent — the
    // form no longer renders an MV input. Existing rows keep whatever
    // MV is on the DB column; the save block below uses
    // `Value.absent()` so the column is left untouched.
    _defaultZeroRangeYd = TextEditingController(
      // Yardage is the explicit exception in CLAUDE.md § 0 — pre-
      // fill with the de-facto reloader default (100 yd zero) so
      // users don't have to think about it; they can change it
      // (200 / 25 / etc.) before saving. On edit, shows the
      // saved value.
      text: (e?.defaultZeroRangeYd ?? 100).toString(),
    );
    _sightHeightIn = TextEditingController(
      text: e?.sightHeightIn?.toString() ?? (e == null ? '2.0' : ''),
    );
    // ── v15 ballistic precision inputs ──
    // `twistDirection`, `sightScaleVertical`, `sightScaleHorizontal`
    // all carry schema defaults (right / 1.0 / 1.0). Zero-atmosphere
    // fields are nullable — the form shows blank when null so the
    // user knows they haven't been recorded yet.
    _twistDirection = e?.twistDirection ?? 'right';
    // Scope tracking calibration pre-fills to 1.000 — the
    // mathematically neutral value meaning "no correction." Per
    // CLAUDE.md § 0 this is a named carve-out from the rifle
    // no-placeholder rule because the value is universal: every
    // scope IS 1.0 until the user runs the Scope Tracking Test
    // and finds otherwise. Edits mirror the saved value verbatim.
    _sightScaleVertical = TextEditingController(
      text: e?.sightScaleVertical.toStringAsFixed(3) ?? '1.000',
    );
    _sightScaleHorizontal = TextEditingController(
      text: e?.sightScaleHorizontal.toStringAsFixed(3) ?? '1.000',
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
    // Build type — default to factory for new firearms; mirror saved
    // value on edits. A custom-build row by definition has no factory
    // reference, so the migration's `withDefault(false)` matches
    // every existing row to "Factory Rifle" mode.
    _isCustomBuild = e?.isCustomBuild ?? false;
    _chassisName = TextEditingController(text: e?.chassisName ?? '');
    _barrelName = TextEditingController(text: e?.barrelName ?? '');
    // Trigger + muzzle brake default to "Factory" on new firearms so
    // the inline Factory chip is pre-selected in the Components
    // panel — the dominant case for a factory rifle is "stock
    // trigger, stock brake or thread protector". Existing firearms
    // (e != null) load whatever was saved on the row, including
    // empty (the user explicitly cleared it).
    _triggerName =
        TextEditingController(text: e?.triggerName ?? (e == null ? 'Factory' : ''));
    _buttstockName = TextEditingController(text: e?.buttstockName ?? '');
    _muzzleBrakeName = TextEditingController(
        text: e?.muzzleBrakeName ?? (e == null ? 'Factory' : ''));
    _suppressorName = TextEditingController(text: e?.suppressorName ?? '');
    _bipodName = TextEditingController(text: e?.bipodName ?? '');
    // Pick the muzzle-device toggle side based on what's saved on the
    // row: prefer 'suppressor' iff the suppressor field is non-empty
    // and the brake is empty; otherwise default to 'brake'.
    final brakeHasValue = (e?.muzzleBrakeName ?? '').trim().isNotEmpty;
    final suppHasValue = (e?.suppressorName ?? '').trim().isNotEmpty;
    _muzzleDevice = (suppHasValue && !brakeHasValue) ? 'suppressor' : 'brake';
    _refsFuture =
        context.read<ComponentRepository>().allReferenceFirearms();
    _componentsFuture =
        context.read<FirearmComponentRepository>().all();
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
      _defaultZeroRangeYd,
      _sightHeightIn,
      _sightScaleVertical,
      _sightScaleHorizontal,
      _zeroPressureInHg,
      _zeroTemperatureF,
      _zeroHumidityPct,
      _chassisName,
      _barrelName,
      _triggerName,
      _buttstockName,
      _muzzleBrakeName,
      _suppressorName,
      _bipodName,
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
    // Custom builds force `referenceFirearmId = null` — a custom
    // build by definition has no factory catalog parent. Factory
    // mode binds whatever the catalog autocomplete picked; a user
    // who hasn't picked anything yet (new firearm, blank
    // autocomplete) has `_referenceFirearmId == null`, which is
    // correct. The seven component-name fields are written through
    // in BOTH modes — a factory rifle with an Area 419 brake +
    // Atlas bipod records those alongside its catalog parent.
    final referenceId = _isCustomBuild ? null : _referenceFirearmId;
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
      referenceFirearmId: drift.Value(referenceId),
      notes: drift.Value(_nullIfEmpty(_notes)),
      // `defaultMuzzleVelocityFps` is intentionally `Value.absent()` —
      // the form no longer surfaces an MV input, so we leave whatever
      // is on the existing row untouched (insert paths get null,
      // update paths preserve any prior value). MV pre-fills from
      // ballistic profile / common load on Range Day; the firearm
      // doesn't carry it anymore.
      defaultMuzzleVelocityFps: const drift.Value.absent(),
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
      // ── v33 custom-build inputs ──
      isCustomBuild: drift.Value(_isCustomBuild),
      chassisName: drift.Value(_nullIfEmpty(_chassisName)),
      barrelName: drift.Value(_nullIfEmpty(_barrelName)),
      triggerName: drift.Value(_nullIfEmpty(_triggerName)),
      buttstockName: drift.Value(_nullIfEmpty(_buttstockName)),
      muzzleBrakeName: drift.Value(_nullIfEmpty(_muzzleBrakeName)),
      suppressorName: drift.Value(_nullIfEmpty(_suppressorName)),
      bipodName: drift.Value(_nullIfEmpty(_bipodName)),
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
      _defaultZeroRangeYd,
      _sightHeightIn,
      _sightScaleVertical,
      _sightScaleHorizontal,
      _zeroPressureInHg,
      _zeroTemperatureF,
      _zeroHumidityPct,
      _chassisName,
      _barrelName,
      _triggerName,
      _buttstockName,
      _muzzleBrakeName,
      _suppressorName,
      _bipodName,
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

  /// Format a barrel-length double for display in the field. Drop a
  /// trailing `.0` so an integer length displays as `"20"` rather
  /// than `"20.0"`, and keep one decimal place for half-inches like
  /// `"16.5"`. Mirrors `_formatTwist` in `ballistics_screen.dart`.
  String _formatBarrelLength(double v) {
    if (v == v.truncateToDouble()) return v.toStringAsFixed(0);
    final s = v.toString();
    return s.endsWith('.0') ? s.substring(0, s.length - 2) : s;
  }

  /// Re-apply the catalog's per-caliber spec (barrel length + twist)
  /// when the user picks a different chambering from the dropdown.
  /// Called from `_catalogCaliberSection`'s `onChanged` after the
  /// caliber controller is updated. Pure no-op when:
  ///
  ///   * no catalog rifle is selected (`_selectedRef == null`), or
  ///   * the picked caliber has no entry in `caliberSpecsJson`
  ///     (single-spec rifle, or pre-v34 catalog row).
  ///
  /// Crucially, this OVERWRITES whatever's currently in the barrel-
  /// length and twist-rate controllers — a user who picks 6.5 CM
  /// after the form auto-filled .308 specs needs to see the AT-X's
  /// 24" / 1:8 take over from the .308's 20" / 1:10. The "don't
  /// clobber user input" rule from `_applyReferenceSelection`
  /// doesn't apply here because the user's explicit caliber pick is
  /// itself a strong signal that they want the matching specs.
  void _applyCaliberSpec(_RefEntry ref, String caliber) {
    final spec = _caliberSpecsFor(ref)[caliber];
    if (spec == null) return;
    setState(() {
      _barrelLength.text = _formatBarrelLength(spec.barrelLengthsIn.first);
      if (spec.twistRate != null && spec.twistRate!.isNotEmpty) {
        _twistRate.text = spec.twistRate!;
      }
    });
    _autoSave.notifyDirty();
  }

  void _applyReferenceSelection(_RefEntry ref) {
    setState(() {
      _selectedRef = ref;
      _referenceFirearmId = ref.firearm.id;
      _manufacturer.text = ref.manufacturer.name;
      _model.text = ref.firearm.model;
      // Catalog stores type/action lowercase ("rifle", "semi-auto"); we
      // present them Title Case everywhere in the UI (CLAUDE.md § 0a).
      // Title-case at the seed boundary so the saved row also persists
      // the friendlier form, and the Custom-mode TextFormField (when
      // the user toggles modes) reads in matching case.
      _type.text = _titleCaseEnum(ref.firearm.type);
      _action.text = _titleCaseEnum(ref.firearm.action ?? '');
      // Catalog caliber: always default to the first chambering the
      // catalog row declares. When the catalog row lists more than
      // one (e.g. a Tikka T3x in 6.5 CM / .308 / .300 WSM) the
      // dropdown built inside `_catalogFields` lets the user switch;
      // when there's only one, we just write it through. The shared
      // `ComponentField` no longer renders in catalog mode, so this
      // controller value drives the saved row directly.
      if (ref.calibers.isNotEmpty) {
        final preferUserTyped = _caliber.text.trim().isNotEmpty &&
            ref.calibers.contains(_caliber.text.trim());
        if (!preferUserTyped) {
          _caliber.text = ref.calibers.first;
        }
      }
      // Auto-fill barrel length and twist rate from the catalog row.
      // Per-caliber specs (schema v34) take priority — a multi-
      // chambering rifle declares different barrel lengths and twist
      // rates per caliber, and the picked caliber's spec wins. When
      // a caliber spec exists, it OVERWRITES whatever was in the
      // controllers (the user has just declared "this is what I
      // own", and the catalog says ".308 AT-X is 1:10, not 1:8").
      // When no per-caliber spec is available we fall back to the
      // row-level `barrelLengthIn` / `twistRate` and only fill when
      // the user hasn't typed anything.
      final specs = _caliberSpecsFor(ref);
      final pickedCaliber = _caliber.text.trim();
      final caliberSpec = specs[pickedCaliber];
      if (caliberSpec != null) {
        // Use the FIRST barrel length offering for this caliber.
        // The form's barrel-length dropdown surfaces the rest.
        _barrelLength.text =
            _formatBarrelLength(caliberSpec.barrelLengthsIn.first);
        if (caliberSpec.twistRate != null && caliberSpec.twistRate!.isNotEmpty) {
          _twistRate.text = caliberSpec.twistRate!;
        }
      } else {
        final refBarrel = ref.firearm.barrelLengthIn;
        if (_barrelLength.text.trim().isEmpty && refBarrel != null) {
          _barrelLength.text = _formatBarrelLength(refBarrel);
        }
        final refTwist = ref.firearm.twistRate;
        if (_twistRate.text.trim().isEmpty &&
            refTwist != null &&
            refTwist.isNotEmpty) {
          _twistRate.text = refTwist;
        }
      }
      // Auto-fill the Name field with the catalog manufacturer +
      // model (+ caliber if known) — but only when the user hasn't
      // already typed their own name. A user who renamed it to
      // "Match Rifle" doesn't want their custom name overwritten
      // when they re-pick the same catalog row.
      _ensureName();
    });
    _autoSave.notifyDirty();
  }

  Future<void> _save() async {
    final saved = await _runSavePipeline();
    if (saved == null) return;
    if (mounted) Navigator.of(context).pop();
  }

  /// Save + immediately push the Ballistics screen so the user can
  /// compute a firing solution with the firearm they just configured.
  /// Wired to the "Ballistics" button in the side-by-side button row
  /// at the bottom of the form (2026-05-10 reorg).
  ///
  /// Behaviour:
  ///   * On validation failure: stays on the form (same as `_save`).
  ///   * On success: replaces the current route with BallisticsScreen
  ///     so back-navigating goes to wherever launched the firearm
  ///     form (firearms list, firearm detail, etc.) rather than
  ///     popping back into a stale form view.
  Future<void> _saveAndOpenBallistics() async {
    final navigator = Navigator.of(context);
    final saved = await _runSavePipeline();
    if (saved == null) return;
    if (!mounted) return;
    navigator.pushReplacement(
      MaterialPageRoute<void>(builder: (_) => const BallisticsScreen()),
    );
  }

  /// Common save pipeline shared by `_save` (Done button) and
  /// `_saveAndOpenBallistics` (Ballistics button). Returns the row id
  /// of the saved firearm on success, or null when validation failed
  /// (so the caller knows to stay on the form rather than navigate).
  Future<int?> _runSavePipeline() async {
    // Auto-fill the Name field if the user left it blank — see
    // `_generatedName` for the priority list. Has to happen BEFORE
    // form validation so the validator (which still rejects an
    // empty string as a defensive guard) sees the generated value.
    _ensureName();
    if (!_formKey.currentState!.validate()) return null;
    setState(() => _busy = true);

    final repo = context.read<FirearmRepository>();
    final components = context.read<ComponentRepository>();
    final messenger = ScaffoldMessenger.of(context);

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
    final int rowId;

    if (existingId == null) {
      rowId = await repo.insert(entry);
      messenger.showSnackBar(const SnackBar(content: Text('Firearm saved.')));
    } else {
      await repo.update(existingId, entry);
      rowId = existingId;
      messenger
          .showSnackBar(const SnackBar(content: Text('Firearm updated.')));
    }

    return rowId;
  }

  /// Compose a sensible default firearm name from whatever the user
  /// has filled in so far. Always returns a non-empty string — the
  /// fallbacks are deliberately generic so a user who saves a totally
  /// blank form still gets a row they can find and rename later.
  ///
  /// Order of preference:
  ///
  ///   * **Factory mode with manufacturer + model**
  ///     `"<Manufacturer> <Model>"` plus `" <Caliber>"` if filled
  ///     (e.g. `"Tikka T3x CTR 6.5 Creedmoor"`).
  ///   * **Factory mode with only caliber typed**
  ///     `"<Caliber> Rifle"` (e.g. `"6.5 Creedmoor Rifle"`).
  ///   * **Custom Build with chassis selected**
  ///     `"<Chassis>"` plus `" <Caliber>"` if filled
  ///     (e.g. `"MDT ACC Elite 6.5 Creedmoor"`).
  ///   * **Custom Build with only caliber**
  ///     `"<Caliber> Custom Build"`.
  ///   * **Last resort** `"Custom Rifle"` (Custom Build mode) or
  ///     `"Untitled Firearm"` (Factory mode with nothing filled).
  String _generatedName() {
    final caliber = _caliber.text.trim();
    if (_isCustomBuild) {
      final chassis = _chassisName.text.trim();
      if (chassis.isEmpty && caliber.isEmpty) return 'Custom Rifle';
      if (chassis.isEmpty) return '$caliber Custom Build';
      if (caliber.isEmpty) return chassis;
      return '$chassis $caliber';
    }
    final manufacturer = _manufacturer.text.trim();
    final model = _model.text.trim();
    if (manufacturer.isEmpty && model.isEmpty) {
      return caliber.isEmpty ? 'Untitled Firearm' : '$caliber Rifle';
    }
    final parts = <String>[
      if (manufacturer.isNotEmpty) manufacturer,
      if (model.isNotEmpty) model,
      if (caliber.isNotEmpty) caliber,
    ];
    return parts.join(' ');
  }

  /// Ensure the Name controller has a non-empty value before save.
  /// Called from both the catalog-pick handler (so the user sees
  /// the auto-fill happen as soon as they pick a rifle) and from
  /// `_runSavePipeline` (so users who didn't pick from catalog
  /// still end up with a row that has a sensible name).
  ///
  /// Pure no-op when the user already typed a name — we never
  /// clobber a user's explicit choice.
  void _ensureName() {
    if (_name.text.trim().isNotEmpty) return;
    _name.text = _generatedName();
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
                      // Name is optional — `_ensureName()` runs on
                      // save (and on catalog pick) and fills a
                      // sensible default from manufacturer + model
                      // + caliber, or chassis + caliber for custom
                      // builds. The validator returns null
                      // unconditionally; it only stays as a hook
                      // in case we ever need to re-tighten this.
                      TextFormField(
                        controller: _name,
                        decoration: const InputDecoration(
                          labelText: 'Name',
                          helperText:
                              'Optional. Auto-generated from the rifle and '
                              'caliber if blank — e.g. "Tikka T3x CTR '
                              '6.5 Creedmoor".',
                          helperMaxLines: 2,
                        ),
                        validator: (_) => null,
                      ),
                      const SizedBox(height: 16),
                      // Build Type toggle (v33). Top-level switch between a
                      // factory rifle (catalog or freeform manufacturer/model)
                      // and a user-assembled custom build configured by
                      // chassis / barrel / trigger / buttstock / muzzle brake
                      // / suppressor / bipod selections. The two modes share
                      // every other field below (caliber, barrel length, twist
                      // rate, optics, reticle, ballistics defaults, notes) so
                      // the user can flip mid-edit without losing data.
                      SegmentedButton<bool>(
                        segments: const [
                          ButtonSegment(
                              value: false, label: Text('Factory Rifle')),
                          ButtonSegment(
                              value: true, label: Text('Custom Build')),
                        ],
                        selected: {_isCustomBuild},
                        onSelectionChanged: (s) {
                          setState(() {
                            _isCustomBuild = s.first;
                            if (_isCustomBuild) {
                              // A custom build has no factory parent.
                              _selectedRef = null;
                              _referenceFirearmId = null;
                            }
                          });
                          _autoSave.notifyDirty();
                        },
                      ),
                      const SizedBox(height: 16),
                      // 2026-05-10 reorg — both modes now render in the
                      // same canonical section order:
                      //
                      //   Manufactured (Factory):
                      //     Rifle → Optic → Components(3) → Ballistics
                      //
                      //   Custom Build:
                      //     Components(7) → Optic → barrel/twist+shots
                      //     → Ballistics
                      //
                      // The OLD layout interleaved barrel-length / twist
                      // / shots between the catalog picker and the
                      // optic section. The new Manufactured layout
                      // bundles those three with the catalog picker
                      // inside `_rifleSection`. Custom Build keeps a
                      // looser layout because it has no factory rifle
                      // identifier — caliber and barrel come from the
                      // user-typed component selections.
                      if (_isCustomBuild) ...[
                        _componentsSection(context),
                        const SizedBox(height: 16),
                        // Custom builds still need a barrel length +
                        // twist (the chassis/barrel pickers are brand
                        // names, not dimensional specs) and a shots-
                        // fired counter.
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
                            second: _twistRow(),
                          );
                        }),
                        const SizedBox(height: 16),
                        _shotsFiredField(context),
                      ] else ...[
                        _rifleSection(context),
                      ],
                      const SizedBox(height: 16),
                      _opticsSection(context),
                      const SizedBox(height: 16),
                      // Components panel for Factory mode is the
                      // 3-component layout (Bipod / Trigger /
                      // Muzzle Device). Custom Build already
                      // surfaced the broader 7-component layout
                      // above — it doesn't get a second one here.
                      if (!_isCustomBuild) ...[
                        _componentsSectionFactory(context),
                        const SizedBox(height: 16),
                      ],
                      _ballisticsDefaultsSection(context),
                      const SizedBox(height: 12),
                      TextFormField(
                        controller: _notes,
                        decoration: const InputDecoration(labelText: 'Notes'),
                        maxLines: 4,
                      ),
                      const SizedBox(height: 24),
                      // Side-by-side action row (2026-05-10). The
                      // primary "Done" / "Save Changes" button keeps
                      // the FilledButton emphasis; the new
                      // "Ballistics" button is an OutlinedButton — a
                      // secondary action that saves AND immediately
                      // pushes the Ballistics calculator with this
                      // firearm preselected, for the workflow where
                      // the user sets up a rifle then wants to start
                      // computing solutions right away.
                      Row(
                        children: [
                          Expanded(
                            child: OutlinedButton.icon(
                              onPressed:
                                  _busy ? null : _saveAndOpenBallistics,
                              icon: const Icon(Icons.calculate_outlined),
                              label: const Text('Ballistics'),
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: FilledButton(
                              onPressed: _busy ? null : _save,
                              child:
                                  Text(_finalButtonLabel(autoSaveOn, isEdit)),
                            ),
                          ),
                        ],
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

  /// Per CLAUDE.md UX rule: autosave on → "Done"; off → "Save".
  /// We surface the more specific label "Save Changes" / "Create
  /// Firearm" instead of plain "Save" because the firearm form is
  /// non-trivial — the longer label tells the user what action
  /// they're committing to. Both labels fit the bottom-button width
  /// on every supported device.
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
          // Label used in the field, suggestion list, and as the
          // initial text when opening an edit. Centralised so the
          // search-token matcher and the displayed value never drift
          // apart.
          String labelOf(_RefEntry r) =>
              '${r.manufacturer.name} ${r.firearm.model}';
          final initialText =
              _selectedRef != null ? labelOf(_selectedRef!) : '';
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // Field label sits above the Autocomplete so the
              // suggestion panel doesn't have to fight with a
              // floating label, and so the field still reads as
              // "Model from Catalog" when empty.
              Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Text(
                  'Model from Catalog',
                  style: Theme.of(context).textTheme.labelLarge,
                ),
              ),
              // Autocomplete<_RefEntry>: type to filter inline. Replaces
              // the old DropdownButtonFormField that opened a full-screen
              // menu with no search. Token-based matcher splits the query
              // on whitespace and requires every token to appear somewhere
              // in "<manufacturer> <model>" so a search like
              // "tikka 6.5" narrows correctly even when the user hasn't
              // typed the words in catalog order.
              Autocomplete<_RefEntry>(
                initialValue: TextEditingValue(text: initialText),
                displayStringForOption: labelOf,
                optionsBuilder: (te) {
                  final qq = te.text.trim().toLowerCase();
                  if (qq.isEmpty) return refs;
                  final tokens = qq
                      .split(RegExp(r'\s+'))
                      .where((t) => t.isNotEmpty)
                      .toList(growable: false);
                  return refs.where((r) {
                    final hay = labelOf(r).toLowerCase();
                    for (final tk in tokens) {
                      if (!hay.contains(tk)) return false;
                    }
                    return true;
                  });
                },
                fieldViewBuilder:
                    (context, textCtrl, focusNode, onSubmit) {
                  return TextFormField(
                    controller: textCtrl,
                    focusNode: focusNode,
                    autocorrect: false,
                    enableSuggestions: false,
                    decoration: InputDecoration(
                      isDense: true,
                      border: const OutlineInputBorder(),
                      hintText: 'Search manufacturer or model',
                      prefixIcon: const Icon(Icons.search, size: 18),
                      suffixIcon: textCtrl.text.isEmpty
                          ? null
                          : IconButton(
                              icon: const Icon(Icons.close, size: 18),
                              tooltip: 'Clear',
                              onPressed: () {
                                textCtrl.clear();
                                setState(() {
                                  _selectedRef = null;
                                  _referenceFirearmId = null;
                                });
                                _autoSave.notifyDirty();
                              },
                            ),
                    ),
                    onFieldSubmitted: (_) => onSubmit(),
                    onTap: () {
                      // Force the options panel open on focus even when
                      // the field already has text (Flutter's default is
                      // to only open after a text change).
                      if (textCtrl.text.isEmpty) {
                        textCtrl.text = ' ';
                        textCtrl.text = '';
                      }
                    },
                    validator: (_) =>
                        _selectedRef == null ? 'Pick a model' : null,
                  );
                },
                onSelected: (r) => _applyReferenceSelection(r),
                optionsViewBuilder: (context, onSelected, options) {
                  return Align(
                    alignment: Alignment.topLeft,
                    child: Material(
                      elevation: 4,
                      child: ConstrainedBox(
                        constraints:
                            const BoxConstraints(maxHeight: 360),
                        child: ListView.builder(
                          shrinkWrap: true,
                          padding: EdgeInsets.zero,
                          itemCount: options.length,
                          itemBuilder: (context, i) {
                            final r = options.elementAt(i);
                            return ListTile(
                              dense: true,
                              title: Text(labelOf(r)),
                              subtitle: Text(
                                [
                                  _titleCaseEnum(r.firearm.type),
                                  if ((r.firearm.action ?? '').isNotEmpty)
                                    _titleCaseEnum(r.firearm.action!),
                                ].join(' · '),
                                style:
                                    Theme.of(context).textTheme.bodySmall,
                              ),
                              onTap: () => onSelected(r),
                            );
                          },
                        ),
                      ),
                    ),
                  );
                },
              ),
              const SizedBox(height: 12),
              if (_selectedRef != null) ...[
                _readOnlyTile('Manufacturer', _selectedRef!.manufacturer.name),
                _readOnlyTile('Model', _selectedRef!.firearm.model),
                _readOnlyTile(
                    'Type', _titleCaseEnum(_selectedRef!.firearm.type)),
                if ((_selectedRef!.firearm.action ?? '').isNotEmpty)
                  _readOnlyTile('Action',
                      _titleCaseEnum(_selectedRef!.firearm.action!)),
                const SizedBox(height: 12),
                // Catalog-driven caliber UI. Behavior depends on how
                // many chamberings the catalog row declares:
                //   * 0 → fall back to the freeform ComponentField so
                //         the user can still type one (rare; only
                //         hits very old / incomplete seed rows).
                //   * 1 → read-only tile showing the chambering. We
                //         already wrote it into `_caliber` from
                //         `_applyReferenceSelection`, so save just
                //         works.
                //   * 2+ → DropdownButton<String> with every catalog
                //         chambering. Defaults to the first option
                //         (set by `_applyReferenceSelection`); user
                //         can switch to whichever they actually
                //         shoot. Selection writes through to
                //         `_caliber` so save persists exactly what
                //         the user picked.
                _catalogCaliberSection(_selectedRef!),
              ],
            ],
          );
        },
      ),
    ];
  }

  // _customFields() removed 2026-05-10. The legacy "Pick from
  // Catalog | Custom" inner toggle on Factory mode let users type
  // freeform manufacturer / model / type / action / caliber when
  // their rifle wasn't in the catalog. Removed in favor of always
  // using the catalog autocomplete in Factory mode — users with
  // catalog-missing rifles either pick the closest catalog match
  // or convert to Custom Build mode (which configures by
  // components, not by factory model identifier).

  /// Catalog-mode caliber selector. Renders one of three layouts based
  /// on the number of chamberings the catalog row declares for the
  /// picked firearm. See the call-site comment in `_catalogFields` for
  /// the full state table.
  Widget _catalogCaliberSection(_RefEntry ref) {
    if (ref.calibers.isEmpty) {
      return Padding(
        padding: const EdgeInsets.only(top: 4),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: Text(
                'Caliber',
                style: Theme.of(context).textTheme.labelLarge,
              ),
            ),
            ComponentField(
              kind: 'cartridge',
              label: 'Caliber',
              controller: _caliber,
            ),
          ],
        ),
      );
    }
    if (ref.calibers.length == 1) {
      return _readOnlyTile('Caliber', ref.calibers.first);
    }
    // Multi-chambering rifles: a clean dropdown so the user can
    // declare which factory chambering they actually own. The
    // current `_caliber.text` (set by `_applyReferenceSelection` or
    // by an existing-row load) is the seed value.
    //
    // Edge case: a saved firearm carries a caliber that no longer
    // appears in the catalog row (catalog churn between releases,
    // or the user typed it by hand in an earlier version of the app).
    // We refuse to silently overwrite their choice — the saved value
    // is appended to the dropdown items as a "(user-entered)" option
    // so the displayed value always matches what would persist on
    // save, and the user can either keep it or switch to a catalog
    // chambering.
    final current = _caliber.text.trim();
    final inCatalog = current.isNotEmpty && ref.calibers.contains(current);
    final initial = inCatalog
        ? current
        : (current.isNotEmpty ? current : ref.calibers.first);
    final items = <DropdownMenuItem<String>>[
      for (final c in ref.calibers)
        DropdownMenuItem(value: c, child: Text(c)),
      if (current.isNotEmpty && !inCatalog)
        DropdownMenuItem(value: current, child: Text('$current (custom)')),
    ];
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: DropdownButtonFormField<String>(
        initialValue: initial,
        isExpanded: true,
        decoration: const InputDecoration(
          labelText: 'Caliber',
          helperText: 'Pick which chambering this firearm is.',
        ),
        items: items,
        onChanged: (v) {
          if (v == null) return;
          setState(() => _caliber.text = v);
          // If the catalog row has per-caliber specs (schema v34+),
          // re-apply the picked caliber's barrel length and twist
          // so the form reflects "the AT-X in 6.5 CM is 24" / 1:8,
          // not the AT-X in .308's 20" / 1:10". Pure no-op for
          // single-spec rifles or pre-v34 catalog rows.
          _applyCaliberSpec(ref, v);
          _autoSave.notifyDirty();
        },
      ),
    );
  }

  /// Title-case a catalog enum like "rifle" / "semi-auto" /
  /// "bolt-action" for display. Splits on spaces AND hyphens so
  /// "semi-auto" becomes "Semi-Auto" rather than "Semi-auto", which
  /// matches the rest of the UI's Title Case convention (CLAUDE.md
  /// § 0a). Empty input returns empty.
  String _titleCaseEnum(String raw) {
    if (raw.isEmpty) return raw;
    final buf = StringBuffer();
    var capitaliseNext = true;
    for (final ch in raw.runes) {
      final s = String.fromCharCode(ch);
      if (s == '-' || s == ' ' || s == '_' || s == '/') {
        buf.write(s);
        capitaliseNext = true;
      } else if (capitaliseNext) {
        buf.write(s.toUpperCase());
        capitaliseNext = false;
      } else {
        buf.write(s.toLowerCase());
      }
    }
    return buf.toString();
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

  /// Barrel-length input — renders as a dropdown when the catalog
  /// row + picked caliber declare multiple factory barrel lengths
  /// (e.g. AT-X .308 Win ships in 16.5" and 20" variants), and as a
  /// plain text field otherwise (single-length, custom rifles, or
  /// pre-v34 catalog rows).
  ///
  /// The dropdown is the preferred UI when the manufacturer offers a
  /// choice — it makes the variants discoverable and prevents
  /// fat-finger typos. A user with a re-barreled rifle of a known
  /// non-factory length can still work around by switching to
  /// Custom Build mode (no catalog ref → text field returns).
  Widget _barrelLengthField(String smallLen) {
    final ref = _selectedRef;
    final caliber = _caliber.text.trim();
    if (ref != null && caliber.isNotEmpty) {
      final spec = _caliberSpecsFor(ref)[caliber];
      if (spec != null && spec.barrelLengthsIn.length > 1) {
        return _barrelLengthDropdown(smallLen, spec.barrelLengthsIn);
      }
    }
    // Fall through: plain text field. Single-length specs auto-fill
    // via `_applyReferenceSelection` / `_applyCaliberSpec` and the
    // user is free to override (re-barrel, SBR variant, etc.).
    return TextFormField(
      controller: _barrelLength,
      decoration: InputDecoration(
        labelText: 'Barrel Length ($smallLen)',
        suffixText: smallLen,
      ),
      keyboardType:
          const TextInputType.numberWithOptions(decimal: true),
    );
  }

  /// Build a dropdown of factory-offered barrel lengths for the
  /// picked caliber. Selecting an item rewrites
  /// `_barrelLength.text` so downstream readers (the firing-solution
  /// solver, autosave, the saved row) see the same value the user
  /// sees. The current `_barrelLength` value is added as a "(custom)"
  /// option when it's outside the factory list — preserves
  /// re-barrel scenarios where the user's barrel is non-factory.
  Widget _barrelLengthDropdown(String smallLen, List<double> factoryLengths) {
    final currentText = _barrelLength.text.trim();
    final currentValue = double.tryParse(currentText);
    final inList = currentValue != null &&
        factoryLengths.any((v) => (v - currentValue).abs() < 0.001);
    final initial =
        inList ? currentValue : factoryLengths.first;
    // Make sure the controller and the dropdown are in sync — if the
    // user landed on a caliber whose spec list doesn't include
    // whatever's in the controller, snap to the first factory
    // length. Safe because the only way to reach this builder with a
    // mismatched value is via a stale state path (e.g. the form
    // initially loaded a saved row's custom barrel length, then
    // user picked a different caliber).
    if (!inList && currentText != _formatBarrelLength(factoryLengths.first)) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        if (_barrelLength.text != _formatBarrelLength(factoryLengths.first)) {
          _barrelLength.text = _formatBarrelLength(factoryLengths.first);
        }
      });
    }
    return DropdownButtonFormField<double>(
      initialValue: initial,
      isExpanded: true,
      decoration: InputDecoration(
        labelText: 'Barrel Length ($smallLen)',
        suffixText: smallLen,
      ),
      items: [
        for (final v in factoryLengths)
          DropdownMenuItem<double>(
            value: v,
            child: Text('${_formatBarrelLength(v)} $smallLen'),
          ),
        if (currentValue != null && !inList)
          DropdownMenuItem<double>(
            value: currentValue,
            child: Text('${_formatBarrelLength(currentValue)} $smallLen (custom)'),
          ),
      ],
      onChanged: (v) {
        if (v == null) return;
        setState(() {
          _barrelLength.text = _formatBarrelLength(v);
        });
        _autoSave.notifyDirty();
      },
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

  /// Components panel for custom builds (added schema v33). Renders
  /// seven autocomplete pickers stacked vertically — chassis, barrel,
  /// trigger, buttstock, muzzle brake, suppressor, bipod — each
  /// populated from the `FirearmComponents` catalog filtered by
  /// `kind`. The user can either pick a catalog suggestion (writes
  /// `"<Manufacturer> <Model>"` to the controller) or type freeform
  /// (saved verbatim — catalog membership is a hint, not a
  /// constraint).
  ///
  /// Lazy-loads the catalog through the cached `_componentsFuture`
  /// future so the seven pickers share one query result. The
  /// component list is small enough (~220 rows) that filtering
  /// client-side per keystroke is fine; no need for per-kind queries
  /// on every input event.
  Widget _componentsSection(BuildContext context) {
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
                Icon(Icons.build_outlined,
                    size: 16, color: theme.colorScheme.primary),
                const SizedBox(width: 6),
                Text(
                  'Components',
                  style: theme.textTheme.labelLarge?.copyWith(
                    color: theme.colorScheme.primary,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              'Pick the products that make up this rifle. Each picker '
              'filters the LoadOut component catalog as you type — or '
              'type any product name we don\'t know about.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 12),
            FutureBuilder<List<FirearmComponentEntry>>(
              future: _componentsFuture,
              builder: (context, snap) {
                if (snap.connectionState == ConnectionState.waiting) {
                  return const Padding(
                    padding: EdgeInsets.symmetric(vertical: 8),
                    child: LinearProgressIndicator(),
                  );
                }
                final entries = snap.data ?? const <FirearmComponentEntry>[];
                List<FirearmComponentEntry> entriesOf(
                        FirearmComponentKind k) =>
                    entries.where((e) => e.kind == k).toList(growable: false);
                // Stack the seven pickers vertically. Order matches
                // the user's reading flow when describing a build:
                // skeleton (chassis / barrel) first, fire-control
                // (trigger / buttstock) next, muzzle device
                // (brake / suppressor), then bipod.
                final pickers = <Widget>[
                  _ComponentPicker(
                    kind: FirearmComponentKind.chassis,
                    controller: _chassisName,
                    entries: entriesOf(FirearmComponentKind.chassis),
                    onChanged: () => _autoSave.notifyDirty(),
                  ),
                  _ComponentPicker(
                    kind: FirearmComponentKind.barrel,
                    controller: _barrelName,
                    entries: entriesOf(FirearmComponentKind.barrel),
                    onChanged: () => _autoSave.notifyDirty(),
                  ),
                  _ComponentPicker(
                    kind: FirearmComponentKind.trigger,
                    controller: _triggerName,
                    entries: entriesOf(FirearmComponentKind.trigger),
                    onChanged: () => _autoSave.notifyDirty(),
                  ),
                  _ComponentPicker(
                    kind: FirearmComponentKind.buttstock,
                    controller: _buttstockName,
                    entries: entriesOf(FirearmComponentKind.buttstock),
                    onChanged: () => _autoSave.notifyDirty(),
                  ),
                  _ComponentPicker(
                    kind: FirearmComponentKind.muzzleBrake,
                    controller: _muzzleBrakeName,
                    entries: entriesOf(FirearmComponentKind.muzzleBrake),
                    onChanged: () => _autoSave.notifyDirty(),
                  ),
                  _ComponentPicker(
                    kind: FirearmComponentKind.suppressor,
                    controller: _suppressorName,
                    entries: entriesOf(FirearmComponentKind.suppressor),
                    onChanged: () => _autoSave.notifyDirty(),
                  ),
                  _ComponentPicker(
                    kind: FirearmComponentKind.bipod,
                    controller: _bipodName,
                    entries: entriesOf(FirearmComponentKind.bipod),
                    onChanged: () => _autoSave.notifyDirty(),
                  ),
                ];
                final children = <Widget>[];
                for (var i = 0; i < pickers.length; i++) {
                  if (i > 0) {
                    children.add(const SizedBox(height: 12));
                  }
                  children.add(pickers[i]);
                }
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: children,
                );
              },
            ),
            const SizedBox(height: 16),
            // Caliber is required for the ballistics solver downstream
            // — we keep the field visible inside the components panel
            // for custom builds because the user no longer has a
            // factory-catalog row that auto-fills it. Mirror the same
            // ComponentField that the Factory mode's `_customFields()`
            // uses so a user-typed caliber participates in the same
            // "remember as custom cartridge" flow.
            Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: Text(
                'Caliber',
                style: theme.textTheme.labelLarge,
              ),
            ),
            ComponentField(
              kind: 'cartridge',
              controller: _caliber,
              label: 'Caliber',
            ),
          ],
        ),
      ),
    );
  }

  /// Manufactured-rifle section (2026-05-10 reorg). Wraps the
  /// catalog autocomplete picker, the auto-filled rifle details,
  /// the barrel-length / twist row, and the shots-fired counter
  /// inside a single Card with a "Rifle" header. Replaces the loose
  /// stack of unfettered widgets the form used to render in Factory
  /// mode.
  ///
  /// Only rendered when `_isCustomBuild == false`. Custom Build mode
  /// has no factory rifle to identify, so it skips this section
  /// entirely and goes straight to the Components panel.
  Widget _rifleSection(BuildContext context) {
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
                Icon(Icons.gpp_good_outlined,
                    size: 16, color: theme.colorScheme.primary),
                const SizedBox(width: 6),
                Text(
                  'Rifle',
                  style: theme.textTheme.labelLarge?.copyWith(
                    color: theme.colorScheme.primary,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              'Pick the manufactured rifle from the catalog. The '
              'caliber, barrel length, and twist auto-fill from the '
              'catalog row but stay editable.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 12),
            ..._catalogFields(),
            const SizedBox(height: 12),
            // Barrel length + twist row. Inherits the catalog's
            // factory-spec default but the user can override (a
            // re-barreled rifle, a 16" SBR variant of a 20" catalog
            // entry, etc.).
            Builder(builder: (ctx) {
              final smallLen = unitDisplayLabel(ctx
                  .watch<UnitService>()
                  .unitFor(UnitCategory.smallLength));
              return _ResponsiveRowPair(
                first: _barrelLengthField(smallLen),
                second: _twistRow(),
              );
            }),
            const SizedBox(height: 16),
            _shotsFiredField(context),
          ],
        ),
      ),
    );
  }

  /// Components section for Manufactured rifles (2026-05-10 reorg).
  /// Surfaces the THREE common aftermarket components a manufactured
  /// rifle owner typically swaps:
  ///
  ///   * Bipod — always aftermarket; no Factory option needed.
  ///   * Trigger — often replaced (TriggerTech, Timney, Jewell) but
  ///     a Factory chip lets the user record "stock trigger".
  ///   * Muzzle device — a single slot toggled between Brake and
  ///     Suppressor. A rifle has either-or installed at a time, never
  ///     both. Brake gets a Factory chip (most rifles ship with a
  ///     thread protector or brake from the factory). Suppressor
  ///     does not — there's no "factory suppressor" SKU on common
  ///     rifles.
  ///
  /// The remaining four component fields (chassis, barrel, buttstock,
  /// and the inactive of brake/suppressor) are still written through
  /// `_buildCompanion` from their controllers — the data is preserved
  /// across the Manufactured ↔ Custom Build mode toggle so a user who
  /// flips back and forth doesn't lose what they typed.
  ///
  /// Custom Build mode uses the broader `_componentsSection` instead,
  /// which surfaces all 7 component pickers.
  Widget _componentsSectionFactory(BuildContext context) {
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
                Icon(Icons.build_outlined,
                    size: 16, color: theme.colorScheme.primary),
                const SizedBox(width: 6),
                Text(
                  'Components',
                  style: theme.textTheme.labelLarge?.copyWith(
                    color: theme.colorScheme.primary,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              'Aftermarket parts installed on this rifle. Tap "Factory" '
              'to record the stock component for trigger or muzzle '
              'brake.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 12),
            FutureBuilder<List<FirearmComponentEntry>>(
              future: _componentsFuture,
              builder: (context, snap) {
                if (snap.connectionState == ConnectionState.waiting) {
                  return const Padding(
                    padding: EdgeInsets.symmetric(vertical: 8),
                    child: LinearProgressIndicator(),
                  );
                }
                final entries = snap.data ?? const <FirearmComponentEntry>[];
                List<FirearmComponentEntry> entriesOf(
                        FirearmComponentKind k) =>
                    entries.where((e) => e.kind == k).toList(growable: false);
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    // Bipod — always aftermarket; no Factory option.
                    _ComponentPicker(
                      kind: FirearmComponentKind.bipod,
                      controller: _bipodName,
                      entries: entriesOf(FirearmComponentKind.bipod),
                      onChanged: () => _autoSave.notifyDirty(),
                    ),
                    const SizedBox(height: 12),
                    // Trigger — Factory chip rendered INSIDE the
                    // picker (under the "Trigger" label, above the
                    // search field) so the chip is visually owned
                    // by this section rather than floating between
                    // Bipod and Trigger as it did in the first
                    // iteration.
                    _ComponentPicker(
                      kind: FirearmComponentKind.trigger,
                      controller: _triggerName,
                      entries: entriesOf(FirearmComponentKind.trigger),
                      allowFactory: true,
                      onChanged: () => _autoSave.notifyDirty(),
                    ),
                    const SizedBox(height: 16),
                    // Muzzle-device toggle: Brake or Suppressor.
                    Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: Text(
                        'Muzzle Device',
                        style: theme.textTheme.labelLarge,
                      ),
                    ),
                    SegmentedButton<String>(
                      segments: const [
                        ButtonSegment(
                            value: 'brake', label: Text('Muzzle Brake')),
                        ButtonSegment(
                            value: 'suppressor', label: Text('Suppressor')),
                      ],
                      selected: {_muzzleDevice},
                      onSelectionChanged: (s) {
                        setState(() {
                          _muzzleDevice = s.first;
                        });
                        _autoSave.notifyDirty();
                      },
                    ),
                    const SizedBox(height: 12),
                    // Active picker for the muzzle-device choice.
                    // Brake gets the inline Factory chip (a stock
                    // thread protector or factory brake is common);
                    // suppressor never gets one since "factory
                    // suppressor" isn't a real rifle SKU.
                    if (_muzzleDevice == 'brake')
                      _ComponentPicker(
                        kind: FirearmComponentKind.muzzleBrake,
                        controller: _muzzleBrakeName,
                        entries: entriesOf(FirearmComponentKind.muzzleBrake),
                        allowFactory: true,
                        onChanged: () => _autoSave.notifyDirty(),
                      )
                    else
                      _ComponentPicker(
                        kind: FirearmComponentKind.suppressor,
                        controller: _suppressorName,
                        entries: entriesOf(FirearmComponentKind.suppressor),
                        onChanged: () => _autoSave.notifyDirty(),
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
                String labelOf(OpticEntry o) =>
                    '${o.manufacturer.name} ${o.optic.model}';
                final initialText =
                    _selectedOptic != null ? labelOf(_selectedOptic!) : '';
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Padding(
                      padding: const EdgeInsets.only(bottom: 4),
                      child: Text(
                        'Mounted Optic',
                        style: Theme.of(context).textTheme.labelLarge,
                      ),
                    ),
                    // Autocomplete<OpticEntry>: type to filter inline.
                    // Same pattern used for the firearm-catalog picker
                    // above so the two pickers behave identically. The
                    // suggestion panel pops below the field instead of
                    // taking over the whole screen, and a search bar
                    // sits at the top so users with crowded optics
                    // catalogs can find a scope by typing instead of
                    // scrolling. "None / iron sights" lives as the
                    // first row of the suggestion panel; clearing the
                    // field also resets to None.
                    Autocomplete<OpticEntry>(
                      initialValue: TextEditingValue(text: initialText),
                      displayStringForOption: labelOf,
                      optionsBuilder: (te) {
                        final qq = te.text.trim().toLowerCase();
                        if (qq.isEmpty) return optics;
                        final tokens = qq
                            .split(RegExp(r'\s+'))
                            .where((t) => t.isNotEmpty)
                            .toList(growable: false);
                        return optics.where((o) {
                          final hay = labelOf(o).toLowerCase();
                          for (final tk in tokens) {
                            if (!hay.contains(tk)) return false;
                          }
                          return true;
                        });
                      },
                      fieldViewBuilder:
                          (context, textCtrl, focusNode, onSubmit) {
                        return TextFormField(
                          controller: textCtrl,
                          focusNode: focusNode,
                          autocorrect: false,
                          enableSuggestions: false,
                          decoration: InputDecoration(
                            isDense: true,
                            border: const OutlineInputBorder(),
                            hintText: 'Search manufacturer or model',
                            helperText:
                                'Clear the field for "None / iron sights".',
                            prefixIcon:
                                const Icon(Icons.search, size: 18),
                            suffixIcon: textCtrl.text.isEmpty
                                ? null
                                : IconButton(
                                    icon: const Icon(Icons.close, size: 18),
                                    tooltip: 'Clear',
                                    onPressed: () {
                                      textCtrl.clear();
                                      setState(() {
                                        _selectedOptic = null;
                                        _opticsId = null;
                                      });
                                      _autoSave.notifyDirty();
                                    },
                                  ),
                          ),
                          onFieldSubmitted: (_) => onSubmit(),
                          onTap: () {
                            // Force the panel open on focus even when
                            // the field already has text.
                            if (textCtrl.text.isEmpty) {
                              textCtrl.text = ' ';
                              textCtrl.text = '';
                            }
                          },
                        );
                      },
                      onSelected: (o) {
                        setState(() {
                          _selectedOptic = o;
                          _opticsId = o.optic.id;
                        });
                        _autoSave.notifyDirty();
                        _maybeAutoFillReticleFromOptic(o.optic.id);
                      },
                      optionsViewBuilder:
                          (context, onSelected, options) {
                        return Align(
                          alignment: Alignment.topLeft,
                          child: Material(
                            elevation: 4,
                            child: ConstrainedBox(
                              constraints:
                                  const BoxConstraints(maxHeight: 360),
                              child: ListView.builder(
                                shrinkWrap: true,
                                padding: EdgeInsets.zero,
                                itemCount: options.length,
                                itemBuilder: (context, i) {
                                  final o = options.elementAt(i);
                                  return ListTile(
                                    dense: true,
                                    title: Text(labelOf(o)),
                                    subtitle: Text(
                                      [
                                        o.optic.category,
                                        if (o.optic.magnification.isNotEmpty)
                                          o.optic.magnification,
                                      ].join(' · '),
                                      style: Theme.of(context)
                                          .textTheme
                                          .bodySmall,
                                    ),
                                    onTap: () => onSelected(o),
                                  );
                                },
                              ),
                            ),
                          ),
                        );
                      },
                    ),
                  ],
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
            const SizedBox(height: 12),
            // Sight Height (a.k.a. Scope Height in the user-facing
            // 2026-05-10 reorg). Lives inside the Optic section
            // because it's a property of the optic + rings/mount
            // combination — not a "ballistics default". The solver
            // reads it as the bore-axis-to-line-of-sight offset for
            // the geometric line-of-sight correction.
            Builder(builder: (ctx) {
              final smallLen = unitDisplayLabel(
                  ctx.watch<UnitService>().unitFor(UnitCategory.smallLength));
              return TextFormField(
                controller: _sightHeightIn,
                decoration: InputDecoration(
                  labelText: 'Scope Height ($smallLen)',
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
              );
            }),
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
          'Scope Tracking Calibration (Advanced)',
          style: theme.textTheme.labelLarge?.copyWith(
            color: theme.colorScheme.primary,
            fontWeight: FontWeight.w600,
          ),
        ),
        // Subtitle intentionally omitted — when collapsed the user
        // should see only the section title and chevron. The full
        // explanation lives inside the expanded body below so the
        // form scrolls cleanly past this section until someone opts
        // in to read it.
        children: [
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: Text(
              'Tells the firing solution exactly how much your scope '
              'dials when you turn the turret. The solver assumes 1 '
              'mil (or MOA) dialed equals 1 mil downrange — when your '
              'scope is off, every drop and wind correction inherits '
              'that same error proportionally, so a long-range shot '
              'drifts.\n\n'
              'Vertical scale corrects elevation, horizontal scale '
              'corrects windage. Enter the ratio of actual to '
              'commanded movement (1.000 = perfect tracking). Run the '
              'Scope Tracking Test from Range Day → Advanced Analysis '
              "if you don't already have a measured value.",
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
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
    final rangeUnit = unitDisplayLabel(units.unitFor(UnitCategory.range));
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
                  'Ballistics',
                  style: theme.textTheme.labelLarge?.copyWith(
                    color: theme.colorScheme.primary,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              'Default zero range and (optionally) the atmosphere when '
              'you sighted in. Pre-fills the ballistics calculator when '
              'this firearm is selected.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 12),
            // MV input + Garmin Xero / Photo OCR capture buttons used
            // to live here. Removed from the firearm creation/update
            // form because MV changes per-load (different powders /
            // bullets / temperatures all shift it), so asking the
            // user to pin one number to a rifle was the wrong
            // affordance. See `lib/widgets/mv_capture_buttons.dart`
            // for the External Ballistics + Ballistic Profile hosts.
            //
            // Sight Height (now "Scope Height") was here too, but
            // moved into the Optic section in the 2026-05-10 reorg
            // because it's properly a property of the optic +
            // rings/mount, not a ballistics default.
            TextFormField(
              controller: _defaultZeroRangeYd,
              decoration: InputDecoration(
                labelText: 'Zero Range ($rangeUnit)',
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
          'Zero Environment Conditions (Advanced)',
          style: theme.textTheme.labelLarge?.copyWith(
            color: theme.colorScheme.primary,
            fontWeight: FontWeight.w600,
          ),
        ),
        // No `subtitle:` — the explanatory paragraph used to render
        // here below the title even when collapsed, which made the
        // "Advanced" expander loud on a form designed to read calmly
        // when nothing is expanded. Now the prose lives inside the
        // expanded body (first child below).
        children: [
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: Text(
              'The atmosphere where you sighted in. Future ballistics '
              'solves use these as the baseline so today\'s correction '
              'is computed relative to zero-day, not to the ICAO '
              'standard atmosphere.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
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
          // fields above. Pro-gated; tapping a free user routes
          // through `ensurePro` (paywall) before the network call.
          //
          // Layout: `Align(centerLeft) + Wrap` instead of
          // `Align + Row(MainAxisSize.min)`. The ExpansionTile body
          // hands its children unbounded-width constraints; the Row
          // variant let `w=Infinity` reach `OutlinedButton`'s 48 dp
          // tap-target enforcer, which then asserted in
          // `RenderPhysicalShape`. `Wrap` sizes children to their
          // intrinsic widths and falls a child to a new line on a
          // narrow device. Same canonical fix used by
          // `_inclineAngleRow` in `range_day_detail_screen.dart`.
          Align(
            alignment: Alignment.centerLeft,
            child: Wrap(
              spacing: 8,
              runSpacing: 4,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                OutlinedButton.icon(
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
                if (!context.watch<EntitlementNotifier>().isPro)
                  _zeroWeatherProBadge(),
              ],
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
  ///
  /// Pro-gated. The same open-meteo handshake powers the Pro
  /// "Use my location" button on the ballistics screen and the GPS
  /// altitude piece of Range Day's "Capture environment from sensors";
  /// gating this keeps the live-weather pitch consistent across the
  /// app.
  Future<void> _captureZeroFromWeather() async {
    if (!await ensurePro(context)) return;
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

  /// Brass-tinted "Pro" pill rendered next to the Zero Conditions
  /// "Capture from current weather" button so a free user can see at a
  /// glance that tapping the button will route through the paywall.
  Widget _zeroWeatherProBadge() {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      decoration: BoxDecoration(
        color: theme.colorScheme.primary.withValues(alpha: 0.16),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(
          color: theme.colorScheme.primary.withValues(alpha: 0.55),
          width: 0.8,
        ),
      ),
      child: Text(
        'Pro',
        style: theme.textTheme.labelSmall?.copyWith(
          color: theme.colorScheme.primary,
          fontWeight: FontWeight.w600,
          fontSize: 10,
          letterSpacing: 0.2,
        ),
      ),
    );
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

/// Single-row autocomplete picker for one component category (chassis,
/// barrel, trigger, etc.) — added schema v33 to drive the firearm
/// form's "Custom Build" mode.
///
/// Behaviour:
///   * Manufacturer + model display, identical to the existing
///     optic / firearm-catalog pickers so the form reads consistently.
///   * Free-text typing is allowed — what the user types is what gets
///     saved. Catalog membership is a hint (the autocomplete
///     suggests matches), never a constraint.
///   * The Clear (×) icon resets the controller without picking
///     anything, mirroring the optic picker's "None / iron sights"
///     gesture.
///
/// `onChanged` fires whenever the saved value changes (typed
/// keystrokes via TextField listener, picked suggestion via the
/// autocomplete callback, or Clear). Forms wire this through to
/// `AutoSaveController.notifyDirty` so the debounce timer restarts
/// just like every other field on the screen.

/// One-tap chip that fills the bound controller with the literal
/// string `"Factory"`. Surfaced above the Trigger and Muzzle Brake
/// pickers in Manufactured rifle mode for the common case where the
/// rifle still has its factory-installed component.
///
/// Tapping the chip sets the controller value, fires `onChanged`,
/// and visually highlights when the controller is currently holding
/// `"Factory"` so the user can see that the chip is the active
/// choice. Typing a different value into the picker below clears the
/// chip's highlight on the next rebuild.
class _FactoryChip extends StatefulWidget {
  const _FactoryChip({
    required this.controller,
    required this.onChanged,
  });

  final TextEditingController controller;
  final VoidCallback onChanged;

  @override
  State<_FactoryChip> createState() => _FactoryChipState();
}

class _FactoryChipState extends State<_FactoryChip> {
  // Listen to the bound controller and rebuild LOCALLY when its text
  // changes. This keeps the chip's `selected` visual in sync with
  // whatever's in the field without forcing the parent component
  // panel to setState — which would cascade into rebuilding every
  // sibling picker and (crucially) re-trigger the
  // `_ComponentPicker.fieldViewBuilder` direct-sync logic mid-build.
  // The parent's `onChanged` callback now does only `notifyDirty`.
  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_onControllerChanged);
  }

  @override
  void didUpdateWidget(covariant _FactoryChip old) {
    super.didUpdateWidget(old);
    if (!identical(old.controller, widget.controller)) {
      old.controller.removeListener(_onControllerChanged);
      widget.controller.addListener(_onControllerChanged);
    }
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onControllerChanged);
    super.dispose();
  }

  void _onControllerChanged() {
    if (!mounted) return;
    setState(() {}); // local rebuild only
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isActive =
        widget.controller.text.trim().toLowerCase() == 'factory';
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Align(
        alignment: Alignment.centerLeft,
        child: InputChip(
          label: const Text('Factory'),
          avatar: Icon(
            Icons.precision_manufacturing_outlined,
            size: 16,
            color: isActive
                ? theme.colorScheme.onPrimary
                : theme.colorScheme.primary,
          ),
          selected: isActive,
          onPressed: () {
            widget.controller.text = 'Factory';
            widget.onChanged();
          },
          tooltip: 'Set this component to the factory-installed default',
        ),
      ),
    );
  }
}

class _ComponentPicker extends StatefulWidget {
  const _ComponentPicker({
    required this.kind,
    required this.controller,
    required this.entries,
    required this.onChanged,
    this.allowFactory = false,
  });

  final FirearmComponentKind kind;
  final TextEditingController controller;
  final List<FirearmComponentEntry> entries;
  final VoidCallback onChanged;

  /// Render an inline `_FactoryChip` directly under the picker's
  /// label (and above the search field) so the chip is visually and
  /// semantically grouped with THIS picker rather than appearing as
  /// an unowned widget between two sections. Used for Trigger and
  /// Muzzle Brake on Manufactured rifles where "Factory" is a
  /// common, valid value.
  final bool allowFactory;

  @override
  State<_ComponentPicker> createState() => _ComponentPickerState();
}

class _ComponentPickerState extends State<_ComponentPicker> {
  // Listen to the bound controller so the picker rebuilds when the
  // value changes from OUTSIDE — e.g. the inline `_FactoryChip` writing
  // 'Factory' into our shared controller. Without this listener, the
  // chip's tap silently mutated the controller but the autocomplete's
  // internal text field didn't pick up the change until the next time
  // the parent panel rebuilt for some other reason. Now: chip tap →
  // controller change → this listener fires → setState → build runs →
  // post-frame sync inside fieldViewBuilder pushes the new value into
  // textCtrl.
  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_onControllerChanged);
  }

  @override
  void didUpdateWidget(covariant _ComponentPicker old) {
    super.didUpdateWidget(old);
    if (!identical(old.controller, widget.controller)) {
      old.controller.removeListener(_onControllerChanged);
      widget.controller.addListener(_onControllerChanged);
    }
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onControllerChanged);
    super.dispose();
  }

  void _onControllerChanged() {
    if (!mounted) return;
    setState(() {}); // local rebuild only
  }

  @override
  Widget build(BuildContext context) {
    final kind = widget.kind;
    final controller = widget.controller;
    final entries = widget.entries;
    final onChanged = widget.onChanged;
    final allowFactory = widget.allowFactory;
    final theme = Theme.of(context);
    String labelOf(FirearmComponentEntry e) => e.label;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.only(bottom: 4),
          child: Text(
            kind.displayLabel,
            style: theme.textTheme.labelLarge,
          ),
        ),
        if (allowFactory)
          _FactoryChip(
            controller: controller,
            onChanged: onChanged,
          ),
        // Autocomplete<FirearmComponentEntry>: type to filter against
        // the catalog's manufacturer + model labels. The
        // `RawAutocomplete`-style fieldViewBuilder uses our shared
        // `controller` directly so saved-state and live-edit text
        // stay coupled — the autocomplete's internal text controller
        // is bypassed entirely.
        Autocomplete<FirearmComponentEntry>(
          initialValue: TextEditingValue(text: controller.text),
          displayStringForOption: labelOf,
          optionsBuilder: (te) {
            final qq = te.text.trim().toLowerCase();
            if (qq.isEmpty) return entries;
            final tokens = qq
                .split(RegExp(r'\s+'))
                .where((t) => t.isNotEmpty)
                .toList(growable: false);
            return entries.where((e) {
              final hay = labelOf(e).toLowerCase();
              for (final tk in tokens) {
                if (!hay.contains(tk)) return false;
              }
              return true;
            });
          },
          fieldViewBuilder: (context, textCtrl, focusNode, onSubmit) {
            // Bidirectional sync between the autocomplete's internal
            // text controller (`textCtrl`) and the parent's shared
            // controller (`controller`):
            //
            //   * Inbound (parent → field) — defer via post-frame
            //     callback. Direct assignment during build triggers
            //     `TextFormField`'s internal controller-change
            //     handler, which calls `markNeedsBuild` → the
            //     framework throws "setState called during build"
            //     because we're already inside that frame's build
            //     phase. The `_FactoryChip` flow exposed this:
            //     chip tap → controller.text='Factory' → setState
            //     → rebuild → this fieldViewBuilder runs → direct
            //     sync triggered the crash. Deferring to the next
            //     frame moves the FormFieldState rebuild out of the
            //     current build phase.
            //   * Outbound (field → parent) — listen synchronously;
            //     fires from a tap/keystroke event handler, never
            //     during build.
            if (textCtrl.text != controller.text) {
              WidgetsBinding.instance.addPostFrameCallback((_) {
                if (textCtrl.text != controller.text) {
                  textCtrl.text = controller.text;
                }
              });
            }
            void syncOut() {
              if (controller.text != textCtrl.text) {
                controller.text = textCtrl.text;
                onChanged();
              }
            }
            // Keep the listener idempotent — avoid re-attaching every
            // build. We tag the controller via its userTag-equivalent
            // (`hashCode` here) by wrapping the listener inside an
            // adapter; in practice fieldViewBuilder runs once per
            // field rebuild and `addListener` is cheap, so we just
            // call it once. Disposal is owned by the parent's
            // initState/dispose pair, not by us.
            textCtrl.addListener(syncOut);
            return TextFormField(
              controller: textCtrl,
              focusNode: focusNode,
              autocorrect: false,
              enableSuggestions: false,
              decoration: InputDecoration(
                isDense: true,
                border: const OutlineInputBorder(),
                hintText: 'Search manufacturer or model',
                helperText: 'Or type any product not in the catalog.',
                prefixIcon: const Icon(Icons.search, size: 18),
                suffixIcon: textCtrl.text.isEmpty
                    ? null
                    : IconButton(
                        icon: const Icon(Icons.close, size: 18),
                        tooltip: 'Clear',
                        onPressed: () {
                          textCtrl.clear();
                          // syncOut() will fire from the listener
                          // attached above, propagating the empty
                          // string to `controller`.
                        },
                      ),
              ),
              onFieldSubmitted: (_) => onSubmit(),
              onTap: () {
                // Force the panel open on focus even when the
                // field already has text.
                if (textCtrl.text.isEmpty) {
                  textCtrl.text = ' ';
                  textCtrl.text = '';
                }
              },
            );
          },
          onSelected: (e) {
            controller.text = labelOf(e);
            onChanged();
          },
          optionsViewBuilder: (context, onSelected, options) {
            return Align(
              alignment: Alignment.topLeft,
              child: Material(
                elevation: 4,
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxHeight: 360),
                  child: ListView.builder(
                    shrinkWrap: true,
                    padding: EdgeInsets.zero,
                    itemCount: options.length,
                    itemBuilder: (context, i) {
                      final e = options.elementAt(i);
                      return ListTile(
                        dense: true,
                        title: Text(labelOf(e)),
                        subtitle: Text(
                          [
                            if (e.productLine != null) e.productLine!,
                            if (e.notes != null) e.notes!,
                          ].join(' · '),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                        onTap: () => onSelected(e),
                      );
                    },
                  ),
                ),
              ),
            );
          },
        ),
      ],
    );
  }
}
