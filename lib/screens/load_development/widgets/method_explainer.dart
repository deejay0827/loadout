// FILE: lib/screens/load_development/widgets/method_explainer.dart
//
// ============================================================================
// WHAT THIS FILE DOES
// ============================================================================
// Renders an expandable "Method" card on every load-development detail
// screen. Holds a one-paragraph plain-English explanation of the
// protocol the user is running (OCW, Audette Ladder, Satterlee 10-shot,
// Generic) plus a citation block crediting the published source so a
// reloader who learned the technique elsewhere can verify the
// implementation matches the literature they trust.
//
// Public surface: `MethodExplainerCard` — a `StatelessWidget` that
// takes a `MethodKind` enum and an optional override for the card
// title. The body and citation strings live in this file so adding a
// new method (e.g. ammo science Holland method) is one switch case
// here plus one new enum value, no UI rewiring.
//
// ============================================================================
// WHY IT EXISTS IN THE ARCHITECTURE
// ============================================================================
// The user-facing surface needs to (a) tell a new user what the
// method actually does, and (b) reassure an experienced reloader that
// the app is following the published method, not a half-remembered
// summary. A separate, expandable card means the info is one tap
// away on every detail screen without crowding the data-entry rows.
//
// ============================================================================
// WHY THIS IS HARDER THAN IT LOOKS
// ============================================================================
// Title Case applies to LABELS / HEADERS only (CLAUDE.md § 0a). Every
// paragraph below is body copy, so it stays in sentence case even
// when the heading right above is Title Case. Mixing them up in this
// file would propagate to every detail screen.
//
// ============================================================================
// WHO CONSUMES THIS FILE
// ============================================================================
// - lib/screens/load_development/ocw_test_screen.dart
// - lib/screens/load_development/ladder_test_screen.dart
// - lib/screens/load_development/satterlee_test_screen.dart
// - lib/screens/load_development/generic_test_screen.dart
//
// ============================================================================
// SIDE EFFECTS
// ============================================================================
// None — pure rendering.

import 'package:flutter/material.dart';

/// Which load-development method this card describes.
enum MethodKind { ocw, ladder, satterlee, generic, seating }

/// Expandable card with a plain-language explanation and a citation
/// block for one [MethodKind].
class MethodExplainerCard extends StatelessWidget {
  const MethodExplainerCard({
    super.key,
    required this.method,
    this.title,
  });

  final MethodKind method;

  /// Optional title override. Defaults to "Method".
  final String? title;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final detail = _detailFor(method);
    return Card(
      clipBehavior: Clip.antiAlias,
      child: ExpansionTile(
        leading: Icon(
          Icons.menu_book_outlined,
          color: theme.colorScheme.primary,
        ),
        title: Text(title ?? 'Method'),
        subtitle: Text(detail.shortName),
        childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        children: [
          Align(
            alignment: Alignment.centerLeft,
            child: Text(
              detail.body,
              style: theme.textTheme.bodyMedium,
            ),
          ),
          const SizedBox(height: 12),
          Align(
            alignment: Alignment.centerLeft,
            child: Text(
              'How to read the results',
              style: theme.textTheme.labelLarge?.copyWith(
                color: theme.colorScheme.primary,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          const SizedBox(height: 4),
          Align(
            alignment: Alignment.centerLeft,
            child: Text(
              detail.howToRead,
              style: theme.textTheme.bodyMedium,
            ),
          ),
          const SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 10),
            decoration: BoxDecoration(
              color: theme.colorScheme.primary.withValues(alpha: 0.08),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(
                color: theme.colorScheme.primary.withValues(alpha: 0.25),
              ),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Source',
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: theme.colorScheme.primary,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.4,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  detail.citation,
                  style: theme.textTheme.bodySmall,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  _MethodDetail _detailFor(MethodKind k) {
    switch (k) {
      case MethodKind.ocw:
        return const _MethodDetail(
          shortName: 'Optimal Charge Weight (Newberry)',
          body:
              'OCW fires three shots per charge weight across an evenly-stepped '
              'charge ladder, then plots the vertical point of impact against '
              'charge weight. The "OCW node" shows up as a flat spot in that '
              'plot — a span of consecutive charges where small powder changes '
              'do not move the vertical impact much. The flat spot identifies '
              'a charge range where the load is sitting at a barrel-time '
              'harmonic node and is forgiving of the small day-to-day powder '
              'variation that comes with a thrown charge or a humid powder '
              'measure.',
          howToRead:
              'Look at the vertical-impact-vs-charge chart. The flat spot is '
              'highlighted in the brand colour. Aim to load at the centre of '
              'that flat spot. If no flat spot appears, the analysis card '
              'will tell you — usually it means the ladder needs a wider '
              'span or an additional shot per charge to clean up the noise.',
          citation:
              'Newberry, Dan. "Optimal Charge Weight Load Development." '
              'Method published in 2002 onward at ocwreloading.com and on '
              '6mmBR.com forums. The 3-shot-per-charge protocol with '
              'vertical-impact analysis is canonical.',
        );
      case MethodKind.ladder:
        return const _MethodDetail(
          shortName: 'Audette Ladder',
          body:
              'A ladder fires one shot per charge weight at distance (typically '
              '300 yards or further), aiming at the same point of aim each '
              'time. Charges that land near each other vertically are sitting '
              'at the same node — the bullets are physically "stacking" on '
              'the target even though their charge weights differ. The shooter '
              'picks a charge near the centre of the cluster and verifies it '
              'with a 5-shot group later.',
          howToRead:
              'Look at the impact plot for vertical clustering. Charges where '
              'the shots stacked tightly together are your candidate nodes. '
              'The vertical-spread summary tells you the gap between the '
              'highest and lowest impact across all your charges; a real node '
              'shows up as a stretch of consecutive charges all within roughly '
              '0.5 to 0.75 inches of each other at distance.',
          citation:
              'Audette, Creighton. Original method published in Precision '
              'Shooting magazine in the late 1970s. The single-shot-per-charge '
              'fired-at-distance protocol with vertical-stacking analysis is '
              'his — the modern OCW method derives from it but uses three '
              'shots per charge for noise tolerance.',
        );
      case MethodKind.satterlee:
        return const _MethodDetail(
          shortName: 'Satterlee 10-shot',
          body:
              'A chronograph-driven method: shoot 10 rounds stepping the '
              'charge by 0.1 to 0.2 grains through the safe range of your '
              'cartridge. Plot mean velocity against charge weight. Look for '
              'a "plateau" — a stretch of consecutive charges where the '
              'velocity barely climbs even though more powder went in. The '
              'plateau is the load\'s pressure / barrel-time node; loads '
              'tuned to the centre of the plateau are forgiving of small '
              'powder variations.',
          howToRead:
              'The MV-vs-charge chart highlights the longest plateau in the '
              'brand colour. Centre your final load on the middle charge of '
              'that plateau. A plateau of three or more consecutive charges '
              'is meaningful; if no plateau emerges, your charge step may be '
              'too coarse or the data has too much shot-to-shot noise — '
              'consider re-running with two shots per charge to confirm.',
          citation:
              'Satterlee, Scott. "10-Round Load Development Test." Spec\'d '
              'in informal coaching writeups; widely applied in PRS / '
              'long-range rifle shooting. The single-shot-per-charge '
              'chronograph-driven protocol with plateau analysis is his.',
        );
      case MethodKind.generic:
        return const _MethodDetail(
          shortName: 'Generic charge ladder',
          body:
              'A freeform ladder for protocols that do not match OCW, Ladder, '
              'or Satterlee exactly. Log shots one at a time with chronograph '
              'and impact data; the analysis card surfaces per-charge SD, ES, '
              'mean MV, mean impact, and group size so you can choose the '
              'best charge by whichever metric matters most for your test.',
          howToRead:
              'Use the per-charge stats table to compare charges across the '
              'metrics that matter to your protocol. The chart cycles between '
              'velocity SD, vertical impact, and group size — pick the view '
              'that matches the variable you are tuning.',
          citation:
              'Generic protocols vary by shooter; this surface stays '
              'opinion-free and surfaces the same per-charge statistics that '
              'OCW / Ladder / Satterlee compute internally.',
        );
      case MethodKind.seating:
        return const _MethodDetail(
          shortName: 'Seating depth ladder',
          body:
              'A CBTO (cartridge base to ogive) ladder around an existing '
              'recipe, tuning seating depth to find the bullet jump that '
              'shoots the tightest groups for your firearm. Each rung is a '
              'small batch of rounds with one CBTO setting; the rung with '
              'the lowest mean (group, vertical) MOA wins.',
          howToRead:
              'The chart plots mean (group, vertical) MOA versus CBTO. The '
              'winning CBTO is highlighted; the analysis card surfaces the '
              'recommendation and offers a one-tap update of your source '
              'recipe\'s CBTO field. Bullet seating windows tend to be a '
              'few thousandths wide, so a step of 0.003" to 0.005" is normal.',
          citation:
              'Seating-depth ladders are a long-standing precision-rifle '
              'practice without a single canonical author. The implementation '
              'follows the consensus protocol used in PRS and F-class circles.',
        );
    }
  }
}

class _MethodDetail {
  const _MethodDetail({
    required this.shortName,
    required this.body,
    required this.howToRead,
    required this.citation,
  });

  final String shortName;
  final String body;
  final String howToRead;
  final String citation;
}
