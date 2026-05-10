// FILE: lib/screens/resources/resources_screen.dart
//
// ============================================================================
// WHAT THIS FILE DOES
// ============================================================================
// Top-level "Resources" directory — the home for read-only reference
// data screens that aren't user data and aren't settings. Reference
// data is the catalog material LoadOut ships with (SAAMI cartridge
// specs today; potentially Reloading Guide, Powder Burn-Rate
// Charts, and similar in future releases). Settings was the wrong
// home for these — they aren't preferences, they're reference
// material — so they moved here.
//
// Each tile pushes its destination via a standard `MaterialPageRoute`.
// The screen mirrors the visual language of the Settings directory
// (`_CategoryTile` rows with icon + title + subtitle + chevron) so
// users navigate consistently across the two.
//
// ============================================================================
// WHY IT EXISTS IN THE ARCHITECTURE
// ============================================================================
// SAAMI Specs were originally a bottom-nav tab, then moved into
// Settings to declutter. Settings became cluttered too, and SAAMI
// reads as a *reference resource* rather than a *preference* — the
// user looks up cartridge dimensions, they don't configure
// anything. Splitting Resources out from Settings gives reference
// material a coherent home and keeps Settings focused on
// preferences (account, app prefs, privacy, sync).
//
// ============================================================================
// WHY THIS IS HARDER THAN IT LOOKS
// ============================================================================
// Trivial today (three tiles). The discipline is keeping it that way:
// every new resource gets its own `_ResourceTile` row, with the
// same shape as Settings tiles. Resist any temptation to add
// *behaviour* to this screen — search, filtering, etc. — until at
// least four resources live here. With three tiles, anything beyond a
// directory list is over-engineered. The point is that users find
// SAAMI Specs / the Internal Ballistics Calculator / Load Development
// in a sane place, not that they discover it through a rich UI.
//
// Pro-gating discipline: free / Pro tiers are NOT visually distinct
// in this directory — both groups see the same row. The gate is
// applied at tap time via `proGated: true`, which routes through
// `ensurePro(context)` before pushing the destination. The
// destination screen also wraps its body in a `ProGate` widget for
// defense in depth (in case the user somehow lands on the screen
// without going through this directory). Listing Pro tiles
// alongside free ones is deliberate: the user discovers the
// calculator exists, taps it, sees the paywall — that's the
// upgrade-discovery flow. A locked-icon prefix would discourage
// that discovery.
//
// ============================================================================
// WHO CONSUMES THIS FILE
// ============================================================================
// - lib/screens/home/home_screen.dart — `_MainDrawer` pushes
//   `ResourcesScreen()` from the new "Resources" tile.
// - lib/screens/how_it_works/how_it_works_screen.dart — the SAAMI
//   topic CTA pushes here so the user lands on the same screen the
//   drawer surface points to.
//
// ============================================================================
// SIDE EFFECTS
// ============================================================================
// None — just a directory of MaterialPageRoute pushes.

import 'package:flutter/material.dart';

import '../../widgets/pro_gate.dart';
import '../ballistics/internal_ballistics_screen.dart';
import '../inventory/inventory_list_screen.dart';
import '../load_development/load_development_list_screen.dart';
import '../saami/saami_screen.dart';

class ResourcesScreen extends StatelessWidget {
  const ResourcesScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Resources')),
      body: SafeArea(
        child: ListView(
          children: [
            _ResourceTile(
              icon: Icons.straighten_outlined,
              title: 'SAAMI Specs',
              subtitle:
                  'Reference dimensions and pressures for every '
                  'cartridge in the SAAMI catalog.',
              destinationBuilder: (_) => const SaamiScreen(),
            ),
            _ResourceTile(
              icon: Icons.calculate_outlined,
              title: 'Internal Ballistics Calculator',
              subtitle:
                  'Predict muzzle velocity and peak pressure for a '
                  'hypothetical reloading recipe. Pro Feature.',
              // Pro gate: route push only after `ensurePro` resolves
              // true. Free users see the paywall instead of the
              // calculator. Mirrors how every other Pro feature
              // surfaces its gate from a list (CLAUDE.md § Pro gating).
              proGated: true,
              destinationBuilder: (_) => const InternalBallisticsScreen(),
            ),
            _ResourceTile(
              icon: Icons.science_outlined,
              title: 'Load Development',
              subtitle:
                  'OCW, Audette Ladder, Satterlee 10-shot, and Generic '
                  'charge ladders with statistical analysis. Pro Feature.',
              // The list screen wraps its body in a ProGate, so we
              // don't need to gate the route push here — free users
              // hitting the tile see the upgrade card on the list
              // screen. Keeping the resource tile non-gated lets free
              // users browse the feature description, which improves
              // upsell conversion (CLAUDE.md § Pro gating).
              destinationBuilder: (_) => const LoadDevelopmentListScreen(),
            ),
            _ResourceTile(
              icon: Icons.inventory_2_outlined,
              title: 'Component Inventory',
              subtitle:
                  'On-hand quantity tracking for powder, primers, '
                  'bullets, brass, and factory ammo. Quick adjust + '
                  'audit log per container.',
              // Inventory is intentionally NOT marketed (CLAUDE.md
              // § 26). Free for all users; lives here under
              // Resources rather than the bottom nav so we close
              // the "Reloader's Log has this and we don't" gap
              // without making inventory a stated focus.
              destinationBuilder: (_) => const InventoryListScreen(),
            ),
            // Future resources land here as they ship. Examples:
            //   * Reloading Guide (text reference)
            //   * Powder Burn-Rate Chart
            //   * Cartridge cross-reference / wildcat-parent map
            // Add a new `_ResourceTile` row above this comment when
            // a new screen is ready; the layout takes any number.
          ],
        ),
      ),
    );
  }
}

/// Re-usable directory row for the Resources screen. Same shape as
/// the Settings directory's `_CategoryTile` so users navigate
/// between the two screens with no friction.
///
/// When [proGated] is true, the tap routes through `ensurePro(...)`
/// before pushing the destination. Free users get the paywall; Pro
/// users get the destination immediately. Visually identical for
/// both — we deliberately don't show a lock icon on the row, because
/// the destination's own `ProGate` wrapping renders the upgrade card
/// inside the destination screen if a free user somehow arrives
/// there (defense in depth).
class _ResourceTile extends StatelessWidget {
  const _ResourceTile({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.destinationBuilder,
    this.proGated = false,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final WidgetBuilder destinationBuilder;
  final bool proGated;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: Icon(icon),
      title: Text(title),
      subtitle: Text(subtitle),
      trailing: const Icon(Icons.chevron_right),
      onTap: () async {
        if (proGated) {
          if (!await ensurePro(context)) return;
        }
        if (!context.mounted) return;
        await Navigator.of(context).push(
          MaterialPageRoute(builder: destinationBuilder),
        );
      },
    );
  }
}
