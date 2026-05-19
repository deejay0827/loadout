// FILE: lib/screens/settings/diagnostics_screen.dart
//
// ============================================================================
// WHAT THIS FILE DOES
// ============================================================================
// Renders the Settings → Diagnostics screen: a small, developer-only
// surface for flipping app state that would otherwise require a real
// purchase, a specific account, or a device condition to reproduce.
//
// Today it carries one control: the "Simulate LoadOut Pro" switch. Off
// (the default) means the app behaves as a free account — every Pro
// gate is closed, the paywall is reachable, exactly what a real free
// user sees. On means every `ProGate` opens and `ensurePro(...)`
// short-circuits to allowed, so Pro-gated screens can be exercised
// without a sandbox subscription. The switch drives
// `EntitlementNotifier.setDevProOverride(...)`; widgets that did
// `context.watch<EntitlementNotifier>()` rebuild the instant it flips.
//
// ============================================================================
// WHY IT EXISTS IN THE ARCHITECTURE
// ============================================================================
// Pro state is owned by `EntitlementNotifier`, which normally derives
// `isPro` from the live RevenueCat entitlement stream. With placeholder
// RevenueCat keys (the dev default) that stream is never configured, so
// a developer could never reach Pro-gated UI to test it. This screen is
// the one place that exposes the notifier's debug override as a user-
// facing toggle, instead of scattering `kDebugMode` checks through the
// Pro-gated screens themselves.
//
// It lives under Settings (not the bottom nav, not a floating button)
// because that's the conventional, discoverable home for developer
// switches and it keeps the production surface clean — the entry tile
// in `settings_screen.dart` is itself `kDebugMode`-gated, so this
// screen is unreachable in a release build.
//
// ============================================================================
// WHY THIS IS HARDER THAN IT LOOKS
// ============================================================================
//   * Release-build safety is load-bearing. A shipped "become Pro for
//     free" switch would gut the RevenueCat monetization the whole app
//     is built on (see marketing/CLAUDE.md § monetization). Defence in
//     depth: (a) the settings tile that routes here is wrapped in
//     `if (kDebugMode)`; (b) `EntitlementNotifier.setDevProOverride`
//     no-ops unless `kDebugMode`; (c) `EntitlementNotifier.isPro` only
//     consults the override when `kDebugMode`. In a release binary
//     `kDebugMode` is a compile-time `false`, so all three branches are
//     dead code the Dart compiler strips.
//   * Free is the default, deliberately. `_devProOverride` starts
//     `false` so a fresh debug run shows the real free-user experience
//     — the prior behaviour (always-Pro in debug) hid every gate and
//     made free-path bugs invisible during development.
//   * The switch reads `context.watch` so it reflects state changed
//     elsewhere (e.g. a future second toggle, or a test harness), not
//     just its own taps.
//
// ============================================================================
// WHO CONSUMES THIS FILE
// ============================================================================
// - `lib/screens/settings/settings_screen.dart` — adds a debug-only
//   "Diagnostics" tile whose `destinationBuilder` returns this screen.
//
// ============================================================================
// SIDE EFFECTS
// ============================================================================
// - Mutates the app-wide `EntitlementNotifier` (in-memory only; not
//   persisted). Flipping the switch rebuilds every Pro-gated widget.
// - No disk, network, database, or preference writes.

import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../services/entitlement_notifier.dart';

/// Developer-only diagnostics surface. Reachable only from the
/// `kDebugMode`-gated Settings tile; never present in a release build.
class DiagnosticsScreen extends StatelessWidget {
  const DiagnosticsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // watch — not read — so the switch position tracks the notifier
    // even if something else flips the override.
    final entitlement = context.watch<EntitlementNotifier>();
    final isProSimulated = entitlement.devProOverride;

    return Scaffold(
      appBar: AppBar(title: const Text('Diagnostics')),
      body: SafeArea(
        child: ListView(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
              child: Text(
                'Developer-only. These switches are compiled out of '
                'release builds and never reach the App Store or Play '
                'Store.',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ),
            SwitchListTile(
              secondary: Icon(
                isProSimulated
                    ? Icons.workspace_premium
                    : Icons.workspace_premium_outlined,
              ),
              title: const Text('Simulate LoadOut Pro'),
              subtitle: Text(
                isProSimulated
                    ? 'Paid account: every Pro feature is unlocked. '
                        'Turn this off to return to the free '
                        'experience.'
                    : 'Free account (default): Pro features stay gated, '
                        'exactly as a free user sees them. Turn this on '
                        'to test paid features without a purchase.',
              ),
              value: isProSimulated,
              // The notifier's setter is itself kDebugMode-guarded; the
              // extra check here keeps the intent explicit at the call
              // site and means a stray release-mode tap (impossible —
              // the tile is debug-gated — but defensive) is a no-op.
              onChanged: kDebugMode
                  ? (v) => context
                      .read<EntitlementNotifier>()
                      .setDevProOverride(v)
                  : null,
            ),
            const Divider(height: 1),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
              child: Text(
                'The toggle changes entitlement state in memory only — '
                'it is not saved and resets to Free on next launch. It '
                'does not touch RevenueCat or your real subscription.',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
