import 'package:drift/drift.dart' as drift;
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../database/database.dart';
import '../../repositories/component_repository.dart';
import '../../repositories/recipe_repository.dart';
import '../../widgets/component_field.dart';
import '../../widgets/primer_cascade_field.dart';

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
///   Primer Pocket Size, Shoulder Bump, Mandrel Size.
/// * [all] — every field. Identical to [detailed] for now; a future pass
///   will introduce 80+ fields that live exclusively under this level.
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
  recipeName,
  caliber,
  powder,
  powderCharge,
  primer,
  primerSize,
  primerDepth,
  bullet,
  bulletWeight,
  seatingDepth,
  cbto,
  brass,
  primerPocketSize,
  shoulderBump,
  mandrelSize,
  coal,
  notes,
}

/// Declarative description of one field on the recipe form.
///
/// New fields are added by:
///   1. Append a new value to [_FieldId].
///   2. Add a `_FieldDef` for it inside `_buildFieldDefs`.
///   3. Add the id to whichever `_Section.fields` list it belongs in.
///
/// No other changes to the form rendering loop are required.
class _FieldDef {
  const _FieldDef({
    required this.id,
    required this.label,
    required this.level,
    required this.aliases,
    required this.builder,
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
}

/// Declarative description of one collapsible section on the form.
class _Section {
  const _Section({
    required this.id,
    required this.title,
    required this.fieldIds,
  });

  /// Stable id used for `PageStorageKey` so each section's expansion
  /// state survives scrolling and rebuilds.
  final String id;

  /// Header label, shown in the brass-tinted chip on the section header.
  final String title;

  /// Field ids that live in this section, in display order.
  final List<_FieldId> fieldIds;
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

  /// Picked from the dropdown; `null` means user hasn't selected one yet.
  String? _primerSize;
  String? _primerPocketSize;

  /// Active detail level. Loaded from SharedPreferences in [initState];
  /// defaults to [DetailLevel.basic] until the load completes.
  DetailLevel _detailLevel = DetailLevel.basic;

  /// Current filter query. When non-empty, filter takes priority over
  /// [_detailLevel] — every field whose label/alias matches shows.
  String _query = '';

  bool _busy = false;

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

    // Hydrate the user's saved detail-level preference. Done lazily so the
    // first frame doesn't block on disk I/O.
    // ignore: discarded_futures
    _loadDetailLevel();
  }

  @override
  void dispose() {
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
    ]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _loadDetailLevel() async {
    final prefs = await SharedPreferences.getInstance();
    final stored = prefs.getString(DetailLevel._prefsKey);
    if (!mounted) return;
    setState(() => _detailLevel = DetailLevel.fromPrefs(stored));
  }

  Future<void> _persistDetailLevel(DetailLevel level) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(DetailLevel._prefsKey, level.prefsValue);
  }

  double? _parseDouble(TextEditingController c) {
    final t = c.text.trim();
    if (t.isEmpty) return null;
    return double.tryParse(t);
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

    final entry = UserLoadsCompanion(
      name: drift.Value(_name.text.trim()),
      caliber: drift.Value(
          _caliber.text.trim().isEmpty ? null : _caliber.text.trim()),
      powder: drift.Value(
          _powder.text.trim().isEmpty ? null : _powder.text.trim()),
      powderChargeGr: drift.Value(_parseDouble(_powderCharge)),
      bullet: drift.Value(
          _bullet.text.trim().isEmpty ? null : _bullet.text.trim()),
      bulletWeightGr: drift.Value(_parseDouble(_bulletWeight)),
      primer: drift.Value(
          _primer.text.trim().isEmpty ? null : _primer.text.trim()),
      brass: drift.Value(
          _brass.text.trim().isEmpty ? null : _brass.text.trim()),
      coalIn: drift.Value(_parseDouble(_coal)),
      cbtoIn: drift.Value(_parseDouble(_cbto)),
      seatingDepthIn: drift.Value(_parseDouble(_seatingDepth)),
      primerDepthCps: drift.Value(_parseDouble(_primerDepth)),
      shoulderBumpIn: drift.Value(_parseDouble(_shoulderBump)),
      mandrelSizeIn: drift.Value(_parseDouble(_mandrelSize)),
      notes: drift.Value(
          _notes.text.trim().isEmpty ? null : _notes.text.trim()),
    );

    if (widget.existing == null) {
      await repo.insert(entry);
      messenger.showSnackBar(const SnackBar(content: Text('Recipe saved.')));
    } else {
      await repo.update(widget.existing!.id, entry);
      messenger.showSnackBar(const SnackBar(content: Text('Recipe updated.')));
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
  Map<_FieldId, _FieldDef> _buildFieldDefs() {
    return {
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
        builder: (ctx) => TextFormField(
          controller: _powderCharge,
          decoration: const InputDecoration(
            labelText: 'Powder Charge (gr)',
            suffixText: 'gr',
          ),
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
        ),
      ),
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
          onChanged: (v) => setState(() => _primerSize = v),
        ),
      ),
      _FieldId.primerDepth: _FieldDef(
        id: _FieldId.primerDepth,
        label: 'Primer Depth',
        level: DetailLevel.detailed,
        aliases: const ['cps', 'cup', 'seating'],
        builder: (ctx) => TextFormField(
          controller: _primerDepth,
          decoration: const InputDecoration(
            labelText: 'Primer Depth (in)',
            suffixText: 'in',
            helperText: 'CPS, in 0.001" units',
          ),
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
        ),
      ),
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
        builder: (ctx) => TextFormField(
          controller: _bulletWeight,
          decoration: const InputDecoration(
            labelText: 'Bullet Weight (gr)',
            suffixText: 'gr',
          ),
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
        ),
      ),
      _FieldId.seatingDepth: _FieldDef(
        id: _FieldId.seatingDepth,
        label: 'Seating Depth',
        level: DetailLevel.detailed,
        aliases: const ['seat', 'jump', 'jam'],
        builder: (ctx) => TextFormField(
          controller: _seatingDepth,
          decoration: const InputDecoration(
            labelText: 'Seating Depth (in)',
            suffixText: 'in',
          ),
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
        ),
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
        builder: (ctx) => TextFormField(
          controller: _cbto,
          decoration: const InputDecoration(
            labelText: 'CBTO (in)',
            suffixText: 'in',
            helperText: 'Cartridge base to ogive',
          ),
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
        ),
      ),
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
          onChanged: (v) => setState(() => _primerPocketSize = v),
        ),
      ),
      _FieldId.shoulderBump: _FieldDef(
        id: _FieldId.shoulderBump,
        label: 'Shoulder Bump',
        level: DetailLevel.detailed,
        aliases: const ['bump', 'sizing', 'headspace'],
        builder: (ctx) => TextFormField(
          controller: _shoulderBump,
          decoration: const InputDecoration(
            labelText: 'Shoulder Bump (in)',
            suffixText: 'in',
          ),
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
        ),
      ),
      _FieldId.mandrelSize: _FieldDef(
        id: _FieldId.mandrelSize,
        label: 'Mandrel Size',
        level: DetailLevel.detailed,
        aliases: const ['neck', 'tension', 'expander'],
        builder: (ctx) => TextFormField(
          controller: _mandrelSize,
          decoration: const InputDecoration(
            labelText: 'Mandrel Size (in)',
            suffixText: 'in',
          ),
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
        ),
      ),
      _FieldId.coal: _FieldDef(
        id: _FieldId.coal,
        label: 'COAL',
        level: DetailLevel.basic,
        aliases: const ['overall', 'length', 'oal', 'cartridge'],
        builder: (ctx) => TextFormField(
          controller: _coal,
          decoration: const InputDecoration(
            labelText: 'COAL (in)',
            suffixText: 'in',
          ),
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
        ),
      ),
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
      fieldIds: [_FieldId.recipeName, _FieldId.caliber],
    ),
    _Section(
      id: 'powder',
      title: 'Powder',
      fieldIds: [_FieldId.powder, _FieldId.powderCharge],
    ),
    _Section(
      id: 'primer',
      title: 'Primer',
      fieldIds: [
        _FieldId.primer,
        _FieldId.primerSize,
        _FieldId.primerDepth,
      ],
    ),
    _Section(
      id: 'bullet',
      title: 'Bullet',
      fieldIds: [
        _FieldId.bullet,
        _FieldId.bulletWeight,
        _FieldId.seatingDepth,
        _FieldId.cbto,
      ],
    ),
    _Section(
      id: 'brass',
      title: 'Brass',
      fieldIds: [
        _FieldId.brass,
        _FieldId.primerPocketSize,
        _FieldId.shoulderBump,
        _FieldId.mandrelSize,
      ],
    ),
    _Section(
      id: 'dimensions',
      title: 'Loaded Round Dimensions',
      fieldIds: [_FieldId.coal],
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

    return Scaffold(
      appBar: AppBar(title: Text(isEdit ? 'Edit Recipe' : 'New Recipe')),
      body: Form(
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
                  FilledButton(
                    onPressed: _busy ? null : _save,
                    child: Text(isEdit ? 'Save Changes' : 'Create Recipe'),
                  ),
                  const SizedBox(height: 16),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  bool _noVisibleFields(
    Map<_FieldId, _FieldDef> defs,
    List<String> tokens,
  ) {
    for (final s in _sections) {
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
  }) {
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

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Card(
        clipBehavior: Clip.antiAlias,
        child: ExpansionTile(
          key: tileKey,
          initiallyExpanded: initiallyExpanded,
          tilePadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
          childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          title: _SectionHeader(
            title: section.title,
            count: visibleFields.length,
          ),
          children: [
            for (int i = 0; i < visibleFields.length; i++) ...[
              if (i > 0) const SizedBox(height: 12),
              KeyedSubtree(
                key: ValueKey('field_${visibleFields[i].id.name}'),
                child: visibleFields[i].builder(context),
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
