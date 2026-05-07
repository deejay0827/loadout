// FILE: lib/screens/devices/device_scan_screen.dart
//
// ============================================================================
// WHAT THIS FILE DOES
// ============================================================================
// Scans for Kestrel weather meters in range and presents the results
// as a tappable list. Selecting a device kicks off the connect +
// service-discovery + GATT-subscribe handshake via [KestrelService];
// success bounces the user back to the [DevicesScreen] which now
// shows "Connected".
//
// The scan uses the GATT service-UUID filter so discovery is fast
// even in BLE-noisy environments. As a fallback, devices whose name
// starts with "Kestrel" are also included — some Kestrel firmware
// versions advertise their service UUID only in the scan-response
// rather than the broadcast packet, and the OS's pre-filter would
// otherwise drop them.
//
// ============================================================================
// WHO CONSUMES THIS FILE
// ============================================================================
// - lib/screens/devices/devices_screen.dart — pushes this screen as a
//   fullscreen dialog from the "Scan for devices" button.
//
// ============================================================================
// SIDE EFFECTS
// ============================================================================
// - Starts a BLE scan (lasts up to 12 seconds or until the user backs
//   out).
// - On selection, opens a GATT connection that survives this screen's
//   teardown — the connection lives on the [KestrelService] singleton.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:provider/provider.dart';

import '../../services/ble/ble_service.dart';
import '../../services/ble/kestrel_service.dart';

class DeviceScanScreen extends StatefulWidget {
  const DeviceScanScreen({super.key});

  @override
  State<DeviceScanScreen> createState() => _DeviceScanScreenState();
}

class _DeviceScanScreenState extends State<DeviceScanScreen> {
  StreamSubscription<List<ScanResult>>? _sub;
  final Map<String, ScanResult> _seen = {};
  String? _connectingId;
  String? _error;
  bool _scanning = false;

  @override
  void initState() {
    super.initState();
    // ignore: discarded_futures
    _startScan();
  }

  Future<void> _startScan() async {
    setState(() {
      _seen.clear();
      _error = null;
      _scanning = true;
    });
    final ble = context.read<BleService>();
    try {
      final stream = await ble.startScan(
        timeout: const Duration(seconds: 12),
        withServices: [kKestrelServiceUuid],
      );
      _sub = stream.listen((batch) {
        for (final r in batch) {
          final isKestrel = r.advertisementData.serviceUuids
                  .contains(kKestrelServiceUuid) ||
              r.device.platformName.toLowerCase().startsWith('kestrel');
          if (isKestrel) {
            _seen[r.device.remoteId.str] = r;
          }
        }
        if (mounted) setState(() {});
      });
      // Auto-stop spinner after the package's timeout fires.
      Future<void>.delayed(const Duration(seconds: 13), () {
        if (mounted) setState(() => _scanning = false);
      });
    } on BleException catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.userMessage;
        _scanning = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = 'Scan failed: $e';
        _scanning = false;
      });
    }
  }

  @override
  void dispose() {
    // ignore: discarded_futures
    _sub?.cancel();
    // ignore: discarded_futures
    context.read<BleService>().stopScan();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final results = _seen.values.toList(growable: false)
      ..sort((a, b) => b.rssi.compareTo(a.rssi));
    return Scaffold(
      appBar: AppBar(
        title: const Text('Scan for Kestrel'),
        actions: [
          if (_scanning)
            const Padding(
              padding: EdgeInsets.only(right: 16),
              child: Center(
                child: SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              ),
            )
          else
            IconButton(
              onPressed: _startScan,
              icon: const Icon(Icons.refresh),
              tooltip: 'Scan again',
            ),
        ],
      ),
      body: _error != null
          ? _buildError()
          : results.isEmpty
              ? _buildEmpty()
              : ListView.separated(
                  itemBuilder: (_, i) => _buildResult(results[i]),
                  separatorBuilder: (_, _) => const Divider(height: 1),
                  itemCount: results.length,
                ),
    );
  }

  Widget _buildError() {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.error_outline,
              color: theme.colorScheme.error, size: 36),
          const SizedBox(height: 12),
          Text(
            _error ?? 'Scan failed.',
            textAlign: TextAlign.center,
            style: theme.textTheme.bodyMedium,
          ),
          const SizedBox(height: 16),
          FilledButton.icon(
            icon: const Icon(Icons.refresh),
            onPressed: _startScan,
            label: const Text('Try again'),
          ),
        ],
      ),
    );
  }

  Widget _buildEmpty() {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            _scanning ? Icons.bluetooth_searching : Icons.bluetooth_disabled,
            color: theme.colorScheme.onSurfaceVariant,
            size: 36,
          ),
          const SizedBox(height: 12),
          Text(
            _scanning
                ? 'Scanning for Kestrel devices…'
                : 'No Kestrel devices found.',
            style: theme.textTheme.bodyMedium,
          ),
          const SizedBox(height: 4),
          Text(
            "Make sure the meter is powered on, in pairing mode, and within "
            'about 30 ft of this device.',
            textAlign: TextAlign.center,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildResult(ScanResult r) {
    final theme = Theme.of(context);
    final id = r.device.remoteId.str;
    final connecting = _connectingId == id;
    final name = r.device.platformName.trim().isEmpty
        ? id
        : r.device.platformName.trim();
    return ListTile(
      leading: const Icon(Icons.air),
      title: Text(name),
      subtitle: Text(
        'Signal: ${r.rssi} dBm · $id',
        style: theme.textTheme.bodySmall?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
        ),
      ),
      trailing: connecting
          ? const SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : const Icon(Icons.chevron_right),
      onTap: connecting ? null : () => _onPick(r.device),
    );
  }

  Future<void> _onPick(BluetoothDevice device) async {
    final messenger = ScaffoldMessenger.of(context);
    final navigator = Navigator.of(context);
    final ble = context.read<BleService>();
    final kestrel = context.read<KestrelService>();
    setState(() => _connectingId = device.remoteId.str);
    try {
      await ble.stopScan();
      await kestrel.connect(device);
      if (!mounted) return;
      messenger.showSnackBar(
        const SnackBar(content: Text('Connected to Kestrel.')),
      );
      navigator.pop();
    } on BleException catch (e) {
      if (!mounted) return;
      messenger.showSnackBar(SnackBar(content: Text(e.userMessage)));
      setState(() => _connectingId = null);
    } catch (e) {
      if (!mounted) return;
      messenger.showSnackBar(
        SnackBar(content: Text('Connection failed: $e')),
      );
      setState(() => _connectingId = null);
    }
  }
}
