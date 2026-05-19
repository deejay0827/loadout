// FILE: test/teaser_blur_wiring_test.dart
//
// ============================================================================
// WHAT THIS FILE DOES
// ============================================================================
// Version-agnostic STRUCTURAL regression guards for the VFP Phase 3
// Group B teaser-blur Option 2 wiring. These read the actual source
// files and assert the load-bearing wiring invariants directly —
// they do NOT pump widgets and do NOT touch the entitlement harness,
// so they hold regardless of the Settings → Diagnostics Free/Pro
// rework on main (commit 2456473). They are the "ship-with-the-impl"
// half of the operator-approved split; the full per-surface free/Pro
// WIDGET matrix runs post-D11-merge against the shipping harness (see
// docs/PRO_GATING.md "Post-D11 pre-launch validation").
//
// The five pinned invariants (operator-enumerated):
//   1. Every gated surface imports + uses `BlurredProTeaser`; the
//      documented out-of-scope generic glyph (reticle_thumbnail) does
//      NOT (pins the scoping decision so a future "blur everything"
//      change fails loudly).
//   2. The reticle picker routes EVERY commit (row tap / "None" /
//      Find-by-Scope) through the single `_commitSelection` →
//      `ensurePro` chokepoint.
//   3. The §30 interoperability caption is rendered OUTSIDE the
//      reticle-preview blur (legal/compliance carve-out — the caption
//      must stay legible for free users).
//   4. ScopeViewScreen wraps its FOV render + adjustments table in
//      `BlurredProTeaser`; the cosmetic "Pro" badge that advertised a
//      non-existent gate (audit Gap 1) is gone.
//   5. `_openScopeView` no longer hard-paywalls at entry (D5 Option
//      β) — a free user can reach ScopeViewScreen; the gate is the
//      render-layer blur, not an entry early-return.
//
// ============================================================================
// WHY IT EXISTS IN THE ARCHITECTURE
// ============================================================================
// The A2 teaser-blur posture is enforced purely by per-surface
// wiring around one primitive. A careless refactor (dropping a
// `BlurredProTeaser` wrap, re-adding the Scope View entry paywall,
// widening the blur over the §30 caption, scattering commit gates
// instead of the chokepoint) would silently regress gating or
// IP-posture without failing the primitive contract test
// (blurred_pro_teaser_test.dart) or `flutter analyze`. These source
// invariants fail loudly on exactly those regressions.
//
// ============================================================================
// WHY THIS IS HARDER THAN IT LOOKS
// ============================================================================
//   * "Caption OUTSIDE the blur" is asserted by extracting the
//     balanced `BlurredProTeaser( … )` span and proving the caption
//     identifier is not inside it — a substring index check would
//     false-pass when the caption sits after the wrap.
//   * "No entry paywall" must scope to the `_openScopeView` method
//     body only — the file has ~8 other legitimate `ensurePro` calls
//     for unrelated Pro features that must NOT be matched.
//
// ============================================================================
// SIDE EFFECTS
// ============================================================================
// Reads lib/ source files from disk (package-root-relative, the same
// pattern as test/assets_present_test.dart). No widget pump, no DB,
// no network.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String _src(String path) {
  final f = File(path);
  expect(f.existsSync(), isTrue, reason: 'expected source file: $path');
  return f.readAsStringSync();
}

/// Extract the balanced `(...)` span starting at the first occurrence
/// of [opener] (e.g. `'BlurredProTeaser('`). Returns the substring
/// from the opener through its matching close paren. Throws via
/// `expect` if the opener is absent or parens never balance.
String _balancedSpan(String src, String opener) {
  final start = src.indexOf(opener);
  expect(start, greaterThanOrEqualTo(0),
      reason: 'expected to find "$opener"');
  // Position of the '(' that begins the argument list.
  var i = start + opener.length - 1;
  var depth = 0;
  for (; i < src.length; i++) {
    final c = src[i];
    if (c == '(') depth++;
    if (c == ')') {
      depth--;
      if (depth == 0) return src.substring(start, i + 1);
    }
  }
  fail('parens never balanced for "$opener"');
}

/// Extract a method body span: from [signature] through the matching
/// closing brace of its `{ … }` block.
String _methodBody(String src, String signature) {
  final start = src.indexOf(signature);
  expect(start, greaterThanOrEqualTo(0),
      reason: 'expected method signature: $signature');
  final braceOpen = src.indexOf('{', start);
  expect(braceOpen, greaterThanOrEqualTo(0));
  var depth = 0;
  for (var i = braceOpen; i < src.length; i++) {
    final c = src[i];
    if (c == '{') depth++;
    if (c == '}') {
      depth--;
      if (depth == 0) return src.substring(start, i + 1);
    }
  }
  fail('braces never balanced for "$signature"');
}

void main() {
  const picker = 'lib/widgets/reticle_picker.dart';
  const fullScreen = 'lib/widgets/reticle_full_screen_view.dart';
  const thumbnail = 'lib/widgets/reticle_thumbnail.dart';
  const rangeDay = 'lib/screens/range_day/range_day_detail_screen.dart';
  const scopeView = 'lib/screens/range_day/scope_view_screen.dart';

  group('Invariant 1 — gated surfaces use BlurredProTeaser', () {
    for (final path in [picker, fullScreen, rangeDay, scopeView]) {
      test('$path imports + uses BlurredProTeaser', () {
        final s = _src(path);
        expect(s.contains("blurred_pro_teaser.dart"), isTrue,
            reason: '$path must import the teaser primitive');
        expect(s.contains('BlurredProTeaser('), isTrue,
            reason: '$path must wrap its Pro content in BlurredProTeaser');
      });
    }

    test('reticle_thumbnail (generic glyph) is documented OUT of scope',
        () {
      // Pins the D2/D3 scoping decision: a generic shared glyph is
      // not Pro content. If a future change blurs it, this fails and
      // forces a re-think rather than a silent over-blur.
      expect(_src(thumbnail).contains('BlurredProTeaser'), isFalse);
    });
  });

  group('Invariant 2 — reticle picker commit chokepoint', () {
    test('every commit routes through _commitSelection → ensurePro', () {
      final s = _src(picker);
      // The chokepoint exists and gates via ensurePro.
      final body =
          _methodBody(s, 'Future<void> _commitSelection(');
      expect(body.contains('ensurePro(context)'), isTrue,
          reason: '_commitSelection must gate via ensurePro');
      expect(body.contains('navigator.pop(selection)'), isTrue,
          reason: '_commitSelection pops with the selection only after '
              'the gate clears');
      // Row tap routes through it.
      expect(s.contains('onPick: () => _commitSelection('), isTrue,
          reason: 'list-row tap must route through the chokepoint');
      // "None" clear routes through it.
      expect(
          s.contains('_commitSelection(\n                            '
              'const _ReticleSelection(cleared: true))'),
          isTrue,
          reason: '"None" must route through the chokepoint');
      // Find-by-Scope match routes through it.
      expect(
          s.contains('await _commitSelection(_ReticleSelection(row: match))'),
          isTrue,
          reason: 'Find-by-Scope match must route through the chokepoint');
      // And the OLD ungated direct pop is gone.
      expect(
          s.contains("Navigator.of(context)\n"
              "                            .pop(const _ReticleSelection"),
          isFalse,
          reason: 'the pre-gate direct "None" pop must be removed');
    });
  });

  group('Invariant 3 — §30 caption OUTSIDE the reticle-preview blur', () {
    test('ReticleInteroperabilityLabel is NOT inside the BlurredProTeaser',
        () {
      final s = _src(fullScreen);
      expect(s.contains('BlurredProTeaser('), isTrue);
      expect(s.contains('ReticleInteroperabilityLabel('), isTrue,
          reason: 'the §30 caption must still be rendered');
      final teaserSpan = _balancedSpan(s, 'BlurredProTeaser(');
      expect(
        teaserSpan.contains('ReticleInteroperabilityLabel'),
        isFalse,
        reason: 'IP-posture carve-out: the legal interoperability '
            'caption must render OUTSIDE the blur (always legible for '
            'free users), never wrapped inside BlurredProTeaser',
      );
    });
  });

  group('Invariant 4 — ScopeViewScreen wrap + Gap-1 badge removed', () {
    test('FOV + adjustments wrapped (>=2 BlurredProTeaser)', () {
      final s = _src(scopeView);
      final count = 'BlurredProTeaser('.allMatches(s).length;
      expect(count, greaterThanOrEqualTo(2),
          reason: 'the scope FOV render AND the adjustments table must '
              'each be wrapped');
    });

    test('cosmetic "Pro" badge removed from the animated-mover card', () {
      final s = _src(scopeView);
      // The exact pre-D5 cosmetic chip was `child: Text('Pro',` inside
      // a decorated Container in _animatedMoverCard. It must be gone
      // (it advertised a gate that did not exist — audit Gap 1).
      expect(s.contains("child: Text('Pro',"), isFalse,
          reason: 'the misleading cosmetic Pro chip must be removed; '
              'the real gate is the FOV teaser-blur the mover animates');
    });
  });

  group('Invariant 5 — Scope View entry is no longer hard-paywalled', () {
    test('_openScopeView has no entry ensurePro early-return (Option β)',
        () {
      final body =
          _methodBody(_src(rangeDay), 'Future<void> _openScopeView(');
      // The pre-A2 holdover was the FIRST statement:
      //   if (!await ensurePro(context)) return;
      expect(
        body.contains('if (!await ensurePro(context)) return;'),
        isFalse,
        reason: 'D5 Option β: Scope View must open for free users '
            '(teaser-blurred inside); the entry-level ensurePro '
            'early-return is removed',
      );
      // And the Option-β rationale is recorded at the call site.
      expect(body.contains('Option β'), isTrue,
          reason: 'the Option β decision should be documented in '
              '_openScopeView so the removal is not mistaken for a bug');
    });
  });
}
