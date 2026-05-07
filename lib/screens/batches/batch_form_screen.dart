import 'dart:convert';

import 'package:drift/drift.dart' as drift;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../database/database.dart';
import '../../repositories/batch_repository.dart';
import '../../repositories/brass_lot_repository.dart';
import '../../repositories/firearm_repository.dart';
import '../../repositories/process_step_repository.dart';
import '../../repositories/recipe_repository.dart';

class BatchFormScreen extends StatefulWidget {
  const BatchFormScreen({super.key, this.existing});

  final BatchRow? existing;

  @override
  State<BatchFormScreen> createState() => _BatchFormScreenState();
}

class _BatchFormScreenState extends State<BatchFormScreen> {
  final _formKey = GlobalKey<FormState>();

  late final TextEditingController _name;
  late final TextEditingController _count;
  late final TextEditingController _firedCount;
  late final TextEditingController _notes;

  int? _recipeId;
  int? _brassLotId;
  int? _firearmId;
  DateTime? _loadedAt;

  bool _busy = false;
  Future<_Refs>? _refsFuture;

  @override
  void initState() {
    super.initState();
    final e = widget.existing;
    _name = TextEditingController(
      text: e?.name ?? _defaultBatchName(),
    );
    _count = TextEditingController(text: (e?.count ?? 100).toString());
    _firedCount =
        TextEditingController(text: (e?.firedCount ?? 0).toString());
    _notes = TextEditingController(text: e?.notes ?? '');
    _recipeId = e?.recipeId;
    _brassLotId = e?.brassLotId;
    _firearmId = e?.firearmId;
    _loadedAt = e?.loadedAt;

    _refsFuture = _loadRefs();
  }

  @override
  void dispose() {
    for (final c in [_name, _count, _firedCount, _notes]) {
      c.dispose();
    }
    super.dispose();
  }

  String _defaultBatchName() {
    final now = DateTime.now();
    String two(int n) => n.toString().padLeft(2, '0');
    return '100rd batch ${now.year}-${two(now.month)}-${two(now.day)}';
  }

  Future<_Refs> _loadRefs() async {
    final recipes = context.read<RecipeRepository>();
    final lots = context.read<BrassLotRepository>();
    final firearms = context.read<FirearmRepository>();
    final results = await Future.wait<dynamic>([
      // RecipeRepository.watchAll is a stream — pull a single snapshot.
      recipes.watchAll().first,
      lots.getAll(),
      firearms.watchAll().first,
    ]);
    return (
      recipes: results[0] as List<UserLoadRow>,
      lots: results[1] as List<BrassLotRow>,
      firearms: results[2] as List<UserFirearmRow>,
    );
  }

  int _parseInt(TextEditingController c) {
    final v = int.tryParse(c.text.trim()) ?? 0;
    return v < 0 ? 0 : v;
  }

  String? _nullIfEmpty(TextEditingController c) {
    final t = c.text.trim();
    return t.isEmpty ? null : t;
  }

  String _formatDate(DateTime d) {
    String two(int n) => n.toString().padLeft(2, '0');
    return '${d.year}-${two(d.month)}-${two(d.day)}';
  }

  Future<void> _pickLoadedDate() async {
    final now = DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: _loadedAt ?? now,
      firstDate: DateTime(now.year - 30),
      lastDate: DateTime(now.year + 1),
    );
    if (picked != null) setState(() => _loadedAt = picked);
  }

  /// Builds the initial process-state JSON for a new batch by enabling
  /// every process step (so the user has the full default checklist
  /// pre-populated, all unchecked).
  Future<String> _buildInitialProcessStateJson() async {
    final repo = context.read<ProcessStepRepository>();
    final steps = await repo.getAll();
    final map = <String, bool>{
      for (final s in steps) s.name: false,
    };
    return json.encode(map);
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() => _busy = true);

    final repo = context.read<BatchRepository>();
    final messenger = ScaffoldMessenger.of(context);
    final navigator = Navigator.of(context);

    final count = _parseInt(_count);
    final fired = _parseInt(_firedCount).clamp(0, count);

    final entry = BatchesCompanion(
      name: drift.Value(_name.text.trim()),
      recipeId: drift.Value(_recipeId),
      brassLotId: drift.Value(_brassLotId),
      firearmId: drift.Value(_firearmId),
      count: drift.Value(count),
      firedCount: drift.Value(fired),
      loadedAt: drift.Value(_loadedAt),
      notes: drift.Value(_nullIfEmpty(_notes)),
      processStateJson: widget.existing == null
          ? drift.Value(await _buildInitialProcessStateJson())
          : const drift.Value.absent(),
    );

    if (widget.existing == null) {
      await repo.insert(entry);
      messenger.showSnackBar(const SnackBar(content: Text('Batch saved.')));
    } else {
      await repo.update(widget.existing!.id, entry);
      messenger.showSnackBar(
        const SnackBar(content: Text('Batch updated.')),
      );
    }

    if (mounted) navigator.pop();
  }

  @override
  Widget build(BuildContext context) {
    final isEdit = widget.existing != null;
    return Scaffold(
      appBar: AppBar(title: Text(isEdit ? 'Edit Batch' : 'New Batch')),
      body: Form(
        key: _formKey,
        child: FutureBuilder<_Refs>(
          future: _refsFuture,
          builder: (context, snap) {
            if (snap.connectionState == ConnectionState.waiting) {
              return const Center(child: CircularProgressIndicator());
            }
            final refs = snap.data!;
            return ListView(
              padding: const EdgeInsets.all(16),
              children: [
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
                    DropdownButtonFormField<int?>(
                      initialValue: _recipeId,
                      isExpanded: true,
                      decoration:
                          const InputDecoration(labelText: 'Recipe'),
                      items: [
                        const DropdownMenuItem<int?>(
                          value: null,
                          child: Text('— None —'),
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
                      onChanged: (v) => setState(() => _recipeId = v),
                    ),
                    const SizedBox(height: 12),
                    DropdownButtonFormField<int?>(
                      initialValue: _brassLotId,
                      isExpanded: true,
                      decoration:
                          const InputDecoration(labelText: 'Brass Lot'),
                      items: [
                        const DropdownMenuItem<int?>(
                          value: null,
                          child: Text('— None —'),
                        ),
                        for (final l in refs.lots)
                          DropdownMenuItem<int?>(
                            value: l.id,
                            child: Text(
                              '${l.name} (${l.caliber})',
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                      ],
                      onChanged: (v) => setState(() => _brassLotId = v),
                    ),
                    const SizedBox(height: 12),
                    DropdownButtonFormField<int?>(
                      initialValue: _firearmId,
                      isExpanded: true,
                      decoration:
                          const InputDecoration(labelText: 'Firearm'),
                      items: [
                        const DropdownMenuItem<int?>(
                          value: null,
                          child: Text('— None —'),
                        ),
                        for (final f in refs.firearms)
                          DropdownMenuItem<int?>(
                            value: f.id,
                            child: Text(
                              f.name,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                      ],
                      onChanged: (v) => setState(() => _firearmId = v),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                _Section(
                  title: 'Counts',
                  children: [
                    TextFormField(
                      controller: _count,
                      decoration: const InputDecoration(
                        labelText: 'Count (rounds in batch) *',
                      ),
                      keyboardType: TextInputType.number,
                      inputFormatters: [
                        FilteringTextInputFormatter.digitsOnly,
                      ],
                      validator: (v) {
                        final n = int.tryParse((v ?? '').trim());
                        if (n == null || n <= 0) {
                          return 'Must be a positive integer';
                        }
                        return null;
                      },
                    ),
                    const SizedBox(height: 12),
                    TextFormField(
                      controller: _firedCount,
                      decoration: const InputDecoration(
                        labelText: 'Fired Count',
                      ),
                      keyboardType: TextInputType.number,
                      inputFormatters: [
                        FilteringTextInputFormatter.digitsOnly,
                      ],
                    ),
                    const SizedBox(height: 12),
                    InputDecorator(
                      decoration:
                          const InputDecoration(labelText: 'Loaded At'),
                      child: Row(
                        children: [
                          Expanded(
                            child: Text(
                              _loadedAt == null
                                  ? 'Not set'
                                  : _formatDate(_loadedAt!),
                            ),
                          ),
                          if (_loadedAt != null)
                            IconButton(
                              tooltip: 'Clear',
                              icon: const Icon(Icons.clear),
                              onPressed: () =>
                                  setState(() => _loadedAt = null),
                            ),
                          IconButton(
                            tooltip: 'Pick date',
                            icon: const Icon(Icons.calendar_today_outlined),
                            onPressed: _pickLoadedDate,
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                _Section(
                  title: 'Notes',
                  children: [
                    TextFormField(
                      controller: _notes,
                      decoration: const InputDecoration(labelText: 'Notes'),
                      maxLines: 4,
                    ),
                  ],
                ),
                const SizedBox(height: 24),
                FilledButton(
                  onPressed: _busy ? null : _save,
                  child: Text(isEdit ? 'Save Changes' : 'Create Batch'),
                ),
                const SizedBox(height: 24),
              ],
            );
          },
        ),
      ),
    );
  }
}

typedef _Refs = ({
  List<UserLoadRow> recipes,
  List<BrassLotRow> lots,
  List<UserFirearmRow> firearms,
});

/// Brass-tinted section header + bordered card.
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
