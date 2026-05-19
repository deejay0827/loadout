// FILE: test/blurred_pro_teaser_test.dart
//
// ============================================================================
// WHAT THIS FILE DOES
// ============================================================================
// Exhaustive contract tests for `BlurredProTeaser`
// (lib/widgets/blurred_pro_teaser.dart) — the canonical VFP Phase 3
// Group B "teaser-blur Option 2" Pro-gating primitive that every
// gated VFP surface (reticle picker, full-screen reticle preview,
// Range Day target/scope-view renders, Scope View FOV + adjustments)
// is built on. Because all ~7 gated surfaces delegate their
// free-vs-Pro behaviour to this one widget, pinning its contract here
// is the highest-leverage behavioural coverage for the whole group:
//
//   Pro user  → returns `child` verbatim. No blur, no CTA, no scrim,
//               zero overhead, full interactivity.
//   Free user → keeps `child` LIVE in the tree (still builds /
//               responds) but rasterises it through ImageFiltered
//               (NOT BackdropFilter), paints an IgnorePointer scrim
//               so the child's gestures are never eaten, and overlays
//               a CTA. With `onCommit` the small centred CTA pill is
//               the ONLY tap-absorber; with `onCommit == null` even
//               the pill is IgnorePointer (pure label).
//   Reactive  → a purchase (notifier flips isPro false→true) rebuilds
//               every teaser to the clear child with no restart.
//
// ============================================================================
// WHY IT EXISTS IN THE ARCHITECTURE
// ============================================================================
// The operator's A2 + teaser-blur Option 2 decision is enforced
// ENTIRELY at the render layer through this widget (the per-surface
// wiring just wraps Pro content in it; there is deliberately no
// commit-action chokepoint on surfaces like Scope View / the
// tier-picker because none exists — the blur IS the gate). A
// regression in this primitive (e.g. blur not applied for free, CTA
// missing, scrim eating scroll, or the Pro path accidentally
// blurring) would silently break the gating on EVERY surface at
// once. These tests are version-agnostic (they construct their own
// minimal entitlement Provider scope) so they hold regardless of the
// Settings → Diagnostics "Simulate LoadOut Pro" rework on main.
//
// ============================================================================
// WHY THIS IS HARDER THAN IT LOOKS
// ============================================================================
//   * `EntitlementNotifier.isPro` short-circuits to `true` in debug
//     builds via `debugForceProActive`. To exercise the FREE path a
//     test MUST provide a subclass that overrides `isPro` (mirroring
//     the production `FixedEntitlementNotifier` test pattern) — a
//     plain notifier would always read Pro under `flutter test`.
//   * "child stays live" is asserted by finding the child widget in
//     BOTH states — ImageFiltered rasterises but does NOT remove the
//     child from the tree (that is the load-bearing Option-2
//     behaviour: a slider above a wrapped preview still drives it).
//   * The scrim-passthrough test deliberately places an interactive
//     child OFF-centre and taps it: proving the IgnorePointer scrim
//     lets the gesture through while only the centred pill absorbs.
//
// ============================================================================
// SIDE EFFECTS
// ============================================================================
// None. Pure widget tests. `PurchasesService()` is constructed
// unconfigured (placeholder-keys path — no plugin/stream wiring), the
// same safe pattern the Range Day harness uses.

import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:loadout/services/entitlement_notifier.dart';
import 'package:loadout/services/purchases_service.dart';
import 'package:loadout/widgets/blurred_pro_teaser.dart';

/// Deterministic, togglable [EntitlementNotifier] for tests. Mirrors
/// the production `FixedEntitlementNotifier` pattern (override `isPro`
/// to bypass the `debugForceProActive` short-circuit) but adds a
/// runtime setter so the reactive-flip contract can be exercised.
class _FixedEnt extends EntitlementNotifier {
  _FixedEnt(super.purchases, this._v);
  bool _v;
  @override
  bool get isPro => _v;
  void setPro(bool value) {
    _v = value;
    notifyListeners();
  }
}

Widget _host(_FixedEnt ent, Widget child) {
  return ChangeNotifierProvider<EntitlementNotifier>.value(
    value: ent,
    child: MaterialApp(home: Scaffold(body: Center(child: child))),
  );
}

void main() {
  _FixedEnt ent(bool isPro) => _FixedEnt(PurchasesService(), isPro);

  group('BlurredProTeaser — Pro path (verbatim child)', () {
    testWidgets('renders child unchanged; no blur, no CTA, no scrim',
        (tester) async {
      await tester.pumpWidget(_host(
        ent(true),
        const BlurredProTeaser(
          ctaText: 'UNLOCK-CTA',
          child: Text('PRO-CONTENT'),
        ),
      ));
      expect(find.text('PRO-CONTENT'), findsOneWidget);
      expect(find.text('UNLOCK-CTA'), findsNothing);
      expect(find.byType(ImageFiltered), findsNothing);
      // No lock icon when Pro.
      expect(find.byIcon(Icons.lock_outline), findsNothing);
    });

    testWidgets('Pro path adds zero wrapper widgets (child is direct)',
        (tester) async {
      await tester.pumpWidget(_host(
        ent(true),
        const BlurredProTeaser(
          ctaText: 'X',
          child: Text('C'),
        ),
      ));
      // The teaser returns `child` itself — no Stack introduced.
      expect(
        find.descendant(
          of: find.byType(BlurredProTeaser),
          matching: find.byType(Stack),
        ),
        findsNothing,
      );
    });
  });

  group('BlurredProTeaser — free path (blurred teaser)', () {
    testWidgets('child stays LIVE in the tree AND is blurred', (tester) async {
      await tester.pumpWidget(_host(
        ent(false),
        const BlurredProTeaser(
          ctaText: 'UNLOCK-CTA',
          child: Text('FREE-CONTENT'),
        ),
      ));
      // Child still mounted (live — Option-2: it keeps responding).
      expect(find.text('FREE-CONTENT'), findsOneWidget);
      // Blur applied via ImageFiltered (NOT BackdropFilter).
      expect(find.byType(ImageFiltered), findsOneWidget);
      expect(find.byType(BackdropFilter), findsNothing);
      // CTA visible.
      expect(find.text('UNLOCK-CTA'), findsOneWidget);
      expect(find.byIcon(Icons.lock_outline), findsOneWidget);
    });

    testWidgets('default blurSigma is 8.0 (documented contract)',
        (tester) async {
      await tester.pumpWidget(_host(
        ent(false),
        const BlurredProTeaser(ctaText: 'X', child: Text('C')),
      ));
      final filtered =
          tester.widget<ImageFiltered>(find.byType(ImageFiltered));
      expect(
        filtered.imageFilter.toString(),
        ui.ImageFilter.blur(
          sigmaX: 8.0,
          sigmaY: 8.0,
          tileMode: TileMode.decal,
        ).toString(),
      );
    });

    testWidgets('blurSigma is honoured per-surface', (tester) async {
      await tester.pumpWidget(_host(
        ent(false),
        const BlurredProTeaser(
          ctaText: 'X',
          blurSigma: 3.0,
          child: Text('C'),
        ),
      ));
      final filtered =
          tester.widget<ImageFiltered>(find.byType(ImageFiltered));
      expect(
        filtered.imageFilter.toString(),
        ui.ImageFilter.blur(
          sigmaX: 3.0,
          sigmaY: 3.0,
          tileMode: TileMode.decal,
        ).toString(),
      );
    });

    testWidgets('overlayIcon + semanticLabel are surfaced', (tester) async {
      await tester.pumpWidget(_host(
        ent(false),
        const BlurredProTeaser(
          ctaText: 'CTA',
          overlayIcon: Icons.star,
          semanticLabel: 'unlock the thing',
          child: Text('C'),
        ),
      ));
      expect(find.byIcon(Icons.star), findsOneWidget);
      expect(find.byIcon(Icons.lock_outline), findsNothing);
      expect(
        find.bySemanticsLabel('unlock the thing'),
        findsOneWidget,
      );
    });

    testWidgets('blurred subtree is wrapped in a RepaintBoundary (perf)',
        (tester) async {
      await tester.pumpWidget(_host(
        ent(false),
        const BlurredProTeaser(ctaText: 'X', child: Text('C')),
      ));
      // Raster isolation: the ImageFiltered sits under a RepaintBoundary
      // so a control-driven child repaint does not re-raster the CTA.
      expect(
        find.ancestor(
          of: find.byType(ImageFiltered),
          matching: find.byType(RepaintBoundary),
        ),
        findsWidgets,
      );
    });
  });

  group('BlurredProTeaser — CTA commit behaviour', () {
    testWidgets('free + onCommit set → CTA pill is tappable, fires onCommit',
        (tester) async {
      var taps = 0;
      await tester.pumpWidget(_host(
        ent(false),
        BlurredProTeaser(
          ctaText: 'UNLOCK-CTA',
          onCommit: () => taps++,
          // Realistically-sized child — every production wrap is a
          // large surface (a scene / list / FOV / table). With
          // StackFit.passthrough the Stack sizes to the child, so a
          // tiny child would collapse the centred pill's hit area
          // (a test artifact, not a widget bug).
          child: const SizedBox(
            width: 300,
            height: 300,
            child: Center(child: Text('C')),
          ),
        ),
      ));
      await tester.tap(find.text('UNLOCK-CTA'));
      await tester.pump();
      expect(taps, 1);
      // The tappable form uses an InkWell.
      expect(
        find.descendant(
          of: find.byType(BlurredProTeaser),
          matching: find.byType(InkWell),
        ),
        findsOneWidget,
      );
    });

    testWidgets('free + onCommit null → CTA is a pure IgnorePointer label',
        (tester) async {
      await tester.pumpWidget(_host(
        ent(false),
        const BlurredProTeaser(
          ctaText: 'UNLOCK-CTA',
          child: Text('C'),
        ),
      ));
      expect(find.text('UNLOCK-CTA'), findsOneWidget);
      // No InkWell when there is no commit handler.
      expect(
        find.descendant(
          of: find.byType(BlurredProTeaser),
          matching: find.byType(InkWell),
        ),
        findsNothing,
      );
      // The label sits under an IgnorePointer (not tap-absorbing).
      expect(
        find.ancestor(
          of: find.text('UNLOCK-CTA'),
          matching: find.byType(IgnorePointer),
        ),
        findsWidgets,
      );
    });
  });

  group('BlurredProTeaser — scrim never eats child gestures', () {
    testWidgets('an OFF-centre interactive child still receives taps (free)',
        (tester) async {
      var childTaps = 0;
      await tester.pumpWidget(_host(
        ent(false),
        BlurredProTeaser(
          ctaText: 'UNLOCK-CTA',
          onCommit: () {},
          // Child taller than the pill; the button is pinned to the
          // TOP so it is well clear of the centred CTA pill.
          child: SizedBox(
            height: 400,
            child: Align(
              alignment: Alignment.topCenter,
              child: ElevatedButton(
                onPressed: () => childTaps++,
                child: const Text('CHILD-BTN'),
              ),
            ),
          ),
        ),
      ));
      // The IgnorePointer scrim must let this through to the live child.
      await tester.tap(find.text('CHILD-BTN'));
      await tester.pump();
      expect(childTaps, 1);
    });
  });

  group('BlurredProTeaser — reactive entitlement flip', () {
    testWidgets('free→Pro flip rebuilds to the clear child (no restart)',
        (tester) async {
      final e = ent(false);
      await tester.pumpWidget(_host(
        e,
        const BlurredProTeaser(
          ctaText: 'UNLOCK-CTA',
          child: Text('CONTENT'),
        ),
      ));
      expect(find.byType(ImageFiltered), findsOneWidget);
      expect(find.text('UNLOCK-CTA'), findsOneWidget);

      e.setPro(true);
      await tester.pump();

      // Blur + CTA gone; child now rendered verbatim.
      expect(find.byType(ImageFiltered), findsNothing);
      expect(find.text('UNLOCK-CTA'), findsNothing);
      expect(find.text('CONTENT'), findsOneWidget);
    });
  });
}
