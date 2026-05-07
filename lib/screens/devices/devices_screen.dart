// FILE: lib/screens/devices/devices_screen.dart
//
// ============================================================================
// WHAT THIS FILE DOES
// ============================================================================
// "Connected Devices" — single-stop UI for pairing the two pieces of
// gear LoadOut talks to over Bluetooth: a Garmin Xero C1 Pro
// chronograph and a Kestrel 5xxx Link weather meter. Reached from
// Settings → Devices.
//
// The screen has three tiles:
//
//   1. Bluetooth status banner. Surfaces "Bluetooth is off" / "Not
//      available on this device" when the radio isn't usable; otherwise
//      hidden. This keeps the rest of the screen functional even if
//      BLE is unavailable on the platform — the .fit import path still
//      works without Bluetooth.
//   2. Garmin Xero card. "Pair via Bluetooth" placeholder (coming-soon
//      snackbar) plus "Import .fit file" button — the latter is the
//      v1 import path. Both gated behind Pro.
//   3. Kestrel card. Shows current connection status; offers "Scan for
//      devices" → opens the [DeviceScanScreen] modal where the user
//      picks a discovered Kestrel and connects. Live readings are
//      shown as a single "Last reading" line. Pro-gated.
//
// A "Manage permissions" tile at the bottom deep-links to system
// settings via [BleService.openAppSettingsPage] for users who
// previously denied Bluetooth permanently and need to grant it
// manually.
//
// ============================================================================
// WHY IT EXISTS IN THE ARCHITECTURE
// ============================================================================
// Centralizing all BLE entry points in one screen keeps each feature
// shell free of pairing UI. The ballistics screen and range-day
// session detail just consume the [KestrelService] stream; they
// don't have to know anything about scanning or connection state.
// Same idea for the .fit import — Recipe Form and Range Day pull
// the import handler from `garmin_xero_service.dart` rather than
// reimplementing FIT parsing.
//
// ============================================================================
// WHO CONSUMES THIS FILE
// ============================================================================
// - lib/screens/settings/settings_screen.dart — pushes this screen.
//
// ============================================================================
// SIDE EFFECTS
// ============================================================================
// - Pushes the [DeviceScanScreen] modal which starts a BLE scan.
// - Calls into the platform `app_settings` deep-link.
// - Opens the OS file picker for the .fit import.

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:provider/provider.dart';

import '../../services/ble/ble_service.dart';
import '../../services/ble/garmin_xero_service.dart';
import '../../services/ble/kestrel_service.dart';
import '../../widgets/pro_gate.dart';
import 'device_scan_screen.dart';

class DevicesScreen extends StatefulWidget {
  const DevicesScreen({super.key});

  @override
  State<DevicesScreen> createState() => _DevicesScreenState();
}

class _DevicesScreenState extends State<DevicesScreen> {
  bool _bleAvailable = true;

  @override
  void initState() {
    super.initState();
    // ignore: discarded_futures
    _checkBleAvailability();
  }

  Future<void> _checkBleAvailability() async {
    final available = await context.read<BleService>().isAvailable();
    if (!mounted) return;
    setState(() => _bleAvailable = available);
  }

  @override
  Widget build(BuildContext context) {
    final ble = context.watch<BleService>();
    final kestrel = context.watch<KestrelService>();
    return Scaffold(
      appBar: AppBar(title: const Text('Connected Devices')),
      body: ListView(
        children: [
          if (!_bleAvailable) _bleUnavailableBanner(),
          if (_bleAvailable && !ble.isAdapterOn) _bluetoothOffBanner(ble),
          const _SectionHeader('Chronograph'),
          _GarminXeroCard(),
          const SizedBox(height: 8),
          const _SectionHeader('Weather Meter'),
          _KestrelCard(kestrel: kestrel),
          const SizedBox(height: 16),
          const _SectionHeader('System'),
          ListTile(
            leading: const Icon(Icons.settings_outlined),
            title: const Text('Manage permissions'),
            subtitle: const Text(
              'Open the OS settings to grant or revoke Bluetooth permission.',
            ),
            onTap: () async {
              await context.read<BleService>().openAppSettingsPage();
            },
          ),
          const SizedBox(height: 24),
        ],
      ),
    );
  }

  Widget _bleUnavailableBanner() {
    final theme = Theme.of(context);
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 16, 16, 0),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: theme.colorScheme.outlineVariant),
      ),
      child: Row(
        children: [
          Icon(Icons.bluetooth_disabled,
              color: theme.colorScheme.onSurfaceVariant),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              'Bluetooth is not available on this device. '
              'You can still import a Garmin .fit file below.',
              style: theme.textTheme.bodySmall,
            ),
          ),
        ],
      ),
    );
  }

  Widget _bluetoothOffBanner(BleService ble) {
    final theme = Theme.of(context);
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 16, 16, 0),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: theme.colorScheme.errorContainer.withValues(alpha: 0.3),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: theme.colorScheme.error.withValues(alpha: 0.4)),
      ),
      child: Row(
        children: [
          Icon(Icons.bluetooth_disabled, color: theme.colorScheme.error),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              'Bluetooth is turned off. Turn it on in Settings to scan '
              'for devices.',
              style: theme.textTheme.bodySmall,
            ),
          ),
          TextButton(
            onPressed: () async {
              await ble.openAppSettingsPage();
            },
            child: const Text('Open'),
          ),
        ],
      ),
    );
  }
}

// ─────────────────────── Garmin Xero ───────────────────────

class _GarminXeroCard extends StatefulWidget {
  @override
  State<_GarminXeroCard> createState() => _GarminXeroCardState();
}

class _GarminXeroCardState extends State<_GarminXeroCard> {
  bool _importing = false;
  GarminXeroSession? _lastSession;
  String? _lastSessionLabel;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final session = _lastSession;
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.speed, color: theme.colorScheme.primary),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Garmin Xero C1 Pro',
                        style: theme.textTheme.titleMedium,
                      ),
                      Text(
                        session == null
                            ? 'Status: Not paired'
                            : 'Imported · ${session.shots.length} shots, '
                                'avg ${session.averageFps.toStringAsFixed(0)} fps',
                        style: theme.textTheme.bodySmall,
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              children: [
                OutlinedButton.icon(
                  icon: const Icon(Icons.bluetooth, size: 18),
                  onPressed: _onPlaceholderPair,
                  label: const Text('Pair via Bluetooth'),
                ),
                FilledButton.icon(
                  icon: _importing
                      ? const SizedBox(
                          width: 14,
                          height: 14,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.file_open_outlined, size: 18),
                  onPressed: _importing ? null : _onImportFit,
                  label: const Text('Import .fit file'),
                ),
              ],
            ),
            if (_lastSessionLabel != null) ...[
              const SizedBox(height: 8),
              Text(
                _lastSessionLabel!,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
            const SizedBox(height: 4),
            Text(
              'Live BLE pairing is coming soon. For now, export a session '
              'to .fit from the Garmin Connect app and import it here.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
                fontStyle: FontStyle.italic,
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _onPlaceholderPair() {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text(
          'Live Garmin Xero pairing is coming soon. Use Import .fit for now.',
        ),
      ),
    );
  }

  Future<void> _onImportFit() async {
    if (!await ensurePro(context)) return;
    if (!mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    final ble = context.read<BleService>();
    setState(() => _importing = true);
    try {
      final picked = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: const ['fit'],
        withData: false,
      );
      if (picked == null || picked.files.isEmpty) return;
      final path = picked.files.single.path;
      if (path == null) {
        messenger.showSnackBar(
          const SnackBar(content: Text("Couldn't read the selected file.")),
        );
        return;
      }
      final svc = GarminXeroService(ble);
      final session = await svc.importFitFile(path);
      if (!mounted) return;
      setState(() {
        _lastSession = session;
        _lastSessionLabel =
            'Loaded ${session.shots.length} shots · avg '
            '${session.averageFps.toStringAsFixed(0)} fps · '
            'ES ${session.extremeSpreadFps.toStringAsFixed(0)} · '
            'SD ${session.standardDeviationFps.toStringAsFixed(1)}';
      });
      messenger.showSnackBar(
        SnackBar(
          content:
              Text('Loaded ${session.shots.length} shots from .fit file.'),
        ),
      );
    } on GarminXeroParseException catch (e) {
      messenger.showSnackBar(SnackBar(content: Text(e.userMessage)));
    } catch (e) {
      messenger.showSnackBar(
        SnackBar(content: Text("Couldn't import that file: $e")),
      );
    } finally {
      if (mounted) setState(() => _importing = false);
    }
  }
}

// ─────────────────────── Kestrel ───────────────────────

class _KestrelCard extends StatelessWidget {
  const _KestrelCard({required this.kestrel});

  final KestrelService kestrel;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final device = kestrel.device;
    final reading = kestrel.lastReading;
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.air, color: theme.colorScheme.primary),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              'Kestrel 5xxx Link',
                              style: theme.textTheme.titleMedium,
                            ),
                          ),
                          Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 6, vertical: 2),
                            decoration: BoxDecoration(
                              color: theme.colorScheme.tertiaryContainer,
                              borderRadius: BorderRadius.circular(6),
                            ),
                            child: Text(
                              'BETA',
                              style:
                                  theme.textTheme.labelSmall?.copyWith(
                                color: theme.colorScheme.onTertiaryContainer,
                                fontWeight: FontWeight.w700,
                                letterSpacing: 0.5,
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 2),
                      Text(
                        device == null
                            ? 'Status: Not connected'
                            : 'Connected · ${_friendlyName(device)}',
                        style: theme.textTheme.bodySmall,
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              children: [
                if (device == null)
                  FilledButton.icon(
                    icon: const Icon(Icons.search, size: 18),
                    onPressed: () => _onScan(context),
                    label: const Text('Scan for devices'),
                  )
                else
                  OutlinedButton.icon(
                    icon: const Icon(Icons.bluetooth_disabled, size: 18),
                    onPressed: () => _onDisconnect(context),
                    label: const Text('Disconnect'),
                  ),
              ],
            ),
            const SizedBox(height: 8),
            if (reading != null)
              Text(
                'Last reading: '
                '${reading.tempF.toStringAsFixed(1)}°F · '
                '${reading.stationPressureInHg.toStringAsFixed(2)} inHg · '
                '${reading.humidityPct.toStringAsFixed(0)}% RH · '
                'Wind ${reading.windSpeedMph.toStringAsFixed(1)} mph '
                'from ${reading.windDirectionDeg.toStringAsFixed(0)}°',
                style: theme.textTheme.bodySmall,
              )
            else
              Text(
                'Last reading: —',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            const SizedBox(height: 4),
            Text(
              'Beta — feedback welcome. Verified Kestrel UUIDs require a real '
              'meter for end-to-end testing; if readings look off, email '
              'support so we can iterate.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
                fontStyle: FontStyle.italic,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _onScan(BuildContext context) async {
    if (!await ensurePro(context)) return;
    if (!context.mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => const DeviceScanScreen(),
        fullscreenDialog: true,
      ),
    );
  }

  Future<void> _onDisconnect(BuildContext context) async {
    final messenger = ScaffoldMessenger.of(context);
    await context.read<KestrelService>().disconnect();
    messenger.showSnackBar(
      const SnackBar(content: Text('Disconnected from Kestrel.')),
    );
  }

  String _friendlyName(BluetoothDevice d) {
    final n = d.platformName.trim();
    if (n.isNotEmpty) return n;
    return d.remoteId.str;
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
