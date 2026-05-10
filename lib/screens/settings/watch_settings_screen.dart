// FILE: lib/screens/settings/watch_settings_screen.dart
//
// ============================================================================
// WHAT THIS FILE DOES
// ============================================================================
// Settings → Watch & Wear submenu. Surfaces the user-facing knobs for
// the Apple Watch / Wear OS companion apps:
//
//   * Connection status — paired / app installed / reachable, pulled
//     live from `WatchBridgeService.connection`.
//   * Stage timer defaults — placeholder (companion-app stage timer
//     ships separately; the row points to the per-screen setting on
//     the watch for now).
//   * Glanceable DOPE preferences — placeholder.
//   * Shot capture sensitivity — the new four-way preset (Off / Low /
//     Medium / High). Bound to [WatchSettingsService] so changes
//     persist + push to the watch via the bridge.
//
// ============================================================================
// WHY IT EXISTS IN THE ARCHITECTURE
// ============================================================================
// Watch settings used to live inside the watch's own settings sheet
// (Stage Log → ellipsis). Power users wanted one place on the phone
// to think about their watch — partly because the watch UI is small
// and partly so they can audit the settings without putting the
// watch on. This screen is that one place.
//
// The Shot Capture Sensitivity preset replaces the old continuous
// 3.0–10.0 g threshold slider for most users. The slider is still
// available on the watch's own settings sheet for power users who
// want fine-grained control, but the four presets cover 95% of
// real-world use.

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../services/watch_bridge_service.dart';
import '../../services/watch_settings_service.dart';

class WatchSettingsScreen extends StatelessWidget {
  const WatchSettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final settings = context.watch<WatchSettingsService>();
    final bridge = context.watch<WatchBridgeService>();
    return Scaffold(
      appBar: AppBar(title: const Text('Watch & Wear')),
      body: ListView(
        children: [
          _ConnectionStatusTile(bridge: bridge),
          const Divider(height: 1),
          ListTile(
            leading: const Icon(Icons.timer_outlined),
            title: const Text('Stage Timer Defaults'),
            subtitle: const Text(
              'Default par time and warning beeps for the watch '
              'competition stage timer. Configured on the watch today; '
              'this row will move here in a future update.',
            ),
            enabled: false,
          ),
          ListTile(
            leading: const Icon(Icons.grid_on_outlined),
            title: const Text('Glanceable DOPE Preferences'),
            subtitle: const Text(
              "Customize the watch's DOPE card layout — coming soon.",
            ),
            enabled: false,
          ),
          const _SectionHeader('Shot capture'),
          _ShotCaptureSensitivityTile(settings: settings),
        ],
      ),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader(this.title);
  final String title;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
      child: Text(
        title.toUpperCase(),
        style: theme.textTheme.labelSmall?.copyWith(
          color: theme.colorScheme.primary,
          letterSpacing: 0.8,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

/// Live connection-state tile. Reads from `WatchBridgeService` so the
/// state is current when the user opens the screen, and re-renders
/// whenever the bridge reports a paired / reachable change.
class _ConnectionStatusTile extends StatelessWidget {
  const _ConnectionStatusTile({required this.bridge});
  final WatchBridgeService bridge;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<WatchConnectionState>(
      valueListenable: bridge.connection,
      builder: (context, state, _) {
        final theme = Theme.of(context);
        final (icon, color, title, subtitle) = _stateRow(theme, state);
        return ListTile(
          leading: Icon(icon, color: color),
          title: Text(title),
          subtitle: Text(subtitle),
          trailing: IconButton(
            tooltip: 'Refresh',
            icon: const Icon(Icons.refresh_outlined),
            onPressed: () {
              // ignore: discarded_futures
              bridge.refreshConnectionState();
            },
          ),
        );
      },
    );
  }

  (IconData, Color, String, String) _stateRow(
    ThemeData theme,
    WatchConnectionState state,
  ) {
    switch (state) {
      case WatchConnectionState.unsupported:
        return (
          Icons.watch_off_outlined,
          theme.colorScheme.onSurfaceVariant,
          'Not available on this platform',
          'Companion apps run on Apple Watch and Wear OS only.',
        );
      case WatchConnectionState.notPaired:
        return (
          Icons.watch_off_outlined,
          theme.colorScheme.onSurfaceVariant,
          'No watch paired',
          'Pair an Apple Watch or Wear OS device first.',
        );
      case WatchConnectionState.appNotInstalled:
        return (
          Icons.download_for_offline_outlined,
          theme.colorScheme.tertiary,
          'Companion app not installed',
          'Install the LoadOut watch app on your paired watch.',
        );
      case WatchConnectionState.notReachable:
        return (
          Icons.watch_outlined,
          theme.colorScheme.onSurfaceVariant,
          'Watch paired (asleep or out of range)',
          'Open the LoadOut watch face / app to wake the link.',
        );
      case WatchConnectionState.reachable:
        return (
          Icons.watch_outlined,
          theme.colorScheme.primary,
          'Watch connected',
          'LoadOut companion app is reachable.',
        );
    }
  }
}

/// Settings tile that lets the user pick the watch's shot-capture
/// sensitivity preset. Renders as a 4-button SegmentedButton with a
/// helper-text caption underneath.
class _ShotCaptureSensitivityTile extends StatelessWidget {
  const _ShotCaptureSensitivityTile({required this.settings});
  final WatchSettingsService settings;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final current = settings.sensitivity;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.fitness_center_outlined,
                  color: theme.colorScheme.primary),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  'Shot capture sensitivity',
                  style: theme.textTheme.titleSmall,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          SegmentedButton<ShotCaptureSensitivity>(
            segments: const [
              ButtonSegment(
                value: ShotCaptureSensitivity.off,
                label: Text('Off'),
              ),
              ButtonSegment(
                value: ShotCaptureSensitivity.low,
                label: Text('Low'),
              ),
              ButtonSegment(
                value: ShotCaptureSensitivity.medium,
                label: Text('Medium'),
              ),
              ButtonSegment(
                value: ShotCaptureSensitivity.high,
                label: Text('High'),
              ),
            ],
            selected: {current},
            showSelectedIcon: false,
            onSelectionChanged: (s) {
              // ignore: discarded_futures
              settings.setSensitivity(s.first);
            },
          ),
          const SizedBox(height: 8),
          Text(
            'Adjust how aggressively the watch listens for shot impulses. '
            'Off disables motion detect entirely; you can still log shots '
            'by swiping right on the watch.',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 8),
          _SensitivityBlurb(current: current),
        ],
      ),
    );
  }
}

/// Per-preset descriptive caption shown under the segmented button.
class _SensitivityBlurb extends StatelessWidget {
  const _SensitivityBlurb({required this.current});
  final ShotCaptureSensitivity current;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final text = switch (current) {
      ShotCaptureSensitivity.off =>
        'Motion-detect disabled. Swipe-to-log still works.',
      ShotCaptureSensitivity.low =>
        'Low sensitivity (≈8 g). Fewer false positives, may miss shots '
            'in soft recoil (.22 LR, suppressed pistols).',
      ShotCaptureSensitivity.medium =>
        'Default. Tuned for typical centerfire rifles (≈5 g).',
      ShotCaptureSensitivity.high =>
        'Most sensitive (≈3 g). Useful for low-recoil rifles. '
            'May trigger on heavy walking.',
    };
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        text,
        style: theme.textTheme.bodySmall,
      ),
    );
  }
}

