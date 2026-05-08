// FILE: lib/screens/batches/quick_add_batch_screen.dart
//
// ============================================================================
// WHAT THIS FILE DOES
// ============================================================================
// One-screen, no-sections batch form aimed at the "I just finished
// loading 100 rounds" scenario. Captures only:
//
//   1. Recipe (dropdown — required)
//   2. Count (number of rounds loaded — required)
//   3. Loaded-at date (defaults to today)
//
// Optional brass lot / firearm / notes are left to the detailed form.
// On save the form writes a `BatchesCompanion` to `BatchRepository`,
// seeded with a fresh `processStateJson` so the per-batch process
// checklist is ready when the user opens batch detail.
//
// ============================================================================
// WHY IT EXISTS IN THE ARCHITECTURE
// ============================================================================
// The detailed `BatchFormScreen` exposes name, recipe, brass lot,
// firearm, count, fired count, loaded-at, notes, plus a Quick Actions
// rail when editing. For a reloader who just walked away from the
// press, that's overkill — they want to log "100 rounds of Recipe X
// loaded today" and move on. Quick Add gives them three fields.
//
// Reachable from the new "Quick" extended FAB on
// `BatchesListScreen`. The original `+` FAB still pushes the detailed
// form for power users.
//
// ============================================================================
// WHY THIS IS HARDER THAN IT LOOKS
// ============================================================================
// 1. **The recipe dropdown drives a default name.** When the user
//    picks a recipe, we synthesize a batch name like
//    "100rd batch · 6.5 Creedmoor · 2026-05-08" so the resulting
//    list tile reads as something useful without forcing the user
//    to type a name. The user can still edit the name in the
//    detailed form afterward.
// 2. **`processStateJson` must seed on insert.** A new batch has to
//    carry a JSON map of every active process step set to false, so
//    `BatchDetailScreen`'s checklist renders correctly on first open.
//    We reuse the same seed-builder logic the detailed form uses.
// 3. **"Switch to detailed" preserves the row id.** Same pattern as
//    the recipe / firearm / brass-lot Quick Add screens.
//
// ============================================================================
// WHO CONSUMES THIS FILE
// ============================================================================
// - lib/screens/batches/batches_list_screen.dart — the new "Quick"
//   extended FAB pushes this screen.

import 'dart:convert';

import 'package:drift/drift.dart' as drift;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../database/database.dart';
import '../../repositories/batch_repository.dart';
import '../../repositories/process_step_repository.dart';
import '../../repositories/recipe_repository.dart';
import 'batch_form_screen.dart';

class QuickAddBatchScreen extends StatefulWidget {
  const QuickAddBatchScreen({super.key});

  @override
  State<QuickAddBatchScreen> createState() => _QuickAddBatchScreenState();
}

class _QuickAddBatchScreenState extends State<QuickAddBatchScreen> {
  final _formKey = GlobalKey<FormState>();

  final _count = TextEditingController(text: '100');

  int? _recipeId;
  DateTime _loadedAt = DateTime.now();

  bool _busy = false;

  Future<List<UserLoadRow>>? _recipesFuture;

  @override
  void initState() {
    super.initState();
    final repo = context.read<RecipeRepository>();
    _recipesFuture = repo.watchAll().first;
  }

  @override
  void dispose() {
    _count.dispose();
    super.dispose();
  }

  Future<String> _buildInitialProcessStateJson() async {
    final repo = context.read<ProcessStepRepository>();
    final steps = await repo.getAll();
    final map = <String, bool>{
      for (final s in steps) s.name: false,
    };
    return jsonEncode(map);
  }

  String _defaultName(UserLoadRow? recipe, int count) {
    final today = _formatDate(_loadedAt);
    final caliber = recipe?.caliber;
    if (caliber != null && caliber.trim().isNotEmpty) {
      return '${count}rd batch · ${caliber.trim()} · $today';
    }
    final name = recipe?.name;
    if (name != null && name.trim().isNotEmpty) {
      return '${count}rd batch · ${name.trim()} · $today';
    }
    return '${count}rd batch · $today';
  }

  String _formatDate(DateTime d) {
    String two(int n) => n.toString().padLeft(2, '0');
    return '${d.year}-${two(d.month)}-${two(d.day)}';
  }

  /// Persist the row, returning its new id (or null on validation
  /// failure). Shared between [_save] (insert + pop) and
  /// [_switchToDetailed] (insert + push detailed form).
  Future<int?> _persist({
    required bool showSnack,
    required List<UserLoadRow> recipes,
  }) async {
    if (!_formKey.currentState!.validate()) return null;
    if (_recipeId == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Pick a recipe first.')),
      );
      return null;
    }
    setState(() => _busy = true);
    try {
      final count = int.tryParse(_count.text.trim()) ?? 0;
      final repo = context.read<BatchRepository>();
      final recipe = recipes.where((r) => r.id == _recipeId).cast<UserLoadRow?>().firstOrNull;
      final processStateJson = await _buildInitialProcessStateJson();
      final id = await repo.insert(
        BatchesCompanion(
          name: drift.Value(_defaultName(recipe, count)),
          recipeId: drift.Value(_recipeId),
          count: drift.Value(count),
          loadedAt: drift.Value(_loadedAt),
          processStateJson: drift.Value(processStateJson),
        ),
      );
      if (mounted && showSnack) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Batch saved.')),
        );
      }
      return id;
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _save(List<UserLoadRow> recipes) async {
    final id = await _persist(showSnack: true, recipes: recipes);
    if (id == null || !mounted) return;
    Navigator.of(context).pop();
  }

  Future<void> _switchToDetailed(List<UserLoadRow> recipes) async {
    final id = await _persist(showSnack: false, recipes: recipes);
    if (id == null || !mounted) return;
    final repo = context.read<BatchRepository>();
    final row = await repo.getById(id);
    if (row == null || !mounted) return;
    Navigator.of(context).pushReplacement(
      MaterialPageRoute(
        builder: (_) => BatchFormScreen(existing: row),
      ),
    );
  }

  Future<void> _pickDate() async {
    final now = DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: _loadedAt,
      firstDate: DateTime(now.year - 30),
      lastDate: DateTime(now.year + 1),
    );
    if (picked != null) {
      setState(() => _loadedAt = picked);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Quick Add Batch')),
      body: AbsorbPointer(
        absorbing: _busy,
        child: FutureBuilder<List<UserLoadRow>>(
          future: _recipesFuture,
          builder: (context, snap) {
            if (snap.connectionState != ConnectionState.done) {
              return const Center(child: CircularProgressIndicator());
            }
            final recipes = snap.data ?? const <UserLoadRow>[];
            if (recipes.isEmpty) {
              return _NoRecipesState(theme: theme);
            }
            return Form(
              key: _formKey,
              child: ListView(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
                children: [
                  DropdownButtonFormField<int?>(
                    initialValue: _recipeId,
                    isExpanded: true,
                    decoration: const InputDecoration(
                      labelText: 'Recipe *',
                      helperText: 'Which load did you build?',
                    ),
                    items: [
                      for (final r in recipes)
                        DropdownMenuItem<int?>(
                          value: r.id,
                          child: Text(
                            r.caliber == null || r.caliber!.trim().isEmpty
                                ? r.name
                                : '${r.name} · ${r.caliber}',
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                    ],
                    validator: (v) => v == null ? 'Required' : null,
                    onChanged: (v) => setState(() => _recipeId = v),
                  ),
                  const SizedBox(height: 12),
                  TextFormField(
                    controller: _count,
                    decoration: const InputDecoration(
                      labelText: 'Count *',
                      helperText: 'Rounds loaded in this batch',
                    ),
                    keyboardType: TextInputType.number,
                    inputFormatters: [
                      FilteringTextInputFormatter.digitsOnly,
                    ],
                    validator: (v) {
                      final n = int.tryParse((v ?? '').trim()) ?? 0;
                      return n <= 0 ? 'Must be > 0' : null;
                    },
                  ),
                  const SizedBox(height: 12),
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: Icon(
                      Icons.event_outlined,
                      color: theme.colorScheme.primary,
                    ),
                    title: const Text('Loaded On'),
                    subtitle: Text(_formatDate(_loadedAt)),
                    trailing: TextButton(
                      onPressed: _busy ? null : _pickDate,
                      child: const Text('Change'),
                    ),
                  ),
                  const SizedBox(height: 24),
                  FilledButton(
                    onPressed: _busy ? null : () => _save(recipes),
                    child: const Text('Save Batch'),
                  ),
                  const SizedBox(height: 12),
                  Center(
                    child: TextButton.icon(
                      onPressed: _busy
                          ? null
                          : () => _switchToDetailed(recipes),
                      icon: const Icon(Icons.tune),
                      label: const Text('Switch to detailed'),
                    ),
                  ),
                  const SizedBox(height: 4),
                  Center(
                    child: Text(
                      'Adds brass lot, firearm, fired count, notes, more.',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                ],
              ),
            );
          },
        ),
      ),
    );
  }
}

/// Shown when the user has zero recipes saved. Quick Add a batch is
/// meaningless without something to reference, so we point them at the
/// recipes screen instead of letting them stumble.
class _NoRecipesState extends StatelessWidget {
  const _NoRecipesState({required this.theme});

  final ThemeData theme;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.layers_outlined,
              size: 56,
              color: theme.colorScheme.primary.withValues(alpha: 0.6),
            ),
            const SizedBox(height: 16),
            Text(
              'No recipes yet',
              style: theme.textTheme.titleMedium,
            ),
            const SizedBox(height: 8),
            Text(
              'A batch references a recipe. Add a recipe first, then '
              'come back to log a batch.',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium,
            ),
            const SizedBox(height: 24),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Back'),
            ),
          ],
        ),
      ),
    );
  }
}
