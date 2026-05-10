// FILE: lib/screens/load_development/new_method_test_screen.dart
//
// ============================================================================
// WHAT THIS FILE DOES
// ============================================================================
// Method-aware "+ New Test" wizard. Replaces the legacy two-card path
// picker (Charge / Seating) with a five-card method picker (OCW,
// Audette Ladder, Satterlee, Generic, Seating). Once a method is
// picked, the wizard shows a method-tailored setup form: charge
// methods ask for charge range / step / shots-per-charge / distance;
// seating mode delegates to the legacy seating wizard for backward
// compatibility.
//
// On save, this wizard inserts a `LoadDevelopmentSessions` row with
// `methodKind` set to the picked enum value, fills in
// `distanceYd` / `shotsPerCharge`, leaves `rungsJson` empty (the new
// path stores per-shot data in `LoadDevelopmentShots`), and pushes
// `MethodTestScreen` for charge methods or the legacy detail screen
// for seating.
//
// ============================================================================
// WHY IT EXISTS IN THE ARCHITECTURE
// ============================================================================
// The legacy `NewLoadDevelopmentScreen` was built before the method
// taxonomy and is still wired for charge-vs-seating ladders that use
// the JSON-rung model. Rather than refactor that working code, the
// new method-aware path lives next to it; the list-screen "+ New
// Test" picker routes here for OCW / Ladder / Satterlee / Generic
// and to the legacy screen for seating.
//
// ============================================================================
// WHY THIS IS HARDER THAN IT LOOKS
// ============================================================================
// 1. Method defaults — each method has its own canonical charge
//    step, shots-per-charge, and starting distance. Picking the
//    method should populate sensible defaults the user can override:
//      * OCW: step 0.3 gr, 3 shots/charge, 100 yd.
//      * Ladder: step 0.3 gr, 1 shot/charge, 300 yd.
//      * Satterlee: step 0.2 gr, 1 shot/charge, 100 yd, 10 charges.
//      * Generic: step 0.3 gr, 3 shots/charge, 100 yd.
// 2. Distance, charge step, and shots-per-charge are all
//    ballistics-affecting "yardage" defaults per CLAUDE.md § 0
//    bucket 4 — sensible placeholders are fine. Powder, bullet,
//    primer, brass come from the source recipe and stay
//    user-pickable. The bullet/rifle/environment trio in the
//    ballistics solver is not touched here.
// 3. The wizard validates start/end/step before allowing save and
//    shows a live preview of the resulting charge ladder under the
//    inputs (mirrors the legacy wizard so the muscle memory carries
//    over).
//
// ============================================================================
// WHO CONSUMES THIS FILE
// ============================================================================
// - lib/screens/load_development/load_development_list_screen.dart
//   ("+ New Test" picker FAB).
//
// ============================================================================
// SIDE EFFECTS
// ============================================================================
// Reads firearms / recipes via their repositories. Inserts a session
// row via `LoadDevelopmentRepository.insert`. PushReplaces to
// `MethodTestScreen` (charge methods) or `LoadDevelopmentDetailScreen`
// (seating).

import 'package:drift/drift.dart' as drift;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../database/database.dart';
import '../../repositories/firearm_repository.dart';
import '../../repositories/load_development_repository.dart';
import '../../repositories/recipe_repository.dart';
import '../../widgets/component_field.dart';
import 'method_test_screen.dart';
import 'new_load_development_screen.dart';
import 'widgets/method_explainer.dart';

/// Method-aware new-test wizard. Renders the method picker first, then
/// a method-tailored setup form.
class NewMethodTestScreen extends StatefulWidget {
  const NewMethodTestScreen({
    super.key,
    this.preselectedMethod,
    this.preselectedSourceRecipeId,
  });

  /// When non-null, skip the method picker and start the wizard at the
  /// given method.
  final MethodKind? preselectedMethod;

  /// When non-null, pre-fill the source recipe (and its components).
  final int? preselectedSourceRecipeId;

  @override
  State<NewMethodTestScreen> createState() => _NewMethodTestScreenState();
}

class _NewMethodTestScreenState extends State<NewMethodTestScreen> {
  MethodKind? _method;
  Future<_NewMethodRefs>? _refsFuture;
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _name;
  late final TextEditingController _cartridge;
  late final TextEditingController _powder;
  late final TextEditingController _bullet;
  late final TextEditingController _primer;
  late final TextEditingController _start;
  late final TextEditingController _end;
  late final TextEditingController _step;
  late final TextEditingController _distance;
  late final TextEditingController _shotsPerCharge;
  late final TextEditingController _notes;

  int? _firearmId;
  int? _sourceRecipeId;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _method = widget.preselectedMethod;
    _sourceRecipeId = widget.preselectedSourceRecipeId;
    _name = TextEditingController(text: _defaultName());
    _cartridge = TextEditingController();
    _powder = TextEditingController();
    _bullet = TextEditingController();
    _primer = TextEditingController();
    _start = TextEditingController();
    _end = TextEditingController();
    _step = TextEditingController();
    _distance = TextEditingController();
    _shotsPerCharge = TextEditingController();
    _notes = TextEditingController();
    if (_method != null) {
      _applyMethodDefaults(_method!);
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
      _distance,
      _shotsPerCharge,
      _notes,
    ]) {
      c.dispose();
    }
    super.dispose();
  }

  String _defaultName() {
    final now = DateTime.now();
    String two(int n) => n.toString().padLeft(2, '0');
    return 'Test ${now.year}-${two(now.month)}-${two(now.day)}';
  }

  void _applyMethodDefaults(MethodKind k) {
    switch (k) {
      case MethodKind.ocw:
        if (_step.text.isEmpty) _step.text = '0.3';
        if (_distance.text.isEmpty) _distance.text = '100';
        if (_shotsPerCharge.text.isEmpty) _shotsPerCharge.text = '3';
        break;
      case MethodKind.ladder:
        if (_step.text.isEmpty) _step.text = '0.3';
        if (_distance.text.isEmpty) _distance.text = '300';
        if (_shotsPerCharge.text.isEmpty) _shotsPerCharge.text = '1';
        break;
      case MethodKind.satterlee:
        if (_step.text.isEmpty) _step.text = '0.2';
        if (_distance.text.isEmpty) _distance.text = '100';
        if (_shotsPerCharge.text.isEmpty) _shotsPerCharge.text = '1';
        break;
      case MethodKind.generic:
        if (_step.text.isEmpty) _step.text = '0.3';
        if (_distance.text.isEmpty) _distance.text = '100';
        if (_shotsPerCharge.text.isEmpty) _shotsPerCharge.text = '3';
        break;
      case MethodKind.seating:
        // Seating uses a different wizard.
        break;
    }
  }

  Future<_NewMethodRefs> _loadRefs() async {
    final firearms = context.read<FirearmRepository>();
    final recipes = context.read<RecipeRepository>();
    final results = await Future.wait<dynamic>([
      firearms.watchAll().first,
      recipes.watchAll().first,
    ]);
    final refs = (
      firearms: results[0] as List<UserFirearmRow>,
      recipes: results[1] as List<UserLoadRow>,
    );
    if (_sourceRecipeId != null) {
      final src = refs.recipes.firstWhere(
        (r) => r.id == _sourceRecipeId,
        orElse: () => refs.recipes.isNotEmpty
            ? refs.recipes.first
            : UserLoadRow(
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
                powderReferenceTempCelsius: 15.6,
                isFavorite: false,
              ),
      );
      if (src.id > 0) {
        _name.text = '${src.name} — ${_methodName(_method!)}';
        if (_cartridge.text.isEmpty) _cartridge.text = src.caliber ?? '';
        if (_powder.text.isEmpty) _powder.text = src.powder ?? '';
        if (_bullet.text.isEmpty) _bullet.text = src.bullet ?? '';
        if (_primer.text.isEmpty) _primer.text = src.primer ?? '';
        if (src.powderChargeGr != null && _start.text.isEmpty) {
          // Centre the ladder around the recipe's existing charge.
          final centre = src.powderChargeGr!;
          _start.text = (centre - 1.0).toStringAsFixed(1);
          _end.text = (centre + 1.0).toStringAsFixed(1);
        }
      }
    }
    return refs;
  }

  void _selectMethod(MethodKind k) {
    if (k == MethodKind.seating) {
      // Hand off to the legacy seating wizard immediately. Seating
      // ladders use the JSON-rung schema and the existing detail
      // screen, so we route to the original flow rather than
      // duplicating it here.
      Navigator.of(context).pushReplacement(
        MaterialPageRoute(
          builder: (_) => const NewLoadDevelopmentScreen(
            preselectedSessionType: 'seating_ladder',
          ),
        ),
      );
      return;
    }
    setState(() {
      _method = k;
      _applyMethodDefaults(k);
      _refsFuture = _loadRefs();
    });
  }

  String _methodName(MethodKind k) {
    switch (k) {
      case MethodKind.ocw:
        return 'OCW Test';
      case MethodKind.ladder:
        return 'Audette Ladder';
      case MethodKind.satterlee:
        return 'Satterlee 10-shot';
      case MethodKind.generic:
        return 'Charge Ladder';
      case MethodKind.seating:
        return 'Seating Ladder';
    }
  }

  String _methodWire(MethodKind k) {
    switch (k) {
      case MethodKind.ocw:
        return 'ocw';
      case MethodKind.ladder:
        return 'ladder';
      case MethodKind.satterlee:
        return 'satterlee';
      case MethodKind.generic:
        return 'generic';
      case MethodKind.seating:
        return 'seating';
    }
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    final method = _method!;
    final start = double.tryParse(_start.text.trim());
    final end = double.tryParse(_end.text.trim());
    final step = double.tryParse(_step.text.trim());
    final distance = int.tryParse(_distance.text.trim());
    final shotsPer = int.tryParse(_shotsPerCharge.text.trim());
    if (start == null || end == null || step == null) return;
    final values = LoadDevelopmentRepository.generateRungs(
      start: start,
      end: end,
      step: step,
    );
    if (values.length < 2) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Need at least 2 charges.')),
      );
      return;
    }

    setState(() => _busy = true);
    final repo = context.read<LoadDevelopmentRepository>();
    final navigator = Navigator.of(context);

    final entry = LoadDevelopmentSessionsCompanion.insert(
      name: _name.text.trim(),
      sessionType: 'charge_ladder',
      methodKind: drift.Value(_methodWire(method)),
      cartridge: drift.Value(_nullIfEmpty(_cartridge.text)),
      firearmId: drift.Value(_firearmId),
      sourceRecipeId: drift.Value(_sourceRecipeId),
      powder: drift.Value(_nullIfEmpty(_powder.text)),
      bullet: drift.Value(_nullIfEmpty(_bullet.text)),
      primer: drift.Value(_nullIfEmpty(_primer.text)),
      startValue: start,
      endValue: end,
      stepValue: step,
      rungCount: values.length,
      distanceYd: drift.Value(distance),
      shotsPerCharge: drift.Value(shotsPer),
      notes: drift.Value(_nullIfEmpty(_notes.text)),
    );

    final id = await repo.insert(entry);
    if (!mounted) return;
    navigator.pushReplacement(MaterialPageRoute(
      builder: (_) => MethodTestScreen(sessionId: id, method: method),
    ));
  }

  String? _nullIfEmpty(String s) {
    final t = s.trim();
    return t.isEmpty ? null : t;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(_method == null
            ? 'New Load Development Test'
            : _methodName(_method!)),
      ),
      body: _method == null ? _methodPicker() : _setupForm(),
    );
  }

  Widget _methodPicker() {
    final theme = Theme.of(context);
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'Pick A Method',
            style: theme.textTheme.titleLarge,
          ),
          const SizedBox(height: 8),
          Text(
            'Each protocol uses a different shot count and analysis. Pick the '
            'one your range plan calls for; you can change methods on a future '
            'test by starting a new one.',
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 24),
          _MethodCard(
            icon: Icons.center_focus_strong_outlined,
            title: 'OCW (Newberry)',
            subtitle: '3 shots per charge · vertical-impact flat spot',
            description:
                "Fire 3 shots at each charge. Plot vertical impact vs charge. "
                'The flat spot is your node.',
            onTap: () => _selectMethod(MethodKind.ocw),
          ),
          const SizedBox(height: 12),
          _MethodCard(
            icon: Icons.linear_scale_outlined,
            title: 'Audette Ladder',
            subtitle: '1 shot per charge · vertical stacking at distance',
            description:
                'Single shot per charge fired at distance. Look for shots that '
                'stack vertically.',
            onTap: () => _selectMethod(MethodKind.ladder),
          ),
          const SizedBox(height: 12),
          _MethodCard(
            icon: Icons.speed_outlined,
            title: 'Satterlee 10-shot',
            subtitle: '1 shot per charge · MV plateau',
            description:
                '10 chronograph rounds stepping the charge. Look for an MV '
                'plateau where velocity stops climbing.',
            onTap: () => _selectMethod(MethodKind.satterlee),
          ),
          const SizedBox(height: 12),
          _MethodCard(
            icon: Icons.dashboard_customize_outlined,
            title: 'Generic Charge Ladder',
            subtitle: 'Freeform — log whatever data you have',
            description:
                'Any data-collection workflow. Per-charge stats and chart '
                'cycler tell the story.',
            onTap: () => _selectMethod(MethodKind.generic),
          ),
          const SizedBox(height: 12),
          _MethodCard(
            icon: Icons.straighten_outlined,
            title: 'Seating Depth Ladder',
            subtitle: 'CBTO ladder around an existing recipe',
            description:
                'Tune seating depth at a known charge. Uses the original '
                'ladder workflow.',
            onTap: () => _selectMethod(MethodKind.seating),
          ),
        ],
      ),
    );
  }

  Widget _setupForm() {
    return FutureBuilder<_NewMethodRefs>(
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
              MethodExplainerCard(method: _method!),
              const SizedBox(height: 16),
              _Section(
                title: 'Identification',
                children: [
                  TextFormField(
                    controller: _name,
                    decoration:
                        const InputDecoration(labelText: 'Test Name *'),
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
                ],
              ),
              const SizedBox(height: 16),
              _Section(
                title: 'Source Recipe & Firearm',
                children: [
                  _recipePicker(refs),
                  const SizedBox(height: 12),
                  _firearmPicker(refs),
                ],
              ),
              const SizedBox(height: 16),
              _Section(
                title: 'Test Setup',
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
                child: const Text('Create Test'),
              ),
              const SizedBox(height: 12),
              OutlinedButton(
                onPressed: _busy ? null : () => setState(() => _method = null),
                child: const Text('Back to Method Picker'),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _recipePicker(_NewMethodRefs refs) {
    return DropdownButtonFormField<int?>(
      initialValue: _sourceRecipeId,
      isExpanded: true,
      decoration: const InputDecoration(labelText: 'Source Recipe'),
      items: [
        const DropdownMenuItem<int?>(
          value: null,
          child: Text('— Pick A Recipe —'),
        ),
        for (final r in refs.recipes)
          DropdownMenuItem<int?>(
            value: r.id,
            child: Text(r.name, overflow: TextOverflow.ellipsis),
          ),
      ],
      onChanged: (v) {
        setState(() {
          _sourceRecipeId = v;
        });
        if (v != null) {
          final src = refs.recipes.firstWhere((r) => r.id == v);
          _name.text = '${src.name} — ${_methodName(_method!)}';
          _cartridge.text = src.caliber ?? '';
          _powder.text = src.powder ?? '';
          _bullet.text = src.bullet ?? '';
          _primer.text = src.primer ?? '';
          if (src.powderChargeGr != null && _start.text.isEmpty) {
            final centre = src.powderChargeGr!;
            _start.text = (centre - 1.0).toStringAsFixed(1);
            _end.text = (centre + 1.0).toStringAsFixed(1);
          }
        }
      },
    );
  }

  Widget _firearmPicker(_NewMethodRefs refs) {
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

  Widget _ladderInputs() {
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
                decoration: const InputDecoration(
                  labelText: 'Start (gr) *',
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
                decoration: const InputDecoration(
                  labelText: 'End (gr) *',
                ),
                validator: _validateNumber,
                onChanged: (_) => setState(() {}),
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(
              child: TextFormField(
                controller: _step,
                keyboardType: const TextInputType.numberWithOptions(
                  decimal: true,
                ),
                inputFormatters: [
                  FilteringTextInputFormatter.allow(RegExp(r'[0-9.]')),
                ],
                decoration: const InputDecoration(
                  labelText: 'Step (gr) *',
                ),
                validator: _validateNumber,
                onChanged: (_) => setState(() {}),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: TextFormField(
                controller: _shotsPerCharge,
                keyboardType: TextInputType.number,
                inputFormatters: [
                  FilteringTextInputFormatter.digitsOnly,
                ],
                decoration: const InputDecoration(
                  labelText: 'Shots Per Charge',
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        TextFormField(
          controller: _distance,
          keyboardType: TextInputType.number,
          inputFormatters: [
            FilteringTextInputFormatter.digitsOnly,
          ],
          decoration: const InputDecoration(
            labelText: 'Distance (yd)',
            helperText:
                'Vertical-impact analysis is most useful at typical bullet '
                'group distance for your cartridge.',
          ),
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
      return _previewMessage('Fill in start, end, and step to preview charges.');
    }
    if (end <= start) return _previewMessage('End must be greater than start.');
    if (step <= 0) return _previewMessage('Step must be positive.');
    final values = LoadDevelopmentRepository.generateRungs(
      start: start,
      end: end,
      step: step,
    );
    if (values.length < 2) {
      return _previewMessage('Need at least 2 charges — reduce step size.');
    }
    final shots = int.tryParse(_shotsPerCharge.text.trim()) ?? 1;
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
            '${values.length} charges · ${values.length * shots} total rounds',
            style: theme.textTheme.titleSmall?.copyWith(
              color: theme.colorScheme.primary,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            '${values.map((v) => v.toStringAsFixed(2)).join(' · ')} gr',
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

class _MethodCard extends StatelessWidget {
  const _MethodCard({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.description,
    required this.onTap,
  });

  final IconData icon;
  final String title;
  final String subtitle;
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
                child: Icon(icon, color: theme.colorScheme.primary),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title, style: theme.textTheme.titleMedium),
                    const SizedBox(height: 2),
                    Text(
                      subtitle,
                      style: theme.textTheme.labelMedium?.copyWith(
                        color: theme.colorScheme.primary,
                      ),
                    ),
                    const SizedBox(height: 6),
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

typedef _NewMethodRefs = ({
  List<UserFirearmRow> firearms,
  List<UserLoadRow> recipes,
});

/// Brass-tinted section header. Mirrors the legacy wizard's `_Section`.
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
                    horizontal: 10, vertical: 6),
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

