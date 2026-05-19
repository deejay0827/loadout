// FILE: lib/screens/settings/settings_screen.dart
//
// ============================================================================
// WHAT THIS FILE DOES
// ============================================================================
// Top-level Settings directory. Splits what used to be a single flat
// list of switches and tiles into thematic submenus, each of which
// owns the controls relevant to one slice of the app:
//
//   Settings
//   ├─ Account                  ← AccountSettingsScreen
//   │     ├─ Sign in / Sign out
//   │     ├─ Email
//   │     └─ Restore purchases
//   ├─ App preferences          ← AppPreferencesScreen
//   │     ├─ Beginner Mode
//   │     ├─ Auto-save
//   │     ├─ Language
//   │     └─ Units of measurement
//   ├─ Cloud Sync               ← CloudSyncScreen (existing, linked)
//   ├─ Watch & Wear             ← WatchSettingsScreen
//   │     ├─ Connection status
//   │     ├─ Stage timer defaults
//   │     ├─ Glanceable DOPE prefs
//   │     └─ Shot capture sensitivity
//   ├─ Connected Devices        ← DevicesScreen (existing, linked)
//   ├─ AI features              ← AiSettingsScreen
//   ├─ Privacy & Data           ← PrivacyDataScreen
//   │     ├─ Crashlytics opt-in
//   │     ├─ Export my data
//   │     ├─ Delete my data
//   │     └─ Privacy / Terms / Disclaimer
//   ├─ Data Sources & Credits   ← DataSourcesScreen
//   └─ Help & Support           ← HelpSupportScreen
//         ├─ Email support
//         ├─ Print sample notebook
//         ├─ Restore from backup
//         └─ About / version
//
// Each tile pushes its own destination screen via a standard
// `MaterialPageRoute`. The system back gesture pops back to this
// directory cleanly.
//
// ============================================================================
// WHY IT EXISTS IN THE ARCHITECTURE
// ============================================================================
// The old single-list Settings screen was 700+ lines and growing every
// release. Splitting it gives each submenu its own narrow scope, makes
// each easier to test in isolation, and reduces the cognitive load on
// users who used to scroll to find a single switch.
//
// User-facing labels are stable: every label below was the label that
// was on the flat list, so screenshots, support replies, and muscle
// memory all still find the same controls — just one tap deeper.
//
// ============================================================================
// WHO CONSUMES THIS FILE
// ============================================================================
// - lib/screens/home/home_screen.dart — the Home drawer pushes
//   `SettingsScreen()` from the "Settings" tile.
// - The five new submenu files in this directory each receive
//   navigation from this directory.

import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../services/device_compatibility_service.dart';
import '../devices/devices_screen.dart';
import '../disclaimers/data_sources_screen.dart';
import '../sync/cloud_sync_screen.dart';
import 'account_settings_screen.dart';
import 'ai_settings_screen.dart';
import 'app_preferences_screen.dart';
import 'device_compatibility_screen.dart';
import 'diagnostics_screen.dart';
import 'help_support_screen.dart';
import 'privacy_data_screen.dart';
import 'watch_settings_screen.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  /// Search query the user types into the filter bar at the top of
  /// the screen. Matches against each tile's title + subtitle case-
  /// insensitively. Empty string = show every tile.
  final TextEditingController _searchController = TextEditingController();
  String _query = '';

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  /// Tile catalog. Lifting the rows out of `build()` so the filter
  /// pass operates on data instead of rebuilt widgets.
  ///
  /// Reads `DeviceCompatibilityService` so the conditional
  /// "Device Compatibility" tile only appears on devices with active
  /// gates (e.g. an Android 10 phone). Modern devices never see the
  /// tile — there's nothing to disclose.
  List<_SettingsTileSpec> _allTiles(BuildContext context) {
    final compat = context.read<DeviceCompatibilityService>();
    return [
      _SettingsTileSpec(
        icon: Icons.account_circle_outlined,
        title: 'Account',
        subtitle: 'Sign-in, email, restore purchases.',
        destinationBuilder: (_) => const AccountSettingsScreen(),
      ),
      _SettingsTileSpec(
        icon: Icons.tune_outlined,
        title: 'App preferences',
        subtitle: 'Beginner Mode, auto-save, language, units.',
        destinationBuilder: (_) => const AppPreferencesScreen(),
      ),
      _SettingsTileSpec(
        icon: Icons.cloud_sync_outlined,
        title: 'Cloud Sync',
        subtitle:
            'Continuously sync your data to your own iCloud, Google '
            'Drive, or OneDrive. End-to-end encrypted (Pro).',
        destinationBuilder: (_) => const CloudSyncScreen(),
      ),
      _SettingsTileSpec(
        icon: Icons.watch_outlined,
        title: 'Watch & Wear',
        subtitle:
            'Apple Watch / Wear OS connection, shot-capture sensitivity.',
        destinationBuilder: (_) => const WatchSettingsScreen(),
      ),
      _SettingsTileSpec(
        icon: Icons.bluetooth_outlined,
        title: 'Connected Devices',
        subtitle:
            'Pair a Bluetooth chronograph, Kestrel, or rangefinder.',
        destinationBuilder: (_) => const DevicesScreen(),
      ),
      _SettingsTileSpec(
        icon: Icons.auto_awesome_outlined,
        title: 'AI features',
        subtitle:
            'Optional AI assist for messy handwriting in Smart Import.',
        destinationBuilder: (_) => const AiSettingsScreen(),
      ),
      // SAAMI Specs moved to the new "Resources" drawer destination
      // (lib/screens/resources/resources_screen.dart) — reference
      // material isn't a setting, and grouping it under Resources
      // matches user expectation. Settings keeps strictly the
      // "preferences and account" surface.
      _SettingsTileSpec(
        icon: Icons.privacy_tip_outlined,
        title: 'Privacy & Data',
        subtitle:
            'Crashlytics, export, delete, privacy policy / disclaimer.',
        destinationBuilder: (_) => const PrivacyDataScreen(),
      ),
      _SettingsTileSpec(
        icon: Icons.handshake_outlined,
        title: 'Data Sources & Credits',
        subtitle:
            'The companies whose data made LoadOut possible.',
        destinationBuilder: (_) => const DataSourcesScreen(),
      ),
      _SettingsTileSpec(
        icon: Icons.help_outline,
        title: 'Help & Support',
        subtitle:
            'Email support, print notebook page, restore backup.',
        destinationBuilder: (_) => const HelpSupportScreen(),
      ),
      // Device Compatibility tile — only present when at least one
      // hardware-linked feature is gated by the OS version on this
      // device. Modern devices (Android 12+, iOS 15+) have no gates
      // active and never see this row; the user reads "everything
      // works" as the silent default.
      if (compat.hasAnyGates)
        _SettingsTileSpec(
          icon: Icons.smartphone_outlined,
          title: 'Device Compatibility',
          subtitle:
              "What's gated by your OS version (${compat.profile.osDisplay}).",
          destinationBuilder: (_) => const DeviceCompatibilityScreen(),
        ),
      // Developer-only Diagnostics tile. `kDebugMode` is a compile-time
      // `false` in release builds, so this tile (and its destination
      // screen) are stripped entirely from anything shipped to the
      // App Store / Play Store — production users never see it. Houses
      // the "Simulate LoadOut Pro" free/paid toggle.
      if (kDebugMode)
        _SettingsTileSpec(
          icon: Icons.bug_report_outlined,
          title: 'Diagnostics',
          subtitle:
              'Developer-only. Simulate a free or paid account to test '
              'Pro-gated features.',
          destinationBuilder: (_) => const DiagnosticsScreen(),
        ),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final all = _allTiles(context);
    final q = _query.toLowerCase();
    final filtered = q.isEmpty
        ? all
        : all
            .where((t) =>
                t.title.toLowerCase().contains(q) ||
                t.subtitle.toLowerCase().contains(q))
            .toList();

    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: SafeArea(
        child: Column(
          children: [
            // Filter bar mirrors the glossary's pattern — type to
            // narrow the visible list. Matches title + subtitle so a
            // search for "kestrel" finds Connected Devices, "auto"
            // finds App preferences, etc.
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
              child: TextField(
                controller: _searchController,
                textInputAction: TextInputAction.search,
                onChanged: (v) => setState(() => _query = v.trim()),
                decoration: InputDecoration(
                  hintText: 'Filter settings',
                  prefixIcon: const Icon(Icons.search),
                  suffixIcon: _query.isEmpty
                      ? null
                      : IconButton(
                          icon: const Icon(Icons.clear),
                          tooltip: 'Clear filter',
                          onPressed: () {
                            _searchController.clear();
                            setState(() => _query = '');
                          },
                        ),
                  filled: true,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: BorderSide.none,
                  ),
                ),
              ),
            ),
            Expanded(
              child: filtered.isEmpty
                  ? Center(
                      child: Padding(
                        padding: const EdgeInsets.all(32),
                        child: Text(
                          'No settings match "$_query".',
                          style: theme.textTheme.bodyMedium?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ),
                    )
                  : ListView(
                      children: [
                        for (final tile in filtered)
                          _CategoryTile(
                            icon: tile.icon,
                            title: tile.title,
                            subtitle: tile.subtitle,
                            destinationBuilder: tile.destinationBuilder,
                          ),
                      ],
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Pure-data settings tile spec. The filter pass operates on a list
/// of these (cheap to scan) before constructing widgets — keeps the
/// search responsive even as the catalog grows.
class _SettingsTileSpec {
  const _SettingsTileSpec({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.destinationBuilder,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final WidgetBuilder destinationBuilder;
}

/// Re-usable directory row. Renders an icon, title, subtitle, and
/// trailing chevron so every tile looks identical.
class _CategoryTile extends StatelessWidget {
  const _CategoryTile({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.destinationBuilder,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final WidgetBuilder destinationBuilder;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: Icon(icon),
      title: Text(title),
      subtitle: Text(subtitle),
      trailing: const Icon(Icons.chevron_right),
      onTap: () {
        Navigator.of(context).push(
          MaterialPageRoute(builder: destinationBuilder),
        );
      },
    );
  }
}
