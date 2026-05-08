// FILE: lib/widgets/cloud_sync_indicator.dart
//
// ============================================================================
// WHAT THIS FILE DOES
// ============================================================================
// Two tiny widgets that surface Cloud Sync status without taking up
// real estate:
//
// * [CloudSyncDot] — a 12px colored dot that reflects the current
//   `CloudSyncService.status`. Suitable for inline placement next to
//   the AutoSave banner or the AppBar icon row. Hides itself when
//   the service is disabled OR the user isn't Pro.
//
// * [CloudSyncAppBarAction] — a full IconButton (Pro users with sync
//   on get a circular `cloud_sync` icon they can tap to trigger an
//   explicit reconcile; everyone else gets a no-op outlined version
//   that pushes the Cloud Sync screen so the feature is at least
//   discoverable). Kept here rather than inlined in HomeScreen so
//   the AppBar code stays declarative.
//
// Both widgets watch `CloudSyncService` via `provider` and
// `ValueListenable` so they redraw on status changes without the
// parent widget rebuilding.
//
// ============================================================================
// WHY IT EXISTS IN THE ARCHITECTURE
// ============================================================================
// Continuous sync needs an "is it working?" indicator the user can
// glance at; without one, it feels invisible / suspicious. We
// deliberately don't reuse the AutoSave banner — that surfaces
// per-form save state, while sync is global and lives at the chrome
// level. Two distinct affordances, two distinct widgets.
//
// ============================================================================
// WHO CONSUMES THIS FILE
// ============================================================================
// - lib/screens/home/home_screen.dart — appbar action.
// - lib/widgets/auto_save_banner.dart (future) — could host the dot
//   alongside the save status; today the banner stays single-purpose
//   and the dot lives next to the action button.
//
// ============================================================================
// SIDE EFFECTS
// ============================================================================
// - Tapping the AppBar action either pushes [CloudSyncScreen] or
//   calls `CloudSyncService.reconcile()`. Reconcile touches the
//   provider's network endpoint.

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../screens/sync/cloud_sync_screen.dart';
import '../services/cloud_sync_service.dart';
import '../services/entitlement_notifier.dart';

/// Small colored dot reflecting [CloudSyncService.status].
/// Returns a zero-size [SizedBox] when the service is disabled or
/// the user isn't Pro.
class CloudSyncDot extends StatelessWidget {
  const CloudSyncDot({super.key, this.size = 10});

  final double size;

  @override
  Widget build(BuildContext context) {
    final svc = context.watch<CloudSyncService>();
    final isPro = context.watch<EntitlementNotifier>().isPro;
    if (!svc.isEnabled || !isPro) return const SizedBox.shrink();
    return ValueListenableBuilder<SyncStatus>(
      valueListenable: svc.status,
      builder: (context, status, _) {
        final color = _colorFor(context, status);
        return Tooltip(
          message: _tooltipFor(status),
          child: Container(
            width: size,
            height: size,
            decoration: BoxDecoration(color: color, shape: BoxShape.circle),
          ),
        );
      },
    );
  }

  static Color _colorFor(BuildContext context, SyncStatus status) {
    final scheme = Theme.of(context).colorScheme;
    switch (status) {
      case SyncStatus.idle:
        return scheme.primary;
      case SyncStatus.syncingUp:
      case SyncStatus.syncingDown:
        return const Color(0xFFF59E0B); // amber
      case SyncStatus.conflict:
      case SyncStatus.error:
        return scheme.error;
    }
  }

  static String _tooltipFor(SyncStatus status) {
    switch (status) {
      case SyncStatus.idle:
        return 'Cloud Sync — up to date';
      case SyncStatus.syncingUp:
        return 'Cloud Sync — uploading';
      case SyncStatus.syncingDown:
        return 'Cloud Sync — downloading';
      case SyncStatus.conflict:
        return 'Cloud Sync — passphrase needed';
      case SyncStatus.error:
        return 'Cloud Sync — last attempt failed';
    }
  }
}

/// AppBar IconButton for Cloud Sync. Two states:
///   * sync enabled (Pro) → tappable refresh button that fires
///     [CloudSyncService.reconcile]. Long-press opens settings.
///   * sync disabled or non-Pro → outlined cloud icon that pushes
///     the Cloud Sync screen (where the user can enable it / hit
///     the paywall).
class CloudSyncAppBarAction extends StatefulWidget {
  const CloudSyncAppBarAction({super.key});

  @override
  State<CloudSyncAppBarAction> createState() => _CloudSyncAppBarActionState();
}

class _CloudSyncAppBarActionState extends State<CloudSyncAppBarAction> {
  bool _busy = false;

  Future<void> _onPressed() async {
    final svc = context.read<CloudSyncService>();
    final isPro = context.read<EntitlementNotifier>().isPro;
    if (!svc.isEnabled || !isPro) {
      Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => const CloudSyncScreen()),
      );
      return;
    }
    setState(() => _busy = true);
    try {
      await svc.reconcile();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Cloud Sync ran.')),
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _onLongPress() {
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => const CloudSyncScreen()),
    );
  }

  @override
  Widget build(BuildContext context) {
    final svc = context.watch<CloudSyncService>();
    final isPro = context.watch<EntitlementNotifier>().isPro;
    final active = svc.isEnabled && isPro;
    return ValueListenableBuilder<SyncStatus>(
      valueListenable: svc.status,
      builder: (context, status, _) {
        final iconColor = active
            ? CloudSyncDot._colorFor(context, status)
            : Theme.of(context).colorScheme.onSurfaceVariant;
        return GestureDetector(
          onLongPress: _onLongPress,
          child: IconButton(
            tooltip: active
                ? 'Sync now (long-press for settings)'
                : 'Cloud Sync',
            onPressed: _busy ? null : _onPressed,
            icon: Icon(
              active ? Icons.cloud_sync_outlined : Icons.cloud_outlined,
              color: iconColor,
            ),
          ),
        );
      },
    );
  }
}
