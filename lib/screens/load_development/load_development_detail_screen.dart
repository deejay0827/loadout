import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../database/database.dart';
import '../../repositories/brass_lot_repository.dart';
import '../../repositories/firearm_repository.dart';
import '../../repositories/load_development_repository.dart';
import '../../repositories/recipe_repository.dart';
import 'new_load_development_screen.dart';

/// Per-session dashboard for a Load Development experiment.
///
/// Sections:
///   * Header card — name, type pill, source recipe / firearm.
///   * Ladder list — one expandable rung card per row, with the right
///     measurement fields for the path type. Editing any field saves
///     the whole rung array via [LoadDevelopmentRepository.setRungs].
///   * Analysis card — runs once at least 3 rungs have data. Shows the
///     recommended node and provides "Pick This Node" buttons that
///     either offer a Path B from the chosen charge or push a CBTO
///     update back to the source recipe.
///   * Chart — bar chart for charge ladders (SD vs charge) or line
///     chart for seating ladders (group MOA vs CBTO). Hand-rolled with
///     [CustomPaint] so we don't depend on `fl_chart`.
class LoadDevelopmentDetailScreen extends StatefulWidget {
  const LoadDevelopmentDetailScreen({super.key, required this.sessionId});

  final int sessionId;

  @override
  State<LoadDevelopmentDetailScreen> createState() =>
      _LoadDevelopmentDetailScreenState();
}

class _LoadDevelopmentDetailScreenState
    extends State<LoadDevelopmentDetailScreen> {
  /// In-memory copy of the rungs list so per-rung text fields can edit
  /// values without round-tripping every keystroke through the DB. We
  /// persist on field commit (onChanged with debounce isn't needed —
  /// the per-rung editor surfaces an explicit Save button per row, but
  /// blur/focus changes also persist).
  List<LadderRung>? _rungsOverride;

  Future<void> _persistRungs(List<LadderRung> rungs) async {
    final repo = context.read<LoadDevelopmentRepository>();
    await repo.setRungs(widget.sessionId, rungs);
  }

  @override
  Widget build(BuildContext context) {
    final repo = context.read<LoadDevelopmentRepository>();
    return Scaffold(
      appBar: AppBar(title: const Text('Development Session')),
      body: StreamBuilder<LoadDevelopmentSessionRow?>(
        stream: repo.watchById(widget.sessionId),
        builder: (context, snap) {
          if (snap.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          }
          final session = snap.data;
          if (session == null) {
            return const Center(child: Text('Session not found.'));
          }
          final stored =
              LoadDevelopmentRepository.decodeRungs(session.rungsJson);
          final rungs = _rungsOverride ?? stored;
          return _DetailBody(
            session: session,
            rungs: rungs,
            onRungsChanged: (next) {
              setState(() => _rungsOverride = next);
              _persistRungs(next);
            },
          );
        },
      ),
    );
  }
}

class _DetailBody extends StatelessWidget {
  const _DetailBody({
    required this.session,
    required this.rungs,
    required this.onRungsChanged,
  });

  final LoadDevelopmentSessionRow session;
  final List<LadderRung> rungs;
  final ValueChanged<List<LadderRung>> onRungsChanged;

  bool get _isCharge => session.sessionType == 'charge_ladder';
  String get _unit => _isCharge ? 'gr' : 'in';
  int get _places => _isCharge ? 2 : 3;

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<_DetailRefs>(
      future: _loadRefs(context),
      builder: (context, snap) {
        if (snap.connectionState == ConnectionState.waiting) {
          return const Center(child: CircularProgressIndicator());
        }
        final refs = snap.data!;
        return ListView(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
          children: [
            _headerCard(context, refs),
            const SizedBox(height: 16),
            _rungsCard(context),
            const SizedBox(height: 16),
            _analysisCard(context, refs),
            const SizedBox(height: 16),
            _chartCard(context),
            if ((session.notes ?? '').isNotEmpty) ...[
              const SizedBox(height: 16),
              _notesCard(context),
            ],
          ],
        );
      },
    );
  }

  Future<_DetailRefs> _loadRefs(BuildContext context) async {
    final firearms = context.read<FirearmRepository>();
    final lots = context.read<BrassLotRepository>();
    final recipes = context.read<RecipeRepository>();
    final firearm = session.firearmId == null
        ? null
        : await firearms.getById(session.firearmId!);
    final lot = session.brassLotId == null
        ? null
        : await lots.getById(session.brassLotId!);
    final source = session.sourceRecipeId == null
        ? null
        : await recipes.getById(session.sourceRecipeId!);
    return (firearm: firearm, brassLot: lot, sourceRecipe: source);
  }

  // ─────────────────────── Header ───────────────────────

  Widget _headerCard(BuildContext context, _DetailRefs refs) {
    final theme = Theme.of(context);
    final pillColor = session.nodeValue != null
        ? theme.colorScheme.primary
        : theme.colorScheme.secondary;
    final pillLabel = session.nodeValue != null ? 'Complete' : 'In Progress';
    return Card(
      clipBehavior: Clip.antiAlias,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    session.name,
                    style: theme.textTheme.titleLarge,
                  ),
                ),
                Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 8, vertical: 4),
                  decoration: BoxDecoration(
                    color: pillColor.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(
                      color: pillColor.withValues(alpha: 0.35),
                    ),
                  ),
                  child: Text(
                    pillLabel,
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: pillColor,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                _ChipText(
                  text: _isCharge ? 'Charge Ladder' : 'Seating Ladder',
                  primary: true,
                ),
                if ((session.cartridge ?? '').isNotEmpty)
                  _ChipText(text: session.cartridge!),
                if (refs.firearm != null)
                  _ChipText(text: refs.firearm!.name),
                if (refs.brassLot != null)
                  _ChipText(text: refs.brassLot!.name),
              ],
            ),
            const SizedBox(height: 12),
            _detail(theme, 'Powder', session.powder ?? '—'),
            _detail(theme, 'Bullet', session.bullet ?? '—'),
            _detail(theme, 'Primer', session.primer ?? '—'),
            if (refs.sourceRecipe != null)
              _detail(theme, 'Source Recipe', refs.sourceRecipe!.name),
            const SizedBox(height: 4),
            _detail(
              theme,
              'Range',
              '${session.startValue}–${session.endValue} $_unit '
                  '(step ${session.stepValue})',
            ),
            if (session.nodeValue != null)
              _detail(
                theme,
                'Picked Node',
                '${session.nodeValue!.toStringAsFixed(_places)} $_unit',
              ),
          ],
        ),
      ),
    );
  }

  Widget _detail(ThemeData theme, String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        children: [
          SizedBox(
            width: 110,
            child: Text(
              label,
              style: theme.textTheme.bodySmall,
            ),
          ),
          Expanded(child: Text(value)),
        ],
      ),
    );
  }

  // ─────────────────────── Rungs ───────────────────────

  Widget _rungsCard(BuildContext context) {
    return Card(
      clipBehavior: Clip.antiAlias,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 12, 12, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Padding(
              padding: EdgeInsets.only(left: 4, bottom: 4),
              child: _SectionChip(title: 'Rungs'),
            ),
            for (var i = 0; i < rungs.length; i++)
              _RungEditor(
                key: ValueKey('rung_${session.id}_${rungs[i].index}'),
                rung: rungs[i],
                isCharge: _isCharge,
                places: _places,
                unit: _unit,
                onChanged: (next) {
                  final updated = List<LadderRung>.from(rungs);
                  updated[i] = next;
                  onRungsChanged(updated);
                },
              ),
          ],
        ),
      ),
    );
  }

  // ─────────────────────── Analysis ───────────────────────

  Widget _analysisCard(BuildContext context, _DetailRefs refs) {
    final analyzed =
        rungs.where((r) => r.hasData).length;
    if (analyzed < 3) {
      return _placeholderAnalysisCard(context, analyzed);
    }
    if (_isCharge) {
      return _chargeAnalysisCard(context);
    } else {
      return _seatingAnalysisCard(context, refs);
    }
  }

  Widget _placeholderAnalysisCard(BuildContext context, int analyzed) {
    final theme = Theme.of(context);
    return Card(
      clipBehavior: Clip.antiAlias,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const _SectionChip(title: 'Analysis'),
            const SizedBox(height: 12),
            Text(
              'Enter data on at least 3 rungs to enable analysis.',
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              '$analyzed of ${rungs.length} rungs have data.',
              style: theme.textTheme.bodySmall,
            ),
          ],
        ),
      ),
    );
  }

  Widget _chargeAnalysisCard(BuildContext context) {
    final theme = Theme.of(context);
    final analysis = LoadDevelopmentRepository.analyzeChargeNode(rungs);
    if (analysis.recommendedValue == null) {
      return Card(
        clipBehavior: Clip.antiAlias,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const _SectionChip(title: 'Analysis'),
              const SizedBox(height: 12),
              Text(
                'No consistent low-SD cluster found. Add more rung data '
                'or revisit the chrono numbers — large outliers can hide '
                'a real node.',
                style: theme.textTheme.bodyMedium,
              ),
            ],
          ),
        ),
      );
    }
    return Card(
      clipBehavior: Clip.antiAlias,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const _SectionChip(title: 'Analysis'),
            const SizedBox(height: 12),
            Text(
              'Recommended Node',
              style: theme.textTheme.labelMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              '${analysis.recommendedValue!.toStringAsFixed(_places)} $_unit',
              style: theme.textTheme.headlineMedium?.copyWith(
                color: theme.colorScheme.primary,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              'Cluster of ${analysis.clusterIndices.length} consecutive '
              'rungs with velocity SD at or below the median '
              '(${analysis.medianSd.toStringAsFixed(1)} fps).',
              style: theme.textTheme.bodyMedium,
            ),
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: () =>
                  _pickChargeNode(context, analysis.recommendedValue!),
              icon: const Icon(Icons.check_circle_outline),
              label: const Text('Pick This Node'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _seatingAnalysisCard(BuildContext context, _DetailRefs refs) {
    final theme = Theme.of(context);
    final analysis = LoadDevelopmentRepository.analyzeSeatingNode(rungs);
    if (analysis.recommendedValue == null) {
      return Card(
        clipBehavior: Clip.antiAlias,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const _SectionChip(title: 'Analysis'),
              const SizedBox(height: 12),
              Text(
                'No group / vertical data yet. Enter group size or '
                'vertical dispersion on at least one rung.',
                style: theme.textTheme.bodyMedium,
              ),
            ],
          ),
        ),
      );
    }
    return Card(
      clipBehavior: Clip.antiAlias,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const _SectionChip(title: 'Analysis'),
            const SizedBox(height: 12),
            Text(
              'Recommended CBTO',
              style: theme.textTheme.labelMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              '${analysis.recommendedValue!.toStringAsFixed(_places)} $_unit',
              style: theme.textTheme.headlineMedium?.copyWith(
                color: theme.colorScheme.primary,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              'Lowest mean of group / vertical MOA across '
              '${analysis.rungsAnalyzed} rungs '
              '(${analysis.bestScore!.toStringAsFixed(2)} MOA).',
              style: theme.textTheme.bodyMedium,
            ),
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: refs.sourceRecipe == null
                  ? null
                  : () => _pickSeatingNode(
                        context,
                        refs.sourceRecipe!,
                        analysis.recommendedValue!,
                      ),
              icon: const Icon(Icons.check_circle_outline),
              label: Text(refs.sourceRecipe == null
                  ? 'No Source Recipe Linked'
                  : 'Pick This CBTO'),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _pickChargeNode(BuildContext context, double value) async {
    final repo = context.read<LoadDevelopmentRepository>();
    final messenger = ScaffoldMessenger.of(context);
    final navigator = Navigator.of(context);

    await repo.setNode(session.id, value);
    if (!context.mounted) return;
    final start = LoadDevelopmentRepository.round(value - 0.010, places: 4);
    final wantsSeating = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Node Saved'),
        content: Text(
          'Charge node set to ${value.toStringAsFixed(_places)} grains. '
          'Start a seating-depth ladder using this node?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Not Now'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Start Seating Ladder'),
          ),
        ],
      ),
    );
    if (wantsSeating == true) {
      navigator.push(
        MaterialPageRoute(
          builder: (_) => NewLoadDevelopmentScreen(
            preselectedSessionType: 'seating_ladder',
            suggestedStart: start,
          ),
        ),
      );
    } else {
      messenger.showSnackBar(
        SnackBar(
            content:
                Text('Node ${value.toStringAsFixed(_places)} gr saved.')),
      );
    }
  }

  Future<void> _pickSeatingNode(
    BuildContext context,
    UserLoadRow source,
    double cbto,
  ) async {
    final repo = context.read<LoadDevelopmentRepository>();
    final messenger = ScaffoldMessenger.of(context);

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Update Source Recipe?'),
        content: Text(
          'This will set "${source.name}" CBTO to '
          '${cbto.toStringAsFixed(_places)} inches and save the node on '
          'this session.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Update Recipe'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await repo.setNode(session.id, cbto);
    final ok = await repo.applySeatingNodeToRecipe(
      recipeId: source.id,
      cbtoIn: cbto,
    );
    if (!context.mounted) return;
    messenger.showSnackBar(
      SnackBar(
        content: Text(
          ok
              ? 'Recipe updated. New CBTO: ${cbto.toStringAsFixed(_places)}".'
              : 'Saved node, but recipe update failed.',
        ),
      ),
    );
  }

  // ─────────────────────── Chart ───────────────────────

  Widget _chartCard(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      clipBehavior: Clip.antiAlias,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 12, 12, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Padding(
              padding: EdgeInsets.only(left: 4, bottom: 4),
              child: _SectionChip(title: 'Chart'),
            ),
            const SizedBox(height: 8),
            SizedBox(
              height: 220,
              child: _isCharge
                  ? _ChargeBarChart(rungs: rungs, places: _places)
                  : _SeatingLineChart(rungs: rungs, places: _places),
            ),
            const SizedBox(height: 8),
            Text(
              _isCharge
                  ? 'Velocity SD by Charge Weight (lower is better)'
                  : 'Mean Group/Vertical by CBTO (lower is better)',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }

  Widget _notesCard(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      clipBehavior: Clip.antiAlias,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const _SectionChip(title: 'Notes'),
            const SizedBox(height: 12),
            Text(
              session.notes!,
              style: theme.textTheme.bodyMedium,
            ),
          ],
        ),
      ),
    );
  }
}

typedef _DetailRefs = ({
  UserFirearmRow? firearm,
  BrassLotRow? brassLot,
  UserLoadRow? sourceRecipe,
});

// ─────────────────────── Per-rung editor ───────────────────────

class _RungEditor extends StatefulWidget {
  const _RungEditor({
    super.key,
    required this.rung,
    required this.isCharge,
    required this.places,
    required this.unit,
    required this.onChanged,
  });

  final LadderRung rung;
  final bool isCharge;
  final int places;
  final String unit;
  final ValueChanged<LadderRung> onChanged;

  @override
  State<_RungEditor> createState() => _RungEditorState();
}

class _RungEditorState extends State<_RungEditor> {
  late TextEditingController _v1; // velocityAvg or groupMoa
  late TextEditingController _v2; // velocitySd or verticalMoa
  late TextEditingController _v3; // velocityEs or horizontalMoa
  late TextEditingController _v4; // sampleSize or distanceYd
  late TextEditingController _notes;

  @override
  void initState() {
    super.initState();
    _v1 = TextEditingController(text: _initial(widget.isCharge
        ? widget.rung.velocityAvgFps
        : widget.rung.groupMoa));
    _v2 = TextEditingController(text: _initial(widget.isCharge
        ? widget.rung.velocitySdFps
        : widget.rung.verticalMoa));
    _v3 = TextEditingController(text: _initial(widget.isCharge
        ? widget.rung.velocityEsFps
        : widget.rung.horizontalMoa));
    _v4 = TextEditingController(text: _initial(widget.isCharge
        ? widget.rung.sampleSize
        : widget.rung.distanceYd));
    _notes = TextEditingController(
      text: widget.isCharge
          ? widget.rung.pressureNotes ?? ''
          : widget.rung.notes ?? '',
    );
  }

  @override
  void didUpdateWidget(covariant _RungEditor old) {
    super.didUpdateWidget(old);
    // If the parent re-issues the rung (e.g. from a fresh DB stream),
    // reconcile any external-only fields. Skip when the user is mid-edit
    // (heuristic: only update if the controller text doesn't already
    // match the new value).
    void sync(TextEditingController c, String fresh) {
      if (c.text != fresh) c.text = fresh;
    }

    sync(
      _v1,
      _initial(widget.isCharge
          ? widget.rung.velocityAvgFps
          : widget.rung.groupMoa),
    );
    sync(
      _v2,
      _initial(widget.isCharge
          ? widget.rung.velocitySdFps
          : widget.rung.verticalMoa),
    );
    sync(
      _v3,
      _initial(widget.isCharge
          ? widget.rung.velocityEsFps
          : widget.rung.horizontalMoa),
    );
    sync(
      _v4,
      _initial(widget.isCharge
          ? widget.rung.sampleSize
          : widget.rung.distanceYd),
    );
  }

  @override
  void dispose() {
    for (final c in [_v1, _v2, _v3, _v4, _notes]) {
      c.dispose();
    }
    super.dispose();
  }

  String _initial(Object? value) {
    if (value == null) return '';
    return value.toString();
  }

  double? _double(TextEditingController c) {
    final t = c.text.trim();
    if (t.isEmpty) return null;
    return double.tryParse(t);
  }

  int? _int(TextEditingController c) {
    final t = c.text.trim();
    if (t.isEmpty) return null;
    return int.tryParse(t);
  }

  void _commit() {
    final updated = widget.isCharge
        ? widget.rung.copyWith(
            velocityAvgFps: _double(_v1),
            velocitySdFps: _double(_v2),
            velocityEsFps: _double(_v3),
            sampleSize: _int(_v4),
            pressureNotes: _notes.text.trim().isEmpty ? null : _notes.text.trim(),
            fired: true,
          )
        : widget.rung.copyWith(
            groupMoa: _double(_v1),
            verticalMoa: _double(_v2),
            horizontalMoa: _double(_v3),
            distanceYd: _int(_v4),
            notes: _notes.text.trim().isEmpty ? null : _notes.text.trim(),
            fired: true,
          );
    widget.onChanged(updated);
  }

  void _toggleFired() {
    widget.onChanged(widget.rung.copyWith(fired: !widget.rung.fired));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final marker = '${widget.rung.value.toStringAsFixed(widget.places)} '
        '${widget.unit}';
    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(
          color: widget.rung.hasData
              ? theme.colorScheme.primary.withValues(alpha: 0.4)
              : theme.colorScheme.outlineVariant,
        ),
      ),
      margin: const EdgeInsets.symmetric(vertical: 6),
      child: ExpansionTile(
        tilePadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
        childrenPadding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
        title: Row(
          children: [
            Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              decoration: BoxDecoration(
                color: theme.colorScheme.primary.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(
                'R${widget.rung.index + 1}',
                style: theme.textTheme.labelSmall?.copyWith(
                  color: theme.colorScheme.primary,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                marker,
                style: theme.textTheme.titleMedium,
              ),
            ),
            if (widget.rung.hasData)
              Padding(
                padding: const EdgeInsets.only(right: 8),
                child: Icon(
                  Icons.check_circle_outline,
                  color: theme.colorScheme.primary,
                  size: 20,
                ),
              ),
          ],
        ),
        children: [
          if (widget.isCharge)
            _chargeFields(theme)
          else
            _seatingFields(theme),
          const SizedBox(height: 8),
          TextField(
            controller: _notes,
            maxLines: 2,
            decoration: InputDecoration(
              labelText: widget.isCharge ? 'Pressure Notes' : 'Notes',
              hintText: widget.isCharge
                  ? 'Sticky bolt, ejector marks, primer flatness...'
                  : 'Wind, position, anything that affected the group',
            ),
            onChanged: (_) => _commit(),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: TextButton.icon(
                  onPressed: _toggleFired,
                  icon: Icon(widget.rung.fired
                      ? Icons.local_fire_department
                      : Icons.local_fire_department_outlined),
                  label: Text(
                      widget.rung.fired ? 'Fired' : 'Mark Fired'),
                ),
              ),
              Expanded(
                child: FilledButton.icon(
                  onPressed: _commit,
                  icon: const Icon(Icons.save_outlined),
                  label: const Text('Save Rung'),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _chargeFields(ThemeData theme) {
    return Column(
      children: [
        Row(
          children: [
            Expanded(
              child: TextField(
                controller: _v1,
                keyboardType: const TextInputType.numberWithOptions(
                    decimal: true),
                inputFormatters: [
                  FilteringTextInputFormatter.allow(RegExp(r'[0-9.]')),
                ],
                decoration: const InputDecoration(
                  labelText: 'Velocity Avg (fps)',
                ),
                onChanged: (_) => _commit(),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: TextField(
                controller: _v2,
                keyboardType: const TextInputType.numberWithOptions(
                    decimal: true),
                inputFormatters: [
                  FilteringTextInputFormatter.allow(RegExp(r'[0-9.]')),
                ],
                decoration: const InputDecoration(
                  labelText: 'SD (fps)',
                ),
                onChanged: (_) => _commit(),
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(
              child: TextField(
                controller: _v3,
                keyboardType: const TextInputType.numberWithOptions(
                    decimal: true),
                inputFormatters: [
                  FilteringTextInputFormatter.allow(RegExp(r'[0-9.]')),
                ],
                decoration: const InputDecoration(
                  labelText: 'ES (fps)',
                ),
                onChanged: (_) => _commit(),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: TextField(
                controller: _v4,
                keyboardType: TextInputType.number,
                inputFormatters: [
                  FilteringTextInputFormatter.digitsOnly,
                ],
                decoration: const InputDecoration(
                  labelText: 'Sample Count',
                ),
                onChanged: (_) => _commit(),
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _seatingFields(ThemeData theme) {
    return Column(
      children: [
        Row(
          children: [
            Expanded(
              child: TextField(
                controller: _v1,
                keyboardType: const TextInputType.numberWithOptions(
                    decimal: true),
                inputFormatters: [
                  FilteringTextInputFormatter.allow(RegExp(r'[0-9.]')),
                ],
                decoration: const InputDecoration(
                  labelText: 'Group (MOA)',
                ),
                onChanged: (_) => _commit(),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: TextField(
                controller: _v2,
                keyboardType: const TextInputType.numberWithOptions(
                    decimal: true),
                inputFormatters: [
                  FilteringTextInputFormatter.allow(RegExp(r'[0-9.]')),
                ],
                decoration: const InputDecoration(
                  labelText: 'Vertical (MOA)',
                ),
                onChanged: (_) => _commit(),
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(
              child: TextField(
                controller: _v3,
                keyboardType: const TextInputType.numberWithOptions(
                    decimal: true),
                inputFormatters: [
                  FilteringTextInputFormatter.allow(RegExp(r'[0-9.]')),
                ],
                decoration: const InputDecoration(
                  labelText: 'Horizontal (MOA)',
                ),
                onChanged: (_) => _commit(),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: TextField(
                controller: _v4,
                keyboardType: TextInputType.number,
                inputFormatters: [
                  FilteringTextInputFormatter.digitsOnly,
                ],
                decoration: const InputDecoration(
                  labelText: 'Distance (yd)',
                ),
                onChanged: (_) => _commit(),
              ),
            ),
          ],
        ),
      ],
    );
  }
}

// ─────────────────────── Charts ───────────────────────

class _ChargeBarChart extends StatelessWidget {
  const _ChargeBarChart({required this.rungs, required this.places});
  final List<LadderRung> rungs;
  final int places;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scored = rungs
        .where((r) => r.velocitySdFps != null && r.velocitySdFps! > 0)
        .toList()
      ..sort((a, b) => a.value.compareTo(b.value));
    if (scored.isEmpty) {
      return Center(
        child: Text(
          'Enter velocity SD on at least one rung to see the chart.',
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
            fontStyle: FontStyle.italic,
          ),
          textAlign: TextAlign.center,
        ),
      );
    }
    final analysis = LoadDevelopmentRepository.analyzeChargeNode(rungs);
    final highlight = analysis.clusterIndices.toSet();

    return CustomPaint(
      painter: _BarChartPainter(
        labels: [for (final r in scored) r.value.toStringAsFixed(places)],
        values: [for (final r in scored) r.velocitySdFps!],
        highlightFlags: [
          for (final r in scored) highlight.contains(r.index),
        ],
        color: theme.colorScheme.primary,
        secondary:
            theme.colorScheme.onSurface.withValues(alpha: 0.55),
        backgroundLine:
            theme.colorScheme.outline.withValues(alpha: 0.45),
        textColor: theme.colorScheme.onSurface,
      ),
    );
  }
}

class _SeatingLineChart extends StatelessWidget {
  const _SeatingLineChart({required this.rungs, required this.places});
  final List<LadderRung> rungs;
  final int places;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // For each rung compute the mean of (groupMoa, verticalMoa) when at
    // least one is present.
    final scored = <({LadderRung rung, double score})>[];
    for (final r in rungs) {
      final samples = <double>[
        if (r.groupMoa != null && r.groupMoa! > 0) r.groupMoa!,
        if (r.verticalMoa != null && r.verticalMoa! > 0) r.verticalMoa!,
      ];
      if (samples.isEmpty) continue;
      final score = samples.reduce((a, b) => a + b) / samples.length;
      scored.add((rung: r, score: score));
    }
    scored.sort((a, b) => a.rung.value.compareTo(b.rung.value));
    if (scored.isEmpty) {
      return Center(
        child: Text(
          'Enter group or vertical on at least one rung to see the chart.',
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
            fontStyle: FontStyle.italic,
          ),
          textAlign: TextAlign.center,
        ),
      );
    }
    final analysis = LoadDevelopmentRepository.analyzeSeatingNode(rungs);
    final highlightIdx = analysis.bestIndex;

    return CustomPaint(
      painter: _LineChartPainter(
        labels: [for (final s in scored) s.rung.value.toStringAsFixed(places)],
        values: [for (final s in scored) s.score],
        highlightFlags: [
          for (final s in scored) s.rung.index == highlightIdx,
        ],
        color: theme.colorScheme.primary,
        secondary:
            theme.colorScheme.onSurface.withValues(alpha: 0.55),
        backgroundLine:
            theme.colorScheme.outline.withValues(alpha: 0.45),
        textColor: theme.colorScheme.onSurface,
      ),
    );
  }
}

/// Hand-rolled bar chart. We avoid `fl_chart` to keep the dependency
/// surface small. This painter shows each rung as a vertical bar, with
/// highlighted bars filled in the brass primary color and others drawn
/// in a muted on-surface tone. Y-axis is auto-scaled to the data range.
class _BarChartPainter extends CustomPainter {
  _BarChartPainter({
    required this.labels,
    required this.values,
    required this.highlightFlags,
    required this.color,
    required this.secondary,
    required this.backgroundLine,
    required this.textColor,
  });

  final List<String> labels;
  final List<double> values;
  final List<bool> highlightFlags;
  final Color color;
  final Color secondary;
  final Color backgroundLine;
  final Color textColor;

  @override
  void paint(Canvas canvas, Size size) {
    if (values.isEmpty) return;
    const padLeft = 32.0;
    const padRight = 8.0;
    const padTop = 8.0;
    const padBottom = 24.0;
    final chartW = size.width - padLeft - padRight;
    final chartH = size.height - padTop - padBottom;

    final maxV = values.reduce((a, b) => a > b ? a : b);
    final minV = 0.0;
    final span = (maxV - minV) <= 0 ? 1.0 : maxV - minV;

    // Background grid.
    final gridPaint = Paint()
      ..color = backgroundLine
      ..strokeWidth = 0.6;
    for (var i = 0; i <= 4; i++) {
      final y = padTop + chartH - (chartH * i / 4);
      canvas.drawLine(
          Offset(padLeft, y), Offset(padLeft + chartW, y), gridPaint);
      final v = minV + (span * i / 4);
      _drawText(
        canvas,
        v.toStringAsFixed(0),
        Offset(0, y - 6),
        textColor.withValues(alpha: 0.7),
        9,
      );
    }

    // Bars.
    final barW = chartW / values.length * 0.7;
    final gap = chartW / values.length * 0.3;
    for (var i = 0; i < values.length; i++) {
      final left = padLeft + (chartW * i / values.length) + (gap / 2);
      final h = chartH * ((values[i] - minV) / span);
      final paint = Paint()
        ..color =
            highlightFlags[i] ? color : secondary.withValues(alpha: 0.45)
        ..style = PaintingStyle.fill;
      final rect = Rect.fromLTWH(
        left,
        padTop + chartH - h,
        barW,
        h,
      );
      canvas.drawRRect(
        RRect.fromRectAndRadius(rect, const Radius.circular(2)),
        paint,
      );
      // X-axis label.
      _drawText(
        canvas,
        labels[i],
        Offset(left + barW / 2 - 16, padTop + chartH + 4),
        textColor.withValues(alpha: 0.75),
        9,
      );
    }
  }

  void _drawText(
      Canvas canvas, String s, Offset offset, Color c, double size) {
    final tp = TextPainter(
      text: TextSpan(
        text: s,
        style: TextStyle(color: c, fontSize: size),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    tp.paint(canvas, offset);
  }

  @override
  bool shouldRepaint(covariant _BarChartPainter old) =>
      old.values != values ||
      old.highlightFlags != highlightFlags ||
      old.color != color;
}

/// Hand-rolled line chart for seating analysis. Plots score (mean of
/// group/vertical MOA) along the rung CBTO axis, with the winning rung
/// highlighted as a larger filled circle.
class _LineChartPainter extends CustomPainter {
  _LineChartPainter({
    required this.labels,
    required this.values,
    required this.highlightFlags,
    required this.color,
    required this.secondary,
    required this.backgroundLine,
    required this.textColor,
  });

  final List<String> labels;
  final List<double> values;
  final List<bool> highlightFlags;
  final Color color;
  final Color secondary;
  final Color backgroundLine;
  final Color textColor;

  @override
  void paint(Canvas canvas, Size size) {
    if (values.isEmpty) return;
    const padLeft = 32.0;
    const padRight = 8.0;
    const padTop = 8.0;
    const padBottom = 24.0;
    final chartW = size.width - padLeft - padRight;
    final chartH = size.height - padTop - padBottom;

    final maxV = values.reduce((a, b) => a > b ? a : b);
    final minV = values.reduce((a, b) => a < b ? a : b);
    final span = (maxV - minV).abs() < 1e-9 ? 1.0 : (maxV - minV);
    final low = (minV - span * 0.1).clamp(0, double.infinity).toDouble();
    final high = maxV + span * 0.1;
    final range = high - low <= 0 ? 1.0 : high - low;

    // Background grid.
    final gridPaint = Paint()
      ..color = backgroundLine
      ..strokeWidth = 0.6;
    for (var i = 0; i <= 4; i++) {
      final y = padTop + chartH - (chartH * i / 4);
      canvas.drawLine(
          Offset(padLeft, y), Offset(padLeft + chartW, y), gridPaint);
      final v = low + (range * i / 4);
      _drawText(
        canvas,
        v.toStringAsFixed(2),
        Offset(0, y - 6),
        textColor.withValues(alpha: 0.7),
        9,
      );
    }

    // Line + points.
    final linePaint = Paint()
      ..color = secondary.withValues(alpha: 0.7)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2;
    final path = Path();
    final points = <Offset>[];
    for (var i = 0; i < values.length; i++) {
      final x = padLeft + (chartW * i / (values.length - 1).clamp(1, 100));
      final y = padTop + chartH - (chartH * (values[i] - low) / range);
      points.add(Offset(x, y));
      if (i == 0) {
        path.moveTo(x, y);
      } else {
        path.lineTo(x, y);
      }
    }
    canvas.drawPath(path, linePaint);

    for (var i = 0; i < points.length; i++) {
      final paint = Paint()
        ..color =
            highlightFlags[i] ? color : secondary.withValues(alpha: 0.85)
        ..style = PaintingStyle.fill;
      canvas.drawCircle(
        points[i],
        highlightFlags[i] ? 6 : 3.5,
        paint,
      );
      _drawText(
        canvas,
        labels[i],
        Offset(points[i].dx - 18, padTop + chartH + 4),
        textColor.withValues(alpha: 0.75),
        9,
      );
    }
  }

  void _drawText(
      Canvas canvas, String s, Offset offset, Color c, double size) {
    final tp = TextPainter(
      text: TextSpan(
        text: s,
        style: TextStyle(color: c, fontSize: size),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    tp.paint(canvas, offset);
  }

  @override
  bool shouldRepaint(covariant _LineChartPainter old) =>
      old.values != values ||
      old.highlightFlags != highlightFlags ||
      old.color != color;
}

// ─────────────────────── Small chips ───────────────────────

/// Brass-tinted chip used as a section header inside cards. Mirrors the
/// `_SectionChip` in `batch_detail_screen.dart`.
class _SectionChip extends StatelessWidget {
  const _SectionChip({required this.title});

  final String title;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Align(
      alignment: Alignment.centerLeft,
      child: Container(
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
    );
  }
}

class _ChipText extends StatelessWidget {
  const _ChipText({required this.text, this.primary = false});
  final String text;
  final bool primary;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color =
        primary ? theme.colorScheme.primary : theme.colorScheme.secondary;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: color.withValues(alpha: 0.35)),
      ),
      child: Text(
        text,
        style: theme.textTheme.labelSmall?.copyWith(
          color: color,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}
