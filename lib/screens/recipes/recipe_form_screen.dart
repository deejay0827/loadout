// FILE: lib/screens/recipes/recipe_form_screen.dart
//
// ============================================================================
// WHAT THIS FILE DOES
// ============================================================================
// The recipe create / edit form. Hosts every column the `UserLoads` Drift
// table exposes — load identification, powder, primer, bullet, brass,
// loaded-round dimensions, pressure indicators, process and equipment
// provenance, and free-form notes — plus user-defined custom fields.
// Reachable from `RecipesListScreen` via the FAB (create) or by tapping a
// list tile (edit, with `widget.existing` populated).
//
// The form is data-driven instead of hand-laid-out. Three pieces wire it
// up:
//
// 1. `_FieldId` — an enum with one value per visible field, used as the
//    stable key everywhere downstream (filter matching, section
//    membership, widget keys).
// 2. `_FieldDef` — a record-style class that pairs a `_FieldId` with a
//    user-visible label, a minimum `DetailLevel`, alias tokens for fuzzy
//    search, and a `builder(BuildContext)` that returns the editor
//    widget. The builders close over the per-controller / per-state
//    fields on `_RecipeFormScreenState`, so the form rendering loop
//    doesn't need to know what kind of editor a field uses.
// 3. `_Section` — a const list that groups `_FieldId`s into the
//    collapsible sections you see on screen ("Load Identification",
//    "Powder", "Primer", "Bullet", etc.). Each section can also
//    declare 2-up `pairs` of related field IDs that render side by
//    side on desktop-class widths (≥ 1024 px); the renderer falls
//    back to the stacked layout on phone / tablet so reach-typing
//    still works on narrow screens.
//
// On top of the FieldDef registry is a 3-level detail toggle
// (`DetailLevel.basic`/`detailed`/`all`) with `SharedPreferences`
// persistence under the key `recipe_form_detail_level`. Every `_FieldDef`
// declares the lowest level at which it should be visible, and
// `DetailLevel.includes` enforces nesting (basic ⊂ detailed ⊂ all). The
// `Basic` level shows just the most-used fields (Recipe Name, Caliber,
// Powder, Charge, Bullet, Bullet Weight, Primer, Brass, COAL); `Detailed`
// adds CBTO, Seating Depth, primer / brass setup, lot pickers, etc.;
// `All` exposes pressure indicators, process / equipment provenance, and
// advanced bullet-sorting fields.
//
// A token-based filter input sits above the section list. When non-empty,
// every token must appear (case-insensitively) in either the field's
// label or one of its declared aliases — so typing "tolerance grain"
// matches both Charge Tolerance and Bullet Weight Tolerance. The filter
// takes priority over the detail level: a filtered result will surface
// even if its declared level is higher than the active toggle.
//
// Lot pickers (`_LotPickerField`) appear for powder, primer, bullet, and
// brass. Each is a `DropdownButtonFormField<int>` whose options are
// loaded from the DB via a `Future<List<...LotRow>>`. The bottom of every
// dropdown is a "+ Create New" tile that delegates to a caller-supplied
// dialog; selecting it kicks off `_showCreateLotDialog`, which writes a
// new row to the appropriate lots table and updates the dropdown's
// future / selected id once the insert returns.
//
// Custom Fields are managed in their own special section (id =
// `_customFieldsSectionId`). The section is rendered with bespoke logic
// instead of going through the FieldDef registry because both the field
// list and the editor type are user-defined at runtime. Four editor
// types are supported: text, number (with optional unit suffix), boolean
// (rendered as a `Switch`), and date (rendered through `_DateField`).
// Values persist to the `UserCustomFieldValues` table on save; the
// in-memory `_customValues` map and per-field `_customControllers` keep
// edits during the form's lifetime. A "+ Add Field" affordance opens
// `_showCreateCustomFieldDialog`, which inserts into `UserCustomFields`
// and refreshes the future.
//
// ============================================================================
// WHY IT EXISTS IN THE ARCHITECTURE
// ============================================================================
// Recipes are LoadOut's central data type, and the schema underlying them
// is wide — currently 50+ columns on the `UserLoads` table. Hand-rolling
// a flat scrolling form for every column would push the precision-shooter
// fields (CBTO, runout, primer flatness, bolt-lift state) into the same
// visual weight as the absolute basics (caliber, powder charge), making
// the screen impossible to use for casual reloaders. The detail toggle
// and the data-driven section list let the same form serve both
// audiences without duplicating code.
//
// Note the asymmetry: this file is named `recipe_form_screen.dart` and
// the public class is `RecipeFormScreen`, but the underlying Drift table
// is still `UserLoads`. That naming gap is legacy — the table predates
// the rename of "loads" to "recipes" in the UI vocabulary. Don't try to
// reconcile it without a migration plan.
//
// ============================================================================
// WHY THIS IS HARDER THAN IT LOOKS
// ============================================================================
// Adding a new field touches three places, none of them obvious without
// the FieldDef pattern documentation:
//
//   1. Append a new value to `_FieldId`.
//   2. Add a `_FieldDef` for it inside `_buildFieldDefs`, providing
//      label, level, aliases, and a builder.
//   3. Add the new id to the appropriate `_Section.fieldIds` list so it
//      lands in a section. Optionally extend that section's `pairs`
//      list with `[fieldA, fieldB]` to render the new field side-by-
//      side with another (desktop widths only — see `_planSectionLayout`
//      for the constraints: same section, both visible, declared
//      adjacency in the visible list).
//
// The form rendering loop and the filter logic pick it up automatically
// after that. Forgetting step 3 is the most common mistake — the field
// will compile, validate, and persist, but won't render because nothing
// puts it in a section.
//
// The 3-level toggle's persistence is asynchronous: the active level is
// loaded from `SharedPreferences` in `initState` via a future and
// defaults to `DetailLevel.basic` until the load completes. That means
// the very first frame may show the basic-level subset even if the user
// last left the form on Detailed; the `setState` after the load corrects
// it within a frame or two. Avoid trying to use the level synchronously
// in `initState`.
//
// Lot pickers have a sentinel-value gotcha: `_createNewSentinel = -1` is
// the "Create New" row's `value`. The `onChanged` handler must
// short-circuit on the sentinel and call `onCreate()` instead of
// propagating the -1 to the parent — otherwise the form would think the
// user picked a lot whose primary key is -1.
//
// Custom field editors and their controllers are lazily constructed via
// `putIfAbsent` on `_customControllers`, so opening a recipe with custom
// fields doesn't allocate unused controllers. They're disposed together
// in `dispose`. If you add a fifth custom-field editor type, both the
// editor render path in `_customFieldEditor` AND the save loop in
// `_save` need to learn how to serialise the new type's value into the
// `value` text column of `UserCustomFieldValues`.
//
// One last asymmetry: typed-in component values (powder, bullet, primer,
// brass) are persisted as `CustomComponents` on save so they appear in
// future `ComponentField` dropdowns. That means a recipe save can write
// to multiple tables (UserLoads + CustomComponents + UserCustomFieldValues),
// and the order of those writes matters when the recipe references a new
// custom component by name.
//
// ============================================================================
// WHO CONSUMES THIS FILE
// ============================================================================
// - `lib/screens/recipes/recipes_list_screen.dart` — pushes
//   `RecipeFormScreen()` via the FAB and `RecipeFormScreen(existing: r)`
//   via list-tile taps.
//
// ============================================================================
// SIDE EFFECTS
// ============================================================================
// - Reads from `RecipeRepository` futures: `allPowderLots`,
//   `allPrimerLots`, `allBulletLots`, `allBrassLots`,
//   `customFieldsForEntity('recipe')`, `customFieldValuesForEntity`.
// - Reads from `ComponentRepository.componentLabels(...)` for the
//   "persist typed-in component as custom" path.
// - Writes via `RecipeRepository.insert` / `.update` / `.createPowderLot`
//   / `.createPrimerLot` / `.createBulletLot` / `.createBrassLot` /
//   `.createCustomField` / `.upsertCustomFieldValue`.
// - Writes via `ComponentRepository.addCustomComponent` for any typed-in
//   powder, primer, bullet, brass, or cartridge that isn't already in
//   the catalog or custom-components table.
// - Reads / writes `SharedPreferences` under `recipe_form_detail_level`
//   to persist the 3-level detail toggle.
// - Pops the navigator on successful save.

import 'package:drift/drift.dart' as drift;
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../database/database.dart';
import '../../repositories/component_repository.dart';
import '../../repositories/recipe_repository.dart';
import '../../services/auto_save_service.dart';
import '../../services/cloud_sync_service.dart';
import '../../services/beginner_mode_service.dart';
import '../../services/ble/ble_service.dart';
import '../../services/ble/garmin_xero_service.dart';
import '../../services/recipe_print_service.dart';
import '../../services/unit_service.dart';
import '../../utils/responsive.dart';
import '../../widgets/auto_save_banner.dart';
import '../../widgets/auto_save_first_time_hint.dart';
import '../../widgets/component_field.dart';
import '../../widgets/primer_cascade_field.dart';
import '../../widgets/pro_gate.dart';

/// Trailing-`<num>gr` matcher used to extract the bullet weight out of a
/// catalog label like `"Berger Long Range Hybrid Target 109gr"`.
final RegExp _bulletWeightSuffix = RegExp(r'(\d+(?:\.\d+)?)\s*gr$');

/// Allowed values for the Primer Size dropdown.
const List<String> _primerSizeOptions = <String>[
  'Small Pistol',
  'Large Pistol',
  'Small Rifle',
  'Large Rifle',
  'Berdan',
];

/// Allowed values for the Primer Pocket Size dropdown.
const List<String> _primerPocketOptions = <String>[
  'SRP',
  'LRP',
  'SP',
  'LP',
  'Other',
];

/// Allowed values for the recipe Status dropdown.
const List<({String value, String label})> _statusOptions = [
  (value: 'active', label: 'Active'),
  (value: 'testing', label: 'Testing'),
  (value: 'retired', label: 'Retired'),
];

/// Allowed values for the Use Case dropdown.
const List<({String value, String label})> _useCaseOptions = [
  (value: 'match', label: 'Match'),
  (value: 'practice', label: 'Practice'),
  (value: 'hunting', label: 'Hunting'),
  (value: 'plinking', label: 'Plinking'),
];

/// Allowed values for the Bolt Lift dropdown.
const List<({String value, String label})> _boltLiftOptions = [
  (value: 'normal', label: 'Normal'),
  (value: 'sticky', label: 'Sticky'),
];

/// Allowed values for the Bore State dropdown.
const List<({String value, String label})> _boreStateOptions = [
  (value: 'clean', label: 'Clean'),
  (value: 'seasoned', label: 'Seasoned'),
  (value: 'fouled', label: 'Fouled'),
];

/// Maps the seed-data primer-size keys (e.g. `"large-rifle"`) onto the
/// human-readable primer-size labels used in the dropdown.
String? _primerSizeLabelForSeedKey(String? seedKey) {
  switch (seedKey) {
    case 'small-pistol':
      return 'Small Pistol';
    case 'large-pistol':
      return 'Large Pistol';
    case 'small-rifle':
      return 'Small Rifle';
    case 'large-rifle':
      return 'Large Rifle';
    case 'berdan':
      return 'Berdan';
    default:
      return null;
  }
}

/// Three-level detail toggle.
///
/// * [basic] — only the most-used fields (Recipe Name, Caliber, Powder,
///   Charge, Bullet, Bullet Weight, Primer, Brass, COAL).
/// * [detailed] — adds CBTO, Seating Depth, Primer Size, Primer Depth,
///   Primer Pocket Size, Shoulder Bump, Mandrel Size, Status, Use Case,
///   and the four lot pickers.
/// * [all] — every field including pressure indicators, process/equipment
///   provenance, advanced bullet sorting, runout, distance to lands, etc.
enum DetailLevel {
  basic,
  detailed,
  all;

  static const String _prefsKey = 'recipe_form_detail_level';

  String get prefsValue {
    switch (this) {
      case DetailLevel.basic:
        return 'basic';
      case DetailLevel.detailed:
        return 'detailed';
      case DetailLevel.all:
        return 'all';
    }
  }

  static DetailLevel fromPrefs(String? raw) {
    switch (raw) {
      case 'basic':
        return DetailLevel.basic;
      case 'detailed':
        return DetailLevel.detailed;
      case 'all':
        return DetailLevel.all;
      default:
        return DetailLevel.basic;
    }
  }

  /// True when a field tagged at [fieldLevel] should be visible at the
  /// current [DetailLevel]. Levels are nested: basic ⊂ detailed ⊂ all.
  bool includes(DetailLevel fieldLevel) {
    return fieldLevel.index <= index;
  }
}

/// Stable identifiers for every field on the recipe form.
///
/// Keeping these as an enum (rather than free-form strings) makes the
/// "section → field IDs" mapping refactor-safe and lets the analyzer
/// catch missing wiring when new fields are added.
enum _FieldId {
  // Load identification
  recipeName,
  caliber,
  status,
  useCase,
  // Powder
  powder,
  powderCharge,
  powderLot,
  chargeTolerance,
  // Primer
  primer,
  primerSize,
  primerDepth,
  primerLot,
  primerSeatingForce,
  // Bullet
  bullet,
  bulletWeight,
  bulletLot,
  bulletLength,
  bulletBaseToOgive,
  bulletBearingSurface,
  bulletMeplatTrimmed,
  bulletPointed,
  bulletWeightSorted,
  bulletWeightTolerance,
  bulletBtoSorted,
  bulletBtoTolerance,
  bulletDiameterSorted,
  seatingDepth,
  cbto,
  // Brass
  brass,
  brassLot,
  primerPocketSize,
  shoulderBump,
  mandrelSize,
  bushingSize,
  // Loaded round dimensions
  coal,
  distanceToLands,
  jumpToLands,
  loadedNeckDiameter,
  bulletRunout,
  // Pressure indicators
  pressureNotes,
  boltLift,
  ejectorMarks,
  crateredPrimers,
  webExpansion,
  primerFlatness,
  // Process / equipment / provenance
  loadingDate,
  roundsLoadedInBatch,
  pressUsed,
  sizingDieUsed,
  seatingDieUsed,
  scaleUsed,
  scaleCalibrationDate,
  comparatorInsertUsed,
  chronographUsed,
  boreState,
  loadedBy,
  // Notes
  notes,
}

/// Declarative description of one field on the recipe form.
///
/// New fields are added by:
///   1. Append a new value to [_FieldId].
///   2. Add a `_FieldDef` for it inside `_buildFieldDefs`.
///   3. Add the id to whichever `_Section.fieldIds` list it belongs in.
///   4. (Optional) extend that section's `pairs` list with this field
///      and a logically related sibling so the two render side by side
///      on desktop layouts.
///
/// No other changes to the form rendering loop are required.
class _FieldDef {
  const _FieldDef({
    required this.id,
    required this.label,
    required this.level,
    required this.aliases,
    required this.builder,
    this.beginnerTooltip,
  });

  /// Stable id used for filter matching, section membership and keys.
  final _FieldId id;

  /// User-visible label, used both as the field's label text and as the
  /// primary search target.
  final String label;

  /// Lowest detail level at which this field is visible.
  final DetailLevel level;

  /// Extra search tokens (in addition to [label]) that match this field
  /// in the filter input. Always lower-case.
  final List<String> aliases;

  /// Builds the editor widget. Receives the current [BuildContext] so
  /// builders can reach providers (e.g. `ComponentRepository`).
  final Widget Function(BuildContext context) builder;

  /// Plain-language explainer shown next to the field when Beginner
  /// Mode is on (see [BeginnerModeService]). Tooltips explain *why* a
  /// field matters, not just what it is — see CLAUDE.md beginner-first
  /// guidance. Null on basic-level fields where the label is enough.
  final String? beginnerTooltip;
}

/// Declarative description of one collapsible section on the form.
class _Section {
  const _Section({
    required this.id,
    required this.title,
    required this.fieldIds,
    this.pairs = const <List<_FieldId>>[],
  });

  /// Stable id used for `PageStorageKey` so each section's expansion
  /// state survives scrolling and rebuilds.
  final String id;

  /// Header label, shown in the brass-tinted chip on the section header.
  final String title;

  /// Field ids that live in this section, in display order.
  final List<_FieldId> fieldIds;

  /// Optional 2-up pairings rendered side-by-side on screens at the
  /// desktop breakpoint (≥ 1024 px wide). Each inner list is a pair of
  /// field IDs that should appear in the same `Row` when both fields
  /// are visible (filtered + at the active detail level). Phones and
  /// narrow tablets fall back to the original stacked layout.
  ///
  /// A pair is honored only when *both* of its fields are visible —
  /// if filter or detail-level rules hide one, the surviving field
  /// stacks normally on its own row. Pairs never re-flow, so the
  /// declared section order still controls the visual sequence.
  final List<List<_FieldId>> pairs;
}

/// Identifier used in the `_Section.id` to distinguish the special
/// custom-fields section, which is rendered with bespoke logic instead of
/// driving off the FieldDef map.
const String _customFieldsSectionId = 'custom_fields';

/// One slot in a section's render plan — either a single field or a
/// 2-up pair. The renderer (`_buildSection` → `_buildRenderItem`) walks
/// a `List<_SectionRenderItem>` and emits Material widgets accordingly.
sealed class _SectionRenderItem {
  const _SectionRenderItem();
}

class _SingleFieldItem extends _SectionRenderItem {
  const _SingleFieldItem(this.field);
  final _FieldDef field;
}

class _PairFieldItem extends _SectionRenderItem {
  const _PairFieldItem(this.first, this.second);
  final _FieldDef first;
  final _FieldDef second;
}

class RecipeFormScreen extends StatefulWidget {
  const RecipeFormScreen({super.key, this.existing});

  final UserLoadRow? existing;

  @override
  State<RecipeFormScreen> createState() => _RecipeFormScreenState();
}

class _RecipeFormScreenState extends State<RecipeFormScreen> {
  final _formKey = GlobalKey<FormState>();
  final _searchController = TextEditingController();

  // ─────────────────────── Text controllers ───────────────────────

  late final TextEditingController _name;
  late final TextEditingController _caliber;
  late final TextEditingController _powder;
  late final TextEditingController _powderCharge;
  late final TextEditingController _bullet;
  late final TextEditingController _bulletWeight;
  late final TextEditingController _primer;
  late final TextEditingController _brass;
  late final TextEditingController _coal;
  late final TextEditingController _cbto;
  late final TextEditingController _seatingDepth;
  late final TextEditingController _primerDepth;
  late final TextEditingController _shoulderBump;
  late final TextEditingController _mandrelSize;
  late final TextEditingController _notes;

  // New v4 numeric / text controllers.
  late final TextEditingController _chargeTolerance;
  late final TextEditingController _primerSeatingForce;
  late final TextEditingController _bulletLength;
  late final TextEditingController _bulletBaseToOgive;
  late final TextEditingController _bulletBearingSurface;
  late final TextEditingController _bulletWeightTolerance;
  late final TextEditingController _bulletBtoTolerance;
  late final TextEditingController _bushingSize;
  late final TextEditingController _distanceToLands;
  late final TextEditingController _jumpToLands;
  late final TextEditingController _loadedNeckDiameter;
  late final TextEditingController _bulletRunout;
  late final TextEditingController _pressureNotes;
  late final TextEditingController _webExpansion;
  late final TextEditingController _roundsLoadedInBatch;
  late final TextEditingController _pressUsed;
  late final TextEditingController _sizingDieUsed;
  late final TextEditingController _seatingDieUsed;
  late final TextEditingController _scaleUsed;
  late final TextEditingController _comparatorInsertUsed;
  late final TextEditingController _chronographUsed;
  late final TextEditingController _loadedBy;

  // ─────────────────────── Discrete-state values ───────────────────────

  /// Picked from the dropdown; `null` means user hasn't selected one yet.
  String? _primerSize;
  String? _primerPocketSize;
  String? _status;
  String? _useCase;
  String? _boltLift;
  String? _boreState;

  bool _bulletMeplatTrimmed = false;
  bool _bulletPointed = false;
  bool _bulletWeightSorted = false;
  bool _bulletBtoSorted = false;
  bool _bulletDiameterSorted = false;
  bool _ejectorMarks = false;
  bool _crateredPrimers = false;

  /// 1-5 scale; null when unset. Stored as int.
  int? _primerFlatness;

  DateTime? _loadingDate;
  DateTime? _scaleCalibrationDate;

  // Lot picker state. Each holds the currently-selected lot id (or null).
  int? _powderLotId;
  int? _primerLotId;
  int? _bulletLotId;
  int? _brassLotId;

  /// Caches loaded from the DB on first build. Each future is kicked off
  /// in `initState` so the dropdowns can render synchronously the first
  /// time they're shown.
  late Future<List<PowderLotRow>> _powderLotsFuture;
  late Future<List<PrimerLotRow>> _primerLotsFuture;
  late Future<List<BulletLotRow>> _bulletLotsFuture;
  late Future<List<BrassLotRow>> _brassLotsFuture;

  // Custom fields state.
  late Future<List<UserCustomFieldRow>> _customFieldsFuture;
  /// fieldId -> in-memory mutable string value. Boolean fields use 'true'
  /// / 'false', date fields use ISO-8601, number fields use the raw text.
  final Map<int, String?> _customValues = {};
  /// fieldId -> per-field controller for text/number editors.
  final Map<int, TextEditingController> _customControllers = {};

  /// Active detail level. Loaded from SharedPreferences in [initState];
  /// defaults to [DetailLevel.basic] until the load completes.
  DetailLevel _detailLevel = DetailLevel.basic;

  /// Current filter query. When non-empty, filter takes priority over
  /// [_detailLevel] — every field whose label/alias matches shows.
  String _query = '';

  bool _busy = false;

  late final AutoSaveController _autoSave;

  @override
  void initState() {
    super.initState();
    final e = widget.existing;
    _name = TextEditingController(text: e?.name ?? '');
    _caliber = TextEditingController(text: e?.caliber ?? '');
    _powder = TextEditingController(text: e?.powder ?? '');
    _powderCharge = TextEditingController(
      text: e?.powderChargeGr?.toString() ?? '',
    );
    _bullet = TextEditingController(text: e?.bullet ?? '');
    _bulletWeight = TextEditingController(
      text: e?.bulletWeightGr?.toString() ?? '',
    );
    _primer = TextEditingController(text: e?.primer ?? '');
    _brass = TextEditingController(text: e?.brass ?? '');
    _coal = TextEditingController(text: e?.coalIn?.toString() ?? '');
    _cbto = TextEditingController(text: e?.cbtoIn?.toString() ?? '');
    _seatingDepth = TextEditingController(
      text: e?.seatingDepthIn?.toString() ?? '',
    );
    _primerDepth = TextEditingController(
      text: e?.primerDepthCps?.toString() ?? '',
    );
    _shoulderBump = TextEditingController(
      text: e?.shoulderBumpIn?.toString() ?? '',
    );
    _mandrelSize = TextEditingController(
      text: e?.mandrelSizeIn?.toString() ?? '',
    );
    _notes = TextEditingController(text: e?.notes ?? '');

    // ── New v4 controllers ──
    _chargeTolerance = TextEditingController(
      text: e?.chargeToleranceGr?.toString() ?? '',
    );
    _primerSeatingForce = TextEditingController(
      text: e?.primerSeatingForceLbs?.toString() ?? '',
    );
    _bulletLength = TextEditingController(
      text: e?.bulletLengthIn?.toString() ?? '',
    );
    _bulletBaseToOgive = TextEditingController(
      text: e?.bulletBaseToOgiveIn?.toString() ?? '',
    );
    _bulletBearingSurface = TextEditingController(
      text: e?.bulletBearingSurfaceIn?.toString() ?? '',
    );
    _bulletWeightTolerance = TextEditingController(
      text: e?.bulletWeightToleranceGr?.toString() ?? '',
    );
    _bulletBtoTolerance = TextEditingController(
      text: e?.bulletBtoToleranceIn?.toString() ?? '',
    );
    _bushingSize = TextEditingController(
      text: e?.bushingSizeIn?.toString() ?? '',
    );
    _distanceToLands = TextEditingController(
      text: e?.distanceToLandsIn?.toString() ?? '',
    );
    _jumpToLands = TextEditingController(
      text: e?.jumpToLandsIn?.toString() ?? '',
    );
    _loadedNeckDiameter = TextEditingController(
      text: e?.loadedNeckDiameterIn?.toString() ?? '',
    );
    _bulletRunout = TextEditingController(
      text: e?.bulletRunoutTirIn?.toString() ?? '',
    );
    _pressureNotes = TextEditingController(text: e?.pressureNotes ?? '');
    _webExpansion = TextEditingController(
      text: e?.webExpansion200In?.toString() ?? '',
    );
    _roundsLoadedInBatch = TextEditingController(
      text: e?.roundsLoadedInBatch?.toString() ?? '',
    );
    _pressUsed = TextEditingController(text: e?.pressUsed ?? '');
    _sizingDieUsed = TextEditingController(text: e?.sizingDieUsed ?? '');
    _seatingDieUsed = TextEditingController(text: e?.seatingDieUsed ?? '');
    _scaleUsed = TextEditingController(text: e?.scaleUsed ?? '');
    _comparatorInsertUsed =
        TextEditingController(text: e?.comparatorInsertUsed ?? '');
    _chronographUsed = TextEditingController(text: e?.chronographUsed ?? '');
    _loadedBy = TextEditingController(text: e?.loadedBy ?? '');

    // Discrete state.
    _primerSize = null; // populated below from existing primer text
    _primerPocketSize = null;
    _status = e?.status;
    _useCase = e?.useCase;
    _boltLift = e?.boltLift;
    _boreState = e?.boreState;
    _bulletMeplatTrimmed = e?.bulletMeplatTrimmed ?? false;
    _bulletPointed = e?.bulletPointed ?? false;
    _bulletWeightSorted = e?.bulletWeightSorted ?? false;
    _bulletBtoSorted = e?.bulletBtoSorted ?? false;
    _bulletDiameterSorted = e?.bulletDiameterSorted ?? false;
    _ejectorMarks = e?.ejectorMarks ?? false;
    _crateredPrimers = e?.crateredPrimers ?? false;
    _primerFlatness = e?.primerFlatness;
    _loadingDate = e?.loadingDate;
    _scaleCalibrationDate = e?.scaleCalibrationDate;
    _powderLotId = e?.powderLotId;
    _primerLotId = e?.primerLotId;
    _bulletLotId = e?.bulletLotId;
    _brassLotId = e?.brassLotId;

    // Kick off DB queries immediately.
    final repo = context.read<RecipeRepository>();
    _powderLotsFuture = repo.allPowderLots();
    _primerLotsFuture = repo.allPrimerLots();
    _bulletLotsFuture = repo.allBulletLots();
    _brassLotsFuture = repo.allBrassLots();
    _customFieldsFuture = repo.customFieldsForEntity('recipe');

    // Hydrate the user's saved detail-level preference. Done lazily so the
    // first frame doesn't block on disk I/O.
    // ignore: discarded_futures
    _loadDetailLevel();

    // Hydrate any existing custom-field values for an edit.
    if (e != null) {
      // ignore: discarded_futures
      _loadCustomValues(repo, e.id);
    }

    _autoSave = AutoSaveController(
      service: context.read<AutoSaveService>(),
      onSave: _runAutoSave,
      initialSavedRowId: widget.existing?.id,
      // Schedule a Cloud Sync push 5s after the save lands. No-op
      // when the user hasn't enabled sync — see CloudSyncService.
      onSavedToCloud: () =>
          context.read<CloudSyncService>().scheduleSyncUp(),
    );
    // Wire every text controller (including custom fields, see
    // _buildCustomFieldEditor's `putIfAbsent` calls) to autosave.
    for (final c in <TextEditingController>[
      _name,
      _caliber,
      _powder,
      _powderCharge,
      _bullet,
      _bulletWeight,
      _primer,
      _brass,
      _coal,
      _cbto,
      _seatingDepth,
      _primerDepth,
      _shoulderBump,
      _mandrelSize,
      _notes,
      _chargeTolerance,
      _primerSeatingForce,
      _bulletLength,
      _bulletBaseToOgive,
      _bulletBearingSurface,
      _bulletWeightTolerance,
      _bulletBtoTolerance,
      _bushingSize,
      _distanceToLands,
      _jumpToLands,
      _loadedNeckDiameter,
      _bulletRunout,
      _pressureNotes,
      _webExpansion,
      _roundsLoadedInBatch,
      _pressUsed,
      _sizingDieUsed,
      _seatingDieUsed,
      _scaleUsed,
      _comparatorInsertUsed,
      _chronographUsed,
      _loadedBy,
    ]) {
      c.addListener(_autoSave.notifyDirty);
    }
  }

  /// Build a `UserLoadsCompanion` from the current state.
  UserLoadsCompanion _buildCompanion() {
    return UserLoadsCompanion(
      name: drift.Value(_name.text.trim()),
      caliber: drift.Value(_trimToNull(_caliber)),
      powder: drift.Value(_trimToNull(_powder)),
      powderChargeGr: drift.Value(_parseDouble(_powderCharge)),
      bullet: drift.Value(_trimToNull(_bullet)),
      bulletWeightGr: drift.Value(_parseDouble(_bulletWeight)),
      primer: drift.Value(_trimToNull(_primer)),
      brass: drift.Value(_trimToNull(_brass)),
      coalIn: drift.Value(_parseDouble(_coal)),
      cbtoIn: drift.Value(_parseDouble(_cbto)),
      seatingDepthIn: drift.Value(_parseDouble(_seatingDepth)),
      primerDepthCps: drift.Value(_parseDouble(_primerDepth)),
      shoulderBumpIn: drift.Value(_parseDouble(_shoulderBump)),
      mandrelSizeIn: drift.Value(_parseDouble(_mandrelSize)),
      notes: drift.Value(_trimToNull(_notes)),
      status: drift.Value(_status),
      useCase: drift.Value(_useCase),
      powderLotId: drift.Value(_powderLotId),
      chargeToleranceGr: drift.Value(_parseDouble(_chargeTolerance)),
      primerLotId: drift.Value(_primerLotId),
      primerSeatingForceLbs: drift.Value(_parseDouble(_primerSeatingForce)),
      bulletLotId: drift.Value(_bulletLotId),
      bulletLengthIn: drift.Value(_parseDouble(_bulletLength)),
      bulletBaseToOgiveIn: drift.Value(_parseDouble(_bulletBaseToOgive)),
      bulletBearingSurfaceIn: drift.Value(_parseDouble(_bulletBearingSurface)),
      bulletMeplatTrimmed: drift.Value(_bulletMeplatTrimmed),
      bulletPointed: drift.Value(_bulletPointed),
      bulletWeightSorted: drift.Value(_bulletWeightSorted),
      bulletWeightToleranceGr:
          drift.Value(_parseDouble(_bulletWeightTolerance)),
      bulletBtoSorted: drift.Value(_bulletBtoSorted),
      bulletBtoToleranceIn: drift.Value(_parseDouble(_bulletBtoTolerance)),
      bulletDiameterSorted: drift.Value(_bulletDiameterSorted),
      brassLotId: drift.Value(_brassLotId),
      distanceToLandsIn: drift.Value(_parseDouble(_distanceToLands)),
      jumpToLandsIn: drift.Value(_parseDouble(_jumpToLands)),
      loadedNeckDiameterIn: drift.Value(_parseDouble(_loadedNeckDiameter)),
      bulletRunoutTirIn: drift.Value(_parseDouble(_bulletRunout)),
      bushingSizeIn: drift.Value(_parseDouble(_bushingSize)),
      pressureNotes: drift.Value(_trimToNull(_pressureNotes)),
      boltLift: drift.Value(_boltLift),
      ejectorMarks: drift.Value(_ejectorMarks),
      crateredPrimers: drift.Value(_crateredPrimers),
      webExpansion200In: drift.Value(_parseDouble(_webExpansion)),
      primerFlatness: drift.Value(_primerFlatness),
      loadingDate: drift.Value(_loadingDate),
      roundsLoadedInBatch: drift.Value(_parseInt(_roundsLoadedInBatch)),
      pressUsed: drift.Value(_trimToNull(_pressUsed)),
      sizingDieUsed: drift.Value(_trimToNull(_sizingDieUsed)),
      seatingDieUsed: drift.Value(_trimToNull(_seatingDieUsed)),
      scaleUsed: drift.Value(_trimToNull(_scaleUsed)),
      scaleCalibrationDate: drift.Value(_scaleCalibrationDate),
      comparatorInsertUsed: drift.Value(_trimToNull(_comparatorInsertUsed)),
      chronographUsed: drift.Value(_trimToNull(_chronographUsed)),
      boreState: drift.Value(_boreState),
      loadedBy: drift.Value(_trimToNull(_loadedBy)),
    );
  }

  /// Autosave entry point. Skips the save if the recipe has no name
  /// (it's not a complete enough record to persist yet). Insert on
  /// first save, update on subsequent.
  Future<int?> _runAutoSave() async {
    final name = _name.text.trim();
    if (name.isEmpty) return null;
    final repo = context.read<RecipeRepository>();
    final entry = _buildCompanion();
    int recipeId;
    final existingId = _autoSave.currentRowId;
    if (existingId == null) {
      recipeId = await repo.insert(entry);
    } else {
      recipeId = existingId;
      await repo.update(recipeId, entry);
    }
    // Sync custom field values too — for partial-save flows we want
    // the user's typed numbers / text to land alongside the recipe.
    for (final entry in _customControllers.entries) {
      final fieldId = entry.key;
      final text = entry.value.text.trim();
      _customValues[fieldId] = text.isEmpty ? null : text;
    }
    for (final entry in _customValues.entries) {
      await repo.setCustomFieldValue(
        fieldId: entry.key,
        entityId: recipeId,
        value: entry.value,
      );
    }
    return recipeId;
  }

  @override
  void dispose() {
    _autoSave.dispose();
    _searchController.dispose();
    for (final c in [
      _name,
      _caliber,
      _powder,
      _powderCharge,
      _bullet,
      _bulletWeight,
      _primer,
      _brass,
      _coal,
      _cbto,
      _seatingDepth,
      _primerDepth,
      _shoulderBump,
      _mandrelSize,
      _notes,
      _chargeTolerance,
      _primerSeatingForce,
      _bulletLength,
      _bulletBaseToOgive,
      _bulletBearingSurface,
      _bulletWeightTolerance,
      _bulletBtoTolerance,
      _bushingSize,
      _distanceToLands,
      _jumpToLands,
      _loadedNeckDiameter,
      _bulletRunout,
      _pressureNotes,
      _webExpansion,
      _roundsLoadedInBatch,
      _pressUsed,
      _sizingDieUsed,
      _seatingDieUsed,
      _scaleUsed,
      _comparatorInsertUsed,
      _chronographUsed,
      _loadedBy,
    ]) {
      c.dispose();
    }
    for (final c in _customControllers.values) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _loadDetailLevel() async {
    final prefs = await SharedPreferences.getInstance();
    final stored = prefs.getString(DetailLevel._prefsKey);
    if (!mounted) return;
    // Beginner Mode anchors the form to Basic — even if the user (or a
    // prior session) set a higher level explicitly, beginners see the
    // basics first. They can still flip the segmented toggle in-screen
    // to see more, but the default is the on-ramp value. Power users
    // turn Beginner Mode off in Settings to get the prior behaviour.
    final beginner = context.read<BeginnerModeService>();
    if (beginner.isEnabled && stored == null) {
      setState(() => _detailLevel = DetailLevel.basic);
      return;
    }
    setState(() => _detailLevel = DetailLevel.fromPrefs(stored));
  }

  Future<void> _persistDetailLevel(DetailLevel level) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(DetailLevel._prefsKey, level.prefsValue);
  }

  Future<void> _loadCustomValues(RecipeRepository repo, int entityId) async {
    final values = await repo.customFieldValuesForEntity('recipe', entityId);
    if (!mounted) return;
    setState(() {
      _customValues
        ..clear()
        ..addAll(values);
    });
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

  String? _trimToNull(TextEditingController c) {
    final t = c.text.trim();
    return t.isEmpty ? null : t;
  }

  /// When the user picks a bullet from the catalog, parse the trailing
  /// `<num>gr` and shove it into the Bullet Weight field. Catalog labels
  /// always end with `<num>gr`; typed-in custom values are left alone.
  void _onBulletSelected(String label) {
    final match = _bulletWeightSuffix.firstMatch(label);
    if (match == null) return;
    final weight = match.group(1);
    if (weight == null) return;
    setState(() => _bulletWeight.text = weight);
  }

  /// When the user picks a primer like `"Federal #210M"`, look it up in
  /// the catalog and pre-fill Primer Size from its `Primers.size` field.
  Future<void> _onPrimerSelected(String label) async {
    final repo = context.read<ComponentRepository>();
    final row = await repo.primerByLabel(label);
    if (!mounted || row == null) return;
    final mapped = _primerSizeLabelForSeedKey(row.size);
    if (mapped != null) {
      setState(() => _primerSize = mapped);
    }
  }

  /// Print-to-paper. Flushes any pending autosave so the printed copy
  /// matches the current screen, then re-reads the row from the DB and
  /// hands it to `RecipePrintService.share`. Errors fall through to a
  /// snackbar — print failure is rarely fatal so we don't want to lock
  /// the form.
  Future<void> _printRecipe() async {
    final messenger = ScaffoldMessenger.of(context);
    final repo = context.read<RecipeRepository>();
    setState(() => _busy = true);
    try {
      // Make sure autosave has committed any in-flight edits before we
      // read the row back. Without this, recently-typed values wouldn't
      // appear on the printed page.
      await _autoSave.flush();
      var rowId = _autoSave.currentRowId ?? widget.existing?.id;
      if (rowId == null) {
        messenger.showSnackBar(
          const SnackBar(
            content: Text('Save the recipe first, then print.'),
          ),
        );
        return;
      }
      final row = await repo.getById(rowId);
      if (row == null) {
        messenger.showSnackBar(
          const SnackBar(content: Text('Could not find this recipe.')),
        );
        return;
      }
      await RecipePrintService().share(row);
    } catch (e) {
      messenger.showSnackBar(
        SnackBar(content: Text('Print failed: $e')),
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Pro: import shot velocities from a Garmin Xero `.fit` file.
  /// Parses the file, computes avg / ES / SD, and rolls them into the
  /// existing Notes + Chronograph Used fields. We don't have a
  /// dedicated velocity-on-recipe schema today (per-recipe velocity
  /// lives in load development sessions), so notes is the right home
  /// until we grow dedicated columns.
  Future<void> _onImportGarminFit() async {
    if (!await ensurePro(context)) return;
    if (!mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    final ble = context.read<BleService>();
    setState(() => _busy = true);
    try {
      final picked = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: const ['fit'],
        withData: false,
      );
      if (picked == null || picked.files.isEmpty) return;
      final path = picked.files.single.path;
      if (path == null) {
        messenger.showSnackBar(
          const SnackBar(content: Text("Couldn't read the selected file.")),
        );
        return;
      }
      final session = await GarminXeroService(ble).importFitFile(path);
      if (!mounted) return;
      final summary =
          'Garmin Xero · ${session.shots.length} shots · '
          'avg ${session.averageFps.toStringAsFixed(0)} fps · '
          'ES ${session.extremeSpreadFps.toStringAsFixed(0)} · '
          'SD ${session.standardDeviationFps.toStringAsFixed(1)}';
      // Append to notes rather than overwrite so existing free-form
      // text isn't blown away.
      final existing = _notes.text.trim();
      _notes.text =
          existing.isEmpty ? summary : '$existing\n\n$summary';
      // Default-fill the chronograph-used field if it's empty so the
      // recipe records the source.
      if (_chronographUsed.text.trim().isEmpty) {
        _chronographUsed.text = 'Garmin Xero C1 Pro';
      }
      _autoSave.notifyDirty();
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            'Imported ${session.shots.length} shots. '
            'Avg ${session.averageFps.toStringAsFixed(0)} fps.',
          ),
        ),
      );
    } on GarminXeroParseException catch (e) {
      messenger.showSnackBar(SnackBar(content: Text(e.userMessage)));
    } catch (e) {
      messenger.showSnackBar(
        SnackBar(content: Text("Couldn't import that file: $e")),
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() => _busy = true);

    final repo = context.read<RecipeRepository>();
    final components = context.read<ComponentRepository>();
    final messenger = ScaffoldMessenger.of(context);
    final navigator = Navigator.of(context);

    // Persist typed-in component values as custom for future dropdowns.
    Future<void> ensureCustom(String kind, TextEditingController c) async {
      final v = c.text.trim();
      if (v.isEmpty) return;
      final known = await components.componentLabels(kind);
      if (!known.contains(v)) {
        await components.addCustomComponent(kind, v);
      }
    }

    await Future.wait([
      ensureCustom('cartridge', _caliber),
      ensureCustom('powder', _powder),
      ensureCustom('bullet', _bullet),
      ensureCustom('primer', _primer),
      ensureCustom('brass', _brass),
    ]);

    final entryLegacy = UserLoadsCompanion(
      name: drift.Value(_name.text.trim()),
      caliber: drift.Value(_trimToNull(_caliber)),
      powder: drift.Value(_trimToNull(_powder)),
      powderChargeGr: drift.Value(_parseDouble(_powderCharge)),
      bullet: drift.Value(_trimToNull(_bullet)),
      bulletWeightGr: drift.Value(_parseDouble(_bulletWeight)),
      primer: drift.Value(_trimToNull(_primer)),
      brass: drift.Value(_trimToNull(_brass)),
      coalIn: drift.Value(_parseDouble(_coal)),
      cbtoIn: drift.Value(_parseDouble(_cbto)),
      seatingDepthIn: drift.Value(_parseDouble(_seatingDepth)),
      primerDepthCps: drift.Value(_parseDouble(_primerDepth)),
      shoulderBumpIn: drift.Value(_parseDouble(_shoulderBump)),
      mandrelSizeIn: drift.Value(_parseDouble(_mandrelSize)),
      notes: drift.Value(_trimToNull(_notes)),
      // Phase 1 expansion fields.
      status: drift.Value(_status),
      useCase: drift.Value(_useCase),
      powderLotId: drift.Value(_powderLotId),
      chargeToleranceGr: drift.Value(_parseDouble(_chargeTolerance)),
      primerLotId: drift.Value(_primerLotId),
      primerSeatingForceLbs: drift.Value(_parseDouble(_primerSeatingForce)),
      bulletLotId: drift.Value(_bulletLotId),
      bulletLengthIn: drift.Value(_parseDouble(_bulletLength)),
      bulletBaseToOgiveIn: drift.Value(_parseDouble(_bulletBaseToOgive)),
      bulletBearingSurfaceIn: drift.Value(_parseDouble(_bulletBearingSurface)),
      bulletMeplatTrimmed: drift.Value(_bulletMeplatTrimmed),
      bulletPointed: drift.Value(_bulletPointed),
      bulletWeightSorted: drift.Value(_bulletWeightSorted),
      bulletWeightToleranceGr:
          drift.Value(_parseDouble(_bulletWeightTolerance)),
      bulletBtoSorted: drift.Value(_bulletBtoSorted),
      bulletBtoToleranceIn: drift.Value(_parseDouble(_bulletBtoTolerance)),
      bulletDiameterSorted: drift.Value(_bulletDiameterSorted),
      brassLotId: drift.Value(_brassLotId),
      distanceToLandsIn: drift.Value(_parseDouble(_distanceToLands)),
      jumpToLandsIn: drift.Value(_parseDouble(_jumpToLands)),
      loadedNeckDiameterIn: drift.Value(_parseDouble(_loadedNeckDiameter)),
      bulletRunoutTirIn: drift.Value(_parseDouble(_bulletRunout)),
      bushingSizeIn: drift.Value(_parseDouble(_bushingSize)),
      pressureNotes: drift.Value(_trimToNull(_pressureNotes)),
      boltLift: drift.Value(_boltLift),
      ejectorMarks: drift.Value(_ejectorMarks),
      crateredPrimers: drift.Value(_crateredPrimers),
      webExpansion200In: drift.Value(_parseDouble(_webExpansion)),
      primerFlatness: drift.Value(_primerFlatness),
      loadingDate: drift.Value(_loadingDate),
      roundsLoadedInBatch: drift.Value(_parseInt(_roundsLoadedInBatch)),
      pressUsed: drift.Value(_trimToNull(_pressUsed)),
      sizingDieUsed: drift.Value(_trimToNull(_sizingDieUsed)),
      seatingDieUsed: drift.Value(_trimToNull(_seatingDieUsed)),
      scaleUsed: drift.Value(_trimToNull(_scaleUsed)),
      scaleCalibrationDate: drift.Value(_scaleCalibrationDate),
      comparatorInsertUsed: drift.Value(_trimToNull(_comparatorInsertUsed)),
      chronographUsed: drift.Value(_trimToNull(_chronographUsed)),
      boreState: drift.Value(_boreState),
      loadedBy: drift.Value(_trimToNull(_loadedBy)),
    );

    int recipeId;
    final existingId = _autoSave.currentRowId;
    if (existingId == null) {
      recipeId = await repo.insert(entryLegacy);
      messenger.showSnackBar(const SnackBar(content: Text('Recipe Saved.')));
    } else {
      recipeId = existingId;
      await repo.update(recipeId, entryLegacy);
      messenger.showSnackBar(const SnackBar(content: Text('Recipe Updated.')));
    }

    // Persist custom-field values. We sync controller text into the
    // _customValues map for text/number fields before writing.
    for (final entry in _customControllers.entries) {
      final fieldId = entry.key;
      final text = entry.value.text.trim();
      _customValues[fieldId] = text.isEmpty ? null : text;
    }
    for (final entry in _customValues.entries) {
      await repo.setCustomFieldValue(
        fieldId: entry.key,
        entityId: recipeId,
        value: entry.value,
      );
    }

    if (mounted) navigator.pop();
  }

  // ─────────────────────── Form layout (declarative) ───────────────────────

  /// Builds the per-build map of `_FieldId -> _FieldDef`.
  ///
  /// Lives inside the widget so each field's builder can capture local
  /// state (controllers, the primer-size dropdown value, etc.) without
  /// resorting to globals. Cheap to rebuild — every entry is a const-ish
  /// record of metadata plus a closure.
  ///
  /// **Note on units (2026-05-07 migration):** field LABELS in this
  /// form are unit-aware via `context.watch<UnitService>()`. The
  /// canonical storage in the `UserLoads` table is unchanged — values
  /// continue to persist as imperial (grains, inches), since shifting
  /// the storage units would invalidate every existing recipe. The
  /// suffix text on each field is purely cosmetic at this point;
  /// migrating to display-conversion is tracked as follow-up work.
  Map<_FieldId, _FieldDef> _buildFieldDefs() {
    return {
      // ─────── Load Identification ───────
      _FieldId.recipeName: _FieldDef(
        id: _FieldId.recipeName,
        label: 'Recipe Name',
        level: DetailLevel.basic,
        aliases: const ['title', 'name'],
        builder: (ctx) => TextFormField(
          controller: _name,
          decoration: const InputDecoration(labelText: 'Recipe Name *'),
          validator: (v) =>
              (v == null || v.trim().isEmpty) ? 'Required' : null,
        ),
      ),
      _FieldId.caliber: _FieldDef(
        id: _FieldId.caliber,
        label: 'Caliber',
        level: DetailLevel.basic,
        aliases: const ['cartridge', 'chambering'],
        builder: (ctx) => ComponentField(
          kind: 'cartridge',
          label: 'Caliber',
          controller: _caliber,
        ),
      ),
      _FieldId.status: _FieldDef(
        id: _FieldId.status,
        label: 'Status',
        level: DetailLevel.detailed,
        aliases: const ['active', 'testing', 'retired', 'state'],
        builder: (ctx) => DropdownButtonFormField<String>(
          initialValue: _status,
          isExpanded: true,
          decoration: const InputDecoration(labelText: 'Status'),
          items: [
            for (final s in _statusOptions)
              DropdownMenuItem(value: s.value, child: Text(s.label)),
          ],
          onChanged: (v) {
            setState(() => _status = v);
            _autoSave.notifyDirty();
          },
        ),
      ),
      _FieldId.useCase: _FieldDef(
        id: _FieldId.useCase,
        label: 'Use Case',
        level: DetailLevel.detailed,
        aliases: const ['match', 'practice', 'hunting', 'plinking', 'purpose'],
        builder: (ctx) => DropdownButtonFormField<String>(
          initialValue: _useCase,
          isExpanded: true,
          decoration: const InputDecoration(labelText: 'Use Case'),
          items: [
            for (final s in _useCaseOptions)
              DropdownMenuItem(value: s.value, child: Text(s.label)),
          ],
          onChanged: (v) {
            setState(() => _useCase = v);
            _autoSave.notifyDirty();
          },
        ),
      ),

      // ─────── Powder ───────
      _FieldId.powder: _FieldDef(
        id: _FieldId.powder,
        label: 'Powder',
        level: DetailLevel.basic,
        aliases: const ['propellant'],
        builder: (ctx) => ComponentField(
          kind: 'powder',
          label: 'Powder',
          controller: _powder,
        ),
      ),
      _FieldId.powderCharge: _FieldDef(
        id: _FieldId.powderCharge,
        label: 'Powder Charge',
        level: DetailLevel.basic,
        aliases: const ['charge', 'grains', 'gr', 'weight'],
        // TODO(units): display labels only; canonical storage unchanged.
        builder: (ctx) {
          final wt = unitDisplayLabel(
              ctx.watch<UnitService>().unitFor(UnitCategory.bulletWeight));
          return TextFormField(
            controller: _powderCharge,
            decoration: InputDecoration(
              labelText: 'Powder Charge ($wt)',
              suffixText: wt,
            ),
            keyboardType:
                const TextInputType.numberWithOptions(decimal: true),
          );
        },
      ),
      _FieldId.powderLot: _FieldDef(
        id: _FieldId.powderLot,
        label: 'Powder Lot',
        level: DetailLevel.detailed,
        aliases: const ['jug', 'can', 'batch', 'lot'],
        builder: (ctx) => _LotPickerField<PowderLotRow>(
          label: 'Powder Lot',
          future: _powderLotsFuture,
          selectedId: _powderLotId,
          itemLabel: (row) => _composeLotLabel(
            row.manufacturer,
            row.name,
            row.lotNumber,
          ),
          itemId: (row) => row.id,
          onChanged: (v) {
            setState(() => _powderLotId = v);
            _autoSave.notifyDirty();
          },
          onCreate: () => _showCreateLotDialog(
            type: 'powder',
            parentLabel: _powder.text,
            onCreate: (m, n, lot) async {
              final repo = context.read<RecipeRepository>();
              final id = await repo.createPowderLot(
                manufacturer: m,
                name: n,
                lotNumber: lot,
              );
              if (!mounted) return;
              setState(() {
                _powderLotsFuture = repo.allPowderLots();
                _powderLotId = id;
              });
            },
          ),
        ),
      ),
      _FieldId.chargeTolerance: _FieldDef(
        id: _FieldId.chargeTolerance,
        label: 'Charge Tolerance',
        level: DetailLevel.all,
        aliases: const ['tolerance', 'plus', 'minus', 'spread', 'scale'],
        // TODO(units): display labels only; canonical storage unchanged.
        builder: (ctx) {
          final wt = unitDisplayLabel(
              ctx.watch<UnitService>().unitFor(UnitCategory.bulletWeight));
          return TextFormField(
            controller: _chargeTolerance,
            decoration: InputDecoration(
              labelText: 'Charge Tolerance ($wt)',
              suffixText: wt,
              helperText: '± spread / scale resolution',
            ),
            keyboardType:
                const TextInputType.numberWithOptions(decimal: true),
          );
        },
        beginnerTooltip:
            'How far each thrown charge can wander from your target. '
            'Tighter tolerance gives more consistent velocity but '
            'takes longer to weigh.',
      ),

      // ─────── Primer ───────
      _FieldId.primer: _FieldDef(
        id: _FieldId.primer,
        label: 'Primer',
        level: DetailLevel.basic,
        aliases: const ['ignition', 'brand', 'product'],
        builder: (ctx) => PrimerCascadeField(
          controller: _primer,
          onSelected: (label) {
            // ignore: discarded_futures
            _onPrimerSelected(label);
          },
        ),
      ),
      _FieldId.primerSize: _FieldDef(
        id: _FieldId.primerSize,
        label: 'Primer Size',
        level: DetailLevel.detailed,
        aliases: const [
          'small',
          'large',
          'pistol',
          'rifle',
          'srp',
          'lrp',
          'sp',
          'lp',
        ],
        builder: (ctx) => DropdownButtonFormField<String>(
          initialValue: _primerSize,
          isExpanded: true,
          decoration: const InputDecoration(labelText: 'Primer Size'),
          items: [
            for (final s in _primerSizeOptions)
              DropdownMenuItem(value: s, child: Text(s)),
          ],
          onChanged: (v) {
            setState(() => _primerSize = v);
            _autoSave.notifyDirty();
          },
        ),
      ),
      _FieldId.primerDepth: _FieldDef(
        id: _FieldId.primerDepth,
        label: 'Primer Depth',
        level: DetailLevel.detailed,
        aliases: const ['cps', 'cup', 'seating'],
        // TODO(units): display labels only; canonical storage unchanged.
        builder: (ctx) {
          final len = unitDisplayLabel(
              ctx.watch<UnitService>().unitFor(UnitCategory.smallLength));
          return TextFormField(
            controller: _primerDepth,
            decoration: InputDecoration(
              labelText: 'Primer Depth ($len)',
              suffixText: len,
              helperText: 'CPS, in 0.001" units',
            ),
            keyboardType:
                const TextInputType.numberWithOptions(decimal: true),
          );
        },
      ),
      _FieldId.primerLot: _FieldDef(
        id: _FieldId.primerLot,
        label: 'Primer Lot',
        level: DetailLevel.detailed,
        aliases: const ['box', 'tray', 'lot', 'batch'],
        builder: (ctx) => _LotPickerField<PrimerLotRow>(
          label: 'Primer Lot',
          future: _primerLotsFuture,
          selectedId: _primerLotId,
          itemLabel: (row) => _composeLotLabel(
            row.manufacturer,
            row.name,
            row.lotNumber,
          ),
          itemId: (row) => row.id,
          onChanged: (v) {
            setState(() => _primerLotId = v);
            _autoSave.notifyDirty();
          },
          onCreate: () => _showCreateLotDialog(
            type: 'primer',
            parentLabel: _primer.text,
            onCreate: (m, n, lot) async {
              final repo = context.read<RecipeRepository>();
              final id = await repo.createPrimerLot(
                manufacturer: m,
                name: n,
                lotNumber: lot,
              );
              if (!mounted) return;
              setState(() {
                _primerLotsFuture = repo.allPrimerLots();
                _primerLotId = id;
              });
            },
          ),
        ),
      ),
      _FieldId.primerSeatingForce: _FieldDef(
        id: _FieldId.primerSeatingForce,
        label: 'Primer Seating Force',
        level: DetailLevel.all,
        aliases: const ['force', 'seating', 'gauge', 'lbs'],
        builder: (ctx) => TextFormField(
          controller: _primerSeatingForce,
          decoration: const InputDecoration(
            labelText: 'Primer Seating Force (lbs)',
            suffixText: 'lbs',
          ),
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
        ),
      ),

      // ─────── Bullet ───────
      _FieldId.bullet: _FieldDef(
        id: _FieldId.bullet,
        label: 'Bullet',
        level: DetailLevel.basic,
        aliases: const ['projectile', 'pill'],
        builder: (ctx) => ComponentField(
          kind: 'bullet',
          label: 'Bullet',
          controller: _bullet,
          onSelected: _onBulletSelected,
        ),
      ),
      _FieldId.bulletWeight: _FieldDef(
        id: _FieldId.bulletWeight,
        label: 'Bullet Weight',
        level: DetailLevel.basic,
        aliases: const ['grains', 'gr', 'mass'],
        // TODO(units): display labels only; canonical storage unchanged.
        builder: (ctx) {
          final wt = unitDisplayLabel(
              ctx.watch<UnitService>().unitFor(UnitCategory.bulletWeight));
          return TextFormField(
            controller: _bulletWeight,
            decoration: InputDecoration(
              labelText: 'Bullet Weight ($wt)',
              suffixText: wt,
            ),
            keyboardType:
                const TextInputType.numberWithOptions(decimal: true),
          );
        },
      ),
      _FieldId.bulletLot: _FieldDef(
        id: _FieldId.bulletLot,
        label: 'Bullet Lot',
        level: DetailLevel.detailed,
        aliases: const ['box', 'lot', 'batch'],
        builder: (ctx) => _LotPickerField<BulletLotRow>(
          label: 'Bullet Lot',
          future: _bulletLotsFuture,
          selectedId: _bulletLotId,
          itemLabel: (row) => _composeLotLabel(
            row.manufacturer,
            row.name,
            row.lotNumber,
          ),
          itemId: (row) => row.id,
          onChanged: (v) {
            setState(() => _bulletLotId = v);
            _autoSave.notifyDirty();
          },
          onCreate: () => _showCreateLotDialog(
            type: 'bullet',
            parentLabel: _bullet.text,
            onCreate: (m, n, lot) async {
              final repo = context.read<RecipeRepository>();
              final id = await repo.createBulletLot(
                manufacturer: m,
                name: n,
                lotNumber: lot,
              );
              if (!mounted) return;
              setState(() {
                _bulletLotsFuture = repo.allBulletLots();
                _bulletLotId = id;
              });
            },
          ),
        ),
      ),
      _FieldId.bulletLength: _FieldDef(
        id: _FieldId.bulletLength,
        label: 'Bullet Length',
        level: DetailLevel.all,
        aliases: const ['length', 'overall', 'projectile'],
        // TODO(units): display labels only; canonical storage unchanged.
        builder: (ctx) {
          final len = unitDisplayLabel(
              ctx.watch<UnitService>().unitFor(UnitCategory.smallLength));
          return TextFormField(
            controller: _bulletLength,
            decoration: InputDecoration(
              labelText: 'Bullet Length ($len)',
              suffixText: len,
            ),
            keyboardType:
                const TextInputType.numberWithOptions(decimal: true),
          );
        },
      ),
      _FieldId.bulletBaseToOgive: _FieldDef(
        id: _FieldId.bulletBaseToOgive,
        label: 'Bullet Base-to-Ogive',
        level: DetailLevel.all,
        aliases: const ['bto', 'base', 'ogive', 'comparator'],
        // TODO(units): display labels only; canonical storage unchanged.
        builder: (ctx) {
          final len = unitDisplayLabel(
              ctx.watch<UnitService>().unitFor(UnitCategory.smallLength));
          return TextFormField(
            controller: _bulletBaseToOgive,
            decoration: InputDecoration(
              labelText: 'Bullet Base-to-Ogive ($len)',
              suffixText: len,
            ),
            keyboardType:
                const TextInputType.numberWithOptions(decimal: true),
          );
        },
      ),
      _FieldId.bulletBearingSurface: _FieldDef(
        id: _FieldId.bulletBearingSurface,
        label: 'Bearing Surface Length',
        level: DetailLevel.all,
        aliases: const ['bearing', 'shank', 'bullet', 'surface'],
        // TODO(units): display labels only; canonical storage unchanged.
        builder: (ctx) {
          final len = unitDisplayLabel(
              ctx.watch<UnitService>().unitFor(UnitCategory.smallLength));
          return TextFormField(
            controller: _bulletBearingSurface,
            decoration: InputDecoration(
              labelText: 'Bearing Surface Length ($len)',
              suffixText: len,
            ),
            keyboardType:
                const TextInputType.numberWithOptions(decimal: true),
          );
        },
      ),
      _FieldId.bulletMeplatTrimmed: _FieldDef(
        id: _FieldId.bulletMeplatTrimmed,
        label: 'Meplat Trimmed',
        level: DetailLevel.all,
        aliases: const ['meplat', 'tip', 'uniform', 'trim'],
        builder: (ctx) => SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('Meplat Trimmed'),
          value: _bulletMeplatTrimmed,
          onChanged: (v) {
            setState(() => _bulletMeplatTrimmed = v);
            _autoSave.notifyDirty();
          },
        ),
      ),
      _FieldId.bulletPointed: _FieldDef(
        id: _FieldId.bulletPointed,
        label: 'Pointed',
        level: DetailLevel.all,
        aliases: const ['pointed', 'tip', 'uniform', 'meplat'],
        builder: (ctx) => SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('Pointed'),
          value: _bulletPointed,
          onChanged: (v) {
            setState(() => _bulletPointed = v);
            _autoSave.notifyDirty();
          },
        ),
      ),
      _FieldId.bulletWeightSorted: _FieldDef(
        id: _FieldId.bulletWeightSorted,
        label: 'Weight Sorted',
        level: DetailLevel.all,
        aliases: const ['weighed', 'sorted', 'graded', 'consistency'],
        builder: (ctx) => SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('Weight Sorted'),
          value: _bulletWeightSorted,
          onChanged: (v) {
            setState(() => _bulletWeightSorted = v);
            _autoSave.notifyDirty();
          },
        ),
      ),
      _FieldId.bulletWeightTolerance: _FieldDef(
        id: _FieldId.bulletWeightTolerance,
        label: 'Weight Sort Tolerance',
        level: DetailLevel.all,
        aliases: const ['tolerance', 'sort', 'spread', 'weight'],
        // TODO(units): display labels only; canonical storage unchanged.
        builder: (ctx) {
          final wt = unitDisplayLabel(
              ctx.watch<UnitService>().unitFor(UnitCategory.bulletWeight));
          return TextFormField(
            controller: _bulletWeightTolerance,
            decoration: InputDecoration(
              labelText: 'Weight Sort Tolerance ($wt)',
              suffixText: wt,
              helperText: '± from nominal',
            ),
            keyboardType:
                const TextInputType.numberWithOptions(decimal: true),
          );
        },
      ),
      _FieldId.bulletBtoSorted: _FieldDef(
        id: _FieldId.bulletBtoSorted,
        label: 'BTO Sorted',
        level: DetailLevel.all,
        aliases: const ['bto', 'sorted', 'ogive', 'comparator'],
        builder: (ctx) => SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('BTO Sorted'),
          value: _bulletBtoSorted,
          onChanged: (v) {
            setState(() => _bulletBtoSorted = v);
            _autoSave.notifyDirty();
          },
        ),
      ),
      _FieldId.bulletBtoTolerance: _FieldDef(
        id: _FieldId.bulletBtoTolerance,
        label: 'BTO Sort Tolerance',
        level: DetailLevel.all,
        aliases: const ['bto', 'tolerance', 'spread', 'ogive'],
        // TODO(units): display labels only; canonical storage unchanged.
        builder: (ctx) {
          final len = unitDisplayLabel(
              ctx.watch<UnitService>().unitFor(UnitCategory.smallLength));
          return TextFormField(
            controller: _bulletBtoTolerance,
            decoration: InputDecoration(
              labelText: 'BTO Sort Tolerance ($len)',
              suffixText: len,
              helperText: '± from nominal',
            ),
            keyboardType:
                const TextInputType.numberWithOptions(decimal: true),
          );
        },
      ),
      _FieldId.bulletDiameterSorted: _FieldDef(
        id: _FieldId.bulletDiameterSorted,
        label: 'Diameter Sorted',
        level: DetailLevel.all,
        aliases: const ['diameter', 'sorted', 'mic'],
        builder: (ctx) => SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('Diameter Sorted'),
          value: _bulletDiameterSorted,
          onChanged: (v) {
            setState(() => _bulletDiameterSorted = v);
            _autoSave.notifyDirty();
          },
        ),
      ),
      _FieldId.seatingDepth: _FieldDef(
        id: _FieldId.seatingDepth,
        label: 'Seating Depth',
        level: DetailLevel.detailed,
        aliases: const ['seat', 'jump', 'jam'],
        // TODO(units): display labels only; canonical storage unchanged.
        builder: (ctx) {
          final len = unitDisplayLabel(
              ctx.watch<UnitService>().unitFor(UnitCategory.smallLength));
          return TextFormField(
            controller: _seatingDepth,
            decoration: InputDecoration(
              labelText: 'Seating Depth ($len)',
              suffixText: len,
            ),
            keyboardType:
                const TextInputType.numberWithOptions(decimal: true),
          );
        },
      ),
      _FieldId.cbto: _FieldDef(
        id: _FieldId.cbto,
        label: 'CBTO',
        level: DetailLevel.detailed,
        aliases: const [
          'cartridge',
          'base',
          'ogive',
          'comparator',
          'btoive',
        ],
        // TODO(units): display labels only; canonical storage unchanged.
        builder: (ctx) {
          final len = unitDisplayLabel(
              ctx.watch<UnitService>().unitFor(UnitCategory.smallLength));
          return TextFormField(
            controller: _cbto,
            decoration: InputDecoration(
              labelText: 'CBTO ($len)',
              suffixText: len,
              helperText: 'Cartridge base to ogive',
            ),
            keyboardType:
                const TextInputType.numberWithOptions(decimal: true),
          );
        },
        beginnerTooltip:
            'CBTO measures from the case base to the bullet\'s ogive — '
            'more reproducible than COAL across bullets with different '
            'tip lengths. Most reloaders measure with a comparator insert.',
      ),

      // ─────── Brass ───────
      _FieldId.brass: _FieldDef(
        id: _FieldId.brass,
        label: 'Brass',
        level: DetailLevel.basic,
        aliases: const ['case', 'cases', 'shell'],
        builder: (ctx) => ComponentField(
          kind: 'brass',
          label: 'Brass',
          controller: _brass,
        ),
      ),
      _FieldId.brassLot: _FieldDef(
        id: _FieldId.brassLot,
        label: 'Brass Lot',
        level: DetailLevel.detailed,
        aliases: const ['lot', 'headstamp', 'batch', 'case'],
        builder: (ctx) => _LotPickerField<BrassLotRow>(
          label: 'Brass Lot',
          future: _brassLotsFuture,
          selectedId: _brassLotId,
          itemLabel: (row) => _composeBrassLotLabel(row),
          itemId: (row) => row.id,
          onChanged: (v) {
            setState(() => _brassLotId = v);
            _autoSave.notifyDirty();
          },
          onCreate: () => _showCreateBrassLotDialog(parentLabel: _brass.text),
        ),
      ),
      _FieldId.primerPocketSize: _FieldDef(
        id: _FieldId.primerPocketSize,
        label: 'Primer Pocket Size',
        level: DetailLevel.detailed,
        aliases: const ['pocket', 'srp', 'lrp', 'sp', 'lp'],
        builder: (ctx) => DropdownButtonFormField<String>(
          initialValue: _primerPocketSize,
          isExpanded: true,
          decoration: const InputDecoration(labelText: 'Primer Pocket Size'),
          items: [
            for (final s in _primerPocketOptions)
              DropdownMenuItem(value: s, child: Text(s)),
          ],
          onChanged: (v) {
            setState(() => _primerPocketSize = v);
            _autoSave.notifyDirty();
          },
        ),
      ),
      _FieldId.shoulderBump: _FieldDef(
        id: _FieldId.shoulderBump,
        label: 'Shoulder Bump',
        level: DetailLevel.detailed,
        aliases: const ['bump', 'sizing', 'headspace'],
        beginnerTooltip:
            'How far you push the case shoulder back during sizing. '
            'Most reloaders aim for 0.001"-0.002" of bump for '
            'reliable chambering and case life.',
        // TODO(units): display labels only; canonical storage unchanged.
        builder: (ctx) {
          final len = unitDisplayLabel(
              ctx.watch<UnitService>().unitFor(UnitCategory.smallLength));
          return TextFormField(
            controller: _shoulderBump,
            decoration: InputDecoration(
              labelText: 'Shoulder Bump ($len)',
              suffixText: len,
            ),
            keyboardType:
                const TextInputType.numberWithOptions(decimal: true),
          );
        },
      ),
      _FieldId.mandrelSize: _FieldDef(
        id: _FieldId.mandrelSize,
        label: 'Mandrel Size',
        level: DetailLevel.detailed,
        aliases: const ['neck', 'tension', 'expander'],
        // TODO(units): display labels only; canonical storage unchanged.
        builder: (ctx) {
          final len = unitDisplayLabel(
              ctx.watch<UnitService>().unitFor(UnitCategory.smallLength));
          return TextFormField(
            controller: _mandrelSize,
            decoration: InputDecoration(
              labelText: 'Mandrel Size ($len)',
              suffixText: len,
            ),
            keyboardType:
                const TextInputType.numberWithOptions(decimal: true),
          );
        },
      ),
      _FieldId.bushingSize: _FieldDef(
        id: _FieldId.bushingSize,
        label: 'Bushing Size',
        level: DetailLevel.all,
        aliases: const ['bushing', 'die', 'neck'],
        // TODO(units): display labels only; canonical storage unchanged.
        builder: (ctx) {
          final len = unitDisplayLabel(
              ctx.watch<UnitService>().unitFor(UnitCategory.smallLength));
          return TextFormField(
            controller: _bushingSize,
            decoration: InputDecoration(
              labelText: 'Bushing Size ($len)',
              suffixText: len,
            ),
            keyboardType:
                const TextInputType.numberWithOptions(decimal: true),
          );
        },
      ),

      // ─────── Loaded Round Dimensions ───────
      _FieldId.coal: _FieldDef(
        id: _FieldId.coal,
        label: 'COAL',
        level: DetailLevel.basic,
        aliases: const ['overall', 'length', 'oal', 'cartridge'],
        // TODO(units): display labels only; canonical storage unchanged.
        builder: (ctx) {
          final len = unitDisplayLabel(
              ctx.watch<UnitService>().unitFor(UnitCategory.smallLength));
          return TextFormField(
            controller: _coal,
            decoration: InputDecoration(
              labelText: 'COAL ($len)',
              suffixText: len,
            ),
            keyboardType:
                const TextInputType.numberWithOptions(decimal: true),
          );
        },
      ),
      _FieldId.distanceToLands: _FieldDef(
        id: _FieldId.distanceToLands,
        label: 'Distance to Lands',
        level: DetailLevel.all,
        aliases: const ['lands', 'jam', 'distance', 'touch'],
        beginnerTooltip:
            'How far the bullet sits from the start of the rifling '
            '(the lands). Affects pressure and accuracy. Most '
            'beginners can ignore this until they\'re tuning loads.',
        // TODO(units): display labels only; canonical storage unchanged.
        builder: (ctx) {
          final len = unitDisplayLabel(
              ctx.watch<UnitService>().unitFor(UnitCategory.smallLength));
          return TextFormField(
            controller: _distanceToLands,
            decoration: InputDecoration(
              labelText: 'Distance to Lands ($len)',
              suffixText: len,
            ),
            keyboardType:
                const TextInputType.numberWithOptions(decimal: true),
          );
        },
      ),
      _FieldId.jumpToLands: _FieldDef(
        id: _FieldId.jumpToLands,
        label: 'Jump to Lands',
        level: DetailLevel.all,
        aliases: const ['jump', 'lands', 'freebore'],
        // TODO(units): display labels only; canonical storage unchanged.
        builder: (ctx) {
          final len = unitDisplayLabel(
              ctx.watch<UnitService>().unitFor(UnitCategory.smallLength));
          return TextFormField(
            controller: _jumpToLands,
            decoration: InputDecoration(
              labelText: 'Jump to Lands ($len)',
              suffixText: len,
            ),
            keyboardType:
                const TextInputType.numberWithOptions(decimal: true),
          );
        },
      ),
      _FieldId.loadedNeckDiameter: _FieldDef(
        id: _FieldId.loadedNeckDiameter,
        label: 'Loaded Neck Diameter',
        level: DetailLevel.all,
        aliases: const ['neck', 'diameter', 'tension', 'loaded'],
        // TODO(units): display labels only; canonical storage unchanged.
        builder: (ctx) {
          final len = unitDisplayLabel(
              ctx.watch<UnitService>().unitFor(UnitCategory.smallLength));
          return TextFormField(
            controller: _loadedNeckDiameter,
            decoration: InputDecoration(
              labelText: 'Loaded Neck Diameter ($len)',
              suffixText: len,
            ),
            keyboardType:
                const TextInputType.numberWithOptions(decimal: true),
          );
        },
      ),
      _FieldId.bulletRunout: _FieldDef(
        id: _FieldId.bulletRunout,
        label: 'Bullet Runout / TIR',
        level: DetailLevel.all,
        aliases: const ['runout', 'tir', 'concentricity', 'bullet'],
        beginnerTooltip:
            'How off-center the seated bullet is, measured by total '
            'indicator runout. Lower is better for accuracy. Skip '
            'unless you have a runout gauge.',
        // TODO(units): display labels only; canonical storage unchanged.
        builder: (ctx) {
          final len = unitDisplayLabel(
              ctx.watch<UnitService>().unitFor(UnitCategory.smallLength));
          return TextFormField(
            controller: _bulletRunout,
            decoration: InputDecoration(
              labelText: 'Bullet Runout / TIR ($len)',
              suffixText: len,
            ),
            keyboardType:
                const TextInputType.numberWithOptions(decimal: true),
          );
        },
      ),

      // ─────── Pressure Indicators ───────
      _FieldId.pressureNotes: _FieldDef(
        id: _FieldId.pressureNotes,
        label: 'Pressure Notes',
        level: DetailLevel.all,
        aliases: const ['pressure', 'notes', 'observations'],
        builder: (ctx) => TextFormField(
          controller: _pressureNotes,
          decoration: const InputDecoration(
            labelText: 'Pressure Notes',
            helperText: 'Free-form pressure-sign observations',
          ),
          maxLines: 3,
        ),
      ),
      _FieldId.boltLift: _FieldDef(
        id: _FieldId.boltLift,
        label: 'Bolt Lift',
        level: DetailLevel.all,
        aliases: const ['bolt', 'lift', 'pressure', 'sticky', 'normal'],
        beginnerTooltip:
            'How the bolt feels when lifting after firing. Sticky lift '
            'is a sign of high pressure — back the charge down before '
            'firing more.',
        builder: (ctx) => DropdownButtonFormField<String>(
          initialValue: _boltLift,
          isExpanded: true,
          decoration: const InputDecoration(labelText: 'Bolt Lift'),
          items: [
            for (final s in _boltLiftOptions)
              DropdownMenuItem(value: s.value, child: Text(s.label)),
          ],
          onChanged: (v) {
            setState(() => _boltLift = v);
            _autoSave.notifyDirty();
          },
        ),
      ),
      _FieldId.ejectorMarks: _FieldDef(
        id: _FieldId.ejectorMarks,
        label: 'Ejector Marks',
        level: DetailLevel.all,
        aliases: const ['ejector', 'marks', 'pressure', 'overpressure'],
        builder: (ctx) => SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('Ejector Marks'),
          value: _ejectorMarks,
          onChanged: (v) {
            setState(() => _ejectorMarks = v);
            _autoSave.notifyDirty();
          },
        ),
      ),
      _FieldId.crateredPrimers: _FieldDef(
        id: _FieldId.crateredPrimers,
        label: 'Cratered Primers',
        level: DetailLevel.all,
        aliases: const [
          'cratered',
          'primer',
          'pressure',
          'marks',
          'overpressure',
        ],
        builder: (ctx) => SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('Cratered Primers'),
          value: _crateredPrimers,
          onChanged: (v) {
            setState(() => _crateredPrimers = v);
            _autoSave.notifyDirty();
          },
        ),
      ),
      _FieldId.webExpansion: _FieldDef(
        id: _FieldId.webExpansion,
        label: 'Web Expansion at .200"',
        level: DetailLevel.all,
        aliases: const ['web', 'expansion', 'pressure', 'case'],
        // TODO(units): display labels only; canonical storage unchanged.
        builder: (ctx) {
          final len = unitDisplayLabel(
              ctx.watch<UnitService>().unitFor(UnitCategory.smallLength));
          return TextFormField(
            controller: _webExpansion,
            decoration: InputDecoration(
              labelText: 'Web Expansion at .200" ($len)',
              suffixText: len,
            ),
            keyboardType:
                const TextInputType.numberWithOptions(decimal: true),
          );
        },
      ),
      _FieldId.primerFlatness: _FieldDef(
        id: _FieldId.primerFlatness,
        label: 'Primer Flatness',
        level: DetailLevel.all,
        aliases: const ['primer', 'flatness', 'pressure', 'flat'],
        builder: (ctx) => _PrimerFlatnessField(
          value: _primerFlatness,
          onChanged: (v) {
            setState(() => _primerFlatness = v);
            _autoSave.notifyDirty();
          },
        ),
      ),

      // ─────── Process / Equipment / Provenance ───────
      _FieldId.loadingDate: _FieldDef(
        id: _FieldId.loadingDate,
        label: 'Loading Date',
        level: DetailLevel.all,
        aliases: const ['date', 'loaded', 'when'],
        builder: (ctx) => _DateField(
          label: 'Loading Date',
          value: _loadingDate,
          onChanged: (v) {
            setState(() => _loadingDate = v);
            _autoSave.notifyDirty();
          },
        ),
      ),
      _FieldId.roundsLoadedInBatch: _FieldDef(
        id: _FieldId.roundsLoadedInBatch,
        label: 'Rounds Loaded in Batch',
        level: DetailLevel.all,
        aliases: const ['rounds', 'count', 'batch', 'quantity'],
        builder: (ctx) => TextFormField(
          controller: _roundsLoadedInBatch,
          decoration: const InputDecoration(
            labelText: 'Rounds Loaded in Batch',
          ),
          keyboardType: TextInputType.number,
        ),
      ),
      _FieldId.pressUsed: _FieldDef(
        id: _FieldId.pressUsed,
        label: 'Press Used',
        level: DetailLevel.all,
        aliases: const ['press', 'tool', 'equipment'],
        builder: (ctx) => TextFormField(
          controller: _pressUsed,
          decoration: const InputDecoration(labelText: 'Press Used'),
        ),
      ),
      _FieldId.sizingDieUsed: _FieldDef(
        id: _FieldId.sizingDieUsed,
        label: 'Sizing Die Used',
        level: DetailLevel.all,
        aliases: const ['sizing', 'die', 'equipment'],
        builder: (ctx) => TextFormField(
          controller: _sizingDieUsed,
          decoration: const InputDecoration(labelText: 'Sizing Die Used'),
        ),
      ),
      _FieldId.seatingDieUsed: _FieldDef(
        id: _FieldId.seatingDieUsed,
        label: 'Seating Die Used',
        level: DetailLevel.all,
        aliases: const ['seating', 'die', 'equipment'],
        builder: (ctx) => TextFormField(
          controller: _seatingDieUsed,
          decoration: const InputDecoration(labelText: 'Seating Die Used'),
        ),
      ),
      _FieldId.scaleUsed: _FieldDef(
        id: _FieldId.scaleUsed,
        label: 'Scale Used',
        level: DetailLevel.all,
        aliases: const ['scale', 'balance', 'equipment'],
        builder: (ctx) => TextFormField(
          controller: _scaleUsed,
          decoration: const InputDecoration(labelText: 'Scale Used'),
        ),
      ),
      _FieldId.scaleCalibrationDate: _FieldDef(
        id: _FieldId.scaleCalibrationDate,
        label: 'Scale Calibration Date',
        level: DetailLevel.all,
        aliases: const ['calibration', 'scale', 'date', 'check'],
        builder: (ctx) => _DateField(
          label: 'Scale Calibration Date',
          value: _scaleCalibrationDate,
          onChanged: (v) {
            setState(() => _scaleCalibrationDate = v);
            _autoSave.notifyDirty();
          },
        ),
      ),
      _FieldId.comparatorInsertUsed: _FieldDef(
        id: _FieldId.comparatorInsertUsed,
        label: 'Comparator Insert Used',
        level: DetailLevel.all,
        aliases: const ['comparator', 'insert', 'measurement'],
        builder: (ctx) => TextFormField(
          controller: _comparatorInsertUsed,
          decoration:
              const InputDecoration(labelText: 'Comparator Insert Used'),
        ),
      ),
      _FieldId.chronographUsed: _FieldDef(
        id: _FieldId.chronographUsed,
        label: 'Chronograph Used',
        level: DetailLevel.all,
        aliases: const ['chronograph', 'velocity', 'equipment'],
        builder: (ctx) => TextFormField(
          controller: _chronographUsed,
          decoration: const InputDecoration(labelText: 'Chronograph Used'),
        ),
      ),
      _FieldId.boreState: _FieldDef(
        id: _FieldId.boreState,
        label: 'Bore State',
        level: DetailLevel.all,
        aliases: const ['bore', 'clean', 'fouled', 'seasoned', 'state'],
        builder: (ctx) => DropdownButtonFormField<String>(
          initialValue: _boreState,
          isExpanded: true,
          decoration: const InputDecoration(labelText: 'Bore State'),
          items: [
            for (final s in _boreStateOptions)
              DropdownMenuItem(value: s.value, child: Text(s.label)),
          ],
          onChanged: (v) {
            setState(() => _boreState = v);
            _autoSave.notifyDirty();
          },
        ),
      ),
      _FieldId.loadedBy: _FieldDef(
        id: _FieldId.loadedBy,
        label: 'Loaded By',
        level: DetailLevel.all,
        aliases: const ['loaded', 'by', 'reloader', 'who'],
        builder: (ctx) => TextFormField(
          controller: _loadedBy,
          decoration: const InputDecoration(labelText: 'Loaded By'),
        ),
      ),

      // ─────── Notes ───────
      _FieldId.notes: _FieldDef(
        id: _FieldId.notes,
        label: 'Notes',
        // Notes is always visible regardless of detail level.
        level: DetailLevel.basic,
        aliases: const ['comments', 'memo'],
        builder: (ctx) => TextFormField(
          controller: _notes,
          decoration: const InputDecoration(labelText: 'Notes'),
          maxLines: 4,
        ),
      ),
    };
  }

  /// The on-screen ordering of sections and the field ids inside each.
  static const List<_Section> _sections = [
    _Section(
      id: 'load_id',
      title: 'Load Identification',
      fieldIds: [
        _FieldId.recipeName,
        _FieldId.caliber,
        _FieldId.status,
        _FieldId.useCase,
      ],
    ),
    _Section(
      id: 'powder',
      title: 'Powder',
      fieldIds: [
        _FieldId.powder,
        _FieldId.powderCharge,
        _FieldId.powderLot,
        _FieldId.chargeTolerance,
      ],
      pairs: [
        [_FieldId.powder, _FieldId.powderCharge],
      ],
    ),
    _Section(
      id: 'primer',
      title: 'Primer',
      // `primerDepth` moves to the Bullet section so it can pair with
      // `seatingDepth` on desktop layouts — they're both seating-depth
      // measurements that reloaders cross-check together. The Primer
      // section keeps the brand / size / lot / seating-force fields
      // that describe primer selection rather than installed geometry.
      fieldIds: [
        _FieldId.primer,
        _FieldId.primerSize,
        _FieldId.primerLot,
        _FieldId.primerSeatingForce,
      ],
    ),
    _Section(
      id: 'bullet',
      title: 'Bullet',
      fieldIds: [
        _FieldId.bullet,
        _FieldId.bulletWeight,
        _FieldId.bulletLot,
        _FieldId.bulletLength,
        _FieldId.bulletBaseToOgive,
        _FieldId.bulletBearingSurface,
        _FieldId.bulletMeplatTrimmed,
        _FieldId.bulletPointed,
        _FieldId.bulletWeightSorted,
        _FieldId.bulletWeightTolerance,
        _FieldId.bulletBtoSorted,
        _FieldId.bulletBtoTolerance,
        _FieldId.bulletDiameterSorted,
        _FieldId.seatingDepth,
        _FieldId.primerDepth,
      ],
      pairs: [
        [_FieldId.bullet, _FieldId.bulletWeight],
        [_FieldId.seatingDepth, _FieldId.primerDepth],
      ],
    ),
    _Section(
      id: 'brass',
      title: 'Brass',
      fieldIds: [
        _FieldId.brass,
        _FieldId.brassLot,
        _FieldId.primerPocketSize,
        _FieldId.shoulderBump,
        _FieldId.mandrelSize,
        _FieldId.bushingSize,
      ],
      pairs: [
        [_FieldId.shoulderBump, _FieldId.mandrelSize],
      ],
    ),
    _Section(
      id: 'dimensions',
      title: 'Loaded Round Dimensions',
      // `cbto` moves here from the Bullet section because it pairs
      // logically with `coal` (Cartridge Overall Length) — both are
      // measurements of the loaded round, and reloaders typically read
      // them together when chasing a target jump-to-lands or seating
      // depth. The pair fires on desktop widths via the `pairs` block
      // below.
      fieldIds: [
        _FieldId.coal,
        _FieldId.cbto,
        _FieldId.distanceToLands,
        _FieldId.jumpToLands,
        _FieldId.loadedNeckDiameter,
        _FieldId.bulletRunout,
      ],
      pairs: [
        [_FieldId.coal, _FieldId.cbto],
      ],
    ),
    _Section(
      id: 'pressure',
      title: 'Pressure Indicators',
      fieldIds: [
        _FieldId.pressureNotes,
        _FieldId.boltLift,
        _FieldId.ejectorMarks,
        _FieldId.crateredPrimers,
        _FieldId.webExpansion,
        _FieldId.primerFlatness,
      ],
    ),
    _Section(
      id: 'process',
      title: 'Process / Equipment / Provenance',
      // `loadedBy` moves up to sit next to `loadingDate` so the desktop
      // pair declared below can render them side-by-side. The two
      // fields are conceptually a "who & when" header for the section
      // anyway, so the new ordering also reads better top-down on
      // narrow widths.
      fieldIds: [
        _FieldId.loadingDate,
        _FieldId.loadedBy,
        _FieldId.roundsLoadedInBatch,
        _FieldId.pressUsed,
        _FieldId.sizingDieUsed,
        _FieldId.seatingDieUsed,
        _FieldId.scaleUsed,
        _FieldId.scaleCalibrationDate,
        _FieldId.comparatorInsertUsed,
        _FieldId.chronographUsed,
        _FieldId.boreState,
      ],
      pairs: [
        [_FieldId.loadingDate, _FieldId.loadedBy],
      ],
    ),
    _Section(
      id: _customFieldsSectionId,
      title: 'Custom Fields',
      fieldIds: [],
    ),
    _Section(
      id: 'notes',
      title: 'Notes',
      fieldIds: [_FieldId.notes],
    ),
  ];

  // ─────────────────────── Filter / visibility logic ───────────────────────

  /// Tokenise [_query] into lower-case substrings; empty list when no
  /// search is active.
  List<String> get _queryTokens {
    final q = _query.trim().toLowerCase();
    if (q.isEmpty) return const [];
    return q
        .split(RegExp(r'\s+'))
        .where((t) => t.isNotEmpty)
        .toList(growable: false);
  }

  /// True when [field] matches every token in the current query. An empty
  /// query matches everything.
  bool _matchesQuery(_FieldDef field, List<String> tokens) {
    if (tokens.isEmpty) return true;
    final haystack = StringBuffer(field.label.toLowerCase());
    for (final a in field.aliases) {
      haystack.write(' ');
      haystack.write(a.toLowerCase());
    }
    final hay = haystack.toString();
    for (final t in tokens) {
      if (!hay.contains(t)) return false;
    }
    return true;
  }

  /// Whether [field] should render given the current detail level and
  /// search state. Filter takes priority — a matching query overrides the
  /// detail level. The Notes field is treated as always-visible (per
  /// product requirements) when no filter is active.
  bool _shouldShowField(_FieldDef field, List<String> tokens) {
    if (tokens.isNotEmpty) return _matchesQuery(field, tokens);
    if (field.id == _FieldId.notes) return true;
    return _detailLevel.includes(field.level);
  }

  // ─────────────────────── UI ───────────────────────

  @override
  Widget build(BuildContext context) {
    final isEdit = widget.existing != null;
    final theme = Theme.of(context);
    final defs = _buildFieldDefs();
    final tokens = _queryTokens;
    final isSearching = tokens.isNotEmpty;
    final autoSaveOn = context.watch<AutoSaveService>().isEnabled;
    final beginnerOn = context.watch<BeginnerModeService>().isEnabled;

    return PopScope(
      canPop: true,
      onPopInvokedWithResult: (didPop, _) async {
        await _autoSave.flush();
      },
      child: Scaffold(
        appBar: AppBar(
          title: Text(isEdit ? 'Edit Recipe' : 'New Recipe'),
          actions: [
            // Print / share-as-paper action. Only available once the
            // recipe has been saved at least once — there's nothing to
            // print before then. Saves any pending edits via the
            // autosave controller before formatting so the printed copy
            // matches what's on screen.
            if (isEdit || _autoSave.currentRowId != null)
              IconButton(
                tooltip: 'Print recipe',
                icon: const Icon(Icons.print_outlined),
                onPressed: _busy ? null : _printRecipe,
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
                  child: Column(
                    children: [
                      // Sticky controls: filter input + detail-level toggle. Stays put
                      // while the form scrolls underneath.
            Material(
              color: theme.colorScheme.surface,
              elevation: 0,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    TextField(
                      controller: _searchController,
                      autocorrect: false,
                      enableSuggestions: false,
                      textCapitalization: TextCapitalization.none,
                      textInputAction: TextInputAction.search,
                      onChanged: (v) => setState(() => _query = v),
                      decoration: InputDecoration(
                        hintText: 'Filter Fields...',
                        prefixIcon: const Icon(Icons.search),
                        suffixIcon: _query.isEmpty
                            ? null
                            : IconButton(
                                icon: const Icon(Icons.close),
                                tooltip: 'Clear filter',
                                onPressed: () {
                                  _searchController.clear();
                                  setState(() => _query = '');
                                },
                              ),
                        isDense: true,
                      ),
                    ),
                    const SizedBox(height: 10),
                    Center(
                      child: SegmentedButton<DetailLevel>(
                        segments: const [
                          ButtonSegment(
                            value: DetailLevel.basic,
                            label: Text('Basic'),
                          ),
                          ButtonSegment(
                            value: DetailLevel.detailed,
                            label: Text('Detailed'),
                          ),
                          ButtonSegment(
                            value: DetailLevel.all,
                            label: Text('All'),
                          ),
                        ],
                        selected: {_detailLevel},
                        onSelectionChanged: (s) {
                          final next = s.first;
                          setState(() => _detailLevel = next);
                          // ignore: discarded_futures
                          _persistDetailLevel(next);
                        },
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const Divider(height: 1),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
                children: [
                  for (final section in _sections)
                    _buildSection(
                      context: context,
                      section: section,
                      defs: defs,
                      tokens: tokens,
                      isSearching: isSearching,
                      beginnerOn: beginnerOn,
                    ),
                  if (isSearching && _noVisibleFields(defs, tokens))
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 24),
                      child: Center(
                        child: Text(
                          'No fields match "$_query".',
                          style: theme.textTheme.bodyMedium?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ),
                    ),
                  const SizedBox(height: 16),
                  // Pro: import shot velocities from a Garmin Xero .fit
                  // export. Drops the resulting average / ES / SD into
                  // the Notes field and the Chronograph Used field —
                  // we don't have a dedicated velocity-on-recipe
                  // schema today, so notes are the right home until we
                  // grow the dedicated columns.
                  OutlinedButton.icon(
                    icon: const Icon(Icons.speed),
                    onPressed: _busy ? null : _onImportGarminFit,
                    label: const Text('Import velocity from Garmin .fit'),
                  ),
                  const SizedBox(height: 16),
                  FilledButton(
                    onPressed: _busy ? null : _save,
                    child: Text(_finalButtonLabel(autoSaveOn, isEdit)),
                  ),
                  const SizedBox(height: 16),
                ],
              ),
            ),
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

  /// When autosave is on, the trailing button is just "Done".
  String _finalButtonLabel(bool autoSaveOn, bool isEdit) {
    if (autoSaveOn) return 'Done';
    return isEdit ? 'Save Changes' : 'Create Recipe';
  }

  bool _noVisibleFields(
    Map<_FieldId, _FieldDef> defs,
    List<String> tokens,
  ) {
    for (final s in _sections) {
      if (s.id == _customFieldsSectionId) continue;
      for (final fid in s.fieldIds) {
        final def = defs[fid];
        if (def == null) continue;
        if (_shouldShowField(def, tokens)) return false;
      }
    }
    return true;
  }

  Widget _buildSection({
    required BuildContext context,
    required _Section section,
    required Map<_FieldId, _FieldDef> defs,
    required List<String> tokens,
    required bool isSearching,
    required bool beginnerOn,
  }) {
    if (section.id == _customFieldsSectionId) {
      return _buildCustomFieldsSection(
        context: context,
        tokens: tokens,
        isSearching: isSearching,
      );
    }

    final theme = Theme.of(context);
    final visibleFields = <_FieldDef>[];
    for (final fid in section.fieldIds) {
      final def = defs[fid];
      if (def == null) continue;
      if (_shouldShowField(def, tokens)) visibleFields.add(def);
    }

    // While searching, hide entire sections that have no matching fields.
    if (isSearching && visibleFields.isEmpty) {
      return const SizedBox.shrink();
    }

    // Default expansion:
    //   * searching: expand iff the section has matches
    //   * otherwise: always expanded by default
    final initiallyExpanded = isSearching ? visibleFields.isNotEmpty : true;

    // Re-key on the search state so ExpansionTile picks up the new
    // initiallyExpanded value when the filter toggles.
    final tileKey = PageStorageKey<String>(
      'recipe_section_${section.id}_search_$isSearching',
    );

    // Compute the rendering plan for this section's visible fields.
    // On desktop widths each declared pair (when both halves are
    // visible AND the second half lives in this section) renders as a
    // single Row; everything else stacks. On phone / tablet widths
    // the plan is always a flat list of single-field rows.
    final isDesktop = Breakpoints.isDesktop(context);
    final renderItems = _planSectionLayout(
      section: section,
      visibleFields: visibleFields,
      pairOnRow: isDesktop,
    );

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Card(
        clipBehavior: Clip.antiAlias,
        child: ExpansionTile(
          key: tileKey,
          initiallyExpanded: initiallyExpanded,
          // Keep children mounted across collapse/expand. Two reasons:
          //   1. Pickers wrapping `Autocomplete<String>` (recipe name,
          //      caliber, powder, etc.) own internal controllers and an
          //      overlay; tearing them down on collapse and re-mounting
          //      on expand has historically tripped a
          //      `_elements.contains(element)` framework assertion.
          //   2. UX: typing in a field, collapsing, then expanding
          //      should preserve scroll/focus state — `maintainState`
          //      makes that intrinsic instead of relying on controllers.
          maintainState: true,
          tilePadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
          // 12px top breathing room so the first field's M3 floating
          // label isn't visually clipped by the section header.
          childrenPadding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
          title: _SectionHeader(
            title: section.title,
            count: visibleFields.length,
          ),
          children: [
            for (int i = 0; i < renderItems.length; i++) ...[
              if (i > 0) const SizedBox(height: 12),
              _buildRenderItem(
                context: context,
                item: renderItems[i],
                beginnerOn: beginnerOn,
              ),
            ],
            if (visibleFields.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Text(
                  _detailLevel == DetailLevel.basic
                      ? 'Switch to Detailed or All to see more fields.'
                      : 'No fields in this section yet.',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                    fontStyle: FontStyle.italic,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  /// Computes a render plan for one section's visible fields.
  ///
  /// Walks `visibleFields` in declared order and emits either a
  /// `_SingleFieldItem` (one field) or a `_PairFieldItem` (two fields
  /// rendered side-by-side). A pair is honored only when:
  ///   * `pairOnRow` is true (caller already checked the breakpoint),
  ///   * both pair members are present in `visibleFields` (i.e. neither
  ///     was filtered or hidden by detail-level rules),
  ///   * both pair members live in `section.fieldIds` (so cross-section
  ///     pair declarations don't accidentally collapse two unrelated
  ///     fields together — see the comment on `_Section.pairs`),
  ///   * the first member's position in `visibleFields` is the next one
  ///     to be emitted (preserves declared order — pairs never
  ///     re-order fields).
  ///
  /// Surviving fields whose pair partner was hidden stack as singles in
  /// their declared position.
  List<_SectionRenderItem> _planSectionLayout({
    required _Section section,
    required List<_FieldDef> visibleFields,
    required bool pairOnRow,
  }) {
    final items = <_SectionRenderItem>[];
    if (visibleFields.isEmpty) return items;

    // Build the lookup of declared pair partners. Both halves must
    // appear in section.fieldIds for the pair to be eligible.
    final partner = <_FieldId, _FieldId>{};
    if (pairOnRow) {
      final inSection = section.fieldIds.toSet();
      for (final pair in section.pairs) {
        if (pair.length != 2) continue;
        final a = pair[0];
        final b = pair[1];
        if (!inSection.contains(a) || !inSection.contains(b)) continue;
        partner[a] = b;
        partner[b] = a;
      }
    }

    // Walk visible fields in order, greedily pairing with the next
    // visible field if it's the declared partner.
    final visibleIds = {for (final f in visibleFields) f.id};
    var i = 0;
    while (i < visibleFields.length) {
      final current = visibleFields[i];
      final mate = partner[current.id];
      if (mate != null &&
          visibleIds.contains(mate) &&
          i + 1 < visibleFields.length &&
          visibleFields[i + 1].id == mate) {
        items.add(_PairFieldItem(current, visibleFields[i + 1]));
        i += 2;
      } else {
        items.add(_SingleFieldItem(current));
        i += 1;
      }
    }
    return items;
  }

  Widget _buildRenderItem({
    required BuildContext context,
    required _SectionRenderItem item,
    required bool beginnerOn,
  }) {
    if (item is _SingleFieldItem) {
      final field = item.field;
      return KeyedSubtree(
        key: ValueKey('field_${field.id.name}'),
        child: _BeginnerWrap(
          showTooltip: beginnerOn,
          tooltip: field.beginnerTooltip,
          child: field.builder(context),
        ),
      );
    }
    final pair = item as _PairFieldItem;
    final first = pair.first;
    final second = pair.second;
    return KeyedSubtree(
      key: ValueKey(
          'field_pair_${first.id.name}_${second.id.name}'),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: KeyedSubtree(
              key: ValueKey('field_${first.id.name}'),
              child: _BeginnerWrap(
                showTooltip: beginnerOn,
                tooltip: first.beginnerTooltip,
                child: first.builder(context),
              ),
            ),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: KeyedSubtree(
              key: ValueKey('field_${second.id.name}'),
              child: _BeginnerWrap(
                showTooltip: beginnerOn,
                tooltip: second.beginnerTooltip,
                child: second.builder(context),
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// Builds the Custom Fields section, which is driven by a future-loaded
  /// list of [UserCustomFieldRow]s rather than the static FieldDef map.
  Widget _buildCustomFieldsSection({
    required BuildContext context,
    required List<String> tokens,
    required bool isSearching,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Card(
        clipBehavior: Clip.antiAlias,
        child: FutureBuilder<List<UserCustomFieldRow>>(
          future: _customFieldsFuture,
          builder: (context, snap) {
            final fields = snap.data ?? const <UserCustomFieldRow>[];
            // While searching, only render fields whose name matches the
            // query tokens.
            final visible = <UserCustomFieldRow>[];
            for (final f in fields) {
              if (tokens.isEmpty) {
                visible.add(f);
              } else {
                final name = f.fieldName.toLowerCase();
                if (tokens.every(name.contains)) visible.add(f);
              }
            }

            // Hide entire section when searching with no matches and no
            // hint text. The "+ Add" affordance still shows when not
            // searching (so a user can always add their first field).
            if (isSearching && visible.isEmpty) {
              return const SizedBox.shrink();
            }

            final initiallyExpanded =
                isSearching ? visible.isNotEmpty : true;
            final tileKey = PageStorageKey<String>(
              'recipe_section_custom_fields_search_$isSearching',
            );

            return ExpansionTile(
              key: tileKey,
              initiallyExpanded: initiallyExpanded,
              // See sibling section above for why `maintainState: true`
              // and the 12px top padding are paired.
              maintainState: true,
              tilePadding:
                  const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
              childrenPadding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
              title: _SectionHeader(
                title: 'Custom Fields',
                count: visible.length,
              ),
              children: [
                for (int i = 0; i < visible.length; i++) ...[
                  if (i > 0) const SizedBox(height: 12),
                  KeyedSubtree(
                    key: ValueKey('custom_field_${visible[i].id}'),
                    child: _buildCustomFieldEditor(visible[i]),
                  ),
                ],
                if (visible.isEmpty && !isSearching)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    child: Text(
                      'Add your own fields — anything not covered by the '
                      'standard sections above.',
                      style:
                          Theme.of(context).textTheme.bodySmall?.copyWith(
                                color: Theme.of(context)
                                    .colorScheme
                                    .onSurfaceVariant,
                                fontStyle: FontStyle.italic,
                              ),
                    ),
                  ),
                if (!isSearching) ...[
                  const SizedBox(height: 12),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: TextButton.icon(
                      icon: const Icon(Icons.add),
                      label: const Text('Add Custom Field'),
                      onPressed: _showAddCustomFieldDialog,
                    ),
                  ),
                ],
              ],
            );
          },
        ),
      ),
    );
  }

  /// Renders the right editor for a single custom field row.
  Widget _buildCustomFieldEditor(UserCustomFieldRow field) {
    switch (field.fieldType) {
      case 'text':
        final ctrl = _customControllers.putIfAbsent(field.id, () {
          final c = TextEditingController(text: _customValues[field.id] ?? '');
          c.addListener(_autoSave.notifyDirty);
          return c;
        });
        return TextFormField(
          controller: ctrl,
          decoration: InputDecoration(
            labelText: field.fieldName,
            suffixText: field.unitSuffix,
          ),
        );
      case 'number':
        final ctrl = _customControllers.putIfAbsent(field.id, () {
          final c = TextEditingController(text: _customValues[field.id] ?? '');
          c.addListener(_autoSave.notifyDirty);
          return c;
        });
        return TextFormField(
          controller: ctrl,
          decoration: InputDecoration(
            labelText: field.fieldName,
            suffixText: field.unitSuffix,
          ),
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
        );
      case 'boolean':
        final v = _customValues[field.id] == 'true';
        return SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: Text(field.fieldName),
          value: v,
          onChanged: (newV) {
            setState(() {
              _customValues[field.id] = newV ? 'true' : 'false';
            });
            _autoSave.notifyDirty();
          },
        );
      case 'date':
        DateTime? parsed;
        final raw = _customValues[field.id];
        if (raw != null && raw.isNotEmpty) {
          parsed = DateTime.tryParse(raw);
        }
        return _DateField(
          label: field.fieldName,
          value: parsed,
          onChanged: (newDate) {
            setState(() {
              _customValues[field.id] = newDate?.toIso8601String();
            });
            _autoSave.notifyDirty();
          },
        );
      default:
        return const SizedBox.shrink();
    }
  }

  // ─────────────────────── Lot helpers ───────────────────────

  String _composeLotLabel(
    String? manufacturer,
    String name,
    String? lotNumber,
  ) {
    final parts = <String>[
      if (manufacturer != null && manufacturer.isNotEmpty) manufacturer,
      name,
      if (lotNumber != null && lotNumber.isNotEmpty) '(Lot $lotNumber)',
    ];
    return parts.join(' ');
  }

  String _composeBrassLotLabel(BrassLotRow row) {
    final parts = <String>[
      row.name,
      if (row.caliber.isNotEmpty) '— ${row.caliber}',
    ];
    return parts.join(' ');
  }

  /// Pops a small two-or-three field dialog used for inline lot creation
  /// from any of the powder/primer/bullet pickers. Brass lots use
  /// [_showCreateBrassLotDialog] instead because they require a caliber.
  ///
  /// [parentLabel] is the parent recipe's currently-selected component label
  /// (e.g. `"Hodgdon Varget"` for powder, `"Federal #210M"` for primer). When
  /// non-empty it pre-fills the Manufacturer + Name autocompletes so the
  /// user doesn't have to retype what they just picked.
  ///
  /// IMPORTANT (Bug #9 — `_dependents.isEmpty` crash): the previous flow
  /// closed the dialog with `Navigator.pop()` and then `await`ed
  /// `onCreate(...)`. When the caller's `onCreate` callback then called
  /// `setState` on the parent State, the framework asserted because the
  /// dialog's Element was being torn down while other Elements still
  /// depended on inherited widgets that the same frame was rebuilding.
  /// Fix: run the work BEFORE popping the dialog, capture the dialog's
  /// `Navigator` and the parent's mounted-state up front, and only pop
  /// after the await resolves.
  Future<void> _showCreateLotDialog({
    required String type,
    String parentLabel = '',
    required Future<void> Function(String? mfg, String name, String? lot)
        onCreate,
  }) async {
    final parsed = _parseParentLabel(type, parentLabel);
    final mfgCtrl = TextEditingController(text: parsed.manufacturer);
    final nameCtrl = TextEditingController(text: parsed.name);
    final lotCtrl = TextEditingController();
    final formKey = GlobalKey<FormState>();
    final theme = Theme.of(context);
    final componentRepo = context.read<ComponentRepository>();

    await showDialog<void>(
      context: context,
      builder: (ctx) {
        return AlertDialog(
          title: Text('New ${_typeLabel(type)} Lot'),
          content: Form(
            key: formKey,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _ManufacturerAutocompleteField(
                    controller: mfgCtrl,
                    kind: type,
                    repo: componentRepo,
                    // Re-bind nothing here — the `_NameAutocompleteField`
                    // re-reads `mfgCtrl.text` on each rebuild, and the
                    // listener on mfgCtrl wired below triggers that
                    // rebuild whenever the manufacturer changes.
                    onChanged: () {
                      // Force the parent dialog StatefulBuilder to
                      // rebuild so the Name autocomplete refreshes its
                      // option list. We achieve this via the wrapping
                      // StatefulBuilder below.
                    },
                  ),
                  _NameAutocompleteField(
                    controller: nameCtrl,
                    kind: type,
                    manufacturerController: mfgCtrl,
                    repo: componentRepo,
                    validator: (v) => (v == null || v.trim().isEmpty)
                        ? 'Required'
                        : null,
                  ),
                  TextFormField(
                    controller: lotCtrl,
                    decoration:
                        const InputDecoration(labelText: 'Lot Number'),
                    autocorrect: false,
                    enableSuggestions: false,
                    textCapitalization: TextCapitalization.none,
                  ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () async {
                if (!formKey.currentState!.validate()) return;
                // Capture the dialog's Navigator BEFORE the await so we
                // never reach for `ctx` once the await resumes.
                final dialogNav = Navigator.of(ctx);
                // Run the create + parent setState first…
                await onCreate(
                  mfgCtrl.text.trim().isEmpty ? null : mfgCtrl.text.trim(),
                  nameCtrl.text.trim(),
                  lotCtrl.text.trim().isEmpty ? null : lotCtrl.text.trim(),
                );
                // …then close the dialog. If the dialog was already
                // disposed (e.g. user navigated away mid-await), do
                // nothing.
                if (dialogNav.mounted) {
                  dialogNav.pop();
                }
              },
              style: FilledButton.styleFrom(
                backgroundColor: theme.colorScheme.primary,
              ),
              child: const Text('Create'),
            ),
          ],
        );
      },
    );

    mfgCtrl.dispose();
    nameCtrl.dispose();
    lotCtrl.dispose();
  }

  /// Brass-lot version of [_showCreateLotDialog]. Same crash-shape fix:
  /// capture references (the parent-state's `RecipeRepository`, the
  /// dialog's `Navigator`) BEFORE any await, run the DB write +
  /// parent-state mutation first, then close the dialog only after the
  /// await resumes — and only if the dialog hasn't already been disposed.
  ///
  /// [parentLabel] is the parent recipe's currently-selected brass label
  /// (e.g. `"Lapua"`). When non-empty it pre-fills the Manufacturer
  /// autocomplete so the user doesn't have to retype what they just picked.
  Future<void> _showCreateBrassLotDialog({String parentLabel = ''}) async {
    final parsed = _parseParentLabel('brass', parentLabel);
    final nameCtrl = TextEditingController(text: parsed.name);
    final mfgCtrl = TextEditingController(text: parsed.manufacturer);
    final caliberCtrl = TextEditingController(text: _caliber.text.trim());
    final headstampCtrl = TextEditingController();
    final countCtrl = TextEditingController(text: '0');
    final formKey = GlobalKey<FormState>();
    final theme = Theme.of(context);
    // Capture the parent's repo BEFORE we `await showDialog` so we
    // never reach into the parent's BuildContext after the dialog's
    // future resumes. (`context.read` is an inherited-element lookup;
    // doing it once here is safe.)
    final repo = context.read<RecipeRepository>();
    final componentRepo = context.read<ComponentRepository>();

    await showDialog<void>(
      context: context,
      builder: (ctx) {
        return AlertDialog(
          title: const Text('New Brass Lot'),
          content: Form(
            key: formKey,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _NameAutocompleteField(
                    controller: nameCtrl,
                    kind: 'brass',
                    manufacturerController: mfgCtrl,
                    repo: componentRepo,
                    label: 'Lot Name *',
                    validator: (v) => (v == null || v.trim().isEmpty)
                        ? 'Required'
                        : null,
                  ),
                  _ManufacturerAutocompleteField(
                    controller: mfgCtrl,
                    kind: 'brass',
                    repo: componentRepo,
                    onChanged: () {},
                  ),
                  TextFormField(
                    controller: caliberCtrl,
                    decoration:
                        const InputDecoration(labelText: 'Caliber *'),
                    autocorrect: false,
                    enableSuggestions: false,
                    textCapitalization: TextCapitalization.none,
                    validator: (v) => (v == null || v.trim().isEmpty)
                        ? 'Required'
                        : null,
                  ),
                  TextFormField(
                    controller: headstampCtrl,
                    decoration: const InputDecoration(
                      labelText: 'Headstamp / Lot Marking',
                    ),
                    autocorrect: false,
                    enableSuggestions: false,
                    textCapitalization: TextCapitalization.none,
                  ),
                  TextFormField(
                    controller: countCtrl,
                    decoration:
                        const InputDecoration(labelText: 'Count'),
                    keyboardType: TextInputType.number,
                  ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () async {
                if (!formKey.currentState!.validate()) return;
                // Capture the dialog's Navigator BEFORE any await.
                final dialogNav = Navigator.of(ctx);
                final id = await repo.createBrassLot(
                  name: nameCtrl.text.trim(),
                  manufacturer: mfgCtrl.text.trim().isEmpty
                      ? null
                      : mfgCtrl.text.trim(),
                  caliber: caliberCtrl.text.trim(),
                  headstampLot: headstampCtrl.text.trim().isEmpty
                      ? null
                      : headstampCtrl.text.trim(),
                  count: int.tryParse(countCtrl.text.trim()) ?? 0,
                );
                // Update parent state first, while the dialog is still
                // mounted (so its inherited-widget dependents are still
                // hooked up).
                if (mounted) {
                  setState(() {
                    _brassLotsFuture = repo.allBrassLots();
                    _brassLotId = id;
                  });
                }
                if (dialogNav.mounted) {
                  dialogNav.pop();
                }
              },
              style: FilledButton.styleFrom(
                backgroundColor: theme.colorScheme.primary,
              ),
              child: const Text('Create'),
            ),
          ],
        );
      },
    );

    nameCtrl.dispose();
    mfgCtrl.dispose();
    caliberCtrl.dispose();
    headstampCtrl.dispose();
    countCtrl.dispose();
  }

  /// Parses the parent recipe form's currently-selected component label
  /// into a `(manufacturer, name)` pair so the new-lot dialog can pre-fill
  /// its inputs. The parsing rules mirror how each kind is rendered by
  /// [ComponentRepository.componentLabels]:
  ///
  /// * powder   — `"Hodgdon Varget"` → mfg=`"Hodgdon"`, name=`"Varget"`
  /// * primer   — `"Federal #210M"`  → mfg=`"Federal"`, name=`"210M"`
  /// * bullet   — `"Berger Long Range Hybrid Target 109gr"` →
  ///              mfg=`"Berger"`, name=`"Long Range Hybrid Target 109gr"`
  /// * brass    — `"Lapua"` (single token) → mfg=`"Lapua"`, name=`""`
  ///
  /// Empty input → empty fields. Defensive against malformed labels: never
  /// throws.
  ({String manufacturer, String name}) _parseParentLabel(
      String type, String label) {
    final raw = label.trim();
    if (raw.isEmpty) return (manufacturer: '', name: '');
    switch (type) {
      case 'primer':
        // Split on " #" or "#" — accept either form.
        final hashIdx = raw.indexOf('#');
        if (hashIdx <= 0) {
          // No '#' (or the '#' is the first char): treat as
          // manufacturer-only.
          return (manufacturer: raw, name: '');
        }
        final mfg = raw.substring(0, hashIdx).trim();
        final name = raw.substring(hashIdx + 1).trim();
        return (manufacturer: mfg, name: name);
      case 'brass':
        // Brass labels are usually a single manufacturer token.
        // If it contains whitespace, treat the first token as the mfg
        // and leave the name blank — the user can fill in a tier.
        final ws = raw.indexOf(RegExp(r'\s'));
        if (ws < 0) return (manufacturer: raw, name: '');
        return (manufacturer: raw.substring(0, ws), name: '');
      case 'powder':
      case 'bullet':
      default:
        final ws = raw.indexOf(RegExp(r'\s'));
        if (ws < 0) return (manufacturer: raw, name: '');
        final mfg = raw.substring(0, ws).trim();
        final rest = raw.substring(ws + 1).trim();
        return (manufacturer: mfg, name: rest);
    }
  }

  String _typeLabel(String type) {
    switch (type) {
      case 'powder':
        return 'Powder';
      case 'primer':
        return 'Primer';
      case 'bullet':
        return 'Bullet';
      case 'brass':
        return 'Brass';
      default:
        return type;
    }
  }

  // ─────────────────────── Custom field dialog ───────────────────────

  Future<void> _showAddCustomFieldDialog() async {
    final nameCtrl = TextEditingController();
    final unitCtrl = TextEditingController();
    final formKey = GlobalKey<FormState>();
    String fieldType = 'text';
    final theme = Theme.of(context);

    await showDialog<void>(
      context: context,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (ctx, setLocal) {
            return AlertDialog(
              title: const Text('New Custom Field'),
              content: Form(
                key: formKey,
                child: SingleChildScrollView(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      TextFormField(
                        controller: nameCtrl,
                        decoration:
                            const InputDecoration(labelText: 'Field Name *'),
                        autocorrect: false,
                        validator: (v) => (v == null || v.trim().isEmpty)
                            ? 'Required'
                            : null,
                      ),
                      const SizedBox(height: 12),
                      Text(
                        'Field Type',
                        style: theme.textTheme.labelLarge,
                      ),
                      RadioListTile<String>(
                        contentPadding: EdgeInsets.zero,
                        dense: true,
                        title: const Text('Text'),
                        value: 'text',
                        // ignore: deprecated_member_use
                        groupValue: fieldType,
                        // ignore: deprecated_member_use
                        onChanged: (v) =>
                            setLocal(() => fieldType = v ?? 'text'),
                      ),
                      RadioListTile<String>(
                        contentPadding: EdgeInsets.zero,
                        dense: true,
                        title: const Text('Number'),
                        value: 'number',
                        // ignore: deprecated_member_use
                        groupValue: fieldType,
                        // ignore: deprecated_member_use
                        onChanged: (v) =>
                            setLocal(() => fieldType = v ?? 'text'),
                      ),
                      RadioListTile<String>(
                        contentPadding: EdgeInsets.zero,
                        dense: true,
                        title: const Text('Boolean (Yes/No)'),
                        value: 'boolean',
                        // ignore: deprecated_member_use
                        groupValue: fieldType,
                        // ignore: deprecated_member_use
                        onChanged: (v) =>
                            setLocal(() => fieldType = v ?? 'text'),
                      ),
                      RadioListTile<String>(
                        contentPadding: EdgeInsets.zero,
                        dense: true,
                        title: const Text('Date'),
                        value: 'date',
                        // ignore: deprecated_member_use
                        groupValue: fieldType,
                        // ignore: deprecated_member_use
                        onChanged: (v) =>
                            setLocal(() => fieldType = v ?? 'text'),
                      ),
                      if (fieldType == 'number') ...[
                        const SizedBox(height: 8),
                        TextFormField(
                          controller: unitCtrl,
                          decoration: const InputDecoration(
                            labelText: 'Unit Suffix',
                            helperText: 'e.g. gr, fps, in',
                          ),
                          autocorrect: false,
                        ),
                      ],
                    ],
                  ),
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(ctx).pop(),
                  child: const Text('Cancel'),
                ),
                FilledButton(
                  onPressed: () async {
                    if (!formKey.currentState!.validate()) return;
                    Navigator.of(ctx).pop();
                    final repo = context.read<RecipeRepository>();
                    await repo.createCustomField(
                      entityType: 'recipe',
                      name: nameCtrl.text.trim(),
                      type: fieldType,
                      unitSuffix: fieldType == 'number' &&
                              unitCtrl.text.trim().isNotEmpty
                          ? unitCtrl.text.trim()
                          : null,
                    );
                    if (!mounted) return;
                    setState(() {
                      _customFieldsFuture =
                          repo.customFieldsForEntity('recipe');
                    });
                  },
                  style: FilledButton.styleFrom(
                    backgroundColor: theme.colorScheme.primary,
                  ),
                  child: const Text('Add'),
                ),
              ],
            );
          },
        );
      },
    );

    nameCtrl.dispose();
    unitCtrl.dispose();
  }
}

/// Brass-tinted chip used inside an [ExpansionTile.title]. Mirrors the
/// chip style used on the SAAMI screen so section markers stay visually
/// consistent with the rest of the app.
class _SectionHeader extends StatelessWidget {
  const _SectionHeader({required this.title, required this.count});

  final String title;
  final int count;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
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
        const Spacer(),
        if (count > 0)
          Padding(
            padding: const EdgeInsets.only(right: 4),
            child: Text(
              '$count',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
      ],
    );
  }
}

/// Shared dropdown widget used by the four lot pickers (powder, primer,
/// bullet, brass). Loads its option list from a Future and shows a
/// "+ Create New" tile at the bottom that delegates to a caller-supplied
/// dialog. Picking the create item does not change the dropdown value
/// directly — the caller is expected to update [selectedId] via [onChanged]
/// after the new lot lands in the DB.
class _LotPickerField<T> extends StatelessWidget {
  const _LotPickerField({
    required this.label,
    required this.future,
    required this.selectedId,
    required this.itemLabel,
    required this.itemId,
    required this.onChanged,
    required this.onCreate,
  });

  final String label;
  final Future<List<T>> future;
  final int? selectedId;
  final String Function(T) itemLabel;
  final int Function(T) itemId;
  final ValueChanged<int?> onChanged;
  final Future<void> Function() onCreate;

  static const int _createNewSentinel = -1;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return FutureBuilder<List<T>>(
      future: future,
      builder: (context, snap) {
        final rows = snap.data ?? const [];
        final hasLots = rows.isNotEmpty;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            DropdownButtonFormField<int>(
              initialValue: selectedId,
              isExpanded: true,
              decoration: InputDecoration(
                labelText: label,
                helperText: hasLots
                    ? null
                    : 'No lots yet — tap + to add one',
              ),
              items: [
                const DropdownMenuItem<int>(
                  value: null,
                  child: Text('— None —'),
                ),
                for (final row in rows)
                  DropdownMenuItem<int>(
                    value: itemId(row),
                    child: Text(
                      itemLabel(row),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                DropdownMenuItem<int>(
                  value: _createNewSentinel,
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.add, color: theme.colorScheme.primary),
                      const SizedBox(width: 6),
                      Text(
                        'Create New',
                        style: TextStyle(
                          color: theme.colorScheme.primary,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
              onChanged: (v) async {
                if (v == _createNewSentinel) {
                  await onCreate();
                  return;
                }
                onChanged(v);
              },
            ),
            if (!hasLots)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton.icon(
                    icon: const Icon(Icons.add),
                    label: const Text('Add Lot'),
                    onPressed: () async => onCreate(),
                  ),
                ),
              ),
          ],
        );
      },
    );
  }
}

/// Compact tile-style date picker. Tapping the field opens a date picker
/// limited to a sensible reload-tracking window.
class _DateField extends StatelessWidget {
  const _DateField({
    required this.label,
    required this.value,
    required this.onChanged,
  });

  final String label;
  final DateTime? value;
  final ValueChanged<DateTime?> onChanged;

  static String _format(DateTime d) {
    final m = d.month.toString().padLeft(2, '0');
    final day = d.day.toString().padLeft(2, '0');
    return '${d.year}-$m-$day';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return InkWell(
      borderRadius: BorderRadius.circular(4),
      onTap: () async {
        final now = DateTime.now();
        final picked = await showDatePicker(
          context: context,
          initialDate: value ?? now,
          firstDate: DateTime(2000),
          lastDate: DateTime(now.year + 5),
        );
        if (picked != null) onChanged(picked);
      },
      child: InputDecorator(
        decoration: InputDecoration(
          labelText: label,
          suffixIcon: value == null
              ? const Icon(Icons.calendar_today, size: 18)
              : IconButton(
                  icon: const Icon(Icons.close, size: 18),
                  tooltip: 'Clear',
                  onPressed: () => onChanged(null),
                ),
        ),
        child: Text(
          value == null ? 'Tap to pick a date' : _format(value!),
          style: theme.textTheme.bodyLarge?.copyWith(
            color: value == null
                ? theme.colorScheme.onSurfaceVariant
                : theme.colorScheme.onSurface,
          ),
        ),
      ),
    );
  }
}

/// 1-5 stepper for the Primer Flatness pressure indicator. Renders as a
/// labelled slider with a numeric value chip — easier to dial in on a
/// touch screen than typing 1-5 by hand.
class _PrimerFlatnessField extends StatelessWidget {
  const _PrimerFlatnessField({required this.value, required this.onChanged});

  final int? value;
  final ValueChanged<int?> onChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final v = value ?? 0; // 0 = unset; slider starts at 1
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text(
              'Primer Flatness',
              style: theme.textTheme.labelLarge,
            ),
            const Spacer(),
            if (value != null)
              Container(
                padding: const EdgeInsets.symmetric(
                    horizontal: 8, vertical: 2),
                decoration: BoxDecoration(
                  color: theme.colorScheme.primary.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Text(
                  '$value / 5',
                  style: theme.textTheme.labelMedium?.copyWith(
                    color: theme.colorScheme.primary,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              )
            else
              TextButton(
                onPressed: () => onChanged(3),
                child: const Text('Set'),
              ),
          ],
        ),
        Slider(
          value: v.toDouble().clamp(0, 5),
          min: 0,
          max: 5,
          divisions: 5,
          label: value == null ? '—' : '$value',
          onChanged: (newV) {
            final i = newV.round();
            onChanged(i == 0 ? null : i);
          },
        ),
        Text(
          '1 = Rounded edges, 5 = Flat / Cratered',
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
            fontStyle: FontStyle.italic,
          ),
        ),
      ],
    );
  }
}

// ─────────────────────── Lot-dialog autocomplete fields ───────────────────────
//
// Both fields below are hybrid autocomplete + free-form text fields
// driven by Flutter's stock `Autocomplete<String>` widget. They follow
// the same listener-leak-avoidance pattern as `lib/widgets/component_field.dart`
// (capture the autocomplete-owned controller exactly once, mirror to the
// caller-provided controller). Unlike `ComponentField`, these don't fetch
// labels for an entire kind — the manufacturer field shows the seeded
// manufacturers for the kind, and the name field re-resolves its option
// list based on the manufacturer the user has currently picked.

/// Manufacturer autocomplete used inside the lot-creation dialogs.
/// Pulls the seeded manufacturer list for the given component [kind] and
/// lets the user either pick one or type a custom value.
class _ManufacturerAutocompleteField extends StatefulWidget {
  const _ManufacturerAutocompleteField({
    required this.controller,
    required this.kind,
    required this.repo,
    this.onChanged,
  });

  final TextEditingController controller;
  final String kind;
  final ComponentRepository repo;
  final VoidCallback? onChanged;

  @override
  State<_ManufacturerAutocompleteField> createState() =>
      _ManufacturerAutocompleteFieldState();
}

class _ManufacturerAutocompleteFieldState
    extends State<_ManufacturerAutocompleteField> {
  late Future<List<String>> _futureOptions;

  TextEditingController? _innerController;
  VoidCallback? _innerListener;

  @override
  void initState() {
    super.initState();
    _futureOptions = widget.repo.manufacturersForKind(widget.kind);
  }

  @override
  void dispose() {
    if (_innerController != null && _innerListener != null) {
      _innerController!.removeListener(_innerListener!);
    }
    super.dispose();
  }

  void _ensureWiring(TextEditingController autocompleteCtrl) {
    if (identical(_innerController, autocompleteCtrl)) return;
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
        widget.onChanged?.call();
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
            _ensureWiring(textCtrl);
            return TextFormField(
              controller: textCtrl,
              focusNode: focusNode,
              autocorrect: false,
              enableSuggestions: false,
              textCapitalization: TextCapitalization.none,
              decoration: const InputDecoration(
                labelText: 'Manufacturer',
                helperText: 'Pick from list or type your own',
              ),
            );
          },
          onSelected: (sel) {
            widget.controller.text = sel;
            widget.onChanged?.call();
          },
          optionsViewBuilder: (context, onSelected, options) {
            return Align(
              alignment: Alignment.topLeft,
              child: Material(
                elevation: 4,
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxHeight: 240),
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

/// Product-name autocomplete used inside the lot-creation dialogs. Reads
/// the manufacturer from [manufacturerController] (subscribing to changes
/// so the option list refreshes whenever the user picks a new
/// manufacturer) and queries the seed catalog for matching products.
class _NameAutocompleteField extends StatefulWidget {
  const _NameAutocompleteField({
    required this.controller,
    required this.kind,
    required this.manufacturerController,
    required this.repo,
    this.label = 'Name *',
    this.validator,
  });

  final TextEditingController controller;
  final String kind;
  final TextEditingController manufacturerController;
  final ComponentRepository repo;
  final String label;
  final String? Function(String?)? validator;

  @override
  State<_NameAutocompleteField> createState() => _NameAutocompleteFieldState();
}

class _NameAutocompleteFieldState extends State<_NameAutocompleteField> {
  Future<List<String>> _futureOptions = Future.value(const <String>[]);
  String _lastMfg = '';

  TextEditingController? _innerController;
  VoidCallback? _innerListener;
  late VoidCallback _mfgListener;

  @override
  void initState() {
    super.initState();
    _refreshOptions();
    _mfgListener = () {
      final mfg = widget.manufacturerController.text.trim();
      if (mfg == _lastMfg) return;
      _refreshOptions();
    };
    widget.manufacturerController.addListener(_mfgListener);
  }

  void _refreshOptions() {
    _lastMfg = widget.manufacturerController.text.trim();
    final f = _lastMfg.isEmpty
        ? Future.value(const <String>[])
        : widget.repo.productsForManufacturer(widget.kind, _lastMfg);
    if (mounted) {
      setState(() {
        _futureOptions = f;
      });
    } else {
      _futureOptions = f;
    }
  }

  @override
  void dispose() {
    widget.manufacturerController.removeListener(_mfgListener);
    if (_innerController != null && _innerListener != null) {
      _innerController!.removeListener(_innerListener!);
    }
    super.dispose();
  }

  void _ensureWiring(TextEditingController autocompleteCtrl) {
    if (identical(_innerController, autocompleteCtrl)) return;
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
            _ensureWiring(textCtrl);
            return TextFormField(
              controller: textCtrl,
              focusNode: focusNode,
              autocorrect: false,
              enableSuggestions: false,
              textCapitalization: TextCapitalization.none,
              decoration: InputDecoration(
                labelText: widget.label,
                helperText: 'Pick from list or type your own',
              ),
              validator: widget.validator,
            );
          },
          onSelected: (sel) {
            widget.controller.text = sel;
          },
          optionsViewBuilder: (context, onSelected, options) {
            return Align(
              alignment: Alignment.topLeft,
              child: Material(
                elevation: 4,
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxHeight: 240),
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

/// Optional wrapper that adds a small "Why does this matter?" explainer
/// below a recipe-form field when Beginner Mode is on. The wrapper is a
/// no-op when [showTooltip] is false or [tooltip] is null — the field
/// renders unchanged. That way every form field can sit inside one of
/// these without extra branching.
class _BeginnerWrap extends StatelessWidget {
  const _BeginnerWrap({
    required this.showTooltip,
    required this.tooltip,
    required this.child,
  });

  final bool showTooltip;
  final String? tooltip;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final t = tooltip;
    if (!showTooltip || t == null || t.isEmpty) return child;
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        child,
        const SizedBox(height: 4),
        Padding(
          padding: const EdgeInsets.only(left: 4, top: 2),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(
                Icons.school_outlined,
                size: 14,
                color: theme.colorScheme.primary.withValues(alpha: 0.8),
              ),
              const SizedBox(width: 4),
              Expanded(
                child: Text(
                  t,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                    fontStyle: FontStyle.italic,
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
