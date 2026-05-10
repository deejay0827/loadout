// FILE: lib/widgets/lookup_loads_sheet.dart
//
// ============================================================================
// WHAT THIS FILE DOES
// ============================================================================
// Modal bottom sheet that hands the user off to a powder-or-bullet
// manufacturer's official online load-data tool, in their system
// browser. Reachable from any cartridge surface (SAAMI screen, recipe
// form, Range Day load picker) via the public function
// [showLookupLoadsSheet].
//
// The sheet shows four cards — Hodgdon Reloading Data Center, Hornady
// Load Data, Sierra Load Data, Vihtavuori Reloading Data Tool — each
// with the manufacturer's name + a one-line description of what they
// publish. Tapping a card calls `url_launcher` and the user lands on
// the manufacturer's own page in Safari / Chrome / etc.
//
// **What this is NOT:** a republisher. We never ship manufacturer
// recipes inside the app, never scrape, never cache. The button is
// purely a deep-link launcher, with the sheet's subtitle telegraphing
// that promise to the user explicitly.
//
// ============================================================================
// WHY IT EXISTS IN THE ARCHITECTURE
// ============================================================================
// Per the Gap 2 audit (2026-05-10): the four major US powder + bullet
// manufacturers either explicitly prohibit (Hodgdon, Sierra, Speer/
// Kinetic Group) or implicitly assert copyright over (Hornady) the
// republication of their published load tables. The previously
// proposed "ship a built-in starting-load library" plan was killed
// for that reason. This sheet is the chosen mitigation: give the
// user a one-tap path to the official source without copying any
// data into LoadOut's bundle.
//
// The strategic frame is honest and on-brand: "we never republish
// anyone else's data — your recipes are yours, theirs are theirs.
// Tap the brand to open their official source."
//
// ============================================================================
// WHY THIS IS HARDER THAN IT LOOKS
// ============================================================================
//   * Deep-linking by cartridge is tempting but fragile. Hornady's
//     URL pattern, Hodgdon's RDC routing, and Vihtavuori's tool URL
//     all change without notice — a deep link that worked in v1.0
//     can 404 by v1.5 and we'd have to ship an app update to fix it.
//     The sheet therefore opens the manufacturer's TOP-level load
//     data page and lets the user search within it. Less elegant,
//     vastly more durable.
//   * `canLaunchUrl` returns true on most platforms only when the
//     scheme is whitelisted in the platform manifest. iOS LSApplica-
//     tionQueriesSchemes already lists `https`, so this works out of
//     the box; Android's API 30+ requires a `<queries>` block in
//     `AndroidManifest.xml` which we already have for the
//     `text/plain` share intent. So no manifest plumbing needed for
//     this widget.
//   * `LaunchMode.externalApplication` is intentional — opening the
//     URL in an in-app webview would inherit our app's identity in
//     the manufacturer's analytics, which is a privacy-leak we don't
//     want and a UX surprise for the user who expected Safari /
//     Chrome.
//   * The sheet must NOT pass the user's typed cartridge into the
//     URL even when the manufacturer's page accepts a `?cartridge=`
//     query param. That would silently betray the user's input to
//     the third party and create the appearance that we're "sending"
//     their data. The cartridge name is passed as informational text
//     ("you're looking up: 6.5 Creedmoor") so the user can copy /
//     re-type on the destination page. Slightly less convenient,
//     materially better posture.
//
// ============================================================================
// WHO CONSUMES THIS FILE
// ============================================================================
// - lib/screens/saami/saami_screen.dart — per-cartridge "Look Up
//   Published Loads" affordance.
// - lib/screens/loads/load_form_screen.dart — same affordance on
//   the recipe form so a user typing a fresh recipe can grab a
//   starting charge from the manufacturer's official page.
// - Future surfaces (Range Day load picker, ballistics screen
//   bullet picker) can call the same function.
//
// ============================================================================
// SIDE EFFECTS
// ============================================================================
// - Calls `url_launcher.launchUrl` to open a URL in the system
//   browser. No network calls from this app.
// - Reads no persistent state.

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

/// Show the manufacturer-link-out sheet. The optional [cartridgeName]
/// is rendered for the user's reference only — it is intentionally
/// NOT passed to the manufacturer site so the user's input never
/// leaks across the app boundary.
Future<void> showLookupLoadsSheet(
  BuildContext context, {
  String? cartridgeName,
}) async {
  await showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    useSafeArea: true,
    builder: (_) => _LookupLoadsSheetBody(cartridgeName: cartridgeName),
  );
}

class _LookupLoadsSheetBody extends StatelessWidget {
  const _LookupLoadsSheetBody({required this.cartridgeName});

  final String? cartridgeName;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final entries = _kManufacturerEntries;
    return SafeArea(
      child: ListView(
        shrinkWrap: true,
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
        children: [
          Text(
            'Look Up Published Load Data',
            style: theme.textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            "We don't republish manufacturer recipes inside LoadOut — "
            "your data stays yours, theirs stays theirs. Tap a brand "
            'below to open their official load-data page in your '
            'browser.',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          if (cartridgeName != null && cartridgeName!.trim().isNotEmpty) ...[
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.symmetric(
                horizontal: 12,
                vertical: 8,
              ),
              decoration: BoxDecoration(
                color: theme.colorScheme.primaryContainer
                    .withValues(alpha: 0.4),
                borderRadius: BorderRadius.circular(6),
              ),
              child: Row(
                children: [
                  Icon(
                    Icons.search,
                    size: 16,
                    color: theme.colorScheme.onPrimaryContainer,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      "Searching for: ${cartridgeName!.trim()}",
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onPrimaryContainer,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
          const SizedBox(height: 12),
          for (final e in entries) _ManufacturerCard(entry: e),
        ],
      ),
    );
  }
}

class _ManufacturerCard extends StatelessWidget {
  const _ManufacturerCard({required this.entry});

  final _ManufacturerEntry entry;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => _open(context),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(
                entry.icon,
                size: 24,
                color: theme.colorScheme.primary,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      entry.brand,
                      style: theme.textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      entry.description,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              Icon(
                Icons.open_in_new,
                size: 18,
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _open(BuildContext context) async {
    final messenger = ScaffoldMessenger.of(context);
    final navigator = Navigator.of(context);
    final uri = Uri.parse(entry.url);
    try {
      final ok = await launchUrl(
        uri,
        mode: LaunchMode.externalApplication,
      );
      if (!ok) throw 'launchUrl returned false';
      navigator.pop();
    } catch (_) {
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            "Couldn't open ${entry.brand}. Check your network and "
            'try again.',
          ),
        ),
      );
    }
  }
}

/// One row in the link-out sheet. Top-level URLs only — see file
/// header for why we don't deep-link by cartridge.
class _ManufacturerEntry {
  const _ManufacturerEntry({
    required this.brand,
    required this.description,
    required this.url,
    required this.icon,
  });

  final String brand;
  final String description;
  final String url;
  final IconData icon;
}

/// Static catalog of manufacturer link-outs. Order is alphabetical
/// to avoid implying a preference. Add a new entry here when a new
/// publisher comes online; nothing else needs to change.
const List<_ManufacturerEntry> _kManufacturerEntries = [
  _ManufacturerEntry(
    brand: 'Hodgdon',
    description: 'Reloading Data Center — Hodgdon, IMR, Winchester '
        'powder data across rifle, pistol, and shotgun cartridges.',
    url: 'https://hodgdonreloading.com/rldc/',
    icon: Icons.local_fire_department_outlined,
  ),
  _ManufacturerEntry(
    brand: 'Hornady',
    description: 'Manufacturer load data plus the Hornady Reloading '
        'Guide and 4DOF ballistics tools.',
    url: 'https://www.hornady.com/support/load-data',
    icon: Icons.adjust_outlined,
  ),
  _ManufacturerEntry(
    brand: 'Sierra Bullets',
    description: 'Published load data accompanying every Sierra '
        'bullet line, indexed by cartridge.',
    url: 'https://sierrabullets.com/load-data/',
    icon: Icons.gps_fixed_outlined,
  ),
  _ManufacturerEntry(
    brand: 'Vihtavuori',
    description: 'Reloading Data Tool covering 100+ cartridges with '
        'Vihtavuori powder lineup. Strong European coverage.',
    url: 'https://www.vihtavuori.com/reloading-data/reloading-data-tool/',
    icon: Icons.science_outlined,
  ),
];
