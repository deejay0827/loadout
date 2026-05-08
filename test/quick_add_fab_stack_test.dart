// Smoke tests for [QuickAddFabStack] — confirms the cluster renders both
// FABs, fires the right callbacks, and gives the FABs distinct hero
// tags so two stacks can coexist on a single Navigator without
// colliding.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:loadout/widgets/quick_add_fab_stack.dart';

void main() {
  testWidgets('renders both FABs with the expected labels and icons',
      (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          floatingActionButton: QuickAddFabStack(
            tagPrefix: 'recipes',
            quickIcon: Icons.bolt,
            quickLabel: 'Quick',
            onQuickPressed: _noop,
            onAddPressed: _noop,
          ),
        ),
      ),
    );

    expect(find.text('Quick'), findsOneWidget);
    expect(find.byIcon(Icons.bolt), findsOneWidget);
    expect(find.byIcon(Icons.add), findsOneWidget);
  });

  testWidgets('fires onQuickPressed and onAddPressed independently',
      (tester) async {
    var quick = 0;
    var add = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          floatingActionButton: QuickAddFabStack(
            tagPrefix: 'recipes',
            quickIcon: Icons.bolt,
            quickLabel: 'Quick',
            onQuickPressed: () => quick++,
            onAddPressed: () => add++,
          ),
        ),
      ),
    );

    await tester.tap(find.byIcon(Icons.bolt));
    await tester.pump();
    expect(quick, 1);
    expect(add, 0);

    await tester.tap(find.byIcon(Icons.add));
    await tester.pump();
    expect(quick, 1);
    expect(add, 1);
  });

  testWidgets('gives the two FABs distinct hero tags', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          floatingActionButton: QuickAddFabStack(
            tagPrefix: 'recipes',
            quickIcon: Icons.bolt,
            quickLabel: 'Quick',
            onQuickPressed: _noop,
            onAddPressed: _noop,
          ),
        ),
      ),
    );

    final fabs = tester
        .widgetList<FloatingActionButton>(find.byType(FloatingActionButton))
        .toList();
    expect(fabs.length, 2);
    final tags = fabs.map((f) => f.heroTag).toSet();
    // Distinct tags ensure two QuickAddFabStacks (one per list screen)
    // can coexist in the same Navigator without hero-animation
    // collisions.
    expect(tags.length, 2);
    expect(tags.contains('recipes_quick'), isTrue);
    expect(tags.contains('recipes_add'), isTrue);
  });
}

void _noop() {}
