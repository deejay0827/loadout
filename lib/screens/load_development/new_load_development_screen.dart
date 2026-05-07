// FILE: lib/screens/load_development/new_load_development_screen.dart
//
// ============================================================================
// WHAT THIS FILE DOES
// ============================================================================
// Wizard for creating a new Load Development session. Opens with a
// two-card path picker: Path A "Start with Charge Weight" (walk a powder
// charge ladder to find a velocity node) or Path B "Start with Seating
// Depth" (tune CBTO around an existing recipe). Once a path is picked the
// wizard transitions to a long form with Identification, Components,
// Firearm, Ladder, and Notes sections.
//
// Path A asks for cartridge + components from scratch and a start/end/step
// triple in grains. Path B requires the user to pick a source recipe from
// the recipes dropdown — picking pre-fills cartridge, powder, bullet,
// primer, brass lot, and seeds the start/end/step around the recipe's
// existing CBTO with a default 0.020" bracket and 0.005" step. Both paths
// render a live "ladder preview" card under the inputs, recomputed on
// every keystroke via LoadDevelopmentRepository.generateRungs(); the
// preview shows rung count and the comma-separated values so the user
// can sanity-check the ladder before saving.
//
// On save we call LoadDevelopmentRepository.buildInitialRungs to pre-create
// the rung array (one row per ladder value with empty measurement fields),
// JSON-encode it into rungsJson, insert the session row, and pushReplace
// to LoadDevelopmentDetailScreen so the user lands ready to enter range
// data.
//
// ============================================================================
// WHY IT EXISTS IN THE ARCHITECTURE
// ============================================================================
// Reached from the FAB on LoadDevelopmentListScreen for the cold start, and
// from the LoadDevelopmentDetailScreen analysis card via the
// preselectedSessionType / preselectedSourceRecipeId / suggestedStart hooks
// for the "start a Path B at this charge node" flow that lets a user move
// from a completed charge ladder into a seating ladder without re-entering
// component data.
//
// ============================================================================
// WHY THIS IS HARDER THAN IT LOOKS
// ============================================================================
// Path B's source-recipe pre-fill has to be done twice: once on initState
// when the wizard opens via the deep-link path with preselectedSourceRecipeId,
// and once again when the user changes the dropdown selection inside the
// form. The orElse on firstWhere has to construct a no-op UserLoadRow to
// satisfy non-null returns, but is only triggered when the recipes list
// is empty. The ladder preview validates start/end/step on every keystroke
// — bad values render an italic gray hint, not a snackbar, so the user
// isn't yelled at while typing. The rungs JSON must be initialized at
// session-create time, never at first-open of the detail screen, so the
// detail screen can rely on the array being present.
//
// ============================================================================
// WHO CONSUMES THIS FILE
// ============================================================================
// - lib/screens/load_development/load_development_list_screen.dart (FAB)
// - lib/screens/load_development/load_development_detail_screen.dart
//   (analysis-card "start Path B" flow)
//
// ============================================================================
// SIDE EFFECTS
// ============================================================================
// Reads firearms, lots, recipes via their repos. Inserts a new row via
// LoadDevelopmentRepository.insert and pushReplace to detail screen.

import 'dart:convert';

import 'package:drift/drift.dart' as drift;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../database/database.dart';
import '../../repositories/brass_lot_repository.dart';
import '../../repositories/firearm_repository.dart';
import '../../repositories/load_development_repository.dart';
import '../../repositories/recipe_repository.dart';
import '../../widgets/component_field.dart';
import 'load_development_detail_screen.dart';

/// New Load Development wizard.
///
/// Two paths:
///   * Path A — Charge ladder. User picks cartridge, firearm, components,
///     brass lot, then sets a `start..end` charge-weight range and a step
///     size. The form previews the resulting rungs live.
///   * Path B — Seating ladder. User picks an existing recipe (which
///     locks the charge weight) and sets a CBTO ladder.
///
/// Both paths land at [LoadDevelopmentDetailScreen] once the session is
/// inserted with the rungs JSON pre-populated.
class NewLoadDevelopmentScreen extends StatefulWidget {
  const NewLoadDevelopmentScreen({
    super.key,
    this.preselectedSessionType,
    this.preselectedSourceRecipeId,
    this.suggestedStart,
  });

  /// If set, skip the path-picker and start the wizard at the given path.
  /// Used by the "start a Path B from this charge node" flow on the
  /// detail screen.
  final String? preselectedSessionType;
  final int? preselectedSourceRecipeId;
  final double? suggestedStart;

  @override
  State<NewLoadDevelopmentScreen> createState() =>
      _NewLoadDevelopmentScreenState();
}

class _NewLoadDevelopmentScreenState extends State<NewLoadDevelopmentScreen> {
  /// Selected ladder type. Null until the user picks one — if non-null
  /// at start time we skip the picker via [widget.preselectedSessionType].
  String? _sessionType;

  // Form refs.
  Future<_NewSessionRefs>? _refsFuture;

  // Common form fields.
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _name;
  late final TextEditingController _cartridge;
  late final TextEditingController _powder;
  late final TextEditingController _bullet;
  late final TextEditingController _primer;
  late final TextEditingController _start;
  late final TextEditingController _end;
  late final TextEditingController _step;
  late final TextEditingController _notes;

  int? _firearmId;
  int? _brassLotId;
  int? _sourceRecipeId;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _sessionType = widget.preselectedSessionType;
    _sourceRecipeId = widget.preselectedSourceRecipeId;
    _name = TextEditingController(text: _defaultName());
    _cartridge = TextEditingController();
    _powder = TextEditingController();
    _bullet = TextEditingController();
    _primer = TextEditingController();
    _start = TextEditingController(
      text: widget.suggestedStart?.toString() ?? '',
    );
    _end = TextEditingController();
    _step = TextEditingController();
    _notes = TextEditingController();
    if (_sessionType != null) {
      _refsFuture = _loadRefs();
    }
  }

  @override
  void dispose() {
    for (final c in [
      _name,
      _cartridge,
      _powder,
      _bullet,
      _primer,
      _start,
      _end,
      _step,
      _notes,
    ]) {
      c.dispose();
    }
    super.dispose();
  }

  String _defaultName() {
    final now = DateTime.now();
    String two(int n) => n.toString().padLeft(2, '0');
    return 'Ladder ${now.year}-${two(now.month)}-${two(now.day)}';
  }

  Future<_NewSessionRefs> _loadRefs() async {
    final firearms = context.read<FirearmRepository>();
    final lots = context.read<BrassLotRepository>();
    final recipes = context.read<RecipeRepository>();
    final results = await Future.wait<dynamic>([
      firearms.watchAll().first,
      lots.getAll(),
      recipes.watchAll().first,
    ]);
    final refs = (
      firearms: results[0] as List<UserFirearmRow>,
      lots: results[1] as List<BrassLotRow>,
      recipes: results[2] as List<UserLoadRow>,
    );
    // Pre-populate fields from the source recipe (Path B preselect).
    if (_sourceRecipeId != null) {
      final src = refs.recipes.firstWhere(
        (r) => r.id == _sourceRecipeId,
        orElse: () => refs.recipes.isEmpty
            ? UserLoadRow(
                id: -1,
                name: '',
                createdAt: DateTime.now(),
                updatedAt: DateTime.now(),
                bulletMeplatTrimmed: false,
                bulletPointed: false,
                bulletWeightSorted: false,
                bulletBtoSorted: false,
                bulletDiameterSorted: false,
                ejectorMarks: false,
                crateredPrimers: false,
              )
            : refs.recipes.first,
      );
      if (src.id > 0) {
        _name.text = '${src.name} — Seating Ladder';
        if (_cartridge.text.isEmpty) _cartridge.text = src.caliber ?? '';
        if (_powder.text.isEmpty) _powder.text = src.powder ?? '';
        if (_bullet.text.isEmpty) _bullet.text = src.bullet ?? '';
        if (_primer.text.isEmpty) _primer.text = src.primer ?? '';
        _firearmId ??= null;
        _brassLotId ??= src.brassLotId;
        if (src.cbtoIn != null && _start.text.isEmpty) {
          // Suggest a small bracket centered on the recipe's CBTO.
          final cbto = src.cbtoIn!;
          _start.text = (cbto - 0.010).toStringAsFixed(3);
          _end.text = (cbto + 0.010).toStringAsFixed(3);
          _step.text = '0.005';
        }
      }
    }
    return refs;
  }

  void _selectPath(String type) {
    setState(() {
      _sessionType = type;
      _refsFuture = _loadRefs();
      // Sensible defaults for the ladder spec.
      if (type == 'charge_ladder' && _step.text.isEmpty) {
        _step.text = '0.3';
      } else if (type == 'seating_ladder' && _step.text.isEmpty) {
        _step.text = '0.005';
      }
    });
  }

  // ─────────────────────── Save ───────────────────────

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    final start = double.tryParse(_start.text.trim());
    final end = double.tryParse(_end.text.trim());
    final step = double.tryParse(_step.text.trim());
    if (start == null || end == null || step == null) return;
    final values = LoadDevelopmentRepository.generateRungs(
      start: start,
      end: end,
      step: step,
    );
    if (values.length < 2) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Need at least 2 rungs.')),
      );
      return;
    }

    setState(() => _busy = true);
    final repo = context.read<LoadDevelopmentRepository>();
    final navigator = Navigator.of(context);

    final rungs = LoadDevelopmentRepository.buildInitialRungs(
      start: start,
      end: end,
      step: step,
    );

    final entry = LoadDevelopmentSessionsCompanion.insert(
      name: _name.text.trim(),
      sessionType: _sessionType!,
      cartridge: drift.Value(_nullIfEmpty(_cartridge.text)),
      firearmId: drift.Value(_firearmId),
      sourceRecipeId: drift.Value(_sourceRecipeId),
      powder: drift.Value(_nullIfEmpty(_powder.text)),
      bullet: drift.Value(_nullIfEmpty(_bullet.text)),
      primer: drift.Value(_nullIfEmpty(_primer.text)),
      brassLotId: drift.Value(_brassLotId),
      startValue: start,
      endValue: end,
      stepValue: step,
      rungCount: values.length,
      rungsJson: drift.Value(
        json.encode(rungs.map((r) => r.toJson()).toList()),
      ),
      notes: drift.Value(_nullIfEmpty(_notes.text)),
    );

    final id = await repo.insert(entry);
    if (!mounted) return;
    navigator.pushReplacement(MaterialPageRoute(
      builder: (_) => LoadDevelopmentDetailScreen(sessionId: id),
    ));
  }

  String? _nullIfEmpty(String s) {
    final t = s.trim();
    return t.isEmpty ? null : t;
  }

  // ─────────────────────── Build ───────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(_sessionType == null
            ? 'New Load Development'
            : _sessionType == 'seating_ladder'
                ? 'Seating Depth Ladder'
                : 'Charge Weight Ladder'),
      ),
      body: _sessionType == null ? _pathPicker() : _setupForm(),
    );
  }

  Widget _pathPicker() {
    final theme = Theme.of(context);
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'Pick A Path',
            style: theme.textTheme.titleLarge,
          ),
          const SizedBox(height: 8),
          Text(
            'A development session walks you through one variable at a '
            'time. Most reloaders find their charge weight first, then '
            'tune seating depth at that charge.',
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 24),
          _PathCard(
            icon: Icons.scale_outlined,
            title: 'Start with Charge Weight',
            description:
                'Walk a powder-charge ladder to find a low-SD velocity '
                'node. Best when you have a fresh component pairing and '
                'no charge data yet.',
            onTap: () => _selectPath('charge_ladder'),
          ),
          const SizedBox(height: 16),
          _PathCard(
            icon: Icons.straighten_outlined,
            title: 'Start with Seating Depth',
            description:
                'Walk a CBTO ladder around an existing recipe to tighten '
                'groups and reduce vertical. Requires an existing recipe '
                'whose charge weight is already locked.',
            onTap: () => _selectPath('seating_ladder'),
          ),
        ],
      ),
    );
  }

  Widget _setupForm() {
    return FutureBuilder<_NewSessionRefs>(
      future: _refsFuture,
      builder: (context, snap) {
        if (snap.connectionState == ConnectionState.waiting) {
          return const Center(child: CircularProgressIndicator());
        }
        final refs = snap.data!;
        return Form(
          key: _formKey,
          child: ListView(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
            children: [
              if (_sessionType == 'seating_ladder')
                _Section(
                  title: 'Source Recipe',
                  children: [_recipePicker(refs)],
                ),
              if (_sessionType == 'seating_ladder') const SizedBox(height: 16),
              _Section(
                title: 'Identification',
                children: [
                  TextFormField(
                    controller: _name,
                    decoration: const InputDecoration(labelText: 'Name *'),
                    validator: (v) => (v == null || v.trim().isEmpty)
                        ? 'Required'
                        : null,
                  ),
                  const SizedBox(height: 12),
                  ComponentField(
                    kind: 'cartridge',
                    label: 'Cartridge',
                    controller: _cartridge,
                  ),
                ],
              ),
              const SizedBox(height: 16),
              _Section(
                title: 'Components',
                children: [
                  ComponentField(
                    kind: 'powder',
                    label: 'Powder',
                    controller: _powder,
                  ),
                  const SizedBox(height: 12),
                  ComponentField(
                    kind: 'bullet',
                    label: 'Bullet',
                    controller: _bullet,
                  ),
                  const SizedBox(height: 12),
                  ComponentField(
                    kind: 'primer',
                    label: 'Primer',
                    controller: _primer,
                  ),
                  const SizedBox(height: 12),
                  _brassLotPicker(refs),
                ],
              ),
              const SizedBox(height: 16),
              _Section(
                title: 'Firearm',
                children: [_firearmPicker(refs)],
              ),
              const SizedBox(height: 16),
              _Section(
                title: 'Ladder',
                children: [
                  _ladderInputs(),
                  const SizedBox(height: 12),
                  _ladderPreview(),
                ],
              ),
              const SizedBox(height: 16),
              _Section(
                title: 'Notes',
                children: [
                  TextFormField(
                    controller: _notes,
                    decoration: const InputDecoration(labelText: 'Notes'),
                    maxLines: 3,
                  ),
                ],
              ),
              const SizedBox(height: 24),
              FilledButton(
                onPressed: _busy ? null : _save,
                child: const Text('Create Session'),
              ),
              const SizedBox(height: 12),
              OutlinedButton(
                onPressed: _busy
                    ? null
                    : () => setState(() => _sessionType = null),
                child: const Text('Back to Path Selection'),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _recipePicker(_NewSessionRefs refs) {
    return DropdownButtonFormField<int?>(
      initialValue: _sourceRecipeId,
      isExpanded: true,
      decoration: const InputDecoration(labelText: 'Source Recipe *'),
      validator: (v) => v == null
          ? 'Pick the recipe whose seating depth you want to tune'
          : null,
      items: [
        const DropdownMenuItem<int?>(
          value: null,
          child: Text('— Pick A Recipe —'),
        ),
        for (final r in refs.recipes)
          DropdownMenuItem<int?>(
            value: r.id,
            child: Text(
              r.name,
              overflow: TextOverflow.ellipsis,
            ),
          ),
      ],
      onChanged: (v) {
        setState(() {
          _sourceRecipeId = v;
        });
        // Refresh refs so the form repopulates from the new recipe.
        if (v != null) {
          final src = refs.recipes.firstWhere(
            (r) => r.id == v,
            orElse: () => refs.recipes.first,
          );
          _name.text = '${src.name} — Seating Ladder';
          _cartridge.text = src.caliber ?? '';
          _powder.text = src.powder ?? '';
          _bullet.text = src.bullet ?? '';
          _primer.text = src.primer ?? '';
          _brassLotId = src.brassLotId;
          if (src.cbtoIn != null) {
            final cbto = src.cbtoIn!;
            _start.text = (cbto - 0.010).toStringAsFixed(3);
            _end.text = (cbto + 0.010).toStringAsFixed(3);
            _step.text = '0.005';
          }
        }
      },
    );
  }

  Widget _firearmPicker(_NewSessionRefs refs) {
    return DropdownButtonFormField<int?>(
      initialValue: _firearmId,
      isExpanded: true,
      decoration: const InputDecoration(labelText: 'Firearm'),
      items: [
        const DropdownMenuItem<int?>(
          value: null,
          child: Text('— None —'),
        ),
        for (final f in refs.firearms)
          DropdownMenuItem<int?>(
            value: f.id,
            child: Text(f.name, overflow: TextOverflow.ellipsis),
          ),
      ],
      onChanged: (v) => setState(() => _firearmId = v),
    );
  }

  Widget _brassLotPicker(_NewSessionRefs refs) {
    return DropdownButtonFormField<int?>(
      initialValue: _brassLotId,
      isExpanded: true,
      decoration: const InputDecoration(labelText: 'Brass Lot'),
      items: [
        const DropdownMenuItem<int?>(
          value: null,
          child: Text('— None —'),
        ),
        for (final l in refs.lots)
          DropdownMenuItem<int?>(
            value: l.id,
            child: Text('${l.name} (${l.caliber})',
                overflow: TextOverflow.ellipsis),
          ),
      ],
      onChanged: (v) => setState(() => _brassLotId = v),
    );
  }

  Widget _ladderInputs() {
    final isCharge = _sessionType == 'charge_ladder';
    final unit = isCharge ? 'gr' : 'in';
    return Column(
      children: [
        Row(
          children: [
            Expanded(
              child: TextFormField(
                controller: _start,
                keyboardType: const TextInputType.numberWithOptions(
                  decimal: true,
                ),
                inputFormatters: [
                  FilteringTextInputFormatter.allow(RegExp(r'[0-9.]')),
                ],
                decoration: InputDecoration(
                  labelText: 'Start ($unit) *',
                ),
                validator: _validateNumber,
                onChanged: (_) => setState(() {}),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: TextFormField(
                controller: _end,
                keyboardType: const TextInputType.numberWithOptions(
                  decimal: true,
                ),
                inputFormatters: [
                  FilteringTextInputFormatter.allow(RegExp(r'[0-9.]')),
                ],
                decoration: InputDecoration(
                  labelText: 'End ($unit) *',
                ),
                validator: _validateNumber,
                onChanged: (_) => setState(() {}),
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        TextFormField(
          controller: _step,
          keyboardType: const TextInputType.numberWithOptions(
            decimal: true,
          ),
          inputFormatters: [
            FilteringTextInputFormatter.allow(RegExp(r'[0-9.]')),
          ],
          decoration: InputDecoration(
            labelText: 'Step ($unit) *',
            helperText: isCharge
                ? 'Typical: 0.2 to 0.4 grains for rifle, 0.1 for pistol'
                : 'Typical: 0.003 to 0.005 inches',
          ),
          validator: _validateNumber,
          onChanged: (_) => setState(() {}),
        ),
      ],
    );
  }

  String? _validateNumber(String? s) {
    final v = double.tryParse((s ?? '').trim());
    if (v == null) return 'Required';
    if (v <= 0) return 'Must be positive';
    return null;
  }

  Widget _ladderPreview() {
    final start = double.tryParse(_start.text.trim());
    final end = double.tryParse(_end.text.trim());
    final step = double.tryParse(_step.text.trim());
    if (start == null || end == null || step == null) {
      return _previewMessage('Fill in start, end, and step to preview rungs.');
    }
    if (end <= start) {
      return _previewMessage('End must be greater than start.');
    }
    if (step <= 0) {
      return _previewMessage('Step must be positive.');
    }
    final values = LoadDevelopmentRepository.generateRungs(
      start: start,
      end: end,
      step: step,
    );
    if (values.length < 2) {
      return _previewMessage('Need at least 2 rungs — reduce step size.');
    }
    final unit = _sessionType == 'seating_ladder' ? 'in' : 'gr';
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: theme.colorScheme.primary.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: theme.colorScheme.primary.withValues(alpha: 0.35),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '${values.length} rungs',
            style: theme.textTheme.titleSmall?.copyWith(
              color: theme.colorScheme.primary,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            '${values.map((v) {
              final places = unit == 'gr' ? 2 : 3;
              return v.toStringAsFixed(places);
            }).join(' · ')} $unit',
            style: theme.textTheme.bodyMedium,
          ),
        ],
      ),
    );
  }

  Widget _previewMessage(String text) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Text(
        text,
        style: theme.textTheme.bodyMedium?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
          fontStyle: FontStyle.italic,
        ),
      ),
    );
  }
}

class _PathCard extends StatelessWidget {
  const _PathCard({
    required this.icon,
    required this.title,
    required this.description,
    required this.onTap,
  });

  final IconData icon;
  final String title;
  final String description;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: theme.colorScheme.primary.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Icon(
                  icon,
                  color: theme.colorScheme.primary,
                ),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: theme.textTheme.titleMedium,
                    ),
                    const SizedBox(height: 4),
                    Text(
                      description,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              const Icon(Icons.chevron_right),
            ],
          ),
        ),
      ),
    );
  }
}

typedef _NewSessionRefs = ({
  List<UserFirearmRow> firearms,
  List<BrassLotRow> lots,
  List<UserLoadRow> recipes,
});

/// Brass-tinted section header + bordered card. Mirrors the pattern in
/// `batch_form_screen.dart` to keep visual identity consistent.
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
