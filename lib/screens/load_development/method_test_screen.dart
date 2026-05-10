// FILE: lib/screens/load_development/method_test_screen.dart
//
// ============================================================================
// WHAT THIS FILE DOES
// ============================================================================
// Single, configurable detail screen for the four method-specific
// load-development workflows: OCW, Audette Ladder, Satterlee 10-shot,
// and Generic charge ladder. Driven by a `MethodKind` enum and the
// row id of the `LoadDevelopmentSessions` row created by the new
// test wizard.
//
// Each method renders the same vertical layout:
//   1. Header card (name, method badge, source recipe / firearm chips,
//      distance, charge range / step / shots-per-charge).
//   2. Method explainer (expandable; see `widgets/method_explainer.dart`).
//   3. Per-charge "shot grid" — one expandable card per planned charge
//      from the wizard, each with rows for the per-shot inputs (shared
//      `ShotEntryCard` widget). User can override the planned shots
//      per charge by tapping "Add shot."
//   4. Per-charge stats table — SD / ES / mean MV, mean impact, and
//      group size at each charge. Rendered as a Material `DataTable`.
//   5. Method-specific chart — for OCW, vertical impact vs charge;
//      for Satterlee, mean MV vs charge; for Ladder, vertical impact
//      vs charge with stacking-spread annotation; for Generic, a
//      cycler that flips between SD vs charge, vertical vs charge,
//      and group ES vs charge.
//   6. Analysis card — the recommended node + a "Pick This Node"
//      button that writes back to the source recipe (when one is
//      linked) and persists the picked node on the session.
//
// Pro-gated by routing — the list screen wraps a `ProGate`. This
// detail screen is reached only after the `ensurePro` check, so it
// doesn't re-gate.
//
// ============================================================================
// WHY IT EXISTS IN THE ARCHITECTURE
// ============================================================================
// One file per method would duplicate the header, the shot grid, and
// the stats table four times for code that only differs in the chart
// renderer and the analysis call. Routing the four methods through
// one screen keyed on `MethodKind` keeps the surface narrow and
// localizes each method's bespoke pieces (chart + analysis label) to
// a small switch on the enum.
//
// ============================================================================
// WHY THIS IS HARDER THAN IT LOOKS
// ============================================================================
// 1. The "planned charge weights" come from the session's
//    `(startValue, endValue, stepValue)` triple, but the actual
//    shots can land at any chargeGr the user types into a per-shot
//    row — including off-grid charges. We render one card per
//    PLANNED charge plus extra cards for any extra charges that
//    showed up in the per-shot data.
// 2. Watching `LoadDevelopmentShots` and the session row at the same
//    time produces a `(session, shots)` tuple that drives every
//    subordinate widget; using two separate `StreamBuilder`s would
//    cause the lower stream to flash empty whenever the upper rebuilds.
//    We merge them with `StreamBuilder` over `Stream.combineLatest`
//    via `rxdart` if available; for now we use a `FutureBuilder`-
//    friendly compose pattern.
// 3. The "Pick This Node" cascade for charge methods has to update
//    BOTH the session's `nodeValue` column AND optionally the source
//    recipe's `powderChargeGr` — the user gets a dialog asking which
//    one before any write happens.
//
// ============================================================================
// WHO CONSUMES THIS FILE
// ============================================================================
// - lib/screens/load_development/load_development_list_screen.dart
//   (tile tap on a v31+ method-keyed session)
// - lib/screens/load_development/new_method_test_screen.dart
//   (pushReplacement after wizard save)
//
// ============================================================================
// SIDE EFFECTS
// ============================================================================
// Streams `LoadDevelopmentSessionRow` and `LoadDevelopmentShotRow` from
// the repository. Inserts / updates / deletes shot rows. Writes back
// node value to `LoadDevelopmentSessions.nodeValue` and (optionally)
// `UserLoads.powderChargeGr` when the user accepts the recommendation.

import 'dart:async';

import 'package:drift/drift.dart' show Value;
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../database/database.dart';
import '../../repositories/firearm_repository.dart';
import '../../repositories/load_development_repository.dart';
import '../../repositories/recipe_repository.dart';
import 'widgets/load_development_charts.dart';
import 'widgets/method_explainer.dart';
import 'widgets/shot_entry_card.dart';

/// Detail screen for one v31+ method-specific load-development test.
class MethodTestScreen extends StatefulWidget {
  const MethodTestScreen({
    super.key,
    required this.sessionId,
    required this.method,
  });

  final int sessionId;
  final MethodKind method;

  @override
  State<MethodTestScreen> createState() => _MethodTestScreenState();
}

class _MethodTestScreenState extends State<MethodTestScreen> {
  /// View-toggle state for the Generic method's chart cycler. One of
  /// `'sd' | 'verticalY' | 'groupEs'`.
  String _genericChartMode = 'sd';

  @override
  Widget build(BuildContext context) {
    final repo = context.read<LoadDevelopmentRepository>();
    return Scaffold(
      appBar: AppBar(title: Text(_titleFor(widget.method))),
      body: StreamBuilder<LoadDevelopmentSessionRow?>(
        stream: repo.watchById(widget.sessionId),
        builder: (context, sessionSnap) {
          if (sessionSnap.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          }
          final session = sessionSnap.data;
          if (session == null) {
            return const Center(child: Text('Test not found.'));
          }
          return StreamBuilder<List<LoadDevelopmentShotRow>>(
            stream: repo.watchShots(widget.sessionId),
            builder: (context, shotsSnap) {
              final shots =
                  shotsSnap.data ?? const <LoadDevelopmentShotRow>[];
              return _Body(
                session: session,
                shots: shots,
                method: widget.method,
                genericChartMode: _genericChartMode,
                onGenericChartModeChanged: (m) =>
                    setState(() => _genericChartMode = m),
              );
            },
          );
        },
      ),
    );
  }

  String _titleFor(MethodKind k) {
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
        return 'Seating Depth Ladder';
    }
  }
}

class _Body extends StatelessWidget {
  const _Body({
    required this.session,
    required this.shots,
    required this.method,
    required this.genericChartMode,
    required this.onGenericChartModeChanged,
  });

  final LoadDevelopmentSessionRow session;
  final List<LoadDevelopmentShotRow> shots;
  final MethodKind method;
  final String genericChartMode;
  final ValueChanged<String> onGenericChartModeChanged;

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
            MethodExplainerCard(method: method),
            const SizedBox(height: 16),
            _shotGridCard(context),
            const SizedBox(height: 16),
            _statsCard(context),
            const SizedBox(height: 16),
            _chartCard(context),
            const SizedBox(height: 16),
            _analysisCard(context, refs),
          ],
        );
      },
    );
  }

  Future<_DetailRefs> _loadRefs(BuildContext context) async {
    final firearms = context.read<FirearmRepository>();
    final recipes = context.read<RecipeRepository>();
    final firearm = session.firearmId == null
        ? null
        : await firearms.getById(session.firearmId!);
    final recipe = session.sourceRecipeId == null
        ? null
        : await recipes.getById(session.sourceRecipeId!);
    return (firearm: firearm, sourceRecipe: recipe);
  }

  // ─────────────────────── Header ───────────────────────

  Widget _headerCard(BuildContext context, _DetailRefs refs) {
    final theme = Theme.of(context);
    final method = this.method;
    final isComplete = session.nodeValue != null;
    final pillColor = isComplete
        ? theme.colorScheme.primary
        : theme.colorScheme.secondary;
    final pillLabel = isComplete ? 'Complete' : 'In Progress';
    final methodBadge = _badgeForMethod(method);
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
                _pill(theme, pillLabel, pillColor),
              ],
            ),
            const SizedBox(height: 6),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                _pill(theme, methodBadge, theme.colorScheme.primary,
                    filled: true),
                if ((session.cartridge ?? '').isNotEmpty)
                  _pill(theme, session.cartridge!, theme.colorScheme.secondary),
                if (refs.firearm != null)
                  _pill(theme, refs.firearm!.name,
                      theme.colorScheme.secondary),
                if (refs.sourceRecipe != null)
                  _pill(theme, refs.sourceRecipe!.name,
                      theme.colorScheme.tertiary),
              ],
            ),
            const SizedBox(height: 12),
            _detail(theme, 'Powder', session.powder ?? '—'),
            _detail(theme, 'Bullet', session.bullet ?? '—'),
            _detail(theme, 'Primer', session.primer ?? '—'),
            _detail(
              theme,
              'Charge Range',
              '${session.startValue.toStringAsFixed(2)}–'
                  '${session.endValue.toStringAsFixed(2)} gr '
                  '(step ${session.stepValue.toStringAsFixed(2)})',
            ),
            if (session.distanceYd != null)
              _detail(theme, 'Distance', '${session.distanceYd} yd'),
            if (session.shotsPerCharge != null)
              _detail(
                theme,
                'Shots Per Charge',
                '${session.shotsPerCharge}',
              ),
            if (session.nodeValue != null)
              _detail(
                theme,
                'Picked Node',
                '${session.nodeValue!.toStringAsFixed(2)} gr',
              ),
          ],
        ),
      ),
    );
  }

  Widget _pill(ThemeData theme, String label, Color color,
      {bool filled = false}) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: filled ? 0.18 : 0.10),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: color.withValues(alpha: 0.35)),
      ),
      child: Text(
        label,
        style: theme.textTheme.labelSmall?.copyWith(
          color: color,
          fontWeight: FontWeight.w600,
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
            width: 130,
            child: Text(label, style: theme.textTheme.bodySmall),
          ),
          Expanded(child: Text(value)),
        ],
      ),
    );
  }

  String _badgeForMethod(MethodKind k) {
    switch (k) {
      case MethodKind.ocw:
        return 'OCW';
      case MethodKind.ladder:
        return 'Audette Ladder';
      case MethodKind.satterlee:
        return 'Satterlee';
      case MethodKind.generic:
        return 'Generic';
      case MethodKind.seating:
        return 'Seating';
    }
  }

  // ─────────────────────── Shot grid ───────────────────────

  Widget _shotGridCard(BuildContext context) {
    final theme = Theme.of(context);
    // Planned charges from the session range.
    final plannedCharges = LoadDevelopmentRepository.generateRungs(
      start: session.startValue,
      end: session.endValue,
      step: session.stepValue,
    );
    // Off-grid charges that landed in the shot data.
    final offGrid = <double>{};
    final byCharge = <double, List<LoadDevelopmentShotRow>>{};
    for (final s in shots) {
      final key = LoadDevelopmentRepository.round(s.chargeGr, places: 2);
      byCharge.putIfAbsent(key, () => []).add(s);
      if (!plannedCharges
          .map((c) => LoadDevelopmentRepository.round(c, places: 2))
          .contains(key)) {
        offGrid.add(key);
      }
    }
    final allCharges = <double>[
      ...plannedCharges
          .map((c) => LoadDevelopmentRepository.round(c, places: 2)),
      ...offGrid,
    ];
    allCharges.sort();

    final shotKind = _shotKindFor(method);
    final plannedShots = session.shotsPerCharge ?? _defaultShotsForMethod(method);

    return Card(
      clipBehavior: Clip.antiAlias,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 12, 12, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.only(left: 4, bottom: 4),
              child: _SectionHeader(
                title: 'Shot Grid',
                trailing: Text(
                  '${shots.length} of ~${plannedCharges.length * plannedShots} shots logged',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
            ),
            // Capture the repo once outside the per-card builder so
            // the per-card callbacks don't reach into `context.read`
            // across async gaps. Each callback closes over `repo` only.
            for (final c in allCharges)
              Builder(
                builder: (rowCtx) {
                  final repo = rowCtx.read<LoadDevelopmentRepository>();
                  return ShotEntryCard(
                    key: ValueKey('charge_card_${session.id}_$c'),
                    chargeGr: c,
                    shots: byCharge[c] ?? const <LoadDevelopmentShotRow>[],
                    plannedShotsPerCharge: plannedShots,
                    shotKind: shotKind,
                    onAddShot: (entry) async {
                      await repo.insertShot(entry.copyWith(
                        sessionId: Value(session.id),
                      ));
                      await _bumpSessionTimestamp(repo);
                    },
                    onUpdateShot: (id, patch) async {
                      await repo.updateShot(id, patch);
                      await _bumpSessionTimestamp(repo);
                    },
                    onDeleteShot: (id) async {
                      await repo.deleteShot(id);
                      await _bumpSessionTimestamp(repo);
                    },
                  );
                },
              ),
          ],
        ),
      ),
    );
  }

  /// Bump the session's `updatedAt` so the list-screen tile sort moves
  /// the session to the top after the latest shot edit. Takes a repo
  /// reference rather than a `BuildContext` so callbacks can call this
  /// safely after an async gap.
  Future<void> _bumpSessionTimestamp(LoadDevelopmentRepository repo) async {
    await repo.update(
      session.id,
      LoadDevelopmentSessionsCompanion(
        updatedAt: Value(DateTime.now()),
      ),
    );
  }

  ShotEntryKind _shotKindFor(MethodKind k) {
    switch (k) {
      case MethodKind.ocw:
      case MethodKind.ladder:
        return ShotEntryKind.both;
      case MethodKind.satterlee:
        return ShotEntryKind.velocityOnly;
      case MethodKind.generic:
        return ShotEntryKind.both;
      case MethodKind.seating:
        return ShotEntryKind.both;
    }
  }

  int _defaultShotsForMethod(MethodKind k) {
    switch (k) {
      case MethodKind.ocw:
        return 3;
      case MethodKind.ladder:
        return 1;
      case MethodKind.satterlee:
        return 1;
      case MethodKind.generic:
        return 3;
      case MethodKind.seating:
        return 5;
    }
  }

  // ─────────────────────── Stats ───────────────────────

  Widget _statsCard(BuildContext context) {
    final theme = Theme.of(context);
    final stats = LoadDevelopmentRepository.computePerChargeStats(shots);
    return Card(
      clipBehavior: Clip.antiAlias,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 12, 12, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Padding(
              padding: EdgeInsets.only(left: 4, bottom: 4),
              child: _SectionHeader(title: 'Per-Charge Stats'),
            ),
            const SizedBox(height: 4),
            if (stats.isEmpty)
              Padding(
                padding: const EdgeInsets.all(12),
                child: Text(
                  'Log at least one shot to see per-charge statistics.',
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              )
            else
              SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: DataTable(
                  columnSpacing: 18,
                  columns: const [
                    DataColumn(label: Text('Charge (gr)')),
                    DataColumn(label: Text('Shots'), numeric: true),
                    DataColumn(label: Text('Mean MV (fps)'), numeric: true),
                    DataColumn(label: Text('SD (fps)'), numeric: true),
                    DataColumn(label: Text('ES (fps)'), numeric: true),
                    DataColumn(label: Text('Mean X (in)'), numeric: true),
                    DataColumn(label: Text('Mean Y (in)'), numeric: true),
                    DataColumn(label: Text('Group ES (in)'), numeric: true),
                    DataColumn(label: Text('Mean R (in)'), numeric: true),
                  ],
                  rows: [
                    for (final r in stats)
                      DataRow(cells: [
                        DataCell(Text(r.chargeGr.toStringAsFixed(2))),
                        DataCell(Text('${r.shotCount}')),
                        DataCell(Text(_n(r.meanVelocityFps, 0))),
                        DataCell(Text(_n(r.sdVelocityFps, 1))),
                        DataCell(Text(_n(r.esVelocityFps, 0))),
                        DataCell(Text(_n(r.meanXIn, 2))),
                        DataCell(Text(_n(r.meanYIn, 2))),
                        DataCell(Text(_n(r.extremeSpreadIn, 2))),
                        DataCell(Text(_n(r.meanRadiusIn, 2))),
                      ]),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }

  String _n(double? v, int places) =>
      v == null ? '—' : v.toStringAsFixed(places);

  // ─────────────────────── Chart ───────────────────────

  Widget _chartCard(BuildContext context) {
    final theme = Theme.of(context);
    final stats = LoadDevelopmentRepository.computePerChargeStats(shots);

    Widget chart;
    String caption;
    Set<double> highlight = const {};

    switch (method) {
      case MethodKind.ocw:
      case MethodKind.ladder:
        final ocw = LoadDevelopmentRepository.analyzeOcwNode(shots);
        highlight = ocw.flatChargeIndices.toSet();
        final pts = <({double chargeGr, double value})>[
          for (final s in stats.where((s) => s.meanYIn != null))
            (chargeGr: s.chargeGr, value: s.meanYIn!),
        ];
        chart = LoadDevelopmentXyScatter(
          points: pts,
          yAxisLabel: 'Mean Y impact (in)',
          highlightCharges: highlight,
          emptyMessage:
              'Log impact Y values to see vertical-vs-charge plot.',
        );
        caption = method == MethodKind.ocw
            ? 'Vertical impact by charge weight. Flat spot is your OCW node.'
            : 'Vertical impact by charge weight. Stacked charges are your '
                'candidate node.';
        break;
      case MethodKind.satterlee:
        final sat = LoadDevelopmentRepository.analyzeSatterleePlateau(shots);
        highlight = sat.plateauChargeIndices.toSet();
        final pts = <({double chargeGr, double value})>[
          for (final s in stats.where((s) => s.meanVelocityFps != null))
            (chargeGr: s.chargeGr, value: s.meanVelocityFps!),
        ];
        chart = LoadDevelopmentXyScatter(
          points: pts,
          yAxisLabel: 'Mean MV (fps)',
          highlightCharges: highlight,
          emptyMessage:
              'Log chronograph readings to see MV-vs-charge plot.',
        );
        caption =
            'Mean MV by charge weight. Plateau (highlighted) is your node.';
        break;
      case MethodKind.generic:
        return _genericChartCard(context, stats);
      case MethodKind.seating:
        final pts = <({double chargeGr, double value})>[
          for (final s in stats.where((s) => s.extremeSpreadIn != null))
            (chargeGr: s.chargeGr, value: s.extremeSpreadIn!),
        ];
        chart = LoadDevelopmentXyScatter(
          points: pts,
          yAxisLabel: 'Group ES (in)',
          emptyMessage:
              'Log impact X / Y for at least 2 shots per CBTO to see groups.',
        );
        caption = 'Group extreme spread by CBTO. Smaller is better.';
        break;
    }
    return Card(
      clipBehavior: Clip.antiAlias,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 12, 12, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Padding(
              padding: EdgeInsets.only(left: 4, bottom: 4),
              child: _SectionHeader(title: 'Chart'),
            ),
            const SizedBox(height: 4),
            chart,
            const SizedBox(height: 8),
            Text(
              caption,
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

  Widget _genericChartCard(
    BuildContext context,
    List<PerChargeStats> stats,
  ) {
    final theme = Theme.of(context);
    final mode = genericChartMode;
    Widget chart;
    String caption;
    if (mode == 'sd') {
      final pts = <({double chargeGr, double value})>[
        for (final s in stats.where((s) => s.sdVelocityFps != null))
          (chargeGr: s.chargeGr, value: s.sdVelocityFps!),
      ];
      chart = LoadDevelopmentBarChart(
        bars: pts,
        yAxisLabel: 'SD (fps)',
        emptyMessage:
            'Log at least 2 chrono readings per charge to see SD bars.',
      );
      caption = 'Velocity SD by charge weight. Lower is more consistent.';
    } else if (mode == 'verticalY') {
      final pts = <({double chargeGr, double value})>[
        for (final s in stats.where((s) => s.meanYIn != null))
          (chargeGr: s.chargeGr, value: s.meanYIn!),
      ];
      chart = LoadDevelopmentXyScatter(
        points: pts,
        yAxisLabel: 'Mean Y (in)',
        emptyMessage:
            'Log impact Y values to see vertical-vs-charge plot.',
      );
      caption =
          'Vertical impact by charge weight. Look for a flat spot.';
    } else {
      final pts = <({double chargeGr, double value})>[
        for (final s in stats.where((s) => s.extremeSpreadIn != null))
          (chargeGr: s.chargeGr, value: s.extremeSpreadIn!),
      ];
      chart = LoadDevelopmentBarChart(
        bars: pts,
        yAxisLabel: 'Group ES (in)',
        emptyMessage:
            'Log impact X / Y for at least 2 shots per charge to see groups.',
      );
      caption =
          'Group extreme spread by charge weight. Smaller is better.';
    }
    return Card(
      clipBehavior: Clip.antiAlias,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 12, 12, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Padding(
              padding: EdgeInsets.only(left: 4, bottom: 4),
              child: _SectionHeader(title: 'Chart'),
            ),
            SegmentedButton<String>(
              segments: const [
                ButtonSegment(value: 'sd', label: Text('SD')),
                ButtonSegment(value: 'verticalY', label: Text('Vertical Y')),
                ButtonSegment(value: 'groupEs', label: Text('Group ES')),
              ],
              selected: {mode},
              onSelectionChanged: (s) => onGenericChartModeChanged(s.first),
            ),
            const SizedBox(height: 12),
            chart,
            const SizedBox(height: 8),
            Text(
              caption,
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

  // ─────────────────────── Analysis ───────────────────────

  Widget _analysisCard(BuildContext context, _DetailRefs refs) {
    final theme = Theme.of(context);
    String headline;
    String detail;
    double? recommendation;
    final hasMeaningfulData = shots.any(
      (s) => s.velocityFps != null || s.impactYIn != null,
    );

    switch (method) {
      case MethodKind.ocw:
      case MethodKind.ladder:
        final ocw = LoadDevelopmentRepository.analyzeOcwNode(shots);
        recommendation = ocw.recommendedChargeGr;
        if (recommendation == null) {
          headline = 'No OCW node detected yet';
          detail = ocw.chargesAnalyzed < 3
              ? 'Need impact-Y data on at least 3 charges. Currently '
                  '${ocw.chargesAnalyzed} analyzed.'
              : 'No flat spot under '
                  '${ocw.maxVerticalSpreadIn.toStringAsFixed(2)} inch '
                  'between adjacent charges. Add more data or widen the '
                  'flat-spot threshold by re-running with finer charge steps.';
        } else {
          headline = method == MethodKind.ocw
              ? 'Recommended OCW Node'
              : 'Audette Stacking Charge';
          detail = 'Centre of a ${ocw.flatChargeIndices.length}-charge flat '
              'spot in vertical impact (within '
              '${ocw.maxVerticalSpreadIn.toStringAsFixed(2)} inch step).';
        }
        break;
      case MethodKind.satterlee:
        final sat = LoadDevelopmentRepository.analyzeSatterleePlateau(shots);
        recommendation = sat.recommendedChargeGr;
        if (recommendation == null) {
          headline = 'No plateau detected yet';
          detail = sat.chargesAnalyzed < 3
              ? 'Need chronograph data on at least 3 charges. Currently '
                  '${sat.chargesAnalyzed} analyzed.'
              : 'Velocity rose more than '
                  '${sat.maxVelocityRiseFps.toStringAsFixed(0)} fps at every '
                  'step. Re-run with finer charge increments or two shots per '
                  'charge.';
        } else {
          headline = 'Recommended Satterlee Node';
          detail =
              'Centre of a ${sat.plateauChargeIndices.length}-charge MV plateau '
              '(rise per step under '
              '${sat.maxVelocityRiseFps.toStringAsFixed(0)} fps).';
        }
        break;
      case MethodKind.generic:
        // Generic: surface OCW node first, fall back to Satterlee node, fall
        // back to "lowest SD charge."
        final ocw = LoadDevelopmentRepository.analyzeOcwNode(shots);
        final sat = LoadDevelopmentRepository.analyzeSatterleePlateau(shots);
        if (ocw.recommendedChargeGr != null) {
          recommendation = ocw.recommendedChargeGr;
          headline = 'Suggested Node (OCW Flat Spot)';
          detail = 'Centre of a ${ocw.flatChargeIndices.length}-charge flat '
              'spot in vertical impact.';
        } else if (sat.recommendedChargeGr != null) {
          recommendation = sat.recommendedChargeGr;
          headline = 'Suggested Node (MV Plateau)';
          detail =
              'Centre of a ${sat.plateauChargeIndices.length}-charge MV plateau.';
        } else {
          // Pick the charge with the lowest SD if any have SD computed.
          final stats = LoadDevelopmentRepository.computePerChargeStats(shots);
          final scored = stats.where((s) => s.sdVelocityFps != null).toList()
            ..sort((a, b) =>
                a.sdVelocityFps!.compareTo(b.sdVelocityFps!));
          if (scored.isNotEmpty) {
            recommendation = scored.first.chargeGr;
            headline = 'Lowest-SD Charge';
            detail = 'No node detected. The charge with the lowest velocity SD '
                'so far is '
                '${recommendation.toStringAsFixed(2)} gr at '
                '${scored.first.sdVelocityFps!.toStringAsFixed(1)} fps.';
          } else {
            recommendation = null;
            headline = 'Not Enough Data Yet';
            detail = hasMeaningfulData
                ? 'Need either chrono SD, impact-Y, or MV plateau data to '
                    'recommend a node.'
                : 'Log shots with chronograph or impact data to enable '
                    'analysis.';
          }
        }
        break;
      case MethodKind.seating:
        // Seating analysis runs against the legacy LadderRung path; this
        // method screen is Charge-focused. Keep a simple stat surface.
        headline = 'Seating ladders use the legacy detail screen.';
        detail =
            'Open the older ladder workflow from the list to analyze seating.';
        recommendation = null;
        break;
    }

    return Card(
      clipBehavior: Clip.antiAlias,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const _SectionHeader(title: 'Analysis'),
            const SizedBox(height: 12),
            Text(
              headline,
              style: theme.textTheme.titleMedium?.copyWith(
                color: theme.colorScheme.primary,
                fontWeight: FontWeight.w700,
              ),
            ),
            if (recommendation != null) ...[
              const SizedBox(height: 4),
              Text(
                '${recommendation.toStringAsFixed(2)} gr',
                style: theme.textTheme.headlineMedium?.copyWith(
                  color: theme.colorScheme.primary,
                ),
              ),
            ],
            const SizedBox(height: 8),
            Text(detail, style: theme.textTheme.bodyMedium),
            if (recommendation != null) ...[
              const SizedBox(height: 16),
              FilledButton.icon(
                onPressed: () => _pickNode(context, refs, recommendation!),
                icon: const Icon(Icons.check_circle_outline),
                label: const Text('Pick This Node'),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Future<void> _pickNode(
    BuildContext context,
    _DetailRefs refs,
    double chargeGr,
  ) async {
    final repo = context.read<LoadDevelopmentRepository>();
    final messenger = ScaffoldMessenger.of(context);
    final hasRecipe = refs.sourceRecipe != null;

    final action = await showDialog<_NodeAction>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Save Node?'),
        content: Text(
          'Save ${chargeGr.toStringAsFixed(2)} gr as the picked node for '
          'this test'
          '${hasRecipe ? ', and optionally update the source recipe.' : '.'}',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, _NodeAction.sessionOnly),
            child: const Text('Save Node Only'),
          ),
          if (hasRecipe)
            FilledButton(
              onPressed: () => Navigator.pop(ctx, _NodeAction.alsoUpdateRecipe),
              child: const Text('Save Node + Update Recipe'),
            ),
        ],
      ),
    );
    if (action == null) return;

    await repo.setNode(session.id, chargeGr);
    if (action == _NodeAction.alsoUpdateRecipe && hasRecipe) {
      await repo.applyChargeNodeToRecipe(
        recipeId: refs.sourceRecipe!.id,
        chargeGr: chargeGr,
      );
    }
    if (!context.mounted) return;
    messenger.showSnackBar(SnackBar(
      content: Text(action == _NodeAction.alsoUpdateRecipe
          ? 'Node saved. Recipe charge updated to '
              '${chargeGr.toStringAsFixed(2)} gr.'
          : 'Node ${chargeGr.toStringAsFixed(2)} gr saved on this test.'),
    ));
  }
}

enum _NodeAction { sessionOnly, alsoUpdateRecipe }

class _SectionHeader extends StatelessWidget {
  const _SectionHeader({required this.title, this.trailing});
  final String title;
  final Widget? trailing;
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      children: [
        Container(
          padding:
              const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
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
        ?trailing,
      ],
    );
  }
}

typedef _DetailRefs = ({
  UserFirearmRow? firearm,
  UserLoadRow? sourceRecipe,
});
